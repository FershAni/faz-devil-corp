extends Node3D

const REST := Vector3(0.29, -0.48, -0.31)
const FINGER_EXTENDED := Vector3(-0.025, 0.012, -0.091)

var _motion: Tween
var _index: MeshInstance3D


func _ready() -> void:
	var sleeve := _material(Color(0.37, 0.30, 0.20))
	var glove := _material(Color(0.12, 0.14, 0.15))
	var cuff := _material(Color(0.63, 0.44, 0.23))
	var wrist := Vector3(0.0, -0.017, 0.04)
	var elbow := Vector3(0.34, -0.32, 0.39)
	_tube(wrist, elbow, 0.044, 0.075, sleeve)
	_tube(wrist, wrist.lerp(elbow, 0.15), 0.049, 0.052, cuff)
	_oval(Vector3(0.047, 0.034, 0.067), Vector3(0.0, 0.0, -0.015), glove)
	_index = _oval(Vector3(0.016, 0.017, 0.056), FINGER_EXTENDED, glove)
	_oval(Vector3(0.025, 0.020, 0.034), Vector3(0.032, -0.020, -0.035), glove)
	hide()


func reach_for(target: Vector3, grip: bool) -> void:
	if _motion != null:
		_motion.kill()
	var aim := (get_parent() as Camera3D).to_local(target).normalized()
	var reach := aim * 0.78 + Vector3(0.041, -0.042, 0.04)
	position = REST
	rotation_degrees = Vector3(-12.0, -13.0, -17.0)
	_index.position = FINGER_EXTENDED
	_index.rotation.x = 0.0
	show()
	_motion = create_tween().set_trans(Tween.TRANS_CUBIC)
	_motion.tween_property(self, "position", reach, 0.15).set_ease(Tween.EASE_OUT)
	_motion.parallel().tween_property(self, "rotation_degrees", Vector3.ZERO, 0.15)
	if grip:
		_motion.parallel().tween_property(_index, "position", Vector3(-0.025, -0.011, -0.067), 0.15)
		_motion.parallel().tween_property(_index, "rotation:x", -0.82, 0.15)
	_motion.tween_interval(0.045)
	_motion.tween_property(self, "position", REST, 0.22).set_ease(Tween.EASE_IN)
	_motion.tween_callback(hide)


func _tube(start: Vector3, end: Vector3, start_radius: float, end_radius: float,
		material: StandardMaterial3D) -> void:
	var tube := CylinderMesh.new()
	tube.height = start.distance_to(end)
	tube.top_radius = end_radius
	tube.bottom_radius = start_radius
	tube.radial_segments = 10
	var part := _piece(tube, start.lerp(end, 0.5), material)
	part.basis = Basis(Quaternion(Vector3.UP, (end - start).normalized()))


func _oval(radii: Vector3, at: Vector3, material: StandardMaterial3D) -> MeshInstance3D:
	var oval := SphereMesh.new()
	oval.radius = 1.0
	oval.height = 2.0
	oval.radial_segments = 12
	oval.rings = 6
	var part := _piece(oval, at, material)
	part.scale = radii
	return part


func _piece(mesh: Mesh, at: Vector3, material: StandardMaterial3D) -> MeshInstance3D:
	var part := MeshInstance3D.new()
	part.mesh = mesh
	part.material_override = material
	part.position = at
	part.layers = 2
	part.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(part)
	return part


func _material(color: Color) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = 0.93
	return material
