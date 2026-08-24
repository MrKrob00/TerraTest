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

@export_group("Вражеские базы")
## ВРАЖЕСКИЕ БАЗЫ — то, ради чего на карте есть куда ехать. Это обычная машина врага с
## флагом is_base: заякорена, не ездит, отстреливается, разбирается по блокам и платит ДИ по
## своей стоимости, как всё остальное. Держим их отдельным списком, а НЕ в общем потоке
## врагов: потолок бодрствующих (max_enemies) считает тех, кто ездит и ищет игрока, и
## стоящая за холмом постройка не должна занимать это место — иначе две базы в округе
## выключали бы весь остальной мир.
@export var max_bases: int = 2
## Кольцо, в котором базы живут вокруг игрока. Ближняя граница заметно больше обзора врага:
## база не должна «появиться» на глазах, её надо ВСТРЕТИТЬ.
@export var base_min_dist: float = 260.0
@export var base_max_dist: float = 520.0
## Как часто пробуем поставить недостающую базу. Редко: это не поток врагов, а обстановка.
@export var base_interval: float = 40.0
## Пресеты баз (blocks.gd): аванпост и форт. Порядок — по опасности, как у машин.
@export var base_presets: Array[int] = [11, 12]

## Сколько врагов ОДНОВРЕМЕННО могут вести бой с игроком. Остальные патрулируют, пока место
## не освободится. Без этого потолка машины, заметив игрока, ехали на него все разом —
## и это не бой, а казнь: отбиться от толпы нечем, а разъехаться она не даёт.
## ОДИН: бой один на один читается и выигрывается, а второй нападающий превращает его
## в свалку, где решает не умение, а количество.
@export var max_engaging: int = 1
## Кольцо спавна. Ближняя граница НЕ ЗАДАЁТСЯ ЧИСЛОМ, а СЧИТАЕТСЯ: радиус обзора врага плюс
## запас (_spawn_min_dist). Смысл в том, что спавн ближе «сколько враг видит» — это машина,
## которая родилась и в ту же секунду поехала драться, а игрок даже не понял, откуда она
## взялась. Зашитое число тут разъезжалось бы с обзором при первой же его правке: радиус уже
## менялся с 85 на 40, и граница про это не знала.
##
## Запас нужен сверх обзора: враг должен ещё какое-то время патрулировать, чтобы игрок успел
## его заметить и решить — объехать или подраться.
##
## Тем же запасом меряется расстояние до ДРУГИХ врагов при выборе точки (_too_close_to_enemy):
## «безопасно» — величина одна, и держать её двумя числами значит однажды их разойти.
@export var spawn_safe_margin: float = 40.0
## Радиус обзора берём у ЖИВОГО врага (он же может отличаться у сборок). Пока врагов нет —
## брать неоткуда, поэтому значение по умолчанию.
@export var enemy_detect_fallback: float = 40.0
@export var spawn_max_dist: float = 160.0
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
# Запас до ДРУГИХ врагов — тот же spawn_safe_margin, что и до игрока. Одно число на оба
# правила намеренно: это одна и та же величина «насколько далеко считается безопасно», и
# двумя экспортами она рано или поздно разъехалась бы. Было 70 отдельным числом.
## ВСЕ враги ДЕСАНТИРУЮТСЯ: появляются на этой высоте над рельефом и падают.
##
## Отсюда же и то, чего здесь БОЛЬШЕ НЕТ — отбраковки точек по высоте и уклону. Она искала
## ровное место, чтобы машина не возникла в стене обрыва, и стоила пяти сэмплов рельефа на
## каждого кандидата (высота плюс четыре вокруг для уклона), а кандидатов до сорока восьми.
## Падающей машине ровное место не нужно: она сама скатится с уклона, а перевернётся —
## встанет (_flip_recover в enemy_vehicle). Проверять землю, чтобы аккуратно поставить туда
## то, что и так прилетит сверху, смысла нет.
@export var drop_height: float = 10.0

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

