extends Area3D

## Пуля летит по dir и падает по гравитации. Если ни во что не попала (Area body_entered)
## — раньше летела вечно. Теперь заканчивает полёт, уйдя НИЖЕ min_y по Y (за землю) или по
## потолку времени жизни, и сигналит expired — оружие возвращает её в пул (см. WeaponBlock).

signal expired(bullet)

## Горизонтальная скорость пули (ед/с). Была 50 → пуля просаживалась под цель ещё на
## боевой дистанции (~15 ед) и «недолетала». Быстрее = меньше времени в полёте = меньше просадка.
@export var speed: float = 120.0
## Падение пули по гравитации (ед/с²-ish). Меньше → траектория ровнее, бьёт дальше прямо.
@export var bullet_gravity: float = 50.0
## Ниже этой высоты по Y (мир) полёт заканчивается — пуля ушла за землю/за окно коллизий.
@export var min_y: float = 0.0
## Жёсткий потолок времени жизни (с) — страховка от «вечных» пуль (напр. строго горизонтальных).
@export var max_lifetime: float = 3.0

var dir: Vector3 = Vector3.ZERO
var t: float = 0.0

func _physics_process(delta: float) -> void:
	if dir == Vector3.ZERO:          # в пуле — не двигаемся
		t = 0.0
		return
	t += delta
	global_position += dir * speed * delta
	global_position.y -= t * bullet_gravity * delta
	if global_position.y < min_y or t > max_lifetime:
		dir = Vector3.ZERO           # стоп; оружие заберёт в пул по сигналу
		expired.emit(self)
