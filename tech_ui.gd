extends Control
# Инвентарь/крафт-UI (гараж), подключён к реальной игре:
#   • INVENTORY — блоки из G.block_inventory; клик по слоту берёт блок В РУКУ
#     (vehicle.take_block_into_hand) → дальше ставишь его на машину обычным Building-флоу.
#   • SHOP      — покупка блоков за G.money (ассортимент = мировой магазин).
#   • СБОРКИ    — сохранение/применение раскладок машины.
#   • Справа    — имя машины, построено/в наличии блоков, масса машины (всё из игры).

enum { TAB_INVENTORY, TAB_SHOP, TAB_BUILDS, TAB_MUSIC, TAB_SETTINGS }

@onready var _grid:   GridContainer = %Grid
@onready var _search: LineEdit      = %Search
@onready var _tab_buttons: Array = [
	%TabInventory, %TabShop, %TabSnapshots, %TabMusic, %TabSettings
]

var _items: Array = []   # [{type:int, name:String, count:int, price:int}]
var _tab: int = TAB_INVENTORY
var _prices: Dictionary = {}              # G.Block -> цена (что продаётся в SHOP)

# ── Фильтры вкладки SHOP (гараж — единственный магазин блоков) ────────────────
var _categories: Dictionary = {}          # ключ → Array типов
var _shop_filter: String = "all"
var _filter_col: VBoxContainer = null     # колонка кнопок слева от сетки (видна в SHOP)
var _filter_buttons: Dictionary = {}
const FILTERS := [
	["all",     "Все"],
	["attack",  "Атака"],
	["blocks",  "Блоки"],
	["factory", "Фабрика"],
	["other",   "Остальные"],
]

func _ready() -> void:
	# ЕДИНСТВЕННЫЙ магазин блоков в игре (мировой магазин продаёт только ресурсы
	# через чёрную дыру и своего меню не имеет).
	_prices = {
		G.Block.BLOCK: 5,
		G.Block.WHEEL: 10,
		G.Block.CABIN: 25,
		G.Block.DRILL: 20,
		G.Block.GUN: 35,
		G.Block.LASER: 40,
		G.Block.COLLECTOR: 15,
		G.Block.INTAKE: 15,
		G.Block.BELT: 10,
		G.Block.PROCESSOR: 30,
		G.Block.SELLER: 30,
		G.Block.GENERATOR: 40,
		G.Block.BATTERY: 30,
		G.Block.SOLAR: 35,
		G.Block.REGEN: 45,
		G.Block.SHIELD: 50,
	}
	_categories = {
		"attack":  [G.Block.GUN, G.Block.LASER, G.Block.DRILL],
		"blocks":  [G.Block.BLOCK, G.Block.CABIN, G.Block.WHEEL],
		"factory": [G.Block.COLLECTOR, G.Block.INTAKE, G.Block.BELT, G.Block.PROCESSOR, G.Block.SELLER, G.Block.GENERATOR],
		# BATTERY/SOLAR/REGEN/SHIELD не в явных категориях -> попадают в «Остальные»
	}
	_build_filter_column()
	_build_extra_panel()
	if _search:
		_search.text_changed.connect(func(t: String) -> void: _rebuild_grid(t))
	if has_node("%Close"):
		%Close.pressed.connect(hide)
	for i in _tab_buttons.size():
		if _tab_buttons[i]:
			_tab_buttons[i].pressed.connect(_select_tab.bind(i))
	visibility_changed.connect(_on_visibility_changed)
	_select_tab(TAB_INVENTORY)
	_refresh_stats()
	_update_currency()

# Колонка фильтров слева от сетки. Видна только на вкладке SHOP.
func _build_filter_column() -> void:
	var body: Node = get_node_or_null("Root/Main/LeftPanel/LeftVB/Body")
	if body == null:
		return
	_filter_col = VBoxContainer.new()
	_filter_col.add_theme_constant_override("separation", 6)
	_filter_col.visible = false
	body.add_child(_filter_col)
	body.move_child(_filter_col, 0)
	for f in FILTERS:
		var fb := Button.new()
		fb.text = f[1]
		fb.toggle_mode = true
		fb.button_pressed = (f[0] == _shop_filter)
		fb.custom_minimum_size = Vector2(104, 40)
		fb.pressed.connect(_set_shop_filter.bind(f[0]))
		_filter_col.add_child(fb)
		_filter_buttons[f[0]] = fb

