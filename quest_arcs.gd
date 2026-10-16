class_name QuestArcs
extends Node
# Ведущий сюжетной ветки: кладёт в мир то, что квест обещал, и следит, выполнено ли условие
# стадии. Сами квесты (тексты, стадии, зависимости) живут в quest_manager — здесь только их
# «физика»: что появляется в мире и что считается сделанным.
#
# Условия проверяются ОПРОСОМ раз в секунду, а не событием на постановку блока. Событие
# block_placed не знает типа блока, и учить его типу пришлось бы через всю цепочку
# постановки; опрос же не зависит от того, КАК блок попал на машину — поставил руками,
# подобрал с земли, отобрал у вора. Раз в секунду — это дёшево: обход блоков одной машины.

const POLL := 1.0

## ДИСТАНЦИЯ СПАВНА КВЕСТОВЫХ МАШИН — одна на все ветки. Раньше у каждой была своя (170..260),
## и разницы между ними игрок всё равно не видел, а держать восемь чисел про одно и то же значит
## однажды получить квест, начинающийся в двадцати метрах.
##
## УЧАСТНИКИ ПОЯВЛЯЮТСЯ СРАЗУ, а не когда игрок доедет. Отложенный спавн читался как «метка
## ведёт в пустое поле, доедешь — тогда и появятся»: до приезда там нечего было увидеть даже в
## бинокль. Далеко они всё равно ничего не стоят — спавнер их усыпляет (sleep_dist).
const EV_SPAWN_DIST := Vector2(250.0, 300.0)

func _quest_dist() -> float:
	return randf_range(EV_SPAWN_DIST.x, EV_SPAWN_DIST.y)

var _t: float = 0.0
var _props: QuestProps = null
var _dropped: Dictionary = {}      # какие стадии уже выложили своё добро в мир

func _ready() -> void:
	# НА ПОЛИГОНЕ ВЕТКИ НЕ ЗАПУСКАЮТСЯ САМИ, но узел жив: ведём то, что выдали руками через
	# панель (см. _arc_quests). Раньше он тут выключался целиком, и проверить ветку на полигоне
	# было нельзя вовсе — а это единственное место, где её можно посмотреть с начала и сразу.
	add_to_group("quest_arcs")     # компас берёт отсюда координаты события
	_props = QuestProps.new()
	add_child(_props)

func _process(delta: float) -> void:
	var _pf := Perf.now()          # profiler mark (perf.gd)
	_tick_arcs(delta)
	Perf.mark("quests", _pf)

func _tick_arcs(delta: float) -> void:
	_t -= delta
	if _t > 0.0:
		return
	_t = POLL
	if get_node_or_null("/root/Q") == null:
		return
	# NOT BEFORE THE WORLD IS UP (G.world_ready): polled under the loading screen, a branch measured
	# its point from the scene's default spot with the player's height for the ground - Salvage Run's
	# cargo and guard went INSIDE a mountain and its "reach" stage could never close.
	if not G.world_ready():
		return
	_ev_cooldowns(POLL)
	_sweep_yellow_points()
	_party_tick()
	var polled: Dictionary = {}
	for q in _arc_quests():
		_cur_q = String(q.get("id", ""))
		polled[_ev_key(String(q.get("event", "")))] = true
		if _cur_q == "arc_solvent":
			_solvent(q)
			continue
		match String(q.get("event", "")):
			"quest_arc_power_1":   _arc_power_1(q)
			"quest_arc_power_2":   _arc_power_2(q)
			"quest_arc_radar_1":   _arc_radar_1(q)
			"quest_arc_battery_1": _arc_battery_1(q)
			"quest_arc_battery_2": _arc_battery_2(q)
			"quest_salvage_1":     _salvage_1(q)
			"quest_salvage_2":     _salvage_2(q)
			"quest_line_1":        _line_1(q)
			"quest_line_2":        _line_2(q)
			"quest_hold_1":        _hold_1(q)
			"quest_hold_2":        _hold_2(q)
			"quest_yellow_1":      _yellow_1(q)
			"quest_tower_1":       _tower_1(q, TOWER_WATCH)
			"quest_tower_2":       _tower_2(q, TOWER_WATCH)
			"quest_sam_1":         _tower_1(q, TOWER_SAM)
			"quest_sam_2":         _tower_2(q, TOWER_SAM)
			# The three cubes run at once, each its own key and point (the tower branch, CUBES)
			"quest_cube1_1":       _tower_1(q, CUBES[0])
			"quest_cube1_2":       _tower_2(q, CUBES[0])
			"quest_cube2_1":       _tower_1(q, CUBES[1])
			"quest_cube2_2":       _tower_2(q, CUBES[1])
			"quest_cube3_1":       _tower_1(q, CUBES[2])
			"quest_cube3_2":       _tower_2(q, CUBES[2])
			# MARLIT'S EVENTS ARE THE SAME EVENTS WITH ANOTHER FACTION: the functions take their key
			# from the stage ("quest_mgang_1" -> "mgang"), and the faction decides the enemies'
			# builds (_faction_preset), the loot and whose XP it pays (Q.faction_of)
			"quest_mgang_1":       _gang_1(q)
			"quest_mgang_2":       _gang_2(q)
			"quest_msupply_1":     _supply_1(q)
			"quest_msupply_2":     _supply_2(q)
			"quest_mdefend_1":     _defend_1(q)
			"quest_mdefend_2":     _defend_2(q)
			"quest_gang_1":        _gang_1(q)
			"quest_gang_2":        _gang_2(q)
			"quest_supply_1":      _supply_1(q)
			"quest_supply_2":      _supply_2(q)
			"quest_defend_1":      _defend_1(q)
			"quest_defend_2":      _defend_2(q)
			# every timed course is one pair of handlers (COURSES)
			"quest_race_1", "quest_plateau_1", "quest_descent_1", "quest_acourse_1", "quest_adrag_1", \
					"quest_aslalom_1":
				_course_1(q)
			"quest_race_2", "quest_plateau_2", "quest_descent_2", "quest_acourse_2", "quest_adrag_2", \
					"quest_aslalom_2":
				_course_2(q)
			"quest_achase_1":      _chase_1(q)
			"quest_rock_1":        _rock_1(q)
			"quest_rock_2":        _rock_2(q)
			"quest_quiet_1":       _quiet_1(q)
			"quest_quiet_2":       _quiet_2(q)
			"quest_crown_1":       _tower_1(q, CROWN)
			"quest_crown_2":       _tower_2(q, CROWN)
			"quest_bop_1":         _bop_1(q)
			"quest_bop_2":         _bop_2(q)
			"quest_astrand_1":     _strand_1(q)
			"quest_astrand_2":     _strand_2(q)
			"quest_achase_2":      _chase_2(q)
			"quest_camp_1":        _camp_1(q)
			"quest_camp_2":        _camp_2(q)
			"quest_camp_3":        _camp_3(q)
	_drop_orphans(polled)
	_update_safe_zones()
	_sweep_safe_zones()

## A QUIET ZONE ROUND THE LEARNING BASES (the player's rule): while the power branch (the panel and
## the repair unit) or the factory branch (the line, then Solvent's sales) is open, no hostile
## machine is born within G.SAFE_ZONE_R of its site (`enemy_spawner.is_clear_of_player`, the door every
## spawn goes through, and `_event_point`), none takes a target standing in it
## (`enemy_vehicle._consider_target`, and a target that walks in is dropped), and one that is inside
## drives back out (`enemy_vehicle._leave_safe_zone`). The quests done, the zone is gone. Centred on
## the site's POINT, so it stands before the base does. Rebuilt every poll; `safe_zone_at` is the
## one question everyone asks (through `G.safe_zone_at`).
const SAFE_ZONE_QUESTS := ["arc_power", "arc_line", "arc_solvent"]
var _safe: Array = []

func _update_safe_zones() -> void:
	_safe.clear()
	for q in _arc_quests():
		var id := String(q.get("id", ""))
		if not SAFE_ZONE_QUESTS.has(id) or q.get("done", false):
			continue
		var at: Variant = null
		if id == "arc_power":
			at = _power_point
		else:
			_line_adopt()
			at = _line_point
		if at is Vector3 and not _safe.has(at):
			_safe.append(at)

## WHAT STANDS IN A QUIET ZONE IS TAKEN AWAY (the player: the power site came up beside an enemy
## turret, which shot it to pieces). Every poll while a zone stands, for every hostile machine
## inside: an EVENT's (meta `QUEST_OWNER`, set at the one door `_ask_spawner`) drops that event as an
## abandoned one is - its machines leave, it cools down and comes back elsewhere;
## a MAIN QUEST's (a story quest's: a carrier, a tower, the champion; the scout, `story_scout`) stays,
## its quest needs it - it takes no target inside and drives out (`enemy_vehicle._leave_safe_zone`);
## anything else goes - the stream's, a raid's, a miner, a stronghold (`outposts` keeps its point and
## builds it again once the zone is gone: its `_clear_of_player` asks the zone). The `story` meta
## cannot tell them apart: `spawn_at` puts it on every machine it makes, raids included. An event
## whose POINT is inside is dropped before anything is born there.
const QUEST_OWNER := "quest_owner"

func _sweep_safe_zones() -> void:
	if _safe.is_empty():
		return
	for q in _arc_quests():
		if int(q.get("type", -1)) != Q.Type.EVENT or q.get("done", false):
			continue
		var key := _ev_key(String(q.get("event", "")))
		var pt = _ev_point.get(key)
		if pt is Vector3 and safe_zone_at(pt as Vector3, EV_PARTY_RING) != null:
			_drop_event(q)
	var vr: Node = get_node_or_null("/root/Main/Vehicles")
	if vr == null:
		return
	for v in vr.get_children():
		if not (v is Node3D) or v.is_queued_for_deletion():
			continue
		var f = v.get("faction")
		if f == null or int(f) == 0 or safe_zone_at((v as Node3D).global_position) == null:
			continue
		if v.has_meta("story_scout"):
			continue
		if v.has_meta(QUEST_OWNER):
			var q: Dictionary = Q.find_quest(String(v.get_meta(QUEST_OWNER)))
			if not q.is_empty() and not q.get("done", false):
				if int(q.get("type", -1)) == Q.Type.EVENT:
					_drop_event(q)
					if v.is_queued_for_deletion():
						continue
				else:
					continue                           # a main quest's: it stays and drives out
		v.queue_free()

## An event dropped like an abandoned one: machines, point and orb gone, cooled down, skipped.
func _drop_event(q: Dictionary) -> void:
	var key := _ev_key(String(q.get("event", "")))
	_ev_clear(key)
	_ev_cool[String(q["id"])] = _event_cooldown()
	Q.skip_quest(String(q["id"]))

## The centre of the quiet zone holding `p` (with `pad` metres more radius), or null.
func safe_zone_at(p: Vector3, pad: float = 0.0) -> Variant:
	var r: float = G.SAFE_ZONE_R + pad
	for c in _safe:
		var cv: Vector3 = c
		if Vector2(p.x - cv.x, p.z - cv.z).length_squared() < r * r:
			return cv
	return null

## AN EVENT THAT LEFT THE POLL LEAVES THE WORLD. Its state is cleaned where the event ends -
## done, abandoned, skipped - but an event can also simply stop being active: the board redrawn
## when a better faction opens, a forced branch dropped on the proving ground. Then nothing polled
## it again, and its machines, orb and loose items stayed in the world for good, the machines
## tagged `story` (never cleaned up, holding places in `max_total`).
func _drop_orphans(polled: Dictionary) -> void:
	var keys: Dictionary = {}
	for d in [_ev_point, _ev_mobs, _ev_orb, _ev_party, _ev_base]:
		for k in d:
			keys[k] = true
	for k in _tracks:
		if is_instance_valid(_tracks[k]) and _tracks[k].get("keep") != true:
			keys[k] = true
	for k in keys:
		if not polled.has(k):
			_forget_event(String(k))

func _forget_event(key: String) -> void:
	_ev_ally.erase(key)
	_supply_hidden.erase(key)
	_supply_t.erase(key)
	_defend_t.erase(key)
	_defend_wave2.erase(key)
	_supply_trap.erase(key)
	_supply_opened.erase(key)
	_ev_clear(key)

## A QUEST HANDED OUT AGAIN STARTS CLEAN (`Q.force_quest`, the proving ground). The branch's memory
## outlives the quest: forced a second time, the radar branch found its carrier "already dead" and
## dropped the block at the old spot instead of sending a carrier, a tower kept its old point.
## Everything the quest's stages keep in memory is forgotten and its machines leave.
func forget_quest(id: String) -> void:
	var q: Dictionary = Q.find_quest(id)
	_ev_cool.erase(id)
	if id == "arc_solvent":
		_solvent_said = -1
	_q_kills.erase(id)
	for st in q.get("stages", []):
		var key := _ev_key(String((st as Dictionary).get("event", "")))
		_forget_event(key)
		var m = _carrier.get(key)
		if is_instance_valid(m):
			(m as Node).queue_free()
		_carrier.erase(key)
		_carrier_spot.erase(key)
		_carrier_dead.erase(key)
		if _tower_node.has(key):
			var t = _tower_node[key]
			if is_instance_valid(t):
				(t as Node).queue_free()
		_tower_node.erase(key)
		_tower_point.erase(key)
		_tower_dead.erase(key)
		if key == "salvage":
			if is_instance_valid(_salvage_guard):
				_salvage_guard.queue_free()
			_salvage_guard = null
			_salvage_point = null
			_salvage_killed = false
			_salvage_drop = null
		if key == "hold":
			for e in _hold:
				if is_instance_valid(e):
					(e as Node).queue_free()
			_hold.clear()

## КАКИЕ ЗАДАНИЯ ВЕДЁМ. В игре — все активные; на полигоне ТОЛЬКО ВЫДАННЫЕ РУКАМИ, и это то же
## правило, по которому там живёт спавнер: в мир полигона ничто не входит само. Спрашивать там
## `active_quests` нельзя — полигон одалживает прогресс последнего игранного слота, и сюжет,
## пройденный в настоящей игре, открыл бы свои ветки сам, без единого нажатия.
func _arc_quests() -> Array:
	if G.proving_ground:
		return Q.forced_quests()
	return Q.active_quests()

# ── Ветка «энергия»: панель на опору, затем реген рядом ──────────────────────
# THE STAGE IS A PLACE, NOT AN INVENTORY. Handing the player a panel and a support as loose blocks
# taught nothing: the panel went onto the hull, the machine drove off, and no power appeared -
# a panel only feeds something that STANDS STILL. So the quest builds the answer in the world
# instead: an anchored support of its own, fifty metres out, with the panel lying beside it.
# Mounting that panel on that support is the whole first stage; the repair unit next to it is the
# second.
#
# The site is the factory quest's pattern (_spawn_station): a machine with no cabin, a stationary
# block as its core, anchored from birth. It belongs to the player's faction, so building on it is
# the ordinary build-on-another-machine path and the camera can switch to it.
#
# The site appears AT ONCE, not when the player drives up - the same rule as every other quest
# participant (see EV_SPAWN_DIST). Fifty metres is "visible from where you stand", so the task
# starts as a thing you can see rather than a marker into empty field.
const POWER_SITE_DIST := 50.0
## Levelled pad under the base: the build is three cells across at most, and a support on a slope
## puts the panel over a hole.
const POWER_SITE_HALF := Vector2(3.0, 3.0)
const POWER_SITE_FEATHER := 5.0
## Base cells. The core sits at the centre of the grid - every station layout puts it there, and
## _spawn_station positions the machine by that cell - the panel goes ON TOP of it.
const POWER_CORE_CELL := Vector3i(5, 5, 5)
const POWER_PANEL_CELL := Vector3i(5, 6, 5)
## Where the repair unit may stand: the four cells around the support. The blueprint points at the
## first free one, but ANY of them closes the stage - "beside the support" is the requirement, and
## refusing a neighbouring cell would be a puzzle nobody asked for.
const POWER_REGEN_CELLS := [Vector3i(5, 5, 6), Vector3i(6, 5, 5), Vector3i(4, 5, 5), Vector3i(5, 5, 4)]

var _power_point: Variant = null
var _power_base: Node3D = null

## ЧЕРТЁЖ ПОКАЗЫВАЕМ, ТОЛЬКО КОГДА ИГРОК ДОЕХАЛ. Разметка, зажигающаяся в момент объявления
## задания, — это призраки, висящие на пустом месте всю дорогу до цели: ставить в них нечего, и к
## тому моменту, когда они наконец нужны, игрок перестаёт их замечать.
const PLAN_SHOW_DIST := 20.0

func _plan_near(at: Variant) -> bool:
	if not (at is Vector3):
		return true
	var p: Node3D = _player()
	if p == null:
		return false
	return p.global_position.distance_squared_to(at as Vector3) \
			<= PLAN_SHOW_DIST * PLAN_SHOW_DIST

## Площадка ветки: точка и стоящая на ней база. true — база есть, на неё можно строить.
##
## Ровно ОДНА база за прохождение, и это стоит трёх строк проверки: точка выбирается один раз,
## база подхватывается по метке после перезахода (сейв возвращает её раньше, чем квест успевает
## опомниться), и только если её нет нигде — ставится новая. Без подхвата каждый вход в мир
## добавлял бы к прежней базе ещё одну, в новом случайном месте.
func _power_site() -> bool:
	if is_instance_valid(_power_base):
		return true
	_power_base = _adopt_quest_base("arc_power")
	if is_instance_valid(_power_base):
		_power_point = _power_base.global_position
		return true
	var p: Node3D = _player()
	if p == null:
		return false
	if _power_point == null:
		var ang: float = randf() * TAU
		var wp: Vector3 = p.global_position \
				+ Vector3(cos(ang), 0.0, sin(ang)) * POWER_SITE_DIST
		wp.y = G.ground_y(wp, p.global_position.y)
		_power_point = wp
	_flatten_site(_power_point as Vector3, POWER_SITE_HALF, POWER_SITE_FEATHER)
	_power_base = _spawn_station(_power_point as Vector3, [
		{"x": POWER_CORE_CELL.x, "y": POWER_CORE_CELL.y, "z": POWER_CORE_CELL.z,
		 "block": G.Block.SUPPORT, "rot": [0.0, 0.0, 0.0]},
	])
	if is_instance_valid(_power_base):
		# ТА ЖЕ МЕТКА, ЧТО У КВЕСТОВЫХ ПРЕДМЕТОВ. По ней база узнаётся после перезахода — и уборке
		# мира, и сейву она означает одно и то же: это не мусор, это цель задания.
		#
		# ГОВОРИТ ОДИН. Своя реплика тут повторяла подсказку стадии слово в слово, и задание
		# читалось как выданное дважды: сначала Механик, следом Система, об одном и том же.
		_power_base.set_meta(QuestProps.META, "arc_power")
	return false          # даём кадр: блоки базы появляются асинхронно

## База этого квеста, уже стоящая в мире (перезаход). Ищем по метке, а не по форме: игрок вправе
## поставить свою собственную опору, и отличать их «по похожести» значило бы однажды выдать чужую
## постройку за квестовую.
func _adopt_quest_base(quest_id: String) -> Node3D:
	var vr: Node = get_node_or_null("/root/Main/Vehicles")
	if vr == null:
		return null
	for c in vr.get_children():
		if c is Node3D and c.has_meta(QuestProps.META) \
				and String(c.get_meta(QuestProps.META)) == quest_id:
			return c as Node3D
	return null

## Что стоит в клетке базы. EMPTY — базы нет, сетки нет или клетка пуста.
func _base_block(base: Node3D, cell: Vector3i) -> int:
	if not is_instance_valid(base):
		return G.Block.EMPTY
	var bm = base.get("block_map_node")
	if bm == null or not is_instance_valid(bm) or not bm.has_method("get_block"):
		return G.Block.EMPTY
	return int(bm.get_block(cell.x, cell.y, cell.z))

## Куда показывает чертёж регена: первая свободная клетка рядом с опорой.
func _power_regen_cell() -> Vector3i:
	for c in POWER_REGEN_CELLS:
		if _base_block(_power_base, c) == G.Block.EMPTY:
			return c
	return POWER_REGEN_CELLS[0]

## ЕСТЬ ЛИ ТАКОЙ БЛОК НА БАЗЕ — ГДЕ УГОДНО, А НЕ В ЗАДУМАННОЙ КЛЕТКЕ.
##
## Стадия засчитывалась по ОДНОЙ клетке, и это давало худший из возможных отказов: игрок ставит
## панель на базу, видит её стоящей — а квест считает, что не поставил, и через секунду роняет
## рядом ВТОРУЮ (ensure спрашивает только про мир и про руку). Стоило промахнуться мимо клетки —
## и ветка выдавала панели бесконечно, требуя поставить уже поставленное.
##
## Чертёж по-прежнему показывает, КУДА советуют, но засчитываем факт: блок на базе. Задание
## звучит «поставь панель на опору», а не «попади в клетку (5,6,5)».
func _base_has(base: Node3D, bt: int) -> bool:
	if not is_instance_valid(base):
		return false
	var bm = base.get("block_map_node")
	if bm == null or not is_instance_valid(bm):
		return false
	for c in (bm as Node).get_children():
		if c.get("block") != null and int(c.get("block")) == bt:
			return true
	return false

