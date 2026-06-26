# map.gd
@tool
extends StaticBody3D

@export var camera: Camera3D
@export_range(-0.5, 0.5, 0.01) var frustum_margin: float = 0.05
@export var enable_frustum_culling: bool = true
## Run AABB frustum tests on worker threads — main thread never blocks.
## Results arrive with ~1 frame latency (imperceptible). Disable on platforms
## with unreliable WorkerThreadPool or for debugging.
@export var enable_threaded_frustum: bool = true

# ── Occlusion culling settings ────────────────────────────────────────────────
## Hide chunks whose AABB top sits below the terrain horizon seen from the camera.
## Uses the elevation-angle (horizon) method: samples the heightmap along the
## XZ ray from the camera to each chunk and tracks the maximum terrain angle.
## If the terrain horizon exceeds the angle to the chunk top, the chunk is occluded.
@export var enable_occlusion_culling: bool = true
## XZ distance (world units) below which chunks are never occlusion-culled.
## Keeps nearby chunks always visible regardless of geometry.
@export_range(0.0, 200.0, 1.0) var occlusion_min_dist: float = 40.0
## Added to the chunk AABB top before the horizon test.
## Raises the occluder bar so only clearly dominant ridges trigger culling;
## prevents popping when the camera nearly grazes a ridge line.
@export_range(0.0, 10.0, 0.5) var occlusion_bias: float = 1.5
## Heightmap samples taken along each camera→chunk ray.
## More samples = fewer missed occluders, more CPU cost.
@export_range(2, 24, 1) var occlusion_samples: int = 8

@export var chunk_size: int = 16

# ── LOD settings ─────────────────────────────────────────────────────────────
# Toggle LOD on/off without changing distances
@export var enable_lod: bool = true

# XZ distance thresholds (in world units) at which LOD switches:
#   dist < lod_distance_0  →  LOD 0  (step=1, full res, 512 tris/chunk)
#   dist < lod_distance_1  →  LOD 1  (step=2, ¼ tris, ~128/chunk)
#   dist < lod_distance_2  →  LOD 2  (step=4, 1/16 tris, ~32/chunk)
#   dist ≥ lod_distance_2  →  LOD 3  (step=8, 1/64 tris, ~8/chunk)
@export var lod_distance_0: float = 40.0
@export var lod_distance_1: float = 80.0
@export var lod_distance_2: float = 160.0

# Vertex sampling step per LOD level (index = LOD level)
const LOD_STEPS: Array[int] = [1, 2, 4, 8]
const LOD_COUNT: int        = 4

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

# ── Streaming settings ────────────────────────────────────────────────────────
## Chunks within this XZ radius (world units) are meshed immediately at startup.
## Chunks outside it are queued and streamed in during gameplay via _process().
@export_range(20.0, 500.0, 10.0) var stream_initial_radius: float = 100.0
## How many chunks are meshed per streaming batch. Lower = fewer frame hitches.
@export_range(4, 128, 4) var stream_batch_size: int = 32

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
@export_file("*.res", "*.exr", "*.png") var heightmap_path: String = "res://terrain_height.res"

## Master decoupling switch. ON = the R32F image is the ONLY heightmap source, in the
## editor AND at runtime; the giant HeightMapShape3D is never used for data, the editor
## sculpts by ray-marching the heightmap (no physics needed), and runtime always uses
## the streaming collision window. This is what lets the map grow huge — detach the big
## terrain.res/terrain_mesh.res from the scene (plugin button) and nothing heavy loads.
## OFF (default) = previous behaviour (embedded shape is data + collision).
@export var use_image_data: bool = false

# ── Streaming collision settings ──────────────────────────────────────────────
## Master switch. OFF (default) = current behaviour: the embedded HeightMapShape3D is
## both the data and the collision (whole map). ON = data comes from the R32F image and
## collision becomes a small window that follows the player — required for huge maps.
## NOTE while ON: only terrain inside the window has collision, so bodies far from the
## active vehicle (other parked vehicles, spread-out objects) sit on no ground. Size the
## window to cover your play area, or keep OFF until the map is genuinely large.
@export var enable_streaming_collision: bool = false
## Side length (in heightmap cells) of the small HeightMapShape3D that slides under
## the active vehicle. Physics cost is fixed at this size regardless of map size, so
## the map can grow arbitrarily without the collision body becoming "death" to load.
@export_range(32, 512, 16) var collision_window: int = 128
## Re-centre the collision window once the focus point has drifted this many cells
## from the window's last centre. Larger = fewer refills, smaller = tighter follow.
@export_range(8, 256, 8) var collision_update_margin: int = 32
## Every RigidBody3D under these node paths gets its OWN collision window that follows
## it, so the ground exists under all vehicles/objects — not only the active one. Empty
## or no bodies found → a single window follows the camera (old behaviour).
@export var collision_body_roots: Array[NodePath] = [NodePath("../Vehicles"), NodePath("../objects")]

@onready var collision     = $CollisionShape3D
@onready var mesh_instance = $MeshInstance3D

# ── Runtime chunk state ───────────────────────────────────────────────────────
var _chunk_instances: Array[MeshInstance3D] = []
var _chunk_aabbs:    Array[AABB]           = []

# _chunk_meshes[i][lod] → ArrayMesh (or null for degenerate chunks)
# Pre-built for all 4 LOD levels at startup; no runtime rebuild needed.
var _chunk_meshes:   Array = []

# Current LOD level that is actually displayed for each chunk
var _chunk_lod:      Array[int] = []

# Per-chunk "stitch signature": encodes the chunk's LOD step plus the snap step
# on each of its 4 borders (see _stitch_signature). _update_lod rebuilds a chunk
# whenever its current required signature differs from the one last applied, which
# makes seam stitching self-healing regardless of event order (LOD change, neighbour
# LOD change, macro toggle, streamed-in chunk). 0 = no mesh applied yet.
var _chunk_stitch_sig: Array[int] = []

var _chunks_x:      int = 0
var _visible_chunks: Dictionary = {}
var _frontier:       Dictionary = {}
var frustum_old
var _lod_timer:     float = 0.0

# ── Streaming collision runtime state ─────────────────────────────────────────
var _col_size:      int   = 0      # window side length (clamped to map size)
var _col_windows:   Array = []     # [{node:CollisionShape3D, body:Node3D|null, ox,oz,built}]
var _col_regather_t: float = 0.0   # timer for re-scanning tracked bodies

# ── Occlusion culling runtime state ──────────────────────────────────────────
const OCCLUSION_UPDATE_INTERVAL: float = 0.20   # seconds between full occlusion passes
var _occlusion_timer: float = 0.0
var _occluded_chunks: Dictionary = {}           # ci → true  (passed frustum, failed occlusion)
var _occluded_macros: Dictionary = {}           # mi → true