## РЕДКОЕ СОБЫТИЕ «Проверка сектора» (лор цифровой симуляции): Система объявляет проверку
## квадрата вокруг игрока, даёт время сбежать, и если он не покинул квадрат — присылает
## ЗАХВАТЧИКА. Заглянул в квадрат — беги.
##
## Раньше присылала отряд из пяти. Вместе с девятью обычными это давало четырнадцать машин
## разом — то есть один сценарий отменял весь баланс плотности. Теперь, как invader в
## TerraTech, он ОДИН: сильный, помнит цель, не деспавнится и ждёт, сколько понадобится.
## Одна такая машина страшнее пяти обычных и при этом не превращает карту в свалку.
@export_group("Проверка сектора")
@export var scan_enabled: bool = true
## Раз в 10–15 минут — темп invader'а в TerraTech. Было 3–7, и «редкое событие» приходило
## чаще, чем игрок успевал построить фабрику.
@export var scan_min_interval: float = 600.0
@export var scan_max_interval: float = 900.0
@export var scan_half_size: float = 32.0            # полугабарит квадрата (4×4 чанка по 16 = 64)
@export var scan_warn_time: float = 12.0            # сколько секунд на побег
@export var scan_preset: int = 9                    # тяжёлая сборка (см. blocks.gd layout)
## Захватчик десантируется с той же высоты, что и все (drop_height): у него это особенно
## важно — появляется он у края квадрата, то есть рядом с игроком, и без падения читалось как
## «машина возникла в двадцати метрах и сразу открыла огонь».

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

var _scan_state: int = 0                            # 0 — покой, 1 — идёт предупреждение
var _scan_t: float = 0.0                            # до следующей проверки
var _scan_left: float = 0.0                         # осталось до зачистки
var _scan_center: Vector3 = Vector3.ZERO
var _scan_marker: Node3D = null

func _ready() -> void:
	# Ждём загрузку рельефа (map грузит md после своего await).
	var guard: int = 0
	var map: Node = _find_map()
	while (map == null or not map.has_method("get_dims") or map.get_dims().x <= 0) and guard < 300:
		await get_tree().process_frame
		map = _find_map()
		guard += 1
	_ready_done = map != null and map.has_method("get_dims") and map.get_dims().x > 0
	_scan_t = randf_range(scan_min_interval, scan_max_interval)

func _process(delta: float) -> void:
	var _pf := Perf.now()          # profiler mark (perf.gd)
	_tick_spawner(delta)
	Perf.mark("spawner", _pf)

func _tick_spawner(delta: float) -> void:
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
	_scan_tick(delta)                               # редкое событие «проверка сектора»
	_bases_tick(delta)                              # обстановка на карте: вражеские базы
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
		# Считаем только тех, кто идёт НА ИГРОКА. Ограничение существует, чтобы на него не
		# наваливались толпой; двое врагов, стреляющих ДРУГ В ДРУГА (событие «Crossfire»),
		# к игроку отношения не имеют, и запрещать одному из них бой значило бы гасить драку,
		# ради которой событие и придумано.
		var t = e.get("_target")
		if t != null and t == player:
			seekers.append(e)
		else:
			e.set_combat_allowed(true)         # цели нет или цель не игрок — не ограничиваем
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
	# БАЗЫ ЗАСЫПАЮТ ПО ТЕМ ЖЕ ПРАВИЛАМ. Они не ездят, но на каждой стоит по несколько турелей,
	# а WeaponBlock тикает каждый физкадр — три базы за горизонтом это десяток стволов, которые
	# ищут цель в пустоте. Спящая ветка выключена целиком (_sleep), и это ровно то, ради чего
	# дремота и придумана. В потолок бодрствующих (max_enemies) базы при этом не входят: там
	# считаются те, кто едет к игроку.
	for e in _enemies + _bases:
		if not is_instance_valid(e):
			continue
		# Квадраты: порог сравнивается с порогом, корень ничего не меняет. Цикл идёт по ВСЕМ
		# врагам каждый кадр — здесь это самый горячий distance в проекте.
		var d2: float = player.global_position.distance_squared_to(e.global_position)
		# ТЕНЬ — ТОЛЬКО ВБЛИЗИ. Отбрасывание тени это второй проход по всей геометрии машины, а у
		# неё тридцать-сорок отдельных блоков. За сотню метров тень от машины — пятно в пару
		# пикселей, и платить за него удвоением её вызовов отрисовки бессмысленно. Переключаем
		# ТОЛЬКО на смене состояния: обход блоков стоит денег, а расстояние меняется плавно.
		var want_shadow: bool = d2 < SHADOW_DIST * SHADOW_DIST
		if bool(e.get_meta("shadows_on", true)) != want_shadow:
			e.set_meta("shadows_on", want_shadow)
			_set_shadows(e, want_shadow)
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
## Дальше этого расстояния машина перестаёт отбрасывать тень (принимать — продолжает).
const SHADOW_DIST: float = 90.0

