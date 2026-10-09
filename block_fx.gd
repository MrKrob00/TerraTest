class_name BlockFX
extends RefCounted

const SHADER := preload("res://block_matrix.gdshader")   # урон (mode 2, красные цифры) — hit()
const SHADER_HP := preload("res://block_hp.gdshader")    # постоянный оверлей хп (свой режим глубины)
const CARD_SHADER := preload("res://glitch_card.gdshader")   # глитч-карточки (появление/исчезновение)
const CARD_BURST := preload("res://card_burst.gd")       # every cloud of cards, one MultiMesh a palette
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
	mi.mesh = _jet_mesh()
	var mat := _flash_mat(col)
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	holder.add_child(mi)
	# THE BLAST HAS A SHAPE ACROSS THE BARREL TOO: four short petals of fire out to the sides and a
	# ring that runs outward from the muzzle. The cone alone said "light out of the barrel"; seen
	# from the front or three-quarters - how a turret is mostly seen - it was a dot. One material
	# for all three, so the one fade covers them.
	var petals := MeshInstance3D.new()
	petals.mesh = _petal_mesh()
	petals.material_override = mat
	petals.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	holder.add_child(petals)
	var ring := MeshInstance3D.new()
	ring.mesh = _ring_mesh()
	ring.material_override = mat
	ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	holder.add_child(ring)
	holder.visible = false
	muzzle.add_child(holder)
	return holder

## THE FLAME IS A JET OF PIXELS, NOT A CONE (the player: "I just do not like the cone part"). A
## smooth cone of light is the one shape in the shot that was not in the game's language - every
## other effect here is pixel cards. So: a short chain of glowing cubes down the shot, shrinking
## toward its end and stepping off the axis, and two sparks thrown out to the sides; built along -Z
## of the holder from the muzzle out, length 1, turned at random about the shot each time.
static var _jet: Mesh = null

static func _jet_mesh() -> Mesh:
	if _jet != null:
		return _jet
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	# [centre, half-size]: the chain, then the sparks
	# Apart, not touching: additive cubes that overlap sum to one white bar.
	for c in [[Vector3(0.0, 0.0, -0.14), 0.20], [Vector3(0.16, -0.10, -0.44), 0.15],
			[Vector3(-0.14, 0.12, -0.68), 0.11], [Vector3(0.10, 0.08, -0.86), 0.075],
			[Vector3(-0.06, -0.08, -0.98), 0.045], [Vector3(0.60, 0.14, -0.30), 0.06],
			[Vector3(-0.32, -0.56, -0.50), 0.05]]:
		var o: Vector3 = c[0]
		var h: float = c[1]
		for ax in 3:
			for sg in [-1.0, 1.0]:
				var n := Vector3.ZERO
				n[ax] = sg
				var u := Vector3.ZERO
				u[(ax + 1) % 3] = h
				var v := Vector3.ZERO
				v[(ax + 2) % 3] = h
				var f: Vector3 = o + n * h
				for q in [f - u - v, f + u - v, f + u + v, f - u - v, f + u + v, f - u + v]:
					st.add_vertex(q)
	_jet = st.commit()
	return _jet

## Four flat petals in the plane across the barrel (XY of the holder, which looks down -Z), each a
## thin diamond from the muzzle out; doubled back to back so both faces draw. One mesh, built once.
static var _petals: Mesh = null
static var _ring: Mesh = null

static func _petal_mesh() -> Mesh:
	if _petals != null:
		return _petals
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for k in 4:
		var a: float = PI / 4.0 + k * PI / 2.0
		var out := Vector3(cos(a), sin(a), 0.0)
		var side := Vector3(-sin(a), cos(a), 0.0) * 0.16
		var tip := out * 1.0 + Vector3(0, 0, -0.12)
		var mid := out * 0.35
		for tri in [[Vector3.ZERO, mid + side, tip], [Vector3.ZERO, tip, mid - side]]:
			for v in tri:
				st.add_vertex(v)
	_petals = st.commit()
	return _petals

## A flat ring across the barrel, inner edge at 0.8 of its radius.
static func _ring_mesh() -> Mesh:
	if _ring != null:
		return _ring
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var n := 16
	for i in n:
		var a0: float = TAU * i / n
		var a1: float = TAU * (i + 1) / n
		var o0 := Vector3(cos(a0), sin(a0), 0.0)
		var o1 := Vector3(cos(a1), sin(a1), 0.0)
		for v in [o0 * 0.8, o0, o1, o0 * 0.8, o1, o1 * 0.8]:
			st.add_vertex(v)
	_ring = st.commit()
	return _ring

