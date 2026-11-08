class_name DaytimeManager
extends Node3D
## The pizzeria is a subphase of HUB_DAY. Only the host advances the clock, spawns
## customers, owns reservations and changes the ledger. Clients render snapshots and
## submit intent. All world queries and transaction commits run on the physics tick.

signal feedback_changed

enum Command { INTERACT, REPAIR_KEY, OPEN, BUY, START_NIGHT }
enum VisitPhase { ARRIVING, STAYING, LEAVING }

const SHIFT_SECONDS: float = 180.0
const START_MINUTE: int = 9 * 60
const SHIFT_MINUTES: int = 8 * 60
const REACH: float = 2.35
const KITCHEN: int = 0
const MAX_GUESTS: int = 8
const GUEST_SPEED: float = 2.25
const STREAM_INTERVAL: float = 0.125
const QTE_STEPS: int = 6
const QTE_SECONDS: float = 8.0
const KEY_INTERVAL_MS: int = 65
const HEAT_RATE: float = 2.25
const SHOW_RADIUS: float = 8.5
const HEAT_RESET: float = 20.0
const CUSTOMER_AISLE: float = 3.65

class Visit:
	var id: int
	var prop: InteractiveProp
	var child: bool
	var point: Vector3
	var route: Array[Vector3] = []
	var waypoint: int = 0
	var phase: VisitPhase = VisitPhase.ARRIVING
	var stay: float
	var served: bool = false
	var payout: int = 0

class Delivery:
	var visit_id: int
	var table: int
	var balance: float = 1.0
	var sample_position: Vector3
	var previous_velocity: Vector3 = Vector3.ZERO
	var sample_time: float = 0.0

class Repair:
	var prop: InteractiveProp
	var token: int
	var step: int = 0
	var key: int
	var expires: float
	var last_press: int

class WalkSample:
	var position: Vector3
	var spawn_position: Vector3
	var budget: float = 0.0
	var return_home: int

## Client read model for the HUD. Durable state and reports travel through GameState.
var remaining: float = 0.0
var temperature: float = HEAT_RESET
var order_tables: PackedInt32Array = PackedInt32Array()
var tablet_order_tables: PackedInt32Array = PackedInt32Array()
var order_seconds: PackedFloat32Array = PackedFloat32Array()
var _active_carriers: PackedInt32Array = PackedInt32Array()
var _close_retry: float = 0.0
var _closing_shift: bool = false
var carried_table: int = -1
var carry_balance: float = 0.0
var repair_token: int = 0
var repair_step: int = 0
var repair_key: int = -1
var feedback: String = ""

var _pizzeria: Pizzeria
var _players: Node3D
var _props: Dictionary[int, InteractiveProp] = {}
var _show: InteractiveProp
var _rng: RandomNumberGenerator = RandomNumberGenerator.new()
var _visits: Dictionary[int, Visit] = {}
var _deliveries: Dictionary[int, Delivery] = {}
var _repairs: Dictionary[int, Repair] = {}
var _walk: Dictionary[int, WalkSample] = {}
var _commands: Dictionary[int, Vector4i] = {}
var _next_command_ms: Dictionary[int, int] = {}
var _subscribers: Dictionary[int, bool] = {}
var _guest_visuals: Dictionary[int, Node3D] = {}
var _guest_targets: Dictionary[int, Vector3] = {}
var _box_visuals: Dictionary[int, MeshInstance3D] = {}
var _delivery_marker: Label3D
var _serial: int = 0
var _sales: int = 0
var _tips: int = 0
var _spawn_in: float = 0.0
var _fault_in: float = 0.0
var _stream_in: float = 0.0
var _subscribe_in: float = 0.0
var _subscribed: bool = false
var _cooldown: float = 0.0
var _feedback_until: int = 0
var _was_open: bool = false
var _installed_ids: PackedInt32Array
var _damaged_ids: PackedInt32Array

func configure(pizzeria: Pizzeria, players: Node3D) -> void:
	_pizzeria = pizzeria
	_players = players
	for node: Node in _pizzeria.get_node("DaytimeProps").get_children():
		var prop: InteractiveProp = node as InteractiveProp
		if prop == null:
			continue
		if prop.prop_id <= 0 or _props.has(prop.prop_id):
			push_error("Daytime prop needs a unique positive ID: %s" % prop.get_path())
			prop.hide()
			continue
		_props[prop.prop_id] = prop
		if prop.kind == InteractiveProp.Kind.ANIMATRONIC:
			_show = prop
	_rng.randomize()
	_delivery_marker = Label3D.new()
	_delivery_marker.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_delivery_marker.font_size = 44
	_delivery_marker.pixel_size = 0.006
	_delivery_marker.modulate = Color(1.0, 0.78, 0.37)
	_delivery_marker.hide()
	add_child(_delivery_marker)
	_sync_world(true)
	GameState.state_changed.connect(_on_game_state)
	GameState.player_left.connect(_on_player_left)


