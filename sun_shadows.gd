extends Node
## FAST SUN SHADOWS (the player's call, after the phone's probe: with the engine's shadows the ground
## cost 34 ms of a 53 ms frame, 23 of them the lit pass and its shadow lookup). The ground draws
## unshaded (`ChunkTerrain.fast_ground`) and reads one texel of THIS map for its shadow: a top-down
## window `WINDOW` across round the camera, `VP_SIZE` px, where every caster is drawn as its own
## silhouette PROJECTED ALONG THE SUN onto the ground under it - a machine block by block (the
## machine's copy of each block's collider, so a drill or a turret casts its hull, not its cell), a
## tree as its crown and its trunk, a wheel as its tyre's disc. It is 2D polygons on a SubViewport,
## the same road the grass trample takes (`grass.gd`): no 3D pass, no light pass, no depth map.
## THE GROUND SHADES ITSELF TOO, from a coarse map (`TERR_N` cells over the same window) drawn into
## the casters' map under them, so the ground still reads one texel: each
## cell marches toward the sun over the DRAWN heights (`ChunkTerrain.drawn_height`) and is dark when a
## ridge stands over the ray. The heights are fetched a slice a frame (`TERR_FETCH_PER_FRAME`) and the
## march runs on a worker thread over the packed grid; a refresh starts when the camera has moved
## `TERR_MOVE` or the light has turned `TERR_TURN` - the sun crosses the sky in `day_length`, so a
## few seconds late is nothing. The engine's shadows reached `directional_shadow_max_distance` (80 m),
## so the window reaches past them. NOTHING SWIMS: the window's centre moves in whole texels and the
## ground's shade in whole cells over a fixed height grid, so a still shadow lands on the same texels
## frame after frame - a centre following the camera to the millimetre slid every edge under the
## linear filter and the shadows shimmered while driving (the player's report). WHAT STANDS STILL IS
## DRAWN ONCE (trees, ore veins): their polygons are built round a reference centre every
## `STATIC_EVERY` or when the window or the light has moved, and laid off by whole pixels each frame. What it cannot do: nothing shades a machine (its
## blocks were never lit by the engine's shadow - they are unshaded, `block_lit.gdshader`).

const VP_SIZE := 768
const WINDOW := 192.0                # m across; 25 cm a texel, softened by the linear filter
const MIN_SUN_Y := 0.28              # a low sun casts at most ~3.4x a caster's height
const MACHINE_REACH := 24.0          # a machine's blocks can stand this far from its origin
const TRUNK_R := 0.35                # m, of a tree's trunk at scale 1
const CROWN_SIDES := 10
const TYRE_SIDES := 10
const TERR_N := 48                   # terrain shade cells across the window (4 m each)
const TERR_STEP := 4.0               # m between fetched heights and march steps
const TERR_MARCH := 160.0            # m a ray walks toward the sun
const TERR_LIFT := 0.6               # m the ray starts over its cell, past the cell's own slope
const TERR_MOVE := 16.0
const TERR_TURN := 0.02              # of the light direction (~1.1 deg)
const TERR_FETCH_PER_FRAME := 250
const STATIC_EVERY := 1.0            # s between rebuilds of the trees' and veins' polygons
const STATIC_MOVE := 16.0            # m the window may move before they are rebuilt

var active := false:
	set(v):
		if v == active:
			return
		active = v
		_apply_active()

var _vp: SubViewport = null
var _canvas: Node2D = null
var _center := Vector2.ZERO
var _dir := Vector3(0, -1, 0)        # where the light TRAVELS
var _box_of: Dictionary = {}         # Shape3D -> AABB in its own axes
var _tyre_mesh: Dictionary = {}      # wheel instance id -> its tyre's MeshInstance3D
var _org := Vector2.ZERO             # the centre `_px` lays pixels off from
var _st_polys: Array = []            # still casters' polygons, in pixels round `_st_ref`
var _st_ref := Vector2(INF, INF)
var _st_dir := Vector3.ZERO
var _st_t := 0.0

