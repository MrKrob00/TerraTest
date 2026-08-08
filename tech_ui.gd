extends Control
# Инвентарь/крафт-UI (гараж), подключён к реальной игре:
#   • INVENTORY — блоки из G.block_inventory; клик по слоту берёт блок В РУКУ
#     (vehicle.take_block_into_hand) → дальше ставишь его на машину обычным Building-флоу.
#   • SHOP      — покупка блоков за G.money (ассортимент = мировой магазин).
#   • СБОРКИ    — сохранение/применение раскладок машины.
#   • Справа    — имя машины, нагруженность (тянет/не тянет) и характеристики.
#                 Все значения живые: строки собираются кодом из MachineBody, а не
#                 лежат в сцене, где часть чисел осталась картинкой со скриншота.

enum { TAB_INVENTORY, TAB_SHOP, TAB_BUILDS, TAB_MUSIC, TAB_SETTINGS, TAB_TECH }

@onready var _grid:   HFlowContainer = %Grid
@onready var _search: LineEdit      = %Search
# ВАЖНО: индекс в массиве = значение enum (bind в _ready) — TabTech последним.
@onready var _tab_buttons: Array = [
	%TabInventory, %TabShop, %TabSnapshots, %TabMusic, %TabSettings, %TabTech
]

var _items: Array = []   # [{type:int, name:String, count:int, price:int}]
var _tab: int = TAB_INVENTORY
var _prices: Dictionary = {}              # G.Block -> цена (что продаётся в SHOP)

# ── Фильтры вкладки SHOP (гараж — единственный магазин блоков) ────────────────
var _categories: Dictionary = {}          # ключ → Array типов
var _shop_filter: String = "all"
var _last_slot_side: float = 0.0        # чтобы пересобирать сетку только при реальной смене ширины
var _filter_col: VBoxContainer = null     # колонка кнопок слева от сетки (видна в SHOP)
var _filter_buttons: Dictionary = {}
const FILTERS := [
	["all",     "All"],
	["attack",  "Attack"],
	["blocks",  "Blocks"],
	["factory", "Factory"],
	["other",   "Other"],
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
		G.Block.ROCKET: 55,
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
	# Любой блок из дерева, которому не задали цену выше, ВСЁ РАВНО попадает в магазин (цена от
	# стоимости исследования). Так все блоки — и новые в будущем — автоматически есть в магазине.
	for _bt in G.BLOCK_META:
		if not _prices.has(_bt):
			_prices[_bt] = maxi(int(G.BLOCK_META[_bt].get("rp", 10)), 5)
	# Категории — общие с глобусом стройки (G.BLOCK_CATEGORIES), чтобы не расходились.
	_categories = G.BLOCK_CATEGORIES
	_build_filter_column()
	_build_stats_panel()
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
	for i: int in _tab_buttons.size():
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
			_items.append({
				"type": int(block_type),
				"name": _block_name(int(block_type)),
				"count": 0,
				"price": int(_prices[block_type]),
			})
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

func _block_name(block_type: int) -> String:
	var names: Array = G.Block.keys()
	if block_type >= 0 and block_type < names.size():
		return str(names[block_type]).capitalize()
	return "Block %d" % block_type

const COLS := 4

func _slot_side() -> float:
	if _grid == null:
		return 96.0
	var sep: float = float(_grid.get_theme_constant("h_separation"))
	var w: float = _grid.size.x
	if w <= 1.0:                                   # ещё не разложились — берём разумный дефолт
		return 96.0
	return maxf(floorf((w - sep * float(COLS - 1)) / float(COLS)), 48.0)

func _on_grid_resized() -> void:
	if _tab != TAB_INVENTORY and _tab != TAB_SHOP and _tab != TAB_BUILDS:
		return
	if absf(_slot_side() - _last_slot_side) < 1.0:
		return                                     # ширина слота не изменилась — перестраивать нечего
	_rebuild_grid(_search.text if _search else "")

func _rebuild_grid(filter: String) -> void:
	if _grid == null:
		return
	_last_slot_side = _slot_side()
	if _tab == TAB_BUILDS:
		_build_builds_tab()
		return
	for c: Node in _grid.get_children():
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
			empty.text = "Nothing found"
		elif _tab == TAB_SHOP:
			empty.text = "Shop empty"
		else:
			empty.text = "Inventory empty"
		_grid.add_child(empty)

func _make_slot(it: Dictionary) -> Control:
	# Слот = кнопка с названием блока. INVENTORY: в углу ×count, клик → блок в руку.
	# SHOP: в углу цена, клик → купить (выключена, если не хватает денег).
	var btn := Button.new()
	var _side := _slot_side()
	btn.custom_minimum_size = Vector2(_side, _side)
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
		if not G.is_block_shop_unlocked(block_type):
			# Замок: блок виден (мотивация), но не покупается. Причина в углу и тултипе:
			# не исследован в древе / не хватает грейда лицензии.
			var m: Dictionary = G.BLOCK_META.get(block_type, {})
			if not m.is_empty() and G.grade(m["f"]) < int(m["g"]):
				corner.text = "gr.%d" % int(m["g"])
				btn.tooltip_text = "Requires license grade %d" % int(m["g"])
			else:
				corner.text = "tree"
				btn.tooltip_text = "Research in the tech tree"
			btn.disabled = true
			btn.modulate = Color(1, 1, 1, 0.45)
		else:
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
	for c: Node in _grid.get_children():
		c.queue_free()
	_grid.add_child(_make_action_slot("＋ Save\ncurrent", _save_current_build))
	for build_name in G.saved_builds:
		_grid.add_child(_make_build_slot(str(build_name)))

func _make_action_slot(label: String, cb: Callable) -> Control:
	var btn := Button.new()
	var _side := _slot_side()
	btn.custom_minimum_size = Vector2(_side, _side)
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
	corner.text = "%d bl." % layout.size()
	corner.add_theme_font_size_override("font_size", 12)
	corner.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT)
	corner.offset_left = -52
	corner.offset_top = -22
	corner.mouse_filter = Control.MOUSE_FILTER_IGNORE
	btn.add_child(corner)
	# Действия (переименовать/удалить) — по ДОЛГОМУ нажатию (и правой кнопкой на ПК), а не
	# крошечными иконками в углу: на телефоне в 26 px попасть пальцем невозможно, а увеличить
	# их прямо в слоте — значит закрыть название сборки. В меню цели крупные и не мешают.
	btn.gui_input.connect(_on_build_slot_input.bind(build_name))
	btn.button_up.connect(func() -> void: _hold_name = "")
	var hint := PencilIcon.new()                       # маленький значок «у слота есть действия»
	hint.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	hint.offset_left = -24.0
	hint.offset_top = 2.0
	hint.offset_right = -2.0
	hint.offset_bottom = 24.0
	hint.modulate = Color(1, 1, 1, 0.45)
	hint.mouse_filter = Control.MOUSE_FILTER_IGNORE    # не перехватывает нажатие — это лишь подсказка
	btn.add_child(hint)
	return btn

