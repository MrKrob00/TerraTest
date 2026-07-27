class_name BlockFX
extends RefCounted
# Эффект «матрицы» на блоке (block_matrix.gdshader): одной строкой
#   BlockFX.play(block, false)   — появление: «хмара» плоских 2D-глитч-карточек разного
#                                  размера на разной глубине вокруг блока (glitch_card.gdshader)
#   BlockFX.play(block, true)    — уничтожение: та же хмара карточек, мерцает и гаснет
#   BlockFX.hit(block)           — попадание: короткая вспышка КРАСНЫХ 0/1 (как раньше) на
#                                  1-2 случайных гранях блока (mode 2)
#
# ВАЖНО: эффект — РЕБЁНОК движущегося узла, а не мировой снапшот в сцене. Машина в стройке
# левитирует (и вообще ездит) — снапшот-версия оставалась на одной позиции и «отставала».
#   • появление/попадание → ребёнок САМОГО блока (едет и живёт вместе с ним);
#   • уничтожение → ребёнок родителя блока (blocks-нода машины / objects): переживает блок
#     и продолжает ехать с машиной; фолбэк — текущая сцена.
# Гонит progress 0→1 и сам себя удаляет.

const SHADER := preload("res://block_matrix.gdshader")   # урон (mode 2, красные цифры) — hit()
const SHADER_HP := preload("res://block_hp.gdshader")    # постоянный оверлей хп (свой режим глубины)
const CARD_SHADER := preload("res://glitch_card.gdshader")   # глитч-карточки (появление/исчезновение)
const CARD_COUNT := 28          # сколько карточек в «хмаре» (много; часть видна по ходу анимации)
const CARD_SPREAD := 1.25       # насколько шире блока разлетаются карточки

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

	# «Хмара» глитч-карточек: плоские 2D-билборды РАЗНОГО размера на РАЗНОЙ глубине внутри/
	# вокруг блока, cyan/magenta, мерцают и гаснут (глитч появления/исчезновения — вариант 1).
	var cloud := Node3D.new()
	host.add_child(cloud)
	cloud.global_transform = block.global_transform * Transform3D(Basis(), aabb.get_center())
	var half := aabb.size * 0.5
	var mats: Array = []
	for i in CARD_COUNT:
		var card := MeshInstance3D.new()
		var q := QuadMesh.new()
		q.size = Vector2.ONE
		card.mesh = q
		card.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var cmat := ShaderMaterial.new()
		cmat.shader = CARD_SHADER
		cmat.set_shader_parameter("seed", randf() * 100.0)                       # свой цвет/форма патча
		cmat.set_shader_parameter("grid_cells", 4.0 if randf() < 0.5 else 6.0)   # 4×4 или 6×6
		cmat.set_shader_parameter("fill_threshold", randf_range(0.38, 0.5))      # форма пятна
		cmat.set_shader_parameter("progress", 0.0)
		card.material_override = cmat
		cloud.add_child(card)
		# позиция вразброс в пределах блока (чуть шире), масштаб случайный → разные размеры/глубины
		card.position = Vector3(randf_range(-half.x, half.x), randf_range(-half.y, half.y),
				randf_range(-half.z, half.z)) * CARD_SPREAD
		var s := randf_range(aabb.size.length() * 0.10, aabb.size.length() * 0.35)
		card.scale = Vector3(s, s, 1.0)
		mats.append(cmat)

	var dur := duration
	if dur <= 0.0:
		dur = 0.7 if destroy else 0.8
	var tw := cloud.create_tween()
	tw.tween_method(_set_cards_progress.bind(mats), 0.0, 1.0, dur)
	tw.tween_callback(cloud.queue_free)

static func _set_cards_progress(p: float, mats: Array) -> void:
	for m in mats:
		if is_instance_valid(m):
			(m as ShaderMaterial).set_shader_parameter("progress", p)

const HIT_THICKNESS := 0.08   # толщина пластины вспышки попадания
const HIT_DURATION := 0.3

# Попадание (block.gd/VehicleBlock.hurt): 1-2 случайные грани блока на миг вспыхивают
# красными 0/1 — лёгкая обратная связь на урон, БЕЗ полной коробки-оболочки (это не
# спавн и не смерть). Пластина — тонкий BoxMesh, а не отдельно ориентированный квад:
# переиспользуем ту же схему трансформа, что и play(), без риска напутать с осями.
static func hit(block: Node3D, faces: int = 2) -> void:
	if block == null or not block.is_inside_tree():
		return
	var aabb := _local_aabb(block)
	var dirs: Array = [Vector3.RIGHT, Vector3.LEFT, Vector3.UP, Vector3.DOWN, Vector3.FORWARD, Vector3.BACK]
	dirs.shuffle()
	for i in mini(faces, dirs.size()):
		_spawn_hit_flash(block, aabb, dirs[i])

