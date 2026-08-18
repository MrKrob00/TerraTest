extends Node3D
# Спавнит врагов вокруг игрока и держит их количество: враг погиб/исчез → через интервал
# появляется новый. Сцена берётся случайно из пула, а вот СБОРКА — уже нет: она подбирается
# под стоимость машины игрока (см. _pick_preset). Враги добавляются под узел Vehicles,
# чтобы карта дала им стриминговую коллизию (иначе провалятся сквозь рельеф вдали).
#
# Плотность и правила взяты из TerraTech, где мир держится на четырёх врагах и сорока
# секундах паузы. У нас было девять и шесть — вчетверо гуще по машинам и в семь раз по
# темпу, и мир читался как непрерывная драка. Три правила оттуда же:
#   • рядом со СВОЕЙ ЗАЯКОРЕННОЙ машиной спавна нет (quiet_radius) — база тихая;
#   • далёкий враг ЗАСЫПАЕТ, а не возвращается к игроку — из боя можно выйти;
#   • сила врага подбирается под стоимость машины игрока, а не бросается кубиком.
# Чего НЕ взял: в TerraTech враг не появляется, пока игрок едет быстро. У нас это отменило
# бы главное требование к миру — «проехал сотню метров и уже дерёшься».

@export var enemy_scenes: Array[PackedScene]        # пул сцен врагов
## ПОТОЛОК одновременно БОДРСТВУЮЩИХ врагов. Было девять, потом четыре (как в TerraTech) —
## и всё равно оказалось густо. Двое: столько же держит любая встреча на дороге, но мир
## перестаёт быть непрерывной дракой.
@export var max_enemies: int = 2
## Пауза между появлениями. Было 6 секунд (убитый заменялся мгновенно), потом 40. Минута с
## четвертью: после стычки должен быть слышен перерыв, а не следующая стычка.
@export var spawn_interval: float = 75.0
## Сколько врагов ставится СРАЗУ, как только мир готов (и обучение закончилось). Один:
## мир не должен встречать игрока пустым, но и толпой тоже.
@export var initial_enemies: int = 1

## Сколько врагов ОДНОВРЕМЕННО могут вести бой с игроком. Остальные патрулируют, пока место
## не освободится. Без этого потолка машины, заметив игрока, ехали на него все разом —
## и это не бой, а казнь: отбиться от толпы нечем, а разъехаться она не даёт.
## ОДИН: бой один на один читается и выигрывается, а второй нападающий превращает его
## в свалку, где решает не умение, а количество.
@export var max_engaging: int = 1
## Кольцо спавна. Было 270–520: враг появлялся ЗА горизонтом восприятия (машина видит на 40,
## оружие бьёт на 60) — игрок не встречал его, а натыкался неизвестно где и неизвестно когда.
## Теперь чуть дальше видимости: враг приходит «из-за холма», а не из ниоткуда.
## Ближняя граница ОБЯЗАНА быть заметно больше радиуса обнаружения врага (40): иначе он
## рождается уже внутри своей зоны агрессии и бросается на игрока в ту же секунду, вместо
## того чтобы патрулировать, пока к нему не подъедут. Двести — с пятикратным запасом: стоящий
## на месте игрок не должен обнаруживать рядом с собой машину, которой минуту назад не было.
@export var spawn_min_dist: float = 200.0
@export var spawn_max_dist: float = 300.0
## ТИХАЯ ЗОНА вокруг СВОЕЙ ЗАЯКОРЕННОЙ машины: туда враг не приходит вовсе (правило
## TerraTech — рядом с якорем игрока спавна нет).
##
## Нам оно нужнее, чем ей: вся производственная цепочка — фабрикатор, компонентный завод,
## склад, продавец — работает ТОЛЬКО под якорем. Без тихой зоны враг рождался в полутора
## сотнях метров от стоящей фабрики и приезжал ломать её ровно тогда, когда игрок
## раскладывает конвейер и управлять машиной не может.
@export var quiet_radius: float = 120.0
## Не появляться ПЕРЕД машиной ближе этого: игрок едет вперёд и не должен видеть, как враг
## возникает у него по курсу. Сзади и по бокам такого ограничения нет — там появление не видно.
@export var front_clear_dist: float = 240.0
@export_range(0.0, 180.0) var front_cone_deg: float = 55.0
@export var spawn_separation: float = 70.0          # не ближе этого к ДРУГИМ врагам
@export var min_height: float = 2.0                 # ниже — днища впадин (воды в мире НЕТ)
@export var max_slope: float = 8.0                  # не на обрыве
@export var ground_offset: float = 3.0

