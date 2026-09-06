extends Node3D
## ЗАДНИК ГЛАВНОГО МЕНЮ: НАСТОЯЩИЕ МАШИНЫ ИГРЫ, а не рисунок.
##
## Здесь был бой, нарисованный целиком в `_draw` (menu_battle.gd). Довод у него был разумный —
## не поднимать ради картинки рельеф, физику и стриминг, — но результат врал: машины в меню
## состояли из прямоугольников и не имели ничего общего с тем, что игрок собирает из блоков.
## Меню — первое, что видно про игру, и оно обязано показывать ЕЁ, а не свою схему.
##
## Компромисс, на котором это стоит: сцена настоящая и трёхмерная, но В НЕЙ НЕТ НИ ОДНОГО
## ИГРОВОГО СКРИПТА. Машины собраны ИЗ МЕШЕЙ настоящих блоков — тот же приём, что у
## `build_hint.gd`: из сцены блока берём только `MeshInstance3D`, а тело, зоны, сигналы и
## скрипты выбрасываем (сама сцена в дерево не попадает, её `_ready` не срабатывает). Значит,
## тут не работает и не может заработать ни физика, ни турель, ни фабрика: это декорация из
## настоящих деталей. Земля — один плоский меш с туманом, а не LiteTerrain.
##
## СВЕТЛО, А НЕ ТЕМНО. Прошлый задник был почти чёрным, и меню читалось как экран ошибки.
## Здесь дневное небо, тёплое солнце и туман к горизонту, поэтому панели интерфейса могут
## быть маленькими: читаемость даёт их собственная подложка, а не затемнение всего экрана.
##
## ВСЁ ДЕТЕРМИНИРОВАНО СВОИМ RNG — глобальный `randf` не трогаем, им пользуется вся игра.

const GROUND_SIZE := 420.0
## Радиус, на котором машины кружат вокруг центра. Они НЕ СХОДЯТСЯ: меню открыто минутами,
## а сближающиеся машины через минуту стояли бы вплотную и упирались бы друг в друга.
const RING_R := 11.0
## Высота, на которой стоит машина: колёса у сборки на нижнем этаже, их низ и есть земля.
const GROUND_Y := 0.5

const TRACER_COL := Color(0.35, 0.95, 1.0)
const HIT_A := Color(1.0, 0.24, 0.18)
const HIT_B := Color(1.0, 0.62, 0.12)

const SHOT_EVERY := Vector2(0.45, 1.15)
const SHOT_SPEED := 55.0          # м/с: трассер долетает за долю секунды, как в бою
const TRACERS := 6                # пул: больше одновременно в кадре не бывает
const CARDS := 30
const CARD_LIFE := 0.5

var _rng := RandomNumberGenerator.new()
var _t: float = 0.0
var _cam: Camera3D = null
## Машины: {node, recoil, phase}. Ровно две — эта сцена про дуэль, а не про толпу.
var _mach: Array = []
var _shot_t: float = 0.0
## Пулы. Заводим ОДИН РАЗ и переиспользуем по флагу `on`: выстрел раз в полсекунды сам по себе
## дёшев, но меню живёт долго, и создавать под каждый узел с материалом незачем.
var _tracers: Array = []
var _cards: Array = []

func _ready() -> void:
	_rng.seed = 0x7A11
	_build_environment()
	_build_ground()
	_build_machines()
	_build_pools()
	set_process(true)

# ── Сцена ────────────────────────────────────────────────────────────────────
func _build_environment() -> void:
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-38.0, 128.0, 0.0)
	sun.light_energy = 1.15
	sun.light_color = Color(1.0, 0.95, 0.86)
	sun.shadow_enabled = true
	# Тень только вблизи: в кадре две машины на пятачке, дальше её всё равно съедает туман.
	sun.directional_shadow_max_distance = 45.0
	add_child(sun)

	var we := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color(0.22, 0.44, 0.62)
	sky_mat.sky_horizon_color = Color(0.74, 0.76, 0.70)
	sky_mat.ground_horizon_color = Color(0.62, 0.57, 0.46)
	sky_mat.ground_bottom_color = Color(0.30, 0.27, 0.22)
	sky.sky_material = sky_mat
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 1.0
	# Туман прячет край плоскости: без него меш земли обрывается прямой линией по горизонту.
	env.fog_enabled = true
	env.fog_light_color = Color(0.70, 0.72, 0.68)
	env.fog_density = 0.0055
	env.fog_aerial_perspective = 0.35
	we.environment = env
	add_child(we)

	_cam = Camera3D.new()
	_cam.fov = 52.0
	_cam.far = 600.0
	_cam.current = true
	add_child(_cam)

