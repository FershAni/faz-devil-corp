class_name Corpse
extends Node3D

## The body left exactly where the hunter took it. The host owns it: a teammate dragging it
## or the basket carrying it moves it on the server, and every peer only renders the result.
## There is no timer here - the crew decides whether the body comes home.

var owner_peer := 0
var carried_by := 0
var in_basket := false

var _cam: Camera3D


func _enter_tree() -> void:
	# Config must exist before the first replication packet: a late joiner receives this
	# node already spawned, and _ready would be too late for it.
	_setup_replication()


func _ready() -> void:
	add_to_group("corpses")
	# Lying on its side: the capsule stands in the scene, the body does not stand in the world.
	get_node("Body").rotation.z = deg_to_rad(90.0)
	_cam = get_node_or_null("Camera") as Camera3D
	if _cam != null:
		_cam.rotation.y = deg_to_rad(-90.0)


func _process(_delta: float) -> void:
	# The dead peer watches the room from the floor; nobody else loses their own camera.
	# Written only when it flips: every corpse is in the tree all night.
	var mine := SteamNet.local_peer_id == owner_peer
	if _cam != null and _cam.current != mine:
		_cam.current = mine


func _setup_replication() -> void:
	var sync := get_node_or_null("Sync") as MultiplayerSynchronizer
	if sync == null:
		return
	var cfg := SceneReplicationConfig.new()
	_add(cfg, NodePath(":position"), SceneReplicationConfig.REPLICATION_MODE_ALWAYS)
	_add(cfg, NodePath(":rotation:y"), SceneReplicationConfig.REPLICATION_MODE_ALWAYS)
	_add(cfg, NodePath(":owner_peer"), SceneReplicationConfig.REPLICATION_MODE_ON_CHANGE, true)
	_add(cfg, NodePath(":carried_by"), SceneReplicationConfig.REPLICATION_MODE_ON_CHANGE, true)
	_add(cfg, NodePath(":in_basket"), SceneReplicationConfig.REPLICATION_MODE_ON_CHANGE, true)
	sync.replication_config = cfg
	sync.root_path = NodePath("..")


func _add(cfg: SceneReplicationConfig, path: NodePath, repl_mode: int, on_spawn := false) -> void:
	if cfg.has_property(path):
		return
	cfg.add_property(path)
	cfg.property_set_replication_mode(path, repl_mode)
	cfg.property_set_spawn(path, on_spawn)