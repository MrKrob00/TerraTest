extends SceneTree
# THE VEIN MODELS: an ore outcrop and a tree, low poly, built here and saved as meshes the vein
# MultiMeshes draw (resource_nodes.gd). Run on a copy of the project (CLAUDE.md §3):
#   godot --headless --path <copy> --script res://art/vein_models.gd
# and copy resources/vein_*.tres back.
#
# A vein is drawn by TWO MultiMeshes per kind, and the split is the mechanic:
#   rock / stump  - what stays: plain unshaded vertex colour, never moves;
#   crystal / tree - what is mined: resource.gdshader shrinks the crystals into the rock as the HP
#                    goes (a tree LEANS and falls instead), shakes on a hit and grows back.
# The frame is the vein node's: its origin stands VEIN_LIFT over the ground, so the ground is
# y = GROUND, and every part reaches below it so a slope does not show a floating edge.
#
# Faces are flat and carry their own tone from one fixed light (TONE_*): unshaded, so a facet's
# colour is all there is - one colour round a rock is a flat blob. A crystal vertex has alpha 1:
# the shader tints it with its metal (G.METAL_COLOR), its rgb is the facet's tone / TINT_GAIN. Alpha
# 0 is a fixed colour (rock, bark, needles).

const GROUND := -0.25                  # resource_nodes puts the origin 0.25 over the ground
const SINK := 0.45                     # how far every part reaches below the ground
const TINT_GAIN := 1.4                 # resource.gdshader multiplies a tinted tone back by this
const LIGHT := Vector3(0.45, 1.0, 0.3)
const OUT := "res://resources/"

const STONE := Color(0.26, 0.24, 0.29)       # dark slate, violet leaning: reads on sand, grass and grey mountain
const BARK := Color(0.50, 0.33, 0.20)
## The game's AgX at contrast 1.7 crushes darks: needles at (0.13, 0.33, 0.20) came out black on
## the real driver. Still darker and bluer than the meadow (0.33, 0.56, 0.23), so a tree reads on it.
const NEEDLE := Color(0.30, 0.58, 0.34)
const NEEDLE_TIP := Color(0.40, 0.68, 0.38)

var _rng := RandomNumberGenerator.new()

func _initialize() -> void:
	_rng.seed = 7711
	_save(_rock(), "vein_rock")
	_save(_crystals(), "vein_crystal")
	_save(_stump(), "vein_stump")
	_save(_tree(), "vein_tree")
	quit()

func _save(st: SurfaceTool, name: String) -> void:
	var m: ArrayMesh = st.commit()
	m.resource_name = name
	var err := ResourceSaver.save(m, OUT + name + ".tres")
	var tris: int = m.surface_get_array_len(0) / 3
	print("%s: %d triangles, aabb %s, save %d" % [name, tris, m.get_aabb(), err])

func _tone(n: Vector3) -> float:
	return 0.70 + 0.42 * maxf(n.dot(LIGHT.normalized()), 0.0)

## One flat triangle, wound so its front faces away from `inside` (Godot's front face is clockwise
## seen from outside - CLAUDE.md, the shield entry).
func _tri(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, inside: Vector3, col: Color,
		tinted: bool) -> void:
	var n: Vector3 = (b - a).cross(c - a).normalized()
	if n.dot((a + b + c) / 3.0 - inside) < 0.0:
		var t := b; b = c; c = t
		n = -n
	# a, b, c now run counter-clockwise seen from outside; they are added a, c, b
	var k: float = _tone(n)
	var cc: Color
	if tinted:
		var g: float = clampf(k / TINT_GAIN, 0.0, 1.0)
		cc = Color(g, g, g, 1.0)
	else:
		cc = Color(col.r * k, col.g * k, col.b * k, 0.0)
	st.set_color(cc)
	st.set_normal(n)
	st.add_vertex(a)
	st.set_color(cc)
	st.set_normal(n)
	st.add_vertex(c)
	st.set_color(cc)
	st.set_normal(n)
	st.add_vertex(b)

func _quad(st, a, b, c, d, inside, col, tinted) -> void:
	_tri(st, a, b, c, inside, col, tinted)
	_tri(st, a, c, d, inside, col, tinted)

func _begin() -> SurfaceTool:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	return st

## A ring of `n` points at height y, radius r, each pushed by `jit` and turned by `phase`.
func _ring(c: Vector3, n: int, r: float, y: float, jit: float, phase: float, sq: float = 1.0) -> Array:
	var out: Array = []
	for i in n:
		var a: float = phase + TAU * float(i) / float(n) + _rng.randf_range(-0.18, 0.18)
		var rr: float = r * (1.0 + _rng.randf_range(-jit, jit))
		out.append(c + Vector3(cos(a) * rr, y + _rng.randf_range(-jit, jit) * r * 0.5, sin(a) * rr * sq))
	return out

## A lofted boulder: rings from below the ground up to a jittered cap.
func _boulder(st: SurfaceTool, c: Vector3, n: int, rings: Array, col: Color) -> void:
	var rs: Array = []
	for i in rings.size():
		var spec: Array = rings[i]
		rs.append(_ring(c, n, spec[0], spec[1], spec[2], 0.4 * i))
	var inside: Vector3 = c + Vector3(0.0, (rings[0][1] + rings[-1][1]) * 0.5, 0.0)
	for i in rs.size() - 1:
		for k in n:
			var j: int = (k + 1) % n
			_quad(st, rs[i][k], rs[i][j], rs[i + 1][j], rs[i + 1][k], inside, col, false)
	var top: Vector3 = Vector3.ZERO
	for p in rs[-1]:
		top += p
	top /= float(n)
	top.y += 0.06
	for k in n:
		_tri(st, rs[-1][k], rs[-1][(k + 1) % n], top, inside, col, false)

