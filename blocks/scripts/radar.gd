extends VehicleBlock
# RADAR: its whole effect is in the HUD - a machine carrying one gets the big map (hud.gd,
# RADAR_SIZE_FULL / RADAR_RANGE_FULL) - so the block's job in the world is to SHOW that it is
# working: the dish sweeps round while it sits on a machine, and stands still lying loose, which is
# exactly when it widens nothing. It draws no energy, so there is no third state to show.

## The scene parks the head turned -135 deg so the shop portrait (taken from the back-right three
## quarters) shows the dish's face; on a machine it sweeps, so the parked angle is never seen there.
## The sweep is the clip "sweep" (one turn in 4 s, slow enough to read as a radar, not a fan) on the
## scene's `Anim` player; here only whether it runs.
var _anim: AnimationPlayer = null

func _ready() -> void:
	super._ready()
	moving_parts = true                 # the head turns (MachineBatch copies it every frame)
	_anim = get_node_or_null("Anim") as AnimationPlayer

func _physics_process(_delta: float) -> void:
	var p := get_parent()
	drive_clip(_anim, &"sweep", 1.0 if freeze and p != null and p.name == "blocks" else 0.0)
