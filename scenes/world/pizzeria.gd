class_name Pizzeria
extends Node3D


## The FNAF 1 camera plan, with north at -Z. The dining room feeds two separate
## halls that meet only at the security office. Service rooms branch off the
## same walls as on the monitor. Dimensions are in controller-scale meters.

const WALL_H := 3.4
const WALL_THICKNESS := 0.18
const DOOR_H := 2.5
const REACH := 2.4
const HALL_INNER := 3.85
const HALL_OUTER := 7.7
const HALL_END := 20.5
const OFFICE_FRONT := 14.5
const OFFICE_DOOR := Vector2(16.65, 18.85)
const DESK_LOCAL := Vector3(0.0, 0.0, 15.65)
const COUNTER_LOCAL := Vector3(8.6, 0.0, -6.75)
const DOOR_LOCAL := Vector3(0.0, 0.0, 4.35)
const PUBLIC_ENTRANCE: float = -9.7
const PUBLIC_OPENING: Vector2 = Vector2(-10.8, -8.6)
const KITCHEN_PICKUP: Vector3 = Vector3(11.5, 1.04, 8.3)
const DINING := Rect2(-12.0, -9.0, 24.0, 14.0)
const STAGE := Rect2(-6.5, -13.0, 11.5, 4.0)
const BACKSTAGE := Rect2(-17.0, -9.0, 5.0, 6.0)
const COVE := Rect2(-17.0, -0.5, 5.0, 5.0)
const CLOSET := Rect2(-12.6, 7.6, 4.9, 6.6)
const RESTROOM_HALL := Rect2(12.0, -5.4, 3.3, 10.2)
const RESTROOM_NORTH := Rect2(15.3, -3.7, 4.0, 3.3)
const RESTROOM_SOUTH := Rect2(15.3, 1.3, 4.0, 3.3)
const KITCHEN_ENTRY := Rect2(9.65, 5.0, 2.2, 1.6)
const KITCHEN := Rect2(9.15, 6.6, 8.05, 6.8)
const WEST_ENTRY := Vector2(-7.55, -4.0)
const EAST_ENTRY := Vector2(4.0, 7.55)
const BACKSTAGE_DOOR := Vector2(-7.95, -5.85)
const COVE_OPENING := Vector2(0.0, 4.0)
const CLOSET_DOOR := Vector2(9.95, 12.05)
const RESTROOM_ENTRY := Vector2(-4.95, -2.75)
const RESTROOM_NORTH_DOOR := Vector2(-3.35, -1.45)
const RESTROOM_SOUTH_DOOR := Vector2(1.7, 3.6)
const TABLE_X := [-3.4, 2.2]
const TABLE_Z := [-4.65, 0.65]
const GOLD_INK := Color(1.0, 0.81, 0.53)
const OFFICE_INK := Color(0.63, 0.89, 0.79)
const SORTIE_OPEN_TIME := 0.76

var security: SecurityOffice
var _sortie_leaves: Array[Node3D] = []
var _sortie_handle: MeshInstance3D
var _sortie_motion: Tween
var _public_doors: StaticBody3D
var _public_status: Label3D

var _mat_floor: StandardMaterial3D
var _mat_ceiling: StandardMaterial3D
var _mat_plaster: StandardMaterial3D
var _mat_brick: StandardMaterial3D
var _mat_wood: StandardMaterial3D
var _mat_chair: StandardMaterial3D
var _mat_seat: StandardMaterial3D
var _mat_glass: StandardMaterial3D
var _mat_curtain: StandardMaterial3D
var _mat_metal: StandardMaterial3D
var _mat_red: StandardMaterial3D
var _mat_globe: StandardMaterial3D
var _mat_panel: StandardMaterial3D
var _mat_curtain_red: StandardMaterial3D
var _mat_gold: StandardMaterial3D
var _mat_hat: StandardMaterial3D
var _mat_eye: StandardMaterial3D
var _mat_fur_bear: StandardMaterial3D
var _mat_fur_rabbit: StandardMaterial3D
var _mat_fur_fox: StandardMaterial3D
var _mat_fur_bird: StandardMaterial3D
var _mat_office: StandardMaterial3D
var _mat_cove: StandardMaterial3D
var _mat_crust: StandardMaterial3D
var _mat_sauce: StandardMaterial3D
var _mat_pepperoni: StandardMaterial3D
var _mat_paper: StandardMaterial3D
var _mat_trash: StandardMaterial3D
var _mat_balloon: StandardMaterial3D



func _ready() -> void:
	_make_materials()
	_shell()
	_office()
	_hall_details()
	_counter()
	_sortie_door()
	_build_public_doors()
	_dining()
	_stage()
	_pirate_cove()
	_service_rooms()
	_party_decor()
	_lights()


func _pizza(at: Vector3, radius: float) -> void:
	_cyl(radius, 0.045, at, _mat_crust, "Crust")
	_cyl(radius * 0.86, 0.02, at + Vector3(0.0, 0.03, 0.0), _mat_sauce, "Sauce")
	for i in 5:
		var a := float(i) / 5.0 * TAU
		_cyl(radius * 0.16, 0.016, at + Vector3(cos(a) * radius * 0.52, 0.048,
			sin(a) * radius * 0.52), _mat_pepperoni, "Pepperoni")


func _cup(at: Vector3) -> void:
	var mesh := MeshInstance3D.new()
	mesh.name = "Cup"
	var cup := CylinderMesh.new()
	cup.top_radius = 0.055
	cup.bottom_radius = 0.042
	cup.height = 0.12
	cup.radial_segments = 8
	mesh.mesh = cup
	mesh.material_override = _mat_paper
	mesh.position = at
	add_child(mesh)


func _bin(at: Vector3) -> void:
	_cyl(0.26, 0.62, at + Vector3(0.0, 0.31, 0.0), _mat_trash, "Bin")
	_cyl(0.29, 0.05, at + Vector3(0.0, 0.64, 0.0), _mat_trash, "BinRim")
	_cup(at + Vector3(0.34, 0.0, 0.18))
	_mesh(Vector3(0.2, 0.06, 0.16), at + Vector3(-0.3, 0.03, 0.24), _mat_paper, "Litter")



func counter_pos() -> Vector3:
	return to_global(COUNTER_LOCAL)


