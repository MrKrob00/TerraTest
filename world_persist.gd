extends Node
# Персист МИРА игрока (не путать с G — там прогресс: деньги/исследования). Здесь — состояние мира:
#  • Новый старт: у игрока ОДНА кабина, рядом падает базовый набор блоков; других машин нет.
#  • Любой свободный блок в мире пропадает через BLOCK_TTL (10 мин).
#  • Каждые AUTOSAVE_EVERY (5 мин) — автосейв всех машин игрока + блоков мира + их позиций.
#  • ВРАГИ не сохраняются (только машины faction 0).
# Загрузка при любой ошибке откатывается на новый старт (сейв игру не ломает).

const SAVE_PATH := "user://world_save.json"
const BLOCK_TTL := 600.0            # 10 мин — время жизни свободного блока в мире
const AUTOSAVE_EVERY := 300.0       # 5 мин — период автосейва

var _tick: float = 0.0

func _ready() -> void:
	# Даём машинам/камере доиниться (у vehicle._ready есть await), потом решаем старт.
	await get_tree().process_frame
	await get_tree().process_frame
	_purge_extra_machines()                        # оставляем только ОСНОВНУЮ машину игрока
	if FileAccess.file_exists(SAVE_PATH):
		_load_world()
	else:
		_fresh_start()
	var t := Timer.new()
	t.wait_time = AUTOSAVE_EVERY
	t.autostart = true
	t.one_shot = false
	t.timeout.connect(_save_world)
	add_child(t)

func _process(delta: float) -> void:
	_tick += delta
	if _tick < 1.0:
		return
	_tick = 0.0
	_expire_world_blocks()                         # деспавн свободных блоков старше 10 мин

# ── Узлы сцены ────────────────────────────────────────────────────────────────
func _objects() -> Node:
	return get_node_or_null("/root/Main/objects")

func _vehicles_root() -> Node:
	return get_node_or_null("/root/Main/Vehicles")

func _camera():
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

func _primary_machine():
	var cc = _camera()
	if cc != null and "current_vehicle" in cc and cc.current_vehicle != null:
		return cc.current_vehicle
	var m := _player_machines()
	return m[0] if not m.is_empty() else null

# Убрать лишние машины игрока (в сцене их бывает несколько для теста) — оставить только основную.
func _purge_extra_machines() -> void:
	var primary = _primary_machine()
	var cc = _camera()
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
	var b = scene.instantiate()
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
	var primary = _primary_machine()
	if primary == null or not (primary is Node3D):
		return
	# Базовый набор: 2 блока, 4 колеса, 1 бур, 1 пушка — падают вокруг игрока.
	var drop := [G.Block.BLOCK, G.Block.BLOCK, G.Block.WHEEL, G.Block.WHEEL,
			G.Block.WHEEL, G.Block.WHEEL, G.Block.DRILL, G.Block.GUN]
	var base: Vector3 = (primary as Node3D).global_position
	for i in drop.size():
		var ang := TAU * float(i) / float(drop.size())
		_spawn_world_block(int(drop[i]), base + Vector3(cos(ang) * 3.5, 2.5, sin(ang) * 3.5), null)

# ── Сохранение / загрузка ─────────────────────────────────────────────────────
func _save_world() -> void:
	var machines: Array = []
	for m in _player_machines():
		if m.block_map_node == null or not m.block_map_node.has_method("get_layout"):
			continue
		var gp: Vector3 = (m as Node3D).global_position
		var gr: Vector3 = (m as Node3D).global_rotation
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
				"block": int(c.get("block")),
				"pos": [bp.x, bp.y, bp.z],
				"rot": [br.x, br.y, br.z],
				"age": age,
			})
	var f := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify({"machines": machines, "world_blocks": blocks}))
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
		_fresh_start()
		return
	var data: Dictionary = json.get_data()
	var machines: Array = data.get("machines", [])
	var primary = _primary_machine()
	if not machines.is_empty() and primary != null and primary.has_method("apply_build"):
		_restore_machine(primary, machines[0])
		for i in range(1, machines.size()):
			_spawn_machine(machines[i])
	for wb in data.get("world_blocks", []):
		var p = wb.get("pos", [0, 0, 0])
		var r = wb.get("rot", [0, 0, 0])
		_spawn_world_block(int(wb.get("block", 0)), Vector3(p[0], p[1], p[2]),
				Vector3(r[0], r[1], r[2]), float(wb.get("age", 0.0)))

func _restore_machine(veh, mdata: Dictionary) -> void:
	veh.apply_build(mdata.get("layout", []))
	var p = mdata.get("pos", null)
	var r = mdata.get("rot", null)
	if veh is Node3D:
		if p != null:
			veh.global_position = Vector3(p[0], p[1], p[2])
		if r != null:
			veh.global_rotation = Vector3(r[0], r[1], r[2])

func _spawn_machine(mdata: Dictionary) -> void:
	var scene := load("res://player_vehicle.tscn") as PackedScene
	var vr := _vehicles_root()
	if scene == null or vr == null:
		return
	var v = scene.instantiate()
	vr.add_child(v)
	await get_tree().process_frame                 # даём _ready машины отработать до apply_build
	await get_tree().process_frame
	if v.has_method("apply_build"):
		_restore_machine(v, mdata)
	var cc = _camera()
	if cc != null and "vehicles" in cc and not cc.vehicles.has(v):
		cc.vehicles.append(v)
	if v.has_method("set_active"):
		v.set_active(false)
