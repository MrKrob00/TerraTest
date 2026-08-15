extends MachineBody

# ══════════════════════════════════════════
# ЭКСПОРТИРУЕМЫЕ ПАРАМЕТРЫ
# ══════════════════════════════════════════

@export var faction: int = 0  # 0 = игрок

@export var RADIUS: float = 8.0
@export var CAM_HEIGHT: float = 8.0
@export var ROT_SPEED: float = 1.5
@onready var camera_controller: Node3D = $"../Camera Controller"

# ══════════════════════════════════════════
# ВНУТРЕННИЕ ПЕРЕМЕННЫЕ
# ══════════════════════════════════════════

var is_active: bool = false
var Building: bool = false
var block_body

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
var _solar_count: int = 0            # кеш числа солнечных блоков (обновляется вместе с _cap_timer)

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
	if _cap_timer <= 0.0:
		_cap_timer = 0.5
		var batteries := 0
		_solar_count = 0
		if block_map_node != null:
			for b in block_map_node.get_children():
				match b.get("block"):
					G.Block.BATTERY: batteries += 1
					G.Block.SOLAR:   _solar_count += 1
		_energy_cap = batteries * BATTERY_CAP
		_energy = minf(_energy, _energy_cap)
	if anchored and _solar_count > 0:
		energy_produce(_solar_count * SOLAR_RATE * delta)

# ── Якорь (фиксация к миру, как в TerraTech) ──────────────────────────────────
var anchored: bool = false
var _anchor_column: MeshInstance3D = null
var _anchor_tween: Tween = null
# Стационарная структура (база): спавнится сразу на якоре, снять якорь/ехать нельзя.
# Ставится флаг при спавне через _place_ground_structure (ядро — стационарный блок).
var is_station: bool = false
const ANCHOR_MAX_RISE := 0.5      # м: максимальный перепад земли под машиной для фиксации
const ANCHOR_MAX_HEIGHT := 2.5    # м: выше этого над землёй якорить нельзя (прыжок/полёт)


# Словник: { shape_owner_id (int) : block_node (Node) }

	# Автоматично зв'язуємо колізії з блоками при старті
# ══════════════════════════════════════════
# ИНИЦИАЛИЗАЦИЯ
# ══════════════════════════════════════════

func _ready() -> void:
	mass = base_weight
	init_machine_physics()
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
var _cabin: Node = null            # текущая кабина; невалидна → сборка сменилась или её снесли
var _had_cabin: bool = false       # была ли кабина хоть раз (станции её не имеют — они не гибнут)

func _connect_cabin() -> void:
	if block_map_node == null:
		return
	for b in block_map_node.get_children():
		if b.get("block") == G.Block.CABIN:
			_cabin = b
			_had_cabin = true
			if b.has_signal("destroyed") and not b.destroyed.is_connected(_on_cabin_destroyed):
				b.destroyed.connect(_on_cabin_destroyed)
			return
	_cabin = null

# Сторож кабины. Один сигнал — ненадёжная опора: _connect_cabin молча ничего не делает,
# если в момент вызова кабины среди детей ещё/уже нет (сборка перестраивается корутинами,
# сейв применяется позже _ready). Промах означал машину БЕЗ кабины, которую нельзя убить:
# оставался голый кузов с коллизией, камера на нём, возрождение не запускалось.
# Здесь смерть определяется по ФАКТУ отсутствия кабины, а сигнал остаётся быстрым путём.
const CABIN_WATCH_INTERVAL: float = 0.5
var _cabin_watch_t: float = 0.0

func _cabin_watch(delta: float) -> void:
	if _dying or is_station:
		return
	_cabin_watch_t -= delta
	if _cabin_watch_t > 0.0:
		return
	_cabin_watch_t = CABIN_WATCH_INTERVAL
	if is_instance_valid(_cabin):
		return
	_connect_cabin()                       # сборка сменилась — переподписываемся
	if is_instance_valid(_cabin):
		return
	if _had_cabin:
		_die()                             # кабины нет, а сигнал не пришёл

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
		if "block" in b and int(b.block) in [G.Block.SUPPORT, G.Block.ROT_SUPPORT]:
			return true
	return false

# ВРАЩАЮЩАЯСЯ ОПОРА: тир выше обычной. На якоре ею можно доворачивать машину джойстиком
# движения — база перестаёт быть намертво приколоченной, и продавца/бур можно навести
# куда надо, не снимая якорь.
const ROT_SUPPORT_SPEED: float = 1.2      # рад/с при полностью отклонённом джойстике

func has_rot_support() -> bool:
	if block_map_node == null:
		return false
	for b in block_map_node.get_children():
		if "block" in b and int(b.block) == G.Block.ROT_SUPPORT:
			return true
	return false

# Разворот на якоре. Крутим transform напрямую, а не крутящим моментом: тело заморожено
# якорем, физика его вращать не станет.
func _rot_support_tick(delta: float) -> void:
	if not anchored or is_station or not has_rot_support():
		return
	if camera_controller == null or camera_controller.joystick_move == null:
		return
	var joy: Vector2 = camera_controller.joystick_move.get_joystick_dir()
	if absf(joy.x) < 0.15:
		return
	global_rotation.y -= joy.x * ROT_SUPPORT_SPEED * delta

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
	freeze = true
	anchored = true
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
	_rebuild_factory()                    # цепочка фабрики свежая к запуску под якорем
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
	_rebuild_factory()
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
						and (col.position == n3.position \
						or col.position == n3.position + BIG_BLOCK_COL_OFFSET):
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
		var orb: Node3D = REWARD_ORBITER.new()                      # untyped → setup() зовётся динамически
		scn.add_child(orb)
		orb.setup(self, int(types[i]), TAU * float(i) / float(n))

