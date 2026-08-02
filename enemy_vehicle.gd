extends RigidBody3D

# ══════════════════════════════════════════════════════════════════
# ENEMY VEHICLE — полный переписанный ИИ
# _get_forward() = +Z (колёса в +Z = визуальный передок машины)
# Area3D создаётся программно, сигналы подключаются в _ready
# ══════════════════════════════════════════════════════════════════

# ══════════════════════════════════════════
# ЭКСПОРТ — ФИЗИКА (идентично vehicle_body_3d)
# ══════════════════════════════════════════

@export_group("Двигатель")
@export var engine_force:  float = 80.0
@export var max_speed:     float = 20.0
@export var engine_brake:  float = 0.3

@export_group("Тормоза")
@export var brake_power: float = 4.0

@export_group("Поворот")
@export var steer_max_angle:       float = 45.0
@export var steer_speed:           float = 10.0
@export var turn_response:         float = 4.0
@export var speed_steer_reduction: float = 0.5

@export_group("Сцепление шин")
@export var lateral_grip:      float = 8.0
@export var longitudinal_grip: float = 0.3

@export_group("Стабилизация")
# Чуть сильнее, чем у игрока (6.0/12.0): у ИИ нет ручного контр-руления при опрокидывании,
# так что запас устойчивости нужен больше — а сборки врагов часто кладут оружие на y=1.
@export var anti_roll:       float = 8.0
@export var upright_strength: float = 15.0

@export_group("Масса и физика")
@export var base_weight:  float = 40.0
@export var gravity_mult: float = 2.5

# ══════════════════════════════════════════
# ЭКСПОРТ — ИИ
# ══════════════════════════════════════════

@export_group("ИИ — Фракция")
## 0 = игрок, 1+ = враги. Атакует всех с другим faction.
@export var faction: int = 1

@export_group("ИИ — Живучесть")
## Блоки — отдельные RigidBody (слой 2) со своим HP; пули игрока (mask 3) бьют по ним,
## а не по корпусу. Ловим destroyed КАБИНЫ → машина гибнет, шлёт died (спавнер поднимает
## нового) и роняет остальные блоки в мир (reparent в objects → они сами оживают).
signal died(enemy: Node)
var _cabin: Node = null
var _dying: bool = false

@export_group("ИИ — Обнаружение")
@export var detection_radius:    float = 40.0
@export var attack_range:        float = 15.0
@export var min_combat_distance: float = 5.0
## Слои, на которых ИИ ищет цели. Корпус машины (где живёт faction) лежит на слое
## «machine» (5 → значение 16). Старое значение 1|2 ловило рельеф и блоки, но НЕ сам
## корпус — поэтому ИИ не видел игрока. По умолчанию = слой machine.
@export_flags_3d_physics var detection_mask: int = 16

@export_group("ИИ — Патруль")
## Кастомные точки. Если пусто — генерируются случайные.
@export var patrol_points:       Array[Vector3] = []
@export var patrol_radius:       float = 30.0
@export var patrol_points_count: int   = 4
@export var waypoint_reach_dist: float = 3.0

@export_group("ИИ — Поведение")
@export var patrol_speed_factor: float = 0.5
@export var chase_speed_factor:  float = 1.0
## Сколько держим цель ПОСЛЕ того, как она вышла из зоны обнаружения (внутри зоны не забываем).
@export var forget_enemy_time:   float = 6.0
## Множитель тяги в погоне. При равном max_speed догнать убегающего нельзя — даём небольшой перевес.
@export var chase_boost:         float = 1.25

@export_group("ИИ — Препятствия")
@export var obstacle_ray_length: float = 5.0
@export var obstacle_ray_angle:  float = 35.0

# ══════════════════════════════════════════
# СОСТОЯНИЯ
# ══════════════════════════════════════════

enum AIState { PATROL, CHASE, ATTACK, STUCK_RECOVERY }

# ══════════════════════════════════════════
# ПЕРЕМЕННЫЕ — ФИЗИКА
# ══════════════════════════════════════════

var Wheels: Array  = []
var _steer_angle:  float = 0.0
var _throttle:     float = 0.0
var _on_ground:    bool  = false

