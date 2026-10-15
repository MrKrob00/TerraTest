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
## and built again only when the camera has gone `step` from that point, a caster in its reach changed
## (`ResourceNodes.shadow_rev_in`, asked every `REV_EVERY`) or a new ground shade landed. THE LIGHT IS
## NOT IN IT: a caster is kept as its solid's triangles with their heights and thrown along the light by
## a canvas shader (`SHEAR`), so a turned sun is a uniform and a re-render. The near composite takes
## its still layer as one textured quad laid off by whole pixels, where it used to record and
## triangulate every tree's polygons every frame, and the loose blocks as one mesh (`_draw_loose`).
## A far cascade is built only when the haze at its inner edge still lets the ground show (`haze`, from
## `Main._apply_view`): at the 200 m view they are off. Measured on the optimize=none build, everything
## this node costs a frame, the camera standing / at 5 m/s / at 20 m/s: the old single window against
## the cascades, the day stopped, 1.48 / 1.32 / 1.69 ms against 0.47 / 0.96 / 1.64; with the day
## running, the cascades casting by the light against the sheared layers, 1.26 / 2.08 / 2.2-2.5 against
## 0.61-0.73 / 1.32 / 1.35-1.6 (the build alone 0.6-0.9 -> 0.1-0.2). What is left at speed is the
## heights a moving window uncovers (~1100 a second at 20 m/s, ~11 us each there).
## A caster's triangles are KEPT between builds as ONE MESH A REGION (`Cas.memo`, `Cas.meshes`, in
## pixels round a fixed origin): moving the window only lays them off again, and only the regions that
## came in or changed cost anything, a slice a frame (`BUILD_USEC`). The ground shade's heights come a
## row at a call (`ChunkTerrain.known_heights_into`).
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
const TRUNK_SPAN := 1.072            # 2 / (1 + cos 30 deg): three quads' shadow is 0.93-1.07 of 2 x TRUNK_R
const CROWN_HALF := 0.6              # of the crown's radius, its half height: a crown is a short drum
const CROWN_SIDES := 12              # a crown's drum: its sides on the near and middle maps,
const FAR_CROWN_SIDES := 8           # and on the far one
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
const TERR_TURN := 0.02              # of the light direction (~1.1 deg), at the near cascade's texel
const TURN_SPAN_MAX := 4.0           # a far cascade's turn: TERR_TURN x its texel over the near one's, at most this
const TERR_FETCH_PER_FRAME := 250
const TERR_REFRESH := 2              # rows of the window fetched again on every refresh
const NO_GROUND := -1.0e6            # a fetched cell with nothing drawn: lower than any ridge
const UNFETCHED := -1.0e7
const REV_EVERY := 0.5               # s: a changed caster is redrawn at most this often
const BUILD_USEC := 1500             # a frame's share of building the still layers' polygons
const IDLE_TURN := 0.002             # a turn of the light (~0.1 deg) the near composite redraws for
const SHEAR_H := 12.0                # m: a tall caster (a tree's crown); a still layer is drawn again
const SHEAR_PX := 1.0                # when its shadow has moved this many of the layer's pixels
const HOLE_TURN_COS := 0.9           # a camera turned ~25 deg asks for a refresh (the holes now in view),
const HOLE_BURSTS := 2               # twice, `HOLE_GAP` s apart: the ground there is still being built
const HOLE_GAP := 2.0
const HOLE_FIELD := 1.05             # rad, half the field a hole is asked again in (the screen's ~50 + a margin)
const HOLE_EVERY := 4.0              # s: the holes in view are asked again at most this often, a turn aside

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
	var turn := 0.0                  # how far the light turns before this map's ground shade is marched again
	var inner := 0.0                 # m from the camera where it takes over from the one before
	var on := false
	var vp: SubViewport = null
	var canvas: Node2D = null
	# what the map shows
	var ref := Vector2(INF, INF)     # centre of the map
	var meshes: Array = []           # a mesh a region, its casters' triangles in pixels round `org`
	var cast: Node2D = null          # draws `meshes` through `mat`, over the ground shade `canvas` draws
	var mat: ShaderMaterial = null   # `shear`: the light's throw in pixels a metre of height
	var shear := Vector2(INF, INF)   # what `mat` throws, pixels a metre of height
	var org := Vector2.ZERO
	var redraw := false
	# kept between builds, round `memo_org`: region key -> [its rev, its mesh (null: casts nothing),
	# {caster key -> [the caster's triangles, their heights]}]
	var memo: Dictionary = {}
	var memo_org := Vector2.ZERO
	# the build asked last and the one in flight
	var goal_ref := Vector2(INF, INF)
	var goal_dir := Vector3(INF, INF, INF)
	var dirty := true
	var rev := 0                     # `ResourceNodes.shadow_rev_in` round the last build
	var b_i := -1                    # -1: none in flight; else the record in the region in flight
	var b_g := 0                     # the region in flight
	var b_list: Array = []           # `ResourceNodes.shadow_groups`
	var b_rt := PackedVector2Array() # the region in flight's triangles
	var b_rh := PackedVector2Array() # and their heights
	var b_rc: Dictionary = {}        # and its casters'
	var b_old: Dictionary = {}       # what the region cast last time, by caster
	var b_ref := Vector2.ZERO
	var b_org := Vector2.ZERO
	var b_reuse := false
	var b_meshes: Array = []
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
	var hole_t := 0.0                # until the holes in view may be asked again
	var hole_due := true             # the next refresh asks them
	var hole_ep := -1                # `ChunkTerrain.built_epoch` when they were asked last
	var refetch: Array = []          # world rects the ground changed under: fetched again next refresh

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
var _built_ep := 0                   # `ChunkTerrain.built_epoch` this frame
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
		# A TURN SHIFTS A SHADOW BY ITS LENGTH x THE TURN, so a coarse map takes a bigger one for the
		# same shift in texels: the day turns the sun TERR_TURN every ~5 s, and every cascade cast anew
		# each time was most of what the far maps cost a minute
		c.turn = TERR_TURN * minf((float(CASCADES[0][1]) / float(CASCADES[0][0])) / c.ppm, TURN_SPAN_MAX)
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
		c.mat = ShaderMaterial.new()
		c.mat.shader = SHEAR
		c.cast = Node2D.new()
		c.cast.material = c.mat
		c.canvas.add_child(c.cast)
		c.cast.draw.connect(_draw_cast.bind(c))
		# CULLED BY A RECT OF ITS OWN, THE WHOLE LAYER: the engine culls a canvas item by its commands'
		# rects, taken from the meshes before the shader throws them, so a window whose casters all
		# stand past its edge dropped the shadows they throw into it
		RenderingServer.canvas_item_set_custom_rect(c.cast.get_canvas_item(), true, Rect2(0.0, 0.0, float(c.px), float(c.px)))
		_cas.append(c)
	_make_templates()
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
	if map.has_signal(&"ground_changed") and not map.is_connected(&"ground_changed", _on_ground_changed):
		map.connect(&"ground_changed", _on_ground_changed)
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
	_built_ep = int(map.call(&"built_epoch")) if map.has_method(&"built_epoch") else 0
	var rn := get_node_or_null("/root/Main/map/Resource_Nodes")
	if rn != null and not rn.has_method("shadow_groups"):
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
				c.hole_due = true
		# and every `HOLE_EVERY` whatever the camera does: ground ahead is built after a refresh asked
		# for it (the first ones run under the loading screen), and a drive straight on turns nothing.
		# The next refresh a move or a light turn makes asks them; the timer makes one of its own only
		# when the terrain has built or dropped something since they were asked - a parked camera with
		# holes only behind it re-marched every map every 4 s for the same picture, and one parked with
		# the day still (the proving ground) never saw ground in view that landed after the bursts
		c.hole_t -= delta
		if c.hole_t <= 0.0:
			c.hole_t = HOLE_EVERY
			c.hole_due = true
			if _built_ep != c.hole_ep and not c.h_hruns.is_empty():
				c.t_dirty = true
		var moved: bool = c.goal_ref.x == INF or _cheb(_cam2 - c.goal_ref) > c.step - c.cell
		if moved:
			# A BUILD IN FLIGHT IS FINISHED, NOT DROPPED: thrown away at every move it never finished
			# where a fresh cast took longer than driving a step (a phone in a fight), and the map stood
			# where it was last built until `_push` let it go. It lands, and the next starts from it.
			# The goal moves now, so a move is seen once a step: left at the build in flight, every
			# frame past it raised the ground shade again and refreshed it back to back.
			c.goal_ref = (_cam2 / c.cell).round() * c.cell
			c.dirty = true
			c.t_dirty = true
		# THE LIGHT IS A UNIFORM, NOT A BUILD: the casters' triangles are kept by height and thrown
		# along the light in `SHEAR`, so a turn of the sun re-renders the maps and builds nothing; only
		# the ground's own shade is marched again, at the cascade's own `turn`
		if c.goal_dir.distance_squared_to(_dir) > c.turn * c.turn:
			c.goal_dir = _dir
			c.t_dirty = true
		# re-rendered once a tall caster's shadow has moved a pixel of this layer: the day turns the sun
		# a fifth of a degree every `DayCycle.TICK`, and three layers drawn again at each was fill for
		# nothing - a coarse layer goes ppm-times longer
		var sh: Vector2 = Vector2(_dir.x, _dir.z) / -_dir.y * c.ppm
		if c.shear.x == INF or (sh - c.shear).length_squared() * SHEAR_H * SHEAR_H > SHEAR_PX * SHEAR_PX:
			c.shear = sh
			c.mat.set_shader_parameter(&"shear", sh)
			if c.ref.x != INF:
				c.vp.render_target_update_mode = SubViewport.UPDATE_ONCE
				if c.k == 0:
					_comp_dirty = true
		# its own question, not the `else` of the re-render: the two run on about the same period, and
		# in phase a felled tree kept its shadow for as long as they stayed so
		if rev_ask and c.b_i < 0 and not c.dirty \
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
			c.cast.queue_redraw()
			c.vp.render_target_update_mode = SubViewport.UPDATE_ONCE
			if c.k == 0:
				_comp_dirty = true
	# THE COMPOSITE IS DRAWN WHEN SOMETHING IN IT CHANGED: the window, the light, its still layer, a
	# machine or a loose block. What it was drawn from is asked only while the window stands, so a
	# drive pays nothing for the question; a stop costs one more drawing, then nothing.
	# The signature is taken whenever the window stands, a redraw due or not: kept empty after a redraw
	# for another reason, the next standing frame read as a change and drew everything again.
	var sig := PackedFloat32Array()
	var standing: bool = _center == _sig_center
	var redraw: bool = _comp_dirty or not standing \
			or _sig_dir.distance_squared_to(_dir) > IDLE_TURN * IDLE_TURN
	if standing:
		sig = _scene_sig()
		redraw = redraw or sig != _sig
	if redraw:
		_comp_dirty = false
		_sig_center = _center
		_sig_dir = _dir
		_sig = sig
		_canvas.queue_redraw()
		_vp.render_target_update_mode = SubViewport.UPDATE_ONCE
	_push(map, strength)
	Perf.mark("sun_shadows", _pf)

