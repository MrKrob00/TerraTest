extends Node3D
# Раскидывает жилы руды по ВСЕЙ карте. Берёт реальную высоту рельефа у родителя-карты
# (map.terrain_height_at) и ставит жилу на землю; пропускает низины и крутые склоны,
# держит минимальную дистанцию между жилами. Каждая жила — это и StaticBody-узел (логика/
# коллизия), и инстанс в двух MultiMesh (видимый меш + канал шейдера истощения).

@export var resource_nodes: Array[PackedScene]
## ONE OUTCROP MODEL PER METAL, in G.Metal order (art/vein_models.gd): ferrite chunks, cuprite
## nuggets, silicate crystals, titanite plates. Each model is its rock plus its ore; the vertex says
## which part is mined.
@export var multimesh_nodes: Array[MultiMeshInstance3D]
## THE TREE: stump and tree in one model, one MultiMesh per kind (`_model_mm`).
@export var wood_multimesh_nodes: Array[MultiMeshInstance3D]

## Цвета типов жил = ЦВЕТА МЕТАЛЛОВ, один в один: тип жилы это и есть металл, который из неё
## выйдет (G.Metal), и жила обязана выглядеть тем, что даёт. Список НЕ дублируется здесь и не
## правится в инспекторе — он берётся из G.METAL_COLOR в _ready. Раньше цвета жил жили сами по
## себе, и добавить металл значило поправить два места, забыв одно.
## Новый металл — строка в G.Metal/G.METAL_COLOR (до 8 штук, см. MAX_ORE_TYPES в resource.gdshader).
var ore_colors: Array[Color] = []

## WHAT GROWS AND WHAT IS DUG ARE LAID IN GROUPS, after TerraTech (`_region_job`, below): trees
## stand in groves, ore in deposits of one metal. Coal is not in the ground: it is made from wood
## (resource.upgrade), and that is its only source.
##
## THE AUTO MINER DOES NOT TAKE A TREE (resource_node.claim), and that is the design: wood is the
## driving economy, see "WOOD HAS NO AUTOMATION" in CLAUDE.md.
@export var wood_color: Color = Color(0.42, 0.28, 0.16)

@export_group("Расстановка")
## Density is set PER REGION by the cluster constants (GROVE_TRIES, DEPOSIT_TRIES ...): a world with
## no edge has no "whole map" to count veins over.
@export var min_height: float = 2.0          # ниже — самые днища впадин, не спавним (воды в мире нет)
@export var max_slope: float = 7.0           # разброс высот вокруг точки; выше — обрыв

@export_group("Стриминг")
## Радиус вокруг камеры, в котором жилы РЕНДЕРЯТСЯ и активны (есть узел/коллизия для добычи).
## Дальше — только запись в _data, ни ноды, ни инстанса MultiMesh (система не грузится).
@export var render_distance: float = 160.0
## ПОТОЛОК одновременно отрисованных/активных жил = размер буфера MultiMesh и пул слотов.
## В радиусе 160 при 2000 жилах на карту 1982² их ~40-60; 180 — с большим запасом.
@export var max_visible: int = 180
@export var cull_interval: float = 0.25      # как часто пересчитывать стриминг (сек)
## Жилы ЗА СПИНОЙ не держим. Жила — это не только инстанс MultiMesh, но и узел с коллизией и
## своей логикой добычи; за камерой от него нет никакой пользы, а слот в буфере он занимает.
## Отвернулся — отдали слот тому, что впереди, и в радиусе стало видно дальше.
## keep_radius — ближний пузырь: рядом жила активна в любую сторону, иначе та, в которую уже
## вгрызся бур, гасла бы, стоило отвести камеру.
@export var keep_radius: float = 40.0
@export var view_cos: float = -0.15          # чуть шире полусферы перед камерой — край не мигает

# Все жилы карты как данные: {pos, scene, ore_type, wood, slot(-1=не показана), node(null)}.
var _data: Array = []
## EACH MODEL'S SLOTS ARE DENSE: its MultiMesh draws exactly `visible_instance_count` instances, the
## live veins of that model, in slots 0..n-1 (MultiMeshInstance3D -> Array of records, index = slot).
## It used to be one pool of `max_visible` slots shared by all seven models, every slot in every
## MultiMesh, the unused ones collapsed to a zero scale - and a zero-scale instance is still DRAWN:
## its vertices go through the shader. Measured on the real driver, booted world: the veins were
## 285k of the frame's 342k primitives and 166k of the sun's 167k in the shadow pass (the trees cast).
## A vein leaving hands its slot to its model's LAST live vein (`_stream_out`), which is told its new
## slot; a node writes its shader data through its record (`write_custom`).
var _mm_live: Dictionary = {}
var _cull_t: float = 0.0
## A SHOWN vein is asked whether it went behind a ridge a slice of the list a pass (1/OCCL_SLICES);
## a HIDDEN one every pass, or it would come back up to four passes - tens of metres of driving -
## after the ridge was crossed. Hiding late costs a drawn vein, showing late is a pop.
const OCCL_SLICES := 4
## The test asks for the vein's TOP (`_vein_top`): its model's height times its size. A fixed 1.5 m
## hid a tree - twelve metres of it - while its crown stood over the ridge.
const OCCL_VEIN_HEIGHT := 1.5
var _occl_cursor: int = 0
var _top_of: Dictionary = {}      # MultiMeshInstance3D -> its model's top, in model metres
var _last_fwd: Vector3 = Vector3.FORWARD

# _ready идёт СНИЗУ ВВЕРХ: у детей он вызывается РАНЬШЕ, чем у родителя. Значит на этот
# момент карта ещё не выполнила свой _ready, и требовать от неё готовности сразу нельзя.
# Ждём, пока она начнёт отвечать, и только потом сдаёмся: прежний вариант ругался и
# делал return, из-за чего узел не инициализировался за весь сеанс.
const MAP_WAIT_FRAMES: int = 300      # ~5 секунд при 60 кадрах
## Each vein drawn turned by its own angle and at its own size, by its position.
const VEIN_SCALE_MIN := 0.85
const VEIN_SCALE_MAX := 1.15
## A TREE IS DRAWN AT TWICE ITS MODEL (the player: "the trees are small, make them twice as big").
## One number on the instance, not a regenerated mesh: the stump, the fall and the break points are
## all in model space and scale with it. The node's collider grows to the trunk (`_tree_shape`), and
## whoever places something on a tree asks the node's `vein_basis` meta (the battery errand).
const TREE_SCALE := 2.0
var _tree_shape: CylinderShape3D = null
## AN ORE VEIN IS DRAWN AT THREE TIMES ITS MODEL (the player: "make the veins three times bigger"),
## the same way: one number on the instance, break points in model space. The models are about a
## metre across, so a vein is about three now; its collider (`_ore_shape`), where its ore is thrown
## (`resource_node._eject_one`, by `vein_basis`) and the auto miner's reach and mount distance
## (`auto_miner.vein_reach`, `vehicle_body_3d.MINER_MOUNT_DIST`) grew with it. the spacing (`ORE_GAP`) did
## NOT: it is a rejection radius in the seeded layout, and moving it would move veins under saved bases.
const VEIN_SIZE := 3.0
var _ore_shape: CylinderShape3D = null

## A TIME FOR THE SHADER IS THE SHADER'S CLOCK, which rolls over (`time_rollover_secs`, an hour by
## default): an hour into a session a raw Time.get_ticks_msec() stood an hour ahead of TIME, and a
## vein that came back then read "comes back in an hour" - its crystals stayed at stub size for good.
static func shader_now() -> float:
	var roll: float = float(ProjectSettings.get_setting("rendering/limits/time/time_rollover_secs", 3600))
	return fmod(Time.get_ticks_msec() / 1000.0, maxf(roll, 1.0))
## Страховка на случай, если сигнала так и не будет (сломанная карта, выгруженная сцена).
## В СЕКУНДАХ, не в кадрах: ждём мы работу потоков, а она меряется часами, а не кадрами.
const TERRAIN_WAIT_SEC: float = 120.0

func _terrain_ready(map: Node) -> bool:
	return is_instance_valid(map) and map.get_dims().x > 0