# terrain shade: state of the refresh in flight
var _terr_tex: ImageTexture = null
var _terr_center := Vector2(INF, INF) # the window the shown texture covers
var _terr_dir := Vector3.ZERO
var _t_phase := 0                    # 0 idle, 1 fetching, 2 marching on the thread
var _t_org := Vector2.ZERO           # world XZ of height cell (0, 0)
var _t_w := 0
var _t_h := 0
var _t_heights := PackedFloat32Array()
var _t_i := 0
var _t_center := Vector2.ZERO
var _t_dir := Vector3.ZERO
var _t_task := -1
var _t_out := PackedByteArray()

func _ready() -> void:
	_vp = SubViewport.new()
	_vp.size = Vector2i(VP_SIZE, VP_SIZE)
	_vp.transparent_bg = true
	_vp.disable_3d = true
	_vp.render_target_clear_mode = SubViewport.CLEAR_MODE_ALWAYS
	add_child(_vp)
	_canvas = Node2D.new()
	_canvas.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	_vp.add_child(_canvas)
	_canvas.draw.connect(_draw_timed)
	_apply_active()

func _apply_active() -> void:
	if _vp == null:
		return
	_terr_center = Vector2(INF, INF)     # a fresh start computes the ground's shade again
	_st_ref = Vector2(INF, INF)
	_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS if active else SubViewport.UPDATE_DISABLED
	set_process(active)
	var map := _map()
	if map != null and map.has_method("set_sun_shadow"):
		map.set_sun_shadow(_vp.get_texture() if active else null, _center, WINDOW, 0.0)

func _map() -> Node:
	return get_node_or_null("/root/Main/map")

func _light() -> DirectionalLight3D:
	return get_node_or_null("/root/Main/DirectionalLight3D2") as DirectionalLight3D

func _process(_delta: float) -> void:
	var _pf := Perf.now()
	var cam := get_viewport().get_camera_3d()
	var light := _light()
	var map := _map()
	if cam == null or light == null or map == null:
		return
	var texel: float = WINDOW / float(VP_SIZE)
	_center = (Vector2(cam.global_position.x, cam.global_position.z) / texel).floor() * texel
	var d: Vector3 = -light.global_basis.z
	if d.y > -MIN_SUN_Y:
		d = Vector3(d.x, 0.0, d.z).normalized() * sqrt(1.0 - MIN_SUN_Y * MIN_SUN_Y) + Vector3(0, -MIN_SUN_Y, 0)
	_dir = d
	# a shadow keeps what the engine's kept (`shadow_opacity`) and goes with the light
	var strength: float = light.shadow_opacity * clampf(light.light_energy, 0.0, 1.0)
	_st_t -= _delta
	if _st_ref.x == INF or _st_t <= 0.0 or _st_ref.distance_squared_to(_center) > STATIC_MOVE * STATIC_MOVE \
			or _st_dir.distance_squared_to(_dir) > TERR_TURN * TERR_TURN:
		_build_static()
	_canvas.queue_redraw()
	map.set_sun_shadow(_vp.get_texture(), _center, WINDOW, strength)
	_terrain_tick(map)
	Perf.mark("sun_shadows", _pf)

## A world point dropped along the light onto the plane y = g, in the map's pixels.
## A point under the plane stays where it is (it would be thrown away from the light).
func _px(p: Vector3, g: float) -> Vector2:
	var t: float = maxf((g - p.y) / _dir.y, 0.0)
	var q: Vector3 = p + _dir * t
	return Vector2(q.x - _org.x + WINDOW * 0.5, q.z - _org.y + WINDOW * 0.5) * (float(VP_SIZE) / WINDOW)

## A world VECTOR through the same projection (no position, no clamp), in pixels.
func _pv(v: Vector3) -> Vector2:
	return Vector2(v.x - _dir.x / _dir.y * v.y, v.z - _dir.z / _dir.y * v.y) * (float(VP_SIZE) / WINDOW)

