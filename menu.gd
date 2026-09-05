extends Control
## ГЛАВНОЕ МЕНЮ — первое, что видит игрок. Собрано КОДОМ, а не сценой, по той же причине, по
## которой кодом собраны иконки HUD: тут нет ни одного «стоящего» элемента, всё строится ПО
## ДАННЫМ — три слота, у каждого своя надпись и своё состояние. Нодовая сцена всё равно
## наполнялась бы из кода, а править пришлось бы два места.
##
## МЕНЮ ИДЁТ ДО ЗАГРУЗКИ МИРА, и это не косметика. Слот выбирается ЗДЕСЬ, а G.use_slot должен
## отработать раньше, чем карта, машины и жилы начнут читать свои файлы: иначе первый кадр игры
## успевает прочитать чужой мир. Поэтому главная сцена проекта — меню, а игровая грузится тем же
## стойким оверлеем, каким её грузил мини-бут (loading_boot.gd).
##
## ── РАСКЛАДКА: ФОН ЖИВОЙ, УПРАВЛЕНИЕ ВНИЗУ ───────────────────────────────────────────────
## Задник — идущий сам по себе БОЙ МАШИН, и он занимает весь экран. Значит меню обязано не
## закрывать его: панели прижаты к НИЗУ (там и палец на телефоне), а верх остаётся картинкой.
## Никакой полупрозрачной простыни поверх всего: она гасит ровно то, ради чего задник и делался.
##
## Читаемость даёт не заливка, а ГРАДИЕНТ СНИЗУ — тёмная полоса под панелями, сходящая на нет к
## середине экрана. Текст на ней читается на любом кадре боя, а небо и горы остаются чистыми.
const GAME_SCENE := "res://node_3d.tscn"
const LOADING := preload("res://loading_screen.gd")
const BATTLE := preload("res://menu_battle.gd")

# Палитра — та же тёмно-бирюзовая, что во всём интерфейсе (hud.gd, tech_ui.gd): меню обязано
# выглядеть частью игры, а не отдельным приложением перед ней.
const PANEL   := Color(0.055, 0.125, 0.141, 0.72)
const ACCENT  := Color(0.35, 0.85, 0.92)
const TEXT    := Color(0.88, 0.97, 0.99)
const DIM     := Color(0.55, 0.72, 0.76)
const DANGER  := Color(1.0, 0.45, 0.35)

## Ширина колонки меню. Ограничена: на планшете растянутый на всю ширину список слотов читается
## как таблица, а палец всё равно ходит по одной стороне экрана.
const COL_W := 460.0
## Сколько высоты экрана занимает тёмный градиент под панелями.
const FADE_FRAC := 0.62

var _slots_box: VBoxContainer = null
## Какой слот ждёт подтверждения перезаписи. −1 — никто не ждёт. Второй тап по той же кнопке
## подтверждает: отдельного модального окна тут не нужно, а спросить обязательно — «Новая игра»
## по занятому слоту стирает мир, и промах пальцем не должен этого делать.
var _confirm_slot: int = -1

func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	_build_background()
	_build_foreground()

# ── Задник ───────────────────────────────────────────────────────────────────
func _build_background() -> void:
	var battle := BATTLE.new()
	battle.set_anchors_preset(Control.PRESET_FULL_RECT)
	battle.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(battle)
	# Градиент снизу. Именно TextureRect с GradientTexture2D, а не ColorRect с альфой: сплошная
	# заливка либо не даёт читаемости, либо съедает картинку целиком, а плавный переход делает
	# и то и другое сразу.
	var fade := TextureRect.new()
	var g := Gradient.new()
	g.set_color(0, Color(0.02, 0.05, 0.06, 0.0))
	g.set_color(1, Color(0.02, 0.05, 0.06, 0.94))
	var tex := GradientTexture2D.new()
	tex.gradient = g
	tex.fill_from = Vector2(0.5, 0.0)
	tex.fill_to = Vector2(0.5, 1.0)
	tex.width = 4
	tex.height = 256
	fade.texture = tex
	fade.stretch_mode = TextureRect.STRETCH_SCALE
	fade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	fade.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	fade.anchor_top = 1.0 - FADE_FRAC
	fade.offset_top = 0.0
	fade.offset_bottom = 0.0
	add_child(fade)

