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
# ВСПЫШКА ВЫСТРЕЛА И ВЗРЫВА
# ─────────────────────────────────────────────────────────────────────────────
#
# БЫЛА OmniLight3D, И ЕЁ НЕ БЫЛО ВИДНО. Дважды: сначала с малыми числами, потом с поднятыми
# вчетверо. Причина не в яркости, а в конфигурации рендера: при force_vertex_shading точечные
# источники считаются В ВЕРШИНАХ (цикл по omni стоит внутри вершинного блока шейдера сцены), то
# есть свет на кубе из восьми вершин почти никуда не попадает. А glow, который обычно и продаёт
# вспышку ореолом, снят — он стоил 5 fps из 23.
#
# Значит подход был неверный, а не числа малы. Здесь НЕОСВЕЩАЕМЫЙ ЭМИССИВНЫЙ МЕШ — ровно то, чем
# лазер рисует своё дуло, и это единственное в проекте, что видно наверняка: unshaded не зависит
# ни от вершинного освещения, ни от glow, ни от тонемаппинга.
#
# ШЕСТЬ ШТУК НА ВСЮ ИГРУ, переиспользуются. Новая вспышка забирает самую старую: в бою десяток
# стволов бьёт очередями, и узел на выстрел был бы хичем. Дальше FLASH_DIST не зажигаем вовсе —
# вспышка живёт десятые доли секунды и на таком расстоянии не видна.
const LAMPS := 6
const FLASH_DIST := 110.0
static var _lamps: Array = []
static var _lamp_at: int = 0

## СОБСТВЕННАЯ ВСПЫШКА СТВОЛА, ребёнком дула. Пул ниже (flash) кладёт узлы под корень сцены, то
## есть в МИРОВЫЕ координаты, и это верно для взрыва: он случается в точке мира и машина к нему
## отношения не имеет. Для выстрела — неверно: машина едет, а вспышка оставалась там, где был
## ствол в момент нажатия. Игрок это и увидел.
##
## Поэтому у ствола она своя, ребёнком точки дула: едет и поворачивается вместе с ним без единой
## строки на обновление. Создаётся лениво, на первом выстреле, и дальше только показывается.
static func muzzle_node(muzzle: Node3D, col: Color) -> Node3D:
	var have := muzzle.get_node_or_null("MuzzleFX") as Node3D
	if have != null:
		return have
	var holder := Node3D.new()
	holder.name = "MuzzleFX"
	holder.set_meta("block_fx", true)          # в габарит блока не входит (см. _local_aabb)
	var mi := MeshInstance3D.new()
	mi.mesh = _cone_mesh()
	# −90° по X переводит собственный +Y конуса в −Z держателя, то есть вперёд по стволу.
	mi.rotation_degrees = Vector3(-90.0, 0.0, 0.0)
	mi.material_override = _flash_mat(col)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	holder.add_child(mi)
	holder.visible = false
	muzzle.add_child(holder)
	return holder

## Зажечь вспышку ствола. dir — направление ВЫСТРЕЛА в мировых осях.
##
## ПОВОРОТ БЕРЁТСЯ ОТ ВЫСТРЕЛА, А НЕ ОТ УЗЛА ДУЛА. Вспышка висит ребёнком дула и наследовала его
## поворот, а он у каждой модели свой: художник ставил маркер как удобно. У одной пушки конус
## выходил чуть ниже ствола, у другой развёрнут на девяносто градусов. Направление же у всех
## одно и то же и уже известно — по нему летит пуля.
## Во сколько flash_size конус в начале жизни и в конце: радиус и длина. Растёт и тускнеет.
const MUZZLE_R0 := 0.55
const MUZZLE_L0 := 1.7
const MUZZLE_R1 := 1.15
const MUZZLE_L1 := 3.0

