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
## WHICH NODES and WHICH OF THEM ARE SEEN are two passes at two rates: the leaf set comes from
## distance alone and is cached (`_build_leaves`), the frustum is a flat pass over it (`_select`).
@tool
class_name ChunkTerrain
extends StaticBody3D

# ── Что рисуем ───────────────────────────────────────────────────────────────
const CHUNK := 16                 ## клеток в стороне базового чанка
const VERTS := CHUNK + 1          ## вершин в стороне любого узла, на любом уровне
const APRON := VERTS + 2          ## та же сетка с каймой в одну клетку — она нужна нормалям
## The top level: 16 x 128 = 2048 m a node. It was 5 (512 m) while the view ended at 1400 m; with the
## draw distance the player's (up to 10 km, Main.VIEW_MAX) every node past 1 km stayed 512 m with 32 m
## cells, so the far ground was thousands of nodes of sub-pixel triangles. The key keeps 3 bits for it.
const MAX_LOD := 7
## Раскрываем узел, пока расстояние до него меньше его размера, умноженного на это. Двойка —
## не вкусовое число: при ней соседние листья не могут разойтись больше чем на уровень, и
## притягивать край нужно только к вдвое более крупному соседу.
const LOD_QUALITY := 2.0

## SUB-PIXEL GROUND IS NOT SPLIT (`_subpixel`): a node the distance rule would split stays whole when
## its children's cells would cover fewer than SUBPX_MIN pixels on screen - seen at a grazing angle a
## far plain's cell is a fraction of a pixel tall however wide it is, and the GPU shades every such
## triangle as whole 2x2 quads. The size is the cell's projection by the camera's own pixels per
## radian, times how squarely the ground faces the eye: the height gap to the node over the distance,
## plus the node's own relief over its width (a mountain face looks at the camera; a plain does not).
## Never nearer than SUBPX_NEAR (the grass lift and its level-1 borders live in front of it), and never
## more than SUBPX_EXTRA levels coarser than distance alone - neighbours then differ by three levels
## at most, under the four `_snap_row` can stitch.
const SUBPX_MIN := 2.0
const SUBPX_NEAR := 256.0
const SUBPX_EXTRA := 2

## THE INSPECTOR HOLDS WHAT SHAPES THE LOOK: the ground's material, the biomes and the behind-a-hill
## switch (the player: "a heap of useless settings" - the ENGINE's tuning numbers went). The menu
## backdrop's own numbers are set from its script (menu_stage_3d `_make_map`), and every tuning
## number nobody changes is a constant below. Gone: `camera` (the ground always takes the camera the
## scene is DRAWN with, and a path stored once pointed at the editor viewport's camera, which a
## running game does not have) and the frustum culling switch (always on).
const GROUND_SHADER := preload("res://addons/LiteTerrain/glsl.gdshader")
## THE GROUND'S MATERIAL, its shader's settings in the inspector (the player: "return the shader
## that was in the export" - for a commit it was made in code and its settings turned into a group
## of the node's own, and both were wrong). A plain text resource with no texture slot of its own:
## the binary `terrain_shader.res` it replaces carried a tile texture the shader no longer read and
## shipped it in every build. The node draws with a COPY (`_setup_materials`), and the copy takes
## from `biomes` the colours, rock, snow, grass and canyon bands, and from the game the grass fade,
## the trample and the corruption map - those are tuned there; everything else is tuned here. The
## editor's preview takes a change at the next "Build in scene": the engine says nothing when a
## shader parameter changes.
@export var surface_material: Material = preload("res://addons/LiteTerrain/terrain_shader.tres")
@export var biomes: TerrainBiomes = null : set = _set_biomes
## WHAT STANDS BEHIND A HILL IS NOT DRAWN (`is_point_hidden`, asked by veins, loose items and
## machines). On by default (the player's call); the ray reads the DRAWN ground's heights, see there.
@export var enable_occlusion_culling: bool = true

@export_group("Render")
## How far ground is drawn. In the game the player's own setting (garage SETTINGS) wins once saved;
## this is its starting value (`Main._ready`). The menu backdrop draws much less (MENU_VIEW).
@export_range(200.0, 10000.0, 10.0) var view_distance: float = 1400.0
## THE HAZE (the global `haze_range`'s strength): off, the far ground and the trees show their own
## colour to the edge. The haze still stretches with the draw distance (`Main._apply_view`).
@export var haze_enabled: bool = true:
	set(v):
		haze_enabled = v
		_apply_haze()

@export_group("Biomes")
## Which biomes the world has; off, its mask is zero everywhere (the desert's off means all meadow).
## Read before the ground is built - in the editor press "Build in scene" again after a change.
@export var desert_enabled: bool = true:
	set(v):
		desert_enabled = v
		_push_switches()
@export var canyons_enabled: bool = true:
	set(v):
		canyons_enabled = v
		_push_switches()
@export var mountains_enabled: bool = true:
	set(v):
		mountains_enabled = v
		_push_switches()
@export var salt_flats_enabled: bool = true:
	set(v):
		salt_flats_enabled = v
		_push_switches()

@export_group("Vertex lift")
## The meadow's grass lift (`TerrainBiomes.grass_height`) and the snow's crust (the material's
## `snow_height`); off, the ground is drawn at its own heights - fewer moved vertices, same triangles.
@export var grass_lift_enabled: bool = true:
	set(v):
		grass_lift_enabled = v
		_push_biomes()
@export var snow_lift_enabled: bool = true:
	set(v):
		snow_lift_enabled = v
		_push_biomes()
@export_group("")
## ЗАПАС ЗА КРАЕМ ЭКРАНА, В МЕТРАХ, И ТОЛЬКО У БОКОВЫХ ПЛОСКОСТЕЙ.
##
## У ближней плоскости запас означает буквально «рисовать то, что за камерой»: её нормаль смотрит
## назад, и любой плюс пускает землю за спиной. Пока запас применялся ко всем шести плоскостям
## сразу, положительным его ставить было нельзя — отсюда и прежние −0.05, то есть не запас, а
## лёгкое ПЕРЕотсечение, которым гасили землю за камерой ценой узлов на краю экрана.
##
## Теперь ближняя и дальняя считаются точно, а боковым даётся честный запас: узел, который
## вот-вот выедет в кадр сбоку, успевает посчитаться заранее.
const FRUSTUM_MARGIN := 12.0
## Nothing nearer than this is ever hidden: up close the test means nothing and a blink costs most.
const OCCL_MIN_DIST := 40.0
## How far the ground has to stand ABOVE the line of sight to hide a thing - the margin that also
## covers a test asked a few frames late.
const OCCL_BIAS := 1.5

## Сколько узлов собираем за один заход пула потоков. Заход один — второй писал бы в те же слоты.
const BUILD_BATCH := 24
## Пересборок из-за смены соседа за тик. Шов на кадр-другой дешевле просадки.
const STITCH_BUDGET := 16
## Seconds between LOD passes; the selection is also recomputed whenever the camera moves.
const LOD_INTERVAL := 0.15

## Streamed collision tiles. The menu keeps them off on a map being prepared (set_collision_streaming).
var enable_streaming_collision: bool = true
## Клеток вокруг тела, которым даём землю. Радиус должен покрывать не только то, где тело стоит,
## но и то, куда оно едет: тайл теперь СЧИТАЕТСЯ, а не режется из готового массива, и просить его
## в момент въезда — значит въехать в пустоту.
const COLLISION_RADIUS := 12
## На сколько секунд вперёд смотрим по скорости тела. Машина на 15 м/с за это время проезжает
## больше чанка, и тайл успевает родиться до того, как под колесом кончится земля.
const COLLISION_LOOKAHEAD := 1.2

## Номинальный размер мира для тех, кто спрашивает get_dims (раскладка магазинов, жил и точек).
## У самой земли края нет; это лишь квадрат, в котором игра расставляет своё.
const WORLD_CELLS := 2048

## Спрашивать ли сид у слота (G.world_seed). Выключено — берётся forced_seed: так фон меню
## получает свою землю, не трогая сохранение игрока.
var follow_world_settings: bool = true
## РОВНАЯ ЗЕМЛЯ. Не экспорт: ставится из G при подъёме (испытательный полигон), а галочка в
## инспекторе была бы вторым источником, который спорит с первым.
var flat_ground: bool = false
## Цвет земли на полигоне — чистый луг: трава есть, каньона и гор нет (см. _mesh_arrays).
## COLOR.r CARRIES TWO THINGS: the vertex's BORDER CODE and the SALT FLAT mask - the other three
## channels are canyon, meadow and mountain, and a fifth biome needs a home. r = EDGE_STEP x code +
## SALT_SPAN x salt; code 0 inside the node, 1 on a border running along x (the north and south
## rows), 2 along z. The shader's grass takes its border rule from it (glsl.gdshader). The code is
## a fact of the vertex's place in its OWN node, never of the neighbours: a flag read off the
## neighbours at build time goes stale the moment one of them changes level.
const EDGE_STEP := 1.0 / 3.0
const SALT_SPAN := 0.3
const FLAT_COLOR := Color(0.0, 0.0, 1.0, 0.0)
## The seed when `follow_world_settings` is off: the menu's round, the editor's preview.
var forced_seed: int = 0

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
## ONE MATERIAL FOR EVERY LEVEL: the grass is the same function of the world point on all of them
## (glsl.gdshader), so there is nothing left to tell a near node from a far one.
var _mat: Material = null
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
var _queued: Dictionary = {}   # key → задание (или true у коллизии), чтобы не заводить второе
## BUILT MESHES WAITING FOR THEIR LEVEL CHANGE TO BE WHOLE (_place_mesh, _release_held): key -> the
## entry `_live` will hold. A level change is several meshes - the replacement and every neighbour's
## restitch - and each shown the moment it landed met a neighbour still built for the old levels:
## a crack as tall as the ground climbs over a cell (measured up to 1.3 m while driving).
var _staged: Dictionary = {}
var _held_dirty: bool = false
var _held_check_t: float = 0.0
## How long a held mesh may wait before it goes up as it is. A level change waits long: the old
## ground stands meanwhile, so the cost is coarser ground for a moment, not a hole. Fresh ground
## waits briefly: until it is up there is no ground there at all.
const HOLD_MAX_MS := 4000
const FRESH_HOLD_MS := 300
## While a release is being tried: key -> drawn or not, over what `_live` says (`_drawn_key_at`).
var _ovl: Dictionary = {}

