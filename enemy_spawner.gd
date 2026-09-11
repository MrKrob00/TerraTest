extends Node3D
# Keeps enemies around the player: one dies or despawns, another arrives after the interval.
# The scene is random from the pool, the BUILD is not - it follows the player machine's value
# (_pick_preset). Enemies go under Vehicles so the map gives them streamed collision.
#
# Density rules taken from TerraTech: quiet zone around the player's anchored machine, a far
# enemy SLEEPS instead of being teleported back (so combat can be left), strength follows the
# player's machine value. Not taken: "no spawns while driving fast" - that would cancel the one
# thing the world must do, meet you within a hundred metres.

@export var enemy_scenes: Array[PackedScene]        # pool of enemy scenes
## Cap on AWAKE enemies. Nine, then four, still crowded; two is what a road encounter holds.
@export var max_enemies: int = 2
## Pause between spawns. After a fight there must be an audible break, not the next fight.
@export var spawn_interval: float = 75.0
## Enemies placed at once when the world is ready: not empty, not a crowd.
@export var initial_enemies: int = 1
## Grace after the tutorial before the world sends anyone: a few seconds to try what was just
## taught. ONE number for both paths - tutorial_director asks this field for the story scout,
## and two numbers would let the regular stream arrive first.
@export var first_spawn_delay: float = 8.0
var _seed_grace: float = -1.0

# Enemy BASES live in outposts.gd: they stand at fixed map points and survive driving away.
# Here they keep one duty shared with enemies - sleep and shadows (register_base), because base
# turrets tick every physics frame and past the horizon that is ten guns aiming at nothing.

## How many may ENGAGE at once; the rest patrol until a slot frees. Without the cap everyone
## who noticed the player drove in together, which is an execution rather than a fight.
@export var max_engaging: int = 1
## Spawn ring. The inner edge is COMPUTED, not a number: enemy vision + this margin
## (_spawn_min_dist). Closer than vision means a machine that spawns and immediately attacks.
## The same margin measures clearance from OTHER enemies - "safe" is one quantity.
@export var spawn_safe_margin: float = 40.0
## Vision radius is asked from a LIVE enemy (builds may differ); this is the fallback.
@export var enemy_detect_fallback: float = 40.0
@export var spawn_max_dist: float = 160.0
## QUIET ZONE around your own anchored machine: no spawns there. The whole production chain
## only runs while anchored, so without it enemies arrive exactly while the player is laying out
## a conveyor and not steering.
@export var quiet_radius: float = 120.0
## Never appear within this distance IN FRONT: the player must not watch an enemy materialise
## on his heading. Behind and to the sides it is not visible anyway.
@export var front_clear_dist: float = 240.0
@export_range(0.0, 180.0) var front_cone_deg: float = 55.0
## Everyone DROPS IN from this height. Hence no height/slope rejection of candidate points: it
## cost five terrain samples per candidate across dozens of them, and a falling machine does not
## need flat ground - it rolls off a slope and rights itself (_flip_recover).
@export var drop_height: float = 10.0

@export_group("Сон и уборка")
## Past sleep_dist for sleep_delay seconds an enemy SLEEPS: physics frozen, AI and weapons off,
## node stays where it is. It used to be teleported back to the player instead, which made
## retreat impossible - the same machine reappeared behind you.
@export var sleep_dist: float = 420.0
@export var sleep_delay: float = 20.0
## Sleepers do not count against the cap but must not pile up: over max_total the farthest
## SLEEPER is removed. The invader never is.
@export var max_total: int = 8
@export var map_node: Node

## Rare event "sector scan": the System announces a square around the player, gives him time to
## leave, and sends an INVADER if he stays. ONE machine, not a squad: strong, never forgets its
## target, never despawns. A squad of five cancelled the whole density balance.
@export_group("Проверка сектора")
@export var scan_enabled: bool = true
## Every 10-15 min. At 3-7 the "rare event" came faster than a factory could be built.
@export var scan_min_interval: float = 600.0
@export var scan_max_interval: float = 900.0
@export var scan_half_size: float = 32.0            # half-size of the square (4x4 chunks of 16 = 64)
@export var scan_warn_time: float = 12.0            # seconds to escape
@export var scan_preset: int = 9                    # heavy build (see blocks.gd layouts)
## The invader drops from the usual drop_height: it appears at the square's edge, i.e. close,
## and without the fall it read as "a machine materialised twenty metres away and opened fire".

@export_group("Сила врага")
## Builds from weakest to strongest (see blocks.gd _define_layout). Tiers grow in danger and in
## SIZE: the silhouette on the horizon tells you what you are getting into.
@export var preset_tiers: Array[int] = [5, 6, 7, 8, 9, 10]   # scout → runner → raider → lancer → breaker → siege
## Player machine value (sum of G.shop_price over its blocks) at which each tier starts. A starter
## cabin is about 1800, a finished combat machine some ten thousand.
@export var tier_from_value: Array[int] = [0, 6000, 9000, 13000, 18000, 26000]

var _enemies: Array = []
var _clean_t: float = 0.0                           # throttle for pruning dead enemies from the list
var _far_time: Dictionary = {}                      # enemy -> seconds it has been far away
var _invader: Node3D = null                         # the single invader, if one exists now
var _t: float = 0.0
var _ready_done: bool = false
var _seeded: bool = false          # the initial batch has been placed

var _scan_state: int = 0                            # 0 idle, 1 warning in progress
var _scan_t: float = 0.0                            # until the next scan
var _scan_left: float = 0.0                         # left until the sweep
var _scan_center: Vector3 = Vector3.ZERO
var _scan_marker: Node3D = null

