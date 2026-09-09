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
##
## Until a map is up the stage is hidden behind `%Backdrop` - the menu's own loading screen, which
## covers the 3D and NOT the interface: PLAY, the slots and the settings work while the ground is
## still being computed. The same backdrop covers the swap between rounds, and stays up for good
## when the fight is switched off in the settings (`G.menu_battles`).

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
## How long the backdrop takes to cover the stage before a round is swapped. Long enough to read as
## a fade, short enough that nobody waits for it.
const SWAP_FADE := 0.4

## Camera: an orbit around the middle of the fight, high enough to see both machines and the ground
## between them.
const CAM_HEIGHT := 26.0
const CAM_DIST := 34.0
const CAM_ORBIT := 0.06          # rad/s
## Never closer than this to whatever is directly under the camera.
const CAM_CLEARANCE := 8.0

## SEEDS ARE AUDITIONED, NOT TAKEN AS THEY COME. The landform knobs are the dock's Natural preset,
## but the preset says nothing about WHERE the map lands: the biome regions are hundreds of metres
## across, and a 256 m window dropped at random sits inside one of them - a plain desert, or the
## fringe of a canyon where the mask is a tenth and the carve comes out as scratches a couple of
## metres deep. That is not the preset being different, it is the window missing the landscape.
##
## So a handful of seeds are scored on their biome masks (pure maths, no terrain) and the best one
## is generated. What "best" means is in _score_seed.
const SEED_TRIES := 12
## Metres between score samples. The masks are hundreds of metres wide; sampling finer only costs
## time, and this runs while the backdrop is up.
const SCORE_STEP := 24.0
## The fight happens within this radius of the origin - it must be drivable ground, not a gorge.
const CLEAR_RADIUS := 48.0
## Wanted share of the window: canyon country over meadow (the ground there is high enough for a
## carve to have somewhere to go), and mountains for a skyline.
const WANT_CANYON := 0.22
const WANT_MOUNTAIN := 0.20

var _rng := RandomNumberGenerator.new()
var _t: float = 0.0
var _round_t: float = 0.0
@onready var _cam: Camera3D = %MenuCamera
@onready var _machines_root: Node3D = %Machines
@onready var _backdrop: Control = %Backdrop

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
## The fight is off in the settings: no map, no machines, the backdrop is the menu.
var _off: bool = false
## Biomes for generated maps: the authored map's, so the regions the menu generates are the regions
## the map in the scene was made with. Duplicated per map - the generator writes the seed's mask
## offset into it.
var _biomes: TerrainBiomes = null
## The map authored in the scene, kept for what it can tell about the world it was baked from: its
## biomes and the Height it was generated with.
var _scene_map: Node3D = null

func _ready() -> void:
	_rng.randomize()
	_scene_map = get_node_or_null("LiteTerrain") as Node3D
	var bio: Variant = _scene_map.get("biomes") if _scene_map != null else null
	if bio is TerrainBiomes:
		_biomes = bio
	set_process(true)       # the camera works while the first map is still being generated
	_off = G.menu_battles != true
	if _off:
		_backdrop.set_idle(true)
		_shutdown()
		return
	_backdrop.cover(true)
	await _open_round()

## The settings switch. Turning it off clears the stage in the same frame; turning it on opens a
## round from scratch, backdrop and all, exactly as if the menu had just been entered.
func set_battles(on: bool) -> void:
	if on != _off:
		return          # already in that state
	_off = not on
	if _off:
		_backdrop.set_idle(true)
		_shutdown()
		return
	_backdrop.set_idle(false)
	_backdrop.cover(true)
	await _open_round()

## Take the stage down: everything the fight owns goes, including the map authored in the scene.
## Keeping it would mean paying for terrain streaming behind an opaque backdrop.
func _shutdown() -> void:
	for c in _machines_root.get_children():
		_machines_root.remove_child(c)
		c.queue_free()
	_fighters.clear()
	_born.clear()
	_armed.clear()
	for m in [_map, _next_map]:
		if is_instance_valid(m):
			if m.has_method("stop_generation"):
				m.stop_generation()
			remove_child(m)
			m.queue_free()
	_map = null
	_next_map = null

# ── Rounds ───────────────────────────────────────────────────────────────────
## Open the first round on the scene map; if it is gone (someone deleted the node), generate one.
func _open_round() -> void:
	_map = get_node_or_null("LiteTerrain") as Node3D
	if _map != null:
		# The scene map loads its own baked heightmap and sets up its own collision in _ready.
		_backdrop.set_progress("reading terrain", -1.0)
		if not await _wait_terrain(_map, true):
			_map = null
	if _map == null:
		_map = await _make_map(true)
		if _map == null or _off:
			return
		_map.set_collision_streaming(true)
	_spawn_pair()
	_round_t = ROUND_TIME
	_move_camera()          # first frame already looks at the fight, not at the origin
	_backdrop.reveal()

