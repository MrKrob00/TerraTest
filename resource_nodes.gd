extends Node3D
# Раскидывает жилы руды по ВСЕЙ карте. Берёт реальную высоту рельефа у родителя-карты
# (map.terrain_height_at) и ставит жилу на землю; пропускает воду/низины и крутые склоны,
# держит минимальную дистанцию между жилами. Каждая жила — это и StaticBody-узел (логика/
# коллизия), и инстанс в двух MultiMesh (видимый меш + канал шейдера истощения).

@export var resource_nodes: Array[PackedScene]
@export var multimesh_nodes: Array[MultiMeshInstance3D]

## Цвета типов жил. Тип выбирается случайно на жилу и красит руду через шейдер (один
## draw-call на все жилы — бесплатно по FPS). ЧТОБЫ ДОБАВИТЬ НОВЫЙ ЦВЕТ ЖИЛЫ — просто
## допиши сюда ещё один Color (до 8 штук, см. MAX_ORE_TYPES в resource.gdshader).
@export var ore_colors: Array[Color] = [
	Color(1.0, 0.75, 0.0),    # золото (по умолчанию)
	Color(0.2, 0.8, 0.85),    # бирюза
	Color(0.85, 0.25, 0.35),  # рубин
]

## Доля угольных жил (0..1). Угольная жила тёмная и выбрасывает УГОЛЬ (COAL) —
## топливо генератора; слитка у угля нет, процессор его не переплавляет.
@export var coal_chance: float = 0.25
@export var coal_color: Color = Color(0.13, 0.13, 0.15)

@export_group("Расстановка")
@export var count: int = 800                 # сколько жил пытаемся расставить (было 200, ×4)
@export var edge_margin: float = 48.0        # отступ от края карты (в юнитах рельефа)
@export var min_height: float = 2.0          # ниже — вода/пляж, не спавним
@export var max_slope: float = 7.0           # разброс высот вокруг точки; выше — обрыв
@export var min_spacing: float = 2.0         # только чтобы жилы не налезали друг на друга

@export_group("Куллинг")
## Дальше этого от камеры жила не рендерится (MultiMesh не куллит инстансы сам, поэтому
## далёкие схлопываем в нулевой масштаб — instance_id и данные истощения не трогаем).
@export var render_distance: float = 280.0
@export var cull_interval: float = 0.25      # как часто пересчитывать видимость (сек)

var _positions: Array[Vector3] = []          # локальные позиции жил (для куллинга)
var _visible_state: Array[bool] = []
var _cull_t: float = 0.0

func _ready() -> void:
	var map: Node = get_parent()
	if map == null or not map.has_method("terrain_height_at") or not map.has_method("get_dims"):
		push_error("resource_nodes: у родителя-карты нет terrain_height_at()/get_dims()")
		return

	# Рельеф грузится в map._ready ПОСЛЕ его await, а этот _ready (ребёнок) идёт раньше —
	# поэтому ждём, пока карта не отдаст размеры (md загружен).
	var guard: int = 0
	while map.get_dims().x <= 0 and guard < 300:
		await get_tree().process_frame
		guard += 1
	var dims: Vector2i = map.get_dims()
	if dims.x <= 0:
		push_error("resource_nodes: рельеф так и не загрузился")
		return

	_apply_ore_colors()
	var positions: Array[Vector3] = _pick_positions(map, dims)
	_spawn(positions)

# Заливаем список цветов в шейдер руды (общий материал core.tres → один раз на всех).
func _apply_ore_colors() -> void:
	if ore_colors.is_empty():
		return
	var cols := PackedVector3Array()
	for c in ore_colors + [coal_color]:      # уголь — последний индекс в шейдере
		var lc: Color = c.srgb_to_linear()      # шейдер ждёт линейные RGB
		cols.append(Vector3(lc.r, lc.g, lc.b))
	for mm in multimesh_nodes:
		var mesh: Mesh = mm.multimesh.mesh if mm.multimesh else null
		if mesh is PrimitiveMesh and mesh.material is ShaderMaterial:
			(mesh.material as ShaderMaterial).set_shader_parameter("ore_colors", cols)

