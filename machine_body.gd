class_name MachineBody
extends RigidBody3D

# Общая физика езды: одна реализация для машины игрока и для машин врагов.
# Раньше это были две дословные копии в vehicle_body_3d.gd и enemy_vehicle.gd, и любая
# правка приезжала только в одну из них.
#
# Что оставлено наследникам: ввод (джойстик у игрока, ИИ у врага), оружие, постройка,
# смерть. Наследник заполняет _throttle и _steer_angle, а дальше зовёт готовые шаги:
#   sense_ground(delta)    — контакт колёс с землёй, масса, центр масс
#   drive_physics(delta)   — тяга, сцепление, поворот, стабилизация, лимит скорости
#   push_drive_input(steer) — раздать газ и руль колёсным блокам (визуал вращения)
#
# Точки переопределения: _speed_cap() и _blocks_root().

@export_group("Двигатель")
## Общий множитель тяги. Сама тяга берётся из колёс (Wheel.wheel_power), это лишь
## ручка для настройки всей машины разом: ускорение = engine_force * Σтяга / масса.
@export var engine_force: float = 1.0
## Собственная тяга ГОЛОЙ кабины — когда на ней нет ни одного навесного блока.
## Нужна, чтобы в начале игры доползти до блоков, лежащих рядом. Стоит навесить хоть
## что-то — тяга пропадает, и машина не поедет, пока на неё не поставят колёса.
@export var chassis_power: float = 1100.0
@export var max_speed: float = 20.0
@export var engine_brake: float = 0.3

@export_group("Тормоза")
@export var brake_power: float = 4.0

@export_group("Поворот")
@export var steer_max_angle: float = 45.0
@export var steer_speed: float = 10.0
@export var turn_response: float = 4.0
@export var speed_steer_reduction: float = 0.5
## Ниже этой скорости руль отпускается. У ИИ порог выше — иначе враг дёргает рулём,
## почти остановившись.
@export var steer_min_speed: float = 0.05

@export_group("Сцепление шин")
@export var lateral_grip: float = 8.0
@export var longitudinal_grip: float = 0.3

@export_group("Стабилизация")
@export var anti_roll: float = 6.0
@export var upright_strength: float = 12.0
## Доля гашения крена, работающая в воздухе. Без контакта колёс демпфировать нечем,
## но полностью отключать нельзя — иначе машина после трамплина крутится неуправляемо.
@export_range(0.0, 1.0) var air_stability: float = 0.35

@export_group("Масса и физика")
@export var base_weight: float = 40.0
@export var gravity_mult: float = 2.5
## Насколько центр масс опущен ниже оси колёс. Низкий центр масс — то, чем реальные
## машины держатся от переворота; заодно тяга перестаёт создавать опрокидывающий момент.
@export var com_drop: float = 0.40

var Wheels: Array = []
var _steer_angle: float = 0.0
var _throttle: float = 0.0
var _on_ground: bool = false

var _ground_q: PhysicsRayQueryParameters3D = null
var _grounded_wheels: int = 0
var _wheel_count: int = 0

var _mass_wheels_n: int = -1
var _mass_timer: float = 0.0
var _drive_cache: Array = []
var _drive_n: int = -1

# Низ машины в локальных координатах (отрицательный) — нужен проверке земли без колёс.
var _body_drop: float = -0.5
# Сколько на машине блоков помимо кабины. 0 = голая кабина, ей разрешено ползти самой.
var _extra_blocks: int = 0
var _wheelbase: float = 2.0

# ══════════════════════════════════════════
# НАГРУЖЕННОСТЬ (для гаража)
# ══════════════════════════════════════════

# Пороги заданы через УСКОРЕНИЕ, а не через массу: сколько машина утащит, зависит от её
# же тяги, поэтому «предела в килограммах» как константы не существует — он растёт вместе
# с колёсами. Время выхода на максималку ≈ max_speed / ускорение (демпфирования у тела
# нет, linear_damp обнуляется в _ready). 25 м/с² — это ~0.8 с, отклик сразу; 10 м/с² —
# 2 с, уже тяжело; ниже 10 игрок считает машину неподвижной.
const ACCEL_BRISK: float = 25.0
const ACCEL_CRAWL: float = 10.0

## Паспортная тяга: то же, что _drive_power, но без требования касаться земли —
## в гараже машина висит в воздухе, а знать её возможности всё равно нужно.
func rated_power() -> float:
	var power: float = 0.0
	for w in Wheels:
		if is_instance_valid(w) and w.is_drive:
			power += w.wheel_power
	if _extra_blocks == 0:
		power += chassis_power
	return power * engine_force

## До какой массы машина остаётся бодрой.
func mass_comfort() -> float:
	return rated_power() / ACCEL_BRISK

## Предельная масса, которую эта сборка ещё стронет с места.
func mass_limit() -> float:
	return rated_power() / ACCEL_CRAWL

