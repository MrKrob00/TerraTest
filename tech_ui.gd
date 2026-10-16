extends Control
# Инвентарь/крафт-UI (гараж), подключён к реальной игре:
#   • INVENTORY — блоки из G.block_inventory; клик по слоту берёт блок В РУКУ
#     (vehicle.take_block_into_hand) → дальше ставишь его на машину обычным Building-флоу.
#   • SHOP      — покупка блоков за G.money (ассортимент = мировой магазин).
#   • СБОРКИ    — сохранение/применение раскладок машины.
#   • Справа    — имя машины, нагруженность (тянет/не тянет) и характеристики.
#                 Все значения живые: строки собираются кодом из MachineBody, а не
#                 лежат в сцене, где часть чисел осталась картинкой со скриншота.

enum { TAB_INVENTORY, TAB_SHOP, TAB_BUILDS, TAB_MUSIC, TAB_SETTINGS, TAB_TECH, TAB_BUILD, TAB_CODEX }

@onready var _grid:   HFlowContainer = %Grid
@onready var _search: LineEdit      = %Search
# ВАЖНО: индекс в массиве = значение enum (bind в _ready) — TabTech последним.
@onready var _tab_buttons: Array = [
	%TabInventory, %TabShop, %TabSnapshots, %TabMusic, %TabSettings, %TabTech, %TabBuild, %TabCodex
]

var _items: Array = []   # [{type:int, name:String, count:int, price:int}]
var _tab: int = TAB_INVENTORY
var _prices: Dictionary = {}              # G.Block -> цена (что продаётся в SHOP)

# ── Фильтры вкладки SHOP (гараж — единственный магазин блоков) ────────────────
var _categories: Dictionary = {}          # ключ → Array типов
var _shop_filter: String = "all"
## Цвет ценника на распродаже. Тёплый, а не зелёный: зелёный в этой игре занят ремонтом и
## «хватает денег», и скидка в нём читалась бы как «можно купить», а не как «стало дешевле».
const SALE_COL := Color(1.0, 0.82, 0.22)
## THE SHOP'S DAY ON SCREEN (the player's call): a strip over the list with the time to the next
## restock (`G.shop_sale_seconds_left`), a bar that empties over the day and today's counts, and the
## list in three sections - on sale, today only (a stock-limited block, with how many are left), always
## in stock. The window IS the shop's rule, and a flat list hid which blocks would be gone tomorrow.
const STOCK_COL := Color(0.55, 0.85, 0.9)
## THE SHOP'S LOOK IS THE BLOCKS' LOOK (docs/ART_STYLE.md): dark violet-grey metal, shape read by a
## lighter EDGE LINE on top and a darker one under it, corners CUT (corner_detail 1 turns a radius
## into a chamfer), never rounded pills, no glow, no shadow. Colour is an accent, not a fill: the
## faction's stripe down a row's left edge, the warm sale stripe over it, a chip for the stock count.
const METAL := Color(0.094, 0.094, 0.114, 0.97)
const METAL_HI := Color(0.125, 0.125, 0.15, 0.98)
const METAL_LO := Color(0.06, 0.06, 0.074, 0.97)
const EDGE_HI := Color(0.24, 0.24, 0.29)
const EDGE_LO := Color(0.03, 0.03, 0.04)
const CHAMFER := 5
## A row's stripe by the block's faction; "start" is the GSO blue of the models.
const FACTION_COL := {
	"start": Color(0.43, 0.6, 0.85),
	"marlit": Color(0.3, 0.74, 0.7),
	"aero": Color(0.95, 0.6, 0.25),
	"stryx": Color(0.55, 0.8, 0.4),
}
var _row_styles: Dictionary = {}          # faction key -> {normal, hover, pressed, disabled}
const POOR_COL := Color(0.95, 0.5, 0.45)
const HEAD_H := 28.0
enum { SHOP_SALE, SHOP_TODAY, SHOP_ALWAYS }
var _shop_head: PanelContainer = null
var _shop_cap: Label = null
var _shop_time: Label = null
var _shop_bar: DayBar = null
var _shop_info: Label = null
var _shop_sec: int = -1
var _heads: Array = []                    # section rows in the grid, pooled like the slots
var _last_slot_side: float = 0.0        # чтобы пересобирать сетку только при реальной смене ширины
var _filter_col: VBoxContainer = null     # колонка кнопок слева от сетки (видна в SHOP)
var _filter_buttons: Dictionary = {}
const FILTERS := [
	["all",     "All"],
	["blocks",  "Blocks"],
	["wheels",  "Wheels"],
	["attack",  "Attack"],
	["factory", "Factory"],
	["power",   "Power"],
]

func _ready() -> void:
	# ЕДИНСТВЕННЫЙ магазин блоков в игре (мировой магазин продаёт только ресурсы
	# через чёрную дыру и своего меню не имеет).
	#
	# Цены НЕ задаются здесь. Раньше тут лежал список руками (BLOCK 5$, GUN 35$…), и он ни
	# с чем не сверялся: блок из материалов на три сотни продавался за пятёрку, поэтому
	# добывать, плавить и собирать было чистым проигрышем — выгоднее продать сырьё и купить
	# готовое. Теперь цена считается из рецепта (G.shop_price) и всегда ВЫШЕ стоимости
	# материалов, так что магазин — это удобство, а не способ обойти производство.
	# Ассортимент прежний: всё, что есть в дереве технологий.
	# Печь иконок может закончить, пока гараж уже открыт: тогда плитки перерисовываются с
	# картинками. Без этого первая сессия после установки показала бы магазин без иконок,
	# хотя файлы к тому моменту уже лежат.
	if not Icons.baked.is_connected(_on_icons_baked):
		Icons.baked.connect(_on_icons_baked)
	if not Icons.build_baked.is_connected(_on_build_baked):
		Icons.build_baked.connect(_on_build_baked)
	_prices = {}
	for _bt in G.BLOCK_META:
		_prices[_bt] = G.shop_price(int(_bt))
	# Категории — общие с глобусом стройки (G.BLOCK_CATEGORIES), чтобы не расходились.
	_categories = G.BLOCK_CATEGORIES
	_build_filter_column()
	_build_shop_head()
	_build_stats_panel()
	_build_shop_v2()
	_build_extra_panel()
	# Ширина сетки может измениться (поворот экрана, ресайз окна, ползунок размера UI) — тогда
	# пересобираем слоты, чтобы в ряду ОСТАЛОСЬ ровно COLS. Гейт по изменению размера слота,
	# иначе перестройка сама меняла бы размер сетки и зациклилась.
	if _grid:
		_grid.resized.connect(_on_grid_resized)
	if _search:
		_search.text_changed.connect(func(t: String) -> void: _rebuild_grid(t))
	if has_node("%Close"):
		%Close.pressed.connect(hide)
	for i in _tab_buttons.size():
		if _tab_buttons[i]:
			_tab_buttons[i].pressed.connect(_select_tab.bind(i))
	visibility_changed.connect(_on_visibility_changed)
	# Прогресс лицензии в шапке (перед деньгами): «Гр.N · XP x/y · ДИ z». Живёт в том же
	# HBox TopRow, обновляется по G.progress_changed (XP/ДИ/исследования).
	if has_node("%Currency"):
		var row: Node = (%Currency as Node).get_parent()
		_prog_label = Label.new()
		_prog_label.add_theme_font_size_override("font_size", 14)
		_prog_label.add_theme_color_override("font_color", Color(0.65, 0.85, 0.9))
		row.add_child(_prog_label)
		row.move_child(_prog_label, (%Currency as Node).get_index())
	G.progress_changed.connect(_on_progress_changed)   # XP/ДИ: замки могли открыться
	G.money_changed.connect(_on_money_changed)         # пассивный доход при открытом гараже
	# Витрина обязана обновиться в тот же миг, когда сменилась распродажа: гараж бывает открыт
	# как раз в эту минуту, и цена под пальцем не имеет права разойтись с той, что спишут.
	G.shop_sales_changed.connect(_on_money_changed)
	# Закрыть гараж можно и ЖЕСТОМ — протянуть от нижней кромки экрана вверх по центру.
	# Крестик остаётся, но он в дальнем углу, а гараж закрывают чаще всего сразу после
	# того, как что-то взяли, — то есть пальцем, который и так внизу экрана.
	SwipeClose.attach(self, hide, func(): return visible)
	_select_tab(TAB_INVENTORY)
	_refresh_stats()
	_update_currency()
	_fit_tab_row()
	get_viewport().size_changed.connect(_fit_tab_row)

## ПЕРЕВОД ДЛИННЕЕ ОРИГИНАЛА, И РЯД ВКЛАДОК ЭТО ПЕРВЫМ И ЗАМЕЧАЕТ. «INVENTORY / SETTINGS» это
## 9 и 8 букв, «ИНВЕНТАРЬ / НАСТРОЙКИ» — те же 9, а «CODEX» против «СПРАВОЧНИКА» вдвое короче.
## HBoxContainer ничего не ужимает: не влезло — уехало за экран вместе с крестиком.
##
## Поэтому шрифт ряда подбираем ПО ФАКТУ, а не подгоняем строки перевода под английскую длину:
## строка должна читаться на своём языке, а влезать — забота раскладки. Считаем по минимальным
## размерам самих кнопок, то есть по тому, что реально нарисует шрифт.
const TAB_FONT_MAX := 14
const TAB_FONT_MIN := 9

func _fit_tab_row() -> void:
	var row: Control = get_node_or_null("Root/TopBar/TopRow") as Control
	if row == null:
		return
	var avail: float = get_viewport_rect().size.x - 24.0
	if avail <= 1.0:
		return
	for fs in range(TAB_FONT_MAX, TAB_FONT_MIN - 1, -1):
		for b in _tab_buttons:
			if b != null:
				(b as Control).add_theme_font_size_override("font_size", fs)
		# Ширину спрашиваем у самого ряда: он складывает минимумы детей и разделители, то есть
		# знает и про «ГАРАЖ», и про деньги, и про крестик, а не только про вкладки.
		if row.get_combined_minimum_size().x <= avail or fs == TAB_FONT_MIN:
			return

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
		fb.text = tr(String(f[1]))
		fb.toggle_mode = true
		fb.button_pressed = (f[0] == _shop_filter)
		fb.custom_minimum_size = Vector2(104, 48)
		_style_filter_button(fb)
		fb.pressed.connect(_set_shop_filter.bind(f[0]))
		_filter_col.add_child(fb)
		_filter_buttons[f[0]] = fb
	# Кнопки СПРАВОЧНИКА живут в той же колонке и просто скрыты: колонка одна, а её ширина
	# и отступы заданы в сцене — вторая такая же рядом означала бы вторую раскладку.
	_codex_col = VBoxContainer.new()
	_codex_col.add_theme_constant_override("separation", 6)
	_codex_col.visible = false
	body.add_child(_codex_col)
	body.move_child(_codex_col, 1)
	for k in CODEX_KINDS:
		var cb := Button.new()
		cb.text = tr(String(k[1]))
		cb.toggle_mode = true
		cb.button_pressed = (k[0] == _codex_kind)
		cb.custom_minimum_size = Vector2(104, 40)
		cb.pressed.connect(_set_codex_kind.bind(k[0]))
		_codex_col.add_child(cb)
		_codex_buttons[k[0]] = cb

## A filter tab: a cut-cornered metal plate; the chosen one is lighter with the GSO blue on its left
## edge, like a selected row. 48 points tall - a finger, not a cursor.
func _style_filter_button(b: Button) -> void:
	var accent: Color = FACTION_COL["start"]
	b.add_theme_stylebox_override("normal", _plate(METAL, EDGE_HI, Color(0, 0, 0, 0), 0))
	b.add_theme_stylebox_override("hover", _plate(METAL_HI, EDGE_HI, Color(0, 0, 0, 0), 0))
	b.add_theme_stylebox_override("pressed", _plate(METAL_HI, EDGE_HI, accent, 4))
	b.add_theme_stylebox_override("hover_pressed", _plate(METAL_HI, EDGE_HI, accent, 4))
	b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	b.add_theme_color_override("font_color", Color(0.62, 0.64, 0.72))
	b.add_theme_color_override("font_hover_color", Color(0.85, 0.86, 0.9))
	b.add_theme_color_override("font_pressed_color", Color(0.95, 0.96, 1.0))
	b.add_theme_color_override("font_hover_pressed_color", Color(0.95, 0.96, 1.0))
	b.add_theme_font_size_override("font_size", 14)
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT

## One plate of the shop: metal fill, lighter edge line on top, darker under, a cut corner, and an
## optional stripe of `stripe_w` down the left.
func _plate(bg: Color, hi: Color, stripe: Color, stripe_w: int) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.border_width_top = 1
	sb.border_width_bottom = 1
	sb.border_width_left = stripe_w
	sb.border_color = hi
	if stripe_w > 0:
		sb.border_color = stripe
	sb.set_corner_radius_all(CHAMFER)
	sb.corner_radius_top_left = 0
	sb.corner_radius_bottom_left = 0
	sb.corner_detail = 1
	sb.anti_aliasing = false
	sb.content_margin_left = 12.0 + stripe_w
	sb.content_margin_right = 8.0
	return sb

## The four states of a shop row in its faction's colour, built once per faction.
func _row_style(f: String) -> Dictionary:
	if _row_styles.has(f):
		return _row_styles[f]
	var col: Color = FACTION_COL.get(f, FACTION_COL["start"])
	var d := {
		"normal": _plate(METAL, EDGE_HI, col, 4),
		"hover": _plate(METAL_HI, EDGE_HI, col.lightened(0.2), 4),
		"pressed": _plate(METAL_LO, EDGE_HI, col.lightened(0.35), 4),
		"disabled": _plate(METAL_LO, EDGE_HI, Color(col.r, col.g, col.b, 0.35), 4),
	}
	_row_styles[f] = d
	return d

func _chip(col: Color) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(col.r, col.g, col.b, 0.16)
	sb.border_color = Color(col.r, col.g, col.b, 0.75)
	sb.set_border_width_all(1)
	sb.anti_aliasing = false
	sb.content_margin_left = 5.0
	sb.content_margin_right = 5.0
	return sb

## The strip over the shop's list: "Restock in 12:34", the day's bar, today's counts. Shown on the
## SHOP tab only (`_update_shop_head`); built once, like the filter column.
func _build_shop_head() -> void:
	var vb: Node = get_node_or_null("Root/Main/LeftPanel/LeftVB")
	if vb == null:
		return
	_shop_head = PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = METAL_LO
	sb.border_color = EDGE_HI
	sb.border_width_top = 1
	sb.border_width_bottom = 2
	sb.border_width_left = 4
	sb.set_corner_radius_all(CHAMFER)
	sb.corner_detail = 1
	sb.anti_aliasing = false
	sb.content_margin_left = 12.0
	sb.content_margin_right = 12.0
	sb.content_margin_top = 7.0
	sb.content_margin_bottom = 8.0
	_shop_head.add_theme_stylebox_override("panel", sb)
	_shop_head.tooltip_text = tr("The shop restocks once a game day. Blocks researched today join at the next restock.")
	_shop_head.visible = false
	vb.add_child(_shop_head)
	vb.move_child(_shop_head, 0)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 4)
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_shop_head.add_child(col)
	var row := HBoxContainer.new()
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(row)
	_shop_cap = Label.new()
	_shop_cap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_shop_cap.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_shop_cap.add_theme_font_size_override("font_size", 12)
	_shop_cap.add_theme_color_override("font_color", Color(0.62, 0.64, 0.72))
	_shop_cap.uppercase = true
	_shop_cap.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_shop_cap.clip_text = true
	row.add_child(_shop_cap)
	_shop_time = Label.new()
	_shop_time.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_shop_time.add_theme_font_size_override("font_size", 28)
	row.add_child(_shop_time)
	_shop_bar = DayBar.new()
	_shop_bar.custom_minimum_size = Vector2(0.0, 8.0)
	_shop_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(_shop_bar)
	_shop_info = Label.new()
	_shop_info.add_theme_font_size_override("font_size", 12)
	_shop_info.add_theme_color_override("font_color", Color(0.62, 0.64, 0.72))
	_shop_info.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_shop_info.clip_text = true
	col.add_child(_shop_info)

## The countdown, set only when its second changes; on the proving ground the shop is everything.
func _update_shop_head(force: bool = false) -> void:
	if _shop_head == null:
		return
	_shop_head.visible = false              # the second cut keeps the clock in its own header
	if _tab != TAB_SHOP:
		return
	if G.proving_ground:
		_shop_cap.text = tr("Proving ground: everything in stock")
		if _sv_time != null:
			_sv_time.text = "∞"
			_sv_gauge.visible = false
		_shop_time.visible = false
		_shop_bar.visible = false
		return
	var left: float = G.shop_sale_seconds_left()
	var sec: int = int(ceil(left))
	if sec == _shop_sec and not force:
		return
	_shop_sec = sec
	_shop_cap.text = tr("Restock in")
	_shop_time.visible = true
	_shop_bar.visible = true
	_shop_time.text = "%d:%02d" % [sec / 60, sec % 60]
	var last: bool = sec <= 60                   # the last minute warms up: tomorrow is close
	_shop_time.add_theme_color_override("font_color", SALE_COL if last else Color(0.92, 0.93, 0.96))
	_shop_bar.frac = clampf(left / G.SHOP_DAY, 0.0, 1.0)
	_shop_bar.warm = last
	_shop_bar.queue_redraw()
	_sv_update_clock(sec, _shop_bar.frac, last)

## Today's counts under the countdown: the whole window, not what the filter shows.
func _update_shop_counts() -> void:
	if _shop_info == null:
		return
	var n := 0
	var sale := 0
	for bt in G.BLOCK_META:
		if G.shop_count(int(bt)) == 0:
			continue
		n += 1
		if G.shop_sale_pct(int(bt)) > 0:
			sale += 1
	_shop_info.text = tr("In stock today: %d · on sale: %d") % [n, sale]

## Which section of the shop a row stands in.
func _shop_group(it: Dictionary) -> int:
	if G.shop_sale_pct(int(it["type"])) > 0:
		return SHOP_SALE
	if int(it.get("left", -1)) > 0:
		return SHOP_TODAY
	return SHOP_ALWAYS

func _by_shop_order(a: Dictionary, b: Dictionary) -> bool:
	var ga: int = _shop_group(a)
	var gb: int = _shop_group(b)
	if ga != gb:
		return ga < gb
	return _by_block_order(a, b)

func _set_shop_filter(key: String) -> void:
	_shop_filter = key
	Q.report("garage_filter", 1)          # шаг обучения «попробовать фильтр категорий»
	for k in _filter_buttons:
		_filter_buttons[k].button_pressed = (k == key)
	_load_items()
	_rebuild_grid(_search.text if _search else "")

# Does the block pass the SHOP filter. "power" also takes what is in no category at all.
func _passes_filter(block_type: int) -> bool:
	match _shop_filter:
		"all":
			return true
		"power":
			for k in _categories:
				if _categories[k].has(block_type):
					return k == "power"
			return true
		_:
			return _categories.get(_shop_filter, []).has(block_type)

func _on_visibility_changed() -> void:
	if visible:
		refresh()

# Полное обновление: инвентарь/магазин в сетке + характеристики справа + деньги.
func refresh() -> void:
	# Спец-вкладки (музыка/настройки/древо) перестраиваются СВОИМ билдером — иначе
	# переоткрытый гараж показывал бы древо с ДИ/замками на момент закрытия.
	if _tab == TAB_MUSIC or _tab == TAB_SETTINGS or _tab == TAB_TECH:
		_select_tab(_tab)
	else:
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
			# TODAY'S WINDOW ONLY (G.shop_count): researched blocks, and of those what the day drew.
			var left: int = G.shop_count(int(block_type))
			if left == 0:
				continue
			# Цена СЧИТАЕТСЯ ЗДЕСЬ, а не берётся из кеша _prices: раз в игровые сутки часть
			# блоков уходит на распродажу, и витрина обязана показывать то, что с игрока
			# спишут. _prices остаётся базовой — рядом со скидкой мы показываем и её,
			# иначе «−30 %» не от чего отсчитать.
			_items.append({
				"type": int(block_type),
				"name": _block_name(int(block_type)),
				"count": 0,
				"price": G.shop_price_now(int(block_type)),
				"was": int(_prices[block_type]),
				"left": left,
			})
		_items.sort_custom(_by_shop_order)
		return
	var counts: Dictionary = {}
	for b in G.block_inventory:
		counts[b] = counts.get(b, 0) + 1
	for block_type in counts:
		if not _passes_filter(int(block_type)):
			continue
		_items.append({
			"type": int(block_type),
			"name": _block_name(int(block_type)),
			"count": int(counts[block_type]),
			"price": 0,
		})
	_items.sort_custom(_by_block_order)