## Зажечь вспышку ствола. dir — направление ВЫСТРЕЛА в мировых осях.
##
## ПОВОРОТ БЕРЁТСЯ ОТ ВЫСТРЕЛА, А НЕ ОТ УЗЛА ДУЛА. Вспышка висит ребёнком дула и наследовала его
## поворот, а он у каждой модели свой: художник ставил маркер как удобно. У одной пушки конус
## выходил чуть ниже ствола, у другой развёрнут на девяносто градусов. Направление же у всех
## одно и то же и уже известно — по нему летит пуля.
## How many flash_size the jet is across and along at the start of its life and at the end: it grows
## and fades.
const MUZZLE_R0 := 0.9               # near the jet's length, so its pixels stay cubes
const MUZZLE_L0 := 1.2
const MUZZLE_R1 := 1.3
const MUZZLE_L1 := 2.2
## The petals across the barrel and the shock ring, at the start of the flash and at its end.
const MUZZLE_PETAL0 := 1.4
const MUZZLE_PETAL1 := 0.5
const MUZZLE_RING0 := 0.25
const MUZZLE_RING1 := 1.5

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
	var s0 := Vector3(size * MUZZLE_R0, size * MUZZLE_R0, size * MUZZLE_L0)
	var s1 := Vector3(size * MUZZLE_R1, size * MUZZLE_R1, size * MUZZLE_L1)
	mi.scale = s0
	mi.position = Vector3.ZERO                 # the jet is built from the muzzle out
	mi.rotation = Vector3(0.0, 0.0, randf() * TAU)
	var petals := holder.get_child(1) as MeshInstance3D if holder.get_child_count() > 2 else null
	var ring := holder.get_child(2) as MeshInstance3D if holder.get_child_count() > 2 else null
	if petals != null:
		petals.scale = Vector3.ONE * size * MUZZLE_PETAL0
		petals.rotation.z = randf() * TAU            # never the same star twice in a burst
		petals.position = Vector3(0.0, 0.0, -size * 0.15)
	if ring != null:
		ring.scale = Vector3.ONE * size * MUZZLE_RING0
		ring.position = Vector3(0.0, 0.0, -size * 0.3)
	holder.visible = true
	if holder.has_meta("fx_tw"):
		var old: Variant = holder.get_meta("fx_tw")
		if old is Tween and (old as Tween).is_valid():
			(old as Tween).kill()
	var tw := holder.create_tween()
	tw.set_parallel(true)
	tw.tween_property(mi, "scale", s1, dur).set_ease(Tween.EASE_OUT)
	if petals != null:
		tw.tween_property(petals, "scale", Vector3.ONE * size * MUZZLE_PETAL1, dur * 0.7).set_ease(Tween.EASE_OUT)
	if ring != null:
		# the ring runs out ahead of the flame and away from the muzzle: the shock of the shot
		tw.tween_property(ring, "scale", Vector3.ONE * size * MUZZLE_RING1, dur).set_ease(Tween.EASE_OUT)
		tw.tween_property(ring, "position", Vector3(0.0, 0.0, -size * 1.6), dur).set_ease(Tween.EASE_OUT)
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
		var lmat := _flash_mat(col)
		lm.material_override = lmat
		lm.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		holder.add_child(lm)
		# a ring of light thrown off the emitter as the bolt leaves: the discharge, seen head-on
		var lr := MeshInstance3D.new()
		lr.mesh = _ring_mesh()
		lr.material_override = lmat
		lr.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		holder.add_child(lr)
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
	var lr := holder.get_child(1) as MeshInstance3D if holder.get_child_count() > 1 else null
	if lr != null:
		lr.scale = Vector3.ONE * width * 1.5
		lr.position = Vector3(0.0, 0.0, -0.05)
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
	if lr != null:
		tw.tween_property(lr, "scale", Vector3.ONE * width * 7.0, dur * 1.4).set_ease(Tween.EASE_OUT)
		tw.tween_property(lr, "position", Vector3(0.0, 0.0, -length * 0.3), dur * 1.4).set_ease(Tween.EASE_OUT)
	if mat != null:
		tw.tween_property(mat, "albedo_color:a", 0.0, dur).set_ease(Tween.EASE_IN)
	tw.chain().tween_callback(_hide_lamp.bind(holder))
	holder.set_meta("fx_tw", tw)

