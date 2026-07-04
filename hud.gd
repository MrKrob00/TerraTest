extends CanvasLayer

# Игровой HUD. Помимо старой логики (FPS, переключение режимов, кнопки Take/TakeOff)
# здесь живёт ARK-mobile «прикол» — выезжающая боковая панель (drawer) у правого края:
# по тапу на ручку из-за края выезжает тёмно-бирюзовая панель с кнопками Инвентарь /
# Сменить технику. Экран в покое чистый, второстепенные кнопки спрятаны за край.

const TECH_UI := preload("res://tech_ui.tscn")

@onready var current_vehicle = $"..".current_vehicle

# ── ARK drawer ───────────────────────────────────────────────────────────────
const DRAWER_W: float = 250.0
const DRAWER_H_RATIO: float = 0.46
var _drawer: PanelContainer
var _handle: Button
var _drawer_open: bool = false
var _tech_ui: Control = null
var _vehicle_list: VBoxContainer            # список техники в drawer (перестраивается)
var _rotate_panel: PanelContainer           # кнопки поворота блока (видны в стройке)
var _game_controls: Array = []              # игровые кнопки/джойстики — прячем при инвентаре

func _ready() -> void:
	_build_ark_drawer()
	_build_rotate_panel()
	_build_anchor_button()
	_collect_game_controls()

# ── Кнопка якоря (фиксация машины к миру, как блок-якорь в TerraTech) ──────────
# Иконка рисуется нодами (AnchorIcon._draw): кольцо + шток + лапы, картинка сразу понятна.
class AnchorIcon extends Control:
	var active := false
	func _draw() -> void:
		var c := size * 0.5
		var col := Color(0.3, 1.0, 0.5) if active else Color(0.88, 0.96, 0.98)
		var lw := 3.0
		draw_arc(c + Vector2(0, -14), 5.0, 0.0, TAU, 16, col, lw)          # кольцо
		draw_line(c + Vector2(0, -9), c + Vector2(0, 14), col, lw)          # шток
		draw_line(c + Vector2(-9, -2), c + Vector2(9, -2), col, lw)         # перекладина
		draw_arc(c + Vector2(0, 2), 13.0, PI * 0.15, PI * 0.85, 14, col, lw)  # лапы
		draw_line(c + Vector2(-12.3, 8.0), c + Vector2(-9.0, 3.2), col, lw)   # зубец левый
		draw_line(c + Vector2(12.3, 8.0), c + Vector2(9.0, 3.2), col, lw)     # зубец правый

var _anchor_btn: Button = null
var _anchor_icon: AnchorIcon = null
func _build_anchor_button() -> void:
	var screen: Vector2 = get_viewport().get_visible_rect().size
	_anchor_btn = Button.new()
	_anchor_btn.tooltip_text = "Якорь: зафиксировать машину (ровно 0°)"
	_anchor_btn.custom_minimum_size = Vector2(64, 64)
	_anchor_btn.add_theme_stylebox_override("normal", _make_button_style(false))
	_anchor_btn.add_theme_stylebox_override("hover", _make_button_style(false))
	_anchor_btn.add_theme_stylebox_override("pressed", _make_button_style(true))
	_anchor_btn.position = Vector2(16, screen.y - 170)
	_anchor_btn.pressed.connect(_on_anchor_pressed)
	_anchor_icon = AnchorIcon.new()
	_anchor_icon.set_anchors_preset(Control.PRESET_FULL_RECT)
	_anchor_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_anchor_btn.add_child(_anchor_icon)
	add_child(_anchor_btn)

func _on_anchor_pressed() -> void:
	var v: Node = _menu_vehicle_or_current()
	if v and v.has_method("toggle_anchor"):
		_anchor_icon.active = v.toggle_anchor()
		_anchor_icon.queue_redraw()

func _menu_vehicle_or_current() -> Node:
	var cc: Node = $".."
	if cc and "current_vehicle" in cc:
		return cc.current_vehicle
	return current_vehicle

