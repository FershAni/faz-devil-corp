class_name Look
extends RefCounted

## The whole picture lives here: two color grades (the warm pizzeria day and the cold night),
## the lamp and bulb materials, and the common rules for wayfinding signs. One place to tune,
## one place for the graphics settings to write into later.
##
## Numbers are measured, not guessed: every capture run prints draw calls and fps, and the
## cost of glow / SSAO / volumetric fog is known per effect from the lighting skill.

const NIGHT := &"night"
const HUB := &"hub"
const MENU := &"menu"

## Light colors. Sodium and tungsten warm, industrial cyan cold - the two families the game
## cuts between, so a room always reads as "habitable" or "abandoned" before you see it.
const COLOR_SODIUM := Color(1.00, 0.62, 0.28)
const COLOR_TUNGSTEN := Color(1.00, 0.80, 0.55)
const COLOR_DAYLIGHT_BULB := Color(1.00, 0.92, 0.80)
const COLOR_COLD_INDUSTRIAL := Color(0.52, 0.66, 0.82)
const COLOR_SICKLY_GREEN := Color(0.55, 0.85, 0.66)
const COLOR_EMERGENCY := Color(1.00, 0.28, 0.20)


## ---------------- environments ----------------

static func night() -> Environment:
	var env := Environment.new()
	_put(env, "background_mode", 1)
	_put(env, "background_color", Color(0.006, 0.010, 0.016, 1.0))
	_put(env, "ambient_light_source", 2)
	_put(env, "ambient_light_color", Color(0.63, 0.68, 0.74, 1.0))
	_put(env, "ambient_light_energy", 0.76)
	_put(env, "tonemap_mode", 4)          # AgX: a sodium bulb stays orange, not yellow-white
	_put(env, "tonemap_exposure", 1.34)
	_put(env, "tonemap_white", 4.0)
	_apply_fog(env, Color(0.12, 0.15, 0.19, 1.0), 0.0055, 0.0)
	# Keep the floor haze dark. The colder volume catches the practicals and flashlights.
	_apply_volumetric_fog(env, 0.0055, Color(0.48, 0.55, 0.61, 1.0))
	env.volumetric_fog_length = 32.0
	env.volumetric_fog_detail_spread = 2.5
	env.volumetric_fog_gi_inject = 0.25
	env.sdfgi_enabled = RenderingServer.get_current_rendering_method() == "forward_plus"
	env.sdfgi_cascades = 3
	env.sdfgi_min_cell_size = 0.18
	env.sdfgi_use_occlusion = true
	env.sdfgi_read_sky_light = false
	env.sdfgi_energy = 0.60
	env.sdfgi_bounce_feedback = 0.25
	_apply_glow(env, 0.10, 0.25, 0.0, 4.5, 1.0)
	_apply_ssao(env, 0.72, 0.50, 0.05)
	_put(env, "adjustment_enabled", true)
	_put(env, "adjustment_contrast", 1.0)
	_put(env, "adjustment_saturation", 0.94)
	_put(env, "adjustment_brightness", 1.0)
	return env


static func hub() -> Environment:
	var env := Environment.new()
	_put(env, "background_mode", 1)
	_put(env, "background_color", Color(0.030, 0.020, 0.014, 1.0))
	_put(env, "ambient_light_source", 2)
	_put(env, "ambient_light_color", Color(0.95, 0.82, 0.68, 1.0))
	# The dining room is the only place the crew is safe: warm, readable, a little too sweet.
	_put(env, "ambient_light_energy", 0.62)
	_put(env, "tonemap_mode", 4)
	_put(env, "tonemap_exposure", 1.42)
	_put(env, "tonemap_white", 3.0)
	_apply_fog(env, Color(0.10, 0.06, 0.04, 1.0), 0.004, 0.0)
	_apply_volumetric_fog(env, 0.0022, Color(1.0, 0.80, 0.58, 1.0))
	_apply_glow(env, 0.17, 0.30, 0.0, 3.8, 0.9)
	_apply_ssao(env, 0.85, 0.7, 0.20)
	_put(env, "adjustment_enabled", true)
	_put(env, "adjustment_contrast", 1.05)
	_put(env, "adjustment_saturation", 1.06)
	_put(env, "adjustment_brightness", 1.02)
	return env


