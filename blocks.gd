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

## Пускает ли УЖЕ СТОЯЩИЙ блок соседа к своей грани face. Грани берём повёрнутыми и
## ПОКЛЕТОЧНО (VehicleBlock.connects_at): блок на машине развёрнут, «зад» у него смотрит
## куда угодно, а у крупного блока каждая клетка стороны может решать за себя.
##
## cell — клетка, к которой пристыковываются (у обычного блока она же и якорь).
func node_accepts_face(node: Node, face: String, cell: Vector3i = Vector3i.ZERO) -> bool:
	if node == null or not is_instance_valid(node) or not (node is VehicleBlock):
		return true                        # не блок (или уже уничтожен) — не мешаем
	if not FACE_DIR.has(face):
		return true
	return (node as VehicleBlock).connects_at(cell - _anchor_of(cell), FACE_DIR[face] as Vector3i)

# Можно ли прицепить new_type к грани attach_face блока neighbor_type.
# true, если структура — стационарная база (ставит vehicle при спавне с якорным ядром).
var is_station: bool = false

# Что можно ставить на СТАЦИОНАРНУЮ базу. Запрещено ровно то, что базе физически не нужно:
# КАБИНА (у базы своё ядро, вторая сделала бы из неё машину) и КОЛЁСА (база не едет).
#
# Оружие раньше тоже было в запрете, и это была ошибка проектирования, а не защита: игру
# просят оборонять СВОЮ базу (квест «Hold the Line»), а поставить на неё турель было нельзя.
# Опоры тоже были запрещены — и это противоречило самому себе с тех пор, как опора стала
# СТАЦИОНАРНЫМ блоком (G.STATIONARY_BLOCKS), то есть возможным ядром базы: на базу из опоры
# нельзя было поставить вторую опору.
# Всё остальное — фабрика, броня, каркас, энергетика, оружие — на базе осмысленно.
const _STATION_BANNED := [G.Block.CABIN, G.Block.WHEEL, G.Block.SMALL_WHEEL, G.Block.BIG_WHEEL,
		G.Block.TOP_WHEEL, G.Block.STAB_WHEEL]

func _allowed_on_station(bt: int) -> bool:
	return not _STATION_BANNED.has(bt)

## Можно ли прицепить блок new_node к грани attach_face того, что стоит в клетке (nx,ny,nz).
## Клетку берём, а не тип: по ней достаём САМ УЗЕЛ соседа, а значит и его поворот — без
## поворота грань «зад» ничего не значит, блок на машине развёрнут как попало.
func can_attach(nx: int, ny: int, nz: int, new_node: Node, attach_face: String) -> bool:
	var new_type: int = int(new_node.get("block")) if new_node != null else G.Block.EMPTY
	# СТАЦИОНАРНЫЙ блок на машину — МОЖНО. Запрет был лишним: такой блок и так работает
	# только под якорем (_factory_active), а машина, которая его везёт, получает право
	# вставать на якорь (vehicle_body_3d.has_stationary). Возить продавца с собой и
	# останавливаться, чтобы продать, — нормальная игра, а не обход правила.
	# На стационарную базу — только разрешённые типы (3Б).
	if is_station and not _allowed_on_station(new_type):
		return false
	# У НОВОГО блока грань не проверяем: постройка сама доворачивает его отмеченной стороной
	# к соседу (_face_orient), поэтому «стыковаться нужной гранью» выполнимо на любой грани.
	# Не может он только одного — если галочек не стоит вовсе.
	if new_node is VehicleBlock and (new_node as VehicleBlock).connect_faces == 0:
		return false
	# А вот СОСЕД решает, пускать ли к своей грани: на коронку бура ничего не навесить.
	return node_accepts_face(find_block(nx, ny, nz), attach_face, Vector3i(nx, ny, nz))

## Пресет стартовой сборки. 0 — обычная машина (как у игрока, НЕ трогаем). 1+ — варианты
## для врагов («машина из пула»). Спавнер врагов ставит случайный пресет ДО добавления в дерево.
@export var layout_preset: int = 0

