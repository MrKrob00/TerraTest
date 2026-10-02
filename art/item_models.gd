extends SceneTree
# THE LOOSE ITEM MODELS: raw ore per metal, a log, coal, one model per component and a block chunk, low poly, saved as
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
	var comps := _components()
	for i in comps.size():
		_save(comps[i], "component%d" % i)
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

# ── COMPONENTS: one model each, after its name (G.COMP_NAME). The first six are made of two ingots,
# the rest of two of those, and the model shows the parts it is made of where it can (the Torque
# Motor carries the Wound Coil's windings, the Focus Cell the Contact Ring and the Prism Lens). The
# body is TINTED (white here, the component's colour from resource.gd); the frames are fixed dark
# metal, a lens fixed glass, a screen GSO blue - one pop colour, as the blocks keep it.
const DARK := Color(0.30, 0.30, 0.35)       # 0.20 came out black on the real driver
const GLASS := Color(0.62, 0.86, 0.92)
const SCREEN := Color(0.30, 0.48, 0.80)
const T := Color.WHITE

## A frustum of `n` sides along `axis` from `c`, radius r0 at the start and r1 at the end.
func _prism(st: SurfaceTool, c: Vector3, axis: Vector3, n: int, r0: float, r1: float, h: float,
		col: Color, phase: float = 0.0) -> void:
	axis = axis.normalized()
	var u: Vector3 = axis.cross(Vector3.UP if absf(axis.y) < 0.9 else Vector3.RIGHT).normalized()
	var v: Vector3 = axis.cross(u).normalized()
	var a: Array = []
	var b: Array = []
	for i in n:
		var ang: float = phase + TAU * float(i) / float(n)
		var d: Vector3 = u * cos(ang) + v * sin(ang)
		a.append(c + d * r0)
		b.append(c + axis * h + d * r1)
	var mid: Vector3 = c + axis * h * 0.5
	for i in n:
		var j: int = (i + 1) % n
		_quad(st, a[i], a[j], b[j], b[i], mid, col)
		if r0 > 0.001:
			_tri(st, a[j], a[i], c, mid, col)
		if r1 > 0.001:
			_tri(st, b[i], b[j], c + axis * h, mid, col)

## An annulus of `n` sides along `axis`: a ring with a hole, walls in and out.
func _annulus(st: SurfaceTool, c: Vector3, axis: Vector3, n: int, ro: float, ri: float, h: float,
		col: Color) -> void:
	axis = axis.normalized()
	var u: Vector3 = axis.cross(Vector3.UP if absf(axis.y) < 0.9 else Vector3.RIGHT).normalized()
	var v: Vector3 = axis.cross(u).normalized()
	var oa: Array = []; var ob: Array = []; var ia: Array = []; var ib: Array = []
	for i in n:
		var ang: float = TAU * float(i) / float(n)
		var d: Vector3 = u * cos(ang) + v * sin(ang)
		oa.append(c + d * ro); ob.append(c + axis * h + d * ro)
		ia.append(c + d * ri); ib.append(c + axis * h + d * ri)
	for i in n:
		var j: int = (i + 1) % n
		var mid: Vector3 = c + axis * h * 0.5 + (oa[i] + oa[j] - c * 2.0) * 0.5 * ((ro + ri) / (2.0 * ro))
		_quad(st, oa[i], oa[j], ob[j], ob[i], mid, col)                      # outside
		_quad(st, ia[j], ia[i], ib[i], ib[j], mid, col)                      # bore
		_quad(st, ob[i], ob[j], ib[j], ib[i], mid - axis * h, col)           # end facing +axis
		_quad(st, oa[j], oa[i], ia[i], ia[j], mid + axis * h, col)           # end facing -axis

func _bx(st: SurfaceTool, c: Vector3, h: Vector3, col: Color, b: Basis = Basis()) -> void:
	_box(st, c, b, h, col)

const X := Vector3(1, 0, 0)
const Y := Vector3(0, 1, 0)
const Z := Vector3(0, 0, 1)

func _components() -> Array:
	var out: Array = []
	for i in 21:
		var st := _begin()
		call("_comp%d" % i, st)
		out.append(_foot(st))
	return out

## Wound Coil: windings on a spool between two dark flanges, lying on its side.
func _comp0(st) -> void:
	_prism(st, Vector3(-0.17, 0.14, 0), X, 8, 0.14, 0.14, 0.04, DARK, PI / 8)
	_prism(st, Vector3(-0.13, 0.14, 0), X, 8, 0.11, 0.11, 0.26, T, PI / 8)
	_prism(st, Vector3(0.13, 0.14, 0), X, 8, 0.14, 0.14, 0.04, DARK, PI / 8)

