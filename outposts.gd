class_name Outposts
extends Node
# УКРЕПЛЁННЫЕ ТОЧКИ — то немногое в этом мире, что стоит НА КАРТЕ, а не вокруг игрока.
#
# Всё остальное (враги, события, прежние «вражеские базы») спавнится в кольце вокруг машины и
# исчезает за спиной. Из-за этого две тысячи метров рельефа работали фоном: куда ни поезжай,
# видишь одно и то же, а «уехать куда-то» не значит ничего. Точки решают ровно это — у них
# есть КООРДИНАТЫ, они там же и завтра, и их можно найти, объехать, вернуться подготовленным.
#
# ТОЧКИ НЕ СЛУЧАЙНЫ ПРИ КАЖДОМ ЗАПУСКЕ. Карта высот у нас заводская и одна и та же
# (res://terrain_height.res), поэтому и раскладка точек берётся от постоянного зерна: это
# делает мир ЗАПОМИНАЕМЫМ («форт на краю каньона») вместо «где-то опять что-то заспавнилось».
#
# Разрушенная точка остаётся разрушенной: это записано в сейв мира (world_persist), иначе
# зачищенный форт восстанавливался бы к следующему приезду и обесценивал поход.
#
# Сама постройка — обычная вражеская машина с флагом is_base (та же, что делал спавнер):
# заякорена, отстреливается, разбирается по блокам и платит ДИ по стоимости. Новых сущностей
# здесь нет, новое только одно — МЕСТО.

## Сколько точек на карте. Четырнадцать на 1982² — это примерно одна на 280 тысяч м²: едешь
## пару минут и находишь следующую, но поле между ними остаётся полем.
const COUNT := 14
## Зерно раскладки. Константа, а не случайное число: карта одна и та же, точки тоже.
const PLACE_SEED := 20260829
## Минимальный зазор между точками — чтобы две не читались как одна укреплённая зона.
const MIN_GAP := 300.0
## Вокруг старта точек нет: первые минуты игрок собирает машину, и форт в двухстах метрах
## означал бы бой раньше, чем колёса.
const HOME_CLEAR := 260.0
## Отступ от края карты: постройка на самом краю наполовину висит над обрывом.
const EDGE_MARGIN := 120.0

## Ближе этого точка МАТЕРИАЛИЗУЕТСЯ (появляется машина с блоками), дальше — узел убирается,
## а сама точка остаётся на карте. Порог убирания больше порога появления: иначе постройка
## на границе мигала бы, появляясь и исчезая от каждого шага игрока.
const SPAWN_DIST := 460.0
const DESPAWN_DIST := 620.0
## Как часто проверяем расстояния. Раз в секунду: точка не убегает.
const TICK := 1.0

## Сборки укреплений (blocks.gd): аванпост, форт и ПОВОРОТНАЯ БАШНЯ. Порядок — по опасности.
## Башня опаснее не числом стволов, а тем, что у неё нет мёртвой зоны: корпус доворачивается
## к цели (enemy_vehicle._turn_to_target), поэтому объехать её сзади не выйдет.
const PRESETS := [11, 12, 13]

## Награда за зачистку СВЕРХ разлетевшихся блоков: слитки того металла, что лежит в этом
## биоме. Поход должен окупаться не только ломом, иначе разбирать точку выгоднее издалека
## по одному блоку, чем брать её штурмом.
const LOOT_MIN := 3
const LOOT_MAX := 6

var _points: Array = []          # [{pos: Vector3, preset: int, cleared: bool, node: Node3D}]
var _t: float = 0.0
var _ready_done: bool = false

func _ready() -> void:
	add_to_group("outposts")     # радар и сейв находят нас через группу, а не по пути

func _process(delta: float) -> void:
	_t -= delta
	if _t > 0.0:
		return
	_t = TICK
	if not _ready_done:
		_build_points()
		return
	_stream()

# ── Раскладка ────────────────────────────────────────────────────────────────
## Точки раскладываются ОДИН РАЗ, когда карта высот уже прочитана: до этого G.ground_y
## отвечает «не знаю», и все точки легли бы на нулевую высоту.
func _build_points() -> void:
	var map: Node = get_node_or_null("/root/Main/map")
	if map == null or not map.has_method("get_dims"):
		return
	var dims: Vector2i = map.get_dims()
	if dims.x <= 0:
		return                    # высот ещё нет — попробуем на следующем тике
	_ready_done = true
	var half_x: float = float(dims.x) * 0.5 - EDGE_MARGIN
	var half_z: float = float(dims.y) * 0.5 - EDGE_MARGIN
	var rng := RandomNumberGenerator.new()
	rng.seed = PLACE_SEED
	var tries: int = 0
	while _points.size() < COUNT and tries < COUNT * 40:
		tries += 1
		var p := Vector3(rng.randf_range(-half_x, half_x), 0.0, rng.randf_range(-half_z, half_z))
		if p.length() < HOME_CLEAR or _too_close(p):
			continue
		p.y = G.ground_y(p, 0.0)
		_points.append({
			"pos": p,
			"preset": int(PRESETS[rng.randi() % PRESETS.size()]),
			"cleared": false,
			"node": null,
		})

func _too_close(p: Vector3) -> bool:
	for e in _points:
		if (e["pos"] as Vector3).distance_squared_to(p) < MIN_GAP * MIN_GAP:
			return true
	return false