func _build_ground() -> void:
	var pm := PlaneMesh.new()
	pm.size = Vector2(GROUND_SIZE, GROUND_SIZE)
	var mi := MeshInstance3D.new()
	mi.mesh = pm
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.53, 0.47, 0.35)
	m.roughness = 1.0
	mi.material_override = m
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)

	# Холмы по кольцу — глубина за ту же копейку. Их не видно целиком: туман съедает верх,
	# и от них остаётся ровно то, ради чего они стоят, — что горизонт не пустой.
	var hill := SphereMesh.new()
	hill.radius = 1.0
	hill.height = 2.0
	hill.radial_segments = 12
	hill.rings = 6
	var hm := StandardMaterial3D.new()
	hm.albedo_color = Color(0.46, 0.42, 0.33)
	hm.roughness = 1.0
	for i in 9:
		var a: float = TAU * float(i) / 9.0 + _rng.randf_range(-0.2, 0.2)
		var r: float = _rng.randf_range(95.0, 165.0)
		var h := MeshInstance3D.new()
		h.mesh = hill
		h.material_override = hm
		h.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		h.position = Vector3(cos(a) * r, -_rng.randf_range(4.0, 9.0), sin(a) * r)
		h.scale = Vector3(_rng.randf_range(28.0, 58.0), _rng.randf_range(10.0, 20.0),
				_rng.randf_range(28.0, 58.0))
		add_child(h)

# ── Машины ───────────────────────────────────────────────────────────────────
## Сборки повторяют настоящие пресеты из `blocks.gd` (машина игрока и «рейдер»), но заданы
## ЗДЕСЬ списком клеток. Позвать `blocks.gd` нельзя: это узел машины со скриптами, физикой и
## картой 11³ — он потянул бы за собой ровно то, чего в меню быть не должно.
func _layout_player() -> Array:
	# Кабина, шесть колёс, бур спереди, лазер сверху — `blocks._layout_default`.
	var l: Array = [
		[Vector3i(5, 5, 5), G.Block.CABIN, 0.0],
		[Vector3i(5, 5, 6), G.Block.BLOCK, 0.0],
		[Vector3i(5, 5, 7), G.Block.BLOCK, 0.0],
		[Vector3i(5, 5, 4), G.Block.DRILL, 0.0],
		[Vector3i(5, 6, 5), G.Block.LASER, 0.0],
	]
	l.append_array(_side_wheels(G.Block.WHEEL, [5, 6, 7]))
	return l

func _layout_raider() -> Array:
	# Рейдер: шесть колёс, две пушки, борта в броне — `blocks._layout_raider`.
	var l: Array = [
		[Vector3i(5, 5, 5), G.Block.CABIN, 0.0],
		[Vector3i(5, 5, 6), G.Block.BLOCK, 0.0],
		[Vector3i(5, 5, 7), G.Block.BLOCK, 0.0],
		[Vector3i(5, 6, 6), G.Block.BLOCK, 0.0],
		[Vector3i(4, 6, 6), G.Block.ARMOR, PI / 2],
		[Vector3i(6, 6, 6), G.Block.ARMOR, -PI / 2],
		[Vector3i(5, 6, 5), G.Block.GUN, 0.0],
		[Vector3i(5, 6, 7), G.Block.GUN, 0.0],
	]
	l.append_array(_side_wheels(G.Block.WHEEL, [5, 6, 7]))
	return l

func _side_wheels(bt: int, rows: Array) -> Array:
	var l: Array = []
	for z in rows:
		l.append([Vector3i(4, 5, int(z)), bt, PI / 2])
		l.append([Vector3i(6, 5, int(z)), bt, -PI / 2])
	return l

