extends Node

## SteamNetworkManager - one place where Steam meets Godot's high-level multiplayer API.
##
## Transport: the lobby host is a listen server. Godot's SceneMultiplayer keeps doing all
## the RPC / MultiplayerSpawner / MultiplayerSynchronizer work; only the packet pipe is
## swapped for Steam's P2P sockets by the GodotSteam MultiplayerPeer GDExtension
## (SteamMultiplayerPeer), which already keeps SteamID64-based peer ids.
##
## Without the addon, or with Steam closed, the manager falls back to ENet so the game
## stays testable offline:
##   --offline --auto-host                 host on :24564
##   --offline --auto-join=127.0.0.1       a second process joining it
##
## GodotSteam ships two generations of lobby signals with different arities, so handlers
## are bound by matching signal argument counts instead of guessing a version.

enum Transport { NONE, STEAM, ENET, SOLO }

## Mirrors Steamworks ELobbyType (isteammatchmaking.h: Private = 0, Public = 1,
## FriendsOnly = 2, Invisible = 3). If your GodotSteam build exposes different constants,
## this table is the only place to change.
const LOBBY_TYPE_PRIVATE := 0
const LOBBY_TYPE_PUBLIC := 1
const LOBBY_TYPE_FRIENDS_ONLY := 2
const LOBBY_TYPE_INVISIBLE := 3

const MAX_PEERS := 4
const LOBBY_CREATE_TIMEOUT_MS: int = 25000
const STEAM_RELATIONSHIP_FRIEND: int = 3
const ENET_PORT := 24564
const BUILD_VERSION: String = "campaign-tablet-03"
## Valve's sanctioned test app (SpaceWar). Hardcoded so the shipped test build does not
## depend on steam_appid.txt being reachable through the working directory. For a real
## release, set this back to 0 and launch through Steam with your own AppID.
const STEAM_APP_ID := 480
const STEAM_PEER_CLASSES := ["SteamMultiplayerPeer", "SteamNetworking"]

signal session_started(is_host: bool, transport: StringName)
signal session_ended(reason: String)
signal player_connected(peer_id: int, meta: Dictionary)
signal player_disconnected(peer_id: int)
signal roster_updated(roster: Dictionary)
signal lobby_created(lobby_id: int, error: int)
signal host_failed(error: Error)
signal lobby_joined(lobby_id: int, ok: bool, reason: String)
signal lobby_list_updated(lobbies: Array)
signal friends_updated(friends: Array)
signal invite_received(lobby_id: int, inviter_steam_id: int)
signal status(text: String)

var transport: int = Transport.NONE
var is_host := false
var lobby_id := 0
var local_peer_id := 1
var local_steam_id := 0
var local_nickname := "Guest"
var host_steam_id := 0
var host_nickname := "Host"
var lobbies: Array = []
var friends: Array = []
var peers: Dictionary = {}
## Latest human-readable state line; the menu reads this because Steam initialises before
## any UI is connected to the status signal.
var last_status := ""

var _steam: Object = null
var _steam_ok := false
var _hooks_installed := false
var _friend_flags := 1
var _friends_wait := 0.0
var _log: FileAccess
var _mp: SceneMultiplayer
var _enet_port := ENET_PORT
var _use_offline_only := false
var _auto_host := false
var _auto_join_ip := ""
var _target_address := ""
var _pending_join_lobby := 0
var _incoming_lobby: int = 0
var _pending_invite := 0
var _pending_lobby_type: int = LOBBY_TYPE_PUBLIC
var _creating_lobby: bool = false
var _lobby_request_deadline: int = 0
var _expected_steam_host: int = 0


func _ready() -> void:
	_open_session_log()
	# An uncapped headless listen server replicates ~2.4x the bandwidth of a 60 fps one;
	# the test rig and any future dedicated run stay at the design tick.
	if DisplayServer.get_name() == "headless":
		Engine.max_fps = 60
	# Ship logs need the net line even before any UI is listening.
	status.connect(_print_status)
	_parse_command_line()
	if not _use_offline_only and not OS.has_feature("android"):
		_init_steam()
	if _auto_host or _auto_join_ip != "":
		# Deferred so the menu scene has already connected to session_started by frame one.
		call_deferred("_start_from_command_line")
	if not _steam_ok:
		# Offline crew lists still need distinguishable names.
		local_nickname = "Гость %d" % randi_range(100, 999)


