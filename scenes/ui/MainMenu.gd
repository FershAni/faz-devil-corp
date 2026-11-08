extends Control

## MainMenu - two levels.
## Level 1 (the scene itself): СОЗДАТЬ ИГРУ / НАСТРОЙКИ / КАК ИГРАТЬ / ВЫХОД.
## Level 2 (NetMenu overlay): host a Steam lobby, browse lobbies, or connect by address.
## Esc always steps back one level. Everything network-facing is delegated to SteamNet.
## The look is a dark pizzeria back-office: a 3D backdrop drifting toward something that
## is standing in the fog, a CRT overlay on top, and a procedural ambience bed.

const GAME_SCENE := "res://scenes/game/Game.tscn"

enum PanelMode { NONE, LOBBIES, FRIENDS }

const MEMOS := [
	"Напоминание: найденный лом принадлежит FazDevil Corp.",
	"Табличка над проходом показывает соседний сектор.",
	"Работающий фонарик - привилегия, а не право.",
	"Два сорванных квоты - и здание подаст на тебя в суд само.",
	"Вентиляция - это не shortcut. Это приглашение.",
	"Сломанные двери - в заявку maintenance. Maintenance закрыт.",
	"Кошки в подсобке не существует. Отчёт 41-B подтверждает.",
]

@onready var _rig: Node3D = get_node("World/Rig")
@onready var _lamp: OmniLight3D = get_node("World/Lamp")
@onready var _dust: CPUParticles3D = get_node("World/Dust")
@onready var _backdrop: ColorRect = get_node("Backdrop")
@onready var _background: ColorRect = get_node("Background")
@onready var _title: Label = get_node("Title")
@onready var _menu_box: VBoxContainer = get_node("MenuBox")
@onready var _host_button: Button = get_node("MenuBox/HostButton")
@onready var _settings_button: Button = get_node("MenuBox/SettingsButton")
@onready var _help_button: Button = get_node("MenuBox/HelpButton")
@onready var _exit_button: Button = get_node("MenuBox/ExitButton")
@onready var _net_menu: CanvasLayer = get_node("NetMenu")
@onready var _host_steam_button: Button = get_node("NetMenu/Root/Panel/Margin/Column/HostSteamButton")
@onready var _public_lobby: CheckButton = get_node("NetMenu/Root/Panel/Margin/Column/PublicLobby")
@onready var _find_button: Button = get_node("NetMenu/Root/Panel/Margin/Column/FindButton")
@onready var _net_status: Label = get_node("NetMenu/Root/Panel/Margin/Column/NetStatus")
@onready var _back_button: Button = get_node("NetMenu/Root/Panel/Margin/Column/BackButton")
@onready var _side_panel: PanelContainer = get_node("NetMenu/Root/SidePanel")
@onready var _header: Label = get_node("NetMenu/Root/SidePanel/Margin/Column/HeaderRow/Header")
@onready var _panel_close_x: Button = get_node("NetMenu/Root/SidePanel/Margin/Column/HeaderRow/PanelCloseX")
@onready var _list: ItemList = get_node("NetMenu/Root/SidePanel/Margin/Column/List")
@onready var _refresh_button: Button = get_node("NetMenu/Root/SidePanel/Margin/Column/Row/RefreshButton")
@onready var _source_button: Button = get_node("NetMenu/Root/SidePanel/Margin/Column/Row/SourceButton")
@onready var _join_button: Button = get_node("NetMenu/Root/SidePanel/Margin/Column/Row/JoinButton")
@onready var _invite_button: Button = get_node("NetMenu/Root/SidePanel/Margin/Column/Row/InviteButton")
@onready var _info_label: Label = get_node("InfoLabel")
@onready var _ticker: Label = get_node("Ticker")
@onready var _help: CanvasLayer = get_node("Help")
@onready var _settings: CanvasLayer = get_node("Settings")
@onready var _music: AudioStreamPlayer = get_node("MenuMusic")

