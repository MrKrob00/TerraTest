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
# One mesh per model, cut into parts: an ore vein BREAKS a part at a time as the HP goes (UV.x is the
# part's break point, see `_part`) and grows back whole; on the tree UV.x 1 is what falls and the
# stump stays (resources/resource.gdshader). The frame is the vein node's: its origin stands 0.25 over the
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
## What the faces being added now are, written to UV.x. On an ORE it is the part's BREAK point: the
## part is drawn while the vein's HP share is above it, so one part goes with each ore thrown out
## (`BREAKS`, the vein's MAX_RESOURCES = 5 throws at 0.8 / 0.6 / ... / 0.0); RUBBLE (below 0) stays
## for good and marks the spot while the vein rests. On the TREE it is 1 for what falls, 0 for the
## stump.
var _part := RUBBLE
const RUBBLE := -1.0
const BREAKS := [0.8, 0.6, 0.4, 0.2, 0.0]

func _initialize() -> void:
	_rng.seed = 7711
	_save(_ferrite(), "vein_ore0")
	_save(_cuprite(), "vein_ore1")
	_save(_silicate(), "vein_ore2")
	_save(_titanite(), "vein_ore3")
	# a seed per tree: reworking one no longer shifts every later tree's jitter
	var trees := [[_broadleaf, "vein_tree1"], [_flatcrown, "vein_tree2"], [_palm, "vein_tree3"]]
	for i in trees.size():
		_rng.seed = 9101 + i            # the seeds the approved models were drawn with
		_save((trees[i][0] as Callable).call(), trees[i][1])
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
	var uv := Vector2(_part, 0.0)
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

## The narrow rock every ore stands in, about a metre across, in two parts: the low rubble that
## stays, and the rock over it, which breaks away at `cap` like any piece of ore.
func _base(st: SurfaceTool, col: Color, top: float, cap: float) -> void:
	_part = RUBBLE
	_boulder(st, Vector3.ZERO, 6,
			[[0.50, GROUND - SINK, 0.08], [0.55, GROUND + 0.04, 0.08], [0.46, GROUND + 0.10, 0.06]], col.darkened(0.1))
	_part = cap
	_boulder(st, Vector3(0.02, 0, -0.02), 6,
			[[0.46, GROUND + 0.0, 0.08], [0.48, GROUND + 0.10, 0.10], [0.36, GROUND + top, 0.12]], col)

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
	_base(st, Color(0.27, 0.22, 0.22), 0.30, BREAKS[4])
	var rust := Color.WHITE
	_part = BREAKS[4]
	_box(st, Vector3(0.0, GROUND + 0.42, 0.02), _turn(0.4, 0.35, 0.25), Vector3(0.24, 0.22, 0.20), rust, true)
	_part = BREAKS[3]
	_box(st, Vector3(0.28, GROUND + 0.30, -0.12), _turn(1.2, -0.5, 0.6), Vector3(0.17, 0.15, 0.14), rust, true)
	_part = BREAKS[2]
	_box(st, Vector3(-0.27, GROUND + 0.28, 0.20), _turn(2.3, 0.7, -0.4), Vector3(0.15, 0.16, 0.12), rust, true)
	_part = BREAKS[1]
	_box(st, Vector3(-0.10, GROUND + 0.30, -0.32), _turn(0.9, -0.3, 0.9), Vector3(0.11, 0.10, 0.10), rust, true)
	_part = BREAKS[0]
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
	_base(st, Color(0.22, 0.25, 0.25), 0.20, BREAKS[3])
	_part = BREAKS[4]
	_stratum(st, Vector3(0.02, 0, 0.0), 0.40, GROUND + 0.05, GROUND + 0.28, 6)
	_part = BREAKS[2]
	_stratum(st, Vector3(-0.06, 0, 0.05), 0.30, GROUND + 0.26, GROUND + 0.48, 6)
	_part = BREAKS[0]
	_stratum(st, Vector3(0.05, 0, -0.02), 0.20, GROUND + 0.46, GROUND + 0.66, 5)
	_part = BREAKS[1]
	_stratum(st, Vector3(0.30, 0, -0.22), 0.13, GROUND + 0.20, GROUND + 0.40, 5)
	return st