## РАСТРУБ ВПЕРЁД, ОСТРИЁ У ДУЛА. Конус стоял наоборот — остриём от ствола, — и вспышка читалась
## не как вылетающие газы, а как шип, растущий из дула. Поворот на −90° по X переводит +Y меша
## вперёд по стволу, поэтому широкий конец — это `top_radius`.
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
	if root == null or not is_instance_valid(root) or not root.is_inside_tree():
		return
	var count: int = _take_card_budget(cards)
	if count <= 0:
		return
	var burst = CARD_BURST.of(root, true, ca, cb)
	if burst == null:
		return
	var data := PackedFloat32Array()
	data.resize(count * CARD_BURST.PER)
	for i in count:
		# Points in a BALL, not a cube: the blast has a radius and the cloud must be round, or the
		# cube's corners stick out past the damage and lie about it. The cube root of a uniform
		# number gives an even density by volume; without it the cards bunch in the middle.
		var dir := Vector3(randf() - 0.5, randf() - 0.5, randf() - 0.5)
		dir = dir.normalized() if dir.length_squared() > 0.0001 else Vector3.UP
		var at: Vector3 = dir * radius * pow(randf(), 1.0 / 3.0)
		var o: int = i * CARD_BURST.PER
		data[o] = at.x
		data[o + 1] = at.y
		data[o + 2] = at.z
		data[o + 3] = randf_range(radius * 0.18, radius * 0.5)
		data[o + 4] = randf() * 100.0
		data[o + 5] = 4.0 if randf() < 0.5 else 6.0
		data[o + 6] = randf_range(0.34, 0.5)
	# The cloud stays on what it burst on (the dome rides with its machine) and SPREADS: the cards
	# keep their places in it while the cloud grows from 0.35 to full over its life.
	var anchor: Node3D = root as Node3D if root is Node3D else null
	var local := Transform3D(Basis(), pos)
	if anchor != null:
		local = anchor.global_transform.affine_inverse() * local
	burst.add(anchor, local, data, dur, 0.35)
	# The blast's flash is here, not with whoever blew up: this is the one door the battery, the
	# cabin and a burnt-out fuse all come through. Only in the blast's own colours - NOT FOR A SHIELD
	# SPARK: a dome under a machine gun takes several hits a second, and each stood a cone on it.
	if ca == BLAST_A:
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
	# A cloud of glitch cards: flat billboards of DIFFERENT sizes at DIFFERENT depths in and round the
	# block, flickering and fading (the appear / vanish glitch). One CardBurst per palette draws them
	# all; an empty tint is the card's own cyan-magenta. The card budget is shared with the blasts.
	var count: int = _take_card_budget(CARD_COUNT)
	if count <= 0:
		return
	var tinted: bool = tint_a.a > 0.0
	var ca: Color = tint_a if tinted else Color(0.15, 0.85, 1.0)
	var cb: Color = tint_b if tint_b.a > 0.0 else Color(0.85, 0.15, 0.95)
	var burst = CARD_BURST.of(block, tinted, ca, cb)
	if burst == null:
		return
	var half := aabb.size * 0.5
	var span: float = aabb.size.length()
	var data := PackedFloat32Array()
	data.resize(count * CARD_BURST.PER)
	for i in count:
		var o: int = i * CARD_BURST.PER
		data[o] = randf_range(-half.x, half.x) * CARD_SPREAD
		data[o + 1] = randf_range(-half.y, half.y) * CARD_SPREAD
		data[o + 2] = randf_range(-half.z, half.z) * CARD_SPREAD
		data[o + 3] = randf_range(span * 0.10, span * 0.35)
		data[o + 4] = randf() * 100.0
		data[o + 5] = 4.0 if randf() < 0.5 else 6.0
		data[o + 6] = randf_range(0.38, 0.5)
	# In the block's own axes round its middle. A block being destroyed is about to be freed, so its
	# cloud stays with the block's PARENT (the machine drives on, the cloud with it) - or the world.
	var at: Transform3D = block.global_transform * Transform3D(Basis(), aabb.get_center())
	var anchor: Node3D = block
	if destroy:
		anchor = host as Node3D if host is Node3D else null
	var local: Transform3D = at if anchor == null else anchor.global_transform.affine_inverse() * at
	var dur := duration
	if dur <= 0.0:
		dur = 0.7 if destroy else 0.8
	burst.add(anchor, local, data, dur, 1.0)

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
	# THE BLOCK KEEPS ITS PLATES. Two plates a hit were two new nodes, two BoxMeshes and two
	# ShaderMaterials (and a tween writing into each every frame), and a block under fire is hit up
	# to eight times a second (VehicleBlock.HIT_FX_COOLDOWN): a volley of pellets made a hundred
	# materials. Now the first hit makes them, hidden after, and every later hit lights them again.
	var plates: Array = block.get_meta(&"hit_plates") if block.has_meta(&"hit_plates") else []
	for i in mini(faces, dirs.size()):
		if i >= plates.size() or not is_instance_valid(plates[i]):
			var made := _make_hit_plate(block)
			if i >= plates.size():
				plates.append(made)
			else:
				plates[i] = made
		_flash_plate(plates[i], aabb, dirs[i])
	block.set_meta(&"hit_plates", plates)