## The order of the lists, not of pick-up or of the enum (`G.block_order`, shared with the globe).
func _by_block_order(a: Dictionary, b: Dictionary) -> bool:
	return G.block_order(int(a["type"])) < G.block_order(int(b["type"]))

# ── ЭНЦИКЛОПЕДИЯ ─────────────────────────────────────────────────────────────
# Справочник по деталям и материалам. Существует потому, что игра НИГДЕ не говорит, чем
# стабилизатор отличается от верхнего колеса, а купол — от регенератора: в магазине у блока
# есть только имя и цена, в стройке — только силуэт. Отсюда же и «что мне делать с этой
# рудой»: имя материала в инвентаре не говорит ни во что он превращается, ни зачем.
#
# КАТАЛОГ СТРОИТСЯ ИЗ ТЕХ ЖЕ ТАБЛИЦ, из которых живёт игра (G.Block, G.METAL_NAME,
# G.COMP_NAME): второй список, написанный руками, однажды отстал бы на один блок и молчал
# бы об этом. Блок без строки описания из каталога НЕ ПРОПАДАЕТ — он честно говорит, что
# описания пока нет, иначе дыру в справочнике никто бы не заметил.
## ДВА РАЗДЕЛА, И ОБА — ГРАФЫ. Плоский список всех ресурсов отсюда убран: он отвечал на вопрос
## «что есть» и молчал о том, ОТКУДА оно берётся, а ровно это и показывает цепочка — теми же
## именами и теми же связями. Два места, где написано одно и то же, всегда расходятся; здесь
## второе ещё и было бесполезнее первого.
const CODEX_KINDS := [
	["blocks",    "Blocks"],
	["chain",     "Chain"],
]
var _codex_kind: String = "blocks"
var _codex_buttons: Dictionary = {}
var _codex_col: VBoxContainer = null

# ── ЦЕПОЧКА РЕСУРСОВ: ТОТ ЖЕ ГРАФ, ЧТО И ДРЕВО ТЕХНОЛОГИЙ ───────────────────────
#
# Плоский список «сорок имён подряд» отвечает на вопрос «что есть» и молчит о том, ОТКУДА оно
# берётся. А вся экономика — четыре передела, и понять её по алфавитному списку нельзя.
#
# Рисуется ТЕМ ЖЕ холстом, что и древо (TechGraph): колонки слева направо — сырьё, слитки,
# простые, сложные, — и НАСТОЯЩИЕ ЛИНИИ СВЯЗЕЙ от родителей к потомку. Список стадий с текстовой
# стрелкой, который был здесь раньше, показывал порядок, но не показывал, что из чего: у каждого
# компонента РОВНО ДВА родителя, и это видно только линиями.
#
# Строится из тех же таблиц, что и всё остальное (G.METAL_NAME, G.COMP_NAME, G.COMP_PARENT):
# второй, написанный руками список однажды отстал бы на материал и промолчал.
const CNODE_W := 104.0
const CNODE_H := 42.0
const CCOL_W := 150.0
const CROW_H := 50.0

var _codex_root: VBoxContainer = null
var _codex_head: Label = null
var _codex_scroll: ScrollContainer = null
var _codex_graph: TechGraph = null
var _codex_info: PanelContainer = null
var _codex_info_title: Label = null
var _codex_info_body: Label = null

## ОПИСАНИЕ — ПОЛОСКОЙ ПО НИЗУ, А НЕ ОКНОМ ПО ЦЕНТРУ.
##
## Окно по центру закрывает ровно то, по чему только что ткнули, и требует отдельного действия,
## чтобы его убрать: посмотреть три записи подряд — это три открытия и три закрытия. Полоска
## лежит поверх графа снизу, сама меняет содержимое на следующий тап и не отнимает место у
## раскладки — граф под ней остаётся там же, где был.
const CODEX_INFO_H := 96.0

func _codex_build_shell(body: Node) -> void:
	_codex_root = VBoxContainer.new()
	_codex_root.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_codex_root.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_codex_root.add_theme_constant_override("separation", 6)
	_codex_root.visible = false
	body.add_child(_codex_root)
	_codex_head = Label.new()
	_codex_head.add_theme_font_size_override("font_size", 14)
	_codex_head.add_theme_color_override("font_color", Color(0.55, 0.75, 0.8, 0.9))
	_codex_head.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_codex_root.add_child(_codex_head)
	var area := Control.new()
	area.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	area.size_flags_vertical = Control.SIZE_EXPAND_FILL
	area.clip_contents = true
	_codex_root.add_child(area)
	_codex_scroll = ScrollContainer.new()
	_codex_scroll.set_anchors_preset(Control.PRESET_FULL_RECT)
	_codex_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	_codex_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	area.add_child(_codex_scroll)
	_codex_graph = TechGraph.new()
	_codex_graph.mouse_filter = Control.MOUSE_FILTER_PASS   # тач-драг прокрутки идёт сквозь холст
	_codex_scroll.add_child(_codex_graph)

	# Полоска описания — ПОВЕРХ графа, по якорям: контейнер разложил бы её в столбец и отнял
	# бы у графа высоту навсегда, даже когда показывать нечего.
	_codex_info = PanelContainer.new()
	_codex_info.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	_codex_info.offset_top = -CODEX_INFO_H
	_codex_info.visible = false
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.05, 0.09, 0.11, 0.94)
	sb.border_color = Color(0.35, 0.72, 0.78, 0.55)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(5)
	sb.set_content_margin_all(8)
	_codex_info.add_theme_stylebox_override("panel", sb)
	area.add_child(_codex_info)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 3)
	_codex_info.add_child(vb)
	var row := HBoxContainer.new()
	vb.add_child(row)
	_codex_info_title = Label.new()
	_codex_info_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_codex_info_title.add_theme_font_size_override("font_size", 14)
	_codex_info_title.add_theme_color_override("font_color", Color(0.75, 0.93, 0.98))
	_codex_info_title.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_codex_info_title.clip_text = true
	row.add_child(_codex_info_title)
	var close := Button.new()
	close.text = "X"
	close.flat = true
	close.custom_minimum_size = Vector2(26, 0)
	close.pressed.connect(func(): _codex_info.visible = false)
	row.add_child(close)
	_codex_info_body = Label.new()
	_codex_info_body.add_theme_font_size_override("font_size", 12)
	_codex_info_body.add_theme_color_override("font_color", Color(0.82, 0.9, 0.93))
	_codex_info_body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_codex_info_body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vb.add_child(_codex_info_body)

## Справочник рисует ОДИН холст на оба раздела: разница только в том, что на нём разложено.
func _build_codex_tab() -> void:
	var body: Node = get_node_or_null("Root/Main/LeftPanel/LeftVB/Body")
	if body == null:
		return
	if _codex_root == null:
		_codex_build_shell(body)
	_codex_root.visible = true
	for c in _codex_graph.get_children():
		c.queue_free()
	_codex_info.visible = false
	if _codex_kind == "blocks":
		_codex_blocks_graph()
	else:
		_codex_codex_graph()

## БЛОКИ — ТЕМ ЖЕ ДЕРЕВОМ, ЧТО И ИССЛЕДОВАНИЯ, и раскладка берётся та же самая (`_tech_layout`,
## связи из `G.TECH_PARENT`). Список по грейдам отвечал «когда я это получу» и молчал о том, из
## чего это растёт, хотя порядок изучения — и есть устройство прогрессии. Своя вторая раскладка
## здесь разъехалась бы с древом при первой же правке родителя.
##
## От древа отличается ровно одним: тут нет ни цены в ДИ, ни замков — справочник рассказывает,
## а не выдаёт. Поэтому и узлы другие (`_make_codex_block_node`), а раскладка общая.
func _codex_blocks_graph() -> void:
	_codex_head.text = tr("Blocks in research order: a child grows out of its parent. Tap any of them for its entry.")
	var pos: Dictionary = _tech_layout()
	var edges: Array = []
	var line := Color(0.35, 0.72, 0.78, 0.5)
	for bt in G.TECH_PARENT:
		var par := int(G.TECH_PARENT[bt])
		if not (pos.has(bt) and pos.has(par)):
			continue
		edges.append({"a": (pos[par] as Vector2) + Vector2(TNODE_W, TNODE_H * 0.5),
				"b": (pos[bt] as Vector2) + Vector2(0.0, TNODE_H * 0.5), "col": line})
	_codex_graph.edges = edges
	_codex_graph.queue_redraw()
	var maxx := 0.0
	var maxy := 0.0
	for bt in pos:
		var at: Vector2 = pos[bt]
		maxx = maxf(maxx, at.x)
		maxy = maxf(maxy, at.y)
		_codex_graph.add_child(_make_codex_block_node(int(bt), at))
	_codex_graph.custom_minimum_size = Vector2(maxx + TNODE_W + TMARGIN, maxy + TNODE_H + TMARGIN)

func _make_codex_block_node(bt: int, at: Vector2) -> Control:
	var btn := Button.new()
	btn.position = at
	btn.size = Vector2(TNODE_W, TNODE_H)
	btn.clip_text = true
	btn.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	btn.add_theme_font_size_override("font_size", 11)
	var meta: Dictionary = G.BLOCK_META.get(bt, {})
	# Грейд подписью: по дереву видно ПОРЯДОК, а грейд говорит, на каком уровне лицензии это
	# вообще открывается — второе из дерева не следует.
	btn.text = "%s\n%d" % [G.block_name(bt), int(meta.get("g", 1))]
	# Своя рамка нужна только затем, чтобы у неё был левый отступ под портрет: у кнопки из темы
	# сдвинуть текст нечем.
	var st := StyleBoxFlat.new()
	st.set_corner_radius_all(8)
	st.set_border_width_all(2)
	st.bg_color = Color(0.06, 0.12, 0.14, 0.92)
	st.border_color = Color(0.3, 0.6, 0.66, 0.6)
	st.content_margin_right = 6
	st.content_margin_left = 6 + (TNODE_ICON + 6 if _node_icon(btn, bt) else 0.0)
	for s in [&"normal", &"hover", &"focus"]:
		btn.add_theme_stylebox_override(s, st)
	btn.pressed.connect(_show_codex.bind("b%d" % bt))
	return btn

## ПОРТРЕТ ВНУТРИ УЗЛА ГРАФА. Одна дверь на древо и справочник: у них общая раскладка, и два
## разных способа положить картинку разъехались бы при первой правке размера узла.
##
## Возвращает false, когда портрета ещё нет: печь идёт при старте и заканчивает позже, чем
## игрок может открыть гараж (`Icons.get_icon` отдаёт null). Узел тогда рисуется как рисовался,
## а `Icons.baked` перестроит вкладку.
func _node_icon(btn: Button, bt: int) -> bool:
	var tex: Texture2D = Icons.get_icon(bt)
	if tex == null:
		return false
	var ic := TextureRect.new()
	ic.texture = tex
	ic.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	ic.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	ic.mouse_filter = Control.MOUSE_FILTER_IGNORE      # тап по картинке — это тап по узлу
	ic.set_anchors_preset(Control.PRESET_LEFT_WIDE)
	ic.offset_left = 5.0
	ic.offset_right = 5.0 + TNODE_ICON
	ic.offset_top = -TNODE_ICON * 0.5
	ic.offset_bottom = TNODE_ICON * 0.5
	btn.add_child(ic)
	return true

func _codex_codex_graph() -> void:
	_codex_head.text = tr("Ore is smelted into ingots, a pair of ingots makes a simple component, a pair of simple ones makes a complex one. Tap any of them for its entry.")

	# Колонки. Уголь стоит в первой особняком: он не плавится в слиток и идёт прямо в топливо,
	# поэтому связей у него нет и своей записи в каталоге тоже.
	var col_raw: Array = []
	for m in G.METAL_NAME.size():
		col_raw.append({"name": tr(String(G.METAL_NAME[m])) + " " + tr("ore"), "key": "m%d" % m})
	# ДЕРЕВО СТОИТ В СЫРЬЕ, УГОЛЬ — В ПЕРЕДЕЛЕ. Раньше уголь висел в первой колонке особняком,
	# без единой связи: его добывали, и он никуда не вёл. Теперь он ровно такой же передел,
	# как слиток из руды, и линия между ними это показывает.
	col_raw.append({"name": tr("Wood"), "key": "wood"})
	var col_ing: Array = []
	for m in G.METAL_NAME.size():
		col_ing.append({"name": tr(String(G.METAL_NAME[m])), "key": "m%d" % m})
	col_ing.append({"name": tr("Coal"), "key": "coal"})
	# Ярусы — G.COMP_SIMPLE_COUNT, а не шестёрка руками: число пар считается из числа металлов,
	# и одна новая руда сдвинула бы границу.
	var col_s: Array = []
	for c in mini(G.COMP_SIMPLE_COUNT, G.COMP_NAME.size()):
		col_s.append({"name": tr(String(G.COMP_NAME[c])), "key": "c%d" % c})
	var col_c: Array = []
	for c in range(G.COMP_SIMPLE_COUNT, G.COMP_NAME.size()):
		col_c.append({"name": tr(String(G.COMP_NAME[c])), "key": "c%d" % c})
	var cols: Array = [col_raw, col_ing, col_s, col_c]

	# Позиции: колонка по X, ряд по Y. Каждая колонка ЦЕНТРИРУЕТСЯ по самой длинной, иначе
	# короткая колонка сырья прижималась бы к верху, а линии к ней шли бы наискось через всё.
	var tallest := 0
	for col in cols:
		tallest = maxi(tallest, (col as Array).size())
	for ci in cols.size():
		var col: Array = cols[ci]
		var off: float = (float(tallest) - float(col.size())) * CROW_H * 0.5
		for ri in col.size():
			(col[ri] as Dictionary)["at"] = Vector2(TMARGIN + ci * CCOL_W, TMARGIN + off + ri * CROW_H)

	# Линии. Руда → слиток один к одному; компонент — от ОБОИХ родителей (G.COMP_PARENT).
	var edges: Array = []
	var line := Color(0.35, 0.72, 0.78, 0.5)
	# Руда → слиток один к одному, и тем же ребром дерево → уголь: обе строки стоят последними
	# в своих колонках, поэтому связь считается тем же индексом.
	for m in range(mini(col_raw.size(), col_ing.size())):
		edges.append({"a": (col_raw[m]["at"] as Vector2) + Vector2(CNODE_W, CNODE_H * 0.5),
				"b": (col_ing[m]["at"] as Vector2) + Vector2(0.0, CNODE_H * 0.5), "col": line})
	for c in G.COMP_NAME.size():
		var par: Array = G.COMP_PARENT[c]
		if par == null or par.size() < 2:
			continue
		# Первый ярус собирается из СЛИТКОВ, второй — из первого яруса: индексы в COMP_PARENT
		# считаются внутри своего яруса, и колонка-источник у них разная.
		var simple: bool = c < G.COMP_SIMPLE_COUNT
		var dst: Dictionary = col_s[c] if simple else col_c[c - G.COMP_SIMPLE_COUNT]
		var src: Array = col_ing if simple else col_s
		for pi in par:
			var p_i: int = int(pi)
			if p_i < 0 or p_i >= src.size():
				continue
			edges.append({"a": ((src[p_i] as Dictionary)["at"] as Vector2) + Vector2(CNODE_W, CNODE_H * 0.5),
					"b": (dst["at"] as Vector2) + Vector2(0.0, CNODE_H * 0.5), "col": line})
	_codex_graph.edges = edges
	_codex_graph.queue_redraw()

	var maxx := 0.0
	var maxy := 0.0
	for col in cols:
		for it in col:
			var at: Vector2 = (it as Dictionary)["at"]
			maxx = maxf(maxx, at.x)
			maxy = maxf(maxy, at.y)
			_codex_graph.add_child(_make_chain_node(it as Dictionary))
	_codex_graph.custom_minimum_size = Vector2(maxx + CNODE_W + TMARGIN, maxy + CNODE_H + TMARGIN)

func _make_chain_node(it: Dictionary) -> Control:
	var btn := Button.new()
	btn.position = it["at"]
	btn.size = Vector2(CNODE_W, CNODE_H)
	btn.text = String(it["name"])
	btn.clip_text = true
	btn.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	btn.add_theme_font_size_override("font_size", 11)
	var key := String(it["key"])
	if key == "":
		btn.disabled = true          # у угля своей записи в каталоге нет
	else:
		btn.pressed.connect(_show_codex.bind(key))
	return btn

func _set_codex_kind(key: String) -> void:
	_codex_kind = key
	for k in _codex_buttons:
		_codex_buttons[k].button_pressed = (k == key)
	# Цепочка — другая панель, а не другой набор плиток: перевыбираем вкладку целиком, иначе
	# сетка осталась бы видимой поверх неё.
	_select_tab(TAB_CODEX)

## Запись справочника — в полоску снизу (см. _codex_build_shell). Окно по центру закрывало ровно
## тот узел, по которому ткнули, и требовало закрытия перед следующим тапом.
func _show_codex(key: String) -> void:
	if key == "" or _codex_info == null:
		return
	var title := ""
	var body := ""
	if key.begins_with("b"):
		var bt: int = int(key.substr(1))
		title = G.block_name(bt)
		body = G.block_desc(bt)
		var rec: Dictionary = G.BLOCK_RECIPE.get(bt, {})
		if not rec.is_empty():
			body += "\n\n" + tr("Built from: %s.") % G.recipe_text(rec)
		var stats: String = _codex_stats(bt)
		if stats != "":
			body += "\n\n" + stats
	elif key == "wood" or key == "coal":
		title = tr("Wood") if key == "wood" else tr("Coal")
		body = tr("Grows on trees all over the map. Burns in a generator, or a smelter bakes it into coal, which is worth twice as much.") \
				if key == "wood" else tr("Made by a smelter out of wood: the better fuel, and worth twice the wood.")
		body += "\n\n" + tr("Sells for %d$.") % G.sell_price(key)
	elif key.begins_with("m"):
		var m: int = int(key.substr(1))
		title = tr(String(G.METAL_NAME[m]))
		body = G.metal_desc(m)
		body += "\n\n" + tr("Sells for: ore %d$, ingot %d$.") % [G.sell_price("ore%d" % m), G.sell_price(key)]
	elif key.begins_with("c"):
		var c: int = int(key.substr(1))
		title = tr(String(G.COMP_NAME[c]))
		body = G.comp_desc(c)
		body += "\n\n" + tr("Sells for %d$.") % G.sell_price(key)
	if body.strip_edges() == "":
		body = tr("No description yet.")
	_codex_info_title.text = title
	_codex_info_body.text = body
	_codex_info.visible = true

## WHAT A BLOCK CAN DO, IN THE NUMBERS THE GAME RUNS ON (the player's call: hit points, damage,
## energy). Read off the tables (`VehicleBlock.BLOCK_HP` / `BLOCK_WEIGHT`, `MachineBody.SOLAR_RATE`)
## and off an INSTANCE of the block's own scene, never typed here: a weapon's numbers are scene exports
## (a Marlit gun is the Falsus script with its own), and a faction's repair unit or charger sets its
## fields in `_init` - which instantiating runs, while `_ready` (it would build the dome) does not.
## Cached: the strip is opened by tapping, and a scene instanced per tap would stutter on a phone.
var _stats_cache: Dictionary = {}
const GENERATOR_GD := preload("res://blocks/scripts/generator.gd")
const MARLIT_SOLAR_GD := preload("res://blocks/scripts/marlit_solar.gd")

const DMG_NAMES := ["Standard", "Bullet", "Energy", "Explosive", "Cutting"]      # VehicleBlock.Dmg
const CLS_NAMES := ["Standard", "Armour", "Rubber", "Volatile", "Shield"]        # VehicleBlock.Cls

