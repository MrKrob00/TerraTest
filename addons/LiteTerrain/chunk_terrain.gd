## ПРОЦЕДУРНЫЙ РЕЛЬЕФ, ХРАНИМЫЙ И РИСУЕМЫЙ ЧАНКАМИ.
##
## Чем отличается от map.gd: нет окна и нет массива высот на весь мир. Чанк спрашивает у
## генератора свои вершины сам, и это единственное место, откуда берётся земля. Поэтому у мира
## нет края, память равна тому, что на экране, а чанк вдалеке не стоит ничего.
##
## LOD — ЭТО СЛИЯНИЕ ЧАНКОВ. Узел уровня L накрывает 2^L × 2^L базовых чанков и рисуется ТЕМИ ЖЕ
## 16×16 квадами с шагом 2^L: четыре чанка становятся одним, полигонов вчетверо меньше, силуэт
## тот же. Ничего не прореживается и никакой меш не упрощается.
##
## ШОВ МЕЖДУ УРОВНЯМИ ЗАКРЫВАЕТСЯ ПРИТЯГИВАНИЕМ, не юбкой (юбок тут нет нигде). Мелкий сосед
## знает уровень крупного и кладёт лишние вершины своего края на отрезок между общими — а общие
## совпадают точно, потому что обе стороны берут высоту в одной и той же мировой точке.
##
## Отсечение по камере считается НА КАЖДЫЙ УЗЕЛ и во время спуска по дереву: узел, не попавший в
## кадр, не рисуется и не раскрывается — вместе с ним отсекается вся его четверть.
@tool
class_name ChunkTerrain
extends StaticBody3D

# ── Что рисуем ───────────────────────────────────────────────────────────────
const CHUNK := 16                 ## клеток в стороне базового чанка
const VERTS := CHUNK + 1          ## вершин в стороне любого узла, на любом уровне
const APRON := VERTS + 2          ## та же сетка с каймой в одну клетку — она нужна нормалям
const MAX_LOD := 5                ## верхний уровень: 16 × 32 = 512 м на узел
## Раскрываем узел, пока расстояние до него меньше его размера, умноженного на это. Двойка —
## не вкусовое число: при ней соседние листья не могут разойтись больше чем на уровень, и
## притягивать край нужно только к вдвое более крупному соседу.
const LOD_QUALITY := 2.0

@export var camera: Camera3D
@export var surface_material: Material = preload("res://addons/LiteTerrain/terrain_shader.res")
@export var biomes: TerrainBiomes = null : set = _set_biomes

@export_group("Visibility")
@export var view_distance: float = 1400.0
@export var enable_frustum_culling: bool = true
@export_range(-0.5, 0.5, 0.01) var frustum_margin: float = -0.05
## Заслонённость рельефом для того, что на нём стоит. По умолчанию выключена, как и была: луч
## по земле стоит дороже, чем рисование куста, который всё равно за бугром.
@export var enable_occlusion_culling: bool = false
@export_range(0.0, 200.0, 1.0) var occlusion_min_dist: float = 40.0
@export_range(0.0, 10.0, 0.5) var occlusion_bias: float = 1.5

@export_group("Build")
## Сколько узлов собираем за один заход пула потоков. Заход один — второй писал бы в те же слоты.
@export_range(1, 64, 1) var build_batch: int = 12
## Пересборок из-за смены соседа за тик. Шов на кадр-другой дешевле просадки.
@export_range(1, 32, 1) var stitch_budget: int = 6
@export var lod_interval: float = 0.15

@export_group("Collision")
@export var enable_streaming_collision: bool = true
## Клеток вокруг тела, которым даём землю.
@export_range(4, 256, 4) var collision_radius: int = 10

@export_group("Procedural")
@export var world_seed: int = 0
## Номинальный размер мира для тех, кто спрашивает get_dims (раскладка магазинов, жил и точек).
## У самой земли края нет; это лишь квадрат, в котором игра расставляет своё.
@export var world_cells: int = 2048
@export_group("")

@export var follow_world_settings: bool = true
@export var force_procedural: bool = true
@export var forced_seed: int = 0

signal terrain_ready
var terrain_is_ready: bool = false
## Экран загрузки читает эти два: что считается и какая доля пройдена.
var gen_step: String = ""
var gen_frac: float = 0.0
## Сток замеров времени, `func(key: String, usec_start: int)`. Пустой — замеров нет.
var perf_sink: Callable = Callable()

func _pf_now() -> int:
	return Time.get_ticks_usec() if not perf_sink.is_null() else 0

func _pf_mark(key: String, t0: int) -> void:
	if t0 != 0:
		perf_sink.call(key, t0)

var _gen: LiteTerrainGen = null
var _mat_lod0: Material = null
var _mat_far: Material = null
var _cam: Camera3D = null
var _y_lo: float = -60.0
var _y_hi: float = 240.0

## key → {inst, sig, lod, gx, gz}. Живой узел — тот, чей меш сейчас в дереве.
var _live: Dictionary = {}
## key → true. Чего хочет камера в этот тик; из него же берётся уровень соседа.
var _want: Dictionary = {}
## key → PackedFloat32Array(APRON²). Высоты узла. Их же берёт коллизия у уровня 0.
var _hc: Dictionary = {}
const HC_CAP := 768

var _jobs: Array = []          # очередь заданий (меш или тайл коллизии)
var _batch: Array = []         # то, что считает пул прямо сейчас
var _out: Array = []           # результаты пула, по одному на задание
var _group: int = -1
var _busy: bool = false
var _lod_timer: float = 0.0
var _queued: Dictionary = {}   # key → true, чтобы не заводить второе задание на тот же узел

func _ready() -> void:
	# В РЕДАКТОРЕ НОДА НЕ ТРОГАЕТ НИЧЕГО САМА. Скрипт @tool ради превью (см. preview_build), а
	# всякая правка свойств отсюда пометила бы сцену изменённой и однажды сохранилась.
	if Engine.is_editor_hint():
		return
	collision_layer = 1
	collision_mask = 0
	await get_tree().process_frame
	var game: Node = get_node_or_null("/root/G") if follow_world_settings else null
	var seed_value: int = forced_seed
	if game != null and game.get("world_seed") != null:
		seed_value = int(game.get("world_seed"))
	await setup_procedural(seed_value)
	set_collision_streaming(true)
	print("ChunkTerrain: сид %d, чанк %d, уровней %d, кольцо %d×%d за %d мс, узлов %d"
			% [seed_value, CHUNK, MAX_LOD + 1, READY_RING * 2 + 1, READY_RING * 2 + 1,
				_ready_ms, _live.size()])

