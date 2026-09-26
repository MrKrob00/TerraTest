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
