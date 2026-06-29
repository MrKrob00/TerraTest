# block_map.gd
extends Node3D

const MAP_SIZE_X = 10
const MAP_SIZE_Y = 10
const MAP_SIZE_Z = 10
const CELL_SIZE = 1.0

var map: Array = []
var node_map: Dictionary = {}
var rotation_map: Dictionary = {}
# Многоклеточные блоки (SELLER/PROCESSOR 2×2×2) занимают 8 клеток, но узел/поворот живут
# на ОДНОЙ якорной клетке. cell_owner: "x,y,z" любой занятой клетки → "ax,ay,az" якоря.
# Так любая из 8 клеток ведёт к одному блоку (выбор/удаление с любой стороны), а все 8
# помечены занятыми (другой блок туда уже не встанет).
var cell_owner: Dictionary = {}

const SAVE_PATH = "user://vehicle_layout.json"

func _ready() -> void:
	_init_map()
	_define_layout()
	_spawn_all()

# ─── Инициализация ────────────────────────────────────────────────────────────
func _init_map() -> void:
	map = []
	for x in range(MAP_SIZE_X):
		var plane: Array = []
		for y in range(MAP_SIZE_Y):
			var row: Array = []
			for z in range(MAP_SIZE_Z):
				row.append(G.Block.EMPTY)
			plane.append(row)
		map.append(plane)

# ─── Раскладка по умолчанию ───────────────────────────────────────────────────
func _define_layout() -> void:
	set_block(5, 0, 5, G.Block.CABIN, 0.0)
	set_block(4, 0, 5, G.Block.WHEEL, PI / 2)
	set_block(6, 0, 5, G.Block.WHEEL, -PI / 2)
	set_block(4, 0, 6, G.Block.WHEEL, PI / 2)
	set_block(6, 0, 6, G.Block.WHEEL, -PI / 2)
	set_block(4, 0, 7, G.Block.WHEEL, PI / 2)
	set_block(6, 0, 7, G.Block.WHEEL, -PI / 2)
	set_block(5, 0, 4, G.Block.DRILL, 0.0)
	set_block(5, 1, 5, G.Block.GUN, 0.0)
	#set_block(5, 1, 5, G.Block.COLLECTOR, 0.0)
	#set_block(3, 1, 7, G.Block.INTAKE, -PI/2)
	#set_block(4, 1, 7, G.Block.BELT, 0.0)
	#set_block(4, 1, 6, G.Block.PROCESSOR, 0.0)
	#set_block(4, 1, 4, G.Block.BELT, 0.0)
	#set_block(4, 1, 3, G.Block.SELLER, 0.0)

# ─── Спавн всех блоков ────────────────────────────────────────────────────────
func _spawn_all() -> void:
	for x in range(MAP_SIZE_X):
		for y in range(MAP_SIZE_Y):
			for z in range(MAP_SIZE_Z):
				var block: G.Block = map[x][y][z]
				# Только якорные клетки — иначе многоклеточный блок заспавнится 8 раз.
				if block != G.Block.EMPTY and _is_anchor(x, y, z):
					spawn_block(block, x, y, z)

# True, если (x,y,z) — якорная клетка своего блока (для одноклеточных всегда true).
func _is_anchor(x: int, y: int, z: int) -> bool:
	var key := "%d,%d,%d" % [x, y, z]
	return cell_owner.get(key, key) == key

# ─── Клетки, которые занимает блок ────────────────────────────────────────────
# Якорь (x,y,z). 2×2×2 (SELLER/PROCESSOR) занимает x-1..x, y..y+1, z-1..z (8 клеток),
# остальные блоки — одну клетку. Те же 8 клеток, что проверял старый код.
func _block_footprint(block: int, x: int, y: int, z: int) -> Array:
	if block == G.Block.PROCESSOR or block == G.Block.SELLER:
		var cells: Array = []
		for dx in [-1, 0]:
			for dy in [0, 1]:
				for dz in [-1, 0]:
					cells.append(Vector3i(x + dx, y + dy, z + dz))
		return cells
	return [Vector3i(x, y, z)]

# Можно ли поставить block с якорем (x,y,z): все клетки footprint в границах и пусты.
func can_place(block: int, x: int, y: int, z: int) -> bool:
	for c in _block_footprint(block, x, y, z):
		if not _in_bounds(c.x, c.y, c.z) or map[c.x][c.y][c.z] != G.Block.EMPTY:
			return false
	return true

# ─── Запись / чтение ──────────────────────────────────────────────────────────
# Возвращает true, если блок реально поставлен (footprint был свободен).
func set_block(x: int, y: int, z: int, block: G.Block, rot_y: float = 0.0) -> bool:
	if not _in_bounds(x, y, z):
		push_warning("set_block: координаты (%d,%d,%d) вне границ!" % [x, y, z])
		return false
	if not can_place(block, x, y, z):
		return false   # перекрытие/край → не ставим
	var anchor := "%d,%d,%d" % [x, y, z]
	for c in _block_footprint(block, x, y, z):
		map[c.x][c.y][c.z] = block
		cell_owner["%d,%d,%d" % [c.x, c.y, c.z]] = anchor
	rotation_map[anchor] = rot_y
	return true