@export_group("Сон и уборка")
## Враг дальше sleep_dist от машины игрока дольше sleep_delay секунд — ЗАСЫПАЕТ: физика
## заморожена, ИИ и оружие не считаются, узел остаётся на месте.
##
## Раньше он вместо этого ТЕЛЕПОРТИРОВАЛСЯ обратно в кольцо возле игрока — «чтобы бой не
## затухал». Это и была главная причина ощущения «их слишком много»: из боя нельзя было
## выйти, отступление возвращало ту же машину тебе за спину. В TerraTech далёкий враг просто
## замирает и ждёт; уехал — значит уехал, и это единственный способ разорвать стычку.
@export var sleep_dist: float = 420.0
@export var sleep_delay: float = 20.0
## Спящие не занимают место под потолком, но и копиться до бесконечности не должны: когда их
## вместе с живыми больше max_total, самый дальний СПЯЩИЙ убирается. Захватчик не убирается
## никогда (см. ниже).
@export var max_total: int = 8
@export var map_node: Node

## РЕДКОЕ СОБЫТИЕ: Система присылает ЗАХВАТЧИКА — одну усиленную машину, которая приезжает
## именно за игроком и цель не забывает.
##
## Раньше это была «Проверка сектора»: Система объявляла квадрат вокруг игрока, ставила по
## углам светящиеся столбы, отсчитывала двенадцать секунд и присылала машину К КРАЮ КВАДРАТА.
## Квадрат строился вокруг того места, где игрок СТОЯЛ, поэтому стоящему на месте захватчик
## вылезал метрах в двадцати шести — внутри своей зоны обнаружения — и бил сразу, без единого
## шанса заметить его заранее. Вся церемония с разметкой и таймером существовала ради этого
## одного невыгодного спавна и убрана целиком.
##
## Теперь он приходит по обычному кольцу спавна, как все, но ДЕСАНТИРУЕТСЯ с высоты: падает
## с DROP_HEIGHT над землёй. Это и есть всё объявление — машина, рухнувшая с неба, читается
## сама, без столбов и обратного отсчёта.
@export_group("Захватчик")
@export var invader_enabled: bool = true
## Раз в 10–15 минут.
@export var invader_min_interval: float = 600.0
@export var invader_max_interval: float = 900.0
@export var invader_preset: int = 9                 # тяжёлая сборка (см. blocks.gd layout)
## С какой высоты над землёй он падает.
@export var invader_drop_height: float = 10.0

@export_group("Сила врага")
## Сборки от САМОЙ СЛАБОЙ к самой сильной (номера см. blocks.gd _define_layout): разведчик,
## бегун, рейдер, копейщик, таран, осадная. Ступени растут и по опасности, и по РАЗМЕРУ —
## по машине на горизонте сразу понятно, во что ввязываешься.
@export var preset_tiers: Array[int] = [5, 6, 7, 8, 9, 10]   # scout → runner → raider → lancer → breaker → siege
## С какой стоимости машины игрока (сумма G.shop_price её блоков) начинается каждая ступень.
## Стартовая кабина ≈ 1800, готовая боевая машина — тысяч десять.
@export var tier_from_value: Array[int] = [0, 6000, 9000, 13000, 18000, 26000]

var _enemies: Array = []
var _clean_t: float = 0.0                           # троттл чистки списка от мёртвых врагов
var _far_time: Dictionary = {}                      # enemy -> сколько секунд он «далеко»
var _invader: Node3D = null                         # единственный захватчик, если он сейчас есть
var _t: float = 0.0
var _ready_done: bool = false
var _seeded: bool = false          # стартовая партия врагов уже поставлена