# ══════════════════════════════════════════
# ГЛАВНЫЙ ЦИКЛ
# ══════════════════════════════════════════

func _physics_process(delta: float) -> void:
	# Энергия тикает ВСЕГДА (даже у неактивной машины): база на якоре копит от солнца.
	_energy_tick(delta)
	_cabin_watch(delta)
	_rot_support_tick(delta)
	# Защита работает и у НЕактивной машины: стоит и отстреливается от врагов рядом.
	if defense_mode:
		_defense_tick(delta)
	if !is_active:
		return
	if anchored:
		return                      # на якоре не ездим (freeze держит тело)
	if Building:
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

	var joy: Vector2 = camera_controller.joystick_move.get_joystick_dir()
	# ПК: WASD/стрелки дают тот же Vector2, что и тач-джойстик (см. _process_input ниже).
	# Суммируем с джойстиком и клампим — вместе на практике не используются, но так честно.
	# Гасим клавиатурную часть, пока фокус в текстовом поле (напр. поиск в гараже) —
	# иначе набор "wasd" в строке поиска ещё и гонял бы машину.
	if not typing:
		joy = (joy + Input.get_vector("move_left", "move_right", "move_forward", "move_back")).limit_length(1.0)
	_process_input(joy, delta)
	sense_ground(delta)
	drive_physics(delta)

# ══════════════════════════════════════════
# ОБРАБОТКА ВВОДА
# ══════════════════════════════════════════

# Игрок держит блоки в узле, заданном через инспектор, а не по фиксированному имени.
func _blocks_root() -> Node:
	return block_map_node if block_map_node != null else get_node_or_null("blocks")

func _process_input(joy: Vector2, delta: float) -> void:
	# joy.y вверх = -1 на большинстве джойстиков → газ вперёд
	# Если едет назад при нажатии вперёд — убери минус
	var raw_throttle: float = -joy.y
	var raw_steer: float = joy.x

	if abs(raw_throttle) < 0.08: raw_throttle = 0.0
	if abs(raw_steer) < 0.05:    raw_steer = 0.0

	_throttle = raw_throttle

	# Угол руля: уменьшается на скорости
	var speed_ratio: float = clamp(linear_velocity.length() / max_speed, 0.0, 1.0)
	var angle_limit: float = deg_to_rad(steer_max_angle) * (1.0 - speed_steer_reduction * speed_ratio)
	var target_steer: float = -raw_steer * angle_limit
	_steer_angle = lerp(_steer_angle, target_steer, steer_speed * delta)

	push_drive_input(raw_steer)

# ══════════════════════════════════════════
# КОНТАКТ С ЗЕМЛЁЙ
# ══════════════════════════════════════════


# Землю щупает КАЖДОЕ колесо у себя под собой. Прежний вариант — один луч из центра
# корпуса на 1.4 — ломался, как только машина становилась выше кабины: центр уезжал
# вверх вместе с постройкой, луч переставал доставать, и вместе с `_on_ground`
# отключались разом тяга, сцепление и поворот. Колёса же всегда там, где контакт.

# Доля колёс на земле: 1.0 — вся машина в контакте, 0.25 — висит на одном колесе.
# Без колёс возвращаем 1.0, иначе стационарные постройки лишились бы сцепления.

# ══════════════════════════════════════════
# СИНХРОНИЗАЦИЯ МАССЫ
# ══════════════════════════════════════════


# Блоки, принимающие газ/руль (колёса). Кеш инвалидируется по числу детей $blocks.

# Низ машины в локальных координатах (отрицательный) — нужен проверке земли без колёс.
# Сколько на машине блоков помимо кабины. 0 = голая кабина, ей разрешено ползти самой.

# Пересчитывает массу, центр масс и низ корпуса за один проход по блокам.
# Массу теперь дают ВСЕ блоки, а не только колёса: иначе постройка не влияла бы
# ни на разгон, ни на инерцию, и сборка машины ничего не решала.

# ══════════════════════════════════════════
# ТЯГА ДВИГАТЕЛЯ
# ══════════════════════════════════════════

# Суммарная тяга ведущих колёс, СТОЯЩИХ на земле. Колесо в воздухе не толкает.

# ══════════════════════════════════════════
# ВСПОМОГАТЕЛЬНЫЕ
# ══════════════════════════════════════════


# Кто передний, а кто задний, определяется РАСПОЛОЖЕНИЕМ колёс, а не флагом is_front:
# этот флаг нигде не выставлялся и у всех колёс оставался true, из-за чего база всегда
# была заглушкой 2.0, и длина машины никак не влияла на радиус поворота.
# Вперёд у нас -Z (см. _get_forward), поэтому переднее колесо — то, у которого z меньше.

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
var BuildingBlock: Dictionary = { "build": true, "x": 5, "y": 5, "z": 5, "block": 1 }  # дефолт = центр сетки 11³

