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
# Рельеф — карта высот, под поверхностью нет ничего, так что провалившееся тело улетает
# на сотни метров вниз. Порог держим с запасом: terrain_height_at берёт высоту в точке XZ
# тела, и у подножия обрыва она бывает заметно выше того места, где тело законно стоит —
# со слишком чутким порогом страховка начала бы телепортировать технику на ровном месте.
# Прежние 60 м были слишком грубы (машину, застрявшую в толще холма, не замечали вовсе),
# 15 ловит и это, и настоящее падение, не срабатывая на рельефе.
const FALL_LIMIT := 15.0
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
		var v = _primary_machine()
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
	_cull_tick(delta)                              # гасим то, что за спиной (свой период, чаще)
	_tick += delta
	if _tick < 1.0:
		return
	_tick = 0.0
	_expire_world_blocks()                         # деспавн свободных блоков старше 10 мин
	_rescue_fallen()                               # машина провалилась сквозь рельеф — вернуть наверх

# ── Отсечение того, что ЗА СПИНОЙ ────────────────────────────────────────────
# Свободный блок в мире — это не только меш (его движок и так не рисует за камерой), но и
# ЖИВОЙ СКРИПТ: лежащий на земле коллектор всё так же перебирает ресурсы вокруг, лента
# двигает предметы, зарядник каждые полсекунды обходит все машины. Полсотни таких блоков за
# спиной стоят ровно столько же, сколько перед носом, а пользы от них ноль.
#
# Гасим ТОЛЬКО СПЯЩИЕ тела: у спящего физика и так не считается, и остановить ему скрипт
# безопасно. Летящий/катящийся блок не трогаем совсем — иначе он замер бы в воздухе и
# доехал бы вниз рывком, когда игрок обернётся.
#
# Ближний пузырь оставляем активным в любую сторону: то, что рядом, участвует в игре
# (магнит упаковщика, приёмник, подбор рукой), и гасить его по направлению взгляда нельзя.
const CULL_PERIOD := 0.25
const CULL_KEEP_RADIUS := 25.0       # м: ближе этого блок активен, куда бы ни смотрела камера
const CULL_VIEW_COS := -0.15         # чуть шире полусферы перед камерой — край не мигает
const CULL_META := "culled"
var _cull_t: float = 0.0

func _cull_tick(delta: float) -> void:
	_cull_t -= delta
	if _cull_t > 0.0:
		return
	_cull_t = CULL_PERIOD
	var o := _objects()
	if o == null:
		return
	var cam := get_viewport().get_camera_3d() if get_viewport() != null else null
	if cam == null:
		return
	var cam_pos: Vector3 = cam.global_position
	var fwd: Vector3 = -cam.global_transform.basis.z
	var keep2: float = CULL_KEEP_RADIUS * CULL_KEEP_RADIUS
	for c in o.get_children():
		var n := c as Node3D
		if n == null:
			continue
		var was: bool = n.has_meta(CULL_META)
		var to: Vector3 = n.global_position - cam_pos
		var d2: float = to.length_squared()
		var behind: bool = d2 > keep2 and to.normalized().dot(fwd) < CULL_VIEW_COS
		if behind == was:
			continue
		if behind:
			var rb := n as RigidBody3D
			if rb != null and not rb.sleeping and not rb.freeze:
				continue                    # ещё едет/падает — досчитаем, погасим в следующий раз
			n.set_meta(CULL_META, true)
			n.visible = false
			n.process_mode = Node.PROCESS_MODE_DISABLED
		else:
			n.remove_meta(CULL_META)
			n.visible = true
			n.process_mode = Node.PROCESS_MODE_INHERIT

# Кэш ноды рельефа (у неё есть terrain_height_at).
var _terrain_node: Node = null
var _warned_no_terrain: bool = false

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
# Сколько ждём готовности рельефа при восстановлении. Держать дольше нельзя: всё это время
# машина заморожена, а игрок смотрит на неподвижную картинку.
const TERRAIN_WAIT_FRAMES: int = 120

func _await_terrain(max_frames: int) -> Node:
	var terr := _ready_terrain()
	var guard: int = 0
	while terr == null and guard < max_frames:
		await get_tree().process_frame
		guard += 1
		terr = _ready_terrain()
	return terr

func _ready_terrain() -> Node:
	var terr := _terrain()
	if terr == null or not terr.has_method("get_dims"):
		return null
	return terr if terr.get_dims().x > 0 else null

