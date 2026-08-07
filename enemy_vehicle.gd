extends MachineBody

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
## «Невідступний»: цель, назначенная при спавне (напр. отряд от проверки сектора), НИКОГДА не
## забывается и не меняется — такой враг ведёт её через всю карту, сколько бы она ни убегала.
@export var relentless:          bool = false

@export_group("ИИ — Препятствия")
## Дальность лучей контекстной карты. Углы больше не задаются: направления берутся
## из 16 секторов ContextSteering, а не из пары «влево/вправо на N градусов».
@export var obstacle_ray_length: float = 5.0

# ══════════════════════════════════════════
# СОСТОЯНИЯ
# ══════════════════════════════════════════

# Поведение выбирает EnemyBrain по полезности — жёсткой машины состояний больше нет.
var _act: int = EnemyBrain.Act.PATROL
var _percept: Dictionary = {}
var _decide_t: float = 0.0
const DECIDE_PERIOD: float = 0.15        # переоценка обстановки ~7 раз в секунду

var _target:       Node3D  = null
var _forget_timer: float   = 0.0

var _patrol_targets: Array[Vector3] = []
var _patrol_index:   int   = 0
var _start_pos:      Vector3

# Локальная навигация: контекстная карта вместо трёх лучей с доворотом.
var _steering: ContextSteering = ContextSteering.new()
var _ctx_t: float = 0.0
var _obst_q: PhysicsRayQueryParameters3D = null

# Замер застревания
var _stuck01: float = 0.0
var _move_ref: Vector3 = Vector3.ZERO
var _move_t: float = 0.0

# Самокалибровка подвижности: сколько колёс было в лучшие времена.
var _wheels_peak: int = 1

# ══════════════════════════════════════════
# ИНИЦИАЛИЗАЦИЯ
# ══════════════════════════════════════════

func _ready() -> void:
	mass          = base_weight
	# Врагу нужны свои значения, а не игроковские: ИИ не контр-рулит при опрокидывании,
	# поэтому запас устойчивости больше, а порог руля выше — иначе он дёргает рулём,
	# почти остановившись. Сборки врагов к тому же часто кладут оружие на y=1.
	anti_roll = 8.0
	upright_strength = 15.0
	steer_min_speed = 0.3
	init_machine_physics()
	linear_damp   = 0.0
	angular_damp  = 4.0

	_start_pos = global_position
	_move_ref  = global_position

	_setup_detection_area()
	_setup_patrol_points()
	_connect_cabin()

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

# В ПОГОНЕ потолок скорости выше: у врага и игрока max_speed одинаковый, поэтому с общим
# лимитом догнать убегающего невозможно математически — он всегда отрывается. В бою и
# патруле лимит обычный, так что вне погони враг быстрее не становится.
func _speed_cap() -> float:
	return max_speed * (chase_boost if _act == EnemyBrain.Act.PURSUE else 1.0)

func _physics_process(delta: float) -> void:
	sense_ground(delta)
	# Перевернулся — включаем тот же приём, что у игрока в СТРОЙКЕ: приподнимаем над рельефом и
	# плавно доворачиваем «ровно». _apply_upright сам по себе перевёрнутую машину на колёсах часто
	# не поднимает (крутящий момент упирается в землю), и враг оставался лежать навсегда.
	if _flip_recover(delta):
		return                    # пока встаём — ИИ и обычная физика движения не мешают
	_update_ai(delta)
	drive_physics(delta)
	push_drive_input(-_steer_angle / deg_to_rad(steer_max_angle))

# ══════════════════════════════════════════
# ИИ — ДИСПЕТЧЕР
# ══════════════════════════════════════════

var _detect_area: Area3D = null
var _reacquire_t: float = 0.0
var _last_known_pos: Vector3 = Vector3.ZERO
var _has_last_known: bool = false

