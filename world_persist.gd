extends Node
# Player WORLD persistence (not to be confused with G, which holds progress: money, research):
#  - New game: the player has ONE cabin with the starter kit dropping nearby, no other machines.
#  - Any loose block in the world disappears after BLOCK_TTL (10 min).
#  - Every AUTOSAVE_EVERY (5 min): all player machines, world blocks and their positions.
#  - ENEMIES are not saved (faction 0 only).
# Any load error falls back to a new game, so a broken save cannot break the game.

## File names, not paths: the world belongs to the SLOT and the prefix comes from G.slot_path.
## There must be no second copy of that prefix in the project.
const SAVE_FILE := "world_save.json"
const BAD_SAVE_FILE := "world_save.bad.json"          # a save that failed to load is moved here
const SAFE_CLEARANCE := 2.0         # lift above terrain when restoring
# The terrain is a heightmap with nothing under the surface, so a body that falls through drops
# hundreds of metres. The threshold is generous: terrain_height_at samples at the body's XZ, and at
# the foot of a cliff that is noticeably higher than where the body legitimately stands - too
# sensitive a threshold would start teleporting machines on flat ground. 60 m was too coarse (a
# machine stuck inside a hill went unnoticed); 15 catches both that and a real fall.
const FALL_LIMIT := 15.0
const BLOCK_TTL := 600.0            # 10 min: how long a loose block lives in the world
const AUTOSAVE_EVERY := 60.0        # 1 min: autosave period (machines, world blocks, positions)

var _tick: float = 0.0

func _ready() -> void:
	# The group is how "exit to menu" (tech_ui) finds us: this node lives in the scene, not as an
	# autoload, and there must be no path to it in code - the scene has been rearranged more than once.
	add_to_group("world_persist")
	# WAIT until the machine is actually built. Two frames are not enough: blocks.spawn_block does
	# `await get_parent().ready` inside, so starter blocks arrive LATE. Applying the saved build at that
	# moment lets apply_layout clear node_map while the catching-up coroutines then write colliders and
	# positions to freed nodes - the saved build was overwritten by the starter one (and could crash).
	# So: wait for the machine to be ready plus a couple of frames for the coroutines.
	var guard := 0
	while guard < 600:
		var v = _primary_machine()
		if v != null and v.is_node_ready() and v.get("block_map_node") != null:
			break
		await get_tree().process_frame
		guard += 1
	await get_tree().process_frame
	await get_tree().process_frame
	_purge_extra_machines()                        # keep the primary player machine only
	if FileAccess.file_exists(G.slot_path(SAVE_FILE)):
		await _load_world()        # it awaits inside (unfreeze after teleport), so wait for it
	else:
		_fresh_start()
	var t := Timer.new()
	t.wait_time = AUTOSAVE_EVERY
	t.autostart = true
	t.one_shot = false
	t.timeout.connect(_save_world)
	add_child(t)

func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_APPLICATION_PAUSED \
			or what == NOTIFICATION_WM_GO_BACK_REQUEST:
		_save_world()

func _process(delta: float) -> void:
	var _pf := Perf.now()                          # profiler mark (perf.gd)
	_vehicle_render_tick()                         # machines out of frame are not drawn (EVERY frame)
	_cull_tick(delta)                              # disable what is behind you (its own, more frequent period)
	_tick += delta
	if _tick < 1.0:
		Perf.mark("world", _pf)
		return
	_tick = 0.0
	_expire_world_blocks()                         # despawn loose blocks older than the TTL
	_rescue_fallen()                               # машина провалилась сквозь рельеф — вернуть наверх
	Perf.mark("world", _pf)

# ── Culling what is BEHIND YOU ───────────────────────────────────────────────
# A loose block in the world is not only a mesh (the engine already skips drawing it behind the
# camera) but a LIVE SCRIPT: a collector lying on the ground still iterates resources around it, a
# belt still moves items, a charger walks every machine twice a second. Fifty such blocks behind
# you cost exactly as much as fifty in front, and give nothing.
#
# Only SLEEPING bodies are disabled: physics is not running for them anyway, so stopping the script
# is safe. A flying or rolling block is never touched, or it would freeze in mid-air and jerk down
# when the player turns around.
#
# The near bubble stays active in every direction: what is close takes part in the game (packer
# magnet, receiver, picking up by hand) and must not be gated by view direction.
const CULL_PERIOD := 0.25
const CULL_KEEP_RADIUS := 25.0       # м: ближе этого блок активен, куда бы ни смотрела камера
const CULL_VIEW_COS := -0.15         # чуть шире полусферы перед камерой — край не мигает
const CULL_META := "culled"
var _cull_t: float = 0.0