## Проставить отбрасывание тени всей ветке узла. Зовётся на смене состояния, не по кадрам.
func _set_shadows(n: Node, on: bool) -> void:
	var gi := n as GeometryInstance3D
	if gi != null:
		gi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if on \
				else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	for c in n.get_children():
		_set_shadows(c, on)

func _sleep(e: Node3D) -> void:
	if bool(e.get_meta("asleep", false)):
		return
	e.set_meta("asleep", true)
	if e is RigidBody3D:
		e.linear_velocity = Vector3.ZERO
		e.angular_velocity = Vector3.ZERO
		e.freeze = true
	e.process_mode = Node.PROCESS_MODE_DISABLED
	# И ПРЯЧЕМ. Выключенный process не убирает машину из кадра: спящий враг за четыреста
	# метров — это несколько пикселей на экране и тридцать-сорок ОТДЕЛЬНЫХ мешей в счётчике
	# вызовов отрисовки, у каждого свой блок. Он заморожен и ничего не делает; рисовать его
	# незачем. Просыпается — показывается обратно.
	e.visible = false

func _wake(e: Node3D) -> void:
	if not bool(e.get_meta("asleep", false)):
		return
	e.set_meta("asleep", false)
	e.process_mode = Node.PROCESS_MODE_INHERIT
	e.visible = true
	# БАЗУ НЕ РАЗМОРАЖИВАЕМ. Она стоит на якоре по своей природе, а не потому, что спит:
	# сняв freeze, мы бы уронили постройку без колёс на первом же физ-шаге — у неё коллизия
	# off-центровая, и её кренит (та же грабля, что у нашей станции при постановке).
	if e is RigidBody3D and e.get("is_base") != true:
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
	if enemy is RigidBody3D:
		(enemy as RigidBody3D).linear_velocity = Vector3.ZERO   # падает своим весом, а не броском
	if enemy.has_signal("died") and not enemy.died.is_connected(_on_enemy_died):
		enemy.died.connect(_on_enemy_died)
	_enemies.append(enemy)

# ── ВРАЖЕСКИЕ БАЗЫ ────────────────────────────────────────────────────────────
var _bases: Array = []
var _base_t: float = 0.0

func _bases_tick(delta: float) -> void:
	_base_t -= delta
	if _base_t > 0.0:
		return
	_base_t = base_interval
	if _tutorial_active():
		return
	var player: Node3D = _player()
	if player == null:
		return
	# Базу, оставшуюся далеко за спиной, УБИРАЕМ и ставим новую впереди. Сохранять их негде
	# (врагов сейв не пишет вовсе), а держать на другом конце карты — платить за то, чего
	# игрок уже не увидит. Порог заметно больше кольца спавна: база, к которой игрок только
	# что ехал, не должна исчезать у него за спиной.
	var drop_d2: float = (base_max_dist * 1.6) * (base_max_dist * 1.6)
	var kept: Array = []
	for b in _bases:
		if not is_instance_valid(b):
			continue
		if (b as Node3D).global_position.distance_squared_to(player.global_position) > drop_d2:
			(b as Node3D).queue_free()
			continue
		kept.append(b)
	_bases = kept
	if _bases.size() >= max_bases:
		return
	_spawn_base(player)

func _spawn_base(player: Node3D) -> void:
	if base_presets.is_empty() or enemy_scenes.is_empty():
		return
	var map: Node = _find_map()
	if map == null:
		return
	# Место ищем в своём кольце и подальше от чужих баз — иначе две подряд читаются как одна
	# укреплённая зона, а не как две встречи.
	for _try in 12:
		var ang: float = randf() * TAU
		var dist: float = randf_range(base_min_dist, base_max_dist)
		var p: Vector3 = player.global_position + Vector3(cos(ang) * dist, 0.0, sin(ang) * dist)
		if _too_close_to_bases(p):
			continue
		var enemy: Node3D = enemy_scenes.pick_random().instantiate()
		enemy.set("is_base", true)                  # ДО add_child: _ready по нему морозит тело
		var blocks := enemy.get_node_or_null("blocks")
		if blocks and "layout_preset" in blocks:
			blocks.layout_preset = int(base_presets.pick_random())
			if "is_station" in blocks:
				blocks.is_station = true            # на базу нельзя ставить кабину и колёса
		var vehicles: Node = _vehicles_root()
		if vehicles == null:
			return
		vehicles.add_child(enemy)
		# СТАВИМ НА ЗЕМЛЮ, а не десантируем: база заморожена и падать не умеет. Высоту берём
		# через G.ground_y — он же отвечает «не знаю», пока карта высот не прочитана.
		enemy.global_position = Vector3(p.x, G.ground_y(p, player.global_position.y) + 0.5, p.z)
		if enemy is Node3D:
			enemy.rotation.y = randf() * TAU
		if enemy.has_signal("died") and not enemy.died.is_connected(_on_base_died):
			enemy.died.connect(_on_base_died)
		_bases.append(enemy)
		return

