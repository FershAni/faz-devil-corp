class_name FazTheme

## One dark theme for every overlay (menu, pause, settings), built in code so the StyleBox
## geometry stays reviewable in diffs instead of hiding in a .tres blob.

const INK := Color(0.90, 0.88, 0.84)
const INK_DIM := Color(0.62, 0.60, 0.57)
const BLOOD := Color(0.66, 0.09, 0.10)
const BLOOD_HI := Color(0.88, 0.20, 0.16)
const PANEL := Color(0.045, 0.045, 0.055, 0.92)
const SLOT := Color(0.09, 0.09, 0.11, 1.0)

static var _cached: Theme


static func get_theme() -> Theme:
	if _cached != null:
		return _cached
	var theme := Theme.new()
	theme.default_font_size = 17
	theme.set_color("font_color", "Label", INK)
	theme.set_color("font_shadow_color", "Label", Color(0, 0, 0, 0.9))
	theme.set_constant("shadow_offset_x", "Label", 1)
	theme.set_constant("shadow_offset_y", "Label", 2)
	theme.set_font_size("font_size", "Label", 17)

	_apply_buttons(theme)
	_apply_panels(theme)
	_apply_inputs(theme)
	_cached = theme
	return theme


static func _apply_buttons(theme: Theme) -> void:
	var normal := _button(SLOT, 0.0)
	var hover := _button(SLOT.lightened(0.08), 0.0)
	hover.border_color = BLOOD_HI
	var pressed := _button(BLOOD.darkened(0.35), 0.0)
	var focus := _button(SLOT, 1.0)
	focus.border_color = BLOOD_HI
	theme.set_stylebox("normal", "Button", normal)
	theme.set_stylebox("hover", "Button", hover)
	theme.set_stylebox("pressed", "Button", pressed)
	theme.set_stylebox("disabled", "Button", _button(Color(0.06, 0.06, 0.07, 1.0), 0.0))
	theme.set_stylebox("focus", "Button", focus)
	theme.set_color("font_color", "Button", INK)
	theme.set_color("font_hover_color", "Button", Color.WHITE)
	theme.set_color("font_pressed_color", "Button", Color.WHITE)
	theme.set_color("font_disabled_color", "Button", Color(0.4, 0.4, 0.42))
	theme.set_font_size("font_size", "Button", 18)
	theme.set_constant("h_separation", "ButtonBox", 8)
	theme.set_color("font_color", "CheckBox", INK)
	theme.set_color("font_hover_color", "CheckBox", Color.WHITE)
	theme.set_color("font_pressed_color", "CheckButton", INK)


static func _apply_panels(theme: Theme) -> void:
	var panel := StyleBoxFlat.new()
	panel.bg_color = PANEL
	panel.border_width_left = 1
	panel.border_width_top = 1
	panel.border_width_right = 1
	panel.border_width_bottom = 1
	panel.border_color = Color(BLOOD.r, BLOOD.g, BLOOD.b, 0.55)
	panel.content_margin_left = 18.0
	panel.content_margin_top = 16.0
	panel.content_margin_right = 18.0
	panel.content_margin_bottom = 16.0
	theme.set_stylebox("panel", "PanelContainer", panel)
	theme.set_stylebox("panel", "Panel", panel)

	var tab := StyleBoxFlat.new()
	tab.bg_color = Color(0.05, 0.05, 0.06, 0.95)
	tab.border_color = Color(BLOOD.r, BLOOD.g, BLOOD.b, 0.5)
	tab.set_border_width_all(1)
	tab.set_content_margin_all(14.0)
	theme.set_stylebox("panel", "TabContainer", tab)
	theme.set_color("font_selected_color", "TabContainer", Color.WHITE)
	theme.set_color("font_color", "TabContainer", INK_DIM)


static func _apply_inputs(theme: Theme) -> void:
	theme.set_stylebox("normal", "LineEdit", _slot())
	theme.set_stylebox("focus", "LineEdit", _slot(BLOOD_HI))
	theme.set_color("font_color", "LineEdit", INK)
	theme.set_color("font_placeholder_color", "LineEdit", Color(0.45, 0.44, 0.46))

	theme.set_stylebox("normal", "ItemList", _slot())
	theme.set_stylebox("selected_focus", "ItemList", _slot(BLOOD_HI))
	theme.set_stylebox("cursor", "ItemList", _slot(BLOOD))
	theme.set_color("font_selected_color", "ItemList", Color.WHITE)

	theme.set_stylebox("grabber_area_highlight", "HSlider", _gutter(BLOOD_HI))
	theme.set_stylebox("grabber_area", "HSlider", _gutter(Color(0.32, 0.33, 0.36)))
	theme.set_stylebox("slider", "HSlider", _gutter(SLOT))
	var grab := StyleBoxFlat.new()
	grab.bg_color = INK
	grab.set_content_margin_all(4.0)
	theme.set_stylebox("grabber", "HSlider", grab)

	theme.set_stylebox("normal", "OptionButton", _button(SLOT, 0.0))
	theme.set_stylebox("hover", "OptionButton", _button(SLOT.lightened(0.08), 0.0))
	theme.set_stylebox("selected", "OptionButton", _button(BLOOD, 0.0))
	theme.set_color("font_color", "OptionButton", INK)

	var scroll := _gutter(Color(0.10, 0.10, 0.12, 0.9))
	theme.set_stylebox("scroll", "VScrollBar", scroll)
	theme.set_stylebox("scroll", "HScrollBar", scroll)
	theme.set_stylebox("grabber", "VScrollBar", _gutter(Color(0.28, 0.28, 0.32)))
	theme.set_stylebox("grabber", "HScrollBar", _gutter(Color(0.28, 0.28, 0.32)))


static func _button(fill: Color, border: int, edge: Color = BLOOD) -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = fill
	box.set_border_width_all(border)
	box.border_color = edge
	box.corner_radius_top_left = 2
	box.corner_radius_top_right = 2
	box.corner_radius_bottom_left = 2
	box.corner_radius_bottom_right = 2
	box.content_margin_left = 14.0
	box.content_margin_top = 9.0
	box.content_margin_right = 14.0
	box.content_margin_bottom = 9.0
	return box


static func _slot(edge: Color = Color(0.18, 0.18, 0.21)) -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = SLOT
	box.set_border_width_all(1)
	box.border_color = edge
	box.content_margin_left = 10.0
	box.content_margin_top = 6.0
	box.content_margin_right = 10.0
	box.content_margin_bottom = 6.0
	return box


static func _gutter(fill: Color) -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = fill
	box.set_content_margin_all(3.0)
	return box
