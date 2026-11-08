class_name Tablet
extends CanvasLayer
## Local input and camera presentation plus the server's tablet command handler.
## The SceneTree path /root/Game/UI/Tablet stays identical on every peer.

const SCAN_COST: float = 2.0
const SCAN_RADIUS: float = 15.0
const AUDIO_COST: float = 4.0
const EMP_COST: float = 10.0
const VENT_COST: float = 8.0
const RELOAD_MS: int = 3000
const RELOAD_TIMEOUT_MS: int = 6500
const DECOY: AudioStream = preload("res://audio/tablet_laugh.wav")
const SWAP: AudioStream = preload("res://audio/tablet_swap.wav")

class Reload:
	var started: int
	var committed: bool = false

@onready var _ui: TabletUI = $Root

var _crew: Node3D
var _level: LevelGenerator
var _daytime: DaytimeManager
var _invasion: HubInvasion
var _security: SecurityOffice
var _ship: Vector3
var _phase: int = -1
var _open: bool = false
var _mouse_before: Input.MouseMode
var _blurred_camera: Camera3D
var _original_attributes: CameraAttributes
var _blur_attributes: CameraAttributesPractical
var _held_since: int = -1
var _map_tick: float = 0.0
var _ping_ms: int = -1
var _ping_sent: int = -1
var _next_ping: int = 0
var _remote_open: Dictionary[int, bool] = {}
var _charge: Dictionary[int, float] = {}
var _busy: Dictionary[int, Reload] = {}
var _reload_flags: Dictionary[int, bool] = {}
var _next_command: Dictionary[int, int] = {}
var _next_probe: Dictionary[int, int] = {}
var _next_room_audio: int = 0
var _next_transport: int = 0
var _sound: AudioStreamPlayer3D
var _swap_sound: AudioStreamPlayer3D


func _ready() -> void:
	_ui.close_requested.connect(close)
	_ui.command_requested.connect(_send)
	get_window().focus_exited.connect(_cancel_reload)
	_blur_attributes = CameraAttributesPractical.new()
	_blur_attributes.dof_blur_far_enabled = true
	_blur_attributes.dof_blur_far_distance = 0.55
	_blur_attributes.dof_blur_far_transition = 1.5
	_blur_attributes.dof_blur_amount = 0.24


func configure(daytime: DaytimeManager, level: LevelGenerator, pizzeria: Pizzeria,
		crew: Node3D, invasion: HubInvasion, ship: Vector3) -> void:
	_daytime = daytime
	_level = level
	_crew = crew
	_invasion = invasion
	_security = pizzeria.security
	_ship = ship
	_sound = _new_sound(pizzeria, DECOY)
	_swap_sound = _new_sound(pizzeria, SWAP)
	_ui.configure(daytime, level, _security, crew, invasion)
	_set_phase()
	GameState.state_changed.connect(_on_state)
	GameState.player_left.connect(_on_player_left)
	GameState.player_life_changed.connect(_on_life_changed)
	SaveManager.peer_ready.connect(_on_peer_ready)


func is_open() -> bool:
	return _open


func uses_security_feed() -> bool:
	return _open and GameState.phase == GameState.Phase.HUB_INVASION


func toggle() -> void:
	toggle_tablet()


func toggle_tablet() -> void:
	if _open:
		close()
	else:
		open()


func open() -> void:
	if _open or _crew == null or not SteamNet.available() or not GameState.is_world_phase() \
		or _blocking_overlay():
		return
	_open = true
	_mouse_before = GameplayPointer.get_mode()
	GameplayPointer.set_mode(Input.MOUSE_MODE_VISIBLE)
	_ui.show_device()
	_ui.activate_feed()
	_update_depth_of_field()
	_send(&"open")


func close() -> void:
	if not _open:
		return
	_cancel_reload()
	_send(&"close")
	_open = false
	_ui.hide_device()
	_restore_depth_of_field()
	GameplayPointer.set_mode(_mouse_before)


func _blocking_overlay() -> bool:
	var scene: Node = get_tree().current_scene
	if scene == null:
		return true
	var pause: PauseMenu = scene.get_node_or_null("UI/Pause") as PauseMenu
	var shop: ShopMenu = scene.get_node_or_null("UI/Shop") as ShopMenu
	var daytime: Control = scene.get_node_or_null("UI/DaytimeCenter/DaytimePanel") as Control
	var security: Control = scene.get_node_or_null("UI/SecurityView") as Control
	return (pause != null and pause.is_open()) or (shop != null and shop.is_open()) \
		or (daytime != null and daytime.visible) or (security != null and security.visible)