## A crystal column, TerraTech's: a THICK hexagonal prism from its foot under the ground, a short
## faceted point, the shoulder ring a little wider than the foot.
func _column(st: SurfaceTool, foot: Vector3, dir: Vector3, lean: float, h: float, r: float,
		brk: float, stub: float = 0.0) -> void:
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
	_part = brk
	for i in 6:
		var j: int = (i + 1) % 6
		_quad(st, lo[i], lo[j], hi[j], hi[i], inside, Color.WHITE, true)
		_tri(st, hi[i], hi[j], tip, inside, Color.WHITE, true)
	if stub <= 0.0:
		return
	# the broken-off stump that stays: a sleeve a hair wider than the column, cut flat at `stub`
	_part = RUBBLE
	var top: Array = []
	var bot: Array = []
	for i in 6:
		var o: Vector3 = (lo[i] - foot) * 1.06
		bot.append(foot + o)
		top.append(foot + up * stub + o)
	var cap: Vector3 = foot + up * stub
	for i in 6:
		var j: int = (i + 1) % 6
		_quad(st, bot[i], bot[j], top[j], top[i], foot + up * stub * 0.5, Color.WHITE, true)
		_tri(st, top[i], top[j], cap, foot, Color(0.75, 0.75, 0.75), true)

## SILICATE: a cluster of thick crystal columns growing straight out of the ground, TerraTech's
## crystal node - a tall one in the middle, a ring leaning out round it and small shards at the
## foot. Turned down on the way: big thin crystals on a stone slab ("a plinth"), then a tall rock
## with a brush of thin crystals on top ("still not it").
func _silicate() -> SurfaceTool:
	var st := _begin()
	var y0 := GROUND - 0.25                              # every foot starts under the ground
	_column(st, Vector3(0.02, y0, 0.0), Vector3(0.3, 0, -0.2), 0.06, 1.85, 0.24, BREAKS[4], 0.42)
	var ring := 5
	var ring_breaks := [BREAKS[1], BREAKS[2], BREAKS[1], BREAKS[3], BREAKS[2]]
	for i in ring:
		var ang: float = TAU * float(i) / float(ring) + _rng.randf_range(-0.2, 0.2)
		var dir := Vector3(cos(ang), 0, sin(ang))
		var foot := dir * _rng.randf_range(0.17, 0.24) + Vector3(0, y0, 0)
		_column(st, foot, dir, _rng.randf_range(0.30, 0.55), _rng.randf_range(0.95, 1.35),
				_rng.randf_range(0.14, 0.19), ring_breaks[i], 0.36)
	for i in 3:
		var ang: float = TAU * (float(i) + 0.5) / 3.0 + _rng.randf_range(-0.3, 0.3)
		var dir := Vector3(cos(ang), 0, sin(ang))
		_column(st, dir * 0.40 + Vector3(0, GROUND - 0.12, 0), dir, _rng.randf_range(0.7, 0.95),
				_rng.randf_range(0.40, 0.55), 0.09, BREAKS[0])
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
	_base(st, Color(0.24, 0.24, 0.27), 0.24, BREAKS[3])
	_part = BREAKS[4]
	_shard(st, Vector3(0.0, GROUND + 0.18, 0.0), Vector3(0.10, 0, -0.08), 0.24, 0.62, 5)
	_part = BREAKS[2]
	_shard(st, Vector3(0.24, GROUND + 0.12, 0.16), Vector3(0.45, 0, 0.25), 0.16, 0.40, 5)
	_part = BREAKS[1]
	_shard(st, Vector3(-0.24, GROUND + 0.12, 0.10), Vector3(-0.50, 0, 0.10), 0.15, 0.36, 4)
	_part = BREAKS[0]
	_shard(st, Vector3(-0.06, GROUND + 0.10, -0.28), Vector3(-0.10, 0, -0.55), 0.13, 0.30, 4)
	return st

