class_name LevelGenerator
extends Node3D
## Plans a whole night on the authority. One custom MultiplayerSpawner spawn carries the
## committed start room, every transform, connected sockets, and loot. Remote peers only
## instantiate that snapshot, so late joiners use exactly the same layout as the host.

signal layout_ready(seed_value: int)

const START_ROOM: PackedScene = preload("res://scenes/world/rooms/StartRoom.tscn")
const ASSEMBLY: PackedScene = preload("res://scenes/world/rooms/AssemblyRoom.tscn")
const FLOODED: PackedScene = preload("res://scenes/world/rooms/FloodedRoom.tscn")
const ARCHIVES: PackedScene = preload("res://scenes/world/rooms/Archives.tscn")
const DOOR_COUNT: int = 4
const HALF_TURN: Transform3D = Transform3D(Basis(Vector3(-1, 0, 0), Vector3.UP, Vector3(0, 0, -1)), Vector3.ZERO)
const WALK_Y: float = 0.35
const SOCKET_EPSILON: float = 0.015
const TYPE_NAMES: Dictionary[int, String] = {0: "сборка", 1: "насосная", 2: "архив"}

@export var start_room: PackedScene = START_ROOM
@export var room_pool: Array[PackedScene] = [ASSEMBLY, FLOODED, ARCHIVES]
@export_range(15, 25) var target_rooms: int = 19
@export_range(1, 12) var max_depth: int = 8
@export_range(1, 12) var main_path_length: int = 6
@export_range(1, 25) var loot_budget: int = 12


class RoomTemplate:
	var scene: PackedScene
	var bounds: AABB
	var sockets: Dictionary[int, Transform3D]
	var loot_count: int
	var title: String


var _rng: RandomNumberGenerator = RandomNumberGenerator.new()
var _catalog: Array[RoomTemplate] = []
var _plan: Array[Dictionary] = []
var _occupied: Array[AABB] = []
var _links: Array[Vector4i] = []

var _layouts: Node3D
var _spawner: MultiplayerSpawner
var _active: DungeonRoom
var _seed_value: int = 0
var _hash: int = 0
var _room_count: int = 0
var _loop_count: int = 0
var _rooms: Array[Dictionary] = []
var _nodes: Array[Dictionary] = []
var _scrap: Array[Marker3D] = []
var _scrap_mesh: BoxMesh
## Tablet geometry in world X/Z. Walls are endpoint pairs, doors are link sockets.
var tablet_walls: PackedVector3Array = PackedVector3Array()
var tablet_doors: PackedVector3Array = PackedVector3Array()


func _ready() -> void:
	# Game.tscn declares these nodes. Standalone level probes can also instantiate this
	# class directly without reproducing the scene tree.
	_layouts = get_node_or_null("Layouts") as Node3D
	if _layouts == null:
		_layouts = Node3D.new()
		_layouts.name = "Layouts"
		add_child(_layouts)
	_spawner = get_node_or_null("RoomSpawner") as MultiplayerSpawner
	if _spawner == null:
		_spawner = MultiplayerSpawner.new()
		_spawner.name = "RoomSpawner"
		_spawner.spawn_path = NodePath("../Layouts")
		add_child(_spawner)
	_spawner.spawn_function = _spawn_layout
	_layouts.child_exiting_tree.connect(_on_layout_removed)
	if not _register_room(start_room):
		return
	for room: PackedScene in room_pool:
		_register_room(room)


func _register_room(scene: PackedScene) -> bool:
	if scene == null:
		push_error("Room registry contains an empty PackedScene.")
		return false
	var instance: Node = scene.instantiate()
	var preview: DungeonRoom = instance as DungeonRoom
	if preview == null:
		instance.free()
		push_error("%s needs a DungeonRoom root." % scene.resource_path)
		return false
	var entry: RoomTemplate = RoomTemplate.new()
	entry.scene = scene
	entry.bounds = preview.footprint
	entry.sockets = preview.sockets()
	entry.loot_count = preview.loot_markers().size()
	entry.title = preview.sector_name.strip_edges()
	if entry.title.is_empty():
		entry.title = TYPE_NAMES.get(preview.room_kind, "Проход").to_upper()
	# Read the authored metadata once. Rejected layout candidates never enter the tree.
	preview.free()
	if not entry.bounds.has_volume() or entry.sockets.is_empty():
		push_error("%s needs a positive footprint and at least one valid door." % scene.resource_path)
		return false
	_catalog.append(entry)
	return true