func _exit_tree() -> void:
	_restore_depth_of_field()


func _input(event: InputEvent) -> void:
	if not _open:
		return
	if event.is_action_pressed(&"UI_Cancel"):
		close()
		get_viewport().set_input_as_handled()
	elif event.is_action(&"reload_battery"):
		if event.is_action_pressed(&"reload_battery") and not event.is_echo():
			if _held_since < 0 and not GameState.is_dead(SteamNet.local_peer_id):
				_start_local_reload()
		elif event.is_action_released(&"reload_battery"):
			_cancel_reload()
		get_viewport().set_input_as_handled()


func _unhandled_input(event: InputEvent) -> void:
	if is_toggle_event(event):
		toggle_tablet()
		get_viewport().set_input_as_handled()


static func is_toggle_event(event: InputEvent) -> bool:
	return not event.is_echo() and (event.is_action_pressed(&"toggle_tablet") or event.is_action_pressed(&"open_tablet"))


func _process(delta: float) -> void:
	if _crew == null:
		return
	var now: int = Time.get_ticks_msec()
	if _phase == GameState.Phase.NIGHT_SCAVENGE:
		_map_tick -= delta
		if _map_tick <= 0.0:
			_map_tick = 0.07 if _open else 0.20
			_ui.track_map()
	if not _open:
		return
	_update_depth_of_field()
	var progress: float = -1.0
	if _held_since >= 0:
		progress = clampf(float(now - _held_since) / RELOAD_MS, 0.0, 1.0)
		if now - _held_since >= RELOAD_MS:
			_held_since = -1
			_send(&"reload_commit")
	if not GameState.is_host() and now >= _next_ping and _connected():
		_next_ping = now + 2000
		_ping_sent = now
		_probe.rpc_id(1, now)
	var interference: float = clampf(maxf(0.0, float(_ping_ms)) / 450.0, 0.0, 0.60)
	var player: Player = _player(SteamNet.local_peer_id)
	if player != null:
		var hunter: Node3D = _crew.get_node_or_null("BlindHunter") as Node3D
		if hunter != null:
			interference += 0.68 * (1.0 - clampf(hunter.global_position.distance_to(player.global_position) / 16.0, 0.0, 1.0))
		interference += 0.78 * _invasion.interference_at(player.global_position)
	_ui.refresh(delta, _charge, _reload_flags, progress, _ping_ms, clampf(interference, 0.0, 1.0))


func _physics_process(_delta: float) -> void:
	if _crew == null or not SteamNet.is_host:
		return
	var now: int = Time.get_ticks_msec()
	for peer_id: int in _busy.keys():
		var reload: Reload = _busy[peer_id]
		if not _can_operate(peer_id) or now - reload.started >= RELOAD_TIMEOUT_MS:
			_clear_reload(peer_id)
		elif reload.committed and now - reload.started >= RELOAD_MS:
			_complete_reload(peer_id)


func _on_state(_key: StringName) -> void:
	_set_phase()


func _set_phase() -> void:
	if _phase == GameState.phase:
		return
	_phase = GameState.phase
	_cancel_reload()
	if SteamNet.is_host and not _busy.is_empty():
		_busy.clear()
		_reload_flags.clear()
		_publish_power()
	_ui.set_phase(_phase)
	if _open and not GameState.is_world_phase():
		close()


func _on_life_changed(peer_id: int, dead: bool) -> void:
	if dead:
		if SteamNet.is_host:
			_clear_reload(peer_id)
		if peer_id == SteamNet.local_peer_id:
			_cancel_reload()


func _on_peer_ready(peer_id: int) -> void:
	if SteamNet.is_host:
		_sync_power.rpc_id(peer_id, _charge, _reload_flags)


func _on_player_left(peer_id: int) -> void:
	_remote_open.erase(peer_id)
	_charge.erase(peer_id)
	_busy.erase(peer_id)
	_reload_flags.erase(peer_id)
	_next_command.erase(peer_id)
	_next_probe.erase(peer_id)
	if SteamNet.is_host:
		_publish_power.call_deferred()


func _send(command: StringName, camera: String = "") -> void:
	if GameState.is_host():
		_handle(1, command, camera)
	elif _connected():
		_request.rpc_id(1, _phase, GameState.day_index, command, camera)