# Ориентация блока в руке = авто по грани (наклон/поворот) ∘ ручная (кнопки UI поворота).
var build_basis: Basis = Basis()
var _rc_cache: Node3D = null       # кеш узла Camera3D/Raycast (find_child — рекурсивный поиск)
var _hover_ms: int = 0             # троттл наведения мышью (ховер шлёт до 1000 событий/с)
var _preview_res = null            # последний res для превью (чтобы переприменить при повороте)
var _cabin_ground = null           # Vector3|null: куда на ЗЕМЛЮ ставим кабину (новая машина)
var _hand_from_inventory := false  # блок в руке взят из инвентаря (а не снят с машины) — для авто-добора

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
# Двойной тап = «подтверждение» (взять/поставить). Одиночный только наводит/подсвечивает.
var _dbl_tap_ms: int = 0
var _dbl_tap_pos: Vector2 = Vector2.ZERO
var _last_touch_ms: int = 0    # был недавно тач → эмулированную мышь игнорируем (иначе двойной тап
#                                срабатывал ДВАЖДЫ: взял блок и тут же поставил обратно)

func _input(event: InputEvent) -> void:
	if !is_active: return
	if event is InputEventScreenTouch:
		_touch_count = maxi(_touch_count + (1 if event.pressed else -1), 0)
		_last_touch_ms = Time.get_ticks_msec()
	# Подбор и постановка блока работают В ЛЮБОМ РЕЖИМЕ. Раньше весь разбор тапа лежал под
	# `if Building`, и вне стройки тап по миру не делал ВООБЩЕ ничего: чтобы поднять блок,
	# приходилось лезть в режим. Режим стройки остаётся, но теперь он именно то, чем должен
	# быть, — удобства ради (глобус блоков, повороты, превью), а не пропуск к самому действию.
	# Конфликтовать здесь не с чем: оружие наводится само, по своей зоне обнаружения, и тап
	# в него не передаётся; орбита камеры отделена по свайпу (_build_tap_moved).
	if (event is InputEventMouseMotion \
			or (event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed)) \
			and Time.get_ticks_msec() - _last_touch_ms > 250:   # не эмулированная-из-тача мышь
		# Ховер мыши шлёт до 1000 событий в секунду, и КАЖДОЕ гоняло полный пайплайн наведения
		# (проверка HUD + DDA-луч по сетке + пересборка превью). Для наведения хватает ~60 Гц;
		# КЛИК пропускаем всегда, чтобы постановка блока не «проглатывалась» троттлом.
		var _is_click := event is InputEventMouseButton
		var _now_ms := Time.get_ticks_msec()
		if not _is_click and _now_ms - _hover_ms < 16:
			return
		_hover_ms = _now_ms
		# Не целимся в мир, когда указатель над интерактивным HUD (см. _tap_over_ui).
		if not _tap_over_ui(event.position):
			_handle_click(event.position)          # наводим/подсвечиваем (ховер и клик)
			# ДВОЙНОЙ клик мышью = подтверждение: поставить блок из руки / взять наведённый.
			if event is InputEventMouseButton and event.double_click:
				_commit_build_tap(event.position)
	elif event is InputEventScreenTouch:
		if event.pressed:
			_build_tap_pos = event.position
			_build_tap_ms = Time.get_ticks_msec()
			_build_tap_moved = false
		elif _touch_count == 0 and not _build_tap_moved \
				and Time.get_ticks_msec() - _build_tap_ms < 250 \
				and not _tap_over_ui(event.position):
			_handle_click(event.position)          # ОДИНОЧНЫЙ тап = навести/подсветить блок
			# ДВОЙНОЙ тап (второй за ~340мс рядом) = подтверждение: взять/поставить.
			var _now := Time.get_ticks_msec()
			if _now - _dbl_tap_ms < 340 and _dbl_tap_pos.distance_to(event.position) < 45.0:
				_commit_build_tap(event.position)
				_dbl_tap_ms = 0                    # съели двойной — не склеиваем в тройной
			else:
				_dbl_tap_ms = _now
				_dbl_tap_pos = event.position
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
	# Одна кнопка HUD на оба режима: она шлёт ModeToggle, а куда переключаться — решаем
	# по текущему состоянию. Movement/Building остаются отдельными действиями: их зовут
	# изнутри (взял блок в руку → стройка) и под них можно повесить клавиши на ПК.
	if event.is_action_pressed("ModeToggle"):
		if Building: _on_movement_pressed()
		else:        _on_building_pressed()

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
	if Building:
		Q.report("mode_movement", 1)          # шаг обучения «выйти из стройки»
	Building = false
	ghost_block.visible = false
	if not is_station:            # станция всегда на якоре — Movement не должен её размораживать
		freeze = false
	var up: Vector3 = global_transform.basis.y
	if up.dot(Vector3.UP) < 0.3:
		global_rotation.z = 0
		global_rotation.x = 0
	_rebuild_factory()            # авто-коннект фабрики по соседству (без ручного поворота)

# Пересобрать связи фабричной цепочки (поле потока к продавцу/генератору). Зовём при выходе
# из стройки и при постановке на якорь — чтобы цепочка была свежей к моменту запуска фабрики.
func _rebuild_factory() -> void:
	if block_map_node != null and block_map_node.has_method("rebuild_factory_links"):
		block_map_node.rebuild_factory_links()

var map:float = 0.0
func _on_building_pressed() -> void:
	if Building: return
	if not is_instance_valid(ghost_block):
		push_warning("ghost_block недоступен — постройка невозможна")
		return
	Q.report("mode_building", 1)              # шаг обучения «войти в стройку»
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

