class_name TutorialDirector
extends Node

# Наставник обучения: смотрит, какой шаг сейчас активен (это решает Q), и ставит палец
# (TutorialGuide) на то, что надо нажать. Шаги — обычные квесты типа TUTORIAL, поэтому
# прогресс, персист и трекер достаются даром; здесь только «куда показать и что сказать».
#
# Живёт под HUD: цели — это его же кнопки, а палец должен гаситься вместе с ним.

const GUIDE := preload("res://tutorial_guide.gd")

# Стартовая машина — ОДНА кабина, вокруг падает базовый набор (world_persist._fresh_start).
const STARTER_BLOCKS: int = 7    # G.FIRST_KIT: how many blocks tut_place_all asks for (the gun comes later)
const CABIN_BLOCKS: int = 1      # что уже стоит на машине к началу обучения

var _guide: TutorialGuide = null
var _step: String = ""           # id текущего шага (пусто — обучение не идёт)
# Ключ текущего наведения: шаг + цель + текст. Именно ТЕКСТ в ключе важен — соседние шаги
# показывают на одну и ту же точку (машину), и по одной лишь цели палец не обновлялся:
# после первого поставленного блока подсказка так и висела со старым текстом.
var _aimed: String = ""
var _story_started: bool = false
var _assembly_shown: int = -1    # что уже записано в прогресс шага сборки

# Пояснения к ЗАКРЫТОМУ шагу. Каждая реплика показывает пальцем на ТУ САМУЮ часть экрана,
# о которой говорит, и только когда очередь кончится, палец уходит на следующий шаг.
#
# Сейчас таблица ПУСТА, и это не забывчивость: все прежние пояснения были про журнал, склад,
# магазин, древо и звук — то есть про кнопки, которые игрок и так нажимает сам. Механизм
# остался для тех механик, которые правда требуют слов; появится такая — впишется сюда.
# t — ключ цели (см. _explain_target), s — что написать в пузыре.
const EXPLAIN := {}

## Что говорит Механик, когда обучение закончилось. Это ровно те две вещи, которых НЕ УГАДАТЬ
## и которым негде научиться по ходу: длинное нажатие по своему блоку (настройки фабрики и
## меню чужой машины) и жест закрытия большого окна. Всё остальное объясняет само себя.
const FINAL_HINTS := [
	"Hold a finger on one of your own blocks for its settings — that is where a factory picks what it makes and which side it feeds.",
	"A full-screen window closes with a swipe up from the bottom edge. The cross in the corner works too.",
]

# Очередь пояснений текущего шага. Пока она не пуста, палец на следующий шаг НЕ переходит.
var _explain: Array = []
var _explain_t: float = 0.0
const EXPLAIN_CHARS_PER_SEC: float = 17.0    # медленнее реплик Механика: тут ещё и смотреть надо
const EXPLAIN_MIN: float = 2.6
const EXPLAIN_MAX: float = 8.0
const EXPLAIN_MAX_WAIT: int = 12         # ~3 с ожидания цели, потом реплика пропускается
var _explain_wait: int = 0

func _ready() -> void:
	_guide = GUIDE.new()
	add_child(_guide)
	_guide.bind_hud(get_parent())
	_guide.skip_pressed.connect(Q.skip_tutorial)
	Q.changed.connect(_on_quests_changed)
	Q.tutorial_finished.connect(_on_tutorial_finished)
	set_process(true)
	_on_quests_changed()
	# Debug switch (Main → Отладка → Мир). Closing the steps through skip_tutorial, not by
	# refusing to show them: the rest of the game asks Q.tutorial_active() — the enemy spawner
	# keeps the world empty, the story waits for tutorial_finished — so a walkthrough merely
	# hidden would leave the world frozen with no way out of it.
	if not G.debug(&"tutorial") and Q.tutorial_active():
		Q.skip_tutorial()

# ── Текущий шаг ──────────────────────────────────────────────────────────────
func _on_quests_changed() -> void:
	var id := _current_step_id()
	if id == _step:
		return
	# Шаг сменился. Если у закрытого шага есть пояснения — сначала проговариваем их, показывая
	# пальцем на разбираемую часть, и только потом наводимся на следующий шаг.
	var closed := _step
	_step = id
	_aimed = ""
	_route_prev = ""
	if closed != "" and EXPLAIN.has(closed):
		_explain = (EXPLAIN[closed] as Array).duplicate()
		_show_explain()
		return
	if _step == "":
		_guide.clear()
		_set_ui_locked(false)
		_clear_blueprint()          # обучение кончилось — чертёж больше не нужен
		_say_final_hints()

