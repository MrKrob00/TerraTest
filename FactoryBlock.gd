# factory_block.gd
class_name FactoryBlock
extends VehicleBlock

signal slot_freed

var current_item: Node3D = null
var next_block: FactoryBlock = null
var waiting_for_next: bool = false

func _ready() -> void:
	await get_tree().process_frame
	super._ready()

func _find_next_block() -> void:
	var blocks_node = get_parent()
	var owner_node = blocks_node.get_parent()
	if not owner_node.has_node("blocks"):
		push_warning("FactoryBlock: не найден node 'blocks'")
		return
	var block_map = owner_node.get_node("blocks")
	var forward
	if block == G.Block.PROCESSOR or \
		block == G.Block.SELLER:
		forward = Vector3(0, 0, -2)
	else: 
		if rotation.y == 0.0: forward= Vector3(0,0,-1)
		elif rotation.y == PI*2.0: forward = Vector3(0,0,1)
		else: forward = Vector3(sign(rotation.y),0,0)*-1
	
	var my_local = round(position)
	var neighbor_local = my_local + forward

	# find_block резолвит клетку через cell_owner: у 2×2-блоков (продавец/процессор) в
	# node_map записан только ЯКОРЬ, и прямой node_map.get по соседней клетке их «не видел»
	# — цепочка не находила блок продажи, если упиралась в его не-якорную клетку.
	var nx: int = int(neighbor_local.x) + 5
	var ny: int = int(neighbor_local.y)
	var nz: int = int(neighbor_local.z) + 5
	var neighbor = null
	if block_map.has_method("find_block"):
		neighbor = block_map.find_block(nx, ny, nz)
	else:
		neighbor = block_map.node_map.get("%d,%d,%d" % [nx, ny, nz], null)
	if neighbor and neighbor.has_method("try_receive"):
		next_block = neighbor

func try_receive(item: Node3D) -> bool:
	if current_item != null:
		return false
	if not is_instance_valid(item):
		return false
	current_item = item
	if item is RigidBody3D:
		item.freeze = true
	# Запоминаем мировую позицию ДО reparent
	var world_pos = item.global_position
	item.reparent(self, true)
	# Восстанавливаем мировую позицию ПОСЛЕ reparent
	item.global_position = world_pos
	# Анимируем к item_slot
	var target = Vector3.ZERO
	if has_node("item_slot"):
		target = to_local(global_position) + $item_slot.position
		target = $item_slot.position
	var tween = create_tween()
	tween.tween_property(item, "position", target, 0.3)
	tween.finished.connect(func(): _on_item_received(), CONNECT_ONE_SHOT)
	return true

func _on_item_received() -> void:
	pass

func _try_push() -> void:
	if current_item == null or not is_instance_valid(current_item):
		current_item = null
		return
	if next_block == null:
		return
	if next_block.try_receive(current_item):
		current_item = null
		waiting_for_next = false
		slot_freed.emit()
	else:
		if not waiting_for_next:
			waiting_for_next = true
			next_block.slot_freed.connect(_on_next_block_freed, CONNECT_ONE_SHOT)

func _on_next_block_freed() -> void:
	waiting_for_next = false
	_try_push()
