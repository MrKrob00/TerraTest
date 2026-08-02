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
	var forward: Vector3
	if block == G.Block.PROCESSOR or \
		block == G.Block.SELLER:
		forward = Vector3(0, 0, -2)
	else: 
		if rotation.y == 0.0: forward= Vector3(0,0,-1)
		elif rotation.y == PI*2.0: forward = Vector3(0,0,1)
		else: forward = Vector3(sign(rotation.y),0,0)*-1
	
	var my_local: Vector3 = round(position)
	var neighbor_local: Vector3 = my_local + forward

	# НАМЕРЕННО прямой node_map (только якорная клетка). 2×2-блок (продавец/процессор)
	# принимает ресурс только в ОДНУ клетку — якорную, то есть вкинуть в него можно лишь
	# с её двух открытых сторон. Смотрим в не-якорную клетку — соединения нет, это дизайн.
	# Локальная позиция клетки = (x-5, y-5, z-5) от ядра (сетка 11³, центр 5 — см. blocks.gd),
	# поэтому обратно в grid-ключ node_map прибавляем 5 по ВСЕМ осям (раньше Y был снизу, без +5).
	var key: String = "%d,%d,%d" % [
		int(neighbor_local.x) + 5,
		int(neighbor_local.y) + 5,
		int(neighbor_local.z) + 5
	]
	var neighbor = block_map.node_map.get(key, null)
	if neighbor and neighbor.has_method("try_receive"):
		next_block = neighbor

# Фабрика работает ТОЛЬКО под якорем: машина должна стоять заякоренной. Исключение —
# коллектор (он не в этой цепочке): подбирает с земли всегда, а вот передача дальше
# (intake забирает у него и пушит по цепочке) уже гейтится этим условием.
func _factory_active() -> bool:
	var p := get_parent()
	if p == null or p.name != "blocks":
		return false                      # блок валяется в мире — фабрика не работает
	var vehicle := p.get_parent()
	return vehicle != null and bool(vehicle.get("anchored"))

func try_receive(item: Node3D) -> bool:
	if not _factory_active():
		return false                      # без якоря цепочка стоит
	if current_item != null:
		return false
	if not is_instance_valid(item):
		return false
	current_item = item
	if item is RigidBody3D:
		item.freeze = true
	# Запоминаем мировую позицию ДО reparent
	var world_pos: Vector3 = item.global_position
	item.reparent(self, true)
	# Восстанавливаем мировую позицию ПОСЛЕ reparent
	item.global_position = world_pos
	# Анимируем к item_slot
	var target: Vector3 = Vector3.ZERO
	if has_node("item_slot"):
		target = to_local(global_position) + $item_slot.position
		target = $item_slot.position
	var tween: Tween = create_tween()
	tween.tween_property(item, "position", target, 0.3)
	tween.finished.connect(func(): _on_item_received(), CONNECT_ONE_SHOT)
	return true

func _on_item_received() -> void:
	pass

func _try_push() -> void:
	if not _factory_active():
		return                            # без якоря дальше не передаём
	if current_item == null or not is_instance_valid(current_item):
		current_item = null
		return
	if next_block == null or not is_instance_valid(next_block):
		next_block = null                 # следующий блок исчез (разрушен/снят) — не течём в мёртвую ссылку
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
