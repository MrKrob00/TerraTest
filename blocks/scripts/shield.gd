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
## The ripple's own clock (shield_dome.gdshader `ripple`): 0 at the hit, 1 gone. A new one starts
## only once the last is RIPPLE_RESTART of the way out, or a machine gun would restart it every
## tenth of a second and it would never travel - sustained fire reads as rings rolling outward.
const RIPPLE_TIME := 0.6
const RIPPLE_RESTART := 0.5
var _ripple: float = 1.0
## Neighbour domes cut out of this one (shield_dome.gdshader `cut`). The dome is a Goldberg solid of
## FLAT plates, so its surface lies inside the true sphere by up to 1 - cos(half a plate); cutting at
## the full radius would open a sliver where neither dome draws. CUT_INSET is that margin.
const CUT_MAX := 4
const CUT_INSET := 0.985
const GROUP := &"shield_blocks"
var _cuts: Array[Vector4] = []
## Shields whose domes are merged with this one right now (same list as the cuts): a hit on any of
## them is a hit on the one hull, so the flare, the cap and the ripple are handed to all of them.
var _merged: Array = []
## ONE LATTICE OVER THE JOIN (shield_dome.gdshader `seam_c`): every surviving plate of the merged
## domes whose centre lies within `_seam_zone` + SEAM_MARGIN of a join, as (centre in THIS dome's model
## space, its random number). The margin is a plate's reach, so any fragment in the band has the
## plate it would belong to in the set. SEAM_MAX is the shader's array.
const SEAM_MARGIN := 0.9                  # of a spacing: a plate's reach beyond the band
const SEAM_MAX := 96
## THE JOIN ITSELF CARRIES A ROW OF PLATES. Two domes side by side are mirror images, so with only
## their own surviving plates the boundary between nearest centres fell exactly on the join - the
## seam came back as a lattice edge - and the plates cut away on both sides left the cells there half
## again too big. So centres are laid ON the intersection ring at the lattice's own spacing, and
## plates closer to it than `_seam_clear` make room for them: the join then runs through
## the middle of a row of plates, the way any line on a dome does.
## HEXAGONS NEED STAGGERED ROWS. A single row on the ring against the domes' own plates came out
## as a band of rectangles - the row stood square to the rows beside it. So each side of the ring
## gets one more row, a hexagon's row-height away (spacing x sqrt(3)/2) and half a step round,
## and each dome's own plates give way until past it (`_seam_clear`): ring row, side rows and the
## baked lattice beyond make a honeycomb that runs straight over the join.
const ROW_H := 0.866
var _seam_local: Array = []           # the shared set as last handed to the shader (model space)
static var _hex_spacing: float = 0.0

## Centre-to-centre distance of neighbouring plates, measured once from the lattice itself.
static func _spacing() -> float:
	if _hex_spacing <= 0.0:
		var sum := 0.0
		for a in _hex_cells:
			var best := INF
			for b in _hex_cells:
				if a != b:
					best = minf(best, (a as Vector3).distance_to(b))
			sum += best
		_hex_spacing = sum / float(maxi(_hex_cells.size(), 1)) * SHIELD_RADIUS
	return _hex_spacing

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
	add_to_group(GROUP)

## Сколько раз делится грань икосаэдра: ячеек выходит 10·sub²+2, то есть 92 при трёх. Столько
## и читается как «шестиугольный щит» — при большем числе пластины мельчают до ряби.
const DOME_SUB := 3
static var _hex_mesh: ArrayMesh = null
static var _hex_cells: Array = []
static var _hex_keep: PackedFloat32Array = PackedFloat32Array()
static var _hex_rnd: PackedFloat32Array = PackedFloat32Array()

## СКОЛЬКО ПЛАСТИН ОСТАЁТСЯ ВОКРУГ ПОПАДАНИЯ НА ПУСТОМ ЗАРЯДЕ. Семь — это сама пластина и её
## ряд соседей; меньше читается как случайные искры, а не как «щит держится вот здесь».
const KEEP_MIN := 7

## Строится один раз на всю игру: у всех щитов один радиус, значит и купол один и тот же.
static func _hex_geometry() -> ArrayMesh:
	if _hex_mesh == null:
		var built := ShieldHex.build(SHIELD_RADIUS, DOME_SUB)
		_hex_mesh = built["mesh"]
		_hex_cells = built["centers"]
		_hex_rnd = built["rnds"]
		_build_keep_table()
	return _hex_mesh