# ── Async frustum culling state (WorkerThreadPool) ────────────────────────────
# Pattern: main thread snapshots frustum+transform → workers test all AABBs in
# parallel → main thread applies visibility changes next frame.
# _chunk_aabbs must NOT be written while _ft_group_id ≥ 0 (update_chunks waits).
var _ft_snap_frustum: Array[Plane] = []         # captured on main thread, read-only by workers
var _ft_snap_gt:      Transform3D  = Transform3D()
var _ft_snap_margin:  float        = 0.0
var _ft_results:      PackedByteArray = PackedByteArray()  # 1=in frustum, 0=out
var _ft_group_id:     int          = -1         # -1 = no task in flight
var _ft_chunk_count:  int          = 0          # snapshot of _chunk_aabbs.size() at dispatch

# ── Streaming runtime state ───────────────────────────────────────────────────
# Chunks outside stream_initial_radius are queued here and built in background.
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
	if Engine.is_editor_hint():
		if use_image_data and _load_heightmap_image() != null:
			_load_heightmap()                   # editor data from the R32F image
		elif collision.shape is HeightMapShape3D:
			w  = collision.shape.map_width      # legacy: data from the embedded shape
			d  = collision.shape.map_depth
			md = collision.shape.map_data
		update()
		return
	mesh_instance.visible = false
	await get_tree().process_frame
	if not camera:
		camera = _find_game_camera()
	if use_image_data or enable_streaming_collision:
		_load_heightmap()                   # data from the R32F image (fallback: shape)
		_setup_streaming_collision()        # small sliding collision window
	else:
		# Legacy: the embedded HeightMapShape3D is both data and collision.
		w  = collision.shape.map_width
		d  = collision.shape.map_depth
		md = collision.shape.map_data
	_chunks_x = ceili(float(w - 1) / chunk_size)
	await _build_chunks_from_map_data()
	if camera:
		_full_scan()


# ─────────────────────────────────────────────────────────────────────────────
# Heightmap loading + streaming collision
# ─────────────────────────────────────────────────────────────────────────────

# Loads the master heightmap into w / d / md. Prefers the R32F image (scales to huge
# maps); falls back to the embedded HeightMapShape3D so the game still runs pre-bake.
func _load_heightmap() -> void:
	var img := _load_heightmap_image()
	if img != null:
		w  = img.get_width()
		d  = img.get_height()
		if img.get_format() != Image.FORMAT_RF:
			img.convert(Image.FORMAT_RF)
		md = img.get_data().to_float32_array()
		return
	# Fallback: read the heights out of the still-attached HeightMapShape3D.
	push_warning("map.gd: heightmap image not found at '%s' — using embedded CollisionShape3D data. Run 'Bake heightmap → image' in the Terraid3D dock for big-map streaming." % heightmap_path)
	if collision.shape is HeightMapShape3D:
		w  = collision.shape.map_width
		d  = collision.shape.map_depth
		md = collision.shape.map_data

func _load_heightmap_image() -> Image:
	if heightmap_path.is_empty() or not ResourceLoader.exists(heightmap_path):
		return null
	var res = load(heightmap_path)
	if res is Image:
		return res as Image
	if res is Texture2D:
		return (res as Texture2D).get_image()
	return null

# Creates one small HeightMapShape3D collision window per tracked body (every vehicle,
# and any RigidBody3D under collision_body_roots). Each window slides under its body, so
# the ground exists under ALL of them — not just the active one — at fixed physics cost.
func _setup_streaming_collision() -> void:
	if md.is_empty() or w <= 0 or d <= 0:
		return
	_col_size = mini(collision_window, mini(w, d))
	collision.disabled = true            # the scene's CollisionShape3D is unused at runtime
	_clear_collision_windows()
	_add_collision_window(null)          # always-on window under the camera / active vehicle
	var bodies := _gather_collision_bodies()
	for b in bodies:
		_add_collision_window(b)
	_update_collision_windows()

func _gather_collision_bodies() -> Array:
	var out := []
	for p in collision_body_roots:
		var root := get_node_or_null(p)
		if root == null:
			continue
		# Non-recursive: one window per top-level body (a vehicle), not per sub-block —
		# the window is large enough to cover the whole vehicle (wheels, etc.).
		for n in root.find_children("*", "RigidBody3D", false, false):
			if not out.has(n):
				out.append(n)
	# Robust fallback: if the configured roots found nothing (e.g. paths not set on this
	# scene), scan the whole scene and take every TOP-LEVEL RigidBody3D (skip blocks that
	# are nested under another body, and anything under the map itself).
	if out.is_empty():
		var scene_root := get_tree().current_scene
		if scene_root != null:
			for n in scene_root.find_children("*", "RigidBody3D", true, false):
				if is_ancestor_of(n):
					continue
				if _top_rigidbody(n) != n:
					continue
				if not out.has(n):
					out.append(n)
	return out

# Highest RigidBody3D in n's ancestor chain, or n itself if none above it.
func _top_rigidbody(n: Node) -> Node:
	var top: Node = n
	var p := n.get_parent()
	while p != null:
		if p is RigidBody3D:
			top = p
		p = p.get_parent()
	return top

func _add_collision_window(body: Node3D) -> void:
	var cs := CollisionShape3D.new()
	var shape := HeightMapShape3D.new()
	shape.map_width  = _col_size
	shape.map_depth  = _col_size
	cs.shape = shape
	add_child(cs)
	_col_windows.append({"node": cs, "body": body, "ox": 0, "oz": 0, "built": false})

func _clear_collision_windows() -> void:
	for win in _col_windows:
		if is_instance_valid(win["node"]):
			win["node"].queue_free()
	_col_windows.clear()

# Each frame: re-centre any window whose body has drifted past collision_update_margin,
# and periodically re-scan so newly built / removed bodies get / drop their own window.
func _update_collision_windows() -> void:
	if _col_size <= 0 or md.is_empty():
		return
	for win in _col_windows:
		var body = win["body"]
		var focus: Vector3
		if body != null and is_instance_valid(body):
			focus = body.global_position
		elif camera:
			focus = camera.global_position
		else:
			continue
		var local := global_transform.affine_inverse() * focus
		var fx := int(round(local.x + float(w) * 0.5 - 0.5))
		var fz := int(round(local.z + float(d) * 0.5 - 0.5))
		var ox := clampi(fx - _col_size / 2, 0, maxi(0, w - _col_size))
		var oz := clampi(fz - _col_size / 2, 0, maxi(0, d - _col_size))
		if win["built"] and absi(ox - win["ox"]) < collision_update_margin \
					   and absi(oz - win["oz"]) < collision_update_margin:
			continue
		_fill_collision_window(win["node"], ox, oz)
		win["ox"] = ox
		win["oz"] = oz
		win["built"] = true

func _regather_collision_bodies() -> void:
	if _col_size <= 0:
		return
	var bodies := _gather_collision_bodies()
	var kept := []
	var have := {}
	for win in _col_windows:
		var b = win["body"]
		if b == null:
			kept.append(win)                       # keep the camera fallback window
		elif is_instance_valid(b) and bodies.has(b):
			kept.append(win)
			have[b] = true
		elif is_instance_valid(win["node"]):
			win["node"].queue_free()               # body gone → drop its window
	_col_windows = kept
	for b in bodies:
		if not have.has(b):
			_add_collision_window(b)