## Ждём готовности земли ОПРОСОМ ПО ЧАСАМ, а не по сигналу `terrain_ready`. Сигнал был бы
## короче, но его нет у запечённой карты аддона, а главное — на него нельзя повесить срок:
## `await` сигнала, который не придёт (сломанная карта, выгруженная сцена), висит вечно и
## молча, то есть меняет громкую ошибку на тихую.
func _wait_terrain(map: Node) -> void:
	var deadline: int = Time.get_ticks_msec() + int(TERRAIN_WAIT_SEC * 1000.0)
	while is_instance_valid(map) and not _terrain_ready(map) \
			and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame

func _ready() -> void:
	# До любого await: дальше по коду список нужен и шейдеру, и раздаче типов жилам.
	ore_colors.assign(G.METAL_COLOR)
	_digits = VEIN_DIGITS.new()
	add_child(_digits)
	var map: Node = await _await_map()
	if map == null:
		push_error("resource_nodes: родитель так и не стал картой (нет terrain_height_at/get_dims)")
		return

	# ЖДЁМ СИГНАЛА РЕЛЬЕФА, А НЕ КАДРОВ. `get_dims()` отдаёт ноль, пока земля не готова, а
	# готовность — это РЕАЛЬНЫЕ СЕКУНДЫ работы потоков: замер на этой машине — кольцо 4.1 с,
	# весь ближний вид 11.4 с. Прежние 300 кадров это 5 секунд при шестидесяти, то есть жилы
	# сдавались РАНЬШЕ, чем земля успевала подняться, и не появлялись за весь сеанс. Держалось
	# это только на том, что во время генерации кадры и так просажены и триста штук набегают
	# дольше пяти секунд, — то есть на удаче, и на быстром устройстве удача кончается.
	if not _terrain_ready(map):
		await _wait_terrain(map)
	if not _terrain_ready(map):
		push_error("resource_nodes: рельеф так и не загрузился")
		return

	_apply_ore_colors()
	# ЖИЛЫ БОЛЬШЕ НЕ РАСКЛАДЫВАЮТСЯ ОДНИМ КУСКОМ. Пул слотов заводим здесь, а сами жилы рождают
	# регионы по мере того, как игрок к ним подъезжает (_regions_tick).
	_init_slots()
	_far = FAR_TREES_SCRIPT.new()
	add_child(_far)
	_far.setup()
	_far.set_reach(FAR_TREES * FAR_FADE, FAR_TREES)
	_regions_tick()

## Red digits off a struck vein (vein_digits.gd): one pool for every vein, asked by resource_node.hurt.
const VEIN_DIGITS := preload("res://vein_digits.gd")

## THE FAR TREES (far_trees.gd): past `render_distance` a tree is a picture of itself out to FAR_TREES,
## from the same record, in the same pass that streams the models; the last FAR_FADE of the way it
## dissolves. A forest used to end at 160 m, where the haze has barely begun (150..750). Untyped: the
## script has no class_name (CLAUDE.md rule 19).
const FAR_TREES_SCRIPT := preload("res://far_trees.gd")
const FAR_TREES := 420.0
const FAR_FADE := 0.85
var _far = null
var _digits: Node = null

func vein_hit(vein: Node3D) -> void:
	if _digits == null or not is_instance_valid(vein):
		return
	# out of the side the player sees, and on a tree under its crown: from the middle they were lost
	# inside the needles
	var wood: bool = vein.get("is_wood") == true
	var base: Vector3 = vein.global_position
	var at: Vector3 = base + Vector3.UP * (0.8 * TREE_SCALE if wood else 0.35 * VEIN_SIZE)
	var out := Vector3.ZERO
	var cam := get_viewport().get_camera_3d()
	if cam != null:
		out = cam.global_position - at
		out.y = 0.0
		if out.length_squared() > 0.01:
			out = out.normalized()
			at += out * (0.45 * TREE_SCALE if wood else 0.6 * VEIN_SIZE)
	_digits.burst(vein, at, base.y - 0.25, out)

## The veins' shader reads its own `now`, never TIME (see resources/resource.gdshader): one clock
## for the times written into custom data and the time they are compared against.
func _tick_clock() -> void:
	var t: float = shader_now()
	for mm in _all_mm():
		var m = mm.material_override
		if m is ShaderMaterial:
			(m as ShaderMaterial).set_shader_parameter("now", t)

func _all_mm() -> Array:
	return multimesh_nodes + wood_multimesh_nodes

## THE MULTIMESHES' BOX STANDS ROUND THE CAMERA, NOT ROUND THE WORLD'S ORIGIN. It was a fixed 4 km cube
## round (0, 0, 0): past 2 km from the spawn every live vein lay outside it, and the moment the camera
## looked away from the spawn the box was behind it and the whole MultiMesh was culled - the veins
## vanished while their nodes, colliders and far cards stayed (the player's report). A box holding the
## camera is never culled, which is what "drawn whole" always meant; it is moved each streaming pass.
const BOUNDS_HALF := 4500.0

func _recentre_bounds(cam_pos: Vector3) -> void:
	var half := Vector3(BOUNDS_HALF, BOUNDS_HALF, BOUNDS_HALF)
	for mm in _all_mm():
		var node := mm as GeometryInstance3D
		if node != null and node.is_inside_tree():
			node.custom_aabb = AABB(node.to_local(cam_pos) - half, half * 2.0)
	if _far != null and is_instance_valid(_far) and _far.is_inside_tree():
		_far.custom_aabb = AABB(_far.to_local(cam_pos) - half, half * 2.0)

## The MultiMesh that draws this vein: the tree, or its metal's outcrop (a metal past the list - a
## new one before its model is built - borrows the last).
## WHICH TREE GROWS HERE, BY BIOME (the player's call, after TerraTech): an index into
## `wood_multimesh_nodes` - TREE_BROAD or TREE_TEAL on the meadow, TREE_BROAD in the canyon and on the
## mountains (two mountain trees were turned down, and the player kept three models), TREE_PALM in
## the desert; -1 on a salt flat, where nothing grows. The roll is a HASH OF THE POINT, not the
## region's rng: drawing from that would shift every vein after the first tree.
const TREE_BROAD := 0
const TREE_TEAL := 1
const TREE_PALM := 2
const TEAL_SHARE := 30          # of a hundred meadow trees

func _tree_kind(map: Node, world: Vector3) -> int:
	if map == null or not map.has_method("biome_at"):
		return TREE_BROAD
	if map.has_method("salt_at") and float(map.salt_at(world)) > 0.5:
		return -1
	return _tree_kind_of(map.biome_at(world), world)

## The kind from a biome blend already in hand (canyon, meadow, mountain) - the salt flat asked before.
func _tree_kind_of(b: Vector3, world: Vector3) -> int:
	if b.y > 0.5 and b.z <= 0.5:
		var roll: int = absi(hash(Vector2i(roundi(world.x * 10.0), roundi(world.z * 10.0)))) % 100
		return TREE_TEAL if roll < TEAL_SHARE else TREE_BROAD
	if b.x > 0.5 or b.z > 0.5:
		return TREE_BROAD
	return TREE_PALM

func _model_mm(v: Dictionary) -> MultiMeshInstance3D:
	if v.get("wood") == true:
		if wood_multimesh_nodes.is_empty():
			return null
		return wood_multimesh_nodes[clampi(int(v.get("tree", 0)), 0, wood_multimesh_nodes.size() - 1)]
	if multimesh_nodes.is_empty():
		return null
	return multimesh_nodes[clampi(int(v["ore_type"]), 0, multimesh_nodes.size() - 1)]

## The metal colours into the vein shader (resources/resource.gdshader), once for all: the
## crystals' material is the MultiMesh's material_override.
func _apply_ore_colors() -> void:
	if ore_colors.is_empty():
		return
	var cols := PackedVector3Array()
	for c in ore_colors + [wood_color]:      # wood is the shader's last index
		var lc: Color = c.srgb_to_linear()      # the shader takes linear RGB
		cols.append(Vector3(lc.r, lc.g, lc.b))
	for mm in _all_mm():
		if mm.material_override is ShaderMaterial:
			(mm.material_override as ShaderMaterial).set_shader_parameter("ore_colors", cols)

