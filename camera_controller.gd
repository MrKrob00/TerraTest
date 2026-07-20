extends Node3D

@export var current_vehicle: RigidBody3D # Ссылка на активную машину
@export var lerp_speed: float = 10.0 # Скорость следования камеры

var vehicles: Array

@onready var camera = $SpringArm3D/Camera3D
@onready var Spring = $SpringArm3D
@onready var hud = $HUD
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

func _ready():
	add_to_group("camera_controller")   # чтобы UI (tech_ui) находил активную машину
	# Собираем только управляемую игроком технику (у неё есть take_block_into_hand),
	# чтобы враг (другой RigidBody3D в Vehicles) не попадал в список переключения.
	var vehicle_childs = $"..".get_children()
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

func _process(delta):
	if not current_vehicle: return

	# 1. Smoothly move the entire controller to the car's 
	var target_pos = current_vehicle.global_position
	
	global_position = global_position.lerp(target_pos, delta * lerp_speed)


	camera_movement(delta)

var locked_angle: float = 0.0
var is_locked: bool = false

func camera_movement(delta):
	var dir = (-$"HUD/Joystick_camera".get_joystick_dir().x)
	# Жест кругового меню мог включиться ПОСЛЕ того, как в этот же кадр уже накопился
	# сдвиг мыши (_input идёт раньше _process) — не даём этому остатку доехать до угла.
	# Наклон взгляда: джойстик вверх (экранный y отрицательный) и мышь вверх — смотреть выше.
	var tilt : float = -joystick_cam.get_joystick_dir().y
	# Жест кругового меню гасит ОБА источника, включая джойстик: его центрует _input самого
	# джойстика, но если пальцы замерли — событий нет, и отклонённая ручка продолжала бы
	# крутить (а теперь и наклонять) камеру весь холд.
	if VehicleInteractButton.camera_block:
		_mouse_look_dx = 0.0
		_mouse_look_dy = 0.0
		dir = 0.0
		tilt = 0.0
	var mouse_turn := -_mouse_look_dx * MOUSE_SENS
	_mouse_look_dx = 0.0
	var mouse_pitch := -_mouse_look_dy * MOUSE_SENS
	_mouse_look_dy = 0.0
	if absf(tilt) > 0.05 or mouse_pitch != 0.0:
		gaze_pitch = clampf(gaze_pitch + tilt * PITCH_SPEED * delta + mouse_pitch, PITCH_MIN, PITCH_MAX)
	# mouse_turn либо ровно 0.0 (не двигали), либо реальный накопленный сдвиг — тут не
	# нужен допуск на дребезг, в отличие от аналогового джойстика ниже.
	if abs(dir) > 0.05 or mouse_turn != 0.0:
		angle += dir * ROT_SPEED * delta + mouse_turn
		is_locked = false
		locked_angle = angle - current_vehicle.global_rotation.y
	else:
		if not is_locked:
			locked_angle = angle - current_vehicle.global_rotation.y
			is_locked = true
		angle = current_vehicle.global_rotation.y + locked_angle
	
	var offset := Vector3(RADIUS * sin(angle), CAM_HEIGHT, RADIUS * cos(angle))
	# Минимум MIN_GROUND_CLEARANCE (8 м) над террейном: если точку камеры поджал рельеф —
	# поднимаем её вертикально (взгляд всё равно на машину). Выше 8 м — не трогаем.
	var cam_pos: Vector3 = current_vehicle.global_position + offset
	var ground := _terrain_height(cam_pos)
	if cam_pos.y < ground + MIN_GROUND_CLEARANCE:
		offset.y += ground + MIN_GROUND_CLEARANCE - cam_pos.y
	Spring.spring_length = offset.length()
	# Смотрим строго на машину. Раньше сюда ДОБАВЛЯЛСЯ крен корпуса (rotation.x) поверх
	# look_at — на горках камеру клевало вниз/вверх и она теряла машину из виду.
	Spring.look_at_from_position(current_vehicle.global_position + offset * 0.01, current_vehicle.global_position)
	# Наклон — ЛОКАЛЬНО на камере, после look_at арки: рига/длина пружины/прижим к земле
	# не затронуты, при gaze_pitch == 0 кадр идентичен прежнему.
	camera.rotation.x = gaze_pitch

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
