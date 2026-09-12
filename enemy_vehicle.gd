extends MachineBody

# ══════════════════════════════════════════
# EXPORTS - AI
# ══════════════════════════════════════════

@export_group("ИИ — Фракция")
## 0 = player, 1+ = enemies. Attacks anything with a different faction.
@export var faction: int = 1

@export_group("ИИ — Живучесть")
## Blocks are separate RigidBodies (layer 2) with their own HP; player bullets (mask 3) hit them,
## not the hull. Catching the CABIN's destroyed signal kills the machine: it emits died (the spawner
## sends a new one) and drops the rest of the blocks into the world.
signal died(enemy: Node)

@export_group("ИИ — Обнаружение")
## How far an enemy notices a MACHINE BY SIGHT. Smaller than its own gun range on purpose, though
## this used to be 85 with the opposite reasoning ("otherwise it stands there while being shot from
## fifty metres").
##
## That hole is now closed by notice_attacker instead of by radius: a hit reveals the shooter at any
## distance and through anything. The radius only decides how far an enemy spots someone by itself,
## and forty metres give the player what he never had - the option to drive around a fight.
@export var detection_radius:    float = 40.0
## Close ring where a target is noticed WITHOUT line of sight: a machine roars, clanks and raises
## dust, so pretending it does not exist behind a rock ten metres away is deafness, not stealth.
@export var hear_radius:         float = 15.0
@export var attack_range:        float = 15.0
@export var min_combat_distance: float = 5.0
## Layers the AI searches for targets on. A machine hull (where faction lives) sits on the "machine"
## layer (5 -> value 16). The old 1|2 caught terrain and blocks but NOT the hull, so the AI could not
## see the player.
@export_flags_3d_physics var detection_mask: int = 16

@export_group("ИИ — Патруль")
## Custom patrol points; random ones are generated when empty.
@export var patrol_points:       Array[Vector3] = []
@export var patrol_radius:       float = 30.0
@export var patrol_points_count: int   = 4
@export var waypoint_reach_dist: float = 3.0

@export_group("ИИ — Поведение")
@export var patrol_speed_factor: float = 0.5
@export var chase_speed_factor:  float = 1.0
## How long a target is kept AFTER it leaves the detection zone (inside it, never forgotten).
@export var forget_enemy_time:   float = 6.0
## Relentless: a target assigned at spawn (a sector-scan squad, say) is NEVER forgotten or changed -
## such an enemy follows it across the whole map.
@export var relentless:          bool = false

@export_group("ИИ — Препятствия")
## Ray length of the context map. Angles are no longer configurable: directions come from the 16
## ContextSteering sectors rather than a left/right pair at N degrees.
@export var obstacle_ray_length: float = 5.0

# ══════════════════════════════════════════
# STATES
# ══════════════════════════════════════════

# Behaviour is chosen by EnemyBrain on utility - there is no rigid state machine any more.
#
# Flanking is time-limited: FLANK_CHARGE_TIME of manoeuvring spends the charge, FLANK_RECOVER_TIME
# of fighting face to face restores it. Hence the rhythm "dart sideways, trade, dart again" instead
# of an endless carousel around the player.
var _act: int = EnemyBrain.Act.PATROL
# Flanking is time-limited: FLANK_CHARGE_TIME of manoeuvring spends the charge, FLANK_RECOVER_TIME
# of fighting face to face restores it. Hence "dart sideways, trade, dart again" instead of an
# endless carousel around the player.
const FLANK_CHARGE_TIME:  float = 4.0
const FLANK_RECOVER_TIME: float = 9.0
var _flank_spent: float = 0.0
## Is THIS enemy allowed to fight right now (set by enemy_spawner._limit_engagement).
var combat_allowed: bool = true
var _percept: Dictionary = {}
var _decide_t: float = 0.0
const DECIDE_PERIOD: float = 0.15        # re-score the situation ~7 times a second

var _target:       Node3D  = null
var _forget_timer: float   = 0.0

var _patrol_targets: Array[Vector3] = []
var _patrol_index:   int   = 0
var _start_pos:      Vector3
## Seconds during which the enemy takes no target of its own accord. Set when it retreated damaged
## and broke contact: without it the enemy forgot the player and came straight back, because patrol
## points are built around its own spawn place - exactly where the fight was.
var _give_up_t: float = 0.0
## How long the give-up lasts.
const GIVE_UP_TIME: float = 25.0
## How far the patrol "home" is moved when the enemy leaves. Returning to where it just lost is not
## behaviour, it is the absence of behaviour.
const GIVE_UP_MOVE: float = 90.0

# Local navigation: a context map instead of three rays with a correction turn.
var _steering: ContextSteering = ContextSteering.new()
var _ctx_t: float = 0.0
var _obst_q: PhysicsRayQueryParameters3D = null

# Stuck measurement.
var _stuck01: float = 0.0
var _move_ref: Vector3 = Vector3.ZERO
var _move_t: float = 0.0

# Mobility self-calibration: how many wheels there were in better days.
var _wheels_peak: int = 1

# ══════════════════════════════════════════
# INITIALISATION
# ══════════════════════════════════════════

func _ready() -> void:
	mass          = base_weight
	# The enemy needs its own numbers, not the player's: the AI does not counter-steer when tipping, so
	# the stability margin is larger and the steering threshold higher - otherwise it saws at the wheel
	# while nearly stopped. Enemy builds also often carry weapons at y=1.
	anti_roll = 8.0
	upright_strength = 15.0
	steer_min_speed = 0.3
	init_machine_physics()
	# The name marker above a machine (enemy_marker.gd): an enemy must be visible in a crowd and behind
	# a tree, and it must be clear who it is. Player machines carry the radial menu button at that spot,
	# so the marker is for others only.
	var mk := Node3D.new()
	mk.set_script(preload("res://enemy_marker.gd"))
	mk.vehicle = self
	mk.position = Vector3(0, 2.6, 0)
	add_child(mk)
	linear_damp   = 0.0
	angular_damp  = 4.0

	_setup_detection_area()
	# A BASE IS FROZEN FROM THE START. Not "stop moving" but freeze: it has no wheels, and an unfrozen
	# hull with off-centre collision tips over on the first physics step - the same rake our own station
	# hit when anchoring.
	if is_base:
		is_station = true      # the MachineBody watchdog follows the core, not a cabin
		freeze = true
		linear_velocity = Vector3.ZERO
		angular_velocity = Vector3.ZERO
	_connect_cabin()
	_measure_build()          # build value while the machine is whole (see _pay_out)

