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

# ── Режим защиты (ставится из кругового меню чужой машины) ────────────────────
# Машина стоит на месте, но если враг в радиусе — её оружие атакует.
var defense_mode: bool = false
const DEFENSE_RANGE := 25.0
var _defense_timer: float = 0.0

# ── Якорь (фиксация к миру, как в TerraTech) ──────────────────────────────────
var anchored: bool = false
var _anchor_column: MeshInstance3D = null
const ANCHOR_MAX_RISE := 0.5      # м: максимальный перепад земли под машиной для фиксации
const ANCHOR_MAX_HEIGHT := 2.5    # м: выше этого над землёй якорить нельзя (прыжок/полёт)

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

	_connect_cabin()

	# Кнопка взаимодействия (только на машинах игрока): подъехал другой машиной,
	# зажал ~1с → круговое меню (в инвентарь / разобрать / защита).
	if faction == 0:
		var ib := Area3D.new()
		ib.set_script(preload("res://vehicle_interact_button.gd"))
		ib.vehicle = self
		ib.position = Vector3(0, 2.2, 0)
		ib.collision_layer = 16     # свой слой: луч тапа его видит, физика машин — нет
		ib.collision_mask = 0
		add_child(ib)

# Смерть машины = уничтожена КАБИНА. Ловим её destroyed. При смене сборки зовём заново.
var _dying: bool = false
func _connect_cabin() -> void:
	if block_map_node == null:
		return
	for b in block_map_node.get_children():
		if b.get("block") == G.Block.CABIN:
			if b.has_signal("destroyed") and not b.destroyed.is_connected(_on_cabin_destroyed):
				b.destroyed.connect(_on_cabin_destroyed)
			return

func _on_cabin_destroyed(_b = null) -> void:
	_die()

# Кабина уничтожена → машина разваливается (блоки падают в мир), камера уходит к другой
# машине (а если её нет — спавнит бесплатную стартовую), эта машина удаляется.
func _die() -> void:
	if _dying:
		return
	_dying = true
	_scatter_blocks()
	if camera_controller and camera_controller.has_method("on_vehicle_died"):
		camera_controller.on_vehicle_died(self)
	queue_free()

func _scatter_blocks() -> void:
	var objects := get_node_or_null("/root/Main/objects")
	if objects == null or block_map_node == null:
		return
	# Центр разлёта = кабина (она и взорвалась). Блоки получают толчок ОТ неё.
	var cabin_pos: Vector3 = global_position
	for b in block_map_node.get_children():
		if b.get("block") == G.Block.CABIN and b is Node3D:
			cabin_pos = (b as Node3D).global_position
			break
	for b in block_map_node.get_children():
		if not ("block" in b):
			continue                       # пропускаем меш-призрак
		if b.get("block") == G.Block.CABIN:
			continue                       # кабина разрушена
		if b is Node3D:
			var n3 := b as Node3D
			# Толчок от кабины ЗАЯВКОЙ до reparent: VehicleBlock применит его сам в момент
			# своей разморозки (kick/_pending_kick). Задавать скорость снаружи бесполезно —
			# тело ещё заморожено, и значение терялось (блоки падали кучкой).
			if n3.has_method("kick"):
				var dir := (n3.global_position - cabin_pos)
				dir.y = 0.0
				dir = dir.normalized() if dir.length() > 0.01 else Vector3(randf() - 0.5, 0, randf() - 0.5).normalized()
				n3.kick(dir * 5.0 + Vector3.UP * 4.0)
			n3.reparent(objects)


# ══════════════════════════════════════════
# ЗАЩИТА / ЯКОРЬ / ДЕЙСТВИЯ КРУГОВОГО МЕНЮ
# ══════════════════════════════════════════

