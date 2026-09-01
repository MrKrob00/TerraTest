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

# ── Энергосистема ─────────────────────────────────────────────────────────────
# Сама система переехала в MachineBody: она нужна ОБЕИМ машинам (см. «главная ловушка» в
# CLAUDE.md). У врага без неё не работали ни щит, ни солнечная панель, ни реген — блоки
# висели бы на его базе мёртвым грузом. Здесь остаётся только то, что про ЯКОРЬ ИГРОКА.

## Солнечный буфер есть ТОЛЬКО под якорем: панель и производит, и даёт ёмкость, пока машина
## стоит. У врага-базы (она всегда стоит) базовый ответ «да», поэтому переопределяем здесь.
func power_anchored() -> bool:
	return anchored

## ЯКОРЬ ДЕРЖИТСЯ НА БЛОКЕ. Сбили опору — машина обязана свалиться с якоря: иначе сбитая
## насмерть база продолжала висеть замороженной в воздухе, и снять её было нечем (кнопка
## якоря проверяет ту же опору, которой уже нет). База (is_station) — исключение: у неё
## опора и есть весь смысл. Счёт опор ведёт тот же обход блоков, что считает ёмкость.
func _after_power_scan(anchors: int) -> void:
	if anchored and not is_station and anchors == 0:
		_release_anchor()


# ── Якорь (фиксация к миру, как в TerraTech) ──────────────────────────────────
var anchored: bool = false
var _anchor_column: MeshInstance3D = null
var _anchor_tween: Tween = null
# Стационарная структура (база): спавнится сразу на якоре, снять якорь/ехать нельзя.
# Ставится флаг при спавне через _place_ground_structure (ядро — стационарный блок).
var is_station: bool = false


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

	# Кнопка взаимодействия с ЭТОЙ машиной (круговое меню) живёт в HUD, а не здесь: значок в
	# мире закрывали собственные блоки, а ввод к нему не доходил — его перехватывал любой
	# коллайдер, оказавшийся ближе (зона регена, купол щита, магнит упаковщика). См. hud.gd,
	# «Кнопка машины: 2D, ПОВЕРХ ВСЕГО».

# Death = the cabin is gone. The watchdog, the subscription and the flags all live in
# MachineBody now: the enemy had none of it, so an enemy whose cabin was torn off never died.
# Only _die() itself stays here — handing the camera over is the player's business.

# Кабина уничтожена → машина разваливается (блоки падают в мир), камера уходит к другой
# машине (а если её нет — спавнит бесплатную стартовую), эта машина удаляется.
func _die() -> void:
	if _dying:
		return
	_dying = true
	scatter_blocks()          # общий разлёт из MachineBody: у врага он тот же
	if camera_controller and camera_controller.has_method("on_vehicle_died"):
		camera_controller.on_vehicle_died(self)
	queue_free()

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
		if global_position.distance_squared_to((v as Node3D).global_position) <= DEFENSE_RANGE * DEFENSE_RANGE:
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
	return is_station or has_support() or has_stationary()

## Есть ли на машине СТАЦИОНАРНЫЙ блок (продавец, авто-шахтёр). Он и есть повод для якоря:
## такая техника работает ТОЛЬКО под якорем, и машина, которая её везёт, обязана уметь
## вставать — даже если отдельной фикс-опоры на ней нет.
func has_stationary() -> bool:
	if block_map_node == null:
		return false
	for b in block_map_node.get_children():
		if ("block" in b) and G.is_stationary(int(b.get("block"))):
			return true
	return false

## ЯДРО БАЗЫ — ОДИН стационарный блок, а не каждый. Пока правило было «стационарный = ядро»,
## база с шахтёром и продавцом запирала оба: снять было нельзя ни один, хотя держится она на
## одном. Главным считаем ПЕРВЫЙ поставленный, а это блок в ЦЕНТРЕ сетки — туда его кладёт
## _place_ground_structure, и его же локальная позиция равна нулю. Центр пуст (ядро сбили,
## старый сейв) — берём первого стационарного из детей: порядок детей и есть порядок постановки.
##
## У МОБИЛЬНОЙ машины ядро — кабина, а стационарный блок она просто везёт; поэтому здесь
## null, и снимается такой блок как обычный.
func station_core() -> Node3D:
	if block_map_node == null or not is_station:
		return null
	var first: Node3D = null
	for b in block_map_node.get_children():
		if not (b is Node3D) or not ("block" in b) or not G.is_stationary(int(b.get("block"))):
			continue
		var n3 := b as Node3D
		if n3.position.is_zero_approx():
			return n3
		if first == null:
			first = n3
	return first

## Этот ли блок держит машину: кабина у машины, ядро у базы. Снимать его руками нельзя.
func is_core_block(b: Node) -> bool:
	if b == null or not is_instance_valid(b) or not ("block" in b):
		return false
	if int(b.get("block")) == G.Block.CABIN:
		return true
	return b == station_core()

func toggle_anchor() -> bool:
	if is_station:
		return true                        # стационарная база всегда на якоре — снять нельзя
	if anchored:
		_release_anchor()
		return false
	if not has_support():
		_anchor_refuse_hop()               # без фикс-опоры якорь не ставится (нужен блок SUPPORT)
		return false
	# МЕСТО БОЛЬШЕ НЕ ПРОВЕРЯЕТСЯ. Здесь стояла оценка площадки (уклон, бугор под днищем,
	# высота над землёй), и она отказывала там, где машина стоит совершенно нормально: игрок
	# жал кнопку, машину подкидывало, и почему — оставалось гадать. Единственное условие
	# якоря — наличие опоры на самой машине; всё остальное решает выравнивание, которое и так
	# ставит машину в 0° и поднимает на полметра.
	var terr: Node = _find_terrain()
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
	_build_anchor_column(maxf(target_y - ground_y, 0.4))
	# Контакт-сброс: следим за столкновениями, пока на якоре.
	contact_monitor = true
	max_contacts_reported = 4
	if not body_entered.is_connected(_on_anchor_contact):
		body_entered.connect(_on_anchor_contact)
	return true

## КОЛОННА СТАВИТСЯ ПОД ЯДРО, А НЕ ПОД НАЧАЛО КООРДИНАТ МАШИНЫ. У блока 2×2×2 (продавец,
## фабрикатор, процессор) якорная клетка — УГЛОВАЯ: футпринт растёт от неё в минус по X и Z
## (blocks._block_footprint), поэтому середина блока смещена на пол-клетки, а начало координат
## машины остаётся у угла. Столб рисовался в начале координат и торчал рядом с постройкой —
## ровно то, что видно на скриншоте: «магазин ушёл от якоря». Смещение берём у самого блока
## (VehicleBlock.cells_center — центр футпринта в его осях) и поворачиваем вместе с ним, чтобы
## оно осталось верным на повёрнутой базе.
func _core_center_offset() -> Vector3:
	var core: Node3D = station_core()
	if core == null:
		return Vector3.ZERO                # обычная машина: кабина и так в центре сетки
	var c = core.get("cells_center")
	var local: Vector3 = (c as Vector3) if c is Vector3 else Vector3.ZERO
	return core.position + core.basis * local

func _build_anchor_column(depth: float) -> void:
	var off: Vector3 = _core_center_offset()
	_anchor_column = MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.18
	cyl.bottom_radius = 0.28
	cyl.height = depth
	_anchor_column.mesh = cyl
	_anchor_column.position = Vector3(off.x, -depth * 0.5, off.z)
	add_child(_anchor_column)

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
		_build_anchor_column(maxf(global_position.y - ground_y, 0.4))
	_connect_station_core()