# ── ЭНЕРГОСИСТЕМА (общая для игрока и врага) ──────────────────────────────────
# Живёт ЗДЕСЬ, а не у игрока, ровно по правилу «главной ловушки»: щит, реген и солнечная
# панель спрашивают энергию у своей машины, и пока система была только в vehicle_body_3d,
# на вражеской постройке все три висели мёртвым грузом — блок есть, а работать ему не с чем.
# _tick_prod — энергия, произведённая В ЭТОМ тике (солнечные/генератор): потребители
# (реген/щит) едят СНАЧАЛА её, потом запас. Остаток в начале следующего тика утекает в
# аккумуляторы; если аккумуляторов нет — сгорает. Так «без аккума работает, но не больше,
# чем производится» получается само собой.
#
# ЗАПАС ЛЕЖИТ В САМИХ АККУМУЛЯТОРАХ (blocks/scripts/battery.gd), а машина только складывает
# их и раздаёт по ним. Пока запас был одним числом машины, снятый и возвращённый аккумулятор
# приходил пустым: ёмкость возвращалась, а заряд машина уже потеряла — заряженную батарею
# нельзя было ни отложить, ни перенести на другую машину.
#
# _energy — то, что аккумуляторами НЕ хранится: буфер солнечных панелей под якорем. Он живёт
# у машины, потому что и появляется от неё (якорь), и исчезает вместе с ним.
const BATTERY_CAP := 100.0        # запасная ёмкость для блока без своей (старые сцены)
## СОБСТВЕННОГО ЗАПАСА У МАШИНЫ НЕТ. Ёмкость даёт только то, что для неё поставлено:
## аккумулятор — постоянно, солнечная панель — ПОКА МАШИНА НА ЯКОРЕ, и ровно столько,
## сколько панель вырабатывает за секунду. Съехал с якоря — этот буфер исчезает вместе с
## выработкой, и остаётся то, что реально хранит аккумулятор.
##
## Так честнее прежних «двадцати пяти из воздуха»: запас перестал быть свойством самого
## факта существования машины и стал следствием того, что на ней стоит.
const BASE_ENERGY_CAP := 0.0
const SOLAR_RATE := 6.0          # энергии в секунду с одной панели (только на якоре)
var _energy: float = 0.0
var _tick_prod: float = 0.0
var _energy_cap: float = 0.0
var _battery_cap: float = 0.0        # часть ёмкости от аккумуляторов (считается раз в секунду)
var _cap_timer: float = 0.0
var _solar_count: int = 0            # кеш числа солнечных блоков (обновляется вместе с _cap_timer)

func energy_cap() -> float:
	return _energy_cap

func energy_stored() -> float:
	return _energy + _bat_stored()

# Доля заполнения аккумуляторов для HUD (0..1). Нет аккумуляторов — 0.
func energy_fill() -> float:
	return energy_stored() / _energy_cap if _energy_cap > 0.0 else 0.0

# Есть ли сейчас хоть какая-то энергия (запас или свежая выработка).
func energy_available() -> float:
	return energy_stored() + _tick_prod

# Источники (солнечная, генератор) добавляют выработку сюда.
func energy_produce(amount: float) -> void:
	_tick_prod += amount

# Потребители (реген/щит) просят энергию; возвращается сколько реально выдано.
# Порядок трат: свежая выработка → солнечный буфер → аккумуляторы. Сначала тратится то, что
# всё равно пропадёт (выработка этого тика и буфер, который исчезнет со снятием якоря).
func energy_consume(amount: float) -> float:
	var given: float = 0.0
	var from_prod: float = minf(amount, _tick_prod)
	_tick_prod -= from_prod
	given += from_prod
	var from_buf: float = minf(amount - given, _energy)
	_energy -= from_buf
	given += from_buf
	given += _bat_take(amount - given)
	return given

## ── Аккумуляторы как хранилища ───────────────────────────────────────────────
## Кеш узлов: перебирать сборку на каждый глоток энергии нельзя — energy_consume зовут
## реген, щит, шахтёр и фабрика, каждый в свой тик. Список обновляется там же, где считается
## ёмкость (раз в полсекунды), и там же чистится от освобождённых узлов.
var _batteries: Array = []

func _bat_stored() -> float:
	var s: float = 0.0
	for b in _batteries:
		if is_instance_valid(b):
			s += float(b.get("charge"))
	return s

## Долить по блокам. Возвращает, сколько НЕ влезло (это и сгорит, если некуда).
func _bat_add(amount: float) -> float:
	var left: float = amount
	for b in _batteries:
		if left <= 0.0:
			break
		if is_instance_valid(b) and b.has_method("charge_add"):
			left = b.charge_add(left)
	return left

## Взять по блокам. Возвращает, сколько реально удалось взять.
func _bat_take(amount: float) -> float:
	var need: float = amount
	var got: float = 0.0
	for b in _batteries:
		if need <= 0.001:
			break
		if is_instance_valid(b) and b.has_method("charge_take"):
			var g: float = b.charge_take(need)
			got += g
			need -= g
	return got

