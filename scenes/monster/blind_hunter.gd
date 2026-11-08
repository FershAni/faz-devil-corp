class_name BlindHunter
extends Node3D

## Blind Hunter - the first monster. It never sees you: it hears you, and it walks the
## level's route graph to the place the sound came from.
##
## Everything here runs on the host only. Clients get position, facing and state through the
## synchronizer, which is what keeps "the server decides what the AI does" true in practice -
## a client cannot tell the hunter anything.

enum State { PATROL, HUNT, SEARCH, COOLDOWN }

const PATROL_SPEED := 2.0
const HUNT_SPEED := 4.1
const SEARCH_SPEED := 1.6
const SEARCH_SECONDS := 4.0
const COOLDOWN_SECONDS := 3.0
## Anything quieter than this is weather. A crouched step is ~1.2, a normal step 8, a run 34.
const HEAR_MIN_LEVEL := 5.0

var state: int = State.PATROL
var heard_at := Vector3.ZERO
var heard_level := 0.0

var _graph := NavGraph.new()
var _route := PackedVector3Array()
var _step := 0
var _state_time := 0.0
var _rng := RandomNumberGenerator.new()
var _patrol_points: PackedVector3Array = PackedVector3Array()
var _dbg_state := -1
var _pose_scale := Vector3.ONE
var _breath := 0.0


@onready var _body: MeshInstance3D = get_node("Body")


func _enter_tree() -> void:
	# Before the first replication packet: late joiners receive an already-spawned hunter.
	_setup_replication()


func _ready() -> void:
	add_to_group("hunters")
	_dress()
	_rng.randomize()
	if not GameState.is_host():
		return
	GameState.noise_reported.connect(_on_noise)
	var level := _find_level()
	if level != null:
		_graph.load_nodes(level.nav_nodes())
		for room in level.rooms():
			_patrol_points.append(room["center"] as Vector3)
	if _patrol_points.is_empty():
		_patrol_points.append(global_position)
	_next_patrol()


## A capsule alone reads as a pill, not a predator. The arms are what sell it: they break the
## silhouette against a lit wall, and the pale face plate gives the flashlight something to
## find. Built the same way on every peer - no state and no rng, just geometry, so all four
## screens agree on what is walking towards them.
func _dress() -> void:
	var skin := StandardMaterial3D.new()
	skin.albedo_color = Color(0.11, 0.12, 0.135, 1.0)
	skin.roughness = 0.88
	skin.metallic = 0.0
	skin.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	# A rim is the cheapest horror trick there is: the shape reads before the light reaches it.
	skin.rim_enabled = true
	skin.rim = 0.28
	skin.rim_tint = 0.9
	# The pale parts are a wet muzzle and fingertips, not a balloon: at 0.44 the creature lit
	# like a snowman and the flashlight stopped being the scariest thing in the room.
	var pale := skin.duplicate() as StandardMaterial3D
	pale.albedo_color = Color(0.22, 0.22, 0.215, 1.0)
	pale.rim = 0.26
	var gape := StandardMaterial3D.new()
	gape.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	gape.albedo_color = Color(0.012, 0.012, 0.015, 1.0)
	_body.material_override = skin
	get_node("Head").material_override = skin
	for side in [-1.0, 1.0]:
		_limb(_body, Vector3(0.44 * side, 0.5, -0.1), Vector3(0.1, 1.5, 0.1),
			Vector3(6.0, 0.0, -9.0 * side), skin, "Arm")
		_limb(_body, Vector3(0.56 * side, -0.24, -0.3), Vector3(0.09, 0.34, 0.13),
			Vector3(20.0, 0.0, 0.0), pale, "Hand")
	_limb(_body, Vector3(0.0, 0.86, -0.6), Vector3(0.36, 0.4, 0.16), Vector3.ZERO,
		pale, "FacePlate", "box")
	_limb(get_node("Head"), Vector3(0.0, -0.02, -0.5), Vector3(0.05, 0.3, 0.04),
		Vector3.ZERO, gape, "Mouth")


## A primitive hung off a node in the creature's own coordinate space. Everything lives under
## Body so the existing lunge scale (`_body.scale`) moves the whole animal, not just its torso.
func _limb(parent: Node3D, at: Vector3, size: Vector3, rot_deg: Vector3,
		material: Material, node_name: String, shape := "auto") -> MeshInstance3D:
	var mesh := MeshInstance3D.new()
	mesh.name = node_name
	if shape == "box" or (shape == "auto" and size.z > size.x * 1.6):
		var box := BoxMesh.new()
		box.size = size
		mesh.mesh = box
	else:
		var capsule := CapsuleMesh.new()
		capsule.radius = size.x
		capsule.height = size.y
		capsule.radial_segments = 8
		capsule.rings = 5
		mesh.mesh = capsule
	mesh.material_override = material
	mesh.position = at
	mesh.rotation_degrees = rot_deg
	parent.add_child(mesh)
	return mesh