func _cull_tick(delta: float) -> void:
	_cull_t -= delta
	if _cull_t > 0.0:
		return
	_cull_t = CULL_PERIOD
	var o := _objects()
	if o == null:
		return
	var cam := get_viewport().get_camera_3d() if get_viewport() != null else null
	if cam == null:
		return
	var cam_pos: Vector3 = cam.global_position
	var fwd: Vector3 = -cam.global_transform.basis.z
	var keep2: float = CULL_KEEP_RADIUS * CULL_KEEP_RADIUS
	# Behind a ridge is the same as behind you. The terrain answers from its own heightmap
	# (map.is_point_hidden), and that is cheap.
	var terr := get_node_or_null("/root/Main/map")
	var can_occlude: bool = terr != null and terr.has_method("is_point_hidden")
	var frustum: Array[Plane] = cam.get_frustum()
	_shadow_tick(cam_pos)
	for c in o.get_children():
		var n := c as Node3D
		if n == null:
			continue
		_settle_tick(n)
		# DRAWING AND SCRIPT ARE DECIDED SEPARATELY, and that is not pedantry.
		#
		# There is nothing to draw off-frame at all, so the exact frustum test fits - the same one machines
		# use. The SCRIPT must not follow it: a collector lying at the base thirty metres to the side fails
		# the frustum, and the factory would stall every time the player turned the camera. The script keeps
		# the old, much softer rule - strictly behind you or behind a ridge.
		n.visible = _in_frustum(frustum, n.global_position, ITEM_CULL_RADIUS)
		var was: bool = n.has_meta(CULL_META)
		var to: Vector3 = n.global_position - cam_pos
		var d2: float = to.length_squared()
		# The near bubble surrounds ANY live point (G.active_points), not just the camera: blocks lying
		# next to another of the player's machines take part in the game (packer magnet, receiver), and
		# disabling them because the camera looks elsewhere would stop the factory at a base.
		var kept: bool = d2 <= keep2 or G.near_active(n.global_position, CULL_KEEP_RADIUS)
		var behind: bool = not kept and to.normalized().dot(fwd) < CULL_VIEW_COS
		if not behind and not kept and can_occlude:
			behind = terr.is_point_hidden(n.global_position, 1.0, was)
		if behind == was:
			continue
		if behind:
			var rb := n as RigidBody3D
			if rb != null and not rb.sleeping and not rb.freeze:
				continue                    # ещё едет/падает — досчитаем, погасим в следующий раз
			n.set_meta(CULL_META, true)
			n.process_mode = Node.PROCESS_MODE_DISABLED
		else:
			n.remove_meta(CULL_META)
			n.process_mode = Node.PROCESS_MODE_INHERIT

# ── SETTLED MEANS ASLEEP ─────────────────────────────────────────────────────
# Every non-sleeping RigidBody3D asks the terrain for its own streamed collision window
# (map._update_collision_cells), and this game scatters dozens of loose blocks and ore pieces on the
# ground. Godot sleeps bodies itself, but a block resting on a streamed heightfield can jitter at
# the sleep threshold forever: micro-velocity keeps it awake, awake keeps the window, the window
# keeps the ground, the ground keeps the jitter. The loop closes and the block NEVER sleeps.
#
# So we sleep it ourselves: slower than SETTLE_SPEED for longer than SETTLE_TIME sets sleeping.
# Physics does the rest - a contact, a blast impulse or a passing machine wakes it, and the window
# comes back the same frame.
#
# sleeping, NOT freeze. A frozen body means "not lying in the world" for this game: G.is_loose_item
# tells lying from held by exactly that flag, so a frozen block would stop being picked up by hand,
# collector and receiver. Blast impulses are not applied to frozen bodies at all
# (block_fx.explosion), so blocks would stop scattering.
const SETTLE_SPEED := 0.35        # м/с — медленнее считаем, что тело уже легло
const SETTLE_TIME := 3.5          # столько секунд подряд, чтобы не усыпить подброшенное в апогее
const SETTLE_META := "settled_s"

func _settle_tick(n: Node3D) -> void:
	var rb := n as RigidBody3D
	if rb == null or rb.freeze or rb.sleeping:
		return
	var v2: float = rb.linear_velocity.length_squared() + rb.angular_velocity.length_squared()
	if v2 > SETTLE_SPEED * SETTLE_SPEED:
		rb.remove_meta(SETTLE_META)
		return
	var t: float = float(rb.get_meta(SETTLE_META, 0.0)) + CULL_PERIOD
	if t < SETTLE_TIME:
		rb.set_meta(SETTLE_META, t)
		return
	rb.remove_meta(SETTLE_META)
	rb.sleeping = true

