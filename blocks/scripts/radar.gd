extends VehicleBlock
# RADAR: its whole effect is in the HUD - a machine carrying one gets the big map (hud.gd,
# RADAR_SIZE_FULL / RADAR_RANGE_FULL) - so the block's job in the world is to SHOW that it is
# working: the dish sweeps round while it sits on a machine, and stands still lying loose, which is
# exactly when it widens nothing. It draws no energy, so there is no third state to show.

## The scene parks the head turned -135 deg so the shop portrait (taken from the back-right three
## quarters) shows the dish's face; on a machine it sweeps, so the parked angle is never seen there.
## One sweep every SWEEP_TIME seconds; slow enough to read as a radar, not a fan.
const SWEEP_TIME := 4.0
var _head: Node3D = null

func _ready() -> void:
	super._ready()
	moving_parts = true                 # the head turns (MachineBatch copies it every frame)
	_head = get_node_or_null("Head") as Node3D

func _physics_process(delta: float) -> void:
	if _head == null or not freeze:
		return
	var p := get_parent()
	if p == null or p.name != "blocks":
		return
	_head.rotate_y(-TAU / SWEEP_TIME * delta)
