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

func fix_position_resources(body:Node3D):
	if not is_instance_valid(body):
		return                     # предмет забрали и уничтожили, пока вызов ждал кадра
	body.position = Vector3(0, maxi(inventory.find(body), 0) + 1, 0)

# Столбик добычи над блоком. Сперва ЧИСТИМ список, потом раскладываем — и в таком порядке
# по двум причинам.
#
# Во-первых, ссылка на освобождённый узел НЕ равна null: руду у коллектора забирает приёмник,
# дальше она уезжает по ленте и может быть переплавлена или продана — то есть узла уже нет, а
# в списке он ещё есть. Проверять его через get_parent() значило падать на мёртвом узле
# («Attempt to call function 'get_parent' in base 'previously freed'»), поэтому фильтруем
# по is_instance_valid.
#
# Во-вторых, erase ПРЯМО В ЦИКЛЕ по тому же массиву сдвигает хвост, и обход пропускает
# элемент за каждым удалённым — часть добычи оставалась лежать друг в друге.
func _on_resources_child_order_changed() -> void:
	var holder := $resources
	inventory = inventory.filter(func(i):
		return is_instance_valid(i) and i.get_parent() == holder)
	for idx in inventory.size():
		var n := inventory[idx] as Node3D
		if n != null:
			n.position = Vector3(0, idx + 1, 0)