# ── Круговое меню чужой машины (открывает vehicle_interact_button) ─────────────
# Колесо в стиле chatwheel: тёмный донат, секторы с разделителями, иконка + подпись
# в каждом секторе, центральный круг с синим кольцом = мёртвая зона (отмена).
# Жестовое: появляется вокруг 2D-кнопки машины (палец ещё зажат), тянешь к сектору
# (он подсвечивается) и отпускаешь — срабатывает. Отпустил в центре — отмена.
const VMENU_OUTER := 175.0
const VMENU_INNER := 64.0
var _vmenu: Control = null
var _vmenu_center: Vector2 = Vector2.ZERO
var _vmenu_wheel: Control = null
var _vmenu_count: int = 0
var _vmenu_vehicle: Node = null

class RadialWheel extends Control:
	var items: Array = []        # [[иконка, подпись], ...]
	var hovered: int = -1
	var outer := 175.0
	var inner := 64.0

	func _ready() -> void:
		size = Vector2(outer, outer) * 2.0
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		var c := size * 0.5
		var n := items.size()
		for i in n:
			var ang := -PI / 2 + TAU * float(i) / float(n)
			var mid := c + Vector2(cos(ang), sin(ang)) * ((outer + inner) * 0.53)
			var icon := Label.new()
			icon.text = items[i][0]
			icon.add_theme_font_size_override("font_size", 30)
			icon.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			icon.size = Vector2(120, 36)
			icon.position = mid - Vector2(60, 32)
			icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
			add_child(icon)
			var txt := Label.new()
			txt.text = items[i][1]
			txt.add_theme_font_size_override("font_size", 14)
			txt.add_theme_color_override("font_color", Color(0.92, 0.96, 1.0))
			txt.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			txt.size = Vector2(140, 20)
			txt.position = mid + Vector2(-70, 8)
			txt.mouse_filter = Control.MOUSE_FILTER_IGNORE
			add_child(txt)
		var cancel := Label.new()
		cancel.text = "ОТМЕНА"
		cancel.add_theme_font_size_override("font_size", 15)
		cancel.add_theme_color_override("font_color", Color(0.85, 0.9, 0.96))
		cancel.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		cancel.size = Vector2(120, 20)
		cancel.position = c - Vector2(60, 10)
		cancel.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(cancel)

	func _draw() -> void:
		var c := size * 0.5
		var n := maxi(items.size(), 1)
		# донат-фон
		draw_circle(c, outer, Color(0.075, 0.095, 0.13, 0.93))
		# подсвеченный сектор (клин между inner и outer)
		if hovered >= 0:
			var a0 := -PI / 2 + TAU * (float(hovered) - 0.5) / float(n)
			var steps := 22
			var pts := PackedVector2Array()
			for s in steps + 1:
				var a := a0 + TAU / float(n) * float(s) / float(steps)
				pts.append(c + Vector2(cos(a), sin(a)) * outer)
			for s in steps + 1:
				var a := a0 + TAU / float(n) * float(steps - s) / float(steps)
				pts.append(c + Vector2(cos(a), sin(a)) * inner)
			draw_colored_polygon(pts, Color(0.18, 0.25, 0.34, 0.95))
		# разделители секторов
		for i in n:
			var ab := -PI / 2 + TAU * (float(i) - 0.5) / float(n)
			var dv := Vector2(cos(ab), sin(ab))
			draw_line(c + dv * inner, c + dv * outer, Color(1, 1, 1, 0.10), 2.0)
		# центральный круг + синее кольцо (мёртвая зона / отмена)
		draw_circle(c, inner, Color(0.05, 0.065, 0.095, 0.97))
		draw_arc(c, inner, 0, TAU, 64, Color(0.42, 0.58, 0.76, 0.9), 3.5)
		draw_arc(c, outer, 0, TAU, 64, Color(0, 0, 0, 0.35), 2.0)