# 4A: гибель стационарного ЯДРА (SELLER) = структура разваливается (как кабина у машины).
# Спавн блоков асинхронный (spawn_block ждёт ready) — ретраим, пока ядро не появится.
# Подписываемся ИМЕННО НА ЯДРО (station_core), а не на первый попавшийся стационарный блок:
# на базе их бывает несколько, и подписка на шахтёра рядом с продавцом означала бы, что база
# рассыпается от гибели ГРУЗА, а не опоры.
func _connect_station_core(tries: int = 0) -> void:
	if block_map_node == null:
		return
	var core: Node3D = station_core()
	if core != null:
		if core.has_signal("destroyed") and not core.destroyed.is_connected(_on_cabin_destroyed):
			core.destroyed.connect(_on_cabin_destroyed)
		return
	if tries < 5:
		get_tree().create_timer(0.1).timeout.connect(_connect_station_core.bind(tries + 1))

## Гибель ЯДРА базы — ещё не гибель базы. Стационарных на ней бывает несколько (шахтёр рядом с
## продавцом), и пока стоит хоть один, база держится: ровно это и считает сторож
## (`MachineBody._has_core`). Два правила про одно и то же расходиться не должны, иначе база
## умирала бы от сбитого ядра, имея под собой вторую опору. Переподписку даём ЧЕРЕЗ ТАЙМЕР:
## сбитый блок в момент сигнала ещё в дереве, и выбирать нового главного по нему рано.
func _on_cabin_destroyed(b = null) -> void:
	if is_station and _other_stationary(b):
		get_tree().create_timer(0.2).timeout.connect(_connect_station_core.bind(0))
		return
	super._on_cabin_destroyed(b)

## Остался ли на базе стационарный блок, КРОМЕ этого.
func _other_stationary(exclude) -> bool:
	if block_map_node == null:
		return false
	for c in block_map_node.get_children():
		if c == exclude or not is_instance_valid(c) or not ("block" in c):
			continue
		if G.is_stationary(int(c.get("block"))):
			return true
	return false

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
	if joy.length_squared() < 0.0144:                   # 0.12², мёртвая зона стика
		return Vector3.ZERO
	var cam: Camera3D = camera_controller.camera if camera_controller != null else null
	if cam == null:
		return Vector3.ZERO
	var cf := -cam.global_transform.basis.z; cf.y = 0.0
	var cr := cam.global_transform.basis.x;  cr.y = 0.0
	# Проверка «вектор не вырожден» — сравнение, корень ей не нужен; normalized() ниже
	# возьмёт свой, и это уже по делу.
	if cf.length_squared() > 0.0001: cf = cf.normalized()
	if cr.length_squared() > 0.0001: cr = cr.normalized()
	var m := cr * joy.x + cf * (-joy.y)   # joy.y вверх = -1 → вперёд (от камеры)
	return m.normalized() if m.length_squared() > 1.0 else m   # 1² = 1

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
		# Ядро СТАНЦИИ (первый стационарный блок, напр. SELLER) — как кабина у машины: остаётся
		# на якоре и НЕ выпадает. Пропускаем ДО remove_block/коллизии/reparent, чтобы клетки
		# карты, коллизия и сам узел ядра сохранились и база продолжала стоять. SELLER 2×2×2 —
		# один якорный узел, так что пропуска узла хватает на все 8 клеток. Спрашиваем именно
		# ЯДРО, а не «любой стационарный»: на базе их бывает несколько (шахтёр рядом с
		# продавцом), и остальные — обычный груз, они обязаны выпасть; а мобильная машина
		# стационарный блок ВЕЗЁТ, и висеть в воздухе после разбора ему тем более незачем.
		if is_core_block(b):
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
	# ПОДПИСЫВАЕМСЯ ОДИН РАЗ. Узел блока переживает снятие с машины: подобрал в руку, поставил
	# обратно — и это ТОТ ЖЕ объект, которому _on_take_pressed снова раздаёт подписки. Вторая
	# connect роняет ошибку движка, а если бы прошла — коллизию снимали бы дважды, то есть
	# ровно та беда, от которой чуть ниже страхуется _on_block_destroyed.
	# То же правило и той же строкой стоит в blocks.attach_block_signals.
	if block.has_signal("destroyed") and not block.destroyed.is_connected(_on_block_destroyed):
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
	var _pf := Perf.now()          # метка для панели профиля (perf.gd): цена машин игрока
	_physics_body(delta)
	Perf.mark("machines", _pf)

func _physics_body(delta: float) -> void:
	# Энергия тикает ВСЕГДА (даже у неактивной машины): база на якоре копит от солнца.
	_energy_tick(delta)
	cabin_watch(delta)
	_rot_support_tick(delta)
	# Защита работает и у НЕактивной машины: стоит и отстреливается от врагов рядом.
	if defense_mode:
		_defense_tick(delta)
	if !is_active:
		return
	# ОГОНЬ РАЗБИРАЕМ ДО ВСЕХ РАННИХ ВЫХОДОВ. Он висел ниже, за проверкой якоря, и уходил
	# вместе с ней: игрок, вставший на якорь ради фабрики, оказывался безоружным ровно там и
	# ровно тогда, когда на него и нападают. Якорь запрещает ЕЗДУ, а не стрельбу.
	var typing := _typing_in_ui()
	if Input.is_action_pressed("Attack") and not typing:
		_on_attack_timeout()
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
## ЧТО именно в руке. Одним понятием, а не проверкой свойств в каждом месте: рука раньше
## означала строго «блок», и десяток мест читал у содержимого .block, приводил его к
## VehicleBlock и клал в инвентарь блоков. Ресурс (руда/слиток) ни одного из этих действий
## не переживает, поэтому развилка должна быть ровно одна и явная.
enum Hand { EMPTY, BLOCK, RESOURCE }
var hand_kind: int = Hand.EMPTY

## Ресурс отличается от блока наличием type/kind_key и ОТСУТСТВИЕМ block. Проверяем по
## наличию свойств, а не по классу: resource.gd не объявляет class_name.
static func _is_resource(n: Node) -> bool:
	return n != null and not ("block" in n) and ("type" in n) and n.has_method("kind_key")
var BuildingBlock: Dictionary = { "build": true, "x": 5, "y": 5, "z": 5, "block": 1 }  # дефолт = центр сетки 11³

# Ориентация блока в руке = авто по грани (наклон/поворот) ∘ ручная (кнопки UI поворота).
var build_basis: Basis = Basis()
var _rc_cache: Node3D = null       # кеш узла Camera3D/Raycast (find_child — рекурсивный поиск)
var _hover_ms: int = 0             # троттл наведения мышью (ховер шлёт до 1000 событий/с)
var _preview_res = null            # последний res для превью (чтобы переприменить при повороте)
var _cabin_ground = null           # Vector3|null: куда на ЗЕМЛЮ ставим кабину (новая машина)
var _ground_core := false          # в руке ядро, которое МОЖЕТ уйти на землю (кабина/стационар)
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
				and Time.get_ticks_msec() - _build_tap_ms >= LONG_PRESS_MS \
				and not _tap_over_ui(event.position):
			# ДОЛГОЕ УДЕРЖАНИЕ = настройки блока. Жест был свободен: короткий путь ниже требует
			# уложиться в 250 мс, и всё, что дольше, до этого просто терялось. Двойной тап
			# занять было нельзя — он означает «взять блок в руку».
			_try_open_factory_ui(event.position)
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
	# На ПК длинного удержания нет — там та же настройка вешается на правую кнопку.
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT and event.pressed \
			and not _tap_over_ui(event.position):
		_try_open_factory_ui(event.position)
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
		# По ВСЕМУ блоку (см. _ghost_fit): у 2×2×2 трансформ узла — это его угловая клетка,
		# и подсветка по нему садилась на четверть постройки.
		_ghost_fit(block_body)

