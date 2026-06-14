extends Area3D

var dir:Vector3 = Vector3.ZERO
# Called every frame. 'delta' is the elapsed time since the previous frame.
var t: float = 0.0
func _physics_process(delta: float) -> void:
	if dir==Vector3.ZERO: t = 0.0
	else: t +=delta
	global_position += dir*100.0*delta/2
	global_position.y -= t*98.0*delta/2
