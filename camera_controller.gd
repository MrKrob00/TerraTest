extends Node3D

@export var current_vehicle: RigidBody3D # Ссылка на активную машину
@export var lerp_speed: float = 10.0 # Скорость следования камеры

var vehicles: Array

@onready var camera: Camera3D = $SpringArm3D/Camera3D
@onready var Spring: SpringArm3D = $SpringArm3D
@onready var hud: CanvasLayer = $HUD
@onready var joystick_move = $HUD/Joystick_movement
@onready var joystick_cam = $HUD/Joystick_camera

@export var RADIUS: float = 8.0
@export var CAM_HEIGHT: float = 4.0
@export var ROT_SPEED: float = 1.5
## Камера никогда не опускается ниже этой высоты над террейном (склон/гора поджимают
## её снизу — поднимаем точку камеры вертикально, взгляд остаётся на машине).
@export var MIN_GROUND_CLEARANCE: float = 8.0

# ── ПК: мышь ────────────────────────────────────────────────────────────────────
# ПКМ+драг вращает камеру (ЛКМ занята стройкой/UI), колесо — зум. Тач-джойстик камеры
# не трогаем — оба источника складываются в camera_movement().
const MOUSE_SENS := 0.0025   # рад на пиксель движения мыши
const ZOOM_STEP := 1.0
const ZOOM_MIN := 2.0
const ZOOM_MAX := 20.0
var _mouse_look_dx: float = 0.0   # накопленный сдвиг мыши по X с прошлого кадра (ПКМ зажата)
var _mouse_look_dy: float = 0.0   # то же по Y — наклон взгляда

# ── Наклон взгляда (gaze pitch) ─────────────────────────────────────────────────
# Позиция камеры остаётся на орбите (RADIUS/CAM_HEIGHT/прижим к земле не трогаем) —
# наклоняется только НАПРАВЛЕНИЕ взгляда: camera.rotation.x. Храним именно УГОЛ,
# а не сдвиг цели в метрах: наклон ощущается одинаково на любом зуме.
# Управление: вертикаль джойстика камеры (раньше ось пустовала) и вертикаль мыши
# при зажатой ПКМ. Сброс на машину: двойной тап по зоне джойстика / двойная ПКМ.
const PITCH_SPEED := 1.4          # рад/с от джойстика
const PITCH_MIN := -0.35          # ~−20°: смотреть вниз
const PITCH_MAX := 0.66           # ~+38°: смотреть вдаль, к горизонту
var gaze_pitch: float = 0.0       # 0 — ровно на машину, как раньше
# В СТРОЙКЕ разрешаем заглянуть ПОД машину (ставить блоки снизу): смотрим сильнее вверх, и чем
# выше взгляд — тем ниже уходит камера (под днище). Машина в стройке парит, поэтому камере можно
# опуститься ближе к земле, чем обычные 8 м.
const BUILD_PITCH_MAX := 1.4      # ~+80° вверх в стройке
const BUILD_UNDER_DROP := 5.0     # насколько камера уходит НИЖЕ машины при полном взгляде вверх
const BUILD_MIN_CLEARANCE := 1.5  # в стройке камере можно ближе к земле

# ── Тач-камера (свайп вместо джойстика) ─────────────────────────────────────────
# Один палец по миру — орбита (гориз.) + наклон взгляда (верт.), как во всех 3D-мобилках.
# Два пальца — пинч-зум (раньше жил в джойстике камеры). Двойной тап — сброс взгляда.
# Касания в зоне джойстика ДВИЖЕНИЯ игнорируем (там его палец), UI-кнопки/глобус тач съедают
# сами (обрабатываем в _unhandled_input — доходит только НЕсъеденное).
const TOUCH_LOOK_SENS := 0.006    # рад/пиксель свайпа (тач крупнее мыши)
const PINCH_ZOOM_SENS := 0.03     # единиц RADIUS на пиксель изменения расстояния пинча
const TAP_MAX_MOVE := 14.0        # пиксель: больше сдвиг — это свайп, а не тап
const DOUBLE_TAP_MS := 300
var _cam_touches: Dictionary = {} # index → позиция «мировых» касаний (не джойстик движения)
var _touch_look_dx: float = 0.0
var _touch_look_dy: float = 0.0
var _pinch_last: float = -1.0
var _tap_down_pos: Vector2 = Vector2.ZERO
var _tap_down_ms: int = 0
var _last_tap_ms: int = -10000
var _tap_moved: bool = false

