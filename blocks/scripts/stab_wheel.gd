extends "res://blocks/scripts/wheel.gd"
# THE FALSUS STABILISER: THE ARTIST'S OWN KIT (art/falsus_wheels.py `stab`, the player's pick of four
# designs). Out of the plate's slot come two PARALLEL bars - the artist's C-arm - with the drive shaft
# between them; their far ends carry the upright, and under it the knuckle (crown, one leg, hub drum)
# steers about the post and holds the tyre. Parallel links: the upright rides up and down without
# tilting, and the shaft, parallel to them, keeps its length - so here the bars and the shaft only
# TURN about their pivots, the upright and the knuckle only MOVE, and the knuckle turns about Y.
#
# The rig's numbers are the generator's (S_PU, S_PL, S_PS, S_V, S_ZK, S_K0): change both together.
# The physics is wheel.gd's; this poses the picture from the same `suspension_sag()` and
# `current_steer_angle`. The tyre (%wheel) is a child of the knuckle, so it steers and rides with it.

const PIV_UP := Vector3(0.0, 0.28, 0.44)
const PIV_LO := Vector3(0.0, -0.04, 0.44)
const PIV_SHAFT := Vector3(0.0, 0.12, 0.44)
const ARM_V := Vector3(0.0, -0.08, -0.46)
const UPRIGHT := Vector3(0.0, 0.04, -0.02)      # PIV_SHAFT + ARM_V: the bevel box on the post
const KNUCKLE := Vector3(0.0, -0.185, -0.02)    # on the post, at the crown's top

@onready var _bar_up: Node3D = $BarUp
@onready var _bar_lo: Node3D = $BarLo
@onready var _shaft: Node3D = $Shaft
@onready var _upright: Node3D = $Upright
@onready var _knuckle: Node3D = $Knuckle
var _pose_s: float = INF
var _swing := Basis()

## The bars' turn about X for a hub rise of s metres: ARM_V turned by phi rises by
## R sin(phi - a) - ARM_V.y, with R its length and a its angle under the level.
static func arm_angle(s: float) -> float:
	var r: float = Vector2(ARM_V.y, ARM_V.z).length()
	var a: float = atan2(-ARM_V.y, -ARM_V.z)
	return a + asin(clampf((s + ARM_V.y) / r, -0.95, 0.95))

func _steer_wheel() -> void:
	if _knuckle != null:
		_knuckle.transform.basis = Basis(Vector3.UP, current_steer_angle)

func _apply_suspension_visual() -> void:
	if _knuckle == null:
		return
	var s: float = suspension_sag()
	if not is_equal_approx(s, _pose_s):
		_pose_s = s
		_swing = Basis(Vector3.RIGHT, arm_angle(s))
		var lift: Vector3 = _swing * ARM_V - ARM_V
		_bar_up.transform = Transform3D(_swing, PIV_UP)
		_bar_lo.transform = Transform3D(_swing, PIV_LO)
		_upright.position = UPRIGHT + lift
		_knuckle.position = KNUCKLE + lift
	# the shaft turns with the tyre, so it is posed every tick: about its own length, then swung
	_shaft.transform = Transform3D(_swing * Basis(ARM_V.normalized(), _spin), PIV_SHAFT)