func set_combat_allowed(v: bool) -> void:
	combat_allowed = v

## What THIS machine cost, computed ONCE at birth while it is whole. Computing it at death would be
## wrong twice over: half the blocks are gone by then, so the reward would depend on how neatly the
## player took it apart.
var build_value: int = 0

func _measure_build() -> void:
	var blocks_node := get_node_or_null("blocks")
	if blocks_node == null:
		return
	var v: int = 0
	for b in blocks_node.get_children():
		if b.get("block") != null:
			v += G.shop_price(int(b.get("block")))
	build_value = v

# Kill reward: RP by machine value (G.rp_for_kill). The System announces it - without the line the
# player would not notice anything was granted.
func _pay_out() -> void:
	if demo or faction == 0 or build_value <= 0:
		return
	var rp: int = G.rp_for_kill(build_value)
	G.add_research_points(rp)
	var d: Node = get_node_or_null("/root/Dialogue")
	if d != null and d.has_method("say"):
		d.say("System", "Wreck catalogued. +%d RP." % rp)


func _die() -> void:
	if _dying:
		return
	_dying = true
	_pay_out()
	if not demo:
		Q.report("enemy_killed", 1)         # combat quest progress; a menu duel counts for nothing
	died.emit(self)
	scatter_blocks(_cabin)    # shared scatter from MachineBody: the player uses the same one
	queue_free()

func _setup_detection_area() -> void:
	var area: Area3D = Area3D.new()
	area.name             = "DetectionArea"
	area.collision_layer  = 0
	area.collision_mask   = detection_mask  # machine layer by default (machine hulls)

	var col: CollisionShape3D = CollisionShape3D.new()
	var sph: SphereShape3D = SphereShape3D.new()
	sph.radius = detection_radius
	col.shape  = sph
	area.add_child(col)
	add_child(area)
	_detect_area = area                     # kept: the periodic re-search runs through it

	area.body_entered.connect(_on_body_entered)
	area.body_exited.connect(_on_body_exited)

## The SPAWN POINT is remembered on the first physics tick, not in _ready. _ready fires on add_child,
## i.e. BEFORE the spawner places the machine: at that moment it stands at the origin. Patrols were
## built around it, so every enemy on the map patrolled THE MAP CENTRE wherever it appeared.
var _spawn_captured: bool = false

## ВРАГ ПРИЕЗЖАЕТ ЗАРЯЖЕННЫМ. Батарея рождается пустой (battery.charge = 0) — это правильно для
## игрока, который её добывает и заряжает, и бессмысленно для машины, которая приехала откуда-то
## воевать: с пустой батареей её купол не включился бы ни разу, а реген не залатал бы ни блока.
##
## Заряда ровно столько, сколько в батарее помещается, и пополнить его в бою нечем: панели стоят
## только на БАЗАХ (blocks.gd, вышки), у ездящих сборок их нет. Значит купол и ремонт —
## РАСХОДУЕМЫЙ ресурс, и дыра в обороне открывается не «когда-нибудь», а тогда, когда игрок её
## выбьет.
## Возвращает true, когда батареи нашлись и залиты. ПОВТОРЯЕМ НЕСКОЛЬКО СЕКУНД: блоки машины
## появляются не в первом кадре (spawn_block ждёт готовности узла), и одна попытка на первом тике
## заряжала бы пустоту.
func _charge_batteries() -> bool:
	var bl := blocks_node()
	if bl == null:
		return false
	var any := false
	for b in bl.get_children():
		if b.has_method("charge_add") and ("capacity" in b):
			b.charge_add(float(b.get("capacity")))
			any = true
	return any

var _charge_t: float = 3.0

func _capture_spawn() -> void:
	if _spawn_captured:
		return
	_spawn_captured = true
	_start_pos = global_position
	_move_ref = global_position
	_setup_patrol_points()

func _setup_patrol_points() -> void:
	if patrol_points.size() > 0:
		_patrol_targets = patrol_points.duplicate()
		return
	_patrol_targets.clear()
	for i in patrol_points_count:
		var ang: float = (TAU / patrol_points_count) * i + randf_range(-0.5, 0.5)
		var dist: float = patrol_radius * randf_range(0.5, 1.0)
		_patrol_targets.append(_start_pos + Vector3(cos(ang) * dist, 0.0, sin(ang) * dist))

# ══════════════════════════════════════════
# MAIN LOOP
# ══════════════════════════════════════════

# No chase bonus. PURSUE used to add 25% to top speed, which meant escaping a healthy enemy was not
# hard but mathematically impossible, however many wheels the player fitted. An enemy must catch up
# by driving - cutting corners, catching you on a turn, using numbers.
func _speed_cap() -> float:
	# No chase bonus. PURSUE used to add 25% to top speed, which made escaping a healthy enemy
	# mathematically impossible however many wheels the player fitted. An enemy must catch up by
	# driving: cutting corners, catching you on a turn, using numbers.
	return max_speed

## How far below the terrain counts as falling through, and how far back up. The threshold is
## generous: at the foot of a cliff the height at that XZ is noticeably above where a machine legally
## stands, and a sensitive threshold would jerk it around on flat ground.
const SUNK_LIMIT := 6.0
const SUNK_LIFT := 2.0

func _physics_process(delta: float) -> void:
	var _pf := Perf.now()          # profiler mark (perf.gd): cost of enemy AI
	_physics_ai(delta)
	Perf.mark("enemies", _pf)