var angle: float = 0.0
var is_active: bool = false
var _terrain: Node = null   # кэш ноды террейна (terrain_height_at)

func _input(event: InputEvent) -> void:
	# Жест кругового меню (см. VehicleInteractButton) не должен ещё и крутить камеру —
	# тот же гейт, что уже стоит у тач-джойстика камеры.
	if VehicleInteractButton.camera_block:
		return
	# Мышь над любым UI (гараж, HUD-кнопки) не должна ещё и вертеть/зумить мировую камеру —
	# иначе прокрутка списка в гараже или ПКМ-драг над панелью крутили бы камеру под ней.
	# Тача это не касается: правая кнопка/колесо мыши тачем не эмулируются.
	if get_viewport().gui_get_hovered_control() != null:
		return
	if event is InputEventMouseMotion and Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT):
		_mouse_look_dx += event.relative.x
		_mouse_look_dy += event.relative.y
	elif event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			RADIUS = clampf(RADIUS - ZOOM_STEP, ZOOM_MIN, ZOOM_MAX)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			RADIUS = clampf(RADIUS + ZOOM_STEP, ZOOM_MIN, ZOOM_MAX)
		elif event.button_index == MOUSE_BUTTON_RIGHT and event.double_click:
			reset_gaze()             # двойная ПКМ — взгляд снова ровно на машину

# Тач-камера: сюда доходят только касания, НЕ съеденные UI (кнопки/глобус — Control-ы с
# mouse_filter STOP их поглощают). Палец джойстика движения тоже пропускаем (по его индексу),
# в стройке камеру не крутим (там драги ставят блоки).
func _unhandled_input(event: InputEvent) -> void:
	if VehicleInteractButton.camera_block:
		return
	# Камера крутится ОДНИМ пальцем одинаково во всех режимах (и в езде, и в стройке): драг —
	# орбита. В стройке блок наводится ТАПОМ (см. vehicle_body_3d._input), поэтому драг свободен
	# под камеру — двумя пальцами больше крутить не надо (было неудобно/непривычно).
	var jmove_idx: int = joystick_move.active_touch_index if joystick_move else -1
	if event is InputEventScreenTouch:
		if event.pressed:
			if event.index == jmove_idx:
				return                       # это палец джойстика движения
			_cam_touches[event.index] = event.position
			if _cam_touches.size() == 1:
				_tap_down_pos = event.position
				_tap_down_ms = Time.get_ticks_msec()
				_tap_moved = false
		else:
			if _cam_touches.has(event.index):
				# короткое касание без свайпа = тап; два тапа подряд — сброс взгляда на машину.
				if _cam_touches.size() == 1 and not _tap_moved \
						and Time.get_ticks_msec() - _tap_down_ms < 250:
					var now := Time.get_ticks_msec()
					if now - _last_tap_ms < DOUBLE_TAP_MS and not _in_build():
						reset_gaze()
						_last_tap_ms = -10000
					else:
						_last_tap_ms = now
				_cam_touches.erase(event.index)
			if _cam_touches.size() < 2:
				_pinch_last = -1.0
	elif event is InputEventScreenDrag:
		if event.index == jmove_idx or not _cam_touches.has(event.index):
			return
		_cam_touches[event.index] = event.position
		if _tap_down_pos.distance_to(event.position) > TAP_MAX_MOVE:
			_tap_moved = true
		if _cam_touches.size() >= 2:
			# Пинч-зум: развёл пальцы (дистанция растёт) → приближаем (RADIUS меньше).
			var pts: Array = _cam_touches.values()
			var d: float = pts[0].distance_to(pts[1])
			if _pinch_last > 0.0:
				RADIUS = clampf(RADIUS - (d - _pinch_last) * PINCH_ZOOM_SENS * G.cam_zoom_sens, ZOOM_MIN, ZOOM_MAX)
			_pinch_last = d
		else:
			# Один палец — орбита (X) + наклон взгляда (Y). Работает и в стройке: там одиночный
			# палец крутит камеру ровно как при езде, а блок наводится ТАПОМ (vehicle_body_3d).
			_touch_look_dx += event.relative.x
			_touch_look_dy += event.relative.y

