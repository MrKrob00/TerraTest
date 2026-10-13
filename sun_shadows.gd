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
## so a 128 m window loses no distance against them. What it cannot do: nothing shades a machine (its
## blocks were never lit by the engine's shadow - they are unshaded, `block_lit.gdshader`).

const VP_SIZE := 512
const WINDOW := 128.0                # m across; ~25 cm a texel, softened by the linear filter
const MIN_SUN_Y := 0.28              # a low sun casts at most ~3.4x a caster's height
const MACHINE_REACH := 24.0          # a machine's blocks can stand this far from its origin
const TRUNK_R := 0.35                # m, of a tree's trunk at scale 1
const CROWN_SIDES := 10
const TYRE_SIDES := 10
const TERR_N := 32                   # terrain shade cells across the window (4 m each)
const TERR_STEP := 4.0               # m between fetched heights and march steps
const TERR_MARCH := 160.0            # m a ray walks toward the sun
const TERR_LIFT := 0.6               # m the ray starts over its cell, past the cell's own slope
const TERR_MOVE := 16.0
const TERR_TURN := 0.02              # of the light direction (~1.1 deg)
const TERR_FETCH_PER_FRAME := 200

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
	_canvas.draw.connect(_draw_casters)
	_apply_active()

func _apply_active() -> void:
	if _vp == null:
		return
	_terr_center = Vector2(INF, INF)     # a fresh start computes the ground's shade again
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
	_center = Vector2(cam.global_position.x, cam.global_position.z)
	var d: Vector3 = -light.global_basis.z
	if d.y > -MIN_SUN_Y:
		d = Vector3(d.x, 0.0, d.z).normalized() * sqrt(1.0 - MIN_SUN_Y * MIN_SUN_Y) + Vector3(0, -MIN_SUN_Y, 0)
	_dir = d
	# a shadow keeps what the engine's kept (`shadow_opacity`) and goes with the light
	var strength: float = light.shadow_opacity * clampf(light.light_energy, 0.0, 1.0)
	_canvas.queue_redraw()
	map.set_sun_shadow(_vp.get_texture(), _center, WINDOW, strength)
	_terrain_tick(map)
	Perf.mark("sun_shadows", _pf)

## A world point dropped along the light onto the plane y = g, in the map's pixels.
func _px(p: Vector3, g: float) -> Vector2:
	var t: float = (g - p.y) / _dir.y
	var q: Vector3 = p + _dir * t
	return Vector2(q.x - _center.x + WINDOW * 0.5, q.z - _center.y + WINDOW * 0.5) * (float(VP_SIZE) / WINDOW)

func _draw_casters() -> void:
	var half: float = WINDOW * 0.5
	var col := Color(1, 1, 1, 1)
	# THE GROUND'S SHADE GOES INTO THE SAME MAP, under the casters: one fetch a ground pixel, not two.
	# Its window was centred where the camera stood when it was marched, so it is laid that far off.
	if _terr_tex != null and _terr_center.x != INF:
		var ppm: float = float(VP_SIZE) / WINDOW
		var off: Vector2 = (_terr_center - _center) * ppm
		_canvas.draw_texture_rect(_terr_tex, Rect2(off, Vector2(VP_SIZE, VP_SIZE)), false)
	# machines, block by block
	for m in get_tree().get_nodes_in_group(MachineBody.MACHINES):
		var mn := m as Node3D
		if mn == null or not mn.is_inside_tree() or not mn.is_visible_in_tree():
			continue
		var mp: Vector3 = mn.global_position
		if absf(mp.x - _center.x) > half + MACHINE_REACH or absf(mp.z - _center.y) > half + MACHINE_REACH:
			continue
		var g: float = G.ground_y(mp, mp.y - 1.0)
		var mxf: Transform3D = mn.global_transform
		for c in mn.get_children():
			if not (c is CollisionShape3D) or not c.has_meta(&"block_owner"):
				continue
			var cs := c as CollisionShape3D
			if cs.disabled or cs.shape == null:
				continue
			var bb: AABB = _box(cs.shape)
			var xf: Transform3D = mxf * cs.transform
			var pts := PackedVector2Array()
			pts.resize(8)
			for k in 8:
				pts[k] = _px(xf * (bb.position + bb.size * Vector3(k & 1, (k >> 1) & 1, (k >> 2) & 1)), g)
			var hull := Geometry2D.convex_hull(pts)
			if hull.size() >= 3:
				_canvas.draw_colored_polygon(hull, col)
		var wl = mn.get("Wheels")
		if wl is Array:
			for w in wl:
				_draw_tyre(w, g, col)
	# trees: a trunk and a crown
	var rn := get_node_or_null("/root/Main/map/Resource_Nodes")
	if rn != null and rn.has_method("tree_shadow_casters"):
		for t in rn.tree_shadow_casters(_center, half + 20.0):
			var foot: Vector3 = t[0]
			var ch: float = t[1]
			var cr: float = t[2]
			var g2: float = foot.y
			var top: Vector3 = foot + Vector3.UP * ch
			var tr_r: float = TRUNK_R * cr / 2.5
			var a := _px(foot, g2)
			var b := _px(top, g2)
			var side := (b - a).orthogonal().normalized() * tr_r * (float(VP_SIZE) / WINDOW)
			_canvas.draw_colored_polygon(PackedVector2Array([a - side, a + side, b + side, b - side]), col)
			# the crown is a ball: its shadow is the ball's outline projected, an ellipse round b
			var ring := PackedVector2Array()
			ring.resize(CROWN_SIDES * 2)
			for k in CROWN_SIDES:
				var ang: float = TAU * float(k) / float(CROWN_SIDES)
				var off := Vector3(cos(ang), 0.0, sin(ang)) * cr
				ring[k * 2] = _px(top + off + Vector3.UP * cr * 0.6, g2)
				ring[k * 2 + 1] = _px(top + off - Vector3.UP * cr * 0.6, g2)
			var hull2 := Geometry2D.convex_hull(ring)
			if hull2.size() >= 3:
				_canvas.draw_colored_polygon(hull2, col)

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
	var ring := PackedVector2Array()
	ring.resize(TYRE_SIDES)
	for k in TYRE_SIDES:
		var a: float = TAU * float(k) / float(TYRE_SIDES)
		ring[k] = _px(c + (u * cos(a) + v * sin(a)) * rad, g)
	var hull := Geometry2D.convex_hull(ring)
	if hull.size() >= 3:
		_canvas.draw_colored_polygon(hull, col)

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
	_t_center = _center
	_t_dir = _dir
	var flat := Vector2(-_dir.x, -_dir.z)            # toward the sun, on the plan
	var reach: Vector2 = flat.normalized() * TERR_MARCH if flat.length_squared() > 1e-6 else Vector2.ZERO
	var half: float = WINDOW * 0.5
	var lo := Vector2(_center.x - half + minf(reach.x, 0.0), _center.y - half + minf(reach.y, 0.0))
	var hi := Vector2(_center.x + half + maxf(reach.x, 0.0), _center.y + half + maxf(reach.y, 0.0))
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
