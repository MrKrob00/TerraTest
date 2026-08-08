extends Node
# Персист МИРА игрока (не путать с G — там прогресс: деньги/исследования). Здесь — состояние мира:
#  • Новый старт: у игрока ОДНА кабина, рядом падает базовый набор блоков; других машин нет.
#  • Любой свободный блок в мире пропадает через BLOCK_TTL (10 мин).
#  • Каждые AUTOSAVE_EVERY (5 мин) — автосейв всех машин игрока + блоков мира + их позиций.
#  • ВРАГИ не сохраняются (только машины faction 0).
# Загрузка при любой ошибке откатывается на новый старт (сейв игру не ломает).

const SAVE_PATH := "user://world_save.json"
const BAD_SAVE_PATH := "user://world_save.bad.json"   # сюда уезжает сейв, который не удалось загрузить
const SAFE_CLEARANCE := 2.0         # на сколько поднимаем машину над рельефом при восстановлении
# Рельеф — карта высот: под поверхностью нет НИЧЕГО, поэтому оказаться там глубже пары
# метров можно только провалившись сквозь неё. Прежние 60 м означали, что застрявшую в
# толще машину страховка не замечала вовсе.
const FALL_LIMIT := 3.0             # ниже рельефа на столько = провалился, поднимаем
const BLOCK_TTL := 600.0            # 10 мин — время жизни свободного блока в мире
const AUTOSAVE_EVERY := 60.0        # 1 мин — период автосейва (машины, блоки мира, позиции)

var _tick: float = 0.0

func _ready() -> void:
	# ЖДЁМ, пока машина реально достроится. Мало двух кадров: blocks.spawn_block внутри делает
	# `await get_parent().ready`, т.е. стартовые блоки доезжают ОТЛОЖЕННО. Если применить
	# сохранённую сборку в этот момент, apply_layout вычистит node_map, а «догоняющие» корутины
	# потом допишут коллизии и позиции уже освобождённым узлам — сборка из сейва затиралась
	# стартовой (и могло падать). Ждём готовности машины + пару кадров на догон корутин.
	var guard := 0
	while guard < 600:
		var v := _primary_machine()
		if v != null and v.is_node_ready() and v.get("block_map_node") != null:
			break
		await get_tree().process_frame
		guard += 1
	await get_tree().process_frame
	await get_tree().process_frame
	_purge_extra_machines()                        # оставляем только ОСНОВНУЮ машину игрока
	if FileAccess.file_exists(SAVE_PATH):
		await _load_world()        # внутри есть await (разморозка после телепорта) — дожидаемся
	else:
		_fresh_start()
	var t := Timer.new()
	t.wait_time = AUTOSAVE_EVERY
	t.autostart = true
	t.one_shot = false
	t.timeout.connect(_save_world)
	add_child(t)

func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_APPLICATION_PAUSED \
			or what == NOTIFICATION_WM_GO_BACK_REQUEST:
		_save_world()

func _process(delta: float) -> void:
	_tick += delta
	if _tick < 1.0:
		return
	_tick = 0.0
	_expire_world_blocks()                         # деспавн свободных блоков старше 10 мин
	_rescue_fallen()                               # машина провалилась сквозь рельеф — вернуть наверх

# Кэш ноды рельефа (у неё есть terrain_height_at).
var _terrain_node: Node = null

func _terrain() -> Node:
	if _terrain_node != null and is_instance_valid(_terrain_node):
		return _terrain_node
	var scn := get_tree().current_scene
	if scn == null:
		return null
	for c in scn.get_children():
		if c.has_method("terrain_height_at"):
			_terrain_node = c
			return c
	return null

# Рельеф, у которого УЖЕ загружены высоты. Пока карта не прочитала heightmap, get_dims()
# нулевой, а terrain_height_at возвращает бессмысленный ноль — и подъём «над рельефом» по
# такому нулю ставит машину внутрь холма. Именно так позиция и оказывалась под картой.
func _ready_terrain() -> Node:
	var terr := _terrain()
	if terr == null or not terr.has_method("get_dims"):
		return null
	return terr if terr.get_dims().x > 0 else null

