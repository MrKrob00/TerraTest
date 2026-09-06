class_name MachineBody
extends RigidBody3D

# Shared driving physics: one implementation for the player machine and for enemies. It used
# to be two verbatim copies (vehicle_body_3d, enemy_vehicle) and every fix reached only one.
#
# Subclasses own input (joystick or AI), weapons, building and death. They fill _throttle and
# _steer_angle and then call the ready steps:
#   sense_ground(delta)     - wheel contact, mass, centre of mass
#   drive_physics(delta)    - traction, grip, steering, stabilisation, speed cap
#   push_drive_input(steer) - hand throttle and steering to the wheel blocks (visuals)
#
# Override points: _speed_cap() and _blocks_root().

@export_group("Двигатель")
## Overall traction multiplier. The traction itself comes from the wheels (Wheel.wheel_power);
## this is the one knob for the whole machine: acceleration = engine_force * sum(power) / mass.
@export var engine_force: float = 1.0
## Traction of a BARE cabin - with no attached block at all. It exists so the first minutes work:
## crawl to the blocks lying nearby. Attach anything and it disappears, so the machine needs
## wheels.
@export var chassis_power: float = 1100.0
@export var max_speed: float = 20.0
@export var engine_brake: float = 0.3

@export_group("Тормоза")
@export var brake_power: float = 4.0

@export_group("Поворот")
@export var steer_max_angle: float = 45.0
@export var steer_speed: float = 10.0
@export var turn_response: float = 4.0
@export var speed_steer_reduction: float = 0.5
## Below this speed the steering releases. The AI uses a higher threshold, otherwise an enemy
## saws at the wheel while nearly stopped.
@export var steer_min_speed: float = 0.05

@export_group("Сцепление шин")
@export var lateral_grip: float = 8.0
@export var longitudinal_grip: float = 0.3

@export_group("Стабилизация")
@export var anti_roll: float = 6.0
@export var upright_strength: float = 12.0
## Share of roll damping that still works airborne. With no wheel contact there is nothing to
## damp against, but switching it off entirely leaves the machine spinning after a jump.
@export_range(0.0, 1.0) var air_stability: float = 0.35

@export_group("Масса и физика")
@export var base_weight: float = 40.0
@export var gravity_mult: float = 2.5
## How far the centre of mass sits below the wheel axle. A low centre of mass is what keeps real
## cars from tipping, and it also removes the pitch-up moment from traction.
@export var com_drop: float = 0.40

## Damage multiplier for every weapon on this machine. It lives in the shared base by the rule
## "a mechanic both machines need belongs to MachineBody": the player's guns read the same field
## through the same code. Only the spawner touches it, halving the FIRST enemy
## (enemy_spawner.FIRST_ENEMY_DAMAGE).
var damage_scale: float = 1.0

var Wheels: Array = []
var _steer_angle: float = 0.0
var _throttle: float = 0.0
var _on_ground: bool = false

var _ground_q: PhysicsRayQueryParameters3D = null
var _grounded_wheels: int = 0
var _wheel_count: int = 0

var _mass_wheels_n: int = -1
var _mass_timer: float = 0.0
var _drive_cache: Array = []
var _drive_n: int = -1

# Bottom of the machine in local space (negative) - used by the ground check when no wheels are left.
var _body_drop: float = -0.5
# Blocks besides the cabin. 0 = a bare cabin, which is allowed to crawl on its own.
var _extra_blocks: int = 0
var _wheelbase: float = 2.0

# ══════════════════════════════════════════
# LOAD RATING (for the garage)
# ══════════════════════════════════════════

# Thresholds are ACCELERATION, not mass: how much a machine can haul depends on its own
# traction, so a constant "limit in kilograms" does not exist - it grows with the wheels. Time to
# top speed is roughly max_speed / acceleration (the body has no damping, linear_damp is zeroed
# in _ready). 25 m/s^2 is ~0.8 s and feels instant; 10 m/s^2 is 2 s and already heavy; below 10
# the player calls the machine stuck.
const ACCEL_BRISK: float = 25.0
const ACCEL_CRAWL: float = 10.0

## Rated traction: same as _drive_power but without requiring ground contact - in the garage the
## machine hangs in the air and its capabilities still have to be shown.
func rated_power() -> float:
	var power: float = 0.0
	for w in Wheels:
		if is_instance_valid(w) and w.is_drive:
			power += w.wheel_power
	if _extra_blocks == 0:
		power += chassis_power
	return power * engine_force

## Mass up to which the machine still feels brisk.
func mass_comfort() -> float:
	return rated_power() / ACCEL_BRISK

## Heaviest mass this build will still get moving.
func mass_limit() -> float:
	return rated_power() / ACCEL_CRAWL

