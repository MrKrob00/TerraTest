class_name LockFrame
extends MeshInstance3D
# A GREEN NEON FRAME ON A BLOCK YOUR GUNS ARE LOCKED ON.
#
# ONE PER TARGET, NOT PER GUN AND NOT PER MACHINE. Every gun picks its own block, so a fight shows
# as many frames as there are distinct targets; guns that agree on one block share its frame.
# BlockFX.lock_hold / lock_release count the guns on a block, and the frame lives while that count
# is above zero: it snaps in when the first gun takes the block and fades when the last lets go
# (guns only aim while firing is held, so frames exist only while the player is shooting).
#
# ONE MESH, ONE DRAW CALL. Four corners, two arms each, and a faint wider copy behind every arm for
# the neon (glow is off for frames, so the halo is faked) - sixteen strips in ONE surface, built
# once and shared by every frame. As sixteen quad nodes a frame cost sixteen draw calls, and with
# a frame per target that would have been the draw-call count of a whole machine per gun.
#
# Its own node with its own clock rather than a tween: it has to turn to the camera every frame for
# as long as it lives, and it does not know in advance when it will be released.

const COL := Color(0.3, 1.0, 0.45)
const SNAP := 0.22              # from wide to fitted
const WIDE := 1.7               # it starts this many times its fitted size
const FADE := 0.25
const ARM := 0.34               # bracket arm, share of the half-size
const TH := 0.07                # core line at half-size 1
const HALO_W := 3.2
const HALO_A := 0.28
## NEVER SMALLER THAN THIS SHARE OF THE DISTANCE (about 1.4 degrees of view): a frame round one
## block sixty metres out is otherwise a speck on a phone. Up close the block's own size wins.
const MIN_ANGLE := 0.025

static var _mesh: ArrayMesh = null

var centre: Vector3 = Vector3.ZERO       # the target block's middle, in its own space
var _r: float = 1.0
var _t: float = 0.0
var _out: float = -1.0          # >= 0 while fading out
var _mat: StandardMaterial3D = null

static func unit_mesh() -> ArrayMesh:
	if _mesh != null:
		return _mesh
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for layer in 2:                              # halo first, so the core draws over it
		var w: float = TH * (HALO_W if layer == 0 else 1.0)
		var col := Color(1, 1, 1, HALO_A if layer == 0 else 1.0)
		for c in [Vector2(-1, -1), Vector2(1, -1), Vector2(-1, 1), Vector2(1, 1)]:
			# Arms run INWARD from the corner along each edge.
			_strip(st, col, c, Vector2(c.x - c.x * ARM, c.y), w)
			_strip(st, col, c, Vector2(c.x, c.y - c.y * ARM), w)
	_mesh = st.commit()
	return _mesh

static func _strip(st: SurfaceTool, col: Color, a: Vector2, b: Vector2, w: float) -> void:
	var d: Vector2 = (b - a).normalized()
	var n: Vector2 = Vector2(-d.y, d.x) * w * 0.5
	var a2: Vector2 = a - d * w * 0.5            # overhang, so the two arms close the corner
	var p := [a2 + n, b + n, b - n, a2 - n]
	for i in [0, 1, 2, 0, 2, 3]:
		st.set_color(col)
		st.add_vertex(Vector3(p[i].x, p[i].y, 0.0))

func setup(radius: float) -> void:
	_r = radius
	mesh = unit_mesh()
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	set_meta("block_fx", true)                   # rule 11: never part of a block's measured size
	_mat = StandardMaterial3D.new()
	_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	_mat.no_depth_test = true                    # a sight: a lock behind a hill still reads
	_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_mat.vertex_color_use_as_albedo = true       # the halo's alpha rides in the vertex colour
	_mat.albedo_color = COL
	material_override = _mat

func release() -> void:
	if _out < 0.0:
		_out = 0.0

func is_releasing() -> bool:
	return _out >= 0.0

## Held again while fading: the same frame comes back instead of a second one appearing.
func rehold() -> void:
	_out = -1.0

func _process(delta: float) -> void:
	_t += delta
	var a: float = 1.0
	if _out >= 0.0:
		_out += delta
		a = 1.0 - _out / FADE
		if a <= 0.0:
			queue_free()
			return
	var k: float = clampf(_t / SNAP, 0.0, 1.0)
	var size: float = _r * lerpf(WIDE, 1.0, 1.0 - pow(1.0 - k, 3.0))
	var cam: Camera3D = get_viewport().get_camera_3d()
	if cam != null:
		size = maxf(size, cam.global_position.distance_to(global_position) * MIN_ANGLE)
		var q: Basis = Basis(cam.global_basis.get_rotation_quaternion())
		global_basis = q.scaled(Vector3.ONE * size)
		# Stepped jitter while it snaps: the lock is a glitch landing, not a zoom.
		var jit := Vector3.ZERO
		if k < 1.0:
			var step: int = int(_t / 0.05)
			jit = (q.x * (fposmod(sin(float(step) * 12.99) * 437.5, 1.0) - 0.5)
					+ q.y * (fposmod(sin(float(step) * 78.23) * 437.5, 1.0) - 0.5)) * _r * 0.12
		position = centre + get_parent_node_3d().global_basis.inverse() * jit
	if k < 1.0:
		a *= 0.55 + 0.45 * float(int(_t / 0.04) % 2)     # flicker while it lands
	_mat.albedo_color = Color(COL, a)
