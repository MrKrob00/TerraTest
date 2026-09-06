extends Node3D
## Menu backdrop: REAL game machines, no game scripts.
##
## Machines are assembled from the MESHES of real block scenes (the `build_hint.gd` trick: take
## only `MeshInstance3D` with their own materials, drop body/areas/scripts, never add the scene to
## the tree). So nothing here can start working: no physics, no turret code, no factory. Ground is
## one flat mesh with fog, not LiteTerrain.
##
## Motion is a CIRCLE, deliberately. Steering with a turn-rate limit looked like the whole model
## being yanked left and right; a machine on rails reads as driving and never jerks. The TURRETS
## track the opponent and the tyres roll - the same two parts that move in game.
##
## Sun, environment, camera and ground are NODES in menu.tscn: they stand still, so they belong
## in the scene where they can be tweaked without touching code. Everything built from data -
## rocks, machines, tracers, cards - is created here.
##
## Every ROUND_TIME the round restarts: another biome palette and another pair of builds, so the
## menu is not one looping scene.
##
## All randomness comes from a local RNG; global `randf` belongs to the game.

## Wheel bottom is half a cell below the block centre — lower and the wheels sink into the floor.
const GROUND_Y := 0.62
## Tyre radius, for turning metres per second into radians per second.
const WHEEL_RADIUS := 0.45
const ROUND_TIME := 30.0

const TRACER_COL := Color(0.35, 0.95, 1.0)
const HIT_A := Color(1.0, 0.24, 0.18)
const HIT_B := Color(1.0, 0.62, 0.12)

## Bursts, not single shots: an even stream of single rounds reads as a metronome.
const BURST := Vector2i(3, 6)
const SHOT_GAP := 0.14
const RELOAD := Vector2(0.7, 1.7)
const BOLT_SPEED := 80.0
const MUZZLE_FLASH := 0.07
const TRACERS := 16
const CARDS := 48
const CARD_LIFE := 0.45

## Biome palettes for a round. Colours only — the shape of the ground never changes here.
const BIOMES := [
	{"name": "desert", "ground": Color(0.46, 0.39, 0.28), "rock": Color(0.38, 0.33, 0.25),
	 "fog": Color(0.62, 0.60, 0.52), "sky": Color(0.68, 0.70, 0.64)},
	{"name": "meadow", "ground": Color(0.30, 0.38, 0.22), "rock": Color(0.32, 0.34, 0.26),
	 "fog": Color(0.60, 0.66, 0.58), "sky": Color(0.66, 0.74, 0.68)},
	{"name": "canyon", "ground": Color(0.45, 0.29, 0.22), "rock": Color(0.36, 0.24, 0.19),
	 "fog": Color(0.66, 0.56, 0.48), "sky": Color(0.72, 0.66, 0.58)},
	{"name": "mountain", "ground": Color(0.34, 0.35, 0.37), "rock": Color(0.28, 0.29, 0.31),
	 "fog": Color(0.60, 0.63, 0.66), "sky": Color(0.66, 0.70, 0.74)},
]

var _rng := RandomNumberGenerator.new()
var _t: float = 0.0
var _round_t: float = 0.0
var _biome: int = 0
@onready var _cam: Camera3D = %MenuCamera
@onready var _ground: MeshInstance3D = %Ground
@onready var _rocks_root: Node3D = %Rocks
@onready var _machines_root: Node3D = %Machines
@onready var _fx_root: Node3D = %Effects
var _env: Environment = null
var _sky_mat: ProceduralSkyMaterial = null
var _ground_mat: StandardMaterial3D = null
var _rock_mat: StandardMaterial3D = null
var _rocks: Array = []
## Two machines: {node, ring, speed, phase, turrets, wheels, fire_t, burst, next}.
var _mach: Array = []
## Pools, allocated once and reused by the `on` flag.
var _tracers: Array = []
var _cards: Array = []

func _ready() -> void:
	_rng.seed = 0x7A11
	# Sky and ground materials come from the scene and are mutated per round (palette). They are
	# instances of this running scene, so nothing is written back to disk.
	var we := %MenuEnv as WorldEnvironment
	_env = we.environment if we != null else null
	if _env != null and _env.sky != null:
		_sky_mat = _env.sky.sky_material as ProceduralSkyMaterial
	_ground_mat = _ground.material_override as StandardMaterial3D
	_build_rocks()
	_build_pools()
	_new_round()
	set_process(true)