## THE KEPT HEIGHTS UNDER A GROUND EDIT ARE ASKED AGAIN (a quest's levelled pad, the edits replayed
## on load): a refresh copies what it kept and fetches only what it has not got, so the slope under a
## new pad was marched over until the rolling band came round to it - minutes standing still. Whatever
## is not built again yet comes back a hole and is asked again as one.
func _on_ground_changed(area: Rect2) -> void:
	for c: Cas in _cas:
		c.refetch.append(area.grow(c.cell))
		c.t_dirty = true

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
## A slice of the still layers' triangles a frame, near cascade first. A build walks the regions round
## its centre (`ResourceNodes.shadow_groups`): a region whose casters have not changed (its rev) lays
## in the mesh it made last time, whole - the light is not in it (`SHEAR`); one that changed is walked
## caster by caster (`cast_entry`), each unchanged caster's triangles reused from that region's last
## cast. So a move costs the regions that came in, not every record in reach - at 20 m/s on the real
## driver the walk was 0.67 ms a frame. EVERY RECORD OF A REGION IN REACH IS CAST, in the window or
## not: the triangles past its edge are clipped, and a region's cast stays one piece whatever the
## window. The result is shown in one go when it is complete.
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
		while c.b_g < c.b_list.size():
			var grp: Array = c.b_list[c.b_g]
			var rk = grp[0]
			var rev: int = grp[1]
			var recs: Array = grp[2]
			if c.b_i == 0:
				var last = c.memo.get(rk) if c.b_reuse else null
				if last != null and int(last[0]) == rev:
					c.b_memo[rk] = last
					if last[1] != null:
						c.b_meshes.append(last[1])
					c.b_g += 1
					continue
				c.b_old = last[2] if last != null else {}
				c.b_rt = PackedVector2Array()
				c.b_rh = PackedVector2Array()
				c.b_rc = {}
			while c.b_i < recs.size():
				if Time.get_ticks_usec() >= t_end:
					return
				var v: Dictionary = recs[c.b_i]
				c.b_i += 1
				if c.detail == 0 and v.get("wood") != true:
					continue                 # at 2 m a texel a vein is a blob under a texel: crowns only
				var ce = v.get("sc")
				if ce == null:
					ce = rn.cast_entry(v)
				if not (ce is Array):
					continue
				var e: Array = ce
				var key = e[e.size() - 1]
				var got = c.b_old.get(key)
				if got == null:
					got = _caster_tris(e, c.b_org, c.ppm, c.detail)
				c.b_rc[key] = got
				c.b_rt.append_array(got[0])
				c.b_rh.append_array(got[1])
			# A MESH A REGION: a move lays the kept ones in again and builds nothing - one mesh for the
			# layer was every region's triangles copied and uploaded again at every step
			var rm: ArrayMesh = null
			if not c.b_rt.is_empty():
				var arr := []
				arr.resize(Mesh.ARRAY_MAX)
				arr[Mesh.ARRAY_VERTEX] = c.b_rt
				arr[Mesh.ARRAY_TEX_UV] = c.b_rh
				rm = ArrayMesh.new()
				rm.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
				c.b_meshes.append(rm)
			c.b_memo[rk] = [rev, rm, c.b_rc]
			c.b_g += 1
			c.b_i = 0
		# complete: shown in one go - a polygon a draw command was 0.8 ms a frame of recording at
		# 20 m/s on the real driver (optimize=none), most of what the still layers cost
		c.memo = c.b_memo
		c.memo_org = c.b_org
		c.meshes = c.b_meshes
		c.org = c.b_org
		c.ref = c.b_ref
		c.b_i = -1
		c.b_list = []
		c.b_meshes = []
		c.b_memo = {}
		c.b_old = {}
		c.b_rc = {}
		c.b_rt = PackedVector2Array()
		c.b_rh = PackedVector2Array()
		c.redraw = true

