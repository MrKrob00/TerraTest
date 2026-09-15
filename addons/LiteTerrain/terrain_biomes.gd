@tool
class_name TerrainBiomes
extends Resource

## The single source of truth for biomes: the landform generator (plugin.gd), the CPU-side
## masks (map.gd) and the material colours all read from here, so a biome's colour cannot
## drift away from its terrain.
##
## A biome is a 0..1 MASK of world-XZ noise. Layers stack in this order:
##   base DESERT ↔ MEADOW split  →  CANYON on top  →  MOUNTAINS on top.
## A disabled layer yields a zero mask and disappears from both the colour and the landform.
##
## Settings alone cannot add a biome of your own: each layer's colour is written out in
## glsl.gdshader (vertex(), where v_base_col is assembled), so a new layer means editing the
## shader as well as adding its mask here.

# ── Base land split: DESERT ↔ MEADOW ──────────────────────────────────────────
@export_group("Desert / Meadow")
## Biome patch size in world units. Smaller fits several biomes on screen at once.
@export_range(30.0, 1000.0, 1.0) var biome_scale: float = 230.0
## Split threshold: above 0.5 gives more sand, below it more meadow.
@export_range(0.0, 1.0, 0.01) var biome_bias: float = 0.5
## Transition width. Narrower gives a crisp border instead of a muddle.
@export_range(0.02, 0.5, 0.01) var biome_blend: float = 0.07
## Noise contrast stretched before the threshold: higher packs the patches and hardens edges.
@export_range(0.5, 4.0, 0.1) var biome_contrast: float = 1.8
@export var color_sand: Color = Color(0.87, 0.74, 0.49)
@export var color_grass: Color = Color(0.33, 0.56, 0.23)
## Dune ridge height, m (landform only, used by the generator).
@export_range(0.0, 40.0, 0.5) var dune_amp: float = 9.0
## Dune ridge wavelength, m.
@export_range(5.0, 200.0, 1.0) var dune_wavelength: float = 34.0
## How far to flatten hills in the desert: 0 is a table, 1 is as hilly as the meadow.
@export_range(0.0, 1.0, 0.05) var desert_flatten: float = 0.4

# ── CANYON ────────────────────────────────────────────────────────────────────
@export_group("Canyon")
## A disabled biome shows up neither in the colour nor in the landform.
@export var canyon_enabled: bool = true
@export_range(30.0, 1000.0, 1.0) var canyon_scale: float = 250.0
## Higher threshold means rarer canyons.
@export_range(0.0, 1.0, 0.01) var canyon_threshold: float = 0.70
## Narrower edge means a steeper outer wall.
@export_range(0.02, 0.5, 0.01) var canyon_edge: float = 0.05
@export var color_canyon: Color = Color(0.70, 0.30, 0.15)
## Height of one colour stratum. Must match the geometry terrace or the banding slides
## along the wall.
@export_range(2.0, 12.0, 0.5) var canyon_band_height: float = 6.0
## Scale of the mesa-height variation — the large buttes (landform only).
@export_range(20.0, 400.0, 1.0) var canyon_butte_scale: float = 110.0

# ── MOUNTAINS ─────────────────────────────────────────────────────────────────
@export_group("Mountains")
@export var mountain_enabled: bool = true
@export_range(30.0, 1500.0, 1.0) var mountain_scale: float = 420.0
@export_range(0.0, 1.0, 0.01) var mountain_threshold: float = 0.72
@export_range(0.02, 0.5, 0.01) var mountain_edge: float = 0.05
## Mountain height, m (landform only, used by the generator).
@export_range(0.0, 300.0, 1.0) var mountain_rise: float = 48.0