## A map generated from its own seed. `force_procedural` keeps it away from G: the slot's seed
## belongs to the save, this one is scenery.
func _make_map(report: bool = false) -> Node3D:
	# The biomes are the AUTHORED map's, copied: the regions, their scales and the terrace height all
	# live in that resource, and a fresh default one would generate a different country under the
	# same preset. The copy is per map because the generator writes the seed's mask offset into it.
	var b: TerrainBiomes = (_biomes.duplicate() as TerrainBiomes) if _biomes != null \
			else TerrainBiomes.new()
	var m := StaticBody3D.new()
	m.set_script(MAP_SCRIPT)
	m.force_procedural = true
	m.forced_seed = _pick_seed(b)
	m.window_size = MAP_SIZE
	m.use_image_data = false
	m.biomes = b
	# THE SAME PRESET THE EDITOR BUTTON USES. The procedural defaults are a compromise for the game's
	# own world; the menu wants the land the dock's "Natural preset" makes - big masses, drivable
	# slopes - and the numbers for it live in the generator, not here.
	var np := LiteTerrainGen.natural_params(b)
	# HEIGHT COMES FROM THE MAP IN THE SCENE, not from the preset. The preset is a starting point
	# someone then moves: bake the menu map at Height 240 and generate the rounds at the preset's
	# 130, and the generated ones stand next to it visibly flatter - canyons half as deep, mountains
	# half as tall. The authored map records what built it (map.built_amplitude, written by the
	# dock); everything else stays the preset.
	if is_instance_valid(_scene_map) and _scene_map.has_method("world_height"):
		var authored: float = float(_scene_map.world_height())
		if authored > 0.0:
			np["amplitude"] = authored
	m.proc_scale = float(np["scale"])
	m.proc_power = float(np["power"])
	m.proc_amplitude = float(np["amplitude"])
	m.proc_mountains01 = float(np["mountains"])
	# Collision OFF from the start: while this map builds its chunks it stands at the same origin as
	# the one on screen, and two heightfields under the same machines fight each other. It is turned
	# on in the frame this map becomes the visible one.
	m.start_without_collision = true
	add_child(m)
	if not await _wait_terrain(m, report):
		if is_instance_valid(m):
			m.queue_free()
		return null
	return m

## The seed whose window shows the most landscape. Scoring reads the biome masks only - no heights,
## no threads - so auditing a dozen of them costs a few milliseconds, once per round.
func _pick_seed(b: TerrainBiomes) -> int:
	var best: int = 0
	var best_score: float = -1.0
	for i in SEED_TRIES:
		var s: int = _rng.randi() | 1
		b.mask_offset = TerrainBiomes.offset_for_seed(s)
		var sc: float = _score_seed(b)
		if sc > best_score:
			best_score = sc
			best = s
	return best

## What makes a menu map worth looking at:
##
## - CANYON COUNTRY OVER MEADOW. The carve is measured down from the local ground and stops at a
##   floor, so in the desert - which the preset flattens - there is barely anything above that floor
##   to cut into, and the result is the scratch the eye reads as "no canyons". Over meadow the same
##   region cuts real walls. So canyon mask alone is not the score; canyon over meadow is.
## - SOME MOUNTAIN for a skyline, but not a window full of it.
## - A CLEAR MIDDLE. The machines are dropped at the origin and have to drive; a gorge or a peak
##   there is a fight nobody can see.
func _score_seed(b: TerrainBiomes) -> float:
	var half: float = float(MAP_SIZE) * 0.5
	# One Callable for the whole sweep: building it per sample allocates thousands of them.
	var nz: Callable = b.noise
	var canyon: float = 0.0
	var mountain: float = 0.0
	var blocked: float = 0.0
	var n: int = 0
	var x: float = -half
	while x < half:
		var z: float = -half
		while z < half:
			var wp := Vector2(x, z)
			var c: float = b.canyon_mask(wp, nz)
			var mt: float = b.mountain_mask(wp, nz)
			canyon += c * b.meadow_mask(wp, nz)
			mountain += mt
			if wp.length_squared() <= CLEAR_RADIUS * CLEAR_RADIUS:
				blocked = maxf(blocked, maxf(c, mt))
			n += 1
			z += SCORE_STEP
		x += SCORE_STEP
	if n == 0:
		return 0.0
	var cs: float = _near(canyon / float(n), WANT_CANYON)
	var ms: float = _near(mountain / float(n), WANT_MOUNTAIN)
	return cs + ms * 0.7 + (1.0 - blocked) * 1.5

## 1 at the wanted share, falling to 0 at zero and at twice it. A plain distance would rank an empty
## window the same as one covered edge to edge.
func _near(v: float, want: float) -> float:
	return clampf(1.0 - absf(v - want) / maxf(want, 0.001), 0.0, 1.0)

## Wait until a map has its terrain up. Polled rather than awaiting terrain_ready: a map that never
## finishes (empty heights, a freed node) would leave this coroutine hanging forever, and with it
## the whole round loop.
##
## `report` sends what the map is doing to the backdrop. Only the map the player is WAITING for
## reports: the one generated in the background is not worth a progress bar, the fight is on screen.
func _wait_terrain(m: Node3D, report: bool = false) -> bool:
	var guard: int = 0
	while is_instance_valid(m) and not m.terrain_is_ready and guard < 3600:
		if report:
			# Asked through `get`, and every answer checked: a map node without these fields (an
			# older addon, someone else's terrain) must leave the readout running, not crash it.
			var sv: Variant = m.get("gen_step")
			var fv: Variant = m.get("gen_frac")
			var step: String = String(sv) if sv is String else ""
			# An empty step means the map is not computing anything (it is reading a baked file):
			# there is no fraction to show, and the meter runs instead of filling.
			var frac: float = float(fv) if (step != "" and fv is float) else -1.0
			_backdrop.set_progress(step if step != "" else "reading terrain", frac)
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
	if _off:
		# The fight was switched off while this was building. It has nothing to appear on.
		if m.has_method("stop_generation"):
			m.stop_generation()
		remove_child(m)
		m.queue_free()
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
	# The backdrop comes down over the swap. Without it the round ends on a hard cut from one
	# landscape to another, and the new one is still popping its chunks in as it appears.
	_backdrop.cover(false)
	await get_tree().create_timer(SWAP_FADE).timeout
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
	_backdrop.reveal()
	_swapping = false

# ── Tick ─────────────────────────────────────────────────────────────────────
func _process(delta: float) -> void:
	_t += delta
	# While the round is being swapped the camera holds still: the old map is already gone and the
	# new one is not in place yet, so there is no ground to measure a height against.
	if _swapping or _off:
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