func _build_start(c: Cas, rn: Node) -> void:
	c.dirty = false
	# THE LAYER AND THE GROUND'S SHADE ARE CENTRED ON ONE POINT, `goal_ref`, set when a move is seen: a
	# build that waited on one in flight was centred where the camera had got to by then while the shade
	# refreshed at the move stayed behind, and its leading strip had no ridge shade until the next step;
	# a build for a changed caster centred on the camera's cell set off a refresh of the shade as well
	c.b_ref = c.goal_ref if c.goal_ref.x != INF else (_cam2 / c.cell).round() * c.cell
	c.goal_ref = c.b_ref
	# The kept triangles are laid off from their own origin while it stays near; the rest are made there.
	c.b_reuse = c.memo_org.distance_squared_to(c.b_ref) < 4.0 * c.win * c.win
	c.b_org = c.memo_org if c.b_reuse else c.b_ref
	if not c.b_reuse:
		c.memo = {}
	c.rev = rn.shadow_rev_in(c.b_ref, c.win * 0.5 + CASTER_PAD)
	c.b_list = rn.shadow_groups(c.b_ref, c.win * 0.5 + CASTER_PAD)
	c.b_g = 0
	c.b_i = 0
	c.b_meshes = []
	c.b_memo = {}

## THE STILL LAYERS HOLD NO LIGHT. A caster is triangles in the ground's plane (pixels round `org`)
## with every vertex's HEIGHT over its own ground in UV.x, and the shader throws each vertex along the
## light by its height (`SHEAR`: the projection onto a horizontal plane is a shear, x + h * d.x / -d.y),
## so the union of a solid's faces is its shadow whatever the sun does. A turn of the sun is a uniform
## and a re-render; every caster cast again in GDScript at each `TERR_TURN` was most of what the maps
## cost with the day running (1.6 ms a frame at 20 m/s on the real driver, optimize=none). A vertex
## under its ground stays where it is (height 0), as the old projection kept it.
const SHEAR := preload("res://sun_shadow_shear.gdshader")

