extends Node3D
# Спавнит врагов вокруг игрока и держит их количество: враг погиб/исчез → через интервал
# появляется новый. Каждый берётся СЛУЧАЙНО из пула сцен, и ему задаётся случайная сборка
# (layout_preset у его blocks) — «машина из пула». Враги добавляются под узел Vehicles,
# чтобы карта дала им стриминговую коллизию (иначе провалятся сквозь рельеф вдали).

@export var enemy_scenes: Array[PackedScene]        # пул сцен врагов
@export var layout_presets: Array[int] = [0, 1, 2]  # пул сборок (см. blocks.gd)
@export var max_enemies: int = 9
@export var spawn_interval: float = 6.0             # пауза между появлениями
## Сколько врагов ставится СРАЗУ, как только мир готов (и обучение закончилось). Без этого
## мир начинался пустым и наполнялся по одному раз в spawn_interval — до первой стычки
## приходилось ждать и просто кататься. Ставятся по обычным правилам кольца, то есть
## разнесённые по разным сторонам, а не кучей.
@export var initial_enemies: int = 2

## Сколько врагов ОДНОВРЕМЕННО могут вести бой с игроком. Остальные патрулируют, пока место
## не освободится. Без этого потолка девять машин, заметив игрока, ехали на него все разом —
## и это не бой, а казнь: отбиться от толпы нечем, а разъехаться она не даёт.
@export var max_engaging: int = 2
## Кольцо спавна. Было 270–520: враг появлялся ЗА горизонтом восприятия (машина видит на 40,
## оружие бьёт на 60) — игрок не встречал его, а натыкался неизвестно где и неизвестно когда.
## Теперь чуть дальше видимости: враг приходит «из-за холма», а не из ниоткуда.
## Ближняя граница ОБЯЗАНА быть заметно больше радиуса обнаружения врага (85): иначе он
## рождается уже внутри своей зоны агрессии и бросается на игрока в ту же секунду, вместо
## того чтобы патрулировать, пока к нему не подъедут.
@export var spawn_min_dist: float = 150.0
@export var spawn_max_dist: float = 300.0
## Не появляться ПЕРЕД машиной ближе этого: игрок едет вперёд и не должен видеть, как враг
## возникает у него по курсу. Сзади и по бокам такого ограничения нет — там появление не видно.
@export var front_clear_dist: float = 240.0
@export_range(0.0, 180.0) var front_cone_deg: float = 55.0
@export var spawn_separation: float = 70.0          # не ближе этого к ДРУГИМ врагам
@export var min_height: float = 2.0                 # не на воде
@export var max_slope: float = 8.0                  # не на обрыве
@export var ground_offset: float = 3.0
## Враг дальше far_dist от текущей машины дольше far_limit секунд — телепортируется обратно
## в кольцо спавна возле игрока (не нашли точку — исчезает). Чтобы бой не «затухал», когда
## игрок уехал от разбежавшихся врагов.
@export var far_dist: float = 640.0                 # с запасом над spawn_max_dist, иначе дальние спавны сразу «далеко»
@export var far_limit: float = 60.0
@export var map_node: Node

## РЕДКОЕ СОБЫТИЕ «Проверка сектора» (лор цифровой симуляции): Система объявляет проверку
## квадрата вокруг игрока, даёт время сбежать, и если он не покинул квадрат — вызывает
## усиленный отряд врагов внутрь. Заглянул в квадрат — беги.
@export_group("Проверка сектора")
@export var scan_enabled: bool = true
@export var scan_min_interval: float = 180.0        # не чаще (сек) — событие редкое
@export var scan_max_interval: float = 420.0
@export var scan_half_size: float = 32.0            # полугабарит квадрата (4×4 чанка по 16 = 64)
@export var scan_warn_time: float = 12.0            # сколько секунд на побег
@export var scan_squad: int = 5                     # сколько врагов вызывает при провале
@export var scan_preset: int = 1                    # усиленная сборка (см. blocks.gd layout)

