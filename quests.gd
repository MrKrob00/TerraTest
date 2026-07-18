extends CanvasLayer
# UI заданий. Вверху справа — трекер с ОДНИМ отслеживаемым заданием; тап по нему
# разворачивает список всех заданий (сюжет + ежедневные). У каждого звёздочка —
# нажал → это задание показывается в трекере. Данные берём из автолоада Q.

@onready var _tracker:   Button   = %Tracker
@onready var _title:     Label    = %TrackTitle
@onready var _objective: Label    = %TrackObjective
@onready var _list_panel: PanelContainer = %ListPanel
@onready var _list:      VBoxContainer   = %QuestList

var _tracker_top0: float = 0.0        # исходное положение трекера (чтобы вернуть)
var _tracker_bot0: float = 0.0

func _ready() -> void:
	add_to_group("quests")            # чтобы HUD мог увести трекер вниз при открытом инвентаре
	_tracker_top0 = _tracker.offset_top
	_tracker_bot0 = _tracker.offset_bottom
	_tracker.pressed.connect(_toggle_list)
	%Close.pressed.connect(func(): _list_panel.visible = false)
	Q.changed.connect(_refresh)       # Q — автолоад, всегда готов к моменту нашего _ready
	_refresh()

# HUD зовёт при открытии/закрытии инвентаря: при открытом уводим трекер вниз (из-под панели
# статистики) и делаем его прозрачным для тача, чтобы он не перекрывал кнопку закрытия.
func set_inventory_open(open: bool) -> void:
	_list_panel.visible = false
	if open:
		var shift: float = get_viewport().get_visible_rect().size.y * 0.55
		_tracker.offset_top = _tracker_top0 + shift
		_tracker.offset_bottom = _tracker_bot0 + shift
		_tracker.mouse_filter = Control.MOUSE_FILTER_IGNORE
	else:
		_tracker.offset_top = _tracker_top0
		_tracker.offset_bottom = _tracker_bot0
		_tracker.mouse_filter = Control.MOUSE_FILTER_STOP

func _toggle_list() -> void:
	_list_panel.visible = not _list_panel.visible
	if _list_panel.visible:
		_rebuild_list()

func _refresh() -> void:
	_update_tracker()
	if _list_panel.visible:
		_rebuild_list()

# ── Трекер (одно задание вверху справа) ───────────────────────────────────────
func _update_tracker() -> void:
	var q: Dictionary = Q.tracked()
	if q.is_empty():
		_title.text = "Нет активных заданий"
		_objective.text = ""
		return
	var star := "★ " if q["type"] == Q.Type.STORY else "◆ "
	_title.text = star + str(q["title"])
	if q["done"]:
		_objective.text = "✓ выполнено"
	else:
		_objective.text = "%s — %d/%d" % [q["desc"], q["progress"], q["goal"]]

# ── Список всех заданий ───────────────────────────────────────────────────────
func _rebuild_list() -> void:
	for c in _list.get_children():
		c.queue_free()
	var vis: Array = Q.visible_quests()
	_add_section("СЮЖЕТ", vis.filter(func(q): return q["type"] == Q.Type.STORY))
	_add_section("ЕЖЕДНЕВНЫЕ", vis.filter(func(q): return q["type"] == Q.Type.DAILY))

func _add_section(section_name: String, items: Array) -> void:
	if items.is_empty():
		return
	var h := Label.new()
	h.text = section_name
	h.add_theme_font_size_override("font_size", 13)
	h.add_theme_color_override("font_color", Color(0.55, 0.75, 0.8, 0.85))
	_list.add_child(h)
	for q in items:
		_list.add_child(_make_row(q))

func _make_row(q: Dictionary) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)

	var is_tracked: bool = (q["id"] == Q.tracked_id)
	var star := Button.new()
	star.flat = true
	star.custom_minimum_size = Vector2(34, 34)
	star.text = "★" if is_tracked else "☆"
	star.add_theme_font_size_override("font_size", 20)
	star.add_theme_color_override("font_color", Color(1, 0.65, 0.2, 1) if is_tracked else Color(0.7, 0.75, 0.78, 1))
	star.disabled = q["done"]
	star.pressed.connect(func(): Q.track(q["id"]))
	row.add_child(star)

	var vb := VBoxContainer.new()
	vb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vb.add_theme_constant_override("separation", 1)
	var t := Label.new()
	t.text = str(q["title"]) + ("  ✓" if q["done"] else "")
	t.add_theme_font_size_override("font_size", 15)
	t.add_theme_color_override("font_color", Color(0.6, 0.75, 0.6, 1) if q["done"] else Color(0.92, 0.96, 0.98, 1))
	vb.add_child(t)
	var o := Label.new()
	if q["done"]:
		o.text = "✓ выполнено"
	else:
		o.text = "%s — %d/%d" % [q["desc"], q["progress"], q["goal"]]
		var reward: int = int(q.get("reward_money", 0))
		if reward > 0:
			o.text += "  ·  +%d$" % reward
		var rxp: int = int(q.get("reward_xp", 0))
		if rxp > 0:
			o.text += "  ·  +%dXP" % rxp
		var rrp: int = int(q.get("reward_rp", 0))
		if rrp > 0:
			o.text += "  ·  +%dДИ" % rrp
	o.add_theme_font_size_override("font_size", 12)
	o.add_theme_color_override("font_color", Color(1, 1, 1, 0.55))
	vb.add_child(o)
	row.add_child(vb)
	return row
