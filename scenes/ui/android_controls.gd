extends Node2D

const RADIUS := 66.0
const BUTTON_RADIUS := 43.0
const BUTTONS := {
	&"interact": "ДЕЙСТВИЕ",
	&"inventory_grab": "ВЗЯТЬ",
	&"jump": "ПРЫЖОК",
	&"sprint": "БЕГ",
	&"crouch": "ПРИСЕСТЬ",
	&"toggle_flashlight": "СВЕТ",
	&"reload_battery": "БАТАРЕЯ",
	&"toggle_tablet": "ПЛАНШЕТ",
	&"UI_Cancel": "ПАУЗА",
}
const REPAIR_KEYS := [KEY_W, KEY_A, KEY_S, KEY_D]
const MOVE_ACTIONS := [&"move_left", &"move_right", &"move_forward", &"move_back"]

var repair_active := false
var security_active := false
var inventory_bar: HBoxContainer

var _stick := -1
var _look := -1
var _movement := Vector2.ZERO
var _fingers: Dictionary[int, StringName] = {}
var _buttons: Dictionary[StringName, Vector2] = {}
var _stick_center := Vector2.ZERO
var _safe := Rect2()
var _active := false


func _process(_delta: float) -> void:
	var active := GameplayPointer.get_mode() == Input.MOUSE_MODE_CAPTURED 		and GameState.is_world_phase()
	if _active and not active:
		_reset_input()
	_active = active
	_layout()
	queue_redraw()


func _layout() -> void:
	_safe = get_viewport_rect().grow(-24.0)
	var safe_pixels := DisplayServer.get_display_safe_area()
	if OS.has_feature("android") and safe_pixels.has_area():
		var screen_to_canvas := get_viewport().get_screen_transform().affine_inverse()
		var safe_local := screen_to_canvas * Rect2(safe_pixels)
		var intersection := get_viewport_rect().intersection(safe_local)
		if intersection.size.x >= 640.0 and intersection.size.y >= 360.0:
			_safe = intersection.grow(-24.0)
	var right := _safe.end.x
	var bottom := _safe.end.y
	_stick_center = Vector2(_safe.position.x + 94.0, bottom - 140.0)
	_buttons.clear()
	if not _active:
		if security_active:
			_buttons[&"UI_Cancel"] = Vector2(right - 48.0, _safe.position.y + 48.0)
		return
	_buttons[&"UI_Cancel"] = Vector2(right - 48.0, _safe.position.y + 48.0)
	if _is_dead():
		return
	if repair_active:
		for index in REPAIR_KEYS.size():
			var caption := StringName(OS.get_keycode_string(REPAIR_KEYS[index]))
			_buttons[caption] = Vector2(_safe.get_center().x + (index - 1.5) * 104.0, bottom - 226.0)
		return
	_buttons[&"toggle_tablet"] = Vector2(right - 148.0, _safe.position.y + 48.0)
	_buttons[&"toggle_flashlight"] = Vector2(right - 48.0, bottom - 336.0)
	_buttons[&"reload_battery"] = Vector2(right - 148.0, bottom - 336.0)
	_buttons[&"interact"] = Vector2(right - 48.0, bottom - 236.0)
	_buttons[&"inventory_grab"] = Vector2(right - 148.0, bottom - 236.0)
	_buttons[&"jump"] = Vector2(right - 48.0, bottom - 136.0)
	_buttons[&"crouch"] = Vector2(right - 148.0, bottom - 136.0)
	_buttons[&"sprint"] = Vector2(_safe.position.x + 90.0, bottom - 270.0)


