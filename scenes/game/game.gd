extends Node3D

## Game - round root. Owns the player spawner, the HUD and the route back to the menu.
## Only the listen server instantiates players; clients receive them through MultiplayerSpawner.

const PLAYER_SCENE := preload("res://scenes/player/Player.tscn")
const HUNTER_SCENE := preload("res://scenes/monster/BlindHunter.tscn")
const CORPSE_SCENE := preload("res://scenes/world/Corpse.tscn")
const BASKET_SCENE := preload("res://scenes/world/Basket.tscn")
const MENU_SCENE := preload("res://scenes/ui/MainMenu.tscn")

## How close "hold E" reaches, and how long the ship makes you hold before it lifts off.
const CARRY_REACH := 2.2
const SCRAP_REACH := 1.7
const SHIP_REACH := 3.0
const EXTRACT_HOLD := 1.2
const SHIP_POS := Vector3(0.0, 0.0, -5.0)
const BASKET_POS := Vector3(4.5, 0.0, 4.0)
const HINT_ALIVE := "WASD - движение | Shift - бег | Ctrl - присесть | Space - прыжок | F - фонарик | R - перезарядка | E (держать) - взять/тащить | ЛКМ / 1–3 - снаряжение | Tab - планшет | Esc - меню"
const HINT_DEAD := "ЛКМ/ПКМ - смотреть за следующего живого | Tab - планшет | Esc - меню"
const HINT_HUB := "E - пост охраны / магазин / вылазка | ЛКМ / 1–3 - снаряжение | Tab - планшет | Esc - меню"
const HINT_HUB_CLIENT := "E - пост охраны / магазин | ЛКМ / 1–3 - снаряжение | вылазку начинает хост | Tab - планшет | Esc - меню"
const HINT_DAYTIME: String = "E — взять / подать пиццу, чинить автомат или охлаждать сцену | Пиццу несите шагом"
const REPAIR_KEYS: Array[int] = [KEY_W, KEY_A, KEY_S, KEY_D]
const HINT_EXTRACT := "Удерживайте E на площадке, чтобы эвакуировать экипаж в пиццерию"

@onready var _players: Node3D = get_node("Players")
@onready var _hud: Control = $UI/Hud
@onready var _spawner: MultiplayerSpawner = get_node("Spawner")
@onready var _spawn_points: Node3D = get_node("SpawnPoints")
@onready var _phase_label: Label = get_node("UI/Hud/TopLeft/Phase")
@onready var _quota_label: Label = get_node("UI/Hud/TopLeft/Quota")
@onready var _crew_label: Label = get_node("UI/Hud/TopLeft/Crew")
@onready var _hint_label: Label = get_node("UI/Hud/BottomLeft/Hint")
@onready var _level: LevelGenerator = get_node("Level")
@onready var _pizzeria: Pizzeria = get_node("Pizzeria")
@onready var _stamina_bar: ProgressBar = get_node("UI/Hud/StaminaBar")
@onready var _death_label: Label = get_node("UI/Hud/Death")
@onready var _world_env: WorldEnvironment = get_node("WorldEnvironment")
@onready var _office_prompt: Label = get_node("UI/Hud/OfficePrompt")
@onready var _office_reticle: Label = get_node("UI/Hud/OfficeReticle")
@onready var _security_view: Control = get_node("UI/SecurityView")
@onready var _security_image: TextureRect = get_node("UI/SecurityView/Feed")
@onready var _security_title: Label = get_node("UI/SecurityView/Title")
@onready var _security_buttons: HBoxContainer = get_node("UI/SecurityView/CameraButtons")
@onready var _daytime: DaytimeManager = get_node("Daytime")
@onready var _day_panel: DaytimePanel = get_node("UI/DaytimeCenter/DaytimePanel")
@onready var _shop: ShopMenu = get_node("UI/Shop")
@onready var _tablet: Tablet = get_node("UI/Tablet")
@onready var _pause: PauseMenu = get_node("UI/Pause")

## Phase-dependent environment and the cadence of local stress grading.
var _look_hub := false
var _look_applied := false
var _death_panel: Panel
var _look_in: float = 0.0

## How long the stamina bar keeps showing after the last sprint tick.
var _stamina_hold := 0.0
var _last_hint := ""
var _last_death_text := ""
var _last_bar_value := -1.0
var _last_bar_visible := false

var _last_phase := -1
var _rng := RandomNumberGenerator.new()
## Server-only bookkeeping: who is dragging which carryable, and who is holding at the ship.
var _dragging: Dictionary = {}
var _extract_hold: Dictionary = {}
var _office_held := false
var _office_requests: Dictionary = {}
var _viewing_player: Player
var _view_motion: Tween
const ANDROID_CONTROLS := preload("res://scenes/ui/android_controls.gd")

var _android_controls: ANDROID_CONTROLS
var _mouse_mode_before_security: Input.MouseMode
var _sortie_time := 0.0
var _extract_retry: float = 0.0
var _save_notice_until: int = 0


