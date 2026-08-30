@tool
extends VBoxContainer

# THE CUBE IN THE INSPECTOR. The same widget as in game (port_cube.gd), except that here it
# configures THE BLOCK'S SCENE rather than one machine's ports.
#
# The cube LOOKS AT THE BLOCK'S SIZE and splits into as many cells as the block really has: six
# faces for an ordinary 1³, six sides of four cells for the 2³ processor — twenty-four buttons.
# Otherwise "input on the left" on a big block would mean "input into all four left cells at
# once", and telling the cells of one side apart is the whole point.
#
# The size comes from the block's COLLISION, not from a table in code: the collision IS how the
# block takes up space in the world, and keeping a second list of sizes beside it is a way to let
# the two drift apart.
#
# WHAT EXACTLY IS BEING SET depends on the mode and the size:
#
#   CONNECT — CONNECTION sides. On a single-cell block that is the connect_faces mask; on a large
#             one, PER-CELL defaults (connect_defaults): a 2×2×2 processor can now be joined by
#             one cell of a side instead of all four at once.
#   IN/OUT  — on a single-cell block, the masks (input_faces / output_faces).
#   PORTS   — on a large one: per-cell defaults (port_defaults), where each cell has its own
#             side. The masks remain the base — a cell with no setting of its own behaves by the
#             mask, as before.
#
# Why the per-cell data is a DEFAULT and not a "port". A player's port (FactoryBlock.ports) lives
# in MAP axes and belongs to one machine; a scene has no idea which way round it will be placed,
# so everything here is in the BLOCK'S OWN axes and rotation is applied when it is read.

const MODE_CONNECT := 0
const MODE_IN := 1
const MODE_OUT := 2
const MODE_PORTS := 3

const COL_OFF := Color(0.16, 0.20, 0.22, 1.0)
const COL_CONNECT := Color(0.35, 0.85, 0.45, 1.0)
const COL_IN := Color(0.25, 0.72, 0.95, 1.0)
const COL_OUT := Color(1.0, 0.72, 0.25, 1.0)

var _block: VehicleBlock = null
var _ur = null
var _mode: int = MODE_CONNECT
var _cube = null
var _buttons: Array = []
var _cells: Array = [Vector3i.ZERO]
var _size_label: Label = null

func setup(block: VehicleBlock, undo_redo) -> void:
	_block = block
	_ur = undo_redo

func _ready() -> void:
	add_theme_constant_override("separation", 4)
	_cells = _footprint()
	var title := Label.new()
	title.text = "BLOCK FACES"
	add_child(title)

	var row := HBoxContainer.new()
	add_child(row)
	_add_mode_button(row, MODE_CONNECT, "CONNECT")
	# Only a factory block has inputs and outputs — on an ordinary one these buttons would have
	# nothing to change.
	if _block is FactoryBlock:
		if _cells.size() > 1:
			_add_mode_button(row, MODE_PORTS, "PORTS")     # per cell: off -> in -> out
		else:
			_add_mode_button(row, MODE_IN, "IN")
			_add_mode_button(row, MODE_OUT, "OUT")

	_cube = PortCube.new()
	_cube.cells = _cells
	_cube.custom_minimum_size = Vector2(300, 190)
	_cube.state_of = func(off: Vector3i, di: int) -> int:
		return _state(off, di)
	_cube.on_click = func(off: Vector3i, di: int) -> void:
		_toggle(off, di)
	add_child(_cube)

	_size_label = Label.new()
	_size_label.add_theme_font_size_override("font_size", 11)
	_size_label.text = "%d cell(s): %s" % [_cells.size(), _mode_hint()]
	add_child(_size_label)
	_sync()

func _add_mode_button(row: HBoxContainer, mode: int, text: String) -> void:
	var b := Button.new()
	b.text = text
	b.toggle_mode = true
	b.pressed.connect(func() -> void:
		_mode = mode
		_sync())
	row.add_child(b)
	_buttons.append({"btn": b, "mode": mode})

# ── Block size ───────────────────────────────────────────────────────────────
## The block's cells in the same axes and with the same origin as in game
## (`blocks._block_footprint`): along X and Z the footprint grows FROM THE ANCHOR INTO THE
## NEGATIVE, along Y INTO THE POSITIVE. Hence the formulas: for width n the cells run from -(n/2)
## to n-n/2, while in height they are simply 0..n-1. Let this drift from the game and the per-cell
## settings land in the wrong cells.
func _footprint() -> Array:
	var sz: Vector3 = _collision_size()
	var nx: int = maxi(int(round(sz.x)), 1)
	var ny: int = maxi(int(round(sz.y)), 1)
	var nz: int = maxi(int(round(sz.z)), 1)
	var out: Array = []
	for dx in range(-(nx / 2), nx - nx / 2):
		for dy in range(0, ny):
			for dz in range(-(nz / 2), nz - nz / 2):
				out.append(Vector3i(dx, dy, dz))
	return out

## The block's collision size in cells. The first BoxShape3D is taken: every block's collision is
## a box, and its size IS the space occupied (1³ for an ordinary one, 2³ for the processor, 2×1×1
## for a long one).
func _collision_size() -> Vector3:
	if _block == null or not is_instance_valid(_block):
		return Vector3.ONE
	for c in _block.get_children():
		var cs := c as CollisionShape3D
		if cs == null or cs.shape == null:
			continue
		var box := cs.shape as BoxShape3D
		if box != null:
			return box.size
	return Vector3.ONE

