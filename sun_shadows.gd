extends Node
## FAST SUN SHADOWS (the player's call, after the phone's probe: with the engine's shadows the ground
## cost 34 ms of a 53 ms frame, 23 of them the lit pass and its shadow lookup). The ground draws
## unshaded (`ChunkTerrain.fast_ground`) and reads ONE texel of these maps for its shadow: top-down
## windows round the camera where every caster is drawn as its own silhouette PROJECTED ALONG THE SUN
## onto the ground under it - a machine block by block (the machine's copy of each block's collider,
## so a drill or a turret casts its hull, not its cell), a tree as its crown and its trunk, a wheel as
## its tyre's disc. 2D polygons on SubViewports, the same road the grass trample takes (`grass.gd`):
## no 3D pass, no light pass, no depth map.
## THE GROUND SHADES ITSELF TOO, from a coarse map (`TERR_N` cells over a cascade's window) drawn into
## the casters' map under them, so the ground still reads one texel: each cell marches toward the sun
## over the heights the terrain holds (`ChunkTerrain.known_height`) and is dark when a ridge stands
## over the ray. The march runs on a worker thread over a packed grid of heights, and the grid is KEPT:
## a refresh after the light turned marches the heights it has (the light turns, the ground does not),
## one after a move fetches only the cells it has not got, the HOLES IN VIEW (cells the terrain had
## no height for, found by the worker as runs, asked again where they lie in the camera's field
## within the view distance - ground never looked at was never built and has none to give) and a
## rolling share (`TERR_REFRESH`: a far node's coarse heights give way to finer ones as it nears).
## THREE CASCADES, NEAR TO FAR AT 100 / 75 / 50 % OF THE PIXELS (the player's call: "longer shadows
## at no cost"): `CASCADES`, 25 cm, 67 cm and 2 m a texel. The ground picks one per pixel by its
## distance (`glsl.gdshader`, `v_shsel`, chosen per vertex) and still fetches once. Only the NEAR
## one follows the camera and carries the machines, and it is the only map drawn every frame
## (`_vp`, a 192 m composite), and only when something in it changed; each cascade's STILL LAYER
## (ground shade, trees, veins) is a map of its own, centred where the camera stood when it was built
## and drawn again only when the camera has gone `step` from that point, the light has turned
## `TERR_TURN`, a caster in its reach changed (`ResourceNodes.shadow_rev_in`, asked every
## `REV_EVERY`) or a new ground shade landed. The near composite takes its still layer as one textured
## quad laid off by whole pixels, where it used to record and triangulate every tree's polygons every
## frame, and the loose blocks as one mesh (`_draw_loose`). A far cascade is built only when the haze
## at its inner edge still lets the ground show (`haze`, from `Main._apply_view`): at the 200 m view
## they are off. Measured on the optimize=none build, everything this node costs a frame, old against
## new, the camera standing / at 5 m/s / at 20 m/s: 1.48 / 1.32 / 1.69 ms against 0.47 / 0.96 / 1.64.
## A caster's polygons are KEPT between builds (`Cas.memo`, by the caster's key, in pixels round a
## fixed origin): moving the window only lays them off again, and only the casters that came in,
## changed or left cost anything; a turned light makes all of them anew, a slice a frame (`BUILD_USEC`).
## NOTHING SWIMS: every window's centre moves in whole texels and the ground's shade in whole cells
## over a fixed height grid, so a still shadow lands on the same texels frame after frame - a centre
## following the camera to the millimetre slid every edge under the linear filter and the shadows
## shimmered while driving (the player's report). What it cannot do: nothing shades a machine (its
## blocks were never lit by the engine's shadow - they are unshaded, `block_lit.gdshader`), and past
## the near window machines cast nothing.

const VP_SIZE := 768                 # the near composite, every frame
const WINDOW := 192.0                # m across; 25 cm a texel, softened by the linear filter
const MIN_SUN_Y := 0.28              # a low sun casts at most ~3.4x a caster's height
const MACHINE_REACH := 24.0          # a machine's blocks can stand this far from its origin
const TRUNK_R := 0.35                # m, of a tree's trunk at scale 1
const CROWN_HALF := 0.6              # of the crown's radius, its half height: a crown is a short drum
const CROWN_ARC := 5                 # points on each half of a crown's shadow (a stadium)
const FAR_CROWN_ARC := 3
const TYRE_SIDES := 10
const CASTER_PAD := 44.0             # m past a window a caster can stand and still throw into it
## [window m, pixels, step m (how far the camera goes before the still layer is built again), march m
## (how far a ground cell looks for a ridge), detail (2 and 1 trunks, crowns and veins, 0 crowns only)]
const CASCADES := [
	[224.0, 896, 16.0, 160.0, 2],
	[448.0, 672, 32.0, 240.0, 1],
	[896.0, 448, 64.0, 400.0, 0],
]
const SH_BAND := 8.0                 # m inside a window's edge the next one takes over (glsl.gdshader)
const HAZE_SHOWN := 0.6              # a far cascade is built while its inner edge is under this share
                                     # of the haze's run (begin to end)