func _ready() -> void:
	# A custom spawn function is the only way both sides agree on player authority: the
	# plain scene list would give every spawned node the spawner's authority (the server).
	_spawner.spawn_function = _custom_spawn
	_spawner.add_spawnable_scene(PLAYER_SCENE.resource_path)
	_spawner.add_spawnable_scene(HUNTER_SCENE.resource_path)
	_spawner.add_spawnable_scene(CORPSE_SCENE.resource_path)
	_spawner.add_spawnable_scene(BASKET_SCENE.resource_path)
	SaveManager.peer_ready.connect(_on_peer_ready)
	SaveManager.avatar_viewer_ready.connect(_on_avatar_viewer_ready)
	SaveManager.checkpoint_failed.connect(func(_error: Error) -> void: _save_notice_until = Time.get_ticks_msec() + 6000)
	SteamNet.player_disconnected.connect(_on_player_disconnected)
	SteamNet.session_ended.connect(_on_session_ended)
	GameState.state_changed.connect(_refresh_hud)
	GameState.player_wallet_updated.connect(_on_wallet_updated)
	GameState.player_life_changed.connect(_on_life_changed)
	_level.layout_ready.connect(_on_layout_ready)
	_build_ship_pad()
	_theme_hud()
	_setup_security_view()
	if OS.has_feature("android"):
		var touch_layer := CanvasLayer.new()
		touch_layer.layer = 2
		add_child(touch_layer)
		_android_controls = ANDROID_CONTROLS.new()
		_android_controls.inventory_bar = $UI/Hud/InventoryBar
		$UI/SecurityView/CloseHint.text = "ПРЯМОЙ ЭФИР"
		touch_layer.add_child(_android_controls)
	_daytime.configure(_pizzeria, _players)
	_day_panel.bind(_daytime)
	var invasion: HubInvasion = $HubInvasion
	invasion.configure(_pizzeria.security, _players)
	_tablet.configure(_daytime, _level, _pizzeria, _players, invasion, SHIP_POS)
	_daytime.feedback_changed.connect(_refresh_day_panel)
	# The host owns phase and seed; a client never decides what night it is. A session opens
	# in the pizzeria - the night only starts when the host holds E at the sortie door.
	if GameState.is_host() and GameState.phase == GameState.Phase.MENU:
		if GameState.invasion_active:
			GameState.server_begin_invasion()
		else:
			GameState.server_set_phase(GameState.Phase.HUB_DAY)
	_apply_seed()
	for peer_id: int in SteamNet.peers.keys():
		if SaveManager.can_spawn_for(peer_id):
			_spawn_player(peer_id)
	if not GameState.is_host():
		SaveManager.client_world_ready.call_deferred()
	_hint_label.text = HINT_ALIVE
	_refresh_hud()


func _process(delta: float) -> void:
	if _android_controls != null:
		_android_controls.repair_active = _daytime.repair_key >= 0
		_android_controls.security_active = _security_view.visible and not _pause.is_open()
	_hud.visible = not _tablet.is_open()
	_update_stamina_bar(delta)
	_update_death_label()
	if not _look_hub:
		_look_in -= delta
		if _look_in <= 0.0:
			_look_in = 0.25
			var viewer: Player = _local_player()
			Look.apply_stress(_world_env.environment, viewer.sanity if viewer != null else 100.0)
	var hint := HINT_ALIVE
	if GameState.is_dead(SteamNet.local_peer_id):
		hint = HINT_DEAD
	elif GameState.phase == GameState.Phase.HUB_DAY:
		hint = HINT_HUB if GameState.is_host() else HINT_HUB_CLIENT
		if GameState.daytime_open:
			hint = _daytime_hint()
		if not _pause.is_open() and not _tablet.is_open() and not _shop.is_open() and not _security_view.visible:
			_day_panel.present_pending_report()
	elif GameState.is_play_phase():
		var player := _local_player()
		if player != null and _at_ship(player):
			hint = HINT_EXTRACT
	if _android_controls != null:
		match hint:
			HINT_ALIVE, HINT_HUB, HINT_HUB_CLIENT:
				hint = "Стик — движение  ·  Свайп — обзор"
			HINT_DEAD:
				hint = "Вы погибли"
			HINT_EXTRACT:
				hint = "Удерживайте «ДЕЙСТВИЕ» на площадке для эвакуации"
			_:
				hint = hint.replace("E —", "ДЕЙСТВИЕ —")
	if Time.get_ticks_msec() < _save_notice_until:
		hint = "Ошибка записи слота. Проверьте доступ к папке сохранений и повторите операцию."
	# Label.text setters queue a redraw even for an identical string: write only on change.
	if hint != _last_hint:
		_last_hint = hint
		_hint_label.text = hint
	_tick_hub()


## Dragging a body and the lift-off hold are server rules about physics, so they run on the
## fixed 30 Hz clock: under a 144 fps host they were evaluated 4x more often for the same
## answer, and a held body disagreed with its carrier between two physics steps.
func _physics_process(delta: float) -> void:
	var local: Player = _local_player()
	if local != null:
		local.daytime_repairing = _daytime.repair_key >= 0
	if GameState.is_hub_phase():
		_tick_office()
		if GameState.is_host():
			_tick_shutters()
			if _sortie_time > 0.0:
				_sortie_time = maxf(0.0, _sortie_time - delta)
				if _sortie_time == 0.0:
					SteamNet.note("[hub] хост начинает вылазку")
					GameState.request_phase(GameState.Phase.NIGHT_SCAVENGE)
	if GameState.is_host() and GameState.phase == GameState.Phase.NIGHT_SCAVENGE:
		_tick_carry()
		_extract_retry = maxf(0.0, _extract_retry - delta)
		if _extract_retry == 0.0:
			_tick_extract(delta)


## Counter and door are read on every peer in the idle frame: the shop is local UI, and the
## sortie request goes to the server, so neither depends on whose physics tick ran first.
func _tick_hub() -> void:
	if GameState.phase != GameState.Phase.HUB_DAY or _security_view.visible or _day_panel.visible \
		or _daytime.repair_key >= 0 or _tablet.is_open() or _pause.is_open():
		return
	var player := _local_player()
	if player == null or not player.interact_held or GameState.is_dead(player.get_multiplayer_authority()):
		return
	if not _shop.is_open() \
		and player.global_position.distance_to(_pizzeria.counter_pos()) <= Pizzeria.REACH:
		_shop.open()
		return
	if player.global_position.distance_to(_pizzeria.door_pos()) <= Pizzeria.REACH \
		and GameState.is_host() and not GameState.daytime_open and _sortie_time == 0.0:
		_sortie_time = Pizzeria.SORTIE_OPEN_TIME + 0.08
		player.animate_interaction(_pizzeria.sortie_handle_pos(), true)
		_pizzeria.animate_sortie()
		_rpc_animate_sortie.rpc()


