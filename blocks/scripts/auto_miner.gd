extends FactoryBlock

# АВТО-ШАХТЁР. Стационарный блок, который ставят у ВЫРАБОТАННОЙ жилы — и в этом вся механика.
#
# ПОРЯДОК ТАКОЙ: сначала жилу выбирает бур (пять руды залпом), и только пустую её можно занять
# шахтёром. Дальше жила НЕ ВОССТАНАВЛИВАЕТСЯ, пока он стоит: он медленно выскребает то, что
# буром уже не достать. Отсюда и выбор, которого раньше не было. Бур — это быстро, вручную и
# с возвратом каждые пять секунд; шахтёр — медленно, само и навсегда, но жилу он у бура
# ЗАБИРАЕТ. Раньше он просто бил ту же жилу тем же hurt, то есть был буром, который не устаёт:
# ставить его имело смысл всегда и везде, а решать было нечего.
#
# Отсюда же ответ на «а бур тогда что?»: буру достаются ЖИВЫЕ жилы, которых на карте много, и
# та, что стоит под шахтёром, из этого списка просто выбывает.
#
# Приёмник ЖЕЛАТЕЛЕН, но не обязателен. Раньше без него шахтёр не бил вовсе («не вытряхивать
# жилу на землю»), и это делало бесполезным самый частый способ его поставить — ОДИН на жиле,
# ядром своей базы: он стоял и не делал ничего, что читается как сломанный блок. Теперь без
# приёмника руда просто остаётся лежать у жилы, как у упаковщика без ленты («ленты нет — падает
# в мир»): её подберёт коллектор или сам игрок. Чтобы шахтёр не засыпал карту, пока хозяина нет
# рядом, без приёмника он бьёт только пока невывезенного под ногами меньше GROUND_LIMIT.
#
# Всё, что нужно, жила умеет сама (resource_node.gd): claim/release держат её выработанной,
# mine_for_claimer выдаёт руду её типа и цвета. Тип и цвет руды считает ЖИЛА, а не шахтёр —
# иначе правило «металл принадлежит биому» пришлось бы знать двоим.

## Секунд на одну руду. Бур с руки достаёт из живой жилы пять штук за полторы секунды и ждёт
## пять; шахтёр медленнее, зато сам и без перерыва.
@export var mine_interval: float = 2.0
## Энергии в секунду. 12 — это две солнечные панели (SOLAR_RATE 6.0 у каждой).
@export var energy_per_sec: float = 12.0
## Как далеко под собой искать жилу и в каком радиусе подбирать выпавшее.
@export var vein_reach: float = 3.0
@export var pickup_radius: float = 4.0
## Сколько невывезенной руды рядом — и хватит: без приёмника бить дальше некуда.
const GROUND_LIMIT := 6

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

	# 1. Куда девать руду. Приёмника нет — кладём на землю, но не бесконечно (см. шапку).
	var target: FactoryBlock = _free_target()
	var before: Array = _loose_resources()
	if target == null and before.size() >= GROUND_LIMIT:
		return
	# 2. Энергия. Списываем за весь цикл сразу; не хватило — цикл пропущен.
	if not _take_energy():
		return
	# 3. Жила.
	var vein: Node3D = _find_vein(delta)
	if vein == null or not vein.has_method("mine_for_claimer"):
		return
	# Что уже валяется рядом, мы запомнили ВЫШЕ: новым будет то, чего в том списке нет.
	if not vein.mine_for_claimer(self):
		return                            # жилу занял кто-то другой или она вдруг ожила
	if target == null:
		return                            # руда осталась у жилы — её подберут коллектор или игрок
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
	# ТО ЖЕ САМОЕ, когда система есть, но ПУСТА. У базы, чьё ядро — сам шахтёр, нет ни панелей,
	# ни аккумуляторов: ёмкость ноль, выработка ноль, и списать с неё нельзя НИКОГДА. Шахтёр
	# молча не добывал ничего, а сказать об этом ему нечем — блок читался как сломанный.
	# Появилась панель — появилась и плата за цикл, правило «фабрика ест энергию» в силе.
	if v.has_method("energy_cap") and float(v.energy_cap()) <= 0.0:
		return true
	var need: float = energy_per_sec * mine_interval
	return v.energy_consume(need) >= need - 0.001

# Жила ПОД блоком. Ищем ПО ДАННЫМ (перебором залежей), а не лучом вниз, и кешируем: жила не
# двигается, а стационарный блок тем более. Кеш сбрасываем, если жила исчезла.
#
# Луч не годился по двум причинам, и обе тихие. Первая: он шёл БЕЗ exclude, а под шахтёром
# стоит его собственная коллизия (у блока на машине она живёт на корпусе) — луч упирался в
# свою же машину, «жилой» она не была, и добыча не начиналась вовсе. Вторая: коллизия у жилы
# СТРИМИТСЯ — далёкая жила её не держит, и шахтёр за спиной игрока переставал её видеть.
# Перебор идёт по тому же списку и тем же радиусом, что проверка при постановке
# (vehicle_body_3d._vein_near): правило «дотягивается до жилы» должно быть одно.
func _find_vein(delta: float) -> Node3D:
	if is_instance_valid(_vein):
		return _vein
	_vein = null                          # жила исчезла (стриминг) — займём заново, когда вернётся
	_vein_retry -= delta
	if _vein_retry > 0.0:
		return null
	_vein_retry = 1.0
	var rn: Node = get_node_or_null("/root/Main/map/Resource_Nodes")
	if rn == null:
		return null
	var best_d: float = vein_reach * vein_reach
	for c in rn.get_children():
		if not (c is Node3D) or not ("instance_id" in c) or not c.has_method("mine_for_claimer"):
			continue                      # mine_for_claimer есть только у жилы
		# ИЩЕМ СРЕДИ ПОДХОДЯЩИХ, а не «ближайшую вообще». Рядом может стоять живая жила или
		# занятая соседним шахтёром: выбери мы её как ближайшую, claim бы отказал, и блок
		# стоял бы вхолостую при свободной жиле в двух метрах.
		if not c.is_depleted():
			continue
		var owner_now = c.get("claimed_by")
		if owner_now != null and is_instance_valid(owner_now) and owner_now != self:
			continue
		var d: float = global_position.distance_squared_to((c as Node3D).global_position)
		if d < best_d:
			best_d = d
			_vein = c as Node3D
	# ЗАНИМАЕМ: пока жила наша, она не восстанавливается и её не займёт второй шахтёр.
	if _vein != null and not _vein.claim(self):
		_vein = null
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
			if c is Node3D and "type" in c \
					and global_position.distance_squared_to((c as Node3D).global_position) <= pickup_radius * pickup_radius:
				out.append(c)
	return out

## Блока не стало (снесли, взорвали, разобрали базу) — жила снова свободна и начинает отдых.
## Через NOTIFICATION_PREDELETE, а не tree_exiting: блок ВРЕМЕННО выходит из дерева при
## переносе на другую машину, и отпускать жилу на этом не нужно.
func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE and is_instance_valid(_vein) and _vein.has_method("release"):
		_vein.release(self)

func _vehicle() -> Node:
	var p: Node = get_parent()
	if p == null or p.name != "blocks":
		return null
	return p.get_parent()