func _current_step_id() -> String:
	for q in Q.quests:
		if int(q["type"]) != Q.Type.TUTORIAL or q["done"]:
			continue
		# quests хранит шаги в порядке добавления, он же order — первый невыполненный и есть
		# текущий (ту же выборку делает Q._current_tutorial).
		return str(q["id"])
	return ""

# ── Кадр: цель может появиться/переехать (гараж открылся, машина едет) ────────
func _process(delta: float) -> void:
	# Прогресс сборки считаем ВСЕГДА, в том числе пока идёт очередь пояснений. Раньше эта
	# ветка выходила раньше счётчика, и всё, что игрок навесил за время реплик, не считалось.
	if _step == "tut_place_all":
		_drive_assembly_progress()
	elif ARSENAL.has(_step):
		_drive_arsenal()
	if not _explain.is_empty():
		_explain_tick(delta)
		return
	if _step == "":
		return
	# ЧЕРТЁЖ СТОИТ С ПЕРВОГО ШАГА, а не с того, где начинают ставить блоки. Раньше его
	# показывали только в tut_place_first, и на «нажми BUILD» и «возьми деталь» игрок смотрел
	# на голую кабину: он не знал, ЧТО собирает, и брал блоки наугад. Чертёж — это картинка
	# цели, а цель полагается видеть с самого начала, а не после третьего шага.
	_show_blueprint()
	_aim_current_step()

# ── Пояснения ────────────────────────────────────────────────────────────────
func _explain_tick(delta: float) -> void:
	_explain_t -= delta
	if _explain_t > 0.0:
		return
	_explain.pop_front()
	_show_explain()

func _show_explain() -> void:
	if _explain.is_empty():
		_aimed = ""                       # очередь кончилась — палец возвращается к шагу
		if _step == "":
			_guide.clear()
			_set_ui_locked(false)
		return
	var e: Dictionary = _explain[0]
	var text := str(e["s"])
	var node: Control = _explain_target(str(e["t"]))
	if node == null or not node.is_visible_in_tree():
		# Цель ещё не построена (панель только открылась) — ждём, но не вечно: заглушка
		# висит, и застрять перед ней хуже, чем пропустить одну реплику.
		_explain_wait += 1
		if _explain_wait > EXPLAIN_MAX_WAIT:
			_explain_wait = 0
			_explain.pop_front()
			_show_explain()
			return
		_explain_t = 0.25
		return
	_explain_wait = 0
	_explain_t = clampf(float(text.length()) / EXPLAIN_CHARS_PER_SEC, EXPLAIN_MIN, EXPLAIN_MAX)
	_guide.point_at_node(node, tr(text))

func _explain_target(key: String) -> Control:
	if key.begins_with("quest_"):
		var q: Node = get_tree().get_first_node_in_group("quests")
		if q == null or not q.has_method("tutorial_target"):
			return null
		return q.tutorial_target(key.substr(6))
	if key.begins_with("garage_"):
		return _garage_node(key.substr(7))
	return null

# Прогресс сборки СЧИТАЕМ, а не накапливаем по событию: по block_placed его крутили бы
# циклом «поставил — снял — поставил». Здесь снятый блок сразу уменьшает прогресс.
func _drive_assembly_progress() -> void:
	var v: Node = _vehicle()
	if v == null or v.get("block_map_node") == null:
		return
	var n: int = 0
	for b in v.block_map_node.get_children():
		if "block" in b:
			n += 1                       # у меша-призрака поля block нет — он не считается
	var want: int = clampi(n - CABIN_BLOCKS, 0, STARTER_BLOCKS)
	# ШАГ ЗАКРЫВАЕТСЯ, КОГДА ВЕШАТЬ БОЛЬШЕ НЕЧЕГО, а не когда навешено ровно восемь.
	#
	# Жёсткая восьмёрка делала шаг непроходимым от любой мелочи: блок укатился под текстуру,
	# сгорел, был продан, потерялся при возрождении — и обучение вставало навсегда, потому что
	# восьмого блока в мире физически не существует. Считать «сколько осталось» надёжнее, чем
	# «сколько поставлено»: пусто — значит собрал, сколько бы их ни оказалось на самом деле.
	if _pending_blocks() <= 0:
		want = STARTER_BLOCKS
	if want == _assembly_shown:
		return                           # set_progress шлёт changed БЕЗУСЛОВНО — иначе весь
	_assembly_shown = want               # список квестов пересобирался бы каждый кадр
	Q.set_progress("tut_place_all", want)

