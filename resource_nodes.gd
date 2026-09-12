extends Node3D
# Раскидывает жилы руды по ВСЕЙ карте. Берёт реальную высоту рельефа у родителя-карты
# (map.terrain_height_at) и ставит жилу на землю; пропускает низины и крутые склоны,
# держит минимальную дистанцию между жилами. Каждая жила — это и StaticBody-узел (логика/
# коллизия), и инстанс в двух MultiMesh (видимый меш + канал шейдера истощения).

@export var resource_nodes: Array[PackedScene]
@export var multimesh_nodes: Array[MultiMeshInstance3D]

## Цвета типов жил = ЦВЕТА МЕТАЛЛОВ, один в один: тип жилы это и есть металл, который из неё
## выйдет (G.Metal), и жила обязана выглядеть тем, что даёт. Список НЕ дублируется здесь и не
## правится в инспекторе — он берётся из G.METAL_COLOR в _ready. Раньше цвета жил жили сами по
## себе, и добавить металл значило поправить два места, забыв одно.
## Новый металл — строка в G.Metal/G.METAL_COLOR (до 8 штук, см. MAX_ORE_TYPES в resource.gdshader).
var ore_colors: Array[Color] = []

## Доля угольных жил (0..1). Угольная жила тёмная и выбрасывает УГОЛЬ (COAL) —
## топливо генератора; слитка у угля нет, процессор его не переплавляет.
@export var coal_chance: float = 0.25
@export var coal_color: Color = Color(0.13, 0.13, 0.15)

@export_group("Расстановка")
## СЧЁТЧИКА ЖИЛ НА ВСЮ КАРТУ БОЛЬШЕ НЕТ: у мира без края нет «всей карты». Плотность задаётся
## на РЕГИОН (VEINS_PER_REGION), и прежние 2000 жил на 1982² — это ровно то число, из которого
## она и выведена. Отступа от края тоже нет: края нет.
@export var min_height: float = 2.0          # ниже — самые днища впадин, не спавним (воды в мире нет)
@export var max_slope: float = 7.0           # разброс высот вокруг точки; выше — обрыв
@export var min_spacing: float = 2.0         # только чтобы жилы не налезали друг на друга

@export_group("Стриминг")
## Радиус вокруг камеры, в котором жилы РЕНДЕРЯТСЯ и активны (есть узел/коллизия для добычи).
## Дальше — только запись в _data, ни ноды, ни инстанса MultiMesh (система не грузится).
@export var render_distance: float = 160.0
## ПОТОЛОК одновременно отрисованных/активных жил = размер буфера MultiMesh и пул слотов.
## В радиусе 160 при 2000 жилах на карту 1982² их ~40-60; 180 — с большим запасом.
@export var max_visible: int = 180
@export var cull_interval: float = 0.25      # как часто пересчитывать стриминг (сек)
## Жилы ЗА СПИНОЙ не держим. Жила — это не только инстанс MultiMesh, но и узел с коллизией и
## своей логикой добычи; за камерой от него нет никакой пользы, а слот в буфере он занимает.
## Отвернулся — отдали слот тому, что впереди, и в радиусе стало видно дальше.
## keep_radius — ближний пузырь: рядом жила активна в любую сторону, иначе та, в которую уже
## вгрызся бур, гасла бы, стоило отвести камеру.
@export var keep_radius: float = 40.0
@export var view_cos: float = -0.15          # чуть шире полусферы перед камерой — край не мигает

# Все жилы карты как данные: {pos, scene, ore_type, coal, slot(-1=не показана), node(null)}.
var _data: Array = []
var _free: Array[int] = []                   # свободные слоты MultiMesh (пул)
var _cull_t: float = 0.0
## Окклюзия спрашивается порциями (см. _process): за тик — 1/OCCL_SLICES списка.
const OCCL_SLICES := 4
const OCCL_VEIN_HEIGHT := 1.5     # высота жилы: её верх и должен выглянуть из-за хребта
var _occl_cursor: int = 0
var _last_fwd: Vector3 = Vector3.FORWARD
# Схлопнутый трансформ (нулевой масштаб) — для «погашенных» слотов MultiMesh.
var ZERO_XFORM := Transform3D(Basis().scaled(Vector3.ZERO), Vector3.ZERO)