## THE TREE. Its stump IS THE BOTTOM OF ITS OWN TRUNK - the same faces, the same radius at the cut,
## one ring shared by both - so what a felling leaves is the root of that tree; the first stump was
## a squat cone twice the trunk's width, and the player read it as some other object. Both cut faces
## are pale wood, so the falling trunk shows its cut too. About 5.5 m tall (the player: "bigger").
const CUT_Y := 0.42            # the cut over the ground
const TRUNK_R := 0.27          # the trunk's radius at the cut
const WOOD := Color(0.78, 0.62, 0.40)



# ── TREES BY BIOME (after TerraTech's, the player's screenshots) ─────────────────────────────────
# Two attempts at a mountain tree were turned down (a conifer of needle cones, then a faceted fir:
# "too plain, the others carry their leaves on top"), so there are three: vein_tree1 a BROADLEAF with chunky faceted crown
# lumps and vein_tree2 a FLAT-CROWN teal tree on a forked trunk on the meadow; vein_tree3 a PALM in
# the desert. Every one keeps the felling rules of `_tree`: its stump is the base of ITS OWN trunk
# up to CUT_Y with a pale cut, UV.x 1 on everything above, which is what falls.
const LEAF := Color(0.46, 0.76, 0.24)
const LEAF_DEEP := Color(0.30, 0.60, 0.20)
const TEAL := Color(0.20, 0.64, 0.72)
const TEAL_UNDER := Color(0.12, 0.40, 0.50)
const GLOW := Color(0.72, 0.46, 0.86)
const PALM_BARK := Color(0.62, 0.47, 0.30)
const FROND := Color(0.32, 0.62, 0.24)

## The stump every tree stands on: its own trunk ring at the cut (radius r), a flare under the
## ground, and both cut faces. Returns the cut ring; `_part` is left at 1 for what grows above.
func _stump(st: SurfaceTool, n: int, r: float, bark: Color) -> Array:
	var cut_y: float = GROUND + CUT_Y
	var cut := _ring(Vector3.ZERO, n, r, cut_y, 0.0, 0.0)
	var inside := Vector3(0, GROUND, 0)
	_part = 0.0
	var lo := _ring(Vector3.ZERO, n, r * 1.6, GROUND - SINK, 0.05, 0.0)
	var flare := _ring(Vector3.ZERO, n, r * 1.25, GROUND + 0.08, 0.03, 0.0)
	for k in n:
		var j: int = (k + 1) % n
		_quad(st, lo[k], lo[j], flare[j], flare[k], inside, bark.darkened(0.18), false)
		_quad(st, flare[k], flare[j], cut[j], cut[k], inside, bark.darkened(0.06), false)
	var mid := Vector3(0, cut_y, 0)
	for k in n:
		_tri(st, cut[k], cut[(k + 1) % n], mid, Vector3(0, cut_y - 1.0, 0), WOOD, false)
	_part = 1.0
	for k in n:
		_tri(st, cut[(k + 1) % n], cut[k], mid, Vector3(0, cut_y + 1.0, 0), WOOD.darkened(0.1), false)
	return cut

## A limb from ring `a` (already built) to a ring of radius r1 around `top`.
func _limb(st: SurfaceTool, a: Array, top: Vector3, r1: float, col: Color) -> Array:
	var n: int = a.size()
	var b := _ring(top - Vector3(0, top.y, 0), n, r1, top.y, 0.0, 0.0)
	var c0: Vector3 = Vector3.ZERO
	for p in a:
		c0 += p
	c0 /= float(n)
	for k in n:
		var j: int = (k + 1) % n
		_quad(st, a[k], a[j], b[j], b[k], (c0 + top) * 0.5, col, false)
	return b