func _start_from_command_line() -> void:
	if _auto_host:
		host_game()
	elif _auto_join_ip != "":
		join_offline(_auto_join_ip, _enet_port)


func _print_status(text: String) -> void:
	last_status = text
	note("[net] " + text)


## Diagnostic log for shipped builds, where no console is attached. Both peers keep their
## own file, which is what makes a two-machine bug report readable.
## Named `note`, not `log`: GDScript resolves the unqualified call to the built-in
## math function log(float) and the script never compiles.
func note(text: String) -> void:
	print(text)
	if _log == null:
		return
	_log.store_line("%07d | %s" % [Time.get_ticks_msec(), text])
	_log.flush()


func _open_session_log() -> void:
	var stamp := Time.get_datetime_string_from_system(false, true).replace(":", "-")
	var err := FileAccess.open("user://session-%s.log" % stamp, FileAccess.WRITE)
	if err != null:
		_log = err
		_log.store_line("engine %s | build %s" % [Engine.get_version_info().string, BUILD_VERSION])
		_log.flush()


func _process(delta: float) -> void:
	if _steam_ok:
		_steam.call("run_callbacks")
		if _creating_lobby and _lobby_request_deadline > 0 and Time.get_ticks_msec() >= _lobby_request_deadline:
			_lobby_request_deadline = 0
			host_failed.emit(ERR_TIMEOUT)
		if _friends_wait > 0.0:
			# Every resolved profile pushes the refresh back, so a wall of user_info_changed
			# signals rebuilds the roster once instead of once per friend.
			_friends_wait -= delta
			if _friends_wait <= 0.0:
				refresh_friends()
	

## ---------------- public session API ----------------

func available() -> bool:
	return transport != Transport.NONE


func steam_ready() -> bool:
	return _steam_ok


func transport_name() -> StringName:
	match transport:
		Transport.STEAM: return &"steam"
		Transport.ENET: return &"enet"
		Transport.SOLO: return &"solo"
	return &"none"


func player_count() -> int:
	return peers.size()


func slots_left() -> int:
	return maxi(MAX_PEERS - player_count(), 0)


func is_full() -> bool:
	return slots_left() <= 0


func meta_of(peer_id: int) -> Dictionary:
	return peers.get(peer_id, {})


func host_game(max_peers: int = MAX_PEERS, lobby_type: int = LOBBY_TYPE_PUBLIC) -> void:
	if available() or _creating_lobby or _pending_join_lobby != 0:
		host_failed.emit(ERR_BUSY)
		return
	_pending_lobby_type = lobby_type
	if _steam_ok:
		# The lobby id only arrives in lobby_created; the peer opens from that callback.
		_creating_lobby = true
		_lobby_request_deadline = Time.get_ticks_msec() + LOBBY_CREATE_TIMEOUT_MS
		status.emit("Создаю лобби Steam...")
		_steam.call("createLobby", lobby_type, clampi(max_peers, 1, MAX_PEERS))
	else:
		_open_host(0, Transport.ENET)


func host_solo() -> void:
	if available():
		host_failed.emit(ERR_BUSY)
		return
	_open_host(0, Transport.SOLO)


func find_lobbies() -> void:
	lobbies = []
	if not _steam_ok:
		status.emit("Steam не запущен - поиск лобби недоступен.")
		lobby_list_updated.emit(lobbies)
		return
	_steam.call("addRequestLobbyListStringFilter", "build", BUILD_VERSION, 0)
	_steam.call("addRequestLobbyListResultCountFilter", 16)
	_steam.call("requestLobbyList")
	status.emit("Ищу открытые игры...")


func join_lobby(join_id: int) -> void:
	if join_id == 0 or _creating_lobby or _pending_join_lobby != 0:
		return
	if available():
		# The invite is dropped here otherwise, and "nothing happened" is what the player
		# reports - so say who is in the way and what to press.
		status.emit("Ты уже в своей игре (хост). Сначала «ПОКИНУТЬ» - потом «Войти» по приглашению.")
		return
	if not _steam_ok:
		status.emit("Steam не запущен. Для теста без Steam используй --offline (ENet).")
		return
	_pending_join_lobby = join_id
	# joinLobby's return shape differs across GodotSteam generations (int here, and it is
	# not always an int), so only a real error code is treated as a refusal.
	var result: Variant = _steam.call("joinLobby", join_id)
	if typeof(result) == TYPE_INT and int(result) != OK:
		_pending_join_lobby = 0
		status.emit("Steam не принял запрос на вход в лобби %d: %s" % [join_id, error_string(int(result))])
	else:
		status.emit("Захожу в лобби %d..." % join_id)