# _ready идёт СНИЗУ ВВЕРХ: у детей он вызывается РАНЬШЕ, чем у родителя. Значит на этот
# момент карта ещё не выполнила свой _ready, и требовать от неё готовности сразу нельзя.
# Ждём, пока она начнёт отвечать, и только потом сдаёмся: прежний вариант ругался и
# делал return, из-за чего узел не инициализировался за весь сеанс.
const MAP_WAIT_FRAMES: int = 300      # ~5 секунд при 60 кадрах

func _ready() -> void:
	# До любого await: дальше по коду список нужен и шейдеру, и раздаче типов жилам.
	ore_colors.assign(G.METAL_COLOR)
	var map: Node = await _await_map()
	if map == null:
		push_error("resource_nodes: родитель так и не стал картой (нет terrain_height_at/get_dims)")
		return

	var guard: int = 0
	while map.get_dims().x <= 0 and guard < 300:
		await get_tree().process_frame
		guard += 1
	var dims: Vector2i = map.get_dims()
	if dims.x <= 0:
		push_error("resource_nodes: рельеф так и не загрузился")
		return

	_apply_ore_colors()
	# ЖИЛЫ БОЛЬШЕ НЕ РАСКЛАДЫВАЮТСЯ ОДНИМ КУСКОМ. Пул слотов заводим здесь, а сами жилы рождают
	# регионы по мере того, как игрок к ним подъезжает (_regions_tick).
	_init_slots()
	_regions_tick()

# Заливаем список цветов в шейдер руды (общий материал core.tres → один раз на всех).
func _apply_ore_colors() -> void:
	if ore_colors.is_empty():
		return
	var cols := PackedVector3Array()
	for c in ore_colors + [coal_color]:      # уголь — последний индекс в шейдере
		var lc: Color = c.srgb_to_linear()      # шейдер ждёт линейные RGB
		cols.append(Vector3(lc.r, lc.g, lc.b))
	for mm in multimesh_nodes:
		var mesh: Mesh = mm.multimesh.mesh if mm.multimesh else null
		if mesh is PrimitiveMesh and mesh.material is ShaderMaterial:
			(mesh.material as ShaderMaterial).set_shader_parameter("ore_colors", cols)

# ── РЕГИОНЫ: ЖИЛЫ РОЖДАЮТСЯ КУСКАМИ, А НЕ ВСЕЙ КАРТОЙ СРАЗУ ──────────────────
# Раньше две тысячи жил раскладывались ОДИН РАЗ при загрузке, перебором по всей карте. В мире
# без края так нельзя дважды: перебирать нечего (карта не кончается) и держать нечего (список
# рос бы вместе с пройденным путём).
#
# Поэтому мир нарезан на РЕГИОНЫ по REGION клеток, и каждый рождает свои жилы САМ — из сида мира
# и собственных координат. Отсюда два свойства, ради которых всё и делается: регион всегда даёт
# одни и те же жилы, сколько бы раз игрок в него ни вернулся, и соседний регион можно посчитать,
# ничего не зная про этот.
#
# ВЫСОТУ СПРАШИВАЕМ У КАРТЫ, а она знает только то, что внутри окна. Поэтому регион рождается,
# лишь когда игрок к нему подъехал: снаружи окна ответа всё равно нет.
const REGION := 256
## Сколько жил в регионе. Не на глаз: прежняя плотность — 2000 жил на карту 1982², то есть одна
## на ~1964 клетки². На регион 256² (65 536 клеток²) это ровно тридцать три.
const VEINS_PER_REGION := 33
## На сколько регионов вокруг игрока держим жилы. Один в каждую сторону — это 768 клеток по
## диагонали, вдвое больше дальности отрисовки: жила успевает родиться задолго до того, как её
## станет видно.
const REGION_KEEP := 1

var _regions: Dictionary = {}          # Vector2i региона → Array записей жил
var _region_center := Vector2i(999999, 999999)

## Ключ региона по мировой точке.
func _region_of(gp: Vector3) -> Vector2i:
	return Vector2i(floori(gp.x / REGION), floori(gp.z / REGION))