## A chunky faceted lump (a crown cluster): a pole, three jittered rings, a pole.
func _lump(st: SurfaceTool, c: Vector3, r: float, h: float, col: Color, sides: int = 6) -> void:
	var cx := Vector3(c.x, 0.0, c.z)            # `_ring` adds its own y to the centre's
	var rings := [_ring(cx, sides, r * 0.62, c.y - h * 0.42, 0.12, 0.0),
			_ring(cx, sides, r, c.y - h * 0.05, 0.12, 0.5), _ring(cx, sides, r * 0.72, c.y + h * 0.36, 0.14, 1.0)]
	var bot := c + Vector3(0, -h * 0.5, 0)
	var top := c + Vector3(_rng.randf_range(-0.08, 0.08), h * 0.55, _rng.randf_range(-0.08, 0.08))
	for i in 2:
		for k in sides:
			var j: int = (k + 1) % sides
			_quad(st, rings[i][k], rings[i][j], rings[i + 1][j], rings[i + 1][k], c, col if i == 1 else col.darkened(0.12), false)
	for k in sides:
		var j: int = (k + 1) % sides
		_tri(st, rings[2][k], rings[2][j], top, c, col.lightened(0.06), false)
		_tri(st, rings[0][j], rings[0][k], bot, c, col.darkened(0.28), false)

func _broadleaf() -> SurfaceTool:
	var st := _begin()
	var n := 6
	var cut := _stump(st, n, 0.22, BARK)
	var fork := _limb(st, cut, Vector3(0.05, GROUND + 1.55, 0.0), 0.17, BARK)
	var tips := [Vector3(-0.55, GROUND + 2.55, 0.25), Vector3(0.6, GROUND + 2.75, -0.2), Vector3(0.05, GROUND + 3.0, 0.5)]
	for t in tips:
		_limb(st, fork, t, 0.07, BARK.darkened(0.05))
	var lumps := [[Vector3(-0.85, GROUND + 2.9, 0.35), 1.1, 1.2], [Vector3(0.9, GROUND + 3.1, -0.3), 1.15, 1.25],
			[Vector3(0.05, GROUND + 3.4, 0.7), 1.0, 1.15], [Vector3(0.0, GROUND + 3.7, -0.45), 1.0, 1.1],
			[Vector3(0.1, GROUND + 4.2, 0.1), 0.85, 1.0]]
	for i in lumps.size():
		var col: Color = LEAF.lerp(LEAF_DEEP, _rng.randf_range(0.0, 0.5))
		_lump(st, lumps[i][0], lumps[i][1], lumps[i][2], col)
	return st

func _flatcrown() -> SurfaceTool:
	var st := _begin()
	var n := 6
	var cut := _stump(st, n, 0.26, BARK)
	var split := _limb(st, cut, Vector3(0.0, GROUND + 0.9, 0.0), 0.22, BARK)
	# a V of two trunks splaying apart, each into the crown's underside - the crossed pair read as
	# a diamond hung under a gem (the player: "strange")
	var a1 := _limb(st, split, Vector3(-0.55, GROUND + 1.9, 0.15), 0.15, BARK.darkened(0.04))
	_limb(st, a1, Vector3(-0.85, GROUND + 2.55, 0.2), 0.11, BARK.darkened(0.04))
	var b1 := _limb(st, split, Vector3(0.5, GROUND + 1.85, -0.2), 0.15, BARK)
	_limb(st, b1, Vector3(0.8, GROUND + 2.5, -0.3), 0.11, BARK)
	# the crown: wide FLAT lumps side by side, chunky as the broadleaf's, flattened on top - one
	# thick faceted cap, wide above and drawn in below
	var lumps := [[Vector3(-0.7, GROUND + 2.95, 0.2), 1.35], [Vector3(0.75, GROUND + 2.9, -0.25), 1.3],
			[Vector3(0.05, GROUND + 3.1, 0.75), 1.2], [Vector3(0.0, GROUND + 3.05, -0.8), 1.15],
			[Vector3(0.0, GROUND + 3.2, 0.0), 1.3]]
	for i in lumps.size():
		var col: Color = TEAL.lerp(TEAL_UNDER, _rng.randf_range(0.0, 0.25))
		if i == 1 or i == 3:
			col = col.lerp(GLOW, 0.35)          # a violet cast on two of them, as on the screenshot
		_flat_lump(st, lumps[i][0], lumps[i][1], 0.95, col)
	return st

