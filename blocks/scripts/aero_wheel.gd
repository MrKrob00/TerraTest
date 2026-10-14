extends "res://blocks/scripts/wheel.gd"
# THE AERO LIGHT WHEEL (art/aero_wheels.py, round one's design A - the player's pick, "basic and light").
# An open formula corner: two PARALLEL aerofoil A-arms and the drive shaft between them turn about X at
# their pivots on the mount plate, so the upright on their outboard ends only MOVES (it never tilts)
# and steers about the kingpin through the tyre's middle; the coilover turns about its top eye on the
# plate's turret and its rod rides the upper arm's eye.
#
# The rig's numbers are the generator's (K0, V, PU, PS, PL, DT, F_EYE): change both together. The
# physics is wheel.gd's; this poses the picture from the same `suspension_sag()` and
# `current_steer_angle`. The tyre node (%wheel) is turned so its X is the axle (wheel.gd rolls about
# it), and the tyre mesh under it (`Tyre`) is turned back into the generator's frame.

const K0 := Vector3(0.0, -0.46, -0.20)      # the kingpin through the tyre's middle
const V := Vector3(0.0, -0.13, -0.56)       # every link, inboard pivot to outboard end
const PU := Vector3(0.0, -0.19, 0.36)
const PS := Vector3(0.0, -0.33, 0.36)
const PL := Vector3(0.0, -0.47, 0.36)
const DT := Vector3(0.0, 0.20, 0.335)       # the coilover's top eye
const F_EYE := 0.60                         # its lower eye, this far out along the upper arm

@onready var _arm_up: Node3D = $ArmUp
@onready var _arm_lo: Node3D = $ArmLo
@onready var _shaft: Node3D = $Shaft
@onready var _dmp_body: Node3D = $DmpBody
@onready var _dmp_rod: Node3D = $DmpRod
@onready var _knuckle: Node3D = $Knuckle
var _pose_s: float = INF
var _swing := Basis()

## The arms' turn about X for a hub rise of s metres: V turned by phi rises by R sin(phi - a) - V.y,
## with R its length and a its angle under the level.
static func arm_angle(s: float) -> float:
	var r: float = Vector2(V.y, V.z).length()
	var a: float = atan2(-V.y, -V.z)
	return a + asin(clampf((s + V.y) / r, -0.95, 0.95))

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
		_arm_up.transform = Transform3D(_swing, PU)
		_arm_lo.transform = Transform3D(_swing, PL)
		_knuckle.position = K0 + (_swing * V - V)
		# the coilover: the body turns about its top eye to point at the arm's eye, the rod rides it
		var e0: Vector3 = PU + V * F_EYE
		var e1: Vector3 = PU + _swing * (e0 - PU)
		var d0: Vector3 = e0 - DT
		var d1: Vector3 = e1 - DT
		var turn := Basis(Vector3.RIGHT, atan2(d1.z, d1.y) - atan2(d0.z, d0.y))
		_dmp_body.transform = Transform3D(turn, DT)
		_dmp_rod.transform = Transform3D(turn, e1)
	# the shaft turns with the tyre, so it is posed every tick: about its own length, then swung
	_shaft.transform = Transform3D(_swing * Basis(V.normalized(), _spin), PS)