func remove_block(x: int, y: int, z: int) -> void:
	if not _in_bounds(x, y, z):
		return
	# Удаляем весь блок, даже если тапнули по не-якорной клетке многоклеточного блока.
	var anchor: String = cell_owner.get("%d,%d,%d" % [x, y, z], "%d,%d,%d" % [x, y, z])
	var parts := anchor.split(",")
	var ax := int(parts[0]); var ay := int(parts[1]); var az := int(parts[2])
	if not _in_bounds(ax, ay, az) or map[ax][ay][az] == G.Block.EMPTY:
		return
	for c in _block_footprint(map[ax][ay][az], ax, ay, az):
		if _in_bounds(c.x, c.y, c.z):
			map[c.x][c.y][c.z] = G.Block.EMPTY
			cell_owner.erase("%d,%d,%d" % [c.x, c.y, c.z])
	node_map.erase(anchor)
	rotation_map.erase(anchor)

func get_block(x: int, y: int, z: int) -> G.Block:
	if _in_bounds(x, y, z):
		return map[x][y][z]
	return G.Block.EMPTY

func find_block(x: int, y: int, z: int) -> Node3D:
	if not _in_bounds(x, y, z):
		push_warning("find_block: координаты (%d,%d,%d) вне границ!" % [x, y, z])
		return null
	# Любая клетка многоклеточного блока ведёт к его якорному узлу.
	var anchor: String = cell_owner.get("%d,%d,%d" % [x, y, z], "%d,%d,%d" % [x, y, z])
	return node_map.get(anchor, null)

func _in_bounds(x: int, y: int, z: int) -> bool:
	return (
		x >= 0 and x < MAP_SIZE_X and
		y >= 0 and y < MAP_SIZE_Y and
		z >= 0 and z < MAP_SIZE_Z
	)

# ─── Спавн одного блока ───────────────────────────────────────────────────────
func spawn_block(block: G.Block, x: int, y: int, z: int) -> void:
	var scene: PackedScene = G.get_scene(block)
	if scene == null:
		push_warning("Сцена не назначена для блока: %s" % G.Block.keys()[block])
		return

	var instance: Node3D = scene.instantiate()
	add_child(instance)

	# ── Подключаем сигнал уничтожения ─────────────────────────────
	if instance.has_signal("destroyed"):
		instance.destroyed.connect(_on_block_destroyed.bind(x, y, z))

	var key := "%d,%d,%d" % [x, y, z]
	var rot_y: float = rotation_map.get(key, 0.0)
	instance.rotation.y = rot_y

	var collision = instance.get_child(0).duplicate()
	collision.position = Vector3(x - 5, y, z - 5)
	if collision.shape.size == Vector3(2,2,2):
		collision.position += Vector3(-0.5,0.5,-0.5)
	if !get_parent().is_node_ready():
		await get_parent().ready
	get_parent().add_child(collision)
	node_map[key] = instance

	instance.position = Vector3(
		(x - MAP_SIZE_X / 2.0) * CELL_SIZE,
		y * CELL_SIZE,
		(z - MAP_SIZE_Z / 2.0) * CELL_SIZE
	)

# ── Обработчик: блок уничтожен ────────────────────────────────────
func _on_block_destroyed(_block_node: VehicleBlock, x: int, y: int, z: int) -> void:
	remove_block(x, y, z)

# ══════════════════════════════════════════════════════════════════════════════
# СОХРАНЕНИЕ / ЗАГРУЗКА
# ══════════════════════════════════════════════════════════════════════════════

func save_layout() -> void:
	var blocks_array = []
	for x in range(MAP_SIZE_X):
		for y in range(MAP_SIZE_Y):
			for z in range(MAP_SIZE_Z):
				var block = map[x][y][z]
				if block != G.Block.EMPTY and _is_anchor(x, y, z):
					var key = "%d,%d,%d" % [x, y, z]
					blocks_array.append({
						"x": x,
						"y": y,
						"z": z,
						"block": block,
						"rot_y": rotation_map.get(key, 0.0)
					})

	var json_string = JSON.stringify(blocks_array, "\t")
	var file = FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	file.store_string(json_string)
	file.close()
	print("Машина сохранена: ", SAVE_PATH)

func load_layout() -> void:
	if not FileAccess.file_exists(SAVE_PATH):
		push_warning("Файл сохранения не найден: ", SAVE_PATH)
		return

	for child in get_children():
		child.queue_free()
	node_map.clear()
	rotation_map.clear()
	cell_owner.clear()
	_init_map()

	var file = FileAccess.open(SAVE_PATH, FileAccess.READ)
	var json = JSON.new()
	json.parse(file.get_as_text())
	file.close()

	var blocks_array = json.get_data()
	for entry in blocks_array:
		set_block(entry["x"], entry["y"], entry["z"], entry["block"], entry["rot_y"])

	_spawn_all()
	print("Машина загружена!")

func get_layout() -> Array:
	var blocks_array = []
	for x in range(MAP_SIZE_X):
		for y in range(MAP_SIZE_Y):
			for z in range(MAP_SIZE_Z):
				var block = map[x][y][z]
				if block != G.Block.EMPTY and _is_anchor(x, y, z):
					var key = "%d,%d,%d" % [x, y, z]
					blocks_array.append({
						"x": x, "y": y, "z": z,
						"block": block,
						"rot_y": rotation_map.get(key, 0.0)
					})
	return blocks_array

func apply_layout(blocks_array: Array) -> void:
	for child in get_children():
		child.queue_free()
	node_map.clear()
	rotation_map.clear()
	cell_owner.clear()
	_init_map()
	for entry in blocks_array:
		set_block(entry["x"], entry["y"], entry["z"], entry["block"], entry["rot_y"])
	_spawn_all()
