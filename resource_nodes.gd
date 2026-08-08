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
@export var count: int = 2000                # жил по ВСЕЙ карте — «тысячи». Все они лишь ДАННЫЕ
#                                              (позиция+тип, дёшево); ноды и слоты — только ближним.
@export var edge_margin: float = 48.0        # отступ от края карты (в юнитах рельефа)
@export var min_height: float = 2.0          # ниже — вода/пляж, не спавним
@export var max_slope: float = 7.0           # разброс высот вокруг точки; выше — обрыв
@export var min_spacing: float = 2.0         # только чтобы жилы не налезали друг на друга

@export_group("Стриминг")
## Радиус вокруг камеры, в котором жилы РЕНДЕРЯТСЯ и активны (есть узел/коллизия для добычи).
## Дальше — только запись в _data, ни ноды, ни инстанса MultiMesh (система не грузится).
@export var render_distance: float = 160.0
## ПОТОЛОК одновременно отрисованных/активных жил = размер буфера MultiMesh и пул слотов.
## В радиусе 160 при 2000 жилах на карту 1982² их ~40-60; 180 — с большим запасом.
@export var max_visible: int = 180
@export var cull_interval: float = 0.25      # как часто пересчитывать стриминг (сек)

# Все жилы карты как данные: {pos, scene, ore_type, coal, slot(-1=не показана), node(null)}.
var _data: Array = []
var _free: Array[int] = []                   # свободные слоты MultiMesh (пул)
var _cull_t: float = 0.0
# Схлопнутый трансформ (нулевой масштаб) — для «погашенных» слотов MultiMesh.
var ZERO_XFORM := Transform3D(Basis().scaled(Vector3.ZERO), Vector3.ZERO)

# _ready идёт СНИЗУ ВВЕРХ: у детей он вызывается РАНЬШЕ, чем у родителя. Значит на этот
# момент карта ещё не выполнила свой _ready, и требовать от неё готовности сразу нельзя.
# Ждём, пока она начнёт отвечать, и только потом сдаёмся: прежний вариант ругался и
# делал return, из-за чего узел не инициализировался за весь сеанс.
const MAP_WAIT_FRAMES: int = 300      # ~5 секунд при 60 кадрах

func _ready() -> void:
	var map: Node = await _await_map()
	if map == null:
		push_error("resource_nodes: родитель так и не стал картой (нет terrain_height_at/get_dims)")
		return

	var guard: int = 0
	while map.get_dims().x <= 0 and guard < 300:
		await get_tree().process_frame
		guard += 1
	var dims: Vector2i = map.get_dims()
	if dims.x <= 0:
		push_error("resource_nodes: рельеф так и не загрузился")
		return

	_apply_ore_colors()
	var positions: Array[Vector3] = await _pick_positions(map, dims)
	_init_veins(positions)

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
# Отбор идёт ПОРЦИЯМИ (между ними отдаём кадр) — иначе до 24 000 попыток × 5 сэмплов рельефа
# вставали одним многосекундным фризом поверх экрана загрузки.
const PICK_BATCH := 400

func _pick_positions(map: Node, dims: Vector2i) -> Array[Vector3]:
	var positions: Array[Vector3] = []
	var half_x: float = dims.x * 0.5 - edge_margin
	var half_z: float = dims.y * 0.5 - edge_margin
	var attempts: int = count * 12
	var grid: Dictionary = {}
	var cell: float = maxf(min_spacing, 0.001)
	var since_yield: int = 0
	while positions.size() < count and attempts > 0:
		attempts -= 1
		since_yield += 1
		if since_yield >= PICK_BATCH:
			since_yield = 0
			await get_tree().process_frame
		var lx: float = randf_range(-half_x, half_x)
		var lz: float = randf_range(-half_z, half_z)
		var world: Vector3 = map.global_transform * Vector3(lx, 0.0, lz)
		var h: float = map.terrain_height_at(world)
		if h < min_height:
			continue                                        # под водой / слишком низко
		if _slope_at(map, lx, lz) > max_slope:
			continue                                        # обрыв
		var local_pos: Vector3 = to_local(Vector3(world.x, h + 0.25, world.z))
		if _too_close_hashed(grid, cell, local_pos):
			continue
		positions.append(local_pos)
		var key := Vector2i(floori(local_pos.x / cell), floori(local_pos.z / cell))
		if not grid.has(key):
			grid[key] = [] as Array[Vector3]
		(grid[key] as Array).append(local_pos)
	return positions