## An ENEMY BASE is the same enemy without a drivetrain: anchored, does not drive, shoots whatever
## comes near. No separate class on purpose: it differs from a machine exactly as our base differs
## from our machine (no cabin, always anchored), and all the combat code is shared - target,
## visibility, forgetting, turrets.
##
## Read by the core watchdog in MachineBody: for a base it watches the stationary block instead of a
## cabin. Same name as on the player machine because it means the same thing.
@export var is_base: bool = false
## Read by the core watchdog in MachineBody: for a base it watches the stationary block instead of
## a cabin. Same name as on the player machine because it means the same thing.
var is_station: bool = false

func _physics_ai(delta: float) -> void:
	# THE CORE WATCHDOG RUNS FOR ENEMIES TOO. It lives in MachineBody but only the player called it,
	# and two silent bugs followed. A BASE has no cabin, so the death subscription was empty: the
	# building could be stripped to the last block without dying, leaving an invisible hull that paid no
	# RP and never told the points system it was cleared. On a driving machine the cabin can be TORN
	# into the world whole (DROP_FRAC) instead of destroyed: no destroyed signal, and the enemy kept
	# driving cabinless. The watchdog catches both because it asks "is anything still holding this
	# machine together", not "did a signal arrive".
	cabin_watch(delta)
	# Debug (Main -> Debug -> Enemies): disabled AI leaves the machine WHOLE and in place, which is
	# convenient for inspecting builds, hits and spread. The gate sits AFTER the core watchdog, not at
	# the top: the watchdog is not part of the AI and is the only thing that removes a hull stripped to
	# the last block.
	if not G.debug(&"enemy_ai"):
		return
	# ПРИЕХАЛ ЗАРЯЖЕННЫМ — и база, и едущая машина: без тока купол и реген мёртвый груз.
	if _charge_t > 0.0:
		_charge_t -= delta
		if _charge_batteries():
			_charge_t = 0.0
	if is_base:
		_base_tick(delta)
		return
	_capture_spawn()          # first tick: the machine is in place, patrol can be built
	# ЭНЕРГИЮ ТИКАЕТ И ЕДУЩАЯ МАШИНА. Раньше её тикали только базы, и это было верно ровно до тех
	# пор, пока у ездящих сборок не появились купол, батарея и реген (blocks.ENEMY_BUILDS, начиная с копейщика, и
	# дальше): без тика щит не поднимался ни разу, а реген не чинил ничего — блоки стояли мёртвым
	# грузом, то есть продвинутый враг отличался от простого только числом стволов.
	_energy_tick(delta)
	_unsink()
	sense_ground(delta)
	# Flipped over: the same trick the player uses in BUILD mode - lift above the terrain and rotate
	# smoothly to level. _apply_upright alone often fails to right a machine on its back (the torque
	# pushes into the ground) and the enemy stayed there forever.
	if _flip_recover(delta):
		return                    # while righting itself, AI and normal drive physics stay out
	_update_ai(delta)
	drive_physics(delta)
	push_drive_input(-_steer_angle / deg_to_rad(steer_max_angle))

## Base tick: see and shoot, nothing else. No driving, no patrol, no righting itself - a standing
## building needs none of that, and running them idle costs for every base on the map.
##
## The engagement ban (combat_allowed) does not apply to a base: it exists so driving enemies do not
## pile on, and a silent turret you can drive past reads as broken.
func _base_tick(delta: float) -> void:
	# Энергию тикают ОБЕ ветки — и база, и едущая машина (см. _physics_ai): купол, батарея и реген
	# стоят и на тех, и на других.
	_energy_tick(delta)
	_reacquire_t -= delta
	if _reacquire_t <= 0.0:
		_reacquire_t = 0.3
		if not is_instance_valid(_target):
			_scan_for_targets()
	_refresh_vision(delta)
	if not is_instance_valid(_target):
		_target = null
		return
	if _can_see_target():
		_forget_timer = forget_enemy_time
		_turn_to_target(delta)
		_do_attack()
		return
	_forget_timer -= delta
	if _forget_timer <= 0.0:
		_lose_target()

# FELL THROUGH THE TERRAIN - put it back. Terrain collision is streamed: tiles are built AROUND a
# body and only after it is there, while every enemy drops in from height - if the tile is late the
# machine passes through the map and falls forever. There is nothing under the surface, so "below
# the terrain by SUNK_LIMIT" cannot be confused with anything else. world_persist._rescue_fallen
# does the same for the player but never touches enemies: they are not saved and not in its list.
func _unsink() -> void:
	# Through G.ground_y: until the map's heights are read it returns our own height and the check
	# disables itself. With raw terrain_height_at it would be zero and we would "rescue" a machine
	# standing in a legitimate hollow.
	var h: float = G.ground_y(global_position, global_position.y)
	if global_position.y > h - SUNK_LIMIT:
		return
	global_position = Vector3(global_position.x, h + SUNK_LIFT, global_position.z)
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO

# ══════════════════════════════════════════
# AI - DISPATCH
# ══════════════════════════════════════════

var _detect_area: Area3D = null
var _reacquire_t: float = 0.0
var _last_known_pos: Vector3 = Vector3.ZERO
var _has_last_known: bool = false

# Assign a target FROM OUTSIDE (a sector-scan squad). The spawner used to write private fields
# directly and set the state by number, which would break silently on any enum edit.
## DEMO MACHINE (menu backdrop). It fights for show, so two things are switched off: rewards and
## quest progress on death (the menu must not advance a playthrough), and any way out of the fight -
## no giving up, no retreat behaviour. There is nowhere to retreat to in a 512 m arena anyway, and a
## backdrop where both sides drive apart shows nothing.
var demo: bool = false

func assign_target(t: Node3D, never_forget: bool = false) -> void:
	if t == null or not is_instance_valid(t):
		return
	_target = t
	_forget_timer = forget_enemy_time
	_act = EnemyBrain.Act.PURSUE
	relentless = never_forget