# ЧТО ПРОИЗВОДИТ фабричный блок, стоящий в этой клетке: "x,y,z" → номер (G.Comp у
# компонентного завода, G.Block у фабрикатора). Живёт ЗДЕСЬ, а не только на самом узле,
# по одной причине: настройка обязана пережить сохранение. Раскладка машины хранит клетки,
# а не узлы, и выбор игрока, оставшись полем экземпляра, сбрасывался бы при каждой загрузке
# на значение из сцены — то есть каждый вход в игру возвращал бы завод к первому компоненту.
var output_map: Dictionary = {}

# ПОРТЫ фабричных блоков: "x,y,z" клетки-якоря → словарь портов этого блока
# (FactoryBlock.ports). Здесь по той же причине, что и output_map: настройка игрока обязана
# пережить сейв, а раскладка хранит клетки, не узлы.
var port_map: Dictionary = {}

# ЗАРЯД АККУМУЛЯТОРА, стоящего в этой клетке: "x,y,z" → сколько в нём энергии. Здесь по той
# же причине, что output_map и port_map: заряд — свойство БЛОКА (battery.gd), а сейв хранит
# клетки, не узлы. Без этой карты полный аккумулятор возвращался бы после перезахода пустым,
# то есть ровно тем же способом, каким он раньше пустел при снятии с машины.
var charge_map: Dictionary = {}

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
		5: _layout_scout()
		6: _layout_runner()
		7: _layout_raider()
		8: _layout_lancer()
		9: _layout_breaker()
		10: _layout_siege()
		11: _layout_outpost()
		12: _layout_fort()
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

# ══════════════════════════════════════════════════════════════════════════════
# СБОРКИ ВРАГОВ: от мелкой до тяжёлой (пресеты 5..10)
# ══════════════════════════════════════════════════════════════════════════════
# Порядок — по ОПАСНОСТИ и по размеру сразу: чем дальше по списку, тем машина крупнее,
# бронированнее и злее. Спавнер выбирает ступень по стоимости машины игрока
# (enemy_spawner._pick_preset), а стоимость убитой машины превращается в ДИ (G.rp_for_kill),
# поэтому «крупнее» здесь автоматически значит «дороже и ценнее как добыча».
#
# ТОЛЬКО ОДНОКЛЕТОЧНЫЕ блоки. У 2×1×1 и 2×1×2 в карте занята одна клетка, а коллизия шире —
# соседний блок налезал бы на неё корпусом. Разбираться с этим в шести сборках сразу незачем:
# броня ARMOR и так 1³, а размер набирается количеством, а не габаритом блока.
#
# Энергетику врагам не ставим намеренно: солнечная панель питает только машину НА ЯКОРЕ
# (поле anchored есть лишь у игрока), генератор просит топливо по фабричной цепочке, и
# реген со щитом на враге просто не заработали бы. Сложность набирается бронёй и стволами.

# Разведчик: самый мелкий. Четыре малых колеса, один ствол, корпус в две клетки.
func _layout_scout() -> void:
	set_block(5, 5, 5, G.Block.CABIN, 0.0)
	set_block(5, 5, 6, G.Block.BLOCK, 0.0)
	_side_wheels(G.Block.SMALL_WHEEL, [5, 6])
	set_block(5, 6, 5, G.Block.GUN, 0.0)          # низом на кабину

# Бегун: те же габариты, но полноразмерные колёса и дробовик — заставляет подпускать близко.
func _layout_runner() -> void:
	set_block(5, 5, 5, G.Block.CABIN, 0.0)
	set_block(5, 5, 6, G.Block.BLOCK, 0.0)
	_front_armor()                                # лоб прикрыт: в упор он и живёт
	_side_wheels(G.Block.WHEEL, [5, 6])
	set_block(5, 6, 5, G.Block.SHOTGUN, 0.0)

