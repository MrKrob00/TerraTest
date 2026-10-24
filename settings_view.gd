class_name SettingsView
extends HBoxContainer
## THE SETTINGS SCREEN, ONE FOR THE MENU AND THE GARAGE.
##
## The menu had three fixed columns and the garage one long list with "— GRAPHICS —" dividers;
## the same camera slider lived in two copies, and the graphics could only be reached from inside
## a world. Now both hosts drop this view in and say what differs (`contexts` for the music
## list, `in_game` for the rows that need a machine, `actions` for the garage's own buttons).
##
## Layout follows landscape mobile games (Genshin, PUBG Mobile, Crossout Mobile): a rail of
## categories on the left, one category's rows on the right, every row a full-width card with the
## name and a one-line hint on the left and the control on the right, so a thumb never has to aim
## at a 14 px check box. Look follows the shop (shop v2 in tech_ui): dark metal, one amber accent.
##
## EVERYTHING APPLIES AT ONCE. Graphics go through Main's own setters when the world is up (the
## single door - Main applies and saves), and straight into settings.json from the menu, which
## Main reads on its next start. Nothing here keeps a copy of a value.

signal lang_changed
signal menu_fight_changed(on: bool)

const INK := Color(0.9, 0.9, 0.93)
const DIM := Color(0.56, 0.57, 0.64)
const BG := Color(0.07, 0.07, 0.085, 0.96)
const CARD := Color(0.115, 0.113, 0.135)
const CARD_HI := Color(0.14, 0.138, 0.163)
const RAIL := Color(0.085, 0.085, 0.1)
const ACCENT := Color(0.86, 0.58, 0.22)
const GROOVE := Color(0.04, 0.04, 0.05)
const ROW_H := 68.0

enum Cat { GRAPHICS, AUDIO, CONTROLS, GAME, LANGUAGE }
const CAT_WORDS := ["GRAPHICS", "AUDIO", "CONTROLS", "GAME", "LANGUAGE"]

## Names in their own language: whoever opened a foreign one by mistake has to find his own
## without reading a word around it.
const LANG_NAMES := {
	"en": "English", "ru": "Русский", "uk": "Українська", "es": "Español",
	"pt_BR": "Português (Brasil)", "de": "Deutsch", "fr": "Français", "tr": "Türkçe",
	"ja": "日本語", "ko": "한국어", "zh_CN": "简体中文", "id": "Bahasa Indonesia",
}

## Graphics presets. MEDIUM is exactly Main's defaults, so a fresh install reads MEDIUM.
const PRESETS := {
	"low": {"auto_fps": false, "manual_scale": 0.6, "shadows_enabled": false, "shadows_engine": false,
			"view_distance": 800.0, "hlod_on": true},
	"medium": {"auto_fps": true, "manual_scale": 0.75, "shadows_enabled": true, "shadows_engine": false,
			"view_distance": 1400.0, "hlod_on": true},
	"high": {"auto_fps": false, "manual_scale": 1.0, "shadows_enabled": true, "shadows_engine": true,
			"view_distance": 2600.0, "hlod_on": true},
}
const PRESET_ORDER := [["low", "LOW"], ["medium", "MEDIUM"], ["high", "HIGH"]]
## Defaults of every graphics key this view touches (Main's own initial values).
const GFX_DEFAULTS := {"auto_fps": true, "manual_scale": 0.75, "shadows_enabled": true,
		"shadows_soft": true, "shadows_engine": false, "view_distance": 1400.0, "hlod_on": true,
		"ui_scale": 1.0, "fullscreen": false, "terrain_cache": 1.0}
const GFX_SETTERS := {"auto_fps": "set_auto_fps", "manual_scale": "set_manual_scale",
		"shadows_enabled": "set_shadows_enabled", "shadows_soft": "set_shadows_soft",
		"shadows_engine": "set_shadows_engine", "view_distance": "set_view_distance",
		"hlod_on": "set_hlod", "terrain_cache": "set_terrain_cache", "ui_scale": "set_ui_scale", "fullscreen": "set_fullscreen"}

