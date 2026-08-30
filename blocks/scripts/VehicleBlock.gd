# vehicle_block.gd
class_name VehicleBlock
extends RigidBody3D

@export var block: G.Block

# ── ГРАНИ СТЫКОВКИ ────────────────────────────────────────────────────────────
# Настраиваются В ИНСПЕКТОРЕ для КАЖДОЙ сцены блока — как input/output у фабричных, только
# про механическое крепление, а не про поток ресурса. Отмечаешь галочками, какими своими
# сторонами блок стыкуется с другими; вписывать ничего не надо.
#
# Грани заданы в СОБСТВЕННЫХ осях блока и едут вместе с его поворотом:
#   front = −Z (морда), back = +Z, right = +X, left = −X, top = +Y, bottom = −Y
#
# Работает в ОБЕ стороны, одним и тем же списком:
#   • ставя блок, постройка доворачивает его так, чтобы одна из этих граней смотрела на
#     соседа (бур с одной галочкой «Back» всегда встанет буром наружу);
#   • цепляя что-то К этому блоку, сосед может пристыковаться ТОЛЬКО к отмеченной грани —
#     к остальным нельзя (на коронку бура ничего не навесить).
# По умолчанию отмечены все шесть: обычный блок стыкуется чем угодно и куда угодно.
#
# НАСТРАИВАЕТСЯ ТОЛЬКО КУБИКОМ (addons/blockfaces), поэтому `@export_storage`, а не
# `@export_flags`: значение по-прежнему лежит в сцене блока и грузится как раньше, но своих
# галочек в инспекторе у него больше нет. Шесть галочек рядом с кубиком — это ВТОРОЙ орган
# управления тем же числом: два способа задать одно и то же однажды разъезжаются, а главное —
# галочка «Left» требует помнить, где у блока лево, ради чего кубик и делался.
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
# Перевод из осей карты в свои делает _local_side (крутим вокруг центра футпринта, иначе
# поворот уводит клетки за его границы).
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
	var lo: Vector3 = (inv * (Vector3(off) - cells_center) + cells_center).round()
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

const BLOCK_HP: Dictionary = {
	G.Block.CABIN:     150,
	G.Block.WHEEL:     60,
	G.Block.BLOCK:     80,
	G.Block.DRILL:     80,
	G.Block.COLLECTOR: 50,
	G.Block.RECEIVER:    50,
	G.Block.BELT:      40,
	G.Block.PROCESSOR: 100,
	G.Block.SELLER:    70,
	G.Block.BATTERY:   60,
	G.Block.SOLAR:     40,
	G.Block.GENERATOR: 90,
	G.Block.REGEN:     60,
	G.Block.SHIELD:    70,
	G.Block.ROCKET:    70,
	G.Block.BLOCK3:    120,      # 3 клетки — и hp втрое от обычного блока
	G.Block.WEDGE2:    110,
	G.Block.ARMOR:     240,      # защитная пластина: держит втрое больше блока
	# Плиты крупнее — прочность по объёму: 2 клетки вдвое, 4 клетки вчетверо от ARMOR.
	G.Block.ARMOR2:    480,
	G.Block.ARMOR4:    960,
	# Половинка — тот же материал, но металла в ней меньше: две трети от блока.
	G.Block.HALF_BLOCK:  55,
	G.Block.HALF_BLOCK2: 110,
	G.Block.WIRELESS_CHARGER: 55,
	G.Block.MORTAR:      90,
	G.Block.POUND_CANNON: 95,
	G.Block.SHOTGUN:     70,
	G.Block.SCRAPPER:    90,
	G.Block.SMALL_DRILL: 50,
	G.Block.BELT_SPLIT: 40,
	G.Block.BELT_CROSS: 40,
	G.Block.ROT_SUPPORT: 70,
	G.Block.STORAGE:    90,
	G.Block.AUTO_MINER: 110,
	G.Block.FABRICATOR: 160,
}
const DEFAULT_HP := 50

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
	G.Block.COAL_GEN:  35.0,
	G.Block.REGEN:     15.0,
	G.Block.SHIELD:    18.0,
	G.Block.RADAR:     10.0,
	G.Block.SUPPORT:   15.0,
}
const DEFAULT_WEIGHT := 10.0

# Колёса переопределяют это своим экспортом — у них вес настраивается на сцене.
func get_weight() -> float:
	return float(BLOCK_WEIGHT.get(block, DEFAULT_WEIGHT))