## Сколько блоков СТАРТОВОГО НАБОРА ещё ждёт установки: в инвентаре, в руке и лежащие
## РЯДОМ С МАШИНОЙ. Кабину и стационарные не считаем — их на машину и не поставить.
##
## Радиус тут обязателен. Считать все свободные блоки мира было ошибкой: там валяются обломки
## сбитых врагов, предметы квестов и всё, что игрок когда-либо выбросил, — счётчик не
## обнулялся никогда, и запасной выход из шага не срабатывал вовсе. Стартовый набор падает
## орбитой прямо у машины (award_block_list), так что смотреть дальше незачем.
const PENDING_RADIUS := 40.0

func _pending_blocks() -> int:
	var n: int = G.block_inventory.size()
	var v: Node = _vehicle()
	if v != null and v.get("block_take") == true and v.get("block_body") != null:
		n += 1                           # блок в руке — он ещё не на машине, но и не потерян
	var objects: Node = get_node_or_null("/root/Main/objects")
	if objects == null or not (v is Node3D):
		return n
	var from: Vector3 = (v as Node3D).global_position
	for c in objects.get_children():
		if not ("block" in c) or not (c is Node3D):
			continue
		var bt: int = int(c.get("block"))
		if G.is_cabin(bt) or G.is_stationary(bt):
			continue
		if from.distance_squared_to((c as Node3D).global_position) > PENDING_RADIUS * PENDING_RADIUS:
			continue                     # это не наш набор, а чужой хлам где-то в мире
		n += 1
	return n

# ── ЧЕРТЁЖ СТАРТОВОЙ МАШИНЫ ──────────────────────────────────────────────────
# Сборка — единственное, чего в этой игре не угадать: блоки стыкуются ГРАНЯМИ, у каждого они
# свои, и «поставь как хочешь» на первой машине оборачивается колесом на стволе и кабиной без
# колёс. Поэтому обучение показывает ЧЕРТЁЖ: белый призрак блока стоит в той клетке, куда он
# и должен встать (build_hint.gd), а палец ведёт к ближайшей незакрытой.
#
# Раскладка — ровно стартовый набор (G.FIRST_KIT: два блока, четыре малых колеса, малый бур)
# вокруг кабины, которая уже стоит в центре сетки. Ни одного лишнего блока: чертёж,
# в котором чего-то не хватает, читается как ошибка игрока, а не как подсказка.
#
# Повороты колёс не на глаз: у колеса connect_faces = 2 (стыкуется задом, +Z), и к корпусу
# его разворачивают ±90° по Y — те же числа, что в сборках врага (blocks._side_wheels).
## Машина растёт ВДОЛЬ, а не вверх: корпус спереди и сзади кабины, на переднем — бур.
## Второй этаж тут ни к чему — бур, поставленный на крышу, до земли не достаёт, а игрок с
## первой же машины должен увидеть рабочую схему: чем копать впереди, чем ехать, чем бить.
const BLUEPRINT := [
	{"cell": Vector3i(5, 5, 4), "block": G.Block.BLOCK,       "yaw": 0.0},   # корпус ПЕРЕД кабиной
	{"cell": Vector3i(5, 5, 6), "block": G.Block.BLOCK,       "yaw": 0.0},   # и позади — под колёса
	# ПЕРЕДНЯЯ ПАРА — У ПЕРЕДНЕГО БЛОКА (z = 4), а не по бокам кабины. Стояли обе пары через
	# клетку, кабина оказывалась в свесе, и собранная по чертежу машина клевала носом на первом
	# же бугре. Разнесённая по краям корпуса база — это ещё и то, как машина выглядит: игрок
	# копирует чертёж и дальше строит по его образцу.
	{"cell": Vector3i(4, 5, 4), "block": G.Block.SMALL_WHEEL, "yaw": PI / 2},
	{"cell": Vector3i(6, 5, 4), "block": G.Block.SMALL_WHEEL, "yaw": -PI / 2},
	{"cell": Vector3i(4, 5, 6), "block": G.Block.SMALL_WHEEL, "yaw": PI / 2},
	{"cell": Vector3i(6, 5, 6), "block": G.Block.SMALL_WHEEL, "yaw": -PI / 2},
	{"cell": Vector3i(5, 5, 3), "block": G.Block.SMALL_DRILL, "yaw": 0.0},   # бур НА переднем блоке
]
## The gun's place, outlined only in the step that bolts it on (the kit has no gun, see ARSENAL).
const GUN_CELL := Vector3i(5, 6, 5)

