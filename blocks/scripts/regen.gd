# regen.gd — блок регенерации: раз в интервал чинит повреждённые блоки В РАДИУСЕ, тратя
# энергию своей машины (vehicle.energy_consume). Нет энергии — не чинит.
#
# ЧИНИТ ВСЁ, ДО ЧЕГО ДОТЯГИВАЕТСЯ, а не только свою машину: блок, лежащий на земле, блок
# другой твоей машины, блок ВРАЖЕСКОЙ машины — тоже. И наоборот: вражеский реген лечит блоки
# игрока. Это не недосмотр, а правило — поле маленькое (REGEN_RADIUS), и чтобы им зацепить
# чужую технику, надо стоять к ней вплотную; зато починить сбитый борт соседней машины или
# подобранный хлам можно, не разбирая половину сборки.
extends VehicleBlock

const REGEN_RADIUS := 4.6      # м: как далеко достаёт
## THE UNIT MENDS A BUDGET OF HIT POINTS A SECOND, SHARED BY WHAT IS BROKEN (the player's numbers):
## one damaged block takes all of it, ten take a tenth each. It used to be a fixed 12 per block per
## tick for 2 energy, so a big battered hull drew the most repair and the most energy exactly when
## the unit was spread thinnest - and a lone block under fire got the same 12 as one of thirty.
const REGEN_RATE := 135.0      # HP a second, split between the damaged blocks in the field
const REGEN_HP_PER_ENERGY := 1.5
const REGEN_INTERVAL := 1.0    # с между тиками

## Яркость поля: рабочая и «энергии нет». Поле показывает РАДИУС и то, что блок работает;
## моргать ради привлечения внимания оно не должно, поэтому переход плавный.
const FIELD_ALPHA := 0.09
const FIELD_ALPHA_DEAD := 0.03
## За сколько секунд поле переходит между этими двумя состояниями.
const FIELD_FADE := 0.4

## What a faction's own repair unit changes (regen_marlit.gd sets them in _init): how far the field
## reaches, how many hit points it mends a second and at what price, how many blocks one tick can
## take, and where in the block the field's centre is - a 2x2x2 block's anchor is its corner.
var field_radius: float = REGEN_RADIUS
var heal_rate: float = REGEN_RATE
var hp_per_energy: float = REGEN_HP_PER_ENERGY
var max_bodies: int = FIELD_MAX_BODIES
var field_centre: Vector3 = Vector3.ZERO

var _timer: float = 0.0
var _field: MeshInstance3D = null
var _field_mat: ShaderMaterial = null
var _alpha: float = FIELD_ALPHA_DEAD

func _ready() -> void:
	super._ready()
	# EVERY UNIT ON ITS OWN BEAT. With one start value all of them fired in the same physics tick:
	# measured, five units over a battered hull put 35-47 ms of work into one tick a second - a
	# hitch, not a load. A random phase spreads it over the second.
	_timer = randf() * REGEN_INTERVAL
	_build_field()
	_build_digits()
	_setup_beacon()

# ── THE BEACON ──────────────────────────────────────────────────────────────────
# The model says whether the field works: powered, the RING spins up and the CRYSTAL glows green
# and floats; every repair tick that heals something flashes it; unpowered, the ring runs down and
# the crystal goes dark. `Ring` and `Crystal` move (moving_parts), the crystal is re-coloured and
# so draws itself (unbatched).
const RING_SPIN := 1.8             # rad/s at full power
const RING_SPIN_UP := 1.2          # rad/s² - it winds up and runs down, it does not snap
const CRYSTAL_ON := Color(0.35, 1.0, 0.5)
const CRYSTAL_HEAL := Color(0.85, 1.0, 0.85)
const CRYSTAL_OFF := Color(0.07, 0.16, 0.1)
const BOB := 0.025                 # m the crystal floats while powered
const HEAL_FLASH := 0.3            # s
var _ring: Node3D = null
var _crystal: MeshInstance3D = null
var _crystal_mat: StandardMaterial3D = null
var _crystal_y: float = 0.0
var _crystal_col: Color = CRYSTAL_OFF
var _spin: float = 0.0
var _bob: float = 0.0
var _heal_flash: float = 0.0

func unbatched() -> Array:
	var c := get_node_or_null("Crystal")
	return [c] if c != null else []