# Тик энергии: остаток прошлого тика → в аккумуляторы (без них сгорает), пересчёт
# ёмкости (раз в 0.5с), выработка солнечных панелей (только на якоре).
func _energy_tick(delta: float) -> void:
	# Непотраченная выработка сперва заряжает АККУМУЛЯТОРЫ (там она хранится долго), и только
	# остаток ложится в солнечный буфер, который исчезнет вместе с якорем.
	_energy = minf(_energy + _bat_add(_tick_prod), _solar_buf_cap())
	_tick_prod = 0.0
	_cap_timer -= delta
	if _cap_timer <= 0.0:
		_cap_timer = 0.5
		var anchors := 0
		_solar_count = 0
		_batteries.clear()
		_battery_cap = BASE_ENERGY_CAP
		var bl: Node = _blocks_root()
		if bl != null:
			for b in bl.get_children():
				var bt = b.get("block")
				if bt == G.Block.BATTERY:
					_batteries.append(b)
					# Ёмкость спрашиваем У БЛОКА: она его свойство (battery.gd), а BATTERY_CAP
					# здесь только запасной ответ для сцен, где скрипта аккумулятора ещё нет.
					var cap = b.get("capacity")
					_battery_cap += float(cap) if cap != null else BATTERY_CAP
				elif bt == G.Block.SOLAR:
					_solar_count += 1
				# Чем машина держится на якоре: фикс-опора ИЛИ любой стационарный блок —
				# ровно то, что разрешало якорь в can_anchor().
				if bt != null and (int(bt) in [G.Block.SUPPORT, G.Block.ROT_SUPPORT] or G.is_stationary(int(bt))):
					anchors += 1
		# Что делать, если опор не осталось, решает НАСЛЕДНИК: у игрока машина падает с якоря,
		# а вражеской базе падать неоткуда. Считаем опоры здесь, потому что это тот же обход
		# блоков, и второй такой ради одного числа заводить незачем.
		_after_power_scan(anchors)
	# Ёмкость пересчитываем КАЖДЫЙ тик, а не раз в секунду вместе с блоками: она зависит от
	# якоря, а якорь снимают мгновенно, и буфер обязан пропасть тогда же.
	_energy_cap = _battery_cap + _solar_buf_cap()
	_energy = minf(_energy, _solar_buf_cap())
	if power_anchored() and _solar_count > 0:
		energy_produce(_solar_count * SOLAR_RATE * delta)

## Буфер солнечных панелей: он есть ТОЛЬКО под якорем и равен их секундной выработке.
## Аккумуляторы к нему отношения не имеют — их запас снятие якоря не трогает.
func _solar_buf_cap() -> float:
	return _solar_count * SOLAR_RATE if power_anchored() else 0.0

## Стоит ли машина так, что панели работают. У ВРАГА-базы ответ всегда «да»: она заякорена
## по своей природе и снять якорь ей нечем. Игрок переопределяет это своим полем anchored.
func power_anchored() -> bool:
	return true

## Крючок после пересчёта блоков: сколько на машине опор (SUPPORT/стационарных). Базе всё
## равно, игроку — нет (см. vehicle_body_3d).
func _after_power_scan(_anchors: int) -> void:
	pass

# ── Общие показатели машины ───────────────────────────────────────────────────
# Живут здесь, а не у врага, потому что описывают ЛЮБУЮ машину: ИИ по ним решает,
# стоит ли драться, а гараж их же показывает игроку. Считаются в одном месте, значит
# панель не может разойтись с тем, что видит ИИ.

## Текущий и максимальный HP всех блоков.
func hp_totals() -> Vector2i:
	var bl: Node = _blocks_root()
	if bl == null:
		return Vector2i(1, 1)
	var cur: int = 0
	var mx: int = 0
	for b in bl.get_children():
		if b is VehicleBlock:
			cur += (b as VehicleBlock).current_hp
			mx += (b as VehicleBlock).max_hp
	return Vector2i(cur, maxi(mx, 1))

func health_ratio() -> float:
	var hp: Vector2i = hp_totals()
	return clampf(float(hp.x) / float(hp.y), 0.0, 1.0)

## Грубый урон в секунду всех орудий — для сравнения «кто кого перестреляет».
func firepower() -> float:
	var bl: Node = _blocks_root()
	if bl == null:
		return 0.0
	var p: float = 0.0
	for b in bl.get_children():
		var dmg: Variant = b.get("damage")
		var rate: Variant = b.get("fire_rate")
		if dmg != null and rate != null and float(rate) > 0.001:
			p += float(dmg) / float(rate)
	return p

## Сколько на машине колёс: x — всего, y — ведущих.
func wheel_counts() -> Vector2i:
	var total: int = 0
	var driven: int = 0
	for w in Wheels:
		if is_instance_valid(w):
			total += 1
			if w.is_drive:
				driven += 1
	return Vector2i(total, driven)

## Пересчитать массу и центр масс немедленно. Нужно гаражу: у неактивной машины
## _physics_process выходит досрочно, и _sync_mass там не вызывается — без этого
## панель показывала бы данные на момент последней поездки.
func refresh_mass() -> void:
	_mass_timer = 0.0
	_mass_wheels_n = -1
	_sync_mass()

# ══════════════════════════════════════════
# ТОЧКИ ПЕРЕОПРЕДЕЛЕНИЯ
# ══════════════════════════════════════════

# Потолок скорости. Врагу в погоне нужен запас, иначе догнать убегающего математически
# невозможно — у него тот же max_speed.
func _speed_cap() -> float:
	return max_speed

# Узел, под которым висят блоки машины.
func _blocks_root() -> Node:
	return get_node_or_null("blocks")

# ══════════════════════════════════════════
# ИНИЦИАЛИЗАЦИЯ
# ══════════════════════════════════════════

## Трение корпуса о рельеф. Задаём ЯВНО: от него напрямую зависит, тронется ли машина
## с места, и оставлять здесь молчаливое умолчание движка нельзя.
const GROUND_FRICTION: float = 0.35

func init_machine_physics() -> void:
	gravity_scale = gravity_mult
	var mat := PhysicsMaterial.new()
	mat.friction = GROUND_FRICTION
	physics_material_override = mat

# Эффективное ускорение свободного падения с учётом gravity_scale.
func _gravity_accel() -> float:
	return float(ProjectSettings.get_setting("physics/3d/default_gravity", 9.8)) * gravity_scale