func _fill_collision_window(node: CollisionShape3D, ox: int, oz: int) -> void:
	var W := _col_size
	var data := PackedFloat32Array()
	data.resize(W * W)
	for j in W:
		var srow := (oz + j) * w + ox
		var drow := j * W
		for i in W:
			data[drow + i] = md[srow + i]
	var shape: HeightMapShape3D = node.shape
	shape.map_data = data
	# Offset the node so window cell (i,j) lands on the same local position as the visual
	# mesh's master cell (ox+i, oz+j):  node.x = ox + (W - w) * 0.5  (see vertex formula).
	node.position = Vector3(ox + float(W - w) * 0.5, 0.0, oz + float(W - d) * 0.5)


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
		if not Engine.is_editor_hint() and _col_size > 0:
			for win in _col_windows:       # heights changed → force every window to refill
				win["built"] = false
			_update_collision_windows()
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
	var h0 = lerp(md[z0 * w + x0], md[z0 * w + x1], fx)
	var h1 = lerp(md[z1 * w + x0], md[z1 * w + x1], fx)
	return lerp(h0, h1, fz)

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
	var prev_gap := o.y - _sample_height_local(o.x, o.z)
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
	var avg := 0.0
	if mode == 0:
		var cnt := 0
		for z in range(z_min, z_max + 1):
			for x in range(x_min, x_max + 1):
				if Vector2(x - cx, z - cz).length() <= radius:
					avg += md[z * w + x]
					cnt += 1
		if cnt > 0:
			avg /= float(cnt)
	for z in range(z_min, z_max + 1):
		for x in range(x_min, x_max + 1):
			var dist := Vector2(x - cx, z - cz).length()
			if dist > radius:
				continue
			var falloff := 1.0 - dist / radius
			var idx := z * w + x
			if mode == 0:
				md[idx] = lerp(md[idx], avg, falloff * strength * 5.0)
			else:
				md[idx] += float(mode) * strength * falloff
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
	# If a frustum task is in flight it holds read references to _chunk_aabbs.
	# Wait for it to finish before we write new AABB data (avoids data race).
	if _ft_group_id >= 0:
		WorkerThreadPool.wait_for_group_task_completion(_ft_group_id)
		_ft_group_id = -1
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
	var mat  = _get_material()
	var cxl  = ceili(float(w - 1) / chunk_size)
	var dirty_macros := {}   # macro group indices that need their mesh rebuilt

	for ci in chunk_indices:
		if ci < 0 or ci >= _chunk_instances.size():
			continue
		if not _chunk_instances[ci]:   # skip chunks not yet streamed in
			continue
		var cx_l = ci % cxl
		var cz_l = ci / cxl
		var x0 = cx_l * chunk_size
		var z0 = cz_l * chunk_size
		var x1 = mini(x0 + chunk_size, w - 1)
		var z1 = mini(z0 + chunk_size, d - 1)

		var lod_meshes: Array = []
		for lod in LOD_COUNT:
			var data = _compute_chunk_data(x0, z0, x1, z1, LOD_STEPS[lod])
			if data.is_empty():
				lod_meshes.append(null)
				continue
			var am = ArrayMesh.new()
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
			var cur_lod = _chunk_lod[ci] if ci < _chunk_lod.size() else 0
			var display_mesh = _best_available_mesh(lod_meshes, cur_lod)
			if display_mesh:
				_chunk_instances[ci].mesh = display_mesh
				_chunk_instances[ci].set_surface_override_material(0, mat)

	# Rebuild merged meshes for every macro group that had a sub-chunk change
	for mi in dirty_macros:
		var macro_mesh := _build_macro_mesh(_macro_to_chunks[mi], 2)
		if macro_mesh:
			_macro_instances[mi].mesh = macro_mesh
			_macro_instances[mi].set_surface_override_material(0, mat)

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
	for cz in _ed_cz:
		for cx in _ed_cx:
			_ed_cache[cz * _ed_cx + cx] = _chunk_surface_arrays(cx, cz)
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
	if pos.distance_to(_editor_track_pos) > 2.0:
		_editor_track_pos = pos
		_editor_settle_t  = 0.0
		return
	_editor_settle_t += delta
	if _editor_settle_t >= 0.35 \
			and _editor_track_pos.distance_to(_editor_build_pos) > float(chunk_size) * 0.5:
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
			var dist := sqrt(dx * dx + dz * dz)
			var lod := 0
			if dist >= lod_distance_2:   lod = 3
			elif dist >= lod_distance_1: lod = 2
			elif dist >= lod_distance_0: lod = 1
			_ed_lod[cz * _ed_cx + cx] = lod
	for cz in _ed_cz:
		for cx in _ed_cx:
			_ed_cache[cz * _ed_cx + cx] = _chunk_surface_arrays_lod(cx, cz)
	_apply_editor_cache()
	_editor_build_pos = cam_pos

# Editor LOD step of the neighbour chunk, or 1 at the map edge (so no snap is forced).
func _ed_neighbour_step(cx: int, cz: int, dcx: int, dcz: int) -> int:
	var nx := cx + dcx
	var nz := cz + dcz
	if nx < 0 or nx >= _ed_cx or nz < 0 or nz >= _ed_cz:
		return 1
	return LOD_STEPS[_ed_lod[nz * _ed_cx + nx]]

# Builds chunk (cx,cz)'s surface arrays at its editor LOD, snapping borders toward any
# coarser neighbour (same anti-crack stitching as runtime).
func _chunk_surface_arrays_lod(cx: int, cz: int) -> Array:
	var ci := cz * _ed_cx + cx
	var step := LOD_STEPS[_ed_lod[ci]]
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

# Editor full-res chunk arrays (used when editor_lod is OFF).
func _chunk_surface_arrays(cx: int, cz: int) -> Array:
	var x0 = cx * chunk_size
	var z0 = cz * chunk_size
	var x1 = mini(x0 + chunk_size, w - 1)
	var z1 = mini(z0 + chunk_size, d - 1)
	var res = _compute_chunk_data(x0, z0, x1, z1, 1)
	return [] if res.is_empty() else res[0]

