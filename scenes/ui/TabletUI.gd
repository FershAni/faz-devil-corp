class_name TabletUI
extends Control
## Presentation only. All buttons emit intents. The host resolves them before
## a scan, audio playback, EMP or vent action has any world effect.

signal close_requested
signal command_requested(command: StringName, camera: String)

const STABLE: Color = Color(0.45, 0.95, 0.72)
const PANIC: Color = Color(1.0, 0.76, 0.31)
const LOST: Color = Color(1.0, 0.33, 0.39)
const WHITE: Color = Color(0.93, 0.97, 0.94)
const DAY_INK: Color = Color(0.09, 0.23, 0.26)
const DAY_ACCENT: Color = Color(0.68, 0.92, 0.85)
const NIGHT_ACCENT: Color = Color(0.25, 0.79, 0.73)
const UI_TICK: float = 0.20

class CrewRow:
	var root: VBoxContainer
	var title: Label
	var vital: Label
	var detail: Label
	var activity: Label
	var power: ProgressBar
	var card: PanelContainer

@onready var _device: Panel = $Device
@onready var _heading: Label = %Title
@onready var _charge: Label = %Battery
@onready var _close: Button = %Close
@onready var _roster: VBoxContainer = %Roster
@onready var _views: Control = %Views
@onready var _footer: Label = %Footer
@onready var _crt: ShaderMaterial = %CRT.material as ShaderMaterial

var _crew: Node3D
var _daytime: DaytimeManager
var _security: SecurityOffice
var _invasion: HubInvasion
var _rows: Dictionary[int, CrewRow] = {}
var _map: TabletMap
var _night: VBoxContainer
var _cctv: VBoxContainer
var _day: VBoxContainer
var _scan: Button
var _ping: Button
var _emp: Button
var _audio: Button
var _vent: Button
var _camera_caption: Label
var _grid_status: Label
var _orders: Label
var _fixture_grid: GridContainer
var _fixture_cards: Dictionary[int, PanelContainer] = {}
var _fixture_states: Dictionary[int, Label] = {}
var _heat: Label
var _camera: String = SecurityOffice.DEFAULT_CAMERA
var _phase: int = -1
var _notice: String = ""
var _notice_until: int = 0
var _opening: Tween
var _refresh_in: float = 0.0
var _shell: StyleBoxFlat


func _ready() -> void:
	theme = _tablet_theme()
	_charge.add_theme_color_override("font_color", NIGHT_ACCENT)
	_shell = _panel(Color(0.025, 0.055, 0.069), Color(0.23, 0.36, 0.37))
	_shell.set_corner_radius_all(14)
	_shell.set_border_width_all(3)
	_shell.shadow_color = Color(0.0, 0.0, 0.0, 0.65)
	_shell.shadow_size = 18
	_device.add_theme_stylebox_override("panel", _shell)
	_close.pressed.connect(close_requested.emit)


func configure(daytime: DaytimeManager, level: LevelGenerator, security: SecurityOffice,
		crew: Node3D, invasion: HubInvasion) -> void:
	_daytime = daytime
	_security = security
	_crew = crew
	_invasion = invasion
	_build_night(level)
	_build_cctv()
	_build_day()
	set_phase(GameState.phase)


func show_device() -> void:
	if _opening != null:
		_opening.kill()
	show()
	_device.pivot_offset = _device.size * 0.5
	_device.scale = Vector2.ONE * 0.78
	_opening = create_tween().set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)
	_opening.tween_property(_device, "scale", Vector2.ONE, 0.24)
	_close.grab_focus()
	_refresh_in = 0.0


func hide_device() -> void:
	if _opening != null:
		_opening.kill()
	_close.release_focus()
	hide()


