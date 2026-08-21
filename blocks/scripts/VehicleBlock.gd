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
@export_flags("Front (−Z)", "Back (+Z)", "Left (−X)", "Right (+X)", "Top (+Y)", "Bottom (−Y)") \
		var connect_faces: int = FACE_ALL   ## Стороны, которыми блок стыкуется с соседями

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

## УПАКОВКА БЛОКА В ЧАНК — общая для коллектора и приёмника.
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
	freeze = not (get_parent().name == "objects")

func hurt(damage: int = 10) -> void:
	current_hp -= damage
	# Оверлей хп строим ДО хит-эффекта: _local_aabb внутри hp_overlay иначе прихватил бы
	# только что заспавненные пластины вспышки (mode 2) и раздул бы коробку навсегда.
	if current_hp > 0:
		_refresh_hp_fx()
	_play_hit_effect()
	if current_hp <= 0:
		destroy()

# Постоянный показ хп красными «матричными» цифрами (см. block_fx.hp_overlay / mode 3).
# Зовём ТОЛЬКО при изменении хп (урон/реген), не по кадрам: анимацию гонит сам шейдер от
# TIME, GDScript лишь пишет юниформ `damage`. Полный хп → узел спрятан (нулевая цена);
# оверлей создаётся лениво на первом уроне, чтобы целые блоки не плодили узлы.
func _refresh_hp_fx() -> void:
	var dmg := 1.0 - float(current_hp) / float(maxi(max_hp, 1))
	if dmg <= 0.001:
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

const BATTERY_BLAST_RADIUS := 3.0
const BATTERY_BLAST_DAMAGE := 35
const BATTERY_BLAST_FORCE := 7.0
var _destroyed: bool = false

func destroy() -> void:
	if _destroyed:                    # защита от двойного вызова (цепные взрывы, урон в кадре гибели)
		return
	_destroyed = true
	# Батарея ВОЛАТИЛЬНА: при уничтожении — AOE-урон блокам вокруг (~3 м) + пометка «бласт», чтобы
	# осколки, оторвавшиеся из-за её гибели, разлетелись СИЛЬНЕЕ обычного (см. detach_block_to_world).
	if block == G.Block.BATTERY:
		var veh := _root_body()
		if veh != null and veh.has_method("register_blast"):
			veh.register_blast(global_position, BATTERY_BLAST_FORCE)
		BlockFX.explosion(self, global_position, BATTERY_BLAST_RADIUS, BATTERY_BLAST_DAMAGE)
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