# ── ENERGY (shared by player and enemy) ──────────────────────────────────────
# Lives HERE by the main-trap rule: shield, repair field and solar panel ask their own machine for
# energy, and while the system existed only in vehicle_body_3d all three were dead weight on an
# enemy build - the block was there with nothing to run on.
#
# _tick_prod is what was produced THIS tick (solar, generator): consumers eat that first, then the
# stored charge. Whatever is left at the start of the next tick flows into the batteries, or burns
# off if there are none. "Works without a battery, but never above what is produced" falls out of
# that by itself.
#
# THE CHARGE LIVES IN THE BATTERIES (blocks/scripts/battery.gd); the machine only collects and
# distributes across them. While it was one machine-level number, a battery removed and refitted
# came back empty - capacity returned, charge did not, so a charged battery could neither be
# stored nor moved to another machine.
#
# _energy is what batteries do NOT hold: the solar buffer under anchor. It belongs to the machine
# because it appears with the anchor and disappears with it.
const BATTERY_CAP := 100.0        # fallback capacity for blocks without one (old scenes)
## A machine has NO capacity of its own. Capacity comes only from what is mounted: a battery
## always, a solar panel only WHILE ANCHORED and only as much as it produces in a second. Leave the
## anchor and that buffer goes with the production, leaving whatever the battery really holds.
const BASE_ENERGY_CAP := 0.0
const SOLAR_RATE := 6.0          # energy per second per panel (anchored only)
var _energy: float = 0.0
var _tick_prod: float = 0.0
var _energy_cap: float = 0.0
var _battery_cap: float = 0.0        # battery share of capacity (recounted twice a second)
var _cap_timer: float = 0.0
var _solar_count: int = 0            # cached solar block count (refreshed with _cap_timer)

func energy_cap() -> float:
	return _energy_cap

func energy_stored() -> float:
	return _energy + _bat_stored()

# Battery fill for the HUD (0..1). No batteries - 0.
func energy_fill() -> float:
	return energy_stored() / _energy_cap if _energy_cap > 0.0 else 0.0

# Any energy at all right now (stored or freshly produced).
func energy_available() -> float:
	return energy_stored() + _tick_prod

# Sources (solar, generator) add their production here.
func energy_produce(amount: float) -> void:
	_tick_prod += amount

# Consumers (repair field, shield) ask for energy; returns how much was actually given.
# Spending order: fresh production -> solar buffer -> batteries. What would be lost anyway goes
# first (this tick's production, and the buffer that dies with the anchor).
func energy_consume(amount: float) -> float:
	# Debug switch (Main -> Debug -> Player): the player's machines pay nothing. Guarded at the
	# single till — shield, regen, factory and miner all ask through here, so none of them needs
	# its own check. Enemies keep paying: a tower whose shield never runs out cannot be cracked
	# open, and that is the only way to take one down.
	if amount > 0.0 and get("faction") == 0 and G.debug(&"infinite_energy", false):
		return amount
	var given: float = 0.0
	var from_prod: float = minf(amount, _tick_prod)
	_tick_prod -= from_prod
	given += from_prod
	var from_buf: float = minf(amount - given, _energy)
	_energy -= from_buf
	given += from_buf
	given += _bat_take(amount - given)
	return given

## ── Batteries as storage ─────────────────────────────────────────────────────
## Node cache: walking the build on every sip of energy is not an option - energy_consume is called
## by repair field, shield, miner and factory, each on its own tick. The list is refreshed where
## capacity is counted (twice a second) and cleaned of freed nodes there too.
var _batteries: Array = []

func _bat_stored() -> float:
	var s: float = 0.0
	for b in _batteries:
		if is_instance_valid(b):
			s += float(b.get("charge"))
	return s

## Top up across blocks. Returns what did NOT fit (that is what burns off if there is nowhere).
func _bat_add(amount: float) -> float:
	var left: float = amount
	for b in _batteries:
		if left <= 0.0:
			break
		if is_instance_valid(b) and b.has_method("charge_add"):
			left = b.charge_add(left)
	return left

## Draw across blocks. Returns how much was actually taken.
func _bat_take(amount: float) -> float:
	var need: float = amount
	var got: float = 0.0
	for b in _batteries:
		if need <= 0.001:
			break
		if is_instance_valid(b) and b.has_method("charge_take"):
			var g: float = b.charge_take(need)
			got += g
			need -= g
	return got

# Energy tick: last tick's leftover into batteries (burns off without them), capacity recount
# (twice a second), solar production (only while anchored).
func _energy_tick(delta: float) -> void:
	# Unspent production charges the BATTERIES first (long-term storage) and only the remainder goes
	# into the solar buffer, which dies with the anchor.
	_energy = minf(_energy + _bat_add(_tick_prod), _solar_buf_cap())
	_tick_prod = 0.0
	_cap_timer -= delta
	if _cap_timer <= 0.0:
		_cap_timer = 0.5
		var anchors := 0
		_solar_count = 0
		_batteries.clear()
		_battery_cap = BASE_ENERGY_CAP
		var bl: Node = _blocks_root()
		if bl != null:
			for b in bl.get_children():
				var bt = b.get("block")
				if bt == G.Block.BATTERY:
					_batteries.append(b)
					# Capacity is asked FROM THE BLOCK: it is its property (battery.gd). BATTERY_CAP here is only
					# a fallback for scenes without the battery script.
					var cap = b.get("capacity")
					_battery_cap += float(cap) if cap != null else BATTERY_CAP
				elif bt == G.Block.SOLAR:
					_solar_count += 1
				# What holds the machine on its anchor: a support block OR any stationary block - exactly what
				# allowed anchoring in can_anchor().
				if bt != null and (int(bt) in [G.Block.SUPPORT, G.Block.ROT_SUPPORT] or G.is_stationary(int(bt))):
					anchors += 1
		# What to do when no supports remain is up to the SUBCLASS: the player's machine drops off the
		# anchor, an enemy base has nowhere to drop. Counted here because it is the same block walk.
		_after_power_scan(anchors)
	# Capacity is recomputed EVERY tick, not once a second with the blocks: it depends on the anchor,
	# the anchor is released instantly, and the buffer must vanish at the same moment.
	_energy_cap = _battery_cap + _solar_buf_cap()
	_energy = minf(_energy, _solar_buf_cap())
	if power_anchored() and _solar_count > 0:
		energy_produce(_solar_count * SOLAR_RATE * delta)

