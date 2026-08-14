# block_map.gd
extends Node3D

const MAP_SIZE_X = 11
const MAP_SIZE_Y = 11
const MAP_SIZE_Z = 11
const CENTER = 5                     # индекс центральной клетки по каждой оси (0..10 → центр 5)
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

# ─── Точки контакта (какими гранями блок стыкуется) ───────────────────────────
# Список граней теперь живёт НЕ здесь, а экспортом connect_faces на самом блоке
# (VehicleBlock) — галочками в инспекторе каждой сцены, как input/output у фабричных.
# Здесь остаётся только правило, как их читать.
#
# Раньше это была таблица в коде, по типу блока и в неповёрнутых осях: чтобы поправить одну
# грань бура, надо было лезть в скрипт, а поворот блока в проверке не участвовал вовсе.
const ALL_FACES := ["top", "bottom", "left", "right", "front", "back"]
const OPPOSITE := {
	"top": "bottom", "bottom": "top",
	"left": "right", "right": "left",
	"front": "back", "back": "front",
}
# Имя грани → направление наружу. Совпадает с FACE_VECS в VehicleBlock.
const FACE_DIR := {
	"right": Vector3i(1, 0, 0), "left": Vector3i(-1, 0, 0),
	"top": Vector3i(0, 1, 0), "bottom": Vector3i(0, -1, 0),
	"back": Vector3i(0, 0, 1), "front": Vector3i(0, 0, -1),
}

## Пускает ли УЖЕ СТОЯЩИЙ блок соседа к своей грани face. Грани берём повёрнутыми
## (face_dirs), потому что блок на машине развёрнут, и «зад» у него смотрит куда угодно.
func node_accepts_face(node: Node, face: String) -> bool:
	if node == null or not is_instance_valid(node) or not (node is VehicleBlock):
		return true                        # не блок (или уже уничтожен) — не мешаем
	if not FACE_DIR.has(face):
		return true
	return (node as VehicleBlock).face_dirs((node as VehicleBlock).connect_faces) \
			.has(FACE_DIR[face] as Vector3i)

# Можно ли прицепить new_type к грани attach_face блока neighbor_type.
# true, если структура — стационарная база (ставит vehicle при спавне с якорным ядром).
var is_station: bool = false

# Что можно ставить на СТАЦИОНАРНУЮ базу: другие стационары + обычные фабричные + каркас
# (3Б — база-фабрика). Оружие/колёса/кабину на базу не ставим.
func _allowed_on_station(bt: int) -> bool:
	if G.is_stationary(bt) or bt == G.Block.BLOCK:
		return true
	return (G.BLOCK_CATEGORIES.get("factory", []) as Array).has(bt)

## Можно ли прицепить блок new_node к грани attach_face того, что стоит в клетке (nx,ny,nz).
## Клетку берём, а не тип: по ней достаём САМ УЗЕЛ соседа, а значит и его поворот — без
## поворота грань «зад» ничего не значит, блок на машине развёрнут как попало.
func can_attach(nx: int, ny: int, nz: int, new_node: Node, attach_face: String) -> bool:
	var new_type: int = int(new_node.get("block")) if new_node != null else G.Block.EMPTY
	# Стационарный блок нельзя на мобильную машину, только на стационарную базу (2A).
	if G.is_stationary(new_type) and not is_station:
		return false
	# На стационарную базу — только разрешённые типы (3Б).
	if is_station and not _allowed_on_station(new_type):
		return false
	# У НОВОГО блока грань не проверяем: постройка сама доворачивает его отмеченной стороной
	# к соседу (_face_orient), поэтому «стыковаться нужной гранью» выполнимо на любой грани.
	# Не может он только одного — если галочек не стоит вовсе.
	if new_node is VehicleBlock and (new_node as VehicleBlock).connect_faces == 0:
		return false
	# А вот СОСЕД решает, пускать ли к своей грани: на коронку бура ничего не навесить.
	return node_accepts_face(find_block(nx, ny, nz), attach_face)