## Порог близости, при котором вокруг КАЖДОЙ пластины остаётся ровно KEEP_MIN штук.
##
## Одним числом на весь купол это не решается: у двенадцати пятиугольников соседей пять, то есть
## шесть пластин вместо семи, — измерено, на всём плато порогов 0.80…0.90 минимум держится на
## шести. Поэтому порог свой у каждой пластины.
##
## И берём его ПОСЕРЕДИНЕ между последней оставляемой пластиной и первой отбрасываемой, а не
## впритык под первую. Направление центра пластины едет в шейдер ВЕРШИННЫМ ЦВЕТОМ, то есть по
## восемь бит на канал: упаковка сдвигает каждую координату на величину до 1/255, и скалярное
## произведение — уже до полупроцента. Запас в 0.001 меньше этой ошибки, и крайняя пластина
## выпадала — на кадре вместо семи оставалось шесть. Между кольцами провал широкий (0.87 против
## 0.62 у соседних колец), так что середина даёт запас в сотню раз больше нужного.
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
		var last: int = mini(KEEP_MIN - 1, dots.size() - 1)
		var next: int = mini(last + 1, dots.size() - 1)
		_hex_keep[i] = (dots[last] + dots[next]) * 0.5 if next > last else dots[last] - 0.01

func _physics_process(delta: float) -> void:
	if _dome == null:
		return
	if _cd > 0.0:
		_cd -= delta
	if _hit > 0.0:
		_hit = maxf(_hit - delta / HIT_FADE, 0.0)
		_push_hit()
	if _ripple < 1.0:
		_ripple = minf(_ripple + delta / RIPPLE_TIME, 1.0)
		_set_dome_param("ripple", _ripple)
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
	if powered:
		_update_cuts(v)

## Every other LIT dome of the same side whose sphere reaches into this one, in this dome's own axes.
## Domes on one machine stand still in those axes, so the uniforms are written only when the list
## actually changes - a driving machine does not pay a material write per tick for them.
func _update_cuts(v: Node) -> void:
	var side: Variant = v.get("faction") if v != null else null
	var inv: Transform3D = _dome.global_transform.affine_inverse()
	var reach2: float = (2.0 * SHIELD_RADIUS) * (2.0 * SHIELD_RADIUS)
	var r2: float = (SHIELD_RADIUS * CUT_INSET) * (SHIELD_RADIUS * CUT_INSET)
	var found: Array[Vector4] = []
	var merged: Array = []
	for n in get_tree().get_nodes_in_group(GROUP):
		if n == self or found.size() >= CUT_MAX:
			continue
		var other_dome: Node3D = n.get("_dome")
		if not is_instance_valid(other_dome) or not other_dome.visible:
			continue
		var ov: Node = n.call("_vehicle_root")
		if ov != v and (ov == null or ov.get("faction") != side):
			continue
		var c: Vector3 = other_dome.global_position
		if c.distance_squared_to(_dome.global_position) >= reach2:
			continue
		var lc: Vector3 = inv * c
		found.append(Vector4(lc.x, lc.y, lc.z, r2))
		merged.append(n)
	_merged = merged
	if _same_cuts(found):
		return
	_cuts = found
	_update_seam(inv)
	var packed: Array[Vector4] = found.duplicate()
	while packed.size() < CUT_MAX:
		packed.append(Vector4.ZERO)
	_set_dome_param("cut", packed)
	_set_dome_param("cut_n", found.size())