# ── Долгое нажатие по слоту сборки → меню действий ────────────────────────────
const HOLD_MS := 450
var _hold_name: String = ""
var _hold_start: int = 0
var _build_menu: PopupMenu = null
var _menu_target: String = ""
var _skip_apply: bool = false

func _on_build_slot_input(event: InputEvent, build_name: String) -> void:
	# ПК: правая кнопка открывает меню сразу.
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
		_open_build_menu(build_name)
		return
	if event is InputEventMouseButton or event is InputEventScreenTouch:
		if event.pressed:
			_hold_name = build_name
			_hold_start = Time.get_ticks_msec()
		else:
			_hold_name = ""

func _process(_delta: float) -> void:
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
		_build_menu.add_item("Apply", 0)
		_build_menu.add_item("Rename", 1)
		_build_menu.add_item("Delete", 2)
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
		_rename_dialog.title = "Rename build"
		_rename_dialog.ok_button_text = "Rename"
		_rename_dialog.add_cancel_button("Cancel")
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
		_say("Name already taken: %s" % new_name)
		return
	_rebuild_grid("")
	_say("Renamed: %s" % new_name)

var _delete_dialog: ConfirmationDialog = null
var _delete_target: String = ""

func _ask_delete_build(build_name: String) -> void:
	_delete_target = build_name
	if _delete_dialog == null or not is_instance_valid(_delete_dialog):
		_delete_dialog = ConfirmationDialog.new()
		_delete_dialog.title = "Delete build"
		_delete_dialog.ok_button_text = "Delete"
		_delete_dialog.confirmed.connect(_apply_delete)
		add_child(_delete_dialog)
	_delete_dialog.dialog_text = "Delete build \"%s\"?" % build_name
	_delete_dialog.popup_centered(Vector2i(340, 130))

func _apply_delete() -> void:
	G.delete_build(_delete_target)
	_rebuild_grid("")
	_say("Deleted: %s" % _delete_target)