static func menu() -> Environment:
	var env: Environment = night()
	env.sdfgi_enabled = false
	# The menu is the night with the lights left on: same cold grade, but the room has to be
	# legible behind the buttons and the lamp shaft is what sells the place.
	_put(env, "ambient_light_energy", 0.50)
	_put(env, "tonemap_exposure", 1.62)
	_put(env, "volumetric_fog_density", 0.005)
	_put(env, "glow_intensity", 0.32)
	_put(env, "adjustment_saturation", 0.96)
	return env


static func apply(world_env: WorldEnvironment, which: StringName) -> void:
	if world_env == null:
		return
	# Environment is RefCounted: swapping the pointer is the release. Calling free() on it
	# is an error, and the old grade would have been freed twice.
	if which == HUB:
		world_env.environment = hub()
	elif which == MENU:
		world_env.environment = menu()
	else:
		world_env.environment = night()


## ---------------- materials ----------------

## The glass of a bulb: unshaded enough to keep its color, emissive enough to feed glow.
## Without a real emitter in the picture glow has nothing to bloom and lamps read as flat
## white boxes - which is exactly what the first night captures showed.
static func bulb(color: Color, energy := 4.0) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = color
	mat.emission_enabled = true
	mat.emission = color
	mat.emission_energy_multiplier = energy
	return mat


static func matte(color: Color, rough := 0.9) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.metallic = 0.0
	mat.roughness = clampf(rough, 0.05, 1.0)
	mat.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	return mat


## Painted sign panel: a colored board with a dark border, lit by the room and glowing a
## little on its own, the way enamel signage behaves under tungsten light.
static func sign_board(color: Color, emissive := 0.55) -> StandardMaterial3D:
	var mat := matte(color, 0.55)
	mat.roughness = 0.35
	mat.metallic = 0.0
	mat.emission_enabled = true
	mat.emission = color
	mat.emission_energy_multiplier = emissive
	return mat


## ---------------- lights ----------------

## A practical lamp: fixture above, emitter below, light at the emitter. Every lamp in the
## game goes through this so no bulb ever floats or hides inside its own housing.
static func lamp(parent: Node3D, at: Vector3, color: Color, energy: float, range_m: float,
		kind := &"omni", fixture: Mesh = null, casts_shadow := false,
		attenuation := 0.7, fog_energy := -1.0, angle := 70.0) -> Light3D:
	var light: Light3D = OmniLight3D.new() if kind == &"omni" else SpotLight3D.new()
	light.position = at
	light.light_color = color
	light.light_energy = energy
	if light is OmniLight3D:
		(light as OmniLight3D).omni_range = range_m
		(light as OmniLight3D).omni_attenuation = attenuation
	else:
		var spot := light as SpotLight3D
		spot.spot_range = range_m
		spot.spot_angle = angle
		spot.spot_attenuation = attenuation
		# A spot pointing straight down needs to be told what it lights, or the cone misses.
		spot.rotation_degrees = Vector3(-90.0, 0.0, 0.0)
	light.shadow_enabled = casts_shadow
	# A cone of fog reads as a beam; an omni ball of fog reads as a glowing bubble. The hero
	# lamp of a room is the one that gets the beam, and only the beam is allowed to be thick.
	_put(light, "light_volumetric_fog_energy",
		fog_energy if fog_energy >= 0.0 else (1.2 if casts_shadow else 0.18))
	parent.add_child(light)
	# The bulb is a small, only mildly emissive bead: a bright unshaded sphere at 3.2 turned
	# every lamp into a glowing ball that swallowed the room, because glow blooms pixels, not
	# lights, and the frame is mostly those pixels.
	var bulb_mesh := MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = 0.055
	sphere.height = 0.11
	sphere.radial_segments = 8
	sphere.rings = 4
	bulb_mesh.mesh = sphere
	bulb_mesh.material_override = bulb(color.lightened(0.45), 1.1)
	bulb_mesh.position = at
	parent.add_child(bulb_mesh)
	if fixture != null:
		var holder := MeshInstance3D.new()
		holder.mesh = fixture
		holder.position = at + Vector3(0.0, 0.16, 0.0)
		parent.add_child(holder)
	return light


## Stress keeps its atmospheric cue through the environment. The camera and signs retain
## their native spatial detail, and the 2D HUD is outside the 3D color grade.
static func apply_stress(env: Environment, sanity: float) -> void:
	if env != null:
		env.adjustment_saturation = lerpf(0.72, 0.94, clampf(sanity / 100.0, 0.0, 1.0))


static var _sign_backing: StandardMaterial3D


static func sign_backing() -> StandardMaterial3D:
	if _sign_backing == null:
		_sign_backing = StandardMaterial3D.new()
		_sign_backing.albedo_color = Color(0.035, 0.055, 0.075)
		_sign_backing.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	return _sign_backing


