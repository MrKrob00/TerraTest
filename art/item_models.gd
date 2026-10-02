extends SceneTree
# THE LOOSE ITEM MODELS: raw ore per metal, a log, a component and a block chunk, low poly, saved as
# meshes resource.gd puts in its picture. Run on a copy of the project (CLAUDE.md §3):
#   godot --headless --path <copy> --script res://art/item_models.gd
# and copy resources/items/*.tres back. The INGOT is the artist's own (objects/Assets.glb
# `ingot_metal`), tinted per metal by resource.gd. Their `coal` is not used: it samples a near-black
# patch of the atlas and read as a black blot with no faces.
#
# RAW ORE IS A PIECE OF ITS VEIN (art/vein_models.gd): a rusty chunk of ferrite, a banded slab of
# cuprite, a silicate crystal shard, a jagged titanite shard - what the player saw break off is what
# lies on the ground. They used to be one octahedron in a metre-wide additive bubble (256 triangles
# of bubble for 8 of item); now 12-40 triangles, and the shape tells the metal before the colour does.
#
# Same rules as the veins: flat faces toned from one fixed light, unshaded. A tinted vertex is a GREY
# TONE the material multiplies by the metal's colour (resource.gd); alpha is unused. Origin at the
# model's FOOT, centred: resource.gd stands it where the bubble's bottom was, so every belt slot,
# tray and hold height made for the bubble still holds it.

const LIGHT := Vector3(0.45, 1.0, 0.3)
const OUT := "res://resources/items/"
const BARK := Color(0.50, 0.33, 0.20)
const WOOD_END := Color(0.80, 0.64, 0.40)
const CRATE := Color(0.24, 0.23, 0.28)
const STRAP := Color(0.30, 0.42, 0.69)        # GSO blue
const NUT_DARK := Color(0.16, 0.16, 0.19)

var _rng := RandomNumberGenerator.new()

func _initialize() -> void:
	_rng.seed = 4242
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT))
	_save(_ferrite(), "ore0")
	_save(_cuprite(), "ore1")
	_save(_silicate(), "ore2")
	_save(_titanite(), "ore3")
	_save(_log(), "wood")
	_save(_component(), "component")
	_save(_chunk(), "chunk")
	_save(_coal(), "coal")
	quit()

func _save(st: SurfaceTool, name: String) -> void:
	var m: ArrayMesh = st.commit()
	m.resource_name = "item_" + name
	var err := ResourceSaver.save(m, OUT + name + ".tres")
	print("%s: %d triangles, aabb %s, save %d" % [name, m.surface_get_array_len(0) / 3, m.get_aabb(), err])

func _tone(n: Vector3) -> float:
	return 0.70 + 0.42 * maxf(n.dot(LIGHT.normalized()), 0.0)

## One flat triangle, front away from `inside`, added clockwise as Godot wants. A white `col` is a
## tint tone (grey, the material colours it); any other colour is fixed.
func _tri(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, inside: Vector3, col: Color) -> void:
	var n: Vector3 = (b - a).cross(c - a).normalized()
	if n.dot((a + b + c) / 3.0 - inside) < 0.0:
		var t := b; b = c; c = t
		n = -n
	var k: float = _tone(n)
	var cc := Color(clampf(col.r * k / 1.12, 0, 1), clampf(col.g * k / 1.12, 0, 1), clampf(col.b * k / 1.12, 0, 1))
	for p in [a, c, b]:
		st.set_color(cc)
		st.set_normal(n)
		st.add_vertex(p)

func _quad(st, a, b, c, d, inside, col) -> void:
	_tri(st, a, b, c, inside, col)
	_tri(st, a, c, d, inside, col)

func _begin() -> SurfaceTool:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	return st

func _ring(c: Vector3, n: int, r: float, y: float, jit: float, phase: float) -> Array:
	var out: Array = []
	for i in n:
		var a: float = phase + TAU * float(i) / float(n) + _rng.randf_range(-0.15, 0.15)
		var rr: float = r * (1.0 + _rng.randf_range(-jit, jit))
		out.append(c + Vector3(cos(a) * rr, y + _rng.randf_range(-jit, jit) * r * 0.4, sin(a) * rr))
	return out

func _box(st: SurfaceTool, c: Vector3, b: Basis, h: Vector3, col: Color) -> void:
	var p: Array = []
	for i in 8:
		var s := Vector3(1 if i & 1 else -1, 1 if i & 2 else -1, 1 if i & 4 else -1)
		p.append(c + b * (s * h))
	for f in [[0, 1, 3, 2], [4, 6, 7, 5], [0, 4, 5, 1], [2, 3, 7, 6], [0, 2, 6, 4], [1, 5, 7, 3]]:
		_quad(st, p[f[0]], p[f[1]], p[f[2]], p[f[3]], c, col)