var _invader_t: float = 0.0                         # до следующего захватчика

func _ready() -> void:
	# Ждём загрузку рельефа (map грузит md после своего await).
	var guard: int = 0
	var map: Node = _find_map()
	while (map == null or not map.has_method("get_dims") or map.get_dims().x <= 0) and guard < 300:
		await get_tree().process_frame
		map = _find_map()
		guard += 1
	_ready_done = map != null and map.has_method("get_dims") and map.get_dims().x > 0
	_invader_t = randf_range(invader_min_interval, invader_max_interval)

func _process(delta: float) -> void:
	if not _ready_done:
		return
	# Чистка списка — раз в 0.5с, а не каждый кадр: .filter() создавал новую Callable + новый
	# Array и звал is_instance_valid на всех врагах 60 раз в секунду ради события, которое
	# случается редко (смерть врага). На счёт лимита это не влияет — проверка ниже переживёт
	# полсекунды с мёртвой записью.
	_clean_t -= delta
	if _clean_t <= 0.0:
		_clean_t = 0.5
		_enemies = _enemies.filter(func(e): return is_instance_valid(e))
	_track_dormancy(delta)
	_limit_engagement()
	_invader_tick(delta)                            # редкое событие: десант захватчика
	# Потолок считается по БОДРСТВУЮЩИМ. Спящий стоит за горизонтом, ничего не делает и на
	# ощущение «сколько их вокруг» не влияет — считать его занятым местом значило бы, что
	# четыре забытые в поле машины навсегда выключают спавн.
	if _awake_count() >= max_enemies:
		return
	# Первый заход: наполняем мир сразу, а не по одному с паузой.
	if not _seeded and not _tutorial_active():
		_seeded = true
		for _i in mini(initial_enemies, max_enemies):
			_spawn_one()
		_t = spawn_interval
		return
	_t -= delta
	if _t > 0.0:
		return
	_t = spawn_interval
	_spawn_one()

# Кто СЕЙЧАС имеет право драться. Право получают ближайшие к игроку max_engaging врагов из
# тех, кто его уже заметил; остальным бой запрещён, и они ведут себя как патрульные.
#
# Считаем по РАССТОЯНИЮ, а не по очереди «кто первый заметил»: иначе право оставалось бы у
# врага, который уже уехал за холм, а тот, что дышит игроку в затылок, стоял бы и ждал.
#
# Признак «желает драться» — наличие цели, и это работает только потому, что запрет её больше
# НЕ СБРАСЫВАЕТ (см. enemy_vehicle._update_ai). Когда сбрасывал, признак зависел от того, что
# сам же запрет и уничтожал: враг мгновенно снова считался свободным, право возвращалось,
# цель находилась заново — и так триста раз в минуту, со стрельбой на каждом витке.
func _limit_engagement() -> void:
	var player: Node3D = _player()
	if player == null:
		return
	var seekers: Array = []
	for e in _enemies:
		if not is_instance_valid(e) or not e.has_method("set_combat_allowed"):
			continue
		if _is_asleep(e):
			continue                           # спящий не дерётся и место в бою не занимает
		if e.get("_target") != null:
			seekers.append(e)
		else:
			e.set_combat_allowed(true)         # цели нет — ограничивать нечего
	seekers.sort_custom(func(a, b):
		return player.global_position.distance_squared_to(a.global_position) \
				< player.global_position.distance_squared_to(b.global_position))
	for i in seekers.size():
		seekers[i].set_combat_allowed(i < max_engaging)