static func _make_hit_plate(block: Node3D) -> MeshInstance3D:
	var fx := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3.ONE
	fx.mesh = bm
	fx.set_meta("block_fx", true)          # см. _local_aabb: свои эффекты в габарит не входят
	fx.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var mat := ShaderMaterial.new()
	mat.shader = SHADER
	mat.set_shader_parameter("mode", 2)
	mat.set_shader_parameter("progress", 1.0)
	fx.material_override = mat
	fx.visible = false
	block.add_child(fx)
	return fx

static func _flash_plate(fx: MeshInstance3D, aabb: AABB, dir: Vector3) -> void:
	var center := aabb.get_center()
	var half := aabb.size * 0.5
	var plate_size := aabb.size
	if absf(dir.x) > 0.5:      plate_size.x = HIT_THICKNESS
	elif absf(dir.y) > 0.5:    plate_size.y = HIT_THICKNESS
	else:                      plate_size.z = HIT_THICKNESS
	# Центр пластины — на выбранной грани блока, чуть наружу (не тонет в поверхности).
	var axis := 0 if absf(dir.x) > 0.5 else (1 if absf(dir.y) > 0.5 else 2)
	var plate_center := center + dir * (half[axis] + HIT_THICKNESS * 0.5 + 0.01)
	fx.transform = Transform3D(Basis().scaled(plate_size), plate_center)
	var mat := fx.material_override as ShaderMaterial
	mat.set_shader_parameter("seed", randf() * 100.0)
	mat.set_shader_parameter("progress", 0.0)
	fx.visible = true
	if fx.has_meta(&"tw"):
		var old = fx.get_meta(&"tw")
		if old is Tween and (old as Tween).is_valid():
			(old as Tween).kill()
	var tw := fx.create_tween()
	tw.tween_method(_set_card_progress.bind(mat), 0.0, 1.0, HIT_DURATION)
	tw.tween_callback(fx.hide)
	fx.set_meta(&"tw", tw)

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
## THE SIGN AT REST STAYS A GLITCH, NOT A POLISHED GLYPH: cards lock in only GLYPH_SOLID solid, so
## they keep holes and flicker; each sits up to GLYPH_SKEW cells off its place, so the outline is not
## ruler-straight; and in stepped glitch frames (GLYPH_JIT_STEP) a few pixels jump sideways.
const GLYPH_SOLID := 0.5
const GLYPH_SKEW := 0.14
const GLYPH_JIT_STEP := 0.07
const GLYPH_JIT_CHANCE := 0.16
const GLYPH_JIT := 0.35          # how far a jumping pixel goes, in cells
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
				var skew := Vector3(randf_range(-1.0, 1.0), randf_range(-1.0, 1.0), 0.0) * GLYPH_SKEW * cell
				targets.append(Vector3((float(x) - float(cols - 1) * 0.5) * cell,
						(float(rows - 1) * 0.5 - float(y)) * cell, 0.0) + skew)
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
		card.set_meta("cell", cell)
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
		var c = cards[i]                  # untyped: a freed card must be asked, not assigned (rule 4)
		if not is_instance_valid(c):
			continue
		var a: float = clampf((t - float(delays[i])) / GLYPH_FLY, 0.0, 1.0)
		var e: float = 1.0 - pow(1.0 - a, 3.0)
		var at: Vector3 = (starts[i] as Vector3).lerp(targets[i], e)
		if a >= 1.0:
			# A glitch frame: stepped, not smooth - the same step for every card, its own roll.
			var k: int = int(t / GLYPH_JIT_STEP)
			var roll: float = fposmod(sin(float(k * 131 + i * 17) * 12.9898) * 43758.5453, 1.0)
			if roll < GLYPH_JIT_CHANCE:
				at.x += (1.0 if roll < GLYPH_JIT_CHANCE * 0.5 else -1.0) * GLYPH_JIT * float(c.get_meta("cell"))
		c.position = at
		var sz: float = lerpf(float(c.get_meta("big")), float(c.get_meta("small")), e)
		c.scale = Vector3(sz, sz, 1.0)
		(mats[i] as ShaderMaterial).set_shader_parameter("progress", pr)
		# Solider as it locks in, but only GLYPH_SOLID: in place it is still a glitch, with holes.
		(mats[i] as ShaderMaterial).set_shader_parameter("solid", a * a * GLYPH_SOLID)