# Локальные позиции жил (Y уже на рельефе). Отбираем случайные точки по всей карте,
# отбраковывая воду, обрывы и слишком близкие друг к другу.
func _pick_positions(map: Node, dims: Vector2i) -> Array[Vector3]:
	var positions: Array[Vector3] = []
	var half_x: float = dims.x * 0.5 - edge_margin
	var half_z: float = dims.y * 0.5 - edge_margin
	var attempts: int = count * 12
	while positions.size() < count and attempts > 0:
		attempts -= 1
		var lx: float = randf_range(-half_x, half_x)
		var lz: float = randf_range(-half_z, half_z)
		var world: Vector3 = map.global_transform * Vector3(lx, 0.0, lz)
		var h: float = map.terrain_height_at(world)
		if h < min_height:
			continue                                        # под водой / слишком низко
		if _slope_at(map, lx, lz) > max_slope:
			continue                                        # обрыв
		var local_pos: Vector3 = to_local(Vector3(world.x, h + 0.25, world.z))
		if _too_close(positions, local_pos):
			continue
		positions.append(local_pos)
	return positions

# Крутизна = разброс высот в 4 точках вокруг (± sample юнитов).
func _slope_at(map: Node, lx: float, lz: float) -> float:
	var s: float = 3.0
	var hx1: float = map.terrain_height_at(map.global_transform * Vector3(lx + s, 0.0, lz))
	var hx2: float = map.terrain_height_at(map.global_transform * Vector3(lx - s, 0.0, lz))
	var hz1: float = map.terrain_height_at(map.global_transform * Vector3(lx, 0.0, lz + s))
	var hz2: float = map.terrain_height_at(map.global_transform * Vector3(lx, 0.0, lz - s))
	return maxf(maxf(hx1, hx2), maxf(hz1, hz2)) - minf(minf(hx1, hx2), minf(hz1, hz2))

func _too_close(positions: Array[Vector3], p: Vector3) -> bool:
	for q in positions:
		if q.distance_to(p) < min_spacing:
			return true
	return false

func _spawn(positions: Array[Vector3]) -> void:
	for mm in multimesh_nodes:
		mm.multimesh.instance_count = 0
		mm.multimesh.use_custom_data = true         # выделяем буфер custom-data ДО instance_count
		mm.multimesh.instance_count = positions.size()

	var type_count: int = maxi(ore_colors.size(), 1)
	for i in positions.size():
		if resource_nodes.is_empty():
			break
		# С шансом coal_chance жила угольная: тип = последний индекс (цвет угля).
		var coal: bool = randf() < coal_chance
		var ore_type: int = ore_colors.size() if coal else randi() % type_count
		var node: Node3D = resource_nodes.pick_random().instantiate()
		node.position = positions[i]
		node.instance_id = i
		if "is_coal" in node:
			node.is_coal = coal
		if "ore_type" in node:
			node.ore_type = ore_type            # жила помнит свой тип для дальнейших записей
		if "ore_color" in node and ore_type < ore_colors.size():
			node.ore_color = ore_colors[ore_type]   # цвет для тинта вылетающей руды
		add_child(node)
		# R=0 → «урона ещё не было», A = тип руды (цвет берёт шейдер).
		var custom := Color(0.0, 0.0, 0.0, float(ore_type))
		var xform := Transform3D(Basis(), positions[i])
		for mm in multimesh_nodes:
			mm.multimesh.set_instance_transform(i, xform)
			mm.multimesh.set_instance_custom_data(i, custom)

	_positions = positions
	_visible_state.resize(positions.size())
	_visible_state.fill(true)

# ── Дистанционный куллинг жил (MultiMesh не куллит инстансы поштучно) ──────────
func _process(delta: float) -> void:
	if _positions.is_empty():
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
	for i in _positions.size():
		var world: Vector3 = to_global(_positions[i])
		var want: bool = cam_pos.distance_squared_to(world) <= d2
		if want == _visible_state[i]:
			continue
		_visible_state[i] = want
		# Видимая — базовый трансформ; далёкая — нулевой масштаб (схлопнута, не рендерится).
		var basis := Basis() if want else Basis().scaled(Vector3.ZERO)
		var xform := Transform3D(basis, _positions[i])
		for mm in multimesh_nodes:
			mm.multimesh.set_instance_transform(i, xform)
