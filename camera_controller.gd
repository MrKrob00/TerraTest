extends Node3D

@export var current_vehicle: RigidBody3D # Ссылка на активную машину
@export var lerp_speed: float = 10.0 # Скорость следования камеры

var vehicles: Array

@onready var camera: Camera3D = $SpringArm3D/Camera3D
@onready var Spring: SpringArm3D = $SpringArm3D
@onready var hud: CanvasLayer = $HUD
@onready var joystick_move = $HUD/Joystick_movement
@onready var joystick_cam: TouchScreenButton = $HUD/Joystick_camera

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

const PITCH_SPEED := 1.4          # рад/с от джойстика
const PITCH_MIN := -0.35          # ~−20°: смотреть вниз
const PITCH_MAX := 0.66           # ~+38°: смотреть вдаль, к горизонту
var gaze_pitch: float = 0.0
# В СТРОЙКЕ разрешаем заглянуть ПОД машину (ставить блоки снизу): смотрим сильнее вверх, и чем
# выше взгляд — тем ниже уходит камера (под днище). Машина в стройке парит, поэтому камере можно
# опуститься ближе к земле, чем обычные 8 м.
const BUILD_PITCH_MAX := 1.4      # ~+80° вверх в стройке
const BUILD_UNDER_DROP := 5.0     # насколько камера уходит НИЖЕ машины при полном взгляде вверх
const BUILD_MIN_CLEARANCE := 1.5  # в стройке камере можно ближе к земле

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
					# Гейт `not _in_build()` больше не нужен и был неверен: подбор блока и
					# ресурса давно работает В ЛЮБОМ режиме, а не только в стройке. Сработавший
					# двойной тап теперь гасится машиной (vehicle_body_3d._commit_build_tap →
					# set_input_as_handled), и сюда просто не доходит — а если дошёл, значит
					# тапнули в пустоту, и сброс взгляда там уместен.
					if now - _last_tap_ms < DOUBLE_TAP_MS:
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
# Зовётся каждый физ-тик из camera_movement. Кеш срабатывал только при УСПЕХЕ: пока карты в
# сцене нет (первые кадры) или её вообще нет, поиск шёл заново КАЖДЫЙ тик — аллокация массива
# всех детей сцены + has_method() на каждом. Держим отдельный троттл на неудачный поиск.
var _terrain_retry: float = 0.0

func _terrain_height(world_pos: Vector3) -> float:
	if _terrain == null or not is_instance_valid(_terrain):
		_terrain = null
		if _terrain_retry > 0.0:
			_terrain_retry -= get_physics_process_delta_time()
			return -INF                     # не пересканируем сцену чаще раза в 0.5с
		_terrain_retry = 0.5
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
	if current_vehicle != dead:
		return
	var origin: Vector3 = (dead as Node3D).global_position if is_instance_valid(dead) else global_position
	current_vehicle = null            # чтобы switch_to_vehicle не дёргал умирающую
	var alive: Array = []
	for v in vehicles:
		if is_instance_valid(v) and v != dead:
			alive.append(v)
	if alive.is_empty():
		var starter: Node = _spawn_starter_vehicle(origin)
		if starter == null:
			push_error("camera_controller: возрождение не удалось — игрок остался без машины")
			return
		switch_to_vehicle(starter)
		# Камера СНАПАЕТСЯ: возрождение уносит на 60-100 м от места гибели, и обычный lerp
		# полз бы туда через всю карту, показывая по дороге пустой рельеф.
		global_position = (starter as Node3D).global_position
		return
	var best: RigidBody3D = alive[0]
	var best_d2 := INF
	for v in alive:
		var d2: float = origin.distance_squared_to((v as Node3D).global_position)
		if d2 < best_d2:
			best_d2 = d2
			best = v
	switch_to_vehicle(best)

# ── Возрождение ──────────────────────────────────────────────────────────────
# Возрождаемся ГОЛОЙ КАБИНОЙ: ни оружия, ни брони, а базовый набор ещё только осыпается
# рядом орбитой. Поэтому «не вплотную к врагу» — недостаточное условие: нужно место, где
# бой можно вообще НЕ начинать, пока машина не собрана.
#
# Раньше точка искалась в 60–100 м от места гибели с запасом 40 м до врага, тогда как зона
# обнаружения врага была 85 м, а пушка бьёт на 60. Оба числа были меньше его радиуса, то есть
# кабина ГАРАНТИРОВАННО появлялась внутри чужой зоны агрессии, и следующая смерть шла сразу
# за предыдущей. Отсюда правило: запас считается ОТ РАДИУСА ВРАГА, а не от круглого числа —
# радиус с тех пор опустили до 40, и возрождение подстроилось само, без правок здесь.