# Сила сопротивления качению, которую двигатель обязан перебить, прежде чем машина
# вообще стронется. Коэффициент берём как корень из своего трения: движок сводит
# трение двух тел, а у рельефа материал не задан (то есть 1.0), и при усреднении по
# среднему геометрическому получается sqrt(нашего). Это ПЕССИМИСТИЧНАЯ оценка — если
# правило сведения окажется другим, мы скомпенсируем с запасом, а не недодадим.
func _rolling_drag() -> float:
	return sqrt(GROUND_FRICTION) * mass * _gravity_accel()

func append_wheel(wheel: Node) -> void:
	if !Wheels.has(wheel):
		Wheels.append(wheel)

func erase_wheel(wheel: Node) -> void:
	Wheels.erase(wheel)

# ══════════════════════════════════════════
# ШАГИ ФИЗИЧЕСКОГО КАДРА
# ══════════════════════════════════════════

func sense_ground(delta: float) -> void:
	_check_ground()
	_sync_mass(delta)

func drive_physics(delta: float) -> void:
	_apply_suspension()
	if _on_ground:
		_apply_engine()
		_apply_grip()
		_apply_steering(delta)
	# Крен гасим и в воздухе, но слабее: без контакта колёс демпфировать физически
	# нечем, а полностью отпустив машину, получаем неуправляемое вращение после трамплина.
	_apply_anti_roll(delta, 1.0 if _on_ground else air_stability)
	_apply_upright(delta)
	_limit_speed()

# ══════════════════════════════════════════
# ПОДВЕСКА
# ══════════════════════════════════════════
# Колёса ПРИПОДНИМАЮТ кузов на свой радиус, поэтому днище не чиркает по земле, а большое
# колесо само даёт больший клиренс — ride_height у него больше.
#
# Пружина ДОБАВОЧНАЯ: коллизии блоков (в том числе самих колёс) никуда не делись и остаются
# полом на случай, если её не хватит. Так худший исход при плохой настройке — сегодняшнее
# поведение, а не машина, провалившаяся сквозь мир.
#
# Жёсткость не константа, а считается от нагрузки: пружина обязана держать mass*g, делённую
# на число колёс, просев на SUSP_SAG своего хода. Иначе гружёная машина ложилась бы на днище,
# а пустая скакала бы на тех же числах.
## Какую долю радиуса подвеска проседает под собственным весом машины в покое.
const SUSP_SAG: float = 0.35
## Демпфирование как доля от критического: 1.0 — без единого качка, меньше — мягче и живее.
const SUSP_DAMP: float = 0.75

func _apply_suspension() -> void:
	if _wheel_count <= 0:
		return
	var load_per: float = mass * _gravity_accel() / float(_wheel_count)
	var up: Vector3 = global_transform.basis.y
	for w in Wheels:
		if not is_instance_valid(w) or not w.grounded:
			continue
		if w.ride_height <= 0.0:
			continue                        # подвеска выключена (верхнее колесо смотрит вверх)
		var sag: float = w.suspension_sag()
		if sag <= 0.0:
			continue                        # колесо вывешено — держать нечего
		# k подобрана так, чтобы в покое просело ровно SUSP_SAG хода.
		var travel: float = maxf(w.suspension_travel, 0.01)
		var k: float = load_per / (travel * SUSP_SAG)
		# Скорость точки крепления вдоль вертикали — её и гасим.
		var arm: Vector3 = w.global_position - global_position
		var vel_at: Vector3 = linear_velocity + angular_velocity.cross(arm)
		var c: float = 2.0 * SUSP_DAMP * sqrt(k * maxf(mass / float(_wheel_count), 0.001))
		var force: float = k * sag - c * vel_at.dot(up)
		if force <= 0.0:
			continue                        # тянуть кузов ВНИЗ подвеска не должна
		apply_force(up * force, arm)

# Газ и руль уходят в колёсные блоки — они от этого крутятся и поворачиваются визуально.
func push_drive_input(steer_norm: float) -> void:
	for block in _drive_blocks():
		if not is_instance_valid(block):
			_drive_n = -1               # блок уничтожили — заставляем пересобрать кеш
			continue
		block.set_throttle(_throttle)
		block.set_steer(steer_norm)

# Блоки, принимающие газ/руль (колёса). Кеш инвалидируется по числу детей блок-узла.
func _drive_blocks() -> Array:
	var bl: Node = _blocks_root()
	if bl == null:
		return []
	if bl.get_child_count() != _drive_n:
		_drive_n = bl.get_child_count()
		_drive_cache.clear()
		for b in bl.get_children():
			if b.has_method("set_throttle") and b.has_method("set_steer"):
				_drive_cache.append(b)
	return _drive_cache

# ══════════════════════════════════════════
# КОНТАКТ С ЗЕМЛЁЙ
# ══════════════════════════════════════════

# Землю щупает КАЖДОЕ колесо у себя под собой. Прежний вариант — один луч из центра
# корпуса на 1.4 — ломался, как только машина становилась выше кабины: центр уезжал
# вверх вместе с постройкой, луч переставал доставать, и вместе с `_on_ground`
# отключались разом тяга, сцепление и поворот. Колёса же всегда там, где контакт.
func _check_ground() -> void:
	var space: PhysicsDirectSpaceState3D = get_world_3d().direct_space_state
	if _ground_q == null:
		_ground_q = PhysicsRayQueryParameters3D.new()
		_ground_q.exclude = [get_rid()]     # RID, не узел; состав не меняется — задаём один раз
		_ground_q.collision_mask = 1

	_grounded_wheels = 0
	_wheel_count = 0
	for w in Wheels:
		if not is_instance_valid(w):
			continue
		_wheel_count += 1
		if w.probe_ground(space, _ground_q):
			_grounded_wheels += 1

	if _wheel_count > 0:
		_on_ground = _grounded_wheels > 0
		return

	# Колёс нет (сбили все, или это стационарная база) — щупаем от НИЗА машины,
	# а не от центра, чтобы длина луча не зависела от высоты постройки.
	_ground_q.from = global_position + global_transform.basis.y * _body_drop
	_ground_q.to = _ground_q.from + Vector3.DOWN * 0.5
	_on_ground = not space.intersect_ray(_ground_q).is_empty()

