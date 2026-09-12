class_name QuestArcs
extends Node
# Ведущий сюжетной ветки: кладёт в мир то, что квест обещал, и следит, выполнено ли условие
# стадии. Сами квесты (тексты, стадии, зависимости) живут в quest_manager — здесь только их
# «физика»: что появляется в мире и что считается сделанным.
#
# Условия проверяются ОПРОСОМ раз в секунду, а не событием на постановку блока. Событие
# block_placed не знает типа блока, и учить его типу пришлось бы через всю цепочку
# постановки; опрос же не зависит от того, КАК блок попал на машину — поставил руками,
# подобрал с земли, отобрал у вора. Раз в секунду — это дёшево: обход блоков одной машины.

const POLL := 1.0

## ДИСТАНЦИЯ СПАВНА КВЕСТОВЫХ МАШИН — одна на все ветки. Раньше у каждой была своя (170..260),
## и разницы между ними игрок всё равно не видел, а держать восемь чисел про одно и то же значит
## однажды получить квест, начинающийся в двадцати метрах.
##
## УЧАСТНИКИ ПОЯВЛЯЮТСЯ СРАЗУ, а не когда игрок доедет. Отложенный спавн читался как «метка
## ведёт в пустое поле, доедешь — тогда и появятся»: до приезда там нечего было увидеть даже в
## бинокль. Далеко они всё равно ничего не стоят — спавнер их усыпляет (sleep_dist).
const EV_SPAWN_DIST := Vector2(250.0, 300.0)

func _quest_dist() -> float:
	return randf_range(EV_SPAWN_DIST.x, EV_SPAWN_DIST.y)

var _t: float = 0.0
var _props: QuestProps = null
var _dropped: Dictionary = {}      # какие стадии уже выложили своё добро в мир
var _thief: Node3D = null

func _ready() -> void:
	add_to_group("quest_arcs")     # компас берёт отсюда координаты события
	_props = QuestProps.new()
	add_child(_props)

func _process(delta: float) -> void:
	var _pf := Perf.now()          # profiler mark (perf.gd)
	_tick_arcs(delta)
	Perf.mark("quests", _pf)

func _tick_arcs(delta: float) -> void:
	_t -= delta
	if _t > 0.0:
		return
	_t = POLL
	if get_node_or_null("/root/Q") == null:
		return
	_duel_cooldown(POLL)
	_ev_cooldowns(POLL)
	for q in Q.active_quests():
		match String(q.get("event", "")):
			"quest_arc_power_1":   _arc_power_1(q)
			"quest_arc_power_2":   _arc_power_2(q)
			"quest_arc_radar_1":   _arc_radar_1(q)
			"quest_arc_radar_2":   _arc_radar_2(q)
			"quest_arc_battery_1": _arc_battery_1(q)
			"quest_arc_battery_2": _arc_battery_2(q)
			"quest_salvage_1":     _salvage_1(q)
			"quest_salvage_2":     _salvage_2(q)
			"quest_line_1":        _line_1(q)
			"quest_line_2":        _line_2(q)
			"quest_hold_1":        _hold_1(q)
			"quest_hold_2":        _hold_2(q)
			"quest_tower_1":       _tower_1(q, TOWER_WATCH)
			"quest_tower_2":       _tower_2(q, TOWER_WATCH)
			"quest_sam_1":         _tower_1(q, TOWER_SAM)
			"quest_sam_2":         _tower_2(q, TOWER_SAM)
			"quest_duel_1":        _duel_1(q)
			"quest_duel_2":        _duel_2(q)
			"quest_gang_1":        _gang_1(q)
			"quest_gang_2":        _gang_2(q)
			"quest_supply_1":      _supply_1(q)
			"quest_supply_2":      _supply_2(q)
			"quest_defend_1":      _defend_1(q)
			"quest_defend_2":      _defend_2(q)
			"quest_waves_1":       _waves_1(q)
			"quest_waves_2":       _waves_2(q)
			"quest_camp_1":        _camp_1(q)
			"quest_camp_2":        _camp_2(q)

# ── Ветка «энергия»: панель на опору, затем реген рядом ──────────────────────
# THE STAGE IS A PLACE, NOT AN INVENTORY. Handing the player a panel and a support as loose blocks
# taught nothing: the panel went onto the hull, the machine drove off, and no power appeared -
# a panel only feeds something that STANDS STILL. So the quest builds the answer in the world
# instead: an anchored support of its own, fifty metres out, with the panel lying beside it.
# Mounting that panel on that support is the whole first stage; the repair unit next to it is the
# second.
#
# The site is the factory quest's pattern (_spawn_station): a machine with no cabin, a stationary
# block as its core, anchored from birth. It belongs to the player's faction, so building on it is
# the ordinary build-on-another-machine path and the camera can switch to it.
#
# The site appears AT ONCE, not when the player drives up - the same rule as every other quest
# participant (see EV_SPAWN_DIST). Fifty metres is "visible from where you stand", so the task
# starts as a thing you can see rather than a marker into empty field.
const POWER_SITE_DIST := 50.0
## Levelled pad under the base: the build is three cells across at most, and a support on a slope
## puts the panel over a hole.
const POWER_SITE_HALF := Vector2(3.0, 3.0)
const POWER_SITE_FEATHER := 5.0
## Base cells. The core sits at the centre of the grid - every station layout puts it there, and
## _spawn_station positions the machine by that cell - the panel goes ON TOP of it.
const POWER_CORE_CELL := Vector3i(5, 5, 5)
const POWER_PANEL_CELL := Vector3i(5, 6, 5)
## Where the repair unit may stand: the four cells around the support. The blueprint points at the
## first free one, but ANY of them closes the stage - "beside the support" is the requirement, and
## refusing a neighbouring cell would be a puzzle nobody asked for.
const POWER_REGEN_CELLS := [Vector3i(5, 5, 6), Vector3i(6, 5, 5), Vector3i(4, 5, 5), Vector3i(5, 5, 4)]

var _power_point: Variant = null
var _power_base: Node3D = null

## ЧЕРТЁЖ ПОКАЗЫВАЕМ, ТОЛЬКО КОГДА ИГРОК ДОЕХАЛ. Разметка, зажигающаяся в момент объявления
## задания, — это призраки, висящие на пустом месте всю дорогу до цели: ставить в них нечего, и к
## тому моменту, когда они наконец нужны, игрок перестаёт их замечать.
const PLAN_SHOW_DIST := 20.0

func _plan_near(at: Variant) -> bool:
	if not (at is Vector3):
		return true
	var p: Node3D = _player()
	if p == null:
		return false
	return p.global_position.distance_squared_to(at as Vector3) \
			<= PLAN_SHOW_DIST * PLAN_SHOW_DIST

## Площадка ветки: точка и стоящая на ней база. true — база есть, на неё можно строить.
##
## Ровно ОДНА база за прохождение, и это стоит трёх строк проверки: точка выбирается один раз,
## база подхватывается по метке после перезахода (сейв возвращает её раньше, чем квест успевает
## опомниться), и только если её нет нигде — ставится новая. Без подхвата каждый вход в мир
## добавлял бы к прежней базе ещё одну, в новом случайном месте.
func _power_site() -> bool:
	if is_instance_valid(_power_base):
		return true
	_power_base = _adopt_quest_base("arc_power")
	if is_instance_valid(_power_base):
		_power_point = _power_base.global_position
		return true
	var p: Node3D = _player()
	if p == null:
		return false
	if _power_point == null:
		var ang: float = randf() * TAU
		var wp: Vector3 = p.global_position \
				+ Vector3(cos(ang), 0.0, sin(ang)) * POWER_SITE_DIST
		wp.y = G.ground_y(wp, p.global_position.y)
		_power_point = wp
	_flatten_site(_power_point as Vector3, POWER_SITE_HALF, POWER_SITE_FEATHER)
	_power_base = _spawn_station(_power_point as Vector3, [
		{"x": POWER_CORE_CELL.x, "y": POWER_CORE_CELL.y, "z": POWER_CORE_CELL.z,
		 "block": G.Block.SUPPORT, "rot": [0.0, 0.0, 0.0]},
	])
	if is_instance_valid(_power_base):
		# ТА ЖЕ МЕТКА, ЧТО У КВЕСТОВЫХ ПРЕДМЕТОВ. По ней база узнаётся после перезахода — и уборке
		# мира, и сейву она означает одно и то же: это не мусор, это цель задания.
		#
		# ГОВОРИТ ОДИН. Своя реплика тут повторяла подсказку стадии слово в слово, и задание
		# читалось как выданное дважды: сначала Механик, следом Система, об одном и том же.
		_power_base.set_meta(QuestProps.META, "arc_power")
	return false          # даём кадр: блоки базы появляются асинхронно

## База этого квеста, уже стоящая в мире (перезаход). Ищем по метке, а не по форме: игрок вправе
## поставить свою собственную опору, и отличать их «по похожести» значило бы однажды выдать чужую
## постройку за квестовую.
func _adopt_quest_base(quest_id: String) -> Node3D:
	var vr: Node = get_node_or_null("/root/Main/Vehicles")
	if vr == null:
		return null
	for c in vr.get_children():
		if c is Node3D and c.has_meta(QuestProps.META) \
				and String(c.get_meta(QuestProps.META)) == quest_id:
			return c as Node3D
	return null

## Что стоит в клетке базы. EMPTY — базы нет, сетки нет или клетка пуста.
func _base_block(base: Node3D, cell: Vector3i) -> int:
	if not is_instance_valid(base):
		return G.Block.EMPTY
	var bm = base.get("block_map_node")
	if bm == null or not is_instance_valid(bm) or not bm.has_method("get_block"):
		return G.Block.EMPTY
	return int(bm.get_block(cell.x, cell.y, cell.z))

## Куда показывает чертёж регена: первая свободная клетка рядом с опорой.
func _power_regen_cell() -> Vector3i:
	for c in POWER_REGEN_CELLS:
		if _base_block(_power_base, c) == G.Block.EMPTY:
			return c
	return POWER_REGEN_CELLS[0]

## ЕСТЬ ЛИ ТАКОЙ БЛОК НА БАЗЕ — ГДЕ УГОДНО, А НЕ В ЗАДУМАННОЙ КЛЕТКЕ.
##
## Стадия засчитывалась по ОДНОЙ клетке, и это давало худший из возможных отказов: игрок ставит
## панель на базу, видит её стоящей — а квест считает, что не поставил, и через секунду роняет
## рядом ВТОРУЮ (ensure спрашивает только про мир и про руку). Стоило промахнуться мимо клетки —
## и ветка выдавала панели бесконечно, требуя поставить уже поставленное.
##
## Чертёж по-прежнему показывает, КУДА советуют, но засчитываем факт: блок на базе. Задание
## звучит «поставь панель на опору», а не «попади в клетку (5,6,5)».
func _base_has(base: Node3D, bt: int) -> bool:
	if not is_instance_valid(base):
		return false
	var bm = base.get("block_map_node")
	if bm == null or not is_instance_valid(bm):
		return false
	for c in (bm as Node).get_children():
		if c.get("block") != null and int(c.get("block")) == bt:
			return true
	return false