## Держать вокруг игрока квадрат регионов; ушедшие — забыть вместе с их жилами.
func _regions_tick() -> void:
	var here := _region_of(_player_point())
	if here == _region_center:
		return
	_region_center = here
	var want := {}
	for dz in range(-REGION_KEEP, REGION_KEEP + 1):
		for dx in range(-REGION_KEEP, REGION_KEEP + 1):
			want[here + Vector2i(dx, dz)] = true
	for k in _regions.keys():
		if not want.has(k):
			for v in _regions[k]:
				if int(v["slot"]) >= 0:
					_stream_out(v)          # слот и узел отдаём до того, как забудем запись
			_regions.erase(k)
	for k in want:
		if not _regions.has(k):
			_regions[k] = _build_region(k)
	_rebuild_data()

func _player_point() -> Vector3:
	var pts: Array = G.active_points()
	return pts[0] if not pts.is_empty() else Vector3.ZERO

## _data — это просто ВСЕ жилы живых регионов, склеенные в один список: стриминг ходит по нему
## каждый тик, и перебирать словарь словарей на каждом кадре было бы дороже, чем пересобрать
## список тогда, когда набор регионов реально сменился.
func _rebuild_data() -> void:
	_data.clear()
	for k in _regions:
		_data.append_array(_regions[k])

## Жилы ОДНОГО региона. Своё зерно от сида мира и координат: соседний регион считается
## независимо, а этот всегда даёт одно и то же.
func _build_region(rk: Vector2i) -> Array:
	var map: Node = get_parent()
	if map == null or not map.has_method("terrain_height_at"):
		return []
	var can_biome: bool = map.has_method("biome_at")
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(Vector3i(rk.x, rk.y, int(G.world_seed)))
	var out: Array = []
	var grid: Dictionary = {}
	var cell: float = maxf(min_spacing, 0.001)
	var tries: int = VEINS_PER_REGION * 12
	while out.size() < VEINS_PER_REGION and tries > 0:
		tries -= 1
		var gx: float = float(rk.x * REGION) + rng.randf() * REGION
		var gz: float = float(rk.y * REGION) + rng.randf() * REGION
		var world := Vector3(gx, 0.0, gz)
		var h: float = map.terrain_height_at(world)
		if h < min_height:
			continue
		var lp: Vector3 = to_local(Vector3(gx, h + 0.25, gz))
		if _slope_at(map, lp.x, lp.z) > max_slope:
			continue
		if _too_close_hashed(grid, cell, lp):
			continue
		var key := Vector2i(floori(lp.x / cell), floori(lp.z / cell))
		if not grid.has(key):
			grid[key] = [] as Array[Vector3]
		(grid[key] as Array).append(lp)
		var coal: bool = rng.randf() < coal_chance
		var ore_type: int = ore_colors.size() if coal else _metal_for(lp, map, can_biome, rng)
		if not _ore_enabled(ore_type, coal):
			continue
		out.append({
			"pos": lp,
			"gpos": Vector3(gx, h + 0.25, gz),
			"scene": resource_nodes[rng.randi() % resource_nodes.size()] \
					if not resource_nodes.is_empty() else null,
			"ore_type": ore_type, "coal": coal, "slot": -1, "node": null,
		})
	return out

# Есть ли принятая точка ближе min_spacing? Смотрим только свою и 8 соседних ячеек решётки.
func _too_close_hashed(grid: Dictionary, cell: float, p: Vector3) -> bool:
	var cx := floori(p.x / cell)
	var cz := floori(p.z / cell)
	for dx in [-1, 0, 1]:
		for dz in [-1, 0, 1]:
			var bucket = grid.get(Vector2i(cx + dx, cz + dz), null)
			if bucket == null:
				continue
			for q in (bucket as Array):
				# Квадраты: на генерации карты сюда приходит до двадцати четырёх тысяч
				# кандидатов, у каждого по девять клеток соседей — корень стоит заметного
				# времени на загрузке, а решает здесь только сравнение с порогом.
				if (q as Vector3).distance_squared_to(p) < min_spacing * min_spacing:
					return true
	return false

# Крутизна = разброс высот в 4 точках вокруг (± sample юнитов).
func _slope_at(map: Node, lx: float, lz: float) -> float:
	var s: float = 3.0
	var hx1: float = map.terrain_height_at(map.global_transform * Vector3(lx + s, 0.0, lz))
	var hx2: float = map.terrain_height_at(map.global_transform * Vector3(lx - s, 0.0, lz))
	var hz1: float = map.terrain_height_at(map.global_transform * Vector3(lx, 0.0, lz + s))
	var hz2: float = map.terrain_height_at(map.global_transform * Vector3(lx, 0.0, lz - s))
	return maxf(maxf(hx1, hx2), maxf(hz1, hz2)) - minf(minf(hx1, hx2), minf(hz1, hz2))

