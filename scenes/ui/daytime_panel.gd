class_name DaytimePanel
extends PanelContainer
## One local overlay for the Office PC and the 17:00 report. The figures come
## from GameState, so host, guests and late joiners read the same settlement.

var _daytime: DaytimeManager
var _heading: Label
var _summary: Label
var _notice: Label
var _scroll: ScrollContainer
var _catalog: VBoxContainer
var _start: Button
var _night: Button
var _close: Button
var _buy: Dictionary[int, Button] = {}
var _reported_day: int = 0
var _showing_report: bool = false


func _ready() -> void:
	hide()
	theme = FazTheme.get_theme()
	custom_minimum_size.x = 490.0
	var margin: MarginContainer = MarginContainer.new()
	for edge: String in ["left", "top", "right", "bottom"]:
		margin.add_theme_constant_override("margin_" + edge, 22)
	add_child(margin)
	var column: VBoxContainer = VBoxContainer.new()
	column.add_theme_constant_override("separation", 10)
	margin.add_child(column)
	_heading = Label.new()
	_heading.add_theme_font_size_override("font_size", 24)
	column.add_child(_heading)
	_summary = Label.new()
	_summary.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(_summary)
	_scroll = ScrollContainer.new()
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.custom_minimum_size.y = 200.0
	column.add_child(_scroll)
	_catalog = VBoxContainer.new()
	_catalog.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll.add_child(_catalog)
	_notice = Label.new()
	_notice.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(_notice)
	_start = _button(column, "Открыть пиццерию  •  09:00–17:00")
	_night = _button(column, "Начать ночную смену")
	_close = _button(column, "Закрыть")
	_close.pressed.connect(close)


func bind(manager: DaytimeManager) -> void:
	_daytime = manager
	_start.pressed.connect(_daytime.request_open)
	_night.pressed.connect(_daytime.request_night)
	for prop: InteractiveProp in _daytime.catalog():
		if prop.price > 0:
			var button: Button = _button(_catalog, "")
			button.pressed.connect(_daytime.request_buy.bind(prop.prop_id))
			_buy[prop.prop_id] = button


func _button(parent: VBoxContainer, caption: String) -> Button:
	var button: Button = Button.new()
	button.text = caption
	button.custom_minimum_size.y = 38.0
	button.pressed.connect(_play_click)
	parent.add_child(button)
	return button


func _play_click() -> void:
	FazSfx.play(FazSfx.Cue.CLICK)


func open_terminal() -> void:
	if not GameState.daytime_report.is_empty():
		_show_report()
		return
	_showing_report = false
	_open()
	if _start.visible and not _start.disabled:
		_start.grab_focus()


func _show_report() -> void:
	_reported_day = int(GameState.daytime_report.get("day", 0))
	_showing_report = true
	_open()
	if _night.visible:
		_night.grab_focus()


func _open() -> void:
	refresh()
	show()
	GameplayPointer.set_mode(Input.MOUSE_MODE_VISIBLE)
	_close.grab_focus()


func close() -> void:
	if visible:
		hide()
		GameplayPointer.set_mode(Input.MOUSE_MODE_CAPTURED)


func present_pending_report() -> void:
	var day: int = int(GameState.daytime_report.get("day", 0))
	if day > 0 and day != _reported_day:
		_show_report()


func refresh() -> void:
	if _showing_report:
		var report: Dictionary = GameState.daytime_report
		var sales: int = int(report.get("sales", 0))
		var tips: int = int(report.get("tips", 0))
		var penalties: int = int(report.get("penalties", 0))
		_caption(_heading, "17:00  ·  ИТОГИ ДНЕВНОЙ СМЕНЫ")
		_caption(_summary, ("Всего заработано  $%d\nВыручка от гостей  $%d\nЧаевые  $%d\n" +
			"Штрафы за обслуживание  −$%d\nЧистый доход  $%d\nУют  %d\nОбщая касса  $%d") % [
			sales + tips, sales, tips, penalties, sales + tips - penalties,
			int(report.get("cozy_level", 0)), int(report.get("balance", 0)),
		])
		_scroll.hide()
		_notice.hide()
		_start.hide()
		_night.visible = GameState.is_host()
		return

	_caption(_heading, "FAZ / УПРАВЛЕНИЕ ПИЦЦЕРИЕЙ")
	_caption(_summary, "Общая касса  $%d   ·   Уют  %d\n%s" % [
		GameState.business_balance, GameState.cozy_level,
		"Открыто до 17:00" if GameState.daytime_open else "Утро · смена по желанию",
	])
	var host: bool = GameState.is_host()
	_scroll.show()
	_night.hide()
	_start.visible = host and not GameState.daytime_open
	_notice.show()
	var help: String = "Украшения устанавливаются в зале сразу после покупки." if host else "Открывать смену и покупать украшения может владелец."
	_caption(_notice, _daytime.feedback if not _daytime.feedback.is_empty() else help)
	for prop: InteractiveProp in _daytime.catalog():
		if not _buy.has(prop.prop_id):
			continue
		var button: Button = _buy[prop.prop_id]
		var price: String = "УСТАНОВЛЕНО" if prop.installed else "$%d" % prop.price
		_caption(button, "%s  ·  +%d уют  ·  %s" % [prop.display_name, prop.cozy_value, price])
		button.disabled = not host or prop.installed or prop.price > GameState.business_balance


func _caption(control: Control, caption: String) -> void:
	if control is Label:
		var label: Label = control as Label
		if label.text != caption:
			label.text = caption
	elif control is Button:
		var button: Button = control as Button
		if button.text != caption:
			button.text = caption
