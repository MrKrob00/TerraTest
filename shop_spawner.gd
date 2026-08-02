extends Node3D
# Раскидывает магазины по всей карте РЕДКО — примерно один на клетку cell_size×cell_size.
# Сетка с джиттером, ставит магазин на землю (map.terrain_height_at), пропускает воду/низины
# и крутые склоны, и не ставит рядом с уже существующим магазином (напр. стартовым в сцене).
# ВНИМАНИЕ по FPS: у каждого магазина несколько Area3D (чёрная дыра, кнопка, продавцы) —
# чем меньше cell_size, тем больше магазинов и физических зон. Мало магазинов = крупнее cell_size.

@export var shop_scene: PackedScene
@export var map_node: Node                     # карта; если пусто — ищем ../map и /root/Main/map
@export var cell_size: float = 200.0           # ~один магазин на cell_size×cell_size
@export var jitter: float = 0.35               # случайный сдвиг от центра клетки (доля клетки)
@export var edge_margin: float = 60.0
@export var min_height: float = 2.0            # ниже — вода/пляж, не ставим
@export var max_slope: float = 6.0             # разброс высот вокруг точки; выше — обрыв
@export var ground_offset: float = 0.0         # ставим ровно на рельеф (без подъёма +2)
@export var avoid_existing: float = 90.0       # не ставить ближе этого к уже стоящему магазину

@export_group("Куллинг")
## Дальше этого от камеры магазин прячется (visible=false) — снимает нагрузку GPU от
## далёких магазинов (особенно от прозрачных мешей чёрной дыры). Off-screen меши Godot
## куллит сам, это про «слишком далеко, но в кадре».
@export var render_distance: float = 380.0
@export var cull_interval: float = 0.3

var _shops: Array[Node3D] = []                 # все магазины (стартовый + заспавненные)
var _cull_t: float = 0.0

func _ready() -> void:
	var map: Node = _find_map()
	if map == null or not map.has_method("terrain_height_at") or not map.has_method("get_dims"):
		push_error("shop_spawner: не нашёл карту с terrain_height_at()/get_dims()")
		return
	if shop_scene == null:
		push_error("shop_spawner: не задан shop_scene")
		return

	# Рельеф грузится в map._ready после его await — ждём, пока карта отдаст размеры.
	var guard: int = 0
	while map.get_dims().x <= 0 and guard < 300:
		await get_tree().process_frame
		guard += 1
	var dims: Vector2i = map.get_dims()
	if dims.x <= 0:
		push_error("shop_spawner: рельеф так и не загрузился")
		return

	await _scatter(map, dims)

func _find_map() -> Node:
	if map_node:
		return map_node
	var m: Node = get_node_or_null("../map")
	if m == null:
		m = get_node_or_null("/root/Main/map")
	return m

func _scatter(map: Node, dims: Vector2i) -> void:
	_shops = _existing_shop_nodes()                          # стартовый магазин тоже куллим
	var placed: Array[Vector3] = []
	for s in _shops:
		placed.append(s.global_position)
	var half_x: float = dims.x * 0.5 - edge_margin
	var half_z: float = dims.y * 0.5 - edge_margin
	var lx: float = -half_x
	while lx < half_x:
		var lz: float = -half_z
		while lz < half_z:
			# центр клетки + случайный джиттер, зажатый в границы карты
			var jx: float = clampf(lx + cell_size * 0.5 + randf_range(-jitter, jitter) * cell_size, -half_x, half_x)
			var jz: float = clampf(lz + cell_size * 0.5 + randf_range(-jitter, jitter) * cell_size, -half_z, half_z)
			var world: Vector3 = map.global_transform * Vector3(jx, 0.0, jz)
			var h: float = map.terrain_height_at(world)
			if h >= min_height and _slope_at(map, jx, jz) <= max_slope:
				var pos: Vector3 = Vector3(world.x, h + ground_offset, world.z)
				if not _too_close(placed, pos):
					_place_shop(pos)
					placed.append(pos)
					# Каждый магазин — сцена из ~10 узлов с ареями/коллизиями. Десятки за один кадр
					# давали хич поверх экрана загрузки: отдаём кадр после каждой постановки.
					await get_tree().process_frame
			lz += cell_size
		lx += cell_size

func _place_shop(world_pos: Vector3) -> void:
	var shop: Node3D = shop_scene.instantiate()
	shop.add_to_group("shop")
	add_child(shop)
	shop.global_position = world_pos
	_shops.append(shop)

# Магазины, уже стоящие в сцене вручную (имя начинается с "Shop"), кроме самого спавнера.
func _existing_shop_nodes() -> Array[Node3D]:
	var out: Array[Node3D] = []
	var main: Node = get_parent()
	if main:
		for c in main.get_children():
			if c != self and c is Node3D and str(c.name).begins_with("Shop"):
				out.append(c as Node3D)
	return out

# ── Дистанционный куллинг магазинов ───────────────────────────────────────────
func _process(delta: float) -> void:
	if _shops.is_empty():
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
	for s in _shops:
		if is_instance_valid(s):
			s.visible = cam_pos.distance_squared_to(s.global_position) <= d2

# Крутизна = разброс высот в 4 точках вокруг (± sample юнитов).
func _slope_at(map: Node, lx: float, lz: float) -> float:
	var s: float = 4.0
	var hx1: float = map.terrain_height_at(map.global_transform * Vector3(lx + s, 0.0, lz))
	var hx2: float = map.terrain_height_at(map.global_transform * Vector3(lx - s, 0.0, lz))
	var hz1: float = map.terrain_height_at(map.global_transform * Vector3(lx, 0.0, lz + s))
	var hz2: float = map.terrain_height_at(map.global_transform * Vector3(lx, 0.0, lz - s))
	return maxf(maxf(hx1, hx2), maxf(hz1, hz2)) - minf(minf(hx1, hx2), minf(hz1, hz2))

func _too_close(placed: Array[Vector3], p: Vector3) -> bool:
	for q in placed:
		if Vector2(q.x, q.z).distance_to(Vector2(p.x, p.z)) < avoid_existing:
			return true
	return false
