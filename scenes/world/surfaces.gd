class_name Surfaces
extends RefCounted

## Every wall, floor and prop in the game used to be one flat color, and that is the single
## biggest reason the frames looked like a prototype: light hits a flat albedo, the dither
## post smears what little contrast there was, and a 4 m wall becomes an empty brown field.
##
## These textures are generated in code at startup - no asset files, no import step, nothing
## to lose - and drawn to be tileable so a corridor wall and a room wall share one texture
## and still batch. The patterns are deliberately coarse (brick, tile, panel seams) because
## the game reads shapes, not detail: the pixel grid in the post shader throws away anything
## finer than about 4 texels.

enum Kind { CONCRETE, PLASTER, BRICK, TILE, METAL, PANEL, WOOD, GRIME }

const SIZE := 128
## How wide one texture tile is in the world, per material: brick wants about a meter, the
## dining floor wants its checkers at half that, a concrete wall can afford two.
const METERS := {
	Kind.CONCRETE: 1.4, Kind.PLASTER: 1.6, Kind.BRICK: 0.55, Kind.TILE: 1.2,
	Kind.METAL: 1.0, Kind.PANEL: 1.2, Kind.WOOD: 0.9, Kind.GRIME: 1.4,
}
static var _cache: Dictionary = {}
static var _scaled: Dictionary = {}
static var _meters_by_mat: Dictionary = {}


## The one call sites use. BoxMesh maps each face's own size to 0..1, so a shared material
## cannot know how big its surface is: `scale_for()` sets uv1_scale per instance instead.
static func mat(kind: Kind, color: Color, rough: float, metallic: float = 0.0,
		baked_tint: bool = false) -> StandardMaterial3D:
	var key: String = "%d|%s|%.2f|%.2f|%d" % [kind, color.to_html(), rough, metallic, int(baked_tint)]
	if _cache.has(key):
		return _cache[key]
	var mat := StandardMaterial3D.new()
	# The procedural image already contains its palette tint.
	mat.albedo_color = Color.WHITE if baked_tint else color
	mat.roughness = rough
	mat.metallic = metallic
	mat.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC if baked_tint \
		else BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	var albedo := _image(kind, color)
	mat.albedo_texture = _texture(albedo, baked_tint)
	# Roughness variation is what makes a dirty wall read as dirty under a flashlight: a flat
	# roughness is a plastic wall, no matter what the albedo says.
	mat.roughness_texture = _texture(_roughness_image(kind, albedo), baked_tint)
	mat.roughness_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_RED
	# texture_repeat already defaults to enabled on Material, and 4.7 does not expose the
	# enum constant through BaseMaterial3D - setting it by name here would only break the build.
	_cache[key] = mat
	_meters_by_mat[mat.get_instance_id()] = float(METERS.get(kind, 2.0))
	return mat


## BoxMesh maps each face's own two axes to 0..1, so one isotropic repeat cannot fit a wall
## that is 18 m long and 3.4 m high: the courses collapse into stripes. The thin axis of the
## box is the one nobody sees (wall thickness, slab depth), so the two visible axes get their
## own repeat - 0.55 m of brick is 0.55 m of brick horizontally and vertically.
static func for_size(material: Material, size: Vector3) -> Material:
	if material == null or not _meters_by_mat.has(material.get_instance_id()):
		return material
	var meters := float(_meters_by_mat[material.get_instance_id()])
	var axes := [size.x, size.y, size.z]
	axes.sort()
	# The smallest dim is the hidden one; the other two are U and V of the visible faces.
	var u := 0.0
	var v := 0.0
	if axes[0] == size.x:
		u = size.z
		v = size.y
	elif axes[0] == size.y:
		u = size.x
		v = size.z
	else:
		u = size.x
		v = size.y
	var key := "%d|%.2f|%.2f" % [material.get_instance_id(), u / meters, v / meters]
	if _scaled.has(key):
		return _scaled[key]
	# Resources duplicate by reference for textures, so a clone shares both maps.
	var clone := material.duplicate() as StandardMaterial3D
	clone.uv1_scale = Vector3(maxf(u / meters, 0.2), maxf(v / meters, 0.2), 1.0)
	_scaled[key] = clone
	return clone


