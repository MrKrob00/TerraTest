extends Control
class_name FactoryPicker

# ВЫБОР ПРОДУКТА фабричного блока — что варит Component Factory и что штампует фабрикатор.
#
# До этого окна выбор жил только в @export'е сцены: в игре сменить его было НЕЛЬЗЯ, то есть
# все компонентные заводы мира вечно делали Wound Coil, а все фабрикаторы — простой блок.
# С двадцатью одним компонентом это перестало быть мелким неудобством: без выбора недоступны
# двадцать из них и почти все рецепты блоков.
#
# Окно строится КОДОМ, как и остальной UI проекта (шрифт не рендерит эмодзи, иконки рисуем
# сами). Цветной квадратик слева — это цвет самого материала (G.COMP_COLOR), тот же, каким
# деталь выглядит на ленте: выбирать по цвету быстрее, чем читать двадцать одно название.

const PANEL_W: float = 460.0
const PANEL_MAX_H: float = 560.0
const SWATCH: int = 20

var _block: Node = null                  # фабричный блок, которому меняем продукт
var _blocks_root: Node = null            # узел blocks его машины (через него настройка живёт в сейве)
var _is_comp: bool = false               # true — компонентный завод, false — фабрикатор
var _list: VBoxContainer = null
var _title: Label = null

## Открыть окно для блока. null — блок не фабрика с выбором либо не нашли его машину.
static func open_for(host: Node, block: Node) -> FactoryPicker:
	if block == null or not is_instance_valid(block):
		return null
	var comp: bool = "output_comp" in block
	if not comp and not ("output_block" in block):
		return null
	# Машина нужна не для красоты: сохранять выбор умеет только карта блоков (blocks.gd),
	# на самом узле он не пережил бы загрузку.
	var root: Node = block.get_parent()
	while root != null and not root.has_method("set_factory_output"):
		root = root.get_parent()
	if root == null:
		return null
	var p := FactoryPicker.new()
	p._block = block
	p._blocks_root = root
	p._is_comp = comp
	host.add_child(p)
	p._build()
	return p

func _build() -> void:
	PortPicker._fill_parent(self)
	mouse_filter = Control.MOUSE_FILTER_STOP     # окно ловит тапы, мир под ним не трогаем

	# Затемнение: и читаемость, и «клик мимо окна = закрыть».
	var dim := ColorRect.new()
	PortPicker._fill_parent(dim)
	dim.color = Color(0.0, 0.03, 0.04, 0.55)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	dim.gui_input.connect(func(e: InputEvent):
		if (e is InputEventMouseButton and e.pressed) or (e is InputEventScreenTouch and e.pressed):
			close())
	add_child(dim)

	# По центру — контейнером, а не якорями: панель растёт до минимального размера уже после
	# того, как смещения посчитаны, и на якорях окно оказывалось в левом верхнем углу.
	var center := CenterContainer.new()
	PortPicker._fill_parent(center)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center)

	var vp: Vector2 = get_viewport_rect().size
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", _panel_style())
	panel.custom_minimum_size = Vector2(minf(PANEL_W, vp.x - 48.0), 0.0)
	center.add_child(panel)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 8)
	panel.add_child(col)

	_title = Label.new()
	_title.add_theme_font_size_override("font_size", 20)
	_title.add_theme_color_override("font_color", Color(0.62, 0.92, 0.96))
	col.add_child(_title)

	var hint := Label.new()
	hint.text = "Pick what this machine produces."
	hint.add_theme_font_size_override("font_size", 13)
	hint.add_theme_color_override("font_color", Color(0.55, 0.72, 0.76))
	col.add_child(hint)

	var scroll := ScrollContainer.new()
	# Список ограничен ЭКРАНОМ: двадцать один компонент или четыре десятка блоков длиннее
	# любого окна, а зашитая высота на низком экране выносила кнопку CLOSE за край.
	scroll.custom_minimum_size = Vector2(0.0, clampf(vp.y - 240.0, 180.0, PANEL_MAX_H))
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	col.add_child(scroll)

	_list = VBoxContainer.new()
	_list.add_theme_constant_override("separation", 4)
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_list)

	var close_btn := Button.new()
	close_btn.text = "CLOSE"
	close_btn.add_theme_font_size_override("font_size", 16)
	close_btn.add_theme_color_override("font_color", Color(0.88, 0.96, 0.98))
	close_btn.add_theme_stylebox_override("normal", _button_style(false))
	close_btn.add_theme_stylebox_override("hover", _button_style(true))
	close_btn.add_theme_stylebox_override("pressed", _button_style(true))
	close_btn.pressed.connect(close)
	col.add_child(close_btn)

	if _is_comp:
		_fill_components()
	else:
		_fill_blocks()
	_refresh_title()

func _refresh_title() -> void:
	if _title == null:
		return
	var cur: int = _current()
	if _is_comp:
		_title.text = "COMPONENT FACTORY — %s" % G.kind_name(G.comp_key(cur))
	else:
		_title.text = "FABRICATOR — %s" % G.block_name(cur)

