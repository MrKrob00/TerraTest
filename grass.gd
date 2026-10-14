# grass_system.gd
# Interactive grass via a TRAMPLE MAP (a.k.a. interaction/flatten texture):
# a top-down SubViewport stamps a soft blob under every ground-touching object, the stamps
# fade over a few seconds (grass springs back), and the grass shader presses each blade down
# by one texture fetch. Replaces the old per-vertex loop over 64 bend points → much cheaper
# on the GPU vertex shader (the project is GPU/fill-bound on Adreno), and the fade gives
# trails that linger after a vehicle has driven past.
extends Node3D

@export var map_node: StaticBody3D
## Сколько секунд трава остаётся примятой после ухода объекта (затухание следа).
@export var flatten_lifetime: float = 2.5
## Размер окна примятия в МИРЕ (единиц). Должно покрывать зону травы у камеры (≈ lod_distance_1 ×2).
@export var window_size: float = 130.0
## Радиус одного отпечатка в мире (единиц).
@export var stamp_radius: float = 2.5
## Бендер прижимает траву только если он не выше этого над рельефом (блоки на крыше машины игнор).
@export var ground_touch_height: float = 2.0
## Мин. сдвиг объекта, прежде чем оставить новый отпечаток (м) — чтобы стоящий объект не плодил их.
@export var footprint_spacing: float = 0.5
## Сколько отпечатков держим максимум (= размер пула спрайтов).
@export var max_footprints: int = 200

const VP_SIZE: int = 512
## A STILL PRESS (`press_zone`): 0.5 takes a blade's lift to exactly zero (glsl.gdshader `blade_at`:
## h -= r * 2 * height), a little over it keeps the blade just under the ground.
const ZONE_PRESS := 0.55
const ZONE_POOL := 4
const BENDER_REFRESH := 0.5
## How far a bender can get between two refreshes: 80 m/s is faster than anything that drives.
const BENDER_MARGIN := 40.0

var _initialized: bool = false
var _benders: Array = []
var _vp: SubViewport
var _sprite_pool: Array[Sprite2D] = []
var _stamp_tex: Texture2D
var _footprints: Array = []          # [{pos: Vector2 (world xz), born: float}]
var _time: float = 0.0
var _refresh_t: float = 0.0
var _zones: Dictionary = {}          # id -> Vector3(world x, world z, radius)
var _zone_pool: Array[Sprite2D] = []

# _ready идёт СНИЗУ ВВЕРХ: у детей он вызывается РАНЬШЕ, чем у родителя. Значит на этот
# момент карта ещё не выполнила свой _ready, и требовать от неё готовности сразу нельзя.
# Ждём, пока она начнёт отвечать, и только потом сдаёмся: прежний вариант ругался и
# делал return, из-за чего узел не инициализировался за весь сеанс.
const MAP_WAIT_FRAMES: int = 300      # ~5 секунд при 60 кадрах

func _ready() -> void:
	add_to_group("grass_system")
	if not await _await_map():
		push_error("GrassSystem: map_node так и не поддержал set_grass_trample()")
		return
	_benders = get_tree().get_nodes_in_group("grass_benders")
	_build_viewport()
	_initialized = true

# ── Build the flatten SubViewport + a pool of stamp sprites (all in code, no .tscn) ──────
func _build_viewport() -> void:
	_vp = SubViewport.new()
	_vp.size = Vector2i(VP_SIZE, VP_SIZE)
	_vp.transparent_bg = true                              # empty = red 0 = no press
	_vp.render_target_clear_mode = SubViewport.CLEAR_MODE_ALWAYS
	_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(_vp)

	_stamp_tex = _make_stamp_texture()
	var add_mat := CanvasItemMaterial.new()
	add_mat.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD   # overlapping prints accumulate
	for _i in max_footprints:
		var s := Sprite2D.new()
		s.texture = _stamp_tex
		s.material = add_mat
		s.visible = false
		_vp.add_child(s)
		_sprite_pool.append(s)
	var zone_tex := _make_zone_texture()
	for _i in ZONE_POOL:
		var z := Sprite2D.new()
		z.texture = zone_tex
		z.material = add_mat
		z.modulate = Color(ZONE_PRESS, ZONE_PRESS, ZONE_PRESS, 1.0)
		z.visible = false
		_vp.add_child(z)
		_zone_pool.append(z)

## GRASS HELD FLAT IN A DISC for as long as the zone is up (crash_site.gd's embers: a blade growing
## through a patch lying on the ground showed as a tuft out of the coals). Any key; the same key
## moves or resizes it. At most ZONE_POOL are drawn.
func press_zone(id: Variant, at: Vector2, radius: float) -> void:
	_zones[id] = Vector3(at.x, at.y, radius)

func release_zone(id: Variant) -> void:
	_zones.erase(id)

# Full press out to 85% of the radius, falling to none at the radius.
func _make_zone_texture() -> Texture2D:
	var sz := 64
	var img := Image.create(sz, sz, false, Image.FORMAT_RGBA8)
	var c := float(sz) * 0.5
	for y in sz:
		for x in sz:
			var dn := Vector2(float(x) + 0.5 - c, float(y) + 0.5 - c).length() / c
			var v := 1.0 - smoothstep(0.85, 1.0, dn)
			img.set_pixel(x, y, Color(1.0, 1.0, 1.0, v))
	return ImageTexture.create_from_image(img)

