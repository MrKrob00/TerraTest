# processor.gd
extends FactoryBlock

@export var process_time: float = 2.0  # секунд на переработку

var timer_visual: Timer

func _ready() -> void:
	super._ready()
	_set_processing_visual(false)

	timer_visual = Timer.new()
	timer_visual.wait_time = process_time/4
	timer_visual.autostart = false
	timer_visual.one_shot = true
	timer_visual.timeout.connect(_on_timer_visual_timeout)
	add_child(timer_visual)

func _on_item_received() -> void:
	_set_processing_visual(true)
	for i: int in 4:
		timer_visual.start()
		await timer_visual.timeout
	# Визуально — можно покрутить или поменять цвет пока идёт обработка

func _on_timer_visual_timeout() -> void:
	if !current_item: return 
	var item: Node3D = current_item
	var target: Vector3 = Vector3.ZERO
	if item.position == $item_slot.position: target = $item_slot2.position
	elif item.position == $item_slot2.position: 
		target = $item_slot3.position
		if current_item and current_item.has_method("upgrade"):
			current_item.upgrade()
	elif item.position == $item_slot3.position: target = $item_slot4.position
	elif item.position == $item_slot4.position: 
		_set_processing_visual(false)
		call_deferred("_try_push")
	
	var tween: Tween = create_tween()
	tween.tween_property(item, "position", target, 0.3)

func _set_processing_visual(active: bool) -> void:
	var mat: StandardMaterial3D = StandardMaterial3D.new()
	mat.albedo_color = Color.GREEN if active else Color.RED
	$MeshInstance3D.material_override = mat
	# Например мигание или вращение меша процессора
	# Переопределяй под свой визуал
	pass
