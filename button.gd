extends Area3D

func _input_event(camera: Camera3D, event: InputEvent, event_position: Vector3, normal: Vector3, shape_idx: int) -> void:
	print(true)
	if event.is_action_pressed("Attack"):
		print("wow")