func _save_current_build() -> void:
	var v: Node = _get_vehicle()
	if v == null or not v.has_method("capture_build"):
		return
	var layout: Array = v.capture_build()
	if layout.is_empty():
		return
	var bname: String = "Build %d" % (G.saved_builds.size() + 1)
	G.save_build(bname, layout)
	_rebuild_grid("")
	_say("Build saved: %s" % bname)

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
		_say("Missing: " + _missing_text(missing))
		return
	# Применяем: новый инвентарь = пул − потрачено на сборку.
	for t in need:
		pool[t] = int(pool.get(t, 0)) - int(need[t])
	var new_inv: Array = []
	for t in pool:
		for _i in int(pool[t]):
			new_inv.append(int(t))
	G.block_inventory = new_inv
	G.mark_progress_dirty()
	v.apply_build(target)
	_say("Build applied: %s" % build_name)
	refresh()

func _missing_text(missing: Dictionary) -> String:
	var parts: Array = []
	for t in missing:
		parts.append("%s ×%d" % [_block_name(int(t)), int(missing[t])])
	return ", ".join(parts)

func _say(text: String) -> void:
	var d := get_node_or_null("/root/Dialogue")
	if d:
		d.say("Garage", text)

# ── Действия ──────────────────────────────────────────────────────────────────
func _take_into_hand(block_type: int) -> void:
	if not G.block_inventory.has(block_type):
		return
	var v: Node = _get_vehicle()
	if v == null or not v.has_method("take_block_into_hand"):
		push_warning("tech_ui: no active vehicle found to hand the block to")
		return
	if not v.take_block_into_hand(block_type):
		return                                  # в руке уже что-то есть
	G.block_inventory.erase(block_type)         # списываем один экземпляр
	G.mark_progress_dirty()
	visible = false                             # прячем UI — пора ставить блок на машину

func _buy(block_type: int, price: int) -> void:
	if G.money < price:
		return
	G.money -= price
	G.block_inventory.append(block_type)
	G.mark_progress_dirty()
	# Магазин остаётся открытым: обновляем цены/доступность кнопок и счётчик денег.
	_rebuild_grid(_search.text if _search else "")
	_update_currency()
	_refresh_stats()

# ── Вкладки ───────────────────────────────────────────────────────────────────
func _select_tab(idx: int) -> void:
	_tab = idx
	for i: int in _tab_buttons.size():
		if _tab_buttons[i]:
			_tab_buttons[i].button_pressed = (i == idx)
	if _filter_col:
		_filter_col.visible = (_tab == TAB_SHOP or _tab == TAB_INVENTORY)
	# МУЗЫКА/НАСТРОЙКИ — спец-панель-список; ДРЕВО — свой 2D-панорамируемый граф.
	var extra_list: bool = _tab == TAB_MUSIC or _tab == TAB_SETTINGS
	var is_tech: bool = _tab == TAB_TECH
	var grid_scroll: Node = get_node_or_null("Root/Main/LeftPanel/LeftVB/Body/Scroll")
	if grid_scroll:
		grid_scroll.visible = not (extra_list or is_tech)
	if _extra_scroll:
		_extra_scroll.visible = extra_list
	if _tech_root:
		_tech_root.visible = is_tech
	if _search:
		_search.visible = not (extra_list or is_tech)
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
		var gr: int = G.grade("start")
		var xp: int = int(G.faction_xp.get("start", 0))
		var th: Array = (G.FACTIONS["start"] as Dictionary)["xp_thresholds"]
		var txt := "Gr.%d" % gr
		if gr < th.size():
			txt += " · %d/%d XP" % [xp, int(th[gr])]   # порог СЛЕДУЮЩЕГО грейда
		else:
			txt += " · max"
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
	heading.text = "SPECS"
	heading.add_theme_color_override("font_color", STAT_NAME_COLOR)
	heading.add_theme_font_size_override("font_size", 12)
	column.add_child(heading)

	var grid := GridContainer.new()
	grid.name = "StatsGrid"
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 14)
	grid.add_theme_constant_override("v_separation", 5)
	column.add_child(grid)

	for key: String in STAT_ROWS:
		var caption := Label.new()
		caption.text = key
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
	_set_stat("THRUST", "%d N" % int(round(m.rated_power())))
	_set_stat("TOP SPEED", "%d km/h" % int(round(m.max_speed * 3.6)))
	_set_stat("FIREPOWER", "%d dps" % int(round(m.firepower())))
	# Броня красится по остатку — сразу видно побитую машину, без чтения цифр.
	_set_stat("ARMOUR", "%d / %d" % [hp.x, hp.y],
		LOAD_OK if health > 0.66 else (LOAD_WARN if health > 0.33 else LOAD_BAD))
	# Ведущие показываем отдельно: именно они дают тягу, остальные только катятся.
	_set_stat("WHEELS", "%d / %d driven" % [wheels.y, wheels.x],
		STAT_VALUE_COLOR if wheels.y > 0 else LOAD_BAD)

