extends Area3D

## Пуля летит по dir и падает по гравитации. Если ни во что не попала (Area body_entered)
## — раньше летела вечно. Теперь заканчивает полёт, уйдя НИЖЕ min_y по Y (за землю) или по
## потолку времени жизни, и сигналит expired — оружие возвращает её в пул (см. WeaponBlock).

signal expired(bullet)
## ПОПАДАНИЕ, НАЙДЕННОЕ ЛУЧОМ ПО ОТРЕЗКУ ПОЛЁТА. Оружие слушает его так же, как body_entered
## (WeaponBlock._rebind_bullet): аргументы те же — тело и сама пуля.
signal hit(body, bullet)

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

## ЧЬЯ ЭТО ПУЛЯ — узел blocks стрелявшей машины. Нужен свипу: луч по отрезку первым делом упирается
## в СОБСТВЕННЫЙ корпус (пуля рождается на дуле, внутри машины), и без этого каждый выстрел
## застревал бы в метре от ствола. Ставит WeaponBlock при выстреле.
var shooter_blocks: Node = null

## ПУЛЯ ЛЕТИТ БЫСТРЕЕ, ЧЕМ ТОЛЩИНА БЛОКА.
##
## Скорость 120 ед/с — это ДВА МЕТРА за физический кадр при 60 Гц и четыре при 30, а блок в этой
## игре ровно метр. Area3D замечает тело только если перекрывает его В МОМЕНТ ОПРОСА физики, то
## есть пуля штатно ПЕРЕШАГИВАЛА блок: броня не задерживала ничего, часть выстрелов не попадала
## никуда, а те, что попадали, попадали в то, что случайно оказалось в конце шага, — во внутренний
## блок за бронёй. Отсюда обе половины жалобы разом: «урон небольшой» и «машина живёт пять секунд».
## На телефоне с просадкой кадров это только хуже — шаг растёт вместе с delta.
##
## Поэтому за кадр проверяется ВЕСЬ ОТРЕЗОК от старой точки до новой, лучом по слою блоков. Area
## остаётся как была: она ловит медленные и упорные случаи (попадание в упор), а свип — быстрые.
## МАСКА СВИПА — СОБСТВЕННАЯ МАСКА ЭТОЙ AREA, а не своё число: Area у пули слушает не только
## блоки (слой 2), но и рельеф (1) и лежащие предметы (3). Свип обязан останавливать пулю ровно
## там же, где её остановила бы Area, иначе выстрел «пробивал» холм и попадал в блок за ним.
const SWEEP_SKIP := 0.05       # на сколько проскакиваем своё тело, чтобы не упереться в него же
const SWEEP_OWN_TRIES := 3     # столько раз подряд позволяем пропустить СВОЙ блок

func _physics_process(delta: float) -> void:
	var _pf := Perf.now()          # profiler mark (perf.gd)
	_tick_bullet(delta)
	Perf.mark("bullets", _pf)

func _tick_bullet(delta: float) -> void:
	if dir == Vector3.ZERO:          # в пуле — не двигаемся
		t = 0.0
		var mi0 := _mesh_node()      # вернулась в пул — снимаем растяжение (см. _stretch)
		if mi0 != null and _mesh_base != Vector3.ZERO and mi0.scale != _mesh_base:
			mi0.scale = _mesh_base
		return
	t += delta
	var from: Vector3 = global_position
	var to: Vector3 = from + dir * speed * delta
	to.y -= t * bullet_gravity * delta
	if _sweep(from, to):
		return                       # попали по дороге: оружие уже забрало пулю в пул
	global_position = to
	_face(to - from)
	_stretch(from.distance_to(to))
	if global_position.y < min_y or t > max_lifetime:
		dir = Vector3.ZERO           # стоп; оружие заберёт в пул по сигналу
		expired.emit(self)

## ПУЛЯ СМОТРИТ ТУДА, КУДА ЛЕТИТ — КАЖДЫЙ КАДР, А НЕ ТОЛЬКО В МОМЕНТ ВЫСТРЕЛА.
##
## Поворот ставился один раз, look_at'ом при выстреле (WeaponBlock.fire_bullet), и для прямого
## ствола этого хватало: траектория почти прямая, отклонение за полёт меньше толщины снаряда.
## Для НАВЕСА не хватает вовсе. Мортира бросает под 60°, снаряд проходит верхнюю точку и идёт
## ВНИЗ, а модель всё это время смотрит вверх — на падающем участке он летит хвостом вперёд.
## То же и у обычной пули на большой дистанции, только слабее.
##
## Направление берём ИЗ ШАГА, а не из dir: dir — это горизонтальная часть скорости, а
## вертикальную добавляет гравитация уже в _tick_bullet, и правильный ответ есть только в
## разнице точек. Почти вертикальный шаг пропускаем — на нём базис вырождается и look_at падает.
const FACE_MIN_STEP := 0.0001

func _face(step: Vector3) -> void:
	if step.length_squared() < FACE_MIN_STEP:
		return
	var fwd: Vector3 = step.normalized()
	var up: Vector3 = Vector3.UP if absf(fwd.y) < 0.99 else Vector3.FORWARD
	global_basis = Basis.looking_at(fwd, up)

