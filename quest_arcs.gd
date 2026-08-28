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

# ── Ветка «энергия»: солнечная панель + опора, затем реген ───────────────────
func _arc_power_1(q: Dictionary) -> void:
	# ОБА предмета под одним id квеста: компас спрашивает именно его, и под ключом
	# «arc_power+» опора оставалась без метки — лежала где-то в стороне, и выглядело это
	# как «якорь не выдали вовсе».
	#
	# Проверяем КАЖДЫЙ опрос, а не «положили один раз и забыли». ensure берёт то, что уже
	# лежит в мире (после перезахода предмет помечен и восстановлен сейвом), и кладёт новый,
	# только если цели действительно нет — сгорела, провалилась под рельеф, потерялась.
	# Условие «пока у игрока этого блока нет» обязательно: иначе подобранный предмет тут же
	# выдавался бы вторым.
	if not _player_owns(G.Block.SOLAR):
		_props.ensure("arc_power", G.Block.SOLAR)
	if not _player_owns(G.Block.SUPPORT):
		_props.ensure("arc_power", G.Block.SUPPORT)
	# Закрывает стадию ЯКОРЬ, а не наличие двух блоков. Смысл стадии — научить вставать на
	# опору: панель без якоря энергии не даёт (SOLAR_RATE идёт только на якоре), и засчитывать
	# «привинтил и поехал» значило бы пропустить ровно то, ради чего стадия существует.
	if _has_block(G.Block.SOLAR) and _has_block(G.Block.SUPPORT) and _is_anchored():
		Q.report(String(q["event"]), 1)

## Машина игрока СЕЙЧАС на якоре. Через get(), потому что поле есть только у машин игрока.
func _is_anchored() -> bool:
	var p: Node3D = _player()
	return p != null and p.get("anchored") == true

func _arc_power_2(q: Dictionary) -> void:
	var key := "power_2"
	if not _dropped.has(key):
		_dropped[key] = true
		# «Рядом с вами появился» — блок падает прямо у машины, искать не надо.
		_award(G.Block.REGEN)
	if _has_block(G.Block.REGEN):
		Q.report(String(q["event"]), 1)

# ── Ветка «радар»: найти свой, затем отобрать у вора ─────────────────────────
func _arc_radar_1(q: Dictionary) -> void:
	if not _player_owns(G.Block.RADAR):
		_props.ensure("arc_radar", G.Block.RADAR)
	if _has_block(G.Block.RADAR):
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

# ── Ветка «аккумулятор»: найти, затем выбить из жилы ─────────────────────────
func _arc_battery_1(q: Dictionary) -> void:
	if not _player_owns(G.Block.BATTERY):
		_props.ensure("arc_battery", G.Block.BATTERY)
	if _has_block(G.Block.BATTERY):
		Q.report(String(q["event"]), 1)

func _arc_battery_2(q: Dictionary) -> void:
	# Жила «держит» аккумулятор: выработал её досуха — блок падает рядом.
	var key := "battery_2"
	if not _dropped.has(key):
		_dropped[key] = true
	if _has_block(G.Block.BATTERY):
		Q.report(String(q["event"]), 1)

