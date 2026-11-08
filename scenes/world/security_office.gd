class_name SecurityOffice
extends Node3D

const CAMERA_CONTROL := 6
const DAYTIME_CONTROL: int = 7
const DEFAULT_CAMERA := "1B"
const REACH := 2.35
const CONTROL_LAYER := 1 << 5
const SHUTTER_FOR_CONTROL := [0, 0, 1, 1, 0, 1]
const INK := Color(0.63, 0.89, 0.79)
const OPEN_COLOR := Color(0.29, 0.85, 0.56)
const MOVING_COLOR := Color(1.0, 0.62, 0.23)
const CLOSED_COLOR := Color(1.0, 0.27, 0.17)
const SHUTTER_TRAVEL_TIME := 0.82

var _shutters: Array[AnimatableBody3D] = []
var _shutter_motion: Array[Tween] = [null, null]
var _controls: Array[Area3D] = []
var _buttons: Array[MeshInstance3D] = []
var _button_motion: Array[Tween] = []
var _lights: Array[StandardMaterial3D] = []
var _status: Array[Label3D] = []
var _shutter_mask := -1
var _door_height: float
var _doorway: Vector2
var _metal: Material
var _trim: Material
var _dining_camera: Node3D
var _camera_lenses: Dictionary[String, MeshInstance3D] = {}
var _camera_locations: Dictionary[String, String] = {}
var _camera_targets: Dictionary[String, Vector3] = {}
var _selected_camera := DEFAULT_CAMERA
var _camera: Camera3D
var _feed: SubViewport
var _video: StandardMaterial3D
var _video_motion: Tween
var _recording: Label3D
var _feed_on := false
var _feed_clock := 0.0
var _sweep_clock := 0.0


func build(wall_x: float, doorway: Vector2, height: float, desk: Vector3,
		metal: Material, trim: Material) -> void:
	_door_height = height
	_doorway = doorway
	_metal = metal
	_trim = trim
	for side in [-1.0, 1.0]:
		var index := _shutters.size()
		_build_shutter(wall_x * side, index)
		for face in [1.0, -1.0]:
			var normal: float = -side * face
			var at := Vector3(wall_x * side + normal * 0.19, 1.32, doorway.x - 0.33)
			_build_button(at, normal * PI / 2.0, Vector3(0.27, 0.36, 0.16), _lights[index])
	_build_terminals(desk)
	_build_dining_camera()
	apply_shutters(0, true)
	set_process(false)


func _build_shutter(x: float, index: int) -> void:
	var center := (_doorway.x + _doorway.y) * 0.5
	var width := _doorway.y - _doorway.x - 0.09
	var slab := AnimatableBody3D.new()
	slab.name = "WestShutter" if index == 0 else "EastShutter"
	slab.position = Vector3(x, _height_for(false), center)
	slab.collision_mask = 0
	add_child(slab)
	_shutters.append(slab)
	var size := Vector3(0.17, _door_height - 0.025, width)
	var shape := BoxShape3D.new()
	shape.size = size
	var collider := CollisionShape3D.new()
	collider.shape = shape
	slab.add_child(collider)
	_box(slab, "Slab", size, Vector3.ZERO, _metal)
	var slat := Surfaces.panel_material(Color(0.25, 0.29, 0.31), 0.14)
	for row in 10:
		var y := -size.y * 0.5 + 0.14 + row * (size.y - 0.19) / 10.0
		_box(slab, "Slat", Vector3(0.21, 0.075, width), Vector3(0.0, y, 0.0), slat)
	_box(slab, "SafetyEdge", Vector3(0.24, 0.11, width), Vector3(0.0, -size.y * 0.5 + 0.06, 0.0), _trim)
	var lamp := Look.bulb(OPEN_COLOR, 1.25)
	_lights.append(lamp)


