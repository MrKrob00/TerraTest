extends CanvasLayer

@onready var current_vehicle = $"..".current_vehicle


func _process(_delta: float) -> void:
	$Label.text = str(int(Engine.get_frames_per_second())) + " FPS"


func _on_movement_pressed() -> void:
	$Attack.visible = true
	$Take.visible = false
	$TakeOff.visible = false
	%Joystick_movement.visible=true
	$Movement/Label.add_theme_color_override("font_color", Color.GREEN)
	$Building/Label.add_theme_color_override("font_color", Color.BLACK)


func _on_building_pressed() -> void:
	$Attack.visible =false
	$Take.visible = true
	$TakeOff.visible = true
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