func _ready() -> void:
	# Wait for the terrain (map loads md after its own await).
	var guard: int = 0
	var map: Node = _find_map()
	while (map == null or not map.has_method("get_dims") or map.get_dims().x <= 0) and guard < 300:
		await get_tree().process_frame
		map = _find_map()
		guard += 1
	_ready_done = map != null and map.has_method("get_dims") and map.get_dims().x > 0
	_scan_t = randf_range(scan_min_interval, scan_max_interval)

func _process(delta: float) -> void:
	var _pf := Perf.now()          # profiler mark (perf.gd)
	_tick_spawner(delta)
	Perf.mark("spawner", _pf)

func _tick_spawner(delta: float) -> void:
	if not _ready_done:
		return
	# Debug gate for the regular stream only. Quest machines go through spawn_at and are never
	# gated: a quest that silently refuses to start is worse to debug than one extra enemy.
	if not G.debug(&"enemy_spawn"):
		return
	# Twice a second, not per frame: .filter() allocates a Callable and an Array and walks every
	# enemy, all for a rare event. A stale entry for half a second changes nothing.
	_clean_t -= delta
	if _clean_t <= 0.0:
		_clean_t = 0.5
		_enemies = _enemies.filter(func(e): return is_instance_valid(e))
	_track_dormancy(delta)
	_limit_engagement()
	if G.debug(&"sector_scan"):
		_scan_tick(delta)                           # the rare sector scan event
	# The cap counts AWAKE ones: a sleeper past the horizon does nothing, and counting it would
	# let four forgotten machines disable spawning forever.
	if _awake_count() >= _awake_cap():
		return
	# First run: fill the world at once rather than one at a time.
	if not _seeded:
		if _tutorial_active():
			return                      # tutorial running: the world is silent and the grace has not started
		# The grace starts when the tutorial ends (or at once if there was none), which is why
		# it is set here and not in _ready.
		if _seed_grace < 0.0:
			_seed_grace = first_spawn_delay
		_seed_grace -= delta
		if _seed_grace > 0.0:
			return
		_seeded = true
		for _i in mini(initial_enemies, _awake_cap()):
			_spawn_one()
		_t = _spawn_wait()
		return
	_t -= delta
	if _t > 0.0:
		return
	_t = _spawn_wait()
	_spawn_one()

# ── ПОТОК РАСТЁТ ВМЕСТЕ С ИГРОКОМ ────────────────────────────────────────────
# Сколько врагов не спит и как часто приходит следующий — не константы, а доля от давления мира
# (G.threat_ramp: 0 на первом грейде, 1 к четвёртому). Раньше поток был одинаков с первой минуты,
# и первые часы игры выглядели так же, как поздние: пока игрок учится ставить второй блок, к нему
# уже едут двое, а следом открытые с самого начала события приводят ещё нескольких — «спавнит
# всех скопом» это оно и есть.
#
# Ослабляем именно ПОТОК, а не самих врагов: сборку врага и так подбирает _pick_preset по цене
# машины игрока, а выкуп за него считается от этой сборки. Время → сложность → награда, в этом
# порядке, и каждое звено уже на месте — не хватало только первого.
@export var max_enemies_early: int = 1          ## сколько не спит на первом грейде
@export var spawn_interval_early_mul: float = 2.2   ## во столько раз реже приходит следующий

func _awake_cap() -> int:
	return int(round(G.threat_lerp(float(mini(max_enemies_early, max_enemies)), float(max_enemies))))

func _spawn_wait() -> float:
	return spawn_interval * G.threat_lerp(spawn_interval_early_mul, 1.0)

# Who may fight right now: the max_engaging nearest enemies that already noticed the player.
# By DISTANCE, not by who noticed first, or the right would stay with someone already behind a
# hill. "Wants to fight" means having a target, and that only works because the ban no longer
# CLEARS the target (enemy_vehicle._update_ai) - when it did, the flag destroyed its own input
# and the enemy re-acquired hundreds of times a minute, firing on every cycle.
func _limit_engagement() -> void:
	var player: Node3D = _player()
	if player == null:
		return
	var seekers: Array = []
	for e in _enemies:
		if not is_instance_valid(e) or not e.has_method("set_combat_allowed"):
			continue
		if _is_asleep(e):
			continue                           # a sleeper does not fight and takes no engagement slot
		# BASES DO NOT QUEUE. The cap exists so DRIVING enemies do not pile on; a building goes
		# nowhere, and a silent turret you can drive past reads as broken. That is what happened:
		# charging towers around a quest tower are bases too, and with one slot it went to the
		# nearest one - usually the unarmed charger.
		if e.get("is_base") == true:
			e.set_combat_allowed(true)
			continue
		# Only those going FOR THE PLAYER. Two enemies shooting each other ("Crossfire") are not
		# his problem, and banning one of them would kill the fight the event is about.
		var t = e.get("_target")
		if t != null and t == player:
			seekers.append(e)
		else:
			e.set_combat_allowed(true)         # no target, or not the player: no limit
	seekers.sort_custom(func(a, b):
		return player.global_position.distance_squared_to(a.global_position) \
				< player.global_position.distance_squared_to(b.global_position))
	for i in seekers.size():
		seekers[i].set_combat_allowed(i < max_engaging)

