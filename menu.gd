extends Node3D
## Main menu. It runs BEFORE the world loads: the slot is chosen here, and `G.use_slot` must
## finish before map, machines and veins read any file - otherwise the first frame of the game
## reads someone else's world.
##
## The scene (`menu.tscn`) holds everything that stands still: the 3D stage nodes, the corner
## layout, the news panel, the settings window and their styles. Code holds only what is built
## FROM DATA - slot rows (their buttons follow slot state), the generation panel and the news
## entries. That is the same node-or-code line the rest of the project uses.
##
## The centre of the screen belongs to the backdrop: controls sit bottom-left (thumb zone), news
## top-right. Slots appear only after PLAY - the first screen answers one question.
const GAME_SCENE := "res://node_3d.tscn"
const LOADING := preload("res://loading_screen.gd")

# Same dark teal as the rest of the UI. Only for widgets built here; scene nodes carry their own.
const ACCENT  := Color(0.35, 0.85, 0.92)
const TEXT    := Color(0.88, 0.97, 0.99)
const DIM     := Color(0.62, 0.78, 0.82)
const DANGER  := Color(1.0, 0.45, 0.35)

const COL_W := 420.0
## Share of screen height the news feed may take. More and it covers the fight.
const NEWS_H_FRAC := 0.42

@onready var _left: VBoxContainer = %Left
@onready var _news_list: VBoxContainer = %NewsList
@onready var _settings: CenterContainer = %Settings

# ── World creation ───────────────────────────────────────────────────────────
# The menu computes a new slot's ground, not the first frame of the game: the run takes a minute
# or more and under a loading screen that is indistinguishable from a hang. Here it gets a bar, a
# remaining-time estimate and a STOP, and the slot itself is only written once the run finishes.
var _gen: LiteTerrainGen = null
var _gen_slot: int = -1
var _gen_seed: int = 0
var _gen_t0: float = 0.0
var _gen_frac: float = 0.0
var _gen_eta: float = -1.0
var _gen_label: String = ""
var _gen_done: bool = false
var _c_stage: Label = null
var _c_bar: ProgressBar = null
var _c_eta: Label = null
## Is the slot list open? First screen is PLAY / SETTINGS, second is the three worlds.
var _slots_open: bool = false

func _ready() -> void:
	%TitleVersion.text = "v%s" % str(ProjectSettings.get_setting("application/config/version", "dev"))
	%NewsScroll.custom_minimum_size.y = get_viewport().get_visible_rect().size.y * NEWS_H_FRAC
	_fill_news()
	_bind_settings()
	_rebuild_left()

# ── News ─────────────────────────────────────────────────────────────────────
## A DATED feed, not a list of small change notes. What goes in: things that change the game for
## the PLAYER - a mechanic, an opponent, an economy rule. The feed scrolls, so someone returning
## after a month sees what they missed rather than the last line only.
##
## The list lives here rather than being fetched: the game is offline, and a request nobody
## answers is a startup delay plus an error screen.
const NEWS := [
	{"date": "06.09.2026", "title": "МИР БЕЗ КРАЯ", "lines": [
		"Земля больше не кончается: она СЧИТАЕТСЯ вокруг машины, а не читается из файла. Едешь в любую сторону — край не найдёшь.",
		"Три слота сохранения. Мир и прохождение живут отдельно: карту можно создать заранее, сбросить прогресс и остаться на ней, или снести целиком.",
		"На фоне этого меню дерутся настоящие машины из настоящих блоков — те же, что собираешь ты.",
	]},
	{"date": "23.08.2026", "title": "ОБОРОНА", "lines": [
		"Укреплённые точки стоят НА КАРТЕ и не переезжают за спиной. Зачистил — навсегда, и сверху падают слитки металла этого биома.",
		"Поворотные башни: корпус сам доворачивается к цели, стволы держат сектор. Вскрываются через энергию — сбей панели, и щит погаснет сам.",
		"Рейды на базу: чем дороже постройка, тем короче пауза между налётами. Предупреждение приходит за двадцать секунд.",
	]},
	{"date": "07.08.2026", "title": "ПРОИЗВОДСТВО", "lines": [
		"Скидки переехали из рынка в магазин: три блока дешевле на пятнадцать минут — там, где их и покупают.",
		"Контракты Системы: привези металл к сроку, платят с наценкой. Срок тикает прямо в описании задания.",
		"Собрать блок самому теперь ВЫГОДНЕЕ, чем продать материалы и купить его же. Иначе вся линия была чистым проигрышем.",
	]},
	{"date": "18.07.2026", "title": "БОЙ", "lines": [
		"Машина разваливается ДО того, как её добьют: сбитые блоки падают в мир, а догоревший фитиль взрывается вместе с соседями.",
		"Разброс у стволов угловой и растёт с дистанцией — очередь ложится по машине, а не в одну заклёпку.",
		"От врага можно УЕХАТЬ: битый теряет интерес и уводит патруль прочь. Добиваешь — снова дерётся.",
	]},
]