# ── «Salvage Run»: сбитый груз под охраной ───────────────────────────────────
# Замена станции из оригинала. Магазинов у нас нет, поэтому «доехать до станции и отбить её»
# превращается в «доехать до груза и отбить его», а наградой становится КОЛЛЕКТОР — блок, без
# которого не собрать производственную цепочку в следующем квесте.
const SALVAGE_DIST := 180.0
const SALVAGE_REACH := 45.0

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
		var wp: Vector3 = p.global_position + Vector3(cos(ang) * SALVAGE_DIST, 0.0, sin(ang) * SALVAGE_DIST)
		wp.y = G.ground_y(wp, p.global_position.y)
		_salvage_point = wp
		return
	if p.global_position.distance_squared_to(_salvage_point as Vector3) > SALVAGE_REACH * SALVAGE_REACH:
		return
	# Подъехали — груз на месте, и он не бесхозный. Охранник появляется ЗДЕСЬ, а не ждал сутки
	# на точке: спавн по прибытии дешевле и надёжнее, чем машина, живущая где-то с начала игры.
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
	# Охрана кончилась — груз наш. Коллектор кладём В МИР рядом с точкой, а не молча в
	# инвентарь: игрок должен его увидеть и подобрать, как любой трофей.
	if not _player_owns(G.Block.COLLECTOR):
		_props.ensure("arc_salvage", G.Block.COLLECTOR, _salvage_point)
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
const LINE_BELTS := 5          # всего лент в наборе, одна из них уже стоит на продавце
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
## Куда врезается процессор: СЕРЕДИНА линии. Его футпринт 2×2×2 занимает x∈{4,5}, z∈{7,8} —
## то есть две клетки самой линии и две СЛЕВА от неё, корпусом в сторону. Вход у него сзади
## (+Z), выход спереди (−Z), как у ленты, поэтому поток не разворачивается.
const LINE_PROC_PLAN := [
	{"cell": Vector3i(5, 5, 8), "block": G.Block.PROCESSOR},
]

var _hints: Array = []

## Куда ведёт компас, пока площадка не появилась.
func line_point() -> Variant:
	return _line_point

## Разметка: белый призрак блока в каждой клетке схемы (build_hint.gd). Показывает форму,
## клетку и поворот — то, чего текст задания сказать не может.
func _show_plan(plan: Array) -> void:
	_clear_plan()
	if _line_base == null or not is_instance_valid(_line_base):
		return
	var bm = _line_base.get("block_map_node")
	if bm == null or not is_instance_valid(bm):
		return
	for e in plan:
		var cell: Vector3i = e["cell"]
		# Клетка уже занята нужным блоком (её поставил квест) — разметка ей не нужна.
		if bm.has_method("get_block") and int(bm.get_block(cell.x, cell.y, cell.z)) == int(e["block"]):
			continue
		var h := BuildHint.create(bm, cell, int(e["block"]))
		if h != null:
			_hints.append(h)

func _clear_plan() -> void:
	for h in _hints:
		if is_instance_valid(h):
			(h as Node).queue_free()
	_hints.clear()
	_point_finger("")

## Палец наставника на БЛИЖАЙШУЮ незакрытую клетку схемы. Тот же палец, что в обучении:
## второй такой указатель заводить незачем, а привычка у игрока уже есть.
##
## Пустой текст — убрать. Ничего не блокируем (Gate.OFF) и не предлагаем пропустить
## обучение: это сюжетное задание, а не вводная.
var _finger_text: String = ""

func _point_finger(text: String) -> void:
	var guide: Node = get_tree().get_first_node_in_group("tutorial_guide")
	if guide == null:
		return
	if text == "" or _next_hint() == null:
		if _finger_text != "" and guide.has_method("is_active") and guide.is_active():
			guide.clear()
		_finger_text = ""
		return
	if not guide.has_method("point_at_world"):
		return
	# Взводим ОДИН РАЗ на текст: сам палец каждый кадр спрашивает у нас точку заново (см.
	# getter ниже), поэтому переставлять его на каждом опросе незачем — он от этого мигал бы.
	if _finger_text == text and guide.has_method("is_active") and guide.is_active():
		return
	_finger_text = text
	guide.point_at_world(func() -> Vector3:
		var h = _next_hint()
		return (h as Node3D).global_position if h != null else Vector3.ZERO,
		text, false, TutorialGuide.Gate.OFF, false)

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
		Dialogue.say("System", "Processor delivered. It goes into the middle of the line — its body sticks out to the left, and the two belts in that spot have to come out first.")
		return
	var recv: Node = _find_in_base(G.Block.RECEIVER)
	if recv == null or not _chain_reaches(recv, G.Block.PROCESSOR):
		_point_finger("Processor here: pull the two belts in the middle and drop it in their place.")
		return                          # процессор ещё не врезан в линию
	_clear_plan()
	_drop_ore_over(recv, LINE_ORE)      # и снова руда — проверить, что линия не развалилась
	Q.report(String(q["event"]), 1)

