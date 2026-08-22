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

## РАДИУС колеса: на этой высоте над землёй держится его ось, то есть это и есть клиренс,
## который колесо даёт машине. У большой модели он больше — и кузов встаёт выше сам собой.
## Меряется от центра блока вниз; ставь по модели, иначе колесо будет висеть или тонуть.
@export var ride_height: float = 0.55
## Ход подвески: на столько колесо может уйти вверх (сжатие) и вниз (вывешивание) от оси.
@export var suspension_travel: float = 0.22

## Самый крутой склон, который подвеска ещё отрабатывает: 1/0.6 ≈ 53°. Дальше поправка на
## наклон росла бы к бесконечности (у отвесной стены нормаль вообще горизонтальна).
const SLOPE_MAX: float = 1.0 / 0.6

# Луч щупает на радиус + ход + запас, причём радиус берётся с запасом на наклон: на склоне
# до земли ПО ВЕРТИКАЛИ дальше, чем радиус колеса (см. probe_ground). Без этого запаса луч
# на косогоре не доставал до земли, и колесо считалось вывешенным прямо на склоне.
# Дальность луча — не то же, что «колесо на земле»: касание проверяется отдельно, по
# реальному расстоянию, иначе машина в прыжке получала бы тягу от висящих колёс.
func _probe_len() -> float:
	return ride_height * SLOPE_MAX + suspension_travel + 0.15

## Скорость вращения покрышки, рад/с на единицу газа.
const SPIN_SPEED: float = 3.0

var steer_input: float = 0.0
var throttle_input: float = 0.0
var current_steer_angle: float = 0.0
var grounded: bool = false
## Расстояние от центра блока до земли по лучу. INF — под колесом ничего нет.
var contact_distance: float = INF

# ── ЧАСТИ МОДЕЛИ ──────────────────────────────────────────────────────────────
# Модель колеса собрана ЦЕПОЧКОЙ, и в этом весь смысл: крепление → поворотный кулак →
# стойки → ось → покрышка. Каждая часть висит на предыдущей, поэтому двигать надо ровно
# одну, а остальное едет за ней само:
#
#   • Wheel_module — КРЕПЛЕНИЕ к соседнему блоку. Не двигается вообще: оно приколочено к
#     кузову, и разворачивать его при рулении значило возить точку крепления по машине.
#   • *susp_high* — ПОВОРОТНЫЙ КУЛАК: рулит вокруг своей Z (влево −Z, вправо +Z), и вместе
#     с ним поворачивается вся нога, включая покрышку.
#   • *axle* — ОСЬ: на ней отыгрывается ход подвески (кузов ходит вверх-вниз, колесо
#     остаётся на земле).
#   • %wheel — ПОКРЫШКА: катится вокруг своей X (вперёд +x, назад −x).
#
# Части ищем ПО ИМЕНИ и по всему поддереву: у трёх размеров колеса имена с суффиксами
# (_small/_medium/_big), а глубина вложенности одинаковая. У опорных колёс (top_wheel,
# stab_wheel) ни кулака, ни оси нет — там просто нечего рулить, а ход отыгрывает сама
# покрышка.
var _tyre: Node3D = null
var _tyre_rest: Basis = Basis()
var _spin: float = 0.0                 # накопленный угол качения покрышки
var _steer: Node3D = null              # поворотный кулак
var _steer_rest: Basis = Basis()
var _hub: Node3D = null                # ось (или сама покрышка, если оси нет)
var _hub_rest: Vector3 = Vector3.ZERO

func _ready() -> void:
	super._ready()
	_tyre = get_node_or_null("%wheel") as Node3D
	if _tyre == null:
		return
	_tyre_rest = _tyre.transform.basis
	_steer = _find_part("susp_high")
	if _steer != null:
		_steer_rest = _steer.transform.basis
	_hub = _find_part("axle")
	if _hub == null:
		_hub = _tyre                   # опорное колесо: ход отыгрывает сама покрышка
	_hub_rest = _hub.position

## Первая часть модели, в имени которой есть слово. Ищем по всему поддереву: цепочка
## вложена на несколько уровней, а имена у трёх размеров колеса отличаются суффиксом.
func _find_part(word: String) -> Node3D:
	for n in find_children("*", "Node3D", true, false):
		if (n as Node3D).name.to_lower().contains(word):
			return n as Node3D
	return null

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
## Насколько выше центра блока начинается луч. Колесо, уже въехавшее в склон, пускало луч
## ИЗНУТРИ рельефа — попаданий нет, подвеска считает колесо вывешенным и не толкает кузов
## вверх, машина проваливается ещё глубже. Со стартом выше поверхности такое колесо даёт
## ОТРИЦАТЕЛЬНОЕ расстояние до земли, и пружина выдавливает его обратно.
const PROBE_LIFT: float = 0.6

## Радиус, пересчитанный на наклон поверхности под колесом (см. probe_ground).
var _ride_effective: float = 0.0

