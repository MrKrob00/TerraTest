extends WeaponBlock
# 8-BARREL MORTAR — залп навесных снарядов, падающий дождём по дуге.
#
# НАВОДКА: корпусом плюс небольшой доворот. Ствол ходит на YAW ±18° — этого хватает, чтобы не
# промахиваться мимо цели, которая чуть сместилась, и мало, чтобы стрелять «куда угодно, не
# поворачиваясь»: мортиру всё так же подводят корпусом, как и раньше.
#
# УГОЛ БРОСКА ХОДИТ ПО ДАЛЬНОСТИ, 60° вблизи → 30° вдали. Так стреляет настоящая мортира: по
# ближней цели круче (снаряд падает почти отвесно), по дальней отложе. Фиксированные 45°
# выглядели одинаково на любой дистанции, то есть дуга ничего не рассказывала о расстоянии.
#
# СКОРОСТЬ ПОДБИРАЕТСЯ ПОД ДАЛЬНОСТЬ из v = √(g·d / sin 2θ). Отсюда же берётся и ближняя
# граница: на максимальном угле 60° минимальная разумная скорость кладёт снаряд ровно в 20 м,
# ближе навесом не положить физически. Поэтому «не стреляет ближе двадцати» — это не запрет в
# коде, а следствие баллистики; запрет лишь делает его видимым, вместо выстрела в никуда.
#
# ЧТО ПОЛУЧАЕТСЯ (g = 30, считано по формулам ниже):
#
#   дальность   угол    скорость   время полёта   высота дуги
#      20 м     60.0°    26.3 м/с     1.52 с          8.7 м
#      50 м     53.6°    39.6 м/с     2.13 с         16.9 м
#      90 м     45.0°    52.0 м/с     2.45 с         22.5 м
#     160 м     30.0°    74.4 м/с     2.48 с         23.1 м
#
# То есть снаряд идёт полторы-две с половиной секунды и поднимается на девять-двадцать три
# метра: дуга видна глазом, у цели есть время уехать, а по стоящей машине залп накрывает.
#
# РАЗБРОС — МЕТРАМИ ПО ЗЕМЛЕ, и он же решает, сколько снарядов долетит до цели. Было ±6 м, то
# есть квадрат 12×12 = 144 м²: машина размером три на три занимает в нём шестнадцатую часть, и
# из восьми снарядов в неё попадал в среднем ОДИН. На бумаге мортира выдавала 96 урона в
# секунду и была сильнейшим стволом игры, на деле — около шести. Теперь ±2.5 м: пятно 5×5,
# машина закрывает больше трети, три-четыре снаряда из восьми ложатся в цель.

const MIN_RANGE := 20.0        # ближе навесом не положить (см. шапку)
const MAX_RANGE := 160.0
const SHELLS := 8              # залпом, одновременно
const SHELL_DAMAGE := 12
## ПАУЗА МЕЖДУ ЗАЛПАМИ. Считается от того, сколько снарядов реально доходит: три-четыре по 12 —
## это 40-48 за залп, и на 1.6 с выходит 25-30 в секунду, вровень с тяжёлой пушкой. Платит
## мортира временем полёта (до двух с половиной секунд) и мёртвой зоной в двадцать метров.
const SALVO_PERIOD := 1.6
const SPREAD := 2.5            # разброс по земле, метров (см. шапку)
const SHELL_GRAVITY := 30.0
## Углы броска на ближней и дальней границе. Между ними — линейно по дальности.
const ARC_NEAR_DEG := 60.0
const ARC_FAR_DEG := 30.0
## Доворот ствола. «Процентов десять от круга» — это и есть восемнадцать градусов в каждую
## сторону.
const MORTAR_YAW := 18.0

var _salvo_t: float = 0.0

func _ready() -> void:
	super._ready()
	weapon_range = MAX_RANGE
	damage = SHELL_DAMAGE
	# Свой сектор: узкий по горизонтали, зато вверх — на весь рабочий угол броска.
	yaw_limit = MORTAR_YAW
	pitch_limit = ARC_NEAR_DEG
	# Базовый конус разброса мортире не нужен: _arc_last всё равно задаёт направление снаряда
	# заново, от точки падения, и свой разброс у неё МЕТРАМИ ПО ЗЕМЛЕ (SPREAD) — так и должно
	# быть у навесного оружия, которое целится в место, а не в тело.
	spread_deg = 0.0
	fire_rate = SALVO_PERIOD
	raycast.target_position = Vector3(0, 0, -weapon_range)
	_sync_detect_radius()

func _physics_process(delta: float) -> void:
	_salvo_t = maxf(_salvo_t - delta, 0.0)
	super._physics_process(delta)