# Far enemies SLEEP instead of being returned to the player: that is what makes retreat work.
func _track_dormancy(delta: float) -> void:
	for k in _far_time.keys():
		if not is_instance_valid(k):
			_far_time.erase(k)
	var player: Node3D = _player()
	if player == null:
		return
	# Bases sleep by the same rules: each carries several turrets, and WeaponBlock ticks every
	# physics frame. They do not count against max_enemies - that cap is about who drives at you.
	for e in _enemies + _bases:
		if not is_instance_valid(e):
			continue
		# Squared: this loop runs over every enemy every frame, the hottest distance here.
		var d2: float = player.global_position.distance_squared_to(e.global_position)
		# Shadows only up close: casting is a second pass over 30-40 separate block meshes, and at
		# a hundred metres the shadow is a few pixels. Toggled on state change only.
		var want_shadow: bool = d2 < SHADOW_DIST * SHADOW_DIST
		if bool(e.get_meta("shadows_on", true)) != want_shadow:
			e.set_meta("shadows_on", want_shadow)
			_set_shadows(e, want_shadow)
		if d2 > sleep_dist * sleep_dist:
			_far_time[e] = float(_far_time.get(e, 0.0)) + delta
			if _far_time[e] >= sleep_delay:
				_sleep(e)
		else:
			_far_time.erase(e)
			_wake(e)
	_release_lost_invader(player)
	_trim_sleepers(player)

# The invader holds its slot while alive and is never trimmed. Unqualified that means forever:
# the player drives off, it sleeps past the horizon, and the sector scan can never fire again.
# Far beyond sleep_dist it counts as having lost the chase.
const INVADER_GIVE_UP: float = 2.0        # multiple of sleep_dist past which it cannot catch up

func _release_lost_invader(player: Node3D) -> void:
	if _invader == null or not is_instance_valid(_invader):
		_invader = null
		return
	if not _is_asleep(_invader):
		return
	var give_up: float = sleep_dist * INVADER_GIVE_UP
	if player.global_position.distance_squared_to(_invader.global_position) < give_up * give_up:
		return
	_enemies.erase(_invader)
	_invader.queue_free()
	_invader = null

# Asleep: physics frozen, AI and weapons not ticking. process_mode disables the WHOLE branch,
# or child turrets would keep turning and firing past the horizon.
## Beyond this distance a machine stops casting shadows (receiving them continues).
const SHADOW_DIST: float = 90.0

## Set shadow casting across a whole node branch. Called on state change, not per frame.
func _set_shadows(n: Node, on: bool) -> void:
	var gi := n as GeometryInstance3D
	if gi != null:
		gi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if on \
				else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	for c in n.get_children():
		_set_shadows(c, on)

func _sleep(e: Node3D) -> void:
	if bool(e.get_meta("asleep", false)):
		return
	e.set_meta("asleep", true)
	if e is RigidBody3D:
		e.linear_velocity = Vector3.ZERO
		e.angular_velocity = Vector3.ZERO
		e.freeze = true
	e.process_mode = Node.PROCESS_MODE_DISABLED
	# And hide it: a disabled process still draws. A sleeper at four hundred metres is a few
	# pixels and 30-40 separate meshes in the draw call count.
	e.visible = false

func _wake(e: Node3D) -> void:
	if not bool(e.get_meta("asleep", false)):
		return
	e.set_meta("asleep", false)
	e.process_mode = Node.PROCESS_MODE_INHERIT
	e.visible = true
	# Never unfreeze a BASE: it is anchored by nature, not by sleep. Unfrozen, a wheel-less
	# building with off-centre collision tips over on the first physics step.
	if e is RigidBody3D and e.get("is_base") != true:
		e.freeze = false
		e.sleeping = false

func _is_asleep(e: Node) -> bool:
	return is_instance_valid(e) and bool(e.get_meta("asleep", false))

func _awake_count() -> int:
	var n: int = 0
	for e in _enemies:
		if is_instance_valid(e) and not _is_asleep(e) and e != _invader:
			n += 1
	return n

# Sleepers accumulate while the player roams. Over max_total the farthest SLEEPER goes; awake
# ones are in combat and the invader waits as long as it likes.
func _trim_sleepers(player: Node3D) -> void:
	if _enemies.size() <= max_total:
		return
	var worst: Node3D = null
	var worst_d2: float = -1.0
	for e in _enemies:
		if not is_instance_valid(e) or e == _invader or not _is_asleep(e):
			continue
		if bool(e.get_meta("story", false)):
			continue                           # an enemy brought by a quest: a task is waiting for it
		var d2: float = player.global_position.distance_squared_to((e as Node3D).global_position)
		if d2 > worst_d2:
			worst_d2 = d2
			worst = e
	if worst != null:
		_enemies.erase(worst)
		worst.queue_free()

## The first enemy of a save deals half damage: the player meets it right after the tutorial on
## the starter kit, with no research. DAMAGE, not HP - it must still break apart the same way,
## the player just gets time to understand what is happening.
const FIRST_ENEMY_DAMAGE := 0.5

## Goes to the first one that came FOR THE PLAYER (regular stream, story scout), never to event
## machines: duellists fight each other, so spending "the first" on them helps nobody. The flag
## persists in the save.
func _mark_first_enemy(enemy: Node) -> void:
	if enemy == null or G == null or G.first_enemy_met:
		return
	G.first_enemy_met = true
	G.mark_progress_dirty()
	enemy.set("damage_scale", FIRST_ENEMY_DAMAGE)