func _fill_news() -> void:
	for rel in NEWS:
		var head := HBoxContainer.new()
		head.add_theme_constant_override("separation", 8)
		var date := Label.new()
		date.text = String(rel["date"])
		date.add_theme_font_size_override("font_size", 11)
		date.add_theme_color_override("font_color", DIM * Color(1, 1, 1, 0.75))
		head.add_child(date)
		var title := Label.new()
		title.text = String(rel["title"])
		title.add_theme_font_size_override("font_size", 13)
		title.add_theme_color_override("font_color", ACCENT)
		head.add_child(title)
		_news_list.add_child(head)
		for line in rel["lines"]:
			var l := Label.new()
			l.text = "· " + String(line)
			l.add_theme_font_size_override("font_size", 12)
			l.add_theme_color_override("font_color", TEXT * Color(1, 1, 1, 0.86))
			l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			_news_list.add_child(l)

# ── Settings ─────────────────────────────────────────────────────────────────
## The camera values are the same ones as in game (`hud._build_settings_panel`) and the same `G`
## fields (settings.json): one setting, wherever it is opened. A separate copy exists here only
## because the HUD does not exist before entering a world.
##
## The menu fight switch is the exception - it belongs to this screen alone, and the stage is told
## about it straight away rather than at the next start.
func _bind_settings() -> void:
	var look: HSlider = %LookSlider
	var zoom: HSlider = %ZoomSlider
	look.value = G.cam_look_sens
	zoom.value = G.cam_zoom_sens
	%LookValue.text = "%.2f" % G.cam_look_sens
	%ZoomValue.text = "%.2f" % G.cam_zoom_sens
	look.value_changed.connect(_on_look_sens)
	zoom.value_changed.connect(_on_zoom_sens)
	var inv: CheckButton = %InvertY
	inv.button_pressed = G.cam_invert_y
	inv.toggled.connect(_on_invert_y)
	var fight: CheckButton = %MenuFight
	fight.button_pressed = G.menu_battles
	fight.toggled.connect(_on_menu_fight)
	(%CloseSettings as Button).pressed.connect(_close_settings)

func _on_look_sens(v: float) -> void:
	G.cam_look_sens = v
	%LookValue.text = "%.2f" % v
	G.save_settings()

func _on_zoom_sens(v: float) -> void:
	G.cam_zoom_sens = v
	%ZoomValue.text = "%.2f" % v
	G.save_settings()

func _on_invert_y(on: bool) -> void:
	G.cam_invert_y = on
	G.save_settings()

## Switched here and taken up at once: the fight either starts on the spot or is cleared away with
## its map. Waiting for a restart to show what a switch did is how a switch gets pressed twice.
func _on_menu_fight(on: bool) -> void:
	G.menu_battles = on
	G.save_settings()
	var stage := get_node_or_null("%Stage")
	if stage != null and stage.has_method("set_battles"):
		stage.set_battles(on)

func _open_settings() -> void:
	_settings.visible = true

func _close_settings() -> void:
	_settings.visible = false