func _arc_power_1(q: Dictionary) -> void:
	if not _power_site():
		return
	if _base_has(_power_base, G.Block.SOLAR):
		_clear_plan()
		Q.report(String(q["event"]), 1)
		return
	# Панель лежит у базы, пока её не взяли. Условие «у игрока её нет» обязательно: ensure
	# спрашивает только про мир, и без него каждый опрос ронял бы вторую панель, пока игрок везёт
	# первую в руке.
	if not _player_owns(G.Block.SOLAR):
		_props.ensure("arc_power", G.Block.SOLAR, _power_point)
	# ПАЛЕЦ СНАЧАЛА НА ПАНЕЛЬ, и только потом на клетку. Показывать место установки, пока блок
	# лежит в траве, — значит просить поставить то, чего у игрока ещё нет; а чертёж в этот момент
	# и вовсе висит на другом конце площадки.
	if _props.position_for("arc_power") != null:
		_drop_hints()
		_point_finger("Pick the panel up", "arc_power")
		return
	if _plan_near(_power_point):
		_show_plan_on(_power_base.get("block_map_node"),
				[{"cell": POWER_PANEL_CELL, "block": G.Block.SOLAR}])
		_point_finger("Panel goes on top of the support")
	else:
		_clear_plan()

func _arc_power_2(q: Dictionary) -> void:
	if not _power_site():
		return
	if _base_has(_power_base, G.Block.REGEN):
		_clear_plan()
		Q.report(String(q["event"]), 1)
		return
	# РЕГЕН ЖДЁТ У БАЗЫ, А НЕ ЛЕТИТ К ИГРОКУ. Награда, закружившая вокруг машины (award_blocks →
	# reward_orbiter), уместна, когда её можно везти куда угодно; здесь же её надо поставить ВОТ
	# НА ЭТУ базу, до которой полсотни метров. Выданный у игрока блок означал «а теперь вези его
	# обратно», причём в руке, то есть без стрельбы и с риском выронить. Кладём туда, где он
	# нужен, — тем же ensure, что и панель стадией раньше, и с той же проверкой «в руке уже есть».
	if not _player_owns(G.Block.REGEN):
		_props.ensure("arc_power", G.Block.REGEN, _power_point)
	if _plan_near(_power_point):
		_show_plan_on(_power_base.get("block_map_node"),
				[{"cell": _power_regen_cell(), "block": G.Block.REGEN}])
		_point_finger("Repair unit beside the support")
	else:
		_clear_plan()

# ══════════════════════════════════════════════════════════════════════════════
# БЛОК ВЕЗЁТ ВРАГ: не «съезди и подбери», а «отбери»
# ══════════════════════════════════════════════════════════════════════════════
# Сюжетный блок лежал в чистом поле: игрок ехал по компасу и подбирал его, ни с кем не
# встретившись, — то есть задание было дорогой, а не задачей. Теперь его ВОЗИТ вражеская
# машина, и получить блок можно только разобрав её.
#
# ГЛАВНОЕ ПРАВИЛО: убитый носитель обязан ОСТАВИТЬ блок, даже если тот сгорел в бою. Иначе
# ветка вешается насмерть из-за случайного попадания, а игрок этого не поймёт — он сделал
# ровно то, о чём просили. Поэтому в точке смерти блок ГАРАНТИРУЕТСЯ: лежит настоящий,
# сорванный с носителя, — берём его; не осталось ничего — кладём новый (QuestProps.claim_or_drop).
#
# Носитель появляется, ТОЛЬКО КОГДА ИГРОК ДОЕХАЛ, — то же правило, что у вышек: машина,
# которая с начала игры ездит на другом конце карты, ничего не добавляет, а тикает и стреляет.

var _carrier: Dictionary = {}        # ключ → машина-носитель
var _carrier_spot: Dictionary = {}   # ключ → куда ехать; после боя — где упадёт блок
var _carrier_dead: Dictionary = {}   # ключ → носителя добили

## Куда ведёт компас по этой стадии. Пока носитель жив, точка ЕДЕТ ЗА НИМ: он не стоит на
## месте, и метка, оставшаяся там, где его объявили, ведёт в пустое поле (то же правило, что
## у _live_target для событий).
func carrier_point(key: String) -> Variant:
	var m = _carrier.get(key)
	if m != null and is_instance_valid(m) and m is Node3D:
		_carrier_spot[key] = (m as Node3D).global_position
	return _carrier_spot.get(key, null)

## Стадия «отбери блок у врага». true — блок уже стоит на машине игрока.
func _carry_stage(key: String, block: int, preset: int) -> bool:
	if _has_block(block):
		return true
	var p: Node3D = _player()
	if p == null:
		return false
	if not _carrier_spot.has(key):
		var ang: float = randf() * TAU
		var dist: float = _quest_dist()
		var wp: Vector3 = p.global_position + Vector3(cos(ang) * dist, 0.0, sin(ang) * dist)
		wp.y = G.ground_y(wp, p.global_position.y)
		_carrier_spot[key] = wp
		return false
	# Носителя добили — блок его пережил (или мы кладём такой же на его место).
	if bool(_carrier_dead.get(key, false)):
		if not _player_owns(block):
			_props.claim_or_drop(key, block, _carrier_spot[key])
		return false
	var at: Vector3 = _carrier_spot[key]
	if is_instance_valid(_carrier.get(key)):
		return false                                  # едет и дерётся — ждём
	_carrier_spawn(key, block, preset, at)
	return false

func _carrier_spawn(key: String, block: int, preset: int, at: Vector3) -> void:
	var sp: Node = get_node_or_null("/root/Main/EnemySpawner")
	if sp == null or not sp.has_method("spawn_at"):
		return
	var e = sp.spawn_at(at, preset, 1)
	if e == null or not (e is Node3D):
		return
	# Блок ставим НА КАБИНУ (5,6,5): он должен быть виден снаружи, иначе «вон та машина везёт
	# радар» игроку неоткуда узнать, а метка над врагом об этом не говорит.
	var bl: Node = (e as Node3D).get_node_or_null("blocks")
	if bl != null and bl.has_method("set_block"):
		bl.set_block(5, 6, 5, block, 0.0)
	if e.has_method("assign_target"):
		e.assign_target(_player(), true)
	if e.has_signal("died"):
		e.died.connect(func(_x = null): _on_carrier_died(key), CONNECT_ONE_SHOT)
	_carrier[key] = e

func _on_carrier_died(key: String) -> void:
	# Точку смерти запоминаем ЗДЕСЬ: carrier_point обновляет её каждый опрос, пока носитель жив,
	# но после гибели узел уже освобождён и спросить его не у кого.
	var m = _carrier.get(key)
	if m != null and is_instance_valid(m) and m is Node3D:
		_carrier_spot[key] = (m as Node3D).global_position
	_carrier_dead[key] = true
	_carrier.erase(key)

# ── Ветка «радар»: отобрать у того, кто его возит, затем у вора ──────────────
func _arc_radar_1(q: Dictionary) -> void:
	# Пресет 5 — разведчик, самая слабая сборка: это первая машина, которую игрок разбирает
	# ради трофея, и проиграть ей означало бы застрять на второй ступени сюжета.
	if _carry_stage("arc_radar", G.Block.RADAR, 5):
		Q.report(String(q["event"]), 1)

func _arc_radar_2(q: Dictionary) -> void:
	var key := "radar_2"
	if not _dropped.has(key):
		_dropped[key] = true
		_thief = _spawn_thief()
		if _thief == null:
			Q.skip_quest(String(q["id"]))     # некуда поставить — не держим игрока
			return
	# Вор жив, но радара на нём уже нет — отбирать нечего, квест пропускаем. Без этого
	# случайно сбитый в бою радар вешал бы всю ветку намертво.
	if is_instance_valid(_thief):
		if not _machine_has(_thief, G.Block.RADAR):
			Q.skip_quest(String(q["id"]))
			return
	elif _thief != null:
		Q.skip_quest(String(q["id"]))         # вора уничтожили целиком
		return
	if _count_block(G.Block.RADAR) >= 2:      # свой + отобранный
		Q.report(String(q["event"]), 1)

# ── Ветка «аккумулятор»: жила его ДЕРЖИТ, пока её не выработают ──────────────
# Аккумулятор лежал в поле, как и всё остальное, и «Buried Charge» ничем не отличался от
# прогулки по компасу. Теперь он ВНУТРИ ЖИЛЫ: пока в ней есть руда, блока нет — выкопай её
# досуха, и он выпадет. Это и единственный сюжетный повод взять бур в руки после обучения.
#
# ЖИЛУ НЕ ДЕРЖИМ ССЫЛКОЙ, только точку. Жилы стримятся (узел живёт лишь рядом с камерой), и
# ссылка на неё после отъезда протухает; точка же верна всегда, а узел по ней находится тогда,
# когда игрок рядом, — то есть ровно когда его и надо спрашивать.
const BATTERY_DIST := 140.0
const BATTERY_REACH := 60.0

var _bat_spot: Variant = null       # где стоит «та самая» жила
var _bat_free: bool = false         # её выработали, блок выпал
## ПОКАЗАННЫЙ В ЖИЛЕ БЛОК. Задание говорит «он в этой жиле», а на экране до последнего удара была
## обычная руда: игрок бурил наугад и верил на слово. Кладём настоящий блок сверху на жилу —
## видно, что именно там лежит и что за это бурят.
var _bat_shown: Node3D = null
## ОН ЛЕЖИТ В ОСНОВАНИИ ЖИЛЫ, А НЕ СТОИТ У НЕЁ НА МАКУШКЕ. Аккуратный блок по центру сверху
## читается как положенный туда предмет; задание же говорит, что он ПРОЛЕЖАЛ в породе и его
## оттуда выскребают. Поэтому низко, чуть в сторону, с завалом набок и сильно побитый.
const BATTERY_SHOW_Y := 0.2
const BATTERY_SHOW_SPREAD := 0.35      # разброс по горизонтали от центра жилы, м
const BATTERY_SHOW_TILT := 0.28        # завал набок, рад (~16°)
## Сколько от него осталось. Тридцать процентов — это и «видно, что он побитый» (красные цифры
## хп над блоком), и повод дать игроку реген или ремонт, а не бесплатную целую деталь.
const BATTERY_WORN_FRAC := 0.3

