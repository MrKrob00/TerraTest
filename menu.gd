extends Control
## ГЛАВНОЕ МЕНЮ — первое, что видит игрок. Собрано КОДОМ, а не сценой, по той же причине, по
## которой кодом собраны иконки HUD: тут нет ни одного «стоящего» элемента, всё строится ПО
## ДАННЫМ — три слота, у каждого своя надпись, свои кнопки и своё состояние (пустой/занятый).
## Нодовая сцена всё равно наполнялась бы из кода, а править пришлось бы два места.
##
## МЕНЮ ИДЁТ ДО ЗАГРУЗКИ МИРА, и это не косметика. Слот выбирается ЗДЕСЬ, а G.use_slot должен
## отработать раньше, чем карта, машины и жилы начнут читать свои файлы: иначе первый кадр игры
## успевает прочитать чужой мир. Поэтому главная сцена проекта — меню, а игровая сцена грузится
## тем же стойким оверлеем, каким её грузил мини-бут (loading_boot.gd).

const GAME_SCENE := "res://node_3d.tscn"
const LOADING := preload("res://loading_screen.gd")

# Палитра — та же тёмно-бирюзовая, что во всём интерфейсе (hud.gd, tech_ui.gd): меню обязано
# выглядеть частью игры, а не отдельным приложением перед ней.
const BG      := Color(0.031, 0.075, 0.086)
const PANEL   := Color(0.055, 0.125, 0.141, 0.95)
const ACCENT  := Color(0.247, 0.6, 0.65)
const TEXT    := Color(0.85, 0.95, 0.97)
const DIM     := Color(0.45, 0.62, 0.66)
const DANGER  := Color(1.0, 0.45, 0.35)

var _slots_box: VBoxContainer = null
var _root_box: VBoxContainer = null
## Какой слот ждёт подтверждения перезаписи. -1 — никто не ждёт. Второй тап по той же кнопке
## подтверждает: отдельного модального окна тут не нужно, а спросить обязательно — «Новая игра»
## по занятому слоту стирает мир, и промах пальцем не должен этого делать.
var _confirm_slot: int = -1

func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	var bg := ColorRect.new()
	bg.color = BG
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(center)

	_root_box = VBoxContainer.new()
	_root_box.add_theme_constant_override("separation", 14)
	_root_box.custom_minimum_size = Vector2(420, 0)
	center.add_child(_root_box)

	_add_title()
	_slots_box = VBoxContainer.new()
	_slots_box.add_theme_constant_override("separation", 8)
	_root_box.add_child(_slots_box)
	_rebuild_slots()
	_add_footer()

func _add_title() -> void:
	var t := Label.new()
	t.text = "WORLDTECH"
	t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	t.add_theme_font_size_override("font_size", 44)
	t.add_theme_color_override("font_color", TEXT)
	_root_box.add_child(t)
	var sub := Label.new()
	sub.text = "Choose a world"
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	sub.add_theme_font_size_override("font_size", 14)
	sub.add_theme_color_override("font_color", DIM)
	_root_box.add_child(sub)

## Три ряда слотов. Пересобираются целиком после любого действия: рядов три, а состояний у них
## два — дешевле построить заново, чем держать ссылки на восемь виджетов и обновлять их по одному.
func _rebuild_slots() -> void:
	for c in _slots_box.get_children():
		c.queue_free()
	for i in G.SLOT_COUNT:
		_slots_box.add_child(_slot_row(i))

func _slot_row(i: int) -> Control:
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", _panel_style())
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	panel.add_child(row)

	var info := VBoxContainer.new()
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	info.add_theme_constant_override("separation", 0)
	row.add_child(info)

	var name_lbl := Label.new()
	name_lbl.text = "SLOT %d" % (i + 1)
	name_lbl.add_theme_font_size_override("font_size", 18)
	name_lbl.add_theme_color_override("font_color", TEXT)
	info.add_child(name_lbl)

	var desc := Label.new()
	desc.add_theme_font_size_override("font_size", 13)
	desc.add_theme_color_override("font_color", DIM)
	var d: Dictionary = G.slot_info(i)
	if d.is_empty():
		# ПЕРВЫЙ СЛОТ ИМЕНОВАН ОТДЕЛЬНО: у него постоянный сид, то есть «наша» карта — та же
		# раскладка жил и точек, что была всегда. Остальные два — новые миры со своим сидом.
		desc.text = "Empty — the original world" if i == 0 else "Empty — a new world"
	else:
		desc.text = "%d$   ·   %d blocks unlocked   ·   %d directives done" \
				% [int(d.get("money", 0)), int(d.get("researched", 0)), int(d.get("quests", 0))]
	info.add_child(desc)

	var used: bool = G.slot_used(i)
	if used:
		row.add_child(_button("PLAY", ACCENT, _on_play.bind(i)))
	# «Новая игра» на занятом слоте — это стирание мира, поэтому она спрашивает. Подтверждение
	# живёт на самой кнопке (второй тап), а не в отдельном окне: окно поверх меню пришлось бы
	# строить, гасить ввод под ним и закрывать — ради одного вопроса, который умещается в надпись.
	var new_label: String = "NEW" if not used else ("ERASE?" if _confirm_slot == i else "NEW")
	row.add_child(_button(new_label, DANGER if _confirm_slot == i else DIM, _on_new.bind(i)))
	return panel

func _add_footer() -> void:
	var sep := Control.new()
	sep.custom_minimum_size = Vector2(0, 6)
	_root_box.add_child(sep)
	# ПРОДОЛЖИТЬ — самая частая кнопка, и она ведёт в последний слот, в котором играли: игрок,
	# у которого мир один, не должен каждый раз выбирать его из трёх.
	var last: int = G.last_slot()
	if G.slot_used(last):
		_root_box.add_child(_button("CONTINUE — SLOT %d" % (last + 1), ACCENT, _on_play.bind(last)))
	if OS.has_feature("pc"):
		_root_box.add_child(_button("QUIT", DIM, func(): get_tree().quit()))
	var ver := Label.new()
	# ОТКУДА ВЕРСИЯ: из project.godot, а не из константы в коде. Второе число в двух местах
	# однажды разъедется, а на экране у беты обязано стоять то же, что в сборке.
	ver.text = "v%s" % str(ProjectSettings.get_setting("application/config/version", "dev"))
	ver.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	ver.add_theme_font_size_override("font_size", 11)
	ver.add_theme_color_override("font_color", DIM * Color(1, 1, 1, 0.7))
	_root_box.add_child(ver)

func _button(text: String, col: Color, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(96, 48)
	b.add_theme_font_size_override("font_size", 15)
	b.add_theme_color_override("font_color", col)
	b.add_theme_color_override("font_hover_color", TEXT)
	b.add_theme_stylebox_override("normal", _btn_style(false))
	b.add_theme_stylebox_override("hover", _btn_style(true))
	b.add_theme_stylebox_override("pressed", _btn_style(true))
	b.pressed.connect(cb)
	return b

func _panel_style() -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = PANEL
	s.set_corner_radius_all(6)
	s.set_content_margin_all(12)
	s.border_color = ACCENT * Color(1, 1, 1, 0.35)
	s.set_border_width_all(1)
	return s

func _btn_style(hot: bool) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = ACCENT * Color(1, 1, 1, 0.28) if hot else Color(0, 0, 0, 0.25)
	s.set_corner_radius_all(4)
	s.set_content_margin_all(8)
	s.border_color = ACCENT * Color(1, 1, 1, 0.5)
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
