# MARLIT SHIELD: shield.gd's dome at Marlit's scale, the hatches for a model. What the dome does - who
# it stops, what a hit costs, the reboot - is shield.gd's; this file sets the faction's numbers and
# drives the model (art/emitter_models.py marlit_shield): a Marlit block whose six window floors are
# eight leaves each. Dome up, the leaves swing FOLD into the block and the emitter swells into the six
# funnels; rebooting, the leaves stand half open and the emitter blinks amber; unpowered, all shut and
# grey. A face with a block bolted over it keeps its hatch shut: the leaves would open onto that
# block's wall, and the model says "this face is covered".
extends "res://blocks/scripts/shield.gd"

## The player's numbers against the Falsus dome: half as far again, and one point of damage costs
## 1.25 times less energy (0.48 against 0.6).
const MARLIT_REACH := 1.5
const MARLIT_THRIFT := 1.25
## The model's numbers (MSD_FOLD, MSD_SWELL in the generator).
const FOLD := 55.0
const SWELL := 2.1
const OPEN_TIME := 0.7             # s for the leaves, and as much again for the swell
const REBOOT_OPEN := 0.35          # share of the fold the leaves stand at while rebooting
const LEAF_RE := "Leaf"            # every leaf node's name starts with this; its face is in meta `face`

var _leaves: Array[Node3D] = []
var _leaf_rest: Array[Basis] = []
var _leaf_face: Array[Vector3i] = []
var _open: float = 0.0             # 0 shut .. 1 leaves open
var _swell: float = 0.0            # 0 bead .. 1 swollen
var _covered: Dictionary = {}      # local face normal -> bool, asked every COVER_POLL
var _cover_t: float = 0.0
const COVER_POLL := 0.5

func _init() -> void:
	dome_scale = MARLIT_REACH
	cost_x = SHIELD_COST_X / MARLIT_THRIFT
	dome_centre = Vector3(-0.5, 0.5, -0.5)

func unbatched() -> Array:
	var c := get_node_or_null("Core")
	return [c] if c != null else []

func _setup_emitter() -> void:
	moving_parts = true
	_core = get_node_or_null("Core") as MeshInstance3D
	if _core != null:
		var m: Material = _core.material_override
		if m is StandardMaterial3D:
			_core_mat = (m as StandardMaterial3D).duplicate()
			_core_mat.albedo_color = _core_col
			_core.material_override = _core_mat
	for n in get_children():
		if n is Node3D and String(n.name).begins_with(LEAF_RE) and n.has_meta("face"):
			_leaves.append(n)
			_leaf_rest.append((n as Node3D).basis)
			_leaf_face.append(n.get_meta("face"))

func _animate_emitter(delta: float, up: bool, rebooting: bool) -> void:
	if up and not _was_up:
		_flash = 1.0
	_was_up = up
	_flash = maxf(_flash - delta / BOOT_FLASH, 0.0)
	var want_open: float = 1.0 if up else (REBOOT_OPEN if rebooting else 0.0)
	# Open first, then swell; closing, the other way round - the emitter never meets a closing leaf.
	if want_open >= _open:
		_open = move_toward(_open, want_open, delta / OPEN_TIME)
		if _open >= 1.0 and up:
			_swell = move_toward(_swell, 1.0, delta / OPEN_TIME)
	else:
		_swell = move_toward(_swell, 0.0, delta / OPEN_TIME)
		if _swell <= 0.0:
			_open = move_toward(_open, want_open, delta / OPEN_TIME)
	_cover_t -= delta
	if _cover_t <= 0.0:
		_cover_t = COVER_POLL
		_poll_covered()
	var ease_o: float = _open * _open * (3.0 - 2.0 * _open)
	for i in _leaves.size():
		var shut: bool = _covered.get(_leaf_face[i], false)
		var a: float = 0.0 if shut else deg_to_rad(FOLD) * ease_o
		_leaves[i].basis = _leaf_rest[i] * Basis(Vector3.RIGHT, a)
	if _core != null:
		var ease_s: float = _swell * _swell * (3.0 - 2.0 * _swell)
		_core.scale = Vector3.ONE * lerpf(1.0, SWELL, ease_s)
	var col: Color = CORE_ON if up else CORE_OFF
	if rebooting:
		var blink: bool = fmod(Time.get_ticks_msec() / 1000.0 * BOOT_BLINK, 1.0) < 0.5
		col = CORE_BOOT if blink else CORE_BOOT * 0.35
	if _flash > 0.0:
		col = col.lerp(Color.WHITE, _flash)
	if _core_mat != null:
		_core_col = col if rebooting or _flash > 0.0 else _core_col.lerp(col, clampf(delta * 6.0, 0.0, 1.0))
		if not _core_mat.albedo_color.is_equal_approx(_core_col):
			_core_mat.albedo_color = _core_col

## Which faces have a block of this machine in front of them. The block's cells are its footprint
## (blocks.gd); a face counts as covered when any of the four cells in front of it is taken.
func _poll_covered() -> void:
	_covered.clear()
	var bl: Node = get_parent()
	if bl == null or bl.name != "blocks" or not bl.has_method("cell_of_node"):
		return
	var key: String = bl.cell_of_node(self)
	var map = bl.get("map")
	if key == "" or not (map is Dictionary):
		return
	var p := key.split(",")
	var anchor := Vector3i(int(p[0]), int(p[1]), int(p[2]))
	var rot := Basis(Vector3.UP, rotation.y)
	for f in [Vector3i(1, 0, 0), Vector3i(-1, 0, 0), Vector3i(0, 1, 0), Vector3i(0, -1, 0), Vector3i(0, 0, 1), Vector3i(0, 0, -1)]:
		var taken := false
		for c in _front_cells(f):
			var g: Vector3 = (rot * Vector3(c)).round()
			if (map as Dictionary).has(anchor + Vector3i(int(g.x), int(g.y), int(g.z))):
				taken = true
				break
		_covered[f] = taken

## The four cells in front of face `f`, as offsets from the anchor in the block's own axes (the
## block spans x -1..0, y 0..1, z -1..0).
static func _front_cells(f: Vector3i) -> Array:
	var out: Array = []
	var span := {0: [-1, 0], 1: [0, 1], 2: [-1, 0]}
	var ax: int = 0 if f.x != 0 else (1 if f.y != 0 else 2)
	var pos: int = (span[ax][1] + 1) if (f.x + f.y + f.z) > 0 else (span[ax][0] - 1)
	var o1: int = (ax + 1) % 3
	var o2: int = (ax + 2) % 3
	for a in span[o1]:
		for b in span[o2]:
			var v := [0, 0, 0]
			v[ax] = pos
			v[o1] = a
			v[o2] = b
			out.append(Vector3i(v[0], v[1], v[2]))
	return out