func _ready():
	add_to_group("camera_controller")   # чтобы UI (tech_ui) находил активную машину
	# Джойстик камеры заменён свайпом (тач-look) — прячем костыль и глушим его ввод.
	if joystick_cam:
		joystick_cam.visible = false
		joystick_cam.set_process_input(false)
	# Собираем только управляемую игроком технику (у неё есть take_block_into_hand),
	# чтобы враг (другой RigidBody3D в Vehicles) не попадал в список переключения.
	var vehicle_childs: Array[Node] = $"..".get_children()
	for i in vehicle_childs:
		if i is RigidBody3D and i.has_method("take_block_into_hand"):
			if !vehicles.has(i):
				vehicles.append(i)

	# Если машина не задана, попробуем найти первую в списке Vehicles
	if not current_vehicle:
		switch_to_vehicle(vehicles[0])
	else: 
		if current_vehicle.has_method("set_active"):
			current_vehicle.set_active(true)

# Камера следит за МАШИНОЙ, а машина — RigidBody3D, её трансформ обновляет физика на своём тике.
# Раньше слежение шло в _process (кадр отрисовки): между физ-шагами позиция тела не меняется, и
# камера то догоняла её, то стояла — характерное подрагивание картинки, особенно когда FPS не
# совпадает с частотой физики (а у нас авто-масштаб FPS её как раз гоняет). Читаем позицию там же,
# где она меняется — на физ-тике.
func _physics_process(delta):
	if not current_vehicle: return

	# 1. Smoothly move the entire controller to the car's
	var target_pos: Vector3 = current_vehicle.global_position

	global_position = global_position.lerp(target_pos, delta * lerp_speed)


	camera_movement(delta)

var locked_angle: float = 0.0
var is_locked: bool = false

func camera_movement(_delta):
	# Поворот/наклон камеры — от СВАЙПА (тач) и мыши (ПКМ-драг на ПК). Оба уже в пикселях,
	# накоплены за кадр (_touch_look_* в _unhandled_input, _mouse_look_* в _input). Джойстик
	# камеры убран (был костылём). Жест кругового меню гасит оба источника.
	if VehicleInteractButton.camera_block:
		_mouse_look_dx = 0.0
		_mouse_look_dy = 0.0
		_touch_look_dx = 0.0
		_touch_look_dy = 0.0
	# Множитель чувствительности — из настроек игрока (G.cam_look_sens).
	var look_k: float = G.cam_look_sens
	var turn := -(_mouse_look_dx * MOUSE_SENS + _touch_look_dx * TOUCH_LOOK_SENS) * look_k
	_mouse_look_dx = 0.0
	_touch_look_dx = 0.0
	var pitch := -(_mouse_look_dy * MOUSE_SENS + _touch_look_dy * TOUCH_LOOK_SENS) * look_k
	_mouse_look_dy = 0.0
	_touch_look_dy = 0.0
	if G.cam_invert_y:
		pitch = -pitch                     # инверсия вертикали (настройка)
	var pmax := BUILD_PITCH_MAX if _in_build() else PITCH_MAX
	if pitch != 0.0:
		gaze_pitch = clampf(gaze_pitch + pitch, PITCH_MIN, pmax)
	gaze_pitch = clampf(gaze_pitch, PITCH_MIN, pmax)   # ре-кламп при смене режима (вышел из стройки)
	if turn != 0.0:
		angle += turn
		is_locked = false
		locked_angle = angle - current_vehicle.global_rotation.y
	else:
		if not is_locked:
			locked_angle = angle - current_vehicle.global_rotation.y
			is_locked = true
		angle = current_vehicle.global_rotation.y + locked_angle
	
	var cam_h := CAM_HEIGHT
	var min_clear := MIN_GROUND_CLEARANCE
	if _in_build():
		# Заглянуть ПОД машину: чем выше смотрим (gaze_pitch↑), тем ниже уходит камера (под днище).
		var under := clampf(gaze_pitch / BUILD_PITCH_MAX, 0.0, 1.0)
		cam_h = lerpf(CAM_HEIGHT, -BUILD_UNDER_DROP, under)
		min_clear = BUILD_MIN_CLEARANCE
	var offset := Vector3(RADIUS * sin(angle), cam_h, RADIUS * cos(angle))
	# Минимум min_clear над террейном: если точку камеры поджал рельеф — поднимаем её вертикально
	# (взгляд всё равно на машину). В стройке порог ниже, чтобы камера могла уйти под парящую машину.
	var cam_pos: Vector3 = current_vehicle.global_position + offset
	var ground := _terrain_height(cam_pos)
	if cam_pos.y < ground + min_clear:
		offset.y += ground + min_clear - cam_pos.y
	Spring.spring_length = offset.length()
	# Смотрим строго на машину. Раньше сюда ДОБАВЛЯЛСЯ крен корпуса (rotation.x) поверх
	# look_at — на горках камеру клевало вниз/вверх и она теряла машину из виду.
	Spring.look_at_from_position(current_vehicle.global_position + offset * 0.01, current_vehicle.global_position)
	# Наклон — ЛОКАЛЬНО на камере, после look_at арки: рига/длина пружины/прижим к земле
	# не затронуты, при gaze_pitch == 0 кадр идентичен прежнему.
	# В СТРОЙКЕ gaze_pitch двигает камеру ПО ВЫСОТЕ (свешивает под машину), а look_at сам держит
	# машину в кадре — поэтому дополнительный наклон вида не добавляем (иначе перекрутит вверх).
	camera.rotation.x = 0.0 if _in_build() else gaze_pitch

