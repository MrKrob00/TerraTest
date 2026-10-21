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

## ТОЧКИ РОЖДАЮТСЯ РЕГИОНАМИ, как и жилы (resource_nodes): в мире без края нет «всей карты», по
## которой можно было бы разложить их разом. Регион считается из сида мира и своих координат,
## поэтому форт на краю каньона там же и завтра, и соседний регион считается независимо.
const REGION := 512
## Сколько точек в регионе. Плотность выведена из прежней: четырнадцать на 1982² — это одна на
## ~280 тысяч м², а регион 512² это 262 тысячи. То есть ровно одна.
const OUTPOSTS_PER_REGION := 1
## Сколько регионов вокруг игрока держим. Радиус материализации — сотни метров, регион — 512,
## одного кольца хватает с запасом.
const REGION_KEEP := 1
## Зерно раскладки — СИД МИРА (G.world_seed), а не константа. Точки обязаны стоять на одном
## месте всю игру, но в РАЗНЫХ слотах это должны быть разные точки: иначе новый мир отличается
## от старого только счётчиком денег. Форт на краю каньона по-прежнему там же и завтра — сид у
## слота один и тот же от создания до конца.
## Минимальный зазор между точками — чтобы две не читались как одна укреплённая зона.
const MIN_GAP := 300.0
## Вокруг старта точек нет: первые минуты игрок собирает машину, и форт в двухстах метрах
## означал бы бой раньше, чем колёса.
const HOME_CLEAR := 260.0


## Ближе этого точка МАТЕРИАЛИЗУЕТСЯ (появляется машина с блоками), дальше — узел убирается,
## а сама точка остаётся на карте. Порог убирания больше порога появления: иначе постройка
## на границе мигала бы, появляясь и исчезая от каждого шага игрока.
const SPAWN_DIST := 460.0
const DESPAWN_DIST := 620.0
## Как часто проверяем расстояния. Раз в секунду: точка не убегает.
const TICK := 1.0

## Сборки укреплений (blocks.gd): аванпост, форт и ТРИ ПОВОРОТНЫЕ БАШНИ — с пушками, с
## дробовиками и с лазерами. Порядок — по опасности.
##
## Башня опаснее не числом стволов, а тем, что у неё нет мёртвой зоны: корпус доворачивается к
## цели (enemy_vehicle._turn_to_target), поэтому объехать её сзади не выйдет, а щит наверху
## живёт от собственных панелей. Три варианта оружия — это три разных боя на одной раскладке:
## пушка достаёт издалека, дробовик наказывает за подъезд вплотную, лазер жжёт непрерывно.
const PRESETS := [11, 12, 13, 14, 15]
## THE STRONGHOLDS COME WITH THE THIRD GRADE (the player's call: a fort of turrets is no fight for the
## first machine). Below it the points stay on the map - the seed lays them all the same - but none
## materialises and the radar shows none; reaching the grade brings them in on the next tick.
const MIN_GRADE := 3

## ENEMY FACTORIES - RARE: one region in FACTORY_CHANCE gets one besides its stronghold (a region is
## 512 m square, so about one per square kilometre). Kind by FACTORY_KINDS weights: the plain smelter
## line most often, the component plant less, the fabricator rarely. Each stands on real ore veins
## (`_factory_site`) with two turrets and a miner round it; its seller pays nobody (seller.gd).
const FACTORY_CHANCE := 0.25
const FACTORY_KINDS := [[133, 0.55], [134, 0.30], [135, 0.15]]     # blocks.FACTORY_BASIC/COMP/FAB
const FACTORY_GUARDS := [13, 14, 15]
## Where a factory's veins must stand, in the base's own axes: behind its miners (blocks.FACTORY_MINERS
## at local x 0 and -3, z 4.5), 3 m further back.
const VEIN_LOCAL := [Vector3(0.0, 0.0, 7.5), Vector3(-3.0, 0.0, 7.5)]
const VEIN_PAIR := Vector2(3.0, 10.5)       # how far apart a pair of veins may stand
const VEIN_SEARCH := 70.0                   # how far from the point a factory looks for its veins
## Ticks to wait for the vein field round the point to be laid, then build anyway. It is laid only
## near the player, and a factory comes in at SPAWN_DIST: with 20 the comp and fab kinds found no
## veins yet, fell back to the plain line - and only basic factories were ever seen.
const SITE_TRIES := 240