## The shared plate set for the join (see `_seam_zone`). A plate survives when its centre lies outside
## every sphere but its own dome's; it is kept when it lies near one of those spheres. Nearest to a
## join first, so the cap drops the plates the band needs least.
func _update_seam(inv: Transform3D) -> void:
	var r_in: float = SHIELD_RADIUS * CUT_INSET
	var spheres: Array = [[Vector3.ZERO, self]]
	for n in _merged:
		if is_instance_valid(n) and is_instance_valid(n.get("_dome")):
			spheres.append([inv * (n.get("_dome") as Node3D).global_position, n])
	var picked: Array = []                    # [distance to the join, Vector4]
	var clear: float = _seam_clear()
	var zone: float = _seam_zone()
	if spheres.size() > 1:
		for s in spheres.slice(1):
			_ring_points(s[1], inv, spheres, r_in, picked)
		for s in spheres:
			var owner_n: Node = s[1]
			var xf: Transform3D = inv * (owner_n.get("_dome") as Node3D).global_transform
			for i in _hex_cells.size():
				var p: Vector3 = xf * ((_hex_cells[i] as Vector3) * SHIELD_RADIUS)
				var near: float = INF
				var alive: bool = true
				for o in spheres:
					if o[1] == owner_n:
						continue
					if p.distance_to(o[0]) < r_in:
						alive = false
						break
					# Distance to the JOIN - the circle the two spheres meet in - not to the other
					# sphere: with domes two cells apart nearly all of a dome lies within two metres
					# of the other sphere, and that measure cleared the whole lattice away.
					near = minf(near, _ring_dist(p, s[0], o[0]))
				if alive and near >= clear and near < zone + SEAM_MARGIN * _spacing():
					picked.append([near, Vector4(p.x, p.y, p.z, _hex_rnd[i])])
	picked.sort_custom(func(a, b): return a[0] < b[0])
	var packed: Array[Vector4] = []
	for e in picked:
		if packed.size() >= SEAM_MAX:
			break
		packed.append(e[1])
	var n_used: int = packed.size()
	_seam_local = []
	for q in packed:
		_seam_local.append(Vector3(q.x, q.y, q.z))
	while packed.size() < SEAM_MAX:
		packed.append(Vector4.ZERO)
	_set_dome_param("seam_c", packed)
	_set_dome_param("seam_n", n_used)
	_set_dome_param("seam_zone", zone)
	_set_dome_param("seam_clear", clear)
	_set_dome_param("radius", SHIELD_RADIUS)

## Distance from `p` to the circle where two domes of this radius, centred at `ca` and `cb`, meet.
static func _ring_dist(p: Vector3, ca: Vector3, cb: Vector3) -> float:
	var d: float = ca.distance_to(cb)
	if d < 0.001:
		return INF
	var ax: Vector3 = (cb - ca) / d
	var m: Vector3 = (ca + cb) * 0.5
	var rho: float = sqrt(maxf(SHIELD_RADIUS * SHIELD_RADIUS - d * d * 0.25, 0.0))
	var h: float = (p - m).dot(ax)
	var q: float = ((p - m) - ax * h).length()
	return sqrt(h * h + (q - rho) * (q - rho))

## Own plates closer to a join than this give way to the ring and side rows.
func _seam_clear() -> float:
	return _spacing() * (ROW_H + 0.55)

## Where the shared lattice is drawn: past the side rows by most of a plate, so their cells are whole.
func _seam_zone() -> float:
	return _spacing() * (ROW_H + 0.75)