func _on_movement_pressed() -> void:
	_return_hand_to_inventory()   # выход из стройки — блок из руки возвращаем в инвентарь
	if Building:
		Q.report("mode_movement", 1)          # шаг обучения «выйти из стройки»
	Building = false
	ghost_block.visible = false
	# ЯКОРЬ ПЕРЕЖИВАЕТ ВЫХОД ИЗ СТРОЙКИ. Условие было «не станция», и заякоренная обычная
	# машина размораживалась: она сползала с колонны-упора, физика возобновлялась, первый же
	# контакт уходил в _on_anchor_contact и снимал якорь. Со стороны это выглядело так, будто
	# якорь отцепляет ЗАКРЫТИЕ ГАРАЖА, — его закрытие и зовёт этот метод (hud._on_tech_ui_
	# visibility). Держит машину именно freeze, поэтому размораживать её, пока anchored,
	# нельзя ничем: снять якорь можно только кнопкой якоря.
	if not is_station and not anchored:
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
	# Подброс на 4 м — только для СВОБОДНОЙ машины. На якоре нельзя: там freeze = true, и
	# сдвиг координаты просто ТЕЛЕПОРТИРУЕТ машину вверх, где она и повисает — Movement высоту
	# не возвращает. Проверять хватало is_station (наземная база), но машина на ОПОРЕ станцией
	# не является: подобрал блок в руку → включилась стройка → база с фабрикой улетела вверх.
	if not is_station and not anchored:
		global_position.y += 4          # подброс для стройки в воздухе; выравнивание — плавно в _physics_process
	map = global_position.y

# Интерактивные узлы HUD, тап по которым НЕ должен наводить блок в мир.
#
# ЗОН ДЖОЙСТИКОВ ЗДЕСЬ НЕТ намеренно. Это не кнопки, а половина экрана: пока они считались
# «интерфейсом», подобрать блок или ресурс в этой половине было нельзя вовсе — тап молча
# проглатывался. Езде это не мешает: джойстик работает ПЕРЕТАСКИВАНИЕМ, а подбор — коротким
# двойным тапом, и одно от другого отличает _build_tap_moved.
const _UI_HIT_NODES := ["Take", "TakeOff", "Attack", "ModeToggle"]

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

# ══════════════════════════════════════════
# СТРОЙКА НА ДРУГОЙ СВОЕЙ МАШИНЕ — ЧЕРЕЗ НЕЁ САМУ
# ══════════════════════════════════════════
# Строить на соседней своей машине (достроить фабрику, не пересаживаясь) удобно, но делать
# это «отсюда» — плохая идея, и мы уже пробовали: цель протаскивалась через сетку, превью,
# кузов под коллизию, обе подписки и пересборку связей, то есть получалась ВТОРАЯ реализация
# постройки, которая вела себя иначе, чем первая.
#
# Здесь наоборот: своего кода для этого случая НЕТ ВООБЩЕ. Луч нашёл другую машину игрока —
# и мы просто просим ЕЁ обработать тот же тап. У неё тот же скрипт и те же методы, так что
# она строит у себя ровно так же, как строила бы, сидй игрок в ней: её сетка, её призрак, её
# коллизии, её подписки. Никакой разницы в ощущениях быть не может — код буквально один.
#
# Делегирует ТОЛЬКО активная машина (is_active). Это и защита от цепочки: цель, получив вызов,
# сама уже никуда его не передаст, даже если её собственный луч во что-то упрётся.
const BUILD_REACH := 30.0                # дальше этого чужая машина целью не становится

func _bt() -> Node3D:
	return self

func _btm() -> Node:
	return block_map_node

## Другая машина ИГРОКА под лучом тапа — или null. «Своя» определяется списком машин у камеры:
## faction тут мало (у баз он свой), а список камеры и есть ответ на вопрос, чем игрок владеет.
func _player_machine_under(screen_pos: Vector2) -> Node:
	if not is_active or camera_controller == null or camera_controller.camera == null:
		return null
	if not ("vehicles" in camera_controller):
		return null
	var cam: Camera3D = camera_controller.camera
	var from: Vector3 = cam.project_ray_origin(screen_pos)
	var q := PhysicsRayQueryParameters3D.create(from, from + cam.project_ray_normal(screen_pos) * 500.0)
	q.collision_mask = 2                          # слой блоков
	q.exclude = [get_rid()]                       # себя не ищем: по себе и так строим
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	if hit.is_empty():
		return null
	var root: Node = hit.get("collider")
	while root != null and not (root is MachineBody):
		root = root.get_parent()
	if root == null or root == self or not (root is Node3D):
		return null
	if not camera_controller.vehicles.has(root):
		return null                               # чужая машина — на ней не строим
	if global_position.distance_squared_to((root as Node3D).global_position) > BUILD_REACH * BUILD_REACH:
		return null
	return root

## Передать жест другой машине. РУКА ОБЩАЯ (держатель висит под камерой, один на всех), а вот
## ФЛАГИ руки — block_take, что именно в ней, ручной поворот, откуда она взялась — у каждой
## машины свои. Без переноса цель решила бы, что рука пуста, и вместо постановки блока сняла бы
## с себя тот, на который навели. Обратно забираем по той же причине: блок мог уйти из руки
## (поставили) или прийти в неё (сняли), и знать об этом должна та машина, которой рулят.
func _delegate_build(other: Node, screen_pos: Vector2, commit: bool) -> void:
	other.block_take = block_take
	other.hand_kind = hand_kind
	other.build_basis = build_basis
	other._hand_from_inventory = _hand_from_inventory
	if commit:
		other._commit_build_tap(screen_pos)
	else:
		other._handle_click(screen_pos)
	block_take = other.block_take
	hand_kind = other.hand_kind
	build_basis = other.build_basis
	_hand_from_inventory = other._hand_from_inventory
	# Своя подсветка гаснет: наводились не на нас, и оставленный на прошлой клетке призрак
	# читался бы как «сюда тоже можно».
	if ghost_block != null and is_instance_valid(ghost_block):
		ghost_block.visible = false
	block_body = null

