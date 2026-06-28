extends CanvasLayer
# Экранное меню магазина — ОДНО на всю игру (autoload). Любой магазин открывает его через
# ShopMenu.open(shop_node). Две вкладки: «Купить» (тратишь G.money → блок в G.block_inventory)
# и «Инвентарь» (достаёшь блок → он спавнится в мире рядом с этим магазином).
#
# UI строится кодом, чтобы не было .tscn для ручной правки — стилизовать можно потом.

var _shop: Node = null
var _spawn_anchor: Vector3 = Vector3.ZERO   # мировая точка магазина (от его кнопки)

var _bg:        ColorRect
var _tabs:      TabContainer
var _buy_list:  VBoxContainer
var _inv_list:  VBoxContainer

# Что продаётся и почём: тип блока (G.Block) → цена. Правь под свой баланс.
var _prices: Dictionary = {}

func _ready() -> void:
	layer = 20                                   # поверх HUD
	# Без этого тап по 3D-кнопке магазина не доходит до её Area3D._input_event.
	get_viewport().physics_object_picking = true
	get_viewport().physics_object_picking_sort = true
	_prices = {
		G.Block.BLOCK: 5,
		G.Block.WHEEL: 10,
		G.Block.COLLECTOR: 15,
		G.Block.DRILL: 20,
		G.Block.CABIN: 25,
	}
	_build_ui()
	visible = false

func _build_ui() -> void:
	# Полупрозрачный фон — ловит тапы, чтобы они не уходили в игру под меню.
	_bg = ColorRect.new()
	_bg.color = Color(0, 0, 0, 0.55)
	_bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_bg.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_bg)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center)

	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(460, 580)
	center.add_child(panel)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 8)
	panel.add_child(vb)

	# Заголовок + крестик
	var header := HBoxContainer.new()
	vb.add_child(header)
	var title := Label.new()
	title.text = "Магазин"
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)
	var close := Button.new()
	close.text = "X"
	close.custom_minimum_size = Vector2(48, 48)
	close.pressed.connect(close_menu)
	header.add_child(close)

	# Вкладки
	_tabs = TabContainer.new()
	_tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vb.add_child(_tabs)

	var buy_scroll := ScrollContainer.new()
	buy_scroll.name = "Купить"
	_buy_list = VBoxContainer.new()
	_buy_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_buy_list.add_theme_constant_override("separation", 6)
	buy_scroll.add_child(_buy_list)
	_tabs.add_child(buy_scroll)

	var inv_scroll := ScrollContainer.new()
	inv_scroll.name = "Инвентарь"
	_inv_list = VBoxContainer.new()
	_inv_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_inv_list.add_theme_constant_override("separation", 6)
	inv_scroll.add_child(_inv_list)
	_tabs.add_child(inv_scroll)

# ── Открытие / закрытие ───────────────────────────────────────────────────────

func open(shop: Node, spawn_anchor: Vector3 = Vector3.ZERO) -> void:
	_shop = shop
	_spawn_anchor = spawn_anchor
	visible = true
	_refresh()

func close_menu() -> void:
	visible = false
	_shop = null

# ── Наполнение ────────────────────────────────────────────────────────────────

func _refresh() -> void:
	_refresh_buy()
	_refresh_inventory()

func _refresh_buy() -> void:
	for c in _buy_list.get_children():
		c.queue_free()
	var money_row := Label.new()
	money_row.text = "Деньги: %d$" % G.money
	_buy_list.add_child(money_row)
	for block_type in _prices:
		var price: int = _prices[block_type]
		var row := Button.new()
		row.custom_minimum_size.y = 52
		row.text = "%s — %d$" % [_block_name(block_type), price]
		row.disabled = G.money < price
		row.pressed.connect(_buy.bind(block_type, price))
		_buy_list.add_child(row)

func _buy(block_type: int, price: int) -> void:
	if G.money < price:
		return
	G.money -= price
	G.block_inventory.append(block_type)
	_refresh()

func _refresh_inventory() -> void:
	for c in _inv_list.get_children():
		c.queue_free()
	# Группируем по типу с количеством.
	var counts: Dictionary = {}
	for b in G.block_inventory:
		counts[b] = counts.get(b, 0) + 1
	if counts.is_empty():
		var empty := Label.new()
		empty.text = "Инвентарь пуст"
		_inv_list.add_child(empty)
		return
	for block_type in counts:
		var row := Button.new()
		row.custom_minimum_size.y = 52
		row.text = "%s ×%d — Достать" % [_block_name(block_type), counts[block_type]]
		row.pressed.connect(_take_out.bind(block_type))
		_inv_list.add_child(row)

func _take_out(block_type: int) -> void:
	var scene: PackedScene = G.get_scene(block_type)
	if scene == null:
		return
	if not G.block_inventory.has(block_type):
		return
	G.block_inventory.erase(block_type)            # убираем один экземпляр
	var block := scene.instantiate()
	# Мировая точка спавна — от кнопки магазина (она физически на магазине), чуть в сторону
	# и выше, упадёт на рельеф сам. Фолбэк на узел магазина, если якорь не передали.
	var origin := _spawn_anchor + Vector3(2.0, 0.5, 2.0)
	if _spawn_anchor == Vector3.ZERO and _shop and _shop is Node3D:
		origin = (_shop as Node3D).global_position + Vector3(2.0, 2.0, 2.0)
	var objects := get_node_or_null("/root/Main/objects")
	if objects:
		objects.add_child(block)
	else:
		get_tree().current_scene.add_child(block)
	# ВАЖНО: ставим global_position ПОСЛЕ add_child. Узел objects сдвинут трансформом
	# (~0,56,110), а локальный position игнорировал бы этот сдвиг → блок улетал в другой
	# конец карты. global_position кладёт его именно туда, где магазин.
	if block is Node3D:
		(block as Node3D).global_position = origin
	_refresh()

func _block_name(block_type: int) -> String:
	var names: Array = G.Block.keys()
	if block_type >= 0 and block_type < names.size():
		return str(names[block_type])
	return "Block %d" % block_type
