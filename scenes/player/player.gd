extends CharacterBody3D

## Player - networked CharacterBody3D.
##
## Authority model: each player owns their own body (multiplayer authority == that peer),
## so movement input only ever runs locally. Remote copies are static bodies that render
## replicated state. Noise travels as a client->server RPC because monster AI, the alert
## meter and the quota are server-side.

class_name Player

signal animation_state_changed(state: int)
signal flashlight_changed(on: bool)

enum Mode { STAND, CROUCH }
enum AnimState { IDLE, WALK, RUN, CROUCH, JUMP, LAND, RELOAD, EXHAUSTED }
enum NoiseKind { FOOT_WALK, FOOT_RUN, JUMP, LAND, BATTERY_CLICK, FLASHLIGHT, HEAVY_STEP }

const WALK_SPEED := 2.7
const RUN_SPEED := 4.6
const CROUCH_SPEED := 1.35
const JUMP_VELOCITY := 5.4
const GROUND_ACCELERATION := 42.0
const AIR_ACCELERATION := 6.0

const STAMINA_MAX := 100.0
const SPRINT_DRAIN := 22.0
const STAMINA_REGEN := 17.0
const STAMINA_REGEN_DELAY := 1.1
const EXHAUSTION_RECOVER := 30.0

const BATTERY_MAX := 100.0
const BATTERY_DIM_AT := 35.0
const FLASHLIGHT_DRAIN := 1.7
const RELOAD_TIME := 3.0
const RELOAD_NOISE := 85.0

const STAND_HEIGHT := 1.75
const CROUCH_HEIGHT := 1.05
const HEAD_STAND_Y := 1.6
const HEAD_CROUCH_Y := 0.9
const INTERACTION_HAND := preload("res://scenes/player/interaction_hand.gd")

## Loudness in arbitrary units; a hunter's hearing radius scales with this.
const NOISE_LEVELS := {
	NoiseKind.FOOT_WALK: 8.0,
	NoiseKind.FOOT_RUN: 34.0,
	NoiseKind.JUMP: 45.0,
	NoiseKind.LAND: 30.0,
	NoiseKind.BATTERY_CLICK: RELOAD_NOISE,
	NoiseKind.FLASHLIGHT: 9.0,
	NoiseKind.HEAVY_STEP: 24.0,
}

@export var display_name := "Рабочий"
@export var animation_tree: AnimationTree

## Replicated: the crew sees a crouched, torch-lit teammate even when they join late.
var mode: int = Mode.STAND
var animation_state: int = AnimState.IDLE
var flashlight_on := false
var carry_heavy := false
var battery_display := BATTERY_MAX
## The server reads this to decide who is dragging what; only the owning peer writes it.
var interact_held := false
## Replicated vitals for the tablet: integers so a slow drain is one packet per point.
var health := 100
var sanity := 100
## Harness hook: headless cannot capture the mouse, so the smoke rig drives E through this
## instead of Input. -1 means "read the real key".
var interact_override := -1

## Local-only simulation.
var battery := BATTERY_MAX
var stamina := STAMINA_MAX
var exhausted := false
var running := false
var viewing_security := false
var daytime_repairing: bool = false
var _buff_phase: int = -1

var _is_authority := false
var _was_dead := false
var _return_home := 0
var _last_spawn := Vector3.ZERO
var _spectate: Player
var _sanity_f := 100.0
var _reloading := 0.0
var _regen_delay := 0.0
var _footstep_distance := 0.0
var _airborne := false
var _fall_speed := 0.0
var _crouch_amount := 0.0
var _seen_animation := -1
var _buffs := {
	"stamina_multiplier": 1.0,
	"battery_drain_multiplier": 1.0,
	"noise_multiplier": 1.0,
}
var _head: Node3D
var _visual: Node3D
var _camera: Camera3D
var _flashlight: SpotLight3D
var _collision: CollisionShape3D
var _capsule: CapsuleShape3D
var _interaction_hand: INTERACTION_HAND