# ══════════════════════════════════════════
# ПЕРЕМЕННЫЕ — ИИ
# ══════════════════════════════════════════

var _state:        AIState = AIState.PATROL
var _target:       Node3D  = null
var _forget_timer: float   = 0.0

var _patrol_targets: Array[Vector3] = []
var _patrol_index:   int   = 0
var _start_pos:      Vector3

# Застревание
var _stuck_timer:            float    = 0.0
var _stuck_check_pos:        Vector3
var _stuck_check_interval:   float    = 1.5
var _stuck_recovery_timer:   float    = 0.0
var _stuck_recovery_duration: float   = 2.0
var _stuck_drive_dir:        float    = -1.0
var _state_before_stuck:     AIState  = AIState.PATROL

# Препятствия
var _obstacle_correction: float = 0.0

# Атака: сторона объезда цели (+1/-1), выбирается один раз за бой; 0 = не выбрана.
var _orbit_dir: float = 0.0

# ══════════════════════════════════════════
# ОСИ — ИДЕНТИЧНО vehicle_body_3d
# ══════════════════════════════════════════

# Перёд = -Z, как у игрока: враг использует тот же blocks.gd-расклад (дрель/нос на z=4 →
# локальный -Z, колёса z=5..7). Раньше тут был +Z → ИИ ехал ЗАДОМ (это вылезло только
# когда фикс detection_mask заставил его реально преследовать).
func _get_forward() -> Vector3: return -global_transform.basis.z
func _get_right()   -> Vector3: return  global_transform.basis.x
func _get_up()      -> Vector3: return  global_transform.basis.y

# ══════════════════════════════════════════
# ИНИЦИАЛИЗАЦИЯ
# ══════════════════════════════════════════

func _ready() -> void:
	mass          = base_weight
	gravity_scale = gravity_mult
	linear_damp   = 0.0
	angular_damp  = 4.0

	_start_pos          = global_position
	_stuck_check_pos    = global_position
	_state_before_stuck = AIState.PATROL

	_setup_detection_area()
	_setup_patrol_points()
	_connect_cabin()

# Кабина строится в blocks._ready (дочерний узел → раньше нашего _ready), поэтому она уже
# готова. Ловим её destroyed → гибель машины.
func _connect_cabin() -> void:
	var blocks_node := get_node_or_null("blocks")
	if blocks_node == null:
		return
	for b in blocks_node.get_children():
		if b.get("block") == G.Block.CABIN:
			_cabin = b
			if b.has_signal("destroyed") and not b.destroyed.is_connected(_on_cabin_destroyed):
				b.destroyed.connect(_on_cabin_destroyed)
			return

func _on_cabin_destroyed(_b = null) -> void:
	_die()

func _die() -> void:
	if _dying:
		return
	_dying = true
	Q.report("enemy_killed", 1)             # прогресс боевых заданий
	died.emit(self)
	_eject_blocks()
	queue_free()

# Роняем уцелевшие блоки в мир С РАЗЛЁТОМ от кабины — как у машины игрока
# (vehicle_body_3d._scatter_blocks): reparent -> freeze=false -> импульс напрямую.
func _eject_blocks() -> void:
	var objects := get_node_or_null("/root/Main/objects")
	var blocks_node := get_node_or_null("blocks")
	if objects == null or blocks_node == null:
		return
	var cabin_pos: Vector3 = global_position
	if _cabin != null and is_instance_valid(_cabin) and _cabin is Node3D:
		cabin_pos = (_cabin as Node3D).global_position
	for b in blocks_node.get_children():          # get_children() — снимок, reparent безопасен
		if b.get("block") == G.Block.CABIN:
			continue                              # кабина уничтожена — не роняем
		if b is Node3D:
			var n3 := b as Node3D
			n3.reparent(objects)                  # keep_global_transform=true → блок на месте
			if n3 is RigidBody3D:
				var rb := n3 as RigidBody3D
				var dir := (rb.global_position - cabin_pos)
				dir.y = 0.0
				dir = dir.normalized() if dir.length() > 0.01 else Vector3(randf() - 0.5, 0, randf() - 0.5).normalized()
				rb.freeze = false
				rb.sleeping = false
				rb.apply_central_impulse((dir * 5.0 + Vector3.UP * 4.0) * rb.mass)