func catalog() -> Array[InteractiveProp]:
	return _props.values()


func is_carrying_order(peer_id: int) -> bool:
	return _active_carriers.has(peer_id)


func prop_name(id: int) -> String:
	return _props[id].display_name if _props.has(id) else ""


func clock_text() -> String:
	var minute: int = START_MINUTE + floori((1.0 - remaining / SHIFT_SECONDS) * SHIFT_MINUTES)
	@warning_ignore("integer_division")
	return "%02d:%02d" % [minute / 60, minute % 60]


func stage_status() -> String:
	if not GameState.daytime_open or _show == null or not _show.installed:
		return ""
	return "Сцена · перегрев" if _show.damaged else "Сцена · %d °C" % roundi(temperature)


func can_vent_stage() -> bool:
	return GameState.daytime_open and _show != null and _show.installed and not _show.damaged \
		and temperature > HEAT_RESET and _cooldown <= 0.0


## Used by the physical switch and the tablet after their respective access checks.
func server_vent_stage() -> bool:
	if not GameState.is_host() or not can_vent_stage():
		return false
	temperature = maxf(HEAT_RESET, temperature - 55.0)
	_cooldown = 7.0
	return true


func target_position(id: int) -> Vector3:
	return _pizzeria.kitchen_pickup_pos() if id == KITCHEN else _props[id].interaction_position()


## Pure presentation hint. The server repeats the phase, identity, reach and LOS checks.
func focus_target(player: Player) -> int:
	var eye: Vector3 = player.interaction_origin()
	var facing: Vector3 = player.interaction_direction()
	var best: int = -1
	var best_dot: float = 0.83
	var targets: PackedInt32Array = order_tables.duplicate()
	if carried_table >= 0:
		targets.append(carried_table)
	if GameState.daytime_open:
		targets.append(KITCHEN)
	for prop: InteractiveProp in _props.values():
		if prop.installed and (prop == _show or (GameState.daytime_open and prop.kind == InteractiveProp.Kind.ARCADE and prop.damaged)):
			targets.append(prop.prop_id)
	for id: int in targets:
		if interaction_hint(id).is_empty():
			continue
		var point: Vector3 = target_position(id)
		var offset: Vector3 = point - eye
		var aim: float = facing.dot(offset.normalized())
		if aim > best_dot and _reachable(eye, point):
			best = id
			best_dot = aim
	return best


func interaction_hint(id: int) -> String:
	if id == KITCHEN:
		return "Взять пиццу" if carried_table == -1 and not order_tables.is_empty() else ""
	var prop: InteractiveProp = _props.get(id)
	if prop == null:
		return ""
	if prop == _show:
		if GameState.daytime_open and not prop.damaged:
			return "Охладить аниматроника · %d °C" % roundi(temperature)
		if not GameState.daytime_open and GameState.daytime_report.is_empty() and prop.damaged:
			return "Восстановить аниматроника"
	if GameState.daytime_open and prop.kind == InteractiveProp.Kind.ARCADE and prop.damaged:
		return "Починить автомат"
	if GameState.daytime_open and id == carried_table:
		return "Подать пиццу · " + prop.display_name
	return ""


func request_interaction(id: int) -> void:
	_request(Command.INTERACT, id, 0, 0)


func request_repair_key(key: int) -> void:
	if repair_key >= 0:
		_request(Command.REPAIR_KEY, key, repair_token, repair_step)


func request_open() -> void:
	if GameState.is_host():
		_request(Command.OPEN, 0, 0, 0)


func request_buy(prop_id: int) -> void:
	if GameState.is_host():
		_request(Command.BUY, prop_id, 0, 0)


func request_night() -> void:
	if GameState.is_host():
		_request(Command.START_NIGHT, 0, 0, 0)


func _request(command: Command, value: int, token: int, step: int) -> void:
	if GameState.is_host():
		_queue(1, command, value, token, step)
	elif _connected():
		_rpc_request.rpc_id(1, GameState.day_index, command, value, token, step)