func _enter_tree() -> void:
	_setup_replication(get_node_or_null("Sync") as MultiplayerSynchronizer)


@onready var _night_level: LevelGenerator = get_node_or_null("../../Level") as LevelGenerator
@onready var _pizzeria: Pizzeria = get_node_or_null("../../Pizzeria") as Pizzeria


func _ready() -> void:
	_is_authority = is_multiplayer_authority()
	_head = get_node("Head")
	_visual = get_node("Visual")
	_camera = get_node("Head/Camera")
	_flashlight = get_node("Head/Camera/Flashlight")
	Look.beam(_flashlight)
	_build_dust()
	_collision = get_node("Collision")
	# The scene's CapsuleShape3D is shared by every instance, so crouching must not resize
	# everyone else's collider.
	_capsule = _collision.shape.duplicate() as CapsuleShape3D
	_collision.shape = _capsule
	_flashlight.visible = false
	_is_authority = is_multiplayer_authority()
	_apply_authority()
	GameState.player_wallet_updated.connect(_on_wallet_spawn)


## The spawner can assign authority after _ready on a joining peer, so the flag is refreshed
## every physics tick and the visuals follow the flip instead of being cached once.
func _apply_authority() -> void:
	if _is_authority:
		display_name = String(SteamNet.meta_of(get_multiplayer_authority()).get("name", display_name))
		_buffs = GameState.cozy_buffs()
		_buff_phase = GameState.phase
		stamina = STAMINA_MAX * float(_buffs.get("stamina_multiplier", 1.0))
		# First person must not render the inside of its own body box.
		_visual.visible = false
		# 4.7 dropped Camera3D.enabled: the camera is live when it is the current one.
		_camera.current = true
		GameplayPointer.set_mode(Input.MOUSE_MODE_CAPTURED)
	else:
		# Remote copies never call move_and_slide, so they only render replicated state and
		# never fight it with local simulation.
		collision_mask = 1
		_camera.current = false


## ---------------- replication config ----------------

func _setup_replication(sync: MultiplayerSynchronizer) -> void:
	if sync == null or sync.replication_config != null:
		return
	var cfg := SceneReplicationConfig.new()
	# A leading colon means "a property of root_path itself"; "Head:rotation:x" addresses a
	# descendant node. Writing bare "position" is parsed as a node name and silently fails.
	_add(cfg, NodePath(":position"), SceneReplicationConfig.REPLICATION_MODE_ALWAYS)
	_add(cfg, NodePath(":rotation:y"), SceneReplicationConfig.REPLICATION_MODE_ALWAYS)
	_add(cfg, NodePath("Head:rotation:x"), SceneReplicationConfig.REPLICATION_MODE_ALWAYS)
	_add(cfg, NodePath("Head:rotation:y"), SceneReplicationConfig.REPLICATION_MODE_ALWAYS)
	# Discrete state: reliable, only on change, and pushed once on spawn.
	for discrete in [
		NodePath(":display_name"), NodePath(":mode"), NodePath(":animation_state"),
		NodePath(":flashlight_on"), NodePath(":carry_heavy"), NodePath(":battery_display"),
		NodePath(":interact_held"), NodePath(":health"), NodePath(":sanity"),
		NodePath(":viewing_security"), NodePath(":daytime_repairing"),
	]:
		_add(cfg, discrete, SceneReplicationConfig.REPLICATION_MODE_ON_CHANGE, true)
	sync.replication_config = cfg
	sync.root_path = NodePath("..")
	sync.visibility_update_mode = MultiplayerSynchronizer.VISIBILITY_PROCESS_PHYSICS


func _add(cfg: SceneReplicationConfig, path: NodePath, repl_mode: int, on_spawn := false) -> void:
	if cfg.has_property(path):
		return
	cfg.add_property(path)
	cfg.property_set_replication_mode(path, repl_mode)
	cfg.property_set_spawn(path, on_spawn)


