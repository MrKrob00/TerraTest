extends RigidBody3D

# ══════════════════════════════════════════
# ЭКСПОРТИРУЕМЫЕ ПАРАМЕТРЫ
# ══════════════════════════════════════════

@export var faction: int = 0  # 0 = игрок

@export_group("Двигатель")
@export var engine_force: float = 80.0
@export var max_speed: float = 20.0
@export var engine_brake: float = 0.3

@export_group("Тормоза")
@export var brake_power: float = 4.0

@export_group("Поворот")
@export var steer_max_angle: float = 45.0
@export var steer_speed: float = 10.0
@export var turn_response: float = 4.0
@export var speed_steer_reduction: float = 0.5

@export_group("Сцепление шин")
@export var lateral_grip: float = 8.0
@export var longitudinal_grip: float = 0.3

@export_group("Стабилизация")
@export var anti_roll: float = 6.0
@export var upright_strength: float = 12.0

@export_group("Масса и физика")
@export var base_weight: float = 40.0
@export var gravity_mult: float = 2.5

@export_group("Подвеска")
## Мягкая подвеска под каждым колесом: луч вниз + пружина/демпфер. Гасит подскоки на
## неровностях и стыках коллизии. Боксы колёс остаются «отбойником» на сильных ударах.
@export var suspension_enabled: bool = true
## Длина луча подвески вниз от колеса (м). Земля ближе этого → пружина+демпфер работают.
@export var suspension_rest: float = 0.7
## Жёсткость пружины (сила на единицу сжатия, ×масса). Мягкая — чтобы не воевать с боксами колёс.
@export var suspension_stiffness: float = 12.0
## Демпфер — главный гаситель подскоков (сила на скорость колеса вверх, ×масса).
@export var suspension_damping: float = 4.0
## Потолок силы подвески (×масса), чтобы на резком ударе машину не выкидывало.
@export var suspension_max_force: float = 40.0

@export var RADIUS: float = 8.0
@export var CAM_HEIGHT: float = 8.0
@export var ROT_SPEED: float = 1.5
@onready var camera_controller = $"../Camera Controller"

# ══════════════════════════════════════════
# ВНУТРЕННИЕ ПЕРЕМЕННЫЕ
# ══════════════════════════════════════════

var is_active: bool = false
var Building: bool = false
var block_body
var Wheels: Array = []

var _steer_angle: float = 0.0
var _throttle: float = 0.0
var _on_ground: bool = false

# Словник: { shape_owner_id (int) : block_node (Node) }
var collision_to_block_map: Dictionary = {}

	# Автоматично зв'язуємо колізії з блоками при старті
# ══════════════════════════════════════════
# ОСИ МАШИНЫ
# Колёса расставлены вдоль Z (z=5,6,7) → машина смотрит по -Z (стандарт Godot)
# Если едет в обратную сторону — поменяй знак в _get_forward()
# ══════════════════════════════════════════

func _get_forward() -> Vector3:
	return -global_transform.basis.z

func _get_right() -> Vector3:
	return global_transform.basis.x

func _get_up() -> Vector3:
	return global_transform.basis.y

# ══════════════════════════════════════════
# ИНИЦИАЛИЗАЦИЯ
# ══════════════════════════════════════════

func _ready() -> void:
	mass = base_weight
	gravity_scale = gravity_mult
	linear_damp = 0.0
	angular_damp = 4.0
	_on_movement_pressed()
	await get_tree().process_frame

	for block in get_children():
		_map_block_collisions(block)

	for block in block_map_node.get_children():
		connect_block_signals(block)


func _map_block_collisions(block: Node) -> void:
	for child in block.get_children():
		if child is CollisionShape3D:
			# Отримуємо ID власника форми всередині цього фізичного тіла (Vehicle)
			# Цей ID ідеально збігається з shape_owner_id, який дає RayCast/Area3D
			var owner_id: int = shape_find_owner(child.get_index())
			
			# Зв'язуємо цей ID з блоком
			collision_to_block_map[owner_id] = block
			
			# Також динамічно створюємо зворотну властивість у колізії, 
			# щоб швидко знайти її при видаленні блока
			child.set_meta("block_owner", block)