## THE STANDING TREES FOR THE SUN'S SHADOW MAP (`sun_shadows.gd`): [world foot, crown height, crown
## radius] of every tree streamed in within `half` of `center` (XZ), felled ones (custom G under a
## half) left out. The crown is read off the model's own box, scaled per instance.
var _crown_of: Dictionary = {}
func tree_shadow_casters(center: Vector2, half: float) -> Array:
	var out: Array = []
	for mm in wood_multimesh_nodes:
		if not is_instance_valid(mm) or not _mm_live.has(mm) or mm.multimesh == null or mm.multimesh.mesh == null:
			continue
		var crown = _crown_of.get(mm)
		if crown == null:
			var bb: AABB = mm.multimesh.mesh.get_aabb()
			var r0: float = maxf(bb.size.x, bb.size.z) * 0.5
			crown = Vector2(bb.end.y - r0 * 0.8, r0 * 0.85)
			_crown_of[mm] = crown
		var mxf: Transform3D = mm.global_transform
		for v in _mm_live[mm]:
			var cd = v.get("cd")
			if cd is Color and (cd as Color).g < 0.5:
				continue
			var xf = v.get("xf")
			if not (xf is Transform3D):
				continue
			var gp: Vector3 = mxf * (xf as Transform3D).origin
			if absf(gp.x - center.x) > half or absf(gp.z - center.y) > half:
				continue
			var s: float = (xf as Transform3D).basis.get_scale().y
			out.append([gp, (crown as Vector2).x * s, (crown as Vector2).y * s])
	return out

## A vein node's shader data (its HP and hit times, resource_node._write_shader_data): into its own
## model's slot, and kept on the record so the data moves with the vein when its slot does. A node
## that is already streamed out (freed at the end of this frame) no longer owns the slot it names.
func write_custom(slot: int, data: Color, node: Node = null) -> void:
	for mm in _mm_live:
		var recs: Array = _mm_live[mm]
		if slot < 0 or slot >= recs.size():
			continue
		var v: Dictionary = recs[slot]
		if node != null and v.get("node") != node:
			continue
		v["cd"] = data
		(mm as MultiMeshInstance3D).multimesh.set_instance_custom_data(slot, data)
		return

# ── РЕГИОНЫ: ЖИЛЫ РОЖДАЮТСЯ КУСКАМИ, А НЕ ВСЕЙ КАРТОЙ СРАЗУ ──────────────────
# Раньше две тысячи жил раскладывались ОДИН РАЗ при загрузке, перебором по всей карте. В мире
# без края так нельзя дважды: перебирать нечего (карта не кончается) и держать нечего (список
# рос бы вместе с пройденным путём).
#
# Поэтому мир нарезан на РЕГИОНЫ по REGION клеток, и каждый рождает свои жилы САМ — из сида мира
# и собственных координат. Отсюда два свойства, ради которых всё и делается: регион всегда даёт
# одни и те же жилы, сколько бы раз игрок в него ни вернулся, и соседний регион можно посчитать,
# ничего не зная про этот.
#
# ВЫСОТУ СПРАШИВАЕМ У КАРТЫ, а она знает только то, что внутри окна. Поэтому регион рождается,
# лишь когда игрок к нему подъехал: снаружи окна ответа всё равно нет.
const REGION := 256
## На сколько регионов вокруг игрока держим жилы. Один в каждую сторону — это 768 клеток по
## диагонали, вдвое больше дальности отрисовки: жила успевает родиться задолго до того, как её
## станет видно. These are built AT ONCE: they hold every vein a drill or a miner can reach.
const REGION_KEEP := 1
## THE FAR TREES NEED A RING MORE (`FAR_TREES` 420 m: one ring guarantees only 256 m, from a region's
## edge), and a region that far out costs 127-158 ms to build on the debug build against 8 ms for one
## the ground is already up under - its heights are new to the terrain. So the outer ring is built a
## SLICE A FRAME (`_region_step`, `REGION_SLICE_USEC`), nearest first; the slicing changes nothing
## about what is laid, since one region's rng draws in one order however the work is cut. A region
## that comes inside REGION_KEEP while its job is half done is finished on the spot.
const REGION_FAR := 2
const REGION_SLICE_USEC := 1500
var _region_jobs: Array = []

var _regions: Dictionary = {}          # Vector2i региона → Array записей жил
var _region_center := Vector2i(999999, 999999)

## Ключ региона по мировой точке.
func _region_of(gp: Vector3) -> Vector2i:
	return Vector2i(floori(gp.x / REGION), floori(gp.z / REGION))

## Держать вокруг игрока квадрат регионов; ушедшие — забыть вместе с их жилами.
func _regions_tick() -> void:
	var here := _region_of(_player_point())
	if here == _region_center:
		return
	_region_center = here
	var want := {}
	for dz in range(-REGION_FAR, REGION_FAR + 1):
		for dx in range(-REGION_FAR, REGION_FAR + 1):
			want[here + Vector2i(dx, dz)] = true
	for k in _regions.keys():
		if not want.has(k):
			for v in _regions[k]:
				if int(v["slot"]) >= 0:
					_stream_out(v)          # слот и узел отдаём до того, как забудем запись
			_regions.erase(k)
	var jobs: Dictionary = {}
	for j in _region_jobs:
		if want.has(j["rk"]):
			jobs[j["rk"]] = j
	var queue: Array = []
	for k in want:
		if _regions.has(k):
			continue
		var job: Dictionary = jobs.get(k, {})
		if job.is_empty():
			job = _region_job(k)
		if maxi(absi(k.x - here.x), absi(k.y - here.y)) <= REGION_KEEP:
			_region_step(job, 0)               # a vein in reach is never late: built now
			_regions[k] = job["out"]
		else:
			queue.append(job)
	var p := _player_point()
	queue.sort_custom(func(a, b): return _region_d2(a["rk"], p) < _region_d2(b["rk"], p))
	_region_jobs = queue
	_rebuild_data()

func _region_d2(rk: Vector2i, p: Vector3) -> float:
	return Vector2((rk.x + 0.5) * REGION - p.x, (rk.y + 0.5) * REGION - p.z).length_squared()

## The outer ring's next slice (called every frame): a finished region joins the data, and the next
## streaming pass takes its trees in (`_last_cell` forgotten).
func _region_jobs_tick() -> void:
	if _region_jobs.is_empty():
		return
	var job: Dictionary = _region_jobs[0]
	if not _region_step(job, REGION_SLICE_USEC):
		return
	_region_jobs.pop_front()
	_regions[job["rk"]] = job["out"]
	_rebuild_data()
	_last_cell = Vector2i(1 << 30, 1 << 30)

func _player_point() -> Vector3:
	var pts: Array = G.active_points()
	return pts[0] if not pts.is_empty() else Vector3.ZERO

## _data — это просто ВСЕ жилы живых регионов, склеенные в один список: стриминг ходит по нему
## каждый тик, и перебирать словарь словарей на каждом кадре было бы дороже, чем пересобрать
## список тогда, когда набор регионов реально сменился.
func _rebuild_data() -> void:
	_data.clear()
	for k in _regions:
		_data.append_array(_regions[k])
	_data.append_array(_made)

## ── ЖИЛА ПО ЗАКАЗУ ───────────────────────────────────────────────────────────
## Заказанные жилы живут ОТДЕЛЬНЫМ списком, а не в регионе. Регион считается от сида и обязан
## давать один и тот же набор сколько угодно раз; дописанная в него запись исчезла бы при первой
## же пересборке — то есть в тот момент, когда игрок отъехал на регион и вернулся.
var _made: Array = []