## THE SHADOW OF A BOX IS A HEXAGON OF ITS THREE HALF EDGES (the projection is affine, so a box goes
## to a zonotope): no eight corners and no hull. Eight `_px` and a `convex_hull` a block were 4-6 ms a
## frame for four machines on the optimize=none build. Generators turned into the upper half plane
## and sorted by angle walk the outline counter-clockwise from its lowest corner.
func _box_shadow(xf: Transform3D, bb: AABB, g: float) -> PackedVector2Array:
	var hb: Vector3 = bb.size * 0.5
	var c: Vector2 = _px(xf * bb.get_center(), g)
	var gs: Array[Vector2] = []
	for u3 in [xf.basis.x * hb.x, xf.basis.y * hb.y, xf.basis.z * hb.z]:
		var u: Vector2 = _pv(u3)
		if u.length_squared() < 0.0025:
			continue
		if u.y < 0.0 or (u.y == 0.0 and u.x < 0.0):
			u = -u
		var k := gs.size()
		while k > 0 and gs[k - 1].angle() > u.angle():
			k -= 1
		gs.insert(k, u)
	var out := PackedVector2Array()
	if gs.size() < 2:
		return out
	var v: Vector2 = c
	for u in gs:
		v -= u
	out.append(v)
	for u in gs:
		v += u * 2.0
		out.append(v)
	for i in gs.size() - 1:
		v -= gs[i] * 2.0
		out.append(v)
	return out

## `convex_hull` closes the ring by repeating its first point; a thin hull with that seam fails the
## canvas's triangulation (the engine prints it every frame), so the ring goes in open.
func _open(h: PackedVector2Array) -> PackedVector2Array:
	if h.size() > 1 and h[0] == h[h.size() - 1]:
		h.resize(h.size() - 1)
	return h

## Trees and ore veins: polygons round `_st_ref`, drawn laid off by whole pixels until the next build.
func _build_static() -> void:
	_st_ref = _center
	_st_dir = _dir
	_st_t = STATIC_EVERY
	_org = _st_ref
	_st_polys.clear()
	var reach: float = WINDOW * 0.5 + STATIC_MOVE + 20.0
	var rn := get_node_or_null("/root/Main/map/Resource_Nodes")
	if rn == null:
		return
	if rn.has_method("tree_shadow_casters"):
		for t in rn.tree_shadow_casters(_st_ref, reach):
			var foot: Vector3 = t[0]
			var ch: float = t[1]
			var cr: float = t[2]
			var g2: float = foot.y
			var top: Vector3 = foot + Vector3.UP * ch
			var tr_r: float = TRUNK_R * cr / 2.5
			var a := _px(foot, g2)
			var b := _px(top, g2)
			if a.distance_squared_to(b) > 1.0:
				var side := (b - a).orthogonal().normalized() * tr_r * (float(VP_SIZE) / WINDOW)
				_st_polys.append(PackedVector2Array([a - side, a + side, b + side, b - side]))
			# the crown is a ball: its shadow is the ball's outline projected, an ellipse round b
			var ring := PackedVector2Array()
			ring.resize(CROWN_SIDES * 2)
			for k in CROWN_SIDES:
				var ang: float = TAU * float(k) / float(CROWN_SIDES)
				var off := Vector3(cos(ang), 0.0, sin(ang)) * cr
				ring[k * 2] = _px(top + off + Vector3.UP * cr * 0.6, g2)
				ring[k * 2 + 1] = _px(top + off - Vector3.UP * cr * 0.6, g2)
			var hull2 := _open(Geometry2D.convex_hull(ring))
			if hull2.size() >= 3:
				_st_polys.append(hull2)
	if rn.has_method("ore_shadow_casters"):
		for o in rn.ore_shadow_casters(_st_ref, reach):
			var xf: Transform3D = o[0]
			var pts: PackedVector3Array = o[1]
			if pts.size() < 3:
				continue
			var flat := PackedVector2Array()
			flat.resize(pts.size())
			for k in pts.size():
				flat[k] = _px(xf * pts[k], xf.origin.y)
			var hull := _open(Geometry2D.convex_hull(flat))
			if hull.size() >= 3:
				_st_polys.append(hull)

