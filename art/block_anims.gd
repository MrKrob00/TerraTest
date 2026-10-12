extends SceneTree
# THE BLOCKS' CLIPS: every fixed motion a block makes - a lid that flips, a hatch that lifts, a ring
# that turns - is an Animation in `blocks/anims/<block>.tres`, played by AnimationPlayer nodes in the
# block's scene. The script only says WHEN and HOW FAST (play, play_backwards, pause, speed_scale),
# the way auto_miner.gd drives its pump. What follows game state rather than a timeline - a turret's
# aim, a wheel's roll and suspension, a support's ram, a charge level - stays in code.
#
# Run on a COPY (CLAUDE.md §3), then copy `blocks/anims/` back:
#   godot --headless --path <copy> --script res://art/block_anims.gd
#
# THE REST POSE IS READ FROM THE SCENE, never typed here: a clip keys absolute values, so a spin
# starts from the part's own turn (the radar's head is parked at -135 deg) and a slide keeps its x
# and z. A part moved in a scene means this script re-run. Every library carries a RESET clip at
# that pose, which the editor applies on save.
#
# A SPIN IS A LOOP OF WHOLE TURNS at a NOMINAL rate (the rate the old code turned at); the script
# eases `speed_scale` against that rate. Quaternion keys stand a quarter turn apart, so the slerp
# between two never takes the short way round the wrong side. Where two parts turn at their own
# rates in one loop (the Marlit gyro) the loop is long enough for each to make whole turns, at
# rates within 3% of the old ones.

const OUT := "res://blocks/anims/"

func _initialize() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT))
	await process_frame
	_radar()
	_solar()
	_seller()
	_scrapper()
	_wireless("wireless_charger")
	_wireless("marlit_wireless")
	_generator()
	_processor()
	_shield()
	_regen()
	_marlit_regen()
	_drill("drill", "Drill_base_big/Drill_rotor_big")
	_drill("small_drill", "Drill_base_small/Drill_rotor_small")
	_drill("marlit_drill", "Bit")
	_drill("marlit_laser_drill", "Head")
	_saw("marlit_saw", "Blade")
	quit()

# ── helpers ───────────────────────────────────────────────────────────────────

var _scene: Node3D = null

func _open(name: String) -> Node3D:
	if _scene != null:
		_scene.free()
	_scene = (load("res://blocks/scenes/%s.tscn" % name) as PackedScene).instantiate() as Node3D
	# In the tree: a part's global transform means something only there (CLAUDE.md, muzzles).
	get_root().add_child(_scene)
	return _scene

func _part(path: String) -> Node3D:
	var n := _scene.get_node_or_null(path) as Node3D
	assert(n != null, "no part " + path)
	return n

func _save(name: String, clips: Dictionary, reset_parts: Array) -> void:
	var lib := AnimationLibrary.new()
	var reset := Animation.new()
	reset.length = 0.001
	for path in reset_parts:
		var p := _part(path)
		var t := reset.add_track(Animation.TYPE_POSITION_3D)
		reset.track_set_path(t, path)
		reset.position_track_insert_key(t, 0.0, p.position)
		t = reset.add_track(Animation.TYPE_ROTATION_3D)
		reset.track_set_path(t, path)
		reset.rotation_track_insert_key(t, 0.0, p.quaternion)
		t = reset.add_track(Animation.TYPE_SCALE_3D)
		reset.track_set_path(t, path)
		reset.scale_track_insert_key(t, 0.0, p.scale)
	lib.add_animation("RESET", reset)
	for k in clips:
		lib.add_animation(k, clips[k])
	var err := ResourceSaver.save(lib, OUT + name + ".tres")
	print("%s: %s clips %s" % [name, error_string(err), clips.keys()])

