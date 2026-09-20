## ПРОЦЕДУРНЫЙ РЕЛЬЕФ, ХРАНИМЫЙ И РИСУЕМЫЙ ЧАНКАМИ.
##
## ЕДИНСТВЕННАЯ ЗЕМЛЯ В ПРОЕКТЕ — и игра, и фон меню стоят на ней. Ни окна, ни массива высот на
## весь мир: чанк спрашивает у генератора свои вершины сам, и это единственное место, откуда
## берётся земля. Поэтому у мира нет края, память равна тому, что на экране, а чанк вдалеке не
## стоит ничего.
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

## КАМЕРА, ПО КОТОРОЙ СЧИТАЮТСЯ LOD И ОТСЕЧЕНИЕ. ОСТАВЛЯЙТЕ ПУСТЫМ. По умолчанию берётся та,
## которой сцена РИСУЕТСЯ прямо сейчас (`get_viewport().get_camera_3d()`), то есть земля сама
## следует за переключением камер, за спринг-армом и за сменой машины — искать по пути нечего.
##
## Поле осталось на один случай: вести LOD от камеры, которой сцена НЕ рисуется. Прописанный
## путь — это ещё и риск: однажды в сцену сохранился путь до камеры ВЬЮПОРТА РЕДАКТОРА, которой
## в игре нет вовсе, и земля осталась без камеры совсем.
@export var camera: Camera3D
@export var surface_material: Material = preload("res://addons/LiteTerrain/terrain_shader.res")
@export var biomes: TerrainBiomes = null : set = _set_biomes

@export_group("Visibility")
@export var view_distance: float = 1400.0
@export var enable_frustum_culling: bool = true
## ЗАПАС ЗА КРАЕМ ЭКРАНА, В МЕТРАХ, И ТОЛЬКО У БОКОВЫХ ПЛОСКОСТЕЙ.
##
## У ближней плоскости запас означает буквально «рисовать то, что за камерой»: её нормаль смотрит
## назад, и любой плюс пускает землю за спиной. Пока запас применялся ко всем шести плоскостям
## сразу, положительным его ставить было нельзя — отсюда и прежние −0.05, то есть не запас, а
## лёгкое ПЕРЕотсечение, которым гасили землю за камерой ценой узлов на краю экрана.
##
## Теперь ближняя и дальняя считаются точно, а боковым даётся честный запас: узел, который
## вот-вот выедет в кадр сбоку, успевает посчитаться заранее.
@export_range(0.0, 64.0, 1.0) var frustum_margin: float = 12.0
## Заслонённость рельефом для того, что на нём стоит. По умолчанию выключена, как и была: луч
## по земле стоит дороже, чем рисование куста, который всё равно за бугром.
@export var enable_occlusion_culling: bool = false
@export_range(0.0, 200.0, 1.0) var occlusion_min_dist: float = 40.0
@export_range(0.0, 10.0, 0.5) var occlusion_bias: float = 1.5

@export_group("Build")
## Сколько узлов собираем за один заход пула потоков. Заход один — второй писал бы в те же слоты.
@export_range(1, 64, 1) var build_batch: int = 24
## Пересборок из-за смены соседа за тик. Шов на кадр-другой дешевле просадки.
@export_range(1, 64, 1) var stitch_budget: int = 16
@export var lod_interval: float = 0.15

@export_group("Collision")
@export var enable_streaming_collision: bool = true
## Клеток вокруг тела, которым даём землю. Радиус должен покрывать не только то, где тело стоит,
## но и то, куда оно едет: тайл теперь СЧИТАЕТСЯ, а не режется из готового массива, и просить его
## в момент въезда — значит въехать в пустоту.
@export_range(4, 256, 4) var collision_radius: int = 12
## На сколько секунд вперёд смотрим по скорости тела. Машина на 15 м/с за это время проезжает
## больше чанка, и тайл успевает родиться до того, как под колесом кончится земля.
@export_range(0.0, 3.0, 0.1) var collision_lookahead: float = 1.2

@export_group("Procedural")
## Сид, на котором стоит эта земля. Пишется при подъёме мира, читается кем угодно снаружи —
## но НЕ экспорт: сид приходит из слота (G.world_seed) или из forced_seed, а поле в инспекторе
## выглядело бы как третий источник, который ни на что не влияет.
var world_seed: int = 0
## Номинальный размер мира для тех, кто спрашивает get_dims (раскладка магазинов, жил и точек).
## У самой земли края нет; это лишь квадрат, в котором игра расставляет своё.
@export var world_cells: int = 2048
@export_group("")

## Спрашивать ли сид у слота (G.world_seed). Выключено — берётся forced_seed: так фон меню и
## тестовые сцены получают свою землю, не трогая сохранение игрока.
@export var follow_world_settings: bool = true
## РОВНАЯ ЗЕМЛЯ. Не экспорт: ставится из G при подъёме (испытательный полигон), а галочка в
## инспекторе была бы вторым источником, который спорит с первым.
var flat_ground: bool = false
## Цвет земли на полигоне — чистый луг: трава есть, каньона и гор нет (см. _mesh_arrays).
const FLAT_COLOR := Color(1.0, 0.0, 1.0, 0.0)
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
##
## ПОТОЛОК ЗДЕСЬ РЕШАЕТ, СКОЛЬКО СТОИТ ВЕРНУТЬСЯ НАЗАД. Пересобрать меш из готовых высот —
## это вершины и цвет, миллисекунда; посчитать высоты заново — вчетверо дороже и с нуля. Пока
## кеш был на 768 записей, отъезд на полкилометра и обратно означал пересчёт всего, что проехал.
## Запись — 1.5 КБ, так что три тысячи их стоят четыре с половиной мегабайта.
var _hc: Dictionary = {}
const HC_CAP := 3072