## A one-off panel for props that must not tile (signs, boards, posters).
static func panel_material(color: Color, emissive := 0.0) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = 0.6
	mat.metallic = 0.0
	mat.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	if emissive > 0.0:
		mat.emission_enabled = true
		mat.emission = color
		mat.emission_energy_multiplier = emissive
	return mat


static func _texture(image: Image, mipmaps: bool = false) -> ImageTexture:
	if mipmaps:
		image.generate_mipmaps()
	var tex: ImageTexture = ImageTexture.create_from_image(image)
	tex.resource_name = "procedural_%dx%d" % [image.get_width(), image.get_height()]
	return tex


static func _image(kind: Kind, base: Color) -> Image:
	var image := Image.create(SIZE, SIZE, false, Image.FORMAT_RGB8)
	var noise := FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.seed = 1337 + kind
	noise.frequency = 0.035
	var grit := FastNoiseLite.new()
	grit.noise_type = FastNoiseLite.TYPE_VALUE
	grit.seed = 900 + kind
	grit.frequency = 0.22
	for y in SIZE:
		for x in SIZE:
			var pair: Array = [1.0, Vector3.ZERO]
			match kind:
				Kind.BRICK:
					pair = _brick_at(x, y, noise)
				Kind.TILE:
					pair = _tile_at(x, y, noise)
				Kind.METAL:
					pair = _metal_at(x, y, noise, grit)
				Kind.PANEL:
					pair = _panel_at(x, y, noise)
				Kind.WOOD:
					pair = _wood_at(x, y, noise, grit)
				Kind.GRIME:
					pair = _grime_at(x, y, noise, grit)
				Kind.PLASTER:
					pair = _plaster_at(x, y, noise, grit)
				_:
					pair = _concrete_at(x, y, noise, grit)
			var shade := float(pair[0])
			var tint: Vector3 = pair[1]
			var painted := Color(
				clampf(base.r * shade + tint.x, 0.0, 1.0),
				clampf(base.g * shade + tint.y, 0.0, 1.0),
				clampf(base.b * shade + tint.z, 0.0, 1.0), 1.0)
			image.set_pixel(x, y, painted)
	return image


## Roughness comes from the albedo it was painted with: grout, rust and damp go rough,
## painted panels and metal stay smoother. One pass, no second noise field to tune.
static func _roughness_image(kind: Kind, albedo: Image) -> Image:
	var out := Image.create(SIZE, SIZE, false, Image.FORMAT_RGB8)
	for y in SIZE:
		for x in SIZE:
			var src := albedo.get_pixel(x, y)
			var luma := (src.r + src.g + src.b) / 3.0
			var rough := clampf(0.55 + (1.0 - luma) * 0.45, 0.0, 1.0)
			if kind == Kind.METAL or kind == Kind.TILE:
				rough = clampf(0.30 + (1.0 - luma) * 0.55, 0.0, 1.0)
			out.set_pixel(x, y, Color(rough, rough, rough, 1.0))
	return out


## ---------------- pattern math ----------------

static func _concrete_at(x: int, y: int, noise: FastNoiseLite,
		grit: FastNoiseLite) -> Array:
	var blotch := noise.get_noise_2d(x, y) * 0.07
	var sand := grit.get_noise_2d(x, y) * 0.025
	var crack := 1.0
	if absf(noise.get_noise_2d(x * 0.5, y * 0.5)) < 0.008:
		crack = 0.74
	return [1.0 + blotch + sand * crack, Vector3(-0.01, -0.005, -0.005)]


static func _plaster_at(x: int, y: int, noise: FastNoiseLite,
		grit: FastNoiseLite) -> Array:
	# Old paint over patchy skim: soft mottling, a darker tide line near the bottom of the
	# tile, and a little grit where somebody dragged something along the wall.
	var mottle := noise.get_noise_2d(x * 0.6, y * 0.6) * 0.05
	var band := 0.0
	if y > SIZE - 14:
		band = -0.12
	var scuff := grit.get_noise_2d(x, y * 3.0) * 0.018
	return [1.0 + mottle + band + scuff, Vector3(0.005, 0.0, -0.005)]