# Интерактивные узлы HUD, тап по которым НЕ должен наводить блок в мир.
const _UI_HIT_NODES := ["Take", "TakeOff", "Attack", "ModeToggle",
		"Joystick_movement", "Joystick_camera"]

# Пришёлся ли указатель на интерактивный HUD? На ПК hover-контрол ловит это сам. На ТАЧЕ
# gui_get_hovered_control после отрыва пальца врёт (hover «висит» пусто), из-за чего тап по
# кнопке «Place» повторно гнал _handle_click по её координатам и перенаводил блок. Поэтому
# бьём по геометрии: rect у Control-кнопок (Take/TakeOff/Attack) и shape у TouchScreenButton
# (джойстики/Movement/Building) — ровно так, как сам TouchScreenButton считает своё нажатие.
func _tap_over_ui(pos: Vector2) -> bool:
	if get_viewport().gui_get_hovered_control() != null:
		return true
	var hud: CanvasLayer = camera_controller.hud if (camera_controller and "hud" in camera_controller) else null
	if hud == null:
		return false
	for nm in _UI_HIT_NODES:
		var n: Node = hud.get_node_or_null(nm)
		if n == null or not (n is CanvasItem) or not n.visible:
			continue
		if n is Control and (n as Control).get_global_rect().has_point(pos):
			return true
		if n is TouchScreenButton and _tsb_hit(n as TouchScreenButton, pos):
			return true
	return false

# Точка pos внутри области нажатия TouchScreenButton (учитываем shape_centered, как движок).
# ВАЖНО: при shape_centered движок центрует форму по ПРЯМОУГОЛЬНИКУ ТЕКСТУРЫ (её левый
# верх = позиция ноды), а не по началу координат. У джойстиков текстуры нет — прямоугольник
# нулевой, центр совпадает с нодой; у кнопки режима текстура есть, и центр смещён на её
# половину. Считали от ноды — область нажатия уезжала на пол-кнопки вверх-влево, и тап по
# её нижней половине уходил в мир (наводил блок).
func _tsb_hit(b: TouchScreenButton, pos: Vector2) -> bool:
	var s: Shape2D = b.shape
	if s == null:
		return false
	var o: Vector2 = b.global_position
	var center: Vector2 = o
	if b.shape_centered and b.texture_normal != null:
		center += b.texture_normal.get_size() * 0.5
	if s is RectangleShape2D:
		var sz: Vector2 = (s as RectangleShape2D).size
		var tl: Vector2 = (center - sz * 0.5) if b.shape_centered else o
		return Rect2(tl, sz).has_point(pos)
	if s is CircleShape2D:
		var r: float = (s as CircleShape2D).radius
		return (center if b.shape_centered else o + Vector2(r, r)).distance_to(pos) <= r
	return false

func _handle_click(screen_pos: Vector2) -> void:
	var camera: Camera3D = camera_controller.camera
	var world_origin: Vector3 = camera.project_ray_origin(screen_pos)
	var world_dir: Vector3 = camera.project_ray_normal(screen_pos)
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
			var held_bt: int = holder.get_child(0).get("block")
			# Кабина → всегда новая машина на землю. Стационар → новая база на землю, ТОЛЬКО
			# если сейчас управляем МАШИНОЙ; если управляем СТАНЦИЕЙ — идёт обычным путём
			# сетки (прикрепляется к базе, can_attach разрешает стационар-на-стационар).
			if held_bt == G.Block.CABIN or (G.is_stationary(held_bt) and not is_station):
				_preview_cabin_ground(world_origin, world_dir)
				return
	var space_node: Node3D = block_map_node if block_map_node else self
	var ray_origin: Vector3 = space_node.to_local(world_origin) + Vector3(5, 5, 5)
	var ray_dir: Vector3 = (space_node.global_transform.basis.inverse() * world_dir).normalized()
	var res: Dictionary = _find_nearest_block_on_ray(ray_origin, ray_dir)
	if not res["hit"]:
		res = _cell_from_physics(screen_pos)   # DDA промахнулся — спрашиваем физику (см. ниже)
	if block_take:
		# Больше НЕ светяшка: двигаем сам взятый блок на выбранную ячейку (превью), тап Take ставит.
		if res["hit"]: _preview_held(res)
		return
	else:
		# look_at ломается, когда направление почти вертикально (клик СТРОГО «по земле» — взгляд
		# вниз): базис вырождается, и на экспортной сборке это тихий креш без ошибки в консоли.
		# Целимся Raycast'ом только если луч не вертикален (как уже сделано для пуль в WeaponBlock).
		# Узел статичен (Camera3D/Raycast) — кешируем. find_child() это РЕКУРСИВНЫЙ поиск с
		# сопоставлением имён по всему поддереву камеры, а звался он на каждом наведении.
		if _rc_cache == null or not is_instance_valid(_rc_cache):
			_rc_cache = camera.find_child("Raycast") as Node3D
		var _rc: Node3D = _rc_cache
		if _rc != null and absf(world_dir.dot(Vector3.UP)) < 0.99:
			_rc.process_mode = Node.PROCESS_MODE_DISABLED
			_rc.look_at(camera.global_position + world_dir)
			_rc.process_mode = Node.PROCESS_MODE_INHERIT
	if !block_take and res["hit"]:
		_place_ghost(res, false)
		block_body = block_map_node.find_block(BuildingBlock["x"], BuildingBlock["y"], BuildingBlock["z"])
		res["hit"] = false
	elif !block_take:
		block_body = null                # тап/ховер мимо блока — снимаем выделение, иначе тап-захват
		if ghost_block: ghost_block.visible = false   # взял бы устаревший block_body по промаху

