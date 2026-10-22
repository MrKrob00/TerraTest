extends Control
class_name FactoryPickerWheel

var entries: Array = []
var current_index: int = 0
var radius: float = 170.0
var center: Vector2 = Vector2.ZERO
var on_pick: Callable = Callable()

func setup(items: Array, selected_idx: int, callback: Callable) -> void:
	entries = items
	current_index = clampi(selected_idx, 0, maxi(items.size() - 1, 0))
	on_pick = callback
	queue_redraw()

func _draw() -> void:
	if entries.is_empty():
		return
	var step: float = TAU / float(entries.size())
	center = size * 0.5
	for i in entries.size():
		var start: float = -PI * 0.5 + step * i
		var a0: Vector2 = center + Vector2(cos(start), sin(start)) * (radius * 0.2)
		var a1: Vector2 = center + Vector2(cos(start + step), sin(start + step)) * (radius * 0.2)
		var outer0: Vector2 = center + Vector2(cos(start), sin(start)) * radius
		var outer1: Vector2 = center + Vector2(cos(start + step), sin(start + step)) * radius
		var color: Color = _sector_color(i)
		draw_polygon(PackedVector2Array([center, a0, outer0, outer1, a1]), PackedColorArray([color]))
		var mid: float = start + step * 0.5
		var label_pos: Vector2 = center + Vector2(cos(mid), sin(mid)) * (radius * 0.7)
		var name: String = String((entries[i] as Dictionary).get("name", ""))
		if name.length() > 0:
			draw_string(get_theme_default_font(), label_pos - Vector2(20.0, 0.0), name.substr(0, 12), HORIZONTAL_ALIGNMENT_CENTER, -1, 14, Color.WHITE)
	draw_arc(center, radius * 0.8, 0.0, TAU, 30, Color(0.18, 0.24, 0.30, 1.0), 2.0, true)
	draw_circle(center, 55.0, Color(0.12, 0.18, 0.22, 0.96))
	var current: Dictionary = entries[current_index] if current_index >= 0 and current_index < entries.size() else {}
	var title: String = String(current.get("name", "Current"))
	draw_string(get_theme_default_font(), center - Vector2(12.0, 0.0), title.substr(0, 18), HORIZONTAL_ALIGNMENT_CENTER, -1, 18, Color(0.98, 0.98, 0.98))

func _sector_color(i: int) -> Color:
	if i == current_index:
		return Color(0.18, 0.78, 0.72, 1.0)
	var entry: Dictionary = entries[i] if i >= 0 and i < entries.size() else {}
	var base: Color = entry.get("color", Color(0.55, 0.78, 0.82))
	return base.lerp(Color(0.18, 0.24, 0.30, 1.0), 0.25)

func _gui_input(event: InputEvent) -> void:
	if not (event is InputEventMouseButton and event.pressed):
		return
	var local: Vector2 = event.position - center
	if local.length_squared() < 20.0 * 20.0:
		return
	var angle: float = atan2(local.y, local.x) + PI * 0.5
	while angle < 0.0:
		angle += TAU
	var step: float = TAU / maxf(float(entries.size()), 1.0)
	var idx: int = int(floor(angle / step)) % entries.size()
	current_index = idx
	queue_redraw()
	if on_pick != null and on_pick.is_valid():
		on_pick.call(idx)