func _setup_beacon() -> void:
	moving_parts = true
	_ring = get_node_or_null("Ring") as Node3D
	_crystal = get_node_or_null("Crystal") as MeshInstance3D
	if _crystal != null:
		_crystal_y = _crystal.position.y
		var m: Material = _crystal.material_override
		if m == null and _crystal.mesh != null:
			m = _crystal.mesh.surface_get_material(0)
		if m is StandardMaterial3D:
			_crystal_mat = (m as StandardMaterial3D).duplicate()
			_crystal_mat.albedo_color = _crystal_col
			_crystal.material_override = _crystal_mat

func _animate_beacon(delta: float, on: bool) -> void:
	if _ring == null:
		return
	_spin = move_toward(_spin, RING_SPIN if on else 0.0, delta * RING_SPIN_UP)
	if _spin > 0.001:
		_ring.rotate_y(_spin * delta)
	_heal_flash = maxf(_heal_flash - delta / HEAL_FLASH, 0.0)
	if _crystal == null:
		return
	_bob = move_toward(_bob, 1.0 if on else 0.0, delta * 1.5)
	var t: float = Time.get_ticks_msec() / 1000.0
	_crystal.position.y = _crystal_y + BOB * _bob * sin(t * 2.2)
	if _bob > 0.001:
		_crystal.rotate_y(delta * 0.9 * _bob)
	if _crystal_mat != null:
		var target: Color = CRYSTAL_ON if on else CRYSTAL_OFF
		target = target.lerp(CRYSTAL_HEAL, _heal_flash)
		_crystal_col = _crystal_col.lerp(target, clampf(delta * 8.0, 0.0, 1.0))
		if not _crystal_mat.albedo_color.is_equal_approx(_crystal_col):
			_crystal_mat.albedo_color = _crystal_col

# ── The field and the digits ─────────────────────────────────────────────────
# The FIELD is a sphere of exactly `field_radius` (regen_field.gdshader): a rim, a thin grid and a
# band running over it - it says how far the unit reaches and that it is powered. The REPAIR is said
# by DIGITS: ONE 0/1 card for every HP_PER_DIGIT hit points a tick mends (the player: "as many as
# the heal, not as many as the blocks"), at least one per block mended, appearing anywhere in the field,
# hang there a moment and fly to the block along an arc; the hit points land WITH them
# (`_land`), so the block's damage overlay greens the moment the digits arrive. They used to be a
# cloud of ninety cards orbiting the field for good and one glitch bolt per heal - the player wanted
# a plain, pretty field and the repair visible as something that travels.
#
# The digits are ONE MultiMesh per unit, a pool of cards moved on the CPU while any is in flight: no
# node is made per heal (the old bolt made one, and it was 40% of the unit's work). The pool holds a
# full budget twice over (a flight outlives the tick) plus one per block, since a fixed 96 ran out
# under the Marlit unit and the rest healed with nothing flying.
const HP_PER_DIGIT := 5
const DIGITS_MAX_PER_HEAL := 40    # one block's share of a tick, the whole budget at most
const DIGIT_SIZE := 0.32
const DIGIT_SPAWN := 0.35          # s the digits hang at the core, blinking in
const DIGIT_FLY := 0.7             # s to the block
const DIGIT_FADE := 0.15           # s they burn out on it
const DIGIT_SPREAD := 0.9         # share of the field's radius they appear within
const DIGIT_ARC := 0.9             # m the path bows upward
const PULSE_FADE := 0.4            # s the field brightens for when a repair lands

var _digits: MultiMeshInstance3D = null
var _flights: Array = []           # {slot, group, start, ctrl, t, seed}
var _groups: Dictionary = {}       # block instance id -> {block, hp, left}
var _free: Array[int] = []
var _pulse: float = 0.0
var _digits_dirty := false

func _build_field() -> void:
	_field = MeshInstance3D.new()
	var sph := SphereMesh.new()
	sph.radius = field_radius
	sph.height = field_radius * 2.0
	sph.radial_segments = 32
	sph.rings = 16
	_field.mesh = sph
	_field_mat = ShaderMaterial.new()
	_field_mat.shader = preload("res://regen_field.gdshader")
	_field_mat.set_shader_parameter("active", 0.0)
	_field.material_override = _field_mat
	_field.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_field.position = field_centre
	_field.set_meta("block_fx", true)       # not part of the block's size (see _local_aabb)
	add_child(_field)