var _jobs: Array = []          # очередь мешей
## ОЧЕРЕДЬ ТАЙЛОВ КОЛЛИЗИИ — ОТДЕЛЬНАЯ И ПЕРВАЯ. Пока она была общей с мешами, тайл под колесом
## ждал, когда посчитаются десятки узлов, которые игрок только увидит: земля под машиной
## кончалась каждые несколько метров. Меш — это то, на что смотрят, тайл — то, по чему едут.
var _col_jobs: Array = []
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
	# РОВНАЯ ЗЕМЛЯ ПОЛИГОНА. Флаг приходит оттуда же, откуда сид, — из G, а не экспортом в сцене:
	# мир у полигона тот же самый (node_3d.tscn), и вторая сцена ради одной галочки означала бы
	# вторую копию HUD, камеры и машины, которая начнёт отставать от первой с первой же правкой.
	flat_ground = game != null and game.get("proving_ground") == true
	# ГДЕ СТРОИТЬ ПЕРВУЮ ЗЕМЛЮ. В сохранённом мире машина вернётся на своё место уже ПОСЛЕ того,
	# как рельеф готов: world_persist сам ждёт его готовности. Значит вокруг камеры строить нечего
	# — она стоит там, где открылась сцена. Точку берём из сейва, её там пишут первой машиной.
	# Нового мира это не касается: сохранения нет, строим вокруг камеры.
	var inv := global_transform.affine_inverse()
	var start := Vector3.ZERO
	var saved = game.saved_start_point() if (game != null and game.has_method("saved_start_point")) else null
	if saved is Vector3:
		start = inv * (saved as Vector3)
	else:
		_cam = _active_camera()
		if _cam != null:
			start = inv * _cam.global_position
	await setup_procedural(seed_value, start)
	set_collision_streaming(true)
	# ГОВОРИМ, ТОЛЬКО ЕСЛИ ЗАГРУЗКА БЫЛА ДОЛГОЙ. Строка о каждом удачном входе — это строка,
	# которую перестают читать; число нужно ровно тогда, когда кольцо не уложилось в мгновение.

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
	gen.flat = flat_ground
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
## Дольше этого — повод сказать об этом в лог.
const READY_SLOW_MS := 400
## СКОЛЬКО ЗЕМЛИ ИМЕТЬ ДО ТОГО, КАК ПОКАЗАТЬ ХОТЬ ЧТО-ТО, в чанках в каждую сторону: 2 — это 5×5
## по 16 м, то есть 80 м вокруг точки старта. Экспорт, а не константа, потому что это решение
## СЦЕНЫ, а не движка: игре нужна земля под колёсами во все стороны от машины, которая сейчас
## поедет, а фону меню — пятачок под двумя машинами у начала координат, и каждый лишний чанк
## здесь это те же миллисекунды ожидания под экраном.
@export_range(1, 6) var ready_ring: int = 2

## Сколько заняли обе стадии входа, мс. Печатается при входе в мир: «быстро или медленно» — это
## не отчёт, а число — отчёт.
var _ready_ms: int = 0
var _view_ms: int = 0
var _ready_ms_t0: int = 0
## ДОКУДА ЖДЁМ ЗЕМЛЮ ПЕРЕД ТЕМ, КАК СНЯТЬ ЭКРАН ЗАГРУЗКИ, в метрах от камеры. Больше — дольше
## вход, но меньше пустоты вокруг в первый кадр.
@export_range(32.0, 512.0, 16.0) var ready_view: float = 192.0

func _build_around(around: Vector3, with_collision: bool = true) -> void:
	var t0 := Time.get_ticks_msec()
	_ready_ms_t0 = t0
	gen_step = "world"
	gen_frac = 0.0
	var bx := int(floor(around.x / CHUNK))
	var bz := int(floor(around.z / CHUNK))
	var need: Array[int] = []
	for dz in range(-ready_ring, ready_ring + 1):
		for dx in range(-ready_ring, ready_ring + 1):
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
	await _build_view(around)
	gen_step = ""
	gen_frac = 0.0