## A crown is a DRUM of `CROWN_SIDES`: its top cap and its side band - the swept band and one cap
## cover the other cap too, so the bottom is left out. A trunk is three upright quads 60 deg apart, each
## `TRUNK_SPAN` of the old width: one alone goes edge-on to a light along it, and two crossed threw a
## shadow 29% narrower with the sun on their diagonal; three keep it within 7% of the old at any sun. Unit templates, laid out by `Transform2D * PackedVector2Array`
## (native) per tree: xz the shape in the plane, f in x 0 at the bottom ring and 1 at the top.
var _crown_xz: Array = []            # [far, near]
var _crown_f: Array = []
var _trunk_xz := PackedVector2Array()
var _trunk_f := PackedVector2Array()

func _make_templates() -> void:
	for n in [FAR_CROWN_SIDES, CROWN_SIDES]:
		var ring := PackedVector2Array()
		for i in n:
			ring.append(Vector2(cos(TAU * float(i) / float(n)), sin(TAU * float(i) / float(n))))
		var xz := PackedVector2Array()
		var f := PackedVector2Array()
		var lo := Vector2.ZERO
		var hi := Vector2(1.0, 0.0)
		for i in range(1, n - 1):
			xz.append_array([ring[0], ring[i], ring[i + 1]])
			f.append_array([hi, hi, hi])
		for i in n:
			var p: Vector2 = ring[i]
			var q: Vector2 = ring[(i + 1) % n]
			xz.append_array([p, q, q, p, q, p])
			f.append_array([lo, lo, hi, lo, hi, hi])
		_crown_xz.append(xz)
		_crown_f.append(f)
	_trunk_xz = PackedVector2Array()
	_trunk_f = PackedVector2Array()
	for a in 3:
		var ax: Vector2 = Vector2.from_angle(PI / 3.0 * float(a)) * TRUNK_SPAN
		var p: Vector2 = -ax
		var q: Vector2 = ax
		_trunk_xz.append_array([p, q, q, p, q, p])
		_trunk_f.append_array([Vector2.ZERO, Vector2.ZERO, Vector2(1.0, 0.0), Vector2.ZERO, Vector2(1.0, 0.0), Vector2(1.0, 0.0)])