func _rock() -> SurfaceTool:
	var st := _begin()
	var b := GROUND - SINK
	# the main boulder, broad and low, and a second chunk leaning on it
	_boulder(st, Vector3(0.05, 0, 0.0), 7,
			[[0.82, b, 0.10], [0.86, GROUND + 0.18, 0.12], [0.62, GROUND + 0.48, 0.14]], STONE)
	_boulder(st, Vector3(-0.62, 0, 0.42), 6,
			[[0.42, b, 0.10], [0.44, GROUND + 0.12, 0.12], [0.26, GROUND + 0.34, 0.15]], STONE.darkened(0.08))
	return st

## A crystal: a prism of `sides` from its foot inside the rock, a shoulder and a pointed tip,
## leaning by `lean` toward `dir`.
func _crystal(st: SurfaceTool, foot: Vector3, dir: Vector3, lean: float, h: float, r: float,
		sides: int) -> void:
	var up: Vector3 = (Vector3.UP * cos(lean) + dir.normalized() * sin(lean)).normalized()
	var side: Vector3 = up.cross(Vector3.FORWARD if absf(up.z) < 0.9 else Vector3.RIGHT).normalized()
	var side2: Vector3 = up.cross(side).normalized()
	var phase: float = _rng.randf() * TAU
	var lo: Array = []
	var hi: Array = []
	for i in sides:
		var a: float = phase + TAU * float(i) / float(sides)
		var o: Vector3 = side * cos(a) * r + side2 * sin(a) * r
		lo.append(foot + o)
		hi.append(foot + up * h * 0.72 + o * 1.06)
	var tip: Vector3 = foot + up * h
	var inside: Vector3 = foot + up * h * 0.4
	for i in sides:
		var j: int = (i + 1) % sides
		_quad(st, lo[i], lo[j], hi[j], hi[i], inside, Color.WHITE, true)
		_tri(st, hi[i], hi[j], tip, inside, Color.WHITE, true)

func _crystals() -> SurfaceTool:
	var st := _begin()
	var y0 := GROUND + 0.2                      # feet inside the boulder's shoulder
	_crystal(st, Vector3(0.05, y0, -0.02), Vector3(0.2, 0, -0.3), 0.12, 1.35, 0.21, 5)
	_crystal(st, Vector3(0.32, y0 - 0.02, 0.18), Vector3(1.0, 0, 0.5), 0.55, 0.95, 0.15, 5)
	_crystal(st, Vector3(-0.28, y0, -0.20), Vector3(-1.0, 0, -0.4), 0.48, 0.85, 0.14, 5)
	_crystal(st, Vector3(-0.05, y0 - 0.05, 0.36), Vector3(-0.2, 0, 1.0), 0.70, 0.62, 0.12, 4)
	_crystal(st, Vector3(-0.58, GROUND + 0.1, 0.45), Vector3(-0.6, 0, 0.8), 0.40, 0.55, 0.11, 4)
	return st

func _stump() -> SurfaceTool:
	var st := _begin()
	var b := GROUND - SINK
	var n := 6
	var lo := _ring(Vector3.ZERO, n, 0.42, b, 0.06, 0.0)
	var mid := _ring(Vector3.ZERO, n, 0.36, GROUND + 0.06, 0.08, 0.0)
	var hi := _ring(Vector3.ZERO, n, 0.24, GROUND + 0.30, 0.04, 0.0)
	var inside := Vector3(0, GROUND, 0)
	for k in n:
		var j: int = (k + 1) % n
		_quad(st, lo[k], lo[j], mid[j], mid[k], inside, BARK.darkened(0.15), false)
		_quad(st, mid[k], mid[j], hi[j], hi[k], inside, BARK.darkened(0.05), false)
	var top := Vector3(0, GROUND + 0.30, 0)
	for k in n:
		_tri(st, hi[k], hi[(k + 1) % n], top, Vector3(0, GROUND, 0), Color(0.62, 0.48, 0.30), false)
	return st

func _tree() -> SurfaceTool:
	var st := _begin()
	# the trunk from inside the stump up into the crown
	var n := 5
	var lo := _ring(Vector3.ZERO, n, 0.20, GROUND + 0.1, 0.0, 0.0)
	var hi := _ring(Vector3.ZERO, n, 0.13, GROUND + 1.25, 0.0, 0.0)
	for k in n:
		_quad(st, lo[k], lo[(k + 1) % n], hi[(k + 1) % n], hi[k], Vector3(0, GROUND + 0.6, 0), BARK, false)
	# three tiers of needles, each a six-sided cone with its underside
	var tiers := [[GROUND + 0.85, 1.05, 1.15], [GROUND + 1.55, 0.82, 1.0], [GROUND + 2.2, 0.56, 0.95]]
	for i in tiers.size():
		var y: float = tiers[i][0]
		var r: float = tiers[i][1]
		var h: float = tiers[i][2]
		var m := 6
		var skirt := _ring(Vector3.ZERO, m, r, y, 0.08, 0.5 * i)
		var apex := Vector3(_rng.randf_range(-0.04, 0.04), y + h, _rng.randf_range(-0.04, 0.04))
		var under := Vector3(0, y + 0.12, 0)
		var inside := Vector3(0, y + h * 0.3, 0)
		var col: Color = NEEDLE.lerp(NEEDLE_TIP, float(i) / 2.0)
		for k in m:
			var j: int = (k + 1) % m
			_tri(st, skirt[k], skirt[j], apex, inside, col, false)
			_tri(st, skirt[j], skirt[k], under, inside + Vector3(0, 0.4, 0), col.darkened(0.25), false)
	return st