## Solar buffer: exists ONLY while anchored and equals one second of panel output. Batteries have
## nothing to do with it - releasing the anchor does not touch their charge.
func _solar_buf_cap() -> float:
	return _solar_count * SOLAR_RATE if power_anchored() else 0.0

## Are the panels working? For an enemy BASE the answer is always yes: it is anchored by nature and
## has no way to release. The player overrides this with its own anchored field.
func power_anchored() -> bool:
	return true

## Hook after the block scan: how many supports (SUPPORT/stationary) the machine has. A base does
## not care, the player does (see vehicle_body_3d).
func _after_power_scan(_anchors: int) -> void:
	pass

# ── Machine-wide stats ───────────────────────────────────────────────────────
# They live here rather than on the enemy because they describe ANY machine: the AI decides
# whether to fight by them and the garage shows the same numbers to the player. One place, so the
# panel cannot disagree with what the AI sees.

## Current and maximum HP of all blocks.
func hp_totals() -> Vector2i:
	var bl: Node = _blocks_root()
	if bl == null:
		return Vector2i(1, 1)
	var cur: int = 0
	var mx: int = 0
	for b in bl.get_children():
		if b is VehicleBlock:
			cur += (b as VehicleBlock).current_hp
			mx += (b as VehicleBlock).max_hp
	return Vector2i(cur, maxi(mx, 1))

func health_ratio() -> float:
	var hp: Vector2i = hp_totals()
	return clampf(float(hp.x) / float(hp.y), 0.0, 1.0)

## Rough damage per second of all guns - for "who out-shoots whom" comparisons.
func firepower() -> float:
	var bl: Node = _blocks_root()
	if bl == null:
		return 0.0
	var p: float = 0.0
	for b in bl.get_children():
		var dmg: Variant = b.get("damage")
		var rate: Variant = b.get("fire_rate")
		if dmg != null and rate != null and float(rate) > 0.001:
			p += float(dmg) / float(rate)
	return p

## Wheels on the machine: x total, y driven.
func wheel_counts() -> Vector2i:
	var total: int = 0
	var driven: int = 0
	for w in Wheels:
		if is_instance_valid(w):
			total += 1
			if w.is_drive:
				driven += 1
	return Vector2i(total, driven)

## Recompute mass and centre of mass right now. The garage needs it: an inactive machine leaves
## _physics_process early, so _sync_mass never runs and the panel would show the last drive.
func refresh_mass() -> void:
	_mass_timer = 0.0
	_mass_wheels_n = -1
	_sync_mass()

# ══════════════════════════════════════════
# OVERRIDE POINTS
# ══════════════════════════════════════════

# Speed cap. A chasing enemy needs headroom, otherwise catching a runaway is mathematically
# impossible - it has the same max_speed.
func _speed_cap() -> float:
	return max_speed

# The node the machine's blocks hang under.
func _blocks_root() -> Node:
	return get_node_or_null("blocks")

# ══════════════════════════════════════════
# INITIALISATION
# ══════════════════════════════════════════

## Body friction against terrain. Set EXPLICITLY: whether the machine moves at all depends on it,
## and a silent engine default has no business deciding that.
const GROUND_FRICTION: float = 0.35

func init_machine_physics() -> void:
	gravity_scale = gravity_mult
	var mat := PhysicsMaterial.new()
	mat.friction = GROUND_FRICTION
	physics_material_override = mat

# Effective gravity with gravity_scale applied.
func _gravity_accel() -> float:
	return float(ProjectSettings.get_setting("physics/3d/default_gravity", 9.8)) * gravity_scale

# Rolling drag the engine must beat before the machine moves at all. The coefficient is the square
# root of our own friction: the engine combines two bodies' friction, the terrain has no material
# (i.e. 1.0), and a geometric mean gives sqrt(ours). Pessimistic on purpose - if the combine rule
# turns out different, we overshoot rather than undershoot.
func _rolling_drag() -> float:
	return sqrt(GROUND_FRICTION) * mass * _gravity_accel()

func append_wheel(wheel: Node) -> void:
	if !Wheels.has(wheel):
		Wheels.append(wheel)

func erase_wheel(wheel: Node) -> void:
	Wheels.erase(wheel)