func _codex_stats(bt: int) -> String:
	if _stats_cache.has(bt):
		return _stats_cache[bt]
	var lines: Array = []
	lines.append(tr("Hit points: %d") % int(VehicleBlock.BLOCK_HP.get(bt, VehicleBlock.DEFAULT_HP)))
	if VehicleBlock.BLOCK_WEIGHT.has(bt):
		lines.append(tr("Weight: %d kg") % int(VehicleBlock.BLOCK_WEIGHT[bt]))
	var scene: PackedScene = G.get_scene(bt)
	var n: Node = scene.instantiate() if scene != null else null
	if n != null:
		if n.get("laser_damage") != null:
			var d: float = float(n.get("laser_damage"))
			var r: float = float(n.get("laser_fire_rate"))
			lines.append(tr("Damage: %d a shot every %.1f s (%d a second)") % [int(d), r, int(d / r)])
			lines.append(tr("Range: %d m") % int(n.get("laser_range")))
		elif n.get("pellets") != null:
			var hit: float = float(n.get("pellets")) * float(n.get("pellet_damage"))
			var burst: int = int(n.get("burst"))
			var cycle: float = float(burst) * 0.35 + float(n.get("reload"))
			lines.append(tr("Damage: %d pellets x %d, %d shots then a reload (%d a second up close)") % [
					int(n.get("pellets")), int(n.get("pellet_damage")), burst, int(hit * burst / cycle)])
			lines.append(tr("Range: %d m") % int(n.get("shotgun_range")))
		elif n.get("shells") != null:
			lines.append(tr("Salvo: %d shells x %d every %.1f s, 20-160 m") % [int(n.get("shells")),
					int(n.get("shell_damage")), float(n.get("salvo_period"))])
		elif n.get("aoe_damage") != null:
			lines.append(tr("Damage: %d a hit plus a %d blast, every %.1f s") % [int(n.get("damage")),
					int(n.get("aoe_damage")), 1.6])
		elif n.get("drill_damage") != null:
			var dd: int = int(n.get("drill_damage"))
			lines.append(tr("Damage: %d every %.1f s at contact (%d a second)") % [dd, 0.3, int(dd / 0.3)])
		elif n is WeaponBlock:
			var d2: float = float(n.get("damage"))
			var r2: float = float(n.get("fire_rate"))
			lines.append(tr("Damage: %d a shot every %.2f s (%d a second)") % [int(d2), r2, int(d2 / maxf(r2, 0.01))])
			lines.append(tr("Range: %d m") % int(n.get("weapon_range")))
		# the wiki's damage types (VehicleBlock.DMG_TABLE): what this deals, and what it is made of
		var kind = n.get("damage_kind")
		if kind == null and n.get("drill_damage") != null:
			kind = VehicleBlock.Dmg.CUTTING
		if kind != null:
			lines.append(tr("Damage type: %s") % tr(DMG_NAMES[int(kind)]))
		if n.has_method("damage_class") and int(n.damage_class()) != VehicleBlock.Cls.STANDARD:
			lines.append(tr("Block class: %s") % tr(CLS_NAMES[int(n.damage_class())]))
		if n.get("turn_speed") != null:
			lines.append(tr("Turret turns %d degrees a second") % int(n.get("turn_speed")))
		if n.get("capacity") != null and G.BATTERY_BLOCKS.has(bt):
			lines.append(tr("Stores %d energy") % int(n.get("capacity")))
		if n.get("heal_rate") != null:
			lines.append(tr("Repairs %d HP a second out to %.1f m, %.1f HP per unit of energy") % [
					int(n.get("heal_rate")), float(n.get("field_radius")), float(n.get("hp_per_energy"))])
		if n.get("charge_rate") != null:
			lines.append(tr("Sends %d energy a second out to %d m") % [int(n.get("charge_rate")), int(n.get("charge_range"))])
		if n.get("cost_x") != null:
			lines.append(tr("Each point of damage it stops costs %.2f energy") % float(n.get("cost_x")))
		if n.get("energy_per_sec") != null:
			lines.append(tr("Uses %d energy a second while it digs") % int(n.get("energy_per_sec")))
		n.free()
	if G.base_block(bt) == G.Block.SOLAR:
		lines.append(tr("Makes %d energy a second on an anchored machine") % int(MachineBody.SOLAR_RATE))
	elif bt == G.Block.MARLIT_SOLAR:
		lines.append(tr("Makes %d energy a second on an anchored machine") % int(MachineBody.SOLAR_RATE * MARLIT_SOLAR_GD.UNITS))
	elif bt == G.Block.GENERATOR:
		lines.append(tr("Burns fuel: wood %d, coal %d, ore %d, an ingot %d energy") % [GENERATOR_GD.ENERGY_WOOD,
				GENERATOR_GD.ENERGY_COAL, GENERATOR_GD.ENERGY_ORE, GENERATOR_GD.ENERGY_INGOT])
	var out: String = "\n".join(lines)
	_stats_cache[bt] = out
	return out

## Имя блока — ОДНОЙ ДВЕРЬЮ (G.block_name): там же лежит и перевод, а вторая копия правила
## означала бы переведённый магазин и непереведённый справочник рядом.
func _block_name(block_type: int) -> String:
	return G.block_name(block_type)

## Осталась одна колонка: слот занимает всю ширину сетки (см. _row_w). Константа держится для
## тех, кто считает раскладку от числа колонок.
const COLS := 1
## Полоска подписи по низу плитки и её шрифт. Высота фиксированная: имя в переводе длиннее
## английского, и «плавающая» полоска прыгала бы от плитки к плитке.
## Высота строки и её шрифт. Фиксированные: строка должна быть одинаковой у всех, иначе список
## «дышит» при прокрутке, а картинка блока в разных строках выходит разного размера.
const ROW_H := 56.0
const ROW_FONT := 13

## Высота строки. Имя функции осталось прежним: её зовут все заполнители слотов, а менять
## подпись ради одного слова — это правка в шести местах ради нуля смысла.
func _slot_side() -> float:
	return ROW_H

## Ширина строки — вся сетка. HFlowContainer переносит следующий слот на новую строку именно
## потому, что этот занимает её целиком.
func _row_w() -> float:
	if _grid == null or _grid.size.x <= 1.0:
		return 240.0
	return maxf(_grid.size.x - 2.0, 120.0)

func _on_grid_resized() -> void:
	if _tab != TAB_INVENTORY and _tab != TAB_SHOP and _tab != TAB_BUILDS and _tab != TAB_CODEX:
		return
	if absf(_slot_side() - _last_slot_side) < 1.0:
		return                                     # ширина слота не изменилась — перестраивать нечего
	_rebuild_grid(_search.text if _search else "")

func _rebuild_grid(filter: String) -> void:
	if _grid == null:
		return
	_last_slot_side = _slot_side()
	if _tab == TAB_SHOP and _sv_root != null:
		_hide_slots_from(0)
		_hide_heads_from(0)
		_set_empty_text("")
		_sv_rebuild()
		return
	if _tab == TAB_BUILDS:
		_hide_heads_from(0)
		_build_builds_tab()
		return
	var side := _slot_side()
	var f := filter.strip_edges().to_lower()
	var seq: Array = []
	var shown := 0
	var heads := 0
	var group := -1
	for it in _items:
		if f != "" and not str(it["name"]).to_lower().contains(f):
			continue
		if _tab == TAB_SHOP and _shop_group(it) != group:
			group = _shop_group(it)
			var h: SectionHead = _head_at(heads)
			_fill_head(h, group)
			seq.append(h)
			heads += 1
		var s: Slot = _slot_at(shown)
		_fill_item_slot(s, it, side)
		seq.append(s)
		shown += 1
	_hide_slots_from(shown)
	_hide_heads_from(heads)
	_order_grid(seq)
	if _tab == TAB_SHOP:
		_update_shop_counts()
		_update_shop_head(true)
	if shown > 0:
		_set_empty_text("")
	elif not _items.is_empty():
		_set_empty_text(tr("Nothing found"))
	elif _tab == TAB_SHOP:
		_set_empty_text(tr("Shop empty"))
	else:
		_set_empty_text(tr("Inventory empty"))

# ── Слоты сетки ───────────────────────────────────────────────────────────────
# Слоты НЕ пересоздаются: их держит пул, а пересборка лишь заполняет первые N и прячет
# остальные. Так исчезает целый класс багов — удаление ноды в Godot отложено до конца
# кадра, и вторая пересборка за тот же кадр (покупка меняет деньги, деньги дёргают
# пересборку) видела бы ещё живых детей и дописывала к ним новых: товары двоились.
#
# Слот один на все вкладки: заголовок, уголок с числом (штук / цена / блоков в сборке) и
# карандашик у сохранённых сборок. Что показать — решает заполнение, поэтому вкладки
# переключаются без единого new/free.
class Slot extends Button:
	var action: StringName = &""      # take / buy / save / load — что делает нажатие
	var arg: int = 0                  # тип блока для take и buy
	var price: int = 0
	var build_name: String = ""       # имя сборки для load
	## ИМЯ НЕ `icon`: у Button такое свойство уже есть, а поле, названное как член нативного
	## класса, роняет ВЕСЬ скрипт («Member icon redefined») — и gdparse этого не видит, только
	## движок (см. CLAUDE.md, правило 5).
	var block_icon: TextureRect = null
	var strip: ColorRect = null       # тёмная полоска по низу под подписи
	var name_lbl: Label = null        # имя детали (у самой кнопки текст пустой)
	var corner: Label = null
	var sale: Label = null            # процент скидки, отдельной строкой в правом верхнем углу
	var stock: Label = null           # "3 left" under the sale corner: a stock-limited block
	var accent: ColorRect = null      # the warm stripe down the left edge of a row on sale
	var pencil: Control = null
	var well: PanelContainer = null   # the dark square the portrait sits in (shop only)
	var coin: Control = null          # drawn currency mark before a shop price
	var lock: Control = null          # drawn padlock before a locked row's grade

var _pool: Array = []
var _empty_label: Label = null

# Слот номер i: берём из пула, а не хватило — заводим один раз и навсегда.
func _slot_at(i: int) -> Slot:
	while _pool.size() <= i:
		var fresh := _new_slot()
		_pool.append(fresh)
		_grid.add_child(fresh)
	var s: Slot = _pool[i]
	return s

func _hide_slots_from(n: int) -> void:
	for i in range(n, _pool.size()):
		(_pool[i] as Control).visible = false

## A section row of the shop, pooled like the slots.
func _head_at(i: int) -> SectionHead:
	while _heads.size() <= i:
		var h := SectionHead.new()
		h.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_heads.append(h)
		_grid.add_child(h)
	return _heads[i]

func _fill_head(h: SectionHead, group: int) -> void:
	h.custom_minimum_size = Vector2(_row_w(), HEAD_H)
	match group:
		SHOP_SALE:
			h.text = tr("On sale")
			h.col = SALE_COL
		SHOP_TODAY:
			h.text = tr("Today only")
			h.col = STOCK_COL
		_:
			h.text = tr("Always in stock")
			h.col = Color(0.6, 0.72, 0.76)
	h.visible = true
	h.queue_redraw()

func _hide_heads_from(n: int) -> void:
	for i in range(n, _heads.size()):
		(_heads[i] as Control).visible = false

## THE GRID SHOWS ITS CHILDREN IN TREE ORDER, so a rebuild puts what it filled first, in its order.
## The shop interleaves section rows with the slots, and without this the next tab would show the
## pooled slots in the order the shop left them.
func _order_grid(seq: Array) -> void:
	for i in seq.size():
		var n: Node = seq[i]
		if n.get_index() != i:
			_grid.move_child(n, i)

func _new_slot() -> Slot:
	var s := Slot.new()
	s.clip_text = true
	s.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	s.add_theme_font_size_override("font_size", 13)
	# СТРОКА, А НЕ ПЛИТКА. Левая панель узкая, и в четыре колонки плитка выходила по шестьдесят
	# точек: туда не помещается ни модель, ни имя — а имя в переводе ещё и вдвое длиннее
	# английского («Stabiliser Wheel» против «Стабилизирующее колесо»). В строке у картинки свой
	# квадрат слева, у имени вся оставшаяся ширина, у цены — правый край; читается на любой
	# ширине панели и не зависит от длины слова.
	#
	# Сетка остаётся HFlowContainer: строки получаются сами, потому что минимальная ширина слота
	# равна ширине сетки.
	var row := HBoxContainer.new()
	row.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	row.offset_left = 5.0
	row.offset_right = -6.0
	row.add_theme_constant_override("separation", 7)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	s.add_child(row)
	s.block_icon = TextureRect.new()
	s.block_icon.custom_minimum_size = Vector2(ROW_H - 8.0, ROW_H - 8.0)
	s.block_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	s.block_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	s.block_icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	s.block_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	s.well = PanelContainer.new()
	s.well.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	s.well.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(s.well)
	s.well.add_child(s.block_icon)
	s.name_lbl = Label.new()
	s.name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	s.name_lbl.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	s.name_lbl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	s.name_lbl.clip_text = true
	s.name_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(s.name_lbl)
	s.coin = CoinIcon.new()
	s.coin.custom_minimum_size = Vector2(16.0, 16.0)
	s.coin.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	s.coin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	s.coin.visible = false
	row.add_child(s.coin)
	s.lock = LockIcon.new()
	s.lock.custom_minimum_size = Vector2(16.0, 16.0)
	s.lock.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	s.lock.mouse_filter = Control.MOUSE_FILTER_IGNORE
	s.lock.visible = false
	row.add_child(s.lock)
	s.corner = Label.new()
	s.corner.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	s.corner.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	s.corner.custom_minimum_size = Vector2(58.0, 0.0)
	s.corner.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(s.corner)
	# ПРОЦЕНТ СКИДКИ — СВОЙ УГОЛ, ПРАВЫЙ ВЕРХНИЙ. Он стоял в той же строке, что и цена, и
	# «120$  −30%» в угол слота просто не влезало: строка обрезалась, и от скидки оставалась
	# половина процента. Две короткие надписи в разных углах читаются и на самом узком слоте.
	s.sale = Label.new()
	s.sale.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	s.sale.offset_left = -88.0
	s.sale.offset_top = 3.0
	s.sale.offset_right = -84.0
	s.sale.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	s.sale.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	s.sale.add_theme_font_size_override("font_size", 11)
	s.sale.add_theme_color_override("font_color", Color(0.1, 0.07, 0.0))
	var sale_sb := _chip(SALE_COL)
	sale_sb.bg_color = SALE_COL
	s.sale.add_theme_stylebox_override("normal", sale_sb)
	s.sale.mouse_filter = Control.MOUSE_FILTER_IGNORE
	s.sale.visible = false
	s.add_child(s.sale)
	s.stock = Label.new()
	s.stock.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT)
	s.stock.offset_left = -88.0
	s.stock.offset_top = -19.0
	s.stock.offset_right = -84.0
	s.stock.offset_bottom = -3.0
	s.stock.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	s.stock.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	s.stock.add_theme_font_size_override("font_size", 11)
	s.stock.add_theme_color_override("font_color", STOCK_COL)
	s.stock.add_theme_stylebox_override("normal", _chip(STOCK_COL))
	s.stock.mouse_filter = Control.MOUSE_FILTER_IGNORE
	s.stock.visible = false
	s.add_child(s.stock)
	s.accent = ColorRect.new()
	s.accent.set_anchors_and_offsets_preset(Control.PRESET_LEFT_WIDE)
	s.accent.offset_top = 0.0
	s.accent.offset_bottom = 0.0
	s.accent.offset_right = 4.0
	s.accent.color = SALE_COL
	s.accent.mouse_filter = Control.MOUSE_FILTER_IGNORE
	s.accent.visible = false
	s.add_child(s.accent)
	# Карандашик — подсказка «у слота есть меню», не кнопка: нажатия пропускает насквозь.
	s.pencil = PencilIcon.new()
	s.pencil.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	s.pencil.offset_left = -24.0
	s.pencil.offset_top = 2.0
	s.pencil.offset_right = -2.0
	s.pencil.offset_bottom = 24.0
	s.pencil.modulate = Color(1, 1, 1, 0.45)
	s.pencil.mouse_filter = Control.MOUSE_FILTER_IGNORE
	s.add_child(s.pencil)
	# Сигналы вешаем ОДИН раз на всю жизнь ноды. Что делать по нажатию — читаем из
	# slot.action, поэтому при смене вкладки ничего не надо переподключать.
	s.pressed.connect(_on_slot_pressed.bind(s))
	s.gui_input.connect(_on_slot_gui_input.bind(s))
	s.button_up.connect(func() -> void: _hold_name = "")
	return s

func _on_slot_pressed(s: Slot) -> void:
	match s.action:
		&"take": _take_into_hand(s.arg)
		&"buy":  _buy(s.arg, s.price)
		&"save": _save_current_build()
		&"load": _load_build(s.build_name)

## Иконка блока, если она уже испечена. НЕТ — просто нет: плитка работает как работала, а печь
## закончит и перерисует (Icons.baked). Условием показа магазина картинка быть не может.
func _set_slot_icon(s: Slot, bt: int) -> void:
	var tex: Texture2D = Icons.get_icon(bt)
	s.block_icon.texture = tex
	s.block_icon.visible = tex != null

# Общая часть: размер, надпись и сброс всего, что мог включить прошлый жилец слота.
## Плитка квадратная и НЕ РАСТЯГИВАЕТСЯ, а имена деталей в переводе длиннее английских:
## «Stabiliser Wheel» это два коротких слова, «Стабилизирующее колесо» — одно длинное, которое
## переносом не разбить. Подгоняем шрифт под САМОЕ ДЛИННОЕ СЛОВО: перенос спасает строку, но не
## слово, а clip_text у плитки включён — не влезшее просто исчезает.
const SLOT_FONT_MAX := 13
const SLOT_FONT_MIN := 8
const BUILD_ROW_H := 84.0
const BUILD_THUMB := Vector2(114.0, 76.0)

func _reset_slot(s: Slot, label: String, side: float) -> void:
	s.custom_minimum_size = Vector2(_row_w(), side)
	s.block_icon.custom_minimum_size = Vector2(ROW_H - 8.0, ROW_H - 8.0)   # a build row widens it
	s.text = ""
	s.name_lbl.text = label
	s.name_lbl.add_theme_font_size_override("font_size", ROW_FONT)
	s.corner.add_theme_font_size_override("font_size", ROW_FONT)
	s.tooltip_text = ""
	s.disabled = false
	s.modulate = Color(1, 1, 1, 1)
	s.action = &""
	s.arg = 0
	s.price = 0
	s.build_name = ""
	s.corner.visible = false
	s.block_icon.visible = false
	# Цвет ценника СБРАСЫВАЕМ: слоты живут в пуле и переиспользуются, поэтому жёлтый ярлык
	# распродажи иначе остался бы висеть на том товаре, который займёт слот следующим.
	s.corner.remove_theme_color_override("font_color")
	s.sale.visible = false
	s.stock.visible = false
	s.accent.visible = false
	s.pencil.visible = false
	s.coin.visible = false
	s.lock.visible = false
	s.corner.custom_minimum_size.x = 58.0
	for st in ["normal", "hover", "pressed", "disabled"]:
		s.remove_theme_stylebox_override(st)
	s.well.add_theme_stylebox_override("panel", StyleBoxEmpty.new())
	s.visible = true

# ИНВЕНТАРЬ: в углу ×count, клик → блок в руку.
# МАГАЗИН: в углу цена, клик → купить (выключен, если не хватает денег или блок заперт).
func _fill_item_slot(s: Slot, it: Dictionary, side: float) -> void:
	_reset_slot(s, str(it["name"]), side)
	s.arg = int(it["type"])
	_set_slot_icon(s, s.arg)
	s.corner.visible = true
	if _tab != TAB_SHOP:
		s.action = &"take"
		s.corner.text = "×%d" % int(it["count"])
		return
	s.price = int(it["price"])
	var meta: Dictionary = G.BLOCK_META.get(s.arg, {})
	var rs: Dictionary = _row_style(String(meta.get("f", "start")))
	for st in rs:
		s.add_theme_stylebox_override(st, rs[st])
	var well_sb := StyleBoxFlat.new()
	well_sb.bg_color = Color(0.035, 0.035, 0.045, 0.9)
	well_sb.border_width_bottom = 1
	well_sb.border_color = EDGE_HI
	well_sb.anti_aliasing = false
	s.well.add_theme_stylebox_override("panel", well_sb)
	s.corner.custom_minimum_size.x = 0.0
	if not G.is_block_shop_unlocked(s.arg):
		# Замок: блок виден (мотивация), но не покупается. Причина в углу и тултипе:
		# не исследован в древе / не хватает грейда лицензии.
		var m: Dictionary = G.BLOCK_META.get(s.arg, {})
		if not m.is_empty() and G.grade(m["f"]) < int(m["g"]):
			s.corner.text = "gr.%d" % int(m["g"])
			s.tooltip_text = tr("Requires license grade %d") % int(m["g"])
		else:
			s.corner.text = tr("tree")
			s.tooltip_text = tr("Research in the tech tree")
		s.lock.visible = true
		s.disabled = true
		s.modulate = Color(1, 1, 1, 0.5)
		return
	s.action = &"buy"
	s.corner.text = "%d" % s.price
	s.coin.visible = true
	# A stock-limited block says how many are left today, under the sale corner; a basic one is
	# endless and says nothing - its section does.
	var left: int = int(it.get("left", -1))
	if left > 0:
		s.stock.text = tr("%d left") % left
		s.stock.visible = true
	var off: int = G.shop_sale_pct(s.arg)
	if off > 0:
		# РАСПРОДАЖА ЧИТАЕТСЯ С ОДНОГО ВЗГЛЯДА: цена со скидкой внизу, процент мелким сверху
		# справа, старая цена — в подсказке. Процент обязателен: без него игрок не отличит
		# скидку от блока, который просто дешевле соседнего.
		s.corner.add_theme_color_override("font_color", SALE_COL)
		s.sale.text = "−%d%%" % off
		s.sale.visible = true
		s.accent.visible = true
		s.tooltip_text = tr("On sale: %d$ instead of %d$") % [s.price, int(it.get("was", s.price))]
	s.disabled = G.money < s.price
	if s.disabled:
		# NOT ENOUGH MONEY READS ON THE PRICE: a disabled Button dims its own box, not the labels
		# in it, so the row looked buyable and the tap did nothing.
		s.corner.add_theme_color_override("font_color", POOR_COL)
		s.modulate = Color(1, 1, 1, 0.72)