# ── Snow and rock ─────────────────────────────────────────────────────────────
# Snow follows the MOUNTAIN biome rather than altitude: the colour comes from its mask.
@export_group("Snow / rock")
@export var color_snow: Color = Color(0.94, 0.96, 1.00)
## FROM WHAT HEIGHT SNOW LIES, as a SHARE OF THE WORLD'S HEIGHT, and how soft that line is. The
## mountain mask says WHERE the mountain region is, but says nothing about how far the ground
## actually rose there: snow painted from the mask alone landed as white patches on flat ground
## inside the region.
##
## A SHARE, not metres, and this is the whole point of these two fields. Metres held here meant a
## number that only made sense next to the Height that produced it - and that Height is not in this
## resource. So the generator "helpfully" overwrote the metres on every run: a slider you could drag
## that moved back, an output stored in an input, a scene diff after every Generate, and a value
## that reached the shader once and was wrong ever after for any world that did not run the
## generator at load (see map._push_biomes_to_materials, which now does the arithmetic).
@export_range(0.0, 1.5, 0.01) var snow_frac: float = 0.55
@export_range(0.01, 0.6, 0.01) var snow_blend_frac: float = 0.12
## The softest the snow line may be, in metres. On a low world the fraction alone gives a line so
## sharp it reads as a cut-out.
const SNOW_BLEND_MIN := 8.0

## The two in metres, for a world of this Height. One door: the shader, the props and anything else
## asking "where does snow start" go through here.
func snow_line_at(world_height: float) -> float:
	return world_height * snow_frac

func snow_blend_at(world_height: float) -> float:
	return maxf(world_height * snow_blend_frac, SNOW_BLEND_MIN)
@export var color_rock: Color = Color(0.40, 0.41, 0.43)
## How steep a slope has to be before the surface turns to rock.
@export_range(0.0, 1.0, 0.01) var rock_threshold: float = 0.7
@export_range(0.0, 0.5, 0.01) var rock_blend: float = 0.15

# ── Grass ─────────────────────────────────────────────────────────────────────
@export_group("Grass")
@export_range(0.0, 1.0, 0.01) var grass_density: float = 0.4
@export_range(0.0, 1.0, 0.01) var grass_height: float = 0.15
## How much grass the DESERT gets relative to the meadow. 0 is dry sand. Rock, canyon and
## mountains never carry grass.
@export_range(0.0, 0.5, 0.01) var sand_grass: float = 0.0
## Below 0.65 the grass is slightly darker than the ground — a soft shadow at the root
## rather than a bright patch.
@export_range(0.4, 1.2, 0.01) var grass_shade: float = 0.62

# ── Masks (the same maths the shader assumes) ─────────────────────────────────
# Each layer samples the noise at its own offset, otherwise canyons and mountains would
# land on one and the same patch.
const CANYON_OFFSET := Vector2(101.0, 53.0)
const MOUNTAIN_OFFSET := Vector2(211.0, 77.0)

## WHERE THE BIOMES SIT, moved by the SEED. The masks come from a hash-based value noise with
## fixed constants, so without this every seed produced new hills in exactly the same desert,
## with the canyon in exactly the same corner — the world changed shape but not geography.
##
## It lives in the RESOURCE and not in the generator because two different places read these
## masks: the generator carves the landform by them, and the terrain colours and ore veins by
## the same call at runtime. One offset, one answer, no way for them to disagree.
@export var mask_offset: Vector2 = Vector2.ZERO

## THE NOISE THE MASKS ARE BUILT ON, in one place. Every mask above takes it as a Callable because
## its callers used to each carry their own copy of these eight lines - the generator, the map, the
## menu backdrop - and a copy is how the painted region and the carved region drifted apart once
## already. `biomes.noise` below is that Callable; pass it unless you are the shader.
static func cv_noise(p: Vector2) -> float:
	var i := Vector2(floor(p.x), floor(p.y))
	var f := p - i
	f = f * f * (Vector2(3.0, 3.0) - 2.0 * f)
	var a := _cv_hash2d(i)
	var b := _cv_hash2d(i + Vector2(1.0, 0.0))
	var c := _cv_hash2d(i + Vector2(0.0, 1.0))
	var d := _cv_hash2d(i + Vector2(1.0, 1.0))
	return lerpf(lerpf(a, b, f.x), lerpf(c, d, f.x), f.y)

