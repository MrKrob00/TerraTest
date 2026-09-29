# MARLIT REPAIR UNIT: the repair field of regen.gd at Marlit's scale, the gyro for a model. The field
# (what it heals, what it costs, who it reaches) is regen.gd's and only its numbers differ; this file
# is the gyro. The block is 2x2x2, so the field stands round the block's middle, not its anchor.
extends "res://blocks/scripts/regen.gd"

## The player's numbers: a wider, faster, hungrier field. 180 HP a second against Falsus's 135, at
## 0.6 HP an energy against 1.5 - two and a half times the energy for each hit point - and 8.75 m
## of reach; 40% more blocks a tick, so the budget has room to spread.
const MARLIT_RADIUS := 8.75
const MARLIT_RATE := 180.0
const MARLIT_HP_PER_ENERGY := 0.6
const MARLIT_MORE := 1.4

func _init() -> void:
	field_radius = MARLIT_RADIUS
	heal_rate = MARLIT_RATE
	hp_per_energy = MARLIT_HP_PER_ENERGY
	max_bodies = int(round(FIELD_MAX_BODIES * MARLIT_MORE))
	field_centre = Vector3(-0.5, 0.5, -0.5)

# ── THE GYRO ───────────────────────────────────────────────────────────────────
# The model says whether the field works (art/emitter_models.py marlit_regen): four rings round the
# crystal, seen from the front as "-", "|", "/" and "\", hung in the Marlit shell.
# OFF: the rings stand, their energy strips are dark, and the crystal lies grey at the bottom, on the
# rings. POWER-UP: the rings wind up, each turning about its OWN axis (the normal of its plane, so it
# slides through its bearings), at its own rate and alternating in direction; the strips and the
# crystal turn green, and the crystal rises to the centre and stands up. WORKING: the rings turn and
# the crystal floats and turns slowly; every repair tick that heals something flashes it. Rings and
# crystal move (moving_parts); the crystal and the strips are re-coloured, so they draw themselves
# (unbatched) on one per-block material.
const RING_ANGLES := [0.0, 90.0, 45.0, 135.0]     # each ring's plane, turned about Z (REGEN2_ANGLES)
const RING_RATES := [1.0, -1.35, 0.8, -1.15]       # x GYRO_SPIN, rad/s: their own pace, alternating
const GYRO_SPIN := 1.6
const POWER_UP := 1.2              # s from off to working (and back)
const GYRO_OFF := Color(0.26, 0.27, 0.3)     # the crystal off: grey, where the beacon's goes dark green
const STRIP_OFF := Color(0.1, 0.13, 0.11)
## Where the crystal lies off: on its side, down on the bottom bearing and the rings.
const REST_POS := Vector3(0.0, -0.18, 0.0)
const GYRO_BOB := 0.02             # m the crystal floats while working
var _rings: Array[Node3D] = []
var _glow_mat: StandardMaterial3D = null
var _power: float = 0.0            # 0 off .. 1 working, eased
var _crystal_turn: float = 0.0

func unbatched() -> Array:
	var out: Array = []
	var c := get_node_or_null("Crystal")
	if c != null:
		out.append(c)
	for i in 4:
		var g := get_node_or_null("Ring%d/Glow" % i)
		if g != null:
			out.append(g)
	return out

func _setup_beacon() -> void:
	moving_parts = true
	for i in 4:
		var r := get_node_or_null("Ring%d" % i) as Node3D
		if r != null:
			_rings.append(r)
	_crystal = get_node_or_null("Crystal") as MeshInstance3D
	# One material for the crystal and the four strips, duplicated per block: a shared one would
	# light every repair unit in the world at once.
	var m: Material = _crystal.material_override if _crystal != null else null
	if m is StandardMaterial3D:
		_glow_mat = (m as StandardMaterial3D).duplicate()
		_glow_mat.albedo_color = GYRO_OFF
		_crystal.material_override = _glow_mat
	# The strips take their own copy: they go dark to a different colour than the crystal's grey.
	var strip_mat: StandardMaterial3D = null
	if _glow_mat != null:
		strip_mat = _glow_mat.duplicate()
		strip_mat.albedo_color = STRIP_OFF
		_strip_mat = strip_mat
	for r in _rings:
		var g := r.get_node_or_null("Glow") as MeshInstance3D
		if g != null and strip_mat != null:
			g.material_override = strip_mat
	_pose_crystal(0.0)

var _strip_mat: StandardMaterial3D = null

func _animate_beacon(delta: float, on: bool) -> void:
	_power = move_toward(_power, 1.0 if on else 0.0, delta / POWER_UP)
	var p: float = _power * _power * (3.0 - 2.0 * _power)        # smoothstep: eases in and out
	for i in _rings.size():
		var w: float = GYRO_SPIN * float(RING_RATES[i]) * p
		if absf(w) > 0.0005:
			var a: float = deg_to_rad(float(RING_ANGLES[i]))
			_rings[i].rotate(Vector3(-sin(a), cos(a), 0.0), w * delta)
	_heal_flash = maxf(_heal_flash - delta / HEAL_FLASH, 0.0)
	_crystal_turn += delta * 0.9 * p
	_pose_crystal(p)
	if _glow_mat != null:
		var c: Color = GYRO_OFF.lerp(CRYSTAL_ON, p).lerp(CRYSTAL_HEAL, _heal_flash)
		if not _glow_mat.albedo_color.is_equal_approx(c):
			_glow_mat.albedo_color = c
	if _strip_mat != null:
		var sc: Color = STRIP_OFF.lerp(CRYSTAL_ON, p)
		if not _strip_mat.albedo_color.is_equal_approx(sc):
			_strip_mat.albedo_color = sc

## The crystal at power p: lying on the bottom at 0, standing in the centre at 1, lifted along the way.
func _pose_crystal(p: float) -> void:
	if _crystal == null:
		return
	var t: float = Time.get_ticks_msec() / 1000.0
	var pos: Vector3 = field_centre + REST_POS.lerp(Vector3.ZERO, p)
	pos.y += GYRO_BOB * p * sin(t * 2.2)
	var lying := Basis(Vector3.RIGHT, PI * 0.5)
	var standing := Basis(Vector3.UP, _crystal_turn)
	_crystal.transform = Transform3D(lying.slerp(standing, p), pos)
