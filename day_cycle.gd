extends Node
# DAY AND NIGHT (the player: "no clouds and no day/night - add something cheap but pretty"). Nothing
# here costs a pass: the sun is the scene's one DirectionalLight3D, turned; at night the same light
# is the MOON (dim, blue, from the other side), so there is never a second shadowed light; the sky
# is sky.gdshader, fed three uniforms; and THE NIGHT IS `tonemap_exposure`. That is the one dimmer
# that reaches the BLOCKS: they are unshaded and no light ever touches them, so a night made of light
# alone darkened the ground under bright white machines. Exposure runs in every material's own
# tonemap, unshaded included - measured on the real driver, 0.45 took a cabin from 0.20 to 0.07 -
# so it adds no full-screen pass (a multiply overlay would, on a fill-bound phone).
#
# SHADOWS ARE NOT BLACK (the player's other complaint): `shadow_opacity` leaves a share of the sun in
# them, and the ambient colour lifts the rest - with ambient 0.15 a shadow was the ground at 15%.
#
# The cycle is memory only: every session starts in the morning. On the proving ground it stands at
# noon, where a test should not depend on the hour.

@export var day_length := 1200.0          # s for a whole day and night
@export var day_share := 0.72             # of it the sun is up
@export var start_phase := 0.14           # mid-morning
@export var max_elevation := 1.05         # rad, the sun's noon height
@export var night_exposure := 0.62
@export var day_shadow := 0.68            # shadow_opacity in daylight
@export var night_shadow := 0.4
# WARM, AFTER TERRATECH (the player's screenshot): the light off sand and grass fills the shadows,
# so the ambient is a warm grey, not the sky's blue - a blue fill turned every shadow cold and dark.
@export var day_ambient := Color(0.66, 0.6, 0.52)
@export var night_ambient := Color(0.22, 0.3, 0.52)
@export var day_ambient_energy := 0.36
@export var night_ambient_energy := 0.22
# the world's haze (project.godot [shader_globals] `world_haze`): what the far ground fades into and
# the sky's horizon - warm cream by day, the dusk's orange, a deep blue at night
@export var haze_day := Color(0.88, 0.82, 0.72)
@export var haze_dusk := Color(0.96, 0.62, 0.42)
@export var haze_night := Color(0.07, 0.09, 0.17)

const TICK := 0.25                        # s between updates: the sun moves a fifth of a degree
const MOON_SHARE := 0.3                   # the moon's light against the sun's
const DUSK_COLOR := Color(1.0, 0.6, 0.36)
const SUN_COLOR := Color(1.0, 0.93, 0.8)      # a warm white, never pure: the TerraTech afternoon
const SHADOW_BLUR := 1.6
# the blocks' light (block_lit.gdshader): a lit face a touch over its painted colour, warm; a face
# turned away keeps BLOCK_SHADE of it - the TerraTech contrast without losing the dark side's paint
const BLOCK_DAY := Color(1.12, 1.05, 0.94)
const BLOCK_DUSK := Color(1.15, 0.86, 0.66)
const BLOCK_NIGHT := Color(0.8, 0.88, 1.05)
const BLOCK_SHADE_DAY := 0.7
const BLOCK_SHADE_NIGHT := 0.78
const MOON_COLOR := Color(0.62, 0.72, 1.0)

var phase := 0.0
var _light: DirectionalLight3D = null
var _env: Environment = null
var _sky: ShaderMaterial = null
var _base_energy := 1.0
var _t := 0.0

func _ready() -> void:
	_light = get_parent().find_child("DirectionalLight3D*", false, false) as DirectionalLight3D
	var we := get_parent().find_child("WorldEnvironment", false, false) as WorldEnvironment
	if we != null:
		_env = we.environment
		if _env != null and _env.sky != null:
			_sky = _env.sky.sky_material as ShaderMaterial
	if _light != null:
		_base_energy = _light.light_energy
	phase = 0.5 * day_share if G.proving_ground else start_phase
	if _sky != null:
		_sky.set_shader_parameter("manual_sun", true)
	_apply()

func set_phase(p: float) -> void:
	phase = fposmod(p, 1.0)
	_apply()

func _process(delta: float) -> void:
	if G.proving_ground:
		return
	phase = fposmod(phase + delta / day_length, 1.0)
	_t -= delta
	if _t > 0.0:
		return
	_t = TICK
	_apply()

## Where the sun is: up from east to west over `day_share`, then on round under the world.
func sun_direction() -> Vector3:
	var a: float
	var e: float
	if phase < day_share:
		var u := phase / day_share
		a = PI * u
		e = sin(PI * u) * max_elevation
	else:
		var v := (phase - day_share) / (1.0 - day_share)
		a = PI + PI * v
		e = -sin(PI * v) * max_elevation
	return Vector3(cos(e) * cos(a), sin(e), cos(e) * sin(a) * 0.55 - 0.3).normalized()

func _apply() -> void:
	var sun := sun_direction()
	var moon := -sun
	var n := smoothstep(0.06, -0.14, sun.y)              # 0 day, 1 night
	var dusk := 1.0 - smoothstep(0.02, 0.38, absf(sun.y))
	if _sky != null:
		_sky.set_shader_parameter("sun_dir", sun)
		_sky.set_shader_parameter("moon_dir", moon)
		_sky.set_shader_parameter("night", n)
	if _light != null:
		if sun.y > -0.03:
			_light.look_at_from_position(Vector3.ZERO, -sun, Vector3.UP if absf(sun.y) < 0.99 else Vector3.FORWARD)
			_light.light_energy = _base_energy * smoothstep(-0.03, 0.22, sun.y)
			_light.light_color = DUSK_COLOR.lerp(SUN_COLOR, smoothstep(0.08, 0.45, sun.y))
			_light.shadow_opacity = day_shadow
		else:
			_light.look_at_from_position(Vector3.ZERO, -moon, Vector3.UP if absf(moon.y) < 0.99 else Vector3.FORWARD)
			_light.light_energy = _base_energy * MOON_SHARE * smoothstep(-0.03, 0.22, moon.y)
			_light.light_color = MOON_COLOR
			_light.shadow_opacity = night_shadow
	if _light != null:
		_light.shadow_blur = SHADOW_BLUR
	var haze := haze_day.lerp(haze_dusk, dusk * (1.0 - n)).lerp(haze_night, n)
	RenderingServer.global_shader_parameter_set(&"world_haze", haze)
	# the blocks' sun (block_lit.gdshader): the light's own direction and tint, by night the moon's;
	# `a` is the shade floor - a face turned away keeps that much of its painted colour
	var lit_dir: Vector3 = sun if sun.y > -0.03 else moon
	var lit := BLOCK_DAY.lerp(BLOCK_DUSK, dusk * (1.0 - n)).lerp(BLOCK_NIGHT, n)
	RenderingServer.global_shader_parameter_set(&"sun_dir", Vector4(lit_dir.x, lit_dir.y, lit_dir.z, 0.0))
	RenderingServer.global_shader_parameter_set(&"sun_light", Vector4(lit.r, lit.g, lit.b,
			lerpf(BLOCK_SHADE_DAY, BLOCK_SHADE_NIGHT, n)))
	if _env != null:
		_env.ambient_light_color = day_ambient.lerp(night_ambient, n)
		_env.ambient_light_energy = lerpf(day_ambient_energy, night_ambient_energy, n)
		_env.tonemap_exposure = lerpf(1.0, night_exposure, n) * lerpf(1.0, 0.93, dusk * (1.0 - n))