func door_pos() -> Vector3:
	return to_global(DOOR_LOCAL)


func office_desk_pos() -> Vector3:
	return to_global(DESK_LOCAL)


func kitchen_pickup_pos() -> Vector3:
	return to_global(KITCHEN_PICKUP)


func hub_spawns() -> Array[Vector3]:
	var slots: Array[Vector3] = []
	for x in [0.0, -1.2, 1.2, 2.4]:
		slots.append(to_global(Vector3(x, 0.0, 19.05)))
	return slots


## ---------------- shell ----------------

func _shell() -> void:
	_slab(DINING, "Dining")
	_slab(STAGE, "Stage")
	_slab(BACKSTAGE, "Backstage")
	_slab(COVE, "PirateCove")
	_slab(Rect2(-HALL_OUTER, 5.0, HALL_OUTER - HALL_INNER, HALL_END - 5.0), "WestHall")
	_slab(Rect2(HALL_INNER, 5.0, HALL_OUTER - HALL_INNER, HALL_END - 5.0), "EastHall")
	_slab(Rect2(-HALL_INNER, OFFICE_FRONT, HALL_INNER * 2.0, HALL_END - OFFICE_FRONT), "Office")
	_slab(CLOSET, "SupplyCloset")
	_slab(RESTROOM_HALL, "RestroomHall")
	_slab(RESTROOM_NORTH, "NorthRestroom")
	_slab(RESTROOM_SOUTH, "SouthRestroom")
	_slab(KITCHEN_ENTRY, "KitchenEntry")
	_slab(KITCHEN, "Kitchen")
	_slab(Rect2(-10.95, 5.0, 2.5, 2.45), "PublicVestibule")

	# Each shared wall is built once. Door openings use coordinates along that wall.
	_wall_x(-9.0, -12.0, STAGE.position.x, _mat_brick, "DiningNorthWest")
	_wall_x(-9.0, STAGE.end.x, 12.0, _mat_brick, "DiningNorthEast")
	_wall_z(-12.0, -9.0, 5.0, _mat_plaster, "DiningWest", [BACKSTAGE_DOOR, COVE_OPENING])
	_wall_z(12.0, -9.0, 5.0, _mat_plaster, "DiningEast", [RESTROOM_ENTRY])
	_wall_x(5.0, -12.0, 12.0, _mat_plaster, "DiningSouth",
		[PUBLIC_OPENING, WEST_ENTRY, EAST_ENTRY, Vector2(KITCHEN_ENTRY.position.x, KITCHEN_ENTRY.end.x)])

	_alcove_shell(STAGE, "Stage", _mat_brick, false)
	_alcove_shell(BACKSTAGE, "Backstage", _mat_office, true)
	_alcove_shell(COVE, "PirateCove", _mat_brick, true)
	_hall_shells()
	_service_shells()


func _slab(footprint: Rect2, room_name: String) -> void:
	var center := footprint.get_center()
	_box(Vector3(footprint.size.x, 0.2, footprint.size.y),
		Vector3(center.x, -0.1, center.y), _mat_floor, room_name + "Floor")
	_box(Vector3(footprint.size.x, 0.2, footprint.size.y),
		Vector3(center.x, WALL_H + 0.1, center.y), _mat_ceiling, room_name + "Ceiling")


## Stage opens south. The backstage and cove alcoves open east into the dining room.
func _alcove_shell(room: Rect2, room_name: String, material: Material, open_east: bool) -> void:
	_wall_x(room.position.y, room.position.x, room.end.x, material, room_name + "North")
	_wall_z(room.position.x, room.position.y, room.end.y, material, room_name + "West")
	if open_east:
		_wall_x(room.end.y, room.position.x, room.end.x, material, room_name + "South")
	else:
		_wall_z(room.end.x, room.position.y, room.end.y, material, room_name + "East")


func _hall_shells() -> void:
	_wall_z(-HALL_OUTER, 5.0, HALL_END, _mat_plaster, "WestOuter", [CLOSET_DOOR])
	_wall_z(HALL_OUTER, 5.0, HALL_END, _mat_plaster, "EastOuter")
	_wall_z(-HALL_INNER, 5.0, HALL_END, _mat_office, "WestInner", [OFFICE_DOOR])
	_wall_z(HALL_INNER, 5.0, HALL_END, _mat_office, "EastInner", [OFFICE_DOOR])
	_wall_x(HALL_END, -HALL_OUTER, HALL_OUTER, _mat_office, "SouthWall")
	_wall_x(OFFICE_FRONT, -HALL_INNER, HALL_INNER, _mat_office, "OfficeFront")
	_alcove_shell(CLOSET, "SupplyCloset", _mat_office, true)


func _service_shells() -> void:
	_wall_x(RESTROOM_HALL.position.y, 12.0, 15.3, _mat_office, "RestroomHallNorth")
	_wall_x(RESTROOM_HALL.end.y, 12.0, 15.3, _mat_office, "RestroomHallSouth")
	_wall_z(15.3, RESTROOM_HALL.position.y, RESTROOM_HALL.end.y, _mat_office,
		"RestroomHallEast", [RESTROOM_NORTH_DOOR, RESTROOM_SOUTH_DOOR])
	for room in [RESTROOM_NORTH, RESTROOM_SOUTH]:
		_wall_x(room.position.y, 15.3, room.end.x, _mat_office, "RestroomNorth")
		_wall_x(room.end.y, 15.3, room.end.x, _mat_office, "RestroomSouth")
		_wall_z(room.end.x, room.position.y, room.end.y, _mat_office, "RestroomEast")
	_wall_z(KITCHEN_ENTRY.position.x, 5.0, KITCHEN.position.y, _mat_office, "KitchenEntryWest")
	_wall_z(KITCHEN_ENTRY.end.x, 5.0, KITCHEN.position.y, _mat_office, "KitchenEntryEast")
	_wall_x(KITCHEN.position.y, KITCHEN.position.x, KITCHEN_ENTRY.position.x, _mat_office, "KitchenNorthWest")
	_wall_x(KITCHEN.position.y, KITCHEN_ENTRY.end.x, KITCHEN.end.x, _mat_office, "KitchenNorthEast")
	_wall_x(KITCHEN.end.y, KITCHEN.position.x, KITCHEN.end.x, _mat_office, "KitchenSouth")
	_wall_z(KITCHEN.position.x, KITCHEN.position.y, KITCHEN.end.y, _mat_office, "KitchenWest")
	_wall_z(KITCHEN.end.x, KITCHEN.position.y, KITCHEN.end.y, _mat_office, "KitchenEast")


