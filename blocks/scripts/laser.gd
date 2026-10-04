extends WeaponBlock
# Лазер = WeaponBlock, стреляющий СГУСТКАМИ: короткие светящиеся болты летят к цели, как
# пули, только быстрее и без просадки. Раньше это был hitscan — непрерывный луч, наносивший
# урон мгновенно по raycast. Непрерывный луч не даёт промахнуться и не даёт увернуться:
# попадание не зависит ни от расстояния, ни от скорости цели, поэтому и упреждение, и
# уклонение на нём не работают вовсе.
#
# Пули, пул и возврат в пул — общие с пушкой (WeaponBlock.fire_bullet). Своё тут только
# то, как болт выглядит: собираем шаблон кодом, чтобы не заводить отдельную сцену.

# A faction's laser sets its own numbers in the scene (marlit_laser.tscn): Marlit's energy is the
# cyan of every beam it throws. The defaults are the Falsus laser.
@export var beam_color: Color = Color(1.0, 0.15, 0.2)     # цвет болта и вспышки
## ДЛИННЫЙ И ТОНКИЙ, А НЕ КОРОТКИЙ И ТОЛСТЫЙ. Прежняя капсула 1.6 × 0.09 при скорости 90 была
## размером с пулю и читалась как пуля — игрок так и сказал: «лазер стреляет патронами». Разряд
## обязан быть ДЛИНЕЕ СВОЕГО ШАГА ЗА КАДР, тогда соседние кадры складываются в непрерывную
## черту; шаг здесь 2.5 м при шестидесяти кадрах, а с растяжением (bullet._stretch) в полёте
## выходит около шести.
@export var bolt_speed: float = 150.0          # разряд, а не снаряд: быстрее пушечной пули (120)
@export var bolt_length: float = 2.6
@export var bolt_radius: float = 0.045
@export var laser_range: float = 70.0          # дальнобойное оружие 4-го грейда
## ЗАРЯЖАЕМЫЙ ВЫСТРЕЛ. Урон в секунду тот же, каким был у непрерывного луча (≈32) и каким его
## считает таблица HP блоков, — но он теперь приходит ОДНИМ ударом раз в 0.9 с, а не капает
## четыре раза в секунду. Так у оружия появляется собственный ритм: видно, как ствол копит и
## когда разрядится, и по этому ритму от него можно уйти за угол.
@export var laser_fire_rate: float = 0.9
@export var laser_damage: int = 86
const BULLET_SCRIPT := preload("res://blocks/scripts/bullet.gd")

## НАКОПИТЕЛЬ: кольца, сбегающиеся к дулу. Их три и они идут со сдвигом фазы, поэтому поток
## непрерывный, а яркость всего набора растёт вместе с зарядом — к выстрелу кольца самые яркие.
## Шарик у ствола тут не годится: он не говорит ни о направлении, ни о том, что идёт накопление.
const CHARGE_RINGS := 3
@export var charge_reach: float = 1.1          # м: откуда кольцо начинает путь к дулу
@export var charge_big: float = 0.38           # радиус кольца в начале пути
const CHARGE_SMALL := 0.09                    # и у самого дула
const CHARGE_THICK := 0.035                   # толщина самого кольца
## Копьё разряда вместо дульного конуса (BlockFX.muzzle_lance).
@export var lance_len: float = 2.2
@export var lance_width: float = 0.1
const LANCE_DUR := 0.12

var _charge: Node3D = null
var _rings: Array[MeshInstance3D] = []

func _init() -> void:
	damage_kind = VehicleBlock.Dmg.ENERGY   # x1.5 on armour and batteries, x0.5 on shields
	turn_speed = 80.0        # deg/s (WeaponBlock._turn_to): the lens stack is heavier than the gun