## A loop of `turns` whole turns about `axis` in `length` seconds. `local` turns about the part's own
## axis (rotate_object_local), otherwise about its parent's (rotate / rotate_y).
func _spin_track(a: Animation, path: String, axis: Vector3, turns: float, length: float, local := false) -> void:
	var p := _part(path)
	var rest: Quaternion = p.quaternion
	var t := a.add_track(Animation.TYPE_ROTATION_3D)
	a.track_set_path(t, path)
	var steps := int(ceil(absf(turns) * 4.0))
	for i in steps + 1:
		var f := float(i) / float(steps)
		var q := Quaternion(axis.normalized(), TAU * turns * f)
		a.rotation_track_insert_key(t, length * f, rest * q if local else q * rest)

func _loop(length: float) -> Animation:
	var a := Animation.new()
	a.length = length
	a.loop_mode = Animation.LOOP_LINEAR
	return a

func _once(length: float) -> Animation:
	var a := Animation.new()
	a.length = length
	return a

## Keys a sampled function of time, `n` keys over the clip, for curves no two keys can draw.
func _sampled_pos(a: Animation, path: String, n: int, f: Callable) -> void:
	var t := a.add_track(Animation.TYPE_POSITION_3D)
	a.track_set_path(t, path)
	for i in n + 1:
		var tt := a.length * float(i) / float(n)
		a.position_track_insert_key(t, tt, f.call(tt))

func _sampled_rot(a: Animation, path: String, n: int, f: Callable) -> void:
	var t := a.add_track(Animation.TYPE_ROTATION_3D)
	a.track_set_path(t, path)
	for i in n + 1:
		var tt := a.length * float(i) / float(n)
		a.rotation_track_insert_key(t, tt, f.call(tt))

# ── the blocks ────────────────────────────────────────────────────────────────

## One sweep every SWEEP_TIME (4 s), clockwise seen from above, as radar.gd turned it.
func _radar() -> void:
	_open("radar")
	var a := _loop(4.0)
	_spin_track(a, "Head", Vector3.UP, -1.0, 4.0)
	_save("radar", {"sweep": a}, ["Head"])

## The flip (marlit_solar.gd FLIP_TIME 2.4 s): up on the rams to the upper cell, over, and down.
## Played forward on the anchor, backwards on release; mirrored leaves read as one lid.
func _solar() -> void:
	_open("marlit_solar")
	const FLIP := 2.4
	const REST_Y := 0.4
	const TURN_Y := 1.0
	var a := _once(FLIP)
	for leaf in ["LeafA", "LeafB"]:
		var rest := _part(leaf)
		var sign := -1.0 if leaf == "LeafA" else 1.0
		var eul := rest.rotation
		var pos := rest.position
		_sampled_pos(a, leaf, 48, func(tt: float) -> Vector3:
			var s := tt / FLIP
			var up := smoothstep(0.0, 0.3, s) - smoothstep(0.75, 1.0, s)
			return Vector3(pos.x, lerpf(REST_Y, TURN_Y, up), pos.z))
		_sampled_rot(a, leaf, 48, func(tt: float) -> Quaternion:
			var turn := smoothstep(0.28, 0.78, tt / FLIP)
			return Basis.from_euler(Vector3(sign * PI * turn, eul.y, eul.z)).get_rotation_quaternion())
	for ram in ["RamA0", "RamA1", "RamB0", "RamB1"]:
		var pos := _part(ram).position
		_sampled_pos(a, ram, 48, func(tt: float) -> Vector3:
			var s := tt / FLIP
			var up := smoothstep(0.0, 0.3, s) - smoothstep(0.75, 1.0, s)
			return Vector3(pos.x, lerpf(REST_Y, TURN_Y, up), pos.z))
	_save("marlit_solar", {"open": a}, ["LeafA", "LeafB", "RamA0", "RamA1", "RamB0", "RamB1"])

## The ring round the mast: one turn at RING_SPIN (14 rad/s); a sale kicks it to full and it eases out.
func _seller() -> void:
	_open("seller")
	var a := _loop(TAU / 14.0)
	_spin_track(a, "Ring", Vector3.UP, 1.0, a.length)
	_save("seller", {"spin": a}, ["Ring"])

