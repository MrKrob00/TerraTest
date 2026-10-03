extends VehicleBlock
# SUPPORT and ROTATING SUPPORT. What they do lives on the machine (vehicle_body_3d: `support_block`,
# `toggle_anchor`, `_rot_support_tick`; enemy_vehicle `_turn_to_target`); this script only SHOWS it.
#
# The model is TerraTech's GSO anchor as a jack (art/emitter_models.py support / rot_support): a
# round base under a deck, a telescoping ram (sleeve over rod) and a foot. While the machine stands on its anchor the ram runs out until the foot is
# on the ground - that replaces the plain white cylinder the machine used to grow under itself, so
# the machine draws no column when this block is its core (`draws_own_leg`).
#
# ON THE ROTATING ONE EVERYTHING UNDER THE DECK HOLDS ITS HEADING while the machine is anchored -
# the round STATOR base, the sleeve, the ram and the foot - and the deck with the housing turns over
# it: the foot stands on the ground, and what stands on the ground does not turn. The first cut held
# the stator ALONE while the ram and the foot under it turned with the machine, and a held part
# between two turning ones read as a part turning backwards (the player's report); after that the
# whole block turned, and "the part that should be fixed turns with the machine" was the next one.

## The foot's top at rest (SUP_FOOT_Y in the model; Marlit's MSUP_FOOT_TOP). The ram and the sleeve
## are unit rods hanging from their nodes; the gap from the leg's node down to here is the rest
## length, read off the scene.
@export var foot_top: float = -0.42
## The sleeve covers this share of the ram, so the jack reads as two telescoping stages.
const SLEEVE_SHARE := 0.55
## How far the ram runs out: the most the anchor may hold the machine's foot off the ground.
## vehicle_body_3d._anchor_target_y asks `leg_max` and sets the anchor height inside it, so the foot
## always lands; the player's number, "the machine rises about a metre and a half".
const LEG_MAX := 1.5
## How fast the piston runs, as a share of what is left per second, never slower than LEG_MIN_SPEED.
const LEG_EASE := 10.0
const LEG_MIN_SPEED := 1.5
## The foot's underside is this far below the block's centre at rest.
const FOOT_DROP := 0.5

var _leg: Node3D = null
var _sleeve: Node3D = null
var _rest: float = 0.0
var _foot: Node3D = null
var _stator: Node3D = null
var _ext: float = 0.0
## The lower half's turn against the block, and the world heading it holds while planted.
var _yaw: float = 0.0
var _holding: bool = false
var _hold_yaw: float = 0.0
## Marlit's rotating support: two pinions in mesh with the ring gear (art/emitter_models.py RING /
## PINION pitch radii 0.85 / 0.175).
const PINION_RATIO := 0.85 / 0.175
var _pinions: Array = []

func _ready() -> void:
	super._ready()
	moving_parts = true                 # leg, foot and the held lower half move (MachineBatch copies them)
	_leg = get_node_or_null("Leg") as Node3D
	_sleeve = get_node_or_null("Sleeve") as Node3D
	if _leg != null:
		_rest = maxf(_leg.position.y - foot_top, 0.01)
	_foot = get_node_or_null("Foot") as Node3D
	_stator = get_node_or_null("Stator") as Node3D       # only the rotating support has one
	for k in 2:
		var pn := get_node_or_null("Stator/Pinion%d" % k) as Node3D
		if pn != null:
			_pinions.append(pn)

## Asked by vehicle_body_3d._build_anchor_column: this block puts its own foot on the ground.
func draws_own_leg() -> bool:
	return true

func leg_max() -> float:
	return LEG_MAX

func _process(delta: float) -> void:
	var m: Node = _machine()
	var planted: bool = m != null and (m.get("anchored") == true or m.get("is_base") == true)
	# A support bolted on its side or upside down has no "down" to run the piston along.
	var upright: bool = global_basis.y.dot(Vector3.UP) > 0.9
	var want: float = 0.0
	if planted and upright:
		# under the ram, which is the block's middle on a 2x2x2 Marlit support, not its corner anchor
		var at: Vector3 = _leg.global_position if _leg != null else global_position
		var bottom: float = global_position.y - FOOT_DROP
		want = clampf(bottom - G.ground_y(Vector3(at.x, bottom, at.z), bottom), 0.0, LEG_MAX)
	var moved: bool = false
	if not is_equal_approx(_ext, want):
		var step: float = maxf(absf(want - _ext) * LEG_EASE, LEG_MIN_SPEED) * delta
		_ext = move_toward(_ext, want, step)
		moved = true
	if _stator != null and _hold_heading(planted and upright, delta):
		moved = true
	if moved:
		var turn := Basis(Vector3.UP, _yaw)
		if _leg != null:
			_leg.basis = turn * Basis.from_scale(Vector3(1.0, _rest + _ext, 1.0))
		if _sleeve != null:
			_sleeve.basis = turn * Basis.from_scale(
					Vector3(1.0, maxf((_rest + _ext) * SLEEVE_SHARE, _rest), 1.0))
		if _foot != null:
			_foot.position.y = -_ext
			_foot.basis = turn
		if _stator != null:
			_stator.basis = turn
		# the pinions on the held casting roll round the ring that turns with the deck
		for pn in _pinions:
			pn.basis = Basis(Vector3.UP, _yaw * PINION_RATIO)

## Planted, the lower half keeps the world heading it had when the anchor went down; released, it
## eases back square to the block. True when the angle changed.
func _hold_heading(planted: bool, delta: float) -> bool:
	var was: float = _yaw
	if planted:
		if not _holding:
			_holding = true
			_hold_yaw = global_rotation.y + _yaw
		_yaw = wrapf(_hold_yaw - global_rotation.y, -PI, PI)
	else:
		_holding = false
		_yaw = lerp_angle(_yaw, 0.0, minf(delta * 4.0, 1.0))
		if absf(_yaw) < 0.001:
			_yaw = 0.0
	return not is_equal_approx(was, _yaw)

func _machine() -> Node:
	var p: Node = get_parent()
	if p == null or p.name != "blocks":
		return null
	return p.get_parent()