# ── AN ORDINARY GLITCH WHERE A SHOT HIT THE WORLD ─────────────────────────────
# A shot that lands on the ground, a rock or a tree leaves a patch of plain glitch lying on the
# surface: the very card a block appears with (CARD_SHADER, its palette, its flicker and fade), only
# flat (`lie_flat`) so it stays on the ground as the camera orbits. Damage, not a hole - a dark
# core read as the world breaking open, and the mark only has to say "that landed there". The door
# is WeaponBlock._on_bullet_body_entered, the branch for a body that takes no damage.
#
# A POOL, NOT A NODE PER HIT. A machine gun puts several shots a second into the ground; the oldest
# patch is taken for the newest, so a long burst costs HOLE_POOL nodes and no more. Past HOLE_DIST
# nothing is made at all - a patch the size of a hand cannot be seen from there.
const HOLE_POOL := 24
const HOLE_LIFE := 2.0
const HOLE_SIZE := 0.7
const HOLE_DIST := 90.0
const HOLE_LIFT := 0.03          # off the surface, or it z-fights with the ground it lies on
static var _holes: Array = []
static var _hole_next: int = 0

static func ground_glitch(anchor: Node, pos: Vector3, normal: Vector3) -> void:
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
		m.shader = CARD_SHADER
		m.set_shader_parameter("lie_flat", true)
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
	mat.set_shader_parameter("depth_lift", G.grass_lift() + HOLE_LIFT)
	mat.set_shader_parameter("grid_cells", 4.0 if randf() < 0.5 else 6.0)
	mat.set_shader_parameter("fill_threshold", randf_range(0.30, 0.46))
	# From a third in: the card shader spends 0..0.5 coming up, and a hit is at full strength at once.
	mat.set_shader_parameter("progress", 0.3)
	var tw := mi.create_tween()
	tw.tween_method(_set_card_progress.bind(mat), 0.3, 1.0, HOLE_LIFE)
	tw.tween_callback(mi.hide)
	mi.set_meta("tw", tw)

# ── A FLAT WAVE OF RED PIXELS WHERE A MACHINE LANDED HARD ─────────────────────
# MachineBody.sense_ground raises it on the tick the wheels find ground after a fall, with the
# falling speed as the strength; the radius follows it. One quad per landing, no pool: landings are
# rare next to shots. Lies on the ground normal under the machine and a hand's width above it.
const WAVE_SHADER := preload("res://ground_wave.gdshader")
const WAVE_COL := Color(1.0, 0.13, 0.1)
const WAVE_DUR := 0.75
const WAVE_R_MIN := 3.0
const WAVE_R_MAX := 9.0
const WAVE_R_PER_MS := 0.3       # metres of radius per m/s of landing speed
const WAVE_LIFT := 0.08