func _apply_editor_cache() -> void:
	var mat = _get_material()

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
				all_colors.append(Color(1.0, 1.0, 1.0, 1.0))
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
#   Mesh data generated in parallel across all CPU cores for chunks within
#   stream_initial_radius. Same thread-safety contract as before: reads md/w/d
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

	# ── Phase 0: parallel AABB scan for ALL chunks ────────────────────────────
	# Only reads heightmap extremes — no mesh generation, very fast even on
	# huge maps. Fills _chunk_aabbs so frustum/macro/occlusion work correctly
	# from the very first frame for every chunk, including not-yet-meshed ones.
	var aabb_task := func(ci: int) -> void:
		var cx := ci % cxl;  var cz := ci / cxl
		var x0 := cx * chunk_size;  var x1 := mini(x0 + chunk_size, w - 1)
		var z0 := cz * chunk_size;  var z1 := mini(z0 + chunk_size, d - 1)
		var min_h := INF;  var max_h := -INF
		for zz in range(z0, z1 + 1):
			for xx in range(x0, x1 + 1):
				var h := float(md[zz * w + xx])
				if h < min_h: min_h = h
				if h > max_h: max_h = h
		if min_h == INF:
			return
		_chunk_aabbs[ci] = AABB(
			Vector3(x0 - float(w) * 0.5 + 0.5, min_h, z0 - float(d) * 0.5 + 0.5),
			Vector3(x1 - x0, max_h - min_h, z1 - z0))
	var aabb_gid := WorkerThreadPool.add_group_task(aabb_task, total, -1, true)
	WorkerThreadPool.wait_for_group_task_completion(aabb_gid)

	# ── Sort all chunks by XZ distance from camera ────────────────────────────
	var cam_pos := camera.global_position if camera else Vector3.ZERO
	var sorted  := range(total)
	sorted.sort_custom(func(a: int, b: int) -> bool:
		var ax := (a % cxl + 0.5) * chunk_size - float(w) * 0.5
		var az := (a / cxl + 0.5) * chunk_size - float(d) * 0.5
		var bx := (b % cxl + 0.5) * chunk_size - float(w) * 0.5
		var bz := (b / cxl + 0.5) * chunk_size - float(d) * 0.5
		return (ax - cam_pos.x) * (ax - cam_pos.x) + (az - cam_pos.z) * (az - cam_pos.z) \
			 < (bx - cam_pos.x) * (bx - cam_pos.x) + (bz - cam_pos.z) * (bz - cam_pos.z))

	# ── Split: immediate (near camera) vs deferred (stream later) ────────────
	var initial: Array[int] = []
	var r2 := stream_initial_radius * stream_initial_radius
	for ci in sorted:
		var ax = (ci % cxl + 0.5) * chunk_size - float(w) * 0.5
		var az = (ci / cxl + 0.5) * chunk_size - float(d) * 0.5
		if (ax - cam_pos.x) * (ax - cam_pos.x) + (az - cam_pos.z) * (az - cam_pos.z) <= r2:
			initial.append(ci)
		else:
			_stream_queue.append(ci)

	# ── Phase 1: parallel full mesh build for initial (near-camera) chunks ────
	if not initial.is_empty():
		var build_task := func(i: int) -> void:
			_build_chunk_worker(initial[i], cxl)
		var gid := WorkerThreadPool.add_group_task(build_task, initial.size(), -1, true)
		WorkerThreadPool.wait_for_group_task_completion(gid)

	# ── Phase 2: create nodes on the main thread ──────────────────────────────
	var mat := _get_material()
	if _mat_lod0 == null:
		_setup_lod_materials(mat)
	_apply_built_results(initial, mat)

	# Macro system already knows all AABBs from Phase 0, so the group structure
	# is built for the full map. Unbuilt chunks contribute no geometry yet
	# (_build_macro_mesh guards for null meshes); their macro meshes are rebuilt
	# incrementally as _stream_apply_batch fills them in.
	_build_macro_chunks()

	_is_streaming = not _stream_queue.is_empty()


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
		var data := _compute_chunk_data(x0, z0, x1, z1, LOD_STEPS[lod])
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
# MUST run on the main thread — adds nodes to the scene tree.
# Also classifies each new chunk into _visible_chunks or _frontier based on the
# current camera frustum, so it integrates seamlessly into the culling system.
func _apply_built_results(indices: Array, mat: Material) -> void:
	for ci in indices:
		if _stream_results[ci] == null:
			continue
		var lod_meshes: Array = _stream_results[ci][0]
		var first_aabb: AABB  = _stream_results[ci][1]
		_stream_results[ci]   = null

		var inst := MeshInstance3D.new()
		inst.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		inst.visible     = false
		add_child(inst)
		_chunk_instances[ci] = inst   # fill the pre-allocated slot
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

		if camera and enable_frustum_culling:
			var frustum := camera.get_frustum()
			var margin  := frustum_margin * (camera.position * Vector3(1, 0, 1)).length() + chunk_size
			# A chunk inside an already-active macro group must stay hidden — the merged
			# macro MeshInstance3D owns rendering for that region. This case happens for
			# far chunks streamed in AFTER their group collapsed into a macro. Showing the
			# individual instance here would double-render it AND strand it: _ft_apply's
			# newly-hidden path skips the .visible write for macro chunks, so once it left
			# the frustum it could never be hidden again. Track frustum state regardless,
			# so visibility is restored correctly if the macro later deactivates.
			var in_active_macro: bool = _chunk_macro_idx.size() > ci and _macro_active[_chunk_macro_idx[ci]]
			if _aabb_in_frustum(global_transform * first_aabb, frustum, margin):
				_visible_chunks[ci] = true
				inst.visible = not in_active_macro and not _occluded_chunks.has(ci)
			else:
				_frontier[ci] = true
				inst.visible = false
		else:
			inst.visible = false


# ─────────────────────────────────────────────────────────────────────────────
# LOD update  (runtime only)
# Runs every LOD_UPDATE_INTERVAL seconds.
#
# Step 1 — macro decision: any group whose XZ centre is ≥ lod_distance_1 from
#   the camera collapses into one merged mesh (no shadow casts, 1 draw call).
# Step 2 — individual LOD: close chunks (dist < lod_distance_1) switch between
#   LOD 0 (full res) and LOD 1 (¼ res) only.  LOD 2/3 is the macro system's job.
func _update_lod() -> void:
	if not camera:
		return

	var cam_pos := camera.global_position
	var mat     := _get_material()

	# ── Step 1: macro vs individual per group ─────────────────────────────────
	for mi in _macro_instances.size():
		var center     := global_transform * _macro_aabbs[mi].get_center()
		var dx         := cam_pos.x - center.x
		var dz         := cam_pos.z - center.z
		var dist       := sqrt(dx * dx + dz * dz)
		var want_macro := dist >= lod_distance_1
		if want_macro != _macro_active[mi]:
			_set_macro_mode(mi, want_macro)

	# ── Step 2: per-chunk target LOD ──────────────────────────────────────────
	# Update every built, non-macro chunk's LOD (do NOT skip frustum-culled chunks —
	# off-screen state must stay correct so a chunk re-entering the view never shows a
	# stale, un-stitched mesh). Step 3's signature pass below picks up these LOD changes
	# and re-stitches every affected seam, including macro-group boundaries.
	for i in _chunk_instances.size():
		if not _chunk_instances[i]:   # not yet streamed in
			continue
		if _chunk_macro_idx.size() > i and _macro_active[_chunk_macro_idx[i]]:
			continue
		var center     := global_transform * _chunk_aabbs[i].get_center()
		var dx         := cam_pos.x - center.x
		var dz         := cam_pos.z - center.z
		var dist       := sqrt(dx * dx + dz * dz)
		_chunk_lod[i] = 1 if dist >= lod_distance_0 else 0

	# ── Step 3: rebuild every chunk whose stitch signature is now stale ────────
	# Self-healing seam stitching: a chunk's mesh is fully determined by its LOD plus
	# the snap step on each of its 4 borders (_stitch_signature). Rebuild whenever the
	# required signature differs from the one last applied. This catches EVERY cause of
	# a stale seam — the chunk's own LOD change, a neighbour's LOD change, a macro group
	# toggling, or a chunk newly streamed in — no matter the order events happened in,
	# so a T-junction crack can never persist. After things settle the signatures match
	# and nothing is rebuilt, so the steady-state cost is just the cheap comparison.
	for i in _chunk_instances.size():
		if not _chunk_instances[i]:
			continue
		if _chunk_macro_idx.size() > i and _macro_active[_chunk_macro_idx[i]]:
			continue   # individual mesh is hidden; the macro instance renders this region
		if _chunk_stitch_sig[i] != _stitch_signature(i):
			_apply_lod_mesh(i, mat)


