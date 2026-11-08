extends Node3D

const PICKUP := preload("res://scenes/world/inventory_pickup.gd")
const WORLD_LAYER := 1
const GRAB_REACH := 3.0
const SLOT_ACTIONS := [&"inventory_slot_1", &"inventory_slot_2", &"inventory_slot_3"]

@onready var _spawner: MultiplayerSpawner = $Spawner
@onready var _items: Node3D = $Items
@onready var _players: Node3D = $"../Players"
@onready var _bar: HBoxContainer = $"../UI/Hud/InventoryBar"
@onready var _held_label: Label = $"../UI/Hud/HeldEquipment"
@onready var _aim_label: Label = $"../UI/Hud/EquipmentPrompt"

var _held: Dictionary[int, PICKUP] = {}
var _next_item := 0
var _was_hub := true
var _mouse_grabbing := false


func _ready() -> void:
	_spawner.spawn_function = _spawn_pickup
	GameState.player_life_changed.connect(_on_life_changed)
	GameState.player_left.connect(_release)
	GameState.state_changed.connect(_on_state_changed)


func _physics_process(_delta: float) -> void:
	if GameState.is_host():
		for peer_id in _held.keys():
			var player := _player(peer_id)
			if player == null:
				_release(peer_id)
				continue
			var item: PICKUP = _held[peer_id]
			item.global_position = _hand_position(player)
			item.rotation = Vector3(0.0, player.rotation.y, 0.0)

	var local := _player(SteamNet.local_peer_id)
	_bar.visible = _can_control(local)
	var item := _local_held() if _bar.visible else null
	var target := _aimed_item(local) if _bar.visible and item == null else null
	_set_text(_held_label, "В РУКЕ   /   %s" % _item_name(item) if item != null else "")
	var pickup_hint := "ВЗЯТЬ" if OS.has_feature("android") else "ЛКМ   Взять"
	_set_text(_aim_label, "•\n%s: %s" % [pickup_hint, _item_name(target)] if target != null else "")
	if _mouse_grabbing and not _bar.visible:
		_end_mouse_grab()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_released(&"inventory_grab") and _mouse_grabbing:
		_end_mouse_grab()
		get_viewport().set_input_as_handled()
		return
	var player := _player(SteamNet.local_peer_id)
	if not _can_control(player):
		return
	for slot in range(SLOT_ACTIONS.size()):
		if event.is_action_pressed(SLOT_ACTIONS[slot]):
			if GameState.is_host():
				_change_slot(SteamNet.local_peer_id, slot)
			else:
				_rpc_slot.rpc_id(1, slot)
			get_viewport().set_input_as_handled()
			return
	if event.is_action_pressed(&"inventory_grab"):
		var target := _aimed_item(player)
		var target_name := target.name if target != null else &""
		_mouse_grabbing = true
		if GameState.is_host():
			_press_grab(SteamNet.local_peer_id, target_name)
		else:
			_rpc_grab.rpc_id(1, target_name)
		get_viewport().set_input_as_handled()


func _end_mouse_grab() -> void:
	_mouse_grabbing = false
	if GameState.is_host():
		_release_mouse_item(SteamNet.local_peer_id)
	elif SteamNet.available():
		_rpc_release.rpc_id(1)


func _player(peer_id: int) -> Player:
	if not (GameState.phase == GameState.Phase.HUB_DAY or GameState.is_play_phase()):
		return null
	if GameState.is_dead(peer_id):
		return null
	return _players.get_node_or_null("Player%d" % peer_id) as Player


func _can_control(player: Player) -> bool:
	return player != null and player.is_multiplayer_authority() \
		and GameplayPointer.get_mode() == Input.MOUSE_MODE_CAPTURED and not player.viewing_security


func _local_held() -> PICKUP:
	if GameState.is_host():
		return _held.get(SteamNet.local_peer_id)
	for item: PICKUP in _items.get_children():
		if item.holder_id == SteamNet.local_peer_id and not item.is_queued_for_deletion():
			return item
	return null


func _aimed_item(player: Player) -> PICKUP:
	var origin := player.interaction_origin()
	var end := origin + player.interaction_direction() * GRAB_REACH
	var hit := _ray(origin, end, WORLD_LAYER | PICKUP.PICKUP_LAYER)
	return hit.get("collider") as PICKUP


func _ray(from: Vector3, to: Vector3, mask: int) -> Dictionary:
	return get_world_3d().direct_space_state.intersect_ray(
		PhysicsRayQueryParameters3D.create(from, to, mask))


