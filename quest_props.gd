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

## id квеста → узел положенного блока. Пусто, если предмет уже подобран или уничтожен.
var _props: Dictionary = {}

func _ready() -> void:
	add_to_group("quest_props")      # компас находит нас через группу, а не по пути

## Где положить: не под колёсами и не за горизонтом. Ближе — игрок наступит на предмет
## случайно и не поймёт, что это была цель; дальше — поедет искать по компасу, что и нужно.
const DROP_MIN := 60.0
const DROP_MAX := 130.0

# Положить блок в мир по кругу вокруг игрока. Возвращает узел (или null, если не вышло).
func drop_for(quest_id: String, block_type: int) -> Node3D:
	var scene: PackedScene = G.get_scene(block_type)
	var objects: Node = get_node_or_null("/root/Main/objects")
	var player: Node3D = _player()
	if scene == null or objects == null or player == null:
		return null
	var pos: Vector3 = _ground_spot(player.global_position)
	var node: Node3D = scene.instantiate()
	objects.add_child(node)
	node.global_position = pos
	# Блок в мире — свободное тело: он лежит, его можно подобрать. Замороженным он бы висел.
	if node is RigidBody3D:
		(node as RigidBody3D).freeze = false
	BlockFX.play(node, false)              # «глюк появления» — предмет возник, а не лежал всегда
	_props[quest_id] = node
	return node

# Куда ведёт компас по этому квесту. null — предмета нет (подобрали/уничтожен/не клали).
func position_for(quest_id: String) -> Variant:
	var n = _props.get(quest_id)
	if n == null or not is_instance_valid(n):
		_props.erase(quest_id)
		return null
	# Подобрали — узел уезжает из objects (в руку, потом на машину). Цель достигнута,
	# вести к ней больше некуда.
	if (n as Node3D).get_parent() == null or (n as Node3D).get_parent().name != "objects":
		return null
	return (n as Node3D).global_position

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