# Applies the correct mesh to chunk ci, rebuilding with border snapping when
# the chunk is at LOD 0 and any neighbour is at a coarser step.
func _apply_lod_mesh(ci: int, mat: Material) -> void:
	if ci >= _chunk_lod.size() or ci >= _chunk_instances.size() or ci >= _chunk_meshes.size():
		return   # chunk index out of range
	if not _chunk_instances[ci]:
		return   # chunk not yet streamed in
	var target_lod := _chunk_lod[ci]
	var my_step    := LOD_STEPS[target_lod]
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

	# Record the signature of the mesh we are about to apply, so _update_lod can tell
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
# the same signature produce byte-identical meshes, so _update_lod only rebuilds when
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
	var my_step := LOD_STEPS[_chunk_lod[ci]]
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
	var ni := _get_chunk_idx(cx + dcx, cz + dcz)
	if ni < 0 or ni >= _chunk_lod.size():
		return 1   # map boundary or not-yet-built chunk — no snap
	if _chunk_macro_idx.size() > ni and _macro_active[_chunk_macro_idx[ni]]:
		return LOD_STEPS[2]   # macro group uses LOD-2 step (= 4)
	return LOD_STEPS[_chunk_lod[ni]]

# Returns the mesh at `preferred_lod`, falling back to the next finer LOD
# if the preferred one happens to be null (tiny edge-chunks may skip coarse LODs).
func _best_available_mesh(lod_meshes: Array, preferred_lod: int) -> ArrayMesh:
	var lod = preferred_lod
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

	for mz in _macro_cz:
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

			# Build merged LOD-2 mesh: step=4 → ~32 tris/chunk, negligible cost.
			# Unbuilt chunks contribute no geometry (_build_macro_mesh guards for null).
			var macro_mesh := _build_macro_mesh(c_list, 2)
			var inst       := MeshInstance3D.new()
			inst.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			inst.visible     = false   # activated by _set_macro_mode() only
			if macro_mesh:
				inst.mesh = macro_mesh
				inst.set_surface_override_material(0, mat)
			add_child(inst)
			_macro_instances.append(inst)


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
				all_colors.append(Color(1.0, 1.0, 1.0, 1.0))
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


# Switches macro-group mi between merged (active=true) and individual rendering.
#   active=true  → hide 16 individual instances, show 1 merged (no shadows)
#   active=false → hide merged, restore individual visibility from frustum state
func _set_macro_mode(mi: int, active: bool) -> void:
	_macro_active[mi] = active
	if active:
		for ci in _macro_to_chunks[mi]:
			if not _chunk_instances[ci]:   # not yet streamed in
				continue
			_chunk_instances[ci].visible = false
		# Frustum validity is confirmed each frame by _update_macro_visibility()
		_macro_instances[mi].visible = true
	else:
		_macro_instances[mi].visible = false
		# Restore each chunk's last-known frustum visibility (also respect occlusion)
		for ci in _macro_to_chunks[mi]:
			if not _chunk_instances[ci]:   # not yet streamed in
				continue
			_chunk_instances[ci].visible = _visible_chunks.has(ci) and not _occluded_chunks.has(ci)


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
	# Frustum workers read _chunk_aabbs concurrently. Join before any writes
	# to shared chunk data — mirrors the same guard in update_chunks().
	if _ft_group_id >= 0:
		WorkerThreadPool.wait_for_group_task_completion(_ft_group_id)
		_ft_group_id = -1
		_ft_apply()

	var mat := _get_material()
	_apply_built_results(_stream_batch, mat)

	# Rebuild merged meshes for macro groups that just received new chunks
	var dirty_macros := {}
	for ci in _stream_batch:
		if _chunk_macro_idx.size() > ci:
			dirty_macros[_chunk_macro_idx[ci]] = true
	for mi in dirty_macros:
		if mi >= _macro_instances.size():
			continue
		var macro_mesh := _build_macro_mesh(_macro_to_chunks[mi], 2)
		if macro_mesh:
			_macro_instances[mi].mesh = macro_mesh
			_macro_instances[mi].set_surface_override_material(0, mat)

	# Seam-stitch each freshly-streamed chunk against its already-present neighbours.
	# The stream queue is distance-sorted only once at startup, so as the player moves
	# a fine (close) chunk can arrive AFTER its coarse (far) neighbour has already
	# settled at a higher LOD. _update_lod stitches only on LOD transitions, so it would
	# miss this fine chunk (it never changes LOD), leaving a permanent T-junction crack.
	# _apply_lod_mesh snaps it now toward any coarser neighbour; it's a no-op otherwise
	# and adds no geometry.
	for ci in _stream_batch:
		if ci < 0 or ci >= _chunk_instances.size() or not _chunk_instances[ci]:
			continue
		if _chunk_macro_idx.size() > ci and _macro_active[_chunk_macro_idx[ci]]:
			continue
		_apply_lod_mesh(ci, mat)

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
	var result = PackedInt32Array()
	var pos    = start
	while pos < end:
		result.append(pos)
		pos += step
	# Always include the boundary (avoids duplicate if step divides evenly)
	if result.is_empty() or result[result.size() - 1] != end:
		result.append(end)
	return result

