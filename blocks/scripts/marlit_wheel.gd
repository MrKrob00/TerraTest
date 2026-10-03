extends "res://blocks/scripts/wheel.gd"
# THE MARLIT WHEEL: A MECHANISM THAT MOVES (art/marlit_drive.py, the player's call: "look again at the
# transmission, how it looks and how it works"). Two EQUAL, PARALLEL A-arms swing on their pins, so
# the hub carrier rides up and down without tilting and the tyre stays upright; the coilovers turn to
# follow the upper arm and their springs squeeze; the drive shaft runs from the gearbox to the
# carrier, swings and stretches with it and spins with the tyre; the carrier steers about its own
# upright. Every part is built about its own pivot in the model, so here a node only turns.
#
# The rig's numbers are the generator's (TC, KN, PIV_UP, ...): change one there and here together.
# The wheel's physics is wheel.gd's - this only poses the picture from the same `suspension_sag()`
# and `current_steer_angle` - and its tyre stands at `contact_offset`, a metre from the anchor.

const TC := Vector3(-0.5, -0.20, -0.86)
const KN := Vector3(-0.5, -0.20, -0.20)
const PIV_UP := Vector3(-0.5, 0.20, 0.24)
const PIV_LO := Vector3(-0.5, -0.40, 0.24)
const ARM_V := Vector3(0.0, -0.10, -0.44)
const ARM_X := [-1.06, 0.06]
const SHAFT_O := Vector3(-0.5, -0.20, 0.10)
const SHAFT_T := Vector3(-0.5, -0.20, -0.13)
const DAMP_TOP := [Vector3(-0.86, 1.00, 0.18), Vector3(-0.14, 1.00, 0.18)]
const DAMP_AT := 0.45

@onready var _arm_up: Node3D = $ArmUp
@onready var _arm_lo: Node3D = $ArmLo
@onready var _knuckle: Node3D = $Knuckle
@onready var _shaft: Node3D = $Shaft
@onready var _dbody: Array = [$DBody0, $DBody1]
@onready var _drod: Array = [$DRod0, $DRod1]
@onready var _springs: Array = [$Spring0, $Spring1]
var _pose_s: float = INF

## The arms' swing for a hub rise of s metres: ARM_V turned by phi about X rises by
## R sin(phi - a) - ARM_V.y, with R its length and a its angle under the level.
static func arm_angle(s: float) -> float:
	var r: float = Vector2(ARM_V.y, ARM_V.z).length()
	var a: float = atan2(-ARM_V.y, -ARM_V.z)
	return a + asin(clampf((s + ARM_V.y) / r, -0.95, 0.95))

func _steer_wheel() -> void:
	# the carrier turns about its own upright; the shaft's far end turns with it, close enough
	if _knuckle != null:
		_knuckle.transform.basis = Basis(Vector3.UP, current_steer_angle)

func _apply_suspension_visual() -> void:
	if _knuckle == null:
		return
	var s: float = suspension_sag()
	var r := Basis(Vector3.RIGHT, arm_angle(s))
	var dk: Vector3 = r * ARM_V - ARM_V
	if not is_equal_approx(s, _pose_s):
		_pose_s = s
		_arm_up.transform = Transform3D(r, PIV_UP)
		_arm_lo.transform = Transform3D(r, PIV_LO)
		_knuckle.position = KN + dk
		for i in 2:
			# the coilover's foot rides on the upper arm's leg, DAMP_AT of the way to the ball joint
			var leg := Vector3(ARM_X[i], PIV_UP.y, PIV_UP.z)
			var p0: Vector3 = leg + (PIV_UP + ARM_V - leg) * DAMP_AT
			var foot: Vector3 = PIV_UP + r * (p0 - PIV_UP)
			foot.x = p0.x
			_aim(_dbody[i], DAMP_TOP[i], foot)
			_aim(_springs[i], DAMP_TOP[i], foot, 0.0, true)
			_aim(_drod[i], foot, DAMP_TOP[i])
	# the shaft spins with the tyre every tick, so it is posed every tick
	_aim(_shaft, SHAFT_O, SHAFT_T + dk, _spin, true)

## A part built down its own -Z from its pivot, pointed from `from` at `to`; `stretch` makes its unit
## length the distance between them, `spin` turns it about its length.
func _aim(node: Node3D, from: Vector3, to: Vector3, spin: float = 0.0, stretch: bool = false) -> void:
	var d: Vector3 = to - from
	var dist: float = d.length()
	if dist < 0.001:
		return
	var dn: Vector3 = d / dist
	var b := Basis.looking_at(dn, Vector3.RIGHT if absf(dn.x) < 0.9 else Vector3.UP)
	if spin != 0.0:
		b = b * Basis(Vector3.BACK, spin)
	if stretch:
		b = b * Basis.from_scale(Vector3(1.0, 1.0, dist))
	node.transform = Transform3D(b, from)