func _wall_x(z: float, from: float, to: float, material: Material, wall_name: String,
		openings: Array[Vector2] = []) -> void:
	_wall(z, from, to, false, material, wall_name, openings)


func _wall_z(x: float, from: float, to: float, material: Material, wall_name: String,
		openings: Array[Vector2] = []) -> void:
	_wall(x, from, to, true, material, wall_name, openings)


func _wall(axis: float, from: float, to: float, along_z: bool, material: Material,
		wall_name: String, openings: Array[Vector2]) -> void:
	var start := from
	for opening in openings:
		_wall_piece(axis, start, opening.x, 0.0, WALL_H, along_z, material, wall_name)
		_wall_piece(axis, opening.x, opening.y, DOOR_H, WALL_H, along_z, material, wall_name + "Lintel")
		start = opening.y
	_wall_piece(axis, start, to, 0.0, WALL_H, along_z, material, wall_name)


func _wall_piece(axis: float, from: float, to: float, bottom: float, top: float, along_z: bool,
		material: Material, wall_name: String) -> void:
	var length := to - from
	var center := (from + to) / 2.0
	var pos := Vector3(axis, (bottom + top) / 2.0, center) if along_z else Vector3(center, (bottom + top) / 2.0, axis)
	var size := Vector3(WALL_THICKNESS, top - bottom, length) if along_z else Vector3(length, top - bottom, WALL_THICKNESS)
	_box(size, pos, material, wall_name)
	if bottom == 0.0:
		var trim := Vector3(0.205, 0.16, length) if along_z else Vector3(length, 0.16, 0.205)
		pos.y = 1.03
		_mesh(trim, pos, _mat_red, "WallStripe")
		pos.y = 0.09
		_mesh(trim, pos, _mat_metal, "Baseboard")


## ---------------- office and routes ----------------

func _office() -> void:
	var desk := DESK_LOCAL
	_box(Vector3(4.35, 0.1, 1.05), desk + Vector3(0.0, 0.91, 0.0), _mat_wood, "SecurityDesk")
	for x in [-1.8, 1.8]:
		_box(Vector3(0.55, 0.87, 0.89), desk + Vector3(x, 0.435, 0.0), _mat_metal, "DeskDrawers")
		for y in [0.22, 0.48, 0.72]:
			_mesh(Vector3(0.21, 0.035, 0.05), desk + Vector3(x, y, 0.47), _mat_gold, "DrawerPull")
	_mesh(Vector3(0.29, 0.18, 0.2), desk + Vector3(1.56, 1.05, -0.06), _mat_glass, "Radio")
	_mesh(Vector3(0.015, 0.33, 0.015), desk + Vector3(1.5, 1.24, -0.1), _mat_metal, "Antenna")
	_mesh(Vector3(0.34, 0.022, 0.26), desk + Vector3(-1.47, 0.971, 0.21), _mat_paper, "ShiftLog")
	_cup(desk + Vector3(-1.7, 1.02, 0.15))
	security = SecurityOffice.new()
	security.name = "SecurityOffice"
	add_child(security)
	security.build(HALL_INNER, OFFICE_DOOR, DOOR_H, desk, _mat_metal, _mat_gold)
	_security_cameras()
	_sign("ПОСТ ОХРАНЫ", Vector3(0.0, 2.61, OFFICE_FRONT + 0.23), OFFICE_INK)
	_label("← ЗАПАДНЫЙ ХОЛЛ", Vector3(-2.38, 2.06, OFFICE_FRONT + 0.12), OFFICE_INK, 0.0, 0.002)
	_label("ВОСТОЧНЫЙ ХОЛЛ →", Vector3(2.38, 2.06, OFFICE_FRONT + 0.12), OFFICE_INK, 0.0, 0.002)
	for side in [-1.0, 1.0]:
		var x: float = side * HALL_INNER
		var z := (OFFICE_DOOR.x + OFFICE_DOOR.y) / 2.0
		for edge in [OFFICE_DOOR.x, OFFICE_DOOR.y]:
			_mesh(Vector3(0.46, DOOR_H, 0.13), Vector3(x, DOOR_H / 2.0, edge), _mat_metal, "ShutterRail")
		_mesh(Vector3(0.48, 0.28, OFFICE_DOOR.y - OFFICE_DOOR.x + 0.16),
			Vector3(x, DOOR_H + 0.11, z), _mat_metal, "ShutterHousing")
		_sign("ЗАПАД" if side < 0.0 else "ВОСТОК",
			Vector3(x - side * 0.29, 2.88, z), OFFICE_INK, -side * 90.0)


func _security_cameras() -> void:
	security.add_camera("1A", "Сцена", Vector3(-0.75, 3.02, -6.65), Vector3(-0.75, 1.75, -11.3))
	security.add_camera("1C", "Пиратская бухта", Vector3(-13.25, 3.02, 0.5), Vector3(-14.62, 1.4, 2.0))
	security.add_camera("2A", "Западный коридор", Vector3(-7.3, 3.02, 5.55), Vector3(-5.78, 1.2, 12.8))
	security.add_camera("2B", "Угол западного коридора", Vector3(-7.3, 3.02, 19.8), Vector3(-4.1, 1.3, 17.75))
	security.add_camera("3", "Кладовка", Vector3(-8.25, 3.02, 8.15), Vector3(-11.55, 1.2, 11.1))
	security.add_camera("4A", "Восточный коридор", Vector3(7.3, 3.02, 5.55), Vector3(5.78, 1.2, 12.8))
	security.add_camera("4B", "Угол восточного коридора", Vector3(7.3, 3.02, 19.8), Vector3(4.1, 1.3, 17.75))
	security.add_camera("5", "Закулисье", Vector3(-12.5, 3.02, -3.55), Vector3(-16.3, 1.1, -6.65))
	security.add_camera("6", "Кухня", Vector3(10.6, 3.02, 12.85), Vector3(14.85, 1.25, 9.7))
	security.add_camera("7", "Туалеты", Vector3(12.55, 3.02, -4.25), Vector3(14.7, 1.35, -0.35))