## Пресет стартовой сборки. 0 — обычная машина (как у игрока, НЕ трогаем). 1+ — варианты
## для врагов («машина из пула»). Спавнер врагов ставит случайный пресет ДО добавления в дерево.
@export var layout_preset: int = 0

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

# ─── Раскладка ────────────────────────────────────────────────────────────────
# Пресет выбирает сборку. 0 — базовая (у игрока), 1/2 — варианты врагов из пула.
func _define_layout() -> void:
	match layout_preset:
		1: _layout_dual_gun()
		2: _layout_laser_scout()
		3: _layout_starter()
		4: _layout_cabin_only()
		_: _layout_default()

# Новый старт игры: ОДНА кабина (базовый набор блоков падает рядом в мир — см. world_persist.gd).
# Ядро в ЦЕНТРЕ сетки (CENTER на всех осях), y-этажи присборок отсчитываются от центра (+5).
func _layout_cabin_only() -> void:
	set_block(5, 5, 5, G.Block.CABIN, 0.0)

# Стартовая машина (спавнится бесплатно при гибели): кабина, 4 колеса, пара блоков,
# пулемёт и бур. Компактнее дефолта.
func _layout_starter() -> void:
	set_block(5, 5, 5, G.Block.CABIN, 0.0)
	set_block(4, 5, 5, G.Block.WHEEL, PI / 2)
	set_block(6, 5, 5, G.Block.WHEEL, -PI / 2)
	set_block(4, 5, 6, G.Block.WHEEL, PI / 2)
	set_block(6, 5, 6, G.Block.WHEEL, -PI / 2)
	set_block(5, 5, 6, G.Block.BLOCK, 0.0)
	set_block(5, 6, 6, G.Block.BLOCK, 0.0)
	set_block(5, 5, 4, G.Block.DRILL, 0.0)
	set_block(5, 6, 5, G.Block.LASER, 0.0)
	set_block(5, 5, 6, G.Block.BLOCK, 0.0)
	set_block(5, 5, 7, G.Block.BLOCK, 0.0)

# База: кабина, 6 колёс, дрель, пушка (стартовая машина игрока — НЕ меняем).
func _layout_default() -> void:
	_wheels_6()
	set_block(5, 5, 5, G.Block.CABIN, 0.0)
	set_block(5, 5, 4, G.Block.DRILL, 0.0)
	set_block(5, 6, 5, G.Block.LASER, 0.0)
	#set_block(5, 1, 5, G.Block.COLLECTOR, 0.0)
	#set_block(3, 1, 7, G.Block.RECEIVER, -PI/2)
	#set_block(4, 1, 7, G.Block.BELT, 0.0)
	#set_block(4, 1, 6, G.Block.PROCESSOR, 0.0)
	#set_block(4, 1, 4, G.Block.BELT, 0.0)
	#set_block(4, 1, 3, G.Block.SELLER, 0.0)

# Тяжёлый: две пушки. Разнесены по длине корпуса (5 и 7, а не 5 и 6 рядом) — вес не
# наваливается на передний край базы колёс, машина реже клюёт носом при торможении/ИИ-реверсе.
func _layout_dual_gun() -> void:
	_wheels_6()
	set_block(5, 5, 5, G.Block.CABIN, 0.0)
	set_block(5, 6, 5, G.Block.GUN, 0.0)
	set_block(5, 6, 7, G.Block.GUN, 0.0)

func _layout_laser_scout() -> void:
	_wheels_6()
	set_block(5, 5, 5, G.Block.CABIN, 0.0)
	set_block(5, 6, 5, G.Block.LASER, 0.0)

