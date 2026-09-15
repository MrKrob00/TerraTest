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
		return
	t += delta
	var from: Vector3 = global_position
	var to: Vector3 = from + dir * speed * delta
	to.y -= t * bullet_gravity * delta
	if _sweep(from, to):
		return                       # попали по дороге: оружие уже забрало пулю в пул
	global_position = to
	if global_position.y < min_y or t > max_lifetime:
		dir = Vector3.ZERO           # стоп; оружие заберёт в пул по сигналу
		expired.emit(self)

## Проверить отрезок полёта. true — попали (сигнал отправлен, пуля дальше не летит).
func _sweep(from: Vector3, to: Vector3) -> bool:
	var space := get_world_3d().direct_space_state
	if space == null:
		return false
	var start: Vector3 = from
	var step: Vector3 = to - from
	if step.length_squared() < 0.000001:
		return false
	var fwd: Vector3 = step.normalized()
	for _i in SWEEP_OWN_TRIES + 1:
		var q := PhysicsRayQueryParameters3D.create(start, to)
		q.collision_mask = collision_mask
		q.collide_with_areas = false
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
		hit.emit(body, self)
		return true
	return false

## Машина стрелявшего — по ней щит отличает своих. blocks лежит под самой машиной.
func _shooter_root() -> Node:
	return shooter_blocks.get_parent() if shooter_blocks != null else null
