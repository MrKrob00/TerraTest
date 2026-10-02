extends SceneTree
# THE VEIN MODELS: one ore outcrop per metal and a tree, low poly, built here and saved as the
# meshes the vein MultiMeshes draw (resource_nodes.gd). Run on a copy of the project (CLAUDE.md §3):
#   godot --headless --path <copy> --script res://art/vein_models.gd
# and copy resources/vein_*.tres back.
#
# EACH METAL HAS ITS OWN SHAPE (the player's call: one crystal cluster in four colours read as one
# ore). The metal's colour still comes from G.METAL_COLOR through the shader; the shape says it too:
#   ferrite  - rusty angular chunks breaking out of the rock (iron ore);
#   cuprite  - banded copper ore, uneven strata stacked in steps (rounded nuggets were turned
#              down: they looked silly);
#   silicate - a cluster of thick crystal columns straight out of the ground (TerraTech's node);
#   titanite - jagged shards of raw ore broken up through the rock (plates were turned down:
#              they read as metal already made, not as ore).
# The rock under each is NARROW, about the drill's reach across: the first cut was a 1.7 m slab of
# stone with a second chunk beside it, and the ore sat on it like decoration on a plinth.
#
# One mesh per model. An ore vein shrinks WHOLE as the HP goes and grows back; on the tree the vertex
# says what falls (UV.x 1) and the stump stays (resources/resource.gdshader). The frame is the vein node's: its origin stands 0.25 over the
# ground, so the ground is y = GROUND, and every part reaches below it so a slope shows no edge.
#
# Faces are flat and carry their own tone from one fixed light: unshaded, so a facet's colour is all
# there is. A tinted vertex has alpha 1: the shader multiplies its metal by the facet's tone (rgb,
# stored / TINT_GAIN); alpha 0 is a fixed colour (rock, bark, needles).

const GROUND := -0.25
const SINK := 0.45
const TINT_GAIN := 1.4
const LIGHT := Vector3(0.45, 1.0, 0.3)
const OUT := "res://resources/"

const STONE := Color(0.26, 0.24, 0.29)       # dark slate, violet leaning: reads on sand, grass and grey mountain
const BARK := Color(0.50, 0.33, 0.20)
## Darker and bluer than the meadow (0.33, 0.56, 0.23), so a tree reads on it.
const NEEDLE := Color(0.30, 0.58, 0.34)
const NEEDLE_TIP := Color(0.40, 0.68, 0.38)

var _rng := RandomNumberGenerator.new()
var _moving := false            # the faces being added now are the part that is mined

func _initialize() -> void:
	_rng.seed = 7711
	_save(_ferrite(), "vein_ore0")
	_save(_cuprite(), "vein_ore1")
	_save(_silicate(), "vein_ore2")
	_save(_titanite(), "vein_ore3")
	_save(_tree(), "vein_tree")
	quit()

func _save(st: SurfaceTool, name: String) -> void:
	var m: ArrayMesh = st.commit()
	m.resource_name = name
	var err := ResourceSaver.save(m, OUT + name + ".tres")
	print("%s: %d triangles, aabb %s, save %d" % [name, m.surface_get_array_len(0) / 3, m.get_aabb(), err])

func _tone(n: Vector3) -> float:
	return 0.70 + 0.42 * maxf(n.dot(LIGHT.normalized()), 0.0)

## One flat triangle, its front away from `inside` (Godot's front face is clockwise seen from
## outside - CLAUDE.md, the shield entry).
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
		var g: float = clampf(k * col.v / TINT_GAIN, 0.0, 1.0)
		cc = Color(g, g, g, 1.0)
	else:
		cc = Color(col.r * k, col.g * k, col.b * k, 0.0)
	var uv := Vector2(1.0 if _moving else 0.0, 0.0)
	for p in [a, c, b]:
		st.set_color(cc)
		st.set_normal(n)
		st.set_uv(uv)
		st.add_vertex(p)

func _quad(st, a, b, c, d, inside, col, tinted) -> void:
	_tri(st, a, b, c, inside, col, tinted)
	_tri(st, a, c, d, inside, col, tinted)