func _set_shop_filter(key: String) -> void:
	_shop_filter = key
	for k in _filter_buttons:
		_filter_buttons[k].button_pressed = (k == key)
	_load_items()
	_rebuild_grid(_search.text if _search else "")

# Проходит ли блок текущий фильтр SHOP. "other" = не попал ни в одну категорию.
func _passes_filter(block_type: int) -> bool:
	match _shop_filter:
		"all":
			return true
		"other":
			for k in _categories:
				if _categories[k].has(block_type):
					return false
			return true
		_:
			return _categories.get(_shop_filter, []).has(block_type)

func _on_visibility_changed() -> void:
	if visible:
		refresh()

# Полное обновление: инвентарь/магазин в сетке + характеристики справа + деньги.
func refresh() -> void:
	_load_items()
	_rebuild_grid(_search.text if _search else "")
	_refresh_stats()
	_update_currency()

# ── Наполнение сетки в зависимости от вкладки ─────────────────────────────────
func _load_items() -> void:
	_items.clear()
	if _tab == TAB_SHOP:
		for block_type in _prices:
			if not _passes_filter(int(block_type)):
				continue
			_items.append({
				"type": int(block_type),
				"name": _block_name(int(block_type)),
				"count": 0,
				"price": int(_prices[block_type]),
			})
		return
	# INVENTORY — реальные блоки игрока, сгруппированные по типу.
	var counts: Dictionary = {}
	for b in G.block_inventory:
		counts[b] = counts.get(b, 0) + 1
	for block_type in counts:
		_items.append({
			"type": int(block_type),
			"name": _block_name(int(block_type)),
			"count": int(counts[block_type]),
			"price": 0,
		})

func _block_name(block_type: int) -> String:
	var names: Array = G.Block.keys()
	if block_type >= 0 and block_type < names.size():
		return str(names[block_type]).capitalize()
	return "Block %d" % block_type

func _rebuild_grid(filter: String) -> void:
	if _grid == null:
		return
	if _tab == TAB_BUILDS:
		_build_builds_tab()
		return
	for c in _grid.get_children():
		c.queue_free()
	var f := filter.strip_edges().to_lower()
	var shown := 0
	for it in _items:
		if f != "" and not str(it["name"]).to_lower().contains(f):
			continue
		_grid.add_child(_make_slot(it))
		shown += 1
	if shown == 0:
		var empty := Label.new()
		empty.modulate = Color(1, 1, 1, 0.5)
		if not _items.is_empty():
			empty.text = "Ничего не найдено"
		elif _tab == TAB_SHOP:
			empty.text = "Магазин пуст"
		else:
			empty.text = "Инвентарь пуст"
		_grid.add_child(empty)

func _make_slot(it: Dictionary) -> Control:
	# Слот = кнопка с названием блока. INVENTORY: в углу ×count, клик → блок в руку.
	# SHOP: в углу цена, клик → купить (выключена, если не хватает денег).
	var btn := Button.new()
	btn.custom_minimum_size = Vector2(96, 96)
	btn.clip_text = true
	btn.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	btn.text = str(it["name"])
	btn.add_theme_font_size_override("font_size", 13)
	var corner := Label.new()
	corner.add_theme_font_size_override("font_size", 14)
	corner.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT)
	corner.offset_left = -44
	corner.offset_top = -24
	corner.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var block_type: int = int(it["type"])
	if _tab == TAB_SHOP:
		var price: int = int(it["price"])
		corner.text = "%d$" % price
		btn.disabled = G.money < price
		btn.pressed.connect(_buy.bind(block_type, price))
	else:
		corner.text = "×%d" % int(it["count"])
		btn.pressed.connect(_take_into_hand.bind(block_type))
	btn.add_child(corner)
	return btn