func _setup_detection_area() -> void:
	var area: Area3D = Area3D.new()
	area.name             = "DetectionArea"
	area.collision_layer  = 0
	area.collision_mask   = detection_mask  # по умолчанию слой machine (корпуса машин)

	var col: CollisionShape3D = CollisionShape3D.new()
	var sph: SphereShape3D = SphereShape3D.new()
	sph.radius = detection_radius
	col.shape  = sph
	area.add_child(col)
	add_child(area)
	_detect_area = area                     # держим ссылку: по ней ПЕРИОДИЧЕСКИ пере-ищем цель

	area.body_entered.connect(_on_body_entered)
	area.body_exited.connect(_on_body_exited)

func _setup_patrol_points() -> void:
	if patrol_points.size() > 0:
		_patrol_targets = patrol_points.duplicate()
		return
	_patrol_targets.clear()
	for i in patrol_points_count:
		var ang: float = (TAU / patrol_points_count) * i + randf_range(-0.5, 0.5)
		var dist: float = patrol_radius * randf_range(0.5, 1.0)
		_patrol_targets.append(_start_pos + Vector3(cos(ang) * dist, 0.0, sin(ang) * dist))

# ══════════════════════════════════════════
# ГЛАВНЫЙ ЦИКЛ
# ══════════════════════════════════════════

func _physics_process(delta: float) -> void:
	_check_ground()
	_sync_mass(delta)
	_update_ai(delta)
	_detect_obstacles(delta)

	if _on_ground:
		_apply_engine(delta)
		_apply_grip(delta)
		_apply_steering(delta)
		_apply_anti_roll(delta)
	_apply_upright(delta)
	_limit_speed()

	# Кеш вместо get_children()+has_method каждый физ-тик (см. тот же приём у игрока).
	var steer_norm: float = -_steer_angle / deg_to_rad(steer_max_angle)
	for block in _drive_blocks():
		block.set_throttle(_throttle)
		block.set_steer(steer_norm)

# ══════════════════════════════════════════
# ИИ — ДИСПЕТЧЕР
# ══════════════════════════════════════════

var _detect_area: Area3D = null
var _reacquire_t: float = 0.0
var _last_known_pos: Vector3 = Vector3.ZERO
var _has_last_known: bool = false

# ГЛАВНЫЙ ФИКС ИИ: цель бралась ТОЛЬКО из сигнала body_entered. Стоило потерять её
# (forget_enemy_time), как игрок оставался ВНУТРИ сферы обнаружения — а значит body_entered
# больше никогда не срабатывал, и враг уезжал патрулировать, в упор игнорируя игрока, пока тот
# не выедет за 40 м и не вернётся. Отсюда и «пострелял пару секунд → перестал → долго ничего».
# Теперь, когда цели нет, регулярно опрашиваем саму зону обнаружения.
func _scan_for_targets() -> void:
	if _detect_area == null or not is_instance_valid(_detect_area):
		return
	var best: Node3D = null
	var best_d: float = INF
	for b in _detect_area.get_overlapping_bodies():
		if not _is_enemy(b) or not (b is Node3D):
			continue
		var d: float = global_position.distance_to((b as Node3D).global_position)
		if d < best_d:
			best_d = d
			best = b as Node3D
	if best != null:
		_target = best
		_forget_timer = forget_enemy_time
		_state = AIState.CHASE

func _update_ai(delta: float) -> void:
	# Нет цели (или она погибла) — периодически пере-ищем её в зоне обнаружения.
	if not is_instance_valid(_target):
		_reacquire_t -= delta
		if _reacquire_t <= 0.0:
			_reacquire_t = 0.3
			_scan_for_targets()
	match _state:
		AIState.PATROL:         _ai_patrol(delta)
		AIState.CHASE:          _ai_chase(delta)
		AIState.ATTACK:         _ai_attack(delta)
		AIState.STUCK_RECOVERY: _ai_stuck_recovery(delta)
	_check_stuck(delta)

# ══════════════════════════════════════════
# СОСТОЯНИЕ: ПАТРУЛЬ
# ══════════════════════════════════════════