## Sphere radius around a loose item for the frustum test. A block is a one-metre cube and ore is
## smaller; 1.5 m gives enough margin that an item on the very screen edge does not flicker.
const ITEM_CULL_RADIUS := 1.5

## SHADOWS FROM YOUR OWN MACHINES ONLY UP CLOSE. A machine has 30-40 separate blocks and each
## shadow caster is drawn a SECOND time into the shadow map. A base across the field casts a few
## pixels and costs as much as the machine under your nose. enemy_spawner does the same for enemies;
## here it is the player's machines, which it does not see.
##
## Toggled ON STATE CHANGE only: walking the blocks is not free and distance changes smoothly.
const SHADOW_DIST := 90.0

# ── A MACHINE OUT OF FRAME IS NOT DRAWN ──────────────────────────────────────
# The engine culls each MeshInstance3D itself, but it still costs: a machine has 30-40 instances,
# each with its own AABB, all tested every frame - and there can be a dozen machines around. One
# test for the whole machine plus disabling the branch is cheaper than forty for its blocks.
#
# ONLY DRAWING IS DISABLED. process_mode is never touched: an enemy behind you must keep driving,
# shooting and counting energy - that is decided by its sleep (enemy_spawner), not by the camera.
# visible does not affect physics; collision has its own disabled flag.
#
# The check runs EVERY FRAME rather than on the cleanup timer: a machine must appear the same frame
# the camera turns to it. There are only a few machines and the test is six dot products.
const VEH_CULL_RADIUS := 9.0     # сфера вокруг машины: 11³ клеток по диагонали с запасом
## Box height for the occlusion query. The sphere radius does not fit here: is_point_hidden builds a
## 1 x height x 1 column, and a nine-metre column would stick out above any hill, so "behind a ridge"
## would never happen. Four metres is a machine with a turret plus margin.
const VEH_OCCL_HEIGHT := 4.0

func _vehicle_render_tick() -> void:
	var vehicles := get_node_or_null("/root/Main/Vehicles")
	if vehicles == null:
		return
	var cam := get_viewport().get_camera_3d() if get_viewport() != null else null
	if cam == null:
		return
	var frustum: Array[Plane] = cam.get_frustum()
	var active: Node = _primary_machine()
	var terr := _terrain()
	var can_occlude: bool = terr != null and terr.has_method("is_point_hidden")
	for v in vehicles.get_children():
		if not (v is Node3D):
			continue
		var n := v as Node3D
		# NEVER hide your own active machine. The camera hangs on it and looks at it, so it passes the test
		# anyway - but the cost of an error is asymmetric: one extra drawn frame is invisible, a machine
		# vanishing under the player looks like a broken game.
		if n == active:
			_set_vehicle_visible(n, true)
			continue
		var pos: Vector3 = n.global_position
		var shown: bool = _in_frustum(frustum, pos, VEH_CULL_RADIUS)
		if shown and can_occlude:
			# Behind a ridge is the same as behind you. The hysteresis inside is_point_hidden uses the previous
			# state so a machine on the very edge of a hill does not flicker.
			shown = not terr.is_point_hidden(pos, VEH_OCCL_HEIGHT, not n.visible)
		_set_vehicle_visible(n, shown)

func _set_vehicle_visible(n: Node3D, on: bool) -> void:
	if n.visible != on:
		n.visible = on

## Does the sphere (centre, radius) intersect the view frustum? Planes come from
## Camera3D.get_frustum in WORLD space and face inward, so "outside" means distance_to greater than
## the radius for at least one. Early exit: usually the first plane answers.
func _in_frustum(frustum: Array[Plane], center: Vector3, radius: float) -> bool:
	for pl in frustum:
		if pl.distance_to(center) > radius:
			return false
	return true

func _shadow_tick(cam_pos: Vector3) -> void:
	var vehicles := get_node_or_null("/root/Main/Vehicles")
	if vehicles == null:
		return
	var far2: float = SHADOW_DIST * SHADOW_DIST
	for v in vehicles.get_children():
		if not (v is Node3D):
			continue
		var want: bool = (v as Node3D).global_position.distance_squared_to(cam_pos) < far2
		if bool(v.get_meta("shadows_on", true)) == want:
			continue
		v.set_meta("shadows_on", want)
		_set_shadows(v, want)

func _set_shadows(n: Node, on: bool) -> void:
	var gi := n as GeometryInstance3D
	if gi != null:
		gi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if on \
				else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	for c in n.get_children():
		_set_shadows(c, on)