# Рейдер: шесть колёс, две пушки, борта в броне. Первая машина, которую нельзя перестрелять
# на подъезде — приходится маневрировать.
func _layout_raider() -> void:
	set_block(5, 5, 5, G.Block.CABIN, 0.0)
	set_block(5, 5, 6, G.Block.BLOCK, 0.0)
	set_block(5, 5, 7, G.Block.BLOCK, 0.0)
	_side_wheels(G.Block.WHEEL, [5, 6, 7])
	set_block(5, 6, 6, G.Block.BLOCK, 0.0)        # второй этаж — к нему и крепятся борта
	_side_armor(6)
	set_block(5, 6, 5, G.Block.GUN, 0.0)
	set_block(5, 6, 7, G.Block.GUN, 0.0)

# Копейщик: лазер держит на дистанции, пушка добивает вблизи. Брони заметно больше.
func _layout_lancer() -> void:
	set_block(5, 5, 5, G.Block.CABIN, 0.0)
	set_block(5, 5, 6, G.Block.BLOCK, 0.0)
	set_block(5, 5, 7, G.Block.BLOCK, 0.0)
	_front_armor()
	_side_wheels(G.Block.WHEEL, [5, 6, 7])
	set_block(5, 6, 6, G.Block.BLOCK, 0.0)
	_side_armor(6)
	set_block(5, 6, 5, G.Block.LASER, 0.0)
	set_block(5, 6, 7, G.Block.GUN, 0.0)

# Таран: большие колёса, тяжёлая пушка и две обычных. Уже КРУПНАЯ машина — заметна издалека.
func _layout_breaker() -> void:
	set_block(5, 5, 5, G.Block.CABIN, 0.0)
	set_block(5, 5, 6, G.Block.BLOCK, 0.0)
	set_block(5, 5, 7, G.Block.BLOCK, 0.0)
	_side_wheels(G.Block.BIG_WHEEL, [5, 6, 7])
	set_block(5, 6, 6, G.Block.BLOCK, 0.0)        # второй этаж целиком: на нём стволы и борта
	set_block(5, 6, 7, G.Block.BLOCK, 0.0)
	_side_armor(6)
	_side_armor(7)
	set_block(5, 6, 5, G.Block.POUND_CANNON, 0.0)
	set_block(5, 7, 6, G.Block.GUN, 0.0)
	set_block(5, 7, 7, G.Block.GUN, 0.0)

# Осадная: самая большая. Восемь колёс, мортира навесом, ракетница и пара стволов, борта и
# лоб в броне. Встреча с такой — событие, а не рядовая стычка.
func _layout_siege() -> void:
	set_block(5, 5, 5, G.Block.CABIN, 0.0)
	for z in [6, 7, 8]:
		set_block(5, 5, z, G.Block.BLOCK, 0.0)
		set_block(5, 6, z, G.Block.BLOCK, 0.0)
	_front_armor()
	_side_armor(6)
	_side_armor(7)
	_side_wheels(G.Block.WHEEL, [5, 6, 7, 8])
	set_block(5, 6, 5, G.Block.MORTAR, 0.0)
	set_block(5, 7, 7, G.Block.ROCKET, 0.0)
	set_block(5, 7, 6, G.Block.GUN, 0.0)
	set_block(5, 7, 8, G.Block.GUN, 0.0)

## Колёса по бортам корпуса. Повороты НЕ на глаз: у всех колёс connect_faces = 2, то есть
## стыкуются они ЗАДОМ (+Z), и к корпусу их надо развернуть именно им. Поворот на ±90° по Y
## переводит +Z в ∓X — левый борт смотрит вправо, правый влево, оба в корпус.
func _side_wheels(kind: int, zs: Array) -> void:
	for z in zs:
		set_block(4, 5, int(z), kind, PI / 2)
		set_block(6, 5, int(z), kind, -PI / 2)