func _build_machines() -> void:
	for side in 2:
		var m := Node3D.new()
		add_child(m)
		_assemble(m, _layout_player() if side == 0 else _layout_raider())
		_mach.append({"node": m, "recoil": 0.0, "phase": _rng.randf() * TAU})

func _assemble(root: Node3D, layout: Array) -> void:
	for e in layout:
		var scene: PackedScene = G.get_scene(int(e[1]))
		if scene == null:
			continue
		var cell: Vector3i = e[0]
		var holder := Node3D.new()
		# Та же формула, по которой blocks.gd ставит настоящий блок: сетка 11³ с центром 5,5,5.
		holder.position = Vector3(float(cell.x - 5), float(cell.y - 5), float(cell.z - 5))
		holder.rotation.y = float(e[2])
		root.add_child(holder)
		var src: Node = scene.instantiate()
		_copy_meshes(src, holder, Transform3D.IDENTITY)
		src.free()                  # орфан: в дерево не попадал, _ready не отработал

## Переносим ВИДИМУЮ часть блока и его РОДНЫЕ материалы. Отличие от `build_hint`: тот красит
## копию в белый призрак, а тут машина должна выглядеть ровно так, как в игре.
func _copy_meshes(node: Node, dst: Node3D, xform: Transform3D) -> void:
	var here := xform
	if node is Node3D and node.get_parent() != null:
		here = xform * (node as Node3D).transform
	var src_mi := node as MeshInstance3D
	if src_mi != null and src_mi.mesh != null and src_mi.visible:
		var mi := MeshInstance3D.new()
		mi.mesh = src_mi.mesh
		mi.material_override = src_mi.material_override
		mi.transform = here
		dst.add_child(mi)
	for c in node.get_children():
		_copy_meshes(c, dst, here)

# ── Пулы эффектов ────────────────────────────────────────────────────────────
func _build_pools() -> void:
	var tm := BoxMesh.new()
	tm.size = Vector3(0.08, 0.08, 2.2)          # длинная ось — Z, вдоль неё и смотрит look_at
	var tmat := StandardMaterial3D.new()
	tmat.albedo_color = TRACER_COL
	tmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	tmat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	for i in TRACERS:
		var mi := MeshInstance3D.new()
		mi.mesh = tm
		mi.material_override = tmat
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.visible = false
		add_child(mi)
		_tracers.append({"mi": mi, "on": false, "from": Vector3.ZERO, "to": Vector3.ZERO, "p": 0.0})

	# Попадание — КРАСНЫЕ ГЛИТЧ-КАРТОЧКИ, тот же словарь, которым игра говорит про урон
	# (BlockFX). Одинаковый смысл обязан выглядеть одинаково и в меню, и в бою.
	var qm := QuadMesh.new()
	qm.size = Vector2(0.45, 0.45)
	for i in CARDS:
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
		var mi := MeshInstance3D.new()
		mi.mesh = qm
		mi.material_override = mat
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.visible = false
		add_child(mi)
		_cards.append({"mi": mi, "mat": mat, "on": false, "t": 0.0,
				"pos": Vector3.ZERO, "dir": Vector3.UP})

# ── Ход ──────────────────────────────────────────────────────────────────────
func _process(delta: float) -> void:
	_t += delta
	_move_machines(delta)
	_move_camera()
	_fire_tick(delta)
	_tracer_tick(delta)
	_card_tick(delta)

func _move_machines(delta: float) -> void:
	for i in _mach.size():
		var m: Dictionary = _mach[i]
		m["recoil"] = maxf(float(m["recoil"]) - delta * 5.0, 0.0)
		var n: Node3D = m["node"]
		var base: float = 0.0 if i == 0 else PI
		var a: float = base + _t * 0.10 + sin(_t * 0.5 + float(m["phase"])) * 0.22
		# Отдача отталкивает машину ОТ центра — выстрел без неё читается как полоска из ниоткуда.
		var r: float = RING_R + sin(_t * 0.33 + float(i)) * 1.6 + float(m["recoil"]) * 0.7
		n.position = Vector3(cos(a) * r, GROUND_Y, sin(a) * r)
		n.look_at(Vector3(cos(a + PI) * RING_R, GROUND_Y, sin(a + PI) * RING_R), Vector3.UP)
		# Подвеска: без качки машина едет как приклеенная к плоскости.
		n.rotation.z = sin(_t * 1.7 + float(i) * 2.0) * 0.035
		n.rotation.x = sin(_t * 1.3 + float(i)) * 0.02

