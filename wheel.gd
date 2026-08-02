extends VehicleBlock
class_name Wheel

@export var is_front: bool = true
@export var is_drive: bool = true
@export var weight: float = 20.0
@export var wheel_power: float = 500.0
@export var max_brake_force: float = 300.0

const MAX_STEER_ANGLE: float = 25.0
const STEER_SPEED: float = 6.0

var steer_input: float = 0.0
var throttle_input: float = 0.0
var current_steer_angle: float = 0.0

func _ready() -> void:
	super._ready()
	if get_parent().name == "blocks":
		get_parent().get_parent().append_wheel(self)

func set_throttle(value: float) -> void:
	throttle_input = value

func set_steer(value: float) -> void:
	if is_front:
		steer_input = -value

func _physics_process(delta: float) -> void:
	var target_angle: float = deg_to_rad(steer_input * MAX_STEER_ANGLE)
	current_steer_angle = lerp(current_steer_angle, target_angle, STEER_SPEED * delta)

	if has_node("%wheel"):
		%wheel.rotation.y = current_steer_angle + deg_to_rad(90)
		if throttle_input!=0:
			# Колесо крепится то через грань "left", то "right" (±90° по Y, см. _face_orient
			# в vehicle_body_3d.gd) — эти монтажи зеркальны, поэтому один и тот же локальный
			# спин катится визуально в РАЗНЫЕ мировые стороны слева/справа от машины.
			# Компенсируем знаком по стороне (X-позиция колеса от центра машины, см. _on_take_pressed:
			# position = Vector3(x-5, y-5, z-5) относительно $blocks — сетка 11³, центр 5).
			var side := -1.0 if position.x < 0.0 else 1.0
			%wheel.rotation.x += side * throttle_input * delta * 3.0

func get_module_data() -> Dictionary:
	var vehicle: Node3D = get_parent().get_parent()
	var car_forward: Vector3 = vehicle.global_transform.basis.z

	var wheel_dir: Vector3
	if is_front:
		wheel_dir = car_forward.rotated(Vector3.UP, current_steer_angle)
	else:
		wheel_dir = car_forward

	var force: Vector3 = Vector3.ZERO
	if is_drive:
		force = wheel_dir * throttle_input * wheel_power

	return {
		"force": force,
		"weight": weight,
		"steer_angle": current_steer_angle
	}