var _enemies: Array = []
var _clean_t: float = 0.0                           # троттл чистки списка от мёртвых врагов
var _far_time: Dictionary = {}                      # enemy -> сколько секунд он «далеко»
var _t: float = 0.0
var _ready_done: bool = false
var _seeded: bool = false          # стартовая партия врагов уже поставлена

var _scan_state: int = 0                            # 0 — покой, 1 — идёт предупреждение
var _scan_t: float = 0.0                            # до следующей проверки
var _scan_left: float = 0.0                         # осталось до зачистки
var _scan_center: Vector3 = Vector3.ZERO
var _scan_marker: Node3D = null

func _ready() -> void:
	# Ждём загрузку рельефа (map грузит md после своего await).
	var guard: int = 0
	var map: Node = _find_map()
	while (map == null or not map.has_method("get_dims") or map.get_dims().x <= 0) and guard < 300:
		await get_tree().process_frame
		map = _find_map()
		guard += 1
	_ready_done = map != null and map.has_method("get_dims") and map.get_dims().x > 0
	_scan_t = randf_range(scan_min_interval, scan_max_interval)

func _process(delta: float) -> void:
	if not _ready_done:
		return
	# Чистка списка — раз в 0.5с, а не каждый кадр: .filter() создавал новую Callable + новый
	# Array и звал is_instance_valid на всех врагах 60 раз в секунду ради события, которое
	# случается редко (смерть врага). На счёт лимита это не влияет — проверка ниже переживёт
	# полсекунды с мёртвой записью.
	_clean_t -= delta
	if _clean_t <= 0.0:
		_clean_t = 0.5
		_enemies = _enemies.filter(func(e): return is_instance_valid(e))
	_track_far(delta)
	_limit_engagement()
	_scan_tick(delta)                               # редкое событие «проверка сектора»
	if _enemies.size() >= max_enemies:
		return
	# Первый заход: наполняем мир сразу, а не по одному с паузой.
	if not _seeded and not _tutorial_active():
		_seeded = true
		for _i in mini(initial_enemies, max_enemies):
			_spawn_one()
		_t = spawn_interval
		return
	_t -= delta
	if _t > 0.0:
		return
	_t = spawn_interval
	_spawn_one()

# Кто СЕЙЧАС имеет право драться. Право получают ближайшие к игроку max_engaging врагов из
# тех, кто его уже заметил; остальным бой запрещён, и они возвращаются к патрулю.
#
# Считаем по РАССТОЯНИЮ, а не по очереди «кто первый заметил»: иначе право оставалось бы у
# врага, который уже уехал за холм, а тот, что дышит игроку в затылок, стоял бы и ждал.
func _limit_engagement() -> void:
	var player: Node3D = _player()
	if player == null:
		return
	var seekers: Array = []
	for e in _enemies:
		if not is_instance_valid(e) or not e.has_method("set_combat_allowed"):
			continue
		if e.get("_target") != null:
			seekers.append(e)
		else:
			e.set_combat_allowed(true)         # цели нет — ограничивать нечего
	seekers.sort_custom(func(a, b):
		return player.global_position.distance_squared_to(a.global_position) \
				< player.global_position.distance_squared_to(b.global_position))
	for i in seekers.size():
		seekers[i].set_combat_allowed(i < max_engaging)

# Далёкие враги: кто дальше far_dist от текущей машины дольше far_limit — телепортируется
# обратно в кольцо возле игрока (нет точки — исчезает). Так стычка не «уезжает» от игрока.
func _track_far(delta: float) -> void:
	for k in _far_time.keys():
		if not is_instance_valid(k):
			_far_time.erase(k)
	var player: Node3D = _player()
	if player == null:
		return
	var map: Node = _find_map()
	for e in _enemies:
		if not is_instance_valid(e):
			continue
		if player.global_position.distance_to(e.global_position) > far_dist:
			_far_time[e] = _far_time.get(e, 0.0) + delta
			if _far_time[e] >= far_limit:
				_far_time.erase(e)
				_relocate_enemy(e, map, player)
		else:
			_far_time.erase(e)