func _current() -> int:
	if not is_instance_valid(_block):
		return 0
	return int(_block.get("output_comp" if _is_comp else "output_block"))

# ── Наполнение: компоненты ───────────────────────────────────────────────────
# Два раздела ровно по ярусам (G.COMP_SIMPLE_COUNT): первый варится из слитков, второй — из
# первого, и смешивать их в один список значило бы прятать это правило от игрока.
func _fill_components() -> void:
	_section("BASIC — from ingots")
	for i in G.COMP_SIMPLE_COUNT:
		_row(i, G.kind_name(G.comp_key(i)), G.recipe_text(G.COMP_RECIPE.get(i, {})),
				G.COMP_COLOR[i] if i < G.COMP_COLOR.size() else Color.WHITE)
	_section("ADVANCED — from basic components")
	for i in range(G.COMP_SIMPLE_COUNT, G.COMP_NAME.size()):
		_row(i, G.kind_name(G.comp_key(i)), G.recipe_text(G.COMP_RECIPE.get(i, {})),
				G.COMP_COLOR[i] if i < G.COMP_COLOR.size() else Color.WHITE)

# ── Наполнение: блоки ────────────────────────────────────────────────────────
# Разделы — те же категории, что в гараже и в глобусе стройки (G.BLOCK_CATEGORIES): третьего
# способа группировать блоки в проекте быть не должно, иначе они разъедутся.
func _fill_blocks() -> void:
	var shown: Dictionary = {}
	for key in G.BLOCK_CATEGORIES:
		var names: Array = []
		for bt in G.BLOCK_CATEGORIES[key]:
			if G.block_recipe(int(bt)).is_empty():
				continue                       # рецепта нет — собрать нельзя, в списке не место
			names.append(int(bt))
			shown[int(bt)] = true
		if names.is_empty():
			continue
		_section(String(key).to_upper())
		for bt in names:
			_row(bt, G.block_name(bt), G.recipe_text(G.block_recipe(bt)), Color(0.55, 0.78, 0.82))
	# Всё, что не попало ни в одну категорию, — «прочее»: иначе блок с рецептом молча
	# исчез бы из выбора, и понять это можно было бы только по отсутствию в списке.
	var rest: Array = []
	for bt in G.BLOCK_RECIPE:
		if not shown.has(int(bt)):
			rest.append(int(bt))
	if not rest.is_empty():
		_section("OTHER")
		for bt in rest:
			_row(bt, G.block_name(bt), G.recipe_text(G.block_recipe(bt)), Color(0.55, 0.78, 0.82))

func _section(text: String) -> void:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", 13)
	l.add_theme_color_override("font_color", Color(0.40, 0.66, 0.70))
	var m := MarginContainer.new()
	m.add_theme_constant_override("margin_top", 8)
	m.add_child(l)
	_list.add_child(m)

func _row(idx: int, name: String, recipe: String, tint: Color) -> void:
	var b := Button.new()
	b.text = "  %s\n  %s" % [name, recipe]
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.icon = _swatch(tint)
	b.expand_icon = false
	b.add_theme_font_size_override("font_size", 15)
	b.add_theme_color_override("font_color", Color(0.88, 0.96, 0.98))
	var on: bool = idx == _current()
	b.add_theme_stylebox_override("normal", _button_style(on))
	b.add_theme_stylebox_override("hover", _button_style(true))
	b.add_theme_stylebox_override("pressed", _button_style(true))
	b.pressed.connect(func(): _choose(idx))
	_list.add_child(b)

func _choose(idx: int) -> void:
	if not is_instance_valid(_block) or not is_instance_valid(_blocks_root):
		close()
		return
	if _blocks_root.set_factory_output(_block, idx):
		close()

func close() -> void:
	queue_free()

# ── Мелочи оформления ────────────────────────────────────────────────────────
# Квадратик цвета материала. Кешируем по цвету: в списке из двадцати одной строки иначе
# родилось бы двадцать одно изображение на каждое открытие окна.
static var _swatches: Dictionary = {}

static func _swatch(c: Color) -> ImageTexture:
	var key := c.to_rgba32()
	var cached = _swatches.get(key)
	if cached != null:
		return cached
	var img := Image.create(SWATCH, SWATCH, false, Image.FORMAT_RGBA8)
	img.fill(c)
	var tex := ImageTexture.create_from_image(img)
	_swatches[key] = tex
	return tex

# Палитра и скругления — как у плавающих панелей HUD (_make_float_panel_style): окно должно
# выглядеть частью того же интерфейса, а не гостем из другого проекта.
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

func _button_style(active: bool) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = Color(0.247, 0.6, 0.65, 1.0) if active else Color(0.082, 0.235, 0.275, 0.95)
	s.border_color = Color(0.247, 0.6, 0.65, 0.45)
	s.set_border_width_all(1)
	s.set_corner_radius_all(6)
	s.content_margin_left = 8
	s.content_margin_right = 8
	s.content_margin_top = 8
	s.content_margin_bottom = 8
	return s
