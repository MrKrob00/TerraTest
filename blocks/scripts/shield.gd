# shield.gd — блок щита: держит сферический купол вокруг себя. Купол ловит вражеские
# снаряды/лучи (он на слое блоков) и за каждое попадание списывает энергию машины:
# урон × SHIELD_COST_X. Энергии нет — купол гаснет и уходит на перезагрузку (SHIELD_BREAK_CD).
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
const SHIELD_BREAK_CD := 2.0   # a dome that broke or ran dry stays down this long (a reboot)

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
## The per-plate table (shield_dome.gdshader `seam_tex`): up to SEAM_ROW centres within SEAM_NEAR
## spacings of the plate's own centre. A plate reaches about 0.6 of a spacing from its centre and
## the centre that owns a point is at most as far again, so 1.7 always holds the owner.
const SEAM_ROW := 16
const SEAM_NEAR := 1.7
var _seam_local: Array = []           # the hull's centres in this dome's model space (hit snapping)
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
	_setup_emitter()

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

# ── THE EMITTER ─────────────────────────────────────────────────────────────────
# The block itself says what the dome is doing, so a shield on a machine can be read from its
# model even where the dome is off screen: the cap LIFTS and turns while the dome stands and the
# core shows cyan through the gap; after running dry it REBOOTS for SHIELD_BREAK_CD - cap shut,
# core blinking amber - and flashes white the moment the dome comes back; unpowered it is dark
# and still. Parts: `Cap` moves (moving_parts, so the batch copies it every frame), `Core` is
# re-coloured and drawn by itself (unbatched). The lift matches art/emitter_models.py SHIELD_LIFT.
const CAP_LIFT := 0.09
const CAP_SPIN := 0.7              # rad/s while the dome stands
const CAP_SPIN_BOOT := 5.0         # rad/s the cap winds up to by the end of a reboot
const CORE_ON := Color(0.35, 0.85, 1.0)
const CORE_BOOT := Color(1.0, 0.6, 0.15)
const CORE_OFF := Color(0.07, 0.09, 0.13)
const BOOT_BLINK := 3.0            # blinks a second while rebooting
const BOOT_FLASH := 0.35           # s of white when the dome comes back
const REBOOT_LIFT := 0.6           # share of CAP_LIFT the cap opens to while rebooting
var _cap: Node3D = null
var _core: MeshInstance3D = null
var _core_mat: StandardMaterial3D = null
var _core_col: Color = CORE_OFF
var _spin: float = 0.0
var _was_up: bool = false
var _flash: float = 0.0

func unbatched() -> Array:
	var c := get_node_or_null("Core")
	return [c] if c != null else []

func _setup_emitter() -> void:
	moving_parts = true
	_cap = get_node_or_null("Cap") as Node3D
	_core = get_node_or_null("Core") as MeshInstance3D
	if _core != null:
		var m: Material = _core.material_override
		if m == null and _core.mesh != null:
			m = _core.mesh.surface_get_material(0)
		if m is StandardMaterial3D:
			_core_mat = (m as StandardMaterial3D).duplicate()
			_core_mat.albedo_color = _core_col
			_core.material_override = _core_mat