static func style_sign(label: Label3D, ink: Color, font_px: int, meters_per_px: float) -> void:
	label.font_size = font_px
	label.pixel_size = meters_per_px
	label.modulate = ink
	label.outline_size = 5
	label.outline_modulate = Color(0.016, 0.024, 0.033)
	label.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	label.shaded = false
	label.double_sided = false


## The player's own lamp: warm, narrow, and the one light in the night that must show its
## beam in the fog. Called on every Player instance, host and remote, so a teammate walking
## towards you is a cone of dust before it is a face.
static func beam(light: SpotLight3D) -> void:
	light.light_color = Color(1.00, 0.92, 0.78)
	light.spot_range = 26.0
	light.spot_angle = 30.0
	_put(light, "light_volumetric_fog_energy", 1.5)


## ---------------- internals ----------------

static func _apply_fog(env: Environment, color: Color, density: float, sky_affect: float) -> void:
	_put(env, "fog_enabled", true)
	_put(env, "fog_light_color", color)
	_put(env, "fog_light_energy", 1.0)
	_put(env, "fog_density", density)
	_put(env, "fog_sky_affect", sky_affect)
	# Fog thicker near the floor: corridors read as damp, and the ceiling stays lost in dark.
	_put(env, "fog_height", 0.0)
	_put(env, "fog_height_density", 2.2)
	_put(env, "fog_aerial_perspective", 0.0)


static func _apply_volumetric_fog(env: Environment, density: float, albedo: Color) -> void:
	if RenderingServer.get_current_rendering_method() != "forward_plus":
		return
	_put(env, "volumetric_fog_enabled", true)
	_put(env, "volumetric_fog_density", density)
	_put(env, "volumetric_fog_albedo", albedo)
	# 0.7 is the god-ray number: forward scattering makes the beam visible instead of a haze.
	# 0.7 is the god-ray number, but seen from under a ceiling lamp it paints a white
	# bar across the frame; 0.5 keeps the cone and loses the strip.
	_put(env, "volumetric_fog_anisotropy", 0.5)
	_put(env, "volumetric_fog_length", 48.0)
	_put(env, "volumetric_fog_detail_spread", 4.0)


static func _apply_glow(env: Environment, intensity: float, strength: float, bloom: float,
		hdr_threshold: float, hdr_scale: float) -> void:
	_put(env, "glow_enabled", true)
	# 4.6 changed these defaults; without a retune a pre-4.6 scene blooms like a soap opera.
	_put(env, "glow_normalized", true)
	_put(env, "glow_blend_mode", 0)
	_put(env, "glow_intensity", intensity)
	_put(env, "glow_strength", strength)
	_put(env, "glow_bloom", bloom)
	_put(env, "glow_hdr_threshold", hdr_threshold)
	_put(env, "glow_hdr_scale", hdr_scale)
	# 2/4/7 is the classic mix: a tight halo on the bulb, a mid bloom on the beam, and a wide
	# wash that makes a lit doorway readable from the far end of a corridor.
	for level in [2, 4, 7]:
		_put(env, "glow_levels/%d" % level, true)


static func _apply_ssao(env: Environment, radius: float, intensity: float,
		light_affect: float) -> void:
	if RenderingServer.get_current_rendering_method() == "mobile":
		return
	_put(env, "ssao_enabled", true)
	_put(env, "ssao_radius", radius)
	_put(env, "ssao_intensity", intensity)
	_put(env, "ssao_power", 1.0)
	_put(env, "ssao_detail", 2.0)
	# SSAO only touches ambient by default (0.0), which is why it often looks like nothing
	# happened; in a dim game most of the visible light IS ambient, so it must bite.
	_put(env, "ssao_light_affect", light_affect)


static var _property_cache: Dictionary = {}


## Sets a property only if this Godot build actually has it, so a renamed 4.x property is a
## silent skip instead of an error that aborts the rest of the function (that trap cost a
## null environment once: one bad assignment killed everything after it).
static func _put(target: Object, key: String, value: Variant) -> bool:
	var names: Array = _property_cache.get(target.get_class(), [])
	if names.is_empty():
		for entry in target.get_property_list():
			names.append(String(entry["name"]))
		_property_cache[target.get_class()] = names
	if not names.has(key):
		push_warning("Look: %s has no property %s in this build" % [target.get_class(), key])
		return false
	target.set(key, value)
	return true