# Запасная наводка на клетку — ФИЗИКОЙ. У взятия блока такой путь есть давно
# (_grab_world_block), у постановки не было: промахнулся луч по сетке — блок молча оставался
# в руке, и поставить его было нечем. DDA идёт по данным карты и промахивается, когда луч
# скользит по грани или машина наклонена; физический луч бьёт по реальным коллизиям блоков.
# Точка удара + нормаль дают ровно то же, что DDA: занятую клетку (уходим на пол-клетки
# ВНУТРЬ по нормали) и грань, к которой цепляемся (направление самой нормали).
func _cell_from_physics(screen_pos: Vector2) -> Dictionary:
	var miss := {"hit": false, "x": 0, "y": 0, "z": 0, "block_name": "", "face": ""}
	if camera_controller == null or camera_controller.camera == null or block_map_node == null:
		return miss
	var cam: Camera3D = camera_controller.camera
	var from: Vector3 = cam.project_ray_origin(screen_pos)
	var q := PhysicsRayQueryParameters3D.create(from, from + cam.project_ray_normal(screen_pos) * 500.0)
	var hit: Dictionary = get_world_3d().direct_space_state.intersect_ray(q)
	if hit.is_empty() or hit.get("collider") != self:
		return miss                        # попали не в машину (земля, чужой блок) — это не наводка
	var basis_inv: Basis = block_map_node.global_transform.basis.inverse()
	var n: Vector3 = (basis_inv * (hit["normal"] as Vector3)).normalized()
	var p: Vector3 = block_map_node.to_local(hit["position"] as Vector3) - n * 0.5
	var cx := int(round(p.x)) + 5
	var cy := int(round(p.y)) + 5
	var cz := int(round(p.z)) + 5
	if not _in_bounds(cx, cy, cz):
		return miss
	var block: int = block_map_node.get_block(cx, cy, cz)
	if block == 0:
		return miss
	# Имена граней = НАПРАВЛЕНИЕ наружу (см. _place_ghost: "right" → x+1). Берём ось, по
	# которой нормаль длиннее всего: у куба она и есть та грань, в которую ткнули.
	var face := ""
	if absf(n.x) >= absf(n.y) and absf(n.x) >= absf(n.z):
		face = "right" if n.x > 0.0 else "left"
	elif absf(n.y) >= absf(n.z):
		face = "top" if n.y > 0.0 else "bottom"
	else:
		face = "back" if n.z > 0.0 else "front"
	return {"hit": true, "x": cx, "y": cy, "z": cz,
			"block_name": _get_block_name(block), "face": face}

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

# Имя грани → направление от центра блока наружу. Оно же связывает имена разъёмов
# (connect_faces у самого блока) с осями модели.
const FACE_DIR := {
	"right": Vector3.RIGHT, "left": Vector3.LEFT,
	"top": Vector3.UP, "bottom": Vector3.DOWN,
	"back": Vector3.BACK, "front": Vector3.FORWARD,
}

# Разворот блока при установке: одна из его ГРАНЕЙ СТЫКОВКИ обязана смотреть на соседа.
# Сосед лежит с той стороны, откуда пришла грань, то есть в направлении −FACE_DIR[face].
#
# Грани блок объявляет сам — экспортом connect_faces (галочки в инспекторе его сцены,
# см. VehicleBlock). Отмечены все шесть (так по умолчанию) — доворачивать не надо, любая
# сторона уже подходит, блок встаёт ровно. Отмечена одна («Back» у бура) — блок развернётся
# ею к соседу на какой угодно грани.
#
# Из нескольких отмеченных граней берём ТУ, которой поворачивать МЕНЬШЕ ВСЕГО, причём с
# учётом ручного поворота игрока (build_basis): выкрутил блок в UI как надо — доворот его
# не сломает.
#
# Сам поворот СЧИТАЕТСЯ, а не перечисляется по случаям, поэтому работает на любой из шести
# граней и для любого набора галочек.
func _face_orient(face: String, node: Node, manual: Basis = Basis()) -> Basis:
	if not FACE_DIR.has(face) or not (node is VehicleBlock):
		return Basis()
	var vb := node as VehicleBlock
	var vecs: Array = vb.connect_vecs()
	if vecs.is_empty() or vecs.size() >= 6:
		return Basis()                     # стыкуется чем угодно — ставим как есть
	var want: Vector3 = -(FACE_DIR[face] as Vector3)
	var best: Vector3 = vecs[0]
	var best_dot: float = -2.0
	for v in vecs:
		var d: float = (manual * (v as Vector3)).normalized().dot(want)
		if d > best_dot:
			best_dot = d
			best = v
	return _rotation_between((manual * best).normalized(), want)

# Кратчайший поворот, переводящий направление from_dir в to_dir.
func _rotation_between(from_dir: Vector3, to_dir: Vector3) -> Basis:
	var a: Vector3 = from_dir.normalized()
	var b: Vector3 = to_dir.normalized()
	var d: float = a.dot(b)
	if d > 0.9999:
		return Basis()
	if d < -0.9999:
		# Строго противоположны: ось поворота не определена, берём любую перпендикулярную.
		var any: Vector3 = Vector3.UP if absf(a.dot(Vector3.UP)) < 0.9 else Vector3.RIGHT
		return Basis(a.cross(any).normalized(), PI)
	return Basis(a.cross(b).normalized(), a.angle_to(b))