# ── Left column: three states ────────────────────────────────────────────────
## Rebuilt whole: there are three states with three or four widgets each, so building anew is
## cheaper than holding references and toggling visibility.
func _rebuild_left() -> void:
	for c in _left.get_children():
		c.queue_free()
	if _gen_slot >= 0:
		_left.add_child(_create_panel())
		return
	if _slots_open:
		_left.add_child(_slots_panel())
		_left.add_child(_button("BACK", DIM, _close_slots))
		return
	_left.add_child(_big_button("PLAY", _open_slots))
	_left.add_child(_button("SETTINGS", DIM, _open_settings))
	if OS.has_feature("pc"):
		_left.add_child(_button("QUIT", DIM, func(): get_tree().quit()))

func _open_slots() -> void:
	_slots_open = true
	_rebuild_left()

func _close_slots() -> void:
	_slots_open = false
	_rebuild_left()

func _slots_panel() -> Control:
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", _panel_style())
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	panel.add_child(box)
	var head := Label.new()
	head.text = "CHOOSE A WORLD"
	head.add_theme_font_size_override("font_size", 11)
	head.add_theme_color_override("font_color", ACCENT * Color(1, 1, 1, 0.9))
	box.add_child(head)
	for i in G.SLOT_COUNT:
		box.add_child(_slot_row(i))
	return panel

## A SLOT ROW. World and playthrough are separate things, so the buttons follow their states:
##   no world              -> CREATE
##   world, no progress    -> PLAY + delete
##   world and progress    -> PLAY + RESET (wipe the playthrough, keep the map) + delete
## Slot one is special: its map ships with the game, there is nothing to delete.
##
## Deleting is HOLD, not a second tap. A tap next to PLAY erases a world that took a minute to
## compute, and a confirm button is caught by the same mis-tap; a hold cannot be mis-tapped and
## shows what it is doing while the bar fills.
func _slot_row(i: int) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)

	var info := VBoxContainer.new()
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	info.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	info.add_theme_constant_override("separation", -2)
	row.add_child(info)

	var name_lbl := Label.new()
	name_lbl.text = "SLOT %d" % (i + 1)
	name_lbl.add_theme_font_size_override("font_size", 16)
	name_lbl.add_theme_color_override("font_color", TEXT)
	info.add_child(name_lbl)

	var has_world: bool = i == 0 or G.slot_has_world(i)
	var d: Dictionary = G.slot_info(i)
	var desc := Label.new()
	desc.add_theme_font_size_override("font_size", 12)
	desc.add_theme_color_override("font_color", DIM)
	if not d.is_empty():
		desc.text = "%d$ · %d blocks · %d directives" \
				% [int(d.get("money", 0)), int(d.get("researched", 0)), int(d.get("quests", 0))]
	elif has_world:
		# Slot one is "our" map: a constant seed, the same veins and points it always had.
		desc.text = "The original world · not started" if i == 0 else "World ready · not started"
	else:
		desc.text = "No world yet"
	info.add_child(desc)

	if not has_world:
		row.add_child(_button("CREATE", ACCENT, _begin_create.bind(i)))
		return row
	# The slot played last is labelled CONTINUE: with one world that is the most common action.
	var lbl: String = "CONTINUE" if (not d.is_empty() and i == G.last_slot()) else "PLAY"
	row.add_child(_button(lbl, ACCENT, _play_slot.bind(i)))
	if not d.is_empty():
		row.add_child(_button("RESET", DIM, _reset_slot.bind(i)))
	if i != 0:
		row.add_child(_hold_button("DELETE", _delete_slot.bind(i)))
	return row

func _play_slot(i: int) -> void:
	G.use_slot(i)
	_start_game()

func _reset_slot(i: int) -> void:
	G.reset_progress(i)
	_rebuild_left()

func _delete_slot(i: int) -> void:
	G.delete_world(i)
	_rebuild_left()