# Раз в 0.3с ищем врага (faction != наш) в радиусе; есть — жмём attack() у оружия.
func _defense_tick(delta: float) -> void:
	_defense_timer -= delta
	if _defense_timer > 0.0:
		return
	_defense_timer = 0.3
	var vehicles_root := get_parent()
	if vehicles_root == null:
		return
	for v in vehicles_root.get_children():
		if v == self or not (v is Node3D):
			continue
		var f = v.get("faction")
		if f == null or f == faction:
			continue
		if global_position.distance_to((v as Node3D).global_position) <= DEFENSE_RANGE:
			_on_attack_timeout()      # attack() у всех блоков с оружием
			return

# Якорь: фиксирует машину ровно 0° (по горизонту) с колонной-упором, как в TerraTech.
# Порядок: (1) отказ, если высоко над землёй; (2) приподнимаем машину на 0.5 м, чтобы
# выравнивание не воткнуло углы в склон; (3) проверка ровности (перепад <= 0.5 м, иначе
# опускаем обратно и отказ); (4) поворот ровно 0°; (5) фиксация + колонна.
# Сброс: пока на якоре, любой контакт НЕ с террейном снимает фиксацию.
func toggle_anchor() -> bool:
	if anchored:
		_release_anchor()
		return false
	var terr: Node = _find_terrain()
	var ground_center: float = terr.terrain_height_at(global_position) if terr else (global_position.y - 1.5)
	# (1) Высоко над землёй (прыжок/полёт/обрыв) — якорить нельзя.
	if global_position.y - ground_center > ANCHOR_MAX_HEIGHT:
		var dh = get_node_or_null("/root/Dialogue")
		if dh:
			dh.say("Якорь", "Слишком высоко над землёй")
		return false
	# Замораживаем ДО телепорта: трансформ незамороженного RigidBody физика тут же
	# перетирает своим состоянием — из-за этого подъём «не происходил».
	freeze = true
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
	# (2) Подъём на 0.5 м (машина встаёт на колонну — так и остаётся приподнятой).
	global_position.y += 0.5
	# (3) Ровность: 4 угла + центр.
	if terr != null:
		var mn := INF
		var mx := -INF
		for off in [Vector3.ZERO, Vector3(2, 0, 2), Vector3(2, 0, -2), Vector3(-2, 0, 2), Vector3(-2, 0, -2)]:
			var h: float = terr.terrain_height_at(global_position + off)
			mn = minf(mn, h)
			mx = maxf(mx, h)
		if mx - mn > ANCHOR_MAX_RISE:
			global_position.y -= 0.5          # неровно — вернули как было
			freeze = false
			var d = get_node_or_null("/root/Dialogue")
			if d:
				d.say("Якорь", "Слишком неровно — нужен перепад не больше %.1f м" % ANCHOR_MAX_RISE)
			return false
	# (4) Ровно 0° по X/Z (yaw остаётся).
	global_rotation.x = 0.0
	global_rotation.z = 0.0
	# (5) Фиксация.
	anchored = true
	# Колонна-упор: цилиндр от днища до земли.
	var ground_y: float = terr.terrain_height_at(global_position) if terr else (global_position.y - 1.5)
	var depth: float = maxf(global_position.y - ground_y, 0.4)
	_anchor_column = MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.18
	cyl.bottom_radius = 0.28
	cyl.height = depth
	_anchor_column.mesh = cyl
	_anchor_column.position = Vector3(0, -depth * 0.5, 0)
	add_child(_anchor_column)
	# Контакт-сброс: следим за столкновениями, пока на якоре.
	contact_monitor = true
	max_contacts_reported = 4
	if not body_entered.is_connected(_on_anchor_contact):
		body_entered.connect(_on_anchor_contact)
	return true

func _release_anchor() -> void:
	anchored = false
	freeze = false
	contact_monitor = false
	if body_entered.is_connected(_on_anchor_contact):
		body_entered.disconnect(_on_anchor_contact)
	if _anchor_column != null and is_instance_valid(_anchor_column):
		_anchor_column.queue_free()
	_anchor_column = null