## One caster's triangles for a still layer and their heights: [PackedVector2Array, PackedVector2Array].
## A tree: the crown's drum, radius cr and `CROWN_HALF` x cr up and down from its middle, and on the
## near maps its trunk; an ore vein: its outline's surface (`ResourceNodes.cast_entry`, the extreme
## vertices in 26 directions joined as a grid), by its own transform.
func _caster_tris(e: Array, org: Vector2, ppm: float, detail: int) -> Array:
	var xz := PackedVector2Array()
	var hh := PackedVector2Array()
	if int(e[0]) == 0:
		var foot: Vector3 = e[1]
		var ch: float = e[2]
		var cr: float = e[3]
		var c := Vector2(foot.x - org.x, foot.z - org.y) * ppm
		var r: float = cr * ppm
		var h1: float = ch - cr * CROWN_HALF
		var h2: float = ch + cr * CROWN_HALF
		var t: int = 1 if detail > 0 else 0
		xz = Transform2D(Vector2(r, 0.0), Vector2(0.0, r), c) * (_crown_xz[t] as PackedVector2Array)
		hh = Transform2D(Vector2(h2 - h1, 0.0), Vector2(0.0, 1.0), Vector2(h1, 0.0)) * (_crown_f[t] as PackedVector2Array)
		if detail > 0:
			var w: float = TRUNK_R * cr / 2.5 * ppm
			xz.append_array(Transform2D(Vector2(w, 0.0), Vector2(0.0, w), c) * _trunk_xz)
			hh.append_array(Transform2D(Vector2(ch, 0.0), Vector2(0.0, 1.0), Vector2.ZERO) * _trunk_f)
	else:
		var xf: Transform3D = e[1]
		var tri: PackedVector3Array = e[2]
		# world -> (x pixels, z pixels, height over the vein's ground) in one native multiply
		var to_map := Transform3D(Basis(Vector3(ppm, 0.0, 0.0), Vector3(0.0, 0.0, 1.0), Vector3(0.0, ppm, 0.0)),
				Vector3(-org.x * ppm, -org.y * ppm, -xf.origin.y))
		var w: PackedVector3Array = (to_map * xf) * tri
		xz.resize(w.size())
		hh.resize(w.size())
		for i in w.size():
			var q: Vector3 = w[i]
			xz[i] = Vector2(q.x, q.y)
			hh[i] = Vector2(maxf(q.z, 0.0), 0.0)
	return [xz, hh]