# СТРАХОВКА: если машина оказалась заметно НИЖЕ рельефа, она провалилась сквозь него (коллизия
# рельефа стриминговая — под только что телепортированным телом её может ещё не быть). Без этого
# машина падала бесконечно, а камера уезжала за ней на километры вниз — экран становился пустым.
func _rescue_fallen() -> void:
	var terr := _ready_terrain()
	if terr == null:
		return
	var lifted: Array[RigidBody3D] = []
	for n in _fall_candidates():
		var n3 := n as Node3D
		if n3 == null or not is_instance_valid(n3):
			continue
		var ground: float = terr.terrain_height_at(n3.global_position)
		if n3.global_position.y > ground - FALL_LIMIT:
			continue
		push_warning("world_persist: %s провалился под рельеф — возвращаю наверх" % n3.name)
		var rb := n3 as RigidBody3D
		if rb != null and not rb.freeze:
			rb.freeze = true                    # замороженным (база на якоре) не мешаем
			rb.linear_velocity = Vector3.ZERO
			rb.angular_velocity = Vector3.ZERO
			lifted.append(rb)
		n3.global_position = Vector3(n3.global_position.x,
				ground + SAFE_CLEARANCE + 2.0, n3.global_position.z)
	if lifted.is_empty():
		return
	# Стриминговая коллизия рельефа строится ВОКРУГ тел, то есть уже после того, как тело
	# окажется на новом месте. Отпускаем через пару кадров, иначе провалится снова.
	await get_tree().process_frame
	await get_tree().process_frame
	for rb in lifted:
		if is_instance_valid(rb):
			rb.freeze = false

# Всё, что может провалиться: машины и свободные блоки/ресурсы в мире.
func _fall_candidates() -> Array:
	var out: Array = _player_machines().duplicate()
	var o := _objects()
	if o != null:
		out.append_array(o.get_children())
	return out

# ── Узлы сцены ────────────────────────────────────────────────────────────────
func _objects() -> Node:
	return get_node_or_null("/root/Main/objects")

func _vehicles_root() -> Node:
	return get_node_or_null("/root/Main/Vehicles")

func _camera() -> Node:
	return get_tree().get_first_node_in_group("camera_controller")

func _now() -> float:
	return float(Time.get_ticks_msec()) / 1000.0

# Машины ИГРОКА (faction 0, есть block_map_node). Враги (faction != 0) исключены.
func _player_machines() -> Array:
	var out: Array = []
	var vr := _vehicles_root()
	if vr == null:
		return out
	for c in vr.get_children():
		if c is RigidBody3D and "block_map_node" in c and c.get("block_map_node") != null \
				and "faction" in c and int(c.get("faction")) == 0:
			out.append(c)
	return out

func _primary_machine() -> Node:
	var cc := _camera()
	if cc != null and "current_vehicle" in cc and cc.current_vehicle != null:
		return cc.current_vehicle
	var m := _player_machines()
	return m[0] if not m.is_empty() else null

# Убрать лишние машины игрока (в сцене их бывает несколько для теста) — оставить только основную.
func _purge_extra_machines() -> void:
	var primary := _primary_machine()
	var cc := _camera()
	for m in _player_machines():
		if m == primary:
			continue
		if cc != null and "vehicles" in cc:
			cc.vehicles.erase(m)
		m.queue_free()

# ── Свободные блоки в мире ────────────────────────────────────────────────────
func _is_world_block(n) -> bool:
	return n is RigidBody3D and "block" in n

func _expire_world_blocks() -> void:
	var o := _objects()
	if o == null:
		return
	var now := _now()
	for c in o.get_children():
		if not _is_world_block(c):
			continue
		if not c.has_meta("world_spawn_s"):
			c.set_meta("world_spawn_s", now)           # первый раз увидели — стартуем его таймер
			continue
		if now - float(c.get_meta("world_spawn_s")) > BLOCK_TTL:
			c.queue_free()

func _spawn_world_block(bt: int, pos: Vector3, rot, age_s: float = 0.0) -> Node:
	var scene: PackedScene = G.get_scene(bt)
	var o := _objects()
	if scene == null or o == null:
		return null
	var b := scene.instantiate()
	o.add_child(b)
	if b is Node3D:
		b.global_position = pos
		if rot != null:
			b.global_rotation = rot
	b.set_meta("world_spawn_s", _now() - age_s)         # остаток жизни = TTL − age
	return b