## The animal breathes, on every screen and even while it is frozen: a still prop is what a
## capsule reads as, and this costs one sin per frame.
func _process(delta: float) -> void:
	_breath += delta
	var swell := sin(_breath * 1.7)
	_body.scale = _pose_scale * Vector3(1.0 + swell * 0.022, 1.0 + swell * 0.03, 1.0 + swell * 0.022)


func _physics_process(delta: float) -> void:
	if not GameState.is_host():
		return
	# The hunter lives only in the night phases; in the pizzeria it does not walk or grab.
	if not GameState.is_play_phase():
		return
	if state != _dbg_state:
		_dbg_state = state
		SteamNet.note("[hunter] state -> %d at %s" % [state, str(global_position)])
	_state_time -= delta
	match state:
		State.PATROL:
			_advance(PATROL_SPEED, delta)
			if _arrived():
				_next_patrol()
		State.HUNT:
			_advance(HUNT_SPEED * clampf(heard_level / 40.0, 0.6, 1.3), delta)
			if _arrived():
				state = State.SEARCH
				_state_time = SEARCH_SECONDS
				_wander()
		State.SEARCH:
			_advance(SEARCH_SPEED, delta)
			if _state_time <= 0.0 or _arrived():
				_next_patrol()
		State.COOLDOWN:
			if _state_time <= 0.0:
				_next_patrol()
		_:
			pass
	_check_grab()


## ---------------- hearing ----------------

## The noise pipeline already carries who made it, so the hunter knows where the sound came
## from without the player having to send a position anyone could fake.
func _on_noise(level: float, _kind: int, peer_id: int) -> void:
	if level < HEAR_MIN_LEVEL:
		return
	var player := _player_by_peer(peer_id)
	if player == null:
		return
	heard_at = player.global_position
	heard_level = level
	_route = _graph.path(global_position, heard_at)
	_step = 0
	state = State.HUNT
	_state_time = 12.0
	_pose_scale = Vector3(1.0, 1.0, 1.25)


## Kill is contact, not proximity: the area is exactly the monster's body, so slipping past
## a blind hunter at arm's length is survivable - only actually touching it is not.
func _check_grab() -> void:
	var area := get_node_or_null("Touch") as Area3D
	if area == null:
		return
	for body in area.get_overlapping_bodies():
		var player := body as Player
		if player == null:
			continue
		var peer_id := int(player.get_multiplayer_authority())
		if GameState.is_dead(peer_id):
			continue
		# Catching somebody is loud, and the noise is what the rest of the crew will hear.
		SteamNet.note("[hunter] коснулся peer=%d" % peer_id)
		GameState.server_register_noise(60.0, Player.NoiseKind.HEAVY_STEP, peer_id)
		GameState.server_player_caught(peer_id)
		state = State.COOLDOWN
		_state_time = COOLDOWN_SECONDS
		_pose_scale = Vector3.ONE
		return


## ---------------- routing ----------------

func _next_patrol() -> void:
	var goal: Vector3 = _patrol_points[_rng.randi_range(0, _patrol_points.size() - 1)]
	state = State.PATROL
	_route = _graph.path(global_position, goal)
	_step = 0


func _wander() -> void:
	_route = _graph.path(global_position, heard_at + Vector3(
		_rng.randf_range(-3.0, 3.0), 0.0, _rng.randf_range(-3.0, 3.0)))
	_step = 0


func _advance(speed: float, delta: float) -> void:
	if _step >= _route.size():
		return
	var next: Vector3 = _route[_step]
	var to_next := next - global_position
	var distance := to_next.length()
	if distance < 0.35:
		_step += 1
		return
	global_position += to_next / distance * minf(speed * delta, distance)
	rotation.y = lerp_angle(rotation.y, atan2(-to_next.x, -to_next.z), 10.0 * delta)


func _arrived() -> bool:
	return _step >= _route.size()


func _player_by_peer(peer_id: int) -> Player:
	for node in get_tree().get_nodes_in_group(&"players"):
		if int(node.get_multiplayer_authority()) == peer_id:
			return node as Player
	return null


func _find_level() -> LevelGenerator:
	var game := get_tree().current_scene
	if game == null:
		return null
	return game.get_node_or_null("Level") as LevelGenerator


## ---------------- replication ----------------

func _setup_replication() -> void:
	var sync := get_node_or_null("Sync") as MultiplayerSynchronizer
	if sync == null:
		return
	var cfg := SceneReplicationConfig.new()
	_add(cfg, NodePath(":position"), SceneReplicationConfig.REPLICATION_MODE_ALWAYS)
	_add(cfg, NodePath(":rotation:y"), SceneReplicationConfig.REPLICATION_MODE_ALWAYS)
	_add(cfg, NodePath(":state"), SceneReplicationConfig.REPLICATION_MODE_ON_CHANGE, true)
	sync.replication_config = cfg
	# Same as the player: the replicated node is the synchronizer's parent.
	sync.root_path = NodePath("..")


func _add(cfg: SceneReplicationConfig, path: NodePath, repl_mode: int, on_spawn := false) -> void:
	if cfg.has_property(path):
		return
	cfg.add_property(path)
	cfg.property_set_replication_mode(path, repl_mode)
	cfg.property_set_spawn(path, on_spawn)