func _set_biomes(v: TerrainBiomes) -> void:
	biomes = v
	_push_biomes()

func _biomes() -> TerrainBiomes:
	if biomes == null:
		biomes = TerrainBiomes.new()
	return biomes

# ─────────────────────────────────────────────────────────────────────────────
# Генератор
# ─────────────────────────────────────────────────────────────────────────────

## ЗЕМЛЯ СТРОИТСЯ ПО НАТУРАЛЬНОМУ ПРЕСЕТУ — по тем же числам, что и карта из дока и фон меню.
## Своих ползунков тут нет намеренно: вторая копия этих чисел это другой ландшафт в том же мире.
func _proc_params() -> Dictionary:
	return LiteTerrainGen.natural_params(_biomes())

## Мир поднимается ЗДЕСЬ И СРАЗУ: считать заранее нечего, первый чанк родится к первому кадру.
## around — где стоит игрок; вокруг неё и строим первое кольцо.
func setup_procedural(seed_value: int, around: Vector3 = Vector3.ZERO) -> void:
	world_seed = seed_value
	var gen := LiteTerrainGen.new()
	add_child(gen)
	gen.gen_seed = seed_value
	gen.apply_params(_proc_params())
	gen.begin_sampling(_biomes())
	_gen = gen
	_y_lo = -world_height() * 0.5
	_y_hi = world_height() * 1.8
	_setup_materials(_get_material())
	_cam = _active_camera()
	# ПЕРВОЕ КОЛЬЦО СТРОИМ ДО ГОТОВНОСТИ, а не по кадру-другому: игрок падает в мир сразу после
	# terrain_ready, и земли под ним к этому моменту обязана быть не «скоро», а уже.
	var in_game := not Engine.is_editor_hint()
	await _build_around(around, in_game)
	if in_game:
		set_collision_streaming(true)
	terrain_is_ready = true
	terrain_ready.emit()

## Ждём ЗЕМЛЮ ПОД ИГРОКОМ — квадрат чанков уровня 0 вокруг точки и их тайлы коллизии, — и
## больше ничего. Остальное кольцо к этому моменту уже в очереди (его просит _process), но ждать
## его под экраном загрузки незачем: оно доедет за спиной у затемнения. Пока условием выхода была
## пустая очередь, загрузка держалась до последнего узла на всю дальность видимости.
const READY_RING := 2        # чанков в каждую сторону: 5×5 по 16 м = 80 м вокруг точки старта

## Сколько заняло первое кольцо, мс. Печатается при входе в мир: «быстро или медленно» — это не
## отчёт, а число — отчёт.
var _ready_ms: int = 0

func _build_around(around: Vector3, with_collision: bool = true) -> void:
	var t0 := Time.get_ticks_msec()
	gen_step = "world"
	gen_frac = 0.0
	var bx := int(floor(around.x / CHUNK))
	var bz := int(floor(around.z / CHUNK))
	var need: Array[int] = []
	for dz in range(-READY_RING, READY_RING + 1):
		for dx in range(-READY_RING, READY_RING + 1):
			var key := _key(0, bx + dx, bz + dz)
			# В _want тоже: готовый меш показывается только там, где его просит кадр, а первого
			# спуска по дереву ещё не было.
			_want[key] = true
			need.append(key)
			_enqueue_mesh(0, bx + dx, bz + dz, 0)
			if with_collision:
				_enqueue_coll(bx + dx, bz + dz)
	var guard := 0
	while guard < 600:
		_job_tick()
		var done := 0
		for k in need:
			if _live.has(k) and (_col.has(k) or not with_collision):
				done += 1
		gen_frac = float(done) / float(need.size())
		if done >= need.size():
			break
		await get_tree().process_frame
		guard += 1
	_ready_ms = Time.get_ticks_msec() - t0
	gen_step = ""
	gen_frac = 0.0

## СНЯТЬ КАРТУ СО СЧЁТА. Зовёт тот, кто собирается её освободить: задания пула пишут в массивы,
## живущие в этой ноде, и без остановки допишут в уничтоженные.
func stop_generation() -> void:
	if _group != -1:
		WorkerThreadPool.wait_for_group_task_completion(_group)
		_group = -1
	_busy = false
	_jobs.clear()
	_pending_dirty.clear()
	_batch.clear()
	_out.clear()
	_queued.clear()
	if _gen != null and is_instance_valid(_gen):
		_gen.stop()
		_gen.queue_free()        # иначе каждое превью оставляет в ноде ещё один генератор
	_gen = null

func _exit_tree() -> void:
	stop_generation()

# ─────────────────────────────────────────────────────────────────────────────
# Высоты
# ─────────────────────────────────────────────────────────────────────────────

func world_height() -> float:
	return _gen.gen_amplitude if _gen != null else LiteTerrainGen.NAT_AMPLITUDE

func get_dims() -> Vector2i:
	return Vector2i(world_cells, world_cells) if terrain_is_ready else Vector2i.ZERO

## ЗЕМЛЯ В МИРОВОЙ ТОЧКЕ: генератор плюс правки. Единственная дверь — и меш, и коллизия, и
## запрос высоты снаружи идут через неё, иначе площадка была бы ровной только на вид.
func _ground_at(wx: float, wz: float, edits: Array) -> float:
	return _edit_h(_gen.height_at(wx, wz), wx, wz, edits)

## Запомненная высота в УЗЛЕ СЕТКИ. Спрашивают её десятки раз за кадр и почти всегда рядом с
## тем же местом, а один расчёт — это пять выборок шума и три маски биома.
var _memo: Dictionary = {}
const MEMO_CAP := 1 << 16

func _memo_h(cx: int, cz: int) -> float:
	var k: int = ((cx & 0x3FFFFFF) << 26) | (cz & 0x3FFFFFF)
	var v = _memo.get(k)
	if v != null:
		return v
	if _memo.size() > MEMO_CAP:
		_memo.clear()
	var h: float = _ground_at(float(cx), float(cz), _flat_edits)
	_memo[k] = h
	return h