# Acquiring a target requires LINE OF SIGHT. Being inside the sphere used to be enough: an enemy
# "saw" through hills and rocks while the sight ray was computed but only affected the manoeuvre
# choice (enemy_brain: a 0.35 multiplier). Terrain in combat was pure decoration - there was nowhere
# to hide.
func _scan_for_targets() -> void:
	if _detect_area == null or not is_instance_valid(_detect_area):
		return
	# SQUARED distances: distance_to takes a root and "who is closer" does not care - the ordering is
	# the same. This walks every body in the sphere several times a second for every enemy.
	var best: Node3D = null
	var best_d2: float = INF
	for b in _detect_area.get_overlapping_bodies():
		if not _is_enemy(b) or not (b is Node3D):
			continue
		var d2: float = global_position.distance_squared_to((b as Node3D).global_position)
		if d2 < best_d2:
			best_d2 = d2
			best = b as Node3D
	# The nearest candidate goes through the shared visibility rule - a ray costs more than comparing
	# numbers, so it is cast once rather than per candidate.
	if best != null:
		_consider_target(best)

## Is the target visible RIGHT NOW: in radius and either close enough to hear or in direct line. The
## ray result is cached - it is needed by forgetting (every frame) and by situation scoring, and a
## physics query sixty times a second per enemy is not worth it.
const LOS_PERIOD: float = 0.2
var _los_t: float = 0.0
var _los_ok: bool = false

func _refresh_vision(delta: float) -> void:
	_los_t -= delta
	if _los_t > 0.0:
		return
	_los_t = LOS_PERIOD
	_los_ok = is_instance_valid(_target) and _has_line_of_sight(_target)

func _can_see_target() -> bool:
	if not is_instance_valid(_target):
		return false
	# Squared comparison; thresholds are squared too (this runs every physics frame).
	var d2: float = global_position.distance_squared_to(_target.global_position)
	if d2 > detection_radius * detection_radius:
		return false
	return d2 <= hear_radius * hear_radius or _los_ok

func _update_ai(delta: float) -> void:
	# The target is re-searched periodically while there is none.
	_reacquire_t -= delta
	if _reacquire_t <= 0.0:
		_reacquire_t = 0.3
		if not is_instance_valid(_target):
			_scan_for_targets()

	# Forgetting: while the target is VISIBLE it is never forgotten; once out of sight (behind a hill or
	# out of radius) the timer runs. The condition used to be distance only, so inside the radius a
	# target was NEVER lost and hiding behind a rock at eighty metres gained nothing. Now losing sight
	# starts the same timer and the enemy drives to the last known place - the SEARCH behaviour in
	# enemy_brain was written long ago and almost never triggered. A relentless enemy never forgets.
	_give_up_t = maxf(_give_up_t - delta, 0.0)
	_refresh_vision(delta)
	if is_instance_valid(_target):
		if _can_see_target():
			_forget_timer = forget_enemy_time
		elif not relentless:
			_forget_timer -= delta
			if _forget_timer <= 0.0:
				_lose_target()
	elif _target != null:
		_target = null

	# Combat is banned by the spawner (engagement slots are taken). The target is still REMEMBERED -
	# dropping it here put the spawner in a loop: it lists "wants to fight" by `_target != null`, the ban
	# cleared the target, next frame the enemy counted as free, the ban lifted, 0.3 s later the target
	# returned, ban again. Three hundred oscillations a minute, and since the behaviour tick (0.15 s)
	# and the re-search tick (0.3 s) are exactly two to one, the enemy managed a burst on EVERY return.

	_update_stuck(delta)

	# Flank charge: spent while flanking, recovered while fighting head on. That is what turns the
	# flank into a short dart with a trade in between (EnemyBrain.score_all).
	if _act == EnemyBrain.Act.FLANK:
		_flank_spent = minf(_flank_spent + delta / FLANK_CHARGE_TIME, 1.0)
	else:
		_flank_spent = maxf(_flank_spent - delta / FLANK_RECOVER_TIME, 0.0)

	# The situation is re-scored a few times a second rather than every physics frame: the decision
	# changes more slowly anyway and the measurements (HP, firepower, line of fire) are not free.
	_decide_t -= delta
	if _decide_t <= 0.0:
		_decide_t = DECIDE_PERIOD
		_percept = _sense()
		_act = EnemyBrain.decide(_percept, _act)
		if demo and _act == EnemyBrain.Act.RETREAT:
			_act = EnemyBrain.Act.ENGAGE          # a demo machine has nowhere to fall back to

	# The ban is enforced HERE rather than by clearing the target: the enemy behaves like a patrol but
	# remembers who it came for and returns to the fight the frame a slot frees.
	if not combat_allowed:
		_act_patrol(delta)
		return

	match _act:
		EnemyBrain.Act.PATROL:      _act_patrol(delta)
		EnemyBrain.Act.INVESTIGATE: _act_investigate(delta)
		EnemyBrain.Act.PURSUE:      _act_pursue(delta)
		EnemyBrain.Act.ENGAGE:      _act_engage(delta)
		EnemyBrain.Act.FLANK:       _act_flank(delta)
		EnemyBrain.Act.RETREAT:     _act_retreat(delta)
		EnemyBrain.Act.UNSTICK:     _act_unstick(delta)

# ══════════════════════════════════════════
# PERCEPTION
# ══════════════════════════════════════════

const NO_TARGET_DIST: float = 1.0e6

