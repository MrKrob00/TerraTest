extends Area3D

## Горизонтальная скорость пули (ед/с). Была 50 → пуля просаживалась под цель ещё на
## боевой дистанции (~15 ед) и «недолетала». Быстрее = меньше времени в полёте = меньше просадка.
@export var speed: float = 120.0
## Падение пули по гравитации (ед/с²-ish). Меньше → траектория ровнее, бьёт дальше прямо.
@export var gravity: float = 50.0

var dir: Vector3 = Vector3.ZERO
var t: float = 0.0

func _physics_process(delta: float) -> void:
	if dir == Vector3.ZERO:
		t = 0.0
	else:
		t += delta
	global_position += dir * speed * delta
	global_position.y -= t * gravity * delta