func _ai_patrol(delta: float) -> void:
	# Сначала — доехать до ПОСЛЕДНЕЙ ИЗВЕСТНОЙ точки цели. Раньше при потере врага он мгновенно
	# уезжал на свои патрульные точки (они возле точки спавна), т.е. просто бросал бой и уходил
	# в сторону. Теперь он идёт туда, где видел игрока, и по дороге снова его засекает.
	if _has_last_known:
		if global_position.distance_to(_last_known_pos) > waypoint_reach_dist * 1.5:
			_drive_toward(_last_known_pos, chase_speed_factor, delta)
			return
		_has_last_known = false          # дошли — дальше обычный патруль
	if _patrol_targets.is_empty():
		_throttle = 0.0
		return

	var target_pos: Vector3 = _patrol_targets[_patrol_index]

	# Достигли точки — берём следующую сразу (не делаем return)
	if global_position.distance_to(target_pos) < waypoint_reach_dist:
		_patrol_index = (_patrol_index + 1) % _patrol_targets.size()
		target_pos    = _patrol_targets[_patrol_index]

	_drive_toward(target_pos, patrol_speed_factor, delta)

# ══════════════════════════════════════════
# СОСТОЯНИЕ: ПРЕСЛЕДОВАНИЕ
# ══════════════════════════════════════════

func _ai_chase(delta: float) -> void:
	if !is_instance_valid(_target):
		_lose_target()
		return

	var dist: float = global_position.distance_to(_target.global_position)
	_last_known_pos = _target.global_position
	_has_last_known = true

	if dist <= attack_range:
		_state = AIState.ATTACK
		return

	# Таймер забывания тикает ТОЛЬКО когда цель реально вне зоны обнаружения. Раньше он шёл
	# всегда, поэтому убегающего игрока враг бросал через 3 секунды, даже видя его в упор —
	# «уехал = проблем нет». Пока цель в радиусе — преследуем сколько нужно.
	if dist > detection_radius:
		_forget_timer -= delta
		if _forget_timer <= 0.0:
			_lose_target()
			return
	else:
		_forget_timer = forget_enemy_time

	# Стреляем и В ПОГОНЕ, если цель уже в пределах оружия: турель наводится сама (±45°),
	# так что ждать перехода в ATTACK незачем — иначе враг долго едет молча.
	if dist <= attack_range * 1.15:
		_do_attack()

	# Убегающего догоняем с небольшим бонусом к скорости, иначе при равном max_speed (20 у обоих)
	# догнать игрока невозможно в принципе — он просто уезжает.
	_drive_toward(_target.global_position, chase_speed_factor * chase_boost, delta)

# ══════════════════════════════════════════
# СОСТОЯНИЕ: АТАКА
# ══════════════════════════════════════════