func _ready() -> void:
	super._ready()
	weapon_range = laser_range
	fire_rate = laser_fire_rate
	damage = laser_damage
	recoil_dist = minf(recoil_dist, 0.03)   # light: a discharge, not a charge of powder
	# Разброс ВДВОЕ УЖЕ базового: лазер — точный ствол, это его отличие от пушки, за которое
	# платят скорострельностью и дальностью. Нулевым его не делаем: аимбот остаётся аимботом,
	# каким бы благородным ни было оружие.
	spread_deg = 0.7
	flash_color = beam_color        # свет дула — того же цвета, что болт, а не пороховой
	# Против купола лазер — неправильный инструмент: щит снимает с батареи половину цены.
	shield_cost_mult = SHIELD_MULT_ENERGY
	raycast.target_position = Vector3(0, 0, -weapon_range)
	_sync_detect_radius()          # дальность лазера своя — пересчитываем зону под неё
	# Узла Ammo в сцене лазера БОЛЬШЕ НЕТ — он снят вместе со своим шаблоном пули: тот был
	# подключён к _on_bullet_body_entered БЕЗ bind (метод ждёт два аргумента, сигнал даёт один)
	# и ронял вызов на каждом попадании, а его плоский зелёный меш-билборд оставался висеть у
	# ствола зелёной полоской — от старого, ещё лучевого лазера. Проверку оставляем на случай
	# старой сцены: свой пул мы строим всё равно.
	var ammo_node := get_node_or_null("Ammo")
	if ammo_node:
		ammo_node.free()             # именно free, а не queue_free: имя "Ammo" нужно прямо сейчас
	_build_bolt_pool()
	_build_charge()

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
	bolt.set("speed", bolt_speed)
	bolt.set("bullet_gravity", 0.0)    # сгусток света не проседает
	bolt.set("max_lifetime", weapon_range / bolt_speed + 0.4)
	var col := CollisionShape3D.new()
	var sph := SphereShape3D.new()
	sph.radius = 0.22
	col.shape = sph
	bolt.add_child(col)
	var mi := MeshInstance3D.new()
	mi.mesh = _bolt_mesh()
	mi.rotation = Vector3(-PI / 2, 0, 0)   # капсула растёт по Y, а болт летит по -Z
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# РАЗРЯД — НЕ ПУЛЯ, И ОБЩУЮ МОДЕЛЬ СНАРЯДА СЮДА СТАВИТЬ НЕЛЬЗЯ (WeaponBlock.OWN_VISUAL).
	mi.set_meta(OWN_VISUAL, true)
	bolt.add_child(mi)
	holder.add_child(bolt)
	_rebind_bullet(bolt)

# Кольца накопителя. Тор лежит в плоскости XZ с осью по Y, поэтому его разворачивают на −90°
# по X: ось кольца ложится вдоль −Z держателя, то есть вдоль ствола.
func _build_charge() -> void:
	_charge = Node3D.new()
	_charge.name = "ChargeFX"
	_charge.set_meta("block_fx", true)          # в габарит блока не входит (см. _local_aabb)
	var mat := _glow_mat(beam_color, 7.0)
	for _i in CHARGE_RINGS:
		var mi := MeshInstance3D.new()
		var t := TorusMesh.new()
		t.inner_radius = 1.0 - CHARGE_THICK
		t.outer_radius = 1.0
		t.rings = 10
		t.ring_segments = 5
		t.material = mat                        # один материал на все кольца: цвет у них общий
		mi.mesh = t
		mi.rotation_degrees = Vector3(-90.0, 0.0, 0.0)
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_charge.add_child(mi)
		_rings.append(mi)
	_charge.visible = false
	# ТА ЖЕ ТОЧКА ДУЛА, ЧТО У БОЛТА И У КОПЬЯ (_muzzle_point). Своя строка `pivot/Marker3D`
	# означала бы, что на сборке с другой моделью ствола заряд копится в одном месте, а
	# вылетает из другого.
	_muzzle_point().add_child(_charge)

