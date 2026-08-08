extends Node3D
# Раскидывает пропы 3D-художника ПО БИОМАМ и стримит их (как жилы руды): все пропы — лишь
# данные (позиция+сцена), а ноды создаются только для БЛИЖНИХ (render_distance), дальние не
# грузят систему. Художнику достаточно: положить ноду ребёнком карты (map/terrain), заполнить
# biome_props в инспекторе (для каждого биома — свои сцены + count) — и всё расставится само.
#
# Биом в точке определяется ТЕМИ ЖЕ формулами, что в шейдере террейна (glsl.gdshader): смотри,
# чтобы параметры ниже совпадали с параметрами МАТЕРИАЛА (по умолчанию совпадают).

const ANY := 0
const SAND := 1
const GRASS := 2
const CANYON := 3
const SNOW := 4

@export var biome_props: Array[BiomePropSet] = []

@export_group("Размещение")
@export var edge_margin: float = 48.0        # отступ от края карты
@export var min_height: float = 2.0          # ниже — вода/пляж, не ставим
@export var max_slope: float = 6.0           # круче — скала, пропы не ставим (разброс высот вокруг)

@export_group("Стриминг")
@export var render_distance: float = 220.0   # рендерятся/активны только пропы в этом радиусе
@export var max_visible: int = 260           # потолок одновременно отрисованных
@export var cull_interval: float = 0.3

## Параметры БИОМА — держать синхронно с материалом террейна (glsl.gdshader → group Biomes/Terrain).
@export_group("Биом (синхронно с шейдером)")
@export var height_grass_start: float = 20.0
@export var height_snow_start: float = 70.0
@export var zone_blend: float = 5.0
@export var biome_scale: float = 230.0
@export var biome_blend: float = 0.07
@export var biome_grass_bias: float = 0.5
@export var biome_contrast: float = 1.8
@export var canyon_scale: float = 250.0
@export var canyon_threshold: float = 0.70
@export var canyon_edge: float = 0.05
@export var mtn_scale: float = 420.0
@export var mtn_threshold: float = 0.72
@export var mtn_edge: float = 0.05

var _data: Array = []                        # [{pos, scene, scale, yaw, node}]
var _cull_t: float = 0.0
var _shown: int = 0

func _ready() -> void:
	var map: Node = get_parent()
	if map == null or not map.has_method("terrain_height_at") or not map.has_method("get_dims"):
		push_error("BiomeScatter: родитель должен быть картой (terrain_height_at/get_dims). Достался: %s тип %s скрипт %s" % [
				"null" if map == null else map.name,
				"-" if map == null else map.get_class(),
				"нет" if map == null or map.get_script() == null else map.get_script().resource_path])
		return
	var guard: int = 0
	while map.get_dims().x <= 0 and guard < 300:
		await get_tree().process_frame
		guard += 1
	if map.get_dims().x <= 0:
		return
	await _place(map, map.get_dims())      # расстановка уступает кадры (см. PLACE_BATCH)
	_cull_t = 0.0

# ── Биом в мировой точке (зеркалит шейдер) ────────────────────────────────────
func _fract(x: float) -> float:
	return x - floor(x)

func _hash2d(p: Vector2) -> float:
	p = Vector2(_fract(p.x * 123.34), _fract(p.y * 456.21))
	var d: float = p.dot(p + Vector2(45.32, 45.32))
	p += Vector2(d, d)
	return _fract(p.x * p.y)

func _vnoise(p: Vector2) -> float:
	var i := Vector2(floor(p.x), floor(p.y))
	var f := p - i
	f = f * f * (Vector2(3.0, 3.0) - 2.0 * f)
	var a := _hash2d(i)
	var b := _hash2d(i + Vector2(1.0, 0.0))
	var c := _hash2d(i + Vector2(0.0, 1.0))
	var d := _hash2d(i + Vector2(1.0, 1.0))
	return lerpf(lerpf(a, b, f.x), lerpf(c, d, f.x), f.y)

func _ss(a: float, b: float, x: float) -> float:
	return smoothstep(a, b, x)

func _biome_at(wx: float, wz: float, wy: float) -> int:
	# Биом ЧИСТО по региону (шум), на любой высоте — воды/снега-по-высоте нет (см. glsl.gdshader).
	# Порядок как в шейдере (верхний слой побеждает): ГОРЫ(снег) → КАНЬОН → трава/песок.
	var mtn := _ss(mtn_threshold - mtn_edge, mtn_threshold + mtn_edge,
			_vnoise(Vector2(wx, wz) / mtn_scale + Vector2(211.0, 77.0)))
	if mtn > 0.5:
		return SNOW
	var canyon := _ss(canyon_threshold - canyon_edge, canyon_threshold + canyon_edge,
			_vnoise(Vector2(wx, wz) / canyon_scale + Vector2(101.0, 53.0)))
	if canyon > 0.5:
		return CANYON
	var bn := _vnoise(Vector2(wx, wz) / biome_scale)
	bn = clampf((bn - 0.5) * biome_contrast + 0.5, 0.0, 1.0)
	return GRASS if _ss(biome_grass_bias - biome_blend, biome_grass_bias + biome_blend, bn) > 0.5 else SAND