## Music lists the AUDIO page shows (`MusicManager.Ctx` values).
var contexts: Array = []
## Garage: rows that need a world (move controls, UI size, the garage's action buttons).
var in_game: bool = false
## Extra rows at the bottom of GAME: [caption, hint, Callable, danger: bool].
var actions: Array = []

var _cat: int = Cat.GRAPHICS
var _rail: VBoxContainer
var _rail_btns: Array = []
var _list: VBoxContainer
var _scroll: ScrollContainer
var _title: Label
var _preset_btns: Dictionary = {}
var _font_b: FontVariation

func _ready() -> void:
	add_theme_constant_override("separation", 0)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	_font_b = FontVariation.new()
	_font_b.base_font = ThemeDB.fallback_font
	_font_b.variation_embolden = 0.9
	_build()

func open_category(c: int) -> void:
	_cat = clampi(c, 0, CAT_WORDS.size() - 1)
	_refresh_rail()
	_fill()

func _build() -> void:
	for c in get_children():
		remove_child(c)
		c.queue_free()
	_rail_btns.clear()
	var rail_bg := PanelContainer.new()
	rail_bg.add_theme_stylebox_override("panel", _flat(RAIL, 0))
	add_child(rail_bg)
	_rail = VBoxContainer.new()
	_rail.add_theme_constant_override("separation", 2)
	rail_bg.add_child(_rail)
	var w: float = 150.0
	for i in CAT_WORDS.size():
		w = maxf(w, ThemeDB.fallback_font.get_string_size(tr(CAT_WORDS[i]), HORIZONTAL_ALIGNMENT_LEFT, -1, 15).x + 44.0)
	for i in CAT_WORDS.size():
		var b := RailButton.new()
		b.word = tr(CAT_WORDS[i])
		b.custom_minimum_size = Vector2(w, 60)
		b.focus_mode = Control.FOCUS_NONE
		b.pressed.connect(open_category.bind(i))
		b.wfont = _font_b
		_rail.add_child(b)
		_rail_btns.append(b)
	var right := VBoxContainer.new()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.add_theme_constant_override("separation", 0)
	add_child(right)
	var head := PanelContainer.new()
	var hs := _flat(BG, 0)
	hs.content_margin_left = 18.0
	hs.content_margin_right = 12.0
	head.add_theme_stylebox_override("panel", hs)
	right.add_child(head)
	var hrow := HBoxContainer.new()
	hrow.add_theme_constant_override("separation", 10)
	head.add_child(hrow)
	_title = _label(20, INK, true)
	_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_title.custom_minimum_size.y = 56
	_title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	hrow.add_child(_title)
	var note := _label(12, DIM)
	note.text = tr("Changes apply instantly")
	note.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	hrow.add_child(note)
	var reset := _button(tr("RESET TO DEFAULTS"), false)
	reset.name = "Reset"
	reset.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	reset.pressed.connect(_reset_category)
	hrow.add_child(reset)
	var rule := ColorRect.new()
	rule.color = Color(0.2, 0.2, 0.24)
	rule.custom_minimum_size = Vector2(0, 1)
	right.add_child(rule)
	var back := PanelContainer.new()
	back.size_flags_vertical = Control.SIZE_EXPAND_FILL
	back.add_theme_stylebox_override("panel", _flat(BG, 0))
	right.add_child(back)
	_scroll = ScrollContainer.new()
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	back.add_child(_scroll)
	var pad := MarginContainer.new()
	pad.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for side in ["left", "right", "top", "bottom"]:
		pad.add_theme_constant_override("margin_" + side, 12)
	_scroll.add_child(pad)
	_list = VBoxContainer.new()
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list.add_theme_constant_override("separation", 6)
	pad.add_child(_list)
	_refresh_rail()
	_fill()

func _refresh_rail() -> void:
	for i in _rail_btns.size():
		(_rail_btns[i] as RailButton).on = i == _cat
		(_rail_btns[i] as RailButton).queue_redraw()
	if _title != null:
		_title.text = tr(CAT_WORDS[_cat])
	var r := find_child("Reset", true, false) as Control
	if r != null:
		r.visible = _cat != Cat.LANGUAGE and _cat != Cat.AUDIO