func connect_block_signals(block: Node) -> void:
	if block.has_signal("destroyed"):
		block.destroyed.connect(_on_block_destroyed)

func _on_block_destroyed(destroyed_block: Node3D) -> void:
	print("Блок знищено: ", destroyed_block.name, ". Шукаємо колізію всередині Vehicle...")
	
	var keys_to_remove: Array = []
	
	# Перебираємо всі фізичні форми самого Vehicle
	for owner_id in get_shape_owners():
		var collision_shape = shape_owner_get_owner(owner_id) as CollisionShape3D
		
		if is_instance_valid(collision_shape):
			# Якщо ця колізія належить знищеному блоку
			if collision_shape.position == destroyed_block.position:
				
				print("💥 Миттєво видаляємо колізію з кузова машини: ", collision_shape.name)
				
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





# ══════════════════════════════════════════
# ГЛАВНЫЙ ЦИКЛ
# ══════════════════════════════════════════

func _physics_process(delta: float) -> void:
	if !is_active:
		return
	if Building:
		var dist = global_position.y - map
		if dist < 5.0:
			var t = 1.0 - clamp(dist / 5.0, 0.0, 0.3)
			linear_velocity.y += lerp(0.0, 0.45, t)
		angular_velocity.x += rotation.x
		angular_velocity.z += rotation.z
		return

	if Input.is_action_pressed("Attack"):
		_on_attack_timeout()

	var joy = camera_controller.joystick_move.get_joystick_dir()
	_process_input(joy, delta)
	_check_ground()
	_sync_mass()
	_apply_suspension()

	if _on_ground:
		_apply_engine(delta)
		_apply_grip(delta)
		_apply_steering(delta)
		_apply_anti_roll(delta)
	_apply_upright(delta)
	_limit_speed()

# ══════════════════════════════════════════
# ОБРАБОТКА ВВОДА
# ══════════════════════════════════════════

func _process_input(joy: Vector2, delta: float) -> void:
	# joy.y вверх = -1 на большинстве джойстиков → газ вперёд
	# Если едет назад при нажатии вперёд — убери минус
	var raw_throttle = -joy.y
	var raw_steer = joy.x

	if abs(raw_throttle) < 0.08: raw_throttle = 0.0
	if abs(raw_steer) < 0.05:    raw_steer = 0.0

	_throttle = raw_throttle

	# Угол руля: уменьшается на скорости
	var speed_ratio = clamp(linear_velocity.length() / max_speed, 0.0, 1.0)
	var angle_limit = deg_to_rad(steer_max_angle) * (1.0 - speed_steer_reduction * speed_ratio)
	var target_steer = -raw_steer * angle_limit
	_steer_angle = lerp(_steer_angle, target_steer, steer_speed * delta)

	# Передаём блокам для визуала колёс
	for block in $blocks.get_children():
		if block.has_method("set_throttle"): block.set_throttle(_throttle)
		if block.has_method("set_steer"):    block.set_steer(raw_steer)

# ══════════════════════════════════════════
# КОНТАКТ С ЗЕМЛЁЙ
# ══════════════════════════════════════════

func _check_ground() -> void:
	var space = get_world_3d().direct_space_state
	var q = PhysicsRayQueryParameters3D.create(
		global_position,
		global_position + Vector3.DOWN * 1.4
	)
	q.exclude = [self]
	q.collision_mask = 1
	_on_ground = space.intersect_ray(q).size() > 0