@rpc("any_peer", "call_remote", "reliable")
func _request(phase: int, day: int, command: StringName, camera: String) -> void:
	var peer_id: int = multiplayer.get_remote_sender_id()
	if not SteamNet.is_host or peer_id <= 1 or not SaveManager.can_spawn_for(peer_id) \
		or phase != GameState.phase or day != GameState.day_index:
		return
	_handle(peer_id, command, camera)


func _handle(peer_id: int, command: StringName, camera: String) -> void:
	if command == &"close":
		_remote_open.erase(peer_id)
		_clear_reload(peer_id)
		return
	if command == &"open":
		_remote_open[peer_id] = GameState.is_world_phase() and GameState.players.has(peer_id)
		return
	if command == &"reload_cancel":
		_clear_reload(peer_id)
		return
	if not _can_operate(peer_id):
		return
	if command == &"reload_commit":
		var reload: Reload = _busy.get(peer_id)
		if reload != null:
			reload.committed = true
		return
	var now: int = Time.get_ticks_msec()
	if now < _next_command.get(peer_id, 0):
		return
	_next_command[peer_id] = now + 330
	match command:
		&"reload_begin":
			_begin_reload(peer_id, now)
		&"scan":
			if _phase == GameState.Phase.NIGHT_SCAVENGE and _level.has_layout(GameState.map_seed) and _spend(peer_id, SCAN_COST):
				var point: Vector3 = _player(peer_id).global_position
				if peer_id == 1:
					_ui.receive_scan(point, SCAN_RADIUS)
				else:
					_show_scan.rpc_id(peer_id, point)
		&"transport":
			if _phase == GameState.Phase.NIGHT_SCAVENGE and _charge.get(peer_id, 100.0) > 0.0 and now >= _next_transport:
				_next_transport = now + 3500
				_ui.receive_transport(_ship)
				_show_transport.rpc(_ship)
		&"audio":
			if _phase == GameState.Phase.HUB_INVASION and _security.camera_ids().has(camera) \
				and now >= _next_room_audio and _spend(peer_id, AUDIO_COST):
				_next_room_audio = now + 5500
				_invasion.server_decoy(camera)
				var point: Vector3 = _security.camera_target(camera)
				_play_positional_audio(point, true)
				_noise_event.rpc(point, true)
		&"emp":
			if _phase == GameState.Phase.HUB_INVASION and camera == HubInvasion.GENERATOR_CAMERA \
				and _charge.get(peer_id, 100.0) >= EMP_COST and _invasion.server_emp():
				_spend(peer_id, EMP_COST)
		&"vent":
			if _phase == GameState.Phase.HUB_DAY and _charge.get(peer_id, 100.0) >= VENT_COST \
				and _daytime.server_vent_stage():
				_spend(peer_id, VENT_COST)


func _start_local_reload() -> void:
	if GameState.tablet_battery >= 100.0:
		_ui.set_notice("Батарея полностью заряжена")
		return
	var slot: int = GameState.inventory_slots(SteamNet.local_peer_id).find("battery")
	if slot < 0 or slot >= GameState.INVENTORY_SIZE:
		_ui.set_notice("Нет запасной батареи в слотах снаряжения")
		return
	_held_since = Time.get_ticks_msec()
	_send(&"reload_begin")


func _begin_reload(peer_id: int, now: int) -> void:
	if _busy.has(peer_id):
		return
	if _charge.get(peer_id, 100.0) >= 100.0:
		_notice_peer(peer_id, "Батарея полностью заряжена")
		return
	var slot: int = GameState.inventory_slots(peer_id).find("battery")
	if slot < 0 or slot >= GameState.INVENTORY_SIZE:
		_notice_peer(peer_id, "Нет запасной батареи в слотах снаряжения")
		return
	var reload: Reload = Reload.new()
	reload.started = now
	_busy[peer_id] = reload
	_reload_flags[peer_id] = true
	_publish_power()


func _complete_reload(peer_id: int) -> void:
	var slot: int = GameState.inventory_slots(peer_id).find("battery")
	if slot < 0 or slot >= GameState.INVENTORY_SIZE:
		_clear_reload(peer_id)
		_notice_peer(peer_id, "Нет запасной батареи в слотах снаряжения")
		return
	GameState.server_set_inventory_slot(peer_id, slot, "")
	_charge[peer_id] = 100.0
	_clear_reload(peer_id)
	# AI reacts on the host immediately. The reliable event lets peers hear the
	# same click at the host-observed position and cannot be invoked by a client.
	GameState.server_register_noise(85.0, Player.NoiseKind.BATTERY_CLICK, peer_id)
	var point: Vector3 = _player(peer_id).global_position
	_play_positional_audio(point, false)
	_noise_event.rpc(point, false)
	_notice_peer(peer_id, "Батарея заменена")