func _build_rocks() -> void:
	# Rocks and distant hills. Not decoration: on a bare plane there is nothing to measure the
	# machines' speed or distance against, and the motion reads as sliding.
	var lump := SphereMesh.new()
	lump.radius = 1.0
	lump.height = 2.0
	lump.radial_segments = 10
	lump.rings = 5
	_rock_mat = StandardMaterial3D.new()
	_rock_mat.roughness = 1.0
	for i in 22:
		var rock := MeshInstance3D.new()
		rock.mesh = lump
		rock.material_override = _rock_mat
		rock.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_rocks_root.add_child(rock)
		_rocks.append(rock)

## Scatter rocks and hills anew: same meshes, another layout — that is what "another map" means here.
func _scatter() -> void:
	for i in _rocks.size():
		var far: bool = i >= 14                     # the last few are horizon hills
		var a: float = _rng.randf() * TAU
		var r: float = _rng.randf_range(90.0, 170.0) if far else _rng.randf_range(13.0, 48.0)
		var s: float = _rng.randf_range(10.0, 22.0) if far else _rng.randf_range(0.5, 1.8)
		var rock: MeshInstance3D = _rocks[i]
		rock.position = Vector3(cos(a) * r, -(s * 0.5 if far else s * 0.55), sin(a) * r)
		rock.scale = Vector3(s * _rng.randf_range(1.4, 3.0), s, s * _rng.randf_range(1.4, 3.0)) \
				if far else Vector3(s * 1.6, s, s * 1.4)

# ── Machines ─────────────────────────────────────────────────────────────────
## Builds mirror the real `blocks.gd` presets but are listed as cells here: calling `blocks.gd`
## would drag in the 11³ grid with its scripts.
func _layouts() -> Array:
	return [_layout_player(), _layout_raider(), _layout_scout(), _layout_runner(), _layout_lancer()]

func _layout_player() -> Array:
	var l: Array = [
		[Vector3i(5, 5, 5), G.Block.CABIN, 0.0],
		[Vector3i(5, 5, 6), G.Block.BLOCK, 0.0],
		[Vector3i(5, 5, 7), G.Block.BLOCK, 0.0],
		[Vector3i(5, 5, 4), G.Block.DRILL, 0.0],
		[Vector3i(5, 6, 5), G.Block.LASER, 0.0],
	]
	l.append_array(_side_wheels(G.Block.WHEEL, [5, 6, 7]))
	return l

func _layout_raider() -> Array:
	var l: Array = [
		[Vector3i(5, 5, 5), G.Block.CABIN, 0.0],
		[Vector3i(5, 5, 6), G.Block.BLOCK, 0.0],
		[Vector3i(5, 5, 7), G.Block.BLOCK, 0.0],
		[Vector3i(5, 6, 6), G.Block.BLOCK, 0.0],
		[Vector3i(4, 6, 6), G.Block.ARMOR, PI / 2],
		[Vector3i(6, 6, 6), G.Block.ARMOR, -PI / 2],
		[Vector3i(5, 6, 5), G.Block.GUN, 0.0],
		[Vector3i(5, 6, 7), G.Block.GUN, 0.0],
	]
	l.append_array(_side_wheels(G.Block.WHEEL, [5, 6, 7]))
	return l

func _layout_scout() -> Array:
	var l: Array = [
		[Vector3i(5, 5, 5), G.Block.CABIN, 0.0],
		[Vector3i(5, 5, 6), G.Block.BLOCK, 0.0],
		[Vector3i(5, 6, 5), G.Block.GUN, 0.0],
	]
	l.append_array(_side_wheels(G.Block.SMALL_WHEEL, [5, 6]))
	return l

func _layout_runner() -> Array:
	var l: Array = [
		[Vector3i(5, 5, 5), G.Block.CABIN, 0.0],
		[Vector3i(5, 5, 6), G.Block.BLOCK, 0.0],
		[Vector3i(5, 5, 4), G.Block.ARMOR, 0.0],
		[Vector3i(5, 6, 5), G.Block.SHOTGUN, 0.0],
	]
	l.append_array(_side_wheels(G.Block.WHEEL, [5, 6]))
	return l

func _layout_lancer() -> Array:
	var l: Array = [
		[Vector3i(5, 5, 5), G.Block.CABIN, 0.0],
		[Vector3i(5, 5, 6), G.Block.BLOCK, 0.0],
		[Vector3i(5, 5, 7), G.Block.BLOCK, 0.0],
		[Vector3i(5, 6, 6), G.Block.BLOCK, 0.0],
		[Vector3i(5, 6, 5), G.Block.LASER, 0.0],
		[Vector3i(5, 6, 7), G.Block.LASER, 0.0],
		[Vector3i(4, 6, 6), G.Block.ARMOR, PI / 2],
	]
	l.append_array(_side_wheels(G.Block.WHEEL, [5, 6, 7]))
	return l