# ══════════════════════════════════════════
# ПОДВЕСКА (raycast spring+damper под каждым колесом)
# ══════════════════════════════════════════
# Кузов — один RigidBody3D с жёсткими боксами колёс, поэтому удары рельефа бьют прямо в
# тело (отсюда подскоки). Тут под каждым колесом пускаем луч вниз по «верху» машины: если
# земля ближе rest, добавляем силу = пружина(сжатие) − демпфер(скорость колеса вверх),
# приложенную в точке колеса. Демпфер гасит подскок, пружина мягко держит. Сила только
# толкающая (clamp ≥ 0) — пассивная подвеска не тянет вниз; боксы остаются отбойником.
func _apply_suspension() -> void:
	if not suspension_enabled or Wheels.is_empty():
		return
	var space := get_world_3d().direct_space_state
	var up := _get_up()
	for wnode in Wheels:
		if not is_instance_valid(wnode):
			continue
		var wp: Vector3 = wnode.global_position
		var q := PhysicsRayQueryParameters3D.create(wp, wp - up * (suspension_rest + 0.4))
		q.exclude = [self]
		q.collision_mask = 1            # только рельеф (слой "world")
		var hit := space.intersect_ray(q)
		if hit.is_empty():
			continue
		var dist: float = wp.distance_to(hit.position)
		var compression := clampf(suspension_rest - dist, 0.0, suspension_rest)
		# скорость точки колеса вдоль "верха" машины (учёт вращения кузова)
		var wheel_vel := linear_velocity + angular_velocity.cross(wp - global_position)
		var vel_up := up.dot(wheel_vel)
		var force_mag := (suspension_stiffness * compression - suspension_damping * vel_up) * mass
		force_mag = clampf(force_mag, 0.0, suspension_max_force * mass)
		apply_force(up * force_mag, wp - global_position)

# ══════════════════════════════════════════
# СИНХРОНИЗАЦИЯ МАССЫ
# ══════════════════════════════════════════

func _sync_mass() -> void:
	var total = base_weight
	for w in Wheels:
		if is_instance_valid(w):
			total += w.get_module_data()["weight"]
	mass = total

# ══════════════════════════════════════════
# ТЯГА ДВИГАТЕЛЯ
# ══════════════════════════════════════════

func _apply_engine(delta: float) -> void:
	var fwd = _get_forward()
	var vel_fwd = fwd.dot(linear_velocity)

	if abs(_throttle) > 0.01:
		var speed_factor = clamp(1.0 - abs(vel_fwd) / max_speed, 0.05, 1.0)
		apply_central_force(fwd * _throttle * engine_force * mass * speed_factor)
	elif abs(vel_fwd) > 0.1:
		# Двигательное торможение (накат)
		apply_central_force(-fwd * vel_fwd * engine_brake * mass)

# ══════════════════════════════════════════
# СЦЕПЛЕНИЕ ШИН
# Боковое трение — машина не скользит бочком
# ══════════════════════════════════════════

func _apply_grip(delta: float) -> void:
	var right = _get_right()
	var fwd = _get_forward()

	# Боковое сцепление
	var vel_lat = right.dot(linear_velocity)
	apply_central_force(-right * vel_lat * lateral_grip * mass)

	# Лёгкое трение качения
	var vel_fwd = fwd.dot(linear_velocity)
	if abs(_throttle) < 0.01 and abs(vel_fwd) > 0.05:
		apply_central_force(-fwd * vel_fwd * longitudinal_grip * mass)

# ══════════════════════════════════════════
# ПОВОРОТ (формула Аккермана через angular_velocity)
# Плавный lerp без рывков
# ══════════════════════════════════════════

func _apply_steering(delta: float) -> void:
	var fwd = _get_forward()
	var vel_fwd = fwd.dot(linear_velocity)

	if abs(vel_fwd) < 0.3:
		angular_velocity.y = lerp(angular_velocity.y, 0.0, 10.0 * delta)
		return

	var wheelbase = _get_wheelbase()
	var target_yaw = 0.0
	if abs(_steer_angle) > 0.001 and wheelbase > 0.1:
		target_yaw = vel_fwd * tan(_steer_angle) / wheelbase
		if vel_fwd < 0:
			target_yaw = -target_yaw  # ← единственное изменение

	angular_velocity.y = lerp(angular_velocity.y, target_yaw, turn_response * delta)