func _build_terminals(desk: Vector3) -> void:
	var left := desk + Vector3(-0.66, 1.0, -0.09)
	var right := desk + Vector3(0.66, 1.0, -0.09)
	for base in [left, right]:
		_box(self, "MonitorFoot", Vector3(0.69, 0.095, 0.44), base, _metal)
		_box(self, "CRT", Vector3(1.12, 0.69, 0.44), base + Vector3(0.0, 0.39, 0.0), _metal)
		_box(self, "Bezel", Vector3(1.04, 0.61, 0.05), base + Vector3(0.0, 0.405, 0.23), _metal)
	var glass := Look.bulb(Color(0.035, 0.10, 0.085), 0.7)
	_box(self, "DoorStatusGlass", Vector3(0.91, 0.49, 0.02), left + Vector3(0.0, 0.405, 0.26), glass)
	_label("FAZ / КОНТРОЛЬ ДВЕРЕЙ", left + Vector3(0.0, 0.575, 0.275), 0.00069)
	for index in 2:
		var y := 0.44 - index * 0.14
		_status.append(_label("", left + Vector3(0.0, y, 0.275), 0.00083))
		var x := -0.27 + index * 0.54
		_build_button(left + Vector3(x, 0.045, 0.42), 0.0, Vector3(0.25, 0.14, 0.17), _lights[index])
		_label("ЗАПАД" if index == 0 else "ВОСТОК", left + Vector3(x, 0.16, 0.505), 0.00053)
	_feed = SubViewport.new()
	_feed.name = "CCTVFeed"
	_feed.size = Vector2i(512, 288)
	_feed.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(_feed)
	_camera = Camera3D.new()
	_camera.fov = 78.0
	_camera.far = 50.0
	_camera.cull_mask = 1
	_feed.add_child(_camera)
	_camera.current = true
	var screen := MeshInstance3D.new()
	screen.name = "CCTVGlass"
	# The feed camera must never sample its own texture through the desk monitor.
	screen.layers = 2
	var quad := QuadMesh.new()
	quad.size = Vector2(0.86, 0.484)
	screen.mesh = quad
	_video = StandardMaterial3D.new()
	_video.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_video.albedo_texture = _feed.get_texture()
	_video.albedo_color = Color.BLACK
	screen.material_override = _video
	screen.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	screen.position = right + Vector3(0.0, 0.405, 0.274)
	add_child(screen)
	_recording = _label("●  CAM " + DEFAULT_CAMERA, right + Vector3(-0.29, 0.61, 0.278), 0.00052)
	_recording.modulate = Color(1.0, 0.51, 0.36)
	_recording.hide()
	_label("ВИДЕОНАБЛЮДЕНИЕ", right + Vector3(0.0, 0.16, 0.506), 0.00062)
	_build_button(right + Vector3(0.0, 0.045, 0.42), 0.0, Vector3(0.42, 0.14, 0.17),
		Look.bulb(INK, 1.0), Vector3(0.98, 0.66, 0.18), Vector3(0.0, 0.32, -0.24))
	var terminal: Vector3 = desk + Vector3(0.0, 1.04, 0.50)
	_build_button(terminal, 0.0, Vector3(0.24, 0.14, 0.17), Look.bulb(OPEN_COLOR, 1.0))
	_label("УПРАВЛЕНИЕ ПИЦЦЕРИЕЙ", terminal + Vector3(0.0, 0.16, 0.10), 0.00055)


func _build_dining_camera() -> void:
	var at := Vector3(0.0, 3.03, 4.61)
	_box(self, "CameraMount", Vector3(0.21, 0.14, 0.44), at + Vector3(0.0, 0.17, 0.15), _metal)
	_dining_camera = _build_camera_head(DEFAULT_CAMERA, "Обеденный зал", at, "DiningCamera")
	_dining_camera.rotation_degrees.x = -14.0
	_camera_targets[DEFAULT_CAMERA] = Vector3(0.0, 0.0, -2.5)


func add_camera(id: String, location: String, at: Vector3, target: Vector3) -> void:
	_box(self, "CameraMount" + id, Vector3(0.18, 0.4, 0.18), at + Vector3(0.0, 0.21, 0.0), _metal)
	var head := _build_camera_head(id, location, at, "Camera" + id)
	head.look_at(to_global(target))
	_camera_targets[id] = Vector3(target.x, 0.0, target.z)


