extends TouchScreenButton
## THE MOVEMENT STICK: a floating stick in a bounded corner (the player: "it takes too much of the
## screen where it can appear"). A press inside the ZONE puts the base under the thumb and the stick
## follows the drag; let go, the base glides back to REST. Everything is drawn here (`_draw`), in the
## HUD's own fill and teal ring.
##
## THE NUMBERS ARE MEASURED THUMBS, NOT A SHARE OF THE SCREEN. Li et al. ("Understanding Players'
## Interaction Patterns with Mobile Game App UI via Visualizations", Chinese CHI 2021) logged where
## players' left thumbs land on a stick: first touches 15.6-25.4 mm from the bottom-left corner, the
## stick's centre 9.8-19.4 mm from the left and bottom edges. A canvas unit on a phone is ~1/12 mm
## (Main._apply_ui_scale sizes the UI physically), so the ZONE - a quarter ellipse from the corner,
## ~33 x 27 mm - holds all of that with a margin, and REST stands ~17 / 15 mm in. It was the left 33 %
## by the bottom 40 % of the screen (on a 20:9 phone ~55 x 30 mm, and wider the wider the phone) plus
## a circle round wherever the last press began, a stick 25 mm across: most of the left half.
## A share of the screen grows with the screen; a thumb does not, so the zone is in units.

## The stick's reach, which full throttle needs (~9 mm), and the knob riding on it.
const BASE_R := 110.0
const KNOB_R := 46.0
## Where the stick waits, from the bottom-left corner.
const REST := Vector2(205.0, 185.0)
## The zone a press may start the stick in: a quarter ellipse from the bottom-left corner. A press on
## the resting stick counts too, where its top reaches past the ellipse.
const ZONE := Vector2(400.0, 320.0)
## The base stays wholly on screen, this far in. The stick reads the thumb's move from where it LANDED,
## not from the base's middle: a press in the very corner put the base inward and the stick at full
## lock before the thumb moved at all.
const EDGE := 10.0
## Movements under this share of the reach are ignored, so a resting thumb does not creep.
const DEAD_ZONE: float = 0.12
## HUD controls that can stand in the zone (the anchor button, the build panels): a press on one is
## the control's, not the stick's - this `_input` runs before the GUI.
const HUD_PANELS := ["_anchor_btn", "_rotate_panel", "_hand_panel", "_menu_btn", "_handle"]
## How fast the base returns to REST and the knob re-centres, and how fast the look follows a press.
const GLIDE := 14.0
const LIGHT_IN := 12.0

const FILL := Color(0.043, 0.122, 0.149)          # hud.HUD_FILL without its alpha
const RING := Color(0.247, 0.6, 0.65)             # hud.HUD_RING
const LIT := Color(0.62, 0.95, 0.97)              # the push, and a held knob's rim

var knob_pos: Vector2 = Vector2.ZERO               # the knob in the base's own axes
var active_touch_index: int = -1

var _rest := Vector2.ZERO                          # REST on this screen, canvas units
var _landed := Vector2.ZERO                        # where the holding thumb came down
var _knob_shown := Vector2.ZERO                    # where the knob is drawn (eases to knob_pos)
var _light: float = 0.0                            # 0 resting .. 1 held

func _ready() -> void:
	if shape is CircleShape2D:
		(shape as CircleShape2D).radius = BASE_R
	place_rest(get_viewport().get_visible_rect().size)
	set_process(false)

## The HUD's relayout hands the screen over; a stick at rest moves with it.
func place_rest(screen: Vector2) -> void:
	_rest = Vector2(REST.x, screen.y - REST.y)
	if active_touch_index == -1:
		position = _rest
	queue_redraw()

# ── the finger ──────────────────────────────────────────────────────────────────────────────────

func _input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		var t := event as InputEventScreenTouch
		if t.pressed:
			if active_touch_index == -1 and claims(t.position):
				active_touch_index = t.index
				position = _base_for(t.position)
				_landed = t.position
				_set_knob(t.position)
				_knob_shown = knob_pos
				_wake()
		elif t.index == active_touch_index:
			active_touch_index = -1
			knob_pos = Vector2.ZERO
			_wake()
	elif event is InputEventScreenDrag and (event as InputEventScreenDrag).index == active_touch_index:
		_set_knob((event as InputEventScreenDrag).position)
		_knob_shown = knob_pos
		queue_redraw()

## A HIDDEN STICK LETS GO. The engine stops a TouchScreenButton's input while it is hidden
## (`touch_screen_button.cpp`, process_input follows visibility), so a thumb held on the stick while
## the garage opened lifted unseen: the stick stayed held at its last push for good, and every later
## press was refused as a second finger (the player's report).
func _notification(what: int) -> void:
	if what == NOTIFICATION_VISIBILITY_CHANGED and not is_visible_in_tree() and active_touch_index != -1:
		active_touch_index = -1
		knob_pos = Vector2.ZERO
		_wake()

## Would a press here start the stick? In the zone, or on the resting stick, and not on a HUD control.
func claims(p: Vector2) -> bool:
	if not is_visible_in_tree():
		return false
	var screen: Vector2 = get_viewport().get_visible_rect().size
	var q := Vector2(p.x / ZONE.x, (screen.y - p.y) / ZONE.y)
	var in_zone: bool = p.x >= 0.0 and p.y <= screen.y and q.length_squared() <= 1.0
	if not in_zone and p.distance_squared_to(_rest) > BASE_R * BASE_R:
		return false
	return not _over_hud(p)

## Kept for vehicle_body_3d._joystick_finger, which asks the stick's own claiming rule.
func is_touch_inside(p: Vector2) -> bool:
	return p.distance_squared_to(position) <= BASE_R * BASE_R and claims(p)

