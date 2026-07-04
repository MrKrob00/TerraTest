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
}
const DEFAULT_HP := 50

var max_hp: int = 50
var current_hp: int = 50

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

# Отложенный толчок (разлёт при смерти кабины): скорость нельзя задать, пока тело
# заморожено — заявка хранится и применяется ровно в момент разморозки ниже.
var _pending_kick: Vector3 = Vector3.ZERO

func kick(vel: Vector3) -> void:
	_pending_kick = vel

func _on_parent_changed() -> void:
	await get_tree().process_frame
	if get_parent() == null:
		return
	freeze = not (get_parent().name in "objects")
	if not freeze and _pending_kick != Vector3.ZERO:
		var v := _pending_kick
		_pending_kick = Vector3.ZERO
		# Правильный толчок RigidBody3D: дождаться, пока смена freeze ДОЕДЕТ до физсервера
		# (кадр физики), разбудить и дать импульс. Прямое linear_velocity в тот же кадр,
		# что и разморозка, сервер молча съедал — блоки не разлетались.
		await get_tree().physics_frame
		if not is_inside_tree() or freeze:
			return
		sleeping = false
		apply_central_impulse(v * mass)




func hurt(damage: int = 10) -> void:
	current_hp -= damage
	_play_hit_effect()
	if current_hp <= 0:
		destroy()

func _play_hit_effect() -> void:
	# Собираем ВСЕ меши внутри блока
	var meshes: Array = []
	_collect_meshes(self, meshes)
	if meshes.is_empty(): return

	# Для каждого меша дублируем все его сурфейсы
	var mats: Array = []
	for mesh in meshes:
		for s in mesh.get_surface_override_material_count():
			var mat = mesh.get_surface_override_material(s)
			if mat == null:
				var base = mesh.get_active_material(s)
				if base == null: continue
				mat = base.duplicate()
				mesh.set_surface_override_material(s, mat)
			mats.append(mat)

	if mats.is_empty(): return

	# Запоминаем исходные цвета
	var original_colors: Array = []
	for mat in mats:
		original_colors.append(mat.albedo_color)

	# Scale анимация
	var tween = create_tween()
	tween.tween_property(self, "scale", Vector3.ONE * 1.1, 0.07)
	tween.tween_property(self, "scale", Vector3.ONE * 0.9, 0.07)
	tween.tween_property(self, "scale", Vector3.ONE, 0.07)

	# Цвет анимация — красный и обратно к оригиналу
	for i in mats.size():
		var mat = mats[i]
		var orig = original_colors[i]
		var tween2 = create_tween()
		tween2.tween_property(mat, "albedo_color", Color.RED, 0.05)
		tween2.tween_property(mat, "albedo_color", orig, 0.15)


func _collect_meshes(node: Node, result: Array) -> void:
	if node is MeshInstance3D:
		result.append(node)
	for child in node.get_children():
		_collect_meshes(child, result)

func destroy() -> void:
	emit_signal("destroyed", self)
	queue_free()