func _build_digits() -> void:
	_digits = MultiMeshInstance3D.new()
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_custom_data = true
	var q := QuadMesh.new()
	q.size = Vector2(DIGIT_SIZE, DIGIT_SIZE)
	mm.mesh = q
	var pool: int = 2 * ceili(heal_rate * REGEN_INTERVAL / float(HP_PER_DIGIT)) + max_bodies
	mm.instance_count = pool
	for i in pool:
		mm.set_instance_transform(i, Transform3D(Basis().scaled(Vector3.ZERO), Vector3.ZERO))
		mm.set_instance_custom_data(i, Color(0, randf(), 0, 0))
		_free.append(i)
	_digits.multimesh = mm
	var mat := ShaderMaterial.new()
	mat.shader = preload("res://regen_digit.gdshader")
	_digits.material_override = mat
	_digits.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# The instances move, so the box is set by hand: the whole field, where every flight stays.
	_digits.custom_aabb = AABB(Vector3.ONE * -field_radius, Vector3.ONE * (field_radius * 2.0))
	_digits.position = field_centre
	_digits.set_meta("block_fx", true)
	add_child(_digits)

## Send digits to mend `b` by `hp`, one per HP_PER_DIGIT. A block with digits still flying gets its
## new ones in the same group and its hit points land with the last of them. False when the pool has
## no room at all: the caller heals at once.
func _launch(b: Node3D, hp: int) -> bool:
	var id: int = b.get_instance_id()
	var want: int = clampi(ceili(float(hp) / float(HP_PER_DIGIT)), 1, DIGITS_MAX_PER_HEAL)
	var n: int = mini(want, _free.size()) if _digits != null else 0
	if _groups.has(id):
		_groups[id]["hp"] = int(_groups[id]["hp"]) + hp
		_groups[id]["left"] = int(_groups[id]["left"]) + n
	elif n <= 0:
		return false
	else:
		_groups[id] = {"block": b, "hp": hp, "left": n}
	for k in n:
		# Anywhere inside the field (uniform in its volume: the cube root), not at the core: a whole
		# swarm leaving one point read as a fountain, not as the field doing the work.
		var start := Vector3(randf_range(-1, 1), randf_range(-1, 1), randf_range(-1, 1)).normalized() \
				* field_radius * DIGIT_SPREAD * pow(randf(), 1.0 / 3.0)
		_flights.append({"slot": _free.pop_back(), "group": id, "start": start,
			"t": -k * minf(0.08, 0.5 / float(n)), "side": randf_range(-0.5, 0.5), "seed": randf()})
	return true

func _process(delta: float) -> void:
	if _pulse > 0.0:
		_pulse = maxf(_pulse - delta / PULSE_FADE, 0.0)
		if _field_mat != null:
			_field_mat.set_shader_parameter("pulse", _pulse)
	if _flights.is_empty():
		if _digits_dirty:
			_digits_dirty = false
			var mm0 := _digits.multimesh
			for i in mm0.instance_count:
				mm0.set_instance_custom_data(i, Color(0, 0, 0, 0))
		return
	_digits_dirty = true
	var mm: MultiMesh = _digits.multimesh
	var total: float = DIGIT_SPAWN + DIGIT_FLY + DIGIT_FADE
	var keep: Array = []
	for f in _flights:
		f["t"] += delta
		var t: float = f["t"]
		var g: Dictionary = _groups.get(f["group"], {})
		var b = g.get("block")
		# A block still alive but out of the tree (its machine taken off in a round reset, a block on
		# its way to being freed) is gone as far as a flight goes: it has no global position, and
		# asking for one is an engine error a frame.
		var gone: bool = not is_instance_valid(b) or not (b as Node).is_inside_tree()
		if t >= total or gone:
			# A long frame can carry a flight from the air straight past its end: it still lands, or
			# the group stayed in `_groups` and that block was never mended by this unit again.
			if not f.get("landed", false):
				f["landed"] = true
				if not gone:
					_land(f["group"])
				else:
					_groups.erase(f["group"])
			mm.set_instance_transform(f["slot"], Transform3D(Basis().scaled(Vector3.ZERO), Vector3.ZERO))
			mm.set_instance_custom_data(f["slot"], Color(0, f["seed"], 0, 0))
			_free.append(f["slot"])
			continue
		keep.append(f)
		var target: Vector3 = _digits.to_local((b as Node3D).global_position)
		var pos: Vector3 = f["start"]
		var alpha := 1.0
		var size := 1.0
		if t < 0.0:
			alpha = 0.0
		elif t < DIGIT_SPAWN:
			var k: float = t / DIGIT_SPAWN
			size = k
			alpha = k * (0.6 + 0.4 * float(int(t * 30.0) % 2))   # blinks in
		elif t < DIGIT_SPAWN + DIGIT_FLY:
			var u: float = (t - DIGIT_SPAWN) / DIGIT_FLY
			u = u * u * (3.0 - 2.0 * u)
			var mid: Vector3 = (f["start"] + target) * 0.5 + Vector3.UP * DIGIT_ARC
			var span: Vector3 = target - f["start"]
			if span.length_squared() > 0.0001:
				mid += span.cross(Vector3.UP).normalized() * float(f["side"])
			pos = (f["start"] as Vector3).lerp(mid, u).lerp(mid.lerp(target, u), u)
		else:
			if not f.get("landed", false):
				f["landed"] = true
				_land(f["group"])
			var k2: float = (t - DIGIT_SPAWN - DIGIT_FLY) / DIGIT_FADE
			pos = target
			alpha = 1.0 - k2
			size = 1.0 + k2 * 0.8
		mm.set_instance_transform(f["slot"], Transform3D(Basis().scaled(Vector3.ONE * size), pos))
		mm.set_instance_custom_data(f["slot"], Color(alpha, f["seed"], 0, 0))
	_flights = keep