func _side_wheels(bt: int, rows: Array) -> Array:
	var l: Array = []
	for z in rows:
		l.append([Vector3i(4, 5, int(z)), bt, PI / 2])
		l.append([Vector3i(6, 5, int(z)), bt, -PI / 2])
	return l

## New round: another palette, another scatter, another pair of builds.
func _new_round() -> void:
	_round_t = ROUND_TIME
	_biome = (_biome + _rng.randi_range(1, BIOMES.size() - 1)) % BIOMES.size()
	var b: Dictionary = BIOMES[_biome]
	# Guarded: the scene may have been edited and a material or the environment removed.
	if _ground_mat != null:
		_ground_mat.albedo_color = b["ground"]
	if _rock_mat != null:
		_rock_mat.albedo_color = b["rock"]
	if _env != null:
		_env.fog_light_color = b["fog"]
	if _sky_mat != null:
		_sky_mat.sky_horizon_color = b["sky"]
		_sky_mat.ground_horizon_color = Color(b["ground"]).lerp(Color(b["fog"]), 0.5)
	_scatter()

	for m in _mach:
		(m["node"] as Node3D).queue_free()
	_mach.clear()
	var picks: Array = _layouts()
	picks.shuffle()
	for side in 2:
		var n := Node3D.new()
		_machines_root.add_child(n)
		var parts: Dictionary = _assemble(n, picks[side])
		_mach.append({
			"node": n,
			"wheels": parts["wheels"],
			# Two rings with different radii and speeds: the distance between them keeps changing
			# without anyone steering.
			"ring": 12.0 if side == 0 else 15.5,
			"speed": (0.16 if side == 0 else -0.13),
			"phase": 0.0 if side == 0 else PI,
			"turrets": parts["turrets"],
			"fire_t": _rng.randf_range(0.2, 1.0),
			"burst": 0,
			"next": 0,
		})

## Assemble and return the moving parts of THIS build: turrets track the enemy, tyres roll.
## Same split as in game - the hull carries them, they move on their own.
func _assemble(root: Node3D, layout: Array) -> Dictionary:
	var turrets: Array = []
	var wheels: Array = []
	for e in layout:
		var bt: int = int(e[1])
		var scene: PackedScene = G.get_scene(bt)
		if scene == null:
			continue
		var cell: Vector3i = e[0]
		var holder := Node3D.new()
		# Same formula blocks.gd uses for a real block: 11³ grid centred on 5,5,5.
		holder.position = Vector3(float(cell.x - 5), float(cell.y - 5), float(cell.z - 5))
		holder.rotation.y = float(e[2])
		root.add_child(holder)
		var src: Node = scene.instantiate()
		_copy_meshes(src, holder, Transform3D.IDENTITY)
		src.free()                  # orphan: never entered the tree, _ready never ran
		if bt == G.Block.GUN or bt == G.Block.LASER or bt == G.Block.SHOTGUN:
			var glow := _glow_sphere(0.14,
					TRACER_COL if bt == G.Block.LASER else Color(1.0, 0.8, 0.4))
			glow.position = Vector3(0.0, 0.3, -0.85)
			glow.visible = false
			holder.add_child(glow)
			turrets.append({"node": holder, "glow": glow, "flash": 0.0})
		elif bt == G.Block.WHEEL or bt == G.Block.SMALL_WHEEL or bt == G.Block.BIG_WHEEL:
			# The tyre is the copy of the node named "wheel" (wheel.gd spins that same one). It
			# rolls around its OWN X, and the mount is mirrored left/right, hence the side sign.
			for c in holder.get_children():
				if String(c.name).to_lower() != "wheel":
					continue
				wheels.append({"node": c, "rest": (c as Node3D).transform.basis,
						"side": -1.0 if cell.x < 5 else 1.0, "spin": 0.0})
	return {"turrets": turrets, "wheels": wheels}

## Copy the visible part with its OWN materials. `build_hint` paints its copy white; here the
## machine must look exactly like it does in game.
func _copy_meshes(node: Node, dst: Node3D, xform: Transform3D) -> void:
	var here := xform
	if node is Node3D and node.get_parent() != null:
		here = xform * (node as Node3D).transform
	var src_mi := node as MeshInstance3D
	if src_mi != null and src_mi.mesh != null and src_mi.visible:
		var mi := MeshInstance3D.new()
		mi.name = src_mi.name          # the tyre is found by name, see _assemble
		mi.mesh = src_mi.mesh
		mi.material_override = src_mi.material_override
		mi.transform = here
		dst.add_child(mi)
	for c in node.get_children():
		_copy_meshes(c, dst, here)