func _fill() -> void:
	if _list == null:
		return
	for c in _list.get_children():
		_list.remove_child(c)
		c.queue_free()
	_preset_btns.clear()
	match _cat:
		Cat.GRAPHICS: _fill_graphics()
		Cat.AUDIO: _fill_audio()
		Cat.CONTROLS: _fill_controls()
		Cat.GAME: _fill_game()
		Cat.LANGUAGE: _fill_language()
	_scroll.scroll_vertical = 0

# ── Graphics ────────────────────────────────────────────────────────────────────
func _main() -> Node:
	var m := get_node_or_null("/root/Main")
	return m if m != null and "auto_fps" in m else null

func _gfx(key: String) -> Variant:
	var m := _main()
	if m != null:
		return m.get(key)
	return G.settings_raw().get(key, GFX_DEFAULTS[key])

func _set_gfx(key: String, v: Variant) -> void:
	var m := _main()
	if m != null and m.has_method(GFX_SETTERS[key]):
		m.call(GFX_SETTERS[key], v)
	else:
		G.settings_merge({key: v})
	_mark_preset()

func _current_preset() -> String:
	var auto := bool(_gfx("auto_fps"))
	for p in PRESETS:
		var ok := true
		for k in PRESETS[p]:
			var want = PRESETS[p][k]
			if k == "manual_scale" and auto and bool(PRESETS[p]["auto_fps"]):
				continue
			if want is bool:
				ok = ok and bool(_gfx(k)) == want
			else:
				ok = ok and absf(float(_gfx(k)) - float(want)) < 0.01
		if ok:
			return p
	return ""

func _mark_preset() -> void:
	var cur := _current_preset()
	for k in _preset_btns:
		(_preset_btns[k] as Button).set_pressed_no_signal(k == cur)
	if _preset_btns.has("custom"):
		(_preset_btns["custom"] as Button).set_pressed_no_signal(cur == "")

func _apply_preset(p: String) -> void:
	for k in PRESETS[p]:
		_set_gfx(k, PRESETS[p][k])
	_fill()

