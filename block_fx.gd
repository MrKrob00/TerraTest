class_name BlockFX
extends RefCounted
# Эффект «матрицы» на блоке (block_matrix.gdshader): одной строкой
#   BlockFX.play(block, false)   — появление (зелёные 0/1, волна снизу вверх)
#   BlockFX.play(block, true)    — уничтожение (красные + глюк, растворение сверху вниз)
#
# ВАЖНО: эффект — РЕБЁНОК движущегося узла, а не мировой снапшот в сцене. Машина в стройке
# левитирует (и вообще ездит) — снапшот-версия оставалась на одной позиции и «отставала».
#   • появление → ребёнок САМОГО блока (едет и живёт вместе с ним);
#   • уничтожение → ребёнок родителя блока (blocks-нода машины / objects): переживает блок
#     и продолжает ехать с машиной; фолбэк — текущая сцена.
# Гонит progress 0→1 и сам себя удаляет.

const SHADER := preload("res://block_matrix.gdshader")

static func play(block: Node3D, destroy: bool, duration: float = -1.0) -> void:
	if block == null or not block.is_inside_tree():
		return
	var host: Node = block
	if destroy:
		host = block.get_parent()
		if host == null or not (host is Node3D):
			host = block.get_tree().current_scene
	if host == null:
		return
	var aabb := _local_aabb(block)

	var fx := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3.ONE
	fx.mesh = bm
	fx.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var mat := ShaderMaterial.new()
	mat.shader = SHADER
	mat.set_shader_parameter("mode", 1 if destroy else 0)
	mat.set_shader_parameter("progress", 0.0)
	# Свой узор цифр на каждый блок (сетка теперь в локальных осях, без этого узор был бы
	# одинаковым у всех блоков).
	mat.set_shader_parameter("seed",
			wrapf(block.global_position.x * 3.7 + block.global_position.z * 7.1, 0.0, 100.0))
	fx.material_override = mat
	host.add_child(fx)
	# Трансформ выставляем ПОСЛЕ add_child: как ребёнок хоста эффект сохранит относительное
	# положение и дальше едет вместе с ним. Коробка строится В ОСЯХ БЛОКА (его позиция + его
	# ПОВОРОТ + локальный AABB): раньше базис был мировой, без ротации — на повёрнутом блоке
	# эффект стоял криво и не вращался вместе с ним.
	var box_size := aabb.size * 1.05 + Vector3(0.05, 0.05, 0.05)   # чуть больше блока
	fx.global_transform = block.global_transform \
			* Transform3D(Basis().scaled(box_size), aabb.get_center())

	var dur := duration
	if dur <= 0.0:
		dur = 0.5 if destroy else 0.6
	var tw := fx.create_tween()
	tw.tween_method(func(p: float) -> void: mat.set_shader_parameter("progress", p), 0.0, 1.0, dur)
	tw.tween_callback(fx.queue_free)

# AABB блока В ЕГО СОБСТВЕННЫХ ОСЯХ: объединяем AABB всех MeshInstance3D, переведя их
# в систему координат блока. Повёрнутый блок получает плотную коробку по своим граням,
# а не раздутый мировой AABB.
static func _local_aabb(block: Node3D) -> AABB:
	var inv := block.global_transform.affine_inverse()
	var acc := AABB()
	var has := false
	var stack: Array = [block]
	while not stack.is_empty():
		var n = stack.pop_back()
		for c in n.get_children():
			stack.append(c)
		if n is MeshInstance3D and n.mesh != null:
			var la: AABB = n.get_aabb()
			var xf: Transform3D = inv * n.global_transform
			for i in 8:
				var corner := la.position + Vector3(
						la.size.x * float(i & 1),
						la.size.y * float((i >> 1) & 1),
						la.size.z * float((i >> 2) & 1))
				var lp := xf * corner
				if not has:
					acc = AABB(lp, Vector3.ZERO)
					has = true
				else:
					acc = acc.expand(lp)
	if not has:
		acc = AABB(Vector3(-0.5, -0.5, -0.5), Vector3.ONE)
	return acc