func _ai_attack(delta: float) -> void:
	if !is_instance_valid(_target):
		_lose_target()
		return

	_forget_timer = forget_enemy_time

	var to_target := _target.global_position - global_position
	to_target.y = 0.0
	var dist := to_target.length()

	if dist > attack_range * 1.3:
		_state = AIState.CHASE
		return

	# Цель рядом — всегда стреляем. Турель сама целится в пределах своего конуса (±45°),
	# поэтому машине НЕ нужно утыкаться носом во врага — она может спокойно кружить.
	_do_attack()

	if dist < 0.01:
		_throttle = lerp(_throttle, 0.0, 3.0 * delta)
		return

	var to_n := to_target / dist
	var fwd_flat := Vector3(_get_forward().x, 0.0, _get_forward().z)
	if fwd_flat.length_squared() < 0.001:
		return
	fwd_flat = fwd_flat.normalized()

	# ── Бой: ДЕРЖИМ ДИСТАНЦИЮ, НЕ ТЕРЯЯ ЦЕЛЬ ИЗ ПРИЦЕЛА ─────────────────────────
	# Раньше здесь строилась «желаемая точка» в тылу цели: враг ехал ЗА спину игрока, а стоило
	# игроку повернуть — точка убегала на другую сторону, и враг снова катался вместо стрельбы.
	# Отсюда и «атаковал пару секунд, потом всё время меняет позицию». Теперь проще и злее:
	# нос всегда на цель (турель ±45° тогда всегда её достаёт), а газом только удерживаем
	# дистанцию в боевом коридоре. Боковой снос добавляем лёгким смещением прицела — враг
	# кружит, но НЕ перестаёт стрелять.
	var band_near := maxf(min_combat_distance, 3.0)      # ближе — сдаём назад
	var band_far := attack_range * 0.8                   # дальше — поджимаем
	if _orbit_dir == 0.0:
		_orbit_dir = 1.0 if randf() > 0.5 else -1.0
	var right_of_target := Vector3(to_n.z, 0.0, -to_n.x)  # перпендикуляр к линии на цель

	var steer_target: Vector3
	var target_throttle: float
	if dist < band_near:
		# Слишком близко: пятимся, но нос держим на цели — оружие продолжает работать.
		steer_target = to_n
		target_throttle = -0.3
	elif dist > band_far:
		# Далековато: сближаемся по прямой на цель.
		steer_target = to_n
		target_throttle = chase_speed_factor
	else:
		# В коридоре: идём по дуге вокруг цели (смесь «на цель» и «вбок») — сложнее попасть по
		# нам, но цель всё время в лобовом секторе, значит турель стреляет непрерывно.
		steer_target = (to_n + right_of_target * (_orbit_dir * 0.75)).normalized()
		target_throttle = chase_speed_factor * 0.55

	var steer_ang := fwd_flat.signed_angle_to(steer_target, Vector3.UP)
	var steer_input := clampf(steer_ang / (PI * 0.6), -1.0, 1.0)
	var speed_ratio := clampf(linear_velocity.length() / max_speed, 0.0, 1.0)
	var angle_limit := deg_to_rad(steer_max_angle) * (1.0 - speed_steer_reduction * speed_ratio)
	_steer_angle = lerp(_steer_angle, steer_input * angle_limit + _obstacle_correction, steer_speed * delta)
	_throttle = lerp(_throttle, target_throttle, 3.0 * delta)

# ══════════════════════════════════════════
# СОСТОЯНИЕ: ВОССТАНОВЛЕНИЕ ПОСЛЕ ЗАСТРЕВАНИЯ
# ══════════════════════════════════════════

func _ai_stuck_recovery(delta: float) -> void:
	_stuck_recovery_timer -= delta

	# Едем в обратную сторону и рулим
	_throttle    = lerp(_throttle, _stuck_drive_dir * 0.8, 6.0 * delta)
	var speed_ratio: float = clamp(linear_velocity.length() / max_speed, 0.0, 1.0)
	var angle_limit: float = deg_to_rad(steer_max_angle) * (1.0 - speed_steer_reduction * speed_ratio)
	_steer_angle = lerp(_steer_angle, angle_limit * 0.7 * sign(_stuck_drive_dir), steer_speed * delta)

	if _stuck_recovery_timer <= 0.0:
		_stuck_timer     = 0.0
		_stuck_check_pos = global_position

		# Возвращаемся в предыдущее состояние
		if _state_before_stuck == AIState.CHASE or _state_before_stuck == AIState.ATTACK:
			if is_instance_valid(_target):
				_state = _state_before_stuck
				return
		_patrol_index = _nearest_patrol_index()
		_state        = AIState.PATROL

# ══════════════════════════════════════════
# ПРОВЕРКА ЗАСТРЕВАНИЯ
# ══════════════════════════════════════════

func _check_stuck(delta: float) -> void:
	if _state == AIState.STUCK_RECOVERY:
		return

	_stuck_timer += delta
	if _stuck_timer < _stuck_check_interval:
		return

	_stuck_timer = 0.0
	var moved: float = global_position.distance_to(_stuck_check_pos)
	_stuck_check_pos = global_position

	if abs(_throttle) > 0.15 and moved < 0.5:
		_state_before_stuck    = _state
		_state                 = AIState.STUCK_RECOVERY
		_stuck_recovery_timer  = _stuck_recovery_duration
		_stuck_drive_dir       = -sign(_throttle) if abs(_throttle) > 0.01 else -1.0

# ══════════════════════════════════════════
# ОБНАРУЖЕНИЕ ПРЕПЯТСТВИЙ
# Лучи смотрят в направлении движения (вперёд ИЛИ назад)
# ══════════════════════════════════════════