# Returns [surface_arrays, AABB], or [] for a degenerate chunk.
# `step` controls LOD resolution:
#   step=1 → every vertex (LOD 0, full quality)
#   step=2 → every other vertex (LOD 1, ~4× fewer triangles)
#   step=4 → every 4th vertex  (LOD 2, ~16× fewer triangles)
#   step=8 → every 8th vertex  (LOD 3, ~64× fewer triangles)
# n/s/w/e_step: LOD step of the neighbour on that edge.
# When neighbour_step > step, border vertices that fall between the neighbour's
# sample positions are linearly interpolated so both meshes share the same
# height along the seam — eliminating T-junction cracks.
# Pass 0 (default) for edges that need no stitching.
func _compute_chunk_data(x0: int, z0: int, x1: int, z1: int, step: int = 1,
		n_step: int = 0, s_step: int = 0,
		w_step: int = 0, e_step: int = 0) -> Array:
	var vertices  = PackedVector3Array()
	var indices   = PackedInt32Array()
	var normals   = PackedVector3Array()
	var uvs       = PackedVector2Array()
	var colors    = PackedColorArray()   # .r = grass mask: 0 on chunk borders, 1 inside
	var local_idx = {}
	var idx       = 0
	var aabb_min  = Vector3(INF,  INF,  INF)
	var aabb_max  = Vector3(-INF, -INF, -INF)

	var sz = maxi(1, step)
	var xs = _sample_range(x0, x1, sz)
	var zs = _sample_range(z0, z1, sz)

	# ── Vertices ──────────────────────────────────────────────────────────────
	for z in zs:
		for x in xs:
			var h = float(md[z * w + x])

			# ── Border snapping ───────────────────────────────────────────────
			# If this vertex is on an edge adjacent to a coarser-LOD chunk and
			# its position is not on the coarser grid, snap its height to the
			# linear interpolation of the two coarser neighbours.
			# Guarantee: chunk_size=16 is divisible by all possible steps (1,2,4,8),
			# so x0/z0 are always aligned with the neighbour grid — no clamping needed.

			# North border (z == z0): snap x to n_step grid
			if z == z0 and n_step > step:
				var rem: int = x % n_step
				if rem != 0:
					h = lerp(float(md[z * w + x - rem]),
							 float(md[z * w + x - rem + n_step]),
							 float(rem) / float(n_step))

			# South border (z == z1): snap x to s_step grid
			elif z == z1 and s_step > step:
				var rem: int = x % s_step
				if rem != 0:
					h = lerp(float(md[z * w + x - rem]),
							 float(md[z * w + x - rem + s_step]),
							 float(rem) / float(s_step))

			# West border (x == x0): snap z to w_step grid
			if x == x0 and w_step > step:
				var rem: int = z % w_step
				if rem != 0:
					h = lerp(float(md[(z - rem) * w + x]),
							 float(md[(z - rem + w_step) * w + x]),
							 float(rem) / float(w_step))

			# East border (x == x1): snap z to e_step grid
			elif x == x1 and e_step > step:
				var rem: int = z % e_step
				if rem != 0:
					h = lerp(float(md[(z - rem) * w + x]),
							 float(md[(z - rem + e_step) * w + x]),
							 float(rem) / float(e_step))

			var pos = Vector3(x - w * 0.5 + 0.5, h, z - d * 0.5 + 0.5)
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
			colors.append(Color(0.0, 0.0, 0.0, 1.0) if seam else Color(1.0, 1.0, 1.0, 1.0))

			# Finite-difference normal — uses step-wide neighbours so normals
			# remain smooth at lower LODs instead of having discontinuities.
			var hl = md[z * w + maxi(x - sz, 0)]
			var hr = md[z * w + mini(x + sz, w - 1)]
			var hu = md[maxi(z - sz, 0) * w + x]
			var hd = md[mini(z + sz, d - 1) * w + x]
			normals.append(Vector3(hl - hr, 2.0 * sz, hu - hd).normalized())

			local_idx[z * w + x] = idx
			idx += 1

	# ── Triangles ─────────────────────────────────────────────────────────────
	# Iterate over the sample-position arrays — no manual index arithmetic,
	# so we always connect exactly the vertices we generated above.
	for zi in range(zs.size() - 1):
		for xi in range(xs.size() - 1):
			var i00 = local_idx.get(zs[zi]     * w + xs[xi],     -1)
			var i10 = local_idx.get(zs[zi]     * w + xs[xi + 1], -1)
			var i01 = local_idx.get(zs[zi + 1] * w + xs[xi],     -1)
			var i11 = local_idx.get(zs[zi + 1] * w + xs[xi + 1], -1)
			if i00 < 0 or i10 < 0 or i01 < 0 or i11 < 0:
				continue
			indices.append_array([i00, i10, i11])
			indices.append_array([i00, i11, i01])

	if vertices.is_empty() or indices.is_empty():
		return []

	var arr = Array()
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
		_mat_lod0 = base_mat.duplicate()
		(_mat_lod0 as ShaderMaterial).set_shader_parameter("lod_grass_enabled", 1.0)
		_mat_lod_high = base_mat.duplicate()
		(_mat_lod_high as ShaderMaterial).set_shader_parameter("lod_grass_enabled", 0.0)
	else:
		# StandardMaterial3D or unknown — no grass parameter, use same ref for both
		_mat_lod0    = base_mat
		_mat_lod_high = base_mat

func _get_material() -> Material:
	var mat: Material = null
	if mesh_instance.mesh != null and mesh_instance.mesh.get_surface_count() > 0:
		mat = mesh_instance.get_surface_override_material(0)
		if mat == null:
			mat = mesh_instance.mesh.surface_get_material(0)
	if mat == null:
		mat = StandardMaterial3D.new()
	return mat


# ─────────────────────────────────────────────────────────────────────────────
# Camera / frustum culling  (runtime only)
# ─────────────────────────────────────────────────────────────────────────────

func _find_game_camera() -> Camera3D:
	for node in get_tree().root.find_children("*", "Camera3D", true, false):
		var cam = node as Camera3D
		if cam and cam.current:
			return cam
	return null

func _process(delta: float) -> void:
	if Engine.is_editor_hint():
		if editor_lod:
			_editor_lod_tick(delta)
		return
	if not camera:
		camera = _find_game_camera()
		return

	# ── Streaming collision: keep a physics window under every tracked body ───
	if _col_size > 0:
		_update_collision_windows()
		_col_regather_t += delta
		if _col_regather_t >= 1.0:        # re-scan for new/removed bodies once a second
			_col_regather_t = 0.0
			_regather_collision_bodies()

	# ── Background chunk streaming ────────────────────────────────────────────
	if _is_streaming:
		_stream_tick(delta)

	# ── Frustum culling ───────────────────────────────────────────────────────
	if enable_frustum_culling:
		if enable_threaded_frustum:
			# ── Async path ────────────────────────────────────────────────────
			# Step 1: if the previous task just finished, apply its results.
			if _ft_group_id >= 0 and WorkerThreadPool.is_group_task_completed(_ft_group_id):
				WorkerThreadPool.wait_for_group_task_completion(_ft_group_id)  # join (instant)
				_ft_group_id = -1
				_ft_apply()
			# Step 2: dispatch next task if none is in flight.
			# (If the previous task hasn't finished yet we simply reuse
			#  _visible_chunks from the last applied frame — zero stall.)
			if _ft_group_id < 0:
				_ft_dispatch()
		else:
			# ── Sync fallback ─────────────────────────────────────────────────
			# Drain any leftover async task before switching to sync mode.
			if _ft_group_id >= 0:
				WorkerThreadPool.wait_for_group_task_completion(_ft_group_id)
				_ft_group_id = -1
			_update_chunk_visibility()
		# Macro visibility: few AABBs, stays on main thread every frame
		_update_macro_visibility()
	else:
		# No frustum culling — show everything while still respecting macro mode and occlusion
		for i in _chunk_instances.size():
			if not _chunk_instances[i]:   # not yet streamed in
				continue
			var in_macro := _chunk_macro_idx.size() > i and _macro_active[_chunk_macro_idx[i]]
			_chunk_instances[i].visible = not in_macro and not _occluded_chunks.has(i)
		for mi in _macro_instances.size():
			_macro_instances[mi].visible = _macro_active[mi] and not _occluded_macros.has(mi)

	# ── Occlusion culling (throttled) ─────────────────────────────────────────
	if enable_occlusion_culling:
		_occlusion_timer += delta
		if _occlusion_timer >= OCCLUSION_UPDATE_INTERVAL:
			_occlusion_timer = 0.0
			_update_occlusion()
	elif not (_occluded_chunks.is_empty() and _occluded_macros.is_empty()):
		# Occlusion was just toggled off — restore full frustum-based visibility
		_clear_occlusion()

	# ── LOD update (throttled) ────────────────────────────────────────────────
	if enable_lod:
		_lod_timer += delta
		if _lod_timer >= LOD_UPDATE_INTERVAL:
			_lod_timer = 0.0
			_update_lod()