# Надпись «пусто» тоже переиспользуем: пустая строка — просто прячем.
func _set_empty_text(text: String) -> void:
	if text == "":
		if _empty_label != null and is_instance_valid(_empty_label):
			_empty_label.visible = false
		return
	if _empty_label == null or not is_instance_valid(_empty_label):
		_empty_label = Label.new()
		_empty_label.modulate = Color(1, 1, 1, 0.5)
		_grid.add_child(_empty_label)
	_empty_label.text = text
	_empty_label.visible = true

# ── Вкладка СБОРКИ (сохранённые машины) ───────────────────────────────────────
func _build_builds_tab() -> void:
	var side := _slot_side()
	var n := 0
	var add: Slot = _slot_at(n)
	_reset_slot(add, tr("+ Save\ncurrent"), side)
	add.action = &"save"
	n += 1
	for build_name in G.saved_builds:
		_fill_build_slot(_slot_at(n), str(build_name), side)
		n += 1
	_hide_slots_from(n)
	_order_grid(_pool.slice(0, n))
	_set_empty_text("")

func _fill_build_slot(s: Slot, build_name: String, side: float) -> void:
	var layout: Array = G.saved_builds.get(build_name, [])
	_reset_slot(s, build_name, side)
	s.action = &"load"
	s.build_name = build_name
	s.corner.visible = true
	s.corner.text = tr("%d bl.") % layout.size()
	# THE MACHINE ITSELF, not a name to remember it by (Icons.get_build_thumb): a taller row with a
	# wide picture on the left. NULL while it is being photographed - the row works without it.
	s.custom_minimum_size.y = BUILD_ROW_H
	s.block_icon.custom_minimum_size = BUILD_THUMB
	var tex: Texture2D = Icons.get_build_thumb(layout)
	s.block_icon.texture = tex
	s.block_icon.visible = tex != null
	# Действия (переименовать/удалить) — по ДОЛГОМУ нажатию (и правой кнопкой на ПК), а не
	# крошечными иконками в углу: на телефоне в 26 px попасть пальцем невозможно, а увеличить
	# их прямо в слоте — значит закрыть название сборки. В меню цели крупные и не мешают.
	s.pencil.visible = true                            # значок «у слота есть действия»

# ── Долгое нажатие по слоту сборки → меню действий ────────────────────────────
const HOLD_MS := 450
var _hold_name: String = ""
var _hold_start: int = 0
var _build_menu: PopupMenu = null
var _menu_target: String = ""
var _skip_apply: bool = false

func _on_slot_gui_input(event: InputEvent, s: Slot) -> void:
	if s.action != &"load":
		return                                # долгое нажатие есть только у сохранённых сборок
	# ПК: правая кнопка открывает меню сразу.
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
		_open_build_menu(s.build_name)
		return
	if event is InputEventMouseButton or event is InputEventScreenTouch:
		if event.pressed:
			_hold_name = s.build_name
			_hold_start = Time.get_ticks_msec()
		else:
			_hold_name = ""

func _process(_delta: float) -> void:
	if visible and _tab == TAB_SHOP:
		_update_shop_head()
	# Держим палец на слоте дольше HOLD_MS → открываем меню (и гасим последующее «применить»).
	if _hold_name != "" and Time.get_ticks_msec() - _hold_start >= HOLD_MS:
		var n := _hold_name
		_hold_name = ""
		_skip_apply = true
		_open_build_menu(n)

func _open_build_menu(build_name: String) -> void:
	_menu_target = build_name
	if _build_menu == null or not is_instance_valid(_build_menu):
		_build_menu = PopupMenu.new()
		_build_menu.add_theme_font_size_override("font_size", 18)
		_build_menu.add_item(tr("Apply"), 0)
		_build_menu.add_item(tr("Rename"), 1)
		_build_menu.add_item(tr("Delete"), 2)
		_build_menu.id_pressed.connect(_on_build_menu_id)
		add_child(_build_menu)
	_build_menu.title = build_name
	_build_menu.reset_size()
	# Крупные строки: минимальная ширина + высота элемента под палец.
	_build_menu.min_size = Vector2i(220, 0)
	_build_menu.popup_centered()

func _on_build_menu_id(id: int) -> void:
	match id:
		0: _load_build(_menu_target)
		1: _ask_rename_build(_menu_target)
		2: _ask_delete_build(_menu_target)

## The shop's day as a bar that empties toward the restock; the last minute turns it warm.
class DayBar extends Control:
	var frac: float = 1.0
	var warm: bool = false
	func _draw() -> void:
		# a gauge, not a progress pill: a sunk track, a flat fill, a notch every tenth of the day
		draw_rect(Rect2(Vector2.ZERO, size), Color(0.03, 0.03, 0.04, 1.0))
		var w: float = size.x * frac
		if w >= 1.0:
			var col := Color(1.0, 0.82, 0.22) if warm else Color(0.43, 0.6, 0.85)
			draw_rect(Rect2(Vector2.ZERO, Vector2(w, size.y)), col)
			draw_rect(Rect2(Vector2.ZERO, Vector2(w, 1.0)), col.lightened(0.3))
		for i in range(1, 10):
			var x: float = floorf(size.x * i / 10.0)
			draw_rect(Rect2(x, 0.0, 2.0, size.y), Color(0.03, 0.03, 0.04, 1.0))

## A section row of the shop's list: its name in the section's colour and a rule running on to the
## right edge, drawn - a Label cannot draw the rule, and a separator node beside it is a second row.
class SectionHead extends Control:
	var text: String = ""
	var col: Color = Color.WHITE
	const FS := 12
	func _draw() -> void:
		# a stencilled tab in the section's colour with dark letters, then a rule to the edge
		var font: Font = get_theme_default_font()
		var cap: String = text.to_upper()
		var tw: float = font.get_string_size(cap, HORIZONTAL_ALIGNMENT_LEFT, -1, FS).x
		var top: float = 4.0
		var h: float = size.y - top - 2.0
		var tab_w: float = tw + 14.0
		draw_colored_polygon(PackedVector2Array([Vector2(0, top), Vector2(tab_w + 6.0, top),
			Vector2(tab_w, top + h), Vector2(0, top + h)]), col)
		draw_string(font, Vector2(7.0, top + h * 0.5 + FS * 0.36), cap, HORIZONTAL_ALIGNMENT_LEFT, -1, FS,
			Color(0.06, 0.06, 0.07))
		var y: float = top + h - 1.0
		if size.x - tab_w > 20.0:
			draw_rect(Rect2(tab_w + 4.0, y, size.x - tab_w - 6.0, 1.0), Color(col.r, col.g, col.b, 0.45))

## The shop's currency mark, drawn (rule 11): a flat octagonal token with a slot, the game's gold.
class CoinIcon extends Control:
	func _draw() -> void:
		var c := size * 0.5
		var r: float = minf(size.x, size.y) * 0.5 - 1.0
		var pts := PackedVector2Array()
		for i in 8:
			var a: float = TAU * (i + 0.5) / 8.0
			pts.append(c + Vector2(cos(a), sin(a)) * r)
		draw_colored_polygon(pts, Color(0.83, 0.62, 0.24))
		var inner := PackedVector2Array()
		for p in pts:
			inner.append(c + (p - c) * 0.62)
		draw_colored_polygon(inner, Color(1.0, 0.82, 0.38))
		draw_rect(Rect2(c.x - 1.0, c.y - r * 0.4, 2.0, r * 0.8), Color(0.55, 0.38, 0.12))

## A padlock before a locked row's grade, drawn.
class LockIcon extends Control:
	func _draw() -> void:
		var c := size * 0.5
		var col := Color(0.62, 0.64, 0.72)
		draw_rect(Rect2(c.x - 6.0, c.y - 1.0, 12.0, 8.0), col)
		draw_polyline(PackedVector2Array([c + Vector2(-4, -1), c + Vector2(-4, -5), c + Vector2(-2, -7),
			c + Vector2(2, -7), c + Vector2(4, -5), c + Vector2(4, -1)]), col, 2.0)
		draw_rect(Rect2(c.x - 1.0, c.y + 1.0, 2.0, 3.0), Color(0.06, 0.06, 0.07))

# Иконки рисуем в коде: шрифт проекта не рендерит эмодзи (пустые кнопки — уже проходили).
class PencilIcon extends Control:
	func _draw() -> void:
		var c := size * 0.5
		var col := Color(0.88, 0.96, 0.98)
		draw_line(c + Vector2(-6, 6), c + Vector2(4, -5), col, 2.4)      # корпус ручки
		draw_line(c + Vector2(-3, 7), c + Vector2(6, -3), col, 2.4)
		draw_line(c + Vector2(4, -5), c + Vector2(6, -3), col, 2.4)      # обод у наконечника
		draw_colored_polygon(PackedVector2Array([                        # остриё
			c + Vector2(-6, 6), c + Vector2(-3, 7), c + Vector2(-7, 8)]), col)

class TrashIcon extends Control:
	func _draw() -> void:
		var c := size * 0.5
		var col := Color(1.0, 0.62, 0.62)                                # красноватая — «удалить»
		draw_line(c + Vector2(-8, -5), c + Vector2(8, -5), col, 2.2)     # крышка
		draw_line(c + Vector2(-3, -8), c + Vector2(3, -8), col, 2.2)     # ручка крышки
		draw_polyline(PackedVector2Array([                               # корпус ведра
			c + Vector2(-6, -4), c + Vector2(-5, 8),
			c + Vector2(5, 8),   c + Vector2(6, -4)]), col, 2.2)
		draw_line(c + Vector2(-2, -2), c + Vector2(-2, 5), col, 1.6)     # рёбра
		draw_line(c + Vector2(2, -2), c + Vector2(2, 5), col, 1.6)

# ── Переименование / удаление сборки ──────────────────────────────────────────
var _rename_dialog: AcceptDialog = null
var _rename_edit: LineEdit = null
var _rename_target: String = ""

func _ask_rename_build(build_name: String) -> void:
	_rename_target = build_name
	if _rename_dialog == null or not is_instance_valid(_rename_dialog):
		_rename_dialog = AcceptDialog.new()
		_rename_dialog.title = tr("Rename build")
		_rename_dialog.ok_button_text = tr("Rename")
		_rename_dialog.add_cancel_button(tr("Cancel"))
		_rename_edit = LineEdit.new()
		_rename_edit.custom_minimum_size = Vector2(260, 0)
		_rename_edit.max_length = 24
		_rename_dialog.add_child(_rename_edit)
		_rename_dialog.register_text_enter(_rename_edit)     # Enter = подтвердить
		_rename_dialog.confirmed.connect(_apply_rename)
		add_child(_rename_dialog)
	_rename_edit.text = build_name
	_rename_dialog.popup_centered(Vector2i(320, 120))
	_rename_edit.grab_focus()
	_rename_edit.select_all()

func _apply_rename() -> void:
	var new_name: String = _rename_edit.text.strip_edges()
	if new_name.is_empty() or new_name == _rename_target:
		return
	if not G.rename_build(_rename_target, new_name):
		_say(tr("Name already taken: %s") % new_name)
		return
	_rebuild_grid("")
	_say(tr("Renamed: %s") % new_name)

var _delete_dialog: ConfirmationDialog = null
var _delete_target: String = ""

func _ask_delete_build(build_name: String) -> void:
	_delete_target = build_name
	if _delete_dialog == null or not is_instance_valid(_delete_dialog):
		_delete_dialog = ConfirmationDialog.new()
		_delete_dialog.title = tr("Delete build")
		_delete_dialog.ok_button_text = tr("Delete")
		_delete_dialog.confirmed.connect(_apply_delete)
		add_child(_delete_dialog)
	_delete_dialog.dialog_text = tr("Delete build \"%s\"?") % build_name
	_delete_dialog.popup_centered(Vector2i(340, 130))

func _apply_delete() -> void:
	G.delete_build(_delete_target)
	_rebuild_grid("")
	_say(tr("Deleted: %s") % _delete_target)

func _save_current_build() -> void:
	var v: Node = _get_vehicle()
	if v == null or not v.has_method("capture_build"):
		return
	var layout: Array = v.capture_build()
	if layout.is_empty():
		return
	var bname: String = tr("Build %d") % (G.saved_builds.size() + 1)
	G.save_build(bname, layout)
	_rebuild_grid("")
	_say(tr("Build saved: %s") % bname)

# Применить сохранённую сборку с ПРОВЕРКОЙ блоков: пул = блоки на машине + инвентарь.
func _load_build(build_name: String) -> void:
	# После долгого нажатия кнопка всё равно шлёт pressed при отпускании — гасим, иначе меню
	# открылось бы И сборка тут же применилась.
	if _skip_apply:
		_skip_apply = false
		return
	var v: Node = _get_vehicle()
	if v == null or not v.has_method("apply_build"):
		return
	var blocks_node: Node = v.get_node_or_null("blocks")
	if blocks_node == null:
		return
	var target: Array = G.saved_builds.get(build_name, [])
	if target.is_empty():
		return
	# THE PROVING GROUND'S STOCK IS ENDLESS AND IS NOT AN INVENTORY. It is ten of every type in
	# G.block_inventory so the picker globe has something to walk (proving_ground._stock_all_blocks),
	# and the pool arithmetic below read those ten as all there was: a build with a dozen belts
	# "ran short", was cut down, and the leftover written back as the inventory took every type the
	# build used out of the globe for good - measured, belts 10 -> 0, 45 types -> 43, 21 of 25
	# placed. That was "after a saved build nothing could be taken into the hand".
	if G.proving_ground:
		v.apply_build(target)
		_say(tr("Build applied: %s") % build_name)
		refresh()
		return
	var current: Array = blocks_node.get_layout() if blocks_node.has_method("get_layout") else []
	var on_machine: Dictionary = G.layout_counts(current)
	var need: Dictionary = G.layout_counts(target)
	# THE POOL IS THE MACHINE PLUS WHAT `G.block_available` SEES - the inventory AND the blocks lying
	# within reach, the door every other build path asks. It was the machine plus the inventory only,
	# and after a death the starter kit is not in the inventory: it circles the new cabin and lands
	# beside it. So a saved build placed the cabin and two or three blocks and stopped, with the
	# rest of its kit lying in the grass (the player's report).
	var pool: Dictionary = on_machine.duplicate()
	for t in need:
		pool[t] = int(pool.get(t, 0)) + G.block_available(int(t))
	# SHORT OF BLOCKS: BUILD WHAT HOLDS TOGETHER. It used to refuse outright on any missing type.
	# Now the part the pool can build is built outward from the core, and only through what was
	# actually placed (blocks.buildable_subset), so a gun whose hull is missing is left out rather
	# than hung in the air. Whatever is not placed stays in the inventory.
	var build: Array = target
	var missing: Dictionary = {}
	for t in need:
		var short: int = int(need[t]) - int(pool.get(t, 0))
		if short > 0:
			missing[t] = short
	if not missing.is_empty():
		build = blocks_node.get_script().buildable_subset(target, pool)
		if build.is_empty():
			_say(tr("Missing: ") + _missing_text(missing))
			return
	# WHAT THE BUILD USES COMES OFF THE MACHINE FIRST, the rest through `G.consume_block` (inventory,
	# then the nearest loose one); what the machine had and the build does not use goes to the
	# inventory. Writing the inventory back from the pool, as before, would now copy every block
	# lying in reach into it while it still lay there.
	var used: Dictionary = G.layout_counts(build)
	var types: Dictionary = {}
	for t in used:
		types[t] = true
	for t in on_machine:
		types[t] = true
	for t in types:
		var from_machine: int = mini(int(used.get(t, 0)), int(on_machine.get(t, 0)))
		for _i in int(used.get(t, 0)) - from_machine:
			G.consume_block(int(t))
		for _i in int(on_machine.get(t, 0)) - from_machine:
			G.block_inventory.append(int(t))
	G.mark_progress_dirty()
	v.apply_build(build)
	if missing.is_empty():
		_say(tr("Build applied: %s") % build_name)
	else:
		_say(tr("Built %d of %d blocks. Missing: ") % [build.size(), target.size()] + _missing_text(missing))
	refresh()

func _missing_text(missing: Dictionary) -> String:
	var parts: Array = []
	for t in missing:
		parts.append("%s ×%d" % [_block_name(int(t)), int(missing[t])])
	return ", ".join(parts)

func _say(text: String) -> void:
	var d = get_node_or_null("/root/Dialogue")
	if d:
		d.say("Garage", text)

# ── Действия ──────────────────────────────────────────────────────────────────
func _take_into_hand(block_type: int) -> void:
	# Доступен — значит в инвентаре ИЛИ лежит рядом (G.BUILD_REACH). Списывается там же, одной
	# дверью: спрашивать в одном месте, а вычитать в другом — это разъехаться на первом же блоке.
	if G.block_available(block_type) <= 0:
		return
	var v: Node = _get_vehicle()
	if v == null or not v.has_method("take_block_into_hand"):
		push_warning("tech_ui: no active vehicle found to hand the block to")
		return
	if not v.take_block_into_hand(block_type):
		return                                  # в руке уже что-то есть
	G.consume_block(block_type)                 # инвентарь, а если там пусто — ближайший из мира
	# Переключаемся на СТРОЙКУ, а не закрываем гараж. Закрытие теперь выводит машину из
	# режима постройки, а тот возвращает блок из руки в инвентарь — взять блок было нельзя.
	_select_tab(TAB_BUILD)

func _buy(block_type: int, price: int) -> void:
	if G.money < price or G.shop_count(block_type) == 0:
		return
	G.money -= price
	G.shop_take(block_type)
	G.block_inventory.append(block_type)
	G.mark_progress_dirty()
	# Магазин остаётся открытым: обновляем цены/доступность кнопок и счётчик денег.
	_rebuild_grid(_search.text if _search else "")
	_update_currency()
	_refresh_stats()

# ── Вкладки ───────────────────────────────────────────────────────────────────
## ПЕЧЬ ЗАКОНЧИЛА — ПЕРЕСТРАИВАЕМ ТУ ВКЛАДКУ, ЧТО ОТКРЫТА. Портреты появляются через пару
## секунд после запуска, и игрок вполне может открыть гараж раньше: без этого он увидел бы
## древо без картинок до следующего переключения вкладки.
## A machine picture is ready: only the builds tab shows them, so only it is redrawn.
func _on_build_baked() -> void:
	if is_inside_tree() and visible and _tab == TAB_BUILDS and _grid != null:
		_rebuild_grid(_search.text if _search else "")

func _on_icons_baked() -> void:
	if not (is_inside_tree() and visible):
		return
	if _grid != null:
		_rebuild_grid(_search.text if _search else "")
	if _tech_root != null and _tech_root.visible:
		_build_tech_tab()
	if _codex_root != null and _codex_root.visible:
		_build_codex_tab()

