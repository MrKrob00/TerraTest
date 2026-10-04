extends WeaponBlock
# 8-BARREL MORTAR: a salvo of lobbed shells.
#
# Aimed by the HULL - yaw_limit is 18 deg, the barrel only trims. Throw angle follows distance,
# 60 deg near to 30 deg far, and the speed comes out of v = sqrt(g*d / sin 2t). The 20 m minimum
# falls out of that same formula rather than being a rule in code.
#
#   dist    angle   speed      flight   apex
#    20 m   60.0    26.3 m/s   1.52 s    8.7 m
#    50 m   53.6    39.6 m/s   2.13 s   16.9 m
#    90 m   45.0    52.0 m/s   2.45 s   22.5 m
#   160 m   30.0    74.4 m/s   2.48 s   23.1 m
#
# SPREAD IS IN METRES ON THE GROUND, and it alone decides how much of a salvo lands. At +-6 m the
# pattern is 144 m2 and a 3x3 machine covers a sixteenth of it: one shell of eight, i.e. 6 real
# damage per second against 96 on paper. Recheck this number before touching anything else here.
const MIN_RANGE := 20.0        # a lob cannot reach closer (see header)
const MAX_RANGE := 160.0
# Exported: Marlit's mortar has seven tubes and fires seven (marlit_mortar.tscn); the defaults are
# the Falsus eight-barrel numbers.
@export var shells: int = 8              # per salvo, all at once - one per tube on the model
@export var shell_damage: int = 62
## Set from what LANDS, not from the salvo: 3-4 shells x 12 over 1.6 s is 25-30/s, a heavy
## gun's worth, paid for with flight time and a 20 m dead zone.
@export var salvo_period: float = 1.6
const SPREAD := 2.5            # metres on the ground (see header)
const SHELL_GRAVITY := 30.0
## Throw angle at the near and far limits; linear in distance between them.
const ARC_NEAR_DEG := 60.0
const ARC_FAR_DEG := 30.0
## Barrel trim only - the hull does the aiming.
const MORTAR_YAW := 18.0

var _salvo_t: float = 0.0
## The tube pack's REST elevation, read off the scene rather than written here. The model stands
## at rest pointing up the way a mortar is parked (mortar.tscn, `mortar_head`), and WeaponBlock
## rotates a part FROM its rest pose: so the aim hands it the throw angle MINUS this, and the pack
## shows exactly the angle the shells leave at. A second number here would disagree with the
## scene the first time either was touched.
var _idle_pitch: float = 0.0

func _init() -> void:
	damage_kind = VehicleBlock.Dmg.EXPLOSIVE   # x2 on batteries, x1.5 on tyres, x0.5 on armour
	turn_speed = 45.0        # deg/s (WeaponBlock._turn_to): the hull aims it; the pack only trims and lifts

func _ready() -> void:
	super._ready()
	weapon_range = MAX_RANGE
	damage = shell_damage
	recoil_dist = maxf(recoil_dist, 0.08)
	# Свой сектор: узкий по горизонтали, зато вверх — на весь рабочий угол броска.
	yaw_limit = MORTAR_YAW
	pitch_limit = ARC_NEAR_DEG
	# Базовый конус разброса мортире не нужен: _arc_last всё равно задаёт направление снаряда
	# заново, от точки падения, и свой разброс у неё МЕТРАМИ ПО ЗЕМЛЕ (SPREAD) — так и должно
	# быть у навесного оружия, которое целится в место, а не в тело.
	spread_deg = 0.0
	fire_rate = salvo_period
	shield_cost_mult = SHIELD_MULT_EXPLOSIVE   # взрыв идёт сквозь купол, платить за него незачем
	raycast.target_position = Vector3(0, 0, -weapon_range)
	_sync_detect_radius()
	if _pitch_part != null:
		var f: Vector3 = _pitch_rest * Vector3.FORWARD
		_idle_pitch = atan2(f.y, Vector2(f.x, f.z).length())
	# the pivot starts where the pack stands, or the first salvo would swing the pack down from it
	pivot.rotation = Vector3(_idle_pitch, 0.0, 0.0)

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
		_turn_to(rad_to_deg(_idle_pitch), 0.0, delta, _idle_pitch)   # parked as the scene parks it
		return
	var flat: Vector3 = t.global_position - global_position
	flat.y = 0.0
	var dist: float = flat.length()
	var dir_local: Vector3 = global_transform.basis.inverse() * flat.normalized()
	var yaw: float = clampf(rad_to_deg(atan2(-dir_local.x, -dir_local.z)), -yaw_limit, yaw_limit)
	var pitch: float = _arc_deg(dist)
	_turn_to(pitch, yaw, delta, _idle_pitch)

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
	_salvo_t = salvo_period
	for _i in shells:
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
	var b = last_fired
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