# ── Вкладка СБОРКИ (сохранённые машины) ───────────────────────────────────────
func _build_builds_tab() -> void:
	for c in _grid.get_children():
		c.queue_free()
	_grid.add_child(_make_action_slot("＋ Сохранить\nтекущую", _save_current_build))
	for build_name in G.saved_builds:
		_grid.add_child(_make_build_slot(str(build_name)))

func _make_action_slot(label: String, cb: Callable) -> Control:
	var btn := Button.new()
	btn.custom_minimum_size = Vector2(96, 96)
	btn.clip_text = true
	btn.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	btn.text = label
	btn.add_theme_font_size_override("font_size", 13)
	btn.pressed.connect(cb)
	return btn

func _make_build_slot(build_name: String) -> Control:
	var layout: Array = G.saved_builds.get(build_name, [])
	var btn := _make_action_slot(build_name, _load_build.bind(build_name)) as Button
	var corner := Label.new()
	corner.text = "%d бл." % layout.size()
	corner.add_theme_font_size_override("font_size", 12)
	corner.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT)
	corner.offset_left = -52
	corner.offset_top = -22
	corner.mouse_filter = Control.MOUSE_FILTER_IGNORE
	btn.add_child(corner)
	return btn

func _save_current_build() -> void:
	var v: Node = _get_vehicle()
	if v == null or not v.has_method("capture_build"):
		return
	var layout: Array = v.capture_build()
	if layout.is_empty():
		return
	var bname: String = "Сборка %d" % (G.saved_builds.size() + 1)
	G.save_build(bname, layout)
	_rebuild_grid("")
	_say("Сборка сохранена: %s" % bname)

# Применить сохранённую сборку с ПРОВЕРКОЙ блоков: пул = блоки на машине + инвентарь.
func _load_build(build_name: String) -> void:
	var v: Node = _get_vehicle()
	if v == null or not v.has_method("apply_build"):
		return
	var blocks_node: Node = v.get_node_or_null("blocks")
	if blocks_node == null:
		return
	var target: Array = G.saved_builds.get(build_name, [])
	if target.is_empty():
		return
	var current: Array = blocks_node.get_layout() if blocks_node.has_method("get_layout") else []
	var pool: Dictionary = G.layout_counts(current)
	for b in G.block_inventory:
		var t := int(b)
		pool[t] = pool.get(t, 0) + 1
	var need: Dictionary = G.layout_counts(target)
	# Чего не хватает?
	var missing: Dictionary = {}
	for t in need:
		var short: int = int(need[t]) - int(pool.get(t, 0))
		if short > 0:
			missing[t] = short
	if not missing.is_empty():
		_say("Не хватает: " + _missing_text(missing))
		return
	# Применяем: новый инвентарь = пул − потрачено на сборку.
	for t in need:
		pool[t] = int(pool.get(t, 0)) - int(need[t])
	var new_inv: Array = []
	for t in pool:
		for _i in int(pool[t]):
			new_inv.append(int(t))
	G.block_inventory = new_inv
	v.apply_build(target)
	_say("Сборка применена: %s" % build_name)
	refresh()

func _missing_text(missing: Dictionary) -> String:
	var parts: Array = []
	for t in missing:
		parts.append("%s ×%d" % [_block_name(int(t)), int(missing[t])])
	return ", ".join(parts)

func _say(text: String) -> void:
	var d = get_node_or_null("/root/Dialogue")
	if d:
		d.say("Гараж", text)

# ── Действия ──────────────────────────────────────────────────────────────────
func _take_into_hand(block_type: int) -> void:
	if not G.block_inventory.has(block_type):
		return
	var v: Node = _get_vehicle()
	if v == null or not v.has_method("take_block_into_hand"):
		push_warning("tech_ui: не нашёл активную машину для выдачи блока в руку")
		return
	if not v.take_block_into_hand(block_type):
		return                                  # в руке уже что-то есть
	G.block_inventory.erase(block_type)         # списываем один экземпляр
	visible = false                             # прячем UI — пора ставить блок на машину