## Посадка блока в жиле, посчитанная ОДИН РАЗ. Жилы стримятся: узел появляется и исчезает вместе
## с игроком, а _bat_display пересоздаёт блок каждый раз. Считай мы поворот заново — блок бы
## заметно прыгал при каждом возвращении к жиле.
var _bat_pose: Variant = null
## Побитость выдаётся один раз: иначе опрос раз в секунду срезал бы хп заново и починить
## выпавший аккумулятор было бы нельзя вовсе.
var _bat_worn: bool = false

## Куда ведёт компас по этой ветке.
func battery_point() -> Variant:
	return _bat_spot

## Общая половина обеих стадий: довести игрока до жилы и дождаться, пока он её выскребет.
## true — аккумулятор уже стоит на машине.
func _battery_stage() -> bool:
	if _has_block(G.Block.BATTERY):
		return true
	var p: Node3D = _player()
	if p == null:
		return false
	if _bat_spot == null:
		var ang: float = randf() * TAU
		var wp: Vector3 = p.global_position + Vector3(cos(ang) * BATTERY_DIST, 0.0, sin(ang) * BATTERY_DIST)
		wp.y = G.ground_y(wp, p.global_position.y)
		_bat_spot = wp
		return false
	var at: Vector3 = _bat_spot as Vector3
	if _bat_free:
		if not _player_owns(G.Block.BATTERY):
			# ВЫПАДАЕТ ИЗ ЖИЛЫ, А НЕ ВЫДАЁТСЯ НАГРАДОЙ: claim_or_drop кладёт настоящий блок в мир у
			# точки жилы, и подобрать его игрок должен сам. Награда квеста — деньги и опыт
			# (quest_manager: 210/45/14), блоков в ней нет и быть не должно.
			var dropped: Node3D = _props.claim_or_drop("arc_battery", G.Block.BATTERY, at)
			if dropped != null and not _bat_worn:
				_bat_worn = true
				_wear_battery(dropped)
		return false
	if p.global_position.distance_squared_to(at) > BATTERY_REACH * BATTERY_REACH:
		return false
	# Доехал. Настоящая жила рядом с объявленной точкой — к ней и подтягиваем метку, иначе
	# компас указывает на пустую землю в паре метров от того, что надо бурить.
	var rn: Node = get_node_or_null("/root/Main/map/Resource_Nodes")
	if rn == null:
		rn = _find_resource_nodes()
	if rn == null or not rn.has_method("node_near"):
		_bat_free = true                      # жил в мире нет вовсе — не держим игрока
		return false
	var vein: Node = rn.node_near(at, BATTERY_REACH)
	if vein == null:
		return false                          # ещё не стримнулась — подождём следующий опрос
	_bat_spot = (vein as Node3D).global_position
	if vein.call("is_depleted"):
		_bat_free = true
		_bat_hide()
	else:
		_bat_display(vein as Node3D)
	return false

## Показать блок в жиле. Жилы СТРИМЯТСЯ — узел появляется и исчезает вместе с игроком, — поэтому
## показ проверяется каждый опрос и восстанавливается, а не ставится один раз.
##
## Блок настоящий, но ИНЕРТНЫЙ: слои коллизии сняты уже ПОСЛЕ add_child, потому что VehicleBlock
## ставит себе второй слой в своём _ready. Без этого его можно было бы подобрать прямо из породы
## (луч постройки бьёт по второму слою) и по нему стреляли бы враги — цель у оружия ищется там же.
func _bat_display(vein: Node3D) -> void:
	if is_instance_valid(_bat_shown) and _bat_shown.get_parent() == vein:
		return
	_bat_hide()
	var scene: PackedScene = G.get_scene(G.Block.BATTERY)
	if scene == null:
		return
	var n: Node3D = scene.instantiate()
	vein.add_child(n)
	if _bat_pose == null:
		_bat_pose = Transform3D(
			Basis(Vector3.UP, randf() * TAU) * Basis(Vector3.RIGHT, randf_range(-BATTERY_SHOW_TILT, BATTERY_SHOW_TILT)),
			Vector3(randf_range(-BATTERY_SHOW_SPREAD, BATTERY_SHOW_SPREAD), BATTERY_SHOW_Y,
				randf_range(-BATTERY_SHOW_SPREAD, BATTERY_SHOW_SPREAD)))
	n.transform = _bat_pose as Transform3D
	if n is RigidBody3D:
		var rb := n as RigidBody3D
		rb.freeze = true
		rb.collision_layer = 0
		rb.collision_mask = 0
	_wear_battery(n)
	_bat_shown = n

## Сбить блоку хп до BATTERY_WORN_FRAC и обновить красные цифры над ним. Показанный в жиле блок
## инертен, так что для него это чистая картинка; выпавшему это реальное состояние.
func _wear_battery(n: Node) -> void:
	if n == null or not is_instance_valid(n) or not ("max_hp" in n):
		return
	n.set("current_hp", maxi(int(round(float(n.get("max_hp")) * BATTERY_WORN_FRAC)), 1))
	if n.has_method("_refresh_hp_fx"):
		n.call("_refresh_hp_fx")

func _bat_hide() -> void:
	if is_instance_valid(_bat_shown):
		_bat_shown.queue_free()
	_bat_shown = null

## Узел стриминга жил. Путь в сцене не зашиваем: он уже переезжал, а группы у узла нет —
## ищем по методу, которого больше ни у кого нет.
func _find_resource_nodes() -> Node:
	var main: Node = get_node_or_null("/root/Main")
	if main == null:
		return null
	for c in main.get_children():
		if c.has_method("active_blips"):
			return c
		for g in c.get_children():
			if g.has_method("active_blips"):
				return g
	return null

func _arc_battery_1(q: Dictionary) -> void:
	# Первая стадия — ДОЕХАТЬ до жилы: до неё полтораста метров, и это отдельный шаг, иначе
	# «найди и выкопай» закрывается одним событием и читается как одна кнопка.
	if _battery_stage():
		Q.report(String(q["event"]), 1)   # аккумулятор уже стоит — «доехать» закрываем сразу
		return
	var p: Node3D = _player()
	if p != null and _bat_spot is Vector3 \
			and p.global_position.distance_squared_to(_bat_spot as Vector3) \
				<= BATTERY_REACH * BATTERY_REACH:
		Q.report(String(q["event"]), 1)

func _arc_battery_2(q: Dictionary) -> void:
	if _battery_stage():
		Q.report(String(q["event"]), 1)

# ── «Salvage Run»: сбитый груз под охраной ───────────────────────────────────
# Замена станции из оригинала. Магазинов у нас нет, поэтому «доехать до станции и отбить её»
# превращается в «доехать до груза и отбить его», а наградой становится КОЛЛЕКТОР — блок, без
# которого не собрать производственную цепочку в следующем квесте.

var _salvage_point: Variant = null
var _salvage_guard: Node3D = null

## Куда ведёт компас на первой стадии. Цель — координаты, а не предмет, поэтому мимо QuestProps.
func salvage_point() -> Variant:
	return _salvage_point

func _salvage_1(q: Dictionary) -> void:
	var p: Node3D = _player()
	if p == null:
		return
	if _salvage_point == null:
		var ang: float = randf() * TAU
		var dist: float = _quest_dist()
		var wp: Vector3 = p.global_position + Vector3(cos(ang) * dist, 0.0, sin(ang) * dist)
		wp.y = G.ground_y(wp, p.global_position.y)
		_salvage_point = wp
		return
	_salvage_spawn_guard()
	Q.report(String(q["event"]), 1)

var _salvage_killed: bool = false

## Охрана груза. Отдельной функцией, потому что зовут её ДВА раза: при первом приезде и
## тогда, когда охраны не стало не от выстрелов (перезаход, вылет — врагов мы не сохраняем).
func _salvage_spawn_guard() -> void:
	if is_instance_valid(_salvage_guard) or not (_salvage_point is Vector3):
		return
	var sp: Node = get_node_or_null("/root/Main/EnemySpawner")
	if sp == null or not sp.has_method("spawn_at"):
		return
	_salvage_guard = sp.spawn_at(_salvage_point as Vector3 + Vector3(12.0, 0.0, 0.0), 7, 1)
	if _salvage_guard == null:
		return
	# КОЛЛЕКТОР ВЕЗЁТ САМ ОХРАННИК, а не лежит рядом с ним. Груз, валяющийся у ног побеждённого,
	# читается как «награда за галочку»; блок, снятый с машины, которую пришлось разобрать, —
	# как трофей. Ставим на кабину, чтобы его было видно ещё на подъезде (см. _carrier_spawn:
	# правило одно и то же, разница только в том, что охранника ставит своя функция).
	var gb: Node = _salvage_guard.get_node_or_null("blocks")
	if gb != null and gb.has_method("set_block"):
		gb.set_block(5, 6, 5, G.Block.COLLECTOR, 0.0)
	if _salvage_guard.has_method("assign_target"):
		_salvage_guard.assign_target(_player(), true)
	# Смерть ЗАПОМИНАЕМ. Пустая ссылка сама по себе не означает победу: после загрузки она
	# пуста всегда, и без этого флага квест проходился бы выходом в меню.
	if _salvage_guard.has_signal("died"):
		_salvage_guard.died.connect(func(_e = null): _salvage_killed = true, CONNECT_ONE_SHOT)

func _salvage_2(q: Dictionary) -> void:
	if is_instance_valid(_salvage_guard):
		return
	if not _salvage_killed:
		_salvage_spawn_guard()      # охрана пропала не от выстрелов — присылаем снова
		return
	# Охрана кончилась — коллектор наш. Он ЕХАЛ НА НЕЙ, поэтому обычно уже лежит там же,
	# сорванный с корпуса: claim_or_drop усыновляет такой, а кладёт новый, только если блок
	# сгорел в бою. Молча в инвентарь не отдаём — трофей игрок должен увидеть и подобрать.
	if not _player_owns(G.Block.COLLECTOR):
		_props.claim_or_drop("arc_salvage", G.Block.COLLECTOR, _salvage_point as Vector3)
		return                              # даём кадр, чтобы предмет появился
	Q.report(String(q["event"]), 1)
	_salvage_point = null

