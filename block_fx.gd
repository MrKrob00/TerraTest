class_name BlockFX
extends RefCounted

const SHADER := preload("res://block_matrix.gdshader")   # урон (mode 2, красные цифры) — hit()
const SHADER_HP := preload("res://block_hp.gdshader")    # постоянный оверлей хп (свой режим глубины)
const CARD_SHADER := preload("res://glitch_card.gdshader")   # глитч-карточки (появление/исчезновение)
## АВТОЛОАД ИЗ СТАТИКИ БЕРЁТСЯ УЗЛОМ. По имени к нему отсюда не обратиться — в этом файле всё
## статическое. Раньше здесь лежала ссылка на СКРИПТ G и функция вызывалась от него, что требовало
## держать её static; из-за этого все девятнадцать обычных вызовов вида G.is_loose_item() были
## предупреждением «статику зовут от экземпляра». Цикла нет: G про эффекты не знает.
static func _progress() -> Node:
	var loop := Engine.get_main_loop() as SceneTree
	return loop.root.get_node_or_null("/root/G") if loop != null else null
const CARD_COUNT := 28          # сколько карточек в «хмаре» (много; часть видна по ходу анимации)
# Потолок карточек, которые можно создать за ОДИН кадр по всей игре. Сборка машины зовёт play()
# на каждый блок сразу: 40 блоков × 28 = 1120 MeshInstance3D + столько же QuadMesh и
# ShaderMaterial в одном кадре — заметный хич на загрузке/респавне. Сверх лимита эффект просто
# получает меньше карточек (или пропускается) — визуально почти незаметно, зато без просадки.
const CARDS_PER_FRAME := 120
static var _cards_frame: int = -1
static var _cards_used: int = 0
const CARD_SPREAD := 1.25       # насколько шире блока разлетаются карточки

# ─────────────────────────────────────────────────────────────────────────────
# ВСПЫШКА: единственный настоящий свет в игре
# ─────────────────────────────────────────────────────────────────────────────
#
# До этого в проекте был ровно ОДИН источник света — солнце, и ни одного OmniLight3D. Дуло
# лазера светило эмиссивной сферой, то есть яркой краской, которая ничего вокруг не освещала.
# Теперь выстрел и взрыв зажигают настоящую лампу, и вместе с включённым glow (см. Environment
# в node_3d.tscn) она читается как свет, а не как наклейка.
#
# ЛАМП ШЕСТЬ НА ВСЮ ИГРУ, И ОНИ ПЕРЕИСПОЛЬЗУЮТСЯ. Создавать OmniLight3D на выстрел нельзя: в
# большом бою десяток стволов бьёт очередями, а узел со светом на каждый выстрел — это хич на
# ровном месте. Новая вспышка забирает самую старую лампу; при скорострельности оружия глазу
# этого не видно, зато цена ограничена сверху числом, а не боем.
#
# ТЕНИ ВЫКЛЮЧЕНЫ ВСЕГДА. Compatibility считает освещение по вершинам (force_vertex_shading в
# project.godot), и вспышка и так ложится плоско; теневая карта на каждый выстрел стоила бы
# больше, чем весь эффект.
#
# ДАЛЬШЕ FLASH_DIST ЛАМПА НЕ ЗАЖИГАЕТСЯ ВОВСЕ. Вспышка живёт десятые доли секунды и на таком
# расстоянии не видна, а бой идёт по всей карте — без этой проверки пул целиком уходил бы на
# перестрелку, которую никто не смотрит.
const LAMPS := 6
const FLASH_DIST := 110.0
static var _lamps: Array = []
static var _lamp_at: int = 0

