extends VehicleBlock
class_name Wheel

@export var is_front: bool = true
@export var is_drive: bool = true
@export var weight: float = 20.0
## Тяга одного колеса в ньютонах. Общая тяга машины = сумма по ведущим колёсам,
## КАСАЮЩИМСЯ земли, поэтому больше колёс — быстрее разгон, а больше блоков — медленнее.
## Величина откалибрована по реальной сборке: 296 кг на пяти колёсах дают ~68 м/с²,
## что близко к отклику до перехода на тяговую модель.
@export var wheel_power: float = 4000.0
@export var max_brake_force: float = 300.0

const MAX_STEER_ANGLE: float = 25.0
const STEER_SPEED: float = 6.0
# Длина луча проверки земли: полвысоты колеса плюс запас на неровности.
const GROUND_PROBE: float = 0.95

## Скорость вращения покрышки, рад/с на единицу газа.
const SPIN_SPEED: float = 3.0

var steer_input: float = 0.0
var throttle_input: float = 0.0
var current_steer_angle: float = 0.0
var grounded: bool = false

# %wheel — это ПОКРЫШКА внутри модуля колеса; её родитель и есть модуль. Катим покрышку,
# рулим модулем. Ссылки берём один раз: has_node("%wheel") каждый физкадр — лишний поиск.
var _tyre: Node3D = null
var _module: Node3D = null
var _module_rest: Basis = Basis()

func _ready() -> void:
	super._ready()
	_tyre = get_node_or_null("%wheel") as Node3D
	if _tyre != null:
		var p: Node = _tyre.get_parent()
		# Родитель — модуль, только если это не сам корень колеса: рулить корнем нельзя,
		# на нём висит коллизия.
		if p is Node3D and p != self:
			_module = p as Node3D
			_module_rest = _module.transform.basis

# Регистрация идёт по ВХОДУ В ДЕРЕВО, а не в _ready. Блок, который игрок ставит руками,
# сначала инстансится в держатель у камеры (take_block_into_hand), там у него отрабатывает
# _ready — и родитель в тот момент не "blocks". Потом блок переносится на машину через
# reparent, но _ready второй раз не вызывается, и колесо навсегда оставалось
# незарегистрированным: тяга машины не росла, сколько колёс ни ставь.
func _enter_tree() -> void:
	var machine: Node = _machine()
	if machine != null and machine.has_method("append_wheel"):
		machine.append_wheel(self)

func _exit_tree() -> void:
	var machine: Node = _machine()
	if machine != null and machine.has_method("erase_wheel"):
		machine.erase_wheel(self)

func _machine() -> Node:
	var p: Node = get_parent()
	if p == null or p.name != "blocks":
		return null
	return p.get_parent()

func get_weight() -> float:
	return weight

func set_throttle(value: float) -> void:
	throttle_input = value

func set_steer(value: float) -> void:
	# Иначе колесо, ставшее задним после перестройки, так и осталось бы вывернутым.
	steer_input = -value if is_front else 0.0

# Земля проверяется у КАЖДОГО колеса, а не одним лучом из центра машины: центр уезжает
# вверх вместе с постройкой, а колёса по определению остаются там, где контакт.
func probe_ground(space: PhysicsDirectSpaceState3D, query: PhysicsRayQueryParameters3D) -> bool:
	query.from = global_position
	query.to = global_position + Vector3.DOWN * GROUND_PROBE
	grounded = not space.intersect_ray(query).is_empty()
	return grounded

func _physics_process(delta: float) -> void:
	var target_angle: float = deg_to_rad(steer_input * MAX_STEER_ANGLE)
	current_steer_angle = lerp(current_steer_angle, target_angle, STEER_SPEED * delta)

	_steer_module()
	if throttle_input != 0.0 and _tyre != null:
		# Колесо крепится то через грань "left", то "right" (±90° по Y, см. _face_orient
		# в vehicle_body_3d.gd) — эти монтажи зеркальны, поэтому один и тот же локальный
		# спин катится визуально в РАЗНЫЕ мировые стороны слева/справа от машины.
		# Компенсируем знаком по стороне (X-позиция колеса от центра машины, см. _on_take_pressed:
		# position = Vector3(x-5, y-5, z-5) относительно $blocks — сетка 11³, центр 5).
		var side := -1.0 if position.x < 0.0 else 1.0
		_tyre.rotation.y += side * throttle_input * delta * SPIN_SPEED

# Рулим ВЕСЬ модуль колеса (шина + ось + подвеска), а не одну шину: иначе покрышка
# отворачивалась, а подвеска оставалась смотреть прямо.
#
# Поворачиваем от ЗАПОМНЕННОГО положения покоя вокруг вертикали РОДИТЕЛЯ, а не через
# rotation.y: у модуля в сцене запечён свой разворот (художник ориентировал модель), и
# присваивание одной эйлеровой компоненты его бы разрушило.
func _steer_module() -> void:
	if _module == null:
		return
	_module.transform.basis = _module_rest.rotated(Vector3.UP, current_steer_angle)