func _select_tab(idx: int) -> void:
	_tab = idx
	# Шаги обучения по вкладкам. TAB_INVENTORY не докладываем: её открывает сам _ready,
	# и шаг закрылся бы раньше, чем игрок что-то увидел.
	match idx:
		TAB_SHOP:  Q.report("garage_shop", 1)
		TAB_TECH:  Q.report("garage_tech", 1)
		TAB_MUSIC: Q.report("garage_music", 1)
	for i in _tab_buttons.size():
		if _tab_buttons[i]:
			_tab_buttons[i].button_pressed = (i == idx)
	_update_shop_head(true)
	if _filter_col:
		# В СПРАВОЧНИКЕ ФИЛЬТРА БОЛЬШЕ НЕТ: там теперь граф, а не сетка плиток, и «показать только
		# оружие» в дереве означало бы дерево с выломанной серединой — связи ведут через скрытые
		# узлы. Фильтр остался там, где он отбирает ТОВАР: магазин и инвентарь.
		_filter_col.visible = (_tab == TAB_INVENTORY)
	if _codex_col:
		_codex_col.visible = (_tab == TAB_CODEX)
	# МУЗЫКА/НАСТРОЙКИ — спец-панель-список; ДРЕВО — свой 2D-панорамируемый граф.
	var extra_list: bool = _tab == TAB_MUSIC or _tab == TAB_SETTINGS
	# СПРАВОЧНИК ЦЕЛИКОМ — ГРАФ, оба его раздела: у компонента ровно два родителя, у блока —
	# один, и то и другое видно только линиями связей, а не сеткой плиток.
	var is_codex: bool = _tab == TAB_CODEX
	var is_tech: bool = _tab == TAB_TECH
	var is_build: bool = _tab == TAB_BUILD
	var grid_scroll: Node = get_node_or_null("Root/Main/LeftPanel/LeftVB/Body/Scroll")
	var is_shop: bool = _tab == TAB_SHOP
	if grid_scroll:
		grid_scroll.visible = not (extra_list or is_tech or is_build or is_codex or is_shop)
	_shop_v2_show(is_shop)
	if _codex_root:
		_codex_root.visible = is_codex
	if _extra_scroll:
		_extra_scroll.visible = extra_list
	if _tech_root:
		_tech_root.visible = is_tech
	if _search:
		_search.visible = not (extra_list or is_tech or is_build or is_codex or is_shop)
	_widen_left_panel(is_tech or is_codex or is_shop)   # графу нужна та же ширина, что и древу
	_show_left_panel(not is_build)
	_set_world_clickthrough(is_build)
	tab_changed.emit(_tab)
	if is_build:
		return                       # своего содержимого у вкладки нет
	if is_codex:
		_build_codex_tab()
		return
	if extra_list:
		if _tab == TAB_MUSIC:
			_build_music_tab()
		else:
			_build_settings_tab()
		return
	if is_tech:
		_build_tech_tab()
		return
	_load_items()
	_rebuild_grid(_search.text if _search else "")

# ── Вкладка СТРОЙКА ───────────────────────────────────────────────────────────
# У вкладки нет своего содержимого: на ней прячется ВСЯ левая панель, чтобы было видно
# машину, а глобус выбора блока и кнопки поворота остаются там же, где были на HUD.
# Сверху вкладки, справа — вес и характеристики.
signal tab_changed(idx: int)

## Какая вкладка открыта сейчас (HUD смотрит, показывать ли строительные виджеты).
func current_tab() -> int:
	return _tab

## Открыть гараж сразу на нужной вкладке (HUD зовёт при входе в режим стройки).
func open_tab(idx: int) -> void:
	_select_tab(idx)

# ── Цели для обучающего пальца ────────────────────────────────────────────────
# Наставник (tutorial_director.gd) не лазит по внутренностям гаража — спрашивает узел
# по ключу. Так перестановка панелей внутри не ломает обучение.
func tutorial_target(key: String) -> Control:
	match key:
		"tab_inventory": return _tab_buttons[TAB_INVENTORY] as Control
		"tab_shop":      return _tab_buttons[TAB_SHOP] as Control
		"tab_tech":      return _tab_buttons[TAB_TECH] as Control
		"tab_music":     return _tab_buttons[TAB_MUSIC] as Control
		# Крестик окна. Нужен обучению: пока гараж открыт, кнопка меню на HUD СПРЯТАНА вместе
		# со всем игровым управлением, и показывать «закрой склад» было не на что — палец не
		# ставился вовсе, а на экране оставалась подсказка прошлого шага.
		"close":         return (%Close as Control) if has_node("%Close") else null
		"grid":          return _grid
		"currency":      return (%Currency as Control) if has_node("%Currency") else null
		"progress":      return _prog_label
		"extra":         return _extra_scroll
		"tech":          return _tech_root
		"filters":
			if _tab == TAB_SHOP and _sv_tabs.has("all"):
				return _sv_tabs["all"] as Control
			if _filter_col != null and _filter_col.get_child_count() > 0:
				return _filter_col.get_child(0) as Control
			return null
		"slot":
			if _tab == TAB_SHOP:
				for t in _sv_tiles:
					if (t as Control).visible:
						return t as Control
				return null
			# Первый ВИДИМЫЙ: в пуле за ним стоят спрятанные слоты прошлых вкладок.
			if _grid != null:
				for c in _grid.get_children():
					if c is Control and (c as Control).visible:
						return c as Control
			return null
	return null

# ДРЕВО занимает всю ширину до панели характеристик: граф широкий, а в колонке 430 px от
# него видно две ветки. Пустой распорке Center на это время расширяться незачем.
# Вкладка СТРОЙКА прячет левую панель целиком: строить надо глядя на машину, а не на сетку
# инвентаря. Сверху остаются вкладки, справа — вес и характеристики.
# На вкладке СТРОЙКА тапы должны доходить до мира: игрок ставит и снимает блоки, глядя на
# машину. Гасим перехват у КОРНЕЙ (сам гараж и его контейнеры) — дети со своим mouse_filter
# (вкладки сверху, панель справа) кликаются по-прежнему, IGNORE отключает только сам узел.
func _set_world_clickthrough(on: bool) -> void:
	var mode: Control.MouseFilter = Control.MOUSE_FILTER_IGNORE if on else Control.MOUSE_FILTER_STOP
	mouse_filter = mode
	for path in ["Root", "Root/Main"]:
		var n: Control = get_node_or_null(path) as Control
		if n != null:
			n.mouse_filter = mode

func _show_left_panel(visible_on: bool) -> void:
	var left: Control = get_node_or_null("Root/Main/LeftPanel") as Control
	if left != null:
		left.visible = visible_on

func _widen_left_panel(wide: bool) -> void:
	var left: Control = get_node_or_null("Root/Main/LeftPanel") as Control
	var centre: Control = get_node_or_null("Root/Main/Center") as Control
	if left != null:
		left.size_flags_horizontal = Control.SIZE_EXPAND_FILL if wide else Control.SIZE_FILL
	if centre != null:
		centre.visible = not wide

# ── Поиск активной машины ─────────────────────────────────────────────────────
func _get_vehicle() -> Node:
	var cc: Node = get_tree().get_first_node_in_group("camera_controller")
	if cc == null:
		cc = get_node_or_null("/root/Main/Vehicles/Camera Controller")
	if cc and "current_vehicle" in cc:
		return cc.current_vehicle
	return null

# ── Характеристики справа + деньги (реальные данные) ──────────────────────────
var _prog_label: Label = null   # «Гр.N · XP x/y · ДИ z» в шапке (создаётся в _ready)

# XP/ДИ/исследования изменились: шапка + открытые SHOP/ДРЕВО перестроить.
func _on_progress_changed() -> void:
	_update_currency()
	if not visible:
		return
	if _tab == TAB_SHOP:
		_rebuild_grid(_search.text if _search else "")
	elif _tab == TAB_TECH:
		_build_tech_tab()

# ТОЛЬКО деньги (тикают пассивно от продавца): шапка + кнопки покупки SHOP.
# Древо от денег не зависит — пересборка на каждый тик роняла бы тап по ноде
# (кнопка освобождается под пальцем).
func _on_money_changed() -> void:
	_update_currency()
	if visible and _tab == TAB_SHOP:
		_rebuild_grid(_search.text if _search else "")

func _update_currency() -> void:
	if has_node("%Currency"):
		%Currency.text = str(G.money)
	if _prog_label:
		var fac: String = _tech_faction if G.faction_open(_tech_faction) else "start"
		var gr: int = G.grade(fac)
		var xp: int = int(G.faction_xp.get(fac, 0))
		var th: Array = (G.FACTIONS[fac] as Dictionary)["xp_thresholds"]
		var txt := tr("Gr.%d") % gr
		if G.open_factions().filter(G.faction_has_blocks).size() > 1:
			txt = tr(String((G.FACTIONS[fac] as Dictionary)["name"])) + " " + txt
		if gr < th.size():
			txt += " · %d/%d XP" % [xp, int(th[gr])]   # порог СЛЕДУЮЩЕГО грейда
		else:
			txt += " · " + tr("max")
		txt += " · RP %d" % G.research_points
		_prog_label.text = txt

func _refresh_stats() -> void:
	var v: Node = _get_vehicle()
	if v == null:
		return
	set_vehicle_name(str(v.name))
	if v is MachineBody:
		var m: MachineBody = v as MachineBody
		m.refresh_mass()                        # в гараже физпроцесс машины не крутится
		set_load(m)
		_fill_stats(m)

## Машина изменилась — блок поставили или сняли. Зовёт HUD (см. notify_build_changed).
## Раньше вес и характеристики считались только при ЗАХОДЕ в гараж, а стройка теперь идёт
## внутри него: панель справа висела бы со старыми числами всю сборку.
func notify_build_changed() -> void:
	if not visible:
		return
	_refresh_stats()
	# Блок ушёл из запаса в машину (или вернулся) — счётчики в инвентаре тоже устарели.
	if _tab == TAB_INVENTORY:
		_load_items()
		_rebuild_grid(_search.text if _search else "")

# ── Публичный API характеристик справа ────────────────────────────────────────
func set_vehicle_name(n: String) -> void:
	if has_node("%VehicleName"):
		%VehicleName.text = n

# ── Характеристики машины ─────────────────────────────────────────────────────
# Строки собираются кодом, а не лежат в сцене. Панель рисовалась по скриншоту игры, и
# часть чисел так и осталась картинкой из него. Строка, рождённая из данных, застыть
# не может — ей просто неоткуда взять «нарисованное» значение.
# MASS сюда не берём — он уже левое число в LOAD. Вместо него разгон: он меняется
# от каждого навешенного блока и от каждого колеса, то есть показывает то же, что
# и цвет LOAD, но числом.
const STAT_ROWS: Array[String] = ["ACCEL", "THRUST", "TOP SPEED", "FIREPOWER", "ARMOUR", "WHEELS"]
const STAT_NAME_COLOR: Color = Color(0.58, 0.63, 0.72)
const STAT_VALUE_COLOR: Color = Color(0.93, 0.95, 1.0)

var _stat_values: Dictionary = {}

func _build_stats_panel() -> void:
	var right: Node = get_node_or_null("Root/Main/RightPanel/RightVB")
	if right == null:
		return
	var weight_row: Node = right.get_node_or_null("WeightRow")
	if weight_row != null:
		(weight_row as Control).visible = false     # масса переехала в сетку, дубль убираем

	# Оформляем как соседнюю панель LOAD, а не голой сеткой: стиль берём с неё же, чтобы
	# блок не выглядел приклеенным и не разъехался, если тему панели поменяют.
	var panel := PanelContainer.new()
	panel.name = "StatsPanel"
	var reactor: Node = right.get_node_or_null("Reactor")
	if reactor != null:
		var style: StyleBox = (reactor as PanelContainer).get_theme_stylebox("panel")
		if style != null:
			panel.add_theme_stylebox_override("panel", style)
	right.add_child(panel)

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 8)
	panel.add_child(column)

	var heading := Label.new()
	heading.text = tr("SPECS")
	heading.add_theme_color_override("font_color", STAT_NAME_COLOR)
	heading.add_theme_font_size_override("font_size", 12)
	column.add_child(heading)

	var grid := GridContainer.new()
	grid.name = "StatsGrid"
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 14)
	grid.add_theme_constant_override("v_separation", 5)
	column.add_child(grid)

	for key in STAT_ROWS:
		var caption := Label.new()
		caption.text = tr(key)
		caption.add_theme_color_override("font_color", STAT_NAME_COLOR)
		caption.add_theme_font_size_override("font_size", 13)
		caption.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		grid.add_child(caption)

		var value := Label.new()
		value.text = "—"
		value.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		value.add_theme_color_override("font_color", STAT_VALUE_COLOR)
		value.add_theme_font_size_override("font_size", 15)
		grid.add_child(value)
		_stat_values[key] = value

func _set_stat(key: String, text: String, tint: Color = STAT_VALUE_COLOR) -> void:
	var lbl: Label = _stat_values.get(key)
	if lbl != null:
		lbl.text = text
		lbl.add_theme_color_override("font_color", tint)

func _fill_stats(m: MachineBody) -> void:
	var hp: Vector2i = m.hp_totals()
	var wheels: Vector2i = m.wheel_counts()
	var health: float = m.health_ratio()
	var accel: float = m.rated_power() / maxf(m.mass, 0.001)
	_set_stat("ACCEL", "%.1f m/s²" % accel,
		LOAD_OK if accel >= MachineBody.ACCEL_BRISK
		else (LOAD_WARN if accel >= MachineBody.ACCEL_CRAWL else LOAD_BAD))
	_set_stat("THRUST", tr("%d N") % int(round(m.rated_power())))
	_set_stat("TOP SPEED", tr("%d km/h") % int(round(m.max_speed * 3.6)))
	_set_stat("FIREPOWER", tr("%d dps") % int(round(m.firepower())))
	# Броня красится по остатку — сразу видно побитую машину, без чтения цифр.
	_set_stat("ARMOUR", "%d / %d" % [hp.x, hp.y],
		LOAD_OK if health > 0.66 else (LOAD_WARN if health > 0.33 else LOAD_BAD))
	# Ведущие показываем отдельно: именно они дают тягу, остальные только катятся.
	_set_stat("WHEELS", tr("%d / %d driven") % [wheels.y, wheels.x],
		STAT_VALUE_COLOR if wheels.y > 0 else LOAD_BAD)

const LOAD_OK: Color = Color(0.35, 0.85, 0.42)     # тянет легко
const LOAD_WARN: Color = Color(1.0, 0.78, 0.22)    # тянет, но с трудом
const LOAD_BAD: Color = Color(0.95, 0.32, 0.28)    # не поедет

# Панель показывает не число блоков, а способность машины себя ВЕЗТИ: её масса против того,
# сколько держат её колёса (сумма load_capacity). Предел не константа и не выводится из тяги —
# это паспортная грузоподъёмность ходовой, та же, из которой считается жёсткость пружины
# (MachineBody._apply_suspension). Поэтому вердикт сбывается буквально: перевалил за предел —
# подвеска легла, кузов сел на собственные коллайдеры и машина чертит по земле.
#
# Раньше предел считался как тяга/ускорение, и порог «не поедет» стоял там, где машина ещё
# разгонялась быстрее, чем панель называла бодрым: вердикт не мог сбыться в принципе.
func set_load(m: MachineBody) -> void:
	var mass_now: float = m.mass
	var comfort: float = m.mass_comfort()
	var limit: float = m.mass_limit()

	var col: Color = LOAD_OK
	var verdict: String = tr("MOVES WELL")
	if limit < 1.0:
		col = LOAD_BAD
		verdict = tr("NO WHEELS")                  # нечему держать: нужны колёса, достающие до земли
	elif mass_now > limit:
		col = LOAD_BAD
		verdict = tr("TOO HEAVY")
	elif mass_now > comfort:
		col = LOAD_WARN
		verdict = tr("STRAINED")

	if has_node("%ReactorLabel"):
		%ReactorLabel.text = tr("LOAD") + "  ·  " + verdict
	if has_node("%ReactorValue"):
		%ReactorValue.text = tr("%d / %d kg") % [int(round(mass_now)), int(round(limit))]
		%ReactorValue.add_theme_color_override("font_color", col)
	if has_node("%ReactorBar"):
		%ReactorBar.max_value = maxf(limit, 1.0)
		%ReactorBar.value = clampf(mass_now, 0.0, maxf(limit, 1.0))
		var fill := StyleBoxFlat.new()
		fill.bg_color = col
		fill.set_corner_radius_all(3)
		%ReactorBar.add_theme_stylebox_override("fill", fill)

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
	# Подписка на смену трека живёт в самой панели (music_panel.gd) — она обновляет свои строки
	# и не требует от вкладки помнить, что их надо перерисовать.

func _music() -> Node:
	return get_node_or_null("/root/Music")

func _clear_extra() -> void:
	_clear_children(_extra_vb)

# Убираем детей ИЗ ДЕРЕВА сразу, а не одним queue_free: тот удаляет в конце кадра, и вторая
# пересборка за тот же кадр видела бы старое содержимое и дописывала к нему новое.
# Сетке слотов это больше не нужно (там пул), а вот панель МУЗЫКА/НАСТРОЙКИ строится так.
static func _clear_children(host: Node) -> void:
	if host == null:
		return
	for c in host.get_children():
		host.remove_child(c)
		c.queue_free()

func _extra_header(text: String) -> void:
	var lbl := Label.new()
	lbl.text = text
	lbl.add_theme_font_size_override("font_size", 14)
	lbl.add_theme_color_override("font_color", Color(0.55, 0.75, 0.8, 0.9))
	_extra_vb.add_child(lbl)

# ── Вкладка МУЗЫКА ─────────────────────────────────────────────────────────────
# Панель — общая с главным меню (music_panel.gd). Здесь она показывает ДВА списка, которые
# играет мир; меню показывает свой. Вторая раскладка строк рядом с этой разъехалась бы в тот
# день, когда в одну из них добавят кнопку.
func _build_music_tab() -> void:
	if _extra_vb == null:
		return
	_clear_extra()
	var m := _music()
	if m == null:
		_extra_header(tr("Music system not connected"))
		return
	var panel := MusicPanel.new()
	panel.contexts = [m.Ctx.TRAVEL, m.Ctx.BATTLE]   # before it enters the tree: one build, not two
	_extra_vb.add_child(panel)

# ── Вкладка НАСТРОЙКИ ──────────────────────────────────────────────────────────
# Авто-FPS (система в Main.gd: держит целевой FPS, меняя масштаб рендера). Авто
# выключено → полоска ручного выбора масштаба.
func _on_soft_shadows(on: bool) -> void:
	var mn: Node = get_node_or_null("/root/Main")
	if mn and mn.has_method("set_shadows_soft"):
		mn.set_shadows_soft(on)

func _on_full_shadows(on: bool) -> void:
	var mn: Node = get_node_or_null("/root/Main")
	if mn and mn.has_method("set_shadows_engine"):
		mn.set_shadows_engine(on)

func _on_hlod(on: bool) -> void:
	var mn: Node = get_node_or_null("/root/Main")
	if mn and mn.has_method("set_hlod"):
		mn.set_hlod(on)

func _on_view_distance(v: float, lbl: Label) -> void:
	lbl.text = tr("Draw distance: %d m") % int(v)
	var mn: Node = get_node_or_null("/root/Main")
	if mn and mn.has_method("set_view_distance"):
		mn.set_view_distance(v)