func _wheels_6() -> void:
	set_block(4, 5, 5, G.Block.WHEEL, PI / 2)
	set_block(6, 5, 5, G.Block.WHEEL, -PI / 2)
	set_block(4, 5, 6, G.Block.WHEEL, PI / 2)
	set_block(6, 5, 6, G.Block.WHEEL, -PI / 2)
	set_block(4, 5, 7, G.Block.WHEEL, PI / 2)
	set_block(6, 5, 7, G.Block.WHEEL, -PI / 2)
	set_block(5, 5, 6, G.Block.BLOCK, 0.0)
	set_block(5, 5, 7, G.Block.BLOCK, 0.0)

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
	if block == G.Block.PROCESSOR or block == G.Block.SELLER or block == G.Block.FABRICATOR:
		var cells: Array = []
		for dx in [-1, 0]:
			for dy in [0, 1]:
				for dz in [-1, 0]:
					cells.append(Vector3i(x + dx, y + dy, z + dz))
		return cells
	if block == G.Block.COAL_GEN:
		var cells2: Array = []               # 2×1×2 (xyz): dx∈[-1,0], dy=0, dz∈[-1,0]
		for dx in [-1, 0]:
			for dz in [-1, 0]:
				cells2.append(Vector3i(x + dx, y, z + dz))
		return cells2
	if block == G.Block.BLOCK2 or block == G.Block.WEDGE2:
		return [Vector3i(x - 1, y, z), Vector3i(x, y, z)]   # 2×1×1
	if block == G.Block.BLOCK3:
		return [Vector3i(x - 1, y, z), Vector3i(x, y, z), Vector3i(x + 1, y, z)]   # 3×1×1
	return [Vector3i(x, y, z)]

# Можно ли поставить block с якорем (x,y,z): все клетки footprint в границах и пусты.
func can_place(block: int, x: int, y: int, z: int) -> bool:
	for c in _block_footprint(block, x, y, z):
		if not _in_bounds(c.x, c.y, c.z) or map[c.x][c.y][c.z] != G.Block.EMPTY:
			return false
	return true

# ─── Запись / чтение ──────────────────────────────────────────────────────────
# Возвращает true, если блок реально поставлен (footprint был свободен).
# rot принимает float (только yaw — старый формат) ИЛИ Vector3 (полный поворот с наклоном).
func set_block(x: int, y: int, z: int, block: G.Block, rot = 0.0) -> bool:
	if not _in_bounds(x, y, z):
		push_warning("set_block: координаты (%d,%d,%d) вне границ!" % [x, y, z])
		return false
	if not can_place(block, x, y, z):
		return false   # перекрытие/край → не ставим
	var anchor := "%d,%d,%d" % [x, y, z]
	for c in _block_footprint(block, x, y, z):
		map[c.x][c.y][c.z] = block
		cell_owner["%d,%d,%d" % [c.x, c.y, c.z]] = anchor
	rotation_map[anchor] = rot if rot is Vector3 else Vector3(0, float(rot), 0)
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

	attach_block_signals(instance, x, y, z)

	var key := "%d,%d,%d" % [x, y, z]
	var rot: Vector3 = rotation_map.get(key, Vector3.ZERO)
	instance.rotation = rot

	var collision = instance.get_child(0).duplicate()
	collision.position = Vector3(x - CENTER, y - CENTER, z - CENTER)
	collision.rotation = rot                     # коллизия наклоняется вместе с блоком
	if collision.shape.size == Vector3(2,2,2):
		collision.position += Vector3(-0.5,0.5,-0.5)
	elif collision.shape.size == Vector3(2,1,1):
		collision.position += Vector3(-0.5,0.0,0.0)       # BLOCK2: центрируем 2-широкую коллизию
	elif collision.shape.size == Vector3(2,1,2):
		collision.position += Vector3(-0.5,0.0,-0.5)      # COAL_GEN: 2×1×2
	if !get_parent().is_node_ready():
		await get_parent().ready
	get_parent().add_child(collision)
	collision.add_to_group("block_collision")   # чтобы смена сборки могла их убрать
	node_map[key] = instance

	instance.position = Vector3(
		(x - CENTER) * CELL_SIZE,
		(y - CENTER) * CELL_SIZE,
		(z - CENTER) * CELL_SIZE
	)

	# Эффект «матрицы»-появления — только когда машина строится с НУЛЯ (spawn_block зовётся
	# лишь из _spawn_all: первая машина / загрузка / смена сборки). При ручной постановке
	# блока его больше не играем (см. vehicle_body_3d._on_take_pressed).
	BlockFX.play(instance, false)