func _sense() -> Dictionary:
	var has_t: bool = is_instance_valid(_target)
	var dist: float = NO_TARGET_DIST
	var facing: float = 0.0
	var los: bool = false
	if has_t:
		var to_us: Vector3 = global_position - _target.global_position
		to_us.y = 0.0
		dist = to_us.length()
		_last_known_pos = _target.global_position
		_has_last_known = true
		if dist > 0.01:
			var t_fwd: Vector3 = -_target.global_transform.basis.z
			t_fwd.y = 0.0
			if t_fwd.length_squared() > 0.0001:
				facing = clampf(t_fwd.normalized().dot(to_us.normalized()), 0.0, 1.0)
		los = _los_ok           # same cache as forgetting uses: no second ray

	# Mobility self-calibrates: remember how many wheels there were at best and compare with now. No
	# need to catch the moment the machine was assembled.
	_wheels_peak = maxi(_wheels_peak, _wheel_count)
	var wheels01: float = float(_wheel_count) / float(maxi(_wheels_peak, 1))

	return {
		"has_target": has_t,
		"has_memory": _has_last_known,
		"dist": dist,
		"range": _own_weapon_range(),
		"health": health_ratio(),
		"mobility": clampf(wheels01 * _contact_ratio(), 0.0, 1.0),
		"power_ratio": _power_ratio(),
		"los": los,
		"stuck": _stuck01,
		"facing_us": facing,
		"flank_spent": _flank_spent,
	}

# Effective range is the best gun's range. It used to be an export (attack_range) unrelated to what
# the machine actually carries.
func _own_weapon_range() -> float:
	var r: float = 0.0
	for b in _weapon_blocks():
		if not is_instance_valid(b):
			continue
		var wr: Variant = b.get("weapon_range")
		if wr != null:
			r = maxf(r, float(wr))
	# LIMITED by what the enemy can actually see. Otherwise it keeps gun distance (weapon_range * 0.85
	# in _act_engage) - with a 60 m gun that is 51 m against a 40 m radius, so it backs out of its own
	# detection zone, loses the target, returns, backs out again. With a mortar (160) it would be four
	# times worse.
	return minf(r if r > 0.5 else attack_range, detection_radius)

func _power_ratio() -> float:
	if not is_instance_valid(_target) or not _target.has_method("firepower"):
		return 0.5
	var mine: float = firepower()
	var total: float = mine + float(_target.call("firepower"))
	return 0.5 if total < 0.001 else clampf(mine / total, 0.0, 1.0)

var _los_q: PhysicsRayQueryParameters3D = null

func _has_line_of_sight(t: Node3D) -> bool:
	if _los_q == null:
		_los_q = PhysicsRayQueryParameters3D.new()
		_los_q.collision_mask = 1        # terrain only: other machines' blocks do not count as cover
	# exclude is left empty: it takes RIDs rather than nodes, and with a terrain-only mask there is
	# nobody to exclude - neither we nor the target sit on layer 1 (machines are on layer 5).
	_los_q.from = global_position + Vector3.UP
	_los_q.to = t.global_position + Vector3.UP
	return get_world_3d().direct_space_state.intersect_ray(_los_q).is_empty()

# Stuck means "commanded to drive and not driving". A continuous value, not a flag: it grows while
# the machine stands under throttle and falls as soon as it moves. There is no separate recovery
# mode with a timer - the same utility scoring decides.
const STUCK_WINDOW: float = 1.2
const STUCK_MIN_MOVE: float = 0.8

func _update_stuck(delta: float) -> void:
	_move_t += delta
	if _move_t < STUCK_WINDOW:
		return
	_move_t = 0.0
	var moved: float = global_position.distance_to(_move_ref)
	_move_ref = global_position
	if absf(_throttle) > 0.15 and moved < STUCK_MIN_MOVE:
		_stuck01 = minf(1.0, _stuck01 + 0.5)
	else:
		_stuck01 = maxf(0.0, _stuck01 - 0.5)

# ══════════════════════════════════════════
# BEHAVIOURS
# ══════════════════════════════════════════

func _act_patrol(delta: float) -> void:
	if _patrol_targets.is_empty():
		_drive(_get_forward(), 0.0, delta)
		return
	var goal: Vector3 = _patrol_targets[_patrol_index]
	if global_position.distance_squared_to(goal) < waypoint_reach_dist * waypoint_reach_dist:
		_patrol_index = (_patrol_index + 1) % _patrol_targets.size()
		goal = _patrol_targets[_patrol_index]
	_drive_to(goal, patrol_speed_factor, delta)

func _act_investigate(delta: float) -> void:
	if not _has_last_known:
		_act_patrol(delta)
		return
	if global_position.distance_squared_to(_last_known_pos) < waypoint_reach_dist * waypoint_reach_dist:
		_has_last_known = false          # arrived and nobody is there: back to patrol
		return
	_drive_to(_last_known_pos, chase_speed_factor, delta)

func _act_pursue(delta: float) -> void:
	if not is_instance_valid(_target):
		return
	# The turret aims itself within its cone, so we fire on the move without waiting to face the target.
	if float(_percept.get("dist", NO_TARGET_DIST)) <= _own_weapon_range() * 1.15:
		_do_attack()
	_drive_to(_target.global_position, chase_speed_factor, delta)

func _act_engage(delta: float) -> void:
	if not is_instance_valid(_target):
		return
	_do_attack()
	var to_t: Vector3 = _target.global_position - global_position
	to_t.y = 0.0
	var dist: float = to_t.length()
	if dist < 0.01:
		return
	var dir: Vector3 = to_t / dist
	var rng: float = _own_weapon_range()
	var band_near: float = maxf(min_combat_distance, rng * 0.35)
	var band_far: float = rng * 0.85

	if dist < band_near:
		_drive(dir, -0.35, delta)                       # back off keeping the nose on the target
	elif dist > band_far:
		_drive(dir, chase_speed_factor, delta)          # close in
	else:
		# In the corridor we HOLD distance and shoot, working sideways only slightly. This used to be a full
		# arc (0.75 lateral at 0.6 speed) which, together with FLANK, produced "the enemy circles you
		# forever". The side is the one we are already on, not a coin flip: a random choice threw the enemy
		# across its own line of fire.
		var side: Vector3 = Vector3(dir.z, 0.0, -dir.x)
		var sgn: float = signf(side.dot(_get_forward()))
		if absf(sgn) < 0.01:
			sgn = 1.0
		_drive((dir + side * (sgn * 0.30)).normalized(), chase_speed_factor * 0.25, delta)