func _cancel_reload() -> void:
	if _held_since < 0:
		return
	_held_since = -1
	_send(&"reload_cancel")


func _clear_reload(peer_id: int) -> void:
	if _busy.erase(peer_id):
		_reload_flags.erase(peer_id)
		_publish_power()


func _can_operate(peer_id: int) -> bool:
	var player: Player = _player(peer_id)
	return _remote_open.get(peer_id, false) and GameState.is_world_phase() \
		and GameState.players.has(peer_id) and not GameState.is_dead(peer_id) and player != null \
		and player.global_position.is_finite()


func _spend(peer_id: int, amount: float) -> bool:
	var battery: float = _charge.get(peer_id, 100.0)
	if battery < amount:
		_notice_peer(peer_id, "Недостаточно заряда планшета")
		return false
	_charge[peer_id] = battery - amount
	_publish_power()
	return true


func _publish_power() -> void:
	if not SteamNet.is_host:
		return
	GameState.tablet_battery = _charge.get(1, 100.0)
	_sync_power.rpc(_charge, _reload_flags)


@rpc("authority", "call_remote", "reliable")
func _sync_power(charges: Dictionary, reloading: Dictionary) -> void:
	if not _from_host():
		return
	_charge.assign(charges)
	_reload_flags.assign(reloading)
	GameState.tablet_battery = _charge.get(multiplayer.get_unique_id(), 100.0)


@rpc("authority", "call_remote", "reliable")
func _show_scan(point: Vector3) -> void:
	if _from_host():
		_ui.receive_scan(point, SCAN_RADIUS)


@rpc("authority", "call_remote", "reliable")
func _show_transport(point: Vector3) -> void:
	if _from_host():
		_ui.receive_transport(point)


@rpc("authority", "call_remote", "reliable")
func _noise_event(point: Vector3, is_decoy: bool) -> void:
	if _from_host():
		_play_positional_audio(point, is_decoy)


func _play_positional_audio(point: Vector3, is_decoy: bool) -> void:
	var audio: AudioStreamPlayer3D = _sound if is_decoy else _swap_sound
	audio.global_position = point + Vector3.UP
	audio.play()


func _new_sound(parent: Node3D, stream: AudioStream) -> AudioStreamPlayer3D:
	var audio: AudioStreamPlayer3D = AudioStreamPlayer3D.new()
	audio.stream = stream
	audio.bus = &"SFX"
	audio.max_distance = 26.0
	audio.unit_size = 4.0
	audio.max_polyphony = 2
	parent.add_child(audio)
	return audio


func _notice_peer(peer_id: int, message: String) -> void:
	if peer_id == 1:
		_ui.set_notice(message)
	else:
		_notice.rpc_id(peer_id, message)


@rpc("authority", "call_remote", "reliable")
func _notice(message: String) -> void:
	if _from_host():
		_ui.set_notice(message)


@rpc("any_peer", "call_remote", "unreliable")
func _probe(sent: int) -> void:
	var peer_id: int = multiplayer.get_remote_sender_id()
	var now: int = Time.get_ticks_msec()
	if SteamNet.is_host and peer_id > 1 and SaveManager.can_spawn_for(peer_id) and now >= _next_probe.get(peer_id, 0):
		_next_probe[peer_id] = now + 1200
		_probe_reply.rpc_id(peer_id, sent)


@rpc("authority", "call_remote", "unreliable")
func _probe_reply(sent: int) -> void:
	if _from_host() and sent == _ping_sent:
		_ping_ms = Time.get_ticks_msec() - sent


func _from_host() -> bool:
	return not SteamNet.is_host and multiplayer.get_remote_sender_id() == 1


func _connected() -> bool:
	return SteamNet.available() and multiplayer.get_peers().has(1)


func _player(peer_id: int) -> Player:
	return _crew.get_node_or_null("Player%d" % peer_id) as Player


func _update_depth_of_field() -> void:
	var camera: Camera3D = get_viewport().get_camera_3d()
	if camera == _blurred_camera:
		return
	_restore_depth_of_field()
	if camera != null:
		_blurred_camera = camera
		_original_attributes = camera.attributes
		camera.attributes = _blur_attributes


func _restore_depth_of_field() -> void:
	if is_instance_valid(_blurred_camera):
		_blurred_camera.attributes = _original_attributes
	_blurred_camera = null
	_original_attributes = null
