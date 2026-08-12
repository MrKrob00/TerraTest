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

# %wheel — это ПОКРЫШКА внутри модуля колеса; её родитель и есть модуль. Катим покрышку,
# рулим модулем. Ссылки берём один раз: has_node("%wheel") каждый физкадр — лишний поиск.
var _tyre: Node3D = null
var _module: Node3D = null
var _module_rest: Basis = Basis()
var _module_rest_pos: Vector3 = Vector3.ZERO

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
			_module_rest_pos = _module.position
			_collect_suspension()

# ── Разбор модуля колеса на части ─────────────────────────────────────────────
# Wheel_module — КРЕПЛЕНИЕ к соседнему блоку: оно приколочено к кузову и не двигается вообще.
# Остальное разбираем ПО ГЕОМЕТРИИ, а не по именам, потому что имена тут обманывают: в
# wheel.tscn «susp_mid» — это горизонтальный РЫЧАГ от крепления до самой оси колеса (его
# дальний конец в 0.11 м от неё), а «susp_high» и «susp_low» — вертикальные СТОЙКИ, на 95%
# стоящие вдоль вертикали. Считать их всех рычагами и качать вокруг опоры — вывернуть
# стойки набок.
#
# Оси модели тоже не угадываются: у модуля в сцене запечён разворот (вертикаль блока — это
# его локальное −Z), а у деталей вдобавок неединичный масштаб. Поэтому вертикаль берём
# пересчётом из пространства блока, а концы детали — из AABB её меша.
#
# Итог: ось с покрышкой идут на полный ход; рычаг ПОВОРАЧИВАЕТСЯ вокруг того конца, что
# дальше от колеса (он прикручен к креплению); стойка сжимается между неподвижным верхом и
# подвижным низом, поэтому проходит полхода.
const STRUT_COS: float = 0.7           # |cos| с вертикалью выше этого — деталь стоит, а не лежит
const STRUT_FACTOR: float = 0.5        # какую долю хода проходит стойка

var _riders: Array[Dictionary] = []    # едут вертикально: {node, rest, factor}
var _arms: Array[Dictionary] = []      # качаются вокруг опоры: {node, pivot, axis, len, basis, pos}
var _up_local: Vector3 = Vector3.UP    # вертикаль блока в системе координат модуля

func _collect_suspension() -> void:
	# Поворот руля вращает модуль ВОКРУГ этой же вертикали, значит на пересчёт она не влияет
	# и её достаточно взять один раз в покое.
	_up_local = (_module_rest.inverse() * Vector3.UP).normalized()
	var hub: Vector3 = _tyre.position          # центр колеса в системе координат модуля
	_riders.append({"node": _tyre, "rest": _tyre.position, "factor": 1.0})
	for ch in _module.get_children():
		var n3 := ch as Node3D
		if n3 == null or n3 == _tyre:
			continue
		var nm: String = n3.name.to_lower()
		# Ось держит колесо — идёт с ним целиком, без всякой геометрии.
		if nm.contains("axle"):
			_riders.append({"node": n3, "rest": n3.position, "factor": 1.0})
			continue
		# Всё остальное разбираем, только если это ЯВНО деталь подвески. У top_wheel и
		# stab_wheel рядом с покрышкой лежит wheelbody — целый корпус колеса, и растащить
		# его как рычаг значило бы разобрать модель.
		if not nm.contains("susp"):
			continue
		var g: Dictionary = _part_geometry(n3, hub)
		if g.is_empty():
			continue
		if absf((g["dir"] as Vector3).dot(_up_local)) > STRUT_COS:
			_riders.append({"node": n3, "rest": n3.position, "factor": STRUT_FACTOR})
		else:
			_arms.append(g)

# Концы детали берём из AABB её меша по самой длинной оси. ОПОРОЙ считаем тот конец, что
# дальше от колеса: он и прикручен к креплению, вокруг него деталь качается.
func _part_geometry(n3: Node3D, hub: Vector3) -> Dictionary:
	var vis := n3 as VisualInstance3D
	if vis == null:
		return {}
	var ab: AABB = vis.get_aabb()
	var ax: int = 0
	if ab.size.y > ab.size[ax]:
		ax = 1
	if ab.size.z > ab.size[ax]:
		ax = 2
	var e0: Vector3 = ab.get_center()
	var e1: Vector3 = e0
	e0[ax] = ab.position[ax]
	e1[ax] = ab.position[ax] + ab.size[ax]
	e0 = n3.transform * e0
	e1 = n3.transform * e1
	var pivot: Vector3 = e0 if e0.distance_to(hub) > e1.distance_to(hub) else e1
	var outer: Vector3 = e1 if pivot == e0 else e0
	var arm: Vector3 = outer - pivot
	if arm.length() < 0.05:
		return {}                          # деталь без выраженной длины — двигать нечего
	var axis: Vector3 = _up_local.cross(arm)
	if axis.length() < 0.001:
		axis = Vector3.RIGHT               # строго вертикальная деталь: уйдёт в стойки, ось не нужна
	return {"node": n3, "pivot": pivot, "axis": axis.normalized(), "len": arm.length(),
			"dir": arm.normalized(), "basis": n3.transform.basis, "pos": n3.position}

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

	_steer_module()
	_apply_suspension_visual()
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

# Ход подвески ВИЗУАЛЬНО: кузов ходит вверх-вниз, а колесо обязано остаться на земле.
# Раньше на эту величину дёргался ВЕСЬ модуль — вместе с креплением, которое приколочено к
# соседнему блоку: крепление ездило внутрь кузова и наружу. Теперь ходят только те части,
# что и должны ходить, а крепление стоит на месте.
func _apply_suspension_visual() -> void:
	if _module == null:
		return
	var sag: float = suspension_sag()
	# Колёса без разобранного модуля (top_wheel, stab_wheel — там внутри просто visual и
	# покрышка) двигаем по-старому целиком: лучше грубый ход, чем неподвижная подвеска.
	if _riders.size() <= 1 and _arms.is_empty():
		_module.position.y = _module_rest_pos.y + sag
		return
	var lift: Vector3 = _up_local * sag
	for r in _riders:
		(r["node"] as Node3D).position = (r["rest"] as Vector3) + lift * float(r["factor"])
	for a in _arms:
		# Дальний конец рычага обязан подняться ровно на sag, значит рычаг поворачивается
		# на asin(sag / плечо). Знак минус — потому что ось вращения построена как
		# «вертикаль × плечо»: положительный поворот вокруг неё опускает дальний конец.
		var theta: float = -asin(clampf(sag / float(a["len"]), -0.95, 0.95))
		var rot := Basis(a["axis"] as Vector3, theta)
		var node: Node3D = a["node"]
		var pivot: Vector3 = a["pivot"]
		node.transform.basis = rot * (a["basis"] as Basis)
		node.position = pivot + rot * ((a["pos"] as Vector3) - pivot)