# ── Стриминг ─────────────────────────────────────────────────────────────────
func _stream() -> void:
	var player: Node3D = _player()
	if player == null:
		return
	var origin: Vector3 = player.global_position
	for e in _points:
		var d2: float = (e["pos"] as Vector3).distance_squared_to(origin)
		var node = e["node"]
		if node != null and not is_instance_valid(node):
			e["node"] = null
			node = null
		if bool(e["cleared"]):
			continue
		if node == null and d2 <= SPAWN_DIST * SPAWN_DIST:
			e["node"] = _spawn(e)
		elif node != null and d2 > DESPAWN_DIST * DESPAWN_DIST:
			# Убираем УЗЕЛ, а не точку: постройка вернётся на то же место такой же. Урон,
			# который ей успели нанести, при этом теряется — и это осознанно: помнить хп
			# каждого блока каждой точки значит писать в сейв целую вторую карту машин.
			(node as Node).queue_free()
			e["node"] = null

func _spawn(e: Dictionary) -> Node3D:
	var spawner: Node = get_node_or_null("/root/Main/EnemySpawner")
	var vehicles: Node = get_node_or_null("/root/Main/Vehicles")
	if spawner == null or vehicles == null or not ("enemy_scenes" in spawner):
		return null
	var scenes: Array = spawner.enemy_scenes
	if scenes.is_empty():
		return null
	var enemy: Node3D = (scenes.pick_random() as PackedScene).instantiate()
	enemy.set("is_base", true)                   # ДО add_child: _ready по нему морозит тело
	var blocks := enemy.get_node_or_null("blocks")
	if blocks and "layout_preset" in blocks:
		blocks.layout_preset = int(e["preset"])
		if "is_station" in blocks:
			blocks.is_station = true             # на базу нельзя ставить кабину и колёса
	vehicles.add_child(enemy)
	var p: Vector3 = e["pos"]
	# Высоту берём заново: раскладка считалась при старте, а рельеф с тех пор могли выровнять
	# (квест ровняет площадку под линию, и точка могла оказаться рядом).
	enemy.global_position = Vector3(p.x, G.ground_y(p, p.y) + 0.5, p.z)
	enemy.rotation.y = float(int(p.x + p.z)) * 0.37      # разный разворот, но постоянный
	if enemy.has_signal("died"):
		enemy.died.connect(_on_cleared.bind(e))
	# Отдаём базу под присмотр спавнера: сон и тени — его правило, общее для всего, что
	# стреляет. Второй такой механизм здесь однажды разошёлся бы с тем.
	if spawner.has_method("register_base"):
		spawner.register_base(enemy)
	return enemy

func _on_cleared(_who, e: Dictionary) -> void:
	if bool(e["cleared"]):
		return
	e["cleared"] = true
	e["node"] = null
	_drop_loot(e["pos"] as Vector3)
	Dialogue.say("System", "Stronghold neutralised. The sector reads clear.")

## Трофей: слитки МЕТАЛЛА ЭТОГО БИОМА. Правило «металл принадлежит биому» уже держит карту
## (resource_nodes._metal_for), и трофей обязан ему следовать: иначе титанит выгоднее фармить
## с ближайшего аванпоста в пустыне, чем ехать в горы.
func _drop_loot(at: Vector3) -> void:
	var props: Node = get_tree().get_first_node_in_group("quest_props")
	if props == null or not props.has_method("drop_resource"):
		return
	var metal: int = _metal_of_biome(at)
	var n: int = randi_range(LOOT_MIN, LOOT_MAX)
	for i in n:
		var off := Vector3(randf_range(-2.5, 2.5), 1.2 + float(i) * 0.4, randf_range(-2.5, 2.5))
		props.drop_resource("m%d" % metal, at + off)

func _metal_of_biome(at: Vector3) -> int:
	var map: Node = get_node_or_null("/root/Main/map")
	if map == null or not map.has_method("biome_at"):
		return 0
	var m: Vector3 = map.biome_at(at)            # x = каньон, y = луг, z = горы
	if m.z > 0.5:
		return 3                                 # горы → титанит
	if m.x > 0.5:
		return 2                                 # каньон → силикат
	if m.y > 0.5:
		return 1                                 # луг → куприт
	return 0                                     # пустыня → феррит

func _player() -> Node3D:
	var cc: Node = get_tree().get_first_node_in_group("camera_controller")
	if cc != null and "current_vehicle" in cc and cc.current_vehicle != null:
		return cc.current_vehicle as Node3D
	return null

# ── Наружу: радар и сейв ─────────────────────────────────────────────────────
## Живые (не зачищенные) точки в радиусе — для радара. Отдаём ДАННЫЕ, а не узлы: радар
## смотрит сверху на километры, а постройка материализуется только вблизи, и по узлам он
## показывал бы лишь то, что и так видно из окна.
func blips(around: Vector3, radius: float) -> Array:
	var out: Array = []
	var r2: float = radius * radius
	for e in _points:
		if bool(e["cleared"]):
			continue
		if (e["pos"] as Vector3).distance_squared_to(around) <= r2:
			out.append(e["pos"])
	return out

## Что писать в сейв мира: индексы зачищенных точек. Координаты не пишем — они выводятся из
## зерна и всегда одни и те же, а хранить в сейве то, что и так вычисляется, значит однажды
## получить сейв, который спорит с кодом.
func save_state() -> Array:
	var out: Array = []
	for i in _points.size():
		if bool(_points[i]["cleared"]):
			out.append(i)
	return out

func load_state(cleared: Array) -> void:
	if not _ready_done:
		_build_points()
	for i in cleared:
		var k: int = int(i)
		if k >= 0 and k < _points.size():
			_points[k]["cleared"] = true
			var node = _points[k]["node"]
			if node != null and is_instance_valid(node):
				(node as Node).queue_free()
			_points[k]["node"] = null
