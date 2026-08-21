class_name QuestProps
extends Node
# Предметы, которые кладёт в мир СЮЖЕТ: «в мире появилась солнечная панель — найдите её».
#
# Блок ставится настоящий, тот же, что игрок носит в руке, — его можно подобрать и поставить
# на машину обычным способом, никакой отдельной «квестовой» сущности нет. Мы лишь помним,
# ГДЕ он лежит, чтобы компас вёл игрока именно к нему, а не к абстрактному «ближайшему».
#
# Живёт в дереве под наставником (tutorial_director), а не автолоадом: предметы принадлежат
# конкретному миру и должны исчезать вместе с ним.

## id квеста → СПИСОК положенных узлов. Именно список, а не один узел: у стадии бывает
## несколько предметов («панель и опора»), и раньше второй клали под ключом «id+», который
## компас не спрашивал НИКОГДА. Он падал в случайной точке круга — в другой стороне от
## первого, без метки, — и для игрока это выглядело так, что второй предмет вообще не выдали.
var _props: Dictionary = {}

func _ready() -> void:
	add_to_group("quest_props")      # компас находит нас через группу, а не по пути

## Где положить: не под колёсами и не за горизонтом. Ближе — игрок наступит на предмет
## случайно и не поймёт, что это была цель; дальше — поедет искать по компасу, что и нужно.
const DROP_MIN := 60.0
const DROP_MAX := 130.0

## Насколько разносим предметы ОДНОЙ стадии. Рядом, но не в одну кучу: нашёл один — видишь
## второй, и не надо второй раз ехать через полкарты по компасу.
const SIBLING_SPREAD := 4.0

## Положить блок РЯДОМ С ЗАДАННОЙ ТОЧКОЙ, а не по кругу вокруг игрока. Нужно квестам, где
## место уже определено сюжетом (сбитый груз): ронять награду в случайную сторону от игрока
## значило бы отправить его искать во второй раз то, за чем он только что приехал.
func drop_near(quest_id: String, block_type: int, at: Variant) -> Node3D:
	if not (at is Vector3):
		return drop_for(quest_id, block_type)
	var scene: PackedScene = G.get_scene(block_type)
	var objects: Node = get_node_or_null("/root/Main/objects")
	if scene == null or objects == null:
		return null
	var pos: Vector3 = (at as Vector3) + Vector3(randf_range(-3.0, 3.0), 1.2, randf_range(-3.0, 3.0))
	var node: Node3D = scene.instantiate()
	objects.add_child(node)
	node.global_position = pos
	if node is RigidBody3D:
		(node as RigidBody3D).freeze = false
	BlockFX.play(node, false)
	if not _props.has(quest_id):
		_props[quest_id] = []
	(_props[quest_id] as Array).append(node)
	return node

# Положить блок в мир по кругу вокруг игрока. Возвращает узел (или null, если не вышло).
func drop_for(quest_id: String, block_type: int) -> Node3D:
	var scene: PackedScene = G.get_scene(block_type)
	var objects: Node = get_node_or_null("/root/Main/objects")
	var player: Node3D = _player()
	if scene == null or objects == null or player == null:
		return null
	# Второй и следующие предметы той же стадии кладём ВОЗЛЕ первого, а не в новую случайную
	# точку круга: иначе игрок находит один и не догадывается, что где-то лежит второй.
	var first: Node3D = _first_loose(quest_id)
	var pos: Vector3 = _ground_spot(player.global_position)
	if first != null:
		pos = first.global_position + Vector3(randf_range(-SIBLING_SPREAD, SIBLING_SPREAD),
				0.0, randf_range(-SIBLING_SPREAD, SIBLING_SPREAD))
		var map: Node = get_node_or_null("/root/Main/map")
		if map != null and map.has_method("terrain_height_at"):
			pos.y = map.terrain_height_at(pos) + 1.2
	var node: Node3D = scene.instantiate()
	objects.add_child(node)
	node.global_position = pos
	# Блок в мире — свободное тело: он лежит, его можно подобрать. Замороженным он бы висел.
	if node is RigidBody3D:
		(node as RigidBody3D).freeze = false
	BlockFX.play(node, false)              # «глюк появления» — предмет возник, а не лежал всегда
	if not _props.has(quest_id):
		_props[quest_id] = []
	(_props[quest_id] as Array).append(node)
	return node

# Куда ведёт компас по этому квесту: к БЛИЖАЙШЕМУ ещё не подобранному предмету стадии.
# null — подбирать больше нечего.
func position_for(quest_id: String) -> Variant:
	var n: Node3D = _first_loose(quest_id)
	return n.global_position if n != null else null

## Ближайший к игроку предмет стадии, который ВСЁ ЕЩЁ лежит в мире. Подобранный узел уезжает
## из objects (в руку, потом на машину) — по родителю это и видно.
func _first_loose(quest_id: String) -> Node3D:
	var list = _props.get(quest_id)
	if not (list is Array):
		return null
	var from: Node3D = _player()
	var best: Node3D = null
	var best_d2: float = INF
	var alive: Array = []
	for n in list:
		if n == null or not is_instance_valid(n):
			continue
		alive.append(n)
		var p: Node = (n as Node3D).get_parent()
		if p == null or p.name != "objects":
			continue                       # уже подобрали
		var d2: float = 0.0 if from == null else from.global_position.distance_squared_to((n as Node3D).global_position)
		if d2 < best_d2:
			best_d2 = d2
			best = n as Node3D
	_props[quest_id] = alive
	return best

func _ground_spot(center: Vector3) -> Vector3:
	var map: Node = get_node_or_null("/root/Main/map")
	var ang: float = randf() * TAU
	var dist: float = randf_range(DROP_MIN, DROP_MAX)
	var p: Vector3 = center + Vector3(cos(ang) * dist, 0.0, sin(ang) * dist)
	if map != null and map.has_method("terrain_height_at"):
		p.y = map.terrain_height_at(p) + 1.2
	else:
		p.y = center.y + 1.2
	return p

func _player() -> Node3D:
	var cc: Node = get_tree().get_first_node_in_group("camera_controller")
	if cc != null and "current_vehicle" in cc and cc.current_vehicle != null:
		return cc.current_vehicle as Node3D
	return null
