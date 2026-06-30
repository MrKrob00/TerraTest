extends Control
# Каркас инвентарь/крафт-UI в духе TerraTech: верхние вкладки, слева сетка слотов с
# категориями и поиском, справа панель характеристик, снизу подсказки управления.
# ДИНАМИКА здесь (сетка/вкладки/поиск); ВИЗУАЛ (тема, гейдж реактора, иконки) — в редакторе.
# Слоты читаются из РЕАЛЬНОГО инвентаря G.block_inventory (плоский массив G.Block,
# группируем по типу с количеством). Сетка обновляется каждый раз при показе панели.

@onready var _grid:   GridContainer = %Grid
@onready var _search: LineEdit      = %Search
@onready var _tab_buttons: Array = [
	%TabInventory, %TabCab, %TabWeapons, %TabSkins, %TabSnapshots
]

var _items: Array = []   # [{type:int, name:String, count:int}]

func _ready() -> void:
	_load_items()
	_rebuild_grid("")
	if _search:
		_search.text_changed.connect(func(t: String) -> void: _rebuild_grid(t))
	for i in _tab_buttons.size():
		if _tab_buttons[i]:
			_tab_buttons[i].pressed.connect(_select_tab.bind(i))
	# Каждый раз при показе панели перечитываем инвентарь (блоки могли измениться).
	visibility_changed.connect(_on_visibility_changed)
	_select_tab(0)

func _on_visibility_changed() -> void:
	if visible:
		refresh()

# Перечитать инвентарь и перестроить сетку (сохраняя текущий фильтр поиска).
func refresh() -> void:
	_load_items()
	_rebuild_grid(_search.text if _search else "")

# Реальное наполнение из инвентаря: группируем плоский массив по типу с количеством.
func _load_items() -> void:
	_items.clear()
	var counts: Dictionary = {}
	for b in G.block_inventory:
		counts[b] = counts.get(b, 0) + 1
	for block_type in counts:
		_items.append({
			"type": int(block_type),
			"name": _block_name(int(block_type)),
			"count": int(counts[block_type]),
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
		empty.text = "Инвентарь пуст" if _items.is_empty() else "Ничего не найдено"
		empty.modulate = Color(1, 1, 1, 0.5)
		_grid.add_child(empty)

func _make_slot(it: Dictionary) -> Control:
	# Слот = кнопка с названием блока и числом в углу. Иконку добавишь сверху (TextureRect) в редакторе.
	var btn := Button.new()
	btn.custom_minimum_size = Vector2(96, 96)
	btn.clip_text = true
	btn.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	btn.text = str(it["name"])
	btn.add_theme_font_size_override("font_size", 13)
	var count := Label.new()
	count.text = "×%d" % int(it["count"])
	count.add_theme_font_size_override("font_size", 16)
	count.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT)
	count.offset_left = -40
	count.offset_top = -24
	count.mouse_filter = Control.MOUSE_FILTER_IGNORE
	btn.add_child(count)
	return btn

func _select_tab(idx: int) -> void:
	for i in _tab_buttons.size():
		if _tab_buttons[i]:
			_tab_buttons[i].button_pressed = (i == idx)

# ── Публичный API для характеристик справа (зови из своей логики техники) ──────
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