## Lift a finished model so its lowest point is y = 0.
func _foot(st: SurfaceTool) -> SurfaceTool:
	var arr := st.commit_to_arrays()
	var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
	var lo := INF
	for p in v:
		lo = minf(lo, p.y)
	for i in v.size():
		v[i].y -= lo
	arr[Mesh.ARRAY_VERTEX] = v
	var out := SurfaceTool.new()
	out.create_from_arrays(arr)
	return out

## FERRITE: a rusty angular chunk - two boxes grown into each other, as the vein's chunks are.
func _ferrite() -> SurfaceTool:
	var st := _begin()
	_box(st, Vector3(0, 0.14, 0), Basis(Vector3.UP, 0.4) * Basis(Vector3.RIGHT, 0.3), Vector3(0.17, 0.13, 0.15), Color.WHITE)
	_box(st, Vector3(0.10, 0.20, 0.06), Basis(Vector3.UP, 1.3) * Basis(Vector3.FORWARD, 0.6), Vector3(0.10, 0.09, 0.09), Color.WHITE)
	return _foot(st)

## CUPRITE: a slab of the banded ore, two strata stepped.
func _cuprite() -> SurfaceTool:
	var st := _begin()
	for layer in [[Vector3(0, 0, 0), 0.22, 0.0, 0.13], [Vector3(-0.04, 0, 0.03), 0.15, 0.12, 0.24]]:
		var c: Vector3 = layer[0]
		var lo := _ring(c, 6, layer[1], layer[2], 0.14, _rng.randf() * TAU)
		var hi: Array = []
		for p in lo:
			hi.append(Vector3(c.x, layer[3], c.z) + ((p as Vector3) - Vector3(c.x, (p as Vector3).y, c.z)) * 0.88)
		var top := Vector3(c.x, layer[3] + 0.01, c.z)
		var inside := Vector3(c.x, (float(layer[2]) + float(layer[3])) * 0.5, c.z)
		for k in 6:
			var j: int = (k + 1) % 6
			_quad(st, lo[k], lo[j], hi[j], hi[k], inside, Color.WHITE)
			_tri(st, hi[k], hi[j], top, inside, Color.WHITE)
			_tri(st, lo[j], lo[k], Vector3(c.x, float(layer[2]) - 0.01, c.z), inside, Color.WHITE)
	return _foot(st)

## A hexagonal column with a point, from `foot` along `up`.
func _column(st: SurfaceTool, foot: Vector3, up: Vector3, h: float, r: float) -> void:
	up = up.normalized()
	var side: Vector3 = up.cross(Vector3.FORWARD if absf(up.z) < 0.9 else Vector3.RIGHT).normalized()
	var side2: Vector3 = up.cross(side).normalized()
	var lo: Array = []
	var hi: Array = []
	for i in 6:
		var a: float = TAU * float(i) / 6.0
		var o: Vector3 = side * cos(a) * r + side2 * sin(a) * r
		lo.append(foot + o)
		hi.append(foot + up * h * 0.75 + o)
	var tip: Vector3 = foot + up * h
	var inside: Vector3 = foot + up * h * 0.4
	for i in 6:
		var j: int = (i + 1) % 6
		_quad(st, lo[i], lo[j], hi[j], hi[i], inside, Color.WHITE)
		_tri(st, hi[i], hi[j], tip, inside, Color.WHITE)
		_tri(st, lo[j], lo[i], foot - up * 0.02, inside, Color.WHITE)

## SILICATE: a broken-off crystal lying on its side, a small one grown on it.
func _silicate() -> SurfaceTool:
	var st := _begin()
	_column(st, Vector3(-0.20, 0.10, 0), Vector3(1, 0.25, 0.1), 0.46, 0.10)
	_column(st, Vector3(-0.02, 0.12, 0.02), Vector3(0.2, 1, -0.4), 0.22, 0.05)
	return _foot(st)