func _input(event: InputEvent) -> void:
	if _day_panel != null and _day_panel.visible:
		if event.is_action_pressed("UI_Cancel"):
			_day_panel.close()
			get_viewport().set_input_as_handled()
		elif Tablet.is_toggle_event(event):
			get_viewport().set_input_as_handled()
		return
	if _daytime != null and _daytime.repair_key >= 0 and GameplayPointer.get_mode() == Input.MOUSE_MODE_CAPTURED \
		and event is InputEventKey:
		var key_event: InputEventKey = event as InputEventKey
		var key: int = REPAIR_KEYS.find(key_event.physical_keycode)
		if key >= 0 and key_event.pressed and not key_event.echo:
			_daytime.request_repair_key(key)
			get_viewport().set_input_as_handled()
			return
	if _security_view == null or not _security_view.visible:
		return
	if event.is_action_pressed("UI_Cancel") or Tablet.is_toggle_event(event):
		_close_security_view()
		if event.is_action_pressed("UI_Cancel"):
			get_viewport().set_input_as_handled()


func _tick_office() -> void:
	var player := _local_player()
	var alive := player != null and not GameState.is_dead(player.get_multiplayer_authority())
	var near_desk := alive and player.global_position.distance_to(_pizzeria.office_desk_pos()) < 6.0
	var held := alive and player.interact_held
	var pressed := held and not _office_held
	_office_held = held
	var was_viewing := _security_view.visible
	if was_viewing and (pressed or not alive or not near_desk):
		_close_security_view()
	_pizzeria.security.set_feed_active(near_desk or _tablet.uses_security_feed())
	var can_aim := near_desk and not _security_view.visible and not _day_panel.visible \
		and (GameplayPointer.get_mode() == Input.MOUSE_MODE_CAPTURED or player.interact_override >= 0)
	var control := -1
	if can_aim:
		control = _pizzeria.security.control_in_sight(player.interaction_origin(), player.interaction_direction())
	var action_hint := "ДЕЙСТВИЕ   " if _android_controls != null else "E   "
	var hint := action_hint + _pizzeria.security.control_hint(control) if control >= 0 else ""
	var task: int = -1
	if alive and not near_desk and not _day_panel.visible and _daytime.repair_key < 0 \
		and (GameplayPointer.get_mode() == Input.MOUSE_MODE_CAPTURED or player.interact_override >= 0):
		task = _daytime.focus_target(player)
		if task >= 0:
			hint = action_hint + _daytime.interaction_hint(task)
	if _office_prompt.text != hint:
		_office_prompt.text = hint
	_office_reticle.visible = can_aim or task >= 0
	if not pressed or was_viewing:
		return
	if task >= 0:
		player.animate_interaction(_daytime.target_position(task), task == DaytimeManager.KITCHEN)
		_daytime.request_interaction(task)
		return
	if control < 0:
		return
	player.animate_interaction(_pizzeria.security.control_position(control))
	FazSfx.play(FazSfx.Cue.CLICK)
	if control == SecurityOffice.CAMERA_CONTROL:
		_pizzeria.security.press(control)
		_open_security_view(player)
	elif control == SecurityOffice.DAYTIME_CONTROL:
		_pizzeria.security.press(control)
		_day_panel.open_terminal()
	elif GameState.is_host():
		_office_requests[player.get_multiplayer_authority()] = control
	else:
		_rpc_office_request.rpc_id(1, control)


func _setup_security_view() -> void:
	_security_view.theme = FazTheme.get_theme()
	var security := _pizzeria.security
	_security_image.texture = security.feed_texture()
	var group := ButtonGroup.new()
	for id in security.camera_ids():
		var button := Button.new()
		button.text = "CAM " + id
		button.tooltip_text = security.camera_location(id)
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		button.toggle_mode = true
		button.button_group = group
		button.set_pressed_no_signal(id == SecurityOffice.DEFAULT_CAMERA)
		button.pressed.connect(_select_security_camera.bind(id))
		_security_buttons.add_child(button)
	_select_security_camera(SecurityOffice.DEFAULT_CAMERA)


func _select_security_camera(id: String) -> void:
	var security := _pizzeria.security
	security.select_camera(id)
	_security_title.text = "FAZ / SEC     ●  CAM %s   •   %s" % [id, security.camera_location(id).to_upper()]


func _open_security_view(player: Player) -> void:
	_viewing_player = player
	player.viewing_security = true
	_mouse_mode_before_security = GameplayPointer.get_mode()
	GameplayPointer.set_mode(Input.MOUSE_MODE_VISIBLE)
	_security_view.modulate.a = 0.0
	_security_view.show()
	for child in _security_buttons.get_children():
		var button := child as Button
		if button.button_pressed:
			button.grab_focus()
			break
	_view_motion = create_tween()
	_view_motion.tween_interval(0.17)
	_view_motion.tween_property(_security_view, "modulate:a", 1.0, 0.19)


func _close_security_view() -> void:
	if not _security_view.visible:
		return
	if _view_motion != null:
		_view_motion.kill()
	_security_view.hide()
	GameplayPointer.set_mode(_mouse_mode_before_security)
	if is_instance_valid(_viewing_player):
		_viewing_player.viewing_security = false
	_viewing_player = null


