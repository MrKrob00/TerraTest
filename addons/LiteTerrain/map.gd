# map.gd — the LiteTerrain terrain node: a StaticBody3D with HeightMapShape3D collision and an
# ArrayMesh, plus quadtree LOD, streaming collision and the grass shader. The LiteTerrain dock
# creates one at the press of a button and can generate, sculpt and bake it.
@tool
class_name LiteTerrain
extends StaticBody3D

## The camera LOD and culling are measured from. LEAVE IT EMPTY unless you need something
## unusual: by default the currently active camera is used, so the terrain follows it even
## across camera switches. Set it only to drive LOD from a camera that is NOT the active one.
@export var camera: Camera3D

# The camera in effect this frame: the manual override if one is set and still alive, else the
# active one. Refreshed every frame in _process, so nothing needs assigning.
var _cam: Camera3D = null

## The surface material. Defaults to the addon's terrain shader (biome colours plus grass) so
## a freshly created node looks right immediately. Swap in your own ShaderMaterial if you like.
##
## APPEARANCE (tile texture, texture_blend, tile_world_size, low_quality) is configured ON THE
## MATERIAL itself, under its Shader Parameters — the node does not duplicate those. Biome
## colours and grass come from the biomes resource below and overwrite the material's copies.
@export var surface_material: Material = preload("res://addons/LiteTerrain/terrain_shader.res")

# Hide the settings of anything switched off, to keep the inspector clean.
func _validate_property(property: Dictionary) -> void:
	# heightmap_path only matters in image mode.
	if property.name == "heightmap_path" and not use_image_data:
		property.usage = PROPERTY_USAGE_NO_EDITOR
@export_range(-0.5, 0.5, 0.01) var frustum_margin: float = -0.05
@export var enable_frustum_culling: bool = true
## How far terrain is drawn. Anything past this is hidden without a frustum test. Match it to
## your visibility distance (fog, if you use it): terrain drawn past what the player can make
## out is pure cost.
@export var max_render_distance: float = 1400.0

# ── Occlusion culling settings ────────────────────────────────────────────────
## Hide chunks whose AABB top sits below the terrain horizon seen from the camera.
## Uses the elevation-angle (horizon) method: samples the heightmap along the
## XZ ray from the camera to each chunk and tracks the maximum terrain angle.
## If the terrain horizon exceeds the angle to the chunk top, the chunk is occluded.
@export var enable_occlusion_culling: bool = false
## XZ distance (world units) below which chunks are never occlusion-culled.
## NOTE: the horizon method false-culls on a steep top-down camera (black holes in the
## terrain), so occlusion is OFF by default — these knobs only matter if you re-enable it.
@export_range(0.0, 200.0, 1.0) var occlusion_min_dist: float = 40.0
## Added to the chunk AABB top before the horizon test (higher = more conservative).
@export_range(0.0, 10.0, 0.5) var occlusion_bias: float = 1.5
## Heightmap samples taken along each camera→chunk ray. More = fewer misses, more CPU.
@export_range(2, 24, 1) var occlusion_samples: int = 8
## Metres between horizon samples. The sample count is derived from the ray length and this
## (see _is_aabb_occluded), so a long ray is not read any coarser than a short one.
const OCCLUSION_STRIDE: float = 6.0

@export var chunk_size: int = 16

## Biome settings: noise thresholds and scales (shape and layout) plus colours and grass. One
## resource for the whole pipeline — the landform generator, the masks and the material all
## read it. Leave it empty and the node makes a default set; save it as a .tres to edit.
@export var biomes: TerrainBiomes = null : set = _set_biomes

func _set_biomes(v: TerrainBiomes) -> void:
	biomes = v
	_push_biomes_to_materials()

# There is always a resource; without one the defaults would have to be repeated in every formula.
func _biomes() -> TerrainBiomes:
	if biomes == null:
		biomes = TerrainBiomes.new()
	return biomes

func _push_biomes_to_materials() -> void:
	if biomes == null:
		return
	if _mat_lod0 is ShaderMaterial:
		biomes.apply_to_material(_mat_lod0 as ShaderMaterial)
	if _mat_lod_high is ShaderMaterial:
		biomes.apply_to_material(_mat_lod_high as ShaderMaterial)

# ── LOD settings ─────────────────────────────────────────────────────────────
# Toggle LOD on/off without changing distances
@export var enable_lod: bool = true

# XZ distance thresholds (in world units) at which LOD switches:
#   dist < lod_distance_0  →  LOD 0  (step=1, full res, 512 tris/chunk)
#   dist < lod_distance_1  →  LOD 1  (step=2, ¼ tris, ~128/chunk)
#   dist < lod_distance_2  →  LOD 2  (step=4, 1/16 tris, ~32/chunk)
#   dist ≥ lod_distance_2  →  LOD 3  (step=8, 1/64 tris, ~8/chunk)
## How far a chunk may deviate from a simple four-corner surface and still count as FLAT, in
## world units. Flat ground and even slopes are drawn with large triangles: no visible
## difference, a fraction of the vertices. 0 disables it and LOD goes purely by distance.
@export var flat_lod_error: float = 0.35
@export var lod_distance_0: float = 40.0
@export var lod_distance_1: float = 80.0
@export var lod_distance_2: float = 160.0

# Vertex sampling step per LOD level (index = LOD level)
const LOD_STEPS: Array[int] = [1, 2, 4]   # LOD3 (step 8) dropped — never shown at runtime

## TRIANGLE SIZE in world units — the grid cell side at the finest LOD.
## 1 puts a vertex on every heightmap cell; 2 is a quarter of the vertices, 4 a sixteenth.
## Note that grass is a displaced vertex, so coarsening thins the grass along with the mesh.
## It scales the WHOLE hierarchy at once (chunks, macro meshes, quadtree coarse meshes), so
## the seam stitching between differing LODs still lines up.
@export_enum("1 (detailed)", "2 (recommended)", "4 (max FPS)") var triangle_size: int = 0


# Grid step for the given LOD level, scaled by triangle_size.
func _step_for(lod: int) -> int:
	return LOD_STEPS[clampi(lod, 0, LOD_STEPS.size() - 1)] * (1 << triangle_size)
const LOD_COUNT: int        = 3

# How often (seconds) the LOD check runs — no need every frame
const LOD_UPDATE_INTERVAL: float = 0.15

# ── Editor view settings ──────────────────────────────────────────────────────
## OFF (default): the editor bakes ONE full-resolution merged mesh for the whole map
## (current behaviour — fine for small maps, heavy for huge ones).
## ON: the editor builds the WHOLE map but with LOD — distant chunks low-poly, near
## chunks full-res — using the same lod_distance_* thresholds as the game. The merged
## mesh is only rebuilt after the editor camera STOPS moving (no per-move lag), and on
## sculpt. Seams are snapped just like at runtime, so no LOD cracks.
@export var editor_lod: bool = false
## КАК ДАЛЕКО РЕДАКТОР ВООБЩЕ СТРОИТ МЕШ (0 = вся карта, как раньше).
##
## Превью в редакторе строилось на ВСЮ карту: на 1984² это пятнадцать тысяч чанков и четыре
## миллиона вершин — за один заход, и заново после каждого движения камеры. Отсюда и минуты
## на «Generate Terrain». Смотреть на всю карту разом всё равно незачем: за шестьсот метров от
## камеры видно контур, а не рельеф. Дальние чанки просто не строятся — в игре они, как и
## раньше, стримятся сами.
@export_range(0.0, 4000.0, 50.0) var editor_view_distance: float = 600.0

# ── Streaming settings ────────────────────────────────────────────────────────
## How many chunks are meshed per streaming batch. Lower = fewer frame hitches.
@export_range(4, 128, 4) var stream_batch_size: int = 8

# ── Macro-chunk settings ──────────────────────────────────────────────────────
# Groups of MACRO_SIZE×MACRO_SIZE individual chunks are merged into one
# MeshInstance3D (shadows OFF) for dist ≥ lod_distance_1.
# 4×4 = 16 chunks → 1 draw call instead of 16 (+ saves ~16 shadow passes).
const MACRO_SIZE: int = 4

# ── Heightmap data source ─────────────────────────────────────────────────────
## Master heightmap (R32F Image saved as .res), the single source of truth for both
## the visual chunks and the streaming collision. Bake it from the editor terrain via
## the plugin's "Bake heightmap → image" button. If missing, falls back at runtime to
## the embedded CollisionShape3D HeightMapShape3D data (so nothing breaks pre-bake).
@export_file("*.res", "*.exr", "*.png") var heightmap_path: String = "res://addons/LiteTerrain/terrain_height.res"

## Master decoupling switch. ON = the R32F image is the ONLY heightmap source, in the
## editor AND at runtime; the giant HeightMapShape3D is never used for data, the editor
## sculpts by ray-marching the heightmap (no physics needed), and runtime always uses
## the streaming collision window. This is what lets the map grow huge — detach the big
## terrain.res/terrain_mesh.res from the scene (plugin button) and nothing heavy loads.
## OFF (default) = previous behaviour (embedded shape is data + collision).
@export var use_image_data: bool = true:
	set(v):
		use_image_data = v
		notify_property_list_changed()   # shows or hides heightmap_path

# ── Streaming collision settings ──────────────────────────────────────────────
## Master switch. OFF (default) = current behaviour: the embedded HeightMapShape3D is
## both the data and the collision (whole map). ON = data comes from the R32F image and
## collision becomes a small window that follows the player — required for huge maps.
## NOTE while ON: only terrain inside the window has collision, so bodies far from the
## active vehicle (other parked vehicles, spread-out objects) sit on no ground. Size the
## window to cover your play area, or keep OFF until the map is genuinely large.
@export var enable_streaming_collision: bool = true
## Collision follows every MOVING physics body in the scene (RigidBody3D, VehicleBody3D,
## CharacterBody3D) automatically — no node paths to set up, works with any project. Each
## tracked body gets its own sliding HeightMapShape3D window; bodies that ride ON another
## body (e.g. parts welded to a vehicle) are skipped, the parent's window covers them.
## Bodies are discovered via node_added/node_removed signals — no per-frame polling.
##
## Collision is a GRID of tiled HeightMapShape3D cells. A body marks every cell within
## collision_radius as needed; bodies sharing a cell share its window.
@export_range(16, 256, 8) var collision_cell:   int = 16   # heightmap cells per collision tile
@export_range(4, 256, 4)  var collision_radius: int = 8    # cells covered around each tracked body
## How many samples a tile reaches into its neighbour. Jolt treats a heightfield's outer edge
## as an active edge and a wheel catches on it; the overlap lays the neighbour's real surface
## over that edge. The overlap carries real heights — a dropped skirt does not work here, see
## _make_cell_tile.
@export_range(0, 32, 1) var collision_overlap: int = 8

# The child nodes no longer have to be in the scene — the node creates them itself (see
# _ensure_children), so LiteTerrain can be added as a single node with no manual assembly of a
# CollisionShape3D and a MeshInstance3D. Existing ones are reused if the scene already has them.
var collision: CollisionShape3D = null
var mesh_instance: MeshInstance3D = null

# Guarantees a CollisionShape3D and a MeshInstance3D exist, creating them as INTERNAL children
# (INTERNAL_MODE_BACK): they stay out of the scene tree, are not saved into the .tscn and are
# managed by the node itself, so LiteTerrain remains one clean node. get_node still finds them
# by name, so calling this again does not produce duplicates.
func _ensure_children() -> void:
	collision = get_node_or_null("CollisionShape3D") as CollisionShape3D
	if collision == null:
		collision = CollisionShape3D.new()
		collision.name = "CollisionShape3D"
		add_child(collision, false, Node.INTERNAL_MODE_BACK)
	mesh_instance = get_node_or_null("MeshInstance3D") as MeshInstance3D
	if mesh_instance == null:
		mesh_instance = MeshInstance3D.new()
		mesh_instance.name = "MeshInstance3D"
		add_child(mesh_instance, false, Node.INTERNAL_MODE_BACK)

# ── Runtime chunk state ───────────────────────────────────────────────────────
var _chunk_instances: Array[MeshInstance3D] = []
var _chunk_aabbs:    Array[AABB]           = []

# _chunk_meshes[i][lod] → ArrayMesh (or null for degenerate chunks)
# Pre-built for all 4 LOD levels at startup; no runtime rebuild needed.
var _chunk_meshes:   Array = []

# Current LOD level that is actually displayed for each chunk
var _chunk_lod:      Array[int] = []
var _chunk_flat_err: PackedFloat32Array = PackedFloat32Array()   # how far each chunk departs from flat

# Per-chunk "stitch signature": encodes the chunk's LOD step plus the snap step
# on each of its 4 borders (see _stitch_signature). the quadtree LOD pass (_qt_apply) rebuilds a chunk
# whenever its current required signature differs from the one last applied, which
# makes seam stitching self-healing regardless of event order (LOD change, neighbour
# LOD change, macro toggle, streamed-in chunk). 0 = no mesh applied yet.
var _chunk_stitch_sig: Array[int] = []

var _chunks_x:      int = 0
var _lod_timer:     float = 0.0
## Throttle for the quadtree descend (culling + LOD selection). See _process for why it does
## not have to run every frame.
const QT_MAX_HZ:    float = 30.0
const QT_STILL_EPS2: float = 0.04     # 0.2 m, squared: below this the camera counts as still
const QT_STILL_COS:  float = 0.9995   # ~1.8 degrees of turn
var _qt_timer:      float = 0.0
var _qt_last_pos:   Vector3 = Vector3(1e9, 1e9, 1e9)
var _qt_last_fwd:   Vector3 = Vector3.FORWARD

# ── Streaming collision runtime state ─────────────────────────────────────────
var _col_active: bool       = false
var _col_bodies: Array      = []   # [{body:Node3D}]  every moving body we give ground to
## Когда каждая плитка коллизии последний раз была нужна (ключ клетки → секунды). По ней
## работает отсрочка удаления: пересоздавать height field каждый кадр дороже, чем подержать.
var _col_seen: Dictionary   = {}
const COL_TILE_GRACE: float = 3.0
var _col_cells:  Dictionary = {}   # cell_key -> CollisionShape3D (one tile per active cell)

# ── Occlusion culling runtime state ──────────────────────────────────────────
const OCCLUSION_UPDATE_INTERVAL: float = 0.20   # seconds between full occlusion passes
var _occlusion_timer: float = 0.0
var _occluded_chunks: Dictionary = {}           # ci → true  (passed frustum, failed occlusion)
var _occluded_macros: Dictionary = {}
var _occluded_nodes:  Dictionary = {}           # node → true (far coarse quadtree mesh, occluded)

# ── Streaming runtime state ───────────────────────────────────────────────────
# Chunks not built at startup are queued here and built in background (on demand).
var _stream_queue:    Array[int] = []   # chunk indices not yet meshed, sorted by dist
var _stream_batch:    Array[int] = []   # indices being processed in the current batch
var _stream_results:  Array      = []   # [ci] = [lod_meshes, aabb] | null (worker output)
var _stream_group_id: int        = -1
var _is_streaming:    bool       = false

# ── Macro-chunk runtime state ─────────────────────────────────────────────────
# _macro_instances[mi]  → one MeshInstance3D per MACRO_SIZE×MACRO_SIZE group
# _macro_aabbs[mi]      → merged AABB of all sub-chunks (for frustum culling)
# _macro_to_chunks[mi]  → Array[int] of individual chunk indices in the group
# _chunk_macro_idx[ci]  → which macro group this individual chunk belongs to
# _macro_active[mi]     → true while the macro instance is actively rendering
var _macro_instances:  Array[MeshInstance3D] = []
var _macro_aabbs:      Array[AABB]           = []
var _macro_to_chunks:  Array                 = []
var _chunk_macro_idx:  Array[int]            = []
var _macro_active:     Array[bool]           = []

# ── Quadtree (runtime frustum + LOD selection) ────────────────────────────────
# Spatial hierarchy over the MACRO grid: each leaf = one macro group (4×4 chunks);
# internal nodes merge their children's AABBs up to a single root. Selection descends
# from the root every frame — any subtree fully outside the frustum, or entirely beyond
# max_render_distance, is pruned WITHOUT being visited. So per-frame cull/LOD cost scales
# with the visible area, not the map size (the far 3/4 of a huge map is never iterated),
# and because the selection is recomputed statelessly from the root it is instantly
# correct after a camera teleport (no temporal-coherence frontier to repair).
#   far leaf  → rendered as its merged macro mesh (1 draw call)
#   near leaf → expanded into its individual chunks at per-chunk LOD 0/1
var _qt_aabb:  Array[AABB] = []   # node → local-space merged AABB
var _qt_child: Array       = []   # node → Array[int] child node ids ([] = leaf)
var _qt_macro: Array[int]  = []   # leaf → macro index; internal node → -1
var _qt_built: bool        = false
# Each INTERNAL node also carries one coarse merged mesh (its whole footprint sampled at a
# step that grows with the node's size — ~constant triangle budget per node).
# The descend renders the COARSEST node whose on-screen error is acceptable, so distant
# terrain collapses into a few big low-poly meshes: you can see to the horizon (mountains)
# for a handful of draw calls instead of thousands of macros. Leaves keep using the macro
# meshes / individual chunks (fine near detail, grass, collision-matching).
var _qt_rect:  Array        = []   # node → Vector4i(x0, z0, x1, z1) cell rect
var _qt_step:  Array[int]   = []   # node → sample step of its coarse mesh
var _qt_size:  Array[float] = []   # node → max world XZ extent (LOD-selection metric)
var _qt_inst:  Array        = []   # node → MeshInstance3D (internal nodes only; null for leaves)
var _qt_node_results: Array = []   # threaded coarse-mesh build scratch
const QT_QUALITY: float = 1.1      # render a node coarsely once dist ≥ size * this (lower = coarser/faster)
# Currently-rendered selection, kept for cheap show/hide diffing each frame.
var _qt_cur_macros: Dictionary = {}   # mi → true (macro mesh currently visible)
var _qt_cur_chunks: Dictionary = {}   # ci → lod  (chunk currently rendered individually)
var _qt_cur_nodes:  Dictionary = {}   # node → true (coarse internal mesh currently visible)
# Per-frame scratch sets (members so they aren't reallocated every frame).
var _qt_des_macros: Dictionary = {}
var _qt_des_chunks: Dictionary = {}
var _qt_des_nodes:  Dictionary = {}

# ── Chunk residency (memory cap for big maps) ─────────────────────────────────
# Individual chunk nodes/meshes are instantiated ONLY for macro groups near the camera.
# Far terrain is drawn by the always-resident macro meshes (built once, directly from the
# heightmap — no per-chunk dependency). This bounds resident memory to the play area
# instead of instantiating every chunk of the whole map at once. Chunks stream in on demand when the
# camera approaches a macro and are freed (evicted) when it leaves.
var _resident_set:  Dictionary = {}   # mi → true : this macro's chunks are instantiated
var _queued_chunks: Dictionary = {}   # ci → true : queued for (re)build (dedups enqueues)
var _macro_results: Array      = []   # [mi] → ArrayMesh : threaded macro-mesh build scratch
const QT_EVICT_MARGIN: float = 96.0   # free a macro's chunks only this far beyond the expand ring

# ── Editor chunk cache ────────────────────────────────────────────────────────
# The editor uses a single MeshInstance3D with one surface per chunk.
# Editor always renders LOD 0 (full resolution) for accurate sculpting.
var _ed_cache: Array = []
var _ed_cx:    int   = 0
var _ed_cz:    int   = 0
var _ed_lod:   Array[int] = []                 # per-chunk LOD level (editor)
# Editor camera (fed by plugin.gd) + camera-settle tracking for lag-free LOD rebuilds.
var _editor_cam:        Camera3D = null
var _editor_track_pos:  Vector3  = Vector3(INF, INF, INF)
var _editor_build_pos:  Vector3  = Vector3(INF, INF, INF)
var _editor_settle_t:   float    = 0.0

# ── LOD material cache ────────────────────────────────────────────────────────
# Two static material variants replace per-instance shader parameters.
# set_instance_shader_parameter() allocates a slot in the global_shader_variables
# buffer (GLES3 limit: 4096). With hundreds of chunks this overflows instantly.
# Swapping materials uses zero buffer slots and costs nothing at runtime.
var _mat_lod0:     Material = null  # lod_grass_enabled = 1.0  (LOD 0, close)
var _mat_lod_high: Material = null  # lod_grass_enabled = 0.0  (LOD 1+, distant)

signal terrain_ready                 # the near terrain is built (for a loading screen)
var terrain_is_ready: bool = false

# How many nodes to create per frame during the initial build. add_child both enters the tree
# and creates a render instance, so hundreds in one frame is a visible freeze; we do them in
# batches and yield a frame in between.
const NODE_BATCH := 64

# ── Heightmap (the data the whole system reads) ───────────────────────────────
# Filled by _load_heightmap() in _ready(): from the R32F image at runtime, or from
# the embedded HeightMapShape3D (editor, or as a pre-bake fallback at runtime).
var w:  int                = 0
var d:  int                = 0
var md: PackedFloat32Array = PackedFloat32Array()

