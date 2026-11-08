class_name GameplayPointer
extends RefCounted

# Android can reject pointer capture on touch-only devices. Keep the gameplay
# input lock separate from the OS pointer so touchscreen menus can use mouse emulation.
static var _touch_mode := Input.MOUSE_MODE_VISIBLE


static func get_mode() -> Input.MouseMode:
	return _touch_mode if OS.has_feature("android") else Input.mouse_mode


static func set_mode(mode: Input.MouseMode) -> void:
	if OS.has_feature("android"):
		_touch_mode = mode
	else:
		Input.mouse_mode = mode