@rpc("any_peer", "call_remote", "reliable")
func _rpc_office_request(control: int) -> void:
	if GameState.is_host() and GameState.phase == GameState.Phase.HUB_DAY:
		_office_requests[multiplayer.get_remote_sender_id()] = control


@rpc("authority", "call_remote", "reliable")
func _rpc_office_press(control: int) -> void:
	_pizzeria.security.press(control)


@rpc("authority", "call_remote", "reliable")
func _rpc_animate_sortie() -> void:
	_pizzeria.animate_sortie()


func _tick_shutters() -> void:
	var security := _pizzeria.security
	var mask := GameState.office_shutters
	for shutter in 2:
		var bit := 1 << shutter
		if mask & bit and security.shutter_is_moving(shutter) and _doorway_occupied(shutter):
			mask &= ~bit
	for peer_id in _office_requests:
		var control: int = _office_requests[peer_id]
		var shutter := security.shutter_for(control)
		var player := _players.get_node_or_null("Player%d" % peer_id) as Player
		if shutter < 0 or player == null or GameState.is_dead(peer_id):
			continue
		if not security.can_reach_control(player.interaction_origin(), control):
			continue
		var bit := 1 << shutter
		# Resolve at most one change per shutter in a physics tick, including safety reversals.
		if (mask ^ GameState.office_shutters) & bit:
			continue
		if not (mask & bit) and _doorway_occupied(shutter):
			continue
		mask ^= bit
		security.press(control)
		_rpc_office_press.rpc(control)
	_office_requests.clear()
	GameState.server_set_office_shutters(mask)


func _doorway_occupied(shutter: int) -> bool:
	for player in _players.get_children():
		if player is Player and not GameState.is_dead(player.get_multiplayer_authority()) \
			and _pizzeria.security.doorway_contains(shutter, player.global_position):
			return true
	return false


## One window about the haul that died with its carrier: no headline, no countdown.
func _update_death_label() -> void:
	var peer_id := SteamNet.local_peer_id
	if not GameState.is_dead(peer_id):
		if _last_death_text != "":
			_last_death_text = ""
			_death_label.visible = false
			if _death_panel != null:
				_death_panel.visible = false
		return
	var text := "Потерян лом: $%d" % int(GameState.wallet(peer_id).get("lost_scrap", 0))
	if text != _last_death_text:
		_last_death_text = text
		_death_label.text = text
		_death_label.visible = true
		if _death_panel != null:
			_death_panel.visible = true


## Stamina is simulated only on the owning machine, so the bar is a local readout with
## nothing to replicate: it appears when you sprint and stays a beat after you stop.
func _update_stamina_bar(delta: float) -> void:
	var player := _local_player()
	if player == null:
		_stamina_hold = 0.0
		if _last_bar_visible:
			_last_bar_visible = false
			_stamina_bar.visible = false
		return
	if player.running or player.exhausted:
		_stamina_hold = 1.2
	_stamina_hold = maxf(_stamina_hold - delta, 0.0)
	var show := _stamina_hold > 0.0
	if show != _last_bar_visible:
		_last_bar_visible = show
		_stamina_bar.visible = show
	var value := player.stamina_fraction() * 100.0
	# The bar animates in 0.5 steps: writing the same float every frame only costs redraws.
	value = snappedf(value, 0.5)
	if show and value != _last_bar_value:
		_last_bar_value = value
		_stamina_bar.value = value


## The HUD used to be raw white text floating over the world, which is the one screen element
## that did not match the tablet, the shop or the menu. Same palette, same 1 px blood border,
## built in code so the geometry stays reviewable.
func _theme_hud() -> void:
	var hud := get_node_or_null("UI/Hud") as Control
	if hud == null:
		return
	var crew := _wrap_hud(hud, "TopLeft", _hud_box(FazTheme.PANEL, 3, FazTheme.BLOOD, 14.0, 10.0))
	if crew != null:
		(crew.get_node("Phase") as Label).add_theme_color_override("font_color", Color(1.0, 0.72, 0.64))
		(crew.get_node("Phase") as Label).add_theme_font_size_override("font_size", 20)
		(crew.get_node("Quota") as Label).add_theme_color_override("font_color", FazTheme.INK)
		(crew.get_node("Quota") as Label).add_theme_font_size_override("font_size", 17)
		(crew.get_node("Crew") as Label).add_theme_color_override("font_color", FazTheme.INK)
		(crew.get_node("Crew") as Label).add_theme_font_size_override("font_size", 17)
	var soft: Color = Color(0.026, 0.033, 0.044, 0.86)
	var hint := _wrap_hud(hud, "BottomLeft", _hud_box(soft, 0, FazTheme.BLOOD, 12.0, 6.0), true)
	if hint != null:
		var label := hint.get_node("Hint") as Label
		label.add_theme_color_override("font_color", FazTheme.INK)
		label.add_theme_font_size_override("font_size", 16)
		# The hint line is long; it should wrap instead of running under the stamina bar.
		label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		label.custom_minimum_size = Vector2(900.0, 0.0)
	# The death window keeps its node path (the harness reads UI/Hud/Death), so its frame is a
	# sibling Panel drawn just behind it instead of a reparent into a container.
	var death := _hud_frame(hud, "Death", _hud_box(Color(0.05, 0.04, 0.045, 0.9), 2,
		FazTheme.BLOOD_HI, 22.0, 12.0))
	if death != null:
		_death_panel = death
		(_death_label).add_theme_color_override("font_color", Color(0.93, 0.66, 0.22))