# ─────────────────────────────────────────────────────────────────────────────
# Ready
# ─────────────────────────────────────────────────────────────────────────────

func _ready() -> void:
	_ensure_children()
	if Engine.is_editor_hint():
		if use_image_data and _load_heightmap_image() != null:
			# Image mode: the R32F terrain_height.res is the source of truth. The internal
			# MeshInstance3D is not saved into the scene, so if no preview mesh exists yet we
			# build one from the heightmap. If a mesh is already assigned (older scenes with an
			# external terrain_mesh.res) we leave it alone, to avoid embedding a huge mesh.
			_load_heightmap()
			if mesh_instance.mesh == null:
				_rebuild_editor_full()
			return
		if collision.shape is HeightMapShape3D:
			w  = collision.shape.map_width      # legacy: data from the embedded shape
			d  = collision.shape.map_depth
			md = collision.shape.map_data
			_recompute_height_bound()
		update()
		return
	mesh_instance.visible = false
	await get_tree().process_frame
	_cam = _active_camera()
	if use_image_data or enable_streaming_collision:
		await _prewarm_heightmap()          # pull the heightmap in the BACKGROUND; load() would stall the frame
		_load_heightmap()
		# Yield a frame BETWEEN the heavy phases. Unpacking the heightmap (to_float32_array copies
		# tens of megabytes) and building the collision (a full scene walk plus Jolt heightfield
		# tiles) are each uninterruptible, but between them a loading screen gets to draw.
		await get_tree().process_frame
		_setup_streaming_collision()        # small sliding collision window
		await get_tree().process_frame
	else:
		# Legacy: the embedded HeightMapShape3D is both data and collision.
		if collision.shape is HeightMapShape3D:
			w  = collision.shape.map_width
			d  = collision.shape.map_depth
			md = collision.shape.map_data
		else:
			push_error("LiteTerrain: legacy mode needs a HeightMapShape3D on CollisionShape3D. Turn on use_image_data (default) or generate/bake terrain from the LiteTerrain dock.")
			terrain_is_ready = true         # otherwise a loading screen would wait forever
			terrain_ready.emit()
			return
	_chunks_x = ceili(float(w - 1) / chunk_size)
	await _build_mask_lattice()      # before the threads: from here they only read it
	await _build_chunks_from_map_data()
	if _cam:
		await get_tree().process_frame   # a frame BEFORE the full scan, which is heavy and unbroken
		_full_scan()
	await get_tree().process_frame       # and one after, so a screen fade starts without a hitch
	terrain_is_ready = true          # the near terrain is up; a loading screen can leave
	terrain_ready.emit()

# ─────────────────────────────────────────────────────────────────────────────
# Heightmap loading + streaming collision
# ─────────────────────────────────────────────────────────────────────────────

# Loads the master heightmap into w / d / md. Prefers the R32F image (scales to huge
# maps); falls back to the embedded HeightMapShape3D so the game still runs pre-bake.
func _load_heightmap() -> void:
	# СНАЧАЛА СВОЙ ФАЙЛ. Если рельеф уже правили (площадки под постройки) и правки запекли,
	# истина лежит в user:// — пакетный res:// после этого только «заводская» карта, к которой
	# возвращает новая игра.
	if _load_user_heights():
		return
	if _load_stream_heights():
		return
	var img := _load_heightmap_image()
	if img != null:
		w  = img.get_width()
		d  = img.get_height()
		if img.get_format() != Image.FORMAT_RF:
			img.convert(Image.FORMAT_RF)
		md = img.get_data().to_float32_array()
		_recompute_height_bound()
		return
	# Fallback: read the heights out of the still-attached HeightMapShape3D.
	push_warning("map.gd: heightmap image not found at '%s' — using embedded CollisionShape3D data. Run 'Bake heightmap → image' in the LiteTerrain dock for big-map streaming." % heightmap_path)
	if collision.shape is HeightMapShape3D:
		w  = collision.shape.map_width
		d  = collision.shape.map_depth
		md = collision.shape.map_data
		_recompute_height_bound()
	if md.is_empty():
		# With no heights there is neither terrain nor collision — bodies fall through nothing.
		push_error("LiteTerrain: no heightmap loaded (%s is missing and there is no embedded "
				% heightmap_path
				+ "HeightMapShape3D either). There will be no collision and no terrain. "
				+ "Re-bake the terrain from the LiteTerrain dock (\"Bake -> files\") or put "
				+ "the file back.")

# ── ПОТОКОВЫЙ ФАЙЛ ВЫСОТ (res://…​.bin рядом с .res) ──────────────────────────
# Сырые строки float32 с заголовком и таблицей «мин/макс на чанк». Зачем он, если .res уже
# есть: ресурс-картинку можно загрузить только ЦЕЛИКОМ, и это упирает размер карты в память —
# а из сырого файла любой прямоугольник берётся seek'ом и чтением. Сейчас мы всё равно читаем
# его целиком, и даже так он выигрывает: одно выделение вместо «загрузить ресурс → сконвертить
# формат → to_float32_array».
#
# Таблица мин/макс идёт ПЕРЕД высотами, потому что читают её всю и сразу: тому, кто грузит
# регионы, всё равно надо знать габариты каждого чанка ДО того, как рядом с ним прочитана хоть
# одна высота (иначе нечем строить дерево отсечения). Два float на чанк — это ~120 КБ на карту
# 1984², рядом с 16 МБ высот это ничто.
const STREAM_MAGIC := 0x4C545331          # "LTS1"
## Габариты чанков из файла: минимум и максимум высоты. Пусто, пока файла нет.
var _chunk_min: PackedFloat32Array = PackedFloat32Array()
var _chunk_max: PackedFloat32Array = PackedFloat32Array()

func _stream_path() -> String:
	return heightmap_path.get_basename() + ".bin" if not heightmap_path.is_empty() else ""

## Открыть файл и прочитать заголовок. Возвращает [file, w, d, chunk, data_offset] или пусто.
func _stream_open() -> Array:
	var path := _stream_path()
	if path.is_empty() or not FileAccess.file_exists(path):
		return []
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null or f.get_32() != STREAM_MAGIC:
		return []
	var sw := f.get_32()
	var sd := f.get_32()
	var cs := f.get_32()
	if sw <= 0 or sd <= 0 or cs <= 0:
		return []
	var cx: int = ceili(float(sw - 1) / float(cs))
	var cz: int = ceili(float(sd - 1) / float(cs))
	var table_bytes: int = cx * cz * 4 * 2
	return [f, sw, sd, cs, 16 + table_bytes, cx, cz]

func _load_stream_heights() -> bool:
	var o := _stream_open()
	if o.is_empty():
		return false
	var f: FileAccess = o[0]
	var sw: int = o[1]
	var sd: int = o[2]
	var cells: int = int(o[5]) * int(o[6])
	_chunk_min = f.get_buffer(cells * 4).to_float32_array()
	_chunk_max = f.get_buffer(cells * 4).to_float32_array()
	var bytes := f.get_buffer(sw * sd * 4)
	f.close()
	if bytes.size() != sw * sd * 4:
		push_warning("LiteTerrain: %s обрезан — беру запечённую картинку" % _stream_path())
		return false
	w = sw
	d = sd
	md = bytes.to_float32_array()
	_recompute_height_bound()
	return true

## ПРОЧИТАТЬ ПРЯМОУГОЛЬНИК ВЫСОТ, не поднимая карту целиком. Ради этого файл и заведён:
## отсюда вырастет подгрузка регионов вокруг игрока. Читаем построчно — строка в файле лежит
## непрерывно, значит на строку приходится один seek и одно чтение.
##
## Возвращает массив (x1-x0+1) × (z1-z0+1) в порядке строк, или пустой, если файла нет.
func read_height_rect(x0: int, z0: int, x1: int, z1: int) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	var o := _stream_open()
	if o.is_empty():
		return out
	var f: FileAccess = o[0]
	var sw: int = o[1]
	var sd: int = o[2]
	var base: int = o[4]
	var cx0: int = clampi(x0, 0, sw - 1)
	var cx1: int = clampi(x1, 0, sw - 1)
	var cz0: int = clampi(z0, 0, sd - 1)
	var cz1: int = clampi(z1, 0, sd - 1)
	var rw: int = cx1 - cx0 + 1
	if rw <= 0 or cz1 < cz0:
		f.close()
		return out
	for z in range(cz0, cz1 + 1):
		f.seek(base + (z * sw + cx0) * 4)
		out.append_array(f.get_buffer(rw * 4).to_float32_array())
	f.close()
	return out

## Габариты чанка из таблицы файла: (min, max) высоты. Нужны тому, кто строит дерево
## отсечения, не загрузив ни одной высоты рядом.
func chunk_height_bounds(ci: int) -> Vector2:
	if ci < 0 or ci >= _chunk_min.size():
		return Vector2(0.0, 0.0)
	return Vector2(_chunk_min[ci], _chunk_max[ci])

# ── ЗАПЕЧЁННЫЙ РЕЛЬЕФ (правки игрока) ────────────────────────────────────────
# Правки высот живут двумя способами сразу, и это не дублирование, а разделение труда:
#
#   • СПИСОК ПРАВОК (ground_edits) — на время сессии. Записать четыре числа стоит ноль, и
#     они переживут даже вылет игры: список уезжает в сейв мира при первом же автосейве.
#   • ЗАПЕЧЁННЫЙ ФАЙЛ — при загрузке. Правки применяются к высотам и сбрасываются в
#     user:// одним куском, после чего список пуст: рельеф САМ стал таким.
#
# Почему запекаем именно на загрузке: дамп карты высот — это её полный размер (у карты
# 1984×1984 это 15 МБ), и на ходу такая запись видна рывком. А загрузка и так долгая, там
# лишние доли секунды не заметны — это ровно то место, где такой работе и место.
#
# Формат простейший: заголовок с размерами и сырые float. Ни сжатия, ни картинки: PNG хранит
# высоту восемью битами (256 ступеней на всю карту — рельеф стал бы ступенчатым), а EXR надо
# кодировать. Сырые float читаются мгновенно и без потерь.
const USER_HEIGHTS := "user://terrain_height.bin"
const USER_HEIGHTS_MAGIC := 0x4C544831        # "LTH1"

## Прочитать запечённый рельеф. false — файла нет или он от другой карты (тогда берём
## пакетный, а этот игнорируем: подсунуть высоты не того размера значит развалить всё).
func _load_user_heights() -> bool:
	if not FileAccess.file_exists(USER_HEIGHTS):
		return false
	var f := FileAccess.open(USER_HEIGHTS, FileAccess.READ)
	if f == null:
		return false
	if f.get_32() != USER_HEIGHTS_MAGIC:
		return false
	var uw := f.get_32()
	var ud := f.get_32()
	var useq := f.get_32()
	if uw <= 0 or ud <= 0:
		return false
	var bytes := f.get_buffer(uw * ud * 4)
	if bytes.size() != uw * ud * 4:
		push_warning("LiteTerrain: %s обрезан — беру заводскую карту" % USER_HEIGHTS)
		return false
	w = uw
	d = ud
	md = bytes.to_float32_array()
	_baked_seq = useq
	_edit_seq = useq             # новые правки продолжают нумерацию, а не начинают её заново
	_recompute_height_bound()
	return true

## Запечь текущие высоты в user://. Зовётся ПОСЛЕ применения правок при загрузке.
func bake_heights() -> bool:
	if md.is_empty() or w <= 0 or d <= 0:
		return false
	var f := FileAccess.open(USER_HEIGHTS, FileAccess.WRITE)
	if f == null:
		push_warning("LiteTerrain: не удалось записать %s — правки останутся списком" % USER_HEIGHTS)
		return false
	f.store_32(USER_HEIGHTS_MAGIC)
	f.store_32(w)
	f.store_32(d)
	# НОМЕР ПОСЛЕДНЕЙ ЗАПЕЧЁННОЙ ПРАВКИ. Без него правка, оставшаяся в сейве мира (игрок
	# закрыл игру раньше первого автосейва), применилась бы ВТОРОЙ РАЗ поверх уже ровной
	# земли — и край площадки с каждым разом становился бы круче. С номером повтор просто
	# пропускается: рельеф уже такой.
	f.store_32(_edit_seq)
	f.store_buffer(md.to_byte_array())
	f.close()
	_baked_seq = _edit_seq
	_flat_edits.clear()          # они теперь ВНУТРИ файла, повторять их больше не нужно
	return true

## Забыть все правки рельефа: удалить запечённый файл и список. Новая игра начинается на
## заводской карте, а не на чужих ямах.
func reset_heights() -> void:
	_flat_edits.clear()
	_baked_seq = 0
	_edit_seq = 0
	if FileAccess.file_exists(USER_HEIGHTS):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(USER_HEIGHTS))

# Pulls the heightmap file (tens of megabytes of R32F) on a BACKGROUND thread, yielding frames.
# The ordinary load() in _load_heightmap_image() then takes it from the cache instantly. The
# path is a plain string, so the file is NOT a scene dependency and threaded scene loading
# does not pick it up on its own.
func _prewarm_heightmap() -> void:
	if heightmap_path.is_empty() or not ResourceLoader.exists(heightmap_path):
		return
	if ResourceLoader.load_threaded_request(heightmap_path) != OK:
		return                               # no luck; _load_heightmap() falls back to a plain load()
	while true:
		var st := ResourceLoader.load_threaded_get_status(heightmap_path)
		if st != ResourceLoader.THREAD_LOAD_IN_PROGRESS:
			break
		await get_tree().process_frame
	ResourceLoader.load_threaded_get(heightmap_path)   # collect it; this puts it in the resource cache

func _load_heightmap_image() -> Image:
	if heightmap_path.is_empty() or not ResourceLoader.exists(heightmap_path):
		return null
	var res := load(heightmap_path)
	if res is Image:
		return res as Image
	if res is Texture2D:
		return (res as Texture2D).get_image()
	return null

# ── Streaming collision (grid of tiled HeightMapShape3D cells) ─────────────────
# Each tracked body marks the grid cells within its radius as "needed"; one small
# HeightMapShape3D is created per needed cell. Cells TILE (no overlap → no doubled
# collision and no catchy edges inside the driving area), and bodies that share a cell
# share its window. Bodies are discovered via node_added/node_removed signals.
func _setup_streaming_collision() -> void:
	if md.is_empty() or w <= 0 or d <= 0:
		return
	collision.disabled = true            # the scene's CollisionShape3D is unused at runtime
	_clear_collision_cells()
	_col_bodies.clear()
	_col_active = true
	var scene_root := get_tree().current_scene
	if scene_root != null:
		# Track every moving body (RigidBody3D/VehicleBody3D/CharacterBody3D); _register_body filters.
		for n in scene_root.find_children("*", "PhysicsBody3D", true, false):
			_register_body(n)
	if not get_tree().node_added.is_connected(_on_node_added):
		get_tree().node_added.connect(_on_node_added)
		get_tree().node_removed.connect(_on_node_removed)
	_update_collision_cells()

# A moving body worth giving ground collision to (excludes StaticBody3D, Area3D, etc.).
# VehicleBody3D is a RigidBody3D subclass, so it is covered by the RigidBody3D check.
func _is_trackable_body(n: Node) -> bool:
	return n is RigidBody3D or n is CharacterBody3D

# Highest trackable body in n's ancestor chain, or n itself if none above it. Used to skip
# sub-bodies (e.g. a part welded onto a vehicle) — the top body's window already covers them.
func _top_body(n: Node) -> Node:
	var top: Node = n
	var p := n.get_parent()
	while p != null:
		if _is_trackable_body(p):
			top = p
		p = p.get_parent()
	return top

func _register_body(n: Node) -> void:
	if not _col_active or not is_instance_valid(n):
		return
	if not _is_trackable_body(n):
		return
	if is_ancestor_of(n):
		return                            # our own collision shapes etc.
	if _top_body(n) != n:
		return                            # a sub-body — the top body's window already covers it
	for b in _col_bodies:
		if b["body"] == n:
			return                        # already tracked
	_col_bodies.append({"body": n})

func _unregister_body(n: Node) -> void:
	var kept := []
	for b in _col_bodies:
		if b["body"] != n:
			kept.append(b)
	_col_bodies = kept

func _on_node_added(n: Node) -> void:
	if _is_trackable_body(n):
		call_deferred("_register_body", n)   # defer so parent/position are settled

func _on_node_removed(n: Node) -> void:
	if _is_trackable_body(n):
		_unregister_body(n)

func _clear_collision_cells() -> void:
	for key in _col_cells:
		if is_instance_valid(_col_cells[key]):
			_col_cells[key].queue_free()
	_col_cells.clear()
	_col_seen.clear()

# Recompute the set of grid cells needed (union of all bodies' footprints) and create /
# free cell tiles to match. Diff-only, so static bodies cause zero churn.
var _warned_no_heights: bool = false

func _update_collision_cells() -> void:
	if md.is_empty() and _col_active and not _warned_no_heights:
		_warned_no_heights = true      # once, not every frame
		push_error("LiteTerrain: no collision is being built — the heightmap is empty (w=%d d=%d). "
				% [w, d] + "See the heightmap loading message above.")
	if not _col_active or md.is_empty() or collision_cell <= 0:
		return
	var cells_x := (w + collision_cell - 1) / collision_cell
	var cells_z := (d + collision_cell - 1) / collision_cell
	var desired := {}
	var dead := false
	for b in _col_bodies:
		# БЕЗ ТИПА: присваивание освобождённого узла типизированной переменной падает САМО
		# («Trying to assign invalid previously freed instance») — до всякой проверки ниже.
		# Ссылка на удалённый узел не равна null, поэтому и проверка нужна именно такая.
		var raw = b["body"]
		if raw == null or not is_instance_valid(raw):
			dead = true
			continue
		var body: Node3D = raw
		# GAME HOOK (TerraTest): a body flagged "asleep" gets no ground. Dormant enemies are
		# frozen and their whole branch is process-disabled (enemy_spawner._sleep), yet they
		# were still holding a full collision window open on the far side of the map — the
		# exact cost dormancy exists to avoid. They cannot fall while frozen, and this loop
		# runs every frame, so the window is back the moment they wake.
		# Deliberately keyed on our own meta rather than on `freeze`: plenty of frozen bodies
		# in this project (an anchored base, carried items) still want ground under them.
		if body.get_meta("asleep", false):
			continue
		# GAME HOOK (TerraTest): a body ASLEEP UNDER ITS OWN PHYSICS gets no window either.
		# Every RigidBody3D asks for a full collision_radius window, and this game leaves loose
		# blocks lying all over the ground — dozens of them, each demanding its own patch of
		# heightfield. The desired set explodes, tiles are built and freed every frame, and the
		# ground under the machine the player is actually driving stops being refreshed.
		#
		# A body resting on the ground does not move, so it does not need fresh ground; when
		# something disturbs it, it wakes and gets its window back on the very next frame,
		# because this loop runs every frame.
		#
		# FROZEN bodies are deliberately NOT skipped: freeze is not rest. An anchored base is
		# frozen, and skipping it would leave the player's own factory floor without collision.
		if body is RigidBody3D and (body as RigidBody3D).sleeping and not (body as RigidBody3D).freeze:
			continue
		var r: int = collision_radius
		var local := global_transform.affine_inverse() * body.global_position
		var bx := int(round(local.x + float(w) * 0.5 - 0.5))
		var bz := int(round(local.z + float(d) * 0.5 - 0.5))
		var cx0 := clampi((bx - r) / collision_cell, 0, cells_x - 1)
		var cx1 := clampi((bx + r) / collision_cell, 0, cells_x - 1)
		var cz0 := clampi((bz - r) / collision_cell, 0, cells_z - 1)
		var cz1 := clampi((bz + r) / collision_cell, 0, cells_z - 1)
		for cz in range(cz0, cz1 + 1):
			for cx in range(cx0, cx1 + 1):
				desired[cz * cells_x + cx] = true
	# Плитки ЖИВУТ ЕЩЁ НЕМНОГО после того, как стали не нужны (COL_TILE_GRACE). Причина —
	# цена создания: каждая плитка это HeightMapShape3D, и физический движок печёт по ней
	# height field. Без задержки машина, едущая вдоль границы клеток, заставляла удалять и
	# тут же создавать одни и те же плитки каждый кадр, а десяток разлетевшихся блоков —
	# сразу пачку. Держать готовую плитку почти бесплатно: она статична и в широкой фазе
	# ничего не стоит.
	var now_s: float = float(Time.get_ticks_msec()) * 0.001
	for key in desired:
		_col_seen[key] = now_s
		if not _col_cells.has(key):
			_make_cell_tile(key, cells_x)
	for key in _col_cells.keys():
		if desired.has(key):
			continue
		if now_s - float(_col_seen.get(key, 0.0)) < COL_TILE_GRACE:
			continue
		if is_instance_valid(_col_cells[key]):
			_col_cells[key].queue_free()
		_col_cells.erase(key)
		_col_seen.erase(key)
	if dead:
		_prune_dead_bodies()

