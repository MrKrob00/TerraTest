extends "res://blocks/scripts/wheel.gd"
# THE MARLIT LIGHT WHEEL: a SWING AXLE (art/marlit_wheels.py build_wlight). The axle tube pivots about
# X at the final-drive drum (PIV), the hub carrier steers about its kingpin at the tube's end (KN), and
# one air strut runs from its top mount on the hull face to a clamp on the tube. Every part is built
# about its own pivot in the model. The rig's numbers are the generator's (change both together); the
# physics is wheel.gd's, this only poses the picture from `suspension_sag()` and `current_steer_angle`.

const PIV := Vector3(-0.5, -0.10, 0.02)
const KN := Vector3(-0.5, -0.10, -0.66)
const TC := Vector3(-0.5, -0.10, -1.12)
const STRUT_TOP := Vector3(-0.5, 1.02, 0.18)
const STRUT_FOOT := Vector3(-0.5, 0.08, -0.40)     # on the tube, at rest

@onready var _arm: Node3D = $Arm
@onready var _knuckle: Node3D = $Knuckle
@onready var _dbody: Node3D = $DBody
@onready var _drod: Node3D = $DRod

## The tube's swing about X for a hub rise of s metres.
static func arm_angle(s: float) -> float:
	var r: float = absf(TC.z - PIV.z)
	return asin(clampf(s / r, -0.95, 0.95))

func _steer_wheel() -> void:
	_pose()

func _apply_suspension_visual() -> void:
	_pose()

func _pose() -> void:
	if _knuckle == null:
		return
	var r := Basis(Vector3.RIGHT, arm_angle(suspension_sag()))
	_arm.transform = Transform3D(r, PIV)
	_knuckle.transform = Transform3D(r * Basis(Vector3.UP, current_steer_angle), PIV + r * (KN - PIV))
	var foot: Vector3 = PIV + r * (STRUT_FOOT - PIV)
	_aim(_dbody, STRUT_TOP, foot)
	_aim(_drod, foot, STRUT_TOP)

## A part built down its own -Z from its pivot, pointed from `from` at `to`.
func _aim(node: Node3D, from: Vector3, to: Vector3) -> void:
	var d: Vector3 = to - from
	if d.length() < 0.001:
		return
	var dn: Vector3 = d.normalized()
	node.transform = Transform3D(Basis.looking_at(dn, Vector3.RIGHT if absf(dn.x) < 0.9 else Vector3.UP), from)
