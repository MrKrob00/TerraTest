extends FactoryBlock

# АВТО-ШАХТЁР. Стационарный блок, который ставят НА ЖИЛУ. Делает то же, что игрок с буром,
# только сам: бьёт по жиле, подбирает выпавшее и кладёт на конвейер.
#
# Порядок именно такой — сначала проверка конвейера, потом удар. Бить, когда девать руду
# некуда, значит вытряхивать жилу на землю: она истощится, а игрок ничего не получит.
#
# Жила уже умеет всё нужное сама (resource_node.gd): по hurt роняет руду пропорционально
# HP, на нуле запускает RestTimer и через паузу восстанавливается. Урон подобран так, чтобы
# один удар давал РОВНО одну руду: max_hp 100 при MAX_RESOURCES 5 — это 20 HP на штуку.

## Секунд на одну руду.
@export var mine_interval: float = 2.0
## Урон за удар. 20 при стандартной жиле = ровно одна руда за раз.
@export var hurt_per_cycle: int = 20
## Энергии в секунду. 12 — это две солнечные панели (SOLAR_RATE 6.0 у каждой).
@export var energy_per_sec: float = 12.0
## Как далеко под собой искать жилу и в каком радиусе подбирать выпавшее.
@export var vein_reach: float = 3.0
@export var pickup_radius: float = 4.0

var _t: float = 0.0
var _vein: Node3D = null
var _vein_retry: float = 0.0

func _physics_process(delta: float) -> void:
	if not _factory_active():
		return
	_t -= delta
	if _t > 0.0:
		return
	_t = mine_interval

	# 1. Приёмник. Пусто — не бьём: руда просто высыпалась бы на землю.
	var target: FactoryBlock = _free_target()
	if target == null:
		return
	# 2. Энергия. Списываем за весь цикл сразу; не хватило — цикл пропущен.
	if not _take_energy():
		return
	# 3. Жила.
	var vein: Node3D = _find_vein(delta)
	if vein == null or not vein.has_method("hurt"):
		return
	# Что уже валяется рядом, запоминаем: новым будет то, чего в этом списке нет.
	var before: Array = _loose_resources()
	vein.hurt(hurt_per_cycle)
	# Жила штампует руду сразу в _eject_one, так что искать можно тем же кадром.
	for r in _loose_resources():
		if before.has(r):
			continue
		if target.try_receive(r):
			return
		break                             # приёмник передумал — руда осталась в мире

# Первый подключённый приёмник со свободным слотом.
func _free_target() -> FactoryBlock:
	for t in next_blocks:
		if t != null and is_instance_valid(t) and t.current_item == null:
			return t
	return null

func _take_energy() -> bool:
	var v: Node = _vehicle()
	if v == null or not v.has_method("energy_consume"):
		return true                       # энергосистемы нет — не блокируем добычу
	var need: float = energy_per_sec * mine_interval
	return v.energy_consume(need) >= need - 0.001

# Жила ПОД блоком. Ищем лучом вниз и кешируем: жила не двигается, а стационарный блок тем
# более. Кеш сбрасываем, если жила исчезла.
func _find_vein(delta: float) -> Node3D:
	if is_instance_valid(_vein):
		return _vein
	_vein = null
	_vein_retry -= delta
	if _vein_retry > 0.0:
		return null
	_vein_retry = 1.0
	var space: PhysicsDirectSpaceState3D = get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(
			global_position + Vector3.UP * 0.5,
			global_position + Vector3.DOWN * vein_reach)
	q.collision_mask = 0xFFFFFFFF
	var hit: Dictionary = space.intersect_ray(q)
	var c = hit.get("collider")
	if c is Node3D and c.has_method("hurt") and "instance_id" in c:
		_vein = c as Node3D               # instance_id есть только у жилы
	return _vein

# Свободные ресурсы рядом: жила роняет их себе под бок, к нам они сами не придут.
func _loose_resources() -> Array:
	var out: Array = []
	var root: Node = get_node_or_null("/root/Main/objects")
	var vein_root: Node = _vein.get_parent() if is_instance_valid(_vein) else null
	for holder in [root, vein_root]:
		if holder == null:
			continue
		for c in holder.get_children():
			if c is Node3D and "type" in c and global_position.distance_to((c as Node3D).global_position) <= pickup_radius:
				out.append(c)
	return out

func _vehicle() -> Node:
	var p: Node = get_parent()
	if p == null or p.name != "blocks":
		return null
	return p.get_parent()