const TERR_N := 56                   # terrain shade cells across a cascade's window
const TERR_LIFT := 0.6               # m the ray starts over its cell, past the cell's own slope
const TERR_TURN := 0.02              # of the light direction (~1.1 deg)
const TERR_FETCH_PER_FRAME := 250
const TERR_REFRESH := 0.03           # of the rows fetched again on every refresh
const NO_GROUND := -1.0e6            # a fetched cell with nothing drawn: lower than any ridge
const UNFETCHED := -1.0e7
const REV_EVERY := 0.5               # s: a changed caster is redrawn at most this often
const BUILD_USEC := 1500             # a frame's share of building the still layers' polygons
const IDLE_TURN := 0.002             # a turn of the light (~0.1 deg) the near composite redraws for
const HOLE_TURN_COS := 0.9           # a camera turned ~25 deg asks for a refresh (the holes now in view),
const HOLE_BURSTS := 2               # twice, `HOLE_GAP` s apart: the ground there is still being built
const HOLE_GAP := 2.0
const HOLE_FIELD := 1.05             # rad, half the field a hole is asked again in (the screen's ~50 + a margin)

var active := false:
	set(v):
		if v == active:
			return
		active = v
		_apply_active()

## What the haze leaves of the ground: begin and end, m, and how far it is drawn (`Main._apply_view`).
var haze := Vector2(150.0, 750.0)
var view := 1400.0

class Cas extends RefCounted:
	var k := 0
	var win := 0.0
	var px := 0
	var step := 0.0
	var march := 0.0
	var detail := 0
	var cell := 0.0
	var ppm := 0.0
	var inner := 0.0                 # m from the camera where it takes over from the one before
	var on := false
	var vp: SubViewport = null
	var canvas: Node2D = null
	# what the map shows
	var ref := Vector2(INF, INF)     # centre of the map
	var polys: Array = []            # in pixels round `org`
	var org := Vector2.ZERO
	var redraw := false
	# the polygons kept between builds: key -> Array of polygons, cast by `memo_dir` round `memo_org`
	var memo: Dictionary = {}
	var memo_dir := Vector3(INF, INF, INF)
	var memo_org := Vector2.ZERO
	# the build asked last and the one in flight
	var goal_ref := Vector2(INF, INF)
	var goal_dir := Vector3(INF, INF, INF)
	var dirty := true
	var rev := 0                     # `ResourceNodes.shadow_rev_in` round the last build
	var b_i := -1                    # -1: none in flight
	var b_list: Array = []
	var b_ref := Vector2.ZERO
	var b_dir := Vector3.ZERO
	var b_org := Vector2.ZERO
	var b_reuse := false
	var b_polys: Array = []
	var b_memo: Dictionary = {}
	# the ground's shade
	var t_tex: ImageTexture = null
	var t_center := Vector2(INF, INF)
	var t_dirty := true
	var h := PackedFloat32Array()    # heights kept from the last refresh
	var h_org := Vector2(INF, INF)
	var h_n := 0
	var h_refresh := 0
	var h_hruns := PackedInt32Array() # the holes of `h` (no ground known), runs: start, count...
	var h_hrow := PackedInt32Array()  # where each row's runs begin in `h_hruns` (n + 1 entries)
	var h_fwd := Vector2.ZERO        # where the camera looked at the last refresh it asked for
	var bursts := 0                  # refreshes still to ask for after the camera turned
	var burst_t := 0.0

class TJob extends RefCounted:
	var cas: Cas = null
	var center := Vector2.ZERO
	var dir := Vector3.ZERO
	var cell := 0.0
	var win := 0.0
	var march := 0.0
	var org := Vector2.ZERO
	var n := 0
	var heights := PackedFloat32Array()
	var runs := PackedInt32Array()   # cells to fetch: start, count, start, count...
	var r := 0                       # the run being fetched
	var i := 0                       # cells of it fetched
	var out := PackedByteArray()
	var hruns := PackedInt32Array()  # holes found by the worker: runs, and each row's first one
	var hrow := PackedInt32Array()

var _vp: SubViewport = null          # the near composite
var _canvas: Node2D = null
var _cas: Array = []                 # of Cas, near to far
var _center := Vector2.ZERO
var _cam2 := Vector2.ZERO
var _fwd2 := Vector2(0, -1)          # where the camera looks, on the plan
var _dir := Vector3(0, -1, 0)        # where the light TRAVELS
var _org := Vector2.ZERO             # the centre `_px` lays pixels off from
var _box_of: Dictionary = {}         # Shape3D -> AABB in its own axes
var _tyre_mesh: Dictionary = {}      # wheel instance id -> its tyre's MeshInstance3D
var _rev_t := 0.0
var _job: TJob = null
var _t_phase := 0                    # 0 idle, 1 fetching, 2 marching on the thread
var _t_task := -1
var _t_next := 0                     # the cascade a refresh is offered to first (round robin)
var _sig := PackedFloat32Array()     # what the near composite was last drawn from
var _sig_center := Vector2(INF, INF)
var _sig_dir := Vector3.ZERO
var _comp_dirty := true
var _pushed: Array = []              # the uniforms last handed to the ground