func _hud_box(fill: Color, edge: int, edge_color: Color, pad_x: float,
		pad_y: float) -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = fill
	box.border_width_left = edge
	box.border_width_top = 1
	box.border_width_right = 1
	box.border_width_bottom = 1
	box.border_color = Color(edge_color.r, edge_color.g, edge_color.b, 0.6)
	box.corner_radius_top_left = 2
	box.corner_radius_top_right = 2
	box.corner_radius_bottom_left = 2
	box.corner_radius_bottom_right = 2
	box.content_margin_left = pad_x
	box.content_margin_right = pad_x
	box.content_margin_top = pad_y
	box.content_margin_bottom = pad_y
	return box


## A Panel that borrows a label's rectangle and sits one slot earlier in the tree, so it is
## drawn behind the text instead of over it.
func _hud_frame(hud: Control, node_name: String, box: StyleBoxFlat) -> Panel:
	var child := hud.get_node_or_null(node_name) as Control
	if child == null:
		return null
	var frame := Panel.new()
	frame.name = node_name + "Bg"
	frame.anchor_left = child.anchor_left
	frame.anchor_top = child.anchor_top
	frame.anchor_right = child.anchor_right
	frame.anchor_bottom = child.anchor_bottom
	frame.offset_left = child.offset_left - 14.0
	frame.offset_top = child.offset_top - 10.0
	frame.offset_right = child.offset_right + 14.0
	frame.offset_bottom = child.offset_bottom + 10.0
	frame.grow_horizontal = child.grow_horizontal
	frame.grow_vertical = child.grow_vertical
	frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	frame.add_theme_stylebox_override("panel", box)
	var at := child.get_index()
	hud.add_child(frame)
	hud.move_child(frame, at)
	frame.visible = child.visible
	return frame


## Puts an existing corner block inside a PanelContainer without moving it on screen: the
## wrapper inherits the child's anchors and offsets, the child gives them up to the container.
func _wrap_hud(hud: Control, node_name: String, box: StyleBoxFlat, wide := false) -> Control:
	var child := hud.get_node_or_null(node_name) as Control
	if child == null:
		return null
	var wrap := PanelContainer.new()
	wrap.name = node_name + "Panel"
	if wide:
		# The hint line spans the bottom and wraps; only its height comes from content.
		wrap.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
		wrap.offset_left = 24.0
		wrap.offset_right = -24.0
		wrap.offset_top = -70.0
		wrap.offset_bottom = -12.0
	else:
		wrap.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
		wrap.offset_left = child.offset_left
		wrap.offset_top = child.offset_top
	wrap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	wrap.add_theme_stylebox_override("panel", box)
	var at := child.get_index()
	hud.add_child(wrap)
	hud.move_child(wrap, at)
	hud.remove_child(child)
	child.anchor_left = 0.0
	child.anchor_top = 0.0
	child.anchor_right = 0.0
	child.anchor_bottom = 0.0
	child.offset_left = 0.0
	child.offset_top = 0.0
	child.offset_right = 0.0
	child.offset_bottom = 0.0
	wrap.add_child(child)
	# The old boxes had hand-set rectangles; the panel must shrink to what the labels need.
	wrap.reset_size()
	return child


func _local_player() -> Player:
	# The group holds Players only, so this never walks over corpses, baskets or the monster.
	for node in get_tree().get_nodes_in_group(&"players"):
		var player := node as Player
		if player != null and player.is_multiplayer_authority():
			return player
	return null


func _on_peer_ready(peer_id: int) -> void:
	if not GameState.is_host():
		return
	for node: Node in _players.get_children():
		if node is Player:
			var gate: MultiplayerSynchronizer = node.get_node("SpawnGate") as MultiplayerSynchronizer
			gate.update_visibility(peer_id)
			var movement: MultiplayerSynchronizer = node.get_node("Sync") as MultiplayerSynchronizer
			if movement.is_multiplayer_authority():
				movement.update_visibility(peer_id)
	_spawn_player(peer_id)


func _on_avatar_viewer_ready(peer_id: int) -> void:
	var local: Player = _local_player()
	if local != null:
		var movement: MultiplayerSynchronizer = local.get_node("Sync") as MultiplayerSynchronizer
		movement.update_visibility(peer_id)


func _on_player_disconnected(peer_id: int) -> void:
	if not GameState.is_host():
		return
	_dragging.erase(peer_id)
	_extract_hold.erase(peer_id)
	_drop_carryables_of(peer_id)
	var node := _players.get_node_or_null("Player%d" % peer_id)
	if node != null:
		node.queue_free()


func _spawn_player(peer_id: int) -> void:
	if not GameState.is_host():
		return
	if _players.get_node_or_null("Player%d" % peer_id) != null:
		return
	# Slot by join order, not peer id: Steam ids and ENet ids are huge and would collide.
	var pos := _spawn_position_for(_players.get_child_count())
	GameState.server_set_spawn_pos(peer_id, pos)
	_spawner.spawn({
		"peer": peer_id,
		"pos": pos,
	})


