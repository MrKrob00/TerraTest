class_name BlockFX
extends RefCounted

const SHADER := preload("res://block_matrix.gdshader")   # урон (mode 2, красные цифры) — hit()
const SHADER_HP := preload("res://block_hp.gdshader")    # постоянный оверлей хп (свой режим глубины)
const CARD_SHADER := preload("res://glitch_card.gdshader")   # глитч-карточки (появление/исчезновение)
const CARD_COUNT := 28          # сколько карточек в «хмаре» (много; часть видна по ходу анимации)
# Потолок карточек, которые можно создать за ОДИН кадр по всей игре. Сборка машины зовёт play()
# на каждый блок сразу: 40 блоков × 28 = 1120 MeshInstance3D + столько же QuadMesh и
# ShaderMaterial в одном кадре — заметный хич на загрузке/респавне. Сверх лимита эффект просто
# получает меньше карточек (или пропускается) — визуально почти незаметно, зато без просадки.
const CARDS_PER_FRAME := 120
static var _cards_frame: int = -1
static var _cards_used: int = 0
const CARD_SPREAD := 1.25       # насколько шире блока разлетаются карточки

# AOE-взрыв: урон блокам в радиусе (спад от центра) + дешёвый огненный эффект (два additive-меша,
# без частиц/света — легко для мобильного GPU). Батарея зовёт это при уничтожении. exclude_root —
# машина, которую НЕ бить (напр. ракета не бьёт свою); для батареи null — взрывает всё вокруг.
#
# push — импульс СВОБОДНЫМ блокам (тем, что уже лежат в мире, freeze = false). Блоки на машине
# толкать нечем: их держит родитель, и импульс телу блока физика просто игнорирует. Те, что
# оторвутся ИЗ-ЗА этого взрыва, разлетаются по метке machine_body.register_blast — её ставит
# тот, кто взрывается.
static func explosion(anchor: Node3D, world_pos: Vector3, radius: float, dmg: int, exclude_root: Node = null, push: float = 0.0) -> void:
	if not is_instance_valid(anchor):
		return
	var world := anchor.get_world_3d()
	if world != null:
		var sphere := SphereShape3D.new()
		sphere.radius = radius
		var q := PhysicsShapeQueryParameters3D.new()
		q.shape = sphere
		q.transform = Transform3D(Basis(), world_pos)
		q.collision_mask = 2                                # слой блоков (VehicleBlock.collision_layer=2)
		q.collide_with_bodies = true
		var seen := {}
		for hit in world.direct_space_state.intersect_shape(q, 48):
			var b = hit.get("collider")
			if b == null or seen.has(b) or b == anchor or not b.has_method("hurt"):
				continue
			if exclude_root != null and _root_of(b) == exclude_root:
				continue
			seen[b] = true
			var dist: float = (b as Node3D).global_position.distance_to(world_pos)
			var f: float = clampf(1.0 - dist / radius, 0.15, 1.0)   # спад урона к краю
			# Толкаем ДО урона: hurt может убить блок, а мёртвому импульс уже не нужен.
			if push > 0.0 and b is RigidBody3D and not (b as RigidBody3D).freeze:
				var away: Vector3 = (b as Node3D).global_position - world_pos
				if away.length_squared() < 0.01:                     # 0.1², только сравнение
					away = Vector3(randf() - 0.5, 0.4, randf() - 0.5)
				away = (away.normalized() + Vector3.UP * 0.35).normalized()
				(b as RigidBody3D).apply_central_impulse(away * push * f * (b as RigidBody3D).mass)
			b.hurt(int(round(dmg * f)))
	var tree := anchor.get_tree()
	if tree != null and tree.current_scene != null:
		_boom(tree.current_scene, world_pos, radius, Color(1.0, 0.55, 0.15), 4.0, 0.38)   # огненный шар
		_boom(tree.current_scene, world_pos, radius * 0.55, Color(1.0, 0.95, 0.7), 6.0, 0.22)  # горячее ядро

static func _root_of(n: Node) -> Node:
	var p: Node = n
	while p != null and not (p is RigidBody3D):
		p = p.get_parent()
	return p

