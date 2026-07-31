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

# ── Энергосистема машины ──────────────────────────────────────────────────────
# _energy — запас в аккумуляторах (кап = число BATTERY × BATTERY_CAP).
# _tick_prod — энергия, произведённая В ЭТОМ тике (солнечные/генератор): потребители
# (реген/щит) едят СНАЧАЛА её, потом запас. Остаток в начале следующего тика утекает в
# аккумуляторы; если аккумуляторов нет — сгорает. Так «без аккума работает, но не больше,
# чем производится» получается само собой.
const BATTERY_CAP := 100.0
const SOLAR_RATE := 6.0          # энергии в секунду с одной панели (только на якоре)
var _energy: float = 0.0
var _tick_prod: float = 0.0
var _energy_cap: float = 0.0
var _cap_timer: float = 0.0

func energy_cap() -> float:
	return _energy_cap

func energy_stored() -> float:
	return _energy

# Доля заполнения аккумуляторов для HUD (0..1). Нет аккумуляторов — 0.
func energy_fill() -> float:
	return _energy / _energy_cap if _energy_cap > 0.0 else 0.0

# Есть ли сейчас хоть какая-то энергия (запас или свежая выработка).
func energy_available() -> float:
	return _energy + _tick_prod

# Источники (солнечная, генератор) добавляют выработку сюда.
func energy_produce(amount: float) -> void:
	_tick_prod += amount

# Потребители (реген/щит) просят энергию; возвращается сколько реально выдано.
func energy_consume(amount: float) -> float:
	var given: float = 0.0
	var from_prod: float = minf(amount, _tick_prod)
	_tick_prod -= from_prod
	given += from_prod
	var from_store: float = minf(amount - given, _energy)
	_energy -= from_store
	given += from_store
	return given

# Тик энергии: остаток прошлого тика → в аккумуляторы (без них сгорает), пересчёт
# ёмкости (раз в 0.5с), выработка солнечных панелей (только на якоре).
func _energy_tick(delta: float) -> void:
	_energy = minf(_energy + _tick_prod, _energy_cap)
	_tick_prod = 0.0
	_cap_timer -= delta
	var solar := 0
	if _cap_timer <= 0.0 or anchored:
		var batteries := 0
		if block_map_node != null:
			for b in block_map_node.get_children():
				match b.get("block"):
					G.Block.BATTERY: batteries += 1
					G.Block.SOLAR:   solar += 1
		if _cap_timer <= 0.0:
			_cap_timer = 0.5
			_energy_cap = batteries * BATTERY_CAP
			_energy = minf(_energy, _energy_cap)
	if anchored and solar > 0:
		energy_produce(solar * SOLAR_RATE * delta)

# ── Якорь (фиксация к миру, как в TerraTech) ──────────────────────────────────
var anchored: bool = false
var _anchor_column: MeshInstance3D = null
var _anchor_tween: Tween = null
# Стационарная структура (база): спавнится сразу на якоре, снять якорь/ехать нельзя.
# Ставится флаг при спавне через _place_ground_structure (ядро — стационарный блок).
var is_station: bool = false
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
	
	var cabin_pos: Vector3 = global_position  # Центр разлёта
	for b in block_map_node.get_children():
		if b.get("block") == G.Block.CABIN and b is Node3D:
			cabin_pos = (b as Node3D).global_position
			break
	for b in block_map_node.get_children():
		if not ("block" in b):
			continue      # пропускаем меш-призрак
		if b.get("block") == G.Block.CABIN:
			continue      # кабина разрушена
		if b is Node3D:
			var n3 := b as Node3D
			n3.reparent(objects)
			if n3 is RigidBody3D:
				# Толчок сразу и напрямую: размораживаем САМИ (не ждём, пока VehicleBlock
				# сделает это сигналом кадром позже), будим и даём импульс. freeze=false и
				# apply_central_impulse — прямые вызовы физсервера, выполняются по порядку.
				# Поздний _on_parent_changed поставит freeze=false ещё раз — без вреда.
				var rb := n3 as RigidBody3D
				var dir := (rb.global_position - cabin_pos)
				dir.y = 0.0
				dir = dir.normalized() if dir.length() > 0.01 else Vector3(randf() - 0.5, 0, randf() - 0.5).normalized()
				rb.freeze = false
				rb.sleeping = false
				rb.apply_central_impulse((dir * 5.0 + Vector3.UP * 4.0) * rb.mass)


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
# Есть ли на машине блок ФИКС-ОПОРЫ (SUPPORT). Без него якорь недоступен (по ТЗ).
func has_support() -> bool:
	if block_map_node == null:
		return false
	for b in block_map_node.get_children():
		if "block" in b and int(b.block) == G.Block.SUPPORT:
			return true
	return false

