extends SceneTree
# BIOME PROPS - small cheap things on the ground, one set per biome, ~50 triangles each. NOT IN THE
# GAME: a model goes in only after the player has seen it and said yes (CLAUDE.md). This builds
# every prop, checks its triangle budget, and photographs the line-up on the real driver:
#   xvfb-run -a -s "-screen 0 1200x700x24" godot --path <copy> --rendering-driver opengl3 \
#       --resolution 1200x700 --script res://art/biome_props.gd
# -> user://props_<biome>.png. Same rules as the veins (art/vein_models.gd): flat faces, each toned
# from one fixed light, colour in the vertex, unshaded - so it costs what a block costs.

const LIGHT := Vector3(0.45, 1.0, 0.3)
const BUDGET := 60

var _rng := RandomNumberGenerator.new()
var _tris := 0

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	var sets := {
		"meadow": [["daisies", _daisies], ["tulips", _tulips], ["mushrooms", _mushrooms], ["clover", _clover]],
		"desert": [["cactus", _cactus], ["dry_bush", _dry_bush], ["skull_rock", _bleached_rock], ["pebbles_sand", _pebbles.bind(Color(0.72, 0.58, 0.42))]],
		"canyon": [["pebbles_red", _pebbles.bind(Color(0.62, 0.36, 0.24))], ["stacked_stones", _cairn], ["thorn", _thorn], ["shard_rock", _shard_rock]],
		"mountain": [["snow_rock", _snow_rock], ["edelweiss", _edelweiss], ["ice_shard", _ice_shard], ["moss_stone", _moss_stone]],
		"salt": [["salt_cubes", _salt_cubes], ["salt_crust", _salt_crust]],
	}
	var report := []
	for biome in sets:
		var meshes := []
		for entry in sets[biome]:
			_rng.seed = hash(String(entry[0]))
			_tris = 0
			var st := SurfaceTool.new()
			st.begin(Mesh.PRIMITIVE_TRIANGLES)
			(entry[1] as Callable).call(st)
			var mesh: ArrayMesh = st.commit()
			var aabb := mesh.get_aabb()
			report.append("%s/%s: %d tris, %.2f x %.2f x %.2f m %s" % [biome, entry[0], _tris,
					aabb.size.x, aabb.size.y, aabb.size.z, "OK" if _tris <= BUDGET else "OVER"])
			meshes.append([entry[0], mesh])
		await _shoot(String(biome), meshes)
	for r in report:
		print(r)
	quit()

# ── the photo ───────────────────────────────────────────────────────────────
const GROUND := {"meadow": Color(0.40, 0.58, 0.27), "desert": Color(0.85, 0.72, 0.50),
		"canyon": Color(0.70, 0.45, 0.32), "mountain": Color(0.55, 0.55, 0.58), "salt": Color(0.90, 0.89, 0.86)}

func _shoot(biome: String, meshes: Array) -> void:
	var w := Node3D.new()
	root.add_child(w)
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.62, 0.72, 0.80)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.6, 0.6, 0.6)
	env.environment = e
	w.add_child(env)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.vertex_color_use_as_albedo = true
	mat.vertex_color_is_srgb = true
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	var plane := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(12, 8)
	plane.mesh = pm
	var gm := StandardMaterial3D.new()
	gm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	gm.albedo_color = GROUND[biome]
	plane.material_override = gm
	w.add_child(plane)
	var n := meshes.size()
	for i in n:
		var mi := MeshInstance3D.new()
		mi.mesh = meshes[i][1]
		mi.material_override = mat
		mi.position = Vector3((float(i) - (n - 1) * 0.5) * 1.15, 0.0, 0.0)
		mi.scale = Vector3.ONE * 2.6
		w.add_child(mi)
		var lab := Label3D.new()
		lab.text = String(meshes[i][0])
		lab.font_size = 28
		lab.pixel_size = 0.003
		lab.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		lab.position = mi.position + Vector3(0, 0.02, 0.85)
		lab.modulate = Color(0.1, 0.1, 0.1)
		w.add_child(lab)
	var cam := Camera3D.new()
	cam.fov = 48.0
	w.add_child(cam)
	cam.look_at_from_position(Vector3(0, 1.9, 3.3), Vector3(0, 0.3, 0.1), Vector3.UP)
	cam.current = true
	for i in 4:
		await process_frame
	await RenderingServer.frame_post_draw
	root.get_viewport().get_texture().get_image().save_png("user://props_%s.png" % biome)
	print("shot ", ProjectSettings.globalize_path("user://props_%s.png" % biome))
	w.queue_free()
	await process_frame