func _draw() -> void:
	if _active and not repair_active and not _is_dead():
		draw_circle(_stick_center, RADIUS + 24.0, Color(0.03, 0.06, 0.10, 0.55), true, -1.0, true)
		draw_arc(_stick_center, RADIUS + 24.0, 0.0, TAU, 48, Color(0.62, 0.78, 0.92, 0.65), 2.0, true)
		draw_circle(_stick_center + _movement * RADIUS, 31.0, Color(0.65, 0.82, 0.96, 0.74), true, -1.0, true)
	var font := ThemeDB.fallback_font
	for action in _buttons:
		var center := _buttons[action]
		var radius := BUTTON_RADIUS
		var held := action in _fingers.values()
		draw_circle(center, radius, Color(0.14, 0.30, 0.43, 0.92) if held else Color(0.03, 0.06, 0.10, 0.77), true, -1.0, true)
		draw_arc(center, radius, 0.0, TAU, 40, Color(0.62, 0.78, 0.92, 0.75), 2.0, true)
		var title := "ВЫХОД" if security_active and action == &"UI_Cancel" else String(BUTTONS.get(action, action))
		var width := font.get_string_size(title, HORIZONTAL_ALIGNMENT_LEFT, -1.0, 13).x
		draw_string(font, center + Vector2(-width * 0.5, 5.0), title, HORIZONTAL_ALIGNMENT_LEFT, -1.0, 13, Color.WHITE)


func _input(event: InputEvent) -> void:
	if _active and event is InputEventMouse and event.device == InputEvent.DEVICE_ID_EMULATION:
		get_viewport().set_input_as_handled()
		return
	if event is InputEventScreenTouch:
		if event.pressed:
			if not _begin_touch(event.index, event.position):
				return
		elif not _end_touch(event.index):
			return
	elif event is InputEventScreenDrag:
		if event.index == _stick:
			_set_movement(((event.position - _stick_center) / RADIUS).limit_length())
		elif event.index == _look and _active and not repair_active:
			var motion := InputEventMouseMotion.new()
			motion.relative = event.relative * 1.8
			get_viewport().push_input.call_deferred(motion, true)
		elif not _fingers.has(event.index):
			return
	else:
		return
	get_viewport().set_input_as_handled()


func _begin_touch(index: int, position: Vector2) -> bool:
	for action in _buttons:
		if position.distance_to(_buttons[action]) <= BUTTON_RADIUS:
			if action not in _fingers.values():
				_fingers[index] = action
				_send(action, true)
			return true
	if not _active:
		return false
	if not repair_active and not _is_dead():
		if inventory_bar != null and inventory_bar.is_visible_in_tree():
			for slot in inventory_bar.get_child_count():
				var panel := inventory_bar.get_child(slot) as Control
				if panel.get_global_rect().has_point(position):
					var action := StringName("inventory_slot_%d" % (slot + 1))
					if action not in _fingers.values():
						_fingers[index] = action
						_send(action, true)
					return true
		if _stick < 0 and position.distance_to(_stick_center) <= RADIUS + 24.0:
			_stick = index
			_set_movement(((position - _stick_center) / RADIUS).limit_length())
		elif _look < 0 and position.x > _safe.position.x + 220.0:
			_look = index
	return true


func _end_touch(index: int) -> bool:
	if _fingers.has(index):
		_send(_fingers[index], false)
		_fingers.erase(index)
	elif index == _stick:
		_stick = -1
		_set_movement(Vector2.ZERO)
	elif index == _look:
		_look = -1
	else:
		return _active
	return true


func _is_dead() -> bool:
	return GameState.is_dead(SteamNet.local_peer_id)


func _send(action: StringName, pressed: bool) -> void:
	if InputMap.has_action(action):
		var event := InputEventAction.new()
		event.action = action
		event.pressed = pressed
		Input.parse_input_event.call_deferred(event)
	else:
		var key := InputEventKey.new()
		key.physical_keycode = OS.find_keycode_from_string(action)
		key.pressed = pressed
		get_viewport().push_input.call_deferred(key, true)


func _set_movement(movement: Vector2) -> void:
	_movement = movement
	var strengths := [-movement.x, movement.x, -movement.y, movement.y]
	for i in MOVE_ACTIONS.size():
		var strength := float(strengths[i])
		if strength > 0.12:
			Input.action_press(MOVE_ACTIONS[i], inverse_lerp(0.12, 1.0, strength))
		else:
			Input.action_release(MOVE_ACTIONS[i])


func _reset_input() -> void:
	_stick = -1
	_look = -1
	_set_movement(Vector2.ZERO)
	for action in _fingers.values():
		_send(action, false)
	_fingers.clear()


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		_reset_input()
	elif what == NOTIFICATION_WM_GO_BACK_REQUEST:
		_send(&"UI_Cancel", true)
		_send(&"UI_Cancel", false)


func _exit_tree() -> void:
	_reset_input()