func _spawn_one() -> void:
	if enemy_scenes.is_empty() or _tutorial_active():
		return
	var map: Node = _find_map()
	var player: Node3D = _player()
	if map == null or player == null:
		return
	var pos = _find_spawn_pos(map, player.global_position)
	if pos == null:
		return

	var enemy: Node3D = enemy_scenes.pick_random().instantiate()
	# The build is set BEFORE add_child (blocks assembles in its _ready).
	var blocks := enemy.get_node_or_null("blocks")
	if blocks and "layout_preset" in blocks:
		blocks.layout_preset = _pick_preset(player)

	var vehicles: Node = _vehicles_root()
	if vehicles == null:
		return
	vehicles.add_child(enemy)
	enemy.global_position = pos
	if enemy is RigidBody3D:
		(enemy as RigidBody3D).linear_velocity = Vector3.ZERO   # falls by its own weight, not thrown
	if enemy.has_signal("died") and not enemy.died.is_connected(_on_enemy_died):
		enemy.died.connect(_on_enemy_died)
	_mark_first_enemy(enemy)          # the tutorial can be skipped, and then the first enemy comes from here
	_enemies.append(enemy)

# ── ВРАЖЕСКИЕ БАЗЫ: только сон и тени ─────────────────────────────────────────
# We keep the list, outposts.gd PLACES the bases. Simple split: where a base stands is a map
# question, while "switch off the one past the horizon" is one rule for everything that shoots.
var _bases: Array = []

## Take a base under watch (called by outposts when a point materialises).
func register_base(b: Node) -> void:
	if b == null or _bases.has(b):
		return
	_bases.append(b)
	if b.has_signal("died") and not b.died.is_connected(_on_base_died):
		b.died.connect(_on_base_died)

func _on_base_died(b: Node) -> void:
	_bases.erase(b)

# Which build to send. TerraTech rule: an enemy of roughly your machine's weight, picked there by
# total block value - and we finally have that value (G.shop_price is derived from the recipe). It
# used to be a dice roll, so two guns could arrive at a starter cabin.
#
# VALUE SETS THE CEILING, NOT THE BUILD. The tier is rolled RANDOMLY from the first up to it: a
# level-three player meets first, second and third alike.
#
# The tier used to follow the player strictly (with a one-in-three chance to drop one), which gave
# two problems at once. Every fight was equally hard, so growing gained nothing and the reward was
# the same. And the world had no variety: whatever stood on the horizon was always an equal. The
# spread brings back both light skirmishes on the road and heavy meetings worth preparing for.
## ПОТОЛОК ТИРА ДЛЯ ЭТОГО ИГРОКА — по тому, на чём он едет СЕЙЧАС, и по давлению мира.
##
## Цена машины отвечает на вопрос «что он потянет», грейд — «сколько он уже играет», и берётся
## МЕНЬШЕЕ: игрок, вложивший всё в одну дорогую сборку на первом грейде, не должен получать против
## себя весь список, а игрок пятого грейда, только что потерявший машину и сидящий на стартовой
## кабине, — тем более.
func _tier_cap(player: Node3D) -> int:
	if preset_tiers.is_empty():
		return 0
	var value: int = _machine_value(player)
	var cap: int = 0
	for i in mini(preset_tiers.size(), tier_from_value.size()):
		if value >= int(tier_from_value[i]):
			cap = i
	var ramp_cap: int = int(floor(G.threat_ramp() * float(preset_tiers.size() - 1) + 0.001))
	return maxi(mini(cap, ramp_cap), 0)

func _enemy_tier(player: Node3D) -> int:
	if preset_tiers.is_empty():
		return 0
	return randi() % (_tier_cap(player) + 1)

## СБОРКА ПО ЗАПРОСУ, НО НЕ ВЫШЕ ПОТОЛКА. Событие просит конкретные пресеты («лагерь: копейщик,
## крушитель, осадная») и до сих пор получало их независимо от того, на чём игрок сейчас едет:
## разобрали на пятом грейде — и через минуту встречает та же осадная машина, только теперь ты на
## стартовой кабине. Просьба события остаётся просьбой: если игрок потянет — придёт то, что просили,
## если нет — ближайшее, что он потянет.
##
## Пресет не из лестницы (вышки, базы, сюжетные носители) не трогаем: там сборка — часть задания.
func preset_for_request(preset: int) -> int:
	var player: Node3D = _player()
	if player == null or preset_tiers.is_empty():
		return preset
	var idx: int = preset_tiers.find(preset)
	if idx < 0:
		return preset
	return int(preset_tiers[mini(idx, _tier_cap(player))])

func _pick_preset(player: Node3D) -> int:
	if preset_tiers.is_empty():
		return 0
	return int(preset_tiers[_enemy_tier(player)])

# Machine value: the sum of shop prices of its blocks. Everything else in the game is measured the
# same way, so "stronger" here means what it means in the garage.
func _machine_value(machine: Node3D) -> int:
	var blocks: Node = machine.get_node_or_null("blocks") if machine != null else null
	if blocks == null:
		return 0
	var v: int = 0
	for b in blocks.get_children():
		if "block" in b:
			v += G.shop_price(int(b.get("block")))
	return v

