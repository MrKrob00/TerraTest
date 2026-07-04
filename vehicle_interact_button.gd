extends Area3D
# Кнопка взаимодействия НА чужой машине игрока (билборд, как была у магазина).
# Видна, когда эта машина не активна и активная машина игрока рядом. Удержание ~1с
# открывает круговое меню (hud.open_vehicle_menu): в инвентарь / разобрать / защита.

const SHOW_DISTANCE := 14.0     # м: дальше кнопку не видно и тапы игнорируются
const HOLD_TIME := 1.0          # с: сколько держать до открытия меню

var vehicle: Node3D = null      # машина-владелец (ставит vehicle_body_3d при создании)

var _hold: float = 0.0
var _holding: bool = false
var _label: Label3D = null
var _ring: Label3D = null       # индикатор прогресса удержания

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
	_label.modulate = Color(0.55, 0.95, 1.0)
	_label.outline_size = 24
	add_child(_label)
	_ring = Label3D.new()
	_ring.font_size = 110
	_ring.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_ring.no_depth_test = true
	_ring.modulate = Color(1, 1, 0.6)
	_ring.position = Vector3(0, 0.9, 0)
	add_child(_ring)

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
		_holding = false
		_ring.text = ""
		return
	if _holding:
		_hold += delta
		_ring.text = "◔◑◕●"[mini(int(_hold / HOLD_TIME * 4.0), 3)]
		if _hold >= HOLD_TIME:
			_holding = false
			_ring.text = ""
			var hud: Node = cc.get_node_or_null("HUD")
			if hud and hud.has_method("open_vehicle_menu"):
				hud.open_vehicle_menu(vehicle)

func _input_event(camera: Camera3D, event: InputEvent, _pos: Vector3, _normal: Vector3, _shape: int) -> void:
	if not visible:
		return
	if camera and camera.global_position.distance_to(global_position) > SHOW_DISTANCE + 6.0:
		return
	var pressed: bool = (event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed) \
			or (event is InputEventScreenTouch and event.pressed)
	var released: bool = (event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and not event.pressed) \
			or (event is InputEventScreenTouch and not event.pressed)
	if pressed:
		_holding = true
		_hold = 0.0
	elif released:
		_holding = false
		_ring.text = ""

func _input(event: InputEvent) -> void:
	# Отпускание может случиться ВНЕ области кнопки — _input_event его не увидит.
	if _holding and ((event is InputEventScreenTouch and not event.pressed) \
			or (event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and not event.pressed)):
		_holding = false
		_ring.text = ""