# ══════════════════════════════════════════
# ГАШЕНИЕ КРЕНА
# ══════════════════════════════════════════

func _apply_anti_roll(delta: float) -> void:
	var local_av = global_transform.basis.inverse() * angular_velocity
	var correction = global_transform.basis * Vector3(
		-local_av.x * anti_roll,
		0.0,
		-local_av.z * anti_roll
	)
	apply_torque(correction * mass * delta)

# ══════════════════════════════════════════
# ВОЗВРАТ В ВЕРТИКАЛЬ
# ══════════════════════════════════════════

func _apply_upright(delta: float) -> void:
	var up = _get_up()
	var dot = up.dot(Vector3.UP)
	if dot >= 0.85: return

	var axis = up.cross(Vector3.UP)
	if axis.length_squared() < 0.0001: return
	axis = axis.normalized()
	var angle = acos(clamp(dot, -1.0, 1.0))
	apply_torque(axis * angle * upright_strength * mass * delta)
	

# ══════════════════════════════════════════
# ОГРАНИЧЕНИЕ СКОРОСТИ
# ══════════════════════════════════════════

func _limit_speed() -> void:
	var fwd = _get_forward()
	var vel_fwd = fwd.dot(linear_velocity)
	if abs(vel_fwd) > max_speed:
		linear_velocity -= fwd * (vel_fwd - sign(vel_fwd) * max_speed)
	if linear_velocity.y > 10.0:
		linear_velocity.y = 10.0

# ══════════════════════════════════════════
# ВСПОМОГАТЕЛЬНЫЕ
# ══════════════════════════════════════════

func _get_wheelbase() -> float:
	var front_z = -INF
	var rear_z = INF
	var has_f = false
	var has_r = false
	for w in Wheels:
		if !is_instance_valid(w): continue
		var lz = to_local(w.global_position).z
		if w.is_front:
			front_z = max(front_z, lz); has_f = true
		else:
			rear_z = min(rear_z, lz); has_r = true
	if has_f and has_r:
		return max(abs(front_z - rear_z), 0.5)
	return 2.0

func append_wheel(wheel: Node) -> void:
	if !Wheels.has(wheel): Wheels.append(wheel)

func erase_wheel(wheel: Node) -> void:
	Wheels.erase(wheel)

func set_active(active: bool) -> void:
	is_active = active
	Building = false

# ══════════════════════════════════════════
# СТРОИТЕЛЬСТВО (оригинальный код без изменений)
# ══════════════════════════════════════════

@export var block_map_node: Node
@export var ghost_block: Node3D

const CELL_SIZE = 1.0
const MAP_SIZE_X = 10
const MAP_SIZE_Y = 10
const MAP_SIZE_Z = 10

var block_take: bool = false
var BuildingBlock = { "build": true, "x": 5, "y": 0, "z": 5, "block": 1 }

func _input(event: InputEvent) -> void:
	if !is_active: return
	if event is InputEventScreenTouch and event.pressed and Building:
		_handle_click(event.position)
	elif event is InputEventScreenDrag and Building:
		_handle_click(event.position)
	if event.is_action_pressed("Take"):     _on_take_pressed()
	if event.is_action_pressed("TakeOff"):  _on_take_off_pressed()
	if event.is_action_pressed("Building"): _on_building_pressed()
	if event.is_action_pressed("Movement"): _on_movement_pressed()

func _on_movement_pressed() -> void:
	Building = false
	ghost_block.visible = false
	freeze = false
	var up = global_transform.basis.y
	if up.dot(Vector3.UP) < 0.3:
		global_rotation.z = 0
		global_rotation.x = 0
	for b in $blocks.get_children():
		if b.has_method("_find_next_block"): b._find_next_block()

var map = 0.0
func _on_building_pressed() -> void:
	if Building: return
	ghost_block.visible = true
	Building = true
	#freeze = true
	global_position.y += 4
	global_rotation.x = 0
	global_rotation.z = 0
	map = global_position.y

