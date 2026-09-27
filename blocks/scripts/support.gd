extends VehicleBlock
# SUPPORT and ROTATING SUPPORT. What they do lives on the machine (vehicle_body_3d: `support_block`,
# `toggle_anchor`, `_rot_support_tick`; enemy_vehicle `_turn_to_target`); this script only SHOWS it.
#
# The model is a jack (art/emitter_models.py support / rot_support): a housing, a sleeve, a piston
# rod and a round foot. While the machine stands on its anchor the piston runs out until the foot is
# on the ground - that replaces the plain white cylinder the machine used to grow under itself, so
# the machine draws no column when this block is its core (`draws_own_leg`). On the rotating one
# the STATOR ring under the turntable holds its heading on the ground while the housing turns with
# the machine, which is the one thing that says "this block turns the build".

## The model's rest gap between the leg's node and the foot's top (SUP_FOOT_Y - SUP_LEG_Y there):
## the leg is a unit rod scaled to this plus the extension.
const LEG_REST := 0.10
## Past this the jack stays short: a machine anchored over a cliff is still anchored, it just does
## not get a twenty-metre stilt.
const LEG_MAX := 12.0
## How fast the piston runs, as a share of what is left per second, never slower than LEG_MIN_SPEED.
const LEG_EASE := 10.0
const LEG_MIN_SPEED := 1.5
## The foot's underside is this far below the block's centre at rest.
const FOOT_DROP := 0.5

var _leg: Node3D = null
var _foot: Node3D = null
var _stator: Node3D = null
var _ext: float = 0.0
var _holding: bool = false
var _hold_yaw: float = 0.0

func _ready() -> void:
	super._ready()
	moving_parts = true                 # leg, foot and stator move (MachineBatch copies them)
	_leg = get_node_or_null("Leg") as Node3D
	_foot = get_node_or_null("Foot") as Node3D
	_stator = get_node_or_null("Stator") as Node3D

## Asked by vehicle_body_3d._build_anchor_column: this block puts its own foot on the ground.
func draws_own_leg() -> bool:
	return true

func _process(delta: float) -> void:
	var m: Node = _machine()
	var planted: bool = m != null and (m.get("anchored") == true or m.get("is_base") == true)
	# A support bolted on its side or upside down has no "down" to run the piston along.
	var upright: bool = global_basis.y.dot(Vector3.UP) > 0.9
	var want: float = 0.0
	if planted and upright:
		var bottom: float = global_position.y - FOOT_DROP
		want = clampf(bottom - G.ground_y(global_position, bottom), 0.0, LEG_MAX)
	if not is_equal_approx(_ext, want):
		var step: float = maxf(absf(want - _ext) * LEG_EASE, LEG_MIN_SPEED) * delta
		_ext = move_toward(_ext, want, step)
		if _leg != null:
			_leg.scale = Vector3(1.0, LEG_REST + _ext, 1.0)
		if _foot != null:
			_foot.position.y = -_ext
	if _stator != null:
		_turn_stator(planted and upright, delta)

## The stator keeps the heading it had when the machine anchored; loose or driving it turns with
## the housing again, easing back to its rest angle.
func _turn_stator(planted: bool, delta: float) -> void:
	if planted:
		if not _holding:
			_holding = true
			_hold_yaw = global_rotation.y + _stator.rotation.y
		_stator.rotation.y = wrapf(_hold_yaw - global_rotation.y, -PI, PI)
	else:
		_holding = false
		if not is_zero_approx(_stator.rotation.y):
			_stator.rotation.y = lerp_angle(_stator.rotation.y, 0.0, minf(delta * 4.0, 1.0))
			if absf(_stator.rotation.y) < 0.001:
				_stator.rotation.y = 0.0

func _machine() -> Node:
	var p: Node = get_parent()
	if p == null or p.name != "blocks":
		return null
	return p.get_parent()