# Доля колёс на земле: 1.0 — вся машина в контакте, 0.25 — висит на одном колесе.
# Без колёс возвращаем 1.0, иначе стационарные постройки лишились бы сцепления.
func _contact_ratio() -> float:
	if _wheel_count <= 0:
		return 1.0
	return float(_grounded_wheels) / float(_wheel_count)

# ══════════════════════════════════════════
# МАССА, ЦЕНТР МАСС, ГЕОМЕТРИЯ КОЛЁС
# ══════════════════════════════════════════

# Пересчитывает массу, центр масс, низ корпуса и оси за один проход по блокам.
# Массу дают ВСЕ блоки, а не только колёса: иначе постройка не влияла бы ни на разгон,
# ни на инерцию, и сборка машины ничего не решала.
func _sync_mass(delta: float = 0.0) -> void:
	_mass_timer -= delta
	if Wheels.size() == _mass_wheels_n and _mass_timer > 0.0:
		return
	_mass_wheels_n = Wheels.size()
	_mass_timer = 0.5

	var total: float = base_weight
	var sum_x: float = 0.0
	var sum_z: float = 0.0
	var lowest: float = -0.5
	var extra: int = 0
	var bl: Node = _blocks_root()
	if bl != null:
		for b in bl.get_children():
			if not b.has_method("get_weight"):
				continue
			var w: float = b.get_weight()
			total += w
			sum_x += b.position.x * w
			sum_z += b.position.z * w
			lowest = minf(lowest, b.position.y - 0.5)
			if int(b.block) != G.Block.CABIN:
				extra += 1
	mass = total
	_body_drop = lowest
	_extra_blocks = extra

	# Центр масс опускаем ниже оси колёс. Это не подкрутка «чтобы не падало», а то же
	# самое, чем реальные машины держатся от переворота: чем ниже центр масс над пятном
	# контакта, тем больший угол крена нужен, чтобы вертикаль вышла за опору. Побочно
	# исчезает опрокидывающий момент от тяги — apply_central_force бьёт в центр масс,
	# и пока он был высоко, разгон подкидывал нос.
	var axle_y: float = 0.0
	var sum_z_w: float = 0.0
	var min_z: float = INF
	var max_z: float = -INF
	var n: int = 0
	for wheel in Wheels:
		if is_instance_valid(wheel):
			axle_y += wheel.position.y
			sum_z_w += wheel.position.z
			min_z = minf(min_z, wheel.position.z)
			max_z = maxf(max_z, wheel.position.z)
			n += 1
	if n > 0:
		axle_y /= float(n)
		_update_axles(sum_z_w / float(n), min_z, max_z)
	else:
		axle_y = lowest + 0.5
		_wheelbase = 2.0

	# Делим на ПОЛНУЮ массу: base_weight — это шасси, оно лежит в начале координат и
	# тянет центр масс к середине. Без него несимметричная постройка смещала бы центр
	# сильнее, чем есть на самом деле.
	center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
	center_of_mass = Vector3(sum_x / total, axle_y - com_drop, sum_z / total)

# Кто передний, а кто задний, определяется РАСПОЛОЖЕНИЕМ колёс, а не флагом is_front:
# этот флаг нигде не выставлялся и у всех колёс оставался true, из-за чего база всегда
# была заглушкой 2.0, и длина машины никак не влияла на радиус поворота.
# Вперёд у нас -Z (см. _get_forward), поэтому переднее колесо — то, у которого z меньше.
func _update_axles(mid_z: float, min_z: float, max_z: float) -> void:
	var spread: float = max_z - min_z
	_wheelbase = maxf(spread, 0.5)
	# Колёса в один ряд — руль отдаём всем, иначе поворачивать было бы нечем.
	var single_row: bool = spread < 0.5
	for w in Wheels:
		if is_instance_valid(w):
			w.is_front = single_row or w.position.z < mid_z

func _get_wheelbase() -> float:
	return _wheelbase

# ══════════════════════════════════════════
# ТЯГА
# ══════════════════════════════════════════

# Суммарная тяга ведущих колёс, СТОЯЩИХ на земле. Колесо в воздухе не толкает.
func _drive_power() -> float:
	var power: float = 0.0
	for w in Wheels:
		if is_instance_valid(w) and w.is_drive and w.grounded:
			power += w.wheel_power
	# Своим ходом ползёт ТОЛЬКО голая кабина. Навесил хоть один блок — теперь это
	# машина, и она обязана стоять на колёсах, иначе никуда не поедет.
	if _extra_blocks == 0:
		power += chassis_power
	return power

