extends VehicleBlock
# MARLIT SOLAR ARRAY (art/emitter_models.py marlit_solar). The top of a 2x1x2 housing is two
# leaves, armour on one side and cells on the other. On the anchor each rides up on its rams to the
# middle of the upper cell, turns over there and settles back cells up; released, it runs the same
# path backwards. It makes energy only lying open (`solar_units`, asked by MachineBody's power scan),
# so a machine on the move carries armour, not a panel. The block owns 2x2x2: the turn needs the
# upper floor, and a block put there would stand inside a leaf mid-turn.

## Worth of a Falsus panel (SOLAR_RATE each): the player's 200 energy a second, against the Falsus
## panel's 80.
const UNITS := 2.5

## The path is the clip "open" (2.4 s: up on the rams to the middle of the upper cell, over, down;
## the leaves mirrored so they read as one lid) on the scene's `Anim` player, keyed off the scene
## by art/block_anims.gd. Played forward on the anchor and backwards on release - a reversal halfway
## runs back from where it stands.
var _anim: AnimationPlayer = null
var _planted: bool = false
var _open: bool = false              # lying open at the clip's end: the only time it makes energy

func _ready() -> void:
	super._ready()
	moving_parts = true                 # leaves and rams move (MachineBatch copies them)
	_anim = get_node_or_null("Anim") as AnimationPlayer
	if _anim != null:
		_anim.animation_finished.connect(_on_flip_done)

## How many Falsus panels this block is worth right now: all of it lying open, nothing otherwise.
func solar_units() -> float:
	return UNITS if _open else 0.0

func _process(_delta: float) -> void:
	var m: Node = _machine()
	var planted: bool = m != null and (m.get("anchored") == true or m.get("is_base") == true)
	if planted == _planted or _anim == null:
		return
	_planted = planted
	_open = false
	if planted:
		_anim.play(&"open")
	else:
		_anim.play_backwards(&"open")

func _on_flip_done(_clip: StringName) -> void:
	_open = _planted

func _machine() -> Node:
	var p: Node = get_parent()
	if p == null or p.name != "blocks":
		return null
	return p.get_parent()
