extends Node3D
## Menu backdrop: a REAL fight on a REAL map.
##
## Nothing here is faked any more. The ground is a LiteTerrain map with streamed collision, the
## machines are the game's enemy scenes with their own physics, AI, weapons and wreckage - two of
## them, of DIFFERENT factions, so they treat each other as enemies exactly the way the game
## decides that (enemy_vehicle._is_enemy compares faction).
##
## A round runs ROUND_TIME, and only THEN does the next map start generating - the fight keeps
## going while it does. When generation finishes the round resets: EVERYTHING of the old round is
## removed first (map, machines, their wreckage and bullets), and only then is the new one added.
## Only ever one generation at a time (_gen_busy), or a second round would queue up behind the first
## and the swap would happen twice.
##
## THE MAP IS NOT CHANGED BECAUSE A MACHINE DIED. A kill takes seconds, generation takes tens of
## them, and tying one to the other meant the ground changed under a fight that had just started.
## A machine that dies or loses its last gun is simply REPLACED by another random build on the spot
## (_replace_fallen), so there is always something to watch until the round is up.
##
## The demo machines carry `demo = true`: no rewards, no quest progress on death, and no way out of
## the fight (see enemy_vehicle). A backdrop where both sides drive apart shows nothing.
##
## The FIRST map is the one authored in the scene (`Stage/LiteTerrain`): a baked heightmap made with
## the plugin. It loads in a moment, so the menu opens on a real world instead of on an empty sky
## while the first generation runs. Every map after it is generated here, at MAP_SIZE.

const ENEMY_SCENE := preload("res://enemy.tscn")
const MAP_SCRIPT := preload("res://addons/LiteTerrain/map.gd")

## Generated rounds use a 256-cell map: a fight needs a couple of hundred metres, and a quarter of
## the cells means a quarter of the noise and of the chunk meshes - the run finishes well inside a
## round, on a phone too. The authored first map keeps whatever size it was baked at.
const MAP_SIZE := 256
const ROUND_TIME := 30.0
## Distance between the two machines at the start: they must see each other (enemy vision is 40 m)
## and still have room to manoeuvre.
const START_GAP := 34.0
## Builds are the same enemy presets the game sends (blocks.gd): scout to siege.
const PRESETS := [5, 6, 7, 8, 9, 10]
## How long a fresh machine is left alone before it is judged disarmed. Blocks are assembled in the
## machine's own _ready and the weapons appear over the frames after that: without the grace every
## spawn counts as weaponless in the frame it is born and is replaced at once, forever.
const ARM_GRACE := 3.0

## Camera: an orbit around the middle of the fight, high enough to see both machines and the ground
## between them.
const CAM_HEIGHT := 26.0
const CAM_DIST := 34.0
const CAM_ORBIT := 0.06          # rad/s
## Never closer than this to whatever is directly under the camera.
const CAM_CLEARANCE := 8.0

var _rng := RandomNumberGenerator.new()
var _t: float = 0.0
var _round_t: float = 0.0
@onready var _cam: Camera3D = %MenuCamera
@onready var _machines_root: Node3D = %Machines

var _map: Node3D = null          # the map the fight runs on
var _next_map: Node3D = null     # the one being generated in the background
var _gen_busy: bool = false
var _fighters: Array = []
## Per fighter, in the same order: when it was spawned and whether it has ever had a gun. Both are
## only there to tell "still being assembled" from "shot to pieces" (see ARM_GRACE).
var _born: Array = []
var _armed: Array = []
## Angle of the line the pair stands on. Kept for the round, so a replacement machine appears where
## its predecessor stood instead of somewhere behind the camera.
var _ring_ang: float = 0.0
var _swapping: bool = false

func _ready() -> void:
	_rng.randomize()
	set_process(true)       # the camera works while the first map is still being generated
	await _open_round()

# ── Rounds ───────────────────────────────────────────────────────────────────
## Open the first round on the scene map; if it is gone (someone deleted the node), generate one.
func _open_round() -> void:
	_map = get_node_or_null("LiteTerrain") as Node3D
	if _map != null:
		# The scene map loads its own baked heightmap and sets up its own collision in _ready.
		if not await _wait_terrain(_map):
			_map = null
	if _map == null:
		_map = await _make_map()
		if _map == null:
			return
		_map.set_collision_streaming(true)
	_spawn_pair()
	_round_t = ROUND_TIME
	_move_camera()          # first frame already looks at the fight, not at the origin

