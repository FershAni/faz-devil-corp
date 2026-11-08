extends Node

## GameState - replicated game data. Server-authoritative by construction:
## every mutator below asserts _is_server() first, applies locally, then broadcasts
## with _rpc_publish_state / targeted _rpc_set_player_wallet. Clients call the
## request_* helpers, which only reach the server.

signal state_changed(key: StringName)
signal player_wallet_updated(peer_id: int, balance: int)
signal player_left(peer_id: int)
signal noise_reported(level: float, kind: int, peer_id: int)
signal player_life_changed(peer_id: int, dead: bool)
signal shop_purchase_finished(item_id: String, error: String)

enum Phase {
	MENU,
	HUB_DAY,
	TRANSPORT,
	NIGHT_SCAVENGE,
	HUB_INVASION,
	SETTLEMENT,
	GAME_OVER,
}

const PHASE_NAMES := {
	Phase.MENU: "В меню",
	Phase.HUB_DAY: "Дневная смена",
	Phase.TRANSPORT: "Транспорт",
	Phase.NIGHT_SCAVENGE: "Ночная смена",
	Phase.HUB_INVASION: "Вторжение",
	Phase.SETTLEMENT: "Расчёт",
	Phase.GAME_OVER: "Конец",
}

## Quota curve: what the crew owes FazDevilCorp at the end of each 3-day cycle.
const QUOTA_BY_CYCLE: Array[int] = [800, 1400, 2200, 3200, 4600, 6400, 9000]
const DAYS_PER_CYCLE := 3
## The pizzeria hands every worker an advance before the sortie; unspent money is balance.
const STARTING_BALANCE := 300
const STARTING_BUSINESS_BALANCE: int = 100
## Equipment sold at the pizzeria.
const INVENTORY_SIZE := 3
const SHOP_ITEMS := {
	"battery": {"name": "Запасная батарея", "price": 120},
	"medkit": {"name": "Аптечка", "price": 150},
	"pills": {"name": "Успокоительное", "price": 90},
	"lamp": {"name": "Мощный фонарь", "price": 200},
}
const STATE_BROADCAST_INTERVAL := 2.0
const ALERT_DECAY_PER_SECOND := 0.02
const NOISE_ALERT_GAIN := 0.0009
const COZY_BUFF_TABLE := {
	"stamina_multiplier": 1.0,
	"battery_drain_multiplier": 1.0,
	"noise_multiplier": 1.0,
}

var phase: int = Phase.MENU
var day_index: int = 1
var quota_index: int = 0
## Local read model. The authority keeps one charge value per authenticated player.
var tablet_battery: float = 100.0
var decor_positions: Dictionary[int, Vector3] = {}
var quota_cents: int = QUOTA_BY_CYCLE[0]
var debt_cents: int = 0
var earnings_cents: int = 0
var map_seed: int = 0
var alert_level: float = 0.0
var loudest_noise: float = 0.0
var cozy_level: int = 0
## The business wallet is shared by the crew. Personal equipment still uses player wallets.
var business_balance: int = STARTING_BUSINESS_BALANCE
var daytime_open: bool = false
var daytime_prop_ids: PackedInt32Array = PackedInt32Array()
var daytime_damaged_ids: PackedInt32Array = PackedInt32Array()
var daytime_report: Dictionary = {}
var night_cozy_level: int = 0
var night_damaged_electronics: int = 0
var invasion_active: bool = false
## One bit per office shutter. Included in the state snapshot for late joins.
var office_shutters := 0
var players: Dictionary = {}
## Indices of the scrap points already picked up this night, so every peer hides the same
## markers even though the map itself is generated locally from the seed.
var taken_scrap: Array[int] = []

var _is_server := true
var _publish_timer := 0.0


func _ready() -> void:
	reset()
	SteamNet.session_started.connect(_on_session_started)
	SteamNet.session_ended.connect(_on_session_ended)
	SteamNet.player_connected.connect(_on_player_connected)
	SteamNet.player_disconnected.connect(_on_player_disconnected)


