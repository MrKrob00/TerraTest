# vehicle_block.gd
class_name VehicleBlock
extends RigidBody3D

@export var block: G.Block

## ЗАПОЛНЯЕТ ЛИ БЛОК СВОЮ КЛЕТКУ ЦЕЛИКОМ. По ней машина решает, что рисовать: замурованный
## со всех сторон блок не рисуется вовсе (blocks._apply_occlusion), а «замурован» считается
## заливкой снаружи — сквозь НЕПОЛНЫЙ сосед (колесо, лента, ствол, половинка) взгляд проходит,
## и закрытым он ничего не делает.
##
## По умолчанию НЕТ, и это нарочно: цена ошибки несимметрична. Ошибиться в «нет» — один лишний
## нарисованный куб; ошибиться в «да» — дыра в корпусе, сквозь которую видно небо.
@export var solid_cell: bool = false

# ── ATTACH FACES ─────────────────────────────────────────────────────────────
# Which of its own sides this block joins with. Given in the block's OWN axes and rotating with it:
#   front = -Z, back = +Z, right = +X, left = -X, top = +Y, bottom = -Y
#
# The same list works both ways: building rotates the block so a marked face meets the neighbour,
# and a neighbour may attach ONLY to a marked face (nothing mounts on a drill head). Default is all
# six.
#
# EDITED ONLY ON THE CUBE WIDGET (addons/blockfaces), hence @export_storage rather than
# @export_flags: a second set of checkboxes for the same number is a second control that drifts,
# and "Left" requires remembering which way the block faces - the cube exists to answer that.
@export_storage var connect_faces: int = FACE_ALL   ## Стороны, которыми блок стыкуется с соседями

const FACE_FRONT  := 1
const FACE_BACK   := 2
const FACE_LEFT   := 4
const FACE_RIGHT  := 8
const FACE_TOP    := 16
const FACE_BOTTOM := 32
const FACE_ALL    := 63

# Локальные направления сторон (в осях самого блока; поворот учитывает face_dirs).
const FACE_VECS := [
	Vector3(0, 0, -1),   # Front
	Vector3(0, 0, 1),    # Back
	Vector3(-1, 0, 0),   # Left
	Vector3(1, 0, 0),    # Right
	Vector3(0, 1, 0),    # Top
	Vector3(0, -1, 0),   # Bottom
]

# Отмеченные в маске стороны — в направлениях РОДИТЕЛЯ, с учётом поворота блока.
# Прижимаем к ближайшей оси: блок стоит по сетке, поворот кратен 90°.
func face_dirs(mask: int) -> Array:
	var out: Array = []
	for i in FACE_VECS.size():
		if mask & (1 << i) == 0:
			continue
		var v: Vector3 = (basis * FACE_VECS[i]).normalized()
		if absf(v.x) >= absf(v.y) and absf(v.x) >= absf(v.z):
			out.append(Vector3i(int(signf(v.x)), 0, 0))
		elif absf(v.y) >= absf(v.z):
			out.append(Vector3i(0, int(signf(v.y)), 0))
		else:
			out.append(Vector3i(0, 0, int(signf(v.z))))
	return out

# Стороны стыковки в ЛОКАЛЬНЫХ осях блока — по ним постройка выбирает, каким боком его
# повернуть к соседу (поворот ещё не применён, поэтому basis тут не при чём).
func connect_vecs() -> Array:
	var out: Array = []
	for i in FACE_VECS.size():
		if connect_faces & (1 << i) != 0:
			out.append(FACE_VECS[i])
	return out

# ── СТЫКОВКА ПО КЛЕТКАМ (для блоков крупнее одной клетки) ────────────────────
# Маска connect_faces — это сторона ЦЕЛИКОМ. У обычного блока сторона и есть клетка, и
# вопроса нет; а у процессора 2×2×2 сторона — это ЧЕТЫРЕ клетки, и «стыкуется левой
# стороной» означало «всеми четырьмя левыми клетками сразу». Пристыковать к нему что-то
# одной клеткой было нельзя вовсе.
#
# Поэтому у крупного блока есть УМОЛЧАНИЯ ПО КЛЕТКАМ: ключ «смещение клетки + сторона» в
# ЛОКАЛЬНЫХ осях блока, значение — стыкуется или нет. Клетка, которой в словаре нет,
# работает по маске, как и раньше, поэтому все существующие сцены ведут себя как прежде.
#
# Оси именно локальные: словарь описывает САМ БЛОК, а он поворачивается вместе с машиной.
# Перевод из осей карты в свои делает _local_side (крутим вокруг ЯКОРЯ, как сетка, меш и коллайдер).
##
## Ключ порта/стыковки: смещение клетки от якоря + индекс стороны в FACE_VECS.
static func side_key(off: Vector3i, dir_idx: int) -> String:
	return "%d,%d,%d|%d" % [off.x, off.y, off.z, dir_idx]

## Направление стороны по индексу, прижатое к оси и БЕЗ поворота блока (локальное).
func dir_of(dir_idx: int) -> Vector3i:
	if dir_idx < 0 or dir_idx >= FACE_VECS.size():
		return Vector3i.ZERO
	var v: Vector3 = FACE_VECS[dir_idx]
	return Vector3i(int(signf(v.x)), int(signf(v.y)), int(signf(v.z)))

