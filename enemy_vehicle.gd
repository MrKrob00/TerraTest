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
@export var forget_enemy_time:   float = 3.0

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
	_sync_mass()
	_update_ai(delta)
	_detect_obstacles()

	if _on_ground:
		_apply_engine(delta)
		_apply_grip(delta)
		_apply_steering(delta)
		_apply_anti_roll(delta)
	_apply_upright(delta)
	_limit_speed()

	for block in $blocks.get_children():
		if block.has_method("set_throttle"): block.set_throttle(_throttle)
		if block.has_method("set_steer"):
			block.set_steer(-_steer_angle / deg_to_rad(steer_max_angle))

# ══════════════════════════════════════════
# ИИ — ДИСПЕТЧЕР
# ══════════════════════════════════════════

func _update_ai(delta: float) -> void:
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

	if dist <= attack_range:
		_state = AIState.ATTACK
		return

	_forget_timer -= delta
	if _forget_timer <= 0.0:
		_lose_target()
		return

	_drive_toward(_target.global_position, chase_speed_factor, delta)

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

	# ── «2D-карта» цели: где она и КУДА СМОТРИТ (там её оружие/лоб) ──────────────
	# Перёд цели = -Z её базиса (как и у нас). Зная это, заходим в РЕАР-фланг —
	# вне её лобового конуса — а не лезем в лоб под выстрелы.
	var tb := _target.global_transform.basis
	var enemy_fwd := Vector3(-tb.z.x, 0.0, -tb.z.z)
	if enemy_fwd.length_squared() < 0.0001:
		enemy_fwd = -to_n
	enemy_fwd = enemy_fwd.normalized()
	var enemy_right := Vector3(enemy_fwd.z, 0.0, -enemy_fwd.x)   # правый борт цели

	# Заходим на тот фланг цели, что сейчас ближе (выбираем один раз за бой).
	if _orbit_dir == 0.0:
		_orbit_dir = 1.0 if enemy_right.dot(-to_n) >= 0.0 else -1.0

	# Желаемая позиция: боевая дистанция, СЗАДИ-сбоку от цели. Точка рядом с целью →
	# мы едем примерно НА неё, цель остаётся спереди → турель (±45°) её держит. Цель
	# крутится → точка ездит за её спиной → мы обходим и переигрываем по манёвру.
	var radius := maxf(min_combat_distance, 3.0)
	var desired_pos := _target.global_position \
			- enemy_fwd * (radius * 0.7) \
			+ enemy_right * (_orbit_dir * radius * 0.85)
	var to_desired := Vector3(desired_pos.x - global_position.x, 0.0, desired_pos.z - global_position.z)
	var arrive := to_desired.length()

	# Куда рулим и сколько газу.
	var steer_target: Vector3
	var target_throttle: float
	if dist < radius * 0.5:
		steer_target = to_n          # вплотную к цели — нос на неё, сдаём назад (турель целится)
		# Было -0.5 — резкий реверс на ходу (только что гнались на полном газу) часто
		# опрокидывал машину носом вперёд, особенно с оружием на y=1 (выше центр масс).
		target_throttle = -0.25
	elif arrive < 1.5:
		steer_target = to_n          # на позиции — держим цель в прицеле, почти стоим
		target_throttle = 0.15
	else:
		steer_target = to_desired / arrive
		var ang := absf(fwd_flat.signed_angle_to(steer_target, Vector3.UP))
		target_throttle = chase_speed_factor * clampf(1.0 - ang / PI, 0.35, 1.0)

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

func _detect_obstacles() -> void:
	var space: PhysicsDirectSpaceState3D = get_world_3d().direct_space_state
	var origin: Vector3 = global_position + Vector3.UP * 0.5

	# Если едем назад — лучи тоже назад
	var ray_fwd: Vector3 = _get_forward() if _throttle >= 0.0 else -_get_forward()
	var ang_rad: float = deg_to_rad(obstacle_ray_angle)

	var dirs: Array[Vector3] = [
		ray_fwd.rotated(Vector3.UP, -ang_rad),  # 0 = левый  (для +Z перёд: CW = влево)
		ray_fwd,                                 # 1 = центр
		ray_fwd.rotated(Vector3.UP,  ang_rad),  # 2 = правый (для +Z перёд: CCW = вправо)
	]

	var hit: Array[bool] = [false, false, false]
	for i in 3:
		var q: PhysicsRayQueryParameters3D = PhysicsRayQueryParameters3D.create(origin, origin + dirs[i] * obstacle_ray_length)
		q.exclude       = [self]
		q.collision_mask = 1
		if space.intersect_ray(q).size() > 0:
			hit[i] = true

	var correction: float = 0.0
	if   hit[0] and !hit[2]: correction = -0.5   # объект слева → уходим вправо
	elif hit[2] and !hit[0]: correction =  0.5   # объект справа → уходим влево
	elif hit[1]:              correction =  0.5 * (1.0 if randf() > 0.5 else -1.0)

	_obstacle_correction = lerp(_obstacle_correction, correction * deg_to_rad(steer_max_angle), 0.15)

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

func _do_attack() -> void:
	for block in $blocks.get_children():
		if block.has_method("attack"): block.attack()

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

func _sync_mass() -> void:
	var total: float = base_weight
	for w in Wheels:
		if is_instance_valid(w):
			total += w.get_module_data()["weight"]
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
	if abs(vel_fwd) > max_speed:
		linear_velocity -= fwd * (vel_fwd - sign(vel_fwd) * max_speed)
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