func _handle_click(screen_pos: Vector2) -> void:
	var camera = camera_controller.camera
	var world_origin = camera.project_ray_origin(screen_pos)
	var world_dir    = camera.project_ray_normal(screen_pos)
	# Луч надо перевести из мира в ЛОКАЛЬНУЮ сетку блоков. Старый код вычитал только
	# position (без учёта поворота машины и трансформа родителя) и НЕ поворачивал
	# направление — поэтому, как только машина повёрнута (а в Building остаётся поворот
	# по Y) или едет, выбор блоков переставал попадать. Берём пространство самого
	# block_map_node: to_local() даёт полный перевод точки (позиция+поворот+родитель), а
	# направление крутим обратным базисом. Сетка сдвинута на (5,0,5) (см. blocks.gd).
	var space_node: Node3D = block_map_node if block_map_node else self
	var ray_origin = space_node.to_local(world_origin) + Vector3(5, 0, 5)
	var ray_dir    = (space_node.global_transform.basis.inverse() * world_dir).normalized()
	var res = _find_nearest_block_on_ray(ray_origin, ray_dir)
	if block_take:
		if res["hit"]: _place_ghost(res, true)
		return
	else:
		camera.find_child("Raycast").process_mode = Node.PROCESS_MODE_DISABLED
		camera.find_child("Raycast").look_at(camera.global_position + world_dir)
		camera.find_child("Raycast").process_mode = Node.PROCESS_MODE_INHERIT
	if !block_take and res["hit"]:
		_place_ghost(res, false)
		block_body = block_map_node.find_block(BuildingBlock["x"], BuildingBlock["y"], BuildingBlock["z"])
		res["hit"] = false

func _place_ghost(res: Dictionary, face: bool) -> void:
	if ghost_block == null: return
	var gx: float = res.x; var gy: float = res.y; var gz: float = res.z
	if face: match res.face:
		"top":    gy += 1
		"bottom": gy -= 1
		"right":  gx += 1
		"left":   gx -= 1
		"back":   gz += 1
		"front":  gz -= 1
	ghost_block.position = Vector3(gx - 5, gy, gz - 5)
	if BuildingBlock["build"]:
		BuildingBlock["x"] = gx; BuildingBlock["y"] = gy; BuildingBlock["z"] = gz
	else:
		BuildingBlock["x"] = res.x; BuildingBlock["y"] = res.y; BuildingBlock["z"] = res.z

