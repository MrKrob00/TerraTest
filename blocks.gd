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

# ─── Точки контакта (к каким граням блока можно цеплять) ──────────────────────
# У каждого блока есть грани-«разъёмы». Прицепить новый блок к грани соседа можно, только
# если у СОСЕДА есть разъём на этой грани И у НОВОГО блока есть разъём на противоположной.
# Пример: пушка (разъём только снизу) ставится НА блок, но на неё — нельзя. Колесо (разъём
# слева) цепляется только справа от блока. Остальные блоки пока со всеми гранями (дополним).
const ALL_FACES := ["top", "bottom", "left", "right", "front", "back"]
const OPPOSITE := {
	"top": "bottom", "bottom": "top",
	"left": "right", "right": "left",
	"front": "back", "back": "front",
}
# G.Block.* нельзя в const (это автолоад) — строим в _ready.
var _contact_faces: Dictionary = {}

func _init_contacts() -> void:
	_contact_faces = {
		G.Block.GUN:   ["bottom"],           # пушка: контакт только снизу
		G.Block.WHEEL: ["left", "right"],    # колесо цепляется слева и справа; постройка сама
		#                                      разворачивает его по стороне (см. vehicle_body_3d)
		G.Block.DRILL: ["back"],             # бур: контакт только сзади (ставится на морду, буром вперёд)
		# остальные типы — все грани (по умолчанию); допишем по мере надобности
	}

# Грани-разъёмы блока (по умолчанию — все).
func block_faces(block_type: int) -> Array:
	return _contact_faces.get(block_type, ALL_FACES)

# Можно ли прицепить new_type к грани attach_face блока neighbor_type.
func can_attach(neighbor_type: int, new_type: int, attach_face: String) -> bool:
	if not OPPOSITE.has(attach_face):
		return true                        # нет данных о грани (первый блок и т.п.) — не мешаем
	if neighbor_type == G.Block.EMPTY:
		return true
	if not block_faces(neighbor_type).has(attach_face):
		return false                       # к этой грани соседа цеплять нельзя
	if not block_faces(new_type).has(OPPOSITE[attach_face]):
		return false                       # у нового блока нет разъёма с этой стороны
	return true

## Пресет стартовой сборки. 0 — обычная машина (как у игрока, НЕ трогаем). 1+ — варианты
## для врагов («машина из пула»). Спавнер врагов ставит случайный пресет ДО добавления в дерево.
@export var layout_preset: int = 0

func _ready() -> void:
	_init_contacts()
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
		_: _layout_default()

# Стартовая машина (спавнится бесплатно при гибели): кабина, 4 колеса, пара блоков,
# пулемёт и бур. Компактнее дефолта.
func _layout_starter() -> void:
	set_block(5, 0, 5, G.Block.CABIN, 0.0)
	set_block(4, 0, 5, G.Block.WHEEL, PI / 2)
	set_block(6, 0, 5, G.Block.WHEEL, -PI / 2)
	set_block(4, 0, 6, G.Block.WHEEL, PI / 2)
	set_block(6, 0, 6, G.Block.WHEEL, -PI / 2)
	set_block(5, 0, 6, G.Block.BLOCK, 0.0)
	set_block(5, 1, 6, G.Block.BLOCK, 0.0)
	set_block(5, 0, 4, G.Block.DRILL, 0.0)
	set_block(5, 1, 5, G.Block.GUN, 0.0)

# База: кабина, 6 колёс, дрель, пушка (стартовая машина игрока — НЕ меняем).
func _layout_default() -> void:
	_wheels_6()
	set_block(5, 0, 5, G.Block.CABIN, 0.0)
	set_block(5, 0, 4, G.Block.DRILL, 0.0)
	set_block(5, 1, 5, G.Block.GUN, 0.0)
	#set_block(5, 1, 5, G.Block.COLLECTOR, 0.0)
	#set_block(3, 1, 7, G.Block.INTAKE, -PI/2)
	#set_block(4, 1, 7, G.Block.BELT, 0.0)
	#set_block(4, 1, 6, G.Block.PROCESSOR, 0.0)
	#set_block(4, 1, 4, G.Block.BELT, 0.0)
	#set_block(4, 1, 3, G.Block.SELLER, 0.0)