@onready var _slots_panel: PanelContainer = $NetMenu/Root/SaveSlots
@onready var _slots_column: VBoxContainer = $NetMenu/Root/SaveSlots/Margin/Slots
@onready var _join_game: Button = $MenuBox/JoinGameButton

@onready var _delete_button: Button = $NetMenu/Root/SaveSlots/Margin/Slots/DeleteSlotButton
@onready var _delete_confirm: ConfirmationDialog = $DeleteConfirm
var _deleting_slot: bool = false
var _delete_target: int = 0

var _slot_buttons: Array[Button] = []
var _hosting_slot: bool = false
var _mode: int = PanelMode.NONE
var _invited_lobby := 0
var _friend_to_invite: int = 0
var _flicker := 0.0
var _memo_at := 0.0
var _memo_index := 0


func _ready() -> void:
	Engine.time_scale = 1.0
	GameplayPointer.set_mode(Input.MOUSE_MODE_VISIBLE)
	theme = FazTheme.get_theme()
	# The menu room gets the same grade as the game, or the first frame of the build looks
	# like a different product than the one behind the buttons.
	Look.apply(get_node("World/Env") as WorldEnvironment, Look.MENU)
	var menu_lamp := get_node("World/Lamp") as OmniLight3D
	if menu_lamp != null:
		menu_lamp.light_volumetric_fog_energy = 2.6
	_side_panel.visible = false
	_slots_panel.theme = FazTheme.get_theme()
	_wire_buttons()
	if OS.has_feature("android"):
		_host_button.text = "ОДИНОЧНАЯ ИГРА"
		_join_game.hide()
		_help_button.hide()
		_host_steam_button.hide()
		_find_button.hide()
		_public_lobby.hide()
		$NetMenu/Root/Panel/Margin/Column/NetHint.hide()
		$NetMenu/Root/Panel/Margin/Column/Title.text = "ОДИНОЧНАЯ ИГРА"
	_build_dust()
	SteamNet.status.connect(_on_status)
	SteamNet.lobby_list_updated.connect(_fill_lobbies)
	SteamNet.friends_updated.connect(_fill_friends)
	SteamNet.invite_received.connect(_on_invite_received)
	SteamNet.session_started.connect(_on_session_started)
	SteamNet.host_failed.connect(_on_host_failed)
	_animate_backdrop()
	_play_menu_music()
	_next_memo()
	_refresh_info()
	if SteamNet.last_status != "":
		_set_status(SteamNet.last_status)
	if SteamNet.available():
		# A session can already be up before this scene finishes loading (auto-host, invites).
		_on_session_started(SteamNet.is_host, SteamNet.transport_name())


func _wire_buttons() -> void:
	var buttons: Array[Button] = [_host_button, _join_game, _settings_button, _help_button, _exit_button,
		_host_steam_button, _find_button, _back_button, _panel_close_x,
		_refresh_button, _source_button, _join_button, _invite_button]
	for button in buttons:
		button.pressed.connect(_click)
		button.mouse_entered.connect(_hover)
	_delete_button.pressed.connect(_toggle_delete_mode)
	_delete_confirm.confirmed.connect(_delete_selected_slot)
	_host_button.pressed.connect(_on_host_pressed)
	_join_game.pressed.connect(_on_find_pressed)
	for slot: int in range(1, SaveManager.SLOT_COUNT + 1):
		var button: Button = _slots_column.get_node("Slot%d" % slot) as Button
		button.pressed.connect(_click)
		button.pressed.connect(_select_slot.bind(slot))
		button.mouse_entered.connect(_hover)
		_slot_buttons.append(button)
	_settings_button.pressed.connect(_settings.open_menu)
	_help_button.pressed.connect(open_help)
	_exit_button.pressed.connect(_on_exit_pressed)
	_host_steam_button.pressed.connect(_on_host_pressed)
	_find_button.pressed.connect(_on_find_pressed)
	_back_button.pressed.connect(close_net_menu)
	_panel_close_x.pressed.connect(_close_panel)
	_source_button.pressed.connect(_on_source_pressed)
	_refresh_button.pressed.connect(_on_refresh_pressed)
	_join_button.pressed.connect(_on_join_pressed)
	_invite_button.pressed.connect(_on_invite_pressed)
	_help.get_node("Root/Center/Panel/Margin/Column/CloseHelp").pressed.connect(close_help)
	_public_lobby.toggled.connect(func(_pressed: bool): _click())
	_list.item_activated.connect(_on_list_activated)


