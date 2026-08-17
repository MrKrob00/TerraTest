extends VehicleBlock
class_name WeaponBlock

@export var damage: int = 5
## Дальность. Было 10 — втрое меньше, чем машина видит противника, поэтому убегающего было
## не достать в принципе. Отсюда же ИИ берёт свою боевую дистанцию
## (enemy_vehicle._own_weapon_range), так что короткий ствол заставлял и врага лезть вплотную.
## Дальность — с СЕТТЕРОМ намеренно: от неё зависят зона обнаружения турели и длина луча
## наводки, и держать их в синхроне вручную оказалось нельзя. Подклассы меняют дальность в
## своём _ready ПОСЛЕ super._ready(), то есть после того, как база уже синхронизировала
## сферу по старому значению; ракетница на этом и попалась — ствол на 18 м при зоне
## обнаружения 60, из-за чего она бросала цель под боком и лупила по машине за пятьдесят
## метров, куда всё равно не доставала. Теперь забыть пересинхронизировать невозможно.
@export var weapon_range: float = 60.0:
	set(v):
		weapon_range = v
		_sync_detect_radius()
		if raycast != null:
			raycast.target_position = Vector3(0, 0, -v)
@export var fire_rate: float = 0.2
@export var raycast: RayCast3D
@export var pivot: Node3D
@export var Area_Range: Area3D
# Сектор наведения башни. Был 45×30 — цель уходила из сектора от одного разворота корпуса,
# и башня бросала её, хотя ствол физически мог довернуть.
const YAW_LIMIT   = 75.0
const PITCH_LIMIT = 40.0

var _fire_timer: float = 0.0
## «Огонь» — это не защёлка, а таймер: attack() взводит его, и каждый кадр он гаснет.
## Пока стрелок (игрок держит Attack / ИИ в атаке) зовёт attack() каждый кадр — оружие
## стреляет; перестал звать → через FIRE_HOLD выключается. Так луч/трасер сами гаснут,
## когда атака закончилась (раньше для ИИ _firing залипал в true навсегда).
const FIRE_HOLD: float = 0.15
var _fire_hold: float = 0.0
var _anim_t: float = 0.0
var _targets: Array[Node3D] = []
var _current_target: Node3D = null
func _ready() -> void:
	super._ready()
	raycast.target_position = Vector3(0, 0, -weapon_range)
	_sync_detect_radius()
	# Шаблон-пулю перецепляем с bind (см. _rebind_bullet). Лазер свой Ammo дальше удалит.
	if has_node("Ammo/Bullet"):
		_rebind_bullet($Ammo/Bullet)

# ФИЗ-ТИК, а не кадр отрисовки: force_raycast_update() — это запрос к физическому серверу (луч
# наведения), а выстрел рождает физические тела (пули/ракеты). На кадре отрисовки такой запрос
# читает состояние физики в произвольной точке шага и лишний раз гоняет её на быстрых экранах;
# частота стрельбы тоже становилась зависимой от FPS. Наведение башни оставляем здесь же — физ-тик
# 60 Гц даёт ровное вращение и башня не отстаёт от тела, на котором стоит.
func _physics_process(delta: float) -> void:
	_fire_hold = maxf(_fire_hold - delta, 0.0)
	var firing := _fire_hold > 0.0
	if not firing:
		if _current_target != null:
			_current_target = null
		_track_target(delta, false)     # прячет луч и плавно возвращает башню в нейтраль
		return
	_update_current_target()
	_track_velocity(delta)          # ДО наводки: упреждение считается по свежей скорости
	raycast.force_raycast_update()
	_track_target(delta, true)
	_handle_fire(delta)

func attack() -> void:
	_fire_hold = FIRE_HOLD

# Радиус зоны, в которой турель ВИДИТ цели, = дальность оружия. В сценах он был прибит
# к 10 (у ракетницы 18) — то есть турель не бралась наводиться дальше десяти метров, сколько
# ни увеличивай weapon_range. Именно это, а не дальность, и означало «наводятся только вблизи».
# Форму дублируем: SubResource в сцене общий для всех её экземпляров.
func _sync_detect_radius() -> void:
	if Area_Range == null:
		return
	for c in Area_Range.get_children():
		if c is CollisionShape3D and (c as CollisionShape3D).shape is SphereShape3D:
			var sh: SphereShape3D = ((c as CollisionShape3D).shape as SphereShape3D).duplicate()
			sh.radius = weapon_range
			(c as CollisionShape3D).shape = sh