## Высота под мировой точкой. Билинейно по четырём узлам клетки — ровно так же, как её описывает
## меш и режет коллизия, поэтому колесо и картинка не расходятся.
func terrain_height_at(world_pos: Vector3) -> float:
	if _gen == null:
		return 0.0
	var p: Vector3 = global_transform.affine_inverse() * world_pos
	var x0 := int(floor(p.x))
	var z0 := int(floor(p.z))
	var tx: float = p.x - float(x0)
	var tz: float = p.z - float(z0)
	var h00 := _memo_h(x0, z0)
	var h10 := _memo_h(x0 + 1, z0)
	var h01 := _memo_h(x0, z0 + 1)
	var h11 := _memo_h(x0 + 1, z0 + 1)
	var h: float = lerpf(lerpf(h00, h10, tx), lerpf(h01, h11, tx), tz)
	return (global_transform * Vector3(p.x, h, p.z)).y

# ─────────────────────────────────────────────────────────────────────────────
# Правки рельефа
# ─────────────────────────────────────────────────────────────────────────────
## Правка — семь чисел, и от неё земля воспроизводится точно. В мире без края это единственная
## память о том, что игрок здесь строил.
const FLAT_EDITS_MAX := 1024
var _flat_edits: Array = []
var _edit_seq: int = 0

## Правка в одной точке. edits приходит списком, а не читается полем: список отдают потокам, и
## заменить его под ними на другой нельзя (см. flatten_area — там копия, а не append на месте).
func _edit_h(h: float, wx: float, wz: float, edits: Array) -> float:
	for e in edits:
		var cx: float = e["cx"]
		var cz: float = e["cz"]
		var fe: float = e["fe"]
		var dx: float = maxf(absf(wx - cx) - e["ex"], 0.0)
		var dz: float = maxf(absf(wz - cz) - e["ez"], 0.0)
		if dx >= fe or dz >= fe:
			continue
		var dist: float = sqrt(dx * dx + dz * dz)
		if dist >= fe:
			continue
		h = lerpf(h, e["y"], clampf(1.0 - dist / fe, 0.0, 1.0))
	return h

## Прямоугольник правки в мировых клетках, с запасом на спад.
func _edit_rect(e: Dictionary) -> Rect2:
	var r: float = e["fe"]
	return Rect2(e["cx"] - e["ex"] - r, e["cz"] - e["ez"] - r,
			(e["ex"] + r) * 2.0, (e["ez"] + r) * 2.0)

func _edits_in(x0: float, z0: float, size: float) -> Array:
	if _flat_edits.is_empty():
		return _flat_edits
	var box := Rect2(x0, z0, size, size)
	var out: Array = []
	for e in _flat_edits:
		if _edit_rect(e).intersects(box):
			out.append(e)
	return out

func flatten_area(center_world: Vector3, half_extent: Vector2, height: float,
		feather: float = 4.0, record: bool = true) -> void:
	if _gen == null:
		return
	var inv := global_transform.affine_inverse()
	var local: Vector3 = inv * center_world
	var target: float = (inv * Vector3(center_world.x, height, center_world.z)).y
	var e := {
		"cx": local.x, "cz": local.z,
		"ex": maxf(half_extent.x, 0.0), "ez": maxf(half_extent.y, 0.0),
		"fe": maxf(feather, 0.001), "y": target,
		"n": (_edit_seq + 1) if record else 0,
	}
	if record:
		_edit_seq += 1
	# КОПИЯ, А НЕ append НА МЕСТЕ: ссылку на старый список держат задания, которые уже считает
	# пул. Дописать в него значит менять массив под чужим потоком.
	var list := _flat_edits.duplicate()
	list.append(e)
	if list.size() > FLAT_EDITS_MAX:
		list.remove_at(0)
	_flat_edits = list
	_invalidate(_edit_rect(e))

## Правки наружу и обратно (мировое сохранение). Формат тот же, что был у map.gd.
func ground_edits() -> Array:
	var out: Array = []
	for e in _flat_edits:
		out.append({"c": [e["cx"], e["y"], e["cz"]], "h": [e["ex"], e["ez"]],
				"y": e["y"], "f": e["fe"], "n": e["n"]})
	return out

func apply_ground_edits(list: Array) -> void:
	if list.is_empty() or _gen == null:
		return
	var dirty := Rect2()
	var first := true
	var acc := _flat_edits.duplicate()
	for raw in list:
		if not (raw is Dictionary) or not (raw.get("c") is Array) or not (raw.get("h") is Array):
			continue
		var c: Array = raw["c"]
		var hh: Array = raw["h"]
		if c.size() < 3 or hh.size() < 2:
			continue
		var e := {
			"cx": float(c[0]), "cz": float(c[2]),
			"ex": float(hh[0]), "ez": float(hh[1]),
			"fe": maxf(float(raw.get("f", 4.0)), 0.001), "y": float(raw.get("y", 0.0)),
			"n": int(raw.get("n", 0)),
		}
		acc.append(e)
		_edit_seq = maxi(_edit_seq, e["n"])
		var r := _edit_rect(e)
		dirty = r if first else dirty.merge(r)
		first = false
	if first:
		return
	if acc.size() > FLAT_EDITS_MAX:
		acc = acc.slice(acc.size() - FLAT_EDITS_MAX)
	_flat_edits = acc
	_invalidate(dirty)

## Земля в прямоугольнике изменилась: забыть её высоты, пересобрать меши и срезать тайлы заново.
##
## Пока идёт заход пула — ОТКЛАДЫВАЕМ. Задания читают _hc, и стереть из него запись под чужим
## потоком значит уронить игру ровно в тот момент, когда игрок ставит базу.
var _pending_dirty: Array = []

func _invalidate(area: Rect2) -> void:
	if _busy:
		_pending_dirty.append(area)
		return
	_memo.clear()
	for key in _hc.keys():
		if _node_rect(key).intersects(area):
			_hc.erase(key)
	for key in _live.keys():
		if _node_rect(key).intersects(area):
			var n: Dictionary = _live[key]
			_enqueue_mesh(n["lod"], n["gx"], n["gz"], n["sig"])
	for key in _col.keys():
		var r := _node_rect(key)
		if r.intersects(area):
			var cs = _col[key]
			if is_instance_valid(cs):
				cs.queue_free()
			_col.erase(key)
			_col_seen.erase(key)