func _too_close(positions: Array[Vector3], p: Vector3) -> bool:
	for q in positions:
		if q.distance_to(p) < min_spacing:
			return true
	return false

# Буфер MultiMesh на max_visible слотов, все схлопнуты. ДАННЫЕ жил сюда больше не входят: их
# рождают регионы по мере приближения игрока (_build_region), а здесь только пул слотов, который
# они делят между собой.
#
# Потолок берём ровно max_visible, а не «сколько жил насчитали»: жил в мире без края бесконечно
# много, а одновременно нарисованных — столько, сколько влезает в радиус.
func _init_slots() -> void:
	var cap: int = maxi(max_visible, 1)
	var big := AABB(Vector3(-2000.0, -2000.0, -2000.0), Vector3(4000.0, 4000.0, 4000.0))
	for mm in multimesh_nodes:
		mm.custom_aabb = big
		mm.multimesh.instance_count = 0
		mm.multimesh.use_custom_data = true         # буфер custom-data ДО instance_count
		mm.multimesh.instance_count = cap
		for s in cap:
			mm.multimesh.set_instance_transform(s, ZERO_XFORM)   # пусто, пока не заполнит стриминг
	_free.clear()
	for s in range(cap - 1, -1, -1):
		_free.append(s)                             # слоты cap-1..0 свободны

## КАКОЙ МЕТАЛЛ ЛЕЖИТ В ЭТОЙ ТОЧКЕ.
##
## Раньше тип жилы был просто `randi() % 4`, и это молча обесценивало всю карту: титанит с
## равной вероятностью лежал под колёсами и за тремя хребтами, значит ехать было незачем —
## копай где стоишь. Теперь металл принадлежит БИОМУ, и дорогой лежит там, куда труднее
## добраться:
##
##   пустыня (базовый слой) → феррит, самый дешёвый и самый частый;
##   луг                    → куприт;
##   каньон                 → силикат;
##   горы                   → титанит, самый дорогой.
##
## Веса, а не жёсткое соответствие. Во-первых, биомы у нас плавно переходят друг в друга
## (маски дробные), и резкая граница «здесь только титанит» выглядела бы нарисованной. Во-
## вторых, `WILD_CHANCE` оставляет долю жил вопреки правилу: карта, разложенная по полочкам
## идеально, читается как таблица, а не как местность, и случайная богатая жила под боком —
## это маленький подарок, ради которого игрок и смотрит по сторонам.
const WILD_CHANCE := 0.15

## Разрешён ли этот тип жилы отладочными флажками Main. Порядок металлов тот же, что в
## G.Metal и в ore_colors: феррит, куприт, силикат, титанит; уголь идёт следом отдельным типом.
const ORE_FLAGS := [&"ore_ferrite", &"ore_cuprite", &"ore_silicate", &"ore_titanite"]

func _ore_enabled(ore_type: int, coal: bool) -> bool:
	if coal:
		return G.debug(&"ore_coal")
	return G.debug(ORE_FLAGS[ore_type]) if ore_type < ORE_FLAGS.size() else true

func _metal_for(local_pos: Vector3, map: Node, can_biome: bool, rng: RandomNumberGenerator) -> int:
	var types: int = maxi(ore_colors.size(), 1)
	if not can_biome or rng.randf() < WILD_CHANCE:
		return rng.randi() % types
	# biome_at отдаёт (каньон, луг, горы); пустыня — это то, что осталось.
	var m: Vector3 = map.biome_at(to_global(local_pos))
	var desert: float = clampf(1.0 - maxf(m.x, maxf(m.y, m.z)), 0.0, 1.0)
	var weights := [desert, m.y, m.x, m.z]        # феррит, куприт, силикат, титанит
	var total: float = 0.0
	for i in mini(weights.size(), types):
		total += maxf(float(weights[i]), 0.0)
	if total <= 0.001:
		return 0                                   # ни один биом не выражен — базовый металл
	var roll: float = rng.randf() * total
	for i in mini(weights.size(), types):
		roll -= maxf(float(weights[i]), 0.0)
		if roll <= 0.0:
			return i
	return 0