## ---------------- input ----------------

func _unhandled_input(event: InputEvent) -> void:
	if not _is_authority or viewing_security:
		return
	if _was_dead:
		# Spectating: the mouse buttons walk through the living, the camera follows on its own.
		if event is InputEventMouseButton and event.pressed:
			if event.button_index == MOUSE_BUTTON_LEFT:
				_cycle_spectate(1)
			elif event.button_index == MOUSE_BUTTON_RIGHT:
				_cycle_spectate(-1)
		return
	if event is InputEventMouseMotion and GameplayPointer.get_mode() == Input.MOUSE_MODE_CAPTURED:
		rotate_y(-event.relative.x * 0.0022)
		_head.rotate_x(-event.relative.y * 0.0022)
		_head.rotation.x = clampf(_head.rotation.x, -deg_to_rad(88.0), deg_to_rad(76.0))
	elif GameState.is_dead(get_multiplayer_authority()):
		return
	elif event.is_action_pressed("toggle_flashlight"):
		toggle_flashlight()
	elif event.is_action_pressed("crouch"):
		set_mode(Mode.CROUCH if mode == Mode.STAND else Mode.STAND)
	elif event.is_action_pressed("reload_battery"):
		start_reload()


## Dust that only exists where the light is: shaded motes in a slow drift turn an empty
## corridor into air, and they are the cheapest way to make a flashlight beam feel solid.
## Only the owner of the body carries the system, so a four-player night costs one emitter.
func _build_dust() -> void:
	var dust := GPUParticles3D.new()
	dust.name = "Dust"
	dust.amount = 240
	dust.lifetime = 9.0
	dust.preprocess = 9.0
	dust.local_coords = false
	dust.visibility_aabb = AABB(Vector3(-12.0, -1.0, -12.0), Vector3(24.0, 6.0, 24.0))
	var process := ParticleProcessMaterial.new()
	process.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	process.emission_box_extents = Vector3(7.0, 1.4, 7.0)
	process.direction = Vector3(0.0, -0.15, 0.0)
	process.spread = 90.0
	process.initial_velocity_min = 0.02
	process.initial_velocity_max = 0.12
	process.gravity = Vector3(0.0, -0.008, 0.0)
	process.scale_min = 0.012
	process.scale_max = 0.032
	dust.process_material = process
	var mesh := QuadMesh.new()
	mesh.size = Vector2(0.02, 0.02)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.92, 0.88, 0.8, 1.0)
	mat.roughness = 1.0
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mesh.material = mat
	dust.draw_pass_1 = mesh
	add_child(dust)


func _physics_process(delta: float) -> void:
	var authority := is_multiplayer_authority()
	if authority != _is_authority:
		_is_authority = authority
		_apply_authority()
	if not _is_authority:
		_render_remote_state()
		return
	if _buff_phase != GameState.phase:
		_buff_phase = GameState.phase
		_buffs = GameState.cozy_buffs()
		stamina = minf(stamina, STAMINA_MAX * float(_buffs.get("stamina_multiplier", 1.0)))
	if _tick_life():
		_tick_spectate()
		return
	# A joining client can receive its wallet before the room collision snapshot.
	if GameState.is_play_phase() and _night_level != null and not _night_level.has_layout(GameState.map_seed):
		interact_held = false
		return
	interact_held = interact_override == 1 if interact_override >= 0 else (
		Input.is_action_pressed("interact")
		and (GameplayPointer.get_mode() == Input.MOUSE_MODE_CAPTURED or viewing_security))
	var input := _read_input()
	_apply_gravity(delta)
	_apply_horizontal(input, delta)
	_apply_jump(input)
	move_and_slide()
	_update_stamina(delta, input)
	_update_flashlight(delta)
	_update_vitals(delta)
	_update_reload(delta)
	_track_flight()
	_tick_footsteps()
	battery_display = floorf(battery / 5.0) * 5.0