## ПУЛЯ РАСТЯГИВАЕТСЯ НА СВОЙ ШАГ, И БЕЗ ЭТОГО ЕЁ НЕ ВИДНО. На 120 м/с и 30 кадрах снаряд
## проходит ЧЕТЫРЕ МЕТРА за кадр — точка успевает мелькнуть два раза и исчезнуть, что игрок и
## описал как «появились, улетели, пропали».
##
## Скорость трогать нельзя: от неё считается упреждение турели (_lead_point) и вся баллистика.
## Поэтому меняется только ВИД — меш вытягивается вдоль полёта ровно на пройденный за кадр
## отрезок, и соседние кадры складываются в непрерывную черту вместо пунктира из точек.
##
## Масштаб сбрасывается при возврате в пул (см. dir == ZERO в _tick_bullet): иначе вытянутая
## пуля ушла бы в пул и вылетела оттуда следующим выстрелом уже растянутой.
## ТЯНЕМ МЕШ, А НЕ ТЕЛО. Сначала масштабировался сам Area3D — и Jolt ругался каждый кадр полёта:
## неравномерный масштаб сферической формы он не поддерживает и молча заменяет его равномерным.
## То есть коллизия пули раздувалась, а в консоли шла ошибка на каждый кадр. Вид — дело меша,
## физика тут ни при чём.
const TRACE_MIN := 1.0           # короче собственной длины не сжимаем
const TRACE_MAX := 14.0          # и не превращаем в луч через полкарты
var _mesh_base: Vector3 = Vector3.ZERO      # масштаб, которым меш нормализован под длину модели
## КАКУЮ ОСЬ МЕША ТЯНЕМ. Масштаб живёт в ЛОКАЛЬНОЙ системе меша, а меш внутри пули бывает
## повёрнут: капсула растёт по Y, и её разворачивают на −90° по X, чтобы длина легла вдоль
## полёта. Жёсткое «тянем по Z» на такой пуле масштабировало РАДИУС — болт лазера не удлинялся,
## а раздувался, тем сильнее чем ниже кадры. Ось спрашиваем у самого меша, один раз.
var _stretch_axis: int = 2

## МЕШ ИЩЕТСЯ ОДИН РАЗ, А НЕ КАЖДЫЙ ТИК. Перебор детей стоял в `_stretch`, то есть выполнялся на
## каждом физ-тике каждой пули в воздухе. Замерено на движке, 200 пуль: 415 мкс за тик только на
## этот перебор — против 744 мкс на сам рейкаст, ради которого пуля и живёт.
## Дети у пули не меняются за её жизнь, так что кэш не может устареть.
var _mi_cache: MeshInstance3D = null

func _mesh_node() -> MeshInstance3D:
	if is_instance_valid(_mi_cache):
		return _mi_cache
	for c in get_children():
		var mi := c as MeshInstance3D
		if mi != null:
			_mi_cache = mi
			return mi
	return null

func _stretch(step: float) -> void:
	var mi := _mesh_node()
	if mi == null:
		return
	if _mesh_base == Vector3.ZERO:
		_mesh_base = mi.scale           # запоминаем однажды: дальше только домножаем
		# Пуля смотрит по −Z; какая ось МЕША на неё легла, спрашиваем у его же поворота.
		var local: Vector3 = (mi.transform.basis.orthonormalized().inverse() * Vector3.BACK).abs()
		_stretch_axis = 2
		if local.x > local.y and local.x > local.z:
			_stretch_axis = 0
		elif local.y > local.z:
			_stretch_axis = 1
	var k: float = clampf(step, TRACE_MIN, TRACE_MAX)
	var s: Vector3 = _mesh_base
	s[_stretch_axis] = _mesh_base[_stretch_axis] * k
	mi.scale = s

## Проверить отрезок полёта. true — попали (сигнал отправлен, пуля дальше не летит).
## ОБЪЕКТ ЗАПРОСА ЖИВЁТ С ПУЛЕЙ, А НЕ СОЗДАЁТСЯ НА КАЖДЫЙ ЛУЧ. `create()` — это выделение
## объекта, и оно стоит дороже самого луча: замерено на движке, 200 пуль за тик — 1224 мкс со
## свежим объектом против 744 мкс с переиспользованным. Половина строки «пули» в профиле уходила
## на аллокацию, а не на физику.
var _ray_q: PhysicsRayQueryParameters3D = null
## The surface normal at the last hit, from the same ray: a mark on the world (BlockFX.ground_hole)
## lies along the slope it was shot into.
var hit_normal: Vector3 = Vector3.UP

func _sweep(from: Vector3, to: Vector3) -> bool:
	var space := get_world_3d().direct_space_state
	if space == null:
		return false
	var start: Vector3 = from
	var step: Vector3 = to - from
	if step.length_squared() < 0.000001:
		return false
	var fwd: Vector3 = step.normalized()
	if _ray_q == null:
		_ray_q = PhysicsRayQueryParameters3D.new()
		_ray_q.collide_with_areas = false
	for _i in SWEEP_OWN_TRIES + 1:
		var q := _ray_q
		q.from = start
		q.to = to
		q.collision_mask = collision_mask
		var h := space.intersect_ray(q)
		if h.is_empty():
			return false
		var body = h.get("collider")
		# СВОИ БЛОКИ И СВОЙ КУПОЛ ПРОПУСКАЕМ И ИДЁМ ДАЛЬШЕ ПО ТОМУ ЖЕ ОТРЕЗКУ — ровно те же два
		# исключения, что и у обработчика попадания (WeaponBlock._on_bullet_body_entered).
		if body != null and shooter_blocks != null and body.get_parent() == shooter_blocks:
			start = (h["position"] as Vector3) + fwd * SWEEP_SKIP
			continue
		if body != null and G.is_friendly_dome(body, _shooter_root()):
			start = (h["position"] as Vector3) + fwd * SWEEP_SKIP
			continue
		global_position = h["position"]
		hit_normal = h.get("normal", Vector3.UP)
		hit.emit(body, self)
		return true
	return false

## Машина стрелявшего — по ней щит отличает своих. blocks лежит под самой машиной.
func _shooter_root() -> Node:
	return shooter_blocks.get_parent() if shooter_blocks != null else null