func _ready() -> void:
	_vp = SubViewport.new()
	_vp.size = Vector2i(VP_SIZE, VP_SIZE)
	_vp.transparent_bg = true
	_vp.disable_3d = true
	_vp.render_target_clear_mode = SubViewport.CLEAR_MODE_ALWAYS
	_vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(_vp)
	_canvas = Node2D.new()
	_canvas.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	_vp.add_child(_canvas)
	_canvas.draw.connect(_draw_casters)
	var prev_reach := 0.0
	for k in CASCADES.size():
		var row: Array = CASCADES[k]
		var c := Cas.new()
		c.k = k
		c.win = row[0]
		c.px = row[1]
		c.step = row[2]
		c.march = row[3]
		c.detail = row[4]
		c.cell = c.win / float(TERR_N)
		c.ppm = float(c.px) / c.win
		c.inner = maxf(prev_reach - SH_BAND, 0.0)
		prev_reach = c.win * 0.5 - c.step
		c.vp = SubViewport.new()
		c.vp.size = Vector2i(c.px, c.px)
		c.vp.transparent_bg = true
		c.vp.disable_3d = true
		c.vp.render_target_clear_mode = SubViewport.CLEAR_MODE_ALWAYS
		c.vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
		# THE NEAR STILL LAYER IS A VIEWPORT INSIDE THE COMPOSITE'S: the engine draws a viewport's
		# children before it (`RendererViewport::_sort_active_viewports`), so a layer built this frame
		# is what the composite lays in this frame - never last frame's at this frame's offset.
		if k == 0:
			_vp.add_child(c.vp)
		else:
			add_child(c.vp)
		c.canvas = Node2D.new()
		c.canvas.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
		c.vp.add_child(c.canvas)
		c.canvas.draw.connect(_draw_still.bind(c))
		_cas.append(c)
	_apply_active()

func _apply_active() -> void:
	if _vp == null:
		return
	for c in _cas:
		c.ref = Vector2(INF, INF)
		c.goal_ref = Vector2(INF, INF)
		c.dirty = true
		c.t_dirty = true
		c.b_i = -1
		c.vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	_comp_dirty = true
	_pushed = []
	_vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	set_process(active)
	if not active:
		var map := _map()
		if map != null and map.has_method("set_sun_shadows"):
			map.set_sun_shadows([], [], 0.0)

func _map() -> Node:
	return get_node_or_null("/root/Main/map")

func _light() -> DirectionalLight3D:
	return get_node_or_null("/root/Main/DirectionalLight3D2") as DirectionalLight3D

func _process(delta: float) -> void:
	var _pf := Perf.now()
	var cam := get_viewport().get_camera_3d()
	var light := _light()
	var map := _map()
	if cam == null or light == null or map == null:
		return
	var texel: float = WINDOW / float(VP_SIZE)
	_cam2 = Vector2(cam.global_position.x, cam.global_position.z)
	var fw := Vector2(-cam.global_basis.z.x, -cam.global_basis.z.z)
	if fw.length_squared() > 1e-6:
		_fwd2 = fw.normalized()
	_center = (_cam2 / texel).floor() * texel
	var d: Vector3 = -light.global_basis.z
	if d.y > -MIN_SUN_Y:
		d = Vector3(d.x, 0.0, d.z).normalized() * sqrt(1.0 - MIN_SUN_Y * MIN_SUN_Y) + Vector3(0, -MIN_SUN_Y, 0)
	_dir = d
	# a shadow keeps what the engine's kept (`shadow_opacity`) and goes with the light
	var strength: float = light.shadow_opacity * clampf(light.light_energy, 0.0, 1.0)
	_rev_t -= delta
	var rn := get_node_or_null("/root/Main/map/Resource_Nodes")
	if rn != null and not rn.has_method("shadow_records"):
		rn = null
	var rev_ask: bool = rn != null and _rev_t <= 0.0
	if rev_ask:
		_rev_t = REV_EVERY
	var shown_to: float = haze.x + HAZE_SHOWN * (haze.y - haze.x)
	for c: Cas in _cas:
		var on: bool = c.k == 0 or c.inner < shown_to
		if on != c.on:
			c.on = on
			c.ref = Vector2(INF, INF)
			c.goal_ref = Vector2(INF, INF)
			c.b_i = -1
		if not on:
			continue
		# GROUND THE CAMERA TURNS TO GETS ITS HEIGHTS: until it was looked at it was never built, so the
		# march had nothing there (the holes); a refresh asks again while it is being built
		if c.h_fwd.dot(_fwd2) < HOLE_TURN_COS:
			c.h_fwd = _fwd2
			c.bursts = HOLE_BURSTS
			c.burst_t = 0.0
		if c.bursts > 0:
			c.burst_t -= delta
			if c.burst_t <= 0.0:
				c.bursts -= 1
				c.burst_t = HOLE_GAP
				c.t_dirty = true
		var moved: bool = c.goal_ref.x == INF or _cheb(_cam2 - c.goal_ref) > c.step - c.cell
		var turned: bool = c.goal_dir.distance_squared_to(_dir) > TERR_TURN * TERR_TURN
		if moved or turned:
			c.dirty = true
			c.t_dirty = true
			c.b_i = -1                   # what is in flight is for a window or a light already gone
		elif rev_ask and c.b_i < 0 and not c.dirty \
				and rn.shadow_rev_in(c.goal_ref, c.win * 0.5 + CASTER_PAD) != c.rev:
			c.dirty = true
	var _pb := Perf.now()
	_build_tick(rn)
	Perf.mark("sun_shadows.build", _pb)
	var _pt := Perf.now()
	_terrain_tick(map)
	Perf.mark("sun_shadows.terrain", _pt)
	for c: Cas in _cas:
		if c.redraw:
			c.redraw = false
			c.canvas.queue_redraw()
			c.vp.render_target_update_mode = SubViewport.UPDATE_ONCE
			if c.k == 0:
				_comp_dirty = true
	# THE COMPOSITE IS DRAWN WHEN SOMETHING IN IT CHANGED: the window, the light, its still layer, a
	# machine or a loose block. What it was drawn from is asked only while the window stands, so a
	# drive pays nothing for the question; a stop costs one more drawing, then nothing.
	var sig := PackedFloat32Array()
	var redraw: bool = _comp_dirty or _center != _sig_center \
			or _sig_dir.distance_squared_to(_dir) > IDLE_TURN * IDLE_TURN
	if not redraw:
		sig = _scene_sig()
		redraw = sig != _sig
	if redraw:
		_comp_dirty = false
		_sig_center = _center
		_sig_dir = _dir
		_sig = sig
		_canvas.queue_redraw()
		_vp.render_target_update_mode = SubViewport.UPDATE_ONCE
	_push(map, strength)
	Perf.mark("sun_shadows", _pf)