# ══════════════════════════════════════════
# PHYSICS FRAME STEPS
# ══════════════════════════════════════════

func sense_ground(delta: float) -> void:
	_check_ground()
	_sync_mass(delta)

func drive_physics(delta: float) -> void:
	_apply_suspension()
	if _on_ground:
		_apply_engine()
		_apply_grip()
		_apply_steering(delta)
	# Roll is damped in the air too, but weaker: with no wheel contact there is nothing to damp
	# against, and releasing the machine entirely gives uncontrollable spin after a jump.
	_apply_anti_roll(delta, 1.0 if _on_ground else air_stability)
	_apply_upright(delta)
	_limit_speed()

# ══════════════════════════════════════════
# SUSPENSION
# ══════════════════════════════════════════
# Wheels LIFT the body by their radius, so the hull does not scrape and a bigger wheel gives more
# clearance by itself (its ride_height is larger).
#
# The spring is ADDITIONAL: block colliders (wheels included) are still there as a floor in case it
# is not enough. The worst case of a bad tune is today's behaviour, not a machine falling through
# the world.
#
# Stiffness is not a constant but derived from load: the spring must hold mass*g divided by the
# wheel count while sagging SUSP_SAG of its travel. Otherwise a loaded machine sits on its belly
# and an empty one bounces on the same numbers.
## Share of travel the suspension sags under the machine own weight at rest.
const SUSP_SAG: float = 0.35
## Damping as a share of critical: 1.0 is no bounce at all, less is softer and livelier.
const SUSP_DAMP: float = 0.75

func _apply_suspension() -> void:
	if _wheel_count <= 0:
		return
	var load_per: float = mass * _gravity_accel() / float(_wheel_count)
	var up: Vector3 = global_transform.basis.y
	for w in Wheels:
		if not is_instance_valid(w) or not w.grounded:
			continue
		if w.ride_height <= 0.0:
			continue                        # suspension off (a top wheel points up)
		var sag: float = w.suspension_sag()
		if sag <= 0.0:
			continue                        # wheel hanging: nothing to hold
		# k is chosen so that at rest the sag is exactly SUSP_SAG of travel.
		var travel: float = maxf(w.suspension_travel, 0.01)
		var k: float = load_per / (travel * SUSP_SAG)
		# Vertical speed of the mount point - that is what gets damped.
		var arm: Vector3 = w.global_position - global_position
		var vel_at: Vector3 = linear_velocity + angular_velocity.cross(arm)
		var c: float = 2.0 * SUSP_DAMP * sqrt(k * maxf(mass / float(_wheel_count), 0.001))
		var force: float = k * sag - c * vel_at.dot(up)
		if force <= 0.0:
			continue                        # suspension must never pull the body DOWN
		apply_force(up * force, arm)

# Throttle and steering go to the wheel blocks: that is what makes them spin and turn visually.
func push_drive_input(steer_norm: float) -> void:
	for block in _drive_blocks():
		if not is_instance_valid(block):
			_drive_n = -1               # block destroyed: force a cache rebuild
			continue
		block.set_throttle(_throttle)
		block.set_steer(steer_norm)

# Blocks that accept throttle and steering (wheels). The cache is invalidated by child count.
func _drive_blocks() -> Array:
	var bl: Node = _blocks_root()
	if bl == null:
		return []
	if bl.get_child_count() != _drive_n:
		_drive_n = bl.get_child_count()
		_drive_cache.clear()
		for b in bl.get_children():
			if b.has_method("set_throttle") and b.has_method("set_steer"):
				_drive_cache.append(b)
	return _drive_cache

# ══════════════════════════════════════════
# GROUND CONTACT
# ══════════════════════════════════════════

# ══════════════════════════════════════════
# GROUND CONTACT
# ══════════════════════════════════════════
# EVERY wheel probes the ground under itself. The old single ray from the body centre broke the
# moment a machine grew taller than the cabin: the centre rose with the build, the ray stopped
# reaching, and _on_ground took traction, grip and steering down with it. Wheels are always where
# the contact is.
func _check_ground() -> void:
	var space: PhysicsDirectSpaceState3D = get_world_3d().direct_space_state
	if _ground_q == null:
		_ground_q = PhysicsRayQueryParameters3D.new()
		_ground_q.exclude = [get_rid()]     # RIDs, not nodes; the set never changes, so set it once
		_ground_q.collision_mask = 1

	_grounded_wheels = 0
	_wheel_count = 0
	for w in Wheels:
		if not is_instance_valid(w):
			continue
		_wheel_count += 1
		if w.probe_ground(space, _ground_q):
			_grounded_wheels += 1

	if _wheel_count > 0:
		_on_ground = _grounded_wheels > 0
		return

	# No wheels (all shot off, or this is a stationary base) - probe from the BOTTOM of the machine,
	# not the centre, so ray length does not depend on build height.
	_ground_q.from = global_position + global_transform.basis.y * _body_drop
	_ground_q.to = _ground_q.from + Vector3.DOWN * 0.5
	_on_ground = not space.intersect_ray(_ground_q).is_empty()