## The rollers at SPIN (12 rad/s), turning against each other.
func _scrapper() -> void:
	_open("scrapper")
	var a := _loop(TAU / 12.0)
	_spin_track(a, "RollerA", Vector3.RIGHT, 1.0, a.length)
	_spin_track(a, "RollerB", Vector3.RIGHT, -1.0, a.length)
	_save("scrapper", {"roll": a}, ["RollerA", "RollerB"])

## The coils at RING_SPIN (5 rad/s) while energy flows.
func _wireless(name: String) -> void:
	_open(name)
	var a := _loop(TAU / 5.0)
	_spin_track(a, "Ring", Vector3.UP, 1.0, a.length)
	_save(name, {"spin": a}, ["Ring"])

## The turbine at ROTOR_SPIN (9 rad/s), and its sink through the lid (0.16 m, so its top, 0.47,
## ends under the lid, 0.40; in 0.25 s, eased, against the fuel's 0.3 s slide onto it): forward while
## fuel comes in, backwards once it is swallowed.
func _generator() -> void:
	_open("generator")
	var spin := _loop(TAU / 9.0)
	_spin_track(spin, "Rotor", Vector3.UP, 1.0, spin.length)
	var sink := _once(0.25)
	var pos := _part("Rotor").position
	_sampled_pos(sink, "Rotor", 10, func(tt: float) -> Vector3:
		return Vector3(pos.x, -0.16 * smoothstep(0.0, 1.0, tt / 0.25), pos.z))
	_save("generator", {"spin": spin, "sink": sink}, ["Rotor"])

## A guillotine hatch's pass (HATCH_LIFT 0.42 in HATCH_TIME 0.12, held a LEG 0.3, down in 0.18),
## one clip per hatch, since the two run at once; and the melt gauge, GAUGE_MIN to full over a
## second - the script sets the pace from `tick_time`.
func _processor() -> void:
	_open("processor")
	var clips := {}
	for h in ["HatchIn", "HatchOut"]:
		var a := _once(0.6)
		var pos := _part(h).position
		var t := a.add_track(Animation.TYPE_POSITION_3D)
		a.track_set_path(t, h)
		a.position_track_insert_key(t, 0.0, Vector3(pos.x, 0.0, pos.z))
		a.position_track_insert_key(t, 0.12, Vector3(pos.x, 0.42, pos.z))
		a.position_track_insert_key(t, 0.42, Vector3(pos.x, 0.42, pos.z))
		a.position_track_insert_key(t, 0.6, Vector3(pos.x, 0.0, pos.z))
		clips["pass_in" if h == "HatchIn" else "pass_out"] = a
	var g := _once(1.0)
	var sc := _part("Gauge").scale
	var gt := g.add_track(Animation.TYPE_SCALE_3D)
	g.track_set_path(gt, "Gauge")
	g.scale_track_insert_key(gt, 0.0, Vector3(sc.x, 0.02, sc.z))
	g.scale_track_insert_key(gt, 1.0, Vector3(sc.x, 1.0, sc.z))
	clips["melt"] = g
	_save("processor", clips, ["HatchIn", "HatchOut", "Gauge"])

## The cap's lift (CAP_LIFT 0.09 m at 0.45 m/s) - a reboot plays it only to REBOOT_LIFT - and its
## turn at CAP_SPIN (0.7 rad/s), wound up to CAP_SPIN_BOOT by speed_scale during a reboot.
func _shield() -> void:
	_open("shield")
	var pos := _part("Cap").position
	var lift := _once(0.2)
	var t := lift.add_track(Animation.TYPE_POSITION_3D)
	lift.track_set_path(t, "Cap")
	lift.position_track_insert_key(t, 0.0, Vector3(pos.x, 0.0, pos.z))
	lift.position_track_insert_key(t, 0.2, Vector3(pos.x, 0.09, pos.z))
	var spin := _loop(TAU / 0.7)
	_spin_track(spin, "Cap", Vector3.UP, 1.0, spin.length)
	_save("shield", {"lift": lift, "spin": spin}, ["Cap"])