## Индекс стороны по локальному направлению (обратное к dir_of).
func idx_of(dir: Vector3i) -> int:
	for i in FACE_VECS.size():
		if dir_of(i) == dir:
			return i
	return -1

## Клетка + сторона В ОСЯХ КАРТЫ → тот же ключ, но в СВОИХ осях блока. Пустая строка —
## такой стороны у блока нет (поворот не кратен 90°, чего быть не должно).
func _local_side(off: Vector3i, dir: Vector3i) -> String:
	var inv: Basis = basis.inverse()
	var ld: Vector3 = (inv * Vector3(dir)).round()
	var li: int = idx_of(Vector3i(int(ld.x), int(ld.y), int(ld.z)))
	if li < 0:
		return ""
	# THE CELL TURNS ABOUT THE ANCHOR, as the grid turns it (blocks._block_footprint: Basis * offset)
	# and as the mesh and the collider turn. This used to turn it about `cells_center`, which is the
	# same only at 0 deg: a two-cell block at 90 or 180 read its cells under keys that do not exist,
	# fell back to the mask, and a wedge joined on every face while the riser joined on none.
	var lo: Vector3 = (inv * Vector3(off)).round()
	return side_key(Vector3i(int(lo.x), int(lo.y), int(lo.z)), li)

## Центр футпринта В СМЕЩЕНИЯХ от якоря (у 2×2×2 это (-0.5, 0.5, -0.5)). Вокруг него
## поворачиваются поклеточные умолчания. Пишет его кубик, руками это число никто не вводит —
## оно выводится из размера блока (см. faces_editor._footprint_center).
@export_storage var cells_center := Vector3.ZERO
## Поклеточные умолчания СТЫКОВКИ: "dx,dy,dz|сторона" (локальные оси) → true/false.
## Пусто — блок целиком работает по маске connect_faces. Правит кубик; редактор словарей в
## инспекторе для такого ключа («0,1,-1|3») — способ ошибиться, а не настроить.
@export_storage var connect_defaults: Dictionary = {}

## Стыкуется ли ЭТА клетка блока в ЭТУ сторону (обе в осях карты). Порядок ответов:
## поклеточное умолчание → маска грани. Это и есть «связность по граням», просто грань у
## крупного блока теперь можно разложить на клетки.
func connects_at(off: Vector3i, dir: Vector3i) -> bool:
	if not connect_defaults.is_empty():
		var k := _local_side(off, dir)
		if k != "" and connect_defaults.has(k):
			return bool(connect_defaults[k])
	return face_dirs(connect_faces).has(dir)

## УПАКОВКА БЛОКА В ЧАНК. Живёт здесь, а не в упаковщике, чтобы правило («сколько влезает»,
## «блок другого типа начинает новый чанк») было одно на всех, кто когда-либо станет паковать.
##
## Свободный блок это RigidBody с коллизией и весом; двадцать четыре штуки на ленте — это
## двадцать четыре физических тела. В чанке на ленте всегда ОДИН предмет, сколько бы блоков в
## нём ни лежало (см. resource.gd). Правило одно на оба блока намеренно: две копии одной
## упаковки разъехались бы при первой же правке вместимости.
##
## Блок ДРУГОГО типа начинает новый чанк, а не отбрасывается: выброшенный трофей — это тихая
## потеря добычи. Возвращает true, если блок принят (и уничтожен).
const CHUNK_SCENE: String = "res://resource.tscn"
static var _chunk_scene: PackedScene = null

static func pack_block_into(inv: Array, holder: Node, body: Node3D, cap: int) -> bool:
	if body == null or not is_instance_valid(body) or not ("block" in body) or holder == null:
		return false
	var bt: int = int(body.get("block"))
	for it in inv:
		if not is_instance_valid(it):
			continue
		if int(it.get("type")) == 3 and int(it.get("chunk_block")) == bt \
				and int(it.get("chunk_count")) < 24:          # 3 = Type.CHUNK
			it.set("chunk_count", int(it.get("chunk_count")) + 1)
			body.queue_free()
			return true
	if inv.size() >= cap:
		return false                                          # места нет — блок остаётся лежать
	if _chunk_scene == null:
		_chunk_scene = load(CHUNK_SCENE) as PackedScene
	if _chunk_scene == null:
		return false
	var chunk: Node3D = _chunk_scene.instantiate() as Node3D
	if chunk == null:
		return false
	chunk.set("type", 3)                                      # Type.CHUNK
	chunk.set("chunk_block", bt)
	chunk.set("chunk_count", 1)
	holder.add_child(chunk)
	if chunk is RigidBody3D:
		(chunk as RigidBody3D).freeze = true
	inv.append(chunk)
	body.queue_free()
	return true