func generate(seed_value: int) -> void:
	if _catalog.is_empty() or not multiplayer.is_server() or not is_multiplayer_authority() or has_layout(seed_value):
		return
	var blueprint: Dictionary = _make_blueprint(seed_value)
	clear_layout()
	if multiplayer.multiplayer_peer is OfflineMultiplayerPeer or not multiplayer.has_multiplayer_peer():
		_layouts.add_child(_spawn_layout(blueprint), true)
	else:
		_spawner.spawn(blueprint)


func clear_layout() -> void:
	if not multiplayer.is_server() or not is_instance_valid(_active):
		return
	var previous: DungeonRoom = _active
	# Removing the root makes the spawner send its despawn before publishing a new snapshot.
	_layouts.remove_child(previous)
	previous.queue_free()


func has_layout(seed_value: int) -> bool:
	return is_instance_valid(_active) and _seed_value == seed_value


func _make_blueprint(seed_value: int) -> Dictionary:
	_rng.seed = seed_value
	_plan.clear()
	_occupied.clear()
	_links.clear()
	_commit(0, Transform3D.IDENTITY, 0, true)
	if _catalog.size() > 1:
		_grow_main_path()
		_grow_branches()
	return {
		"seed": seed_value,
		"rooms": _plan.duplicate(true),
		"links": _links.duplicate(),
		"loot": _plan_loot(),
	}


func _grow_main_path() -> void:
	var cursor: int = 0
	var first: int = _rng.randi_range(0, DOOR_COUNT - 1)
	var turn: int = -1 if _rng.randi_range(0, 1) == 0 else 1
	var limit: int = mini(main_path_length, max_depth)
	for step: int in range(limit):
		# The first three moves aim around a 2x2 block. Its last room can reconnect to
		# StartRoom, giving the default tiles a second route back to the extraction bay.
		var preferred: int = posmod(first + turn * step, DOOR_COUNT) if step < 3 else _rng.randi_range(0, DOOR_COUNT - 1)
		var next: int = -1
		for offset: int in DOOR_COUNT:
			var side: int = (preferred + offset) % DOOR_COUNT
			next = _attach(cursor, side, true)
			if next >= 0:
				break
		if next < 0 or _plan.size() >= target_rooms:
			break
		cursor = next


func _grow_branches() -> void:
	var frontier: Array[Vector2i] = []
	for index: int in _plan.size():
		_add_frontier(frontier, index)
	while _plan.size() < target_rooms and not frontier.is_empty():
		var pick: int = _rng.randi_range(0, frontier.size() - 1)
		var candidate: Vector2i = frontier[pick]
		frontier.remove_at(pick)
		var index: int = _attach(candidate.x, candidate.y, false)
		if index >= 0:
			_add_frontier(frontier, index)


func _add_frontier(frontier: Array[Vector2i], room_index: int) -> void:
	var room: Dictionary = _plan[room_index]
	if int(room["depth"]) >= max_depth:
		return
	var template: RoomTemplate = _catalog[int(room["type"])]
	for side: int in template.sockets:
		if (int(room["used"]) & (1 << side)) == 0:
			frontier.append(Vector2i(room_index, side))


func _attach(room_index: int, side: int, on_main: bool) -> int:
	var parent_room: Dictionary = _plan[room_index]
	var depth: int = int(parent_room["depth"]) + 1
	var template: RoomTemplate = _catalog[int(parent_room["type"])]
	if depth > max_depth or not template.sockets.has(side) or (int(parent_room["used"]) & (1 << side)):
		return -1
	var parent_pose: Transform3D = parent_room["pose"]
	var target: Transform3D = parent_pose * template.sockets[side] * HALF_TURN
	var template_offset: int = _rng.randi_range(0, _catalog.size() - 2)
	for offset: int in range(_catalog.size() - 1):
		var type: int = 1 + (template_offset + offset) % (_catalog.size() - 1)
		var candidate: RoomTemplate = _catalog[type]
		var door_offset: int = _rng.randi_range(0, DOOR_COUNT - 1)
		for index: int in DOOR_COUNT:
			var door: int = (door_offset + index) % DOOR_COUNT
			if not candidate.sockets.has(door):
				continue
			var pose: Transform3D = target * candidate.sockets[door].affine_inverse()
			# Authors use quarter turns. Snap away floating point drift at the shared plane.
			pose = Transform3D(Basis(pose.basis.x.round(), pose.basis.y.round(), pose.basis.z.round()),
				pose.origin.snapped(Vector3(0.001, 0.001, 0.001)))
			if _overlaps(pose * candidate.bounds):
				continue
			return _commit(type, pose, depth, on_main)
	# The socket stays unused. The instantiator will put a collidable bulkhead there.
	return -1


