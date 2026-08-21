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
	_t -= delta
	if _t > 0.0:
		return
	_t = POLL
	if get_node_or_null("/root/Q") == null:
		return
	_duel_cooldown(POLL)
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

# ── Ветка «энергия»: солнечная панель + опора, затем реген ───────────────────
func _arc_power_1(q: Dictionary) -> void:
	var key := "power_1"
	if not _dropped.has(key):
		_dropped[key] = true
		# ОБА предмета под одним id квеста: компас спрашивает именно его, и под ключом
		# «arc_power+» опора оставалась без метки — лежала где-то в стороне, и выглядело
		# это как «якорь не выдали вовсе».
		_props.drop_for("arc_power", G.Block.SOLAR)
		_props.drop_for("arc_power", G.Block.SUPPORT)
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
	var key := "radar_1"
	if not _dropped.has(key):
		_dropped[key] = true
		_props.drop_for("arc_radar", G.Block.RADAR)
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
	var key := "battery_1"
	if not _dropped.has(key):
		_dropped[key] = true
		_props.drop_for("arc_battery", G.Block.BATTERY)
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
	var sp: Node = get_node_or_null("/root/Main/EnemySpawner")
	if sp != null and sp.has_method("spawn_at") and not is_instance_valid(_salvage_guard):
		_salvage_guard = sp.spawn_at(_salvage_point as Vector3 + Vector3(12.0, 0.0, 0.0), 7, 1)
		if _salvage_guard != null and _salvage_guard.has_method("assign_target"):
			_salvage_guard.assign_target(p, true)
	Q.report(String(q["event"]), 1)

func _salvage_2(q: Dictionary) -> void:
	if is_instance_valid(_salvage_guard):
		return
	# Охрана кончилась — груз наш. Коллектор кладём В МИР рядом с точкой, а не молча в
	# инвентарь: игрок должен его увидеть и подобрать, как любой трофей.
	if not _dropped.has("salvage"):
		_dropped["salvage"] = true
		_props.drop_near("arc_salvage", G.Block.COLLECTOR, _salvage_point)
		return                              # даём кадр, чтобы предмет появился
	if _has_block(G.Block.COLLECTOR):
		Q.report(String(q["event"]), 1)
		_salvage_point = null

# ── «Production Line»: собрать цепочку и включить её ─────────────────────────
# Условие — НАБОР БЛОКОВ НА МАШИНЕ плюс якорь, а не «поставь пять блоков»: цепочка либо есть
# целиком, либо не работает вовсе (_factory_active у всех фабричных блоков смотрит на якорь).
const LINE_CORE := [G.Block.COLLECTOR, G.Block.RECEIVER, G.Block.BELT, G.Block.PROCESSOR]

func _line_1(q: Dictionary) -> void:
	for bt in LINE_CORE:
		if not _has_block(int(bt)):
			return
	Q.report(String(q["event"]), 1)

func _line_2(q: Dictionary) -> void:
	if not _has_block(G.Block.SELLER) or not _is_anchored():
		return
	Q.report(String(q["event"]), 1)

# ── «Hold the Line»: налёт на СВОЮ базу ──────────────────────────────────────
# В оригинале это турели у чужой станции. Станций у нас нет, поэтому защищаем то, что игрок
# построил сам, — и защищать приходится СТОЯ: заякоренная машина уехать не может.
const HOLD_COUNT := 2
const HOLD_RANGE := 70.0

var _hold: Array = []

func _hold_1(q: Dictionary) -> void:
	if not _is_anchored():
		return                              # ждём, пока игрок встанет: налёт идёт на базу
	var p: Node3D = _player()
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