# Активная машина сейчас в режиме стройки? (в стройке камеру крутим двумя пальцами)
func _in_build() -> bool:
	return current_vehicle != null and ("Building" in current_vehicle) and current_vehicle.Building

# Вернуть взгляд ровно на машину (двойной тап по джойстику камеры / двойная ПКМ).
func reset_gaze() -> void:
	gaze_pitch = 0.0

# Высота террейна под точкой (мировые координаты). Карты нет — вернёт -INF,
# тогда ограничение по высоте просто не действует.
func _terrain_height(world_pos: Vector3) -> float:
	if _terrain == null or not is_instance_valid(_terrain):
		_terrain = null
		for c in get_tree().current_scene.get_children():
			if c.has_method("terrain_height_at"):
				_terrain = c
				break
	if _terrain == null:
		return -INF
	return _terrain.terrain_height_at(world_pos)

# Machine change function 
func switch_to_vehicle(new_vehicle: RigidBody3D):
	if current_vehicle and current_vehicle.has_method("set_active"):
		current_vehicle._on_take_off_pressed()
		current_vehicle.set_active(false)
	
	current_vehicle = new_vehicle
	
	if current_vehicle.has_method("set_active"):
		current_vehicle.set_active(true)


# Машина погибла (уничтожена кабина): убираем из списка, садимся в ближайшую живую,
# а если техники не осталось — спавним бесплатную стартовую и садимся в неё.
func on_vehicle_died(dead: Node) -> void:
	vehicles.erase(dead)
	# Умерла НЕ текущая машина — камеру не трогаем, только вычистили из списка.
	# Раньше камера пересаживалась при гибели ЛЮБОЙ машины игрока.
	if current_vehicle != dead:
		return
	var origin: Vector3 = (dead as Node3D).global_position if is_instance_valid(dead) else global_position
	current_vehicle = null            # чтобы switch_to_vehicle не дёргал умирающую
	var alive: Array = []
	for v in vehicles:
		if is_instance_valid(v) and v != dead:
			alive.append(v)
	if alive.is_empty():
		var starter = _spawn_starter_vehicle(origin)
		if starter:
			switch_to_vehicle(starter)
		return
	var best = alive[0]
	var best_d := INF
	for v in alive:
		var d: float = origin.distance_to((v as Node3D).global_position)
		if d < best_d:
			best_d = d
			best = v
	switch_to_vehicle(best)

func _spawn_starter_vehicle(pos: Vector3) -> Node:
	var scene: PackedScene = load("res://player_vehicle.tscn")
	if scene == null:
		push_error("camera_controller: нет player_vehicle.tscn для стартовой машины")
		return null
	var v: Node3D = scene.instantiate()
	get_parent().add_child(v)              # под Vehicles — карта даст стриминговую коллизию
	v.global_position = pos + Vector3(0, 3, 0)
	if not vehicles.has(v):
		vehicles.append(v)
	return v


func _on_raycast_body_entered(body: Node3D) -> void:
	if body.get_parent().name in "objects" and !current_vehicle.block_take:
		current_vehicle.ghost_block.global_position = body.global_position
		current_vehicle.block_body = body