# ── Расстановка: для каждого набора набираем count точек в его биоме ───────────
func _place(map: Node, dims: Vector2i) -> void:
	var half_x: float = dims.x * 0.5 - edge_margin
	var half_z: float = dims.y * 0.5 - edge_margin
	for setp in biome_props:
		if setp == null or setp.scenes.is_empty():
			continue
		var placed: Array = []
		var attempts: int = setp.count * 12
		var grid: Dictionary = {}
		var cell: float = maxf(setp.min_spacing, 0.001)
		var since_yield: int = 0
		while placed.size() < setp.count and attempts > 0:
			attempts -= 1
			since_yield += 1
			if since_yield >= PLACE_BATCH:
				since_yield = 0
				await get_tree().process_frame
			var lx: float = randf_range(-half_x, half_x)
			var lz: float = randf_range(-half_z, half_z)
			var world: Vector3 = map.global_transform * Vector3(lx, 0.0, lz)
			var h: float = map.terrain_height_at(world)
			if h < min_height:
				continue
			if _slope_at(map, lx, lz) > max_slope:
				continue
			if int(setp.biome) != ANY and _biome_at(world.x, world.z, h) != int(setp.biome):
				continue
			var local_pos: Vector3 = to_local(Vector3(world.x, h + setp.y_offset, world.z))
			if _too_close_hashed(grid, cell, local_pos, setp.min_spacing):
				continue
			placed.append(local_pos)
			var key := Vector2i(floori(local_pos.x / cell), floori(local_pos.z / cell))
			if not grid.has(key):
				grid[key] = [] as Array[Vector3]
			(grid[key] as Array).append(local_pos)
			_data.append({
				"pos": local_pos,
				"scene": setp.scenes.pick_random(),
				"scale": randf_range(setp.min_scale, setp.max_scale),
				"yaw": randf() * TAU if setp.random_yaw else 0.0,
				"node": null,
			})

func _slope_at(map: Node, lx: float, lz: float) -> float:
	var s: float = 3.0
	var h1: float = map.terrain_height_at(map.global_transform * Vector3(lx + s, 0.0, lz))
	var h2: float = map.terrain_height_at(map.global_transform * Vector3(lx - s, 0.0, lz))
	var h3: float = map.terrain_height_at(map.global_transform * Vector3(lx, 0.0, lz + s))
	var h4: float = map.terrain_height_at(map.global_transform * Vector3(lx, 0.0, lz - s))
	return maxf(maxf(h1, h2), maxf(h3, h4)) - minf(minf(h1, h2), minf(h3, h4))

const PLACE_BATCH := 400            # попыток на кадр при расстановке пропов

func _too_close(placed: Array, p: Vector3, spacing: float) -> bool:
	for q in placed:
		if (q as Vector3).distance_to(p) < spacing:
			return true
	return false

# O(1)-версия: смотрим только свою и 8 соседних ячеек решётки со стороной spacing.
func _too_close_hashed(grid: Dictionary, cell: float, p: Vector3, spacing: float) -> bool:
	var cx := floori(p.x / cell)
	var cz := floori(p.z / cell)
	for dx in [-1, 0, 1]:
		for dz in [-1, 0, 1]:
			var bucket: Variant = grid.get(Vector2i(cx + dx, cz + dz), null)
			if bucket == null:
				continue
			for q in (bucket as Array):
				if (q as Vector3).distance_to(p) < spacing:
					return true
	return false

# ── Стриминг: ноды только для ближних пропов ──────────────────────────────────
func _process(delta: float) -> void:
	if _data.is_empty():
		return
	_cull_t -= delta
	if _cull_t > 0.0:
		return
	_cull_t = cull_interval
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	var cam_pos: Vector3 = cam.global_position
	var d2: float = render_distance * render_distance
	for v in _data:
		var near: bool = cam_pos.distance_squared_to(to_global(v["pos"])) <= d2
		var has: bool = v["node"] != null
		if near and not has and _shown < max_visible:
			_spawn(v)
		elif not near and has:
			_despawn(v)

func _spawn(v: Dictionary) -> void:
	var node: Node3D = (v["scene"] as PackedScene).instantiate()
	add_child(node)
	node.position = v["pos"]
	var s: float = v["scale"]
	node.scale = Vector3(s, s, s)
	if node is Node3D:
		node.rotation.y = v["yaw"]
	v["node"] = node
	_shown += 1

func _despawn(v: Dictionary) -> void:
	if v["node"] != null and is_instance_valid(v["node"]):
		(v["node"] as Node).queue_free()
	v["node"] = null
	_shown -= 1