func _relocate_enemy(enemy: Node3D, map: Node, player: Node3D) -> void:
	if map == null:
		enemy.queue_free()
		return
	var pos = _find_spawn_pos(map, player.global_position, enemy)
	if pos == null:
		enemy.queue_free()          # некуда переместить — просто исчезает
		return
	if enemy is RigidBody3D:
		enemy.linear_velocity = Vector3.ZERO
		enemy.angular_velocity = Vector3.ZERO
	enemy.global_position = pos

func _spawn_one() -> void:
	if enemy_scenes.is_empty() or _tutorial_active():
		return
	var map: Node = _find_map()
	var player: Node3D = _player()
	if map == null or player == null:
		return
	var pos = _find_spawn_pos(map, player.global_position)
	if pos == null:
		return

	var enemy: Node3D = enemy_scenes.pick_random().instantiate()
	# Сборка из пула — ставим ДО add_child (blocks строит машину в своём _ready).
	var blocks := enemy.get_node_or_null("blocks")
	if blocks and "layout_preset" in blocks and not layout_presets.is_empty():
		blocks.layout_preset = layout_presets.pick_random()

	var vehicles: Node = _vehicles_root()
	if vehicles == null:
		return
	vehicles.add_child(enemy)
	enemy.global_position = pos
	if enemy.has_signal("died") and not enemy.died.is_connected(_on_enemy_died):
		enemy.died.connect(_on_enemy_died)
	_enemies.append(enemy)

## Разведчик РЯДОМ с игроком — сюжетный спавн после обучения. Обычный поток врагов держит
## дистанцию spawn_min_dist (270 м), чтобы не наваливаться; здесь наоборот нужно, чтобы
## игрок его сразу увидел, поэтому кольцо своё и слабая сборка (preset 0).
## Возвращает врага или null, если рядом не нашлось ровного места.
func spawn_scout_near_player(min_d: float = 20.0, max_d: float = 40.0) -> Node3D:
	if enemy_scenes.is_empty():
		return null
	var map: Node = _find_map()
	var player: Node3D = _player()
	var vehicles: Node = _vehicles_root()
	if map == null or player == null or vehicles == null:
		return null
	var center: Vector3 = player.global_position
	var pos = null
	var base: float = randf() * TAU
	for i in 24:
		var ang: float = base + TAU * float(i) / 24.0
		var dist: float = randf_range(min_d, max_d)
		var world := center + Vector3(cos(ang) * dist, 0.0, sin(ang) * dist)
		var h: float = map.terrain_height_at(world)
		if h < min_height or _slope_at(map, world) > max_slope:
			continue
		pos = Vector3(world.x, h + ground_offset, world.z)
		break
	if pos == null:
		return null
	var enemy: Node3D = enemy_scenes.pick_random().instantiate()
	var blocks := enemy.get_node_or_null("blocks")
	if blocks and "layout_preset" in blocks:
		blocks.layout_preset = 0            # базовая сборка: первый бой должен быть посильным
	vehicles.add_child(enemy)
	enemy.global_position = pos
	if enemy.has_signal("died") and not enemy.died.is_connected(_on_enemy_died):
		enemy.died.connect(_on_enemy_died)
	_enemies.append(enemy)
	return enemy

# Пока обучение не закончено, случайный поток врагов и проверки сектора молчат: игрока
# ведут за руку, и рейдер посреди вводной только мешает. Первого врага приводит сюжет
# (tutorial_director после закрытия последнего шага) — он спавнится в обход этого гейта.
func _tutorial_active() -> bool:
	var q: Node = get_node_or_null("/root/Q")
	return q != null and q.has_method("tutorial_active") and q.tutorial_active()