func _begin() -> SurfaceTool:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	return st

func _ring(c: Vector3, n: int, r: float, y: float, jit: float, phase: float) -> Array:
	var out: Array = []
	for i in n:
		var a: float = phase + TAU * float(i) / float(n) + _rng.randf_range(-0.18, 0.18)
		var rr: float = r * (1.0 + _rng.randf_range(-jit, jit))
		out.append(c + Vector3(cos(a) * rr, y + _rng.randf_range(-jit, jit) * r * 0.5, sin(a) * rr))
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
	top.y += 0.05
	for k in n:
		_tri(st, rs[-1][k], rs[-1][(k + 1) % n], top, inside, col, false)

## The narrow rock every ore stands in: one boulder about a metre across.
func _base(st: SurfaceTool, col: Color, top: float = 0.30) -> void:
	_moving = false
	_boulder(st, Vector3.ZERO, 6,
			[[0.50, GROUND - SINK, 0.08], [0.54, GROUND + 0.08, 0.10], [0.38, GROUND + top, 0.12]], col)

## A box of half sizes `h` turned by `b` round `c`.
func _box(st: SurfaceTool, c: Vector3, b: Basis, h: Vector3, col: Color, tinted: bool) -> void:
	var p: Array = []
	for i in 8:
		var s := Vector3(1 if i & 1 else -1, 1 if i & 2 else -1, 1 if i & 4 else -1)
		p.append(c + b * (s * h))
	for f in [[0, 1, 3, 2], [4, 6, 7, 5], [0, 4, 5, 1], [2, 3, 7, 6], [0, 2, 6, 4], [1, 5, 7, 3]]:
		_quad(st, p[f[0]], p[f[1]], p[f[2]], p[f[3]], c, col, tinted)

func _turn(yaw: float, tilt: float, roll: float = 0.0) -> Basis:
	return Basis(Vector3.UP, yaw) * Basis(Vector3.RIGHT, tilt) * Basis(Vector3.FORWARD, roll)

## FERRITE: rusty angular chunks half out of the rock, tilted every way - a broken seam.
func _ferrite() -> SurfaceTool:
	var st := _begin()
	_base(st, Color(0.27, 0.22, 0.22))
	_moving = true
	var rust := Color.WHITE
	_box(st, Vector3(0.0, GROUND + 0.42, 0.02), _turn(0.4, 0.35, 0.25), Vector3(0.24, 0.22, 0.20), rust, true)
	_box(st, Vector3(0.28, GROUND + 0.30, -0.12), _turn(1.2, -0.5, 0.6), Vector3(0.17, 0.15, 0.14), rust, true)
	_box(st, Vector3(-0.27, GROUND + 0.28, 0.20), _turn(2.3, 0.7, -0.4), Vector3(0.15, 0.16, 0.12), rust, true)
	_box(st, Vector3(-0.10, GROUND + 0.30, -0.32), _turn(0.9, -0.3, 0.9), Vector3(0.11, 0.10, 0.10), rust, true)
	_box(st, Vector3(0.12, GROUND + 0.68, 0.06), _turn(2.0, 0.6, 0.5), Vector3(0.10, 0.09, 0.09), rust, true)
	return st

## One stratum: an uneven flat-topped slab, `n` sides, from y0 to y1, its top tipped a little.
func _stratum(st: SurfaceTool, c: Vector3, r: float, y0: float, y1: float, n: int) -> void:
	var ph: float = _rng.randf() * TAU
	var lo := _ring(c, n, r, y0, 0.16, ph)
	var hi: Array = []
	var tip := Vector3(_rng.randf_range(-1, 1), 0, _rng.randf_range(-1, 1)).normalized() * 0.12
	for p in lo:
		var d: Vector3 = ((p as Vector3) - Vector3(c.x, (p as Vector3).y, c.z)) * 0.88
		hi.append(Vector3(c.x, y1, c.z) + d + Vector3(0, tip.dot(d), 0))
	var top := Vector3.ZERO
	for p in hi:
		top += p
	top /= float(n)
	var inside := Vector3(c.x, (y0 + y1) * 0.5, c.z)
	for k in n:
		var j: int = (k + 1) % n
		_quad(st, lo[k], lo[j], hi[j], hi[k], inside, Color.WHITE, true)
		_tri(st, hi[k], hi[j], top, inside, Color.WHITE, true)