# ── the toolkit ─────────────────────────────────────────────────────────────
func _tone(n: Vector3) -> float:
	return 0.62 + 0.38 * maxf(0.0, n.normalized().dot(LIGHT.normalized()))

## One flat face, toned from the light; `out` points to the side that faces out (decides the normal).
func _tri(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, col: Color, out: Vector3 = Vector3.ZERO) -> void:
	var n: Vector3 = (b - a).cross(c - a)
	if out != Vector3.ZERO and n.dot(out) < 0.0:
		var t := b
		b = c
		c = t
		n = -n
	var k: float = _tone(n)
	var cc := Color(col.r * k, col.g * k, col.b * k)
	for v in [a, b, c]:
		st.set_color(cc)
		st.add_vertex(v)
	_tris += 1

func _ring(c: Vector3, n: int, r: float, phase: float = 0.0, jit: float = 0.0) -> Array:
	var out := []
	for i in n:
		var a: float = phase + TAU * i / n
		var rr: float = r * (1.0 + _rng.randf_range(-jit, jit))
		out.append(c + Vector3(cos(a) * rr, 0.0, sin(a) * rr))
	return out

## A faceted lump: a bottom ring at y0, a top ring at y1 (smaller), a cap point. 3n triangles.
func _lump(st: SurfaceTool, c: Vector3, n: int, r: float, h: float, top: float, col: Color, cap_col := Color(-1, 0, 0), jit := 0.18) -> void:
	var a: Array = _ring(c, n, r, _rng.randf() * TAU, jit)
	var b: Array = []
	for p in a:
		b.append(c + ((p as Vector3) - c) * top + Vector3(0, h * _rng.randf_range(0.6, 0.8), 0))
	var tip: Vector3 = c + Vector3(_rng.randf_range(-0.03, 0.03), h, _rng.randf_range(-0.03, 0.03)) * Vector3(r, 1, r)
	tip.y = c.y + h
	var cc: Color = col if cap_col.r < 0.0 else cap_col
	for i in n:
		var j: int = (i + 1) % n
		var mid: Vector3 = (a[i] + a[j] + b[i] + b[j]) * 0.25
		var outv: Vector3 = (mid - c) * Vector3(1, 0, 1)
		_tri(st, a[i], a[j], b[j], col, outv)
		_tri(st, a[i], b[j], b[i], col, outv)
		_tri(st, b[i], b[j], tip, cc, Vector3.UP)

## A thin stem, a three-sided prism from `a` to `b`. 6 triangles.
func _stem(st: SurfaceTool, a: Vector3, b: Vector3, r: float, col: Color) -> void:
	var d: Vector3 = (b - a).normalized()
	var s: Vector3 = d.cross(Vector3.FORWARD if absf(d.z) < 0.9 else Vector3.RIGHT).normalized()
	var t: Vector3 = d.cross(s)
	var ra := []
	for i in 3:
		var ang: float = TAU * i / 3.0
		ra.append(s * cos(ang) * r + t * sin(ang) * r)
	for i in 3:
		var j: int = (i + 1) % 3
		var o: Vector3 = ra[i] + ra[j]
		_tri(st, a + ra[i], a + ra[j], b + ra[j], col, o)
		_tri(st, a + ra[i], b + ra[j], b + ra[i], col, o)

## A flower head: `n` petals round a centre, each one triangle, cupped up by `cup`. n+... triangles.
func _head(st: SurfaceTool, c: Vector3, n: int, r: float, cup: float, petal: Color, eye: Color) -> void:
	var ph: float = _rng.randf() * TAU
	for i in n:
		var a0: float = ph + TAU * (i - 0.32) / n
		var a1: float = ph + TAU * (i + 0.32) / n
		var am: float = ph + TAU * i / n
		var p0: Vector3 = c + Vector3(cos(a0), 0, sin(a0)) * r * 0.45 + Vector3(0, cup * 0.3, 0)
		var p1: Vector3 = c + Vector3(cos(a1), 0, sin(a1)) * r * 0.45 + Vector3(0, cup * 0.3, 0)
		var tip: Vector3 = c + Vector3(cos(am), 0, sin(am)) * r + Vector3(0, cup, 0)
		_tri(st, p0, p1, tip, petal, Vector3.UP)
	var e: Array = _ring(c + Vector3(0, cup * 0.35, 0), 5, r * 0.32, ph)
	var top: Vector3 = c + Vector3(0, cup * 0.35 + r * 0.12, 0)
	for i in 5:
		_tri(st, e[i], e[(i + 1) % 5], top, eye, Vector3.UP)

