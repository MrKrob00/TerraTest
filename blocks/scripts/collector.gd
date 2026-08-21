extends VehicleBlock
# КОЛЛЕКТОР — подбирает с земли, и всё. По ленте он НИЧЕГО НЕ ПЕРЕДАЁТ: это VehicleBlock, а не
# FactoryBlock, значит у него нет ни выходов, ни push_item. Забрать у него добычу может только
# приёмник (Receiver._take_from_vehicle), и вот он уже работает лишь на якоре.
#
# Сам коллектор якоря НЕ ТРЕБУЕТ намеренно: собирать руду на ходу — его единственная работа,
# и запрет на это сделал бы блок бессмысленным.

var is_on_vehicle: bool = false
var inventory:Array = []
@export var capacity: int = 2

# ФИЗИКА (freeze тела, monitoring ареи) — в _physics_process: это свойства физического сервера,
# менять их надо на физ-тике, а не на кадре отрисовки (иначе правки летят в произвольный момент
# шага физики и лишний раз дёргают сервер на быстрых экранах).
func _physics_process(_delta: float) -> void:
	if $"..".name == "objects":
		if is_on_vehicle:
			$collector.monitoring = false
			is_on_vehicle = false
		return
	if !is_on_vehicle:
		$collector.monitoring = true
		is_on_vehicle = true
	elif not freeze:
		freeze = true

# ВИЗУАЛ (вращение тарелки, подтяжка её высоты) — в _process: должен идти по кадрам отрисовки,
# чтобы крутился плавно и на экранах с частотой выше физ-тика.
func _process(delta: float) -> void:
	if !is_on_vehicle: return
	$collector/MeshInstance3D.rotation.y += deg_to_rad(360)*delta/6
	$collector/MeshInstance3D.global_position.y = get_parent().global_position.y

func _on_collector_body_entered(body: RigidBody3D) -> void:
	if inventory.has(body): return  # ← уже в инвентаре, игнорируем
	elif body.freeze:
		return
	# СВОБОДНЫЙ БЛОК пакуем в чанк, а не тащим как есть. Коллектор и раньше засасывал блоки
	# (они в мире незаморожены и проходят проверку выше), но нёс их целиком — тяжёлое тело с
	# коллизией занимало слот. Теперь блок исчезает, а в инвентаре растёт счётчик чанка: на
	# ленту уедет ОДИН предмет, даже если в нём двадцать четыре блока.
	if "block" in body:
		_pack_block(body)
		return
	if inventory.size()>=capacity:
		return
	body.reparent($resources)
	if inventory.has(body): return
	inventory.append(body)
	body.freeze = true
	fix_position_resources.call_deferred(body)

# Упаковка — общая с приёмником (VehicleBlock.pack_block_into): правило одно, и разъехаться
# двум копиям негде.
func _pack_block(body: RigidBody3D) -> void:
	if pack_block_into(inventory, $resources, body, capacity):
		if not inventory.is_empty():
			fix_position_resources.call_deferred(inventory[inventory.size() - 1])

## Отдать предмет приёмнику. Он это уже зовёт (Receiver._take_from_vehicle), но метода не
## было, и вызов молча пропускался: список чистился лишь потом, сигналом child_order_changed.
## Пока он не сработал, коллектор считал слот занятым и мог не взять следующую руду.
func remove_from_inventory(item: Node) -> void:
	inventory.erase(item)

func fix_position_resources(body:Node3D):
	body.position = Vector3(0,inventory.find(body)+1,0)

func _on_resources_child_order_changed() -> void:
	for i in inventory:
		if i.get_parent() != $resources:
			inventory.erase(i)
		else: i.position = Vector3(0,inventory.find(i)+1,0)