## A digit reached its block; the last of its group brings the hit points.
func _land(group: int) -> void:
	var g: Dictionary = _groups.get(group, {})
	if g.is_empty():
		return
	g["left"] = int(g["left"]) - 1
	if int(g["left"]) > 0:
		return
	_groups.erase(group)
	var b = g.get("block")
	if is_instance_valid(b):
		_mend(b, int(g["hp"]))
	_pulse = 1.0

func _mend(b: Node, hp: int) -> void:
	b.current_hp = mini(b.current_hp + hp, b.max_hp)
	if b.has_method("on_repaired"):
		b.on_repaired()
	# THE REPAIR IS SHOWN BY THE DAMAGE OVERLAY ITSELF: digits that stop being red green and fade.
	if b.has_method("_refresh_hp_fx"):
		b._refresh_hp_fx()

func _physics_process(delta: float) -> void:
	_animate_beacon(delta, _work(delta))

## The field's tick; true while it is powered and mounted.
func _work(delta: float) -> bool:
	if freeze == false:
		_show_field(false)
		return false                         # валяется в мире — не работает
	var blocks_node := get_parent()
	if blocks_node == null or blocks_node.name != "blocks":
		_show_field(false)
		return false
	var vehicle := blocks_node.get_parent()
	if vehicle == null or not vehicle.has_method("energy_consume"):
		_show_field(false)
		return false
	# Нехватку энергии показываем ПРИГЛУШЕНИЕМ, а не включением-выключением.
	#
	# Мигало здесь по двум причинам, и обе убраны. Первая: поле вспыхивало на каждый ремонт —
	# раз в секунду, бесконечно, пока идёт починка. Вторая и куда хуже: видимость гонялась
	# напрямую от energy_available(), а та скачет через ноль КАЖДЫЙ тик — выработка панели
	# приходит по капле за кадр, а реген снимает 2.0 разом. Сфера моргала с частотой кадров.
	# Теперь яркость едет к цели плавно, и дрожание источника до картинки не доходит.
	# БЕЗ ЭНЕРГИИ ПОЛЯ НЕТ ВОВСЕ. Раньше оно лишь тускнело, и обесточенный реген выглядел
	# работающим: игрок видел купол и ждал починки, которой не будет. Показываем ровно то,
	# что происходит, — как это делает щит (shield.gd прячет свой купол по тому же признаку).
	var powered: bool = vehicle.has_method("energy_available") and vehicle.energy_available() > 0.0
	_show_field(powered)
	if not powered:
		return false
	_fade_field(delta, FIELD_ALPHA)
	_timer -= delta
	if _timer > 0.0:
		return true
	_timer = REGEN_INTERVAL
	# Кого чинить, спрашиваем У ФИЗИКИ, а не у своего узла blocks: раньше перебирались только
	# соседи по машине, и поле, накрывшее лежащий на земле блок или борт стоящей рядом машины,
	# не делало с ними ничего. Слой 2 — это блоки, все и всюду: на машине, на базе, в мире.
	# СЕБЯ ТОЖЕ ЧИНИМ: the unit is one of the blocks in its field, or a shot-up unit stays shot up.
	# A block with digits still on the way is charged again, and what it is given rides with the
	# digits already flying (`pending`): a flight lasts longer than the tick, so waiting for it to
	# land skipped every other tick and a lone damaged block got half the budget.
	var pending: Dictionary = {}
	for id in _groups:
		pending[id] = int(_groups[id]["hp"])
	var need: Array = []
	for b in _blocks_in_field():
		if b.current_hp + int(pending.get(b.get_instance_id(), 0)) < b.max_hp:
			need.append(b)
	if need.is_empty():
		return true
	if need.size() > max_bodies:
		var c: Vector3 = to_global(field_centre)
		need.sort_custom(func(a, b): return (a as Node3D).global_position.distance_squared_to(c) < (b as Node3D).global_position.distance_squared_to(c))
		need.resize(max_bodies)
	# The budget, cut to what the machine can pay for; paid in full before anything flies.
	var budget: float = heal_rate * REGEN_INTERVAL
	if vehicle.has_method("energy_available"):
		budget = minf(budget, float(vehicle.energy_available()) * hp_per_energy)
	var shares: Dictionary = _share(need, int(budget), pending)
	var total := 0
	for id in shares:
		total += int(shares[id])
	if total <= 0:
		return true
	vehicle.energy_consume(float(total) / hp_per_energy)
	for b in need:
		var id: int = b.get_instance_id()
		var hp: int = int(shares.get(id, 0))
		if hp <= 0:
			continue
		if not _launch(b, hp):
			_mend(b, hp)
	_heal_flash = 1.0
	return true

