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
	var target_angle = deg_to_rad(steer_input * MAX_STEER_ANGLE)
	current_steer_angle = lerp(current_steer_angle, target_angle, STEER_SPEED * delta)

	if has_node("%wheel"):
		%wheel.rotation.y = current_steer_angle + deg_to_rad(90)
		if throttle_input!=0:
			%wheel.rotation.x += throttle_input * delta * 3.0

func get_module_data() -> Dictionary:
	var vehicle = get_parent().get_parent()
	var car_forward = vehicle.global_transform.basis.z

	var wheel_dir: Vector3
	if is_front:
		wheel_dir = car_forward.rotated(Vector3.UP, current_steer_angle)
	else:
		wheel_dir = car_forward

	var force = Vector3.ZERO
	if is_drive:
		force = wheel_dir * throttle_input * wheel_power

	return {
		"force": force,
		"weight": weight,
		"steer_angle": current_steer_angle
	}