var draw_us := 0                     # what the last map took to draw (the probe reads it)
func _draw_timed() -> void:
	var t0 := Time.get_ticks_usec()
	_draw_casters()
	draw_us = Time.get_ticks_usec() - t0

func _draw_casters() -> void:
	var half: float = WINDOW * 0.5
	var col := Color(1, 1, 1, 1)
	# THE GROUND'S SHADE GOES INTO THE SAME MAP, under the casters: one fetch a ground pixel, not two.
	# Its window was centred where the camera stood when it was marched, so it is laid that far off.
	if _terr_tex != null and _terr_center.x != INF:
		var ppm: float = float(VP_SIZE) / WINDOW
		var off: Vector2 = (_terr_center - _center) * ppm
		_canvas.draw_texture_rect(_terr_tex, Rect2(off, Vector2(VP_SIZE, VP_SIZE)), false)
	_org = _center
	# trees and ore veins, built round `_st_ref`
	if not _st_polys.is_empty():
		_canvas.draw_set_transform((_st_ref - _center) * (float(VP_SIZE) / WINDOW))
		for poly in _st_polys:
			_canvas.draw_colored_polygon(poly, col)
		_canvas.draw_set_transform(Vector2.ZERO)
	# machines, block by block
	for m in get_tree().get_nodes_in_group(MachineBody.MACHINES):
		var mn := m as Node3D
		if mn == null or not mn.is_inside_tree() or not mn.is_visible_in_tree():
			continue
		var mp: Vector3 = mn.global_position
		if absf(mp.x - _center.x) > half + MACHINE_REACH or absf(mp.z - _center.y) > half + MACHINE_REACH:
			continue
		var g: float = G.ground_y(mp, mp.y - 1.0)
		var e: Array = _machine_mesh(mn)
		var mesh: ArrayMesh = e[2]
		if mesh != null:
			var verts: PackedVector3Array = (_proj(g) * mn.global_transform) * (e[1] as PackedVector3Array)
			RenderingServer.mesh_surface_update_vertex_region(mesh.get_rid(), 0, 0, verts.to_byte_array())
			_canvas.draw_mesh(mesh, null)
		var wl = mn.get("Wheels")
		if wl is Array:
			for w in wl:
				_draw_tyre(w, g, col)
	# loose blocks lying about: their own body's box, on the ground under each
	var objs := get_node_or_null("/root/Main/objects")
	if objs != null:
		for c in objs.get_children():
			var vb := c as VehicleBlock
			if vb == null or not vb.is_inside_tree():
				continue
			var bp: Vector3 = vb.global_position
			if absf(bp.x - _center.x) > half + 4.0 or absf(bp.z - _center.y) > half + 4.0:
				continue
			var cs := _block_shape(vb)
			if cs == null:
				continue
			var hull := _box_shadow(cs.global_transform, _box(cs.shape), G.ground_y(bp, bp.y - 1.0))
			if hull.size() >= 3:
				_canvas.draw_colored_polygon(hull, col)

