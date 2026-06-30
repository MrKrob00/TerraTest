extends Control
# Каркас инвентарь/крафт-UI в духе TerraTech: верхние вкладки, слева сетка слотов с
# категориями и поиском, справа панель характеристик, снизу подсказки управления.
# ДИНАМИКА здесь (сетка/вкладки/поиск); ВИЗУАЛ (тема, гейдж реактора, иконки) — в редакторе.
# Слоты сейчас демо; подключишь к G.block_inventory когда захочешь (см. _load_items).

@onready var _grid:   GridContainer = %Grid
@onready var _search: LineEdit      = %Search
@onready var _tab_buttons: Array = [
	%TabInventory, %TabCab, %TabWeapons, %TabSkins, %TabSnapshots
]

var _items: Array = []   # [{name:String, count:int}]

func _ready() -> void:
	_load_items()
	_rebuild_grid("")
	if _search:
		_search.text_changed.connect(func(t: String) -> void: _rebuild_grid(t))
	for i in _tab_buttons.size():
		if _tab_buttons[i]:
			_tab_buttons[i].pressed.connect(_select_tab.bind(i))
	_select_tab(0)

# Демо-наполнение. Замени на чтение своих данных (напр. G.block_inventory).
func _load_items() -> void:
	_items.clear()
	for i in 24:
		_items.append({"name": "Block %d" % i, "count": 90 + (i % 10)})

func _rebuild_grid(filter: String) -> void:
	if _grid == null:
		return
	for c in _grid.get_children():
		c.queue_free()
	var f := filter.strip_edges().to_lower()
	for it in _items:
		if f != "" and not str(it["name"]).to_lower().contains(f):
			continue
		_grid.add_child(_make_slot(it))

func _make_slot(it: Dictionary) -> Control:
	# Слот = кнопка с числом в углу. Иконку блока добавишь сверху (TextureRect) в редакторе.
	var btn := Button.new()
	btn.custom_minimum_size = Vector2(96, 96)
	btn.clip_text = true
	var count := Label.new()
	count.text = str(it["count"])
	count.add_theme_font_size_override("font_size", 16)
	count.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT)
	count.offset_left = -34
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