## Зажечь вспышку в мировой точке. anchor — любой узел в дереве (нужен только чтобы добраться
## до сцены и камеры), dur — за сколько секунд она гаснет.
static func flash(anchor: Node, pos: Vector3, col: Color, energy: float, rng: float,
		dur: float) -> void:
	if anchor == null or not is_instance_valid(anchor) or not anchor.is_inside_tree():
		return
	var tree := anchor.get_tree()
	if tree == null:
		return
	# Лампы вешаем на сцену, но если её нет (мир собран кодом, стенд, редакторское превью) —
	# на корень. Пустой current_scene раньше означал бы, что света просто не будет, и заметить
	# это нечем: вспышка не падает, она НЕ ПОЯВЛЯЕТСЯ.
	var host: Node = tree.current_scene if tree.current_scene != null else tree.root
	var vp := anchor.get_viewport()
	var cam: Camera3D = vp.get_camera_3d() if vp != null else null
	if cam == null or cam.global_position.distance_squared_to(pos) > FLASH_DIST * FLASH_DIST:
		return
	var lamp := _take_lamp(host)
	if lamp == null:
		return
	lamp.global_position = pos
	lamp.light_color = col
	lamp.omni_range = rng
	lamp.light_energy = energy
	lamp.visible = true
	var tw := lamp.create_tween()
	tw.tween_property(lamp, "light_energy", 0.0, dur).set_ease(Tween.EASE_OUT)
	tw.tween_callback(_hide_lamp.bind(lamp))
	# Твин держим НА САМОЙ ЛАМПЕ: забирая её под новую вспышку, старый надо оборвать, иначе два
	# твина тянут одну энергию в разные стороны и лампа моргает невпопад. Своего kill_tweens у
	# Node нет, так что ссылку храним сами.
	lamp.set_meta("fx_tw", tw)

static func _take_lamp(root: Node) -> OmniLight3D:
	# Пул переживает смену сцены, а лампы — нет: они дети сцены и умирают вместе с ней.
	for i in range(_lamps.size() - 1, -1, -1):
		if not is_instance_valid(_lamps[i]):
			_lamps.remove_at(i)
	if _lamps.size() < LAMPS:
		var made := OmniLight3D.new()
		made.shadow_enabled = false
		made.visible = false
		root.add_child(made)
		_lamps.append(made)
		return made
	if _lamp_at >= _lamps.size():
		_lamp_at = 0
	var lamp: OmniLight3D = _lamps[_lamp_at]
	_lamp_at = (_lamp_at + 1) % _lamps.size()
	if lamp.has_meta("fx_tw"):               # get_meta без has_meta падает, см. правило 4
		var old: Variant = lamp.get_meta("fx_tw")
		if old is Tween and (old as Tween).is_valid():
			(old as Tween).kill()
	return lamp

static func _hide_lamp(lamp: OmniLight3D) -> void:
	if is_instance_valid(lamp):
		lamp.visible = false           # погасшая лампа не должна стоить ничего

# AOE-взрыв: урон блокам в радиусе (спад от центра) + красное облако глитч-карточек
# (blast_cards, без частиц и света — легко для мобильного GPU). Батарея зовёт это при
# уничтожении. exclude_root —
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
		for found in world.direct_space_state.intersect_shape(q, 48):
			var b = found.get("collider")
			if b == null or seen.has(b) or b == anchor or not b.has_method("hurt"):
				continue
			if exclude_root != null and _root_of(b) == exclude_root:
				continue
			# КУПОЛ СВОЕГО ЩИТА AOE НЕ БЬЁТ. Проверки выше его не ловят: _root_of идёт вверх до
			# первого RigidBody3D, а у купола это САМ БЛОК ЩИТА, а не машина. Поэтому своя же
			# ракета, взорвавшись рядом, списывала энергию с собственного щита — и тем сильнее,
			# чем ближе цель, то есть ровно тогда, когда игрок обороняется.
			var g: Node = _progress()
			if g != null and g.is_friendly_dome(b, exclude_root):
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
		blast_cards(tree.current_scene, world_pos, radius)

static func _root_of(n: Node) -> Node:
	var p: Node = n
	while p != null and not (p is RigidBody3D):
		p = p.get_parent()
	return p

## КРАСНЫЙ МАТРИЧНЫЙ ВЗРЫВ. Раньше здесь надувались две additive-сферы — оранжевый шар и
## белое ядро. Выглядело это чужеродно: во всей игре появление, гибель, урон и ремонт говорят
## ГЛИТЧ-КАРТОЧКАМИ и матричными цифрами, и только взрыв был мультяшным огоньком из другой
## игры. Теперь он из того же словаря — облако красных карточек, разлетающееся на радиус
## поражения, то есть заодно и ЧЕСТНО ПОКАЗЫВАЮЩЕЕ, докуда достаёт урон.
const BLAST_A := Color(1.0, 0.16, 0.12)     # алый
const BLAST_B := Color(1.0, 0.62, 0.10)     # и раскалённый край: две краски глитча
const BLAST_CARDS := 34
const BLAST_DUR := 0.55