func _hand_position(player: Player) -> Vector3:
	var origin := player.interaction_origin()
	var right := player.global_basis.x
	var end := origin + player.interaction_direction() * 0.95 + right * 0.24 - Vector3.UP * 0.22
	var hit := _ray(origin, end, WORLD_LAYER)
	if hit.is_empty():
		return end
	var contact: Vector3 = hit["position"]
	return contact.move_toward(origin, 0.22)


func _press_grab(peer_id: int, target_name: StringName) -> void:
	var player := _player(peer_id)
	if player == null:
		return
	if _held.has(peer_id):
		_release(peer_id)
		return
	if target_name.is_empty() or not String(target_name).is_valid_identifier():
		return
	var target := _items.get_node_or_null(NodePath(target_name)) as PICKUP
	if target == null or target.holder_id != 0 or target.is_queued_for_deletion():
		return
	var origin := player.interaction_origin()
	if origin.distance_to(target.global_position) > GRAB_REACH + 0.25:
		return
	if not _ray(origin, target.global_position, WORLD_LAYER).is_empty():
		return
	target.holder_id = peer_id
	target.mouse_grabbed = true
	_held[peer_id] = target


func _change_slot(peer_id: int, slot: int) -> void:
	var player := _player(peer_id)
	if player == null or slot < 0 or slot >= GameState.INVENTORY_SIZE:
		return
	var item_id := String(GameState.inventory_slots(peer_id)[slot])
	var in_hand: PICKUP = _held.get(peer_id)
	if item_id.is_empty():
		if in_hand != null:
			_held.erase(peer_id)
			in_hand.queue_free()
			GameState.server_set_inventory_slot(peer_id, slot, in_hand.item_id)
		return
	if not GameState.SHOP_ITEMS.has(item_id):
		return
	_next_item += 1
	var item := _spawner.spawn({
		"id": _next_item, "item": item_id, "holder": peer_id,
		"position": _hand_position(player),
	}) as PICKUP
	if item == null:
		return
	_release(peer_id)
	_held[peer_id] = item
	GameState.server_set_inventory_slot(peer_id, slot, "")


func _release_mouse_item(peer_id: int) -> void:
	var item: PICKUP = _held.get(peer_id)
	if item != null and item.mouse_grabbed:
		_release(peer_id)


func _release(peer_id: int) -> void:
	var item: PICKUP = _held.get(peer_id)
	if item != null:
		_held.erase(peer_id)
		item.holder_id = 0
		item.mouse_grabbed = false
		item.dropped_in_hub = GameState.phase == GameState.Phase.HUB_DAY


func _spawn_pickup(data: Variant) -> Node:
	var item := PICKUP.new()
	item.name = "Equipment%d" % int(data["id"])
	item.item_id = data["item"]
	item.holder_id = data["holder"]
	item.position = data["position"]
	var config := SceneReplicationConfig.new()
	config.add_property(^":position")
	config.property_set_replication_mode(^":position", SceneReplicationConfig.REPLICATION_MODE_ALWAYS)
	config.add_property(^":rotation")
	config.property_set_replication_mode(^":rotation", SceneReplicationConfig.REPLICATION_MODE_ALWAYS)
	config.add_property(^":holder_id")
	config.property_set_replication_mode(^":holder_id", SceneReplicationConfig.REPLICATION_MODE_ON_CHANGE)
	config.property_set_spawn(^":holder_id", true)
	var sync := MultiplayerSynchronizer.new()
	sync.replication_config = config
	sync.root_path = ^".."
	sync.replication_interval = 1.0 / 30.0
	item.add_child(sync)
	return item


func _on_life_changed(peer_id: int, dead: bool) -> void:
	if dead:
		_release(peer_id)


func _on_state_changed(_key: StringName) -> void:
	var hub := GameState.phase == GameState.Phase.HUB_DAY
	if GameState.is_host() and hub and not _was_hub:
		for item: PICKUP in _items.get_children():
			if item.holder_id == 0 and not item.dropped_in_hub:
				item.queue_free()
	_was_hub = hub


func _item_name(item: PICKUP) -> String:
	return GameState.SHOP_ITEMS[item.item_id]["name"]


func _set_text(label: Label, text: String) -> void:
	if label.text != text:
		label.text = text


@rpc("any_peer", "call_remote", "reliable")
func _rpc_slot(slot: int) -> void:
	if GameState.is_host():
		_change_slot(multiplayer.get_remote_sender_id(), slot)


@rpc("any_peer", "call_remote", "reliable")
func _rpc_grab(target_name: StringName) -> void:
	if GameState.is_host():
		_press_grab(multiplayer.get_remote_sender_id(), target_name)


@rpc("any_peer", "call_remote", "reliable")
func _rpc_release() -> void:
	if GameState.is_host():
		_release_mouse_item(multiplayer.get_remote_sender_id())