@rpc("any_peer", "call_remote", "reliable")
func _rpc_request(day: int, command: int, value: int, token: int, step: int) -> void:
	var sender: int = multiplayer.get_remote_sender_id()
	# Remote peers can only perform world tasks. Even a hand-crafted RPC cannot
	# open the doors, buy decor, pick a payout or advance the phase.
	if not GameState.is_host() or sender <= 1 or not _subscribers.has(sender) or day != GameState.day_index:
		return
	if command == Command.INTERACT and (value == KITCHEN or _props.has(value)):
		_queue(sender, command, value, 0, 0)
	elif command == Command.REPAIR_KEY and value >= 0 and value < 4 \
		and token > 0 and token <= 2147483647 and step >= 0 and step < QTE_STEPS:
		_queue(sender, command, value, token, step)


func _queue(peer: int, command: int, value: int, token: int, step: int) -> void:
	var now: int = Time.get_ticks_msec()
	if GameState.phase != GameState.Phase.HUB_DAY or not GameState.players.has(peer) \
		or GameState.is_dead(peer) or _commands.has(peer) or now < _next_command_ms.get(peer, 0):
		return
	_next_command_ms[peer] = now + KEY_INTERVAL_MS
	_commands[peer] = Vector4i(command, value, token, step)


func _physics_process(delta: float) -> void:
	if _pizzeria == null:
		return
	if not GameState.is_host():
		_subscribe_in -= delta
		if not _subscribed and _subscribe_in <= 0.0 and _connected():
			_subscribe_in = 1.0
			_rpc_subscribe.rpc_id(1)
		return
	if GameState.phase != GameState.Phase.HUB_DAY:
		_walk.clear()
		return
	_track_players(delta)
	if GameState.daytime_open:
		remaining = maxf(0.0, remaining - delta)
		if remaining == 0.0:
			_close_retry = maxf(0.0, _close_retry - delta)
			if _close_retry == 0.0:
				_close_shift()
			_commands.clear()
			return
		else:
			_tick_shift(delta)
	for peer: int in _commands.keys():
		_execute(peer, _commands[peer])
	_commands.clear()
	if GameState.daytime_open:
		_stream_in -= delta
		if _stream_in <= 0.0:
			_stream_in += STREAM_INTERVAL
			_publish_live()


func _execute(peer: int, command: Vector4i) -> void:
	if GameState.phase != GameState.Phase.HUB_DAY or GameState.is_dead(peer):
		return
	var player: Player = _player(peer)
	var sample: WalkSample = _walk.get(peer)
	if player == null or sample == null:
		return
	if not player.global_position.is_finite() or sample.position.distance_squared_to(player.global_position) > 0.36:
		return
	# Head offset comes from the body pose, applied to the host's accepted
	# position. The request never carries a transform or a hit result.
	var eye: Vector3 = _eye(player, sample)
	match command.x:
		Command.INTERACT:
			_interact(peer, eye, command.y)
		Command.REPAIR_KEY:
			_repair_press(peer, eye, command.y, command.z, command.w)
		Command.OPEN, Command.BUY:
			if peer != 1 or not _pizzeria.security.can_reach_control(eye, SecurityOffice.DAYTIME_CONTROL):
				return
			if command.x == Command.OPEN:
				_open_shift()
			else:
				_buy(command.y)
		Command.START_NIGHT:
			if peer == 1 and not GameState.daytime_report.is_empty():
				GameState.server_set_phase(GameState.Phase.NIGHT_SCAVENGE)


func _open_shift() -> void:
	if GameState.daytime_open or not GameState.daytime_report.is_empty():
		return
	remaining = SHIFT_SECONDS
	_sales = 0
	_tips = 0
	_spawn_in = 0.8
	_fault_in = _rng.randf_range(12.0, 22.0)
	_stream_in = 0.0
	_cooldown = 0.0
	temperature = HEAT_RESET
	GameState.server_open_daytime()


func _buy(id: int) -> void:
	var prop: InteractiveProp = _props.get(id)
	if prop == null or prop.installed or not GameState.server_buy_decor(1, id, prop.price, prop.cozy_value, prop.position):
		_send_feedback(1, "Покупка недоступна. Проверьте кассу и статус смены.")
		return
	_send_feedback(1, "Установлено · " + prop.display_name)


func _tick_shift(delta: float) -> void:
	_tick_equipment(delta)
	for id: int in _visits.keys():
		_tick_visit(_visits[id], delta)
	for peer: int in _deliveries.keys():
		_tick_delivery(peer, _deliveries[peer], delta)
	for peer: int in _repairs.keys():
		var repair: Repair = _repairs[peer]
		var player: Player = _player(peer)
		var sample: WalkSample = _walk.get(peer)
		if remaining < repair.expires or player == null or sample == null or GameState.is_dead(peer) \
			or not _reachable(_eye(player, sample), repair.prop.interaction_position()):
			_finish_repair(peer, false, "Ремонт прерван")
	_spawn_in -= delta
	if _spawn_in <= 0.0:
		_spawn_in = _rng.randf_range(4.5, 6.5)
		if remaining > 34.0 and _visits.size() < MAX_GUESTS:
			_spawn_guest()