func _physics_process(delta: float) -> void:
	if not _is_server or not SteamNet.available():
		return
	loudest_noise = maxf(loudest_noise - 60.0 * delta, 0.0)
	if is_play_phase():
		alert_level = maxf(alert_level - ALERT_DECAY_PER_SECOND * delta, 0.0)
	_publish_timer -= delta
	if _publish_timer <= 0.0:
		_publish_timer = STATE_BROADCAST_INTERVAL
		_publish_state()


func _rpc_is_server_caller() -> bool:
	return _is_server or multiplayer.get_remote_sender_id() == 1


func _on_session_started(is_host: bool, _transport: StringName) -> void:
	_is_server = is_host
	reset()
	# No seed yet: the session opens in the pizzeria, and the night map is rolled when the
	# host actually starts the sortie.


func _on_session_ended(_reason: String) -> void:
	_is_server = true
	reset()


func _on_player_connected(peer_id: int, meta: Dictionary) -> void:
	if not _is_server:
		return
	var wallet := {
		"peer_id": peer_id,
		"name": String(meta.get("name", "Peer %d" % peer_id)),
		"steam_id": int(meta.get("steam_id", 0)),
		"balance": STARTING_BALANCE,
		"scrap_value": 0,
		"ready": false,
		"cozy_items": [],
		"dead": false,
		"spawn_pos": Vector3.ZERO,
		"lost_scrap": 0,
		"return_home": 0,
		"items": [],
	}
	var restored: Dictionary = SaveManager.restored_wallet(peer_id, int(wallet["steam_id"]))
	if not restored.is_empty():
		wallet["balance"] = restored["balance"]
		wallet["items"] = restored["items"]
	players[peer_id] = wallet
	_broadcast_wallets()
	# The seed travels in the state payload: without this a fresh peer would sit in a round
	# with no map until the next timed broadcast.
	_publish_state()
	state_changed.emit(&"players")


func _on_player_disconnected(peer_id: int) -> void:
	if not _is_server:
		return
	SaveManager.remember_wallet(peer_id, wallet(peer_id))
	players.erase(peer_id)
	_publish_departure.call_deferred(peer_id)
	player_left.emit(peer_id)
	state_changed.emit(&"players")


func _publish_departure(peer_id: int) -> void:
	if SteamNet.is_host and not players.has(peer_id):
		_rpc_drop_player.rpc(peer_id)


func reset() -> void:
	phase = Phase.MENU
	day_index = 1
	quota_index = 0
	tablet_battery = 100.0
	decor_positions.clear()
	loudest_noise = 0.0
	quota_cents = QUOTA_BY_CYCLE[0]
	debt_cents = 0
	earnings_cents = 0
	map_seed = 0
	alert_level = 0.0
	cozy_level = 0
	business_balance = STARTING_BUSINESS_BALANCE
	daytime_open = false
	daytime_prop_ids.clear()
	daytime_damaged_ids.clear()
	daytime_report.clear()
	night_cozy_level = 0
	night_damaged_electronics = 0
	invasion_active = false
	office_shutters = 0
	players.clear()
	taken_scrap.clear()
	state_changed.emit(&"reset")


## ---------------- read models ----------------

func is_host() -> bool:
	return _is_server


func balance_of(peer_id: int) -> int:
	return int(players.get(peer_id, {}).get("balance", 0))


func wallet(peer_id: int) -> Dictionary:
	return players.get(peer_id, {})


func local_wallet() -> Dictionary:
	return wallet(SteamNet.local_peer_id)


func inventory_slots(peer_id: int) -> Array:
	var slots: Array = wallet(peer_id).get("items", []).duplicate()
	if slots.size() < INVENTORY_SIZE:
		slots.resize(INVENTORY_SIZE)
	for slot in range(INVENTORY_SIZE):
		if slots[slot] == null:
			slots[slot] = ""
	return slots


func is_dead(peer_id: int) -> bool:
	return bool(wallet(peer_id).get("dead", false))


func days_until_quota() -> int:
	return maxi(DAYS_PER_CYCLE - ((day_index - 1) % DAYS_PER_CYCLE), 1)


func phase_name() -> String:
	return String(PHASE_NAMES.get(phase, "Menu"))


func is_play_phase() -> bool:
	return phase == Phase.NIGHT_SCAVENGE or phase == Phase.HUB_INVASION