func _full_scan() -> void:
	# Cancel any in-flight async task before we rebuild _visible_chunks from scratch.
	if _ft_group_id >= 0:
		WorkerThreadPool.wait_for_group_task_completion(_ft_group_id)
		_ft_group_id = -1
	_visible_chunks.clear()
	_frontier.clear()

	if enable_threaded_frustum and camera and not _chunk_aabbs.is_empty():
		# Dispatch and wait synchronously — called once at startup, blocking is OK here.
		_ft_dispatch()
		if _ft_group_id >= 0:
			WorkerThreadPool.wait_for_group_task_completion(_ft_group_id)
			_ft_group_id = -1
			_ft_apply()
	else:
		# Original single-threaded path (fallback / no camera yet)
		if not camera:
			return
		var frustum := camera.get_frustum()
		var margin  := frustum_margin * (camera.position * Vector3(1, 0, 1)).length() + chunk_size
		for i in _chunk_instances.size():
			if not _chunk_instances[i]:   # not yet streamed in
				continue
			var world_aabb := global_transform * _chunk_aabbs[i]
			if _aabb_in_frustum(world_aabb, frustum, margin):
				_chunk_instances[i].visible = not _occluded_chunks.has(i)
				_visible_chunks[i] = true
			else:
				_chunk_instances[i].visible = false
		for i in _visible_chunks:
			for nb in _get_neighbors(i):
				if not _visible_chunks.has(nb):
					_frontier[nb] = true


# ─────────────────────────────────────────────────────────────────────────────
# Async frustum culling  —  WorkerThreadPool
# ─────────────────────────────────────────────────────────────────────────────

# Snapshot current camera state on the main thread and kick off a group task.
# Workers read _chunk_aabbs[] (read-only) and _ft_snap_frustum (read-only).
# Writes only to distinct indices of _ft_results (PackedByteArray, thread-safe).
func _ft_dispatch() -> void:
	if not camera or _chunk_aabbs.is_empty():
		return

	var new_frustum := camera.get_frustum()
	# Skip dispatch if the camera hasn't moved — results would be identical.
	if new_frustum == _ft_snap_frustum:
		return

	_ft_chunk_count  = _chunk_aabbs.size()
	_ft_snap_frustum = new_frustum          # fresh Array[Plane], kept alive by member var
	_ft_snap_gt      = global_transform
	_ft_snap_margin  = frustum_margin * (camera.position * Vector3(1, 0, 1)).length() \
					   + chunk_size
	_ft_results.resize(_ft_chunk_count)

	# Each worker call gets its own index (0…_ft_chunk_count-1).
	# bind() appends the extra args after the system-provided index.
	_ft_group_id = WorkerThreadPool.add_group_task(
			_ft_worker.bind(_ft_snap_gt, _ft_snap_frustum, _ft_snap_margin),
			_ft_chunk_count, -1, true, "frustum_cull")


# Worker — executes on a WorkerThreadPool thread.
# MUST be pure math: no scene-tree, no node property writes, no GDScript Mutex.
# Reads: _chunk_aabbs (read-only during task lifetime), bound args (read-only).
# Writes: _ft_results[idx] — each thread writes to its own unique index only.
func _ft_worker(idx: int, gt: Transform3D, frustum: Array[Plane], margin: float) -> void:
	if idx >= _chunk_aabbs.size():
		_ft_results[idx] = 0
		return
	var world_aabb := gt * _chunk_aabbs[idx]
	_ft_results[idx] = 1 if _aabb_in_frustum(world_aabb, frustum, margin) else 0


# Apply the completed task's results on the main thread.
# Mirrors the newly-visible / newly-hidden logic of _update_chunk_visibility.
func _ft_apply() -> void:
	var n := mini(_ft_results.size(), _chunk_instances.size())
	if n == 0:
		return

	var newly_visible: Array[int] = []
	var newly_hidden:  Array[int] = []

	for i in n:
		var in_frustum := _ft_results[i] != 0
		if in_frustum and not _visible_chunks.has(i):
			newly_visible.append(i)
		elif not in_frustum and _visible_chunks.has(i):
			newly_hidden.append(i)

	for i in newly_visible:
		_visible_chunks[i] = true
		_frontier.erase(i)
		if _chunk_macro_idx.size() <= i or not _macro_active[_chunk_macro_idx[i]]:
			if _chunk_instances[i]:   # guard: chunk may not be streamed in yet
				_chunk_instances[i].visible = not _occluded_chunks.has(i)
		for nb in _get_neighbors(i):
			if not _visible_chunks.has(nb):
				_frontier[nb] = true

	for i in newly_hidden:
		_visible_chunks.erase(i)
		_frontier[i] = true
		# Always hide — safe in both individual and macro modes (mirrors the sync
		# path in _update_chunk_visibility). Guarding this behind the macro check
		# could strand a chunk visible if it was ever shown while its macro was active.
		if _chunk_instances[i]:   # guard: chunk may not be streamed in yet
			_chunk_instances[i].visible = false
		for nb in _get_neighbors(i):
			if not _visible_chunks.has(nb):
				var has_vis := false
				for nnb in _get_neighbors(nb):
					if _visible_chunks.has(nnb):
						has_vis = true
						break
				if not has_vis:
					_frontier.erase(nb)