## CUPRITE: banded copper ore - uneven strata stacked in steps, each set off from the one under it,
## broken up through the rock. Rounded nuggets were turned down (the player: they look silly).
func _cuprite() -> SurfaceTool:
	var st := _begin()
	_base(st, Color(0.22, 0.25, 0.25), 0.20)
	_moving = true
	_stratum(st, Vector3(0.02, 0, 0.0), 0.40, GROUND + 0.05, GROUND + 0.28, 6)
	_stratum(st, Vector3(-0.06, 0, 0.05), 0.30, GROUND + 0.26, GROUND + 0.48, 6)
	_stratum(st, Vector3(0.05, 0, -0.02), 0.20, GROUND + 0.46, GROUND + 0.66, 5)
	_stratum(st, Vector3(0.30, 0, -0.22), 0.13, GROUND + 0.20, GROUND + 0.40, 5)
	return st

## A crystal column, TerraTech's: a THICK hexagonal prism from its foot under the ground, a short
## faceted point, the shoulder ring a little wider than the foot.
func _column(st: SurfaceTool, foot: Vector3, dir: Vector3, lean: float, h: float, r: float) -> void:
	var up: Vector3 = (Vector3.UP * cos(lean) + dir.normalized() * sin(lean)).normalized()
	var side: Vector3 = up.cross(Vector3.FORWARD if absf(up.z) < 0.9 else Vector3.RIGHT).normalized()
	var side2: Vector3 = up.cross(side).normalized()
	var phase: float = _rng.randf() * TAU
	var lo: Array = []
	var hi: Array = []
	for i in 6:
		var a: float = phase + TAU * float(i) / 6.0
		var o: Vector3 = side * cos(a) * r + side2 * sin(a) * r
		lo.append(foot + o)
		hi.append(foot + up * h * 0.78 + o * 1.05)
	var tip: Vector3 = foot + up * h
	var inside: Vector3 = foot + up * h * 0.4
	for i in 6:
		var j: int = (i + 1) % 6
		_quad(st, lo[i], lo[j], hi[j], hi[i], inside, Color.WHITE, true)
		_tri(st, hi[i], hi[j], tip, inside, Color.WHITE, true)

## SILICATE: a cluster of thick crystal columns growing straight out of the ground, TerraTech's
## crystal node - a tall one in the middle, a ring leaning out round it and small shards at the
## foot. Turned down on the way: big thin crystals on a stone slab ("a plinth"), then a tall rock
## with a brush of thin crystals on top ("still not it").
func _silicate() -> SurfaceTool:
	var st := _begin()
	_moving = false
	var y0 := GROUND - 0.25                              # every foot starts under the ground
	_column(st, Vector3(0.02, y0, 0.0), Vector3(0.3, 0, -0.2), 0.06, 1.85, 0.24)
	var ring := 5
	for i in ring:
		var ang: float = TAU * float(i) / float(ring) + _rng.randf_range(-0.2, 0.2)
		var dir := Vector3(cos(ang), 0, sin(ang))
		var foot := dir * _rng.randf_range(0.17, 0.24) + Vector3(0, y0, 0)
		_column(st, foot, dir, _rng.randf_range(0.30, 0.55), _rng.randf_range(0.95, 1.35),
				_rng.randf_range(0.14, 0.19))
	for i in 3:
		var ang: float = TAU * (float(i) + 0.5) / 3.0 + _rng.randf_range(-0.3, 0.3)
		var dir := Vector3(cos(ang), 0, sin(ang))
		_column(st, dir * 0.40 + Vector3(0, GROUND - 0.12, 0), dir, _rng.randf_range(0.7, 0.95),
				_rng.randf_range(0.40, 0.55), 0.09)
	return st

