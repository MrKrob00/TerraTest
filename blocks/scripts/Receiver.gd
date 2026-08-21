# Receiver.gd
extends FactoryBlock
# ПРИЁМНИК — универсальный вход цепочки, но ТОЛЬКО НА ЯКОРЕ.
#
# Берёт из двух источников: с земли (что лежит в его зоне) и из КОЛЛЕКТОРОВ машин, попавших в
# зону. Дальше отдаёт по ленте (push_item). Коллектор ничего этого не умеет: он лишь копит
# добытое и отдать может только приёмнику.
#
# Якорь обязателен на ВСЕХ путях: и на заборе у коллекторов, и на подъёме с земли. Вся фабрика
# работает под якорем (_factory_active), и вход в неё не может быть исключением — иначе
# цепочка начиналась бы на ходу и обрывалась на первом же следующем блоке.

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
	var target_pos: Vector3 = Vector3(0, inventory.find(item) + 1, 0)
	var tween: Tween = create_tween()
	tween.tween_property(item, "position", target_pos, 0.3)
	_push_from_inventory()   # проталкиваем СРАЗУ (по событию), а не ждём тика таймера
	_update_take_timer()     # набрали capacity → таймер забора сам остановится

func _fix_positions() -> void:
	inventory = inventory.filter(func(i): return is_instance_valid(i))
	for i in inventory:
		var tween: Tween = create_tween()
		tween.tween_property(i, "position", Vector3(0, inventory.find(i) + 1, 0), 0.3)

func _on_body_entered(body: Node3D) -> void:
	if body is RigidBody3D and not vehicles_in_zone.has(body):
		vehicles_in_zone.append(body)
	_try_take_world(body)          # лежит на земле — берём сразу, не дожидаясь тика
	_update_take_timer()

## Свободный предмет с ЗЕМЛИ. Именно «с земли»: берём только то, что лежит под /root/Main/objects,
## — так отсекаются и блоки чужих машин, и предмет в руке игрока (он висит под камерой).
##
## Раньше приёмник этого не умел вовсе, и не по логике, а по маске: зона стояла на 16 (только
## корпуса машин), то есть ни ресурса, ни блока в мире она физически не видела.
func _try_take_world(body: Node3D) -> bool:
	if not _factory_active():
		return false                          # без якоря вход в цепочку закрыт
	if body == null or not is_instance_valid(body) or not (body is RigidBody3D):
		return false
	var p: Node = body.get_parent()
	if p == null or p.name != "objects":
		return false
	if inventory.size() >= capacity:
		return false
	# БЛОК пакуем в чанк — на ленте это один предмет вместо тяжёлого тела с коллизией
	# (правило общее с коллектором, см. VehicleBlock.pack_block_into).
	if "block" in body:
		if pack_block_into(inventory, $resources, body, capacity):
			_push_from_inventory()
			_update_take_timer()
			return true
		return false
	if not body.has_method("kind_key"):
		return false                          # не ресурс и не блок — не наше дело
	_accept_item(body)
	return true

func _on_body_exited(body: Node3D) -> void:
	if body is RigidBody3D:
		vehicles_in_zone.erase(body)
	_update_take_timer()

# Таймер забора крутится ТОЛЬКО когда есть у кого забирать И есть куда класть — иначе стоит,
# чтобы не тикать вхолостую каждую секунду. Проталкивание дальше — по сигналу, не тут.
func _update_take_timer() -> void:
	vehicles_in_zone = vehicles_in_zone.filter(func(v): return is_instance_valid(v))
	var need := not vehicles_in_zone.is_empty() and inventory.size() < capacity
	if need and timer.is_stopped():
		timer.start()
	elif not need and not timer.is_stopped():
		timer.stop()

# Таймер нужен ЛИШЬ чтобы периодически забирать руду у машин в зоне (коллектор копит её сам,
# отдельного сигнала нет). Проталкивание дальше — по сигналу (_accept_item/_on_next_block_freed).
func _on_timer_timeout() -> void:
	# Коллектор подбирает с земли и без якоря, но ЗАБОР у него (начало передачи по
	# цепочке) работает только когда наша машина стоит на якоре.
	if not _factory_active():
		return
	vehicles_in_zone = vehicles_in_zone.filter(func(v): return is_instance_valid(v))
	if inventory.size() < capacity:
		for body in vehicles_in_zone:
			# Сначала земля: предмет, уже лежащий в зоне, забирать некому, кроме нас, а
			# коллектор свою добычу никуда не денет и подождёт.
			if _try_take_world(body):
				break
			if _take_from_vehicle(body):
				break
	_update_take_timer()

func _push_from_inventory() -> void:
	if _valid_targets().is_empty():
		next_block = null
		waiting_for_next = false   # приёмников больше нет — не залипаем в ожидании
		return
	if inventory.is_empty() or waiting_for_next:
		return
	inventory = inventory.filter(func(i): return is_instance_valid(i))
	if inventory.is_empty():
		return
	var item: Node3D = inventory[0]
	# Переносим в корень сцены чтобы мировая позиция была чистой
	var world_pos: Vector3 = item.global_position
	item.reparent(get_tree().root, false)
	item.global_position = world_pos
	if push_item(item):            # раздаём по кругу между всеми выходами (см. FactoryBlock)
		inventory.erase(item)
		_fix_positions()
		slot_freed.emit()
		_update_take_timer()   # освободилось место → снова можно забирать у машин
		if not inventory.is_empty():
			call_deferred("_push_from_inventory")
	else:
		# Не приняли — возвращаем обратно в $resources
		item.reparent($resources, false)
		item.global_position = world_pos
		var wait_on := _first_valid_target()
		if wait_on != null and not waiting_for_next:
			waiting_for_next = true
			wait_on.slot_freed.connect(_on_next_block_freed, CONNECT_ONE_SHOT)

func _on_next_block_freed() -> void:
	waiting_for_next = false
	call_deferred("_push_from_inventory")  # ← тоже deferred

func _on_item_received() -> void:
	pass

func _take_from_vehicle(vehicle: RigidBody3D) -> Node3D:
	if not is_instance_valid(vehicle) or not vehicle.has_node("blocks"):
		return null
	# Забираем руду у КОЛЛЕКТОРОВ машины. Тип блока проверяем явно, поэтому «пропустить
	# первого ребёнка» (прежний произвольный костыль) не нужно — он мог отбросить настоящий
	# коллектор, если тот оказывался первым в списке.
	for b in vehicle.get_node("blocks").get_children():
		if b.get("block") != G.Block.COLLECTOR or not b.has_node("resources"):
			continue
		var resources: Node = b.get_node("resources")
		if resources.get_child_count() == 0:
			continue
		var item: Node3D = resources.get_child(0)
		if b.has_method("remove_from_inventory"):
			b.remove_from_inventory(item)
		_accept_item(item)
		return item
	return null

func _on_resources_child_order_changed() -> void:
	_fix_positions()
