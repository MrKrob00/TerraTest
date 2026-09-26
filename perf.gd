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

static var _acc: Dictionary = {}       # key -> usec accumulated SINCE THE LAST SNAPSHOT
static var _shown: Dictionary = {}     # last snapshot (what the panel draws), usec per frame/tick
# THE PANEL TAKES A SNAPSHOT FOUR TIMES A SECOND, NOT EVERY FRAME, so what piles up between two of
# them is several frames' worth - six at 23 fps. Printed as it was, a 5 ms grass pass read as
# 30 ms and "accounted" process time came out larger than the whole process line. So frames and
# physics ticks are counted here and each key is divided by the one it runs in.
static var _frames: int = 0
static var _ticks: int = 0

## Start of a measurement. Zero means "measuring is off", and mark() ignores a zero, so the
## call sites need no condition of their own.
static func now() -> int:
	return Time.get_ticks_usec() if enabled else 0

static func mark(key: String, t0: int) -> void:
	if t0 == 0:
		return
	_acc[key] = float(_acc.get(key, 0.0)) + float(Time.get_ticks_usec() - t0)

## Counted by the HUD: one call per rendered frame and one per physics tick.
static func frame() -> void:
	if enabled:
		_frames += 1

static func tick() -> void:
	if enabled:
		_ticks += 1

## The marks since the last call, as usec PER FRAME - or per physics TICK for the keys in
## `per_tick` (they run in _physics_process, and a tick is how the physics line is read). Reset.
static func snapshot(per_tick: Array = []) -> Dictionary:
	_shown = {}
	for k in _acc:
		var n: int = _ticks if per_tick.has(String(k)) else _frames
		_shown[k] = float(_acc[k]) / float(maxi(n, 1))
	_acc.clear()
	_frames = 0
	_ticks = 0
	return _shown

static func last() -> Dictionary:
	return _shown

static func reset() -> void:
	_acc.clear()
	_shown.clear()
	_frames = 0
	_ticks = 0