## A scout CLOSE to the player - the story spawn after the tutorial. The regular stream keeps
## "enemy vision + margin" so as not to pile on; here the point is that the player sees it at once,
## hence its own distance and the weakest build.
##
## PLACED ALONG THE MACHINE'S HEADING, not at a random ring angle. This is the ONE place where the
## regular rule (front_clear_dist: never appear in front) is inverted, and deliberately: there an
## enemy must not be seen MATERIALISING, here it is the opposite - this is the player's first enemy,
## it drops from the sky, and the whole show is wasted if a random angle puts it behind him. At that
## moment he does not yet know the camera can be turned, and the first sign of an enemy was gunfire
## from somewhere behind.
##
## The heading comes from the FORWARD VECTOR flattened to the horizon, not from global_rotation.y: on
## a slope the Euler angle is not a heading (same rule as the camera, see CLAUDE.md).
const SCOUT_FRONT_SPREAD := 0.42            # +-24 deg: slightly aside so it does not land exactly on the nose
## Returns the enemy or null if scenes, map or player are missing. The spot is not validated: it
## drops in and rolls off a slope by itself, the same rule the ring spawn uses.
func spawn_scout_near_player(min_d: float = 20.0, max_d: float = 40.0) -> Node3D:
	if enemy_scenes.is_empty():
		return null
	var map: Node = _find_map()
	var player: Node3D = _player()
	var vehicles: Node = _vehicles_root()
	if map == null or player == null or vehicles == null:
		return null
	var center: Vector3 = player.global_position
	var fwd: Vector3 = -player.global_transform.basis.z
	fwd.y = 0.0
	# A machine standing nose straight up (flipped, hanging in the air) gives a zero horizontal
	# heading - then any direction is equally fair, so take a random one.
	var base: float = atan2(fwd.z, fwd.x) if fwd.length_squared() > 0.0001 else randf() * TAU
	var ang: float = base + randf_range(-SCOUT_FRONT_SPREAD, SCOUT_FRONT_SPREAD)
	var dist: float = randf_range(min_d, max_d)
	var world := center + Vector3(cos(ang) * dist, 0.0, sin(ang) * dist)
	# Height through the ONE function (project rule): until the map's heights are read, raw
	# terrain_height_at returns zero and the scout would drop underground.
	var pos := Vector3(world.x, G.ground_y(world, center.y) + drop_height, world.z)
	var enemy: Node3D = enemy_scenes.pick_random().instantiate()
	var blocks := enemy.get_node_or_null("blocks")
	if blocks and "layout_preset" in blocks:
		# The WEAKEST tier, not "build number 0": the first fight must be winnable, and preset 0 was simply
		# first in the list rather than the easiest. The order lives in preset_tiers now.
		blocks.layout_preset = int(preset_tiers[0]) if not preset_tiers.is_empty() else 0
	vehicles.add_child(enemy)
	enemy.global_position = pos
	if enemy is RigidBody3D:
		(enemy as RigidBody3D).linear_velocity = Vector3.ZERO   # falls by its own weight
	# Tagged as story so sleep cleanup cannot remove it. Without the tag the quest "destroy the scout"
	# could become silently impossible: the player drives off, the scout sleeps, cleanup takes it as the
	# farthest one, and the quest keeps pointing at a target that no longer exists.
	enemy.set_meta("story", true)
	if enemy.has_signal("died") and not enemy.died.is_connected(_on_enemy_died):
		enemy.died.connect(_on_enemy_died)
	_mark_first_enemy(enemy)          # usual path: the end of the tutorial brings this scout
	# And REGARDLESS OF THE FLAG: the scout arrives at the end of the tutorial, when the player has the
	# starter kit and no research. If "the first" was already spent on someone from the regular stream,
	# the discount must still reach here, or the first story fight runs at full strength against a
	# machine assembled five minutes ago.
	enemy.set("damage_scale", FIRST_ENEMY_DAMAGE)
	_enemies.append(enemy)
	return enemy

## Place an enemy AT A GIVEN POINT with a given build and FACTION. Events need it: there machines
## fight each other as well as the player, and friend-or-foe is decided by faction
## (enemy_vehicle._is_enemy compares it, so 1 against 2 are already enemies).
##
## Tagged as story: sleep cleanup must not remove an event participant while the player drives to it.
## It still joins the regular stream as an ordinary enemy - counted, put to sleep, subject to the
## engagement cap.
##
## as_base = true means a BUILDING rather than a machine: frozen hull, cabinless layout, spawner
## supervision. The flag must be set BEFORE add_child - _ready freezes the body by it, and set
## afterwards it is too late: an unfrozen hull with off-centre collision tips over on the first
## physics step. A building needs no drop either: a frozen body does not fall, it would simply hang
## at drop_height.
func spawn_at(pos: Vector3, preset: int, faction_id: int = 1, as_base: bool = false) -> Node3D:
	if enemy_scenes.is_empty():
		return null
	var vehicles: Node = _vehicles_root()
	if vehicles == null:
		return null
	var enemy: Node3D = enemy_scenes.pick_random().instantiate()
	if as_base:
		enemy.set("is_base", true)
	var blocks := enemy.get_node_or_null("blocks")
	if blocks and "layout_preset" in blocks:
		blocks.layout_preset = preset
		if as_base and "is_station" in blocks:
			blocks.is_station = true
	if "faction" in enemy:
		enemy.set("faction", faction_id)
	vehicles.add_child(enemy)
	if as_base:
		enemy.global_position = Vector3(pos.x, G.ground_y(pos, pos.y) + 0.5, pos.z)
		if enemy is RigidBody3D:
			(enemy as RigidBody3D).linear_velocity = Vector3.ZERO
		enemy.set_meta("story", true)
		if enemy.has_signal("died") and not enemy.died.is_connected(_on_enemy_died):
			enemy.died.connect(_on_enemy_died)
		_enemies.append(enemy)
		register_base(enemy)          # sleep and shadows: one rule for everything that shoots
		return enemy
	# The drop is measured FROM THE TERRAIN AT THIS POINT, not from the passed height. We are called
	# with offsets ("a guard twelve metres from the cargo", "duellists either side of the centre") and
	# the height there is its own: on a slope ten metres of margin are eaten by the hill and the machine
	# appeared INSIDE the ground.
	var ground: float = G.ground_y(pos, pos.y)
	enemy.global_position = Vector3(pos.x, maxf(pos.y, ground) + drop_height, pos.z)
	if enemy is RigidBody3D:
		(enemy as RigidBody3D).linear_velocity = Vector3.ZERO
	enemy.set_meta("story", true)
	if enemy.has_signal("died") and not enemy.died.is_connected(_on_enemy_died):
		enemy.died.connect(_on_enemy_died)
	_enemies.append(enemy)
	return enemy