func _act_flank(delta: float) -> void:
	if not is_instance_valid(_target):
		return
	_do_attack()
	# Leave the target's frontal sector while staying in ours: a point to its side and rear, on the side
	# we are already on, so we do not cross its line of fire.
	var t_fwd: Vector3 = -_target.global_transform.basis.z
	t_fwd.y = 0.0
	if t_fwd.length_squared() < 0.0001:
		_act_engage(delta)
		return
	t_fwd = t_fwd.normalized()
	var t_right: Vector3 = Vector3(t_fwd.z, 0.0, -t_fwd.x)
	var to_us: Vector3 = global_position - _target.global_position
	to_us.y = 0.0
	var sgn: float = signf(t_right.dot(to_us))
	if absf(sgn) < 0.01:
		sgn = 1.0
	var rng: float = maxf(_own_weapon_range() * 0.7, min_combat_distance)
	var spot: Vector3 = _target.global_position + t_right * (sgn * rng) - t_fwd * (rng * 0.3)
	_drive_to(spot, chase_speed_factor * 0.9, delta)

func _act_retreat(delta: float) -> void:
	_do_attack()                                        # turrets keep working while retreating
	var away: Vector3 = global_position - _last_known_pos
	if is_instance_valid(_target):
		away = global_position - _target.global_position
	away.y = 0.0
	if away.length_squared() < 0.0001:
		away = _get_forward()
	_drive(away.normalized(), chase_speed_factor, delta)

func _act_unstick(delta: float) -> void:
	# Reverse, but the direction is chosen by the same context map - it sees where the space behind is.
	# There is no fixed "back up for two seconds then steer aside" any more.
	_drive(_get_forward(), -0.7, delta)

# ══════════════════════════════════════════
# MOVEMENT THROUGH THE CONTEXT MAP
# ══════════════════════════════════════════

func _drive_to(pos: Vector3, speed: float, delta: float) -> void:
	var to: Vector3 = pos - global_position
	to.y = 0.0
	if to.length_squared() < 0.0001:
		return
	_drive(to.normalized(), speed, delta)

# nose_dir is where we want to look, speed is signed (negative is reverse).
func _drive(nose_dir: Vector3, speed: float, delta: float) -> void:
	var travel: Vector3 = nose_dir if speed >= 0.0 else -nose_dir
	_refresh_context(travel, delta)
	var safe: Vector3 = _steering.choose(travel)
	var aim: Vector3 = safe if speed >= 0.0 else -safe

	var fwd: Vector3 = Vector3(_get_forward().x, 0.0, _get_forward().z)
	if fwd.length_squared() < 0.0001:
		return
	fwd = fwd.normalized()

	var ang: float = fwd.signed_angle_to(aim, Vector3.UP)
	var steer_input: float = clampf(ang / PI, -1.0, 1.0)
	var speed_ratio: float = clampf(linear_velocity.length() / max_speed, 0.0, 1.0)
	var angle_limit: float = deg_to_rad(steer_max_angle) * (1.0 - speed_steer_reduction * speed_ratio)
	_steer_angle = lerp(_steer_angle, steer_input * angle_limit, steer_speed * delta)

	# On a sharp turn the throttle drops but not to zero, or the machine stops completing the turn.
	var turn_factor: float = clampf(1.0 - absf(ang) / PI, 0.4, 1.0)
	_throttle = lerp(_throttle, speed * turn_factor, 4.0 * delta)

const CTX_PERIOD: float = 0.12
const PROBE_NEAR: float = 3.0
const PROBE_FAR: float = 7.0
const MAX_CLIMB: float = 2.5     # steeper than this and the machine will not climb
const MAX_DROP: float = 3.5      # steeper than this is a cliff: do not drive there

func _refresh_context(travel: Vector3, delta: float) -> void:
	_ctx_t -= delta
	if _ctx_t <= 0.0:
		_ctx_t = CTX_PERIOD
		_sample_danger()
	_steering.clear_interest()
	_steering.seek(travel)

# Danger across all 16 directions. Terrain is evaluated mathematically (terrain_height_at, no
# physics), so every side is sampled; rays check every second one, which is enough and costs far
# more.
func _sample_danger() -> void:
	_steering.clear_danger()
	var terr: Node = _find_terrain()
	var space: PhysicsDirectSpaceState3D = get_world_3d().direct_space_state
	if _obst_q == null:
		_obst_q = PhysicsRayQueryParameters3D.new()
		_obst_q.exclude = [get_rid()]      # exclude takes RIDs, not nodes
		_obst_q.collision_mask = 1
	var here: float = global_position.y
	var origin: Vector3 = global_position + Vector3.UP * 0.5

	for i in ContextSteering.SLOTS:
		var d: Vector3 = _steering.direction(i)
		if terr != null:
			var h_near: float = terr.terrain_height_at(global_position + d * PROBE_NEAR)
			var h_far: float = terr.terrain_height_at(global_position + d * PROBE_FAR)
			var climb: float = maxf(h_near - here, h_far - here)
			var drop: float = maxf(here - h_near, here - h_far)
			if climb > MAX_CLIMB:
				_steering.set_danger(i, clampf(climb / (MAX_CLIMB * 2.0), 0.0, 1.0))
			if drop > MAX_DROP:
				_steering.set_danger(i, clampf(drop / (MAX_DROP * 2.0), 0.0, 1.0))
		if i % 2 == 0:
			_obst_q.from = origin
			_obst_q.to = origin + d * obstacle_ray_length
			var hit: Dictionary = space.intersect_ray(_obst_q)
			if not hit.is_empty():
				var dd: float = origin.distance_to(hit["position"])
				_steering.add_danger(d, clampf(1.0 - dd / obstacle_ray_length, 0.2, 1.0))