# Cached terrain node (the one with terrain_height_at).
var _terrain_node: Node = null
var _warned_no_terrain: bool = false

func _terrain() -> Node:
	if _terrain_node != null and is_instance_valid(_terrain_node):
		return _terrain_node
	var scn := get_tree().current_scene
	if scn == null:
		return null
	for c in scn.get_children():
		if c.has_method("terrain_height_at"):
			_terrain_node = c
			return c
	return null

# Terrain that has ALREADY loaded its heights. Until the map reads the heightmap get_dims() is zero
# and terrain_height_at returns a meaningless zero - and lifting "above terrain" by that zero puts
# the machine inside a hill. That is exactly how positions ended up under the map.
const TERRAIN_WAIT_FRAMES: int = 120

func _await_terrain(max_frames: int) -> Node:
	var terr := _ready_terrain()
	var guard: int = 0
	while terr == null and guard < max_frames:
		await get_tree().process_frame
		guard += 1
		terr = _ready_terrain()
	return terr

func _ready_terrain() -> Node:
	var terr := _terrain()
	if terr == null or not terr.has_method("get_dims"):
		return null
	return terr if terr.get_dims().x > 0 else null

# SAFETY NET: a machine noticeably BELOW the terrain has fallen through it (terrain collision is
# streamed and may not exist yet under a body that was just teleported). Without this the machine
# fell forever and the camera followed it kilometres down into an empty screen.
## Absolute world floor: below it a body is falling through nothing, and no terrain is needed for
## that conclusion. The fallback must not depend on the map being ready, or it silently switches
## off exactly when it is needed most.
const WORLD_FLOOR := -300.0

func _rescue_fallen() -> void:
	# Note _terrain(), not _ready_terrain(): gating on readiness disabled the safety net without a word
	# in the log, and a fallen machine dropped forever.
	var terr := _terrain()
	var ready_terr := _ready_terrain()
	if terr == null and not _warned_no_terrain:
		_warned_no_terrain = true
		push_warning("world_persist: no terrain node - the safety net works off the absolute "
				+ "floor %.0f only" % WORLD_FLOOR)
	var lifted: Array[RigidBody3D] = []
	for n in _fall_candidates():
		var n3 := n as Node3D
		if n3 == null or not is_instance_valid(n3):
			continue
		# Ground is known only once the map has read its heights; otherwise judge by the world floor.
		var ground: float = ready_terr.terrain_height_at(n3.global_position) if ready_terr != null else 0.0
		var fell: bool = (ready_terr != null and n3.global_position.y < ground - FALL_LIMIT) \
				or n3.global_position.y < WORLD_FLOOR
		if not fell:
			continue
		var diag: String = ""
		if terr != null and terr.has_method("collision_debug_at"):
			diag = " | " + str(terr.call("collision_debug_at", n3.global_position))
		push_warning("world_persist: %s провалился под рельеф (y=%.1f, земля %.1f)%s"
				% [n3.name, n3.global_position.y, ground, diag])
		var rb := n3 as RigidBody3D
		if rb != null and not rb.freeze:
			rb.freeze = true                    # замороженным (база на якоре) не мешаем
			rb.linear_velocity = Vector3.ZERO
			rb.angular_velocity = Vector3.ZERO
			lifted.append(rb)
		# With no terrain ready, lift higher and let it fall to the ground by itself.
		var lift_y: float = (ground + SAFE_CLEARANCE + 2.0) if ready_terr != null else 200.0
		n3.global_position = Vector3(n3.global_position.x, lift_y, n3.global_position.z)
	if lifted.is_empty():
		return
	# Streamed terrain collision is built AROUND bodies, i.e. only after the body is at its new place.
	# Release after a couple of frames or it falls through again.
	await get_tree().process_frame
	await get_tree().process_frame
	for rb in lifted:
		if is_instance_valid(rb):
			rb.freeze = false

# Everything that can fall through: machines and loose blocks/resources in the world.
func _fall_candidates() -> Array:
	var out: Array = _player_machines().duplicate()
	var o := _objects()
	if o != null:
		out.append_array(o.get_children())
	return out

# ── Scene nodes ─────────────────────────────────────────────────────────────
## Terrain edits to save. They live in the map itself: anyone may level ground (a quest, a future
## building), and keeping the list here would mean asking each of them to report to the save.
func _ground_edits() -> Array:
	var terr := _terrain()
	if terr != null and terr.has_method("ground_edits"):
		return terr.ground_edits()
	return []

func _objects() -> Node:
	return get_node_or_null("/root/Main/objects")

func _vehicles_root() -> Node:
	return get_node_or_null("/root/Main/Vehicles")

func _camera():
	return get_tree().get_first_node_in_group("camera_controller")

