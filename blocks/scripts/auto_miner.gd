extends FactoryBlock

# AUTO-MINER: a stationary block placed on a WORKED-OUT vein, and that is the whole mechanic.
#
# ORDER MATTERS. The drill takes the vein first (five ore in a burst); only an empty one can be
# claimed. While the miner stands there the vein NEVER REFILLS - it slowly scrapes out what a drill
# can no longer reach. That is the choice: the drill is fast, manual and needs you back every few
# seconds; the miner is slow, unattended and permanent, but it TAKES the vein away from the drill.
# Hitting the same vein with the same hurt made it a drill that never tires, i.e. no decision.
#
# A receiver is WANTED, not required. Without one the ore simply lies by the vein (same rule as a
# packer with no belt) for a collector or the player to pick up; refusing to mine at all made the
# commonest placement - one miner on a vein as its own base core - look like a broken block. To
# keep it from burying the map while nobody is around, an unreceived miner stops at GROUND_LIMIT.
#
# The vein does the rest itself (resource_node.gd): claim/release hold it worked out, and
# mine_for_claimer hands out ore of ITS type and colour - "metal belongs to the biome" must not be
# a rule two scripts know.

## Секунд на одну руду. Бур с руки достаёт из живой жилы пять штук за полторы секунды и ждёт
## пять; шахтёр медленнее, зато сам и без перерыва.
@export var mine_interval: float = 2.0

# ── КАЧАЛКА ──────────────────────────────────────────────────────────────────
# Модель шахтёра — это станок-качалка: кривошип, шатун, коромысло и бур в лунку, подвешенные
# на костях (Skeleton3D в сцене). Анимацию к ним не выдумываем: она уже сделана художником в
# Blender и лежит в objects/Assets.glb (действие Armature.001Action, 2.5 с). Оттуда её ключи
# перенесены в blocks/scenes/auto_miner_pump.tres — четыре трека поворота на четыре кости,
# которые реально двигаются (пятая, Bone.003, в действии стоит на месте, и трека у неё нет).
#
# ДВИЖЕНИЕ = РАБОТА, И ЭТО ГЛАВНОЕ ПРАВИЛО. Качалка ходит РОВНО тогда, когда цикл добычи
# прошёл целиком: есть энергия, есть занятая жила, есть куда деть руду. Крутящаяся вхолостую
# машина врёт игроку дважды — она и «работает», и не даёт понять, почему нет руды; замершая
# сразу показывает, что чего-то не хватает, и остаётся посмотреть, чего именно.
const ANIM_LEN := 2.5
## Дальше этого качалку останавливаем: рига в два метра за сотню метров не разглядеть, а
## анимация тянет за собой пересчёт поз скелета и всех BoneAttachment3D каждый кадр. Гасим
## ПО РАССТОЯНИЮ, а не по направлению взгляда: правило проекта — ближний пузырь активен в любую
## сторону, иначе обернулся и увидел замершую машину, которая «только что работала».
const RIG_VIEW_DIST := 120.0
@onready var _anim: AnimationPlayer = get_node_or_null("AnimationPlayer")
var _rig_on: bool = false
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
		_set_rig(false)
		return
	_t -= delta
	if _t > 0.0:
		return
	_t = mine_interval

	# 1. Куда девать руду. Приёмника нет — кладём на землю, но не бесконечно (см. шапку).
	var target: FactoryBlock = _free_target()
	var before: Array = _loose_resources()
	if target == null and before.size() >= GROUND_LIMIT:
		_set_rig(false)
		return
	# 2. The vein, BEFORE the energy. Paying first meant a miner with no spent vein in reach (or
	# one taken by a neighbour) was billed every cycle for ore it never dug.
	var vein: Node3D = _find_vein(delta)
	if vein == null or not vein.has_method("mine_for_claimer"):
		_set_rig(false)
		return
	# 3. Energy: ASKED, then taken. energy_consume hands over whatever there is even when it is
	# short, so "take and see" on one panel (6/s against the 12/s this block needs) drained the
	# batteries to zero, then ate every tick's production, and never once dug - the machine was
	# flat and the ground was empty.
	if not _has_energy():
		_set_rig(false)
		return
	# Что уже валяется рядом, мы запомнили ВЫШЕ: новым будет то, чего в том списке нет.
	if not vein.mine_for_claimer(self):
		_set_rig(false)
		return                            # жилу занял кто-то другой или она вдруг ожила
	_pay_energy()
	# Цикл прошёл целиком — качалка ходит (если есть кому на неё смотреть).
	_set_rig(_seen_by_player())
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
		# Спрашиваем can_accept(), а не current_item: у процессора внутри очередь на три клетки,
		# и «выход занят» там не значит «брать не готов».
		if t != null and is_instance_valid(t) and t.can_accept():
			return t
	return null

## Enough for a whole cycle right now. A machine with no energy system at all has none: the miner
## is a factory, and a factory runs on power. It used to dig for free on a base with no panel and
## no battery (capacity 0), which made the power it asked for everywhere else a formality.
func _has_energy() -> bool:
	var v: Node = _vehicle()
	if v == null or not v.has_method("energy_available"):
		return false
	var need: float = energy_per_sec * mine_interval
	if float(v.energy_available()) >= need - 0.001 or _free_power(v):
		return true
	_say_no_power(v)
	return false

func _pay_energy() -> void:
	var v: Node = _vehicle()
	if v != null and v.has_method("energy_consume"):
		v.energy_consume(energy_per_sec * mine_interval)

## The debug switch pays for the player's machines at the till (MachineBody.energy_consume), so an
## empty store must not stop a miner there either.
func _free_power(v: Node) -> bool:
	return v.get("faction") == 0 and G.debug(&"infinite_energy", false)

## Said ONCE per block, and only for the player's own machine: a stopped rig shows that something is
## missing, this says what. Once, because the cycle comes round every two seconds.
var _told_power: bool = false
func _say_no_power(v: Node) -> void:
	if _told_power or v.get("faction") != 0 or v.get("demo") == true:
		return
	_told_power = true
	var need: float = energy_per_sec
	Dialogue.say("System", tr("The Auto Miner needs %d energy a second: two solar panels, or a battery to carry it.") % int(need))

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

## Пуск и остановка качалки. Плеер трогаем ТОЛЬКО НА СМЕНЕ состояния: _physics_process зовётся
## каждый физкадр, и play() на работающей анимации сбрасывал бы её в начало — вместо хода
## качалки получилась бы дрожь на первом кадре цикла.
##
## Останавливаем pause(), а не stop(): качалка замирает там, где её застали, и с того же места
## продолжает, когда работа возобновится. stop() отбрасывал бы её в исходную позу, и каждый
## перебой энергии выглядел бы как рывок.
func _set_rig(on: bool) -> void:
	if on == _rig_on or _anim == null:
		return
	_rig_on = on
	if on:
		# Темп СЛЕДУЕТ ЗА ПРОИЗВОДСТВОМ: один проход анимации = одна руда. Число одно
		# (mine_interval), и если его поменять в инспекторе, качалка поедет соответственно —
		# иначе визуальный ритм и реальный разъедутся, и станок будет махать вхолостую.
		_anim.speed_scale = ANIM_LEN / maxf(mine_interval, 0.05)
		_anim.play("pump")
	else:
		_anim.pause()

## Есть ли кому смотреть. Камеру спрашиваем у вьюпорта — ту же, по которой рельеф считает LOD;
## своей ссылки на игрока блоку не нужно.
func _seen_by_player() -> bool:
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return true
	return cam.global_position.distance_squared_to(global_position) \
			<= RIG_VIEW_DIST * RIG_VIEW_DIST

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