func _ready() -> void:
	# В РЕДАКТОРЕ НОДА НЕ ТРОГАЕТ НИЧЕГО САМА. Скрипт @tool ради превью (см. preview_build), а
	# всякая правка свойств отсюда пометила бы сцену изменённой и однажды сохранилась.
	if Engine.is_editor_hint():
		return
	collision_layer = 1
	collision_mask = 0
	await get_tree().process_frame
	_apply_haze()
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
	# A NEW WORLD STARTS ON THE NEAREST PLAIN (start_point, world_persist._fresh_start moves the
	# machine there): wherever the scene opened could be a canyon floor or a mountainside.
	await setup_procedural(seed_value, start, game != null and saved == null and not flat_ground)

func _set_biomes(v: TerrainBiomes) -> void:
	biomes = v
	_push_switches()
	_push_biomes()

func _push_switches() -> void:
	if biomes == null:
		return
	biomes.desert_on = desert_enabled
	biomes.canyon_on = canyons_enabled
	biomes.mountains_on = mountains_enabled
	biomes.salt_on = salt_flats_enabled

## The haze's strength is a GLOBAL every hazed shader reads. In the world `Main._apply_view` owns it
## (the range follows the draw distance) and asks `haze_strength`; with no Main (the menu) the map
## writes the project's own range with its strength. Never READ the global back at run time:
## `global_shader_parameter_get` is editor-only and prints an error on every call.
func _apply_haze() -> void:
	if Engine.is_editor_hint() or not is_inside_tree():
		return
	var main: Node = get_node_or_null("/root/Main")
	if main != null and main.has_method("_apply_view"):
		main._apply_view()
		return
	var h: Vector4 = _haze_default()
	h.z = haze_strength()
	RenderingServer.global_shader_parameter_set(&"haze_range", h)

func _haze_default() -> Vector4:
	var d = ProjectSettings.get_setting("shader_globals/haze_range", null)
	if d is Dictionary and d.get("value") is Vector4:
		return d["value"]
	return Vector4(150.0, 750.0, 1.0, 0.0)

func haze_strength() -> float:
	return _haze_default().z if haze_enabled else 0.0

func _biomes() -> TerrainBiomes:
	if biomes == null:
		biomes = TerrainBiomes.new()
		_push_switches()
	return biomes

# ─────────────────────────────────────────────────────────────────────────────
# Генератор
# ─────────────────────────────────────────────────────────────────────────────

## THE GROUND IS BUILT ON THE NATURAL PRESET, the same numbers for the world and the menu backdrop.
## No sliders of its own on purpose: a second copy of these numbers is another landscape in one world.
func _proc_params() -> Dictionary:
	return LiteTerrainGen.natural_params(_biomes())

## WHERE A NEW WORLD'S MACHINE STANDS (world space), or null: a saved world comes back where it was.
var start_point: Variant = null

## THE NEAREST PLAIN TO `from` (local XZ, the generator's own points; the player's call: "spawning in
## a canyon is random and awkward - only on the nearest plains"). Rings PLAIN_STEP apart out to
## PLAIN_MAX, PLAIN_DIRS points a ring, the first that is no canyon and no mountain (masks under
## PLAIN_MASK) and level across PLAIN_SPAN (heights within PLAIN_RISE). Masks first: they are three
## noise reads, a height is five generator calls. The seed decides it, so a world always opens on the
## same spot. None found - the best-scored point seen, never the canyon itself.
const PLAIN_STEP := 40.0
const PLAIN_MAX := 2400.0
const PLAIN_DIRS := 16
const PLAIN_MASK := 0.05
const PLAIN_SPAN := 14.0
const PLAIN_RISE := 2.0
func _plain_near(from: Vector3) -> Vector3:
	return _plain_search(from, PLAIN_MAX)[1]

## THE NEAREST PLAIN WITHIN `reach` of a world point, or null: the respawn's question
## (`camera_controller._respawn_point`), the same rule a new world opens by. Flat ground is all plain.
func plain_near(from: Vector3, reach: float) -> Variant:
	if _gen == null:
		return null
	if flat_ground:
		return from
	var local: Vector3 = global_transform.affine_inverse() * from
	var got: Array = _plain_search(local, reach)
	if not got[0]:
		return null
	var p: Vector3 = got[1]
	return global_transform * Vector3(p.x, _gen.height_at(p.x, p.z), p.z)

## [found a plain, the point]: the first plain on rings `PLAIN_STEP` apart out to `reach`, else the
## least bad point seen.
func _plain_search(from: Vector3, reach: float) -> Array:
	var b := _biomes()
	var nz: Callable = b.noise
	var best := from
	var best_score := INF
	var r := 0.0
	while r <= reach:
		var n: int = 1 if r == 0.0 else PLAIN_DIRS
		for i in n:
			var a := TAU * float(i) / float(n)
			var p := Vector2(from.x + cos(a) * r, from.z + sin(a) * r)
			var bad: float = b.canyon_mask(p, nz) + b.mountain_mask(p, nz)
			if bad > PLAIN_MASK and bad >= best_score:
				continue
			var lo := INF
			var hi := -INF
			for dz in [-1, 0, 1]:
				for dx in [-1, 0, 1]:
					var h: float = _gen.height_at(p.x + dx * PLAIN_SPAN * 0.5, p.y + dz * PLAIN_SPAN * 0.5)
					lo = minf(lo, h)
					hi = maxf(hi, h)
			if bad <= PLAIN_MASK and hi - lo <= PLAIN_RISE:
				return [true, Vector3(p.x, from.y, p.y)]
			var score: float = bad + (hi - lo) / PLAIN_RISE
			if score < best_score:
				best_score = score
				best = Vector3(p.x, from.y, p.y)
		r += PLAIN_STEP
	return [false, best]

## Мир поднимается ЗДЕСЬ И СРАЗУ: считать заранее нечего, первый чанк родится к первому кадру.
## around — где стоит игрок; вокруг неё и строим первое кольцо.
func setup_procedural(seed_value: int, around: Vector3 = Vector3.ZERO, find_plain: bool = false) -> void:
	var gen := LiteTerrainGen.new()
	add_child(gen)
	gen.gen_seed = seed_value
	gen.apply_params(_proc_params())
	gen.flat = flat_ground
	gen.begin_sampling(_biomes())
	_gen = gen
	if find_plain:
		around = _plain_near(around)
		start_point = global_transform * Vector3(around.x, _gen.height_at(around.x, around.z), around.z)
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

## СКОЛЬКО ЗЕМЛИ ИМЕТЬ ДО ТОГО, КАК ПОКАЗАТЬ ХОТЬ ЧТО-ТО, в чанках в каждую сторону: 2 — это 5×5
## по 16 м, то есть 80 м вокруг точки старта. Поле, а не константа, потому что это решение
## СЦЕНЫ, а не движка: игре нужна земля под колёсами во все стороны от машины, которая сейчас
## поедет, а фону меню — пятачок под двумя машинами у начала координат (menu_stage_3d ставит 1),
## и каждый лишний чанк здесь это те же миллисекунды ожидания под экраном.
var ready_ring: int = 2

## ДОКУДА ЖДЁМ ЗЕМЛЮ ПЕРЕД ТЕМ, КАК СНЯТЬ ЭКРАН ЗАГРУЗКИ, в метрах от камеры. Больше — дольше
## вход, но меньше пустоты вокруг в первый кадр.
var ready_view: float = 192.0

## Ждём ЗЕМЛЮ ПОД ИГРОКОМ — квадрат чанков уровня 0 вокруг точки и их тайлы коллизии, — и
## больше ничего. Остальное кольцо к этому моменту уже в очереди (его просит _process), но ждать
## его под экраном загрузки незачем: оно доедет за спиной у затемнения. Пока условием выхода была
## пустая очередь, загрузка держалась до последнего узла на всю дальность видимости.
func _build_around(around: Vector3, with_collision: bool = true) -> void:
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

## СНЯТЬ КАРТУ СО СЧЁТА. Зовёт тот, кто собирается её освободить: задания пула пишут в массивы,
## живущие в этой ноде, и без остановки допишут в уничтоженные. Waiting for the running group is
## the whole stop: nothing else reads the generator once it is done.
func stop_generation() -> void:
	_hlod_stop()
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
	return Vector2i(WORLD_CELLS, WORLD_CELLS) if terrain_is_ready else Vector2i.ZERO

## ЗЕМЛЯ В МИРОВОЙ ТОЧКЕ: генератор плюс правки. Единственная дверь — и меш, и коллизия, и
## запрос высоты снаружи идут через неё, иначе площадка была бы ровной только на вид.
func _ground_at(wx: float, wz: float, edits: Array) -> float:
	return _edit_h(_gen.height_at(wx, wz), wx, wz, edits)

## Запомненная высота в УЗЛЕ СЕТКИ. Спрашивают её десятки раз за кадр и почти всегда рядом с
## тем же местом, а один расчёт — это пять выборок шума и три маски биома.
var _memo: Dictionary = {}
const MEMO_CAP := 1 << 16

## A CELL A BUILT LEVEL-0 CHUNK ALREADY HOLDS IS READ FROM IT (`_hc`, the heights its mesh or its
## collision tile was cut from, edits included), and the generator is asked only for a cell no such
## chunk covers. A new cell from the generator costs ~364 us on the optimize=none build against
## ~16 us for a remembered one, and every machine that moves meets new cells every tick - and level-0
## chunks and collision tiles stand exactly where machines drive.
func _memo_h(cx: int, cz: int) -> float:
	var k: int = ((cx & 0x3FFFFFF) << 26) | (cz & 0x3FFFFFF)
	var v = _memo.get(k)
	if v != null:
		return v
	if _memo.size() > MEMO_CAP:
		_memo.clear()
	var h: float
	var gx: int = floori(float(cx) / CHUNK)
	var gz: int = floori(float(cz) / CHUNK)
	var built = _hc.get(_key(0, gx, gz))
	if built != null and (built as PackedFloat32Array).size() == APRON * APRON:
		h = (built as PackedFloat32Array)[(cz - gz * CHUNK + 1) * APRON + (cx - gx * CHUNK + 1)]
	else:
		h = _ground_at(float(cx), float(cz), _flat_edits)
	_memo[k] = h
	return h