## Esc steps back one level: the topmost overlay first, then the list, then the net menu.
func _unhandled_input(event: InputEvent) -> void:
	if not event.is_action_pressed("UI_Cancel"):
		return
	if _settings.visible:
		_settings.close()
	elif _help.visible:
		close_help()
	elif _slots_panel.visible and not _hosting_slot:
		_deleting_slot = false
		if OS.has_feature("android"):
			close_net_menu()
		else:
			_slots_panel.hide()
	elif _side_panel.visible:
		_close_panel()
	elif _net_menu.visible:
		close_net_menu()
	else:
		return
	get_viewport().set_input_as_handled()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_GO_BACK_REQUEST:
		var event := InputEventAction.new()
		event.action = &"UI_Cancel"
		event.pressed = true
		_unhandled_input(event)


func open_net_menu() -> void:
	_net_menu.visible = true
	_sync_level1()


func close_net_menu() -> void:
	if _hosting_slot:
		return
	_slots_panel.hide()
	_net_menu.visible = false
	_close_panel()
	_sync_level1()
	_host_button.grab_focus()


func open_help() -> void:
	_help.visible = true


func close_help() -> void:
	_help.visible = false
	FazSfx.play(FazSfx.Cue.CLICK)


## The dim overlays are translucent on purpose, so the level-1 buttons have to be taken out
## of the tree's draw list or their captions land on top of the panel behind them. Derived
## each frame instead of paired with every open/close: the settings × closes from inside its
## own script, and a hand-carried flag there left the main menu with no buttons at all.
func _sync_level1() -> void:
	_menu_box.visible = not (_settings.visible or _help.visible or _net_menu.visible)


## The × on the lobby/friends panel only puts the panel away - the net menu stays open.
func _close_panel() -> void:
	_side_panel.visible = false
	_mode = PanelMode.NONE


func _click() -> void:
	FazSfx.play(FazSfx.Cue.CLICK)


func _hover() -> void:
	FazSfx.play(FazSfx.Cue.HOVER)


## Dust motes need a mesh; a small unshaded billboard is enough and costs no asset.
func _build_dust() -> void:
	var mesh := QuadMesh.new()
	mesh.size = Vector2(0.035, 0.035)
	var material := StandardMaterial3D.new()
	material.shading_mode = StandardMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = StandardMaterial3D.TRANSPARENCY_ALPHA
	material.billboard_mode = StandardMaterial3D.BILLBOARD_ENABLED
	material.disable_receive_shadows = true
	material.albedo_color = Color(1.0, 0.92, 0.8, 0.55)
	mesh.material = material
	# 4.7: CPUParticles3D takes the mesh directly; draw_pass_1 belongs to GPUParticles3D.
	_dust.mesh = mesh


func _animate_backdrop() -> void:
	var drift := create_tween().set_loops()
	drift.tween_property(_rig, "position:z", 4.4, 24.0).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	drift.tween_property(_rig, "position:z", 7.4, 24.0).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	var sway := create_tween().set_loops()
	sway.tween_property(_rig, "position:x", -0.7, 17.0).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	sway.tween_property(_rig, "position:x", 0.7, 17.0).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	var title := create_tween().set_loops()
	title.tween_property(_title, "modulate:a", 0.86, 0.11)
	title.tween_property(_title, "modulate:a", 1.0, 0.4)
	title.tween_interval(2.6)
	title.tween_property(_title, "modulate:a", 0.55, 0.06)
	title.tween_property(_title, "modulate:a", 1.0, 0.2)
	var scrim := create_tween().set_loops()
	scrim.tween_property(_background, "color", Color(0.06, 0.016, 0.02, 1.0), 5.0)
	scrim.tween_property(_background, "color", Color(0.02, 0.025, 0.045, 1.0), 5.0)
	scrim.tween_property(_backdrop, "modulate:a", 0.22, 4.0)
	scrim.tween_property(_backdrop, "modulate:a", 0.36, 4.0)