const LOAD_OK: Color = Color(0.35, 0.85, 0.42)     # тянет легко
const LOAD_WARN: Color = Color(1.0, 0.78, 0.22)    # тянет, но с трудом
const LOAD_BAD: Color = Color(0.95, 0.32, 0.28)    # не поедет

# Панель показывает не число блоков, а способность машины себя везти: её масса против
# той, которую вытянет её собственная тяга. Предел не константа — он растёт от колёс,
# поэтому берётся из MachineBody, из той же формулы, по которой машина реально едет.
func set_load(m: MachineBody) -> void:
	var mass_now: float = m.mass
	var comfort: float = m.mass_comfort()
	var limit: float = m.mass_limit()

	var col: Color = LOAD_OK
	var verdict: String = "MOVES WELL"
	if limit < 1.0:
		col = LOAD_BAD
		verdict = "NO DRIVE"                       # тяги нет вообще: нужны колёса
	elif mass_now > limit:
		col = LOAD_BAD
		verdict = "TOO HEAVY"
	elif mass_now > comfort:
		col = LOAD_WARN
		verdict = "STRAINED"

	if has_node("%ReactorLabel"):
		%ReactorLabel.text = "LOAD  ·  " + verdict
	if has_node("%ReactorValue"):
		%ReactorValue.text = "%d / %d kg" % [int(round(mass_now)), int(round(limit))]
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
	for c: Node in _extra_vb.get_children():
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
		_extra_header("Music system not connected")
		return
	var cur: Dictionary = m.current_track()
	# Сейчас играет + пропуск
	var now_row := HBoxContainer.new()
	_extra_vb.add_child(now_row)
	var now := Label.new()
	now.text = ("▶ %s — %s  [%s]" % [cur.get("title", ""), cur.get("author", ""), m.context_name()]) \
			if not cur.is_empty() else "Silence (no tracks or all disabled)"
	now.add_theme_font_size_override("font_size", 13)
	now.add_theme_color_override("font_color", Color(0.75, 0.95, 0.8))
	now.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	now.clip_text = true
	now_row.add_child(now)
	var skip := Button.new()
	skip.text = "⏭"
	skip.tooltip_text = "Next track"
	skip.custom_minimum_size = Vector2(44, 38)
	skip.pressed.connect(func() -> void:
		var mm := _music()
		if mm: mm.skip())
	now_row.add_child(skip)
	# Громкость
	var vol_row := HBoxContainer.new()
	_extra_vb.add_child(vol_row)
	var vol_lbl := Label.new()
	vol_lbl.text = "Volume"
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
	var sections := [["Travel", m.Ctx.TRAVEL], ["Battle", m.Ctx.BATTLE]]
	for s in sections:
		_extra_header(str(s[0]))
		var list: Array = m.tracks.get(s[1], [])
		if list.is_empty():
			var empty := Label.new()
			empty.text = "   (no tracks — drop .ogg into music/)"
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

	row.add_child(_music_icon_btn(HeartIcon.new(), m.fav.has(file), "Favorite: plays more often",
			func(on: bool) -> void: m.set_favorite(file, on)))
	row.add_child(_music_icon_btn(BanIcon.new(), m.banned.has(file), "Never play",
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
	_extra_header("— GRAPHICS —")
	if main == null or not ("auto_fps" in main):
		_extra_header("Main with auto-FPS not found")
		return
	var auto_btn := CheckButton.new()
	auto_btn.text = "Auto FPS (render scale adjusts itself)"
	auto_btn.button_pressed = bool(main.auto_fps)
	auto_btn.add_theme_font_size_override("font_size", 14)
	_extra_vb.add_child(auto_btn)

	var scale_row := HBoxContainer.new()
	scale_row.visible = not bool(main.auto_fps)
	_extra_vb.add_child(scale_row)
	var scale_lbl := Label.new()
	scale_lbl.text = "Scale: %d%%" % int(round(float(main.manual_scale) * 100.0))
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
		scale_lbl.text = "Scale: %d%%" % int(round(v * 100.0))
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
	hint.text = "Auto mode holds ~55 FPS."
	hint.add_theme_font_size_override("font_size", 12)
	hint.modulate = Color(1, 1, 1, 0.55)
	_extra_vb.add_child(hint)

	if "shadows_enabled" in main:
		var shadow_btn := CheckButton.new()
		shadow_btn.text = "Shadows"
		shadow_btn.button_pressed = bool(main.shadows_enabled)
		shadow_btn.add_theme_font_size_override("font_size", 14)
		_extra_vb.add_child(shadow_btn)
		shadow_btn.toggled.connect(func(on: bool) -> void:
			var mn: Node = get_node_or_null("/root/Main")
			if mn and mn.has_method("set_shadows_enabled"):
				mn.set_shadows_enabled(on))

		var shadow_hint := Label.new()
		shadow_hint.text = "Turn off if FPS drops — the heaviest setting."
		shadow_hint.add_theme_font_size_override("font_size", 12)
		shadow_hint.modulate = Color(1, 1, 1, 0.55)
		_extra_vb.add_child(shadow_hint)

	# Полноэкранный ↔ плавающее окно (только ПК; окно тянется мышью, UI подстраивается сам).
	if OS.has_feature("pc") and "fullscreen" in main:
		var fs_btn := CheckButton.new()
		fs_btn.text = "Fullscreen mode (off — floating window)"
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
		ui_lbl.text = "Size: %d%%" % int(round(float(main.ui_scale) * 100.0))
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
			ui_lbl.text = "Size: %d%%" % int(round(v * 100.0))
			var mn: Node = get_node_or_null("/root/Main")
			if mn and mn.has_method("set_ui_scale"):
				mn.set_ui_scale(v))
		ui_row.add_child(ui_sl)

		var ui_hint := Label.new()
		ui_hint.text = "Size of buttons/panels. The base already adapts to the screen on its own."
		ui_hint.add_theme_font_size_override("font_size", 12)
		ui_hint.modulate = Color(1, 1, 1, 0.55)
		_extra_vb.add_child(ui_hint)

	# — КАМЕРА — (перенесено из HUD: управление камерой настраивается здесь, в гараже)
	_extra_header("— CAMERA —")
	_extra_vb.add_child(_cam_slider("Rotation sensitivity", G.cam_look_sens,
			func(v): G.cam_look_sens = v; G.save_settings()))
	_extra_vb.add_child(_cam_slider("Zoom sensitivity", G.cam_zoom_sens,
			func(v): G.cam_zoom_sens = v; G.save_settings()))
	var inv := CheckButton.new()
	inv.text = "Invert vertical"
	inv.button_pressed = G.cam_invert_y
	inv.add_theme_font_size_override("font_size", 14)
	inv.toggled.connect(func(on: bool) -> void: G.cam_invert_y = on; G.save_settings())
	_extra_vb.add_child(inv)

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
const TNODE_W := 96.0
const TNODE_H := 50.0
const TCOL_W := 138.0                  # шаг колонок (глубина): зазор под линии связей
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

func _build_tech_tab() -> void:
	var body: Node = get_node_or_null("Root/Main/LeftPanel/LeftVB/Body")
	if body == null:
		return
	if _tech_root == null:
		_tech_build_shell(body)
	_tech_root.visible = true            # билдер зовётся только для активной вкладки ДРЕВО
	_tech_head.text = "Tech tree — researched %d/%d · RP: %d" % [
			G.researched.size(), G.BLOCK_META.size(), G.research_points]
	_tech_update_info()

	# Раскладка позиций всех нод (px) деревом.
	var pos := _tech_layout()
	# Холст нужного размера + перестройка нод/линий (сохраняя позицию прокрутки).
	var keep := Vector2(_tech_scroll.scroll_horizontal, _tech_scroll.scroll_vertical)
	var graph: TechGraph = _tech_graph
	for c: Node in graph.get_children():
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

# Каркас вкладки (создаётся один раз): фикс. шапка+инфо+кнопка, ниже — граф в 2D-скролле.
func _tech_build_shell(body: Node) -> void:
	_tech_root = VBoxContainer.new()
	_tech_root.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_tech_root.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_tech_root.add_theme_constant_override("separation", 6)
	_tech_root.visible = false
	body.add_child(_tech_root)

	_tech_head = Label.new()
	_tech_head.add_theme_font_size_override("font_size", 16)
	_tech_root.add_child(_tech_head)

	var panel := PanelContainer.new()
	var pv := VBoxContainer.new()
	panel.add_child(pv)
	_tech_info = Label.new()
	_tech_info.add_theme_font_size_override("font_size", 13)
	_tech_info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	pv.add_child(_tech_info)
	_tech_btn = Button.new()
	_tech_btn.custom_minimum_size = Vector2(0, 40)
	_tech_btn.pressed.connect(_tech_do_research)
	pv.add_child(_tech_btn)
	_tech_root.add_child(panel)

	_tech_scroll = ScrollContainer.new()
	_tech_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_tech_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_tech_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	_tech_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	_tech_root.add_child(_tech_scroll)
	_tech_graph = TechGraph.new()
	_tech_graph.mouse_filter = Control.MOUSE_FILTER_PASS   # тач-драг скролла проходит сквозь холст
	_tech_scroll.add_child(_tech_graph)

# Позиции всех нод дерева (px). x = глубина·TCOL_W; y = ряд·TROW_H (лист по счётчику,
# родитель — среднее детей: классическая аккуратная раскладка дерева).
func _tech_layout() -> Dictionary:
	var children: Dictionary = {}
	var root := -1
	for bt in G.BLOCK_META:
		if G.TECH_PARENT.has(bt):
			var par := int(G.TECH_PARENT[bt])
			if not children.has(par):
				children[par] = []
			(children[par] as Array).append(int(bt))
		else:
			root = int(bt)                 # без родителя = корень (кабина)
	for par in children:
		(children[par] as Array).sort()    # стабильный порядок детей
	var rows: Dictionary = {}
	_tech_leaf = 0.0
	if root >= 0:
		_tech_assign(root, children, rows)
	var pos: Dictionary = {}
	for bt in rows:
		pos[bt] = Vector2(TMARGIN + _tech_depth(int(bt)) * TCOL_W,
				TMARGIN + float(rows[bt]) * TROW_H)
	return pos

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
	if G.researched.has(bt):
		status = "researched"
		btn.modulate = Color(0.72, 1.0, 0.82)
	else:
		var why: String = G.research_lock_reason(bt)
		if why == "":
			status = "%d RP" % int(meta["rp"])
		elif why.begins_with("need RP"):
			status = "%d RP (short)" % int(meta["rp"])
			btn.modulate = Color(1.0, 0.93, 0.65, 0.9)
		else:
			status = "locked"
			btn.modulate = Color(1, 1, 1, 0.45)
	btn.text = "%s\n%s" % [_block_name(bt), status]
	if bt == _tech_selected:
		btn.toggle_mode = true
		btn.button_pressed = true
	btn.pressed.connect(func() -> void:
		_tech_selected = bt
		_tech_update_info())
	return btn

# Текст инфо-панели и состояние кнопки «Исследовать» по выбранной ноде.
func _tech_update_info() -> void:
	if _tech_info == null or _tech_btn == null:
		return
	if _tech_selected < 0 or not G.BLOCK_META.has(_tech_selected):
		_tech_info.text = "Select a block in the tree to see details."
		_tech_btn.text = "Research"
		_tech_btn.disabled = true
		return
	var bt := _tech_selected
	var m: Dictionary = G.BLOCK_META[bt]
	var line := "%s — grade %d · cost %d RP" % [_block_name(bt), int(m["g"]), int(m["rp"])]
	var parent := int(G.TECH_PARENT.get(bt, -1))
	var why: String
	if parent >= 0:
		line += " · requires: %s" % _block_name(parent)
	if not G.researched.has(bt):
		why= G.research_lock_reason(bt)
		if why != "":
			line += "\n" + why         # у изученной причины нет — кнопка и так скажет
	_tech_info.text = line
	if G.researched.has(bt):
		_tech_btn.text = "Researched"
		_tech_btn.disabled = true
	else:
		_tech_btn.text = "Research (%d RP)" % int(m["rp"])
		_tech_btn.disabled = why != ""

func _tech_do_research() -> void:
	if _tech_selected < 0:
		return
	var bt := _tech_selected
	if not G.research(bt):
		_tech_update_info()            # причина могла устареть — показать актуальную
		return
	_say("Researched: %s! +1 block already in inventory." % _block_name(bt))
	# G.research эмитит progress_changed → _on_progress_changed перестроит вкладку
	# (нода станет ✓, соседи откроются) — тут ничего пересобирать не нужно.
