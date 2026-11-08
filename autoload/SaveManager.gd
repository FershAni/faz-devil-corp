extends Node
## Host-owned campaign checkpoints. Session state (seed, avatars, loose cargo and
## tablet charge) is rebuilt when the crew starts a new session.

signal peer_ready(peer_id: int)
signal avatar_viewer_ready(peer_id: int)
signal checkpoint_failed(error: Error)

const SLOT_COUNT: int = 3
const VERSION: int = 1
const JOIN_TIMEOUT_MS: int = 15000
const MAX_FILE_BYTES: int = 1024 * 1024

var active_slot: int = 0

var _profile: String = ""
var _staged: Dictionary = {}
class JoinPermit:
	var ticket: int
	var deadline: int


var _pending: Dictionary[int, JoinPermit] = {}
var _ready_peers: Dictionary[int, bool] = {}
var _avatar_viewers: Dictionary[int, bool] = {}
var _ticket: int = 0
var _client_ticket: int = 0
var _client_world_ready: bool = false
var _wallets: Dictionary[String, Dictionary] = {}


func _ready() -> void:
	# Autoload order is significant: GameState resets before we apply the selected slot.
	SteamNet.session_started.connect(_on_session_started)
	SteamNet.session_ended.connect(func(_reason: String) -> void: _clear_session())
	SteamNet.player_connected.connect(_on_player_connected)
	SteamNet.player_disconnected.connect(_on_player_disconnected)


func profile_key() -> String:
	return str(SteamNet.local_steam_id) if SteamNet.local_steam_id > 0 else "offline"


func slot_summary(slot: int) -> Dictionary:
	if slot < 1 or slot > SLOT_COUNT:
		return {"error": ERR_INVALID_PARAMETER}
	return _read_slot(_slot_path(profile_key(), slot))


func has_slot_files(slot: int) -> bool:
	if slot < 1 or slot > SLOT_COUNT:
		return false
	var path: String = _slot_path(profile_key(), slot)
	return FileAccess.file_exists(path) or FileAccess.file_exists(path + ".bak")


## Remove the recovery copy first so a deleted slot cannot reappear on refresh.
func delete_slot(slot: int) -> Error:
	if SteamNet.available() or active_slot != 0 or slot < 1 or slot > SLOT_COUNT:
		return ERR_INVALID_PARAMETER
	var path: String = ProjectSettings.globalize_path(_slot_path(profile_key(), slot))
	for candidate: String in [path + ".bak", path]:
		if FileAccess.file_exists(candidate):
			var error: Error = DirAccess.remove_absolute(candidate)
			if error != OK:
				return error
	return OK


func slot_caption(slot: int, result: Dictionary) -> String:
	var caption: String = "Пустой слот"
	match int(result["error"]):
		OK:
			var data: Dictionary = result["data"]
			caption = "День %d  ·  Квота $%d / $%d  ·  Касса $%d  ·  Уют %d" % [
				data["day"], data["earnings"], data["quota"], data["business_balance"], data["cozy"]]
			if bool(result.get("recovered", false)):
				caption += "  ·  Резервная копия"
		ERR_FILE_NOT_FOUND:
			pass
		_:
			caption = "Сохранение недоступно"
	return "СЛОТ %d\n%s" % [slot, caption]


## Select and validate a checkpoint before Steam receives a lobby creation request.
## A missing file starts a campaign. A damaged file never starts one implicitly.
func select_slot(slot: int) -> Error:
	if SteamNet.available() or slot < 1 or slot > SLOT_COUNT:
		return ERR_INVALID_PARAMETER
	var profile: String = profile_key()
	var path: String = _slot_path(profile, slot)
	var result: Dictionary = _read_slot(path)
	var error: Error = int(result["error"]) as Error
	var campaign: Dictionary = result.get("data", {})
	if error == ERR_FILE_NOT_FOUND:
		campaign = {
			"day": 1, "quota_index": 0, "quota": GameState.QUOTA_BY_CYCLE[0],
			"earnings": 0, "debt": 0, "cozy": 0,
			"business_balance": GameState.STARTING_BUSINESS_BALANCE,
			"daytime_report": {}, "decorations": [],
			"wallets": {profile: {"balance": GameState.STARTING_BALANCE, "items": []}},
			"invasion_pending": false,
		}
		error = _commit(path, campaign)
	if error == OK:
		active_slot = slot
		_profile = profile
		_staged = campaign
	return error