## TITANITE: a jagged raw shard lying on its side.
func _titanite() -> SurfaceTool:
	var st := _begin()
	var n := 5
	var dir := Vector3(1, 0.2, 0).normalized()
	var lo := _ring(Vector3.ZERO, n, 0.13, 0.0, 0.25, 0.0)
	var mid := _ring(Vector3.ZERO, n, 0.11, 0.0, 0.3, 0.4)
	var hi := _ring(Vector3.ZERO, n, 0.05, 0.0, 0.35, 0.8)
	var b := Basis(Vector3.FORWARD, -PI * 0.5 + 0.2)          # the shard's length along +X
	var pts := [lo, mid, hi]
	var at := [-0.2, 0.02, 0.2]
	var rings: Array = []
	for r in 3:
		var row: Array = []
		for p in pts[r]:
			row.append(b * (p as Vector3) + dir * at[r] + Vector3(0, 0.13, 0))
		rings.append(row)
	var tip := dir * 0.30 + Vector3(0, 0.15, 0.02)
	var tail := -dir * 0.24 + Vector3(0, 0.12, 0)
	var inside := Vector3(0, 0.13, 0)
	for r in 2:
		for k in n:
			var j: int = (k + 1) % n
			_quad(st, rings[r][k], rings[r][j], rings[r + 1][j], rings[r + 1][k], inside, Color.WHITE)
	for k in n:
		var j: int = (k + 1) % n
		_tri(st, rings[2][k], rings[2][j], tip, inside, Color.WHITE)
		_tri(st, rings[0][j], rings[0][k], tail, inside, Color.WHITE)
	return _foot(st)

## WOOD: a log - a six-sided prism of bark with pale cut ends.
func _log() -> SurfaceTool:
	var st := _begin()
	var n := 6
	var r := 0.13
	var half := 0.28
	var a: Array = []
	var bb: Array = []
	for i in n:
		var ang: float = TAU * float(i) / float(n)
		var o := Vector3(0, sin(ang) * r, cos(ang) * r)
		a.append(Vector3(-half, r, 0) + o)
		bb.append(Vector3(half, r, 0) + o * 0.92)
	var c := Vector3(0, r, 0)
	for i in n:
		var j: int = (i + 1) % n
		_quad(st, a[i], a[j], bb[j], bb[i], c, BARK)
		_tri(st, a[j], a[i], Vector3(-half, r, 0), c, WOOD_END)
		_tri(st, bb[i], bb[j], Vector3(half, r, 0), c, WOOD_END)
	return _foot(st)

## COMPONENT: a machined part - a hex nut, its body in the component's colour round a dark bore.
func _component() -> SurfaceTool:
	var st := _begin()
	var n := 6
	var ro := 0.17
	var ri := 0.07
	var h := 0.12
	var c := Vector3(0, h * 0.5, 0)
	var ob: Array = []; var ot: Array = []; var ib: Array = []; var it: Array = []
	for i in n:
		var ang: float = TAU * float(i) / float(n)
		var d := Vector3(cos(ang), 0, sin(ang))
		ob.append(d * ro); ot.append(d * ro + Vector3(0, h, 0))
		ib.append(d * ri); it.append(d * ri + Vector3(0, h, 0))
	for i in n:
		var j: int = (i + 1) % n
		_quad(st, ob[i], ob[j], ot[j], ot[i], c, Color.WHITE)            # outer walls
		_quad(st, ot[i], ot[j], it[j], it[i], c - Vector3(0, 1, 0), Color.WHITE)   # top face
		_quad(st, ob[j], ob[i], ib[i], ib[j], c + Vector3(0, 1, 0), Color.WHITE)   # bottom face
		_quad(st, ib[j], ib[i], it[i], it[j], c + (ib[i] + ib[j]) * 4.0, NUT_DARK)  # the bore, facing in
	return _foot(st)

## CHUNK: a crate of packed blocks - a dark box with two GSO-blue straps.
func _chunk() -> SurfaceTool:
	var st := _begin()
	_box(st, Vector3(0, 0.17, 0), Basis(), Vector3(0.22, 0.17, 0.22), CRATE)
	for x in [-0.11, 0.11]:
		_box(st, Vector3(x, 0.17, 0), Basis(), Vector3(0.025, 0.175, 0.225), STRAP)
	return _foot(st)

## COAL: a burnt lump, charcoal dark but with its facets showing - three jittered rings and a cap.
const CHARCOAL := Color(0.26, 0.25, 0.29)
func _coal() -> SurfaceTool:
	var st := _begin()
	var n := 6
	var rings := [_ring(Vector3.ZERO, n, 0.13, 0.0, 0.18, 0.0), _ring(Vector3.ZERO, n, 0.19, 0.10, 0.2, 0.5),
			_ring(Vector3.ZERO, n, 0.12, 0.21, 0.25, 1.0)]
	var inside := Vector3(0, 0.11, 0)
	for r in 2:
		for k in n:
			var j: int = (k + 1) % n
			_quad(st, rings[r][k], rings[r][j], rings[r + 1][j], rings[r + 1][k], inside, CHARCOAL)
	for k in n:
		var j: int = (k + 1) % n
		_tri(st, rings[2][k], rings[2][j], Vector3(0.02, 0.26, -0.01), inside, CHARCOAL)
		_tri(st, rings[0][j], rings[0][k], Vector3(0, -0.01, 0), inside, CHARCOAL)
	return _foot(st)