# Ставим сам взятый блок на выбранную ячейку (превью реальным блоком, не светяшкой).
func _preview_held(res: Dictionary) -> void:
	var holder: Node = camera_controller.camera.get_child(0)
	if holder.get_child_count() == 0:
		return
	var instance: Node3D = holder.get_child(0)
	_preview_res = res
	# Сдвиг якоря к выбранной грани — с учётом РАЗМЕРА блока (attach_delta), чтобы многоклеточные
	# (процессор/продавец) вставали и СБОКУ, а не только наверх (см. blocks.attach_delta).
	var ad :Vector3 = block_map_node.attach_delta(int(instance.block), String(res.face))
	var gx: float = float(res.x) + ad.x
	var gy: float = float(res.y) + ad.y
	var gz: float = float(res.z) + ad.z
	BuildingBlock["x"] = gx; BuildingBlock["y"] = gy; BuildingBlock["z"] = gz
	var placeable: bool = block_map_node.can_attach(int(res.x), int(res.y), int(res.z),
			instance, res.face) and block_map_node.can_place(instance.block, gx, gy, gz)
	if not placeable:
		instance.top_level = false
		instance.position = Vector3.ZERO       # обратно в руку
		instance.rotation = Vector3.ZERO
		if ghost_block:
			ghost_block.visible = false
		return
	var orient := _face_orient(res.face, instance, build_basis) * build_basis
	var local_pos := Vector3(gx - 5, gy - 5, gz - 5)
	var world_basis: Basis = (block_map_node.global_transform.basis * orient).orthonormalized()
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
	inst.global_transform = Transform3D(Basis(Vector3.UP, build_basis.get_euler().y), _cabin_ground + Vector3.UP * 1.2)
	if ghost_block:
		ghost_block.visible = false

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
	if v is Node3D:
		v.global_rotation.y = build_basis.get_euler().y   # уважаем ручной поворот игрока (как в превью)
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
	var hud: CanvasLayer = camera_controller.hud if (camera_controller and "hud" in camera_controller) else null
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

# Взятый в руку блок (child takepos-маркера под камерой) или null, если рука пуста.
func _hand_instance() -> Node3D:
	if camera_controller == null or camera_controller.camera == null:
		return null
	if camera_controller.camera.get_child_count() == 0:
		return null
	var holder: Node = camera_controller.camera.get_child(0)
	if holder == null or holder.get_child_count() == 0:
		return null
	return holder.get_child(0) as Node3D

# Ручной поворот/наклон блока (кнопки UI). Крутим СРАЗУ:
#  • если блок наведён на клетку машины (превью, top_level) — переприменяем превью с
#    ориентацией по грани (_face_orient ∘ build_basis);
#  • если блок просто в руке — вращаем его прямо под камерой (build_basis как локальный базис),
#    ставить на машину для этого больше не нужно.
# build_basis копится в обоих случаях, поэтому наклон сохраняется до самой постановки.
func rotate_build(axis: Vector3, ang: float) -> void:
	build_basis = (Basis(axis, ang) * build_basis).orthonormalized()
	if not block_take:
		return
	var held := _hand_instance()
	if held == null:
		return
	if held.top_level and _preview_res != null:
		_preview_held(_preview_res)          # наведён на клетку — с ориентацией по грани
	else:
		held.basis = build_basis             # в руке — крутится сразу под камерой

var result: Dictionary = {"hit": false, "x": 0, "y": 0, "z": 0, "block_name": "", "face": ""}
func _find_nearest_block_on_ray(origin: Vector3, direction: Vector3) -> Dictionary:
	result = {"hit": false, "x": 0, "y": 0, "z": 0, "block_name": "", "face": ""}
	var dir: Vector3 = direction
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
			var block: int = block_map_node.get_block(cx, cy, cz)
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
	var names: Array = G.Block.keys()
	if block < names.size(): return names[block]
	return "UNKNOWN"

# Снять НАВЕДЁННЫЙ блок машины (block_body) в руку. Ядро (кабину/стационар) не трогаем.
# Общий код для кнопки Take и для тапа-по-блоку (см. _maybe_grab_on_tap). Возвращает true,
# если блок реально взят.
func _pick_selected_block() -> bool:
	if block_body == null or not is_instance_valid(block_body):
		return false
	var bt := int(block_body.get("block"))
	if bt == G.Block.CABIN or G.is_stationary(bt):
		return false                              # ядро сборки не снимаем
	if block_body.get_parent() != null and block_body.get_parent().name == "blocks":
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
	Q.report("block_taken_world", 1)               # шаг обучения: блок в руке, откуда — неважно
	_hand_from_inventory = false                   # снят с машины, не из инвентаря — без авто-добора
	build_basis = Basis()
	_preview_res = null
	_cabin_ground = null
	if ghost_block:
		ghost_block.visible = false                # блок взят в руку — светяшка больше не нужна
	_notify_build_changed()                        # машина стала легче — панель справа обновляем
	return true

# Гараж открыт ВСЮ стройку (вкладка СТРОЙКА), поэтому вес и характеристики пересчитываем
# на каждом блоке, а не только при заходе в инвентарь.
func _notify_build_changed() -> void:
	var hud: CanvasLayer = camera_controller.hud \
			if (camera_controller != null and "hud" in camera_controller) else null
	if hud != null and hud.has_method("notify_build_changed"):
		hud.notify_build_changed()

