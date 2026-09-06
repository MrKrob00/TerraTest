extends Node3D
## Menu backdrop: a REAL fight on a REAL map.
##
## Nothing here is faked any more. The ground is a LiteTerrain map with streamed collision, the
## machines are the game's enemy scenes with their own physics, AI, weapons and wreckage - two of
## them, of DIFFERENT factions, so they treat each other as enemies exactly the way the game
## decides that (enemy_vehicle._is_enemy compares faction).
##
## A round runs ROUND_TIME, and only THEN does the next map start generating - the fight keeps
## going while it does. When generation finishes the round resets: old map, machines and everything
## they spawned go away, the new map takes their place and a new pair of builds starts over.
## Generation also starts early when one side has lost all its weapons: there is nothing left to
## watch. Only ever one generation at a time (_gen_busy), or a second round would queue up behind
## the first and the swap would happen twice.
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
var _next_ready: bool = false
var _gen_busy: bool = false
var _fighters: Array = []
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
	_next_ready = false
	var m: Node3D = await _make_map()
	_gen_busy = false
	if m == null:
		return
	m.visible = false
	_next_map = m
	_next_ready = true

func _spawn_pair() -> void:
	var picks: Array = PRESETS.duplicate()
	picks.shuffle()
	var ang: float = _rng.randf() * TAU
	for side in 2:
		var e: Node3D = ENEMY_SCENE.instantiate()
		# The build is set BEFORE add_child: blocks assembles the machine in its own _ready.
		var blocks := e.get_node_or_null("blocks")
		if blocks != null and "layout_preset" in blocks:
			blocks.layout_preset = int(picks[side])
		# DIFFERENT factions, otherwise they do not see each other as enemies at all. Neither is 0,
		# so neither of them counts as the player's.
		e.set("faction", 1 + side)
		e.set("demo", true)
		_machines_root.add_child(e)
		var dir := Vector3(cos(ang), 0.0, sin(ang)) * (START_GAP * 0.5)
		var p: Vector3 = dir if side == 0 else -dir
		e.global_position = Vector3(p.x, _ground_y(p) + 6.0, p.z)   # dropped in, like in game
		if e is RigidBody3D:
			(e as RigidBody3D).linear_velocity = Vector3.ZERO
		_fighters.append(e)
	# Locked on each other and relentless: no searching, no losing interest, no walking away.
	for i in _fighters.size():
		var a: Node3D = _fighters[i]
		var b: Node3D = _fighters[1 - i]
		if is_instance_valid(a) and a.has_method("assign_target"):
			a.assign_target(b, true)

func _ground_y(p: Vector3) -> float:
	if _map != null and is_instance_valid(_map) and _map.has_method("terrain_height_at"):
		return float(_map.terrain_height_at(p))
	return 0.0

## Swap the round: the old map takes its machines, their bullets and their wreckage with it - all of
## that lives under nodes we free here.
func _swap_round() -> void:
	_swapping = true
	for f in _fighters:
		if is_instance_valid(f):
			(f as Node).queue_free()
	_fighters.clear()
	for c in _machines_root.get_children():
		c.queue_free()                       # loose blocks and effects left by the fight
	if is_instance_valid(_map):
		_map.queue_free()
	_map = _next_map
	_next_map = null
	_next_ready = false
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
	_move_camera()
	if _swapping or _map == null:
		return
	# A map is ready and waiting - reset the round now.
	if _next_map != null:
		_swap_round()
		return
	# Generation is running: the fight carries on until it lands. No second run is started.
	if _gen_busy:
		return
	_round_t -= delta
	# Time is up, or one side has no weapons left and there is nothing left to watch.
	if _round_t <= 0.0 or _fight_over():
		_prepare_next()

## Is the fight decided? Either machine dead, or one of them with no weapon blocks left.
func _fight_over() -> bool:
	for f in _fighters:
		if not is_instance_valid(f):
			return true
		if _weapon_count(f as Node3D) == 0:
			return true
	return _fighters.is_empty()

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