func _animate_emitter(delta: float, up: bool, rebooting: bool) -> void:
	if _cap == null:
		return
	if up and not _was_up:
		_flash = 1.0
	_was_up = up
	_flash = maxf(_flash - delta / BOOT_FLASH, 0.0)
	# Rebooting, the cap stands half open: shut, it hid the very core that says "rebooting".
	var lift: float = CAP_LIFT if up else (CAP_LIFT * REBOOT_LIFT if rebooting else 0.0)
	var spin: float = CAP_SPIN if up else 0.0
	var col: Color = CORE_ON if up else CORE_OFF
	if rebooting:
		# Winds up as the reboot runs out: the player sees how soon the dome is back.
		var k: float = 1.0 - clampf(_cd / SHIELD_BREAK_CD, 0.0, 1.0)
		spin = CAP_SPIN_BOOT * k
		var blink: bool = fmod(Time.get_ticks_msec() / 1000.0 * BOOT_BLINK, 1.0) < 0.5
		col = CORE_BOOT if blink else CORE_BOOT * 0.35
	if _flash > 0.0:
		col = col.lerp(Color.WHITE, _flash)
	_cap.position.y = move_toward(_cap.position.y, lift, delta * 0.45)
	_spin = move_toward(_spin, spin, delta * 3.0)
	if _spin > 0.001:
		_cap.rotate_y(_spin * delta)
	if _core_mat != null:
		var target: Color = col
		# Blinks switch at once; everything else eases, so power flicker never reaches the core.
		_core_col = target if rebooting or _flash > 0.0 else _core_col.lerp(target, clampf(delta * 6.0, 0.0, 1.0))
		if not _core_mat.albedo_color.is_equal_approx(_core_col):
			_core_mat.albedo_color = _core_col

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
	var mounted: bool = freeze and v != null and v.has_method("energy_available")
	var has_energy: bool = mounted and v.energy_available() > 0.0
	# RUNNING DRY IS A COLLAPSE, NOT A PAUSE. The dome used to vanish at zero and stand again on the
	# first drop a panel produced, so a shield sharing a thin supply with a repair field blinked on
	# and off with every tick; now it reboots for SHIELD_BREAK_CD, exactly as when a hit it cannot
	# pay for breaks it (absorb), and the model shows the reboot.
	if _dome.visible and mounted and not has_energy and _cd <= 0.0:
		_cd = SHIELD_BREAK_CD
	var powered: bool = _cd <= 0.0 and has_energy
	_animate_emitter(delta, powered, mounted and _cd > 0.0)
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
		_poll_seam()

## Every other LIT dome of the same side whose sphere reaches into this one, in this dome's own axes.
## Domes on one machine stand still in those axes, so the uniforms are written only when the list
## actually changes - a driving machine does not pay a material write per tick for them.
func _update_cuts(v: Node) -> void:
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
		# ONE MACHINE ONLY. The shared lattice is solved once per layout (`_solve_seam`); domes on
		# two machines move against each other every tick, and a merge between them would mean a
		# fresh solve per tick - they simply overlap.
		if ov != v:
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

## THE SHARED PLATE SET, relaxed into a honeycomb. Rows laid on the join ring were straight
## enough on their own and agreed with nothing beside them: the player's screenshots showed a band
## of stretched rectangles and, where the ring turns away from the camera, loose lines. So the band
## is solved as a CENTROIDAL VORONOI tessellation (Lloyd): the plates beyond the band stay where
## the lattice has them and hold it in place, the ones in the band start on the ring rows and are
## moved, a few rounds, to the middle of the surface they win - which is what makes cells equal and
## six-sided. Solved in the MACHINE's axes and cached by layout (`_seam_cache`), so every dome of the
## hull takes the very same centres, and a second dome, or a second machine of the same build,
## pays nothing.
static var _seam_cache: Dictionary = {}
static var _fib: PackedVector3Array = PackedVector3Array()
const SEAM_SAMPLES := 4000           # surface samples per sphere for the relaxation
const SEAM_ROUNDS := 30
const SEAM_NB := 10                  # neighbour list per centre for the nearest-centre walk

static func _fib_dirs() -> PackedVector3Array:
	if _fib.is_empty():
		var n: int = SEAM_SAMPLES
		var ga: float = PI * (3.0 - sqrt(5.0))
		for i in n:
			var y: float = 1.0 - 2.0 * (float(i) + 0.5) / float(n)
			var r: float = sqrt(maxf(1.0 - y * y, 0.0))
			var th: float = ga * float(i)
			_fib.append(Vector3(cos(th) * r, y, sin(th) * r))
	return _fib