## The height at a whole-metre node of the grid, in the node's own axes: one remembered read where
## `terrain_height_at` reads four corners. For callers that only need the ground's shape (a slope).
func cell_height(cx: int, cz: int) -> float:
	return _memo_h(cx, cz) if _gen != null else 0.0

## Высота под мировой точкой. Билинейно по четырём узлам клетки — ровно так же, как её описывает
## меш и режет коллизия, поэтому колесо и картинка не расходятся.
func terrain_height_at(world_pos: Vector3) -> float:
	if _gen == null:
		return 0.0
	var xf: Transform3D = global_transform
	var p: Vector3 = world_pos if xf == Transform3D.IDENTITY else xf.affine_inverse() * world_pos
	var x0 := int(floor(p.x))
	var z0 := int(floor(p.z))
	var tx: float = p.x - float(x0)
	var tz: float = p.z - float(z0)
	var h00 := _memo_h(x0, z0)
	var h10 := _memo_h(x0 + 1, z0)
	var h01 := _memo_h(x0, z0 + 1)
	var h11 := _memo_h(x0 + 1, z0 + 1)
	var h: float = lerpf(lerpf(h00, h10, tx), lerpf(h01, h11, tx), tz)
	return h if xf == Transform3D.IDENTITY else (xf * Vector3(p.x, h, p.z)).y

## THE GROUND UNDER A WHEEL: (height, dh/dx, dh/dz) at a world point, from the same four cell
## corners `terrain_height_at` reads - the slope is that bilinear patch's own, so a wheel's normal
## and its height agree. It answers what a ray on layer 1 used to (the collision tile is cut from
## these very heights): a ray into Jolt's heightfield cost 46.8 us on the booted world against
## ~16 us here, and the two agreed within 8 mm over 300 points (`MachineBody._check_ground`).
func ground_sample(world_pos: Vector3) -> Vector3:
	if _gen == null:
		return Vector3.ZERO
	var xf: Transform3D = global_transform
	var p: Vector3 = world_pos if xf == Transform3D.IDENTITY else xf.affine_inverse() * world_pos
	var x0 := int(floor(p.x))
	var z0 := int(floor(p.z))
	var tx: float = p.x - float(x0)
	var tz: float = p.z - float(z0)
	var h00 := _memo_h(x0, z0)
	var h10 := _memo_h(x0 + 1, z0)
	var h01 := _memo_h(x0, z0 + 1)
	var h11 := _memo_h(x0 + 1, z0 + 1)
	var h: float = lerpf(lerpf(h00, h10, tx), lerpf(h01, h11, tx), tz)
	if xf != Transform3D.IDENTITY:
		h = (xf * Vector3(p.x, h, p.z)).y
	return Vector3(h, lerpf(h10 - h00, h11 - h01, tz), lerpf(h01 - h00, h11 - h10, tx))

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

## Edits out and back in (the world save); the format older saves already carry.
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
## THE LEAF SET, NOT THE FRAME: a neighbour off the screen is still drawn at its level the moment
## the camera turns to it. Asked of `_want`, it read as "nothing there", the node was built
## unsnapped, and every turn of the camera re-stitched the frame's edge twice over.
func _level_of(bcx: int, bcz: int) -> int:
	for l in MAX_LOD + 1:
		if _leaf_set.has(_key(l, bcx >> l, bcz >> l)):
			return l
	return -1

## ЧТО У НАС ПО ЭТУ СТОРОНУ: насколько сосед КРУПНЕЕ — к его решётке надо притянуть край.
## A coarser node never hears of a finer neighbour, so a level change re-stitches only the side
## that snaps. The grass needs no bit here any more (glsl.gdshader: the same lift on every level).
const SIDE_BITS := 8

## `drawn`: ask what is DRAWN there (`_drawn_key_at`) instead of the leaf set, and answer -1 when
## nothing in the frame is drawn on that side - a side with nothing across it cannot crack.
func _side_info(lod: int, gx: int, gz: int, dx: int, dz: int, drawn: bool = false) -> int:
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
	var seen := false
	for p in [a, b]:
		var l: int
		if drawn:
			# Drawn and in the frame: a crack against ground nobody can see is no reason to wait.
			var dk := _drawn_key_at(p.x, p.y)
			l = _key_lod(dk) if dk != -1 and _in_frame_key(dk) else -1
		else:
			l = _level_of(p.x, p.y)                  # -1: там ничего не рисуется — шва нет
		if l >= 0:
			seen = true
		if l > lod:
			k = maxi(k, l - lod)
	if drawn and not seen:
		return -1
	return mini(k, 4)

## THE NODE DRAWN OVER A BASE CHUNK RIGHT NOW: a live one no replacement has covered, as the overlay
## of a release being tried has it. The leaf set says what the ground is going to be; this is what
## stands there while it gets there.
func _drawn_key_at(bcx: int, bcz: int) -> int:
	for l in MAX_LOD + 1:
		var k: int = (l << 40) | (((bcx >> l) & 0xFFFFF) << 20) | ((bcz >> l) & 0xFFFFF)
		if _ovl.has(k):
			if _ovl[k]:
				return k
			continue
		var n = _live.get(k)
		if n != null and not n.get("cov", false):
			return k
	return -1

## Does a mesh built with `sig` meet whatever is drawn round it? Sides with nothing across are free.
const SIDES := [Vector2i(0, -1), Vector2i(0, 1), Vector2i(-1, 0), Vector2i(1, 0)]

func _fits_drawn(lod: int, gx: int, gz: int, sig: int) -> bool:
	for s in 4:
		var d: int = _side_info(lod, gx, gz, SIDES[s].x, SIDES[s].y, true)
		if d >= 0 and d != ((sig >> (SIDE_BITS * s)) & 0xF):
			return false
	return true

## Is other ground drawn over this node's area - the coarse node it splits out of, or the finer
## ones it merges? Then it is a REPLACEMENT, and goes up together with its seams.
func _area_drawn(lod: int, gx: int, gz: int) -> bool:
	return _drawn_ancestor(lod, gx, gz) != -1 or not _drawn_under(lod, gx, gz).is_empty()

func _drawn_ancestor(lod: int, gx: int, gz: int) -> int:
	for l in range(lod + 1, MAX_LOD + 1):
		var k: int = (l << 40) | (((gx >> (l - lod)) & 0xFFFFF) << 20) | ((gz >> (l - lod)) & 0xFFFFF)
		var n = _live.get(k)
		if n != null and not n.get("cov", false):
			return k
	return -1

## Четыре соседа в одном числе, по байту на сторону: север, юг, запад, восток.
func _signature(lod: int, gx: int, gz: int) -> int:
	return _side_info(lod, gx, gz, 0, -1) \
		| (_side_info(lod, gx, gz, 0, 1) << SIDE_BITS) \
		| (_side_info(lod, gx, gz, -1, 0) << (SIDE_BITS * 2)) \
		| (_side_info(lod, gx, gz, 1, 0) << (SIDE_BITS * 3))

## A SPLIT GOES UP WHOLE: every leaf under the node it replaces is built, not only the ones in the
## frame. The coarse node is hidden only once all of its area is covered, and until then it and the
## children already up were drawn over each other, the children's edges against its coarse one.
func _enqueue_under(lod: int, gx: int, gz: int) -> void:
	var cl := lod - 1
	for dz in 2:
		for dx in 2:
			var cx := gx * 2 + dx
			var cz := gz * 2 + dz
			if _aabb_dist2(_node_aabb(cl, cx, cz), _leaf_at) > view_distance * view_distance:
				continue
			var ck := _key(cl, cx, cz)
			if _leaf_set.has(ck):
				if not _live.has(ck) and not _staged.has(ck):
					_enqueue_mesh(cl, cx, cz, _signature(cl, cx, cz))
			elif cl > 0:
				_enqueue_under(cl, cx, cz)

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
var _leaf_set: Dictionary = {}                # the same keys, for _level_of
## Bumped with every new set of leaves: a live node's seams are checked once per set (`gen`).
var _leaf_gen: int = 0
var _leaf_box := PackedFloat32Array()         # по 4 на лист: minx, minz, maxx, maxz
var _leaf_at: Vector3 = Vector3(1e9, 1e9, 1e9)
var _leaf_vd: float = -1.0
const LEAF_MOVE2 := 256.0                     # 16 м, один базовый чанк
## New relief rebuilds the leaves at most this often: a region seen for the first time is split by
## distance, and only once its leaves are built does the sub-pixel rule know enough to merge them.
const RELIEF_REBUILD_MS := 1000
var _leaf_ms: int = 0

## cull = false — берём всё вокруг точки, без отсечения по кадру. Нужно входу в сохранённый мир:
## земля строится вокруг машины, а камера в этот момент ещё смотрит из начала сцены.
func _select(at: Vector3, cull: bool = true) -> void:
	var mx: float = at.x - _leaf_at.x
	var mz: float = at.z - _leaf_at.z
	# По высоте не сверяемся: расстояние до узла меряется по земле (см. _aabb_dist2), и подъём
	# камеры на орбите набор листьев не меняет.
	var now_ms: int = Time.get_ticks_msec()
	if _leaf_vd != view_distance or mx * mx + mz * mz > LEAF_MOVE2 \
			or (_relief_new and now_ms - _leaf_ms > RELIEF_REBUILD_MS):
		_relief_new = false
		_leaf_ms = now_ms
		_measure_px()
		_build_leaves(at)
	_want.clear()
	var n: int = _leaf_keys.size()
	if not (cull and is_instance_valid(_cam)):
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
	_leaf_gen += 1
	_leaf_keys.clear()
	_leaf_set.clear()
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
	if lod > 0 and d2 < split * split and not _subpixel(lod, gx, gz, cam, d2, span):
		var cx := gx * 2
		var cz := gz * 2
		_descend(lod - 1, cx, cz, cam)
		_descend(lod - 1, cx + 1, cz, cam)
		_descend(lod - 1, cx, cz + 1, cam)
		_descend(lod - 1, cx + 1, cz + 1, cam)
		return
	var key: int = (lod << 40) | ((gx & 0xFFFFF) << 20) | (gz & 0xFFFFF)
	_leaf_keys.append(key)
	_leaf_set[key] = true
	_leaf_box.append(x0)
	_leaf_box.append(z0)
	_leaf_box.append(x1)
	_leaf_box.append(z1)