func _on_enemy_died(_enemy: Node) -> void:
	pass    # _process сам подчистит список по is_instance_valid и дозаспавнит

# Точка спавна: кольцо вокруг игрока, на рельефе, не вода/не обрыв, и НЕ вплотную к другим
# врагам (чтобы не кучковались). Угол берём с шагом-«секторами» + джиттер: даже под нагрузкой
# точки расходятся по кольцу, а не бьют в одно место. exclude — враг, которого не считаем
# соседом (при телепорте его самого). Возвращает Vector3 или null.
# Точка спавна в кольце вокруг игрока.
#
# Кольцо поделено на секторы, и новый враг идёт в ТОТ, ГДЕ ИХ СЕЙЧАС МЕНЬШЕ ВСЕГО, —
# равномерность получается по построению, а не как побочный эффект.
#
# Так пришлось делать в два захода. Сначала брался первый подходящий кандидат из 36 по
# кругу: когда часть кольца отбракована водой или обрывом (а это почти всегда), все спавны
# подряд сваливались в один уцелевший сектор. Потом выбиралось направление, максимально
# удалённое по углу от живых врагов, — уже лучше, но это ЖАДНЫЙ выбор: он отталкивается
# только от текущей расстановки и на неудачном рельефе всё равно перекашивал кольцо в одну
# сторону. Счётчик по секторам этим не страдает: занятый сектор не выберут, пока есть пустые.
const SPAWN_SECTORS := 8

func _find_spawn_pos(map: Node, center: Vector3, exclude: Node = null):
	# Сколько врагов уже стоит в каждом секторе.
	var per: Array[int] = []
	per.resize(SPAWN_SECTORS)
	per.fill(0)
	for e in _enemies:
		if e == exclude or not is_instance_valid(e):
			continue
		var d: Vector3 = (e as Node3D).global_position - center
		if Vector2(d.x, d.z).length() < 0.5:
			continue
		per[_sector_of(atan2(d.z, d.x))] += 1
	# Секторы по возрастанию занятости; равные — вперемешку, иначе пустая карта всегда
	# заполнялась бы с одного и того же боку.
	var order: Array[int] = []
	for i in SPAWN_SECTORS:
		order.append(i)
	order.shuffle()
	order.sort_custom(func(a, b): return per[a] < per[b])
	# Внутри сектора — несколько попыток: рельеф может не пустить в конкретную точку.
	for sec in order:
		for _try in 6:
			var ang: float = (TAU / SPAWN_SECTORS) * (float(sec) + randf())
			var dist: float = randf_range(spawn_min_dist, spawn_max_dist)
			var world := center + Vector3(cos(ang) * dist, 0.0, sin(ang) * dist)
			var h: float = map.terrain_height_at(world)
			if h < min_height:
				continue
			if _slope_at(map, world) > max_slope:
				continue
			var cand := Vector3(world.x, h + ground_offset, world.z)
			if _too_close_to_enemy(cand, exclude):
				continue
			if _in_player_view(cand, center):
				continue                       # по курсу и близко — игрок увидел бы появление
			return cand
	return null

# Точка «по курсу» игрока и достаточно близко, чтобы появление было ЗАМЕТНО. Смотрим на
# направление машины, а не камеры: камеру игрок крутит постоянно, и по ней спавн стал бы
# случайным, а перед носом машины — то место, куда он едет и куда смотрит чаще всего.
func _in_player_view(pos: Vector3, center: Vector3) -> bool:
	var player: Node3D = _player()
	if player == null:
		return false
	var to: Vector3 = pos - center
	to.y = 0.0
	if to.length() > front_clear_dist:
		return false                           # далеко — пусть появляется хоть прямо по курсу
	var fwd: Vector3 = -player.global_transform.basis.z
	fwd.y = 0.0
	if fwd.length() < 0.01 or to.length() < 0.01:
		return false
	return rad_to_deg(fwd.normalized().angle_to(to.normalized())) < front_cone_deg

