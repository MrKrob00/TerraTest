extends VehicleBlock
# WIRELESS CHARGER — переливает энергию в аккумулятор ДРУГОЙ машины игрока.
#
# Свою машину игнорирует намеренно: внутри одной машины энергия и так общая
# (MachineBody.energy_produce/consume), заряжать самого себя нечего.
#
# Получателю ОБЯЗАТЕЛЕН аккумулятор — без него энергию некуда положить: ёмкость машины
# складывается из батарей, и у машины без них energy_cap() равен нулю, то есть перелив ушёл
# бы в пустоту.
#
# Ищем при этом именно БЛОК аккумулятора, а не ёмкость машины, хотя проверка ёмкости была бы
# общее и сама распространялась на будущие накопители. Причина — луч: он обязан упираться в
# то, что заряжается, а ёмкость машины не говорит, ГДЕ это. Появятся другие накопители —
# добавлять их сюда придётся руками, и это осознанная плата за верную картинку.

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
	var best_d: float = RANGE
	for v in vehicles.get_children():
		if v == mine or not (v is Node3D) or not is_instance_valid(v):
			continue
		var f = v.get("faction")
		if f == null or int(f) != 0:
			continue                      # только машины ИГРОКА
		var blocks: Node = v.get_node_or_null("blocks")
		if blocks == null:
			continue
		for b in blocks.get_children():
			if not (b is Node3D) or b.get("block") == null:
				continue
			if int(b.get("block")) != G.Block.BATTERY:
				continue
			var d: float = global_position.distance_to((b as Node3D).global_position)
			if d < best_d:
				best_d = d
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
	var len: float = from.distance_to(to)
	if len < 0.05:
		_show_beam(false)
		return
	_beam.global_position = mid
	# Цилиндр растёт по Y — разворачиваем его вдоль отрезка. look_at вырождается, если
	# направление почти вертикально, поэтому в этом случае оставляем поворот как есть.
	var dir: Vector3 = (to - from).normalized()
	if absf(dir.dot(Vector3.UP)) < 0.99:
		_beam.look_at(to, Vector3.UP)
		_beam.rotate_object_local(Vector3.RIGHT, PI * 0.5)
	(_beam.mesh as CylinderMesh).height = len
	# Пульсация — по ней видно, что энергия ИДЁТ, а не что луч просто нарисован.
	_t += 0.05
	_beam_mat.emission_energy_multiplier = 3.0 + 2.0 * sin(_t * 6.0)