func cancel_selection() -> void:
	if not SteamNet.available():
		_clear_session()


## Called synchronously at the transaction boundary, before a payout is published.
## No selected slot is valid for the existing unsaved developer/LAN entry point.
func checkpoint() -> Error:
	if not SteamNet.is_host or not GameState.is_host():
		return ERR_UNAUTHORIZED
	if active_slot == 0:
		return OK
	return _write_checkpoint(active_slot, _profile)


## Switch the autosave target only after the selected file has been written.
func save_to_slot(slot: int) -> Error:
	if not SteamNet.is_host or not GameState.is_host() or not SteamNet.available():
		return ERR_UNAUTHORIZED
	if slot < 1 or slot > SLOT_COUNT:
		return ERR_INVALID_PARAMETER
	var profile: String = profile_key()
	var status: int = int(_read_slot(_slot_path(profile, slot))["error"])
	if status not in [OK, ERR_FILE_NOT_FOUND]:
		return status as Error
	var error: Error = _write_checkpoint(slot, profile)
	if error == OK:
		_profile = profile
		active_slot = slot
	return error


func _write_checkpoint(slot: int, profile: String) -> Error:
	var campaign: Dictionary = GameState.campaign_snapshot()
	var wallets: Dictionary[String, Dictionary] = _wallets.duplicate(true)
	for peer_id: int in GameState.players:
		_capture_wallet(wallets, peer_id, GameState.wallet(peer_id), profile)
	campaign["wallets"] = wallets
	var error: Error = _commit(_slot_path(profile, slot), campaign)
	if error == OK:
		_wallets = wallets
	else:
		push_error("Save slot %d: %s" % [slot, error_string(error)])
		checkpoint_failed.emit(error)
	return error


func restored_wallet(peer_id: int, steam_id: int) -> Dictionary:
	return _wallets.get(_wallet_key(peer_id, steam_id, _profile), {}).duplicate(true)


func remember_wallet(peer_id: int, wallet: Dictionary) -> void:
	if SteamNet.is_host and active_slot > 0:
		_capture_wallet(_wallets, peer_id, wallet, _profile)


func _capture_wallet(wallets: Dictionary[String, Dictionary], peer_id: int, wallet: Dictionary, profile: String) -> void:
	var key: String = _wallet_key(peer_id, int(wallet.get("steam_id", 0)), profile)
	if not key.is_empty():
		wallets[key] = {"balance": int(wallet.get("balance", 0)), "items": wallet.get("items", []).duplicate()}


func _wallet_key(peer_id: int, steam_id: int, profile: String) -> String:
	if steam_id > 0:
		return str(steam_id)
	return "offline" if peer_id == 1 and profile == "offline" else ""


func _slot_path(profile: String, slot: int) -> String:
	return "user://saves/%s/slot_%d.cfg" % [profile, slot]


func _read_slot(path: String) -> Dictionary:
	var primary: Dictionary = _read_file(path)
	if int(primary["error"]) in [OK, ERR_FILE_UNRECOGNIZED]:
		return primary
	var backup: Dictionary = _read_file(path + ".bak")
	if int(backup["error"]) == OK:
		backup["recovered"] = true
		return backup
	return primary if int(primary["error"]) != ERR_FILE_NOT_FOUND else backup