## Пара бортовых пластин на ВТОРОЙ ЭТАЖ, в клетку z. Плита стыкуется ЗАДОМ, как колесо
## (connect_faces = 2), поэтому её так же доворачивают к корпусу: без поворота её единственная
## грань смотрела бы в пустоту наружу, и связность (_reachable_cells) считала бы плиту
## оторванной — при рождении машины она просто падала бы на землю.
##
## Клетка (5, 6, z) обязана быть КОРПУСОМ: у ствола connect_faces = 32 (только низ), к его
## борту не крепится ничего.
func _side_armor(z: int) -> void:
	set_block(4, 6, z, G.Block.ARMOR, PI / 2)
	set_block(6, 6, z, G.Block.ARMOR, -PI / 2)

## Лобовая пластина перед кабиной. Поворот нулевой: её задняя грань (+Z) и так смотрит в
## кабину — та принимает соседей всеми сторонами.
func _front_armor() -> void:
	set_block(5, 5, 4, G.Block.ARMOR, 0.0)

## ВРАЖЕСКИЕ БАЗЫ (пресеты 11-12). Ядро — ОПОРА, а не кабина: база не едет, и держится она
## тем же, чем наша (G.STATIONARY_BLOCKS). Кабины у неё нет намеренно — смерть базы решает
## сторож ядра в MachineBody, ровно как у станции игрока.
##
## Колёс нет вовсе, поэтому корпус можно тянуть в стороны свободно; зато стволы, как и везде,
## стыкуются ТОЛЬКО низом (connect_faces = 32) — значит каждый стоит НА блоке, а не в воздухе.
## Броня стыкуется задом (+Z), отсюда те же ±90° по бортам, что и у машин.

## Аванпост: опора, пара блоков, два ствола и борта. Первая база, которую встретит игрок.
func _layout_outpost() -> void:
	set_block(5, 5, 5, G.Block.SUPPORT, 0.0)
	set_block(5, 5, 6, G.Block.BLOCK, 0.0)
	set_block(5, 5, 4, G.Block.BLOCK, 0.0)
	set_block(5, 6, 5, G.Block.BLOCK, 0.0)
	_side_armor(5)
	set_block(5, 7, 5, G.Block.GUN, 0.0)
	set_block(5, 6, 6, G.Block.GUN, 0.0)