# СТРАХОВКА: если машина оказалась заметно НИЖЕ рельефа, она провалилась сквозь него (коллизия
# рельефа стриминговая — под только что телепортированным телом её может ещё не быть). Без этого
# машина падала бесконечно, а камера уезжала за ней на километры вниз — экран становился пустым.
# Абсолютный пол мира: ниже него тело падает в пустоту, и никакой рельеф для этого
# вывода не нужен. Нужен именно такой запасной путь — страховка не должна зависеть от
# готовности карты, иначе она молча выключается ровно тогда, когда нужнее всего.
const WORLD_FLOOR := -300.0

func _rescue_fallen() -> void:
	# ВНИМАНИЕ: здесь _terrain(), а не _ready_terrain(). Гейт по готовности отключал
	# страховку без единого слова в логе — и провалившаяся машина падала вечно.
	var terr := _terrain()
	var ready_terr := _ready_terrain()
	if terr == null and not _warned_no_terrain:
		_warned_no_terrain = true
		push_warning("world_persist: узел рельефа не найден — страховка работает только "
				+ "по абсолютному полу %.0f" % WORLD_FLOOR)
	var lifted: Array[RigidBody3D] = []
	for n in _fall_candidates():
		var n3 := n as Node3D
		if n3 == null or not is_instance_valid(n3):
			continue
		# Земля известна только если карта уже прочитала высоты; иначе судим по полу мира.
		var ground: float = ready_terr.terrain_height_at(n3.global_position) if ready_terr != null else 0.0
		var fell: bool = (ready_terr != null and n3.global_position.y < ground - FALL_LIMIT) \
				or n3.global_position.y < WORLD_FLOOR
		if not fell:
			continue
		var diag: String = ""
		if terr != null and terr.has_method("collision_debug_at"):
			diag = " | " + str(terr.call("collision_debug_at", n3.global_position))
		push_warning("world_persist: %s провалился под рельеф (y=%.1f, земля %.1f)%s"
				% [n3.name, n3.global_position.y, ground, diag])
		var rb := n3 as RigidBody3D
		if rb != null and not rb.freeze:
			rb.freeze = true                    # замороженным (база на якоре) не мешаем
			rb.linear_velocity = Vector3.ZERO
			rb.angular_velocity = Vector3.ZERO
			lifted.append(rb)
		# Без готового рельефа поднимаем повыше и даём упасть на землю самому.
		var lift_y: float = (ground + SAFE_CLEARANCE + 2.0) if ready_terr != null else 200.0
		n3.global_position = Vector3(n3.global_position.x, lift_y, n3.global_position.z)
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
## Правки рельефа, которые надо сохранить. Живут они в самой карте: ровнять землю может кто
## угодно (квест, будущая постройка), и держать список здесь значило бы просить каждого
## отчитываться перед сейвом отдельно.
func _ground_edits() -> Array:
	var terr := _terrain()
	if terr != null and terr.has_method("ground_edits"):
		return terr.ground_edits()
	return []

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
		# КВЕСТОВЫЙ ПРЕДМЕТ НЕ ПРОПАДАЕТ ПО ТАЙМЕРУ. Он помечен (QuestProps.META), и метка
		# здесь и нужна: уборка мира про квесты ничего не знает, а десять минут — обычное
		# время дороги до цели. Груз, растаявший по пути, оставлял квест без цели навсегда.
		if c.has_meta("quest_id"):
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
## Новая игра начинается на ЗАВОДСКОЙ карте. Запечённый рельеф — это ямы и площадки прошлого
## прохождения, и оставлять их новому старту значит отдать игроку чужие постройки без построек.
##
## Файл удаляем, но высоты в ПАМЯТИ уже прочитаны — эта сессия доигрывает на них, а заводская
## карта вернётся со следующего запуска. Перечитывать 15 МБ и пересобирать все чанки посреди
## игры ради редкого случая (сейв удалён или испорчен) дороже, чем один раз доиграть.
func _fresh_start() -> void:
	var terr := _terrain()
	if terr != null and terr.has_method("reset_heights"):
		terr.reset_heights()
	var o := _objects()
	if o != null:
		for c in o.get_children():
			if _is_world_block(c):
				c.queue_free()                          # убрать предустановленные тест-блоки
	var primary = _primary_machine()
	if primary == null or not primary.has_method("award_block_list"):
		return
	# Базовый набор кружит вокруг игрока и осыпается в мир (reward_orbiter.gd) — подбирает сам.
	primary.award_block_list(G.STARTER_KIT)