# Далёкие враги ЗАСЫПАЮТ, а не возвращаются к игроку.
#
# Прежняя версия телепортировала их обратно в кольцо спавна, «чтобы стычка не затухала».
# Именно она и делала бой бесконечным: отступать было некуда — та же машина возникала
# сзади. В TerraTech далёкий враг просто замирает и ждёт, и отступление снова работает.
func _track_dormancy(delta: float) -> void:
	for k in _far_time.keys():
		if not is_instance_valid(k):
			_far_time.erase(k)
	var player: Node3D = _player()
	if player == null:
		return
	for e in _enemies:
		if not is_instance_valid(e):
			continue
		# Квадраты: порог сравнивается с порогом, корень ничего не меняет. Цикл идёт по ВСЕМ
		# врагам каждый кадр — здесь это самый горячий distance в проекте.
		var d2: float = player.global_position.distance_squared_to(e.global_position)
		if d2 > sleep_dist * sleep_dist:
			_far_time[e] = float(_far_time.get(e, 0.0)) + delta
			if _far_time[e] >= sleep_delay:
				_sleep(e)
		else:
			_far_time.erase(e)
			_wake(e)
	_release_lost_invader(player)
	_trim_sleepers(player)

# Захватчик занимает свой слот, пока жив, и уборкой спящих не трогается — иначе он не был бы
# событием. Но «пока жив» без оговорок означало бы «навсегда»: игрок уехал, тот заснул за
# горизонтом, и проверка сектора больше НИКОГДА никого не присылает, потому что слот занят
# машиной, которую никто уже не встретит. Считаем такого отставшим: он гнался и потерял.
const INVADER_GIVE_UP: float = 2.0        # во сколько раз дальше sleep_dist — уже не догонит

func _release_lost_invader(player: Node3D) -> void:
	if _invader == null or not is_instance_valid(_invader):
		_invader = null
		return
	if not _is_asleep(_invader):
		return
	var give_up: float = sleep_dist * INVADER_GIVE_UP
	if player.global_position.distance_squared_to(_invader.global_position) < give_up * give_up:
		return
	_enemies.erase(_invader)
	_invader.queue_free()
	_invader = null

# Спящий: физика заморожена, ИИ и оружие не тикают. process_mode гасит ВСЮ ветку — иначе
# турели дочерних блоков продолжали бы крутиться и стрелять за горизонтом.
func _sleep(e: Node3D) -> void:
	if bool(e.get_meta("asleep", false)):
		return
	e.set_meta("asleep", true)
	if e is RigidBody3D:
		e.linear_velocity = Vector3.ZERO
		e.angular_velocity = Vector3.ZERO
		e.freeze = true
	e.process_mode = Node.PROCESS_MODE_DISABLED

func _wake(e: Node3D) -> void:
	if not bool(e.get_meta("asleep", false)):
		return
	e.set_meta("asleep", false)
	e.process_mode = Node.PROCESS_MODE_INHERIT
	if e is RigidBody3D:
		e.freeze = false
		e.sleeping = false

func _is_asleep(e: Node) -> bool:
	return is_instance_valid(e) and bool(e.get_meta("asleep", false))

func _awake_count() -> int:
	var n: int = 0
	for e in _enemies:
		if is_instance_valid(e) and not _is_asleep(e) and e != _invader:
			n += 1
	return n

# Спящие не занимают место под потолком — значит могут копиться, пока игрок колесит по
# карте. Когда машин суммарно больше max_total, самая дальняя СПЯЩАЯ убирается: бодрствующих
# трогать нельзя (они в бою), захватчика — тоже (он по определению ждёт сколько угодно).
func _trim_sleepers(player: Node3D) -> void:
	if _enemies.size() <= max_total:
		return
	var worst: Node3D = null
	var worst_d2: float = -1.0
	for e in _enemies:
		if not is_instance_valid(e) or e == _invader or not _is_asleep(e):
			continue
		if bool(e.get_meta("story", false)):
			continue                           # враг, приведённый квестом: его ждёт задание
		var d2: float = player.global_position.distance_squared_to((e as Node3D).global_position)
		if d2 > worst_d2:
			worst_d2 = d2
			worst = e
	if worst != null:
		_enemies.erase(worst)
		worst.queue_free()