# ── Новый старт ───────────────────────────────────────────────────────────────
func _fresh_start() -> void:
	var o := _objects()
	if o != null:
		for c in o.get_children():
			if _is_world_block(c):
				c.queue_free()                          # убрать предустановленные тест-блоки
	var primary := _primary_machine()
	if primary == null or not primary.has_method("award_block_list"):
		return
	# Базовый набор: 2 блока, 4 колеса, 1 бур, 1 пушка — глючно КРУЖАТ вокруг игрока (как награда),
	# затем осыпаются в мир (reward_orbiter.gd). Игрок подбирает их в стройке.
	primary.award_block_list([G.Block.BLOCK, G.Block.BLOCK, G.Block.WHEEL, G.Block.WHEEL,
			G.Block.WHEEL, G.Block.WHEEL, G.Block.DRILL, G.Block.GUN])

# ── Сохранение / загрузка ─────────────────────────────────────────────────────
func _save_world() -> void:
	var machines: Array = []
	for m in _player_machines():
		if m.block_map_node == null or not m.block_map_node.has_method("get_layout"):
			continue
		var gp: Vector3 = (m as Node3D).global_position
		var gr: Vector3 = (m as Node3D).global_rotation
		# В сейв не должна попасть точка ПОД рельефом. Иначе одна неудачная автосохранёнка
		# закрепляется навсегда: каждая следующая загрузка возвращает машину туда же, и
		# игрок падает снова и снова, сколько ни перезапускай.
		var terr_save := _ready_terrain()
		if terr_save != null:
			gp.y = maxf(gp.y, terr_save.terrain_height_at(gp) + SAFE_CLEARANCE)
		machines.append({
			"layout": m.block_map_node.get_layout(),
			"pos": [gp.x, gp.y, gp.z],
			"rot": [gr.x, gr.y, gr.z],
		})
	var blocks: Array = []
	var o := _objects()
	if o != null:
		var now := _now()
		for c in o.get_children():
			if not _is_world_block(c):
				continue
			var age := 0.0
			if c.has_meta("world_spawn_s"):
				age = now - float(c.get_meta("world_spawn_s"))
			var bp: Vector3 = (c as Node3D).global_position
			var br: Vector3 = (c as Node3D).global_rotation
			blocks.append({
				"block": G.block_key(int(c.get("block"))),
				"pos": [bp.x, bp.y, bp.z],
				"rot": [br.x, br.y, br.z],
				"age": age,
			})
	var f := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify({
			"version": G.SAVE_FORMAT,
			"machines": machines,
			"world_blocks": blocks,
		}))
		f.close()

func _load_world() -> void:
	var f := FileAccess.open(SAVE_PATH, FileAccess.READ)
	if f == null:
		_fresh_start()
		return
	var json := JSON.new()
	var err := json.parse(f.get_as_text())
	f.close()
	if err != OK or typeof(json.get_data()) != TYPE_DICTIONARY:
		_quarantine_save("файл не разобрался как JSON")
		_fresh_start()
		return
	var data: Dictionary = json.get_data()
	var machines: Array = data.get("machines", [])
	var primary := _primary_machine()
	if machines.is_empty() or primary == null or not primary.has_method("apply_build"):
		# Сейв есть, но машины в нём нет (например, записался до того, как машина появилась).
		# Молча оставить игрока с голой кабиной и без блоков = тупик, поэтому — новый старт.
		_quarantine_save("в сейве нет машин")
		_fresh_start()
		return
	if not _layout_ok(machines[0].get("layout", [])):
		_quarantine_save("раскладка машины повреждена")
		_fresh_start()
		return
	await _restore_machine(primary, machines[0])
	for i in range(1, machines.size()):
		_spawn_machine(machines[i])
	# Убираем предустановленные в сцене тест-блоки, иначе они копятся поверх сохранённых.
	var o := _objects()
	if o != null:
		for c in o.get_children():
			if _is_world_block(c):
				c.queue_free()
	for wb in data.get("world_blocks", []):
		var p: Variant = wb.get("pos", [0, 0, 0])
		var r: Variant = wb.get("rot", [0, 0, 0])
		_spawn_world_block(G.block_from_key(wb.get("block", 0)), Vector3(p[0], p[1], p[2]),
				Vector3(r[0], r[1], r[2]), float(wb.get("age", 0.0)))