func _open() -> bool:
	return G.grade("start") >= MIN_GRADE

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
	# Debug switch (Main → Отладка → Враги). Cuts the whole system off, layout included: with the
	# points never built, nothing materialises and nothing is written to the world save either.
	if not G.debug(&"outposts"):
		return
	if not _ready_done:
		_build_points()
		return
	_regions_tick()              # игрок мог переехать в соседний регион
	_stream()

# ── Раскладка ────────────────────────────────────────────────────────────────
## Точки региона. Высоту спрашиваем у рельефа, а он знает только то, что внутри окна, — поэтому
## регион рождается лишь когда игрок к нему подъехал.
var _regions: Dictionary = {}            # Vector2i региона → Array записей точек
var _region_center := Vector2i(999999, 999999)
## Зачищенные точки, по СТАБИЛЬНОМУ ключу «регион + номер внутри региона». Индекс в общем списке
## тут не годится: общего списка больше нет, а номер в нём менялся бы от того, где стоит игрок.
var _cleared: Dictionary = {}

func _region_of(p: Vector3) -> Vector2i:
	return Vector2i(floori(p.x / REGION), floori(p.z / REGION))

static func _point_key(rk: Vector2i, i: int) -> String:
	return "%d,%d,%d" % [rk.x, rk.y, i]

func _build_points() -> void:
	var map: Node = get_node_or_null("/root/Main/map")
	if map == null or not map.has_method("get_dims"):
		return
	if map.get_dims().x <= 0:
		return                    # высот ещё нет — попробуем на следующем тике
	_ready_done = true
	_regions_tick()

## Держать вокруг игрока квадрат регионов; ушедшие — забыть вместе с их точками.
func _regions_tick() -> void:
	var pts: Array = G.active_points()
	var here := _region_of(pts[0] if not pts.is_empty() else Vector3.ZERO)
	if here == _region_center and not _regions.is_empty():
		return
	_region_center = here
	var want := {}
	for dz in range(-REGION_KEEP, REGION_KEEP + 1):
		for dx in range(-REGION_KEEP, REGION_KEEP + 1):
			want[here + Vector2i(dx, dz)] = true
	for k in _regions.keys():
		if not want.has(k):
			for e in _regions[k]:
				var node = e["node"]
				if node != null and is_instance_valid(node):
					(node as Node).queue_free()
			_regions.erase(k)
	for k in want:
		if not _regions.has(k):
			_regions[k] = _build_region(k)
	_points.clear()
	for k in _regions:
		_points.append_array(_regions[k])