func _read_input() -> Dictionary:
	# An uncaptured mouse means a local overlay (pause, settings, tablet) owns the screen.
	# The world keeps simulating for everyone else; only this player stops taking input.
	var captured := GameplayPointer.get_mode() == Input.MOUSE_MODE_CAPTURED and GameState.is_world_phase() \
		and not viewing_security and not daytime_repairing
	var direction := Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	if not captured:
		direction = Vector2.ZERO
	return {
		"direction": direction,
		"jump": captured and Input.is_action_just_pressed("jump"),
		"run": captured and Input.is_action_pressed("sprint"),
	}


func interaction_origin() -> Vector3:
	return _camera.global_position


func interaction_direction() -> Vector3:
	return -_camera.global_basis.z


func animate_interaction(target: Vector3, grip := false) -> void:
	if not _camera.is_position_in_frustum(target):
		return
	if _interaction_hand == null:
		_interaction_hand = INTERACTION_HAND.new()
		_camera.add_child(_interaction_hand)
	_interaction_hand.reach_for(target, grip)


## Life and death are server state in the wallet, so the body only reacts to the flip.
## Down = the corpse object takes over the view and this body stops simulating; there is no
## countdown. Flying off bumps return_home, which is the only teleport back to the slot.
## Returns true while dead so the rest of the simulation is skipped entirely.
func _tick_life() -> bool:
	var peer_id := get_multiplayer_authority()
	var wallet := GameState.wallet(peer_id)
	# The server rewrites spawn_pos on every hub<->night crossing; following the value rather
	# than a counter survives RPCs arriving in any order between the two wallet writes.
	_check_spawn()
	var home := int(wallet.get("return_home", 0))
	if home != _return_home:
		_return_home = home
		_check_spawn()
		stamina = STAMINA_MAX * float(_buffs.get("stamina_multiplier", 1.0))
		exhausted = false
		set_mode(Mode.STAND)
	var dead := bool(wallet.get("dead", false))
	if dead != _was_dead:
		_was_dead = dead
		velocity = Vector3.ZERO
		_camera.current = not dead
		if dead:
			flashlight_on = false
			_flashlight.visible = false
			_spectate = null
			_set_animation(AnimState.IDLE)
	carry_heavy = int(wallet.get("scrap_value", 0)) > 0
	if not dead:
		return false
	velocity = Vector3.ZERO
	return true


## Teleport when the server moves our slot. Also driven by the wallet signal so a crossing
## lands even on a frame where this body's physics tick did not run.
func _check_spawn() -> void:
	var spawn: Vector3 = GameState.wallet(get_multiplayer_authority()).get("spawn_pos", Vector3.ZERO)
	if spawn == _last_spawn:
		return
	_last_spawn = spawn
	global_position = spawn
	velocity = Vector3.ZERO
	# Check the slot itself so the office view works even before the phase arrives on a client.
	if is_multiplayer_authority() and _pizzeria != null and _pizzeria.hub_spawns().has(spawn):
		var desk := _pizzeria.office_desk_pos()
		desk.y = spawn.y
		look_at(desk)
		_head.rotation.x = 0.0


func _on_wallet_spawn(peer_id: int, _balance: int) -> void:
	if peer_id == get_multiplayer_authority():
		_check_spawn()


func _corpse_camera() -> Camera3D:
	for node in get_tree().get_nodes_in_group(&"corpses"):
		if int(node.get("owner_peer")) == get_multiplayer_authority():
			return node.get_node_or_null("Camera") as Camera3D
	return null


## Dead eyes ride along with the living: third person over the shoulder of whoever is
## selected, mouse buttons cycle the crew. With nobody left alive the view stays at the body.
func _tick_spectate() -> void:
	var cam := _corpse_camera()
	if cam == null:
		return
	var living := _living_players()
	if living.is_empty():
		return
	if _spectate == null or not is_instance_valid(_spectate) or not living.has(_spectate):
		_spectate = living[0]
	var offset: Vector3 = _spectate.global_transform.basis * Vector3(0.0, 1.9, 3.2)
	cam.global_position = _spectate.global_position + offset
	cam.look_at(_spectate.global_position + Vector3(0.0, 1.4, 0.0), Vector3.UP)