func _overlaps(candidate: AABB) -> bool:
	# Two aligned rooms may touch at a door plane. Allow that face contact without
	# allowing a wall or floor to intrude into the neighbouring module.
	var interior: AABB = candidate.grow(-SOCKET_EPSILON)
	for occupied: AABB in _occupied:
		if interior.intersects(occupied):
			return true
	return false


func _commit(type: int, pose: Transform3D, depth: int, on_main: bool) -> int:
	var index: int = _plan.size()
	_plan.append({"type": type, "pose": pose, "depth": depth, "main": on_main, "used": 0})
	_occupied.append(pose * _catalog[type].bounds)
	_connect_touching(index)
	return index


func _connect_touching(index: int) -> void:
	var room: Dictionary = _plan[index]
	var pose: Transform3D = room["pose"]
	var template: RoomTemplate = _catalog[int(room["type"])]
	for side: int in template.sockets:
		var socket: Transform3D = pose * template.sockets[side]
		for other_index: int in range(index):
			if int(room["used"]) & (1 << side):
				break
			var other: Dictionary = _plan[other_index]
			var other_pose: Transform3D = other["pose"]
			var other_template: RoomTemplate = _catalog[int(other["type"])]
			for other_side: int in other_template.sockets:
				if int(other["used"]) & (1 << other_side):
					continue
				var opposite: Transform3D = other_pose * other_template.sockets[other_side]
				if socket.origin.distance_squared_to(opposite.origin) > SOCKET_EPSILON * SOCKET_EPSILON:
					continue
				if socket.basis.z.dot(opposite.basis.z) > -0.999:
					continue
				room["used"] = int(room["used"]) | (1 << side)
				other["used"] = int(other["used"]) | (1 << other_side)
				_links.append(Vector4i(index, side, other_index, other_side))
				break


func _plan_loot() -> Array[Vector3i]:
	var candidates: Array[int] = []
	for room_index: int in range(1, _plan.size()):
		if _catalog[int(_plan[room_index]["type"])].loot_count > 0:
			candidates.append(room_index)
	# Keep the first two finds on the entry route, then spread the rest between rooms.
	for index: int in range(candidates.size() - 1, 2, -1):
		var swap_index: int = _rng.randi_range(2, index)
		var swap: int = candidates[index]
		candidates[index] = candidates[swap_index]
		candidates[swap_index] = swap
	var loot: Array[Vector3i] = []
	for index: int in mini(loot_budget, candidates.size()):
		var room_index: int = candidates[index]
		var count: int = _catalog[int(_plan[room_index]["type"])].loot_count
		loot.append(Vector3i(room_index, _rng.randi_range(0, count - 1), _rng.randi_range(120, 300)))
	return loot