## ТО, ЧТО ИГРОК УВИДИТ В ПЕРВЫЙ КАДР. Кольцо выше — это земля ПОД КОЛЁСАМИ: коллизия есть,
## ехать можно, а вокруг пусто, потому что дальние узлы приезжали уже после того, как экран
## погас. Ждём ещё и те узлы, которые кадр просит и которые ближе ready_view; даль за ними
## дорисуется на ходу и этого не заметно.
##
## Ждать ВСЁ до горизонта нельзя: грубый узел стоит впятеро дороже мелкого (на шаге больше метра
## размытие не переиспользует соседей), и полный набор — это десятки секунд.
func _build_view(centre: Vector3) -> void:
	gen_step = "view"
	# КАМЕРА РЯДОМ С ТОЧКОЙ — значит смотрит туда же, и ждать надо только то, что в кадре. Далеко
	# (загруженный мир: машина ещё не вернулась на место) — куда игрок посмотрит, мы не знаем,
	# поэтому ждём круг вокруг точки, и вдвое меньший: круг это вчетверо больше узлов, чем конус.
	var here := centre
	var cull := false
	var cam := _active_camera()
	if cam != null:
		var cl: Vector3 = global_transform.affine_inverse() * cam.global_position
		if cl.distance_squared_to(centre) < CAM_AT_START * CAM_AT_START:
			here = cl
			cull = true
			_cam = cam
	_sel_local = here
	# Камера во время загрузки стоит, поэтому спуск по дереву делаем ОДИН раз, а не каждый кадр.
	_select(here, cull)
	var need: Array[int] = []
	var view: float = ready_view if cull else ready_view * 0.5
	var r2: float = view * view
	for key in _want:
		var l := _key_lod(key)
		var gx := _key_gx(key)
		var gz := _key_gz(key)
		if _aabb_dist2(_node_aabb(l, gx, gz), here) > r2:
			continue
		need.append(key)
		if not _live.has(key):
			_enqueue_mesh(l, gx, gz, _signature(l, gx, gz))
	_sort_queues(here)
	var guard := 0
	while guard < 900:
		var done := 0
		for k in need:
			if _live.has(k):
				done += 1
		gen_frac = float(done) / float(maxi(need.size(), 1))
		if done >= need.size():
			break
		_job_tick()
		await get_tree().process_frame
		guard += 1
	_view_ms = Time.get_ticks_msec() - _ready_ms_t0

## СНЯТЬ КАРТУ СО СЧЁТА. Зовёт тот, кто собирается её освободить: задания пула пишут в массивы,
## живущие в этой ноде, и без остановки допишут в уничтоженные.
func stop_generation() -> void:
	if _group != -1:
		WorkerThreadPool.wait_for_group_task_completion(_group)
		_group = -1
	_busy = false
	_jobs.clear()
	_col_jobs.clear()
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
	# ТА ЖЕ ПРАВКА ВТОРОЙ РАЗ — НЕ ПРАВКА. Кто просит площадку, обычно просит её вместе с
	# постройкой, и если постройка не встала, он приходит снова с теми же числами (quest_arcs
	# опрашивает свою ветку раз в секунду). Записывать копию нельзя по трём причинам: _edit_h
	# накладывает обе, и спад по краю выходит круче заказанного; каждая копия — лишний проход
	# на КАЖДОМ запросе высоты в этом прямоугольнике, навсегда; и список при переполнении
	# выбрасывает САМУЮ СТАРУЮ запись, то есть копии молча съедают площадки, выровненные раньше.
	if _same_edit_recorded(e, _flat_edits):
		return
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

## Есть ли уже такая же площадка. Сравниваем с допуском: числа приходят из мировой точки через
## обратную матрицу, и побитового совпадения у них не бывает даже у одного и того же места.
const EDIT_SAME_XZ := 0.25        # м: ближе этого центры считаем одним местом
const EDIT_SAME_Y := 0.05         # м: и высота площадки та же

func _same_edit_recorded(e: Dictionary, list: Array) -> bool:
	for o in list:
		if absf(o["cx"] - e["cx"]) < EDIT_SAME_XZ and absf(o["cz"] - e["cz"]) < EDIT_SAME_XZ \
				and absf(o["y"] - e["y"]) < EDIT_SAME_Y \
				and is_equal_approx(o["ex"], e["ex"]) and is_equal_approx(o["ez"], e["ez"]) \
				and is_equal_approx(o["fe"], e["fe"]):
			return true
	return false

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
		# Сейв доливается К ТОМУ, ЧТО УЖЕ ЕСТЬ: загрузка идёт кадрами, и квестовая ветка успевает
		# попросить свою площадку раньше, чем сейв до неё дошёл. Без этой проверки одна и та же
		# площадка ложилась бы дважды — см. flatten_area.
		if _same_edit_recorded(e, acc):
			continue
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

## ЗАБЫТЬ ПРАВКИ РЕЛЬЕФА — и только их. Земля считается из сида, сбрасывать в ней нечего: она и
## так та, какой родилась. Пересчитываем ровно те чанки, которых правки касались.
##
## ЭТО НЕ СБРОС МИРА. Написанная как «выбросить всё и собрать заново», эта функция убивала новый
## сейв: world_persist._fresh_start зовёт её первой строкой, и под игроком в тот же миг исчезала
## коллизия — ровно тогда, когда ему выдают стартовый набор.
func reset_heights() -> void:
	if _flat_edits.is_empty():
		return
	var area := _edit_rect(_flat_edits[0])
	for e in _flat_edits:
		area = area.merge(_edit_rect(e))
	_flat_edits = []
	_edit_seq = 0
	_invalidate(area)

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

## ЧТО У НАС ПО ЭТУ СТОРОНУ. Младшие четыре бита — насколько сосед КРУПНЕЕ (к его решётке надо
## притянуть край), бит 4 — уровни просто РАЗНЫЕ, в любую сторону.
##
## Второе нужно ровно из-за травы. Шейдер поднимает травинку, двигая вершину, и на шве это
## законно только если обе стороны двигают её одинаково. Крупный сосед о мелком не знает, его
## край никто не притягивает — значит он поднимал свои вершины, мелкий свои нет, и вдоль шва
## открывалась щель. Поэтому траву гасят ОБЕ стороны, а не только притянутая.
const SIDE_BITS := 8
const SIDE_DIFF := 0x10

