extends VehicleBlock
# WIRELESS CHARGER: pours energy into the battery of ANOTHER machine of ITS OWN FACTION.
#
# Own machine is skipped on purpose - inside one machine energy is already shared.
#
# OWN FACTION, not "the player". A hardcoded faction == 0 made this a mechanic the enemy silently
# lacked (CLAUDE.md rule 7); blocks here are shared, and the shielded tower quests stand on exactly
# this - charge towers hold the dome up by ordinary energy transfer, not by quest code.
#
# The receiver MUST have a battery: machine capacity is the sum of its batteries, so without one
# energy_cap() is zero and the transfer goes nowhere.
#
# We look for the battery BLOCK rather than machine capacity, even though capacity would be the
# general check: the beam has to end on the thing being charged, and capacity does not say WHERE
# that is. New storage blocks will have to be added here by hand - the price of a correct picture.

## Радиус действия в метрах (решение игрока).
const RANGE := 6.0
## Сколько энергии в секунду переливаем.
const RATE := 12.0
## Как часто ищем получателя. Каждый кадр перебирать машины незачем — они не телепортируются.
const SCAN_PERIOD := 0.5

var _scan_t: float = 0.0
var _target: Node = null            # машина-получатель (ей отдаём энергию)
var _target_cell: Node3D = null     # её АККУМУЛЯТОР — к нему тянется луч
var _beam: MeshInstance3D = null
var _beam_mat: StandardMaterial3D = null
var _t: float = 0.0

func _ready() -> void:
	super._ready()
	_build_beam()

func _physics_process(delta: float) -> void:
	var mine: Node = _machine()
	if mine == null:
		_show_beam(false)
		return
	_scan_t -= delta
	if _scan_t <= 0.0:
		_scan_t = SCAN_PERIOD
		_target_cell = _find_battery(mine)
		_target = _machine_of(_target_cell)
	if _target == null or not is_instance_valid(_target) \
			or _target_cell == null or not is_instance_valid(_target_cell):
		_show_beam(false)
		return
	# Полному получателю не льём: всё, что не влезло в его ёмкость, просто сгорает в его же
	# тике, а у донора энергия при этом уже списана — вечная утечка на стоящей рядом машине.
	if _target.has_method("energy_fill") and _target.energy_fill() >= 0.999:
		_show_beam(false)
		return
	# Берём энергию у СВОЕЙ машины и кладём получателю. Отдаём ровно столько, сколько
	# реально сняли: energy_consume возвращает выданное, и если у нас пусто — перелива нет.
	var want: float = RATE * delta
	var got: float = mine.energy_consume(want) if mine.has_method("energy_consume") else 0.0
	if got <= 0.0:
		_show_beam(false)
		return
	if _target.has_method("energy_produce"):
		_target.energy_produce(got)
	_show_beam(true)
	_aim_beam(_target_cell.global_position)

# Ближайший АККУМУЛЯТОР на чужой машине игрока в радиусе.
#
# Ищем сам блок, а не машину: он же и конец луча. Целиться в начало координат машины было
# неверно — та точка лежит в её геометрическом центре и к аккумулятору отношения не имеет,
# из-за чего луч упирался в произвольное место корпуса. Заодно расстояние меряется до того,
# что реально заряжается, а не до центра машины.
func _find_battery(mine: Node) -> Node3D:
	var vehicles: Node = get_node_or_null("/root/Main/Vehicles")
	if vehicles == null:
		return null
	var best: Node3D = null
	# В КВАДРАТЕ: сравниваем с distance_squared_to. Здесь стояло само RANGE, то есть радиус
	# на деле был √6 ≈ 2.4 м — машины почти вплотную, и зарядка «не работала».
	var best_d2: float = RANGE * RANGE
	var my_f = mine.get("faction")
	var mine_faction: int = int(my_f) if my_f != null else 0
	for v in vehicles.get_children():
		if v == mine or not (v is Node3D) or not is_instance_valid(v):
			continue
		var f = v.get("faction")
		if f == null or int(f) != mine_faction:
			continue                      # только машины СВОЕЙ фракции
		var blocks: Node = v.get_node_or_null("blocks")
		if blocks == null:
			continue
		for b in blocks.get_children():
			if not (b is Node3D) or b.get("block") == null:
				continue
			if int(b.get("block")) != G.Block.BATTERY:
				continue
			var d2: float = global_position.distance_squared_to((b as Node3D).global_position)
			if d2 < best_d2:
				best_d2 = d2
				best = b as Node3D
	return best

func _machine_of(n: Node) -> Node:
	var p: Node = n
	while p != null and not (p is MachineBody):
		p = p.get_parent()
	return p

func _machine() -> Node:
	var p: Node = get_parent()
	while p != null and not (p is MachineBody):
		p = p.get_parent()
	return p

# ── Луч передачи ─────────────────────────────────────────────────────────────
# Без него работа блока невидима: цифры энергии живут в другом углу экрана, и понять,
# что перелив вообще идёт, было бы нельзя.
func _build_beam() -> void:
	_beam = MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.05
	cyl.bottom_radius = 0.05
	cyl.height = 1.0
	cyl.radial_segments = 6
	_beam_mat = StandardMaterial3D.new()
	_beam_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_beam_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_beam_mat.albedo_color = Color(0.35, 0.9, 1.0, 0.75)
	_beam_mat.emission_enabled = true
	_beam_mat.emission = Color(0.35, 0.9, 1.0)
	_beam_mat.emission_energy_multiplier = 4.0
	cyl.material = _beam_mat
	_beam.mesh = cyl
	_beam.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_beam.top_level = true               # тянется в МИРОВЫХ координатах, между двумя машинами
	_beam.visible = false
	add_child(_beam)

func _show_beam(on: bool) -> void:
	if _beam != null and _beam.visible != on:
		_beam.visible = on

func _aim_beam(to: Vector3) -> void:
	if _beam == null:
		return
	var from: Vector3 = global_position
	var mid: Vector3 = (from + to) * 0.5
	var beam_len: float = from.distance_to(to)
	if beam_len < 0.05:
		_show_beam(false)
		return
	_beam.global_position = mid
	# Цилиндр растёт по Y — разворачиваем его вдоль отрезка. look_at вырождается, если
	# направление почти вертикально, поэтому в этом случае оставляем поворот как есть.
	var dir: Vector3 = (to - from).normalized()
	if absf(dir.dot(Vector3.UP)) < 0.99:
		_beam.look_at(to, Vector3.UP)
		_beam.rotate_object_local(Vector3.RIGHT, PI * 0.5)
	(_beam.mesh as CylinderMesh).height = beam_len
	# Пульсация — по ней видно, что энергия ИДЁТ, а не что луч просто нарисован.
	_t += 0.05
	_beam_mat.emission_energy_multiplier = 3.0 + 2.0 * sin(_t * 6.0)
