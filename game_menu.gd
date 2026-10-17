extends CanvasLayer
## THE IN-GAME MENU (the player: "Surrender and Main menu have to be searched for, a player will not
## find them at once"). They sat at the bottom of the garage's SETTINGS -> GAME, four taps in. Now one
## card over the world - Continue, Settings, Main menu, Surrender - opened by the HUD's menu button
## (`hud._pause_btn`, top right) and by the phone's Back key, which used to quit the app on the spot.
## The world does NOT pause: nothing in the game pauses, and a paused tree stops the terrain's queues,
## the music and the save timer with it. SURRENDER ASKS TWICE INSIDE THE CARD (`CONFIRM_TIME`):
## nothing irreversible is one tap. This script is also the one door for both actions
## (`to_main_menu`, `surrender`), which the stuck offer (`stuck_watch.gd`) uses too.

const LAYER := 65                 # over the HUD (1) and the stuck offer (55), under the FPS readout
const CARD_W := 400.0
const BTN_H := 58.0
const CONFIRM_TIME := 4.0
const FILL := Color(0.043, 0.122, 0.149, 0.96)     # hud.HUD_FILL, a little denser over the world
const RING := Color(0.247, 0.6, 0.65)              # hud.HUD_RING
const INK := Color(0.88, 0.96, 0.98)
const DIM := Color(0.6, 0.72, 0.76)
const DANGER := Color(0.95, 0.5, 0.45)

var hud: Node = null
var _root: Control
var _card: PanelContainer
var _surr: Button
var _surr_hint: Label
var _confirm_t: float = 0.0

func _ready() -> void:
	layer = LAYER
	visible = false
	_build()
	set_process(false)

func is_open() -> bool:
	return visible

func toggle() -> void:
	if visible:
		close()
	else:
		open()

func open() -> void:
	_confirm_t = 0.0
	_refresh_surrender()
	visible = true
	_card.pivot_offset = _card.size * 0.5
	_card.scale = Vector2(0.92, 0.92)
	_card.modulate.a = 0.0
	var tw := create_tween().set_parallel(true)
	tw.tween_property(_card, "scale", Vector2.ONE, 0.16).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw.tween_property(_card, "modulate:a", 1.0, 0.12)

func close() -> void:
	visible = false
	_confirm_t = 0.0
	set_process(false)

func _process(delta: float) -> void:
	_confirm_t -= delta
	if _confirm_t <= 0.0:
		_refresh_surrender()
		set_process(false)

# ── The one door for each action ─────────────────────────────────────────────────

## Saves first: a scene change frees world_persist, and without the call everything since the last
## autosave would be left in the slot. THE PROVING GROUND'S FLAG IS DROPPED HERE, at the one door back
## to the menu (`G.leave_proving_ground`): it lives in an autoload, and a forgotten one would make the
## next REAL game flat, endless and unsaved.
static func to_main_menu(tree: SceneTree) -> void:
	var wp: Node = tree.get_first_node_in_group("world_persist")
	if wp != null and wp.has_method("_save_world"):
		wp._save_world()                     # refuses by itself on the proving ground
	G.save_now()
	G.leave_proving_ground()
	tree.change_scene_to_file("res://menu.tscn")

## SURRENDER IS THE CABIN'S OWN DEATH (`vehicle_body_3d.surrender`). The garage goes first: the
## death screen and the wreck are what is left to see.
static func surrender(hud_node: Node) -> bool:
	var v: Node = current_vehicle(hud_node)
	if v == null or not v.has_method("can_surrender") or not v.can_surrender():
		return false
	var tu = hud_node.get("_tech_ui") if hud_node != null else null
	if tu is Control and is_instance_valid(tu) and (tu as Control).visible:
		(tu as Control).hide()
	return v.surrender()

static func current_vehicle(hud_node: Node) -> Node:
	if hud_node == null or not is_instance_valid(hud_node):
		return null
	var cc: Node = hud_node.get_tree().get_first_node_in_group("camera_controller")
	if cc == null or not ("current_vehicle" in cc):
		return null
	var v = cc.current_vehicle
	return v if is_instance_valid(v) else null

# ── The card ─────────────────────────────────────────────────────────────────────