func _handle_click(screen_pos: Vector2) -> void:
	# Тап пришёлся по другой своей машине — пусть наводится она сама (см. шапку раздела).
	var other: Node = _player_machine_under(screen_pos)
	if other != null:
		_delegate_build(other, screen_pos, false)
		return
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
			# Ресурс в руке в сетку не ставится — наводить нечего, выходим сразу. Ниже идёт
			# чтение .block, которого у ресурса нет.
			if hand_kind == Hand.RESOURCE:
				return
			var held_bt: int = holder.get_child(0).get("block")
			# КАБИНА — всегда новая машина на земле: на машину её не поставить.
			if held_bt == G.Block.CABIN:
				_preview_cabin_ground(world_origin, world_dir)
				return
			# СТАЦИОНАРНЫЙ блок (продавец, авто-шахтёр) ставится И НА МАШИНУ, и на землю.
			# Решает ПОПАДАНИЕ ЛУЧА, а не тип блока: целишься в машину — обычная сетка,
			# целишься мимо — новая база на земле. Раньше он уходил на землю ВСЕГДА, и
			# поставить продавца на свою машину было нельзя вовсе.
			_ground_core = G.is_stationary(held_bt) and not is_station
	var bm: Node = _btm()
	var space_node: Node3D = bm as Node3D if bm != null else _bt()
	var ray_origin: Vector3 = space_node.to_local(world_origin) + Vector3(5, 5, 5)
	var ray_dir: Vector3 = (space_node.global_transform.basis.inverse() * world_dir).normalized()
	var res: Dictionary = _find_nearest_block_on_ray(ray_origin, ray_dir)
	if not res["hit"]:
		res = _cell_from_physics(screen_pos)   # DDA промахнулся — спрашиваем физику (см. ниже)
	if block_take:
		# Ядро в руке и луч мимо машины — значит, ставим на землю (новая машина/база).
		if not res["hit"] and _ground_core:
			_preview_cabin_ground(world_origin, world_dir)
			return
		_cabin_ground = null     # целимся в машину: это обычная постановка в сетку, не база
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
		var bmn2: Node = _btm()
		block_body = bmn2.find_block(BuildingBlock["x"], BuildingBlock["y"], BuildingBlock["z"])
		_ghost_fit(block_body)                 # подсветка по ВСЕМУ блоку, а не по одной клетке
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
	var bmn: Node = _btm()
	if camera_controller == null or camera_controller.camera == null or bmn == null:
		return miss
	var cam: Camera3D = camera_controller.camera
	var from: Vector3 = cam.project_ray_origin(screen_pos)
	var q := PhysicsRayQueryParameters3D.create(from, from + cam.project_ray_normal(screen_pos) * 500.0)
	var hit: Dictionary = get_world_3d().direct_space_state.intersect_ray(q)
	# Попали в ту машину, НА КОТОРОЙ строим (обычно в себя, но может быть и соседняя своя).
	if hit.is_empty() or hit.get("collider") != _bt():
		return miss                        # попали не в неё (земля, чужой блок) — это не наводка
	var grid: Node3D = bmn as Node3D
	var basis_inv: Basis = grid.global_transform.basis.inverse()
	var n: Vector3 = (basis_inv * (hit["normal"] as Vector3)).normalized()
	var p: Vector3 = grid.to_local(hit["position"] as Vector3) - n * 0.5
	var cx := int(round(p.x)) + 5
	var cy := int(round(p.y)) + 5
	var cz := int(round(p.z)) + 5
	if not _in_bounds(cx, cy, cz):
		return miss
	var block: int = bmn.get_block(cx, cy, cz)
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
	var gm: Node = _btm()
	# Строим на ЧУЖОЙ (своей же, но другой) машине — подсветка обязана жить в мировых
	# координатах: как ребёнок этой машины она уехала бы вместе с ней, а клетка не здесь.
	if gm != null and gm != block_map_node:
		ghost_block.top_level = true
	# РАЗМЕР СБРАСЫВАЕМ В КЛЕТКУ. Подсветка растягивается под многоклеточный блок (_ghost_fit),
	# и без сброса она осталась бы растянутой, наведись игрок следом на пустую клетку или на
	# обычный блок — то есть показывала бы занятыми клетки, которые свободны.
	ghost_block.scale = Vector3.ONE
	_ghost_of = null
	if ghost_block.top_level and gm != null:
		# Мировой трансформ ячейки (позиция + поворот машины) — призрак не отстаёт при движении.
		# Берём сетку ЦЕЛИ: строить можно и на соседней своей машине, и подсветка обязана быть там же.
		ghost_block.global_transform = (gm as Node3D).global_transform * Transform3D(Basis(), local_pos)
	else:
		ghost_block.position = local_pos
	if BuildingBlock["build"]:
		BuildingBlock["x"] = gx; BuildingBlock["y"] = gy; BuildingBlock["z"] = gz
	else:
		BuildingBlock["x"] = res.x; BuildingBlock["y"] = res.y; BuildingBlock["z"] = res.z

## ПОДСВЕТКА НАКРЫВАЕТ ВЕСЬ БЛОК, А НЕ ОДНУ КЛЕТКУ.
##
## Куб подсветки размером в клетку садился в ту клетку, куда попал луч, — и у блока крупнее
## одной клетки это выглядело как ошибка: у продавца 2×2×2 якорь стоит в УГЛОВОЙ клетке
## (футпринт растёт от него в минус по X и Z, в плюс по Y), поэтому подсветка оказывалась на
## задней правой нижней четверти постройки, а не на ней самой. Игрок читает это буквально:
## «блок не там, где показывают».
##
## Размер и центр берём у САМОГО блока — по клеткам его футпринта (blocks.footprint_offsets),
## а не по мешу: меш у моделей бывает и крупнее, и мельче своих клеток, а подсветка обязана
## говорить про КЛЕТКИ — именно их занимает блок и именно их освободит снятие.
## Форму КЕШИРУЕМ на узел: подсветка следует за наведённым блоком каждый кадр, а
## footprint_offsets перебирает карту машины и режет строку ключа. Клетки блока при этом не
## меняются, пока он стоит, — значит и считать их каждый кадр незачем.
var _ghost_of: Node = null
var _ghost_size: Vector3 = Vector3.ONE
var _ghost_mid: Vector3 = Vector3.ZERO

func _ghost_fit(b: Node) -> void:
	if ghost_block == null or not is_instance_valid(ghost_block):
		return
	var grid: Node = _btm()
	if b == null or not is_instance_valid(b) or not (b is Node3D) or grid == null:
		return
	if not grid.has_method("footprint_offsets"):
		return
	if b != _ghost_of:
		_ghost_of = b
		var mn := Vector3.ZERO
		var mx := Vector3.ZERO
		for o in grid.footprint_offsets(b):
			var v := Vector3(o)
			mn = mn.min(v)
			mx = mx.max(v)
		_ghost_size = mx - mn + Vector3.ONE
		_ghost_mid = (mn + mx) * 0.5                # центр футпринта в клетках от якоря
	var size: Vector3 = _ghost_size
	var mid: Vector3 = _ghost_mid
	var gnode: Node3D = grid as Node3D
	var b3: Node3D = b as Node3D
	if ghost_block.top_level:
		ghost_block.global_transform = Transform3D(
				gnode.global_transform.basis.scaled(size), gnode.to_global(b3.position + mid))
	else:
		ghost_block.transform = Transform3D(Basis().scaled(size), b3.position + mid)

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
# Грани блок объявляет сам — экспортом connect_faces (правится кубиком в инспекторе его сцены,
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
	var bmn: Node = _btm()            # строим на СЕБЕ или на соседней своей машине — решил луч
	if bmn == null:
		return
	var ad :Vector3 = bmn.attach_delta(int(instance.block), String(res.face))
	var gx: float = float(res.x) + ad.x
	var gy: float = float(res.y) + ad.y
	var gz: float = float(res.z) + ad.z
	BuildingBlock["x"] = gx; BuildingBlock["y"] = gy; BuildingBlock["z"] = gz
	var placeable: bool = bmn.can_attach(int(res.x), int(res.y), int(res.z),
			instance, res.face) and bmn.can_place(instance.block, gx, gy, gz)
	if not placeable:
		instance.top_level = false
		instance.position = Vector3.ZERO       # обратно в руку
		instance.rotation = Vector3.ZERO
		if ghost_block:
			ghost_block.visible = false
		return
	var orient := _face_orient(res.face, instance, build_basis) * build_basis
	var local_pos := Vector3(gx - 5, gy - 5, gz - 5)
	var grid: Node3D = bmn as Node3D
	var world_basis: Basis = (grid.global_transform.basis * orient).orthonormalized()
	# top_level → превью держится в мировой ячейке и НЕ крутится с камерой (блок висит под
	# камерой; без этого при повороте камеры он «смотрел» на неё).
	instance.top_level = true
	instance.global_transform = Transform3D(world_basis, grid.to_global(local_pos))
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
	q.exclude = [get_rid()]        # exclude — это RID'ы, не узлы
	var hit := space.intersect_ray(q)
	if hit.is_empty():
		return
	_cabin_ground = hit.position
	_preview_res = null
	var inst: Node3D = holder.get_child(0)
	inst.top_level = true
	# Превью показывает блок ТАМ ЖЕ, где он окажется после постановки (_place_ground_structure
	# вычитает тот же сдвиг): у 2×2×2 начало координат в углу, и без поправки превью стояло на
	# пол-клетки в стороне от того места, куда блок в итоге вставал.
	var pyaw: float = build_basis.get_euler().y
	var poff: Vector3 = Basis(Vector3.UP, pyaw) * _cells_center_of(inst)
	inst.global_transform = Transform3D(Basis(Vector3.UP, pyaw),
			_cabin_ground + Vector3.UP * 1.2 - Vector3(poff.x, 0.0, poff.z))
	if ghost_block:
		ghost_block.visible = false

## Центр футпринта блока в его собственных осях: у одноклеточного ноль, у 2×2×2 — пол-клетки
## по X и Z в минус (см. VehicleBlock.cells_center, blocks._block_footprint).
func _cells_center_of(inst: Node) -> Vector3:
	var c = inst.get("cells_center") if inst != null else null
	return (c as Vector3) if c is Vector3 else Vector3.ZERO

