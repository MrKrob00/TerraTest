# MARLIT WIRELESS CHARGER: wireless_charger.gd at Marlit's numbers, the player's: twice the reach of
# the Falsus charger (40 m against 20) at 60% of its rate (75 energy a second against 125) - a
# charger that tops a base up from across a vein field rather than one that refills a fight.
# Everything it does - own faction only, never its own machine, a full receiver is skipped - is the
# parent's; only the numbers and, with its model, the moving parts are this file's.
extends "res://blocks/scripts/wireless_charger.gd"

const MARLIT_RANGE := 40.0
const MARLIT_RATE := 75.0

func _init() -> void:
	charge_range = MARLIT_RANGE
	charge_rate = MARLIT_RATE
