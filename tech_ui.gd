extends Control
# Инвентарь/крафт-UI в духе TerraTech, подключён к реальной игре:
#   • INVENTORY — блоки из G.block_inventory; клик по слоту берёт блок В РУКУ
#     (vehicle.take_block_into_hand) → дальше ставишь его на машину обычным Building-флоу.
#   • SHOP      — покупка блоков за G.money (бывшая вкладка CAB CRAFTING).
#   • WEAPONS   — те же блоки, отфильтрованные по оружию (GUN/LASER).
#   • Справа    — имя машины, построено/в наличии блоков, масса машины (всё из игры).
# ВИЗУАЛ (тема, иконки, радиальный гейдж) дорабатывается в редакторе поверх этого скелета.

enum { TAB_INVENTORY, TAB_SHOP, TAB_WEAPONS, TAB_SKINS, TAB_SNAPSHOTS }

@onready var _grid:   GridContainer = %Grid
@onready var _search: LineEdit      = %Search
@onready var _tab_buttons: Array = [
	%TabInventory, %TabShop, %TabWeapons, %TabSkins, %TabSnapshots
]

var _items: Array = []   # [{type:int, name:String, count:int, price:int}]
var _tab: int = TAB_INVENTORY
var _prices: Dictionary = {}              # G.Block -> цена (что продаётся в SHOP)
var _weapon_types: Array = []             # типы-оружие для вкладки WEAPONS

func _ready() -> void:
	_prices = {
		G.Block.BLOCK: 5,
		G.Block.WHEEL: 10,
		G.Block.COLLECTOR: 15,
		G.Block.DRILL: 20,
		G.Block.CABIN: 25,
		G.Block.GUN: 40,
		G.Block.LASER: 60,
	}
	_weapon_types = [G.Block.GUN, G.Block.LASER]
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
			_items.append({
				"type": int(block_type),
				"name": _block_name(int(block_type)),
				"count": 0,
				"price": int(_prices[block_type]),
			})
		return
	# INVENTORY / WEAPONS — реальные блоки игрока, сгруппированные по типу.
	var counts: Dictionary = {}
	for b in G.block_inventory:
		counts[b] = counts.get(b, 0) + 1
	for block_type in counts:
		if _tab == TAB_WEAPONS and not _weapon_types.has(int(block_type)):
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

func _rebuild_grid(filter: String) -> void:
	if _grid == null:
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
		if _tab == TAB_SKINS or _tab == TAB_SNAPSHOTS:
			empty.text = "—"
		elif not _items.is_empty():
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