func _place_ground_structure(instance: Node3D) -> void:
	var core: int = int(instance.get("block"))
	var scene: PackedScene = load("res://player_vehicle.tscn")
	if scene == null:
		push_error("vehicle: нет player_vehicle.tscn для новой структуры")
		return
	# АВТО-ШАХТЁР СТАВИТСЯ ТОЛЬКО К ВЫРАБОТАННОЙ ЖИЛЕ. Он умеет ровно одно — выскребать пустую
	# жилу рядом с собой, и посреди поля это дорогой памятник: стоит, ест энергию, не добывает
	# ничего. Поэтому не «можно и так», а нельзя: не нашли подходящую жилу — блок ОСТАЁТСЯ В
	# РУКЕ, игрок доносит его до залежи.
	#
	# ПУСТАЯ, А НЕ ЛЮБАЯ: пока в жиле есть руда, она принадлежит буру. Шахтёр забирает её себе
	# навсегда (жила под ним больше не восстанавливается), и отдавать ему полную значило бы
	# отменить выбор — поставил и забыл, копать руками больше незачем.
	if core == G.Block.AUTO_MINER:
		# Радиус спрашиваем у САМОГО блока: правило «дотягивается до жилы» должно быть одно
		# и то же и при постановке, и при добыче (auto_miner.vein_reach).
		var reach: float = float(instance.get("vein_reach")) if ("vein_reach" in instance) \
				else VEIN_SNAP_FALLBACK
		var vein: Node3D = _vein_near(_cabin_ground, reach)
		if vein == null:
			Dialogue.say("System", "The Auto Miner works an ore vein. Place it next to one.")
			return
		if vein.has_method("is_depleted") and not vein.is_depleted():
			Dialogue.say("System", "Mine this vein out first — the Auto Miner only works a spent one.")
			return
		if vein.get("claimed_by") != null:
			Dialogue.say("System", "Another Auto Miner already works this vein.")
			return
		# СТАВИМ РЯДОМ, БУРОМ К ЖИЛЕ, а не поверх неё. Рабочая сторона у модели одна — передняя
		# (−Z, как у ручного бура), и блок, накрывший жилу собой, выглядит как коробка на руде.
		# Сторону выбирает САМ ИГРОК: берём направление от жилы к точке, куда он ткнул. Тапнул
		# ровно в жилу (направление нулевое) — становимся со стороны машины, лишь бы не наугад.
		var side: Vector3 = _cabin_ground - vein.global_position
		side.y = 0.0
		if side.length_squared() < 0.01:
			side = global_position - vein.global_position
			side.y = 0.0
		if side.length_squared() < 0.01:
			side = Vector3.BACK
		side = side.normalized()
		_cabin_ground = vein.global_position + side * MINER_MOUNT_DIST
		# Высоту берём В ТОЧКЕ, КУДА ВСТАЁМ (общее правило проекта, G.ground_y): жила и место
		# рядом с ней на склоне отличаются на метры — база уезжала под рельеф или зависала.
		_cabin_ground.y = G.ground_y(_cabin_ground, _cabin_ground.y)
		# Разворачиваем −Z на жилу и ПЕРЕБИВАЕМ ручной поворот игрока: ставить шахтёр буром в
		# другую сторону нельзя, а объяснять это некому. Модель смотрит −Z, поэтому нужный курс
		# даёт направление ОТ блока К жиле.
		build_basis = Basis(Vector3.UP, atan2(side.x, side.z))
	# ЯДРО ИЗ РУКИ УБИРАЕМ ДО СОЗДАНИЯ МАШИНЫ, а не одним queue_free в конце. Держатель руки
	# ОБЩИЙ (он висит под камерой), а _ready новой машины первым делом зовёт
	# _on_movement_pressed → _return_hand_to_inventory: тот проходит по детям держателя и
	# кладёт в инвентарь всё, что там висит. Ядро, ещё не убранное из руки, уезжало в
	# инвентарь — блок ставился на землю И дублировался. queue_free от этого не спасает: узел
	# живёт до конца кадра.
	var hand_holder: Node = instance.get_parent()
	if hand_holder != null:
		hand_holder.remove_child(instance)
	block_take = false
	hand_kind = Hand.EMPTY
	block_body = null
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
	# СТАВИМ ТУДА ЯДРО, А НЕ НАЧАЛО КООРДИНАТ МАШИНЫ. У блока 2×2×2 якорная клетка угловая
	# (футпринт растёт от неё в минус по X и Z), значит середина ядра смещена от начала
	# координат на пол-клетки. Машина вставала в точку тапа началом координат — и продавец
	# оказывался в стороне от места, куда его ставили, и от собственного столба якоря. Ровно
	# этот сдвиг и виден на скриншоте.
	var yaw: float = build_basis.get_euler().y
	var core_off: Vector3 = Basis(Vector3.UP, yaw) * _cells_center_of(instance)
	v.global_position = _cabin_ground + Vector3.UP * 1.2 - Vector3(core_off.x, 0.0, core_off.z)
	if v is Node3D:
		v.global_rotation.y = yaw                         # уважаем ручной поворот игрока (как в превью)
	if v.has_method("apply_build"):
		v.apply_build([{"x": 5, "y": 5, "z": 5, "block": core, "rot": [0.0, 0.0, 0.0]}])  # ядро в ЦЕНТРЕ сетки 11³
	# Ядро базы → машина на якоре (нельзя ехать/снять якорь). Опора здесь равноправна с
	# продавцом: база отличается от машины не набором блоков, а тем, что у неё нет кабины и
	# она стоит.
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
	instance.queue_free()                           # ядро из руки потрачено (из руки уже снято выше)
	_cabin_ground = null
	_preview_res = null
	build_basis = Basis()
	if ghost_block:
		ghost_block.visible = false

## Жила рядом с точкой (по XZ). Ищем перебором стримнутых залежей, а не лучом: луч превью
## бьёт по маске 1 (рельеф), а жила стоит НА рельефе — палец почти всегда попадает в землю
## рядом с ней, а не в неё саму. Радиус берём у самого шахтёра (vein_reach), чтобы правило
## «дотягивается» было ОДНО: поставили — значит и добывать сможет.
const VEIN_SNAP_FALLBACK := 3.0
## На сколько метров шахтёр отходит от жилы. Меньше vein_reach у самого блока — иначе он
## встанет так, что своей же жилы не увидит.
const MINER_MOUNT_DIST := 1.4

func _vein_near(at, reach: float = VEIN_SNAP_FALLBACK) -> Node3D:
	if not (at is Vector3):
		return null
	var rn: Node = get_node_or_null("/root/Main/map/Resource_Nodes")
	if rn == null:
		return null
	var best: Node3D = null
	var best_d: float = reach * reach
	for c in rn.get_children():
		if not (c is Node3D) or not ("instance_id" in c) or not c.has_method("hurt"):
			continue                    # жила — единственное, у чего есть и то, и другое
		var d: Vector3 = (c as Node3D).global_position - (at as Vector3)
		var d2: float = d.x * d.x + d.z * d.z      # по XZ: жила «под ногами», высота не важна
		if d2 <= best_d:
			best_d = d2
			best = c as Node3D
	return best