## A map generated from its own seed. `force_procedural` keeps it away from G: the slot's seed
## belongs to the save, this one is scenery.
func _make_map() -> Node3D:
	var m := StaticBody3D.new()
	m.set_script(MAP_SCRIPT)
	m.force_procedural = true
	m.forced_seed = _rng.randi() | 1
	m.window_size = MAP_SIZE
	m.use_image_data = false
	# THE SAME PRESET THE EDITOR BUTTON USES. The procedural defaults are a compromise for the game's
	# own world; the menu wants the land the dock's "Natural preset" makes - big masses, drivable
	# slopes - and the numbers for it live in the generator, not here.
	var np := LiteTerrainGen.natural_params()
	m.proc_scale = float(np["scale"])
	m.proc_power = float(np["power"])
	m.proc_amplitude = float(np["amplitude"])
	m.proc_mountains01 = float(np["mountains"])
	# Collision OFF from the start: while this map builds its chunks it stands at the same origin as
	# the one on screen, and two heightfields under the same machines fight each other. It is turned
	# on in the frame this map becomes the visible one.
	m.start_without_collision = true
	add_child(m)
	if not await _wait_terrain(m):
		if is_instance_valid(m):
			m.queue_free()
		return null
	return m

## Wait until a map has its terrain up. Polled rather than awaiting terrain_ready: a map that never
## finishes (empty heights, a freed node) would leave this coroutine hanging forever, and with it
## the whole round loop.
func _wait_terrain(m: Node3D) -> bool:
	var guard: int = 0
	while is_instance_valid(m) and not m.terrain_is_ready and guard < 3600:
		await get_tree().process_frame
		guard += 1
	if is_instance_valid(m) and m.terrain_is_ready:
		return true
	push_warning("menu: terrain never became ready (%d frames)" % guard)
	return false

## Start the NEXT map. Runs while the current fight is still on screen, so nothing freezes; the
## round is only reset once this finishes. Guarded twice - a map already waiting, or a run already
## going - because both _process and the "no weapons left" check can ask for it in the same frame.
func _prepare_next() -> void:
	if _next_map != null or _gen_busy:
		return
	_gen_busy = true
	var m: Node3D = await _make_map()
	_gen_busy = false
	if m == null:
		return
	m.visible = false
	_next_map = m

func _spawn_pair() -> void:
	_ring_ang = _rng.randf() * TAU
	_fighters = [null, null]
	_born = [0.0, 0.0]
	_armed = [false, false]
	for side in 2:
		_spawn_fighter(side)
	_retarget()

## One machine on its side of the line, with a random build. Also the replacement for a machine that
## died or lost its guns - which is why the side, and not the machine, is what this takes.
func _spawn_fighter(side: int) -> void:
	var e: Node3D = ENEMY_SCENE.instantiate()
	# The build is set BEFORE add_child: blocks assembles the machine in its own _ready.
	var blocks := e.get_node_or_null("blocks")
	if blocks != null and "layout_preset" in blocks:
		blocks.layout_preset = int(PRESETS[_rng.randi() % PRESETS.size()])
	# DIFFERENT factions, otherwise they do not see each other as enemies at all. Neither is 0,
	# so neither of them counts as the player's.
	e.set("faction", 1 + side)
	e.set("demo", true)
	_machines_root.add_child(e)
	var dir := Vector3(cos(_ring_ang), 0.0, sin(_ring_ang))
	var p: Vector3 = dir * (START_GAP * 0.5) if side == 0 else dir * (-START_GAP * 0.5)
	# A REPLACEMENT LANDS BESIDE THE MACHINE THAT IS STILL STANDING, not on the spot the round
	# started from: a survivor that has driven off would otherwise get an opponent a hundred metres
	# away, and the camera - which frames the middle of the pair - would show neither of them.
	var other: Variant = _fighters[1 - side] if _fighters.size() == 2 else null
	if is_instance_valid(other):
		var op: Vector3 = (other as Node3D).global_position
		p = Vector3(op.x, 0.0, op.z) + dir * (START_GAP if side == 0 else -START_GAP)
	e.global_position = Vector3(p.x, _ground_y(p) + 6.0, p.z)   # dropped in, like in game
	if e is RigidBody3D:
		(e as RigidBody3D).linear_velocity = Vector3.ZERO
	_fighters[side] = e
	_born[side] = _t
	_armed[side] = false

## Locked on each other and relentless: no searching, no losing interest, no walking away.
func _retarget() -> void:
	for i in _fighters.size():
		var a = _fighters[i]
		var b = _fighters[1 - i]
		if is_instance_valid(a) and is_instance_valid(b) and a.has_method("assign_target"):
			a.assign_target(b, true)

