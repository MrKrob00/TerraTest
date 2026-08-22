extends Control
class_name PortPicker

# ПОРТЫ многоклеточного фабричного блока: показываем, какая клетка какой стороны — вход, а
# какая — выход. ТОЛЬКО ПОКАЗЫВАЕМ: настраиваются они в сцене блока (плагин addons/blockfaces),
# и в игре их менять нельзя — см. комментарий у куба ниже.
#
# У односкеточного блока сторона и есть коннектор. А у блока 2×2×2 одна сторона это ЧЕТЫРЕ
# клетки, и «вход слева» означало бы вход во все четыре левые клетки сразу: подвести две разные
# ленты с одной стороны было бы нельзя — ради этого поклеточность и делалась.
#
# Окно показывает САМ БЛОК кубиком (port_cube.gd). Кубов два, они смотрят с противоположных
# углов, поэтому все шесть сторон видны сразу и вертеть ничего не нужно.
#
# Грани здесь — в осях КАРТЫ, как и сами порты (см. FactoryBlock): футпринт многоклеточного
# блока от поворота не зависит, и показывать его в локальных осях значило бы врать игроку
# про то, где у блока «лево».

const PANEL_W: float = 460.0

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
	_fill_parent(self)
	mouse_filter = Control.MOUSE_FILTER_STOP

	var dim := ColorRect.new()
	_fill_parent(dim)
	dim.color = Color(0.0, 0.03, 0.04, 0.55)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	dim.gui_input.connect(func(e: InputEvent):
		if (e is InputEventMouseButton and e.pressed) or (e is InputEventScreenTouch and e.pressed):
			close())
	add_child(dim)

	# Окно ставит по центру КОНТЕЙНЕР, а не якоря. На якорях оно уезжало в левый верхний угол
	# и наполовину за экран: панель растёт до своего минимального размера уже ПОСЛЕ того, как
	# смещения посчитаны, и пересчитывать их под новый размер некому. CenterContainer делает
	# это сам на каждое изменение содержимого, и от порядка вызовов не зависит.
	var center := CenterContainer.new()
	_fill_parent(center)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE   # тап мимо окна обязан дойти до затемнения
	add_child(center)

	var vp: Vector2 = get_viewport_rect().size
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", _panel_style())
	panel.custom_minimum_size = Vector2(minf(PANEL_W, vp.x - 48.0), 0.0)
	center.add_child(panel)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 6)
	panel.add_child(col)

	var title := Label.new()
	title.text = "PORTS — %s" % G.block_name(int(_block.block))
	title.add_theme_font_size_override("font_size", 20)
	title.add_theme_color_override("font_color", Color(0.62, 0.92, 0.96))
	col.add_child(title)

	var hint := Label.new()
	hint.text = "View only — ports are set on the block itself. Both sides must agree for a link."
	hint.add_theme_font_size_override("font_size", 13)
	hint.add_theme_color_override("font_color", Color(0.55, 0.72, 0.76))
	col.add_child(hint)
	col.add_child(_legend())

	# САМ БЛОК, а не список сторон. Шесть подписанных сеток заставляли держать в голове, где
	# у блока «зад» и «низ», и сверять это с тем, как он стоит на машине. На кубе тыкаешь в
	# ту грань, которую видишь; два куба смотрят с противоположных углов, поэтому видны все
	# шесть сторон сразу и крутить ничего не надо.
	var cube := PortCube.new()
	cube.cells = _offsets
	cube.custom_minimum_size = Vector2(0.0, clampf(vp.y - 260.0, 170.0, 380.0))
	cube.size_flags_vertical = Control.SIZE_EXPAND_FILL
	cube.state_of = func(off: Vector3i, di: int) -> int:
		return _block.port_state(off, di) if is_instance_valid(_block) else 0
	# on_click НЕ ставим намеренно: в игре окно только ПОКАЗЫВАЕТ, где у блока вход и выход.
	# Стороны блока — свойство самого блока, а не машины: их задают в сцене (плагин
	# addons/blockfaces), и цепочку строят под известную деталь, а не перенастраивают деталь
	# под цепочку. Правка в игре означала бы, что один и тот же блок у двух игроков работает
	# по-разному, а разбирать конвейер, который «почему-то не идёт», пришлось бы вслепую.
	col.add_child(cube)

	var close_btn := Button.new()
	close_btn.text = "CLOSE"
	close_btn.add_theme_font_size_override("font_size", 16)
	close_btn.add_theme_color_override("font_color", Color(0.88, 0.96, 0.98))
	close_btn.add_theme_stylebox_override("normal", _cell_style(COL_NONE))
	close_btn.pressed.connect(close)
	col.add_child(close_btn)

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

## Растянуть узел на весь родитель ЯВНО, числами. Пресеты считают смещения от ТЕКУЩЕГО
## прямоугольника узла, а у только что созданного Control он нулевой — окно так и оставалось
## размером 0×0 в углу экрана вместе со всем, что в нём лежит.
static func _fill_parent(c: Control) -> void:
	c.anchor_left = 0.0
	c.anchor_top = 0.0
	c.anchor_right = 1.0
	c.anchor_bottom = 1.0
	c.offset_left = 0.0
	c.offset_top = 0.0
	c.offset_right = 0.0
	c.offset_bottom = 0.0

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