## Runs on every peer with the same payload, so each machine builds the same node with the
## same authority before its first replication tick.
func _custom_spawn(data: Variant) -> Node:
	var payload: Dictionary = data
	var peer_id := int(payload.get("peer", 1))
	var kind := String(payload.get("scene", "player"))
	var node: Node3D
	if kind == "hunter":
		# The hunter belongs to the server: authority 1 on every machine, so no client ever
		# simulates it and no client can move it.
		node = HUNTER_SCENE.instantiate()
		node.name = "BlindHunter"
		peer_id = 1
	elif kind == "corpse":
		node = CORPSE_SCENE.instantiate()
		node.name = "Corpse%d" % peer_id
		node.owner_peer = peer_id
		peer_id = 1
	elif kind == "basket":
		node = BASKET_SCENE.instantiate()
		node.name = "Basket"
		peer_id = 1
	else:
		var player: Player = PLAYER_SCENE.instantiate()
		player.name = "Player%d" % peer_id
		player.display_name = String(SteamNet.meta_of(peer_id).get("name", "Peer %d" % peer_id))
		node = player
	node.set_multiplayer_authority(peer_id)
	if node is Player:
		# Spawn visibility uses an OR across server-authoritative synchronizers. Gate
		# the host's movement synchronizer as well as the dedicated spawn synchronizer.
		var gate: MultiplayerSynchronizer = MultiplayerSynchronizer.new()
		gate.name = "SpawnGate"
		gate.replication_config = SceneReplicationConfig.new()
		gate.visibility_update_mode = MultiplayerSynchronizer.VISIBILITY_PROCESS_NONE
		node.add_child(gate)
		gate.add_visibility_filter(SaveManager.can_spawn_for)
		var movement: MultiplayerSynchronizer = node.get_node("Sync") as MultiplayerSynchronizer
		if GameState.is_host() and peer_id == 1:
			movement.add_visibility_filter(SaveManager.can_spawn_for)
		elif not GameState.is_host():
			if peer_id == multiplayer.get_unique_id():
				movement.add_visibility_filter(SaveManager.can_send_avatar_to)
			else:
				node.ready.connect(SaveManager.confirm_avatar_visible.bind(peer_id), CONNECT_ONE_SHOT)
	# The node has no parent yet, so global_position would warn; Players sits at the origin.
	node.position = payload.get("pos", Vector3.ZERO)
	return node


## One hunter per night, placed in a room rather than next to the crew.
func _spawn_hunter() -> void:
	var rooms := _level.rooms()
	var spot := Vector3.ZERO
	if not rooms.is_empty():
		spot = rooms[_pick_room()]["center"] as Vector3
	_spawner.spawn({"scene": "hunter", "peer": 1, "pos": spot})
	SteamNet.note("[hunter] spawn pos=%s" % str(spot))


func _pick_room() -> int:
	return _rng.randi_range(0, _level.rooms().size() - 1)


## Spawn points are indexed by join slot so every machine agrees without extra traffic.
## In the pizzeria the slots are in the security office, at night they are the map markers.
func _spawn_position_for(slot: int) -> Vector3:
	if GameState.is_hub_phase():
		var hub := _pizzeria.hub_spawns()
		return hub[slot % hub.size()]
	var markers := _spawn_points.get_children()
	if markers.is_empty():
		return Vector3.ZERO
	return markers[slot % markers.size()].global_position


func _on_session_ended(reason: String) -> void:
	SteamNet.note("[game] session ended: " + reason)
	# Deferred: this runs inside leave_session(), and freeing the round mid-signal is how
	# sibling handlers end up talking to a node that no longer has a tree.
	get_tree().change_scene_to_packed.call_deferred(MENU_SCENE)


func _on_wallet_updated(_peer_id: int, _balance: int) -> void:
	_refresh_hud()


## The authority commits a layout before it spawns actors that depend on the navigation
## graph. Clients consume the RoomSpawner snapshot, including when joining mid-sortie.
func _apply_seed() -> void:
	if not GameState.is_host():
		return
	var phase: int = GameState.phase
	if GameState.is_hub_phase():
		_level.clear_layout()
		var hunter: Node = _players.get_node_or_null("BlindHunter")
		if hunter != null:
			hunter.queue_free()
		return
	var seed_value: int = GameState.map_seed
	if not GameState.is_play_phase() or seed_value == 0 or _level.has_layout(seed_value):
		return
	_level.generate(seed_value)
	if not _level.has_layout(seed_value):
		return
	_rng.seed = seed_value
	_clear_carryables()
	_spawn_hunter()
	_spawner.spawn({"scene": "basket", "peer": 1, "pos": BASKET_POS})


func _on_layout_ready(seed_value: int) -> void:
	_level.apply_taken(GameState.taken_scrap)
	SteamNet.note("[level] seed=%d hash=%d %s" % [
		seed_value, _level.layout_hash(), _level.describe()])


## Crossing between pizzeria and night moves the whole crew: the server rewrites each
## spawn slot and bumps return_home, so every body teleports itself to the right floor.
func _reposition_on_phase_change() -> void:
	if not GameState.is_host() or GameState.phase == _last_phase:
		return
	_last_phase = GameState.phase
	if not GameState.is_hub_phase() and GameState.phase != GameState.Phase.NIGHT_SCAVENGE:
		return
	var slot := 0
	for peer_id in GameState.players.keys():
		GameState.server_set_spawn_pos(int(peer_id), _spawn_position_for(slot))
		slot += 1
	GameState.server_reset_crew()


## The two moods of the game are two color grades, not one: the pizzeria is warm and legible,
## the night is cold, foggy and lit by failing lamps. Every peer picks the grade itself from
## the replicated phase, so nobody needs an extra RPC to say "put the lights on".
func _apply_look(hub: bool) -> void:
	if hub == _look_hub and _look_applied:
		return
	_look_hub = hub
	_look_applied = true
	Look.apply(_world_env, Look.HUB if hub else Look.NIGHT)