## GAME HOOK (TerraTest): счётчики для панели профиля — сколько сейчас ЖИВЫХ плиток коллизии
## и сколько тел их просит. Одно число объясняет просадку на развале машины: каждое
## незаснувшее тело держит свой кусок heightfield, и плитки нарезаются заново каждый кадр.
func collision_stats() -> Vector2i:
	return Vector2i(_col_cells.size(), _col_bodies.size())

## The state of the streaming collision at a point. Meant for a fall-through safety net to
## call when it catches a body below the terrain: one log line answers whether there was any
## collision there at all, instead of guessing from the code.
func collision_debug_at(world_pos: Vector3) -> String:
	if md.is_empty():
		return "the heightmap is EMPTY (w=%d d=%d) — there is no collision of any kind" % [w, d]
	if not _col_active:
		return "streaming is OFF, the embedded collision is in use (disabled=%s)" % str(collision.disabled)
	var cells_x: int = (w + collision_cell - 1) / collision_cell
	var cells_z: int = (d + collision_cell - 1) / collision_cell
	var local: Vector3 = global_transform.affine_inverse() * world_pos
	var bx: int = int(round(local.x + float(w) * 0.5 - 0.5))
	var bz: int = int(round(local.z + float(d) * 0.5 - 0.5))
	var cx: int = clampi(bx / collision_cell, 0, cells_x - 1)
	var cz: int = clampi(bz / collision_cell, 0, cells_z - 1)
	var key: int = cz * cells_x + cx
	return "cell (%d,%d) key=%d — tile %s | tiles %d | bodies tracked %d | inside the map %s" % [
			cx, cz, key,
			"present" if _col_cells.has(key) else "MISSING",
			_col_cells.size(), _col_bodies.size(),
			"yes" if (bx >= 0 and bx < w and bz >= 0 and bz < d) else "NO"]

func _prune_dead_bodies() -> void:
	var kept := []
	for b in _col_bodies:
		if b["body"] != null and is_instance_valid(b["body"]):
			kept.append(b)
	_col_bodies = kept

func _make_cell_tile(key: int, cells_x: int) -> void:
	var cx := key % cells_x
	var cz := key / cells_x
	# A tile OWNS samples [ox, ox+collision_cell] inclusive, so it shares exactly one boundary
	# row with each neighbour — no gap and no hole.
	var ox := cx * collision_cell
	var oz := cz * collision_cell
	# The tile's shape is grown by collision_overlap on every side to cover the neighbour's live
	# edge, and the overlap carries REAL heights. A skirt (a ring dropped downwards) cannot work
	# here: while streaming, the neighbour is sometimes not loaded yet, and the ring becomes the
	# only surface there — that is, a pit.
	var sx0 := maxi(ox - collision_overlap, 0)
	var sz0 := maxi(oz - collision_overlap, 0)
	var sx1 := mini(ox + collision_cell + collision_overlap, w - 1)
	var sz1 := mini(oz + collision_cell + collision_overlap, d - 1)
	var W := sx1 - sx0 + 1
	var H := sz1 - sz0 + 1
	if W < 2 or H < 2:
		return
	var data := PackedFloat32Array()
	data.resize(W * H)
	for j in H:
		var srow := (sz0 + j) * w + sx0
		var drow := j * W
		for i in W:
			data[drow + i] = md[srow + i]
	var shape := HeightMapShape3D.new()
	shape.map_width  = W
	shape.map_depth  = H
	shape.map_data   = data
	var cs := CollisionShape3D.new()
	cs.shape = shape
	# position so the shape's cell (i,j) lands on the visual master cell (sx0+i, sz0+j).
	cs.position = Vector3(sx0 + float(W - w) * 0.5, 0.0, sz0 + float(H - d) * 0.5)
	add_child(cs)
	_col_cells[key] = cs

# ─────────────────────────────────────────────────────────────────────────────
# Public API  (called by plugin.gd)
# ─────────────────────────────────────────────────────────────────────────────

# Full rebuild — call after noise generation or on first open.
func update() -> void:
	if not is_node_ready() or collision == null or mesh_instance == null:
		return
	# Editor only: the plugin edits the HeightMapShape3D via undo/redo, so re-read it.
	# At runtime md comes from the R32F image and collision.shape is the small streaming
	# window — never overwrite md from it here.
	if Engine.is_editor_hint() and not use_image_data and collision.shape is HeightMapShape3D:
		w  = collision.shape.map_width
		d  = collision.shape.map_depth
		md = collision.shape.map_data
	if md.size() == 0:
		return
	if Engine.is_editor_hint():
		_rebuild_editor_full()

# Sets the whole heightmap and rebuilds. Used by the plugin's undo/redo for terrain
# generation: routing both the do and the undo through this NODE method keeps the
# action in a single EditorUndoRedoManager history, avoiding the "history mismatch"
# you get when one action touches both the scene node and the heightmap resource.
func apply_heightmap(data: PackedFloat32Array) -> void:
	if use_image_data:
		md = data                          # image mode: md is the source of truth
		_recompute_height_bound()
		if not Engine.is_editor_hint() and _col_active:
			_clear_collision_cells()       # heights changed → rebuild tiles from fresh md
			_update_collision_cells()
		update()
		return
	if collision != null and collision.shape is HeightMapShape3D:
		collision.shape.map_data = data
	update()

# ── Image-data heightmap API (editor sculpt without a physics shape) ───────────

func is_image_mode() -> bool:
	return use_image_data and not md.is_empty()

func get_heights() -> PackedFloat32Array:
	return md

func get_dims() -> Vector2i:
	return Vector2i(w, d)

# World-space terrain height under world_pos. Use it to place vehicles/objects ON the
# ground (e.g. body.global_position.y = map.terrain_height_at(body.global_position) + clearance)
# instead of spawning them in the air and letting them drop.
func terrain_height_at(world_pos: Vector3) -> float:
	if md.is_empty() or w <= 0:
		return 0.0
	var local := global_transform.affine_inverse() * world_pos
	var lh := _sample_height_local(local.x, local.z)
	return (global_transform * Vector3(local.x, lh, local.z)).y

# Replaces the whole heightmap AND its dimensions (used by 'generate' to make a bigger
# map). Editor-side: rebuilds the LOD preview at the new size. The plugin saves md to
# the R32F image afterwards; runtime then loads that image — no giant shape anywhere.
func set_heightmap(data: PackedFloat32Array, width: int, depth: int) -> void:
	if width <= 0 or depth <= 0 or data.size() != width * depth:
		push_error("map.gd: set_heightmap got %d values for %dx%d" % [data.size(), width, depth])
		return
	md = data
	w  = width
	d  = depth
	_chunks_x = ceili(float(w - 1) / chunk_size)
	_recompute_height_bound()
	if Engine.is_editor_hint():
		_rebuild_editor_full()

# Bilinear local-space height at local XZ. Clamps to the edge outside the map.
func _sample_height_local(lx: float, lz: float) -> float:
	if md.is_empty() or w <= 0:
		return 0.0
	var x0 := clampi(int(floor(lx + float(w) * 0.5 - 0.5)), 0, w - 1)
	var z0 := clampi(int(floor(lz + float(d) * 0.5 - 0.5)), 0, d - 1)
	var x1 := mini(x0 + 1, w - 1)
	var z1 := mini(z0 + 1, d - 1)
	var fx := clampf((lx + float(w) * 0.5 - 0.5) - float(x0), 0.0, 1.0)
	var fz := clampf((lz + float(d) * 0.5 - 0.5) - float(z0), 0.0, 1.0)
	var h0: float = lerp(md[z0 * w + x0], md[z0 * w + x1], fx)
	var h1: float = lerp(md[z1 * w + x0], md[z1 * w + x1], fx)
	return lerp(h0, h1, fz)

# Upper bound of the map's heights, in local units. Only the editor's raycast_heightmap needs
# it: there is definitely no terrain above it, so the empty air over the tallest peak can be
# skipped without sampling. It is kept at or above the real maximum — recomputed exactly on
# load, generation and undo, while the raise brush only ever pushes it up.
var _md_max := 0.0

func _recompute_height_bound() -> void:
	if not Engine.is_editor_hint():
		return
	var m := -INF
	for h in md:
		if h > m:
			m = h
	_md_max = m if md.size() > 0 else 0.0

# Ray-march the heightmap; returns the world hit position or null. Lets the editor
# sculpt with NO physics collision, so the giant HeightMapShape3D is never needed.
func raycast_heightmap(from_world: Vector3, dir_world: Vector3) -> Variant:
	if md.is_empty() or w <= 0:
		return null
	var inv := global_transform.affine_inverse()
	var o := inv * from_world
	var dir := (inv.basis * dir_world).normalized()
	var max_t := float(maxi(w, d)) * 2.0
	var t := 0.0
	# Skip the empty air: while the ray is heading down and still above the tallest peak
	# (_md_max) there is nothing to sample, so jump straight to the y = _md_max plane (minus one,
	# to start slightly above it and keep prev_gap > 0). Safe, since no terrain exists above.
	if dir.y < -1e-6 and o.y > _md_max:
		t = maxf(0.0, (o.y - _md_max) / -dir.y - 1.0)
	var p0 := o + dir * t
	var prev_gap := p0.y - _sample_height_local(p0.x, p0.z)
	while t < max_t:
		t += 1.0
		var p := o + dir * t
		var gap := p.y - _sample_height_local(p.x, p.z)
		if gap <= 0.0 and prev_gap > 0.0:
			var lo := t - 1.0
			var hi := t
			for _i in 10:
				var mid := (lo + hi) * 0.5
				var pm := o + dir * mid
				if pm.y - _sample_height_local(pm.x, pm.z) > 0.0:
					lo = mid
				else:
					hi = mid
			var ph := o + dir * hi
			return global_transform * Vector3(ph.x, _sample_height_local(ph.x, ph.z), ph.z)
		prev_gap = gap
	return null

# ── ПЛОЩАДКА ПОД ПОСТРОЙКУ ───────────────────────────────────────────────────
# Выровнять кусок рельефа В ИГРЕ: высоты, меш и коллизия. Нужно всему, что «встраивается» в
# мир, а не ставится на него, — базе из квеста, будущим вышкам, любой постройке, которой
# нужен ровный пол.
#
# Область ПРЯМОУГОЛЬНАЯ, а не круглая, и это не мелочь: постройки у нас вытянутые (линия
# конвейера — шесть клеток в одну сторону и две вбок), а круг под такую площадку пришлось бы
# брать по её диагонали и срывать втрое больше земли, чем нужно.
#
# Порядок работы важен: сперва высоты, потом меши задетых чанков, потом коллизия. Коллизия
# стриминговая — её тайлы нарезаются ИЗ md вокруг тел, поэтому старые надо снести, иначе
# машина продолжит ездить по прежнему рельефу, которого уже не видно.
#
# Правка живёт только в памяти: карта высот в сейв мира не попадает, и после перезапуска
# площадка вернётся к исходному рельефу. Тому, кто её звал, и решать, повторить ли правку
# при загрузке.
#
# half_extent — половина размера площадки в мировых единицах (X и Z), feather — насколько
# плавно она сходит на нет за своим краем.
func flatten_area(center_world: Vector3, half_extent: Vector2, height: float,
		feather: float = 4.0, record: bool = true) -> void:
	var dirty: Array = _flatten_heights(center_world, half_extent, height, feather)
	if dirty.is_empty():
		return
	# ЗАПОМИНАЕМ правку. Карта высот в сейв не пишется (мегабайты float на каждую запись),
	# зато сама правка — это четыре числа, и по ним рельеф повторяется при загрузке точно
	# таким же. record = false у повтора, иначе список рос бы с каждым входом в игру.
	if record:
		_edit_seq += 1
		_flat_edits.append({
			"c": [center_world.x, center_world.y, center_world.z],
			"h": [half_extent.x, half_extent.y],
			"y": height, "f": feather, "n": _edit_seq,
		})
		if _flat_edits.size() > FLAT_EDITS_MAX:
			_flat_edits.remove_at(0)
	update_chunks(dirty)
	_refresh_ground_collision()

## Сколько правок рельефа помним. Каждая — четыре числа, но список не должен расти вечно:
## квест может ровнять новую площадку каждый прогон.
const FLAT_EDITS_MAX := 64
var _flat_edits: Array = []
## Сквозной номер правки и номер последней ЗАПЕЧЁННОЙ. По ним повтор при загрузке отличает
## «эту правку земля уже помнит» от «эту надо применить».
var _edit_seq: int = 0
var _baked_seq: int = 0

## Правки рельефа для сейва мира и обратно. Список — простые словари, готовые к JSON.
func ground_edits() -> Array:
	return _flat_edits.duplicate(true)

## Повторить сохранённые правки. Зовётся ОДИН РАЗ при загрузке, ПОСЛЕ того как высоты карты
## прочитаны и ДО того, как в мир вернут машины: база обязана встать на уже ровную землю.
func apply_ground_edits(list: Array) -> void:
	if list.is_empty():
		return
	var seen: Dictionary = {}
	for e in list:
		if not (e is Dictionary) or not (e.get("c") is Array) or not (e.get("h") is Array):
			continue
		# Уже запечена в файл высот — земля её помнит, применять второй раз нельзя.
		if int(e.get("n", 0)) > 0 and int(e["n"]) <= _baked_seq:
			continue
		var c: Array = e["c"]
		var hh: Array = e["h"]
		if c.size() < 3 or hh.size() < 2:
			continue
		var dirty: Array = _flatten_heights(
				Vector3(float(c[0]), float(c[1]), float(c[2])),
				Vector2(float(hh[0]), float(hh[1])),
				float(e.get("y", 0.0)), float(e.get("f", 4.0)))
		for ci in dirty:
			seen[ci] = true
		_flat_edits.append(e)
		_edit_seq = maxi(_edit_seq, int(e.get("n", 0)))
	if seen.is_empty():
		return
	# Меши и коллизию трогаем ОДИН РАЗ на все правки: перестройка чанка и пересборка
	# коллизионных тайлов дороги, а площадок при загрузке может оказаться несколько.
	update_chunks(seen.keys())
	_refresh_ground_collision()

func _refresh_ground_collision() -> void:
	# Тайлы нарезаны из СТАРЫХ высот — сносим и даём построиться заново. Без этого машина
	# продолжит ездить по прежнему рельефу, которого уже не видно.
	if _col_active:
		_clear_collision_cells()
		_update_collision_cells()

## Сама правка высот: возвращает индексы задетых чанков и НИЧЕГО не перестраивает.
func _flatten_heights(center_world: Vector3, half_extent: Vector2, height: float,
		feather: float) -> Array:
	if md.is_empty() or w <= 0:
		return []
	var inv := global_transform.affine_inverse()
	var local: Vector3 = inv * center_world
	# Целевую высоту переводим в ЛОКАЛЬНУЮ: md хранит высоты в осях самой карты, а звать нас
	# будут мировыми координатами (там же, где стоит постройка).
	var target: float = (inv * Vector3(center_world.x, height, center_world.z)).y
	var cx: float = local.x + float(w) * 0.5 - 0.5      # та же формула, что в _compute_chunk_data
	var cz: float = local.z + float(d) * 0.5 - 0.5
	var ex: float = maxf(half_extent.x, 0.0)
	var ez: float = maxf(half_extent.y, 0.0)
	var fe: float = maxf(feather, 0.001)
	var x0 := clampi(int(floor(cx - ex - fe)), 0, w - 1)
	var x1 := clampi(int(ceil(cx + ex + fe)), 0, w - 1)
	var z0 := clampi(int(floor(cz - ez - fe)), 0, d - 1)
	var z1 := clampi(int(ceil(cz + ez + fe)), 0, d - 1)
	if x1 < x0 or z1 < z0:
		return []
	for z in range(z0, z1 + 1):
		var dz: float = maxf(absf(float(z) - cz) - ez, 0.0)   # 0 внутри площадки
		var row := z * w
		for x in range(x0, x1 + 1):
			var dx: float = maxf(absf(float(x) - cx) - ex, 0.0)
			# Вес по расстоянию ДО ПРЯМОУГОЛЬНИКА: внутри — единица (ровно), дальше плавно
			# к нулю, чтобы площадка не обрывалась стеной.
			var dist: float = sqrt(dx * dx + dz * dz)
			if dist >= fe:
				continue
			var k: float = 1.0 - dist / fe
			md[row + x] = lerp(md[row + x], target, clampf(k, 0.0, 1.0))
	_md_max = maxf(_md_max, target)          # граница высот нужна лучу по рельефу
	var cxl: int = ceili(float(w - 1) / chunk_size)
	var dirty: Array = []
	var seen: Dictionary = {}
	for czz in range(z0 / chunk_size, z1 / chunk_size + 1):
		for cxx in range(x0 / chunk_size, x1 / chunk_size + 1):
			var ci: int = czz * cxl + cxx
			if not seen.has(ci):
				seen[ci] = true
				dirty.append(ci)
	return dirty

# In-place brush on md around a world centre; returns the editor chunk indices touched.
# mode: 1 = raise, -1 = lower, 0 = flatten.
func apply_brush(center_world: Vector3, radius: float, strength: float, mode: int) -> PackedInt32Array:
	var dirty := PackedInt32Array()
	if md.is_empty() or w <= 0:
		return dirty
	var local := global_transform.affine_inverse() * center_world
	var cx := int(round(local.x + float(w) * 0.5 - 0.5))
	var cz := int(round(local.z + float(d) * 0.5 - 0.5))
	var r := int(ceil(radius))
	var x_min := clampi(cx - r, 0, w - 1)
	var x_max := clampi(cx + r, 0, w - 1)
	var z_min := clampi(cz - r, 0, d - 1)
	var z_max := clampi(cz + r, 0, d - 1)
	# Hot path: it runs on EVERY mouse move across (2r+1)² cells. Hence squared distances for the
	# rejection test (sqrt only for cells that pass), no Vector2 allocations, and the row base
	# and constant factors hoisted out of the loop.
	var r2 := radius * radius
	var inv_r := 1.0 / radius
	var avg := 0.0
	if mode == 0:
		var cnt := 0
		for z in range(z_min, z_max + 1):
			var dz := z - cz
			var dz2 := dz * dz
			var row := z * w
			for x in range(x_min, x_max + 1):
				var dx := x - cx
				if dx * dx + dz2 <= r2:
					avg += md[row + x]
					cnt += 1
		if cnt > 0:
			avg /= float(cnt)

	var add := float(mode) * strength      # raise/lower: the constant part, hoisted out
	for z in range(z_min, z_max + 1):
		var dz := z - cz
		var dz2 := dz * dz
		var row := z * w
		for x in range(x_min, x_max + 1):
			var dx := x - cx
			var d2 := dx * dx + dz2
			if d2 > r2:
				continue
			var falloff := 1.0 - sqrt(float(d2)) * inv_r
			var idx := row + x
			if mode == 0:
				# Flatten pulls towards the average. The weight is in [0,1] (falloff <= 1,
				# strength <= 1); the clamp guards against strength > 1, which would make the
				# lerp overshoot the average and wreck the map.
				md[idx] = lerp(md[idx], avg, clampf(falloff * strength, 0.0, 1.0))
			else:
				md[idx] += add * falloff
				if md[idx] > _md_max:      # keep the height bound current, for the raycast
					_md_max = md[idx]
	# Touched editor chunks (so the plugin can rebuild just those).
	if _ed_cx > 0:
		var seen := {}
		for cz2 in range(z_min / chunk_size, z_max / chunk_size + 1):
			for cx2 in range(x_min / chunk_size, x_max / chunk_size + 1):
				var ci := cz2 * _ed_cx + cx2
				if not seen.has(ci):
					seen[ci] = true
					dirty.append(ci)
	return dirty