## Any phase where a 3D round is live: input gates and AI updates agree on this.
func is_hub_phase() -> bool:
	return phase == Phase.HUB_DAY or phase == Phase.HUB_INVASION


func is_world_phase() -> bool:
	return phase in [Phase.HUB_DAY, Phase.TRANSPORT, Phase.NIGHT_SCAVENGE, Phase.HUB_INVASION, Phase.SETTLEMENT]


## The one place noise becomes game state. Monster AI listens to noise_reported instead of
## per-event signals, which is how a loud group of four gets hunted faster than a solo run.
func server_register_noise(level: float, kind: int, peer_id: int) -> void:
	if not _is_server:
		return
	# Clients report their own noise over an unreliable RPC: clamp to the design range so a
	# forged or NaN level cannot pin the alert meter or deafen the hunter.
	if not is_finite(level):
		return
	level = clampf(level, 0.0, 120.0)
	kind = clampi(kind, 0, Player.NoiseKind.HEAVY_STEP)
	noise_reported.emit(level, kind, peer_id)
	if not is_play_phase():
		return
	loudest_noise = maxf(loudest_noise, level)
	alert_level = clampf(alert_level + level * NOISE_ALERT_GAIN, 0.0, 1.0)
	if phase == Phase.NIGHT_SCAVENGE and server_should_spawn_boss():
		invasion_active = true


## Monsters scale their hearing to the loudest recent sound, so it decays as fast as it climbs.
func noise_pressure() -> float:
	return clampf(loudest_noise / 100.0, 0.0, 1.0) * alert_level


func team_balance() -> int:
	var total := 0
	for peer_id in players:
		total += int(players[peer_id].get("balance", 0))
	return total


## Cozy Level converts hub cosmetics into passive team buffs. Players read this
## when they build their own movement/battery parameters.
func cozy_buffs() -> Dictionary:
	var buffs: Dictionary = COZY_BUFF_TABLE.duplicate(true)
	@warning_ignore("integer_division")
	var tiers: int = clampi(night_cozy_level / 25, 0, 4) if is_play_phase() else 0
	buffs["stamina_multiplier"] = 1.0 + 0.05 * tiers
	var wear: float = minf(0.15 * night_damaged_electronics, 0.60) if is_play_phase() else 0.0
	buffs["battery_drain_multiplier"] = (1.0 - 0.08 * tiers) * (1.0 + wear)
	buffs["noise_multiplier"] = maxf(1.0 - 0.05 * tiers, 0.6)
	return buffs


## ---------------- server-authoritative mutators ----------------

func server_set_phase(new_phase: int) -> void:
	if not _is_server or (daytime_open and new_phase != Phase.HUB_DAY):
		return
	if new_phase != phase:
		office_shutters = 0
	phase = new_phase
	if new_phase == Phase.NIGHT_SCAVENGE:
		night_cozy_level = cozy_level
		night_damaged_electronics = daytime_damaged_ids.size()
		_server_reroll_seed()
	SteamNet.note("[state] phase -> %s (day %d, quota %d, seed %d)" % [
		phase_name(), day_index, quota_cents, map_seed,
	])
	_publish_state()
	# The host applies its own phase locally too: without this the listen server never
	# rebuilds the map or moves the crew when it changes phase itself.
	state_changed.emit(&"state")


func server_set_office_shutters(mask: int) -> void:
	if not _is_server or not is_hub_phase() or office_shutters == mask:
		return
	office_shutters = mask
	_publish_state()
	state_changed.emit(&"office_shutters")


func server_advance_day() -> void:
	if not _is_server:
		return
	_advance_day()
	_publish_state()


func _advance_day() -> void:
	day_index += 1
	daytime_report = {}
	if (day_index - 1) % DAYS_PER_CYCLE == 0:
		_check_quota()
		quota_index = mini(floori(float(day_index - 1) / DAYS_PER_CYCLE), QUOTA_BY_CYCLE.size() - 1)
		quota_cents = roundi(float(QUOTA_BY_CYCLE[quota_index]) * quota_scalar())
		earnings_cents = 0


