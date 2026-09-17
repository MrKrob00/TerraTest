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
# Создание мира — это выбор сида. Шкала, оценка времени и STOP тут были, пока земля считалась
# окном на весь мир вперёд; чанковый рельеф считает её по ходу игры, и ждать стало нечего.
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
	{"date": "15.09.2026", "title": "БЕСКОНЕЧНАЯ ГЕНЕРАЦИЯ", "lines": [
		"Генерация мира теперь бесконечная и процедурная: земля считается по ходу игры, а не читается готовой.",
		"При загрузке в мир карта больше не требует много времени.",
		"Были исправлены некоторые баги.",
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
	_bind_lang()
	(%CloseSettings as Button).pressed.connect(_close_settings)

## ЯЗЫК. Подписи пунктов — на своих языках, а не переведённые: человек, открывший чужой язык по
## ошибке, должен найти свой в списке, не понимая ни слова вокруг.
const LANG_NAMES := {"en": "English", "ru": "Русский", "uk": "Українська"}

func _bind_lang() -> void:
	var pick: OptionButton = %LangPick
	pick.clear()
	var cur: String = G.current_lang()
	for i in G.LANGS.size():
		var code: String = String(G.LANGS[i])
		pick.add_item(String(LANG_NAMES.get(code, code)), i)
		if code == cur:
			pick.select(i)
	pick.item_selected.connect(_on_lang_picked)

## Переключение языка ПЕРЕСОБИРАЕТ экран: подписи уже нарисованы, и сами по себе они не меняются —
## сцена переводится при загрузке, а кнопки слева вообще строятся кодом.
func _on_lang_picked(idx: int) -> void:
	if idx < 0 or idx >= G.LANGS.size():
		return
	G.set_lang(String(G.LANGS[idx]))
	_rebuild_left()

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
	if _slots_open:
		_left.add_child(_slots_panel())
		_left.add_child(_button(tr("BACK"), DIM, _close_slots))
		return
	_left.add_child(_big_button(tr("PLAY"), _open_slots))
	_left.add_child(_button(tr("SETTINGS"), DIM, _open_settings))
	if OS.has_feature("pc"):
		_left.add_child(_button(tr("QUIT"), DIM, func(): get_tree().quit()))

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
	head.text = tr("CHOOSE A WORLD")
	head.add_theme_font_size_override("font_size", 11)
	head.add_theme_color_override("font_color", ACCENT * Color(1, 1, 1, 0.9))
	box.add_child(head)
	for i in G.SLOT_COUNT:
		box.add_child(_slot_row(i))
	return panel

## A SLOT ROW: нет мира — CREATE, есть — PLAY и DELETE.
##
## СБРОСА ПРОХОЖДЕНИЯ ОТДЕЛЬНОЙ КНОПКОЙ БОЛЬШЕ НЕТ. Он существовал, пока мир был дорогим: карту
## считали минуту, и терять её из-за «начать заново» было жалко. Мир теперь это сид, создание
## мгновенное, и две кнопки про одно и то же («стереть прохождение» рядом со «стереть мир»)
## отличались только тем, чего игрок не видит.
##
## Удаление — УДЕРЖАНИЕ, потом вопрос. Тап рядом с PLAY стирает слот, а удержание не нажимается
## случайно и показывает, что делает, пока ползёт полоса; вопрос после него называет слот вслух.
## Первый слот не исключение: карта у него своя, постоянная, и удаление стирает прохождение —
## мир на том же сиде вернётся при следующем входе.
func _slot_row(i: int) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)

	var info := VBoxContainer.new()
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	info.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	info.add_theme_constant_override("separation", -2)
	row.add_child(info)

	var name_lbl := Label.new()
	name_lbl.text = tr("SLOT %d") % (i + 1)
	name_lbl.add_theme_font_size_override("font_size", 16)
	name_lbl.add_theme_color_override("font_color", TEXT)
	info.add_child(name_lbl)

	var has_world: bool = G.slot_has_world(i)
	var d: Dictionary = G.slot_info(i)
	var desc := Label.new()
	desc.add_theme_font_size_override("font_size", 12)
	desc.add_theme_color_override("font_color", DIM)
	if not d.is_empty():
		desc.text = tr("%d$ · %d blocks · %d directives") \
				% [int(d.get("money", 0)), int(d.get("researched", 0)), int(d.get("quests", 0))]
	elif has_world:
		desc.text = tr("World ready · not started")
	else:
		desc.text = tr("No world yet")
	info.add_child(desc)

	if not has_world:
		row.add_child(_button(tr("CREATE"), ACCENT, _begin_create.bind(i)))
		return row
	# The slot played last is labelled CONTINUE: with one world that is the most common action.
	var lbl: String = tr("CONTINUE") if (not d.is_empty() and i == G.last_slot()) else tr("PLAY")
	row.add_child(_button(lbl, ACCENT, _play_slot.bind(i)))
	row.add_child(_hold_button(tr("DELETE"), _ask_delete.bind(i)))
	return row

func _play_slot(i: int) -> void:
	G.use_slot(i)
	_start_game()

## Удержание довели до конца — спрашиваем словами. Одно и то же действие стирает и мир, и
## сохранение: с тех пор как мир это сид, отдельного «сбросить прохождение» нет.
var _del_dialog: ConfirmationDialog = null
var _del_slot: int = -1

func _ask_delete(i: int) -> void:
	_del_slot = i
	if _del_dialog == null or not is_instance_valid(_del_dialog):
		_del_dialog = ConfirmationDialog.new()
		_del_dialog.title = tr("Delete world")
		_del_dialog.ok_button_text = tr("DELETE")
		_del_dialog.confirmed.connect(_delete_slot)
		add_child(_del_dialog)
	# Называем то, что в слоте ЕСТЬ: обещать стереть сохранение там, где игрок ни разу не входил,
	# значит пугать несуществующим.
	var msg: String = tr("Slot %d: the world and the save are erased. This cannot be undone.") \
			if G.slot_used(i) else tr("Slot %d: the world is erased. This cannot be undone.")
	_del_dialog.dialog_text = msg % (i + 1)
	_del_dialog.popup_centered(Vector2i(380, 140))

func _delete_slot() -> void:
	if _del_slot < 0:
		return
	G.delete_world(_del_slot)
	_del_slot = -1
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
	b.tooltip_text = tr("Hold")
	return b

## СОЗДАНИЕ МИРА — ЭТО ВЫБОР СИДА, и экрана у него больше нет. Раньше здесь минуту считалось
## окно высот на весь мир — со шкалой, оценкой времени и кнопкой «Стоп», — и в конце показывалась
## панель с выбором «играть» или «назад к слотам». Землю теперь считает чанковый рельеф по ходу
## игры, ждать нечего, и выбирать после мгновенного действия тоже нечего: слот появляется в том
## же списке, где на него и нажали.
func _begin_create(i: int) -> void:
	G.create_world(i, G.roll_world_seed())
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