## A leaf: a flat diamond from `a` along `dir`. 2 triangles.
func _leaf(st: SurfaceTool, a: Vector3, dir: Vector3, w: float, col: Color) -> void:
	var side: Vector3 = dir.cross(Vector3.UP).normalized() * w
	var m: Vector3 = a + dir * 0.5 + Vector3(0, 0.02, 0)
	_tri(st, a, m + side, a + dir, col, Vector3.UP)
	_tri(st, a, a + dir, m - side, col, Vector3.UP)

# ── meadow ──────────────────────────────────────────────────────────────────
func _daisies(st: SurfaceTool) -> void:
	for i in 3:
		var foot := Vector3(_rng.randf_range(-0.12, 0.12), 0, _rng.randf_range(-0.12, 0.12))
		var h: float = _rng.randf_range(0.22, 0.34)
		var top: Vector3 = foot + Vector3(_rng.randf_range(-0.04, 0.04), h, _rng.randf_range(-0.04, 0.04))
		_stem(st, foot, top, 0.008, Color(0.30, 0.52, 0.22))
		_head(st, top, 7, 0.07, 0.015, Color(0.97, 0.96, 0.92), Color(0.95, 0.75, 0.15))
	_leaf(st, Vector3.ZERO, Vector3(0.14, 0.02, 0.05), 0.03, Color(0.32, 0.55, 0.24))

func _tulips(st: SurfaceTool) -> void:
	var cols := [Color(0.88, 0.22, 0.22), Color(0.95, 0.62, 0.15)]
	for i in 2:
		var foot := Vector3(-0.07 + 0.14 * i, 0, _rng.randf_range(-0.05, 0.05))
		var top: Vector3 = foot + Vector3(_rng.randf_range(-0.03, 0.03), _rng.randf_range(0.28, 0.36), 0)
		_stem(st, foot, top, 0.009, Color(0.30, 0.52, 0.22))
		# a cup: 5 petals standing up round the top, each two triangles
		var r: float = 0.045
		var ph: float = _rng.randf() * TAU
		for k in 5:
			var a0: float = ph + TAU * k / 5.0
			var a1: float = ph + TAU * (k + 1) / 5.0
			var b0: Vector3 = top + Vector3(cos(a0), 0, sin(a0)) * r * 0.5
			var b1: Vector3 = top + Vector3(cos(a1), 0, sin(a1)) * r * 0.5
			var t0: Vector3 = top + Vector3(cos(a0), 0, sin(a0)) * r + Vector3(0, 0.08, 0)
			var tm: Vector3 = top + Vector3(cos((a0 + a1) * 0.5), 0, sin((a0 + a1) * 0.5)) * r * 1.1 + Vector3(0, 0.1, 0)
			var o: Vector3 = (b0 + b1) * 0.5 - top
			_tri(st, b0, b1, tm, cols[i], o)
			_tri(st, b0, tm, t0, cols[i], o)
		_leaf(st, foot, Vector3(0.0, 0.12, 0.08 if i == 0 else -0.08), 0.03, Color(0.34, 0.58, 0.26))

func _mushrooms(st: SurfaceTool) -> void:
	for i in 2:
		var c := Vector3(-0.06 + 0.13 * i, 0, 0.03 * i)
		var h: float = 0.12 if i == 0 else 0.08
		var r: float = 0.07 if i == 0 else 0.05
		_stem(st, c, c + Vector3(0, h, 0), r * 0.25, Color(0.92, 0.88, 0.78))
		# the cap: a low cone over a skirt, red with a pale rim
		var rim: Array = _ring(c + Vector3(0, h - 0.01, 0), 7, r)
		var tip: Vector3 = c + Vector3(0, h + r * 0.75, 0)
		for k in 7:
			_tri(st, rim[k], rim[(k + 1) % 7], tip, Color(0.80, 0.18, 0.14), Vector3.UP)
			_tri(st, rim[k], rim[(k + 1) % 7], c + Vector3(0, h - 0.005, 0), Color(0.88, 0.82, 0.70), Vector3.DOWN)