func _update_chunk_visibility() -> void:
	var frustum = camera.get_frustum()
	if frustum_old == frustum:
		return
	frustum_old = frustum
	var margin = frustum_margin * (camera.position * Vector3(1, 0, 1)).distance_to(Vector3.ZERO) + chunk_size

	var newly_visible = []
	var newly_hidden  = []

	for i in _frontier:
		if i >= _chunk_aabbs.size():
			continue
		var world_aabb = global_transform * _chunk_aabbs[i]
		if _aabb_in_frustum(world_aabb, frustum, margin):
			newly_visible.append(i)

	for i in _visible_chunks:
		if i >= _chunk_aabbs.size():
			continue
		var world_aabb = global_transform * _chunk_aabbs[i]
		if not _aabb_in_frustum(world_aabb, frustum, margin):
			newly_hidden.append(i)

	for i in newly_visible:
		_visible_chunks[i] = true
		_frontier.erase(i)
		# Don't show individual instances that belong to an active macro group —
		# the macro MeshInstance3D owns rendering for that region.
		if _chunk_macro_idx.size() <= i or not _macro_active[_chunk_macro_idx[i]]:
			if _chunk_instances[i]:   # guard: chunk may not be streamed in yet
				_chunk_instances[i].visible = not _occluded_chunks.has(i)
		for n in _get_neighbors(i):
			if not _visible_chunks.has(n):
				_frontier[n] = true

	for i in newly_hidden:
		if _chunk_instances[i]:   # guard: chunk may not be streamed in yet
			_chunk_instances[i].visible = false   # safe in both individual & macro modes
		_visible_chunks.erase(i)
		_frontier[i] = true
		for n in _get_neighbors(i):
			if not _visible_chunks.has(n):
				var has_visible_neighbor = false
				for nn in _get_neighbors(n):
					if _visible_chunks.has(nn):
						has_visible_neighbor = true
						break
				if not has_visible_neighbor:
					_frontier.erase(n)


# Frustum-culls macro instances independently of the individual-chunk frontier.
# One AABB check per group replaces 16 individual checks for far-away terrain.
# Called only when enable_frustum_culling is true (see _process).
func _update_macro_visibility() -> void:
	if _macro_instances.is_empty():
		return
	var frustum := camera.get_frustum()
	# Margin scaled to the macro group's XZ footprint so large groups aren't
	# clipped too aggressively near the frustum edge.
	var margin  := frustum_margin * (camera.position * Vector3(1, 0, 1)).distance_to(Vector3.ZERO) \
				   + chunk_size * MACRO_SIZE * 0.5
	for mi in _macro_instances.size():
		if not _macro_active[mi]:
			continue
		var world_aabb := global_transform * _macro_aabbs[mi]
		_macro_instances[mi].visible = _aabb_in_frustum(world_aabb, frustum, margin) \
				and not _occluded_macros.has(mi)


func _get_neighbors(i: int) -> Array:
	var neighbors = []
	var total = _chunk_instances.size()
	var cz = i / _chunks_x
	var cx = i % _chunks_x
	if cx > 0:                            neighbors.append(i - 1)
	if cx < _chunks_x - 1:               neighbors.append(i + 1)
	if cz > 0:                            neighbors.append(i - _chunks_x)
	if cz < (total / _chunks_x) - 1:     neighbors.append(i + _chunks_x)
	return neighbors


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
	if not camera:
		return

	# One affine_inverse per frame — all chunk AABBs live in local space
	var cam_local := global_transform.affine_inverse() * camera.global_position

	var new_occ_chunks := {}
	var new_occ_macros  := {}

	# ── Individual chunks ─────────────────────────────────────────────────────
	# When frustum culling is on, only test visible chunks (saves CPU).
	# When off, iterate all because _visible_chunks may be empty.
	var chunks_to_test: Array
	if enable_frustum_culling:
		chunks_to_test = _visible_chunks.keys()
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
		if _is_aabb_occluded(_chunk_aabbs[ci], cam_local):
			new_occ_chunks[ci] = true

	# ── Active macro groups ───────────────────────────────────────────────────
	for mi in _macro_instances.size():
		if not _macro_active[mi]:
			continue
		if _is_aabb_occluded(_macro_aabbs[mi], cam_local):
			new_occ_macros[mi] = true

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
			var in_frustum := not enable_frustum_culling or _visible_chunks.has(ci)
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
				var frustum    := camera.get_frustum()
				var margin     := frustum_margin * \
						(camera.position * Vector3(1, 0, 1)).distance_to(Vector3.ZERO) \
						+ chunk_size * MACRO_SIZE * 0.5
				_macro_instances[mi].visible = _aabb_in_frustum(world_aabb, frustum, margin) and not now
			else:
				_macro_instances[mi].visible = not now

	_occluded_chunks = new_occ_chunks
	_occluded_macros = new_occ_macros


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
		_chunk_instances[ci].visible = _visible_chunks.has(ci) or not enable_frustum_culling
	for mi in _occluded_macros:
		if mi >= _macro_instances.size() or not _macro_active[mi]:
			continue
		if enable_frustum_culling:
			var world_aabb := global_transform * _macro_aabbs[mi]
			var frustum    := camera.get_frustum()
			var margin     := frustum_margin * \
					(camera.position * Vector3(1, 0, 1)).distance_to(Vector3.ZERO) \
					+ chunk_size * MACRO_SIZE * 0.5
			_macro_instances[mi].visible = _aabb_in_frustum(world_aabb, frustum, margin)
		else:
			_macro_instances[mi].visible = true
	_occluded_chunks.clear()
	_occluded_macros.clear()


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
func _is_aabb_occluded(aabb: AABB, cam_local: Vector3) -> bool:
	# Guard: w must be positive and md must be populated before we read it.
	# md is refreshed by update_chunks() but w/d are @onready — they can
	# temporarily disagree with md.size() after a map resize.  Derive the
	# actual row-count from the live array so clampi stays within real bounds.
	var md_size = md.size()
	if md_size == 0 or w <= 0:
		return false
	var actual_d = md_size / w          # real depth regardless of stale d
	if actual_d <= 0:
		return false

	var center  := aabb.get_center()
	var dx      := center.x - cam_local.x
	var dz      := center.z - cam_local.z
	var dist_xz := sqrt(dx * dx + dz * dz)

	if dist_xz < occlusion_min_dist:
		return false

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

	# Sample at t ∈ [10 %, 90 %] of the distance so we skip the camera's own
	# foot and the chunk's own geometry, reading only the terrain between them.
	for si in range(1, occlusion_samples):
		var t           := float(si) / float(occlusion_samples) * 0.9
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
		var idx = hz * w + hx
		# Final safety net — prevents any remaining edge-case OOB
		if idx < 0 or idx >= md_size:
			continue

		var terrain_h     := float(md[idx])
		var terrain_angle := atan2(terrain_h - cam_local.y, sample_dist)

		if terrain_angle > max_terrain_angle:
			max_terrain_angle = terrain_angle

	# Terrain horizon is above the chunk top → chunk is occluded
	return max_terrain_angle > chunk_angle


func _aabb_in_frustum(aabb: AABB, frustum: Array[Plane], margin: float) -> bool:
	var bmin = aabb.position
	var bmax = aabb.position + aabb.size
	for plane in frustum:
		var nx = bmin.x if plane.normal.x >= 0.0 else bmax.x
		var ny = bmin.y if plane.normal.y >= 0.0 else bmax.y
		var nz = bmin.z if plane.normal.z >= 0.0 else bmax.z
		if plane.distance_to(Vector3(nx, ny, nz)) > margin:
			return false
	return true
