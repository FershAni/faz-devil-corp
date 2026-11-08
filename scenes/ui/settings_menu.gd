extends CanvasLayer

## SettingsMenu - shared by the main menu and the pause overlay.
## Sections are switched by two buttons rather than a TabContainer: the tab titles came
## from node names, which cannot be Russian without Cyrillic node names.
## Living on its own CanvasLayer means the overlay anchors to the viewport, so it can no
## longer collapse when the scene root Control it was instanced into has no size yet.

const SECTION_NAMES := {
	"Master": "ОБЩАЯ ГРОМКОСТЬ",
	"Music": "МУЗЫКА",
	"UI": "ИНТЕРФЕЙС",
	"SFX": "ЭФФЕКТЫ",
	"Ambient": "АТМОСФЕРА",
}

@onready var _root: Control = get_node("Root")
@onready var _tab_audio: Button = get_node("Root/Center/Panel/Margin/Column/Tabs/TabAudio")
@onready var _tab_video: Button = get_node("Root/Center/Panel/Margin/Column/Tabs/TabVideo")
@onready var _audio_box: VBoxContainer = get_node("Root/Center/Panel/Margin/Column/Body/Audio")
@onready var _video_box: VBoxContainer = get_node("Root/Center/Panel/Margin/Column/Body/Video")
@onready var _mode: OptionButton = get_node("Root/Center/Panel/Margin/Column/Body/Video/ModeRow/Mode")
@onready var _resolution: OptionButton = get_node("Root/Center/Panel/Margin/Column/Body/Video/ResRow/Resolution")
@onready var _vsync: CheckBox = get_node("Root/Center/Panel/Margin/Column/Body/Video/VSync")
@onready var _max_fps: OptionButton = get_node("Root/Center/Panel/Margin/Column/Body/Video/FpsRow/MaxFps")
@onready var _reset_button: Button = get_node("Root/Center/Panel/Margin/Column/Actions/ResetButton")
@onready var _save_button: Button = get_node("Root/Center/Panel/Margin/Column/Actions/SaveButton")
@onready var _close_x: Button = get_node("Root/Center/Panel/Margin/Column/Head/CloseX")
@onready var _feedback: Label = get_node("Root/Center/Panel/Margin/Column/Feedback")

var _sliders := {}


func _ready() -> void:
	_root.theme = FazTheme.get_theme()
	for bus_name in GameSettings.BUSES:
		_add_audio_row(bus_name)
	_populate_mode()
	_populate_resolutions()
	_populate_fps()
	_tab_audio.pressed.connect(_show_audio)
	_tab_video.pressed.connect(_show_video)
	_mode.item_selected.connect(
		func(index: int): GameSettings.set_display_mode(String(_mode.get_item_metadata(index))))
	_resolution.item_selected.connect(_on_resolution_selected)
	_vsync.toggled.connect(func(pressed: bool): GameSettings.set_vsync(pressed))
	_max_fps.item_selected.connect(func(index: int): GameSettings.set_max_fps(int(_max_fps.get_item_metadata(index))))
	_reset_button.pressed.connect(reset_to_defaults)
	_save_button.pressed.connect(save_settings)
	_close_x.pressed.connect(close)
	for button in [_reset_button, _save_button, _close_x]:
		button.pressed.connect(func(): FazSfx.play(FazSfx.Cue.CLICK))
	_show_audio()


func open_menu() -> void:
	visible = true
	_sync_controls()
	if not GameSettings.settings_changed.is_connected(_sync_controls):
		GameSettings.settings_changed.connect(_sync_controls)


## × and Esc: leave the overlay, keep everything as it is on screen.
func close() -> void:
	if GameSettings.settings_changed.is_connected(_sync_controls):
		GameSettings.settings_changed.disconnect(_sync_controls)
	visible = false


func reset_to_defaults() -> void:
	GameSettings.reset_to_defaults()
	_sync_controls()
	_show_feedback("СБРОШЕНО К ДЕФОЛТАМ - ЕЩЁ НЕ СОХРАНЕНО")