# Троттл + переиспользуемый объект запроса. Раньше это шло КАЖДЫЙ физ-тик и на каждом вызове
# рождало массив dirs, массив hit и ТРИ новых PhysicsRayQueryParameters3D с новым [self]:
# ~3 луча + ~11 аллокаций на врага за тик (при 9 врагах ≈1600 лучей и 5900 аллокаций в секунду).
# Препятствия — вещь инерционная, 10 Гц достаточно; сглаживание ниже осталось прежним, поэтому
# руль ведёт себя так же плавно. Между опросами применяем последний результат.
const OBSTACLE_HZ := 0.1
var _obst_t: float = 0.0
var _obst_q: PhysicsRayQueryParameters3D = null
var _obstacle_correction_target: float = 0.0

func _detect_obstacles(delta: float = 0.0) -> void:
	_obst_t -= delta
	if _obst_t <= 0.0:
		_obst_t = OBSTACLE_HZ
		var space: PhysicsDirectSpaceState3D = get_world_3d().direct_space_state
		var origin: Vector3 = global_position + Vector3.UP * 0.5
		# Если едем назад — лучи тоже назад
		var ray_fwd: Vector3 = _get_forward() if _throttle >= 0.0 else -_get_forward()
		var ang_rad: float = deg_to_rad(obstacle_ray_angle)
		if _obst_q == null:
			_obst_q = PhysicsRayQueryParameters3D.new()
			_obst_q.exclude = [self]
			_obst_q.collision_mask = 1
		var hit_l := _ray_hits(space, origin, ray_fwd.rotated(Vector3.UP, -ang_rad))  # левый
		var hit_c := _ray_hits(space, origin, ray_fwd)                                # центр
		var hit_r := _ray_hits(space, origin, ray_fwd.rotated(Vector3.UP,  ang_rad))  # правый
		var correction: float = 0.0
		if   hit_l and !hit_r: correction = -0.5   # объект слева → уходим вправо
		elif hit_r and !hit_l: correction =  0.5   # объект справа → уходим влево
		elif hit_c:            correction =  0.5 * (1.0 if randf() > 0.5 else -1.0)
		_obstacle_correction_target = correction * deg_to_rad(steer_max_angle)
	_obstacle_correction = lerp(_obstacle_correction, _obstacle_correction_target, 0.15)

func _ray_hits(space: PhysicsDirectSpaceState3D, origin: Vector3, dir: Vector3) -> bool:
	_obst_q.from = origin
	_obst_q.to = origin + dir * obstacle_ray_length
	return not space.intersect_ray(_obst_q).is_empty()

# ══════════════════════════════════════════
# ДВИЖЕНИЕ К ТОЧКЕ
# ══════════════════════════════════════════

func _drive_toward(target_pos: Vector3, speed_factor: float, delta: float) -> void:
	var to_target: Vector3 = target_pos - global_position
	to_target.y   = 0.0
	if to_target.length_squared() < 0.001:
		return

	var target_dir: Vector3 = to_target.normalized()

	var fwd_flat: Vector3 = Vector3(_get_forward().x, 0.0, _get_forward().z)
	if fwd_flat.length_squared() < 0.001:
		return
	fwd_flat = fwd_flat.normalized()

	# Знаковый угол: отрицательный = цель справа, положительный = цель слева
	var angle_to_target: float = fwd_flat.signed_angle_to(target_dir, Vector3.UP)

	# steer_input < 0 → нос едет вправо (steer_angle < 0 → target_yaw < 0 → CW = право)
	var steer_input: float = clamp(angle_to_target / PI, -1.0, 1.0)
	var speed_ratio: float = clamp(linear_velocity.length() / max_speed, 0.0, 1.0)
	var angle_limit: float = deg_to_rad(steer_max_angle) * (1.0 - speed_steer_reduction * speed_ratio)
	_steer_angle    = lerp(_steer_angle, steer_input * angle_limit + _obstacle_correction, steer_speed * delta)

	# Газ: снижаем на резком повороте, минимум 0.4 чтобы машина всегда набирала скорость
	var turn_factor: float = clamp(1.0 - abs(angle_to_target) / PI, 0.4, 1.0)
	_throttle       = lerp(_throttle, speed_factor * turn_factor, 4.0 * delta)