func _buy(block_type: int, price: int) -> void:
	if G.money < price:
		return
	G.money -= price
	G.block_inventory.append(block_type)
	# Магазин остаётся открытым: обновляем цены/доступность кнопок и счётчик денег.
	_rebuild_grid(_search.text if _search else "")
	_update_currency()
	_refresh_stats()

# ── Вкладки ───────────────────────────────────────────────────────────────────
func _select_tab(idx: int) -> void:
	_tab = idx
	for i in _tab_buttons.size():
		if _tab_buttons[i]:
			_tab_buttons[i].button_pressed = (i == idx)
	if _filter_col:
		_filter_col.visible = (_tab == TAB_SHOP)
	# МУЗЫКА/НАСТРОЙКИ живут в спец-панели вместо сетки блоков (и без поиска).
	var extra: bool = _tab == TAB_MUSIC or _tab == TAB_SETTINGS
	var grid_scroll: Node = get_node_or_null("Root/Main/LeftPanel/LeftVB/Body/Scroll")
	if grid_scroll:
		grid_scroll.visible = not extra
	if _extra_scroll:
		_extra_scroll.visible = extra
	if _search:
		_search.visible = not extra
	if extra:
		if _tab == TAB_MUSIC:
			_build_music_tab()
		else:
			_build_settings_tab()
		return
	_load_items()
	_rebuild_grid(_search.text if _search else "")

# ── Поиск активной машины ─────────────────────────────────────────────────────
func _get_vehicle() -> Node:
	var cc: Node = get_tree().get_first_node_in_group("camera_controller")
	if cc == null:
		cc = get_node_or_null("/root/Main/Vehicles/Camera Controller")
	if cc and "current_vehicle" in cc:
		return cc.current_vehicle
	return null

# ── Характеристики справа + деньги (реальные данные) ──────────────────────────
func _update_currency() -> void:
	if has_node("%Currency"):
		%Currency.text = str(G.money)

func _refresh_stats() -> void:
	var v: Node = _get_vehicle()
	if v == null:
		return
	set_vehicle_name(str(v.name))
	# «Реактор» переосмыслен как блоки: построено на машине / всего во владении.
	var built := 0
	var blocks_node: Node = v.get_node_or_null("blocks")
	if blocks_node:
		for b in blocks_node.get_children():
			if "block" in b:                    # блоки имеют свойство .block; меш-узел — нет
				built += 1
	var owned: int = built + G.block_inventory.size()
	set_reactor(built, max(owned, 1))
	if "mass" in v:
		set_weight(int(round(v.mass)))

# ── Публичный API характеристик справа ────────────────────────────────────────
func set_vehicle_name(n: String) -> void:
	if has_node("%VehicleName"):
		%VehicleName.text = n

func set_reactor(used: int, total: int) -> void:
	if has_node("%ReactorValue"):
		%ReactorValue.text = "%d / %d" % [used, total]
	if has_node("%ReactorBar"):
		%ReactorBar.max_value = total
		%ReactorBar.value = used

func set_weight(kg: int) -> void:
	if has_node("%WeightValue"):
		%WeightValue.text = "%d kg" % kg

# ── Спец-панель для вкладок МУЗЫКА и НАСТРОЙКИ (вместо сетки блоков) ───────────
var _extra_scroll: ScrollContainer = null
var _extra_vb: VBoxContainer = null

func _build_extra_panel() -> void:
	var body: Node = get_node_or_null("Root/Main/LeftPanel/LeftVB/Body")
	if body == null:
		return
	_extra_scroll = ScrollContainer.new()
	_extra_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_extra_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_extra_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_extra_scroll.visible = false
	body.add_child(_extra_scroll)
	_extra_vb = VBoxContainer.new()
	_extra_vb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_extra_vb.add_theme_constant_override("separation", 6)
	_extra_scroll.add_child(_extra_vb)
	# Обновление вкладки МУЗЫКА при смене трека/предпочтений.
	var m := _music()
	if m:
		m.prefs_changed.connect(func() -> void:
			if visible and _tab == TAB_MUSIC: _build_music_tab())
		m.track_changed.connect(func(_t: String, _a: String) -> void:
			if visible and _tab == TAB_MUSIC: _build_music_tab())