## Кольца на текущем заряде. Каждое идёт от CHARGE_REACH к дулу, сжимаясь; фазы разнесены, так
## что в любой момент одно из трёх близко к стволу. Общая яркость — сам заряд: пока ствол пуст,
## накопителя почти не видно, к выстрелу он горит в полную силу.
func _drive_charge(ratio: float) -> void:
	for i in _rings.size():
		var p: float = fposmod(ratio + float(i) / float(CHARGE_RINGS), 1.0)
		var mi: MeshInstance3D = _rings[i]
		var r: float = lerpf(charge_big, CHARGE_SMALL, p)
		mi.scale = Vector3(r, r, r)
		mi.position = Vector3(0.0, 0.0, -(1.0 - p) * charge_reach)
		# Кольцо разгорается на входе и гаснет у дула, иначе видно, что их ровно три.
		mi.transparency = 1.0 - clampf(sin(p * PI) * (0.25 + 0.75 * ratio), 0.0, 1.0)

## THE BOLT HAS A WHITE-HOT CORE IN A COLOURED SHEATH, two surfaces of one mesh (so BulletSim still
## draws all bolts of one laser in one MultiMesh - a kind that brings its own visual keeps the mesh's
## own surface materials). A single translucent capsule read as a coloured stick; the core is what
## makes it read as light. The sheath is additive, the core opaque.
func _bolt_mesh() -> ArrayMesh:
	var cap := CapsuleMesh.new()
	cap.radius = bolt_radius
	cap.height = bolt_length
	cap.radial_segments = 6
	cap.rings = 2
	var core := CapsuleMesh.new()
	core.radius = bolt_radius * 0.42
	core.height = bolt_length * 0.86
	core.radial_segments = 6
	core.rings = 2
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, core.get_mesh_arrays())
	var cm := StandardMaterial3D.new()
	cm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	cm.albedo_color = beam_color.lerp(Color.WHITE, 0.75)
	m.surface_set_material(0, cm)
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, cap.get_mesh_arrays())
	var sm := _glow_mat(beam_color, 7.0)
	sm.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	sm.albedo_color = Color(beam_color.r, beam_color.g, beam_color.b, 0.9)
	m.surface_set_material(1, sm)
	return m

func _glow_mat(col: Color, energy: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.albedo_color = Color(col.r, col.g, col.b, 0.85)
	m.emission_enabled = true
	m.emission = col
	m.emission_energy_multiplier = energy
	return m

# Наводка турели. Пушечный track_visual тут не используется, поэтому базовый _track_target
# (он на нём завязан и без него сразу выходит) заменён своим — но точка прицеливания берётся
# та же, общая: с упреждением и поправкой на просадку (WeaponBlock._lead_point).
func _track_target(delta: float, firing: bool) -> void:
	if not firing:
		_charge.visible = false                 # молчащий ствол ничего не копит
		_turn_to(0.0, 0.0, delta)
		return
	var has_target: bool = _current_target != null and is_instance_valid(_current_target) \
			and _is_in_cone(_current_target)
	if has_target:
		var tp := _lead_point(_current_target, pivot.global_position)
		var dl := global_transform.basis.inverse() * (tp - pivot.global_position).normalized()
		var yaw := clampf(rad_to_deg(atan2(-dl.x, -dl.z)), -yaw_limit, yaw_limit)
		var pitch := clampf(rad_to_deg(atan2(dl.y, Vector2(dl.x, dl.z).length())), -pitch_limit, pitch_limit)
		_turn_to(pitch, yaw, delta)
	else:
		_turn_to(0.0, 0.0, delta)

	# НАКОПИТЕЛЬ ВИДЕН ВСЁ ВРЕМЯ ПРИЦЕЛИВАНИЯ, а не долю секунды после выстрела. Вспышка
	# постфактум говорила только «уже выстрелил»; кольца говорят «сейчас выстрелю», и это
	# единственное, что игрок может использовать — успеть уйти за укрытие.
	_charge.visible = true
	_drive_charge(charge_ratio())

## Разряд рисуем копьём вдоль ствола, а не дульным конусом: конус — это пороховые газы.
func _muzzle_fx(dir: Vector3) -> void:
	BlockFX.muzzle_lance(_muzzle_point(), dir, beam_color, lance_len, lance_width, LANCE_DUR)
