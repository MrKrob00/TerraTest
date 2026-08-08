extends WeaponBlock
# Лазер = WeaponBlock, но БЕЗ пуль: бьёт hitscan-лучом (мгновенный урон по raycast) и
# рисует красивый непрерывный луч (толстая светящаяся линия дуло→цель + вспышка у дула +
# свечение в точке попадания). Переопределяем только _track_target (визуал+наводка) и
# _handle_fire (урон лучом вместо fire_bullet). Базовый WeaponBlock (общий с пушкой) не трогаем.

const BEAM_COLOR := Color(1.0, 0.15, 0.2)     # цвет луча
const BEAM_RADIUS := 0.06
const LASER_RANGE := 16.0
const LASER_FIRE_RATE := 0.1                  # тик урона (частый = «непрерывный» луч)
const LASER_DAMAGE := 3                       # урон за тик

var _beam: MeshInstance3D = null
var _beam_mat: StandardMaterial3D = null
var _muzzle_glow: MeshInstance3D = null
var _impact_glow: MeshInstance3D = null
var _beam_t: float = 0.0

func _ready() -> void:
	super._ready()
	weapon_range = LASER_RANGE
	fire_rate = LASER_FIRE_RATE
	damage = LASER_DAMAGE
	raycast.target_position = Vector3(0, 0, -weapon_range)
	# Лазер — hitscan (урон лучом в _handle_fire), пуль НЕ пускает. Убираем «спящий» узел
	# Ammo/Bullet из сцены лазера: его Area3D (top_level, у мировой точки, маска на блоки)
	# паразитно ловил тела и звал _on_bullet_body_entered, а сценовое соединение без bind
	# роняло вызов (метод ждёт 2 аргумента, сигнал даёт 1) — та самая «ошибка с ammo».
	var ammo_node := get_node_or_null("Ammo")
	if ammo_node:
		ammo_node.queue_free()
	_build_beam()

func _build_beam() -> void:
	# Луч: цилиндр вдоль -Z под raycast (как track_visual пушки, но ярче и толще).
	_beam = MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = BEAM_RADIUS
	cyl.bottom_radius = BEAM_RADIUS
	cyl.height = 1.0
	cyl.radial_segments = 6
	_beam_mat = _glow_mat(BEAM_COLOR, 6.0)
	cyl.material = _beam_mat
	_beam.mesh = cyl
	_beam.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# CylinderMesh идёт вдоль Y → кладём вдоль -Z.
	_beam.rotation = Vector3(-PI / 2, 0, 0)
	_beam.visible = false
	raycast.add_child(_beam)

	# Вспышка у дула (Marker3D) и свечение в точке попадания.
	_muzzle_glow = _make_glow_sphere(0.16, BEAM_COLOR, 7.0)
	pivot.get_node("Marker3D").add_child(_muzzle_glow)
	_impact_glow = _make_glow_sphere(0.22, BEAM_COLOR.lerp(Color(1, 1, 1), 0.4), 8.0)
	add_child(_impact_glow)       # позиционируем в мировой точке попадания
	_impact_glow.top_level = true
	_impact_glow.visible = false

func _glow_mat(col: Color, energy: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.albedo_color = Color(col.r, col.g, col.b, 0.85)
	m.emission_enabled = true
	m.emission = col
	m.emission_energy_multiplier = energy
	return m

func _make_glow_sphere(r: float, col: Color, energy: float) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = r
	sm.height = r * 2.0
	sm.radial_segments = 8
	sm.rings = 4
	sm.material = _glow_mat(col, energy)
	mi.mesh = sm
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mi

# Наводка турели (как в базе) + рисование луча. Пушечный track_visual тут не используется.
func _track_target(delta: float, firing: bool) -> void:
	if not firing:
		_beam.visible = false
		_muzzle_glow.visible = false
		_impact_glow.visible = false
		pivot.rotation = lerp(pivot.rotation, Vector3.ZERO, 0.1)
		return

	# Доворот на приоритетную точку цели (незакрытая кабина → ближайший блок), иначе в нейтраль.
	var has_target: bool = _current_target != null and is_instance_valid(_current_target) \
			and _is_in_cone(_current_target)
	if has_target:
		var tp := _aim_point_for(_current_target)
		var dl := global_transform.basis.inverse() * (tp - pivot.global_position).normalized()
		var yaw := clampf(rad_to_deg(atan2(-dl.x, -dl.z)), -YAW_LIMIT, YAW_LIMIT)
		var pitch := clampf(rad_to_deg(atan2(dl.y, Vector2(dl.x, dl.z).length())), -PITCH_LIMIT, PITCH_LIMIT)
		pivot.rotation = lerp(pivot.rotation, Vector3(deg_to_rad(pitch), deg_to_rad(yaw), 0.0), 15.0 * delta)
	else:
		pivot.rotation = lerp(pivot.rotation, Vector3.ZERO, 8.0 * delta)

	# Длина луча: до точки попадания или на всю дальность.
	var hit := raycast.is_colliding()
	var length := weapon_range
	if hit:
		length = minf(raycast.global_position.distance_to(raycast.get_collision_point()), weapon_range)

	# Пульсация толщины и яркости — «живой» луч.
	_beam_t += delta
	var pulse := 0.85 + 0.15 * sin(_beam_t * 45.0)
	_beam.visible = true
	(_beam.mesh as CylinderMesh).height = length
	_beam.position.z = -length * 0.5
	_beam.scale = Vector3(pulse, 1.0, pulse)
	_beam_mat.emission_energy_multiplier = 6.0 * pulse

	_muzzle_glow.visible = true
	_muzzle_glow.scale = Vector3.ONE * (0.8 + 0.4 * pulse)

	_impact_glow.visible = hit
	if hit:
		_impact_glow.global_position = raycast.get_collision_point()
		_impact_glow.scale = Vector3.ONE * (0.8 + 0.5 * sin(_beam_t * 60.0) * 0.5 + 0.4)

# Урон лучом (hitscan) вместо пуль: по коллайдеру raycast, тиком fire_rate.
func _handle_fire(delta: float) -> void:
	if not raycast.is_colliding():
		return
	var body := raycast.get_collider()
	if body == null:
		return
	if body == self or body == _vehicle_root():
		return
	if body.get_parent() == get_parent():
		return                                     # блок своей же машины
	if "owner_vehicle" in body and body.owner_vehicle == _vehicle_root():
		return                                     # свой щит-купол
	_fire_timer -= delta
	if _fire_timer > 0.0:
		return
	_fire_timer = fire_rate
	if body.has_method("hurt"):
		body.hurt(damage)

# Лазер пулями не стреляет — на случай, если базовый путь позовёт.
func fire_bullet() -> void:
	pass