var _hints: Array = []

## Разложить чертёж на машине игрока. Зовётся, когда обучение дошло до сборки, и ровно один
## раз: призрак гаснет сам, когда в его клетке появился нужный блок.
func _show_blueprint() -> void:
	if not _hints.is_empty():
		return
	var v: Node = _vehicle()
	if v == null or v.get("block_map_node") == null:
		return
	var bm = v.block_map_node
	for e in BLUEPRINT:
		var cell: Vector3i = e["cell"]
		if bm.has_method("get_block") and int(bm.get_block(cell.x, cell.y, cell.z)) == int(e["block"]):
			continue
		var h := BuildHint.create(bm, cell, int(e["block"]), Vector3(0.0, float(e["yaw"]), 0.0))
		if h != null:
			_hints.append(h)

func _clear_blueprint() -> void:
	for h in _hints:
		if is_instance_valid(h):
			(h as Node).queue_free()
	_hints.clear()

## Незакрытая клетка чертежа, куда показывать палец, — или null, если чертёж собран.
##
## ПАЛЕЦ ПОКАЗЫВАЕТ МЕСТО ИМЕННО ТОГО БЛОКА, ЧТО В РУКЕ. Раньше он брал ближайшую к машине
## клетку какую попало, и это было хуже, чем ничего: игрок держит колесо, палец показывает на
## клетку корпуса, тап туда не срабатывает (колесо стыкуется только задом), и остаётся гадать,
## что не так — рука, место или сам жест. Плюс все восемь клеток чертежа лежат в паре метров от
## центра машины, поэтому «ближайшая» каждый раз оказывалась примерно одной и той же, у самой
## кабины: палец упирался в середину и на дальние клетки (бур, задние колёса) не уходил вовсе.
##
## Рука пуста — показываем ближайшую к КАМЕРЕ, а не к машине: игрок смотрит на машину с одной
## стороны, и вести его на клетку за корпусом значит показывать сквозь него.
func _next_hint():
	_hints = _hints.filter(func(h): return is_instance_valid(h))
	if _hints.is_empty():
		return null
	var want: int = _held_block()
	var h = BuildHint.pick(_hints, want, _aim_origin())
	# В руке блок, которого в чертеже уже нет (игрок поднял лишнее или подобрал обломок) —
	# показываем на ближайшую свободную клетку: оставить палец висеть в воздухе хуже.
	if h == null and want >= 0:
		h = BuildHint.pick(_hints, -1, _aim_origin())
	return h

## THE PART TO TAKE IS THE ONE THE PLAN CAN TAKE NOW: the type of the first reachable open cell
## (`BuildHint.pick`), the hull blocks before the wheels and the drill hanging on them. The finger
## went to whatever lay nearest, and a wheel taken before the front block had no cell to go to
## (the player's report). -1 when the plan is done or nothing is reachable.
func _wanted_type() -> int:
	_hints = _hints.filter(func(h): return is_instance_valid(h))
	for h in _hints:
		if (h as BuildHint).reachable():
			return (h as BuildHint).block_type
	return -1

## Тип блока В РУКЕ или -1, если рука пуста. Спрашиваем у самого тела, а не у флага: флаг
## говорит лишь «что-то держим».
func _held_block() -> int:
	var v: Node = _vehicle()
	if v == null or v.get("block_take") != true:
		return -1
	var body = v.get("block_body")
	if body == null or not is_instance_valid(body) or body.get("block") == null:
		return -1
	return int(body.get("block"))

## Откуда мерить «ближе»: от камеры, если она есть, иначе от машины.
func _aim_origin() -> Vector3:
	var cam := get_viewport().get_camera_3d() if get_viewport() != null else null
	if cam != null:
		return cam.global_position
	var v: Node = _vehicle()
	return (v as Node3D).global_position if v is Node3D else Vector3.ZERO

## Точка чертежа для пальца: нужная клетка, а нет такой — сама машина.
func _blueprint_point() -> Vector3:
	var h = _next_hint()
	if h != null:
		return (h as BuildHint).tap_point(_aim_origin())   # the face it bolts onto, not the cell
	return _vehicle_point()

## Две неочевидные механики В КОНЦЕ обучения, репликой, а не шагом: заставлять игрока
## «сделай длинное нажатие» на пустом месте нечего, а знать про них надо — сами эти жесты
## нигде не подписаны.
var _final_said: bool = false

