extends Node3D

@export var current_vehicle: RigidBody3D # Ссылка на активную машину
@export var lerp_speed: float = 10.0 # Скорость следования камеры

var vehicles: Array

@onready var camera = $SpringArm3D/Camera3D
@onready var Spring = $SpringArm3D
@onready var hud = $HUD
@onready var joystick_move = $HUD/Joystick_movement
@onready var joystick_cam = $HUD/Joystick_camera

@export var RADIUS: float = 8.0
@export var CAM_HEIGHT: float = 4.0
@export var ROT_SPEED: float = 1.5

var angle: float = 0.0
var is_active: bool = false

func _ready():
	
	var vehicle_childs = $"..".get_children()
	for i in vehicle_childs:
		if i is RigidBody3D:
			if !vehicles.has(i): 
				vehicles.append(i)
				if vehicles.size()>1:
					var Machine_duplicate= $"HUD/TabContainer/Machine 1".duplicate()
					Machine_duplicate.name = "Machine "+ str(vehicles.size())
					$HUD/TabContainer.add_child(Machine_duplicate)
	
	# Если машина не задана, попробуем найти первую в списке Vehicles
	if not current_vehicle:
		switch_to_vehicle(vehicles[0])
	else: 
		if current_vehicle.has_method("set_active"):
			current_vehicle.set_active(true)

func _process(delta):
	if not current_vehicle: return

	# 1. Smoothly move the entire controller to the car's 
	var target_pos = current_vehicle.global_position
	
	global_position = global_position.lerp(target_pos, delta * lerp_speed)


	camera_movement(delta)

var locked_angle: float = 0.0
var is_locked: bool = false

func camera_movement(delta):
	var dir = (-$"HUD/Joystick_camera".get_joystick_dir().x)
	
	if abs(dir) > 0.05:
		angle += dir * ROT_SPEED * delta
		is_locked = false
		locked_angle = angle - current_vehicle.global_rotation.y
	else:
		if not is_locked:
			locked_angle = angle - current_vehicle.global_rotation.y
			is_locked = true
		angle = current_vehicle.global_rotation.y + locked_angle
	
	var x = RADIUS * sin(angle)
	var z = RADIUS * cos(angle)
	#camera.position = Vector3(x, CAM_HEIGHT, z)
	Spring.spring_length = Vector3.ZERO.distance_to(Vector3(x, CAM_HEIGHT, z))
	Spring.look_at_from_position(current_vehicle.global_position+(Vector3(x, CAM_HEIGHT, z)*0.01),current_vehicle.global_position)
	Spring.rotation.x += current_vehicle.rotation.x

# Machine change function 
func switch_to_vehicle(new_vehicle: RigidBody3D):
	if current_vehicle and current_vehicle.has_method("set_active"):
		current_vehicle._on_take_off_pressed()
		current_vehicle.set_active(false)
	
	current_vehicle = new_vehicle
	
	if current_vehicle.has_method("set_active"):
		current_vehicle.set_active(true)


func _on_raycast_body_entered(body: Node3D) -> void:
	if body.get_parent().name in "objects" and !current_vehicle.block_take:
		current_vehicle.ghost_block.global_position = body.global_position
		current_vehicle.block_body = body


func _on_switch_pressed() -> void:
	switch_to_vehicle(vehicles[$HUD/TabContainer.current_tab])
