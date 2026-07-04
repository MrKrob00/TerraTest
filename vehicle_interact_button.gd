extends Area3D
# Кнопка взаимодействия НА чужой машине игрока (билборд, как была у магазина).
# Видна, когда эта машина не активна и активная машина игрока рядом. Удержание ~1с
# открывает круговое меню (hud.open_vehicle_menu): в инвентарь / разобрать / защита.
#
# Прогресс удержания «заливает» саму кнопку (цвет + рост), отдельного индикатора нет.
# Drag НЕ сбрасывает удержание: пока палец на экране (эмулированная кнопка мыши зажата),
# держим. Сброс — только реальное отпускание. Android long-press-as-right-click отключён
# в project.godot — он рвал касание на ~0.5с.

const SHOW_DISTANCE := 14.0     # м: дальше кнопку не видно и тапы игнорируются
const HOLD_TIME := 1.0          # с: сколько держать до открытия меню

const COL_IDLE := Color(0.55, 0.95, 1.0)
const COL_FULL := Color(1.0, 0.9, 0.25)

var vehicle: Node3D = null      # машина-владелец (ставит vehicle_body_3d при создании)

var _hold: float = 0.0
var _holding: bool = false
var _label: Label3D = null

func _ready() -> void:
	input_ray_pickable = true
	# Без physics_object_picking Area3D._input_event молчит (раньше это включал ShopMenu).
	get_viewport().physics_object_picking = true
	get_viewport().physics_object_picking_sort = true
	var shape := CollisionShape3D.new()
	var sph := SphereShape3D.new()
	sph.radius = 1.4
	shape.shape = sph
	add_child(shape)
	_label = Label3D.new()
	_label.text = "⚙"
	_label.font_size = 220
	_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_label.no_depth_test = true
	_label.modulate = COL_IDLE
	_label.outline_size = 24
	add_child(_label)

func _process(delta: float) -> void:
	# Показ: машина не под управлением игрока И активная машина рядом.
	var cc: Node = get_tree().get_first_node_in_group("camera_controller")
	if cc == null or vehicle == null or not ("current_vehicle" in cc):
		visible = false
		return
	var cur: Node3D = cc.current_vehicle
	var near: bool = cur != null and cur != vehicle \
			and cur.global_position.distance_to(global_position) <= SHOW_DISTANCE
	visible = near
	if not near:
		_cancel_hold()
		return
	if _holding:
		# Палец ещё на экране? Тач эмулирует левую кнопку мыши (стандарт Godot), так что
		# Input-состояние надёжно и при drag'е, и когда палец ушёл с самой кнопки.
		if not Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
			_cancel_hold()
			return
		_hold += delta
		var t: float = clampf(_hold / HOLD_TIME, 0.0, 1.0)
		_label.modulate = COL_IDLE.lerp(COL_FULL, t)   # кнопка «заливается»
		_label.scale = Vector3.ONE * (1.0 + 0.4 * t)   # и подрастает
		if _hold >= HOLD_TIME:
			_cancel_hold()
			var hud: Node = cc.get_node_or_null("HUD")
			if hud and hud.has_method("open_vehicle_menu"):
				hud.open_vehicle_menu(vehicle)

func _cancel_hold() -> void:
	_holding = false
	_hold = 0.0
	if _label:
		_label.modulate = COL_IDLE
		_label.scale = Vector3.ONE

func _input_event(camera: Camera3D, event: InputEvent, _pos: Vector3, _normal: Vector3, _shape: int) -> void:
	if not visible:
		return
	if camera and camera.global_position.distance_to(global_position) > SHOW_DISTANCE + 6.0:
		return
	var pressed: bool = (event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed) \
			or (event is InputEventScreenTouch and event.pressed)
	# Двойная доставка (тач + эмулированная мышь) не должна обнулять прогресс.
	if pressed and not _holding:
		_holding = true
		_hold = 0.0

func _input(event: InputEvent) -> void:
	# Реальное отпускание где угодно на экране — сброс (drag сюда не попадает).
	if _holding and ((event is InputEventScreenTouch and not event.pressed) \
			or (event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and not event.pressed)):
		_cancel_hold()