static func _cheb(v: Vector2) -> float:
	return maxf(absf(v.x), absf(v.y))

## The maps and their windows into the ground's material, when one of them changed: uv = world XZ *
## x + yz, w = the window's half in metres, 0 for a map not built (the ground skips it).
func _push(map: Node, strength: float) -> void:
	var texs: Array = [_vp.get_texture()]
	var uvs: Array = [_uv(_center, WINDOW * 0.5)]
	for k in range(1, _cas.size()):
		var c: Cas = _cas[k]
		texs.append(c.vp.get_texture())
		# a map the camera has left (a respawn far off, a switch to a machine across the map) is not
		# handed over until it is built again round it: as the last window it would fade out
		# everything, the near one's machines included
		var fresh: bool = c.on and c.ref.x != INF and _cheb(_cam2 - c.ref) <= 2.0 * c.step
		uvs.append(_uv(c.ref, c.win * 0.5) if fresh else Vector4.ZERO)
	# the ground's material too: a new one (a map set up again, the probe's variants) has none of it
	var now: Array = [uvs, snappedf(strength, 0.002), map.get("_mat")]
	if now == _pushed:
		return
	_pushed = now
	if map.has_method("set_sun_shadows"):
		map.set_sun_shadows(texs, uvs, strength)

static func _uv(center: Vector2, half: float) -> Vector4:
	var s: float = 0.5 / half
	return Vector4(s, 0.5 - center.x * s, 0.5 - center.y * s, half)

## What the near composite is drawn from, besides the window and the light: every machine in reach
## by its transform and block count, and every loose block that is awake. Equal to the last one -
## a parked camera over a still base - the map is not drawn again.
func _scene_sig() -> PackedFloat32Array:
	var s := PackedFloat32Array()
	var half: float = WINDOW * 0.5
	for m in get_tree().get_nodes_in_group(MachineBody.MACHINES):
		var mn := m as Node3D
		if mn == null or not mn.is_inside_tree() or not mn.is_visible_in_tree():
			continue
		var xf: Transform3D = mn.global_transform
		if absf(xf.origin.x - _center.x) > half + MACHINE_REACH or absf(xf.origin.z - _center.y) > half + MACHINE_REACH:
			continue
		s.append_array([xf.origin.x, xf.origin.y, xf.origin.z, xf.basis.x.x, xf.basis.x.y, xf.basis.x.z,
				xf.basis.z.x, xf.basis.z.y, xf.basis.z.z, float(mn.get_child_count())])
	var objs := get_node_or_null("/root/Main/objects")
	if objs != null:
		var n := 0
		for c in objs.get_children():
			var vb := c as VehicleBlock
			if vb == null or not vb.is_inside_tree():
				continue
			var bp: Vector3 = vb.global_position
			if absf(bp.x - _center.x) > half + 4.0 or absf(bp.z - _center.y) > half + 4.0:
				continue
			n += 1
			if not vb.sleeping:
				s.append_array([bp.x, bp.y, bp.z])
		s.append(float(n))
	return s