## HIT POINTS ARE ON TERRATECH'S SCALE (the player's anchors: a Falsus block 250, a Marlit block
## 1750), AND DAMAGE IS HALF OF TERRATECH'S. The first rescale took TerraTech's dps as it stands (gun
## 255, laser 190) and fights ended in a second; but TerraTech's turrets TURN at a rate and armour
## takes half from bullets, so its nominal dps never all lands. Ours aim instantly, so every number
## that hurts was halved (the player's call) and turrets got a traverse rate
## (`WeaponBlock.turn_speed`). The ladder between blocks is unchanged: armour three times a block,
## plates by area, a half block two thirds.
## THE CABIN IS 2.5 BLOCKS OF ITS FACTION (the player's rule): Falsus 625, Marlit 4375.
## A weapon without a row falls to DEFAULT_HP and is the most fragile thing on the machine - which is
## what the enemy aims at.
const BLOCK_HP: Dictionary = {
	G.Block.CABIN:     625,       # 2.5 blocks (the player's rule): the heart, not a bunker
	G.Block.WHEEL:     190,
	G.Block.BLOCK:     250,
	G.Block.DRILL:     265,      # носовой блок: принимает удар первым, им же и работают
	G.Block.COLLECTOR: 140,
	G.Block.RECEIVER:    140,
	G.Block.BELT:      110,
	G.Block.PROCESSOR: 280,
	G.Block.SELLER:    205,
	G.Block.BATTERY:   170,
	G.Block.SOLAR:     110,
	G.Block.GENERATOR: 265,
	G.Block.REGEN:     170,
	G.Block.SHIELD:    205,
	G.Block.GUN:       205,      # по стволам и бьют: своя строка, а не общий потолок
	G.Block.LASER:     190,
	G.Block.ROCKET:    205,
	G.Block.BLOCK3:    375,      # 3 клетки — и hp втрое от обычного блока
	G.Block.WEDGE2:    345,
	G.Block.ARMOR:     750,      # защитная пластина: держит втрое больше блока
	# Bigger plates: toughness by area - 2 cells twice ARMOR, 4 four times, 9 nine.
	G.Block.ARMOR2:    1500,
	G.Block.ARMOR4:    3000,
	G.Block.ARMOR9:    6750,
	# Половинка — тот же материал, но металла в ней меньше: две трети от блока.
	G.Block.HALF_BLOCK:  170,
	G.Block.HALF_BLOCK2: 345,
	G.Block.WIRELESS_CHARGER: 170,
	G.Block.MORTAR:      265,
	G.Block.POUND_CANNON: 280,
	G.Block.SHOTGUN:     220,
	G.Block.SCRAPPER:    265,
	G.Block.SMALL_DRILL: 155,
	G.Block.BELT_SPLIT: 110,
	G.Block.BELT_CROSS: 110,
	G.Block.ROT_SUPPORT: 205,
	G.Block.STORAGE:    265,
	G.Block.AUTO_MINER: 330,
	G.Block.FABRICATOR: 470,
	# Marlit hull by volume, a little over the frame's 160 a cell: fewer seams in one big part.
	G.Block.MARLIT_BLOCK:     1750,
	G.Block.MARLIT_SLAB:      875,
	G.Block.MARLIT_HALF:      875,
	G.Block.MARLIT_HALF_SLAB: 440,
	G.Block.MARLIT_LONG:      3500,
	G.Block.MARLIT_LONG_HALF: 1750,
	G.Block.MARLIT_GIRDER:    875,     # half the basic block's, as its entry says
	G.Block.MARLIT_BREW_GIRDER: 1750,
	G.Block.MARLIT_BRACKET:   750,     # small but strong
	# Plates by area, a little over Falsus's 480 a cell: thicker plate.
	G.Block.MARLIT_ARMOR2:    1375,
	G.Block.MARLIT_ARMOR4:    2750,
	G.Block.MARLIT_ARMOR8:    5500,
	G.Block.MARLIT_SOLAR:     1000,     # the housing is half a basic block, the lid armour
	G.Block.MARLIT_REGEN:     875,
	G.Block.MARLIT_WHEEL:     750,      # 2×2×2 now, a big target; the Falsus big wheel's share by size
	G.Block.MARLIT_SUPPORT:     1375,   # a casting: tougher than its eight cells of frame, short of the block
	G.Block.MARLIT_ROT_SUPPORT: 1250,
	G.Block.MARLIT_CABIN:     4375,      # 2.5 Marlit blocks, as the Falsus cabin
	# Two cells across and two deep, at a weapon's rate - the part the enemy aims at, so tougher
	# than a hull block's share of its eight cells would make it.
	G.Block.MARLIT_GUN:       700,
	G.Block.MARLIT_LASER:     650,
	G.Block.MARLIT_SHOTGUN:   750,
	G.Block.MARLIT_CANNON:    850,
	G.Block.MARLIT_MORTAR:    750,
	G.Block.MARLIT_BATTERY:   1125,     # a battery's toughness, by its eight cells, less the open bays
	G.Block.MARLIT_WIRELESS:  500,
	G.Block.MARLIT_OCTO:      5875,    # 27 cells at the basic block's rate
}
const DEFAULT_HP := 140