## Hold-to-fire button: it keeps its own timer and draws the fill over its own style. Until the
## bar reaches the edge nothing happened, and releasing resets it.
class HoldButton extends Button:
	signal confirmed
	const HOLD := 1.2
	var _t: float = 0.0
	var fill := Color(1.0, 0.45, 0.35, 0.35)

	func _ready() -> void:
		set_process(false)
		button_down.connect(func(): _t = 0.0; set_process(true))
		button_up.connect(func(): _t = 0.0; set_process(false); queue_redraw())

	func _process(delta: float) -> void:
		_t += delta
		queue_redraw()
		if _t >= HOLD:
			set_process(false)
			_t = 0.0
			confirmed.emit()

	func _draw() -> void:
		if _t <= 0.0:
			return
		draw_rect(Rect2(Vector2.ZERO, Vector2(size.x * (_t / HOLD), size.y)), fill, true)

func _hold_button(text: String, cb: Callable) -> Button:
	var b := HoldButton.new()
	b.text = text
	b.custom_minimum_size = Vector2(88, 48)
	b.add_theme_font_size_override("font_size", 14)
	b.add_theme_color_override("font_color", DANGER)
	b.add_theme_color_override("font_hover_color", TEXT)
	b.add_theme_color_override("font_pressed_color", TEXT)
	b.add_theme_stylebox_override("normal", _btn_style(false))
	b.add_theme_stylebox_override("hover", _btn_style(false))
	b.add_theme_stylebox_override("pressed", _btn_style(true))
	b.confirmed.connect(cb)
	b.tooltip_text = "Hold"
	return b

# ── Generation panel ─────────────────────────────────────────────────────────
## Widgets are kept by reference: their captions change every frame, and rebuilding the panel
## thirty times a second is a button flickering under the finger.
func _create_panel() -> Control:
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", _panel_style())
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	panel.add_child(box)
	var head := Label.new()
	head.text = "CREATING WORLD · SLOT %d" % (_gen_slot + 1)
	head.add_theme_font_size_override("font_size", 13)
	head.add_theme_color_override("font_color", ACCENT)
	box.add_child(head)

	_c_stage = Label.new()
	_c_stage.add_theme_font_size_override("font_size", 12)
	_c_stage.add_theme_color_override("font_color", DIM)
	box.add_child(_c_stage)

	_c_bar = ProgressBar.new()
	_c_bar.min_value = 0.0
	_c_bar.max_value = 1.0
	_c_bar.step = 0.001
	_c_bar.show_percentage = false
	_c_bar.custom_minimum_size = Vector2(COL_W, 10)
	box.add_child(_c_bar)

	_c_eta = Label.new()
	_c_eta.add_theme_font_size_override("font_size", 12)
	_c_eta.add_theme_color_override("font_color", DIM)
	box.add_child(_c_eta)

	if _gen_done:
		# TWO ways out, not one: the world may have been computed to be entered later.
		box.add_child(_big_button("PLAY", _play_created))
		box.add_child(_button("BACK TO SLOTS", DIM, _leave_create))
	else:
		box.add_child(_button("STOP", DANGER, _stop_create))
	_update_create()
	return panel

func _process(_delta: float) -> void:
	if _gen_slot >= 0:
		_update_create()

func _update_create() -> void:
	if _c_stage == null or not is_instance_valid(_c_stage):
		return
	if _gen_done:
		_c_stage.text = "World ready · seed %d" % _gen_seed
		_c_bar.value = 1.0
		_c_eta.text = "Press PLAY to enter"
		return
	_c_stage.text = _gen_label
	_c_bar.value = _gen_frac
	# Estimate over the whole run (elapsed × (1−frac)/frac) and SMOOTHED: rows inside a pass are
	# not equal, so the raw number jumps every frame.
	var el: float = float(Time.get_ticks_msec()) / 1000.0 - _gen_t0
	if _gen_frac > 0.02:
		var raw: float = el * (1.0 - _gen_frac) / _gen_frac
		_gen_eta = raw if _gen_eta < 0.0 else lerpf(_gen_eta, raw, 0.08)
	_c_eta.text = "%d%%   ·   %s left" % [int(_gen_frac * 100.0), _time_text(_gen_eta)]