# ══════════════════════════════════════════
# ВСПОМОГАТЕЛЬНЫЕ
# ══════════════════════════════════════════

# Кеш стреляющих блоков: теперь зовётся каждый физ-тик и в бою, и в погоне, поэтому
# get_children()+has_method на каждом вызове здесь недопустимы (см. тот же приём у игрока).
var _atk_cache: Array = []
var _atk_n: int = -1

func _do_attack() -> void:
	var bl := get_node_or_null("blocks")
	if bl == null:
		return
	if bl.get_child_count() != _atk_n:
		_atk_n = bl.get_child_count()
		_atk_cache.clear()
		for b in bl.get_children():
			if b.has_method("attack"):
				_atk_cache.append(b)
	for b in _atk_cache:
		b.attack()

func _lose_target() -> void:
	_target       = null
	_orbit_dir    = 0.0   # следующий бой выберет сторону объезда заново
	_patrol_index = _nearest_patrol_index()
	_state        = AIState.PATROL

func _nearest_patrol_index() -> int:
	var best_i: int = 0
	var best_dist: float = INF
	for i in _patrol_targets.size():
		var d: float = global_position.distance_to(_patrol_targets[i])
		if d < best_dist:
			best_dist = d
			best_i    = i
	return best_i

func _is_enemy(body: Node) -> bool:
	if body == self: return false
	var f = body.get("faction")
	if f == null: return false
	return f != faction

# ══════════════════════════════════════════
# СИГНАЛЫ AREA3D
# ══════════════════════════════════════════

func _on_body_entered(body: Node) -> void:
	if !_is_enemy(body): return
	var body3d: Node3D = body as Node3D
	if !is_instance_valid(_target):
		_target       = body3d
		_forget_timer = forget_enemy_time
		_state        = AIState.CHASE
	else:
		var d_new: float = global_position.distance_to(body3d.global_position)
		var d_cur: float = global_position.distance_to(_target.global_position)
		if d_new < d_cur:
			_target = body3d
			_forget_timer = forget_enemy_time

func _on_body_exited(body: Node) -> void:
	if body == _target:
		_forget_timer = forget_enemy_time

# ══════════════════════════════════════════
# ФИЗИКА — ЗЕМЛЯ
# ══════════════════════════════════════════

func _check_ground() -> void:
	var space: PhysicsDirectSpaceState3D = get_world_3d().direct_space_state
	var q: PhysicsRayQueryParameters3D = PhysicsRayQueryParameters3D.create(
		global_position,
		global_position + Vector3.DOWN * 1.4
	)
	q.exclude        = [self]
	q.collision_mask = 1
	_on_ground = space.intersect_ray(q).size() > 0

# ══════════════════════════════════════════
# ФИЗИКА — МАССА
# ══════════════════════════════════════════

# Как у игрока: масса зависит только от НАБОРА колёс (вес колеса — константный @export), поэтому
# пересчитываем при смене их числа и раз в 0.5с, а не каждый физ-тик. Раньше на каждое колесо
# рождался Dictionary из get_module_data() — 6 колёс × 60 Гц × 9 врагов ≈ 3200 аллокаций/с.
var _mass_wheels_n: int = -1
var _mass_timer: float = 0.0

# Блоки, принимающие газ/руль (колёса). Кеш инвалидируется по числу детей $blocks.
var _drive_cache: Array = []
var _drive_n: int = -1

func _drive_blocks() -> Array:
	var bl := get_node_or_null("blocks")
	if bl == null:
		return []
	if bl.get_child_count() != _drive_n:
		_drive_n = bl.get_child_count()
		_drive_cache.clear()
		for b in bl.get_children():
			if b.has_method("set_throttle") and b.has_method("set_steer"):
				_drive_cache.append(b)
	return _drive_cache

func _sync_mass(delta: float = 0.0) -> void:
	_mass_timer -= delta
	if Wheels.size() == _mass_wheels_n and _mass_timer > 0.0:
		return
	_mass_wheels_n = Wheels.size()
	_mass_timer = 0.5
	var total: float = base_weight
	for w in Wheels:
		if is_instance_valid(w):
			total += float(w.weight)
	mass = total