var max_hp: int = 50
var current_hp: int = 50
var _hp_fx: MeshInstance3D = null       # постоянный оверлей-«матрица» хп (лениво, см. ниже)
var _hit_tween: Tween = null            # «пинок» масштабом при уроне (гасим прошлый, см. ниже)

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
		_set_shadows(c, on)

func hurt(damage: int = 10) -> void:
	current_hp -= damage
	# Оверлей хп строим ДО хит-эффекта: _local_aabb внутри hp_overlay иначе прихватил бы
	# только что заспавненные пластины вспышки (mode 2) и раздул бы коробку навсегда.
	if current_hp > 0:
		_refresh_hp_fx()
	_play_hit_effect()
	if current_hp <= 0:
		destroy()
		return
	_check_critical()

# ── A BATTERED BLOCK ─────────────────────────────────────────────────────────
# A block does not hang on to its last hit point. Below DROP_FRAC the mounts no longer hold and
# every hit can tear it off; below FUSE_FRAC it is doomed — it comes off for certain, blinks,
# and blows up on its own. That is what makes a fight readable and gives a reason to retreat:
# the machine starts coming apart BEFORE it is finished off.
#
# THE CABIN IS EXEMPT FROM TEARING OFF, and this is not cosmetic. The cabin is the root the
# whole structure hangs from, and a block torn into the world has its `destroyed` connections
# cut (blocks._detach_one) — so a detached cabin left the machine with no root and no death
# signal at once: everything else fell off as orphans and a live, empty hull kept driving
# around, unkillable. It still explodes when destroyed, it just never leaves the machine.
const DROP_FRAC := 0.20        # below this share of hp a hit can tear the block off
const DROP_CHANCE := 0.30      # chance PER HIT while in that state
const FUSE_FRAC := 0.05        # below this the block is doomed: it detaches and burns down
## How long the fuse burns. Long on purpose: a doomed block has to be a WARNING, something you
## can drive away from or shoot off, not an instant explosion the player never saw coming.
const FUSE_TIME_MIN := 4.0
const FUSE_TIME_MAX := 6.0
const FUSE_BLINK_SLOW := 0.34  # seconds per blink at the start
const FUSE_BLINK_FAST := 0.07  # ...and at the end, so the last second reads as "now"
const SELF_BLAST_RADIUS := 3.0
const SELF_BLAST_DAMAGE := 30
const SELF_BLAST_FORCE := 7.0
var _fuse_lit: bool = false

func _check_critical() -> void:
	if _destroyed or _fuse_lit:
		return
	var frac: float = float(current_hp) / float(maxi(max_hp, 1))
	if frac >= DROP_FRAC:
		return
	var is_cabin: bool = block == G.Block.CABIN
	if frac < FUSE_FRAC:
		# Doomed: off the machine FOR CERTAIN (the 30% roll above may well have never come up),
		# and the fuse is lit either way.
		if not is_cabin and _map_node() != null:
			_map_node().detach_node(self)
		_light_fuse()
	elif not is_cabin and _map_node() != null and randf() < DROP_CHANCE:
		_map_node().detach_node(self)

## The block map of the machine this block sits on. null → the block is already loose (lying in
## the world, in a collector, in the player's hand): there is nothing to tear it off.
func _map_node() -> Node:
	var p: Node = get_parent()
	if p != null and p.has_method("detach_node"):
		return p
	return null

## The fuse: the block blinks, faster and faster, then explodes. We blink the node's VISIBILITY
## rather than tinting it: models share their materials between instances, so tinting one block
## would tint every block of that kind in the game, and there is nothing to restore them from.
func _light_fuse() -> void:
	_fuse_lit = true
	var total: float = randf_range(FUSE_TIME_MIN, FUSE_TIME_MAX)
	var tw := create_tween()          # a node tween: destroy the block earlier and it dies too
	var t: float = 0.0
	while t < total:
		var k: float = t / total
		var step: float = lerpf(FUSE_BLINK_SLOW, FUSE_BLINK_FAST, k * k)
		tw.tween_callback(func() -> void: visible = false)
		tw.tween_interval(step * 0.5)
		tw.tween_callback(func() -> void: visible = true)
		tw.tween_interval(step * 0.5)
		t += step
	tw.tween_callback(_fuse_blow)

func _fuse_blow() -> void:
	if _destroyed or not is_inside_tree():
		return
	visible = true
	current_hp = 0
	destroy()

