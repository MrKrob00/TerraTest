extends VehicleBlock
class_name Wheel

@export var is_front: bool = true
@export var is_drive: bool = true
@export var weight: float = 20.0
## ТЯГА одного колеса в ньютонах. Общая тяга машины = сумма по ведущим колёсам, КАСАЮЩИМСЯ
## земли, поэтому больше колёс — быстрее разгон, а больше блоков — медленнее.
##
## Число само по себе ничего не значит — значение имеет отношение тяги к массе. Ориентир задан
## в MachineBody: ACCEL_BRISK 25 м/с² — «едет бодро», ACCEL_CRAWL 10 — «ползёт». Числа в сценах
## подобраны так, чтобы СОРАЗМЕРНАЯ сборка попадала в 25-40, а не в семь g, как было при общих
## 4000 на каждое колесо.
@export var wheel_power: float = 2600.0
## СКОЛЬКО КИЛОГРАММОВ ЭТО КОЛЕСО ДЕРЖИТ. Главное число выбора колеса и единственная причина,
## по которой их несколько видов.
##
## Из него выводится жёсткость пружины (MachineBody._apply_suspension), и потому перегруз
## наказывает сам собой, без отдельного «штрафа за вес»: пружина рассчитана на свои килограммы,
## под большим весом просадка упирается в ход подвески, кузов садится на собственные коллайдеры
## и начинает ЧЕРТИТЬ ПО ЗЕМЛЕ. Дальше всё делает трение — большая сборка на мелких колёсах
## буксует, а не «едет чуть медленнее».
##
## Раньше жёсткость считалась от ФАКТИЧЕСКОЙ нагрузки, то есть подвеска подстраивалась под любой
## вес и держала что угодно: вид колеса не решал ничего, кроме клиренса.
@export var load_capacity: float = 190.0
@export var max_brake_force: float = 300.0

const MAX_STEER_ANGLE: float = 25.0
const STEER_SPEED: float = 6.0

## РАДИУС колеса: на этой высоте над землёй держится его ось, то есть это и есть клиренс,
## который колесо даёт машине. У большой модели он больше — и кузов встаёт выше сам собой.
## Меряется от центра блока вниз; ставь по модели, иначе колесо будет висеть или тонуть.
@export var ride_height: float = 0.55
## Ход подвески: на столько колесо может уйти вверх (сжатие) и вниз (вывешивание) от оси.
@export var suspension_travel: float = 0.22

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
	# ЩУП И КОЛЛАЙДЕР СТАВИМ ДО РАЗБОРА МОДЕЛИ. Ниже есть выход по отсутствию покрышки, и раньше
	# за ним оставалась только визуальная часть; теперь за ним осталась бы и опора на землю —
	# колесо без %wheel просто никогда не коснулось бы грунта.
	_measure_tyre()
	_fit_collider()
	_make_arm()
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

## ЗАДАНА ЛИ У КОЛЕСА ГЕОМЕТРИЯ. ride_height — это радиус шины плюс просадка рычага, то есть
## высота, на которой колесо держит ось; ноль означает «модель ещё не сделана», а не «колесо
## особенное». Такое колесо не считается в паспорте гаража (rated_power, load_capacity) и не
## получает пружину — иначе витрина обещала бы ньютоны и килограммы от заготовки.
##
## СТАБИЛИЗИРУЮЩЕЕ и ВЕРХНЕЕ — ОБЫЧНЫЕ КОЛЁСА, отличаются только тем, какой гранью встают:
##   • ВЕРХНЕЕ (терратековский Riser Wheel) — колесо НА ВЫНОСНОЙ СТОЙКЕ, и крепится оно ВЕРХНЕЙ
##     гранью: висит под тем блоком, к которому прикручено, а не сбоку от корпуса. Смысл стойки —
##     подпереть тяжёлую машину лишней точкой опоры и ПОДНЯТЬ её, чтобы не цеплялась днищем.
##     В нашей модели это ровно load_capacity плюс большой ride_height: стойка на то и стойка,
##     чтобы ось стояла ниже места крепления. Значит у готового блока ride_height обязан быть
##     БОЛЬШЕ, чем у обычного колеса, а connect_faces — FACE_TOP (16), а не FACE_BACK;
##   • СТАБИЛИЗИРУЮЩЕЕ встаёт на ЗАДНЮЮ (или переднюю) грань и смотрит ВПЕРЁД, а не вбок, как
##     все остальные. Это третья точка опоры у несбалансированной сборки: задирающийся зад
##     раньше подпирали блоком, а блок цепляется за грунт и тормозит — колесо катится.
## Обе модели ещё не готовы, поэтому трансмиссия и посадка у них ОТЛОЖЕНЫ: числа тяги и веса
## взяты от обычного колеса, геометрия и грань крепления появятся вместе с моделью.
func geometry_ready() -> bool:
	return ride_height > 0.0

func set_throttle(value: float) -> void:
	throttle_input = value