# Можно ли этой машине вставать на якорь: она база ИЛИ на ней есть фикс-опора.
func can_anchor() -> bool:
	return is_station or has_support()

func toggle_anchor() -> bool:
	if is_station:
		return true                        # стационарная база всегда на якоре — снять нельзя
	if anchored:
		_release_anchor()
		return false
	if not has_support():
		_anchor_refuse_hop()               # без фикс-опоры якорь не ставится (нужен блок SUPPORT)
		return false
	var terr: Node = _find_terrain()
	var ground_center: float = terr.terrain_height_at(global_position) if terr else (global_position.y - 1.5)
	# (1) Высоко над землёй (прыжок/полёт/обрыв) — не якорим, просто подкидывает.
	if global_position.y - ground_center > ANCHOR_MAX_HEIGHT:
		_anchor_refuse_hop()
		return false
	# (2) Ровность: 4 угла + центр (математика по террейну, от подъёма не зависит).
	if terr != null:
		var mn := INF
		var mx := -INF
		for off in [Vector3.ZERO, Vector3(2, 0, 2), Vector3(2, 0, -2), Vector3(-2, 0, 2), Vector3(-2, 0, -2)]:
			var h: float = terr.terrain_height_at(global_position + off)
			mn = minf(mn, h)
			mx = maxf(mx, h)
		if mx - mn > ANCHOR_MAX_RISE:
			_anchor_refuse_hop()
			return false
	# (3) Замораживаем (STATIC): у замороженного тела transform МОЖНО двигать — физика его
	# не перетирает. Прямой телепорт незамороженного RigidBody сервер откатывал, поэтому
	# подъёма «не было видно». Tween по замороженному телу = серия телепортов: надёжно и
	# видно глазом — машина поднимается на колонну и выравнивается.
	freeze = true
	anchored = true
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
	var target_y := global_position.y + 0.5
	_anchor_tween = create_tween()
	_anchor_tween.tween_property(self, "global_position:y", target_y, 0.18)   # (4) подъём на 0.5
	_anchor_tween.tween_property(self, "global_rotation:x", 0.0, 0.12)        # (5) ровно 0°
	_anchor_tween.parallel().tween_property(self, "global_rotation:z", 0.0, 0.12)
	# (6) Колонна-упор до земли (размер под конечную высоту).
	var ground_y: float = terr.terrain_height_at(global_position) if terr else (global_position.y - 1.5)
	var depth: float = maxf(target_y - ground_y, 0.4)
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

# Отказ якоря (высоко/неровно): без сообщений — машину просто подкидывает вверх,
# якорь не ставится. Живая обратная связь вместо текста.
func _anchor_refuse_hop() -> void:
	sleeping = false
	apply_central_impulse(Vector3.UP * mass * 5.0)

func _release_anchor() -> void:
	if _anchor_tween != null and _anchor_tween.is_valid():
		_anchor_tween.kill()          # сброс во время анимации — не даём твину драться с физикой
	_anchor_tween = null
	anchored = false
	freeze = false
	contact_monitor = false
	if body_entered.is_connected(_on_anchor_contact):
		body_entered.disconnect(_on_anchor_contact)
	if _anchor_column != null and is_instance_valid(_anchor_column):
		_anchor_column.queue_free()
	_anchor_column = null

func _on_anchor_contact(body: Node) -> void:
	if not anchored or is_station:          # база не слетает с якоря от касаний
		return
	# Пока идёт анимация постановки на якорь (подъём + выравнивание) — контакты игнорируем:
	# иначе _release_anchor убьёт твин на полпути и машина зависнет НАКЛОНЁННОЙ и размороженной.
	if _anchor_tween != null and _anchor_tween.is_valid():
		return
	# Террейн — законная опора; всё остальное упёрлось в нас → фиксация сбрасывается.
	if body != null and body.has_method("terrain_height_at"):
		return
	_release_anchor()