func _build_settings_tab() -> void:
	if _extra_vb == null:
		return
	_clear_extra()
	var main: Node = get_node_or_null("/root/Main")
	_extra_header("— GRAPHICS —")
	if main == null or not ("auto_fps" in main):
		_extra_header(tr("Main with auto-FPS not found"))
		return
	var auto_btn := CheckButton.new()
	auto_btn.text = tr("Auto FPS (render scale adjusts itself)")
	auto_btn.button_pressed = bool(main.auto_fps)
	auto_btn.add_theme_font_size_override("font_size", 14)
	_extra_vb.add_child(auto_btn)

	var scale_row := HBoxContainer.new()
	scale_row.visible = not bool(main.auto_fps)
	_extra_vb.add_child(scale_row)
	var scale_lbl := Label.new()
	scale_lbl.text = tr("Scale: %d%%") % int(round(float(main.manual_scale) * 100.0))
	scale_lbl.custom_minimum_size = Vector2(130, 0)
	scale_lbl.add_theme_font_size_override("font_size", 13)
	scale_row.add_child(scale_lbl)
	var scale_sl := HSlider.new()
	scale_sl.min_value = 0.25
	scale_sl.max_value = 2.0
	scale_sl.step = 0.05
	scale_sl.value = float(main.manual_scale)
	scale_sl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scale_sl.value_changed.connect(func(v: float) -> void:
		scale_lbl.text = tr("Scale: %d%%") % int(round(v * 100.0))
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
	hint.text = tr("Auto mode holds ~30 FPS and sets the scale itself. Turn it off to set the scale by hand: on a phone a lower scale gives the most frames.")
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.add_theme_font_size_override("font_size", 12)
	hint.modulate = Color(1, 1, 1, 0.55)
	_extra_vb.add_child(hint)

	if "shadows_enabled" in main:
		var shadow_btn := CheckButton.new()
		shadow_btn.text = tr("Shadows")
		shadow_btn.button_pressed = bool(main.shadows_enabled)
		shadow_btn.add_theme_font_size_override("font_size", 14)
		_extra_vb.add_child(shadow_btn)
		shadow_btn.toggled.connect(func(on: bool) -> void:
			var mn: Node = get_node_or_null("/root/Main")
			if mn and mn.has_method("set_shadows_enabled"):
				mn.set_shadows_enabled(on))

		var full_btn := CheckButton.new()
		full_btn.text = tr("Full shadows (slow)")
		full_btn.button_pressed = bool(main.get("shadows_engine") == true)
		full_btn.add_theme_font_size_override("font_size", 14)
		_extra_vb.add_child(full_btn)
		full_btn.toggled.connect(_on_full_shadows)

		var shadow_hint := Label.new()
		shadow_hint.text = tr("Shadows are fast: machines and trees on the ground. Full shadows also shade hills and cost about half the frame on a phone.")
		shadow_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		shadow_hint.add_theme_font_size_override("font_size", 12)
		shadow_hint.modulate = Color(1, 1, 1, 0.55)
		_extra_vb.add_child(shadow_hint)

	if "view_distance" in main:
		var vd_row := HBoxContainer.new()
		_extra_vb.add_child(vd_row)
		var vd_lbl := Label.new()
		vd_lbl.text = tr("Draw distance: %d m") % int(main.view_distance)
		vd_lbl.custom_minimum_size = Vector2(170, 0)
		vd_lbl.add_theme_font_size_override("font_size", 13)
		vd_row.add_child(vd_lbl)
		var vd_sl := HSlider.new()
		vd_sl.min_value = float(main.VIEW_MIN)
		vd_sl.max_value = float(main.VIEW_MAX)
		vd_sl.step = 100.0
		vd_sl.value = float(main.view_distance)
		vd_sl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		vd_sl.value_changed.connect(_on_view_distance.bind(vd_lbl))
		vd_row.add_child(vd_sl)
		var vd_hint := Label.new()
		vd_hint.text = tr("How far the ground is drawn. Far costs frames and memory.")
		vd_hint.add_theme_font_size_override("font_size", 12)
		vd_hint.modulate = Color(1, 1, 1, 0.55)
		_extra_vb.add_child(vd_hint)
		if "hlod_on" in main:
			var hl_btn := CheckButton.new()
			hl_btn.text = tr("Merge far ground")
			hl_btn.button_pressed = bool(main.hlod_on)
			hl_btn.add_theme_font_size_override("font_size", 14)
			_extra_vb.add_child(hl_btn)
			hl_btn.toggled.connect(_on_hlod)
			var hl_hint := Label.new()
			hl_hint.text = tr("Fewer draw calls for distant ground. Turn off to compare FPS.")
			hl_hint.add_theme_font_size_override("font_size", 12)
			hl_hint.modulate = Color(1, 1, 1, 0.55)
			_extra_vb.add_child(hl_hint)

	# Полноэкранный ↔ плавающее окно (только ПК; окно тянется мышью, UI подстраивается сам).
	if OS.has_feature("pc") and "fullscreen" in main:
		var fs_btn := CheckButton.new()
		fs_btn.text = tr("Fullscreen mode (off — floating window)")
		fs_btn.button_pressed = bool(main.fullscreen)
		fs_btn.add_theme_font_size_override("font_size", 14)
		fs_btn.toggled.connect(func(on: bool) -> void:
			var mn: Node = get_node_or_null("/root/Main")
			if mn and mn.has_method("set_fullscreen"):
				mn.set_fullscreen(on))
		_extra_vb.add_child(fs_btn)

	if "ui_scale" in main:
		_extra_header("— INTERFACE —")
		var ui_row := HBoxContainer.new()
		_extra_vb.add_child(ui_row)
		var ui_lbl := Label.new()
		ui_lbl.text = tr("Size: %d%%") % int(round(float(main.ui_scale) * 100.0))
		ui_lbl.custom_minimum_size = Vector2(130, 0)
		ui_lbl.add_theme_font_size_override("font_size", 13)
		ui_row.add_child(ui_lbl)
		var ui_sl := HSlider.new()
		ui_sl.min_value = 0.7      # = Main.UI_SCALE_MIN (set_ui_scale всё равно клампит)
		ui_sl.max_value = 1.4      # = Main.UI_SCALE_MAX
		ui_sl.step = 0.05
		ui_sl.value = float(main.ui_scale)
		ui_sl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		ui_sl.value_changed.connect(func(v: float) -> void:
			ui_lbl.text = tr("Size: %d%%") % int(round(v * 100.0))
			var mn: Node = get_node_or_null("/root/Main")
			if mn and mn.has_method("set_ui_scale"):
				mn.set_ui_scale(v))
		ui_row.add_child(ui_sl)

		var ui_hint := Label.new()
		ui_hint.text = tr("Size of buttons/panels. The base already adapts to the screen on its own.")
		ui_hint.add_theme_font_size_override("font_size", 12)
		ui_hint.modulate = Color(1, 1, 1, 0.55)
		_extra_vb.add_child(ui_hint)

	# THE PLAYER'S OWN LAYOUT: the garage closes and a frame lies over every control a thumb
	# reaches (hud.start_layout_edit); DONE keeps the places, RESET puts them back.
	var move_btn := Button.new()
	move_btn.text = tr("Move controls")
	move_btn.add_theme_font_size_override("font_size", 14)
	move_btn.pressed.connect(_on_move_controls)
	_extra_vb.add_child(move_btn)
	var move_hint := Label.new()
	move_hint.text = tr("Put Attack, Build, the map and the rest where your thumbs reach them.")
	move_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	move_hint.add_theme_font_size_override("font_size", 12)
	move_hint.modulate = Color(1, 1, 1, 0.55)
	_extra_vb.add_child(move_hint)
	var fps_btn := CheckButton.new()
	fps_btn.text = tr("Show FPS")
	fps_btn.button_pressed = G.show_fps
	fps_btn.add_theme_font_size_override("font_size", 14)
	fps_btn.toggled.connect(_on_show_fps)
	_extra_vb.add_child(fps_btn)
	var fps_hint := Label.new()
	fps_hint.text = tr("A small counter in the bottom-right corner, in the game and in the garage.")
	fps_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	fps_hint.add_theme_font_size_override("font_size", 12)
	fps_hint.modulate = Color(1, 1, 1, 0.55)
	_extra_vb.add_child(fps_hint)

	# — СТРОЙКА — вкус, а не правило: одному подобранный блок нужен сразу в руке и на машине,
	# другой подбирает мусор по дороге и не хочет каждый раз выпадать из езды.
	_extra_header("— BUILDING —")
	var pick := CheckButton.new()
	pick.text = tr("Picking up a block opens assembly")
	pick.button_pressed = G.build_on_pickup
	pick.add_theme_font_size_override("font_size", 14)
	pick.toggled.connect(func(on: bool) -> void: G.build_on_pickup = on; G.save_settings())
	_extra_vb.add_child(pick)
	var pick_hint := Label.new()
	pick_hint.text = tr("Off — the block stays in hand, assembly opens by its button.")
	pick_hint.add_theme_font_size_override("font_size", 12)
	pick_hint.modulate = Color(1, 1, 1, 0.55)
	_extra_vb.add_child(pick_hint)

	# — КАМЕРА — (перенесено из HUD: управление камерой настраивается здесь, в гараже)
	_extra_header("— CAMERA —")
	_extra_vb.add_child(_cam_slider(tr("Rotation sensitivity"), G.cam_look_sens,
			func(v): G.cam_look_sens = v; G.save_settings()))
	_extra_vb.add_child(_cam_slider(tr("Zoom sensitivity"), G.cam_zoom_sens,
			func(v): G.cam_zoom_sens = v; G.save_settings()))
	var inv := CheckButton.new()
	inv.text = tr("Invert vertical")
	inv.button_pressed = G.cam_invert_y
	inv.add_theme_font_size_override("font_size", 14)
	inv.toggled.connect(func(on: bool) -> void: G.cam_invert_y = on; G.save_settings())
	_extra_vb.add_child(inv)

	# — MACHINE — giving up the machine you are in: behind a question, like everything here that
	# cannot be undone (see the reset note below).
	_extra_header("— MACHINE —")
	var give_up := Button.new()
	give_up.text = tr("Surrender")
	give_up.add_theme_font_size_override("font_size", 14)
	give_up.pressed.connect(_ask_surrender)
	_extra_vb.add_child(give_up)
	var give_hint := Label.new()
	give_hint.text = tr("Blows up this machine's cabin: its blocks fall where it stands, and you start again in a new cabin.")
	give_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	give_hint.add_theme_font_size_override("font_size", 12)
	give_hint.modulate = Color(1, 1, 1, 0.55)
	_extra_vb.add_child(give_hint)

	# СБРОСА ЗДЕСЬ НЕТ. Он переехал в меню, к слотам, и это его место: там видно, ЧТО именно
	# сбрасывается (мир отдельно, прохождение отдельно), а удаление требует удержания. Кнопка «в
	# один тап, необратимо» посреди игровых настроек — это только способ потерять мир случайно.
	#
	# ВЫХОД В МЕНЮ — единственный способ сменить слот, не перезапуская приложение. Без него
	# три мира есть, а попасть из одного в другой нельзя.
	var menu_btn := Button.new()
	menu_btn.text = tr("Main menu (switch world)")
	menu_btn.add_theme_font_size_override("font_size", 14)
	menu_btn.pressed.connect(_to_main_menu)
	_extra_vb.add_child(menu_btn)

func _on_show_fps(on: bool) -> void:
	G.show_fps = on
	G.save_settings()
	for n in get_tree().get_nodes_in_group("fps_counter"):
		(n as CanvasItem).visible = on

func _on_move_controls() -> void:
	var hud: Node = get_parent()
	if hud == null or not hud.has_method("start_layout_edit"):
		return
	hide()                          # the garage goes first: the controls come back with it closed
	hud.start_layout_edit()

var _surrender_dialog: ConfirmationDialog = null

func _ask_surrender() -> void:
	var v: Node = _get_vehicle()
	if v == null or not v.has_method("can_surrender") or not v.can_surrender():
		_say(tr("Only a machine with a cabin can surrender."))
		return
	if _surrender_dialog == null or not is_instance_valid(_surrender_dialog):
		_surrender_dialog = ConfirmationDialog.new()
		_surrender_dialog.title = tr("Surrender")
		_surrender_dialog.ok_button_text = tr("Surrender")
		_surrender_dialog.dialog_text = tr("Destroy this machine? Its blocks fall to the ground.")
		_surrender_dialog.confirmed.connect(_apply_surrender)
		add_child(_surrender_dialog)
	_surrender_dialog.popup_centered(Vector2i(380, 140))

## The garage goes first: the death screen and the wreck are what is left to see.
func _apply_surrender() -> void:
	var v: Node = _get_vehicle()
	if v == null or not v.has_method("surrender"):
		return
	hide()
	v.surrender()

## В МЕНЮ. Сначала СОХРАНЯЕМ мир: смена сцены освобождает world_persist, и без явного вызова
## всё, что игрок настроил после последнего автосейва, осталось бы в прошлом слоте.
func _to_main_menu() -> void:
	var wp: Node = get_tree().get_first_node_in_group("world_persist")
	if wp != null and wp.has_method("_save_world"):
		wp._save_world()                     # на полигоне сам откажется (world_persist)
	G.save_now()
	# ФЛАГ ПОЛИГОНА СНИМАЕТСЯ ЗДЕСЬ, В ЕДИНСТВЕННОЙ ДВЕРИ ОБРАТНО В МЕНЮ. Он живёт в автолоаде,
	# то есть переживает смену сцены, и забытый флаг означал бы следующую НАСТОЯЩУЮ игру на
	# ровной земле, с бесконечным складом и без сейва. Снимаем через G: там же сбрасывается
	# отложенная запись и перечитывается настоящий прогресс.
	G.leave_proving_ground()
	get_tree().change_scene_to_file("res://menu.tscn")

# Строка «подпись + ползунок + значение» для настроек камеры (0.2..3.0).
func _cam_slider(label: String, value: float, on_change: Callable) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	var l := Label.new()
	l.text = label
	l.custom_minimum_size = Vector2(190, 0)
	l.add_theme_font_size_override("font_size", 13)
	row.add_child(l)
	var s := HSlider.new()
	s.min_value = 0.2
	s.max_value = 3.0
	s.step = 0.05
	s.value = value
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var val := Label.new()
	val.text = "%.2f" % value
	val.custom_minimum_size = Vector2(44, 0)
	s.value_changed.connect(func(v: float) -> void:
		val.text = "%.2f" % v
		on_change.call(v))
	row.add_child(s)
	row.add_child(val)
	return row

# ══ Вкладка ДРЕВО: дерево технологий стартовой фракции (этап 2 прогрессии) ══════════
# Вертикальные ярусы по грейдам (мобайл: ряды-«полки», не радиалка); нода = кнопка с
# именем блока и статусом. 4 состояния: исследована / можно / не хватает ДИ / закрыта.
# Паттерн покупки: ПЕРВЫЙ тап — панель с деталями сверху, ВТОРОЙ (кнопка) — исследовать.
# Исследование сразу даёт +1 блок в инвентарь (G.research, без двойного гейта).

# ── Вкладка ДРЕВО: граф слева-направо с линиями связей, панорама в 2D ──────────────
# Раскладка деревом (RT-подобная): x = глубина по TECH_PARENT, y — листья по порядку,
# родитель по среднему детей. Граф внутри ScrollContainer по ОБЕИМ осям — тащишь пальцем
# вверх/вниз/влево/вправо (тач-драг), чтобы влезало. Сверху фикс. инфо-панель.
## УЗЕЛ ШИРЕ РАДИ ПОРТРЕТА. Имя детали в узле — это чтение, а картинка узнаётся без чтения, и
## на дереве из полусотни узлов разница между «искать глазами» и «увидеть» решающая. Сорок
## точек под портрет плюс прежнее место под текст: ширина выросла с 96 до 136, шаг колонок
## следом, чтобы зазор под линии связей остался тем же (42).
const TNODE_W := 136.0
const TNODE_H := 50.0
const TNODE_ICON := 40.0               # сторона портрета внутри узла
const TCOL_W := 178.0                  # шаг колонок (глубина): зазор под линии связей
const TROW_H := 64.0                   # шаг рядов
const TMARGIN := 18.0

# Холст графа: рисует линии связей родитель→ребёнок; ноды-кнопки — его дети.
class TechGraph extends Control:
	var edges: Array = []              # [{a: Vector2, b: Vector2, col: Color}]
	func _draw() -> void:
		for e in edges:
			draw_line(e["a"], e["b"], e["col"], 2.0, true)

var _tech_selected: int = -1           # выбранная нода (Block) для инфо-панели
var _tech_info: Label = null
var _tech_btn: Button = null
var _tech_root: VBoxContainer = null    # фикс. инфо-панель + прокручиваемый граф
var _tech_head: Label = null
var _tech_scroll: ScrollContainer = null
var _tech_graph: TechGraph = null       # холст графа (ноды + линии) внутри _tech_scroll
var _tech_leaf := 0.0                    # счётчик листьев при раскладке (см. _tech_assign)
## Whose page the tree shows. The switch above it lists only licensed factions and hides itself
## while there is one; the garage header shows the grade of the page that is open.
var _tech_faction := "start"
var _tech_fac_row: HBoxContainer = null

func _tech_fill_factions() -> void:
	for c in _tech_fac_row.get_children():
		c.queue_free()
	var open: Array = G.open_factions().filter(G.faction_has_blocks)
	_tech_fac_row.visible = open.size() > 1
	for f in open:
		var b := Button.new()
		b.text = tr(String((G.FACTIONS[f] as Dictionary)["name"]))
		b.toggle_mode = true
		b.button_pressed = f == _tech_faction
		b.custom_minimum_size = Vector2(0, 40)
		b.add_theme_font_size_override("font_size", 15)
		var em: Texture2D = G.faction_emblem(String(f))
		if em != null:
			b.icon = em
			b.expand_icon = true
			b.add_theme_constant_override("icon_max_width", 28)
		b.pressed.connect(_tech_pick_faction.bind(String(f)))
		_tech_fac_row.add_child(b)

func _tech_pick_faction(f: String) -> void:
	if f == _tech_faction:
		_tech_fill_factions()
		return
	_tech_faction = f
	_tech_selected = -1
	_update_currency()
	_build_tech_tab()

func _build_tech_tab() -> void:
	var body: Node = get_node_or_null("Root/Main/LeftPanel/LeftVB/Body")
	if body == null:
		return
	if _tech_root == null:
		_tech_build_shell(body)
	_tech_root.visible = true            # билдер зовётся только для активной вкладки ДРЕВО
	if not G.faction_open(_tech_faction):
		_tech_faction = "start"
	_tech_fill_factions()
	var total := 0
	var done := 0
	for bt in G.BLOCK_META:
		if String((G.BLOCK_META[bt] as Dictionary)["f"]) == _tech_faction:
			total += 1
			done += 1 if G.researched.has(int(bt)) else 0
	_tech_head.text = tr("Tech tree — researched %d/%d · RP: %d") % [done, total, G.research_points]
	_tech_update_info()

	# Раскладка позиций всех нод (px) деревом.
	var pos := _tech_layout(_tech_faction)
	# Холст нужного размера + перестройка нод/линий (сохраняя позицию прокрутки).
	var keep := Vector2(_tech_scroll.scroll_horizontal, _tech_scroll.scroll_vertical)
	var graph: TechGraph = _tech_graph
	for c in graph.get_children():
		c.queue_free()
	var maxx := 0.0
	var maxy := 0.0
	for bt in pos:
		maxx = maxf(maxx, (pos[bt] as Vector2).x)
		maxy = maxf(maxy, (pos[bt] as Vector2).y)
	graph.custom_minimum_size = Vector2(maxx + TNODE_W + TMARGIN, maxy + TNODE_H + TMARGIN)
	# Линии связей: правый-центр родителя → левый-центр ребёнка.
	var edges: Array = []
	for bt in G.TECH_PARENT:
		var par := int(G.TECH_PARENT[bt])
		if not (pos.has(bt) and pos.has(par)):
			continue
		var a: Vector2 = (pos[par] as Vector2) + Vector2(TNODE_W, TNODE_H * 0.5)
		var b: Vector2 = (pos[bt] as Vector2) + Vector2(0, TNODE_H * 0.5)
		var col := Color(0.45, 0.55, 0.62, 0.75) if G.researched.has(int(bt)) \
				else Color(0.4, 0.45, 0.5, 0.35)
		edges.append({"a": a, "b": b, "col": col})
	graph.edges = edges
	graph.queue_redraw()
	# Ноды.
	for bt in pos:
		graph.add_child(_make_tech_node(int(bt), pos[bt]))
	# Вернуть прокрутку после того, как контейнер пересчитает размеры.
	_tech_scroll.scroll_horizontal = int(keep.x)
	_tech_scroll.scroll_vertical = int(keep.y)

# Каркас вкладки (создаётся один раз): шапка сверху, ГРАФ НА ВСЮ ПЛОЩАДЬ, а карточка
# выбранного узла с кнопкой «Research» — ПОВЕРХ графа В ПРАВОМ НИЖНЕМ УГЛУ.
#
# Раньше карточка стояла строкой между шапкой и графом, и это было неудобно дважды: она
# съедала верх экрана, где как раз начинается дерево, а кнопка оказывалась у самого верха —
# то есть дальше всего от пальца, которым игрок только что тыкал в узел. Внизу справа она
# попадает под большой палец и не закрывает дерево, которое разрастается влево-вверх.
#
# Из-за оверлея между шапкой и графом появился слой-Control: контейнер разложил бы карточку
# в столбец, а нам нужно, чтобы она ЛЕЖАЛА НА графе по якорям.
const TECH_CARD_W := 330.0
const TECH_CARD_MARGIN := 12.0

func _tech_build_shell(body: Node) -> void:
	_tech_root = VBoxContainer.new()
	_tech_root.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_tech_root.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_tech_root.add_theme_constant_override("separation", 6)
	_tech_root.visible = false
	body.add_child(_tech_root)

	_tech_fac_row = HBoxContainer.new()
	_tech_fac_row.add_theme_constant_override("separation", 8)
	_tech_root.add_child(_tech_fac_row)

	_tech_head = Label.new()
	_tech_head.add_theme_font_size_override("font_size", 16)
	_tech_root.add_child(_tech_head)

	var area := Control.new()
	area.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	area.size_flags_vertical = Control.SIZE_EXPAND_FILL
	area.clip_contents = true
	_tech_root.add_child(area)

	_tech_scroll = ScrollContainer.new()
	_tech_scroll.set_anchors_preset(Control.PRESET_FULL_RECT)
	_tech_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	_tech_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	area.add_child(_tech_scroll)
	_tech_graph = TechGraph.new()
	_tech_graph.mouse_filter = Control.MOUSE_FILTER_PASS   # тач-драг скролла проходит сквозь холст
	_tech_scroll.add_child(_tech_graph)

	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", _tech_card_style())
	# Правый нижний угол: растём вверх и влево от него, поэтому размер задаём отрицательными
	# отступами, а не size — иначе карточка уедет за край, когда текст станет длиннее.
	panel.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT, true)
	panel.offset_right = -TECH_CARD_MARGIN
	panel.offset_bottom = -TECH_CARD_MARGIN
	panel.offset_left = -TECH_CARD_W - TECH_CARD_MARGIN
	panel.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	panel.grow_vertical = Control.GROW_DIRECTION_BEGIN
	area.add_child(panel)

	var pv := VBoxContainer.new()
	pv.add_theme_constant_override("separation", 8)
	panel.add_child(pv)
	_tech_info = Label.new()
	_tech_info.add_theme_font_size_override("font_size", 13)
	_tech_info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_tech_info.custom_minimum_size = Vector2(TECH_CARD_W - 24.0, 0)
	pv.add_child(_tech_info)
	_tech_btn = Button.new()
	_tech_btn.custom_minimum_size = Vector2(0, 46)
	_tech_btn.add_theme_font_size_override("font_size", 16)
	_tech_btn.pressed.connect(_tech_do_research)
	pv.add_child(_tech_btn)