## Форт: шире, выше, с ракетницей и аккумулятором. Аккумулятор здесь не для энергии (базе она
## не нужна), а ради взрыва: добить форт в упор должно быть опасно.
func _layout_fort() -> void:
	set_block(5, 5, 5, G.Block.SUPPORT, 0.0)
	for z in [4, 6]:
		set_block(5, 5, z, G.Block.BLOCK, 0.0)
		set_block(5, 6, z, G.Block.BLOCK, 0.0)
	set_block(4, 5, 5, G.Block.BLOCK, 0.0)
	set_block(6, 5, 5, G.Block.BLOCK, 0.0)
	set_block(5, 6, 5, G.Block.BATTERY, 0.0)
	_side_armor(4)
	_side_armor(6)
	set_block(5, 7, 4, G.Block.GUN, 0.0)
	set_block(5, 7, 6, G.Block.ROCKET, 0.0)
	set_block(4, 6, 5, G.Block.GUN, PI / 2)
	set_block(6, 6, 5, G.Block.GUN, -PI / 2)

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
	if block == G.Block.ARMOR4:
		var cells4: Array = []               # 2×1×2 (xyz), как у COAL_GEN
		for dx in [-1, 0]:
			for dz in [-1, 0]:
				cells4.append(Vector3i(x + dx, y, z + dz))
		return cells4
	if block == G.Block.COAL_GEN:
		var cells2: Array = []               # 2×1×2 (xyz): dx∈[-1,0], dy=0, dz∈[-1,0]
		for dx in [-1, 0]:
			for dz in [-1, 0]:
				cells2.append(Vector3i(x + dx, y, z + dz))
		return cells2
	if block == G.Block.BLOCK2 or block == G.Block.WEDGE2 \
			or block == G.Block.ARMOR2 or block == G.Block.HALF_BLOCK2:
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
	output_map.erase(anchor)
	port_map.erase(anchor)
	charge_map.erase(anchor)

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
	var n = node_map.get(anchor, null)
	# УЗЕЛ МОГ БЫТЬ УЖЕ УДАЛЁН, а запись о нём в карте — остаться: блок гибнет через
	# queue_free, и путей к этому несколько (взрыв, разбор, смена сборки). Ссылка на
	# освобождённый узел НЕ равна null, и возврат её из типизированной функции роняет вызов
	# («Trying to return a previously freed instance») — именно так падал обход связности
	# после отрыва блоков. Заодно ЧИСТИМ запись: иначе следующий вызов споткнётся о неё же.
	if n != null and not is_instance_valid(n):
		node_map.erase(anchor)
		return null
	return n

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

	# Коллизию ищем ПЕРЕБОРОМ, а не по первому ребёнку: порядок узлов в сцене блока меняют,
	# не задумываясь, и промах здесь ронял бы спавн всей сборки (та же грабля, что в
	# vehicle_body_3d._first_collision).
	var src_col: CollisionShape3D = null
	for ch in instance.get_children():
		var cs := ch as CollisionShape3D
		if cs != null and cs.shape != null:
			src_col = cs
			break
	if src_col == null:
		push_error("blocks: у блока %s нет CollisionShape3D" % G.block_name(int(instance.get("block"))))
		return
	var collision: CollisionShape3D = src_col.duplicate()
	collision.position = Vector3(x - CENTER, y - CENTER, z - CENTER)
	collision.rotation = rot                     # коллизия наклоняется вместе с блоком
	# Смещение только у КОРОБОК: у любой другой формы поля .size нет, и обращение к нему
	# оборвало бы спавн на полпути.
	var box: BoxShape3D = collision.shape as BoxShape3D
	if box != null:
		if box.size == Vector3(2,2,2):
			collision.position += Vector3(-0.5,0.5,-0.5)
		elif box.size == Vector3(2,1,1):
			collision.position += Vector3(-0.5,0.0,0.0)   # BLOCK2: центрируем 2-широкую коллизию
		elif box.size == Vector3(2,1,2):
			collision.position += Vector3(-0.5,0.0,-0.5)  # COAL_GEN: 2×1×2
	if !get_parent().is_node_ready():
		await get_parent().ready
	get_parent().add_child(collision)
	collision.add_to_group("block_collision")   # чтобы смена сборки могла их убрать
	node_map[key] = instance
	_apply_output(instance, key)

	instance.position = Vector3(
		(x - CENTER) * CELL_SIZE,
		(y - CENTER) * CELL_SIZE,
		(z - CENTER) * CELL_SIZE
	)

	# Эффект «матрицы»-появления — только когда машина строится с НУЛЯ (spawn_block зовётся
	# лишь из _spawn_all: первая машина / загрузка / смена сборки). При ручной постановке
	# блока его больше не играем (см. vehicle_body_3d._on_take_pressed).
	BlockFX.play(instance, false)

# Проставить блоку сохранённый выбор продукта. Имя поля разное у двух фабрик, поэтому
# проверяем оба: общего интерфейса у них нет и заводить его ради одного числа незачем.
func _apply_output(inst: Node, key: String) -> void:
	if charge_map.has(key) and inst != null and ("charge" in inst):
		inst.set("charge", float(charge_map[key]))     # аккумулятор родился с сохранённым зарядом
	if inst is FactoryBlock and port_map.has(key):
		(inst as FactoryBlock).ports = (port_map[key] as Dictionary).duplicate()
	if not output_map.has(key) or inst == null:
		return
	var v: int = int(output_map[key])
	if "output_comp" in inst:
		inst.set("output_comp", v)
	elif "output_block" in inst:
		inst.set("output_block", v)

