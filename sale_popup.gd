extends Label3D
# "+N$" OVER A SELLER AT EVERY SALE (the player's call: "a pretty +N$ pop-up", in place of the screen
# across the seller's front, which is gone). Gold on a dark outline, it POPS (overshoots its size and
# settles), rises and fades - text, no particles (rule 11). A line selling twice a second would stack
# a column of them, so a sale inside MERGE of the last pop-up ADDS to it and pops it again: one number
# counting up reads as "money is coming in", a column of +6s reads as noise.
#
# Screen-sized (`fixed_size`): it lives LIFE seconds and says one thing, so it should read the same
# from any distance the camera allows; past SHOW_DIST nobody is watching that seller and none is made.

const LIFE := 1.4
const RISE := 1.5               # m over its life
const FADE := 0.45              # s at the end it takes to go
const MERGE := 0.7              # s: a sale this soon after the last one adds to it
const POP := 0.28               # s of the overshoot
const SHOW_DIST := 70.0
const GOLD := Color(1.0, 0.84, 0.25)

var amount: int = 0
var _age: float = 0.0
var _base_y: float = 0.0
var _spawn_y: float = 0.0

## A new pop-up at `at` (world), or null when the camera is too far to see it.
static func spawn(owner_node: Node, at: Vector3, amt: int) -> Label3D:
	var cam := owner_node.get_viewport().get_camera_3d() if owner_node.is_inside_tree() else null
	if cam == null or cam.global_position.distance_squared_to(at) > SHOW_DIST * SHOW_DIST:
		return null
	var p = load("res://sale_popup.gd").new()
	var root: Node = owner_node.get_tree().current_scene
	if root == null:
		root = owner_node.get_tree().root
	root.add_child(p)
	p.global_position = at
	p._spawn_y = at.y
	p._base_y = at.y
	p.add(amt)
	return p

func _init() -> void:
	billboard = BaseMaterial3D.BILLBOARD_ENABLED
	fixed_size = true
	pixel_size = 0.0011
	font_size = 48
	outline_size = 14
	modulate = GOLD
	outline_modulate = Color(0.16, 0.08, 0.0, 1.0)
	no_depth_test = true
	render_priority = 10
	outline_render_priority = 9
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	set_meta("block_fx", true)

## Still young enough to take another sale.
func can_merge() -> bool:
	return _age < MERGE

func add(amt: int) -> void:
	amount += amt
	text = "+%d$" % amount
	# carry on rising from where it is, but a line selling for a minute does not climb away
	if is_inside_tree():
		_base_y = minf(global_position.y, _spawn_y + RISE * 0.5)
	_age = 0.0
	scale = Vector3.ONE * 0.35

func _process(delta: float) -> void:
	_age += delta
	if _age >= LIFE:
		queue_free()
		return
	var k := _age / LIFE
	global_position.y = _base_y + RISE * (1.0 - pow(1.0 - k, 2.0))
	# overshoot to 1.3 and settle at 1.0
	var s := 1.0
	if _age < POP:
		var u := _age / POP
		s = lerpf(0.35, 1.3, sin(u * PI * 0.5)) if u < 0.6 else lerpf(1.3, 1.0, (u - 0.6) / 0.4)
	scale = Vector3.ONE * s
	var a := clampf((LIFE - _age) / FADE, 0.0, 1.0)
	modulate.a = a
	outline_modulate.a = a