func _spawn_guest() -> void:
	var destinations: Array[InteractiveProp] = []
	for prop: InteractiveProp in _props.values():
		if prop.accepts_customer():
			destinations.append(prop)
	if destinations.is_empty():
		return
	var visit: Visit = Visit.new()
	_serial += 1
	visit.id = _serial
	visit.prop = destinations[_rng.randi_range(0, destinations.size() - 1)]
	visit.prop.reserved_by = visit.id
	visit.child = _rng.randf() < 0.48
	visit.stay = _rng.randf_range(20.0, 30.0)
	var entry_x: float = Pizzeria.PUBLIC_ENTRANCE + (-0.45 if visit.child else 0.45)
	visit.point = _pizzeria.to_global(Vector3(entry_x, 0.0, 6.75))
	var seat: Vector3 = visit.prop.customer_position()
	var aisle: Vector3 = _pizzeria.to_local(seat)
	# Both directions use the same public aisle and an approach lane authored
	# clear of the dining furniture. The two entry points share one doorway.
	visit.route = [
		visit.point,
		_pizzeria.to_global(Vector3(entry_x, 0.0, CUSTOMER_AISLE)),
		_pizzeria.to_global(Vector3(aisle.x, aisle.y, CUSTOMER_AISLE)),
		seat,
	]
	_visits[visit.id] = visit


func _tick_visit(visit: Visit, delta: float) -> void:
	if visit.phase == VisitPhase.STAYING:
		visit.stay -= delta
		if visit.stay <= 0.0:
			_leave(visit, true)
		return
	var target: Vector3 = visit.route[visit.waypoint]
	visit.point = visit.point.move_toward(target, GUEST_SPEED * delta)
	if not visit.point.is_equal_approx(target):
		return
	if visit.phase == VisitPhase.ARRIVING:
		visit.waypoint += 1
		if visit.waypoint == visit.route.size():
			visit.waypoint -= 1
			visit.phase = VisitPhase.STAYING
	else:
		visit.waypoint -= 1
		if visit.waypoint < 0:
			_visits.erase(visit.id)
			_sales += visit.payout
			GameState.server_credit_business(visit.payout)


func _leave(visit: Visit, paying: bool) -> void:
	if visit.phase == VisitPhase.LEAVING:
		return
	if paying and not visit.prop.damaged:
		visit.payout = visit.prop.payout()
		for prop: InteractiveProp in _props.values():
			if prop.kind == InteractiveProp.Kind.NEON:
				visit.payout += prop.payout()
		if _show != null and _show.installed and not _show.damaged \
			and _show.global_position.distance_to(visit.prop.customer_position()) <= SHOW_RADIUS:
			visit.payout *= 2
	# Reverse from the last reached waypoint, even if the guest was interrupted
	# en route. Release only this reservation so other guests can use the table.
	visit.prop.reserved_by = 0
	if visit.phase == VisitPhase.ARRIVING:
		visit.waypoint = maxi(visit.waypoint - 1, 0)
	visit.phase = VisitPhase.LEAVING


func _tick_equipment(delta: float) -> void:
	_fault_in -= delta
	if _fault_in <= 0.0:
		_fault_in = _rng.randf_range(10.0, 17.0)
		for prop: InteractiveProp in _props.values():
			if prop.installed and not prop.damaged and prop.kind == InteractiveProp.Kind.ARCADE and _rng.randf() < 0.55:
				_damage(prop)
	_cooldown = maxf(_cooldown - delta, 0.0)
	if _show == null or not _show.installed or _show.damaged:
		return
	temperature = minf(100.0, temperature + HEAT_RATE * delta)
	if temperature < 100.0:
		return
	_damage(_show)


func _damage(prop: InteractiveProp) -> void:
	GameState.server_set_decor_damage(prop.prop_id, true)
	for visit: Visit in _visits.values():
		var near_show: bool = prop == _show and prop.global_position.distance_to(visit.point) <= SHOW_RADIUS
		if visit.prop == prop or near_show:
			_leave(visit, false)