func _hall_details() -> void:
	var hall_center := (HALL_INNER + HALL_OUTER) / 2.0
	for side in [-1.0, 1.0]:
		var west: bool = side < 0.0
		var x: float = side * hall_center
		var title := "ЗАПАДНЫЙ ХОЛЛ" if west else "ВОСТОЧНЫЙ ХОЛЛ"
		_sign(title, Vector3(x, 2.91, 4.79), GOLD_INK, 180.0)
		_sign("В ЗАЛ", Vector3(x, 2.91, 5.21), GOLD_INK)
		_sign("ПОСТ ОХРАНЫ", Vector3(x, 2.18, HALL_END - 0.23), OFFICE_INK, 180.0)
		_sign("В ЗАЛ →" if west else "← В ЗАЛ",
			Vector3(side * (HALL_OUTER - 0.23), 1.95, (OFFICE_DOOR.x + OFFICE_DOOR.y) / 2.0),
			GOLD_INK, -side * 90.0)
		_sign("CAM 2A" if west else "CAM 4A",
			Vector3(side * (HALL_INNER + 0.23), 2.2, 8.0), GOLD_INK, side * 90.0)
		_sign("CAM 2B" if west else "CAM 4B",
			Vector3(side * (HALL_OUTER - 0.23), 2.1, 15.0), GOLD_INK, -side * 90.0)
	_sign("КЛАДОВАЯ", Vector3(-HALL_OUTER + 0.23, 2.9, 11.0), GOLD_INK, 90.0)


func _sortie_door() -> void:
	_mesh(Vector3(2.38, 2.39, 0.035), Vector3(0.0, 1.20, 4.885), _mat_glass, "SortieRecess")
	for side in [-1.0, 1.0]:
		var leaf := _mesh(Vector3(1.19, 2.39, 0.14), Vector3(side * 0.6, 1.20, 4.80),
			_mat_metal, "SortieLeaf")
		_sortie_leaves.append(leaf)
		_mesh(Vector3(0.045, 2.29, 0.06), Vector3(side * 0.06, 1.20, 4.705),
			_mat_gold, "SortieLeafEdge").reparent(leaf)
	for x in [-1.19, 1.19]:
		_mesh(Vector3(0.075, 2.43, 0.08), Vector3(x, 1.215, 4.71), _mat_gold, "SortieDoorTrim")
	_mesh(Vector3(2.42, 0.13, 0.08), Vector3(0.0, 2.4, 4.71), _mat_gold, "SortieDoorHeader")
	_sortie_handle = _mesh(Vector3(0.29, 0.1, 0.08), Vector3(0.27, 1.12, 4.68), _mat_gold, "SortieHandle")
	_sortie_handle.reparent(_sortie_leaves[1])
	_mesh(Vector3(2.35, 0.02, 0.85), Vector3(0.0, 0.012, 4.29), _mat_red, "SortieMat")
	_sign("ВЫЛАЗКА  [E]", Vector3(0.0, 2.88, 4.69), GOLD_INK, 180.0)


func sortie_handle_pos() -> Vector3:
	return _sortie_handle.global_position


func animate_sortie() -> void:
	_sortie_motion = create_tween().set_trans(Tween.TRANS_CUBIC)
	_sortie_motion.tween_property(_sortie_handle, "rotation:z", -0.36, 0.15)
	_sortie_motion.tween_property(_sortie_leaves[0], "position:x", -1.63, SORTIE_OPEN_TIME - 0.15)
	_sortie_motion.parallel().tween_property(_sortie_leaves[1], "position:x", 1.63, SORTIE_OPEN_TIME - 0.15)


func reset_sortie() -> void:
	if _sortie_motion != null:
		_sortie_motion.kill()
	_sortie_leaves[0].position.x = -0.6
	_sortie_leaves[1].position.x = 0.6
	_sortie_handle.rotation.z = 0.0


## ---------------- dining and counter ----------------

func _build_public_doors() -> void:
	_wall_z(-10.95, 5.0, 7.45, _mat_plaster, "PublicVestibuleWest")
	_wall_z(-8.45, 5.0, 7.45, _mat_plaster, "PublicVestibuleEast")
	_wall_x(7.45, -10.95, -8.45, _mat_glass, "StreetDoor")
	_public_doors = _box(Vector3(2.2, DOOR_H, 0.18),
		Vector3(PUBLIC_ENTRANCE, DOOR_H / 2.0, 5.0), _mat_metal, "PublicDoors")
	var center_trim: MeshInstance3D = _mesh(Vector3(0.055, 2.45, 0.2),
		_public_doors.position, _mat_gold, "PublicDoorTrim")
	center_trim.reparent(_public_doors)
	_public_status = _label("ЗАКРЫТО", Vector3(PUBLIC_ENTRANCE, 2.83, 4.87), GOLD_INK, 180.0, 0.003)


func set_daytime_open(open: bool) -> void:
	_public_doors.visible = not open
	_public_doors.set_deferred("collision_layer", 0 if open else 1)
	_public_status.text = "ОТКРЫТО" if open else "ЗАКРЫТО"


func _counter() -> void:
	var center := COUNTER_LOCAL + Vector3(0.0, 0.0, -1.12)
	_box(Vector3(5.45, 1.0, 0.8), center + Vector3(0.0, 0.5, 0.0), _mat_wood, "Counter")
	_box(Vector3(5.65, 0.08, 0.95), center + Vector3(0.0, 1.04, 0.0), _mat_wood, "CounterTop")
	_mesh(Vector3(0.5, 0.35, 0.4), center + Vector3(-2.15, 1.26, 0.0), _mat_metal, "Register")
	for i in 3:
		_mesh(Vector3(0.6, 0.1, 0.6), center + Vector3(-0.75 + i * 1.2, 1.13, 0.0), _mat_red, "PizzaBox")
	_mesh(Vector3(0.3, 0.18, 0.22), center + Vector3(2.32, 1.17, 0.12), _mat_chair, "Napkins")
	for y in [1.7, 2.2]:
		_box(Vector3(5.3, 0.06, 0.35), Vector3(center.x, y, -8.73), _mat_wood, "Shelf")
		for i in 9:
			_cyl(0.06, 0.3, Vector3(center.x - 2.1 + i * 0.51, y + 0.18, -8.73), _mat_glass, "Bottle")
	_sign("МАГАЗИН  [E]", Vector3(center.x, 2.94, -8.77), GOLD_INK)
	_sign("ПИЦЦА / СОДА / КОФЕ", Vector3(center.x, 1.35, -8.77), Color(0.85, 0.8, 0.7))