# Мгновенный якорь стационарной базы при спавне: без отказа (стоит на земле) и без
# анимации-подъёма (уже на месте) — просто фиксируем, выравниваем и ставим колонну-упор.
func _anchor_station() -> void:
	anchored = true
	freeze = true
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
	global_rotation.x = 0.0
	global_rotation.z = 0.0
	if _anchor_column == null or not is_instance_valid(_anchor_column):
		var terr: Node = _find_terrain()
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
	_connect_station_core()

# 4A: гибель стационарного ЯДРА (SELLER) = структура разваливается (как кабина у машины).
# Спавн блоков асинхронный (spawn_block ждёт ready) — ретраим, пока ядро не появится.
func _connect_station_core(tries: int = 0) -> void:
	if block_map_node == null:
		return
	for b in block_map_node.get_children():
		if "block" in b and G.is_stationary(int(b.block)):
			if b.has_signal("destroyed") and not b.destroyed.is_connected(_on_cabin_destroyed):
				b.destroyed.connect(_on_cabin_destroyed)
			return
	if tries < 5:
		get_tree().create_timer(0.1).timeout.connect(_connect_station_core.bind(tries + 1))

func _find_terrain() -> Node:
	for c in get_tree().current_scene.get_children():
		if c.has_method("terrain_height_at"):
			return c
	return null

# ── Медленное перемещение в РЕЖИМЕ СТРОЙКИ (репозиция, чтобы выбраться из ямы/застревания) ──
const BUILD_MOVE_SPEED := 4.0         # медленно (u/с) — это не езда, а сдвиг платформы
const BUILD_HOVER_CLEARANCE := 4.0    # высота парения над рельефом в стройке
var _terr_cache: Node = null

func _get_terrain() -> Node:
	if _terr_cache == null or not is_instance_valid(_terr_cache):
		_terr_cache = _find_terrain()
	return _terr_cache

# Направление сдвига в стройке (джойстик движения + WASD), ОТНОСИТЕЛЬНО КАМЕРЫ (вверх по стику —
# от игрока). Свободный XZ-сдвиг, а не «газ/руль» — репозиция висящей платформы.
func _build_move_dir() -> Vector3:
	var joy := Vector2.ZERO
	if camera_controller != null and camera_controller.joystick_move != null:
		joy = camera_controller.joystick_move.get_joystick_dir()
	if not _typing_in_ui():
		joy = (joy + Input.get_vector("move_left", "move_right", "move_forward", "move_back")).limit_length(1.0)
	if joy.length() < 0.12:
		return Vector3.ZERO
	var cam: Camera3D = camera_controller.camera if camera_controller != null else null
	if cam == null:
		return Vector3.ZERO
	var cf := -cam.global_transform.basis.z; cf.y = 0.0
	var cr := cam.global_transform.basis.x;  cr.y = 0.0
	if cf.length() > 0.01: cf = cf.normalized()
	if cr.length() > 0.01: cr = cr.normalized()
	var m := cr * joy.x + cf * (-joy.y)   # joy.y вверх = -1 → вперёд (от камеры)
	return m.normalized() if m.length() > 1.0 else m

# ── Действия кругового меню (вызывает hud.open_vehicle_menu) ─────────────────

# Вся машина → в инвентарь: каждый блок типом в G.block_inventory, машина исчезает.
func send_to_inventory() -> void:
	if block_map_node == null:
		return
	for b in block_map_node.get_children():
		if "block" in b:
			G.block_inventory.append(b.block)
	G.mark_progress_dirty()
	var cc: Node = get_tree().get_first_node_in_group("camera_controller")
	if cc and "vehicles" in cc:
		cc.vehicles.erase(self)
	queue_free()

# Разобрать: все блоки КРОМЕ ядра выпадают в мир. Ядро остаётся стоять: у машины это кабина,
# у станции — стационарный блок (SELLER) на якоре.
func disassemble() -> void:
	var objects := get_node_or_null("/root/Main/objects")
	if objects == null or block_map_node == null:
		return
	for b in block_map_node.get_children():
		if not ("block" in b) or b.get("block") == G.Block.CABIN:
			continue
		# Ядро СТАНЦИИ (стационарный блок, напр. SELLER) — как кабина у машины: остаётся на
		# якоре и НЕ выпадает. Пропускаем ДО remove_block/коллизии/reparent, чтобы клетки карты,
		# коллизия и сам узел ядра сохранились и база продолжала стоять. SELLER 2×2×2 — один
		# якорный узел, так что пропуска узла хватает на все 8 клеток. Гард по G.is_stationary
		# (мобильная машина стационарный блок носить не может — can_attach это запрещает).
		if G.is_stationary(int(b.get("block"))):
			continue
		if b is Node3D:
			var n3 := b as Node3D
			# Чистим клетку карты и коллизию блока на корпусе.
			var cell := Vector3i(roundi(n3.position.x + 5), roundi(n3.position.y + 5), roundi(n3.position.z + 5))
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