func _music() -> Node:
	return get_node_or_null("/root/Music")

func _clear_extra() -> void:
	for c in _extra_vb.get_children():
		c.queue_free()

func _extra_header(text: String) -> void:
	var lbl := Label.new()
	lbl.text = text
	lbl.add_theme_font_size_override("font_size", 14)
	lbl.add_theme_color_override("font_color", Color(0.55, 0.75, 0.8, 0.9))
	_extra_vb.add_child(lbl)

# ── Вкладка МУЗЫКА ─────────────────────────────────────────────────────────────
func _build_music_tab() -> void:
	if _extra_vb == null:
		return
	_clear_extra()
	var m := _music()
	if m == null:
		_extra_header("Музыкальная система не подключена")
		return
	var cur: Dictionary = m.current_track()
	# Сейчас играет + пропуск
	var now_row := HBoxContainer.new()
	_extra_vb.add_child(now_row)
	var now := Label.new()
	now.text = ("▶ %s — %s  [%s]" % [cur.get("title", ""), cur.get("author", ""), m.context_name()]) \
			if not cur.is_empty() else "Тишина (нет треков или всё выключено)"
	now.add_theme_font_size_override("font_size", 13)
	now.add_theme_color_override("font_color", Color(0.75, 0.95, 0.8))
	now.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	now.clip_text = true
	now_row.add_child(now)
	var skip := Button.new()
	skip.text = "⏭"
	skip.tooltip_text = "Следующий трек"
	skip.custom_minimum_size = Vector2(44, 38)
	skip.pressed.connect(func() -> void:
		var mm := _music()
		if mm: mm.skip())
	now_row.add_child(skip)
	# Громкость
	var vol_row := HBoxContainer.new()
	_extra_vb.add_child(vol_row)
	var vol_lbl := Label.new()
	vol_lbl.text = "Громкость"
	vol_lbl.add_theme_font_size_override("font_size", 13)
	vol_row.add_child(vol_lbl)
	var vol := HSlider.new()
	vol.min_value = 0.0
	vol.max_value = 1.0
	vol.step = 0.05
	vol.value = m.volume
	vol.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vol.value_changed.connect(func(v: float) -> void:
		var mm := _music()
		if mm: mm.set_volume(v))
	vol_row.add_child(vol)
	# Два списка: путешествия (играют и в гараже) и отдельно сражения. Без «меню» —
	# тот тип зарезервирован под будущее главное меню игры.
	var sections := [["Путешествия", m.Ctx.TRAVEL], ["Сражения", m.Ctx.BATTLE]]
	for s in sections:
		_extra_header(str(s[0]))
		var list: Array = m.tracks.get(s[1], [])
		if list.is_empty():
			var empty := Label.new()
			empty.text = "   (треков нет — кинь .ogg в music/)"
			empty.add_theme_font_size_override("font_size", 12)
			empty.modulate = Color(1, 1, 1, 0.45)
			_extra_vb.add_child(empty)
			continue
		for tr in list:
			_extra_vb.add_child(_music_row(m, tr, cur))

# ── Иконки строк музыки: рисуются кодом (юникод-глифы ♥/✖ не рендерились шрифтом) ──
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
		# «Не любимое» — всегда красный: тусклый в покое, яркий когда включён.
		var col := Color(1.0, 0.25, 0.2) if active else Color(0.62, 0.2, 0.18)
		var a := 7.0
		draw_line(c + Vector2(-a, -a), c + Vector2(a, a), col, 3.5)
		draw_line(c + Vector2(-a, a), c + Vector2(a, -a), col, 3.5)