# Авто-добор такого же блока из инвентаря после постановки (серийная стройка).
func _refill_hand_from_inventory(bt: int) -> void:
	if not G.block_inventory.has(bt):
		return
	if take_block_into_hand(bt):
		G.block_inventory.erase(bt)                # списываем экземпляр (как tech_ui._take_into_hand)
		G.mark_progress_dirty()

# Подтверждение стройки по ДВОЙНОМУ тапу/клику (кнопка Take не нужна): держим блок в руке → СТАВИМ
# его; рука пуста → БЕРЁМ наведённый блок. Одиночный тап только наводит/подсвечивает (_handle_click).
var _last_commit_ms: int = 0
func _commit_build_tap(screen_pos: Vector2) -> void:
	var now := Time.get_ticks_msec()
	if now - _last_commit_ms < 250:
		return                           # антидубль: на мобилке тач И эмулированная мышь дают двойной
	_last_commit_ms = now
	if block_take:
		_on_take_pressed()               # поставить блок из руки (или наземное ядро — кабина/база)
	else:
		_maybe_grab_on_tap(screen_pos)   # взять наведённый блок машины / свободный блок из мира

# Взять В РУКУ наведённый блок машины (block_body из _handle_click) ИЛИ свободный блок из мира
# (физ-луч из точки тапа). Зовётся из _commit_build_tap по двойному тапу, когда рука пуста.
func _maybe_grab_on_tap(screen_pos: Vector2) -> void:
	if block_take:
		return
	# 1) Блок на МАШИНЕ (block_body уже наведён grid-лучом) — снять в руку.
	if block_body != null and is_instance_valid(block_body) \
			and block_body.get_parent() != null and block_body.get_parent().name == "blocks":
		_pick_selected_block()
		return
	_grab_world_block(screen_pos)

# Взять СВОБОДНЫЙ блок из мира (RigidBody-VehicleBlock под /root/Main/objects) в руку по клику.
func _grab_world_block(screen_pos: Vector2) -> bool:
	if camera_controller == null or camera_controller.camera == null:
		return false
	var cam: Camera3D = camera_controller.camera
	var from: Vector3 = cam.project_ray_origin(screen_pos)
	var to: Vector3 = from + cam.project_ray_normal(screen_pos) * 500.0
	var q := PhysicsRayQueryParameters3D.create(from, to)
	q.collision_mask = 2                           # VehicleBlock.collision_layer = 2 (свободные блоки)
	q.exclude = [get_rid()]                         # не цепляем саму машину
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	if hit.is_empty():
		return false
	var body: Node3D = hit.get("collider")
	var objects := get_node_or_null("/root/Main/objects")
	if objects == null or not (body is Node3D) or body.get_parent() != objects or not ("block" in body):
		return false                               # только свободный блок, реально лежащий в мире
	var bt := int(body.get("block"))
	if bt == G.Block.CABIN or G.is_stationary(bt):
		return false
	_return_hand_to_inventory()                    # рука должна быть пустой (перестраховка от лишних блоков)
	body.reparent(camera_controller.camera.get_child(0), false)   # в takepos под камерой
	if body is Node3D:
		body.top_level = false
		body.position = Vector3.ZERO
		body.rotation = Vector3.ZERO
	if body is RigidBody3D:
		body.freeze = true
		body.linear_velocity = Vector3.ZERO
		body.angular_velocity = Vector3.ZERO
	block_body = body
	Q.report("block_taken_world", 1)          # шаг обучения «взять блок в руку»
	block_take = true
	_hand_from_inventory = false                   # из мира, не из инвентаря — без авто-добора
	build_basis = Basis()
	_preview_res = null
	_cabin_ground = null
	if ghost_block:
		ghost_block.visible = false
	_on_building_pressed()                          # гарантируем режим стройки (if Building: return внутри)
	return true