func _apply_engine() -> void:
	var fwd: Vector3 = _get_forward()
	var vel_fwd: float = fwd.dot(linear_velocity)

	# Раньше сила умножалась на массу, из-за чего масса сокращалась и ускорение выходило
	# постоянным: машина из пяти блоков и из ста разгонялись одинаково, а лишние колёса
	# не давали ничего. Теперь сила — это сумма тяги колёс, а ускорение получается
	# делением на массу самим физдвижком, как в жизни.
	var power: float = _drive_power()
	if abs(_throttle) > 0.01 and power > 0.0:
		var speed_factor: float = clamp(1.0 - abs(vel_fwd) / max_speed, 0.05, 1.0)
		# Двигатель отдельно перебивает СОБСТВЕННОЕ сопротивление качению, а Σтяга колёс
		# остаётся чистым избытком на разгон. Без этого тяга конкурировала с трением,
		# которое растёт с массой: при 296 кг трение (~7250 Н) почти в точности равнялось
		# тяге четырёх колёс, и машина стояла, хотя расчёт обещал 24 м/с². Старая модель
		# этой беды не знала лишь потому, что умножала тягу на массу и трение сокращалось.
		# Теперь ускорение действительно равно Σтяга / масса — ровно то, что в гараже.
		var surplus: float = power * engine_force * speed_factor
		apply_central_force(fwd * _throttle * (surplus + _rolling_drag()))
	elif abs(vel_fwd) > 0.1:
		apply_central_force(-fwd * vel_fwd * engine_brake * mass)   # накат

# ══════════════════════════════════════════
# СЦЕПЛЕНИЕ
# ══════════════════════════════════════════

func _apply_grip() -> void:
	var right: Vector3 = _get_right()
	var fwd: Vector3 = _get_forward()
	# Держит машину ровно столько колёс, сколько реально касается земли: повиснув на
	# двух колёсах из шести, машина должна скользить, а не ехать как по рельсам.
	var contact: float = _contact_ratio()

	var vel_lat: float = right.dot(linear_velocity)
	apply_central_force(-right * vel_lat * lateral_grip * mass * contact)

	var vel_fwd: float = fwd.dot(linear_velocity)
	if abs(_throttle) < 0.01 and abs(vel_fwd) > 0.05:
		apply_central_force(-fwd * vel_fwd * longitudinal_grip * mass * contact)

# ══════════════════════════════════════════
# ПОВОРОТ (формула Аккермана через angular_velocity)
# ══════════════════════════════════════════

func _apply_steering(delta: float) -> void:
	var fwd: Vector3 = _get_forward()
	var vel_fwd: float = fwd.dot(linear_velocity)

	if abs(vel_fwd) < steer_min_speed:
		angular_velocity.y = lerp(angular_velocity.y, 0.0, 10.0 * delta)
		return

	var wheelbase: float = _get_wheelbase()
	var target_yaw: float = 0.0
	if abs(_steer_angle) > 0.001 and wheelbase > 0.1:
		target_yaw = vel_fwd * tan(_steer_angle) / wheelbase
		if vel_fwd < 0:
			target_yaw = -target_yaw

	angular_velocity.y = lerp(angular_velocity.y, target_yaw, turn_response * delta)

# ══════════════════════════════════════════
# СТАБИЛИЗАЦИЯ
# ══════════════════════════════════════════

func _apply_anti_roll(delta: float, scale: float = 1.0) -> void:
	var local_av: Vector3 = global_transform.basis.inverse() * angular_velocity
	var correction: Vector3 = global_transform.basis * Vector3(
		-local_av.x * anti_roll,
		0.0,
		-local_av.z * anti_roll
	)
	apply_torque(correction * mass * delta * scale)

func _apply_upright(delta: float) -> void:
	var up: Vector3 = _get_up()
	var dot: float = up.dot(Vector3.UP)
	if dot >= 0.85:
		return
	var axis: Vector3 = up.cross(Vector3.UP)
	if axis.length_squared() < 0.0001:
		return
	axis = axis.normalized()
	var angle: float = acos(clamp(dot, -1.0, 1.0))
	apply_torque(axis * angle * upright_strength * mass * delta)

func _limit_speed() -> void:
	var fwd: Vector3 = _get_forward()
	var vel_fwd: float = fwd.dot(linear_velocity)
	var cap: float = _speed_cap()
	if abs(vel_fwd) > cap:
		linear_velocity -= fwd * (vel_fwd - sign(vel_fwd) * cap)
	if linear_velocity.y > 10.0:
		linear_velocity.y = 10.0

# ══════════════════════════════════════════
# ОСИ МАШИНЫ
# ══════════════════════════════════════════

func _get_forward() -> Vector3:
	return -global_transform.basis.z

func _get_right() -> Vector3:
	return global_transform.basis.x

func _get_up() -> Vector3:
	return global_transform.basis.y


# ══════════════════════════════════════════
# ПРИОРИТЕТНАЯ ЦЕЛЬ
# ══════════════════════════════════════════
# Что игрок назначил бить в первую очередь (двойной тап по вражескому блоку). Живёт на
# МАШИНЕ, а не на стволе: назначил один раз — довернулись все орудия, иначе пришлось бы
# указывать цель каждому.
#
# Держим сам БЛОК, а не машину: у врага можно осмысленно выбивать конкретное — сбить
# турель, которая тебя достаёт, или бур, которым он копает, — а не только кабину.
var priority_target: Node3D = null

func set_priority_target(t: Node3D) -> void:
	priority_target = t

# Цель ещё жива? Уничтоженный блок иначе держал бы приоритет вечно, и орудия игнорировали
# бы всё остальное, целясь в пустоту.
func priority_alive() -> bool:
	if priority_target == null or not is_instance_valid(priority_target):
		priority_target = null
		return false
	return true