## Joining straight from a friend: no lobby list involved.
func join_by_steam_id(host_steam_id: int) -> void:
	if host_steam_id == 0 or not _steam_ok or _creating_lobby or _pending_join_lobby != 0:
		return
	if available():
		status.emit("Ты уже в своей игре (хост). Сначала «ПОКИНУТЬ», потом зови друга сам.")
		return
	_open_client(0, Transport.STEAM, host_steam_id)


func accept_invite() -> void:
	if _incoming_lobby != 0:
		join_lobby(_incoming_lobby)


func show_invite_dialog() -> void:
	if _steam_ok and lobby_id != 0:
		_steam.call("activateGameOverlayInviteDialog", lobby_id)


## True only when the game was started by Steam: the overlay picker is the friendlier path,
## but double-clicking the exe leaves it off and invites would silently go nowhere.
func overlay_available() -> bool:
	return _steam_ok and bool(_steam.call("isOverlayEnabled"))


## The invite that actually works outside the Steam client: the overlay picker needs
## isOverlayEnabled(), and that is false for anything started by double-click or from the
## editor. inviteUserToLobby() goes straight to the friend's running game as join_requested.
## Returns a line for the UI: sending is fire-and-forget, so nobody should claim delivery.
func invite_friend(steam_id: int) -> String:
	if not _steam_ok:
		return "Steam не запущен - передай другу адрес хоста."
	if steam_id == 0:
		return "Выбери в списке друга со статусом «онлайн»."
	if lobby_id == 0:
		_pending_invite = steam_id
		host_game(MAX_PEERS, LOBBY_TYPE_FRIENDS_ONLY)
		return "Сначала открываю лобби, потом шлю приглашение..."
	_steam.call("inviteUserToLobby", lobby_id, steam_id)
	refresh_friends()
	return "Приглашение в лобби %d отправлено %s. У друга оно появится в игре." % [
		lobby_id, persona_of(steam_id)]


## Display name for a SteamID, when Steam is up and the id is a friend of ours.
func persona_of(steam_id: int) -> String:
	if _steam_ok and steam_id != 0:
		var name := String(_steam.call("getFriendPersonaName", steam_id))
		if not name.is_empty():
			return name
	return "Игрок %05d" % (steam_id % 100000)


## The roster Steam has cached for us: online friends first, then the offline ones.
## This build has no getFriendPresence - getFriendPersonaState is the one that answers,
## and 0 means offline. Friends Steam never named come back as an empty string, so they get
## a placeholder plus a requestUserInformation(); the real name shows up on the next refresh.
func refresh_friends() -> void:
	friends = []
	if _steam_ok:
		var count := int(_steam.call("getFriendCount"))
		for i in count:
			var steam_id := int(_steam.call("getFriendByIndex", i, _friend_flags))
			if steam_id == 0:
				continue
			var display := String(_steam.call("getFriendPersonaName", steam_id))
			if display.is_empty():
				_steam.call("requestUserInformation", steam_id, false)
				display = "Игрок %05d" % (steam_id % 100000)
			friends.append({
				"steam_id": steam_id,
				"name": display,
				"online": int(_steam.call("getFriendPersonaState", steam_id)) != 0,
			})
		friends.sort_custom(_by_presence_then_name)
	friends_updated.emit(friends)


func _by_presence_then_name(a: Dictionary, b: Dictionary) -> bool:
	var a_online := bool(a["online"])
	if a_online != bool(b["online"]):
		return a_online
	return String(a["name"]).to_lower() < String(b["name"]).to_lower()


func leave_session(reason: String = "Выход") -> void:
	var was_active := available()
	if _steam_ok and lobby_id != 0:
		_steam.call("leaveLobby", lobby_id)
	lobby_id = 0
	_pending_join_lobby = 0
	_expected_steam_host = 0
	_pending_invite = 0
	peers.clear()
	lobbies.clear()
	transport = Transport.NONE
	is_host = false
	local_peer_id = 1
	if was_active and _mp != null:
		# A null peer is not allowed: swap in OfflineMultiplayerPeer to tear the session down.
		_mp.multiplayer_peer = OfflineMultiplayerPeer.new()
		session_ended.emit(reason)
	status.emit(reason)