# Назначить цель ИЗВНЕ (отряд от проверки сектора). Спавнер раньше писал приватные поля напрямую
# и ставил номер состояния числом — при любой правке enum это молча ломалось бы.
func assign_target(t: Node3D, never_forget: bool = false) -> void:
	if t == null or not is_instance_valid(t):
		return
	_target = t
	_forget_timer = forget_enemy_time
	_act = EnemyBrain.Act.PURSUE
	relentless = never_forget

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

func _update_ai(delta: float) -> void:
	# Цель периодически пере-ищется, пока её нет.
	_reacquire_t -= delta
	if _reacquire_t <= 0.0:
		_reacquire_t = 0.3
		if not is_instance_valid(_target):
			_scan_for_targets()

	# Забывание: внутри радиуса обнаружения цель не забывается никогда, снаружи — по
	# таймеру. Невідступный не забывает вообще.
	if is_instance_valid(_target):
		if global_position.distance_to(_target.global_position) > detection_radius and not relentless:
			_forget_timer -= delta
			if _forget_timer <= 0.0:
				_lose_target()
		else:
			_forget_timer = forget_enemy_time
	elif _target != null:
		_target = null

	_update_stuck(delta)

	# Обстановка переоценивается несколько раз в секунду, а не каждый физкадр: решение
	# всё равно меняется медленнее, а замеры (HP, огневая мощь, линия огня) не бесплатны.
	_decide_t -= delta
	if _decide_t <= 0.0:
		_decide_t = DECIDE_PERIOD
		_percept = _sense()
		_act = EnemyBrain.decide(_percept, _act)

	match _act:
		EnemyBrain.Act.PATROL:      _act_patrol(delta)
		EnemyBrain.Act.INVESTIGATE: _act_investigate(delta)
		EnemyBrain.Act.PURSUE:      _act_pursue(delta)
		EnemyBrain.Act.ENGAGE:      _act_engage(delta)
		EnemyBrain.Act.FLANK:       _act_flank(delta)
		EnemyBrain.Act.RETREAT:     _act_retreat(delta)
		EnemyBrain.Act.UNSTICK:     _act_unstick(delta)

# ══════════════════════════════════════════
# ВОСПРИЯТИЕ
# ══════════════════════════════════════════

const NO_TARGET_DIST: float = 1.0e6

func _sense() -> Dictionary:
	var has_t: bool = is_instance_valid(_target)
	var dist: float = NO_TARGET_DIST
	var facing: float = 0.0
	var los: bool = false
	if has_t:
		var to_us: Vector3 = global_position - _target.global_position
		to_us.y = 0.0
		dist = to_us.length()
		_last_known_pos = _target.global_position
		_has_last_known = true
		if dist > 0.01:
			var t_fwd: Vector3 = -_target.global_transform.basis.z
			t_fwd.y = 0.0
			if t_fwd.length_squared() > 0.0001:
				facing = clampf(t_fwd.normalized().dot(to_us.normalized()), 0.0, 1.0)
		los = _has_line_of_sight(_target)

	# Подвижность самокалибруется: запоминаем, сколько колёс было в лучшие времена, и
	# сравниваем с текущим. Не нужно ловить момент сборки машины.
	_wheels_peak = maxi(_wheels_peak, _wheel_count)
	var wheels01: float = float(_wheel_count) / float(maxi(_wheels_peak, 1))

	return {
		"has_target": has_t,
		"has_memory": _has_last_known,
		"dist": dist,
		"range": _own_weapon_range(),
		"health": _health01(),
		"mobility": clampf(wheels01 * _contact_ratio(), 0.0, 1.0),
		"power_ratio": _power_ratio(),
		"los": los,
		"stuck": _stuck01,
		"facing_us": facing,
	}

func _health01() -> float:
	var bl: Node = get_node_or_null("blocks")
	if bl == null:
		return 1.0
	var cur: float = 0.0
	var mx: float = 0.0
	for b in bl.get_children():
		if b is VehicleBlock:
			cur += float((b as VehicleBlock).current_hp)
			mx += float((b as VehicleBlock).max_hp)
	return clampf(cur / mx, 0.0, 1.0) if mx > 0.0 else 1.0