## Точки ОДНОГО региона. Своё зерно от сида мира и координат региона.
func _build_region(rk: Vector2i) -> Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(Vector3i(rk.x, rk.y, int(G.world_seed) ^ 0x0FF5))
	var out: Array = []
	var tries: int = OUTPOSTS_PER_REGION * 40
	while out.size() < OUTPOSTS_PER_REGION and tries > 0:
		tries -= 1
		var p := Vector3(float(rk.x * REGION) + rng.randf() * REGION, 0.0,
				float(rk.y * REGION) + rng.randf() * REGION)
		# Вокруг старта точек нет: первые минуты игрок собирает машину, и форт в двухстах метрах
		# означал бы бой раньше, чем колёса. Старт у нас в нуле мира.
		if p.length() < HOME_CLEAR or _too_close(p):
			continue
		p.y = G.ground_y(p, 0.0)
		var key := _point_key(rk, out.size())
		out.append({
			"pos": p,
			"preset": int(PRESETS[rng.randi() % PRESETS.size()]),
			"cleared": _cleared.has(key),
			"key": key,
			"node": null,
		})
	# Drawn after the strongholds, so their layout is the one it was before factories came.
	if rng.randf() < FACTORY_CHANCE:
		var roll: float = rng.randf()
		var preset: int = int(FACTORY_KINDS[0][0])
		for kw in FACTORY_KINDS:
			preset = int(kw[0])
			roll -= float(kw[1])
			if roll < 0.0:
				break
		for _t in 40:
			var p := Vector3(float(rk.x * REGION) + rng.randf() * REGION, 0.0,
					float(rk.y * REGION) + rng.randf() * REGION)
			var near_other := false
			for o in out:
				if (o["pos"] as Vector3).distance_squared_to(p) < MIN_GAP * MIN_GAP:
					near_other = true
			if p.length() < HOME_CLEAR or near_other or _too_close(p):
				continue
			p.y = G.ground_y(p, 0.0)
			var key := "f" + _point_key(rk, 0)
			out.append({"pos": p, "preset": preset, "factory": true, "yaw": rng.randf() * TAU,
					"cleared": _cleared.has(key), "key": key, "node": null, "guards": [], "tries": 0})
			break
	return out

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
		# БЕЗ СРАВНЕНИЯ С null: освобождённый объект в Godot 4 РАВЕН null по `==`, но не является
		# им, поэтому `node != null` для мёртвой ссылки ложно и ветка очистки не срабатывала.
		# Запись в списке оставалась «занятой» мёртвым узлом, и точка больше не появлялась никогда.
		# Та же грабля была в blocks.find_block — там она роняла обход связности.
		if not is_instance_valid(node):
			e["node"] = null
			node = null
		if bool(e["cleared"]):
			continue
		if node == null and d2 <= SPAWN_DIST * SPAWN_DIST and _open() and _clear_of_player(e["pos"]):
			e["node"] = _spawn(e)
		elif node != null and d2 > DESPAWN_DIST * DESPAWN_DIST:
			# Убираем УЗЕЛ, а не точку: постройка вернётся на то же место такой же. Урон,
			# который ей успели нанести, при этом теряется — и это осознанно: помнить хп
			# каждого блока каждой точки значит писать в сейв целую вторую карту машин.
			(node as Node).queue_free()
			e["node"] = null
			_free_guards(e)

func _free_guards(e: Dictionary) -> void:
	for gd in e.get("guards", []):
		if is_instance_valid(gd):
			(gd as Node).queue_free()
	e["guards"] = []

## A STRONGHOLD DOES NOT MATERIALISE WITHIN enemy_spawner.PLAYER_CLEAR OF THE PLAYER'S OWN (a machine
## or a base; the player's rule, the same door as every other hostile). Approached, it appears at
## SPAWN_DIST and stays; this holds it back after a load, a respawn or a base built beside it.
func _clear_of_player(p: Vector3) -> bool:
	var spawner: Node = get_node_or_null("/root/Main/EnemySpawner")
	if spawner == null or not spawner.has_method("is_clear_of_player"):
		return true
	return spawner.is_clear_of_player(p)

func _spawn(e: Dictionary) -> Node3D:
	if bool(e.get("factory", false)):
		return _spawn_factory(e)
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