func _clover(st: SurfaceTool) -> void:
	for i in 4:
		var a: float = TAU * i / 4.0 + _rng.randf_range(-0.3, 0.3)
		var c := Vector3(cos(a), 0, sin(a)) * 0.08
		var top: Vector3 = c + Vector3(0, _rng.randf_range(0.06, 0.1), 0)
		_stem(st, c, top, 0.006, Color(0.28, 0.48, 0.2))
		for k in 3:
			var la: float = TAU * k / 3.0 + a
			_leaf(st, top, Vector3(cos(la), 0.0, sin(la)) * 0.06, 0.03, Color(0.30, 0.60, 0.28))
	_head(st, Vector3(0, 0.14, 0), 6, 0.035, 0.02, Color(0.92, 0.70, 0.85), Color(0.85, 0.55, 0.75))

# ── desert ──────────────────────────────────────────────────────────────────
func _cactus(st: SurfaceTool) -> void:
	var g := Color(0.33, 0.55, 0.32)
	_lump(st, Vector3.ZERO, 6, 0.07, 0.5, 0.85, g, Color(0.40, 0.62, 0.36), 0.0)
	_stem(st, Vector3(0, 0.22, 0), Vector3(0.12, 0.24, 0), 0.03, g)
	_lump(st, Vector3(0.12, 0.22, 0), 5, 0.035, 0.16, 0.8, g, Color(0.95, 0.60, 0.75), 0.0)

func _dry_bush(st: SurfaceTool) -> void:
	var c := Color(0.55, 0.42, 0.28)
	for i in 6:
		var a: float = TAU * i / 6.0 + _rng.randf_range(-0.3, 0.3)
		var mid := Vector3(cos(a) * 0.08, 0.12, sin(a) * 0.08)
		var tip := Vector3(cos(a) * 0.2, _rng.randf_range(0.2, 0.3), sin(a) * 0.2)
		_stem(st, Vector3(0, 0, 0), mid, 0.008, c)
		_tri(st, mid, tip + Vector3(0.02, 0, 0), tip - Vector3(0.02, 0, 0), c, Vector3.UP)

func _bleached_rock(st: SurfaceTool) -> void:
	_lump(st, Vector3.ZERO, 7, 0.22, 0.18, 0.6, Color(0.82, 0.76, 0.64), Color(0.92, 0.88, 0.78))
	_lump(st, Vector3(0.2, 0, 0.1), 6, 0.1, 0.1, 0.5, Color(0.74, 0.66, 0.52))

func _pebbles(st: SurfaceTool, col: Color) -> void:
	var at := [Vector3(0, 0, 0), Vector3(0.16, 0, 0.06), Vector3(-0.1, 0, 0.13), Vector3(0.06, 0, -0.14)]
	for i in at.size():
		var r: float = [0.09, 0.06, 0.05, 0.045][i]
		var k: float = _rng.randf_range(0.85, 1.1)
		_lump(st, at[i], 5, r, r * 0.9, 0.55, Color(col.r * k, col.g * k, col.b * k))

# ── canyon ──────────────────────────────────────────────────────────────────
func _cairn(st: SurfaceTool) -> void:
	var y := 0.0
	for i in 3:
		var r: float = 0.14 - i * 0.035
		var k: float = 0.9 + 0.08 * i
		_lump(st, Vector3(_rng.randf_range(-0.02, 0.02), y, 0), 5, r, r * 0.7, 0.75, Color(0.66 * k, 0.40 * k, 0.28 * k))
		y += r * 0.6

func _thorn(st: SurfaceTool) -> void:
	var c := Color(0.42, 0.36, 0.22)
	for i in 5:
		var a: float = TAU * i / 5.0 + _rng.randf_range(-0.2, 0.2)
		var tip := Vector3(cos(a) * 0.18, _rng.randf_range(0.18, 0.32), sin(a) * 0.18)
		_stem(st, Vector3.ZERO, tip, 0.01, c)
	_head(st, Vector3(0, 0.22, 0), 5, 0.05, 0.01, Color(0.95, 0.85, 0.35), Color(0.75, 0.45, 0.2))

func _shard_rock(st: SurfaceTool) -> void:
	_lump(st, Vector3.ZERO, 5, 0.12, 0.42, 0.35, Color(0.62, 0.34, 0.22), Color(0.72, 0.46, 0.32), 0.25)
	_lump(st, Vector3(0.14, 0, 0.06), 4, 0.07, 0.2, 0.3, Color(0.56, 0.30, 0.20))

# ── mountain ────────────────────────────────────────────────────────────────
func _snow_rock(st: SurfaceTool) -> void:
	_lump(st, Vector3.ZERO, 7, 0.24, 0.24, 0.55, Color(0.46, 0.46, 0.50), Color(0.94, 0.96, 1.0))
	_lump(st, Vector3(-0.2, 0, 0.12), 5, 0.1, 0.1, 0.5, Color(0.42, 0.42, 0.46), Color(0.92, 0.94, 1.0))

