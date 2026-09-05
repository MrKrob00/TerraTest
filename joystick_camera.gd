extends TouchScreenButton
#Hi
@onready var max_distance = shape.radius

@onready var knob_pos = Vector2.ZERO
@onready var stick_center: Vector2= Vector2.ZERO
@onready var radius:float = $"../..".RADIUS
var active_touch_index: int = -1
var second_touch_index: int = -1
var active_touch_pos: Vector2 = Vector2.ZERO
var second_touch_pos: Vector2 = Vector2.ZERO
var zoom: bool = false
var distance: float = 0.0
var _press_ms: int = 0             # когда нажали текущий палец (тап = короткое нажатие)
var _tap_ready_ms: int = -10000    # когда отпустили последний КОРОТКИЙ тап (для двойного)
var _had_pending: bool = false     # это нажатие пришло после свежего тапа (кандидат в двойной)

@onready var screen_size = get_viewport().get_visible_rect().size

func _ready():
	#var start_pos = global_position
	knob_pos = stick_center
	#set_process(false)

func _draw() -> void:
	draw_circle(Vector2.ZERO, max_distance, Color.WHITE, false, 12)
	draw_circle(knob_pos, max_distance/2, Color.GHOST_WHITE, true)

func _input(event):
	# Удержание кнопки на машине / открытое круговое меню — камеру не крутим,
	# иначе жест кнопки в зоне джойстика вращал камеру вместе с прогрессом.
	if G.ui_grab:
		if active_touch_index != -1:
			active_touch_index = -1
			knob_pos = stick_center
			queue_redraw()
		return
	if event is InputEventScreenTouch:
		if event.pressed:
			if active_touch_index == -1 and is_touch_outside(event.position):
				global_position = event.position

			if active_touch_index == -1 and is_touch_inside(event.position):
				active_touch_index = event.index
				active_touch_pos = event.position
				update_knob_position(event.position)
				# Кандидат в двойной тап запоминаем, но РЕШАЕМ на отпускании: в момент
				# нажатия ещё неизвестно, тап это или начало драга/пинча — сброс наклона
				# по «тап + быстрый драг» стирал бы только что выставленный взгляд.
				_press_ms = Time.get_ticks_msec()
				_had_pending = _press_ms - _tap_ready_ms < 300
				_tap_ready_ms = -10000   # ожидание потреблено этим нажатием

			if active_touch_index != -1 and is_touch_outside_2(event.position):
				second_touch_index = event.index
				second_touch_pos = event.position
				zoom = true
				distance = active_touch_pos.distance_to(second_touch_pos)
				knob_pos=stick_center
			else: zoom = false

		elif not event.pressed and event.index == active_touch_index:
			# Тап = короткое нажатие почти без движения ручки; драг и пинч-зум — не тап.
			var now := Time.get_ticks_msec()
			if now - _press_ms < 250 and not zoom \
					and (knob_pos - stick_center).length_squared() < max_distance * 0.3 * max_distance * 0.3:
				if _had_pending:
					pass   # сброс взгляда убран: двойной тап занят подбором блока
				else:
					_tap_ready_ms = now     # первый тап — ждём второго (третий не сдвоится)
			_had_pending = false
			active_touch_index = -1
			knob_pos = stick_center

	elif !zoom and event is InputEventScreenDrag and event.index == active_touch_index:
		update_knob_position(event.position)
		queue_redraw()
	elif zoom and event is InputEventScreenDrag:
		if event.index == active_touch_index:
			set_zoom(active_touch_pos,second_touch_pos)
			active_touch_pos = event.position
		elif event.index == second_touch_index:
			set_zoom(active_touch_pos,second_touch_pos)
			second_touch_pos = event.position

func is_touch_inside(touch_pos: Vector2):
	return (touch_pos - global_position).length_squared() <= (max_distance / 10.0) * (max_distance / 10.0)

func is_touch_outside(touch_pos: Vector2):
	screen_size = get_viewport().get_visible_rect().size
	var r: float = max_distance / 10.0
	return (touch_pos - global_position).length_squared() > r * r and touch_pos.x > screen_size.x/3*2 and touch_pos.y <screen_size.y/2

func is_touch_outside_2(touch_pos: Vector2):
	screen_size = get_viewport().get_visible_rect().size
	return (touch_pos - global_position).length_squared() > max_distance * max_distance and touch_pos.x > screen_size.x/2 and touch_pos.y <screen_size.y/2

func update_knob_position(touch_pos: Vector2):
	var dir = touch_pos - global_position
	knob_pos = stick_center + dir.limit_length(max_distance)

func get_joystick_dir() -> Vector2:
	var dir = knob_pos - stick_center
	return dir.normalized()

func set_zoom(index1:Vector2,index2:Vector2):
	var d = index1.distance_to(index2)
	var result = d/ distance
	distance = d
	radius = $"../..".RADIUS   # ресинк с живым значением — иначе колесо мыши (ПК-зум) затиралось бы старым кэшем
	radius/=result
	if radius<2: radius=2
	if radius>20: radius=20
	$"../..".RADIUS = radius