# While the tutorial runs, the regular stream and sector scans stay silent: the player is being led
# by the hand and a raider mid-lesson only gets in the way. The first enemy is brought by the story
# (tutorial_director after the last step closes) and spawns around this gate.
func _tutorial_active() -> bool:
	var q: Node = get_node_or_null("/root/Q")
	return q != null and q.has_method("tutorial_active") and q.tutorial_active()

func _on_enemy_died(enemy: Node) -> void:
	# _process prunes the list by is_instance_valid; the only thing that matters here is freeing the
	# invader slot - while it is taken, a new sector scan sends nobody.
	if enemy == _invader:
		_invader = null

# Spawn point: a ring around the player, on the terrain, not on a cliff and NOT next to other
# enemies. The ring is divided into sectors and a new enemy goes into the one with the FEWEST right
# now, so evenness is by construction rather than a side effect.
#
# It took two attempts. First the first suitable candidate out of 36 around the circle was used:
# when part of the ring is rejected by water or a cliff (which is almost always), every spawn fell
# into the one surviving sector. Then the direction farthest in angle from live enemies was chosen -
# better, but a GREEDY choice: it works off the current arrangement only and on awkward terrain
# still skewed the ring one way. A per-sector count does not suffer from that: an occupied sector is
# not picked while empty ones exist. exclude is an enemy not counted as a neighbour (when
# teleporting that same one).
const SPAWN_SECTORS := 8

func _find_spawn_pos(map: Node, center: Vector3, exclude: Node = null):
	# How many enemies already stand in each sector.
	var per: Array[int] = []
	per.resize(SPAWN_SECTORS)
	per.fill(0)
	for e in _enemies:
		if e == exclude or not is_instance_valid(e):
			continue
		# Sleepers are NOT counted: the point of the counter is "where around the player is someone alive",
		# and one asleep half a map away is not in this sector in any meaningful sense. Counting them banned
		# a whole eighth of the ring because of a machine left behind an hour ago.
		if _is_asleep(e):
			continue
		var d: Vector3 = (e as Node3D).global_position - center
		if Vector2(d.x, d.z).length_squared() < 0.25:       # 0.5 squared, comparison only
			continue
		per[_sector_of(atan2(d.z, d.x))] += 1
	# Sectors by ascending occupancy; ties are shuffled, or an empty map would always fill from the same
	# side.
	#
	# ON EQUAL OCCUPANCY, TAKE THE REAR. The "never appear on his heading" ban (_in_player_view) only
	# covers the MOMENT of appearing: an enemy shows up eighty metres to the side, the rule is satisfied,
	# and ten seconds later the player turns toward a quest marker and it is right in the way. With two
	# awake on a ring of 80..160 m that happened EVERY time and read as "they are waiting for me". From
	# behind and behind-the-side an enemy catches up instead of blocking: the meeting happens when the
	# player decides to stop and take it.
	var back: Array[int] = []
	back.resize(SPAWN_SECTORS)
	back.fill(0)
	var pl: Node3D = _player()
	if pl != null:
		var fwd: Vector3 = -pl.global_transform.basis.z
		if Vector2(fwd.x, fwd.z).length_squared() > 0.0001:
			var head: float = atan2(fwd.z, fwd.x)
			for i in SPAWN_SECTORS:
				var mid: float = (TAU / SPAWN_SECTORS) * (float(i) + 0.5)
				# 1 — сектор смотрит вперёд (хуже), 0 — назад и вбок-назад (лучше).
				back[i] = 1 if absf(wrapf(mid - head, -PI, PI)) < deg_to_rad(100.0) else 0
	var order: Array[int] = []
	for i in SPAWN_SECTORS:
		order.append(i)
	order.shuffle()
	order.sort_custom(func(a, b):
		if per[a] != per[b]:
			return per[a] < per[b]
		return back[a] < back[b])
	# Ring bounds are computed ONCE per search: enemy vision does not change during the loop.
	var near: float = _spawn_min_dist()
	var far: float = maxf(spawn_max_dist, near + 20.0)   # the ring cannot be inside out
	# Several attempts inside a sector: a point may be taken by a neighbour, the player's heading or a
	# quiet zone.
	for sec in order:
		for _try in 6:
			var ang: float = (TAU / SPAWN_SECTORS) * (float(sec) + randf())
			var dist: float = randf_range(near, far)
			var world := center + Vector3(cos(ang) * dist, 0.0, sin(ang) * dist)
			var h: float = map.terrain_height_at(world)
			var cand := Vector3(world.x, h + drop_height, world.z)
			if _too_close_to_enemy(cand, exclude):
				continue
			if _in_player_view(cand, center):
				continue                       # по курсу и близко — игрок увидел бы появление
			if _near_anchored_base(cand):
				continue                       # quiet zone: no spawns near an anchored player machine
			return cand
	return null