func is_touch_outside(p: Vector2) -> bool:
	return claims(p)

func _over_hud(p: Vector2) -> bool:
	var hud: Node = get_parent()
	if hud == null:
		return false
	for f in HUD_PANELS:
		var c = hud.get(f)
		if c is Control and is_instance_valid(c) and (c as Control).is_visible_in_tree() \
				and (c as Control).get_global_rect().has_point(p):
			return true
	return false

## The base under the thumb, kept wholly on screen.
func _base_for(p: Vector2) -> Vector2:
	var screen: Vector2 = get_viewport().get_visible_rect().size
	return Vector2(clampf(p.x, BASE_R + EDGE, screen.x - BASE_R - EDGE),
			clampf(p.y, BASE_R + EDGE, screen.y - BASE_R - EDGE))

func _set_knob(p: Vector2) -> void:
	knob_pos = (p - _landed).limit_length(BASE_R)

func get_joystick_dir() -> Vector2:
	var raw: Vector2 = knob_pos / BASE_R
	var length: float = raw.length()
	if length < DEAD_ZONE:
		return Vector2.ZERO
	# [DEAD_ZONE .. 1] -> [0 .. 1], or the stick would jump as it leaves the dead zone
	return raw.normalized() * clampf((length - DEAD_ZONE) / (1.0 - DEAD_ZONE), 0.0, 1.0)

# ── the picture ─────────────────────────────────────────────────────────────────────────────────

## Ticks only while something moves: the light coming up or going down, the base gliding home.
func _wake() -> void:
	set_process(true)
	queue_redraw()

func _process(delta: float) -> void:
	var held: bool = active_touch_index != -1
	_light = move_toward(_light, 1.0 if held else 0.0, delta * LIGHT_IN)
	var k: float = 1.0 - exp(-GLIDE * delta)
	if not held:
		position = position.lerp(_rest, k)
		_knob_shown = _knob_shown.lerp(Vector2.ZERO, k)
		if position.distance_squared_to(_rest) < 0.25 and _knob_shown.length_squared() < 0.25:
			position = _rest
			_knob_shown = Vector2.ZERO
	queue_redraw()
	if (held and _light >= 1.0) or (not held and _light <= 0.0 and position == _rest and _knob_shown == Vector2.ZERO):
		set_process(false)

func _draw() -> void:
	var a: float = lerpf(0.55, 1.0, _light)          # a resting stick is there, not loud
	# the base: a dark disc in the HUD's ring, a fainter ring at the dead zone's far side
	draw_circle(Vector2.ZERO, BASE_R, Color(FILL, lerpf(0.42, 0.62, _light)))
	draw_arc(Vector2.ZERO, BASE_R, 0.0, TAU, 72, Color(RING, 0.85 * a), 3.0, true)
	draw_arc(Vector2.ZERO, BASE_R - 9.0, 0.0, TAU, 72, Color(RING, 0.22 * a), 1.5, true)
	draw_arc(Vector2.ZERO, BASE_R * 0.5, 0.0, TAU, 48, Color(RING, 0.16 * a), 1.5, true)
	var push: Vector2 = _knob_shown / BASE_R
	var amount: float = clampf((push.length() - DEAD_ZONE) / (1.0 - DEAD_ZONE), 0.0, 1.0)
	var dir: Vector2 = push.normalized() if push.length_squared() > 0.0001 else Vector2.ZERO
	# four chevrons pointing out; the ones the stick leans to light up
	for d in [Vector2.UP, Vector2.RIGHT, Vector2.DOWN, Vector2.LEFT]:
		var lean: float = maxf(dir.dot(d), 0.0) * amount
		var col: Color = Color(RING, 0.55 * a).lerp(Color(LIT, 1.0), lean)
		_chevron(d * (BASE_R - 24.0), d, 9.0, col)
	# the push: an arc just outside the rim where the stick leans, longer and brighter the further
	# (on the rim itself the knob, out at full reach, covered it)
	if amount > 0.0:
		var ang: float = dir.angle()
		var half: float = lerpf(0.3, 0.75, amount)
		draw_arc(Vector2.ZERO, BASE_R + 8.0, ang - half, ang + half, 24, Color(LIT, 0.35 + 0.55 * amount), 5.0, true)
	# the knob: a soft shade under it, the body, its rim, a lit edge up and to the left, a core
	var kp: Vector2 = _knob_shown
	var kr: float = KNOB_R * lerpf(1.0, 1.08, _light)
	draw_circle(kp, kr + 4.0, Color(0.0, 0.0, 0.0, 0.22 * a))
	draw_circle(kp, kr, Color(FILL.lerp(RING, lerpf(0.28, 0.42, _light)), lerpf(0.82, 0.96, _light)))
	draw_arc(kp, kr, 0.0, TAU, 48, Color(RING.lerp(LIT, _light), a), 3.0, true)
	draw_arc(kp, kr - 7.0, PI * 1.05, PI * 1.6, 16, Color(1.0, 1.0, 1.0, 0.28 * a), 3.0, true)
	draw_arc(kp, kr * 0.45, 0.0, TAU, 32, Color(RING.lerp(LIT, _light), 0.55 * a), 2.0, true)
	draw_circle(kp, 3.5, Color(LIT, 0.8 * a))

func _chevron(at: Vector2, d: Vector2, s: float, col: Color) -> void:
	var side := Vector2(-d.y, d.x)
	var tip: Vector2 = at + d * s * 0.6
	draw_polyline(PackedVector2Array([tip - d * s + side * s, tip, tip - d * s - side * s]), col, 3.0, true)