static func _cv_hash2d(p: Vector2) -> float:
	p = Vector2(_cv_fract(p.x * 123.34), _cv_fract(p.y * 456.21))
	var d: float = p.dot(p + Vector2(45.32, 45.32))
	p += Vector2(d, d)
	return _cv_fract(p.x * p.y)

static func _cv_fract(x: float) -> float:
	return x - floor(x)

## The same function as a Callable to hand to the masks. A static method cannot be passed by name
## in every Godot build; a method on the resource can.
func noise(p: Vector2) -> float:
	return cv_noise(p)

## Offset from a seed. Any deterministic spread does; this one just has to be far enough that
## neighbouring seeds do not overlap their patterns.
static func offset_for_seed(seed_value: int) -> Vector2:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	return Vector2(rng.randf_range(-4000.0, 4000.0), rng.randf_range(-4000.0, 4000.0))

## 0 is desert, 1 is meadow. wp is world XZ.
func meadow_mask(wp: Vector2, noise: Callable) -> float:
	var n: float = noise.call(wp / biome_scale + mask_offset)
	n = clampf((n - 0.5) * biome_contrast + 0.5, 0.0, 1.0)
	return smoothstep(biome_bias - biome_blend, biome_bias + biome_blend, n)

func canyon_mask(wp: Vector2, noise: Callable) -> float:
	if not canyon_enabled:
		return 0.0
	var n: float = noise.call(wp / canyon_scale + CANYON_OFFSET + mask_offset)
	return smoothstep(canyon_threshold - canyon_edge, canyon_threshold + canyon_edge, n)

func mountain_mask(wp: Vector2, noise: Callable) -> float:
	if not mountain_enabled:
		return 0.0
	var n: float = noise.call(wp / mountain_scale + MOUNTAIN_OFFSET + mask_offset)
	return smoothstep(mountain_threshold - mountain_edge, mountain_threshold + mountain_edge, n)

## The mountain dome — not the mask but its interior: it ramps up smoothly from the
## threshold to the peak, and the generator raises the landform by it so the slopes stay
## gentle enough to drive on.
func mountain_dome(wp: Vector2, noise: Callable) -> float:
	if not mountain_enabled:
		return 0.0
	var n: float = noise.call(wp / mountain_scale + MOUNTAIN_OFFSET + mask_offset)
	return smoothstep(mountain_threshold - mountain_edge, 0.95, n)

# ── Handing values to the shader ──────────────────────────────────────────────
## Writes the COLOURS and grass settings into the material's uniforms. Noise thresholds and
## scales do not go here: the CPU (map.gd) computes the biome masks and bakes them into the
## vertex COLOR, and the shader only reads those — which is why a disabled biome disappears
## on its own, with no flag in the shader.
##
## `world_height` is the Height the ground was generated with; the snow line is worked out from it
## here, because the shader compares against a world Y and needs metres. The caller knows the
## Height (map.world_height), this resource does not and must not guess.
func apply_to_material(mat: ShaderMaterial, world_height: float) -> void:
	if mat == null:
		return
	mat.set_shader_parameter("color_sand", color_sand)
	mat.set_shader_parameter("color_grass", color_grass)
	mat.set_shader_parameter("color_canyon", color_canyon)
	mat.set_shader_parameter("canyon_band_h", canyon_band_height)
	mat.set_shader_parameter("color_snow", color_snow)
	mat.set_shader_parameter("snow_line", snow_line_at(world_height))
	mat.set_shader_parameter("snow_blend", snow_blend_at(world_height))
	mat.set_shader_parameter("color_rock", color_rock)
	mat.set_shader_parameter("rock_threshold", rock_threshold)
	mat.set_shader_parameter("rock_blend", rock_blend)
	mat.set_shader_parameter("grass_density", grass_density)
	mat.set_shader_parameter("grass_height", grass_height)
	mat.set_shader_parameter("sand_grass", sand_grass)
	mat.set_shader_parameter("grass_shade", grass_shade)