func _arc_power_1(q: Dictionary) -> void:
	if not _power_site():
		return
	if _base_has(_power_base, G.Block.SOLAR):
		_clear_plan()
		Q.report(String(q["event"]), 1)
		return
	# Панель лежит у базы, пока её не взяли. Условие «у игрока её нет» обязательно: ensure
	# спрашивает только про мир, и без него каждый опрос ронял бы вторую панель, пока игрок везёт
	# первую в руке.
	if not _player_owns(G.Block.SOLAR):
		_props.ensure_orbit("arc_power", G.Block.SOLAR, _power_base)
	# ПАЛЕЦ СНАЧАЛА НА ПАНЕЛЬ, и только потом на клетку. Показывать место установки, пока блок
	# лежит в траве, — значит просить поставить то, чего у игрока ещё нет; а чертёж в этот момент
	# и вовсе висит на другом конце площадки.
	if _props.position_for("arc_power") != null:
		_drop_hints()
		_point_finger("Pick the panel up", "arc_power")
		return
	if _plan_near(_power_point):
		_show_plan_on(_power_base.get("block_map_node"),
				[{"cell": POWER_PANEL_CELL, "block": G.Block.SOLAR}])
		_point_finger("Panel goes on top of the support")
	else:
		_clear_plan()

func _arc_power_2(q: Dictionary) -> void:
	if not _power_site():
		return
	if _base_has(_power_base, G.Block.REGEN):
		_clear_plan()
		Q.report(String(q["event"]), 1)
		return
	# THE REGEN ARRIVES AT THE BASE, NOT AT THE PLAYER. It has to go on THIS base, fifty metres from
	# where the player may be, and a block circling the player meant "now carry it back", in hand,
	# with no guns and a chance to drop it. It circles the BASE the way a reward circles a machine
	# (ensure_orbit) and lands there: the gift is seen, and it is already where it is needed.
	if not _player_owns(G.Block.REGEN):
		_props.ensure_orbit("arc_power", G.Block.REGEN, _power_base)
	# ПАЛЕЦ СНАЧАЛА НА САМ БЛОК, и только потом на клетку — ровно как стадией раньше с панелью.
	# Здесь этой ветки не было, и получалось «поставь ремонтник» при пустых руках: блок лежал в
	# траве, чертёж висел на опоре, а что именно ставить и откуда оно возьмётся, игроку не
	# говорил никто. Про панель это уже было известно и записано — стадия просто не переняла.
	if _props.position_for("arc_power") != null:
		_drop_hints()
		_point_finger("Pick the repair unit up", "arc_power")
		return
	if _plan_near(_power_point):
		_show_plan_on(_power_base.get("block_map_node"),
				[{"cell": _power_regen_cell(), "block": G.Block.REGEN}])
		_point_finger("Repair unit beside the support")
	else:
		_clear_plan()

# ══════════════════════════════════════════════════════════════════════════════
# MARLIT'S LICENCE IS WON IN A FIGHT (arc_yellow)
# ══════════════════════════════════════════════════════════════════════════════
# The player's design: Marlit sends its champion, a machine of the fourth step built of Marlit
# blocks (blocks.MARLIT_CHAMPION, outside the ladder so no ceiling shrinks it), about
# YELLOW_DIST from the player; destroying it is the licence. It used to be a collection point where
# resources were handed in - a TerraTech mission that was not this one - and every load planted
# another point, because the poll ran before the saved base came back; those are swept up
# (`_sweep_yellow_points`) from old saves.
const YELLOW_DIST := 200.0
const CHAMPION_PRESET := 120              # blocks.MARLIT_CHAMPION

var _yellow_point: Variant = null
var _yellow_e: Node3D = null
## SENT, NOT "DEAD": a lost reference after a reload and a dead champion both read false through
## is_instance_valid; only this flag, which lives in memory, tells them apart.
var _yellow_sent: bool = false

func yellow_point() -> Variant:
	return _yellow_point

func _yellow_1(q: Dictionary) -> void:
	if not _yellow_sent:
		var p: Node3D = _player()
		var map: Node = get_node_or_null("/root/Main/map")
		if p == null or (map != null and map.get("terrain_is_ready") == false):
			return
		if _yellow_point == null:
			var ang: float = randf() * TAU
			var wp: Vector3 = p.global_position + Vector3(cos(ang), 0.0, sin(ang)) * YELLOW_DIST
			wp.y = G.ground_y(wp, p.global_position.y)
			_yellow_point = wp
		_yellow_e = _spawn_hostile(get_node_or_null("/root/Main/EnemySpawner"), _yellow_point as Vector3,
				CHAMPION_PRESET)
		if _yellow_e == null:
			return
		_yellow_e.set_meta("story", true)          # the kill marker looks for this first
		_yellow_sent = true
		return
	if is_instance_valid(_yellow_e):
		_yellow_point = _yellow_e.global_position   # the compass follows the champion
		return
	_yellow_sent = false
	_yellow_point = null
	Q.report(String(q["event"]), 1)

## Collection points the old version of this quest planted (one more on every load) leave the world.
## The old points only ever come back from a save, and the save is restored in the first seconds of a
## session; the sweep runs that long (with room for a slow terrain wait) and then stops walking every
## vehicle once a second for the rest of the game.
const YELLOW_SWEEP_TIME := 120.0
var _yellow_sweep_left: float = YELLOW_SWEEP_TIME

func _sweep_yellow_points() -> void:
	if _yellow_sweep_left <= 0.0:
		return
	_yellow_sweep_left -= POLL
	var vr: Node = get_node_or_null("/root/Main/Vehicles")
	if vr == null:
		return
	var cc: Node = get_tree().get_first_node_in_group("camera_controller")
	for c in vr.get_children():
		if c.has_meta(QuestProps.META) and String(c.get_meta(QuestProps.META)) == "arc_yellow":
			if cc != null and "vehicles" in cc:
				(cc.vehicles as Array).erase(c)
			c.queue_free()

# ══════════════════════════════════════════════════════════════════════════════
# БЛОК ВЕЗЁТ ВРАГ: не «съезди и подбери», а «отбери»
# ══════════════════════════════════════════════════════════════════════════════
# Сюжетный блок лежал в чистом поле: игрок ехал по компасу и подбирал его, ни с кем не
# встретившись, — то есть задание было дорогой, а не задачей. Теперь его ВОЗИТ вражеская
# машина, и получить блок можно только разобрав её.
#
# ГЛАВНОЕ ПРАВИЛО: убитый носитель обязан ОСТАВИТЬ блок, даже если тот сгорел в бою. Иначе
# ветка вешается насмерть из-за случайного попадания, а игрок этого не поймёт — он сделал
# ровно то, о чём просили. Поэтому в точке смерти блок ГАРАНТИРУЕТСЯ: лежит настоящий,
# сорванный с носителя, — берём его; не осталось ничего — кладём новый (QuestProps.claim_or_drop).
#
# Носитель появляется, ТОЛЬКО КОГДА ИГРОК ДОЕХАЛ, — то же правило, что у вышек: машина,
# которая с начала игры ездит на другом конце карты, ничего не добавляет, а тикает и стреляет.

var _carrier: Dictionary = {}        # ключ → машина-носитель
var _carrier_spot: Dictionary = {}   # ключ → куда ехать; после боя — где упадёт блок
var _carrier_dead: Dictionary = {}   # ключ → носителя добили
var _carrier_block: Dictionary = {}  # key -> the block the stage is about

## Куда ведёт компас по этой стадии. Пока носитель жив, точка ЕДЕТ ЗА НИМ: он не стоит на
## месте, и метка, оставшаяся там, где его объявили, ведёт в пустое поле (то же правило, что
## у _live_target для событий).
func carrier_point(key: String) -> Variant:
	var m = _carrier.get(key)
	if m != null and is_instance_valid(m) and m is Node3D:
		_carrier_spot[key] = (m as Node3D).global_position
	# Carrier dead and the block already owned (hand, inventory, another machine): nothing is left
	# at the death spot to lead to - the stage waits for it to go on the machine.
	if bool(_carrier_dead.get(key, false)) and _owned_count(int(_carrier_block.get(key, -1))) > 0:
		return null
	return _carrier_spot.get(key, null)

## Стадия «отбери блок у врага». true — носитель уничтожен и блок стоит на машине игрока.
## THE CHECK IS MADE AFTER THE CARRIER DIES, AND ONE ON THE MACHINE IS ENOUGH (the player's rule).
## It used to be "this many on the machine" checked before anything else: the first stage closed
## itself if a radar already stood there (one shot off some carrier earlier), and the second then
## asked for TWO - a radar bolts on by its bottom only and nothing joins on top of one, so the
## second had nowhere obvious to go, sat in the hand, and the stage never closed while its carrier
## drove about with a third. Now the carrier is the task: kill it, and a radar on the machine -
## the one taken from it or one already there - closes the stage. Owned nowhere at all, one is laid
## where it died (`claim_or_drop`); owned but not mounted, the marker leads to the machine's build.
func _carry_stage(key: String, block: int, preset: int) -> bool:
	_carrier_block[key] = block
	var p: Node3D = _player()
	if p == null:
		return false
	if not _carrier_spot.has(key):
		var ang: float = randf() * TAU
		var dist: float = _quest_dist()
		var wp: Vector3 = p.global_position + Vector3(cos(ang) * dist, 0.0, sin(ang) * dist)
		wp.y = G.ground_y(wp, p.global_position.y)
		_carrier_spot[key] = wp
		return false
	# Носителя добили — блок его пережил (или мы кладём такой же на его место).
	if bool(_carrier_dead.get(key, false)):
		if _count_block(block) >= 1:
			return true
		if _owned_count(block) < 1:
			_props.claim_or_drop(key, block, _carrier_spot[key])
		return false
	var at: Vector3 = _carrier_spot[key]
	if is_instance_valid(_carrier.get(key)):
		return false                                  # едет и дерётся — ждём
	_carrier_spawn(key, block, preset, at)
	return false

## МАШИНА ПО ЗАКАЗУ КВЕСТА — ВСЕГДА ЧЕРЕЗ ПОТОЛОК СПАВНЕРА.
##
## Правило «всё, что просит врага, идёт через _tier_cap» жило только в _ev_spawn, а квесты просят
## машины ещё в четырёх местах, и каждое называет пресет ЧИСЛОМ: носитель сюжетного блока, охрана
## груза, волна на базу и дуэль. Дуэль и встретил игрок в первый час: она зашита на пресет 8, а
## копейщик — первая ступень с куполом, против стартовой кабины.
##
## СОЮЗНИКА (фракция 0) не режем: слабый союзник не помогает вообще никак.
## БАЗЫ И ВЫШКИ через потолок не идут намеренно — там сборка часть задания; к спавнеру они
## обращаются на одну дверь ниже, через `_ask_spawner`.
## THE REWARD FOLLOWS WHAT THE QUEST PUT UP. Every hostile a quest spawns reports its death here,
## with the value it was measured at on birth, and the quest's reward is multiplied by the average
## strength of what died (G.strength_of: 1 at step one of the ladder, capped at 3). The same event
## sent against a starter cabin and against a late build used to pay the same 200-420, while the
## builds it sent - chosen by the player's own machine - grew five-fold. `_cur_q` is the quest being
## polled: every spawn happens inside its handler.
var _cur_q: String = ""
var _q_kills: Dictionary = {}           # quest id -> [sum of values, count]

func _on_quest_kill(who, qid: String) -> void:
	if qid == "" or not is_instance_valid(who):
		return
	var e: Array = _q_kills.get(qid, [0.0, 0])
	e[0] = float(e[0]) + float(who.get("build_value") if who.get("build_value") != null else 0)
	e[1] = int(e[1]) + 1
	_q_kills[qid] = e
	Q.set_reward_mult(qid, G.strength_of(float(e[0]) / float(maxi(int(e[1]), 1))))

func _spawn_hostile(sp: Node, at: Vector3, preset: int, faction_id: int = 1, carry: Array = []) -> Node3D:
	if sp == null or not sp.has_method("spawn_at"):
		return null
	var want: int = preset
	if faction_id != 0 and sp.has_method("preset_for_request"):
		want = int(sp.preset_for_request(preset))
	if faction_id != 0:
		want = _faction_preset(sp, want)
	# НА ПОЛИГОНЕ ВЕТКУ ВЫДАЛ САМ ИГРОК, И ЭТО И ЕСТЬ «ЧЕРЕЗ ПАНЕЛЬ». Запрет там стоит на
	# `spawn_at`, чтобы в тот мир никто не заезжал сам; выданный квест самоходным не является —
	# его попросили кнопкой, и смотреть на него без участников нечего. Без этого арка тихо
	# возвращалась ни с чем, и квест висел на первой стадии без врага (Q.force_quest выдаёт
	# только ветки, `_arc_quests` гоняет только их — так что лишнего этот путь не пустит).
	var e: Node3D = _ask_spawner(sp, at, want, faction_id, false, carry)
	if e != null and faction_id != 0 and _cur_q != "" and e.has_signal("died"):
		e.died.connect(_on_quest_kill.bind(_cur_q), CONNECT_ONE_SHOT)
	return e

## AN EVENT SENDS ITS OWN FACTION'S MACHINES (the player's rule): the quest being polled names its
## faction, and a Marlit quest turns the Falsus build it asked for into Marlit's build of the same
## step - the step itself is still the player's ceiling. Builds outside the ladder are left alone.
const MARLIT_BY_STEP := [121, 121, 122, 122, 120, 120]   # runner, raider, champion (blocks.gd)

func _faction_preset(sp: Node, preset: int) -> int:
	if _cur_q == "" or Q.faction_of(Q._find(_cur_q)) != "marlit" or not sp.has_method("_tier_of"):
		return preset
	var t: int = int(sp._tier_of(preset))
	if t < 0:
		return preset
	return int(MARLIT_BY_STEP[mini(t, MARLIT_BY_STEP.size() - 1)])

## Одна дверь к спавнеру для ВСЕХ квестовых машин, ездящих и стоящих: потолок ступени режется
## выше (в `_spawn_hostile`), а здесь только запрет полигона.
func _ask_spawner(sp: Node, at: Vector3, preset: int, faction_id: int, as_base: bool,
		carry: Array = []) -> Node3D:
	var e = null
	if G.proving_ground and sp.has_method("spawn_requested"):
		e = sp.spawn_requested(at, preset, faction_id, as_base, false, carry)
	else:
		e = sp.spawn_at(at, preset, faction_id, as_base, carry)
	if e is Node3D and _cur_q != "":
		(e as Node).set_meta(QUEST_OWNER, _cur_q)   # whose machine it is (_sweep_safe_zones)
	return e as Node3D if e is Node3D else null

func _carrier_spawn(key: String, block: int, preset: int, at: Vector3) -> void:
	var sp: Node = get_node_or_null("/root/Main/EnemySpawner")
	# The block rides ON TOP of the build (blocks.carry): seen from outside, or the player has no way
	# to tell which machine carries it - the marker over an enemy does not say.
	var e: Node3D = _spawn_hostile(sp, at, preset, 1, [block])
	if e == null:
		return
	if e.has_method("assign_target"):
		e.assign_target(_player(), true)
	if e.has_signal("died"):
		e.died.connect(func(_x = null): _on_carrier_died(key), CONNECT_ONE_SHOT)
	_carrier[key] = e

func _on_carrier_died(key: String) -> void:
	# Точку смерти запоминаем ЗДЕСЬ: carrier_point обновляет её каждый опрос, пока носитель жив,
	# но после гибели узел уже освобождён и спросить его не у кого.
	var m = _carrier.get(key)
	if m != null and is_instance_valid(m) and m is Node3D:
		_carrier_spot[key] = (m as Node3D).global_position
	_carrier_dead[key] = true
	_carrier.erase(key)

# ── The radar branch: take it off the machine that carries it ────────────────
## ONE STAGE (the player's call): a second carrier with a second radar was the same fight again
## for a block the machine already had. Preset 5 is the scout, the weakest build: the first machine
## the player strips for a trophy, and losing to it would stall the story at its second step.
func _arc_radar_1(q: Dictionary) -> void:
	if _carry_stage("arc_radar", G.Block.RADAR, 5):
		Q.report(String(q["event"]), 1)

# ── Ветка «аккумулятор»: жила его ДЕРЖИТ, пока её не выработают ──────────────
# Аккумулятор лежал в поле, как и всё остальное, и «Buried Charge» ничем не отличался от
# прогулки по компасу. Теперь он ВНУТРИ ЖИЛЫ: пока в ней есть руда, блока нет — выкопай её
# досуха, и он выпадет. Это и единственный сюжетный повод взять бур в руки после обучения.
#
# ЖИЛУ НЕ ДЕРЖИМ ССЫЛКОЙ, только точку. Жилы стримятся (узел живёт лишь рядом с камерой), и
# ссылка на неё после отъезда протухает; точка же верна всегда, а узел по ней находится тогда,
# когда игрок рядом, — то есть ровно когда его и надо спрашивать.
const BATTERY_DIST := 140.0
const BATTERY_REACH := 60.0

var _bat_spot: Variant = null       # где стоит «та самая» жила
var _bat_free: bool = false         # её выработали, блок выпал
## ПОКАЗАННЫЙ В ЖИЛЕ БЛОК. Задание говорит «он в этой жиле», а на экране до последнего удара была
## обычная руда: игрок бурил наугад и верил на слово. Кладём настоящий блок сверху на жилу —
## видно, что именно там лежит и что за это бурят.
var _bat_shown: Node3D = null
## IT HANGS IN A TREE'S BRANCHES (the player's call): the errand is a TREE now, never an ore vein
## (`vein_point_near` / `node_near` with `wood_only`), and the block is caught on the lowest tier of
## needles, out at its skirt and tipped over, where it is seen from the ground. Felling the tree is
## what brings it down - the tree goes on its last blow, and the block drops where it stood.
## Per tree model (resource_nodes TREE_*, vein_models.gd): the point it hangs at in the tree's own
## frame - between the broadleaf's branches, between the teal tree's two trunks under its crown,
## under the palm's fronds (its top leans out along +X) - and how far out from that point it is
## pushed, in a random direction.
const BATTERY_SHOW := [[Vector3(0.0, 2.05, 0.0), 0.45], [Vector3(0.0, 1.85, 0.0), 0.2],
		[Vector3(0.9, 3.5, 0.25), 0.3]]
const BATTERY_SHOW_TILT := 0.45        # tipped on what it is caught on, rad
## Сколько от него осталось. Тридцать процентов — это и «видно, что он побитый» (красные цифры
## хп над блоком), и повод дать игроку реген или ремонт, а не бесплатную целую деталь.
const BATTERY_WORN_FRAC := 0.3

## Посадка блока в жиле, посчитанная ОДИН РАЗ. Жилы стримятся: узел появляется и исчезает вместе
## с игроком, а _bat_display пересоздаёт блок каждый раз. Считай мы поворот заново — блок бы
## заметно прыгал при каждом возвращении к жиле.
var _bat_pose: Variant = null
## Побитость выдаётся один раз: иначе опрос раз в секунду срезал бы хп заново и починить
## выпавший аккумулятор было бы нельзя вовсе.
var _bat_worn: bool = false

## Куда ведёт компас по этой ветке.
func battery_point() -> Variant:
	return _bat_spot

## Общая половина обеих стадий: довести игрока до жилы и дождаться, пока он её выскребет.
## true — аккумулятор уже стоит на машине.
func _battery_stage() -> bool:
	if _has_block(G.Block.BATTERY):
		return true
	var p: Node3D = _player()
	if p == null:
		return false
	if _bat_spot == null:
		# ТОЧКА — НА НАСТОЯЩЕЙ ЖИЛЕ, а не рядом с ней. Раньше здесь бралось случайное направление
		# на BATTERY_DIST, и метка вела в поле: жила находилась только когда игрок подъезжал на
		# BATTERY_REACH и она успевала стримнуться. Снаружи это «показывает рядом».
		#
		# Данные о жилах есть заранее — они считаются от сида по регионам вокруг игрока, без
		# всякой отрисовки (resource_nodes.vein_point_near).
		var rnd: Node = get_node_or_null("/root/Main/map/Resource_Nodes")
		if rnd == null:
			rnd = _find_resource_nodes()
		var exact: Variant = null
		if rnd != null and rnd.has_method("vein_point_near"):
			exact = rnd.vein_point_near(p.global_position, BATTERY_DIST * 0.6, BATTERY_DIST * 1.6, true)
		if exact != null:
			_bat_spot = exact
		else:
			# Жил вокруг нет вовсе (редко: край карты, выработанный район) — держим прежнее
			# поведение, иначе ветка не начнётся никогда.
			var ang: float = randf() * TAU
			var wp: Vector3 = p.global_position + Vector3(cos(ang) * BATTERY_DIST, 0.0, sin(ang) * BATTERY_DIST)
			wp.y = G.ground_y(wp, p.global_position.y)
			_bat_spot = wp
		return false
	var at: Vector3 = _bat_spot as Vector3
	if _bat_free:
		_bat_drop(at)
		return false
	if p.global_position.distance_squared_to(at) > BATTERY_REACH * BATTERY_REACH:
		return false
	# Доехал. Настоящая жила рядом с объявленной точкой — к ней и подтягиваем метку, иначе
	# компас указывает на пустую землю в паре метров от того, что надо бурить.
	var rn: Node = get_node_or_null("/root/Main/map/Resource_Nodes")
	if rn == null:
		rn = _find_resource_nodes()
	if rn == null or not rn.has_method("node_near"):
		_bat_free = true                      # жил в мире нет вовсе — не держим игрока
		_bat_drop(at)
		return false
	var vein: Node = rn.node_near(at, BATTERY_REACH, true)
	if vein == null:
		return false                          # ещё не стримнулась — подождём следующий опрос
	_bat_spot = (vein as Node3D).global_position
	if vein.call("is_depleted"):
		_bat_free = true
		_bat_hide()
		_bat_drop(_bat_spot as Vector3)       # в ТОТ ЖЕ проход, а не следующим опросом
	else:
		_bat_display(vein as Node3D)
	return false

