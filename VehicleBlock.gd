# vehicle_block.gd
class_name VehicleBlock
extends RigidBody3D

@export var block: G.Block

const BLOCK_HP: Dictionary = {
	G.Block.CABIN:     150,
	G.Block.WHEEL:     60,
	G.Block.BLOCK:     80,
	G.Block.DRILL:     80,
	G.Block.COLLECTOR: 50,
	G.Block.INTAKE:    50,
	G.Block.BELT:      40,
	G.Block.PROCESSOR: 100,
	G.Block.SELLER:    70,
	G.Block.BATTERY:   60,
	G.Block.SOLAR:     40,
	G.Block.GENERATOR: 90,
	G.Block.REGEN:     60,
	G.Block.SHIELD:    70,
	G.Block.ROCKET:    70,
}
const DEFAULT_HP := 50

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