func reset_heights() -> void:
	_drain()                      # _hc читают задания пула; чистить его под ними нельзя
	_flat_edits = []
	_edit_seq = 0
	_memo.clear()
	_hc.clear()
	for key in _live.keys():
		var n: Dictionary = _live[key]
		if is_instance_valid(n["inst"]):
			n["inst"].queue_free()
	_live.clear()
	_clear_collision()

## Запекать в чанковом мире нечего: земля и так считается из сида, а правки лежат в сохранении.
func bake_heights() -> bool:
	return false

func update() -> void:
	_lod_timer = lod_interval

# ─────────────────────────────────────────────────────────────────────────────
# Ключи узлов и выбор уровня
# ─────────────────────────────────────────────────────────────────────────────

func _key(lod: int, gx: int, gz: int) -> int:
	return (lod << 40) | ((gx & 0xFFFFF) << 20) | (gz & 0xFFFFF)

func _key_lod(k: int) -> int:
	return (k >> 40) & 0x7

func _key_gx(k: int) -> int:
	var v: int = (k >> 20) & 0xFFFFF
	return v - 0x100000 if v >= 0x80000 else v

func _key_gz(k: int) -> int:
	var v: int = k & 0xFFFFF
	return v - 0x100000 if v >= 0x80000 else v

func _node_rect(k: int) -> Rect2:
	var span: float = float(CHUNK << _key_lod(k))
	return Rect2(_key_gx(k) * span, _key_gz(k) * span, span, span)

func _node_aabb(lod: int, gx: int, gz: int) -> AABB:
	var span := float(CHUNK << lod)
	return AABB(Vector3(gx * span, _y_lo, gz * span), Vector3(span, _y_hi - _y_lo, span))

## УРОВЕНЬ, НА КОТОРОМ СЕЙЧАС РИСУЕТСЯ БАЗОВЫЙ ЧАНК. Спрашиваем лист, накрывающий его: своих
## координат у листа на каждом уровне ровно одни, так что это шесть проверок словаря, а не обход
## дерева. Отсюда мелкий узел узнаёт, к какому краю притягиваться.
func _level_of(bcx: int, bcz: int) -> int:
	for l in MAX_LOD + 1:
		if _want.has(_key(l, bcx >> l, bcz >> l)):
			return l
	return -1

func _side_k(lod: int, gx: int, gz: int, dx: int, dz: int) -> int:
	var n: int = 1 << lod
	var bx: int = gx * n
	var bz: int = gz * n
	var a: Vector2i
	var b: Vector2i
	if dx != 0:
		var px: int = bx - 1 if dx < 0 else bx + n
		a = Vector2i(px, bz)
		b = Vector2i(px, bz + n - 1)
	else:
		var pz: int = bz - 1 if dz < 0 else bz + n
		a = Vector2i(bx, pz)
		b = Vector2i(bx + n - 1, pz)
	var k := 0
	for p in [a, b]:
		var l := _level_of(p.x, p.y)
		if l > lod:
			k = maxi(k, l - lod)
	return mini(k, 4)

## Четыре соседа в одном числе: по четыре бита на сторону — насколько сосед КРУПНЕЕ.
func _signature(lod: int, gx: int, gz: int) -> int:
	return _side_k(lod, gx, gz, 0, -1) \
		| (_side_k(lod, gx, gz, 0, 1) << 4) \
		| (_side_k(lod, gx, gz, -1, 0) << 8) \
		| (_side_k(lod, gx, gz, 1, 0) << 12)

# ─────────────────────────────────────────────────────────────────────────────
# Спуск по дереву: что рисовать в этот тик
# ─────────────────────────────────────────────────────────────────────────────

func _select(cam_local: Vector3) -> void:
	_want.clear()
	var planes: Array[Plane] = []
	if enable_frustum_culling and is_instance_valid(_cam):
		var inv := global_transform.affine_inverse()
		for pl in _cam.get_frustum():
			planes.append(inv * pl)
	var top := CHUNK << MAX_LOD
	var r: int = int(ceil(view_distance / float(top)))
	var g0x: int = int(floor(cam_local.x / float(top)))
	var g0z: int = int(floor(cam_local.z / float(top)))
	for gz in range(g0z - r, g0z + r + 1):
		for gx in range(g0x - r, g0x + r + 1):
			_descend(MAX_LOD, gx, gz, cam_local, planes)

func _descend(lod: int, gx: int, gz: int, cam: Vector3, planes: Array[Plane]) -> void:
	var span := float(CHUNK << lod)
	var aabb := _node_aabb(lod, gx, gz)
	var d2 := _aabb_dist2(aabb, cam)
	if d2 > view_distance * view_distance:
		return
	# ОТСЕЧЕНИЕ ЗДЕСЬ, А НЕ НАД ЛИСТЬЯМИ: узел вне кадра уносит с собой всю свою четверть, и
	# внизу дерева проверять уже нечего. На верхнем уровне это разом снимает полмира за спиной.
	if not planes.is_empty() and not _aabb_in_frustum(aabb, planes, frustum_margin):
		return
	var split := span * LOD_QUALITY
	if lod > 0 and d2 < split * split:
		var cx := gx * 2
		var cz := gz * 2
		_descend(lod - 1, cx, cz, cam, planes)
		_descend(lod - 1, cx + 1, cz, cam, planes)
		_descend(lod - 1, cx, cz + 1, cam, planes)
		_descend(lod - 1, cx + 1, cz + 1, cam, planes)
		return
	_want[_key(lod, gx, gz)] = true

func _aabb_dist2(aabb: AABB, p: Vector3) -> float:
	var mx: Vector3 = aabb.position + aabb.size
	var dx: float = maxf(maxf(aabb.position.x - p.x, 0.0), p.x - mx.x)
	var dz: float = maxf(maxf(aabb.position.z - p.z, 0.0), p.z - mx.z)
	return dx * dx + dz * dz