## Подписать блок на СВОЁ уничтожение: карта обязана очистить его клетки, иначе на месте
## погибшего блока навсегда остаётся «занято», и новый туда уже не поставить (can_place
## смотрит именно в карту).
##
## Зовут ОБА пути появления блока — и спавн сборки, и постановка игроком
## (vehicle_body_3d._on_take_pressed). Раньше подписка была вписана прямо в spawn_block, и
## поставленные игроком блоки её не получали: сгорел такой блок — клетка занята навсегда.
func attach_block_signals(instance: Node, x: int, y: int, z: int) -> void:
	if not instance.has_signal("destroyed"):
		return
	var cb: Callable = _on_block_destroyed.bind(x, y, z)
	if not instance.destroyed.is_connected(cb):
		instance.destroyed.connect(cb)

# ── Обработчик: блок уничтожен ────────────────────────────────────
func _on_block_destroyed(_block_node: VehicleBlock, x: int, y: int, z: int) -> void:
	remove_block(x, y, z)
	if not _rebuild_queued:
		_rebuild_queued = true
		call_deferred("_deferred_rebuild")

var _rebuild_queued: bool = false

func _deferred_rebuild() -> void:
	_rebuild_queued = false
	_detach_orphans()
	rebuild_factory_links()                  # топология изменилась — пересчитать цепочку фабрики

# ── Структурная целостность ───────────────────────────────────────────────────
# Корень постройки: КАБИНА (мобильная машина) или СТАЦИОНАРНЫЙ блок (база). Всё, что не
# добирается до корня по грани-к-грани, — оторвано. Один BFS ловит сразу целый оторванный кусок.
func _reachable_cells() -> Dictionary:
	var seen: Dictionary = {}
	var queue: Array = []
	for x in MAP_SIZE_X:
		for y in MAP_SIZE_Y:
			for z in MAP_SIZE_Z:
				var bt: int = map[x][y][z]
				if bt != G.Block.EMPTY and (bt == G.Block.CABIN or G.is_stationary(bt)):
					var k := "%d,%d,%d" % [x, y, z]
					if not seen.has(k):
						seen[k] = true
						queue.append(Vector3i(x, y, z))
	var DIRS := [Vector3i(1,0,0), Vector3i(-1,0,0), Vector3i(0,1,0), Vector3i(0,-1,0), Vector3i(0,0,1), Vector3i(0,0,-1)]
	while not queue.is_empty():
		var c: Vector3i = queue.pop_back()
		for d in DIRS:
			var n: Vector3i = c + d
			if not _in_bounds(n.x, n.y, n.z):
				continue
			if map[n.x][n.y][n.z] == G.Block.EMPTY:
				continue
			var nk := "%d,%d,%d" % [n.x, n.y, n.z]
			if seen.has(nk):
				continue
			seen[nk] = true
			queue.append(n)
	return seen

func _detach_orphans() -> void:
	if node_map.is_empty():
		return
	var reachable := _reachable_cells()
	if reachable.is_empty():
		return   # корня нет (кабина/база уничтожена) — этим займётся смерть машины (_scatter_blocks)
	var orphans: Array = []
	for anchor in node_map.keys():
		var parts: PackedStringArray = anchor.split(",")
		var ax := int(parts[0]); var ay := int(parts[1]); var az := int(parts[2])
		if not _in_bounds(ax, ay, az):
			continue
		var bt: int = map[ax][ay][az]
		if bt == G.Block.EMPTY:
			continue
		var grounded := false
		for c in _block_footprint(bt, ax, ay, az):
			if reachable.has("%d,%d,%d" % [c.x, c.y, c.z]):
				grounded = true
				break
		if not grounded:
			orphans.append(Vector3i(ax, ay, az))
	for o in orphans:
		_detach_one(o.x, o.y, o.z)

