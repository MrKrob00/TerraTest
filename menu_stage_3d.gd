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
## ЕЗДА ВМЕСТО ПОЗИРОВАНИЯ. Машины не стоят кругом: у каждой курс, скорость и предел поворота,
## и они КРУЖАТ друг вокруг друга, держа дистанцию, — то есть ведут себя как машины, а не как
## два повёрнутых меша. Физики для этого не нужно: рельефа тут нет, земля плоская, и вся «езда»
## — это две координаты, угол и предел скорости поворота.
##
## СТРЕЛЬБА КАК В ИГРЕ: башни доворачиваются к цели отдельно от корпуса, огонь идёт ОЧЕРЕДЯМИ,
## у дула вспышка, попадание — красные глитч-карточки (BlockFX). Один выстрел раз в секунду
## читался как «машины иногда моргают друг в друга», а не как бой.
##
## ВСЁ ДЕТЕРМИНИРОВАНО СВОИМ RNG — глобальный `randf` не трогаем, им пользуется вся игра.

const GROUND_SIZE := 420.0
## Высота, на которой стоит машина. Клетка блока — метр, низ колеса на полметра ниже её центра;
## меньше этого — и колёса уезжают под землю, что на плоском полу видно сразу.
const GROUND_Y := 0.62

## Дуэль: держат дистанцию и кружат. Ближе — расходятся, дальше — сближаются.
const PREF_DIST := 17.0
const ARENA := 30.0               # дальше от центра не уезжают: камера смотрит сюда
const CRUISE := 6.5               # м/с
const TURN_RATE := 1.6            # рад/с — предел поворота, из него и берётся крен в вираже

const TRACER_COL := Color(0.35, 0.95, 1.0)
const HIT_A := Color(1.0, 0.24, 0.18)
const HIT_B := Color(1.0, 0.62, 0.12)

## Очередь: несколько выстрелов подряд, потом пауза на «перезарядку». Ровный поток одиночных
## выглядит как метроном, а очередь — как оружие.
const BURST := Vector2i(3, 6)
const SHOT_GAP := 0.14
const RELOAD := Vector2(0.7, 1.7)
const BOLT_SPEED := 80.0
const MUZZLE_FLASH := 0.07
const TRACERS := 16
const CARDS := 48
const CARD_LIFE := 0.45

var _rng := RandomNumberGenerator.new()
var _t: float = 0.0
var _cam: Camera3D = null
## Машины: {node, pos, head, turrets, glow, fire_t, burst, next_turret, recoil, phase}.
## Ровно две — эта сцена про дуэль, а не про толпу.
var _mach: Array = []
## Пулы. Заводим ОДИН РАЗ и переиспользуем по флагу `on`: очередями стреляют обе машины, и
## создавать под каждый выстрел узел с материалом посреди меню незачем.
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
	sun.light_energy = 1.05
	sun.light_color = Color(1.0, 0.95, 0.86)
	sun.shadow_enabled = true
	# Тень только вблизи: в кадре две машины на пятачке, дальше её всё равно съедает туман.
	sun.directional_shadow_max_distance = 60.0
	add_child(sun)

	var we := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color(0.20, 0.42, 0.60)
	sky_mat.sky_horizon_color = Color(0.68, 0.71, 0.66)
	sky_mat.ground_horizon_color = Color(0.55, 0.50, 0.40)
	sky_mat.ground_bottom_color = Color(0.28, 0.25, 0.20)
	sky.sky_material = sky_mat
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	# Небо светит сильно, и на голой плоскости это давало БЕЛЫЙ ПОЛ: земля без единой детали
	# набирает свет со всего купола и выцветает. Гасим подсветку и красим землю темнее.
	env.ambient_light_energy = 0.65
	env.fog_enabled = true
	env.fog_light_color = Color(0.62, 0.64, 0.60)
	env.fog_density = 0.004
	env.fog_aerial_perspective = 0.3
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
	m.albedo_color = Color(0.42, 0.36, 0.27)
	m.roughness = 1.0
	mi.material_override = m
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)

	# Камни у арены и холмы по кольцу. Камни здесь не для красоты: на совершенно пустом полу
	# нечем мерить ни скорость машин, ни расстояние до них — движение читается как скольжение.
	var lump := SphereMesh.new()
	lump.radius = 1.0
	lump.height = 2.0
	lump.radial_segments = 10
	lump.rings = 5
	var rock_mat := StandardMaterial3D.new()
	rock_mat.albedo_color = Color(0.34, 0.30, 0.24)
	rock_mat.roughness = 1.0
	for i in 16:
		var a: float = TAU * float(i) / 16.0 + _rng.randf_range(-0.3, 0.3)
		var r: float = _rng.randf_range(12.0, 46.0)
		var s: float = _rng.randf_range(0.5, 1.7)
		var rock := MeshInstance3D.new()
		rock.mesh = lump
		rock.material_override = rock_mat
		rock.position = Vector3(cos(a) * r, -s * 0.55, sin(a) * r)
		rock.scale = Vector3(s * 1.6, s, s * 1.4)
		add_child(rock)

	var hill_mat := StandardMaterial3D.new()
	hill_mat.albedo_color = Color(0.40, 0.36, 0.29)
	hill_mat.roughness = 1.0
	for i in 9:
		var a: float = TAU * float(i) / 9.0 + _rng.randf_range(-0.2, 0.2)
		var r: float = _rng.randf_range(95.0, 165.0)
		var h := MeshInstance3D.new()
		h.mesh = lump
		h.material_override = hill_mat
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
		var n := Node3D.new()
		add_child(n)
		var turrets: Array = _assemble(n, _layout_player() if side == 0 else _layout_raider())
		var a: float = 0.0 if side == 0 else PI
		_mach.append({
			"node": n,
			"pos": Vector2(cos(a), sin(a)) * (PREF_DIST * 0.5),
			"head": 0.0,
			"turrets": turrets,
			"fire_t": _rng.randf_range(0.2, 1.0),
			"burst": 0,
			"next": 0,
			"recoil": 0.0,
			"phase": _rng.randf() * TAU,
		})

