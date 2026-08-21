extends Control
class_name PortPicker

# НАСТРОЙКА ПОРТОВ многоклеточного фабричного блока: каждая клетка каждой стороны отдельно.
#
# У односкеточного блока сторона и есть коннектор — там хватает галочек в инспекторе. А у
# блока 2×2×2 одна сторона это ЧЕТЫРЕ клетки, и настройка «вход слева» означала «вход во все
# четыре левые клетки сразу»: подвести две разные ленты с одной стороны было нельзя.
#
# Окно показывает СТОРОНУ ЦЕЛИКОМ, сеткой её клеток, и каждая клетка переключается по кругу
# ВЫКЛ → ВХОД → ВЫХОД. Так видно всю сторону разом, а не по одному порту, и понятно, что
# именно куда подключится.
#
# Стороны перечислены в осях КАРТЫ, как и сами порты (см. FactoryBlock): футпринт
# многоклеточного блока от поворота не зависит, и показывать его в локальных осях значило бы
# врать игроку про то, где у блока «лево».

const PANEL_W: float = 460.0
const CELL: float = 54.0

## Стороны и как раскладывать их клетки в сетку: по каким осям идут столбцы и строки.
## Порядок именно такой — сперва четыре боковых, потом верх и низ: боковые и есть те самые
## «4 стороны», ради которых всё затевалось, а верх с низом нужны реже.
const SIDES := [
	{"name": "FRONT  −Z", "dir": Vector3i(0, 0, -1), "col": Vector3i(1, 0, 0), "row": Vector3i(0, 1, 0)},
	{"name": "BACK  +Z",  "dir": Vector3i(0, 0, 1),  "col": Vector3i(1, 0, 0), "row": Vector3i(0, 1, 0)},
	{"name": "LEFT  −X",  "dir": Vector3i(-1, 0, 0), "col": Vector3i(0, 0, 1), "row": Vector3i(0, 1, 0)},
	{"name": "RIGHT +X",  "dir": Vector3i(1, 0, 0),  "col": Vector3i(0, 0, 1), "row": Vector3i(0, 1, 0)},
	{"name": "TOP   +Y",  "dir": Vector3i(0, 1, 0),  "col": Vector3i(1, 0, 0), "row": Vector3i(0, 0, 1)},
	{"name": "BOTTOM −Y", "dir": Vector3i(0, -1, 0), "col": Vector3i(1, 0, 0), "row": Vector3i(0, 0, 1)},
]

const COL_NONE := Color(0.082, 0.235, 0.275, 0.95)
const COL_IN := Color(0.25, 0.72, 0.95, 1.0)
const COL_OUT := Color(1.0, 0.72, 0.25, 1.0)

var _block: FactoryBlock = null
var _blocks_root: Node = null
var _offsets: Array = []          # смещения клеток футпринта от якоря

## Открыть для блока. null — блок не фабричный, односкеточный или не нашли его машину.
static func open_for(host: Node, block: Node) -> PortPicker:
	if not (block is FactoryBlock):
		return null
	var root: Node = block.get_parent()
	while root != null and not root.has_method("set_block_port"):
		root = root.get_parent()
	if root == null:
		return null
	var offs: Array = root.footprint_offsets(block)
	if offs.size() <= 1:
		return null                # односкеточному блоку хватает галочек: настраивать нечего
	var p := PortPicker.new()
	p._block = block as FactoryBlock
	p._blocks_root = root
	p._offsets = offs
	host.add_child(p)
	p._build()
	return p

func _build() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP

	var dim := ColorRect.new()
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.color = Color(0.0, 0.03, 0.04, 0.55)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	dim.gui_input.connect(func(e: InputEvent):
		if (e is InputEventMouseButton and e.pressed) or (e is InputEventScreenTouch and e.pressed):
			close())
	add_child(dim)

	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", _panel_style())
	panel.custom_minimum_size = Vector2(PANEL_W, 0.0)
	panel.set_anchors_preset(Control.PRESET_CENTER)
	panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	panel.grow_vertical = Control.GROW_DIRECTION_BOTH
	add_child(panel)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 6)
	panel.add_child(col)

	var title := Label.new()
	title.text = "PORTS — %s" % G.block_name(int(_block.block))
	title.add_theme_font_size_override("font_size", 20)
	title.add_theme_color_override("font_color", Color(0.62, 0.92, 0.96))
	col.add_child(title)

	var hint := Label.new()
	hint.text = "Tap a cell: off → in → out. Both sides must agree for a link."
	hint.add_theme_font_size_override("font_size", 13)
	hint.add_theme_color_override("font_color", Color(0.55, 0.72, 0.76))
	col.add_child(hint)
	col.add_child(_legend())

	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(0.0, 460.0)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	col.add_child(scroll)
	var list := VBoxContainer.new()
	list.add_theme_constant_override("separation", 4)
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(list)

	for side in SIDES:
		_build_side(list, side)

	var close_btn := Button.new()
	close_btn.text = "CLOSE"
	close_btn.add_theme_font_size_override("font_size", 16)
	close_btn.add_theme_color_override("font_color", Color(0.88, 0.96, 0.98))
	close_btn.add_theme_stylebox_override("normal", _cell_style(COL_NONE))
	close_btn.pressed.connect(close)
	col.add_child(close_btn)

