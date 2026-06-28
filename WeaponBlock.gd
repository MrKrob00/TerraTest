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


func _process(delta: float) -> void:
	_update_current_target()
	raycast.force_raycast_update()
	_fire_hold = maxf(_fire_hold - delta, 0.0)
	var firing := _fire_hold > 0.0
	_track_target(delta, firing)
	if firing:
		_handle_fire(delta)

func attack() -> void:
	_fire_hold = FIRE_HOLD

func _is_in_cone(body: Node3D) -> bool:
	var dir_world = (body.global_position - pivot.global_position).normalized()
	var dir_local = pivot.global_transform.basis.inverse() * dir_world
	var yaw   = abs(rad_to_deg(atan2(-dir_local.x, -dir_local.z)))
	var pitch = abs(rad_to_deg(atan2(dir_local.y,
		Vector2(dir_local.x, dir_local.z).length())))
	return yaw <= YAW_LIMIT and pitch <= PITCH_LIMIT

func _update_current_target() -> void:
	#_targets = _targets.filter(func(t): return is_instance_valid(t) and _is_in_cone(t))

	if _targets.is_empty():
		_current_target = null
		return

	var closest: Node3D = null
	var closest_dist = INF
	for t in _targets:
		var d = pivot.global_position.distance_to(t.global_position)
		if d < closest_dist:
			closest_dist = d
			closest = t
	_current_target = closest

func _track_target(delta: float, firing: bool) -> void:
	var track_visual := raycast.get_node_or_null("track_visual") as MeshInstance3D
	if track_visual == null:
		return
	var track_mat = track_visual.get_active_material(0)

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
		var target_pos = _current_target.global_position
		if _current_target is MeshInstance3D:
			target_pos = _current_target.get_aabb().get_center() + _current_target.global_position
		elif _current_target.has_node("CollisionShape3D"):
			target_pos = _current_target.get_node("CollisionShape3D").global_position
		var dir_world = (target_pos - pivot.global_position).normalized()
		var dir_local = global_transform.basis.inverse() * dir_world
		var yaw   = clampf(rad_to_deg(atan2(-dir_local.x, -dir_local.z)), -YAW_LIMIT, YAW_LIMIT)
		var pitch = clampf(rad_to_deg(atan2(dir_local.y, Vector2(dir_local.x, dir_local.z).length())), -PITCH_LIMIT, PITCH_LIMIT)
		pivot.rotation = lerp(pivot.rotation, Vector3(deg_to_rad(pitch), deg_to_rad(yaw), 0.0), 15.0 * delta)
	else:
		pivot.rotation = lerp(pivot.rotation, Vector3.ZERO, 8.0 * delta)

	# Длина луча: до точки попадания, иначе на всю дальность (бьёт в воздух).
	var hit := raycast.is_colliding()
	var length := weapon_range
	if hit:
		length = minf(raycast.global_position.distance_to(raycast.get_collision_point()), weapon_range)
	if track_visual.mesh is CylinderMesh:
		(track_visual.mesh as CylinderMesh).height = length
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
	var body = raycast.get_collider()
	if body:
		if body == self or body.get_parent() == get_parent():
			return
	_fire_timer -= delta
	if _fire_timer > 0.0:
		return
	_fire_timer = fire_rate
	fire_bullet()

@onready var ammo: Node3D= $Ammo
@onready var free_bullet:Array[Area3D] = [$Ammo/Bullet]
func fire_bullet():
	if free_bullet.is_empty():
		var new_bullet: Area3D = $Ammo/Bullet.duplicate()
		ammo.add_child(new_bullet)
		free_bullet.append(new_bullet)
	var bullet:Area3D = free_bullet.pop_back()
	var dir = $Pivot.global_position.direction_to($Pivot/Marker3D.global_position)
	bullet.global_position = $Pivot/DrillBody2.global_position
	bullet.dir = dir
	bullet.look_at(dir+global_position)


func _on_area_3d_body_entered(body: Node3D) -> void:
	if body == self or body.get_parent() == get_parent():
		return
	if not _targets.has(body):
		_targets.append(body)

func _on_area_3d_body_exited(body: Node3D) -> void:
	_targets.erase(body)



func _on_bullet_body_entered(body: Node3D, source: Area3D) -> void:
	if body == self: return
	if body.get_parent() == get_parent(): return
	if body.has_method("hurt"):
		body.hurt(damage)
	source.dir = Vector3.ZERO
	source.global_position = Vector3.ZERO
	free_bullet.append(source)