# ── The still layers ────────────────────────────────────────────────────────
## A slice of the still layers' polygons a frame, near cascade first. A build walks the records round
## its centre (`ResourceNodes.shadow_records`), takes the casters in its window (`cast_entry`), reuses
## the polygons it kept for every caster still there and unchanged when the light has not turned
## (`memo`), and shows the result in one go when it is complete.
func _build_tick(rn: Node) -> void:
	if rn == null:
		return
	var t_end: int = Time.get_ticks_usec() + BUILD_USEC
	for c: Cas in _cas:
		if not c.on:
			continue
		if c.b_i < 0:
			if not c.dirty:
				continue
			_build_start(c, rn)
		var half: float = c.win * 0.5 + CASTER_PAD
		while c.b_i < c.b_list.size():
			if Time.get_ticks_usec() >= t_end:
				return
			var v: Dictionary = c.b_list[c.b_i]
			c.b_i += 1
			var gp: Vector3 = v["gpos"]
			if absf(gp.x - c.b_ref.x) > half or absf(gp.z - c.b_ref.y) > half:
				continue
			if c.detail == 0 and v.get("wood") != true:
				continue                     # at 2 m a texel a vein is a blob under a texel: crowns only
			var ce = v.get("sc")
			if ce == null:
				ce = rn.cast_entry(v)
			if not (ce is Array):
				continue
			var e: Array = ce
			var key = e[e.size() - 1]
			var got = c.memo.get(key) if c.b_reuse else null
			if got == null:
				got = _caster_polys(e, c.b_dir, c.b_org, c.ppm, c.detail)
			c.b_memo[key] = got
			c.b_polys.append_array(got)
		# complete: shown in one go
		c.memo = c.b_memo
		c.memo_dir = c.b_dir
		c.memo_org = c.b_org
		c.polys = c.b_polys
		c.org = c.b_org
		c.ref = c.b_ref
		c.b_i = -1
		c.b_list = []
		c.b_polys = []
		c.b_memo = {}
		c.redraw = true

func _build_start(c: Cas, rn: Node) -> void:
	c.dirty = false
	c.b_ref = (_cam2 / c.cell).round() * c.cell
	# A STILL LAYER IS CAST BY THE LIGHT ITS POLYGONS WERE KEPT FOR until it has turned `TERR_TURN`: the
	# day moves the sun every `DayCycle.TICK`, and a build for a move cast by that frame's light would
	# make every polygon anew. The kept ones are laid off from their own origin; the rest made there.
	c.b_reuse = c.memo_dir.distance_squared_to(_dir) <= TERR_TURN * TERR_TURN \
			and c.memo_org.distance_squared_to(c.b_ref) < 4.0 * c.win * c.win
	c.b_dir = c.memo_dir if c.b_reuse else _dir
	c.b_org = c.memo_org if c.b_reuse else c.b_ref
	c.goal_ref = c.b_ref
	c.goal_dir = c.b_dir
	if not c.b_reuse:
		c.memo = {}
	c.rev = rn.shadow_rev_in(c.b_ref, c.win * 0.5 + CASTER_PAD)
	c.b_list = rn.shadow_records(c.b_ref, c.win * 0.5 + CASTER_PAD)
	c.b_i = 0
	c.b_polys = []
	c.b_memo = {}

## A world point dropped along `d` onto the plane y = g, in pixels round `org` at `ppm`.
## A point under the plane stays where it is (it would be thrown away from the light).
static func _sp(p: Vector3, g: float, d: Vector3, org: Vector2, ppm: float) -> Vector2:
	var t: float = maxf((g - p.y) / d.y, 0.0)
	var q: Vector3 = p + d * t
	return Vector2(q.x - org.x, q.z - org.y) * ppm

## One caster's polygons for a still layer: a tree's trunk and crown, a vein's outline.
## THE CROWN IS A SHORT DRUM, radius cr and `CROWN_HALF` x cr up and down from its middle: a
## horizontal circle drops onto the ground as a circle of its own radius, so the drum's shadow is a
## STADIUM - two half circles round the shadows of its top and bottom centres, joined - built
## straight, where it used to be twenty projected points and a convex hull a tree.
func _caster_polys(e: Array, d: Vector3, org: Vector2, ppm: float, detail: int) -> Array:
	var out: Array = []
	if int(e[0]) == 0:
		var foot: Vector3 = e[1]
		var ch: float = e[2]
		var cr: float = e[3]
		var g: float = foot.y
		var top: Vector3 = foot + Vector3.UP * ch
		if detail > 0:
			var a := _sp(foot, g, d, org, ppm)
			var b := _sp(top, g, d, org, ppm)
			if a.distance_squared_to(b) > 1.0:
				var side := (b - a).orthogonal().normalized() * TRUNK_R * cr / 2.5 * ppm
				out.append(PackedVector2Array([a - side, a + side, b + side, b - side]))
		var c1 := _sp(top + Vector3.UP * cr * CROWN_HALF, g, d, org, ppm)
		var c2 := _sp(top - Vector3.UP * cr * CROWN_HALF, g, d, org, ppm)
		var r: float = cr * ppm
		var u := c1 - c2
		u = u.normalized() if u.length_squared() > 1e-6 else Vector2.RIGHT
		var v := u.orthogonal()
		var arc: int = CROWN_ARC if detail > 0 else FAR_CROWN_ARC
		var ring := PackedVector2Array()
		ring.resize((arc + 1) * 2)
		for i in arc + 1:
			var t: float = PI * float(i) / float(arc) - PI * 0.5
			ring[i] = c1 + (u * cos(t) + v * sin(t)) * r
			ring[arc + 1 + i] = c2 - (u * cos(t) + v * sin(t)) * r
		out.append(ring)
	else:
		var xf: Transform3D = e[1]
		var pts: PackedVector3Array = e[2]
		if pts.size() >= 3:
			var flat := PackedVector2Array()
			flat.resize(pts.size())
			for k in pts.size():
				flat[k] = _sp(xf * pts[k], xf.origin.y, d, org, ppm)
			var hull := _open(Geometry2D.convex_hull(flat))
			if hull.size() >= 3:
				out.append(hull)
	return out