func save_settings() -> void:
	GameSettings.save_settings()
	_show_feedback("СОХРАНЕНО")


func _show_feedback(text: String) -> void:
	_feedback.text = text
	_feedback.modulate.a = 1.0
	get_tree().create_timer(2.5).timeout.connect(func(): _feedback.modulate.a = 0.0)


func _show_audio() -> void:
	_audio_box.visible = true
	_video_box.visible = false
	_tab_audio.button_pressed = true
	_tab_video.button_pressed = false


func _show_video() -> void:
	_audio_box.visible = false
	_video_box.visible = true
	_tab_audio.button_pressed = false
	_tab_video.button_pressed = true


func _add_audio_row(bus_name: String) -> void:
	var row := HBoxContainer.new()
	var label := Label.new()
	label.text = String(SECTION_NAMES.get(bus_name, bus_name))
	label.custom_minimum_size = Vector2(210, 0)
	var slider := HSlider.new()
	slider.min_value = 0.0
	slider.max_value = 1.0
	slider.step = 0.01
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	slider.value = GameSettings.get_bus_volume(bus_name)
	var value_label := Label.new()
	value_label.custom_minimum_size = Vector2(64, 0)
	value_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	value_label.text = "%d%%" % int(slider.value * 100.0)
	slider.value_changed.connect(func(value: float):
		GameSettings.set_bus_volume(bus_name, value)
		value_label.text = "%d%%" % int(value * 100.0)
	)
	slider.drag_ended.connect(func(_value: float): FazSfx.play(FazSfx.Cue.CLICK))
	row.add_child(label)
	row.add_child(slider)
	row.add_child(value_label)
	_audio_box.add_child(row)
	_sliders[bus_name] = slider


func _populate_mode() -> void:
	_mode.clear()
	# Russian labels, internal engine keys in metadata: DisplayServer still wants "Fullscreen".
	for pair in [["Windowed", "В окне"], ["Borderless", "Без рамки"], ["Fullscreen", "Во весь экран"]]:
		_mode.add_item(pair[1])
		_mode.set_item_metadata(_mode.item_count - 1, pair[0])


func _populate_resolutions() -> void:
	_resolution.clear()
	_resolution.add_item("Как на рабочем столе")
	var native := DisplayServer.screen_get_size()
	for size in [Vector2i(1280, 720), Vector2i(1600, 900), Vector2i(1920, 1080), Vector2i(2560, 1440)]:
		if size.x > native.x or size.y > native.y:
			continue
		_resolution.add_item("%dx%d" % [size.x, size.y])


func _populate_fps() -> void:
	_max_fps.clear()
	for cap in [0, 30, 60, 90, 120, 144, 240]:
		_max_fps.add_item("Без ограничения" if cap == 0 else "%d кадров/с" % cap)
		_max_fps.set_item_metadata(_max_fps.item_count - 1, cap)


func _on_resolution_selected(index: int) -> void:
	var text := _resolution.get_item_text(index)
	if not text.contains("x"):
		return
	GameSettings.set_resolution(int(text.get_slice("x", 0)), int(text.get_slice("x", 1)))


## settings_changed carries the section name, so the handler has to accept it.
func _sync_controls(_section: StringName = &"") -> void:
	var wanted_mode := String(GameSettings.video.get("display_mode", "Windowed"))
	for i in _mode.item_count:
		if String(_mode.get_item_metadata(i)) == wanted_mode:
			_mode.selected = i
			break
	for i in _resolution.item_count:
		if _resolution.get_item_text(i) == String(GameSettings.video.get("resolution", "")):
			_resolution.selected = i
			break
	_vsync.button_pressed = bool(GameSettings.video.get("vsync", true))
	for i in _max_fps.item_count:
		if int(_max_fps.get_item_metadata(i)) == int(GameSettings.video.get("max_fps", 0)):
			_max_fps.selected = i
			break
	for bus_name in _sliders:
		var slider := _sliders[bus_name] as HSlider
		slider.value = GameSettings.get_bus_volume(String(bus_name))
