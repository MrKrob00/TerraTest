class_name BlockFX
extends RefCounted
# Эффект «матрицы» на блоке (block_matrix.gdshader): одной строкой
#   BlockFX.play(block, false)   — появление (зелёные 0/1, волна снизу вверх)
#   BlockFX.play(block, true)    — уничтожение (красные + глюк, растворение сверху вниз)
# Строит коробку-оболочку по МИРОВОМУ AABB блока, кладёт в текущую сцену (снимок позиции —
# для уничтожения эффект остаётся, даже когда блок исчез), гонит progress 0→1 и сам себя
# удаляет. Сам блок под оболочкой виден как есть.

const SHADER := preload("res://block_matrix.gdshader")

static func play(block: Node3D, destroy: bool, duration: float = -1.0) -> void:
	if block == null or not block.is_inside_tree():
		return
	var scene: Node = block.get_tree().current_scene
	if scene == null:
		return
	var aabb := _world_aabb(block)

	var fx := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3.ONE
	fx.mesh = bm
	fx.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var mat := ShaderMaterial.new()
	mat.shader = SHADER
	mat.set_shader_parameter("mode", 1 if destroy else 0)
	mat.set_shader_parameter("progress", 0.0)
	fx.material_override = mat
	scene.add_child(fx)
	fx.global_position = aabb.get_center()
	fx.scale = aabb.size * 1.05 + Vector3(0.05, 0.05, 0.05)   # чуть больше блока — цифры «поверх»

	var dur := duration
	if dur <= 0.0:
		dur = 0.5 if destroy else 0.6
	var tw := fx.create_tween()
	tw.tween_method(func(p: float) -> void: mat.set_shader_parameter("progress", p), 0.0, 1.0, dur)
	tw.tween_callback(fx.queue_free)

# Мировой AABB блока: объединяем AABB всех его MeshInstance3D (в мировых координатах).
static func _world_aabb(block: Node3D) -> AABB:
	var acc := AABB()
	var has := false
	var stack: Array = [block]
	while not stack.is_empty():
		var n = stack.pop_back()
		for c in n.get_children():
			stack.append(c)
		if n is MeshInstance3D and n.mesh != null:
			var la: AABB = n.get_aabb()
			var xf: Transform3D = n.global_transform
			for i in 8:
				var corner := la.position + Vector3(
						la.size.x * float(i & 1),
						la.size.y * float((i >> 1) & 1),
						la.size.z * float((i >> 2) & 1))
				var wp := xf * corner
				if not has:
					acc = AABB(wp, Vector3.ZERO)
					has = true
				else:
					acc = acc.expand(wp)
	if not has:
		acc = AABB(block.global_position - Vector3(0.5, 0.5, 0.5), Vector3.ONE)
	return acc