# ══════════════════════════════════════════
# ФИЗИКА — ДВИГАТЕЛЬ
# ══════════════════════════════════════════

func _apply_engine(delta: float) -> void:
	var fwd: Vector3 = _get_forward()
	var vel_fwd: float = fwd.dot(linear_velocity)

	if abs(_throttle) > 0.01:
		var sf: float = clamp(1.0 - abs(vel_fwd) / max_speed, 0.05, 1.0)
		apply_central_force(fwd * _throttle * engine_force * mass * sf)
	elif abs(vel_fwd) > 0.1:
		apply_central_force(-fwd * vel_fwd * engine_brake * mass)

# ══════════════════════════════════════════
# ФИЗИКА — СЦЕПЛЕНИЕ
# ══════════════════════════════════════════

func _apply_grip(delta: float) -> void:
	var right: Vector3 = _get_right()
	var fwd: Vector3 = _get_forward()
	var vel_lat: float = right.dot(linear_velocity)
	apply_central_force(-right * vel_lat * lateral_grip * mass)
	var vel_fwd: float = fwd.dot(linear_velocity)
	if abs(_throttle) < 0.01 and abs(vel_fwd) > 0.05:
		apply_central_force(-fwd * vel_fwd * longitudinal_grip * mass)

# ══════════════════════════════════════════
# ФИЗИКА — ПОВОРОТ
# ══════════════════════════════════════════

func _apply_steering(delta: float) -> void:
	var fwd: Vector3 = _get_forward()
	var vel_fwd: float = fwd.dot(linear_velocity)

	if abs(vel_fwd) < 0.3:
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
# ФИЗИКА — КРЕН
# ══════════════════════════════════════════

func _apply_anti_roll(delta: float) -> void:
	var local_av: Vector3 = global_transform.basis.inverse() * angular_velocity
	var correction: Vector3 = global_transform.basis * Vector3(
		-local_av.x * anti_roll, 0.0, -local_av.z * anti_roll
	)
	apply_torque(correction * mass * delta)

# ══════════════════════════════════════════
# ФИЗИКА — ВЕРТИКАЛЬ
# ══════════════════════════════════════════

func _apply_upright(delta: float) -> void:
	var up: Vector3 = _get_up()
	var dot: float = up.dot(Vector3.UP)
	if dot >= 0.85: return
	var axis: Vector3 = up.cross(Vector3.UP)
	if axis.length_squared() < 0.0001: return
	axis = axis.normalized()
	apply_torque(axis * acos(clamp(dot, -1.0, 1.0)) * upright_strength * mass * delta)

# ══════════════════════════════════════════
# ФИЗИКА — ЛИМИТ СКОРОСТИ
# ══════════════════════════════════════════

func _limit_speed() -> void:
	var fwd: Vector3 = _get_forward()
	var vel_fwd: float = fwd.dot(linear_velocity)
	# В ПОГОНЕ потолок скорости выше: у врага и игрока max_speed одинаковый (20), поэтому с общим
	# лимитом догнать убегающего невозможно математически — он всегда отрывается. В бою/патруле
	# лимит обычный, так что вне погони враг не становится быстрее.
	var cap: float = max_speed * (chase_boost if _state == AIState.CHASE else 1.0)
	if abs(vel_fwd) > cap:
		linear_velocity -= fwd * (vel_fwd - sign(vel_fwd) * cap)
	if linear_velocity.y > 10.0:
		linear_velocity.y = 10.0

# ══════════════════════════════════════════
# ФИЗИКА — БАЗА КОЛЁС
# ══════════════════════════════════════════

func _get_wheelbase() -> float:
	var front_z: float = -INF
	var rear_z: float = INF
	var has_f: bool = false
	var has_r: bool = false
	for w in Wheels:
		if !is_instance_valid(w): continue
		var lz: float = to_local(w.global_position).z
		if w.is_front: front_z = max(front_z, lz); has_f = true
		else:          rear_z  = min(rear_z,  lz); has_r = true
	if has_f and has_r:
		return max(abs(front_z - rear_z), 0.5)
	return 2.0

func append_wheel(wheel: Node) -> void:
	if !Wheels.has(wheel): Wheels.append(wheel)

func erase_wheel(wheel: Node) -> void:
	Wheels.erase(wheel)
