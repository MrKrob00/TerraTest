class_name Perf
extends RefCounted

# PER-SYSTEM TIMING.
#
# Exists so that "is it physics or rendering" and "does the map really eat the CPU" are
# answered with numbers instead of opinions. The engine answers the first on its own
# (Performance.TIME_PROCESS vs TIME_PHYSICS_PROCESS vs frame time), but it will not say WHICH
# script ate the frame — everything is one lump there. Hence these marks: a system wraps its
# tick in now()/mark(), and the HUD panel (tap the FPS counter) prints the table.
#
# Measure ON THE DEVICE and in a fight: the same forty blocks lie differently in the editor,
# and the drop happens exactly when a machine comes apart. Numbers taken inside the editor
# with the debugger attached are inflated — use them for ratios, not absolutes.
#
# Switched off, a mark costs one static call per system per frame and never touches the clock:
# now() returns 0 and mark() returns immediately on a zero. That is why the calls can stay in
# the code permanently instead of hiding behind an `if`.

static var enabled: bool = false

static var _acc: Dictionary = {}       # key -> usec accumulated during the CURRENT frame
static var _shown: Dictionary = {}     # last snapshot (what the panel draws)

## Start of a measurement. Zero means "measuring is off", and mark() ignores a zero, so the
## call sites need no condition of their own.
static func now() -> int:
	return Time.get_ticks_usec() if enabled else 0

static func mark(key: String, t0: int) -> void:
	if t0 == 0:
		return
	_acc[key] = float(_acc.get(key, 0.0)) + float(Time.get_ticks_usec() - t0)

## One frame's worth of marks, and reset. Called by the panel, once per refresh.
static func snapshot() -> Dictionary:
	_shown = _acc.duplicate()
	_acc.clear()
	return _shown

static func last() -> Dictionary:
	return _shown

static func reset() -> void:
	_acc.clear()
	_shown.clear()