static func blast_cards(root: Node, pos: Vector3, radius: float) -> void:
	if root == null or not is_instance_valid(root):
		return
	var count: int = _take_card_budget(BLAST_CARDS)
	if count <= 0:
		return
	var cloud := Node3D.new()
	cloud.set_meta("block_fx", true)        # см. _local_aabb
	root.add_child(cloud)
	cloud.global_position = pos
	var mats: Array = []
	for i in count:
		var card := MeshInstance3D.new()
		var q := QuadMesh.new()
		q.size = Vector2.ONE
		card.mesh = q
		card.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var cmat := ShaderMaterial.new()
		cmat.shader = CARD_SHADER
		cmat.set_shader_parameter("seed", randf() * 100.0)
		cmat.set_shader_parameter("grid_cells", 4.0 if randf() < 0.5 else 6.0)
		cmat.set_shader_parameter("fill_threshold", randf_range(0.34, 0.5))
		cmat.set_shader_parameter("progress", 0.0)
		cmat.set_shader_parameter("glitch_a", Vector3(BLAST_A.r, BLAST_A.g, BLAST_A.b))
		cmat.set_shader_parameter("glitch_b", Vector3(BLAST_B.r, BLAST_B.g, BLAST_B.b))
		card.material_override = cmat
		cloud.add_child(card)
		# Точки по ШАРУ, а не по кубу: у взрыва есть радиус, и облако обязано быть круглым —
		# иначе углы куба торчат за границу поражения и врут про неё.
		var dir := Vector3(randf() - 0.5, randf() - 0.5, randf() - 0.5)
		dir = dir.normalized() if dir.length_squared() > 0.0001 else Vector3.UP
		# Кубический корень от равномерного числа даёт РАВНОМЕРНУЮ плотность по объёму;
		# без него карточки сбивались бы в центр, и края взрыва оставались пустыми.
		card.position = dir * radius * pow(randf(), 1.0 / 3.0)
		var s := randf_range(radius * 0.18, radius * 0.5)
		card.scale = Vector3(s, s, 1.0)
		mats.append(cmat)
	var tw := cloud.create_tween()
	tw.set_parallel(true)
	tw.tween_method(_set_cards_progress.bind(mats), 0.0, 1.0, BLAST_DUR)
	# Само облако РАЗЛЕТАЕТСЯ: карточки стоят на своих местах внутри него, а масштабируется
	# узел целиком — один твин вместо тридцати четырёх.
	cloud.scale = Vector3.ONE * 0.35
	tw.tween_property(cloud, "scale", Vector3.ONE, BLAST_DUR).set_ease(Tween.EASE_OUT)
	tw.chain().tween_callback(cloud.queue_free)
	# Свет взрыва — здесь, а не у того, кто взорвался: blast_cards это единственная дверь, через
	# неё проходят и батарея, и кабина, и догоревший предохранитель. Радиус вдвое шире облака,
	# чтобы взрыв подсвечивал то, что вокруг, а не только себя.
	# Яркость по той же причине, что у дула: свет считается в вершинах и размазывается по
	# треугольнику (см. WeaponBlock.flash_energy). Радиус вдвое шире облака — взрыв обязан
	# подсветить то, что вокруг, а не только себя.
	flash(root, pos, BLAST_A, 16.0, radius * 2.5, BLAST_DUR)

## Сколько карточек можно создать в этом кадре (общий потолок на всю игру, см. CARDS_PER_FRAME).
## Вынесено из play(), потому что считать бюджет обязаны ВСЕ, кто их создаёт: цепной взрыв
## рвёт по десятку блоков сразу, и без общего счёта это тысяча узлов в одном кадре.
static func _take_card_budget(want: int) -> int:
	var frame := Engine.get_frames_drawn()
	if frame != _cards_frame:
		_cards_frame = frame
		_cards_used = 0
	var n: int = mini(want, maxi(CARDS_PER_FRAME - _cards_used, 0))
	_cards_used += n
	return n

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
	cloud.set_meta("block_fx", true)        # см. _local_aabb
	host.add_child(cloud)
	cloud.global_transform = block.global_transform * Transform3D(Basis(), aabb.get_center())
	var half := aabb.size * 0.5
	var mats: Array = []
	# Бюджет карточек на кадр (см. CARDS_PER_FRAME) — общий с взрывом, поэтому в одной функции.
	var count: int = _take_card_budget(CARD_COUNT)
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