func _update_seam(inv: Transform3D) -> void:
	var v: Node = _vehicle_root()
	var mach: Transform3D = (v as Node3D).global_transform.affine_inverse() if v is Node3D else Transform3D.IDENTITY
	# Every dome of the hull in machine space, in a fixed order, with its turn (plates follow it).
	var domes: Array = []
	for n in [self] + _merged:
		if is_instance_valid(n) and is_instance_valid(n.get("_dome")):
			var t: Transform3D = mach * (n.get("_dome") as Node3D).global_transform
			domes.append([t.origin, t.basis.orthonormalized()])
	domes.sort_custom(func(a, b): return str(a[0]) < str(b[0]))
	var key := ""
	for d in domes:
		var o: Vector3 = d[0]
		var bz: Vector3 = (d[1] as Basis).z
		key += "%.2f,%.2f,%.2f/%.2f,%.2f,%.2f;" % [o.x, o.y, o.z, bz.x, bz.y, bz.z]
	if domes.size() < 2:
		_seam_cache[key] = []
	if not _seam_cache.has(key):
		# OFF THE MAIN THREAD. The relaxation is most of a second on a slow build, and it runs the
		# moment a shield is bolted on or a machine loads. Until it lands the domes are simply cut
		# against each other; `_poll_seam` applies the result when the job is done.
		_start_seam_job(key, domes)
		_seam_key = key
		_set_dome_param("merged", false)
		return
	_seam_key = ""
	var solved: Array = _seam_cache[key]
	_seam_local = []
	if solved.is_empty():
		_set_dome_param("merged", false)
		return
	# Machine space -> this dome's model space.
	var to_me: Transform3D = inv * ((v as Node3D).global_transform if v is Node3D else Transform3D.IDENTITY)
	var pts: Array = []                      # Vector4 in model space
	for e in solved:
		var q: Vector3 = to_me * Vector3(e.x, e.y, e.z)
		pts.append(Vector4(q.x, q.y, q.z, e.w))
		_seam_local.append(q)
	# The table: for each plate of THIS mesh, the centres that can own any point of it.
	var reach2: float = pow(_spacing() * SEAM_NEAR, 2.0)
	var img := Image.create(SEAM_ROW, _hex_cells.size(), false, Image.FORMAT_RGBAF)
	img.fill(Color(0, 0, 0, -1))
	for r in _hex_cells.size():
		var pc: Vector3 = (_hex_cells[r] as Vector3) * SHIELD_RADIUS
		var near: Array = []
		for q in pts:
			var dq: float = pc.distance_squared_to(Vector3(q.x, q.y, q.z))
			if dq < reach2:
				near.append([dq, q])
		near.sort_custom(func(x, y): return x[0] < y[0])
		for k in mini(near.size(), SEAM_ROW):
			var q: Vector4 = near[k][1]
			img.set_pixel(k, r, Color(q.x, q.y, q.z, q.w))
	_set_dome_param("seam_tex", ImageTexture.create_from_image(img))
	_set_dome_param("merged", true)
	_set_dome_param("radius", SHIELD_RADIUS)

static var _seam_jobs: Dictionary = {}   # layout key -> {"task": id, "domes": Array, "out": Array}
var _seam_key: String = ""               # the layout this dome waits for, "" when none

static func _start_seam_job(key: String, domes: Array) -> void:
	if _seam_jobs.has(key):
		return
	_fib_dirs()                          # lazily built statics: build them here, not on a worker
	_spacing()
	var job := {"domes": domes, "out": []}
	job["task"] = WorkerThreadPool.add_task(_run_seam_job.bind(job), false, "shield seam")
	_seam_jobs[key] = job

static func _run_seam_job(job: Dictionary) -> void:
	job["out"] = _solve_seam(job["domes"])

## A waiting dome asks every tick; the first to find the job done joins it and caches the result.
func _poll_seam() -> void:
	if _seam_key == "":
		return
	if not _seam_cache.has(_seam_key):
		var job: Dictionary = _seam_jobs.get(_seam_key, {})
		if job.is_empty() or not WorkerThreadPool.is_task_completed(int(job["task"])):
			return
		WorkerThreadPool.wait_for_task_completion(int(job["task"]))
		_seam_cache[_seam_key] = job["out"]
		_seam_jobs.erase(_seam_key)
	_update_seam(_dome.global_transform.affine_inverse())

## Is `p` on the visible hull: outside every sphere but dome `own`'s.
static func _alive(p: Vector3, own: int, domes: Array) -> bool:
	var r_in: float = SHIELD_RADIUS * CUT_INSET
	for j in domes.size():
		if j != own and p.distance_to(domes[j][0]) < r_in:
			return false
	return true