# Эффективная дальность = дальность лучшего своего ствола. Раньше это был экспорт
# attack_range, не связанный с тем, чем машина реально вооружена.
func _own_weapon_range() -> float:
	var r: float = 0.0
	for b in _weapon_blocks():
		if not is_instance_valid(b):
			continue
		var wr: Variant = b.get("weapon_range")
		if wr != null:
			r = maxf(r, float(wr))
	return r if r > 0.5 else attack_range

# Грубый урон в секунду по блокам машины — для сравнения «кто кого перестреляет».
static func _firepower_of(machine: Node) -> float:
	var bl: Node = machine.get_node_or_null("blocks")
	if bl == null:
		return 0.0
	var p: float = 0.0
	for b in bl.get_children():
		var dmg: Variant = b.get("damage")
		var rate: Variant = b.get("fire_rate")
		if dmg != null and rate != null and float(rate) > 0.001:
			p += float(dmg) / float(rate)
	return p

func _power_ratio() -> float:
	if not is_instance_valid(_target):
		return 0.5
	var mine: float = _firepower_of(self)
	var total: float = mine + _firepower_of(_target)
	return 0.5 if total < 0.001 else clampf(mine / total, 0.0, 1.0)

var _los_q: PhysicsRayQueryParameters3D = null

func _has_line_of_sight(t: Node3D) -> bool:
	if _los_q == null:
		_los_q = PhysicsRayQueryParameters3D.new()
		_los_q.collision_mask = 1        # только рельеф: чужие блоки укрытием не считаем
	_los_q.exclude = [self, t]
	_los_q.from = global_position + Vector3.UP
	_los_q.to = t.global_position + Vector3.UP
	return get_world_3d().direct_space_state.intersect_ray(_los_q).is_empty()

# Застревание — это «командую ехать, а не еду». Плавная величина, а не флаг: растёт,
# пока машина стоит под газом, и падает, как только поехала. Отдельного режима
# восстановления с таймером больше нет, решение принимает та же оценка полезности.
const STUCK_WINDOW: float = 1.2
const STUCK_MIN_MOVE: float = 0.8

func _update_stuck(delta: float) -> void:
	_move_t += delta
	if _move_t < STUCK_WINDOW:
		return
	_move_t = 0.0
	var moved: float = global_position.distance_to(_move_ref)
	_move_ref = global_position
	if absf(_throttle) > 0.15 and moved < STUCK_MIN_MOVE:
		_stuck01 = minf(1.0, _stuck01 + 0.5)
	else:
		_stuck01 = maxf(0.0, _stuck01 - 0.5)

# ══════════════════════════════════════════
# ПОВЕДЕНИЯ
# ══════════════════════════════════════════

func _act_patrol(delta: float) -> void:
	if _patrol_targets.is_empty():
		_drive(_get_forward(), 0.0, delta)
		return
	var goal: Vector3 = _patrol_targets[_patrol_index]
	if global_position.distance_to(goal) < waypoint_reach_dist:
		_patrol_index = (_patrol_index + 1) % _patrol_targets.size()
		goal = _patrol_targets[_patrol_index]
	_drive_to(goal, patrol_speed_factor, delta)

func _act_investigate(delta: float) -> void:
	if not _has_last_known:
		_act_patrol(delta)
		return
	if global_position.distance_to(_last_known_pos) < waypoint_reach_dist:
		_has_last_known = false          # дошли, никого нет — обратно к патрулю
		return
	_drive_to(_last_known_pos, chase_speed_factor, delta)