## Смещения клеток блока от его якоря. Одна клетка — обычный блок, восемь — 2×2×2.
## Публично: по ним окно портов (port_picker) рисует стороны, а считать футпринт заново на
## стороне UI значило бы завести вторую копию правила о размерах блоков.
func footprint_offsets(inst: Node) -> Array:
	var key: String = cell_of_node(inst)
	if key == "":
		return []
	var parts: PackedStringArray = key.split(",")
	var ax := int(parts[0]); var ay := int(parts[1]); var az := int(parts[2])
	if not _in_bounds(ax, ay, az):
		return []
	var anchor := Vector3i(ax, ay, az)
	var out: Array = []
	for c in _block_footprint(int(map[ax][ay][az]), ax, ay, az):
		out.append((c as Vector3i) - anchor)
	return out

## Клетка, в которой стоит этот узел ("x,y,z"), или "" — узел не наш.
func cell_of_node(inst: Node) -> String:
	for k in node_map:
		if node_map[k] == inst:
			return String(k)
	return ""

## Задать порт фабричному блоку: и узлу сейчас, и карте — чтобы пережило сейв.
## state: FactoryBlock.PORT_NONE / PORT_IN / PORT_OUT.
func set_block_port(inst: Node, off: Vector3i, dir_idx: int, state: int) -> bool:
	if not (inst is FactoryBlock):
		return false
	var key: String = cell_of_node(inst)
	if key == "":
		return false
	var fb := inst as FactoryBlock
	fb.set_port(off, dir_idx, state)
	port_map[key] = fb.ports.duplicate()
	rebuild_factory_links()          # цепочка меняется прямо сейчас, а не при следующей правке
	return true

## Задать фабричному блоку, ЧТО он производит: и узлу сейчас, и карте — чтобы пережило сейв.
## Возвращает false, если узел не наш или это вообще не фабрика с выбором.
func set_factory_output(inst: Node, value: int) -> bool:
	var key: String = cell_of_node(inst)
	if key == "":
		return false
	if "output_comp" in inst:
		inst.set("output_comp", value)
	elif "output_block" in inst:
		inst.set("output_block", value)
	else:
		return false
	output_map[key] = value
	if inst.has_method("reload_recipe"):
		inst.reload_recipe()            # фабрика пересобирает рецепт под новый продукт
	return true

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
# добирается до корня, — оторвано. Один BFS ловит сразу целый оторванный кусок.
#
# ПО ТОЧКАМ СТЫКОВКИ, а не просто по соприкосновению. Раньше обход шёл по любым соседним
# занятым клеткам, и грани в нём не участвовали вовсе — из-за чего сбитый снизу ствол
# ОСТАВАЛСЯ ВИСЕТЬ: он касался боком какого-нибудь блока, обход это засчитывал за связь, и
# блок не считался оторванным. А по правилам стыковки связи там нет: у ствола отмечен только
# низ, и вбок он не крепится ни к чему.
#
# Условие ребра то же, что и у постройки (can_attach): направление d должно быть среди
# граней стыковки А, и обратное −d — среди граней B. Односторонней связи не бывает.
const BFS_DIRS := [Vector3i(1,0,0), Vector3i(-1,0,0), Vector3i(0,1,0),
		Vector3i(0,-1,0), Vector3i(0,0,1), Vector3i(0,0,-1)]

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
	while not queue.is_empty():
		var c: Vector3i = queue.pop_back()
		var a: Node = find_block(c.x, c.y, c.z)
		for d in BFS_DIRS:
			var n: Vector3i = c + d
			if not _in_bounds(n.x, n.y, n.z):
				continue
			if map[n.x][n.y][n.z] == G.Block.EMPTY:
				continue
			var nk := "%d,%d,%d" % [n.x, n.y, n.z]
			if seen.has(nk):
				continue
			if not _cells_linked(a, find_block(n.x, n.y, n.z), c, n, d):
				continue
			seen[nk] = true
			queue.append(n)
	return seen