func _spawn_one() -> void:
	if enemy_scenes.is_empty() or _tutorial_active():
		return
	var map: Node = _find_map()
	var player: Node3D = _player()
	if map == null or player == null:
		return
	var pos = _find_spawn_pos(map, player.global_position)
	if pos == null:
		return

	var enemy: Node3D = enemy_scenes.pick_random().instantiate()
	# Сборка — ДО add_child (blocks строит машину в своём _ready).
	var blocks := enemy.get_node_or_null("blocks")
	if blocks and "layout_preset" in blocks:
		blocks.layout_preset = _pick_preset(player)

	var vehicles: Node = _vehicles_root()
	if vehicles == null:
		return
	vehicles.add_child(enemy)
	enemy.global_position = pos
	if enemy.has_signal("died") and not enemy.died.is_connected(_on_enemy_died):
		enemy.died.connect(_on_enemy_died)
	_enemies.append(enemy)

# Какую сборку прислать. Правило TerraTech: враг примерно того же веса, что твоя машина, —
# там он подбирается по суммарной стоимости блоков, и у нас такая стоимость наконец есть
# (G.shop_price считается из рецепта). Раньше сборка бралась кубиком, и в стартовую кабину
# могли приехать две пушки.
#
# Со ступени иногда спускаемся на одну вниз: если сила жёстко следует за игроком, каждый бой
# одинаково тяжёлый, и расти незачем — лёгкая цель должна иногда попадаться.
func _pick_preset(player: Node3D) -> int:
	if preset_tiers.is_empty():
		return 0
	var value: int = _machine_value(player)
	var tier: int = 0
	for i in mini(preset_tiers.size(), tier_from_value.size()):
		if value >= int(tier_from_value[i]):
			tier = i
	if tier > 0 and randf() < 0.33:
		tier -= 1
	return int(preset_tiers[tier])

# Во сколько обходится машина: сумма магазинных цен её блоков. Той же меркой считается всё
# остальное в игре, поэтому «сильнее» здесь значит ровно то же, что и в гараже.
func _machine_value(machine: Node3D) -> int:
	var blocks: Node = machine.get_node_or_null("blocks") if machine != null else null
	if blocks == null:
		return 0
	var v: int = 0
	for b in blocks.get_children():
		if "block" in b:
			v += G.shop_price(int(b.get("block")))
	return v

## Разведчик РЯДОМ с игроком — сюжетный спавн после обучения. Обычный поток врагов держит
## дистанцию spawn_min_dist (270 м), чтобы не наваливаться; здесь наоборот нужно, чтобы
## игрок его сразу увидел, поэтому кольцо своё и слабая сборка (preset 0).
## Возвращает врага или null, если рядом не нашлось ровного места.
func spawn_scout_near_player(min_d: float = 20.0, max_d: float = 40.0) -> Node3D:
	if enemy_scenes.is_empty():
		return null
	var map: Node = _find_map()
	var player: Node3D = _player()
	var vehicles: Node = _vehicles_root()
	if map == null or player == null or vehicles == null:
		return null
	var center: Vector3 = player.global_position
	var pos = null
	var base: float = randf() * TAU
	for i in 24:
		var ang: float = base + TAU * float(i) / 24.0
		var dist: float = randf_range(min_d, max_d)
		var world := center + Vector3(cos(ang) * dist, 0.0, sin(ang) * dist)
		var h: float = map.terrain_height_at(world)
		if h < min_height or _slope_at(map, world) > max_slope:
			continue
		pos = Vector3(world.x, h + ground_offset, world.z)
		break
	if pos == null:
		return null
	var enemy: Node3D = enemy_scenes.pick_random().instantiate()
	var blocks := enemy.get_node_or_null("blocks")
	if blocks and "layout_preset" in blocks:
		# САМАЯ СЛАБАЯ ступень, а не «сборка номер 0»: первый бой должен быть посильным, и
		# раньше здесь стоял пресет 0 просто потому, что он первый в списке — а он не самый
		# лёгкий. Теперь порядок ступеней задан в preset_tiers, и слабейшая берётся оттуда.
		blocks.layout_preset = int(preset_tiers[0]) if not preset_tiers.is_empty() else 0
	vehicles.add_child(enemy)
	enemy.global_position = pos
	# Метка «сюжетный»: уборка спящих его не удалит. Без неё квест «уничтожь разведчика» мог
	# бы стать невыполнимым молча — игрок уехал, разведчик заснул, уборка сняла его как самого
	# дальнего, а задание осталось висеть с целью, которой больше нет.
	enemy.set_meta("story", true)
	if enemy.has_signal("died") and not enemy.died.is_connected(_on_enemy_died):
		enemy.died.connect(_on_enemy_died)
	_enemies.append(enemy)
	return enemy