# Оторвать блок в мир: снять сигналы разрушения (чтобы гибель уже свободного блока не трогала
# карту машины), очистить карту, и поручить машине уронить узел (коллизия + репарент + импульс).
func _detach_one(ax: int, ay: int, az: int) -> void:
	var anchor := "%d,%d,%d" % [ax, ay, az]
	var node: Node = node_map.get(anchor, null)
	if node != null and is_instance_valid(node) and node.has_signal("destroyed"):
		for con in node.destroyed.get_connections():
			node.destroyed.disconnect(con["callable"])
	remove_block(ax, ay, az)                       # чистит карту, сам узел НЕ трогает
	if node == null or not is_instance_valid(node):
		return
	var veh := get_parent()
	if veh != null and veh.has_method("detach_block_to_world"):
		veh.detach_block_to_world(node)

# ══════════════════════════════════════════════════════════════════════════════
# СОХРАНЕНИЕ / ЗАГРУЗКА
# ══════════════════════════════════════════════════════════════════════════════

func save_layout() -> void:
	var blocks_array: Array = []
	for x in range(MAP_SIZE_X):
		for y in range(MAP_SIZE_Y):
			for z in range(MAP_SIZE_Z):
				var block: G.Block = map[x][y][z]
				if block != G.Block.EMPTY and _is_anchor(x, y, z):
					var key: String = "%d,%d,%d" % [x, y, z]
					blocks_array.append({
						"x": x,
						"y": y,
						"z": z,
						"block": G.block_key(block),
						"rot": _rot_array(rotation_map.get(key, Vector3.ZERO))
					})

	var json_string: String = JSON.stringify(blocks_array, "\t")
	var file: FileAccess = FileAccess.open(SAVE_PATH, FileAccess.WRITE)
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

	var file: FileAccess = FileAccess.open(SAVE_PATH, FileAccess.READ)
	var json: JSON = JSON.new()
	json.parse(file.get_as_text())
	file.close()

	var blocks_array = json.get_data()
	for entry in blocks_array:
		set_block(int(entry["x"]), int(entry["y"]), int(entry["z"]), G.block_from_key(entry["block"]), _read_rot(entry))

	_spawn_all()
	print("Машина загружена!")

func get_layout() -> Array:
	var blocks_array: Array = []
	for x in range(MAP_SIZE_X):
		for y in range(MAP_SIZE_Y):
			for z in range(MAP_SIZE_Z):
				var block: G.Block = map[x][y][z]
				if block != G.Block.EMPTY and _is_anchor(x, y, z):
					var key: String = "%d,%d,%d" % [x, y, z]
					blocks_array.append({
						"x": x, "y": y, "z": z,
						"block": G.block_key(block),
						"rot": _rot_array(rotation_map.get(key, Vector3.ZERO))
					})
	return blocks_array

func _rot_array(v: Vector3) -> Array:
	return [v.x, v.y, v.z]

# Читает поворот из записи раскладки: новый формат "rot":[x,y,z] или старый "rot_y":float.
func _read_rot(entry: Dictionary) -> Vector3:
	if entry.has("rot"):
		var r: Array = entry["rot"]
		return Vector3(float(r[0]), float(r[1]), float(r[2]))
	if entry.has("rot_y"):
		return Vector3(0.0, float(entry["rot_y"]), 0.0)
	return Vector3.ZERO

func apply_layout(blocks_array: Array) -> void:
	# Освобождаем только инстансы блоков (они лежат в node_map), а НЕ всех детей —
	# среди детей есть призрак постройки (blocks/MeshInstance3D, ghost_block у машины),
	# который освобождать нельзя, иначе _on_building_pressed крашится на freed-объекте.
	for inst in node_map.values():
		if is_instance_valid(inst):
			inst.queue_free()
	_clear_block_collisions()          # убираем коллизии блоков с кузова машины
	node_map.clear()
	rotation_map.clear()
	cell_owner.clear()
	_init_map()
	for entry in blocks_array:
		set_block(int(entry["x"]), int(entry["y"]), int(entry["z"]), G.block_from_key(entry["block"]), _read_rot(entry))
	_spawn_all()