# Вес блока в килограммах. Раньше массу машины составляли только колёса, из-за чего
# постройка вообще не влияла на ходовые качества. Теперь каждый блок весит.
const BLOCK_WEIGHT: Dictionary = {
	G.Block.CABIN:     30.0,
	G.Block.BLOCK:     12.0,
	G.Block.BLOCK2:    22.0,
	G.Block.BLOCK3:    32.0,
	G.Block.WEDGE2:    17.0,
	G.Block.ARMOR:     34.0,
	G.Block.ARMOR2:    68.0,
	G.Block.ARMOR4:    136.0,
	G.Block.ARMOR9:    306.0,
	G.Block.HALF_BLOCK:  7.0,
	G.Block.HALF_BLOCK2: 14.0,
	G.Block.WIRELESS_CHARGER: 16.0,
	G.Block.MORTAR:      34.0,
	G.Block.POUND_CANNON: 30.0,
	G.Block.SHOTGUN:     19.0,
	G.Block.SCRAPPER:    28.0,     # броня тяжёлая: за живучесть платим ходовыми
	G.Block.SMALL_DRILL: 14.0,
	G.Block.BELT_SPLIT:  9.0,
	G.Block.BELT_CROSS: 10.0,
	G.Block.ROT_SUPPORT: 20.0,
	G.Block.STORAGE:    26.0,
	G.Block.AUTO_MINER: 40.0,
	G.Block.FABRICATOR: 55.0,
	G.Block.MARLIT_BLOCK:     90.0,
	G.Block.MARLIT_SLAB:      46.0,
	G.Block.MARLIT_HALF:      46.0,
	G.Block.MARLIT_HALF_SLAB: 23.0,
	G.Block.MARLIT_LONG:      180.0,
	G.Block.MARLIT_LONG_HALF: 92.0,
	G.Block.MARLIT_GIRDER:    45.0,
	G.Block.MARLIT_BREW_GIRDER: 90.0,
	G.Block.MARLIT_BRACKET:   30.0,
	G.Block.MARLIT_ARMOR2:    70.0,
	G.Block.MARLIT_ARMOR4:    140.0,
	G.Block.MARLIT_ARMOR8:    280.0,
	G.Block.MARLIT_SOLAR:     60.0,
	G.Block.MARLIT_REGEN:     55.0,
	G.Block.MARLIT_WHEEL:     70.0,
	G.Block.MARLIT_SUPPORT:     110.0,
	G.Block.MARLIT_ROT_SUPPORT: 130.0,
	G.Block.MARLIT_CABIN:     180.0,
	G.Block.MARLIT_GUN:       80.0,
	G.Block.MARLIT_LASER:     75.0,
	G.Block.MARLIT_SHOTGUN:   90.0,
	G.Block.MARLIT_CANNON:    115.0,
	G.Block.MARLIT_MORTAR:    105.0,
	G.Block.MARLIT_BATTERY:   140.0,
	G.Block.MARLIT_WIRELESS:  45.0,
	G.Block.MARLIT_OCTO:      300.0,
	G.Block.DRILL:     25.0,
	G.Block.COLLECTOR: 12.0,
	G.Block.RECEIVER:    12.0,
	G.Block.BELT:       6.0,
	G.Block.PROCESSOR: 30.0,
	G.Block.SELLER:    18.0,
	G.Block.LASER:     18.0,
	G.Block.GUN:       20.0,
	G.Block.ROCKET:    22.0,
	G.Block.BATTERY:   20.0,
	G.Block.SOLAR:      8.0,
	G.Block.GENERATOR: 28.0,
	G.Block.REGEN:     15.0,
	G.Block.SHIELD:    18.0,
	G.Block.RADAR:     10.0,
	G.Block.SUPPORT:   15.0,
}
const DEFAULT_WEIGHT := 10.0

# Колёса переопределяют это своим экспортом — у них вес настраивается на сцене.
func get_weight() -> float:
	return float(BLOCK_WEIGHT.get(block, DEFAULT_WEIGHT))

## DRAWN BY THE MACHINE, NOT BY ITSELF (MachineBatch): a block's scene meshes join one MultiMesh
## per mesh on its machine. A block whose SCRIPT MOVES one of those meshes (a tyre, a turret, a drill
## rotor) sets this, and its instances are copied from the live nodes every frame; without it the
## part would stand still in the picture while the node turned.
var moving_parts: bool = false

## Scene meshes the batch must leave alone: ones a script shows, hides or re-materials. The batch
## draws a mesh the way it was when the build was last put together.
func unbatched() -> Array:
	return []

var max_hp: int = 50
var current_hp: int = 50
var _hp_fx: MeshInstance3D = null       # постоянный оверлей-«матрица» хп (лениво, см. ниже)

signal destroyed(block_node: VehicleBlock)

func _ready() -> void:
	add_to_group("grass_benders")
	freeze = true
	collision_layer = 2
	collision_mask = 0b10111  # слои 1,2,3,5
	max_hp = BLOCK_HP.get(block, DEFAULT_HP)
	current_hp = max_hp
	tree_entered.connect(_on_parent_changed)
	_on_parent_changed()

func _on_parent_changed() -> void:
	await get_tree().process_frame
	if get_parent() == null:
		return
	var loose: bool = get_parent().name == "objects"
	freeze = not loose
	_set_debris_render(loose)

## A block lying in the world is DEBRIS, and debris is rendered cheaply.
##
## Measured on a phone: a loose block costs about five draw calls, and fifty of them on the
## ground took the frame from 50 fps to 15. Half of that is the shadow pass — every casting
## mesh is drawn a second time into the shadow map — and the damage overlay adds one more draw
## with its own shader on top.
##
## Neither is worth anything on a pile of debris: nobody reads hit points off scrap, and the
## shadow of a small block lying on the ground is a few dark pixels. Both come back the moment
## the block is bolted onto a machine again, where they do matter.
## КАКИЕ ГРАНИ ЭТОГО БЛОКА ОТКРЫТЫ. Считает blocks._apply_occlusion (та же заливка снаружи, по
## которой замурованный блок перестаёт рисоваться), здесь — только запоминаем и передаём
## оболочке хп. Запоминаем обязательно: оболочка создаётся ЛЕНИВО, на первом уроне, то есть
## обычно уже после того, как маску посчитали.
var _open_faces: int = 63