# Пока обучение не закончено, случайный поток врагов и проверки сектора молчат: игрока
# ведут за руку, и рейдер посреди вводной только мешает. Первого врага приводит сюжет
# (tutorial_director после закрытия последнего шага) — он спавнится в обход этого гейта.
func _tutorial_active() -> bool:
	var q: Node = get_node_or_null("/root/Q")
	return q != null and q.has_method("tutorial_active") and q.tutorial_active()

func _on_enemy_died(enemy: Node) -> void:
	# Список чистит _process по is_instance_valid; здесь важно только освободить слот
	# захватчика — пока он занят, новая проверка сектора никого не присылает.
	if enemy == _invader:
		_invader = null

# Точка спавна: кольцо вокруг игрока, на рельефе, не на обрыве, и НЕ вплотную к другим
# врагам (чтобы не кучковались). Угол берём с шагом-«секторами» + джиттер: даже под нагрузкой
# точки расходятся по кольцу, а не бьют в одно место. exclude — враг, которого не считаем
# соседом (при телепорте его самого). Возвращает Vector3 или null.
# Точка спавна в кольце вокруг игрока.
#
# Кольцо поделено на секторы, и новый враг идёт в ТОТ, ГДЕ ИХ СЕЙЧАС МЕНЬШЕ ВСЕГО, —
# равномерность получается по построению, а не как побочный эффект.
#
# Так пришлось делать в два захода. Сначала брался первый подходящий кандидат из 36 по
# кругу: когда часть кольца отбракована водой или обрывом (а это почти всегда), все спавны
# подряд сваливались в один уцелевший сектор. Потом выбиралось направление, максимально
# удалённое по углу от живых врагов, — уже лучше, но это ЖАДНЫЙ выбор: он отталкивается
# только от текущей расстановки и на неудачном рельефе всё равно перекашивал кольцо в одну
# сторону. Счётчик по секторам этим не страдает: занятый сектор не выберут, пока есть пустые.
const SPAWN_SECTORS := 8

func _find_spawn_pos(map: Node, center: Vector3, exclude: Node = null):
	# Сколько врагов уже стоит в каждом секторе.
	var per: Array[int] = []
	per.resize(SPAWN_SECTORS)
	per.fill(0)
	for e in _enemies:
		if e == exclude or not is_instance_valid(e):
			continue
		# Спящих НЕ считаем: смысл счётчика — «где вокруг игрока уже есть кто-то живой», а
		# заснувший за полкарты в этом секторе не стоит и близко. Считая его, мы запрещали
		# спавн в целой восьмой кольца из-за машины, которую игрок оставил позади час назад.
		if _is_asleep(e):
			continue
		var d: Vector3 = (e as Node3D).global_position - center
		if Vector2(d.x, d.z).length_squared() < 0.25:       # 0.5², только сравнение
			continue
		per[_sector_of(atan2(d.z, d.x))] += 1
	# Секторы по возрастанию занятости; равные — вперемешку, иначе пустая карта всегда
	# заполнялась бы с одного и того же боку.
	var order: Array[int] = []
	for i in SPAWN_SECTORS:
		order.append(i)
	order.shuffle()
	order.sort_custom(func(a, b): return per[a] < per[b])
	# Внутри сектора — несколько попыток: рельеф может не пустить в конкретную точку.
	for sec in order:
		for _try in 6:
			var ang: float = (TAU / SPAWN_SECTORS) * (float(sec) + randf())
			var dist: float = randf_range(spawn_min_dist, spawn_max_dist)
			var world := center + Vector3(cos(ang) * dist, 0.0, sin(ang) * dist)
			var h: float = map.terrain_height_at(world)
			if h < min_height:
				continue
			if _slope_at(map, world) > max_slope:
				continue
			var cand := Vector3(world.x, h + ground_offset, world.z)
			if _too_close_to_enemy(cand, exclude):
				continue
			if _in_player_view(cand, center):
				continue                       # по курсу и близко — игрок увидел бы появление
			if _near_anchored_base(cand):
				continue                       # тихая зона: у заякоренной машины игрока не спавним
			return cand
	return null