func _too_close_to_bases(p: Vector3) -> bool:
	var gap2: float = base_min_dist * base_min_dist
	for b in _bases:
		if is_instance_valid(b) and (b as Node3D).global_position.distance_squared_to(p) < gap2:
			return true
	return false

func _on_base_died(b: Node) -> void:
	_bases.erase(b)

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
## дистанцию «обзор врага + запас», чтобы не наваливаться; здесь наоборот нужно, чтобы
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
		pos = Vector3(world.x, h + drop_height, world.z)
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
	if enemy is RigidBody3D:
		(enemy as RigidBody3D).linear_velocity = Vector3.ZERO   # падает своим весом
	# Метка «сюжетный»: уборка спящих его не удалит. Без неё квест «уничтожь разведчика» мог
	# бы стать невыполнимым молча — игрок уехал, разведчик заснул, уборка сняла его как самого
	# дальнего, а задание осталось висеть с целью, которой больше нет.
	enemy.set_meta("story", true)
	if enemy.has_signal("died") and not enemy.died.is_connected(_on_enemy_died):
		enemy.died.connect(_on_enemy_died)
	_enemies.append(enemy)
	return enemy

## Поставить врага В КОНКРЕТНУЮ ТОЧКУ с заданной сборкой и ФРАКЦИЕЙ. Нужен событиям: там
## машины воюют не только с игроком, но и между собой, а «свой-чужой» решается именно
## фракцией (enemy_vehicle._is_enemy сравнивает её, и 1 против 2 — уже враги).
##
## Помечается как сюжетный: уборка спящих не должна унести участника события, пока игрок до
## него едет. В общий поток он при этом попадает как обычный враг — считается, засыпает,
## подчиняется лимиту боя.
func spawn_at(pos: Vector3, preset: int, faction_id: int = 1) -> Node3D:
	if enemy_scenes.is_empty():
		return null
	var vehicles: Node = _vehicles_root()
	if vehicles == null:
		return null
	var enemy: Node3D = enemy_scenes.pick_random().instantiate()
	var blocks := enemy.get_node_or_null("blocks")
	if blocks and "layout_preset" in blocks:
		blocks.layout_preset = preset
	if "faction" in enemy:
		enemy.set("faction", faction_id)
	vehicles.add_child(enemy)
	# ДЕСАНТ отмеряем ОТ РЕЛЬЕФА В ЭТОЙ ТОЧКЕ, а не от высоты переданной точки. Зовут нас
	# со смещением («охранник в двенадцати метрах от груза», «дуэлянты по бокам центра»), и
	# высота там своя: на склоне десять метров запаса съедаются холмом, и машина появлялась
	# ВНУТРИ земли. Кольцевой спавн так и делал с самого начала — здесь этого не хватало.
	var ground: float = G.ground_y(pos, pos.y)
	enemy.global_position = Vector3(pos.x, maxf(pos.y, ground) + drop_height, pos.z)
	if enemy is RigidBody3D:
		(enemy as RigidBody3D).linear_velocity = Vector3.ZERO
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
	# Границы кольца считаем ОДИН РАЗ на поиск: обзор врага за время перебора не меняется.
	var near: float = _spawn_min_dist()
	var far: float = maxf(spawn_max_dist, near + 20.0)   # кольцо не может быть вывернутым
	# Внутри сектора — несколько попыток: точку может занять сосед, курс игрока или тихая зона.
	for sec in order:
		for _try in 6:
			var ang: float = (TAU / SPAWN_SECTORS) * (float(sec) + randf())
			var dist: float = randf_range(near, far)
			var world := center + Vector3(cos(ang) * dist, 0.0, sin(ang) * dist)
			var h: float = map.terrain_height_at(world)
			var cand := Vector3(world.x, h + drop_height, world.z)
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