## A raw ore shard: a lofted lump skewed to one side and broken off unevenly on top, with every
## ring jittered hard - a fractured piece of rock, not a cut shape.
func _shard(st: SurfaceTool, foot: Vector3, lean: Vector3, r: float, h: float, n: int) -> void:
	var ph: float = _rng.randf() * TAU
	var lo := _ring(foot, n, r, 0.0, 0.22, ph)
	var mid := _ring(foot + lean * h * 0.5, n, r * 0.85, h * 0.5, 0.25, ph + 0.3)
	var hi := _ring(foot + lean * h, n, r * 0.45, h * 0.88, 0.35, ph + 0.7)
	var top := foot + lean * h * 1.05 + Vector3(0, h, 0)
	var inside := foot + lean * h * 0.5 + Vector3(0, h * 0.45, 0)
	for k in n:
		var j: int = (k + 1) % n
		_quad(st, lo[k], lo[j], mid[j], mid[k], inside, Color.WHITE, true)
		_quad(st, mid[k], mid[j], hi[j], hi[k], inside, Color.WHITE, true)
		_tri(st, hi[k], hi[j], top, inside, Color.WHITE, true)

## TITANITE: jagged shards of raw metal ore broken up through the rock (the player's call: plates
## read as something already made; this is ore).
func _titanite() -> SurfaceTool:
	var st := _begin()
	_base(st, Color(0.24, 0.24, 0.27), 0.24)
	_moving = true
	_shard(st, Vector3(0.0, GROUND + 0.18, 0.0), Vector3(0.10, 0, -0.08), 0.24, 0.62, 5)
	_shard(st, Vector3(0.24, GROUND + 0.12, 0.16), Vector3(0.45, 0, 0.25), 0.16, 0.40, 5)
	_shard(st, Vector3(-0.24, GROUND + 0.12, 0.10), Vector3(-0.50, 0, 0.10), 0.15, 0.36, 4)
	_shard(st, Vector3(-0.06, GROUND + 0.10, -0.28), Vector3(-0.10, 0, -0.55), 0.13, 0.30, 4)
	return st

func _tree() -> SurfaceTool:
	var st := _begin()
	# the stump stays when the rest is felled
	_moving = false
	var n := 6
	var lo := _ring(Vector3.ZERO, n, 0.42, GROUND - SINK, 0.06, 0.0)
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
	# the trunk from inside the stump up into the crown, and three tiers of needles
	_moving = true
	var m := 5
	var tlo := _ring(Vector3.ZERO, m, 0.20, GROUND + 0.1, 0.0, 0.0)
	var thi := _ring(Vector3.ZERO, m, 0.13, GROUND + 1.25, 0.0, 0.0)
	for k in m:
		_quad(st, tlo[k], tlo[(k + 1) % m], thi[(k + 1) % m], thi[k], Vector3(0, GROUND + 0.6, 0), BARK, false)
	var tiers := [[GROUND + 0.85, 1.05, 1.15], [GROUND + 1.55, 0.82, 1.0], [GROUND + 2.2, 0.56, 0.95]]
	for i in tiers.size():
		var y: float = tiers[i][0]
		var r: float = tiers[i][1]
		var h: float = tiers[i][2]
		var s := 6
		var skirt := _ring(Vector3.ZERO, s, r, y, 0.08, 0.5 * i)
		var apex := Vector3(_rng.randf_range(-0.04, 0.04), y + h, _rng.randf_range(-0.04, 0.04))
		var under := Vector3(0, y + 0.12, 0)
		var inn := Vector3(0, y + h * 0.3, 0)
		var col: Color = NEEDLE.lerp(NEEDLE_TIP, float(i) / 2.0)
		for k in s:
			var j: int = (k + 1) % s
			_tri(st, skirt[k], skirt[j], apex, inn, col, false)
			_tri(st, skirt[j], skirt[k], under, inn + Vector3(0, 0.4, 0), col.darkened(0.25), false)
	return st
