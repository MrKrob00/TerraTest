extends Node3D
## WHERE A MACHINE WILL LAND, SHOWN BEFORE IT COMES (the player's call: "a ring turning on the ground
## where it will fall, ~3 s before it appears"). Raised by the spawner's one door for a dropping
## machine (`enemy_spawner._hold_for_drop`): the machine is made at once but held hidden over the
## point, the ring counts `warn` seconds down, then the machine is let go and the ring fades.
##
## ONE wide red ribbon of dashes draped over the terrain's heights at the build's reach
## (resources/drop_ring.gdshader), running round like the collector's and receiver's reach ring - the
## player's call: "red, fairly wide, not a solid line but - - - - like the collector's". A countdown arc
## filling it and an inner ring turning the other way came first and read as a solid line. Built once
## - the point does not move - and freed after the fade. Top level in the world.

const SHADER := preload("res://resources/drop_ring.gdshader")
const SEGMENTS := 56
const WIDTH := 0.9
const DASH_LEN := 1.6                 # metres a dash and its gap, round the ring
const LIFT := 0.05                    # over the grass lift, as the reach ring's
const FADE_IN := 0.3
const FADE_OUT := 0.8
const HOSTILE := Color(1.0, 0.1, 0.06, 0.95)
const FRIENDLY := Color(0.15, 0.8, 1.0, 0.9)

var at := Vector3.ZERO                # the ground point the machine lands on
var radius: float = 4.0
var warn: float = 3.0
var friendly: bool = false

var _t: float = 0.0
var _out: float = -1.0                # seconds since release; < 0 still counting down
var _mats: Array = []

func _ready() -> void:
	top_level = true
	global_transform = Transform3D(Basis(), Vector3(at.x, 0.0, at.z))
	_ribbon(radius, WIDTH, maxf(8.0, round(TAU * radius / DASH_LEN)), 0.12)
	_shade()

## The countdown is over: the machine is on its way down; the ring fades out and frees itself.
func release() -> void:
	if _out < 0.0:
		_out = 0.0

func _process(delta: float) -> void:
	if _out >= 0.0:
		_out += delta
		if _out >= FADE_OUT:
			queue_free()
			return
	else:
		_t += delta
	_shade()

func _shade() -> void:
	var p: float = clampf(_t / maxf(warn, 0.01), 0.0, 1.0)
	var f: float = clampf(_t / FADE_IN, 0.0, 1.0)
	if _out >= 0.0:
		p = 1.0
		f = 1.0 - _out / FADE_OUT
	for m in _mats:
		(m as ShaderMaterial).set_shader_parameter("progress", p)
		(m as ShaderMaterial).set_shader_parameter("fade", f)

## A ribbon of `width` round the point at radius `r`, every vertex on the ground under it.
func _ribbon(r: float, width: float, dashes: float, spin: float) -> void:
	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	var idx := PackedInt32Array()
	var half: float = width * 0.5
	for i in SEGMENTS + 1:                          # the seam repeats the first point: UV runs 0..1
		var a: float = TAU * float(i % SEGMENTS) / float(SEGMENTS)
		var dir := Vector2(cos(a), sin(a))
		var q: Vector2 = Vector2(at.x, at.z) + dir * r
		var y: float = G.ground_y(Vector3(q.x, at.y, q.y), at.y)   # one height for both edges
		for side in 2:
			var o: Vector2 = dir * (r + (half if side == 1 else -half))
			verts.append(Vector3(o.x, y, o.y))
			uvs.append(Vector2(float(i) / float(SEGMENTS), float(side)))
		if i > 0:
			var b: int = i * 2
			idx.append_array(PackedInt32Array([b - 2, b - 1, b + 1, b - 2, b + 1, b]))
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_TEX_UV] = uvs
	arr[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var mat := ShaderMaterial.new()
	mat.shader = SHADER
	mat.set_shader_parameter("color", FRIENDLY if friendly else HOSTILE)
	mat.set_shader_parameter("dashes", dashes)
	mat.set_shader_parameter("spin", spin)
	mat.set_shader_parameter("depth_lift", G.grass_lift() + LIFT)
	mi.material_override = mat
	_mats.append(mat)
	add_child(mi)
