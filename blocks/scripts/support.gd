extends VehicleBlock
# SUPPORT and ROTATING SUPPORT. What they do lives on the machine (vehicle_body_3d: `support_block`,
# `toggle_anchor`, `_rot_support_tick`; enemy_vehicle `_turn_to_target`); this script only SHOWS it.
#
# The model is TerraTech's GSO anchor as a jack (art/emitter_models.py support / rot_support): a
# round base under a deck, a telescoping ram (sleeve over rod) and a foot. While the machine stands on its anchor the ram runs out until the foot is
# on the ground - that replaces the plain white cylinder the machine used to grow under itself, so
# the machine draws no column when this block is its core (`draws_own_leg`). The rotating one's
# round STATOR base turns WITH the housing, like the rest of the block: it used to hold the heading
# it had at the anchor, and the player read the one part not turning as a part turning backwards.

## The foot's top at rest (SUP_FOOT_Y in the model). The ram and the sleeve are unit rods hanging
## from their nodes; the gap from the leg's node down to here is the rest length, read off the scene.
const FOOT_TOP := -0.42
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
var _ext: float = 0.0

func _ready() -> void:
	super._ready()
	moving_parts = true                 # leg and foot move (MachineBatch copies them)
	_leg = get_node_or_null("Leg") as Node3D
	_sleeve = get_node_or_null("Sleeve") as Node3D
	if _leg != null:
		_rest = maxf(_leg.position.y - FOOT_TOP, 0.01)
	_foot = get_node_or_null("Foot") as Node3D

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
		var bottom: float = global_position.y - FOOT_DROP
		want = clampf(bottom - G.ground_y(global_position, bottom), 0.0, LEG_MAX)
	if not is_equal_approx(_ext, want):
		var step: float = maxf(absf(want - _ext) * LEG_EASE, LEG_MIN_SPEED) * delta
		_ext = move_toward(_ext, want, step)
		if _leg != null:
			_leg.scale = Vector3(1.0, _rest + _ext, 1.0)
		if _sleeve != null:
			_sleeve.scale = Vector3(1.0, maxf((_rest + _ext) * SLEEVE_SHARE, _rest), 1.0)
		if _foot != null:
			_foot.position.y = -_ext

func _machine() -> Node:
	var p: Node = get_parent()
	if p == null or p.name != "blocks":
		return null
	return p.get_parent()