## Offline hosts are how the two-process test rig and LAN play run.
func join_offline(ip: String = "127.0.0.1", port: int = ENET_PORT) -> void:
	if available():
		status.emit("Сессия уже идёт. «ПОКИНУТЬ» - и тогда подключусь к %s." % ip)
		return
	_enet_port = port
	_target_address = "%s:%d" % [ip, port]
	_open_client(0, Transport.ENET, 0, ip)


## ---------------- internals: peer + auth ----------------

func _open_host(join_lobby_id: int, which_transport: int) -> void:
	var peer: MultiplayerPeer = _make_peer(true, join_lobby_id, 0, which_transport)
	if peer == null:
		if which_transport == Transport.STEAM:
			_steam.call("leaveLobby", join_lobby_id)
		host_failed.emit(ERR_CANT_CREATE)
		return
	_install_peer(peer)
	is_host = true
	transport = which_transport
	lobby_id = join_lobby_id
	local_peer_id = _mp.get_unique_id()
	peers[local_peer_id] = _local_meta()
	session_started.emit(true, transport_name())
	status.emit("Хост - %s" % _transport_label())
	player_connected.emit(local_peer_id, peers[local_peer_id])
	if which_transport == Transport.STEAM:
		publish_lobby_metadata()
		_broadcast_roster()


func _open_client(join_lobby_id: int, which_transport: int, host_steam_id: int, ip: String = "127.0.0.1") -> void:
	var peer: MultiplayerPeer = _make_peer(false, join_lobby_id, host_steam_id, which_transport, ip)
	if peer == null:
		if join_lobby_id != 0:
			_steam.call("leaveLobby", join_lobby_id)
		return
	_expected_steam_host = host_steam_id
	_install_peer(peer)
	is_host = false
	transport = which_transport
	lobby_id = join_lobby_id
	if which_transport == Transport.ENET and ip != "":
		_target_address = "%s:%d" % [ip, _enet_port]
	elif which_transport == Transport.STEAM:
		_target_address = ("лобби %d" % join_lobby_id) if join_lobby_id != 0 else ("хост %d" % host_steam_id)
	session_started.emit(false, transport_name())
	status.emit("Подключаюсь к %s..." % _transport_label())


func _make_peer(host: bool, join_lobby_id: int, host_steam_id: int, which_transport: int, ip: String = "127.0.0.1") -> MultiplayerPeer:
	if which_transport == Transport.SOLO:
		return OfflineMultiplayerPeer.new()
	if which_transport == Transport.ENET:
		var enet := ENetMultiplayerPeer.new()
		var err := enet.create_server(_enet_port, MAX_PEERS - 1) if host else enet.create_client(ip, _enet_port)
		if err != OK:
			status.emit("Не удалось поднять ENet: " + error_string(err))
			return null
		return enet
	if which_transport == Transport.STEAM:
		return _make_steam_peer(host, join_lobby_id, host_steam_id)
	return null


## The Steam socket is a star topology. SceneMultiplayer relays client-owned
## avatar replication through the lobby owner.
func _make_steam_peer(host: bool, join_lobby_id: int, host_steam_id: int) -> MultiplayerPeer:
	var peer_class := _steam_peer_class()
	if peer_class == &"":
		status.emit("Лобби Steam готово, но расширение MultiplayerPeer не загружено."
			+ " Установи GodotSteam MultiplayerPeer GDExtension или запускай с --offline.")
		return null
	var peer: MultiplayerPeer = ClassDB.instantiate(peer_class)
	var err := ERR_UNAVAILABLE
	if host:
		# GodotSteam's documented host flow: open the listen socket first, then bind the lobby.
		for attempt in [[&"create_host", 0], [&"host_with_lobby", join_lobby_id]]:
			if peer.has_method(attempt[0]):
				err = int(peer.call(attempt[0], attempt[1]))
				break
	else:
		if peer.has_method(&"create_client"):
			err = int(peer.call(&"create_client", host_steam_id))
		elif join_lobby_id != 0 and peer.has_method(&"connect_to_lobby"):
			err = int(peer.call(&"connect_to_lobby", join_lobby_id))
	if err != OK:
		status.emit("Steam-пит не поднялся: " + error_string(err))
		return null
	# Verified against GodotSteam 4.23.2: these are real properties on SteamMultiplayerPeer.
	peer.set(&"server_relay", true)
	return peer