# Блок потерял связь с корнем (кабина/база) и падает в мир (см. blocks._detach_orphans):
# снимаем его дублированную коллизию с тела машины, репарентим в objects, размораживаем и роняем.
func detach_block_to_world(node: Node) -> void:
	if not is_instance_valid(node):
		return
	if node is Node3D:
		_on_block_destroyed(node as Node3D)          # убрать коллизию блока с тела + чистка мапы урона
	var objects := get_node_or_null("/root/Main/objects")
	if objects == null or not (node is Node3D):
		return
	(node as Node3D).reparent(objects)
	if node is RigidBody3D:
		var rb := node as RigidBody3D
		rb.freeze = false
		rb.sleeping = false
		if _blast_force > 0.0 and Time.get_ticks_msec() < _blast_until_ms:
			# Оторвало ВЗРЫВОМ (напр. батареи) — швыряем от эпицентра сильнее обычного.
			var away := rb.global_position - _blast_pos
			if away.length() < 0.1:
				away = Vector3(randf() - 0.5, 0.3, randf() - 0.5)
			away = (away.normalized() + Vector3.UP * 0.35).normalized()
			rb.apply_central_impulse(away * _blast_force * rb.mass)
		else:
			var dir := Vector3(randf() - 0.5, 0.0, randf() - 0.5)
			dir = dir.normalized() if dir.length() > 0.01 else Vector3.FORWARD
			rb.apply_central_impulse((dir * 2.0 + Vector3.UP * 2.5) * rb.mass)

# Взрыв на машине (напр. уничтожена батарея): осколки, что оторвутся в ближайшие ~0.3с, летят
# ОТ эпицентра сильнее обычного (см. detach_block_to_world). Ставится из VehicleBlock.destroy.
var _blast_pos: Vector3 = Vector3.ZERO
var _blast_force: float = 0.0
var _blast_until_ms: int = 0

func register_blast(pos: Vector3, force: float) -> void:
	_blast_pos = pos
	_blast_force = force
	_blast_until_ms = Time.get_ticks_msec() + 300

# Награда блоками (подача): count блоков ГЛЮЧНО возникают и КРУЖАТ вокруг машины, следуя за ней,
# затем падают в мир (см. reward_orbiter.gd). Зовётся из квестов вместо «молча в инвентарь».
const REWARD_ORBITER := preload("res://reward_orbiter.gd")
func award_blocks(block_type: int, count: int = 1) -> void:
	var list: Array = []
	for _i in count:
		list.append(block_type)
	award_block_list(list)

# Наградить СМЕШАННЫМ набором блоков: все они глючно кружат вокруг машины (равномерно по кругу),
# затем падают в мир (см. reward_orbiter.gd). Напр. стартовый набор: [BLOCK,BLOCK,WHEEL×4,DRILL,GUN].
func award_block_list(types: Array) -> void:
	if types.is_empty():
		return
	var scn := get_tree().current_scene
	if scn == null:
		return
	var n := types.size()
	for i in n:
		var orb = REWARD_ORBITER.new()                      # untyped → setup() зовётся динамически
		scn.add_child(orb)
		orb.setup(self, int(types[i]), TAU * float(i) / float(n))





# ══════════════════════════════════════════
# ГЛАВНЫЙ ЦИКЛ
# ══════════════════════════════════════════