static func _spawn_hit_flash(block: Node3D, aabb: AABB, dir: Vector3) -> void:
	var center := aabb.get_center()
	var half := aabb.size * 0.5

	var plate_size := aabb.size
	if absf(dir.x) > 0.5:      plate_size.x = HIT_THICKNESS
	elif absf(dir.y) > 0.5:    plate_size.y = HIT_THICKNESS
	else:                      plate_size.z = HIT_THICKNESS

	# Центр пластины — на выбранной грани блока, чуть наружу (не тонет в поверхности).
	var axis := 0 if absf(dir.x) > 0.5 else (1 if absf(dir.y) > 0.5 else 2)
	var plate_center := center + dir * (half[axis] + HIT_THICKNESS * 0.5 + 0.01)

	var fx := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3.ONE
	fx.mesh = bm
	fx.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var mat := ShaderMaterial.new()
	mat.shader = SHADER
	mat.set_shader_parameter("mode", 2)
	mat.set_shader_parameter("progress", 0.0)
	mat.set_shader_parameter("seed", randf() * 100.0)
	fx.material_override = mat
	block.add_child(fx)
	fx.transform = Transform3D(Basis().scaled(plate_size), plate_center)

	var tw := fx.create_tween()
	tw.tween_method(func(p: float) -> void: mat.set_shader_parameter("progress", p), 0.0, 1.0, HIT_DURATION)
	tw.tween_callback(fx.queue_free)

# ── Постоянный оверлей ХП (mode 3) ───────────────────────────────────────────────
# Куб-оболочка 1³ на весь блок (как play(), но НЕ анимируется и НЕ удаляется) — ребёнок
# блока, едет и вращается с ним. Густота/яркость красных цифр гонит юниформ `damage`,
# который блок обновляет ТОЛЬКО при изменении хп (не по кадрам). При полном хп блок прячет
# узел (см. VehicleBlock._refresh_hp_fx) → на целых блоках нулевая цена. Создаём лениво —
# на первом же уроне, чтобы неповреждённые блоки не плодили узлы вовсе.
static func hp_overlay(block: Node3D) -> MeshInstance3D:
	var aabb := _local_aabb(block)
	var fx := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3.ONE
	fx.mesh = bm
	fx.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var mat := ShaderMaterial.new()
	mat.shader = SHADER_HP
	mat.set_shader_parameter("damage", 0.0)
	mat.set_shader_parameter("seed", randf() * 100.0)
	fx.material_override = mat
	block.add_child(fx)
	# Локальный трансформ (ребёнок блока, aabb уже в осях блока): чуть больше габарита блока.
	fx.transform = Transform3D(Basis().scaled(aabb.size * 1.04 + Vector3(0.03, 0.03, 0.03)),
			aabb.get_center())
	return fx

# Коробка эффекта не может быть больше этого по каждой оси: страховка от FX-мешей
# (луч лазера в момент выстрела и т.п.), которые не описывают сам блок.
const MAX_EXTENT := 2.0

# AABB блока В ЕГО СОБСТВЕННЫХ ОСЯХ: объединяем AABB всех MeshInstance3D, переведя их
# в систему координат блока. Повёрнутый блок получает плотную коробку по своим граням,
# а не раздутый мировой AABB. Пропускаем:
#   • СКРЫТЫЕ ветки — у оружия детьми висят выключенные FX (луч-цилиндр дальностью в
#     десятки метров, глоу-сферы, трассер), с ними коробка выходила гигантской;
#   • поддеревья Area3D — это триггеры/индикаторы дальности (напр. у коллектора
#     Area3D с кольцом-визуалом радиуса сбора ~5 м), а не тело самого блока; без этого
#     пропуска коробка коллектора раздувалась под гигантское кольцо и обрезалась
#     страховкой MAX_EXTENT до случайного размера вместо настоящих габаритов блока.
static func _local_aabb(block: Node3D) -> AABB:
	var inv := block.global_transform.affine_inverse()
	var acc := AABB()
	var has := false
	var stack: Array = [block]
	while not stack.is_empty():
		var n = stack.pop_back()
		if n is Node3D and not (n as Node3D).visible:
			continue                       # скрытая ветка (FX) — не считаем и не спускаемся
		if n is Area3D and n != block:
			continue                       # триггер/индикатор дальности — не тело блока
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
		return AABB(Vector3(-0.5, -0.5, -0.5), Vector3.ONE)
	# Потолок размера: видимый FX (лазер стреляет прямо в момент сноса) всё ещё может
	# растянуть AABB — обрезаем коробку до MAX_EXTENT вокруг центра блока.
	var half := MAX_EXTENT * 0.5
	acc = acc.intersection(AABB(Vector3(-half, -half, -half), Vector3(MAX_EXTENT, MAX_EXTENT, MAX_EXTENT)))
	if acc.size.x <= 0.0 or acc.size.y <= 0.0 or acc.size.z <= 0.0:
		return AABB(Vector3(-0.5, -0.5, -0.5), Vector3.ONE)
	return acc