## Есть ли РЕАЛЬНАЯ стыковка между соседними КЛЕТКАМИ ca и cb в направлении d.
##
## Спрашиваем именно клетки, а не блоки: у блока крупнее одной клетки сторона состоит из
## нескольких клеток, и «стыкуется левой стороной» больше не значит «всеми левыми клетками
## сразу» (см. VehicleBlock.connects_at). У обычного блока клетка и есть сторона, поэтому
## для него ответ тот же, что и был.
func _cells_linked(a: Node, b: Node, ca: Vector3i, cb: Vector3i, d: Vector3i) -> bool:
	if a == b:
		return true                        # две клетки одного многоклеточного блока
	if a == null or b == null:
		return true                        # узла нет (ещё не заспавнен) — не рвём связь на пустом месте
	if not (a is VehicleBlock) or not (b is VehicleBlock):
		return true
	return (a as VehicleBlock).connects_at(ca - _anchor_of(ca), d) \
			and (b as VehicleBlock).connects_at(cb - _anchor_of(cb), -d)

## Якорная клетка, которой принадлежит клетка c. Смещение от неё и есть «какая это клетка
## блока» — тот же ключ, которым описаны поклеточные настройки.
func _anchor_of(c: Vector3i) -> Vector3i:
	var key := "%d,%d,%d" % [c.x, c.y, c.z]
	var anchor: String = cell_owner.get(key, key)
	var parts: PackedStringArray = anchor.split(",")
	if parts.size() < 3:
		return c
	return Vector3i(int(parts[0]), int(parts[1]), int(parts[2]))

func _detach_orphans() -> void:
	if node_map.is_empty():
		return
	var reachable := _reachable_cells()
	if reachable.is_empty():
		return   # корня нет (кабина/база уничтожена) — этим займётся смерть машины (MachineBody.scatter_blocks)
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

## Сорвать в мир КОНКРЕТНЫЙ узел блока. Зовёт сам блок, когда его добили почти до нуля и
## крепления не держат (VehicleBlock._check_critical). Клетку ищем по node_map: блок своих
## координат не знает, а карта и так хранит обратную связь якорь → узел.
##
## Отрывать откладываем на конец кадра: срыв идёт из hurt(), а hurt зовут прямо из обхода
## физики (AOE-взрыв перебирает тела запросом к пространству) — репарент и снятие коллизии
## посреди такого обхода трогают физический сервер, когда он занят.
func detach_node(node: Node) -> void:
	if node == null or not is_instance_valid(node):
		return
	for anchor in node_map.keys():
		if node_map[anchor] != node:
			continue
		var parts: PackedStringArray = String(anchor).split(",")
		if parts.size() < 3:
			return
		call_deferred("_detach_one", int(parts[0]), int(parts[1]), int(parts[2]))
		# И следом пересчёт: на сорвавшемся блоке могло висеть полмашины (call_deferred —
		# очередь, поэтому пересчёт пойдёт уже ПОСЛЕ срыва).
		if not _rebuild_queued:
			_rebuild_queued = true
			call_deferred("_deferred_rebuild")
		return