func _act_pursue(delta: float) -> void:
	if not is_instance_valid(_target):
		return
	# Турель наводится сама в своём конусе, поэтому стреляем на ходу, не дожидаясь боя.
	if float(_percept.get("dist", NO_TARGET_DIST)) <= _own_weapon_range() * 1.15:
		_do_attack()
	_drive_to(_target.global_position, chase_speed_factor, delta)

func _act_engage(delta: float) -> void:
	if not is_instance_valid(_target):
		return
	_do_attack()
	var to_t: Vector3 = _target.global_position - global_position
	to_t.y = 0.0
	var dist: float = to_t.length()
	if dist < 0.01:
		return
	var dir: Vector3 = to_t / dist
	var rng: float = _own_weapon_range()
	var band_near: float = maxf(min_combat_distance, rng * 0.35)
	var band_far: float = rng * 0.85

	if dist < band_near:
		_drive(dir, -0.35, delta)                       # пятимся, нос держим на цели
	elif dist > band_far:
		_drive(dir, chase_speed_factor, delta)          # поджимаем
	else:
		# В коридоре идём по дуге. Сторона выбирается по той, на которой уже находимся,
		# а не жребием: случайный выбор бросал врага поперёк собственной линии огня.
		var side: Vector3 = Vector3(dir.z, 0.0, -dir.x)
		var sgn: float = signf(side.dot(_get_forward()))
		if absf(sgn) < 0.01:
			sgn = 1.0
		_drive((dir + side * (sgn * 0.75)).normalized(), chase_speed_factor * 0.6, delta)

func _act_flank(delta: float) -> void:
	if not is_instance_valid(_target):
		return
	_do_attack()
	# Уходим из лобового сектора цели, оставаясь в своём: точка сбоку-сзади от неё, с той
	# стороны, где мы уже находимся, чтобы не пересекать линию её огня.
	var t_fwd: Vector3 = -_target.global_transform.basis.z
	t_fwd.y = 0.0
	if t_fwd.length_squared() < 0.0001:
		_act_engage(delta)
		return
	t_fwd = t_fwd.normalized()
	var t_right: Vector3 = Vector3(t_fwd.z, 0.0, -t_fwd.x)
	var to_us: Vector3 = global_position - _target.global_position
	to_us.y = 0.0
	var sgn: float = signf(t_right.dot(to_us))
	if absf(sgn) < 0.01:
		sgn = 1.0
	var rng: float = maxf(_own_weapon_range() * 0.7, min_combat_distance)
	var spot: Vector3 = _target.global_position + t_right * (sgn * rng) - t_fwd * (rng * 0.3)
	_drive_to(spot, chase_speed_factor * 0.9, delta)

func _act_retreat(delta: float) -> void:
	_do_attack()                                        # турели работают и на отходе
	var away: Vector3 = global_position - _last_known_pos
	if is_instance_valid(_target):
		away = global_position - _target.global_position
	away.y = 0.0
	if away.length_squared() < 0.0001:
		away = _get_forward()
	_drive(away.normalized(), chase_speed_factor, delta)

func _act_unstick(delta: float) -> void:
	# Задний ход, но направление выбирает та же контекстная карта — она видит, где сзади
	# свободно. Фиксированного «пятиться 2 секунды и рулить вбок» больше нет.
	_drive(_get_forward(), -0.7, delta)

# ══════════════════════════════════════════
# ДВИЖЕНИЕ ЧЕРЕЗ КОНТЕКСТНУЮ КАРТУ
# ══════════════════════════════════════════

func _drive_to(pos: Vector3, speed: float, delta: float) -> void:
	var to: Vector3 = pos - global_position
	to.y = 0.0
	if to.length_squared() < 0.0001:
		return
	_drive(to.normalized(), speed, delta)