## SteamIDs sitting in the lobby besides us. This build has no lobby_member_entered signal,
## so the roster is polled: a friend who accepts an invite after the host raised the peer
## would otherwise never become a peer at all.
func lobby_member_ids(lobby: int) -> Array[int]:
	var ids: Array[int] = []
	if not _steam_ok or lobby == 0:
		return ids
	for i in int(_steam.call("getNumLobbyMembers", lobby)):
		var member_steam_id := int(_steam.call("getLobbyMemberByIndex", lobby, i))
		if member_steam_id != 0 and member_steam_id != local_steam_id:
			ids.append(member_steam_id)
	return ids


func _steam_peer_class() -> StringName:
	for candidate in STEAM_PEER_CLASSES:
		if ClassDB.class_exists(candidate):
			return StringName(candidate)
	return &""


func _install_peer(peer: MultiplayerPeer) -> void:
	_mp = multiplayer as SceneMultiplayer
	if _mp == null:
		push_error("Root multiplayer is not a SceneMultiplayer; RPC, spawners and synchronizers will not work.")
		_mp = SceneMultiplayer.new()
		get_tree().set_multiplayer(_mp, get_tree().root.get_path())
	if not _hooks_installed:
		# The root SceneMultiplayer outlives a session, so hooking it twice would double every event.
		_hooks_installed = true
		# Auth carries identity: names travel here, and the host validates the claimed SteamID.
		_mp.auth_callback = _on_auth_received
		_mp.peer_authenticating.connect(_on_peer_authenticating)
		_mp.peer_authentication_failed.connect(_on_peer_authentication_failed)
		_mp.peer_connected.connect(_on_mp_peer_connected)
		_mp.peer_disconnected.connect(_on_mp_peer_disconnected)
		_mp.connected_to_server.connect(_on_mp_connected_to_server)
		_mp.connection_failed.connect(_on_mp_connection_failed)
		_mp.server_disconnected.connect(_on_mp_server_disconnected)
	_mp.multiplayer_peer = peer


func _auth_payload() -> Dictionary:
	# SteamIDs still come from the transport. The build id protects the room spawn protocol.
	return {"n": local_nickname, "build": BUILD_VERSION}


func _on_peer_authenticating(peer_id: int) -> void:
	# Peer 1 is reserved. Steam identity comes from the connection, never from auth payloads.
	if is_host:
		if peer_id <= 1 or (transport == Transport.STEAM and not _valid_steam_member(peer_id)):
			_mp.multiplayer_peer.disconnect_peer(peer_id)
			return
		_mp.send_auth(peer_id, var_to_bytes(_auth_payload()))
	elif peer_id != 1 or (transport == Transport.STEAM and _steam_id_for_peer(1) != _expected_steam_host):
		_mp.multiplayer_peer.disconnect_peer(peer_id)


func _on_auth_received(peer_id: int, payload: Variant) -> void:
	if (is_host and (peer_id <= 1 or (transport == Transport.STEAM and not _valid_steam_member(peer_id)))) \
		or (not is_host and (peer_id != 1 or (transport == Transport.STEAM and _steam_id_for_peer(1) != _expected_steam_host))):
		_mp.multiplayer_peer.disconnect_peer(peer_id)
		return
	var decoded: Variant = bytes_to_var(payload) if typeof(payload) == TYPE_PACKED_BYTE_ARRAY else payload
	var meta: Dictionary = decoded if typeof(decoded) == TYPE_DICTIONARY else {}
	if String(meta.get("build", "")) != BUILD_VERSION:
		status.emit("Версии игры различаются. Запустите одинаковую тестовую сборку.")
		_mp.multiplayer_peer.disconnect_peer(peer_id)
		return
	var display := String(meta.get("n", "Игрок %d" % peer_id))
	if peer_id == 1:
		host_nickname = display
		host_steam_id = _steam_id_for_peer(1)
		peers[1] = {"name": host_nickname, "steam_id": host_steam_id}
	else:
		var account: int = _steam_id_for_peer(peer_id)
		peers[peer_id] = {"name": persona_of(account) if account > 0 else display, "steam_id": account}
	if not is_host and peer_id == 1:
		# Handshake: the client answers the host's hello with its own identity.
		_mp.send_auth(1, var_to_bytes(_auth_payload()))
	_mp.complete_auth(peer_id)


func _on_peer_authentication_failed(peer_id: int) -> void:
	if not multiplayer.get_peers().has(peer_id):
		peers.erase(peer_id)
	status.emit("Пир %d не прошёл проверку соединения." % peer_id)