func _spawn_layout(data: Variant) -> Node:
	var blueprint: Dictionary = data
	var placements: Array = blueprint["rooms"]
	var links: Array = blueprint["links"]
	var loot: Array = blueprint["loot"]
	var seed_value: int = int(blueprint["seed"])
	var start: DungeonRoom = _catalog[0].scene.instantiate() as DungeonRoom
	start.name = "Dungeon%d" % seed_value
	var modules: Node3D = Node3D.new()
	modules.name = "Modules"
	start.add_child(modules)
	_active = start
	_seed_value = seed_value
	_room_count = placements.size()
	_loop_count = links.size() - _room_count + 1
	_rooms.clear()
	_nodes.clear()
	_scrap.clear()
	tablet_walls.clear()
	tablet_doors.clear()
	var instances: Array[DungeonRoom] = []
	var fingerprint: PackedStringArray = PackedStringArray([str(seed_value)])
	for index: int in placements.size():
		var placement: Dictionary = placements[index]
		var template: RoomTemplate = _catalog[int(placement["type"])]
		var room: DungeonRoom = start
		if index != 0:
			room = template.scene.instantiate() as DungeonRoom
			room.name = "Room%02d" % index
			modules.add_child(room)
		var pose: Transform3D = placement["pose"]
		room.transform = pose
		_add_tablet_outline(pose, template.bounds)
		var destinations: Dictionary[int, String] = {}
		for link: Vector4i in links:
			if link.x == index:
				destinations[link.y] = _catalog[int(placements[link.z]["type"])].title
			elif link.z == index:
				destinations[link.w] = _catalog[int(placements[link.x]["type"])].title
		room.configure_doors(int(placement["used"]), destinations)
		instances.append(room)
		_add_nav_node(pose.origin + Vector3.UP * WALK_Y)
		if index != 0:
			_rooms.append({"type": room.room_kind, "center": to_global(pose.origin), "size": Vector2(template.bounds.size.x, template.bounds.size.z),
				"depth": int(placement["depth"]), "main": bool(placement["main"])})
		fingerprint.append("%d:%s:%d" % [int(placement["type"]), pose, int(placement["used"])])
	for link: Vector4i in links:
		var pose: Transform3D = instances[link.x].transform
		var template: RoomTemplate = _catalog[int(placements[link.x]["type"])]
		var door: Vector3 = (pose * template.sockets[link.y]).origin
		tablet_doors.append(to_global(door))
		var waypoint: int = _add_nav_node(door + Vector3.UP * WALK_Y)
		_link_nav(link.x, waypoint)
		_link_nav(waypoint, link.z)
		fingerprint.append(str(link))
	for item: Vector3i in loot:
		var anchor: Marker3D = instances[item.x].loot_markers()[item.y]
		_make_scrap(anchor, item.z)
		fingerprint.append(str(item))
	_hash = "|".join(fingerprint).hash()
	start.ready.connect(_on_layout_entered.bind(seed_value), CONNECT_ONE_SHOT)
	return start


func _add_tablet_outline(pose: Transform3D, bounds: AABB) -> void:
	var low: Vector3 = bounds.position
	var high: Vector3 = bounds.end
	var corners: Array[Vector3] = [
		Vector3(low.x, 0.0, low.z), Vector3(high.x, 0.0, low.z),
		Vector3(high.x, 0.0, high.z), Vector3(low.x, 0.0, high.z),
	]
	for index: int in corners.size():
		tablet_walls.append(to_global(pose * corners[index]))
		tablet_walls.append(to_global(pose * corners[(index + 1) % corners.size()]))


func _make_scrap(anchor: Marker3D, value: int) -> void:
	if _scrap_mesh == null:
		_scrap_mesh = BoxMesh.new()
		_scrap_mesh.size = Vector3(0.42, 0.30, 0.36)
		var mat: StandardMaterial3D = Surfaces.mat(Surfaces.Kind.METAL, Color(0.72, 0.63, 0.40), 0.68, 0.0, true)
		mat.emission_enabled = true
		mat.emission = Color(0.61, 0.45, 0.14)
		mat.emission_energy_multiplier = 0.55
		_scrap_mesh.material = mat
	var mesh: MeshInstance3D = MeshInstance3D.new()
	mesh.mesh = _scrap_mesh
	anchor.add_child(mesh)
	anchor.set_meta(&"index", _scrap.size())
	anchor.set_meta(&"value", value)
	_scrap.append(anchor)


func _add_nav_node(at: Vector3) -> int:
	var links: Array[int] = []
	_nodes.append({"pos": to_global(at), "links": links})
	return _nodes.size() - 1


func _link_nav(left: int, right: int) -> void:
	(_nodes[left]["links"] as Array).append(right)
	(_nodes[right]["links"] as Array).append(left)


func _on_layout_entered(seed_value: int) -> void:
	layout_ready.emit(seed_value)


func _on_layout_removed(node: Node) -> void:
	if node != _active:
		return
	_active = null
	_seed_value = 0
	_hash = 0
	_room_count = 0
	_loop_count = 0
	_rooms.clear()
	_nodes.clear()
	_scrap.clear()
	tablet_walls.clear()
	tablet_doors.clear()


func apply_taken(taken: Array) -> void:
	for marker: Marker3D in _scrap:
		marker.visible = not taken.has(int(marker.get_meta(&"index")))


func scrap_points() -> Array[Marker3D]:
	return _scrap


func nav_nodes() -> Array[Dictionary]:
	return _nodes


func rooms() -> Array[Dictionary]:
	return _rooms


func layout_hash() -> int:
	return _hash


func describe() -> String:
	return "комнат %d, петель %d, узлов %d, лут %d" % [_room_count, _loop_count, _nodes.size(), _scrap.size()]

