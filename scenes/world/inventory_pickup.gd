extends RigidBody3D

const PICKUP_LAYER := 1 << 5

var item_id: String
var mouse_grabbed := false
var dropped_in_hub := false
var holder_id := 0:
	set(value):
		holder_id = value
		if is_node_ready():
			_apply_holder()


func _ready() -> void:
	var shape := BoxShape3D.new()
	match item_id:
		"medkit":
			shape.size = Vector3(0.34, 0.23, 0.14)
			_build_medkit()
		"battery":
			shape.size = Vector3(0.13, 0.28, 0.13)
			_cylinder(0.066, 0.23, 0.0, Color("#5d9cac"))
			_cylinder(0.059, 0.025, -0.11, Color("#d5dfdb"))
			_cylinder(0.036, 0.04, 0.12, Color("#b8cbcc"))
		"pills":
			shape.size = Vector3(0.16, 0.23, 0.16)
			_cylinder(0.071, 0.18, -0.025, Color("#bb6d40"))
			_cylinder(0.073, 0.072, -0.028, Color("#e9d9b9"))
			_cylinder(0.078, 0.042, 0.082, Color("#f0ebe0"))
		"lamp":
			shape.size = Vector3(0.18, 0.29, 0.18)
			_cylinder(0.048, 0.19, -0.05, Color("#4d666d"))
			_cylinder(0.050, 0.027, -0.11, Color("#dd9e41"))
			_cylinder(0.087, 0.075, 0.085, Color("#596b70"))
			_cylinder(0.071, 0.012, 0.128, Color("#ffde91"))
	var collider := CollisionShape3D.new()
	collider.shape = shape
	add_child(collider)
	_apply_holder()


func _apply_holder() -> void:
	freeze = not multiplayer.is_server() or holder_id != 0
	collision_layer = PICKUP_LAYER if holder_id == 0 else 0
	collision_mask = 1 if holder_id == 0 else 0
	if not freeze:
		sleeping = false
	elif multiplayer.is_server():
		linear_velocity = Vector3.ZERO
		angular_velocity = Vector3.ZERO


func _build_medkit() -> void:
	_box(Vector3(0.34, 0.20, 0.14), Vector3(0.0, -0.015, 0.0), Color("#f1e7ce"))
	_box(Vector3(0.14, 0.027, 0.046), Vector3(0.0, 0.10, 0.0), Color("#797b70"))
	_box(Vector3(0.14, 0.14, 0.006), Vector3(0.0, -0.015, 0.071), Color("#315649"))
	_box(Vector3(0.085, 0.029, 0.008), Vector3(0.0, -0.015, 0.076), Color("#afe3a0"))
	_box(Vector3(0.029, 0.085, 0.008), Vector3(0.0, -0.015, 0.076), Color("#afe3a0"))


func _box(dimensions: Vector3, offset: Vector3, color: Color) -> void:
	var box := BoxMesh.new()
	box.size = dimensions
	_add_mesh(box, offset, color)


func _cylinder(radius: float, height: float, y: float, color: Color) -> void:
	var cylinder := CylinderMesh.new()
	cylinder.top_radius = radius
	cylinder.bottom_radius = radius
	cylinder.height = height
	cylinder.radial_segments = 12
	cylinder.rings = 0
	_add_mesh(cylinder, Vector3(0.0, y, 0.0), color)


func _add_mesh(mesh: Mesh, offset: Vector3, color: Color) -> void:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = 0.76
	var model := MeshInstance3D.new()
	model.mesh = mesh
	model.material_override = material
	model.position = offset
	add_child(model)