## Cast Plating: a thick bevelled plate with a raised cross on it.
func _comp1(st) -> void:
	_prism(st, Vector3(0, 0, 0), Y, 4, 0.25, 0.21, 0.07, T, PI / 4)
	_bx(st, Vector3(0, 0.085, 0), Vector3(0.16, 0.02, 0.035), T)
	_bx(st, Vector3(0, 0.085, 0), Vector3(0.035, 0.02, 0.16), T)

## Braced Strut: two rails held apart by three cross-braces.
func _comp2(st) -> void:
	for z in [-0.08, 0.08]:
		_bx(st, Vector3(0, 0.035, z), Vector3(0.24, 0.035, 0.025), T)
	for x in [-0.16, 0.0, 0.16]:
		_bx(st, Vector3(x, 0.035, 0), Vector3(0.018, 0.025, 0.07), DARK, Basis(Y, 0.5 if x != 0.0 else -0.5))

## Etched Wafer: a thin octagonal disc, a raised square die in the middle.
func _comp3(st) -> void:
	_prism(st, Vector3.ZERO, Y, 8, 0.2, 0.2, 0.025, T, PI / 8)
	_bx(st, Vector3(0, 0.04, 0), Vector3(0.08, 0.015, 0.08), SCREEN)

## Contact Ring: a flat ring with four contact pins standing up.
func _comp4(st) -> void:
	_annulus(st, Vector3.ZERO, Y, 10, 0.18, 0.11, 0.05, T)
	for i in 4:
		var a: float = TAU * float(i) / 4.0 + 0.4
		_bx(st, Vector3(cos(a) * 0.145, 0.08, sin(a) * 0.145), Vector3(0.015, 0.035, 0.015), DARK)

## Prism Lens: a triangular glass prism lying in a dark cradle.
func _comp5(st) -> void:
	_bx(st, Vector3(0, 0.02, 0), Vector3(0.2, 0.02, 0.09), DARK)
	_prism(st, Vector3(-0.17, 0.12, 0), X, 3, 0.1, 0.1, 0.34, GLASS, PI / 2)

## Shielded Winding: the coil inside a dark half-shell.
func _comp6(st) -> void:
	_comp0(st)
	_bx(st, Vector3(0, 0.03, 0), Vector3(0.2, 0.03, 0.16), DARK)
	for z in [-0.15, 0.15]:
		_bx(st, Vector3(0, 0.14, z), Vector3(0.2, 0.14, 0.015), T)

## Torque Motor: a drum with cooling ribs, a shaft out of one end, a mounting foot.
func _comp7(st) -> void:
	_bx(st, Vector3(0, 0.025, 0), Vector3(0.14, 0.025, 0.1), DARK)
	_prism(st, Vector3(-0.15, 0.15, 0), X, 8, 0.12, 0.12, 0.28, T, PI / 8)
	for x in [-0.1, 0.0, 0.1]:
		_prism(st, Vector3(x - 0.012, 0.15, 0), X, 8, 0.135, 0.135, 0.024, DARK, PI / 8)
	_prism(st, Vector3(0.13, 0.15, 0), X, 6, 0.035, 0.035, 0.12, DARK)

## Signal Relay: a box with a small coil on its lid and two pins under it.
func _comp8(st) -> void:
	_bx(st, Vector3(0, 0.09, 0), Vector3(0.15, 0.07, 0.11), T)
	_prism(st, Vector3(-0.08, 0.22, 0), X, 6, 0.05, 0.05, 0.16, DARK)
	for x in [-0.08, 0.08]:
		_bx(st, Vector3(x, 0.01, 0), Vector3(0.012, 0.02, 0.012), DARK)

## Dynamo Rotor: a hub with six blades, lying flat.
func _comp9(st) -> void:
	_prism(st, Vector3.ZERO, Y, 8, 0.07, 0.07, 0.1, DARK, PI / 8)
	for i in 6:
		var a: float = TAU * float(i) / 6.0
		_bx(st, Vector3(cos(a) * 0.15, 0.05, sin(a) * 0.15), Vector3(0.09, 0.012, 0.04), T, Basis(Y, -a) * Basis(X, 0.5))

## Pulse Emitter: a body with a glass cone flaring out of its front.
func _comp10(st) -> void:
	_prism(st, Vector3(-0.18, 0.11, 0), X, 8, 0.1, 0.1, 0.2, T, PI / 8)
	_prism(st, Vector3(0.02, 0.11, 0), X, 8, 0.07, 0.13, 0.14, GLASS, PI / 8)
	_prism(st, Vector3(-0.2, 0.11, 0), X, 8, 0.11, 0.11, 0.03, DARK, PI / 8)

