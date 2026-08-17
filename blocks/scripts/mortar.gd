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
const SALVO_PERIOD := 4.0      # пауза между залпами
const SPREAD := 6.0            # разброс по земле, метров
const SHELL_SPEED := 55.0
const SHELL_GRAVITY := 30.0

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
	var t: Node3D = _current_target
	if t == null or not is_instance_valid(t):
		return
	# Обе границы — сравнения, значение дальности здесь не нужно: корень не берём.
	var d2: float = global_position.distance_squared_to(t.global_position)
	if d2 < MIN_RANGE * MIN_RANGE or d2 > MAX_RANGE * MAX_RANGE:
		return                       # вне вилки — молчим, и это видно как правило
	_salvo_t = SALVO_PERIOD
	for _i in SHELLS:
		super.fire_bullet()
		_arc_last(t)

# Отправить последний снаряд НАВЕСОМ в точку цели с разбросом. Угол берём из баллистики:
# для настильной ветви угол броска = ½·asin(g·d / v²) — то есть чем дальше цель, тем круче
# ствол. Дальше MAX_RANGE решения нет вовсе, поэтому туда и не стреляем.
func _arc_last(target: Node3D) -> void:
	var b: Area3D = _last_bullet()
	if b == null or not ("dir" in b):
		return
	b.set("speed", SHELL_SPEED)
	b.set("bullet_gravity", SHELL_GRAVITY)
	b.set("max_lifetime", 12.0)          # навес летит долго: пуля успела бы истечь в воздухе
	var aim: Vector3 = target.global_position
	aim.x += randf_range(-SPREAD, SPREAD)
	aim.z += randf_range(-SPREAD, SPREAD)
	var flat: Vector3 = aim - global_position
	flat.y = 0.0
	var dist: float = flat.length()
	if dist < 0.1:
		return
	var s: float = clampf(SHELL_GRAVITY * dist / (SHELL_SPEED * SHELL_SPEED), -1.0, 1.0)
	var ang: float = 0.5 * asin(s)
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