## Поставить жилу в мировой точке. Ровная земля полигона не рождает ни одной (`min_height` 2.0
## против flat_y 0.0), а без жилы нечем проверить ни бур, ни авто-шахтёра, ни коллектор.
##
## Запись делается ТОЙ ЖЕ ФОРМЫ, что у `_build_region`, и отдаётся ТОМУ ЖЕ `_stream_in`: слот
## MultiMesh, узел с коллизией, тип и цвет руды — всё уже там, и второй такой раскладки быть не
## должно. `ore_type` — индекс `G.Metal`; дерево у жил это отдельный флаг, а не пятый металл.
func spawn_vein(world_pos: Vector3, ore_type: int, wood: bool) -> Node:
	if resource_nodes.is_empty():
		return null
	var h: float = G.ground_y(world_pos, world_pos.y)
	var gpos := Vector3(world_pos.x, h + 0.25, world_pos.z)
	var v: Dictionary = {
		"pos": to_local(gpos),
		"gpos": gpos,
		"scene": resource_nodes[randi() % resource_nodes.size()],
		"ore_type": ore_colors.size() if wood else clampi(ore_type, 0, ore_colors.size() - 1),
		"wood": wood, "tree": maxi(_tree_kind(get_parent(), gpos), 0) if wood else 0, "slot": -1, "node": null,
	}
	_made.append(v)
	_rebuild_data()
	_stream_in(v)
	return v.get("node")

## Убрать ВСЕ заказанные жилы (полигон, кнопка уборки). Регионов не касается: их жилы посчитаны
## от сида и обязаны вернуться, а заказанные — нет.
##
## Копятся они именно потому, что убирать их было нечем: кнопка уборки чистила `/root/Main/objects`,
## где лежат предметы, а жила живёт узлом под своим владельцем и записью в `_made`. Три жилы за
## нажатие никуда не девались, и после пяти нажатий пятнадцать штук стояли в одном пятне —
## это и читалось как «их спавнится каждый раз больше».
func clear_made() -> int:
	var n: int = _made.size()
	for v in _made:
		if int(v["slot"]) >= 0:
			_stream_out(v)              # слот и узел отдаём ДО того, как забудем запись
	_made.clear()
	_rebuild_data()
	return n

## Жилы ОДНОГО региона. Своё зерно от сида мира и координат: соседний регион считается
## независимо, а этот всегда даёт одно и то же.
func _build_region(rk: Vector2i) -> Array:
	var job := _region_job(rk)
	_region_step(job, 0)
	return job["out"]

## ── HOW A REGION IS STOCKED (after TerraTech) ────────────────────────────────
## Nothing is strewn one point at a time any more. Every vein used to be its own roll - a point
## anywhere in the region, a quarter of them trees - so a "forest" was eight trees spread over 256 m
## and ore of every metal stood alone wherever it fell. TerraTech's ground is laid in GROUPS: trees
## stand in forests with open ground between them, rock comes as a field of several outcrops of ONE
## kind, and what grows and what is dug both follow the biome. So a region lays:
##   GROVES - a centre where the forest field (`_forest_noise`, one low-frequency noise of the seed)
##     stands over FOREST_CUT, and round it a clump of trees, more the denser the field; the biome
##     thins it (`_tree_keep`: the meadow thick, canyon and mountain thinner, palms in the desert in
##     small oases) and the salt flat takes all of it;
##   DEPOSITS - a centre in open ground (the forest field under DEPOSIT_FOREST_MAX, so ore stands in
##     clearings), its metal decided ONCE for the whole deposit (`_metal_for`), and DEPOSIT_VEINS of
##     that metal round it, DEPOSIT_RICH more in the canyon and on the mountains;
##   LONE TREES - LONE_TREES points anywhere the biome lets a tree stand, so open ground is not bare.
## Every member stays INSIDE its own region: a region is laid knowing nothing of its neighbours, and
## spacing is checked only within it. All the rng is drawn when the job is made, so the layout is
## the same however the work is sliced.
const GROVE_TRIES := 14
const FOREST_FREQ := 1.0 / 260.0
const FOREST_CUT := -0.05
## Simplex FBM rarely leaves +-0.6, so the grove is full at FOREST_CUT + FOREST_SPAN. THE FIRST
## NUMBERS GAVE 13 TREES A REGION, and the player saw "few groves, nothing changed": twice the tries,
## twice the trees a grove and a lower cut now (measured below in CLAUDE.md).
const FOREST_SPAN := 0.4
const GROVE_TREES := Vector2i(10, 28)
const GROVE_R := Vector2(12.0, 26.0)
const LONE_TREES := 6
const LONE_KEEP := 0.6
const DEPOSIT_TRIES := 7
const DEPOSIT_FOREST_MAX := 0.3
const DEPOSIT_VEINS := Vector2i(3, 5)
const DEPOSIT_RICH := 2
const DEPOSIT_R := 8.0
## Gaps between accepted points: a tree drawn at TREE_SCALE, a vein ~3 m across (VEIN_SIZE). The
## hash grid's cell is SPACE_CELL, which has to be at least the largest gap.
const TREE_GAP := 4.5
const ORE_GAP := 4.5
const SPACE_CELL := 5.0
## How thick a grove stands per biome (canyon, meadow, mountain, desert). THE CANYON GROWS NOTHING (the
## player's call): 0 here thins the blend at its rim, and a point over half canyon is refused outright.
const TREE_KEEP_BIOME := Vector4(0.0, 1.0, 0.45, 0.4)

var _forest: FastNoiseLite = null
var _forest_seed: int = -1

func _forest_noise() -> FastNoiseLite:
	var sd: int = int(G.world_seed)
	if _forest == null or _forest_seed != sd:
		_forest = FastNoiseLite.new()
		_forest.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
		_forest.seed = sd ^ 0x5f3e1
		_forest.frequency = FOREST_FREQ
		_forest.fractal_octaves = 2
		_forest_seed = sd
	return _forest

## A point round a cluster's centre, denser in the middle (radius linear in the roll, not its root).
static func _scatter(rng: RandomNumberGenerator, r: float) -> Vector2:
	var a: float = rng.randf() * TAU
	var d: float = rng.randf() * r
	return Vector2(cos(a) * d, sin(a) * d)

## A region's placement as a job that can stop between candidates and go on later (see REGION_FAR).
## Candidates are [point, cluster index, keep roll]; clusters carry what is decided per group.
func _region_job(rk: Vector2i) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(Vector3i(rk.x, rk.y, int(G.world_seed)))
	var forest := _forest_noise()
	var x0 := float(rk.x * REGION)
	var z0 := float(rk.y * REGION)
	var types: int = maxi(ore_colors.size(), 1)
	var clusters: Array = []
	var cand: Array = []
	for _i in GROVE_TRIES:
		var c := Vector2(x0 + rng.randf() * REGION, z0 + rng.randf() * REGION)
		var r: float = lerpf(GROVE_R.x, GROVE_R.y, rng.randf())
		var f: float = forest.get_noise_2d(c.x, c.y)
		if f <= FOREST_CUT:
			continue
		var t: float = clampf((f - FOREST_CUT) / FOREST_SPAN, 0.0, 1.0)
		var n: int = roundi(lerpf(float(GROVE_TREES.x), float(GROVE_TREES.y), t))
		clusters.append({"wood": true, "keep": 1.0})
		for _j in n:
			cand.append([c + _scatter(rng, r), clusters.size() - 1, rng.randf()])
	clusters.append({"wood": true, "keep": LONE_KEEP})
	for _i in LONE_TREES:
		cand.append([Vector2(x0 + rng.randf() * REGION, z0 + rng.randf() * REGION),
				clusters.size() - 1, rng.randf()])
	for _i in DEPOSIT_TRIES:
		var c := Vector2(x0 + rng.randf() * REGION, z0 + rng.randf() * REGION)
		var cl := {"wood": false, "c": c, "wild": rng.randf() < WILD_CHANCE,
				"wild_metal": rng.randi() % types, "roll": rng.randf(), "size": rng.randf(),
				"metal": -2, "n": 0, "placed": 0}
		var pts: Array = []
		for _j in DEPOSIT_VEINS.y + DEPOSIT_RICH:
			pts.append(c + _scatter(rng, DEPOSIT_R))
		if forest.get_noise_2d(c.x, c.y) > DEPOSIT_FOREST_MAX:
			continue                                   # ore stands in clearings, not under a forest
		clusters.append(cl)
		for q in pts:
			cand.append([q, clusters.size() - 1, 0.0])
	return {"rk": rk, "rng": rng, "out": [], "grid": {}, "cl": clusters, "cand": cand, "i": 0}