func _refresh_hud(_key: StringName = &"") -> void:
	_apply_seed()
	_level.apply_taken(GameState.taken_scrap)
	var hub: bool = GameState.is_hub_phase()
	var hub_changed := hub != _look_hub or not _look_applied
	_apply_look(hub)
	if hub:
		_pizzeria.security.apply_shutters(GameState.office_shutters, hub_changed)
	if hub_changed:
		_pizzeria.security.set_process(hub)
		_pizzeria.reset_sortie()
		_sortie_time = 0.0
		_office_held = false
		_office_requests.clear()
		if not hub:
			_day_panel.close()
			_pizzeria.security.set_feed_active(false)
			_close_security_view()
			_office_prompt.text = ""
			_office_reticle.hide()
	_level.visible = not hub
	_pizzeria.visible = hub
	var ship := get_node_or_null("Ship")
	if ship != null:
		ship.visible = GameState.phase == GameState.Phase.NIGHT_SCAVENGE
	_reposition_on_phase_change()
	_phase_label.text = "Смена: %s   (день %d)" % [GameState.phase_name(), GameState.day_index]
	_quota_label.text = "Квота $%d | Сдано $%d | Долг $%d | Уют %d | Тревога %d%%" % [
		GameState.quota_cents,
		GameState.earnings_cents,
		GameState.debt_cents,
		GameState.cozy_level,
		int(GameState.alert_level * 100.0),
	]
	if hub:
		_quota_label.text += " | Касса $%d" % GameState.business_balance
	_refresh_day_panel()
	var lines := PackedStringArray()
	for peer_id in GameState.players:
		var wallet: Dictionary = GameState.players[peer_id]
		var status := ""
		if GameState.is_dead(int(peer_id)):
			status = "  мёртв"
		lines.append("- %s  $%d  лом $%d%s" % [
			String(wallet.get("name", "Игрок")),
			int(wallet.get("balance", 0)),
			int(wallet.get("scrap_value", 0)),
			status,
		])
	_crew_label.text = "ЭКИПАЖ\n" + "\n".join(lines)


func _refresh_day_panel() -> void:
	if _day_panel.visible:
		_day_panel.refresh()


func _daytime_hint() -> String:
	var status: String = "%s  ·  " % _daytime.clock_text()
	if _daytime.repair_key >= 0:
		return status + "Ремонт %d/%d  ·  нажмите %s" % [
			_daytime.repair_step + 1, DaytimeManager.QTE_STEPS,
			OS.get_keycode_string(REPAIR_KEYS[_daytime.repair_key]),
		]
	if _daytime.carried_table >= 0:
		return status + "Заказ → %s  ·  баланс %d%%  ·  идите шагом" % [
			_daytime.prop_name(_daytime.carried_table), roundi(_daytime.carry_balance * 100.0),
		]
	if not _daytime.feedback.is_empty():
		return status + _daytime.feedback
	if not _daytime.order_tables.is_empty():
		return status + "Заказов на кухне: %d  ·  %s" % [_daytime.order_tables.size(), HINT_DAYTIME]
	return status + HINT_DAYTIME


## ---------------- bodies, cart and ship ----------------

func _on_life_changed(peer_id: int, dead: bool) -> void:
	if not dead or not GameState.is_host():
		return
	var player := _players.get_node_or_null("Player%d" % peer_id) as Player
	if player == null:
		return
	_spawner.spawn({"scene": "corpse", "peer": peer_id, "pos": player.global_position})
	SteamNet.note("[corpse] peer=%d лёг на %s" % [peer_id, str(player.global_position)])


func _clear_carryables() -> void:
	_dragging.clear()
	_extract_hold.clear()
	for child in _players.get_children():
		if child is Corpse or child is Basket:
			child.queue_free()


func _basket() -> Basket:
	return _players.get_node_or_null("Basket") as Basket


func _corpses() -> Array:
	var out: Array = []
	for child in _players.get_children():
		if child is Corpse:
			out.append(child)
	return out


## The pad is static hub furniture, so every machine builds the same one from constants -
## nothing to replicate, nothing to desync.
func _build_ship_pad() -> void:
	var ship := Node3D.new()
	ship.name = "Ship"
	ship.position = SHIP_POS
	add_child(ship)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.2, 0.22, 0.26, 1.0)
	mat.metallic = 0.5
	mat.roughness = 0.6
	var pad := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(4.0, 0.2, 4.0)
	pad.mesh = box
	pad.material_override = mat
	pad.position = Vector3(0.0, 0.1, 0.0)
	ship.add_child(pad)
	# Put the extraction sign beside the deck, away from doorway labels on the back wall.
	var board: MeshInstance3D = MeshInstance3D.new()
	var plate: BoxMesh = BoxMesh.new()
	plate.size = Vector3(2.9, 0.61, 0.08)
	board.mesh = plate
	board.material_override = Look.sign_backing()
	board.position = Vector3(2.75, 1.83, -0.35)
	board.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	board.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	ship.add_child(board)
	for facing: float in [-1.0, 1.0]:
		var sign: Label3D = Label3D.new()
		sign.text = "ЭВАКУАЦИЯ [E]"
		sign.position = board.position + Vector3(0.0, 0.0, facing * 0.055)
		sign.rotation.y = 0.0 if facing > 0.0 else PI
		Look.style_sign(sign, Color(1.0, 0.88, 0.65), 88, 0.0043)
		ship.add_child(sign)

	var stripe: BoxMesh = BoxMesh.new()
	stripe.size = Vector3(3.82, 0.016, 0.16)
	stripe.material = Look.bulb(Color(0.76, 0.51, 0.16), 0.16)
	for side: float in [-1.0, 1.0]:
		var edge: MeshInstance3D = MeshInstance3D.new()
		edge.mesh = stripe
		edge.position = Vector3(0.0, 0.208, side * 1.85)
		edge.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		edge.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
		ship.add_child(edge)
	var lamp := OmniLight3D.new()
	lamp.position = Vector3(0.0, 2.0, 0.0)
	lamp.light_energy = 6.8
	lamp.omni_range = 7.0
	lamp.light_color = Color(0.9, 0.8, 0.4, 1.0)
	ship.add_child(lamp)