func _side_info(lod: int, gx: int, gz: int, dx: int, dz: int) -> int:
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
	var diff := false
	for p in [a, b]:
		var l := _level_of(p.x, p.y)
		if l < 0:
			continue                       # там ничего не рисуется — шва нет
		if l != lod:
			diff = true
		if l > lod:
			k = maxi(k, l - lod)
	return mini(k, 4) | (SIDE_DIFF if diff else 0)

## Четыре соседа в одном числе, по байту на сторону: север, юг, запад, восток.
func _signature(lod: int, gx: int, gz: int) -> int:
	return _side_info(lod, gx, gz, 0, -1) \
		| (_side_info(lod, gx, gz, 0, 1) << SIDE_BITS) \
		| (_side_info(lod, gx, gz, -1, 0) << (SIDE_BITS * 2)) \
		| (_side_info(lod, gx, gz, 1, 0) << (SIDE_BITS * 3))

# ─────────────────────────────────────────────────────────────────────────────
# Спуск по дереву: что рисовать в этот тик
# ─────────────────────────────────────────────────────────────────────────────

## ДВА РАЗНЫХ ВОПРОСА, И ЗАДАВАТЬ ИХ НАДО С РАЗНОЙ ЧАСТОТОЙ.
##
## «Дробить узел или нет» зависит ТОЛЬКО от расстояния (lod > 0 and d2 < (span·LOD_QUALITY)²) —
## направление взгляда в это не входит вовсе. «Попадает ли узел в кадр» зависит только от
## пирамиды. Раньше оба считались одним рекурсивным обходом на каждом тике LOD: замер дал 6.6 мс,
## треть кадра 60 fps, и обход шёл вчетверо чаще, пока камера крутится. Плоский проход по кэшу
## стоит 1.65 мс, а сам обход повторяется примерно раз на шестнадцать метров пути.
##
## Теперь НАБОР ЛИСТЬЕВ КЭШИРУЕТСЯ — ключи плюс их прямоугольники в плоских массивах, — а на тике
## остаётся проход по нему с проверкой пирамиды. Обход дерева повторяется, только когда камера
## УЕХАЛА дальше LEAF_MOVE2.
##
## ПОЧЕМУ ПОРОГ — ЦЕЛЫЙ ЧАНК, А НЕ МЕТР. Камера ходит ПО ОРБИТЕ вокруг машины (RADIUS до 20 м в
## camera_controller), то есть при чистом повороте она никуда не смотрит с одного места: она едет
## по дуге длиной в сотню метров. Порог в метр пересобирал бы набор всю дугу напролёт, ровно там,
## где этого и надо избежать. Плата — граница уровня LOD запаздывает на те же 16 м: узлу, которому
## пора раздробиться, дают проехать лишний чанк крупным. Это обычный гистерезис, а не дыра: земля
## на месте, шов притянут, а коллизия идёт своей очередью по коридору тела и кэша не касается.
##
## Высота в кэш не кладётся: у всех узлов она одна (_y_lo.._y_hi) и живёт вместе с миром — её
## подставляет _pack_planes, один раз на тик вместо одного раза на узел.
var _leaf_keys := PackedInt64Array()
var _leaf_box := PackedFloat32Array()         # по 4 на лист: minx, minz, maxx, maxz
var _leaf_at: Vector3 = Vector3(1e9, 1e9, 1e9)
var _leaf_vd: float = -1.0
const LEAF_MOVE2 := 256.0                     # 16 м, один базовый чанк

## cull = false — берём всё вокруг точки, без отсечения по кадру. Нужно входу в сохранённый мир:
## земля строится вокруг машины, а камера в этот момент ещё смотрит из начала сцены.
func _select(at: Vector3, cull: bool = true) -> void:
	var mx: float = at.x - _leaf_at.x
	var mz: float = at.z - _leaf_at.z
	# По высоте не сверяемся: расстояние до узла меряется по земле (см. _aabb_dist2), и подъём
	# камеры на орбите набор листьев не меняет.
	if _leaf_vd != view_distance or mx * mx + mz * mz > LEAF_MOVE2:
		_build_leaves(at)
	_want.clear()
	var n: int = _leaf_keys.size()
	if not (cull and enable_frustum_culling and is_instance_valid(_cam)):
		for i in n:
			_want[_leaf_keys[i]] = true
		return
	_pack_planes()
	for i in n:
		var b: int = i * 4
		var vis := true
		for q in 6:
			var q3: int = q * 3
			if _pl[q3] * _leaf_box[b + _pi[q * 2]] \
					+ _pl[q3 + 1] * _leaf_box[b + _pi[q * 2 + 1]] \
					+ _pl[q3 + 2] > 0.0:
				vis = false
				break
		if vis:
			_want[_leaf_keys[i]] = true

func _build_leaves(at: Vector3) -> void:
	_leaf_keys.clear()
	_leaf_box.clear()
	_leaf_at = at
	_leaf_vd = view_distance
	var top := CHUNK << MAX_LOD
	var r: int = int(ceil(view_distance / float(top)))
	var g0x: int = int(floor(at.x / float(top)))
	var g0z: int = int(floor(at.z / float(top)))
	for gz in range(g0z - r, g0z + r + 1):
		for gx in range(g0x - r, g0x + r + 1):
			_descend(MAX_LOD, gx, gz, at)