func _edelweiss(st: SurfaceTool) -> void:
	for i in 2:
		var foot := Vector3(-0.05 + 0.1 * i, 0, 0)
		var top: Vector3 = foot + Vector3(0, 0.12 + 0.05 * i, 0)
		_stem(st, foot, top, 0.007, Color(0.50, 0.58, 0.48))
		_head(st, top, 8, 0.055, 0.008, Color(0.90, 0.93, 0.88), Color(0.85, 0.80, 0.45))
	_leaf(st, Vector3.ZERO, Vector3(-0.1, 0.01, 0.06), 0.025, Color(0.58, 0.64, 0.56))

func _ice_shard(st: SurfaceTool) -> void:
	_lump(st, Vector3.ZERO, 5, 0.06, 0.4, 0.3, Color(0.66, 0.84, 0.95), Color(0.88, 0.96, 1.0), 0.1)
	_lump(st, Vector3(0.08, 0, 0.04), 4, 0.04, 0.24, 0.3, Color(0.60, 0.80, 0.92), Color(0.86, 0.95, 1.0), 0.1)
	_lump(st, Vector3(-0.06, 0, 0.05), 4, 0.035, 0.18, 0.3, Color(0.62, 0.82, 0.94), Color(0.86, 0.95, 1.0), 0.1)

func _moss_stone(st: SurfaceTool) -> void:
	_lump(st, Vector3.ZERO, 7, 0.2, 0.16, 0.6, Color(0.44, 0.44, 0.47), Color(0.36, 0.52, 0.30))
	_pebbles_small(st)

func _pebbles_small(st: SurfaceTool) -> void:
	_lump(st, Vector3(0.2, 0, -0.06), 4, 0.05, 0.045, 0.5, Color(0.48, 0.48, 0.52))

# ── salt flat ───────────────────────────────────────────────────────────────
func _salt_cubes(st: SurfaceTool) -> void:
	for i in 3:
		var c := Vector3(_rng.randf_range(-0.12, 0.12), 0, _rng.randf_range(-0.12, 0.12))
		var s: float = _rng.randf_range(0.04, 0.08)
		_cube(st, c + Vector3(0, s * 0.6, 0), s, Basis.from_euler(Vector3(_rng.randf_range(-0.5, 0.5), _rng.randf() * TAU, _rng.randf_range(-0.5, 0.5))))

func _cube(st: SurfaceTool, c: Vector3, s: float, b: Basis) -> void:
	var col := Color(0.96, 0.95, 0.93)
	for ax in 3:
		for sg in [-1.0, 1.0]:
			var n: Vector3 = b[ax] * sg
			var u: Vector3 = b[(ax + 1) % 3] * s
			var v: Vector3 = b[(ax + 2) % 3] * s
			var f: Vector3 = c + n * s
			if n.y < -0.3:
				continue                  # the face in the ground is never seen
			_tri(st, f - u - v, f + u - v, f + u + v, col, n)
			_tri(st, f - u - v, f + u + v, f - u + v, col, n)

func _salt_crust(st: SurfaceTool) -> void:
	# a cracked plate lifted at its edges: a fan of slabs, each tipped up toward the rim
	var n := 7
	var c := Vector3(0, 0.01, 0)
	for i in n:
		var a0: float = TAU * i / n
		var a1: float = TAU * (i + 1) / n
		var r0: float = _rng.randf_range(0.22, 0.3)
		var gap: float = 0.03
		var p0: Vector3 = c + Vector3(cos(a0 + gap), 0, sin(a0 + gap)) * r0 + Vector3(0, 0.05, 0)
		var p1: Vector3 = c + Vector3(cos(a1 - gap), 0, sin(a1 - gap)) * r0 + Vector3(0, 0.07, 0)
		var m: Vector3 = c + Vector3(cos((a0 + a1) * 0.5), 0, sin((a0 + a1) * 0.5)) * 0.05
		_tri(st, m, p0, p1, Color(0.95, 0.94, 0.90), Vector3.UP)
		# its broken edge, so the lift reads
		_tri(st, p0, p1, Vector3(p1.x, 0.0, p1.z), Color(0.80, 0.78, 0.74), (p0 + p1) * Vector3(1, 0, 1))
		_tri(st, p0, Vector3(p1.x, 0.0, p1.z), Vector3(p0.x, 0.0, p0.z), Color(0.80, 0.78, 0.74), (p0 + p1) * Vector3(1, 0, 1))