## The footprint centre in offsets — written onto the block as well (cells_center), so the
## per-cell defaults rotate together with the block.
func _footprint_center() -> Vector3:
	var lo := Vector3(INF, INF, INF)
	var hi := Vector3(-INF, -INF, -INF)
	for c in _cells:
		var v := Vector3((c as Vector3i).x, (c as Vector3i).y, (c as Vector3i).z)
		lo = Vector3(minf(lo.x, v.x), minf(lo.y, v.y), minf(lo.z, v.z))
		hi = Vector3(maxf(hi.x, v.x), maxf(hi.y, v.y), maxf(hi.z, v.z))
	return (lo + hi) * 0.5

# ── Cell state ───────────────────────────────────────────────────────────────
## What to show on a cell's face: in mask mode the face bit (0/1), in per-cell mode the port state
## (none / in / out), falling back to the mask exactly as the game does.
func _state(off: Vector3i, di: int) -> int:
	if _block == null or not is_instance_valid(_block):
		return 0
	if _mode == MODE_CONNECT and _cells.size() > 1:
		var cd: Dictionary = _block.get("connect_defaults")
		var ck := _port_key(off, di)
		if cd != null and cd.has(ck):
			return 1 if bool(cd[ck]) else 0
		return _bit("connect_faces", di)          # cell not configured: the mask applies
	if _mode == MODE_PORTS:
		var key := _port_key(off, di)
		var d: Dictionary = _block.get("port_defaults")
		if d != null and d.has(key):
			return int(d[key])
		# Not set: the mask applies, exactly as at runtime (FactoryBlock.port_state).
		if _bit("output_faces", di) == 1:
			return 2
		if _bit("input_faces", di) == 1:
			return 1
		return 0
	return _bit(_prop(), di)

func _bit(prop: String, di: int) -> int:
	var v = _block.get(prop)
	if v == null:
		return 0
	return 1 if (int(v) & (1 << di)) != 0 else 0

func _port_key(off: Vector3i, di: int) -> String:
	return "%d,%d,%d|%d" % [off.x, off.y, off.z, di]

## Which property the mask modes edit.
func _prop() -> String:
	match _mode:
		MODE_IN: return "input_faces"
		MODE_OUT: return "output_faces"
	return "connect_faces"

# ── Editing ──────────────────────────────────────────────────────────────────
func _toggle(off: Vector3i, di: int) -> void:
	if _block == null or not is_instance_valid(_block):
		return
	if _mode == MODE_PORTS:
		_toggle_port(off, di)
	elif _mode == MODE_CONNECT and _cells.size() > 1:
		_toggle_connect_cell(off, di)
	else:
		_toggle_mask(di)
	_sync()

## A face mask: the cell plays no part here, the whole face is switched at once.
func _toggle_mask(di: int) -> void:
	var prop := _prop()
	var old = _block.get(prop)
	if old == null:
		return
	_commit(prop, int(old) ^ (1 << di), "Block faces: %s" % prop)

## Per-cell CONNECTION: switch exactly this cell of this side. The mask stays the base for cells
## that are not in the dictionary, so existing scenes do not change.
func _toggle_connect_cell(off: Vector3i, di: int) -> void:
	var cd: Dictionary = (_block.get("connect_defaults") as Dictionary).duplicate()
	var key := _port_key(off, di)
	cd[key] = _state(off, di) == 0            # off becomes on, and the other way round
	_commit("cells_center", _footprint_center(), "Block connect: cells_center")
	_commit("connect_defaults", cd, "Block connect")

## A per-cell default, cycling NONE -> IN -> OUT. Written as a WHOLE DICTIONARY — the editor
## saves a property, not one key inside it.
func _toggle_port(off: Vector3i, di: int) -> void:
	var d: Dictionary = (_block.get("port_defaults") as Dictionary).duplicate()
	var key := _port_key(off, di)
	d[key] = (_state(off, di) + 1) % 3
	# The footprint centre is written along with it: without it rotating the block would take the
	# cells outside it, and nobody is going to type that number in by hand.
	_commit("cells_center", _footprint_center(), "Block ports: cells_center")
	_commit("port_defaults", d, "Block ports")

## Through the editor's stack rather than a direct assignment: the change has to land in Ctrl+Z
## and mark the scene dirty, or it is silently lost when the tab is closed.
func _commit(prop: String, value, action: String) -> void:
	var old = _block.get(prop)
	if _ur != null:
		_ur.create_action(action)
		_ur.add_do_property(_block, prop, value)
		_ur.add_undo_property(_block, prop, old)
		_ur.commit_action()
	else:
		_block.set(prop, value)

## Each mode has its own colour for an "on" face: otherwise it is far too easy to lose track of
## whether you are painting a connection or an input.
func _sync() -> void:
	for e in _buttons:
		(e["btn"] as Button).button_pressed = int(e["mode"]) == _mode
	if _size_label != null:
		_size_label.text = "%d cell(s): %s" % [_cells.size(), _mode_hint()]
	if _cube == null:
		return
	match _mode:
		MODE_PORTS:
			_cube.labels = ["—", "IN", "OUT"]
			_cube.colors = [COL_OFF, COL_IN, COL_OUT]
		MODE_IN:
			_cube.labels = ["—", "ON", "ON"]
			_cube.colors = [COL_OFF, COL_IN, COL_IN]
		MODE_OUT:
			_cube.labels = ["—", "ON", "ON"]
			_cube.colors = [COL_OFF, COL_OUT, COL_OUT]
		_:
			_cube.labels = ["—", "ON", "ON"]
			_cube.colors = [COL_OFF, COL_CONNECT, COL_CONNECT]
	_cube.queue_redraw()

func _mode_hint() -> String:
	match _mode:
		MODE_PORTS: return "tap a cell: off -> in -> out (per-cell defaults)"
		MODE_IN:    return "tap a face: input side"
		MODE_OUT:   return "tap a face: output side"
	if _cells.size() > 1:
		return "tap a cell: this cell attaches to a neighbour"
	return "tap a face: attaches to neighbours"
