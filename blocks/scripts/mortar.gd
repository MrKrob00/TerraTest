extends WeaponBlock
# 8-BARREL MORTAR — залп из восьми навесных снарядов. БЕЗ башни: наводится корпусом машины,
# то есть куда едешь, туда и бьёшь.
#
# Дальность считается САМА по цели (решение игрока): игрок не крутит прицел, он подъезжает
# на нужную дистанцию. Отсюда и главное ограничение — ближе MIN_RANGE мортира не стреляет
# вовсе: навесом в упор попасть нельзя физически, и «стреляет, но мимо» игрок читал бы как
# поломку, а молчащий ствол — как правило.
#
# Наводка отличается от пушечной принципиально: пушка кладёт снаряд ПРЯМО и лишь поправляет
# просадку, а мортира бросает его ВВЕРХ и попадает нисходящей ветвью. Поэтому угол здесь
# решается баллистикой, а не доворотом ствола на цель.

const MIN_RANGE := 20.0        # решение игрока
const MAX_RANGE := 160.0
const SHELLS := 8              # залпом, одновременно
const SHELL_DAMAGE := 12
const SALVO_PERIOD := 1.0      # пауза между залпами (решение игрока)
const SPREAD := 6.0            # разброс по земле, метров
const SHELL_GRAVITY := 30.0
## Угол броска — ФИКСИРОВАННЫЙ. Раньше он считался по настильной ветви (½·asin(g·d/v²)) и на
## близких целях вырождался почти в ноль: мортира стреляла прямой наводкой, как пушка, и
## «навеса» в ней не было вовсе. Теперь угол задан, а под дальность подбирается СКОРОСТЬ —
## так навес виден всегда и одинаков на любой дистанции.
const ARC_DEG := 45.0

var _salvo_t: float = 0.0

func _ready() -> void:
	super._ready()
	weapon_range = MAX_RANGE
	damage = SHELL_DAMAGE
	fire_rate = SALVO_PERIOD
	raycast.target_position = Vector3(0, 0, -weapon_range)
	_sync_detect_radius()

func _physics_process(delta: float) -> void:
	_salvo_t = maxf(_salvo_t - delta, 0.0)
	super._physics_process(delta)

# Башни нет: ствол не доворачиваем вовсе, поэтому переопределяем наводку пустышкой.
# Базовая версия крутила бы pivot, а у мортиры он неподвижен — это её главное отличие.
func _track_target(_delta: float, _firing: bool) -> void:
	pass

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
# Угол ФИКСИРОВАН (ARC_DEG), а под дальность подбирается скорость. Из d = v²·sin(2θ)/g при
# θ = 45° следует v = √(g·d) — то есть по ближней цели снаряд летит медленно и высоко, по
# дальней быстро, но дуга одна и та же. Так и должна выглядеть мортира: навес не «включается»
# на дальних дистанциях, он у неё всегда.
func _arc_last(point: Vector3) -> void:
	var b: Area3D = _last_bullet()
	if b == null or not ("dir" in b):
		return
	var aim: Vector3 = point
	aim.x += randf_range(-SPREAD, SPREAD)
	aim.z += randf_range(-SPREAD, SPREAD)
	var flat: Vector3 = aim - global_position
	flat.y = 0.0
	var dist: float = flat.length()
	if dist < 0.1:
		return
	var ang: float = deg_to_rad(ARC_DEG)
	# sin(2θ) при 45° равен единице, но пишем формулу целиком: поменяют ARC_DEG — скорость
	# пересчитается сама, а не разъедется с углом.
	var speed: float = sqrt(SHELL_GRAVITY * dist / maxf(sin(2.0 * ang), 0.01))
	b.set("speed", speed)
	b.set("bullet_gravity", SHELL_GRAVITY)
	b.set("max_lifetime", 12.0)          # навес летит долго: пуля успела бы истечь в воздухе
	var horiz: Vector3 = flat / dist
	b.dir = (horiz * cos(ang) + Vector3.UP * sin(ang)).normalized()
	if absf(b.dir.dot(Vector3.UP)) < 0.99:
		b.look_at(b.global_position + b.dir)

func _last_bullet() -> Area3D:
	if ammo == null:
		return null
	for i in range(ammo.get_child_count() - 1, -1, -1):
		var c = ammo.get_child(i)
		if c is Area3D and ("dir" in c) and c.dir != Vector3.ZERO:
			return c as Area3D
	return null