# A point on the player's HEADING and close enough for the appearance to be NOTICED. We look at the
# machine's direction, not the camera's: the camera is turned constantly, which would make the spawn
# random, while ahead of the machine is where he is driving and looking most of the time.
func _in_player_view(pos: Vector3, center: Vector3) -> bool:
	var player: Node3D = _player()
	if player == null:
		return false
	var to: Vector3 = pos - center
	to.y = 0.0
	if to.length_squared() > front_clear_dist * front_clear_dist:
		return false                           # далеко — пусть появляется хоть прямо по курсу
	var fwd: Vector3 = -player.global_transform.basis.z
	fwd.y = 0.0
	if fwd.length_squared() < 0.0001 or to.length_squared() < 0.0001:
		return false
	return rad_to_deg(fwd.normalized().angle_to(to.normalized())) < front_cone_deg

# Is the point inside the quiet zone of some ANCHORED player machine?
#
# We look at the anchor rather than "is one of my machines nearby": a driving machine needs no
# protection, it can leave. An anchored one cannot: the anchor is released by hand, the factory runs
# under it, and at exactly that moment the player is busy with the conveyor rather than the wheel.
#
# anchored lives on vehicle_body_3d (player machines) and enemies do not have it, so it is read
# through get() and anyone without it is silently skipped.
func _near_anchored_base(pos: Vector3) -> bool:
	var vehicles: Node = _vehicles_root()
	if vehicles == null:
		return false
	for v in vehicles.get_children():
		if not (v is Node3D) or not is_instance_valid(v):
			continue
		var f = v.get("faction")
		if f != null and int(f) != 0:
			continue                           # PLAYER machines only
		# Compared with true, NOT bool(...): get() returns null on a machine without the field, and
		# bool(null) cannot be constructed in Godot 4 - "Invalid call. Nonexistent bool constructor" at
		# runtime. Foreign nodes reach here too.
		if v.get("anchored") != true:
			continue
		if pos.distance_squared_to((v as Node3D).global_position) < quiet_radius * quiet_radius:
			return true
	return false

## Inner ring edge: HOW FAR AN ENEMY SEES plus the margin.
func _spawn_min_dist() -> float:
	return _enemy_detect_radius() + spawn_safe_margin

## Enemy vision radius, asked from a live one - builds may differ, and hardcoding a copy of the
## number from enemy_vehicle would mean they eventually diverge. Cached: it does not change per frame.
var _detect_cache: float = -1.0

func _enemy_detect_radius() -> float:
	if _detect_cache > 0.0:
		return _detect_cache
	for e in _enemies:
		if is_instance_valid(e):
			var r = e.get("detection_radius")
			if r != null and float(r) > 0.0:
				_detect_cache = float(r)
				return _detect_cache
	return enemy_detect_fallback

func _sector_of(ang: float) -> int:
	return int(wrapf(ang, 0.0, TAU) / (TAU / SPAWN_SECTORS)) % SPAWN_SECTORS

# Is there already an enemy closer than spawn_safe_margin (horizontally) to pos? Without that margin
# a new drop would land on someone already standing in this sector.
func _too_close_to_enemy(pos: Vector3, exclude: Node) -> bool:
	for e in _enemies:
		if e == exclude or not is_instance_valid(e):
			continue
		var d := Vector2(pos.x - e.global_position.x, pos.z - e.global_position.z)
		if d.length_squared() < spawn_safe_margin * spawn_safe_margin:
			return true
	return false

func _find_map() -> Node:
	if map_node:
		return map_node
	var m: Node = get_node_or_null("../map")
	if m == null:
		m = get_node_or_null("/root/Main/map")
	return m

func _vehicles_root() -> Node:
	var v: Node = get_node_or_null("../Vehicles")
	if v == null:
		v = get_node_or_null("/root/Main/Vehicles")
	return v

func _player() -> Node3D:
	var cc: Node = get_tree().get_first_node_in_group("camera_controller")
	if cc and "current_vehicle" in cc and is_instance_valid(cc.current_vehicle):
		return cc.current_vehicle
	return null

# ── Проверка сектора (редкое событие) ─────────────────────────────────────────
func _scan_tick(delta: float) -> void:
	if not scan_enabled:
		return
	if _scan_state == 0:
		_scan_t -= delta
		if _scan_t <= 0.0:
			_start_scan()
	else:
		_scan_left -= delta
		_pulse_marker()
		if _scan_left <= 0.0:
			_resolve_scan()

func _start_scan() -> void:
	var p := _player()
	if p == null:
		_scan_t = 30.0                              # игрока нет — попробуем позже
		return
	# Захватчик уже в мире — проверку не объявляем ВОВСЕ. Иначе Система обещала бы прислать
	# обработчика, а _spawn_invader молча отказывал бы по правилу «один за раз»: игрок видел
	# бы разметку квадрата, таймер, угрозу — и ничего. Пустое обещание хуже, чем тишина.
	if _invader != null and is_instance_valid(_invader):
		_scan_t = 60.0
		return
	_scan_center = p.global_position
	_scan_state = 1
	_scan_left = scan_warn_time
	_build_marker()
	# Обманка: Система ВЕЖЛИВО просит НЕ выходить — кто послушается, того зачистка :)
	_say("System", "Scheduled sector scan. Please do NOT leave the scan zone. This will take %d sec. Thank you for your cooperation." % int(scan_warn_time))

