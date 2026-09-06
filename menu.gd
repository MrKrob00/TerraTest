extends Node3D
## ГЛАВНОЕ МЕНЮ — первое, что видит игрок.
##
## МЕНЮ ИДЁТ ДО ЗАГРУЗКИ МИРА, и это не косметика. Слот выбирается ЗДЕСЬ, а `G.use_slot` должен
## отработать раньше, чем карта, машины и жилы начнут читать свои файлы: иначе первый кадр игры
## успевает прочитать чужой мир. Поэтому главная сцена проекта — меню, а игровая грузится тем же
## стойким оверлеем, каким её грузил мини-бут (`loading_boot.gd`).
##
## ── ПОЧЕМУ КОРЕНЬ — Node3D ───────────────────────────────────────────────────────────────
## Задник теперь НАСТОЯЩАЯ 3D-СЦЕНА (`menu_stage_3d.gd`): те же блоки, из которых игрок собирает
## машину. Значит, меню обязано быть трёхмерным узлом с камерой, а интерфейс живёт на
## `CanvasLayer` поверх него. `SubViewport` не годится: это лишняя цель рендера на телефоне ради
## картинки, которую и так рисуют в основной кадр.
##
## ── РАСКЛАДКА: УГЛЫ, А НЕ ПРОСТЫНЯ ───────────────────────────────────────────────────────
## Центр экрана отдан бою целиком. Управление — В ЛЕВОМ НИЖНЕМ УГЛУ (единственная зона, куда
## уверенно достаёт большой палец), новости — в ПРАВОМ ВЕРХНЕМ (их читают глазами, а не
## пальцем). Никакого затемнения поверх всего: читаемость даёт подложка самих панелей и обводка
## заголовка, а не потушенная картинка — гасить задник значит отменить то, ради чего он сделан.
##
## Слоты появляются ТОЛЬКО ПОСЛЕ «PLAY». Первый экран должен отвечать на один вопрос — играть
## или нет; выбор из трёх миров нужен вторым шагом и не должен встречать игрока сразу.
const GAME_SCENE := "res://node_3d.tscn"
const LOADING := preload("res://loading_screen.gd")
const STAGE := preload("res://menu_stage_3d.gd")

# Палитра — та же тёмно-бирюзовая, что во всём интерфейсе (hud.gd, tech_ui.gd): меню обязано
# выглядеть частью игры, а не отдельным приложением перед ней.
const PANEL   := Color(0.055, 0.125, 0.141, 0.78)
const ACCENT  := Color(0.35, 0.85, 0.92)
const TEXT    := Color(0.88, 0.97, 0.99)
const DIM     := Color(0.62, 0.78, 0.82)
const DANGER  := Color(1.0, 0.45, 0.35)

## Ширина колонки слотов и панели новостей. Ограничена: на планшете растянутый на всю ширину
## список читается как таблица, а палец всё равно ходит по одной стороне экрана.
const COL_W := 420.0
const NEWS_W := 360.0

var _left: VBoxContainer = null          # колонка в левом нижнем углу
var _settings: CenterContainer = null
## Открыт ли выбор слота. Первый экран — PLAY / SETTINGS, второй — три мира.
var _slots_open: bool = false
## Какой слот ждёт подтверждения перезаписи. −1 — никто не ждёт. Второй тап по той же кнопке
## подтверждает: отдельного модального окна тут не нужно, а спросить обязательно — «Новая игра»
## по занятому слоту стирает мир, и промах пальцем не должен этого делать.
var _confirm_slot: int = -1

func _ready() -> void:
	add_child(STAGE.new())
	_build_ui()

# ── Каркас интерфейса ────────────────────────────────────────────────────────
func _build_ui() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)

	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	for side in ["margin_left", "margin_right", "margin_top", "margin_bottom"]:
		margin.add_theme_constant_override(side, 22)
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(margin)

	var col := VBoxContainer.new()
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	margin.add_child(col)

	# Верх: заголовок слева, новости справа.
	var top := HBoxContainer.new()
	top.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	top.mouse_filter = Control.MOUSE_FILTER_IGNORE
	top.add_child(_title_box())
	top.add_child(_spacer_h())
	top.add_child(_news_panel())
	col.add_child(top)

	col.add_child(_spacer_v())

	# Низ: колонка управления слева.
	var bottom := HBoxContainer.new()
	bottom.size_flags_vertical = Control.SIZE_SHRINK_END
	bottom.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_left = VBoxContainer.new()
	_left.add_theme_constant_override("separation", 8)
	_left.custom_minimum_size = Vector2(COL_W, 0)
	_left.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	_left.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bottom.add_child(_left)
	bottom.add_child(_spacer_h())
	col.add_child(bottom)

	_build_settings(layer)
	_rebuild_left()

func _spacer_h() -> Control:
	var c := Control.new()
	c.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return c