func _sector_of(ang: float) -> int:
	return int(wrapf(ang, 0.0, TAU) / (TAU / SPAWN_SECTORS)) % SPAWN_SECTORS

# Есть ли уже враг ближе spawn_separation (по горизонтали) к точке pos.
func _too_close_to_enemy(pos: Vector3, exclude: Node) -> bool:
	for e in _enemies:
		if e == exclude or not is_instance_valid(e):
			continue
		var d := Vector2(pos.x - e.global_position.x, pos.z - e.global_position.z)
		if d.length() < spawn_separation:
			return true
	return false

func _slope_at(map: Node, world: Vector3) -> float:
	var s: float = 3.0
	var hx1: float = map.terrain_height_at(world + Vector3(s, 0, 0))
	var hx2: float = map.terrain_height_at(world + Vector3(-s, 0, 0))
	var hz1: float = map.terrain_height_at(world + Vector3(0, 0, s))
	var hz2: float = map.terrain_height_at(world + Vector3(0, 0, -s))
	return maxf(maxf(hx1, hx2), maxf(hz1, hz2)) - minf(minf(hx1, hx2), minf(hz1, hz2))

func _find_map() -> Node:
	if map_node:
		return map_node
	var m: Node = get_node_or_null("../map")
	if m == null:
		m = get_node_or_null("/root/Main/map")
	return m

func _vehicles_root() -> Node:
	var v: Node = get_node_or_null("../Vehicles")
	if v == null:
		v = get_node_or_null("/root/Main/Vehicles")
	return v

func _player() -> Node3D:
	var cc: Node = get_tree().get_first_node_in_group("camera_controller")
	if cc and "current_vehicle" in cc and is_instance_valid(cc.current_vehicle):
		return cc.current_vehicle
	return null

# ── Проверка сектора (редкое событие) ─────────────────────────────────────────
func _scan_tick(delta: float) -> void:
	if not scan_enabled:
		return
	if _scan_state == 0:
		_scan_t -= delta
		if _scan_t <= 0.0:
			_start_scan()
	else:
		_scan_left -= delta
		_pulse_marker()
		if _scan_left <= 0.0:
			_resolve_scan()

func _start_scan() -> void:
	var p := _player()
	if p == null:
		_scan_t = 30.0                              # игрока нет — попробуем позже
		return
	_scan_center = p.global_position
	_scan_state = 1
	_scan_left = scan_warn_time
	_build_marker()
	# Обманка: Система ВЕЖЛИВО просит НЕ выходить — кто послушается, того зачистка :)
	_say("System", "🔍 Scheduled sector scan. Please do NOT leave the scan zone. This will take %d sec. Thank you for your cooperation." % int(scan_warn_time))

func _resolve_scan() -> void:
	_scan_state = 0
	_scan_t = randf_range(scan_min_interval, scan_max_interval)
	_clear_marker()
	var p := _player()
	# Система не отслеживает «кто ушёл» — она просто сканирует зону. Есть активность внутри
	# (техника игрока) → «что-то подозрительное» → усиленный отряд. Пусто → нейтральный отчёт.
	if p != null and _in_scan_box(p.global_position):
		_say("System", "⚠ Unauthorized activity detected in the sector. Dispatching handlers.")
		_spawn_enforcement(p)          # отряд идёт именно за ЗАСЕЧЁННОЙ машиной
	else:
		_say("System", "Sector scan complete. No anomalies detected.")

func _in_scan_box(pos: Vector3) -> bool:
	return absf(pos.x - _scan_center.x) <= scan_half_size and absf(pos.z - _scan_center.z) <= scan_half_size