# Share of wheels on the ground: 1.0 is full contact, 0.25 is hanging on one. With no wheels
# return 1.0, or stationary builds would lose grip.
func _contact_ratio() -> float:
	if _wheel_count <= 0:
		return 1.0
	return float(_grounded_wheels) / float(_wheel_count)

# ══════════════════════════════════════════
# MASS, CENTRE OF MASS, WHEEL GEOMETRY
# ══════════════════════════════════════════

# ══════════════════════════════════════════
# MASS, CENTRE OF MASS, WHEEL GEOMETRY
# ══════════════════════════════════════════
# Recomputes mass, centre of mass, hull bottom and axles in one pass over the blocks. ALL blocks
# add mass, not just wheels: otherwise the build would affect neither acceleration nor inertia and
# assembling a machine would decide nothing.
func _sync_mass(delta: float = 0.0) -> void:
	_mass_timer -= delta
	if Wheels.size() == _mass_wheels_n and _mass_timer > 0.0:
		return
	_mass_wheels_n = Wheels.size()
	_mass_timer = 0.5

	var total: float = base_weight
	var sum_x: float = 0.0
	var sum_z: float = 0.0
	var lowest: float = -0.5
	var extra: int = 0
	var bl: Node = _blocks_root()
	if bl != null:
		for b in bl.get_children():
			if not b.has_method("get_weight"):
				continue
			var w: float = b.get_weight()
			total += w
			sum_x += b.position.x * w
			sum_z += b.position.z * w
			lowest = minf(lowest, b.position.y - 0.5)
			if int(b.block) != G.Block.CABIN:
				extra += 1
	mass = total
	_body_drop = lowest
	_extra_blocks = extra

	# The centre of mass is dropped below the axle. Not a fudge: it is what keeps real cars upright -
	# the lower it sits above the contact patch, the greater the roll angle needed to push the vertical
	# outside the base. It also removes the pitch-up moment from traction, since apply_central_force
	# pushes through the centre of mass.
	var axle_y: float = 0.0
	var sum_z_w: float = 0.0
	var min_z: float = INF
	var max_z: float = -INF
	var n: int = 0
	for wheel in Wheels:
		if is_instance_valid(wheel):
			axle_y += wheel.position.y
			sum_z_w += wheel.position.z
			min_z = minf(min_z, wheel.position.z)
			max_z = maxf(max_z, wheel.position.z)
			n += 1
	if n > 0:
		axle_y /= float(n)
		_update_axles(sum_z_w / float(n), min_z, max_z)
	else:
		axle_y = lowest + 0.5
		_wheelbase = 2.0

	# Divided by TOTAL mass: base_weight is the chassis, it sits at the origin and pulls the centre
	# toward the middle. Without it an asymmetric build would shift the centre more than it really does.
	center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
	center_of_mass = Vector3(sum_x / total, axle_y - com_drop, sum_z / total)

# Front and rear are decided by wheel POSITION, not by the is_front flag: nothing ever set that
# flag, every wheel stayed true, the wheelbase was a hardcoded 2.0 and machine length had no effect
# on turning radius. Forward is -Z (see _get_forward), so the front wheel is the one with lower z.
func _update_axles(mid_z: float, min_z: float, max_z: float) -> void:
	var spread: float = max_z - min_z
	_wheelbase = maxf(spread, 0.5)
	# Wheels in a single row - give steering to all of them, or there is nothing to turn with.
	var single_row: bool = spread < 0.5
	for w in Wheels:
		if is_instance_valid(w):
			w.is_front = single_row or w.position.z < mid_z

func _get_wheelbase() -> float:
	return _wheelbase

# ══════════════════════════════════════════
# TRACTION
# ══════════════════════════════════════════

# ══════════════════════════════════════════
# TRACTION
# ══════════════════════════════════════════
# Total traction of driven wheels that are ON THE GROUND. A wheel in the air pushes nothing.
func _drive_power() -> float:
	var power: float = 0.0
	for w in Wheels:
		if is_instance_valid(w) and w.is_drive and w.grounded:
			power += w.wheel_power
	# Only a BARE cabin crawls on its own. Attach one block and it is a machine, which means it has to
	# stand on wheels or it goes nowhere.
	if _extra_blocks == 0:
		power += chassis_power
	return power

func _apply_engine() -> void:
	var fwd: Vector3 = _get_forward()
	var vel_fwd: float = fwd.dot(linear_velocity)

	# Force used to be multiplied by mass, so mass cancelled out and acceleration was constant: a
	# five-block machine and a hundred-block machine accelerated the same, and extra wheels gave
	# nothing. Now force is the sum of wheel traction and the physics engine divides by mass, as in
	# life.
	var power: float = _drive_power()
	if abs(_throttle) > 0.01 and power > 0.0:
		var speed_factor: float = clamp(1.0 - abs(vel_fwd) / max_speed, 0.05, 1.0)
		# The engine separately covers its OWN rolling drag, so the wheel traction sum stays pure surplus
		# for acceleration. Without that, traction competed with friction that grows with mass: at 296 kg
		# the drag (~7250 N) almost exactly equalled four wheels' traction and the machine stood still
		# while the maths promised 24 m/s^2. The old model hid this only because it multiplied traction by
		# mass and the friction cancelled.
		var surplus: float = power * engine_force * speed_factor
		apply_central_force(fwd * _throttle * (surplus + _rolling_drag()))
	elif abs(vel_fwd) > 0.1:
		apply_central_force(-fwd * vel_fwd * engine_brake * mass)   # coasting