# Есть ли принятая точка ближе min_spacing? Смотрим только свою и 8 соседних ячеек решётки.
func _too_close_hashed(grid: Dictionary, cell: float, p: Vector3) -> bool:
	var cx := floori(p.x / cell)
	var cz := floori(p.z / cell)
	for dx in [-1, 0, 1]:
		for dz in [-1, 0, 1]:
			var bucket = grid.get(Vector2i(cx + dx, cz + dz), null)
			if bucket == null:
				continue
			for q in (bucket as Array):
				if (q as Vector3).distance_to(p) < min_spacing:
					return true
	return false

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

# Готовим ДАННЫЕ всех жил (дёшево) + буфер MultiMesh на max_visible слотов (все схлопнуты).
# Узлы и видимые инстансы появляются позже, в _process, только для ближних (стриминг).
func _init_veins(positions: Array[Vector3]) -> void:
	var cap: int = mini(max_visible, positions.size())
	var big := AABB(Vector3(-2000.0, -2000.0, -2000.0), Vector3(4000.0, 4000.0, 4000.0))
	for mm in multimesh_nodes:
		mm.custom_aabb = big
		mm.multimesh.instance_count = 0
		mm.multimesh.use_custom_data = true         # буфер custom-data ДО instance_count
		mm.multimesh.instance_count = cap
		for s in cap:
			mm.multimesh.set_instance_transform(s, ZERO_XFORM)   # пусто, пока не заполнит стриминг
	_free.clear()
	for s in range(cap - 1, -1, -1):
		_free.append(s)                             # слоты cap-1..0 свободны

	var type_count: int = maxi(ore_colors.size(), 1)
	var scene: PackedScene = resource_nodes.pick_random() if not resource_nodes.is_empty() else null
	_data.clear()
	for p in positions:
		# Тип решаем один раз на жилу: с шансом coal_chance — угольная (последний индекс).
		var coal: bool = randf() < coal_chance
		var ore_type: int = ore_colors.size() if coal else randi() % type_count
		_data.append({
			"pos": p,
			"scene": resource_nodes.pick_random() if not resource_nodes.is_empty() else scene,
			"ore_type": ore_type, "coal": coal, "slot": -1, "node": null,
		})
	_cull_t = 0.0                                    # первый стриминг — сразу

# Жила вошла в радиус: берём слот из пула, рисуем инстанс + создаём узел (добыча/коллизия).
func _stream_in(v: Dictionary) -> void:
	if _free.is_empty():
		return                                       # достигнут потолок max_visible — редко (кап с запасом)
	var slot: int = _free.pop_back()
	v["slot"] = slot
	var xform := Transform3D(Basis(), v["pos"])
	var custom := Color(0.0, 1.0, 0.0, float(v["ore_type"]))   # G=1 «целая», A=тип (стримнутая жила полна)
	for mm in multimesh_nodes:
		mm.multimesh.set_instance_transform(slot, xform)
		mm.multimesh.set_instance_custom_data(slot, custom)
	if v["scene"] != null:
		var node: Node3D = v["scene"].instantiate()
		node.position = v["pos"]
		node.instance_id = slot                      # узел пишет истощение в ЭТОТ слот
		if "is_coal" in node: node.is_coal = v["coal"]
		if "ore_type" in node: node.ore_type = v["ore_type"]
		if "ore_color" in node and int(v["ore_type"]) < ore_colors.size():
			node.ore_color = ore_colors[v["ore_type"]]
		add_child(node)
		v["node"] = node

# Мировые позиции сейчас активных (стримнутых) жил — для блипов на радаре (hud.gd).
func active_positions() -> Array:
	var out: Array = []
	for v in _data:
		if int(v["slot"]) >= 0:
			out.append(to_global(v["pos"]))
	return out

# Жила вышла из радиуса: гасим инстанс, освобождаем узел и возвращаем слот в пул.
func _stream_out(v: Dictionary) -> void:
	var slot: int = int(v["slot"])
	for mm in multimesh_nodes:
		mm.multimesh.set_instance_transform(slot, ZERO_XFORM)
	if v["node"] != null and is_instance_valid(v["node"]):
		v["node"].queue_free()
	v["node"] = null
	v["slot"] = -1
	_free.append(slot)

# ── Стриминг: держим отрисованными/активными только жилы в render_distance ─────
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
		var shown: bool = int(v["slot"]) >= 0
		if near and not shown:
			_stream_in(v)
		elif not near and shown:
			_stream_out(v)


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