func _now() -> float:
	return float(Time.get_ticks_msec()) / 1000.0

# PLAYER machines (faction 0, have block_map_node). Enemies (faction != 0) are excluded.
func _player_machines() -> Array:
	var out: Array = []
	var vr := _vehicles_root()
	if vr == null:
		return out
	for c in vr.get_children():
		if c is RigidBody3D and "block_map_node" in c and c.get("block_map_node") != null \
				and "faction" in c and int(c.get("faction")) == 0:
			out.append(c)
	return out

func _primary_machine():
	var cc = _camera()
	if cc != null and "current_vehicle" in cc and cc.current_vehicle != null:
		return cc.current_vehicle
	var m := _player_machines()
	return m[0] if not m.is_empty() else null

# Remove extra player machines (test scenes have several) and keep the primary one.
func _purge_extra_machines() -> void:
	var primary = _primary_machine()
	var cc = _camera()
	for m in _player_machines():
		if m == primary:
			continue
		if cc != null and "vehicles" in cc:
			cc.vehicles.erase(m)
		m.queue_free()

# ── Loose blocks in the world ───────────────────────────────────────────────
func _is_world_block(n) -> bool:
	return n is RigidBody3D and "block" in n

## A RESOURCE lying in the world (ore, ingot, coal, component, chunk). Same test the pick-up uses
## (vehicle_body_3d): not a block, has a type field and a kind_key().
func _is_world_item(n) -> bool:
	return n is RigidBody3D and not ("block" in n) and ("type" in n) and n.has_method("kind_key")

# ── DISTANCE CLEANUP ─────────────────────────────────────────────────────────
# TTL alone is not enough. The player dismantles a base across the map, drives away, and for ten
# minutes fifty bodies with colliders and scripts live in memory he will never return to. Meanwhile
# the battlefield he is standing on is cleared by the timer right under him.
#
# So distance is measured not from the camera but from the NEAREST PLAYER MACHINE: the camera spins
# around while a base with a conveyor stands still, and everything lying near it must survive until
# its owner comes back. Resources use half the range: there are an order of magnitude more of them
# (a vein ejects ore in batches) and each one is worth little.
const CULL_DIST_BLOCK := 300.0
const CULL_DIST_ITEM := 150.0

func _expire_world_blocks() -> void:
	var o := _objects()
	if o == null:
		return
	var now := _now()
	# Player machine positions are computed ONCE per pass, not per item: there are a few machines and
	# hundreds of items.
	var homes: Array[Vector3] = []
	for m in _player_machines():
		if m is Node3D:
			homes.append((m as Node3D).global_position)
	for c in o.get_children():
		var is_block: bool = _is_world_block(c)
		if not is_block and not _is_world_item(c):
			continue
		# A QUEST ITEM NEVER DISAPPEARS, by timer or by distance. It is tagged (QuestProps.META) and that
		# is what the tag is for: world cleanup knows nothing about quests, ten minutes is an ordinary trip
		# to a target, and that target is often more than three hundred metres away. Cargo melting away en
		# route left the quest without a goal forever.
		if c.has_meta("quest_id"):
			continue
		var limit: float = CULL_DIST_BLOCK if is_block else CULL_DIST_ITEM
		if _too_far(c as Node3D, homes, limit):
			c.queue_free()
			continue
		if not is_block:
			continue                                   # у ресурсов TTL нет — только расстояние
		if not c.has_meta("world_spawn_s"):
			c.set_meta("world_spawn_s", now)           # первый раз увидели — стартуем его таймер
			continue
		if now - float(c.get_meta("world_spawn_s")) > BLOCK_TTL:
			c.queue_free()

## Is the item farther than limit from EVERY player machine? An empty machine list (the player died,
## the scene is still loading) means "we do not know", and then nothing is removed: cleanup out of
## ignorance would eventually wipe the whole field.
func _too_far(n: Node3D, homes: Array[Vector3], limit: float) -> bool:
	if n == null or homes.is_empty():
		return false
	var lim2: float = limit * limit
	for h in homes:
		if h.distance_squared_to(n.global_position) <= lim2:
			return false
	return true

func _spawn_world_block(bt: int, pos: Vector3, rot, age_s: float = 0.0) -> Node:
	var scene: PackedScene = G.get_scene(bt)
	var o := _objects()
	if scene == null or o == null:
		return null
	var b = scene.instantiate()
	o.add_child(b)
	if b is Node3D:
		b.global_position = pos
		if rot != null:
			b.global_rotation = rot
	b.set_meta("world_spawn_s", _now() - age_s)         # остаток жизни = TTL − age
	return b