static func _boom(root: Node, pos: Vector3, target_r: float, col: Color, energy: float, dur: float) -> void:
	var mi := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = 0.5
	sm.height = 1.0
	sm.radial_segments = 10
	sm.rings = 6
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	mat.albedo_color = Color(col.r, col.g, col.b, 1.0)
	mat.emission_enabled = true
	mat.emission = col
	mat.emission_energy_multiplier = energy
	sm.material = mat
	mi.mesh = sm
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(mi)
	mi.global_position = pos
	mi.scale = Vector3.ONE * 0.25
	var tw := mi.create_tween()
	tw.set_parallel(true)
	tw.tween_property(mi, "scale", Vector3.ONE * (target_r / 0.5), dur).set_ease(Tween.EASE_OUT)
	tw.tween_property(mat, "albedo_color:a", 0.0, dur).set_ease(Tween.EASE_IN)
	tw.tween_property(mat, "emission_energy_multiplier", 0.0, dur)
	tw.chain().tween_callback(mi.queue_free)

## Зелёный «матрицы» ремонта. Различает эффекты не только цвет, но и ФОРМА: ремонт — это
## цифры 0/1 по всей оболочке, а появление и распад блока — облако глитч-карточек. Одного
## цвета было мало, карточки узнаются по силуэту и в зелёном читались всё тем же распадом.
const HEAL_A := Color(0.25, 1.0, 0.45)

## Эффект ремонта блока: ЗЕЛЁНЫЕ ЦИФРЫ 0/1 по всей оболочке блока — та же «матрица», что
## показывает урон (block_matrix.gdshader, mode 2), только зелёная и по всему блоку сразу.
##
## Раньше heal звал play(), а play строит облако ГЛИТЧ-КАРТОЧЕК — тот эффект, которым блок
## появляется и разваливается. Ремонт от него читался как «блок сейчас сломается», то есть
## ровно наоборот. Цвет тут ничего не решал: карточки узнаются по форме, а не по оттенку.
##
## Оболочка — один куб на блок, а не шесть пластин, как у попадания (_spawn_hit_flash):
## попадание приходит В ГРАНЬ, и его показывают на грани, а чинится блок целиком.
static func heal(block: Node3D, duration: float = 0.55) -> void:
	if block == null or not block.is_inside_tree():
		return
	var aabb := _local_aabb(block)
	var fx := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3.ONE
	fx.mesh = bm
	fx.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var mat := ShaderMaterial.new()
	mat.shader = SHADER
	mat.set_shader_parameter("mode", 2)              # цифры 0/1
	mat.set_shader_parameter("color_damage", HEAL_A) # ...но зелёные: та же матрица, другой смысл
	mat.set_shader_parameter("damage_cells", 10.0)   # мельче, чем у урона: ремонт «шьёт», а не бьёт
	mat.set_shader_parameter("progress", 0.0)
	mat.set_shader_parameter("seed", randf() * 100.0)
	fx.material_override = mat
	block.add_child(fx)
	# Чуть больше самого блока, иначе цифры z-борются с его поверхностью и мерцают.
	fx.transform = Transform3D(Basis().scaled(aabb.size * 1.04), aabb.get_center())
	var tw := fx.create_tween()
	tw.tween_method(func(p: float) -> void: mat.set_shader_parameter("progress", p), 0.0, 1.0, duration)
	tw.tween_callback(fx.queue_free)

static func play(block: Node3D, destroy: bool, duration: float = -1.0,
		tint_a: Color = Color(0, 0, 0, 0), tint_b: Color = Color(0, 0, 0, 0)) -> void:
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
	# Бюджет карточек на кадр (см. CARDS_PER_FRAME): считаем кадры по счётчику движка.
	var frame := Engine.get_frames_drawn()
	if frame != _cards_frame:
		_cards_frame = frame
		_cards_used = 0
	var budget: int = maxi(CARDS_PER_FRAME - _cards_used, 0)
	var count: int = mini(CARD_COUNT, budget)
	_cards_used += count
	if count <= 0:
		cloud.queue_free()
		return
	for i in count:
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
		# Прозрачная «пустая» краска = цвета шейдера по умолчанию (cyan/magenta).
		if tint_a.a > 0.0:
			cmat.set_shader_parameter("glitch_a", Vector3(tint_a.r, tint_a.g, tint_a.b))
		if tint_b.a > 0.0:
			cmat.set_shader_parameter("glitch_b", Vector3(tint_b.r, tint_b.g, tint_b.b))
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