func set_phase(phase: int) -> void:
	if _night == null or phase == _phase:
		return
	_phase = phase
	_night.visible = phase == GameState.Phase.NIGHT_SCAVENGE or phase == GameState.Phase.TRANSPORT
	_cctv.visible = phase == GameState.Phase.HUB_INVASION
	_day.visible = not _night.visible and not _cctv.visible
	_crt.set_shader_parameter("monochrome", 0.86 if _cctv.visible else 0.0)
	if _cctv.visible:
		_heading.text = "FAZ  /  ПОСТ ОХРАНЫ"
		_choose_camera(_camera)
	elif _night.visible:
		_heading.text = "FAZ  /  НОЧНАЯ РАЗВЕДКА"
	else:
		_heading.text = "FAZ  /  УПРАВЛЕНИЕ ПИЦЦЕРИЕЙ"
	_shell.bg_color = Color(0.046, 0.13, 0.14) if _day.visible else Color(0.025, 0.055, 0.069)
	_shell.border_color = Color(0.38, 0.61, 0.52) if _day.visible else Color(0.25, 0.43, 0.44)
	_refresh_in = 0.0


func activate_feed() -> void:
	if _cctv.visible:
		_choose_camera(_camera)


func set_notice(message: String) -> void:
	_notice = message
	_notice_until = Time.get_ticks_msec() + 3000


func receive_scan(point: Vector3, radius: float) -> void:
	_map.receive_scan(point, radius)


func receive_transport(point: Vector3) -> void:
	_map.receive_transport_ping(point)
	set_notice("Маяк транспорта виден всему экипажу")


func track_map() -> void:
	_map.refresh()


func refresh(delta: float, charge_by_peer: Dictionary[int, float], reloading: Dictionary[int, bool],
		reload_progress: float, ping_ms: int, interference: float) -> void:
	_crt.set_shader_parameter("interference", interference)
	var battery: float = GameState.tablet_battery
	_charge.text = "ЗАРЯД %d%%  ·  %s" % [roundi(battery), "%d мс" % ping_ms if ping_ms >= 0 else "ЛОКАЛЬНО"]
	var hint: String = "Tab · Закрыть     /     Удерживайте R · Заменить батарею"
	if reload_progress >= 0.0:
		hint = "ЗАМЕНА БАТАРЕИ  ·  %d%%" % roundi(reload_progress * 100.0)
	elif Time.get_ticks_msec() < _notice_until:
		hint = _notice
	_footer.text = hint
	_refresh_in -= delta
	if _refresh_in > 0.0:
		return
	_refresh_in = UI_TICK
	_refresh_roster(charge_by_peer, reloading)
	var dead: bool = GameState.is_dead(SteamNet.local_peer_id)
	_scan.disabled = dead or battery < 2.0
	_ping.disabled = dead or battery <= 0.0
	_audio.disabled = dead or battery < 4.0
	_emp.disabled = dead or battery < 10.0 or _camera != HubInvasion.GENERATOR_CAMERA or not _invasion.on_grid
	_vent.disabled = dead or battery < 8.0 or not GameState.daytime_open
	if _cctv.visible:
		_grid_status.text = "ГЕНЕРАТОР / %s  ·  %02d с" % [
			"СБОЙ ОБНАРУЖЕН" if _invasion.on_grid else "ПОД НАБЛЮДЕНИЕМ", ceili(_invasion.remaining)]
	elif _day.visible:
		_refresh_day()


func _build_night(level: LevelGenerator) -> void:
	_night = _new_view("Night")
	_night.add_child(_label("01  /  КАРТА ВЫЛАЗКИ", 15, NIGHT_ACCENT))
	_map = TabletMap.new()
	_map.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_map.configure(level, _crew)
	_night.add_child(_map)
	var controls: HBoxContainer = HBoxContainer.new()
	_night.add_child(controls)
	_scan = _button(controls, "СКАНИРОВАТЬ  ·  2%", _emit_command.bind(&"scan"))
	_ping = _button(controls, "ОТМЕТИТЬ ТРАНСПОРТ", _emit_command.bind(&"transport"))
	_night.add_child(_label("▲ ВЫ     ● ЭКИПАЖ     ◆ ЛОМ     ◇ ТРАНСПОРТ", 14, NIGHT_ACCENT))