## A still layer's ground shade, laid off from where it was marched; its trees and veins are the `cast`
## child's (`_draw_cast`), drawn over it.
var fetched_pts := 0                 # heights fetched for the ground shade, summed (the harness reads it)
var still_us := 0                    # what the still layers took to record, summed (the probe reads it)
func _draw_still(c: Cas) -> void:
	var t0 := Time.get_ticks_usec()
	var lo: Vector2 = c.ref - Vector2(c.win, c.win) * 0.5
	if c.t_tex != null and c.t_center.x != INF:
		var tlo: Vector2 = c.t_center - Vector2(c.win, c.win) * 0.5
		c.canvas.draw_texture_rect(c.t_tex, Rect2(((tlo - lo) * c.ppm).round(), Vector2(c.px, c.px)), false)
	still_us += Time.get_ticks_usec() - t0

## Its casters, over the shade, thrown along the light by `mat`.
func _draw_cast(c: Cas) -> void:
	if c.meshes.is_empty():
		return
	var t0 := Time.get_ticks_usec()
	var lo: Vector2 = c.ref - Vector2(c.win, c.win) * 0.5
	c.cast.draw_set_transform(((c.org - lo) * c.ppm).round())
	for m: ArrayMesh in c.meshes:
		c.cast.draw_mesh(m, null)
	c.cast.draw_set_transform(Vector2.ZERO)
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
	var rowwise: bool = map.has_method("known_heights_into")
	var ask: StringName = &"known_height" if map.has_method("known_height") else &"drawn_height"
	if not rowwise and not map.has_method(ask):
		return
	var _tp := Perf.now()
	var _tk: String = ["sun_shadows.t_begin", "sun_shadows.t_fetch", "sun_shadows.t_land"][_t_phase]
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
				if rowwise:
					# a row at a time: a run can carry on into the next row
					while j.i < end:
						var idx: int = start + j.i
						var col: int = idx % j.n
						var seg: int = mini(end - j.i, j.n - col)
						@warning_ignore("integer_division")
						map.call(&"known_heights_into", j.heights, idx, j.org.x + float(col) * j.cell, j.org.y + float(idx / j.n) * j.cell, j.cell, seg, NO_GROUND)
						j.i += seg
						budget -= seg
						fetched_pts += seg
				else:
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
	Perf.mark(_tk, _tp)

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
	j.center = c.goal_ref if c.goal_ref.x != INF else (_cam2 / c.cell).round() * c.cell
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
	# THE ROLLING REFRESH IS THE WINDOW'S, NOT THE GRID'S: what the ground shows is the window, and a
	# strip uncovered at the grid's edge was fetched from coarse ground `march` past it - the band
	# gives it the finer heights built since. Whole grid rows were 4-5 x the cells for heights the
	# march only reaches.
	var w0x: int = clampi(roundi((j.center.x - c.win * 0.5 - j.org.x) / c.cell), 0, j.n)
	var w0z: int = clampi(roundi((j.center.y - c.win * 0.5 - j.org.y) / c.cell), 0, j.n)
	var w1x: int = mini(w0x + TERR_N + 1, j.n)
	var wn: int = mini(TERR_N + 1, j.n - w0z)
	var rows: int = mini(TERR_REFRESH, wn)
	var ref_lo: int = c.h_refresh % maxi(wn, 1)
	c.h_refresh = ref_lo + rows
	# THE HOLES ARE ASKED AFTER A TURN AND AT MOST EVERY `HOLE_EVERY`, NOT ON EVERY REFRESH: one that
	# stayed a hole when asked is ground not built, and asked on every refresh of a drive - the near
	# window's every 12 m - they were most of what it fetched (headless, where nothing is built: 2.0
	# against 1.6 ms a frame at 20 m/s)
	var holes: bool = c.hole_due and kept and c.h_hrow.size() == c.h_n + 1
	if c.hole_due:
		c.hole_due = false
		c.hole_t = HOLE_EVERY
		c.hole_ep = _built_ep
	var runs := PackedInt32Array()
	for row in j.n:
		var src: int = row + oj
		var s0: int = maxi(oi, 0)
		var s1: int = mini(c.h_n, oi + j.n)
		var refresh: bool = (row - w0z - ref_lo + wn) % maxi(wn, 1) < rows and row >= w0z and row < w0z + wn
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
		var in1: int = left + (s1 - s0)
		_run(runs, row * j.n, left)
		var r0: int = in1
		var r1: int = left
		if refresh:
			# the window's columns; a hole inside them is fetched with them
			r0 = maxi(w0x, left)
			r1 = mini(w1x, in1)
			_run(runs, row * j.n + r0, r1 - r0)
		if holes and c.h_hrow[src + 1] > c.h_hrow[src]:
			var ask := _ask_cols(j, row)
			var lo: int = maxi(ask.x, left)
			var hi: int = mini(ask.y, in1)
			if hi > lo:
				for t in range(c.h_hrow[src], c.h_hrow[src + 1], 2):
					var a0: int = maxi(c.h_hruns[t] - oi, lo)
					var a1: int = mini(c.h_hruns[t] + c.h_hruns[t + 1] - oi, hi)
					if r1 > r0:
						if a0 >= r0 and a1 <= r1:
							continue
						if a0 < r0 and a1 > r0:
							_run(runs, row * j.n + a0, r0 - a0)
							a0 = maxi(a0, r1)
						elif a0 >= r0 and a0 < r1:
							a0 = r1
					if a1 > a0:
						_run(runs, row * j.n + a0, a1 - a0)
		_run(runs, row * j.n + in1, right)
	for a in c.refetch:
		var r: Rect2 = a
		var x0: int = clampi(floori((r.position.x - j.org.x) / c.cell), 0, j.n)
		var x1: int = clampi(ceili((r.end.x - j.org.x) / c.cell) + 1, 0, j.n)
		for row in range(clampi(floori((r.position.y - j.org.y) / c.cell), 0, j.n), clampi(ceili((r.end.y - j.org.y) / c.cell) + 1, 0, j.n)):
			_run(runs, row * j.n + x0, x1 - x0)
	c.refetch.clear()
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