# Жила вошла в радиус: берём слот из пула, рисуем инстанс + создаём узел (добыча/коллизия).
func _stream_in(v: Dictionary) -> void:
	if _free.is_empty():
		return                                       # достигнут потолок max_visible — редко (кап с запасом)
	var slot: int = _free.pop_back()
	v["slot"] = slot
	var xform := Transform3D(Basis(), v["pos"])
	var custom := Color(0.0, 1.0, 0.0, float(v["ore_type"]))   # G=1 «целая», A=тип (стримнутая жила полна)
	for mm in multimesh_nodes:
		mm.multimesh.set_instance_transform(slot, xform)
		mm.multimesh.set_instance_custom_data(slot, custom)
	if v["scene"] != null:
		var node: Node3D = v["scene"].instantiate()
		node.position = v["pos"]
		node.instance_id = slot                      # узел пишет истощение в ЭТОТ слот
		if "is_coal" in node: node.is_coal = v["coal"]
		if "ore_type" in node: node.ore_type = v["ore_type"]
		if "ore_color" in node and int(v["ore_type"]) < ore_colors.size():
			node.ore_color = ore_colors[v["ore_type"]]
		add_child(node)
		v["node"] = node

## ЖИВАЯ ЖИЛА ВОЗЛЕ ТОЧКИ — узел, а не запись в _data. Спрашивать можно только про то, что
## сейчас стримнуто: узел с коллизией существует лишь рядом с камерой. Это ровно то, что нужно
## сюжету — он ищет жилу тогда, когда игрок до неё доехал, а не когда объявляет задание.
func node_near(world_pos: Vector3, radius: float = 25.0) -> Node:
	var best: Node = null
	var best_d2: float = radius * radius
	for c in get_children():
		if not (c is Node3D) or not c.has_method("is_depleted"):
			continue
		var d2: float = (c as Node3D).global_position.distance_squared_to(world_pos)
		if d2 <= best_d2:
			best_d2 = d2
			best = c
	return best

# Жилы ВОКРУГ ТОЧКИ для блипов на радаре (hud.gd): позиция и ЦВЕТ МЕТАЛЛА.
#
# Цвет здесь не украшение. С тех пор как металл принадлежит биому (_metal_for), «съездить за
# титанитом» стало осмысленным действием — но только если игрок видит, за чем едет. Одинаково
# жёлтые точки этого не говорят, а цвет жилы в мире и цвет её блипа — это один и тот же
# G.METAL_COLOR, так что радар не может соврать про то, что стоит на земле.
#
# Раньше отдавались «сейчас стримнутые» жилы, и это совпадало с радиусом радара само собой.
# Теперь стриминг отсекает то, что за спиной и за хребтом, а радар смотрит СВЕРХУ и во все
# стороны сразу: по нему как раз и разворачиваются к жиле, которой не видно. Поэтому считаем
# по данным и по расстоянию, а не по тому, нарисована ли жила.
func active_blips(around: Vector3 = Vector3.INF, radius: float = -1.0) -> Array:
	var center: Vector3 = around
	if center == Vector3.INF:
		var cam := get_viewport().get_camera_3d()
		center = cam.global_position if cam != null else Vector3.ZERO
	var r2: float = (radius if radius > 0.0 else render_distance)
	r2 *= r2
	var out: Array = []
	for v in _data:
		var p: Vector3 = v["gpos"]
		if center.distance_squared_to(p) > r2:
			continue
		var t: int = int(v["ore_type"])
		out.append({"p": p, "c": coal_color if t >= ore_colors.size() else ore_colors[t]})
	return out

# Жила вышла из радиуса: гасим инстанс, освобождаем узел и возвращаем слот в пул.
func _stream_out(v: Dictionary) -> void:
	var slot: int = int(v["slot"])
	for mm in multimesh_nodes:
		mm.multimesh.set_instance_transform(slot, ZERO_XFORM)
	if v["node"] != null and is_instance_valid(v["node"]):
		v["node"].queue_free()
	v["node"] = null
	v["slot"] = -1
	_free.append(slot)

# ── Стриминг: держим отрисованными/активными только жилы в render_distance ─────
## КЛЕТКА ПЕРЕСЧЁТА. Приём взят у HTerrain (hterrain_detail_layer): он пересобирает свои
## куски не по таймеру, а когда наблюдатель ПЕРЕСЁК границу клетки. Полный проход по двум
## тысячам жил четыре раза в секунду не нужен, пока игрок стоит в гараже или ползёт по
## стройке: ответ не может измениться, если камера не сдвинулась ощутимо.
const RESCAN_CELL := 12.0
var _last_cell := Vector2i(1 << 30, 1 << 30)