func _interact(peer: int, eye: Vector3, id: int) -> void:
	if _repairs.has(peer) or (id != KITCHEN and not _props.has(id)):
		return
	if not _reachable(eye, target_position(id)):
		return
	if id == KITCHEN:
		if GameState.daytime_open:
			_pickup_pizza(peer)
		return
	var prop: InteractiveProp = _props[id]
	if not prop.installed:
		return
	if prop == _show:
		if not GameState.daytime_open and GameState.daytime_report.is_empty() and prop.damaged:
			GameState.server_set_decor_damage(id, false)
			_send_feedback(peer, "Аниматроник восстановлен")
		elif server_vent_stage():
			_send_feedback(peer, "Охлаждение запущено")
		elif GameState.daytime_open and not prop.damaged:
			_send_feedback(peer, "Охлаждение ещё восстанавливается")
		return
	if not GameState.daytime_open:
		return
	if prop.kind == InteractiveProp.Kind.ARCADE and prop.damaged and not _deliveries.has(peer):
		_start_repair(peer, prop)
	elif _deliveries.has(peer):
		_deliver_pizza(peer, prop)


func _pickup_pizza(peer: int) -> void:
	if _deliveries.has(peer):
		return
	for visit: Visit in _visits.values():
		if visit.phase != VisitPhase.STAYING or visit.prop.kind != InteractiveProp.Kind.SEAT \
			or visit.served or visit.stay < 8.0 or _order_assigned(visit.id):
			continue
		var delivery: Delivery = Delivery.new()
		delivery.visit_id = visit.id
		delivery.table = visit.prop.prop_id
		delivery.sample_position = _walk[peer].position
		_deliveries[peer] = delivery
		_send_feedback(peer, "Заказ · " + visit.prop.display_name)
		return
	_send_feedback(peer, "Сейчас нет свободных заказов")


func _order_assigned(visit_id: int) -> bool:
	for delivery: Delivery in _deliveries.values():
		if delivery.visit_id == visit_id:
			return true
	return false


func _tick_delivery(peer: int, delivery: Delivery, delta: float) -> void:
	var visit: Visit = _visits.get(delivery.visit_id)
	var sample: WalkSample = _walk.get(peer)
	if sample == null or GameState.is_dead(peer) or visit == null or visit.phase != VisitPhase.STAYING:
		_deliveries.erase(peer)
		_send_feedback(peer, "Заказ закрыт")
		return
	delivery.sample_time += delta
	if delivery.sample_time < 0.20:
		return
	# Measure the carrier's actual motion across several replication ticks. A
	# sprint, a sharp turn at speed or a jump shifts the box off balance.
	var span: float = delivery.sample_time
	var velocity: Vector3 = (sample.position - delivery.sample_position) / span
	var flat: Vector3 = Vector3(velocity.x, 0.0, velocity.z)
	var speed: float = flat.length()
	var turning: float = flat.angle_to(delivery.previous_velocity) if speed > 2.0 and delivery.previous_velocity.length() > 2.0 else 0.0
	delivery.balance = clampf(delivery.balance + span * (0.10 - 0.34 * maxf(speed - 3.15, 0.0) \
		- 0.40 * maxf(absf(velocity.y) - 0.8, 0.0)) - 0.12 * turning, 0.0, 1.0)
	delivery.sample_time = 0.0
	delivery.sample_position = sample.position
	delivery.previous_velocity = flat
	if delivery.balance <= 0.0:
		_deliveries.erase(peer)
		_send_feedback(peer, "Пицца упала. Возьмите новую на кухне.")


func _deliver_pizza(peer: int, prop: InteractiveProp) -> void:
	var delivery: Delivery = _deliveries[peer]
	if delivery.table != prop.prop_id:
		return
	var visit: Visit = _visits.get(delivery.visit_id)
	if visit == null or visit.phase != VisitPhase.STAYING or visit.served:
		return
	# Consume the reservation before crediting the shared wallet. Retries and
	# duplicate packets can never pay out twice for one visit.
	visit.served = true
	_deliveries.erase(peer)
	var tip: int = 3 + roundi(delivery.balance * 7.0)
	_tips += tip
	GameState.server_credit_business(tip)
	_send_feedback(peer, "Доставлено · чаевые $%d" % tip)


func _start_repair(peer: int, prop: InteractiveProp) -> void:
	for active: Repair in _repairs.values():
		if active.prop == prop:
			_send_feedback(peer, "Этот автомат уже чинят")
			return
	var repair: Repair = Repair.new()
	_serial += 1
	repair.prop = prop
	repair.token = _serial
	repair.key = _rng.randi_range(0, 3)
	repair.last_press = Time.get_ticks_msec() - KEY_INTERVAL_MS
	repair.expires = remaining - QTE_SECONDS
	_repairs[peer] = repair
	_send_repair(peer, repair)


