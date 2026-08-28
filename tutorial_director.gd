class_name TutorialDirector
extends Node

# Наставник обучения: смотрит, какой шаг сейчас активен (это решает Q), и ставит палец
# (TutorialGuide) на то, что надо нажать. Шаги — обычные квесты типа TUTORIAL, поэтому
# прогресс, персист и трекер достаются даром; здесь только «куда показать и что сказать».
#
# Живёт под HUD: цели — это его же кнопки, а палец должен гаситься вместе с ним.

const GUIDE := preload("res://tutorial_guide.gd")

# Стартовая машина — ОДНА кабина, вокруг падает базовый набор (world_persist._fresh_start).
const STARTER_BLOCKS: int = 8    # столько блоков надо навесить в шаге tut_place_all
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
	if not _explain.is_empty():
		_explain_tick(delta)
		return
	if _step == "":
		return
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
	_guide.point_at_node(node, text)

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
		if bt == G.Block.CABIN or G.is_stationary(bt):
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
# Раскладка — ровно стартовый набор (G.STARTER_KIT: два блока, четыре малых колеса, малый бур
# и пушка) вокруг кабины, которая уже стоит в центре сетки. Ни одного лишнего блока: чертёж,
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
	{"cell": Vector3i(4, 5, 5), "block": G.Block.SMALL_WHEEL, "yaw": PI / 2},
	{"cell": Vector3i(6, 5, 5), "block": G.Block.SMALL_WHEEL, "yaw": -PI / 2},
	{"cell": Vector3i(4, 5, 6), "block": G.Block.SMALL_WHEEL, "yaw": PI / 2},
	{"cell": Vector3i(6, 5, 6), "block": G.Block.SMALL_WHEEL, "yaw": -PI / 2},
	{"cell": Vector3i(5, 5, 3), "block": G.Block.SMALL_DRILL, "yaw": 0.0},   # бур НА переднем блоке
	{"cell": Vector3i(5, 6, 5), "block": G.Block.GUN,         "yaw": 0.0},   # ствол на кабине
]

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

## Ближайшая к машине незакрытая клетка чертежа (или null — чертёж собран).
func _next_hint():
	_hints = _hints.filter(func(h): return is_instance_valid(h))
	var v: Node = _vehicle()
	var best = null
	var best_d: float = INF
	for h in _hints:
		if not (v is Node3D):
			return h
		var d: float = (v as Node3D).global_position.distance_squared_to((h as Node3D).global_position)
		if d < best_d:
			best_d = d
			best = h
	return best

## Точка чертежа для пальца: ближайшая незакрытая клетка, а нет такой — сама машина.
func _blueprint_point() -> Vector3:
	var h = _next_hint()
	if h != null:
		return (h as Node3D).global_position
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
		Dialogue.say("Mechanic", String(line))

func _aim_current_step() -> void:
	match _step:
		"tut_mode_build":
			_aim_node(_hud_node("ModeToggle"), "Tap BUILD — the button names where it takes you")
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
		"tut_mode_move":
			# Пока открыт гараж, кнопки режима на экране НЕТ — она спрятана вместе со всем
			# игровым управлением. Палец показывал в пустоту, подсказка не менялась, и шаг
			# выглядел так, будто обучение всё ещё просит навесить блок. Сначала выводим
			# из гаража, и только потом показываем на переключатель режима.
			if _garage_open():
				_aim_node(_hud_ui("menu"), "Assembled. Close storage")
			else:
				_aim_node(_hud_node("ModeToggle"), "Tap MOVE and drive")
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
func _aim_node(node: CanvasItem, text: String) -> void:
	if node == null or not is_instance_valid(node) or not node.is_visible_in_tree():
		if _aimed != "":
			_guide.clear()
			_aimed = ""
		return
	var key := "%s|%d|%s" % [_step, node.get_instance_id(), text]
	if _aimed == key:
		return
	_aimed = key
	_set_ui_locked(false)
	_guide.point_at_node(node, text)

func _aim_world(getter: Callable, text: String, gate: int = TutorialGuide.Gate.TARGET) -> void:
	var key := "%s|%s|%s" % [_step, getter.get_method(), text]
	if _aimed == key:
		return
	_aimed = key
	# В режиме WORLD заглушки нет (иначе она съела бы и тап по миру), поэтому меню/гараж
	# на время шага гасим отдельно — руками HUD.
	_set_ui_locked(gate == TutorialGuide.Gate.WORLD)
	_guide.point_at_world(getter, text, true, gate)

func _set_ui_locked(locked: bool) -> void:
	var hud: Node = get_parent()
	if hud != null and hud.has_method("set_ui_locked"):
		hud.set_ui_locked(locked)

# ── Поиск целей ──────────────────────────────────────────────────────────────
func _hud_node(name: String) -> CanvasItem:
	var hud: Node = get_parent()
	if hud == null:
		return null
	return hud.get_node_or_null(name) as CanvasItem

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
		return cc.current_vehicle
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
	var best: Vector3 = Vector3.ZERO
	var best_d: float = INF
	for c in objects.get_children():
		if not ("block" in c) or not (c is Node3D):
			continue
		var bt: int = int(c.get("block"))
		if bt == G.Block.CABIN or G.is_stationary(bt):
			continue
		var d: float = origin.distance_squared_to((c as Node3D).global_position)
		if d < best_d:
			best_d = d
			best = (c as Node3D).global_position
	return best if best_d < INF else origin

# ── Конец обучения → первый сюжетный бой ─────────────────────────────────────
func _on_tutorial_finished() -> void:
	if _story_started:
		return
	_story_started = true
	_explain.clear()                      # пропуск в середине пояснения не должен держать заглушку
	_guide.clear()
	_set_ui_locked(false)
	_step = ""
	_spawn_first_enemy.call_deferred()

func _spawn_first_enemy() -> void:
	var sp: Node = get_node_or_null("/root/Main/EnemySpawner")
	var enemy: Node = null
	if sp != null and sp.has_method("spawn_scout_near_player"):
		enemy = sp.spawn_scout_near_player()
	if enemy == null:
		# Ровного места рядом не нашлось — квест всё равно закрываемый: обычный поток
		# врагов приведёт кого-нибудь сам, просто не так быстро.
		_say_lines(["That is the whole of it. Other processes run out there, and they were not asked to share."])
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
		d.say("Mechanic", str(l))
