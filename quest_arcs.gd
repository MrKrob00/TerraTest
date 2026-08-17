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
	_props = QuestProps.new()
	add_child(_props)

func _process(delta: float) -> void:
	_t -= delta
	if _t > 0.0:
		return
	_t = POLL
	if get_node_or_null("/root/Q") == null:
		return
	for q in Q.active_quests():
		match String(q.get("event", "")):
			"quest_arc_power_1":   _arc_power_1(q)
			"quest_arc_power_2":   _arc_power_2(q)
			"quest_arc_radar_1":   _arc_radar_1(q)
			"quest_arc_radar_2":   _arc_radar_2(q)
			"quest_arc_battery_1": _arc_battery_1(q)
			"quest_arc_battery_2": _arc_battery_2(q)

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