## УРОНИТЬ АККУМУЛЯТОР. Вынесено отдельно ровно затем, чтобы звалось СРАЗУ по выработке жилы, а
## не следующим опросом. Раньше между «жила кончилась» и «блок лежит» проходило ДВА прохода по
## POLL: один ставил флаг, второй ронял. Две секунды на пустом месте, и выглядело это как будто
## квест подвис.
##
## ВЫПАДАЕТ ИЗ ЖИЛЫ, А НЕ ВЫДАЁТСЯ НАГРАДОЙ: claim_or_drop кладёт настоящий блок в мир у точки
## жилы, и подобрать его игрок должен сам. Награда квеста — деньги и опыт (quest_manager:
## 210/45/14), блоков в ней нет и быть не должно.
func _bat_drop(at: Vector3) -> void:
	if _player_owns(G.Block.BATTERY):
		return
	var dropped: Node3D = _props.claim_or_drop("arc_battery", G.Block.BATTERY, at)
	if dropped != null and not _bat_worn:
		_bat_worn = true
		_wear_battery(dropped)

## Показать блок в жиле. Жилы СТРИМЯТСЯ — узел появляется и исчезает вместе с игроком, — поэтому
## показ проверяется каждый опрос и восстанавливается, а не ставится один раз.
##
## Блок настоящий, но ИНЕРТНЫЙ: слои коллизии сняты уже ПОСЛЕ add_child, потому что VehicleBlock
## ставит себе второй слой в своём _ready. Без этого его можно было бы подобрать прямо из породы
## (луч постройки бьёт по второму слою) и по нему стреляли бы враги — цель у оружия ищется там же.
func _bat_display(vein: Node3D) -> void:
	if is_instance_valid(_bat_shown) and _bat_shown.get_parent() == vein:
		return
	_bat_hide()
	var scene: PackedScene = G.get_scene(G.Block.BATTERY)
	if scene == null:
		return
	var n: Node3D = scene.instantiate()
	vein.add_child(n)
	if _bat_pose == null:
		var ang: float = randf() * TAU
		var outward := Vector3(cos(ang), 0.0, sin(ang))
		var kind: int = clampi(int(vein.get("tree_kind")) if vein.get("tree_kind") != null else 0,
				0, BATTERY_SHOW.size() - 1)
		var at: Vector3 = BATTERY_SHOW[kind][0]
		# tipped outward, down the slope of what it is caught on
		_bat_pose = Transform3D(
			Basis(outward.cross(Vector3.UP).normalized(), -BATTERY_SHOW_TILT) * Basis(Vector3.UP, randf() * TAU),
			at + outward * float(BATTERY_SHOW[kind][1]))
	# the pose is in the MODEL's axes; the tree stands turned and scaled (resource_nodes TREE_SCALE)
	var vb: Basis = vein.get_meta("vein_basis") if vein.has_meta("vein_basis") else Basis()
	var pose := _bat_pose as Transform3D
	n.transform = Transform3D(vb.orthonormalized() * pose.basis, vb * pose.origin)
	if n is RigidBody3D:
		var rb := n as RigidBody3D
		rb.freeze = true
		rb.collision_layer = 0
		rb.collision_mask = 0
	_wear_battery(n)
	_bat_shown = n

## Сбить блоку хп до BATTERY_WORN_FRAC и обновить красные цифры над ним. Показанный в жиле блок
## инертен, так что для него это чистая картинка; выпавшему это реальное состояние.
func _wear_battery(n: Node) -> void:
	if n == null or not is_instance_valid(n) or not ("max_hp" in n):
		return
	n.set("current_hp", maxi(int(round(float(n.get("max_hp")) * BATTERY_WORN_FRAC)), 1))
	if n.has_method("_refresh_hp_fx"):
		n.call("_refresh_hp_fx")

func _bat_hide() -> void:
	if is_instance_valid(_bat_shown):
		_bat_shown.queue_free()
	_bat_shown = null

## Узел стриминга жил. Путь в сцене не зашиваем: он уже переезжал, а группы у узла нет —
## ищем по методу, которого больше ни у кого нет.
func _find_resource_nodes() -> Node:
	var main: Node = get_node_or_null("/root/Main")
	if main == null:
		return null
	for c in main.get_children():
		if c.has_method("active_blips"):
			return c
		for g in c.get_children():
			if g.has_method("active_blips"):
				return g
	return null

func _arc_battery_1(q: Dictionary) -> void:
	# Первая стадия — ДОЕХАТЬ до жилы: до неё полтораста метров, и это отдельный шаг, иначе
	# «найди и выкопай» закрывается одним событием и читается как одна кнопка.
	if _battery_stage():
		Q.report(String(q["event"]), 1)   # аккумулятор уже стоит — «доехать» закрываем сразу
		return
	var p: Node3D = _player()
	if p != null and _bat_spot is Vector3 \
			and p.global_position.distance_squared_to(_bat_spot as Vector3) \
				<= BATTERY_REACH * BATTERY_REACH:
		Q.report(String(q["event"]), 1)

func _arc_battery_2(q: Dictionary) -> void:
	if _battery_stage():
		Q.report(String(q["event"]), 1)

# ── «Salvage Run»: сбитый груз под охраной ───────────────────────────────────
# Замена станции из оригинала. Магазинов у нас нет, поэтому «доехать до станции и отбить её»
# превращается в «доехать до груза и отбить его», а наградой становится КОЛЛЕКТОР — блок, без
# которого не собрать производственную цепочку в следующем квесте.

var _salvage_point: Variant = null
var _salvage_guard: Node3D = null

## Куда ведёт компас на первой стадии. Цель — координаты, а не предмет, поэтому мимо QuestProps.
func salvage_point() -> Variant:
	return _salvage_point

func _salvage_1(q: Dictionary) -> void:
	var p: Node3D = _player()
	if p == null:
		return
	if _salvage_point == null:
		_salvage_point = _far_point(p)
		return
	# A guard the player killed on the way stays dead: it hunts the player, so it is often met
	# before the point is.
	if not _salvage_killed:
		_salvage_spawn_guard()
	if not _reached(_salvage_point):
		return
	Q.report(String(q["event"]), 1)

var _salvage_killed: bool = false

## A QUEST POINT A MACHINE CAN DRIVE TO, at the one spawn distance (`_quest_dist`). Of `FAR_TRIES`
## directions round the player the one with the gentlest ground and the least climb wins: one random
## direction put Salvage Run's cargo on a mountain, where its guard landed on a peak and the marker
## stood over a slope nobody could drive up. A height costs ~0.1 ms, so the probes are few.
const FAR_TRIES := 8
const FAR_PROBE := 6.0             # m off the point the slope is read at

func _far_point(p: Node3D) -> Vector3:
	var base_ang: float = randf() * TAU
	var dist: float = _quest_dist()
	var py: float = p.global_position.y
	var best := Vector3.ZERO
	var best_score := INF
	for i in FAR_TRIES:
		var ang: float = base_ang + TAU * float(i) / float(FAR_TRIES)
		var wp: Vector3 = p.global_position + Vector3(cos(ang) * dist, 0.0, sin(ang) * dist)
		var h: float = G.ground_y(wp, py)
		var slope: float = maxf(absf(G.ground_y(wp + Vector3(FAR_PROBE, 0.0, 0.0), h) - h),
				absf(G.ground_y(wp + Vector3(0.0, 0.0, FAR_PROBE), h) - h))
		# metres of rise over FAR_PROBE weigh most; a long climb from the player counts too; the jitter
		# keeps two flat candidates from always resolving the same way
		var score: float = slope * 4.0 + absf(h - py) * 0.25 + randf() * 2.0
		if score < best_score:
			best_score = score
			best = Vector3(wp.x, h, wp.z)
	return best

## Охрана груза. Отдельной функцией, потому что зовут её ДВА раза: при первом приезде и
## тогда, когда охраны не стало не от выстрелов (перезаход, вылет — врагов мы не сохраняем).
func _salvage_spawn_guard() -> void:
	if is_instance_valid(_salvage_guard) or not (_salvage_point is Vector3):
		return
	var sp: Node = get_node_or_null("/root/Main/EnemySpawner")
	# THE GUARD CARRIES THE COLLECTOR, it does not lie beside it: cargo at the feet of the beaten
	# reads as a reward for a tick-box, a block taken off a machine you had to strip as a trophy. On
	# top of the build (blocks.carry), seen on the approach - the same rule as `_carrier_spawn`.
	_salvage_guard = _spawn_hostile(sp, _salvage_point as Vector3 + Vector3(12.0, 0.0, 0.0), 7, 1,
		[G.Block.COLLECTOR])
	if _salvage_guard == null:
		return
	if _salvage_guard.has_method("assign_target"):
		_salvage_guard.assign_target(_player(), true)
	# Смерть ЗАПОМИНАЕМ. Пустая ссылка сама по себе не означает победу: после загрузки она
	# пуста всегда, и без этого флага квест проходился бы выходом в меню.
	if _salvage_guard.has_signal("died"):
		_salvage_guard.died.connect(_on_salvage_guard_died, CONNECT_ONE_SHOT)

## Where the guard died is where its collector fell: it hunts the player and is often killed far
## from the cargo point, where `claim_or_drop`'s 30 m search would never see it and dropped a second.
var _salvage_drop = null

func _on_salvage_guard_died(_e = null) -> void:
	_salvage_killed = true
	if is_instance_valid(_salvage_guard):
		_salvage_drop = _salvage_guard.global_position

func _salvage_2(q: Dictionary) -> void:
	if is_instance_valid(_salvage_guard):
		return
	# A reload in this stage forgets the point (memory only), and with no point the guard was never
	# sent again: the stage hung for good. A new point, and the guard comes from there.
	if not (_salvage_point is Vector3):
		var p: Node3D = _player()
		if p == null:
			return
		_salvage_point = _far_point(p)
	if not _salvage_killed:
		_salvage_spawn_guard()      # охрана пропала не от выстрелов — присылаем снова
		return
	# Охрана кончилась — коллектор наш. Он ЕХАЛ НА НЕЙ, поэтому обычно уже лежит там же,
	# сорванный с корпуса: claim_or_drop усыновляет такой, а кладёт новый, только если блок
	# сгорел в бою. Молча в инвентарь не отдаём — трофей игрок должен увидеть и подобрать.
	if not _player_owns(G.Block.COLLECTOR):
		var at: Vector3 = _salvage_drop if _salvage_drop is Vector3 else _salvage_point as Vector3
		_props.claim_or_drop("arc_salvage", G.Block.COLLECTOR, at)
		return                              # даём кадр, чтобы предмет появился
	Q.report(String(q["event"]), 1)
	_salvage_point = null

# ── «Production Line»: собрать цепочку и включить её ─────────────────────────
## ПЛОЩАДКА, А НЕ СПИСОК ПОКУПОК. Раньше стадия просто ждала, пока нужные блоки окажутся на
## машине игрока, — то есть требовала купить их и ничему не учила. Теперь квест САМ кладёт
## в мир всё, что нужно: заякоренного продавца с одной лентой (готовый «выход» линии) и
## рядом на земле — приёмник и остальные ленты. Собрать из этого работающую цепочку и есть
## задание, а проверяется оно по РЕАЛЬНОЙ связи блоков, а не по их наличию.
##
## КОЛЛЕКТОРА в наборе нет намеренно. В цепочку он не входит: по ленте не передаёт ничего
## (это VehicleBlock, без выходов и push_item), а руду с земли приёмник берёт и сам.
const LINE_DIST := 70.0        # как далеко от игрока появляется площадка
const LINE_REACH := 50.0       # ближе этого — материализуем; дальше игрок её и не видит
## Сколько лент КЛАСТЬ НА ЗЕМЛЮ — считается ПО СХЕМЕ, а не задаётся числом. Было отдельной
## константой (LINE_BELTS = 5, минус одна на продавце = четыре), а в схеме лент четыре, одна из
## которых уже стоит: игроку выдавали ЛИШНЮЮ, и она оставалась валяться у площадки как деталь,
## которой некуда встать. Два числа про одно и то же однажды разъезжаются — это и был тот раз.
const LINE_ORE := 3            # how many ores drop on the receiver per batch
const LINE_GIFT_DELAY := 8.0   # через сколько секунд после сборки выдаём процессор
## COPPER ORE, not the copper ingot this used to be ("m1"). The branch is the lesson "ore sells for
## scraps, metal does not": the first batch sells raw, the second goes through the processor. With an
## ingot there was nothing to convert, and since the processor now refuses what it cannot upgrade,
## the demo batch would ride straight past it.
const LINE_ORE_KIND := "ore1"

var _line_point: Variant = null
var _line_base: Node3D = null          # заякоренная база-продавец, которую положил квест
var _line_gift_t: float = -1.0         # обратный отсчёт до выдачи процессора (−1 — не идёт)
var _line_gifted: bool = false

## СХЕМА ЛИНИИ в клетках базы (центр сетки — клетка 5). Лента идёт от продавца ПРЯМО, одной
## полосой по +Z, а приёмник стоит в её конце — так линия читается с одного взгляда и учит
## главному: материал едет ОТ приёмника К продавцу.
##
## Ни одного поворота здесь нет намеренно. У ленты вход сзади (+Z), выход спереди (−Z) —
## значит, выложенная по оси Z полоса гонит груз к продавцу сама, и объяснять игроку, каким
## боком ставить блок, на первой же фабрике не нужно.
##
## Клетка (5,5,6) в списке есть, но её ставит сам квест: подсказка на неё не появится, зато
## схема остаётся ЦЕЛОЙ — по ней же проверяется, что линия сложена так, как задумано.
## "yaw" on every entry: on this line the turn IS the function (a reversed belt carries away from
## the seller, a turned processor links to nothing), so the ghost stays until the block is turned
## as drawn — see BuildHint.create.
const LINE_PLAN := [
	{"cell": Vector3i(5, 5, 6),  "block": G.Block.BELT,     "yaw": 0.0},
	{"cell": Vector3i(5, 5, 7),  "block": G.Block.BELT,     "yaw": 0.0},
	{"cell": Vector3i(5, 5, 8),  "block": G.Block.BELT,     "yaw": 0.0},
	{"cell": Vector3i(5, 5, 9),  "block": G.Block.BELT,     "yaw": 0.0},
	{"cell": Vector3i(5, 5, 10), "block": G.Block.RECEIVER, "yaw": 0.0},
]
## Куда встаёт процессор: СБОКУ ОТ ЛИНИИ, а не в её разрыв. Якорь (4,5,8), футпринт 2×2×2
## занимает x∈{3,4}, z∈{7,8} — все четыре клетки СЛЕВА от ленты, сама линия остаётся целой.
##
## Так это и работает в TerraTech: конвейер идёт своей полосой, станок стоит возле него и
## снимает груз с неё. Раньше процессор занимал две клетки самой линии, то есть вставал ВМЕСТО
## ленты, и собранная линия рвалась ровно там, где игрок ставил станок.
##
## Обмен идёт правым бортом процессора (+X), и обе клетки борта уже настроены в сцене:
## ближняя к приёмнику (4,5,8) — ВХОД (маска input_faces), дальняя (4,5,7) — ВЫХОД
## (port_defaults). Значит груз сходит с ленты в станок и возвращается на ленту НА КЛЕТКУ
## БЛИЖЕ к продавцу, то есть поток никуда не разворачивается.
const LINE_PROC_PLAN := [
	{"cell": Vector3i(4, 5, 8), "block": G.Block.PROCESSOR, "yaw": 0.0},
]

var _hints: Array = []

## Сколько лент выкладывать на землю: СЧИТАЕМ ПО ФАКТУ — клетки схемы, в которых ленты ещё нет.
##
## Было две константы про одно и то же (лент в схеме и «сколько уже стоит»), и они разъезжались
## ровно так, как и положено двум числам об одном: игрок получал не столько лент, сколько просит
## чертёж. Теперь вопрос задаётся самой базе, и ответ не может разойтись с тем, что на ней стоит.
func _belts_to_drop() -> int:
	var need: int = 0
	for e in LINE_PLAN:
		if int(e["block"]) != G.Block.BELT:
			continue
		if _base_block(_line_base, e["cell"]) != G.Block.BELT:
			need += 1
	return need

## Куда ведёт компас, пока площадка не появилась.
func line_point() -> Variant:
	return _line_point

## Разметка: белый призрак блока в каждой клетке схемы (build_hint.gd). Показывает форму,
## клетку и поворот — то, чего текст задания сказать не может.
func _show_plan(plan: Array) -> void:
	if _line_base == null or not is_instance_valid(_line_base):
		_clear_plan()
		return
	_show_plan_on(_line_base.get("block_map_node"), plan)

## То же самое, но на ЛЮБОЙ машине. Разметка сначала умела только площадку фабрики, потому что
## только там квест сам расставлял блоки. А объяснить «опора сзади, панель НА опоре» текстом
## нельзя вовсе: игрок читает «прикрепите панель», вешает её на борт, и она не работает —
## панель даёт ток только на якоре, а якорь держится на опоре. Призрак говорит это молча.
func _show_plan_on(bm, plan: Array) -> void:
	if bm == null or not is_instance_valid(bm):
		_clear_plan()
		return
	# Пересобираем только когда РАЗМЕТКА ДРУГАЯ. Условия квестов опрашиваются раз в секунду, а
	# _clear_plan убивает узлы: без этой проверки призраки пересоздавались бы каждый опрос и
	# заметно мигали, да и палец наставника сбрасывался бы вместе с ними.
	var sig := "%s|%s" % [bm.get_instance_id(), plan]
	if sig == _plan_sig:
		return
	_plan_sig = sig
	_clear_plan()
	for e in plan:
		var cell: Vector3i = e["cell"]
		# An entry with a "yaw" wants the block TURNED that way (see BuildHint.create).
		var yaw: float = float(e["yaw"]) if e.has("yaw") else NAN
		# Клетка уже занята нужным блоком (её поставил квест) — разметка ей не нужна.
		if BuildHint.satisfied_by(bm, cell, int(e["block"]), yaw):
			continue
		var h := BuildHint.create(bm, cell, int(e["block"]),
				Vector3(0.0, 0.0 if is_nan(yaw) else yaw, 0.0), not is_nan(yaw))
		if h != null:
			_hints.append(h)

var _plan_sig: String = ""

func _clear_plan() -> void:
	_drop_hints()
	_point_finger("")

## Убрать только ПРИЗРАКОВ, не трогая палец: пока предмет лежит в мире, чертёж не нужен, а палец
## нужен — он показывает на сам предмет.
func _drop_hints() -> void:
	for h in _hints:
		if is_instance_valid(h):
			(h as Node).queue_free()
	_hints.clear()
	_plan_sig = ""

## Палец наставника на БЛИЖАЙШУЮ незакрытую клетку схемы. Тот же палец, что в обучении:
## второй такой указатель заводить незачем, а привычка у игрока уже есть.
##
## Пустой текст — убрать. Ничего не блокируем (Gate.OFF) и не предлагаем пропустить
## обучение: это сюжетное задание, а не вводная.
var _finger_text: String = ""

## `prop_quest` — палец наводится на ПРЕДМЕТ этого квеста, пока тот лежит в мире, и только потом
## на ближайшую клетку чертежа.
## THE KIT GETS THE FINGER BEFORE THE CELL DOES, the rule _arc_power_1 follows: pointing at an
## empty cell while the player has nothing to put in it asks for a part they do not have yet. The
## finger goes to a part lying by the seller until the player holds something the plan still needs.
## Unlike the power branch the ghosts STAY UP: the shape of the whole line is the lesson, and with
## four parts on the ground hiding it until each was picked up would hide it most of the stage.
func _line_finger(place_text: String, plan: Array) -> void:
	if _misturned(plan):
		_point_finger("Turned the wrong way — match the white outline")
		return
	if not _can_place_any(plan) and _props.position_for("arc_line") != null:
		_point_finger("Pick up the parts lying by the seller", "arc_line")
		return
	_point_finger(place_text)

## The right block in a planned cell, turned otherwise than drawn. Measured: a processor set at 90°
## on its cell was accepted by the grid, linked to nothing, and the type-only ghost vanished — no
## outline, no finger, and a stage that never finished.
func _misturned(plan: Array) -> bool:
	if not is_instance_valid(_line_base):
		return false
	var bm = _line_base.get("block_map_node")
	for e in plan:
		if not e.has("yaw"):
			continue
		var c: Vector3i = e["cell"]
		var bt: int = int(e["block"])
		if _base_block(_line_base, c) == bt and not BuildHint.satisfied_by(bm, c, bt, float(e["yaw"])):
			return true
	return false

## A block for a still-open cell of the plan, in the inventory or in the hand. _player_owns cannot
## answer this: it counts the base as well, and the base already carries a belt.
func _can_place_any(plan: Array) -> bool:
	for e in plan:
		var bt: int = int(e["block"])
		if _base_block(_line_base, e["cell"]) == bt:
			continue
		if G.block_inventory.has(bt) or _in_hand(bt):
			return true
	return false