func _fill_graphics() -> void:
	var seg := HBoxContainer.new()
	seg.add_theme_constant_override("separation", 4)
	for p in PRESET_ORDER:
		var b := _segment(tr(p[1]))
		b.pressed.connect(_apply_preset.bind(String(p[0])))
		seg.add_child(b)
		_preset_btns[p[0]] = b
	var cb := _segment(tr("CUSTOM"))
	cb.disabled = true
	seg.add_child(cb)
	_preset_btns["custom"] = cb
	_list.add_child(_row(tr("Quality"), tr("A preset sets everything below. Change any option and it becomes Custom."), seg))
	_mark_preset()
	_list.add_child(_head(tr("PERFORMANCE")))
	var auto := bool(_gfx("auto_fps"))
	_list.add_child(_switch_row(tr("Auto FPS"), tr("Holds ~30 FPS by lowering the render scale on its own."), auto,
			func(on: bool) -> void: _set_gfx("auto_fps", on); _fill()))
	if not auto:
		_list.add_child(_slider_row(tr("Render scale"), tr("Lower gives more FPS but a softer picture."),
				float(_gfx("manual_scale")), 0.25, 2.0, 0.05, "%d%%", 100.0,
				func(v: float) -> void: _set_gfx("manual_scale", v)))
	_list.add_child(_slider_row(tr("Draw distance"), tr("How far the ground is drawn. Far costs frames and memory."),
			float(_gfx("view_distance")), 200.0, 10000.0, 100.0, "%d m", 1.0,
			func(v: float) -> void: _set_gfx("view_distance", v)))
	_list.add_child(_slider_row(tr("Terrain cache"), tr("How much ground is kept in memory after it leaves the view. More means less rebuilding, but more memory."),
			float(_gfx("terrain_cache")), 0.25, 4.0, 0.25, "%d%%", 100.0,
			func(v: float) -> void: _set_gfx("terrain_cache", v)))
	_list.add_child(_switch_row(tr("Merge far ground"), tr("Fewer draw calls for distant ground. Turn off to compare FPS."),
			bool(_gfx("hlod_on")), func(on: bool) -> void: _set_gfx("hlod_on", on)))
	_list.add_child(_head(tr("SHADOWS")))
	var sh := bool(_gfx("shadows_enabled"))
	_list.add_child(_switch_row(tr("Shadows"), tr("Turn off if FPS drops — the heaviest setting."), sh,
			func(on: bool) -> void: _set_gfx("shadows_enabled", on); _fill()))
	if sh:
		_list.add_child(_switch_row(tr("Full shadows (slow)"), tr("Also shade hills. Costs about half the frame on a phone."),
				bool(_gfx("shadows_engine")), func(on: bool) -> void: _set_gfx("shadows_engine", on); _fill()))
		if bool(_gfx("shadows_engine")):
			_list.add_child(_switch_row(tr("Soft shadows"), "", bool(_gfx("shadows_soft")),
					func(on: bool) -> void: _set_gfx("shadows_soft", on)))
	_list.add_child(_head(tr("SCREEN")))
	if in_game:
		_list.add_child(_slider_row(tr("Interface size"), tr("Size of buttons/panels. The base already adapts to the screen on its own."),
				float(_gfx("ui_scale")), 0.7, 1.4, 0.05, "%d%%", 100.0,
				func(v: float) -> void: _set_gfx("ui_scale", v)))
	if OS.has_feature("pc"):
		_list.add_child(_switch_row(tr("Fullscreen"), "", bool(_gfx("fullscreen")),
				func(on: bool) -> void: _set_gfx("fullscreen", on)))
	_list.add_child(_switch_row(tr("Show FPS"), tr("A small counter in the bottom-right corner, in the game and in the garage."),
			G.show_fps, _on_show_fps))
	if not in_game:
		_list.add_child(_note(tr("Graphics take effect when the world loads.")))

func _on_show_fps(on: bool) -> void:
	G.show_fps = on
	G.save_settings()
	for n in get_tree().get_nodes_in_group("fps_counter"):
		(n as CanvasItem).visible = on

# ── Audio ───────────────────────────────────────────────────────────────────────
func _fill_audio() -> void:
	var m := get_node_or_null("/root/Music")
	if m == null:
		_list.add_child(_note(tr("Music system not connected")))
		return
	var panel := MusicPanel.new()
	panel.contexts = contexts if not contexts.is_empty() else [m.Ctx.MENU]
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list.add_child(panel)

# ── Controls ────────────────────────────────────────────────────────────────────
func _fill_controls() -> void:
	_list.add_child(_head(tr("CAMERA")))
	_list.add_child(_slider_row(tr("Rotation sensitivity"), tr("How fast the view turns under your finger."),
			G.cam_look_sens, 0.2, 3.0, 0.05, "%.2f", 1.0,
			func(v: float) -> void: G.cam_look_sens = v; G.save_settings()))
	_list.add_child(_slider_row(tr("Zoom sensitivity"), tr("How fast two fingers bring the view closer."),
			G.cam_zoom_sens, 0.2, 3.0, 0.05, "%.2f", 1.0,
			func(v: float) -> void: G.cam_zoom_sens = v; G.save_settings()))
	_list.add_child(_switch_row(tr("Invert vertical"), tr("Turns the camera's up-and-down swipe the other way."),
			G.cam_invert_y, func(on: bool) -> void: G.cam_invert_y = on; G.save_settings()))
	_list.add_child(_head(tr("BUILDING")))
	_list.add_child(_switch_row(tr("Picking up a block opens assembly"), tr("Off — the block stays in hand, assembly opens by its button."),
			G.build_on_pickup, func(on: bool) -> void: G.build_on_pickup = on; G.save_settings()))
	for a in actions:
		if String(a[0]) == "Move controls":
			_list.add_child(_head(tr("LAYOUT")))
			_list.add_child(_action_row(a))