func _on_anchor_contact(body: Node) -> void:
	if not anchored:
		return
	# Террейн — законная опора; всё остальное упёрлось в нас → фиксация сбрасывается.
	if body != null and body.has_method("terrain_height_at"):
		return
	_release_anchor()

func _find_terrain() -> Node:
	for c in get_tree().current_scene.get_children():
		if c.has_method("terrain_height_at"):
			return c
	return null

# ── Действия кругового меню (вызывает hud.open_vehicle_menu) ─────────────────

# Вся машина → в инвентарь: каждый блок типом в G.block_inventory, машина исчезает.
func send_to_inventory() -> void:
	if block_map_node == null:
		return
	for b in block_map_node.get_children():
		if "block" in b:
			G.block_inventory.append(b.block)
	var cc: Node = get_tree().get_first_node_in_group("camera_controller")
	if cc and "vehicles" in cc:
		cc.vehicles.erase(self)
	queue_free()

# Разобрать: все блоки КРОМЕ кабины выпадают в мир, кабина остаётся стоять машиной.
func disassemble() -> void:
	var objects := get_node_or_null("/root/Main/objects")
	if objects == null or block_map_node == null:
		return
	for b in block_map_node.get_children():
		if not ("block" in b) or b.get("block") == G.Block.CABIN:
			continue
		if b is Node3D:
			var n3 := b as Node3D
			# Чистим клетку карты и коллизию блока на корпусе.
			var cell := Vector3i(roundi(n3.position.x + 5), roundi(n3.position.y), roundi(n3.position.z + 5))
			if block_map_node.has_method("remove_block"):
				block_map_node.remove_block(cell.x, cell.y, cell.z)
			for col in get_children():
				if col is CollisionShape3D and col.is_in_group("block_collision") \
						and (col.position == n3.position or col.position == n3.position + Vector3(-0.5, 0.5, -0.5)):
					col.queue_free()
			n3.reparent(objects)
	Wheels.clear()

# Защита вкл/выкл. Управление игроком выключает её (set_active).
func set_defense(on: bool) -> void:
	defense_mode = on

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
	
	var keys_to_remove: Array = []
	
	# Перебираємо всі фізичні форми самого Vehicle
	for owner_id in get_shape_owners():
		var collision_shape = shape_owner_get_owner(owner_id) as CollisionShape3D
		
		if is_instance_valid(collision_shape):
			# Якщо ця колізія належить знищеному блоку
			if collision_shape.position == destroyed_block.position:
				
				
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
	# Защита работает и у НЕактивной машины: стоит и отстреливается от врагов рядом.
	if defense_mode:
		_defense_tick(delta)
	if !is_active:
		return
	if anchored:
		return                      # на якоре не ездим (freeze держит тело)
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
	if active:
		defense_mode = false     # игрок сел за руль — авто-оборона больше не рулит оружием

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

# Ориентация блока в руке = авто по грани (наклон/поворот) ∘ ручная (кнопки UI поворота).
var build_basis: Basis = Basis()
var _preview_res = null            # последний res для превью (чтобы переприменить при повороте)

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