func _physics_process(delta: float) -> void:
	# Энергия тикает ВСЕГДА (даже у неактивной машины): база на якоре копит от солнца.
	_energy_tick(delta)
	# Защита работает и у НЕактивной машины: стоит и отстреливается от врагов рядом.
	if defense_mode:
		_defense_tick(delta)
	if !is_active:
		return
	if anchored:
		return                      # на якоре не ездим (freeze держит тело)
	if Building:
		# Держим машину-платформу БЕЗ тряски: высота — задемпфированная пружина к map (v ∝ остатку
		# пути, без овершута), поворот — плавно к ровному. Горизонталь — МЕДЛЕННО по джойстику
		# (репозиция), иначе гасится к нулю (стоит на месте).
		# Высота цели СЛЕДУЕТ ЗА РЕЛЬЕФОМ (+клиренс), чтобы можно было выплыть из ямы/застревания:
		# двигаешь машину к краю → она поднимается над землёй и переваливает через препятствие.
		if not is_station:
			var terr := _get_terrain()
			if terr != null:
				map = terr.terrain_height_at(global_position) + BUILD_HOVER_CLEARANCE
		var err := map - global_position.y
		linear_velocity.y = clampf(err * 6.0, -6.0, 6.0)
		var h := clampf(delta * 8.0, 0.0, 1.0)
		# Медленное ПЕРЕМЕЩЕНИЕ джойстиком/WASD (репозиция, не езда): свободный сдвиг по XZ
		# относительно камеры. Станцию не двигаем (на якоре).
		var move := _build_move_dir() if not is_station else Vector3.ZERO
		linear_velocity.x = lerpf(linear_velocity.x, move.x * BUILD_MOVE_SPEED, h)
		linear_velocity.z = lerpf(linear_velocity.z, move.z * BUILD_MOVE_SPEED, h)
		# ВЫРАВНИВАНИЕ: плавно ставим машину РОВНО (верх = мир-верх), сохраняя курс (yaw). Если
		# въехали в стройку перевёрнутыми/на боку — она сама встаёт вертикально (не мгновенным
		# сбросом эйлеров, который «гимбалит» на перевороте, а slerp к ровной ориентации).
		if not is_station:
			var fwd := -global_transform.basis.z
			fwd.y = 0.0
			if fwd.length_squared() < 0.0001:      # смотрит строго вверх/вниз → курс берём из «верха»
				fwd = global_transform.basis.y
				fwd.y = 0.0
			if fwd.length_squared() < 0.0001:
				fwd = Vector3.FORWARD
			var target := Basis.looking_at(fwd.normalized(), Vector3.UP)
			global_basis = global_basis.orthonormalized().slerp(target, clampf(delta * 8.0, 0.0, 1.0)).orthonormalized()
		angular_velocity = Vector3.ZERO
		return

	var typing := _typing_in_ui()
	if Input.is_action_pressed("Attack") and not typing:
		_on_attack_timeout()

	var joy = camera_controller.joystick_move.get_joystick_dir()
	# ПК: WASD/стрелки дают тот же Vector2, что и тач-джойстик (см. _process_input ниже).
	# Суммируем с джойстиком и клампим — вместе на практике не используются, но так честно.
	# Гасим клавиатурную часть, пока фокус в текстовом поле (напр. поиск в гараже) —
	# иначе набор "wasd" в строке поиска ещё и гонял бы машину.
	if not typing:
		joy = (joy + Input.get_vector("move_left", "move_right", "move_forward", "move_back")).limit_length(1.0)
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

	if abs(vel_fwd) < 0.05:
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
# Сетка сборки 11×11×11 с ядром в центре (см. blocks.gd) — луч выбора/постановки блоков ходит
# по клеткам 0..10, клетка ядра = 5 по каждой оси.
const MAP_SIZE_X = 11
const MAP_SIZE_Y = 11
const MAP_SIZE_Z = 11

var block_take: bool = false
var BuildingBlock = { "build": true, "x": 5, "y": 5, "z": 5, "block": 1 }  # дефолт = центр сетки 11³

# Ориентация блока в руке = авто по грани (наклон/поворот) ∘ ручная (кнопки UI поворота).
var build_basis: Basis = Basis()
var _preview_res = null            # последний res для превью (чтобы переприменить при повороте)
var _cabin_ground = null           # Vector3|null: куда на ЗЕМЛЮ ставим кабину (новая машина)

# Фокус на текстовом поле (напр. поиск в гараже) — клавиатурные игровые действия (WASD,
# Take/TakeOff/Building/Movement/Attack — все читаются по сырому состоянию клавиши, в обход
# фокуса UI) иначе срабатывали бы прямо во время печати.
func _typing_in_ui() -> bool:
	var vp := get_viewport()
	return vp != null and vp.gui_get_focus_owner() is LineEdit

var _touch_count: int = 0        # активных пальцев на экране
var _build_tap_pos: Vector2 = Vector2.ZERO
var _build_tap_ms: int = 0
var _build_tap_moved: bool = false   # палец сдвинулся → это ОРБИТА камеры, а не наводка блока