func set_steer(value: float) -> void:
	# Иначе колесо, ставшее задним после перестройки, так и осталось бы вывернутым.
	steer_input = -value if is_front else 0.0

# Земля проверяется у КАЖДОГО колеса, а не одним лучом из центра машины: центр уезжает
# вверх вместе с постройкой, а колёса по определению остаются там, где контакт.
## ЩУП ЗЕМЛИ — SpringArm3D, И ОН НА КОРНЕ БЛОКА. В цепочку модели его вешать нельзя: там у
## каждого узла запечён свой масштаб, и рука кастила бы в масштабированном пространстве.
##
## Каст ФОРМОЙ, а не лучом. Круглое колесо на склоне касается земли не под осью, и одиночный луч
## про это врал — раньше враньё правили делением радиуса на cos наклона (SLOPE_MAX). Сфера
## радиусом шины встаёт туда же, куда встало бы колесо, и поправка не нужна вовсе.
var _arm: SpringArm3D = null
var _tyre_r: float = 0.5

## РАДИУС ШИНЫ МЕРЯЕТСЯ ПО МОДЕЛИ, а не задаётся числом: иначе это третья константа про один и
## тот же размер (после меша и коллайдера), и они разъедутся.
##
## Отсюда же раскладывается ride_height: это радиус шины ПЛЮС вынос рычага, и полблока (0.5) в
## нём сидит потому, что у средней шины радиус как раз полметра. Делить ride_height пропорцией
## размера шины нельзя — делится и вынос, которому до шины дела нет.
func _measure_tyre() -> void:
	if _tyre == null or not (_tyre is MeshInstance3D):
		return
	var m: Mesh = (_tyre as MeshInstance3D).mesh
	if m == null:
		return
	var t := Transform3D.IDENTITY
	var n: Node3D = _tyre
	while n != null and n != self:
		t = n.transform * t
		n = n.get_parent() as Node3D
	var box: AABB = t * m.get_aabb()
	_tyre_r = maxf(box.size.y * 0.5, 0.05)

## Коллайдер блока — ЭТО КОЛЕСО, а не клетка сетки. Кубом в полный блок он давал малому колесу
## габарит втрое больше его самого: мишень для пуль не по модели и брюхо, которое чертит раньше
## шины. Ставим коробку по шине и опускаем её на вынос рычага — туда, где колесо и находится.
## Форму ДУБЛИРУЕМ: сцена одна на все экземпляры, и правка на месте поехала бы по всем сразу.
func _fit_collider() -> void:
	var cs := get_node_or_null("CollisionShape3D") as CollisionShape3D
	if cs == null or not (cs.shape is BoxShape3D):
		return
	var box: BoxShape3D = (cs.shape as BoxShape3D).duplicate()
	box.size = Vector3(_tyre_r * 2.0, _tyre_r * 2.0, _tyre_r * 2.0)
	cs.shape = box
	cs.position = Vector3(0.0, -(ride_height - _tyre_r), 0.0)

func _make_arm() -> void:
	_arm = SpringArm3D.new()
	add_child(_arm)
	_arm.rotation = Vector3(-PI * 0.5, 0.0, 0.0)     # своим -Z рука смотрит вниз
	_arm.collision_mask = 1                          # только мир: свои блоки щупать незачем
	_arm.margin = 0.0
	var sph := SphereShape3D.new()
	sph.radius = _tyre_r
	_arm.shape = sph
	# Докуда рука вообще тянется: центр сферы может опуститься на ход подвески ниже посадки,
	# и это ровно ride_height + ход, минус радиус — потому что меряем до ЦЕНТРА сферы.
	_arm.spring_length = maxf(ride_height + suspension_travel - _tyre_r, 0.05)

func probe_ground(_space: PhysicsDirectSpaceState3D, _query: PhysicsRayQueryParameters3D) -> bool:
	if _arm == null or not is_instance_valid(_arm):
		grounded = false
		contact_distance = INF
		return false
	var l: float = _arm.get_hit_length()
	# Рука отдаёт длину до ЦЕНТРА сферы; до земли ещё радиус. Упёрлась в самый конец хода —
	# значит не нашла ничего: висим.
	if l >= _arm.spring_length - 0.001:
		contact_distance = INF
		grounded = false
	else:
		contact_distance = l + _tyre_r
		grounded = true
	return grounded

# Сжатие подвески В МЕТРАХ: насколько ось ближе к земле, чем посадка колеса. Отрицательное —
# колесо вывешено. Поправки на наклон тут больше нет: её делает сама форма каста.
func suspension_sag() -> float:
	if contact_distance == INF:
		return -suspension_travel
	return clampf(ride_height - contact_distance, -suspension_travel, suspension_travel)

func _physics_process(delta: float) -> void:
	var _pf := Perf.now()          # profiler mark (perf.gd)
	_tick_wheel(delta)
	Perf.mark("wheels", _pf)

func _tick_wheel(delta: float) -> void:
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