# ── «Production Line»: собрать цепочку и включить её ─────────────────────────
## ПЛОЩАДКА, А НЕ СПИСОК ПОКУПОК. Раньше стадия просто ждала, пока нужные блоки окажутся на
## машине игрока, — то есть требовала купить их и ничему не учила. Теперь квест САМ кладёт
## в мир всё, что нужно: заякоренного продавца с одной лентой (готовый «выход» линии) и
## рядом на земле — приёмник и остальные ленты. Собрать из этого работающую цепочку и есть
## задание, а проверяется оно по РЕАЛЬНОЙ связи блоков, а не по их наличию.
##
## КОЛЛЕКТОРА в наборе нет намеренно. В цепочку он не входит: по ленте не передаёт ничего
## (это VehicleBlock, без выходов и push_item), а руду с земли приёмник берёт и сам.
const LINE_DIST := 70.0        # как далеко от игрока появляется площадка
const LINE_REACH := 50.0       # ближе этого — материализуем; дальше игрок её и не видит
## Сколько лент КЛАСТЬ НА ЗЕМЛЮ — считается ПО СХЕМЕ, а не задаётся числом. Было отдельной
## константой (LINE_BELTS = 5, минус одна на продавце = четыре), а в схеме лент четыре, одна из
## которых уже стоит: игроку выдавали ЛИШНЮЮ, и она оставалась валяться у площадки как деталь,
## которой некуда встать. Два числа про одно и то же однажды разъезжаются — это и был тот раз.
const LINE_ORE := 3            # сколько слитков падает на приёмник за раз
const LINE_GIFT_DELAY := 8.0   # через сколько секунд после сборки выдаём процессор
const LINE_ORE_KIND := "m1"    # средний материал: медный слиток

var _line_point: Variant = null
var _line_base: Node3D = null          # заякоренная база-продавец, которую положил квест
var _line_gift_t: float = -1.0         # обратный отсчёт до выдачи процессора (−1 — не идёт)
var _line_gifted: bool = false

## СХЕМА ЛИНИИ в клетках базы (сетка 11³, центр 5). Лента идёт от продавца ПРЯМО, одной
## полосой по +Z, а приёмник стоит в её конце — так линия читается с одного взгляда и учит
## главному: материал едет ОТ приёмника К продавцу.
##
## Ни одного поворота здесь нет намеренно. У ленты вход сзади (+Z), выход спереди (−Z) —
## значит, выложенная по оси Z полоса гонит груз к продавцу сама, и объяснять игроку, каким
## боком ставить блок, на первой же фабрике не нужно.
##
## Клетка (5,5,6) в списке есть, но её ставит сам квест: подсказка на неё не появится, зато
## схема остаётся ЦЕЛОЙ — по ней же проверяется, что линия сложена так, как задумано.
const LINE_PLAN := [
	{"cell": Vector3i(5, 5, 6),  "block": G.Block.BELT},
	{"cell": Vector3i(5, 5, 7),  "block": G.Block.BELT},
	{"cell": Vector3i(5, 5, 8),  "block": G.Block.BELT},
	{"cell": Vector3i(5, 5, 9),  "block": G.Block.BELT},
	{"cell": Vector3i(5, 5, 10), "block": G.Block.RECEIVER},
]
## Куда встаёт процессор: СБОКУ ОТ ЛИНИИ, а не в её разрыв. Якорь (4,5,8), футпринт 2×2×2
## занимает x∈{3,4}, z∈{7,8} — все четыре клетки СЛЕВА от ленты, сама линия остаётся целой.
##
## Так это и работает в TerraTech: конвейер идёт своей полосой, станок стоит возле него и
## снимает груз с неё. Раньше процессор занимал две клетки самой линии, то есть вставал ВМЕСТО
## ленты, и собранная линия рвалась ровно там, где игрок ставил станок.
##
## Обмен идёт правым бортом процессора (+X), и обе клетки борта уже настроены в сцене:
## ближняя к приёмнику (4,5,8) — ВХОД (маска input_faces), дальняя (4,5,7) — ВЫХОД
## (port_defaults). Значит груз сходит с ленты в станок и возвращается на ленту НА КЛЕТКУ
## БЛИЖЕ к продавцу, то есть поток никуда не разворачивается.
const LINE_PROC_PLAN := [
	{"cell": Vector3i(4, 5, 8), "block": G.Block.PROCESSOR},
]

var _hints: Array = []

## Сколько лент выкладывать на землю: СЧИТАЕМ ПО ФАКТУ — клетки схемы, в которых ленты ещё нет.
##
## Было две константы про одно и то же (лент в схеме и «сколько уже стоит»), и они разъезжались
## ровно так, как и положено двум числам об одном: игрок получал не столько лент, сколько просит
## чертёж. Теперь вопрос задаётся самой базе, и ответ не может разойтись с тем, что на ней стоит.
func _belts_to_drop() -> int:
	var need: int = 0
	for e in LINE_PLAN:
		if int(e["block"]) != G.Block.BELT:
			continue
		if _base_block(_line_base, e["cell"]) != G.Block.BELT:
			need += 1
	return need

## Куда ведёт компас, пока площадка не появилась.
func line_point() -> Variant:
	return _line_point

## Разметка: белый призрак блока в каждой клетке схемы (build_hint.gd). Показывает форму,
## клетку и поворот — то, чего текст задания сказать не может.
func _show_plan(plan: Array) -> void:
	if _line_base == null or not is_instance_valid(_line_base):
		_clear_plan()
		return
	_show_plan_on(_line_base.get("block_map_node"), plan)

## То же самое, но на ЛЮБОЙ машине. Разметка сначала умела только площадку фабрики, потому что
## только там квест сам расставлял блоки. А объяснить «опора сзади, панель НА опоре» текстом
## нельзя вовсе: игрок читает «прикрепите панель», вешает её на борт, и она не работает —
## панель даёт ток только на якоре, а якорь держится на опоре. Призрак говорит это молча.
func _show_plan_on(bm, plan: Array) -> void:
	if bm == null or not is_instance_valid(bm):
		_clear_plan()
		return
	# Пересобираем только когда РАЗМЕТКА ДРУГАЯ. Условия квестов опрашиваются раз в секунду, а
	# _clear_plan убивает узлы: без этой проверки призраки пересоздавались бы каждый опрос и
	# заметно мигали, да и палец наставника сбрасывался бы вместе с ними.
	var sig := "%s|%s" % [bm.get_instance_id(), plan]
	if sig == _plan_sig:
		return
	_plan_sig = sig
	_clear_plan()
	for e in plan:
		var cell: Vector3i = e["cell"]
		# Клетка уже занята нужным блоком (её поставил квест) — разметка ей не нужна.
		if bm.has_method("get_block") and int(bm.get_block(cell.x, cell.y, cell.z)) == int(e["block"]):
			continue
		var h := BuildHint.create(bm, cell, int(e["block"]))
		if h != null:
			_hints.append(h)

var _plan_sig: String = ""

func _clear_plan() -> void:
	_drop_hints()
	_point_finger("")

## Убрать только ПРИЗРАКОВ, не трогая палец: пока предмет лежит в мире, чертёж не нужен, а палец
## нужен — он показывает на сам предмет.
func _drop_hints() -> void:
	for h in _hints:
		if is_instance_valid(h):
			(h as Node).queue_free()
	_hints.clear()
	_plan_sig = ""

## Палец наставника на БЛИЖАЙШУЮ незакрытую клетку схемы. Тот же палец, что в обучении:
## второй такой указатель заводить незачем, а привычка у игрока уже есть.
##
## Пустой текст — убрать. Ничего не блокируем (Gate.OFF) и не предлагаем пропустить
## обучение: это сюжетное задание, а не вводная.
var _finger_text: String = ""

## `prop_quest` — палец наводится на ПРЕДМЕТ этого квеста, пока тот лежит в мире, и только потом
## на ближайшую клетку чертежа.
func _point_finger(text: String, prop_quest: String = "") -> void:
	var guide: Node = get_tree().get_first_node_in_group("tutorial_guide")
	if guide == null:
		return
	_finger_prop = prop_quest
	if text == "" or (_finger_point_prop() == null and _next_hint() == null):
		if _finger_text != "" and guide.has_method("is_active") and guide.is_active():
			guide.clear()
		_finger_text = ""
		return
	if not guide.has_method("point_at_world"):
		return
	# Взводим ОДИН РАЗ на текст: сам палец каждый кадр спрашивает у нас точку заново
	# (_finger_point), поэтому переставлять его на каждом опросе незачем — он от этого мигал бы.
	var key := text + "|" + prop_quest
	if _finger_text == key and guide.has_method("is_active") and guide.is_active():
		return
	_finger_text = key
	guide.point_at_world(_finger_point, text, false, TutorialGuide.Gate.OFF, false)

## Куда смотрит палец ПРЯМО СЕЙЧАС. Именованный метод, а не лямбда в списке аргументов: лямбда,
## перенесённая на вторую строку, становится лишним аргументом вызова, и это валидный синтаксис
## (см. CLAUDE.md).
var _finger_prop: String = ""

func _finger_point() -> Vector3:
	var at = _finger_point_prop()
	if at != null:
		return at as Vector3
	var h = _next_hint()
	return (h as Node3D).global_position if h != null else Vector3.ZERO

func _finger_point_prop() -> Variant:
	return _props.position_for(_finger_prop) if _finger_prop != "" else null

## Ближайшая к игроку живая подсказка (или null, если разметка закрыта целиком).
func _next_hint():
	_hints = _hints.filter(func(h): return is_instance_valid(h))
	var p: Node3D = _player()
	var best = null
	var best_d: float = INF
	for h in _hints:
		if p == null:
			return h
		var d: float = p.global_position.distance_squared_to((h as Node3D).global_position)
		if d < best_d:
			best_d = d
			best = h
	return best

func _line_1(q: Dictionary) -> void:
	var p: Node3D = _player()
	if p == null:
		return
	_line_adopt()
	if _line_point == null:
		var ang: float = randf() * TAU
		var wp: Vector3 = p.global_position + Vector3(cos(ang) * LINE_DIST, 0.0, sin(ang) * LINE_DIST)
		wp.y = G.ground_y(wp, p.global_position.y)
		_line_point = wp
		return
	# Материализуем ТОЛЬКО когда игрок рядом. База — это машина со своей физикой и фабрикой;
	# ставить её за горизонт значит держать всё это работающим там, куда игрок ещё не доехал.
	if p.global_position.distance_squared_to(_line_point as Vector3) > LINE_REACH * LINE_REACH:
		return
	if not _dropped.has("line_kit"):
		_dropped["line_kit"] = true
		_spawn_line_kit(_line_point as Vector3)
		return                          # даём кадр, чтобы база собралась
	# Готово, когда цепочка РЕАЛЬНО собрана: от приёмника есть путь до продавца.
	var recv: Node = _find_in_base(G.Block.RECEIVER)
	if recv == null or not _chain_reaches(recv, G.Block.SELLER):
		_point_finger("Belt by belt along the line — receiver goes at the far end.")
		return
	_clear_plan()
	_drop_ore_over(recv, LINE_ORE)      # линия жива — вот ей и работа
	_line_gift_t = LINE_GIFT_DELAY
	Q.report(String(q["event"]), 1)

