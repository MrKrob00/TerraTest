class_name QuestCompass
extends Control
# Метка ЦЕЛИ отслеживаемого задания. Пока цель на экране — жёлтый значок висит над ней;
# ушла за кадр — метка прилипает к ближайшему краю экрана и разворачивается остриём в её
# сторону. Это и есть весь смысл: не «где-то есть жила», а «жила вон там, поверни туда».
#
# Мировой точки у задания нет — она и не нужна: цель выводится из СОБЫТИЯ, которое двигает
# прогресс. Убить врага → ближайший враг; накопать руды → ближайшая активная жила;
# заработать → ближайший магазин. Задания, у которых цели в мире нет (собери машину,
# открой гараж), метку просто не показывают.

const PAD := 46.0            # насколько метка отступает от кромки, когда цель за кадром
const COL := Color(1.0, 0.82, 0.25)

var _t: float = 0.0

func _ready() -> void:
	add_to_group("quest_compass")   # журнал заданий берёт отсюда расстояние до цели
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_FULL_RECT)

func _process(delta: float) -> void:
	_t += delta
	# Держим узел РОВНО по видимой области. Компас лежит прямо в CanvasLayer, и его
	# собственный size не обязан совпадать с тем, в чём считает камера, — а рамка «цель на
	# экране» строилась именно от size. Стоило им разойтись, и рамка выходила крошечной
	# коробочкой у левого верхнего угла: значок замирал только там, а во всех остальных
	# местах цель считалась «за кадром» и рисовалась стрелка, даже когда игрок смотрит прямо
	# на неё. Ниже все расчёты идут от _screen(), из того же источника, что unproject_position.
	var vs: Vector2 = _screen()
	if size != vs:
		size = vs
		position = Vector2.ZERO
	queue_redraw()

## Видимая область — ТОТ ЖЕ источник, которым пользуется Camera3D.unproject_position
## (get_viewport().get_visible_rect().size). Разойтись они поэтому не могут.
func _screen() -> Vector2:
	return get_viewport().get_visible_rect().size

# Куда ведёт текущее задание. null — цели в мире нет, метку не рисуем.
func _target_pos() -> Variant:
	if get_node_or_null("/root/Q") == null:
		return null
	return target_of(Q.tracked())

## Цель ЛЮБОГО задания. Публично, потому что журнал показывает по ней расстояние: искать
## её вторым способом значило бы держать две копии одной логики, которые разъедутся.
func target_of(q: Dictionary) -> Variant:
	if q.is_empty() or q.get("done", false):
		return null
	var cam: Camera3D = get_viewport().get_camera_3d()
	if cam == null:
		return null
	# Предмет, положенный в мир этим квестом, — цель ТОЧНАЯ и важнее всякой эвристики
	# по событию: «найдите солнечную панель» ведёт именно к ней, а не к чему-то похожему.
	var props: Node = get_tree().get_first_node_in_group("quest_props")
	if props != null and props.has_method("position_for"):
		var exact = props.position_for(String(q.get("id", "")))
		if exact != null:
			return exact
	var from: Vector3 = cam.global_position
	match String(q.get("event", "")):
		"enemy_killed", "daily_kill":
			return _nearest_enemy(from)
		"ore_mined", "daily_ore":
			return _nearest_of(_ore_positions(), from)
		"money_earned":
			return _nearest_node(get_tree().get_nodes_in_group("shop"), from)
	return null

func _nearest_enemy(from: Vector3) -> Variant:
	var vehicles: Node = get_node_or_null("/root/Main/Vehicles")
	if vehicles == null:
		return null
	var list: Array = []
	for e in vehicles.get_children():
		var f = e.get("faction")
		if e is Node3D and f != null and int(f) != 0:
			list.append(e)
	return _nearest_node(list, from)

func _nearest_node(nodes: Array, from: Vector3) -> Variant:
	var pts: Array = []
	for n in nodes:
		if n is Node3D and is_instance_valid(n):
			pts.append((n as Node3D).global_position)
	return _nearest_of(pts, from)

func _ore_positions() -> Array:
	var rn: Node = get_node_or_null("/root/Main/map/Resource_Nodes")
	return rn.active_positions() if rn != null and rn.has_method("active_positions") else []

func _nearest_of(points: Array, from: Vector3) -> Variant:
	var best: Variant = null
	var best_d: float = INF
	for p in points:
		var d: float = from.distance_squared_to(p as Vector3)
		if d < best_d:
			best_d = d
			best = p
	return best

func _draw() -> void:
	var tgt: Variant = _target_pos()
	if tgt == null:
		return
	var cam: Camera3D = get_viewport().get_camera_3d()
	if cam == null:
		return
	var world: Vector3 = tgt
	# Точка ЗА камерой проецируется зеркально — метка ускакала бы в противоположный край.
	# Поэтому за спиной вообще не проецируем, а сразу считаем направление по осям камеры.
	var vs: Vector2 = _screen()
	var behind: bool = cam.is_position_behind(world)
	var p: Vector2 = vs * 0.5
	if not behind:
		p = cam.unproject_position(world)
	# Рамка «цель ещё на экране». Строго от видимой области, не от size узла.
	var rw: float = maxf(vs.x - PAD * 2.0, 1.0)
	var rh: float = maxf(vs.y - PAD * 2.0, 1.0)
	var r := Rect2(Vector2(PAD, PAD), Vector2(rw, rh))
	var off: bool = behind or not r.has_point(p)
	if off:
		# За кадром: направление берём в ПЛОСКОСТИ ЭКРАНА от центра и упираем в рамку.
		var dir: Vector2 = (p - vs * 0.5)
		if behind:
			var to: Vector3 = world - cam.global_position
			dir = Vector2((cam.global_transform.basis.x).dot(to), (cam.global_transform.basis.y).dot(to))
			dir.y = -dir.y                       # экранный Y растёт вниз
			dir = -dir if dir.length_squared() < 0.000001 else dir
		if dir.length_squared() < 0.000001:
			dir = Vector2.UP
		dir = dir.normalized()
		# Пересечение луча из центра с прямоугольником рамки.
		var half: Vector2 = r.size * 0.5
		var k: float = INF
		if absf(dir.x) > 0.0001:
			k = minf(k, half.x / absf(dir.x))
		if absf(dir.y) > 0.0001:
			k = minf(k, half.y / absf(dir.y))
		p = vs * 0.5 + dir * k
		_draw_arrow(p, dir)
	_draw_pin(p, off)

func _draw_pin(p: Vector2, off: bool) -> void:
	var pulse: float = 0.85 + 0.15 * sin(_t * 3.0)
	var rad: float = (13.0 if off else 15.0) * pulse
	draw_circle(p, rad + 3.0, Color(0, 0, 0, 0.5))
	draw_circle(p, rad, COL)
	var f: Font = ThemeDB.fallback_font
	var s := "?"
	var sz: float = rad * 1.5
	var w: Vector2 = f.get_string_size(s, HORIZONTAL_ALIGNMENT_LEFT, -1, int(sz))
	draw_string(f, p + Vector2(-w.x * 0.5, sz * 0.36), s, HORIZONTAL_ALIGNMENT_LEFT, -1,
			int(sz), Color(0.1, 0.09, 0.05))

# Остриё в сторону цели — по нему и понятно, куда поворачивать.
func _draw_arrow(p: Vector2, dir: Vector2) -> void:
	var n := Vector2(-dir.y, dir.x)
	var tip: Vector2 = p + dir * 26.0
	draw_colored_polygon(PackedVector2Array([tip, p + n * 9.0 + dir * 10.0,
			p - n * 9.0 + dir * 10.0]), COL)