## The relaxation itself, in machine space. Returns Vector4(position, random number) per centre.
##
## THE WHOLE HULL RELAXES, NOT A BAND. Relaxing only a strip along the join and holding the rest
## still left a seam of its own where the moving strip met the held lattice: cells there came out
## five- and seven-sided and of mixed sizes (measured, T of three domes: 54% hexagons, cell areas
## spread 0.22, against a lone dome's 77% and 0.08). Every plate of every dome is a centre, every
## centre moves, and Lloyd's rounds even the whole surface - a lone dome is already such a solution,
## so away from the joins almost nothing moves.
##
## SPEED: a sample's nearest centre is looked for among the neighbours of LAST round's nearest
## (centres move little per round), with each centre's SEAM_NB nearest centres re-listed every round.
static func _solve_seam(domes: Array) -> Array:
	var centres: Array[Vector3] = []
	var rnds := PackedFloat32Array()
	# Domes in a ROW make a surface of revolution, and that has a far better start than two
	# Goldberg lattices with twelve pentagons each: rings of staggered cells round the row's axis,
	# one ring on every join and a single cell at each end. Any other layout starts from the plates.
	if not _ring_start(domes, centres, rnds):
		for i in domes.size():
			for k in _hex_cells.size():
				var p: Vector3 = domes[i][0] + (domes[i][1] as Basis) * ((_hex_cells[k] as Vector3) * SHIELD_RADIUS)
				if _alive(p, i, domes):
					centres.append(p)
					rnds.append(_hex_rnd[k])
	var samples := PackedVector3Array()
	for i in domes.size():
		for f in _fib_dirs():
			var p: Vector3 = domes[i][0] + f * SHIELD_RADIUS
			if _alive(p, i, domes):
				samples.append(p)
	var n: int = centres.size()
	if n < 2 or samples.is_empty():
		return []
	# Each sample's current owner, found once by brute force.
	var owner := PackedInt32Array()
	owner.resize(samples.size())
	for si in samples.size():
		var best := INF
		for c in n:
			var d: float = samples[si].distance_squared_to(centres[c])
			if d < best:
				best = d
				owner[si] = c
	for _round in SEAM_ROUNDS:
		var nb: Array = _centre_neighbours(centres)
		var sum: Array[Vector3] = []
		sum.resize(n)
		var cnt := PackedInt32Array()
		cnt.resize(n)
		for si in samples.size():
			var p: Vector3 = samples[si]
			var w: int = owner[si]
			# Walk downhill through neighbour lists until no neighbour is nearer.
			var best: float = p.distance_squared_to(centres[w])
			var moved := true
			while moved:
				moved = false
				for c in (nb[w] as PackedInt32Array):
					var d: float = p.distance_squared_to(centres[c])
					if d < best:
						best = d
						w = c
						moved = true
			owner[si] = w
			sum[w] += p
			cnt[w] += 1
		for c in n:
			if cnt[c] > 0:
				centres[c] = _onto_hull(sum[c] / float(cnt[c]), domes)
	var out: Array = []
	for c in n:
		out.append(Vector4(centres[c].x, centres[c].y, centres[c].z, rnds[c]))
	return out