func _build_camera_head(id: String, location: String, at: Vector3, node_name: String) -> Node3D:
	var head := Node3D.new()
	head.name = node_name
	head.position = at
	add_child(head)
	_box(head, "CameraHousing", Vector3(0.34, 0.22, 0.42), Vector3.ZERO, _metal)
	_box(head, "CameraVisor", Vector3(0.38, 0.04, 0.46), Vector3(0.0, 0.115, -0.04), _trim)
	_camera_lenses[id] = _box(head, "Lens", Vector3(0.17, 0.13, 0.08), Vector3(0.0, 0.0, -0.23),
		Look.bulb(Color(0.07, 0.16, 0.18), 0.55))
	_box(head, "RecordingLED", Vector3(0.042, 0.04, 0.04), Vector3(0.122, 0.0, -0.222),
		Look.bulb(Color(1.0, 0.2, 0.12), 1.3))
	_camera_locations[id] = location
	return head


func _build_button(at: Vector3, yaw: float, size: Vector3, lamp: Material,
		hit_size := Vector3.ZERO, hit_offset := Vector3.ZERO) -> void:
	var area := Area3D.new()
	area.name = "SecurityControl%d" % _controls.size()
	area.position = at
	area.rotation.y = yaw
	area.monitorable = false
	area.monitoring = false
	area.collision_layer = CONTROL_LAYER
	area.collision_mask = 0
	add_child(area)
	var shape := BoxShape3D.new()
	shape.size = size + Vector3(0.08, 0.08, 0.04) if hit_size == Vector3.ZERO else hit_size
	var collider := CollisionShape3D.new()
	collider.position = hit_offset
	collider.shape = shape
	area.add_child(collider)
	if hit_size != Vector3.ZERO:
		var key := BoxShape3D.new()
		key.size = size + Vector3(0.08, 0.08, 0.04)
		var key_shape := CollisionShape3D.new()
		key_shape.shape = key
		area.add_child(key_shape)
	_box(area, "ButtonCase", size, Vector3.ZERO, _metal)
	var face := _box(area, "ButtonFace", Vector3(size.x * 0.64, size.y * 0.52, 0.05),
		Vector3(0.0, 0.0, size.z * 0.5), lamp)
	_controls.append(area)
	_buttons.append(face)
	_button_motion.append(null)


func _process(delta: float) -> void:
	_sweep_clock += delta
	_dining_camera.rotation_degrees.y = sin(_sweep_clock * 0.48) * 25.0
	_recording.visible = _feed_on and fmod(_sweep_clock, 1.3) < 1.0
	if not _feed_on:
		return
	_feed_clock -= delta
	if _feed_clock <= 0.0:
		_feed_clock = 1.0 / 15.0
		_camera.global_transform = _camera_lenses[_selected_camera].global_transform
		_camera.position -= _camera.basis.z * 0.08
		_feed.render_target_update_mode = SubViewport.UPDATE_ONCE


func set_feed_active(active: bool) -> void:
	if _feed_on == active:
		return
	_feed_on = active
	_feed_clock = 0.0
	if _video_motion != null:
		_video_motion.kill()
	var tint := Color(0.73, 0.90, 0.80) if active else Color.BLACK
	_video_motion = create_tween()
	_video_motion.tween_property(_video, "albedo_color", tint, 0.25)
	if not active:
		_feed.render_target_update_mode = SubViewport.UPDATE_DISABLED


func feed_texture() -> Texture2D:
	return _feed.get_texture()


func camera_ids() -> Array[String]:
	var ids := _camera_locations.keys()
	ids.sort()
	return ids


func camera_location(id: String) -> String:
	return _camera_locations[id]


func camera_target(id: String) -> Vector3:
	return to_global(_camera_targets[id])


func select_camera(id: String) -> void:
	_selected_camera = id
	_recording.text = "●  CAM " + id
	_feed_clock = 0.0


func control_in_sight(eye: Vector3, direction: Vector3) -> int:
	var ray := PhysicsRayQueryParameters3D.create(eye, eye + direction * REACH, 1 | CONTROL_LAYER)
	ray.collide_with_areas = true
	var hit := get_world_3d().direct_space_state.intersect_ray(ray)
	var area := hit.get("collider") as Area3D
	return _controls.find(area) if area != null else -1


