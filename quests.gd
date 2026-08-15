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
var _list_top0: float = 0.0           # то же для панели списка — она едет за трекером
var _inventory_open: bool = false

func _ready() -> void:
	add_to_group("quests")            # HUD через группу двигает трекер и прячет его в гараже
	_tracker_top0 = _tracker.offset_top
	_tracker_bot0 = _tracker.offset_bottom
	_list_top0 = _list_panel.offset_top
	_tracker.pressed.connect(_toggle_list)
	%Close.pressed.connect(_close_list)
	# Оба окна плавающие. Трекер таскаем за него самого (он же и кнопка — тап и
	# перетаскивание различаем по пройденному пути), список — ТОЛЬКО за шапку: внутри него
	# скролл, и если ловить перетаскивание всей панелью, список перестанет прокручиваться
	# пальцем.
	_tracker.gui_input.connect(_drag_input.bind(_tracker, TRACKER_ID))
	%Header.gui_input.connect(_drag_input.bind(_list_panel, LIST_ID))
	# Отложенно: сохранённую позицию прижимаем к экрану по РАЗМЕРУ окна, а его контейнеры
	# досчитывают только после первой раскладки.
	_restore_pos.call_deferred(_tracker, TRACKER_ID)
	_restore_pos.call_deferred(_list_panel, LIST_ID)
	get_viewport().size_changed.connect(_keep_on_screen)
	Q.changed.connect(_refresh)       # Q — автолоад, всегда готов к моменту нашего _ready
	_refresh()

# ── Плавающие окна: перетаскивание ────────────────────────────────────────────
const TRACKER_ID := "quest_tracker"
const LIST_ID := "quest_list"
const DRAG_SLOP: float = 8.0          # дальше этого палец уже тащит, а не нажимает
const SCREEN_PAD: float = 8.0         # окно не заходит за край экрана дальше отступа

var _drag_win: Control = null         # что тащим прямо сейчас
var _drag_id: String = ""
var _drag_from: Vector2 = Vector2.ZERO   # позиция окна в момент захвата
var _drag_ptr: Vector2 = Vector2.ZERO    # где был палец в момент захвата
var _dragged: bool = false            # тап уехал в перетаскивание — не считать нажатием
var _moved: Dictionary = {}           # окна, которым игрок сам выбрал место

