# shield.gd — блок щита: держит сферический купол вокруг себя. Купол ловит вражеские
# снаряды/лучи (он на слое блоков) и за каждое попадание списывает энергию машины:
# урон × SHIELD_COST_X. Энергии нет — купол гаснет (коллизия и меш выключены).
extends VehicleBlock

const SHIELD_RADIUS := 4.0
const SHIELD_COST_X := 1.0     # энергии за 1 урона
const SHIELD_BREAK_CD := 2.0   # пробитый щит не поднимается столько секунд

var _dome: StaticBody3D = null
var _dome_mesh: MeshInstance3D = null
var _cd: float = 0.0           # > 0 — щит пробит и перезаряжается

func _ready() -> void:
	super._ready()
	_dome = StaticBody3D.new()
	_dome.set_script(preload("res://shield_dome.gd"))
	_dome.collision_layer = 2    # как блоки: пули (mask 2) и лучи его видят
	_dome.collision_mask = 0     # сам ни с чем не сталкивается
	var cs := CollisionShape3D.new()
	var sph := SphereShape3D.new()
	sph.radius = SHIELD_RADIUS
	cs.shape = sph
	_dome.add_child(cs)
	_dome_mesh = MeshInstance3D.new()
	var m := SphereMesh.new()
	m.radius = SHIELD_RADIUS
	m.height = SHIELD_RADIUS * 2.0
	# ПЛАСТИНЫ, А НЕ ЗАЛИВКА. Однотонный шар на 12% альфы не читался ни как щит, ни как
	# что-либо вообще. Шестиугольная сетка даёт ему устройство, а свечение по касательной —
	# ощущение оболочки, сквозь которую видно машину (см. shield_dome.gdshader).
	#
	# Сегменты сферы подняты: на стандартных 64×32 шов между пластинами ломался на гранях меша.
	m.radial_segments = 48
	m.rings = 24
	var mat := ShaderMaterial.new()
	mat.shader = preload("res://shield_dome.gdshader")
	m.material = mat
	_dome_mesh.mesh = m
	_dome.add_child(_dome_mesh)
	add_child(_dome)

func _physics_process(delta: float) -> void:
	if _dome == null:
		return
	if _cd > 0.0:
		_cd -= delta
	_dome.owner_vehicle = _vehicle_root()
	# Купол активен: блок стоит на машине, есть энергия И щит не пробит (не на КД).
	var v := _vehicle_root()
	var powered: bool = _cd <= 0.0 and freeze and v != null \
			and v.has_method("energy_available") and v.energy_available() > 0.0
	_dome.visible = powered
	var cs := _dome.get_child(0) as CollisionShape3D
	if cs:
		cs.disabled = not powered
	# КУПОЛ ТУСКНЕЕТ ВМЕСТЕ С ЗАРЯДОМ. Раньше он был одинаково ярким и при полной батарее, и на
	# последних процентах: игрок узнавал, что щита больше нет, ровно в тот момент, когда по нему
	# попадали. Теперь видно заранее — и это честная информация, а не подсказка.
	if powered and _dome_mesh != null:
		var mat := (_dome_mesh.mesh as SphereMesh).material as ShaderMaterial
		if mat != null and v != null and v.has_method("energy_fill"):
			var lvl: float = clampf(float(v.energy_fill()), 0.0, 1.0)
			# Не в ноль: погасший в ноль купол неотличим от выключенного, а он ещё работает.
			mat.set_shader_parameter("energy", 0.35 + 0.65 * lvl)

# Попадание в купол: списываем энергию вместо HP. Если на удар энергии не хватило —
# щит ПРОБИТ: гаснет и SHIELD_BREAK_CD секунд не поднимается, даже если энергия уже
# капает. Иначе на якоре подпитка шла быстрее выстрелов и щит был непробиваем.
func absorb(damage: int) -> void:
	var v := _vehicle_root()
	if v and v.has_method("energy_consume"):
		var cost := float(damage) * SHIELD_COST_X
		var paid: float = v.energy_consume(cost)
		_blink()
		if paid < cost or v.energy_available() <= 0.0:
			_cd = SHIELD_BREAK_CD

func _blink() -> void:
	if _dome_mesh == null:
		return
	var mat := (_dome_mesh.mesh as SphereMesh).material as StandardMaterial3D
	if mat == null:
		return
	mat.albedo_color.a = 0.35
	var tw := create_tween()
	tw.tween_property(mat, "albedo_color:a", 0.12, 0.25)

func _vehicle_root() -> Node:
	var p := get_parent()
	while p != null and not (p is RigidBody3D):
		p = p.get_parent()
	return p