## Первая CollisionShape3D среди детей блока. Именно она дублируется на корпус машины при
## постановке — блок на машине заморожен, а форму за него держит кузов.
func _first_collision(node: Node) -> CollisionShape3D:
	for c in node.get_children():
		var cs := c as CollisionShape3D
		if cs != null and cs.shape != null:
			return cs
	return null

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
	# Клетки читаем у ЦЕЛИ ПОСТРОЙКИ, а не у себя: луч выше уже переведён в её пространство
	# (_handle_click), и спрашивать при этом СВОЮ карту значило бы наводиться по чужой сетке —
	# на соседней машине подсветка садилась бы в клетку, вычисленную по нашей сборке.
	var bmn: Node = _btm()
	if bmn == null:
		return result
	for _i in range(128):
		# Проверяем ТЕКУЩУЮ ячейку (включая стартовую) ещё до шага.
		if _in_bounds(cx, cy, cz):
			var block: int = bmn.get_block(cx, cy, cz)
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
	if not ("block" in block_body):
		return false                              # наведён РЕСУРС: у него нет .block, int(null) роняет вызов
	# ЯДРО СПРАШИВАЕМ У ТОЙ МАШИНЫ, С КОТОРОЙ СНИМАЕМ. is_core_block — метод машины, а снимать
	# мы можем и с соседней своей: спросив себя, мы защитили бы своё ядро, а не её.
	var owner_v: Node = _bt()
	if owner_v.has_method("is_core_block") and owner_v.is_core_block(block_body):
		return false                              # ядро сборки не снимаем (кабина / ядро базы)
	var bmn: Node = _btm()
	if bmn != null and block_body.get_parent() != null and block_body.get_parent().name == "blocks":
		bmn.remove_block(BuildingBlock["x"], BuildingBlock["y"], BuildingBlock["z"])
		# Структурная целостность и В СТРОЙКЕ: сняли блок → сосед, потерявший ВСЕ связи с
		# кабиной/базой, отрывается и падает в мир (тот же BFS, что при боевом разрушении).
		if bmn.has_method("_detach_orphans"):
			bmn.call_deferred("_detach_orphans")
	# 2×2-блоки кладут коллизию со сдвигом (-0.5,0.5,-0.5), поэтому ищем по обоим
	# вариантам позиции, иначе коллизия 2×2 оставалась бы висеть после снятия блока.
	# Коллизии блоков живут на КУЗОВЕ машины-владельца — у неё их и ищем.
	for i in owner_v.get_children():
		if i is CollisionShape3D and (i.position == block_body.position \
				or i.position == block_body.position + Vector3(-0.5, 0.5, -0.5)):
			i.queue_free()
	block_body.reparent(camera_controller.camera.get_child(0), false)
	block_body.position = Vector3.ZERO
	block_take = true
	hand_kind = Hand.BLOCK
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
func _refill_hand_from_inventory(bt: int, keep_basis: bool = false) -> void:
	if not G.block_inventory.has(bt):
		return
	# Тот же угол, что у предыдущего: take_block_into_hand сбрасывает build_basis (свежий блок
	# из инвентаря обычно берут «как есть»), поэтому для авто-добора возвращаем его обратно.
	var saved: Basis = build_basis
	if take_block_into_hand(bt):
		if keep_basis:
			build_basis = saved
			var held: Node3D = _hand_instance()
			if held != null:
				held.basis = build_basis     # в руке блок сразу висит под тем же углом
		G.block_inventory.erase(bt)                # списываем экземпляр (как tech_ui._take_into_hand)
		G.mark_progress_dirty()

# Подтверждение стройки по ДВОЙНОМУ тапу/клику (кнопка Take не нужна): держим блок в руке → СТАВИМ
# его; рука пуста → БЕРЁМ наведённый блок. Одиночный тап только наводит/подсвечивает (_handle_click).
var _last_commit_ms: int = 0
func _commit_build_tap(screen_pos: Vector2) -> void:
	# Подтверждение уходит туда же, куда ушло наведение: ставит и снимает блок ТА машина, по
	# которой попал луч. Иначе наведение было бы у неё, а постановка у нас.
	var other: Node = _player_machine_under(screen_pos)
	if other != null:
		_delegate_build(other, screen_pos, true)
		return
	var now := Time.get_ticks_msec()
	if now - _last_commit_ms < 250:
		return                           # антидубль: на мобилке тач И эмулированная мышь дают двойной
	_last_commit_ms = now
	var used: bool = false
	if block_take:
		_on_take_pressed()               # поставить блок из руки (или наземное ядро — кабина/база)
		used = true                      # блок в руке — жест наш в любом случае
	else:
		used = _maybe_grab_on_tap(screen_pos)   # взять блок машины / свободный блок или ресурс
	# СЪЕДАЕМ событие, если жест сработал. Иначе тот же двойной тап доходит до камеры
	# (camera_controller._unhandled_input) и та СБРАСЫВАЕТ ВЗГЛЯД: игрок тапает по ресурсу,
	# ресурс уходит в руку, а камера в тот же миг разворачивается — и выглядит это как
	# «подобрать не вышло, зато камера дёрнулась». Гейт `not _in_build()` у камеры этой
	# задачи не решал: подбор давно работает В ЛЮБОМ режиме, а не только в стройке.
	if used:
		get_viewport().set_input_as_handled()

# Взять В РУКУ наведённый блок машины (block_body из _handle_click) ИЛИ свободный блок из мира
# (физ-луч из точки тапа). Зовётся из _commit_build_tap по двойному тапу, когда рука пуста.
## true — жест ИЗРАСХОДОВАН (что-то взяли, назначили цель, скормили). Ответ нужен вызывающему:
## по нему он гасит событие, чтобы тот же двойной тап не отработал ещё и камерой.
func _maybe_grab_on_tap(screen_pos: Vector2) -> bool:
	if block_take:
		return false
	# 0) Блок в руке + тап по SCRAPPER'у на ЧУЖОЙ машине = скормить. На СВОЕЙ машине тот же
	# жест означает «поставить блок» (в том числе рядом со Scrapper'ом), а на чужую машину
	# блок и так не поставить — там жест свободен, его и занимаем. Поэтому разбирать, куда
	# именно попал луч относительно граней, не нужно вовсе.
	if block_take and hand_kind == Hand.BLOCK and _feed_foreign_scrapper(screen_pos):
		return true
	# 0) ЧУЖОЙ блок — не подбираем, а НАЗНАЧАЕМ ЦЕЛЬЮ. Порядок именно такой: тап по врагу
	# однозначно означает «бей вот это», подобрать блок с живой вражеской машины всё равно
	# нельзя, и разбирать её на ходу руками мы не даём.
	if _mark_enemy_target(screen_pos):
		return true
	# 1) Блок на МАШИНЕ (block_body уже наведён grid-лучом) — снять в руку.
	if block_body != null and is_instance_valid(block_body) \
			and block_body.get_parent() != null and block_body.get_parent().name == "blocks":
		_pick_selected_block()
		return true
	return _grab_world_block(screen_pos)

# Взять РЕСУРС в руку. Отдельно от блочного пути намеренно: общего у них только «повесить
# под камеру», а всё остальное (тип, инвентарь, сетка, стройка, шаг обучения) — блочное и
# ресурсу не подходит.
func _grab_resource(body: Node3D) -> bool:
	_return_hand_to_inventory()                    # рука должна быть пустой
	body.reparent(camera_controller.camera.get_child(0), false)
	body.top_level = false
	body.position = Vector3.ZERO
	body.rotation = Vector3.ZERO
	if body is RigidBody3D:
		var rb := body as RigidBody3D
		# Заморозка обязательна: незамороженный ресурс продолжал бы падать по своей физике
		# и вдобавок его подобрал бы собственный коллектор машины (collector.gd пропускает
		# только freeze-тела).
		rb.freeze = true
		rb.linear_velocity = Vector3.ZERO
		rb.angular_velocity = Vector3.ZERO
	block_body = body
	block_take = true
	hand_kind = Hand.RESOURCE
	_hand_from_inventory = false
	build_basis = Basis()
	_preview_res = null
	_cabin_ground = null
	if ghost_block:
		ghost_block.visible = false
	# Q.report и режим стройки НЕ трогаем: шаг обучения «возьми блок» ресурсом не
	# закрывается, и лезть в стройку ради руды незачем.
	return true