func open_vehicle_menu(vehicle: Node, screen_pos: Vector2 = Vector2(-1, -1)) -> void:
	close_vehicle_menu()
	var screen: Vector2 = get_viewport().get_visible_rect().size
	# Центр колеса — где 2D-кнопка машины; прижимаем к экрану, чтобы не обрезалось.
	var center := screen * 0.5 if screen_pos.x < 0.0 else screen_pos
	center.x = clampf(center.x, VMENU_OUTER + 10.0, screen.x - VMENU_OUTER - 10.0)
	center.y = clampf(center.y, VMENU_OUTER + 10.0, screen.y - VMENU_OUTER - 10.0)
	_vmenu_center = center
	_vmenu_vehicle = vehicle
	_vmenu = Control.new()
	_vmenu.set_anchors_preset(Control.PRESET_FULL_RECT)
	_vmenu.mouse_filter = Control.MOUSE_FILTER_IGNORE   # ввод ловит hud._input, не UI
	add_child(_vmenu)
	var defense_on: bool = bool(vehicle.get("defense_mode"))
	var wheel := RadialWheel.new()
	wheel.outer = VMENU_OUTER
	wheel.inner = VMENU_INNER
	wheel.items = [
		["📦", "В инвентарь"],
		["🔧", "Разобрать"],
		["🛡", "Защита: ВЫКЛ" if defense_on else "Защита: ВКЛ"],
	]
	wheel.position = center - Vector2(VMENU_OUTER, VMENU_OUTER)
	_vmenu.add_child(wheel)
	_vmenu_wheel = wheel
	_vmenu_count = wheel.items.size()
	VehicleInteractButton.camera_block = true   # жест меню не должен крутить камеру

# Пока меню открыто — весь ввод сюда: движение подсвечивает сектор, отпускание выбирает.
func _input(event: InputEvent) -> void:
	if _vmenu == null:
		return
	var pos := Vector2.ZERO
	var is_motion := false
	var is_release := false
	if event is InputEventScreenDrag:
		pos = event.position; is_motion = true
	elif event is InputEventMouseMotion:
		pos = event.position; is_motion = true
	elif event is InputEventScreenTouch and not event.pressed:
		pos = event.position; is_release = true
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and not event.pressed:
		pos = event.position; is_release = true
	else:
		return
	var idx := _vmenu_pick(pos)
	if is_motion:
		if _vmenu_wheel and _vmenu_wheel.hovered != idx:
			_vmenu_wheel.hovered = idx
			_vmenu_wheel.queue_redraw()
		get_viewport().set_input_as_handled()
	elif is_release:
		var vehicle := _vmenu_vehicle
		close_vehicle_menu()
		if idx >= 0:
			_do_vmenu_action(idx, vehicle)
		get_viewport().set_input_as_handled()

# Какой пункт выбирает точка pos: -1 = мёртвая зона (отмена), иначе индекс по углу.
func _vmenu_pick(pos: Vector2) -> int:
	var v := pos - _vmenu_center
	if v.length() < VMENU_INNER:
		return -1
	var best := 0
	var best_d := INF
	for i in _vmenu_count:
		var ang := -PI / 2 + TAU * float(i) / float(_vmenu_count)
		var d: float = absf(angle_difference(v.angle(), ang))
		if d < best_d:
			best_d = d
			best = i
	return best

func _do_vmenu_action(idx: int, vehicle: Node) -> void:
	if vehicle == null or not is_instance_valid(vehicle):
		return
	match idx:
		0:
			if vehicle.has_method("send_to_inventory"):
				vehicle.send_to_inventory()
		1:
			if vehicle.has_method("disassemble"):
				vehicle.disassemble()
		2:
			if vehicle.has_method("set_defense"):
				vehicle.set_defense(not bool(vehicle.get("defense_mode")))

func close_vehicle_menu() -> void:
	if _vmenu != null and is_instance_valid(_vmenu):
		_vmenu.queue_free()
	_vmenu = null
	_vmenu_wheel = null
	_vmenu_vehicle = null
	VehicleInteractButton.camera_block = false

# ── Панель поворота блока (низ по центру, только в режиме стройки) ─────────────
# Сетка 2×2: верхний ряд — НАКЛОН влево/вправо (крен вокруг Z), нижний ряд —
# ПОВОРОТ влево/вправо (вокруг Y). Иконки рисуются нодами (RotIcon._draw):
# кубик-блок + дуга-стрелка, никаких текстур.

