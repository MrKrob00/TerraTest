extends WeaponBlock
class_name RocketLauncher
# Ракетница = WeaponBlock (та же наводка турели/конус/дальность/пул снарядов), но снаряд —
# РАКЕТА (bullet.gd, медленнее пули), и при попадании/истечении она ВЗРЫВАЕТСЯ: урон по
# площади (AOE, спадает от центра) + дешёвый эффект взрыва. Наводку-луч пушки не рисуем
# (у ракетницы нет прицельного луча) — переопределяем только _track_target (без визуала),
# _on_bullet_body_entered и _on_bullet_expired (взрыв вместо одиночного урона).

## Радиус поражения взрыва (мировые единицы).
@export var aoe_radius: float = 4.5
## Урон в эпицентре (к краю радиуса спадает до ~15%).
@export var aoe_damage: int = 45

func _ready() -> void:
	super._ready()
	weapon_range = 18.0                       # ракеты бьют дальше пушки
	fire_rate = 1.6                           # но реже (тяжёлый снаряд)
	raycast.target_position = Vector3(0, 0, -weapon_range)

# Наводка турели БЕЗ прицельного луча (у пушки тут рисовался track_visual). Копия аиминга
# из базы, но без визуала — иначе база при отсутствии track_visual вообще не доворачивала бы.
func _track_target(delta: float, firing: bool) -> void:
	if not firing:
		pivot.rotation = lerp(pivot.rotation, Vector3.ZERO, 8.0 * delta)
		return
	var has_target: bool = _current_target != null and is_instance_valid(_current_target) \
			and _is_in_cone(_current_target)
	if has_target:
		var tp := _aim_point_for(_current_target)
		var dl := global_transform.basis.inverse() * (tp - pivot.global_position).normalized()
		var yaw := clampf(rad_to_deg(atan2(-dl.x, -dl.z)), -YAW_LIMIT, YAW_LIMIT)
		var pitch := clampf(rad_to_deg(atan2(dl.y, Vector2(dl.x, dl.z).length())), -PITCH_LIMIT, PITCH_LIMIT)
		pivot.rotation = lerp(pivot.rotation, Vector3(deg_to_rad(pitch), deg_to_rad(yaw), 0.0), 12.0 * delta)
	else:
		pivot.rotation = lerp(pivot.rotation, Vector3.ZERO, 8.0 * delta)

# Ракета во что-то попала → ВЗРЫВ (AOE), а не одиночный урон базового WeaponBlock.
func _on_bullet_body_entered(body: Node3D, source: Area3D) -> void:
	if body == self: return
	if body.get_parent() == get_parent(): return               # блок своей же машины
	if "owner_vehicle" in body and body.owner_vehicle == _vehicle_root(): return
	_explode(source.global_position)
	_recycle_bullet(source)

# Ракета истекла (таймаут / ниже min_y) — тоже взрыв в точке (напр. упала в землю мимо цели).
func _on_bullet_expired(b: Area3D) -> void:
	_explode(b.global_position)
	_recycle_bullet(b)

# AOE-урон: сфера-запрос по слою блоков (2), урон спадает от эпицентра. Свою машину не бьём.
func _explode(pos: Vector3) -> void:
	var world := get_world_3d()
	if world == null:
		return
	var sphere := SphereShape3D.new()
	sphere.radius = aoe_radius
	var q := PhysicsShapeQueryParameters3D.new()
	q.shape = sphere
	q.transform = Transform3D(Basis(), pos)
	q.collision_mask = 2                                        # VehicleBlock.collision_layer = 2
	q.collide_with_bodies = true
	var own := _vehicle_root()
	var seen := {}                                             # один блок — один урон (много шейпов)
	for hit in world.direct_space_state.intersect_shape(q, 48):
		var b = hit.get("collider")
		if b == null or seen.has(b) or not b.has_method("hurt"):
			continue
		if b == self or b.get_parent() == get_parent():
			continue
		if _root_of(b) == own:
			continue                                           # своя машина — не по себе
		seen[b] = true
		var d: float = (b as Node3D).global_position.distance_to(pos)
		var f: float = clampf(1.0 - d / aoe_radius, 0.15, 1.0)  # спад урона к краю
		b.hurt(int(round(aoe_damage * f)))
	_spawn_explosion_fx(pos)

# Корневое тело (RigidBody3D) для узла — чтобы отличить свою машину от чужой.
func _root_of(n: Node) -> Node:
	var p: Node = n
	while p != null and not (p is RigidBody3D):
		p = p.get_parent()
	return p

# ── Дешёвый взрыв: два additive-меша (огненный шар + горячее ядро), твин раздутие+угасание,
# потом самоудаление. Без частиц/света → предсказуемо и лёгко для мобильного (fill-bound) GPU.
func _spawn_explosion_fx(pos: Vector3) -> void:
	var root := get_tree().current_scene
	if root == null:
		return
	_boom_layer(root, pos, aoe_radius, Color(1.0, 0.55, 0.15), 4.0, 0.38)   # огненный шар
	_boom_layer(root, pos, aoe_radius * 0.55, Color(1.0, 0.95, 0.7), 6.0, 0.22)  # горячее ядро

func _boom_layer(root: Node, pos: Vector3, target_r: float, col: Color, energy: float, dur: float) -> void:
	var mi := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = 0.5
	sm.height = 1.0
	sm.radial_segments = 10
	sm.rings = 6
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	mat.albedo_color = Color(col.r, col.g, col.b, 1.0)
	mat.emission_enabled = true
	mat.emission = col
	mat.emission_energy_multiplier = energy
	sm.material = mat
	mi.mesh = sm
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(mi)
	mi.global_position = pos
	mi.scale = Vector3.ONE * 0.25
	var tw := mi.create_tween()
	tw.set_parallel(true)
	tw.tween_property(mi, "scale", Vector3.ONE * (target_r / 0.5), dur).set_ease(Tween.EASE_OUT)
	tw.tween_property(mat, "albedo_color:a", 0.0, dur).set_ease(Tween.EASE_IN)
	tw.tween_property(mat, "emission_energy_multiplier", 0.0, dur)
	tw.chain().tween_callback(mi.queue_free)

# Ракетница пулями-хитсканом не бьёт — снаряды идут через пул bullet (см. базовый fire_bullet).