func _drag_input(ev: InputEvent, win: Control, id: String) -> void:
	if ev is InputEventMouseButton and (ev as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
		if (ev as InputEventMouseButton).pressed:
			_drag_win = win
			_drag_id = id
			_drag_from = win.position
			_drag_ptr = win.get_global_mouse_position()
			_dragged = false
		elif _drag_win == win:
			_drag_win = null
			if _dragged:
				G.set_window_pos(id, win.position)   # пишем в конфиг на отпускании, не на каждый кадр
	elif ev is InputEventMouseMotion and _drag_win == win:
		var moved: Vector2 = win.get_global_mouse_position() - _drag_ptr
		if not _dragged and moved.length() < DRAG_SLOP:
			return                    # дрожание пальца на тапе — это ещё не перетаскивание
		_dragged = true
		_moved[id] = true
		win.position = _clamp_on_screen(win, _drag_from + moved)

func _clamp_on_screen(win: Control, pos: Vector2) -> Vector2:
	var vp: Vector2 = get_viewport().get_visible_rect().size
	# Окно шире экрана прижимаем к левому/верхнему краю, иначе clampf получил бы min > max.
	return Vector2(
		clampf(pos.x, SCREEN_PAD, maxf(SCREEN_PAD, vp.x - win.size.x - SCREEN_PAD)),
		clampf(pos.y, SCREEN_PAD, maxf(SCREEN_PAD, vp.y - win.size.y - SCREEN_PAD)))

func _restore_pos(win: Control, id: String) -> void:
	var p: Variant = G.window_pos(id)
	if p == null:
		return
	_moved[id] = true
	win.position = _clamp_on_screen(win, p)

# Поворот экрана или смена разрешения: то, что игрок оставил у правого края, иначе
# оказалось бы за его пределами и вернуть окно было бы нечем.
func _keep_on_screen() -> void:
	for pair in [[_tracker, TRACKER_ID], [_list_panel, LIST_ID]]:
		var win: Control = pair[0]
		if _moved.has(pair[1]):
			win.position = _clamp_on_screen(win, win.position)

# HUD зовёт при открытии/закрытии инвентаря. Гараж — полноэкранный, и трекер поверх него
# всё равно ничего не отслеживает: раньше его уводили вниз на 0.55 экрана, и он налезал на
# нижнюю часть панели. Просто убираем на время инвентаря.
func set_inventory_open(open: bool) -> void:
	_inventory_open = open
	_list_panel.visible = false
	_apply_visibility()

# Трекер и список — одно и то же, показанное коротко и подробно. Вместе они только
# загромождают экран и налезают друг на друга, когда игрок растащил их по своим местам:
# открыт список — трекер прячется, закрыт — возвращается.
func _apply_visibility() -> void:
	_tracker.visible = not _inventory_open and not _list_panel.visible

# HUD зовёт, когда появляется/пропадает радар: они оба живут в правом верхнем углу и
# накладывались друг на друга. y = нижняя кромка занятой области (0 — угол свободен).
func set_top_offset(y: float) -> void:
	# Игрок сам положил окна куда хотел — радар их больше не двигает: это его место.
	if _moved.has(TRACKER_ID) or _moved.has(LIST_ID):
		return
	var top: float = _tracker_top0 if y <= 0.0 else y
	_tracker.offset_top = top
	_tracker.offset_bottom = top + (_tracker_bot0 - _tracker_top0)
	_list_panel.offset_top = _list_top0 + (top - _tracker_top0)

# Цели для обучающего пальца.
func tracker_node() -> Control:
	return _tracker

func tutorial_target(key: String) -> Control:
	match key:
		"tracker": return _tracker
		"list":    return _list_panel
		"star":
			# Первая звёздочка в списке — по ней объясняем, что она делает.
			for row in _list.get_children():
				if row is HBoxContainer and row.get_child_count() > 0:
					return row.get_child(0) as Control
			return _list_panel
	return null

func _toggle_list() -> void:
	# Трекер — кнопка, и Button шлёт pressed по отпусканию даже после того, как его утащили
	# пальцем через полэкрана. Переезд нажатием не считаем.
	if _dragged:
		_dragged = false
		return
	_list_panel.visible = not _list_panel.visible
	_apply_visibility()
	if _list_panel.visible:
		_rebuild_list()
		Q.report("quests_opened", 1)      # шаг обучения «открыть список заданий»

func _close_list() -> void:
	_list_panel.visible = false
	_apply_visibility()

func _refresh() -> void:
	_update_tracker()
	if _list_panel.visible:
		_rebuild_list()

# ── Трекер (одно задание вверху справа) ───────────────────────────────────────
func _update_tracker() -> void:
	var q: Dictionary = Q.tracked()
	if q.is_empty():
		_title.text = "No active quests"
		_objective.text = ""
		return
	var star := "▶ " if q["type"] == Q.Type.TUTORIAL else ("★ " if q["type"] == Q.Type.STORY else "◆ ")
	_title.text = star + str(q["title"]) + _stage_suffix(q)
	if q["done"]:
		_objective.text = "✓ done"
	elif _grade_locked(q):
		# Затрекан ждущий грейда квест (напр. сейв со старым треком) — не врём прогрессом.
		_objective.text = "Unlocks at license grade %d" % int(q.get("req_grade", 1))
	else:
		_objective.text = "%s — %d/%d" % [q["desc"], q["progress"], q["goal"]]

# «· часть 2/2» у многостадийных: без этого две разные части выглядят одним и тем же
# заданием, у которого почему-то поменялся текст.
func _stage_suffix(q: Dictionary) -> String:
	var si: Vector2i = Q.stage_info(q)
	return "" if si == Vector2i.ZERO else "  · часть %d/%d" % [si.x, si.y]

# Сюжетный квест ждёт грейда лицензии (см. quest_manager._grade_ok).
func _grade_locked(q: Dictionary) -> bool:
	return int(q["type"]) == Q.Type.STORY and G.grade("start") < int(q.get("req_grade", 1))

# ── Список всех заданий ───────────────────────────────────────────────────────
func _rebuild_list() -> void:
	for c in _list.get_children():
		c.queue_free()
	var vis: Array = Q.visible_quests()
	_add_section("TUTORIAL", vis.filter(func(q): return q["type"] == Q.Type.TUTORIAL))
	_add_section("STORY", vis.filter(func(q): return q["type"] == Q.Type.STORY))
	_add_section("DAILY", vis.filter(func(q): return q["type"] == Q.Type.DAILY))

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
	star.disabled = q["done"] or _grade_locked(q)   # заблокированный не затрекать: прогресс
	star.pressed.connect(func(): Q.track(q["id"]))  # у него всё равно не капает
	row.add_child(star)

	var vb := VBoxContainer.new()
	vb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vb.add_theme_constant_override("separation", 1)
	var t := Label.new()
	t.text = str(q["title"]) + _stage_suffix(q) + ("  ✓" if q["done"] else "")
	t.add_theme_font_size_override("font_size", 15)
	t.add_theme_color_override("font_color", Color(0.6, 0.75, 0.6, 1) if q["done"] else Color(0.92, 0.96, 0.98, 1))
	vb.add_child(t)
	var o := Label.new()
	if q["done"]:
		o.text = "✓ done"
	else:
		if _grade_locked(q):
			# Цепочка ждёт лицензию — вместо прогресса пишем условие (награды как тизер).
			o.text = "Unlocks at license grade %d" % int(q.get("req_grade", 1))
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
			o.text += "  ·  +%d RP" % rrp
	o.add_theme_font_size_override("font_size", 12)
	o.add_theme_color_override("font_color", Color(1, 1, 1, 0.55))
	vb.add_child(o)
	row.add_child(vb)
	return row