## Стиль карточки: та же тёмно-бирюзовая палитра, что у остального интерфейса (hud.gd).
func _tech_card_style() -> StyleBoxFlat:
	var st := StyleBoxFlat.new()
	st.bg_color = Color(0.05, 0.13, 0.16, 0.95)
	st.border_color = Color(0.25, 0.65, 0.7, 0.8)
	st.set_border_width_all(2)
	st.set_corner_radius_all(10)
	st.content_margin_left = 12
	st.content_margin_right = 12
	st.content_margin_top = 10
	st.content_margin_bottom = 10
	st.shadow_color = Color(0, 0, 0, 0.45)
	st.shadow_size = 8
	return st

## Стиль узла дерева. Цвет говорит СОСТОЯНИЕ: изучено — зелёный контур, доступно — бирюзовый,
## не хватает ДИ — янтарный, закрыто — блёклое. Раньше это делалось modulate по всей кнопке,
## и «закрыто» выглядело просто полупрозрачной кнопкой без формы.
func _tech_node_style(state: int, selected: bool) -> StyleBoxFlat:
	var st := StyleBoxFlat.new()
	st.set_corner_radius_all(8)
	st.set_border_width_all(3 if selected else 2)
	match state:
		0:                                            # изучено
			st.bg_color = Color(0.07, 0.20, 0.15, 0.95)
			st.border_color = Color(0.35, 0.95, 0.6, 0.9)
		1:                                            # можно изучить прямо сейчас
			st.bg_color = Color(0.06, 0.16, 0.20, 0.95)
			st.border_color = Color(0.3, 0.8, 0.9, 0.9)
		2:                                            # не хватает ДИ
			st.bg_color = Color(0.16, 0.13, 0.05, 0.95)
			st.border_color = Color(0.95, 0.8, 0.35, 0.8)
		_:                                            # закрыто требованием
			st.bg_color = Color(0.07, 0.09, 0.10, 0.9)
			st.border_color = Color(0.35, 0.4, 0.45, 0.5)
	if selected:
		st.border_color = Color(1.0, 0.85, 0.35, 1.0)
	st.content_margin_left = 6
	st.content_margin_right = 6
	return st

# Позиции всех нод дерева (px). x = глубина·TCOL_W; y = ряд·TROW_H (лист по счётчику,
# родитель — среднее детей: классическая аккуратная раскладка дерева).
## ONE TREE PER FACTION, each from its own root (a block with no parent): `f` picks the faction's
## page, "" stacks every faction's tree one under the other (the codex). It used to keep "the last
## block without a parent" as THE root, which held only while there was one faction - a second
## root silently replaced the whole Falsus tree.
func _tech_layout(f: String = "") -> Dictionary:
	var children: Dictionary = {}
	var roots: Array = []
	for bt in G.BLOCK_META:
		var fac: String = String((G.BLOCK_META[bt] as Dictionary)["f"])
		if f != "" and fac != f:
			continue
		if G.TECH_PARENT.has(bt):
			var par := int(G.TECH_PARENT[bt])
			if not children.has(par):
				children[par] = []
			(children[par] as Array).append(int(bt))
		else:
			roots.append(int(bt))
	for par in children:
		(children[par] as Array).sort()    # стабильный порядок детей
	# Faction order first (the FACTIONS table), then the block's own number.
	var forder: Array = G.FACTIONS.keys()
	roots.sort_custom(func(a, b): return _root_rank(a, forder) < _root_rank(b, forder))
	var rows: Dictionary = {}
	_tech_leaf = 0.0
	for root in roots:
		if _tech_leaf > 0.0:
			_tech_leaf += 1.0              # a blank row between two trees
		_tech_assign(int(root), children, rows)
	var pos: Dictionary = {}
	for bt in rows:
		pos[bt] = Vector2(TMARGIN + _tech_depth(int(bt)) * TCOL_W,
				TMARGIN + float(rows[bt]) * TROW_H)
	return pos

func _root_rank(bt: int, forder: Array) -> int:
	return forder.find(String((G.BLOCK_META[bt] as Dictionary)["f"])) * 1000 + bt

func _tech_assign(bt: int, children: Dictionary, rows: Dictionary) -> void:
	var kids: Array = children.get(bt, [])
	if kids.is_empty():
		rows[bt] = _tech_leaf
		_tech_leaf += 1.0
		return
	var s := 0.0
	for k in kids:
		_tech_assign(int(k), children, rows)
		s += float(rows[int(k)])
	rows[bt] = s / float(kids.size())

func _tech_depth(bt: int) -> int:
	var d := 0
	var cur := bt
	while G.TECH_PARENT.has(cur):
		cur = int(G.TECH_PARENT[cur])
		d += 1
	return d

func _make_tech_node(bt: int, at: Vector2) -> Control:
	var btn := Button.new()
	btn.position = at
	btn.size = Vector2(TNODE_W, TNODE_H)
	btn.clip_text = true
	btn.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	btn.add_theme_font_size_override("font_size", 12)
	var meta: Dictionary = G.BLOCK_META[bt]
	# Статусы ТЕКСТОМ: юникод-значки шрифт проекта не рендерит (прецедент ♥/✖).
	var status := ""
	var state := 3
	if G.researched.has(bt):
		status = tr("researched")
		state = 0
	else:
		var why: String = G.research_lock_reason(bt)
		if why == "":
			status = tr("%d RP") % int(meta["rp"])
			state = 1
		elif G.research_lock_code(bt) == "rp":
			status = tr("%d RP (short)") % int(meta["rp"])
			state = 2
		else:
			status = tr("locked")
	btn.text = "%s\n%s" % [_block_name(bt), status]
	var sel: bool = bt == _tech_selected
	var st := _tech_node_style(state, sel)
	var pressed_st := _tech_node_style(state, true)
	# Отступ ставим ОБЕИМ рамкам: у нажатой он свой, и без этого текст прыгал бы под пальцем.
	if _node_icon(btn, bt):
		st.content_margin_left = 6 + TNODE_ICON + 6
		pressed_st.content_margin_left = st.content_margin_left
	btn.add_theme_stylebox_override("normal", st)
	btn.add_theme_stylebox_override("hover", st)
	btn.add_theme_stylebox_override("focus", st)
	btn.add_theme_stylebox_override("pressed", pressed_st)
	if state == 3:
		btn.add_theme_color_override("font_color", Color(0.75, 0.8, 0.85, 0.6))
	# ДВОЙНОЙ ТАП ПО УЗЛУ = ИЗУЧИТЬ СРАЗУ. Считаем время сами, а не полагаемся на
	# double_click у события: на планшете сюда приходит эмулированная из тача мышь, и ловить
	# её флаг — значит зависеть от настройки эмуляции. Первый тап при этом работает как
	# работал (выбор + карточка), поэтому случайно ничего не изучится: нужен именно второй.
	btn.pressed.connect(func() -> void:
		var now: int = Time.get_ticks_msec()
		var quick: bool = bt == _tech_last_bt and now - _tech_last_ms <= TECH_DOUBLE_MS
		_tech_last_bt = bt
		_tech_last_ms = now
		_tech_selected = bt
		_tech_update_info()
		if quick:
			_tech_do_research())
	return btn

const TECH_DOUBLE_MS := 400
var _tech_last_bt: int = -1
var _tech_last_ms: int = 0

# Текст инфо-панели и состояние кнопки «Исследовать» по выбранной ноде.
func _tech_update_info() -> void:
	if _tech_info == null or _tech_btn == null:
		return
	if _tech_selected < 0 or not G.BLOCK_META.has(_tech_selected):
		_tech_info.text = tr("Tap a block to see what it needs.\nTap it twice to research it right away.")
		_tech_btn.text = tr("Research")
		_tech_btn.disabled = true
		return
	var bt := _tech_selected
	var m: Dictionary = G.BLOCK_META[bt]
	var line := tr("%s — grade %d · cost %d RP") % [_block_name(bt), int(m["g"]), int(m["rp"])]
	var parent := int(G.TECH_PARENT.get(bt, -1))
	var why: String
	if parent >= 0:
		line += " · " + tr("requires: %s") % _block_name(parent)
	if not G.researched.has(bt):
		why= G.research_lock_reason(bt)
		if why != "":
			line += "\n" + why         # у изученной причины нет — кнопка и так скажет
	_tech_info.text = line
	if G.researched.has(bt):
		_tech_btn.text = tr("Researched")
		_tech_btn.disabled = true
	else:
		_tech_btn.text = tr("Research (%d RP)") % int(m["rp"])
		_tech_btn.disabled = why != ""

func _tech_do_research() -> void:
	if _tech_selected < 0:
		return
	var bt := _tech_selected
	if not G.research(bt):
		_tech_update_info()            # причина могла устареть — показать актуальную
		return
	_say(tr("Researched: %s! +1 block already in inventory.") % _block_name(bt))
	# G.research эмитит progress_changed → _on_progress_changed перестроит вкладку
	# (нода станет ✓, соседи откроются) — тут ничего пересобирать не нужно.

# ── SHOP, SECOND CUT: tiles, a category strip, a detail panel (the player's call) ────────────────
## The first restyle was still a list you bought from blind. The layout now follows what real
## crafting/shop screens do (Rust's crafting menu, TerraTech's block palette): a grid of BIG
## portraits, because the 3D block is the thing being sold; categories along the top; and a tap
## SELECTS, the buy happens in a fixed detail panel on the right with the numbers, a quantity and the
## crafting comparison - the right panel's machine stats step aside while the shop is open.
## All logic is the old one: the window is `_items` from `_load_items`, the filter `_shop_filter`,
## the buy `_buy` (called once per unit, so every gate is asked every time).
const SV_TILE := Vector2(128.0, 160.0)
const SV_PORTRAIT := 104.0
const SV_INK := Color(0.9, 0.9, 0.93)
const SV_DIM := Color(0.56, 0.57, 0.64)
const SV_BG := Color(0.07, 0.07, 0.085)
const SV_TILE_BG := Color(0.115, 0.113, 0.135)
## ONE accent, the amber of the block art's "pop" (ART_STYLE §1): selection, sale, the buy button.
const SV_ACCENT := Color(0.86, 0.58, 0.22)
const SV_TABS := [
	["all", "All"], ["blocks", "Blocks"], ["wheels", "Wheels"],
	["attack", "Attack"], ["factory", "Factory"], ["power", "Power"],
]

var _sv_root: VBoxContainer = null
var _sv_grid: HFlowContainer = null
var _sv_search: LineEdit = null
var _sv_time: Label = null
var _sv_gauge: DayBar = null
var _sv_count: Label = null
var _sv_tabs: Dictionary = {}
var _sv_tiles: Array = []
var _sv_heads: Array = []
var _sv_sel: int = -1
var _sv_qty: int = 1
var _sv_detail: VBoxContainer = null
var _sv_hidden_right: Array = []
var _sv_d: Dictionary = {}           # detail widgets by name
var _sv_num_font: FontVariation = null

func _sv_font() -> FontVariation:
	if _sv_num_font == null:
		_sv_num_font = FontVariation.new()
		_sv_num_font.base_font = ThemeDB.fallback_font
		_sv_num_font.variation_embolden = 0.9
		_sv_num_font.spacing_glyph = -1
	return _sv_num_font

func _sv_label(fs: int, col: Color, bold: bool = false) -> Label:
	var l := Label.new()
	l.add_theme_font_size_override("font_size", fs)
	l.add_theme_color_override("font_color", col)
	if bold:
		l.add_theme_font_override("font", _sv_font())
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l

func _sv_flat(bg: Color, edge: Color = Color(0, 0, 0, 0), bottom: int = 0) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.border_color = edge
	sb.border_width_bottom = bottom
	sb.anti_aliasing = false
	sb.content_margin_left = 10.0
	sb.content_margin_right = 10.0
	sb.content_margin_top = 4.0
	sb.content_margin_bottom = 4.0
	return sb

func _build_shop_v2() -> void:
	var vb: Node = get_node_or_null("Root/Main/LeftPanel/LeftVB")
	if vb == null:
		return
	_sv_root = VBoxContainer.new()
	_sv_root.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_sv_root.add_theme_constant_override("separation", 0)
	_sv_root.visible = false
	vb.add_child(_sv_root)
	# HEADER: categories on the left, the day on the right - one line, no box round it.
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 2)
	_sv_root.add_child(head)
	for t in SV_TABS:
		var b := SvTab.new()
		b.key = String(t[0])
		b.word = tr(String(t[1]))
		b.toggle_mode = true
		var tw: float = ThemeDB.fallback_font.get_string_size(b.word.to_upper(), HORIZONTAL_ALIGNMENT_LEFT, -1, 11).x
		b.custom_minimum_size = Vector2(maxf(64.0, tw + 22.0), 56)
		b.add_theme_font_size_override("font_size", 13)
		b.add_theme_color_override("font_color", SV_DIM)
		b.add_theme_color_override("font_hover_color", SV_INK)
		b.add_theme_color_override("font_pressed_color", SV_INK)
		b.add_theme_color_override("font_hover_pressed_color", SV_INK)
		for st in ["normal", "hover", "pressed", "hover_pressed", "focus"]:
			b.add_theme_stylebox_override(st, StyleBoxEmpty.new())
		b.pressed.connect(_sv_pick_tab.bind(b.key))
		head.add_child(b)
		_sv_tabs[b.key] = b
	var gap := Control.new()
	gap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(gap)
	var day := VBoxContainer.new()
	day.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	day.add_theme_constant_override("separation", 2)
	day.tooltip_text = tr("The shop restocks once a game day. Blocks researched today join at the next restock.")
	head.add_child(day)
	var dr := HBoxContainer.new()
	dr.alignment = BoxContainer.ALIGNMENT_END
	dr.add_theme_constant_override("separation", 8)
	dr.mouse_filter = Control.MOUSE_FILTER_IGNORE
	day.add_child(dr)
	var cap := _sv_label(11, SV_DIM)
	cap.text = tr("Restock in").to_upper()
	cap.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	dr.add_child(cap)
	_sv_time = _sv_label(22, SV_INK, true)
	dr.add_child(_sv_time)
	_sv_gauge = DayBar.new()
	_sv_gauge.custom_minimum_size = Vector2(150, 4)
	_sv_gauge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	day.add_child(_sv_gauge)
	var rule := ColorRect.new()
	rule.color = Color(0.2, 0.2, 0.24)
	rule.custom_minimum_size = Vector2(0, 1)
	rule.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_sv_root.add_child(rule)
	# THE GRID on a faint build grid: the same 1 m cell the blocks are made on.
	var back := SvBack.new()
	back.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_sv_root.add_child(back)
	var scroll := ScrollContainer.new()
	scroll.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	back.add_child(scroll)
	var pad := MarginContainer.new()
	pad.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for side in ["left", "right", "top", "bottom"]:
		pad.add_theme_constant_override("margin_" + side, 8)
	scroll.add_child(pad)
	_sv_grid = HFlowContainer.new()
	_sv_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_sv_grid.add_theme_constant_override("h_separation", 6)
	_sv_grid.add_theme_constant_override("v_separation", 6)
	pad.add_child(_sv_grid)
	_sv_grid.resized.connect(_sv_fit_heads)
	# FOOT: today's count and the search, secondary - small, at the bottom.
	var foot := HBoxContainer.new()
	foot.add_theme_constant_override("separation", 10)
	_sv_root.add_child(foot)
	_sv_count = _sv_label(12, SV_DIM)
	_sv_count.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_sv_count.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	foot.add_child(_sv_count)
	_sv_search = LineEdit.new()
	_sv_search.placeholder_text = tr("Search")
	_sv_search.custom_minimum_size = Vector2(220, 44)
	_sv_search.clear_button_enabled = true
	_sv_search.add_theme_stylebox_override("normal", _sv_flat(SV_BG, Color(0.22, 0.22, 0.26), 1))
	_sv_search.add_theme_stylebox_override("focus", _sv_flat(SV_BG, SV_ACCENT, 1))
	_sv_search.text_changed.connect(func(_t: String) -> void: _sv_rebuild())
	foot.add_child(_sv_search)
	_build_shop_detail()

func _build_shop_detail() -> void:
	var right: Node = get_node_or_null("Root/Main/RightPanel/RightVB")
	if right == null:
		return
	_sv_detail = VBoxContainer.new()
	_sv_detail.visible = false
	_sv_detail.add_theme_constant_override("separation", 8)
	right.add_child(_sv_detail)
	var well := PanelContainer.new()
	well.add_theme_stylebox_override("panel", _sv_flat(SV_BG, Color(0.2, 0.2, 0.24), 1))
	_sv_detail.add_child(well)
	var pic := TextureRect.new()
	pic.custom_minimum_size = Vector2(0, 190)
	pic.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	pic.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	well.add_child(pic)
	_sv_d["pic"] = pic
	var tag := _sv_label(11, SV_DIM)
	_sv_detail.add_child(tag)
	_sv_d["tag"] = tag
	var nm := _sv_label(24, SV_INK, true)
	nm.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_sv_detail.add_child(nm)
	_sv_d["name"] = nm
	var desc := _sv_label(13, Color(0.74, 0.75, 0.8))
	desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_sv_detail.add_child(desc)
	_sv_d["desc"] = desc
	var stats := _sv_label(12, SV_DIM)
	stats.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_sv_detail.add_child(stats)
	_sv_d["stats"] = stats
	var craft := _sv_label(12, SV_DIM)
	craft.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_sv_detail.add_child(craft)
	_sv_d["craft"] = craft
	var sep := ColorRect.new()
	sep.color = Color(0.2, 0.2, 0.24)
	sep.custom_minimum_size = Vector2(0, 1)
	_sv_detail.add_child(sep)
	var pr := HBoxContainer.new()
	pr.add_theme_constant_override("separation", 6)
	_sv_detail.add_child(pr)
	var coin := CoinIcon.new()
	coin.custom_minimum_size = Vector2(20, 20)
	coin.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	pr.add_child(coin)
	var price := _sv_label(26, SV_INK, true)
	pr.add_child(price)
	_sv_d["price"] = price
	var was := _sv_label(13, SV_DIM)
	was.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	pr.add_child(was)
	_sv_d["was"] = was
	var stock := _sv_label(13, SV_DIM)
	stock.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	stock.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	stock.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	pr.add_child(stock)
	_sv_d["stock"] = stock
	var qr := HBoxContainer.new()
	qr.add_theme_constant_override("separation", 0)
	_sv_detail.add_child(qr)
	var minus := Button.new()
	minus.text = "–"
	qr.add_child(minus)
	var qty := _sv_label(20, SV_INK, true)
	qty.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	qty.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	qty.custom_minimum_size = Vector2(64, 52)
	qr.add_child(qty)
	_sv_d["qty"] = qty
	var plus := Button.new()
	plus.text = "+"
	qr.add_child(plus)
	for b in [minus, plus]:
		(b as Button).custom_minimum_size = Vector2(52, 52)
		(b as Button).add_theme_font_size_override("font_size", 22)
		(b as Button).add_theme_stylebox_override("normal", _sv_flat(SV_TILE_BG, Color(0.24, 0.24, 0.29), 1))
		(b as Button).add_theme_stylebox_override("hover", _sv_flat(Color(0.15, 0.15, 0.18), Color(0.3, 0.3, 0.36), 1))
		(b as Button).add_theme_stylebox_override("pressed", _sv_flat(SV_BG, SV_ACCENT, 1))
		(b as Button).add_theme_stylebox_override("disabled", _sv_flat(SV_BG))
	minus.pressed.connect(_sv_step.bind(-1))
	plus.pressed.connect(_sv_step.bind(1))
	_sv_d["minus"] = minus
	_sv_d["plus"] = plus
	var total := _sv_label(13, SV_DIM)
	total.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	total.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	total.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	qr.add_child(total)
	_sv_d["total"] = total
	var buy := Button.new()
	buy.custom_minimum_size = Vector2(0, 60)
	buy.add_theme_font_override("font", _sv_font())
	buy.add_theme_font_size_override("font_size", 20)
	buy.add_theme_color_override("font_color", Color(0.08, 0.06, 0.03))
	buy.add_theme_color_override("font_hover_color", Color(0.08, 0.06, 0.03))
	buy.add_theme_color_override("font_pressed_color", Color(0.08, 0.06, 0.03))
	buy.add_theme_color_override("font_disabled_color", SV_DIM)
	buy.add_theme_stylebox_override("normal", _sv_flat(SV_ACCENT, SV_ACCENT.darkened(0.45), 3))
	buy.add_theme_stylebox_override("hover", _sv_flat(SV_ACCENT.lightened(0.1), SV_ACCENT.darkened(0.45), 3))
	buy.add_theme_stylebox_override("pressed", _sv_flat(SV_ACCENT.darkened(0.15), SV_ACCENT.darkened(0.45), 1))
	buy.add_theme_stylebox_override("disabled", _sv_flat(Color(0.13, 0.13, 0.15), Color(0.2, 0.2, 0.24), 1))
	buy.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	buy.pressed.connect(_sv_buy)
	_sv_detail.add_child(buy)
	_sv_d["buy"] = buy
	var why := _sv_label(12, POOR_COL)
	why.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_sv_detail.add_child(why)
	_sv_d["why"] = why
	var empty := _sv_label(14, SV_DIM)
	empty.text = tr("Tap a block to see it here.")
	empty.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_sv_detail.add_child(empty)
	_sv_d["empty"] = empty