# Точка «по курсу» игрока и достаточно близко, чтобы появление было ЗАМЕТНО. Смотрим на
# направление машины, а не камеры: камеру игрок крутит постоянно, и по ней спавн стал бы
# случайным, а перед носом машины — то место, куда он едет и куда смотрит чаще всего.
func _in_player_view(pos: Vector3, center: Vector3) -> bool:
	var player: Node3D = _player()
	if player == null:
		return false
	var to: Vector3 = pos - center
	to.y = 0.0
	if to.length_squared() > front_clear_dist * front_clear_dist:
		return false                           # далеко — пусть появляется хоть прямо по курсу
	var fwd: Vector3 = -player.global_transform.basis.z
	fwd.y = 0.0
	if fwd.length_squared() < 0.0001 or to.length_squared() < 0.0001:
		return false
	return rad_to_deg(fwd.normalized().angle_to(to.normalized())) < front_cone_deg

# Точка внутри тихой зоны какой-нибудь ЗАЯКОРЕННОЙ машины игрока?
#
# Смотрим именно на якорь, а не на «есть ли рядом моя машина»: катающаяся машина в защите не
# нуждается — она может уехать. А заякоренная не может: якорь снимается вручную, под ним
# работает фабрика, и ровно в этот момент игрок занят конвейером, а не рулём.
#
# Поле anchored живёт на vehicle_body_3d (машины игрока), у врагов его нет — поэтому читаем
# через get() и молча пропускаем тех, у кого его нет.
func _near_anchored_base(pos: Vector3) -> bool:
	var vehicles: Node = _vehicles_root()
	if vehicles == null:
		return false
	for v in vehicles.get_children():
		if not (v is Node3D) or not is_instance_valid(v):
			continue
		var f = v.get("faction")
		if f != null and int(f) != 0:
			continue                           # только машины ИГРОКА
		# Сравнение с true, а НЕ bool(...): у машины без такого поля get() возвращает null, а
		# bool(null) в Godot 4 не конструируется — «Invalid call. Nonexistent bool constructor»
		# прямо в рантайме. Поле anchored живёт только на машинах игрока (vehicle_body_3d), и
		# сюда приходят чужие узлы тоже.
		if v.get("anchored") != true:
			continue
		if pos.distance_squared_to((v as Node3D).global_position) < quiet_radius * quiet_radius:
			return true
	return false

func _sector_of(ang: float) -> int:
	return int(wrapf(ang, 0.0, TAU) / (TAU / SPAWN_SECTORS)) % SPAWN_SECTORS

# Есть ли уже враг ближе spawn_separation (по горизонтали) к точке pos.
func _too_close_to_enemy(pos: Vector3, exclude: Node) -> bool:
	for e in _enemies:
		if e == exclude or not is_instance_valid(e):
			continue
		var d := Vector2(pos.x - e.global_position.x, pos.z - e.global_position.z)
		if d.length_squared() < spawn_separation * spawn_separation:
			return true
	return false

func _slope_at(map: Node, world: Vector3) -> float:
	var s: float = 3.0
	var hx1: float = map.terrain_height_at(world + Vector3(s, 0, 0))
	var hx2: float = map.terrain_height_at(world + Vector3(-s, 0, 0))
	var hz1: float = map.terrain_height_at(world + Vector3(0, 0, s))
	var hz2: float = map.terrain_height_at(world + Vector3(0, 0, -s))
	return maxf(maxf(hx1, hx2), maxf(hz1, hz2)) - minf(minf(hx1, hx2), minf(hz1, hz2))

