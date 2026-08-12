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
	var mat := StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(0.3, 0.7, 1.0, 0.12)
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
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