func _is_in_cone(body: Node3D) -> bool:
	var dir_world: Vector3 = (body.global_position - pivot.global_position).normalized()
	var dir_local: Vector3 = pivot.global_transform.basis.inverse() * dir_world
	var yaw: float = abs(rad_to_deg(atan2(-dir_local.x, -dir_local.z)))
	var pitch: float = abs(rad_to_deg(atan2(dir_local.y,
		Vector2(dir_local.x, dir_local.z).length())))
	return yaw <= YAW_LIMIT and pitch <= PITCH_LIMIT

# Выбор цели. Раньше брался просто БЛИЖАЙШИЙ блок — и орудия грызли то, что подвернулось:
# колесо с краю вместо кабины, обломок вместо турели, которая по тебе стреляет. Теперь
# кандидаты оцениваются, и вес каждого слагаемого объясним:
#
#   • НАЗНАЧЕННАЯ ИГРОКОМ цель (двойной тап по вражескому блоку) перевешивает всё
#     остальное — это прямой приказ, а не подсказка;
#   • блоки ТОЙ ЖЕ машины, что и назначенная цель, идут следом: приказ «бей вон того»
#     осмысленно продолжать по его же корпусу, когда указанный блок уже сбит;
#   • КАБИНА — условие победы: сбил её, и машина разваливается целиком;
#   • ОРУЖИЕ — то, что стреляет в ответ, гасить выгоднее прочего;
#   • ближе — лучше, но это лишь довесок, а не главный критерий;
#   • у ТЕКУЩЕЙ цели небольшая прибавка: без неё орудие дёргается между двумя почти
#     равными кандидатами и не добивает ни одного.
const SC_PRIORITY := 1000.0
const SC_PRIORITY_MACHINE := 400.0
const SC_CABIN := 120.0
const SC_WEAPON := 60.0
const SC_STICKY := 40.0
const SC_NEAR := 100.0        # множитель близости: чем дальше цель, тем меньше добавка

func _update_current_target() -> void:
	if _targets.is_empty():
		_current_target = null
		return
	var machine: Node = _vehicle_root()
	var prio: Node3D = null
	var prio_root: Node = null
	if machine != null and machine.has_method("priority_alive") and machine.priority_alive():
		prio = machine.priority_target
		prio_root = _root_machine_of(prio)

	var best: Node3D = null
	var best_score: float = -INF
	for t in _targets:
		if not is_instance_valid(t):
			continue
		var d: float = pivot.global_position.distance_to(t.global_position)
		var score: float = SC_NEAR * (1.0 - clampf(d / maxf(weapon_range, 1.0), 0.0, 1.0))
		if prio != null:
			if t == prio:
				score += SC_PRIORITY
			elif prio_root != null and _root_machine_of(t) == prio_root:
				score += SC_PRIORITY_MACHINE
		var bt = t.get("block")
		if bt != null:
			if int(bt) == G.Block.CABIN:
				score += SC_CABIN
			elif t is WeaponBlock:
				score += SC_WEAPON
		if t == _current_target:
			score += SC_STICKY
		if score > best_score:
			best_score = score
			best = t
	_current_target = best

# Корневая машина, которой принадлежит блок (у свободного блока в мире её нет).
func _root_machine_of(n: Node) -> Node:
	var p: Node = n
	while p != null:
		if p is MachineBody:
			return p
		p = p.get_parent()
	return null