# ── New game ────────────────────────────────────────────────────────────────
## A new game starts on the FACTORY map. Baked terrain is the pits and pads of a previous
## playthrough. The file is deleted but the heights are already in MEMORY - this session finishes
## on them and the factory map returns on the next launch.
func _fresh_start() -> void:
	var terr := _terrain()
	if terr != null and terr.has_method("reset_heights"):
		terr.reset_heights()
	var o := _objects()
	if o != null:
		for c in o.get_children():
			if _is_world_block(c):
				c.queue_free()                          # убрать предустановленные тест-блоки
	var primary = _primary_machine()
	if primary == null or not primary.has_method("award_block_list"):
		return
	# The starter kit orbits the player and drops into the world (reward_orbiter.gd).
	primary.award_block_list(G.STARTER_KIT)

# ── Save / load ─────────────────────────────────────────────────────────────
func _save_world() -> void:
	var machines: Array = []
	# The machine the player CONTROLS is written FIRST: loading puts machines[0] on it
	# (_load_world -> _restore_machine(primary, ...)), and child order in Vehicles knows nothing about
	# that - a base earlier in the list would arrive under the player's control.
	var ordered: Array = _player_machines()
	var prim = _primary_machine()
	if prim != null and ordered.has(prim):
		ordered.erase(prim)
		ordered.insert(0, prim)
	for m in ordered:
		if m.block_map_node == null or not m.block_map_node.has_method("get_layout"):
			continue
		var gp: Vector3 = (m as Node3D).global_position
		var gr: Vector3 = (m as Node3D).global_rotation
		# A point UNDER the terrain must never reach the save. Otherwise one unlucky autosave locks in
		# forever: every load returns the machine there and the player falls again and again.
		var terr_save := _ready_terrain()
		if terr_save != null:
			gp.y = maxf(gp.y, terr_save.terrain_height_at(gp) + SAFE_CLEARANCE)
		machines.append({
			"layout": m.block_map_node.get_layout(),
			"pos": [gp.x, gp.y, gp.z],
			"rot": [gr.x, gr.y, gr.z],
			# A STATIONARY BASE differs from a machine by a flag, not by layout: it has no cabin and is always
			# anchored. Without it a base came back as an ordinary machine and the cabin watchdog removed it
			# half a second after loading (see _restore_machine). Compared with == true rather than bool():
			# get() returns null on a machine without the field, and bool(null) crashes the call.
			"station": m.get("is_station") == true,
		})
	var blocks: Array = []
	var o := _objects()
	if o != null:
		var now := _now()
		for c in o.get_children():
			if not _is_world_block(c):
				continue
			var age := 0.0
			if c.has_meta("world_spawn_s"):
				age = now - float(c.get_meta("world_spawn_s"))
			var bp: Vector3 = (c as Node3D).global_position
			var br: Vector3 = (c as Node3D).global_rotation
			var entry := {
				"block": G.block_key(int(c.get("block"))),
				"pos": [bp.x, bp.y, bp.z],
				"rot": [br.x, br.y, br.z],
				"age": age,
			}
			# The quest tag is saved WITH the block: without it restored cargo becomes ordinary litter - the
			# cleanup eats it while the quest looks for a target that no longer exists.
			if c.has_meta("quest_id"):
				entry["quest"] = String(c.get_meta("quest_id"))
			blocks.append(entry)
	var f := FileAccess.open(G.slot_path(SAVE_FILE), FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify({
			"version": G.SAVE_FORMAT,
			"machines": machines,
			"world_blocks": blocks,
			# TERRAIN EDITS (levelled pads). The heightmap itself is not written - that is megabytes per save,
			# while an edit is four numbers that reproduce the same ground (map.flatten_area).
			"ground": _ground_edits(),
			# CLEARED FORTIFIED POINTS - indices only (outposts.gd). Coordinates derive from the constant seed
			# and are always the same; writing derivable data into a save eventually gives a save that argues
			# with the code.
			"outposts": _outposts_state(),
		}))
		f.close()

## Fortified point state comes through a group, not a path: the node lives in the world scene, and
## finding it by string would tie the save to the scene layout.
func _outposts_state() -> Array:
	var o: Node = get_tree().get_first_node_in_group("outposts")
	return o.save_state() if (o != null and o.has_method("save_state")) else []