func _line_2(q: Dictionary) -> void:
	_line_adopt()
	# Процессор выдаём НЕ сразу: игрок должен увидеть, как первая партия проехала по ленте и
	# продалась. Подарок посреди этого зрелища его бы и перебил.
	if not _line_gifted:
		if _line_gift_t < 0.0:
			_line_gift_t = LINE_GIFT_DELAY
		_line_gift_t -= POLL
		if _line_gift_t > 0.0:
			return
		_line_gifted = true
		_award(G.Block.PROCESSOR)
		_show_plan(LINE_PROC_PLAN)
		Dialogue.say("System", "Processor delivered. It stands BESIDE the line, left of the middle belt — the belts stay where they are. It takes ore off the belt and puts the ingot back on it.")
		return
	var recv: Node = _find_in_base(G.Block.RECEIVER)
	if recv == null or not _chain_reaches(recv, G.Block.PROCESSOR):
		_point_finger("Processor goes here — beside the line, not into it.")
		return                          # процессор ещё не врезан в линию
	_clear_plan()
	_drop_ore_over(recv, LINE_ORE)      # и снова руда — проверить, что линия не развалилась
	Q.report(String(q["event"]), 1)

## ПЛОЩАДКА, УЖЕ СТОЯЩАЯ В МИРЕ. После перезахода сейв возвращает базу раньше, чем квест
## успевает опомниться: его собственные пометки живут только в памяти, и без этой строки каждый
## вход в мир ставил бы рядом со старой площадкой вторую, в новом случайном месте.
func _line_adopt() -> void:
	if is_instance_valid(_line_base):
		return
	_line_base = _adopt_quest_base("arc_line")
	if not is_instance_valid(_line_base):
		return
	_line_point = _line_base.global_position
	_dropped["line_kit"] = true

## Площадка целиком: заякоренный продавец с лентой + набор на земле рядом.
func _spawn_line_kit(at: Vector3) -> void:
	_flatten_line_site(at)
	_line_base = _spawn_station(at, [
		{"x": 5, "y": 5, "z": 5, "block": G.Block.SELLER, "rot": [0.0, 0.0, 0.0]},
		{"x": 5, "y": 5, "z": 6, "block": G.Block.BELT, "rot": [0.0, 0.0, 0.0]},
	])
	if is_instance_valid(_line_base):
		_line_base.set_meta(QuestProps.META, "arc_line")   # по ней база узнаётся после перезахода
	_props.ensure("arc_line", G.Block.RECEIVER, at)
	for _i in _belts_to_drop():
		_props.drop_near("arc_line", G.Block.BELT, at)
	_show_plan(LINE_PLAN)
	Dialogue.say("System", "Seller is anchored and live, one belt already on it. The rest of the line is on the ground — the white outlines show where each piece goes.")

## РОВНАЯ ПЛОЩАДКА под линию. Постройка ВСТРАИВАЕТСЯ в мир, а не ставится на него: линия
## длинная — шесть клеток по оси конвейера и две вбок под процессор, — и на склоне её просто
## не собрать: с одного конца блоки уходят в землю, с другого висят в воздухе.
##
## Площадка ПРЯМОУГОЛЬНАЯ и вытянута ПО НАПРАВЛЕНИЮ КОНВЕЙЕРА (+Z базы, она ставится без
## поворота). Круглая по той же длине срыла бы втрое больше земли ради коридора в две клетки.
const LINE_SITE_HALF := Vector2(3.0, 5.0)     # полуразмер площадки: X — ширина, Z — вдоль линии
const LINE_SITE_AHEAD := 2.0                  # центр смещён вперёд по линии, а не по продавцу
const LINE_SITE_FEATHER := 5.0                # на сколько метров площадка сходит на нет за краем

func _flatten_line_site(at: Vector3) -> void:
	_flatten_site(at + Vector3(0.0, 0.0, LINE_SITE_AHEAD), LINE_SITE_HALF, LINE_SITE_FEATHER)

## РОВНОЕ МЕСТО ПОД ПОСТРОЙКУ КВЕСТА — одной дверью. Каждая площадка своего размера, а вот
## «спросить карту и не упасть, если её нет» у всех одинаково.
func _flatten_site(at: Vector3, half: Vector2, feather: float) -> void:
	var map: Node = get_node_or_null("/root/Main/map")
	if map == null or not map.has_method("flatten_area"):
		return
	map.flatten_area(at, half, at.y, feather)

## Стационарная постройка ОТ КВЕСТА. Делает ровно то же, что постановка ядра игроком
## (vehicle_body_3d._place_ground_structure), но без руки и превью: машина из сцены, раскладка,
## флаг станции и якорь. Держать это в двух местах нельзя — база, собранная «почти так же»,
## разваливается сторожем кабины при первой же загрузке.
func _spawn_station(at: Vector3, layout: Array) -> Node3D:
	var scene: PackedScene = load("res://player_vehicle.tscn")
	var vr: Node = get_node_or_null("/root/Main/Vehicles")
	if scene == null or vr == null:
		return null
	var v: Node3D = scene.instantiate()
	vr.add_child(v)
	if v is RigidBody3D:
		(v as RigidBody3D).freeze = true       # морозим ДО позиции: телепорт живого тела физика откатит
		(v as RigidBody3D).linear_velocity = Vector3.ZERO
	# ВЫСОТА: нижний ряд блоков должен ЛЕЖАТЬ НА ЗЕМЛЕ. Клетка — метр, блок нижнего ряда
	# стоит в самом начале координат машины, значит его низ на полметра ниже — отсюда и
	# половина. Со старыми 1.2 база висела над землёй, и вместе с ней висела в воздухе вся
	# линия конвейера: у неё под собой ничего нет, она держится соседями.
	# СТАВИМ В ТОЧКУ ЦЕНТР ЯДРА, А НЕ НАЧАЛО КООРДИНАТ. У блока 2×2×2 (продавец) якорная клетка
	# УГЛОВАЯ: футпринт растёт от неё в минус по X и Z, поэтому машина, поставленная в `at`
	# началом координат, оказывается смещённой на пол-клетки — постройка стоит не в середине
	# выровненной площадки, а её угол. То же самое делает ручная постановка базы
	# (vehicle_body_3d._place_ground_structure), и правило обязано быть одним.
	v.global_position = at + Vector3.UP * 0.5 - _core_xz_offset(layout)
	if v.has_method("apply_build"):
		v.apply_build(layout)
	if "is_station" in v:
		v.is_station = true
		if v.get("block_map_node") != null and "is_station" in v.block_map_node:
			v.block_map_node.is_station = true
	if v.has_method("_anchor_station"):
		v.call_deferred("_anchor_station")
	var cc: Node = get_tree().get_first_node_in_group("camera_controller")
	if cc != null and "vehicles" in cc and not cc.vehicles.has(v):
		cc.vehicles.append(v)                  # чтобы на неё можно было переключиться
	return v

## Сдвиг центра ЯДРА относительно начала координат машины, по XZ. Ядром считаем блок в центре
## сетки (5,5,5) — туда его кладут все раскладки баз. Смещение спрашиваем у самой сцены блока
## (VehicleBlock.cells_center): второй таблицы размеров рядом с blocks._block_footprint быть
## не должно.
func _core_xz_offset(layout: Array) -> Vector3:
	for e in layout:
		if int(e.get("x", -1)) != 5 or int(e.get("y", -1)) != 5 or int(e.get("z", -1)) != 5:
			continue
		var scene: PackedScene = G.get_scene(int(e.get("block", 0)))
		if scene == null:
			return Vector3.ZERO
		var inst: Node = scene.instantiate()
		var c = inst.get("cells_center")
		inst.free()                            # орфан: в дерево не попадал, _ready не отработал
		if c is Vector3:
			return Vector3((c as Vector3).x, 0.0, (c as Vector3).z)
		return Vector3.ZERO
	return Vector3.ZERO

## Блок нужного типа на базе, которую положил квест.
func _find_in_base(bt: int) -> Node:
	if _line_base == null or not is_instance_valid(_line_base):
		return null
	var bm = _line_base.get("block_map_node")
	if bm == null or not is_instance_valid(bm):
		return null
	for b in bm.get_children():
		if ("block" in b) and int(b.get("block")) == bt:
			return b
	return null

## Есть ли ПУТЬ ПО ЛЕНТЕ от блока до блока такого типа. Проверяем связи (next_blocks), а не
## наличие блоков: «поставил рядом» и «подключил» — разные вещи, и учит квест второму.
func _chain_reaches(from: Node, target_bt: int) -> bool:
	var seen: Dictionary = {}
	var stack: Array = [from]
	while not stack.is_empty():
		var n = stack.pop_back()
		if n == null or not is_instance_valid(n) or seen.has(n):
			continue
		seen[n] = true
		if ("block" in n) and int(n.get("block")) == target_bt and n != from:
			return true
		if "next_blocks" in n:
			for x in n.next_blocks:
				stack.append(x)
	return false

## Уронить слитки ПРЯМО НАД приёмником — он их и подберёт. Показать линию в работе проще,
## чем объяснить: игрок видит, как материал уезжает по ленте и превращается в деньги.
func _drop_ore_over(recv: Node, count: int) -> void:
	if recv == null or not (recv is Node3D):
		return
	for i in count:
		_props.drop_resource(LINE_ORE_KIND,
				(recv as Node3D).global_position + Vector3(0.0, 2.0 + float(i) * 0.8, 0.0))

# ── «Hold the Line»: налёт на СВОЮ базу ──────────────────────────────────────
# В оригинале это турели у чужой станции. Станций у нас нет, поэтому защищаем то, что игрок
# построил сам, — и защищать приходится СТОЯ: заякоренная машина уехать не может.
const HOLD_COUNT := 2
const HOLD_RANGE := 70.0

var _hold: Array = []

## Кого приезжают бить. Сначала БАЗА (стационарная постройка): налёт идёт за производством,
## а производство стоит на ней, и она по определению на якоре. Базы нет — заякоренная
## машина, нет и её — та, которой игрок управляет.
##
## Ждать якоря, как раньше, было незачем: стадия требовала от игрока встать, хотя нападают
## именно на то, что и так стоит. Игрок в этот момент занят конвейером, а квест повторял ему
## пройденное и до тех пор не начинался вовсе.
func _hold_target() -> Node3D:
	var vr: Node = get_node_or_null("/root/Main/Vehicles")
	var anchored_one: Node3D = null
	if vr != null:
		for c in vr.get_children():
			if not (c is Node3D) or c.get("faction") == null or int(c.get("faction")) != 0:
				continue
			if c.get("is_station") == true:
				return c as Node3D
			if anchored_one == null and c.get("anchored") == true:
				anchored_one = c as Node3D
	return anchored_one if anchored_one != null else _player()