# Стрелка направления поверх 3D-кубика (сам кубик — настоящий 3D в SubViewport).
# kind: tilt_left / tilt_right — дуга над кубом (крен), yaw_left / yaw_right —
# сплюснутый эллипс вокруг куба (поворот в горизонтальной плоскости).
class RotIcon extends Control:
	var kind := "yaw_left"
	const COL := Color(0.95, 0.99, 1.0, 1)

	func _arrow(p: Vector2, dir: Vector2) -> void:
		var n := Vector2(-dir.y, dir.x)
		draw_colored_polygon(PackedVector2Array([
			p + dir * 8.0, p + n * 4.5, p - n * 4.5]), COL)

	func _draw() -> void:
		var c := size * 0.5
		var lw := 2.5
		var r := minf(size.x, size.y) * 0.5 - 6.0
		if kind.begins_with("tilt"):
			# дуга над кубом: слева-сверху-направо (экранная плоскость = крен)
			var a0 := -PI + 0.55
			var a1 := -0.55
			draw_arc(c, r, a0, a1, 20, COL, lw)
			if kind == "tilt_right":
				var p := c + Vector2(cos(a1), sin(a1)) * r
				_arrow(p, Vector2(-sin(a1), cos(a1)))
			else:
				var p := c + Vector2(cos(a0), sin(a0)) * r
				_arrow(p, Vector2(sin(a0), -cos(a0)))
		else:
			# сплюснутый эллипс = горизонтальная плоскость вокруг куба (вид сверху под 45°)
			var ec := c + Vector2(0, 7)
			draw_set_transform(ec, 0.0, Vector2(1.0, 0.45))
			draw_arc(Vector2.ZERO, r, 0.35, PI - 0.35, 20, COL, lw)
			draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
			# Стрелка на конце дуги, по касательной наружу: правый конец (a=0.35) —
			# против роста угла, левый (a=PI-0.35) — по росту.
			var a := 0.35 if kind == "yaw_right" else PI - 0.35
			var p := ec + Vector2(cos(a) * r, sin(a) * r * 0.45)
			var t := Vector2(-sin(a), cos(a) * 0.45).normalized()
			_arrow(p, -t if kind == "yaw_right" else t)

func _build_rotate_panel() -> void:
	var screen: Vector2 = get_viewport().get_visible_rect().size
	_rotate_panel = PanelContainer.new()
	_rotate_panel.add_theme_stylebox_override("panel", _make_panel_style())
	_rotate_panel.visible = false
	var pw: float = 180.0
	_rotate_panel.size = Vector2(pw, 140)
	_rotate_panel.position = Vector2(screen.x * 0.5 - pw * 0.5, screen.y - 180.0)
	add_child(_rotate_panel)
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 8)
	grid.add_theme_constant_override("v_separation", 8)
	_rotate_panel.add_child(grid)
	# верхний ряд — наклон (крен вокруг оси Z), нижний — поворот (вокруг Y)
	grid.add_child(_rot_btn("tilt_left",  "Наклон влево",   Vector3.BACK,  PI / 2))
	grid.add_child(_rot_btn("tilt_right", "Наклон вправо",  Vector3.BACK, -PI / 2))
	grid.add_child(_rot_btn("yaw_left",   "Поворот влево",  Vector3.UP,    PI / 2))
	grid.add_child(_rot_btn("yaw_right",  "Поворот вправо", Vector3.UP,   -PI / 2))

func _rot_btn(kind: String, tip: String, axis: Vector3, ang: float) -> Button:
	var b := Button.new()
	b.custom_minimum_size = Vector2(74, 62)
	b.tooltip_text = tip
	b.add_theme_stylebox_override("normal", _make_button_style(false))
	b.add_theme_stylebox_override("hover", _make_button_style(false))
	b.add_theme_stylebox_override("pressed", _make_button_style(true))
	b.add_child(_cube_view(kind))
	var ic := RotIcon.new()
	ic.kind = kind
	ic.set_anchors_preset(Control.PRESET_FULL_RECT)
	ic.mouse_filter = Control.MOUSE_FILTER_IGNORE
	b.add_child(ic)
	b.pressed.connect(func(): _rotate_block(axis, ang))
	return b