var result = {"hit": false, "x": 0, "y": 0, "z": 0, "block_name": "", "face": ""}
func _find_nearest_block_on_ray(origin: Vector3, direction: Vector3) -> Dictionary:
	result = {"hit": false, "x": 0, "y": 0, "z": 0, "block_name": "", "face": ""}
	var dir = direction
	# Ячейки сетки ЦЕНТРИРОВАНЫ на целых (блок (x,y,z) занимает [x-0.5 … x+0.5]), значит
	# стартовая ячейка = round(origin), а границы ячеек — на ПОЛУцелых. Старый код брал
	# границы на целых (round(origin)+1) → стабильный промах ~на полклетки. Здесь правильно:
	# t до первой границы считается до cx±0.5. Плюс проверяем и стартовую ячейку (раньше
	# сначала шагали, потом проверяли — стартовую пропускали).
	var cx := int(round(origin.x)); var cy := int(round(origin.y)); var cz := int(round(origin.z))
	var step_x := 1 if dir.x >= 0 else -1
	var step_y := 1 if dir.y >= 0 else -1
	var step_z := 1 if dir.z >= 0 else -1
	var td_x := (1.0/abs(dir.x)) if dir.x != 0 else INF
	var td_y := (1.0/abs(dir.y)) if dir.y != 0 else INF
	var td_z := (1.0/abs(dir.z)) if dir.z != 0 else INF
	var tm_x := ((cx + 0.5 - origin.x)/abs(dir.x)) if dir.x > 0 else ((origin.x - (cx - 0.5))/abs(dir.x)) if dir.x < 0 else INF
	var tm_y := ((cy + 0.5 - origin.y)/abs(dir.y)) if dir.y > 0 else ((origin.y - (cy - 0.5))/abs(dir.y)) if dir.y < 0 else INF
	var tm_z := ((cz + 0.5 - origin.z)/abs(dir.z)) if dir.z > 0 else ((origin.z - (cz - 0.5))/abs(dir.z)) if dir.z < 0 else INF
	var last_face := ""
	for _i in range(128):
		# Проверяем ТЕКУЩУЮ ячейку (включая стартовую) ещё до шага.
		if _in_bounds(cx, cy, cz):
			var block = block_map_node.get_block(cx, cy, cz)
			if block != 0:
				result["hit"] = true
				result["x"] = cx; result["y"] = cy; result["z"] = cz
				result["block_name"] = _get_block_name(block); result["face"] = last_face
				return result
		# Шаг в соседнюю ячейку по наименьшему tMax.
		if tm_x < tm_y and tm_x < tm_z:
			cx += step_x; tm_x += td_x; last_face = "left" if step_x>0 else "right"
		elif tm_y < tm_z:
			cy += step_y; tm_y += td_y; last_face = "bottom" if step_y>0 else "top"
		else:
			cz += step_z; tm_z += td_z; last_face = "front" if step_z>0 else "back"
	return result

func _in_bounds(x: float, y: float, z: float) -> bool:
	return x>=0 and x<MAP_SIZE_X and y>=0 and y<MAP_SIZE_Y and z>=0 and z<MAP_SIZE_Z

func _get_block_name(block: int) -> String:
	var names = G.Block.keys()
	if block < names.size(): return names[block]
	return "UNKNOWN"

func _on_take_pressed() -> void:
	if block_take:
		if block_map_node.get_block(BuildingBlock["x"], BuildingBlock["y"], BuildingBlock["z"]) != 0: return
		var instance = camera_controller.camera.get_child(0).get_child(0)
		var rotation_y = 0.0
		match result.face:
			"right":  rotation_y = -PI/2
			"left":   rotation_y = PI/2
			"back":   rotation_y = PI
			"front":  rotation_y = 0.0
		instance.rotation = Vector3.ZERO
		instance.rotation.y = rotation_y
		instance.position = Vector3(BuildingBlock["x"]-5, BuildingBlock["y"], BuildingBlock["z"]-5)
		var collision = instance.get_child(0).duplicate()
		collision.position = instance.position
		if collision.shape.size == Vector3(2,2,2):
			collision.position += Vector3(-0.5,0.5,-0.5)
		add_child(collision)
		instance.reparent($blocks, false)
		instance.scale = Vector3.ONE
		block_map_node.set_block(BuildingBlock["x"], BuildingBlock["y"], BuildingBlock["z"], instance.block, instance.rotation.y)
		block_map_node.node_map["%d,%d,%d" % [BuildingBlock["x"], BuildingBlock["y"], BuildingBlock["z"]]] = instance
		block_take = false
	elif block_body:
		if block_body.get_parent().name in "blocks":
			block_map_node.remove_block(BuildingBlock["x"], BuildingBlock["y"], BuildingBlock["z"])
		for i in get_children():
			if i is CollisionShape3D and i.position == block_body.position: i.queue_free()
		block_body.reparent(camera_controller.camera.get_child(0), false)
		block_body.position = Vector3.ZERO
		block_take = true

func _on_take_off_pressed() -> void:
	if block_take:
		var instance = camera_controller.camera.get_child(0).get_child(0)
		if block_body.block == 1: return
		instance.reparent(%objects)
		instance.scale = Vector3.ONE
		block_take = false

func _on_attack_timeout() -> void:
	for i in $blocks.get_children():
		if i.has_method("attack"): i.attack()