## Runs the job until its region is laid or `budget_usec` is spent (0: no limit); true when laid.
func _region_step(job: Dictionary, budget_usec: int) -> bool:
	var map: Node = get_parent()
	if map == null or not map.has_method("terrain_height_at"):
		return true
	var can_biome: bool = map.has_method("biome_at")
	var rk: Vector2i = job["rk"]
	var rng: RandomNumberGenerator = job["rng"]
	var out: Array = job["out"]
	var grid: Dictionary = job["grid"]
	var clusters: Array = job["cl"]
	var cand: Array = job["cand"]
	var x0 := float(rk.x * REGION)
	var z0 := float(rk.y * REGION)
	var t0 := Time.get_ticks_usec()
	while int(job["i"]) < cand.size():
		if budget_usec > 0 and Time.get_ticks_usec() - t0 > budget_usec:
			return false
		var e: Array = cand[int(job["i"])]
		job["i"] = int(job["i"]) + 1
		var pt: Vector2 = e[0]
		if pt.x < x0 or pt.y < z0 or pt.x >= x0 + REGION or pt.y >= z0 + REGION:
			continue                                   # a member past the region's edge
		var cl: Dictionary = clusters[int(e[1])]
		var wood: bool = cl["wood"]
		if not wood:
			if int(cl["metal"]) == -2:
				_decide_deposit(cl, map, can_biome)
			if int(cl["placed"]) >= int(cl["n"]) or not _ore_enabled(int(cl["metal"]), false):
				continue
		var world := Vector3(pt.x, 0.0, pt.y)
		var h: float = map.terrain_height_at(world)
		if h < min_height:
			continue
		var lp: Vector3 = to_local(Vector3(pt.x, h + 0.25, pt.y))
		if _slope_at(map, lp.x, lp.z) > max_slope:
			continue
		if not _space_free(grid, lp, TREE_GAP if wood else ORE_GAP):
			continue
		var kind: int = 0
		if wood:
			if not _ore_enabled(0, true):
				continue
			var gw := Vector3(pt.x, h, pt.y)
			if can_biome and map.has_method("salt_at") and float(map.salt_at(gw)) > 0.5:
				continue                               # no trees on a salt flat
			var b: Vector3 = map.biome_at(gw) if can_biome else Vector3(0.0, 1.0, 0.0)
			if b.x > 0.5:
				continue                               # no trees in a canyon (the player's call)
			if float(e[2]) > _tree_keep(b) * float(cl["keep"]):
				continue
			kind = _tree_kind_of(b, gw)
		var key := Vector2i(floori(lp.x / SPACE_CELL), floori(lp.z / SPACE_CELL))
		if not grid.has(key):
			grid[key] = []
		(grid[key] as Array).append(lp)
		if not wood:
			cl["placed"] = int(cl["placed"]) + 1
		out.append({
			"pos": lp,
			"gpos": Vector3(pt.x, h + 0.25, pt.y),
			"scene": resource_nodes[rng.randi() % resource_nodes.size()] \
					if not resource_nodes.is_empty() else null,
			"ore_type": ore_colors.size() if wood else int(cl["metal"]),
			"wood": wood, "tree": kind, "slot": -1, "node": null,
		})
	return true

## A deposit's metal and size, decided once from its centre: the metal by the biome there
## (`_metal_for`), DEPOSIT_RICH more veins where canyon or mountain holds the centre.
func _decide_deposit(cl: Dictionary, map: Node, can_biome: bool) -> void:
	var c: Vector2 = cl["c"]
	var b := Vector3(0.0, 0.0, 0.0)
	if can_biome:
		b = map.biome_at(Vector3(c.x, 0.0, c.y))
	cl["metal"] = _metal_for(b, can_biome and not bool(cl["wild"]), int(cl["wild_metal"]), float(cl["roll"]))
	var n: int = DEPOSIT_VEINS.x + int(float(cl["size"]) * float(DEPOSIT_VEINS.y - DEPOSIT_VEINS.x + 1))
	if maxf(b.x, b.z) > 0.5:
		n += DEPOSIT_RICH
	cl["n"] = mini(n, DEPOSIT_VEINS.y + DEPOSIT_RICH)

## How thick trees stand at a point, by its biome blend (TREE_KEEP_BIOME; the desert is what is left).
func _tree_keep(b: Vector3) -> float:
	var d: float = clampf(1.0 - maxf(b.x, maxf(b.y, b.z)), 0.0, 1.0)
	var total: float = b.x + b.y + b.z + d
	if total <= 0.001:
		return TREE_KEEP_BIOME.w
	return (b.x * TREE_KEEP_BIOME.x + b.y * TREE_KEEP_BIOME.y + b.z * TREE_KEEP_BIOME.z \
			+ d * TREE_KEEP_BIOME.w) / total

## Nothing accepted closer than `gap`: only this cell of the hash grid and its eight neighbours.
func _space_free(grid: Dictionary, p: Vector3, gap: float) -> bool:
	var cx := floori(p.x / SPACE_CELL)
	var cz := floori(p.z / SPACE_CELL)
	var g2: float = gap * gap
	for dx in [-1, 0, 1]:
		for dz in [-1, 0, 1]:
			var bucket = grid.get(Vector2i(cx + dx, cz + dz), null)
			if bucket == null:
				continue
			for q in (bucket as Array):
				if (q as Vector3).distance_squared_to(p) < g2:
					return false
	return true

# Steepness = the spread of the heights at 4 points round it, `s` metres out.
## ON THE GRID'S OWN NODES (`ChunkTerrain.cell_height`): four bilinear heights were sixteen corner
## reads, and far from the player every corner was a fresh generator call (five raw heights each) -
## the vein ring's whole cost, ~100 `raw_height_at` a candidate on the main thread. The point snaps
## to the nearest metre, so a candidate on the very edge of `max_slope` may decide the other way.
func _slope_at(map: Node, lx: float, lz: float) -> float:
	var s: float = 3.0
	if map.has_method("cell_height") and map.global_transform == Transform3D.IDENTITY:
		var cx: int = roundi(lx)
		var cz: int = roundi(lz)
		var a: float = map.cell_height(cx + 3, cz)
		var b: float = map.cell_height(cx - 3, cz)
		var c: float = map.cell_height(cx, cz + 3)
		var d: float = map.cell_height(cx, cz - 3)
		return maxf(maxf(a, b), maxf(c, d)) - minf(minf(a, b), minf(c, d))
	var hx1: float = map.terrain_height_at(map.global_transform * Vector3(lx + s, 0.0, lz))
	var hx2: float = map.terrain_height_at(map.global_transform * Vector3(lx - s, 0.0, lz))
	var hz1: float = map.terrain_height_at(map.global_transform * Vector3(lx, 0.0, lz + s))
	var hz2: float = map.terrain_height_at(map.global_transform * Vector3(lx, 0.0, lz - s))
	return maxf(maxf(hx1, hx2), maxf(hz1, hz2)) - minf(minf(hx1, hx2), minf(hz1, hz2))

# Буфер MultiMesh на max_visible слотов, все схлопнуты. ДАННЫЕ жил сюда больше не входят: их
# рождают регионы по мере приближения игрока (_build_region), а здесь только пул слотов, который
# они делят между собой.
#
# Потолок берём ровно max_visible, а не «сколько жил насчитали»: жил в мире без края бесконечно
# много, а одновременно нарисованных — столько, сколько влезает в радиус.
func _init_slots() -> void:
	var cap: int = maxi(max_visible, 1)
	var big := AABB(Vector3(-2000.0, -2000.0, -2000.0), Vector3(4000.0, 4000.0, 4000.0))
	for mm in _all_mm():
		mm.custom_aabb = big
		mm.multimesh.instance_count = 0
		mm.multimesh.use_custom_data = true         # буфер custom-data ДО instance_count
		# THE INSTANCE COLOUR MULTIPLIES THE VERTEX COLOUR in Compatibility, and without use_colors
		# it is black: measured on the real driver, every vein drew as a black silhouette.
		mm.multimesh.use_colors = true
		mm.multimesh.instance_count = cap
		mm.multimesh.visible_instance_count = 0     # only the live ones are drawn (see _mm_live)
		_mm_live[mm] = []