# Усиленный отряд внутрь квадрата (кольцом у края, на рельефе, агрессивно близко).
func _spawn_enforcement(locked: Node3D = null) -> void:
	var map: Node = _find_map()
	var vehicles: Node = _vehicles_root()
	if map == null or vehicles == null or enemy_scenes.is_empty():
		return
	for i in scan_squad:
		var enemy: Node3D = enemy_scenes.pick_random().instantiate()
		var blocks := enemy.get_node_or_null("blocks")
		if blocks and "layout_preset" in blocks:
			blocks.layout_preset = scan_preset      # усиленная сборка
		vehicles.add_child(enemy)
		var ang: float = TAU * float(i) / float(maxi(scan_squad, 1))
		var r: float = scan_half_size * 0.8
		var wp: Vector3 = _scan_center + Vector3(cos(ang) * r, 0.0, sin(ang) * r)
		var h: float = map.terrain_height_at(wp) if map.has_method("terrain_height_at") else wp.y
		enemy.global_position = Vector3(wp.x, h + ground_offset, wp.z)
		if enemy.has_signal("died") and not enemy.died.is_connected(_on_enemy_died):
			enemy.died.connect(_on_enemy_died)
		# Отряд по итогам ПРОВЕРКИ СЕКТОРА идёт именно за той машиной, которую засекли: цель
		# назначаем сразу при спавне и включаем relentless — они её уже не забудут и не
		# переключатся на другую (обычные враги ищут цель сами и цель могут терять).
		_lock_on_target(enemy, locked)
		_enemies.append(enemy)

# Жёстко назначить врагу цель (без ожидания сигнала зоны обнаружения) и сделать его невідступным.
func _lock_on_target(enemy: Node, target: Node3D) -> void:
	if target == null or not is_instance_valid(target):
		return
	if enemy.has_method("assign_target"):
		enemy.assign_target(target, true)

# Маркер квадрата: 4 светящихся столба по углам (переживают неровный рельеф). Пульсируют,
# к концу таймера краснеют — тревога.
func _build_marker() -> void:
	_clear_marker()
	_scan_marker = Node3D.new()
	get_tree().current_scene.add_child(_scan_marker)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(0.2, 0.9, 1.0)
	mat.emission_enabled = true
	mat.emission = Color(0.2, 0.9, 1.0)
	var map: Node = _find_map()
	for sx in [-1.0, 1.0]:
		for sz in [-1.0, 1.0]:
			var pillar := MeshInstance3D.new()
			var bm := BoxMesh.new()
			bm.size = Vector3(1.4, 60.0, 1.4)
			pillar.mesh = bm
			pillar.material_override = mat
			pillar.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			var wx: float = _scan_center.x + sx * scan_half_size
			var wz: float = _scan_center.z + sz * scan_half_size
			var h: float = map.terrain_height_at(Vector3(wx, 0.0, wz)) if (map and map.has_method("terrain_height_at")) else _scan_center.y
			pillar.position = Vector3(wx, h + 28.0, wz)
			_scan_marker.add_child(pillar)
	_scan_marker.set_meta("mat", mat)

func _pulse_marker() -> void:
	if _scan_marker == null or not _scan_marker.has_meta("mat"):
		return
	var mat: StandardMaterial3D = _scan_marker.get_meta("mat")
	var t: float = 0.5 + 0.5 * sin(Time.get_ticks_msec() * 0.008)
	var danger: float = 1.0 - clampf(_scan_left / maxf(scan_warn_time, 0.01), 0.0, 1.0)
	mat.emission = Color(0.2 + danger * 0.8, 0.9 - danger * 0.7, 1.0 - danger * 0.85)
	mat.emission_energy_multiplier = 1.0 + t * 2.0 + danger * 3.0

func _clear_marker() -> void:
	if _scan_marker != null and is_instance_valid(_scan_marker):
		_scan_marker.queue_free()
	_scan_marker = null

func _say(speaker: String, text: String) -> void:
	var d: Node = get_node_or_null("/root/Dialogue")
	if d and d.has_method("say"):
		d.say(speaker, text)