# Partial update — only rebuild the listed chunk indices.
# In the editor this is the hot path on every sculpt stroke.
func update_chunks(chunk_indices: Array) -> void:
	if Engine.is_editor_hint() and not use_image_data and collision.shape is HeightMapShape3D:
		md = collision.shape.map_data  # legacy editor: re-read the sculpted shape data
	if Engine.is_editor_hint():
		if _ed_cache.is_empty():
			update()
			return
		for ci in chunk_indices:
			if ci < 0 or ci >= _ed_cache.size():
				continue
			var cx: int = ci % _ed_cx
			var cz: int = ci / _ed_cx
			if editor_lod:
				# Rebuild the dirty chunk plus its 4 neighbours so seam snapping stays valid.
				_ed_cache[ci] = _chunk_surface_arrays_lod(cx, cz)
				for off in [[0,-1],[0,1],[-1,0],[1,0]]:
					var nx: int = cx + off[0]
					var nz: int = cz + off[1]
					if nx >= 0 and nx < _ed_cx and nz >= 0 and nz < _ed_cz:
						_ed_cache[nz * _ed_cx + nx] = _chunk_surface_arrays_lod(nx, nz)
			else:
				_ed_cache[ci] = _chunk_surface_arrays(cx, cz)
		_apply_editor_cache()
		return

	# Runtime: rebuild all LOD levels for the specified chunks
	var mat: Material = _get_material()
	var cxl: int = ceili(float(w - 1) / chunk_size)
	var dirty_macros := {}   # macro group indices that need their mesh rebuilt

	for ci in chunk_indices:
		if ci < 0 or ci >= _chunk_instances.size():
			continue
		if not _chunk_instances[ci]:   # skip chunks not yet streamed in
			continue
		var cx_l: int = ci % cxl
		var cz_l: int = ci / cxl
		var x0: int = cx_l * chunk_size
		var z0: int = cz_l * chunk_size
		var x1: int = mini(x0 + chunk_size, w - 1)
		var z1: int = mini(z0 + chunk_size, d - 1)

		var lod_meshes: Array = []
		for lod in LOD_COUNT:
			var data: Array = _compute_chunk_data(x0, z0, x1, z1, _step_for(lod))
			if data.is_empty():
				lod_meshes.append(null)
				continue
			var am: ArrayMesh = ArrayMesh.new()
			am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, data[0])
			lod_meshes.append(am)
			if lod == 0:
				_chunk_aabbs[ci] = data[1]
		_chunk_meshes[ci] = lod_meshes

		# Track which macro groups need rebuilding due to this chunk change
		if _chunk_macro_idx.size() > ci:
			dirty_macros[_chunk_macro_idx[ci]] = true

		# Apply the currently-active LOD — only when NOT in macro mode
		var in_macro: bool = _chunk_macro_idx.size() > ci and _macro_active[_chunk_macro_idx[ci]]
		if not in_macro:
			var cur_lod: int = _chunk_lod[ci] if ci < _chunk_lod.size() else 0
			var display_mesh: ArrayMesh = _best_available_mesh(lod_meshes, cur_lod)
			if display_mesh:
				_chunk_instances[ci].mesh = display_mesh
				_chunk_instances[ci].set_surface_override_material(0, mat)

	# Rebuild merged meshes for every macro group that had a sub-chunk change
	for mi in dirty_macros:
		var macro_mesh := _build_macro_mesh(_macro_to_chunks[mi], 2)
		if macro_mesh:
			_macro_instances[mi].mesh = macro_mesh
			_macro_instances[mi].set_surface_override_material(0, _mat_lod_high if _mat_lod_high else mat)

func get_chunk_info() -> Dictionary:
	return {
		"chunk_size": chunk_size,
		"chunks_x":   ceili(float(w - 1) / chunk_size),
		"map_width":  w,
		"map_depth":  d,
	}

# ─────────────────────────────────────────────────────────────────────────────
# Editor chunk cache internals
# ─────────────────────────────────────────────────────────────────────────────

func _rebuild_editor_full() -> void:
	_editor_ensure_cache_sized()
	if editor_lod:
		_editor_rebuild_lod()
		return
	# The biome lattice FIRST: without it every vertex computes three noise masks of its own,
	# and that alone is the bulk of a full rebuild (see _build_mask_lattice_sync).
	if _mask_lat.is_empty() or _mask_w != int(ceil(float(w) / float(MASK_STEP))) + 1:
		_build_mask_lattice_sync()
	# Chunks are independent, so they go to the WorkerThreadPool — the same pattern the runtime
	# build uses. Threads only WRITE into their own slot of a pre-sized array and only READ the
	# heights and the lattice; nothing here touches the scene tree, which is the one thing a
	# worker may not do.
	var total: int = _ed_cx * _ed_cz
	if total > 0:
		var cxl: int = _ed_cx
		var far2: float = editor_view_distance * editor_view_distance
		var cam_local := global_transform.affine_inverse() * (_editor_cam.global_position \
				if _editor_cam else global_position)
		var task := func(i: int) -> void:
			if editor_view_distance > 0.0 and _ed_chunk_dist2(i % cxl, i / cxl, cam_local) > far2:
				_ed_cache[i] = []          # дальше горизонта редактора — не строим вовсе
				return
			_ed_cache[i] = _chunk_surface_arrays(i % cxl, i / cxl)
		var gid := WorkerThreadPool.add_group_task(task, total, -1, true, "LiteTerrain: editor chunks")
		WorkerThreadPool.wait_for_group_task_completion(gid)
	_apply_editor_cache()

func _editor_ensure_cache_sized() -> void:
	_ed_cx = ceili(float(w - 1) / chunk_size)
	_ed_cz = ceili(float(d - 1) / chunk_size)
	var total := _ed_cx * _ed_cz
	if _ed_cache.size() != total:
		_ed_cache.clear()
		_ed_cache.resize(total)
	if _ed_lod.size() != total:
		_ed_lod.resize(total)

# Plugin feeds the editor camera here; the actual LOD rebuild is driven by _process so
# it can wait for the camera to settle (no rebuild churn while you fly around).
func set_editor_camera(c: Camera3D) -> void:
	_editor_cam = c

# Editor-only (called from _process): rebuild the LOD mesh once the camera has been
# still for ~0.35 s and moved enough since the last build. Nothing rebuilds while the
# camera moves, so navigating stays smooth — the lighter LOD merge runs only on settle.
func _editor_lod_tick(delta: float) -> void:
	if _editor_cam == null or _ed_cx <= 0:
		return
	var pos := _editor_cam.global_position
	if pos.distance_squared_to(_editor_track_pos) > 4.0:      # 2², корень не нужен
		_editor_track_pos = pos
		_editor_settle_t  = 0.0
		return
	_editor_settle_t += delta
	if _editor_settle_t >= 0.35 \
			and _editor_track_pos.distance_squared_to(_editor_build_pos) \
					> float(chunk_size) * 0.5 * float(chunk_size) * 0.5:
		_editor_rebuild_lod()

# Picks each chunk's LOD by its XZ distance to the editor camera (same thresholds as
# the game), then rebuilds the whole merged editor mesh at those LODs with seam snapping.
func _editor_rebuild_lod() -> void:
	_editor_ensure_cache_sized()
	var cam_pos: Vector3 = _editor_cam.global_position if _editor_cam else global_position
	var cam_local := global_transform.affine_inverse() * cam_pos
	for cz in _ed_cz:
		for cx in _ed_cx:
			var ccx := (cx + 0.5) * chunk_size - w * 0.5
			var ccz := (cz + 0.5) * chunk_size - d * 0.5
			var dx := ccx - cam_local.x
			var dz := ccz - cam_local.z
			# Квадраты: обе строчки ниже — сравнения с порогами, корень им не нужен, а
			# перебор идёт по всем чанкам карты на каждой пересборке.
			var dist2 := dx * dx + dz * dz
			var lod := 0
			if dist2 >= lod_distance_1 * lod_distance_1:   lod = 2   # LOD3 (step 8) removed — unused at runtime
			elif dist2 >= lod_distance_0 * lod_distance_0: lod = 1
			_ed_lod[cz * _ed_cx + cx] = lod
	# Same treatment as the full rebuild: the lattice first (or every vertex re-derives its
	# biome from noise), then the chunks in parallel. The LOD pass above must finish first —
	# a chunk's mesh depends on its neighbours' LOD, so those numbers have to be settled.
	if _mask_lat.is_empty() or _mask_w != int(ceil(float(w) / float(MASK_STEP))) + 1:
		_build_mask_lattice_sync()
	var total: int = _ed_cx * _ed_cz
	if total > 0:
		var cxl: int = _ed_cx
		var far2: float = editor_view_distance * editor_view_distance
		var task := func(i: int) -> void:
			if editor_view_distance > 0.0 and _ed_chunk_dist2(i % cxl, i / cxl, cam_local) > far2:
				_ed_cache[i] = []          # дальше горизонта редактора — не строим вовсе
				return
			_ed_cache[i] = _chunk_surface_arrays_lod(i % cxl, i / cxl)
		var gid := WorkerThreadPool.add_group_task(task, total, -1, true, "LiteTerrain: editor chunks (LOD)")
		WorkerThreadPool.wait_for_group_task_completion(gid)
	_apply_editor_cache()
	_editor_build_pos = cam_pos

# Editor LOD step of the neighbour chunk, or 1 at the map edge (so no snap is forced).
func _ed_neighbour_step(cx: int, cz: int, dcx: int, dcz: int) -> int:
	var nx := cx + dcx
	var nz := cz + dcz
	if nx < 0 or nx >= _ed_cx or nz < 0 or nz >= _ed_cz:
		return 1
	return _step_for(_ed_lod[nz * _ed_cx + nx])

# Builds chunk (cx,cz)'s surface arrays at its editor LOD, snapping borders toward any
# coarser neighbour (same anti-crack stitching as runtime).
func _chunk_surface_arrays_lod(cx: int, cz: int) -> Array:
	var ci := cz * _ed_cx + cx
	var step := _step_for(_ed_lod[ci])
	var x0 := cx * chunk_size
	var z0 := cz * chunk_size
	var x1 := mini(x0 + chunk_size, w - 1)
	var z1 := mini(z0 + chunk_size, d - 1)
	var ns := _ed_neighbour_step(cx, cz,  0, -1)
	var ss := _ed_neighbour_step(cx, cz,  0,  1)
	var ws := _ed_neighbour_step(cx, cz, -1,  0)
	var es := _ed_neighbour_step(cx, cz,  1,  0)
	var res := _compute_chunk_data(x0, z0, x1, z1, step,
			ns if ns != step else 0,
			ss if ss != step else 0,
			ws if ws != step else 0,
			es if es != step else 0)
	return [] if res.is_empty() else res[0]

## Квадрат расстояния от камеры редактора до центра чанка, в локальных осях карты.
func _ed_chunk_dist2(cx: int, cz: int, cam_local: Vector3) -> float:
	var ccx: float = (float(cx) + 0.5) * chunk_size - w * 0.5
	var ccz: float = (float(cz) + 0.5) * chunk_size - d * 0.5
	var dx: float = ccx - cam_local.x
	var dz: float = ccz - cam_local.z
	return dx * dx + dz * dz

# Editor full-res chunk arrays (used when editor_lod is OFF).
func _chunk_surface_arrays(cx: int, cz: int) -> Array:
	var x0: int = cx * chunk_size
	var z0: int = cz * chunk_size
	var x1: int = mini(x0 + chunk_size, w - 1)
	var z1: int = mini(z0 + chunk_size, d - 1)
	var res: Array = _compute_chunk_data(x0, z0, x1, z1, 1)
	return [] if res.is_empty() else res[0]

func _apply_editor_cache() -> void:
	var mat: Material = _get_material()

	# Merge every chunk into ONE surface to avoid hitting MAX_MESH_SURFACES (256).
	# Same technique as _build_macro_mesh() — offset indices per chunk and combine.
	var all_verts   := PackedVector3Array()
	var all_idx     := PackedInt32Array()
	var all_normals := PackedVector3Array()
	var all_uvs     := PackedVector2Array()
	var all_colors  := PackedColorArray()
	var v_offset    := 0

	for arr in _ed_cache:
		if arr == null or arr.is_empty():
			continue
		var verts   := arr[Mesh.ARRAY_VERTEX] as PackedVector3Array
		var idxs    := arr[Mesh.ARRAY_INDEX]  as PackedInt32Array
		var normals := arr[Mesh.ARRAY_NORMAL] as PackedVector3Array
		var uvs     := arr[Mesh.ARRAY_TEX_UV] as PackedVector2Array
		var cols    := arr[Mesh.ARRAY_COLOR]  as PackedColorArray
		if verts == null or verts.is_empty():
			continue
		all_verts.append_array(verts)
		all_normals.append_array(normals)
		all_uvs.append_array(uvs)
		if cols != null and cols.size() == verts.size():
			all_colors.append_array(cols)
		else:
			for _i in verts.size():
				all_colors.append(Color(1.0, 0.0, 0.0, 0.0))   # fallback: no canyon (.g), no mountains (.a)
		for raw_idx in idxs:
			all_idx.append(raw_idx + v_offset)
		v_offset += verts.size()

	if all_verts.is_empty():
		return

	var merged := Array()
	merged.resize(Mesh.ARRAY_MAX)
	merged[Mesh.ARRAY_VERTEX] = all_verts
	merged[Mesh.ARRAY_INDEX]  = all_idx
	merged[Mesh.ARRAY_NORMAL] = all_normals
	merged[Mesh.ARRAY_TEX_UV] = all_uvs
	merged[Mesh.ARRAY_COLOR]  = all_colors

	var am := ArrayMesh.new()
	am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, merged)
	# Keep the rebuilt preview linked to its EXTERNAL .res path (if the scene already points
	# at one) so saving the scene writes a reference, not an embedded copy of this huge mesh.
	# The file itself is only rewritten by "Bake heightmap → image"; this just stops the
	# scene from swallowing the mesh. A built-in path looks like "res://scene.tscn::Id".
	if mesh_instance.mesh != null:
		var prev_path: String = mesh_instance.mesh.resource_path
		if not prev_path.is_empty() and not prev_path.contains("::"):
			am.take_over_path(prev_path)
	mesh_instance.mesh = am
	mesh_instance.set_surface_override_material(0, mat)

# ─────────────────────────────────────────────────────────────────────────────
# Runtime chunk building
# ─────────────────────────────────────────────────────────────────────────────

# Builds runtime MeshInstance3D chunks in three phases:
#
# Phase 0 — WorkerThreadPool (ALL chunks, fast):
#   Scans heightmap extremes to compute accurate AABBs for every chunk without
#   generating any mesh data. After this phase frustum/macro/occlusion are fully
#   operational for the whole map, even for chunks not yet meshed.
#
# Phase 1 — WorkerThreadPool (initial chunks near camera only):
#   Mesh data generated in parallel across all CPU cores for chunks of the macros
#   near the camera. Same thread-safety contract as before: reads md/w/d
#   (immutable), each task writes to its exclusive _stream_results[ci] slot.
#
# Phase 2 — main thread (initial chunks only):
#   MeshInstance3D nodes created; scene-tree ops are never thread-safe in Godot.
#
# Remaining chunks are queued in _stream_queue and meshed incrementally at
# runtime via _process() → _stream_tick() → WorkerThreadPool batches.

func _build_chunks_from_map_data() -> void:
	var cxl   := ceili(float(w - 1) / chunk_size)
	var czl   := ceili(float(d - 1) / chunk_size)
	var total := cxl * czl

	# Pre-allocate all chunk arrays to the full map size.
	# Unbuilt slots stay null / 0 / AABB() until streaming fills them in.
	# Every system that iterates these arrays guards against null (see below).
	_chunk_instances.resize(total)
	_chunk_lod.resize(total)
	_chunk_stitch_sig.resize(total)   # 0 = no mesh applied yet → forced rebuild on first LOD pass
	_chunk_meshes.resize(total)
	_chunk_aabbs.resize(total)
	_stream_results.resize(total)
	_chunk_flat_err.resize(total)

	# ── Phase 0: parallel AABB scan for ALL chunks ────────────────────────────
	# Only reads heightmap extremes — no mesh generation, very fast even on
	# huge maps. Fills _chunk_aabbs so frustum/macro/occlusion work correctly
	# from the very first frame for every chunk, including not-yet-meshed ones.
	var aabb_task := func(ci: int) -> void:
		var cx := ci % cxl;  var cz := ci / cxl
		var x0 := cx * chunk_size;  var x1 := mini(x0 + chunk_size, w - 1)
		var z0 := cz * chunk_size;  var z1 := mini(z0 + chunk_size, d - 1)
		var min_h := INF;  var max_h := -INF
		# While we are here, measure the chunk's FLATNESS ERROR: how far its terrain departs from
		# a simple surface stretched across its four corners. Flat ground or an even slope gives
		# an error near zero, and such a chunk has no use for a dense mesh.
		var h00 := float(md[z0 * w + x0])
		var h10 := float(md[z0 * w + x1])
		var h01 := float(md[z1 * w + x0])
		var h11 := float(md[z1 * w + x1])
		var span_x := float(maxi(x1 - x0, 1))
		var span_z := float(maxi(z1 - z0, 1))
		var err := 0.0
		for zz in range(z0, z1 + 1):
			var tz := float(zz - z0) / span_z
			for xx in range(x0, x1 + 1):
				var h := float(md[zz * w + xx])
				if h < min_h: min_h = h
				if h > max_h: max_h = h
				var tx := float(xx - x0) / span_x
				var flat := lerpf(lerpf(h00, h10, tx), lerpf(h01, h11, tx), tz)
				err = maxf(err, absf(h - flat))
		if min_h == INF:
			return
		_chunk_flat_err[ci] = err
		_chunk_aabbs[ci] = AABB(
			Vector3(x0 - float(w) * 0.5 + 0.5, min_h, z0 - float(d) * 0.5 + 0.5),
			Vector3(x1 - x0, max_h - min_h, z1 - z0))
	var aabb_gid := WorkerThreadPool.add_group_task(aabb_task, total, -1, true)
	while not WorkerThreadPool.is_group_task_completed(aabb_gid):
		await get_tree().process_frame          # yield frames: the scan reads millions of heightmap cells
	WorkerThreadPool.wait_for_group_task_completion(aabb_gid)   # immediate join

	# ── Materials + macro meshes (the always-resident far representation) ──────
	var mat := _get_material()
	if _mat_lod0 == null:
		_setup_lod_materials(mat)
	# Macro meshes are built directly from the heightmap (one merged step-4 mesh per group),
	# so they need NO individual chunks to exist — that's what lets us instantiate chunks
	# only near the camera. AABBs come from Phase 0.
	await _build_macro_chunks()   # awaited: it yields frames inside, so a loading screen animates
	await _build_quadtree()       # also yields: a thread join plus hundreds of add_child in batches

	# ── Initial resident set: only chunks of macros near the camera ───────────
	# Every other chunk of the map is left uninstantiated; its macro mesh covers it until
	# the camera comes close (then it streams in on demand). Bounds startup memory.
	var cam_pos := _cam.global_position if _cam else Vector3.ZERO
	var load_r  := lod_distance_1 + QT_EVICT_MARGIN
	var load_d2 := load_r * load_r
	var near_chunks: Array[int] = []
	for mi in _macro_instances.size():
		var c := global_transform * _macro_aabbs[mi].get_center()
		var dx := cam_pos.x - c.x
		var dz := cam_pos.z - c.z
		if dx * dx + dz * dz <= load_d2:
			_resident_set[mi] = true
			for ci in _macro_to_chunks[mi]:
				near_chunks.append(ci)

	if not near_chunks.is_empty():
		var build_task := func(i: int) -> void:
			_build_chunk_worker(near_chunks[i], cxl)
		var gid := WorkerThreadPool.add_group_task(build_task, near_chunks.size(), -1, true)
		while not WorkerThreadPool.is_group_task_completed(gid):
			await get_tree().process_frame          # yield while the threads build the near chunks
		WorkerThreadPool.wait_for_group_task_completion(gid)   # immediate join
		await _apply_built_results(near_chunks, mat, NODE_BATCH)   # hundreds of nodes, in batches
		var done := 0
		for ci in near_chunks:
			if ci >= 0 and ci < _chunk_instances.size() and _chunk_instances[ci]:
				_apply_lod_mesh(ci, mat)
			done += 1
			if done % NODE_BATCH == 0:
				await get_tree().process_frame

	# Near chunks are built synchronously above; nothing is queued at startup. On-demand
	# streaming (_request_resident) fills the queue later as the camera moves.
	_stream_queue.clear()
	_is_streaming = false

# Computes all 4 LOD meshes for chunk ci and stores the result in _stream_results[ci].
# Thread-safe: reads only md/w/d (immutable during build), writes only to its
# exclusive _stream_results[ci] slot — same pattern as the original Phase 1.
func _build_chunk_worker(ci: int, cxl: int) -> void:
	var cx := ci % cxl;  var cz := ci / cxl
	var x0 := cx * chunk_size;  var x1 := mini(x0 + chunk_size, w - 1)
	var z0 := cz * chunk_size;  var z1 := mini(z0 + chunk_size, d - 1)
	var lod_meshes: Array = []
	var first_aabb := AABB()
	for lod in LOD_COUNT:
		var data := _compute_chunk_data(x0, z0, x1, z1, _step_for(lod))
		if data.is_empty():
			lod_meshes.append(null)
			continue
		var am := ArrayMesh.new()
		am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, data[0])
		lod_meshes.append(am)
		if lod == 0:
			first_aabb = data[1]
	_stream_results[ci] = [lod_meshes, first_aabb]

# Creates a MeshInstance3D for each ci in indices whose _stream_results[ci] is ready.
# MUST run on the main thread — adds nodes to the scene tree. Instances are created
# hidden; the quadtree's next descend decides their visibility and LOD.
# batch > 0 yields a frame every batch nodes, so hundreds of add_child calls do not land as one
# freeze. Only the initial build needs it; streaming passes 0, since its batches are small.
func _apply_built_results(indices: Array, mat: Material, batch: int = 0) -> void:
	var made := 0
	for ci in indices:
		if _stream_results[ci] == null:
			continue
		if batch > 0 and made > 0 and made % batch == 0:
			await get_tree().process_frame
		made += 1
		var lod_meshes: Array = _stream_results[ci][0]
		_stream_results[ci]   = null

		var inst := MeshInstance3D.new()
		inst.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		inst.visible     = false
		add_child(inst)
		_chunk_instances[ci] = inst
		_chunk_lod[ci]       = 0
		_chunk_stitch_sig[ci] = 1     # plain LOD-0, no border snap (= _stitch_signature for that state)
		_chunk_meshes[ci]    = lod_meshes
		# Note: _chunk_aabbs[ci] was already filled by Phase 0 with an identical
		# value (same heightmap scan); we skip the redundant write to avoid any
		# potential race if a frustum task is still in flight.

		var start_mesh := _best_available_mesh(lod_meshes, 0)
		if start_mesh:
			inst.mesh = start_mesh
			var lod_mat := _mat_lod0 if _mat_lod0 else mat
			inst.set_surface_override_material(0, lod_mat)

		# Created hidden. The quadtree's next descend (_qt_update) decides whether this
		# chunk renders individually, is covered by an active macro, or stays culled —
		# no frustum bookkeeping needed here.
		inst.visible = false