## КАКОЙ МЕТАЛЛ ЛЕЖИТ В ЭТОЙ ТОЧКЕ.
##
## Раньше тип жилы был просто `randi() % 4`, и это молча обесценивало всю карту: титанит с
## равной вероятностью лежал под колёсами и за тремя хребтами, значит ехать было незачем —
## копай где стоишь. Теперь металл принадлежит БИОМУ, и дорогой лежит там, куда труднее
## добраться:
##
##   пустыня (базовый слой) → феррит, самый дешёвый и самый частый;
##   луг                    → куприт;
##   каньон                 → силикат;
##   горы                   → титанит, самый дорогой.
##
## Веса, а не жёсткое соответствие. Во-первых, биомы у нас плавно переходят друг в друга
## (маски дробные), и резкая граница «здесь только титанит» выглядела бы нарисованной. Во-
## вторых, `WILD_CHANCE` оставляет долю жил вопреки правилу: карта, разложенная по полочкам
## идеально, читается как таблица, а не как местность, и случайная богатая жила под боком —
## это маленький подарок, ради которого игрок и смотрит по сторонам.
const WILD_CHANCE := 0.15

## Разрешён ли этот тип жилы отладочными флажками Main. Порядок металлов тот же, что в
## G.Metal и в ore_colors: феррит, куприт, силикат, титанит; уголь идёт следом отдельным типом.
const ORE_FLAGS := [&"ore_ferrite", &"ore_cuprite", &"ore_silicate", &"ore_titanite"]

func _ore_enabled(ore_type: int, wood: bool) -> bool:
	if wood:
		return G.debug(&"ore_wood")
	return G.debug(ORE_FLAGS[ore_type]) if ore_type < ORE_FLAGS.size() else true

## `wild_metal` when the deposit is a wild one (or no biome answers), else a roll over the biome's weights.
func _metal_for(m: Vector3, by_biome: bool, wild_metal: int, roll01: float) -> int:
	var types: int = maxi(ore_colors.size(), 1)
	if not by_biome:
		return wild_metal % types
	# biome_at отдаёт (каньон, луг, горы); пустыня — это то, что осталось.
	var desert: float = clampf(1.0 - maxf(m.x, maxf(m.y, m.z)), 0.0, 1.0)
	var weights := [desert, m.y, m.x, m.z]        # феррит, куприт, силикат, титанит
	var total: float = 0.0
	for i in mini(weights.size(), types):
		total += maxf(float(weights[i]), 0.0)
	if total <= 0.001:
		return 0                                   # ни один биом не выражен — базовый металл
	var roll: float = roll01 * total
	for i in mini(weights.size(), types):
		roll -= maxf(float(weights[i]), 0.0)
		if roll <= 0.0:
			return i
	return 0

# Жила вошла в радиус: берём слот из пула, рисуем инстанс + создаём узел (добыча/коллизия).
func _stream_in(v: Dictionary) -> void:
	# ДЕРЕВО НЕ ВЫРАСТАЕТ ВНУТРИ ПОСТРОЙКИ, И ПРОВЕРЯТЬ ЭТО НАДО ЗДЕСЬ, А НЕ ТОЛЬКО НА ПЕРЕСАДКЕ.
	# _data собирается из СИДА заново при каждом заходе, то есть пересадки прошлого сеанса
	# забываются: игрок срубил дерево, построил на этом месте базу, перезашёл — и дерево вернулось
	# ровно туда, где теперь стоит его база. Пересадка тут не спасает: она случается по таймеру
	# отдыха, а это дерево уже полное и отдыхать не собирается.
	#
	# Смотрим ТОЛЬКО машины: жилы разведены ещё при раскладке, а проход по всем данным на каждом
	# стриминге стоил бы дорого — стриминг идёт, пока игрок едет.
	if v.get("wood") == true and _machine_near(v["pos"]):
		var spot = _free_spot_near(v["pos"], v, false)
		if spot == null:
			return                                   # вокруг всё занято: лучше без дерева, чем в стене
		v["pos"] = spot["pos"]
		v["gpos"] = spot["gpos"]
	var own: MultiMeshInstance3D = _model_mm(v)
	if own == null or not _mm_live.has(own):
		return
	var recs: Array = _mm_live[own]
	if recs.size() >= own.multimesh.instance_count:
		return                                       # this model's max_visible is full - rare
	var slot: int = recs.size()
	recs.append(v)
	v["slot"] = slot
	# Each vein turned and sized by its own point: one model, and no two outcrops alike. From the
	# position, so a vein comes back the same every time it streams in.
	var ts: Vector2 = _turn_of(v["gpos"], v.get("wood") == true)
	var vbasis := Basis(Vector3.UP, ts.x).scaled(Vector3.ONE * ts.y)
	var xform := Transform3D(vbasis, v["pos"])
	# G=1 whole, A the type; B the time it came back - a replanted tree grows in its new spot
	var custom := Color(0.0, 1.0, 0.0, float(v["ore_type"]))
	if v.get("regrow") == true:
		v.erase("regrow")
		custom.b = shader_now()
	v["xf"] = xform
	v["cd"] = custom
	own.multimesh.set_instance_transform(slot, xform)
	own.multimesh.set_instance_color(slot, Color.WHITE)
	own.multimesh.set_instance_custom_data(slot, custom)
	own.multimesh.visible_instance_count = recs.size()
	if v["scene"] != null:
		var node: Node3D = v["scene"].instantiate()
		node.position = v["pos"]
		node.instance_id = slot                      # узел пишет истощение в ЭТОТ слот
		if "is_wood" in node: node.is_wood = v["wood"]
		if "tree_kind" in node: node.tree_kind = int(v.get("tree", 0))
		node.set_meta("vein_basis", vbasis)
		if v.get("wood") == true:
			var col := node.get_node_or_null("CollisionShape3D") as CollisionShape3D
			if col != null:
				if _tree_shape == null:
					_tree_shape = CylinderShape3D.new()
					_tree_shape.radius = 0.3 * TREE_SCALE
					_tree_shape.height = 3.5 * TREE_SCALE      # the trunk up into the crown
				col.shape = _tree_shape
				col.position = Vector3(0.0, _tree_shape.height * 0.5, 0.0)
		else:
			var col := node.get_node_or_null("CollisionShape3D") as CollisionShape3D
			if col != null:
				if _ore_shape == null:
					_ore_shape = CylinderShape3D.new()
					_ore_shape.radius = 0.5 * VEIN_SIZE              # the models are ~1 m across
					_ore_shape.height = 0.8 * VEIN_SIZE              # from under the ground to the top
				col.shape = _ore_shape
				col.position = Vector3(0.0, _ore_shape.height * 0.5 - 0.3, 0.0)
		if "ore_type" in node: node.ore_type = v["ore_type"]
		if "ore_color" in node and int(v["ore_type"]) < ore_colors.size():
			node.ore_color = ore_colors[v["ore_type"]]
		v["node"] = node                             # before add_child: its _ready writes through it
		add_child(node)

## How high over its point a vein reaches: its model's top times its size (`_turn_of`).
func _vein_top(v: Dictionary) -> float:
	var mm: MultiMeshInstance3D = _model_mm(v)
	if mm == null:
		return OCCL_VEIN_HEIGHT
	var top = _top_of.get(mm)
	if top == null:
		var mesh: Mesh = mm.multimesh.mesh if mm.multimesh != null else null
		top = maxf(mesh.get_aabb().end.y, OCCL_VEIN_HEIGHT) if mesh != null else OCCL_VEIN_HEIGHT
		_top_of[mm] = top
	return float(top) * _turn_of(v["gpos"], v.get("wood") == true).y

## A vein's turn (x, radians) and size (y) from its point: the model (`_stream_in`) and the far tree's
## picture (`_process`) both read it here, or a far tree would turn and grow as it came near.
func _turn_of(gp: Vector3, wood: bool) -> Vector2:
	var hh: int = hash(Vector2i(int(gp.x * 8.0), int(gp.z * 8.0)))
	var yaw: float = float(hh % 6283) * 0.001
	var size: float = VEIN_SCALE_MIN + float((hh >> 13) % 1000) * 0.001 * (VEIN_SCALE_MAX - VEIN_SCALE_MIN)
	return Vector2(yaw, size * (TREE_SCALE if wood else VEIN_SIZE))