func probe_ground(space: PhysicsDirectSpaceState3D, query: PhysicsRayQueryParameters3D) -> bool:
	query.from = global_position + Vector3.UP * PROBE_LIFT
	query.to = global_position + Vector3.DOWN * _probe_len()
	var hit: Dictionary = space.intersect_ray(query)
	if hit.is_empty():
		contact_distance = INF
		grounded = false
		_ride_effective = ride_height
	else:
		# Меряем ПО ВЕРТИКАЛИ от центра блока, а не длину луча: луч теперь стартует выше,
		# и его длина до земли — это уже не клиренс колеса.
		contact_distance = global_position.y - (hit["position"] as Vector3).y
		# Круглое колесо на склоне касается земли НЕ под самой осью: по вертикали от оси до
		# поверхности выходит радиус / cos(наклона), то есть больше радиуса. Сравнивая с
		# плоским радиусом, подвеска считала, что до земли ещё есть запас, и не толкала —
		# поэтому на ровном месте всё было нормально, а на любой возвышенности колесо
		# уезжало в грунт. Ограничение снизу — чтобы у стены (нормаль почти горизонтальна)
		# поправка не ушла в бесконечность.
		var n: Vector3 = hit["normal"] as Vector3
		_ride_effective = ride_height / clampf(n.dot(Vector3.UP), 1.0 / SLOPE_MAX, 1.0)
		# Луч намеренно длиннее, чем «колесо касается земли»: касание считаем по расстоянию,
		# иначе в прыжке машина получала бы тягу и сцепление от висящих в воздухе колёс.
		grounded = contact_distance <= _ride_effective + suspension_travel + 0.15
		if not grounded:
			contact_distance = INF
	return grounded

# Сжатие подвески В МЕТРАХ: насколько ось ближе к земле, чем радиус колеса. Отрицательное —
# колесо вывешено (машина подпрыгнула). Ограничено ходом в обе стороны.
func suspension_sag() -> float:
	if contact_distance == INF:
		return -suspension_travel
	return clampf(_ride_effective - contact_distance, -suspension_travel, suspension_travel)

func _physics_process(delta: float) -> void:
	var target_angle: float = deg_to_rad(steer_input * MAX_STEER_ANGLE)
	current_steer_angle = lerp(current_steer_angle, target_angle, STEER_SPEED * delta)

	_steer_wheel()
	_apply_suspension_visual()
	if throttle_input != 0.0 and _tyre != null:
		# Колесо крепится то через грань "left", то "right" (±90° по Y, см. _face_orient
		# в vehicle_body_3d.gd) — эти монтажи зеркальны, поэтому один и тот же локальный
		# спин катится визуально в РАЗНЫЕ мировые стороны слева/справа от машины.
		# Компенсируем знаком по стороне (X-позиция колеса от центра машины, см. _on_take_pressed:
		# position = Vector3(x-5, y-5, z-5) относительно $blocks — сетка 11³, центр 5).
		var side := -1.0 if position.x < 0.0 else 1.0
		# Покрышка катится вокруг СВОЕЙ оси X: вперёд +x, назад −x (так собрана модель).
		# Угол копим сами и умножаем базис справа, а не пишем rotation.x: у покрышки в сцене
		# запечён свой разворот, и присваивание одной эйлеровой компоненты его бы разрушило.
		_spin += side * throttle_input * delta * SPIN_SPEED
		_tyre.transform.basis = _tyre_rest * Basis(Vector3.RIGHT, _spin)

# РУЛИТ ПОВОРОТНЫЙ КУЛАК (*susp_high*), а не весь модуль. Модуль — это крепление к кузову,
# оно приколочено намертво; раньше при повороте руля уезжала вся стойка вместе с точкой
# крепления. Кулак стоит в цепочке выше оси и покрышки, поэтому поворачивается вся нога.
#
# Ось поворота — СВОЯ Z кулака: влево −Z, вправо +Z (так собрана модель). Знак минус потому,
# что положительный current_steer_angle — это поворот ВЛЕВО.
#
# Крутим от ЗАПОМНЕННОГО покоя и умножением справа: у детали свой запечённый разворот и
# неединичный масштаб, и присваивание rotation.z разрушило бы и то, и другое.
func _steer_wheel() -> void:
	if _steer == null or not is_instance_valid(_steer):
		return
	_steer.transform.basis = _steer_rest * Basis(Vector3.BACK, -current_steer_angle)

# Ход подвески ВИЗУАЛЬНО: кузов ходит вверх-вниз, а колесо обязано остаться на земле.
# Двигаем ОДНУ деталь — ось, — и всё, что на ней висит, едет само. Раньше на эту величину
# дёргался весь модуль вместе с креплением, и оно ездило внутрь кузова и наружу.
func _apply_suspension_visual() -> void:
	if _hub == null or not is_instance_valid(_hub):
		return
	var p := _hub.get_parent() as Node3D
	if p == null:
		return
	# Ход задан в МИРОВЫХ метрах, а класть его надо в оси родителя: в цепочке модели есть
	# неединичный масштаб, и прибавить sag прямо к локальной координате значило бы уехать
	# не на столько, сколько нужно.
	_hub.position = _hub_rest + p.global_transform.basis.inverse() * (Vector3.UP * suspension_sag())