func _point_finger(text: String, prop_quest: String = "") -> void:
	var guide: Node = get_tree().get_first_node_in_group("tutorial_guide")
	if guide == null:
		return
	_finger_prop = prop_quest
	if text == "" or (_finger_point_prop() == null and _next_hint() == null):
		if _finger_text != "" and guide.has_method("is_active") and guide.is_active():
			guide.clear()
		_finger_text = ""
		return
	if not guide.has_method("point_at_world"):
		return
	# Взводим ОДИН РАЗ на текст: сам палец каждый кадр спрашивает у нас точку заново
	# (_finger_point), поэтому переставлять его на каждом опросе незачем — он от этого мигал бы.
	var key := text + "|" + prop_quest
	if _finger_text == key and guide.has_method("is_active") and guide.is_active():
		return
	_finger_text = key
	guide.point_at_world(_finger_point, tr(text), false, TutorialGuide.Gate.OFF, false)

## Куда смотрит палец ПРЯМО СЕЙЧАС. Именованный метод, а не лямбда в списке аргументов: лямбда,
## перенесённая на вторую строку, становится лишним аргументом вызова, и это валидный синтаксис
## (см. CLAUDE.md).
var _finger_prop: String = ""

func _finger_point() -> Vector3:
	var at = _finger_point_prop()
	if at != null:
		return at as Vector3
	var h = _next_hint()
	if h == null:
		return Vector3.ZERO
	var cam := get_viewport().get_camera_3d()
	return (h as BuildHint).tap_point(cam.global_position if cam != null else (h as Node3D).global_position)

func _finger_point_prop() -> Variant:
	if _finger_prop == "":
		return null
	var want: int = _wanted_type()
	if want >= 0 and _props.has_loose(_finger_prop, want):
		return _props.position_for(_finger_prop, want)
	return _props.position_for(_finger_prop)

## Ближайшая к игроку живая подсказка (или null, если разметка закрыта целиком).
func _next_hint():
	_hints = _hints.filter(func(h): return is_instance_valid(h))
	var p: Node3D = _player()
	return BuildHint.pick(_hints, -1, p.global_position if p != null else Vector3.ZERO)

## The type the plan can take now (`BuildHint.pick`'s first reachable ghost), or -1: the part the
## "pick up" finger goes to, so a receiver lying nearest is not offered before the belts it ends.
func _wanted_type() -> int:
	var h = _next_hint()
	return (h as BuildHint).block_type if h != null and (h as BuildHint).reachable() else -1

# ── Solvent: ten things sold through the line ─────────────────────────────────
# THE MECHANIC SAYS WHAT TO DO (the player's call: the quest used to be a bare "earn 600$" with no
# word on how). One line at the start, one at half way, and a reminder once nothing has sold for
# SOLVENT_NUDGE seconds. Memory only, like every stage: a reload says the opening again.
const SOLVENT_NUDGE := 120.0
var _solvent_said: int = -1        # the progress the last line was said at; -1 = not opened yet
var _solvent_idle: float = 0.0

func _solvent(q: Dictionary) -> void:
	var p: int = int(q.get("progress", 0))
	if _solvent_said < 0:
		_solvent_said = p
		_solvent_idle = 0.0
		Dialogue.say_lines([
			["Mechanic", tr("The System wants proof the line pays. Sell ten loads through the seller: raw ore, ingots, wood, coal - anything it takes counts.")],
			["Mechanic", tr("Ore goes into the receiver, rides the belts and leaves through the seller. Drill a vein near the line, or bring ore in the collector and park beside the receiver.")],
		])
		return
	if p != _solvent_said:
		if _solvent_said < 5 and p >= 5 and p < int(q.get("goal", 10)):
			Dialogue.say("Mechanic", tr("Half way. Keep the line fed."))
		_solvent_said = p
		_solvent_idle = 0.0
		return
	_solvent_idle += POLL
	if _solvent_idle >= SOLVENT_NUDGE:
		_solvent_idle = 0.0
		Dialogue.say("Mechanic", tr("Nothing has sold for a while. Is the receiver getting ore? It takes what lies on the ground beside it and what a parked collector carries."))


func _line_1(q: Dictionary) -> void:
	var p: Node3D = _player()
	if p == null:
		return
	_line_adopt()
	if _line_point == null:
		_line_point = _line_site_by_vein(p.global_position)
		if _line_point == null:
			var ang: float = randf() * TAU
			var wp: Vector3 = p.global_position + Vector3(cos(ang) * LINE_DIST, 0.0, sin(ang) * LINE_DIST)
			wp.y = G.ground_y(wp, p.global_position.y)
			_line_point = wp
		return
	# Материализуем ТОЛЬКО когда игрок рядом. База — это машина со своей физикой и фабрикой;
	# ставить её за горизонт значит держать всё это работающим там, куда игрок ещё не доехал.
	if p.global_position.distance_squared_to(_line_point as Vector3) > LINE_REACH * LINE_REACH:
		return
	if not _dropped.has("line_kit"):
		_dropped["line_kit"] = true
		_spawn_line_kit(_line_point as Vector3)
		return                          # даём кадр, чтобы база собралась
	# Готово, когда цепочка РЕАЛЬНО собрана: от приёмника есть путь до продавца.
	var recv: Node = _find_in_base(G.Block.RECEIVER)
	if recv == null or not _chain_reaches(recv, G.Block.SELLER):
		# EVERY POLL, not once in _spawn_line_kit: the ghosts live in memory and a reload takes
		# them, while _line_adopt marks the kit as already dropped. Measured: after a reload in this
		# stage the player had zero ghosts and no finger. _show_plan is idempotent (_plan_sig).
		_show_plan(LINE_PLAN)
		_line_finger("Belt by belt along the line — receiver goes at the far end.", LINE_PLAN)
		return
	_clear_plan()
	_drop_ore_over(recv, LINE_ORE)      # линия жива — вот ей и работа
	_line_gift_t = LINE_GIFT_DELAY
	Q.report(String(q["event"]), 1)

func _line_2(q: Dictionary) -> void:
	_line_adopt()
	# HANDED OUT BEFORE A RELOAD ALREADY — on a machine, in the inventory or the hand, or lying by
	# the seller. _line_gifted lives in memory, so every reload used to run the countdown again and
	# drop a SECOND processor, with eight seconds of nothing on screen before it.
	if not _line_gifted and (_player_owns(G.Block.PROCESSOR)
			or _props.has_loose("arc_line", G.Block.PROCESSOR)):
		_line_gifted = true
	# Процессор выдаём НЕ сразу: игрок должен увидеть, как первая партия проехала по ленте и
	# продалась. Подарок посреди этого зрелища его бы и перебил.
	if not _line_gifted:
		if _line_gift_t < 0.0:
			_line_gift_t = LINE_GIFT_DELAY
		_line_gift_t -= POLL
		if _line_gift_t > 0.0:
			return
		_line_gifted = true
		Dialogue.say("System", tr("Processor delivered. It stands BESIDE the line, left of the middle belt — the belts stay where they are. It takes ore off the belt and puts the ingot back on it."))
	# A QUEST ITEM, NOT AN AWARD. award_blocks threw it into the world untagged: the finger could
	# not find it, and ten minutes on the ground (world_persist.BLOCK_TTL) deleted it with the branch
	# still waiting. It keeps the award's orbit, around the line base, and is tagged from the start.
	if not _player_owns(G.Block.PROCESSOR):
		_props.ensure_orbit("arc_line", G.Block.PROCESSOR, _line_base)
	var recv: Node = _find_in_base(G.Block.RECEIVER)
	var proc: Node = _find_in_base(G.Block.PROCESSOR)
	# CUT IN MEANS BOTH WAYS: ore reaches the processor AND the ingot reaches the seller. The
	# input alone used to pass, with the output facing nothing, and the demo ore then sat inside.
	if recv == null or proc == null or not _chain_reaches(recv, G.Block.PROCESSOR) \
			or not _chain_reaches(proc, G.Block.SELLER):
		_show_plan(LINE_PROC_PLAN)
		_line_finger("Processor goes here — beside the line, not into it.", LINE_PROC_PLAN)
		return                          # процессор ещё не врезан в линию
	_clear_plan()
	_drop_ore_over(recv, LINE_ORE)      # и снова руда — проверить, что линия не развалилась
	Q.report(String(q["event"]), 1)

## ПЛОЩАДКА, УЖЕ СТОЯЩАЯ В МИРЕ. После перезахода сейв возвращает базу раньше, чем квест
## успевает опомниться: его собственные пометки живут только в памяти, и без этой строки каждый
## вход в мир ставил бы рядом со старой площадкой вторую, в новом случайном месте.
## THE LINE STANDS BY AN ORE VEIN (the player's rule: "at least within 20 m of a vein"): the ore
## for it is right there. The seller goes LINE_VEIN_AHEAD short of the vein along -Z, so the line
## runs +Z from the seller toward it and the receiver at its end stands ~8 m from it. That gap is the
## site's pad plus its feather (LINE_SITE_*) and the vein's reach: levelling the pad must not move the
## ground a vein stands on. Ore comes in deposits, so a candidate is taken only when NO other vein or
## tree stands on the pad (LINE_PAD_*, measured: the first cut put a deposit's neighbour 6 m from the
## seller, under the line, and a tree 3 m from it); of those, the one nearest LINE_DIST out. Null - no
## such vein in reach (none streamed yet): the old random point.
const LINE_VEIN_AHEAD := 13.5
const LINE_VEIN_RING := Vector2(20.0, 120.0)
const LINE_PAD_X := 6.0                       # half width kept clear, the processor's side included
const LINE_PAD_Z := Vector2(-6.0, 12.0)       # behind the seller .. short of the vein

func _line_site_by_vein(from: Vector3) -> Variant:
	var rn: Node = get_node_or_null("/root/Main/map/Resource_Nodes")
	if rn == null or not rn.has_method("veins_near"):
		return null
	var all: Array = rn.veins_near(from, LINE_VEIN_RING.y + LINE_VEIN_AHEAD + LINE_PAD_X * 2.0)
	var best: Variant = null
	var best_s: float = INF
	for v in all:
		if v[1]:
			continue                                # a tree is not ore
		var g: Vector3 = v[0]
		var d: float = Vector2(g.x - from.x, g.z - from.z).length()
		if d < LINE_VEIN_RING.x or d > LINE_VEIN_RING.y:
			continue
		var score: float = absf(d - LINE_DIST)
		if score >= best_s:
			continue
		var wp: Vector3 = g - Vector3(0.0, 0.0, LINE_VEIN_AHEAD)
		var clear: bool = true
		for o in all:
			var og: Vector3 = o[0]
			var lx: float = og.x - wp.x
			var lz: float = og.z - wp.z
			if absf(lx) < LINE_PAD_X and lz > LINE_PAD_Z.x and lz < LINE_PAD_Z.y:
				clear = false
				break
		if clear:
			best_s = score
			best = wp
	if best == null:
		return null
	var out: Vector3 = best
	out.y = G.ground_y(out, from.y)
	return out

func _line_adopt() -> void:
	if is_instance_valid(_line_base):
		return
	_line_base = _adopt_quest_base("arc_line")
	if not is_instance_valid(_line_base):
		return
	_line_point = _line_base.global_position
	_dropped["line_kit"] = true

## Площадка целиком: заякоренный продавец с лентой + набор на земле рядом.
func _spawn_line_kit(at: Vector3) -> void:
	_flatten_line_site(at)
	_line_base = _spawn_station(at, [
		{"x": 5, "y": 5, "z": 5, "block": G.Block.SELLER, "rot": [0.0, 0.0, 0.0]},
		{"x": 5, "y": 5, "z": 6, "block": G.Block.BELT, "rot": [0.0, 0.0, 0.0]},
	])
	if is_instance_valid(_line_base):
		_line_base.set_meta(QuestProps.META, "arc_line")   # по ней база узнаётся после перезахода
	_props.ensure("arc_line", G.Block.RECEIVER, at)
	for _i in _belts_to_drop():
		_props.drop_near("arc_line", G.Block.BELT, at)
	_show_plan(LINE_PLAN)
	Dialogue.say("System", tr("Seller is anchored and live, one belt already on it. The rest of the line is on the ground — the white outlines show where each piece goes."))

## РОВНАЯ ПЛОЩАДКА под линию. Постройка ВСТРАИВАЕТСЯ в мир, а не ставится на него: линия
## длинная — шесть клеток по оси конвейера и две вбок под процессор, — и на склоне её просто
## не собрать: с одного конца блоки уходят в землю, с другого висят в воздухе.
##
## Площадка ПРЯМОУГОЛЬНАЯ и вытянута ПО НАПРАВЛЕНИЮ КОНВЕЙЕРА (+Z базы, она ставится без
## поворота). Круглая по той же длине срыла бы втрое больше земли ради коридора в две клетки.
const LINE_SITE_HALF := Vector2(3.0, 5.0)     # полуразмер площадки: X — ширина, Z — вдоль линии
const LINE_SITE_AHEAD := 2.0                  # центр смещён вперёд по линии, а не по продавцу
const LINE_SITE_FEATHER := 5.0                # на сколько метров площадка сходит на нет за краем

func _flatten_line_site(at: Vector3) -> void:
	_flatten_site(at + Vector3(0.0, 0.0, LINE_SITE_AHEAD), LINE_SITE_HALF, LINE_SITE_FEATHER)

## РОВНОЕ МЕСТО ПОД ПОСТРОЙКУ КВЕСТА — одной дверью. Каждая площадка своего размера, а вот
## «спросить карту и не упасть, если её нет» у всех одинаково.
func _flatten_site(at: Vector3, half: Vector2, feather: float) -> void:
	var map: Node = get_node_or_null("/root/Main/map")
	if map == null or not map.has_method("flatten_area"):
		return
	map.flatten_area(at, half, at.y, feather)

## Стационарная постройка ОТ КВЕСТА. Делает ровно то же, что постановка ядра игроком
## (vehicle_body_3d._place_ground_structure), но без руки и превью: машина из сцены, раскладка,
## флаг станции и якорь. Держать это в двух местах нельзя — база, собранная «почти так же»,
## разваливается сторожем кабины при первой же загрузке.
func _spawn_station(at: Vector3, layout: Array) -> Node3D:
	var scene: PackedScene = load("res://player_vehicle.tscn")
	var vr: Node = get_node_or_null("/root/Main/Vehicles")
	if scene == null or vr == null:
		return null
	var v: Node3D = scene.instantiate()
	vr.add_child(v)
	if v is RigidBody3D:
		(v as RigidBody3D).freeze = true       # морозим ДО позиции: телепорт живого тела физика откатит
		(v as RigidBody3D).linear_velocity = Vector3.ZERO
	# ВЫСОТА: нижний ряд блоков должен ЛЕЖАТЬ НА ЗЕМЛЕ. Клетка — метр, блок нижнего ряда
	# стоит в самом начале координат машины, значит его низ на полметра ниже — отсюда и
	# половина. Со старыми 1.2 база висела над землёй, и вместе с ней висела в воздухе вся
	# линия конвейера: у неё под собой ничего нет, она держится соседями.
	# СТАВИМ В ТОЧКУ ЦЕНТР ЯДРА, А НЕ НАЧАЛО КООРДИНАТ. У блока 2×2×2 (продавец) якорная клетка
	# УГЛОВАЯ: футпринт растёт от неё в минус по X и Z, поэтому машина, поставленная в `at`
	# началом координат, оказывается смещённой на пол-клетки — постройка стоит не в середине
	# выровненной площадки, а её угол. То же самое делает ручная постановка базы
	# (vehicle_body_3d._place_ground_structure), и правило обязано быть одним.
	v.global_position = at + Vector3.UP * 0.5 - _core_xz_offset(layout)
	if v.has_method("apply_build"):
		v.apply_build(layout)
	if "is_station" in v:
		v.is_station = true
		if v.get("block_map_node") != null and "is_station" in v.block_map_node:
			v.block_map_node.is_station = true
	if v.has_method("_anchor_station"):
		v.call_deferred("_anchor_station")
	var cc: Node = get_tree().get_first_node_in_group("camera_controller")
	if cc != null and "vehicles" in cc and not cc.vehicles.has(v):
		cc.vehicles.append(v)                  # чтобы на неё можно было переключиться
	return v

## Сдвиг центра ЯДРА относительно начала координат машины, по XZ. Ядром считаем блок в центре
## сетки (5,5,5) — туда его кладут все раскладки баз. Смещение спрашиваем у самой сцены блока
## (VehicleBlock.cells_center): второй таблицы размеров рядом с blocks._block_footprint быть
## не должно.
func _core_xz_offset(layout: Array) -> Vector3:
	for e in layout:
		if int(e.get("x", -1)) != 5 or int(e.get("y", -1)) != 5 or int(e.get("z", -1)) != 5:
			continue
		var scene: PackedScene = G.get_scene(int(e.get("block", 0)))
		if scene == null:
			return Vector3.ZERO
		var inst: Node = scene.instantiate()
		var c = inst.get("cells_center")
		inst.free()                            # орфан: в дерево не попадал, _ready не отработал
		if c is Vector3:
			return Vector3((c as Vector3).x, 0.0, (c as Vector3).z)
		return Vector3.ZERO
	return Vector3.ZERO

## Блок нужного типа на базе, которую положил квест.
func _find_in_base(bt: int) -> Node:
	if _line_base == null or not is_instance_valid(_line_base):
		return null
	var bm = _line_base.get("block_map_node")
	if bm == null or not is_instance_valid(bm):
		return null
	for b in bm.get_children():
		if ("block" in b) and int(b.get("block")) == bt:
			return b
	return null

## Есть ли ПУТЬ ПО ЛЕНТЕ от блока до блока такого типа. Проверяем связи (next_blocks), а не
## наличие блоков: «поставил рядом» и «подключил» — разные вещи, и учит квест второму.
func _chain_reaches(from: Node, target_bt: int) -> bool:
	var seen: Dictionary = {}
	var stack: Array = [from]
	while not stack.is_empty():
		var n = stack.pop_back()
		if n == null or not is_instance_valid(n) or seen.has(n):
			continue
		seen[n] = true
		if ("block" in n) and int(n.get("block")) == target_bt and n != from:
			return true
		if "next_blocks" in n:
			for x in n.next_blocks:
				stack.append(x)
	return false

## Уронить слитки ПРЯМО НАД приёмником — он их и подберёт. Показать линию в работе проще,
## чем объяснить: игрок видит, как материал уезжает по ленте и превращается в деньги.
func _drop_ore_over(recv: Node, count: int) -> void:
	if recv == null or not (recv is Node3D):
		return
	for i in count:
		_props.drop_resource(LINE_ORE_KIND,
				(recv as Node3D).global_position + Vector3(0.0, 2.0 + float(i) * 0.8, 0.0))

# ── «Hold the Line»: налёт на СВОЮ базу ──────────────────────────────────────
# В оригинале это турели у чужой станции. Станций у нас нет, поэтому защищаем то, что игрок
# построил сам, — и защищать приходится СТОЯ: заякоренная машина уехать не может.
## СКОЛЬКО ПРИЕЗЖАЕТ. Было двое, и вдвоём они приезжали не подраться, а снести: база стоит на
## месте по определению задания, отойти ей нечем, и два лансера разбирали её раньше, чем игрок
## успевал развернуться. Один противник оставляет ту же задачу — оборонить стоящее — и делает её
## проходимой.
const HOLD_COUNT := 1
const HOLD_RANGE := 70.0
## КОГО ПРИСЫЛАЕМ. Здесь стояла голая восьмёрка — первая сборка ступени ЛАНСЕРОВ, а лансер это
## первая машина с куполом (см. правило про жёстко названные пресеты: тем же способом дуэль
## однажды присылала лансера игроку со стартовой кабиной). Берём ступень «бегунов»: налёт на базу
## должен быть боем, а не приговором. `_spawn_hostile` всё равно пропустит это через `_tier_cap`,
## так что слабому игроку приедет ещё легче, а сильному — ровно это.
const HOLD_PRESET := 6

var _hold: Array = []

## Кого приезжают бить. Сначала БАЗА (стационарная постройка): налёт идёт за производством,
## а производство стоит на ней, и она по определению на якоре. Базы нет — заякоренная
## машина, нет и её — та, которой игрок управляет.
##
## Ждать якоря, как раньше, было незачем: стадия требовала от игрока встать, хотя нападают
## именно на то, что и так стоит. Игрок в этот момент занят конвейером, а квест повторял ему
## пройденное и до тех пор не начинался вовсе.
func _hold_target() -> Node3D:
	var vr: Node = get_node_or_null("/root/Main/Vehicles")
	var anchored_one: Node3D = null
	if vr != null:
		for c in vr.get_children():
			if not (c is Node3D) or c.get("faction") == null or int(c.get("faction")) != 0:
				continue
			if c.get("is_station") == true:
				return c as Node3D
			if anchored_one == null and c.get("anchored") == true:
				anchored_one = c as Node3D
	return anchored_one if anchored_one != null else _player()

func _hold_1(q: Dictionary) -> void:
	if not _hold_send():
		return
	Q.report(String(q["event"]), 1)

## Присылает налёт на базу. Отдельно от стадии, потому что после перезахода его присылает ВТОРАЯ
## стадия: ссылки на врагов в сейв не идут.
func _hold_send() -> bool:
	var p: Node3D = _hold_target()
	var sp: Node = get_node_or_null("/root/Main/EnemySpawner")
	if p == null or sp == null or not sp.has_method("spawn_at"):
		return false
	_hold.clear()
	for i in HOLD_COUNT:
		var ang: float = TAU * float(i) / float(HOLD_COUNT) + randf()
		var wp: Vector3 = p.global_position + Vector3(cos(ang) * HOLD_RANGE, 0.0, sin(ang) * HOLD_RANGE)
		wp.y = G.ground_y(wp, p.global_position.y)
		var e: Node3D = _spawn_hostile(sp, wp, HOLD_PRESET)
		if e != null:
			if e.has_method("assign_target"):
				e.assign_target(p, true)    # идёт именно за базой и цель не бросает
			_hold.append(e)
	return not _hold.is_empty()

