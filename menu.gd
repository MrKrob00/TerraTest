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
const NEWS_W := 380.0
## Какую долю высоты экрана занимает лента новостей. Больше — и она закрывает бой.
const NEWS_H_FRAC := 0.42

var _left: VBoxContainer = null          # колонка в левом нижнем углу
var _settings: CenterContainer = null

# ── Создание мира ─────────────────────────────────────────────────────────────
# Землю нового слота считает МЕНЮ, а не первый кадр игры: прогон идёт минуту и дольше, и под
# экраном загрузки он неотличим от зависания. Здесь у него полоса, оценка остатка и СТОП, а
# слот стирается только по «играть» — прервал на середине, старый мир цел.
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
## Открыт ли выбор слота. Первый экран — PLAY / SETTINGS, второй — три мира.
var _slots_open: bool = false

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
## ЧТО НОВОГО — ЛЕНТА ПО ДАТАМ, а не список мелочей. Правило одно: в неё попадает то, что
## МЕНЯЕТ ИГРУ ДЛЯ ИГРОКА, — новая механика, новый противник, новое правило экономики. Мелкая
## правка («переписали фон», «поправили отступ») в ленте не значит ничего: игрок пришёл узнать,
## во что теперь играть, а не что делал разработчик.
##
## Дат несколько, и лента СКРОЛЛИТСЯ: вернувшийся через месяц должен увидеть не последнюю
## строчку, а всё, что пропустил, — по выпускам, сверху вниз.
##
## Живёт список ЗДЕСЬ, а не тянется из сети: игра офлайновая, и запрос, которого некому
## ответить, — это только задержка на старте и экран с ошибкой.
const NEWS := [
	{"date": "06.09.2026", "title": "МИР БЕЗ КРАЯ", "lines": [
		"Земля больше не кончается: она СЧИТАЕТСЯ вокруг машины, а не читается из файла. Едешь в любую сторону — край не найдёшь.",
		"Три слота сохранения. Первый — та самая карта, второй и третий поднимают свой мир из своего сида: свои жилы, свои форты.",
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

func _news_panel() -> Control:
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", _panel_style())
	panel.custom_minimum_size = Vector2(NEWS_W, 0)
	panel.size_flags_horizontal = Control.SIZE_SHRINK_END
	panel.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	var outer := VBoxContainer.new()
	outer.add_theme_constant_override("separation", 4)
	panel.add_child(outer)
	var head := Label.new()
	head.text = "NEWS"
	head.add_theme_font_size_override("font_size", 11)
	head.add_theme_color_override("font_color", ACCENT * Color(1, 1, 1, 0.9))
	outer.add_child(head)

	# Высота — ДОЛЯ ЭКРАНА, а не число: на телефоне лента высотой в полтысячи пикселей закрыла бы
	# полкадра, ради которого задник и сделан.
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.custom_minimum_size = Vector2(NEWS_W,
			get_viewport().get_visible_rect().size.y * NEWS_H_FRAC)
	outer.add_child(scroll)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(box)

	for rel in NEWS:
		var head_row := HBoxContainer.new()
		head_row.add_theme_constant_override("separation", 8)
		var date := Label.new()
		date.text = String(rel["date"])
		date.add_theme_font_size_override("font_size", 11)
		date.add_theme_color_override("font_color", DIM * Color(1, 1, 1, 0.75))
		head_row.add_child(date)
		var title := Label.new()
		title.text = String(rel["title"])
		title.add_theme_font_size_override("font_size", 13)
		title.add_theme_color_override("font_color", ACCENT)
		head_row.add_child(title)
		box.add_child(head_row)
		for line in rel["lines"]:
			var l := Label.new()
			l.text = "· " + String(line)
			l.add_theme_font_size_override("font_size", 12)
			l.add_theme_color_override("font_color", TEXT * Color(1, 1, 1, 0.86))
			l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			box.add_child(l)
	return panel

# ── Левая колонка: два состояния ─────────────────────────────────────────────
## Пересобирается целиком: состояний два, а виджетов в них по три-четыре — дешевле построить
## заново, чем держать ссылки и переключать видимость.
func _rebuild_left() -> void:
	for c in _left.get_children():
		c.queue_free()
	if _gen_slot >= 0:
		_left.add_child(_create_panel())
		return
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

## Панель прогона. Виджеты держим ссылками: их подписи меняются каждый кадр, а пересобирать
## панель по тридцать раз в секунду — это мигающая кнопка под пальцем.
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
		# ДВА выхода, а не один: игрок мог считать мир ЗАРАНЕЕ, чтобы войти в него позже.
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
	# Оценка по всему прогону (elapsed × (1−frac)/frac) и СГЛАЖЕННАЯ: строки внутри прохода
	# неравноценны, голое число прыгало бы каждый кадр.
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

## Прогон. Сид уже выбран, но слот ещё цел — стираем его только в _play_created.
func _begin_create(i: int) -> void:
	if _gen_slot >= 0:
		return                       # прогон уже идёт
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
	# Биомы по умолчанию. На высоты влияют только поля МАСОК (scale/threshold/edge), а карта в
	# node_3d.tscn правит лишь раскраску (snow_line, grass_*) — совпадает. Тронешь маску в сцене
	# карты — здесь появится шов между тем, что посчитало меню, и досчитанной на ходу полосой.
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
		_gen.stop()          # прогон встанет между проходами и вернёт пусто
		return
	_gen_slot = -1
	_rebuild_left()

func _play_created() -> void:
	var i: int = _gen_slot
	_gen_slot = -1
	_play_slot(i)          # мир уже записан в слот прогоном, стирать нечего

func _leave_create() -> void:
	_gen_slot = -1
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

## СТРОКА СЛОТА. Мир и прохождение — РАЗНЫЕ сущности, и кнопки идут ровно по их состояниям:
##   нет мира            → CREATE
##   мир есть, прогресса нет → PLAY + удаление мира
##   есть и то и другое   → PLAY + RESET (сбросить прохождение, карту оставить) + удаление мира
## Первый слот особый: его карта лежит файлом в игре, удалять там нечего.
##
## УДАЛЕНИЕ — УДЕРЖАНИЕМ, а не вторым тапом. Тап рядом с PLAY стирает мир, который считался
## минуту, и «вы уверены?» второй кнопкой ровно так же ловится промахом пальца; удержание
## промахом не делается вовсе и видно, что оно делает, пока полоса ползёт.
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
		# Первый слот — «наша» карта: постоянный сид, та же раскладка жил и точек, что всегда.
		desc.text = "The original world · not started" if i == 0 else "World ready · not started"
	else:
		desc.text = "No world yet"
	info.add_child(desc)

	if not has_world:
		row.add_child(_button("CREATE", ACCENT, _begin_create.bind(i)))
		return row
	# Слот, в котором играли последним, назван CONTINUE: у игрока с одним миром это самое
	# частое действие, и отдельной кнопки под него не нужно.
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

## Кнопка «держи, чтобы сработало». Держит время сама и рисует поверх своего стиля полосу
## заполнения: пока она не дошла до края, ничего не произошло — отпустил, и сброс.
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

## Игровая сцена грузится ТЕМ ЖЕ стойким оверлеем, что и раньше (loading_boot.gd): он живёт
## соседом current_scene, поэтому переживает смену сцены и держится сверху, пока карта не
## построит рельеф. Меню при этом освобождается вместе со сценой — так и задумано.
func _start_game() -> void:
	var overlay := LOADING.new()
	overlay.next_scene = GAME_SCENE
	get_tree().root.add_child.call_deferred(overlay)
