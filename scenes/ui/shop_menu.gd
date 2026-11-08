class_name ShopMenu
extends CanvasLayer

## Pizzeria counter shop: opened by holding E at the counter in the hub. Purchases are paid
## from the wallet balance on the server, so every peer sees the same money and inventory.

@onready var _root: Control = get_node("Root")
@onready var _balance: Label = get_node("Root/Center/Panel/Margin/Column/Balance")
@onready var _items: VBoxContainer = get_node("Root/Center/Panel/Margin/Column/Items")
@onready var _info: Label = get_node("Root/Center/Panel/Margin/Column/Info")
@onready var _close: Button = get_node("Root/Center/Panel/Margin/Column/Head/CloseX")


func _ready() -> void:
	_root.theme = FazTheme.get_theme()
	_root.visible = false
	_close.pressed.connect(close)
	GameState.player_wallet_updated.connect(_on_wallet)
	GameState.shop_purchase_finished.connect(_show_purchase_result)
	for item_id in GameState.SHOP_ITEMS:
		var entry: Dictionary = GameState.SHOP_ITEMS[item_id]
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 12)
		var label := Label.new()
		label.text = "%s - $%d" % [String(entry["name"]), int(entry["price"])]
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(label)
		var buy := Button.new()
		buy.text = "КУПИТЬ"
		buy.pressed.connect(_on_buy.bind(String(item_id)))
		row.add_child(buy)
		_items.add_child(row)


func is_open() -> bool:
	return _root.visible


func _unhandled_input(event: InputEvent) -> void:
	if _root.visible and event.is_action_pressed("UI_Cancel"):
		close()
		get_viewport().set_input_as_handled()


func open() -> void:
	_root.visible = true
	# The counter is a UI moment: the mouse must be free to click КУПИТЬ and the ×.
	GameplayPointer.set_mode(Input.MOUSE_MODE_VISIBLE)
	_info.text = "Покупки занимают свободные слоты 1–3."
	_refresh()


func close() -> void:
	_root.visible = false
	var scene := get_tree().current_scene
	var tablet := scene.get_node_or_null("UI/Tablet") as Tablet if scene != null else null
	var pause := scene.get_node_or_null("UI/Pause") as PauseMenu if scene != null else null
	if (tablet == null or not tablet.is_open()) and (pause == null or not pause.is_open()):
		GameplayPointer.set_mode(Input.MOUSE_MODE_CAPTURED)


func _on_buy(item_id: String) -> void:
	FazSfx.play(FazSfx.Cue.CLICK)
	_info.text = "Проверяем покупку…"
	GameState.request_buy_item(item_id)


func _show_purchase_result(item_id: String, error: String) -> void:
	_info.text = error if error != "" else "Куплено: %s" % GameState.SHOP_ITEMS[item_id]["name"]


func _refresh() -> void:
	_balance.text = "Баланс: $%d" % int(GameState.local_wallet().get("balance", 0))


func _on_wallet(_peer: int, _balance: int) -> void:
	if _root.visible:
		_refresh()
