class_name Basket
extends Node3D

## The haul cart: scrap and bodies ride in it, and the whole thing is dragged to the ship.
## Server-owned like the corpse, so two peers cannot disagree about where the loot is.

var carried_by := 0
var cargo_cents := 0


func _enter_tree() -> void:
	# Before the first replication packet, same reason as the corpse.
	_setup_replication()


func _ready() -> void:
	add_to_group("baskets")


func _setup_replication() -> void:
	var sync := get_node_or_null("Sync") as MultiplayerSynchronizer
	if sync == null:
		return
	var cfg := SceneReplicationConfig.new()
	_add(cfg, NodePath(":position"), SceneReplicationConfig.REPLICATION_MODE_ALWAYS)
	_add(cfg, NodePath(":rotation:y"), SceneReplicationConfig.REPLICATION_MODE_ALWAYS)
	_add(cfg, NodePath(":carried_by"), SceneReplicationConfig.REPLICATION_MODE_ON_CHANGE, true)
	_add(cfg, NodePath(":cargo_cents"), SceneReplicationConfig.REPLICATION_MODE_ON_CHANGE, true)
	sync.replication_config = cfg
	sync.root_path = NodePath("..")


func _add(cfg: SceneReplicationConfig, path: NodePath, repl_mode: int, on_spawn := false) -> void:
	if cfg.has_property(path):
		return
	cfg.add_property(path)
	cfg.property_set_replication_mode(path, repl_mode)
	cfg.property_set_spawn(path, on_spawn)