## ЖИВАЯ ЖИЛА ВОЗЛЕ ТОЧКИ — узел, а не запись в _data. Спрашивать можно только про то, что
## сейчас стримнуто: узел с коллизией существует лишь рядом с камерой. Это ровно то, что нужно
## сюжету — он ищет жилу тогда, когда игрок до неё доехал, а не когда объявляет задание.
## ЖИЛА ПО ДАННЫМ, А НЕ ПО УЗЛУ. node_near ниже ищет среди ОТРИСОВАННЫХ жил, то есть только там,
## где игрок уже стоит: жилы стримятся. А квесту нужна точка ЗАРАНЕЕ — чтобы метка вела к
## настоящей жиле с самого объявления, а не к случайной точке рядом с ней.
##
## Данные для этого есть: _data держит записи регионов вокруг игрока (REGION 256 м, REGION_KEEP 1
## — это 768 м в поперечнике), и считаются они от сида, независимо от того, что нарисовано.
##
## Возвращает мировую точку или null. lo/hi — в каком кольце от from искать.
func vein_point_near(from: Vector3, lo: float, hi: float, wood_only: bool = false) -> Variant:
	var best: Variant = null
	var best_d: float = INF
	for rec in _data:
		var gp = rec.get("gpos")
		if gp == null or (wood_only and rec.get("wood") != true):
			continue
		var d: float = (gp as Vector3).distance_to(from)
		if d < lo or d > hi:
			continue
		# Ближайшая К СЕРЕДИНЕ кольца, а не к игроку: у самого края кольца жила окажется либо
		# под носом, либо на пределе, и «съезди за аккумулятором» перестанет быть поездкой.
		var score: float = absf(d - (lo + hi) * 0.5)
		if score < best_d:
			best_d = score
			best = gp
	return best

func node_near(world_pos: Vector3, radius: float = 25.0, wood_only: bool = false) -> Node:
	var best: Node = null
	var best_d2: float = radius * radius
	for c in get_children():
		if not (c is Node3D) or not c.has_method("is_depleted"):
			continue
		if wood_only and c.get("is_wood") != true:
			continue
		var d2: float = (c as Node3D).global_position.distance_squared_to(world_pos)
		if d2 <= best_d2:
			best_d2 = d2
			best = c
	return best

# Жилы ВОКРУГ ТОЧКИ для блипов на радаре (hud.gd): позиция и ЦВЕТ МЕТАЛЛА.
#
# Цвет здесь не украшение. С тех пор как металл принадлежит биому (_metal_for), «съездить за
# титанитом» стало осмысленным действием — но только если игрок видит, за чем едет. Одинаково
# жёлтые точки этого не говорят, а цвет жилы в мире и цвет её блипа — это один и тот же
# G.METAL_COLOR, так что радар не может соврать про то, что стоит на земле.
#
# Раньше отдавались «сейчас стримнутые» жилы, и это совпадало с радиусом радара само собой.
# Теперь стриминг отсекает то, что за спиной и за хребтом, а радар смотрит СВЕРХУ и во все
# стороны сразу: по нему как раз и разворачиваются к жиле, которой не видно. Поэтому считаем
# по данным и по расстоянию, а не по тому, нарисована ли жила.
func active_blips(around: Vector3 = Vector3.INF, radius: float = -1.0) -> Array:
	var center: Vector3 = around
	if center == Vector3.INF:
		var cam := get_viewport().get_camera_3d()
		center = cam.global_position if cam != null else Vector3.ZERO
	var r2: float = (radius if radius > 0.0 else render_distance)
	r2 *= r2
	var out: Array = []
	for v in _data:
		var p: Vector3 = v["gpos"]
		if center.distance_squared_to(p) > r2:
			continue
		var t: int = int(v["ore_type"])
		out.append({"p": p, "c": wood_color if t >= ore_colors.size() else ore_colors[t]})
	return out

# Жила вышла из радиуса: гасим инстанс, освобождаем узел и возвращаем слот в пул.
## СРУБЛЕННОЕ ДЕРЕВО ПЕРЕЕЗЖАЕТ НЕДАЛЕКО, А НЕ ОТРАСТАЕТ НА ПНЕ. Жила руды после отдыха
## наливается там же, и это верно: месторождение никуда не делось, его просто не успели
## выбрать. Лес так не читается — вырубил, стало пусто, а поднялось рядом.
##
## РАДИУС МАЛЕНЬКИЙ НАМЕРЕННО. Чистый случай по всей карте развалил бы плотность: регион
## раскладывает СВОЁ число деревьев, и если каждое срубленное улетает куда угодно, лес
## стягивается туда, где больше рубили. Восемь метров оставляют дерево в своём лесу, но не на
## своём месте.
##
## КРУГ ПРОВЕРЯЕТСЯ НА ЗАНЯТОСТЬ: чужая жила, чужое дерево, машина или база. Без этого дерево
## однажды вырастет в борту базы или внутри другой жилы — и то и другое выглядит поломкой, а
## не лесом.
##
## Точка ищется ТЕМИ ЖЕ проверками, что и при раскладке (высота, склон), но СВОИМ генератором,
## а не региональным: региональный обязан давать одно и то же при каждом заходе, иначе карта
## перестанет быть функцией сида. Поэтому пересадка живёт только в текущем сеансе — перезашёл,
## и деревья снова там, где их положил сид.
const REPLANT_RADIUS: float = 8.0
## Насколько далеко держаться от чужой жилы и от машины. Разные числа: жилы просто не должны
## налезать друг на друга, а машину дерево не должно подпирать вплотную.
const REPLANT_CLEAR_NODE: float = 3.0
const REPLANT_CLEAR_MACHINE: float = 6.0
const REPLANT_TRIES: int = 16

func replant(node: Node) -> bool:
	var map: Node = get_parent()
	if map == null or not map.has_method("terrain_height_at"):
		return false
	for v in _data:
		if v.get("node") != node:
			continue
		var spot = _free_spot_near(v["pos"], v, true)
		if spot == null:
			return false
		_stream_out(v)                           # слот и узел отдаём: пусть стримится заново
		v["pos"] = spot["pos"]
		v["gpos"] = spot["gpos"]
		v["regrow"] = true                       # grows in its new spot (resource.gdshader)
		# STRAIGHT BACK IN: it stood in view, and the streaming pass reruns only when the camera
		# crosses a cell (RESCAN_CELL), so a player standing at the stump never saw it grow back.
		_stream_in(v)
		return true
	return false

## Занята ли точка ЧУЖОЙ ЖИЛОЙ. Проход по всем данным, поэтому спрашивается только на пересадке
## — она случается раз в отдых одного дерева. На стриминге этого делать нельзя: он идёт
## постоянно, пока игрок едет.
func _node_near(lp: Vector3, self_v: Dictionary) -> bool:
	var rn2: float = REPLANT_CLEAR_NODE * REPLANT_CLEAR_NODE
	for o in _data:
		if o == self_v:
			continue
		if (o["pos"] as Vector3).distance_squared_to(lp) < rn2:
			return true
	return false

## Занята ли точка МАШИНОЙ ИЛИ БАЗОЙ. Машин единицы, поэтому спрашивать можно хоть каждый
## стриминг.
func _machine_near(lp: Vector3) -> bool:
	var vehicles: Node = get_node_or_null("/root/Main/Vehicles")
	if vehicles == null:
		return false
	var gp: Vector3 = to_global(lp)
	var rm2: float = REPLANT_CLEAR_MACHINE * REPLANT_CLEAR_MACHINE
	for m in vehicles.get_children():
		if m is Node3D and (m as Node3D).global_position.distance_squared_to(gp) < rm2:
			return true
	return false