func _load_world() -> void:
	var f := FileAccess.open(G.slot_path(SAVE_FILE), FileAccess.READ)
	if f == null:
		_fresh_start()
		return
	var json := JSON.new()
	var err := json.parse(f.get_as_text())
	f.close()
	if err != OK or typeof(json.get_data()) != TYPE_DICTIONARY:
		_quarantine_save("файл не разобрался как JSON")
		_fresh_start()
		return
	var data: Dictionary = json.get_data()
	var machines: Array = data.get("machines", [])
	var primary = _primary_machine()
	if machines.is_empty() or primary == null or not primary.has_method("apply_build"):
		# The save exists but holds no machine (written before the machine appeared, say). Silently leaving
		# the player with a bare cabin and no blocks is a dead end, so: new game.
		_quarantine_save("в сейве нет машин")
		_fresh_start()
		return
	if not _layout_ok(machines[0].get("layout", [])):
		_quarantine_save("раскладка машины повреждена")
		_fresh_start()
		return
	# TERRAIN FIRST. Levelled pads must be replayed BEFORE machines return: a quest base stands on flat
	# ground, and restored before its edit it would hang in the air (or sink, if the pad was cut down).
	# Wait for the map's heights - zeros cannot level anything.
	var terr0: Node = await _await_terrain(TERRAIN_WAIT_FRAMES)
	if terr0 != null and terr0.has_method("apply_ground_edits"):
		var edits: Array = data.get("ground", [])
		terr0.apply_ground_edits(edits)
		# And BAKE right away. A heightmap dump is the map's full size (15 MB here); mid-game such a write
		# shows as a hitch, while here we are still under the loading screen. After baking the terrain IS
		# that shape and the edits need no replay - the list inside the map is cleared, and any left in the
		# save are cut off by the baked edit number (map.bake_heights).
		if not edits.is_empty() and terr0.has_method("bake_heights"):
			terr0.bake_heights()
	# Cleared points are restored BEFORE machines: a point the player already destroyed must not
	# materialise again while the rest is loading.
	var op: Node = get_tree().get_first_node_in_group("outposts")
	if op != null and op.has_method("load_state"):
		op.load_state(data.get("outposts", []))
	await _restore_machine(primary, machines[0])
	for i in range(1, machines.size()):
		_spawn_machine(machines[i])
	# Remove blocks preset in the scene for testing, or they pile on top of the saved ones.
	var o := _objects()
	if o != null:
		for c in o.get_children():
			if _is_world_block(c):
				c.queue_free()
	for wb in data.get("world_blocks", []):
		var p = wb.get("pos", [0, 0, 0])
		var r = wb.get("rot", [0, 0, 0])
		var b := _spawn_world_block(G.block_from_key(wb.get("block", 0)), Vector3(p[0], p[1], p[2]),
				Vector3(r[0], r[1], r[2]), float(wb.get("age", 0.0)))
		if b != null and String(wb.get("quest", "")) != "":
			b.set_meta("quest_id", String(wb["quest"]))   # снова квестовый, а не мусор

# The layout is validated BEFORE it is applied: one broken entry would silently break the build and
# the player would get an empty machine with no explanation. We require an array of dictionaries
# with coordinates inside the grid and a known block type.
func _layout_ok(layout) -> bool:
	if not (layout is Array) or (layout as Array).is_empty():
		return false
	for e in layout:
		if not (e is Dictionary):
			return false
		if not (e.has("x") and e.has("y") and e.has("z") and e.has("block")):
			return false
		var x := int(e["x"]); var y := int(e["y"]); var z := int(e["z"])
		if x < 0 or x > 10 or y < 0 or y > 10 or z < 0 or z > 10:
			return false                      # координаты вне сетки 11³ — файл от другой версии
		if G.block_from_key(e["block"]) == G.Block.EMPTY:
			return false                      # неизвестный блок (переименовали/удалили тип)
	return true

# A broken save is NOT deleted but moved aside: the game starts fresh and stops getting stuck, and
# the file stays so it can be examined.
func _quarantine_save(reason: String) -> void:
	var bad: String = G.slot_path(BAD_SAVE_FILE)
	push_warning("world_persist: сейв не загружен (%s) → откладываю в %s" % [reason, bad])
	# Open the SLOT FOLDER, not user://: world files live in it, and rename by bare names works only
	# relative to the directory that was opened.
	var d := DirAccess.open(G.slot_dir())
	if d != null:
		if d.file_exists(BAD_SAVE_FILE):
			d.remove(BAD_SAVE_FILE)
		d.rename(SAVE_FILE, BAD_SAVE_FILE)

## Is this a stationary structure? The main path is the flag from the save; files written before it
## existed have no flag but do contain bases. For those we judge by LAYOUT: a stationary core and no
## cabin. The opposite mistake is impossible - a machine always has a cabin.
func _is_station_data(mdata: Dictionary) -> bool:
	if mdata.get("station", false) == true:
		return true
	var has_core := false
	for e in mdata.get("layout", []):
		if not (e is Dictionary):
			continue
		var bt: int = G.block_from_key(e.get("block", 0))
		if bt == G.Block.CABIN:
			return false
		if G.is_stationary(bt):
			has_core = true
	return has_core

