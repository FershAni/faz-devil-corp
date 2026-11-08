class_name HubInvasion
extends Node3D
## The host advances The Glitch between camera targets. It phases through
## geometry and corrupts the generator unless the crew uses the CAM 05 EMP.

const GENERATOR_CAMERA: String = "5"
const TRAVEL_SPEED: float = 2.4
const ARRIVAL_GRACE: float = 16.0
const NIGHT_LIMIT: float = 78.0

var on_grid: bool = false
var remaining: float = 0.0

var _security: SecurityOffice
var _crew: Node3D
var _figure: MeshInstance3D
var _grid: Vector3
var _position: Vector3
var _goal: Vector3
var _decoy_time: float = 0.0
var _remaining_on_grid: float = 0.0
var _stream_in: float = 0.0
var _active: bool = false
var _resolved: bool = false
var _finish_retry: float = 0.0


func configure(security: SecurityOffice, crew: Node3D) -> void:
	_security = security
	_crew = crew
	_grid = security.camera_target(GENERATOR_CAMERA)
	var capsule: CapsuleMesh = CapsuleMesh.new()
	capsule.radius = 0.36
	capsule.height = 2.05
	_figure = MeshInstance3D.new()
	_figure.mesh = capsule
	_figure.material_override = Look.bulb(Color(0.20, 0.015, 0.29), 0.75)
	_figure.hide()
	add_child(_figure)
	var cabinet: MeshInstance3D = MeshInstance3D.new()
	var box: BoxMesh = BoxMesh.new()
	box.size = Vector3(0.82, 1.15, 0.5)
	cabinet.mesh = box
	cabinet.material_override = Look.bulb(Color(0.10, 0.24, 0.19), 0.4)
	security.add_child(cabinet)
	cabinet.global_position = _grid + Vector3.UP * 0.58
	GameState.noise_reported.connect(_on_crew_noise)


func server_decoy(camera: String) -> void:
	if not GameState.is_host() or not _active or _resolved or on_grid:
		return
	_goal = _security.camera_target(camera)
	_decoy_time = 7.0


func server_emp() -> bool:
	if not GameState.is_host() or not _active or _resolved or not on_grid:
		return false
	_resolve()
	return true


func interference_at(point: Vector3) -> float:
	if not _active or _resolved:
		return 0.0
	return 1.0 - clampf(point.distance_to(_position) / 17.0, 0.0, 1.0)


func _on_crew_noise(level: float, _kind: int, peer_id: int) -> void:
	if not GameState.is_host() or not _active or _resolved or on_grid or level < 58.0:
		return
	var player: Player = _crew.get_node_or_null("Player%d" % peer_id) as Player
	if player != null and _position.distance_squared_to(player.global_position) < 225.0:
		_goal = player.global_position
		_decoy_time = 4.0


func _physics_process(delta: float) -> void:
	if _security == null:
		return
	if GameState.phase != GameState.Phase.HUB_INVASION:
		_active = false
		_figure.hide()
		on_grid = false
		return
	if not GameState.is_host():
		return
	if not _active:
		_active = true
		_resolved = false
		_position = _security.camera_target("6")
		_goal = _grid
		_remaining_on_grid = ARRIVAL_GRACE
		_decoy_time = 0.0
		remaining = NIGHT_LIMIT
		_stream_in = 0.0
		_finish_retry = 0.0
	if _resolved:
		_finish_retry = maxf(0.0, _finish_retry - delta)
		if _finish_retry == 0.0 and not GameState.server_finish_invasion():
			_finish_retry = 2.0
		return
	remaining = maxf(0.0, remaining - delta)
	_decoy_time = maxf(0.0, _decoy_time - delta)
	if _decoy_time == 0.0:
		_goal = _grid
	_position = _position.move_toward(_goal, delta * TRAVEL_SPEED)
	on_grid = _position.distance_squared_to(_grid) < 0.25
	if on_grid:
		_remaining_on_grid -= delta
	if _remaining_on_grid <= 0.0 or remaining == 0.0:
		for peer_id: int in GameState.players:
			GameState.server_player_caught(peer_id)
		_resolve()
		return
	_show_state(_position, on_grid, remaining, true)
	_stream_in -= delta
	if _stream_in <= 0.0:
		_stream_in = 0.2
		_publish_glitch.rpc(_position, on_grid, remaining, true)


func _resolve() -> void:
	_resolved = true
	_finish_retry = 3.0
	_show_state(_position, false, 0.0, false)
	_publish_glitch.rpc(_position, false, 0.0, false)


@rpc("authority", "call_remote", "reliable")
func _publish_glitch(point: Vector3, grid: bool, seconds: float, visible_threat: bool) -> void:
	if not GameState.is_host() and multiplayer.get_remote_sender_id() == 1 \
		and GameState.phase == GameState.Phase.HUB_INVASION:
		_active = true
		_resolved = not visible_threat
		_show_state(point, grid, seconds, visible_threat)


func _show_state(point: Vector3, grid: bool, seconds: float, visible_threat: bool) -> void:
	_position = point
	on_grid = grid
	remaining = seconds
	_figure.global_position = point + Vector3.UP
	_figure.visible = visible_threat