# Скормить блок из руки Scrapper'у на ЧУЖОЙ машине. true — блок съеден (или отвергнут за
# отсутствием рецепта, но жест всё равно израсходован: игрок целился именно в Scrapper).
func _feed_foreign_scrapper(screen_pos: Vector2) -> bool:
	if camera_controller == null or camera_controller.camera == null:
		return false
	var cam: Camera3D = camera_controller.camera
	var from: Vector3 = cam.project_ray_origin(screen_pos)
	var q := PhysicsRayQueryParameters3D.create(from, from + cam.project_ray_normal(screen_pos) * 500.0)
	q.collision_mask = 2                            # слой блоков
	q.exclude = [get_rid()]
	var hit: Dictionary = get_world_3d().direct_space_state.intersect_ray(q)
	if hit.is_empty():
		return false
	var target = hit.get("collider")
	if not (target is Node) or not target.has_method("scrap_block"):
		return false
	# Только ЧУЖАЯ машина: на своей этот жест принадлежит постройке.
	var root: Node = target
	while root != null and not (root is MachineBody):
		root = root.get_parent()
	if root == self:
		return false
	var held: Node3D = _hand_instance()
	if held == null:
		return false
	var bt: int = int(held.get("block")) if ("block" in held) else -1
	if not target.can_scrap(bt):
		Dialogue.say("System", "No schematic for this part. It cannot be broken down.")
		return true                                 # жест израсходован, блок ЦЕЛ и в руке
	if target.scrap_block(held):
		block_body = null
		block_take = false
		hand_kind = Hand.EMPTY
		_preview_res = null
		if ghost_block:
			ghost_block.visible = false
	return true

## Сколько держать, чтобы это считалось длинным нажатием.
const LONG_PRESS_MS: int = 500

# Длинное нажатие по СВОЕМУ фабричному блоку = окно «что производить». Только по своему:
# на чужой машине настройки нам не принадлежат, а лезть в них через полкарты — не механика.
# Возвращает true, если окно открылось.
func _try_open_factory_ui(screen_pos: Vector2) -> bool:
	if camera_controller == null or camera_controller.camera == null:
		return false
	var cam: Camera3D = camera_controller.camera
	var from: Vector3 = cam.project_ray_origin(screen_pos)
	var q := PhysicsRayQueryParameters3D.create(from, from + cam.project_ray_normal(screen_pos) * 500.0)
	q.collision_mask = 2                            # слой блоков
	q.exclude = [get_rid()]
	var hit: Dictionary = get_world_3d().direct_space_state.intersect_ray(q)
	if hit.is_empty():
		return false
	var target = hit.get("collider")
	if not (target is Node):
		return false
	var root: Node = target
	while root != null and not (root is MachineBody):
		root = root.get_parent()
	var hud: CanvasLayer = camera_controller.hud if ("hud" in camera_controller) else null
	if hud == null:
		return false
	# ДРУГАЯ СВОЯ машина (или база) — открываем её круговое меню: в инвентарь / разобрать /
	# защита / взять под управление.
	#
	# Тем же меню заведует значок ⚙ над машиной, но он висит на физическом пикинге вьюпорта
	# (Area3D._input_event): туда событие доходит, только если ДО этого его никто не пометил
	# обработанным — а поверх мира лежит HUD, гараж и наш собственный разбор тапа. Меню в
	# итоге не открывалось. Длинное нажатие идёт тем же путём, что и настройка фабрики, то
	# есть работает всегда; значок остаётся подсказкой, что с машиной можно что-то сделать.
	if root != null and root != self and root.get("faction") != null and int(root.get("faction")) == faction:
		if hud.has_method("open_vehicle_menu"):
			hud.open_vehicle_menu(root, screen_pos)
			return true
		return false
	if root != self:
		return false                                # враг или свободный блок в мире
	if not hud.has_method("open_factory_picker"):
		return false
	return hud.open_factory_picker(target)

# Двойной тап по блоку ЧУЖОЙ машины = приказ орудиям бить именно его (см.
# WeaponBlock._update_current_target). Возвращает true, если цель назначена — тогда тап
# израсходован и подбор блока не запускается.
func _mark_enemy_target(screen_pos: Vector2) -> bool:
	if camera_controller == null or camera_controller.camera == null:
		return false
	var cam: Camera3D = camera_controller.camera
	var from: Vector3 = cam.project_ray_origin(screen_pos)
	var q := PhysicsRayQueryParameters3D.create(from, from + cam.project_ray_normal(screen_pos) * 500.0)
	q.collision_mask = 2                            # слой блоков
	q.exclude = [get_rid()]
	var hit: Dictionary = get_world_3d().direct_space_state.intersect_ray(q)
	if hit.is_empty():
		return false
	var body = hit.get("collider")
	if not (body is Node3D) or not ("block" in body):
		return false
	# Блок ЧУЖОЙ машины: он лежит под её узлом blocks, а машина — с другой фракцией.
	var root: Node = body
	while root != null and not (root is MachineBody):
		root = root.get_parent()
	if root == null or root == self:
		return false
	var f = root.get("faction")
	if f == null or int(f) == faction:
		return false                                # своя машина — цель назначать не по чему
	set_priority_target(body as Node3D)
	BlockFX.hit(body as Node3D, 1)                  # мигнули по блоку: приказ принят
	return true