func _spacer_v() -> Control:
	var c := Control.new()
	c.size_flags_vertical = Control.SIZE_EXPAND_FILL
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return c

## Заголовок без подложки: читаемость даёт ОБВОДКА. Панель под ним закрыла бы кусок задника
## ради двух слов, а тёмный контур работает и на небе, и на земле.
func _title_box() -> Control:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", -4)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var t := Label.new()
	t.text = "WORLDTECH"
	t.add_theme_font_size_override("font_size", 40)
	t.add_theme_color_override("font_color", TEXT)
	t.add_theme_color_override("font_outline_color", Color(0.02, 0.05, 0.06, 0.85))
	t.add_theme_constant_override("outline_size", 6)
	box.add_child(t)
	var sub := Label.new()
	sub.text = "v%s" % str(ProjectSettings.get_setting("application/config/version", "dev"))
	sub.add_theme_font_size_override("font_size", 12)
	sub.add_theme_color_override("font_color", TEXT * Color(1, 1, 1, 0.75))
	sub.add_theme_color_override("font_outline_color", Color(0.02, 0.05, 0.06, 0.8))
	sub.add_theme_constant_override("outline_size", 4)
	box.add_child(sub)
	return box

# ── Новости ──────────────────────────────────────────────────────────────────
## ЧТО НОВОГО — прямо в меню, одной строкой на пункт. Игрок, вернувшийся через неделю, иначе
## узнаёт об изменениях только натыкаясь на них; а в бете это ещё и единственный способ сказать
## тестерам, что именно смотреть.
##
## Список ЖИВЁТ ЗДЕСЬ, а не тянется из сети: игра офлайновая, и запрос, которого некому
## ответить, — это только задержка на старте и экран с ошибкой.
const NEWS := [
	"Меню: настоящие машины на фоне, а не рисунок.",
	"Три мира: слоты сохранения, у каждого свои жилы и укреплённые точки.",
	"Карта без края: земля считается вокруг игрока, а не читается из файла.",
	"Скидки переехали из рынка в магазин: три блока со скидкой, пятнадцать минут.",
]

func _news_panel() -> Control:
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", _panel_style())
	panel.custom_minimum_size = Vector2(NEWS_W, 0)
	panel.size_flags_horizontal = Control.SIZE_SHRINK_END
	panel.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 2)
	panel.add_child(box)
	var head := Label.new()
	head.text = "WHAT'S NEW"
	head.add_theme_font_size_override("font_size", 11)
	head.add_theme_color_override("font_color", ACCENT * Color(1, 1, 1, 0.9))
	box.add_child(head)
	for line in NEWS:
		var l := Label.new()
		l.text = "· " + String(line)
		l.add_theme_font_size_override("font_size", 12)
		l.add_theme_color_override("font_color", DIM)
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		box.add_child(l)
	return panel

# ── Левая колонка: два состояния ─────────────────────────────────────────────
## Пересобирается целиком: состояний два, а виджетов в них по три-четыре — дешевле построить
## заново, чем держать ссылки и переключать видимость.
func _rebuild_left() -> void:
	for c in _left.get_children():
		c.queue_free()
	if _slots_open:
		_left.add_child(_slots_panel())
		# Именованный метод, а не лямбда: однострочная лямбда кончается на переносе строки, и
		# перенесённый хвост стал бы ЛИШНИМ АРГУМЕНТОМ вызова — синтаксис при этом верный.
		_left.add_child(_button("BACK", DIM, _close_slots))
		return
	_left.add_child(_big_button("PLAY", func(): _slots_open = true; _rebuild_left()))
	_left.add_child(_button("SETTINGS", DIM, func(): _settings.visible = true))
	if OS.has_feature("pc"):
		_left.add_child(_button("QUIT", DIM, func(): get_tree().quit()))

func _close_slots() -> void:
	_slots_open = false
	_confirm_slot = -1
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

	var desc := Label.new()
	desc.add_theme_font_size_override("font_size", 12)
	desc.add_theme_color_override("font_color", DIM)
	var d: Dictionary = G.slot_info(i)
	if d.is_empty():
		# ПЕРВЫЙ СЛОТ ИМЕНОВАН ОТДЕЛЬНО: у него постоянный сид, то есть «наша» карта — та же
		# раскладка жил и точек, что была всегда. Остальные два — новые миры со своим сидом.
		desc.text = "Empty · the original world" if i == 0 else "Empty · a new world"
	else:
		desc.text = "%d$ · %d blocks · %d directives" \
				% [int(d.get("money", 0)), int(d.get("researched", 0)), int(d.get("quests", 0))]
	info.add_child(desc)

	var used: bool = G.slot_used(i)
	if used:
		# Слот, в котором играли последним, назван CONTINUE: у игрока с одним миром «продолжить»
		# — самое частое действие, и отдельной кнопки для него не нужно.
		var lbl: String = "CONTINUE" if i == G.last_slot() else "PLAY"
		row.add_child(_button(lbl, ACCENT, _on_play.bind(i)))
	# «Новая игра» на занятом слоте — это стирание мира, поэтому она спрашивает. Подтверждение
	# живёт на самой кнопке (второй тап), а не в отдельном окне: окно поверх меню пришлось бы
	# строить, гасить ввод под ним и закрывать — ради одного вопроса, который умещается в надпись.
	var new_label: String = "ERASE?" if (used and _confirm_slot == i) else "NEW"
	row.add_child(_button(new_label, DANGER if _confirm_slot == i else DIM, _on_new.bind(i)))
	return row