## Shop open: the old list, its strip and the machine stats step aside; leaving puts them back.
func _shop_v2_show(on: bool) -> void:
	if _sv_root == null:
		return
	_sv_root.visible = on
	var body: Control = get_node_or_null("Root/Main/LeftPanel/LeftVB/Body") as Control
	if body != null:
		body.visible = not on
	var right: Node = get_node_or_null("Root/Main/RightPanel/RightVB")
	var rp: Control = get_node_or_null("Root/Main/RightPanel") as Control
	if on and _sv_hidden_right.is_empty() and right != null:
		for c in right.get_children():
			if c != _sv_detail and (c as Control).visible:
				(c as Control).visible = false
				_sv_hidden_right.append(c)
	elif not on:
		for c in _sv_hidden_right:
			if is_instance_valid(c):
				(c as Control).visible = true
		_sv_hidden_right.clear()
	if _sv_detail != null:
		_sv_detail.visible = on
	if rp != null:
		rp.size_flags_vertical = Control.SIZE_FILL if on else Control.SIZE_SHRINK_BEGIN
		rp.custom_minimum_size.x = 400.0 if on else 340.0
	if on:
		for k in _sv_tabs:
			(_sv_tabs[k] as Button).button_pressed = k == _shop_filter

func _sv_pick_tab(key: String) -> void:
	_set_shop_filter(key)
	for k in _sv_tabs:
		(_sv_tabs[k] as Button).button_pressed = k == key

func _sv_tile_at(i: int) -> SvTile:
	while _sv_tiles.size() <= i:
		var t := SvTile.new()
		t.custom_minimum_size = SV_TILE
		t.num_font = _sv_font()
		for st in ["normal", "hover", "pressed", "disabled", "focus", "hover_pressed"]:
			t.add_theme_stylebox_override(st, StyleBoxEmpty.new())
		t.pressed.connect(_sv_select.bind(t))
		_sv_tiles.append(t)
		_sv_grid.add_child(t)
	return _sv_tiles[i]

func _sv_head_at(i: int) -> SectionHead:
	while _sv_heads.size() <= i:
		var h := SectionHead.new()
		h.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_sv_heads.append(h)
		_sv_grid.add_child(h)
	return _sv_heads[i]

func _sv_rebuild() -> void:
	if _sv_grid == null:
		return
	var f: String = _sv_search.text.strip_edges().to_lower() if _sv_search else ""
	var seq: Array = []
	var n := 0
	var nh := 0
	var group := -1
	var sel_seen := false
	var row_w: float = maxf(_sv_grid.size.x, SV_TILE.x)
	for it in _items:
		if f != "" and not str(it["name"]).to_lower().contains(f):
			continue
		var g: int = _shop_group(it)
		if g != group:
			group = g
			var h: SectionHead = _sv_head_at(nh)
			_fill_head(h, g)
			h.col = SV_ACCENT if g == SHOP_SALE else (SV_INK if g == SHOP_TODAY else SV_DIM)
			h.custom_minimum_size = Vector2(row_w, HEAD_H)
			seq.append(h)
			nh += 1
		var t: SvTile = _sv_tile_at(n)
		var bt: int = int(it["type"])
		t.bt = bt
		t.title = str(it["name"])
		t.icon_tex = Icons.get_icon(bt)
		t.price = int(it["price"])
		t.was = int(it.get("was", t.price))
		t.left = int(it.get("left", -1))
		t.sale = G.shop_sale_pct(bt)
		var m: Dictionary = G.BLOCK_META.get(bt, {})
		t.grade = int(m.get("g", 1))
		t.locked = not G.is_block_shop_unlocked(bt)
		t.poor = G.money < t.price
		t.selected = bt == _sv_sel
		sel_seen = sel_seen or t.selected
		t.visible = true
		t.queue_redraw()
		seq.append(t)
		n += 1
	for i in range(n, _sv_tiles.size()):
		(_sv_tiles[i] as Control).visible = false
	for i in range(nh, _sv_heads.size()):
		(_sv_heads[i] as Control).visible = false
	for i in seq.size():
		if (seq[i] as Node).get_index() != i:
			_sv_grid.move_child(seq[i], i)
	if not sel_seen:
		_sv_sel = -1
	_update_shop_counts()
	if _sv_count != null and _shop_info != null:
		_sv_count.text = _shop_info.text if n > 0 else (tr("Nothing found") if not _items.is_empty() else tr("Shop empty"))
	_sv_fill_detail()

func _sv_fit_heads() -> void:
	for h in _sv_heads:
		(h as Control).custom_minimum_size.x = maxf(_sv_grid.size.x, SV_TILE.x)

func _sv_select(t: SvTile) -> void:
	if _sv_sel != t.bt:
		_sv_qty = 1
	_sv_sel = t.bt
	for o in _sv_tiles:
		(o as SvTile).selected = (o as SvTile).visible and (o as SvTile).bt == _sv_sel
		(o as SvTile).queue_redraw()
	_sv_fill_detail()

func _sv_item(bt: int) -> Dictionary:
	for it in _items:
		if int(it["type"]) == bt:
			return it
	return {}

## How many of the selected block one press can buy now: stock and money both bound it.
func _sv_max(it: Dictionary) -> int:
	var price: int = int(it["price"])
	var cap: int = 99 if int(it.get("left", -1)) < 0 else int(it["left"])
	if price > 0:
		cap = mini(cap, int(G.money / price))
	return cap

func _sv_step(d: int) -> void:
	var it: Dictionary = _sv_item(_sv_sel)
	if it.is_empty():
		return
	_sv_qty = clampi(_sv_qty + d, 1, maxi(_sv_max(it), 1))
	_sv_fill_detail()

func _sv_buy() -> void:
	var it: Dictionary = _sv_item(_sv_sel)
	if it.is_empty() or not G.is_block_shop_unlocked(_sv_sel):
		return
	var bt: int = _sv_sel
	var n: int = mini(_sv_qty, maxi(_sv_max(it), 0))
	for i in n:
		_buy(bt, G.shop_price_now(bt))     # each unit through the one door: money and stock asked again
	_sv_qty = 1

func _sv_fill_detail() -> void:
	if _sv_detail == null:
		return
	var it: Dictionary = _sv_item(_sv_sel)
	var has: bool = not it.is_empty()
	for k in ["pic", "tag", "name", "desc", "stats", "craft", "price", "was", "stock", "qty",
			"minus", "plus", "total", "buy", "why"]:
		(_sv_d[k] as Control).visible = has
	(_sv_d["pic"] as Control).get_parent().visible = has
	(_sv_d["empty"] as Control).visible = not has
	if not has:
		return
	var bt: int = _sv_sel
	var m: Dictionary = G.BLOCK_META.get(bt, {})
	var fac: String = String(m.get("f", "start"))
	var fname: String = tr(String((G.FACTIONS.get(fac, {"name": fac}) as Dictionary)["name"]))
	(_sv_d["pic"] as TextureRect).texture = Icons.get_icon(bt)
	(_sv_d["tag"] as Label).text = ("%s  ·  " % fname + tr("Grade %d") % int(m.get("g", 1))).to_upper()
	(_sv_d["name"] as Label).text = str(it["name"])
	(_sv_d["desc"] as Label).text = tr(String(G.BLOCK_DESC.get(bt, "")))
	(_sv_d["stats"] as Label).text = _codex_stats(bt)
	var price: int = int(it["price"])
	var mat: int = 0
	var rec: Dictionary = G.block_recipe(bt)
	for k in rec:
		mat += G.base_price(String(k)) * int(rec[k])
	var craft: Label = _sv_d["craft"]
	if mat > 0:
		craft.text = tr("Craft instead: materials %d (%s) - the shop asks %+d%%") % [mat,
				G.recipe_text(rec), int(round((float(price) / float(mat) - 1.0) * 100.0))]
	else:
		craft.text = ""
	(_sv_d["price"] as Label).text = str(price)
	var off: int = G.shop_sale_pct(bt)
	(_sv_d["was"] as Label).text = (tr("was %d") % int(it.get("was", price)) + "  −%d%%" % off) if off > 0 else ""
	(_sv_d["was"] as Label).add_theme_color_override("font_color", SV_ACCENT)
	var left: int = int(it.get("left", -1))
	(_sv_d["stock"] as Label).text = tr("%d left today") % left if left > 0 else tr("Always in stock")
	var locked: bool = not G.is_block_shop_unlocked(bt)
	var mx: int = _sv_max(it)
	_sv_qty = clampi(_sv_qty, 1, maxi(mx, 1))
	(_sv_d["qty"] as Label).text = str(_sv_qty)
	(_sv_d["minus"] as Button).disabled = locked or _sv_qty <= 1
	(_sv_d["plus"] as Button).disabled = locked or _sv_qty >= mx
	var cost: int = price * _sv_qty
	(_sv_d["total"] as Label).text = tr("Total %d") % cost
	(_sv_d["total"] as Label).add_theme_color_override("font_color", POOR_COL if G.money < cost else SV_DIM)
	var buy: Button = _sv_d["buy"]
	var why: Label = _sv_d["why"]
	buy.text = (tr("Buy") + ("  ×%d" % _sv_qty if _sv_qty > 1 else "")).to_upper()
	buy.disabled = locked or mx <= 0
	why.text = ""
	if locked:
		if not m.is_empty() and G.grade(fac) < int(m["g"]):
			why.text = tr("Requires license grade %d") % int(m["g"])
		else:
			why.text = tr("Research in the tech tree")
	elif G.money < price:
		why.text = tr("Not enough money: %d more") % (price - int(G.money))

## The restock clock in the shop's header; called with the old strip's numbers.
func _sv_update_clock(sec: int, frac: float, last: bool) -> void:
	if _sv_time == null:
		return
	_sv_time.text = "%d:%02d" % [sec / 60, sec % 60]
	_sv_time.add_theme_color_override("font_color", SV_ACCENT if last else SV_INK)
	_sv_gauge.frac = frac
	_sv_gauge.warm = last
	_sv_gauge.queue_redraw()

## A category tab: a drawn pictogram over a short word, an amber rule under the chosen one.
class SvTab extends Button:
	var key: String = ""
	var word: String = ""
	func _draw() -> void:
		var on: bool = button_pressed
		var col := Color(0.9, 0.9, 0.93) if on else Color(0.56, 0.57, 0.64)
		var c := Vector2(size.x * 0.5, 15.0)
		match key:
			"all":
				for i in 4:
					draw_rect(Rect2(c + Vector2(-8 + (i % 2) * 9, -8 + (i / 2) * 9), Vector2(7, 7)), col)
			"blocks":
				draw_colored_polygon(PackedVector2Array([c + Vector2(0, -9), c + Vector2(8, -5),
					c + Vector2(0, -1), c + Vector2(-8, -5)]), col)
				draw_colored_polygon(PackedVector2Array([c + Vector2(-8, -4), c + Vector2(-1, 0),
					c + Vector2(-1, 9), c + Vector2(-8, 5)]), col.darkened(0.25))
				draw_colored_polygon(PackedVector2Array([c + Vector2(8, -4), c + Vector2(1, 0),
					c + Vector2(1, 9), c + Vector2(8, 5)]), col.darkened(0.45))
			"wheels":
				draw_arc(c, 8.0, 0.0, TAU, 8, col, 3.0)
				draw_rect(Rect2(c - Vector2(2, 2), Vector2(4, 4)), col)
			"attack":
				draw_arc(c, 7.0, 0.0, TAU, 12, col, 2.0)
				draw_line(c + Vector2(-11, 0), c + Vector2(-4, 0), col, 2.0)
				draw_line(c + Vector2(4, 0), c + Vector2(11, 0), col, 2.0)
				draw_line(c + Vector2(0, -11), c + Vector2(0, -4), col, 2.0)
				draw_line(c + Vector2(0, 4), c + Vector2(0, 11), col, 2.0)
			"factory":
				draw_colored_polygon(PackedVector2Array([c + Vector2(-10, 9), c + Vector2(-10, -1),
					c + Vector2(-4, 3), c + Vector2(-4, -1), c + Vector2(2, 3), c + Vector2(2, -9),
					c + Vector2(7, -9), c + Vector2(7, 9)]), col)
			"power":
				draw_colored_polygon(PackedVector2Array([c + Vector2(2, -10), c + Vector2(-6, 2),
					c + Vector2(0, 2), c + Vector2(-2, 10), c + Vector2(6, -2), c + Vector2(0, -2)]), col)
		var font: Font = get_theme_default_font()
		var cap: String = word.to_upper()
		var tw: float = font.get_string_size(cap, HORIZONTAL_ALIGNMENT_LEFT, -1, 11).x
		draw_string(font, Vector2((size.x - tw) * 0.5, 44.0), cap, HORIZONTAL_ALIGNMENT_LEFT, -1, 11, col)
		if on:
			draw_rect(Rect2(6.0, size.y - 3.0, size.x - 12.0, 3.0), Color(0.86, 0.58, 0.22))


## The tile area's back: a faint grid on the block's own cell, so the shop sits on the build floor.
class SvBack extends Control:
	func _draw() -> void:
		draw_rect(Rect2(Vector2.ZERO, size), Color(0.07, 0.07, 0.085))
		var step := 32.0
		var col := Color(1, 1, 1, 0.025)
		var x := 0.0
		while x < size.x:
			draw_line(Vector2(x, 0), Vector2(x, size.y), col, 1.0)
			x += step
		var y := 0.0
		while y < size.y:
			draw_line(Vector2(0, y), Vector2(size.x, y), col, 1.0)
			y += step
	func _notification(what: int) -> void:
		if what == NOTIFICATION_RESIZED:
			queue_redraw()

## One block for sale, drawn whole: the portrait big, grade top-left, stock top-right, a price bar.
## Shape follows the blocks: a box with one CUT corner and lighter edge lines, not a rounded card.
class SvTile extends Button:
	var bt: int = 0
	var title: String = ""
	var icon_tex: Texture2D = null
	var price: int = 0
	var was: int = 0
	var left: int = -1
	var sale: int = 0
	var grade: int = 1
	var locked: bool = false
	var poor: bool = false
	var selected: bool = false
	var num_font: Font = null
	const CUT := 12.0
	const BAR := 30.0
	func _draw() -> void:
		var w: float = size.x
		var h: float = size.y
		var font: Font = get_theme_default_font()
		var nf: Font = num_font if num_font != null else font
		var body := PackedVector2Array([Vector2(0, 0), Vector2(w - CUT, 0), Vector2(w, CUT),
			Vector2(w, h), Vector2(0, h)])
		var bg := Color(0.115, 0.113, 0.135)
		if is_hovered() and not locked:
			bg = Color(0.14, 0.138, 0.165)
		draw_colored_polygon(body, bg)
		# edge lines as on the models: lighter along the top, darker along the bottom
		draw_line(Vector2(0, 0.5), Vector2(w - CUT, 0.5), Color(0.26, 0.26, 0.31), 1.0)
		draw_line(Vector2(w - CUT, 0.5), Vector2(w - 0.5, CUT), Color(0.26, 0.26, 0.31), 1.0)
		draw_line(Vector2(0.5, 0), Vector2(0.5, h), Color(0.18, 0.18, 0.22), 1.0)
		# the portrait
		var pr := Rect2(Vector2((w - 104.0) * 0.5, 16.0), Vector2(104.0, 104.0))
		if icon_tex != null:
			var tint := Color(0.35, 0.35, 0.4, 0.8) if locked else Color.WHITE
			draw_texture_rect(icon_tex, pr, false, tint)
		# grade, top-left: a roman numeral, the way the faction's grades are spoken of
		var roman: Array = ["I", "II", "III", "IV", "V", "VI"]
		var gtxt: String = String(roman[clampi(grade - 1, 0, 5)])
		draw_string(nf, Vector2(7, 17), gtxt, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(0.56, 0.57, 0.64))
		# stock, top-right under the cut: a count for today's blocks, nothing for endless ones
		if left > 0 and not locked:
			var st: String = "×%d" % left
			var sw: float = nf.get_string_size(st, HORIZONTAL_ALIGNMENT_LEFT, -1, 14).x
			draw_string(nf, Vector2(w - sw - 7.0, CUT + 12.0), st, HORIZONTAL_ALIGNMENT_LEFT, -1, 14,
				Color(0.9, 0.9, 0.93))
		# the name, one line under the portrait
		draw_string(font, Vector2(7, h - BAR - 6.0), title, HORIZONTAL_ALIGNMENT_LEFT, w - 14.0, 11,
			Color(0.74, 0.75, 0.8))
		# the price bar
		var bar := Rect2(0, h - BAR, w, BAR)
		var amber := Color(0.86, 0.58, 0.22)
		draw_rect(bar, amber if sale > 0 and not locked else Color(0.065, 0.065, 0.08))
		if locked:
			var c := Vector2(14.0, h - BAR * 0.5)
			var lc := Color(0.56, 0.57, 0.64)
			draw_rect(Rect2(c.x - 6, c.y - 1, 12, 8), lc)
			draw_polyline(PackedVector2Array([c + Vector2(-4, -1), c + Vector2(-4, -5), c + Vector2(-2, -7),
				c + Vector2(2, -7), c + Vector2(4, -5), c + Vector2(4, -1)]), lc, 2.0)
			draw_string(font, Vector2(26, h - 10.0), tr("Grade %d") % grade, HORIZONTAL_ALIGNMENT_LEFT,
				w - 30.0, 12, lc)
		else:
			var ink := Color(0.08, 0.06, 0.03) if sale > 0 else (Color(0.95, 0.5, 0.45) if poor else Color(0.9, 0.9, 0.93))
			var ptxt := str(price)
			var pw: float = nf.get_string_size(ptxt, HORIZONTAL_ALIGNMENT_LEFT, -1, 16).x
			draw_string(nf, Vector2(w - pw - 8.0, h - 9.0), ptxt, HORIZONTAL_ALIGNMENT_LEFT, -1, 16, ink)
			_coin(Vector2(w - pw - 18.0, h - BAR * 0.5))
			if sale > 0:
				draw_string(nf, Vector2(7, h - 10.0), "−%d%%" % sale, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, ink)
		if selected:
			var sc := amber
			draw_polyline(PackedVector2Array([Vector2(1, 1), Vector2(w - CUT - 0.5, 1), Vector2(w - 1, CUT + 0.5),
				Vector2(w - 1, h - 1), Vector2(1, h - 1), Vector2(1, 1)]), sc, 2.0)
	func _coin(c: Vector2) -> void:
		var pts := PackedVector2Array()
		for i in 8:
			var a: float = TAU * (i + 0.5) / 8.0
			pts.append(c + Vector2(cos(a), sin(a)) * 6.0)
		draw_colored_polygon(pts, Color(0.83, 0.62, 0.24) if sale <= 0 else Color(0.25, 0.16, 0.05))
		draw_rect(Rect2(c.x - 1.0, c.y - 2.5, 2.0, 5.0), Color(0.45, 0.3, 0.1) if sale <= 0 else Color(0.86, 0.58, 0.22))
