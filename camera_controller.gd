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
	add_to_group("camera_controller")   # чтобы UI (tech_ui) находил активную машину
	# Собираем только управляемую игроком технику (у неё есть take_block_into_hand),
	# чтобы враг (другой RigidBody3D в Vehicles) не попадал в список переключения.
	var vehicle_childs = $"..".get_children()
	for i in vehicle_childs:
		if i is RigidBody3D and i.has_method("take_block_into_hand"):
			if !vehicles.has(i):
				vehicles.append(i)

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


# Машина погибла (уничтожена кабина): убираем из списка, садимся в ближайшую живую,
# а если техники не осталось — спавним бесплатную стартовую и садимся в неё.
func on_vehicle_died(dead: Node) -> void:
	vehicles.erase(dead)
	# Умерла НЕ текущая машина — камеру не трогаем, только вычистили из списка.
	# Раньше камера пересаживалась при гибели ЛЮБОЙ машины игрока.
	if current_vehicle != dead:
		return
	var origin: Vector3 = (dead as Node3D).global_position if is_instance_valid(dead) else global_position
	current_vehicle = null            # чтобы switch_to_vehicle не дёргал умирающую
	var alive: Array = []
	for v in vehicles:
		if is_instance_valid(v) and v != dead:
			alive.append(v)
	if alive.is_empty():
		var starter = _spawn_starter_vehicle(origin)
		if starter:
			switch_to_vehicle(starter)
		return
	var best = alive[0]
	var best_d := INF
	for v in alive:
		var d: float = origin.distance_to((v as Node3D).global_position)
		if d < best_d:
			best_d = d
			best = v
	switch_to_vehicle(best)

func _spawn_starter_vehicle(pos: Vector3) -> Node:
	var scene: PackedScene = load("res://player_vehicle.tscn")
	if scene == null:
		push_error("camera_controller: нет player_vehicle.tscn для стартовой машины")
		return null
	var v: Node3D = scene.instantiate()
	get_parent().add_child(v)              # под Vehicles — карта даст стриминговую коллизию
	v.global_position = pos + Vector3(0, 3, 0)
	if not vehicles.has(v):
		vehicles.append(v)
	return v


func _on_raycast_body_entered(body: Node3D) -> void:
	if body.get_parent().name in "objects" and !current_vehicle.block_take:
		current_vehicle.ghost_block.global_position = body.global_position
		current_vehicle.block_body = body
