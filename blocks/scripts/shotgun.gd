extends WeaponBlock
# COMBAT SHOTGUN — дробь в упор. С башней и автонаведением, как обычная пушка, но стреляет
# ПАЧКОЙ дробин с разбросом и после двух выстрелов уходит на перезарядку.
#
# Разброс — это и есть весь смысл: на своей дистанции дробовик прощает промах по наводке и
# бьёт больно, а дальше десятка метров дробины расходятся, и он бесполезен. Поэтому у него
# короткая дальность, а не просто малый урон: ограничение должно читаться по поведению.

const PELLETS := 8            # дробин в выстреле
const PELLET_DAMAGE := 4      # 8×4 = 32 в упор — вдвое больше обычной пушки за выстрел
const SHOTGUN_RANGE := 18.0
const BURST := 2              # выстрелов до перезарядки
const RELOAD := 2.5           # секунд
const SPREAD_DEG := 7.0       # половина угла конуса

var _left: int = BURST
var _reload_t: float = 0.0

func _ready() -> void:
	super._ready()
	weapon_range = SHOTGUN_RANGE
	damage = PELLET_DAMAGE
	# БАЗОВЫЙ РАЗБРОС ВЫКЛЮЧАЕМ: у дробовика он свой и, главное, ПОСТОЯННЫЙ. Базовый сжимается
	# по мере приближения к цели (WeaponBlock._apply_spread) — для пушки это правильно, а тут
	# сузило бы дробь ровно там, где широкая «метла» и есть весь смысл оружия.
	spread_deg = 0.0
	fire_rate = 0.35
	raycast.target_position = Vector3(0, 0, -weapon_range)
	_sync_detect_radius()          # дальность своя — зона обнаружения должна за ней следовать

func _physics_process(delta: float) -> void:
	if _reload_t > 0.0:
		_reload_t -= delta
		if _reload_t <= 0.0:
			_left = BURST
	super._physics_process(delta)

# Один «выстрел» = пачка дробин. Каждая летит своей пулей с отклонением, поэтому попадания
# считаются по-настоящему: часть дробин может уйти мимо, часть — в разные блоки цели.
func fire_bullet() -> void:
	if _reload_t > 0.0:
		return
	for _i in PELLETS:
		super.fire_bullet()
		_spread_last()
	_left -= 1
	if _left <= 0:
		_reload_t = RELOAD

# Базовый fire_bullet пускает пулю строго по стволу — доворачиваем ПОСЛЕДНЮЮ выпущенную.
func _spread_last() -> void:
	var b: Area3D = _last_bullet()
	if b == null or not ("dir" in b):
		return
	var d: Vector3 = b.dir
	if d == Vector3.ZERO:
		return
	var a := deg_to_rad(SPREAD_DEG)
	d = d.rotated(Vector3.UP, randf_range(-a, a))
	# Вертикальный разброс вдвое меньше горизонтального: широкая по земле «метла» читается
	# лучше, чем облако, часть которого уходит в небо впустую.
	var side: Vector3 = d.cross(Vector3.UP).normalized()
	if side.length_squared() > 0.0001:
		d = d.rotated(side, randf_range(-a * 0.5, a * 0.5))
	b.dir = d.normalized()

# Только что выпущенная пуля — последняя, покинувшая пул: она уже в полёте (dir не ноль).
func _last_bullet() -> Area3D:
	if ammo == null:
		return null
	for i in range(ammo.get_child_count() - 1, -1, -1):
		var c = ammo.get_child(i)
		if c is Area3D and ("dir" in c) and c.dir != Vector3.ZERO:
			return c as Area3D
	return null