# Проверка раскладки ДО применения: одна битая запись роняла бы сборку молча, а игрок получал
# пустую машину и не понимал почему. Требуем массив словарей с координатами в пределах сетки
# и известным типом блока.
func _layout_ok(layout) -> bool:
	if not (layout is Array) or (layout as Array).is_empty():
		return false
	for e in layout:
		if not (e is Dictionary):
			return false
		if not (e.has("x") and e.has("y") and e.has("z") and e.has("block")):
			return false
		var x := int(e["x"]); var y := int(e["y"]); var z := int(e["z"])
		if x < 0 or x > 10 or y < 0 or y > 10 or z < 0 or z > 10:
			return false                      # координаты вне сетки 11³ — файл от другой версии
		if G.block_from_key(e["block"]) == G.Block.EMPTY:
			return false                      # неизвестный блок (переименовали/удалили тип)
	return true

# Битый сейв НЕ удаляем, а отодвигаем в сторону: игра стартует заново и больше не залипает,
# а файл остаётся — по нему можно понять, что именно сломалось.
func _quarantine_save(reason: String) -> void:
	push_warning("world_persist: сейв не загружен (%s) → откладываю в %s" % [reason, BAD_SAVE_PATH])
	var d := DirAccess.open("user://")
	if d != null:
		if d.file_exists(BAD_SAVE_PATH.get_file()):
			d.remove(BAD_SAVE_PATH.get_file())
		d.rename(SAVE_PATH.get_file(), BAD_SAVE_PATH.get_file())

func _restore_machine(veh, mdata: Dictionary) -> void:
	veh.apply_build(mdata.get("layout", []))
	var p: Variant = mdata.get("pos", null)
	var r: Variant = mdata.get("rot", null)
	if not (veh is Node3D):
		return
	# Машина — RigidBody3D, и ПРЯМОЙ телепорт незамороженного тела физика откатывает, а под новой
	# точкой ещё нет стриминговой коллизии рельефа (её тайлы строятся вокруг тела уже ПОСЛЕ того,
	# как оно там окажется). Из-за этого машина проваливалась сквозь мир и бесконечно падала —
	# камера уезжала за ней на километры вниз, и экран становился пустым.
	# Поэтому: замораживаем → ставим позицию НЕ НИЖЕ рельефа → ждём пару кадров, пока построится
	# коллизия → отпускаем.
	var rb := veh as RigidBody3D
	if rb != null:
		rb.freeze = true
		rb.linear_velocity = Vector3.ZERO
		rb.angular_velocity = Vector3.ZERO
	if r != null:
		veh.global_rotation = Vector3(r[0], r[1], r[2])
	if p != null:
		var pos := Vector3(p[0], p[1], p[2])
		# Ждём, пока рельеф прочитает высоты: до этого terrain_height_at даёт ноль, подъём
		# считается от нуля, и машина встаёт внутрь холма — а дальше падает сквозь него.
		var guard: int = 0
		var terr := _ready_terrain()
		while terr == null and guard < 600:
			await get_tree().process_frame
			guard += 1
			terr = _ready_terrain()
		if terr != null:
			pos.y = maxf(pos.y, terr.terrain_height_at(pos) + SAFE_CLEARANCE)
		else:
			push_warning("world_persist: рельеф не готов — позиция машины взята из сейва как есть")
		veh.global_position = pos
	await get_tree().process_frame
	await get_tree().process_frame
	if rb != null:
		rb.freeze = false

func _spawn_machine(mdata: Dictionary) -> void:
	var scene := load("res://player_vehicle.tscn") as PackedScene
	var vr := _vehicles_root()
	if scene == null or vr == null:
		return
	var v := scene.instantiate()
	vr.add_child(v)
	await get_tree().process_frame                 # даём _ready машины отработать до apply_build
	await get_tree().process_frame
	if v.has_method("apply_build"):
		await _restore_machine(v, mdata)
	var cc := _camera()
	if cc != null and "vehicles" in cc and not cc.vehicles.has(v):
		cc.vehicles.append(v)
	if v.has_method("set_active"):
		v.set_active(false)