# Постоянный показ хп красными «матричными» цифрами (см. block_fx.hp_overlay / mode 3).
# Зовём ТОЛЬКО при изменении хп (урон/реген), не по кадрам: анимацию гонит сам шейдер от
# TIME, GDScript лишь пишет юниформ `damage`. Полный хп → узел спрятан (нулевая цена);
# оверлей создаётся лениво на первом уроне, чтобы целые блоки не плодили узлы.
func _refresh_hp_fx() -> void:
	var dmg := 1.0 - float(current_hp) / float(maxi(max_hp, 1))
	# Debris carries no damage overlay (see _set_debris_render): an extra draw call and a
	# shader each, on numbers nobody reads off a pile of scrap.
	if dmg <= 0.001 or (get_parent() != null and get_parent().name == "objects"):
		if is_instance_valid(_hp_fx):
			_hp_fx.visible = false
		return
	if not is_instance_valid(_hp_fx):
		if not is_inside_tree():
			return
		_hp_fx = BlockFX.hp_overlay(self)
	_hp_fx.visible = true
	(_hp_fx.material_override as ShaderMaterial).set_shader_parameter("damage", clampf(dmg, 0.0, 1.0))

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
	# Лёгкий "пинок" масштабом — тактильная отдача от попадания. Гасим прошлый твин: под
	# лазером (урон каждые 0.1с) несколько твинов иначе дерутся за scale и блок дёргает.
	if is_instance_valid(_hit_tween):
		_hit_tween.kill()
	_hit_tween = create_tween()
	_hit_tween.tween_property(self, "scale", Vector3.ONE * 1.1, 0.07)
	_hit_tween.tween_property(self, "scale", Vector3.ONE * 0.9, 0.07)
	_hit_tween.tween_property(self, "scale", Vector3.ONE, 0.07)
	# Красные 0/1 на паре случайных граней блока — вместо прежней заливки материалов
	# в красный цвет (см. block_matrix.gdshader mode 2 / BlockFX.hit).
	BlockFX.hit(self)

# The battery and the cabin blow up HARDER than an ordinary block: one is a charged cell, the
# other takes the whole machine with it. Same 3-metre-ish reach so the rule stays readable —
# what differs is how much it hurts and how far it throws.
const BATTERY_BLAST_RADIUS := 3.5
const BATTERY_BLAST_DAMAGE := 45
const BATTERY_BLAST_FORCE := 8.0
const CABIN_BLAST_RADIUS := 3.5
const CABIN_BLAST_DAMAGE := 55
const CABIN_BLAST_FORCE := 9.0
var _destroyed: bool = false

func destroy() -> void:
	if _destroyed:                    # защита от двойного вызова (цепные взрывы, урон в кадре гибели)
		return
	_destroyed = true
	# ЧТО ВЗРЫВАЕТСЯ. Батарея — ВОЛАТИЛЬНА (свои числа, они крупнее). Кабина уносит машину с
	# собой и обязана рвануть тоже — иначе гибель машины выглядит как «блоки просто осыпались».
	# И блок, догоревший до конца фитиля (см. _light_fuse), взрывается по определению.
	# Пометка «бласт» на машине нужна, чтобы осколки, оторвавшиеся ИЗ-ЗА взрыва, разлетелись
	# сильнее обычного (см. detach_block_to_world), а push толкает уже свободные блоки вокруг.
	var blast_r: float = 0.0
	var blast_d: int = 0
	var blast_f: float = 0.0
	if block == G.Block.BATTERY:
		blast_r = BATTERY_BLAST_RADIUS
		blast_d = BATTERY_BLAST_DAMAGE
		blast_f = BATTERY_BLAST_FORCE
	elif block == G.Block.CABIN:
		blast_r = CABIN_BLAST_RADIUS
		blast_d = CABIN_BLAST_DAMAGE
		blast_f = CABIN_BLAST_FORCE
	elif _fuse_lit:
		blast_r = SELF_BLAST_RADIUS
		blast_d = SELF_BLAST_DAMAGE
		blast_f = SELF_BLAST_FORCE
	if blast_r > 0.0:
		var veh := _root_body()
		if veh != null and veh.has_method("register_blast"):
			veh.register_blast(global_position, blast_f)
		BlockFX.explosion(self, global_position, blast_r, blast_d, null, blast_f)
	BlockFX.play(self, true)          # эффект «матрицы» уничтожения (красные + глюк)
	emit_signal("destroyed", self)
	queue_free()

# Корневое тело (RigidBody3D-машина) над блоком — минуя ноду blocks. self сам RigidBody, поэтому
# идём от родителя.
func _root_body() -> Node:
	var p: Node = get_parent()
	while p != null and not (p is RigidBody3D):
		p = p.get_parent()
	return p