func _aabb_in_frustum(aabb: AABB, planes: Array[Plane], margin: float) -> bool:
	var bmin: Vector3 = aabb.position
	var bmax: Vector3 = aabb.position + aabb.size
	for plane in planes:
		var nx: float = bmin.x if plane.normal.x >= 0.0 else bmax.x
		var ny: float = bmin.y if plane.normal.y >= 0.0 else bmax.y
		var nz: float = bmin.z if plane.normal.z >= 0.0 else bmax.z
		if plane.distance_to(Vector3(nx, ny, nz)) > margin:
			return false
	return true

# ─────────────────────────────────────────────────────────────────────────────
# Сборка: очередь → пул потоков → дерево
# ─────────────────────────────────────────────────────────────────────────────

const JOB_MESH := 0
const JOB_COLL := 1

func _enqueue_mesh(lod: int, gx: int, gz: int, sig: int) -> void:
	var key := _key(lod, gx, gz)
	if _queued.has(key):
		return
	_queued[key] = true
	var span := float(CHUNK << lod)
	_jobs.append({
		"kind": JOB_MESH, "key": key, "lod": lod, "gx": gx, "gz": gz, "sig": sig,
		"edits": _edits_in(gx * span, gz * span, span),
	})

func _enqueue_coll(bcx: int, bcz: int) -> void:
	var key := _key(0, bcx, bcz)
	if _col.has(key) or _queued.has(key | (1 << 50)):
		return
	_queued[key | (1 << 50)] = true
	_jobs.append({
		"kind": JOB_COLL, "key": key, "lod": 0, "gx": bcx, "gz": bcz, "sig": 0,
		"edits": _edits_in(bcx * float(CHUNK), bcz * float(CHUNK), float(CHUNK)),
	})

## ДОЖДАТЬСЯ ЗАХОДА ПУЛА И ПРИНЯТЬ ЕГО. Зовёт тот, кто собирается тронуть то, что задания читают
## (_hc, список правок). Блокирует кадр, поэтому только на редких событиях — сброс мира.
func _drain() -> void:
	if not _busy:
		return
	WorkerThreadPool.wait_for_group_task_completion(_group)
	_group = -1
	_busy = false
	_apply_batch()

## Один заход пула за раз: задания пишут в _out по своему номеру, а второй заход переписал бы
## и массив, и поля под первым.
func _job_tick() -> void:
	if _busy:
		if not WorkerThreadPool.is_group_task_completed(_group):
			return
		WorkerThreadPool.wait_for_group_task_completion(_group)
		_group = -1
		_busy = false
		_apply_batch()
		while not _pending_dirty.is_empty():
			_invalidate(_pending_dirty.pop_front())
	if _jobs.is_empty() or _gen == null:
		return
	_batch = _jobs.slice(0, build_batch)
	_jobs = _jobs.slice(_batch.size())
	_out.clear()
	_out.resize(_batch.size())
	_busy = true
	_group = WorkerThreadPool.add_group_task(_build_job, _batch.size(), -1, false, "ChunkTerrain")

## Задание пула. Читает только генератор (он после begin_sampling неизменен), свой список правок
## и свой слот в _out.
func _build_job(i: int) -> void:
	var job: Dictionary = _batch[i]
	var lod: int = job["lod"]
	var step := float(1 << lod)
	var x0 := float(job["gx"] * (CHUNK << lod))
	var z0 := float(job["gz"] * (CHUNK << lod))
	var h: PackedFloat32Array = _hc.get(job["key"], PackedFloat32Array())
	if h.size() != APRON * APRON:
		h = _gen.sample_grid(x0 - step, z0 - step, APRON, step)
		if not job["edits"].is_empty():
			for j in APRON:
				var wz := z0 + float(j - 1) * step
				for x in APRON:
					h[j * APRON + x] = _edit_h(h[j * APRON + x], x0 + float(x - 1) * step, wz,
							job["edits"])
	if job["kind"] == JOB_COLL:
		_out[i] = {"heights": h}
		return
	_out[i] = {"heights": h, "mesh": _mesh_arrays(h, step, job["sig"], x0, z0)}

## Задание пула, снаружи: сколько узлов ждёт сборки.
func pending_jobs() -> int:
	return _jobs.size() + (_batch.size() if _busy else 0)

func _apply_batch() -> void:
	for i in _batch.size():
		var job: Dictionary = _batch[i]
		var res = _out[i]
		if res == null:
			continue
		var key: int = job["key"]
		_hc[key] = res["heights"]
		if job["kind"] == JOB_COLL:
			_queued.erase(key | (1 << 50))
			_make_tile(key, job["gx"], job["gz"], res["heights"])
			continue
		_queued.erase(key)
		_place_mesh(key, job, res["mesh"])
	_batch.clear()
	_out.clear()
	_prune_heights()

func _place_mesh(key: int, job: Dictionary, arrays: Array) -> void:
	var old = _live.get(key)
	if old != null and is_instance_valid(old["inst"]):
		old["inst"].queue_free()
	if arrays.is_empty():
		_live.erase(key)
		return
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays[0])
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.position = Vector3(job["gx"] * (CHUNK << job["lod"]), 0.0, job["gz"] * (CHUNK << job["lod"]))
	mi.custom_aabb = arrays[1]
	mi.material_override = _mat_lod0 if job["lod"] == 0 else _mat_far
	# Тень от дальнего узла — это второй проход по тем же треугольникам ради контура, который на
	# таком расстоянии не виден. Ближние два уровня её отбрасывают, остальные нет.
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if job["lod"] <= 1 \
			else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# Успел уехать из кадра, пока считался, — всё равно кладём, только скрытым: он уже посчитан,
	# а камера ходит туда-сюда.
	mi.visible = _want.has(key)
	add_child(mi)
	_live[key] = {"inst": mi, "sig": job["sig"], "lod": job["lod"], "gx": job["gx"], "gz": job["gz"],
			"seen": float(Time.get_ticks_msec()) * 0.001}

## Высоты держим только у того, что рисуется или лежит под коллизией.
func _prune_heights() -> void:
	if _hc.size() <= HC_CAP:
		return
	for key in _hc.keys():
		if _hc.size() <= HC_CAP:
			return
		if not _live.has(key) and not _want.has(key) and not _col.has(key):
			_hc.erase(key)

# ─────────────────────────────────────────────────────────────────────────────
# Меш узла
# ─────────────────────────────────────────────────────────────────────────────

