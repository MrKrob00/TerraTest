# touch_buttons.gd — autoload: a button answers ANY finger, not only the first one.
#
# Godot turns only touch index 0 into a mouse event, and BaseButton listens to the mouse and to
# nothing else. A second finger on a button still reaches it — the viewport hands the
# InputEventScreenTouch to the Control under the finger (`gui.touch_focus`) and stops it there —
# but the button ignores it. So with one finger on the movement joystick (a TouchScreenButton,
# which takes any index) no Control button on screen could be pressed: not the inventory, not the
# garage's X. TouchScreenButtons (BUILD, fire) worked, which is why it looked random.
#
# The bridge listens to `gui_input` of every BaseButton as it enters the tree and presses it for
# a finger other than the first. Index 0 is left alone: the emulated mouse already clicks with it,
# and answering it here too would press every button twice.
extends Node

var _down: Dictionary = {}   # touch index -> button it went down on

func _ready() -> void:
	get_tree().node_added.connect(_on_node_added)
	for n in get_tree().root.find_children("*", "BaseButton", true, false):
		_on_node_added(n)

func _on_node_added(n: Node) -> void:
	if n is BaseButton and not n.gui_input.is_connected(_on_button_input):
		n.gui_input.connect(_on_button_input.bind(n))
		n.pressed.connect(_click)                # every button in the game clicks: one door

func _click() -> void:
	Sfx.ui("click")

func _on_button_input(ev: InputEvent, b: BaseButton) -> void:
	var t := ev as InputEventScreenTouch
	if t == null or t.index == 0 or not is_instance_valid(b) or b.disabled:
		return
	b.accept_event()
	var on_press: bool = b.action_mode == BaseButton.ACTION_MODE_BUTTON_PRESS
	if t.pressed:
		_down[t.index] = b
		if on_press:
			_fire(b)
		return
	var was: Variant = _down.get(t.index)
	_down.erase(t.index)
	# Released on the button it went down on - the same rule a mouse click follows.
	if on_press or was != b or not Rect2(Vector2.ZERO, b.size).has_point(t.position):
		return
	_fire(b)

func _fire(b: BaseButton) -> void:
	if b is OptionButton or b is MenuButton:
		b.call("show_popup")
		return
	if b.toggle_mode:
		# A button in a group cannot be switched off by pressing it again, same as with the mouse.
		if b.button_pressed and b.button_group != null and not b.button_group.allow_unpress:
			return
		b.button_pressed = not b.button_pressed
	b.pressed.emit()

# ── WHERE A TouchScreenButton TAKES A FINGER ─────────────────────────────────────────────────────
# The engine tests the SHAPE about the node's origin, moved to the texture's middle only when the
# button has a texture and `shape_centered` (touch_screen_button.cpp, _is_point_inside). A button
# drawn by code has no texture, so its shape stands centred ON the node - the HUD's ATTACK and
# BUILD buttons are placed by their middle for that reason. Three places asked this question with
# three copies of the answer (the camera's "not my finger", the world tap's "over the HUD", the
# tutorial's finger), and two of them took a textureless button's area from its corner.

## The press area in the button's own axes (the shape's bounding box for a circle).
static func local_area(b: TouchScreenButton) -> Rect2:
	var mid := _shape_mid(b)
	if b.shape != null:
		var r: Rect2 = b.shape.get_rect()
		return Rect2(r.position + mid, r.size)
	if b.texture_normal != null:
		return Rect2(Vector2.ZERO, b.texture_normal.get_size())
	return Rect2()

## Does a finger at a canvas point land on the button - the engine's own test, a circle as a circle.
static func hits(b: TouchScreenButton, canvas_pos: Vector2) -> bool:
	var local: Vector2 = b.get_global_transform_with_canvas().affine_inverse() * canvas_pos
	if b.shape is CircleShape2D:
		return local.distance_to(_shape_mid(b)) <= (b.shape as CircleShape2D).radius
	return local_area(b).has_point(local)

static func _shape_mid(b: TouchScreenButton) -> Vector2:
	if b.shape_centered and b.texture_normal != null:
		return b.texture_normal.get_size() * 0.5
	return Vector2.ZERO