## Кольцо поиска вокруг места гибели. Начинаем близко (гнать игрока через полкарты к своим
## обломкам — наказание, а не механика) и РАСШИРЯЕМ, пока не найдётся чистая точка.
const RESPAWN_MIN_DIST: float = 80.0
const RESPAWN_MAX_DIST: float = 140.0
const RESPAWN_RING_STEP: float = 90.0   # на столько отодвигаем кольцо за каждый заход
const RESPAWN_RINGS: int = 4            # до ~350 м от места гибели
const RESPAWN_TRIES: int = 16           # проб на кольцо
## Насколько дальше ЗОНЫ ОБНАРУЖЕНИЯ врага надо оказаться. Радиус берём у самого врага
## (detection_radius), запас — чтобы он не заметил кабину, едва она тронется.
const RESPAWN_ENEMY_MARGIN: float = 60.0
const RESPAWN_FALLBACK_DETECT: float = 40.0   # если у врага нет поля — значение по умолчанию
const RESPAWN_CLEARANCE: float = 3.0    # над рельефом

func _spawn_starter_vehicle(pos: Vector3) -> Node:
	var scene: PackedScene = load("res://player_vehicle.tscn")
	if scene == null:
		push_error("camera_controller: нет player_vehicle.tscn для стартовой машины")
		return null
	var v: Node3D = scene.instantiate()
	# Возрождаемся ГОЛОЙ КАБИНОЙ, как в самом начале игры: базовый набор прилетит орбитой и
	# осыплется рядом. layout_preset ставим ДО add_child — раскладку blocks строит в _ready.
	var blocks: Node = v.get_node_or_null("blocks")
	if blocks != null and "layout_preset" in blocks:
		blocks.layout_preset = 4           # _layout_cabin_only
	get_parent().add_child(v)              # под Vehicles — карта даст стриминговую коллизию
	v.global_position = _respawn_point(pos)
	if not vehicles.has(v):
		vehicles.append(v)
	# Отложенно: машина только что вошла в дерево, а орбитеры цепляются за неё.
	if v.has_method("award_block_list"):
		v.award_block_list.call_deferred(G.STARTER_KIT)
	return v

## Точка возрождения. Кольца от места гибели наружу; на каждом — несколько проб по кругу.
## Годная точка это та, где ДО КАЖДОГО врага дальше, чем его зона обнаружения плюс запас;
## первая такая и возвращается. Если не нашлось ни одной за все кольца — берём САМУЮ
## БЕЗОПАСНУЮ из просмотренных: лучше возродиться на краю чужого радиуса, чем в его центре.
## Высоту не фильтруем: в мире НЕТ ВОДЫ (см. addons/LiteTerrain/plugin.gd) — низина это
## просто низина, и отбраковывать её не за что.
func _respawn_point(death_pos: Vector3) -> Vector3:
	var threats: Array = _enemy_threats()
	var best: Vector3 = death_pos + Vector3(0.0, RESPAWN_CLEARANCE, 0.0)
	var best_margin: float = -INF
	for ring in RESPAWN_RINGS:
		var lo: float = RESPAWN_MIN_DIST + RESPAWN_RING_STEP * float(ring)
		var hi: float = RESPAWN_MAX_DIST + RESPAWN_RING_STEP * float(ring)
		var base: float = randf() * TAU
		for i in RESPAWN_TRIES:
			var ang: float = base + TAU * float(i) / float(RESPAWN_TRIES)
			var dist: float = randf_range(lo, hi)
			var p := death_pos + Vector3(cos(ang) * dist, 0.0, sin(ang) * dist)
			var h: float = _terrain_height(p)
			p.y = (h if h > -INF else death_pos.y) + RESPAWN_CLEARANCE
			var margin: float = _enemy_margin(p, threats)
			if margin >= 0.0:
				return p                       # чисто: угол уже случайный, перебирать нечего
			if margin > best_margin:
				best_margin = margin
				best = p
	return best

# Насколько точка ДАЛЬШЕ зоны обнаружения самого опасного отсюда врага. Отрицательное — мы
# внутри чьего-то радиуса. INF — врагов нет вовсе.
func _enemy_margin(p: Vector3, threats: Array) -> float:
	var worst: float = INF
	for t in threats:
		var e: Vector3 = t["pos"]
		var d := Vector2(p.x - e.x, p.z - e.z)
		worst = minf(worst, d.length() - float(t["reach"]))
	return worst

# Враги как УГРОЗЫ: позиция плюс дальность, на которой этот конкретный враг нас заметит.
# Радиус спрашиваем у него самого — у разных сборок он может отличаться, и зашитое число
# рано или поздно разошлось бы с настройкой врага.
func _enemy_threats() -> Array:
	var out: Array = []
	var root: Node = get_parent()          # Vehicles
	if root == null:
		return out
	for c in root.get_children():
		if not (c is Node3D) or not ("faction" in c) or int(c.get("faction")) == 0:
			continue
		var r = c.get("detection_radius")
		var reach: float = (float(r) if r != null else RESPAWN_FALLBACK_DETECT) + RESPAWN_ENEMY_MARGIN
		out.append({"pos": (c as Node3D).global_position, "reach": reach})
	return out

func _on_raycast_body_entered(body: Node3D) -> void:
	if body.get_parent().name == "objects" and !current_vehicle.block_take:
		current_vehicle.ghost_block.global_position = body.global_position
		current_vehicle.block_body = body