# ── Настройки ────────────────────────────────────────────────────────────────
## Те же три значения, что и в игре (`hud._build_settings_panel`), и хранятся они в тех же полях
## `G` (settings.json): настройка обязана быть ОДНА, где бы её ни открыли. Здесь она нужна
## отдельно потому, что до входа в мир HUD ещё не существует.
func _build_settings(layer: CanvasLayer) -> void:
	# Окно, собранное кодом, центрируется CenterContainer, а не якорями: минимальный размер
	# панели меняется после того, как её набьют детьми, и пересчитывать смещения некому.
	_settings = CenterContainer.new()
	_settings.set_anchors_preset(Control.PRESET_FULL_RECT)
	_settings.visible = false
	layer.add_child(_settings)

	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", _panel_style())
	panel.custom_minimum_size = Vector2(380, 0)
	_settings.add_child(panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 12)
	panel.add_child(box)
	var head := Label.new()
	head.text = "CAMERA SETTINGS"
	head.add_theme_font_size_override("font_size", 16)
	head.add_theme_color_override("font_color", ACCENT)
	box.add_child(head)
	box.add_child(_slider("Rotation sensitivity", G.cam_look_sens,
			func(v: float): G.cam_look_sens = v; G.save_settings()))
	box.add_child(_slider("Zoom sensitivity", G.cam_zoom_sens,
			func(v: float): G.cam_zoom_sens = v; G.save_settings()))
	var cb := CheckButton.new()
	cb.text = "Invert vertical"
	cb.button_pressed = G.cam_invert_y
	cb.add_theme_color_override("font_color", TEXT)
	cb.toggled.connect(func(on: bool): G.cam_invert_y = on; G.save_settings())
	box.add_child(cb)
	box.add_child(_button("CLOSE", DIM, func(): _settings.visible = false))

func _slider(label: String, value: float, on_change: Callable) -> Control:
	var row := VBoxContainer.new()
	row.add_theme_constant_override("separation", 2)
	var l := Label.new()
	l.text = label
	l.add_theme_font_size_override("font_size", 13)
	l.add_theme_color_override("font_color", TEXT)
	row.add_child(l)
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 10)
	var s := HSlider.new()
	s.min_value = 0.2
	s.max_value = 3.0
	s.step = 0.05
	s.value = value
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	s.custom_minimum_size = Vector2(220, 32)
	var val := Label.new()
	val.text = "%.2f" % value
	val.custom_minimum_size = Vector2(52, 0)
	val.add_theme_color_override("font_color", ACCENT)
	s.value_changed.connect(func(v: float): val.text = "%.2f" % v; on_change.call(v))
	h.add_child(s)
	h.add_child(val)
	row.add_child(h)
	return row

# ── Виджеты ──────────────────────────────────────────────────────────────────
func _big_button(text: String, cb: Callable) -> Button:
	var b := _button(text, ACCENT, cb)
	b.custom_minimum_size = Vector2(COL_W, 64)
	b.add_theme_font_size_override("font_size", 22)
	return b

func _button(text: String, col: Color, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	# 48 по высоте — минимальная цель под палец; ниже на телефоне промахиваешься.
	b.custom_minimum_size = Vector2(88, 48)
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
	s.bg_color = PANEL
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

# ── Действия ─────────────────────────────────────────────────────────────────
func _on_play(i: int) -> void:
	G.use_slot(i)
	_start_game()

## НОВАЯ ИГРА. По пустому слоту начинает сразу; по занятому первый тап только СПРАШИВАЕТ —
## перезапись стирает мир, и промах пальцем по кнопке рядом с PLAY не должен этого делать.
func _on_new(i: int) -> void:
	if G.slot_used(i) and _confirm_slot != i:
		_confirm_slot = i
		_rebuild_left()
		return
	_confirm_slot = -1
	G.new_game(i)
	_start_game()

## Игровая сцена грузится ТЕМ ЖЕ стойким оверлеем, что и раньше (loading_boot.gd): он живёт
## соседом current_scene, поэтому переживает смену сцены и держится сверху, пока карта не
## построит рельеф. Меню при этом освобождается вместе со сценой — так и задумано.
func _start_game() -> void:
	var overlay := LOADING.new()
	overlay.next_scene = GAME_SCENE
	get_tree().root.add_child.call_deferred(overlay)