func server_add_scrap(peer_id: int, value_cents: int) -> void:
	if not _is_server:
		return
	var wallet_data: Dictionary = players.get(peer_id, {})
	if wallet_data.is_empty():
		return
	wallet_data["scrap_value"] = int(wallet_data["scrap_value"]) + value_cents
	players[peer_id] = wallet_data
	_rpc_sync_player.rpc(wallet_data)


## The hunter reports a catch here and nowhere else: only the server may take a haul away
## or put somebody on the floor. The body stays where it fell until the crew carts it to the
## ship - there is no countdown and no automatic way back.
func server_player_caught(peer_id: int) -> void:
	if not _is_server:
		return
	# Copy before mutating: players[] must keep the old flag until _set_wallet compares it,
	# otherwise the life signal sees "was dead == is dead" and never fires.
	var wallet_data: Dictionary = players.get(peer_id, {}).duplicate()
	if wallet_data.is_empty() or bool(wallet_data.get("dead", false)):
		return
	var lost := int(wallet_data.get("scrap_value", 0))
	wallet_data["scrap_value"] = 0
	wallet_data["lost_scrap"] = lost
	wallet_data["dead"] = true
	_set_wallet(wallet_data)
	SteamNet.note("[state] peer=%d схвачен, лом потерян $%d" % [peer_id, lost])


## The round records each peer's spawn slot once, at spawn time.
func server_set_spawn_pos(peer_id: int, pos: Vector3) -> void:
	if not _is_server:
		return
	var wallet_data: Dictionary = players.get(peer_id, {})
	if wallet_data.is_empty():
		return
	wallet_data["spawn_pos"] = pos
	_set_wallet(wallet_data)


## A picked scrap point stays picked for everyone: the index travels in the state payload.
func server_take_scrap(index: int) -> void:
	if not _is_server or taken_scrap.has(index):
		return
	taken_scrap.append(index)
	_publish_state()


## Flying off resets the crew for the next night: alive, empty-handed, back at the slots.
## return_home is a counter, not a flag, so two extractions in a row both teleport.
func server_reset_crew() -> void:
	if not _is_server:
		return
	for peer_id in players.keys():
		var wallet_data: Dictionary = players[peer_id].duplicate()
		wallet_data["dead"] = false
		wallet_data["lost_scrap"] = 0
		wallet_data["return_home"] = int(wallet_data.get("return_home", 0)) + 1
		_set_wallet(wallet_data)
	taken_scrap.clear()
	_publish_state()


## Single write path for a wallet: stores it, tells the HUD, and fires the life signal only
## on an actual flip so a countdown tick never looks like a death to listeners.
func _set_wallet(wallet_data: Dictionary) -> void:
	var peer_id := int(wallet_data.get("peer_id", 0))
	if peer_id == 0:
		return
	var was_dead := bool(players.get(peer_id, {}).get("dead", false))
	players[peer_id] = wallet_data
	_rpc_sync_player.rpc(wallet_data)
	player_wallet_updated.emit(peer_id, int(wallet_data.get("balance", 0)))
	if was_dead != bool(wallet_data.get("dead", false)):
		player_life_changed.emit(peer_id, bool(wallet_data.get("dead", false)))
	state_changed.emit(&"players")


## Selling happens inside the container, so the whole team's haul moves together.
## Extraction supplies the basket as part of the same sale. Stage the day rollover
## with the payout so a restart cannot replay a paid shipment or repeat the day.
func server_sell_cargo(carrier: int = 0, basket_value: int = 0, advance_day: bool = false) -> bool:
	if not _is_server or not SteamNet.is_host or phase != Phase.NIGHT_SCAVENGE:
		return false
	var previous: Dictionary = campaign_snapshot()
	var previous_wallets: Dictionary = players.duplicate(true)
	var market: float = randf_range(0.5, 1.2)
	var total: int = 0
	for peer_id: int in players:
		var entry: Dictionary = players[peer_id]
		var haul: int = int(entry["scrap_value"]) + (basket_value if carrier == peer_id else 0)
		if haul <= 0:
			continue
		var payout: int = roundi(float(haul) * market)
		entry["scrap_value"] = 0
		entry["balance"] = int(entry["balance"]) + payout
		total += payout
	earnings_cents += total
	if advance_day:
		_advance_day()
	if (advance_day or total > 0) and SaveManager.checkpoint() != OK:
		players = previous_wallets
		apply_campaign(previous, false)
		return false
	_broadcast_wallets()
	_publish_state()
	return true


