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
## Свежее попадание: ОДНА пластина вспыхивает и гаснет за HIT_FADE. Без этого игрок не видел,
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
	# ПЛАСТИНЫ — НАСТОЯЩИЕ МНОГОУГОЛЬНИКИ, а не узор на сфере (см. shield_hex.gd). Сетку на
	# сфере рисовать бесполезно при любых настройках: по UV она закручивается у полюсов, по
	# грани куба тянется к силуэту. Здесь это многогранник Голдберга, и клетка одинакова везде.
	_dome_mesh.mesh = _hex_geometry()
	var mat := ShaderMaterial.new()
	mat.shader = preload("res://shield_dome.gdshader")
	# Меш ОДИН НА ВСЕ ЩИТЫ (радиус у них общий), поэтому материал живёт на узле, а не на меше:
	# заряд и попадание у каждого купола свои.
	_dome_mesh.material_override = mat
	_dome_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_dome.add_child(_dome_mesh)
	add_child(_dome)

## Сколько раз делится грань икосаэдра: ячеек выходит 10·sub²+2, то есть 92 при трёх. Столько
## и читается как «шестиугольный щит» — при большем числе пластины мельчают до ряби.
const DOME_SUB := 3
static var _hex_mesh: ArrayMesh = null
static var _hex_cells: Array = []
static var _hex_keep: PackedFloat32Array = PackedFloat32Array()

## СКОЛЬКО ПЛАСТИН ОСТАЁТСЯ ВОКРУГ ПОПАДАНИЯ НА ПУСТОМ ЗАРЯДЕ. Семь — это сама пластина и её
## ряд соседей; меньше читается как случайные искры, а не как «щит держится вот здесь».
const KEEP_MIN := 7

## Строится один раз на всю игру: у всех щитов один радиус, значит и купол один и тот же.
static func _hex_geometry() -> ArrayMesh:
	if _hex_mesh == null:
		var built := ShieldHex.build(SHIELD_RADIUS, DOME_SUB)
		_hex_mesh = built["mesh"]
		_hex_cells = built["centers"]
		_build_keep_table()
	return _hex_mesh

## Порог близости, при котором вокруг КАЖДОЙ пластины остаётся ровно KEEP_MIN штук.
##
## Одним числом на весь купол это не решается: у двенадцати пятиугольников соседей пять, то есть
## шесть пластин вместо семи, — измерено, на всём плато порогов 0.80…0.90 минимум держится на
## шести. Поэтому порог свой у каждой пластины: берём KEEP_MIN-е по убыванию скалярное
## произведение и чуть опускаем, чтобы оно само попало внутрь.
static func _build_keep_table() -> void:
	_hex_keep = PackedFloat32Array()
	_hex_keep.resize(_hex_cells.size())
	for i in _hex_cells.size():
		var a: Vector3 = (_hex_cells[i] as Vector3).normalized()
		var dots: Array[float] = []
		for c in _hex_cells:
			dots.append(a.dot((c as Vector3).normalized()))
		dots.sort()
		dots.reverse()
		_hex_keep[i] = dots[mini(KEEP_MIN - 1, dots.size() - 1)] - 0.001

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
	return _dome_mesh.material_override as ShaderMaterial

func _set_dome_param(name: String, value: Variant) -> void:
	var mat := _dome_material()
	if mat != null:
		mat.set_shader_parameter(name, value)

func _push_hit() -> void:
	_set_dome_param("hit", _hit)

# Попадание в купол: списываем энергию вместо HP. Если на удар энергии не хватило —
# щит ПРОБИТ: гаснет и SHIELD_BREAK_CD секунд не поднимается, даже если энергия уже
# капает. Иначе на якоре подпитка шла быстрее выстрелов и щит был непробиваем.
## `cost_mult` — во сколько куполу обходится очко урона ЭТОГО типа (WeaponBlock.shield_cost_mult).
## Единица — пули, на них и настроен SHIELD_COST_X; всё остальное дешевле, то есть хуже против
## щита. Источник без типа (таран, чужой код) платит обычную цену.
func absorb(damage: int, cost_mult: float = 1.0) -> void:
	# Вспышка пластины — это и есть ответ на «не вижу, что щит сработал»: снаряд гас у границы,
	# а сам щит никак не менялся. Какая именно пластина, скажет mark_hit_point сразу следом;
	# источник урона без точки (их почти нет) зажжёт ту, что отметили прошлой.
	_hit = 1.0
	_push_hit()
	var v := _vehicle_root()
	if v and v.has_method("energy_consume"):
		var cost := float(damage) * SHIELD_COST_X * maxf(cost_mult, 0.0)
		var paid: float = v.energy_consume(cost)
		if paid < cost or v.energy_available() <= 0.0:
			_cd = SHIELD_BREAK_CD

## Куда попали. Направление переводим в ОСИ КУПОЛА (машина едет и крутится) и ищем БЛИЖАЙШУЮ
## ПЛАСТИНУ: вспыхивает ровно она одна. Мигание всей оболочки не говорит, куда пришёлся удар, а
## под частым огнём превращается в мигание экрана.
func mark_hit_point(world_pos: Vector3) -> void:
	if _dome == null:
		return
	var local: Vector3 = _dome.global_transform.basis.inverse() \
			* (world_pos - _dome.global_position)
	if local.length_squared() < 0.0001:
		return
	var i: int = _nearest_index(local.normalized())
	if i < 0:
		return
	_set_dome_param("hit_cell", _hex_cells[i])
	# И ГРАНИЦА ШАПКИ — ВМЕСТЕ С НЕЙ. Купол держит пластины вокруг последнего попадания, а
	# сколько их там окажется, зависит от того, в какую именно пластину пришло (см. _hex_keep).
	_set_dome_param("keep_cos", _hex_keep[i])

func _nearest_index(dir: Vector3) -> int:
	var best: int = -1
	var best_dot := -2.0
	for i in _hex_cells.size():
		var d: float = dir.dot(_hex_cells[i])
		if d > best_dot:
			best_dot = d
			best = i
	return best

func _vehicle_root() -> Node:
	var p := get_parent()
	while p != null and not (p is RigidBody3D):
		p = p.get_parent()
	return p