## Вершины, нормали, цвет биома и треугольники одного узла. h — сетка APRON² с каймой в одну
## клетку шага: кайма нужна нормалям, иначе по краю чанка была бы видна смена освещения.
func _mesh_arrays(h: PackedFloat32Array, step: float, sig: int, x0: float, z0: float) -> Array:
	if h.size() != APRON * APRON:
		return []
	var b := _biomes()
	var nz_cb: Callable = b.noise
	var vh := PackedFloat32Array()
	vh.resize(VERTS * VERTS)
	for j in VERTS:
		for i in VERTS:
			vh[j * VERTS + i] = h[(j + 1) * APRON + (i + 1)]
	# ПРИТЯГИВАНИЕ КРАЯ К КРУПНОМУ СОСЕДУ. Его вершины стоят через r наших, и лишние мы кладём
	# на прямую между ними — ту самую, которой сосед и рисует свой край. Угловые вершины кратны
	# любому r, так что два края в углу друг другу не мешают.
	var kn: int = sig & 0xF
	var ks: int = (sig >> 4) & 0xF
	var kw: int = (sig >> 8) & 0xF
	var ke: int = (sig >> 12) & 0xF
	if kn > 0:
		_snap_row(vh, 0, 1 << kn, true)
	if ks > 0:
		_snap_row(vh, VERTS - 1, 1 << ks, true)
	if kw > 0:
		_snap_row(vh, 0, 1 << kw, false)
	if ke > 0:
		_snap_row(vh, VERTS - 1, 1 << ke, false)

	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var cols := PackedColorArray()
	verts.resize(VERTS * VERTS)
	norms.resize(VERTS * VERTS)
	cols.resize(VERTS * VERTS)
	var y_lo := INF
	var y_hi := -INF
	for j in VERTS:
		var wz := z0 + float(j) * step
		for i in VERTS:
			var vi := j * VERTS + i
			var y: float = vh[vi]
			y_lo = minf(y_lo, y)
			y_hi = maxf(y_hi, y)
			verts[vi] = Vector3(float(i) * step, y, float(j) * step)
			# Нормаль по кайме, а не по краю сетки: соседний чанк считает ту же разность в той же
			# точке, поэтому шва в освещении нет.
			var a := (j + 1) * APRON + (i + 1)
			var hl: float = h[a - 1]
			var hr: float = h[a + 1]
			var hu: float = h[a - APRON]
			var hd: float = h[a + APRON]
			norms[vi] = Vector3(hl - hr, 2.0 * step, hu - hd).normalized()
			var wp := Vector2(x0 + float(i) * step, wz)
			# .r — трава (0 там, где вершину притянули: поднятая травинка снова раскрыла бы шов),
			# .g каньон, .b луг, .a горы. Цвет земли живёт в вершинах, шейдер их только читает.
			var seam := (j == 0 and kn > 0) or (j == VERTS - 1 and ks > 0) \
					or (i == 0 and kw > 0) or (i == VERTS - 1 and ke > 0)
			cols[vi] = Color(0.0 if seam else 1.0,
					b.canyon_mask(wp, nz_cb), b.meadow_mask(wp, nz_cb), b.mountain_mask(wp, nz_cb))

	var idx := PackedInt32Array()
	idx.resize(CHUNK * CHUNK * 6)
	var n := 0
	for j in CHUNK:
		for i in CHUNK:
			var i00 := j * VERTS + i
			var i10 := i00 + 1
			var i01 := i00 + VERTS
			var i11 := i01 + 1
			idx[n] = i00; idx[n + 1] = i10; idx[n + 2] = i11
			idx[n + 3] = i00; idx[n + 4] = i11; idx[n + 5] = i01
			n += 6

	var arr: Array = []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_NORMAL] = norms
	arr[Mesh.ARRAY_COLOR] = cols
	arr[Mesh.ARRAY_INDEX] = idx
	var span := float(CHUNK) * step
	return [arr, AABB(Vector3(0.0, y_lo, 0.0), Vector3(span, maxf(y_hi - y_lo, 0.01), span))]

## Одна сторона сетки на грубую решётку соседа. along_x — край идёт по x (север/юг).
func _snap_row(vh: PackedFloat32Array, line: int, r: int, along_x: bool) -> void:
	for i in VERTS:
		var rem := i % r
		if rem == 0:
			continue
		var i0 := i - rem
		var i1 := mini(i0 + r, VERTS - 1)
		var t := float(rem) / float(r)
		if along_x:
			vh[line * VERTS + i] = lerpf(vh[line * VERTS + i0], vh[line * VERTS + i1], t)
		else:
			vh[i * VERTS + line] = lerpf(vh[i0 * VERTS + line], vh[i1 * VERTS + line], t)

# ─────────────────────────────────────────────────────────────────────────────
# Коллизия: тайл = базовый чанк
# ─────────────────────────────────────────────────────────────────────────────
## Тайл режется ИЗ ТЕХ ЖЕ ВЫСОТ, что и меш уровня 0 (сетка APRON² с шагом 1) — поэтому под
## ближним чанком он достаётся бесплатно, а дальше стоит одну выборку. Кайма даёт соседям общую
## строку, так что дырок на стыке нет.
var _col: Dictionary = {}        # key → CollisionShape3D
var _col_seen: Dictionary = {}   # key → когда тайл был нужен в последний раз
var _col_bodies: Array = []
var _col_active: bool = false
const COL_TILE_GRACE := 3.0

func set_collision_streaming(on: bool) -> void:
	_col_active = on and enable_streaming_collision
	if not _col_active:
		_clear_collision()
	elif _col_bodies.is_empty():
		_setup_bodies()

func _setup_bodies() -> void:
	_col_bodies.clear()
	var tree := get_tree()
	if tree == null:
		return
	var root := tree.current_scene
	if root != null:
		for n in root.find_children("*", "PhysicsBody3D", true, false):
			_register_body(n)
	if not tree.node_added.is_connected(_on_node_added):
		tree.node_added.connect(_on_node_added)
		tree.node_removed.connect(_on_node_removed)

## Подвижное тело, которому нужна земля. StaticBody3D и Area3D сюда не попадают.
func _is_trackable(n: Node) -> bool:
	return n is RigidBody3D or n is CharacterBody3D