# ══════════════════════════════════════════
# GRIP
# ══════════════════════════════════════════

func _apply_grip() -> void:
	var right: Vector3 = _get_right()
	var fwd: Vector3 = _get_forward()
	# ══════════════════════════════════════════
	# GRIP
	# ══════════════════════════════════════════
	# Grip scales with how many wheels actually touch: hanging on two of six, the machine must slide
	# rather than drive on rails.
	var contact: float = _contact_ratio()

	var vel_lat: float = right.dot(linear_velocity)
	apply_central_force(-right * vel_lat * lateral_grip * mass * contact)

	var vel_fwd: float = fwd.dot(linear_velocity)
	if abs(_throttle) < 0.01 and abs(vel_fwd) > 0.05:
		apply_central_force(-fwd * vel_fwd * longitudinal_grip * mass * contact)

# ══════════════════════════════════════════
# STEERING (Ackermann through angular_velocity)
# ══════════════════════════════════════════

func _apply_steering(delta: float) -> void:
	var fwd: Vector3 = _get_forward()
	var vel_fwd: float = fwd.dot(linear_velocity)

	if abs(vel_fwd) < steer_min_speed:
		angular_velocity.y = lerp(angular_velocity.y, 0.0, 10.0 * delta)
		return

	var wheelbase: float = _get_wheelbase()
	var target_yaw: float = 0.0
	if abs(_steer_angle) > 0.001 and wheelbase > 0.1:
		target_yaw = vel_fwd * tan(_steer_angle) / wheelbase
		if vel_fwd < 0:
			target_yaw = -target_yaw

	angular_velocity.y = lerp(angular_velocity.y, target_yaw, turn_response * delta)

# ══════════════════════════════════════════
# STABILISATION
# ══════════════════════════════════════════

func _apply_anti_roll(delta: float, scale: float = 1.0) -> void:
	var local_av: Vector3 = global_transform.basis.inverse() * angular_velocity
	var correction: Vector3 = global_transform.basis * Vector3(
		-local_av.x * anti_roll,
		0.0,
		-local_av.z * anti_roll
	)
	apply_torque(correction * mass * delta * scale)

func _apply_upright(delta: float) -> void:
	var up: Vector3 = _get_up()
	var dot: float = up.dot(Vector3.UP)
	if dot >= 0.85:
		return
	var axis: Vector3 = up.cross(Vector3.UP)
	if axis.length_squared() < 0.0001:
		return
	axis = axis.normalized()
	var angle: float = acos(clamp(dot, -1.0, 1.0))
	apply_torque(axis * angle * upright_strength * mass * delta)

func _limit_speed() -> void:
	var fwd: Vector3 = _get_forward()
	var vel_fwd: float = fwd.dot(linear_velocity)
	var cap: float = _speed_cap()
	if abs(vel_fwd) > cap:
		linear_velocity -= fwd * (vel_fwd - sign(vel_fwd) * cap)
	if linear_velocity.y > 10.0:
		linear_velocity.y = 10.0

# ══════════════════════════════════════════
# MACHINE AXES
# ══════════════════════════════════════════

func _get_forward() -> Vector3:
	return -global_transform.basis.z

func _get_right() -> Vector3:
	return global_transform.basis.x

func _get_up() -> Vector3:
	return global_transform.basis.y


# ══════════════════════════════════════════
# PRIORITY TARGET
# ══════════════════════════════════════════
# What the player marked to hit first (double tap on an enemy block). It lives on the MACHINE, not
# on the gun: mark once and every weapon turns, instead of instructing each one.
#
# It holds the BLOCK, not the machine: on an enemy it is worth picking something specific - the
# turret that reaches you, or the drill it digs with - not only the cabin.
var priority_target: Node3D = null

func set_priority_target(t: Node3D) -> void:
	priority_target = t

# Is the target still alive? A destroyed block would otherwise hold priority forever and the guns
# would ignore everything else, aiming at nothing.
func priority_alive() -> bool:
	if priority_target == null or not is_instance_valid(priority_target):
		priority_target = null
		return false
	return true

# ══════════════════════════════════════════
# TEARING BLOCKS INTO THE WORLD
# ══════════════════════════════════════════
# Lives in the SHARED base, not on the player machine. A torn block is dropped by the grid
# (blocks._detach_one) calling veh.detach_block_to_world() through has_method - and the enemy
# simply did not have the method: the check silently failed, the grid cell was cleared and the node
# kept hanging in the air. That was the visible difference: the player's wreckage fell, the
# enemy's floated.
var collision_to_block_map: Dictionary = {}

## Collider offset of 2x2x2 blocks relative to the block position: their collider describes a
## 2x2x2 cube and centres differently. Kept as one number - the collider is FOUND by it both when
## disassembling and when a block dies, and diverging copies would leave a collider on the hull.
const BIG_BLOCK_COL_OFFSET := Vector3(-0.5, 0.5, -0.5)