## ПУСТОЙ СПИСОК — НЕ ПОБЕДА, А ПОТЕРЯННОЕ СОСТОЯНИЕ. Враги в сейв не идут, так что после
## перезахода здесь пусто ВСЕГДА, и «ни одного живого» читалось как «налёт разбит»: замерено на
## движке — на первом же опросе после перезахода квест закрывался сам, без единого выстрела.
## То же правило уже стоит у событий (`_ev_all_dead`), у вышки и у охраны обломков: нет записи
## значит «мы про них ничего не знаем», и налёт приезжает заново.
func _hold_2(q: Dictionary) -> void:
	if _hold.is_empty():
		_hold_send()
		return
	for e in _hold:
		if is_instance_valid(e):
			return
	Q.report(String(q["event"]), 1)
	_hold.clear()

# ── ВЫШКА ПОД ЩИТОМ: Charlie Watchtower и SAM Site Ridge ────────────────────
# ОДНА реализация на два квеста, и это не экономия строк: они и по замыслу одно и то же —
# цель под куполом, купол держат зарядные башни вокруг. Разными их делают ровно три числа
# (пресет вышки, сколько башен, тексты), и держать под это две копии значило бы однажды
# починить одну и забыть вторую.
#
# ГЛАВНОЕ: связка «башни держат щит» СОБИРАЕТСЯ САМА, обычными правилами игры. У вышки нет
# панелей (blocks._layout_shielded_tower), значит своей выработки ноль; зарядные башни рядом
# льют в неё энергию блоком WIRELESS_CHARGER. Квест не знает про щит вообще ничего — он
# ставит машины и ждёт, пока вышка умрёт. Убил башни → у вышки кончается запас → купол гаснет
# сам, и её можно ломать. Игроку это видно по лучам зарядки, а не по строчке в журнале.
## The charging stations' ring. It must stand OUTSIDE the dome (shield.SHIELD_RADIUS, 4 m), or the
## station cannot be shot, which is the whole task, and within wireless_charger.RANGE of the
## tower's battery. The ring was measured when that range was 6 m (4.9 m to the nearer battery at
## 5.5); at 20 m it is no longer the limit, and the tight ring stays because it reads as one site.
const TOWER_RING := 5.5
## Пресет вышки, сколько зарядных башен, и что говорит Система, когда игрок доехал.
## THE WATCHTOWER STANDS ALONE (the player: "too hard - remove the others, let it spawn solo"): no
## charging stations, so its dome runs on the tower's own two batteries (it arrives charged, see
## enemy_vehicle._charge_batteries) and goes down when they run dry - about half a minute of one
## gun on the dome. Three stations with a gun each made it the hardest fight of its grade. SAM keeps
## its four: the fed dome is that quest's whole lesson.
const TOWER_WATCH := {"key": "tower", "preset": 16, "guards": 0, "award": G.Block.SHIELD,
		"say": "The tower stands alone: its dome runs on its own batteries. Keep it busy and they will run dry."}
const TOWER_SAM := {"key": "sam", "preset": 17, "guards": 4, "award": G.Block.ROCKET,
		"say": "That dome is not the tower's own. Something else is paying for it."}

## CROWNTOP HILL FORT (TerraTech's Hawkeye story, the player's call: "on a support"): the Spider
## King, an anchored Stryx fort - rockets, lasers, a dome and a repair field on batteries and panels
## (blocks.SPIDER_KING) - so at night its panels give nothing and the dome drains for good. No hover
## rings: nothing here hovers.
const CROWN := {"key": "crown", "preset": 132, "guards": 0, "award": G.Block.STRYX_SHIELD,
		"say": "The Spider King holds Crowntop Hill: rockets, lasers and a dome. Its panels feed the dome - at night they give nothing.",
		"done": "The Spider King is down. Stryx pays in hardware."}

## THE ALMIGHTY CUBE runs on this branch: a base to reach and bring down, no guards. Each cube is
## its own key, so all three can stand at once; `_tower_pick` keeps their points TOWER_APART.
const CUBES := [
	{"key": "cube1", "preset": 123, "guards": 0, "award": G.Block.MARLIT_ARMOR4,
		"say": "Marlit's cube is out there. It does not shoot - it only has to stand. Break it in 20 seconds from the first hit.",
		"done": "The cube is down. Marlit sends what it promised."},
	{"key": "cube2", "preset": 124, "guards": 0, "award": G.Block.MARLIT_REGEN,
		"say": "The second cube repairs itself. Hit it harder than it can mend.",
		"done": "The cube is down. Marlit sends what it promised."},
	{"key": "cube3", "preset": 125, "guards": 0, "award": G.Block.MARLIT_CANNON,
		"say": "The last cube runs on the sun. Its repairs will not stop on their own.",
		"done": "The cube is down. Marlit sends what it promised."},
]
## Two branch points no closer than this, or two cubes open at once land in one fight.
const TOWER_APART := 120.0
const TOWER_APART_TRIES := 6

var _tower_point: Dictionary = {}      # ключ → Vector3, куда ехать
var _tower_node: Dictionary = {}       # ключ → сама вышка
var _tower_dead: Dictionary = {}       # ключ → true, если вышку уже добили

func _tower_1(q: Dictionary, cfg: Dictionary) -> void:
	var key: String = String(cfg["key"])
	var p: Node3D = _player()
	if p == null:
		return
	if not _tower_point.has(key):
		_tower_point[key] = _tower_pick(key, p)
	var at: Vector3 = _tower_point[key]
	if not _tower_node.has(key):
		if not _tower_build(key, cfg, at):
			return
		Dialogue.say("System", tr(String(cfg["say"])))
	if not _reached(at):
		return
	Q.report(String(q["event"]), 1)

func _tower_2(q: Dictionary, cfg: Dictionary) -> void:
	var key: String = String(cfg["key"])
	# СОСТОЯНИЕ МОГЛО ПОТЕРЯТЬСЯ (перезаход: квестовые машины в сейв не идут). Пустая ссылка
	# сама по себе не победа — то же правило, что у событий: ставим постройку заново.
	# The point is memory too: a reload in this stage forgot it, and with no point nothing was ever
	# built again - the stage hung for good. A new point, the tower stands there.
	if not _tower_node.has(key):
		var p: Node3D = _player()
		if p == null:
			return
		if not _tower_point.has(key):
			_tower_point[key] = _tower_pick(key, p)
		_tower_build(key, cfg, _tower_point[key])
		return
	if not bool(_tower_dead.get(key, false)):
		if key.begins_with("cube"):
			_cube_clock(key, cfg)
		return
	_cube_t.erase(key)
	# Вышка мертва. Зарядные башни, если ещё стоят, теряют в этот момент аккумуляторы
	# (_blow_tower_guards) и остаются в мире обычными базами: добивать их ради галочки незачем,
	# а бросать посреди боя — тем более.
	_award(int(cfg["award"]))
	Dialogue.say("System", tr(String(cfg.get("done", "Ridge is clear. The hardware it was guarding is yours."))))
	Q.report(String(q["event"]), 1)
	_tower_node.erase(key)
	_tower_dead.erase(key)

## THE CUBE HAS TO GO DOWN IN ONE GO (the player's rule): it has no guns, the quest is the damage.
## The first hit starts CUBE_TIME; if the cube still stands when it runs out, it is taken away and
## built again whole on its point, and the next hit starts the clock again. "Hit" is read off the
## cube itself (hit points under full, or a block gone), polled with the branch.
const CUBE_TIME := 20.0
var _cube_t: Dictionary = {}       # key -> seconds left, absent while nobody has touched it

func _cube_hp(c: Node) -> Vector2i:
	var hp := 0
	var full := 0
	var bl: Node = c.get_node_or_null("blocks")
	if bl == null:
		return Vector2i.ZERO
	for b in bl.get_children():
		if b is VehicleBlock:
			hp += (b as VehicleBlock).current_hp
			full += (b as VehicleBlock).max_hp
	return Vector2i(hp, full)

func _cube_clock(key: String, cfg: Dictionary) -> void:
	var c = _tower_node.get(key)
	if not is_instance_valid(c):
		return
	if not (c as Node).has_meta("cube_full"):
		(c as Node).set_meta("cube_full", _cube_hp(c).y)   # measured once it stands, never after
		return
	if not _cube_t.has(key):
		var hp: Vector2i = _cube_hp(c)
		if hp.x < int((c as Node).get_meta("cube_full")):
			_cube_t[key] = CUBE_TIME
			Dialogue.say("System", tr("Cube hit: %d seconds to break it.") % int(CUBE_TIME))
		return
	var was: float = float(_cube_t[key])
	_cube_t[key] = was - POLL
	if was > 10.0 and float(_cube_t[key]) <= 10.0:
		Dialogue.say("System", tr("%d seconds left.") % 10)
	if float(_cube_t[key]) > 0.0:
		return
	_cube_t.erase(key)
	var at: Vector3 = (c as Node3D).global_position
	if _tower_point.has(key):
		at = _tower_point[key]
	(c as Node).queue_free()
	_tower_node.erase(key)
	_tower_build(key, cfg, at)
	Dialogue.say("System", tr("Time is up. The cube stands whole again."))

## A point for the branch, TOWER_APART from every other branch point standing (the last try wins).
func _tower_pick(key: String, p: Node3D) -> Vector3:
	var wp: Vector3 = _far_point(p)
	for _i in TOWER_APART_TRIES:
		var clear := true
		for k in _tower_point:
			if k != key and (_tower_point[k] as Vector3).distance_squared_to(wp) < TOWER_APART * TOWER_APART:
				clear = false
				break
		if clear:
			break
		wp = _far_point(p)
	return wp

## Собрать точку: вышка в центре, зарядные башни кольцом вокруг неё.
##
## The ring's radius is TOWER_RING, and why is written there.
func _tower_build(key: String, cfg: Dictionary, at: Vector3) -> bool:
	var sp: Node = get_node_or_null("/root/Main/EnemySpawner")
	if sp == null or not sp.has_method("spawn_at"):
		return false
	var tower = _ask_spawner(sp, at, int(cfg["preset"]), 1, true)
	if tower == null:
		return false
	tower.set_meta("volatile_batteries", true)
	if tower.has_signal("died"):
		tower.died.connect(_on_tower_died.bind(key))
	_tower_node[key] = tower
	# Зарядные башни ссылками НЕ ДЕРЖИМ намеренно: квест про них ничего не спрашивает. Живы они
	# или нет, видно по самому щиту — а список, который никто не читает, однажды разойдётся с
	# миром (башню убрали, ссылка осталась) и начнёт врать.
	var n: int = int(cfg["guards"])
	for i in n:
		var ang: float = TAU * float(i) / float(n)
		var wp: Vector3 = at + Vector3(cos(ang) * TOWER_RING, 0.0, sin(ang) * TOWER_RING)
		wp.y = G.ground_y(wp, at.y)
		var g = _ask_spawner(sp, wp, 18, 1, true)
		if g != null:
			g.set_meta("volatile_batteries", true)
			g.set_meta("tower_guard", key)      # см. _blow_tower_guards: метка, а не список
	return true

## ВЫШКА ПАЛА — БАТАРЕИ ЗАРЯДНЫХ БАШЕН РВУТСЯ. Энергия им больше некуда деваться, и точка
## обязана кончиться одним событием, а не уборкой трёх-четырёх целых баз, у которых уже нет
## работы: добивать их «ради галочки» — это ровно та скука, из-за которой квест кончается позже,
## чем кончился бой.
##
## Ищем МЕТКОЙ ПО МИРУ, а не списком: список, который никто не перечитывает, однажды разойдётся
## с миром (башню снесли, ссылка осталась) и начнёт врать — поэтому его здесь и не заводили.
func _blow_tower_guards(key: String) -> void:
	var vr: Node = get_node_or_null("/root/Main/Vehicles")
	if vr == null:
		return
	for v in vr.get_children():
		if not is_instance_valid(v) or not v.has_meta("tower_guard"):
			continue
		if String(v.get_meta("tower_guard")) != key:
			continue
		# Their job is over: they stop being quest machines, so the spawner's cleanup may take them
		# like any base - left tagged `story`, every tower done kept three or four of them in
		# `max_total` for the rest of the save.
		v.remove_meta("tower_guard")
		v.remove_meta("story")
		var bl: Node = v.get_node_or_null("blocks")
		if bl == null:
			continue
		var bats: Array = []
		for b in bl.get_children():
			if b.has_method("is_volatile") and b.is_volatile():
				bats.append(b)
		for b in bats:                          # взрыв бьёт соседей — рвём вне обхода детей
			if is_instance_valid(b):
				b.destroy()

func _on_tower_died(who, key: String) -> void:
	if who != null and _tower_node.get(key) != who:
		return                                  # a cube taken away to stand up whole again
	_tower_dead[key] = true
	_blow_tower_guards(key)

# ── Помощники ────────────────────────────────────────────────────────────────
## "REACH X" IS DONE WHEN THE PLAYER IS THERE, NOT WHEN X EXISTS. Participants appear the moment a
## quest opens, 250-300 m out (the one spawn rule), and commit 99e43f9 moved the spawn up by
## deleting the distance gate that also decided when stage 1 counted as done. Every "Reach ..."
## stage then reported itself in the same poll that spawned its enemies, and the tracker showed
## 2/2 the moment an event appeared. The spawn stays early; only the report waits for this.
const REACH_DIST := 60.0

## BY THE GROUND'S PLAN, NOT IN 3D: a point on a hill top was out of reach from its own foot, and a
## point whose height went wrong (see `_far_point`) could not be reached at all.
func _reached(at: Variant) -> bool:
	var p: Node3D = _player()
	if p == null or not (at is Vector3):
		return false
	var d: Vector3 = p.global_position - (at as Vector3)
	return d.x * d.x + d.z * d.z <= REACH_DIST * REACH_DIST

func _player() -> Node3D:
	var cc: Node = get_tree().get_first_node_in_group("camera_controller")
	if cc != null and "current_vehicle" in cc and cc.current_vehicle != null:
		return cc.current_vehicle as Node3D
	return null

func _has_block(bt: int) -> bool:
	return _count_block(bt) > 0

## Есть ли блок У ИГРОКА где угодно: на ЛЮБОЙ его машине, в инвентаре или в руке. Пока есть —
## выдавать его заново не надо, иначе «предмет потерялся» и «игрок его уже подобрал» становятся
## для квеста одним и тем же, и мир зарастает копиями награды.
##
## Машины перебираются ВСЕ, а не только та, которой сейчас рулят. Стационарный блок (опора,
## продавец) при постановке на землю РОЖДАЕТ СВОЮ БАЗУ — то есть уезжает на другую машину, —
## и по одной текущей машине выходило, что игрок его потерял: квест клал новую опору каждую
## секунду, и поле вокруг зарастало ими. Ровно на это и жаловались.
func _player_owns(bt: int) -> bool:
	if G.block_inventory.has(bt):
		return true
	var cc: Node = get_tree().get_first_node_in_group("camera_controller")
	if cc != null and "vehicles" in cc:
		for v in cc.vehicles:
			if _machine_has(v, bt):
				return true
	elif _has_block(bt):
		return true
	# РУКА — ЭТО hand_node(), А НЕ block_body. block_body — это блок, НА КОТОРЫЙ НАВЕДЕНЫ (он и так
	# посчитан выше, вместе с машиной, на которой стоит). Пока спрашивали его, блок в руке не
	# считался ничьим: игрок вёз панель к опоре, а ветка каждую секунду роняла ему вторую.
	return _in_hand(bt)

func _in_hand(bt: int) -> bool:
	var p: Node3D = _player()
	if p == null or not p.has_method("hand_node"):
		return false
	var held = p.hand_node()
	return is_instance_valid(held) and ("block" in held) and int(held.get("block")) == bt

func _count_block(bt: int) -> int:
	return _machine_count(_player(), bt)

func _machine_has(m: Node, bt: int) -> bool:
	return _machine_count(m, bt) > 0

func _machine_count(m: Node, bt: int) -> int:
	if m == null or not is_instance_valid(m):
		return 0
	var blocks: Node = m.get_node_or_null("blocks")
	if blocks == null:
		return 0
	var n: int = 0
	for b in blocks.get_children():
		if b.get("block") != null and int(b.get("block")) == bt:
			n += 1
	return n

func _award(bt: int) -> void:
	var p: Node = _player()
	if p != null and p.has_method("award_blocks"):
		p.award_blocks(bt, 1)

## How many of a block the player has anywhere: every machine, the inventory, the hand.
func _owned_count(bt: int) -> int:
	var n: int = (G.block_inventory as Array).count(bt)
	var cc: Node = get_tree().get_first_node_in_group("camera_controller")
	if cc != null and "vehicles" in cc:
		for v in cc.vehicles:
			n += _machine_count(v, bt)
	else:
		n += _count_block(bt)
	if _in_hand(bt):
		n += 1
	return n

# ══════════════════════════════════════════════════════════════════════════════
# ПОВТОРЯЕМЫЕ СОБЫТИЯ (в оригинале — задания с борда станции)
# ══════════════════════════════════════════════════════════════════════════════
# Борда у нас нет и не будет: задания объявляет Система напрямую. Всё остальное взято
# оттуда — типы («банда», «груз», «оборона союзника», «волны», «лагерь»), повторяемость по
# остыванию и правило «уехал далеко — задание снято».
#
# Общего у них ровно три вещи, и они вынесены сюда, чтобы каждое новое событие не тащило
# свою копию: ТОЧКА (куда ехать), СПИСОК УЧАСТНИКОВ (по нему считается победа) и ОТМЕНА
# ПО РАССТОЯНИЮ. Без последней брошенное событие висело бы в журнале навсегда, а его
# участники — в мире.
const EV_ABANDON := 500.0      # уехал дальше — событие снимается (как в оригинале)
## ОСТЫВАНИЕ — МИНУТА-ДВЕ, а не семь. Семь минут означало, что между событиями игрок едет по
## пустой карте: события — это и есть то, ЧТО с ним происходит, пока он не занят сюжетом.
## Разброс, а не одно число: одинаковая пауза читается как расписание.
##
## НО НЕ С ПЕРВОЙ МИНУТЫ. Пока мир слабый (G.threat_ramp), пауза растянута: события — это бой, а
## на первом грейде у игрока одна пушка и ни одного исследования, и «раз в минуту» для него не
## ритм, а осада. К четвёртому грейду множитель приходит к единице сам.
const EV_COOLDOWN_MIN := 60.0
const EV_COOLDOWN_MAX := 120.0
const EV_COOLDOWN_EARLY_MUL := 2.5

func _event_cooldown() -> float:
	return randf_range(EV_COOLDOWN_MIN, EV_COOLDOWN_MAX) \
			* G.threat_lerp(EV_COOLDOWN_EARLY_MUL, 1.0)


var _ev_point: Dictionary = {}   # id события → Vector3, куда ехать
var _ev_mobs: Dictionary = {}    # id события → Array участников
var _ev_cool: Dictionary = {}    # id события → сколько ещё остывать
var _ev_orb: Dictionary = {}     # event key -> reward orb hanging over its point (reward_orb.gd)

## Куда ведёт компас по этому событию. ОДНА точка входа на все события с координатами:
## разбирать их по одному в компасе значило бы вспоминать про него при каждом новом.
func quest_point(ev: String) -> Variant:
	# ЖИВОЙ УЧАСТНИК ВАЖНЕЕ ТОЧКИ, и это не мелочь. Точка выбирается ОДИН РАЗ, при объявлении,
	# а враги ездят: к началу драки противник уже не там, а после гибели игрока (возрождение
	# уводит его в сторону) метка и вовсе вела в пустое поле — «квесты со спавном врагов без
	# метки». Пока участник жив, метка едет за НИМ, и только когда живых не осталось —
	# возвращаемся к точке.
	var live = _live_target(ev)
	if live != null:
		return live
	match ev:
		"quest_salvage_1": return _salvage_point
		"quest_line_1":    return _line_point
		# Пока панель (или реген) лежит у базы, компас ведёт к предмету — его отдаёт QuestProps,
		# и спрашивают его раньше нас. Предмет подобран — цель это САМА БАЗА: ставить его всё
		# равно туда, а без этой строки метка гасла ровно в тот момент, когда игрок взял блок.
		"quest_arc_power_1": return _power_point
		"quest_arc_power_2": return _power_point
		"quest_yellow_1": return _yellow_point
		# Ветки с носителем и с жилой: точка едет за живым носителем (carrier_point сама
		# обновляет её), а после боя указывает туда, где упал блок.
		"quest_arc_radar_1":   return carrier_point("arc_radar")
		"quest_arc_battery_1": return battery_point()
		"quest_arc_battery_2": return battery_point()
	# Вышки под щитом держат свои точки в отдельном словаре, но ключ у них ТОТ ЖЕ, что у
	# событий ("quest_tower_1" → "tower"), поэтому перечислять их по одной здесь не нужно —
	# ровно то, от чего предостерегает комментарий у компаса.
	var key := _ev_key(ev)
	if _tower_point.has(key):
		return _tower_point[key]
	var tr_node = _track_of(key)
	if tr_node != null:
		return (tr_node as Node).call("aim_point")
	return _ev_point.get(key)