# Soft round blob: red falls off from the centre.
func _make_stamp_texture() -> Texture2D:
	var sz := 64
	var img := Image.create(sz, sz, false, Image.FORMAT_RGBA8)
	var c := float(sz) * 0.5
	for y in sz:
		for x in sz:
			var dn := Vector2(float(x) - c, float(y) - c).length() / c
			var v := clampf(1.0 - dn, 0.0, 1.0)
			v = v * v                                       # softer edge
			img.set_pixel(x, y, Color(v, v, v, v))
	return ImageTexture.create_from_image(img)

func _process(delta: float) -> void:
	var _pf := Perf.now()          # profiler mark (perf.gd)
	_tick_grass(delta)
	Perf.mark("grass", _pf)

func _tick_grass(delta: float) -> void:
	if not _initialized:
		return
	_time += delta

	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	var center := Vector2(cam.global_position.x, cam.global_position.z)
	var has_map := map_node.has_method("terrain_height_at")
	var half := window_size * 0.5

	# THE LIST IS THE WINDOW, NOT THE WORLD. Every machine block and every loose item on the map
	# is a bender, and each one cost a height query and two metas per frame even when it lay a
	# kilometre away: measured 133 benders, 11 of them inside the window, 1.5 ms of a 1.76 ms tick.
	# So the refresh (twice a second) keeps only what stands within the window plus the distance
	# anything can cover before the next refresh.
	_refresh_t += delta
	if _refresh_t >= BENDER_REFRESH:
		_refresh_t = 0.0
		var reach: float = half + BENDER_MARGIN
		_benders.clear()
		for t in get_tree().get_nodes_in_group("grass_benders"):
			var tp: Vector3 = (t as Node3D).global_position
			if absf(tp.x - center.x) <= reach and absf(tp.z - center.y) <= reach:
				_benders.append(t)

	# 1. Per ground-touching bender: it's "live" this frame (stays fully pressed while
	#    present — fixes grass springing back under a STATIONARY object), and it drops a
	#    fading footprint when it has moved enough (the lingering trail behind it).
	var live: Array[Vector2] = []
	for b in _benders:
		if not is_instance_valid(b) or not b.is_inside_tree():
			continue                       # dead or out of the tree (a block in the hand put away)
		var bp: Vector3 = b.global_position
		var p := Vector2(bp.x, bp.z)
		if absf(p.x - center.x) > half or absf(p.y - center.y) > half:
			continue                       # outside the window: nothing to press, ask no height
		if has_map and bp.y - map_node.terrain_height_at(bp) > ground_touch_height:
			continue
		live.append(p)
		var last: Vector2 = b.get_meta("_last_print", Vector2(INF, INF))
		if last.distance_squared_to(p) >= footprint_spacing * footprint_spacing:
			b.set_meta("_last_print", p)
			_footprints.append({"pos": p, "born": _time})

	# 2. Expire old footprints (front is oldest).
	while not _footprints.is_empty() and _time - _footprints[0]["born"] > flatten_lifetime:
		_footprints.pop_front()
	while _footprints.size() > max_footprints:
		_footprints.pop_front()

	# 3. Draw into the player-centred window: LIVE stamps first (full press, never fades),
	#    then the fading TRAIL (newest first, so if the pool runs out the oldest drop).
	var ppu  := float(VP_SIZE) / window_size               # pixels per world unit
	var sprite_scale := (stamp_radius * 2.0 * ppu) / float(_stamp_tex.get_width())
	var i := 0
	for p in live:
		if i >= _sprite_pool.size():
			break
		var rel := p - center
		if absf(rel.x) > half or absf(rel.y) > half:
			continue
		i = _place_stamp(i, rel, half, ppu, sprite_scale, 1.0)
	for fi in range(_footprints.size() - 1, -1, -1):
		if i >= _sprite_pool.size():
			break
		var rel2: Vector2 = _footprints[fi]["pos"] - center
		if absf(rel2.x) > half or absf(rel2.y) > half:
			continue
		var fade := clampf(1.0 - (_time - _footprints[fi]["born"]) / flatten_lifetime, 0.0, 1.0)
		i = _place_stamp(i, rel2, half, ppu, sprite_scale, fade)
	while i < _sprite_pool.size():
		_sprite_pool[i].visible = false
		i += 1
	var zi := 0
	for zid in _zones:
		var zv: Vector3 = _zones[zid]
		var zrel := Vector2(zv.x, zv.y) - center
		if zi >= _zone_pool.size() or absf(zrel.x) > half + zv.z or absf(zrel.y) > half + zv.z:
			continue
		var zs := _zone_pool[zi]
		zs.visible = true
		zs.position = Vector2((zrel.x + half) * ppu, (zrel.y + half) * ppu)
		var zscale: float = zv.z * 2.0 * ppu / float(zs.texture.get_width())
		zs.scale = Vector2(zscale, zscale)
		zi += 1
	while zi < _zone_pool.size():
		_zone_pool[zi].visible = false
		zi += 1

	# 4. Feed the flatten texture + window to the grass material.
	map_node.set_grass_trample(_vp.get_texture(), center, window_size)

# Positions sprite at pool index `i` at world-relative `rel` with strength `fade`. Returns i+1.
func _place_stamp(i: int, rel: Vector2, half: float, ppu: float, sprite_scale: float, fade: float) -> int:
	var s := _sprite_pool[i]
	s.visible = true
	s.position = Vector2((rel.x + half) * ppu, (rel.y + half) * ppu)
	s.scale = Vector2(sprite_scale, sprite_scale)
	s.modulate = Color(fade, fade, fade, fade)
	return i + 1

# Дождаться, пока карта сможет принимать карту примятия травы.
func _await_map() -> bool:
	var guard: int = 0
	while guard < MAP_WAIT_FRAMES:
		if map_node != null and map_node.has_method("set_grass_trample"):
			return true
		await get_tree().process_frame
		guard += 1
	return false