## Считает только расстояние, и арифметика здесь РАЗВЁРНУТА (ни _node_aabb, ни _aabb_dist2, ни
## _key): вызов в GDScript стоит больше самой формулы, а на узел их выходило четыре.
func _descend(lod: int, gx: int, gz: int, cam: Vector3) -> void:
	var span := float(CHUNK << lod)
	var x0: float = gx * span
	var z0: float = gz * span
	var x1: float = x0 + span
	var z1: float = z0 + span
	var dx: float = maxf(maxf(x0 - cam.x, 0.0), cam.x - x1)
	var dz: float = maxf(maxf(z0 - cam.z, 0.0), cam.z - z1)
	var d2: float = dx * dx + dz * dz
	if d2 > view_distance * view_distance:
		return
	var split := span * LOD_QUALITY
	if lod > 0 and d2 < split * split:
		var cx := gx * 2
		var cz := gz * 2
		_descend(lod - 1, cx, cz, cam)
		_descend(lod - 1, cx + 1, cz, cam)
		_descend(lod - 1, cx, cz + 1, cam)
		_descend(lod - 1, cx + 1, cz + 1, cam)
		return
	_leaf_keys.append((lod << 40) | ((gx & 0xFFFFF) << 20) | (gz & 0xFFFFF))
	_leaf_box.append(x0)
	_leaf_box.append(z0)
	_leaf_box.append(x1)
	_leaf_box.append(z1)

func _aabb_dist2(aabb: AABB, p: Vector3) -> float:
	var mx: Vector3 = aabb.position + aabb.size
	var dx: float = maxf(maxf(aabb.position.x - p.x, 0.0), p.x - mx.x)
	var dz: float = maxf(maxf(aabb.position.z - p.z, 0.0), p.z - mx.z)
	return dx * dx + dz * dz

## Куда смотрит камера, в осях ноды. Ставится в _pack_planes, читается там же.
var _cam_fwd_local: Vector3 = Vector3.FORWARD
## Выше этого |n·вперёд| плоскость считается ближней или дальней — им запас не даём. У бокового
## угол к оси взгляда это половина поля зрения плюс прямой, то есть скалярное произведение сильно
## меньше; спутать нельзя.
const AXIAL_DOT := 0.9

## ПИРАМИДА, СЛОЖЕННАЯ ДЛЯ ПЛОСКОГО ПРОХОДА. Шесть плоскостей превращаются в 6×(nx, nz, сдвиг) и
## 6×(какой угол брать по x, какой по z): у AABB ближний к плоскости угол выбирается по знаку
## нормали, а знак за тик не меняется — значит это индекс в _leaf_box, посчитанный один раз.
## В сдвиг уже сложены высота узла (у всех одна), d плоскости и запас, так что в цикле по узлам
## остаётся два умножения и сравнение, без Plane, без Vector3 и без вызовов.
var _pl := PackedFloat32Array()
var _pi := PackedInt32Array()

func _pack_planes() -> void:
	var inv := global_transform.affine_inverse()
	# Куда смотрит камера, в наших осях: по нему отличаем ближнюю и дальнюю плоскости от боковых
	# (см. frustum_margin). По номеру в массиве — нельзя: порядок плоскостей это деталь движка, а
	# нормаль говорит сама за себя.
	_cam_fwd_local = (inv.basis * (-_cam.global_transform.basis.z)).normalized()
	_pl.resize(18)
	_pi.resize(12)
	var i := 0
	for raw in _cam.get_frustum():
		if i == 6:
			break
		var p: Plane = inv * (raw as Plane)
		var nn: Vector3 = p.normal
		# Ближней и дальней — точно, без запаса: плюс у ближней это земля за спиной.
		var m: float = 0.0 if absf(nn.dot(_cam_fwd_local)) > AXIAL_DOT else frustum_margin
		_pl[i * 3] = nn.x
		_pl[i * 3 + 1] = nn.z
		_pl[i * 3 + 2] = nn.y * (_y_lo if nn.y >= 0.0 else _y_hi) - p.d - m
		_pi[i * 2] = 0 if nn.x >= 0.0 else 2
		_pi[i * 2 + 1] = 1 if nn.z >= 0.0 else 3
		i += 1
	# Плоскостей всегда шесть, но массив переживает тик: недобор оставил бы в хвосте прошлую
	# пирамиду. Добиваем плоскостью, которая не отсекает ничего.
	while i < 6:
		_pl[i * 3] = 0.0
		_pl[i * 3 + 1] = 0.0
		_pl[i * 3 + 2] = -1e9
		_pi[i * 2] = 0
		_pi[i * 2 + 1] = 1
		i += 1

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
		# Середина узла — по ней очередь потом сортируется от камеры (см. _sort_queues).
		"cx": gx * span + span * 0.5, "cz": gz * span + span * 0.5, "d2": 0.0,
	})