# Настоящий 3D-куб внутри кнопки: свой мини-мир в SubViewport, камера смотрит на куб
# СВЕРХУ под углом 45°. Ряд «наклон» показывает куб уже накренённым в сторону действия,
# ряд «поворот» — куб, довёрнутый по Y. Рендерится только пока панель видна (стройка),
# вьюпорт крошечный — по цене это ничто.
func _cube_view(kind: String) -> SubViewportContainer:
	var svc := SubViewportContainer.new()
	svc.stretch = true
	svc.set_anchors_preset(Control.PRESET_FULL_RECT)
	svc.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sv := SubViewport.new()
	sv.own_world_3d = true
	sv.transparent_bg = true
	sv.render_target_update_mode = SubViewport.UPDATE_WHEN_VISIBLE
	svc.add_child(sv)

	var cam := Camera3D.new()
	cam.fov = 40.0
	# 45° сверху: позиция по дуге (0, sin45, cos45)·d, наклон камеры -45° по X.
	var d := 3.2
	cam.transform = Transform3D(Basis(Vector3.RIGHT, -PI / 4), Vector3(0, d * sin(PI / 4), d * cos(PI / 4)))
	sv.add_child(cam)

	var light := DirectionalLight3D.new()
	light.rotation = Vector3(-0.9, -0.5, 0)
	sv.add_child(light)

	var box := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = Vector3.ONE
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.35, 0.72, 0.78)
	mat.roughness = 0.6
	mesh.material = mat
	box.mesh = mesh
	match kind:                      # куб показывает РЕЗУЛЬТАТ нажатия
		"tilt_left":  box.rotation = Vector3(0, 0,  0.4)
		"tilt_right": box.rotation = Vector3(0, 0, -0.4)
		"yaw_left":   box.rotation = Vector3(0,  0.5, 0)
		"yaw_right":  box.rotation = Vector3(0, -0.5, 0)
	sv.add_child(box)
	return svc

func _rotate_block(axis: Vector3, ang: float) -> void:
	var v: Node = current_vehicle
	var cc: Node = $".."
	if cc and "current_vehicle" in cc:
		v = cc.current_vehicle
	if v and v.has_method("rotate_build"):
		v.rotate_build(axis, ang)


func _process(_delta: float) -> void:
	$Label.text = str(int(Engine.get_frames_per_second())) + " FPS"


# ── Сборка выезжающей панели целиком в коде (тема — как у tech_ui) ─────────────
func _build_ark_drawer() -> void:
	var screen: Vector2 = get_viewport().get_visible_rect().size
	var dh: float = screen.y * DRAWER_H_RATIO
	var dy: float = (screen.y - dh) * 0.5

	# Панель: стартует за правым краем (x = screen.x), выезжает к screen.x - DRAWER_W.
	_drawer = PanelContainer.new()
	_drawer.add_theme_stylebox_override("panel", _make_panel_style())
	_drawer.size = Vector2(DRAWER_W, dh)
	_drawer.position = Vector2(screen.x, dy)
	add_child(_drawer)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 10)
	vb.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_drawer.add_child(vb)

	var title := Label.new()
	title.text = "МЕНЮ"
	title.add_theme_color_override("font_color", Color(0.55, 0.85, 0.9, 1))
	title.add_theme_font_size_override("font_size", 22)
	vb.add_child(title)

	vb.add_child(_make_drawer_button("Инвентарь", _toggle_inventory))

	var veh_label := Label.new()
	veh_label.text = "ТЕХНИКА"
	veh_label.add_theme_color_override("font_color", Color(0.55, 0.75, 0.8, 0.8))
	veh_label.add_theme_font_size_override("font_size", 14)
	vb.add_child(veh_label)

	# Список техники строится при каждом открытии drawer (машины известны только
	# после _ready камеры-контроллера, который вызывается позже HUD).
	_vehicle_list = VBoxContainer.new()
	_vehicle_list.add_theme_constant_override("separation", 6)
	vb.add_child(_vehicle_list)

	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vb.add_child(spacer)

	# Ручка-язычок у самого края — всегда видна, тянет панель наружу/внутрь.
	var handle := Button.new()
	handle.text = "<"
	handle.add_theme_font_size_override("font_size", 28)
	handle.add_theme_stylebox_override("normal", _make_handle_style(false))
	handle.add_theme_stylebox_override("pressed", _make_handle_style(true))
	handle.add_theme_stylebox_override("hover", _make_handle_style(false))
	handle.add_theme_color_override("font_color", Color(0.85, 0.95, 0.97, 1))
	handle.custom_minimum_size = Vector2(50, 72)
	handle.size = Vector2(50, 72)
	handle.position = Vector2(screen.x - 50, dy + dh * 0.5 - 36)
	handle.pressed.connect(_toggle_drawer)
	add_child(handle)
	_handle = handle