func _process(delta: float) -> void:
	_sync_level1()
	_flicker += delta
	# A dying ballast: steady hum with two irregular blackouts per cycle.
	var steady := 0.86 + 0.14 * sin(_flicker * 6.1) * sin(_flicker * 1.7)
	if fmod(_flicker, 4.3) < 0.07 or fmod(_flicker, 7.9) < 0.05:
		steady *= 0.12
	_lamp.light_energy = steady * 8.0
	_memo_at -= delta
	if _memo_at <= 0.0:
		_next_memo()


func _next_memo() -> void:
	_memo_at = 7.0
	_memo_index = (_memo_index + 1) % MEMOS.size()
	_ticker.text = MEMOS[_memo_index]
	_ticker.modulate.a = 0.0
	create_tween().tween_property(_ticker, "modulate:a", 1.0, 0.8)


func _play_menu_music() -> void:
	# Plug an eerie loop into MenuMusic.stream in the editor; the bed below covers the gap.
	if _music.stream != null:
		_music.volume_db = -10.0
		_music.play()


func _refresh_info() -> void:
	if OS.has_feature("android"):
		_info_label.text = "Тестовая версия Android"
		return
	var steam_state := "Steam: %s" % ("готов, " + SteamNet.local_nickname if SteamNet.steam_ready() else "не запущен")
	_info_label.text = steam_state + "   |   сборка " + SteamNet.BUILD_VERSION
	if SteamNet.steam_ready():
		# Friends can join by picking us in their list; the id is the fallback for direct join.
		_info_label.text += "   |   SteamID %d" % SteamNet.local_steam_id
	_find_button.disabled = _hosting_slot or not SteamNet.steam_ready()
	_join_game.disabled = not SteamNet.steam_ready()
	_back_button.disabled = _hosting_slot
	_public_lobby.disabled = _hosting_slot or not SteamNet.steam_ready()
	_host_steam_button.disabled = _hosting_slot
	_source_button.disabled = not SteamNet.steam_ready()
	_host_steam_button.text = "СОЗДАТЬ ИГРУ В STEAM" if SteamNet.steam_ready() else "СОЗДАТЬ ИГРУ ПО СЕТИ"


func _on_host_pressed() -> void:
	_deleting_slot = false
	_friend_to_invite = 0
	open_net_menu()
	_close_panel()
	_slots_panel.show()
	_refresh_slots()
	for button: Button in _slot_buttons:
		if not button.disabled:
			button.grab_focus()
			break


func _refresh_slots() -> void:
	_delete_button.text = "ОТМЕНА УДАЛЕНИЯ" if _deleting_slot else "УДАЛИТЬ СОХРАНЕНИЕ"
	var has_files: bool = false
	for index: int in _slot_buttons.size():
		var button: Button = _slot_buttons[index]
		var result: Dictionary = SaveManager.slot_summary(index + 1)
		var error: Error = int(result["error"]) as Error
		var exists: bool = SaveManager.has_slot_files(index + 1)
		has_files = has_files or exists
		button.disabled = _hosting_slot or (not exists if _deleting_slot else error not in [OK, ERR_FILE_NOT_FOUND])
		button.text = SaveManager.slot_caption(index + 1, result)
	_delete_button.disabled = _hosting_slot or (not has_files and not _deleting_slot)


func _toggle_delete_mode() -> void:
	_deleting_slot = not _deleting_slot
	_set_status("Выберите слот, который хотите удалить." if _deleting_slot else "")
	_refresh_slots()


func _delete_selected_slot() -> void:
	var slot: int = _delete_target
	_delete_target = 0
	if _hosting_slot or not _deleting_slot:
		return
	var error: Error = SaveManager.delete_slot(slot)
	_deleting_slot = false
	_refresh_slots()
	_set_status("Слот %d удалён." % slot if error == OK else "Не удалось удалить слот %d." % slot)