func _dining() -> void:
	for x in TABLE_X:
		for z in TABLE_Z:
			var at := Vector3(x, 0.0, z)
			_box(Vector3(1.2, 0.08, 3.4), at + Vector3(0.0, 0.74, 0.0), _mat_wood, "TableTop")
			for lx in [-0.5, 0.5]:
				for lz in [-1.55, 1.55]:
					_box(Vector3(0.08, 0.7, 0.08), at + Vector3(lx, 0.35, lz), _mat_wood, "TableLeg")
			_mesh(Vector3(0.91, 0.012, 2.85), at + Vector3(0.0, 0.786, 0.0), _mat_curtain_red, "TableRunner")
			_mesh(Vector3(0.3, 0.16, 0.22), at + Vector3(0.0, 0.875, 0.0), _mat_chair, "Napkins")
			for side in [-1.0, 1.0]:
				for dz in [-1.2, 0.0, 1.2]:
					_chair(at + Vector3(side * 0.95, 0.0, dz), side)
			_pizza(at + Vector3(0.0, 0.819, -0.83), 0.32)
			_cup(at + Vector3(0.33, 0.847, 0.84))
			_cone(0.11, 0.25, at + Vector3(-0.24, 0.917, 1.12), _mat_hat, "PartyHat")
	_bin(Vector3(8.3, 0.0, 4.37))


func _chair(at: Vector3, side: float) -> void:
	_box(Vector3(0.45, 0.07, 0.45), at + Vector3(0.0, 0.45, 0.0), _mat_seat, "Seat")
	for lx in [-0.18, 0.18]:
		for lz in [-0.18, 0.18]:
			_box(Vector3(0.05, 0.45, 0.05), at + Vector3(lx, 0.22, lz), _mat_chair, "ChairLeg")
	_box(Vector3(0.06, 0.55, 0.45), at + Vector3(side * 0.2, 0.75, 0.0), _mat_chair, "Backrest")



## ---------------- show stage and Pirate Cove ----------------

func _stage() -> void:
	var floor_y := 0.52
	_box(Vector3(11.1, floor_y, 3.4), Vector3(-0.75, floor_y / 2.0, -11.25), _mat_wood, "Stage")
	_mesh(Vector3(10.85, 0.13, 0.08), Vector3(-0.75, 0.33, -9.53), _mat_gold, "StageApron")
	_mesh(Vector3(10.7, 2.36, 0.16), Vector3(-0.75, 1.55, -12.78), _mat_curtain_red, "StageCurtain")
	for pleat in 14:
		_mesh(Vector3(0.11, 2.36, 0.07), Vector3(-5.95 + pleat * 0.8, 1.55, -12.67),
			_mat_cove, "Pleat")
	_mesh(Vector3(11.15, 0.22, 0.44), Vector3(-0.75, 2.82, -9.53), _mat_gold, "Valance")
	_sign("FAZ DEVIL  •  ГЛАВНАЯ СЦЕНА", Vector3(-0.75, 3.09, -9.2), GOLD_INK)
	var bear_start: int = get_child_count()
	_animatronic(Vector3(-0.75, floor_y, -11.1), _mat_fur_bear, 1.0, true)
	var show_prop: InteractiveProp = get_node_or_null("DaytimeProps/StageCooling") as InteractiveProp
	if show_prop != null:
		# Use the existing stage character as the purchased show. Its position is
		# preserved while the prop owns visibility, installation and the cooling switch.
		var pieces: Array[Node] = get_children().slice(bear_start)
		for piece: Node in pieces:
			piece.reparent(show_prop)
	_animatronic(Vector3(-3.0, floor_y, -11.1), _mat_fur_rabbit, 0.96, false)
	_animatronic(Vector3(1.5, floor_y, -11.1), _mat_fur_bird, 0.92, false)


func _pirate_cove() -> void:
	var floor_y := 0.42
	_box(Vector3(3.82, floor_y, 4.48), Vector3(-14.86, floor_y / 2.0, 2.0), _mat_wood, "CoveStage")
	_mesh(Vector3(0.18, 2.48, 4.55), Vector3(-16.75, 1.65, 2.0), _mat_cove, "CoveBackdrop")
	for side in [-1.0, 1.0]:
		for i in 4:
			_mesh(Vector3(0.18 + i * 0.05, 2.25, 0.23), Vector3(-12.96, 1.62, 2.0 + side * (1.12 + i * 0.24)),
				_mat_cove, "CovePleat")
	_mesh(Vector3(0.42, 0.17, 4.3), Vector3(-12.87, 2.81, 2.0), _mat_gold, "CoveRail")
	_sign("ПИРАТСКАЯ БУХТА", Vector3(-11.77, 2.92, 2.0), GOLD_INK, 90.0)
	var costume_start := get_child_count()
	var fox_at := Vector3(-14.62, floor_y, 2.0)
	_animatronic(fox_at, _mat_fur_fox, 0.92, false)
	# The costumes face +Z by default. Foxy faces the opening on the east wall.
	for i in range(costume_start, get_child_count()):
		var piece := get_child(i) as Node3D
		piece.position = fox_at + (piece.position - fox_at).rotated(Vector3.UP, PI / 2.0)
		piece.rotate_y(PI / 2.0)


