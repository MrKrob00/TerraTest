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
@export var chassis_power: float = 500.0
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
# же тяги, поэтому «предела в килограммах» как константы не существует — он растёт
# вместе с колёсами. Время разгона до max_speed ≈ max_speed / ускорение.
const ACCEL_BRISK: float = 12.0   # выше — машина бодрая (разгон ~1.7 с)
const ACCEL_CRAWL: float = 5.0    # ниже — фактически не едет (разгон от 4 с и хуже)

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

func init_machine_physics() -> void:
	gravity_scale = gravity_mult

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
	if _on_ground:
		_apply_engine()
		_apply_grip()
		_apply_steering(delta)
	# Крен гасим и в воздухе, но слабее: без контакта колёс демпфировать физически
	# нечем, а полностью отпустив машину, получаем неуправляемое вращение после трамплина.
	_apply_anti_roll(delta, 1.0 if _on_ground else air_stability)
	_apply_upright(delta)
	_limit_speed()

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
		_ground_q.exclude = [self]          # состав не меняется — задаём один раз
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
		apply_central_force(fwd * _throttle * power * engine_force * speed_factor)
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