func _restore_machine(veh, mdata: Dictionary) -> void:
	if not is_instance_valid(veh):
		return
	# A STATIONARY BASE is flagged BEFORE the layout. It differs from a machine by this flag, not by
	# blocks: it has no cabin, and without the flag the cabin watchdog (vehicle_body_3d._cabin_watch)
	# took it for a machine with its cabin shot out - the base fell apart into blocks half a second
	# after every load, and restoring crashed on an already freed node.
	var station: bool = _is_station_data(mdata)
	if station and "is_station" in veh:
		veh.is_station = true
	veh.apply_build(mdata.get("layout", []))
	if station and veh.get("block_map_node") != null and "is_station" in veh.block_map_node:
		veh.block_map_node.is_station = true
	var p = mdata.get("pos", null)
	var r = mdata.get("rot", null)
	if not (veh is Node3D):
		return
	# The terrain is awaited BEFORE freezing, and briefly. Machines used to be frozen and held for up
	# to 600 frames, and if the terrain did not read its heights in time the player stood as a brick for
	# ten seconds. If it does not arrive, place as saved: _rescue_fallen runs once a second and lifts
	# the machine if it ends up underground.
	var terr: Node = await _await_terrain(TERRAIN_WAIT_FRAMES)
	# After waiting up to 120 frames the machine may be gone (destroyed, removed as an extra). A
	# reference to a freed node is NOT null, so only is_instance_valid is checked: comparing with null
	# silently lets a dead node through.
	if not is_instance_valid(veh):
		return

	# A machine is a RigidBody3D and a DIRECT teleport of an unfrozen body is rolled back by physics,
	# while under the new point there is no streamed terrain collision yet (tiles are built around a
	# body only AFTER it is there). So: freeze, place NOT BELOW the terrain, wait a couple of frames for
	# collision, release.
	var rb := veh as RigidBody3D
	if rb != null:
		rb.freeze = true
		rb.linear_velocity = Vector3.ZERO
		rb.angular_velocity = Vector3.ZERO
	if r != null:
		veh.global_rotation = Vector3(r[0], r[1], r[2])
	if p != null:
		var pos := Vector3(p[0], p[1], p[2])
		if terr != null:
			pos.y = maxf(pos.y, terr.terrain_height_at(pos) + SAFE_CLEARANCE)
		else:
			# The saved height must not be applied unchecked: if a past bug left it underground the machine
			# starts inside the world and falls. Take X/Z only and keep the spawn height, which is safely above
			# the terrain.
			pos.y = maxf(veh.global_position.y, pos.y)
			push_warning("world_persist: рельеф не готов — беру из сейва только X/Z, "
					+ "высоту оставляю спавновую")
		veh.global_position = pos
	await get_tree().process_frame
	await get_tree().process_frame
	if not is_instance_valid(veh):
		return
	# A BASE is never released: it is anchored by definition, and unfreezing would mean the building
	# drove off. _anchor_station restores the freeze, the anchor column and the core subscription.
	if station:
		if veh.has_method("_anchor_station"):
			veh._anchor_station()
		return
	if is_instance_valid(rb):
		rb.freeze = false

func _spawn_machine(mdata: Dictionary) -> void:
	var scene := load("res://player_vehicle.tscn") as PackedScene
	var vr := _vehicles_root()
	if scene == null or vr == null:
		return
	var v = scene.instantiate()
	vr.add_child(v)
	# Wait for the machine the same way _ready waits for the primary one: starter blocks arrive LATE
	# (blocks.spawn_block awaits the parent's ready), and a saved layout applied earlier was overwritten
	# by the catching-up coroutines.
	var guard: int = 0
	while guard < 600 and is_instance_valid(v) \
			and not (v.is_node_ready() and v.get("block_map_node") != null):
		await get_tree().process_frame
		guard += 1
	# After EVERY await the machine may already be freed - restoring runs across frames and the machine
	# can die or be cleaned up meanwhile. A freed reference is not null (touching it crashes the call),
	# so the one check is is_instance_valid.
	if not is_instance_valid(v):
		return
	if v.has_method("apply_build"):
		await _restore_machine(v, mdata)
	if not is_instance_valid(v):
		return
	var cc = _camera()
	if cc != null and "vehicles" in cc and not cc.vehicles.has(v):
		cc.vehicles.append(v)
	if v.has_method("set_active"):
		v.set_active(false)