func _track_target(delta: float, firing: bool) -> void:
	var track_visual := raycast.get_node_or_null("track_visual") as MeshInstance3D
	if track_visual == null:
		return
	var track_mat: Material = track_visual.get_active_material(0)

	# ── НЕ стреляем → луч полностью скрыт (ни цвета, ни геометрии) ────────────
	if not firing:
		if track_visual.visible:
			track_visual.visible = false
		pivot.rotation = lerp(pivot.rotation, Vector3.ZERO, 0.1)
		return

	# ── Стреляем → показываем и «оживляем» луч ───────────────────────────────
	track_visual.visible = true
	_anim_t += delta

	# Если в конусе есть цель — доворачиваем турель на неё, иначе плавно в нейтраль
	# (стрельба «в воздух» — луч всё равно бьёт прямо, видно что оружие работает).
	var has_target: bool = _current_target != null and is_instance_valid(_current_target) \
			and _is_in_cone(_current_target)
	if has_target:
		# Приоритет: незакрытая кабина → ближайший блок машины (см. _aim_point_for),
		# и УПРЕЖДЕНИЕ с поправкой на просадку (_lead_point) — иначе по убегающему мимо.
		var target_pos: Vector3 = _lead_point(_current_target, pivot.global_position)
		var dir_world: Vector3 = (target_pos - pivot.global_position).normalized()
		var dir_local: Vector3 = global_transform.basis.inverse() * dir_world
		var yaw: float = clampf(rad_to_deg(atan2(-dir_local.x, -dir_local.z)), -YAW_LIMIT, YAW_LIMIT)
		var pitch: float = clampf(rad_to_deg(atan2(dir_local.y, Vector2(dir_local.x, dir_local.z).length())), -PITCH_LIMIT, PITCH_LIMIT)
		pivot.rotation = lerp(pivot.rotation, Vector3(deg_to_rad(pitch), deg_to_rad(yaw), 0.0), 15.0 * delta)
	else:
		pivot.rotation = lerp(pivot.rotation, Vector3.ZERO, 8.0 * delta)

	# Длина луча: до точки попадания, иначе на всю дальность (бьёт в воздух).
	var hit := raycast.is_colliding()
	var length := weapon_range
	if hit:
		length = minf(raycast.global_position.distance_to(raycast.get_collision_point()), weapon_range)
	if track_visual.mesh is CylinderMesh:
		var cyl := track_visual.mesh as CylinderMesh
		if absf(cyl.height - length) > 0.05:
			cyl.height = length
		track_visual.position.z = -length * 0.5

	# Анимация «рабочего» луча: пульсация яркости. По цели — горячий (бело-красный), в
	# воздух — оранжево-красный поспокойнее. Луч материал unshaded, поэтому пульсируем
	# именно albedo (на unshaded виден он, а не emission); emission ставим заодно для
	# материалов с обычным шейдингом. Видно, что оружие именно СТРЕЛЯЕТ.
	var pulse := 0.7 + 0.3 * sin(_anim_t * 40.0)
	var base := Color(1.0, 0.85, 0.7) if hit else Color(1.0, 0.4, 0.1)
	raycast.debug_shape_custom_color = Color(1, 0, 0) if hit else Color(1, 0.5, 0)
	if track_mat is StandardMaterial3D:
		var m := track_mat as StandardMaterial3D
		m.albedo_color = base * pulse
		m.emission_enabled = true
		m.emission = base
		m.emission_energy_multiplier = (3.0 if hit else 1.5) * pulse

func _handle_fire(delta: float) -> void:
	var body: Node3D = raycast.get_collider()
	if body:
		if body == self or body.get_parent() == get_parent():
			return
	_fire_timer -= delta
	if _fire_timer > 0.0:
		return
	_fire_timer = fire_rate
	fire_bullet()

# Безопасно: у оружия без пуль (лазер) узла Ammo может не быть (или он удалён в _ready).
@onready var ammo: Node3D = get_node_or_null("Ammo")
@onready var free_bullet: Array[Area3D]

# Сценовое соединение Ammo/Bullet.body_entered → _on_bullet_body_entered БЕЗ bind давало
# нехватку аргумента (source) и роняло вызов на КАЖДОМ попадании. Перецепляем с bind(самой
# пули), чтобы source приходил корректно (нужен для возврата пули в пул).
func _rebind_bullet(b: Area3D) -> void:
	if b.body_entered.is_connected(_on_bullet_body_entered):
		b.body_entered.disconnect(_on_bullet_body_entered)
	var cb := _on_bullet_body_entered.bind(b)
	if not b.body_entered.is_connected(cb):
		b.body_entered.connect(cb)
	# Пуля улетела за окно коллизий (ушла ниже min_y / вышло время) → вернуть в пул.
	if b.has_signal("expired") and not b.expired.is_connected(_on_bullet_expired):
		b.expired.connect(_on_bullet_expired)

# Пуля отработала (попадание ИЛИ истечение полёта) — паркуем в пул инертной.
func _recycle_bullet(b: Area3D) -> void:
	if not is_instance_valid(b):
		return
	if "dir" in b:
		b.dir = Vector3.ZERO
	# _recycle_bullet зовётся ИЗ сигнала body_entered пули — прямая смена monitoring в этот момент
	# заблокирована движком (Area заблокирована на время in/out-сигнала). set_deferred применит её
	# в конце кадра. Без этого рецикл срывался: пуля оставалась monitoring=true у центра мира и
	# продолжала ловить тела/слать сигналы (спам и возможные каскадные падения).
	b.set_deferred("monitoring", false)         # в пуле (у центра) повторно не ловит тела
	b.global_position = Vector3.ZERO
	if not free_bullet.has(b):
		free_bullet.append(b)