## Rolling a new night also resets the crew's haul for that run.
func server_begin_invasion() -> void:
	if not _is_server or daytime_open:
		return
	invasion_active = true
	night_cozy_level = cozy_level
	night_damaged_electronics = daytime_damaged_ids.size()
	server_set_phase(Phase.HUB_INVASION)


## The "Utilizer" raid unlocks when the crew is underwater and loud.
func server_finish_invasion() -> bool:
	if not _is_server or phase != Phase.HUB_INVASION:
		return false
	invasion_active = false
	if SaveManager.checkpoint() != OK:
		invasion_active = true
		return false
	server_set_phase(Phase.HUB_DAY)
	return true


func server_should_spawn_boss() -> bool:
	return debt_cents > 0 and (alert_level >= 1.0 or float(debt_cents) > float(quota_cents) * 1.5)


func quota_scalar() -> float:
	## 1.0 for a solo crew, ~1.55 for a full four-player crew.
	return 1.0 + 0.18 * maxf(float(players.size()) - 1.0, 0.0)


func _server_reroll_seed() -> void:
	var next_seed: int = randi_range(1, 999999)
	map_seed = next_seed if next_seed != map_seed else next_seed % 999999 + 1
	taken_scrap.clear()


## A late joiner needs every wallet, not only its own.
func _broadcast_wallets() -> void:
	for entry in players.values():
		_rpc_sync_player.rpc(entry)


func _check_quota() -> void:
	var paid := mini(earnings_cents, quota_cents)
	debt_cents += quota_cents - paid
	if debt_cents > 0:
		invasion_active = true
	SteamNet.note("[state] quota settled %d/%d -> debt %d, invasion %s" % [
		paid, quota_cents, debt_cents, invasion_active,
	])


func _publish_state() -> void:
	_rpc_publish_state.rpc(network_snapshot())


func network_snapshot() -> Dictionary:
	return {
		"phase": phase,
		"day": day_index,
		"quota": quota_cents,
		"quota_index": quota_index,
		"decor_positions": decor_positions,
		"debt": debt_cents,
		"earnings": earnings_cents,
		"seed": map_seed,
		"alert": alert_level,
		"cozy": cozy_level,
		"business_balance": business_balance,
		"daytime_open": daytime_open,
		"daytime_props": daytime_prop_ids,
		"daytime_damage": daytime_damaged_ids,
		"daytime_report": daytime_report,
		"night_cozy": night_cozy_level,
		"night_damage": night_damaged_electronics,
		"invasion": invasion_active,
		"office_shutters": office_shutters,
		"taken": taken_scrap.duplicate(),
	}


## Durable campaign data is independent from the live phase and transient player nodes.
func campaign_snapshot() -> Dictionary:
	var decorations: Array[Dictionary] = []
	var damaged_fixtures: PackedInt32Array = daytime_damaged_ids.duplicate()
	for id: int in daytime_prop_ids:
		decorations.append({
			"item_id": id,
			"grid_position": decor_positions.get(id, Vector3.ZERO),
			"damaged": daytime_damaged_ids.has(id),
		})
		var index: int = damaged_fixtures.find(id)
		if index >= 0:
			damaged_fixtures.remove_at(index)
	return {
		"day": day_index, "quota_index": quota_index, "quota": quota_cents,
		"earnings": earnings_cents, "debt": debt_cents, "cozy": cozy_level,
		"business_balance": business_balance, "daytime_report": daytime_report.duplicate(true),
		"decorations": decorations, "damaged_fixtures": damaged_fixtures,
		"invasion_pending": invasion_active,
	}


func apply_campaign(data: Dictionary, notify: bool = true) -> void:
	day_index = int(data["day"])
	quota_index = int(data["quota_index"])
	quota_cents = int(data["quota"])
	earnings_cents = int(data["earnings"])
	debt_cents = int(data["debt"])
	cozy_level = int(data["cozy"])
	business_balance = int(data["business_balance"])
	daytime_report = data["daytime_report"]
	invasion_active = bool(data["invasion_pending"])
	daytime_prop_ids = PackedInt32Array()
	daytime_damaged_ids = data.get("damaged_fixtures", PackedInt32Array())
	decor_positions.clear()
	for item: Dictionary in data["decorations"]:
		var id: int = int(item["item_id"])
		daytime_prop_ids.append(id)
		decor_positions[id] = item["grid_position"]
		if bool(item["damaged"]):
			daytime_damaged_ids.append(id)
	if notify:
		state_changed.emit(&"campaign")