func _valid_steam_member(peer_id: int) -> bool:
	var account: int = _steam_id_for_peer(peer_id)
	if account <= 0 or account == local_steam_id:
		return false
	if peers.has(peer_id):
		return int(meta_of(peer_id).get("steam_id", 0)) == account
	if is_full():
		return false
	for other: int in peers:
		if int(meta_of(other).get("steam_id", 0)) == account:
			return false
	if lobby_id == 0 or lobby_member_ids(lobby_id).has(account):
		return true
	# Direct joins from the friends view still work under the lobby's access policy.
	return _pending_lobby_type == LOBBY_TYPE_PUBLIC or (_pending_lobby_type == LOBBY_TYPE_FRIENDS_ONLY \
		and int(_steam.call("getFriendRelationship", account)) == STEAM_RELATIONSHIP_FRIEND)


func _steam_id_for_peer(peer_id: int) -> int:
	if not _steam_ok or _mp == null or _mp.multiplayer_peer == null:
		return 0
	var peer: Object = _mp.multiplayer_peer
	if not peer.has_method(&"get_steam_id_for_peer_id"):
		return 0
	return int(peer.call("get_steam_id_for_peer_id", peer_id))


func _on_mp_peer_connected(peer_id: int) -> void:
	# Announce only after authentication finished: RPCs sent during the handshake are
	# dropped, which is exactly how a joiner can end up with no wallet.
	var meta: Dictionary = peers.get(peer_id, {"name": "Игрок %d" % peer_id, "steam_id": 0})
	# The transport resolves the SteamID once the connection is real, so refresh it here.
	if transport == Transport.STEAM and (is_host or peer_id == 1) and int(meta.get("steam_id", 0)) == 0:
		meta["steam_id"] = _steam_id_for_peer(peer_id)
	peers[peer_id] = meta
	note("[net] peer %d joined as %s (steamid %d)" % [peer_id, meta["name"], meta["steam_id"]])
	player_connected.emit(peer_id, meta)
	if is_host:
		_broadcast_roster()


func _on_mp_peer_disconnected(peer_id: int) -> void:
	note("[net] peer %d left" % peer_id)
	peers.erase(peer_id)
	player_disconnected.emit(peer_id)
	if is_host:
		_broadcast_roster.call_deferred()
		publish_lobby_metadata()


func _on_mp_connected_to_server() -> void:
	local_peer_id = _mp.get_unique_id()
	peers[local_peer_id] = _local_meta()
	player_connected.emit(local_peer_id, peers[local_peer_id])
	status.emit("Подключился к хосту, мой id %d." % local_peer_id)


func _on_mp_connection_failed() -> void:
	# Name the target and the actual cause per transport: ENet dies on address/firewall,
	# Steam P2P dies on the host's Steam client or relay, not on the user's router.
	var where := _target_address if _target_address != "" else "лобби %d" % lobby_id
	if transport == Transport.ENET:
		leave_session(("Соединение с %s не удалось - хост не отвечает. Проверь адрес и что "
			+ "брандмауэр на его машине пропускает UDP %d.") % [where, _enet_port])
	else:
		leave_session("Соединение с %s не удалось - хост не отвечает в Steam. Проверь, что у "
			+ "хоста запущен Steam и игра, и попробуй войти заново." % where)


func _on_mp_server_disconnected() -> void:
	leave_session("Хост закрыл сессию")


## Roster is broadcast so a client also learns about players who joined before it did.
func _broadcast_roster() -> void:
	if is_host:
		_rpc_roster.rpc(peers)


@rpc("authority", "call_remote", "reliable")
func _rpc_roster(roster: Dictionary) -> void:
	if is_host or multiplayer.get_remote_sender_id() != 1:
		return
	for existing: int in peers.keys():
		if not roster.has(existing):
			peers.erase(existing)
	for peer_id: int in roster:
		var already_known: bool = peers.has(peer_id)
		peers[peer_id] = roster[peer_id]
		if not already_known:
			player_connected.emit(peer_id, roster[peer_id])
	roster_updated.emit(roster)


## Lobby metadata is what the browser rows show, and "build" is the join filter.
func publish_lobby_metadata() -> void:
	if not _steam_ok or lobby_id == 0 or not is_host:
		return
	if not _steam.has_method(&"setLobbyData"):
		return
	_steam.call("setLobbyType", lobby_id, _pending_lobby_type)
	_steam.call("setLobbyData", lobby_id, "build", BUILD_VERSION)
	_steam.call("setLobbyData", lobby_id, "name", "%s's pizzeria" % local_nickname)
	_steam.call("setLobbyData", lobby_id, "players", str(player_count()))
	_steam.call("setLobbyData", lobby_id, "phase", String(GameState.PHASE_NAMES.get(GameState.phase, "Menu")))
	_steam.call("setLobbyData", lobby_id, "seed", str(GameState.map_seed))