func _build_cctv() -> void:
	_cctv = _new_view("CCTV")
	_camera_caption = _label("", 15, NIGHT_ACCENT)
	_cctv.add_child(_camera_caption)
	var screen: TextureRect = TextureRect.new()
	screen.texture = _security.feed_texture()
	screen.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	screen.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	screen.size_flags_vertical = Control.SIZE_EXPAND_FILL
	screen.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_cctv.add_child(screen)
	var matrix: GridContainer = GridContainer.new()
	matrix.columns = 6
	_cctv.add_child(matrix)
	var ids: Array[String] = _security.camera_ids()
	ids.erase(HubInvasion.GENERATOR_CAMERA)
	ids.insert(4, HubInvasion.GENERATOR_CAMERA)
	var group: ButtonGroup = ButtonGroup.new()
	for index: int in ids.size():
		var id: String = ids[index]
		var camera: Button = _button(matrix, "КАМ %02d" % (index + 1), _choose_camera.bind(id))
		camera.tooltip_text = _security.camera_location(id)
		camera.toggle_mode = true
		camera.button_group = group
		camera.set_pressed_no_signal(id == _camera)
	_grid_status = _label("", 14, PANIC)
	_cctv.add_child(_grid_status)
	var commands: HBoxContainer = HBoxContainer.new()
	_cctv.add_child(commands)
	_audio = _button(commands, "ЗВУКОВАЯ ПРИМАНКА  ·  4%", _emit_command.bind(&"audio"))
	_emp = _button(commands, "ИМПУЛЬС ЭМИ  ·  10%", _emit_command.bind(&"emp"))


func _choose_camera(id: String) -> void:
	_camera = id
	_security.select_camera(id)
	_camera_caption.text = "02  /  ВИДЕОНАБЛЮДЕНИЕ  ·  %s" % _security.camera_location(id).to_upper()
	_refresh_in = 0.0


func _build_day() -> void:
	_day = _new_view("Daytime")
	_day.add_child(_label("03  /  ДНЕВНАЯ СМЕНА", 15, DAY_ACCENT))
	var tabs: TabContainer = TabContainer.new()
	tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	tabs.add_theme_stylebox_override("panel", _panel(Color(0.80, 0.92, 0.88), DAY_ACCENT))
	_day.add_child(tabs)
	_orders = _day_label(_tab(tabs, "Заказы"))
	_build_diagnostics(_tab(tabs, "Диагностика"))
	var stage: VBoxContainer = _tab(tabs, "Управление сценой")
	_heat = _day_label(stage)
	_vent = _button(stage, "ОХЛАДИТЬ СЦЕНУ  ·  8%", _emit_command.bind(&"vent"))
	_vent.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN


func _build_diagnostics(parent: VBoxContainer) -> void:
	parent.add_child(_label("СОСТОЯНИЕ ОБОРУДОВАНИЯ", 17, DAY_INK))
	_fixture_grid = GridContainer.new()
	_fixture_grid.columns = 2
	_fixture_grid.add_theme_constant_override("h_separation", 8)
	_fixture_grid.add_theme_constant_override("v_separation", 8)
	parent.add_child(_fixture_grid)
	for prop: InteractiveProp in _daytime.catalog():
		var card: PanelContainer = PanelContainer.new()
		card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		card.add_theme_stylebox_override("panel", _panel(Color(0.90, 0.98, 0.94), Color(0.33, 0.63, 0.54)))
		var content: VBoxContainer = VBoxContainer.new()
		var title: Label = _label("%02d / %s" % [prop.prop_id, prop.display_name], 14, DAY_INK)
		title.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		content.add_child(title)
		var state: Label = _label("", 13, DAY_INK)
		content.add_child(state)
		card.add_child(content)
		_fixture_grid.add_child(card)
		_fixture_cards[prop.prop_id] = card
		_fixture_states[prop.prop_id] = state


func _tab(tabs: TabContainer, caption: String) -> VBoxContainer:
	var scroll: ScrollContainer = ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	tabs.add_child(scroll)
	tabs.set_tab_title(tabs.get_tab_count() - 1, caption)
	var content: VBoxContainer = VBoxContainer.new()
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(content)
	return content


func _day_label(parent: Control) -> Label:
	var label: Label = _label("", 17, DAY_INK)
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	parent.add_child(label)
	return label


