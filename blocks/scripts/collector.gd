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
	# THE RING TURNS UNDER THE COLLECTOR (the player's call). It was the 5 m reach ring, pulled to the
	# machine's centre height every frame, and read as stray arcs somewhere beside the block.
	$collector/MeshInstance3D.rotation.y += deg_to_rad(360)*delta/6

func _on_collector_body_entered(body: RigidBody3D) -> void:
	if inventory.has(body): return  # ← уже в инвентаре, игнорируем
	elif body.freeze:
		return
	# СВОБОДНЫЕ БЛОКИ — не его работа, для них есть упаковщик (packer.gd). Здесь стояла
	# ветка упаковки, но зона коллектора имеет маску 8 (ТОЛЬКО ресурсы), так что блока она не
	# видела никогда: код был мёртвый, а комментарий рядом с ним утверждал обратное.
	# Готовые ЧАНКИ коллектор берёт как обычный ресурс — они лежат на том же слое.
	if inventory.size()>=capacity:
		return
	body.reparent($resources)
	if inventory.has(body): return
	inventory.append(body)
	body.freeze = true
	fix_position_resources.call_deferred(body)

## Отдать предмет приёмнику. Он это уже зовёт (Receiver._take_from_vehicle), но метода не
## было, и вызов молча пропускался: список чистился лишь потом, сигналом child_order_changed.
## Пока он не сработал, коллектор считал слот занятым и мог не взять следующую руду.
func remove_from_inventory(item: Node) -> void:
	inventory.erase(item)
	# The single door out puts the item back as a loose one: visible, seated as loose items sit.
	if is_instance_valid(item) and item is Node3D:
		(item as Node3D).visible = true
		if item.has_method("unseat"):
			item.unseat()
	_layout()

## WHAT IT PICKED UP STANDS IN A STACK IN THE BOWL, AS THE RECEIVER LIFTS ITS CARGO (the player's
## call: it showed one and hid the rest, so a collector carrying five looked like it carried one).
## Each item stands on the one under it (`model_height` + `STACK_GAP`): the first stack, of
## metre-wide bubbles one metre apart, grew a tower taller than the machine - which is why it was
## cut down to one.
const HOLD_Y := 0.45
## The bottom item's model stands this far under HOLD_Y, on the bowl's boss (resource.seat).
const HOLD_FOOT := -0.12
const STACK_GAP := 0.02

func _layout() -> void:
	var holder := get_node_or_null("resources")
	if holder == null:
		return                     # the block is being torn down; its children go first
	inventory = inventory.filter(func(i):
		return is_instance_valid(i) and i.get_parent() == holder)
	var y := HOLD_Y
	for idx in inventory.size():
		var n := inventory[idx] as Node3D
		if n == null:
			continue
		n.position = Vector3(0, y, 0)
		n.visible = true
		if n.has_method("seat"):
			n.seat(HOLD_FOOT)
		y += (n.model_height() if n.has_method("model_height") else 0.3) + STACK_GAP

func fix_position_resources(body: Node3D) -> void:
	if not is_instance_valid(body):
		return                     # taken and freed while the call waited for the frame
	_layout()

## The list is cleaned FIRST and laid out after: a node a receiver took may already be freed (a
## freed reference is not null), and erasing inside the loop over the same array skipped items.
func _on_resources_child_order_changed() -> void:
	_layout()
