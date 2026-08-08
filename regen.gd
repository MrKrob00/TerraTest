# regen.gd — блок регенерации: раз в интервал чинит повреждённые блоки СВОЕЙ машины
# в радиусе, тратя энергию машины (vehicle.energy_consume). Нет энергии — не чинит.
extends VehicleBlock

const REGEN_RADIUS := 2.6      # м: как далеко достаёт
const REGEN_HP := 5            # HP за тик на один блок
const REGEN_COST := 2.0        # энергии за один подлеченный блок
const REGEN_INTERVAL := 1.0    # с между тиками

var _timer: float = 0.0

func _physics_process(delta: float) -> void:
	if freeze == false:
		return                               # валяется в мире — не работает
	var blocks_node := get_parent()
	if blocks_node == null or blocks_node.name != "blocks":
		return
	var vehicle := blocks_node.get_parent()
	if vehicle == null or not vehicle.has_method("energy_consume"):
		return
	_timer -= delta
	if _timer > 0.0:
		return
	_timer = REGEN_INTERVAL
	for b: Node in blocks_node.get_children():
		if b == self or not ("current_hp" in b) or not (b is Node3D):
			continue
		if b.current_hp >= b.max_hp:
			continue
		if global_position.distance_to((b as Node3D).global_position) > REGEN_RADIUS:
			continue
		# Платим за каждый блок отдельно: не хватило на этого — дальше смысла нет.
		if vehicle.energy_consume(REGEN_COST) < REGEN_COST:
			break
		b.current_hp = mini(b.current_hp + REGEN_HP, b.max_hp)
		if b.has_method("_refresh_hp_fx"):
			b._refresh_hp_fx()               # подлечили → цифр меньше (или блок снова чистый)