func set_open_faces(mask: int) -> void:
	_open_faces = mask
	_push_open_faces()

func _push_open_faces() -> void:
	if not is_instance_valid(_hp_fx):
		return
	var m := _hp_fx.material_override as ShaderMaterial
	if m != null:
		m.set_shader_parameter("open_faces", _open_faces)

func _set_debris_render(loose: bool) -> void:
	if is_instance_valid(_hp_fx):
		_hp_fx.visible = not loose and current_hp < max_hp
	_set_shadows(self, not loose)

func _set_shadows(n: Node, on: bool) -> void:
	var mi := n as GeometryInstance3D
	if mi != null and mi != _hp_fx:
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if on \
				else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	for c in n.get_children():
		# В AMMO НЕ ЗАХОДИМ. Там лежат пуля-шаблон и весь пул, и рекурсия включала им тень
		# наравне с корпусом: снаряд 34 см в полёте попадал в теневую карту каждый кадр ради
		# тени, которой никто не видит. При цене теней в восемь кадров из двадцати пяти (замер
		# на устройстве) это чистые потери. Пуле тень снимают там, где ей ставят модель
		# (WeaponBlock._apply_bullet_mesh), и перебивать это отсюда нельзя.
		if c.name == &"Ammo":
			continue
		_set_shadows(c, on)

## TERRATECH'S DAMAGE TYPES (the wiki's "Attack Effectiveness Chart", the player's call): what a hit
## does depends on WHAT hits WHAT. A weapon carries its type (`WeaponBlock.damage_kind`, the drill
## CUTTING), a block its class (`damage_class`), and the table below is the multiplier - applied
## here, at the one door every block's damage comes through. STANDARD is "no type": the blasts of a
## battery, a cabin or a burnt fuse, a hard landing - the table leaves them as they are. Wood and
## rock (veins) are not in it: a vein's hp is tuned to the drill and the gun as they stand.
enum Dmg { STANDARD, BULLET, ENERGY, EXPLOSIVE, CUTTING }
enum Cls { STANDARD, ARMOR, RUBBER, VOLATILE, SHIELD }
## Rows by Dmg, columns by Cls (standard, armour, rubber, volatile, shield) - the wiki's numbers.
const DMG_TABLE := [
	[1.0, 1.0, 1.0, 1.0, 1.0],    # standard
	[1.0, 0.5, 1.0, 1.0, 2.0],    # bullet: bounces off armour, rips shields
	[1.0, 1.5, 1.0, 1.5, 0.5],    # energy: burns through armour and batteries
	[1.0, 0.5, 1.5, 2.0, 0.5],    # explosive: tyres and volatile blocks, not armour
	[1.0, 0.5, 1.0, 1.0, 2.0],    # cutting
]
## What explodes when hit (TerraTech's "volatile"): batteries and the launchers of explosive rounds.
const VOLATILE_BLOCKS := [G.Block.BATTERY, G.Block.MARLIT_BATTERY, G.Block.ROCKET, G.Block.MORTAR,
		G.Block.MARLIT_MORTAR]
var _dmg_cls: int = -1

## This block's column in DMG_TABLE, worked out once.
func damage_class() -> int:
	if _dmg_cls < 0:
		if ARMOR_BLOCKS.has(block):
			_dmg_cls = Cls.ARMOR
		elif VOLATILE_BLOCKS.has(block):
			_dmg_cls = Cls.VOLATILE
		elif block == G.Block.SHIELD:
			_dmg_cls = Cls.SHIELD
		elif has_method("probe_ground"):                   # every wheel: a tyre is rubber
			_dmg_cls = Cls.RUBBER
		else:
			_dmg_cls = Cls.STANDARD
	return _dmg_cls

static func type_mult(kind: int, cls: int) -> float:
	return float(DMG_TABLE[clampi(kind, 0, DMG_TABLE.size() - 1)][cls])

func hurt(damage: int = 10, kind: int = Dmg.STANDARD) -> void:
	if kind != Dmg.STANDARD and damage > 0:
		damage = maxi(int(round(float(damage) * type_mult(kind, damage_class()))), 1)
	# Debug switch (Main → Отладка → Игрок): blocks of the player's machines take no damage.
	# Guarded here, at the single door damage comes through — a weapon-side check would miss the
	# drill, the AOE from block_fx and every future source. A loose block in the world has no
	# machine over it and stays breakable: "invulnerable" is about the player's build.
	if damage > 0 and G.debug(&"player_invulnerable", false):
		var body: Node = _root_body()
		# `== 0` on the Variant, not int(...): a body without the field returns null, and int(null)
		# throws right here (the same trap as bool(null), see CLAUDE.md).
		if body != null and body.get("faction") == 0:
			return
	current_hp -= damage
	if current_hp > 0:
		_refresh_hp_fx()
	_play_hit_effect()
	if current_hp <= 0:
		destroy()
		return
	_check_critical()