# nose_dir — куда хотим смотреть, speed — знаковая скорость (минус = задний ход).
func _drive(nose_dir: Vector3, speed: float, delta: float) -> void:
	var travel: Vector3 = nose_dir if speed >= 0.0 else -nose_dir
	_refresh_context(travel, delta)
	var safe: Vector3 = _steering.choose(travel)
	var aim: Vector3 = safe if speed >= 0.0 else -safe

	var fwd: Vector3 = Vector3(_get_forward().x, 0.0, _get_forward().z)
	if fwd.length_squared() < 0.0001:
		return
	fwd = fwd.normalized()

	var ang: float = fwd.signed_angle_to(aim, Vector3.UP)
	var steer_input: float = clampf(ang / PI, -1.0, 1.0)
	var speed_ratio: float = clampf(linear_velocity.length() / max_speed, 0.0, 1.0)
	var angle_limit: float = deg_to_rad(steer_max_angle) * (1.0 - speed_steer_reduction * speed_ratio)
	_steer_angle = lerp(_steer_angle, steer_input * angle_limit, steer_speed * delta)

	# На резком повороте сбрасываем газ, но не в ноль — иначе машина не доворачивает.
	var turn_factor: float = clampf(1.0 - absf(ang) / PI, 0.4, 1.0)
	_throttle = lerp(_throttle, speed * turn_factor, 4.0 * delta)

const CTX_PERIOD: float = 0.12
const PROBE_NEAR: float = 3.0
const PROBE_FAR: float = 7.0
const MAX_CLIMB: float = 2.5     # подъём круче этого машина не вытянет
const MAX_DROP: float = 3.5      # спуск круче этого — обрыв, туда не едем

func _refresh_context(travel: Vector3, delta: float) -> void:
	_ctx_t -= delta
	if _ctx_t <= 0.0:
		_ctx_t = CTX_PERIOD
		_sample_danger()
	_steering.clear_interest()
	_steering.seek(travel)

# Опасность по всем 16 направлениям. Рельеф считается математикой (terrain_height_at,
# без физики) — поэтому щупаем все стороны; лучами проверяем каждую вторую, этого хватает,
# а стоят они куда дороже.
func _sample_danger() -> void:
	_steering.clear_danger()
	var terr: Node = _find_terrain()
	var space: PhysicsDirectSpaceState3D = get_world_3d().direct_space_state
	if _obst_q == null:
		_obst_q = PhysicsRayQueryParameters3D.new()
		_obst_q.exclude = [self]
		_obst_q.collision_mask = 1
	var here: float = global_position.y
	var origin: Vector3 = global_position + Vector3.UP * 0.5

	for i in ContextSteering.SLOTS:
		var d: Vector3 = _steering.direction(i)
		if terr != null:
			var h_near: float = terr.terrain_height_at(global_position + d * PROBE_NEAR)
			var h_far: float = terr.terrain_height_at(global_position + d * PROBE_FAR)
			var climb: float = maxf(h_near - here, h_far - here)
			var drop: float = maxf(here - h_near, here - h_far)
			if climb > MAX_CLIMB:
				_steering.set_danger(i, clampf(climb / (MAX_CLIMB * 2.0), 0.0, 1.0))
			if drop > MAX_DROP:
				_steering.set_danger(i, clampf(drop / (MAX_DROP * 2.0), 0.0, 1.0))
		if i % 2 == 0:
			_obst_q.from = origin
			_obst_q.to = origin + d * obstacle_ray_length
			var hit: Dictionary = space.intersect_ray(_obst_q)
			if not hit.is_empty():
				var dd: float = origin.distance_to(hit["position"])
				_steering.add_danger(d, clampf(1.0 - dd / obstacle_ray_length, 0.2, 1.0))

var _atk_cache: Array = []
var _atk_n: int = -1

# Кеш оружейных блоков: нужен и для стрельбы, и для оценки своей дальности/мощи.
func _weapon_blocks() -> Array:
	var bl := get_node_or_null("blocks")
	if bl == null:
		return []
	if bl.get_child_count() != _atk_n:
		_atk_n = bl.get_child_count()
		_atk_cache.clear()
		for b in bl.get_children():
			if b.has_method("attack"):
				_atk_cache.append(b)
	return _atk_cache