## Armour Segment: a plate bent into a chevron, braced underneath.
func _comp11(st) -> void:
	for sd in [-1.0, 1.0]:
		_bx(st, Vector3(sd * 0.1, 0.07, 0), Vector3(0.12, 0.025, 0.17), T, Basis(Z, sd * -0.35))
	_bx(st, Vector3(0, 0.03, 0), Vector3(0.18, 0.02, 0.025), DARK)

## Logic Housing: a box with a blue screen set into its top.
func _comp12(st) -> void:
	_bx(st, Vector3(0, 0.08, 0), Vector3(0.18, 0.08, 0.13), T)
	_bx(st, Vector3(0, 0.165, 0), Vector3(0.12, 0.01, 0.08), SCREEN)

## Sealed Bearing: a thick flat ring round a dark hub, seen from its face.
func _comp13(st) -> void:
	_annulus(st, Vector3.ZERO, Y, 12, 0.19, 0.09, 0.08, T)
	_prism(st, Vector3.ZERO, Y, 8, 0.07, 0.07, 0.1, DARK, PI / 8)

## Optic Shroud: a hood opening forward with a lens at its back.
func _comp14(st) -> void:
	_prism(st, Vector3(-0.16, 0.13, 0), X, 4, 0.08, 0.16, 0.3, T, PI / 4)
	_prism(st, Vector3(-0.18, 0.13, 0), X, 8, 0.07, 0.07, 0.04, GLASS, PI / 8)

## Servo Arm: two links with a joint between them and a two-finger claw.
func _comp15(st) -> void:
	_bx(st, Vector3(-0.1, 0.04, 0), Vector3(0.11, 0.035, 0.04), T)
	_prism(st, Vector3(0.0, 0.0, -0.05), Z, 8, 0.05, 0.05, 0.1, DARK, PI / 8)
	_bx(st, Vector3(0.07, 0.1, 0), Vector3(0.09, 0.03, 0.035), T, Basis(Z, 0.8))
	for z in [-0.03, 0.03]:
		_bx(st, Vector3(0.15, 0.18, z), Vector3(0.04, 0.012, 0.01), DARK, Basis(Z, 0.3))

## Drive Axle: a shaft with a hub at each end.
func _comp16(st) -> void:
	_prism(st, Vector3(-0.22, 0.09, 0), X, 6, 0.03, 0.03, 0.44, DARK)
	for x in [-0.2, 0.14]:
		_prism(st, Vector3(x, 0.09, 0), X, 8, 0.09, 0.09, 0.06, T, PI / 8)

## Sight Mount: a scope tube on a short post over a base plate.
func _comp17(st) -> void:
	_bx(st, Vector3(0, 0.015, 0), Vector3(0.11, 0.015, 0.09), T)
	_bx(st, Vector3(0, 0.08, 0), Vector3(0.025, 0.05, 0.025), DARK)
	_prism(st, Vector3(-0.15, 0.17, 0), X, 6, 0.045, 0.045, 0.3, T)
	_prism(st, Vector3(0.15, 0.17, 0), X, 6, 0.045, 0.05, 0.02, GLASS)

## Control Chip: a square chip with pins along all four sides.
func _comp18(st) -> void:
	_bx(st, Vector3(0, 0.03, 0), Vector3(0.13, 0.025, 0.13), DARK)
	_bx(st, Vector3(0, 0.06, 0), Vector3(0.07, 0.008, 0.07), T)
	for i in 4:
		var d := Vector3(cos(TAU * i / 4.0), 0, sin(TAU * i / 4.0))
		var side := Vector3(-d.z, 0, d.x)
		for k in [-0.07, 0.0, 0.07]:
			_bx(st, d * 0.15 + side * k + Vector3(0, 0.02, 0), Vector3(0.02, 0.008, 0.012), T, Basis(Y, -TAU * i / 4.0))

## Optic Sensor: a box with a glass dome eye.
func _comp19(st) -> void:
	_bx(st, Vector3(0, 0.06, 0), Vector3(0.14, 0.06, 0.12), T)
	_prism(st, Vector3(0, 0.12, 0), Y, 8, 0.09, 0.03, 0.08, GLASS, PI / 8)

## Focus Cell: a cylinder cell with the Contact Ring round its middle and the Prism Lens's glass on top.
func _comp20(st) -> void:
	_prism(st, Vector3.ZERO, Y, 8, 0.11, 0.11, 0.26, T, PI / 8)
	_annulus(st, Vector3(0, 0.1, 0), Y, 8, 0.14, 0.11, 0.05, DARK)
	_prism(st, Vector3(0, 0.26, 0), Y, 8, 0.08, 0.02, 0.07, GLASS, PI / 8)