func _cycle_spectate(direction: int) -> void:
	var living := _living_players()
	if living.is_empty():
		return
	var at := living.find(_spectate)
	_spectate = living[posmod(at + direction, living.size())]
	SteamNet.note("[spectate] peer=%d смотрит за %s" % [
		get_multiplayer_authority(), String(_spectate.name)])


func _living_players() -> Array:
	var out: Array = []
	for node in get_tree().get_nodes_in_group(&"players"):
		var player := node as Player
		if player == null or player == self:
			continue
		if not GameState.is_dead(int(player.get_multiplayer_authority())):
			out.append(player)
	return out


func _apply_gravity(delta: float) -> void:
	if not is_on_floor():
		velocity.y -= absf(get_gravity().y) * delta


func _apply_horizontal(input: Dictionary, delta: float) -> void:
	var wish := _wish_direction(input["direction"])
	var speed := _target_speed(input)
	if wish.length_squared() > 0.0 and speed > 0.0:
		wish = wish.normalized() * speed
	var accel := GROUND_ACCELERATION if is_on_floor() else AIR_ACCELERATION
	velocity.x = move_toward(velocity.x, wish.x, accel * delta)
	velocity.z = move_toward(velocity.z, wish.z, accel * delta)


## W/S/A/D are camera-relative. Feeding the raw input vector into world axes makes "forward"
## mean whatever -Z happens to point at, so turning the mouse turned walking into strafing.
## Only yaw counts: a pitched camera would shorten the step every time you look down.
func _wish_direction(direction: Vector2) -> Vector3:
	var forward := -_camera.global_transform.basis.z
	forward.y = 0.0
	if forward.length_squared() < 0.0001:
		forward = -global_transform.basis.z
		forward.y = 0.0
	var right := _camera.global_transform.basis.x
	right.y = 0.0
	if right.length_squared() < 0.0001:
		right = global_transform.basis.x
		right.y = 0.0
	return forward.normalized() * (-direction.y) + right.normalized() * direction.x


func _target_speed(input: Dictionary) -> float:
	if mode == Mode.CROUCH:
		return CROUCH_SPEED
	if input["run"] and not exhausted and stamina > 0.0 and _reloading <= 0.0:
		return RUN_SPEED
	return WALK_SPEED * (0.6 if carry_heavy else 1.0)


func _apply_jump(input: Dictionary) -> void:
	if not input["jump"] or not is_on_floor() or _reloading > 0.0:
		return
	velocity.y = JUMP_VELOCITY * (0.55 if mode == Mode.CROUCH else 1.0)
	set_mode(Mode.STAND)
	_set_animation(AnimState.JUMP)
	make_noise(NoiseKind.JUMP)


## ---------------- stamina, crouch, flashlight ----------------

func _update_stamina(delta: float, input: Dictionary) -> void:
	var max_stamina := STAMINA_MAX * float(_buffs.get("stamina_multiplier", 1.0))
	var moving := Vector2(input["direction"]).length() > 0.1
	# The HUD reads this: the bar should show while running and while catching breath.
	running = bool(input["run"]) and mode == Mode.STAND and moving and not exhausted
	if running:
		stamina = maxf(stamina - SPRINT_DRAIN * delta, 0.0)
		_regen_delay = STAMINA_REGEN_DELAY
		_set_animation(AnimState.RUN)
	else:
		_regen_delay = maxf(_regen_delay - delta, 0.0)
		if _regen_delay <= 0.0 and stamina < max_stamina:
			stamina = minf(stamina + STAMINA_REGEN * delta, max_stamina)
	if stamina <= 0.0 and not exhausted:
		exhausted = true
		_set_animation(AnimState.EXHAUSTED)
	elif exhausted and stamina >= max_stamina * (EXHAUSTION_RECOVER / STAMINA_MAX):
		exhausted = false
	if not running and mode == Mode.STAND:
		_set_animation(AnimState.WALK if moving and is_on_floor() else AnimState.IDLE)