## A MACHINE'S SHADOW IS ONE MESH OF ITS BLOCKS' BOXES, PROJECTED BY ONE NATIVE MULTIPLY. The light's
## projection onto a plane is affine, so it is a `Transform3D` (`_proj`), and the corners of every
## block's box (machine axes, eight a box, 12 triangles - the shadow of a solid is the union of its
## faces' shadows) go through `_proj * machine transform` in one `Transform3D * PackedVector3Array` and
## into the mesh's vertex buffer. Per block in GDScript (eight `_px` and a hull) it was 35-45 us a block
## a frame on the optimize=none build, every frame, since a machine in a fight never stops turning. The
## corners are gathered again when the machine's child count changes (a block on or off).
const BOX_TRIS := [0, 2, 6, 0, 6, 4, 1, 3, 7, 1, 7, 5, 0, 1, 5, 0, 5, 4, 2, 3, 7, 2, 7, 6,
		0, 1, 3, 0, 3, 2, 4, 5, 7, 4, 7, 6]
var _mmesh: Dictionary = {}          # machine id -> [child count, corners in machine axes, ArrayMesh]
func _machine_mesh(mn: Node3D) -> Array:
	var id := mn.get_instance_id()
	var e = _mmesh.get(id)
	var n := mn.get_child_count()
	if e is Array and int(e[0]) == n:
		return e
	var corners := PackedVector3Array()
	var idx := PackedInt32Array()
	for c in _block_shapes(mn):
		var cs := c as CollisionShape3D
		if not is_instance_valid(cs) or cs.disabled or cs.shape == null:
			continue
		var bb: AABB = _box(cs.shape)
		var base := corners.size()
		for k in 8:
			corners.append(cs.transform * (bb.position + bb.size * Vector3(k & 1, (k >> 1) & 1, (k >> 2) & 1)))
		for t in BOX_TRIS:
			idx.append(base + int(t))
	var mesh: ArrayMesh = null
	if not idx.is_empty():
		mesh = ArrayMesh.new()
		var arr := []
		arr.resize(Mesh.ARRAY_MAX)
		arr[Mesh.ARRAY_VERTEX] = corners
		arr[Mesh.ARRAY_INDEX] = idx
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr, [], {}, Mesh.ARRAY_FLAG_USE_DYNAMIC_UPDATE)
		mesh.custom_aabb = AABB(Vector3(-1e6, -1e6, -1.0), Vector3(2e6, 2e6, 2.0))   # moved every frame
	e = [n, corners, mesh]
	if _mmesh.size() > 128:
		_mmesh.clear()
	_mmesh[id] = e
	return e

## World point -> (pixel x, pixel y, 0) on the plane y = g: `_px` without the clamp, as a transform.
func _proj(g: float) -> Transform3D:
	var ppm: float = float(VP_SIZE) / WINDOW
	var kx: float = _dir.x / _dir.y
	var kz: float = _dir.z / _dir.y
	return Transform3D(Basis(Vector3(ppm, 0, 0), Vector3(-ppm * kx, -ppm * kz, 0), Vector3(0, ppm, 0)),
			Vector3(ppm * (kx * g - _org.x + WINDOW * 0.5), ppm * (kz * g - _org.y + WINDOW * 0.5), 0))

## A machine's tagged block colliders, walked again only when its child count changes: the walk over
## every child of every machine each frame was half the machines' share.
var _shapes_of: Dictionary = {}      # machine instance id -> [child count, Array of CollisionShape3D]
func _block_shapes(mn: Node) -> Array:
	var id := mn.get_instance_id()
	var e = _shapes_of.get(id)
	var n := mn.get_child_count()
	if e is Array and int(e[0]) == n:
		return e[1]
	var list: Array = []
	for c in mn.get_children():
		if c is CollisionShape3D and c.has_meta(&"block_owner"):
			list.append(c)
	if _shapes_of.size() > 128:
		_shapes_of.clear()
	_shapes_of[id] = [n, list]
	return list

var _shape_of: Dictionary = {}       # loose block instance id -> its CollisionShape3D
func _block_shape(vb: Node) -> CollisionShape3D:
	var id := vb.get_instance_id()
	var cs = _shape_of.get(id)
	if cs is CollisionShape3D and is_instance_valid(cs) and cs.get_parent() == vb:
		return cs if not cs.disabled and cs.shape != null else null
	cs = null
	for ch in vb.get_children():
		if ch is CollisionShape3D:
			cs = ch
			break
	if _shape_of.size() > 512:
		_shape_of.clear()
	_shape_of[id] = cs
	return cs if cs != null and not cs.disabled and cs.shape != null else null

