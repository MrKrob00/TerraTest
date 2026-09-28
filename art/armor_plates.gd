extends SceneTree
# Builds the big armour plates (x2 2x1, x4 2x2, x9 3x3):
#
#   godot --headless --path . --script res://art/armor_plates.gd
#       -> blocks/meshes/armor_2x1.tres, armor_2x2.tres, armor_3x3.tres
#
# ONE SLAB, NOT A GRID OF SMALL PLATES. The first cut tiled the artist's one-cell plate and read as
# a grid of plates with blue ribs between them; the player wanted a whole piece with something to
# look at inside. So: the small plate's own frame (its bevel and rim, its measurements) round the
# OUTSIDE only, one grey panel across the whole plate, and on it a raised reinforcing slab with
# chamfered edges, four blue braces from the slab's corners to the panel's, a blue diamond on the
# slab and bolts - at the slab's corners, at the braces' ends and along the rim where the cells
# meet, so a x9 still tells its size. On the artist's two materials (GSO_Plane), so it stands beside
# the x1 as one family.
#
# The plate lies in its mesh's XZ plane like the small one; the scenes turn it -90 deg about X onto
# the cells' back face, so the side that shows is -Y and a cell at block (dx, dy) sits at mesh
# (dx, 0, -dy). Cells are the footprints in blocks._footprint_offsets.
const SRC := "res://objects/GSO_Plane.res"

# The small plate's own numbers (GSO_Plane): thickness, bevel foot, rim.
const T := 0.107178
const BEVEL := 0.034599         # 0.5 - 0.465401
const RIM := 0.066394           # 0.5 - 0.433606

const SLAB_IN := 0.30           # the reinforcing slab's inset from the panel edge
const SLAB_H := 0.03
const SLAB_CH := 0.035          # its chamfer
const BRACE_W := 0.10
const BRACE_H := 0.03
const BOLT_R := 0.036
const BOLT_H := 0.022

# name: [cells across, cells up, centre x, centre z] in the mesh's plane
const PLATES := {
	"armor_2x1": [2, 1, -0.5, 0.0],
	"armor_2x2": [2, 2, -0.5, -0.5],
	"armor_3x3": [3, 3, 0.0, 0.0],
}

var _v: Dictionary = {}          # material key -> [verts, normals]

func _init() -> void:
	var src: ArrayMesh = load(SRC)
	var mats := {}
	for s in src.get_surface_count():
		var m: Material = src.surface_get_material(s)
		mats[m.resource_name] = m
	for name in PLATES:
		var p: Array = PLATES[name]
		_v = {"Blue": [PackedVector3Array(), PackedVector3Array()], "Gray": [PackedVector3Array(), PackedVector3Array()]}
		_build(float(p[0]), float(p[1]), float(p[2]), float(p[3]))
		var out := ArrayMesh.new()
		for key in ["Gray", "Blue"]:
			var arr := []
			arr.resize(Mesh.ARRAY_MAX)
			arr[Mesh.ARRAY_VERTEX] = _v[key][0]
			arr[Mesh.ARRAY_NORMAL] = _v[key][1]
			out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
			out.surface_set_material(out.get_surface_count() - 1, mats[key])
		out.resource_name = name
		var dst := "res://blocks/meshes/%s.tres" % name
		var err := ResourceSaver.save(out, dst)
		var tris: int = (_v["Gray"][0].size() + _v["Blue"][0].size()) / 3
		print("saved ", dst, " err ", err, " tris ", tris)
	quit()

## A flat polygon (convex, in order) facing `n`; the materials draw both sides, so the winding only
## has to agree with the normal for the light.
##
## THE NORMALS ARE THE ARTIST'S WAY ROUND, i.e. INVERTED: GSO_Plane's showing face carries +Y (into the
## plate, towards the block it is bolted to), and so does everything else on it. Drawn with outward
## normals a big plate lit as the x1's opposite - black where the x1 was grey, in the same light - so
## they are turned the way the x1's are, and the family shades as one under any sun.
func _poly(key: String, pts: Array, n: Vector3) -> void:
	n = -n
	var vs: PackedVector3Array = _v[key][0]
	var ns: PackedVector3Array = _v[key][1]
	var face: Vector3 = (pts[1] - pts[0]).cross(pts[2] - pts[0])
	if face.dot(n) > 0.0:                       # front face clockwise, as on GSO_Plane itself
		pts = pts.duplicate()
		pts.reverse()
	for i in range(1, pts.size() - 1):
		for q in [pts[0], pts[i], pts[i + 1]]:
			vs.append(q)
			ns.append(n)
	_v[key][0] = vs
	_v[key][1] = ns

## A rectangle's corners at height y, inset by `d` from [x0,x1]x[z0,z1].
func _rect(x0: float, x1: float, z0: float, z1: float, d: float, y: float) -> Array:
	return [Vector3(x0 + d, y, z0 + d), Vector3(x1 - d, y, z0 + d), Vector3(x1 - d, y, z1 - d), Vector3(x0 + d, y, z1 - d)]

## A frustum from the rectangle `lo` up (toward -Y) to `hi`: top face and four sloped sides.
func _frustum(key: String, lo: Array, hi: Array) -> void:
	_poly(key, hi, Vector3.DOWN)
	var c := Vector3.ZERO
	for q in lo:
		c += q / 4.0
	for i in 4:
		var j := (i + 1) % 4
		var side := [lo[i], lo[j], hi[j], hi[i]]
		var mid: Vector3 = (lo[i] + lo[j]) * 0.5
		var out: Vector3 = mid - c
		out.y = 0.0
		var n: Vector3 = (out.normalized() + Vector3.DOWN * 0.6).normalized()
		_poly(key, side, n)