# Applies the correct mesh to chunk ci, rebuilding with border snapping when
# the chunk is at LOD 0 and any neighbour is at a coarser step.
func _apply_lod_mesh(ci: int, mat: Material) -> void:
	if ci >= _chunk_lod.size() or ci >= _chunk_instances.size() or ci >= _chunk_meshes.size():
		return
	if not _chunk_instances[ci]:
		return   # chunk not yet streamed in
	var target_lod := _chunk_lod[ci]
	var my_step    := _step_for(target_lod)
	var cxl        := ceili(float(w - 1) / chunk_size)
	var cx         := ci % cxl
	var cz         := ci / cxl

	# Stitching applies to ANY LOD level, not just LOD-0.
	# A LOD-1 (step=2) chunk adjacent to an active macro group (step=4) also
	# produces T-junction cracks without seam snapping. Snap only toward COARSER
	# neighbours (step > my_step); pass 0 for the rest.
	var n_snap := _border_snap(cx, cz,  0, -1, my_step)
	var s_snap := _border_snap(cx, cz,  0,  1, my_step)
	var w_snap := _border_snap(cx, cz, -1,  0, my_step)
	var e_snap := _border_snap(cx, cz,  1,  0, my_step)

	# Record the signature of the mesh we are about to apply, so the quadtree LOD pass can tell
	# when this chunk needs rebuilding again (its LOD or any neighbour's step changed).
	if ci < _chunk_stitch_sig.size():
		_chunk_stitch_sig[ci] = _encode_sig(my_step, n_snap, s_snap, w_snap, e_snap)

	var lod_mat := (_mat_lod0 if target_lod == 0 else _mat_lod_high) if _mat_lod0 else mat

	if n_snap != 0 or s_snap != 0 or w_snap != 0 or e_snap != 0:
		# Rebuild this chunk's mesh with seam-snapped border vertices
		var x0 := cx * chunk_size
		var z0 := cz * chunk_size
		var x1 := mini(x0 + chunk_size, w - 1)
		var z1 := mini(z0 + chunk_size, d - 1)
		var data := _compute_chunk_data(x0, z0, x1, z1, my_step,
				n_snap, s_snap, w_snap, e_snap)
		if not data.is_empty():
			var am := ArrayMesh.new()
			am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, data[0])
			_chunk_instances[ci].mesh = am
			_chunk_instances[ci].set_surface_override_material(0, lod_mat)
			return

	# No stitching needed — use the pre-built LOD mesh
	var display_mesh := _best_available_mesh(_chunk_meshes[ci], target_lod)
	if display_mesh:
		_chunk_instances[ci].mesh = display_mesh
	_chunk_instances[ci].set_surface_override_material(0, lod_mat)

# Returns the neighbour's LOD step if it DIFFERS from my_step, else 0. Used both for
# height snapping (only when the value is COARSER, i.e. > my_step) and for grass-seam
# flattening (whenever it is non-zero, i.e. any LOD difference, either direction).
func _border_snap(cx: int, cz: int, dcx: int, dcz: int, my_step: int) -> int:
	var s := _neighbour_step(cx, cz, dcx, dcz)
	return s if s != my_step else 0

# Packs a chunk's LOD step and its 4 border snap steps into one int. Two chunks with
# the same signature produce byte-identical meshes, so the quadtree LOD pass only rebuilds when
# the signature actually changes. Each value is ≤ 8, so 4 bits per field is plenty.
func _encode_sig(my_step: int, n_snap: int, s_snap: int, w_snap: int, e_snap: int) -> int:
	return my_step | (n_snap << 4) | (s_snap << 8) | (w_snap << 12) | (e_snap << 16)

# Current required signature for chunk ci (its LOD step + the snap step each border
# needs given its neighbours right now). Compared against _chunk_stitch_sig to decide
# whether the chunk's mesh is stale and must be rebuilt.
func _stitch_signature(ci: int) -> int:
	var cxl := ceili(float(w - 1) / chunk_size)
	var cx := ci % cxl
	var cz := ci / cxl
	var my_step := _step_for(_chunk_lod[ci])
	return _encode_sig(my_step,
			_border_snap(cx, cz,  0, -1, my_step),
			_border_snap(cx, cz,  0,  1, my_step),
			_border_snap(cx, cz, -1,  0, my_step),
			_border_snap(cx, cz,  1,  0, my_step))

# Returns the flat chunk index for grid position (cx, cz), or -1 if out of bounds.
func _get_chunk_idx(cx: int, cz: int) -> int:
	var cxl := ceili(float(w - 1) / chunk_size)
	var czl := ceili(float(d - 1) / chunk_size)
	if cx < 0 or cx >= cxl or cz < 0 or cz >= czl:
		return -1
	return cz * cxl + cx

# Returns the LOD vertex-step of the neighbour at (cx+dcx, cz+dcz).
# Macro groups report step=4 (their merged mesh uses LOD 2).
# Map-edge neighbours return 1 (same as LOD 0, so no snap triggered).
func _neighbour_step(cx: int, cz: int, dcx: int, dcz: int) -> int:
	var nx := cx + dcx
	var nz := cz + dcz
	var ni := _get_chunk_idx(nx, nz)
	if ni < 0 or ni >= _chunk_lod.size():
		return 1   # map boundary or not-yet-built chunk — no snap
	# THE COARSE QUADTREE MESH COMES FIRST. There are THREE representations of the ground —
	# chunk meshes, merged macro meshes, and the internal quadtree nodes' single coarse mesh —
	# and this function used to know only the first two. Where a chunk bordered a region drawn
	# as a quadtree node, neither side knew the other's step, so no height snapping happened at
	# all — and the step gap there is the largest in the whole system (a node is 8 to 64 samples
	# per quad against the chunk's 1). That is the hole you can see the sky through.
	#
	# A chunk hidden under such a node also keeps a STALE _chunk_lod, so asking it was not just
	# incomplete, it answered with a number that meant nothing.
	var node_step := _node_step_covering(nx, nz)
	if node_step > 0:
		return node_step
	if _chunk_macro_idx.size() > ni and _macro_active[_chunk_macro_idx[ni]]:
		return _step_for(2)   # macro group uses LOD-2 step
	return _step_for(_chunk_lod[ni])

## Sample step of the coarse quadtree mesh currently covering chunk (cx, cz), or 0 if that
## area is drawn as chunks/macros. Walks down from the root instead of keeping a per-chunk
## table: the tree is a handful of levels deep, and the question is only ever asked for the
## few chunks sitting on a seam.
func _node_step_covering(cx: int, cz: int) -> int:
	if not _qt_built or _qt_cur_nodes.is_empty():
		return 0
	var px := cx * chunk_size
	var pz := cz * chunk_size
	var node := 0
	for _guard in 32:
		if node < 0 or node >= _qt_rect.size():
			return 0
		var r: Vector4i = _qt_rect[node]
		if px < r.x or px > r.z or pz < r.y or pz > r.w:
			return 0                       # outside this subtree entirely
		if _qt_cur_nodes.has(node):
			return _qt_step[node]          # this node's coarse mesh is what draws here
		var kids: Array = _qt_child[node]
		if kids.is_empty():
			return 0                       # leaf macro — handled by the macro/chunk branches
		var nxt := -1
		for ch in kids:
			var cr: Vector4i = _qt_rect[ch]
			if px >= cr.x and px <= cr.z and pz >= cr.y and pz <= cr.w:
				nxt = ch
				break
		if nxt < 0:
			return 0
		node = nxt
	return 0

# Returns the mesh at `preferred_lod`, falling back to the next finer LOD
# if the preferred one happens to be null (tiny edge-chunks may skip coarse LODs).
func _best_available_mesh(lod_meshes: Array, preferred_lod: int) -> ArrayMesh:
	var lod: int = preferred_lod
	while lod > 0 and lod_meshes[lod] == null:
		lod -= 1
	return lod_meshes[lod]

# ─────────────────────────────────────────────────────────────────────────────
# Macro-chunk building & management
# ─────────────────────────────────────────────────────────────────────────────

# Groups individual chunks into MACRO_SIZE×MACRO_SIZE cells.
# Each cell gets one MeshInstance3D (shadows OFF) whose mesh is the merged
# LOD-2 geometry of all sub-chunks.
# Called once, at the end of _build_chunks_from_map_data(), after every
# _chunk_aabbs entry is populated (by Phase 0 — includes unbuilt chunks).
func _build_macro_chunks() -> void:
	var mat := _get_material()
	var cxl := ceili(float(w - 1) / chunk_size)   # individual chunks wide
	var czl := ceili(float(d - 1) / chunk_size)   # individual chunks deep
	var _macro_cx := ceili(float(cxl) / MACRO_SIZE)
	var _macro_cz := ceili(float(czl) / MACRO_SIZE)

	_chunk_macro_idx.resize(_chunk_instances.size())

	# ── Pass A: group structure + merged AABB (main thread) ───────────────────
	# Cheap on small maps, but at 124x124 chunks this is some 15,000 iterations of AABB.merge and
	# append in one go. Yield a frame after each ROW of macro groups.
	for mz in _macro_cz:
		if mz > 0:
			await get_tree().process_frame
		for mx in _macro_cx:
			# The macro index for this group is the current length of _macro_to_chunks
			# (assigned before the append, so it equals mz*_macro_cx + mx).
			var mi_now  := _macro_to_chunks.size()
			var c_list  := []
			var grp_aabb := AABB()
			var first   := true

			for dz in MACRO_SIZE:
				for dx in MACRO_SIZE:
					var cx := mx * MACRO_SIZE + dx
					var cz := mz * MACRO_SIZE + dz
					if cx >= cxl or cz >= czl:
						continue
					var ci := cz * cxl + cx
					c_list.append(ci)
					_chunk_macro_idx[ci] = mi_now
					if first:
						grp_aabb = _chunk_aabbs[ci]   # Phase 0 guaranteed all AABBs filled
						first    = false
					else:
						grp_aabb = grp_aabb.merge(_chunk_aabbs[ci])

			_macro_to_chunks.append(c_list)
			_macro_aabbs.append(grp_aabb)
			_macro_active.append(false)

	# ── Pass B: build each macro's merged step-4 mesh in parallel ─────────────
	# Built directly from the heightmap over the whole group extent — independent of
	# whether any individual chunk is instantiated, so chunks can be freed/streamed freely.
	var macro_n := _macro_instances_target_count()
	_macro_results.clear()
	_macro_results.resize(macro_n)
	if macro_n > 0:
		var macro_task := func(mi: int) -> void:
			_build_macro_worker(mi, cxl)
		var mgid := WorkerThreadPool.add_group_task(macro_task, macro_n, -1, true)
		while not WorkerThreadPool.is_group_task_completed(mgid):
			await get_tree().process_frame          # yield frames, so a loading screen animates
		WorkerThreadPool.wait_for_group_task_completion(mgid)   # immediate join

	# ── Pass C: create the macro MeshInstance3D nodes (main thread) ───────────
	# There are hundreds of nodes (around 961 at 124x124 chunks). add_child both enters the tree
	# and creates a render instance, so doing them all in one frame is a multi-second freeze.
	# Create them in NODE_BATCH-sized batches, yielding a frame between them.
	for mi in macro_n:
		var inst := MeshInstance3D.new()
		inst.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		inst.visible     = false   # the quadtree shows/hides macros each frame
		var macro_mesh: ArrayMesh = _macro_results[mi]
		if macro_mesh:
			inst.mesh = macro_mesh
			inst.set_surface_override_material(0, _mat_lod_high if _mat_lod_high else mat)
		add_child(inst)
		_macro_instances.append(inst)
		if (mi + 1) % NODE_BATCH == 0:
			await get_tree().process_frame
	_macro_results.clear()

# Number of macro groups (= entries already pushed into _macro_to_chunks by Pass A).
func _macro_instances_target_count() -> int:
	return _macro_to_chunks.size()

# Threaded worker: builds macro mi's merged LOD-2 (step-4) mesh straight from the
# heightmap over the group's full XZ extent. One surface, ~512 tris. Pure math + a
# fresh ArrayMesh (same off-thread pattern as _build_chunk_worker).
func _build_macro_worker(mi: int, cxl: int) -> void:
	var c_list: Array = _macro_to_chunks[mi]
	if c_list.is_empty():
		return
	var first_ci: int = c_list[0]
	var mgx := (first_ci % cxl) / MACRO_SIZE
	var mgz := (first_ci / cxl) / MACRO_SIZE
	var x0  := mgx * MACRO_SIZE * chunk_size
	var z0  := mgz * MACRO_SIZE * chunk_size
	var x1  := mini(x0 + MACRO_SIZE * chunk_size, w - 1)
	var z1  := mini(z0 + MACRO_SIZE * chunk_size, d - 1)
	# Skirt so the macro↔coarse-node seam (different LOD steps) never shows a crack.
	var data := _compute_chunk_data(x0, z0, x1, z1, _step_for(2))
	if data.is_empty():
		return
	var am := ArrayMesh.new()
	am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, data[0])
	_macro_results[mi] = am

# Merges the lod_level mesh of every chunk in chunk_indices into a single
# ArrayMesh with one surface → one draw call.  Returns null if no geometry.
func _build_macro_mesh(chunk_indices: Array, lod_level: int) -> ArrayMesh:
	var all_verts   := PackedVector3Array()
	var all_idx     := PackedInt32Array()
	var all_normals := PackedVector3Array()
	var all_uvs     := PackedVector2Array()
	var all_colors  := PackedColorArray()
	var v_offset    := 0

	for ci in chunk_indices:
		if ci < 0 or ci >= _chunk_meshes.size():
			continue
		if not _chunk_meshes[ci]:   # chunk not yet streamed in
			continue
		var src := _best_available_mesh(_chunk_meshes[ci], lod_level)
		if src == null or src.get_surface_count() == 0:
			continue
		var arrays  := src.surface_get_arrays(0)
		var verts   := arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array
		var idxs    := arrays[Mesh.ARRAY_INDEX]  as PackedInt32Array
		var norms   := arrays[Mesh.ARRAY_NORMAL] as PackedVector3Array
		var uvs     := arrays[Mesh.ARRAY_TEX_UV] as PackedVector2Array
		var cols    := arrays[Mesh.ARRAY_COLOR]  as PackedColorArray
		if verts == null or verts.is_empty():
			continue
		all_verts.append_array(verts)
		all_normals.append_array(norms)
		all_uvs.append_array(uvs)
		if cols != null and cols.size() == verts.size():
			all_colors.append_array(cols)
		else:
			# Source lacks colours — treat as all-interior so grass behaves as before.
			for _i in verts.size():
				all_colors.append(Color(1.0, 0.0, 0.0, 0.0))   # fallback: no canyon (.g), no mountains (.a)
		for raw_idx in idxs:
			all_idx.append(raw_idx + v_offset)
		v_offset += verts.size()

	if all_verts.is_empty():
		return null

	var arr := Array()
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = all_verts
	arr[Mesh.ARRAY_INDEX]  = all_idx
	arr[Mesh.ARRAY_NORMAL] = all_normals
	arr[Mesh.ARRAY_TEX_UV] = all_uvs
	arr[Mesh.ARRAY_COLOR]  = all_colors

	var am := ArrayMesh.new()
	am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	return am

# ─────────────────────────────────────────────────────────────────────────────
# Chunk streaming  (called from _process when _is_streaming == true)
# ─────────────────────────────────────────────────────────────────────────────

# Ticked once per frame while there are unbuilt chunks.
# Non-blocking: dispatches workers, then checks back next frame.
# The main thread never stalls — it applies a batch only when it's already done.
func _stream_tick(_delta: float) -> void:
	# Step 1: apply the completed batch
	if _stream_group_id >= 0 and WorkerThreadPool.is_group_task_completed(_stream_group_id):
		WorkerThreadPool.wait_for_group_task_completion(_stream_group_id)   # instant join
		_stream_group_id = -1
		_stream_apply_batch()
	# Step 2: kick off the next batch while the queue has work
	if _stream_group_id < 0 and not _stream_queue.is_empty():
		_stream_dispatch_batch()

func _stream_dispatch_batch() -> void:
	var count := mini(stream_batch_size, _stream_queue.size())
	_stream_batch = _stream_queue.slice(0, count)
	_stream_queue = _stream_queue.slice(count)
	var cxl := ceili(float(w - 1) / chunk_size)
	var task := func(i: int) -> void:
		_build_chunk_worker(_stream_batch[i], cxl)
	_stream_group_id = WorkerThreadPool.add_group_task(
			task, count, -1, true, "stream_chunk")

func _stream_apply_batch() -> void:
	var mat := _get_material()
	_apply_built_results(_stream_batch, mat)

	# Macro meshes are built once at startup and never rebuilt at runtime (the heightmap
	# doesn't change), so streamed-in chunks DON'T touch them — they only fill the
	# individual-chunk detail back in for a macro the camera is approaching.
	var touched := {}
	for ci in _stream_batch:
		_queued_chunks.erase(ci)
		if _chunk_macro_idx.size() > ci:
			touched[_chunk_macro_idx[ci]] = true

	# Seam-stitch each freshly-streamed chunk against its already-present neighbours
	# (snaps toward coarser/active-macro neighbours; a no-op when none differ).
	for ci in _stream_batch:
		if ci < 0 or ci >= _chunk_instances.size() or not _chunk_instances[ci]:
			continue
		if _chunk_macro_idx.size() > ci and _macro_active[_chunk_macro_idx[ci]]:
			continue
		_apply_lod_mesh(ci, mat)

	# A macro becomes "resident" once all its chunks are present — the quadtree may then
	# expand it into individual chunks instead of showing the merged macro mesh.
	for mi in touched:
		if _macro_all_present(mi):
			_resident_set[mi] = true

	if _stream_queue.is_empty():
		_is_streaming = false

# ─────────────────────────────────────────────────────────────────────────────
# Core geometry helper
# ─────────────────────────────────────────────────────────────────────────────

# Generates a sorted list of sample positions from `start` to `end` inclusive,
# stepping by `step`.  `end` is always included even if it's not on the grid —
# this guarantees chunk edges share the same vertex positions across LOD levels,
# which eliminates visible seams between adjacent chunks at different LODs.
func _sample_range(start: int, end: int, step: int) -> PackedInt32Array:
	var result: PackedInt32Array = PackedInt32Array()
	var pos: int = start
	while pos < end:
		result.append(pos)
		pos += step
	# Always include the boundary (avoids duplicate if step divides evenly)
	if result.is_empty() or result[result.size() - 1] != end:
		result.append(end)
	return result

func _cv_fract(v: float) -> float:
	return v - floor(v)
func _cv_hash2d(p: Vector2) -> float:
	p = Vector2(_cv_fract(p.x * 123.34), _cv_fract(p.y * 456.21))
	var dd: float = p.dot(p + Vector2(45.32, 45.32))
	p += Vector2(dd, dd)
	return _cv_fract(p.x * p.y)
func _cv_noise(p: Vector2) -> float:
	var i := Vector2(floor(p.x), floor(p.y))
	var f := p - i
	f = f * f * (Vector2(3.0, 3.0) - 2.0 * f)
	var a := _cv_hash2d(i)
	var b := _cv_hash2d(i + Vector2(1.0, 0.0))
	var c := _cv_hash2d(i + Vector2(0.0, 1.0))
	var dh := _cv_hash2d(i + Vector2(1.0, 1.0))
	return lerpf(lerpf(a, b, f.x), lerpf(c, dh, f.x), f.y)
# ── Biome masks: computed ONCE on a sparse lattice, then read back with interpolation ────
# The biome layout is a pure function of (x,z) and never changes on a static map. The masks are
# very smooth (hundreds of world units across), so a lattice with a MASK_STEP spacing is plenty:
# orders of magnitude fewer noise calls than one per vertex, with no visible difference.
# The lattice is built BEFORE the threaded build and never touched again — reading a
# PackedFloat32Array from worker threads is safe, unlike a Dictionary cache, which would race.
const MASK_STEP := 8
var _mask_lat := PackedFloat32Array()
var _mask_w: int = 0
var _mask_h: int = 0