func _repair_press(peer: int, eye: Vector3, key: int, token: int, step: int) -> void:
	var repair: Repair = _repairs.get(peer)
	if not GameState.daytime_open or repair == null or repair.token != token or repair.step != step:
		return
	var now: int = Time.get_ticks_msec()
	if now - repair.last_press < KEY_INTERVAL_MS:
		return
	if remaining < repair.expires or key != repair.key or not repair.prop.damaged \
		or not _reachable(eye, repair.prop.interaction_position()):
		_finish_repair(peer, false, "Ошибка ремонта. Попробуйте ещё раз.")
		return
	repair.step += 1
	repair.last_press = now
	if repair.step >= QTE_STEPS:
		_finish_repair(peer, true, "Автомат снова работает")
		return
	# Only the next key is sent to the repairer. Steps are tied to a nonce and
	# an exact sequence index so old, duplicated or guessed packets can't skip ahead.
	repair.key = (repair.key + _rng.randi_range(1, 3)) % 4
	_send_repair(peer, repair)


func _finish_repair(peer: int, repaired: bool, message: String) -> void:
	var repair: Repair = _repairs[peer]
	_repairs.erase(peer)
	if repaired:
		GameState.server_set_decor_damage(repair.prop.prop_id, false)
	_send_repair(peer, null)
	_send_feedback(peer, message)


func _close_shift() -> void:
	var penalty: int = 0
	for prop: InteractiveProp in _props.values():
		prop.reserved_by = 0
		if prop.damaged:
			penalty += prop.maintenance_penalty
	# Guests who completed their visit pay at closing even if they were still
	# walking toward the exit. Interrupted and fleeing visits have no payout.
	var exit_sales: int = 0
	for visit: Visit in _visits.values():
		exit_sales += visit.payout
	if not _closing_shift:
		_sales += exit_sales
		GameState.server_credit_business(exit_sales)
		_closing_shift = true
	_visits.clear()
	_deliveries.clear()
	_repairs.clear()
	_commands.clear()
	# Clear the vestibule before the public gate becomes a solid collider again.
	var slot: int = 0
	for peer: int in _walk:
		var point: Vector3 = _pizzeria.to_local(_walk[peer].position)
		if point.z >= 4.64 and absf(point.x - Pizzeria.PUBLIC_ENTRANCE) <= 1.27:
			GameState.server_set_spawn_pos(peer, _pizzeria.to_global(Vector3(-10.5 + slot * 0.6, 0.0, 3.8)))
			slot += 1
	if GameState.server_close_daytime(_sales, _tips, penalty):
		_closing_shift = false
	else:
		_close_retry = 2.0


func _player(peer: int) -> Player:
	return _players.get_node_or_null("Player%d" % peer) as Player


func _eye(player: Player, sample: WalkSample) -> Vector3:
	var height: float = clampf(player.interaction_origin().y - player.global_position.y, 0.8, 1.65)
	return sample.position + Vector3.UP * height


func _track_players(delta: float) -> void:
	# The game's remote controllers replicate owner-driven movement. The ledger
	# uses a separate host-observed position, rejecting teleports and segments
	# through solid world geometry. Only a host-issued spawn can reset it.
	for peer: int in GameState.players:
		var player: Player = _player(peer)
		if player == null:
			continue
		var wallet: Dictionary = GameState.wallet(peer)
		var spawn_count: int = int(wallet.get("return_home", 0))
		var spawn: Vector3 = wallet.get("spawn_pos", player.global_position)
		var sample: WalkSample = _walk.get(peer)
		if sample == null or sample.return_home != spawn_count or sample.spawn_position != spawn:
			sample = WalkSample.new()
			sample.position = spawn
			sample.spawn_position = spawn
			sample.return_home = spawn_count
			_walk[peer] = sample
		var point: Vector3 = player.global_position
		if not point.is_finite():
			continue
		if peer == 1:
			sample.position = point
			continue
		sample.budget = minf(2.15, sample.budget + 7.5 * delta)
		var distance: float = sample.position.distance_to(point)
		if distance > 0.001 and distance <= sample.budget \
			and _clear_path(sample.position + Vector3.UP, point + Vector3.UP):
			sample.position = point
			sample.budget -= distance


func _reachable(eye: Vector3, point: Vector3) -> bool:
	return eye.distance_squared_to(point) <= REACH * REACH and _clear_path(eye, point)


func _clear_path(from: Vector3, to: Vector3) -> bool:
	var ray: PhysicsRayQueryParameters3D = PhysicsRayQueryParameters3D.create(from, to, 1)
	return get_world_3d().direct_space_state.intersect_ray(ray).is_empty()


func _on_game_state(_key: StringName) -> void:
	_sync_world(false)