## The budget split evenly between the blocks, none given more than it is missing, what one did not
## need handed on to the rest (water filling). Every pass gives at least one point to someone, so
## it ends. instance id -> hit points.
static func _share(blocks: Array, budget: int, pending: Dictionary = {}) -> Dictionary:
	var out: Dictionary = {}
	var open: Array = blocks.duplicate()
	var left: int = budget
	while left > 0 and not open.is_empty():
		var each: int = maxi(left / open.size(), 1)
		var still: Array = []
		for b in open:
			if left <= 0:
				break
			var id: int = b.get_instance_id()
			var missing: int = b.max_hp - b.current_hp - int(pending.get(id, 0)) - int(out.get(id, 0))
			var give: int = mini(mini(each, missing), left)
			out[id] = int(out.get(id, 0)) + give
			left -= give
			if missing > give:
				still.append(b)
		open = still
	return out

## How many DAMAGED blocks one tick shares its budget between (`max_bodies`, the nearest first).
const FIELD_MAX_BODIES := 32
## What the sphere query may return at all. It counts every block in the field, whole ones and
## batteries included: when this was the damaged cap too, a dense hull filled it with sound blocks
## and measured, four of ten damaged ones were never asked about.
const FIELD_QUERY_MAX := 160

func _blocks_in_field() -> Array:
	var world := get_world_3d()
	if world == null:
		return []
	var sphere := SphereShape3D.new()
	sphere.radius = field_radius
	var q := PhysicsShapeQueryParameters3D.new()
	q.shape = sphere
	q.transform = Transform3D(Basis(), to_global(field_centre))
	q.collision_mask = 2                      # слой блоков (VehicleBlock.collision_layer = 2)
	q.collide_with_bodies = true
	var out: Array = []
	for hit in world.direct_space_state.intersect_shape(q, FIELD_QUERY_MAX):
		var b = hit.get("collider")
		if b is Node3D and ("current_hp" in b) and ("max_hp" in b):
			out.append(b)
	return out

func _show_field(on: bool) -> void:
	if _field != null and _field.visible != on:
		_field.visible = on

# Плавный переход яркости к цели. Что блок РАБОТАЕТ, и так видно по зелёным цифрам на самих
# чинимых блоках (зелёные цифры) — полю мигать ради этого незачем, оно показывает радиус.
func _fade_field(delta: float, target: float) -> void:
	if _field_mat == null:
		return
	_alpha = move_toward(_alpha, target, delta * (FIELD_ALPHA - FIELD_ALPHA_DEAD) / FIELD_FADE)
	_field_mat.set_shader_parameter("active", _alpha / maxf(FIELD_ALPHA, 0.001))
