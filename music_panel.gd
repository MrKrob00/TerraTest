class_name MusicPanel
extends VBoxContainer
## Music controls: what plays now, on/off, volume, and the track lists with heart / ban.
##
## ONE PANEL, TWO PLACES. The garage tab owned the only copy; the main menu needed the same
## thing, and a second hand-written set of rows would drift the day a control is added to one
## of them. The only difference between the two is WHICH LISTS are shown: the menu shows its
## own tracks, the garage the two the world plays.
##
## It subscribes to the manager itself, so whoever embeds it does not have to remember to
## refresh the rows on a track change or on a heart being pressed.

## Which context lists to draw (Music.Ctx values). Empty = player controls only, no lists.
var contexts: Array = []

var _m: Node = null

func setup(ctx_list: Array) -> void:
	contexts = ctx_list
	if is_inside_tree():
		rebuild()

func _ready() -> void:
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_theme_constant_override("separation", 10)
	_m = get_node_or_null("/root/Music")
	if _m != null:
		_m.prefs_changed.connect(_on_prefs)
		_m.track_changed.connect(_on_track)
	rebuild()

func _on_prefs() -> void:
	# Rebuilt only while on screen: the garage keeps this panel alive on other tabs, and a
	# track change every few minutes would rebuild rows nobody is looking at.
	if is_visible_in_tree():
		rebuild()

func _on_track(_title: String, _author: String) -> void:
	_on_prefs()

func rebuild() -> void:
	for c in get_children():
		remove_child(c)
		c.queue_free()
	if _m == null:
		var miss := Label.new()
		miss.text = tr("Music system not connected")
		miss.add_theme_font_size_override("font_size", 13)
		add_child(miss)
		return
	var cur: Dictionary = _m.current_track()
	add_child(_now_playing(cur))
	add_child(_enable_row())
	add_child(_volume_row())
	for ctx in contexts:
		add_child(section_head(tr(String(_m.ctx_title(int(ctx))))))
		var list: Array = _m.tracks.get(int(ctx), [])
		if list.is_empty():
			var empty := Label.new()
			empty.text = tr("   (no tracks — drop .ogg into music/)")
			empty.add_theme_font_size_override("font_size", 12)
			empty.modulate = Color(1, 1, 1, 0.45)
			add_child(empty)
			continue
		for t in list:
			add_child(_track_row(t as Dictionary, cur))

# ── Player ────────────────────────────────────────────────────────────────────

## Title and author on two lines, like a track row rather than one long log line: the row is
## narrow on a phone, and «Author — Title [Travel]» clipped to the title alone.
func _now_playing(cur: Dictionary) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	var info := VBoxContainer.new()
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	info.add_theme_constant_override("separation", 0)
	row.add_child(info)
	var silent: bool = cur.is_empty()
	var line := Label.new()
	line.text = tr("Silence (no tracks or all disabled)") if silent else "▶ " + str(cur["title"])
	line.add_theme_font_size_override("font_size", 14)
	var col := Color(0.6, 0.63, 0.66) if silent else Color(0.6, 1.0, 0.7)
	line.add_theme_color_override("font_color", col)
	line.clip_text = true
	info.add_child(line)
	if not silent:
		var sub := Label.new()
		sub.text = "%s · %s" % [str(cur["author"]), tr(String(_m.context_name()))]
		sub.add_theme_font_size_override("font_size", 11)
		sub.add_theme_color_override("font_color", Color(0.55, 0.58, 0.62))
		sub.clip_text = true
		info.add_child(sub)
	var skip := Button.new()
	skip.text = "⏭"
	skip.tooltip_text = tr("Next track")
	skip.custom_minimum_size = Vector2(46, 42)
	skip.disabled = silent
	skip.pressed.connect(_skip)
	row.add_child(skip)
	return row

func _skip() -> void:
	if _m != null:
		_m.skip()

## MUSIC OFF IS A SWITCH, NOT VOLUME ZERO. The manager has carried an `enabled` flag since it
## was written, and nothing ever set it: the only way to silence the game was to drag the
## slider to the left, which then forgets where it was.
func _enable_row() -> CheckButton:
	var cb := CheckButton.new()
	cb.text = tr("Music")
	cb.button_pressed = bool(_m.enabled)
	cb.add_theme_color_override("font_color", Color(0.88, 0.97, 0.99))
	cb.toggled.connect(_on_enabled)
	return cb

func _on_enabled(on: bool) -> void:
	if _m != null:
		_m.set_enabled(on)