func _process(_delta: float) -> void:
	if not Building:
		return
	if block_take:
		# Превью держимого блока переприменяем КАЖДЫЙ кадр: машина в стройке левитирует
		# вверх-вниз, а превью top_level (мировое) — без этого блок отставал от выбранной
		# ячейки. Пересчёт от block_map_node приклеивает его к ячейке, как светяшку.
		if _preview_res != null:
			_preview_held(_preview_res)
		return
	# Подсветка блока для подбора (ghost_block, top_level) следит за самим блоком: позиция И
	# ориентация — не отстаёт, если блок/машина сдвинулись.
	if ghost_block != null and block_body != null and is_instance_valid(block_body):
		ghost_block.global_transform = block_body.global_transform

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
	# top_level → трансформ призрака мировой, не наследует машину. Так позиция точная и не
	# «плывёт» относительно блоков, когда машина двигается (см. _place_ghost — ставим global).
	ghost_block.top_level = true
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
		# Больше НЕ светяшка: двигаем сам взятый блок на выбранную ячейку (превью), тап Take ставит.
		if res["hit"]: _preview_held(res)
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
	ghost_block.visible = true      # подсветка блока для подбора — вернуть, если её скрыл превью
	var gx: float = res.x; var gy: float = res.y; var gz: float = res.z
	if face: match res.face:
		"top":    gy += 1
		"bottom": gy -= 1
		"right":  gx += 1
		"left":   gx -= 1
		"back":   gz += 1
		"front":  gz -= 1
	var local_pos := Vector3(gx - 5, gy, gz - 5)
	if ghost_block.top_level and block_map_node:
		# Мировой трансформ ячейки (позиция + поворот машины) — призрак не отстаёт при движении.
		ghost_block.global_transform = block_map_node.global_transform * Transform3D(Basis(), local_pos)
	else:
		ghost_block.position = local_pos
	if BuildingBlock["build"]:
		BuildingBlock["x"] = gx; BuildingBlock["y"] = gy; BuildingBlock["z"] = gz
	else:
		BuildingBlock["x"] = res.x; BuildingBlock["y"] = res.y; BuildingBlock["z"] = res.z

# Авто-ориентация блока по грани крепления. Колёса — разворот по стороне (yaw, как раньше).
# Остальные блоки — НАКЛОН так, чтобы НИЗ смотрел на соседа (боковое крепление): справа от
# блока → низ влево и т.п. Углы могут потребовать проверки на живом тесте.
func _face_orient(face: String, block_type: int) -> Basis:
	if block_type == G.Block.WHEEL:
		match face:
			"right": return Basis(Vector3.UP, -PI / 2)
			"left":  return Basis(Vector3.UP,  PI / 2)
			"back":  return Basis(Vector3.UP,  PI)
			_:       return Basis()
	if block_type == G.Block.DRILL:
		return Basis()   # контакт «сзади»: ставится только на морду, буром вперёд — без наклона
	match face:
		"bottom": return Basis(Vector3.RIGHT, PI)       # под блоком — низ вверх, к соседу
		"right":  return Basis(Vector3.BACK, -PI / 2)   # низ → -X (влево, к соседу)
		"left":   return Basis(Vector3.BACK,  PI / 2)   # низ → +X
		"front":  return Basis(Vector3.RIGHT, -PI / 2)  # низ → +Z
		"back":   return Basis(Vector3.RIGHT,  PI / 2)  # низ → -Z
		_:        return Basis()                         # top — как есть

# Ставим сам взятый блок на выбранную ячейку (превью реальным блоком, не светяшкой).
func _preview_held(res: Dictionary) -> void:
	var holder: Node = camera_controller.camera.get_child(0)
	if holder.get_child_count() == 0:
		return
	var instance: Node3D = holder.get_child(0)
	_preview_res = res
	var gx: float = res.x; var gy: float = res.y; var gz: float = res.z
	match res.face:
		"top":    gy += 1
		"bottom": gy -= 1
		"right":  gx += 1
		"left":   gx -= 1
		"back":   gz += 1
		"front":  gz -= 1
	BuildingBlock["x"] = gx; BuildingBlock["y"] = gy; BuildingBlock["z"] = gz
	# Точки контакта + занятость клеток: если сюда нельзя прицепить (напр. на колесо сверху)
	# или клетки заняты — НЕ показываем блок на этой грани, держим его в руке, чтобы было
	# видно, что сюда ставить нельзя (раньше показывал где угодно).
	var neighbor_type: int = block_map_node.get_block(int(res.x), int(res.y), int(res.z))
	var placeable: bool = block_map_node.can_attach(neighbor_type, instance.block, res.face) \
			and block_map_node.can_place(instance.block, gx, gy, gz)
	if not placeable:
		instance.top_level = false
		instance.position = Vector3.ZERO       # обратно в руку
		instance.rotation = Vector3.ZERO
		if ghost_block:
			ghost_block.visible = false
		return
	var orient := _face_orient(res.face, instance.block) * build_basis
	var local_pos := Vector3(gx - 5, gy, gz - 5)
	var world_basis = (block_map_node.global_transform.basis * orient).orthonormalized()
	# top_level → превью держится в мировой ячейке и НЕ крутится с камерой (блок висит под
	# камерой; без этого при повороте камеры он «смотрел» на неё).
	instance.top_level = true
	instance.global_transform = Transform3D(world_basis, block_map_node.to_global(local_pos))
	if ghost_block:
		ghost_block.visible = false