## Позиция ближайшего ЖИВОГО участника квеста или null. Участники лежат по своим полям (у
## каждой ветки они свои), поэтому здесь один список на все случаи: добавить новый квест со
## спавном — значит дописать сюда строку, иначе его метка снова будет вести в поле.
func _live_target(ev: String) -> Variant:
	var key := _ev_key(ev)
	var list: Array = []
	list.append_array(_ev_mobs.get(key, []))
	if _ev_base.has(key):
		list.append(_ev_base[key])
	if key == "rock":
		list.append(_rock)
	elif key == "quiet":
		list.append(_quiet)
	if _tower_node.has(key):
		list.append(_tower_node[key])
	match key:
		"hold":      list.append_array(_hold)
		"salvage":   list.append(_salvage_guard)
	# Носитель сюжетного блока — такой же живой участник: пока он ездит, метка едет за ним.
	if _carrier.has(key):
		list.append(_carrier[key])
	var p: Node3D = _player()
	var best: Variant = null
	var best_d: float = INF
	for m in list:
		if m == null or not is_instance_valid(m) or not (m is Node3D):
			continue
		var pos: Vector3 = (m as Node3D).global_position
		var d: float = pos.distance_squared_to(p.global_position) if p != null else 0.0
		if d < best_d:
			best_d = d
			best = pos
	return best

## Ключ события по имени его стадии: "quest_gang_1" → "gang". Точка и участники общие для
## обеих стадий, поэтому и ключ должен быть общим.
func _ev_key(ev: String) -> String:
	var s := ev.trim_prefix("quest_")
	var cut := s.rfind("_")
	return s.substr(0, cut) if cut > 0 else s

## Точка события: выбираем один раз и держим. Возвращает null, пока игрока нет.
## dist <= 0 — общее правило спавна квестов (_quest_dist).
func _ev_get_point(key: String, dist: float = 0.0) -> Variant:
	if _ev_point.has(key):
		return _ev_point[key]
	var wp = _event_point(dist)
	if wp == null:
		return null
	_ev_point[key] = wp
	return wp

## WHERE AN EVENT HAPPENS: EV_POINT_DIST from the player, and no nearer than EV_BASE_CLEAR to any of
## the player's machines and bases (the player's rule): with the player a hundred metres from their
## base, a point "a hundred metres off" could land on the base itself. `dist` > 0 asks for that
## distance instead.
const EV_POINT_DIST := Vector2(220.0, 300.0)
const EV_BASE_CLEAR := 200.0     # enemy_spawner.PLAYER_CLEAR

func _event_point(dist: float = 0.0) -> Variant:
	var p: Node3D = _player()
	if p == null:
		return null
	var best: Variant = null
	var best_clear: float = -1.0
	for i in 24:
		var d: float = dist if dist > 0.0 else randf_range(EV_POINT_DIST.x, EV_POINT_DIST.y)
		var ang: float = randf() * TAU
		var wp: Vector3 = p.global_position + Vector3(cos(ang) * d, 0.0, sin(ang) * d)
		if safe_zone_at(wp, EV_PARTY_RING) != null:
			continue                       # never an event inside a learning base's quiet zone
		var clear: float = _nearest_own_d2(wp)
		if clear >= EV_BASE_CLEAR * EV_BASE_CLEAR:
			best = wp
			break
		if clear > best_clear:
			best_clear = clear
			best = wp
	if best == null:
		return null                        # every try fell in a quiet zone: ask again next poll
	var out: Vector3 = best
	out.y = G.ground_y(out, p.global_position.y)
	return out

## The player's machines and bases (the camera's list, the one quest code asks everywhere).
func _own_machines() -> Array:
	var out: Array = []
	var cc: Node = get_tree().get_first_node_in_group("camera_controller")
	if cc != null and "vehicles" in cc:
		for v in cc.vehicles:
			if is_instance_valid(v) and v is Node3D:
				out.append(v)
	if out.is_empty():
		var p: Node3D = _player()
		if p != null:
			out.append(p)
	return out

func _nearest_own_d2(at: Vector3) -> float:
	var best: float = INF
	for v in _own_machines():
		best = minf(best, (v as Node3D).global_position.distance_squared_to(at))
	return best

## УЕХАЛ ЗА EV_ABANDON — снимаем. Возвращает true, если событие снято: вызывающий сразу выходит.
##
## Меряем от ТОЧКИ СОБЫТИЯ, и участники для этого не нужны. Раньше проверка ждала, пока они
## появятся в мире (а появляются они, только когда игрок доедет), и объявленное событие, к
## которому игрок так и не поехал, висело в журнале вечно — занимая место, которое теперь
## делят всего два события.
func _ev_abandoned(q: Dictionary, key: String) -> bool:
	if not _ev_point.has(key):
		return false
	# FROM THE NEAREST OF THE PLAYER'S MACHINES AND BASES, not from the one being driven: an event
	# by the player's base stays while the player is out on a run (the player's rule)
	var at: Vector3 = _ev_point[key] as Vector3
	var live = _live_target("quest_%s_1" % key)
	if live is Vector3:
		at = live
	if _nearest_own_d2(at) <= EV_ABANDON * EV_ABANDON:
		return false
	_ev_clear(key)
	# Остывание ставим и здесь: снятое событие обязано вернуться, иначе «уехал один раз» —
	# и этот тип задания больше не случается никогда.
	_ev_cool[String(q["id"])] = _event_cooldown()
	Q.skip_quest(String(q["id"]))
	return true

## Убрать за собой: участники, точка, метка. Уводим их из мира, а не бросаем — иначе поле
## постепенно зарастает машинами от заданий, которые игрок даже не начал.
func _ev_clear(key: String) -> void:
	_q_kills.erase("event_" + key)
	Q.set_reward_mult("event_" + key, 1.0)
	for m in _ev_mobs.get(key, []):
		if is_instance_valid(m):
			(m as Node).queue_free()
	_ev_mobs.erase(key)
	_ev_party.erase(key)
	_ev_point.erase(key)
	var orb = _ev_orb.get(key)
	if is_instance_valid(orb):
		(orb as Node).queue_free()
	_ev_orb.erase(key)
	var base = _ev_base.get(key)
	if is_instance_valid(base):
		(base as Node).queue_free()
	_ev_base.erase(key)
	_drop_track(key)
	_camp_hold.erase(key)
	_props.release("event_" + key)

## A participant that outlived its quest (the covered ally, a tower's guards) stops being a quest
## machine: tagged `story`, the spawner's cleanup never takes it and it holds a place in
## `max_total` for the rest of the save.
func _release_machine(m) -> void:
	if is_instance_valid(m):
		(m as Node).remove_meta("story")

## Все участники события уничтожены?
func _ev_all_dead(key: String) -> bool:
	# НЕТ ЗАПИСИ — не «все мертвы», а «мы про них ничего не знаем» (перезаход: события в сейв
	# не идут). Считать это победой значило бы закрывать задание выходом в меню.
	if not _ev_mobs.has(key):
		return false
	if _party_open(key):
		return false
	for m in _ev_mobs.get(key, []):
		if is_instance_valid(m):
			return false
	return true

## Событие завершено: остывает и через минуту-две открывается снова.
func _ev_done(q: Dictionary, key: String) -> void:
	Q.report(String(q["event"]), 1)
	_q_kills.erase(String(q["id"]))     # paid out above; the next run of the event starts at one
	_ev_cool[String(q["id"])] = _event_cooldown()
	_ev_mobs.erase(key)
	_ev_party.erase(key)
	_ev_point.erase(key)
	_ev_orb.erase(key)                  # an opened orb burns out and frees itself
	_props.release(String(q["id"]))

## Остывание всех событий разом (зовётся из _process рядом с дуэльным).
func _ev_cooldowns(delta: float) -> void:
	for id in _ev_cool.keys():
		_ev_cool[id] = float(_ev_cool[id]) - delta
		if _ev_cool[id] <= 0.0:
			_ev_cool.erase(id)
			Q.reset_quest(id)

## How far round its point a party's members drop: the clearance from the player's machines is
## taken for the whole ring, so the two numbers are one.
const EV_PARTY_RING := 10.0

## Спавн отряда вокруг точки. Пресеты — те же ступени опасности, что у обычных врагов.
func _ev_spawn(key: String, at: Vector3, presets: Array, faction_id: int = 1,
		lock_on: Node3D = null, defer: bool = true) -> Array:
	var sp: Node = get_node_or_null("/root/Main/EnemySpawner")
	if sp == null or not sp.has_method("spawn_at"):
		return []
	var out: Array = []
	# THE PARTY IS MEASURED AGAINST THE PLAYER BEFORE IT IS BORN (`party_for_request`), and its
	# point is moved out of PLAYER_CLEAR as a whole (`clear_point`), so the members still drop
	# together - one by one at the door each would be pushed its own way.
	if faction_id != 0:
		if sp.has_method("party_for_request"):
			presets = sp.party_for_request(presets)
		# A FACTION'S PARTY IS MEASURED IN ITS OWN BUILDS: the budget above counts Falsus ladder
		# values, and a Marlit runner (17.4k) stands in for steps worth 10.7k / 15.9k - so the party
		# is turned into the faction's builds HERE and trimmed again on their real value (members
		# outside the ladder cannot step down, only drop). `_spawn_hostile` leaves them as they are.
		var mapped: Array = []
		for p in presets:
			mapped.append(_faction_preset(sp, int(p)))
		if mapped != presets and sp.has_method("party_budget") and sp.has_method("preset_value"):
			var budget: float = sp.party_budget()
			var total: float = 0.0
			for p in mapped:
				total += sp.preset_value(int(p))
			while mapped.size() > 1 and total > budget:
				total -= sp.preset_value(int(mapped.pop_back()))
		presets = mapped
		if defer:
			_party_add(key, at, presets, faction_id, lock_on)
			return []
		if sp.has_method("clear_point"):
			at = sp.clear_point(at, EV_PARTY_RING)
	for i in presets.size():
		var ang: float = TAU * float(i) / float(maxi(presets.size(), 1))
		var pos: Vector3 = at + Vector3(cos(ang) * EV_PARTY_RING, 0.0, sin(ang) * EV_PARTY_RING)
		var e: Node3D = _spawn_hostile(sp, pos, int(presets[i]), faction_id)
		if e == null:
			continue
		if lock_on != null and e.has_method("assign_target"):
			e.assign_target(lock_on, true)
		out.append(e)
	var have: Array = _ev_mobs.get(key, [])
	have.append_array(out)
	_ev_mobs[key] = have
	return out

## A HOSTILE PARTY COMES WHEN THE PLAYER DOES, AND LEAVES WHEN THE PLAYER DOES (the player's rule).
## An event's party used to be born the moment the quest opened, 250-300 m out, and stood there for
## good. Now `_ev_spawn` only WRITES IT DOWN (`_ev_party`): the members are born on their point once
## one of the player's machines is within PARTY_ARRIVE of it, as one spawn group (`spawn_group`, which
## the spawner's MAX_GROUPS counts once), and are taken away again once every live member is farther
## than PARTY_LEAVE from all of the player's machines - measured from THE MACHINES, which drive, not
## from the point. Coming back brings back whoever was not killed. Allies (faction 0) and a party
## spawned with `defer` false come at once.
const PARTY_ARRIVE := 70.0
const PARTY_LEAVE := 140.0

var _ev_party: Dictionary = {}   # event key -> {"at": Vector3, "q": id, "members": [{...}]}

func _party_add(key: String, at: Vector3, presets: Array, faction_id: int, lock_on: Node3D) -> void:
	var party: Dictionary = _ev_party.get(key, {"at": at, "q": _cur_q, "members": []})
	for i in presets.size():
		var ang: float = TAU * float(i) / float(maxi(presets.size(), 1))
		party["members"].append({"preset": int(presets[i]), "faction": faction_id,
				"off": Vector3(cos(ang) * EV_PARTY_RING, 0.0, sin(ang) * EV_PARTY_RING),
				"at": at, "lock": lock_on, "node": null, "out": false, "dead": false})
	_ev_party[key] = party
	if not _ev_mobs.has(key):
		_ev_mobs[key] = []

## Members written down and not killed yet: the party is not over, whether they stand or not.
func _party_open(key: String) -> bool:
	if not _ev_party.has(key):
		return false
	for m in _ev_party[key]["members"]:
		if not bool(m["dead"]):
			return true
	return false

func _party_tick() -> void:
	if _ev_party.is_empty():
		return
	var sp: Node = get_node_or_null("/root/Main/EnemySpawner")
	if sp == null:
		return
	for key in _ev_party.keys():
		var party: Dictionary = _ev_party[key]
		var live: Array = []
		var waiting: Array = []
		for m in party["members"]:
			if bool(m["dead"]):
				continue
			# "out" and not `node != null`: a freed node compares equal to null (rule 4), and a killed
			# member read that way was waiting - and born again.
			if bool(m["out"]):
				if is_instance_valid(m["node"]):
					live.append(m)
					continue
				m["dead"] = true             # gone and not taken away by us: killed
				continue
			waiting.append(m)
		if not live.is_empty():
			var far := true
			for m in live:
				if _nearest_own_d2((m["node"] as Node3D).global_position) <= PARTY_LEAVE * PARTY_LEAVE:
					far = false
					break
			if far:
				var mobs: Array = _ev_mobs.get(key, [])
				for m in live:
					mobs.erase(m["node"])
					(m["node"] as Node).queue_free()
					m["node"] = null
					m["out"] = false
			continue
		if waiting.is_empty() or _nearest_own_d2(party["at"]) > PARTY_ARRIVE * PARTY_ARRIVE:
			continue
		var was_q: String = _cur_q
		_cur_q = String(party["q"])
		var mobs: Array = _ev_mobs.get(key, [])
		sp.set("arrival", true)
		for m in waiting:
			var pos: Vector3 = (m["at"] as Vector3) + (m["off"] as Vector3)
			pos.y = G.ground_y(pos, (m["at"] as Vector3).y)
			var e: Node3D = _spawn_hostile(sp, pos, int(m["preset"]), int(m["faction"]))
			if e == null:
				continue
			e.set_meta("spawn_group", String(key))
			var lock = m["lock"]
			if is_instance_valid(lock) and e.has_method("assign_target"):
				e.assign_target(lock, true)
			m["node"] = e
			m["out"] = true
			mobs.append(e)
		sp.set("arrival", false)
		_ev_mobs[key] = mobs
		_cur_q = was_q

# ── «Tech Gang»: банда стоит лагерем, её надо разогнать ──────────────────────

func _gang_1(q: Dictionary) -> void:
	var key := _ev_key(String(q["event"]))
	if _ev_abandoned(q, key):
		return
	if _ev_get_point(key) == null:
		return
	if not _ev_mobs.has(key):
		# No target given: the gang stands, and the first move is the player's shot - they can drive
		# up, look and leave. THREE TO FIVE (TerraTech's Tech Gang); the party budget still trims it.
		var n: int = _gang_spawn(key, _ev_point[key] as Vector3)
		Dialogue.say("System", tr("%d units, no transponders. They are not ours.") % n)
	if not _reached(_ev_point[key]):
		return
	Q.report(String(q["event"]), 1)

func _gang_2(q: Dictionary) -> void:
	var key := _ev_key(String(q["event"]))
	if _ev_abandoned(q, key):
		return
	if not _ev_mobs.has(key):
		var at = _ev_get_point(key)      # state lost (a reload): the gang stands there again
		if at != null:
			_gang_spawn(key, at as Vector3)
		return
	if not _ev_all_dead(key):
		return
	_ev_done(q, key)

const GANG_SIZE := Vector2i(3, 5)
const GANG_PRESETS := [5, 6, 7, 8]

func _gang_spawn(key: String, at: Vector3) -> int:
	var presets: Array = []
	for i in randi_range(GANG_SIZE.x, GANG_SIZE.y):
		presets.append(int(GANG_PRESETS[i % GANG_PRESETS.size()]))
	_ev_spawn(key, at, presets)
	return presets.size()

# ── «Supply Drop»: a reward orb, half the time bait ─────────────────────────
## The reward is not a crate lying in the grass but an ORB of glitch cards over the point
## (reward_orb.gd): it opens after HOLD_TIME within HOLD_DIST and the reward drops out of it. Half
## the drops are BAIT: the ambush arrives when the player does (not before - it is a trap, not a
## camp), and the orb stays shut until it is dead. One enemy at the ceiling the player can take, or
## two a step below it (EnemySpawner.preset_below_cap). The bait pays one block more, because it
## cost a fight.
const SUPPLY_LOOT := [G.Block.BATTERY, G.Block.SOLAR, G.Block.BELT, G.Block.ARMOR2, G.Block.REGEN]
## A Marlit drop holds Marlit's own blocks.
const SUPPLY_LOOT_MARLIT := [G.Block.MARLIT_BLOCK, G.Block.MARLIT_SLAB, G.Block.MARLIT_HALF,
		G.Block.MARLIT_ARMOR2, G.Block.MARLIT_GIRDER]
const SUPPLY_BLOCKS := 1
const SUPPLY_TRAP_BLOCKS := 2
const REWARD_ORB := preload("res://reward_orb.gd")

var _supply_trap: Dictionary = {}        # event key -> this drop is bait
var _supply_opened: Dictionary = {}      # event key -> its orb has opened
var _supply_hidden: Dictionary = {}      # event key -> the hidden cache kind
var _supply_t: Dictionary = {}           # event key -> seconds before the hidden cache wipes itself
var _supply_warned: Dictionary = {}
const CACHE_SPREAD := 40.0
const CACHE_TIME := 150.0

func _supply_1(q: Dictionary) -> void:
	var key := _ev_key(String(q["event"]))
	if _ev_abandoned(q, key):
		return
	if _ev_get_point(key) == null:
		return
	var at: Vector3 = _ev_point[key] as Vector3
	if not is_instance_valid(_ev_orb.get(key)):
		# THREE KINDS, AS TERRATECH'S CRATES (the player's list): open, bait, and HIDDEN - the orb lies
		# somewhere within CACHE_SPREAD of the mark (the compass leads to the mark, not to it), a guard
		# stands by it, and from the moment the player reaches the mark it wipes itself in CACHE_TIME.
		var roll: int = randi() % 3
		_supply_trap[key] = roll == 1
		_supply_hidden[key] = roll == 2
		_supply_opened[key] = false
		var orb_at: Vector3 = at
		if roll == 2:
			var a: float = randf() * TAU
			var r: float = randf_range(CACHE_SPREAD * 0.5, CACHE_SPREAD)
			orb_at = at + Vector3(cos(a) * r, 0.0, sin(a) * r)
			orb_at.y = G.ground_y(orb_at, at.y)
			Dialogue.say("System", tr("A cache is hidden somewhere round the mark. It has a guard, and once you are there it wipes itself in %d seconds.") % int(CACHE_TIME))
		else:
			Dialogue.say("System", tr("Something came down intact out there. Get close and it opens."))
		_supply_orb(key, orb_at)
	if not _reached(at):
		return
	if _supply_hidden.get(key, false) and not _ev_mobs.has(key):
		var orb_n = _ev_orb.get(key)
		var sp0: Node = get_node_or_null("/root/Main/EnemySpawner")
		var guard: int = int(sp0.preset_below_cap(0)) if sp0 != null and sp0.has_method("preset_below_cap") else 6
		if is_instance_valid(orb_n):
			_ev_spawn(key, (orb_n as Node3D).global_position, [guard], 1, _player())
			_supply_place(key, (orb_n as Node3D).global_position)
		_supply_t[key] = CACHE_TIME
		_supply_warned[key] = false
	elif _supply_trap.get(key, false) and not _ev_mobs.has(key):
		var sp: Node = get_node_or_null("/root/Main/EnemySpawner")
		var two: bool = randf() < 0.5
		var presets: Array = []
		for i in (2 if two else 1):
			presets.append(int(sp.preset_below_cap(1 if two else 0)) if sp != null \
					and sp.has_method("preset_below_cap") else 6)
		_ev_spawn(key, at, presets, 1, _player())
		_supply_place(key, at)
		Dialogue.say("System", tr("It was bait. Contacts dropping on the drop."))
	elif not _ev_mobs.has(key):
		_ev_mobs[key] = []                    # nobody guards it: "all dead" is true from the start
	Q.report(String(q["event"]), 1)

## A SUPPLY DROP'S ENEMIES LAND ROUND THE DROP, WITHIN SUPPLY_MOB_MAX OF IT (the player's rule: 40 m).
## The hidden cache's guard used to go through `_ev_spawn(.., defer = false)`, whose `clear_point`
## carries a party PLAYER_CLEAR (200 m) + ring + pad out from the player - and the player is standing
## at the mark when it is called, so the guard dropped 225 m off. Now both kinds go through the
## deferred party (`_party_tick` spawns with `arrival`, which skips `clear_point`) and each member's
## point is picked here: SUPPLY_MOB_MIN..MAX from the drop, SUPPLY_MOB_CLEAR from every machine of
## the player's, the side away from the player tried first.
const SUPPLY_MOB_MIN := 14.0
const SUPPLY_MOB_MAX := 38.0
const SUPPLY_MOB_CLEAR := 16.0