## `convex_hull` closes the ring by repeating its first point; a thin hull with that seam fails the
## canvas's triangulation (the engine prints it every frame), so the ring goes in open.
static func _open(h: PackedVector2Array) -> PackedVector2Array:
	if h.size() > 1 and h[0] == h[h.size() - 1]:
		h.resize(h.size() - 1)
	return h

## A still layer: its ground shade, then its trees and veins, laid off from where each was made.
var still_us := 0                    # what the still layers took to record, summed (the probe reads it)
func _draw_still(c: Cas) -> void:
	var t0 := Time.get_ticks_usec()
	var lo: Vector2 = c.ref - Vector2(c.win, c.win) * 0.5
	if c.t_tex != null and c.t_center.x != INF:
		var tlo: Vector2 = c.t_center - Vector2(c.win, c.win) * 0.5
		c.canvas.draw_texture_rect(c.t_tex, Rect2(((tlo - lo) * c.ppm).round(), Vector2(c.px, c.px)), false)
	if not c.polys.is_empty():
		var col := Color(1, 1, 1, 1)
		c.canvas.draw_set_transform(((c.org - lo) * c.ppm).round())
		for poly in c.polys:
			c.canvas.draw_colored_polygon(poly, col)
		c.canvas.draw_set_transform(Vector2.ZERO)
	still_us += Time.get_ticks_usec() - t0

# ── The near composite ──────────────────────────────────────────────────────
## A world point dropped along the light onto the plane y = g, in the composite's pixels.
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

var draw_us := 0                     # what the last composite took to record
var draw_total_us := 0               # and all of them, summed (the probe reads it)
func _draw_casters() -> void:
	var t0 := Time.get_ticks_usec()
	var half: float = WINDOW * 0.5
	var col := Color(1, 1, 1, 1)
	_org = _center
	var ppm: float = float(VP_SIZE) / WINDOW
	# the near still layer (ground shade, trees, veins): one quad, laid off by whole pixels
	var c0: Cas = _cas[0]
	if c0.ref.x != INF:
		var lo0: Vector2 = c0.ref - Vector2(c0.win, c0.win) * 0.5
		var lo: Vector2 = _center - Vector2(WINDOW, WINDOW) * 0.5
		_canvas.draw_texture_rect(c0.vp.get_texture(), Rect2(((lo0 - lo) * ppm).round(), Vector2(c0.px, c0.px)), false)
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
	var objs := get_node_or_null("/root/Main/objects")
	if objs != null:
		_draw_loose(objs, half, ppm)
	draw_us = Time.get_ticks_usec() - t0
	draw_total_us += draw_us

## LOOSE BLOCKS LYING ABOUT CAST AS ONE MESH, made again only when one of them moved, came or went or
## the light turned `TERR_TURN`: each block's box shadow (`_box_shadow`, its ground asked of the
## terrain) was made and triangulated anew every frame for every block in reach, and loot after a
## fight is dozens of them. Laid off from where it was made (`_loose_org`) by whole pixels.
var _loose_mesh: ArrayMesh = null
var _loose_sig := PackedFloat32Array()
var _loose_org := Vector2.ZERO
var _loose_dir := Vector3(INF, INF, INF)

func _draw_loose(objs: Node, half: float, ppm: float) -> void:
	var sig := PackedFloat32Array()
	var shapes: Array = []
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
		var xf: Transform3D = cs.global_transform
		sig.append_array([xf.origin.x, xf.origin.y, xf.origin.z, xf.basis.x.x, xf.basis.x.y, xf.basis.x.z,
				xf.basis.z.x, xf.basis.z.y, xf.basis.z.z])
		shapes.append(cs)
	var turned: bool = _loose_dir.distance_squared_to(_dir) > TERR_TURN * TERR_TURN
	if sig != _loose_sig or turned or _cheb(_loose_org - _center) > half:
		_loose_sig = sig
		if turned:
			_loose_dir = _dir
		_loose_org = _center
		_loose_mesh = _make_loose(shapes)
	if _loose_mesh != null:
		_canvas.draw_set_transform(((_loose_org - _center) * ppm).round())
		_canvas.draw_mesh(_loose_mesh, null)
		_canvas.draw_set_transform(Vector2.ZERO)

