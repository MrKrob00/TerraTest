extends "res://blocks/scripts/wheel.gd"
# THE MARLIT HEAVY WHEEL: a SLIDING PILLAR, a portal box and DUAL TYRES (art/marlit_wheels.py
# build_wheavy, heavy_pose). The chrome leg slides along the pillar's axis (suspension) and turns in it
# (steering) with the collar; two scissor links tie the collar to the portal case and fold as it rises.
# The rig's numbers are the generator's (change both together); the physics is wheel.gd's.

const AX := Vector3(-0.5, 0.0, -0.08)
const LINK_X := 0.33
const LINK_HI := 0.50
const LINK_LO := 0.00
const LINK_LEN := 0.30

@onready var _collar: Node3D = $Collar
@onready var _leg: Node3D = $Leg
@onready var _link_up: Node3D = $LinkUp
@onready var _link_lo: Node3D = $LinkLo

func _steer_wheel() -> void:
	_pose()

func _apply_suspension_visual() -> void:
	_pose()

func _pose() -> void:
	if _leg == null:
		return
	var sag: float = clampf(suspension_sag(), -0.25, 0.45)
	var r := Basis(Vector3.UP, current_steer_angle)
	_collar.transform = Transform3D(r, AX)
	_leg.transform = Transform3D(r, AX + Vector3(0.0, sag, 0.0))
	var h: float = minf((LINK_HI - (LINK_LO + sag)) / 2.0, LINK_LEN * 0.999)
	var ang: float = atan2(sqrt(LINK_LEN * LINK_LEN - h * h), h)
	var off: Vector3 = r * Vector3(LINK_X, 0.0, 0.0)
	_link_up.transform = Transform3D(r * Basis(Vector3.BACK, ang), Vector3(AX.x + off.x, LINK_HI, AX.z + off.z))
	_link_lo.transform = Transform3D(r * Basis(Vector3.BACK, PI - ang), Vector3(AX.x + off.x, LINK_LO + sag, AX.z + off.z))