# Ручной поворот блока в руке (кнопки UI). Переприменяет превью, если оно есть.
func rotate_build(axis: Vector3, ang: float) -> void:
	build_basis = (Basis(axis, ang) * build_basis).orthonormalized()
	if block_take and _preview_res != null:
		_preview_held(_preview_res)

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
	var td_x: float = (1.0/abs(dir.x)) if dir.x != 0 else INF
	var td_y: float = (1.0/abs(dir.y)) if dir.y != 0 else INF
	var td_z: float = (1.0/abs(dir.z)) if dir.z != 0 else INF
	var tm_x: float = ((cx + 0.5 - origin.x)/abs(dir.x)) if dir.x > 0 else ((origin.x - (cx - 0.5))/abs(dir.x)) if dir.x < 0 else INF
	var tm_y: float = ((cy + 0.5 - origin.y)/abs(dir.y)) if dir.y > 0 else ((origin.y - (cy - 0.5))/abs(dir.y)) if dir.y < 0 else INF
	var tm_z: float = ((cz + 0.5 - origin.z)/abs(dir.z)) if dir.z > 0 else ((origin.z - (cz - 0.5))/abs(dir.z)) if dir.z < 0 else INF
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
		var instance = camera_controller.camera.get_child(0).get_child(0)
		# Ставим РОВНО то, что показывает превью (_preview_res). Раньше грань бралась из
		# глобального result, а тап по самой кнопке «поставить» тоже прогонял _handle_click
		# по координатам кнопки и затирал result промахом (face="") — блок вставал без
		# наклона, не как в превью. Без превью ставить нечего.
		if _preview_res == null:
			return
		var pres: Dictionary = _preview_res
		# Проверяем ВЕСЬ footprint (для 2×2 — все 8 клеток), а не только якорную клетку,
		# иначе 2×2-блок (селлер) можно было визуально воткнуть в уже занятые клетки (пушку).
		if not block_map_node.can_place(instance.block, BuildingBlock["x"], BuildingBlock["y"], BuildingBlock["z"]):
			return
		# Точки контакта: можно ли прицепить сюда (пушка сверху нельзя, колесо только справа).
		var neighbor_type: int = block_map_node.get_block(pres.x, pres.y, pres.z)
		if not block_map_node.can_attach(neighbor_type, instance.block, pres.face):
			return
		# Превью держало блок top_level (мировой трансформ). Перед постановкой возвращаем
		# наследование, иначе local basis/position ниже применятся как мировые.
		instance.top_level = false
		# Полная ориентация: авто по грани (наклон/разворот колеса) ∘ ручной поворот из UI.
		var orient := _face_orient(pres.face, instance.block) * build_basis
		instance.basis = orient
		instance.position = Vector3(BuildingBlock["x"]-5, BuildingBlock["y"], BuildingBlock["z"]-5)
		var collision = instance.get_child(0).duplicate()
		collision.transform = Transform3D(orient, instance.position)   # коллизия наклоняется вместе
		if collision.shape.size == Vector3(2,2,2):
			collision.position += Vector3(-0.5,0.5,-0.5)
		add_child(collision)
		collision.add_to_group("block_collision")   # чтобы смена сборки могла её убрать
		instance.reparent($blocks, false)
		instance.scale = Vector3.ONE
		block_map_node.set_block(BuildingBlock["x"], BuildingBlock["y"], BuildingBlock["z"], instance.block, instance.rotation)
		block_map_node.node_map["%d,%d,%d" % [BuildingBlock["x"], BuildingBlock["y"], BuildingBlock["z"]]] = instance
		block_take = false
		build_basis = Basis()          # сброс ручного поворота под следующий блок
		_preview_res = null
		Q.report("block_placed", 1)             # прогресс заданий на сборку
	elif block_body:
		if block_body.get_parent().name in "blocks":
			block_map_node.remove_block(BuildingBlock["x"], BuildingBlock["y"], BuildingBlock["z"])
		# 2×2-блоки кладут коллизию со сдвигом (-0.5,0.5,-0.5), поэтому ищем по обоим
		# вариантам позиции, иначе коллизия 2×2 оставалась бы висеть после снятия блока.
		for i in get_children():
			if i is CollisionShape3D and (i.position == block_body.position \
					or i.position == block_body.position + Vector3(-0.5, 0.5, -0.5)):
				i.queue_free()
		block_body.reparent(camera_controller.camera.get_child(0), false)
		block_body.position = Vector3.ZERO
		block_take = true
		build_basis = Basis()
		_preview_res = null
		if ghost_block:
			ghost_block.visible = false   # блок взят в руку — светяшка больше не нужна

