class_name PauseMenu
extends Control

## PauseMenu - local overlay for an in-progress session.
##
## Network rule this file exists to enforce: opening it does NOT pause the tree and does
## NOT touch Engine.time_scale. In a co-op session the world, monsters and other players'
## movement keep simulating; the overlay only captures this player's mouse and input.

@onready var _overlay: Control = get_node("Overlay")
@onready var _info: Label = get_node("Overlay/Center/Panel/Margin/Column/Info")
@onready var _crew: Label = get_node("Overlay/Center/Panel/Margin/Column/Crew")
@onready var _resume_button: Button = get_node("Overlay/Center/Panel/Margin/Column/ResumeButton")
@onready var _settings_button: Button = get_node("Overlay/Center/Panel/Margin/Column/SettingsButton")
@onready var _disconnect_button: Button = get_node("Overlay/Center/Panel/Margin/Column/DisconnectButton")
@onready var _settings: CanvasLayer = get_node("Settings")

@onready var _save_button: Button = $Overlay/Center/Panel/Margin/Column/SaveButton
@onready var _save_slots: VBoxContainer = $Overlay/Center/Panel/Margin/Column/SaveSlots
@onready var _save_status: Label = _save_slots.get_node("Status") as Label

var _slot_buttons: Array[Button] = []
var _confirm_slot: int = 0
var _in_menu := false


func _ready() -> void:
	theme = FazTheme.get_theme()
	_overlay.visible = false
	for button in [_resume_button, _settings_button, _disconnect_button]:
		button.pressed.connect(func(): FazSfx.play(FazSfx.Cue.CLICK))
		button.mouse_entered.connect(func(): FazSfx.play(FazSfx.Cue.HOVER))
	_save_button.pressed.connect(_open_save_slots)
	var back: Button = _save_slots.get_node("Back") as Button
	back.pressed.connect(_close_save_slots)
	for slot: int in range(1, SaveManager.SLOT_COUNT + 1):
		var button: Button = _save_slots.get_node("Slot%d" % slot) as Button
		button.pressed.connect(_save_slot.bind(slot))
		_slot_buttons.append(button)
	_resume_button.pressed.connect(close)
	_settings_button.pressed.connect(_settings.open_menu)
	_disconnect_button.pressed.connect(_on_disconnect_pressed)
	GameState.state_changed.connect(_refresh)


func _unhandled_input(event: InputEvent) -> void:
	if _in_menu or not event.is_action_pressed("UI_Cancel"):
		return
	if _settings.visible:
		_settings.close()
		get_viewport().set_input_as_handled()
		return
	if _save_slots.visible:
		_close_save_slots()
	else:
		toggle()
	get_viewport().set_input_as_handled()


func is_open() -> bool:
	return _overlay.visible


func toggle() -> void:
	if is_open():
		close()
	else:
		open()


func open() -> void:
	_overlay.visible = true
	_save_button.disabled = not SteamNet.is_host
	_save_button.tooltip_text = "Сохранять кампанию может хост" if _save_button.disabled else ""
	# The overlay is a UI-only freeze: time_scale stays 1.0 and the tree stays unpaused.
	Engine.time_scale = 1.0
	get_tree().paused = false
	GameplayPointer.set_mode(Input.MOUSE_MODE_VISIBLE)
	_refresh()
	SteamNet.note("[pause] open (world still running, time_scale=%s)" % Engine.time_scale)


func close() -> void:
	_overlay.visible = false
	_set_save_view(false)
	if not _in_menu:
		GameplayPointer.set_mode(Input.MOUSE_MODE_CAPTURED)
	SteamNet.note("[pause] closed")


func _open_save_slots() -> void:
	if not SteamNet.is_host:
		return
	_confirm_slot = 0
	_save_status.text = "После записи автосохранение будет использовать этот слот."
	_refresh_save_slots()
	_set_save_view(true)
	for button: Button in _slot_buttons:
		if not button.disabled:
			button.grab_focus()
			break


func _close_save_slots() -> void:
	_set_save_view(false)
	_save_button.grab_focus()


func _set_save_view(active: bool) -> void:
	_confirm_slot = 0
	for child: Node in _save_slots.get_parent().get_children():
		var control: Control = child as Control
		control.visible = active if control == _save_slots else not active


func _refresh_save_slots() -> void:
	for index: int in _slot_buttons.size():
		var slot: int = index + 1
		var result: Dictionary = SaveManager.slot_summary(slot)
		var button: Button = _slot_buttons[index]
		button.text = SaveManager.slot_caption(slot, result)
		if slot == SaveManager.active_slot:
			button.text += "  ·  Текущий"
		button.disabled = int(result["error"]) not in [OK, ERR_FILE_NOT_FOUND]


func _save_slot(slot: int) -> void:
	if not SteamNet.is_host:
		return
	var result: Dictionary = SaveManager.slot_summary(slot)
	if int(result["error"]) == OK and slot != SaveManager.active_slot and _confirm_slot != slot:
		_confirm_slot = slot
		_save_status.text = "Слот %d занят. Нажмите на него ещё раз, чтобы перезаписать." % slot
		return
	_confirm_slot = 0
	var error: Error = SaveManager.save_to_slot(slot)
	_save_status.text = "Кампания сохранена в слот %d." % slot if error == OK \
		else "Не удалось сохранить кампанию. Проверьте доступ к папке сохранений."
	_refresh_save_slots()


func _on_disconnect_pressed() -> void:
	# Game owns the route back to the menu; this overlay only asks for the session to end.
	_in_menu = true
	close()
	SteamNet.leave_session("Выход из игры")


func _refresh(_key: StringName = &"") -> void:
	if not _overlay.visible:
		return
	var wallet := GameState.local_wallet()
	_info.text = "Смена: %s\nДень %d | До квоты: %d дн.\nКвота $%d | Сдано $%d | Долг $%d\nТвой баланс $%d | Лом в руках $%d" % [
		GameState.phase_name(),
		GameState.day_index,
		GameState.days_until_quota(),
		GameState.quota_cents,
		GameState.earnings_cents,
		GameState.debt_cents,
		int(wallet.get("balance", 0)),
		int(wallet.get("scrap_value", 0)),
	]
	var lines := PackedStringArray()
	for peer_id in GameState.players:
		lines.append("- %s : $%d" % [
			String(GameState.players[peer_id].get("name", "Игрок")),
			int(GameState.players[peer_id].get("balance", 0)),
		])
	_crew.text = "ЭКИПАЖ\n" + "\n".join(lines)