func _local_meta() -> Dictionary:
	return {"name": local_nickname, "steam_id": local_steam_id}


func _transport_label() -> String:
	match transport:
		Transport.STEAM:
			return "лобби Steam %d" % lobby_id if lobby_id != 0 else "Steam P2P"
		Transport.ENET:
			return "ENet :%d" % _enet_port
		Transport.SOLO:
			return "одиночная игра"
	return "нет соединения"


## ---------------- internals: Steam init + lobby callbacks ----------------

func _init_steam() -> void:
	if not Engine.has_singleton("Steam"):
		status.emit("GodotSteam не загружен - доступен только офлайн/ENet.")
		return
	_steam = Engine.get_singleton("Steam")
	if not _steam.has_method(&"steamInit"):
		status.emit("У GodotSteam нет метода steamInit - доступен только офлайн/ENet.")
		_steam = null
		return
	# steamInit(app_id, embed_callbacks) -> bool. 0 means "take the AppID from
	# steam_appid.txt or from the Steam launch itself"; true means we pump run_callbacks().
	var app_id: int = int(ProjectSettings.get_setting("application/config/steam_app_id", STEAM_APP_ID))
	_steam_ok = bool(_steam.call("steamInit", app_id, true))
	if not _steam_ok:
		status.emit("Steam не инициализирован - доступен только офлайн/ENet.")
		return
	local_steam_id = int(_steam.call("getSteamID"))
	local_nickname = String(_steam.call("getPersonaName"))
	if local_nickname.is_empty():
		local_nickname = "Player %d" % (local_steam_id % 10000)
	_friend_flags = int(_default_arg_of("getFriendCount", 1))
	_bind_steam_signals()
	refresh_friends()
	status.emit("Steam готов: %s (%d)" % [local_nickname, local_steam_id])


## GodotSteam's friend flags have changed between releases, so the value used to count
## friends is reused for indexing them instead of hardcoding an enum.
func _default_arg_of(method_name: String, fallback: Variant) -> Variant:
	for entry in _steam.get_method_list():
		if String(entry["name"]) != method_name:
			continue
		var defaults: Array = entry.get("default_args", [])
		if defaults.size() == 1:
			return defaults[0]
	return fallback


## Arity-checked binding: this build has lobby_created(connect, lobby_id) with connect == 1
## on success; the check keeps a different GodotSteam build from silently misfiring.
func _bind_steam_signals() -> void:
	_bind(&"lobby_created", _on_lobby_created, 2)
	_bind(&"lobby_joined", _on_lobby_joined, 4)
	_bind(&"lobby_match_list", _on_lobby_match_list, 1)
	_bind(&"join_requested", _on_join_requested, 2)
	_bind(&"lobby_invite", _on_lobby_invite, 3)
	_bind(&"lobby_leave", _on_lobby_leave, 2)
	_bind(&"lobby_kicked", _on_lobby_kicked, 3)
	# This build has no user_info_changed signal, so a friend's presence change is the only
	# live nudge we get; friends_refresh_complete covers the roster arriving late.
	_bind(&"persona_state_change", _on_presence_changed, 2)
	_bind(&"friends_refresh_complete", _on_presence_changed, 0)


## Steam flipped a friend online/offline (or handed us the roster): re-read it, debounced in
## _process so a burst of changes rebuilds the list once.
func _on_presence_changed(_a: Variant = null, _b: Variant = null) -> void:
	_friends_wait = 0.6


func _bind(signal_name: StringName, handler: Callable, argc: int) -> void:
	if not _steam.has_signal(signal_name):
		return
	if _signal_arg_count(signal_name) != argc:
		push_warning("GodotSteam signal %s does not take %d args - handler skipped." % [signal_name, argc])
		return
	_steam.connect(signal_name, handler)


func _signal_arg_count(signal_name: StringName) -> int:
	for entry in _steam.get_signal_list():
		if StringName(entry["name"]) == signal_name:
			var args: Array = entry["args"]
			return args.size()
	return -1