func _input(event: InputEvent) -> void:
	if !is_active: return
	if event is InputEventScreenTouch:
		_touch_count = maxi(_touch_count + (1 if event.pressed else -1), 0)
	if Building:
		# Управление одним пальцем — как при езде: ДРАГ крутит камеру (это делает
		# camera_controller), а блок наводится ТАПОМ (короткое касание без свайпа) по клетке.
		# Раньше блок таскался драгом, и камеру пришлось отдавать двум пальцам — неудобно и
		# непривычно после одно-пальцевой езды. Теперь один палец ведёт себя одинаково везде.
		if event is InputEventMouseMotion \
				or (event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed):
			# ПК: мышь целится непрерывно (у неё орбита на ПКМ — конфликта нет). «Пустой» ховер
			# над HUD не целится в мир (иначе наводка ломается по пути к кнопке).
			var idle_hover := event is InputEventMouseMotion and not Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)
			if not (idle_hover and get_viewport().gui_get_hovered_control() != null):
				_handle_click(event.position)
		elif event is InputEventScreenTouch:
			if event.pressed:
				_build_tap_pos = event.position
				_build_tap_ms = Time.get_ticks_msec()
				_build_tap_moved = false
			elif _touch_count == 0 and not _build_tap_moved \
					and Time.get_ticks_msec() - _build_tap_ms < 250 \
					and get_viewport().gui_get_hovered_control() == null:
				_handle_click(event.position)          # одиночный тап по миру = навести блок сюда
		elif event is InputEventScreenDrag:
			if _build_tap_pos.distance_to(event.position) > 14.0:
				_build_tap_moved = true                # свайп → орбита камеры, блок не наводим
	# Клавиатурные действия гасим ТОЛЬКО пока печатают в текстовом поле — иначе, если
	# фокус где-то залип, тач/мышь-кнопки Take/TakeOff/Building/Movement (это тоже
	# event.is_action_pressed, тач-кнопки шлют его же) перестали бы работать вовсе.
	if event is InputEventKey and _typing_in_ui():
		return
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
	_return_hand_to_inventory()   # выход из стройки — блок из руки возвращаем в инвентарь
	Building = false
	ghost_block.visible = false
	if not is_station:            # станция всегда на якоре — Movement не должен её размораживать
		freeze = false
	var up = global_transform.basis.y
	if up.dot(Vector3.UP) < 0.3:
		global_rotation.z = 0
		global_rotation.x = 0
	for b in $blocks.get_children():
		if b.has_method("_find_next_block"): b._find_next_block()

var map:float = 0.0
func _on_building_pressed() -> void:
	if Building: return
	if not is_instance_valid(ghost_block):
		push_warning("ghost_block недоступен — постройка невозможна")
		return
	ghost_block.visible = true
	# top_level → трансформ призрака мировой, не наследует машину. Так позиция точная и не
	# «плывёт» относительно блоков, когда машина двигается (см. _place_ghost — ставим global).
	ghost_block.top_level = true
	Building = true
	#freeze = true
	# Мобильную машину подбрасываем на 4 м (строить в воздухе, потом Movement опускает). СТАНЦИЮ
	# НЕ поднимаем: она на якоре и стоит на месте — иначе база с колонной улетала бы вверх и не
	# возвращалась (Movement высоту не восстанавливает). Строим прямо на станции (правила
	# can_attach: на базу можно стационары + фабричные).
	if not is_station:
		global_position.y += 4          # подброс для стройки в воздухе; выравнивание — плавно в _physics_process
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
	# КАБИНА (новая машина) и СТАЦИОНАРНЫЙ блок (новая база) в руке — ставятся не на эту
	# машину, а В МИР на землю.
	if block_take:
		var holder: Node = camera_controller.camera.get_child(0)
		if holder.get_child_count() > 0:
			var held_bt = holder.get_child(0).get("block")
			# Кабина → всегда новая машина на землю. Стационар → новая база на землю, ТОЛЬКО
			# если сейчас управляем МАШИНОЙ; если управляем СТАНЦИЕЙ — идёт обычным путём
			# сетки (прикрепляется к базе, can_attach разрешает стационар-на-стационар).
			if held_bt == G.Block.CABIN or (G.is_stationary(held_bt) and not is_station):
				_preview_cabin_ground(world_origin, world_dir)
				return
	var space_node: Node3D = block_map_node if block_map_node else self
	var ray_origin = space_node.to_local(world_origin) + Vector3(5, 5, 5)
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
	var local_pos := Vector3(gx - 5, gy - 5, gz - 5)
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
	if G.is_wheel(block_type):
		match face:
			"right": return Basis(Vector3.UP, -PI / 2)
			"left":  return Basis(Vector3.UP,  PI / 2)
			"back":  return Basis(Vector3.UP,  PI)
			"top":   return Basis(Vector3.RIGHT, PI)   # верхнее колесо: перевёрнуто, свисает вниз
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
	var local_pos := Vector3(gx - 5, gy - 5, gz - 5)
	var world_basis = (block_map_node.global_transform.basis * orient).orthonormalized()
	# top_level → превью держится в мировой ячейке и НЕ крутится с камерой (блок висит под
	# камерой; без этого при повороте камеры он «смотрел» на неё).
	instance.top_level = true
	instance.global_transform = Transform3D(world_basis, block_map_node.to_global(local_pos))
	if ghost_block:
		ghost_block.visible = false

