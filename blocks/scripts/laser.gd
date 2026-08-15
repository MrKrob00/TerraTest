extends WeaponBlock
# Лазер = WeaponBlock, стреляющий СГУСТКАМИ: короткие светящиеся болты летят к цели, как
# пули, только быстрее и без просадки. Раньше это был hitscan — непрерывный луч, наносивший
# урон мгновенно по raycast. Непрерывный луч не даёт промахнуться и не даёт увернуться:
# попадание не зависит ни от расстояния, ни от скорости цели, поэтому и упреждение, и
# уклонение на нём не работают вовсе.
#
# Пули, пул и возврат в пул — общие с пушкой (WeaponBlock.fire_bullet). Своё тут только
# то, как болт выглядит: собираем шаблон кодом, чтобы не заводить отдельную сцену.

const BEAM_COLOR := Color(1.0, 0.15, 0.2)     # цвет болта и вспышки
const BOLT_SPEED := 90.0                      # быстрее пушечной пули (120 у пушки — но та с просадкой)
const BOLT_LENGTH := 1.6                      # вытянутый сгусток, а не шарик: видно направление
const BOLT_RADIUS := 0.09
const LASER_RANGE := 70.0                     # дальнобойное оружие 4-го грейда
## Темп и урон пересчитаны с тика непрерывного луча (3 урона каждые 0.1 с = 30 в секунду)
## на выстрелы, чтобы урон в секунду остался прежним.
const LASER_FIRE_RATE := 0.25
const LASER_DAMAGE := 8
const BULLET_SCRIPT := preload("res://blocks/scripts/bullet.gd")

var _muzzle_glow: MeshInstance3D = null
var _beam_t: float = 0.0

func _ready() -> void:
	super._ready()
	weapon_range = LASER_RANGE
	fire_rate = LASER_FIRE_RATE
	damage = LASER_DAMAGE
	raycast.target_position = Vector3(0, 0, -weapon_range)
	_sync_detect_radius()          # дальность лазера своя — пересчитываем зону под неё
	# Узел Ammo из сцены лазера выбрасываем и строим свой: сценовый Bullet был подключён к
	# _on_bullet_body_entered БЕЗ bind (метод ждёт два аргумента, сигнал даёт один) и ронял
	# вызов на каждом попадании — та самая «ошибка с ammo». Свой шаблон цепляем правильно.
	var ammo_node := get_node_or_null("Ammo")
	if ammo_node:
		ammo_node.free()             # именно free, а не queue_free: имя "Ammo" нужно прямо сейчас
	_build_bolt_pool()
	_build_muzzle_glow()

# Пул болтов: шаблон под узлом Ammo, дальше им управляет базовый WeaponBlock.fire_bullet —
# он же дублирует шаблон, когда пул пуст, и возвращает отработавшие болты обратно.
func _build_bolt_pool() -> void:
	var holder := Node3D.new()
	holder.name = "Ammo"
	add_child(holder)
	ammo = holder                      # базовый @onready ammo уже отработал (сцена без Ammo)

	var bolt := Area3D.new()
	bolt.name = "Bullet"
	bolt.top_level = true              # летит в мировых координатах, а не с башней
	bolt.collision_layer = 0
	bolt.collision_mask = 7            # как у пушечной пули: рельеф + блоки
	bolt.monitoring = false            # в пуле не ловит тела
	bolt.set_script(BULLET_SCRIPT)
	bolt.set("speed", BOLT_SPEED)
	bolt.set("bullet_gravity", 0.0)    # сгусток света не проседает
	bolt.set("max_lifetime", weapon_range / BOLT_SPEED + 0.4)
	var col := CollisionShape3D.new()
	var sph := SphereShape3D.new()
	sph.radius = 0.22
	col.shape = sph
	bolt.add_child(col)
	var mi := MeshInstance3D.new()
	var cap := CapsuleMesh.new()
	cap.radius = BOLT_RADIUS
	cap.height = BOLT_LENGTH
	cap.radial_segments = 6
	cap.material = _glow_mat(BEAM_COLOR, 7.0)
	mi.mesh = cap
	mi.rotation = Vector3(-PI / 2, 0, 0)   # капсула растёт по Y, а болт летит по -Z
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	bolt.add_child(mi)
	holder.add_child(bolt)
	_rebind_bullet(bolt)

func _build_muzzle_glow() -> void:
	_muzzle_glow = _make_glow_sphere(0.16, BEAM_COLOR, 7.0)
	pivot.get_node("Marker3D").add_child(_muzzle_glow)
	_muzzle_glow.visible = false

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

# Наводка турели. Пушечный track_visual тут не используется, поэтому базовый _track_target
# (он на нём завязан и без него сразу выходит) заменён своим — но точка прицеливания берётся
# та же, общая: с упреждением и поправкой на просадку (WeaponBlock._lead_point).
func _track_target(delta: float, firing: bool) -> void:
	if not firing:
		_muzzle_glow.visible = false
		pivot.rotation = lerp(pivot.rotation, Vector3.ZERO, 0.1)
		return
	var has_target: bool = _current_target != null and is_instance_valid(_current_target) \
			and _is_in_cone(_current_target)
	if has_target:
		var tp := _lead_point(_current_target, pivot.global_position)
		var dl := global_transform.basis.inverse() * (tp - pivot.global_position).normalized()
		var yaw := clampf(rad_to_deg(atan2(-dl.x, -dl.z)), -YAW_LIMIT, YAW_LIMIT)
		var pitch := clampf(rad_to_deg(atan2(dl.y, Vector2(dl.x, dl.z).length())), -PITCH_LIMIT, PITCH_LIMIT)
		pivot.rotation = lerp(pivot.rotation, Vector3(deg_to_rad(pitch), deg_to_rad(yaw), 0.0), 15.0 * delta)
	else:
		pivot.rotation = lerp(pivot.rotation, Vector3.ZERO, 8.0 * delta)

	# Вспышка у дула живёт долю секунды после выстрела — по ней видно ТЕМП стрельбы.
	# У непрерывного луча темпа не было видно вовсе, он просто горел.
	_beam_t = maxf(_beam_t - delta, 0.0)
	_muzzle_glow.visible = _beam_t > 0.0
	if _muzzle_glow.visible:
		_muzzle_glow.scale = Vector3.ONE * (0.7 + 1.3 * _beam_t / MUZZLE_FLASH)

# Выстрел = вспышка у дула; сам болт пускает базовый WeaponBlock.fire_bullet.
const MUZZLE_FLASH := 0.09

func fire_bullet() -> void:
	super.fire_bullet()
	_beam_t = MUZZLE_FLASH