func _hold_1(q: Dictionary) -> void:
	var p: Node3D = _hold_target()
	var sp: Node = get_node_or_null("/root/Main/EnemySpawner")
	if p == null or sp == null or not sp.has_method("spawn_at"):
		return
	_hold.clear()
	for i in HOLD_COUNT:
		var ang: float = TAU * float(i) / float(HOLD_COUNT) + randf()
		var wp: Vector3 = p.global_position + Vector3(cos(ang) * HOLD_RANGE, 0.0, sin(ang) * HOLD_RANGE)
		wp.y = G.ground_y(wp, p.global_position.y)
		var e = sp.spawn_at(wp, 8, 1)
		if e != null:
			if e.has_method("assign_target"):
				e.assign_target(p, true)    # идут именно за базой и цель не бросают
			_hold.append(e)
	if _hold.is_empty():
		return
	Q.report(String(q["event"]), 1)

func _hold_2(q: Dictionary) -> void:
	for e in _hold:
		if is_instance_valid(e):
			return
	Q.report(String(q["event"]), 1)
	_hold.clear()

# ── ВЫШКА ПОД ЩИТОМ: Charlie Watchtower и SAM Site Ridge ────────────────────
# ОДНА реализация на два квеста, и это не экономия строк: они и по замыслу одно и то же —
# цель под куполом, купол держат зарядные башни вокруг. Разными их делают ровно три числа
# (пресет вышки, сколько башен, тексты), и держать под это две копии значило бы однажды
# починить одну и забыть вторую.
#
# ГЛАВНОЕ: связка «башни держат щит» СОБИРАЕТСЯ САМА, обычными правилами игры. У вышки нет
# панелей (blocks._layout_shielded_tower), значит своей выработки ноль; зарядные башни рядом
# льют в неё энергию блоком WIRELESS_CHARGER. Квест не знает про щит вообще ничего — он
# ставит машины и ждёт, пока вышка умрёт. Убил башни → у вышки кончается запас → купол гаснет
# сам, и её можно ломать. Игроку это видно по лучам зарядки, а не по строчке в журнале.
## Радиус кольца зарядных башен. Считается, а не подбирается на глаз: башня обязана
## ДОТЯГИВАТЬСЯ до аккумулятора вышки (wireless_charger.RANGE = 6 м) и при этом стоять СНАРУЖИ
## купола (shield.SHIELD_RADIUS = 4 м) — иначе её саму не расстрелять, а в этом вся задача.
## На 5.5 м зарядник тянется 4.9 м до ближнего аккумулятора и стоит в полутора метрах от купола.
const TOWER_RING := 5.5
## Пресет вышки, сколько зарядных башен, и что говорит Система, когда игрок доехал.
const TOWER_WATCH := {"key": "tower", "preset": 16, "guards": 3, "award": G.Block.SHIELD,
		"say": "That dome is not the tower's own. Something else is paying for it."}
const TOWER_SAM := {"key": "sam", "preset": 17, "guards": 4, "award": G.Block.ROCKET,
		"say": "Same trick, dug in harder. The batteries will not wait for you to think."}

var _tower_point: Dictionary = {}      # ключ → Vector3, куда ехать
var _tower_node: Dictionary = {}       # ключ → сама вышка
var _tower_dead: Dictionary = {}       # ключ → true, если вышку уже добили

func _tower_1(q: Dictionary, cfg: Dictionary) -> void:
	var key: String = String(cfg["key"])
	var p: Node3D = _player()
	if p == null:
		return
	if not _tower_point.has(key):
		var ang: float = randf() * TAU
		var dist: float = _quest_dist()
		var wp: Vector3 = p.global_position + Vector3(cos(ang) * dist, 0.0, sin(ang) * dist)
		wp.y = G.ground_y(wp, p.global_position.y)
		_tower_point[key] = wp
	var at: Vector3 = _tower_point[key]
	if not _tower_node.has(key):
		if not _tower_build(key, cfg, at):
			return
		Dialogue.say("System", String(cfg["say"]))
	Q.report(String(q["event"]), 1)

func _tower_2(q: Dictionary, cfg: Dictionary) -> void:
	var key: String = String(cfg["key"])
	# СОСТОЯНИЕ МОГЛО ПОТЕРЯТЬСЯ (перезаход: квестовые машины в сейв не идут). Пустая ссылка
	# сама по себе не победа — то же правило, что у событий: ставим постройку заново.
	if not _tower_node.has(key):
		if _tower_point.has(key):
			var p: Node3D = _player()
			var at: Vector3 = _tower_point[key]
			if p != null:
				_tower_build(key, cfg, at)
		return
	if not bool(_tower_dead.get(key, false)):
		return
	# Вышка мертва. Зарядные башни, если ещё стоят, остаются в мире обычными базами: добивать
	# их ради галочки незачем, а бросать посреди боя — тем более.
	_award(int(cfg["award"]))
	Dialogue.say("System", "Ridge is clear. The hardware it was guarding is yours.")
	Q.report(String(q["event"]), 1)
	_tower_node.erase(key)
	_tower_dead.erase(key)

## Собрать точку: вышка в центре, зарядные башни кольцом вокруг неё.
##
## Радиус кольца — НЕ ВКУС: у зарядника дальность 6 м (wireless_charger.RANGE), и башня должна
## дотягиваться до аккумулятора вышки, но стоять СНАРУЖИ купола (радиус 4 м), иначе её не
## расстрелять — а в этом вся задача.
func _tower_build(key: String, cfg: Dictionary, at: Vector3) -> bool:
	var sp: Node = get_node_or_null("/root/Main/EnemySpawner")
	if sp == null or not sp.has_method("spawn_at"):
		return false
	var tower = sp.spawn_at(at, int(cfg["preset"]), 1, true)
	if tower == null:
		return false
	if tower.has_signal("died"):
		tower.died.connect(_on_tower_died.bind(key))
	_tower_node[key] = tower
	# Зарядные башни ссылками НЕ ДЕРЖИМ намеренно: квест про них ничего не спрашивает. Живы они
	# или нет, видно по самому щиту — а список, который никто не читает, однажды разойдётся с
	# миром (башню убрали, ссылка осталась) и начнёт врать.
	var n: int = int(cfg["guards"])
	for i in n:
		var ang: float = TAU * float(i) / float(n)
		var wp: Vector3 = at + Vector3(cos(ang) * TOWER_RING, 0.0, sin(ang) * TOWER_RING)
		wp.y = G.ground_y(wp, at.y)
		sp.spawn_at(wp, 18, 1, true)
	return true

func _on_tower_died(_who, key: String) -> void:
	_tower_dead[key] = true

# ── СОБЫТИЕ «Crossfire»: чужая стычка, в которую можно вмешаться ─────────────
# Часть 1 — доехать до точки. Часть 2 — победить.
#
# Точка ставится не рядом и не за горизонтом: ровно настолько далеко, чтобы это была
# ПОЕЗДКА, а не поворот головы, и чтобы по дороге игрок успел решить, ввязываться ли.
## На каком подлёте стычка начинается. Двести метров ехать в пустоту скучно; на пятидесяти
## бой уже слышно и видно, и игрок приезжает НА идущую драку, а не на пустое поле, где
## машины возникнут у него на глазах.
## Насколько дуэлянты стоят друг от друга.
const DUEL_GAP := 18.0
## Сколько ждать перед тем, как событие может случиться снова, — общее для всех событий
## (см. _event_cooldown в разделе «ПОВТОРЯЕМЫЕ СОБЫТИЯ»).

var _duel_point: Variant = null      # куда ехать (Vector3) или null — точки ещё нет
var _duel_a: Node3D = null
var _duel_b: Node3D = null
var _duel_cool: float = 0.0

## Куда ведёт компас по этому событию. Публично — компас спрашивает отсюда, потому что цель
## тут не предмет в мире (QuestProps), а просто координаты.
func duel_point() -> Variant:
	return _duel_point

func _duel_1(q: Dictionary) -> void:
	var p: Node3D = _player()
	if p == null:
		return
	if _duel_point == null:
		# Направление случайное, дистанция фиксированная: событие должно уводить игрока с его
		# маршрута, а не подворачиваться там, куда он и так ехал.
		var ang: float = randf() * TAU
		var dist: float = _quest_dist()
		var wp: Vector3 = p.global_position + Vector3(cos(ang) * dist, 0.0, sin(ang) * dist)
		wp.y = G.ground_y(wp, p.global_position.y)
		_duel_point = wp
		return
	# Фракции РАЗНЫЕ (1 и 2), иначе они друг друга не увидят:
	# enemy_vehicle._is_enemy сравнивает именно фракцию. Игрок (0) для обоих тоже чужой.
	if not _spawn_duel(_duel_point as Vector3):
		return
	Q.report(String(q["event"]), 1)

func _spawn_duel(center: Vector3) -> bool:
	var sp: Node = get_node_or_null("/root/Main/EnemySpawner")
	if sp == null or not sp.has_method("spawn_at"):
		return false
	var side: Vector3 = Vector3(DUEL_GAP * 0.5, 0.0, 0.0)
	_duel_a = sp.spawn_at(center - side, 7, 1)     # рейдер
	_duel_b = sp.spawn_at(center + side, 8, 2)     # копейщик другой фракции
	if _duel_a == null or _duel_b == null:
		return false
	# Цели назначаем сразу и накрепко: пока игрок доедет, они уже должны драться, а не
	# искать друг друга по своим зонам обнаружения.
	if _duel_a.has_method("assign_target"):
		_duel_a.assign_target(_duel_b, true)
	if _duel_b.has_method("assign_target"):
		_duel_b.assign_target(_duel_a, true)
	return true

func _duel_2(q: Dictionary) -> void:
	# Победа = поля боя больше нет. Если они добьют друг друга сами — тоже победа: игрок
	# приехал и дождался, это его решение, а не поблажка.
	if is_instance_valid(_duel_a) or is_instance_valid(_duel_b):
		return
	Q.report(String(q["event"]), 1)
	_duel_cool = _event_cooldown()   # дуэль — такое же событие, пауза общая
	_duel_point = null