## The lattice, built WITHOUT yielding — for the editor, where a rebuild is one blocking call
## and there is no loading screen to keep alive. It is small by construction: with MASK_STEP 8
## a 1982² map is about 250×250 points, so ~190 thousand noise calls once, against three per
## VERTEX (some twelve million) if it is missing. That absence is why "Generate Terrain" took
## minutes: the masks were being recomputed from noise for every vertex of the whole map.
func _build_mask_lattice_sync() -> void:
	if w <= 0 or d <= 0:
		return
	_mask_w = int(ceil(float(w) / float(MASK_STEP))) + 1
	_mask_h = int(ceil(float(d) / float(MASK_STEP))) + 1
	_mask_lat.resize(_mask_w * _mask_h * 3)
	for j in _mask_h:
		var gz := j * MASK_STEP
		for i in _mask_w:
			var gx := i * MASK_STEP
			var o := (j * _mask_w + i) * 3
			_mask_lat[o]     = _canyon_mask01(gx, gz)
			_mask_lat[o + 1] = _biome_grass01(gx, gz)
			_mask_lat[o + 2] = _mountain_mask01(gx, gz)

func _build_mask_lattice() -> void:
	if w <= 0 or d <= 0:
		return
	_mask_w = int(ceil(float(w) / float(MASK_STEP))) + 1
	_mask_h = int(ceil(float(d) / float(MASK_STEP))) + 1
	_mask_lat.resize(_mask_w * _mask_h * 3)
	for j in _mask_h:
		var gz := j * MASK_STEP
		for i in _mask_w:
			var gx := i * MASK_STEP
			var o := (j * _mask_w + i) * 3
			_mask_lat[o]     = _canyon_mask01(gx, gz)
			_mask_lat[o + 1] = _biome_grass01(gx, gz)
			_mask_lat[o + 2] = _mountain_mask01(gx, gz)
		if (j & 15) == 0:
			await get_tree().process_frame     # do not freeze a loading screen

# The masks at a point (canyon, meadow, mountain), bilinear off the lattice; without one, direct.
func _masks_at(gx: int, gz: int) -> Vector3:
	if _mask_lat.is_empty():
		return Vector3(_canyon_mask01(gx, gz), _biome_grass01(gx, gz), _mountain_mask01(gx, gz))
	var fx: float = float(gx) / float(MASK_STEP)
	var fz: float = float(gz) / float(MASK_STEP)
	var i0: int = clampi(int(floor(fx)), 0, _mask_w - 1)
	var j0: int = clampi(int(floor(fz)), 0, _mask_h - 1)
	var i1: int = mini(i0 + 1, _mask_w - 1)
	var j1: int = mini(j0 + 1, _mask_h - 1)
	var tx: float = clampf(fx - float(i0), 0.0, 1.0)
	var tz: float = clampf(fz - float(j0), 0.0, 1.0)
	var a := (j0 * _mask_w + i0) * 3
	var b := (j0 * _mask_w + i1) * 3
	var c := (j1 * _mask_w + i0) * 3
	var e := (j1 * _mask_w + i1) * 3
	return Vector3(
		lerpf(lerpf(_mask_lat[a],     _mask_lat[b],     tx), lerpf(_mask_lat[c],     _mask_lat[e],     tx), tz),
		lerpf(lerpf(_mask_lat[a + 1], _mask_lat[b + 1], tx), lerpf(_mask_lat[c + 1], _mask_lat[e + 1], tx), tz),
		lerpf(lerpf(_mask_lat[a + 2], _mask_lat[b + 2], tx), lerpf(_mask_lat[c + 2], _mask_lat[e + 2], tx), tz))

## BIOME WEIGHTS UNDER A WORLD POINT: (canyon, meadow, mountains), each 0..1. What is left over
## — 1 minus the strongest of them — is desert, the base layer everything else is painted on.
##
## Public because the world above the terrain wants the same answer the terrain paints with: ore
## veins that belong to a biome, props that only grow in one, spawn rules that avoid the rocks.
## Reading it from the same lattice the colours come from is the whole point — a second guess at
## "where the canyon is" would drift away from the canyon you can see.
func biome_at(world_pos: Vector3) -> Vector3:
	if md.is_empty() or w <= 0 or d <= 0:
		return Vector3.ZERO
	var local: Vector3 = global_transform.affine_inverse() * world_pos
	var gx: int = clampi(int(round(local.x + float(w) * 0.5 - 0.5)), 0, w - 1)
	var gz: int = clampi(int(round(local.z + float(d) * 0.5 - 0.5)), 0, d - 1)
	return _masks_at(gx, gz)

# World XZ of a heightmap cell, exactly as the generator computes it: grid minus size/2.
func _biome_wp(gx: int, gz: int) -> Vector2:
	return Vector2(float(gx) - w * 0.5, float(gz) - d * 0.5)

# The masks are baked into the vertex COLOR: .g is canyon, .b is meadow, .a is mountains. The
# shader only reads them, so the biome layout is identical for the colour and the landform.
func _canyon_mask01(gx: int, gz: int) -> float:
	return _biomes().canyon_mask(_biome_wp(gx, gz), _cv_noise)

func _biome_grass01(gx: int, gz: int) -> float:
	return _biomes().meadow_mask(_biome_wp(gx, gz), _cv_noise)

func _mountain_mask01(gx: int, gz: int) -> float:
	return _biomes().mountain_mask(_biome_wp(gx, gz), _cv_noise)

# ── VISUAL DETAIL THE COLLISION DOES NOT HAVE ────────────────────────────────
# Collision is cut straight from the heights (md); the render mesh is built separately. That
# gap is room to spend on looks: wind ripples across sand, roughness on rock, without a single
# extra collision shape and without the wheels feeling any of it. The ground a machine drives
# on stays exactly the ground the physics knows.
#
# Three rules, and none of them is optional:
#   1. NEAR CHUNKS ONLY (step <= DETAIL_MAX_STEP). At distance the detail is invisible anyway,
#      and paying for it across the whole map is how a terrain gets slow.
#   2. ZERO AT THE CHUNK BORDER (DETAIL_FADE cells). The neighbour may sit at another LOD, and
#      any height we add that it does not add is the seam crack all over again.
#   3. A PURE FUNCTION OF WORLD XZ AND BIOME. Two chunks evaluating the same point must get the
#      same answer, or the detail itself becomes a seam.
const DETAIL_MAX_STEP: int = 2       # LOD 0 at triangle_size 1
const DETAIL_FADE: float = 2.0       # cells over which the detail fades out towards a border
## Sand ripples: wind-blown waves across the dunes. Amplitude stays below a wheel radius — this
## is meant to catch the light, not to be terrain.
##
## THE WAVELENGTH IS SET BY THE VERTEX SPACING, not by taste. LOD 0 puts a vertex every
## `triangle_size` units (2 by default), and a wave shorter than about four of those cannot be
## drawn at all — it aliases into noise that crawls as the camera moves. Nine units gives four
## samples per crest and reads as drifting sand at the scale of our machines.
## Kept small on purpose: the machine drives on the PHYSICAL surface, so on a crest a wheel
## sinks into the drawn one by exactly this much. A fifth of a metre is a shadow; half a metre
## is a wheel buried to the axle.
const RIPPLE_AMP: float = 0.20
const RIPPLE_LEN: float = 9.0        # world units between crests
const RIPPLE_DIR := Vector2(0.82, 0.57)     # wind direction (normalised below)
const RIPPLE_CROSS: float = 0.45     # a slow wave across the first — kills the corduroy look
## Rock roughness: chiselled instead of smoothed-over. Applied by SLOPE, so it lands on canyon
## walls and mountain faces and never on a floor a machine parks on. Same wavelength rule as
## the ripples — value noise, not per-vertex hash, or it turns into shimmering static.
const ROCK_ROUGH: float = 0.45
const ROCK_NOISE_LEN: float = 7.0
const ROCK_SLOPE_MIN: float = 0.6    # height difference per cell where rock starts reading as rock

## Longest side of a merged flat rectangle, in cells. Unbounded merging would draw a whole
## canyon floor as one quad — correct geometrically, but the biome colour lives in the VERTICES,
## so the shading would be interpolated across a hundred metres from four corners.
const MERGE_MAX: int = 16
## How equal is "flat". The heights come from a float texture, so exact comparison is wrong;
## a millimetre is far below anything visible and far below what would move the surface off
## the collision.
const MERGE_EPS: float = 0.001

## Are all four corners of cell (cx, cz) at height h0? Vertices are laid out row-major over the
## sample grid, so the index arithmetic is direct — no dictionary lookup per corner.
func _cell_flat(verts: PackedVector3Array, nx: int, cx: int, cz: int, h0: float) -> bool:
	var i: int = cz * nx + cx
	return absf(verts[i].y - h0) < MERGE_EPS \
			and absf(verts[i + 1].y - h0) < MERGE_EPS \
			and absf(verts[i + nx].y - h0) < MERGE_EPS \
			and absf(verts[i + nx + 1].y - h0) < MERGE_EPS

## How much detail this vertex may take: full inside the chunk, zero at its border.
func _detail_weight(x: int, z: int, x0: int, z0: int, x1: int, z1: int) -> float:
	var dx: float = minf(float(x - x0), float(x1 - x))
	var dz: float = minf(float(z - z0), float(z1 - z))
	return clampf(minf(dx, dz) / DETAIL_FADE, 0.0, 1.0)

## Height the MESH adds on top of the real terrain at this point. masks = (canyon, meadow,
## mountains); sand is what is left. Returns 0 for anything that is not sand or rock.
func _detail_height(wx: float, wz: float, masks: Vector3, slope: float) -> float:
	var out: float = 0.0
	var sand: float = clampf(1.0 - maxf(masks.x, maxf(masks.y, masks.z)), 0.0, 1.0)
	if sand > 0.01:
		var dir: Vector2 = RIPPLE_DIR.normalized()
		var t: float = (wx * dir.x + wz * dir.y) / RIPPLE_LEN
		var u: float = (wx * -dir.y + wz * dir.x) / (RIPPLE_LEN * 7.0)
		# Ripples ride on a long cross-wave, so the field reads as drifting sand rather than
		# corduroy: crests bend and fade instead of running dead straight to the horizon.
		out += sand * RIPPLE_AMP * sin(t * TAU + sin(u * TAU) * RIPPLE_CROSS)
	var rock: float = clampf((slope - ROCK_SLOPE_MIN) / ROCK_SLOPE_MIN, 0.0, 1.0)
	if rock > 0.01:
		# Smooth value noise (the same one the canyon carve uses), so rock detail is stable per
		# world point and identical in every chunk that evaluates it.
		out += rock * ROCK_ROUGH * (_cv_noise(Vector2(wx, wz) / ROCK_NOISE_LEN) - 0.5) * 2.0
	return out

## May a border be snapped to the neighbour's coarser grid? Only if the neighbour IS coarser
## and its grid is a superset of ours, so the two samples we interpolate between are vertices
## it really built. Every step in the system is a power of two (chunks 2/4/8, nodes 8…64 — see
## _qt_step), and every mesh origin is a multiple of the largest of them, so this holds by
## construction; the check is here to fail loudly-by-doing-nothing if that ever stops being true.
func _snap_ok(n_step: int, step: int) -> bool:
	return n_step > step and (n_step % step) == 0

func _compute_chunk_data(x0: int, z0: int, x1: int, z1: int, step: int = 1,
		n_step: int = 0, s_step: int = 0,
		w_step: int = 0, e_step: int = 0) -> Array:
	var vertices: PackedVector3Array = PackedVector3Array()
	var indices: PackedInt32Array = PackedInt32Array()
	var normals: PackedVector3Array = PackedVector3Array()
	var uvs: PackedVector2Array = PackedVector2Array()
	var colors: PackedColorArray = PackedColorArray()   # .r = grass mask: 0 on chunk borders, 1 inside
	var aabb_min: Vector3 = Vector3(INF,  INF,  INF)
	var aabb_max: Vector3 = Vector3(-INF, -INF, -INF)

	var sz: int = maxi(1, step)
	# DETAIL IS A RUNTIME-ONLY THING, and the flag is computed ONCE per chunk rather than per
	# vertex. In the editor the map is rebuilt in FULL at step 1, in one go, on the main thread:
	# a 1982² map is some fifteen thousand chunks, and five extra noise evaluations per vertex
	# turned "Generate Terrain" into a freeze the OS eventually kills. The editor also has the
	# better reason to show the bare surface — that is the one the sculpt brush and the collision
	# actually work with.
	var detail_on: bool = sz <= DETAIL_MAX_STEP and not Engine.is_editor_hint()
	var xs: PackedInt32Array = _sample_range(x0, x1, sz)
	var zs: PackedInt32Array = _sample_range(z0, z1, sz)
	# A degenerate chunk (fewer than 2x2 samples) has no quads to build. On small maps that used
	# to raise a mesh-build error; return empty instead and the chunk simply is not drawn.
	if xs.size() < 2 or zs.size() < 2:
		return []

	# ── Vertices ──────────────────────────────────────────────────────────────
	for z in zs:
		for x in xs:
			var h: float = float(md[z * w + x])

			# ── Border snapping ───────────────────────────────────────────────
			# If this vertex is on an edge adjacent to a coarser-LOD chunk and
			# its position is not on the coarser grid, snap its height to the
			# linear interpolation of the two coarser neighbours.
			# Guarantee: chunk_size=16 is divisible by all possible steps (1,2,4,8),
			# so x0/z0 are always aligned with the neighbour grid — no clamping needed.

			# The neighbouring sample (x-rem+step / z-rem+step) can run off the EDGE of the map
			# on the outermost border, where there is no neighbouring chunk, giving an index a
			# row or column past md — which is where "Invalid access" came from. Clamp it.

			# There is no skirt behind this any more (it cost triangles and looked bad): the
			# seam has to MEET, so snapping is the only thing closing it. See _snap_ok.
			# North border (z == z0): snap x to n_step grid
			if z == z0 and _snap_ok(n_step, step):
				var rem: int = x % n_step
				if rem != 0:
					h = lerp(float(md[z * w + x - rem]),
							 float(md[z * w + mini(x - rem + n_step, w - 1)]),
							 float(rem) / float(n_step))

			# South border (z == z1): snap x to s_step grid
			elif z == z1 and _snap_ok(s_step, step):
				var rem: int = x % s_step
				if rem != 0:
					h = lerp(float(md[z * w + x - rem]),
							 float(md[z * w + mini(x - rem + s_step, w - 1)]),
							 float(rem) / float(s_step))

			# West border (x == x0): snap z to w_step grid
			if x == x0 and _snap_ok(w_step, step):
				var rem: int = z % w_step
				if rem != 0:
					h = lerp(float(md[(z - rem) * w + x]),
							 float(md[mini(z - rem + w_step, d - 1) * w + x]),
							 float(rem) / float(w_step))

			# East border (x == x1): snap z to e_step grid
			elif x == x1 and _snap_ok(e_step, step):
				var rem: int = z % e_step
				if rem != 0:
					h = lerp(float(md[(z - rem) * w + x]),
							 float(md[mini(z - rem + e_step, d - 1) * w + x]),
							 float(rem) / float(e_step))

			# ── Visual-only detail (see _detail_height) ───────────────────────
			# Added AFTER border snapping and faded to nothing at the chunk edge, so neither the
			# seam nor the collision knows about it. Masks are read once here and reused for the
			# colour below.
			var mk := _masks_at(x, z)
			var hl0: float = md[z * w + maxi(x - sz, 0)]
			var hr0: float = md[z * w + mini(x + sz, w - 1)]
			var hu0: float = md[maxi(z - sz, 0) * w + x]
			var hd0: float = md[mini(z + sz, d - 1) * w + x]
			var slope: float = (absf(hr0 - hl0) + absf(hd0 - hu0)) / (2.0 * float(sz))
			# The normal has to follow the detail, or the ripples are geometry nobody can see:
			# the terrain is lambert-shaded, so it is the normal that catches the light, not the
			# height. Two extra samples per axis, on near chunks only.
			var dhx: float = 0.0
			var dhz: float = 0.0
			if detail_on:
				var dw: float = _detail_weight(x, z, x0, z0, x1, z1)
				if dw > 0.001:
					var wx: float = float(x) - w * 0.5 + 0.5
					var wz: float = float(z) - d * 0.5 + 0.5
					h += dw * _detail_height(wx, wz, mk, slope)
					const E: float = 0.6
					dhx = dw * (_detail_height(wx + E, wz, mk, slope) - _detail_height(wx - E, wz, mk, slope))
					dhz = dw * (_detail_height(wx, wz + E, mk, slope) - _detail_height(wx, wz - E, mk, slope))
					dhx *= float(sz) / E
					dhz *= float(sz) / E

			var pos: Vector3 = Vector3(x - w * 0.5 + 0.5, h, z - d * 0.5 + 0.5)
			vertices.append(pos)
			aabb_min = aabb_min.min(pos)
			aabb_max = aabb_max.max(pos)
			uvs.append(Vector2(float(x) / w, float(z) / d))

			# Flatten grass ONLY on borders that touch a DIFFERENT-LOD neighbour (a real
			# LOD seam). There the grass vertex offset would re-open a crack, so the shader
			# skips it (COLOR.r = 0). On same-LOD borders grass stays on — otherwise every
			# chunk edge shows a dip/ridge in the grass. n/s/w/e_step != 0 means "neighbour
			# differs" (see _border_snap). Pass 0 (default build) = grass everywhere.
			var seam := (z == z0 and n_step != 0) or (z == z1 and s_step != 0) \
					 or (x == x0 and w_step != 0) or (x == x1 and e_step != 0)
			# .r = grass seam mask (0 on a LOD seam, else 1); .g = CANYON; .b = MEADOW; .a = MOUNTAINS.
			# mk was read above for the detail pass — masks cost noise lookups, once per vertex is enough.
			colors.append(Color(0.0, mk.x, mk.y, mk.z) if seam else Color(1.0, mk.x, mk.y, mk.z))

			# Finite-difference normal — uses step-wide neighbours so normals
			# remain smooth at lower LODs instead of having discontinuities. The same four
			# samples already served the slope above; re-reading them would double the cost of
			# the hottest loop in the build for nothing.
			normals.append(Vector3(hl0 - hr0 - dhx, 2.0 * sz, hu0 - hd0 - dhz).normalized())

			# Индекс вершины нигде не хранится: вершины пишутся строка за строкой, значит он
			# и так равен zi * xs.size() + xi — ровно так их и адресует сборка треугольников.
			# Прежний словарь стоил вставку на КАЖДУЮ вершину в самом горячем цикле сборки,
			# и ради арифметики, которая помещается в одну строку.

	# ── Triangles: FLAT AREAS ARE MERGED INTO BIG QUADS ───────────────────────
	# A canyon floor is dead flat and used to cost two triangles per METRE, for a surface that
	# a single quad describes exactly. This is greedy meshing, the same idea block-world
	# renderers use on their faces: walk the cells, and wherever a run of them is FLAT AT THE
	# SAME HEIGHT, emit one quad over the whole rectangle instead of two triangles per cell.
	#
	# WHY EXACT FLATNESS AND NOTHING ELSE. Dropping the vertices inside a merged rectangle is
	# only free if they were already lying on it. On a plateau they are — every corner has the
	# same height, so the interior samples sit exactly in the plane of the big quad and the
	# merge changes nothing at all, not even by a millimetre. Merge anything merely "gentle" and
	# the interior would be pulled onto a chord: the ground would visibly flatten, and worse, the
	# terrain would drift away from the collision, which is still cut from the raw heights.
	#
	# Flatness is judged on the FINAL vertex heights, after border snapping and after the visual
	# detail — so sand carrying ripples is never flat and never merges, which is exactly right.
	#
	# The chunk's OUTER RING is never merged: those vertices are the seam with the neighbour
	# (snapped to its grid), and every one of them has to stay in the mesh.
	var nx: int = xs.size()
	var nz: int = zs.size()
	var cells_x: int = nx - 1
	var cells_z: int = nz - 1
	var taken := PackedByteArray()
	taken.resize(cells_x * cells_z)
	for cz in cells_z:
		for cx in cells_x:
			if taken[cz * cells_x + cx] != 0:
				continue
			var i00: int = cz * nx + cx
			var i10: int = cz * nx + cx + 1
			var i01: int = (cz + 1) * nx + cx
			var i11: int = (cz + 1) * nx + cx + 1
			var edge: bool = cx == 0 or cz == 0 or cx == cells_x - 1 or cz == cells_z - 1
			var h0: float = vertices[i00].y
			if edge or not _cell_flat(vertices, nx, cx, cz, h0):
				indices.append_array([i00, i10, i11])
				indices.append_array([i00, i11, i01])
				continue
			# Grow right, then down — the plain greedy rectangle. Capped so one quad never
			# spans so much ground that the biome colour, which is per-vertex, visibly drifts
			# across it.
			var rw: int = 1
			while rw < MERGE_MAX and cx + rw < cells_x - 1 \
					and taken[cz * cells_x + cx + rw] == 0 \
					and _cell_flat(vertices, nx, cx + rw, cz, h0):
				rw += 1
			var rh: int = 1
			while rh < MERGE_MAX and cz + rh < cells_z - 1:
				var row_ok: bool = true
				for k in rw:
					if taken[(cz + rh) * cells_x + cx + k] != 0 \
							or not _cell_flat(vertices, nx, cx + k, cz + rh, h0):
						row_ok = false
						break
				if not row_ok:
					break
				rh += 1
			for jz in rh:
				for jx in rw:
					taken[(cz + jz) * cells_x + cx + jx] = 1
			var a: int = cz * nx + cx
			var b: int = cz * nx + cx + rw
			var c: int = (cz + rh) * nx + cx + rw
			var e: int = (cz + rh) * nx + cx
			indices.append_array([a, b, c])
			indices.append_array([a, c, e])


	if vertices.is_empty() or indices.is_empty():
		return []

	# ── Drop the vertices the merge left unused ───────────────────────────────
	# Inside a merged rectangle nothing points at the interior samples any more. Keeping them
	# would waste memory and upload bandwidth for geometry that draws nothing — and on a machine
	# where the rasteriser runs on the CPU, every vertex that survives is work somebody does.
	# One pass over the indices builds the remap, so this costs a fraction of what it saves.
	var remap := PackedInt32Array()
	remap.resize(vertices.size())
	remap.fill(-1)
	var kv := PackedVector3Array()
	var kn := PackedVector3Array()
	var ku := PackedVector2Array()
	var kc := PackedColorArray()
	for k in indices.size():
		var oi: int = indices[k]
		if remap[oi] < 0:
			remap[oi] = kv.size()
			kv.append(vertices[oi])
			kn.append(normals[oi])
			ku.append(uvs[oi])
			kc.append(colors[oi])
		indices[k] = remap[oi]
	vertices = kv
	normals = kn
	uvs = ku
	colors = kc

	var arr: Array = Array()
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = vertices
	arr[Mesh.ARRAY_INDEX]  = indices
	arr[Mesh.ARRAY_NORMAL] = normals
	arr[Mesh.ARRAY_TEX_UV] = uvs
	arr[Mesh.ARRAY_COLOR]  = colors
	return [arr, AABB(aabb_min, aabb_max - aabb_min)]