# Тяжёлый: две пушки. Разнесены по длине корпуса (5 и 7, а не 5 и 6 рядом) — вес не
# наваливается на передний край базы колёс, машина реже клюёт носом при торможении/ИИ-реверсе.
func _layout_dual_gun() -> void:
	_wheels_6()
	set_block(5, 0, 5, G.Block.CABIN, 0.0)
	set_block(5, 1, 5, G.Block.GUN, 0.0)
	set_block(5, 1, 7, G.Block.GUN, 0.0)

# Разведчик: было 4 колеса на базе всего в 1 клетку — слишком короткое плечо для веса
# лазера на y=1, машину легко кидало носом вперёд. Теперь такая же 6-колёсная база, как
# у остальных пресетов (база в 2 клетки — вчетверо устойчивее к опрокидыванию по тангажу).
func _layout_laser_scout() -> void:
	_wheels_6()
	set_block(5, 0, 5, G.Block.CABIN, 0.0)
	set_block(5, 1, 5, G.Block.LASER, 0.0)

func _wheels_6() -> void:
	set_block(4, 0, 5, G.Block.WHEEL, PI / 2)
	set_block(6, 0, 5, G.Block.WHEEL, -PI / 2)
	set_block(4, 0, 6, G.Block.WHEEL, PI / 2)
	set_block(6, 0, 6, G.Block.WHEEL, -PI / 2)
	set_block(4, 0, 7, G.Block.WHEEL, PI / 2)
	set_block(6, 0, 7, G.Block.WHEEL, -PI / 2)

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

	# ── Подключаем сигнал уничтожения ─────────────────────────────
	if instance.has_signal("destroyed"):
		instance.destroyed.connect(_on_block_destroyed.bind(x, y, z))

	var key := "%d,%d,%d" % [x, y, z]
	var rot: Vector3 = rotation_map.get(key, Vector3.ZERO)
	instance.rotation = rot

	var collision = instance.get_child(0).duplicate()
	collision.position = Vector3(x - 5, y, z - 5)
	collision.rotation = rot                     # коллизия наклоняется вместе с блоком
	if collision.shape.size == Vector3(2,2,2):
		collision.position += Vector3(-0.5,0.5,-0.5)
	if !get_parent().is_node_ready():
		await get_parent().ready
	get_parent().add_child(collision)
	collision.add_to_group("block_collision")   # чтобы смена сборки могла их убрать
	node_map[key] = instance

	instance.position = Vector3(
		(x - MAP_SIZE_X / 2.0) * CELL_SIZE,
		y * CELL_SIZE,
		(z - MAP_SIZE_Z / 2.0) * CELL_SIZE
	)

	# Эффект «матрицы»-появления — только когда машина строится с НУЛЯ (spawn_block зовётся
	# лишь из _spawn_all: первая машина / загрузка / смена сборки). При ручной постановке
	# блока его больше не играем (см. vehicle_body_3d._on_take_pressed).
	BlockFX.play(instance, false)

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
						"rot": _rot_array(rotation_map.get(key, Vector3.ZERO))
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
		set_block(int(entry["x"]), int(entry["y"]), int(entry["z"]), int(entry["block"]), _read_rot(entry))

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
						"rot": _rot_array(rotation_map.get(key, Vector3.ZERO))
					})
	return blocks_array

func _rot_array(v: Vector3) -> Array:
	return [v.x, v.y, v.z]

# Читает поворот из записи раскладки: новый формат "rot":[x,y,z] или старый "rot_y":float.
func _read_rot(entry: Dictionary) -> Vector3:
	if entry.has("rot"):
		var r = entry["rot"]
		return Vector3(float(r[0]), float(r[1]), float(r[2]))
	if entry.has("rot_y"):
		return Vector3(0.0, float(entry["rot_y"]), 0.0)
	return Vector3.ZERO

func apply_layout(blocks_array: Array) -> void:
	for child in get_children():
		child.queue_free()
	_clear_block_collisions()          # убираем коллизии блоков с кузова машины
	node_map.clear()
	rotation_map.clear()
	cell_owner.clear()
	_init_map()
	for entry in blocks_array:
		set_block(int(entry["x"]), int(entry["y"]), int(entry["z"]), int(entry["block"]), _read_rot(entry))
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