## Перезарядка события: отлежалось — открываем заново. Без этого «событие» случилось бы
## ровно один раз за всю игру и навсегда осталось выполненным.
func _duel_cooldown(delta: float) -> void:
	if _duel_cool <= 0.0:
		return
	_duel_cool -= delta
	if _duel_cool <= 0.0:
		Q.reset_quest("event_duel")

# ── Помощники ────────────────────────────────────────────────────────────────
func _player() -> Node3D:
	var cc: Node = get_tree().get_first_node_in_group("camera_controller")
	if cc != null and "current_vehicle" in cc and cc.current_vehicle != null:
		return cc.current_vehicle as Node3D
	return null

func _has_block(bt: int) -> bool:
	return _count_block(bt) > 0

## Есть ли блок У ИГРОКА где угодно: на ЛЮБОЙ его машине, в инвентаре или в руке. Пока есть —
## выдавать его заново не надо, иначе «предмет потерялся» и «игрок его уже подобрал» становятся
## для квеста одним и тем же, и мир зарастает копиями награды.
##
## Машины перебираются ВСЕ, а не только та, которой сейчас рулят. Стационарный блок (опора,
## продавец) при постановке на землю РОЖДАЕТ СВОЮ БАЗУ — то есть уезжает на другую машину, —
## и по одной текущей машине выходило, что игрок его потерял: квест клал новую опору каждую
## секунду, и поле вокруг зарастало ими. Ровно на это и жаловались.
func _player_owns(bt: int) -> bool:
	if G.block_inventory.has(bt):
		return true
	var cc: Node = get_tree().get_first_node_in_group("camera_controller")
	if cc != null and "vehicles" in cc:
		for v in cc.vehicles:
			if _machine_has(v, bt):
				return true
	elif _has_block(bt):
		return true
	var p: Node3D = _player()
	if p == null:
		return false
	var held = p.get("block_body")
	return held != null and is_instance_valid(held) and ("block" in held) \
			and int(held.get("block")) == bt

func _count_block(bt: int) -> int:
	return _machine_count(_player(), bt)

func _machine_has(m: Node, bt: int) -> bool:
	return _machine_count(m, bt) > 0

func _machine_count(m: Node, bt: int) -> int:
	if m == null or not is_instance_valid(m):
		return 0
	var blocks: Node = m.get_node_or_null("blocks")
	if blocks == null:
		return 0
	var n: int = 0
	for b in blocks.get_children():
		if b.get("block") != null and int(b.get("block")) == bt:
			n += 1
	return n

func _award(bt: int) -> void:
	var p: Node = _player()
	if p != null and p.has_method("award_blocks"):
		p.award_blocks(bt, 1)

# Вор — обычный враг, которому ДОБАВЛЕН радар: отбирается он тем же способом, что любой
# другой блок, — сбил остальное, подобрал. Отдельной «сцены вора» заводить незачем.
func _spawn_thief() -> Node3D:
	var sp: Node = get_node_or_null("/root/Main/EnemySpawner")
	if sp == null or not sp.has_method("spawn_scout_near_player"):
		return null
	var e = sp.spawn_scout_near_player()
	if e == null or not (e is Node3D):
		return null
	var blocks: Node = (e as Node3D).get_node_or_null("blocks")
	if blocks != null and blocks.has_method("set_block"):
		blocks.set_block(5, 6, 5, G.Block.RADAR, 0.0)
	return e as Node3D

# ══════════════════════════════════════════════════════════════════════════════
# ПОВТОРЯЕМЫЕ СОБЫТИЯ (в оригинале — задания с борда станции)
# ══════════════════════════════════════════════════════════════════════════════
# Борда у нас нет и не будет: задания объявляет Система напрямую. Всё остальное взято
# оттуда — типы («банда», «груз», «оборона союзника», «волны», «лагерь»), повторяемость по
# остыванию и правило «уехал далеко — задание снято».
#
# Общего у них ровно три вещи, и они вынесены сюда, чтобы каждое новое событие не тащило
# свою копию: ТОЧКА (куда ехать), СПИСОК УЧАСТНИКОВ (по нему считается победа) и ОТМЕНА
# ПО РАССТОЯНИЮ. Без последней брошенное событие висело бы в журнале навсегда, а его
# участники — в мире.
const EV_ABANDON := 500.0      # уехал дальше — событие снимается (как в оригинале)
## ОСТЫВАНИЕ — МИНУТА-ДВЕ, а не семь. Семь минут означало, что между событиями игрок едет по
## пустой карте: события — это и есть то, ЧТО с ним происходит, пока он не занят сюжетом.
## Разброс, а не одно число: одинаковая пауза читается как расписание.
##
## НО НЕ С ПЕРВОЙ МИНУТЫ. Пока мир слабый (G.threat_ramp), пауза растянута: события — это бой, а
## на первом грейде у игрока одна пушка и ни одного исследования, и «раз в минуту» для него не
## ритм, а осада. К четвёртому грейду множитель приходит к единице сам.
const EV_COOLDOWN_MIN := 60.0
const EV_COOLDOWN_MAX := 120.0
const EV_COOLDOWN_EARLY_MUL := 2.5

func _event_cooldown() -> float:
	return randf_range(EV_COOLDOWN_MIN, EV_COOLDOWN_MAX) \
			* G.threat_lerp(EV_COOLDOWN_EARLY_MUL, 1.0)


var _ev_point: Dictionary = {}   # id события → Vector3, куда ехать
var _ev_mobs: Dictionary = {}    # id события → Array участников
var _ev_cool: Dictionary = {}    # id события → сколько ещё остывать

## Куда ведёт компас по этому событию. ОДНА точка входа на все события с координатами:
## разбирать их по одному в компасе значило бы вспоминать про него при каждом новом.
func quest_point(ev: String) -> Variant:
	# ЖИВОЙ УЧАСТНИК ВАЖНЕЕ ТОЧКИ, и это не мелочь. Точка выбирается ОДИН РАЗ, при объявлении,
	# а враги ездят: к началу драки противник уже не там, а после гибели игрока (возрождение
	# уводит его в сторону) метка и вовсе вела в пустое поле — «квесты со спавном врагов без
	# метки». Пока участник жив, метка едет за НИМ, и только когда живых не осталось —
	# возвращаемся к точке.
	var live = _live_target(ev)
	if live != null:
		return live
	match ev:
		"quest_salvage_1": return _salvage_point
		"quest_duel_1":    return _duel_point
		"quest_line_1":    return _line_point
		# Пока панель (или реген) лежит у базы, компас ведёт к предмету — его отдаёт QuestProps,
		# и спрашивают его раньше нас. Предмет подобран — цель это САМА БАЗА: ставить его всё
		# равно туда, а без этой строки метка гасла ровно в тот момент, когда игрок взял блок.
		"quest_arc_power_1": return _power_point
		"quest_arc_power_2": return _power_point
		# Ветки с носителем и с жилой: точка едет за живым носителем (carrier_point сама
		# обновляет её), а после боя указывает туда, где упал блок.
		"quest_arc_radar_1":   return carrier_point("arc_radar")
		"quest_arc_battery_1": return battery_point()
		"quest_arc_battery_2": return battery_point()
	# Вышки под щитом держат свои точки в отдельном словаре, но ключ у них ТОТ ЖЕ, что у
	# событий ("quest_tower_1" → "tower"), поэтому перечислять их по одной здесь не нужно —
	# ровно то, от чего предостерегает комментарий у компаса.
	var key := _ev_key(ev)
	if _tower_point.has(key):
		return _tower_point[key]
	return _ev_point.get(key)

## Позиция ближайшего ЖИВОГО участника квеста или null. Участники лежат по своим полям (у
## каждой ветки они свои), поэтому здесь один список на все случаи: добавить новый квест со
## спавном — значит дописать сюда строку, иначе его метка снова будет вести в поле.
func _live_target(ev: String) -> Variant:
	var key := _ev_key(ev)
	var list: Array = []
	list.append_array(_ev_mobs.get(key, []))
	if _tower_node.has(key):
		list.append(_tower_node[key])
	match key:
		"hold":      list.append_array(_hold)
		"salvage":   list.append(_salvage_guard)
		"duel":      list.append_array([_duel_a, _duel_b])
		"arc_radar": list.append(_thief)          # «вор» с радаром — тоже цель квеста
	# Носитель сюжетного блока — такой же живой участник: пока он ездит, метка едет за ним.
	if _carrier.has(key):
		list.append(_carrier[key])
	var p: Node3D = _player()
	var best: Variant = null
	var best_d: float = INF
	for m in list:
		if m == null or not is_instance_valid(m) or not (m is Node3D):
			continue
		var pos: Vector3 = (m as Node3D).global_position
		var d: float = pos.distance_squared_to(p.global_position) if p != null else 0.0
		if d < best_d:
			best_d = d
			best = pos
	return best

## Ключ события по имени его стадии: "quest_gang_1" → "gang". Точка и участники общие для
## обеих стадий, поэтому и ключ должен быть общим.
func _ev_key(ev: String) -> String:
	var s := ev.trim_prefix("quest_")
	var cut := s.rfind("_")
	return s.substr(0, cut) if cut > 0 else s

## Точка события: выбираем один раз и держим. Возвращает null, пока игрока нет.
## dist <= 0 — общее правило спавна квестов (_quest_dist).
func _ev_get_point(key: String, dist: float = 0.0) -> Variant:
	if dist <= 0.0:
		dist = _quest_dist()
	if _ev_point.has(key):
		return _ev_point[key]
	var p: Node3D = _player()
	if p == null:
		return null
	var ang: float = randf() * TAU
	var wp: Vector3 = p.global_position + Vector3(cos(ang) * dist, 0.0, sin(ang) * dist)
	wp.y = G.ground_y(wp, p.global_position.y)
	_ev_point[key] = wp
	return wp

## УЕХАЛ ЗА EV_ABANDON — снимаем. Возвращает true, если событие снято: вызывающий сразу выходит.
##
## Меряем от ТОЧКИ СОБЫТИЯ, и участники для этого не нужны. Раньше проверка ждала, пока они
## появятся в мире (а появляются они, только когда игрок доедет), и объявленное событие, к
## которому игрок так и не поехал, висело в журнале вечно — занимая место, которое теперь
## делят всего два события.
func _ev_abandoned(q: Dictionary, key: String) -> bool:
	var p: Node3D = _player()
	if p == null or not _ev_point.has(key):
		return false
	if p.global_position.distance_squared_to(_ev_point[key] as Vector3) <= EV_ABANDON * EV_ABANDON:
		return false
	_ev_clear(key)
	# Остывание ставим и здесь: снятое событие обязано вернуться, иначе «уехал один раз» —
	# и этот тип задания больше не случается никогда.
	_ev_cool[String(q["id"])] = _event_cooldown()
	Q.skip_quest(String(q["id"]))
	return true