func _on_bullet_expired(b: Area3D) -> void:
	_recycle_bullet(b)

func fire_bullet():
	if ammo == null:
		return
	if free_bullet.is_empty():
		var new_bullet: Area3D = $Ammo/Bullet.duplicate()
		ammo.add_child(new_bullet)
		_rebind_bullet(new_bullet)              # дубликат унаследовал сценовое соединение без bind
		free_bullet.append(new_bullet)
	var bullet:Area3D = free_bullet.pop_back()
	var dir: Vector3 = (-$Pivot.global_transform.basis.z).normalized()
	if not ("dir" in bullet):
		free_bullet.append(bullet)              # пуля без bullet.gd — вернуть в пул, не падать
		return
	# Дуло: у пушки это DrillBody2, у лазера такого узла нет — берём Marker3D как запасной,
	# иначе $Pivot/DrillBody2 = null и падало "global_position on null instance".
	var muzzle: Node3D = $Pivot.get_node_or_null("DrillBody2")
	if muzzle == null:
		muzzle = $Pivot/Marker3D
	bullet.global_position = muzzle.global_position
	bullet.dir = dir
	if absf(dir.dot(Vector3.UP)) < 0.99:        # look_at падает, если dir почти вертикальна
		bullet.look_at(bullet.global_position + dir)
	bullet.monitoring = true                    # в полёте ловит попадания

func _on_area_3d_body_entered(body: Node3D) -> void:
	if body == self or body.get_parent() == get_parent():
		return
	if body == _vehicle_root():
		return                        # своя машина — не цель
	if "owner_vehicle" in body and body.owner_vehicle == _vehicle_root():
		return                        # свой щит-купол — не цель
	if body.get_parent() != null and body.get_parent().name == "objects":
		return                        # свободные блоки/объекты в мире — не цели
	if not _targets.has(body):
		_targets.append(body)

# Корневое тело машины, на которой стоит это оружие.
func _vehicle_root() -> Node:
	var p := get_parent()
	while p != null and not (p is RigidBody3D):
		p = p.get_parent()
	return p

# ── Скорость цели ─────────────────────────────────────────────────────────────
# Скорость МЕРЯЕМ по смещению цели, а не спрашиваем у неё linear_velocity.
#
# Зона обнаружения оружия смотрит на слой БЛОКОВ (collision_mask = 2), поэтому цель — это
# блок вражеской машины, а не её корпус. Блок на машине не двигается собственной физикой,
# его возит родитель, и его linear_velocity равна нулю. Упреждение исправно считалось по
# нулевой скорости и вырождалось в «целься точно в цель» — то есть не работало вовсе.
# Замер смещения от этого не зависит: он одинаково верен и для блока, и для корпуса, и для
# чего угодно ещё, что мы решим сделать целью.
var _vel_ref: Node3D = null           # за кем меряем (сменилась цель — счётчик с нуля)
var _vel_last: Vector3 = Vector3.ZERO
var _target_vel: Vector3 = Vector3.ZERO

## Насколько сглаживаем замер. Разность за один физ-кадр шумит от тряски подвески, отдачи и
## качания блока на машине; без сглаживания ствол дёргался бы за этим шумом.
const VEL_SMOOTH: float = 0.25

func _track_velocity(delta: float) -> void:
	var t: Node3D = _current_target
	if t == null or not is_instance_valid(t):
		_vel_ref = null
		_target_vel = Vector3.ZERO
		return
	if t != _vel_ref:
		# Новая цель: первого замера ещё нет. Стартуем от скорости её МАШИНЫ, если она
		# известна, — иначе первые доли секунды стреляли бы без упреждения.
		_vel_ref = t
		_vel_last = t.global_position
		_target_vel = _machine_velocity(t)
		return
	if delta > 0.0:
		var raw: Vector3 = (t.global_position - _vel_last) / delta
		_target_vel = _target_vel.lerp(raw, VEL_SMOOTH)
	_vel_last = t.global_position

# Скорость машины, которой принадлежит блок: поднимаемся по дереву до первого RigidBody.
func _machine_velocity(node: Node3D) -> Vector3:
	var p: Node = node
	while p != null:
		if p is RigidBody3D and p != self:
			return (p as RigidBody3D).linear_velocity
		p = p.get_parent()
	return Vector3.ZERO