## ФИТИЛЬ: КРАСНАЯ МАТРИЦА, КОТОРАЯ РАЗГОРАЕТСЯ. Догорающий блок раньше просто МИГАЛ
## видимостью, всё быстрее, — и это был компромисс, а не замысел: подкрасить сам блок нельзя,
## материалы у моделей ОБЩИЕ между экземплярами, и покрасить один значило покрасить все такие
## в игре. Оболочка эту проблему снимает целиком: это отдельный меш со своим материалом, как у
## ремонта, только красный.
##
## Гоним progress ОТ 1 К 0: в mode 2 шейдера альфа считается как (1 − progress), то есть
## единица — это «ничего не видно», а ноль — полная сила. С EASE_IN первую половину фитиля
## блок едва тлеет, а к концу заливается красным — ровно то, что должен сообщать фитиль:
## «время ещё есть» и «времени больше нет».
const FUSE_COL := Color(1.0, 0.14, 0.10)

static func fuse(block: Node3D, duration: float) -> void:
	if block == null or not block.is_inside_tree() or duration <= 0.0:
		return
	var aabb := _local_aabb(block)
	var fx := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3.ONE
	fx.mesh = bm
	fx.set_meta("block_fx", true)          # см. _local_aabb: свои эффекты в габарит не входят
	fx.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var mat := ShaderMaterial.new()
	mat.shader = SHADER
	mat.set_shader_parameter("mode", 2)                 # цифры 0/1 по всей оболочке
	mat.set_shader_parameter("color_damage", FUSE_COL)
	mat.set_shader_parameter("damage_cells", 6.0)       # та же плотность, что у ремонта и оверлея хп
	mat.set_shader_parameter("progress", 1.0)
	mat.set_shader_parameter("seed", randf() * 100.0)
	fx.material_override = mat
	block.add_child(fx)
	# Чуть больше блока — иначе цифры z-борются с его поверхностью и мерцают.
	fx.transform = Transform3D(Basis().scaled(aabb.size * 1.04), aabb.get_center())
	# Твин на САМОЙ оболочке: блок добьют раньше срока — она умрёт вместе с ним, и обращаться
	# к освобождённому материалу будет некому.
	var tw := fx.create_tween()
	tw.tween_method(func(p: float) -> void: mat.set_shader_parameter("progress", p),
			1.0, 0.0, duration).set_ease(Tween.EASE_IN).set_trans(Tween.TRANS_QUAD)

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
	fx.set_meta("block_fx", true)          # см. _local_aabb: свои эффекты в габарит не входят
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
	fx.set_meta("block_fx", true)          # см. _local_aabb: свои эффекты в габарит не входят
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
# ── Материализация МАШИНЫ ЦЕЛИКОМ ────────────────────────────────────────────────
#
# mode 0 у block_matrix уже делает нужное — «собирается снизу вверх, ниже фронта виден настоящий
# блок». Но делает это НА БЛОК: позови его на сорок блоков сразу, и сорок фронтов поедут каждый
# по своему кубику одновременно. Машина должна проявляться ОДНИМ фронтом по всему корпусу.
#
# Поэтому общий прогресс переводится в прогресс КАЖДОГО блока по его месту в корпусе: фронт идёт
# от низа машины к верху, и блок получает свою долю ровно тогда, когда фронт проходит через него.
# Колёса проявляются раньше кабины, потому что они ниже, — а не потому, что им так сказали.
#
# ПО МАТЕРИАЛУ НА БЛОК, И ЭТО НАМЕРЕННО. Общий материал означал бы один progress на всех, то есть
# ту же кашу из сорока одновременных фронтов. Материалов это не ограничивает — ограничены
# instance uniform'ы (см. правило в CLAUDE.md), а их здесь нет вовсе.
const MAT_DUR := 1.4
const MAT_CELLS := 5.0

