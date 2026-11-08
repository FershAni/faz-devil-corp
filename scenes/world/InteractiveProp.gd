class_name InteractiveProp
extends Node3D
## Authored metadata and replicated presentation for one fixed pizzeria installation.
## DaytimeManager owns mutations and RPCs. Props use stable IDs so a late join does
## not depend on node-spawn order or on a client supplying a scene path.

enum Kind { SEAT, ARCADE, NEON, ANIMATRONIC }

@export var prop_id: int = 0
@export var display_name: String = ""
@export var kind: Kind = Kind.SEAT
## Zero is reserved for the venue's starter furniture. Purchased items contribute
## Cozy points even when offline. Revenue is measured in game dollars per visit.
@export_range(0, 10000, 1) var price: int = 0
@export_range(0, 100, 1) var cozy_value: int = 0
@export_range(0, 1000, 1) var revenue_generation: int = 0
@export_range(0, 1000, 1) var maintenance_penalty: int = 0
@export var approach_offset: Vector3 = Vector3.ZERO
@export var interaction_offset: Vector3 = Vector3.UP
@export var status_light: MeshInstance3D

var installed: bool = false
var damaged: bool = false
var reserved_by: int = 0

var _indicator: StandardMaterial3D
var _pulse: float = 0.0


func _ready() -> void:
	if status_light != null:
		_indicator = Look.bulb(Color.WHITE, 1.0)
		status_light.material_override = _indicator
	set_process(false)


func apply_installation(owned: bool, broken: bool) -> void:
	installed = price == 0 or owned
	damaged = installed and broken
	visible = installed
	# Purchasable scenes use a dedicated collision subtree. Hidden props must never
	# leave an invisible obstacle behind. Deferred mode is safe during physics queries.
	var collision: Node3D = get_node_or_null("Collision") as Node3D
	if collision != null:
		var mode: ProcessMode = Node.PROCESS_MODE_INHERIT if installed else Node.PROCESS_MODE_DISABLED
		if collision.process_mode != mode:
			collision.set_deferred("process_mode", mode)
	if _indicator != null:
		var color: Color = Color(1.0, 0.16, 0.06) if damaged else Color(0.24, 0.86, 0.57)
		_indicator.albedo_color = color
		_indicator.emission = color
		_indicator.emission_energy_multiplier = 1.0
	set_process(damaged and kind == Kind.ARCADE and _indicator != null)


func _process(delta: float) -> void:
	_pulse += delta
	# A malfunction flashes the cabinet's diagnostic screen on every peer.
	_indicator.emission_energy_multiplier = 0.35 + 1.9 * pow(absf(sin(_pulse * 19.0)), 6.0)


func customer_position() -> Vector3:
	return to_global(approach_offset)


func interaction_position() -> Vector3:
	return to_global(interaction_offset)


func accepts_customer() -> bool:
	return installed and not damaged and reserved_by == 0 \
		and kind in [Kind.SEAT, Kind.ARCADE]


func payout() -> int:
	return revenue_generation if installed and not damaged else 0