func _make_loose(shapes: Array) -> ArrayMesh:
	var keep_dir := _dir
	_dir = _loose_dir
	_org = _loose_org
	var verts := PackedVector3Array()
	for cs: CollisionShape3D in shapes:
		var bp: Vector3 = cs.global_position
		var hull := _box_shadow(cs.global_transform, _box(cs.shape), G.ground_y(bp, bp.y - 1.0))
		for k in range(1, hull.size() - 1):
			verts.append(Vector3(hull[0].x, hull[0].y, 0.0))
			verts.append(Vector3(hull[k].x, hull[k].y, 0.0))
			verts.append(Vector3(hull[k + 1].x, hull[k + 1].y, 0.0))
	_dir = keep_dir
	_org = _center
	if verts.is_empty():
		return null
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	return mesh

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
## One refresh at a time, offered to the cascades in turn so a near one refreshing all the way along a
## drive cannot starve the far ones. Fetching is the main thread's (the terrain answers there), a
## slice a frame; the march is a worker's.
func _terrain_tick(map: Node) -> void:
	var ask: StringName = &"known_height" if map.has_method("known_height") else &"drawn_height"
	if not map.has_method(ask):
		return
	match _t_phase:
		0:
			for o in _cas.size():
				var c: Cas = _cas[(_t_next + o) % _cas.size()]
				if c.on and c.t_dirty:
					_t_next = (c.k + 1) % _cas.size()
					_terr_begin(c)
					break
		1:
			var j := _job
			var budget: int = TERR_FETCH_PER_FRAME
			while budget > 0 and j.r < j.runs.size():
				var start: int = j.runs[j.r]
				var count: int = j.runs[j.r + 1]
				var end: int = mini(j.i + budget, count)
				for t in range(j.i, end):
					var idx: int = start + t
					@warning_ignore("integer_division")
					var hv = map.call(ask, j.org.x + float(idx % j.n) * j.cell, j.org.y + float(idx / j.n) * j.cell)
					j.heights[idx] = hv if not is_nan(hv) else NO_GROUND
				budget -= end - j.i
				j.i = end
				if j.i >= count:
					j.r += 2
					j.i = 0
			if j.r >= j.runs.size():
				var c: Cas = j.cas
				c.h = j.heights
				c.h_org = j.org
				c.h_n = j.n
				_t_phase = 2
				j.out = PackedByteArray()
				j.out.resize(TERR_N * TERR_N)
				_t_task = WorkerThreadPool.add_task(_terr_march.bind(j))
		2:
			if WorkerThreadPool.is_task_completed(_t_task):
				WorkerThreadPool.wait_for_task_completion(_t_task)
				_t_task = -1
				_t_phase = 0
				var j := _job
				_job = null
				var c: Cas = j.cas
				if c.h_org == j.org:
					c.h_hruns = j.hruns
					c.h_hrow = j.hrow
				var img := Image.create_from_data(TERR_N, TERR_N, false, Image.FORMAT_L8, j.out)
				if c.t_tex == null:
					c.t_tex = ImageTexture.create_from_image(img)
				else:
					c.t_tex.update(img)
				c.t_center = j.center
				if c.on:
					c.redraw = true

## A refresh for cascade `c`: its window round the camera, whole cells over a fixed height grid (a
## refresh lands on the same cells, not half a cell off), the heights reaching `march` past it every
## way so a turned light needs none fetched. What the kept grid holds is copied row by row; what it
## has not got - the strips a move uncovered - is fetched, and with it the holes in view (`_ask_cols`)
## and a rolling band of rows (`TERR_REFRESH`). The cells to fetch are LISTED, run by run: walking
## every cell to find them was most of the cost (2 ms a frame on the optimize=none build with three
## grids of 11-19 thousand cells), and asking every hole again - behind the camera too, where nothing
## is built - was most of what a drive fetched.
func _terr_begin(c: Cas) -> void:
	c.t_dirty = false
	var j := TJob.new()
	j.cas = c
	j.cell = c.cell
	j.win = c.win
	j.march = c.march
	j.center = (_cam2 / c.cell).round() * c.cell
	j.dir = _dir
	var reach: float = c.win * 0.5 + c.march
	j.org = ((j.center - Vector2(reach, reach)) / c.cell).floor() * c.cell
	j.n = int(ceil(2.0 * reach / c.cell)) + 2
	var miss := PackedFloat32Array()
	miss.resize(j.n)
	miss.fill(UNFETCHED)
	var hs := PackedFloat32Array()
	var oi: int = 0
	var oj: int = 0
	var kept: bool = c.h_org.x != INF and c.h_n > 0
	if kept:
		oi = roundi((j.org.x - c.h_org.x) / c.cell)
		oj = roundi((j.org.y - c.h_org.y) / c.cell)
	var rows: int = maxi(int(ceil(float(j.n) * TERR_REFRESH)), 1)
	var ref_lo: int = c.h_refresh % j.n
	c.h_refresh = ref_lo + rows
	var holes: bool = kept and c.h_hrow.size() == c.h_n + 1
	var runs := PackedInt32Array()
	for row in j.n:
		var src: int = row + oj
		var s0: int = maxi(oi, 0)
		var s1: int = mini(c.h_n, oi + j.n)
		var refresh: bool = (row - ref_lo + j.n) % j.n < rows
		if not kept or src < 0 or src >= c.h_n or s1 <= s0:
			hs.append_array(miss)
			_run(runs, row * j.n, j.n)
			continue
		var left: int = s0 - oi
		if left > 0:
			hs.append_array(miss.slice(0, left))
		hs.append_array(c.h.slice(src * c.h_n + s0, src * c.h_n + s1))
		var right: int = j.n - left - (s1 - s0)
		if right > 0:
			hs.append_array(miss.slice(0, right))
		if refresh:
			_run(runs, row * j.n, j.n)
			continue
		_run(runs, row * j.n, left)
		if holes and c.h_hrow[src + 1] > c.h_hrow[src]:
			var ask := _ask_cols(j, row)
			var lo: int = maxi(ask.x, left)
			var hi: int = mini(ask.y, left + (s1 - s0))
			if hi > lo:
				for t in range(c.h_hrow[src], c.h_hrow[src + 1], 2):
					var a0: int = maxi(c.h_hruns[t] - oi, lo)
					var a1: int = mini(c.h_hruns[t] + c.h_hruns[t + 1] - oi, hi)
					if a1 > a0:
						_run(runs, row * j.n + a0, a1 - a0)
		_run(runs, row * j.n + left + (s1 - s0), right)
	j.heights = hs
	j.runs = runs
	j.r = 0
	j.i = 0
	_job = j
	_t_phase = 1