# ── Сохранение / загрузка ─────────────────────────────────────────────────────
func _save_world() -> void:
	var machines: Array = []
	# ПЕРВОЙ пишем ту машину, которой игрок управляет: загрузка кладёт machines[0] на неё
	# (_load_world → _restore_machine(primary, ...)), а порядок детей в Vehicles ничего про
	# это не знает — база, оказавшаяся в списке раньше, приезжала бы игроку под управление.
	var ordered: Array = _player_machines()
	var prim = _primary_machine()
	if prim != null and ordered.has(prim):
		ordered.erase(prim)
		ordered.insert(0, prim)
	for m in ordered:
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
			# СТАЦИОНАРНАЯ БАЗА отличается от машины не раскладкой, а флагом: у неё нет
			# кабины и она всегда на якоре. Без него база возвращалась обычной машиной —
			# и сторож кабины сносил её через полсекунды после загрузки (см. _restore_machine).
			# == true, а не bool(): у машины без поля get() вернёт null, а bool(null) роняет вызов.
			"station": m.get("is_station") == true,
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
			var entry := {
				"block": G.block_key(int(c.get("block"))),
				"pos": [bp.x, bp.y, bp.z],
				"rot": [br.x, br.y, br.z],
				"age": age,
			}
			# Метку квеста сохраняем ВМЕСТЕ с блоком: без неё восстановленный груз становится
			# обычным мусором — его съедает уборка, а квест ищет цель, которой уже нет.
			if c.has_meta("quest_id"):
				entry["quest"] = String(c.get_meta("quest_id"))
			blocks.append(entry)
	var f := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify({
			"version": G.SAVE_FORMAT,
			"machines": machines,
			"world_blocks": blocks,
			# ПРАВКИ РЕЛЬЕФА (выровненные площадки). Саму карту высот не пишем — это мегабайты
			# чисел на каждое сохранение; правка же это четыре числа, и по ней земля
			# получается ровно такой же (см. map.flatten_area).
			"ground": _ground_edits(),
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
	var primary = _primary_machine()
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
	# РЕЛЬЕФ ПЕРВЫМ. Выровненные площадки надо повторить ДО того, как в мир вернутся машины:
	# база из квеста стоит на ровной земле, и восстановленная раньше правки она повисла бы в
	# воздухе (или утонула, если площадку срезали). Ждём высоты карты — по нулевым не выровнять.
	var terr0: Node = await _await_terrain(TERRAIN_WAIT_FRAMES)
	if terr0 != null and terr0.has_method("apply_ground_edits"):
		var edits: Array = data.get("ground", [])
		terr0.apply_ground_edits(edits)
		# И СРАЗУ ЗАПЕКАЕМ. Дамп карты высот — это её полный размер (15 МБ на нашей карте),
		# на ходу такая запись видна рывком, а здесь мы ещё под экраном загрузки, где игрок и
		# так ждёт. После запекания рельеф САМ такой, и повторять правки больше не нужно —
		# список внутри карты чистится, а те, что остались в сейве, отсекутся по номеру
		# запечённой правки (см. map.bake_heights).
		if not edits.is_empty() and terr0.has_method("bake_heights"):
			terr0.bake_heights()
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
		var p = wb.get("pos", [0, 0, 0])
		var r = wb.get("rot", [0, 0, 0])
		var b := _spawn_world_block(G.block_from_key(wb.get("block", 0)), Vector3(p[0], p[1], p[2]),
				Vector3(r[0], r[1], r[2]), float(wb.get("age", 0.0)))
		if b != null and String(wb.get("quest", "")) != "":
			b.set_meta("quest_id", String(wb["quest"]))   # снова квестовый, а не мусор

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

## СТАЦИОНАРНАЯ ли это структура. Основной путь — флаг из сейва, но у файлов, записанных до
## его появления, флага нет, и база в них уже лежит. Для них судим по РАСКЛАДКЕ: стационарное
## ядро есть, кабины нет. Ошибиться в другую сторону нельзя — у машины кабина есть всегда.
func _is_station_data(mdata: Dictionary) -> bool:
	if mdata.get("station", false) == true:
		return true
	var has_core := false
	for e in mdata.get("layout", []):
		if not (e is Dictionary):
			continue
		var bt: int = G.block_from_key(e.get("block", 0))
		if bt == G.Block.CABIN:
			return false
		if G.is_stationary(bt):
			has_core = true
	return has_core

func _restore_machine(veh, mdata: Dictionary) -> void:
	if not is_instance_valid(veh):
		return
	# СТАЦИОНАРНУЮ БАЗУ помечаем ДО раскладки. Она отличается от машины не блоками, а этим
	# флагом: кабины у базы нет, и без флага сторож кабины (vehicle_body_3d._cabin_watch)
	# принимал её за машину с выбитой кабиной — база рассыпалась в блоки через полсекунды
	# после каждой загрузки, а восстановление падало на уже освобождённом узле.
	var station: bool = _is_station_data(mdata)
	if station and "is_station" in veh:
		veh.is_station = true
	veh.apply_build(mdata.get("layout", []))
	if station and veh.get("block_map_node") != null and "is_station" in veh.block_map_node:
		veh.block_map_node.is_station = true
	var p = mdata.get("pos", null)
	var r = mdata.get("rot", null)
	if not (veh is Node3D):
		return
	# Рельеф ждём ДО заморозки и недолго. Раньше машину морозили и держали так до 600 кадров,
	# и если рельеф не успевал прочитать высоты, игрок десять секунд стоял неподвижным кирпичом.
	# Не дождались — ставим как в сейве: страховка _rescue_fallen крутится раз в секунду и
	# поднимет машину, если та окажется под землёй.
	var terr: Node = await _await_terrain(TERRAIN_WAIT_FRAMES)
	# Ждали до 120 кадров — за это время машины может уже не быть (погибла, снесена уборкой
	# лишних). Ссылка на освобождённый узел НЕ равна null, поэтому проверяем только
	# is_instance_valid: сравнение с null здесь молча пропускает мёртвый узел дальше.
	if not is_instance_valid(veh):
		return

	# Машина — RigidBody3D, и ПРЯМОЙ телепорт незамороженного тела физика откатывает, а под новой
	# точкой ещё нет стриминговой коллизии рельефа (её тайлы строятся вокруг тела уже ПОСЛЕ того,
	# как оно там окажется). Поэтому: замораживаем → ставим позицию НЕ НИЖЕ рельефа → ждём пару
	# кадров, пока построится коллизия → отпускаем.
	var rb := veh as RigidBody3D
	if rb != null:
		rb.freeze = true
		rb.linear_velocity = Vector3.ZERO
		rb.angular_velocity = Vector3.ZERO
	if r != null:
		veh.global_rotation = Vector3(r[0], r[1], r[2])
	if p != null:
		var pos := Vector3(p[0], p[1], p[2])
		if terr != null:
			pos.y = maxf(pos.y, terr.terrain_height_at(pos) + SAFE_CLEARANCE)
		else:
			# Высоту из сейва без проверки ставить НЕЛЬЗЯ: если она с прошлого бага под
			# землёй, машина стартует внутри мира и падает. Берём только X/Z, а высоту
			# оставляем спавновую — она заведомо над рельефом, и машина просто сядет.
			pos.y = maxf(veh.global_position.y, pos.y)
			push_warning("world_persist: рельеф не готов — беру из сейва только X/Z, "
					+ "высоту оставляю спавновую")
		veh.global_position = pos
	await get_tree().process_frame
	await get_tree().process_frame
	if not is_instance_valid(veh):
		return
	# БАЗУ не отпускаем: она стоит на якоре по определению, и разморозка означала бы, что
	# постройка поехала. _anchor_station сам вернёт заморозку, столб якоря и подписку на ядро.
	if station:
		if veh.has_method("_anchor_station"):
			veh._anchor_station()
		return
	if is_instance_valid(rb):
		rb.freeze = false

func _spawn_machine(mdata: Dictionary) -> void:
	var scene := load("res://player_vehicle.tscn") as PackedScene
	var vr := _vehicles_root()
	if scene == null or vr == null:
		return
	var v = scene.instantiate()
	vr.add_child(v)
	# Ждём готовности машины так же, как _ready ждёт основную: стартовые блоки доезжают
	# ОТЛОЖЕННО (blocks.spawn_block ждёт ready родителя), и раскладка из сейва, положенная
	# раньше, затиралась догоняющими корутинами.
	var guard: int = 0
	while guard < 600 and is_instance_valid(v) \
			and not (v.is_node_ready() and v.get("block_map_node") != null):
		await get_tree().process_frame
		guard += 1
	# После КАЖДОГО ожидания машина может быть уже освобождена — восстановление идёт кадрами,
	# а машина за это время успевает и погибнуть, и попасть под уборку. Освобождённая ссылка
	# не равна null (обращение к ней роняет вызов), поэтому проверка одна: is_instance_valid.
	if not is_instance_valid(v):
		return
	if v.has_method("apply_build"):
		await _restore_machine(v, mdata)
	if not is_instance_valid(v):
		return
	var cc = _camera()
	if cc != null and "vehicles" in cc and not cc.vehicles.has(v):
		cc.vehicles.append(v)
	if v.has_method("set_active"):
		v.set_active(false)
