extends HBoxContainer

const ICONS := {
	"battery": preload("res://scenes/ui/inventory_icons/battery.svg"),
	"medkit": preload("res://scenes/ui/inventory_icons/medkit.svg"),
	"pills": preload("res://scenes/ui/inventory_icons/pills.svg"),
	"lamp": preload("res://scenes/ui/inventory_icons/lamp.svg"),
}
const SLOT_SIZE := Vector2(72, 72)

var _panels: Array[Panel] = []
var _icons: Array[TextureRect] = []
var _empty_style: StyleBoxFlat
var _filled_style: StyleBoxFlat


func _ready() -> void:
	_empty_style = _slot_style(Color(0.016, 0.030, 0.028, 0.77), Color(0.42, 0.59, 0.53, 0.25))
	_filled_style = _slot_style(Color(0.020, 0.038, 0.033, 0.92), Color(0.54, 0.73, 0.63, 0.48))
	for slot in range(GameState.INVENTORY_SIZE):
		var panel := Panel.new()
		panel.custom_minimum_size = SLOT_SIZE
		panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(panel)
		_panels.append(panel)

		var icon := TextureRect.new()
		icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
		icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		panel.add_child(icon)
		icon.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		icon.offset_left = 7
		icon.offset_right = -7
		icon.offset_top = 4
		icon.offset_bottom = -10
		_icons.append(icon)

		var key := Label.new()
		key.text = str(slot + 1)
		key.position = Vector2(-4, 47)
		key.mouse_filter = Control.MOUSE_FILTER_IGNORE
		key.add_theme_font_size_override("font_size", 20)
		key.add_theme_color_override("font_color", Color(0.90, 0.99, 0.93))
		key.add_theme_color_override("font_outline_color", Color(0.02, 0.05, 0.04))
		key.add_theme_constant_override("outline_size", 5)
		panel.add_child(key)

	GameState.player_wallet_updated.connect(_on_wallet_updated)
	_on_wallet_updated(SteamNet.local_peer_id, 0)


func _on_wallet_updated(peer_id: int, _balance: int) -> void:
	if peer_id != SteamNet.local_peer_id:
		return
	var slots := GameState.inventory_slots(peer_id)
	for slot in range(GameState.INVENTORY_SIZE):
		var texture: Texture2D = ICONS.get(slots[slot])
		_icons[slot].texture = texture
		_panels[slot].add_theme_stylebox_override("panel", _filled_style if texture else _empty_style)


func _slot_style(fill: Color, border: Color) -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = fill
	box.border_color = border
	box.set_border_width_all(1)
	box.border_width_top = 2
	box.shadow_color = Color(0, 0, 0, 0.40)
	box.shadow_size = 3
	box.shadow_offset = Vector2(0, 2)
	return box