# Превью кабины НА ЗЕМЛЕ: физический луч в террейн (слой 1), кабина встаёт в точку
# попадания стоймя. Тап Take превратит её в новую структуру (см. _place_ground_structure).
func _preview_cabin_ground(world_origin: Vector3, world_dir: Vector3) -> void:
	var holder: Node = camera_controller.camera.get_child(0)
	if holder.get_child_count() == 0:
		return
	var space := get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(world_origin, world_origin + world_dir * 200.0)
	q.collision_mask = 1
	q.exclude = [self]
	var hit := space.intersect_ray(q)
	if hit.is_empty():
		return
	_cabin_ground = hit.position
	_preview_res = null
	var inst: Node3D = holder.get_child(0)
	inst.top_level = true
	inst.global_transform = Transform3D(Basis(), _cabin_ground + Vector3.UP * 0.6)
	if ghost_block:
		ghost_block.visible = false

# Ядро поставлено на землю → спавним НОВУЮ структуру из одного блока-ядра.
#   • ядро КАБИНА → мобильная машина (как было);
#   • ядро СТАЦИОНАРНЫЙ блок (SELLER) → якорная база: is_station=true и мгновенный якорь.
# Структура жёстко кладётся под Vehicles (не в objects), регистрируется в списке техники
# камеры (в неё можно пересесть) — круговое меню создаётся её же _ready (faction 0).
func _place_ground_structure(instance: Node3D) -> void:
	var core: int = int(instance.get("block"))
	var scene: PackedScene = load("res://player_vehicle.tscn")
	if scene == null:
		push_error("vehicle: нет player_vehicle.tscn для новой структуры")
		return
	var v: Node3D = scene.instantiate()
	var vehicles_root: Node = get_node_or_null("/root/Main/Vehicles")
	if vehicles_root == null:
		vehicles_root = get_parent()                # фолбэк: рядом с этой машиной
	vehicles_root.add_child(v)
	# СТАЦИОНАРНУЮ базу морозим СРАЗУ (STATIC), до постановки позиции: незамороженный RigidBody
	# сервер откатывает при прямом телепорте (см. коммент якоря ~290), а off-center коллизия
	# ядра 2×2 (SELLER) кренит тело за первый же физ-шаг — отсюда «наклон при якоре». Заморозка
	# до позиции = база не падает и не наклоняется, выравниванию уже не с чем драться.
	# Кабину-МАШИНУ НЕ морозим: freeze снимает только кнопка Movement, а switch_to_vehicle его
	# не трогает — иначе только что поставленная машина не поедет.
	if v is RigidBody3D and G.is_stationary(core):
		v.freeze = true
		v.linear_velocity = Vector3.ZERO
		v.angular_velocity = Vector3.ZERO
	v.global_position = _cabin_ground + Vector3.UP * 1.2
	if v.has_method("apply_build"):
		v.apply_build([{"x": 5, "y": 5, "z": 5, "block": core, "rot": [0.0, 0.0, 0.0]}])  # ядро в ЦЕНТРЕ сетки 11³
	# Стационарное ядро → база на якоре (нельзя ехать/снять якорь).
	if G.is_stationary(core) and "is_station" in v:
		v.is_station = true
		if "block_map_node" in v and v.block_map_node != null and "is_station" in v.block_map_node:
			v.block_map_node.is_station = true
		if v.has_method("_anchor_station"):
			v.call_deferred("_anchor_station")      # после apply_build/ready — тело уже на месте
	# Регистрация в списке техники (как _spawn_starter_vehicle) + обновление HUD.
	if camera_controller and "vehicles" in camera_controller and not camera_controller.vehicles.has(v):
		camera_controller.vehicles.append(v)
	var hud = camera_controller.hud if (camera_controller and "hud" in camera_controller) else null
	if hud and hud.has_method("_rebuild_vehicle_list"):
		hud._rebuild_vehicle_list()
	instance.queue_free()                           # ядро из руки потрачено
	block_take = false
	block_body = null
	_cabin_ground = null
	_preview_res = null
	build_basis = Basis()
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
		# Кабина → новая машина; стационар (с машины) → новая база. Ставятся В МИР на землю.
		# Стационар на СТАНЦИИ на землю не идёт (_cabin_ground будет null — превью шло сеткой).
		if _cabin_ground != null and (instance.get("block") == G.Block.CABIN \
				or (G.is_stationary(instance.get("block")) and not is_station)):
			_place_ground_structure(instance)
			return
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
		instance.position = Vector3(BuildingBlock["x"]-5, BuildingBlock["y"]-5, BuildingBlock["z"]-5)
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
		# Матрицу-появление при РУЧНОЙ постановке не играем (выглядела так себе). Эффект теперь
		# только когда машина строится с нуля — спавн/загрузка/смена сборки (blocks.spawn_block).
		block_take = false
		build_basis = Basis()          # сброс ручного поворота под следующий блок
		_preview_res = null
		Q.report("block_placed", 1)             # прогресс заданий на сборку
	elif block_body != null and is_instance_valid(block_body):
		if block_body.get_parent().name in "blocks":
			block_map_node.remove_block(BuildingBlock["x"], BuildingBlock["y"], BuildingBlock["z"])
			# Структурная целостность и В СТРОЙКЕ: сняли блок → сосед, потерявший ВСЕ связи с
			# кабиной/базой, отрывается и падает в мир (тот же BFS, что при боевом разрушении).
			if block_map_node.has_method("_detach_orphans"):
				block_map_node.call_deferred("_detach_orphans")
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
		_cabin_ground = null
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
	# Сброс стройочного состояния: старые блоки сейчас будут удалены, и подвисшие ссылки
	# ломали стройку — block_body указывал на мёртвый блок (краш при «Взять»), а светяшка
	# застывала в воздухе на его последней позиции.
	block_body = null
	_preview_res = null
	_cabin_ground = null
	if ghost_block:
		ghost_block.visible = false
	block_map_node.apply_layout(layout)     # сам чистит коллизии блоков и пересобирает
	_connect_cabin()                        # новая кабина — заново ловим её гибель