# ══════════════════════════════════════════
# ОТРЫВ БЛОКОВ В МИР
# ══════════════════════════════════════════
# Живёт здесь, в ОБЩЕЙ базе машин, а не у машины игрока. Оторванный блок роняет карта
# (blocks._detach_one) вызовом veh.detach_block_to_world(), причём через has_method — и у
# врага этого метода просто не было: проверка молча не проходила, клетка карты очищалась,
# а сам узел так и оставался висеть в воздухе там, где был. Отсюда и разница, которую было
# видно в игре: у игрока обломки осыпаются, у врага висят.
var collision_to_block_map: Dictionary = {}

## Сдвиг коллизии у блоков 2×2×2 относительно позиции самого блока: коллизия у них
## описывает куб 2×2×2 и центрируется иначе. Держим одним числом — по нему коллизию и
## ИЩУТ при разборке и при гибели блока, и разъехавшиеся копии этого сдвига означали бы
## коллизию, оставшуюся на корпусе.
const BIG_BLOCK_COL_OFFSET := Vector3(-0.5, 0.5, -0.5)

func _on_block_destroyed(destroyed_block: Node3D) -> void:
	
	var keys_to_remove: Array = []
	
	# Перебираємо всі фізичні форми самого Vehicle
	for owner_id in get_shape_owners():
		var collision_shape: CollisionShape3D = shape_owner_get_owner(owner_id) as CollisionShape3D
		
		if is_instance_valid(collision_shape):
			# Якщо ця колізія належить знищеному блоку.
			# Второй вариант — про блоки 2×2×2 (процессор, продавец): их коллизия ставится
			# со сдвигом (см. постановку блока), и по точному совпадению позиции она не
			# находилась — большой блок погибал, а его коллизия оставалась висеть.
			if collision_shape.position == destroyed_block.position \
					or collision_shape.position == destroyed_block.position + BIG_BLOCK_COL_OFFSET:
				
				
				# 1. Вимикаємо її у фізичному рушії (стоп колізія)
				shape_owner_set_disabled(owner_id, true)
				
				# 2. Очищаємо геометрію форми з фізичного сервера
				shape_owner_clear_shapes(owner_id)
				
				# 3. Видаляємо власника форми з кузова Vehicle
				remove_shape_owner(owner_id)
				
				# 4. Видаляємо сам вузол колізії з кореня Vehicle
				collision_shape.queue_free()
				
				# Запам'ятовуємо ID, щоб підчистити словник урону
				keys_to_remove.append(owner_id)
				
	# Очищаємо словник урону від застарілих ID
	for key in keys_to_remove:
		collision_to_block_map.erase(key)

# Блок потерял связь с корнем (кабина/база) и падает в мир (см. blocks._detach_orphans):
# снимаем его дублированную коллизию с тела машины, репарентим в objects, размораживаем и роняем.
func detach_block_to_world(node: Node) -> void:
	if not is_instance_valid(node):
		return
	if node is Node3D:
		_on_block_destroyed(node as Node3D)          # убрать коллизию блока с тела + чистка мапы урона
	var objects := get_node_or_null("/root/Main/objects")
	if objects == null or not (node is Node3D):
		return
	(node as Node3D).reparent(objects)
	if node is RigidBody3D:
		var rb := node as RigidBody3D
		rb.freeze = false
		rb.sleeping = false
		if _blast_force > 0.0 and Time.get_ticks_msec() < _blast_until_ms:
			# Оторвало ВЗРЫВОМ (напр. батареи) — швыряем от эпицентра сильнее обычного.
			var away := rb.global_position - _blast_pos
			if away.length_squared() < 0.01:            # 0.1², только сравнение
				away = Vector3(randf() - 0.5, 0.3, randf() - 0.5)
			away = (away.normalized() + Vector3.UP * 0.35).normalized()
			rb.apply_central_impulse(away * _blast_force * rb.mass)
		else:
			var dir := Vector3(randf() - 0.5, 0.0, randf() - 0.5)
			dir = dir.normalized() if dir.length_squared() > 0.0001 else Vector3.FORWARD
			rb.apply_central_impulse((dir * 2.0 + Vector3.UP * 2.5) * rb.mass)

# Взрыв на машине (напр. уничтожена батарея): осколки, что оторвутся в ближайшие ~0.3с, летят
# ОТ эпицентра сильнее обычного (см. detach_block_to_world). Ставится из VehicleBlock.destroy.
var _blast_pos: Vector3 = Vector3.ZERO
var _blast_force: float = 0.0
var _blast_until_ms: int = 0

# ══════════════════════════════════════════
# CABIN WATCHDOG — the machine is dead when its cabin is gone
# ══════════════════════════════════════════
# Lives in the SHARED base because both machines need it, and only the player had it. What that
# cost: the cabin's `destroyed` signal is the fast path, but it is not a reliable one. A block
# torn off into the world has ALL its `destroyed` connections cut (blocks._detach_one) so that
# a loose block no longer edits the map of the machine it came from — and with the signal gone,
# an enemy whose cabin left the machine simply never died. What was left was a live hull with
# no blocks on it, still driving, still a target, impossible to kill.
#
# So death is decided by the FACT that no cabin is present, and the signal only makes it fast.
var _dying: bool = false
var _cabin: Node = null            # current cabin; invalid → the build changed or it was killed
var _had_cabin: bool = false       # did it ever have one (stations have none and never die)
const CABIN_WATCH_INTERVAL: float = 0.5
var _cabin_watch_t: float = 0.0