# ── Game ────────────────────────────────────────────────────────────────────────
func _fill_game() -> void:
	_list.add_child(_switch_row(tr("Fight behind the menu"), tr("A real battle plays behind the main menu. Off: a quiet map and less battery."),
			G.menu_battles, func(on: bool) -> void:
				G.menu_battles = on
				G.save_settings()
				menu_fight_changed.emit(on)))
	var rest: Array = actions.filter(func(a) -> bool: return String(a[0]) != "Move controls")
	if not rest.is_empty():
		_list.add_child(_head(tr("MACHINE AND WORLD")))
		for a in rest:
			_list.add_child(_action_row(a))

# ── Language ────────────────────────────────────────────────────────────────────
func _fill_language() -> void:
	_list.add_child(_note(tr("Every text in the game switches at once.")))
	var grid := GridContainer.new()
	grid.columns = 2 if size.x < 900.0 else 3
	grid.add_theme_constant_override("h_separation", 6)
	grid.add_theme_constant_override("v_separation", 6)
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list.add_child(grid)
	var cur: String = G.current_lang()
	for code in G.LANGS:
		var b := LangButton.new()
		b.text = String(LANG_NAMES.get(code, code))
		b.on = code == cur
		b.custom_minimum_size = Vector2(0, 60)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.focus_mode = Control.FOCUS_NONE
		b.add_theme_font_size_override("font_size", 17)
		b.add_theme_color_override("font_color", INK if b.on else DIM)
		b.add_theme_color_override("font_hover_color", INK)
		b.add_theme_color_override("font_pressed_color", INK)
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		for st in ["normal", "hover", "pressed", "focus"]:
			var sb := _flat(CARD_HI if b.on else CARD, 0)
			sb.content_margin_left = 18.0
			if b.on:
				sb.border_color = ACCENT
				sb.border_width_left = 3
			b.add_theme_stylebox_override(st, sb)
		b.pressed.connect(_pick_lang.bind(String(code)))
		grid.add_child(b)

func _pick_lang(code: String) -> void:
	G.set_lang(code)
	_build()
	open_category(Cat.LANGUAGE)
	lang_changed.emit()

# ── Reset ───────────────────────────────────────────────────────────────────────
func _reset_category() -> void:
	match _cat:
		Cat.GRAPHICS:
			for k in GFX_DEFAULTS:
				if k == "fullscreen" or (k == "ui_scale" and not in_game):
					continue
				_set_gfx(k, GFX_DEFAULTS[k])
			_on_show_fps(true)
		Cat.CONTROLS:
			G.cam_look_sens = 1.0
			G.cam_zoom_sens = 1.0
			G.cam_invert_y = false
			G.build_on_pickup = true
			G.save_settings()
		Cat.GAME:
			G.menu_battles = true
			G.save_settings()
			menu_fight_changed.emit(true)
	_fill()

# ── Building blocks ─────────────────────────────────────────────────────────────
func _flat(bg: Color, margin: int = 10) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.anti_aliasing = false
	sb.content_margin_left = margin
	sb.content_margin_right = margin
	sb.content_margin_top = 4
	sb.content_margin_bottom = 4
	return sb

func _label(fs: int, col: Color, bold: bool = false) -> Label:
	var l := Label.new()
	l.add_theme_font_size_override("font_size", fs)
	l.add_theme_color_override("font_color", col)
	if bold:
		l.add_theme_font_override("font", _font_b)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l

func _head(text: String) -> Control:
	var l := _label(12, ACCENT, true)
	l.text = text
	l.custom_minimum_size.y = 30
	l.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	return l

func _note(text: String) -> Control:
	var l := _label(13, DIM)
	l.text = text
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.custom_minimum_size.y = 34
	return l