## DaytimeManager calls these from its physics tick. They have no remote entry points.
func server_open_daytime() -> bool:
	if not _is_server or phase != Phase.HUB_DAY or daytime_open or not daytime_report.is_empty():
		return false
	daytime_open = true
	_publish_daytime()
	return true


func server_credit_business(amount: int) -> void:
	if _is_server and daytime_open and amount > 0:
		business_balance += amount
		_publish_daytime()


func server_buy_decor(peer_id: int, prop_id: int, price: int, cozy_value: int, grid_position: Vector3) -> bool:
	if not _is_server or peer_id != 1 or not players.has(peer_id) or is_dead(peer_id) \
		or phase != Phase.HUB_DAY or not daytime_report.is_empty() or daytime_prop_ids.has(prop_id) \
		or prop_id <= 0 or cozy_value < 0 or price <= 0 or price > business_balance:
		return false
	business_balance -= price
	daytime_prop_ids.append(prop_id)
	decor_positions[prop_id] = grid_position
	cozy_level += cozy_value
	_publish_daytime()
	return true


func server_set_decor_damage(prop_id: int, damaged: bool) -> void:
	if not _is_server or phase != Phase.HUB_DAY or prop_id <= 0:
		return
	var index: int = daytime_damaged_ids.find(prop_id)
	if damaged and index == -1:
		daytime_damaged_ids.append(prop_id)
	elif not damaged and index != -1:
		daytime_damaged_ids.remove_at(index)
	else:
		return
	_publish_daytime()


func server_close_daytime(sales: int, tips: int, penalties: int) -> bool:
	if not _is_server or not daytime_open:
		return false
	var charged: int = clampi(penalties, 0, business_balance)
	business_balance -= charged
	daytime_open = false
	daytime_report = {
		"day": day_index,
		"sales": sales,
		"tips": tips,
		"penalties": charged,
		"cozy_level": cozy_level,
		"balance": business_balance,
	}
	if SaveManager.checkpoint() != OK:
		business_balance += charged
		daytime_open = true
		daytime_report.clear()
		return false
	_publish_daytime()
	return true


func _publish_daytime() -> void:
	_publish_state()
	state_changed.emit(&"daytime")


## ---------------- pizzeria loadout ----------------

## The pizzeria counter sells against the wallet balance, server-side only. Returns an
## empty string on success, otherwise the reason the purchase was refused.
func server_buy_item(peer_id: int, item_id: String) -> String:
	if not _is_server:
		return "Покупки считает хост."
	if phase != Phase.HUB_DAY or is_dead(peer_id):
		return "Покупки доступны в пиццерии."
	if not SHOP_ITEMS.has(item_id):
		return "Такого предмета нет в меню пиццерии."
	var wallet_data: Dictionary = players.get(peer_id, {}).duplicate()
	if wallet_data.is_empty():
		return "Кошелёк ещё не открылся."
	var items := inventory_slots(peer_id)
	var slot := items.find("")
	if slot < 0 or slot >= INVENTORY_SIZE:
		return "Все три слота заняты."
	var price := int(SHOP_ITEMS[item_id]["price"])
	var balance := int(wallet_data.get("balance", 0))
	if balance < price:
		return "Не хватает денег: нужно $%d, есть $%d." % [price, balance]
	wallet_data["balance"] = balance - price
	items[slot] = item_id
	wallet_data["items"] = items
	_set_wallet(wallet_data)
	SteamNet.note("[shop] peer=%d купил %s за $%d" % [peer_id, item_id, price])
	return ""