# ── Enemy factories ──────────────────────────────────────────────────────────
## The veins under a factory: [A] or [A, B] (B of another metal, VEIN_PAIR from A), as world points with
## their metal, from the vein field's own data (resource_nodes._data). Empty while the field round the
## point is not laid yet.
func _factory_veins(at: Vector3, pair: bool) -> Array:
	var rn: Node = get_node_or_null("/root/Main/map/Resource_Nodes")
	if rn == null or not ("_data" in rn):
		return []
	var ores: Array = []
	var r2: float = VEIN_SEARCH * VEIN_SEARCH
	for v in rn._data:
		if bool(v.get("wood", false)):
			continue
		var gp: Vector3 = v["gpos"]
		if Vector2(gp.x - at.x, gp.z - at.z).length_squared() <= r2:
			ores.append(v)
	ores.sort_custom(func(a, b): return Vector2((a["gpos"] as Vector3).x - at.x, (a["gpos"] as Vector3).z - at.z).length_squared() \
			< Vector2((b["gpos"] as Vector3).x - at.x, (b["gpos"] as Vector3).z - at.z).length_squared())
	if ores.is_empty():
		return []
	if not pair:
		return [ores[0]]
	for a in ores:
		for b in ores:
			if int(a["ore_type"]) == int(b["ore_type"]):
				continue
			var d: float = Vector2((a["gpos"] as Vector3).x - (b["gpos"] as Vector3).x,
					(a["gpos"] as Vector3).z - (b["gpos"] as Vector3).z).length()
			if d >= VEIN_PAIR.x and d <= VEIN_PAIR.y:
				return [a, b]
	return [ores[0]]

static func _rot(yaw: float, v: Vector3) -> Vector3:
	return Basis(Vector3.UP, yaw) * v

func _spawn_factory(e: Dictionary) -> Node3D:
	var preset: int = int(e["preset"])
	var veins: Array = _factory_veins(e["pos"], preset != 133)
	if veins.is_empty() and int(e["tries"]) < SITE_TRIES:
		e["tries"] = int(e["tries"]) + 1
		return null                              # the field there is not laid yet: next tick
	if veins.size() < 2 and preset != 133 and int(e["tries"]) < SITE_TRIES:
		e["tries"] = int(e["tries"]) + 1
		return null                              # one vein in sight so far: wait for the field round it
	if veins.size() < 2 and preset != 133:
		preset = 133                             # no pair of metals there: the plain line
	var yaw: float = float(e["yaw"])
	var origin: Vector3 = e["pos"]
	if veins.size() >= 2:
		var a: Vector3 = veins[0]["gpos"]
		var b: Vector3 = veins[1]["gpos"]
		var u := Vector3(b.x - a.x, 0.0, b.z - a.z).normalized()
		yaw = atan2(u.z, -u.x)                   # the base's -X runs from vein A to vein B
		origin = (a + b) * 0.5 - _rot(yaw, (VEIN_LOCAL[0] + VEIN_LOCAL[1]) * 0.5)
	elif veins.size() == 1:
		origin = (veins[0]["gpos"] as Vector3) - _rot(yaw, VEIN_LOCAL[0])
	var base := _make_base(origin, preset, yaw)
	if base == null:
		return null
	if base.has_signal("died"):
		base.died.connect(_on_cleared.bind(e))
	var metals: Array = []
	for v in veins:
		metals.append(int(v["ore_type"]))
	get_tree().create_timer(1.5).timeout.connect(_tune_factory.bind(base, metals))
	# two turrets either side and a miner working behind
	var guards: Array = []
	for side in [-1.0, 1.0]:
		var gp: Vector3 = origin + _rot(yaw, Vector3(side * 13.0, 0.0, -3.0))
		var t := _make_base(gp, int(FACTORY_GUARDS[absi(int(origin.x + side * 7.0)) % FACTORY_GUARDS.size()]), yaw)
		if t != null:
			guards.append(t)
	var spawner: Node = get_node_or_null("/root/Main/EnemySpawner")
	if spawner != null and spawner.has_method("spawn_at") and "miner_presets" in spawner \
			and not (spawner.miner_presets as Array).is_empty():
		var mp: Vector3 = origin + _rot(yaw, Vector3(6.0, 0.0, 14.0))
		var m: Node3D = spawner.spawn_at(mp, int(spawner.miner_presets[0]), 1, false)
		if m != null:
			m.remove_meta("story")               # a guard, not a quest target
			guards.append(m)
	e["guards"] = guards
	return base