func _read_file(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {"error": ERR_FILE_NOT_FOUND}
	if FileAccess.get_size(path) > MAX_FILE_BYTES:
		return {"error": ERR_FILE_CORRUPT}
	var file: ConfigFile = ConfigFile.new()
	var error: Error = file.load(path)
	if error != OK:
		return {"error": error}
	if file.get_value("slot", "version", 0) != VERSION:
		return {"error": ERR_FILE_UNRECOGNIZED}
	var data: Dictionary = {}
	for key: String in ["day", "quota_index", "quota", "earnings", "debt", "cozy", "business_balance"]:
		var value: Variant = file.get_value("campaign", key, null)
		if typeof(value) != TYPE_INT or int(value) < 0:
			return {"error": ERR_FILE_CORRUPT}
		data[key] = value
	if int(data["day"]) < 1 or int(data["quota"]) < 1 or int(data["quota_index"]) >= GameState.QUOTA_BY_CYCLE.size():
		return {"error": ERR_FILE_CORRUPT}
	var encoded: Variant = file.get_value("campaign", "decorations_json", null)
	if typeof(encoded) != TYPE_STRING:
		return {"error": ERR_FILE_CORRUPT}
	var decoded: Variant = JSON.parse_string(String(encoded))
	if typeof(decoded) != TYPE_ARRAY:
		return {"error": ERR_FILE_CORRUPT}
	var decorations: Array[Dictionary] = []
	var ids: Dictionary[int, bool] = {}
	for raw: Variant in decoded:
		if typeof(raw) != TYPE_DICTIONARY:
			return {"error": ERR_FILE_CORRUPT}
		var item: Dictionary = raw
		var item_id: Variant = item.get("item_id")
		var grid: Variant = item.get("grid_position")
		var damaged: Variant = item.get("damaged")
		if not _valid_id(item_id) or typeof(grid) != TYPE_ARRAY or grid.size() != 3 \
			or typeof(damaged) != TYPE_BOOL or ids.has(int(item_id)):
			return {"error": ERR_FILE_CORRUPT}
		for axis: Variant in grid:
			if typeof(axis) not in [TYPE_INT, TYPE_FLOAT] or not is_finite(float(axis)) or absf(float(axis)) > 10000.0:
				return {"error": ERR_FILE_CORRUPT}
		var id: int = int(item_id)
		ids[id] = true
		decorations.append({"item_id": id, "grid_position": Vector3(grid[0], grid[1], grid[2]), "damaged": damaged})
	data["decorations"] = decorations
	var report: Variant = file.get_value("campaign", "daytime_report", {})
	var wallets: Variant = file.get_value("campaign", "wallets", {})
	var pending: Variant = file.get_value("campaign", "invasion_pending", false)
	if typeof(report) != TYPE_DICTIONARY or typeof(wallets) != TYPE_DICTIONARY or typeof(pending) != TYPE_BOOL:
		return {"error": ERR_FILE_CORRUPT}
	if not report.is_empty():
		for key: String in ["day", "sales", "tips", "penalties", "cozy_level", "balance"]:
			if typeof(report.get(key)) != TYPE_INT or int(report[key]) < 0:
				return {"error": ERR_FILE_CORRUPT}
		if int(report["day"]) != int(data["day"]):
			return {"error": ERR_FILE_CORRUPT}
	for key: Variant in wallets:
		var wallet: Variant = wallets[key]
		if typeof(key) != TYPE_STRING or (key != "offline" and not String(key).is_valid_int()) \
			or typeof(wallet) != TYPE_DICTIONARY or typeof(wallet.get("balance")) != TYPE_INT \
			or int(wallet["balance"]) < 0 or typeof(wallet.get("items")) != TYPE_ARRAY:
			return {"error": ERR_FILE_CORRUPT}
		for item: Variant in wallet["items"]:
			if typeof(item) != TYPE_STRING or (item != "" and not GameState.SHOP_ITEMS.has(item)):
				return {"error": ERR_FILE_CORRUPT}
	data["daytime_report"] = report
	data["wallets"] = wallets
	data["invasion_pending"] = pending
	var damage: Variant = file.get_value("campaign", "damaged_fixtures", PackedInt32Array())
	if typeof(damage) != TYPE_PACKED_INT32_ARRAY:
		return {"error": ERR_FILE_CORRUPT}
	data["damaged_fixtures"] = damage
	return {"error": OK, "data": data}


func _valid_id(value: Variant) -> bool:
	return typeof(value) in [TYPE_INT, TYPE_FLOAT] and is_finite(float(value)) \
		and float(value) == floorf(float(value)) and float(value) > 0.0 and float(value) <= 2147483647.0


## Write beside the target, verify the complete payload, then rotate and promote.
## If the process stops between the renames, the previous checkpoint is in .bak.
func _commit(path: String, campaign: Dictionary) -> Error:
	var absolute: String = ProjectSettings.globalize_path(path)
	var error: Error = DirAccess.make_dir_recursive_absolute(absolute.get_base_dir())
	if error != OK:
		return error
	var file: ConfigFile = ConfigFile.new()
	file.set_value("slot", "version", VERSION)
	for key: String in campaign:
		if key != "decorations":
			file.set_value("campaign", key, campaign[key])
	var decorations: Array[Dictionary] = []
	for item: Dictionary in campaign["decorations"]:
		var grid: Vector3 = item["grid_position"]
		decorations.append({"item_id": item["item_id"], "grid_position": [grid.x, grid.y, grid.z], "damaged": item["damaged"]})
	file.set_value("campaign", "decorations_json", JSON.stringify(decorations))
	var temporary: String = "%s.%d.tmp" % [absolute, OS.get_process_id()]
	error = file.save(temporary)
	if error != OK:
		return error
	error = int(_read_file(temporary)["error"]) as Error
	if error != OK:
		return error
	var backup: String = absolute + ".bak"
	if FileAccess.file_exists(absolute):
		if int(_read_file(absolute)["error"]) == OK:
			error = DirAccess.rename_absolute(absolute, backup)
		else:
			# Keep the last known good backup when recovering a corrupt primary.
			error = DirAccess.remove_absolute(absolute)
		if error != OK:
			return error
	return DirAccess.rename_absolute(temporary, absolute)


func _on_session_started(host: bool, _transport: StringName) -> void:
	if not host:
		_clear_session()
		return
	if not _staged.is_empty():
		var stored: Dictionary = _staged["wallets"]
		_wallets.assign(stored)
		GameState.apply_campaign(_staged)
		_staged.clear()


func _clear_session() -> void:
	active_slot = 0
	_profile = ""
	_staged = {}
	_wallets.clear()
	_pending.clear()
	_ready_peers.clear()
	_avatar_viewers.clear()
	_client_ticket = 0
	_client_world_ready = false


func _on_player_connected(peer_id: int, _meta: Dictionary) -> void:
	if not SteamNet.is_host or peer_id == 1:
		return
	_ticket += 1
	var permit: JoinPermit = JoinPermit.new()
	permit.ticket = _ticket
	permit.deadline = Time.get_ticks_msec() + JOIN_TIMEOUT_MS
	_pending[peer_id] = permit
	sync_global_game_state.rpc(GameState.network_snapshot(), peer_id, _ticket)


## Lives at /root/SaveManager on every peer. Existing clients update immediately.
## A joiner acknowledges only after its Game scene and spawner exist.
@rpc("authority", "call_remote", "reliable")
func sync_global_game_state(snapshot: Dictionary, joining_peer: int, ticket: int) -> void:
	if SteamNet.is_host or multiplayer.get_remote_sender_id() != 1:
		return
	GameState.apply_network_snapshot(snapshot)
	if joining_peer == multiplayer.get_unique_id():
		_client_ticket = ticket
		_ack_if_ready()


func client_world_ready() -> void:
	_client_world_ready = true
	_ack_if_ready()


func _ack_if_ready() -> void:
	if not _client_world_ready or _client_ticket == 0:
		return
	var error: Error = multiplayer.rpc(1, self, &"_confirm_snapshot", [_client_ticket])
	if error == OK:
		_client_ticket = 0


@rpc("any_peer", "call_remote", "reliable")
func _confirm_snapshot(ticket: int) -> void:
	var peer_id: int = multiplayer.get_remote_sender_id()
	if not SteamNet.is_host or peer_id <= 1 or not _pending.has(peer_id) or _pending[peer_id].ticket != ticket:
		return
	_pending.erase(peer_id)
	_ready_peers[peer_id] = true
	peer_ready.emit(peer_id)


func can_spawn_for(peer_id: int) -> bool:
	return peer_id == 1 or _ready_peers.has(peer_id)


## Client-owned avatar sync must also wait for the viewer's local node path.
## A viewer only authorizes replication to itself after that avatar is ready.
func confirm_avatar_visible(owner_id: int) -> void:
	if not SteamNet.is_host and owner_id > 1 and owner_id != multiplayer.get_unique_id():
		_confirm_avatar_viewer.rpc_id(owner_id)


@rpc("any_peer", "call_remote", "reliable")
func _confirm_avatar_viewer() -> void:
	var viewer: int = multiplayer.get_remote_sender_id()
	if SteamNet.is_host or viewer <= 1 or _avatar_viewers.has(viewer):
		return
	_avatar_viewers[viewer] = true
	avatar_viewer_ready.emit(viewer)


func can_send_avatar_to(peer_id: int) -> bool:
	return peer_id == 1 or _avatar_viewers.has(peer_id)


func _on_player_disconnected(peer_id: int) -> void:
	_pending.erase(peer_id)
	_ready_peers.erase(peer_id)
	_avatar_viewers.erase(peer_id)


func _process(_delta: float) -> void:
	for peer_id: int in _pending.keys():
		if Time.get_ticks_msec() >= _pending[peer_id].deadline:
			_pending.erase(peer_id)
			multiplayer.multiplayer_peer.disconnect_peer(peer_id)