static func ground_wave(anchor: Node, pos: Vector3, normal: Vector3, speed: float) -> void:
	if anchor == null or not anchor.is_inside_tree():
		return
	var cam: Camera3D = anchor.get_viewport().get_camera_3d()
	if cam != null and cam.global_position.distance_squared_to(pos) > FLASH_DIST * FLASH_DIST:
		return
	var tree := anchor.get_tree()
	var host: Node = tree.current_scene if tree.current_scene != null else tree.root
	var r: float = clampf(WAVE_R_MIN + speed * WAVE_R_PER_MS, WAVE_R_MIN, WAVE_R_MAX)
	var mi := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(r * 2.0, r * 2.0)
	mi.mesh = pm
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.set_meta("block_fx", true)
	var m := ShaderMaterial.new()
	m.shader = WAVE_SHADER
	m.set_shader_parameter("radius_m", r)
	m.set_shader_parameter("seed", randf() * 100.0)
	m.set_shader_parameter("color", Vector3(WAVE_COL.r, WAVE_COL.g, WAVE_COL.b))
	m.set_shader_parameter("progress", 0.0)
	m.set_shader_parameter("depth_lift", G.grass_lift() + WAVE_LIFT)
	mi.material_override = m
	host.add_child(mi)
	var up: Vector3 = normal.normalized() if normal.length_squared() > 0.0001 else Vector3.UP
	var side: Vector3 = up.cross(Vector3.FORWARD if absf(up.dot(Vector3.FORWARD)) < 0.9 else Vector3.RIGHT).normalized()
	mi.global_transform = Transform3D(Basis(side, up, side.cross(up)), pos + up * WAVE_LIFT)
	var tw := mi.create_tween()
	# EASE_OUT: the blow travels fast and slows as it spreads, the way a thud reads.
	tw.tween_method(_set_card_progress.bind(m), 0.0, 1.0, WAVE_DUR).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)
	tw.tween_callback(mi.queue_free)

# ── A GREEN NEON FRAME ON EVERY BLOCK YOUR GUNS ARE LOCKED ON (LockFrame) ────
# Counted per target: a gun that takes a block calls lock_hold, one that lets go calls lock_release,
# and the block carries the count and its one frame as metas. Several guns on one block share one
# frame. The frame is the block's child, so it dies with the block, count and all.
## Preloaded rather than named by class_name - see MachineBody.MACHINE_BATCH for why.
const LOCK_FRAME := preload("res://lock_frame.gd")

static func lock_hold(block: Node3D) -> void:
	if block == null or not is_instance_valid(block) or not block.is_inside_tree():
		return
	var n: int = (int(block.get_meta("lock_n")) if block.has_meta("lock_n") else 0) + 1
	block.set_meta("lock_n", n)
	var f = block.get_meta("lock_frame") if block.has_meta("lock_frame") else null
	if is_instance_valid(f):
		f.rehold()
		return
	var aabb := _local_aabb(block)
	var fr := LOCK_FRAME.new()
	fr.setup(maxf(aabb.size.length() * 0.5, 0.6))
	fr.centre = aabb.get_center()
	block.add_child(fr)
	fr.position = fr.centre
	block.set_meta("lock_frame", fr)

static func lock_release(block: Node3D) -> void:
	if block == null or not is_instance_valid(block):
		return
	var n: int = maxi((int(block.get_meta("lock_n")) if block.has_meta("lock_n") else 1) - 1, 0)
	block.set_meta("lock_n", n)
	if n > 0:
		return
	var f = block.get_meta("lock_frame") if block.has_meta("lock_frame") else null
	if is_instance_valid(f):
		f.release()

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
	# ROUND THE BLOCK'S MIDDLE, AT LEAST ITS OWN SIZE. A cap of 2 m round the ANCHOR cut every
	# Marlit block: anchored in a corner, its model spans -1.5..0.5, so the box came out -1..0.5,
	# off-centre and smaller than the block - the damage digits drew INSIDE the Marlit cabin (the
	# player's report), and the octo's 3 m were cut to 2.
	var mid := Vector3.ZERO
	var half := Vector3.ONE * MAX_EXTENT * 0.5
	if "cells_center" in block:
		mid = block.get("cells_center")
	for c in block.get_children():
		if c is CollisionShape3D and (c as CollisionShape3D).shape is BoxShape3D:
			var bs: Vector3 = ((c as CollisionShape3D).shape as BoxShape3D).size
			half = half.max(bs * 0.5 + Vector3.ONE * 0.25)
			break
	acc = acc.intersection(AABB(mid - half, half * 2.0))
	if acc.size.x <= 0.0 or acc.size.y <= 0.0 or acc.size.z <= 0.0:
		return AABB(Vector3(-0.5, -0.5, -0.5), Vector3.ONE)
	return acc