# ── Effect pools ─────────────────────────────────────────────────────────────
func _build_pools() -> void:
	var tm := BoxMesh.new()
	tm.size = Vector3(0.07, 0.07, 2.0)          # long axis is Z, the one look_at points
	var tmat := _glow_mat(TRACER_COL)
	for i in TRACERS:
		var mi := MeshInstance3D.new()
		mi.mesh = tm
		mi.material_override = tmat
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.visible = false
		_fx_root.add_child(mi)
		_tracers.append({"mi": mi, "on": false, "from": Vector3.ZERO, "to": Vector3.ZERO, "p": 0.0})

	# A hit is RED GLITCH CARDS — the same vocabulary the game uses for damage (BlockFX).
	var qm := QuadMesh.new()
	qm.size = Vector2(0.4, 0.4)
	for i in CARDS:
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
		var mi := MeshInstance3D.new()
		mi.mesh = qm
		mi.material_override = mat
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.visible = false
		_fx_root.add_child(mi)
		_cards.append({"mi": mi, "mat": mat, "on": false, "t": 0.0,
				"pos": Vector3.ZERO, "dir": Vector3.UP})

func _glow_mat(col: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = col
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	return m

func _glow_sphere(r: float, col: Color) -> MeshInstance3D:
	var sm := SphereMesh.new()
	sm.radius = r
	sm.height = r * 2.0
	sm.radial_segments = 8
	sm.rings = 4
	var mi := MeshInstance3D.new()
	mi.mesh = sm
	mi.material_override = _glow_mat(col)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mi

# ── Tick ─────────────────────────────────────────────────────────────────────
func _process(delta: float) -> void:
	_t += delta
	_round_t -= delta
	if _round_t <= 0.0:
		_new_round()
		return                                   # machines were just rebuilt, skip a frame
	for i in _mach.size():
		_drive(i)
	for i in _mach.size():
		_aim_and_fire(i, delta)
	_move_camera()
	_tracer_tick(delta)
	_card_tick(delta)

## Riding a circle: position and heading come straight from the angle, so there is nothing to
## jerk. Forward is −Z, hence the signs.
func _drive(i: int) -> void:
	var m: Dictionary = _mach[i]
	var a: float = float(m["phase"]) + _t * float(m["speed"])
	var r: float = float(m["ring"])
	var p := Vector2(cos(a) * r, sin(a) * r)
	var f := Vector2(-sin(a), cos(a)) * signf(float(m["speed"]))
	var n: Node3D = m["node"]
	n.position = Vector3(p.x, GROUND_Y + sin(_t * 4.6 + float(i)) * 0.02, p.y)
	n.rotation = Vector3(0.0, atan2(-f.x, -f.y), -0.05 * signf(float(m["speed"])))
	# Tyres roll at the speed the hull actually travels. Multiplying the basis instead of writing
	# rotation.x: the model has its own baked orientation and one Euler component would break it.
	var roll: float = absf(float(m["speed"])) * r / WHEEL_RADIUS
	for w in m["wheels"]:
		w["spin"] = float(w["spin"]) + float(w["side"]) * roll * get_process_delta_time()
		(w["node"] as Node3D).transform.basis = Basis(w["rest"]) * Basis(Vector3.RIGHT, float(w["spin"]))

## Turrets track the opponent by themselves — same split as in game: the hull drives its own way,
## the gun holds the target.
func _aim_and_fire(i: int, delta: float) -> void:
	var m: Dictionary = _mach[i]
	var n: Node3D = m["node"]
	var target: Vector3 = (_mach[1 - i]["node"] as Node3D).global_position + Vector3.UP * 0.6
	for t in m["turrets"]:
		var h: Node3D = t["node"]
		var loc: Vector3 = n.to_local(target)               # hull axes: the turret is its child
		var want: float = atan2(-loc.x, -loc.z)
		h.rotation.y = lerp_angle(h.rotation.y, want, clampf(6.0 * delta, 0.0, 1.0))
		t["flash"] = maxf(float(t["flash"]) - delta, 0.0)
		var glow: MeshInstance3D = t["glow"]
		glow.visible = float(t["flash"]) > 0.0
		if glow.visible:
			glow.scale = Vector3.ONE * (0.6 + 1.4 * float(t["flash"]) / MUZZLE_FLASH)

	if (m["turrets"] as Array).is_empty():
		return
	m["fire_t"] = float(m["fire_t"]) - delta
	if float(m["fire_t"]) > 0.0:
		return
	if int(m["burst"]) > 0:
		m["burst"] = int(m["burst"]) - 1
		m["fire_t"] = SHOT_GAP
		_shoot(i)
	else:
		m["burst"] = _rng.randi_range(BURST.x, BURST.y)
		m["fire_t"] = _rng.randf_range(RELOAD.x, RELOAD.y)

func _shoot(i: int) -> void:
	var m: Dictionary = _mach[i]
	var turrets: Array = m["turrets"]
	# Barrels fire IN TURN: a machine has up to two, and a salvo from both reads as one shot.
	var idx: int = int(m["next"]) % turrets.size()
	m["next"] = idx + 1
	var t: Dictionary = turrets[idx]
	var h: Node3D = t["node"]
	var slot: Dictionary = _free_slot(_tracers)
	if slot.is_empty():
		return
	t["flash"] = MUZZLE_FLASH
	slot["on"] = true
	slot["p"] = 0.0
	slot["from"] = h.to_global(Vector3(0.0, 0.3, -0.95))
	slot["to"] = _hull(1 - i)
	(slot["mi"] as MeshInstance3D).visible = true

func _move_camera() -> void:
	# Keeps BOTH in frame: they drive, so a fixed "world centre" would drift off the fight.
	var a: Vector2 = Vector2(_mach[0]["node"].position.x, _mach[0]["node"].position.z)
	var b: Vector2 = Vector2(_mach[1]["node"].position.x, _mach[1]["node"].position.z)
	var mid := (a + b) * 0.5
	var ang: float = 0.55 + _t * 0.04
	var dist: float = clampf(a.distance_to(b) * 1.35 + 12.0, 22.0, 38.0)
	_cam.position = Vector3(mid.x + cos(ang) * dist, 8.0 + sin(_t * 0.09) * 0.8,
			mid.y + sin(ang) * dist)
	_cam.look_at(Vector3(mid.x, 1.6, mid.y), Vector3.UP)

func _tracer_tick(delta: float) -> void:
	for t in _tracers:
		if not bool(t["on"]):
			continue
		var a: Vector3 = t["from"]
		var b: Vector3 = t["to"]
		t["p"] = float(t["p"]) + delta * BOLT_SPEED / maxf(a.distance_to(b), 0.001)
		var mi: MeshInstance3D = t["mi"]
		if float(t["p"]) >= 1.0:
			t["on"] = false
			mi.visible = false
			_burst(b)
			continue
		mi.position = a.lerp(b, float(t["p"]))
		if mi.position.distance_squared_to(b) > 0.01:
			mi.look_at(b, Vector3.UP)

func _card_tick(delta: float) -> void:
	for c in _cards:
		if not bool(c["on"]):
			continue
		var k: float = float(c["t"]) + delta / CARD_LIFE
		c["t"] = k
		var mi: MeshInstance3D = c["mi"]
		if k >= 1.0:
			c["on"] = false
			mi.visible = false
			continue
		mi.position = Vector3(c["pos"]) + Vector3(c["dir"]) * (0.3 + k * 1.6)
		mi.scale = Vector3.ONE * (0.6 + k * 0.9)
		var mat: StandardMaterial3D = c["mat"]
		mat.albedo_color.a = 1.0 - k

func _burst(at: Vector3) -> void:
	for i in 4:
		var c: Dictionary = _free_slot(_cards)
		if c.is_empty():
			return
		c["on"] = true
		c["t"] = 0.0
		c["pos"] = at
		var ang: float = _rng.randf() * TAU
		c["dir"] = Vector3(cos(ang), _rng.randf_range(0.15, 1.0), sin(ang)).normalized()
		var mat: StandardMaterial3D = c["mat"]
		mat.albedo_color = HIT_A if i % 2 == 0 else HIT_B
		(c["mi"] as MeshInstance3D).visible = true

func _free_slot(pool: Array) -> Dictionary:
	for e in pool:
		if not bool(e["on"]):
			return e
	return {}

## Hits land SPREAD over the target's hull: dead centre reads as a laser sight, not a fight.
func _hull(i: int) -> Vector3:
	return (_mach[i]["node"] as Node3D).to_global(Vector3(
			_rng.randf_range(-0.7, 0.7), _rng.randf_range(0.0, 1.2), _rng.randf_range(-0.8, 1.6)))