# ─────────────────────────────────────────────────────────────────────────────
# Material helpers
# ─────────────────────────────────────────────────────────────────────────────

# Duplicates the base material twice and bakes lod_grass_enabled into each copy.
# This is called once at chunk-build time. Subsequent LOD switches just swap
# which of these two material references an instance points to — zero per-instance
# shader-parameter slots consumed, so the GLES3 4096-slot buffer is never touched.
func _setup_lod_materials(base_mat: Material) -> void:
	if base_mat is ShaderMaterial:
		# Duplicate the base material: its appearance parameters (tile texture, blend,
		# tile_world_size, low_quality) carry over as they are. Only lod_grass_enabled differs
		# between the two copies; the biome colours are pushed in right after.
		_mat_lod0 = base_mat.duplicate()
		(_mat_lod0 as ShaderMaterial).set_shader_parameter("lod_grass_enabled", 1.0)
		_mat_lod_high = base_mat.duplicate()
		(_mat_lod_high as ShaderMaterial).set_shader_parameter("lod_grass_enabled", 0.0)
		_push_biomes_to_materials()      # colours and grass come from the biomes resource
	else:
		# StandardMaterial3D or unknown — no grass parameter, use same ref for both
		_mat_lod0    = base_mat
		_mat_lod_high = base_mat

# Called by grass.gd every frame. Grass only renders on the LOD0 (close) material, which is
# a private duplicate of the base — so the trample map MUST be set here, not on the base
# material grass.gd would otherwise find. tex = top-down flatten texture, center/size =
# the world-space window it covers (follows the camera).
func set_grass_trample(tex: Texture2D, center: Vector2, size: float) -> void:
	if _mat_lod0 is ShaderMaterial:
		var m := _mat_lod0 as ShaderMaterial
		m.set_shader_parameter("trample_map", tex)
		m.set_shader_parameter("trample_center", center)
		m.set_shader_parameter("trample_size", size)

# The corruption state map (maintained by grass.gd: empty at first, occasionally one more
# chunk, healed permanently near the player). Set on BOTH LOD materials, so the glitch shows at
# any distance.
func set_corruption_map(tex: Texture2D, center: Vector2, size: float) -> void:
	for m in [_mat_lod0, _mat_lod_high]:
		if m is ShaderMaterial:
			var sm := m as ShaderMaterial
			sm.set_shader_parameter("corrupt_map", tex)
			sm.set_shader_parameter("corrupt_world_center", center)
			sm.set_shader_parameter("corrupt_world_size", size)

func _get_material() -> Material:
	var mat: Material = null
	if mesh_instance.mesh != null and mesh_instance.mesh.get_surface_count() > 0:
		mat = mesh_instance.get_surface_override_material(0)
		if mat == null:
			mat = mesh_instance.mesh.surface_get_material(0)
	if mat == null and surface_material != null:
		mat = surface_material            # a fresh node gets the addon's terrain shader
	if mat == null:
		mat = StandardMaterial3D.new()
	return mat

# ─────────────────────────────────────────────────────────────────────────────
# Camera / frustum culling  (runtime only)
# ─────────────────────────────────────────────────────────────────────────────

# The camera currently in use: the manual override if set and valid, otherwise the viewport's
# active camera. get_viewport().get_camera_3d() always returns whichever camera the scene is
# being drawn with, including switches and spring arms, so nothing has to be found by path.
func _active_camera() -> Camera3D:
	if is_instance_valid(camera):
		return camera
	var vp := get_viewport()
	return vp.get_camera_3d() if vp != null else null

## GAME HOOK: приёмник замеров времени, `func(key: String, usec_start: int)`. Пока он пуст,
## замер выключен и не стоит ничего. Именно Callable, а не прямая ссылка на класс игры: аддон
## обязан работать в пустом проекте, где никакого профайлера нет.
var perf_sink: Callable = Callable()

func _pf_now() -> int:
	return Time.get_ticks_usec() if not perf_sink.is_null() else 0

func _pf_mark(key: String, t0: int) -> void:
	if t0 != 0 and not perf_sink.is_null():
		perf_sink.call(key, t0)

func _process(delta: float) -> void:
	if Engine.is_editor_hint():
		if editor_lod:
			_editor_lod_tick(delta)
		return

	# GAME HOOK: пометки для внешнего профайлера (см. perf_sink). Пока приёмник не задан,
	# _pf_now() возвращает ноль и всё это стоит одной проверки Callable на вызов.
	var _pf_all := _pf_now()

	# The active camera, refreshed every frame with nothing to assign by hand. It follows camera
	# switches, such as changing view on death or when moving between vehicles.
	_cam = _active_camera()

	# ── Streaming collision: keep tiled collision cells under the tracked bodies ──
	# Collision does not need a camera, so it updates even before an active one exists.
	if _col_active:
		var _pf := _pf_now()
		_update_collision_cells()
		_pf_mark("terrain.collision", _pf)

	# Everything below (chunk streaming, LOD, culling) depends on the camera.
	if _cam == null:
		_pf_mark("terrain", _pf_all)
		return

	# ── Background chunk streaming ────────────────────────────────────────────
	if _is_streaming:
		var _pf := _pf_now()
		_stream_tick(delta)
		_pf_mark("terrain.stream", _pf)

	# ── Quadtree frustum culling + LOD selection ──────────────────────────────
	# One descend from the root handles culling AND macro/chunk LOD; the heavier work
	# (per-chunk LOD reassignment + seam-stitch rebuilds) is throttled on top of that.
	_lod_timer += delta
	var do_lod := _lod_timer >= LOD_UPDATE_INTERVAL
	if do_lod:
		_lod_timer = 0.0
	# The descend walks the whole tree in GDScript and was the single most expensive thing the
	# terrain did per frame (2-3 ms measured). It does NOT have to run at frame rate: the
	# frustum test already carries a macro-sized margin, which is exactly the slack that covers
	# a frame or two of lag at the screen edge. So cap it at QT_MAX_HZ, and skip it entirely
	# while the camera is not moving — a still camera cannot change what is visible.
	# Streaming is the exception: during a load new chunks must be shown as they arrive.
	_qt_timer += delta
	var cam_pos: Vector3 = _cam.global_position
	var cam_fwd: Vector3 = -_cam.global_transform.basis.z
	var still: bool = cam_pos.distance_squared_to(_qt_last_pos) < QT_STILL_EPS2 \
			and cam_fwd.dot(_qt_last_fwd) > QT_STILL_COS
	if do_lod or _is_streaming or (_qt_timer >= 1.0 / QT_MAX_HZ and not still):
		_qt_timer = 0.0
		_qt_last_pos = cam_pos
		_qt_last_fwd = cam_fwd
		var _pf_qt := _pf_now()
		_qt_update(do_lod)
		_pf_mark("terrain.lod", _pf_qt)

	# ── Occlusion culling (throttled) ─────────────────────────────────────────
	if enable_occlusion_culling:
		_occlusion_timer += delta
		if _occlusion_timer >= OCCLUSION_UPDATE_INTERVAL:
			_occlusion_timer = 0.0
			var _pf_oc := _pf_now()
			_update_occlusion()
			_pf_mark("terrain.occl", _pf_oc)
	elif not (_occluded_chunks.is_empty() and _occluded_macros.is_empty() and _occluded_nodes.is_empty()):
		# Occlusion was just toggled off — restore full quadtree-based visibility
		_clear_occlusion()

	_pf_mark("terrain", _pf_all)

func _full_scan() -> void:
	# Initial selection: one stateless quadtree descend picks the first frame's
	# visible macros/chunks (and their LOD). Same call that runs every frame.
	_qt_cur_macros.clear()
	_qt_cur_chunks.clear()
	_qt_cur_nodes.clear()
	_qt_update(true)

# ─────────────────────────────────────────────────────────────────────────────
# Quadtree — frustum culling + LOD selection  (runtime only)
# ─────────────────────────────────────────────────────────────────────────────

# Builds the macro-grid quadtree. Leaves are existing macro groups (so the merged
# macro meshes are reused as-is); internal nodes just carry a merged AABB for
# hierarchical frustum/range pruning. Called once, after _build_macro_chunks().
func _build_quadtree() -> void:
	_qt_aabb.clear()
	_qt_child.clear()
	_qt_macro.clear()
	_qt_rect.clear()
	_qt_step.clear()
	_qt_size.clear()
	_qt_inst.clear()
	_qt_built = false
	if _macro_aabbs.is_empty():
		return
	var cxl := ceili(float(w - 1) / chunk_size)
	var czl := ceili(float(d - 1) / chunk_size)
	var macro_cx := ceili(float(cxl) / MACRO_SIZE)
	var macro_cz := ceili(float(czl) / MACRO_SIZE)
	if macro_cx <= 0 or macro_cz <= 0:
		return
	_qt_build_node(0, 0, macro_cx, macro_cz, macro_cx)
	# _qt_built is set only AT THE END, once every instance exists. There are awaits below (a
	# thread join plus batched add_child) and _process/_qt_update is gated on this flag —
	# otherwise it would walk a half-filled _qt_inst between frames.

	# ── Build each internal node's coarse merged mesh (threaded), then its instance ──
	var node_n := _qt_aabb.size()
	_qt_inst.resize(node_n)
	_qt_node_results.resize(node_n)
	var internal: Array[int] = []
	for n in node_n:
		if _qt_macro[n] < 0:
			internal.append(n)
	if not internal.is_empty():
		var node_task := func(i: int) -> void:
			_qt_node_worker(internal[i])
		var ngid := WorkerThreadPool.add_group_task(node_task, internal.size(), -1, true)
		while not WorkerThreadPool.is_group_task_completed(ngid):
			await get_tree().process_frame       # yield while the threads build the coarse node meshes
		WorkerThreadPool.wait_for_group_task_completion(ngid)   # immediate join
	var mat := _get_material()
	var made := 0
	for n in internal:
		var m: ArrayMesh = _qt_node_results[n]
		var inst := MeshInstance3D.new()
		inst.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		inst.visible     = false
		if m:
			inst.mesh = m
			inst.set_surface_override_material(0, _mat_lod_high if _mat_lod_high else mat)
		add_child(inst)
		_qt_inst[n] = inst
		# add_child creates a render instance and triggers tree entry, so hundreds of nodes in a
		# single frame is a noticeable hitch. Split into NODE_BATCH batches and yield between.
		made += 1
		if made % NODE_BATCH == 0:
			await get_tree().process_frame
	_qt_node_results.clear()
	_qt_built = not _qt_aabb.is_empty()

# Recursively builds a node covering the macro-grid rectangle
# [mx0, mx0+wsz) × [mz0, mz0+hsz). Splits the longer axis so nodes stay squarish.
# Returns the new node's id. Also records the node's cell rect / coarse-mesh step / world
# size, which the descend uses for LOD selection and the coarse-mesh build.
func _qt_build_node(mx0: int, mz0: int, wsz: int, hsz: int, macro_cx: int) -> int:
	var node_id := _qt_aabb.size()
	_qt_aabb.append(AABB())
	_qt_child.append([] as Array[int])
	_qt_macro.append(-1)
	# Cell rect of the whole node footprint (clamped to the heightmap edge).
	var rx0 := mx0 * MACRO_SIZE * chunk_size
	var rz0 := mz0 * MACRO_SIZE * chunk_size
	var rx1 := mini((mx0 + wsz) * MACRO_SIZE * chunk_size, w - 1)
	var rz1 := mini((mz0 + hsz) * MACRO_SIZE * chunk_size, d - 1)
	_qt_rect.append(Vector4i(rx0, rz0, rx1, rz1))
	# Step grows with node size → ~constant triangle budget per node regardless of level.
	# THE STEP MUST DIVIDE THE GRID, not just be big. A node's samples start at its rect
	# origin, which is a multiple of MACRO_SIZE * chunk_size; a finer neighbour snaps its border
	# vertices by assuming coarse samples sit at multiples of the step. Both hold only when the
	# step is a power of two no larger than that origin granularity — with a span of, say, three
	# macros the old formula gave step 24, the assumption broke, and the seam did not meet.
	# Rounding DOWN keeps a node slightly denser than it strictly needs to be: a root node goes
	# from ~64 quads to ~960, which is nothing, and in exchange every seam is exact.
	var span := maxi(wsz, hsz)
	var pow2 := 1
	while pow2 * 2 <= span:
		pow2 *= 2
	pow2 = mini(pow2, chunk_size / (1 << triangle_size))
	_qt_step.append(maxi(pow2, 1) * MACRO_SIZE * (1 << triangle_size))
	_qt_size.append(float(maxi(rx1 - rx0, rz1 - rz0)))

	if wsz <= 1 and hsz <= 1:
		var mi: int = mz0 * macro_cx + mx0
		_qt_macro[node_id] = mi
		_qt_aabb[node_id]  = _macro_aabbs[mi]
		return node_id

	var hw := (wsz + 1) >> 1
	var hh := (hsz + 1) >> 1
	var rects: Array = []
	if wsz > 1 and hsz > 1:
		rects = [[mx0, mz0, hw, hh], [mx0 + hw, mz0, wsz - hw, hh],
				 [mx0, mz0 + hh, hw, hsz - hh], [mx0 + hw, mz0 + hh, wsz - hw, hsz - hh]]
	elif wsz > 1:
		rects = [[mx0, mz0, hw, hsz], [mx0 + hw, mz0, wsz - hw, hsz]]
	else:
		rects = [[mx0, mz0, wsz, hh], [mx0, mz0 + hh, wsz, hsz - hh]]

	var children: Array[int] = []
	var box := AABB()
	var first := true
	for r in rects:
		if r[2] <= 0 or r[3] <= 0:
			continue
		var ch: int = _qt_build_node(r[0], r[1], r[2], r[3], macro_cx)
		children.append(ch)
		if first:
			box = _qt_aabb[ch]
			first = false
		else:
			box = box.merge(_qt_aabb[ch])
	_qt_child[node_id] = children
	_qt_aabb[node_id]  = box
	return node_id

# Threaded worker: builds internal node n's coarse merged mesh straight from the heightmap
# over its whole footprint, sampled at _qt_step[n].
func _qt_node_worker(n: int) -> void:
	var r: Vector4i = _qt_rect[n]
	# Plain build, no border flags: a node mesh is the COARSEST thing on any seam it takes part
	# in, so it never snaps to anyone — the finer side snaps to it, and that is now exact
	# because _qt_step is a power of two on the same grid (see above).
	var data := _compute_chunk_data(r.x, r.y, r.z, r.w, _qt_step[n])
	if data.is_empty():
		return
	var am := ArrayMesh.new()
	am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, data[0])
	_qt_node_results[n] = am

# Per-frame entry point: descend the tree to pick what renders, then diff the
# selection against what's currently shown. do_lod (throttled) also reassigns
# per-chunk LOD and rebuilds stale seam-stitched meshes.
func _qt_update(do_lod: bool) -> void:
	if not _qt_built or not _cam:
		return
	var frustum := _cam.get_frustum()
	var cam := _cam.global_position
	# Base slack (a macro half-footprint) so chunks don't pop at the screen edge.
	# frustum_margin tightens (<0) or loosens (>0) it as a ratio — the OLD formula
	# multiplied it by the camera's LOCAL XZ pos (≈0 on a spring arm), so it did nothing.
	var margin := chunk_size * MACRO_SIZE * 0.5 * (1.0 + frustum_margin)
	# Range cull: nodes whose nearest XZ point is past this are hidden without a
	# frustum test (fog hides them anyway). + a macro footprint of slack.
	var max_d := max_render_distance + chunk_size * MACRO_SIZE
	_qt_des_macros.clear()
	_qt_des_chunks.clear()
	_qt_des_nodes.clear()
	_qt_descend(0, frustum, cam, margin, max_d * max_d)
	_qt_apply(do_lod)
	# Free chunk nodes for macros the camera has left (throttled — runs with LOD).
	if do_lod:
		_qt_evict_far(cam)

func _qt_descend(node: int, frustum: Array[Plane], cam: Vector3, margin: float, max_d2: float) -> void:
	var world_aabb: AABB = global_transform * _qt_aabb[node]
	if _aabb_dist2(world_aabb, cam) > max_d2:
		return                                   # whole subtree beyond render range
	if enable_frustum_culling and not _aabb_in_frustum(world_aabb, frustum, margin):
		return                                   # whole subtree off-screen — never descended
	var mi: int = _qt_macro[node]
	if mi >= 0:
		# Leaf macro: far → render merged macro mesh; near → expand into individual chunks.
		var center := world_aabb.position + world_aabb.size * 0.5
		var dx := cam.x - center.x
		var dy := cam.y - center.y
		var dz := cam.z - center.z
		if dx * dx + dy * dy + dz * dz >= lod_distance_1 * lod_distance_1:
			_qt_des_macros[mi] = true
		else:
			_qt_expand_macro(mi, frustum, cam, margin, max_d2)
	else:
		# Internal node: if far enough that its coarse mesh is good enough, render it and
		# stop (one big low-poly mesh for the whole subtree). Otherwise descend for detail.
		# _aabb_dist2 уже возвращает КВАДРАТ; корень тут брался лишь ради сравнения, а порог
		# возвести в квадрат дешевле. Обход идёт по всем узлам дерева КАЖДЫЙ кадр, и строкой
		# выше (порог lod_distance_1) файл уже так и делает.
		var lim: float = _qt_size[node] * QT_QUALITY
		if _aabb_dist2(world_aabb, cam) >= lim * lim:
			_qt_des_nodes[node] = true
		else:
			for ch in _qt_child[node]:
				_qt_descend(ch, frustum, cam, margin, max_d2)

# A near macro renders as individual chunks. If its chunks aren't instantiated yet,
# request them (they stream in on background threads) and show the merged macro mesh in
# the meantime — no gap. Once resident, frustum/range-cull each chunk and pick its LOD.
func _qt_expand_macro(mi: int, frustum: Array[Plane], cam: Vector3, margin: float, max_d2: float) -> void:
	if not _resident_set.has(mi):
		_request_resident(mi)
		_qt_des_macros[mi] = true   # cover the region with the macro mesh until chunks arrive
		return
	for ci in _macro_to_chunks[mi]:
		if ci < 0 or ci >= _chunk_instances.size() or not _chunk_instances[ci]:
			continue
		var world_aabb: AABB = global_transform * _chunk_aabbs[ci]
		if _aabb_dist2(world_aabb, cam) > max_d2:
			continue
		if enable_frustum_culling and not _aabb_in_frustum(world_aabb, frustum, margin):
			continue
		var center := world_aabb.position + world_aabb.size * 0.5
		var dx := cam.x - center.x
		var dy := cam.y - center.y
		var dz := cam.z - center.z
		var lod := 0
		if enable_lod and dx * dx + dy * dy + dz * dz >= lod_distance_0 * lod_distance_0:
			lod = 1
		# A FLAT chunk can be drawn coarser even right under the camera: on level ground or an
		# even slope, large triangles follow the surface almost exactly at a quarter or a
		# sixteenth of the vertices. The error was measured back in phase 0.
		_qt_des_chunks[ci] = maxi(lod, _flat_lod(ci))