## Caption and per cent on one line, slider on its own underneath. Side by side the slider
## had about half the panel to itself, and a thumb covers more than that.
func _volume_row() -> Control:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 2)
	var head := HBoxContainer.new()
	box.add_child(head)
	var cap := Label.new()
	cap.text = tr("Volume")
	cap.add_theme_font_size_override("font_size", 13)
	cap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(cap)
	var val := Label.new()
	val.text = "%d%%" % int(round(float(_m.volume) * 100.0))
	val.add_theme_font_size_override("font_size", 13)
	val.add_theme_color_override("font_color", Color(0.35, 0.85, 0.92))
	head.add_child(val)
	var sl := HSlider.new()
	sl.min_value = 0.0
	sl.max_value = 1.0
	sl.step = 0.05
	sl.value = float(_m.volume)
	sl.custom_minimum_size = Vector2(0, 32)
	sl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sl.value_changed.connect(_on_volume.bind(val))
	box.add_child(sl)
	return box

## The value label is updated by hand instead of rebuilding: a rebuild on every slider step
## would free the slider under the finger that is dragging it.
func _on_volume(v: float, val: Label) -> void:
	if _m != null:
		_m.set_volume(v)
	if is_instance_valid(val):
		val.text = "%d%%" % int(round(v * 100.0))

# ── Lists ─────────────────────────────────────────────────────────────────────

## Caption plus a hairline that runs to the edge: a bare label between rows of controls read
## as one more setting. Static and public — the menu settings divide themselves with the same
## header, and two drawings of one divider is how two panels stop looking like one screen.
## Takes the text ALREADY TRANSLATED: `tr()` is a Node method and this has no node.
static func section_head(text: String) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	var lbl := Label.new()
	lbl.text = text.to_upper()
	lbl.add_theme_font_size_override("font_size", 12)
	lbl.add_theme_color_override("font_color", Color(0.35, 0.85, 0.92, 0.9))
	row.add_child(lbl)
	var line := ColorRect.new()
	line.color = Color(0.35, 0.85, 0.92, 0.25)
	line.custom_minimum_size = Vector2(0, 1)
	line.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	line.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(line)
	return row

## Title over author on the left, heart and ban on the right. ▶ marks the one playing.
func _track_row(t: Dictionary, cur: Dictionary) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	var file: String = t["file"]
	var playing: bool = cur.get("file", "") == file
	var banned: bool = _m.banned.has(file)

	var info := VBoxContainer.new()
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	info.add_theme_constant_override("separation", 0)
	row.add_child(info)
	var title := Label.new()
	title.text = ("▶ " if playing else "") + str(t["title"])
	title.add_theme_font_size_override("font_size", 15)
	title.clip_text = true
	if banned:
		title.modulate = Color(1, 1, 1, 0.4)
	elif playing:
		title.add_theme_color_override("font_color", Color(0.6, 1.0, 0.7))
	info.add_child(title)
	var author := Label.new()
	author.text = str(t["author"])
	author.add_theme_font_size_override("font_size", 12)
	author.add_theme_color_override("font_color", Color(0.55, 0.58, 0.62))
	author.clip_text = true
	if banned:
		author.modulate = Color(1, 1, 1, 0.4)
	info.add_child(author)

	row.add_child(_icon_btn(HeartIcon.new(), _m.fav.has(file), tr("Favorite: plays more often"),
			_on_fav.bind(file)))
	row.add_child(_icon_btn(BanIcon.new(), banned, tr("Never play"), _on_ban.bind(file)))
	return row

func _on_fav(on: bool, file: String) -> void:
	if _m != null:
		_m.set_favorite(file, on)

func _on_ban(on: bool, file: String) -> void:
	if _m != null:
		_m.set_banned(file, on)

func _icon_btn(icon: Control, active: bool, tip: String, on_toggle: Callable) -> Button:
	var b := Button.new()
	b.toggle_mode = true
	b.button_pressed = active
	b.tooltip_text = tip
	b.custom_minimum_size = Vector2(42, 40)
	icon.set("active", active)
	icon.set_anchors_preset(Control.PRESET_FULL_RECT)
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	b.add_child(icon)
	b.toggled.connect(on_toggle)
	return b

# ── Icons: drawn in code, because the font renders ♥ / ✖ as empty boxes ────────

class HeartIcon extends Control:
	var active := false
	func _draw() -> void:
		var c := size * 0.5 + Vector2(0, -1)
		var col := Color(1.0, 0.35, 0.5) if active else Color(0.45, 0.47, 0.52)
		var r := 5.0
		draw_circle(c + Vector2(-r, -2), r, col)
		draw_circle(c + Vector2(r, -2), r, col)
		draw_colored_polygon(PackedVector2Array([
			c + Vector2(-2.0 * r, 0.5), c + Vector2(2.0 * r, 0.5), c + Vector2(0, 11.0)]), col)

class BanIcon extends Control:
	var active := false
	func _draw() -> void:
		var c := size * 0.5
		# «Never play» is always red: dim at rest, bright when it is on.
		var col := Color(1.0, 0.25, 0.2) if active else Color(0.62, 0.2, 0.18)
		var a := 7.0
		draw_line(c + Vector2(-a, -a), c + Vector2(a, a), col, 3.5)
		draw_line(c + Vector2(-a, a), c + Vector2(a, -a), col, 3.5)