func server_set_inventory_slot(peer_id: int, slot: int, item_id: String) -> void:
	if not _is_server or slot < 0 or slot >= INVENTORY_SIZE:
		return
	var wallet_data := wallet(peer_id).duplicate()
	if wallet_data.is_empty() or (item_id != "" and not SHOP_ITEMS.has(item_id)):
		return
	var items := inventory_slots(peer_id)
	items[slot] = item_id
	# Keep equipment from older wallets that could hold more than three purchases.
	if item_id.is_empty() and items.size() > INVENTORY_SIZE:
		items[slot] = items.pop_at(INVENTORY_SIZE)
	wallet_data["items"] = items
	_set_wallet(wallet_data)


func request_buy_item(item_id: String) -> void:
	if _is_server:
		var result := server_buy_item(SteamNet.local_peer_id, item_id)
		shop_purchase_finished.emit(item_id, result)
	else:
		_rpc_server_buy.rpc_id(1, item_id)


@rpc("any_peer", "call_remote", "reliable")
func _rpc_server_buy(item_id: String) -> void:
	if not _is_server:
		return
	var peer_id := multiplayer.get_remote_sender_id()
	var result := server_buy_item(peer_id, item_id)
	_rpc_shop_result.rpc_id(peer_id, item_id, result)


@rpc("authority", "call_remote", "reliable")
func _rpc_shop_result(item_id: String, error: String) -> void:
	shop_purchase_finished.emit(item_id, error)


## ---------------- client requests ----------------

## Phase changes are host-only: a client that could request a phase could reroll the seed
## or skip the pizzeria, so there is deliberately no client RPC path here.
func request_phase(new_phase: int) -> void:
	if _is_server:
		server_set_phase(new_phase)


## ---------------- replicated state ----------------

@rpc("authority", "call_remote", "reliable")
func _rpc_publish_state(data: Dictionary) -> void:
	if _is_server or multiplayer.get_remote_sender_id() != 1:
		return
	apply_network_snapshot(data)


func apply_network_snapshot(data: Dictionary) -> void:
	if _is_server:
		return
	phase = int(data.get("phase", phase))
	day_index = int(data.get("day", day_index))
	quota_cents = int(data.get("quota", quota_cents))
	quota_index = int(data.get("quota_index", quota_index))
	var positions: Dictionary = data.get("decor_positions", {})
	decor_positions.assign(positions)
	debt_cents = int(data.get("debt", debt_cents))
	earnings_cents = int(data.get("earnings", earnings_cents))
	map_seed = int(data.get("seed", map_seed))
	alert_level = float(data.get("alert", alert_level))
	cozy_level = int(data.get("cozy", cozy_level))
	business_balance = int(data.get("business_balance", business_balance))
	daytime_open = bool(data.get("daytime_open", daytime_open))
	daytime_prop_ids = data.get("daytime_props", daytime_prop_ids)
	daytime_damaged_ids = data.get("daytime_damage", daytime_damaged_ids)
	daytime_report = data.get("daytime_report", daytime_report)
	night_cozy_level = int(data.get("night_cozy", night_cozy_level))
	night_damaged_electronics = int(data.get("night_damage", night_damaged_electronics))
	invasion_active = bool(data.get("invasion", invasion_active))
	office_shutters = int(data.get("office_shutters", office_shutters))
	if data.has("taken"):
		taken_scrap.clear()
		for index in data["taken"]:
			taken_scrap.append(int(index))
	state_changed.emit(&"state")


@rpc("authority", "call_remote", "reliable")
func _rpc_sync_player(wallet_data: Dictionary) -> void:
	if _is_server or multiplayer.get_remote_sender_id() != 1:
		return
	var peer_id := int(wallet_data.get("peer_id", 0))
	if peer_id == 0:
		return
	var was_dead := bool(players.get(peer_id, {}).get("dead", false))
	players[peer_id] = wallet_data
	player_wallet_updated.emit(peer_id, int(wallet_data.get("balance", 0)))
	if was_dead != bool(wallet_data.get("dead", false)):
		player_life_changed.emit(peer_id, bool(wallet_data.get("dead", false)))
	state_changed.emit(&"players")


@rpc("authority", "call_remote", "reliable")
func _rpc_drop_player(peer_id: int) -> void:
	if _is_server or multiplayer.get_remote_sender_id() != 1:
		return
	players.erase(peer_id)
	player_left.emit(peer_id)
	state_changed.emit(&"players")