## Ближняя граница кольца: НАСКОЛЬКО ДАЛЕКО ВРАГ ВИДИТ плюс запас.
func _spawn_min_dist() -> float:
	return _enemy_detect_radius() + spawn_safe_margin

## Радиус обзора врага. Спрашиваем у живого — сборки могут отличаться, и зашивать сюда копию
## числа из enemy_vehicle значило бы однажды их разойти. Кешируем: за кадр он не меняется.
var _detect_cache: float = -1.0

func _enemy_detect_radius() -> float:
	if _detect_cache > 0.0:
		return _detect_cache
	for e in _enemies:
		if is_instance_valid(e):
			var r = e.get("detection_radius")
			if r != null and float(r) > 0.0:
				_detect_cache = float(r)
				return _detect_cache
	return enemy_detect_fallback

func _sector_of(ang: float) -> int:
	return int(wrapf(ang, 0.0, TAU) / (TAU / SPAWN_SECTORS)) % SPAWN_SECTORS

# Есть ли уже враг ближе spawn_safe_margin (по горизонтали) к точке pos. Без этого запаса
# новый десант падал бы на голову тому, кто уже стоит в этом секторе.
func _too_close_to_enemy(pos: Vector3, exclude: Node) -> bool:
	for e in _enemies:
		if e == exclude or not is_instance_valid(e):
			continue
		var d := Vector2(pos.x - e.global_position.x, pos.z - e.global_position.z)
		if d.length_squared() < spawn_safe_margin * spawn_safe_margin:
			return true
	return false

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

# ── Проверка сектора (редкое событие) ─────────────────────────────────────────
func _scan_tick(delta: float) -> void:
	if not scan_enabled:
		return
	if _scan_state == 0:
		_scan_t -= delta
		if _scan_t <= 0.0:
			_start_scan()
	else:
		_scan_left -= delta
		_pulse_marker()
		if _scan_left <= 0.0:
			_resolve_scan()

func _start_scan() -> void:
	var p := _player()
	if p == null:
		_scan_t = 30.0                              # игрока нет — попробуем позже
		return
	# Захватчик уже в мире — проверку не объявляем ВОВСЕ. Иначе Система обещала бы прислать
	# обработчика, а _spawn_invader молча отказывал бы по правилу «один за раз»: игрок видел
	# бы разметку квадрата, таймер, угрозу — и ничего. Пустое обещание хуже, чем тишина.
	if _invader != null and is_instance_valid(_invader):
		_scan_t = 60.0
		return
	_scan_center = p.global_position
	_scan_state = 1
	_scan_left = scan_warn_time
	_build_marker()
	# Обманка: Система ВЕЖЛИВО просит НЕ выходить — кто послушается, того зачистка :)
	_say("System", "🔍 Scheduled sector scan. Please do NOT leave the scan zone. This will take %d sec. Thank you for your cooperation." % int(scan_warn_time))

func _resolve_scan() -> void:
	_scan_state = 0
	_scan_t = randf_range(scan_min_interval, scan_max_interval)
	_clear_marker()
	var p := _player()
	# Система не отслеживает «кто ушёл» — она просто сканирует зону. Есть активность внутри
	# (техника игрока) → «что-то подозрительное» → усиленный отряд. Пусто → нейтральный отчёт.
	if p != null and _in_scan_box(p.global_position):
		_say("System", "⚠ Unauthorized activity detected in the sector. Dispatching a handler.")
		_spawn_invader(p)              # захватчик идёт именно за ЗАСЕЧЁННОЙ машиной
	else:
		_say("System", "Sector scan complete. No anomalies detected.")

func _in_scan_box(pos: Vector3) -> bool:
	return absf(pos.x - _scan_center.x) <= scan_half_size and absf(pos.z - _scan_center.z) <= scan_half_size