## Проявить машину целиком. Зовётся на спавне; самоочищается, ничего возвращать не нужно.
static func materialise(machine: Node3D, dur: float = MAT_DUR) -> void:
	if machine == null or not is_instance_valid(machine) or not machine.is_inside_tree():
		return
	var holder: Node = machine.get_node_or_null("blocks")
	if holder == null:
		return
	var shells: Array = []
	var lo: float = INF
	var hi: float = -INF
	for b in holder.get_children():
		var nb := b as Node3D
		if nb == null or nb.has_meta("block_fx"):
			continue
		var aabb := _local_aabb(nb)
		if aabb.size == Vector3.ZERO:
			continue
		# Высота блока в осях МАШИНЫ берётся по его позиции в сетке, а не по его локальному
		# aabb: повёрнутый блок всё равно занимает свою клетку, и фронт обязан идти по корпусу.
		var mid: float = nb.position.y
		var half: float = maxf(aabb.size.y, 0.2) * 0.5
		lo = minf(lo, mid - half)
		hi = maxf(hi, mid + half)
		var fx := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3.ONE
		fx.mesh = bm
		fx.set_meta("block_fx", true)
		fx.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var mat := ShaderMaterial.new()
		mat.shader = SHADER
		mat.set_shader_parameter("mode", 0)
		mat.set_shader_parameter("progress", 0.0)
		mat.set_shader_parameter("cells_per_meter", MAT_CELLS)
		mat.set_shader_parameter("seed", randf() * 100.0)
		fx.material_override = mat
		nb.add_child(fx)
		fx.transform = Transform3D(Basis().scaled(aabb.size * 1.03 + Vector3(0.02, 0.02, 0.02)),
				aabb.get_center())
		shells.append({"mi": fx, "mat": mat, "lo": mid - half, "h": half * 2.0})
	if shells.is_empty():
		return
	# Твин живёт НА МАШИНЕ: погибла машина — оболочки уходят вместе с ней, и обновлять уже нечего.
	var tw := machine.create_tween()
	tw.tween_method(_materialise_step.bind(shells, lo, hi), 0.0, 1.0, dur)
	tw.tween_callback(_materialise_done.bind(shells))

static func _materialise_step(p: float, shells: Array, lo: float, hi: float) -> void:
	var front: float = lerpf(lo, hi, p)
	for s in shells:
		var m = s["mat"]
		if m is ShaderMaterial:
			m.set_shader_parameter("progress",
					clampf((front - float(s["lo"])) / maxf(float(s["h"]), 0.001), 0.0, 1.0))

static func _materialise_done(shells: Array) -> void:
	for s in shells:
		var mi = s["mi"]
		if is_instance_valid(mi):
			mi.queue_free()          # оболочка отработала: дальше виден настоящий блок

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
	# ВНЕ ДЕРЕВА global_transform НЕ СУЩЕСТВУЕТ — движок ругается и возвращает единичный. Сюда
	# такой блок попадает по-настоящему: блок отрывается в мир (detach_block_to_world репарентит
	# его в objects), и ровно в этот момент в него прилетает пуля — hurt → destroy → play. Кадр
	# смерти важнее коробки, поэтому не падаем, а отдаём пустую: эффект просто выйдет размером
	# по умолчанию.
	if not block.is_inside_tree():
		return AABB()
	var inv := block.global_transform.affine_inverse()
	var acc := AABB()
	var has := false
	var stack: Array = [block]
	while not stack.is_empty():
		var n = stack.pop_back()
		if n is Node3D and (not (n as Node3D).visible or not (n as Node3D).is_inside_tree()):
			continue                       # скрытая ветка (FX) или узел вне дерева — пропускаем
		if n is Area3D and n != block:
			continue                       # триггер/индикатор дальности — не тело блока
		# СВОИ ЖЕ ЭФФЕКТЫ В КОРОБКУ НЕ ВХОДЯТ. Пластина вспышки торчит НАРУЖУ грани, оверлей хп
		# на 4 % шире блока — и каждый следующий замер брал их в объединение. Коробка росла с
		# каждым попаданием, пластины лезли всё дальше от блока, и так до потолка MAX_EXTENT:
		# «матрица урона с каждым разом всё больше». Метку ставит тот, кто эффект создал.
		if n != block and n.has_meta("block_fx"):
			continue
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