func _say_final_hints() -> void:
	if _final_said:
		return
	_final_said = true
	for line in FINAL_HINTS:
		Dialogue.say("Mechanic", tr(String(line)))

func _aim_current_step() -> void:
	match _step:
		"tut_mode_build":
			# THE GAME TAKES THIS STEP ITSELF (the player's call: the tutorial opens in assembly).
			# Once the machine stands in the world - the planetfall intro over - it enters assembly
			# through the machine's own door, the one the BUILD button's action reaches, which
			# reports the step; the HUD follows the machine's state and opens the build tab.
			var vb: Node = _vehicle()
			if vb == null or vb.has_meta("intro_hidden") or not G.world_ready() \
					or get_tree().get_first_node_in_group("planetfall_intro") != null:
				return
			if "Building" in vb and vb.Building:
				Q.report("mode_building", 1)
			elif vb.has_method("_on_building_pressed"):
				vb._on_building_pressed()
		"tut_take_world":
			# Рука уже занята (блок взяли раньше, чем шаг стал текущим) — засчитываем сразу.
			# Иначе тупик: поставить нельзя (цель — блок на земле), взять нечем.
			var vt: Node = _vehicle()
			if vt != null and "block_take" in vt and vt.block_take:
				Q.report("block_taken_world", 1)
				return
			# Gate.WORLD, а не круг вокруг цели: игрок берёт не тот блок, промахивается мимо
			# круга, и любой из этих случаев запирал его насмерть. Мир открыт целиком, UI — нет.
			_aim_world(_nearest_loose_block, "Double-tap a part to hold it",
					TutorialGuide.Gate.WORLD)
		"tut_place_first":
			_show_blueprint()
			_aim_world(_blueprint_point, "Double-tap the outlined cell to attach it there",
					TutorialGuide.Gate.WORLD)
		"tut_place_all":
			# Свободный шаг: мир открыт, UI — нет. Палец не висит на машине всё время, а
			# показывает, что делать СЕЙЧАС: блок в руке — куда ставить, рука пуста — что брать.
			_show_blueprint()
			var v: Node = _vehicle()
			var holding: bool = v != null and "block_take" in v and v.block_take
			if holding:
				_aim_world(_blueprint_point, "Now attach it — the outline shows where",
						TutorialGuide.Gate.WORLD)
			else:
				_aim_world(_nearest_loose_block, "Take the next part",
						TutorialGuide.Gate.WORLD)
		"tut_tree", "tut_research_gun", "tut_inventory", "tut_take_gun", "tut_place_gun":
			_aim_arsenal()
		"tut_quests":
			_aim_node(_quest_tracker(), "Your directive tracker. Tap it")
		"tut_garage":
			_aim_node(_hud_ui("menu"), "This opens your storage")
		"tut_filters":
			_aim_node(_garage_node("filters"), "These sort your parts by kind. Try one")
		"tut_shop":
			_aim_node(_garage_node("tab_shop"), "SHOP — this is where blocks are bought")
		"tut_tech":
			_aim_node(_garage_node("tab_tech"), "TECH — this is where blocks are unlocked")
		"tut_music":
			_aim_node(_garage_node("tab_music"), "And audio")

# ── Наведение ────────────────────────────────────────────────────────────────
# Цели-кнопки появляются не сразу (гараж инстансится при первом открытии), поэтому
# отсутствие цели — не ошибка: просто ждём следующего кадра.
func _aim_node(node: CanvasItem, text: String, double_tap: bool = false) -> void:
	if node == null or not is_instance_valid(node) or not node.is_visible_in_tree():
		# ЧУЖОЙ ПУЗЫРЬ ГАСИМ ВСЕГДА, а не только если наводились сами. Смена шага сбрасывает
		# _aimed в пустую строку, и по старому условию подсказка ПРОШЛОГО шага оставалась
		# висеть, пока цель нового не появится: игрок дочитывал «поставь блок» в тот момент,
		# когда обучение уже ждало от него совсем другого.
		_aimed = ""
		if _guide.is_active():
			_guide.clear()
		return
	var key := "%s|%d|%s" % [_step, node.get_instance_id(), text]
	if _aimed == key:
		return
	_aimed = key
	_set_ui_locked(false)
	_guide.point_at_node(node, text, double_tap)