var _atk_cache: Array = []
var _atk_n: int = -1

# Weapon block cache: needed both for firing and for scoring our own range and firepower.
func _weapon_blocks() -> Array:
	var bl := get_node_or_null("blocks")
	if bl == null:
		return []
	if bl.get_child_count() != _atk_n:
		_atk_n = bl.get_child_count()
		_atk_cache.clear()
		for b in bl.get_children():
			if b.has_method("attack"):
				_atk_cache.append(b)
	return _atk_cache

# The only place weapons are triggered, so both bans live here.
#
# A target is mandatory: _act_retreat calls attack without any check ("turrets work while
# retreating"), and a retreating enemy with no target sprayed the air - WeaponBlock.attack() only
# arms the timer and it fires regardless of whether there is anything to hit.
func _do_attack() -> void:
	# The ban does NOT apply to a BASE - same rule as in _base_tick. The spawner no longer sets it for
	# buildings, but it is kept here too: this is the single place weapons are armed, and "a base always
	# shoots" must hold whoever set the flag.
	if not (combat_allowed or is_base) or not is_instance_valid(_target):
		return
	for b in _weapon_blocks():
		if not is_instance_valid(b):
			_atk_n = -1                 # block destroyed: rebuild the cache
			continue
		b.attack()

## THE ROTATING SUPPORT WORKS FOR ENEMIES TOO. On the player machine ROT_SUPPORT turns an anchored
## machine with the joystick; here the AI does the same - one rule, only the driver differs. Without
## it the block on an enemy base would be a cube with hit points.
##
## What it changes: a turret covers +-yaw_limit, so a fixed building (outpost, fort) has a dead zone
## behind it and can only cover it with guns pointing different ways. A rotating tower needs one
## direction - and a MORTAR finally makes sense on it, since its own yaw_limit is only 18 deg: it is
## aimed by the hull and merely trims.
##
## Rotation is Y ONLY and only toward a visible target: the base's tilt is how it sits on the terrain,
## and touching it would make the building topple with every turn.
const BASE_TURN_SPEED := 0.8          # rad/s (~45 deg/s): the tower turns rather than snaps
const BASE_TURN_DEAD := 0.02          # dead zone so it does not jitter on a near-zero difference

var _rot_support_t: float = 0.0       # when the rotating support was last looked for
var _rot_support: bool = false

func _turn_to_target(delta: float) -> void:
	if not _has_rot_support(delta) or not is_instance_valid(_target):
		return
	var to: Vector3 = _target.global_position - global_position
	to.y = 0.0
	if to.length_squared() < 0.01:
		return
	# The machine looks along -Z, so the angle is atan2(-x, -z).
	var want: float = atan2(-to.x, -to.z)
	var diff: float = wrapf(want - global_rotation.y, -PI, PI)
	if absf(diff) < BASE_TURN_DEAD:
		return
	var step: float = clampf(diff, -BASE_TURN_SPEED * delta, BASE_TURN_SPEED * delta)
	global_rotation.y += step

## Does this base have a rotating support? Re-checked RARELY and from scratch, because not all bases
## rotate: an outpost and a fort have an ordinary support as their core and the answer is "no" for
## life. And if the support is shot out the tower stops turning that second - and dies almost at once,
## since the support is its only stationary block, i.e. its core (cabin_watch).
func _has_rot_support(delta: float) -> bool:
	_rot_support_t -= delta
	if _rot_support_t > 0.0:
		return _rot_support
	_rot_support_t = 1.0
	_rot_support = false
	var bl: Node = get_node_or_null("blocks")
	if bl == null:
		return false
	for b in bl.get_children():
		if b.get("block") != null and int(b.get("block")) == G.Block.ROT_SUPPORT:
			_rot_support = true
			break
	# KINEMATIC freeze, not static: physics treats a static body as motionless and does not carry its
	# motion into contacts, so a player machine pressed against a rotating tower would sink into it in
	# jerks. Set once, when the support is found.
	if _rot_support and freeze_mode != RigidBody3D.FREEZE_MODE_KINEMATIC:
		freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
	return _rot_support

func _lose_target() -> void:
	if relentless and is_instance_valid(_target):
		return                      # a relentless enemy never drops its target
	# Broke contact while DAMAGED means it lost and leaves for good. The test uses the same confidence
	# that measures all of the enemy's caution (EnemyBrain.confidence) rather than a new threshold,
	# which would sooner or later disagree with the one it retreats by.
	if _has_last_known and not _percept.is_empty() and EnemyBrain.confidence(_percept) < 0.4:
		_give_up()
	_target       = null
	_patrol_index = _nearest_patrol_index()
	# No behaviour is assigned: scoring picks SEARCH (we remember the last place) or PATROL if there is
	# nothing left to remember.

## Leave the field: take no targets for GIVE_UP_TIME and move the patrol "home" AWAY from where the
## target was lost. A timer alone is not enough - when it expires the enemy would still be circling
## its old spawn point, i.e. coming back to the player by itself.
func _give_up() -> void:
	if demo:
		return
	_give_up_t = GIVE_UP_TIME
	var away: Vector3 = global_position - _last_known_pos
	away.y = 0.0
	if away.length_squared() < 0.01:
		away = -_get_forward()
	_start_pos = global_position + away.normalized() * GIVE_UP_MOVE
	_has_last_known = false         # nothing left to search for: we are leaving
	_setup_patrol_points()

func _nearest_patrol_index() -> int:
	var best_i: int = 0
	var best_d2: float = INF
	for i in _patrol_targets.size():
		var d2: float = global_position.distance_squared_to(_patrol_targets[i])
		if d2 < best_d2:
			best_d2 = d2
			best_i  = i
	return best_i