func _find_map() -> Node:
	if map_node:
		return map_node
	var m: Node = get_node_or_null("../map")
	if m == null:
		m = get_node_or_null("/root/Main/map")
	return m

func _vehicles_root() -> Node:
	var v: Node = get_node_or_null("../Vehicles")
	if v == null:
		v = get_node_or_null("/root/Main/Vehicles")
	return v

func _player() -> Node3D:
	var cc: Node = get_tree().get_first_node_in_group("camera_controller")
	if cc and "current_vehicle" in cc and is_instance_valid(cc.current_vehicle):
		return cc.current_vehicle
	return null

# ── Захватчик (редкое событие) ────────────────────────────────────────────────
func _invader_tick(delta: float) -> void:
	if not invader_enabled:
		return
	_invader_t -= delta
	if _invader_t > 0.0:
		return
	# Пока предыдущий жив — нового не присылаем: их одновременно ровно ОДИН. Проверяем ДО
	# объявления, иначе Система обещала бы то, чего не будет.
	if _invader != null and is_instance_valid(_invader):
		_invader_t = 60.0
		return
	if _spawn_invader(_player()):
		_invader_t = randf_range(invader_min_interval, invader_max_interval)
	else:
		_invader_t = 30.0                  # не нашли места — попробуем позже

# ЗАХВАТЧИК: усиленная машина, ДЕСАНТИРУЕТСЯ с высоты и сразу знает, за кем пришла.
#
# Точку берём обычную, из кольца спавна (_find_spawn_pos) — ту же, что у рядовых врагов, со
# всеми её правилами: не в тихой зоне у якоря, не по курсу игрока, не вплотную к другим.
# Раньше он появлялся у края квадрата вокруг игрока, то есть в паре десятков метров, и
# начинал бой в ту же секунду.
#
# Он намеренно не подчиняется остальным правилам: не считается под потолком max_enemies, не
# убирается уборкой спящих и цель не забывает. Это событие, а не фон.
func _spawn_invader(locked: Node3D) -> bool:
	if enemy_scenes.is_empty():
		return false
	var map: Node = _find_map()
	var vehicles: Node = _vehicles_root()
	var player: Node3D = _player()
	if map == null or vehicles == null or player == null:
		return false
	var pos = _find_spawn_pos(map, player.global_position)
	if pos == null:
		return false
	var enemy: Node3D = enemy_scenes.pick_random().instantiate()
	var blocks := enemy.get_node_or_null("blocks")
	if blocks and "layout_preset" in blocks:
		blocks.layout_preset = invader_preset
	vehicles.add_child(enemy)
	# ПАДАЕТ с высоты: обычный спавн ставит машину на ground_offset над землёй, а этот —
	# на invader_drop_height. Удар о землю машина переживает (подвеска + _flip_recover),
	# зато прибытие видно и слышно, и это всё объявление, которое ему нужно.
	enemy.global_position = (pos as Vector3) + Vector3.UP * invader_drop_height
	if enemy is RigidBody3D:
		(enemy as RigidBody3D).linear_velocity = Vector3.ZERO
	if enemy.has_signal("died") and not enemy.died.is_connected(_on_enemy_died):
		enemy.died.connect(_on_enemy_died)
	# Цель назначаем сразу, не дожидаясь его зоны обнаружения, и включаем relentless: обычный
	# враг ищет цель сам и может её потерять, а этот приехал именно за той машиной.
	_lock_on_target(enemy, locked)
	_enemies.append(enemy)
	_invader = enemy
	_say("System", "⚠ Handler dispatched to your position.")
	return true

# Жёстко назначить врагу цель (без ожидания сигнала зоны обнаружения) и сделать его
# невідступным: обычный враг цель ищет сам и может её потерять, захватчик — нет.
func _lock_on_target(enemy: Node, target: Node3D) -> void:
	if target == null or not is_instance_valid(target):
		return
	if enemy.has_method("assign_target"):
		enemy.assign_target(target, true)

func _say(speaker: String, text: String) -> void:
	var d: Node = get_node_or_null("/root/Dialogue")
	if d and d.has_method("say"):
		d.say(speaker, text)