func _move_camera() -> void:
	# Камера идёт вокруг МЕДЛЕННЕЕ машин: иначе они висят в кадре неподвижно и бой не читается.
	var a: float = 0.55 + _t * 0.045
	var d: float = 24.0 + sin(_t * 0.12) * 2.5
	_cam.position = Vector3(cos(a) * d, 7.0 + sin(_t * 0.09) * 0.9, sin(a) * d)
	_cam.look_at(Vector3(0.0, 1.6, 0.0), Vector3.UP)

func _fire_tick(delta: float) -> void:
	_shot_t -= delta
	if _shot_t > 0.0:
		return
	_shot_t = _rng.randf_range(SHOT_EVERY.x, SHOT_EVERY.y)
	var from_i: int = 0 if _rng.randf() < 0.5 else 1
	var t: Dictionary = _free_slot(_tracers)
	if t.is_empty():
		return
	_mach[from_i]["recoil"] = 1.0
	t["on"] = true
	t["p"] = 0.0
	t["from"] = _muzzle(from_i)
	t["to"] = _hull(1 - from_i)
	(t["mi"] as MeshInstance3D).visible = true

func _tracer_tick(delta: float) -> void:
	for t in _tracers:
		if not bool(t["on"]):
			continue
		var a: Vector3 = t["from"]
		var b: Vector3 = t["to"]
		var len_ab: float = a.distance_to(b)
		t["p"] = float(t["p"]) + delta * SHOT_SPEED / maxf(len_ab, 0.001)
		var mi: MeshInstance3D = t["mi"]
		if float(t["p"]) >= 1.0:
			t["on"] = false
			mi.visible = false
			_burst(b)
			continue
		mi.position = a.lerp(b, float(t["p"]))
		if mi.position.distance_squared_to(b) > 0.01:
			mi.look_at(b, Vector3.UP)

func _card_tick(delta: float) -> void:
	for c in _cards:
		if not bool(c["on"]):
			continue
		var k: float = float(c["t"]) + delta / CARD_LIFE
		c["t"] = k
		var mi: MeshInstance3D = c["mi"]
		if k >= 1.0:
			c["on"] = false
			mi.visible = false
			continue
		mi.position = Vector3(c["pos"]) + Vector3(c["dir"]) * (0.3 + k * 1.7)
		mi.scale = Vector3.ONE * (0.6 + k * 0.9)
		var mat: StandardMaterial3D = c["mat"]
		mat.albedo_color.a = 1.0 - k

func _burst(at: Vector3) -> void:
	for i in 5:
		var c: Dictionary = _free_slot(_cards)
		if c.is_empty():
			return
		c["on"] = true
		c["t"] = 0.0
		c["pos"] = at
		var ang: float = _rng.randf() * TAU
		c["dir"] = Vector3(cos(ang), _rng.randf_range(0.15, 1.0), sin(ang)).normalized()
		var mat: StandardMaterial3D = c["mat"]
		mat.albedo_color = HIT_A if i % 2 == 0 else HIT_B
		(c["mi"] as MeshInstance3D).visible = true

func _free_slot(pool: Array) -> Dictionary:
	for e in pool:
		if not bool(e["on"]):
			return e
	return {}

## Ствол и корпус — в МЕСТНЫХ координатах машины: она кружит и поворачивается, а точки едут
## вместе с ней сами.
func _muzzle(i: int) -> Vector3:
	return (_mach[i]["node"] as Node3D).to_global(Vector3(0.0, 1.1, -1.3))

## Попадание приходится ВРАЗБРОС по габариту цели: точка ровно в центре читается как лазерный
## прицел, а не как бой.
func _hull(i: int) -> Vector3:
	return (_mach[i]["node"] as Node3D).to_global(Vector3(
			_rng.randf_range(-0.7, 0.7), _rng.randf_range(0.0, 1.2), _rng.randf_range(-0.8, 1.6)))