## Свободная точка в радиусе пересадки вокруг `from`. Возвращает null, если за REPLANT_TRIES
## попыток ничего не нашлось: значит вокруг сплошь занято, и лучше не показывать дерево вовсе,
## чем воткнуть его в постройку.
func _free_spot_near(from: Vector3, self_v: Dictionary, check_nodes: bool) -> Variant:
	var map: Node = get_parent()
	if map == null or not map.has_method("terrain_height_at"):
		return null
	# ПЕРЕСАДКА — ЭТО ПЕРЕЕЗД, А НЕ РАСКЛАДКА, ПОЭТОМУ `min_height` ЗДЕСЬ НЕ СПРАШИВАЕТСЯ. Тот
	# порог отсеивает днища впадин при раскладке ОТ СИДА; дерево, которое уже стоит, порог когда-то
	# прошло, а в круге восьми метров высота не может уйти дальше, чем позволит max_slope ниже.
	# Спрашивать его снова — значит запретить переезд там, где вся земля ниже порога: на полигоне
	# земля плоская (h = 0.0 против min_height 2.0), и все шестнадцать попыток отсеивались молча.
	# Замерено на движке: срубленное дерево через 14 с оставалось на пне, узлов и записей 7 → 7.
	for _i in REPLANT_TRIES:
		var ang: float = randf() * TAU
		var dist: float = sqrt(randf()) * REPLANT_RADIUS   # равномерно по КРУГУ, а не по радиусу
		var gp: Vector3 = to_global(from) + Vector3(cos(ang) * dist, 0.0, sin(ang) * dist)
		var h: float = map.terrain_height_at(gp)
		var lp: Vector3 = to_local(Vector3(gp.x, h + 0.25, gp.z))
		if _slope_at(map, lp.x, lp.z) > max_slope:
			continue
		if check_nodes and _node_near(lp, self_v):
			continue
		if _machine_near(lp):
			continue
		return {"pos": lp, "gpos": Vector3(gp.x, h + 0.25, gp.z)}
	return null

func _stream_out(v: Dictionary) -> void:
	var slot: int = int(v["slot"])
	var own: MultiMeshInstance3D = _model_mm(v)
	if own != null and _mm_live.has(own):
		var recs: Array = _mm_live[own]
		var last: int = recs.size() - 1
		if slot >= 0 and slot <= last:
			# The model's last live vein moves into the freed slot, so its live ones stay 0..n-1.
			if slot != last:
				var mv: Dictionary = recs[last]
				recs[slot] = mv
				mv["slot"] = slot
				own.multimesh.set_instance_transform(slot, mv["xf"])
				own.multimesh.set_instance_custom_data(slot, mv["cd"])
				if is_instance_valid(mv.get("node")):
					mv["node"].instance_id = slot
			recs.pop_back()
			own.multimesh.visible_instance_count = recs.size()
	if is_instance_valid(v.get("node")):
		v["node"].queue_free()
	v["node"] = null
	v["slot"] = -1

# ── Стриминг: держим отрисованными/активными только жилы в render_distance ─────
## КЛЕТКА ПЕРЕСЧЁТА. Приём взят у HTerrain (hterrain_detail_layer): он пересобирает свои
## куски не по таймеру, а когда наблюдатель ПЕРЕСЁК границу клетки. Полный проход по двум
## тысячам жил четыре раза в секунду не нужен, пока игрок стоит в гараже или ползёт по
## стройке: ответ не может измениться, если камера не сдвинулась ощутимо.
const RESCAN_CELL := 12.0
var _last_cell := Vector2i(1 << 30, 1 << 30)

func _process(delta: float) -> void:
	_tick_clock()
	_region_jobs_tick()
	if _data.is_empty():
		return
	_cull_t -= delta
	if _cull_t > 0.0:
		return
	_cull_t = cull_interval
	var _pf := Perf.now()          # метка для панели профиля (perf.gd)
	_regions_tick()                # игрок мог переехать в соседний регион — родим его жилы
	# Камера не ушла из своей клетки — пересчитывать нечего. Направление взгляда сюда НЕ
	# входит намеренно: жила гаснет и зажигается по направлению, и пропустить поворот значило
	# бы держать за спиной то, что мы только что научились гасить.
	var cam0 := get_viewport().get_camera_3d()
	if cam0 != null:
		var cell := Vector2i(int(floor(cam0.global_position.x / RESCAN_CELL)),
				int(floor(cam0.global_position.z / RESCAN_CELL)))
		var fwd0: Vector3 = -cam0.global_transform.basis.z
		if cell == _last_cell and fwd0.dot(_last_fwd) > 0.999:
			Perf.mark("veins", _pf)
			return
		_last_cell = cell
		_last_fwd = fwd0
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	var cam_pos: Vector3 = cam.global_position
	_recentre_bounds(cam_pos)
	var fwd: Vector3 = -cam.global_transform.basis.z
	var d2: float = render_distance * render_distance
	var keep2: float = keep_radius * keep_radius
	# Жилу за хребтом не рисуем и не оживляем: узел с коллизией и слот MultiMesh стоят одинаково
	# что перед горой, что за ней. Спрашиваем у рельефа по карте высот (map.is_point_hidden) и
	# ПОРЦИЯМИ — ответ меняется только от движения камеры, а жил тысячи.
	var terr: Node = get_parent()
	var can_occlude: bool = terr != null and terr.has_method("is_point_hidden")
	var n: int = _data.size()
	var slice_from: int = _occl_cursor
	@warning_ignore("integer_division")
	var step: int = maxi(n / OCCL_SLICES, 1)
	_occl_cursor = (_occl_cursor + step) % maxi(n, 1)
	var slice_to: int = slice_from + step
	var far2: float = FAR_TREES * FAR_TREES
	var cards: Array = []
	var pts: Array = G.active_points()          # once a pass, not once a vein (G.near_active)
	var i: int = -1
	for v in _data:
		i += 1
		var gp: Vector3 = v["gpos"]
		var to: Vector3 = gp - cam_pos
		var dist2: float = to.length_squared()
		# В радиусе И (близко ИЛИ впереди). Направление считаем только для дальних: у жилы
		# под колёсами направление вырождается, да и гасить её нельзя.
		# БЛИЖНИЙ ПУЗЫРЬ СЧИТАЕТСЯ ОТ ЛЮБОЙ ЖИВОЙ ТОЧКИ (G.active_points), а не от камеры: жила
		# это не картинка, а узел с коллизией, по которому работают бур и авто-шахтёр. У базы
		# на другом конце карты бур грызёт свою жилу, пока игрок ездит другой машиной, — и если
		# мерить только от камеры, жила под ним исчезнет вместе с добычей.
		var kept: bool = dist2 <= keep2
		if not kept:
			for q in pts:
				if (q as Vector3).distance_squared_to(gp) <= keep2:
					kept = true
					break
		# kept идёт ПЕРВЫМ и без оглядки на радиус камеры: жила у базы за пятьсот метров всё
		# равно обязана быть узлом, иначе стоящий на ней авто-шахтёр добывает воздух.
		var near: bool = kept or (dist2 <= d2 and to.normalized().dot(fwd) >= view_cos)
		if near and can_occlude and not kept \
				and (v.get("hidden", false) or (i >= slice_from and i < slice_to)):
			v["hidden"] = terr.is_point_hidden(gp, _vein_top(v), v.get("hidden", false))
		if near and not kept and v.get("hidden", false):
			near = false
		var shown: bool = int(v["slot"]) >= 0
		if near and not shown:
			_stream_in(v)
		elif not near and shown:
			_stream_out(v)
		# A FAR VEIN: past the models' reach, ahead, standing, drawn as its picture - a tree (a felled
		# one keeps G under a half until it comes back) or an ore vein (an emptied one, G at 0, is
		# rubble and gets none). Kind: the tree's model, or ORE_KIND0 + the metal.
		if not near and dist2 > d2 and dist2 <= far2 and to.dot(fwd) >= view_cos * sqrt(dist2):
			var wood: bool = v.get("wood") == true
			var cut: float = 0.5 if wood else 0.01
			if not (v.has("cd") and (v["cd"] as Color).g < cut):
				var ts: Vector2 = _turn_of(gp, wood)
				var kind: int = int(v.get("tree", 0)) if wood \
						else FAR_TREES_SCRIPT.ORE_KIND0 + clampi(int(v.get("ore_type", 0)), 0, 3)
				cards.append([v["pos"], ts.x, ts.y, kind])
	if _far != null:
		_far.set_trees(cards)
	Perf.mark("veins", _pf)


# Родитель, умеющий отвечать как карта. null, если не дождались.
func _await_map() -> Node:
	var map: Node = get_parent()
	var guard: int = 0
	while guard < MAP_WAIT_FRAMES:
		if map != null and map.has_method("terrain_height_at") and map.has_method("get_dims"):
			return map
		await get_tree().process_frame
		guard += 1
		map = get_parent()
	return null