static func muzzle_fire(muzzle: Node3D, dir: Vector3, col: Color, size: float, dur: float) -> void:
	if muzzle == null or not is_instance_valid(muzzle) or not muzzle.is_inside_tree():
		return
	var holder := muzzle_node(muzzle, col)
	# look_at ставит ГЛОБАЛЬНЫЙ поворот, то есть поворот родителя отменяется сам собой. Почти
	# вертикальный ствол пропускаем: там базис вырождается и look_at падает.
	if dir.length_squared() > 0.0001 and absf(dir.normalized().dot(Vector3.UP)) < 0.99:
		holder.look_at(holder.global_position + dir, Vector3.UP)
	var mi := holder.get_child(0) as MeshInstance3D
	if mi == null:
		return
	var mat := mi.material_override as StandardMaterial3D
	if mat != null:
		mat.albedo_color = Color(col.r, col.g, col.b, 0.95)
		mat.emission = col
	# ВСПЫШКА РАСТЁТ, А НЕ СХЛОПЫВАЕТСЯ. Раньше она начинала широкой и вытягивалась в иглу —
	# движение, обратное тому, что делают газы. И она была ЦЕНТРИРОВАНА НА ДУЛЕ, то есть половина
	# её всегда торчала внутри ствола: на снимке видно, как силуэт ствола разрезает конус.
	# Теперь остриё стоит в самом дуле (сдвиг на половину длины вперёд), а конус за свою жизнь
	# расходится.
	var s0 := Vector3(size * MUZZLE_R0, size * MUZZLE_L0, size * MUZZLE_R0)
	var s1 := Vector3(size * MUZZLE_R1, size * MUZZLE_L1, size * MUZZLE_R1)
	mi.scale = s0
	mi.position = Vector3(0.0, 0.0, -0.5 * s0.y)
	holder.visible = true
	if holder.has_meta("fx_tw"):
		var old: Variant = holder.get_meta("fx_tw")
		if old is Tween and (old as Tween).is_valid():
			(old as Tween).kill()
	var tw := holder.create_tween()
	tw.set_parallel(true)
	tw.tween_property(mi, "scale", s1, dur).set_ease(Tween.EASE_OUT)
	# Сдвиг едет вместе с длиной: остриё обязано оставаться в дуле всю жизнь эффекта.
	tw.tween_property(mi, "position", Vector3(0.0, 0.0, -0.5 * s1.y), dur).set_ease(Tween.EASE_OUT)
	if mat != null:
		tw.tween_property(mat, "albedo_color:a", 0.0, dur).set_ease(Tween.EASE_IN)
	tw.chain().tween_callback(_hide_lamp.bind(holder))
	holder.set_meta("fx_tw", tw)

## ВЫСТРЕЛ ЛАЗЕРА — НЕ ДУЛЬНОЕ ПЛАМЯ. Конус (muzzle_fire) рисует раскалённые газы, вылетающие
## из ствола следом за пулей; у лазера газов нет, и тот же конус на нём читается как «пушка,
## которую покрасили в красный». Здесь вместо него КОПЬЁ: тонкий отрезок вдоль выстрела, который
## возникает во всю длину и гаснет, укорачиваясь к дулу, — след разряда, а не пламя.
##
## Держатель СВОЙ, не "MuzzleFX": ствол показывает что-то одно, но если однажды покажет оба,
## пусть они хотя бы не затирают друг другу поворот и твин.
static func muzzle_lance(muzzle: Node3D, dir: Vector3, col: Color, length: float,
		width: float, dur: float) -> void:
	if muzzle == null or not is_instance_valid(muzzle) or not muzzle.is_inside_tree():
		return
	var holder := muzzle.get_node_or_null("LanceFX") as Node3D
	if holder == null:
		holder = Node3D.new()
		holder.name = "LanceFX"
		holder.set_meta("block_fx", true)       # в габарит блока не входит (см. _local_aabb)
		var lm := MeshInstance3D.new()
		var cy := CylinderMesh.new()
		cy.top_radius = 0.5
		cy.bottom_radius = 0.5
		cy.height = 1.0
		cy.radial_segments = 6                  # живёт три кадра, граней тут не видно
		cy.rings = 0
		lm.mesh = cy
		# −90° по X переводит собственный +Y цилиндра в −Z держателя, то есть вперёд по стволу.
		lm.rotation_degrees = Vector3(-90.0, 0.0, 0.0)
		lm.material_override = _flash_mat(col)
		lm.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		holder.add_child(lm)
		holder.visible = false
		muzzle.add_child(holder)
	if dir.length_squared() > 0.0001 and absf(dir.normalized().dot(Vector3.UP)) < 0.99:
		holder.look_at(holder.global_position + dir, Vector3.UP)
	var mi := holder.get_child(0) as MeshInstance3D
	if mi == null:
		return
	var mat := mi.material_override as StandardMaterial3D
	if mat != null:
		mat.albedo_color = Color(col.r, col.g, col.b, 0.95)
		mat.emission = col
	# Цилиндр стоит центром в нуле, поэтому его сдвигают вперёд на половину длины: копьё должно
	# начинаться у дула, а не торчать из ствола назад.
	mi.scale = Vector3(width, length, width)
	mi.position = Vector3(0.0, 0.0, -length * 0.5)
	holder.visible = true
	if holder.has_meta("fx_tw"):
		var old: Variant = holder.get_meta("fx_tw")
		if old is Tween and (old as Tween).is_valid():
			(old as Tween).kill()
	var tw := holder.create_tween()
	tw.set_parallel(true)
	tw.tween_property(mi, "scale", Vector3(width * 0.3, length * 0.25, width * 0.3), dur) \
			.set_ease(Tween.EASE_OUT)
	tw.tween_property(mi, "position", Vector3(0.0, 0.0, -length * 0.125), dur) \
			.set_ease(Tween.EASE_OUT)
	if mat != null:
		tw.tween_property(mat, "albedo_color:a", 0.0, dur).set_ease(Tween.EASE_IN)
	tw.chain().tween_callback(_hide_lamp.bind(holder))
	holder.set_meta("fx_tw", tw)

