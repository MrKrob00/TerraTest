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

## КОРРУПТАЦИЯ (лор цифровой симуляции): карта состояния «битых чанков» для шейдера террейна.
## Изначально пусто; редко +1 чанк; вблизи игрока чанк ЛЕЧИТСЯ НАВСЕГДА (иммунен к спреду).
@export_group("Корруптация")
@export var corr_spread_interval: float = 120.0     # раз в пару минут +1 чанк
@export var corr_heal_dist: float = 240.0           # радиус лечения (3× прежних 80), НАВСЕГДА
@export var corr_map_size: float = 1984.0           # мировой размер карты (единиц)

const VP_SIZE: int = 512
const CORR_GRID: int = 64                           # текстура состояния (клеток на сторону)

var _initialized: bool = false
var _benders: Array = []
var _vp: SubViewport
var _sprite_pool: Array[Sprite2D] = []
var _stamp_tex: Texture2D
var _footprints: Array = []          # [{pos: Vector2 (world xz), born: float}]
var _time: float = 0.0
var _refresh_t: float = 0.0

var _corr: PackedByteArray           # 255 = чанк битый, 0 = чистый (это и есть данные R8-текстуры)
var _corr_healed: PackedByteArray    # 1 = вылечен навсегда (иммунен к спреду)
var _corr_img: Image
var _corr_tex: ImageTexture
var _corr_center: Vector2 = Vector2.ZERO
var _corr_spread_t: float = 0.0
var _corr_heal_t: float = 0.0
var _corr_dirty: bool = false

func _ready() -> void:
	await get_tree().process_frame
	if not map_node or not map_node.has_method("set_grass_trample"):
		push_error("GrassSystem: map_node не поддерживает set_grass_trample()")
		return
	_benders = get_tree().get_nodes_in_group("grass_benders")
	_build_viewport()
	_corr_init()
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
	if not _initialized:
		return
	_time += delta
	_corruption_tick(delta)

	# Refresh the bender list periodically so newly-spawned objects are picked up.
	_refresh_t += delta
	if _refresh_t >= 0.5:
		_refresh_t = 0.0
		_benders = get_tree().get_nodes_in_group("grass_benders")
	_benders = _benders.filter(func(t): return is_instance_valid(t))

	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	var center := Vector2(cam.global_position.x, cam.global_position.z)
	var has_map := map_node.has_method("terrain_height_at")

	# 1. Per ground-touching bender: it's "live" this frame (stays fully pressed while
	#    present — fixes grass springing back under a STATIONARY object), and it drops a
	#    fading footprint when it has moved enough (the lingering trail behind it).
	var live: Array[Vector2] = []
	for b in _benders:
		var bp: Vector3 = b.global_position
		if has_map and bp.y - map_node.terrain_height_at(bp) > ground_touch_height:
			continue
		var p := Vector2(bp.x, bp.z)
		live.append(p)
		var last = b.get_meta("_last_print", Vector2(INF, INF))
		if last.distance_to(p) >= footprint_spacing:
			b.set_meta("_last_print", p)
			_footprints.append({"pos": p, "born": _time})

	# 2. Expire old footprints (front is oldest).
	while not _footprints.is_empty() and _time - _footprints[0]["born"] > flatten_lifetime:
		_footprints.pop_front()
	while _footprints.size() > max_footprints:
		_footprints.pop_front()

	# 3. Draw into the player-centred window: LIVE stamps first (full press, never fades),
	#    then the fading TRAIL (newest first, so if the pool runs out the oldest drop).
	var half := window_size * 0.5
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