## Площадка целиком: заякоренный продавец с лентой + набор на земле рядом.
func _spawn_line_kit(at: Vector3) -> void:
	_flatten_line_site(at)
	_line_base = _spawn_station(at, [
		{"x": 5, "y": 5, "z": 5, "block": G.Block.SELLER, "rot": [0.0, 0.0, 0.0]},
		{"x": 5, "y": 5, "z": 6, "block": G.Block.BELT, "rot": [0.0, 0.0, 0.0]},
	])
	_props.ensure("arc_line", G.Block.RECEIVER, at)
	for _i in (LINE_BELTS - 1):
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
	var map: Node = get_node_or_null("/root/Main/map")
	if map == null or not map.has_method("flatten_area"):
		return
	map.flatten_area(at + Vector3(0.0, 0.0, LINE_SITE_AHEAD), LINE_SITE_HALF, at.y,
			LINE_SITE_FEATHER)

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
	v.global_position = at + Vector3.UP * 0.5
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

# ── СОБЫТИЕ «Crossfire»: чужая стычка, в которую можно вмешаться ─────────────
# Часть 1 — доехать до точки. Часть 2 — победить.
#
# Точка ставится не рядом и не за горизонтом: ровно настолько далеко, чтобы это была
# ПОЕЗДКА, а не поворот головы, и чтобы по дороге игрок успел решить, ввязываться ли.
const DUEL_DIST := 200.0
## На каком подлёте стычка начинается. Двести метров ехать в пустоту скучно; на пятидесяти
## бой уже слышно и видно, и игрок приезжает НА идущую драку, а не на пустое поле, где
## машины возникнут у него на глазах.
const DUEL_TRIGGER := 50.0
## Насколько дуэлянты стоят друг от друга.
const DUEL_GAP := 18.0
## Сколько ждать перед тем, как событие может случиться снова.
const DUEL_COOLDOWN := 420.0

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
		var wp: Vector3 = p.global_position + Vector3(cos(ang) * DUEL_DIST, 0.0, sin(ang) * DUEL_DIST)
		wp.y = G.ground_y(wp, p.global_position.y)
		_duel_point = wp
		return
	if p.global_position.distance_squared_to(_duel_point as Vector3) > DUEL_TRIGGER * DUEL_TRIGGER:
		return
	# Подъехали — стычка начинается. Фракции РАЗНЫЕ (1 и 2), иначе они друг друга не увидят:
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
	_duel_cool = DUEL_COOLDOWN
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
const EV_COOLDOWN := 420.0     # сколько остывает, прежде чем случиться снова
const EV_TRIGGER := 60.0       # на каком подлёте событие «начинается»

var _ev_point: Dictionary = {}   # id события → Vector3, куда ехать
var _ev_mobs: Dictionary = {}    # id события → Array участников
var _ev_cool: Dictionary = {}    # id события → сколько ещё остывать

## Куда ведёт компас по этому событию. ОДНА точка входа на все события с координатами:
## разбирать их по одному в компасе значило бы вспоминать про него при каждом новом.
func quest_point(ev: String) -> Variant:
	match ev:
		"quest_salvage_1": return _salvage_point
		"quest_duel_1":    return _duel_point
		"quest_line_1":    return _line_point
	return _ev_point.get(_ev_key(ev))

## Ключ события по имени его стадии: "quest_gang_1" → "gang". Точка и участники общие для
## обеих стадий, поэтому и ключ должен быть общим.
func _ev_key(ev: String) -> String:
	var s := ev.trim_prefix("quest_")
	var cut := s.rfind("_")
	return s.substr(0, cut) if cut > 0 else s