func _enqueue_coll(bcx: int, bcz: int) -> void:
	var key := _key(0, bcx, bcz)
	if _col.has(key) or _queued.has(key | (1 << 50)):
		return
	_queued[key | (1 << 50)] = true
	_col_jobs.append({
		"kind": JOB_COLL, "key": key, "lod": 0, "gx": bcx, "gz": bcz, "sig": 0,
		"edits": _edits_in(bcx * float(CHUNK), bcz * float(CHUNK), float(CHUNK)),
		"cx": bcx * CHUNK + CHUNK * 0.5, "cz": bcz * CHUNK + CHUNK * 0.5, "d2": 0.0,
	})

## БЛИЖНЕЕ СЧИТАЕТСЯ ПЕРВЫМ. Очередь набирается обходом дерева, то есть в порядке клеток верхнего
## уровня, и без сортировки узел в километре мог родиться раньше того, на который игрок смотрит:
## земля вокруг проявлялась кусками откуда попало.
func _sort_queues(cam: Vector3) -> void:
	for q in [_col_jobs, _jobs]:
		if q.size() < 2:
			continue
		for j in q:
			var dx: float = j["cx"] - cam.x
			var dz: float = j["cz"] - cam.z
			j["d2"] = dx * dx + dz * dz
		q.sort_custom(_nearer)

func _nearer(a: Dictionary, b: Dictionary) -> bool:
	return a["d2"] < b["d2"]

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
	_drain_apply()
	# Очередь приземления не разобрана — новую пачку не считаем. Это ПОДПОР, а не задержка:
	# без него на скорости пул считал бы быстрее, чем главный поток успевает класть, и очередь
	# росла бы вместе с памятью, а земля отставала бы всё равно.
	if not _apply_q.is_empty():
		return
	if _gen == null or (_jobs.is_empty() and _col_jobs.is_empty()):
		return
	# Сначала коллизия, целиком: её очередь короткая (тайлы вокруг тел), а ждать её нельзя.
	_batch = _col_jobs.slice(0, build_batch)
	_col_jobs = _col_jobs.slice(_batch.size())
	if _batch.size() < build_batch:
		var rest: int = build_batch - _batch.size()
		_batch.append_array(_jobs.slice(0, rest))
		_jobs = _jobs.slice(mini(rest, _jobs.size()))
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
	return _jobs.size() + _col_jobs.size() + (_batch.size() if _busy else 0)

## СЧИТАТЬ МОЖНО ПАЧКОЙ, А ПРИЗЕМЛЯТЬ — НЕТ. Потоки считают build_batch чанков параллельно, и
## это правильно: считают они в своих слайсах и никому не мешают. А вот приземление идёт на
## ГЛАВНОМ потоке и стоит дорого на каждый чанк: ArrayMesh, заливка вершин в GPU, новый узел в
## дереве сцены. Двадцать четыре таких в одном кадре — это замеренные игроком 30 fps на месте
## против 22 при движении по новой земле.
##
## Поэтому результаты кладутся В ОЧЕРЕДЬ, а из неё в кадр уходит не больше apply_budget штук.
## Общее время то же, спайк размазан.
##
## КОЛЛИЗИЯ ИДЁТ ВНЕ БЮДЖЕТА. Тайл — это то, по чему едет машина; задержать его на кадр значит
## дать ей провалиться. Меш — это то, на что смотрят, и он подождёт.
@export_range(1, 32, 1) var apply_budget: int = 4
var _apply_q: Array = []

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
		_apply_q.append({"job": job, "mesh": res["mesh"]})
	_batch.clear()
	_out.clear()
	_prune_heights()

## Приземляем по apply_budget мешей за кадр. Пока очередь не пуста, новую пачку в пул не
## запускаем (см. _job_tick): иначе на быстрой езде очередь росла бы быстрее, чем разбирается,
## и земля отставала бы всё сильнее, а память — всё выше.
func _drain_apply() -> void:
	# ПОКА ИДЁТ ЗАГРУЗКА — БЕЗ БЮДЖЕТА. Там экран всё равно закрыт фейдом, сглаживать нечего, а
	# нужна максимальная пропускная способность: игрок смотрит на полосу загрузки, а не на кадры.
	# Бюджет включается, когда земля готова и на неё начали смотреть.
	var n: int = _apply_q.size() if not terrain_is_ready else mini(apply_budget, _apply_q.size())
	for i in n:
		var e: Dictionary = _apply_q.pop_front()
		var job: Dictionary = e["job"]
		_queued.erase(int(job["key"]))
		_place_mesh(int(job["key"]), job, e["mesh"])

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
	# ЗЕМЛЯ ТЕНЬ НЕ ОТБРАСЫВАЕТ, ТОЛЬКО ПРИНИМАЕТ. Замер на устройстве: с тенями 17 fps, без них
	# 25 — треть кадров за одну настройку. Тени и так настроены скупо (один сплит, жёсткие, карта
	# 1024), значит цена не в качестве, а в том, ЧТО в карту рисуется: ближние два уровня это
	# десятки тысяч треугольников земли против пары тысяч у машин.
	#
	# Тень, которую игрок реально видит, — это тень МАШИНЫ на земле, и она остаётся. Уходит
	# собственная тень рельефа: гора перестаёт затенять долину. Потеря настоящая и признана.
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# Успел уехать из кадра, пока считался, — всё равно кладём, только скрытым: он уже посчитан,
	# а камера ходит туда-сюда.
	mi.visible = _want.has(key)
	add_child(mi)
	_live[key] = {"inst": mi, "sig": job["sig"], "lod": job["lod"], "gx": job["gx"], "gz": job["gz"],
			"seen": float(Time.get_ticks_msec()) * 0.001}