## The columns [x, y) of a grid row IN VIEW: within `HOLE_FIELD` of where the camera looks and within
## the view distance - what of a hole the terrain may have built by now. The field is convex, so a
## row crosses it in one stretch: two half planes through the camera and a circle.
func _ask_cols(j: TJob, row: int) -> Vector2i:
	var dz: float = j.org.y + float(row) * j.cell - _cam2.y
	var r: float = view + j.cell
	if absf(dz) >= r:
		return Vector2i(0, 0)
	var hw: float = sqrt(r * r - dz * dz)
	var x0: float = _cam2.x - hw
	var x1: float = _cam2.x + hw
	var e_r: Vector2 = _fwd2.rotated(-HOLE_FIELD)
	var e_l: Vector2 = _fwd2.rotated(HOLE_FIELD)
	# inside: cross(e_r, d) >= 0 and cross(d, e_l) >= 0, d = (x - cam.x, dz); each is a * x + b >= 0
	for ab in [Vector2(-e_r.y, e_r.x * dz + e_r.y * _cam2.x), Vector2(e_l.y, -e_l.y * _cam2.x - dz * e_l.x)]:
		if absf(ab.x) < 1e-6:
			if ab.y < 0.0:
				return Vector2i(0, 0)
			continue
		var xb: float = -ab.y / ab.x
		if ab.x > 0.0:
			x0 = maxf(x0, xb)
		else:
			x1 = minf(x1, xb)
	if x1 <= x0:
		return Vector2i(0, 0)
	return Vector2i(clampi(floori((x0 - j.org.x) / j.cell), 0, j.n), clampi(ceili((x1 - j.org.x) / j.cell) + 1, 0, j.n))

## A run of cells to fetch; one that starts where the last ended joins it.
static func _run(runs: PackedInt32Array, from: int, count: int) -> void:
	if count <= 0:
		return
	var n: int = runs.size()
	if n >= 2 and runs[n - 2] + runs[n - 1] == from:
		runs[n - 1] += count
		return
	runs.append(from)
	runs.append(count)

## On a worker: the job's packed arrays in, its packed bytes out, nothing else touched.
func _terr_march(j: TJob) -> void:
	# the holes, as runs a row: what the next refresh asks again where it is in view
	j.hruns = PackedInt32Array()
	j.hrow = PackedInt32Array()
	j.hrow.resize(j.n + 1)
	for row in j.n:
		j.hrow[row] = j.hruns.size()
		var base: int = row * j.n
		var i := 0
		while i < j.n:
			if j.heights[base + i] >= NO_GROUND * 0.1:
				i += 1
				continue
			var from: int = i
			while i < j.n and j.heights[base + i] < NO_GROUND * 0.1:
				i += 1
			j.hruns.append(from)
			j.hruns.append(i - from)
	j.hrow[j.n] = j.hruns.size()
	var flat := Vector2(-j.dir.x, -j.dir.z)
	var fl: float = flat.length()
	if fl < 1e-6:
		j.out.fill(0)
		return
	var step := flat / fl * j.cell
	var rise: float = -j.dir.y / fl * j.cell        # how much the ray climbs a step
	var steps: int = int(j.march / j.cell)
	var x0: float = j.center.x - j.win * 0.5 + j.cell * 0.5
	var z0: float = j.center.y - j.win * 0.5 + j.cell * 0.5
	for jz in TERR_N:
		for ix in TERR_N:
			var px: float = x0 + float(ix) * j.cell
			var pz: float = z0 + float(jz) * j.cell
			var y: float = _grid(j, px, pz) + TERR_LIFT
			var dark := 0
			# A CELL WITH NO DRAWN GROUND UNDER IT (or beside it - the read is bilinear) IS NOT DARK.
			# It stands at NO_GROUND, so every real height round it rose over its ray: whole
			# nodes not drawn yet came out as black rectangles in the map.
			if y < NO_GROUND * 0.01:
				j.out[jz * TERR_N + ix] = 0
				continue
			for s in steps:
				px += step.x
				pz += step.y
				y += rise
				if _grid(j, px, pz) > y:
					dark = 255
					break
			j.out[jz * TERR_N + ix] = dark

static func _grid(j: TJob, x: float, z: float) -> float:
	var fx: float = (x - j.org.x) / j.cell
	var fz: float = (z - j.org.y) / j.cell
	var i: int = clampi(int(fx), 0, j.n - 2)
	var k: int = clampi(int(fz), 0, j.n - 2)
	var tx: float = clampf(fx - float(i), 0.0, 1.0)
	var tz: float = clampf(fz - float(k), 0.0, 1.0)
	var r0: int = k * j.n + i
	var r1: int = r0 + j.n
	return lerpf(lerpf(j.heights[r0], j.heights[r0 + 1], tx), lerpf(j.heights[r1], j.heights[r1 + 1], tx), tz)

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