## Would this node's CHILDREN draw sub-pixel cells? (see SUBPX_MIN) Unknown relief answers no: the
## node then splits as distance says, its children are built, and their relief decides next time.
func _subpixel(lod: int, gx: int, gz: int, cam: Vector3, d2: float, span: float) -> bool:
	if _px_per_rad <= 0.0 or d2 < SUBPX_NEAR * SUBPX_NEAR:
		return false
	var d: float = sqrt(d2)
	var dist_lod: int = int(floor(log(d / (float(CHUNK) * LOD_QUALITY)) / log(2.0))) if d > CHUNK * LOD_QUALITY else 0
	if lod - dist_lod > SUBPX_EXTRA:
		return false
	var r = _relief_of(lod, gx, gz)
	if r == null:
		return false
	var lo: float = (r as Vector2).x
	var hi: float = (r as Vector2).y
	var gap: float = maxf(maxf(lo - cam.y, cam.y - hi), 0.0)
	var d3: float = sqrt(d2 + gap * gap)
	var face: float = clampf(gap / d3 + (hi - lo) / span, 0.0, 1.0)
	var cell: float = float(1 << (lod - 1))
	return cell * _px_per_rad * face / d3 < SUBPX_MIN

## A node's height range: its own built heights, else its four children's, else the nearest built
## ancestor's (wider, so it splits sooner - the safe side). Cached; `_hc` is pruned, this is not read
## for anything that has to be exact.
var _relief: Dictionary = {}
const RELIEF_CAP := 16384
## Set when ground landed that told the relief something new: the leaves are rebuilt for it.
var _relief_new: bool = false
var _px_per_rad: float = 0.0

func _relief_own(key: int) -> Variant:
	var r = _relief.get(key)
	if r != null:
		return r
	var h = _hc.get(key)
	if h == null or (h as PackedFloat32Array).is_empty():
		return null
	var lo := INF
	var hi := -INF
	for v in (h as PackedFloat32Array):
		lo = minf(lo, v)
		hi = maxf(hi, v)
	if _relief.size() > RELIEF_CAP:
		_relief.clear()
	_relief[key] = Vector2(lo, hi)
	return _relief[key]

func _relief_of(lod: int, gx: int, gz: int) -> Variant:
	var own = _relief_own(_key(lod, gx, gz))
	if own != null:
		return own
	var lo := INF
	var hi := -INF
	var all := true
	for dz in 2:
		for dx in 2:
			var c = _relief_own(_key(lod - 1, gx * 2 + dx, gz * 2 + dz))
			if c == null:
				all = false
				break
			lo = minf(lo, (c as Vector2).x)
			hi = maxf(hi, (c as Vector2).y)
		if not all:
			break
	if all:
		_relief[_key(lod, gx, gz)] = Vector2(lo, hi)
		return Vector2(lo, hi)
	for l in range(lod + 1, MAX_LOD + 1):
		var a = _relief_own(_key(l, gx >> (l - lod), gz >> (l - lod)))
		if a != null:
			return a
	return null

## Pixels per radian of the camera the ground is drawn for, at the 3D buffer's real resolution
## (`scaling_3d_scale`): a lower render scale makes the same cell fewer pixels.
func _measure_px() -> void:
	if not is_instance_valid(_cam):
		return
	var vp := _cam.get_viewport()
	var h: float = vp.get_visible_rect().size.y * vp.scaling_3d_scale
	_px_per_rad = h / (2.0 * tan(deg_to_rad(_cam.fov) * 0.5))

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
	# (см. FRUSTUM_MARGIN). По номеру в массиве — нельзя: порядок плоскостей это деталь движка, а
	# нормаль говорит сама за себя.
	_cam_fwd_local = (inv.basis * (-_cam.global_transform.basis.z)).normalized()
	_frame_memo.clear()
	_pl.resize(18)
	_pi.resize(12)
	var i := 0
	for raw in _cam.get_frustum():
		if i == 6:
			break
		var p: Plane = inv * (raw as Plane)
		var nn: Vector3 = p.normal
		# Ближней и дальней — точно, без запаса: плюс у ближней это земля за спиной.
		var m: float = 0.0 if absf(nn.dot(_cam_fwd_local)) > AXIAL_DOT else FRUSTUM_MARGIN
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
	var q = _queued.get(key)
	if q != null:
		# Still waiting in the queue: build it for the newest neighbours. One the pool has taken is
		# read by a worker thread and is left alone; it is re-asked when it lands.
		if q is Dictionary and not q.get("started", false):
			q["sig"] = sig
		return
	var span := float(CHUNK << lod)
	var job := {
		"kind": JOB_MESH, "key": key, "lod": lod, "gx": gx, "gz": gz, "sig": sig,
		"edits": _edits_in(gx * span, gz * span, span),
		# Середина узла — по ней очередь потом сортируется от камеры (см. _sort_queues).
		"cx": gx * span + span * 0.5, "cz": gz * span + span * 0.5, "d2": 0.0,
	}
	_queued[key] = job
	_jobs.append(job)

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
	_batch = _col_jobs.slice(0, BUILD_BATCH)
	_col_jobs = _col_jobs.slice(_batch.size())
	if _batch.size() < BUILD_BATCH:
		var rest: int = BUILD_BATCH - _batch.size()
		_batch.append_array(_jobs.slice(0, rest))
		_jobs = _jobs.slice(mini(rest, _jobs.size()))
	for j in _batch:
		j["started"] = true                      # a worker reads it from here on (_enqueue_mesh)
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

## СЧИТАТЬ МОЖНО ПАЧКОЙ, А ПРИЗЕМЛЯТЬ — НЕТ. Потоки считают BUILD_BATCH чанков параллельно, и
## это правильно: считают они в своих слайсах и никому не мешают. А вот приземление идёт на
## ГЛАВНОМ потоке и стоит дорого на каждый чанк: ArrayMesh, заливка вершин в GPU, новый узел в
## дереве сцены. Двадцать четыре таких в одном кадре — это замеренные игроком 30 fps на месте
## против 22 при движении по новой земле.
##
## Поэтому результаты кладутся В ОЧЕРЕДЬ, а из неё в кадр уходит не больше APPLY_BUDGET штук.
## Общее время то же, спайк размазан.
##
## КОЛЛИЗИЯ ИДЁТ ВНЕ БЮДЖЕТА. Тайл — это то, по чему едет машина; задержать его на кадр значит
## дать ей провалиться. Меш — это то, на что смотрят, и он подождёт.
const APPLY_BUDGET := 4
var _apply_q: Array = []

func _apply_batch() -> void:
	for i in _batch.size():
		var job: Dictionary = _batch[i]
		var res = _out[i]
		if res == null:
			continue
		var key: int = job["key"]
		_hc[key] = res["heights"]
		if int(job["lod"]) >= 2 and not _relief.has(key):
			_relief_new = true             # near ground is never merged for size (SUBPX_NEAR)
		if job["kind"] == JOB_COLL:
			_queued.erase(key | (1 << 50))
			_make_tile(key, job["gx"], job["gz"], res["heights"])
			continue
		_apply_q.append({"job": job, "mesh": res["mesh"]})
	_batch.clear()
	_out.clear()
	_prune_heights()

## Приземляем по APPLY_BUDGET мешей за кадр. Пока очередь не пуста, новую пачку в пул не
## запускаем (см. _job_tick): иначе на быстрой езде очередь росла бы быстрее, чем разбирается,
## и земля отставала бы всё сильнее, а память — всё выше.
func _drain_apply() -> void:
	# ПОКА ИДЁТ ЗАГРУЗКА — БЕЗ БЮДЖЕТА. Там экран всё равно закрыт фейдом, сглаживать нечего, а
	# нужна максимальная пропускная способность: игрок смотрит на полосу загрузки, а не на кадры.
	# Бюджет включается, когда земля готова и на неё начали смотреть.
	var n: int = _apply_q.size() if not terrain_is_ready else mini(APPLY_BUDGET, _apply_q.size())
	for i in n:
		var e: Dictionary = _apply_q.pop_front()
		var job: Dictionary = e["job"]
		_queued.erase(int(job["key"]))
		_place_mesh(int(job["key"]), job, e["mesh"])

func _place_mesh(key: int, job: Dictionary, arrays: Array) -> void:
	if arrays.is_empty():
		var gone = _live.get(key)
		if gone != null and is_instance_valid(gone["inst"]):
			gone["inst"].queue_free()
		_live.erase(key)
		_drop_staged(key)
		_hlod_dirty = true
		return
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays[0])
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.position = Vector3(job["gx"] * (CHUNK << job["lod"]), 0.0, job["gz"] * (CHUNK << job["lod"]))
	mi.custom_aabb = arrays[1]
	mi.material_override = _mat
	# ЗЕМЛЯ ТЕНЬ НЕ ОТБРАСЫВАЕТ, ТОЛЬКО ПРИНИМАЕТ. Замер на устройстве: с тенями 17 fps, без них
	# 25 — треть кадров за одну настройку. Тени и так настроены скупо (один сплит, жёсткие, карта
	# 1024), значит цена не в качестве, а в том, ЧТО в карту рисуется: ближние два уровня это
	# десятки тысяч треугольников земли против пары тысяч у машин.
	#
	# Тень, которую игрок реально видит, — это тень МАШИНЫ на земле, и она остаётся. Уходит
	# собственная тень рельефа: гора перестаёт затенять долину. Потеря настоящая и признана.
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.visible = false
	add_child(mi)
	var entry := {"inst": mi, "sig": job["sig"], "lod": job["lod"], "gx": job["gx"], "gz": job["gz"],
			"seen": float(Time.get_ticks_msec()) * 0.001}
	if int(job["lod"]) >= HLOD_MIN_LOD and int(job["lod"]) <= HLOD_SPAN_LOD:
		entry["arr"] = arrays[0]           # the cluster merges these (HLOD), never re-reads the GPU
		entry["aabb"] = arrays[1]
	# Loading: the screen is behind the fade and nothing is drawn yet - straight in.
	if not terrain_is_ready:
		_go_live(key, entry)
		return
	# A RESTITCH, or FRESH GROUND (nothing else drawn over its area), THAT MEETS WHAT IS DRAWN goes up
	# now - fresh ground most of all: until it is up there is no ground there. A finer neighbour of
	# fresh ground already snaps to it: its seams come from the leaves, not from what was drawn.
	# Everything else waits for `_release_held`, which runs once the frame's meshes have landed.
	var lod: int = job["lod"]
	var gx: int = job["gx"]
	var gz: int = job["gz"]
	if (_live.has(key) or not _area_drawn(lod, gx, gz)) and _fits_drawn(lod, gx, gz, int(job["sig"])):
		_go_live(key, entry)
		return
	_drop_staged(key)
	entry["t"] = Time.get_ticks_msec()
	_staged[key] = entry
	_held_dirty = true

