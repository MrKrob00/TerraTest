extends VehicleBlock
class_name WeaponBlock


@export var damage: int = 5
@export var weapon_range: float = 10.0
@export var fire_rate: float = 0.2
@export var raycast: RayCast3D
@export var pivot: Node3D
@export var Area_Range: Area3D
const YAW_LIMIT   = 45.0
const PITCH_LIMIT = 30.0

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
	# Луч обновляем ТОЛЬКО когда стреляем: RayCast3D и так опрашивается физикой сам, а
	# force_raycast_update() — второй запрос к физ-серверу за тик. Раньше он шёл безусловно, т.е.
	# каждое простаивающее оружие (в т.ч. у всех врагов и припаркованных машин) держало лишние
	# 60 запросов/с. Цель тоже нужна только для наведения/огня.
	if not firing:
		if _current_target != null:
			_current_target = null
		_track_target(delta, false)     # прячет луч и плавно возвращает башню в нейтраль
		return
	_update_current_target()
	raycast.force_raycast_update()
	_track_target(delta, true)
	_handle_fire(delta)

func attack() -> void:
	_fire_hold = FIRE_HOLD

func _is_in_cone(body: Node3D) -> bool:
	var dir_world: Vector3 = (body.global_position - pivot.global_position).normalized()
	var dir_local: Vector3 = pivot.global_transform.basis.inverse() * dir_world
	var yaw: float = abs(rad_to_deg(atan2(-dir_local.x, -dir_local.z)))
	var pitch: float = abs(rad_to_deg(atan2(dir_local.y,
		Vector2(dir_local.x, dir_local.z).length())))
	return yaw <= YAW_LIMIT and pitch <= PITCH_LIMIT

func _update_current_target() -> void:
	#_targets = _targets.filter(func(t): return is_instance_valid(t) and _is_in_cone(t))

	if _targets.is_empty():
		_current_target = null
		return

	var closest: Node3D = null
	var closest_dist: float = INF
	for t in _targets:
		var d: float = pivot.global_position.distance_to(t.global_position)
		if d < closest_dist:
			closest_dist = d
			closest = t
	_current_target = closest

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
		# Приоритет: незакрытая кабина → ближайший блок машины (см. _aim_point_for).
		var target_pos: Vector3 = _aim_point_for(_current_target)
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
	# Запись height в PrimitiveMesh пересобирает вершинные буферы меша. Раньше это делалось
	# КАЖДЫЙ кадр стрельбы, даже когда длина не менялась. Пишем только при заметном изменении.
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
	if _current_target == null or not raycast.is_colliding():
		pass#return
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
	# Направление — FORWARD турели (её −Z), то же, что у прицельного raycast (target −Z).
	# Раньше брали pivot→Marker3D: если маркер стоял не строго на оси ствола, пуля летела
	# «не в ту сторону». Так — ровно куда целится турель.
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

# Точка прицеливания по цели-машине: если КАБИНА ничем не закрыта — приоритет ей,
# иначе ближайший к оружию блок машины. Для не-машин — как раньше (центр/коллизия).
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

func _on_area_3d_body_exited(body: Node3D) -> void:
	_targets.erase(body)



func _on_bullet_body_entered(body: Node3D, source: Area3D) -> void:
	if body == self: return
	if body.get_parent() == get_parent(): return
	# Свой щит-купол пропускает СВОИ пули (вылетают изнутри купола) — не поглощаем.
	if "owner_vehicle" in body and body.owner_vehicle == _vehicle_root(): return
	if body.has_method("hurt"):
		body.hurt(damage)
	_recycle_bullet(source)