func _toggle_drawer() -> void:
	_set_drawer(not _drawer_open)

func _set_drawer(open: bool) -> void:
	_drawer_open = open
	if open:
		_rebuild_vehicle_list()
	var screen: Vector2 = get_viewport().get_visible_rect().size
	var target_x: float = (screen.x - DRAWER_W) if open else screen.x
	var handle_x: float = (screen.x - DRAWER_W - 50.0) if open else (screen.x - 50.0)
	var tw := create_tween().set_parallel(true)
	tw.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tw.tween_property(_drawer, "position:x", target_x, 0.22)
	if _handle:
		tw.tween_property(_handle, "position:x", handle_x, 0.22)
		_handle.text = ">" if open else "<"


# ── Действия панели ───────────────────────────────────────────────────────────
func _toggle_inventory() -> void:
	if _tech_ui == null:
		_tech_ui = TECH_UI.instantiate()
		_tech_ui.visible = false          # известное состояние до add_child (без вспышки)
		add_child(_tech_ui)
		# Один обработчик на открытие И закрытие (в т.ч. крестиком X и при взятии блока):
		# прячем/возвращаем игровые кнопки, чтобы они не светились сквозь инвентарь.
		_tech_ui.visibility_changed.connect(_on_tech_ui_visibility)
	_set_drawer(false)
	_tech_ui.visible = not _tech_ui.visible
	if _tech_ui.visible and _tech_ui.has_method("refresh"):
		_tech_ui.refresh()

func _on_tech_ui_visibility() -> void:
	# Инвентарь открыт → прячем игровой HUD; закрыт → возвращаем как было.
	var open: bool = _tech_ui != null and _tech_ui.visible
	_set_game_controls_hidden(open)
	# Уводим трекер квестов вниз, чтобы не перекрывал статистику и кнопку закрытия.
	for q in get_tree().get_nodes_in_group("quests"):
		if q.has_method("set_inventory_open"):
			q.set_inventory_open(open)

# ── Выбор техники (список в drawer) ───────────────────────────────────────────
func _player_vehicles() -> Array:
	var cc: Node = $".."
	if cc and "vehicles" in cc:
		return cc.vehicles
	return []

func _rebuild_vehicle_list() -> void:
	if _vehicle_list == null:
		return
	for c in _vehicle_list.get_children():
		c.queue_free()
	var cur: Node = current_vehicle
	var cc: Node = $".."
	if cc and "current_vehicle" in cc:
		cur = cc.current_vehicle
	var i := 0
	for v in _player_vehicles():
		if not is_instance_valid(v):
			continue
		i += 1
		var is_cur: bool = (v == cur)
		var label: String = ("● " if is_cur else "  ") + str(v.name)
		var btn := _make_drawer_button(label, _select_vehicle.bind(v))
		if is_cur:
			btn.add_theme_color_override("font_color", Color(1.0, 0.65, 0.2, 1))  # текущая — оранжевым
			btn.disabled = true
		_vehicle_list.add_child(btn)
	if i == 0:
		var empty := Label.new()
		empty.text = "нет техники"
		empty.modulate = Color(1, 1, 1, 0.5)
		_vehicle_list.add_child(empty)

func _select_vehicle(v: Node) -> void:
	var cc: Node = $".."
	if cc and cc.has_method("switch_to_vehicle") and is_instance_valid(v):
		cc.switch_to_vehicle(v)
		current_vehicle = cc.current_vehicle
	_rebuild_vehicle_list()        # обновляем подсветку текущей

# ── Прятать/возвращать игровой HUD под инвентарём ─────────────────────────────
func _collect_game_controls() -> void:
	_game_controls.clear()
	for n in ["Movement", "Building", "Take", "TakeOff", "Attack",
			"Joystick_movement", "Joystick_camera", "Label"]:
		var node: Node = get_node_or_null(n)
		if node:
			_game_controls.append(node)
	if _drawer:
		_game_controls.append(_drawer)
	if _handle:
		_game_controls.append(_handle)
	if _rotate_panel:
		_game_controls.append(_rotate_panel)
	if _anchor_btn:
		_game_controls.append(_anchor_btn)