## WE WERE HIT, so we know from where. Called by the weapon at the moment of impact (WeaponBlock,
## rocket AOE) passing ITS machine.
##
## This is not sight and must not be: it works at any distance and through any hill. That is exactly
## why the detection radius could drop to forty - "stands there while being shot from afar" is cured
## here rather than by inflating the sphere to eighty-five.
##
## The target is not hijacked on every hit: while we can SEE whoever we are already fighting, a new
## shooter waits. Otherwise crossfire between two machines made the enemy flip between them and shoot
## at neither.
func notice_attacker(attacker: Node3D) -> void:
	if attacker == null or not is_instance_valid(attacker) or attacker == self:
		return
	if not _is_enemy(attacker):
		return                          # same faction: friendly fire does not change the target
	if relentless and is_instance_valid(_target):
		return                          # a relentless enemy was given its target once and for all
	# Being shot at cancels the give-up. You can walk away from someone who let you go; being finished
	# off means fighting back, or the enemy would become a target that does not answer.
	_give_up_t = 0.0
	if is_instance_valid(_target) and _target != attacker and _can_see_target():
		return                          # we can see our current opponent: do not switch
	_target = attacker
	_forget_timer = forget_enemy_time
	_last_known_pos = attacker.global_position
	_has_last_known = true

func _is_enemy(body: Node) -> bool:
	if body == self: return false
	var f = body.get("faction")
	if f == null: return false
	return f != faction

# ══════════════════════════════════════════
# AREA3D SIGNALS
# ══════════════════════════════════════════

# ENTERING THE ZONE is the second acquisition path and must obey the same visibility rule as the
# periodic search. It used not to: the signal set the target directly, so crossing the sphere border
# was enough to see through a hill. The search only runs while there is NO target, so in practice
# almost everything was acquired here - i.e. the visibility check was skipped most of the time.
func _on_body_entered(body: Node) -> void:
	if not _is_enemy(body) or not (body is Node3D):
		return
	_consider_target(body as Node3D)

## Should this become the target? The ONE place with the rule "who an enemy may notice": both the
## zone signal and the periodic search come here, so they cannot diverge.
func _consider_target(body3d: Node3D) -> bool:
	if body3d == null or not is_instance_valid(body3d):
		return false
	if _give_up_t > 0.0:
		return false                # gave up and is leaving: it starts no fights
	var d2: float = global_position.distance_squared_to(body3d.global_position)
	if d2 > detection_radius * detection_radius:
		return false
	if d2 > hear_radius * hear_radius and not _has_line_of_sight(body3d):
		return false                # behind cover and out of earshot: not seen
	if not is_instance_valid(_target):
		_target = body3d
		_forget_timer = forget_enemy_time
		return true
	if relentless:
		return false                # the target was fixed at spawn: ignore others
	# Already fighting someone: switch only to a CLOSER target, or two machines side by side would toss
	# the enemy between them on every border crossing.
	if d2 < global_position.distance_squared_to(_target.global_position):
		_target = body3d
		_forget_timer = forget_enemy_time
		return true
	return false

func _on_body_exited(body: Node) -> void:
	if body == _target:
		_forget_timer = forget_enemy_time

# ══════════════════════════════════════════
# SELF-RIGHTING AFTER A FLIP
# ══════════════════════════════════════════
# Exactly what the player machine does in BUILD mode: lift above the terrain by the ride height and
# rotate smoothly to level (slerp to Basis.looking_at, not an Euler reset - that gimbals when
# upside down). Held for FLIP_TIME seconds, then released to ordinary physics.
const FLIP_DOT := 0.3          # the machine's up tilted more than ~72 deg: treat as flipped
const FLIP_TIME := 2.0         # how long the righting takes
const FLIP_CLEARANCE := 3.0    # how far above the terrain it is lifted
var _flip_t: float = 0.0

func _flip_recover(delta: float) -> bool:
	if _flip_t <= 0.0:
		if _get_up().dot(Vector3.UP) >= FLIP_DOT:
			return false
		_flip_t = FLIP_TIME                       # just flipped: start righting
	_flip_t -= delta
	# Height: pulled toward terrain + clearance (damped spring, no overshoot).
	var terr: Node = _find_terrain()
	var target_y: float = global_position.y
	if terr != null:
		target_y = terr.terrain_height_at(global_position) + FLIP_CLEARANCE
	linear_velocity.y = clampf((target_y - global_position.y) * 6.0, -6.0, 6.0)
	linear_velocity.x = lerpf(linear_velocity.x, 0.0, clampf(delta * 8.0, 0.0, 1.0))
	linear_velocity.z = lerpf(linear_velocity.z, 0.0, clampf(delta * 8.0, 0.0, 1.0))
	# Rotate to level, keeping the heading.
	var fwd := -global_transform.basis.z
	fwd.y = 0.0
	if fwd.length_squared() < 0.0001:
		fwd = global_transform.basis.y
		fwd.y = 0.0
	if fwd.length_squared() < 0.0001:
		fwd = Vector3.FORWARD
	var want := Basis.looking_at(fwd.normalized(), Vector3.UP)
	global_transform.basis = global_transform.basis.slerp(want, clampf(delta * 4.0, 0.0, 1.0)).orthonormalized()
	angular_velocity = Vector3.ZERO
	_throttle = 0.0
	if _flip_t <= 0.0:
		_stuck01 = 0.0                            # after righting this is not being stuck
		_move_ref = global_position
		_move_t = 0.0
	return _flip_t > 0.0

var _terrain_cache: Node = null

func _find_terrain() -> Node:
	if _terrain_cache != null and is_instance_valid(_terrain_cache):
		return _terrain_cache
	var scn := get_tree().current_scene
	if scn == null:
		return null
	for c in scn.get_children():
		if c.has_method("terrain_height_at"):
			_terrain_cache = c
			return c
	return null

# ══════════════════════════════════════════
# PHYSICS - MASS
# ══════════════════════════════════════════


# Blocks that accept throttle and steering (wheels). The cache is invalidated by $blocks child count.

# ══════════════════════════════════════════
# PHYSICS - WHEELBASE
# ══════════════════════════════════════════