func _supply_place(key: String, center: Vector3) -> void:
	if not _ev_party.has(key):
		return
	var own: Array = []
	for m in _own_machines():
		if is_instance_valid(m) and m is Node3D:
			own.append((m as Node3D).global_position)
	var base_ang: float = randf() * TAU
	if not own.is_empty():
		var away := Vector2(center.x - own[0].x, center.z - own[0].z)
		if away.length_squared() > 1.0:
			base_ang = atan2(away.y, away.x)
	var taken: Array = []
	var members: Array = _ev_party[key]["members"]
	for i in members.size():
		var m: Dictionary = members[i]
		if bool(m["out"]) or bool(m["dead"]):
			continue
		var best := Vector3(cos(base_ang), 0.0, sin(base_ang)) * SUPPLY_MOB_MAX
		var found := false
		for ring in 3:
			var r: float = lerpf(SUPPLY_MOB_MAX * 0.75, SUPPLY_MOB_MIN, float(ring) / 2.0)
			for k in 12:
				var a: float = base_ang + float((k + 1) / 2) * (PI / 6.0) * (1.0 if k % 2 == 1 else -1.0) \
						+ float(i) * 0.9
				var off := Vector3(cos(a) * r, 0.0, sin(a) * r)
				var p: Vector3 = center + off
				var ok := true
				for o in own:
					if Vector2(p.x - o.x, p.z - o.z).length_squared() < SUPPLY_MOB_CLEAR * SUPPLY_MOB_CLEAR:
						ok = false
						break
				for t in taken:
					if (p - t).length_squared() < 64.0:
						ok = false
						break
				if ok:
					best = off
					found = true
					break
			if found:
				break
		taken.append(center + best)
		m["at"] = center
		m["off"] = best

func _supply_orb(key: String, at: Vector3) -> void:
	var host: Node = get_tree().current_scene
	if host == null:
		return
	var orb: Node3D = REWARD_ORB.new()
	host.add_child(orb)
	orb.setup(at)
	orb.opened.connect(_on_supply_opened.bind(key))
	_ev_orb[key] = orb

func _on_supply_opened(at: Vector3, key: String) -> void:
	var loot: Array = SUPPLY_LOOT_MARLIT if Q.faction_of(Q._find("event_" + key)) == "marlit" else SUPPLY_LOOT
	var fought: bool = _supply_trap.get(key, false) or _supply_hidden.get(key, false)
	for i in (SUPPLY_TRAP_BLOCKS if fought else SUPPLY_BLOCKS):
		_drop_reward(int(loot.pick_random()), at)
	_supply_opened[key] = true

## A reward block falling out of the air at `at`: an ordinary loose block, the player's to keep.
func _drop_reward(bt: int, at: Vector3) -> void:
	var scene: PackedScene = G.get_scene(bt)
	var objects: Node = get_node_or_null("/root/Main/objects")
	if scene == null or objects == null:
		return
	var node: Node3D = scene.instantiate()
	objects.add_child(node)
	node.global_position = at + Vector3(randf_range(-0.6, 0.6), 0.0, randf_range(-0.6, 0.6))
	if node is RigidBody3D:
		(node as RigidBody3D).freeze = false
	BlockFX.play(node, false)

func _supply_2(q: Dictionary) -> void:
	var key := _ev_key(String(q["event"]))
	if _ev_abandoned(q, key):
		return
	if _supply_opened.get(key, false):
		_supply_opened[key] = false
		_ev_done(q, key)
		return
	var orb = _ev_orb.get(key)
	# STATE LOST (a reload: events are not saved): back to stage 1, which rolls a new drop and, if
	# it is bait, springs it when the player arrives - an ambush spawned here would already be
	# waiting at a point the player has not been told about yet.
	if not is_instance_valid(orb) or not _ev_mobs.has(key):
		_ev_clear(key)
		Q.reset_quest(String(q["id"]))
		return
	var guarded: bool = _supply_trap.get(key, false) or _supply_hidden.get(key, false)
	(orb as Node).set("locked", guarded and not _ev_all_dead(key))
	if not _supply_hidden.get(key, false) or not _supply_t.has(key):
		return
	_supply_t[key] = float(_supply_t[key]) - POLL
	if float(_supply_t[key]) <= 30.0 and not _supply_warned.get(key, false):
		_supply_warned[key] = true
		Dialogue.say("System", tr("Thirty seconds and the cache wipes itself."))
	if float(_supply_t[key]) > 0.0:
		return
	BlockFX.ground_wave(self, (orb as Node3D).global_position, Vector3.UP, 30.0)
	Dialogue.say("System", tr("The cache wiped itself. Nothing left to take."))
	_supply_t.erase(key)
	_ev_clear(key)
	_ev_cool[String(q["id"])] = _event_cooldown()
	Q.skip_quest(String(q["id"]))

# ── «Defend Friendly Tech»: союзника бьют, его надо отбить ──────────────────

func _defend_1(q: Dictionary) -> void:
	var key := _ev_key(String(q["event"]))
	if _ev_abandoned(q, key):
		return
	if _ev_get_point(key) == null:
		return
	if not _ev_mobs.has(key):
		var at: Vector3 = _ev_point[key] as Vector3
		# СОЮЗНИК — обычная машина ИИ нашей фракции (0). Фракция и решает всё: чужие видят в
		# ней врага и бьют её, а по игроку она не стреляет (enemy_vehicle._is_enemy сравнивает
		# именно фракцию). Отдельной «дружественной» сущности заводить незачем.
		var ally: Array = _ev_spawn(key, at, [6], 0)
		if ally.is_empty():
			_ev_clear(key)
			_ev_cool[String(q["id"])] = _event_cooldown()
			Q.skip_quest(String(q["id"]))
			return
		_ev_ally[key] = ally[0]
		_ev_spawn(key, at + Vector3(20.0, 0.0, 0.0), [6, 7], 1, ally[0])
		Dialogue.say("System", tr("Friendly unit under fire. It will not last alone."))
	if not _reached(_ev_point[key]):
		return
	Q.report(String(q["event"]), 1)

var _ev_ally: Dictionary = {}           # event key -> the friendly unit being covered

func _defend_2(q: Dictionary) -> void:
	var key := _ev_key(String(q["event"]))
	if _ev_abandoned(q, key):
		return
	if not _ev_mobs.has(key):
		# Состояние потеряно (перезаход): союзник и налётчики появляются заново, иначе
		# пустая ссылка на союзника читалась бы как «его добили».
		var at = _ev_get_point(key)
		if at != null:
			var ally: Array = _ev_spawn(key, at as Vector3, [6], 0)
			if not ally.is_empty():
				_ev_ally[key] = ally[0]
				_ev_spawn(key, (at as Vector3) + Vector3(20.0, 0.0, 0.0), [6, 7], 1, ally[0])
		return
	# Союзника добили — защищать больше некого. Это не поражение с наказанием, а снятое
	# задание: цель исчезла не по вине игрока (см. Q.skip_quest).
	# A skipped event cools down like an abandoned one: skip_quest marks it done, and only the
	# cooldown ever opens it again - without it Defend happened once a save.
	var ally = _ev_ally.get(key)
	if not is_instance_valid(ally):
		_ev_ally.erase(key)
		_ev_clear(key)
		_ev_cool[String(q["id"])] = _event_cooldown()
		Q.skip_quest(String(q["id"]))
		return
	# TWO MINUTES IN THE ZONE, THEN IT IS YOURS (TerraTech's Defend Friendly Tech, the player's
	# call): the clock runs while the player is within DEFEND_ZONE of the ally, a second group of
	# raiders comes at half time, and an ally still standing at DEFEND_TIME joins the player as one
	# of their own machines (`_adopt_machine`). Raiders left over stay - they are no longer the job.
	var p: Node3D = _player()
	if p != null and p.global_position.distance_squared_to((ally as Node3D).global_position) \
			< DEFEND_ZONE * DEFEND_ZONE:
		_defend_t[key] = float(_defend_t.get(key, 0.0)) + POLL
	var t: float = float(_defend_t.get(key, 0.0))
	if t >= DEFEND_TIME * 0.5 and not _defend_wave2.get(key, false):
		_defend_wave2[key] = true
		_ev_spawn(key, (ally as Node3D).global_position + Vector3(-25.0, 0.0, 15.0), [6, 7], 1, ally, false)
		Dialogue.say("System", tr("More of them. Hold on - a minute to go."))
	if t < DEFEND_TIME:
		return
	_defend_t.erase(key)
	_defend_wave2.erase(key)
	_ev_ally.erase(key)
	for m in _ev_mobs.get(key, []):
		if is_instance_valid(m) and m != ally:
			_release_machine(m)
	Dialogue.say("System", tr("It held. The crew is grateful - the machine is yours to drive."))
	_adopt_machine(ally as Node3D)
	_ev_done(q, key)

const DEFEND_TIME := 120.0
const DEFEND_ZONE := 90.0
var _defend_t: Dictionary = {}
var _defend_wave2: Dictionary = {}

## An AI machine of the player's side becomes one of the player's own: the same build, born whole
## where it stood, in the camera controller's `vehicles` so it can be switched to and is saved.
func _adopt_machine(m: Node3D) -> void:
	if not is_instance_valid(m):
		return
	var bl: Node = m.get_node_or_null("blocks")
	var preset = bl.get("layout_preset") if bl != null else null
	var at: Vector3 = m.global_position
	var basis_y: float = m.global_rotation.y
	m.queue_free()
	var vr: Node = get_node_or_null("/root/Main/Vehicles")
	var scene: PackedScene = load("res://player_vehicle.tscn")
	if vr == null or scene == null or preset == null:
		return
	var v: Node3D = scene.instantiate()
	var vb: Node = v.get_node_or_null("blocks")
	if vb != null and "layout_preset" in vb:
		vb.layout_preset = int(preset)
	vr.add_child(v)
	v.global_position = at + Vector3.UP * 1.0
	v.global_rotation.y = basis_y
	var cc: Node = get_tree().get_first_node_in_group("camera_controller")
	if cc != null and "vehicles" in cc and not cc.vehicles.has(v):
		cc.vehicles.append(v)

# ── "Take the Staging Point": capture a base WITHOUT destroying it ───────────
## TerraTech's Capture Enemy Base (the player's call: make it a real capture). A hostile turret
## post stands on the point with a guard party: stage 1 is reaching it, stage 2 is breaking the guard
## and DISARMING the post - every weapon on it shot off while its core lives - and stage 3 is holding
## the point CAPTURE_HOLD seconds within CAPTURE_DIST of it. Then the post is the player's: its
## enemy machine goes and what is left of it - support, battery, panels, dome - stands again on the
## same spot as one of the player's stations (`_spawn_station`), saved like any base. The post's
## core destroyed, there is nothing to take: the event is dropped and cools down.
const CAMP_POSTS := [13, 14]          # turret posts: a rotating support, a battery, panels, a dome, two guns
const CAPTURE_DIST := 15.0
const CAPTURE_HOLD := 10.0
var _ev_base: Dictionary = {}         # event key -> the hostile base to take
var _camp_hold: Dictionary = {}       # event key -> seconds held so far

func _camp_post(key: String, at: Vector3) -> void:
	var b = _ev_base.get(key)
	if is_instance_valid(b):
		return
	var sp: Node = get_node_or_null("/root/Main/EnemySpawner")
	if sp == null:
		return
	var post: Node3D = _ask_spawner(sp, at, int(CAMP_POSTS.pick_random()), 1, true)
	if post != null:
		_ev_base[key] = post

## Weapons still on the post (WeaponBlock children of its grid).
func _post_armed(post: Node) -> int:
	var bl: Node = post.get_node_or_null("blocks")
	var n := 0
	if bl != null:
		for c in bl.get_children():
			if c is WeaponBlock and not c.is_queued_for_deletion():
				n += 1
	return n

## The post was there and is gone: the event cannot be won any more.
func _camp_lost(q: Dictionary, key: String) -> bool:
	if not _ev_base.has(key) or is_instance_valid(_ev_base[key]):
		return false
	Dialogue.say("System", tr("The post is wrecked. Nothing left to take."))
	_ev_clear(key)
	_ev_cool[String(q["id"])] = _event_cooldown()
	Q.skip_quest(String(q["id"]))
	return true

func _camp_1(q: Dictionary) -> void:
	var key := _ev_key(String(q["event"]))
	if _ev_abandoned(q, key):
		return
	if _ev_get_point(key) == null:
		return
	var at: Vector3 = _ev_point[key] as Vector3
	_camp_post(key, at)
	if not _ev_mobs.has(key):
		_ev_spawn(key, at, [7, 8, 9], 1, _player())
		Dialogue.say("System", tr("That is a staging point, not a patrol. Take it intact: strip its guns, keep its core."))
	if _camp_lost(q, key):
		return
	if not _reached(_ev_point[key]):
		return
	Q.report(String(q["event"]), 1)

func _camp_2(q: Dictionary) -> void:
	var key := _ev_key(String(q["event"]))
	if _ev_abandoned(q, key):
		return
	var at = _ev_get_point(key)
	if at == null:
		return
	if not _ev_mobs.has(key):
		_ev_spawn(key, at as Vector3, [7, 8, 9], 1, _player())   # state lost (a reload): the guard again
	_camp_post(key, at as Vector3)
	if _camp_lost(q, key):
		return
	if not _ev_all_dead(key):
		return
	var post = _ev_base.get(key)
	if not is_instance_valid(post) or _post_armed(post) > 0:
		return
	Dialogue.say("System", tr("The post is disarmed. Stay by it and it is yours."))
	Q.report(String(q["event"]), 1)

func _camp_3(q: Dictionary) -> void:
	var key := _ev_key(String(q["event"]))
	if _ev_abandoned(q, key):
		return
	var post = _ev_base.get(key)
	if not is_instance_valid(post):
		if not _camp_lost(q, key):
			Q.reset_quest(String(q["id"]))      # state lost (a reload): the post again from stage one
		return
	var p: Node3D = _player()
	var pp: Vector3 = (post as Node3D).global_position
	if p == null or Vector2(p.global_position.x - pp.x, p.global_position.z - pp.z).length_squared() \
			> CAPTURE_DIST * CAPTURE_DIST:
		return
	_camp_hold[key] = float(_camp_hold.get(key, 0.0)) + POLL
	if float(_camp_hold[key]) < CAPTURE_HOLD:
		return
	_capture_post(post as Node3D)
	_ev_base.erase(key)
	_camp_hold.erase(key)
	Dialogue.say("System", tr("Post captured. It is one of your bases now."))
	_ev_done(q, key)

## The hostile post becomes the player's station: what is left of it, on the same ground.
func _capture_post(post: Node3D) -> void:
	var bl: Node = post.get_node_or_null("blocks")
	var layout: Array = bl.get_layout() if bl != null and bl.has_method("get_layout") else []
	var at: Vector3 = post.global_position
	at.y = G.ground_y(at, at.y - 0.5)
	post.queue_free()
	if not layout.is_empty():
		_spawn_station(at, layout)

# ── RACES: Aero's licence, Aero's story and Aero's events (race_track.gd) ────
## Every timed course is one handler (`_course_1` reach the start, `_course_2` run it) over COURSES:
## RACE AGAINST TIME (TerraTech's Venture licence, the player's call) - start to finish in under a
## minute, the course KEPT in the world after it (as TerraTech's was, `keep`, saved, still timed);
## PLATEAU RUN - a course that climbs; LOOSE GROUND (TerraTech's "A Slippery Slope", renamed) - one that
## runs downhill; and the repeatable races - a checkpoint course, a drag strip, a slalom. A failed run
## is no loss: drive through the start gate again. A course's limit is RACE_LIMIT or its length over
## `speed` plus COURSE_SPARE. NO RAMP JUMP: wheels read the terrain's heights and nothing else
## (Driving and wheels), so a ramp would have to be a terrain edit - not a prop.
const RACE_TRACK := preload("res://race_track.gd")
const RACE_LIMIT := 60.0
const COURSE_SPARE := 8.0
const COURSES := {
	"race":    {"gates": 9, "leg": 45.0, "climb": 0, "limit": RACE_LIMIT, "keep": true},
	"plateau": {"gates": 7, "leg": 50.0, "climb": 1, "speed": 7.0},
	"descent": {"gates": 7, "leg": 45.0, "climb": -1, "speed": 9.0},
	"acourse": {"gates": 8, "leg": 45.0, "climb": 0, "speed": 10.0},
	"adrag":   {"gates": 2, "leg": 260.0, "climb": 0, "speed": 15.0},
	"aslalom": {"gates": 9, "leg": 32.0, "climb": 0, "speed": 8.0, "slalom": 9.0},
}
var _tracks: Dictionary = {}        # course key -> its race_track node

## The course of a key: in memory, or one the save brought back (meta `track_key`).
func _track_of(key: String) -> Variant:
	var t = _tracks.get(key)
	if is_instance_valid(t):
		return t
	for n in get_tree().get_nodes_in_group("race_tracks"):
		if (n as Node).get_meta("track_key", "") == key and not (n as Node).is_queued_for_deletion():
			_tracks[key] = n
			return n
	return null

func _drop_track(key: String) -> void:
	var t = _tracks.get(key)
	if is_instance_valid(t) and t.get("keep") != true:
		(t as Node).queue_free()
	_tracks.erase(key)

## Lay a course from `start` along `heading`: each next gate `leg` on, turned by whichever of a few
## angles keeps the ground gentlest (`climb` 1 prefers rising ground, -1 falling). Points on the
## ground; a leg that would come back near an earlier gate is not taken. `slalom` swings every other
## gate that far to alternate sides of the line.
func _lay_course(start: Vector3, heading: float, gates: int, leg: float, climb: int = 0,
		slalom: float = 0.0) -> Array:
	var pts: Array = [Vector3(start.x, G.ground_y(start, start.y), start.z)]
	var h: float = heading
	var line: Vector3 = pts[0]
	for i in range(1, gates):
		var prev: Vector3 = line
		var best := Vector3.ZERO
		var best_h := h
		var best_s := INF
		for k in 9:
			var turn: float = deg_to_rad(-40.0 + 10.0 * float(k)) * (0.3 if slalom > 0.0 else 1.0) \
					+ randf_range(-0.05, 0.05)
			var nh: float = h + turn
			var c: Vector3 = prev + Vector3(cos(nh), 0.0, sin(nh)) * leg
			c.y = G.ground_y(c, prev.y)
			var mid: Vector3 = (prev + c) * 0.5
			var mid_y: float = G.ground_y(mid, prev.y)
			var rise: float = c.y - prev.y
			var bump: float = absf(mid_y - (prev.y + c.y) * 0.5)
			var side: float = absf(G.ground_y(c + Vector3(3.0, 0, 0), c.y) - c.y) + absf(G.ground_y(c + Vector3(0, 0, 3.0), c.y) - c.y)
			var sc: float = bump * 2.0 + side * 2.0 + absf(turn) * 2.0
			sc += absf(rise) * 1.5 if climb == 0 else -float(climb) * rise * 2.0 + maxf(-float(climb) * rise, 0.0) * 4.0
			for q in pts.slice(0, pts.size() - 1):
				if (q as Vector3).distance_squared_to(c) < leg * leg * 0.8:
					sc += 1000.0
			if sc < best_s:
				best_s = sc
				best = c
				best_h = nh
		line = best
		h = best_h
		var put: Vector3 = best
		if slalom > 0.0 and i < gates - 1:
			var side_v := Vector3(-sin(h), 0.0, cos(h)) * (slalom if i % 2 == 1 else -slalom)
			put = best + side_v
			put.y = G.ground_y(put, best.y)
		pts.append(put)
	return pts

func _course_limit(cfg: Dictionary, pts: Array) -> float:
	if cfg.has("limit"):
		return float(cfg["limit"])
	var len_m := 0.0
	for i in range(pts.size() - 1):
		len_m += (pts[i] as Vector3).distance_to(pts[i + 1])
	return ceilf((len_m / float(cfg["speed"]) + COURSE_SPARE) / 5.0) * 5.0

func _make_track(key: String, pts: Array, limit: float, keep: bool) -> Node:
	var root: Node = get_node_or_null("/root/Main")
	if root == null:
		return null
	var t: Node3D = RACE_TRACK.new()
	t.set_meta("track_key", key)
	t.keep = keep
	root.add_child(t)
	t.setup(pts, limit)
	_tracks[key] = t
	return t

## Stage 1 of any course: lay it (once) and reach its start gate.
func _course_1(q: Dictionary) -> void:
	var key := _ev_key(String(q["event"]))
	var event: bool = int(q.get("type", -1)) == Q.Type.EVENT
	if event and _ev_abandoned(q, key):
		return
	var p: Node3D = _player()
	if p == null:
		return
	var t = _track_of(key)
	if t == null:
		var cfg: Dictionary = COURSES[key]
		var start: Vector3 = _far_point(p)
		var away: Vector3 = start - p.global_position
		var pts: Array = _lay_course(start, atan2(away.z, away.x), int(cfg["gates"]), float(cfg["leg"]),
				int(cfg.get("climb", 0)), float(cfg.get("slalom", 0.0)))
		t = _make_track(key, pts, _course_limit(cfg, pts), cfg.get("keep", false) == true)
		if t == null:
			return
		var line: String = _course_line(key, "open")
		if line != "":
			Dialogue.say("Aero", tr(line) % _limit_text((t as Node).get("time_limit")))
	if event:
		_ev_point[key] = (t as Node).get("points")[0]
	if _reached((t as Node).get("points")[0]):
		Q.report(String(q["event"]), 1)

## Stage 2: run it. The track reports by signal; a lost course (a reload) is laid again from stage 1.
func _course_2(q: Dictionary) -> void:
	var key := _ev_key(String(q["event"]))
	if int(q.get("type", -1)) == Q.Type.EVENT and _ev_abandoned(q, key):
		return
	var t = _track_of(key)
	if t == null:
		Q.reset_quest(String(q["id"]))
		return
	if not (t as Node).is_connected("finished", _on_course_finished):
		(t as Node).connect("finished", _on_course_finished.bind(key, String(q["id"])))
		(t as Node).connect("failed", _on_course_failed.bind(key, String(q["id"])))