func _time_text(sec: float) -> String:
	if sec < 0.0:
		return "estimating"
	if sec < 60.0:
		return "%ds" % int(sec)
	return "%d:%02d" % [int(sec) / 60, int(sec) % 60]

## The run. The seed is picked here, but the slot is only written when it finishes: stopping
## halfway must leave whatever was there intact.
func _begin_create(i: int) -> void:
	if _gen_slot >= 0:
		return
	_gen_slot = i
	_gen_seed = G.roll_world_seed()
	_gen_done = false
	_gen_frac = 0.0
	_gen_eta = -1.0
	_gen_label = "starting"
	_gen_t0 = float(Time.get_ticks_msec()) / 1000.0
	_rebuild_left()

	var gen := LiteTerrainGen.new()
	add_child(gen)
	gen.gen_seed = _gen_seed
	var params: Dictionary = LiteTerrainGen.default_params()
	gen.apply_params(params)
	gen.on_progress = func(step: String, frac: float) -> void:
		_gen_label = step
		_gen_frac = frac
	_gen = gen
	var size: int = LiteTerrainGen.DEF_WINDOW
	var x0: int = -size / 2
	var z0: int = -size / 2
	# Default biomes. Only the MASK fields affect heights, and the map scene overrides colouring
	# only. Touch a mask there and the strips computed later will not meet what the menu produced.
	var md: PackedFloat32Array = await gen.generate_region(x0, z0, size, size, TerrainBiomes.new())
	var ok: bool = not gen.cancelled() and md.size() == size * size
	gen.queue_free()
	_gen = null
	if not ok:
		_gen_slot = -1
		_rebuild_left()
		return
	G.set_pending_world(_gen_seed, Vector2i(x0, z0), size, md, params)
	G.create_world(_gen_slot, _gen_seed, Vector2i(x0, z0), size, md)
	_gen_done = true
	_rebuild_left()

func _stop_create() -> void:
	if _gen != null and is_instance_valid(_gen):
		_gen.stop()          # the run stops between passes and returns nothing
		return
	_gen_slot = -1
	_rebuild_left()

func _play_created() -> void:
	var i: int = _gen_slot
	_gen_slot = -1
	_play_slot(i)          # the world is already written, there is nothing to wipe

func _leave_create() -> void:
	_gen_slot = -1
	_slots_open = true
	_rebuild_left()

# ── Widgets built from data ──────────────────────────────────────────────────
func _big_button(text: String, cb: Callable) -> Button:
	var b := _button(text, ACCENT, cb)
	b.custom_minimum_size = Vector2(COL_W, 64)
	b.add_theme_font_size_override("font_size", 22)
	return b

func _button(text: String, col: Color, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(88, 48)      # minimum finger target
	b.add_theme_font_size_override("font_size", 14)
	b.add_theme_color_override("font_color", col)
	b.add_theme_color_override("font_hover_color", TEXT)
	b.add_theme_color_override("font_pressed_color", TEXT)
	b.add_theme_stylebox_override("normal", _btn_style(false))
	b.add_theme_stylebox_override("hover", _btn_style(true))
	b.add_theme_stylebox_override("pressed", _btn_style(true))
	b.pressed.connect(cb)
	return b

func _panel_style() -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = Color(0.055, 0.125, 0.141, 0.78)
	s.set_corner_radius_all(5)
	s.set_content_margin_all(10)
	s.border_color = ACCENT * Color(1, 1, 1, 0.28)
	s.set_border_width_all(1)
	return s

func _btn_style(hot: bool) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = ACCENT * Color(1, 1, 1, 0.26) if hot else Color(0.02, 0.05, 0.06, 0.72)
	s.set_corner_radius_all(4)
	s.set_content_margin_all(6)
	s.border_color = ACCENT * Color(1, 1, 1, 0.45)
	s.set_border_width_all(1)
	return s

## The game scene loads under the same persistent overlay as before (loading_boot.gd): it lives
## next to current_scene, so it survives the scene change and stays on top until the terrain is up.
func _start_game() -> void:
	var overlay := LOADING.new()
	overlay.next_scene = GAME_SCENE
	get_tree().root.add_child.call_deferred(overlay)