# Взять СВОБОДНЫЙ блок из мира (RigidBody-VehicleBlock под /root/Main/objects) в руку по клику.
func _grab_world_block(screen_pos: Vector2) -> bool:
	if camera_controller == null or camera_controller.camera == null:
		return false
	var cam: Camera3D = camera_controller.camera
	var from: Vector3 = cam.project_ray_origin(screen_pos)
	var to: Vector3 = from + cam.project_ray_normal(screen_pos) * 500.0
	var q := PhysicsRayQueryParameters3D.create(from, to)
	# Слой 2 — свободные блоки, слой 8 — ресурсы (руда/слитки). Раньше маска была только 2,
	# и ресурс лучом подбора не находился вовсе, сколько по нему ни тапай.
	q.collision_mask = 2 | 8
	q.exclude = [get_rid()]                         # не цепляем саму машину
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	if hit.is_empty():
		return false
	var body: Node3D = hit.get("collider")
	# Только то, что реально ЛЕЖИТ В МИРЕ (см. G.is_loose_item). Проверка по родителю-objects
	# здесь мимо: руда из жилы падает в узел стриминга залежей, и по ней тап в руду не делал
	# ничего вообще.
	if not (body is Node3D) or not G.is_loose_item(body):
		return false
	# РЕСУРС берётся в руку так же, как блок, но без всего блочного: ни сетки, ни инвентаря,
	# ни режима стройки — его можно только положить обратно.
	if _is_resource(body):
		return _grab_resource(body)
	if not ("block" in body):
		return false
	# СТАЦИОНАРНЫЙ блок из мира БЕРЁТСЯ В РУКУ. Раньше он был в одном запрете с кабиной, и это
	# ломало ровно то, ради чего его в мир и кладут: сюжет выдаёт опору («найдите её»), сбитая
	# база рассыпается опорами и продавцами — а поднять их было нечем, тап по ним не делал
	# ничего. Кабина остаётся исключением: это ядро ЧУЖОЙ машины, поднимать её незачем.
	if int(body.get("block")) == G.Block.CABIN:
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
	hand_kind = Hand.BLOCK
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
		# Кнопка Take с ресурсом в руке = положить его обратно на землю. Строкой ниже
		# содержимое руки приводится к VehicleBlock — на ресурсе это ошибка выполнения.
		if hand_kind == Hand.RESOURCE:
			drop_hand_to_world()
			return
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
		# Машина, её сетка и её узел blocks — всё через одну точку (_bt/_btm), чтобы «на чём
		# строим» спрашивалось в одном месте, а не выводилось заново в каждой ветке.
		var tgt: Node3D = _bt()
		var bmn: Node = _btm()
		var tgt_blocks: Node = tgt.get_node_or_null("blocks")
		if bmn == null or tgt_blocks == null:
			return
		if not bmn.can_place(instance.block, BuildingBlock["x"], BuildingBlock["y"], BuildingBlock["z"]):
			return
		# Точки стыковки: пускает ли сосед к своей грани (см. connect_faces в инспекторе блока).
		if not bmn.can_attach(int(pres.x), int(pres.y), int(pres.z), instance, pres.face):
			return
		# Превью держало блок top_level (мировой трансформ). Перед постановкой возвращаем
		# наследование, иначе local basis/position ниже применятся как мировые.
		instance.top_level = false
		# Полная ориентация: авто по грани (наклон/разворот колеса) ∘ ручной поворот из UI.
		var orient := _face_orient(pres.face, instance, build_basis) * build_basis
		instance.basis = orient
		instance.position = Vector3(BuildingBlock["x"]-5, BuildingBlock["y"]-5, BuildingBlock["z"]-5)
		# ИЩЕМ КОЛЛИЗИЮ ПЕРЕБОРОМ, а не get_child(0). Порядок детей в сцене блока — вещь,
		# которую художник меняет не задумываясь, а типизированное присваивание чужого узла в
		# CollisionShape3D падает прямо здесь, посреди постановки: блок остаётся в руке, в
		# консоли ошибка, и выглядит это как «этот блок почему-то не ставится».
		var src_col: CollisionShape3D = _first_collision(instance)
		if src_col == null:
			push_error("vehicle: у блока %s нет CollisionShape3D — ставить нечего" % G.block_name(int(instance.block)))
			return
		var collision: CollisionShape3D = src_col.duplicate()
		collision.transform = Transform3D(orient, instance.position)   # коллизия наклоняется вместе
		# .size есть только у коробки. У любой другой формы обращение к нему роняло бы
		# постановку ровно так же — молча и на полпути.
		var box: BoxShape3D = collision.shape as BoxShape3D
		if box != null and box.size == Vector3(2, 2, 2):
			collision.position += BIG_BLOCK_COL_OFFSET
		tgt.add_child(collision)
		collision.add_to_group("block_collision")   # чтобы смена сборки могла её убрать
		instance.reparent(tgt_blocks, false)
		instance.scale = Vector3.ONE
		bmn.set_block(BuildingBlock["x"], BuildingBlock["y"], BuildingBlock["z"], instance.block, instance.rotation)
		bmn.node_map["%d,%d,%d" % [BuildingBlock["x"], BuildingBlock["y"], BuildingBlock["z"]]] = instance
		# Подписки на уничтожение — ОБЯЗАТЕЛЬНО обе, иначе поставленный игроком блок после
		# гибели оставляет после себя и занятую клетку карты (новый блок туда не встанет),
		# и висящую в воздухе коллизию. Блоки из стартовой сборки их получают в spawn_block,
		# а этот путь про них забывал.
		bmn.attach_block_signals(instance, int(BuildingBlock["x"]),
				int(BuildingBlock["y"]), int(BuildingBlock["z"]))
		# Подписку на гибель ставит ТА машина, на которой блок теперь стоит: обе подписки
		# обязаны быть у одного хозяина, иначе сбитый блок чистит клетку у одной машины, а
		# коллизию оставляет висеть на другой.
		if tgt.has_method("connect_block_signals"):
			tgt.connect_block_signals(instance)
		hand_kind = Hand.EMPTY
		var placed_bt := int(instance.block)
		block_take = false
		# Ручной поворот СОХРАНЯЕМ, если рука сейчас же доберётся таким же блоком из инвентаря.
		# Игрок, выкрутивший блок под нужным углом, ставит подряд целый ряд одинаковых — и
		# сбрасывать угол после каждого значило заставлять его крутить заново по разу на блок.
		# Когда авто-добора нет (рука опустела), сбрасываем как раньше: следующий блок игрок
		# возьмёт сам и, скорее всего, другой.
		var keep_basis: bool = _hand_from_inventory and G.block_inventory.has(placed_bt)
		if not keep_basis:
			build_basis = Basis()
		_preview_res = null
		Q.report("block_placed", 1)             # прогресс заданий на сборку
		if bmn.has_method("rebuild_factory_links"):
			bmn.rebuild_factory_links()         # авто-коннект фабрики ЦЕЛИ сразу после постановки
		if _hand_from_inventory:
			_refill_hand_from_inventory(placed_bt, keep_basis)
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
	# «Кабина была» — свойство СТАРОЙ сборки, и переносить его на новую нельзя. Раскладка
	# меняет машину целиком, поэтому после неё правда только то, что нашёл _connect_cabin.
	# Иначе сборка БЕЗ кабины (стационарная база из сейва ставится поверх стартовой, у
	# которой кабина есть) наследовала чужую историю, и сторож сносил её как погибшую.
	_had_cabin = false
	_connect_cabin()                        # новая кабина — заново ловим её гибель
	_notify_build_changed()                 # сборка сменилась целиком — вес тоже

func _return_hand_to_inventory() -> void:
	var holder: Node = camera_controller.camera.get_child(0) \
			if (camera_controller != null and camera_controller.camera != null) else null
	if holder != null:
		for child in holder.get_children():
			# Узел, уже отправленный на удаление, живёт до конца кадра — но он ПОТРАЧЕН
			# (ядро ушло в новую машину), и класть его тип в инвентарь значит выдать копию.
			if not is_instance_valid(child) or child.is_queued_for_deletion():
				continue
			# РЕСУРС в инвентарь блоков не кладётся и уничтожаться не должен: инвентарь
			# хранит типы блоков, а руда — предмет мира. Раньше сюда попадал любой ребёнок
			# держателя и БЕЗУСЛОВНО освобождался — ресурс просто исчезал бы из игры при
			# любом опустошении руки (выход из стройки, взятие другого блока).
			if _is_resource(child):
				_put_resource_back(child as Node3D)
				continue
			if "block" in child:
				G.block_inventory.append(int(child.get("block")))
			holder.remove_child(child)
			child.queue_free()
		G.mark_progress_dirty()
	block_body = null
	block_take = false
	hand_kind = Hand.EMPTY
	_preview_res = null

## Положить ресурс из руки обратно в мир — перед камерой, на землю. Ресурс сам ляжет на
## поверхность (resource._integrate_forces прижимает его к heightmap), поэтому высоту не
## считаем. Разморозить обязаны ВРУЧНУЮ: у блоков freeze переключается сам по смене
## родителя (VehicleBlock._on_parent_changed), у ресурса такой логики нет.
func _put_resource_back(res: Node3D) -> void:
	var objects := get_node_or_null("/root/Main/objects")
	if objects == null or not is_instance_valid(res):
		return
	var cam: Camera3D = camera_controller.camera if camera_controller != null else null
	var drop: Vector3 = global_position + Vector3.UP * 1.5
	if cam != null:
		var fwd: Vector3 = -cam.global_transform.basis.z
		fwd.y = 0.0
		if fwd.length_squared() > 0.0001:
			drop = global_position + fwd.normalized() * 3.0 + Vector3.UP * 1.5
	res.top_level = false
	res.reparent(objects)
	res.global_position = drop
	res.scale = Vector3.ONE
	if res is RigidBody3D:
		var rb := res as RigidBody3D
		rb.freeze = false
		rb.sleeping = false
		rb.linear_velocity = Vector3.ZERO
		rb.angular_velocity = Vector3.ZERO
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
	hand_kind = Hand.BLOCK
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
	# Инвентарь хранит ТИПЫ БЛОКОВ — руде там места нет. Кладём её обратно в мир: это
	# единственное осмысленное «убрать из руки» для ресурса.
	if hand_kind == Hand.RESOURCE:
		drop_hand_to_world()
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
		hand_kind = Hand.EMPTY
		return
	var instance: Node3D = holder.get_child(0)
	if _is_resource(instance):
		_put_resource_back(instance)      # у ресурса нет .block — и размораживать его надо руками
		block_body = null
		block_take = false
		hand_kind = Hand.EMPTY
		_preview_res = null
		if ghost_block:
			ghost_block.visible = false
		return
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
	hand_kind = Hand.EMPTY
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