## A card: caption and hint on the left, the control on the right.
func _row(caption: String, hint: String, ctrl: Control) -> Control:
	var card := PanelContainer.new()
	var sb := _flat(CARD, 16)
	sb.content_margin_top = 8
	sb.content_margin_bottom = 8
	card.add_theme_stylebox_override("panel", sb)
	card.custom_minimum_size.y = ROW_H
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 16)
	card.add_child(row)
	var txt := VBoxContainer.new()
	txt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	txt.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	txt.add_theme_constant_override("separation", 2)
	row.add_child(txt)
	var cap := _label(16, INK)
	cap.text = caption
	cap.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	txt.add_child(cap)
	if hint != "":
		var h := _label(12, DIM)
		h.text = hint
		h.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		txt.add_child(h)
	ctrl.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(ctrl)
	return card

func _switch_row(caption: String, hint: String, on: bool, cb: Callable) -> Control:
	var s := Switch.new()
	s.toggle_mode = true
	s.button_pressed = on
	s.custom_minimum_size = Vector2(76, 44)
	s.focus_mode = Control.FOCUS_NONE
	s.toggled.connect(cb)
	var card := _row(caption, hint, s)
	return card

func _slider_row(caption: String, hint: String, value: float, lo: float, hi: float, step: float,
		fmt: String, mul: float, cb: Callable) -> Control:
	var box := HBoxContainer.new()
	box.add_theme_constant_override("separation", 12)
	var sl := HSlider.new()
	sl.min_value = lo
	sl.max_value = hi
	sl.step = step
	sl.value = value
	sl.custom_minimum_size = Vector2(260, 44)
	sl.focus_mode = Control.FOCUS_NONE
	_slider_look(sl)
	box.add_child(sl)
	var val := _label(16, INK, true)
	val.custom_minimum_size = Vector2(76, 0)
	val.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	val.text = _fmt(fmt, value * mul)
	box.add_child(val)
	sl.value_changed.connect(func(v: float) -> void:
		val.text = _fmt(fmt, v * mul)
		cb.call(v))
	return _row(caption, hint, box)

static func _fmt(fmt: String, v: float) -> String:
	if fmt.contains("%d"):
		return fmt % int(round(v))
	return fmt % v

func _slider_look(sl: HSlider) -> void:
	var groove := StyleBoxFlat.new()
	groove.bg_color = GROOVE
	groove.content_margin_top = 3.0
	groove.content_margin_bottom = 3.0
	var fill := groove.duplicate() as StyleBoxFlat
	fill.bg_color = ACCENT
	var hot := fill.duplicate() as StyleBoxFlat
	hot.bg_color = ACCENT.lightened(0.2)
	sl.add_theme_stylebox_override("slider", groove)
	sl.add_theme_stylebox_override("grabber_area", fill)
	sl.add_theme_stylebox_override("grabber_area_highlight", hot)
	var g := Knob.new_texture(22, INK)
	sl.add_theme_icon_override("grabber", g)
	sl.add_theme_icon_override("grabber_highlight", Knob.new_texture(22, Color.WHITE))

func _segment(text: String) -> Button:
	var b := Button.new()
	b.text = text
	b.toggle_mode = true
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = Vector2(maxf(84.0, ThemeDB.fallback_font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, 14).x + 28.0), 44)
	b.add_theme_font_size_override("font_size", 14)
	b.add_theme_font_override("font", _font_b)
	b.add_theme_color_override("font_color", DIM)
	b.add_theme_color_override("font_hover_color", INK)
	b.add_theme_color_override("font_pressed_color", Color(0.08, 0.06, 0.03))
	b.add_theme_color_override("font_hover_pressed_color", Color(0.08, 0.06, 0.03))
	b.add_theme_color_override("font_disabled_color", DIM * Color(1, 1, 1, 0.6))
	b.add_theme_stylebox_override("normal", _flat(GROOVE))
	b.add_theme_stylebox_override("hover", _flat(CARD_HI))
	b.add_theme_stylebox_override("pressed", _flat(ACCENT))
	b.add_theme_stylebox_override("hover_pressed", _flat(ACCENT))
	b.add_theme_stylebox_override("disabled", _flat(GROOVE))
	b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	return b