func _on_block_destroyed(destroyed_block: Node3D) -> void:
	
	var keys_to_remove: Array = []
	
	# Walk every shape owner of the Vehicle body
	for owner_id in get_shape_owners():
		var collision_shape: CollisionShape3D = shape_owner_get_owner(owner_id) as CollisionShape3D
		
		# Skip an already removed shape. This handler is reached by TWO paths - directly from
		# detach_block_to_world and via the destroyed signal - and they meet on the same block when it is
		# finished off during the tear (a bullet lands mid-reparent). A second remove_shape_owner on the
		# same owner raises the engine error "!shapes.has(owner)". "Already removed" is read from the node
		# itself: queue_free marked it and deletes at end of frame.
		if is_instance_valid(collision_shape) and not collision_shape.is_queued_for_deletion():
			# Whose collider is this. By the META tag when present (set when the collider is duplicated on
			# placement), and only otherwise by position: position lies for 2x2x2 blocks (the collider is
			# offset) and for two blocks that ended up at the same local point after a rebuild. The positional
			# fallback is for enemy machines, which have no tag.
			#
			# has_meta FIRST: get_meta(name, null) still raises "does not have any meta values" - the
			# engine treats a null default as "no default given". Enemy colliders have no tag at all,
			# so every torn-off block printed that error.
			var owner_block: Variant = collision_shape.get_meta("block_owner") \
					if collision_shape.has_meta("block_owner") else null
			var mine: bool = (owner_block == destroyed_block) if owner_block != null \
					else (collision_shape.position == destroyed_block.position \
						or collision_shape.position == destroyed_block.position + BIG_BLOCK_COL_OFFSET)
			if mine:
				
				
				# 1. disable it in the physics engine
				shape_owner_set_disabled(owner_id, true)
				
				# 2. clear the shape geometry from the physics server
				shape_owner_clear_shapes(owner_id)
				
				# 3. remove the shape owner from the Vehicle body
				remove_shape_owner(owner_id)
				
				# 4. free the collider node itself
				collision_shape.queue_free()
				
				# remember the id so the damage map can be cleaned
				keys_to_remove.append(owner_id)
				
	# drop stale ids from the damage map
	for key in keys_to_remove:
		collision_to_block_map.erase(key)

# A block lost its connection to the core (cabin or base) and falls into the world (see
# blocks._detach_orphans): remove its duplicated collider from the machine body, reparent into
# objects, unfreeze and drop.
## Where loose blocks go. The world has a node for it; anything else that runs machines (the menu
## backdrop with its demo fight) has no `/root/Main`, and without a fallback the torn block kept
## hanging in place with its collider already removed.
func _loose_sink() -> Node:
	var objects := get_node_or_null("/root/Main/objects")
	return objects if objects != null else get_parent()

func detach_block_to_world(node: Node) -> void:
	if not is_instance_valid(node):
		return
	if node is Node3D:
		_on_block_destroyed(node as Node3D)          # drop the block collider and clean the damage map
	var objects := _loose_sink()
	if objects == null or not (node is Node3D):
		return
	(node as Node3D).reparent(objects)
	if node is RigidBody3D:
		var rb := node as RigidBody3D
		rb.freeze = false
		rb.sleeping = false
		if _blast_force > 0.0 and Time.get_ticks_msec() < _blast_until_ms:
			# Torn off by a BLAST (a battery, say) - thrown from the epicentre harder than usual.
			var away := rb.global_position - _blast_pos
			if away.length_squared() < 0.01:            # 0.1 squared, comparison only
				away = Vector3(randf() - 0.5, 0.3, randf() - 0.5)
			away = (away.normalized() + Vector3.UP * 0.35).normalized()
			rb.apply_central_impulse(away * _blast_force * rb.mass)
		else:
			var dir := Vector3(randf() - 0.5, 0.0, randf() - 0.5)
			dir = dir.normalized() if dir.length_squared() > 0.0001 else Vector3.FORWARD
			rb.apply_central_impulse((dir * 2.0 + Vector3.UP * 2.5) * rb.mass)

# A blast on the machine (a destroyed battery, say): fragments torn off in the next ~0.2 s fly
# FROM the epicentre harder than usual (see detach_block_to_world). Set from VehicleBlock.destroy.
var _blast_pos: Vector3 = Vector3.ZERO
var _blast_force: float = 0.0
var _blast_until_ms: int = 0

# ══════════════════════════════════════════
# CABIN WATCHDOG — the machine is dead when its cabin is gone
# ══════════════════════════════════════════
# Lives in the SHARED base because both machines need it, and only the player had it. What that
# cost: the cabin's `destroyed` signal is the fast path, but it is not a reliable one. A block
# torn off into the world has ALL its `destroyed` connections cut (blocks._detach_one) so that
# a loose block no longer edits the map of the machine it came from — and with the signal gone,
# an enemy whose cabin left the machine simply never died. What was left was a live hull with
# no blocks on it, still driving, still a target, impossible to kill.
#
# So death is decided by the FACT that no cabin is present, and the signal only makes it fast.
var _dying: bool = false
var _cabin: Node = null            # current cabin; invalid → the build changed or it was killed
var _had_cabin: bool = false       # did it ever have one (stations have none and never die)
const CABIN_WATCH_INTERVAL: float = 0.5
var _cabin_watch_t: float = 0.0