## The node holding the block map. The player names it in the inspector; everyone else has it
## as a child called "blocks".
func blocks_node() -> Node:
	var n = get("block_map_node")
	return n if n != null else get_node_or_null("blocks")

func _connect_cabin() -> void:
	var bl := blocks_node()
	if bl == null:
		return
	for b in bl.get_children():
		if b.get("block") == G.Block.CABIN:
			_cabin = b
			_had_cabin = true
			if b.has_signal("destroyed") and not b.destroyed.is_connected(_on_cabin_destroyed):
				b.destroyed.connect(_on_cabin_destroyed)
			return
	_cabin = null

func _on_cabin_destroyed(_b = null) -> void:
	_die()

func cabin_watch(delta: float) -> void:
	if _dying:
		return
	_cabin_watch_t -= delta
	if _cabin_watch_t > 0.0:
		return
	_cabin_watch_t = CABIN_WATCH_INTERVAL
	# A BASE HAS NO CABIN — it stands on its stationary core, so that is what gets watched.
	# Same rule underneath: a machine dies when it loses the root everything hangs from. The
	# player's station used to rely on the core's `destroyed` signal alone, and an enemy base
	# has no cabin at all, so without this branch it would either never die or die instantly.
	# `is_station` only exists on machines that can be one, and get() on a missing field returns
	# null — bool(null) is a runtime crash, so compare instead of casting (see CLAUDE.md).
	if get("is_station") == true:
		if not _has_core():
			_die()
		return
	if is_instance_valid(_cabin):
		return
	_connect_cabin()                       # build changed — re-subscribe
	if is_instance_valid(_cabin):
		return
	if _had_cabin:
		_die()                             # no cabin, and no signal came

## Is a stationary block still standing on this machine — the core a base holds on to.
## Counted rather than remembered by reference: a base can carry several, and losing one of
## them is not death.
## СБОРКА МОГЛА ЕЩЁ НЕ ПРИМЕНИТЬСЯ. Блоки спавнятся асинхронно (blocks.spawn_block ждёт ready
## родителя), а сторож включается с первого же физкадра — и «детей нет» в этот момент значит
## «ещё не построена», а не «ядро сбито». Флаг помнит, что блоки У ЭТОЙ МАШИНЫ хоть раз были:
## после этого пустой список — уже настоящая смерть, а не гонка при рождении.
var _had_blocks: bool = false

func _has_core() -> bool:
	var bl := blocks_node()
	if bl == null:
		return true                        # build not applied yet — do not kill it on a guess
	var any := false
	for b in bl.get_children():
		var bt = b.get("block")
		if bt == null:
			continue
		any = true
		_had_blocks = true
		if G.is_stationary(int(bt)):
			return true
	return not any and not _had_blocks

## Overridden by both machines: the player hands the camera over, the enemy pays out and
## reports the kill. The base only decides WHEN it happens.
func _die() -> void:
	pass

## РАЗЛЁТ БЛОКОВ ПРИ ГИБЕЛИ МАШИНЫ. Живёт в ОБЩЕЙ базе, потому что нужен обоим: у игрока это
## был `_scatter_blocks`, у врага — `_eject_blocks`, и они разошлись бы при первой же правке
## (у врага, например, не пропускались меш-призраки подсказок). Ровно та ловушка, про которую
## написано в CLAUDE.md: механика, нужная обеим машинам, не должна лежать у одной из них.
##
## cabin — узел, от которого считается ЭПИЦЕНТР разлёта. У врага ссылка на кабину есть под
## рукой, у игрока её ищут перебором; поэтому параметр, а не поиск в одном стиле для обоих.
## Импульс даём НАПРЯМУЮ и сразу: размораживаем сами, не дожидаясь, пока VehicleBlock сделает
## это сигналом кадром позже — иначе блок успевает провалиться сквозь пол, пока не разморожен.
func scatter_blocks(cabin: Node = null) -> void:
	var objects := get_node_or_null("/root/Main/objects")
	var bl: Node = get("block_map_node") if get("block_map_node") != null else get_node_or_null("blocks")
	if objects == null or bl == null:
		return
	var center: Vector3 = global_position
	if cabin != null and is_instance_valid(cabin) and cabin is Node3D:
		center = (cabin as Node3D).global_position
	else:
		for b in bl.get_children():
			if b.get("block") == G.Block.CABIN and b is Node3D:
				center = (b as Node3D).global_position
				break
	for b in bl.get_children():                   # get_children() — снимок, reparent безопасен
		if not ("block" in b):
			continue                              # меш-призрак подсказки: у него нет типа блока
		if b.get("block") == G.Block.CABIN:
			continue                              # кабина уничтожена — не роняем
		if not (b is Node3D):
			continue
		var n3 := b as Node3D
		n3.reparent(objects)                      # keep_global_transform=true → блок на месте
		var rb := n3 as RigidBody3D
		if rb == null:
			continue
		var dir := rb.global_position - center
		dir.y = 0.0
		dir = dir.normalized() if dir.length_squared() > 0.0001 \
				else Vector3(randf() - 0.5, 0.0, randf() - 0.5).normalized()
		rb.freeze = false
		rb.sleeping = false
		rb.apply_central_impulse((dir * 5.0 + Vector3.UP * 4.0) * rb.mass)

func register_blast(pos: Vector3, force: float) -> void:
	_blast_pos = pos
	_blast_force = force
	_blast_until_ms = Time.get_ticks_msec() + 300