## Самое верхнее подвижное тело в цепочке родителей. Приваренная к машине часть своего окна не
## просит — её накрывает окно машины.
func _top_body(n: Node) -> Node:
	var top: Node = n
	var p := n.get_parent()
	while p != null:
		if _is_trackable(p):
			top = p
		p = p.get_parent()
	return top

func _on_node_added(n: Node) -> void:
	if _is_trackable(n):
		call_deferred("_register_body", n)   # родитель и позиция к этому моменту уже на месте

func _on_node_removed(n: Node) -> void:
	if _is_trackable(n):
		_col_bodies.erase(n)

func _register_body(n: Node) -> void:
	if not _col_active or not is_instance_valid(n) or not _is_trackable(n):
		return
	if is_ancestor_of(n) or _top_body(n) != n or _col_bodies.has(n):
		return
	_col_bodies.append(n)

func _clear_collision() -> void:
	for cs in _col.values():
		if is_instance_valid(cs):
			cs.queue_free()
	_col.clear()
	_col_seen.clear()

func _col_tick() -> void:
	if not _col_active or _gen == null:
		return
	var want := {}
	var r: int = collision_radius
	var dead := false
	var inv := global_transform.affine_inverse()
	for raw in _col_bodies:
		if raw == null or not is_instance_valid(raw):
			dead = true
			continue
		var body: Node3D = raw
		# Спящему телу земля не нужна: уснувший враг заморожен целиком, а лежащий блок не
		# двигается. Цикл идёт каждый кадр, так что окно вернётся в тот же кадр, как оно
		# проснётся. Замороженные (якорь, носимое) НЕ пропускаем — freeze это не покой.
		if body.get_meta("asleep", false):
			continue
		if body is RigidBody3D and (body as RigidBody3D).sleeping and not (body as RigidBody3D).freeze:
			continue
		var p: Vector3 = inv * body.global_position
		var bx0: int = int(floor((p.x - r) / CHUNK))
		var bx1: int = int(floor((p.x + r) / CHUNK))
		var bz0: int = int(floor((p.z - r) / CHUNK))
		var bz1: int = int(floor((p.z + r) / CHUNK))
		for bz in range(bz0, bz1 + 1):
			for bx in range(bx0, bx1 + 1):
				want[_key(0, bx, bz)] = Vector2i(bx, bz)
	var now: float = float(Time.get_ticks_msec()) * 0.001
	for key in want:
		_col_seen[key] = now
		if not _col.has(key):
			var g: Vector2i = want[key]
			_enqueue_coll(g.x, g.y)
	# Тайл живёт ещё несколько секунд после того, как перестал быть нужен: его создание —
	# это запекание поля высот физикой, и машина, едущая вдоль границы, иначе пересоздавала
	# бы одни и те же тайлы каждый кадр.
	for key in _col.keys():
		if want.has(key) or now - float(_col_seen.get(key, 0.0)) < COL_TILE_GRACE:
			continue
		if is_instance_valid(_col[key]):
			_col[key].queue_free()
		_col.erase(key)
		_col_seen.erase(key)
	if dead:
		var alive: Array = []
		for b in _col_bodies:
			if b != null and is_instance_valid(b):
				alive.append(b)
		_col_bodies = alive

func _make_tile(key: int, bcx: int, bcz: int, h: PackedFloat32Array) -> void:
	if _col.has(key) or h.size() != APRON * APRON:
		return
	var shape := HeightMapShape3D.new()
	shape.map_width = APRON
	shape.map_depth = APRON
	shape.map_data = h
	var cs := CollisionShape3D.new()
	cs.shape = shape
	# Сетка накрывает клетки [x0−1 … x0+CHUNK+1], её середина — x0 + CHUNK/2.
	cs.position = Vector3(bcx * CHUNK + CHUNK * 0.5, 0.0, bcz * CHUNK + CHUNK * 0.5)
	add_child(cs)
	_col[key] = cs

func collision_stats() -> Vector2i:
	return Vector2i(_col.size(), _col_bodies.size())

# ─────────────────────────────────────────────────────────────────────────────
# Биомы, материалы, статистика
# ─────────────────────────────────────────────────────────────────────────────

## (каньон, луг, горы) в мировой точке — те же маски, что запечены в вершины.
func biome_at(world_pos: Vector3) -> Vector3:
	var b := _biomes()
	var nz_cb: Callable = b.noise
	var p: Vector3 = global_transform.affine_inverse() * world_pos
	var wp := Vector2(p.x, p.z)
	return Vector3(b.canyon_mask(wp, nz_cb), b.meadow_mask(wp, nz_cb), b.mountain_mask(wp, nz_cb))

func _get_material() -> Material:
	return surface_material if surface_material != null else StandardMaterial3D.new()

## Два экземпляра базового материала: трава включена только у ближнего. Переключение уровня
## после этого — смена ссылки, а не параметра на экземпляр.
func _setup_materials(base: Material) -> void:
	if base is ShaderMaterial:
		_mat_lod0 = base.duplicate()
		(_mat_lod0 as ShaderMaterial).set_shader_parameter("lod_grass_enabled", 1.0)
		_mat_far = base.duplicate()
		(_mat_far as ShaderMaterial).set_shader_parameter("lod_grass_enabled", 0.0)
		_push_biomes()
	else:
		_mat_lod0 = base
		_mat_far = base

func _push_biomes() -> void:
	if biomes == null:
		return
	var h := world_height()
	if _mat_lod0 is ShaderMaterial:
		biomes.apply_to_material(_mat_lod0 as ShaderMaterial, h)
	if _mat_far is ShaderMaterial:
		biomes.apply_to_material(_mat_far as ShaderMaterial, h)

func set_grass_trample(tex: Texture2D, center: Vector2, size: float) -> void:
	if _mat_lod0 is ShaderMaterial:
		var m := _mat_lod0 as ShaderMaterial
		m.set_shader_parameter("trample_map", tex)
		m.set_shader_parameter("trample_center", center)
		m.set_shader_parameter("trample_size", size)

func set_corruption_map(tex: Texture2D, center: Vector2, size: float) -> void:
	for m in [_mat_lod0, _mat_far]:
		if m is ShaderMaterial:
			var sm := m as ShaderMaterial
			sm.set_shader_parameter("corrupt_map", tex)
			sm.set_shader_parameter("corrupt_world_center", center)
			sm.set_shader_parameter("corrupt_world_size", size)