## БЛИЖНИЙ КРУГ ДЕРЖИМ ВСЕГДА. Всё, что ближе KEEP_RADIUS к игроку, не выбрасывается ни по
## времени, ни по потолку: это земля, на которую он развернётся через секунду. Остальная память
## работает как было — недавно виденное лежит ещё NODE_GRACE секунд и вытесняется самым старым.
##
## Круг в 320 м это около полутора сотен узлов всех уровней: пятая часть потолка мешей и
## двадцатая — потолка высот. Дёшево ровно потому, что дальние уровни накрывают много одним узлом.
@export_range(0.0, 1024.0, 16.0) var keep_radius: float = 320.0

func _near_player(key: int) -> bool:
	if keep_radius <= 0.0:
		return false
	return _aabb_dist2(_node_aabb(_key_lod(key), _key_gx(key), _key_gz(key)), _sel_local) \
			<= keep_radius * keep_radius

## Высоты держим у того, что рисуется, лежит под коллизией или стоит в ближнем круге.
func _prune_heights() -> void:
	if _hc.size() <= HC_CAP:
		return
	for key in _hc.keys():
		if _hc.size() <= HC_CAP:
			return
		if _live.has(key) or _want.has(key) or _col.has(key) or _near_player(key):
			continue
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
	var sn: int = sig & 0xFF
	var ss: int = (sig >> SIDE_BITS) & 0xFF
	var sw: int = (sig >> (SIDE_BITS * 2)) & 0xFF
	var se: int = (sig >> (SIDE_BITS * 3)) & 0xFF
	var kn: int = sn & 0xF
	var ks: int = ss & 0xF
	var kw: int = sw & 0xF
	var ke: int = se & 0xF
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
			# Шов — это РАЗНЫЕ уровни, а не только «сосед крупнее»: траву гасят обе стороны.
			var seam := (j == 0 and (sn & SIDE_DIFF) != 0) \
					or (j == VERTS - 1 and (ss & SIDE_DIFF) != 0) \
					or (i == 0 and (sw & SIDE_DIFF) != 0) \
					or (i == VERTS - 1 and (se & SIDE_DIFF) != 0)
			# На полигоне масок не спрашиваем вовсе: там один биом по определению, а три маски на
			# вершину — это ровно та работа, ради отсутствия которой земля и сделана ровной.
			cols[vi] = (Color(0.0 if seam else FLAT_COLOR.r, FLAT_COLOR.g, FLAT_COLOR.b, FLAT_COLOR.a)
					if flat_ground else Color(0.0 if seam else 1.0,
					b.canyon_mask(wp, nz_cb), b.meadow_mask(wp, nz_cb), b.mountain_mask(wp, nz_cb)))

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
const COL_TILE_GRACE := 6.0

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
		# КОРИДОР, А НЕ ТОЧКА: землю просим и там, где тело стоит, и там, где оно окажется через
		# collision_lookahead секунд. Тайл теперь считается, и просить его в момент въезда значит
		# въехать в пустоту. Сдвигать окно целиком вперёд нельзя — на большой скорости тело
		# выпало бы из собственного окна.
		var p0: Vector3 = inv * body.global_position
		var p1: Vector3 = p0
		if collision_lookahead > 0.0 and body is RigidBody3D:
			p1 += inv.basis * ((body as RigidBody3D).linear_velocity * collision_lookahead)
		var bx0: int = int(floor((minf(p0.x, p1.x) - r) / CHUNK))
		var bx1: int = int(floor((maxf(p0.x, p1.x) + r) / CHUNK))
		var bz0: int = int(floor((minf(p0.z, p1.z) - r) / CHUNK))
		var bz1: int = int(floor((maxf(p0.z, p1.z) + r) / CHUNK))
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
	# ОТМЕЧАЕМ ВРЕМЯ СРАЗУ. Без записи _col_seen считает тайл ненужным с нулевой секунды и сносит
	# его на первом же тике — а тайлы стартового кольца рождаются раньше, чем машина встанет на
	# своё место, то есть до того, как их кто-то попросит.
	_col_seen[key] = float(Time.get_ticks_msec()) * 0.001

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

## ОДНА ДВЕРЬ К ШЕЙДЕРУ ЗЕМЛИ СНАРУЖИ. Материалов ДВА (ближний с травой и дальний без неё), и
## тот, кто хочет что-то в них поменять, обязан попасть в оба: правка одного означает, что
## настройка действует только до 64 метров, а дальше земля живёт по-старому.
func set_surface_param(name: StringName, value: Variant) -> void:
	for m in [_mat_lod0, _mat_far]:
		if m is ShaderMaterial:
			(m as ShaderMaterial).set_shader_parameter(name, value)

func get_surface_param(name: StringName) -> Variant:
	return (_mat_lod0 as ShaderMaterial).get_shader_parameter(name) \
			if _mat_lod0 is ShaderMaterial else null

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
##
## ДЕРЖИМ ЕЁ ОТДЕЛЬНО ОТ `camera`. Запись в экспортируемое свойство помечает сцену изменённой, и
## однажды она сохраняется: в node_3d.tscn уезжал путь до камеры ВЬЮПОРТА РЕДАКТОРА
## (`../../../@Node3DEditorViewport@…/@Camera3D@…`), которой в игре нет вовсе — то есть у земли в
## запущенной игре камеры не оставалось. Поле не экспортируется и в сцену попасть не может.
var _ed_cam: Camera3D = null