# Diffs the freshly-descended selection against what's currently rendered and toggles
# only the instances that changed. do_lod additionally commits per-chunk LOD and
# rebuilds any chunk whose seam-stitch signature went stale.
## Occlusion for the pieces that appear THIS pass. Everything else keeps the answer the
## throttled pass gave it; these have no answer at all yet, and "no answer" used to mean
## "visible" for up to a fifth of a second.
func _occlude_newcomers() -> void:
	if not enable_occlusion_culling or not _cam:
		return
	var cam_local: Vector3 = global_transform.affine_inverse() * _cam.global_position
	for ci in _qt_des_chunks:
		if _qt_cur_chunks.has(ci):
			continue
		if ci < _chunk_aabbs.size() and _is_aabb_occluded(_chunk_aabbs[ci], cam_local):
			_occluded_chunks[ci] = true
	for mi in _qt_des_macros:
		if _qt_cur_macros.has(mi):
			continue
		if mi < _macro_aabbs.size() and _is_aabb_occluded(_macro_aabbs[mi], cam_local):
			_occluded_macros[mi] = true
	for node in _qt_des_nodes:
		if _qt_cur_nodes.has(node):
			continue
		if node < _qt_aabb.size() and _is_aabb_occluded(_qt_aabb[node], cam_local):
			_occluded_nodes[node] = true

func _qt_apply(do_lod: bool) -> void:
	# Did the COARSE set change this pass? Chunk LOD only moves on a do_lod pass, but a node or
	# macro can appear between two of them, and the seam next to it is then unstitched until the
	# next one — up to 150 ms of open crack. There is no skirt to hide that any more, so a change
	# here forces the stitch pass below regardless of do_lod.
	var coarse_changed: bool = _qt_des_nodes.size() != _qt_cur_nodes.size() \
			or _qt_des_macros.size() != _qt_cur_macros.size()
	if not coarse_changed:
		for node in _qt_des_nodes:
			if not _qt_cur_nodes.has(node):
				coarse_changed = true
				break
	if not coarse_changed:
		for mi in _qt_des_macros:
			if not _qt_cur_macros.has(mi):
				coarse_changed = true
				break

	# NEWCOMERS ARE TESTED FOR OCCLUSION ON THE SPOT. The occlusion pass is throttled to a fifth
	# of a second, and until it runs a piece that just entered the view counts as "not occluded"
	# — so turning the camera showed a chunk behind a mountain and then took it away again. What
	# the player sees is geometry blinking into existence and vanishing, which reads as a bug
	# even though both states were "correct" at the time.
	#
	# Only what CHANGED is tested here, which is a handful of pieces per pass, not the world.
	_occlude_newcomers()

	# ── Coarse internal nodes (the far, low-poly representation) ───────────────
	for node in _qt_des_nodes:
		var ninst: MeshInstance3D = _qt_inst[node]
		if ninst:
			ninst.visible = not _occluded_nodes.has(node)   # far mesh hidden if behind terrain
	for node in _qt_cur_nodes:
		if not _qt_des_nodes.has(node):
			var ninst2: MeshInstance3D = _qt_inst[node]
			if ninst2:
				ninst2.visible = false
	_qt_cur_nodes = _qt_des_nodes.duplicate()

	# ── Macros ────────────────────────────────────────────────────────────────
	for mi in _qt_des_macros:
		if not _qt_cur_macros.has(mi):
			_macro_active[mi] = true
			# The macro now owns this region — hide any individual chunks under it.
			for ci in _macro_to_chunks[mi]:
				if ci >= 0 and ci < _chunk_instances.size() and _chunk_instances[ci]:
					_chunk_instances[ci].visible = false
				_qt_cur_chunks.erase(ci)
		_macro_instances[mi].visible = not _occluded_macros.has(mi)
	for mi in _qt_cur_macros:
		if not _qt_des_macros.has(mi):
			_macro_active[mi] = false
			_macro_instances[mi].visible = false
	_qt_cur_macros = _qt_des_macros.duplicate()

	# ── Chunks ────────────────────────────────────────────────────────────────
	if do_lod:
		for ci in _qt_des_chunks:
			_chunk_lod[ci] = _qt_des_chunks[ci]
	for ci in _qt_des_chunks:
		var inst: MeshInstance3D = _chunk_instances[ci]
		if inst:
			inst.visible = not _occluded_chunks.has(ci)
	for ci in _qt_cur_chunks:
		if not _qt_des_chunks.has(ci):
			if ci < _chunk_instances.size() and _chunk_instances[ci]:
				_chunk_instances[ci].visible = false
	_qt_cur_chunks = _qt_des_chunks.duplicate()

	# ── Seam-stitch rebuilds over the active chunk set only (throttled) ────────
	# _chunk_lod is now current for every visible chunk, so _stitch_signature reflects
	# neighbour LODs (including step=4 for chunks inside an active macro). Rebuild only
	# the chunks whose signature changed — usually none once the view settles.
	if do_lod or coarse_changed:
		var mat := _get_material()
		for ci in _qt_cur_chunks:
			if ci >= _chunk_instances.size() or not _chunk_instances[ci]:
				continue
			if _chunk_stitch_sig[ci] != _stitch_signature(ci):
				_apply_lod_mesh(ci, mat)

# The coarsest LOD a chunk's flatness allows. The threshold comes from flat_lod_error: the
# flatter the chunk, the larger the triangles it may use.
func _flat_lod(ci: int) -> int:
	if flat_lod_error <= 0.0 or ci < 0 or ci >= _chunk_flat_err.size():
		return 0
	var err := _chunk_flat_err[ci]
	if err <= flat_lod_error:
		return LOD_COUNT - 1          # effectively flat — the coarsest mesh
	if err <= flat_lod_error * 3.0:
		return 1                      # gentle relief — one step coarser
	return 0                          # broken up (a canyon or a mountainside) — full detail

# Squared distance from a point to an AABB in THREE dimensions (0 if the point is inside).
# Height counts as much as XZ: otherwise a camera directly above the map would have a
# horizontal distance near zero and pull the whole terrain in at full detail.
func _aabb_dist2(aabb: AABB, p: Vector3) -> float:
	var mn := aabb.position
	var mx := aabb.position + aabb.size
	var dx := maxf(maxf(mn.x - p.x, p.x - mx.x), 0.0)
	var dy := maxf(maxf(mn.y - p.y, p.y - mx.y), 0.0)
	var dz := maxf(maxf(mn.z - p.z, p.z - mx.z), 0.0)
	return dx * dx + dy * dy + dz * dz


# ── Chunk residency: stream individual chunks in/out as the camera moves ──────

# True once every (in-range) chunk of macro mi has been instantiated.
func _macro_all_present(mi: int) -> bool:
	for ci in _macro_to_chunks[mi]:
		if ci >= 0 and ci < _chunk_instances.size() and _chunk_instances[ci] == null:
			return false
	return true

# Queue macro mi's missing chunks for a background (re)build. Cheap and idempotent:
# already-present or already-queued chunks are skipped, so calling it every frame while
# the camera sits near a not-yet-resident macro costs almost nothing.
func _request_resident(mi: int) -> void:
	var added := false
	for ci in _macro_to_chunks[mi]:
		if ci < 0 or ci >= _chunk_instances.size():
			continue
		if _chunk_instances[ci] == null and not _queued_chunks.has(ci):
			_queued_chunks[ci] = true
			_stream_queue.append(ci)
			added = true
	if added:
		_is_streaming = true

# Free macro mi's individual chunk nodes + meshes. The macro mesh keeps covering the
# region, so nothing visually disappears — this just reclaims the memory.
func _evict_macro(mi: int) -> void:
	for ci in _macro_to_chunks[mi]:
		if ci < 0 or ci >= _chunk_instances.size():
			continue
		if _chunk_instances[ci]:
			_chunk_instances[ci].queue_free()
			_chunk_instances[ci] = null
		if ci < _chunk_meshes.size():
			_chunk_meshes[ci] = null
		_qt_cur_chunks.erase(ci)
		_queued_chunks.erase(ci)
	_resident_set.erase(mi)

# Evicts every resident macro whose centre is well beyond the expand ring. Iterates only
# the (small) resident set, and the QT_EVICT_MARGIN hysteresis stops a macro right at the
# boundary from thrashing load↔evict as the camera jitters.
func _qt_evict_far(cam: Vector3) -> void:
	if _resident_set.is_empty():
		return
	var evict_r  := lod_distance_1 + QT_EVICT_MARGIN
	var evict_d2 := evict_r * evict_r
	var to_evict: Array[int] = []
	for mi in _resident_set:
		var c := global_transform * _macro_aabbs[mi].get_center()
		var dx := cam.x - c.x
		var dz := cam.z - c.z
		if dx * dx + dz * dz > evict_d2:
			to_evict.append(mi)
	for mi in to_evict:
		_evict_macro(mi)

# ─────────────────────────────────────────────────────────────────────────────
# Software occlusion culling  (runtime only)
# ─────────────────────────────────────────────────────────────────────────────

# Periodic occlusion pass.  Iterates every frustum-visible chunk / active macro
# group, tests it with _is_aabb_occluded, and updates MeshInstance3D.visible
# only when the occluded/clear state flips (minimises property-write overhead).
#
# Results are stored in _occluded_chunks / _occluded_macros; frustum culling
# reads those dicts when it sets visibility, so the two systems cooperate without
# one overwriting the other's work.
func _update_occlusion() -> void:
	if not _cam:
		return

	# One affine_inverse per frame — all chunk AABBs live in local space
	var cam_local := global_transform.affine_inverse() * _cam.global_position

	var new_occ_chunks := {}
	var new_occ_macros  := {}
	var new_occ_nodes   := {}

	# ── Individual chunks ─────────────────────────────────────────────────────
	# When frustum culling is on, only test the quadtree's currently-visible chunks
	# (saves CPU). When off, iterate all because _qt_cur_chunks may be empty.
	var chunks_to_test: Array
	if enable_frustum_culling:
		chunks_to_test = _qt_cur_chunks.keys()
	else:
		chunks_to_test = range(_chunk_instances.size())

	for ci in chunks_to_test:
		if ci >= _chunk_aabbs.size():
			continue
		if not _chunk_instances[ci]:   # not yet streamed in
			continue
		# Chunks in an active macro group are covered by the macro test below
		if _chunk_macro_idx.size() > ci and _macro_active[_chunk_macro_idx[ci]]:
			continue
		if _is_aabb_occluded(_chunk_aabbs[ci], cam_local, _occluded_chunks.has(ci)):
			new_occ_chunks[ci] = true

	# ── Active macro groups ───────────────────────────────────────────────────
	for mi in _macro_instances.size():
		if not _macro_active[mi]:
			continue
		if _is_aabb_occluded(_macro_aabbs[mi], cam_local, _occluded_macros.has(mi)):
			new_occ_macros[mi] = true

	# ── Far coarse quadtree meshes ────────────────────────────────────────────
	# The far, low-poly representation behind a ridge was still being drawn; test it too.
	for node in _qt_cur_nodes:
		if node < _qt_aabb.size() and _is_aabb_occluded(_qt_aabb[node], cam_local, _occluded_nodes.has(node)):
			new_occ_nodes[node] = true

	# ── Apply visibility — only when the occluded/clear state changes ─────────
	for ci in chunks_to_test:
		if ci >= _chunk_instances.size():
			continue
		if not _chunk_instances[ci]:   # not yet streamed in
			continue
		if _chunk_macro_idx.size() > ci and _macro_active[_chunk_macro_idx[ci]]:
			continue
		var was := _occluded_chunks.has(ci)
		var now  := new_occ_chunks.has(ci)
		if was != now:
			var in_frustum := not enable_frustum_culling or _qt_cur_chunks.has(ci)
			_chunk_instances[ci].visible = in_frustum and not now

	for mi in _macro_instances.size():
		if not _macro_active[mi]:
			continue
		var was := _occluded_macros.has(mi)
		var now  := new_occ_macros.has(mi)
		if was != now:
			if enable_frustum_culling:
				# Re-confirm frustum: don't accidentally un-hide a macro outside the view
				var world_aabb := global_transform * _macro_aabbs[mi]
				var frustum    := _cam.get_frustum()
				var margin     := chunk_size * MACRO_SIZE * 0.5 * (1.0 + frustum_margin)
				_macro_instances[mi].visible = _aabb_in_frustum(world_aabb, frustum, margin) and not now
			else:
				_macro_instances[mi].visible = not now

	# Coarse nodes: flip visibility only when occluded/clear state changed (and the node
	# is still in view this frame — _qt_cur_nodes is the current rendered set).
	for node in _qt_cur_nodes:
		var was_n := _occluded_nodes.has(node)
		var now_n := new_occ_nodes.has(node)
		if was_n != now_n and node < _qt_inst.size() and _qt_inst[node]:
			_qt_inst[node].visible = not now_n

	_occluded_chunks = new_occ_chunks
	_occluded_macros = new_occ_macros
	_occluded_nodes  = new_occ_nodes

# Restores full frustum-based visibility for every previously-occluded object.
# Called once when enable_occlusion_culling is toggled off at runtime.
func _clear_occlusion() -> void:
	for ci in _occluded_chunks:
		if ci >= _chunk_instances.size():
			continue
		if not _chunk_instances[ci]:   # not yet streamed in
			continue
		if _chunk_macro_idx.size() > ci and _macro_active[_chunk_macro_idx[ci]]:
			continue
		_chunk_instances[ci].visible = _qt_cur_chunks.has(ci) or not enable_frustum_culling
	for mi in _occluded_macros:
		if mi >= _macro_instances.size() or not _macro_active[mi]:
			continue
		if enable_frustum_culling:
			var world_aabb := global_transform * _macro_aabbs[mi]
			var frustum    := _cam.get_frustum()
			var margin     := chunk_size * MACRO_SIZE * 0.5 * (1.0 + frustum_margin)
			_macro_instances[mi].visible = _aabb_in_frustum(world_aabb, frustum, margin)
		else:
			_macro_instances[mi].visible = true
	# Restore far coarse meshes that occlusion had hidden (only those still in the cut).
	for node in _occluded_nodes:
		if node < _qt_inst.size() and _qt_inst[node]:
			_qt_inst[node].visible = _qt_cur_nodes.has(node)
	_occluded_chunks.clear()
	_occluded_macros.clear()
	_occluded_nodes.clear()

# Returns true when the given local-space AABB is fully hidden behind terrain
# as seen from cam_local (also in local space).
#
# Algorithm — elevation angle / terrain horizon method:
#   Cast an XZ ray from the camera toward the chunk's AABB centre.
#   For each heightmap sample along the ray compute:
#       terrain_angle = atan2(terrain_height − cam_y, horizontal_dist)
#   Track max_terrain_angle across all samples.
#   Separately compute:
#       chunk_angle = atan2(aabb_top + occlusion_bias − cam_y, dist_to_chunk)
#   If max_terrain_angle > chunk_angle the terrain horizon is above the chunk
#   top → the chunk cannot be seen → return true.
#
# The occlusion_bias term raises the effective target so only terrain that
# clearly dominates the skyline triggers culling, reducing false-positives
# (popping) when the camera barely grazes a ridge.
## HYSTERESIS, in radians of horizon angle. Without a dead band a piece sitting exactly on the
## threshold flips on every occlusion pass — five times a second — and blinking geometry reads
## as a bug even though each individual answer is correct. Hiding something visible needs the
## terrain to clear its top by this much; showing something hidden needs it to fall below by the
## same amount, so the two thresholds cannot chase each other.
const OCCL_HYST: float = 0.012

func _is_aabb_occluded(aabb: AABB, cam_local: Vector3, was_occluded: bool = false) -> bool:
	# Guard: w must be positive and md must be populated before we read it.
	# md is refreshed by update_chunks() but w/d are @onready — they can
	# temporarily disagree with md.size() after a map resize.  Derive the
	# actual row-count from the live array so clampi stays within real bounds.
	var md_size: int = md.size()
	if md_size == 0 or w <= 0:
		return false
	var actual_d: int = md_size / w          # real depth regardless of stale d
	if actual_d <= 0:
		return false

	var center  := aabb.get_center()
	var dx      := center.x - cam_local.x
	var dz      := center.z - cam_local.z
	# Ранний выход считаем по КВАДРАТУ: ближние чанки отсеиваются здесь, и для них корень
	# не нужен вовсе. Дальше он всё-таки берётся — dist_xz идёт в формулу (шаг выборки и
	# угол к горизонту), а не в сравнение.
	var d2_xz := dx * dx + dz * dz
	if d2_xz < occlusion_min_dist * occlusion_min_dist:
		return false
	var dist_xz := sqrt(d2_xz)

	# Biased AABB top — the target elevation we try to see over
	var target_y := aabb.position.y + aabb.size.y + occlusion_bias

	# Camera already above chunk top → always visible from above
	if cam_local.y >= target_y:
		return false

	# Elevation angle from the camera to the (biased) chunk top
	var chunk_angle := atan2(target_y - cam_local.y, dist_xz)

	var inv_dist := 1.0 / dist_xz
	var dir_x    := dx * inv_dist
	var dir_z    := dz * inv_dist

	var max_terrain_angle := -PI * 0.5   # start maximally below the horizon

	# HOW MANY SAMPLES: by DISTANCE, not a fixed count. The heights themselves are exact — md is
	# the full-resolution map, one float per world unit, and no separate "picture" is involved —
	# but a fixed count spread the same samples over any ray length, so at 40 m it read the
	# ground every three metres and at 300 m every twenty. A ridge thinner than the gap is
	# stepped over, and the thing behind it is drawn for nothing.
	#
	# So: one sample per OCCLUSION_STRIDE metres, with occlusion_samples as the floor and four
	# times that as the ceiling. A missed ridge only costs a draw call; the opposite error would
	# cost a popping hole, and that is why the stride is small rather than clever.
	var steps: int = clampi(int(dist_xz / OCCLUSION_STRIDE), occlusion_samples, occlusion_samples * 4)

	# Sample at t ∈ [10 %, 90 %] of the distance so we skip the camera's own
	# foot and the chunk's own geometry, reading only the terrain between them.
	for si in range(1, steps):
		var t           := float(si) / float(steps) * 0.9
		var sample_dist := t * dist_xz

		var lx := cam_local.x + dir_x * sample_dist
		var lz := cam_local.z + dir_z * sample_dist

		# local coords → heightmap grid indices
		# Vertex formula: pos = Vector3(x − w*0.5 + 0.5, h, z − d*0.5 + 0.5)
		# Inverse: x = lx + w*0.5 − 0.5
		# Use actual_d (derived from md.size()) instead of cached d to avoid
		# stale-cache OOB when the map was resized after _ready().
		var hx  := clampi(int(round(lx + float(w)        * 0.5 - 0.5)), 0, w        - 1)
		var hz  := clampi(int(round(lz + float(actual_d) * 0.5 - 0.5)), 0, actual_d - 1)
		var idx: int = hz * w + hx
		# Final safety net — prevents any remaining edge-case OOB
		if idx < 0 or idx >= md_size:
			continue

		var terrain_h     := float(md[idx])
		var terrain_angle := atan2(terrain_h - cam_local.y, sample_dist)

		if terrain_angle > max_terrain_angle:
			max_terrain_angle = terrain_angle

	# Terrain horizon is above the chunk top → chunk is occluded (with the dead band above).
	return max_terrain_angle > chunk_angle + (-OCCL_HYST if was_occluded else OCCL_HYST)

## IS THIS POINT HIDDEN BY THE TERRAIN? The same horizon walk as the chunk test, exposed for
## everything else in the world: props, ore veins, loose blocks, machines.
##
## The reason it is public is fill rate. Terrain chunks are a few dozen objects; the props,
## veins and debris standing ON that terrain are hundreds, and every one of them behind a ridge
## is drawn in full. On a device where the rasterizer runs on the CPU that is the whole budget.
##
## height is how tall the thing is (its top is what has to clear the ridge), so a boulder does
## not get culled while its own peak is still in view. Cheap and conservative: on any doubt —
## no heightmap yet, camera above the object, too close — it answers "visible".
func is_point_hidden(world_pos: Vector3, height: float = 1.0, was_hidden: bool = false) -> bool:
	if not enable_occlusion_culling or md.is_empty() or not is_instance_valid(_cam):
		return false
	var inv: Transform3D = global_transform.affine_inverse()
	var local: Vector3 = inv * world_pos
	return _is_aabb_occluded(AABB(local - Vector3(0.5, 0.0, 0.5),
			Vector3(1.0, maxf(height, 0.1), 1.0)), inv * _cam.global_position, was_hidden)

func _aabb_in_frustum(aabb: AABB, frustum: Array[Plane], margin: float) -> bool:
	var bmin: Vector3 = aabb.position
	var bmax: Vector3 = aabb.position + aabb.size
	for plane in frustum:
		var nx: float = bmin.x if plane.normal.x >= 0.0 else bmax.x
		var ny: float = bmin.y if plane.normal.y >= 0.0 else bmax.y
		var nz: float = bmin.z if plane.normal.z >= 0.0 else bmax.z
		if plane.distance_to(Vector3(nx, ny, nz)) > margin:
			return false
	return true