## A lump squashed flat on top and drawn in below: the teal tree's crown is made of these.
func _flat_lump(st: SurfaceTool, c: Vector3, r: float, h: float, col: Color) -> void:
	var sides := 7
	var cx := Vector3(c.x, 0.0, c.z)
	var rings := [_ring(cx, sides, r * 0.45, c.y - h * 0.45, 0.10, 0.0),
			_ring(cx, sides, r, c.y + h * 0.05, 0.10, 0.5), _ring(cx, sides, r * 0.85, c.y + h * 0.40, 0.06, 1.0)]
	var bot := c + Vector3(0, -h * 0.55, 0)
	var top := c + Vector3(_rng.randf_range(-0.1, 0.1), h * 0.46, _rng.randf_range(-0.1, 0.1))
	for i in 2:
		for k in sides:
			var j: int = (k + 1) % sides
			_quad(st, rings[i][k], rings[i][j], rings[i + 1][j], rings[i + 1][k], c,
					col.darkened(0.35) if i == 0 else col, false)
	for k in sides:
		var j: int = (k + 1) % sides
		_tri(st, rings[2][k], rings[2][j], top, c, col.lightened(0.08), false)
		_tri(st, rings[0][j], rings[0][k], bot, c, col.darkened(0.45), false)

## A frond: a strip from the crown out and down, seen from both sides (the shader culls backs).
func _frond(st: SurfaceTool, base: Vector3, dir: Vector3, length: float, width: float) -> void:
	var side: Vector3 = dir.cross(Vector3.UP).normalized()
	var pts: Array = []
	var segs := 4
	for i in segs + 1:
		var t: float = float(i) / float(segs)
		var p: Vector3 = base + dir * (length * t) + Vector3.DOWN * (length * 0.8 * t * t)
		var w: float = width * (1.0 - t * 0.85) * (0.6 if i == 0 else 1.0)
		pts.append([p - side * w, p + side * w])
	for i in segs:
		var a: Vector3 = pts[i][0]
		var b: Vector3 = pts[i][1]
		var c2: Vector3 = pts[i + 1][1]
		var d: Vector3 = pts[i + 1][0]
		var col: Color = FROND.lerp(FROND.lightened(0.2), float(i) / float(segs))
		var mid: Vector3 = (a + b + c2 + d) * 0.25
		_quad(st, a, b, c2, d, mid + Vector3.DOWN * 0.3, col, false)
		_quad(st, a, b, c2, d, mid + Vector3.UP * 0.3, col.darkened(0.25), false)

func _palm() -> SurfaceTool:
	var st := _begin()
	var n := 6
	var ring := _stump(st, n, 0.22, PALM_BARK)
	# a curved, ringed trunk: each segment flares a little at its foot
	var segs := 8
	var lean := Vector3(0.9, 0.0, 0.25)
	var top := Vector3.ZERO
	for i in segs:
		var t: float = float(i + 1) / float(segs)
		top = lean * (t * t) + Vector3(0.0, GROUND + CUT_Y + 3.8 * t, 0.0)
		var col: Color = PALM_BARK if i % 2 == 0 else PALM_BARK.darkened(0.12)
		ring = _limb(st, ring, top, 0.21 - 0.07 * t, col)
	# the crown: seven fronds out and drooping, and three nuts under them
	for k in 8:
		var a: float = TAU * float(k) / 8.0 + _rng.randf_range(-0.2, 0.2)
		var dir := Vector3(cos(a), _rng.randf_range(0.25, 0.5), sin(a)).normalized()
		_frond(st, top + Vector3.UP * 0.05, dir, _rng.randf_range(2.0, 2.4), 0.42)
	for k in 3:
		var a: float = TAU * float(k) / 3.0
		_lump(st, top + Vector3(cos(a) * 0.16, -0.12, sin(a) * 0.16), 0.11, 0.2, Color(0.42, 0.30, 0.16), 5)
	return st
