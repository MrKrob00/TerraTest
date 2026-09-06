extends Node3D
## Menu backdrop: a REAL fight on a REAL map.
##
## Nothing here is faked any more. The ground is a LiteTerrain map with streamed collision, the
## machines are the game's enemy scenes with their own physics, AI, weapons and wreckage - two of
## them, of DIFFERENT factions, so they treat each other as enemies exactly the way the game
## decides that (enemy_vehicle._is_enemy compares faction).
##
## A round lasts ROUND_TIME. The NEXT map is generated in the background while the current fight
## runs, and the swap happens only once it is ready: old map, machines and everything they spawned
## go away, the new map takes their place and a new pair of builds starts over. Generation is also
## kicked off early if one side has already lost all its weapons - there is nothing left to watch.
##
## The demo machines carry `demo = true`: no rewards, no quest progress on death, and no way out of
## the fight (see enemy_vehicle). A backdrop where both sides drive apart shows nothing.
##
## The map is 512 cells: big enough for a fight, small enough to generate in a couple of seconds
## while the previous one is still on screen.

const ENEMY_SCENE := preload("res://enemy.tscn")
const MAP_SCRIPT := preload("res://addons/LiteTerrain/map.gd")

const MAP_SIZE := 512
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
	await _open_round()
	set_process(true)

# ── Rounds ───────────────────────────────────────────────────────────────────
## Build a map, wait for its terrain, put two machines on it and start the next map at once.
func _open_round() -> void:
	_map = await _make_map()
	if _map == null:
		return
	_map.set_collision_streaming(true)
	_spawn_pair()
	_round_t = ROUND_TIME
	_prepare_next()

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
	# Polled rather than awaiting terrain_ready: a generation that never finishes (empty heights,
	# a freed node) would leave this coroutine hanging forever, and with it the whole round loop.
	var guard: int = 0
	while is_instance_valid(m) and not m.terrain_is_ready and guard < 3600:
		await get_tree().process_frame
		guard += 1
	if not (is_instance_valid(m) and m.terrain_is_ready):
		return null
	return m

## Generation of the NEXT map runs while the current fight is on screen: it takes seconds, and
## doing it at the moment of the swap would freeze the menu on a still picture.
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
	_swapping = false
	_prepare_next()

# ── Tick ─────────────────────────────────────────────────────────────────────
func _process(delta: float) -> void:
	_t += delta
	_move_camera()
	if _swapping or _map == null:
		return
	_round_t -= delta
	# Nothing left to watch: one side has no weapons or is already gone. Start the next map early
	# if it is not on its way yet, and cut the round short once it is ready.
	if _fight_over():
		_round_t = minf(_round_t, 2.0)
		_prepare_next()
	if _round_t <= 0.0 and _next_ready:
		_swap_round()

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

## The camera watches the middle of the fight from above and orbits slowly. Height is fixed: the
## machines drive, and a camera that also chased them would turn the backdrop into a shaky cam.
func _move_camera() -> void:
	var mid := Vector3.ZERO
	var live: int = 0
	for f in _fighters:
		if is_instance_valid(f):
			mid += (f as Node3D).global_position
			live += 1
	if live > 0:
		mid /= float(live)
	var a: float = _t * CAM_ORBIT
	_cam.position = Vector3(mid.x + cos(a) * CAM_DIST, mid.y + CAM_HEIGHT, mid.z + sin(a) * CAM_DIST)
	_cam.look_at(mid + Vector3.UP * 1.5, Vector3.UP)
