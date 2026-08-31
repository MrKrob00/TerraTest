class_name Raids
extends Node
# РЕЙДЫ НА БАЗУ ИГРОКА. Чем больше построил — тем чаще за этим приходят.
#
# Зачем. Заякоренная база была самым безопасным местом в игре: вокруг своей стоящей машины
# спавна нет вовсе (enemy_spawner.quiet_radius — правило верное, иначе врага присылают ровно
# тогда, когда игрок раскладывает конвейер и рулём не управляет). Из этого выходило, что
# фабрику можно поставить один раз и больше про неё не думать: ни оборонять, ни защищать
# нечем и не от кого. Пушка на базе была украшением.
#
# Рейд — единственное ИСКЛЮЧЕНИЕ из тихой зоны, и поэтому он объявляется заранее: у игрока
# есть время доехать, встать и приготовиться. Внезапный налёт на фабрику, пока хозяин в двух
# километрах, наказывал бы за то, что игрок вообще решил что-то построить.
#
# Механику отбитой волны сюжет уже показывал (quest_arcs «Hold the Line»). Здесь то же самое
# становится постоянным правилом мира, а не одним заданием.

## Как часто вообще смотрим, есть ли что штурмовать.
const CHECK := 5.0
## Границы паузы между рейдами. Богатая база зовёт чаще: это и есть цена за производство.
const PERIOD_MAX := 720.0        # бедная база — раз в двенадцать минут
const PERIOD_MIN := 300.0        # развитая — раз в пять
## Стоимость базы (сумма G.shop_price её блоков), при которой пауза становится минимальной.
const VALUE_FULL := 24000.0
## Дешевле этого база не считается добычей: одна опора с продавцом — не повод присылать отряд.
const VALUE_MIN := 3000.0
## Сколько секунд между объявлением и появлением машин.
const WARN := 20.0
## Откуда приходят и сколько их.
const RING := 90.0
const SQUAD_MAX := 3
## Первая пауза после запуска мира: не встречать игрока рейдом сразу после загрузки.
const FIRST_DELAY := 240.0

var _t: float = CHECK
var _left: float = FIRST_DELAY
var _warning: float = -1.0        # идёт обратный отсчёт объявления (−1 — не идёт)
var _target: Node3D = null        # база, на которую идёт этот рейд
var _squad: Array = []

func _ready() -> void:
	add_to_group("raids")

func _process(delta: float) -> void:
	if _warning > 0.0:
		_warning -= delta
		if _warning <= 0.0:
			_launch()
		return
	_t -= delta
	if _t > 0.0:
		return
	_t = CHECK
	_tick()

func _tick() -> void:
	# Debug switch (Main → Отладка → Враги). Checked in _tick and not in _process on purpose: a
	# raid already announced has to finish its countdown, otherwise the warning hangs on screen
	# forever with nobody coming.
	if not G.debug(&"raids"):
		return
	_squad = _squad.filter(func(e): return is_instance_valid(e))
	if not _squad.is_empty():
		return                       # предыдущая волна ещё жива — второй сверху не шлём
	if get_node_or_null("/root/Q") != null and Q.tutorial_active():
		return
	var base: Node3D = _richest_base()
	if base == null:
		_left = maxf(_left, 60.0)    # базы нет — таймер не копится в ноль про запас
		return
	var value: float = _value_of(base)
	if value < VALUE_MIN:
		return
	_left -= CHECK
	if _left > 0.0:
		return
	_target = base
	_warning = WARN
	Dialogue.say("System", "Your anchor is drawing attention. Contacts inbound — %d seconds."
			% int(WARN))

func _launch() -> void:
	_warning = -1.0
	var sp: Node = get_node_or_null("/root/Main/EnemySpawner")
	if sp == null or not sp.has_method("spawn_at") or _target == null or not is_instance_valid(_target):
		_left = _period_for(0.0)
		return
	var value: float = _value_of(_target)
	var count: int = _squad_size(value)
	var preset: int = _preset_for(sp, value)
	_squad.clear()
	for i in count:
		var ang: float = TAU * float(i) / float(count) + randf()
		var wp: Vector3 = _target.global_position + Vector3(cos(ang) * RING, 0.0, sin(ang) * RING)
		wp.y = G.ground_y(wp, _target.global_position.y)
		var e = sp.spawn_at(wp, preset, 1)
		if e == null:
			continue
		# ЦЕЛЬ — САМА БАЗА, и её не бросают: рейд идёт ломать постройку, а не патрулировать
		# рядом. Без назначенной цели машины ехали бы к ближайшему, кого увидят, то есть
		# зачастую мимо — и «налёт на базу» превращался бы в обычную встречу в поле.
		if e.has_method("assign_target"):
			e.assign_target(_target, true)
		_squad.append(e)
	_left = _period_for(value)

## Сколько ждать до следующего рейда: чем дороже база, тем короче пауза.
func _period_for(value: float) -> float:
	var t: float = clampf((value - VALUE_MIN) / maxf(VALUE_FULL - VALUE_MIN, 1.0), 0.0, 1.0)
	return lerpf(PERIOD_MAX, PERIOD_MIN, t)

func _squad_size(value: float) -> int:
	var t: float = clampf((value - VALUE_MIN) / maxf(VALUE_FULL - VALUE_MIN, 1.0), 0.0, 1.0)
	return clampi(1 + int(round(t * float(SQUAD_MAX - 1))), 1, SQUAD_MAX)

## Сборка нападающих — по тем же ступеням, что и обычные враги (спавнер их и экспортирует).
## Второй такой таблицы заводить нельзя: она разъедется с первой при первой же правке баланса.
func _preset_for(sp: Node, value: float) -> int:
	var tiers: Array = sp.get("preset_tiers") if ("preset_tiers" in sp) else []
	var from: Array = sp.get("tier_from_value") if ("tier_from_value" in sp) else []
	if tiers.is_empty():
		return 7
	var tier: int = 0
	for i in mini(tiers.size(), from.size()):
		if value >= float(from[i]):
			tier = i
	return int(tiers[tier])

# ── Что считается базой ──────────────────────────────────────────────────────
## Самая дорогая ЗАЯКОРЕННАЯ машина игрока. Именно якорь, а не флаг станции: фабрика на
## колёсах, вставшая на опору, работает так же и защищать её надо так же.
func _richest_base() -> Node3D:
	var cc: Node = get_tree().get_first_node_in_group("camera_controller")
	if cc == null or not ("vehicles" in cc):
		return null
	var best: Node3D = null
	var best_v: float = 0.0
	for v in cc.vehicles:
		if v == null or not is_instance_valid(v) or not (v is Node3D):
			continue
		if v.get("anchored") != true and v.get("is_station") != true:
			continue
		var val: float = _value_of(v as Node3D)
		if val > best_v:
			best_v = val
			best = v as Node3D
	return best

## Во сколько обходится постройка — та же мерка, что у машины врага и в гараже (G.shop_price).
func _value_of(machine: Node3D) -> float:
	var blocks: Node = machine.get_node_or_null("blocks")
	if blocks == null:
		return 0.0
	var v: float = 0.0
	for b in blocks.get_children():
		if "block" in b:
			v += float(G.shop_price(int(b.get("block"))))
	return v