func _refresh_day() -> void:
	var orders: PackedStringArray = ["ЗАКАЗЫ  /  " + _daytime.clock_text()]
	for index: int in _daytime.tablet_order_tables.size():
		orders.append("%s   ·   %02d с" % [_daytime.prop_name(_daytime.tablet_order_tables[index]),
			ceili(_daytime.order_seconds[index])])
	if not GameState.daytime_open:
		orders = PackedStringArray(["ЗАКАЗЫ", "", "Зал закрыт.",
			"Следующую смену можно открыть через компьютер охраны.", "",
			"КАССА  $%d     /     УЮТ  %d" % [GameState.business_balance, GameState.cozy_level]])
	elif _daytime.tablet_order_tables.is_empty():
		orders.append("Открытых заказов пока нет.")
	_orders.text = "\n".join(orders)
	for prop: InteractiveProp in _daytime.catalog():
		_fixture_cards[prop.prop_id].visible = prop.installed
		var state: Label = _fixture_states[prop.prop_id]
		state.text = "0%  ·  НУЖЕН РЕМОНТ" if prop.damaged else "100%  ·  ИСПРАВНО"
		state.add_theme_color_override("font_color", Color(0.53, 0.14, 0.18) if prop.damaged else DAY_INK)
	var stage: String = _daytime.stage_status()
	_heat.text = "ТЕМПЕРАТУРА АНИМАТРОНИКА\n\n" + (stage if not stage.is_empty() else "Сцена выключена")


func _refresh_roster(charges: Dictionary[int, float], reloading: Dictionary[int, bool]) -> void:
	var lobby_members: Array[int] = SteamNet.lobby_member_ids(SteamNet.lobby_id)
	var active_peers: Array[int] = []
	for peer_id: int in GameState.players:
		var account: int = int(GameState.wallet(peer_id).get("steam_id", 0))
		# Directly joined Steam friends also have authenticated metadata on the host.
		if SteamNet.lobby_id == 0 or account == SteamNet.local_steam_id or lobby_members.has(account) \
			or (account > 0 and int(SteamNet.meta_of(peer_id).get("steam_id", 0)) == account):
			active_peers.append(peer_id)
	active_peers.sort()
	for peer_id: int in _rows.keys():
		if not active_peers.has(peer_id):
			_rows[peer_id].card.queue_free()
			_rows.erase(peer_id)
	for peer_id: int in active_peers:
		if not _rows.has(peer_id):
			_rows[peer_id] = _add_crew_row()
		_update_crew_row(peer_id, _rows[peer_id], charges, reloading)


func _add_crew_row() -> CrewRow:
	var row: CrewRow = CrewRow.new()
	row.card = PanelContainer.new()
	var frame: StyleBoxFlat = _panel(Color(0.04, 0.095, 0.11), Color(0.16, 0.35, 0.35))
	frame.set_corner_radius_all(5)
	frame.set_content_margin_all(6.0)
	row.card.add_theme_stylebox_override("panel", frame)
	row.root = VBoxContainer.new()
	row.root.add_theme_constant_override("separation", 1)
	row.card.add_child(row.root)
	row.title = _label("", 16, WHITE)
	row.vital = _label("", 13, STABLE)
	row.detail = _label("", 13, WHITE)
	row.activity = _label("", 13, NIGHT_ACCENT)
	for label: Label in [row.title, row.vital, row.detail, row.activity]:
		label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		row.root.add_child(label)
	row.power = ProgressBar.new()
	row.power.show_percentage = false
	row.power.custom_minimum_size.y = 4.0
	var track: StyleBoxFlat = _panel(Color(0.08, 0.18, 0.20), Color.TRANSPARENT)
	track.set_content_margin_all(0.0)
	track.set_border_width_all(0)
	var fill: StyleBoxFlat = track.duplicate() as StyleBoxFlat
	fill.bg_color = NIGHT_ACCENT
	row.power.add_theme_stylebox_override("background", track)
	row.power.add_theme_stylebox_override("fill", fill)
	row.root.add_child(row.power)
	_roster.add_child(row.card)
	return row