## A machine that is gone, or has been stripped of its last gun, is REPLACED - the round is not cut
## short for it. A fresh machine is left alone for ARM_GRACE while it assembles itself; after that a
## build without a single weapon is a broken one and goes the same way.
func _replace_fallen() -> void:
	var changed: bool = false
	for side in _fighters.size():
		var f = _fighters[side]
		var alive: bool = is_instance_valid(f)
		if alive and _weapon_count(f as Node3D) > 0:
			_armed[side] = true
			continue
		if alive and not _armed[side] and _t - float(_born[side]) < ARM_GRACE:
			continue                      # still putting itself together
		if alive:
			(f as Node).queue_free()
		_spawn_fighter(side)
		changed = true
	if changed:
		_retarget()

func _ground_y(p: Vector3) -> float:
	if _map != null and is_instance_valid(_map) and _map.has_method("terrain_height_at"):
		return float(_map.terrain_height_at(p))
	return 0.0

## Swap the round: EVERYTHING GOES FIRST, AND ONLY THEN DOES THE NEW ROUND ARRIVE. The two halves
## are separated by a frame on purpose - queue_free() only takes effect at the end of the frame, so
## machines spawned in the same breath would be dropped onto the collision of the map that is about
## to disappear, and half of them would fall through the world.
##
## The old map takes its machines, their bullets and their wreckage with it: all of that lives under
## nodes freed here. Removing the map from the tree BEFORE it is freed takes its collision away in
## this frame rather than at the end of it.
func _swap_round() -> void:
	_swapping = true
	# ── Remove ──
	_fighters.clear()
	_born.clear()
	_armed.clear()
	for c in _machines_root.get_children():
		_machines_root.remove_child(c)       # machines, loose blocks and effects left by the fight
		c.queue_free()
	if is_instance_valid(_map):
		# The map may still be computing a window strip in worker threads, and those buffers live in
		# the generator node that is about to be freed with it.
		if _map.has_method("stop_generation"):
			_map.stop_generation()
		remove_child(_map)
		_map.queue_free()
	_map = null
	await get_tree().process_frame           # nothing of the old round is left standing
	# ── Add ──
	_map = _next_map
	_next_map = null
	if is_instance_valid(_map):
		_map.visible = true
		_map.set_collision_streaming(true)
	_spawn_pair()
	_round_t = ROUND_TIME
	_move_camera()
	_swapping = false

# ── Tick ─────────────────────────────────────────────────────────────────────
func _process(delta: float) -> void:
	_t += delta
	# While the round is being swapped the camera holds still: the old map is already gone and the
	# new one is not in place yet, so there is no ground to measure a height against.
	if _swapping:
		return
	_move_camera()
	if _map == null:
		return
	# A map is ready and waiting - reset the round now.
	if _next_map != null:
		_swap_round()
		return
	_round_t -= delta
	# Time is up: start the next map. Guarded inside - the fight goes on for as long as the
	# generation takes, and _round_t keeps ticking past zero without starting a second run.
	if _round_t <= 0.0:
		_prepare_next()
	# The fight is kept alive the whole time, generation or not: a machine that died or lost its guns
	# is replaced where it stood.
	_replace_fallen()

func _weapon_count(m: Node3D) -> int:
	var blocks := m.get_node_or_null("blocks")
	if blocks == null:
		return 0
	var n: int = 0
	for b in blocks.get_children():
		if b is WeaponBlock:
			n += 1
	return n

## The camera watches the middle of the fight from above and orbits slowly.
##
## Height is counted FROM THE GROUND under that middle, not from the machines: hills here reach
## tens of metres, and a fixed altitude put the camera inside a slope - the menu opened on a black
## screen. Before the first machines exist the middle is the map centre, so the ground is still
## what the height is measured against.
func _move_camera() -> void:
	var mid := Vector3.ZERO
	var live: int = 0
	for f in _fighters:
		if is_instance_valid(f):
			mid += (f as Node3D).global_position
			live += 1
	if live > 0:
		mid /= float(live)
	# No map yet (the first one is still generating): sit above everything the generator can build,
	# so the ground appears in frame the moment it exists instead of somewhere behind the camera.
	var gy: float = _ground_y(mid) if _map != null and is_instance_valid(_map) else 100.0
	var a: float = _t * CAM_ORBIT
	var eye := Vector3(mid.x + cos(a) * CAM_DIST, gy + CAM_HEIGHT, mid.z + sin(a) * CAM_DIST)
	# The orbit point may land on a hill higher than the camera itself - then the eye goes under the
	# ground and the screen fills with the inside of a slope. Keep it above whatever is under it.
	eye.y = maxf(eye.y, _ground_y(eye) + CAM_CLEARANCE)
	_cam.position = eye
	_cam.look_at(Vector3(mid.x, gy + 2.0, mid.z), Vector3.UP)