func _aim_world(getter: Callable, text: String, gate: int = TutorialGuide.Gate.TARGET) -> void:
	var key := "%s|%s|%s" % [_step, getter.get_method(), text]
	if _aimed == key:
		return
	_aimed = key
	# В режиме WORLD заглушки нет (иначе она съела бы и тап по миру), поэтому меню/гараж
	# на время шага гасим отдельно — руками HUD.
	_set_ui_locked(gate == TutorialGuide.Gate.WORLD)
	_guide.point_at_world(getter, tr(text), true, gate)

func _set_ui_locked(locked: bool) -> void:
	var hud: Node = get_parent()
	if hud != null and hud.has_method("set_ui_locked"):
		hud.set_ui_locked(locked)

# ── Поиск целей ──────────────────────────────────────────────────────────────
func _hud_node(node_name: String) -> CanvasItem:
	var hud: Node = get_parent()
	if hud == null:
		return null
	return hud.get_node_or_null(node_name) as CanvasItem

func _hud_ui(key: String) -> Control:
	var hud: Node = get_parent()
	if hud == null or not hud.has_method("tutorial_target"):
		return null
	return hud.tutorial_target(key)

## Открыт ли гараж прямо сейчас. Пока он открыт, игровые кнопки скрыты (hud._set_game_controls_hidden),
## и наводиться на них бессмысленно.
func _garage_open() -> bool:
	var g: Control = _hud_ui("garage")
	return g != null and g.visible

func _garage_node(key: String) -> Control:
	var g: Node = _hud_ui("garage")
	if g == null or not g.has_method("tutorial_target"):
		return null
	return g.tutorial_target(key)

func _quest_tracker() -> Control:
	var q: Node = get_tree().get_first_node_in_group("quests")
	if q == null or not q.has_method("tracker_node"):
		return null
	return q.tracker_node()

func _vehicle() -> Node:
	var cc: Node = get_tree().get_first_node_in_group("camera_controller")
	if cc != null and "current_vehicle" in cc:
		var v = cc.current_vehicle          # untyped: it can be freed under us (CLAUDE.md rule 4)
		return v if is_instance_valid(v) else null
	return null

func _vehicle_point() -> Vector3:
	var v: Node = _vehicle()
	if not (v is Node3D):
		return Vector3.ZERO
	return (v as Node3D).global_position + Vector3.UP

# Ближайший ПОДБИРАЕМЫЙ блок в мире — на него показываем в шаге «подбери блок».
# Кабину _grab_world_block не берёт, и палец на неё показывал тупик — игрок тапал, ничего не
# происходило. Стационарные блоки поднимать теперь МОЖНО, но в обучении палец на них не
# наводим: с опоры и продавца начинается база, а шаг учит ставить блок на машину.
func _nearest_loose_block() -> Vector3:
	var objects: Node = get_node_or_null("/root/Main/objects")
	var v: Node = _vehicle()
	if objects == null or not (v is Node3D):
		return Vector3.ZERO
	var origin: Vector3 = (v as Node3D).global_position
	var want: int = _wanted_type()
	var best: Vector3 = Vector3.ZERO
	var best_d: float = INF
	var best_w: Vector3 = Vector3.ZERO
	var best_wd: float = INF
	for c in objects.get_children():
		if not ("block" in c) or not (c is Node3D):
			continue
		var bt: int = int(c.get("block"))
		if G.is_cabin(bt) or G.is_stationary(bt):
			continue
		var d: float = origin.distance_squared_to((c as Node3D).global_position)
		if d < best_d:
			best_d = d
			best = (c as Node3D).global_position
		if bt == want and d < best_wd:
			best_wd = d
			best_w = (c as Node3D).global_position
	if best_wd < INF:
		return best_w                     # the part the plan can take now
	return best if best_d < INF else origin

# ── ARSENAL: the gun through the tree and the inventory ──────────────────────
# THE KIT HAS NO GUN (the player's call, G.FIRST_KIT): once the machine is built the tutorial walks
# to the TREE, researches the Machine Gun (grade 1, 0 RP - research hands one into the inventory),
# opens the INVENTORY, takes the gun and bolts it onto the cabin. Every step is closed HERE by what
# the game shows (`_drive_arsenal`), never by an event: a player who gets ahead - the gun already in
# hand, already on the machine - is let through at once. AND A PLAYER WHO STRAYS IS BROUGHT BACK: the
# finger always points at what leads back (the backpack while the garage is closed, the right tab
# while another is open), and the Mechanic says so once when it happens (`_stray`).
const ARSENAL := ["tut_tree", "tut_research_gun", "tut_inventory", "tut_take_gun", "tut_place_gun"]
const TAB_INVENTORY := 0          # tech_ui's enum
const TAB_TECH := 5
const STRAY_GAP := 6.0            # s between two "you strayed" lines
var _route_prev: String = ""
var _stray_t: float = -1e9
var _gun_hint: Node = null