func _update_crew_row(peer_id: int, row: CrewRow, charges: Dictionary[int, float],
		reloading: Dictionary[int, bool]) -> void:
	var wallet: Dictionary = GameState.wallet(peer_id)
	var account: int = int(wallet.get("steam_id", 0))
	var name_text: String = SteamNet.persona_of(account) if account > 0 else String(wallet.get("name", "Игрок"))
	row.title.text = name_text
	var player: Player = _crew.get_node_or_null("Player%d" % peer_id) as Player
	var hp: int = player.health if player != null else 100
	var dead: bool = GameState.is_dead(peer_id) or hp <= 0
	var noisy: bool = reloading.get(peer_id, false) or (player != null and player.animation_state in [
		Player.AnimState.RUN, Player.AnimState.RELOAD])
	if dead:
		row.vital.text = "✖ СИГНАЛ ПОТЕРЯН" if Time.get_ticks_msec() % 620 < 450 else "✖ С!ГНАЛ ПОТЕРЯН"
		row.vital.modulate = Color(1, 1, 1, 0.52 if Time.get_ticks_msec() % 620 >= 450 else 1.0)
		row.vital.add_theme_color_override("font_color", LOST)
	elif noisy:
		row.vital.text = "◆ ПАНИКА / ШУМ"
		row.vital.modulate = Color.WHITE
		row.vital.add_theme_color_override("font_color", PANIC)
	else:
		row.vital.text = "● СТАБИЛЕН"
		row.vital.modulate = Color.WHITE
		row.vital.add_theme_color_override("font_color", STABLE)
	var lamp: int = roundi(player.battery_display) if player != null else 100
	row.detail.text = "ОЗ %d  ·  Фонарь %d%%\nПланшет %d%%" % [
		0 if dead else hp, lamp, roundi(charges.get(peer_id, 100.0))]
	row.power.value = charges.get(peer_id, 100.0)
	row.power.tooltip_text = "Заряд планшета: %d%%" % roundi(row.power.value)
	var activity: String = ""
	if player != null:
		if player.viewing_security:
			activity = "[У компьютера]"
		elif player.daytime_repairing:
			activity = "[Ремонтирует мебель]"
		elif _daytime.is_carrying_order(peer_id):
			activity = "[Несёт пиццу]"
		elif GameState.daytime_open and player.global_position.distance_to(_daytime.target_position(0)) <= 2.5:
			activity = "[Готовит пиццу]"
	row.activity.text = activity
	row.activity.visible = not activity.is_empty() and not dead


func _emit_command(command: StringName) -> void:
	command_requested.emit(command, _camera)


func _new_view(node_name: String) -> VBoxContainer:
	var view: VBoxContainer = VBoxContainer.new()
	view.name = node_name
	view.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	view.add_theme_constant_override("separation", 8)
	_views.add_child(view)
	return view


func _button(parent: Control, caption: String, callback: Callable) -> Button:
	var button: Button = Button.new()
	button.text = caption
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	button.add_theme_font_size_override("font_size", 15)
	button.pressed.connect(callback)
	parent.add_child(button)
	return button


func _label(caption: String, font_size: int, ink: Color) -> Label:
	var label: Label = Label.new()
	label.text = caption
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", ink)
	label.add_theme_color_override("font_shadow_color", Color.TRANSPARENT)
	return label


func _tablet_theme() -> Theme:
	var skin: Theme = FazTheme.get_theme().duplicate() as Theme
	var normal: StyleBoxFlat = _panel(Color(0.053, 0.14, 0.16), Color(0.19, 0.42, 0.42))
	normal.set_corner_radius_all(5)
	normal.set_content_margin_all(8.0)
	var hover: StyleBoxFlat = normal.duplicate() as StyleBoxFlat
	hover.bg_color = Color(0.09, 0.23, 0.24)
	hover.border_color = NIGHT_ACCENT
	var pressed: StyleBoxFlat = hover.duplicate() as StyleBoxFlat
	pressed.bg_color = Color(0.12, 0.33, 0.31)
	var focus: StyleBoxFlat = normal.duplicate() as StyleBoxFlat
	focus.draw_center = false
	focus.border_color = NIGHT_ACCENT
	skin.set_stylebox("normal", "Button", normal)
	skin.set_stylebox("hover", "Button", hover)
	skin.set_stylebox("pressed", "Button", pressed)
	skin.set_stylebox("focus", "Button", focus)
	return skin


func _panel(fill: Color, edge: Color) -> StyleBoxFlat:
	var panel: StyleBoxFlat = StyleBoxFlat.new()
	panel.bg_color = fill
	panel.border_color = edge
	panel.set_border_width_all(1)
	panel.set_content_margin_all(12.0)
	return panel