# Дать игроку блок В РУКУ из инвентаря (вызывается из tech_ui при клике по слоту).
# Блок инстансится из сцены и вешается на takepos (camera.get_child(0)) — ровно туда,
# куда попадает блок, снятый с машины. Дальше его ставит обычный Building-флоу
# (_handle_click → _on_take_pressed). Возвращает false, если в руке уже что-то есть.
# ── Сборки: снять текущую раскладку и применить сохранённую (для tech_ui) ─────
func capture_build() -> Array:
	if block_map_node and block_map_node.has_method("get_layout"):
		return block_map_node.get_layout()
	return []

func apply_build(layout: Array) -> void:
	if block_map_node == null or not block_map_node.has_method("apply_layout"):
		return
	Wheels.clear()                          # старые колёса исчезнут, новые сами добавятся
	block_map_node.apply_layout(layout)     # сам чистит коллизии блоков и пересобирает
	_connect_cabin()                        # новая кабина — заново ловим её гибель

func take_block_into_hand(block_type: int) -> bool:
	if block_take:
		return false
	var scene: PackedScene = G.get_scene(block_type)
	if scene == null:
		return false
	var instance = scene.instantiate()
	var holder: Node = camera_controller.camera.get_child(0)   # takepos Marker3D
	holder.add_child(instance)
	if instance is Node3D:
		instance.position = Vector3.ZERO
		instance.scale = Vector3.ONE
	block_body = instance
	block_take = true
	build_basis = Basis()          # свежий блок — без ручного поворота
	_preview_res = null
	# Сразу включаем режим стройки, чтобы блок можно было поставить без лишних нажатий
	# (и обновляем визуал HUD — кнопки Take/TakeOff). _on_building_pressed сам сгейтит
	# повтор через `if Building: return`.
	_on_building_pressed()
	var hud = camera_controller.hud
	if hud and hud.has_method("_on_building_pressed"):
		hud._on_building_pressed()
	return true

func _on_take_off_pressed() -> void:
	if block_take:
		var instance = camera_controller.camera.get_child(0).get_child(0)
		if block_body.block == 1: return
		instance.top_level = false        # мог остаться top_level от превью
		instance.reparent(%objects)
		instance.scale = Vector3.ONE
		block_take = false

func _on_attack_timeout() -> void:
	for i in $blocks.get_children():
		if i.has_method("attack"): i.attack()