# ЗАХВАТЧИК — один, ДЕСАНТИРУЕТСЯ у края квадрата, сразу нацеленный на засеченную машину.
#
# Он намеренно не подчиняется обычным правилам: не считается под потолком max_enemies, не
# убирается уборкой спящих и не забывает цель. Это событие, а не фон, и работать оно должно
# как событие — пока игрок его не убьёт или не уедет насовсем.
#
# Пока предыдущий захватчик жив, нового не присылаем: их одновременно ровно один, как invader
# в TerraTech. Иначе редкое событие, случившись дважды подряд, снова превращалось бы в толпу.
func _spawn_invader(locked: Node3D = null) -> void:
	if _invader != null and is_instance_valid(_invader):
		return
	var map: Node = _find_map()
	var vehicles: Node = _vehicles_root()
	if map == null or vehicles == null or enemy_scenes.is_empty():
		return
	var enemy: Node3D = enemy_scenes.pick_random().instantiate()
	var blocks := enemy.get_node_or_null("blocks")
	if blocks and "layout_preset" in blocks:
		blocks.layout_preset = scan_preset      # усиленная сборка
	vehicles.add_child(enemy)
	var ang: float = randf() * TAU
	var r: float = scan_half_size * 0.8
	var wp: Vector3 = _scan_center + Vector3(cos(ang) * r, 0.0, sin(ang) * r)
	var h: float = map.terrain_height_at(wp) if map.has_method("terrain_height_at") else wp.y
	# ПАДАЕТ с высоты, а не возникает на земле. Появляется он у края квадрата, то есть рядом
	# с игроком; стоящему на месте это выглядело как «машина материализовалась в двадцати
	# метрах и сразу открыла огонь». Падение даёт те секунды, за которые её видно и слышно.
	enemy.global_position = Vector3(wp.x, h + drop_height, wp.z)
	if enemy is RigidBody3D:
		(enemy as RigidBody3D).linear_velocity = Vector3.ZERO
	if enemy.has_signal("died") and not enemy.died.is_connected(_on_enemy_died):
		enemy.died.connect(_on_enemy_died)
	# Цель назначаем сразу, не дожидаясь его зоны обнаружения, и включаем relentless: обычный
	# враг ищет цель сам и может её потерять, а этот приехал именно за той машиной, которую
	# засекла проверка.
	_lock_on_target(enemy, locked)
	_enemies.append(enemy)
	_invader = enemy

# Жёстко назначить врагу цель (без ожидания сигнала зоны обнаружения) и сделать его невідступным.
func _lock_on_target(enemy: Node, target: Node3D) -> void:
	if target == null or not is_instance_valid(target):
		return
	if enemy.has_method("assign_target"):
		enemy.assign_target(target, true)

# Маркер квадрата: 4 светящихся столба по углам (переживают неровный рельеф). Пульсируют,
# к концу таймера краснеют — тревога.
func _build_marker() -> void:
	_clear_marker()
	_scan_marker = Node3D.new()
	get_tree().current_scene.add_child(_scan_marker)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(0.2, 0.9, 1.0)
	mat.emission_enabled = true
	mat.emission = Color(0.2, 0.9, 1.0)
	var map: Node = _find_map()
	for sx in [-1.0, 1.0]:
		for sz in [-1.0, 1.0]:
			var pillar := MeshInstance3D.new()
			var bm := BoxMesh.new()
			bm.size = Vector3(1.4, 60.0, 1.4)
			pillar.mesh = bm
			pillar.material_override = mat
			pillar.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			var wx: float = _scan_center.x + sx * scan_half_size
			var wz: float = _scan_center.z + sz * scan_half_size
			var h: float = map.terrain_height_at(Vector3(wx, 0.0, wz)) if (map and map.has_method("terrain_height_at")) else _scan_center.y
			pillar.position = Vector3(wx, h + 28.0, wz)
			_scan_marker.add_child(pillar)
	_scan_marker.set_meta("mat", mat)

func _pulse_marker() -> void:
	if _scan_marker == null or not _scan_marker.has_meta("mat"):
		return
	var mat: StandardMaterial3D = _scan_marker.get_meta("mat")
	var t: float = 0.5 + 0.5 * sin(Time.get_ticks_msec() * 0.008)
	var danger: float = 1.0 - clampf(_scan_left / maxf(scan_warn_time, 0.01), 0.0, 1.0)
	mat.emission = Color(0.2 + danger * 0.8, 0.9 - danger * 0.7, 1.0 - danger * 0.85)
	mat.emission_energy_multiplier = 1.0 + t * 2.0 + danger * 3.0

func _clear_marker() -> void:
	if _scan_marker != null and is_instance_valid(_scan_marker):
		_scan_marker.queue_free()
	_scan_marker = null

func _say(speaker: String, text: String) -> void:
	var d: Node = get_node_or_null("/root/Dialogue")
	if d and d.has_method("say"):
		d.say(speaker, text)