## Hold E to drag, release to drop. Everything here runs on the host: clients only report
## their own button through the replicated interact_held, so nobody can teleport a body.
func _tick_carry() -> void:
	for member in get_tree().get_nodes_in_group(&"players"):
		var player := member as Player
		if player == null:
			continue
		var peer_id := int(player.get_multiplayer_authority())
		if GameState.is_dead(peer_id):
			_dragging.erase(peer_id)
			_drop_carryables_of(peer_id)
			continue
		var held: bool = player.interact_held
		var node: Node3D = _dragging.get(peer_id)
		if node != null and not is_instance_valid(node):
			node = null
			_dragging.erase(peer_id)
		if node != null:
			if held:
				_follow(node, player)
			else:
				_release(peer_id, node)
			continue
		if not held:
			continue
		# At the pad the same hold means "lift off", not "grab the cart again".
		if _at_ship(player):
			continue
		var basket := _basket()
		var haul := int(GameState.wallet(peer_id).get("scrap_value", 0))
		if basket != null and haul > 0 and _near(player, basket, CARRY_REACH):
			basket.cargo_cents += haul
			GameState.server_add_scrap(peer_id, -haul)
			SteamNet.note("[basket] peer=%d сдал лом $%d, в корзине $%d" % [
				peer_id, haul, basket.cargo_cents])
			continue
		var target := _nearest_target(player)
		if target == null:
			continue
		if target is Marker3D:
			var index := int(target.get_meta("index", -1))
			if GameState.taken_scrap.has(index):
				continue
			var value := int(target.get_meta("value", 0))
			GameState.server_take_scrap(index)
			GameState.server_add_scrap(peer_id, value)
			_level.apply_taken(GameState.taken_scrap)
			SteamNet.note("[scrap] peer=%d поднял точку %d за $%d" % [peer_id, index, value])
			continue
		_dragging[peer_id] = target
		target.set("carried_by", peer_id)
		if target is Corpse:
			target.in_basket = false


## A dead or gone carrier drops what it held: otherwise the cart stays "carried" forever
## and nobody else can ever grab it.
func _drop_carryables_of(peer_id: int) -> void:
	for node in _corpses():
		if int(node.carried_by) == peer_id:
			node.carried_by = 0
	var basket := _basket()
	if basket != null and int(basket.carried_by) == peer_id:
		basket.carried_by = 0


func _nearest_target(player: Player) -> Node3D:
	var best: Node3D
	var best_dist := CARRY_REACH
	for corpse in _corpses():
		if int(corpse.carried_by) != 0 or corpse.in_basket:
			continue
		var d := player.global_position.distance_to(corpse.global_position)
		if d < best_dist:
			best_dist = d
			best = corpse
	if best != null:
		return best
	for point in _level.scrap_points():
		if not point.visible:
			continue
		var d := player.global_position.distance_to(point.global_position)
		if d < SCRAP_REACH and d < best_dist:
			best_dist = d
			best = point
	if best != null:
		return best
	var basket := _basket()
	if basket != null and int(basket.carried_by) == 0 and _near(player, basket, CARRY_REACH):
		return basket
	for corpse in _corpses():
		if corpse.in_basket and int(corpse.carried_by) == 0 and _near(player, corpse, CARRY_REACH):
			return corpse
	return null


func _release(peer_id: int, node: Node3D) -> void:
	_dragging.erase(peer_id)
	node.set("carried_by", 0)
	var basket := _basket()
	if node is Corpse and basket != null and _near(node, basket, CARRY_REACH):
		node.in_basket = true
		SteamNet.note("[basket] тело peer=%d уложено в корзину" % int(node.owner_peer))


func _follow(node: Node3D, player: Player) -> void:
	var back := -player.global_transform.basis.z
	back.y = 0.0
	back = back.normalized()
	if node is Basket:
		node.global_position = player.global_position + back * 1.3
		node.rotation.y = player.rotation.y
		# Whatever rides in the cart rides with it.
		var i := 0
		for corpse in _corpses():
			if corpse.in_basket:
				corpse.global_position = node.global_position + Vector3(0.0, 0.6 + i * 0.35, 0.0)
				corpse.rotation.y = node.rotation.y
				i += 1
	else:
		node.global_position = player.global_position + back * 1.0 + Vector3(0.0, 0.3, 0.0)
		node.rotation.y = player.rotation.y


func _near(a: Node3D, b: Node3D, reach: float) -> bool:
	return a.global_position.distance_to(b.global_position) <= reach


func _at_ship(player: Player) -> bool:
	return player.global_position.distance_squared_to(SHIP_POS) <= SHIP_REACH * SHIP_REACH


## Holding E at the pad sells the haul and brings the crew back to the pizzeria.
func _tick_extract(delta: float) -> void:
	for node in get_tree().get_nodes_in_group(&"players"):
		var player := node as Player
		if player == null:
			continue
		var peer_id := int(player.get_multiplayer_authority())
		if GameState.is_dead(peer_id) or not player.interact_held or not _at_ship(player) \
			or _dragging.has(peer_id):
			_extract_hold.erase(peer_id)
			continue
		var hold := float(_extract_hold.get(peer_id, 0.0)) + delta
		_extract_hold[peer_id] = hold
		if hold >= EXTRACT_HOLD:
			_extract(peer_id)
			return


func _extract(peer_id: int) -> void:
	var basket: Basket = _basket()
	var cargo: int = basket.cargo_cents if basket != null else 0
	if not GameState.server_sell_cargo(peer_id, cargo, true):
		_extract_hold.clear()
		_extract_retry = 2.0
		return
	SteamNet.note("[ship] peer=%d улетел: сдано $%d, день %d" % [
		peer_id, GameState.earnings_cents, GameState.day_index])
	_clear_carryables()
	if GameState.invasion_active:
		GameState.server_begin_invasion()
	else:
		GameState.server_set_phase(GameState.Phase.HUB_DAY)