# Строка трека: слева НАЗВАНИЕ (сверху) и под ним автор (мелко, серым), справа кнопки
# ♥ (любимое — играет чаще) и ✖ (не играть). ▶ у играющего.
func _music_row(m: Node, t: Dictionary, cur: Dictionary) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	var file: String = t["file"]
	var playing: bool = cur.get("file", "") == file

	var info := VBoxContainer.new()
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	info.add_theme_constant_override("separation", 0)
	row.add_child(info)
	var title := Label.new()
	title.text = ("▶ " if playing else "") + str(t["title"])
	title.add_theme_font_size_override("font_size", 15)
	title.clip_text = true
	if m.banned.has(file):
		title.modulate = Color(1, 1, 1, 0.4)
	elif playing:
		title.add_theme_color_override("font_color", Color(0.6, 1.0, 0.7))
	info.add_child(title)
	var author := Label.new()
	author.text = str(t["author"])
	author.add_theme_font_size_override("font_size", 12)
	author.add_theme_color_override("font_color", Color(0.55, 0.58, 0.62))
	author.clip_text = true
	if m.banned.has(file):
		author.modulate = Color(1, 1, 1, 0.4)
	info.add_child(author)

	row.add_child(_music_icon_btn(HeartIcon.new(), m.fav.has(file), "Любимый: играет чаще",
			func(on: bool) -> void: m.set_favorite(file, on)))
	row.add_child(_music_icon_btn(BanIcon.new(), m.banned.has(file), "Не играть никогда",
			func(on: bool) -> void: m.set_banned(file, on)))
	return row

func _music_icon_btn(icon: Control, active: bool, tip: String, on_toggle: Callable) -> Button:
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

# ── Вкладка НАСТРОЙКИ ──────────────────────────────────────────────────────────
# Авто-FPS (система в Main.gd: держит целевой FPS, меняя масштаб рендера). Авто
# выключено → полоска ручного выбора масштаба.
func _build_settings_tab() -> void:
	if _extra_vb == null:
		return
	_clear_extra()
	var main: Node = get_node_or_null("/root/Main")
	_extra_header("— ГРАФИКА —")
	if main == null or not ("auto_fps" in main):
		_extra_header("Main с авто-FPS не найден")
		return
	var auto_btn := CheckButton.new()
	auto_btn.text = "Авто FPS (масштаб рендера подстраивается сам)"
	auto_btn.button_pressed = bool(main.auto_fps)
	auto_btn.add_theme_font_size_override("font_size", 14)
	_extra_vb.add_child(auto_btn)

	var scale_row := HBoxContainer.new()
	scale_row.visible = not bool(main.auto_fps)
	_extra_vb.add_child(scale_row)
	var scale_lbl := Label.new()
	scale_lbl.text = "Масштаб: %d%%" % int(round(float(main.manual_scale) * 100.0))
	scale_lbl.custom_minimum_size = Vector2(130, 0)
	scale_lbl.add_theme_font_size_override("font_size", 13)
	scale_row.add_child(scale_lbl)
	var scale_sl := HSlider.new()
	scale_sl.min_value = 0.5
	scale_sl.max_value = 1.0
	scale_sl.step = 0.05
	scale_sl.value = float(main.manual_scale)
	scale_sl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scale_sl.value_changed.connect(func(v: float) -> void:
		scale_lbl.text = "Масштаб: %d%%" % int(round(v * 100.0))
		var mn: Node = get_node_or_null("/root/Main")
		if mn and mn.has_method("set_manual_scale"):
			mn.set_manual_scale(v))
	scale_row.add_child(scale_sl)

	auto_btn.toggled.connect(func(on: bool) -> void:
		var mn: Node = get_node_or_null("/root/Main")
		if mn and mn.has_method("set_auto_fps"):
			mn.set_auto_fps(on)
		scale_row.visible = not on)

	var hint := Label.new()
	hint.text = "Ниже масштаб = выше FPS, мягче картинка. Авто держит ~55 FPS."
	hint.add_theme_font_size_override("font_size", 12)
	hint.modulate = Color(1, 1, 1, 0.55)
	_extra_vb.add_child(hint)