func _resolve_scan() -> void:
	_scan_state = 0
	_scan_t = randf_range(scan_min_interval, scan_max_interval)
	_clear_marker()
	var p := _player()
	# The System does not track who left - it simply scans the area. Activity inside (player machines)
	# means "something suspicious" and a reinforced unit; empty means a neutral report.
	if p != null and _in_scan_box(p.global_position):
		_say("System", "Unauthorized activity detected in the sector. Dispatching a handler.")
		_spawn_invader(p)              # the invader goes for the DETECTED machine
	else:
		_say("System", "Sector scan complete. No anomalies detected.")

func _in_scan_box(pos: Vector3) -> bool:
	return absf(pos.x - _scan_center.x) <= scan_half_size and absf(pos.z - _scan_center.z) <= scan_half_size

# THE INVADER is a single machine that DROPS IN at the edge of the square, already locked on the
# detected machine.
#
# It deliberately ignores the usual rules: it does not count against max_enemies, is never removed
# by sleep cleanup and never forgets its target. This is an event, not background, and it must behave
# like one - until the player kills it or leaves for good.
#
# While the previous invader lives, no new one is sent: exactly one at a time, like TerraTech's
# invader. Otherwise a rare event happening twice in a row becomes a crowd again.
func _spawn_invader(locked: Node3D = null) -> void:
	if _invader != null and is_instance_valid(_invader):
		return
	var map: Node = _find_map()
	var vehicles: Node = _vehicles_root()
	if map == null or vehicles == null or enemy_scenes.is_empty():
		return
	var enemy: Node3D = enemy_scenes.pick_random().instantiate()
	var blocks := enemy.get_node_or_null("blocks")
	if blocks and "layout_preset" in blocks:
		blocks.layout_preset = scan_preset      # reinforced build
	vehicles.add_child(enemy)
	var ang: float = randf() * TAU
	var r: float = scan_half_size * 0.8
	var wp: Vector3 = _scan_center + Vector3(cos(ang) * r, 0.0, sin(ang) * r)
	var h: float = map.terrain_height_at(wp) if map.has_method("terrain_height_at") else wp.y
	# It FALLS from height rather than appearing on the ground. It shows up at the edge of the square,
	# i.e. near the player; for someone standing still that read as "a machine materialised twenty metres
	# away and opened fire". The fall gives the seconds in which it can be seen and heard.
	enemy.global_position = Vector3(wp.x, h + drop_height, wp.z)
	if enemy is RigidBody3D:
		(enemy as RigidBody3D).linear_velocity = Vector3.ZERO
	if enemy.has_signal("died") and not enemy.died.is_connected(_on_enemy_died):
		enemy.died.connect(_on_enemy_died)
	# The target is assigned immediately, without waiting for its detection zone, and relentless is
	# switched on: an ordinary enemy finds and can lose a target, while this one came for the machine
	# the scan detected.
	_lock_on_target(enemy, locked)
	_enemies.append(enemy)
	_invader = enemy

# Force a target on an enemy (no waiting for the detection signal) and make it relentless.
func _lock_on_target(enemy: Node, target: Node3D) -> void:
	if target == null or not is_instance_valid(target):
		return
	if enemy.has_method("assign_target"):
		enemy.assign_target(target, true)

# Square marker: four glowing pillars at the corners (they survive uneven terrain). They pulse and
# turn red toward the end of the countdown - an alarm.
func _build_marker() -> void:
	_clear_marker()
	_scan_marker = Node3D.new()
	get_tree().current_scene.add_child(_scan_marker)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(0.2, 0.9, 1.0)
	mat.emission_enabled = true
	mat.emission = Color(0.2, 0.9, 1.0)
	var map: Node = _find_map()
	for sx in [-1.0, 1.0]:
		for sz in [-1.0, 1.0]:
			var pillar := MeshInstance3D.new()
			var bm := BoxMesh.new()
			bm.size = Vector3(1.4, 60.0, 1.4)
			pillar.mesh = bm
			pillar.material_override = mat
			pillar.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			var wx: float = _scan_center.x + sx * scan_half_size
			var wz: float = _scan_center.z + sz * scan_half_size
			var h: float = map.terrain_height_at(Vector3(wx, 0.0, wz)) if (map and map.has_method("terrain_height_at")) else _scan_center.y
			pillar.position = Vector3(wx, h + 28.0, wz)
			_scan_marker.add_child(pillar)
	_scan_marker.set_meta("mat", mat)

func _pulse_marker() -> void:
	if _scan_marker == null or not _scan_marker.has_meta("mat"):
		return
	var mat: StandardMaterial3D = _scan_marker.get_meta("mat")
	var t: float = 0.5 + 0.5 * sin(Time.get_ticks_msec() * 0.008)
	var danger: float = 1.0 - clampf(_scan_left / maxf(scan_warn_time, 0.01), 0.0, 1.0)
	mat.emission = Color(0.2 + danger * 0.8, 0.9 - danger * 0.7, 1.0 - danger * 0.85)
	mat.emission_energy_multiplier = 1.0 + t * 2.0 + danger * 3.0

func _clear_marker() -> void:
	if _scan_marker != null and is_instance_valid(_scan_marker):
		_scan_marker.queue_free()
	_scan_marker = null

func _say(speaker: String, text: String) -> void:
	var d: Node = get_node_or_null("/root/Dialogue")
	if d and d.has_method("say"):
		d.say(speaker, text)