## Собрать машину и вернуть ЕЁ БАШНИ — те клетки, где стоит оружие. Башня доворачивается к цели
## отдельно от корпуса, как в игре (`WeaponBlock._track_target`): корпус едет своим курсом, ствол
## смотрит на противника.
func _assemble(root: Node3D, layout: Array) -> Array:
	var turrets: Array = []
	for e in layout:
		var bt: int = int(e[1])
		var scene: PackedScene = G.get_scene(bt)
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
		if bt == G.Block.GUN or bt == G.Block.LASER:
			var glow := _glow_sphere(0.14, TRACER_COL if bt == G.Block.LASER else Color(1.0, 0.8, 0.4))
			glow.position = Vector3(0.0, 0.3, -0.85)
			glow.visible = false
			holder.add_child(glow)
			turrets.append({"node": holder, "glow": glow, "flash": 0.0})
	return turrets

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
	tm.size = Vector3(0.07, 0.07, 2.0)          # длинная ось — Z, вдоль неё и смотрит look_at
	var tmat := _glow_mat(TRACER_COL)
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
	qm.size = Vector2(0.4, 0.4)
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

func _glow_mat(col: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = col
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	return m

func _glow_sphere(r: float, col: Color) -> MeshInstance3D:
	var sm := SphereMesh.new()
	sm.radius = r
	sm.height = r * 2.0
	sm.radial_segments = 8
	sm.rings = 4
	var mi := MeshInstance3D.new()
	mi.mesh = sm
	mi.material_override = _glow_mat(col)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mi

# ── Ход ──────────────────────────────────────────────────────────────────────
func _process(delta: float) -> void:
	_t += delta
	for i in _mach.size():
		_drive(i, delta)
	for i in _mach.size():
		_aim_and_fire(i, delta)
	_move_camera()
	_tracer_tick(delta)
	_card_tick(delta)

## ЕЗДА. Машина держит курс и не умеет повернуть быстрее предела — отсюда и виражи, и крен.
## Цель у неё одна: остаться на дистанции боя и не стоять на месте.
func _drive(i: int, delta: float) -> void:
	var m: Dictionary = _mach[i]
	var me: Vector2 = m["pos"]
	var opp: Vector2 = _mach[1 - i]["pos"]
	var to: Vector2 = opp - me
	var dist: float = maxf(to.length(), 0.001)
	var dir: Vector2 = to / dist
	# Обход по кругу: одна машина обходит по часовой, другая против — иначе они едут гуськом.
	var perp := Vector2(-dir.y, dir.x) * (1.0 if i == 0 else -1.0)
	var want: Vector2 = (dir * clampf((dist - PREF_DIST) / PREF_DIST, -1.0, 1.0) + perp * 0.9)
	if me.length() > ARENA:
		want = -me.normalized() * 0.8 + perp * 0.4      # у края арены поворачиваем к центру
	want = want.normalized()

	# Курс: у машины он в осях сцены, а модель смотрит по −Z — отсюда знаки.
	var head: float = float(m["head"])
	var want_h: float = atan2(-want.x, -want.y)
	var nh: float = lerp_angle(head, want_h, clampf(TURN_RATE * delta, 0.0, 1.0))
	var dh: float = wrapf(nh - head, -PI, PI)
	m["head"] = nh
	# Чем круче вираж, тем медленнее едем и тем сильнее крен — это и читается как «поворачивает»,
	# а не «скользит боком».
	var turn_k: float = clampf(absf(dh) / maxf(TURN_RATE * delta, 0.0001), 0.0, 1.0)
	var speed: float = CRUISE * lerpf(1.0, 0.65, turn_k)
	var fwd := Vector2(-sin(nh), -cos(nh))
	m["pos"] = me + fwd * speed * delta
	m["recoil"] = maxf(float(m["recoil"]) - delta * 6.0, 0.0)

	var n: Node3D = m["node"]
	var ph: float = float(m["phase"])
	n.position = Vector3(float(m["pos"].x), GROUND_Y + sin(_t * 5.3 + ph) * 0.025, float(m["pos"].y))
	n.rotation = Vector3(
			sin(_t * 4.1 + ph) * 0.018 - float(m["recoil"]) * 0.03,   # клевок от отдачи
			nh,
			-turn_k * signf(dh) * 0.12 + sin(_t * 3.7 + ph) * 0.012)

## Башни смотрят на противника САМИ, как в игре: корпус едет куда едет, ствол держит цель.
func _aim_and_fire(i: int, delta: float) -> void:
	var m: Dictionary = _mach[i]
	var n: Node3D = m["node"]
	var target: Vector3 = (_mach[1 - i]["node"] as Node3D).global_position + Vector3.UP * 0.6
	for t in m["turrets"]:
		var h: Node3D = t["node"]
		var loc: Vector3 = n.to_local(target)               # в осях корпуса: башня его ребёнок
		var want: float = atan2(-loc.x, -loc.z)
		h.rotation.y = lerp_angle(h.rotation.y, want, clampf(7.0 * delta, 0.0, 1.0))
		t["flash"] = maxf(float(t["flash"]) - delta, 0.0)
		var glow: MeshInstance3D = t["glow"]
		glow.visible = float(t["flash"]) > 0.0
		if glow.visible:
			glow.scale = Vector3.ONE * (0.6 + 1.4 * float(t["flash"]) / MUZZLE_FLASH)

	if (m["turrets"] as Array).is_empty():
		return
	m["fire_t"] = float(m["fire_t"]) - delta
	if float(m["fire_t"]) > 0.0:
		return
	if int(m["burst"]) > 0:
		m["burst"] = int(m["burst"]) - 1
		m["fire_t"] = SHOT_GAP
		_shoot(i)
	else:
		m["burst"] = _rng.randi_range(BURST.x, BURST.y)
		m["fire_t"] = _rng.randf_range(RELOAD.x, RELOAD.y)

func _shoot(i: int) -> void:
	var m: Dictionary = _mach[i]
	var turrets: Array = m["turrets"]
	# Стволы стреляют ПО ОЧЕРЕДИ, а не залпом: у машины их бывает два, и залп из обоих читается
	# как один выстрел.
	var idx: int = int(m["next"]) % turrets.size()
	m["next"] = idx + 1
	var t: Dictionary = turrets[idx]
	var h: Node3D = t["node"]
	var slot: Dictionary = _free_slot(_tracers)
	if slot.is_empty():
		return
	t["flash"] = MUZZLE_FLASH
	m["recoil"] = 1.0
	slot["on"] = true
	slot["p"] = 0.0
	slot["from"] = h.to_global(Vector3(0.0, 0.3, -0.95))
	slot["to"] = _hull(1 - i)
	(slot["mi"] as MeshInstance3D).visible = true

func _move_camera() -> void:
	# Камера держит В КАДРЕ ОБЕИХ: они ездят, и точка «центр мира» через полминуты оказалась бы
	# в стороне от боя. Дальность — от того, насколько они разъехались.
	var a: Vector2 = _mach[0]["pos"]
	var b: Vector2 = _mach[1]["pos"]
	var mid := (a + b) * 0.5
	var sep: float = a.distance_to(b)
	var ang: float = 0.55 + _t * 0.045
	var dist: float = clampf(sep * 1.35 + 11.0, 20.0, 36.0)
	_cam.position = Vector3(mid.x + cos(ang) * dist, 7.5 + sin(_t * 0.09) * 0.8,
			mid.y + sin(ang) * dist)
	_cam.look_at(Vector3(mid.x, 1.6, mid.y), Vector3.UP)

func _tracer_tick(delta: float) -> void:
	for t in _tracers:
		if not bool(t["on"]):
			continue
		var a: Vector3 = t["from"]
		var b: Vector3 = t["to"]
		t["p"] = float(t["p"]) + delta * BOLT_SPEED / maxf(a.distance_to(b), 0.001)
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
		mi.position = Vector3(c["pos"]) + Vector3(c["dir"]) * (0.3 + k * 1.6)
		mi.scale = Vector3.ONE * (0.6 + k * 0.9)
		var mat: StandardMaterial3D = c["mat"]
		mat.albedo_color.a = 1.0 - k

func _burst(at: Vector3) -> void:
	for i in 4:
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

## Попадание приходится ВРАЗБРОС по габариту цели: точка ровно в центре читается как лазерный
## прицел, а не как бой.
func _hull(i: int) -> Vector3:
	return (_mach[i]["node"] as Node3D).to_global(Vector3(
			_rng.randf_range(-0.7, 0.7), _rng.randf_range(0.0, 1.2), _rng.randf_range(-0.8, 1.6)))