func _sync_world(force: bool) -> void:
	if force or _installed_ids != GameState.daytime_prop_ids or _damaged_ids != GameState.daytime_damaged_ids:
		_installed_ids = GameState.daytime_prop_ids.duplicate()
		_damaged_ids = GameState.daytime_damaged_ids.duplicate()
		for prop: InteractiveProp in _props.values():
			if GameState.decor_positions.has(prop.prop_id):
				prop.position = GameState.decor_positions[prop.prop_id]
			prop.apply_installation(_installed_ids.has(prop.prop_id), _damaged_ids.has(prop.prop_id))
	if force or _was_open != GameState.daytime_open:
		_was_open = GameState.daytime_open
		_pizzeria.set_daytime_open(_was_open)
		if _was_open:
			remaining = SHIFT_SECONDS
		else:
			remaining = 0.0
			order_tables.clear()
			tablet_order_tables.clear()
			order_seconds.clear()
			_active_carriers.clear()
			carried_table = -1
			carry_balance = 0.0
			repair_key = -1
			feedback = ""
			_apply_guests(PackedInt32Array(), PackedVector3Array(), 0)
			_apply_boxes(PackedInt32Array())
			_delivery_marker.hide()


func _on_player_left(peer: int) -> void:
	_subscribers.erase(peer)
	_walk.erase(peer)
	_deliveries.erase(peer)
	_repairs.erase(peer)
	_commands.erase(peer)
	_next_command_ms.erase(peer)


@rpc("any_peer", "call_remote", "reliable")
func _rpc_subscribe() -> void:
	var peer: int = multiplayer.get_remote_sender_id()
	if GameState.is_host() and peer > 1 and GameState.players.has(peer) and not _subscribers.has(peer):
		_subscribers[peer] = true
		_rpc_subscribed.rpc_id(peer)


func _connected() -> bool:
	return SteamNet.available() and multiplayer.multiplayer_peer != null \
		and multiplayer.multiplayer_peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED \
		and multiplayer.get_peers().has(1)


@rpc("authority", "call_remote", "reliable")
func _rpc_subscribed() -> void:
	_subscribed = true


func _publish_live() -> void:
	var ids: PackedInt32Array = PackedInt32Array()
	var positions: PackedVector3Array = PackedVector3Array()
	var orders: PackedInt32Array = PackedInt32Array()
	var active_orders: PackedInt32Array = PackedInt32Array()
	var deadlines: PackedFloat32Array = PackedFloat32Array()
	var child_mask: int = 0
	for visit: Visit in _visits.values():
		if visit.child:
			child_mask |= 1 << ids.size()
		ids.append(visit.id)
		positions.append(visit.point)
		if visit.phase == VisitPhase.STAYING and visit.prop.kind == InteractiveProp.Kind.SEAT \
			and not visit.served and visit.stay > 0.0:
			active_orders.append(visit.prop.prop_id)
			deadlines.append(visit.stay)
			if visit.stay >= 8.0 and not _order_assigned(visit.id):
				orders.append(visit.prop.prop_id)
	var carriers: PackedInt32Array = PackedInt32Array()
	for peer: int in _deliveries:
		carriers.append(peer)
	var host_delivery: Delivery = _deliveries.get(1)
	_rpc_live(GameState.day_index, remaining, temperature, ids, positions, child_mask, orders, active_orders, deadlines, carriers,
		host_delivery.table if host_delivery != null else -1, host_delivery.balance if host_delivery != null else 0.0)
	for peer: int in _subscribers:
		var delivery: Delivery = _deliveries.get(peer)
		_rpc_live.rpc_id(peer, GameState.day_index, remaining, temperature, ids, positions, child_mask, orders, active_orders, deadlines, carriers,
			delivery.table if delivery != null else -1, delivery.balance if delivery != null else 0.0)


@rpc("authority", "call_remote", "unreliable_ordered")
func _rpc_live(day: int, seconds: float, heat: float, ids: PackedInt32Array,
		positions: PackedVector3Array, child_mask: int, orders: PackedInt32Array, active_orders: PackedInt32Array,
		deadlines: PackedFloat32Array, carriers: PackedInt32Array, table: int, balance: float) -> void:
	if day != GameState.day_index or not GameState.daytime_open:
		return
	remaining = seconds
	temperature = heat
	carried_table = table
	carry_balance = balance
	order_tables = orders
	tablet_order_tables = active_orders
	order_seconds = deadlines
	_active_carriers = carriers
	_apply_guests(ids, positions, child_mask)
	_apply_boxes(carriers)
	_update_delivery_marker()


