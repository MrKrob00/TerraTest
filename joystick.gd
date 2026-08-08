extends TouchScreenButton

@onready var max_distance: float = shape.radius
@onready var knob_pos: Vector2 = Vector2.ZERO
@onready var stick_center: Vector2 = Vector2.ZERO
var active_touch_index: int = -1

# Мёртвая зона — движения меньше этого процента игнорируются
const DEAD_ZONE: float = 0.12

const ZONE_X_FRAC: float = 0.33
const ZONE_Y_FRAC: float = 0.60   # активна только часть НИЖЕ этой доли высоты

@onready var screen_size = get_viewport().get_visible_rect().size

func _ready():
	knob_pos = stick_center

func _draw() -> void:
	draw_circle(Vector2.ZERO, max_distance, Color.WHITE, false, 12)
	draw_circle(knob_pos, max_distance / 2.0, Color.GHOST_WHITE, true)

func _input(event):
	if event is InputEventScreenTouch:
		if event.pressed:
			if active_touch_index == -1 and is_touch_outside(event.position):
				global_position = event.position
				stick_center = Vector2.ZERO
				knob_pos = Vector2.ZERO

			if active_touch_index == -1 and is_touch_inside(event.position):
				active_touch_index = event.index
				update_knob_position(event.position)

		elif not event.pressed and event.index == active_touch_index:
			active_touch_index = -1
			knob_pos = stick_center
			queue_redraw()  # ← обновляем визуал при отпускании

	elif event is InputEventScreenDrag and event.index == active_touch_index:
		update_knob_position(event.position)
		queue_redraw()

func is_touch_inside(touch_pos: Vector2) -> bool:
	return (touch_pos - global_position).length() <= max_distance

func is_touch_outside(touch_pos: Vector2) -> bool:
	screen_size = get_viewport().get_visible_rect().size
	return (touch_pos - global_position).length() > max_distance \
		and touch_pos.x < screen_size.x * ZONE_X_FRAC \
		and touch_pos.y > screen_size.y * ZONE_Y_FRAC

func update_knob_position(touch_pos: Vector2) -> void:
	var dir := touch_pos - global_position
	knob_pos = stick_center + dir.limit_length(max_distance)

func get_joystick_dir() -> Vector2:
	var dir := knob_pos - stick_center
	# Нормализуем по радиусу джойстика → получаем значение 0.0 .. 1.0
	var raw := dir / max_distance

	# Применяем мёртвую зону
	var length := raw.length()
	if length < DEAD_ZONE:
		return Vector2.ZERO

	# Ремапируем диапазон [DEAD_ZONE .. 1.0] → [0.0 .. 1.0]
	# Это убирает прыжок при выходе из мёртвой зоны
	var remapped := (length - DEAD_ZONE) / (1.0 - DEAD_ZONE)
	return raw.normalized() * clamp(remapped, 0.0, 1.0)