## (узлов на экране, из них уровня 0, заданий в очереди) — видно, что именно рисуется.
func render_stats() -> Vector3i:
	var fine := 0
	for key in _want:
		if _key_lod(key) == 0:
			fine += 1
	return Vector3i(_want.size(), fine, pending_jobs())

# ─────────────────────────────────────────────────────────────────────────────
# Заслонённость
# ─────────────────────────────────────────────────────────────────────────────
## Луч от камеры к точке шагами по земле: если хоть один шаг выше линии взгляда, точка за
## бугром. Высоты идут через запомненные узлы сетки, поэтому шаги почти всегда бесплатны.
const OCCL_STEP := 8.0
const OCCL_MAX_STEPS := 28
const OCCL_HYST := 0.5

func is_point_hidden(world_pos: Vector3, height: float = 1.0, was_hidden: bool = false) -> bool:
	if not enable_occlusion_culling or _gen == null:
		return false
	if not is_instance_valid(_cam):
		_cam = _active_camera()
		if _cam == null:
			return false
	var eye: Vector3 = _cam.global_position
	var top := Vector3(world_pos.x, world_pos.y + maxf(height, 0.1), world_pos.z)
	var dist := eye.distance_to(top)
	if dist < occlusion_min_dist:
		return false
	var steps: int = mini(int(dist / OCCL_STEP), OCCL_MAX_STEPS)
	if steps < 2:
		return false
	# Порог с гистерезисом: без него объект на грани мигает каждый кадр.
	var bias: float = occlusion_bias + (OCCL_HYST if was_hidden else 0.0)
	for s in range(1, steps):
		var t: float = float(s) / float(steps)
		var p: Vector3 = eye.lerp(top, t)
		if terrain_height_at(p) > p.y + bias:
			return true
	return false

# ─────────────────────────────────────────────────────────────────────────────

# ─────────────────────────────────────────────────────────────────────────────
# Превью в редакторе
# ─────────────────────────────────────────────────────────────────────────────
## ТОТ ЖЕ МИР, ЧТО УВИДИТ ИГРА, по указанному сиду — прямо во вьюпорте редактора. Смотреть на
## сид иначе можно было только запуском игры: карты высот у чанковой земли нет, а значит нет и
## того файла, который док показывал раньше.
##
## В СЦЕНУ НЕ ПОПАДАЕТ НИЧЕГО: узлы рождаются без owner, поэтому .tscn их не видит, а коллизию
## превью не строит вовсе — она нужна машинам, а не глазам.
var _preview_on: bool = false

func preview_active() -> bool:
	return _preview_on

func preview_build(seed_value: int) -> void:
	preview_clear()
	_preview_on = true
	await setup_procedural(seed_value, _preview_eye())

func preview_clear() -> void:
	_preview_on = false
	stop_generation()
	for key in _live.keys():
		var n: Dictionary = _live[key]
		if is_instance_valid(n["inst"]):
			n["inst"].queue_free()
	_live.clear()
	_want.clear()
	_hc.clear()
	_memo.clear()
	_clear_collision()
	terrain_is_ready = false

## Где стоит камера редактора, в наших координатах. Превью строится вокруг неё, а не вокруг нуля:
## нода может стоять где угодно, а смотрят всегда туда, куда смотрят.
func _preview_eye() -> Vector3:
	var c := _active_camera()
	if c == null:
		return Vector3.ZERO
	return global_transform.affine_inverse() * c.global_position

## Камеру редактора кладёт плагин (_forward_3d_gui_input): своей у ноды в редакторе нет.
func set_editor_camera(c: Camera3D) -> void:
	if c != null and c != camera:
		camera = c

func _active_camera() -> Camera3D:
	if is_instance_valid(camera):
		return camera
	var vp := get_viewport()
	return vp.get_camera_3d() if vp != null else null

func _process(delta: float) -> void:
	if _gen == null:
		return
	if Engine.is_editor_hint() and not _preview_on:
		return
	_col_tick()
	_job_tick()
	_lod_timer += delta
	if _lod_timer < lod_interval:
		return
	_lod_timer = 0.0
	_cam = _active_camera()
	if _cam == null:
		return
	var t0 := _pf_now()
	var cam_local: Vector3 = global_transform.affine_inverse() * _cam.global_position
	_select(cam_local)
	var now: float = float(Time.get_ticks_msec()) * 0.001
	var left: int = stitch_budget
	for key in _want:
		var n = _live.get(key)
		if n == null:
			var l := _key_lod(key)
			var gx := _key_gx(key)
			var gz := _key_gz(key)
			_enqueue_mesh(l, gx, gz, _signature(l, gx, gz))
			continue
		n["seen"] = now
		n["inst"].visible = true
		# Сосед сменил уровень — край надо притянуть заново. Бюджет на тик: шов на кадр-другой
		# дешевле пересборки десятков узлов разом.
		if left > 0:
			var sig := _signature(n["lod"], n["gx"], n["gz"])
			if sig != n["sig"]:
				_enqueue_mesh(n["lod"], n["gx"], n["gz"], sig)
				left -= 1
	_retire(now)
	_pf_mark("terrain_lod", t0)

## УШЕДШЕЕ ИЗ КАДРА ПРЯЧЕМ, А НЕ ВЫБРАСЫВАЕМ. Поворот камеры меняет половину видимого набора, и
## освобождать меши сразу значит собирать ту же сотню узлов заново через секунду — терраса за
## спиной появлялась бы кусками. Меш живёт NODE_GRACE секунд после того, как перестал быть
## нужен, и выбрасывается раньше только когда их накопилось больше LIVE_CAP.
const NODE_GRACE := 8.0
const LIVE_CAP := 320

func _retire(now: float) -> void:
	var over: int = _live.size() - LIVE_CAP
	for key in _live.keys():
		if _want.has(key):
			continue
		var n: Dictionary = _live[key]
		if not is_instance_valid(n["inst"]):
			_live.erase(key)
			continue
		n["inst"].visible = false
		if over <= 0 and now - float(n["seen"]) < NODE_GRACE:
			continue
		n["inst"].queue_free()
		_live.erase(key)
		over -= 1