# ── Передний план ────────────────────────────────────────────────────────────
func _build_foreground() -> void:
	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	for side in ["margin_left", "margin_right", "margin_top", "margin_bottom"]:
		margin.add_theme_constant_override(side, 20)
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(margin)

	# Всё прижато вниз: верх экрана отдан бою. На телефоне это ещё и единственная зона, куда
	# уверенно достаёт большой палец.
	var col := VBoxContainer.new()
	col.alignment = BoxContainer.ALIGNMENT_END
	col.add_theme_constant_override("separation", 10)
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	margin.add_child(col)

	col.add_child(_news_panel())
	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0, 4)
	col.add_child(spacer)
	col.add_child(_title_row())

	_slots_box = VBoxContainer.new()
	_slots_box.add_theme_constant_override("separation", 6)
	_slots_box.custom_minimum_size = Vector2(COL_W, 0)
	_slots_box.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	col.add_child(_narrow(_slots_box))
	_rebuild_slots()
	col.add_child(_narrow(_footer()))

## Обёртка, ограничивающая ширину колонки. Контейнер сам решает размер детей, поэтому ширину
## задаём его собственным минимумом, а не позицией внутри (правило движка: детям контейнера
## позицию не ставим).
func _narrow(inner: Control) -> Control:
	var h := HBoxContainer.new()
	h.mouse_filter = Control.MOUSE_FILTER_IGNORE
	inner.custom_minimum_size = Vector2(COL_W, inner.custom_minimum_size.y)
	inner.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	h.add_child(inner)
	var pad := Control.new()
	pad.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	pad.mouse_filter = Control.MOUSE_FILTER_IGNORE
	h.add_child(pad)
	return h

func _title_row() -> Control:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", -4)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var t := Label.new()
	t.text = "WORLDTECH"
	t.add_theme_font_size_override("font_size", 40)
	t.add_theme_color_override("font_color", TEXT)
	box.add_child(t)
	var sub := Label.new()
	sub.text = "v%s" % str(ProjectSettings.get_setting("application/config/version", "dev"))
	sub.add_theme_font_size_override("font_size", 12)
	sub.add_theme_color_override("font_color", DIM * Color(1, 1, 1, 0.8))
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
	"Три мира: слоты сохранения, у каждого свои жилы и укреплённые точки.",
	"Взрыв и фитиль переведены на красную матрицу — частиц в игре больше нет ни одной.",
	"Скидки переехали из рынка в магазин: три блока со скидкой, пятнадцать минут.",
	"Сюжетные блоки теперь отбирают у врага и выкапывают из жилы.",
]

func _news_panel() -> Control:
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", _panel_style())
	panel.custom_minimum_size = Vector2(COL_W, 0)
	panel.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
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
	return _narrow(panel)

# ── Слоты ────────────────────────────────────────────────────────────────────
## Три ряда. Пересобираются целиком после любого действия: рядов три, а состояний у них два —
## дешевле построить заново, чем держать ссылки на восемь виджетов и обновлять их по одному.
func _rebuild_slots() -> void:
	for c in _slots_box.get_children():
		c.queue_free()
	for i in G.SLOT_COUNT:
		_slots_box.add_child(_slot_row(i))

func _slot_row(i: int) -> Control:
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", _panel_style())
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	panel.add_child(row)

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
		row.add_child(_button("PLAY", ACCENT, _on_play.bind(i)))
	# «Новая игра» на занятом слоте — это стирание мира, поэтому она спрашивает. Подтверждение
	# живёт на самой кнопке (второй тап), а не в отдельном окне: окно поверх меню пришлось бы
	# строить, гасить ввод под ним и закрывать — ради одного вопроса, который умещается в надпись.
	var new_label: String = "ERASE?" if (used and _confirm_slot == i) else "NEW"
	row.add_child(_button(new_label, DANGER if _confirm_slot == i else DIM, _on_new.bind(i)))
	return panel

func _footer() -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	# ПРОДОЛЖИТЬ — самая частая кнопка, и она ведёт в последний слот, в котором играли: игрок,
	# у которого мир один, не должен каждый раз выбирать его из трёх.
	var last: int = G.last_slot()
	if G.slot_used(last):
		var b := _button("CONTINUE · SLOT %d" % (last + 1), ACCENT, _on_play.bind(last))
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(b)
	if OS.has_feature("pc"):
		row.add_child(_button("QUIT", DIM, func(): get_tree().quit()))
	return row

# ── Виджеты ──────────────────────────────────────────────────────────────────
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
	s.bg_color = ACCENT * Color(1, 1, 1, 0.26) if hot else Color(0, 0, 0, 0.35)
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
		_rebuild_slots()
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