func _on_take_pressed() -> void:
	if block_take:
		var instance: VehicleBlock = camera_controller.camera.get_child(0).get_child(0)
		# Кабина → новая машина; стационар (с машины) → новая база. Ставятся В МИР на землю.
		# Стационар на СТАНЦИИ на землю не идёт (_cabin_ground будет null — превью шло сеткой).
		if _cabin_ground != null and (instance.get("block") == G.Block.CABIN \
				or (G.is_stationary(instance.get("block")) and not is_station)):
			_place_ground_structure(instance)
			return
		if _preview_res == null:
			return
		var pres: Dictionary = _preview_res
		if not block_map_node.can_place(instance.block, BuildingBlock["x"], BuildingBlock["y"], BuildingBlock["z"]):
			return
		# Точки стыковки: пускает ли сосед к своей грани (см. connect_faces в инспекторе блока).
		if not block_map_node.can_attach(int(pres.x), int(pres.y), int(pres.z), instance, pres.face):
			return
		# Превью держало блок top_level (мировой трансформ). Перед постановкой возвращаем
		# наследование, иначе local basis/position ниже применятся как мировые.
		instance.top_level = false
		# Полная ориентация: авто по грани (наклон/разворот колеса) ∘ ручной поворот из UI.
		var orient := _face_orient(pres.face, instance, build_basis) * build_basis
		instance.basis = orient
		instance.position = Vector3(BuildingBlock["x"]-5, BuildingBlock["y"]-5, BuildingBlock["z"]-5)
		var collision: CollisionShape3D = instance.get_child(0).duplicate()
		collision.transform = Transform3D(orient, instance.position)   # коллизия наклоняется вместе
		if collision.shape.size == Vector3(2,2,2):
			collision.position += BIG_BLOCK_COL_OFFSET
		add_child(collision)
		collision.add_to_group("block_collision")   # чтобы смена сборки могла её убрать
		instance.reparent($blocks, false)
		instance.scale = Vector3.ONE
		block_map_node.set_block(BuildingBlock["x"], BuildingBlock["y"], BuildingBlock["z"], instance.block, instance.rotation)
		block_map_node.node_map["%d,%d,%d" % [BuildingBlock["x"], BuildingBlock["y"], BuildingBlock["z"]]] = instance
		# Подписки на уничтожение — ОБЯЗАТЕЛЬНО обе, иначе поставленный игроком блок после
		# гибели оставляет после себя и занятую клетку карты (новый блок туда не встанет),
		# и висящую в воздухе коллизию. Блоки из стартовой сборки их получают в spawn_block,
		# а этот путь про них забывал.
		block_map_node.attach_block_signals(instance, int(BuildingBlock["x"]),
				int(BuildingBlock["y"]), int(BuildingBlock["z"]))
		connect_block_signals(instance)
		var placed_bt := int(instance.block)
		block_take = false
		build_basis = Basis()          # сброс ручного поворота под следующий блок
		_preview_res = null
		Q.report("block_placed", 1)             # прогресс заданий на сборку
		_rebuild_factory()                      # авто-коннект фабрики сразу после постановки
		if _hand_from_inventory:
			_refill_hand_from_inventory(placed_bt)
		_notify_build_changed()                 # вес/характеристики в гараже — сразу
	elif block_body != null and is_instance_valid(block_body):
		_pick_selected_block()

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
	_notify_build_changed()                 # сборка сменилась целиком — вес тоже

func _return_hand_to_inventory() -> void:
	var holder: Node = camera_controller.camera.get_child(0) \
			if (camera_controller != null and camera_controller.camera != null) else null
	if holder != null:
		for child in holder.get_children():
			if "block" in child:
				G.block_inventory.append(int(child.get("block")))
			holder.remove_child(child)
			child.queue_free()
		G.mark_progress_dirty()
	block_body = null
	block_take = false
	_preview_res = null
	if ghost_block:
		ghost_block.visible = false

func take_block_into_hand(block_type: int) -> bool:
	var scene: PackedScene = G.get_scene(block_type)
	if scene == null:
		return false
	_return_hand_to_inventory()
	var instance: VehicleBlock = scene.instantiate()
	var holder: Node = camera_controller.camera.get_child(0)   # takepos Marker3D
	holder.add_child(instance)
	if instance is Node3D:
		instance.position = Vector3.ZERO
		instance.scale = Vector3.ONE
		BlockFX.play(instance, false)      # глитч появления блока в руке (как при спавне)
	block_body = instance
	block_take = true
	Q.report("block_taken_world", 1)   # шаг обучения закрывается ЛЮБЫМ способом взять блок
	_hand_from_inventory = true     # взят из инвентаря → после постановки авто-доберём такой же
	build_basis = Basis()          # свежий блок — без ручного поворота
	_preview_res = null
	_cabin_ground = null
	_on_building_pressed()
	var hud: CanvasLayer = camera_controller.hud
	if hud and hud.has_method("_on_building_pressed"):
		hud._on_building_pressed()
	return true

# Убрать блок из руки — ДВА варианта (кнопки HUD): спрятать В ИНВЕНТАРЬ или бросить В МИР.
func stash_hand_to_inventory() -> void:
	if not block_take:
		return
	if block_body != null and is_instance_valid(block_body) and int(block_body.get("block")) == G.Block.CABIN:
		return                            # кабину (ядро новой машины) не прячем
	_return_hand_to_inventory()

func drop_hand_to_world() -> void:
	if not block_take:
		return
	var holder: Node = camera_controller.camera.get_child(0) \
			if (camera_controller != null and camera_controller.camera != null) else null
	if holder == null or holder.get_child_count() == 0:
		block_body = null
		block_take = false
		return
	var instance: Node3D = holder.get_child(0)
	if int(instance.get("block")) == G.Block.CABIN:
		return                            # кабину не бросаем в мир (это ядро новой машины)
	var objects := get_node_or_null("/root/Main/objects")
	if objects == null:
		return
	instance.top_level = false            # мог остаться top_level от превью
	instance.reparent(objects)            # VehicleBlock сам разморозится (parent == "objects")
	instance.scale = Vector3.ONE
	block_body = null
	block_take = false
	_preview_res = null
	if ghost_block:
		ghost_block.visible = false

# Q на ПК / действие «TakeOff» = быстро бросить блок в мир.
func _on_take_off_pressed() -> void:
	drop_hand_to_world()

var _atk_cache: Array = []
var _atk_n: int = -1

func _on_attack_timeout() -> void:
	var bl := block_map_node if block_map_node != null else get_node_or_null("blocks")
	if bl == null:
		return
	if bl.get_child_count() != _atk_n:
		_atk_n = bl.get_child_count()
		_atk_cache.clear()
		for i in bl.get_children():
			if i.has_method("attack"):
				_atk_cache.append(i)
	for i in _atk_cache:
		if not is_instance_valid(i):
			_atk_n = -1                 # блок уничтожили — пересоберём кеш на следующем вызове
			continue
		i.attack()