func set_editor_camera(c: Camera3D) -> void:
	if c != null:
		_ed_cam = c

func _active_camera() -> Camera3D:
	if Engine.is_editor_hint() and is_instance_valid(_ed_cam):
		return _ed_cam
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
	var cam := _active_camera()
	if cam == null:
		return
	# ВЫБОР ПЕРЕСЧИТЫВАЕТСЯ ПО ДВИЖЕНИЮ, А НЕ ТОЛЬКО ПО ТАЙМЕРУ. На скорости за 0.15 с камера
	# проезжает несколько метров и разворачивается — узел, выехавший в кадр, ждал следующего тика
	# и всё это время его просто не было.
	var fwd: Vector3 = -cam.global_transform.basis.z
	var stirred: bool = cam.global_position.distance_squared_to(_sel_pos) > SEL_MOVE2 \
			or fwd.dot(_sel_fwd) < SEL_TURN_COS
	if _lod_timer < (lod_interval * 0.25 if stirred else lod_interval):
		return
	_lod_timer = 0.0
	_sel_pos = cam.global_position
	_sel_fwd = fwd
	_cam = cam
	var t0 := _pf_now()
	var cam_local: Vector3 = global_transform.affine_inverse() * _cam.global_position
	_sel_local = cam_local
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
	_sort_queues(cam_local)
	_pf_mark("terrain_lod", t0)

## УШЕДШЕЕ ИЗ КАДРА ПРЯЧЕМ, А НЕ ВЫБРАСЫВАЕМ. Поворот камеры меняет половину видимого набора, и
## освобождать меши сразу значит собирать ту же сотню узлов заново через секунду — терраса за
## спиной появлялась бы кусками. Меш живёт NODE_GRACE секунд после того, как перестал быть
## нужен, и выбрасывается раньше только когда их накопилось больше LIVE_CAP.
const NODE_GRACE := 15.0
const LIVE_CAP := 420
## Насколько камера должна сдвинуться (метры в квадрате) или повернуться, чтобы пересчитать выбор
## раньше таймера. Четыре метра и пара градусов: меньше — и пересчёт идёт каждый кадр впустую.
## Этот порог задаёт ЧАСТОТУ ТИКА и ничего больше; пересборку дерева держит свой, гораздо более
## крупный LEAF_MOVE2 — тик на повороте стоит одного плоского прохода по кэшу листьев.
## Ближе CAM_AT_START камера считается стоящей в той же точке, что и стройка первой земли.
const CAM_AT_START := 32.0
const SEL_MOVE2 := 16.0
const SEL_TURN_COS := 0.999
var _sel_pos: Vector3 = Vector3(1e9, 1e9, 1e9)
## То же самое, но В ОСЯХ НОДЫ: узлы живут в них, а _sel_pos мировой — им меряют сдвиг камеры.
var _sel_local: Vector3 = Vector3(1e9, 1e9, 1e9)
var _sel_fwd: Vector3 = Vector3.FORWARD

## ЕСТЬ ЛИ НА ЭТОМ МЕСТЕ ДРУГАЯ ЗЕМЛЯ. Смена уровня — это не «узел ушёл», а «узел заменили»:
## вместо одного грубого встают четверо мелких или наоборот. Но замена ещё ТОЛЬКО В ОЧЕРЕДИ, а
## старый гасился в тот же тик — на его месте на секунду-другую открывалась дыра. Ровно это и
## выглядит как «чанки пропадают, пока едешь».
func _covered(key: int) -> bool:
	var l := _key_lod(key)
	var gx := _key_gx(key)
	var gz := _key_gz(key)
	# Накрывает только то, что кадр ПРОСИТ и что уже ПОСТРОЕНО. «Просит» обязательно: живой, но
	# тоже погашенный сосед не накрывает ничего, и по нему пряталась бы целая цепочка.
	var pk := _key(l + 1, gx >> 1, gz >> 1)
	if l < MAX_LOD and _want.has(pk) and _live.has(pk):
		return true                    # стали грубее: накрывает родитель
	if l > 0:
		var all := true
		for dz in 2:
			for dx in 2:
				var ck := _key(l - 1, gx * 2 + dx, gz * 2 + dz)
				if not (_want.has(ck) and _live.has(ck)):
					all = false
		if all:
			return true                # стали мельче: накрывают все четверо детей
	return false

func _retire(now: float) -> void:
	var over: int = _live.size() - LIVE_CAP
	for key in _live.keys():
		if _want.has(key):
			continue
		var n: Dictionary = _live[key]
		if not is_instance_valid(n["inst"]):
			_live.erase(key)
			continue
		# Не накрыт — оставляем видимым. За кадром его всё равно отсечёт движок, а вот дыры на
		# месте узла, чья замена ещё считается, не будет.
		if _covered(key):
			n["inst"].visible = false
		if _near_player(key):
			continue                   # ближний круг не выбрасываем ни по времени, ни по потолку
		if over <= 0 and now - float(n["seen"]) < NODE_GRACE:
			continue
		n["inst"].queue_free()
		_live.erase(key)
		over -= 1