## Убрать за собой: участники, точка, метка. Уводим их из мира, а не бросаем — иначе поле
## постепенно зарастает машинами от заданий, которые игрок даже не начал.
func _ev_clear(key: String) -> void:
	for m in _ev_mobs.get(key, []):
		if is_instance_valid(m):
			(m as Node).queue_free()
	_ev_mobs.erase(key)
	_ev_point.erase(key)

## Все участники события уничтожены?
func _ev_all_dead(key: String) -> bool:
	# НЕТ ЗАПИСИ — не «все мертвы», а «мы про них ничего не знаем» (перезаход: события в сейв
	# не идут). Считать это победой значило бы закрывать задание выходом в меню.
	if not _ev_mobs.has(key):
		return false
	for m in _ev_mobs.get(key, []):
		if is_instance_valid(m):
			return false
	return true

## Событие завершено: остывает и через минуту-две открывается снова.
func _ev_done(q: Dictionary, key: String) -> void:
	Q.report(String(q["event"]), 1)
	_ev_cool[String(q["id"])] = _event_cooldown()
	_ev_mobs.erase(key)
	_ev_point.erase(key)

## Остывание всех событий разом (зовётся из _process рядом с дуэльным).
func _ev_cooldowns(delta: float) -> void:
	for id in _ev_cool.keys():
		_ev_cool[id] = float(_ev_cool[id]) - delta
		if _ev_cool[id] <= 0.0:
			_ev_cool.erase(id)
			Q.reset_quest(id)

## Спавн отряда вокруг точки. Пресеты — те же ступени опасности, что у обычных врагов.
func _ev_spawn(key: String, at: Vector3, presets: Array, faction_id: int = 1,
		lock_on: Node3D = null) -> Array:
	var sp: Node = get_node_or_null("/root/Main/EnemySpawner")
	if sp == null or not sp.has_method("spawn_at"):
		return []
	var out: Array = []
	for i in presets.size():
		var ang: float = TAU * float(i) / float(maxi(presets.size(), 1))
		var pos: Vector3 = at + Vector3(cos(ang) * 10.0, 0.0, sin(ang) * 10.0)
		# ВРАЖДЕБНЫХ участников события просим у спавнера ПО ПОТОЛКУ игрока: событие повторяется
		# и встречает игрока в любом состоянии, в том числе сразу после того, как его разобрали.
		# Союзники (faction 0) идут как заказано — слабый союзник помогает ровно никак.
		var want: int = int(presets[i])
		if faction_id != 0 and sp.has_method("preset_for_request"):
			want = int(sp.preset_for_request(want))
		var e = sp.spawn_at(pos, want, faction_id)
		if e == null:
			continue
		if lock_on != null and e.has_method("assign_target"):
			e.assign_target(lock_on, true)
		out.append(e)
	var have: Array = _ev_mobs.get(key, [])
	have.append_array(out)
	_ev_mobs[key] = have
	return out

# ── «Tech Gang»: банда стоит лагерем, её надо разогнать ──────────────────────

func _gang_1(q: Dictionary) -> void:
	var key := "gang"
	if _ev_abandoned(q, key):
		return
	if _ev_get_point(key) == null:
		return
	if not _ev_mobs.has(key):
		# Цель НЕ назначаем: банда стоит на месте, и первым ходом должен быть выстрел игрока.
		# Так у него остаётся выбор — подъехать, посмотреть и уехать.
		_ev_spawn(key, _ev_point[key] as Vector3, [5, 6, 7])
		Dialogue.say("System", "Three units, no transponders. They are not ours.")
	Q.report(String(q["event"]), 1)

func _gang_2(q: Dictionary) -> void:
	var key := "gang"
	if _ev_abandoned(q, key):
		return
	if not _ev_mobs.has(key):
		var at = _ev_get_point(key)      # состояние потеряно — банда снова на месте
		if at != null:
			_ev_spawn(key, at as Vector3, [5, 6, 7])
		return
	if not _ev_all_dead(key):
		return
	_ev_done(q, key)

# ── «Supply Drop»: ящик снабжения, иногда с засадой ─────────────────────────
## Что бывает в ящике. Список короткий и намеренно полезный: событие должно быть поводом
## съездить, а не лотереей с мусором.
const SUPPLY_LOOT := [G.Block.BATTERY, G.Block.SOLAR, G.Block.BELT, G.Block.ARMOR2, G.Block.REGEN]

func _supply_1(q: Dictionary) -> void:
	var key := "supply"
	if _ev_abandoned(q, key):
		return
	if _ev_get_point(key) == null:
		return
	if not _ev_mobs.has(key):
		_ev_mobs[key] = []                      # событие началось, даже если засады не будет
		var at: Vector3 = _ev_point[key] as Vector3
		_props.ensure("event_supply", int(SUPPLY_LOOT.pick_random()), at)
		# ЗАСАДА через раз. Всегда — и груз перестаёт быть грузом, превращаясь в бой;
		# никогда — и ехать за ним нечем рисковать.
		if randf() < 0.5:
			_ev_spawn(key, at, [6, 7], 1, _player())
			Dialogue.say("System", "Crate located. Movement around it — you are not the only one who got the signal.")
		else:
			Dialogue.say("System", "Crate located and quiet. Take it.")
	Q.report(String(q["event"]), 1)

func _supply_2(q: Dictionary) -> void:
	var key := "supply"
	if _ev_abandoned(q, key):
		return
	# Победа — ГРУЗ У ИГРОКА, а не «убей всех»: засада тут помеха, а не цель.
	if _props.position_for("event_supply") != null:
		return
	_ev_done(q, key)

# ── «Defend Friendly Tech»: союзника бьют, его надо отбить ──────────────────

func _defend_1(q: Dictionary) -> void:
	var key := "defend"
	if _ev_abandoned(q, key):
		return
	if _ev_get_point(key) == null:
		return
	if not _ev_mobs.has(key):
		var at: Vector3 = _ev_point[key] as Vector3
		# СОЮЗНИК — обычная машина ИИ нашей фракции (0). Фракция и решает всё: чужие видят в
		# ней врага и бьют её, а по игроку она не стреляет (enemy_vehicle._is_enemy сравнивает
		# именно фракцию). Отдельной «дружественной» сущности заводить незачем.
		var ally: Array = _ev_spawn(key, at, [6], 0)
		if ally.is_empty():
			Q.skip_quest(String(q["id"]))
			return
		_ev_ally = ally[0]
		_ev_spawn(key, at + Vector3(20.0, 0.0, 0.0), [6, 7], 1, _ev_ally)
		Dialogue.say("System", "Friendly unit under fire. It will not last alone.")
	Q.report(String(q["event"]), 1)

var _ev_ally: Node3D = null

func _defend_2(q: Dictionary) -> void:
	var key := "defend"
	if _ev_abandoned(q, key):
		return
	if not _ev_mobs.has(key):
		# Состояние потеряно (перезаход): союзник и налётчики появляются заново, иначе
		# пустая ссылка на союзника читалась бы как «его добили».
		var at = _ev_get_point(key)
		if at != null:
			var ally: Array = _ev_spawn(key, at as Vector3, [6], 0)
			if not ally.is_empty():
				_ev_ally = ally[0]
				_ev_spawn(key, (at as Vector3) + Vector3(20.0, 0.0, 0.0), [6, 7], 1, _ev_ally)
		return
	# Союзника добили — защищать больше некого. Это не поражение с наказанием, а снятое
	# задание: цель исчезла не по вине игрока (см. Q.skip_quest).
	if not is_instance_valid(_ev_ally):
		_ev_clear(key)
		Q.skip_quest(String(q["id"]))
		return
	for m in _ev_mobs.get(key, []):
		if is_instance_valid(m) and m != _ev_ally:
			return
	_ev_ally = null
	_ev_done(q, key)

# ── «Enemy Waves»: волны прямо по твоей позиции ─────────────────────────────
const WAVES_COUNT := 2

func _waves_1(q: Dictionary) -> void:
	var key := "waves"
	var p: Node3D = _player()
	if p == null:
		return
	# Точка — ГДЕ СТОИТ ИГРОК: волны приходят к нему, ехать никуда не надо. Она нужна не для
	# компаса, а для правила «уехал на 500 м — задание снято».
	if not _ev_point.has(key):
		_ev_point[key] = p.global_position
	if _ev_abandoned(q, key):
		return
	if not _ev_mobs.has(key):
		_ev_spawn(key, p.global_position, [5, 6], 1, p)
		Dialogue.say("System", "Contacts inbound on your position. First wave.")
	if not _ev_all_dead(key):
		return
	_ev_mobs.erase(key)                        # первая волна кончилась, вторую пустит стадия 2
	Q.report(String(q["event"]), 1)

func _waves_2(q: Dictionary) -> void:
	var key := "waves"
	if _ev_abandoned(q, key):
		return
	var p: Node3D = _player()
	if p == null:
		return
	if not _ev_mobs.has(key):
		_ev_spawn(key, p.global_position, [7, 8], 1, p)
		Dialogue.say("System", "Second wave. Heavier.")
		return
	if not _ev_all_dead(key):
		return
	_ev_done(q, key)

# ── «Take the Camp»: лагерь с охраной и трофеем ─────────────────────────────
# Это наш ответ на Capture Enemy Base. Захватывать БАЗУ пока нечего — статичной постройки
# как сущности в игре нет (она же нужна отложенным Watchtower/SAM, см. docs/STORY_ROADMAP.md).
# Смысл при этом сохранён: укреплённая точка, охрана, и трофей достаётся тому, кто её взял.

func _camp_1(q: Dictionary) -> void:
	var key := "camp"
	if _ev_abandoned(q, key):
		return
	if _ev_get_point(key) == null:
		return
	if not _ev_mobs.has(key):
		var at: Vector3 = _ev_point[key] as Vector3
		_ev_spawn(key, at, [7, 8, 9], 1, _player())
		_props.ensure("event_camp", G.Block.PACKER, at)
		Dialogue.say("System", "That is a staging point, not a patrol. Take it apart.")
	Q.report(String(q["event"]), 1)

func _camp_2(q: Dictionary) -> void:
	var key := "camp"
	if _ev_abandoned(q, key):
		return
	if not _ev_mobs.has(key):
		var at = _ev_get_point(key)      # состояние потеряно — охрана снова на точке
		if at != null:
			_ev_spawn(key, at as Vector3, [7, 8, 9], 1, _player())
		return
	if not _ev_all_dead(key):
		return
	if _props.position_for("event_camp") != null:
		return                                  # охрана кончилась, трофей ещё лежит
	_ev_done(q, key)
