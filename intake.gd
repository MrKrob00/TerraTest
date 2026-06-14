# intake.gd
extends FactoryBlock

@export var take_interval: float = 1.0
@export var capacity: int = 4

var vehicles_in_zone: Array = []
var inventory: Array = []
var timer: Timer

func _ready() -> void:
	super._ready()
	timer = Timer.new()
	timer.wait_time = take_interval
	timer.autostart = false
	timer.one_shot = false
	timer.timeout.connect(_on_timer_timeout)
	add_child(timer)
	$Area3D.body_entered.connect(_on_body_entered)
	$Area3D.body_exited.connect(_on_body_exited)

# Переопределяем — ресурс идёт в $resources а не в self
func _accept_item(item: Node3D) -> void:
	if item is RigidBody3D:
		item.freeze = true
	item.reparent($resources, true)
	inventory.append(item)
	var target_pos = Vector3(0, inventory.find(item) + 1, 0)
	var tween = create_tween()
	tween.tween_property(item, "position", target_pos, 0.3)

func _fix_positions() -> void:
	inventory = inventory.filter(func(i): return is_instance_valid(i))
	for i in inventory:
		var tween = create_tween()
		tween.tween_property(i, "position", Vector3(0, inventory.find(i) + 1, 0), 0.3)

func _on_body_entered(body: Node3D) -> void:
	if body is RigidBody3D:
		if not vehicles_in_zone.has(body):
			vehicles_in_zone.append(body)
		#if timer.is_stopped():
		print("NEMA")
		timer.start(1)

func _on_body_exited(body: Node3D) -> void:
	if body is RigidBody3D:
		vehicles_in_zone.erase(body)
		if vehicles_in_zone.is_empty():
			timer.stop()

func _on_timer_timeout() -> void:
	if inventory.size()>0: print("[intake] таймер сработал, inventory: %d" % inventory.size())
	# Сбрасываем флаг ожидания — проверим сами
	if waiting_for_next and next_block and next_block.current_item == null:
		waiting_for_next = false
	if inventory.size() > 0 and not waiting_for_next:
		_push_from_inventory()
	if inventory.size() < capacity:
		for vehicle in vehicles_in_zone:
			var item = _take_from_vehicle(vehicle)
			if item:
				break

func _push_from_inventory() -> void:
	if next_block == null or inventory.is_empty():
		return
	if waiting_for_next:
		return
	inventory = inventory.filter(func(i): return is_instance_valid(i))
	if inventory.is_empty():
		return
	var item = inventory[0]
	print("[intake] пробуем отдать item в [%s]" % next_block.name)
	# Переносим в корень сцены чтобы мировая позиция была чистой
	var world_pos = item.global_position
	print("item.global_position перед передачей: ", item.global_position)
	print("belt.global_position: ", next_block.global_position)
	item.reparent(get_tree().root, false)
	item.global_position = world_pos
	if next_block.try_receive(item):
		inventory.erase(item)
		_fix_positions()
		slot_freed.emit()
	else:
		# Не приняли — возвращаем обратно в $resources
		item.reparent($resources, false)
		item.global_position = world_pos
		print("[intake] следующий занят — ждём")
		if not waiting_for_next:
			waiting_for_next = true
			next_block.slot_freed.connect(_on_next_block_freed, CONNECT_ONE_SHOT)

func _on_next_block_freed() -> void:
	waiting_for_next = false
	call_deferred("_push_from_inventory")  # ← тоже deferred


func _on_item_received() -> void:
	pass

func _take_from_vehicle(vehicle: RigidBody3D) -> Node3D:
	for b in vehicle.get_node("blocks").get_children():
		if vehicle.get_node("blocks").get_child(0) != b :
			if b.has_node("resources"):
				if b.block ==5:
					var resources = b.get_node("resources")
					if resources.get_child_count() > 0:
						var item = resources.get_child(0)
						if b.has_method("remove_from_inventory"):
							b.remove_from_inventory(item)
						_accept_item(item)
						return item
	return null

func _on_resources_child_order_changed() -> void:
	_fix_positions()