func _garage_tab() -> int:
	var g: Node = _hud_ui("garage")
	if g == null or not (g as Control).visible:
		return -1
	return int(g.get("_tab"))

func _gun_on_machine() -> bool:
	var v: Node = _vehicle()
	if v == null or v.get("block_map_node") == null:
		return false
	for b in v.block_map_node.get_children():
		if b.get("block") != null and int(b.get("block")) == int(G.Block.GUN):
			return true
	return false

func _drive_arsenal() -> void:
	var gun: int = int(G.Block.GUN)
	var tab: int = _garage_tab()
	var on: bool = _gun_on_machine()
	var held: bool = _held_block() == gun
	match _step:
		"tut_tree":
			if tab == TAB_TECH or G.researched.has(gun):
				Q.set_progress(_step, 1)
		"tut_research_gun":
			if G.researched.has(gun):
				Q.set_progress(_step, 1)
		"tut_inventory":
			if tab == TAB_INVENTORY or held or on:
				Q.set_progress(_step, 1)
		"tut_take_gun":
			if held or on:
				Q.set_progress(_step, 1)
			elif G.block_available(gun) <= 0:
				# The researched gun went somewhere the plan cannot follow: hand another over rather
				# than leave the tutorial without a way on.
				G.block_inventory.append(gun)
		"tut_place_gun":
			if on:
				_clear_gun_hint()
				Q.set_progress(_step, 1)

## Where the step wants the player and the finger that leads there.
func _aim_arsenal() -> void:
	var gun: int = int(G.Block.GUN)
	var tab: int = _garage_tab()
	var route: String = "ok"
	if _step == "tut_place_gun" and _held_block() == gun:
		_show_gun_hint()
		_aim_world(_gun_point, "Double-tap the cabin's roof to attach it", TutorialGuide.Gate.WORLD)
		_route_prev = "ok"
		return
	if tab < 0:
		route = "closed"
		_aim_node(_hud_ui("menu"), "Open the garage")
	else:
		var want_tab: int = TAB_TECH if _step in ["tut_tree", "tut_research_gun"] else TAB_INVENTORY
		if tab != want_tab:
			route = "tab"
			_aim_node(_garage_node("tab_tech" if want_tab == TAB_TECH else "tab_inventory"),
					"Open the TREE" if want_tab == TAB_TECH else "Open the INVENTORY")
		elif _step == "tut_research_gun":
			# THE NODE ITSELF, DOUBLE-TAPPED (tech_ui._make_tech_node researches on a quick second
			# tap): the Research button sits at the scroll's bottom, under the dialogue strip.
			_aim_node(_garage_node("tech_gun"), "Double-tap the Machine Gun — it costs 0 RP", true)
		else:
			var slot: Control = _garage_node("inv_gun")
			if slot != null:
				_aim_node(slot, "Tap the gun to take it")
			else:
				_aim_node(_garage_node("filters"), "Show all parts")
	_stray(route)
	_route_prev = route

func _stray(route: String) -> void:
	if route == _route_prev or route == "ok" or _route_prev == "":
		return
	if route == "tab" and _route_prev != "ok":
		return                        # the step began on another tab: that is the way, not a stray
	var now: float = Time.get_ticks_msec() / 1000.0
	if now - _stray_t < STRAY_GAP:
		return
	_stray_t = now
	Dialogue.say("Mechanic", tr("The garage closed. The backpack in the corner opens it again.") if route == "closed"
			else tr("That is another tab — follow the finger back."))

func _show_gun_hint() -> void:
	if is_instance_valid(_gun_hint):
		return
	var v: Node = _vehicle()
	if v == null or v.get("block_map_node") == null:
		return
	_gun_hint = BuildHint.create(v.block_map_node, GUN_CELL, int(G.Block.GUN), Vector3.ZERO)

func _clear_gun_hint() -> void:
	if is_instance_valid(_gun_hint):
		_gun_hint.queue_free()
	_gun_hint = null

func _gun_point() -> Vector3:
	if is_instance_valid(_gun_hint):
		return (_gun_hint as BuildHint).tap_point(_aim_origin())
	return _vehicle_point()