func _on_course_finished(_secs: float, key: String, qid: String) -> void:
	var q: Dictionary = Q.find_quest(qid)
	if q.is_empty() or q.get("done", false) or _ev_key(String(q.get("event", ""))) != key:
		return
	var line: String = _course_line(key, "done")
	if line != "":
		Dialogue.say("Aero", tr(line))
	if int(q.get("type", -1)) == Q.Type.EVENT:
		_ev_done(q, key)
	else:
		Q.report(String(q["event"]), 1)
	_drop_track(key)

func _on_course_failed(key: String, qid: String) -> void:
	var q: Dictionary = Q.find_quest(qid)
	if not q.is_empty() and not q.get("done", false):
		var line: String = _course_line(key, "fail")
		if line != "":
			Dialogue.say("Aero", tr(line))

static func _limit_text(secs) -> String:
	var t: int = int(secs)
	return "%d:%02d" % [t / 60, t % 60]

## What Aero says about a course: when it is laid (the time limit goes in), run, and failed.
func _course_line(key: String, what: String) -> String:
	var lines := {
		"race": ["Aero deals with the fast, not the strong. Our course is marked out there: start to finish inside %s.",
			"That will do. The course is yours to keep - come back and beat your time.",
			"Over the limit. The start gate is right where you left it."],
		"plateau": ["Up to the plateau, gate by gate, inside %s. Climbing is where a heavy machine shows itself.",
			"On top, and in time. Aero noticed.", "Too slow on the climb. The start gate is waiting."],
		"descent": ["Loose ground all the way down. Gate by gate to the bottom inside %s - and stay on your wheels.",
			"Down in one piece. That is the trick of it.", "Too slow, or too careful. Back to the start gate."],
		"acourse": ["A fresh course is marked out. Inside %s.", "Clean run.", "Too slow. Through the start gate again."],
		"adrag": ["A straight strip, two gates. Inside %s - nothing to do but go.", "Fast enough.", "Too slow off the line. Again."],
		"aslalom": ["A slalom: every gate swings the other way. Inside %s.", "Every gate. Good.", "Too slow through the gates. Again."],
	}
	var i: int = {"open": 0, "done": 1, "fail": 2}.get(what, 0)
	return String((lines.get(key, ["", "", ""]) as Array)[i])

# ── PURSUIT: catch it within a minute (TerraTech's chase) ───────────────────
## A light hostile machine waits at a point and RUNS from the player once they come within
## `enemy_vehicle.RUN_NOTICE` (`runaway_from`); from the moment it bolts the player has CHASE_TIME to
## destroy it, or it gets away - gone, and the event cools down.
const CHASE_TIME := 60.0
const CHASE_PRESETS := [5]
var _chase_t: Dictionary = {}         # key -> seconds left once it has bolted

func _chase_1(q: Dictionary) -> void:
	var key := _ev_key(String(q["event"]))
	if _ev_abandoned(q, key):
		return
	var at = _ev_get_point(key)
	if at == null:
		return
	if not _ev_mobs.has(key):
		var got: Array = _ev_spawn(key, at as Vector3, CHASE_PRESETS, 1, null, false)
		for m in got:
			if is_instance_valid(m):
				m.set("runaway_from", _player())
		Dialogue.say("Aero", tr("Something fast is parked out there and it does not want company. Catch it before it is gone."))
	var p: Node3D = _player()
	for m in _ev_mobs.get(key, []):
		if is_instance_valid(m):
			m.set("runaway_from", p)
			if p != null and (m as Node3D).global_position.distance_to(p.global_position) < 90.0:
				_chase_t[key] = CHASE_TIME
				Q.report(String(q["event"]), 1)
				return
	if _ev_all_dead(key):
		_ev_done(q, key)                       # killed before it ever bolted

func _chase_2(q: Dictionary) -> void:
	var key := _ev_key(String(q["event"]))
	if not _ev_mobs.has(key) or not _chase_t.has(key):
		Q.reset_quest(String(q["id"]))           # state lost (a reload)
		return
	if _ev_all_dead(key):
		_chase_t.erase(key)
		_ev_done(q, key)
		return
	_chase_t[key] = float(_chase_t[key]) - POLL
	if float(_chase_t[key]) > 0.0:
		return
	Dialogue.say("Aero", tr("Gone. Faster next time."))
	_chase_t.erase(key)
	_ev_clear(key)
	_ev_cool[String(q["id"])] = _event_cooldown()
	Q.skip_quest(String(q["id"]))

# ── STRANDED RACER (TerraTech's Mine Island Rescue, renamed): clear the hostiles off it ──────
## An Aero machine with its wheels gone (blocks.AERO_WRECK, the player's faction) sits at a point with
## a hostile party round it, aimed at it. Reach it; kill everything hostile there while it still
## stands. It destroyed, the quest starts over. A story quest: no cooldown, no 500 m drop.
const AERO_WRECK_PRESET := 129          # blocks.AERO_WRECK

func _strand_1(q: Dictionary) -> void:
	var key := "astrand"
	var at = _ev_get_point(key)
	if at == null:
		return
	_strand_spawn(key, at as Vector3)
	if _reached(at):
		Q.report(String(q["event"]), 1)

func _strand_spawn(key: String, at: Vector3) -> void:
	if _ev_mobs.has(key):
		return
	var ally: Array = _ev_spawn(key, at, [AERO_WRECK_PRESET], 0)
	if ally.is_empty():
		return
	_ev_ally[key] = ally[0]
	_ev_spawn(key, at + Vector3(18.0, 0.0, 0.0), [6, 7], 1, ally[0])
	Dialogue.say("Aero", tr("One of ours lost its wheels out there and the locals have noticed. Get them off it."))

func _strand_2(q: Dictionary) -> void:
	var key := "astrand"
	var at = _ev_get_point(key)
	if at == null:
		return
	if not _ev_mobs.has(key):
		_strand_spawn(key, at as Vector3)        # state lost (a reload): the wreck and its attackers again
		return
	var ally = _ev_ally.get(key)
	if not is_instance_valid(ally):
		Dialogue.say("Aero", tr("We lost it. Another one is stuck out there - try again."))
		_forget_event(key)
		Q.reset_quest(String(q["id"]))
		return
	if _party_open(key):
		return
	for m in _ev_mobs.get(key, []):
		if is_instance_valid(m) and m != ally:
			return
	Dialogue.say("Aero", tr("Clear. A recovery crew is on its way for it. Aero will remember this."))
	_release_machine(ally)
	_ev_ally.erase(key)
	_ev_mobs.erase(key)
	_ev_party.erase(key)
	_ev_point.erase(key)
	Q.report(String(q["event"]), 1)

# ── BIRD OF PREY: Stryx's licence (TerraTech's Hawkeye licence mission) ──────────────────────
## GSO asks the player to look at a mysterious heat signature: a crashed Stryx capsule and burnt-out
## machines lie at a point - a picture, nothing to pick up. Within BOP_NOTICE of it the Mechanic hears
## something, and three capsules are SEEN falling (BOP_FALL seconds from BOP_HIGH) to land round the
## site; out of each comes a machine of Stryx's stubs named "Cleanup Crew" (meta `display_name`) -
## two troopers and a heavy - and the task is all three. The licence is the reward
## (G.FACTION_LICENCE). The only licence with no faction voice: the crew is there to hide what GSO
## is not meant to see. A story quest, guaranteed (the player: TerraTech's drew it at random from a
## board, and players hunted it for hours). State is memory: a reload goes back to the site.
const BOP_NOTICE := 60.0
const BOP_HIGH := 150.0
const BOP_FALL := 3.0                # = EnemySpawner.DROP_WARN: the crew drops as its capsule lands
const BOP_RING := 30.0
const BOP_CREW := [130, 130, 131]       # blocks.STRYX_TROOPER x2, blocks.STRYX_HEAVY
var _bop_site: Node3D = null
var _bop_crew: Array = []
var _bop_dropping: int = 0

func _bop_mat(c: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = c
	return m

func _bop_capsule() -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var cm := CapsuleMesh.new()
	cm.radius = 1.3
	cm.height = 4.2
	cm.radial_segments = 10
	cm.rings = 3
	mi.mesh = cm
	mi.material_override = _bop_mat(Color(0.22, 0.27, 0.2))
	var band := MeshInstance3D.new()
	var cy := CylinderMesh.new()
	cy.top_radius = 1.34
	cy.bottom_radius = 1.34
	cy.height = 0.35
	cy.radial_segments = 10
	band.mesh = cy
	band.material_override = _bop_mat(Color(0.75, 0.15, 0.1))
	mi.add_child(band)
	return mi

## The crash site: the capsule on its side, half in the ground, and burnt blocks round it.
func _bop_make_site(at: Vector3) -> void:
	var root: Node = get_node_or_null("/root/Main")
	if root == null:
		return
	_bop_site = Node3D.new()
	root.add_child(_bop_site)
	_bop_site.global_position = at
	var cap := _bop_capsule()
	_bop_site.add_child(cap)
	cap.position = Vector3(0.0, 0.4, 0.0)
	cap.rotation = Vector3(deg_to_rad(80.0), randf() * TAU, deg_to_rad(12.0))
	var burnt := _bop_mat(Color(0.09, 0.08, 0.08))
	for i in 9:
		var b := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3.ONE
		b.mesh = bm
		b.material_override = burnt
		_bop_site.add_child(b)
		var a: float = randf() * TAU
		var r: float = randf_range(3.0, 8.0)
		var p := at + Vector3(cos(a) * r, 0.0, sin(a) * r)
		b.global_position = Vector3(p.x, G.ground_y(p, at.y) + randf_range(-0.2, 0.3), p.z)
		b.rotation = Vector3(randf() * TAU, randf() * TAU, randf() * TAU)

func _bop_1(q: Dictionary) -> void:
	var at = _ev_get_point("bop")
	if at == null:
		return
	if not is_instance_valid(_bop_site):
		_bop_make_site(at as Vector3)
	var p: Node3D = _player()
	if p == null:
		return
	var d := Vector2(p.global_position.x - (at as Vector3).x, p.global_position.z - (at as Vector3).z)
	if d.length_squared() > BOP_NOTICE * BOP_NOTICE:
		return
	Dialogue.say("Mechanic", tr("What's that noise?"))
	_bop_drop(at as Vector3)
	Q.report(String(q["event"]), 1)

## Three capsules seen falling onto the ring round the site; each one that lands sets down its machine.
func _bop_drop(at: Vector3) -> void:
	var root: Node = get_node_or_null("/root/Main")
	if root == null:
		return
	_bop_crew.clear()
	var a0: float = randf() * TAU
	for i in BOP_CREW.size():
		var a: float = a0 + TAU * float(i) / float(BOP_CREW.size())
		var land := at + Vector3(cos(a) * BOP_RING, 0.0, sin(a) * BOP_RING)
		land.y = G.ground_y(land, at.y)
		var cap := _bop_capsule()
		root.add_child(cap)
		cap.global_position = land + Vector3.UP * BOP_HIGH
		# the crew member is asked for NOW: the spawner holds it over its drop ring for exactly the
		# capsule's fall (EnemySpawner.DROP_WARN) and lets it go as the capsule touches down
		var tw := create_tween()
		tw.tween_property(cap, "global_position", land + Vector3.UP * 2.0, BOP_FALL) \
				.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
		tw.tween_callback(_bop_land.bind(cap, land))
		_bop_dropping += 1
		_bop_spawn(land, int(BOP_CREW[i]))

func _bop_land(cap: Variant, land: Vector3) -> void:
	_bop_dropping = maxi(_bop_dropping - 1, 0)
	if is_instance_valid(cap):
		(cap as Node).queue_free()
	BlockFX.ground_wave(self, land, Vector3.UP, 30.0)

func _bop_spawn(land: Vector3, preset: int) -> void:
	var sp: Node = get_node_or_null("/root/Main/EnemySpawner")
	if sp == null:
		return
	var was_q: String = _cur_q
	_cur_q = "arc_stryx"
	sp.set("arrival", true)
	var e: Node3D = _spawn_hostile(sp, land, preset, 1)
	sp.set("arrival", false)
	_cur_q = was_q
	if e == null:
		return
	e.set_meta("display_name", "Cleanup Crew")
	if e.has_method("assign_target"):
		e.assign_target(_player(), true)
	_bop_crew.append(e)

func _bop_2(q: Dictionary) -> void:
	if _bop_dropping > 0:
		return
	var live := 0
	for m in _bop_crew:
		if is_instance_valid(m):
			live += 1
	if _bop_crew.is_empty():
		Q.reset_quest(String(q["id"]))           # state lost (a reload): back to the site
		return
	if live > 0:
		return
	_bop_crew.clear()
	Dialogue.say("System", tr("The cleaners are gone. Whatever they were hiding, Stryx will deal with you now - as a contractor."))
	Q.report(String(q["event"]), 1)

# ── ROCK CREEK BRIDGE (Marlit's story; TerraTech's GeoCorp mission) ─────────────────────────
## A toll keeper sits on the crossing in a heavy Stryx build (`enemy_vehicle.standoff`: it waits and
## looks for nobody). Within ROCK_TALK the player is asked: pay ROCK_TOLL (the player's call: the
## original's 100 000 does not fit this economy, where quests pay 200-1200) and it drives off, or
## fight. Crossing ROCK_LINE, shooting it, or refusing starts the fight, and beating it pays in Stryx
## blocks early - before the Stryx licence, as the original handed Hawkeye blocks to whoever won.
const ROCK_TOLL := 2500
const ROCK_TALK := 150.0
const ROCK_LINE := 60.0
const ROCK_PRESET := 131                 # blocks.STRYX_HEAVY
const ROCK_LOOT := [G.Block.STRYX_GUN, G.Block.STRYX_CANNON, G.Block.STRYX_ARMOR2]
var _rock: Node3D = null
var _rock_asked: bool = false
var _rock_paid: bool = false
var _rock_dialog: ConfirmationDialog = null

func _rock_spawn(at: Vector3) -> void:
	var sp: Node = get_node_or_null("/root/Main/EnemySpawner")
	if sp == null:
		return
	var was_q: String = _cur_q
	_cur_q = "mrock"
	_rock = _spawn_hostile(sp, at, ROCK_PRESET, 1)
	_cur_q = was_q
	if _rock == null:
		return
	_rock.set("standoff", true)
	_rock.set_meta("display_name", "Toll Keeper")
	_rock_asked = false
	_rock_paid = false

func _rock_1(q: Dictionary) -> void:
	var at = _ev_get_point("rock")
	if at == null:
		return
	if not is_instance_valid(_rock):
		_rock_spawn(at as Vector3)
		Dialogue.say("Marlit", tr("Someone has taken the crossing at Rock Creek and charges for it. Marlit's convoys will not pay. Will you?"))
	var p: Node3D = _player()
	if p == null or not is_instance_valid(_rock):
		return
	if p.global_position.distance_squared_to(_rock.global_position) > ROCK_TALK * ROCK_TALK:
		return
	Q.report(String(q["event"]), 1)

func _rock_2(q: Dictionary) -> void:
	if not is_instance_valid(_rock):
		if _rock_paid or _rock_dead:
			_rock_finish(q)
		else:
			Q.reset_quest(String(q["id"]))      # state lost (a reload): the keeper sits there again
		return
	if _rock_paid:
		return
	var p: Node3D = _player()
	if p == null:
		return
	if not _rock_asked:
		_rock_asked = true
		_rock_ask()
	var standing: bool = _rock.get("standoff") == true
	if standing and p.global_position.distance_squared_to(_rock.global_position) < ROCK_LINE * ROCK_LINE:
		Dialogue.say("Toll Keeper", tr("Over the line without paying. Your mistake."))
		_rock_fight()

func _rock_ask() -> void:
	Dialogue.say("Toll Keeper", tr("This crossing is mine. %d$ and you drive on. Cross the line without paying and you do not.") % ROCK_TOLL)
	if _rock_dialog == null or not is_instance_valid(_rock_dialog):
		_rock_dialog = ConfirmationDialog.new()
		_rock_dialog.title = tr("Rock Creek Bridge")
		_rock_dialog.cancel_button_text = tr("Fight")
		_rock_dialog.confirmed.connect(_rock_pay)
		_rock_dialog.canceled.connect(_rock_fight)
		add_child(_rock_dialog)
	_rock_dialog.ok_button_text = tr("Pay %d$") % ROCK_TOLL
	_rock_dialog.dialog_text = tr("The toll keeper wants %d$ for the crossing.") % ROCK_TOLL
	_rock_dialog.get_ok_button().disabled = G.money < ROCK_TOLL
	_rock_dialog.popup_centered(Vector2i(420, 150))

func _rock_pay() -> void:
	if not is_instance_valid(_rock) or G.money < ROCK_TOLL:
		return
	G.money -= ROCK_TOLL
	G.mark_progress_dirty()
	_rock_paid = true
	Dialogue.say("Toll Keeper", tr("Pleasure doing business."))
	_rock.set("standoff", false)
	_rock.set("runaway_from", _player())
	get_tree().create_timer(8.0).timeout.connect(_rock_leave)

func _rock_leave() -> void:
	if is_instance_valid(_rock):
		_rock.queue_free()

var _rock_dead: bool = false

func _rock_fight() -> void:
	if not is_instance_valid(_rock) or _rock_paid or _rock.get("standoff") != true:
		return
	_rock.set("standoff", false)
	if _rock.has_method("assign_target"):
		_rock.assign_target(_player(), true)
	if _rock.has_signal("died") and not _rock.died.is_connected(_on_rock_died):
		_rock.died.connect(_on_rock_died, CONNECT_ONE_SHOT)

func _on_rock_died(_x = null) -> void:
	_rock_dead = true

func _rock_finish(q: Dictionary) -> void:
	if _rock_dead:
		for bt in ROCK_LOOT:
			_award(int(bt))
		Dialogue.say("Marlit", tr("The crossing is open. Its keeper drove Stryx hardware - it is yours now."))
	else:
		Dialogue.say("Marlit", tr("Paid, and the crossing is open. Marlit would have fought."))
	_rock = null
	_rock_dead = false
	_rock_paid = false
	_ev_point.erase("rock")
	Q.report(String(q["event"]), 1)

# ── QUIET JOB (TerraTech's Hawkeye "Wet Work", renamed): stop the courier ────────────────────
## A courier with two escorts waits at a point; once the player is within QUIET_NOTICE it drives for
## its drop QUIET_RUN on (`enemy_vehicle.travel_to`), the escorts turn on the player. Destroy the
## courier before it gets there; it arrives, the job is lost and starts over.
const QUIET_NOTICE := 150.0
const QUIET_RUN := 350.0
const QUIET_COURIER := 7
const QUIET_ESCORTS := [6, 6]
var _quiet: Node3D = null
var _quiet_drop: Variant = null
var _quiet_dead: bool = false

func _quiet_spawn(at: Vector3) -> void:
	var sp: Node = get_node_or_null("/root/Main/EnemySpawner")
	if sp == null:
		return
	var was_q: String = _cur_q
	_cur_q = "stryx_quiet"
	_quiet = _spawn_hostile(sp, at, QUIET_COURIER, 1)
	if _quiet != null:
		_quiet.set("standoff", true)
		_quiet.set_meta("display_name", "Courier")
		if _quiet.has_signal("died"):
			_quiet.died.connect(func(_x = null): _quiet_dead = true, CONNECT_ONE_SHOT)
		var p: Node3D = _player()
		for i in QUIET_ESCORTS.size():
			var e: Node3D = _spawn_hostile(sp, at + Vector3(10.0 * (i * 2 - 1), 0.0, 8.0), int(QUIET_ESCORTS[i]), 1)
			if e != null and p != null and e.has_method("assign_target"):
				e.assign_target(p, true)
	_cur_q = was_q
	_quiet_dead = false

func _quiet_1(q: Dictionary) -> void:
	var at = _ev_get_point("quiet")
	if at == null:
		return
	if not is_instance_valid(_quiet):
		_quiet_spawn(at as Vector3)
		Dialogue.say("Stryx", tr("A courier is carrying something we want buried. It waits out there with an escort. When it moves, it must not arrive."))
	var p: Node3D = _player()
	if p == null or not is_instance_valid(_quiet):
		return
	if p.global_position.distance_squared_to(_quiet.global_position) > QUIET_NOTICE * QUIET_NOTICE:
		return
	var away: Vector3 = _quiet.global_position - p.global_position
	away.y = 0.0
	var drop: Vector3 = _quiet.global_position + away.normalized() * QUIET_RUN
	drop.y = G.ground_y(drop, _quiet.global_position.y)
	_quiet_drop = drop
	_quiet.set("standoff", false)
	_quiet.set("travel_to", drop)
	Dialogue.say("Stryx", tr("It saw you. It is running for its drop."))
	Q.report(String(q["event"]), 1)

func _quiet_2(q: Dictionary) -> void:
	if _quiet_dead:
		_quiet_dead = false
		_quiet = null
		_quiet_drop = null
		_ev_point.erase("quiet")
		Dialogue.say("Stryx", tr("Done, and quietly. Stryx remembers who is useful."))
		Q.report(String(q["event"]), 1)
		return
	if not is_instance_valid(_quiet):
		Q.reset_quest(String(q["id"]))          # state lost (a reload): the courier waits again
		return
	if _quiet.has_method("arrived") and _quiet.arrived():
		Dialogue.say("Stryx", tr("It made its drop. There will be another courier - be faster."))
		_quiet.queue_free()
		_quiet = null
		_quiet_drop = null
		_ev_point.erase("quiet")
		Q.reset_quest(String(q["id"]))