## Put a built mesh on screen in place of the node's old one. Успел уехать из кадра, пока считался,
## — всё равно кладём, только скрытым: он уже посчитан, а камера ходит туда-сюда.
func _go_live(key: int, entry: Dictionary) -> void:
	var shown: bool = _want.has(key)
	var old = _live.get(key)
	if old != null:
		if old.get("cov", false):
			entry["cov"] = true            # still under the ground that covered it
			shown = false
		elif is_instance_valid(old["inst"]):
			shown = shown or (old["inst"] as Node3D).visible
		if is_instance_valid(old["inst"]):
			old["inst"].queue_free()
	(entry["inst"] as Node3D).visible = shown
	_live[key] = entry                     # no "gen": its seams are checked when the frame wants it
	_hlod_dirty = true

func _drop_staged(key: int) -> void:
	var s = _staged.get(key)
	if s != null and is_instance_valid(s["inst"]):
		s["inst"].queue_free()
	_staged.erase(key)

## RELEASE WHAT FITS, once the frame's meshes have landed:
##  - A LEVEL CHANGE GOES UP AS ONE UNIT: the old node and every leaf replacing it (a split), or the
##    new node and the finer ones it replaces (a merge), once all of it is built - and only when
##    every drawn neighbour of its area has a mesh that meets it, its own or a held restitch that
##    goes up in the same frame. Changes that need each other go up together; one waiting on a
##    change still building waits with it (`_unit_fits` over the overlay of all of them).
##  - A RESTITCH, or GROUND WITH NOTHING ELSE DRAWN OVER ITS AREA, goes up alone once its seams meet
##    what is drawn round it.
## A side facing nothing in the frame does not count (`_fits_drawn`): a crack nobody sees is not
## worth holding ground for, and what is off the frame is not built until the camera turns to it.
## `HOLD_MAX_MS` / `FRESH_HOLD_MS` are the last resort - a mesh held that long goes up as it is, as
## all of them used to.
func _release_held() -> void:
	_held_dirty = false
	if _staged.is_empty():
		return
	var units := {}
	for key in _staged:
		if _live.has(key):
			continue                             # a restitch: a support for units, or alone below
		var e: Dictionary = _staged[key]
		var l: int = e["lod"]
		var anc := _drawn_ancestor(l, int(e["gx"]), int(e["gz"]))
		if anc != -1:
			if not units.has(anc):
				var add: Array = []
				var whole: bool = _gather_under(_key_lod(anc), _key_gx(anc), _key_gz(anc), add)
				units[anc] = {"add": add, "hide": [anc]} if whole else {}
			continue
		var under: Array = _drawn_under(l, int(e["gx"]), int(e["gz"]))
		if not under.is_empty():
			units[key] = {"add": [key], "hide": under}  # a merge; with nothing under it, fresh ground
	for uid in units.keys():
		if (units[uid] as Dictionary).is_empty():
			units.erase(uid)
	var used := {}
	var settled := false
	for _pass in 6:
		if units.is_empty():
			break
		_ovl.clear()
		for uid in units:
			for h in units[uid]["hide"]:
				_ovl[h] = false
			for a in units[uid]["add"]:
				_ovl[a] = true
		used.clear()
		var bad: Array = []
		for uid in units:
			if not _unit_fits(uid, units[uid], used):
				bad.append(uid)
		_ovl.clear()
		if bad.is_empty():
			settled = true
			break
		for uid in bad:
			units.erase(uid)
	if not settled:
		units.clear()                            # nothing proven to fit: nothing goes up this pass
	for uid in units:
		var u: Dictionary = units[uid]
		for h in u["hide"]:
			var n = _live.get(h)
			if n != null:
				if is_instance_valid(n["inst"]):
					(n["inst"] as Node3D).visible = false
				n["cov"] = true
				_hlod_dirty = true
		for a in u["add"]:
			_up(a)
	for k in used:
		_up(k)
	var now := Time.get_ticks_msec()
	for key in _staged.keys():
		if not _staged.has(key):
			continue                             # went up with the ground next to it
		var e: Dictionary = _staged[key]
		var l: int = e["lod"]
		var gx: int = e["gx"]
		var gz: int = e["gz"]
		var fresh: bool = not _live.has(key) and not _area_drawn(l, gx, gz)
		if now - int(e["t"]) > (FRESH_HOLD_MS if fresh else HOLD_MAX_MS):
			_up(key)
		elif _live.has(key):
			if _fits_drawn(l, gx, gz, int(e["sig"])):
				_up(key)                         # a restitch: its neighbours are not touched
		elif fresh and _fits_drawn(l, gx, gz, int(e["sig"])):
			_up(key)

## Bring one held mesh (or a leaf already built and covered) up.
func _up(key: int) -> void:
	var e = _staged.get(key)
	if e != null:
		_staged.erase(key)
		if _leaf_set.has(key) or _live.has(key):
			_go_live(key, e)
		elif is_instance_valid(e["inst"]):
			e["inst"].queue_free()               # the leaves moved on while it was building
		return
	var n = _live.get(key)
	if n != null and n.get("cov", false):
		n["cov"] = false
		_hlod_dirty = true
		if is_instance_valid(n["inst"]):
			(n["inst"] as Node3D).visible = _want.has(key)

## Every leaf under an old node, built (held or live) - false while any is still building.
func _gather_under(lod: int, gx: int, gz: int, add: Array) -> bool:
	var cl := lod - 1
	if cl < 0:
		return false
	for dz in 2:
		for dx in 2:
			var cx := gx * 2 + dx
			var cz := gz * 2 + dz
			var ck := _key(cl, cx, cz)
			if _leaf_set.has(ck):
				if _staged.has(ck) or _live.has(ck):
					add.append(ck)
				else:
					return false
			elif _aabb_dist2(_node_aabb(cl, cx, cz), _leaf_at) > view_distance * view_distance:
				continue                         # past the view: no ground there at all
			elif not _gather_under(cl, cx, cz, add):
				return false
	return true

## The drawn finer nodes over this node's area, two levels down: a merge is one level at a time
## while driving, and a deeper one (a teleport) is left to the hold timeout. Twenty lookups, not a
## pass over every live node for every held mesh.
func _drawn_under(lod: int, gx: int, gz: int) -> Array:
	var out: Array = []
	for d in [1, 2]:
		var l: int = lod - d
		if l < 0:
			break
		var n: int = 1 << d
		for dz in n:
			for dx in n:
				var k: int = (l << 40) | (((gx * n + dx) & 0xFFFFF) << 20) | ((gz * n + dz) & 0xFFFFF)
				var e = _live.get(k)
				if e != null and not e.get("cov", false):
					out.append(k)
	return out

## With the overlay of every unit going up: does this unit's new ground meet what is round it, and
## does every drawn neighbour of its area meet it back - with its own mesh, or a held restitch
## (`used`: it goes up in the same frame)?
func _unit_fits(uid: int, u: Dictionary, used: Dictionary) -> bool:
	for a in u["add"]:
		var e = _staged.get(a)
		if e == null:
			e = _live.get(a)
		if e == null or not _fits_drawn(int(e["lod"]), int(e["gx"]), int(e["gz"]), int(e["sig"])):
			return false
	for n in _drawn_round(uid):
		if _ovl.has(n) or not _in_frame_key(n):
			continue
		var live: Dictionary = _live[n]
		if _fits_drawn(int(live["lod"]), int(live["gx"]), int(live["gz"]), int(live["sig"])):
			continue
		var st = _staged.get(n)
		if st != null and _fits_drawn(int(st["lod"]), int(st["gx"]), int(st["gz"]), int(st["sig"])):
			used[n] = true
			continue
		return false
	return true

## The drawn nodes bordering a node's area, read through the overlay. Probed every quarter of a
## side: leaves next to each other differ by a level at most, so nothing drawn beside a node of
## level L is narrower than a quarter of it even mid-change.
func _drawn_round(key: int) -> Array:
	var n: int = 1 << _key_lod(key)
	var bx: int = _key_gx(key) * n
	var bz: int = _key_gz(key) * n
	var seen := {}
	for i in range(0, n, maxi(1, n >> 2)):
		var k := _drawn_key_at(bx + i, bz - 1)
		if k != -1: seen[k] = true
		k = _drawn_key_at(bx + i, bz + n)
		if k != -1: seen[k] = true
		k = _drawn_key_at(bx - 1, bz + i)
		if k != -1: seen[k] = true
		k = _drawn_key_at(bx + n, bz + i)
		if k != -1: seen[k] = true
	return seen.keys()

## Is this node anywhere in the frame (the planes of the last selection)? Remembered until the
## planes change (`_pack_planes`): a release asks it of the same few nodes many times over.
var _frame_memo: Dictionary = {}

func _in_frame_key(key: int) -> bool:
	if _pl.size() < 18:
		return true
	var hit = _frame_memo.get(key)
	if hit != null:
		return hit
	var span := float(CHUNK << _key_lod(key))
	var x0: float = _key_gx(key) * span
	var z0: float = _key_gz(key) * span
	var inside := true
	for q in 6:
		var q3: int = q * 3
		var bx: float = x0 if _pi[q * 2] == 0 else x0 + span
		var bz: float = z0 if _pi[q * 2 + 1] == 1 else z0 + span
		if _pl[q3] * bx + _pl[q3 + 1] * bz + _pl[q3 + 2] > 0.0:
			inside = false
			break
	_frame_memo[key] = inside
	return inside