# ── Конец обучения → первый сюжетный бой ─────────────────────────────────────
func _on_tutorial_finished() -> void:
	if _story_started:
		return
	_story_started = true
	_explain.clear()                      # пропуск в середине пояснения не должен держать заглушку
	_clear_gun_hint()
	_guide.clear()
	_set_ui_locked(false)
	_step = ""
	# НА ПОЛИГОНЕ СЮЖЕТА НЕТ. Обучение там закрывается сразу (флаг `tutorial` снят), и обе
	# следующие строки оказывались его единственным следом: Механик поздравлял с окончанием и
	# сообщал, что «земля тут нигде не ровная», стоя на ровной по определению земле, а за ним
	# заводился таймер первого врага — он упирался в запрет спавнера, то есть работал впустую.
	if G.proving_ground:
		return
	_say_lines(["That is the whole of it. Take it for a drive — the ground here is not level anywhere."])
	_first_enemy_after_delay()

## THE SCOUT COMES ONCE THE PLAYER DRIVES, AND LANDS RIGHT BY THEM (the player's call): after
## SCOUT_PAUSE (the Mechanic's line), as soon as the machine has gone SCOUT_MOVE from where the
## tutorial ended, the scout is asked for SCOUT_NEAR ahead - inside the 200 m clearance, which only
## guards machines that come by themselves. Its drop ring (enemy_spawner._hold_for_drop) stands
## there for three seconds first, and the quest is released with it, so the marker leads to the
## ring's middle before the machine is there.
const SCOUT_PAUSE := 4.0
const SCOUT_MOVE := 12.0
const SCOUT_NEAR := Vector2(40.0, 55.0)

func _first_enemy_after_delay() -> void:
	# ПРИДЕРЖИВАЕМ КВЕСТ, пока разведчика нет (см. _spawn_first_enemy): метке не на что показывать.
	# Ставится ЗДЕСЬ, в том же потоке, что и снятие: Q.reload_from_progress чистит придержки при
	# выборе слота, а он случается позже определения квестов.
	var q0: Node = get_node_or_null("/root/Q")
	if q0 != null and q0.has_method("hold_quest"):
		q0.hold_quest("story_first_blood")
	await get_tree().create_timer(SCOUT_PAUSE).timeout
	var from = null
	var held: Node = null
	while true:
		# after every await (CLAUDE.md): the player may have left for the menu
		if not is_inside_tree():
			return
		var v: Node = _vehicle()
		if v is Node3D:
			if v != held or from == null:
				held = v                      # a new machine (a respawn): measure from where it is
				from = (v as Node3D).global_position
			elif (from as Vector3).distance_squared_to((v as Node3D).global_position) >= SCOUT_MOVE * SCOUT_MOVE:
				break
		await get_tree().create_timer(0.25).timeout
	_spawn_first_enemy()

func _spawn_first_enemy() -> void:
	var sp: Node = get_node_or_null("/root/Main/EnemySpawner")
	var enemy: Node = null
	if sp != null and sp.has_method("spawn_scout_near_player"):
		enemy = sp.spawn_scout_near_player(SCOUT_NEAR.x, SCOUT_NEAR.y, true)
	# КВЕСТ ОБЪЯВЛЯЕТСЯ ЗДЕСЬ, А НЕ ПО КОНЦУ ОБУЧЕНИЯ. Снимаем придержку ровно тогда, когда
	# цель появилась в мире — тогда метка живая с первой секунды, а не через восемь.
	#
	# Снимаем и при НЕУДАЧЕ спавна тоже: ровного места рядом могло не найтись, но квест закрывается
	# любым врагом, и обычный поток кого-нибудь приведёт. Придержанный навсегда квест был бы хуже
	# любой метки.
	var q: Node = get_node_or_null("/root/Q")
	if q != null and q.has_method("release_quest"):
		q.release_quest("story_first_blood")
	if enemy == null:
		# Ровного места рядом не нашлось — квест всё равно закрываемый: обычный поток
		# врагов приведёт кого-нибудь сам, просто не так быстро.
		_say_lines(["Other processes run out there, and they were not asked to share."])
		return
	_say_lines([
		"Something picked up your signal. It is already close.",
		"Hold Attack — your guns pick their own targets. Go for the CABIN: break it and the rest comes apart.",
	])

func _say_lines(lines: Array) -> void:
	var d: Node = get_node_or_null("/root/Dialogue")
	if d == null:
		return
	for l in lines:
		d.say("Mechanic", tr(str(l)))