## A wheel's tyre has no collider (the probe carries the machine), so it is drawn as its disc: the
## ring round the tyre mesh's middle across its own axle (`_tyre`'s X, the axle `wheel.gd` rolls about).
func _draw_tyre(w, g: float, col: Color) -> void:
	if not is_instance_valid(w) or not (w is Node3D):
		return
	var tyre = w.get("_tyre")
	if not is_instance_valid(tyre):
		return
	var mi = _tyre_mesh.get(w.get_instance_id())
	if mi == null:
		mi = tyre if tyre is MeshInstance3D else null
		if mi == null:
			for c in (tyre as Node).find_children("*", "MeshInstance3D", true, false):
				mi = c
				break
		_tyre_mesh[w.get_instance_id()] = mi if mi != null else false
	if not (mi is MeshInstance3D) or (mi as MeshInstance3D).mesh == null:
		return
	var m := mi as MeshInstance3D
	var bb: AABB = m.get_aabb()
	var c: Vector3 = m.global_transform * bb.get_center()
	var axle: Vector3 = (tyre as Node3D).global_basis.x.normalized()
	var r = w.get("_radius")
	var rad: float = float(r) if r is float and float(r) > 0.05 else bb.size.y * 0.5
	var u: Vector3 = axle.cross(Vector3.UP)
	if u.length_squared() < 0.01:
		u = axle.cross(Vector3.FORWARD)
	u = u.normalized()
	var v: Vector3 = axle.cross(u).normalized()
	# a disc projects to an ellipse round its centre's shadow: convex as it is, no hull
	var pc: Vector2 = _px(c, g)
	var pu: Vector2 = _pv(u * rad)
	var pv: Vector2 = _pv(v * rad)
	if absf(pu.cross(pv)) < 0.5:
		return
	var ring := PackedVector2Array()
	ring.resize(TYRE_SIDES)
	for k in TYRE_SIDES:
		var a: float = TAU * float(k) / float(TYRE_SIDES)
		ring[k] = pc + pu * cos(a) + pv * sin(a)
	_canvas.draw_colored_polygon(ring, col)

# ── The ground's own shade ──────────────────────────────────────────────────
func _terrain_tick(map: Node) -> void:
	if not map.has_method("drawn_height"):
		return
	match _t_phase:
		0:
			var moved: bool = _terr_center.x == INF or _terr_center.distance_squared_to(_center) > TERR_MOVE * TERR_MOVE
			if moved or _terr_dir.distance_squared_to(_dir) > TERR_TURN * TERR_TURN:
				_terr_begin()
		1:
			var end: int = mini(_t_i + TERR_FETCH_PER_FRAME, _t_w * _t_h)
			for i in range(_t_i, end):
				var h = map.drawn_height(_t_org.x + float(i % _t_w) * TERR_STEP, _t_org.y + float(i / _t_w) * TERR_STEP)
				_t_heights[i] = h if not is_nan(h) else -1e6
			_t_i = end
			if _t_i >= _t_w * _t_h:
				_t_phase = 2
				_t_out = PackedByteArray()
				_t_out.resize(TERR_N * TERR_N)
				_t_task = WorkerThreadPool.add_task(_terr_march)
		2:
			if WorkerThreadPool.is_task_completed(_t_task):
				WorkerThreadPool.wait_for_task_completion(_t_task)
				_t_task = -1
				_t_phase = 0
				var img := Image.create_from_data(TERR_N, TERR_N, false, Image.FORMAT_L8, _t_out)
				if _terr_tex == null:
					_terr_tex = ImageTexture.create_from_image(img)
				else:
					_terr_tex.update(img)
				_terr_center = _t_center
				_terr_dir = _t_dir