func _select_slot(slot: int) -> void:
	if _hosting_slot:
		return
	if _deleting_slot:
		if SaveManager.has_slot_files(slot):
			_delete_target = slot
			_delete_confirm.dialog_text = "Удалить сохранение в слоте %d и его резервную копию?\nЭто действие нельзя отменить." % slot
			_delete_confirm.popup_centered()
		return
	var error: Error = SaveManager.select_slot(slot)
	if error != OK:
		_set_status("Ошибка слота %d · %s" % [slot, error_string(error)])
		_refresh_slots()
		return
	_hosting_slot = true
	_refresh_slots()
	_refresh_info()
	var lobby_type: int = SteamNet.LOBBY_TYPE_PUBLIC if _public_lobby.button_pressed \
		else SteamNet.LOBBY_TYPE_FRIENDS_ONLY
	if OS.has_feature("android"):
		SteamNet.host_solo()
	else:
		SteamNet.host_game(SteamNet.MAX_PEERS, lobby_type)


func _on_host_failed(error: Error) -> void:
	if not _hosting_slot:
		return
	_hosting_slot = false
	SaveManager.cancel_selection()
	_set_status("Не удалось запустить сессию · " + error_string(error))
	_refresh_slots()
	_refresh_info()


func _on_find_pressed() -> void:
	open_net_menu()
	_show_panel(PanelMode.LOBBIES)
	SteamNet.find_lobbies()


## One button, two sources: the Steam lobby list and the friend roster.
func _on_source_pressed() -> void:
	if _mode == PanelMode.FRIENDS:
		_show_panel(PanelMode.LOBBIES)
		SteamNet.find_lobbies()
	else:
		_show_panel(PanelMode.FRIENDS)
		SteamNet.refresh_friends()


func _show_panel(mode: int) -> void:
	_slots_panel.hide()
	_mode = mode
	_side_panel.visible = true
	_list.clear()
	var friends := mode == PanelMode.FRIENDS
	_header.text = "ДРУЗЬЯ STEAM" if friends else "ЛОББИ"
	_source_button.text = "Лобби" if friends else "Друзья"
	_join_button.text = "Войти"
	_invite_button.visible = friends and SteamNet.steam_ready()


func _on_refresh_pressed() -> void:
	if _mode == PanelMode.FRIENDS:
		SteamNet.refresh_friends()
	else:
		SteamNet.find_lobbies()


func _on_join_pressed() -> void:
	var selected := _list.get_selected_items()
	if selected.is_empty():
		if _invited_lobby != 0:
			SteamNet.accept_invite()
		else:
			_set_status("Сначала выбери строку в списке.")
			FazSfx.play(FazSfx.Cue.DENIED)
		return
	var row := selected[0]
	match _mode:
		PanelMode.LOBBIES:
			SteamNet.join_lobby(int(SteamNet.lobbies[row].get("lobby_id", 0)))
		PanelMode.FRIENDS:
			var target := _selected_friend_id()
			if target != 0:
				SteamNet.join_by_steam_id(target)
		_:
			pass


func _on_list_activated(index: int) -> void:
	_list.select(index)
	_on_join_pressed()


## The row the player pointed at, if it is a friend who can actually be reached. Section
## headers and offline friends answer 0 with the reason on the status line.
func _selected_friend_id() -> int:
	var selected := _list.get_selected_items()
	if selected.is_empty():
		_set_status("Сначала выбери друга в списке.")
		FazSfx.play(FazSfx.Cue.DENIED)
		return 0
	var friend := _list.get_item_metadata(selected[0]) as Dictionary
	if friend.is_empty():
		_set_status("Это заголовок списка - выбери строку с именем друга.")
		FazSfx.play(FazSfx.Cue.DENIED)
		return 0
	if not bool(friend.get("online", false)):
		_set_status("%s сейчас оффлайн: пусть запустит игру, потом жми «Обновить»."
			% String(friend.get("name", "Друг")))
		FazSfx.play(FazSfx.Cue.DENIED)
		return 0
	return int(friend.get("steam_id", 0))