## 0..1 of the current cap, so the HUD does not need to know about cozy buffs or exhaustion
## thresholds. Remote copies never drive the bar, so this stays a local number.
func stamina_fraction() -> float:
	var max_stamina := STAMINA_MAX * float(_buffs.get("stamina_multiplier", 1.0))
	if max_stamina <= 0.0:
		return 0.0
	return clampf(stamina / max_stamina, 0.0, 1.0)


## Darkness and a hunting monster eat sanity; a lit torch gives it back. Health is a whole
## body until something damages it - the hunter's touch takes it all at once.
func _update_vitals(delta: float) -> void:
	if _was_dead:
		health = 0
		return
	health = 100
	var rate := 2.0
	if GameState.is_play_phase():
		rate = 1.0 if flashlight_on else -1.5
		# One hunter per night: first_node avoids allocating a group array every tick.
		var hunter := get_tree().get_first_node_in_group("hunters") as BlindHunter
		if hunter != null and hunter.state == BlindHunter.State.HUNT \
			and hunter.global_position.distance_to(global_position) < 10.0:
			rate -= 4.0
	_sanity_f = clampf(_sanity_f + rate * delta, 0.0, 100.0)
	sanity = int(roundf(_sanity_f))


func set_mode(new_mode: int) -> void:
	if mode == new_mode:
		return
	mode = new_mode
	_set_animation(AnimState.CROUCH if mode == Mode.CROUCH else AnimState.IDLE)


func _update_crouch(delta: float) -> void:
	var target := 1.0 if mode == Mode.STAND else 0.0
	_crouch_amount = lerpf(_crouch_amount, target, minf(delta * 12.0, 1.0))
	var height := lerpf(CROUCH_HEIGHT, STAND_HEIGHT, _crouch_amount)
	_capsule.height = height
	# 4.7's CapsuleShape3D has no `origin`: the capsule is centered on its node, so the
	# collider node is what gets lifted.
	_collision.position.y = height * 0.5
	_head.position.y = lerpf(HEAD_CROUCH_Y, HEAD_STAND_Y, _crouch_amount)
	_visual.scale.y = lerpf(0.62, 1.0, _crouch_amount)


func toggle_flashlight() -> void:
	if not flashlight_on and battery <= 0.0:
		return
	flashlight_on = not flashlight_on
	_flashlight.visible = flashlight_on
	flashlight_changed.emit(flashlight_on)
	make_noise(NoiseKind.FLASHLIGHT)


func _update_flashlight(delta: float) -> void:
	_update_crouch(delta)
	if not flashlight_on:
		_flashlight.light_energy = 0.0
		return
	battery = maxf(battery - FLASHLIGHT_DRAIN * float(_buffs.get("battery_drain_multiplier", 1.0)) * delta, 0.0)
	# The beam fades before it dies: pressure without a hard cliff.
	var fade := clampf(battery / BATTERY_DIM_AT, 0.0, 1.0)
	_flashlight.light_energy = lerpf(0.6, 3.4, fade) * lerpf(0.65, 1.0, fade)
	if battery <= 0.0 and flashlight_on:
		toggle_flashlight()


func start_reload() -> void:
	if _reloading > 0.0 or battery >= BATTERY_MAX:
		return
	_reloading = RELOAD_TIME
	_set_animation(AnimState.RELOAD)