func _button(text: String, danger: bool) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = Vector2(0, 44)
	b.add_theme_font_size_override("font_size", 13)
	b.add_theme_font_override("font", _font_b)
	var col := Color(0.95, 0.5, 0.45) if danger else INK
	b.add_theme_color_override("font_color", col)
	b.add_theme_color_override("font_hover_color", Color.WHITE)
	var n := _flat(GROOVE, 16)
	n.border_color = col * Color(1, 1, 1, 0.35)
	n.border_width_bottom = 2
	var h := n.duplicate() as StyleBoxFlat
	h.bg_color = CARD_HI
	b.add_theme_stylebox_override("normal", n)
	b.add_theme_stylebox_override("hover", h)
	b.add_theme_stylebox_override("pressed", h)
	b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	return b

func _action_row(a: Array) -> Control:
	var b := _button(tr(String(a[0])).to_upper(), a.size() > 3 and a[3] == true)
	b.custom_minimum_size.x = 200
	b.pressed.connect(a[2])
	return _row(tr(String(a[0])), tr(String(a[1])), b)

# ── Drawn widgets (no glyphs: the font has no ✓, see CLAUDE.md §0.11) ─────────────
class Switch extends Button:
	func _init() -> void:
		flat = true
		for st in ["normal", "hover", "pressed", "hover_pressed", "focus"]:
			add_theme_stylebox_override(st, StyleBoxEmpty.new())
		toggled.connect(func(_on: bool) -> void: queue_redraw())
	func _draw() -> void:
		var h: float = 30.0
		var w: float = 60.0
		var r := Rect2(Vector2(size.x - w, (size.y - h) * 0.5), Vector2(w, h))
		var on := button_pressed
		draw_rect(r, SettingsView.ACCENT if on else SettingsView.GROOVE)
		draw_rect(r, Color(1, 1, 1, 0.08), false, 1.0)
		var k := Rect2(Vector2(r.position.x + (w - h + 3.0 if on else 3.0), r.position.y + 3.0), Vector2(h - 6.0, h - 6.0))
		draw_rect(k, SettingsView.INK if on else SettingsView.DIM)

class RailButton extends Button:
	var word: String = ""
	var on: bool = false
	func _init() -> void:
		flat = true
		for st in ["normal", "hover", "pressed", "hover_pressed", "focus"]:
			add_theme_stylebox_override(st, StyleBoxEmpty.new())
		mouse_entered.connect(queue_redraw)
		mouse_exited.connect(queue_redraw)
	func _draw() -> void:
		if on:
			draw_rect(Rect2(Vector2.ZERO, size), SettingsView.CARD)
			draw_rect(Rect2(Vector2.ZERO, Vector2(4, size.y)), SettingsView.ACCENT)
		elif is_hovered():
			draw_rect(Rect2(Vector2.ZERO, size), Color(1, 1, 1, 0.03))
		var f: Font = get_theme_font("font") if wfont == null else wfont
		var fs: int = 15
		var y: float = (size.y + f.get_ascent(fs) - f.get_descent(fs)) * 0.5
		draw_string(f, Vector2(22, y), word, HORIZONTAL_ALIGNMENT_LEFT, size.x - 28.0, fs,
				SettingsView.INK if on else SettingsView.DIM)
	var wfont: Font = null

class LangButton extends Button:
	var on: bool = false
	func _draw() -> void:
		if not on:
			return
		var c := Vector2(size.x - 30.0, size.y * 0.5)
		draw_polyline(PackedVector2Array([c + Vector2(-8, 0), c + Vector2(-2, 6), c + Vector2(9, -7)]),
				SettingsView.ACCENT, 3.0)

class Knob:
	static func new_texture(d: int, col: Color) -> ImageTexture:
		var img := Image.create(d, d, false, Image.FORMAT_RGBA8)
		img.fill(col)
		for i in d:
			img.set_pixel(i, 0, Color(0, 0, 0, 0.4))
			img.set_pixel(i, d - 1, Color(0, 0, 0, 0.4))
			img.set_pixel(0, i, Color(0, 0, 0, 0.4))
			img.set_pixel(d - 1, i, Color(0, 0, 0, 0.4))
		return ImageTexture.create_from_image(img)
