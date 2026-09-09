extends Control
## The menu's own backdrop and its own loading screen.
##
## It sits on a CanvasLayer BELOW the menu's UI, so it hides the 3D stage and nothing else: while
## the ground behind the menu is being computed the player still has PLAY, the slots, the news and
## the settings under their thumb. That is the whole reason this exists instead of the game's
## loading screen (`loading_screen.gd`), which covers everything and blocks input - correct when
## the scene itself is not ready, wrong for scenery.
##
## It also has a second job: with the menu fight switched off (`G.menu_battles`) there is no map and
## no machines at all, and this stays up permanently as the backdrop. Same node, same look, one flag
## apart - a separate "static picture" would be a second thing to keep in style.
##
## The look is a survey chart (see menu_backdrop.gdshader): contour lines of the same value noise
## the terrain is built from. Deliberately not the game loading screen's glitch language.

## Fade in and out. In is quicker than out: covering hides a swap the player should not see, while
## uncovering is the moment the world appears and can afford to take its time.
const FADE_IN := 0.35
const FADE_OUT := 0.55
## Segments in the meter. Enough to read as progress, few enough that each one is a visible step.
const SEGMENTS := 24
const PLATE := Vector2(320.0, 54.0)

const ACCENT := Color(0.35, 0.85, 0.92)
const TEXT := Color(0.88, 0.97, 0.99)
const DIM := Color(0.42, 0.62, 0.68)

@onready var _pattern: ColorRect = $Pattern

var _alpha: float = 1.0          # what is on screen
var _target: float = 1.0         # where it is going
var _idle: bool = false          # menu fight off: never uncover
var _readout: bool = true        # show the loading plate (a swap cover does not)
var _step: String = ""
var _frac: float = -1.0          # < 0 = no number yet, the meter runs instead
var _shown_frac: float = 0.0     # smoothed, so the meter does not jump between passes
var _t: float = 0.0

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE     # the menu below stays clickable through it
	modulate.a = _alpha

func _process(delta: float) -> void:
	_t += delta
	var speed: float = 1.0 / (FADE_IN if _target > _alpha else FADE_OUT)
	_alpha = move_toward(_alpha, _target, delta * speed)
	modulate.a = _alpha
	visible = _alpha > 0.004
	if not visible:
		return
	# The sweep is the "working" signal: it belongs to a load, not to a backdrop with nothing behind
	# it. Idle keeps the chart and drops the sweep.
	var mat: ShaderMaterial = _pattern.material as ShaderMaterial
	if mat != null:
		mat.set_shader_parameter("energy", 1.0 if (_readout and not _idle) else 0.0)
	if _frac >= 0.0:
		_shown_frac = lerpf(_shown_frac, _frac, clampf(delta * 6.0, 0.0, 1.0))
	if _readout and not _idle:
		queue_redraw()

# ── What the stage tells it ──────────────────────────────────────────────────
## Cover the stage. `loading` also puts the readout up; a plain cover is for the round swap, where
## the wait is a fraction of a second and a progress plate would only blink.
func cover(loading: bool) -> void:
	_readout = loading
	_target = 1.0
	if loading:
		_shown_frac = 0.0
	queue_redraw()

## Uncover, unless the fight is off - then the backdrop IS the menu and stays.
func reveal() -> void:
	if _idle:
		return
	_target = 0.0

## Menu fight off: stay up for good. Turning it back on releases the backdrop the usual way.
func set_idle(on: bool) -> void:
	_idle = on
	if on:
		_readout = false
		_target = 1.0

## Where the ground is. `frac` below zero means the stage cannot say yet (a baked map being read),
## and the meter runs instead of filling.
func set_progress(step: String, frac: float) -> void:
	_step = step
	_frac = frac

# ── Readout ──────────────────────────────────────────────────────────────────
## A survey plate in the middle of the screen: the menu's own controls live bottom-left and the news
## top-right, so the centre is the one place nothing has to move out of the way.
func _draw() -> void:
	if not _readout or _idle:
		return
	var font := get_theme_default_font()
	var fs: int = 13
	var org := Vector2((size.x - PLATE.x) * 0.5, size.y * 0.5 - PLATE.y * 0.5)
	# Corner ticks instead of a box: a full frame here would read as a dialog the player has to
	# answer, and there is nothing to answer.
	var tick: float = 10.0
	for c in [Vector2(0, 0), Vector2(PLATE.x, 0), Vector2(0, PLATE.y), Vector2(PLATE.x, PLATE.y)]:
		var sx: float = 1.0 if c.x < PLATE.x * 0.5 else -1.0
		var sy: float = 1.0 if c.y < PLATE.y * 0.5 else -1.0
		draw_line(org + c, org + c + Vector2(tick * sx, 0.0), ACCENT * Color(1, 1, 1, 0.7), 1.0)
		draw_line(org + c, org + c + Vector2(0.0, tick * sy), ACCENT * Color(1, 1, 1, 0.7), 1.0)

	var caption: String = _step.to_upper() if _step != "" else "SURVEYING TERRAIN"
	draw_string(font, org + Vector2(2.0, 16.0), caption, HORIZONTAL_ALIGNMENT_LEFT,
			PLATE.x - 46.0, fs, TEXT)
	if _frac >= 0.0:
		draw_string(font, org + Vector2(PLATE.x - 44.0, 16.0), "%d%%" % int(_shown_frac * 100.0),
				HORIZONTAL_ALIGNMENT_RIGHT, 44.0, fs, ACCENT)

	# The meter is SEGMENTED, not a bar: the game's other loading screen already owns the smooth
	# bar, and separate cells make slow progress visible - one more cell is a change you can see,
	# two more pixels of a bar are not.
	var seg_w: float = PLATE.x / float(SEGMENTS)
	var y: float = org.y + 30.0
	var lit: float = _shown_frac * float(SEGMENTS)
	for i in SEGMENTS:
		var r := Rect2(org.x + float(i) * seg_w + 1.0, y, seg_w - 2.0, 6.0)
		var on: bool = float(i) < lit
		if _frac < 0.0:
			# Nothing to fill yet: a short group of cells runs along the meter so the screen says
			# "working" rather than "stuck at zero".
			var head: float = fmod(_t * 9.0, float(SEGMENTS + 6)) - 6.0
			on = float(i) <= head and float(i) > head - 5.0
		draw_rect(r, ACCENT * Color(1, 1, 1, 0.85) if on else DIM * Color(1, 1, 1, 0.22), true)
	# The line under the meter carries quarter ticks - the same trick as the game's loading bar, so
	# the two screens are cousins even though they look nothing alike.
	draw_line(Vector2(org.x, y + 10.0), Vector2(org.x + PLATE.x, y + 10.0),
			ACCENT * Color(1, 1, 1, 0.20), 1.0)
	for i in range(1, 4):
		var tx: float = org.x + PLATE.x * (float(i) / 4.0)
		draw_line(Vector2(tx, y + 10.0), Vector2(tx, y + 14.0), ACCENT * Color(1, 1, 1, 0.35), 1.0)