## The node holding the block map. The player names it in the inspector; everyone else has it
## as a child called "blocks".
func blocks_node() -> Node:
	var n = get("block_map_node")
	return n if n != null else get_node_or_null("blocks")

func _connect_cabin() -> void:
	var bl := blocks_node()
	if bl == null:
		return
	for b in bl.get_children():
		if b.get("block") == G.Block.CABIN:
			_cabin = b
			_had_cabin = true
			if b.has_signal("destroyed") and not b.destroyed.is_connected(_on_cabin_destroyed):
				b.destroyed.connect(_on_cabin_destroyed)
			return
	_cabin = null

func _on_cabin_destroyed(_b = null) -> void:
	_die()

func cabin_watch(delta: float) -> void:
	if _dying:
		return
	_cabin_watch_t -= delta
	if _cabin_watch_t > 0.0:
		return
	_cabin_watch_t = CABIN_WATCH_INTERVAL
	# A BASE HAS NO CABIN — it stands on its stationary core, so that is what gets watched.
	# Same rule underneath: a machine dies when it loses the root everything hangs from. The
	# player's station used to rely on the core's `destroyed` signal alone, and an enemy base
	# has no cabin at all, so without this branch it would either never die or die instantly.
	# `is_station` only exists on machines that can be one, and get() on a missing field returns
	# null — bool(null) is a runtime crash, so compare instead of casting (see CLAUDE.md).
	if get("is_station") == true:
		if not _has_core():
			_die()
		return
	if is_instance_valid(_cabin):
		return
	_connect_cabin()                       # build changed — re-subscribe
	if is_instance_valid(_cabin):
		return
	if _had_cabin:
		_die()                             # no cabin, and no signal came

## THE BUILD MAY NOT BE APPLIED YET. Blocks spawn asynchronously (blocks.spawn_block waits for the
## parent to be ready) while the watchdog runs from the first physics frame, so "no children" means
## "not built yet", not "core destroyed". The flag remembers that THIS machine did have blocks; an
## empty list after that is a real death, not a birth race.
var _had_blocks: bool = false

func _has_core() -> bool:
	var bl := blocks_node()
	if bl == null:
		return true                        # build not applied yet — do not kill it on a guess
	var any := false
	for b in bl.get_children():
		var bt = b.get("block")
		if bt == null:
			continue
		any = true
		_had_blocks = true
		if G.is_stationary(int(bt)):
			return true
	return not any and not _had_blocks

## Overridden by both machines: the player hands the camera over, the enemy pays out and
## reports the kill. The base only decides WHEN it happens.
func _die() -> void:
	pass

## BLOCKS SCATTER WHEN THE MACHINE DIES. Lives in the SHARED base because both need it: the player
## had `_scatter_blocks`, the enemy `_eject_blocks`, and they would diverge on the first edit (the
## enemy's already missed hint ghosts). Exactly the trap CLAUDE.md warns about.
##
## `cabin` is the node the EPICENTRE is measured from: the enemy has a cabin reference at hand, the
## player searches for it, hence a parameter instead of one search style for both.
##
## The impulse is applied DIRECTLY and at once: we unfreeze here rather than waiting for
## VehicleBlock to do it a frame later via signal, or the block falls through the floor first.
func scatter_blocks(cabin: Node = null) -> void:
	var objects := _loose_sink()
	var bl: Node = get("block_map_node") if get("block_map_node") != null else get_node_or_null("blocks")
	if objects == null or bl == null:
		return
	var center: Vector3 = global_position
	if cabin != null and is_instance_valid(cabin) and cabin is Node3D:
		center = (cabin as Node3D).global_position
	else:
		for b in bl.get_children():
			if b.get("block") == G.Block.CABIN and b is Node3D:
				center = (b as Node3D).global_position
				break
	for b in bl.get_children():                   # get_children() is a snapshot, so reparent is safe
		if not ("block" in b):
			continue                              # hint ghost mesh: it has no block type
		if b.get("block") == G.Block.CABIN:
			continue                              # the cabin is destroyed, do not drop it
		if not (b is Node3D):
			continue
		var n3 := b as Node3D
		n3.reparent(objects)                      # keep_global_transform=true keeps the block in place
		var rb := n3 as RigidBody3D
		if rb == null:
			continue
		var dir := rb.global_position - center
		dir.y = 0.0
		dir = dir.normalized() if dir.length_squared() > 0.0001 \
				else Vector3(randf() - 0.5, 0.0, randf() - 0.5).normalized()
		rb.freeze = false
		rb.sleeping = false
		rb.apply_central_impulse((dir * 5.0 + Vector3.UP * 4.0) * rb.mass)

func register_blast(pos: Vector3, force: float) -> void:
	_blast_pos = pos
	_blast_force = force
	_blast_until_ms = Time.get_ticks_msec() + 300

