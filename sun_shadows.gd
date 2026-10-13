extends Node
## FAST SUN SHADOWS (the player's call, after the phone's probe: with the engine's shadows the ground
## cost 34 ms of a 53 ms frame, 23 of them the lit pass and its shadow lookup). The ground draws
## unshaded (`ChunkTerrain.fast_ground`) and reads one texel of THIS map for its shadow: a top-down
## window `WINDOW` across round the camera, `VP_SIZE` px, where every caster is drawn as its own
## silhouette PROJECTED ALONG THE SUN onto the ground under it - a machine block by block (the
## machine's copy of each block's collider, so a drill or a turret casts its hull, not its cell), a
## tree as its crown and its trunk. It is 2D polygons on a SubViewport, the same road the grass
## trample takes (`grass.gd`): no 3D pass, no light pass, no depth map. What it cannot do: a hill
## does not shade the ground behind it, and nothing shades a machine (the blocks were never lit by
## the engine's shadow anyway - they are unshaded, `block_lit.gdshader`).

const VP_SIZE := 512
const WINDOW := 128.0                # m across; ~25 cm a texel, softened by the linear filter
const MIN_SUN_Y := 0.28              # a low sun casts at most ~3.4x a caster's height
const MACHINE_REACH := 24.0          # a machine's blocks can stand this far from its origin
const TRUNK_R := 0.35                # m, of a tree's trunk at scale 1
const CROWN_SIDES := 10

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

func _ready() -> void:
	_vp = SubViewport.new()
	_vp.size = Vector2i(VP_SIZE, VP_SIZE)
	_vp.transparent_bg = true
	_vp.disable_3d = true
	_vp.render_target_clear_mode = SubViewport.CLEAR_MODE_ALWAYS
	add_child(_vp)
	_canvas = Node2D.new()
	_vp.add_child(_canvas)
	_canvas.draw.connect(_draw_casters)
	_apply_active()

func _apply_active() -> void:
	if _vp == null:
		return
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
	Perf.mark("sun_shadows", _pf)

## A world point dropped along the light onto the plane y = g, in the map's pixels.
func _px(p: Vector3, g: float) -> Vector2:
	var t: float = (g - p.y) / _dir.y
	var q: Vector3 = p + _dir * t
	return Vector2(q.x - _center.x + WINDOW * 0.5, q.z - _center.y + WINDOW * 0.5) * (float(VP_SIZE) / WINDOW)

func _draw_casters() -> void:
	var half: float = WINDOW * 0.5
	var col := Color(1, 1, 1, 1)
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
