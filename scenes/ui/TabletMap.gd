class_name TabletMap
extends Control
## Top-down X/Z survey. Discovery is stored in metre cells, so a scan
## reveals only the sampled portions of room walls that lie inside its radius.

const METRES_ON_SCREEN: float = 46.0
const CELL: float = 1.0
const WALL_STEP: float = 0.48
const WALL_INK: Color = Color(0.32, 0.79, 0.71)
const GRID_INK: Color = Color(0.22, 0.49, 0.46, 0.22)
const MAP_BACKGROUND: Color = Color(0.018, 0.046, 0.052)
const SCRAP_INK: Color = Color(1.0, 0.78, 0.27)
const TRANSPORT_INK: Color = Color(1.0, 0.55, 0.28)

var _level: LevelGenerator
var _crew: Node3D
var _revealed: Dictionary[Vector2i, bool] = {}
var _seed: int = 0
var _focus: Vector2 = Vector2.ZERO
var _survey_origin: Vector2 = Vector2.ZERO
var _last_walk_cell: Vector2i = Vector2i(100000, 100000)
var _survey_until: int = 0
var _transport: Vector2 = Vector2.ZERO
var _ping_until: int = 0
var _scale: float = 1.0


func configure(level: LevelGenerator, crew: Node3D) -> void:
	_level = level
	_crew = crew
	clip_contents = true


func refresh() -> void:
	if _level == null:
		return
	_sync_seed()
	var player: Player = _player(SteamNet.local_peer_id)
	if player != null:
		_focus = _flat(player.global_position)
		var cell: Vector2i = _cell(_focus)
		if cell != _last_walk_cell and not GameState.is_dead(SteamNet.local_peer_id):
			_reveal(_focus, 3.0)
			_last_walk_cell = cell
	queue_redraw()


func receive_scan(point: Vector3, radius: float) -> void:
	_sync_seed()
	_survey_origin = _flat(point)
	_reveal(_survey_origin, radius)
	_survey_until = Time.get_ticks_msec() + 950
	queue_redraw()


func receive_transport_ping(point: Vector3) -> void:
	_sync_seed()
	_transport = _flat(point)
	_ping_until = Time.get_ticks_msec() + 10000
	queue_redraw()


func _sync_seed() -> void:
	if _seed == GameState.map_seed:
		return
	_seed = GameState.map_seed
	_revealed.clear()
	_last_walk_cell = Vector2i(100000, 100000)
	_survey_until = 0
	_ping_until = 0


func _reveal(origin: Vector2, radius: float) -> void:
	var low: Vector2i = _cell(origin - Vector2.ONE * radius)
	var high: Vector2i = _cell(origin + Vector2.ONE * radius)
	for x: int in range(low.x, high.x + 1):
		for y: int in range(low.y, high.y + 1):
			var cell: Vector2i = Vector2i(x, y)
			if origin.distance_squared_to((Vector2(cell) + Vector2(0.5, 0.5)) * CELL) <= radius * radius:
				_revealed[cell] = true


func _draw() -> void:
	if _level == null:
		return
	draw_rect(Rect2(Vector2.ZERO, size), MAP_BACKGROUND)
	_scale = maxf(1.0, minf(size.x, size.y) / METRES_ON_SCREEN)
	_draw_grid()
	if not _level.has_layout(GameState.map_seed):
		return
	var edges: PackedVector3Array = _level.tablet_walls
	for index: int in range(0, edges.size(), 2):
		_draw_wall(_flat(edges[index]), _flat(edges[index + 1]))
	for point: Vector3 in _level.tablet_doors:
		if _revealed.has(_cell(_flat(point))):
			var marker: Vector2 = _project(_flat(point))
			draw_circle(marker, 4.5, MAP_BACKGROUND)
			draw_circle(marker, 2.5, Color(0.76, 0.90, 0.79))
	var now: int = Time.get_ticks_msec()
	if now % 850 < 580:
		for marker: Marker3D in _level.scrap_points():
			var point: Vector2 = _flat(marker.global_position)
			if marker.visible and _revealed.has(_cell(point)):
				_draw_diamond(_project(point), 4.2, SCRAP_INK)
	if now < _survey_until:
		var progress: float = 1.0 - float(_survey_until - now) / 950.0
		draw_arc(_project(_survey_origin), maxf(1.0, 15.0 * _scale * progress), 0.0, TAU,
			48, Color(0.38, 0.95, 0.75, 1.0 - progress), 1.5, true)
	if now < _ping_until:
		var pixel: Vector2 = _project(_transport).clamp(Vector2(13, 13), size - Vector2(13, 13))
		_draw_diamond(pixel, 7.0, TRANSPORT_INK)
	for peer_id: int in GameState.players:
		_draw_player(peer_id)


func _draw_grid() -> void:
	var spacing: float = _scale * 5.0
	var origin: Vector2 = _project(Vector2.ZERO)
	var x: float = fposmod(origin.x, spacing)
	while x < size.x:
		draw_line(Vector2(x, 0.0), Vector2(x, size.y), GRID_INK)
		x += spacing
	var y: float = fposmod(origin.y, spacing)
	while y < size.y:
		draw_line(Vector2(0.0, y), Vector2(size.x, y), GRID_INK)
		y += spacing


func _draw_wall(start: Vector2, end: Vector2) -> void:
	var count: int = maxi(1, ceili(start.distance_to(end) / WALL_STEP))
	for step: int in count:
		var a: Vector2 = start.lerp(end, float(step) / count)
		var b: Vector2 = start.lerp(end, float(step + 1) / count)
		if _revealed.has(_cell((a + b) * 0.5)):
			draw_line(_project(a), _project(b), WALL_INK, 1.65, true)


func _draw_player(peer_id: int) -> void:
	var player: Player = _player(peer_id)
	if player == null or GameState.is_dead(peer_id) or player.health <= 0:
		return
	var point: Vector2 = _project(_flat(player.global_position))
	if peer_id != SteamNet.local_peer_id:
		draw_circle(point, 4.1, Color(0.30, 0.63, 1.0), true, -1.0, true)
		return
	var forward: Vector2 = _flat(-player.global_basis.z).normalized()
	var side: Vector2 = forward.orthogonal()
	draw_colored_polygon(PackedVector2Array([point + forward * 8.0,
		point - forward * 5.0 + side * 5.0, point - forward * 5.0 - side * 5.0]), Color(0.43, 1.0, 0.57))


func _draw_diamond(point: Vector2, radius: float, ink: Color) -> void:
	draw_colored_polygon(PackedVector2Array([point + Vector2(0, -radius), point + Vector2(radius, 0),
		point + Vector2(0, radius), point + Vector2(-radius, 0)]), ink)


func _player(peer_id: int) -> Player:
	return _crew.get_node_or_null("Player%d" % peer_id) as Player


func _project(point: Vector2) -> Vector2:
	return size * 0.5 + (point - _focus) * _scale


func _cell(point: Vector2) -> Vector2i:
	return Vector2i(floori(point.x / CELL), floori(point.y / CELL))


func _flat(point: Vector3) -> Vector2:
	return Vector2(point.x, point.z)