func _update_reload(delta: float) -> void:
	if _reloading <= 0.0:
		return
	_reloading = maxf(_reloading - delta, 0.0)
	if _reloading > 0.0:
		return
	battery = BATTERY_MAX
	_set_animation(AnimState.IDLE)
	# The mechanical click of a battery swap is a tell: hunters hear it across a sector.
	make_noise(NoiseKind.BATTERY_CLICK)


## ---------------- noise pipeline ----------------

func make_noise(kind: int) -> void:
	var level := float(NOISE_LEVELS.get(kind, 10.0))
	level *= float(_buffs.get("noise_multiplier", 1.0))
	if mode == Mode.CROUCH:
		level *= 0.15
	if carry_heavy:
		level *= 1.4
	_report_noise(level, kind)


## The host registers directly; a client's copy is the only peer allowed to speak for it,
## so the RPC lands on the server copy and is validated by sender id.
func _report_noise(level: float, kind: int) -> void:
	if not SteamNet.available() or get_multiplayer_authority() == 1:
		_register_noise(level, kind)
	elif is_multiplayer_authority():
		_rpc_noise.rpc_id(1, level, kind)


@rpc("any_peer", "call_remote", "unreliable")
func _rpc_noise(level: float, kind: int) -> void:
	if multiplayer.get_remote_sender_id() != get_multiplayer_authority():
		return
	_register_noise(level, kind)


func _register_noise(level: float, kind: int) -> void:
	GameState.server_register_noise(level, kind, get_multiplayer_authority())
	print("[noise] peer=%d kind=%d level=%.1f" % [get_multiplayer_authority(), kind, level])


## ---------------- movement bookkeeping ----------------

func _track_flight() -> void:
	if not is_on_floor() and velocity.y < -1.0 and not _airborne:
		_airborne = true
		_fall_speed = absf(velocity.y)
	elif is_on_floor() and _airborne:
		_airborne = false
		if _fall_speed > 3.0:
			make_noise(NoiseKind.LAND)
		_fall_speed = 0.0


func _tick_footsteps() -> void:
	if not is_on_floor() or mode == Mode.CROUCH:
		return
	var planar := Vector2(velocity.x, velocity.z)
	if planar.length() < 0.5:
		return
	_footstep_distance += planar.length() * get_physics_process_delta_time()
	var running := planar.length() > 3.6
	if _footstep_distance >= (1.8 if running else 2.4):
		_footstep_distance = 0.0
		make_noise(NoiseKind.FOOT_RUN if running else NoiseKind.FOOT_WALK)
		if carry_heavy:
			make_noise(NoiseKind.HEAVY_STEP)


## Replicated properties are written by the synchronizer without calling setters, so remote
## copies re-derive their visuals from those values every physics tick.
func _render_remote_state() -> void:
	# A caught teammate is gone from the floor until the hub takes them back.
	_visual.visible = not GameState.is_dead(get_multiplayer_authority())
	_flashlight.visible = flashlight_on and not GameState.is_dead(get_multiplayer_authority())
	_flashlight.light_energy = 3.4 if flashlight_on else 0.0
	var crouched := mode == Mode.CROUCH
	var height := CROUCH_HEIGHT if crouched else STAND_HEIGHT
	_visual.scale.y = CROUCH_HEIGHT / STAND_HEIGHT if crouched else 1.0
	_head.position.y = HEAD_CROUCH_Y if crouched else HEAD_STAND_Y
	# Remote colliders follow the replicated stance so hitboxes match what everyone sees.
	_capsule.height = height
	_collision.position.y = height * 0.5
	if animation_state != _seen_animation:
		_seen_animation = animation_state
		animation_state_changed.emit(animation_state)


func _set_animation(state: int) -> void:
	if animation_state == state:
		return
	animation_state = state
	if animation_tree != null:
		animation_tree.active = true
	animation_state_changed.emit(state)


## Placeholder for 3D proximity voice: sample the mic level here and let the server mix it
## into the noise budget, so shouting draws the Blind Hunter. Swap in a Steam/Vivox voice tap.
func _voice_capture_level() -> float:
	return 0.0
