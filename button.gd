extends Area3D
# Кликабельный билборд-триггер магазина (аналог Roblox ClickDetector).
# Тап по нему открывает экранное меню магазина (autoload ShopMenu).
#
# ВАЖНО: чтобы _input_event у Area3D вообще вызывался, на вьюпорте должен быть включён
# physics_object_picking — это делает ShopMenu в _ready(). Без него клики по 3D молчат.

## Тапы дальше этого расстояния (м) игнорируются — кнопку видно примерно настолько же.
@export var max_distance: float = 12.0

func _ready() -> void:
	input_ray_pickable = true

func _input_event(camera: Camera3D, event: InputEvent, _pos: Vector3, _normal: Vector3, _shape: int) -> void:
	var tapped := (event is InputEventMouseButton and event.pressed \
			and event.button_index == MOUSE_BUTTON_LEFT) \
		or (event is InputEventScreenTouch and event.pressed)
	if not tapped:
		return
	if camera and camera.global_position.distance_to(global_position) > max_distance:
		return
	# owner = корень инстанса магазина (Node3D со скриптом shop.gd); по нему меню узнаёт,
	# где спавнить блоки и чей это магазин.
	var shop: Node = owner if owner else get_parent()
	ShopMenu.open(shop)