func _do_attack() -> void:
	for b in _weapon_blocks():
		if not is_instance_valid(b):
			_atk_n = -1                 # блок уничтожили — пересоберём кеш
			continue
		b.attack()

func _lose_target() -> void:
	if relentless and is_instance_valid(_target):
		return                      # невідступный цель не бросает
	_target       = null
	_patrol_index = _nearest_patrol_index()
	# Поведение не назначаем: оценка сама выберет ПОИСК (мы помним последнее место)
	# либо ПАТРУЛЬ, если помнить уже нечего.

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
	elif relentless:
		return                      # цель зафиксирована при спавне — на других не отвлекаемся
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
# САМОВОССТАНОВЛЕНИЕ ПРИ ПЕРЕВОРОТЕ
# ══════════════════════════════════════════
# Ровно то же, что делает машина игрока в режиме СТРОЙКИ: подъём над рельефом на клиренс +
# плавный доворот к «ровно» (slerp к Basis.looking_at, а не сброс эйлеров — тот гимбалит на
# перевороте). Держим FLIP_TIME секунд, потом отпускаем в обычную физику.
const FLIP_DOT := 0.3          # верх машины отклонился больше ~72° → считаем перевёрнутой
const FLIP_TIME := 2.0         # сколько длится подъём/выравнивание
const FLIP_CLEARANCE := 3.0    # на сколько поднимаем над рельефом
var _flip_t: float = 0.0

func _flip_recover(delta: float) -> bool:
	if _flip_t <= 0.0:
		if _get_up().dot(Vector3.UP) >= FLIP_DOT:
			return false
		_flip_t = FLIP_TIME                       # только что перевернулись — запускаем подъём
	_flip_t -= delta
	# Высота: тянемся к рельефу + клиренс (демпфированная пружина, без овершута).
	var terr: Node = _find_terrain()
	var target_y: float = global_position.y
	if terr != null:
		target_y = terr.terrain_height_at(global_position) + FLIP_CLEARANCE
	linear_velocity.y = clampf((target_y - global_position.y) * 6.0, -6.0, 6.0)
	linear_velocity.x = lerpf(linear_velocity.x, 0.0, clampf(delta * 8.0, 0.0, 1.0))
	linear_velocity.z = lerpf(linear_velocity.z, 0.0, clampf(delta * 8.0, 0.0, 1.0))
	# Доворот «ровно», курс (yaw) сохраняем.
	var fwd := -global_transform.basis.z
	fwd.y = 0.0
	if fwd.length_squared() < 0.0001:
		fwd = global_transform.basis.y
		fwd.y = 0.0
	if fwd.length_squared() < 0.0001:
		fwd = Vector3.FORWARD
	var want := Basis.looking_at(fwd.normalized(), Vector3.UP)
	global_transform.basis = global_transform.basis.slerp(want, clampf(delta * 4.0, 0.0, 1.0)).orthonormalized()
	angular_velocity = Vector3.ZERO
	_throttle = 0.0
	if _flip_t <= 0.0:
		_stuck01 = 0.0                            # после подъёма это не застревание
		_move_ref = global_position
		_move_t = 0.0
	return _flip_t > 0.0

var _terrain_cache: Node = null

func _find_terrain() -> Node:
	if _terrain_cache != null and is_instance_valid(_terrain_cache):
		return _terrain_cache
	var scn := get_tree().current_scene
	if scn == null:
		return null
	for c in scn.get_children():
		if c.has_method("terrain_height_at"):
			_terrain_cache = c
			return c
	return null

# ══════════════════════════════════════════
# ФИЗИКА — МАССА
# ══════════════════════════════════════════


# Блоки, принимающие газ/руль (колёса). Кеш инвалидируется по числу детей $blocks.

# ══════════════════════════════════════════
# ФИЗИКА — БАЗА КОЛЁС
# ══════════════════════════════════════════
