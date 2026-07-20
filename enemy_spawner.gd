extends Node3D
# Спавнит врагов вокруг игрока и держит их количество: враг погиб/исчез → через интервал
# появляется новый. Каждый берётся СЛУЧАЙНО из пула сцен, и ему задаётся случайная сборка
# (layout_preset у его blocks) — «машина из пула». Враги добавляются под узел Vehicles,
# чтобы карта дала им стриминговую коллизию (иначе провалятся сквозь рельеф вдали).

@export var enemy_scenes: Array[PackedScene]        # пул сцен врагов
@export var layout_presets: Array[int] = [0, 1, 2]  # пул сборок (см. blocks.gd)
@export var max_enemies: int = 9                    # было 3, ×3
@export var spawn_interval: float = 6.0             # пауза между появлениями
@export var spawn_min_dist: float = 120.0           # не ближе к игроку
@export var spawn_max_dist: float = 260.0           # не дальше (карта 1982² — простора много; < render 1400, виден при спавне)
@export var spawn_separation: float = 80.0          # не ближе этого к ДРУГИМ врагам (сильно разнесены, не кучкуются)
@export var min_height: float = 2.0                 # не на воде
@export var max_slope: float = 8.0                  # не на обрыве
@export var ground_offset: float = 3.0
## Враг дальше far_dist от текущей машины дольше far_limit секунд — телепортируется обратно
## в кольцо спавна возле игрока (не нашли точку — исчезает). Чтобы бой не «затухал», когда
## игрок уехал от разбежавшихся врагов.
@export var far_dist: float = 340.0                 # с запасом над spawn_max_dist, иначе дальние спавны сразу «далеко»
@export var far_limit: float = 60.0
@export var map_node: Node

var _enemies: Array = []
var _far_time: Dictionary = {}                      # enemy -> сколько секунд он «далеко»
var _t: float = 0.0
var _ready_done: bool = false

func _ready() -> void:
	# Ждём загрузку рельефа (map грузит md после своего await).
	var guard: int = 0
	var map: Node = _find_map()
	while (map == null or not map.has_method("get_dims") or map.get_dims().x <= 0) and guard < 300:
		await get_tree().process_frame
		map = _find_map()
		guard += 1
	_ready_done = map != null and map.has_method("get_dims") and map.get_dims().x > 0

func _process(delta: float) -> void:
	if not _ready_done:
		return
	_enemies = _enemies.filter(func(e): return is_instance_valid(e))
	_track_far(delta)
	if _enemies.size() >= max_enemies:
		return
	_t -= delta
	if _t > 0.0:
		return
	_t = spawn_interval
	_spawn_one()

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
	if enemy_scenes.is_empty():
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

func _on_enemy_died(_enemy: Node) -> void:
	pass    # _process сам подчистит список по is_instance_valid и дозаспавнит

# Точка спавна: кольцо вокруг игрока, на рельефе, не вода/не обрыв, и НЕ вплотную к другим
# врагам (чтобы не кучковались). Угол берём с шагом-«секторами» + джиттер: даже под нагрузкой
# точки расходятся по кольцу, а не бьют в одно место. exclude — враг, которого не считаем
# соседом (при телепорте его самого). Возвращает Vector3 или null.
func _find_spawn_pos(map: Node, center: Vector3, exclude: Node = null):
	var base: float = randf() * TAU
	for i in 36:
		var ang: float = base + TAU * float(i) / 36.0 + randf_range(-0.13, 0.13)
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
		return cand
	return null

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