## Starting centres for domes in a row: false when they are not in one.
static func _ring_start(domes: Array, centres: Array[Vector3], rnds: PackedFloat32Array) -> bool:
	var first: Vector3 = domes[0][0]
	var far: Vector3 = first
	for d in domes:
		if (d[0] as Vector3).distance_squared_to(first) > far.distance_squared_to(first):
			far = d[0]
	var span: float = first.distance_to(far)
	if span < 0.01:
		return false
	var axis: Vector3 = (far - first) / span
	var ts: Array[float] = []
	for d in domes:
		var rel: Vector3 = (d[0] as Vector3) - first
		if (rel - axis * rel.dot(axis)).length() > 0.05:
			return false                      # off the line: not a surface of revolution
		ts.append(rel.dot(axis))
	ts.sort()
	var R: float = SHIELD_RADIUS
	var sp: float = _spacing()
	# The profile, walked from one end to the other: arc length against position on the axis.
	var x0: float = ts[0] - R
	var x1: float = ts[ts.size() - 1] + R
	var steps: int = 4000
	var xs := PackedFloat32Array()
	var ss := PackedFloat32Array()
	var prev_r: float = 0.0
	var acc: float = 0.0
	for k in steps + 1:
		var x: float = lerpf(x0, x1, float(k) / float(steps))
		var r: float = _profile(x, ts)
		if k > 0:
			acc += sqrt(pow((x1 - x0) / float(steps), 2.0) + pow(r - prev_r, 2.0))
		xs.append(x)
		ss.append(acc)
		prev_r = r
	var total: float = acc
	# Knots: both ends and every join; rings between them at about a row-height apart.
	var knots: Array[float] = [0.0]
	for i in ts.size() - 1:
		knots.append(_s_at((ts[i] + ts[i + 1]) * 0.5, xs, ss))
	knots.append(total)
	var rows: Array[float] = []
	for k in knots.size() - 1:
		var a: float = knots[k]
		var b: float = knots[k + 1]
		var n: int = maxi(1, roundi((b - a) / (sp * 0.866)))   # a hexagon's row height
		for j in n:
			rows.append(a + (b - a) * float(j) / float(n))
	rows.append(total)
	var ref: Vector3 = Vector3.UP if absf(axis.y) < 0.9 else Vector3.RIGHT
	var u: Vector3 = axis.cross(ref).normalized()
	var w: Vector3 = axis.cross(u)
	for ri in rows.size():
		var x: float = _x_at(rows[ri], xs, ss)
		var r: float = _profile(x, ts)
		var ctr: Vector3 = first + axis * x
		var n: int = 1 if r < sp * 0.35 else maxi(3, roundi(TAU * r / sp))
		for k in n:
			var th: float = TAU * (float(k) + 0.5 * float(ri % 2)) / float(n)
			centres.append(ctr + (u * cos(th) + w * sin(th)) * r)
			var rnd: float = fposmod(sin(float(ri) * 91.7 + float(k) * 12.9898) * 43758.5453, 1.0)
			rnds.append(roundf(rnd * 255.0) / 255.0)
	return true

## Radius of the row's hull at position `x` along its axis.
static func _profile(x: float, ts: Array[float]) -> float:
	var r := 0.0
	for t in ts:
		var h: float = SHIELD_RADIUS * SHIELD_RADIUS - (x - t) * (x - t)
		if h > 0.0:
			r = maxf(r, sqrt(h))
	return r

static func _s_at(x: float, xs: PackedFloat32Array, ss: PackedFloat32Array) -> float:
	var i: int = clampi(xs.bsearch(x), 1, xs.size() - 1)
	var f: float = inverse_lerp(xs[i - 1], xs[i], x)
	return lerpf(ss[i - 1], ss[i], f)

static func _x_at(s: float, xs: PackedFloat32Array, ss: PackedFloat32Array) -> float:
	var i: int = clampi(ss.bsearch(s), 1, ss.size() - 1)
	var f: float = inverse_lerp(ss[i - 1], ss[i], s) if ss[i] > ss[i - 1] else 0.0
	return lerpf(xs[i - 1], xs[i], f)

## Each centre's SEAM_NB nearest centres. Distances go into one packed integer with the index in
## the low bits, so the native sort does the work instead of a sort callback per comparison.
static func _centre_neighbours(centres: Array[Vector3]) -> Array:
	var n: int = centres.size()
	var out: Array = []
	for a in n:
		var keys := PackedInt64Array()
		keys.resize(n)
		for b in n:
			keys[b] = (int(centres[a].distance_squared_to(centres[b]) * 10000.0) << 12) | b
		keys.sort()
		var row := PackedInt32Array()
		for k in range(1, mini(SEAM_NB + 1, n)):
			row.append(int(keys[k] & 4095))
		out.append(row)
	return out

## The nearest point of the visible hull to `p`: its projection onto whichever sphere is not
## swallowed there.
static func _onto_hull(p: Vector3, domes: Array) -> Vector3:
	var best: Vector3 = p
	var best_d := INF
	for i in domes.size():
		var dir: Vector3 = p - (domes[i][0] as Vector3)
		if dir.length_squared() < 0.0001:
			continue
		var q: Vector3 = domes[i][0] + dir.normalized() * SHIELD_RADIUS
		if not _alive(q, i, domes):
			continue
		var d: float = q.distance_squared_to(p)
		if d < best_d:
			best_d = d
			best = q
	return best

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