## БЛИЖНИЙ КРУГ ДЕРЖИМ ВСЕГДА. Всё, что ближе KEEP_RADIUS к игроку, не выбрасывается ни по
## времени, ни по потолку: это земля, на которую он развернётся через секунду. Остальная память
## работает как было — недавно виденное лежит ещё NODE_GRACE секунд и вытесняется самым старым.
##
## Круг в 320 м это около полутора сотен узлов всех уровней: пятая часть потолка мешей и
## двадцатая — потолка высот. Дёшево ровно потому, что дальние уровни накрывают много одним узлом.
## The menu backdrop keeps less (menu_stage_3d MENU_KEEP).
var keep_radius: float = 320.0

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
			# .r — код края и солончак (см. EDGE_STEP), .g каньон, .b луг, .a горы. Цвет земли
			# живёт в вершинах, шейдер их только читает.
			var edge: int = 1 if (j == 0 or j == VERTS - 1) else (2 if (i == 0 or i == VERTS - 1) else 0)
			# На полигоне масок не спрашиваем вовсе: там один биом по определению, а три маски на
			# вершину — это ровно та работа, ради отсутствия которой земля и сделана ровной.
			cols[vi] = (Color(EDGE_STEP * edge, FLAT_COLOR.g, FLAT_COLOR.b, FLAT_COLOR.a)
					if flat_ground else _biome_colour(b, wp, nz_cb, edge))

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
# HLOD: far leaves drawn as one mesh per cluster
# ─────────────────────────────────────────────────────────────────────────────
## THE FAR GROUND IS DRAWN BY CLUSTER, NOT BY LEAF (the player's call). Every leaf of level
## HLOD_MIN_LOD..HLOD_SPAN_LOD that is drawn (live, not covered) belongs to the cluster of the
## HLOD_SPAN_LOD cell it stands in, and a settled cluster is ONE mesh - the members' own arrays
## concatenated, moved by their offsets - drawn in one call while the members stay in place with their
## render layers at 0 (`MachineBatch`'s trick): everything that reads the leaves (seams, the held level
## changes, `_drawn_key_at`, the occlusion test) sees them as before. The levels are the sub-pixel
## LOD's business; this only decides how many calls draw them.
## A CLUSTER IS NEVER STALE ON SCREEN: at the end of any frame the ground changed (`_hlod_dirty`) the
## members are counted again, and one whose set differs from what its mesh holds is SPLIT at once -
## the mesh hidden, the members drawn by themselves, which is exactly the path that ran before. It is
## merged again once its set has held still HLOD_SETTLE_MS, on a worker thread; a merge that comes back
## for a set that has moved on since is thrown away.
const HLOD_MIN_LOD := 2
const HLOD_SPAN_LOD := 6
const HLOD_SETTLE_MS := 400
var _hlod_dirty: bool = false
## Off: every cluster split, the leaves drawn by themselves (measurements, and a way back).
var hlod_enabled: bool = true
## cluster Vector2i -> {"inst", "built", "want", "since", "task", "job", "members"}
var _clusters: Dictionary = {}

func _hlod_tick() -> void:
	if Engine.is_editor_hint():
		return
	if not hlod_enabled:
		if not _clusters.is_empty():
			_hlod_stop()
		return
	var now: int = Time.get_ticks_msec()
	if _hlod_dirty:
		_hlod_dirty = false
		_hlod_recount(now)
	for ck in _clusters.keys():
		var c: Dictionary = _clusters[ck]
		if c["task"] != -1:
			if not WorkerThreadPool.is_task_completed(c["task"]):
				continue
			WorkerThreadPool.wait_for_task_completion(c["task"])
			c["task"] = -1
			_hlod_land(ck, c)
		elif int(c["want"]) != int(c["built"]) and now - int(c["since"]) >= HLOD_SETTLE_MS:
			_hlod_start(ck, c)
		if c["members"].is_empty() and c["task"] == -1:
			if is_instance_valid(c["inst"]):
				c["inst"].queue_free()
			_clusters.erase(ck)

## Who is in each cluster now; a cluster whose set moved is split this frame.
func _hlod_recount(now: int) -> void:
	var sets: Dictionary = {}
	for key in _live:
		var l: int = _key_lod(key)
		if l < HLOD_MIN_LOD or l > HLOD_SPAN_LOD:
			continue
		var n: Dictionary = _live[key]
		var inst = n["inst"]
		if not is_instance_valid(inst) or not (inst as Node3D).visible or not n.has("arr"):
			continue
		var sh: int = HLOD_SPAN_LOD - l
		var ck := Vector2i(_key_gx(key) >> sh, _key_gz(key) >> sh)
		var e = sets.get(ck)
		if e == null:
			e = {"sig": 0, "m": {}}
			sets[ck] = e
		e["sig"] = int(e["sig"]) + hash([key, (inst as Object).get_instance_id()])
		e["m"][key] = inst
	for ck in sets.keys():
		if not _clusters.has(ck):
			_clusters[ck] = {"inst": null, "built": 0, "want": 0, "since": now, "task": -1, "job": null,
					"members": {}}
	for ck in _clusters.keys():
		var c: Dictionary = _clusters[ck]
		var e = sets.get(ck)
		var sig: int = int(e["sig"]) if e != null else 0
		var mem: Dictionary = e["m"] if e != null else {}
		if sig == int(c["want"]) and sig == int(c["built"]):
			continue
		if sig != int(c["want"]):
			c["want"] = sig
			c["since"] = now
		# split: the mesh goes, everyone draws itself (members that left included)
		if is_instance_valid(c["inst"]):
			(c["inst"] as Node3D).visible = false
		for k in c["members"]:
			var old = c["members"][k]
			if is_instance_valid(old):
				(old as VisualInstance3D).layers = 1
		for k in mem:
			(mem[k] as VisualInstance3D).layers = 1
		c["built"] = -1 if sig != 0 else 0
		c["members"] = mem

## Snapshot the members' arrays and merge them on a worker thread.
func _hlod_start(ck: Vector2i, c: Dictionary) -> void:
	var parts: Array = []
	var origin := Vector3(ck.x * float(CHUNK << HLOD_SPAN_LOD), 0.0, ck.y * float(CHUNK << HLOD_SPAN_LOD))
	for k in c["members"]:
		var n = _live.get(k)
		if n == null or not n.has("arr"):
			c["since"] = Time.get_ticks_msec()       # a member left meanwhile: wait for the recount
			return
		var l: int = _key_lod(k)
		var off := Vector3(_key_gx(k) * float(CHUNK << l), 0.0, _key_gz(k) * float(CHUNK << l)) - origin
		parts.append([n["arr"], off, n["aabb"]])
	if parts.is_empty():
		return
	var job := {"parts": parts, "sig": int(c["want"]), "out": null}
	c["job"] = job
	c["task"] = WorkerThreadPool.add_task(_hlod_merge.bind(job), false, "ChunkTerrain HLOD")

## Worker: one surface out of the members' surfaces. Reads only the arrays handed to it.
func _hlod_merge(job: Dictionary) -> void:
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var cols := PackedColorArray()
	var idx := PackedInt32Array()
	var box := AABB()
	var first := true
	for p in job["parts"]:
		var arr: Array = p[0]
		var off: Vector3 = p[1]
		var base: int = verts.size()
		var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		var i0: int = verts.size()
		verts.append_array(v)
		for i in v.size():
			verts[i0 + i] += off
		norms.append_array(arr[Mesh.ARRAY_NORMAL])
		cols.append_array(arr[Mesh.ARRAY_COLOR])
		var ix: PackedInt32Array = arr[Mesh.ARRAY_INDEX]
		var j0: int = idx.size()
		idx.append_array(ix)
		for j in ix.size():
			idx[j0 + j] += base
		var b: AABB = (p[2] as AABB)
		b.position += off
		box = b if first else box.merge(b)
		first = false
	var out: Array = []
	out.resize(Mesh.ARRAY_MAX)
	out[Mesh.ARRAY_VERTEX] = verts
	out[Mesh.ARRAY_NORMAL] = norms
	out[Mesh.ARRAY_COLOR] = cols
	out[Mesh.ARRAY_INDEX] = idx
	job["out"] = [out, box]

## Main thread: the merge is put up only if the set it was made of is still the set.
func _hlod_land(ck: Vector2i, c: Dictionary) -> void:
	var job = c["job"]
	c["job"] = null
	if job == null or job["out"] == null or int(job["sig"]) != int(c["want"]):
		c["since"] = Time.get_ticks_msec() - HLOD_SETTLE_MS   # moved on: merge the new set next frame
		return
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, job["out"][0])
	var mi: MeshInstance3D = c["inst"] if is_instance_valid(c["inst"]) else null
	if mi == null:
		mi = MeshInstance3D.new()
		mi.material_override = _mat
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.position = Vector3(ck.x * float(CHUNK << HLOD_SPAN_LOD), 0.0, ck.y * float(CHUNK << HLOD_SPAN_LOD))
		add_child(mi)
		c["inst"] = mi
	mi.mesh = mesh
	mi.custom_aabb = job["out"][1]
	mi.visible = true
	for k in c["members"]:
		var m = c["members"][k]
		if is_instance_valid(m):
			(m as VisualInstance3D).layers = 0
	c["built"] = int(job["sig"])

func _hlod_stop() -> void:
	for ck in _clusters:
		var c: Dictionary = _clusters[ck]
		if c["task"] != -1:
			WorkerThreadPool.wait_for_task_completion(c["task"])
		if is_instance_valid(c["inst"]):
			c["inst"].queue_free()
		for k in c["members"]:
			var m = c["members"][k]
			if is_instance_valid(m):
				(m as VisualInstance3D).layers = 1
	_clusters.clear()