# ── A BATTERED BLOCK ─────────────────────────────────────────────────────────
# A block does not hang on to its last hit point. Below DROP_FRAC the mounts no longer hold and
# every hit can tear it off; below FUSE_FRAC it is doomed — it comes off for certain, burns red,
# and blows up on its own. That is what makes a fight readable and gives a reason to retreat:
# the machine starts coming apart BEFORE it is finished off.
#
# THE CABIN IS EXEMPT FROM TEARING OFF, and this is not cosmetic. The cabin is the root the
# whole structure hangs from, and a block torn into the world has its `destroyed` connections
# cut (blocks._detach_one) — so a detached cabin left the machine with no root and no death
# signal at once: everything else fell off as orphans and a live, empty hull kept driving
# around, unkillable. It still explodes when destroyed, it just never leaves the machine.
const DROP_FRAC := 0.20        # below this share of hp the mounts may give
## ONE ROLL, WHEN THE BLOCK FIRST GOES UNDER DROP_FRAC, not one per hit: at 30% a hit every block
## shot under a fifth of its hp came off within a few rounds, so "may tear off" read as "always
## does". The chance is the block's own (`_drop_chance`): half for an ordinary part, less for what
## is bolted on harder - a weapon on its mount (WeaponBlock) and a battery in its cradle at 30%,
## armour at 20%, since a plate is the part meant to stay and take the hits. A block repaired back
## over the line rolls again when it next drops under it.
const DROP_CHANCE := 0.50
const DROP_CHANCE_WEAPON := 0.30
const DROP_CHANCE_BATTERY := 0.30
const DROP_CHANCE_ARMOR := 0.20
const ARMOR_BLOCKS := [G.Block.ARMOR, G.Block.ARMOR2, G.Block.ARMOR4, G.Block.ARMOR9,
		G.Block.MARLIT_ARMOR2, G.Block.MARLIT_ARMOR4, G.Block.MARLIT_ARMOR8]
var _drop_rolled: bool = false
const FUSE_FRAC := 0.05        # below this the block is doomed: it detaches and burns down
## How long the fuse burns. Long on purpose: a doomed block has to be a WARNING, something you
## can drive away from or shoot off, not an instant explosion the player never saw coming.
const FUSE_TIME_MIN := 4.0
const FUSE_TIME_MAX := 6.0
const SELF_BLAST_RADIUS := 3.0
const SELF_BLAST_DAMAGE := 154
const SELF_BLAST_FORCE := 7.0
var _fuse_lit: bool = false
## ФИТИЛЬ ДОГОРЕЛ — то есть взрыв состоялся сам, а не «блок умер, пока фитиль горел». Разница
## принципиальная: горящий фитиль это ПРЕДУПРЕЖДЕНИЕ, и сбить обречённый блок до того, как он
## рванёт, обязано быть выигрышем игрока, а не тем же взрывом на секунду раньше. Иначе стрелять
## по дымящемуся блоку бессмысленно — результат одинаковый, что стреляй, что нет.
## Кабины и аккумулятора это не касается: у них взрыв СВОЙ и он не от фитиля (см. destroy).
var _fuse_done: bool = false

func _check_critical() -> void:
	if _destroyed or _fuse_lit:
		return
	var frac: float = float(current_hp) / float(maxi(max_hp, 1))
	if frac >= DROP_FRAC:
		_drop_rolled = false             # repaired over the line: the next drop under it rolls anew
		return
	var stays: bool = G.is_cabin(block) or is_volatile()
	if frac < FUSE_FRAC:
		# Doomed: off the machine FOR CERTAIN (the one roll under DROP_FRAC may have failed),
		# and the fuse is lit either way.
		if not stays and _map_node() != null:
			_map_node().detach_node(self)
		_light_fuse()
	elif not _drop_rolled:
		_drop_rolled = true
		if not stays and _map_node() != null and randf() < _drop_chance():
			_map_node().detach_node(self)

## A repair over the line re-arms the roll. `_check_critical` runs only on a hit, so a block mended
## back over DROP_FRAC and then knocked straight under it by one hit kept the old roll and could
## never tear off again. Whoever adds hit points calls this (regen._mend).
func on_repaired() -> void:
	if float(current_hp) / float(maxi(max_hp, 1)) >= DROP_FRAC:
		_drop_rolled = false

## This block's chance to tear off when it first goes under DROP_FRAC; WeaponBlock overrides it.
func _drop_chance() -> float:
	if block in G.BATTERY_BLOCKS:
		return DROP_CHANCE_BATTERY
	if ARMOR_BLOCKS.has(block):
		return DROP_CHANCE_ARMOR
	return DROP_CHANCE

## АККУМУЛЯТОР, КОТОРЫЙ НЕ ВЫПАДАЕТ, А РВЁТСЯ ВМЕСТЕ С ПОСТРОЙКОЙ.
##
## Помечается на МАШИНЕ (мета `volatile_batteries`), а не на блоке: это свойство постройки —
## вышка под щитом и её зарядные башни, — и раздавать метку блокам по одному значит однажды
## забыть один. Батарея такой постройки и есть задача: она должна рвануть в руках у того, кто
## её ломает, а не лечь под ноги трофеем, чем бы её ни сбили — попаданием, фитилём или гибелью
## самой постройки (в том числе когда сломали блок поддержки и всё посыпалось).
func is_volatile() -> bool:
	if not (block in G.BATTERY_BLOCKS):
		return false
	var veh: Node = _root_body()
	return veh != null and veh.has_meta("volatile_batteries")

## The block map of the machine this block sits on. null → the block is already loose (lying in
## the world, in a collector, in the player's hand): there is nothing to tear it off.
func _map_node() -> Node:
	var p: Node = get_parent()
	if p != null and p.has_method("detach_node"):
		return p
	return null