func _on_invite_pressed() -> void:
	if SteamNet.overlay_available() and SteamNet.lobby_id != 0:
		SteamNet.show_invite_dialog()
		_set_status("Выбери друга в списке Steam - он получит приглашение.")
		return
	var target := _selected_friend_id()
	if target == 0:
		return
	if SteamNet.lobby_id == 0:
		_on_host_pressed()
		_friend_to_invite = target
		_set_status("Выберите слот. После создания лобби отправим приглашение.")
	else:
		_set_status(SteamNet.invite_friend(target))


func _on_invite_received(lobby: int, inviter: int) -> void:
	if _hosting_slot:
		return
	_invited_lobby = lobby
	open_net_menu()
	_show_panel(PanelMode.LOBBIES)
	_header.text = "ПРИГЛАШЕНИЕ - ЖМИ «ВОЙТИ»"
	_set_status("%s приглашает тебя в лобби." % SteamNet.persona_of(inviter))


## Steam answers a lobby search whenever it feels like, so a late result must not wipe the
## roster of the tab the player switched to in the meantime - same for the friends side.
func _fill_lobbies(entries: Array) -> void:
	if _mode != PanelMode.LOBBIES:
		return
	_list.clear()
	for row in entries:
		_list.add_item("%s   %d игроков   %s" % [
			String(row.get("name", "Лобби")),
			int(row.get("players", 0)),
			String(row.get("phase", "В меню")),
		])
	if entries.is_empty():
		# Valve's lobby list stays empty under a dev AppID until the app is published, so the
		# browser is not the only way in: Friends and direct connect always work.
		_set_status("Лобби не найдено (на тестовом AppID это норма). Попробуй «Друзья» или адрес.")
	else:
		_set_status("Найдено лобби: %d. Выбери и жми «Войти»." % entries.size())


## Online friends on top, offline ones below, every row labelled. The section headers are
## unselectable rows, so a friend's data rides on the item metadata rather than a row index.
func _fill_friends(entries: Array) -> void:
	if _mode != PanelMode.FRIENDS:
		return
	_list.clear()
	var online := 0
	var group := -1
	for entry in entries:
		var is_online := bool(entry.get("online", false))
		if is_online:
			online += 1
		var next_group := 1 if is_online else 0
		if next_group != group:
			group = next_group
			_add_section("ОНЛАЙН" if is_online else "ОФФЛАЙН")
		var name := String(entry.get("name", "Друг"))
		var row := _list.add_item("%s   %s" % [name, "онлайн" if is_online else "оффлайн"])
		_list.set_item_metadata(row, entry)
		_list.set_item_disabled(row, not is_online)
	if entries.is_empty():
		_set_status("Список друзей пуст - Steam ещё не успел его отдать.")
	else:
		_set_status("В сети %d из %d. Оффлайн-друг не примет соединение, пока не запустит игру." % [
			online, entries.size()])


## A grey, unclickable row used only to split the list into two groups.
func _add_section(title: String) -> void:
	var row := _list.add_item(title)
	_list.set_item_selectable(row, false)
	_list.set_item_disabled(row, true)
	_list.set_item_custom_fg_color(row, Color(0.55, 0.32, 0.26, 1))


func _on_session_started(is_host: bool, _transport: StringName) -> void:
	if is_host and _friend_to_invite > 0 and SteamNet.lobby_id != 0:
		SteamNet.invite_friend(_friend_to_invite)
		_friend_to_invite = 0
	# Lobby metadata is only meaningful once the session exists.
	SteamNet.publish_lobby_metadata()
	get_tree().change_scene_to_file.call_deferred(GAME_SCENE)


## Network answers live inside the net panel: the main menu has no status line of its own.
func _set_status(text: String) -> void:
	_net_status.text = text


func _on_status(text: String) -> void:
	_set_status(text)
	print("[menu] ", text)
	_refresh_info()


func _on_exit_pressed() -> void:
	SteamNet.leave_session("Выход")
	get_tree().quit()