func _service_rooms() -> void:
	_sign("ЗАКУЛИСЬЕ", Vector3(-11.77, 2.91, -6.9), GOLD_INK, 90.0)
	_sign("ТУАЛЕТЫ", Vector3(11.77, 2.91, -3.85), GOLD_INK, -90.0)
	_sign("КУХНЯ", Vector3(10.75, 2.91, 4.77), GOLD_INK, 180.0)
	_sign("01", Vector3(15.07, 2.91, -2.4), OFFICE_INK, -90.0)
	_sign("02", Vector3(15.07, 2.91, 2.65), OFFICE_INK, -90.0)
	_box(Vector3(0.73, 0.92, 3.2), Vector3(-16.36, 0.46, -6.6), _mat_wood, "BackstageBench")
	_mesh(Vector3(0.46, 0.42, 0.48), Vector3(-16.3, 1.13, -6.3), _mat_fur_bear, "SpareCostumeHead")
	_box(Vector3(0.64, 0.65, 0.65), Vector3(-15.24, 0.325, -8.38), _mat_wood, "BackstageCrate")
	for y in [0.32, 0.98, 1.64, 2.3]:
		_box(Vector3(0.58, 0.07, 4.8), Vector3(-12.14, y, 10.9), _mat_metal, "SupplyShelf")
		for z in [9.42, 10.65, 12.45]:
			_mesh(Vector3(0.38, 0.34, 0.49), Vector3(-12.11, y + 0.205, z), _mat_wood, "SupplyBox")
	for z in [8.56, 13.24]:
		_box(Vector3(0.07, 2.45, 0.07), Vector3(-11.88, 1.225, z), _mat_metal, "ShelfUpright")
	_box(Vector3(4.85, 0.93, 0.86), Vector3(14.15, 0.465, 12.78), _mat_metal, "KitchenWorktop")
	_box(Vector3(1.43, 1.85, 1.0), Vector3(16.34, 0.925, 8.6), _mat_metal, "PizzaOven")
	_mesh(Vector3(0.94, 0.32, 0.06), Vector3(16.34, 1.14, 9.13), _mat_glass, "OvenWindow")
	_mesh(Vector3(0.8, 0.055, 0.06), Vector3(16.34, 1.43, 9.15), _mat_gold, "OvenHandle")
	_pizza(Vector3(13.4, 0.953, 12.8), 0.3)
	_box(Vector3(0.85, 0.9, 0.62), KITCHEN_PICKUP - Vector3(0.0, 0.59, 0.0), _mat_metal, "PickupStand")
	_mesh(Vector3(0.46, 0.09, 0.41), KITCHEN_PICKUP - Vector3(0.0, 0.09, 0.0), _mat_paper, "PickupBox")
	_label("ВЫДАЧА ПИЦЦЫ [E]", KITCHEN_PICKUP + Vector3(0.0, 0.41, -0.33), GOLD_INK, 180.0, 0.0022)
	for z in [-2.05, 3.05]:
		_box(Vector3(0.68, 0.86, 1.3), Vector3(18.78, 0.43, z), _mat_panel, "Washbasin")
		_mesh(Vector3(0.3, 0.03, 0.65), Vector3(18.74, 0.876, z), _mat_glass, "BasinInset")
		_mesh(Vector3(0.08, 0.69, 1.25), Vector3(19.13, 1.51, z), _mat_metal, "WashroomMirror")
		_cyl(0.04, 0.18, Vector3(19.02, 0.95, z), _mat_gold, "Tap")


func _party_decor() -> void:
	for z in [-6.8, -1.88]:
		_mesh(Vector3(15.6, 0.024, 0.024), Vector3(-0.75, 3.06, z), _mat_metal, "BannerWire")
		for i in 11:
			var at := Vector3(-8.05 + i * 1.46, 2.88, z)
			var flag := CylinderMesh.new()
			flag.top_radius = 0.0
			flag.bottom_radius = 0.22
			flag.height = 0.36
			flag.radial_segments = 3
			var pennant := MeshInstance3D.new()
			pennant.name = "Pennant"
			pennant.mesh = flag
			pennant.material_override = _mat_hat if i % 2 == 0 else _mat_curtain
			pennant.rotation_degrees.z = 180.0
			pennant.position = at
			add_child(pennant)
	for at in [Vector3(-6.05, 2.57, -7.78), Vector3(4.82, 2.58, -7.65), Vector3(-10.5, 2.67, 3.8)]:
		_mesh_sphere(0.17, at, _mat_balloon, "Balloon")
		_cyl(0.006, 0.86, at + Vector3(0.0, -0.55, 0.0), _mat_paper, "BalloonString")
	_sign("С ДНЁМ РОЖДЕНИЯ!", Vector3(11.77, 2.38, 0.65), GOLD_INK, -90.0)


## One costume, built from primitives. Deliberately not animated: a still thing in a doorway
## is scarier than an animated one, and the crew will walk past it a hundred times.
func _animatronic(at: Vector3, fur: StandardMaterial3D, scale_h: float, party_hat: bool) -> void:
	var body := 1.06 * scale_h
	_cyl(0.14, 0.21, at + Vector3(0.0, 1.13 * scale_h, 0.0), fur, "Neck")
	_capsule(0.34, 0.76 * scale_h, at + Vector3(0.0, 0.75 * scale_h, 0.0), fur, "Torso")
	_mesh(Vector3(0.46, 0.42, 0.5), at + Vector3(0.0, 0.05 + body + 0.28, 0.02), fur, "Skull")
	_mesh(Vector3(0.3, 0.2, 0.26), at + Vector3(0.0, 0.05 + body + 0.2, 0.3),
		_mat_fur_fox if fur == _mat_fur_bird else fur, "Muzzle")
	for side in [-1.0, 1.0]:
		if fur == _mat_fur_rabbit:
			_capsule(0.087, 0.42, at + Vector3(side * 0.17, 0.05 + body + 0.64, -0.02), fur, "LongEar")
		elif fur == _mat_fur_fox:
			_cone(0.115, 0.26, at + Vector3(side * 0.17, 0.05 + body + 0.57, -0.02), fur, "PointedEar")
		elif fur != _mat_fur_bird:
			_mesh_sphere(0.09, at + Vector3(side * 0.22, 0.05 + body + 0.48, -0.02), fur, "Ear")
		var eye_pos := at + Vector3(side * 0.11, 0.05 + body + 0.34, 0.276)
		if fur == _mat_fur_fox and side < 0.0:
			_mesh(Vector3(0.15, 0.14, 0.05), eye_pos, _mat_glass, "Eyepatch")
		else:
			_mesh_sphere(0.035, eye_pos, _mat_eye, "Eye")
		_capsule(0.09, 0.72 * scale_h,
			at + Vector3(side * 0.37, 0.67 * scale_h, 0.04), fur, "Arm")
		_capsule(0.11, 0.5 * scale_h,
			at + Vector3(side * 0.16, 0.29 * scale_h, 0.0), fur, "Leg")
		_mesh(Vector3(0.23, 0.14, 0.34), at + Vector3(side * 0.16, 0.07, 0.08), fur, "Foot")
	if party_hat:
		# Sitting on the skull, not hovering over it: the cone's origin is its centre.
		_cone(0.16, 0.34, at + Vector3(0.0, 0.05 + body + 0.62, 0.0), _mat_hat, "PartyHat")