# ── Баллистика ────────────────────────────────────────────────────────────────
# Снаряд летит ПО ПРЯМОЙ со своей скоростью и одновременно проседает: за время t он
# уходит вниз на g·t²/2 (см. bullet.gd), а цель за то же время уезжает на v·t. Целиться
# в то место, где цель СЕЙЧАС, — значит гарантированно мазать по всему, что движется,
# и тем сильнее, чем дальше цель. Раньше делалось именно так.
#
# Точку встречи ищем итерацией: время полёта зависит от точки прицеливания, а точка — от
# времени. Три прохода сходятся с запасом.
func _lead_point(target: Node3D, from: Vector3) -> Vector3:
	var p: Vector3 = _aim_point_for(target)
	var v: Vector3 = _target_vel
	var bal: Vector2 = _ballistics()
	var t: float = from.distance_to(p) / bal.x
	var aim: Vector3 = p
	for _i in 3:
		aim = p + v * t + Vector3.UP * (0.5 * bal.y * t * t)
		t = from.distance_to(aim) / bal.x
	return aim

# Скорость и просадка берутся С САМОГО СНАРЯДА: у ракеты в сцене 42/6, у пушки 120/50.
# Зашей их сюда числом — прицел считал бы по одним, а летело бы по другим.
func _ballistics() -> Vector2:
	var b: Node = get_node_or_null("Ammo/Bullet")
	if b == null or not ("speed" in b):
		return Vector2(120.0, 50.0)
	return Vector2(maxf(float(b.get("speed")), 1.0), float(b.get("bullet_gravity")))

func _aim_point_for(body: Node3D) -> Vector3:
	var blocks := body.get_node_or_null("blocks")
	if blocks == null:
		if body is MeshInstance3D:
			return (body as MeshInstance3D).get_aabb().get_center() + body.global_position
		if body.has_node("CollisionShape3D"):
			return body.get_node("CollisionShape3D").global_position
		return body.global_position
	var cabin: Node3D = null
	for b in blocks.get_children():
		if b.get("block") == G.Block.CABIN and b is Node3D:
			cabin = b
			break
	if cabin != null and _cabin_exposed(body, cabin):
		return cabin.global_position
	var best: Node3D = null
	var bd := INF
	for b in blocks.get_children():
		if not ("block" in b) or not (b is Node3D):
			continue
		var d: float = pivot.global_position.distance_squared_to((b as Node3D).global_position)
		if d < bd:
			bd = d
			best = b
	return best.global_position if best != null else body.global_position

# Кабина «не закрыта» = луч от оружия до кабины первым делом попадает в саму машину
# рядом с кабиной (а не в другой её блок и не в постороннее препятствие).
func _cabin_exposed(body: Node3D, cabin: Node3D) -> bool:
	var space := get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(pivot.global_position, cabin.global_position)
	var own := _vehicle_root()
	q.exclude = [self, own] if own != null else [self]
	var res := space.intersect_ray(q)
	if res.is_empty():
		return true
	if res.collider != body:
		return false
	return res.position.distance_to(cabin.global_position) <= 0.9

## Сказать подстреленной машине, КТО в неё попал. Урон и осведомлённость разделены
## намеренно: hurt() зовут ещё бур по жиле, реген и цепная детонация блоков — у них стрелка
## нет вовсе, и совать его в подпись метода значило бы тащить null через полпроекта.
## Знает стрелявшего только оружие, здесь и говорим.
func _alert_victim(body: Node3D) -> void:
	var m: Node = body
	while m != null and not (m is MachineBody):
		m = m.get_parent()
	if m != null and m.has_method("notice_attacker"):
		m.notice_attacker(_vehicle_root() as Node3D)

func _on_area_3d_body_exited(body: Node3D) -> void:
	_targets.erase(body)

func _on_bullet_body_entered(body: Node3D, source: Area3D) -> void:
	if body == self: return
	if body.get_parent() == get_parent(): return
	# Свой щит-купол пропускает СВОИ пули (вылетают изнутри купола) — не поглощаем.
	if "owner_vehicle" in body and body.owner_vehicle == _vehicle_root(): return
	if body.has_method("hurt"):
		body.hurt(damage)
		_alert_victim(body)
	# Щит гасит снаряд «в воздухе», на самом куполе: без отметки попадание выглядело как
	# исчезновение пули из ниоткуда. Глюк рисуем по САМОЙ ПУЛЕ — её габарит крошечный,
	# поэтому и облако выходит мелким, ровно на точке гашения.
	if "owner_vehicle" in body and is_instance_valid(source):
		BlockFX.play(source, false, 0.28)
	_recycle_bullet(source)