func _build() -> void:
	_root = Control.new()
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_root)
	var shade := ColorRect.new()
	shade.color = Color(0, 0, 0, 0.5)
	shade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	shade.gui_input.connect(_on_shade_input)     # a tap beside the card is "continue"
	_root.add_child(shade)
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(center)
	_card = PanelContainer.new()
	_card.custom_minimum_size = Vector2(CARD_W, 0)
	var sb := StyleBoxFlat.new()
	sb.bg_color = FILL
	sb.border_color = RING
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(10)
	sb.content_margin_left = 24.0
	sb.content_margin_right = 24.0
	sb.content_margin_top = 18.0
	sb.content_margin_bottom = 22.0
	_card.add_theme_stylebox_override("panel", sb)
	center.add_child(_card)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 10)
	_card.add_child(col)

	var title := Label.new()
	title.text = "MENU"                        # scene-style text: translates itself (auto_translate)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 24)
	title.add_theme_color_override("font_color", INK)
	col.add_child(title)
	var line := ColorRect.new()
	line.color = Color(RING, 0.5)
	line.custom_minimum_size = Vector2(0, 2)
	col.add_child(line)

	col.add_child(_button("CONTINUE", RING, close))
	col.add_child(_button("SETTINGS", RING, _on_settings))
	col.add_child(_button("MAIN MENU", RING, _on_main_menu))
	col.add_child(_hint("Your world is saved. Pick another slot in the menu."))
	var gap := Control.new()
	gap.custom_minimum_size = Vector2(0, 8)
	col.add_child(gap)
	_surr = _button("SURRENDER", DANGER, _on_surrender)
	col.add_child(_surr)
	_surr_hint = _hint("Blows up this machine's cabin: its blocks fall where it stands, and you start again in a new cabin.")
	col.add_child(_surr_hint)

func _button(text: String, edge: Color, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(0, BTN_H)
	b.focus_mode = Control.FOCUS_NONE
	b.add_theme_font_size_override("font_size", 20)
	b.add_theme_color_override("font_color", INK if edge == RING else edge)
	b.add_theme_color_override("font_hover_color", Color.WHITE)
	b.add_theme_color_override("font_pressed_color", Color.WHITE)
	b.add_theme_color_override("font_disabled_color", Color(DIM, 0.5))
	for st in ["normal", "hover", "pressed", "disabled"]:
		var s := StyleBoxFlat.new()
		s.bg_color = Color(0.07, 0.19, 0.23, 1.0) if st == "normal" else \
				(Color(0.1, 0.27, 0.32) if st != "disabled" else Color(0.05, 0.12, 0.14))
		if st == "pressed":
			s.bg_color = Color(edge, 0.35)
		s.border_color = Color(edge, 0.3 if st == "disabled" else 0.9)
		s.set_border_width_all(2)
		s.set_corner_radius_all(6)
		b.add_theme_stylebox_override(st, s)
	b.pressed.connect(cb)
	return b

func _hint(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.add_theme_font_size_override("font_size", 13)
	l.add_theme_color_override("font_color", DIM)
	return l

func _on_shade_input(e: InputEvent) -> void:
	if (e is InputEventMouseButton and e.pressed) or (e is InputEventScreenTouch and e.pressed):
		close()

func _on_settings() -> void:
	close()
	if hud != null and hud.has_method("open_garage_tab"):
		hud.open_garage_tab(&"settings")

func _on_main_menu() -> void:
	close()
	to_main_menu(get_tree())

func _refresh_surrender() -> void:
	var v: Node = current_vehicle(hud)
	var can: bool = v != null and v.has_method("can_surrender") and v.can_surrender()
	_surr.disabled = not can
	_surr.text = tr("SURRENDER")
	_surr_hint.text = tr("Blows up this machine's cabin: its blocks fall where it stands, and you start again in a new cabin.") \
			if can else tr("Only a machine with a cabin can surrender.")

func _on_surrender() -> void:
	if _confirm_t <= 0.0:
		_confirm_t = CONFIRM_TIME
		_surr.text = tr("Tap again to surrender")
		set_process(true)
		return
	close()
	surrender(hud)