## The beacon: the ring at RING_SPIN (1.8 rad/s); the crystal bobbing BOB (2.5 cm) and turning while
## powered - 14 s holds 5 bobs and 2 turns (0.90 rad/s and 2.24, against 0.9 and 2.2).
func _regen() -> void:
	_open("regen")
	var ring := _loop(TAU / 1.8)
	_spin_track(ring, "Ring", Vector3.UP, 1.0, ring.length)
	var c := _loop(14.0)
	_float_crystal(c, "Crystal", 0.025)
	_save("regen", {"spin": ring, "float": c}, ["Ring", "Crystal"])

func _float_crystal(a: Animation, path: String, bob: float) -> void:
	var pos := _part(path).position
	_sampled_pos(a, path, 5 * 16, func(tt: float) -> Vector3:
		return pos + Vector3(0.0, bob * sin(TAU * 5.0 * tt / 14.0), 0.0))
	_spin_track(a, path, Vector3.UP, 2.0, 14.0, true)

## The Marlit gyro: four rings, each about the normal of its own plane (RING_ANGLES about Z) at its
## own rate (GYRO_SPIN x RING_RATES = 1.6 / -2.16 / 1.28 / -1.84 rad/s); 35 s holds 9 / 12 / 7 / 10
## turns. The crystal stands up over POWER_UP (1.2 s, eased) on its mount - lying on the bottom
## bearing at 0, upright in the middle at the end - and floats and turns on its own node while
## working, as the Falsus one does (GYRO_BOB 2 cm).
func _marlit_regen() -> void:
	_open("marlit_regen")
	const ANGLES := [0.0, 90.0, 45.0, 135.0]
	const TURNS := [9.0, -12.0, 7.0, -10.0]
	var gyro := _loop(35.0)
	for i in 4:
		var ang := deg_to_rad(float(ANGLES[i]))
		_spin_track(gyro, "Ring%d" % i, Vector3(-sin(ang), cos(ang), 0.0), float(TURNS[i]), 35.0)
	var stand := _once(1.2)
	var centre := _part("CrystalMount").position
	const REST_POS := Vector3(0.0, -0.18, 0.0)
	var lying := Basis(Vector3.RIGHT, PI * 0.5)
	_sampled_pos(stand, "CrystalMount", 24, func(tt: float) -> Vector3:
		return centre + REST_POS.lerp(Vector3.ZERO, smoothstep(0.0, 1.2, tt)))
	_sampled_rot(stand, "CrystalMount", 24, func(tt: float) -> Quaternion:
		return lying.slerp(Basis.IDENTITY, smoothstep(0.0, 1.2, tt)).get_rotation_quaternion())
	var c := _loop(14.0)
	_float_crystal(c, "CrystalMount/Crystal", 0.02)
	_save("marlit_regen", {"gyro": gyro, "stand": stand, "float": c},
		["Ring0", "Ring1", "Ring2", "Ring3", "CrystalMount", "CrystalMount/Crystal"])

## The Marlit saw's blade, lying flat: a turn about the block's UP taken in the blade's own axes, at
## the drill's rate (the clip is named "drilling" so drill.gd drives it like a bit).
func _saw(name: String, blade: String) -> void:
	var root := _open(name)
	var r := _part(blade)
	var rel: Basis = root.global_transform.basis.inverse() * r.global_transform.basis
	var axis: Vector3 = (rel.inverse() * Vector3.UP).normalized()
	var a := _loop(0.4)
	_spin_track(a, blade, axis, 1.0, 0.4, true)
	_save(name, {"drilling": a}, [blade])

## The bit at SPIN_SPEED (2.5 turns a second) about the block's front, taken in the bit's own axes:
## the two models point their meshes differently (the big bit along its Y, the small along -X).
func _drill(name: String, rotor: String) -> void:
	var root := _open(name)
	var r := _part(rotor)
	var rel: Basis = root.global_transform.basis.inverse() * r.global_transform.basis
	var axis: Vector3 = (rel.inverse() * Vector3.FORWARD).normalized()
	var a := _loop(0.4)
	_spin_track(a, rotor, axis, 1.0, 0.4, true)
	_save(name, {"drilling": a}, [rotor])