# Клетки ОДНОЙ стороны: те из футпринта, у которых сосед в направлении стороны уже снаружи.
# Внутренние клетки на этой стороне портов иметь не могут — им некуда выходить.
func _build_side(list: VBoxContainer, side: Dictionary) -> void:
	var d: Vector3i = side["dir"]
	var outer: Array = []
	for o in _offsets:
		if not _offsets.has((o as Vector3i) + d):
			outer.append(o)
	if outer.is_empty():
		return
	var cap := Label.new()
	cap.text = String(side["name"])
	cap.add_theme_font_size_override("font_size", 13)
	cap.add_theme_color_override("font_color", Color(0.40, 0.66, 0.70))
	var m := MarginContainer.new()
	m.add_theme_constant_override("margin_top", 8)
	m.add_child(cap)
	list.add_child(m)

	# Раскладываем в сетку по осям стороны, чтобы кнопки стояли так же, как клетки в мире.
	var ca: Vector3i = side["col"]
	var ra: Vector3i = side["row"]
	var cols: Array = []
	var rows: Array = []
	for o in outer:
		var cv: int = _axis(o, ca)
		var rv: int = _axis(o, ra)
		if not cols.has(cv):
			cols.append(cv)
		if not rows.has(rv):
			rows.append(rv)
	cols.sort()
	rows.sort()
	rows.reverse()                 # верхний ряд сетки — верхняя клетка блока
	var grid := GridContainer.new()
	grid.columns = maxi(cols.size(), 1)
	grid.add_theme_constant_override("h_separation", 4)
	grid.add_theme_constant_override("v_separation", 4)
	list.add_child(grid)
	for rv in rows:
		for cv in cols:
			var found: Variant = null
			for o in outer:
				if _axis(o, ca) == cv and _axis(o, ra) == rv:
					found = o
					break
			if found == null:
				var gap := Control.new()
				gap.custom_minimum_size = Vector2(CELL, CELL)
				grid.add_child(gap)
				continue
			grid.add_child(_cell_button(found as Vector3i, d))

func _axis(o: Vector3i, a: Vector3i) -> int:
	return o.x * a.x + o.y * a.y + o.z * a.z

func _cell_button(off: Vector3i, d: Vector3i) -> Button:
	var b := Button.new()
	b.custom_minimum_size = Vector2(CELL, CELL)
	b.add_theme_font_size_override("font_size", 14)
	b.add_theme_color_override("font_color", Color(0.05, 0.10, 0.12))
	var di: int = _block._idx_of(d)
	_paint(b, off, di)
	b.pressed.connect(func():
		# По кругу: ВЫКЛ → ВХОД → ВЫХОД. Три состояния и один жест — выбирать «режим», а
		# потом тыкать в клетки было бы на одно действие больше на каждую правку.
		var next: int = (_block.port_state(off, di) + 1) % 3
		if _blocks_root.set_block_port(_block, off, di, next):
			_paint(b, off, di))
	return b

func _paint(b: Button, off: Vector3i, di: int) -> void:
	var st: int = _block.port_state(off, di)
	var c: Color = COL_NONE
	var t := "—"
	if st == FactoryBlock.PORT_IN:
		c = COL_IN
		t = "IN"
	elif st == FactoryBlock.PORT_OUT:
		c = COL_OUT
		t = "OUT"
	b.text = t
	b.add_theme_stylebox_override("normal", _cell_style(c))
	b.add_theme_stylebox_override("hover", _cell_style(c))
	b.add_theme_stylebox_override("pressed", _cell_style(c))
	b.add_theme_color_override("font_color",
			Color(0.05, 0.10, 0.12) if st != FactoryBlock.PORT_NONE else Color(0.55, 0.75, 0.80))

func _legend() -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	for pair in [[COL_IN, "IN — takes from here"], [COL_OUT, "OUT — sends from here"]]:
		var swatch := ColorRect.new()
		swatch.color = pair[0]
		swatch.custom_minimum_size = Vector2(14, 14)
		row.add_child(swatch)
		var l := Label.new()
		l.text = String(pair[1])
		l.add_theme_font_size_override("font_size", 12)
		l.add_theme_color_override("font_color", Color(0.55, 0.72, 0.76))
		row.add_child(l)
	return row

func close() -> void:
	queue_free()

func _panel_style() -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = Color(0.043, 0.122, 0.149, 0.97)
	s.border_color = Color(0.247, 0.6, 0.65, 0.5)
	s.set_border_width_all(2)
	s.set_corner_radius_all(14)
	s.content_margin_left = 14
	s.content_margin_right = 14
	s.content_margin_top = 12
	s.content_margin_bottom = 12
	return s

func _cell_style(c: Color) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = c
	s.border_color = Color(0.247, 0.6, 0.65, 0.45)
	s.set_border_width_all(1)
	s.set_corner_radius_all(6)
	return s
