# shield.gd — блок щита: держит сферический купол вокруг себя. Купол ловит вражеские
# снаряды/лучи (он на слое блоков) и за каждое попадание списывает энергию машины:
# урон × SHIELD_COST_X. Энергии нет — купол гаснет (коллизия и меш выключены).
extends VehicleBlock

const SHIELD_RADIUS := 4.0
## ЦЕНА ЩИТА ПРИВЯЗАНА К ТОЙ ЖЕ МЕРЕ, ЧТО И ХП БЛОКОВ: «сколько секунд под огнём своего уровня».
## Кабина по этой мере держит шесть секунд, обычный блок три.
##
## Было 1 к 1, и вот что это значило на самом деле. Аккумулятор держит 100 энергии, пушка игрока
## даёт 25 урона в секунду: одна батарея — ЧЕТЫРЕ секунды под одним стволом. А щиты появляются у
## врага тогда, когда у игрока уже два-три ствола, то есть полторы-две секунды. Столько не живёт
## механика — столько живёт формальность, и игрок это заметил как «щит спал довольно быстро».
##
## Сборки со щитом несут одну или две батареи (проверено по таблице раскладок: из четырнадцати
## таких сборок ни одной без батареи). При 0.6 это 6.7 секунды на батарею против одного ствола и
## 3.3 против двух; двухбатарейные, то есть верхние сборки, выходят ровно на кабинные шесть
## секунд против реального игрока.
##
## Стеной щит от этого не становится: панелей на ездящих машинах нет, заряд им дают один раз при
## рождении (enemy_spawner._charge_batteries), и потратить его можно ровно однажды.
const SHIELD_COST_X := 0.6     # энергии за 1 урона
const SHIELD_BREAK_CD := 2.0   # пробитый щит не поднимается столько секунд

var _dome: StaticBody3D = null
var _dome_mesh: MeshInstance3D = null
var _cd: float = 0.0           # > 0 — щит пробит и перезаряжается
## Свежее попадание: купол вспыхивает целиком и гаснет за HIT_FADE. Без этого игрок не видел,
## что щит СРАБОТАЛ: снаряд просто исчезал у границы, а сам купол не менялся никак.
var _hit: float = 0.0
const HIT_FADE := 0.22

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
	# ПЛАСТИНЫ, А НЕ ЗАЛИВКА (см. shield_dome.gdshader).
	#
	# СЕГМЕНТОВ ХВАТАЕТ НЕМНОГИХ. Их поднимали до 48×24, пока сетка считалась по UV: там шов
	# действительно ломался на гранях меша. Теперь узор считается от НАПРАВЛЕНИЯ, а оно
	# интерполируется гладко, так что от числа сегментов зависит только силуэт. Меньше
	# сегментов — меньше вершинной работы, а купол на телефоне рисуется дважды (cull_disabled).
	m.radial_segments = 32
	m.rings = 16
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
	if _hit > 0.0:
		_hit = maxf(_hit - delta / HIT_FADE, 0.0)
		_push_hit()
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
	# Заряд теперь решает, СКОЛЬКО ПЛАСТИН СТОИТ, а не насколько купол бледный: бледнеющий
	# купол читался как «эффект гаснет», осыпающаяся решётка — как «щита осталось на столько».
	# Поэтому уровень уходит в шейдер как есть, без прежней поправки 0.35 + 0.65·lvl.
	if powered and v != null and v.has_method("energy_fill"):
		_set_dome_param("energy", clampf(float(v.energy_fill()), 0.0, 1.0))

func _dome_material() -> ShaderMaterial:
	if _dome_mesh == null:
		return null
	var pm := _dome_mesh.mesh as PrimitiveMesh
	return pm.material as ShaderMaterial if pm != null else null

func _set_dome_param(name: String, value: Variant) -> void:
	var mat := _dome_material()
	if mat != null:
		mat.set_shader_parameter(name, value)

func _push_hit() -> void:
	_set_dome_param("hit", _hit)

# Попадание в купол: списываем энергию вместо HP. Если на удар энергии не хватило —
# щит ПРОБИТ: гаснет и SHIELD_BREAK_CD секунд не поднимается, даже если энергия уже
# капает. Иначе на якоре подпитка шла быстрее выстрелов и щит был непробиваем.
func absorb(damage: int) -> void:
	# Волна от места удара — это и есть ответ на «не вижу, что щит сработал»: снаряд гас у
	# границы, а сам щит никак не менялся. Без точки волна расходится от макушки — купол всё
	# равно отвечает, просто не показывает, откуда прилетело.
	_hit = 1.0
	_push_hit()
	var v := _vehicle_root()
	if v and v.has_method("energy_consume"):
		var cost := float(damage) * SHIELD_COST_X
		var paid: float = v.energy_consume(cost)
		if paid < cost or v.energy_available() <= 0.0:
			_cd = SHIELD_BREAK_CD

## Куда попали. Направление переводим в ОСИ КУПОЛА: машина едет и крутится, а волна обязана
## остаться на том месте оболочки, куда пришёл снаряд.
func mark_hit_point(world_pos: Vector3) -> void:
	if _dome == null:
		return
	var local: Vector3 = _dome.global_transform.basis.inverse() \
			* (world_pos - _dome.global_position)
	if local.length_squared() < 0.0001:
		return
	_set_dome_param("hit_dir", local.normalized())

func _vehicle_root() -> Node:
	var p := get_parent()
	while p != null and not (p is RigidBody3D):
		p = p.get_parent()
	return p
