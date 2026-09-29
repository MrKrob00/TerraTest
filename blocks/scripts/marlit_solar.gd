extends VehicleBlock
# MARLIT SOLAR ARRAY (art/emitter_models.py marlit_solar). The top of a 2x1x2 housing is two
# leaves, armour on one side and cells on the other. On the anchor each rides up on its rams to the
# middle of the upper cell, turns over there and settles back cells up; released, it runs the same
# path backwards. It makes energy only lying open (`solar_units`, asked by MachineBody's power scan),
# so a machine on the move carries armour, not a panel. The block owns 2x2x2: the turn needs the
# upper floor, and a block put there would stand inside a leaf mid-turn.

## Seconds for the whole path, up, over and down.
const FLIP_TIME := 2.4
## Worth of a Falsus panel (SOLAR_RATE each): the player's 200 energy a second, against the Falsus
## panel's 80.
const UNITS := 2.5
## A leaf's centre lying in the frame, and while it turns (MS_REST_Y / MS_TURN_Y in the model).
const REST_Y := 0.4
const TURN_Y := 1.0

var _t: float = 0.0
var _leaves: Array[Node3D] = []
var _rams: Array[Node3D] = []

func _ready() -> void:
	super._ready()
	moving_parts = true                 # leaves and rams move (MachineBatch copies them)
	for n in ["LeafA", "LeafB"]:
		var l := get_node_or_null(n) as Node3D
		if l != null:
			_leaves.append(l)
	for n in ["RamA0", "RamA1", "RamB0", "RamB1"]:
		var r := get_node_or_null(n) as Node3D
		if r != null:
			_rams.append(r)

## How many Falsus panels this block is worth right now: all of it lying open, nothing otherwise.
func solar_units() -> float:
	return UNITS if _t >= 1.0 else 0.0

func _process(delta: float) -> void:
	var m: Node = _machine()
	var planted: bool = m != null and (m.get("anchored") == true or m.get("is_base") == true)
	var want: float = 1.0 if planted else 0.0
	if is_equal_approx(_t, want):
		return
	_t = move_toward(_t, want, delta / FLIP_TIME)
	_pose()

func _pose() -> void:
	var up: float = smoothstep(0.0, 0.3, _t) - smoothstep(0.75, 1.0, _t)
	var turn: float = smoothstep(0.28, 0.78, _t)
	var y: float = lerpf(REST_Y, TURN_Y, up)
	for i in _leaves.size():
		var l: Node3D = _leaves[i]
		l.position.y = y
		# The two leaves turn opposite ways, each outer edge up first: mirrored, they read as one lid.
		l.rotation.x = (-PI if i == 0 else PI) * turn
	for r in _rams:
		r.position.y = y

func _machine() -> Node:
	var p: Node = get_parent()
	if p == null or p.name != "blocks":
		return null
	return p.get_parent()