func _terr_begin() -> void:
	# whole cells over a fixed height grid: a refresh lands on the same cells, not half a cell off
	var cell: float = WINDOW / float(TERR_N)
	_t_center = (_center / cell).round() * cell
	_t_dir = _dir
	var flat := Vector2(-_dir.x, -_dir.z)            # toward the sun, on the plan
	var reach: Vector2 = flat.normalized() * TERR_MARCH if flat.length_squared() > 1e-6 else Vector2.ZERO
	var half: float = WINDOW * 0.5
	var lo := Vector2(_t_center.x - half + minf(reach.x, 0.0), _t_center.y - half + minf(reach.y, 0.0))
	var hi := Vector2(_t_center.x + half + maxf(reach.x, 0.0), _t_center.y + half + maxf(reach.y, 0.0))
	lo = (lo / TERR_STEP).floor() * TERR_STEP
	_t_org = lo
	_t_w = int(ceil((hi.x - lo.x) / TERR_STEP)) + 1
	_t_h = int(ceil((hi.y - lo.y) / TERR_STEP)) + 1
	_t_heights.resize(_t_w * _t_h)
	_t_i = 0
	_t_phase = 1

## On a worker: packed arrays in, packed bytes out, nothing else touched.
func _terr_march() -> void:
	var cell: float = WINDOW / float(TERR_N)
	var flat := Vector2(-_t_dir.x, -_t_dir.z)
	var fl: float = flat.length()
	if fl < 1e-6:
		_t_out.fill(0)
		return
	var step := flat / fl * TERR_STEP
	var rise: float = -_t_dir.y / fl * TERR_STEP       # how much the ray climbs a step
	var steps: int = int(TERR_MARCH / TERR_STEP)
	var x0: float = _t_center.x - WINDOW * 0.5 + cell * 0.5
	var z0: float = _t_center.y - WINDOW * 0.5 + cell * 0.5
	for j in TERR_N:
		for i in TERR_N:
			var px: float = x0 + float(i) * cell
			var pz: float = z0 + float(j) * cell
			var y: float = _grid(px, pz) + TERR_LIFT
			var dark := 0
			for s in steps:
				px += step.x
				pz += step.y
				y += rise
				if _grid(px, pz) > y:
					dark = 255
					break
			_t_out[j * TERR_N + i] = dark

func _grid(x: float, z: float) -> float:
	var fx: float = (x - _t_org.x) / TERR_STEP
	var fz: float = (z - _t_org.y) / TERR_STEP
	var i: int = clampi(int(fx), 0, _t_w - 2)
	var k: int = clampi(int(fz), 0, _t_h - 2)
	var tx: float = clampf(fx - float(i), 0.0, 1.0)
	var tz: float = clampf(fz - float(k), 0.0, 1.0)
	var r0: int = k * _t_w + i
	var r1: int = r0 + _t_w
	return lerpf(lerpf(_t_heights[r0], _t_heights[r0 + 1], tx), lerpf(_t_heights[r1], _t_heights[r1 + 1], tx), tz)

func _exit_tree() -> void:
	if _t_task != -1:
		WorkerThreadPool.wait_for_task_completion(_t_task)
		_t_task = -1

func _box(sh: Shape3D) -> AABB:
	var bb = _box_of.get(sh)
	if bb != null:
		return bb
	var out := AABB(Vector3(-0.5, -0.5, -0.5), Vector3.ONE)
	if sh is BoxShape3D:
		var s: Vector3 = (sh as BoxShape3D).size
		out = AABB(-s * 0.5, s)
	elif sh is ConvexPolygonShape3D and (sh as ConvexPolygonShape3D).points.size() > 0:
		var p: PackedVector3Array = (sh as ConvexPolygonShape3D).points
		out = AABB(p[0], Vector3.ZERO)
		for q in p:
			out = out.expand(q)
	_box_of[sh] = out
	return out