func _process(delta: float) -> void:
	if _data.is_empty():
		return
	_cull_t -= delta
	if _cull_t > 0.0:
		return
	_cull_t = cull_interval
	var _pf := Perf.now()          # метка для панели профиля (perf.gd)
	_regions_tick()                # игрок мог переехать в соседний регион — родим его жилы
	# Камера не ушла из своей клетки — пересчитывать нечего. Направление взгляда сюда НЕ
	# входит намеренно: жила гаснет и зажигается по направлению, и пропустить поворот значило
	# бы держать за спиной то, что мы только что научились гасить.
	var cam0 := get_viewport().get_camera_3d()
	if cam0 != null:
		var cell := Vector2i(int(floor(cam0.global_position.x / RESCAN_CELL)),
				int(floor(cam0.global_position.z / RESCAN_CELL)))
		var fwd0: Vector3 = -cam0.global_transform.basis.z
		if cell == _last_cell and fwd0.dot(_last_fwd) > 0.999:
			Perf.mark("veins", _pf)
			return
		_last_cell = cell
		_last_fwd = fwd0
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	var cam_pos: Vector3 = cam.global_position
	var fwd: Vector3 = -cam.global_transform.basis.z
	var d2: float = render_distance * render_distance
	var keep2: float = keep_radius * keep_radius
	# Жилу за хребтом не рисуем и не оживляем: узел с коллизией и слот MultiMesh стоят одинаково
	# что перед горой, что за ней. Спрашиваем у рельефа по карте высот (map.is_point_hidden) и
	# ПОРЦИЯМИ — ответ меняется только от движения камеры, а жил тысячи.
	var terr: Node = get_parent()
	var can_occlude: bool = terr != null and terr.has_method("is_point_hidden")
	var n: int = _data.size()
	var slice_from: int = _occl_cursor
	var step: int = maxi(n / OCCL_SLICES, 1)
	_occl_cursor = (_occl_cursor + step) % maxi(n, 1)
	var slice_to: int = slice_from + step
	var i: int = -1
	for v in _data:
		i += 1
		var gp: Vector3 = v["gpos"]
		var to: Vector3 = gp - cam_pos
		var dist2: float = to.length_squared()
		# В радиусе И (близко ИЛИ впереди). Направление считаем только для дальних: у жилы
		# под колёсами направление вырождается, да и гасить её нельзя.
		# БЛИЖНИЙ ПУЗЫРЬ СЧИТАЕТСЯ ОТ ЛЮБОЙ ЖИВОЙ ТОЧКИ (G.active_points), а не от камеры: жила
		# это не картинка, а узел с коллизией, по которому работают бур и авто-шахтёр. У базы
		# на другом конце карты бур грызёт свою жилу, пока игрок ездит другой машиной, — и если
		# мерить только от камеры, жила под ним исчезнет вместе с добычей.
		var kept: bool = dist2 <= keep2 or G.near_active(gp, keep_radius)
		# kept идёт ПЕРВЫМ и без оглядки на радиус камеры: жила у базы за пятьсот метров всё
		# равно обязана быть узлом, иначе стоящий на ней авто-шахтёр добывает воздух.
		var near: bool = kept or (dist2 <= d2 and to.normalized().dot(fwd) >= view_cos)
		if near and can_occlude and not kept and i >= slice_from and i < slice_to:
			v["hidden"] = terr.is_point_hidden(gp, OCCL_VEIN_HEIGHT, v.get("hidden", false))
		if near and not kept and v.get("hidden", false):
			near = false
		var shown: bool = int(v["slot"]) >= 0
		if near and not shown:
			_stream_in(v)
		elif not near and shown:
			_stream_out(v)
	Perf.mark("veins", _pf)


# Родитель, умеющий отвечать как карта. null, если не дождались.
func _await_map() -> Node:
	var map: Node = get_parent()
	var guard: int = 0
	while guard < MAP_WAIT_FRAMES:
		if map != null and map.has_method("terrain_height_at") and map.has_method("get_dims"):
			return map
		await get_tree().process_frame
		guard += 1
		map = get_parent()
	return null