static func _brick_at(x: int, y: int, noise: FastNoiseLite) -> Array:
	# Two bricks and four courses per tile: at 0.55 m per tile that is a 27 x 14 cm unit,
	# which is what a wall is actually built out of. Denser than this and the courses stop
	# being bricks and become texture.
	var row := int(y / 32.0)
	var offset := 0 if row % 2 == 0 else 32
	var brick := int((x + offset) % 64)
	if y % 32 >= 28 or brick >= 60:
		# Mortar: pale, flat, slightly blue-gray - it has to read as a line, not a smudge.
		return [1.30, Vector3(0.14, 0.13, 0.12)]
	var jitter := 0.94 + absf(noise.get_noise_2d(floorf(x / 64.0) * 40.0, row * 40.0)) * 0.12
	return [jitter, Vector3(0.02, -0.005, -0.01)]


static func _tile_at(x: int, y: int, noise: FastNoiseLite) -> Array:
	var cell := (int(x / 32.0) + int(y / 32.0)) % 2
	var grout := x % 32 < 2 or y % 32 < 2
	if grout:
		return [0.34, Vector3(0.0, 0.0, 0.0)]
	# The checkered dining-room floor is the FNaF signature; wear it so it is not a chess board.
	var wear := noise.get_noise_2d(x * 0.4, y * 0.4) * 0.04
	return [(1.0 + wear) * (1.0 if cell == 0 else 0.34), Vector3(0.0, -0.004, -0.008)]


static func _metal_at(x: int, y: int, noise: FastNoiseLite, grit: FastNoiseLite) -> Array:
	var brushed := sin(y * 1.9) * 0.012 + grit.get_noise_2d(x * 0.4, y * 2.0) * 0.02
	var rust := noise.get_noise_2d(x * 0.7, y * 0.7)
	var tint := Vector3.ZERO
	if rust > 0.52:
		# Rust eats the sheen and pushes orange: the streaks are where water ran down a panel.
		tint = Vector3(0.16, 0.05, -0.02)
		return [0.78 + brushed, tint]
	var seam := 1.0
	if x % 64 < 1 or y % 64 < 1:
		seam = 0.66
	var rivet := 1.0
	if (x % 64 == 8 or x % 64 == 56) and (y % 64 == 8 or y % 64 == 56):
		rivet = 1.25
	return [0.94 + brushed, Vector3(-0.01, -0.005, 0.0) * seam + Vector3(rivet - 1.0, rivet - 1.0, rivet - 1.0)]


static func _panel_at(x: int, y: int, noise: FastNoiseLite) -> Array:
	var seam := 1.0
	if x % 64 < 2 or y % 64 < 2:
		seam = 0.48
	var per_panel := noise.get_noise_2d(floorf(x / 64.0) * 30.0, floorf(y / 64.0) * 30.0) * 0.035
	var stain := 0.0
	if noise.get_noise_2d(x * 0.2, y * 0.2) > 0.72:
		stain = -0.10
	return [(0.95 + per_panel + stain) * seam, Vector3(0.0, -0.01, -0.02)]


static func _wood_at(x: int, y: int, noise: FastNoiseLite, grit: FastNoiseLite) -> Array:
	var grain := sin((y + noise.get_noise_2d(x * 0.3, y * 0.3) * 6.0) * 0.7) * 0.045
	var board := 1.0
	if y % 42 < 1:
		board = 0.6
	return [(0.98 + grain + grit.get_noise_2d(x, y) * 0.012) * board,
		Vector3(0.015, 0.004, -0.008)]


static func _grime_at(x: int, y: int, noise: FastNoiseLite, grit: FastNoiseLite) -> Array:
	# Damp, soot and floor traffic: mostly dark blotches with a few lighter scratch lines.
	var damp := noise.get_noise_2d(x * 0.5, y * 0.5)
	var value := 0.92 + damp * 0.12
	if damp > 0.55:
		value -= 0.13
	return [value + grit.get_noise_2d(x * 2.0, y * 0.6) * 0.02, Vector3(-0.01, -0.005, 0.005)]