func can_reach_control(eye: Vector3, control: int) -> bool:
	if control < 0 or control >= _controls.size():
		return false
	var offset := control_position(control) - eye
	return offset.length() <= REACH and control_in_sight(eye, offset.normalized()) == control


func control_position(control: int) -> Vector3:
	return _buttons[control].global_position


func control_hint(control: int) -> String:
	if control == DAYTIME_CONTROL:
		return "Управление пиццерией"
	if control == CAMERA_CONTROL:
		return "Видеонаблюдение"
	var shutter: int = SHUTTER_FOR_CONTROL[control]
	var action := "Открыть" if _shutter_mask & (1 << shutter) else "Закрыть"
	var side := "западную" if shutter == 0 else "восточную"
	return "%s %s ставню" % [action, side]


func press(control: int) -> void:
	var button := _buttons[control]
	if _button_motion[control] != null:
		_button_motion[control].kill()
	var rest: float = (button.get_parent().get_node("ButtonCase").mesh as BoxMesh).size.z * 0.5
	var motion := create_tween().set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	_button_motion[control] = motion
	motion.tween_property(button, "position:z", rest - 0.025, 0.075)
	motion.tween_interval(0.045)
	motion.tween_property(button, "position:z", rest, 0.14)


func shutter_for(control: int) -> int:
	return SHUTTER_FOR_CONTROL[control] if control >= 0 and control < CAMERA_CONTROL else -1


func shutter_is_moving(shutter: int) -> bool:
	return _shutter_motion[shutter] != null and _shutter_motion[shutter].is_running()


func doorway_contains(shutter: int, feet: Vector3) -> bool:
	var at := to_local(feet)
	return absf(at.x - _shutters[shutter].position.x) < 0.66 \
		and at.z > _doorway.x - 0.38 and at.z < _doorway.y + 0.38 \
		and at.y > -1.7 and at.y < _door_height + 0.15


func apply_shutters(mask: int, immediate := false) -> void:
	var changed := _shutter_mask ^ mask
	_shutter_mask = mask
	for index in _shutters.size():
		if not immediate and not (changed & (1 << index)):
			continue
		if _shutter_motion[index] != null:
			_shutter_motion[index].kill()
		var closed := bool(mask & (1 << index))
		var slab := _shutters[index]
		if immediate:
			slab.position.y = _height_for(closed)
			_set_status(index, "ЗАКРЫТА" if closed else "ОТКРЫТА", CLOSED_COLOR if closed else OPEN_COLOR)
			continue
		_set_status(index, "ЗАКРЫВАЕТСЯ" if closed else "ОТКРЫВАЕТСЯ", MOVING_COLOR)
		var duration := maxf(0.09, absf(slab.position.y - _height_for(closed)) / _door_height * SHUTTER_TRAVEL_TIME)
		var motion := create_tween().set_process_mode(Tween.TWEEN_PROCESS_PHYSICS)
		_shutter_motion[index] = motion
		motion.tween_property(slab, "position:y", _height_for(closed), duration) \
			.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
		motion.tween_callback(_set_status.bind(index, "ЗАКРЫТА" if closed else "ОТКРЫТА",
			CLOSED_COLOR if closed else OPEN_COLOR))


func _height_for(closed: bool) -> float:
	return _door_height * 0.5 if closed else _door_height * 1.5 + 0.04


func _set_status(index: int, text: String, color: Color) -> void:
	_status[index].text = "%s  /  %s" % ["ЗАПАД" if index == 0 else "ВОСТОК", text]
	_status[index].modulate = color
	_lights[index].albedo_color = color
	_lights[index].emission = color


func _label(content: String, at: Vector3, pixel_size: float) -> Label3D:
	var label := Label3D.new()
	label.text = content
	label.position = at
	Look.style_sign(label, INK, 80, pixel_size)
	label.no_depth_test = false
	add_child(label)
	return label


func _box(parent: Node3D, node_name: String, size: Vector3, at: Vector3, material: Material) -> MeshInstance3D:
	var mesh := MeshInstance3D.new()
	mesh.name = node_name
	var box := BoxMesh.new()
	box.size = size
	mesh.mesh = box
	mesh.material_override = Surfaces.for_size(material, size)
	mesh.position = at
	parent.add_child(mesh)
	return mesh
