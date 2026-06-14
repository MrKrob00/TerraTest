# belt.gd
extends FactoryBlock

@export var belt_speed: float = 1.0

var timer: Timer

func _ready() -> void:
	super._ready()
	timer = Timer.new()
	timer.wait_time = belt_speed
	timer.autostart = false
	timer.one_shot = true
	timer.timeout.connect(_on_timer_timeout)
	add_child(timer)

func _on_item_received() -> void:
	timer.stop()
	timer.start()

func _on_timer_timeout() -> void:
	_try_push()
	# trying again 
	if current_item != null:
		timer.wait_time = 0.1
		timer.start()
	else:
		timer.wait_time = belt_speed