func _on_lobby_created(connect: int, lobby: int) -> void:
	# GodotSteam reports success as connect == 1, not as an error code.
	if not _creating_lobby:
		return
	_creating_lobby = false
	if _lobby_request_deadline == 0:
		# A late callback belongs to the abandoned attempt. Steam exposes no request ID.
		if connect == 1 and lobby != 0:
			_steam.call("leaveLobby", lobby)
		return
	_lobby_request_deadline = 0
	var err: Error = OK if connect == 1 and lobby != 0 else ERR_CANT_CONNECT
	lobby_created.emit(lobby, err)
	if err != OK:
		status.emit("Лобби не создан (Steam ответил %d)." % connect)
		host_failed.emit(err)
		return
	_open_host(lobby, Transport.STEAM)
	if _pending_invite != 0:
		# The invite was asked for before the lobby existed - it can only ride on it now.
		var invited := _pending_invite
		_pending_invite = 0
		status.emit(invite_friend(invited))


func _on_lobby_joined(lobby: int, _permissions: int, _locked: int, response: int) -> void:
	# Creating a lobby also fires lobby_joined for its owner: we are already the host then.
	if available() or lobby != _pending_join_lobby:
		return
	_pending_join_lobby = 0
	# EChatRoomEnterResponse: 1 is the only success. 2 used to be read as "already joined",
	# which turned a missing lobby into a silent hang - the friend dialed a lobby Steam
	# never gave him and nothing ever reported it.
	if response == 1:
		lobby_joined.emit(lobby, true, "Joined")
		_open_client(lobby, Transport.STEAM, int(_steam.call("getLobbyOwner", lobby)))
		return
	lobby_joined.emit(lobby, false, _lobby_enter_reason(response))
	status.emit("Не зашёл в лобби %d: %s" % [lobby, _lobby_enter_reason(response)])


func _lobby_enter_reason(response: int) -> String:
	match response:
		2:
			return "такого лобби нет (хост ещё не создал его или лобби уже закрылось)"
		3:
			return "вход запрещён: лобби приватное, жди приглашение от хоста"
		4:
			return "лобби полное (4 места)"
		5:
			return "Steam не смог соединиться с лобби - проверь, что Steam в сети"
		6:
			return "тебя забанили в этом лобби"
		7:
			return "доступ к лобби ограничен Steam"
		9999:
			return "аккаунт забанен"
		_:
			return "Steam ответил кодом %d" % response


func _on_lobby_match_list(these_lobbies: Array) -> void:
	lobbies = _normalize_lobbies(these_lobbies)
	# The menu turns this into its own line; a second status here would land on whatever tab
	# the player switched to while Steam was thinking.
	lobby_list_updated.emit(lobbies)


func _normalize_lobbies(raw: Array) -> Array:
	var out: Array = []
	for entry in raw:
		if typeof(entry) != TYPE_DICTIONARY:
			continue
		if String(entry.get("build", BUILD_VERSION)) != BUILD_VERSION:
			continue
		out.append({
			"lobby_id": int(entry.get("lobby_id", entry.get("SteamID", 0))),
			"name": String(entry.get("name", "Lobby")),
			"players": int(entry.get("players", 0)),
			"phase": String(entry.get("phase", "Menu")),
		})
	return out


func _on_join_requested(lobby: int, inviter_steam_id: int) -> void:
	_incoming_lobby = lobby
	invite_received.emit(lobby, inviter_steam_id)
	status.emit("%s приглашает тебя в лобби." % persona_of(inviter_steam_id))


func _on_lobby_invite(inviter: int, lobby: int, _game: int) -> void:
	_on_join_requested(lobby, inviter)


func _on_lobby_kicked(lobby: int, _admin_id: int, _due_to_disconnect: bool) -> void:
	if lobby == lobby_id and transport == Transport.STEAM:
		leave_session("Хост удалил тебя из лобби")


func _on_lobby_leave(lobby: int, steam_id: int) -> void:
	if lobby != lobby_id or transport != Transport.STEAM:
		return
	if steam_id == local_steam_id or (not is_host and steam_id == _expected_steam_host):
		leave_session("Удалён из лобби")


func _parse_command_line() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg == "--offline":
			_use_offline_only = true
		elif arg == "--auto-host":
			_auto_host = true
		elif arg.begins_with("--auto-join="):
			_auto_join_ip = arg.get_slice("=", 1)
		elif arg.begins_with("--port="):
			_enet_port = int(arg.get_slice("=", 1))