## Точка события: выбираем один раз и держим. Возвращает null, пока игрока нет.
func _ev_get_point(key: String, dist: float) -> Variant:
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

## Игрок доехал до точки события?
func _ev_reached(key: String) -> bool:
	var p: Node3D = _player()
	if p == null or not _ev_point.has(key):
		return false
	return p.global_position.distance_squared_to(_ev_point[key] as Vector3) <= EV_TRIGGER * EV_TRIGGER

## УЕХАЛ — снимаем. Возвращает true, если событие снято: вызывающий сразу выходит.
## Проверяем ТОЛЬКО когда участники уже в мире: пока их нет, «далеко» — это нормальное
## состояние только что объявленного задания.
func _ev_abandoned(q: Dictionary, key: String) -> bool:
	var p: Node3D = _player()
	if p == null or not _ev_point.has(key) or not _ev_mobs.has(key):
		return false
	if p.global_position.distance_squared_to(_ev_point[key] as Vector3) <= EV_ABANDON * EV_ABANDON:
		return false
	_ev_clear(key)
	# Остывание ставим и здесь: снятое событие обязано вернуться, иначе «уехал один раз» —
	# и этот тип задания больше не случается никогда.
	_ev_cool[String(q["id"])] = EV_COOLDOWN
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

## Событие завершено: остывает и через EV_COOLDOWN открывается снова.
func _ev_done(q: Dictionary, key: String) -> void:
	Q.report(String(q["event"]), 1)
	_ev_cool[String(q["id"])] = EV_COOLDOWN
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
		var e = sp.spawn_at(pos, int(presets[i]), faction_id)
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
const GANG_DIST := 180.0

func _gang_1(q: Dictionary) -> void:
	var key := "gang"
	if _ev_abandoned(q, key):
		return
	if _ev_get_point(key, GANG_DIST) == null or not _ev_reached(key):
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
		var at = _ev_get_point(key, GANG_DIST)      # состояние потеряно — банда снова на месте
		if at != null:
			_ev_spawn(key, at as Vector3, [5, 6, 7])
		return
	if not _ev_all_dead(key):
		return
	_ev_done(q, key)

# ── «Supply Drop»: ящик снабжения, иногда с засадой ─────────────────────────
const SUPPLY_DIST := 150.0
## Что бывает в ящике. Список короткий и намеренно полезный: событие должно быть поводом
## съездить, а не лотереей с мусором.
const SUPPLY_LOOT := [G.Block.BATTERY, G.Block.SOLAR, G.Block.BELT, G.Block.ARMOR2, G.Block.REGEN]

func _supply_1(q: Dictionary) -> void:
	var key := "supply"
	if _ev_abandoned(q, key):
		return
	if _ev_get_point(key, SUPPLY_DIST) == null or not _ev_reached(key):
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
const DEFEND_DIST := 120.0

func _defend_1(q: Dictionary) -> void:
	var key := "defend"
	if _ev_abandoned(q, key):
		return
	if _ev_get_point(key, DEFEND_DIST) == null or not _ev_reached(key):
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
		var at = _ev_get_point(key, DEFEND_DIST)
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
const CAMP_DIST := 220.0

func _camp_1(q: Dictionary) -> void:
	var key := "camp"
	if _ev_abandoned(q, key):
		return
	if _ev_get_point(key, CAMP_DIST) == null or not _ev_reached(key):
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
		var at = _ev_get_point(key, CAMP_DIST)      # состояние потеряно — охрана снова на точке
		if at != null:
			_ev_spawn(key, at as Vector3, [7, 8, 9], 1, _player())
		return
	if not _ev_all_dead(key):
		return
	if _props.position_for("event_camp") != null:
		return                                  # охрана кончилась, трофей ещё лежит
	_ev_done(q, key)