func _capsule(radius: float, height: float, at: Vector3, material: Material,
		node_name: String) -> void:
	var mesh := MeshInstance3D.new()
	mesh.name = node_name
	var shape := CapsuleMesh.new()
	shape.radius = radius
	shape.height = height
	shape.radial_segments = 8
	shape.rings = 4
	mesh.mesh = shape
	mesh.material_override = material
	mesh.position = at
	add_child(mesh)


func _cone(radius: float, height: float, at: Vector3, material: Material,
		node_name: String) -> void:
	var mesh := MeshInstance3D.new()
	mesh.name = node_name
	var shape := CylinderMesh.new()
	shape.top_radius = 0.0
	shape.bottom_radius = radius
	shape.height = height
	shape.radial_segments = 8
	mesh.mesh = shape
	mesh.material_override = material
	mesh.position = at
	add_child(mesh)



## ---------------- lighting ----------------

func _lights() -> void:
	for x in [-7.9, -0.75, 6.5]:
		for z in [-5.8, 1.9]:
			_ceiling_light(Vector3(x, 0.0, z), Look.COLOR_TUNGSTEN, 5.3, 7.4)
	for x in TABLE_X:
		for z in TABLE_Z:
			_cyl(0.02, 0.7, Vector3(x, WALL_H - 0.35, z), _mat_metal, "Cord")
			_mesh_sphere(0.13, Vector3(x, WALL_H - 0.78, z), _mat_globe, "Globe")
			Look.lamp(self, Vector3(x, WALL_H - 0.85, z), Look.COLOR_TUNGSTEN, 4.0, 5.8)
	for x in [-3.0, -0.75, 1.5]:
		var light := _ceiling_light(Vector3(x, 0.0, -9.92), Look.COLOR_TUNGSTEN, 11.0, 5.5)
		light.look_at(to_global(Vector3(x, 1.2, -11.45)))
	_ceiling_light(Vector3(8.6, 0.0, -6.9), Look.COLOR_DAYLIGHT_BULB, 8.0, 5.5)
	_ceiling_light(Vector3(0.0, 0.0, 16.9), Look.COLOR_DAYLIGHT_BULB, 6.4, 5.2)
	_ceiling_light(Vector3(0.0, 0.0, 19.4), Look.COLOR_TUNGSTEN, 3.8, 4.2)
	for x in [-(HALL_INNER + HALL_OUTER) / 2.0, (HALL_INNER + HALL_OUTER) / 2.0]:
		for z in [7.2, 12.35, 17.8]:
			_ceiling_light(Vector3(x, 0.0, z), Look.COLOR_DAYLIGHT_BULB, 4.3, 5.1)
	var cove_light := _ceiling_light(Vector3(-12.65, 0.0, 2.0), Color(1.0, 0.73, 0.58), 9.5, 5.8)
	cove_light.look_at(to_global(Vector3(-14.85, 1.25, 2.0)))
	for at in [BACKSTAGE.get_center(), CLOSET.get_center(), RESTROOM_HALL.get_center(),
			RESTROOM_NORTH.get_center(), RESTROOM_SOUTH.get_center(), KITCHEN.get_center()]:
		_ceiling_light(Vector3(at.x, 0.0, at.y), Look.COLOR_DAYLIGHT_BULB, 4.8, 5.2)


func _ceiling_light(at: Vector3, color: Color, energy: float, range_m: float) -> Light3D:
	var pos := at + Vector3(0.0, WALL_H - 0.16, 0.0)
	_mesh(Vector3(0.46, 0.1, 0.28), pos + Vector3(0.0, 0.095, 0.0), _mat_metal, "LightHousing")
	return Look.lamp(self, pos, color, energy, range_m, &"spot", null, false, 0.75, 0.1, 64.0)


## ---------------- builders ----------------

func _sign(text: String, pos: Vector3, color: Color, rot_y: float = 0.0) -> void:
	var label := _label(text, pos, color, rot_y, 0.0033)
	var plate: BoxMesh = BoxMesh.new()
	var width: float = ThemeDB.fallback_font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, label.font_size).x
	plate.size = Vector3(width * label.pixel_size + 0.42, 0.53, 0.06)
	var forward: Vector3 = Vector3(sin(deg_to_rad(rot_y)), 0.0, cos(deg_to_rad(rot_y)))
	var board: MeshInstance3D = MeshInstance3D.new()
	board.mesh = plate
	board.material_override = Look.sign_backing()
	board.position = pos - forward * 0.09
	board.rotation_degrees = label.rotation_degrees
	board.name = "SignBoard"
	board.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	board.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	add_child(board)


func _label(text: String, pos: Vector3, color: Color, rot_y: float, pixel_size: float) -> Label3D:
	var label := Label3D.new()
	label.text = text
	label.position = pos
	label.rotation_degrees.y = rot_y
	Look.style_sign(label, color, 80, pixel_size)
	add_child(label)
	return label


func _box(size: Vector3, pos: Vector3, material: Material, node_name: String) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.name = node_name
	body.collision_layer = 1
	body.collision_mask = 0
	var mesh := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = size
	mesh.mesh = box
	mesh.material_override = Surfaces.for_size(material, size)
	body.add_child(mesh)
	var shape := CollisionShape3D.new()
	var box_shape := BoxShape3D.new()
	box_shape.size = size
	shape.shape = box_shape
	body.add_child(shape)
	body.position = pos
	add_child(body)
	return body