# Удаляет коллизии блоков (группа block_collision) с кузова-родителя — при смене сборки,
# иначе от старой машины остаются висеть коллайдеры.
func _clear_block_collisions() -> void:
	var parent := get_parent()
	if parent == null:
		return
	for c in parent.get_children():
		if c is CollisionShape3D and c.is_in_group("block_collision"):
			c.queue_free()

# Смещение ЯКОРЯ при пристыковке блока к грани соседа. Для МНОГОКЛЕТОЧНЫХ блоков (процессор/
# продавец 2×2×2) простого ±1 мало: футпринт растёт в одну сторону, и на «положительных» гранях
# он налезал бы на соседа. Считаем сдвиг по реальным границам футпринта. Для 1×1×1 даёт ±1.
func attach_delta(block_type: int, face: String) -> Vector3i:
	var lo := Vector3i(0, 0, 0)
	var hi := Vector3i(0, 0, 0)
	for c in _block_footprint(block_type, 0, 0, 0):
		lo.x = mini(lo.x, c.x); lo.y = mini(lo.y, c.y); lo.z = mini(lo.z, c.z)
		hi.x = maxi(hi.x, c.x); hi.y = maxi(hi.y, c.y); hi.z = maxi(hi.z, c.z)
	match face:
		"right":  return Vector3i(-lo.x + 1, 0, 0)
		"left":   return Vector3i(-hi.x - 1, 0, 0)
		"top":    return Vector3i(0, -lo.y + 1, 0)
		"bottom": return Vector3i(0, -hi.y - 1, 0)
		"back":   return Vector3i(0, 0, -lo.z + 1)
		"front":  return Vector3i(0, 0, -hi.z - 1)
	return Vector3i.ZERO

# ══════════════════════════════════════════════════════════════════════════════
# ФАБРИЧНЫЕ СВЯЗИ
# ══════════════════════════════════════════════════════════════════════════════
# Куда блок отдаёт ресурс, задают ЕГО СОБСТВЕННЫЕ грани (FactoryBlock.output_faces /
# input_faces, настраиваются в инспекторе сцены блока) с учётом его поворота.
# Связь A→B есть, когда: у A грань вывода смотрит на клетку B И у B грань ввода смотрит
# навстречу. Многоклеточные блоки (2×2×2) отдают/принимают с любой своей клетки.
func rebuild_factory_links() -> void:
	var facs: Array = []
	var cells: Dictionary = {}                    # node → клетки его футпринта
	for k in node_map.keys():
		var n = node_map[k]
		if n == null or not is_instance_valid(n) or not (n is FactoryBlock):
			continue
		var parts: PackedStringArray = k.split(",")
		var ax := int(parts[0]); var ay := int(parts[1]); var az := int(parts[2])
		if not _in_bounds(ax, ay, az):
			continue
		cells[n] = _block_footprint(int(map[ax][ay][az]), ax, ay, az)
		facs.append(n)
	for n in facs:
		n.next_blocks = []
		n.next_block = null
		var own: Array = cells[n]
		# Собираем ВСЕ подключённые приёмники, а не первый попавшийся: блок может иметь
		# несколько выходов (делитель) — тогда он раздаёт по кругу (FactoryBlock.push_item).
		for d in n.face_dirs(n.output_faces):
			if d == Vector3i.ZERO:
				continue
			for c in own:
				var t: Vector3i = c + d
				if not _in_bounds(t.x, t.y, t.z):
					continue
				var nb = find_block(t.x, t.y, t.z)
				if nb == null or nb == n or not cells.has(nb):
					continue                      # не фабричный сосед — ресурс туда не идёт
				if not nb.accepts_from(d):
					continue                      # у соседа с этой стороны нет стороны ВВОДА
				if not n.next_blocks.has(nb):
					n.next_blocks.append(nb)
				break
		if not n.next_blocks.is_empty():
			n.next_block = n.next_blocks[0]
