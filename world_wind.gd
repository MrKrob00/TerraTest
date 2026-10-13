extends Node3D
## A GUST OF WIND, NOW AND THEN (the player's call, after a screenshot of leaves torn off by wind):
## rare, not weather - every GAP_MIN..GAP_MAX seconds a gust rises for LEN_MIN..LEN_MAX and dies
## away, and while it blows the air is full of what that ground has: leaves over the meadow, white
## lumps of snow on the snowy mountains, sand over the desert and the salt, dust in the canyon.
## THE MOTES STAND IN THE WORLD, NOT ON THE SCREEN: a screen overlay moved with every turn of the
## camera and read as stickers (the player's verdict on the first cut). One MultiMesh, its flight all
## in `resources/wind_motes.gdshader`; here only the gust's clock and a few uniforms a frame. Not
## engine particles (rule 11) - the same kind of thing as CardBurst.

const COUNT := 520
const GAP_MIN := 150.0
const GAP_MAX := 360.0
const FIRST_MIN := 60.0
const FIRST_MAX := 150.0
const LEN_MIN := 14.0
const LEN_MAX := 24.0
const RISE := 3.0
const FALL := 5.0
const BIOME_EVERY := 1.0
## Metres: the cube round the camera the motes live in (the shader's `box`).
const BOX := 24.0
## Over this share of the snow line the mountains count as snowy.
const SNOW_LINE_SHARE := 0.75
const SHADER := preload("res://resources/wind_motes.gdshader")

enum Kind { NONE = -1, LEAVES, SNOW, SAND, DUST }

## Per kind: how many of COUNT fly at full strength, size range, two colours, wind speed, fall.
const LOOK := {
	Kind.LEAVES: {"share": 0.7, "size": Vector2(0.22, 0.42), "a": Color(0.14, 0.22, 0.08), "b": Color(0.34, 0.30, 0.12), "speed": 6.5, "fall": 0.35},
	Kind.SNOW: {"share": 1.0, "size": Vector2(0.12, 0.30), "a": Color(0.92, 0.94, 0.98), "b": Color(1.0, 1.0, 1.0), "speed": 4.5, "fall": 0.9},
	Kind.SAND: {"share": 1.0, "size": Vector2(0.05, 0.10), "a": Color(0.82, 0.68, 0.46), "b": Color(0.93, 0.82, 0.60), "speed": 10.0, "fall": 0.1},
	Kind.DUST: {"share": 0.6, "size": Vector2(0.10, 0.24), "a": Color(0.58, 0.38, 0.26), "b": Color(0.74, 0.52, 0.36), "speed": 5.5, "fall": 0.15},
}

var _mmi: MultiMeshInstance3D
var _mat: ShaderMaterial
var _kind: int = Kind.NONE
var _next: float = 0.0
var _t: float = -1.0               # time into the gust, -1 between gusts
var _len: float = 0.0
var _wind_t: float = 0.0
var _biome_t: float = 0.0
var _biome_kind: int = Kind.NONE

func _ready() -> void:
	_next = randf_range(FIRST_MIN, FIRST_MAX)
	var quad := QuadMesh.new()
	quad.size = Vector2.ONE
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_custom_data = true
	mm.mesh = quad
	mm.instance_count = COUNT
	var rng := RandomNumberGenerator.new()
	rng.seed = 7151
	for i in COUNT:
		mm.set_instance_transform(i, Transform3D.IDENTITY)
		# w is the gate: the gust's strength lets in the motes whose w is under it
		mm.set_instance_custom_data(i, Color(rng.randf(), rng.randf(), rng.randf(), rng.randf()))
	_mat = ShaderMaterial.new()
	_mat.shader = SHADER
	_mat.set_shader_parameter("box", BOX)
	_mmi = MultiMeshInstance3D.new()
	_mmi.multimesh = mm
	_mmi.material_override = _mat
	_mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_mmi.visible = false
	add_child(_mmi)

## Start a gust now (debug and pictures); NONE takes the ground's own kind.
func gust_now(kind: int = Kind.NONE, length: float = 20.0) -> void:
	_start(kind if kind != Kind.NONE else _ground_kind(), length)

func _process(delta: float) -> void:
	_biome_t -= delta
	if _biome_t <= 0.0:
		_biome_t = BIOME_EVERY
		_biome_kind = _ground_kind()
	if _t < 0.0:
		_next -= delta
		if _next <= 0.0:
			_next = randf_range(GAP_MIN, GAP_MAX)
			if _biome_kind != Kind.NONE:
				_start(_biome_kind, randf_range(LEN_MIN, LEN_MAX))
		return
	_t += delta
	var env: float = smoothstep(0.0, RISE, _t) * (1.0 - smoothstep(_len - FALL, _len, _t))
	if _t >= _len:
		_t = -1.0
		_mmi.visible = false
		return
	_wind_t += delta * (0.25 + 0.75 * env)
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	var cp: Vector3 = cam.global_position
	_mmi.custom_aabb = AABB(cp - Vector3.ONE * BOX * 0.5, Vector3.ONE * BOX)
	_mat.set_shader_parameter("cam_pos", cp)
	_mat.set_shader_parameter("wind_t", _wind_t)
	_mat.set_shader_parameter("amount", env * float(LOOK[_kind]["share"]))

func _start(kind: int, length: float) -> void:
	if kind == Kind.NONE:
		return
	_kind = kind
	_t = 0.0
	_len = length
	_wind_t = 0.0
	var look: Dictionary = LOOK[kind]
	var ang: float = randf() * TAU
	_mat.set_shader_parameter("kind", kind)
	_mat.set_shader_parameter("wind_dir", Vector2(cos(ang), sin(ang)))
	_mat.set_shader_parameter("wind_speed", look["speed"])
	_mat.set_shader_parameter("fall", look["fall"])
	_mat.set_shader_parameter("size_range", look["size"])
	_mat.set_shader_parameter("col_a", look["a"])
	_mat.set_shader_parameter("col_b", look["b"])
	_mat.set_shader_parameter("amount", 0.0)
	_mmi.visible = true

## What the wind carries here: the biome under the camera.
func _ground_kind() -> int:
	var cam := get_viewport().get_camera_3d()
	var map: Node = get_node_or_null("/root/Main/map")
	if cam == null or map == null or not map.has_method("biome_at"):
		return Kind.NONE
	var p: Vector3 = cam.global_position
	var b: Vector3 = map.biome_at(p)                       # canyon, meadow, mountain
	if map.has_method("salt_at") and float(map.salt_at(p)) > 0.5:
		return Kind.SAND
	if b.z > 0.5:
		var bio = map.get("biomes")
		var wh: float = float(map.world_height()) if map.has_method("world_height") else 0.0
		var line: float = bio.snow_line_at(wh) if bio != null and bio.has_method("snow_line_at") and wh > 0.0 else 0.0
		var gy: float = G.ground_y(p, 0.0)
		return Kind.SNOW if line <= 0.0 or gy >= line * SNOW_LINE_SHARE else Kind.DUST
	if b.x > 0.5:
		return Kind.DUST
	if b.y > 0.5:
		return Kind.LEAVES
	return Kind.SAND