## РАСТРУБ ВПЕРЁД, ОСТРИЁ У ДУЛА. Конус стоял наоборот — остриём от ствола, — и вспышка читалась
## не как вылетающие газы, а как шип, растущий из дула. Поворот на −90° по X переводит +Y меша
## вперёд по стволу, поэтому широкий конец — это `top_radius`.
static func _cone_mesh() -> Mesh:
	var cm := CylinderMesh.new()
	cm.top_radius = 0.5
	cm.bottom_radius = 0.0
	cm.height = 1.0
	cm.radial_segments = 8          # живёт четыре кадра: больше граней тут не видно
	cm.rings = 0
	return cm

static func _flash_mat(col: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.emission_enabled = true
	m.emission_energy_multiplier = 4.0
	m.albedo_color = col
	m.emission = col
	return m

## Вспышка у дула. dir — куда смотрит ствол: вспышка ВЫТЯНУТА ПО НЕМУ и смещена вперёд.
##
## ШАР БЫЛ НЕВЕРНЫМ РЕШЕНИЕМ, и игрок сказал об этом прямо. Выстрел — событие направленное, а шар
## вокруг ствола не сообщает ни направления, ни того, что вообще произошло: он читается как
## лампочка на оружии. Здесь конус: узкий у дула, раскрытый вперёд, вытянутый вдоль выстрела.
## Это силуэт дульного пламени, а не абстрактная точка света.
static func flash(anchor: Node, pos: Vector3, col: Color, size: float, dur: float,
		dir: Vector3 = Vector3.ZERO) -> void:
	if anchor == null or not is_instance_valid(anchor) or not anchor.is_inside_tree():
		return
	var tree := anchor.get_tree()
	if tree == null:
		return
	# Пустой current_scene раньше означал бы, что вспышки просто нет, и заметить это нечем:
	# она не падает, она НЕ ПОЯВЛЯЕТСЯ.
	var host: Node = tree.current_scene if tree.current_scene != null else tree.root
	var vp := anchor.get_viewport()
	var cam: Camera3D = vp.get_camera_3d() if vp != null else null
	if cam == null or cam.global_position.distance_squared_to(pos) > FLASH_DIST * FLASH_DIST:
		return
	var lamp := _take_lamp(host)
	if lamp == null:
		return
	var fwd: Vector3 = dir
	if fwd.length_squared() < 0.0001:
		fwd = (pos - cam.global_position)      # без направления (взрыв) — от камеры, то есть «на нас»
	fwd = fwd.normalized() if fwd.length_squared() > 0.0001 else Vector3.FORWARD
	# Смещаем ВПЕРЁД от дула на половину длины: иначе половина пламени торчит внутрь ствола.
	lamp.global_position = pos + fwd * size * 0.9
	if absf(fwd.dot(Vector3.UP)) < 0.99:
		lamp.look_at(lamp.global_position + fwd, Vector3.UP)
	var mi := lamp.get_child(0) as MeshInstance3D
	if mi == null:
		return
	# Масштаб В ОСЯХ МЕША: x/z — толщина, y — длина вдоль выстрела (см. разворот в _take_lamp).
	mi.scale = Vector3(size, size * 2.4, size)
	var mat := mi.material_override as StandardMaterial3D
	if mat != null:
		mat.albedo_color = Color(col.r, col.g, col.b, 0.95)
		mat.emission = col
	lamp.visible = true
	var tw := lamp.create_tween()
	tw.set_parallel(true)
	# Вытягивается ВПЕРЁД и гаснет: рост вдоль ствола читается как выброс, а рост во все стороны —
	# как надувающийся шарик, чем прошлая версия и была.
	tw.tween_property(mi, "scale", Vector3(size * 0.5, size * 3.4, size * 0.5), dur) \
			.set_ease(Tween.EASE_OUT)
	if mat != null:
		tw.tween_property(mat, "albedo_color:a", 0.0, dur).set_ease(Tween.EASE_IN)
	tw.chain().tween_callback(_hide_lamp.bind(lamp))
	# Твин держим НА САМОЙ вспышке: забирая её под новую, старый надо оборвать. Своего
	# kill_tweens у Node нет, поэтому ссылку храним сами.
	lamp.set_meta("fx_tw", tw)

## Пул держит УЗЕЛ-ДЕРЖАТЕЛЬ, а конус лежит его ребёнком, и это не украшение. look_at ставит
## поворот НА УЗЕЛ, то есть затирает любой предварительный разворот меша; а меш цилиндра растёт
## по своему Y, тогда как взгляд идёт по -Z. Держать и то и другое на одном узле нельзя: либо
## конус смотрит не туда, либо неравномерный масштаб родителя перекашивает повёрнутого ребёнка.
##
## Поэтому: РОДИТЕЛЬ — положение и поворот, РЕБЁНОК — разворот меша и масштаб в своих осях.
static func _take_lamp(root: Node) -> Node3D:
	for i in range(_lamps.size() - 1, -1, -1):
		if not is_instance_valid(_lamps[i]):
			_lamps.remove_at(i)
	if _lamps.size() < LAMPS:
		var made := Node3D.new()
		var mi := MeshInstance3D.new()
		# КОНУС, А НЕ ШАР. Вершина у дула, раскрытие вперёд — силуэт дульного пламени.
		var cm := CylinderMesh.new()
		cm.top_radius = 0.0
		cm.bottom_radius = 0.5
		cm.height = 1.0
		cm.radial_segments = 8          # живёт четыре кадра: больше граней тут не видно
		cm.rings = 0
		mi.mesh = cm
		# −90° по X переводит собственный +Y цилиндра в −Z родителя, то есть в направление взгляда.
		mi.rotation_degrees = Vector3(-90.0, 0.0, 0.0)
		var m := StandardMaterial3D.new()
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
		m.cull_mode = BaseMaterial3D.CULL_DISABLED
		m.emission_enabled = true
		m.emission_energy_multiplier = 4.0
		mi.material_override = m
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		made.add_child(mi)
		made.visible = false
		root.add_child(made)
		_lamps.append(made)
		return made
	if _lamp_at >= _lamps.size():
		_lamp_at = 0
	var lamp: Node3D = _lamps[_lamp_at]
	_lamp_at = (_lamp_at + 1) % _lamps.size()
	if lamp.has_meta("fx_tw"):               # get_meta без has_meta падает, см. правило 4
		var old: Variant = lamp.get_meta("fx_tw")
		if old is Tween and (old as Tween).is_valid():
			(old as Tween).kill()
	return lamp

static func _hide_lamp(lamp: Node3D) -> void:
	if is_instance_valid(lamp):
		lamp.visible = false           # погасшая вспышка не должна стоить ничего

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

## ИСКРА НА ЩИТЕ. Раньше попадание в купол рисовалось ПО САМОЙ ПУЛЕ (BlockFX.play на снаряде), и
## это давало сразу две беды. Первая: глюк принадлежал не тому — игрок ждёт отметку на щите, там
## где он сработал, а видел облако, летящее со снарядом. Вторая, хуже: пуля тут же уходила в пул
## и вылетала СЛЕДУЮЩИМ выстрелом с ещё не догоревшим облаком на себе — «пуля уже с глитчом до
## попадания».
##
## Теперь облако принадлежит КУПОЛУ и стоит в точке гашения: купол едет с машиной, значит и
## отметка едет с ним. Палитра — глитчевая (циан/маджента), а не взрывная: щит гасит, а не рвёт.
const SPARK_A := Color(0.15, 0.85, 1.0)
const SPARK_B := Color(0.72, 0.16, 1.0)

static func shield_spark(dome: Node, pos: Vector3) -> void:
	blast_cards(dome, pos, 0.55, SPARK_A, SPARK_B, 10, 0.3)

static func blast_cards(root: Node, pos: Vector3, radius: float,
		ca: Color = BLAST_A, cb: Color = BLAST_B, cards: int = BLAST_CARDS,
		dur: float = BLAST_DUR) -> void:
	if root == null or not is_instance_valid(root):
		return
	var count: int = _take_card_budget(cards)
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
		cmat.set_shader_parameter("use_tint", true)
		cmat.set_shader_parameter("glitch_a", Vector3(ca.r, ca.g, ca.b))
		cmat.set_shader_parameter("glitch_b", Vector3(cb.r, cb.g, cb.b))
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
	tw.tween_method(_set_cards_progress.bind(mats), 0.0, 1.0, dur)
	# Само облако РАЗЛЕТАЕТСЯ: карточки стоят на своих местах внутри него, а масштабируется
	# узел целиком — один твин вместо тридцати четырёх.
	cloud.scale = Vector3.ONE * 0.35
	tw.tween_property(cloud, "scale", Vector3.ONE, dur).set_ease(Tween.EASE_OUT)
	tw.chain().tween_callback(cloud.queue_free)
	# Свет взрыва — здесь, а не у того, кто взорвался: blast_cards это единственная дверь, через
	# неё проходят и батарея, и кабина, и догоревший предохранитель. Радиус вдвое шире облака,
	# чтобы взрыв подсвечивал то, что вокруг, а не только себя.
	# Размер по той же причине, что у дула: это неосвещаемый меш, а не лампа (см. flash), и
	# задаётся он в метрах. Шар в половину радиуса поражения — взрыв читается вспышкой в центре
	# облака, а не вторым облаком поверх первого.
	flash(root, pos, BLAST_A, radius * 0.55, BLAST_DUR)

## Сколько карточек можно создать в этом кадре (общий потолок на всю игру, см. CARDS_PER_FRAME).
## Вынесено из play(), потому что считать бюджет обязаны ВСЕ, кто их создаёт: цепной взрыв
## рвёт по десятку блоков сразу, и без общего счёта это тысяча узлов в одном кадре.
## СЧИТАЕМ ПО КАДРАМ ЛОГИКИ, А НЕ ОТРИСОВКИ. Было get_frames_drawn, и это тихая ловушка: счётчик
## отрисованных кадров может не расти вовсе (свёрнутое окно, прогон без рендера), а игра при этом
## идёт. Бюджет тогда выбирается один раз и не обновляется НИКОГДА — эффекты просто перестают
## появляться, молча и без единой ошибки. Поймано на собственном стенде, где ровно это и вышло.
static func _take_card_budget(want: int) -> int:
	var frame := Engine.get_process_frames()
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
			cmat.set_shader_parameter("use_tint", true)
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
# ── Материализация МАШИНЫ: квадратные заплатки, уходящие с краёв ─────────────────
#
# ТРЕТЬЯ ПОПЫТКА, И ПРЕДЫДУЩИЕ ДВЕ СТОИТ ПОМНИТЬ. Оболочка на каждый блок дала сорок независимых
# фронтов. Один круглый билборд на всю машину дал ровное пятно, которое игрок назвал шаром: он
# читался как заслонка, а не как глитч.
#
# Здесь — НЕСКОЛЬКО КВАДРАТНЫХ ЗАПЛАТОК, тем же шейдером, которым говорит появление блока
# (glitch_card): язык совпадает, и машина собирается из тех же кусков, что и деталь в руке.
#
# УХОДЯТ С КРАЁВ К ЦЕНТРУ. Заплатка гаснет тем раньше, чем дальше она от середины машины, так
# что силуэт проявляется снаружи внутрь. Порядок задаётся не таймером на каждую, а одним общим
# прогрессом: своя длительность у каждой заплатки означала бы, что они расходятся по фазе и
# эффект рассыпается на мигание.
#
# Билборды: камера во время спавна может ехать, и заплатки обязаны оставаться между ней и
# машиной. Глубина отключена в самом шейдере карточки.
const SPAWN_DUR := 1.0
const SPAWN_CARDS := 14
const SPAWN_PAD := 1.25        # насколько шире силуэта разбросаны заплатки

## Проявить машину. Зовётся на спавне; самоочищается.
static func materialise(machine: Node3D, dur: float = SPAWN_DUR) -> void:
	if machine == null or not is_instance_valid(machine) or not machine.is_inside_tree():
		return
	var holder: Node = machine.get_node_or_null("blocks")
	if holder == null:
		return
	# Центр и радиус силуэта берём из СЕТКИ, а не из мирового AABB: повёрнутая машина дала бы
	# раздутую коробку и заплатки вдвое больше нужного.
	var mid := Vector3.ZERO
	var n := 0
	for b in holder.get_children():
		var nb := b as Node3D
		if nb == null or nb.has_meta("block_fx"):
			continue
		mid += nb.position
		n += 1
	if n == 0:
		return
	mid /= float(n)
	var r: float = 1.0
	for b in holder.get_children():
		var nb := b as Node3D
		if nb == null or nb.has_meta("block_fx"):
			continue
		r = maxf(r, nb.position.distance_to(mid) + 0.8)
	var count: int = _take_card_budget(SPAWN_CARDS)
	if count <= 0:
		return
	var mats: Array = []
	var outs: Array = []
	var cloud := Node3D.new()
	cloud.set_meta("block_fx", true)
	machine.add_child(cloud)
	cloud.position = mid
	for i in count:
		var card := MeshInstance3D.new()
		var q := QuadMesh.new()
		q.size = Vector2.ONE
		card.mesh = q
		card.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		card.set_meta("block_fx", true)     # правило 11: в габарит машины эффекты не входят
		var cmat := ShaderMaterial.new()
		cmat.shader = CARD_SHADER
		cmat.set_shader_parameter("seed", randf() * 100.0)
		cmat.set_shader_parameter("grid_cells", 4.0 if randf() < 0.5 else 6.0)
		cmat.set_shader_parameter("fill_threshold", randf_range(0.30, 0.46))
		cmat.set_shader_parameter("progress", 0.5)   # 0.5 — пик видимости, дальше только гаснет
		card.material_override = cmat
		cloud.add_child(card)
		# По ШАРУ вокруг центра, с равномерной плотностью по объёму: по кубу углы торчали бы
		# за силуэт, а без кубического корня всё сбилось бы в середину.
		var dir := Vector3(randf() - 0.5, randf() - 0.5, randf() - 0.5)
		dir = dir.normalized() if dir.length_squared() > 0.0001 else Vector3.UP
		var t: float = pow(randf(), 1.0 / 3.0)
		card.position = dir * r * t * SPAWN_PAD
		var sz: float = r * randf_range(0.5, 0.95)
		card.scale = Vector3(sz, sz, 1.0)
		mats.append(cmat)
		outs.append(t)                                # доля радиуса: она и решает очерёдность
	var tw := cloud.create_tween()
	tw.tween_method(_spawn_step.bind(mats, outs), 0.0, 1.0, dur)
	tw.tween_callback(cloud.queue_free)

## Заплатка у края уходит первой, в середине — последней. Окно у каждой своё, но считается от
## ОДНОГО прогресса, поэтому фронт общий.
static func _spawn_step(p: float, mats: Array, outs: Array) -> void:
	for i in mats.size():
		var m = mats[i]
		if not (m is ShaderMaterial):
			continue
		var start: float = 1.0 - float(outs[i])       # чем дальше от центра, тем раньше старт
		var k: float = clampf((p - start * 0.75) / 0.45, 0.0, 1.0)
		# 0.5..1.0 у карточного шейдера — чистое затухание без повторного разгорания.
		(m as ShaderMaterial).set_shader_parameter("progress", 0.5 + 0.5 * k)

# ── Поток ремонта: код летит В блок, который чинят ───────────────────────────────
#
# Орбита вокруг регена (regen_code.gdshader) показывает, что поле РАБОТАЕТ. Она не может
# показать, КОГО оно чинит прямо сейчас: шейдер сферы про соседние блоки ничего не знает.
# Поэтому починка — отдельная вещь: несколько глифов срываются с поля и летят в цель.
#
# ЛЕТЯТ С УСКОРЕНИЕМ. Равномерный полёт читается как перенос предмета, разгон — как притяжение,
# и именно он делает понятным, что чинит не «поле вообще», а вот этот код, прилетевший в блок.
#
# Глифы — билборды с карточным шейдером в зелёной палитре починки, той же, которой зеленеют
# цифры урона на самом блоке. Держатся на СЦЕНЕ, а не на цели: блок могут в этот момент оторвать
# или уничтожить, и поток обязан долететь всё равно.
const HEAL_COL_A := Color(0.25, 1.0, 0.45)
const HEAL_COL_B := Color(0.55, 1.0, 0.75)
## ОДИН ГЛИФ НА БЛОК. Их было три, и на плотной сборке, где за тик чинится полдюжины бортов,
## поле выбрасывало два десятка карточек разом — читалось это как вспышка, а не как «чиню вот
## этот и вот этот». По одному на цель видно, СКОЛЬКО блоков под ремонтом, прямо по числу линий.
const HEAL_BOLTS := 1
const HEAL_DUR := 0.32
## Та же оболочка, по которой шейдер раскладывает цифры (`regen_code.gdshader`: 0.82..1.0 радиуса).
const HEAL_SHELL_LO := 0.82
const HEAL_SHELL_HI := 1.0

## ОТКУДА ЛЕТИТ ПОЧИНКА — ИЗ ОБЛАКА ЦИФР, А НЕ ИЗ САМОГО БЛОКА. Старт стоял в центре поля с
## разбросом в полметра при радиусе 4.6, то есть практически в точке: получалась линия, которую
## блок проводит до цели, — а чинит поле, а не блок.
##
## КОНКРЕТНУЮ ЦИФРУ НЕ СПРАШИВАЕМ. Её положение считается в шейдере из TIME, и повторить орбиту
## на стороне игры значило бы завести вторую копию формулы — она разойдётся с первой при первой
## же правке и разойдётся молча. Берём случайную точку на ТОЙ ЖЕ оболочке: цифры разбросаны по
## ней целиком и всё время движутся, так что отличить «вот эта цифра» от «точка среди них»
## нельзя даже в упор.
##
## Полушарие выбираем СО СТОРОНЫ ЦЕЛИ: с дальней стороны глиф летел бы сквозь всю машину.
static func _cloud_point(centre: Vector3, toward: Vector3, r: float) -> Vector3:
	if r <= 0.0:
		return centre
	var d := Vector3(randf() - 0.5, randf() - 0.5, randf() - 0.5)
	if d.length_squared() < 0.0001:
		d = Vector3.UP
	d = d.normalized()
	if toward.length_squared() > 0.0001 and d.dot(toward.normalized()) < 0.0:
		d = -d
	return centre + d * r * randf_range(HEAL_SHELL_LO, HEAL_SHELL_HI)

static func repair_stream(from: Node3D, to: Node3D, cloud_radius: float = 0.0) -> void:
	if from == null or to == null or not is_instance_valid(from) or not is_instance_valid(to):
		return
	if not from.is_inside_tree() or not to.is_inside_tree():
		return
	var tree := from.get_tree()
	if tree == null:
		return
	var host: Node = tree.current_scene if tree.current_scene != null else tree.root
	var n: int = _take_card_budget(HEAL_BOLTS)
	if n <= 0:
		return
	var a: Vector3 = from.global_position
	var b: Vector3 = to.global_position
	for i in n:
		var card := MeshInstance3D.new()
		var q := QuadMesh.new()
		q.size = Vector2(0.34, 0.34)
		card.mesh = q
		card.set_meta("block_fx", true)
		card.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var cmat := ShaderMaterial.new()
		cmat.shader = CARD_SHADER
		cmat.set_shader_parameter("seed", randf() * 100.0)
		cmat.set_shader_parameter("grid_cells", 3.0)
		cmat.set_shader_parameter("fill_threshold", 0.30)
		cmat.set_shader_parameter("progress", 0.0)
		cmat.set_shader_parameter("use_tint", true)
		cmat.set_shader_parameter("glitch_a", Vector3(HEAL_COL_A.r, HEAL_COL_A.g, HEAL_COL_A.b))
		cmat.set_shader_parameter("glitch_b", Vector3(HEAL_COL_B.r, HEAL_COL_B.g, HEAL_COL_B.b))
		card.material_override = cmat
		host.add_child(card)
		card.global_position = _cloud_point(a, b - a, cloud_radius)
		var tw := card.create_tween()
		tw.set_parallel(true)
		# EASE_IN и есть разгон: к цели глиф приходит быстрее, чем стартовал.
		tw.tween_property(card, "global_position", b, HEAL_DUR).set_ease(Tween.EASE_IN)
		tw.tween_method(_set_card_progress.bind(cmat), 0.0, 1.0, HEAL_DUR)
		tw.chain().tween_callback(card.queue_free)

# ── A SIGN ASSEMBLED FROM GLITCH CARDS ─────────────────────────────────────────
# The cards a block or a machine appears with (the same shader, the same palette) come up scattered
# round the spot, fly together and lock into ONE shape - a pixel glyph drawn by `pattern`, where
# every '#' is a card. The colour is the glitch's own; only the shape says what it means.
#
# The glyph lives in the CAMERA'S PLANE: each card is already a billboard, but their POSITIONS must
# lie across the screen for the shape to read, so the holder is turned to the camera on every step
# of the one tween that drives the whole thing (no script on the node, no second clock).
const GLYPH_IN := 0.7            # scatter and fly-in; the sign is whole by this second
const GLYPH_FLY := 0.45          # one card's flight; starts are staggered across GLYPH_IN - GLYPH_FLY
## BIG GLITCHES INTO A SMALL SIGN: a card starts as a patch the size of the spawn cloud's (this many
## cells across, give or take a third) and shrinks to one pixel of the glyph as it arrives.
const GLYPH_BIG := 5.0
const GLYPH_FADE := 0.4
const GLYPH_SCATTER := 1.7       # radius of the cloud the cards start from, in cells
## Cards exactly fill their cell. They blend ADDITIVELY, so any overlap doubles in brightness and
## draws a bright seam between every pair (1.15 read as a grid of tiles rather than one sign).
const GLYPH_FILL := 1.0

static func glyph(parent: Node3D, pattern: Array, cell: float, at: Vector3, total: float) -> Node3D:
	if parent == null or not parent.is_inside_tree():
		return null
	var targets: Array = []
	var rows: int = pattern.size()
	var cols: int = 0
	for r in pattern:
		cols = maxi(cols, String(r).length())
	for y in rows:
		var line: String = pattern[y]
		for x in line.length():
			if line[x] == "#":
				targets.append(Vector3((float(x) - float(cols - 1) * 0.5) * cell,
						(float(rows - 1) * 0.5 - float(y)) * cell, 0.0))
	var count: int = _take_card_budget(targets.size())
	if count < targets.size():
		return null                              # half a sign is not a sign
	var holder := Node3D.new()
	holder.set_meta("block_fx", true)
	parent.add_child(holder)
	holder.position = at
	var cards: Array = []
	var mats: Array = []
	var starts: Array = []
	var delays: Array = []
	for i in targets.size():
		var card := MeshInstance3D.new()
		var q := QuadMesh.new()
		q.size = Vector2.ONE
		card.mesh = q
		card.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		card.set_meta("block_fx", true)
		var cmat := ShaderMaterial.new()
		cmat.shader = CARD_SHADER
		cmat.set_shader_parameter("seed", randf() * 100.0)
		# The spawn cloud's own patch (materialise): 4x4 or 6x6 cells, patchy. `solid` fills it in
		# as it locks into place, so the same card is a glitch in flight and a pixel at rest.
		cmat.set_shader_parameter("grid_cells", 4.0 if randf() < 0.5 else 6.0)
		cmat.set_shader_parameter("fill_threshold", randf_range(0.30, 0.46))
		cmat.set_shader_parameter("progress", 0.0)
		card.material_override = cmat
		holder.add_child(card)
		var d := Vector3(randf() - 0.5, randf() - 0.5, randf() - 0.5)
		d = d.normalized() if d.length_squared() > 0.0001 else Vector3.UP
		var st: Vector3 = targets[i] + d * cell * GLYPH_SCATTER * pow(randf(), 1.0 / 3.0) * float(rows) * 0.5
		card.position = st
		var big: float = cell * GLYPH_BIG * randf_range(0.7, 1.3)
		card.scale = Vector3(big, big, 1.0)
		card.set_meta("big", big)
		card.set_meta("small", cell * GLYPH_FILL)
		cards.append(card)
		mats.append(cmat)
		starts.append(st)
		delays.append(randf() * (GLYPH_IN - GLYPH_FLY))
	var tw := holder.create_tween()
	tw.tween_method(_glyph_step.bind(holder, cards, mats, starts, targets, delays, total), 0.0, total, total)
	tw.tween_callback(holder.queue_free)
	_glyph_step(0.0, holder, cards, mats, starts, targets, delays, total)
	return holder

static func _glyph_step(t: float, holder: Node3D, cards: Array, mats: Array, starts: Array,
		targets: Array, delays: Array, total: float) -> void:
	if not is_instance_valid(holder) or not holder.is_inside_tree():
		return
	var cam: Camera3D = holder.get_viewport().get_camera_3d()
	if cam != null:
		var k: float = holder.get_parent_node_3d().global_basis.get_scale().x
		holder.global_basis = Basis(cam.global_basis.get_rotation_quaternion()).scaled(Vector3.ONE * k)
	# One progress for every card: 0 -> 0.5 is the card shader's "appearing", 0.5 is full, 0.5 -> 1
	# is the fade, the same scale materialise() runs on.
	var pr: float = 0.5
	if t < GLYPH_IN:
		pr = 0.5 * t / GLYPH_IN
	elif t > total - GLYPH_FADE:
		pr = 0.5 + 0.5 * clampf((t - (total - GLYPH_FADE)) / GLYPH_FADE, 0.0, 1.0)
	for i in cards.size():
		var c: Node3D = cards[i]
		if not is_instance_valid(c):
			continue
		var a: float = clampf((t - float(delays[i])) / GLYPH_FLY, 0.0, 1.0)
		var e: float = 1.0 - pow(1.0 - a, 3.0)
		c.position = (starts[i] as Vector3).lerp(targets[i], e)
		var sz: float = lerpf(float(c.get_meta("big")), float(c.get_meta("small")), e)
		c.scale = Vector3(sz, sz, 1.0)
		(mats[i] as ShaderMaterial).set_shader_parameter("progress", pr)
		# Solid as it LOCKS IN: in flight it is still a patchy glitch card, in place a pixel.
		(mats[i] as ShaderMaterial).set_shader_parameter("solid", a * a)

# ── A DIGITAL HOLE WHERE A SHOT HIT THE WORLD ──────────────────────────────────
# A shot that lands on the ground, a rock or a tree leaves a patch of the world that stopped being
# rendered (ground_hole.gdshader): dark pixels with a glitch rim, healing over HOLE_LIFE. The door is
# WeaponBlock._on_bullet_body_entered, the branch for a body that takes no damage.
#
# A POOL, NOT A NODE PER HIT. A machine gun puts several shots a second into the ground; the oldest
# hole is taken for the newest, so a long burst costs HOLE_POOL nodes and no more. Past HOLE_DIST
# nothing is made at all - a hole the size of a hand cannot be seen from there.
const HOLE_SHADER := preload("res://ground_hole.gdshader")
const HOLE_POOL := 24
const HOLE_LIFE := 4.0
const HOLE_SIZE := 0.75
const HOLE_DIST := 90.0
const HOLE_LIFT := 0.03          # off the surface, or it z-fights with the ground it lies on
static var _holes: Array = []
static var _hole_next: int = 0

static func ground_hole(anchor: Node, pos: Vector3, normal: Vector3) -> void:
	if anchor == null or not anchor.is_inside_tree():
		return
	var cam: Camera3D = anchor.get_viewport().get_camera_3d()
	if cam != null and cam.global_position.distance_squared_to(pos) > HOLE_DIST * HOLE_DIST:
		return
	var tree := anchor.get_tree()
	var host: Node = tree.current_scene if tree.current_scene != null else tree.root
	var alive: Array = []
	for h in _holes:
		if is_instance_valid(h):
			alive.append(h)
	_holes = alive
	var mi: MeshInstance3D = null
	if _holes.size() < HOLE_POOL:
		mi = MeshInstance3D.new()
		var pm := PlaneMesh.new()                 # lies in XZ, faces +Y: the normal becomes its Y
		pm.size = Vector2(HOLE_SIZE, HOLE_SIZE)
		mi.mesh = pm
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.set_meta("block_fx", true)
		var m := ShaderMaterial.new()
		m.shader = HOLE_SHADER
		mi.material_override = m
		host.add_child(mi)
		_holes.append(mi)
	else:
		mi = _holes[_hole_next % _holes.size()]
		_hole_next += 1
		if mi.has_meta("tw"):
			var old = mi.get_meta("tw")
			if old is Tween and (old as Tween).is_valid():
				(old as Tween).kill()
	var up: Vector3 = normal.normalized() if normal.length_squared() > 0.0001 else Vector3.UP
	var side: Vector3 = up.cross(Vector3.FORWARD if absf(up.dot(Vector3.FORWARD)) < 0.9 else Vector3.RIGHT).normalized()
	var basis := Basis(side, up, side.cross(up)).rotated(up, randf() * TAU)
	mi.global_transform = Transform3D(basis, pos + up * HOLE_LIFT)
	mi.visible = true
	var mat := mi.material_override as ShaderMaterial
	mat.set_shader_parameter("seed", randf() * 100.0)
	mat.set_shader_parameter("progress", 0.0)
	var tw := mi.create_tween()
	tw.tween_method(_set_card_progress.bind(mat), 0.0, 1.0, HOLE_LIFE)
	tw.tween_callback(mi.hide)
	mi.set_meta("tw", tw)

static func _set_card_progress(p: float, mat: ShaderMaterial) -> void:
	if is_instance_valid(mat):
		mat.set_shader_parameter("progress", p)

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