# Блок из руки → обратно в инвентарь (при выходе из стройки и при замене руки).
# Синхронный remove_child до queue_free — takepos не держит два блока разом.
func _return_hand_to_inventory() -> void:
	if not (block_take and block_body != null and is_instance_valid(block_body)):
		return
	G.block_inventory.append(int(block_body.block))
	G.mark_progress_dirty()
	var prev_parent: Node = block_body.get_parent()
	if prev_parent:
		prev_parent.remove_child(block_body)
	block_body.queue_free()
	block_body = null
	block_take = false
	_preview_res = null
	if ghost_block:
		ghost_block.visible = false

func take_block_into_hand(block_type: int) -> bool:
	var scene: PackedScene = G.get_scene(block_type)
	if scene == null:
		return false
	# Рука занята → кладём текущий блок в инвентарь и берём новый (замена). Раньше тут был
	# отказ (return false), и выбор нового блока из инвентаря игнорировался.
	_return_hand_to_inventory()
	var instance = scene.instantiate()
	var holder: Node = camera_controller.camera.get_child(0)   # takepos Marker3D
	holder.add_child(instance)
	if instance is Node3D:
		instance.position = Vector3.ZERO
		instance.scale = Vector3.ONE
		BlockFX.play(instance, false)      # глитч появления блока в руке (как при спавне)
	block_body = instance
	block_take = true
	build_basis = Basis()          # свежий блок — без ручного поворота
	_preview_res = null
	_cabin_ground = null
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