## An anchored enemy base of `preset` at `p`, turned `yaw` (the stronghold's own door, as _spawn).
func _make_base(p: Vector3, preset: int, yaw: float) -> Node3D:
	var spawner: Node = get_node_or_null("/root/Main/EnemySpawner")
	var vehicles: Node = get_node_or_null("/root/Main/Vehicles")
	if spawner == null or vehicles == null or not ("enemy_scenes" in spawner):
		return null
	var scenes: Array = spawner.enemy_scenes
	if scenes.is_empty():
		return null
	var enemy: Node3D = (scenes.pick_random() as PackedScene).instantiate()
	enemy.set("is_base", true)
	var blocks := enemy.get_node_or_null("blocks")
	if blocks and "layout_preset" in blocks:
		blocks.layout_preset = preset
		if "is_station" in blocks:
			blocks.is_station = true
	vehicles.add_child(enemy)
	enemy.global_position = Vector3(p.x, G.ground_y(p, p.y) + 0.5, p.z)
	enemy.rotation.y = yaw
	if spawner.has_method("register_base"):
		spawner.register_base(enemy)
	return enemy

## The products, once the blocks stand: the plant makes the component of the two metals under it, and
## the fabricator stamps a block out of that component alone (its own one-material recipe).
func _tune_factory(base: Node, metals: Array) -> void:
	if not is_instance_valid(base) or metals.size() < 2:
		return
	var lo: int = mini(int(metals[0]), int(metals[1]))
	var hi: int = maxi(int(metals[0]), int(metals[1]))
	var comp: int = 0
	for c in G.COMP_SIMPLE_COUNT:
		var par: Array = G.COMP_PARENT[c]
		if int(par[0]) == lo and int(par[1]) == hi:
			comp = c
	var bl: Node = base.get_node_or_null("blocks")
	if bl == null:
		return
	for b in bl.get_children():
		if "output_comp" in b:
			b.set("output_comp", comp)
			b.reload_recipe()
		elif b.has_method("set_recipe_override"):
			var key: String = G.comp_key(comp)
			var out: int = G.Block.BLOCK
			for bt in G.BLOCK_RECIPE:
				if (G.BLOCK_RECIPE[bt] as Dictionary).has(key):
					out = int(bt)
					break
			b.set("output_block", out)
			b.set_recipe_override({key: 2})

func _on_cleared(_who, e: Dictionary) -> void:
	if bool(e["cleared"]):
		return
	e["cleared"] = true
	_cleared[String(e.get("key", ""))] = true    # переживёт и выгрузку региона, и сейв
	e["node"] = null
	if bool(e.get("factory", false)):
		return                                   # its guards stay and fight; it says nothing
	# NO INGOTS FALL OUT OF IT. A stronghold used to drop three to six ingots of the biome's metal
	# on top of its own blocks; what a cleared point leaves is what its build leaves
	# (MachineBody.scatter_blocks at LOOT_SURVIVE), the same as any machine.
	Dialogue.say("System", tr("Stronghold neutralised. The sector reads clear."))

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
	if not _open():
		return out
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
## КЛЮЧИ, А НЕ ИНДЕКСЫ. Раньше писались номера в общем списке точек — но общего списка больше
## нет, он собирается из тех регионов, что сейчас рядом с игроком, и один и тот же форт получал
## бы разный номер в зависимости от того, откуда игрок приехал. Ключ «регион + номер внутри
## региона» не зависит ни от чего внешнего и верен всегда.
##
## СТАРЫЕ САВЫ теряют отметки о зачистке: там лежат числа, и сопоставить их с ключами нечем —
## тот форт мог быть каким угодно. Зачищать заново придётся, но мир при этом цел.
func save_state() -> Array:
	return _cleared.keys()

func load_state(cleared: Array) -> void:
	_cleared.clear()
	for k in cleared:
		if k is String:
			_cleared[String(k)] = true
	if not _ready_done:
		_build_points()
	for e in _points:
		if _cleared.has(String(e.get("key", ""))):
			e["cleared"] = true
			var node = e["node"]
			if node != null and is_instance_valid(node):
				(node as Node).queue_free()
			e["node"] = null
