class_name DungeonRoom
extends Node3D
## A room prefab owns its socket transforms, collision footprint, and loot anchor positions.
## Each socket's local -Z points out of its opening. Its parent can also be rotated/translated.

const DEAD_END: PackedScene = preload("res://scenes/world/rooms/DeadEnd.tscn")
const DOOR_SIGN: PackedScene = preload("res://scenes/world/rooms/DoorSign.tscn")
const DIRECTIONS: Array[StringName] = [&"north", &"east", &"south", &"west"]
const NORMALS: Array[Vector3] = [Vector3.FORWARD, Vector3.RIGHT, Vector3.BACK, Vector3.LEFT]

@export var room_kind: int = -1
@export var sector_name: String = ""
@export var footprint: AABB = AABB(Vector3(-8.0, -0.25, -8.0), Vector3(16.0, 4.5, 16.0))

static var _finishes: Dictionary[StringName, StandardMaterial3D] = {}


func sockets() -> Dictionary[int, Transform3D]:
	var result: Dictionary[int, Transform3D] = {}
	var doors: Node3D = get_node_or_null("Doors") as Node3D
	if doors == null:
		return result
	for opening: Node in doors.get_children():
		var pivot: Node3D = opening as Node3D
		var marker: Marker3D = opening.get_node_or_null("DoorMarker") as Marker3D
		if pivot == null or marker == null:
			continue
		var side: int = DIRECTIONS.find(StringName(marker.get_meta(&"exit_direction", &"")))
		if side < 0 or result.has(side):
			push_error("%s: each DoorMarker needs a unique cardinal exit_direction." % name)
			continue
		var pose: Transform3D = doors.transform * pivot.transform * marker.transform
		if not (-pose.basis.z).is_equal_approx(NORMALS[side]) or not pose.basis.y.is_equal_approx(Vector3.UP):
			push_error("%s: DoorMarker -Z must point toward its exit_direction." % name)
			continue
		result[side] = pose
	return result


func loot_markers() -> Array[Marker3D]:
	var result: Array[Marker3D] = []
	var loot: Node3D = get_node_or_null("Loot") as Node3D
	if loot == null:
		return result
	for node: Node in loot.get_children():
		if node is Marker3D:
			result.append(node as Marker3D)
	return result


func configure_doors(door_mask: int, destinations: Dictionary[int, String]) -> void:
	var room_sockets: Dictionary[int, Transform3D] = sockets()
	for side: int in room_sockets:
		var open: bool = (door_mask & (1 << side)) != 0
		if not open:
			var bulkhead: Node3D = DEAD_END.instantiate() as Node3D
			bulkhead.name = "Seal%d" % side
			bulkhead.transform = room_sockets[side]
			add_child(bulkhead)
		# Read the room on the other side before entering it. Text and color both
		# distinguish a sealed bulkhead from a route that can be used.
		var board: Node3D = DOOR_SIGN.instantiate() as Node3D
		board.name = "DoorSign%d" % side
		board.transform = room_sockets[side]
		var label: Label3D = board.get_node("Text") as Label3D
		label.text = destinations.get(side, "ПРОХОД") if open else "ЗАКРЫТО"
		var ink: Color = Color(1.0, 0.75, 0.63)
		if open:
			ink = Color(1.0, 0.87, 0.58) if label.text == "ШЛЮЗ" else Color(0.78, 1.0, 0.94)
		Look.style_sign(label, ink, 80, 0.0044)
		add_child(board)


func _ready() -> void:
	if _finishes.is_empty():
		_finishes[&"concrete"] = Surfaces.mat(Surfaces.Kind.CONCRETE, Color(0.33, 0.33, 0.32), 0.92, 0.0, true)
		_finishes[&"grime"] = Surfaces.mat(Surfaces.Kind.GRIME, Color(0.44, 0.46, 0.46), 0.91, 0.0, true)
		_finishes[&"panel"] = Surfaces.mat(Surfaces.Kind.PANEL, Color(0.34, 0.42, 0.47), 0.89, 0.0, true)
		_finishes[&"rust"] = Surfaces.mat(Surfaces.Kind.METAL, Color(0.43, 0.26, 0.17), 0.86, 0.0, true)
		_finishes[&"wood"] = Surfaces.mat(Surfaces.Kind.WOOD, Color(0.35, 0.26, 0.18), 0.92, 0.0, true)
	# Visit this room's shell and props only. The start room also parents the replicated
	# Modules container, whose other DungeonRooms each dress their own geometry.
	_apply_finishes(self)


func _apply_finishes(parent: Node) -> void:
	for child: Node in parent.get_children():
		if child is DungeonRoom or child.name == &"Modules":
			continue
		var mesh: MeshInstance3D = child as MeshInstance3D
		if mesh != null and mesh.has_meta(&"finish"):
			var key: StringName = StringName(mesh.get_meta(&"finish"))
			if _finishes.has(key):
				var box: BoxMesh = mesh.mesh as BoxMesh
				mesh.material_override = Surfaces.for_size(_finishes[key], box.size) if box != null else _finishes[key]
		_apply_finishes(child)