## The fuse: a red matrix shell that burns BRIGHTER AND BRIGHTER until the block goes off
## (BlockFX.fuse). It used to blink the node's VISIBILITY instead, and that was a workaround
## rather than a design: models share their materials between instances, so tinting one block
## would tint every block of that kind in the game. A separate shell has its own material and
## does not touch the model at all — the same trick the repair effect has always used.
func _light_fuse() -> void:
	_fuse_lit = true
	var total: float = randf_range(FUSE_TIME_MIN, FUSE_TIME_MAX)
	BlockFX.fuse(self, total)
	var tw := create_tween()          # a node tween: destroy the block earlier and it dies too
	tw.tween_interval(total)
	tw.tween_callback(_fuse_blow)

func _fuse_blow() -> void:
	if _destroyed or not is_inside_tree():
		return
	visible = true
	current_hp = 0
	_fuse_done = true                 # именно ДОГОРЕЛ — только теперь взрыв заслужен
	destroy()

## ПОВРЕЖДЕНИЕ БЛОКА ЦИФРАМИ 0/1 (block_hp.gdshader). Клетка либо пробита, либо нет, и решает это
## её собственный хеш против доли урона: новый удар ДОБАВЛЯЕТ цифры к горящим, а не перекладывает
## их. Меняется в клетке только сам символ.
##
## ПОЧИНКУ ПОКАЗЫВАЮТ ТЕ ЖЕ ЦИФРЫ: клетки между новым уроном и прежним зеленеют и гаснут за
## HEAL_FADE. Отдельного зелёного эффекта поверх блока нет — он рисовал бы то же самое второй раз.
##
## Зовём ТОЛЬКО при изменении хп, не по кадрам: мигание цифр гонит сам шейдер от TIME, а возраст
## починки — твин, и только пока зелёные не догорят.
const HEAL_FADE := 1.4
var _hp_dmg: float = 0.0
var _heal_tw: Tween = null

func _refresh_hp_fx() -> void:
	var dmg := 1.0 - float(current_hp) / float(maxi(max_hp, 1))
	var healed: float = maxf(_hp_dmg - dmg, 0.0)
	_hp_dmg = dmg
	# Debris carries no damage overlay (see _set_debris_render): an extra draw call and a
	# shader each, on numbers nobody reads off a pile of scrap.
	#
	# КВЕСТОВЫЙ БЛОК — ИСКЛЮЧЕНИЕ. Его состояние и есть задание: аккумулятор из жилы побит
	# намеренно, и «в жиле побитый, а выпал целым» — это не починка, это цифры, спрятанные ровно
	# в тот момент, когда блок стал лежащим. Таких блоков в мире единицы.
	var debris: bool = get_parent() != null and get_parent().name == "objects" \
			and not has_meta("quest_id")
	if debris or (dmg <= 0.001 and healed <= 0.001):
		if is_instance_valid(_hp_fx):
			_hp_fx.visible = false
		return
	if not is_instance_valid(_hp_fx):
		if not is_inside_tree():
			return
		_hp_fx = BlockFX.hp_overlay(self)
		_push_open_faces()      # оболочка родилась только сейчас — маску ей ещё не отдавали
	_hp_fx.visible = true
	var mat := _hp_fx.material_override as ShaderMaterial
	mat.set_shader_parameter("damage", clampf(dmg, 0.0, 1.0))
	if healed <= 0.001:
		return
	mat.set_shader_parameter("heal_from", clampf(dmg + healed, 0.0, 1.0))
	if is_instance_valid(_heal_tw):
		_heal_tw.kill()                # реген чинит тиками: каждый следующий начинает отсчёт заново
	_heal_tw = create_tween()
	_heal_tw.tween_method(_set_heal_age, 0.0, HEAL_FADE, HEAL_FADE)
	_heal_tw.tween_callback(_heal_done)

func _set_heal_age(t: float) -> void:
	if is_instance_valid(_hp_fx):
		(_hp_fx.material_override as ShaderMaterial).set_shader_parameter("heal_age", t)

## Зелёные догорели. Блок при этом мог уже стать целым — тогда оверлею больше нечего рисовать.
func _heal_done() -> void:
	if is_instance_valid(_hp_fx) and _hp_dmg <= 0.001:
		_hp_fx.visible = false

var _hit_fx_ms: int = 0
const HIT_FX_COOLDOWN := 120        # мс между визуальными откликами на попадание

func _play_hit_effect() -> void:
	# Троттл: эффект — чисто визуальная отдача, но каждый вызов создаёт твин из 3 шагов И
	# BlockFX.hit() (пластины-вспышки с шейдером). Лазер бьёт 10 раз/с по блоку, а взрыв батареи
	# зовёт это сразу у 48 блоков в одном кадре. Чаще ~8 Гц глазом всё равно не различить.
	var now := Time.get_ticks_msec()
	if now - _hit_fx_ms < HIT_FX_COOLDOWN:
		return
	_hit_fx_ms = now
	# NO SCALE KICK. The block used to jump to 1.1 and 0.9 of its size on a hit, and nothing showed
	# it: MachineBatch draws a block from the transform it had when the batch was BUILT (only
	# `moving_parts` blocks are copied every frame), so the kick moved an invisible node - and a
	# rebuild landing mid-kick froze the block in the picture a tenth too big or too small until the
	# next one. It also rescaled a physics body (the block's own collider) three times a hit.
	# Red 0/1 on a pair of the block's faces (block_matrix.gdshader mode 2, BlockFX.hit).
	BlockFX.hit(self)