# ══ КОРРУПТАЦИЯ: состояние «битых чанков» → текстура для шейдера террейна ══════════
# Изначально пусто. Раз в corr_spread_interval добавляем +1 чанк (растёт от края уже битых).
# Вблизи игрока (corr_heal_dist) чанки лечатся НАВСЕГДА (иммунны к дальнейшему спреду).
func _corr_init() -> void:
	var n := CORR_GRID * CORR_GRID
	_corr = PackedByteArray(); _corr.resize(n); _corr.fill(0)
	_corr_healed = PackedByteArray(); _corr_healed.resize(n); _corr_healed.fill(0)
	_corr_img = Image.create(CORR_GRID, CORR_GRID, false, Image.FORMAT_R8)
	_corr_img.fill(Color(0, 0, 0))
	_corr_tex = ImageTexture.create_from_image(_corr_img)
	if map_node is Node3D:
		_corr_center = Vector2((map_node as Node3D).global_position.x, (map_node as Node3D).global_position.z)
	if map_node and map_node.has_method("get_dims"):
		var d = map_node.get_dims()
		if d.x > 0:
			corr_map_size = float(d.x)
	_corr_spread_t = corr_spread_interval
	if map_node.has_method("set_corruption_map"):
		map_node.set_corruption_map(_corr_tex, _corr_center, corr_map_size)

func _corruption_tick(delta: float) -> void:
	_corr_spread_t -= delta
	if _corr_spread_t <= 0.0:
		_corr_spread_t = corr_spread_interval
		_corr_spread_one()
	_corr_heal_t -= delta
	if _corr_heal_t <= 0.0:
		_corr_heal_t = 0.5
		_corr_heal_near()
	if _corr_dirty:
		_corr_dirty = false
		_corr_img.set_data(CORR_GRID, CORR_GRID, false, Image.FORMAT_R8, _corr)
		_corr_tex.update(_corr_img)

# +1 битый чанк: если корруптации ещё нет — случайный сид; иначе клетка у края существующей.
func _corr_spread_one() -> void:
	var has_any := false
	for v in _corr:
		if v != 0:
			has_any = true
			break
	if not has_any:
		var tries := 0
		while tries < 40:
			tries += 1
			var i := randi() % _corr.size()
			if _corr_healed[i] == 0:
				_corr[i] = 255
				_corr_dirty = true
				return
		return
	var cands: Array = []
	for y in CORR_GRID:
		for x in CORR_GRID:
			var i := y * CORR_GRID + x
			if _corr[i] != 0 or _corr_healed[i] != 0:
				continue
			for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
				var nx :int= x + d.x
				var ny :int= y + d.y
				if nx >= 0 and nx < CORR_GRID and ny >= 0 and ny < CORR_GRID and _corr[ny * CORR_GRID + nx] != 0:
					cands.append(i)
					break
	if cands.is_empty():
		return
	_corr[cands[randi() % cands.size()]] = 255
	_corr_dirty = true

# Лечим чанки в радиусе corr_heal_dist вокруг игрока — НАВСЕГДА (помечаем healed).
func _corr_heal_near() -> void:
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	var p := Vector2(cam.global_position.x, cam.global_position.z)
	var cell_w := corr_map_size / float(CORR_GRID)
	var rad := int(ceil(corr_heal_dist / cell_w)) + 1
	var pcx := int(((p.x - _corr_center.x) / corr_map_size + 0.5) * float(CORR_GRID))
	var pcy := int(((p.y - _corr_center.y) / corr_map_size + 0.5) * float(CORR_GRID))
	var d2 := corr_heal_dist * corr_heal_dist
	for dy in range(-rad, rad + 1):
		for dx in range(-rad, rad + 1):
			var x := pcx + dx
			var y := pcy + dy
			if x < 0 or x >= CORR_GRID or y < 0 or y >= CORR_GRID:
				continue
			var i := y * CORR_GRID + x
			if _corr_healed[i] != 0 and _corr[i] == 0:
				continue
			var wx := _corr_center.x + ((float(x) + 0.5) / float(CORR_GRID) - 0.5) * corr_map_size
			var wz := _corr_center.y + ((float(y) + 0.5) / float(CORR_GRID) - 0.5) * corr_map_size
			if Vector2(wx, wz).distance_squared_to(p) <= d2:
				_corr[i] = 0
				_corr_healed[i] = 1
				_corr_dirty = true