# Оторвать блок в мир: снять сигналы разрушения (чтобы гибель уже свободного блока не трогала
# карту машины), очистить карту, и поручить машине уронить узел (коллизия + репарент + импульс).
func _detach_one(ax: int, ay: int, az: int) -> void:
	# КАБИНУ НЕ РОНЯЕМ НИКОГДА. Она корень, на котором держится вся сборка, а у сорванного
	# блока рвутся подписки на его гибель (ниже) — вместе они означали машину без корня и без
	# сигнала смерти: остальное осыпалось как оторванное, а живой пустой корпус продолжал
	# ездить, и убить его было нечем.
	if _in_bounds(ax, ay, az) and map[ax][ay][az] == G.Block.CABIN:
		return
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
					var entry: Dictionary = {
						"x": x, "y": y, "z": z,
						"block": G.block_key(block),
						"rot": _rot_array(rotation_map.get(key, Vector3.ZERO))
					}
					# "out" пишем ТОЛЬКО у фабрик, которым его меняли: лишнее поле в каждой
					# из полусотни клеток раздуло бы сейв ради значения по умолчанию.
					if output_map.has(key):
						entry["out"] = int(output_map[key])
					# Порты пишем ТОЛЬКО у блоков, где игрок их менял: у остальных работает
					# правило по умолчанию (маски граней), и хранить пустоту незачем.
					if port_map.has(key) and not (port_map[key] as Dictionary).is_empty():
						entry["ports"] = port_map[key]
					# Заряд спрашиваем У ЖИВОГО УЗЛА: он тратится и копится каждую секунду, а
					# карта — лишь то, с чем блок родился. Пустой аккумулятор поля не пишет.
					var bnode: Node = node_map.get(key)
					if bnode != null and is_instance_valid(bnode) and ("charge" in bnode) \
							and float(bnode.get("charge")) > 0.01:
						entry["chg"] = float(bnode.get("charge"))
					blocks_array.append(entry)
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
	output_map.clear()
	port_map.clear()
	charge_map.clear()
	for entry in blocks_array:
		set_block(int(entry["x"]), int(entry["y"]), int(entry["z"]), G.block_from_key(entry["block"]), _read_rot(entry))
		# Выбор продукта кладём в карту ДО _spawn_all: узлы читают его при рождении.
		if entry.has("out"):
			output_map["%d,%d,%d" % [int(entry["x"]), int(entry["y"]), int(entry["z"])]] = int(entry["out"])
		if entry.has("ports") and entry["ports"] is Dictionary:
			port_map["%d,%d,%d" % [int(entry["x"]), int(entry["y"]), int(entry["z"])]] = entry["ports"]
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
	var anchors: Dictionary = {}                  # node → его якорная клетка
	for k in node_map.keys():
		var n = node_map[k]
		if n == null or not is_instance_valid(n) or not (n is FactoryBlock):
			continue
		var parts: PackedStringArray = k.split(",")
		var ax := int(parts[0]); var ay := int(parts[1]); var az := int(parts[2])
		if not _in_bounds(ax, ay, az):
			continue
		cells[n] = _block_footprint(int(map[ax][ay][az]), ax, ay, az)
		anchors[n] = Vector3i(ax, ay, az)     # смещения клеток считаем от якоря
		facs.append(n)
	# Связи считаются ПОКЛЕТОЧНО. Раньше перебирались отмеченные ГРАНИ блока, и для каждой
	# брался ПЕРВЫЙ подходящий сосед по всему футпринту (там стоял break). У односкеточного
	# блока разницы нет, а у 2×2×2 сторона это четыре клетки: подвести к ней две разные ленты
	# было нельзя — вторая молча игнорировалась, потому что первая уже «заняла» грань.
	#
	# Теперь пара «клетка + направление» рассматривается сама по себе, и обе стороны обязаны
	# согласиться: у нас в этой клетке ВЫХОД, у соседа в его клетке ВХОД навстречу.
	for n in facs:
		n.next_blocks = []
		n.next_block = null
		var own: Array = cells[n]
		var anchor: Vector3i = anchors.get(n, Vector3i.ZERO)
		for c in own:
			var off: Vector3i = c - anchor
			for di in 6:
				var d: Vector3i = n.dir_of(di)
				if d == Vector3i.ZERO or not n.outputs_at(off, d):
					continue
				var t: Vector3i = c + d
				if not _in_bounds(t.x, t.y, t.z):
					continue
				var nb = find_block(t.x, t.y, t.z)
				if nb == null or nb == n or not cells.has(nb):
					continue                      # не фабричный сосед — ресурс туда не идёт
				# У СОСЕДА спрашиваем про ЕГО клетку: у многоклеточного блока вход может быть
				# в одной клетке стороны и отсутствовать в соседней.
				if not nb.accepts_at(t - Vector3i(anchors.get(nb, t)), d):
					continue                      # у соседа в этой клетке нет входа навстречу
				if not n.next_blocks.has(nb):
					n.next_blocks.append(nb)
		if not n.next_blocks.is_empty():
			n.next_block = n.next_blocks[0]