# The battery and the cabin blow up HARDER than an ordinary block: one is a charged cell, the
# other takes the whole machine with it. Same 3-metre-ish reach so the rule stays readable —
# what differs is how much it hurts and how far it throws.
## ВЗРЫВ АККУМУЛЯТОРА РАСТЁТ С ЗАРЯДОМ. Пустая банка — кусок железа, полная — запас энергии, и
## разница обязана читаться: снять с вражеской машины щит и реген выгодно ещё и потому, что её
## батареи после этого рвутся вполсилы.
##
## Урон задан ДОЛЕЙ ОТ ПРОЧНОСТИ ОБЫЧНОГО БЛОКА, а не абсолютным числом: таблица BLOCK_HP
## двигается (её тюнят «в секундах под огнём»), и «сколько это в хп» обязано двигаться вместе с
## ней. Полный аккумулятор снимает соседу больше двух третей, пустой едва царапает.
## Радиус в КЛЕТКАХ — клетка и есть метр.
const BATTERY_BLAST_FRAC_FULL := 0.70
const BATTERY_BLAST_FRAC_EMPTY := 0.20
const BATTERY_BLAST_RADIUS_FULL := 3.0
const BATTERY_BLAST_RADIUS_EMPTY := 1.0
const BATTERY_BLAST_FORCE := 8.0

## Насколько аккумулятор полон, 0..1. Не аккумулятор или блок без скрипта батареи — ноль:
## `get` на отсутствующем поле возвращает null, и делить на него нельзя (CLAUDE.md, правило 4).
func _charge01() -> float:
	var cap = get("capacity")
	var ch = get("charge")
	if not (cap is float) or not (ch is float) or float(cap) <= 0.0:
		return 0.0
	return clampf(float(ch) / float(cap), 0.0, 1.0)
const CABIN_BLAST_RADIUS := 3.5
const CABIN_BLAST_DAMAGE := 282
const CABIN_BLAST_FORCE := 9.0
var _destroyed: bool = false

func destroy() -> void:
	if _destroyed:                    # защита от двойного вызова (цепные взрывы, урон в кадре гибели)
		return
	_destroyed = true
	# ЧТО ВЗРЫВАЕТСЯ. Батарея — ВОЛАТИЛЬНА (свои числа, они крупнее). Кабина уносит машину с
	# собой и обязана рвануть тоже — иначе гибель машины выглядит как «блоки просто осыпались».
	# И блок, ДОГОРЕВШИЙ до конца фитиля (_fuse_done, а не просто «фитиль горел»): сбитый раньше
	# срока обречённый блок не взрывается — иначе стрелять по дымящемуся нет смысла, результат
	# один и тот же. Батарею и кабину это не затрагивает: их взрыв выше и он не от фитиля.
	# Пометка «бласт» на машине нужна, чтобы осколки, оторвавшиеся ИЗ-ЗА взрыва, разлетелись
	# сильнее обычного (см. detach_block_to_world), а push толкает уже свободные блоки вокруг.
	var blast_r: float = 0.0
	var blast_d: int = 0
	var blast_f: float = 0.0
	if block in G.BATTERY_BLOCKS:
		var k: float = _charge01()
		var ord_hp: float = float(int(BLOCK_HP.get(G.Block.BLOCK, DEFAULT_HP)))
		blast_r = lerpf(BATTERY_BLAST_RADIUS_EMPTY, BATTERY_BLAST_RADIUS_FULL, k)
		blast_d = int(round(ord_hp * lerpf(BATTERY_BLAST_FRAC_EMPTY, BATTERY_BLAST_FRAC_FULL, k)))
		blast_f = BATTERY_BLAST_FORCE
	elif G.is_cabin(block):
		blast_r = CABIN_BLAST_RADIUS
		blast_d = CABIN_BLAST_DAMAGE
		blast_f = CABIN_BLAST_FORCE
	elif _fuse_done:
		blast_r = SELF_BLAST_RADIUS
		blast_d = SELF_BLAST_DAMAGE
		blast_f = SELF_BLAST_FORCE
	if blast_r > 0.0:
		var veh := _root_body()
		if veh != null and veh.has_method("register_blast"):
			veh.register_blast(centre(), blast_f)
		BlockFX.explosion(self, centre(), blast_r, blast_d, null, blast_f)
	BlockFX.play(self, true)          # эффект «матрицы» уничтожения (красные + глюк)
	emit_signal("destroyed", self)
	queue_free()

## THE BLOCK'S MIDDLE in the world. A multi-cell block is anchored in a CORNER of its cells (every
## Marlit block), so its `global_position` is a metre off its middle: a blast, a shot aimed at the
## Marlit cabin and the scatter of a dead machine are centred here, not on the anchor.
func centre() -> Vector3:
	return global_transform * cells_center

# Корневое тело (RigidBody3D-машина) над блоком — минуя ноду blocks. self сам RigidBody, поэтому
# идём от родителя.
func _root_body() -> Node:
	var p: Node = get_parent()
	while p != null and not (p is RigidBody3D):
		p = p.get_parent()
	return p