func _set_game_controls_hidden(hidden: bool) -> void:
	for n in _game_controls:
		if is_instance_valid(n):
			n.visible = not hidden
	# При закрытии инвентаря возвращаем кнопки в правильный режим машины
	# (мог поменяться, если игрок взял блок в руку → стройка).
	if not hidden:
		_apply_mode_visibility()

func _apply_mode_visibility() -> void:
	var v: Node = current_vehicle
	var cc: Node = $".."
	if cc and "current_vehicle" in cc:
		v = cc.current_vehicle
	if v and "Building" in v and v.Building:
		_on_building_pressed()
	else:
		_on_movement_pressed()


# ── Стили (тёмно-бирюзовая палитра tech_ui) ───────────────────────────────────
func _make_panel_style() -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = Color(0.043, 0.122, 0.149, 0.95)
	s.border_color = Color(0.247, 0.6, 0.65, 0.5)
	s.set_border_width(SIDE_LEFT, 2)
	s.set_border_width(SIDE_TOP, 1)
	s.set_border_width(SIDE_BOTTOM, 1)
	s.corner_radius_top_left = 10
	s.corner_radius_bottom_left = 10
	s.content_margin_left = 14
	s.content_margin_right = 14
	s.content_margin_top = 12
	s.content_margin_bottom = 12
	return s

func _make_handle_style(pressed: bool) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = Color(0.247, 0.6, 0.65, 1) if pressed else Color(0.082, 0.235, 0.275, 0.95)
	s.border_color = Color(0.247, 0.6, 0.65, 0.6)
	s.set_border_width(SIDE_LEFT, 2)
	s.set_border_width(SIDE_TOP, 1)
	s.set_border_width(SIDE_BOTTOM, 1)
	s.corner_radius_top_left = 10
	s.corner_radius_bottom_left = 10
	return s

func _make_button_style(pressed: bool) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = Color(0.247, 0.6, 0.65, 1) if pressed else Color(0.082, 0.235, 0.275, 0.95)
	s.border_color = Color(0.247, 0.6, 0.65, 0.45)
	s.set_border_width_all(1)
	s.set_corner_radius_all(6)
	s.content_margin_left = 12
	s.content_margin_right = 12
	s.content_margin_top = 12
	s.content_margin_bottom = 12
	return s

func _make_drawer_button(label: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = label
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.add_theme_font_size_override("font_size", 18)
	b.add_theme_color_override("font_color", Color(0.88, 0.96, 0.98, 1))
	b.add_theme_stylebox_override("normal", _make_button_style(false))
	b.add_theme_stylebox_override("hover", _make_button_style(false))
	b.add_theme_stylebox_override("pressed", _make_button_style(true))
	b.pressed.connect(cb)
	return b


# ── Старая логика режимов/кнопок (визуал) ─────────────────────────────────────
func _on_movement_pressed() -> void:
	$Attack.visible = true
	$Take.visible = false
	$TakeOff.visible = false
	if _rotate_panel: _rotate_panel.visible = false
	%Joystick_movement.visible=true
	$Movement/Label.add_theme_color_override("font_color", Color.GREEN)
	$Building/Label.add_theme_color_override("font_color", Color.BLACK)


func _on_building_pressed() -> void:
	$Attack.visible =false
	$Take.visible = true
	$TakeOff.visible = true
	if _rotate_panel: _rotate_panel.visible = true
	%Joystick_movement.visible=false
	$Movement/Label.add_theme_color_override("font_color", Color.BLACK)
	$Building/Label.add_theme_color_override("font_color", Color.GREEN)


func _on_take_pressed() -> void:
	if current_vehicle.block_map_node.get_block(current_vehicle.BuildingBlock["x"],current_vehicle.BuildingBlock["y"],current_vehicle.BuildingBlock["z"])!=0:
		return #if no empty return
	$Take/Label.text = "Take"
	$TakeOff.visible = false
	if current_vehicle.block_body: #Take blocking
		$Take/Label.text = "Place"
		$TakeOff.visible = true



func _on_take_off_pressed() -> void:
	if current_vehicle.block_take:

		$HUD/Build/Label.text = "Take"
		$HUD/TakeOff.visible = false
