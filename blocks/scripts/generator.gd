# generator.gd — фабричный блок: принимает ресурс по цепочке (лента/приёмник), сжигает
# его BURN_TIME секунд и выдаёт энергию в машину (руда меньше, слиток больше).
# Как и вся фабрика — работает только под якорем: горение вне якоря стоит на паузе.
extends FactoryBlock

const BURN_TIME := 3.0
const ENERGY_COAL := 40.0     # уголь — основное топливо
const ENERGY_ORE := 25.0
const ENERGY_INGOT := 80.0

var _burn_left: float = 0.0
var _burn_energy: float = 0.0

# КОМПОНЕНТ в топку не берём вовсе. Он не топливо: сжечь деталь, которая стоит двух слитков,
# ради энергии одной руды — это не выбор игрока, а потеря по невнимательности. Отказ виден:
# компонент остаётся на ленте и едет дальше.
func try_receive(item: Node3D) -> bool:
	if item != null and "type" in item and int(item.get("type")) == 4:   # 4 = Type.COMPONENT
		return false
	return super.try_receive(item)

func _on_item_received() -> void:
	if current_item == null:
		return
	# Сколько энергии даст топливо: по типу ресурса (ORE/INGOT/COAL).
	_burn_energy = ENERGY_ORE
	if "type" in current_item and current_item.has_method("upgrade"):
		var tname: String = current_item.Type.keys()[current_item.type]
		match tname:
			"COAL":  _burn_energy = ENERGY_COAL
			"INGOT": _burn_energy = ENERGY_INGOT
			_:       _burn_energy = ENERGY_ORE
	_burn_left = BURN_TIME
	current_item.visible = false          # топливо «в топке»

func _physics_process(delta: float) -> void:
	if _burn_left <= 0.0 or current_item == null:
		return
	if not _factory_active():
		return                            # не на якоре — топка на паузе
	_burn_left -= delta
	if _burn_left > 0.0:
		return
	# Догорело: энергия в машину, топливо испарилось, слот свободен.
	var v := _gen_vehicle_root()
	if v and v.has_method("energy_produce"):
		v.energy_produce(_burn_energy)
	if is_instance_valid(current_item):
		current_item.queue_free()
	current_item = null
	slot_freed.emit()

func _gen_vehicle_root() -> Node:
	var p := get_parent()
	while p != null and not (p is RigidBody3D):
		p = p.get_parent()
	return p