func _bolt(x: float, z: float, y: float) -> void:
	var lo := []
	var hi := []
	for i in 8:
		var a := (i + 0.5) * TAU / 8.0
		lo.append(Vector3(x + BOLT_R * cos(a), y, z + BOLT_R * sin(a)))
		hi.append(Vector3(x + BOLT_R * 0.8 * cos(a), y - BOLT_H, z + BOLT_R * 0.8 * sin(a)))
	_poly("Blue", hi, Vector3.DOWN)
	for i in 8:
		var j := (i + 1) % 8
		var mid: Vector3 = (lo[i] + lo[j]) * 0.5 - Vector3(x, y, z)
		_poly("Blue", [lo[i], lo[j], hi[j], hi[i]], (mid.normalized() + Vector3.DOWN * 0.4).normalized())

## A brace: a low bar from a to b (both on the panel face), its top and two long sides.
func _brace(a: Vector3, b: Vector3, y: float) -> void:
	var d: Vector3 = (b - a).normalized()
	var s: Vector3 = Vector3(-d.z, 0.0, d.x) * (BRACE_W * 0.5)
	var lo := [a + s, b + s, b - s, a - s]
	var up := Vector3(0.0, -BRACE_H, 0.0)
	var top := [a + s * 0.75 + up, b + s * 0.75 + up, b - s * 0.75 + up, a - s * 0.75 + up]
	_poly("Blue", top, Vector3.DOWN)
	_poly("Blue", [lo[0], lo[1], top[1], top[0]], (s.normalized() + Vector3.DOWN * 0.5).normalized())
	_poly("Blue", [lo[2], lo[3], top[3], top[2]], (-s.normalized() + Vector3.DOWN * 0.5).normalized())

func _build(w: float, h: float, cx: float, cz: float) -> void:
	var x0 := cx - w * 0.5
	var x1 := cx + w * 0.5
	var z0 := cz - h * 0.5
	var z1 := cz + h * 0.5
	var face := -T                               # the side that shows
	# Back: flat against the cells.
	_poly("Blue", _rect(x0, x1, z0, z1, 0.0, 0.0), Vector3.UP)
	# Outer bevel, the small plate's: from the cell edge at the back to the bevel foot at the face.
	var back := _rect(x0, x1, z0, z1, 0.0, 0.0)
	var foot := _rect(x0, x1, z0, z1, BEVEL, face)
	var c := Vector3(cx, 0.0, cz)
	for i in 4:
		var j := (i + 1) % 4
		var mid: Vector3 = (back[i] + back[j]) * 0.5 - c
		mid.y = 0.0
		_poly("Blue", [back[i], back[j], foot[j], foot[i]], (mid.normalized() + Vector3.DOWN * 0.3).normalized())
	# The rim, between the bevel foot and the panel.
	var inner := _rect(x0, x1, z0, z1, RIM, face)
	for i in 4:
		var j := (i + 1) % 4
		_poly("Blue", [foot[i], foot[j], inner[j], inner[i]], Vector3.DOWN)
	# One grey panel across the whole plate.
	_poly("Gray", inner, Vector3.DOWN)
	# The reinforcing slab.
	var slab_lo := _rect(x0, x1, z0, z1, RIM + SLAB_IN, face)
	var slab_hi := _rect(x0, x1, z0, z1, RIM + SLAB_IN + SLAB_CH, face - SLAB_H)
	_frustum("Gray", slab_lo, slab_hi)
	# Braces from the panel's corners to the slab's, bolted at both ends.
	var pc := _rect(x0, x1, z0, z1, RIM + 0.07, face)
	for i in 4:
		_brace(pc[i], slab_lo[i], face)
		_bolt(pc[i].x, pc[i].z, face - BRACE_H)
	# The diamond on the slab: its points on the slab's axes, a third of the slab's shorter side.
	var top_y := face - SLAB_H
	var r: float = minf(w, h) * 0.17
	var dia_lo := [Vector3(cx - r, top_y, cz), Vector3(cx, top_y, cz - r), Vector3(cx + r, top_y, cz), Vector3(cx, top_y, cz + r)]
	var dia_hi := []
	for q in dia_lo:
		dia_hi.append(Vector3(cx + (q.x - cx) * 0.8, top_y - 0.014, cz + (q.z - cz) * 0.8))
	_frustum("Blue", dia_lo, dia_hi)
	# Bolts at the slab's corners.
	for q in _rect(x0, x1, z0, z1, RIM + SLAB_IN + SLAB_CH + 0.06, top_y):
		_bolt(q.x, q.z, top_y)
	# Bolts along the rim where the cells meet, so the plate still tells how big it is.
	for i in range(1, int(w)):
		for z in [z0 + (BEVEL + RIM) * 0.5, z1 - (BEVEL + RIM) * 0.5]:
			_bolt(x0 + i, z, face)
	for i in range(1, int(h)):
		for x in [x0 + (BEVEL + RIM) * 0.5, x1 - (BEVEL + RIM) * 0.5]:
			_bolt(x, z0 + i, face)