## Decor without collision: bottles, napkins, panes - things nobody needs to bump into.
func _mesh(size: Vector3, pos: Vector3, material: Material, node_name: String) -> MeshInstance3D:
	var mesh := MeshInstance3D.new()
	mesh.name = node_name
	var box := BoxMesh.new()
	box.size = size
	mesh.mesh = box
	mesh.material_override = Surfaces.for_size(material, size)
	mesh.position = pos
	add_child(mesh)
	return mesh


func _mesh_sphere(radius: float, pos: Vector3, material: Material, node_name: String) -> void:
	var mesh := MeshInstance3D.new()
	mesh.name = node_name
	var sphere := SphereMesh.new()
	sphere.radius = radius
	sphere.height = radius * 2.0
	sphere.radial_segments = 8
	sphere.rings = 4
	mesh.mesh = sphere
	mesh.material_override = material
	mesh.position = pos
	add_child(mesh)


func _cyl(radius: float, height: float, pos: Vector3, material: Material, node_name: String) -> void:
	var mesh := MeshInstance3D.new()
	mesh.name = node_name
	var cyl := CylinderMesh.new()
	cyl.top_radius = radius
	cyl.bottom_radius = radius
	cyl.height = height
	cyl.radial_segments = 8
	mesh.mesh = cyl
	mesh.material_override = material
	mesh.position = pos
	add_child(mesh)


func _make_materials() -> void:
	# A dining room is the most patterned place in the game: checkered floor, brick behind the
	# bar, painted plaster, wood tables. Each one gets its scale from Surfaces so a table top
	# and a wall do not share a brick size.
	_mat_floor = _slab_material(Surfaces.Kind.TILE, Color(0.62, 0.58, 0.52), 0.45)
	_mat_ceiling = _slab_material(Surfaces.Kind.PANEL, Color(0.72, 0.68, 0.60), 0.95)
	_mat_plaster = _mat(Surfaces.Kind.PLASTER, Color(0.62, 0.54, 0.40, 1.0), 0.9)
	_mat_brick = _mat(Surfaces.Kind.BRICK, Color(0.50, 0.26, 0.20, 1.0), 0.9)
	_mat_wood = _mat(Surfaces.Kind.WOOD, Color(0.40, 0.28, 0.18, 1.0), 0.72)
	_mat_chair = _mat(Surfaces.Kind.WOOD, Color(0.47, 0.32, 0.20, 1.0), 0.72)
	_mat_seat = _mat(Surfaces.Kind.GRIME, Color(0.18, 0.34, 0.22, 1.0), 0.85)
	_mat_glass = _mat(Surfaces.Kind.METAL, Color(0.05, 0.08, 0.1, 1.0), 0.2)
	_mat_curtain = _mat(Surfaces.Kind.PLASTER, Color(0.74, 0.66, 0.48, 1.0), 0.95)
	_mat_metal = _mat(Surfaces.Kind.METAL, Color(0.28, 0.28, 0.30, 1.0), 0.55)
	_mat_red = _mat(Surfaces.Kind.PLASTER, Color(0.58, 0.13, 0.11, 1.0), 0.8)
	# The pendant globes are the brightest thing in the room, and glow only blooms what
	# actually emits: without them the pizzeria reads as a dim box no matter the light energy.
	_mat_globe = Look.bulb(Color(1.0, 0.86, 0.66, 1.0), 5.5)
	_mat_panel = _mat(Surfaces.Kind.PANEL, Color(0.72, 0.68, 0.60, 1.0), 0.95)
	_mat_curtain_red = _mat(Surfaces.Kind.PLASTER, Color(0.44, 0.07, 0.07, 1.0), 0.95)
	_mat_gold = _mat(Surfaces.Kind.METAL, Color(0.62, 0.46, 0.16, 1.0), 0.45, 0.4)
	_mat_hat = _mat(Surfaces.Kind.PLASTER, Color(0.75, 0.24, 0.55, 1.0), 0.85)
	# The costumes are the only soft thing in the game: matte, slightly dusty, and dark
	# enough that the room decides how threatening they look.
	_mat_fur_bear = _mat(Surfaces.Kind.GRIME, Color(0.45, 0.32, 0.22), 0.95)
	_mat_fur_rabbit = _mat(Surfaces.Kind.GRIME, Color(0.52, 0.50, 0.46, 1.0), 0.95)
	_mat_fur_fox = _mat(Surfaces.Kind.GRIME, Color(0.52, 0.26, 0.12, 1.0), 0.95)
	_mat_fur_bird = _mat(Surfaces.Kind.GRIME, Color(0.69, 0.52, 0.17), 0.95)
	_mat_office = _mat(Surfaces.Kind.PLASTER, Color(0.47, 0.53, 0.51), 0.9)
	_mat_cove = _mat(Surfaces.Kind.PLASTER, Color(0.43, 0.24, 0.41), 0.95)
	_mat_eye = Look.bulb(Color(0.92, 0.95, 1.0, 1.0), 1.6)
	_mat_crust = _mat(Surfaces.Kind.WOOD, Color(0.76, 0.58, 0.30, 1.0), 0.85)
	_mat_sauce = _mat(Surfaces.Kind.GRIME, Color(0.66, 0.16, 0.11, 1.0), 0.7)
	_mat_pepperoni = _mat(Surfaces.Kind.GRIME, Color(0.52, 0.13, 0.10, 1.0), 0.75)
	_mat_paper = _mat(Surfaces.Kind.PLASTER, Color(0.80, 0.78, 0.72, 1.0), 0.9)
	_mat_trash = _mat(Surfaces.Kind.METAL, Color(0.15, 0.15, 0.16, 1.0), 0.6, 0.3)
	_mat_balloon = _mat(Surfaces.Kind.PLASTER, Color(0.74, 0.16, 0.36, 1.0), 0.45)


func _mat(kind: int, color: Color, rough: float, metallic := 0.0) -> StandardMaterial3D:
	return Surfaces.mat(kind as Surfaces.Kind, color, rough, metallic)


func _slab_material(kind: Surfaces.Kind, color: Color, rough: float) -> StandardMaterial3D:
	# Keep the existing tile textures on the same grid across adjoining floor and ceiling slabs.
	var material := Surfaces.mat(kind, color, rough).duplicate() as StandardMaterial3D
	material.uv1_triplanar = true
	material.uv1_world_triplanar = true
	material.uv1_scale = Vector3.ONE / float(Surfaces.METERS[kind])
	return material