func _update_delivery_marker() -> void:
	_delivery_marker.visible = carried_table >= 0
	if _delivery_marker.visible:
		_delivery_marker.global_position = target_position(carried_table) + Vector3.UP * 1.13
		_delivery_marker.text = "ПИЦЦА · " + prop_name(carried_table).to_upper()


func _send_repair(peer: int, repair: Repair) -> void:
	var token: int = repair.token if repair != null else 0
	var step: int = repair.step if repair != null else 0
	var key: int = repair.key if repair != null else -1
	if peer == 1:
		_rpc_repair_state(GameState.day_index, token, step, key)
	elif _subscribers.has(peer):
		_rpc_repair_state.rpc_id(peer, GameState.day_index, token, step, key)


@rpc("authority", "call_remote", "reliable")
func _rpc_repair_state(day: int, token: int, step: int, key: int) -> void:
	if day == GameState.day_index and GameState.daytime_open:
		repair_token = token
		repair_step = step
		repair_key = key


func _send_feedback(peer: int, message: String) -> void:
	if peer == 1:
		_rpc_feedback(message)
	elif _subscribers.has(peer):
		_rpc_feedback.rpc_id(peer, message)


@rpc("authority", "call_remote", "reliable")
func _rpc_feedback(message: String) -> void:
	feedback = message
	_feedback_until = Time.get_ticks_msec() + 3600
	feedback_changed.emit()


func _process(delta: float) -> void:
	if not feedback.is_empty() and Time.get_ticks_msec() >= _feedback_until:
		feedback = ""
		feedback_changed.emit()
	for id: int in _guest_visuals:
		var guest: Node3D = _guest_visuals[id]
		var target: Vector3 = _guest_targets[id]
		guest.global_position = guest.global_position.move_toward(target, GUEST_SPEED * 1.5 * delta)
	for peer: int in _box_visuals:
		var player: Player = _player(peer)
		if player == null:
			continue
		var box: MeshInstance3D = _box_visuals[peer]
		box.global_position = player.interaction_origin() + Vector3.DOWN * 0.55 - player.global_basis.z * 0.58
		box.rotation.y = player.global_rotation.y
		box.rotation.z = (1.0 - carry_balance) * 0.45 if peer == SteamNet.local_peer_id else 0.0


func _apply_guests(ids: PackedInt32Array, positions: PackedVector3Array, child_mask: int) -> void:
	for id: int in _guest_visuals.keys():
		if not ids.has(id):
			_guest_visuals[id].queue_free()
			_guest_visuals.erase(id)
			_guest_targets.erase(id)
	for index: int in ids.size():
		var id: int = ids[index]
		var point: Vector3 = positions[index]
		if not _guest_visuals.has(id):
			var guest: Node3D = _build_guest((child_mask & (1 << index)) != 0, id)
			add_child(guest)
			guest.global_position = point
			_guest_visuals[id] = guest
		_guest_targets[id] = point


func _build_guest(child: bool, id: int) -> Node3D:
	var guest: Node3D = Node3D.new()
	guest.name = "Guest%d" % id
	var height: float = 0.88 if child else 1.40
	var body: CapsuleMesh = CapsuleMesh.new()
	body.height = height
	body.radius = 0.16 if child else 0.22
	var color: Color = Color(0.91, 0.56, 0.26) if child else Color(0.24, 0.55, 0.68)
	_mesh(guest, body, Vector3.UP * (height * 0.5), color)
	var head: SphereMesh = SphereMesh.new()
	head.radius = 0.12 if child else 0.16
	head.height = head.radius * 2.0
	_mesh(guest, head, Vector3.UP * (height + head.radius * 0.55), Color(0.8, 0.58, 0.44))
	return guest


func _apply_boxes(carriers: PackedInt32Array) -> void:
	for peer: int in _box_visuals.keys():
		if not carriers.has(peer):
			_box_visuals[peer].queue_free()
			_box_visuals.erase(peer)
	for peer: int in carriers:
		if not _box_visuals.has(peer) and _player(peer) != null:
			var box: BoxMesh = BoxMesh.new()
			box.size = Vector3(0.47, 0.08, 0.43)
			_box_visuals[peer] = _mesh(self, box, Vector3.ZERO, Color(0.91, 0.68, 0.38))


func _mesh(parent: Node3D, shape: Mesh, point: Vector3, color: Color) -> MeshInstance3D:
	var instance: MeshInstance3D = MeshInstance3D.new()
	var material: StandardMaterial3D = StandardMaterial3D.new()
	material.albedo_color = color
	instance.mesh = shape
	instance.material_override = material
	instance.position = point
	parent.add_child(instance)
	return instance