## НАВОДКА У МОРТИРЫ СВОЯ, и отличается она от пушечной принципиально: пушка смотрит НА цель, а
## мортира смотрит ВВЕРХ — в ту сторону и под тем углом, под каким снаряд уйдёт по дуге. Поэтому
## рыскание берём от цели (в пределах своего узкого сектора), а тангаж — прямо из баллистики.
func _track_target(delta: float, firing: bool) -> void:
	var t: Node3D = _current_target
	var live: bool = firing and t != null and is_instance_valid(t) and _is_in_cone(t)
	if not live:
		pivot.rotation = lerp(pivot.rotation, Vector3.ZERO, 8.0 * delta)
		_aim_model(0.0, 0.0, delta)
		return
	var flat: Vector3 = t.global_position - global_position
	flat.y = 0.0
	var dist: float = flat.length()
	var dir_local: Vector3 = global_transform.basis.inverse() * flat.normalized()
	var yaw: float = clampf(rad_to_deg(atan2(-dir_local.x, -dir_local.z)), -yaw_limit, yaw_limit)
	var pitch: float = _arc_deg(dist)
	pivot.rotation = lerp(pivot.rotation, Vector3(deg_to_rad(pitch), deg_to_rad(yaw), 0.0),
			12.0 * delta)
	_aim_model(deg_to_rad(yaw), deg_to_rad(pitch), delta)

## Угол броска на эту дальность: круто вблизи, отложе вдали (см. шапку).
func _arc_deg(dist: float) -> float:
	var k: float = clampf((dist - MIN_RANGE) / maxf(MAX_RANGE - MIN_RANGE, 0.001), 0.0, 1.0)
	return lerpf(ARC_NEAR_DEG, ARC_FAR_DEG, k)

## Скорость, при которой снаряд, брошенный под этим углом, ложится ровно на эту дальность.
## Из d = v²·sin(2θ)/g. Ближняя граница сидит в этой же формуле: 60° и 20 м дают 26.3 м/с, и
## медленнее мортира не бросает — значит и ближе двадцати метров не достаёт.
func _shell_speed(dist: float, ang_rad: float) -> float:
	return sqrt(SHELL_GRAVITY * dist / maxf(sin(2.0 * ang_rad), 0.01))

func fire_bullet() -> void:
	if _salvo_t > 0.0:
		return
	var aim: Variant = _aim_ground()
	if aim == null:
		return
	_salvo_t = SALVO_PERIOD
	for _i in SHELLS:
		super.fire_bullet()
		_arc_last(aim as Vector3)

## КУДА кладём залп. Есть цель — по цели, как раньше, и по-прежнему только в своей вилке
## дальности. НЕТ цели — ПРЯМО ПЕРЕД СОБОЙ, на MIN_RANGE: по кнопке Attack все остальные
## стволы бьют вперёд, и одна молчащая мортира читалась как сломанный блок. Дистанция взята
## не с потолка — это её же ближняя граница: ближе навесом попасть нельзя, а значит «вперёд»
## для мортиры и есть двадцать метров.
##
## Возвращает Vector3 или null (молчим): точка на ЗЕМЛЕ, потому что снаряд навесной и
## приходит сверху — целиться в воздух перед собой бессмысленно.
func _aim_ground() -> Variant:
	var t: Node3D = _current_target
	if t != null and is_instance_valid(t):
		# Обе границы — сравнения, значение дальности здесь не нужно: корень не берём.
		var d2: float = global_position.distance_squared_to(t.global_position)
		if d2 < MIN_RANGE * MIN_RANGE or d2 > MAX_RANGE * MAX_RANGE:
			return null              # вне вилки — молчим, и это видно как правило
		if not _is_in_cone(t):
			return null              # вне своего сектора: машину надо довернуть корпусом
		return t.global_position
	var fwd: Vector3 = -global_transform.basis.z
	fwd.y = 0.0
	if fwd.length_squared() < 0.0001:
		return null                  # ствол смотрит строго вверх/вниз — направления нет
	var p: Vector3 = global_position + fwd.normalized() * MIN_RANGE
	p.y = G.ground_y(p, global_position.y)
	return p

# Отправить последний снаряд НАВЕСОМ в точку цели с разбросом.
#
# Угол и скорость — по дальности до ТОЧКИ ПАДЕНИЯ, а не до цели: разброс сдвигает точку на
# метры, и снаряд обязан лететь именно туда, куда его положили, иначе пятно расползается тем
# сильнее, чем дальше стреляем.
func _arc_last(point: Vector3) -> void:
	var b: Area3D = last_fired
	if b == null or not is_instance_valid(b) or not ("dir" in b):
		return
	var aim: Vector3 = point
	aim.x += randf_range(-SPREAD, SPREAD)
	aim.z += randf_range(-SPREAD, SPREAD)
	var flat: Vector3 = aim - global_position
	flat.y = 0.0
	var dist: float = flat.length()
	if dist < 0.1:
		return
	var ang: float = deg_to_rad(_arc_deg(dist))
	var speed: float = _shell_speed(dist, ang)
	b.set("speed", speed)
	b.set("bullet_gravity", SHELL_GRAVITY)
	b.set("max_lifetime", 12.0)          # навес летит долго: пуля успела бы истечь в воздухе
	var horiz: Vector3 = flat / dist
	b.dir = (horiz * cos(ang) + Vector3.UP * sin(ang)).normalized()
	if absf(b.dir.dot(Vector3.UP)) < 0.99:
		b.look_at(b.global_position + b.dir)