## How many calls the ground costs now: clusters drawn, leaves drawn by themselves (in the frame or not).
func hlod_stats() -> Vector2i:
	var merged := 0
	for ck in _clusters:
		var c: Dictionary = _clusters[ck]
		if is_instance_valid(c["inst"]) and (c["inst"] as Node3D).visible:
			merged += 1
	var alone := 0
	for key in _live:
		var inst = _live[key]["inst"]
		if is_instance_valid(inst) and (inst as Node3D).visible and (inst as VisualInstance3D).layers != 0:
			alone += 1
	return Vector2i(merged, alone)

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
	var r: int = COLLISION_RADIUS
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
		# A machine CRUISING far from the camera is driven on these heights, not by Jolt (enemy_vehicle
		# FAR CRUISE): no ground under it, or every metre it covers adds and frees tiles on this one
		# static body. It asks again for the tile under it before it lands (has_collision_at).
		if body.has_method("is_cruising") and body.is_cruising():
			continue
		# КОРИДОР, А НЕ ТОЧКА: землю просим и там, где тело стоит, и там, где оно окажется через
		# COLLISION_LOOKAHEAD секунд. Тайл теперь считается, и просить его в момент въезда значит
		# въехать в пустоту. Сдвигать окно целиком вперёд нельзя — на большой скорости тело
		# выпало бы из собственного окна.
		var p0: Vector3 = inv * body.global_position
		var p1: Vector3 = p0
		if COLLISION_LOOKAHEAD > 0.0 and body is RigidBody3D:
			p1 += inv.basis * ((body as RigidBody3D).linear_velocity * COLLISION_LOOKAHEAD)
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

## Is a collision tile up under this world point - what a machine coming back from its cruise waits for.
func has_collision_at(world: Vector3) -> bool:
	var p: Vector3 = global_transform.affine_inverse() * world
	return _col.has(_key(0, int(floor(p.x / CHUNK)), int(floor(p.z / CHUNK))))

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
	var c := _biome_colour(b, wp, nz_cb, 0)
	return Vector3(c.g, c.b, c.a)

## THE VERTEX'S BIOMES, one door for the bake and for `biome_at`: r the border code and the salt
## flat (EDGE_STEP / SALT_SPAN), g canyon, b meadow, a mountain. THE SALT FLAT WINS OVER THE CANYON
## in colour as it does in the landform (terrain_gen.carve_at): the canyon's mask is taken by it, or
## a lake bed under a canyon mask was painted terracotta from shore to shore.
func _biome_colour(b: TerrainBiomes, wp: Vector2, nz_cb: Callable, edge: int) -> Color:
	var salt: float = b.salt_mask(wp, nz_cb)
	return Color(EDGE_STEP * edge + SALT_SPAN * salt,
			b.canyon_mask(wp, nz_cb) * (1.0 - salt), b.meadow_mask(wp, nz_cb), b.mountain_mask(wp, nz_cb))

## 0..1: a salt flat at this world point - the mask baked into COLOR.r.
func salt_at(world_pos: Vector3) -> float:
	var b := _biomes()
	var p: Vector3 = global_transform.affine_inverse() * world_pos
	return b.salt_mask(Vector2(p.x, p.z), b.noise)

func _get_material() -> Material:
	if surface_material != null:
		return surface_material
	var m := ShaderMaterial.new()
	m.shader = GROUND_SHADER
	return m

## Свой экземпляр базового материала: параметры пишутся в него, а не в общий ресурс.
## THE FAST GROUND: the ground's own shader as an unshaded variant that lights itself
## (glsl.gdshader, FAST_GROUND). Set while shadows are off (Main._apply_shadows): unshaded receives no
## shadow, and with none to receive the engine's lighting was 12 ms of the phone's 47 ms frame
## (frame_probe, "ground unshaded" against "ground no shadow"). It swaps the SHADER of the one
## material every chunk and HLOD cluster shares, carrying every uniform across.
var fast_ground: bool = false:
	set(v):
		if v == fast_ground:
			return
		fast_ground = v
		_apply_fast_ground()
var _lit_shader: Shader = null
var _fast_shader: Shader = null

func _apply_fast_ground() -> void:
	var sm := _mat as ShaderMaterial
	if sm == null or sm.shader == null:
		return
	if _lit_shader == null:
		_lit_shader = sm.shader
	var to: Shader = _lit_shader
	if fast_ground:
		if _fast_shader == null:
			_fast_shader = Shader.new()
			_fast_shader.code = _lit_shader.code.replace(
					"render_mode diffuse_lambert, specular_disabled;",
					"render_mode unshaded;\n#define FAST_GROUND")
		to = _fast_shader
	if sm.shader == to:
		return
	var keep := {}
	for u in sm.shader.get_shader_uniform_list():
		keep[u["name"]] = sm.get_shader_parameter(u["name"])
	sm.shader = to
	for k in keep:
		sm.set_shader_parameter(k, keep[k])

func _setup_materials(base: Material) -> void:
	if base is ShaderMaterial:
		_mat = base.duplicate()
		(_mat as ShaderMaterial).set_shader_parameter("grass_fade", grass_fade())
		_push_biomes()
		_lit_shader = null
		_fast_shader = null
		if fast_ground:
			_apply_fast_ground()
	else:
		_mat = base

## WHERE THE GRASS FADES OUT, metres from the camera over the ground. A level-0 node meets a level-1
## one anywhere past 44 m and the shader's border rule makes those seams agree; it cannot make a
## level-1 border agree with a level-2 edge, so the lift is gone before level 2 can begin - its split
## distance less twice the leaf hysteresis (the camera is up to a leaf step from the point the leaves
## were cut around, and a node waiting to be split is drawn a while longer).
const GRASS_FADE_BAND := 24.0

func grass_fade() -> Vector2:
	var end: float = float(CHUNK << 2) * LOD_QUALITY - 2.0 * sqrt(LEAF_MOVE2)
	return Vector2(end - GRASS_FADE_BAND, end)

func _push_biomes() -> void:
	if biomes == null:
		return
	if _mat is ShaderMaterial:
		biomes.apply_to_material(_mat as ShaderMaterial, world_height())
		var sm := _mat as ShaderMaterial
		if not grass_lift_enabled:
			sm.set_shader_parameter("grass_height", 0.0)
		if _snow_h < 0.0:
			var s = sm.get_shader_parameter("snow_height")
			_snow_h = float(s) if s != null else 0.3
		sm.set_shader_parameter("snow_height", _snow_h if snow_lift_enabled else 0.0)

var _snow_h := -1.0                  # the material's own snow crust, kept to turn it back on

## THE SUN'S SHADOW CASCADES (sun_shadows.gd), read by the fast ground only: near to far, a map and
## its window each - uv = world XZ * x + yz, w the window's half in metres, 0 for a map not built yet.
## Strength 0 skips the fetch. The maps are handed over only when they change: the near window moves
## every frame of a drive, its map stays the same texture.
const SUN_SHADOW_MAPS := [&"sun_shadow_map", &"sun_shadow_map1", &"sun_shadow_map2"]
const SUN_SHADOW_UVS := [&"sun_shadow_uv0", &"sun_shadow_uv1", &"sun_shadow_uv2"]
var _sun_maps: Array = []
func set_sun_shadows(maps: Array, uvs: Array, strength: float) -> void:
	if not (_mat is ShaderMaterial):
		return
	var m := _mat as ShaderMaterial
	if m != _sun_mat or maps != _sun_maps:
		_sun_mat = m
		_sun_maps = maps.duplicate()
		for k in SUN_SHADOW_MAPS.size():
			m.set_shader_parameter(SUN_SHADOW_MAPS[k], maps[k] if k < maps.size() else null)
	for k in SUN_SHADOW_UVS.size():
		m.set_shader_parameter(SUN_SHADOW_UVS[k], uvs[k] if k < uvs.size() else Vector4.ZERO)
	m.set_shader_parameter(&"sun_shadow_strength", strength if fast_ground and not maps.is_empty() else 0.0)
var _sun_mat: ShaderMaterial = null

## THE GROUND'S HEIGHT OFF ANY NODE WHOSE HEIGHTS ARE STILL HELD (`_hc`), the finest first, NAN where
## none is. `drawn_height` answers only under the frame; this answers wherever ground was built - behind
## the camera, off the frustum, and inside `keep_radius` for good (`_prune_heights` keeps those). The
## sun shadow's ground shade marches over it (`sun_shadows.gd`): on the drawn heights alone nine cells in
## ten of its near grid were empty - everything the camera was not looking at - measured on the real
## driver, 17122 of 19044.
func known_height(wx: float, wz: float) -> float:
	if _gen == null:
		return NAN
	var p: Vector3 = global_transform.affine_inverse() * Vector3(wx, 0.0, wz)
	var bcx: int = floori(p.x / CHUNK)
	var bcz: int = floori(p.z / CHUNK)
	for l in MAX_LOD + 1:
		var hs = _hc.get(_key(l, bcx >> l, bcz >> l))
		if hs != null and (hs as PackedFloat32Array).size() == APRON * APRON:
			var span := float(CHUNK << l)
			var cell := float(1 << l)
			var h: float = _grid_h(hs, (p.x - float(bcx >> l) * span) / cell, (p.z - float(bcz >> l) * span) / cell)
			return (global_transform * Vector3(p.x, h, p.z)).y
	return NAN

## The DRAWN ground's height at a world XZ, NAN where nothing is drawn: what the screen shows, read
## off the heights the drawn node was built from (`_drawn_h`, the occlusion test's own read).
func drawn_height(wx: float, wz: float) -> float:
	if _gen == null:
		return NAN
	var p: Vector3 = global_transform.affine_inverse() * Vector3(wx, 0.0, wz)
	var h: float = _drawn_h(p.x, p.z)
	return h if is_nan(h) else (global_transform * Vector3(p.x, h, p.z)).y

func set_grass_trample(tex: Texture2D, center: Vector2, size: float) -> void:
	if _mat is ShaderMaterial:
		var m := _mat as ShaderMaterial
		m.set_shader_parameter("trample_map", tex)
		m.set_shader_parameter("trample_center", center)
		m.set_shader_parameter("trample_size", size)

func set_corruption_map(tex: Texture2D, center: Vector2, size: float) -> void:
	if _mat is ShaderMaterial:
		var sm := _mat as ShaderMaterial
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
## Is the point `height` over `world_pos` behind the ground, seen from the camera? A ray from the eye
## to it, stepped over the ground: hidden once a step's ground stands `OCCL_BIAS` over the line.
## THE GROUND IS THE ONE THE FRAME DRAWS (`_drawn_h`), not the generator's: a far node samples every
## 2^L m and cuts its peaks, so the true ground hid a vein over a ridge the screen drew lower - and a
## point no near chunk holds was a generator call, ~364 us on the optimize=none build, at every step
## of every ray. That is why this test was off: "a ray over the ground cost more than drawing the
## bush behind the hill". A step over ground with no drawn heights hides nothing.
const OCCL_STEP := 8.0
const OCCL_MAX_STEPS := 28
## Hysteresis: a thing already hidden needs this much more to come back, or it blinks on the edge.
const OCCL_HYST := 0.5
var _no_h := PackedFloat32Array()      # what a point with no drawn heights reads