## Plate centres along the circle where this dome and `other` meet, into `picked` at distance 0.
## Built in WORLD space from the pair ordered by instance id and the machine's own up, so both domes
## lay the very same points and give each the same random number - one plate, drawn from both sides.
func _ring_points(other: Node, inv: Transform3D, spheres: Array, r_in: float, picked: Array) -> void:
	var lo: Node = self if get_instance_id() < other.get_instance_id() else other
	var hi: Node = other if lo == self else self
	var ca: Vector3 = (lo.get("_dome") as Node3D).global_position
	var cb: Vector3 = (hi.get("_dome") as Node3D).global_position
	var d: float = ca.distance_to(cb)
	if d < 0.01 or d >= 2.0 * SHIELD_RADIUS:
		return
	var axis: Vector3 = (cb - ca) / d
	var v: Node = _vehicle_root()
	var ref: Vector3 = (v as Node3D).global_basis.y if v is Node3D else Vector3.UP
	if absf(ref.normalized().dot(axis)) > 0.9:
		ref = (v as Node3D).global_basis.x if v is Node3D else Vector3.RIGHT
	var u: Vector3 = axis.cross(ref).normalized()
	var w: Vector3 = axis.cross(u)
	var mid: Vector3 = (ca + cb) * 0.5
	var rho: float = sqrt(maxf(SHIELD_RADIUS * SHIELD_RADIUS - d * d * 0.25, 0.0))
	var k_n: int = maxi(3, roundi(TAU * rho / _spacing()))
	for k in k_n:
		var th: float = TAU * float(k) / float(k_n)
		var p: Vector3 = inv * (mid + (u * cos(th) + w * sin(th)) * rho)
		# A third dome may swallow part of the ring.
		var alive: bool = true
		for o in spheres:
			if o[1] == self or o[1] == other:
				continue
			if p.distance_to(o[0]) < r_in:
				alive = false
				break
		if alive:
			picked.append([0.0, _seam_pt(p, k, k_n, 0)])
	# One staggered row on each sphere, a row-height further from the join along the surface.
	var a0: float = acos(clampf(d * 0.5 / SHIELD_RADIUS, -1.0, 1.0))
	var a1: float = a0 + _spacing() * ROW_H / SHIELD_RADIUS
	for side in [[ca, axis, 1], [cb, -axis, 2]]:
		var c0: Vector3 = side[0]
		var ax: Vector3 = side[1]
		var r1: float = SHIELD_RADIUS * sin(a1)
		var ctr: Vector3 = c0 + ax * (SHIELD_RADIUS * cos(a1))
		var n1: int = maxi(3, roundi(TAU * r1 / _spacing()))
		for k in n1:
			var th: float = TAU * (float(k) + 0.5) / float(n1)
			var p: Vector3 = inv * (ctr + (u * cos(th) + w * sin(th)) * r1)
			var alive: bool = true
			for o in spheres:
				if (o[1] == lo and side[2] == 1) or (o[1] == hi and side[2] == 2):
					continue
				if p.distance_to(o[0]) < r_in:
					alive = false
					break
			if alive:
				picked.append([_spacing() * ROW_H, _seam_pt(p, k, n1, side[2])])

## A shared plate with its random number, derived from where it stands in its row - both domes lay
## the same rows in the same order, so both draw it the same.
static func _seam_pt(p: Vector3, k: int, n: int, row: int) -> Vector4:
	var rnd: float = fposmod(sin(float(k) * 12.9898 + float(n) * 78.233 + float(row) * 37.719) * 43758.5453, 1.0)
	return Vector4(p.x, p.y, p.z, roundf(rnd * 255.0) / 255.0)

func _same_cuts(found: Array[Vector4]) -> bool:
	if found.size() != _cuts.size():
		return false
	for i in found.size():
		if (found[i] - _cuts[i]).length_squared() > 0.0001:
			return false
	return true

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
	# The struck plate as a WORLD point, handed to every dome of the hull: each one draws the flare,
	# the cap and the ripple around it in its own axes, so a ring that starts here crosses the join.
	var cell_local: Vector3 = (_hex_cells[i] as Vector3) * SHIELD_RADIUS
	# Near the join the plate under the shot may be one of the SHARED set (a ring plate, or the
	# neighbour's) rather than one of ours - the flare has to land on the plate that is drawn there.
	var on_sphere: Vector3 = local.normalized() * SHIELD_RADIUS
	var best: float = on_sphere.distance_squared_to(cell_local)
	for q in _seam_local:
		var dq: float = on_sphere.distance_squared_to(q)
		if dq < best:
			best = dq
			cell_local = q
	var at: Vector3 = _dome.global_transform * cell_local
	_take_hit(at, _hex_keep[i])
	for n in _merged:
		if is_instance_valid(n) and n.has_method("_take_hit"):
			n._take_hit(at, _hex_keep[i], true)

## One hull's hit, in this dome's axes. `shared`: it landed on a merged neighbour - the flare is
## raised here too, since the struck plate may be drawn on this dome's side of the join.
func _take_hit(world_cell: Vector3, keep_cos: float, shared: bool = false) -> void:
	if _dome == null:
		return
	var p: Vector3 = _dome.global_transform.affine_inverse() * world_cell
	_set_dome_param("hit_pos", p)
	# И ГРАНИЦА ШАПКИ — ВМЕСТЕ С НЕЙ. Купол держит пластины вокруг последнего попадания, а
	# сколько их там окажется, зависит от того, в какую именно пластину пришло (см. _hex_keep).
	_set_dome_param("keep_cos", keep_cos)
	if shared:
		_hit = 1.0
		_push_hit()
	if _ripple >= RIPPLE_RESTART:
		_ripple = 0.0
		_set_dome_param("ripple_pos", p)
		_set_dome_param("ripple", _ripple)

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
