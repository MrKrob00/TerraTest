extends CanvasLayer
# A FACTION'S LICENCE IS ANNOUNCED IN THE MIDDLE OF THE SCREEN, WITH THE BLOCKS IT OPENS (the player's
# call, after TerraTech's "Licence upgrade" card): the faction's emblem and name, a line saying what
# happened, and under it the PORTRAITS of the blocks that are now the player's to research or already
# researched. It used to be one System line in the dialogue strip - which scrolls away, names nothing
# and shows no picture - for the biggest step in the game, a second faction.
#
# Two doors raise it, both signals of G: `licence_granted` (a faction opens: its blocks of grade 1)
# and `grade_up` (a faction's next level: that grade's blocks). Several at once (a quest that both
# licenses and levels up) QUEUE and show one after another. Built in code like every window whose
# content is data; centred by a CenterContainer (its minimum size changes as the grid fills).

const ICON := 72
const COLS := 4

var _queue: Array = []          # [{title, body, faction, blocks}]
var _root: Control = null

func _init() -> void:
	layer = 60

## Announce `faction` opening (licence) or reaching `level` (grade-up).
func announce(faction: String, level: int, licence: bool) -> void:
	var fname: String = tr(String((G.FACTIONS.get(faction, {}) as Dictionary).get("name", faction)))
	var src: Array = _licence_blocks(faction) if licence else G.blocks_of_grade(faction, level)
	var blocks: Array = []
	for bt in src:
		blocks.append(int(bt))
	blocks.sort_custom(_by_order)
	var e := {"faction": faction, "blocks": blocks}
	if licence:
		e["title"] = tr("Licence granted: %s") % fname
		e["body"] = tr("Congratulations! %s has licensed you. Their blocks can now be researched in the tech tree; the first ones are already yours.") % fname
	else:
		e["title"] = tr("%s licence: level %d") % [fname, level]
		e["body"] = tr("Your %s licence has gone up. These blocks can now be researched in the tech tree.") % fname
	_queue.append(e)
	if _root == null:
		_show_next()

func _by_order(a: int, b: int) -> bool:
	return G.block_order(a) < G.block_order(b)

func _licence_blocks(faction: String) -> Array:
	var out: Array = []
	for bt in G.BLOCK_META:
		var m: Dictionary = G.BLOCK_META[bt]
		if String(m["f"]) == faction and int(m["g"]) <= 1:
			out.append(int(bt))
	return out

func _show_next() -> void:
	if _queue.is_empty():
		return
	var e: Dictionary = _queue.pop_front()
	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_root)
	var dim := ColorRect.new()
	dim.color = Color(0.0, 0.02, 0.04, 0.55)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(dim)
	var cc := CenterContainer.new()
	cc.set_anchors_preset(Control.PRESET_FULL_RECT)
	cc.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(cc)
	var panel := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.06, 0.11, 0.15, 0.94)
	sb.border_color = Color(0.35, 0.75, 0.85, 0.9)
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(10)
	sb.set_content_margin_all(22)
	panel.add_theme_stylebox_override("panel", sb)
	panel.custom_minimum_size = Vector2(560, 0)
	cc.add_child(panel)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 14)
	panel.add_child(vb)
	# emblem + title
	var head := HBoxContainer.new()
	head.alignment = BoxContainer.ALIGNMENT_CENTER
	head.add_theme_constant_override("separation", 14)
	vb.add_child(head)
	var em: Texture2D = G.faction_emblem(String(e["faction"]))
	if em != null:
		var tr_em := TextureRect.new()
		tr_em.texture = em
		tr_em.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		tr_em.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		tr_em.custom_minimum_size = Vector2(56, 56)
		head.add_child(tr_em)
	var title := Label.new()
	title.text = String(e["title"])
	title.add_theme_font_size_override("font_size", 30)
	title.add_theme_color_override("font_color", Color(1.0, 0.86, 0.35))
	head.add_child(title)
	var body := Label.new()
	body.text = String(e["body"])
	body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.custom_minimum_size = Vector2(520, 0)
	body.add_theme_font_size_override("font_size", 19)
	body.add_theme_color_override("font_color", Color(0.82, 0.9, 0.95))
	vb.add_child(body)
	# the blocks
	var blocks: Array = e["blocks"]
	if not blocks.is_empty():
		var grid := GridContainer.new()
		grid.columns = mini(COLS if blocks.size() <= 8 else COLS + 1, blocks.size())
		grid.add_theme_constant_override("h_separation", 12)
		grid.add_theme_constant_override("v_separation", 10)
		var gc := CenterContainer.new()
		gc.add_child(grid)
		vb.add_child(gc)
		for bt in blocks:
			grid.add_child(_block_cell(int(bt)))
	var ok := Button.new()
	ok.text = tr("Continue")
	ok.custom_minimum_size = Vector2(220, 52)
	ok.add_theme_font_size_override("font_size", 22)
	ok.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	for st in ["normal", "hover", "pressed", "focus"]:
		var bs := StyleBoxFlat.new()
		bs.bg_color = Color(0.85, 0.66, 0.15) if st != "pressed" else Color(0.7, 0.52, 0.1)
		if st == "hover":
			bs.bg_color = Color(0.95, 0.76, 0.25)
		bs.set_corner_radius_all(8)
		ok.add_theme_stylebox_override(st, bs)
	for cn in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color"]:
		ok.add_theme_color_override(cn, Color(0.1, 0.07, 0.02))
	ok.pressed.connect(_close)
	vb.add_child(ok)
	# a pop in, not a cut
	panel.pivot_offset = Vector2(280, 160)
	panel.scale = Vector2.ONE * 0.85
	_root.modulate.a = 0.0
	var tw := create_tween().set_parallel(true)
	tw.tween_property(_root, "modulate:a", 1.0, 0.18)
	tw.tween_property(panel, "scale", Vector2.ONE, 0.25).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)

func _block_cell(bt: int) -> Control:
	var v := VBoxContainer.new()
	v.custom_minimum_size = Vector2(ICON + 40, 0)
	v.add_theme_constant_override("separation", 2)
	var frame := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	var have: bool = G.researched.has(bt)
	sb.bg_color = Color(0.1, 0.17, 0.22, 1.0)
	sb.border_color = Color(1.0, 0.86, 0.35, 0.9) if have else Color(0.3, 0.45, 0.52, 0.8)
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(6)
	sb.set_content_margin_all(4)
	frame.add_theme_stylebox_override("panel", sb)
	frame.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	v.add_child(frame)
	var icons: Node = get_node_or_null("/root/Icons")
	var tex: Texture2D = icons.get_icon(bt) if icons != null else null
	var pic := TextureRect.new()
	pic.custom_minimum_size = Vector2(ICON, ICON)
	pic.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	pic.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	pic.texture = tex
	frame.add_child(pic)
	var name_l := Label.new()
	name_l.text = G.block_name(bt)
	name_l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	name_l.custom_minimum_size = Vector2(ICON + 40, 0)
	name_l.add_theme_font_size_override("font_size", 13)
	name_l.add_theme_color_override("font_color", Color(0.75, 0.85, 0.9))
	v.add_child(name_l)
	return v

func _close() -> void:
	if _root != null:
		_root.queue_free()
		_root = null
	_show_next()