func is_point_hidden(world_pos: Vector3, height: float = 1.0, was_hidden: bool = false) -> bool:
	if not enable_occlusion_culling or _gen == null:
		return false
	var t0 := _pf_now()
	var hid := _point_hidden(world_pos, height, was_hidden)
	_pf_mark("terrain_occl", t0)
	return hid

func _point_hidden(world_pos: Vector3, height: float, was_hidden: bool) -> bool:
	if not is_instance_valid(_cam):
		_cam = _active_camera()
		if _cam == null:
			return false
	var inv: Transform3D = global_transform.affine_inverse()
	var eye: Vector3 = inv * _cam.global_position
	var top: Vector3 = inv * Vector3(world_pos.x, world_pos.y + maxf(height, 0.1), world_pos.z)
	var dist := eye.distance_to(top)
	if dist < OCCL_MIN_DIST:
		return false
	var steps: int = mini(int(dist / OCCL_STEP), OCCL_MAX_STEPS)
	if steps < 2:
		return false
	# An eye under the drawn ground (a camera pushed into a slope) would see every ray blocked at
	# its first step and empty the world: nothing is hidden from there.
	if _drawn_h(eye.x, eye.z) > eye.y:
		return false
	var bias: float = OCCL_BIAS + (OCCL_HYST if was_hidden else 0.0)
	# The node under the ray is looked up only when the ray leaves it: a far node spans many steps.
	var hs: PackedFloat32Array = _no_h
	var x0 := 0.0
	var z0 := 0.0
	var x1 := -1.0
	var z1 := -1.0
	var cell := 1.0
	for s in range(1, steps):
		var p: Vector3 = eye.lerp(top, float(s) / float(steps))
		if p.x < x0 or p.z < z0 or p.x >= x1 or p.z >= z1:
			var bcx: int = floori(p.x / CHUNK)
			var bcz: int = floori(p.z / CHUNK)
			var k: int = _drawn_key_at(bcx, bcz)
			var l: int = _key_lod(k) if k != -1 else 0
			hs = _hc.get(k, _no_h) if k != -1 else _no_h
			var span := float(CHUNK << l)
			x0 = float(bcx >> l) * span
			z0 = float(bcz >> l) * span
			x1 = x0 + span
			z1 = z0 + span
			cell = float(1 << l)
		if hs.size() != APRON * APRON:
			continue
		if _grid_h(hs, (p.x - x0) / cell, (p.z - z0) / cell) > p.y + bias:
			return true
	return false

## The drawn ground's height at a local point, NAN where nothing drawn has its heights.
func _drawn_h(x: float, z: float) -> float:
	var bcx: int = floori(x / CHUNK)
	var bcz: int = floori(z / CHUNK)
	var k: int = _drawn_key_at(bcx, bcz)
	if k == -1:
		return NAN
	var hs: PackedFloat32Array = _hc.get(k, _no_h)
	if hs.size() != APRON * APRON:
		return NAN
	var l: int = _key_lod(k)
	var span := float(CHUNK << l)
	var cell := float(1 << l)
	return _grid_h(hs, (x - float(bcx >> l) * span) / cell, (z - float(bcz >> l) * span) / cell)

## Bilinear over a node's height grid (APRON², one cell of apron), at grid coordinates inside it.
func _grid_h(hs: PackedFloat32Array, fx: float, fz: float) -> float:
	var i: int = clampi(int(fx), 0, CHUNK - 1)
	var j: int = clampi(int(fz), 0, CHUNK - 1)
	var tx: float = fx - float(i)
	var tz: float = fz - float(j)
	var r0: int = (j + 1) * APRON + i + 1
	var r1: int = r0 + APRON
	return lerpf(lerpf(hs[r0], hs[r0 + 1], tx), lerpf(hs[r1], hs[r1 + 1], tx), tz)

# ─────────────────────────────────────────────────────────────────────────────
# Превью в редакторе
# ─────────────────────────────────────────────────────────────────────────────
## THE SAME GROUND THE GAME WILL SHOW, in the editor's viewport (the inspector's "Build in scene",
## preview_panel.gd): the chunked ground has no height file to look at, so without it the ground and
## what its material's settings do to it could only be seen by running the game.
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
	for key in _staged.keys():
		_drop_staged(key)
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
## NOT AN EXPORT, and never was one on purpose: a camera written into an exported field marks the
## scene changed and is saved one day - node_3d.tscn once carried a path to the EDITOR VIEWPORT's
## camera (`../../../@Node3DEditorViewport@…/@Camera3D@…`), which a running game does not have, and
## the ground was left with no camera at all.
var _ed_cam: Camera3D = null

func set_editor_camera(c: Camera3D) -> void:
	if c != null:
		_ed_cam = c

func _active_camera() -> Camera3D:
	if Engine.is_editor_hint() and is_instance_valid(_ed_cam):
		return _ed_cam
	var vp := get_viewport()
	return vp.get_camera_3d() if vp != null else null

## The clusters are counted AFTER everything that frame moved the ground (landing, holds, the LOD
## tick's covers and retirements), so no cluster is ever drawn over a change for a frame.
func _process(delta: float) -> void:
	_ground_tick(delta)
	if _gen != null:
		_hlod_tick()

func _ground_tick(delta: float) -> void:
	if _gen == null:
		return
	if Engine.is_editor_hint() and not _preview_on:
		return
	_col_tick()
	_job_tick()
	# Held meshes are looked at when something landed or the LOD tick moved the ground, four times a
	# second at most - what they wait for is other meshes landing, and a pass is ~2 ms on the
	# optimize=none build - and twice a second for the ones waiting out their hold.
	_held_check_t -= delta
	if not _staged.is_empty() and _held_check_t <= 0.0 and (_held_dirty or _held_check_t <= -0.25):
		_held_check_t = 0.25
		var th := _pf_now()
		_release_held()
		_pf_mark("terrain_hold", th)
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
	if _lod_timer < (LOD_INTERVAL * 0.25 if stirred else LOD_INTERVAL):
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
	var split_seen := {}
	for key in _want:
		var n = _live.get(key)
		if n == null:
			if _staged.has(key):
				continue                   # built, waiting for the rest of its level change
			var l := _key_lod(key)
			var gx := _key_gx(key)
			var gz := _key_gz(key)
			_enqueue_mesh(l, gx, gz, _signature(l, gx, gz))
			var anc := _drawn_ancestor(l, gx, gz)
			if anc != -1 and not _leaf_set.has(anc) and not split_seen.has(anc):
				split_seen[anc] = true
				_enqueue_under(_key_lod(anc), _key_gx(anc), _key_gz(anc))
			continue
		n["seen"] = now
		n["inst"].visible = true
		n["cov"] = false
	# Сосед сменил уровень — край надо притянуть заново. Бюджет на тик: шов на кадр-другой
	# дешевле пересборки десятков узлов разом. A NODE IS LOOKED AT ONCE PER SET OF LEAVES ("gen"),
	# when the frame wants it: a signature changes only when the leaves do, and computing one for
	# every node in the frame every tick is eight probes of six lookups a node. Scanning every built
	# leaf, off the screen too, was tried - three times the signatures, and the cracks while turning
	# came out the same (measured).
	var left: int = STITCH_BUDGET
	for key in _want:
		if left <= 0:
			break
		var n = _live.get(key)
		if n == null or int(n.get("gen", -1)) == _leaf_gen:
			continue
		var sig := _signature(n["lod"], n["gx"], n["gz"])
		n["gen"] = _leaf_gen
		if sig == int(n["sig"]):
			continue
		var st = _staged.get(key)
		if st != null and int(st["sig"]) == sig:
			continue                       # already built, waiting to go up
		var q = _queued.get(key)
		if q is Dictionary:                # already queued: no budget spent on asking again
			if not q.get("started", false):
				q["sig"] = sig
			continue
		_enqueue_mesh(n["lod"], n["gx"], n["gz"], sig)
		left -= 1
	_retire(now)
	_held_dirty = true
	_hlod_dirty = true
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
	# Covered only by ground the LEAF SET asks for and that is already BUILT. Asked for, because a
	# live node that is itself hidden covers nothing - by it a whole chain would hide. The leaf set,
	# not the frame: a split builds all its children (_enqueue_under), the ones off the screen too,
	# and a built leaf is drawn whether or not it is in the frame.
	# ANY ANCESTOR AND ANY DEPTH BELOW, not only the parent and the four children: a node replaced
	# by leaves two levels finer (a fast drive, a respawn, the sub-pixel rule) was "not covered",
	# stayed drawn over the fine ground - another shape and colour, no collision under it - and near
	# the player nothing is ever dropped, so it stood there until the player drove away (the
	# player's "two maps with different seeds, only one with physics").
	var al := l + 1
	var ax := gx >> 1
	var az := gz >> 1
	while al <= MAX_LOD:
		var ak := _key(al, ax, az)
		if _leaf_set.has(ak):
			return _live.has(ak)                 # стали грубее: накрывает предок
		al += 1
		ax >>= 1
		az >>= 1
	return l > 0 and _covered_below(l, gx, gz)

## Every leaf under (lod, gx, gz) is in the leaf set and built (the node itself not counted).
func _covered_below(lod: int, gx: int, gz: int) -> bool:
	if lod <= 0:
		return false
	for dz in 2:
		for dx in 2:
			var cl := lod - 1
			var cx := gx * 2 + dx
			var cz := gz * 2 + dz
			var ck := _key(cl, cx, cz)
			if _leaf_set.has(ck):
				if not _live.has(ck):
					return false
			elif not _covered_below(cl, cx, cz):
				return false
	return true

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
			n["cov"] = true
		if _near_player(key):
			continue                   # ближний круг не выбрасываем ни по времени, ни по потолку
		if over <= 0 and now - float(n["seen"]) < NODE_GRACE:
			continue
		n["inst"].queue_free()
		_live.erase(key)
		over -= 1
