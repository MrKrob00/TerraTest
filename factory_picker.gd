extends Control
class_name FactoryPicker

# ВЫБОР ПРОДУКТА фабричного блока — что варит Component Factory и что штампует фабрикатор.
#
# Текущий список давно разросся до масштаба, где он мешает игре: он длинный, тяжёлый и
# не даёт быстро понять, что сейчас выбрано. Поэтому на этом этапе меняем вертикальный список
# на круговой выбор, но оставляем старый контракт API (set_factory_output / output_comp /
# output_block) неизменным, чтобы существующие фабрики продолжали работать без переписывания
# всего проекта.
const SCENE_PATH := "res://factory_picker.tscn"
const PANEL_W: float = 460.0
const PANEL_MAX_H: float = 560.0
const SWATCH: int = 20

var _block: Node = null
var _blocks_root: Node = null
var _is_comp: bool = false
var _title: Label = null
var _entries: Array = []
var _wheel: Node = null

static func open_for(host: Node, block: Node) -> FactoryPicker:
	if block == null or not is_instance_valid(block):
		return null
	var comp: bool = "output_comp" in block
	if not comp and not ("output_block" in block):
		return null
	var root: Node = block.get_parent()
	while root != null and not root.has_method("set_factory_output"):
		root = root.get_parent()
	if root == null:
		return null
	var p: FactoryPicker = (load(SCENE_PATH) as PackedScene).instantiate()
	p._block = block
	p._blocks_root = root
	p._is_comp = comp
	host.add_child(p)
	p._build()
	return p

func _build() -> void:
	var vp: Vector2 = get_viewport_rect().size
	(%Panel as PanelContainer).custom_minimum_size = Vector2(minf(PANEL_W, vp.x - 48.0), 0.0)
	(%Scroll as ScrollContainer).custom_minimum_size = Vector2(0.0, clampf(vp.y - 240.0, 180.0, PANEL_MAX_H))
	_title = %Title
	(%Dim as ColorRect).gui_input.connect(func(e: InputEvent):
		if (e is InputEventMouseButton and e.pressed) or (e is InputEventScreenTouch and e.pressed):
			close())
	(%CloseButton as Button).pressed.connect(close)
	var ports := %PortsButton as Button
	ports.visible = _blocks_root.has_method("footprint_offsets") and _block is FactoryBlock and (_blocks_root.footprint_offsets(_block) as Array).size() > 1
	ports.pressed.connect(_open_ports)
	_entries = _build_entries()
	_build_wheel()
	_refresh_title()

func _build_wheel() -> void:
	var scroll: ScrollContainer = %Scroll
	for child in scroll.get_children():
		if is_instance_valid(child):
			child.queue_free()
	var wheel := FactoryPickerWheel.new()
	wheel.name = "Wheel"
	wheel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	wheel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	wheel.custom_minimum_size = Vector2(0.0, clampf(get_viewport_rect().size.y - 240.0, 180.0, PANEL_MAX_H))
	wheel.setup(_entries, _entry_index_for_current(), func(idx: int): _choose(_entries[idx].get("id", 0)))
	scroll.add_child(wheel)
	_wheel = wheel

func _entry_index_for_current() -> int:
	var cur: int = _current()
	for i in _entries.size():
		if int(_entries[i].get("id", -1)) == cur:
			return i
	return 0

func _build_entries() -> Array:
	if _is_comp:
		var out: Array = []
		for i in G.COMP_NAME.size():
			out.append({
				"id": i,
				"name": G.kind_name(G.comp_key(i)),
				"category": "basic" if i < G.COMP_SIMPLE_COUNT else "advanced",
				"recipe": (G.COMP_RECIPE.get(i, {}) as Dictionary).duplicate(),
				"color": G.COMP_COLOR[i] if i < G.COMP_COLOR.size() else Color.WHITE,
			})
		return out
	var lists: Dictionary = {}
	var shown: Dictionary = {}
	for key in G.BLOCK_CATEGORIES:
		var names: Array = []
		for bt in G.BLOCK_CATEGORIES[key]:
			if G.block_recipe(int(bt)).is_empty():
				continue
			names.append(int(bt))
			shown[int(bt)] = true
		lists[key] = names
	for bt in G.BLOCK_RECIPE:
		if not shown.has(int(bt)):
			if not lists.has("power"):
				lists["power"] = []
			(lists["power"] as Array).append(int(bt))
	var out: Array = []
	for key in lists:
		var names: Array = lists[key]
		if names.is_empty():
			continue
		for bt in names:
			out.append({
				"id": int(bt),
				"name": G.block_name(int(bt)),
				"category": String(key),
				"recipe": G.block_recipe(int(bt)),
				"color": Color(0.55, 0.78, 0.82),
			})
	return out

func _refresh_title() -> void:
	if _title == null:
		return
	var cur: int = _current()
	if _is_comp:
		_title.text = tr("COMPONENT FACTORY") + " — %s" % G.kind_name(G.comp_key(cur))
	else:
		_title.text = tr("FABRICATOR") + " — %s" % G.block_name(cur)

func _current() -> int:
	if not is_instance_valid(_block):
		return 0
	return int(_block.get("output_comp" if _is_comp else "output_block"))

func _choose(idx: int) -> void:
	if not is_instance_valid(_block) or not is_instance_valid(_blocks_root):
		close()
		return
	if _blocks_root.set_factory_output(_block, idx):
		close()

func close() -> void:
	queue_free()

func _open_ports() -> void:
	var host: Node = get_parent()
	var block: Node = _block
	close()
	if host != null and is_instance_valid(block):
		var p = PortPicker.open_for(host, block)
		if p != null and host.get("_factory_picker") != null:
			host.set("_factory_picker", p)

# Legacy list helpers kept for compatibility with older scenes or future fallback logic.
func _fill_components() -> void:
	_entries = _build_entries()
	if _wheel != null:
		(_wheel as FactoryPickerWheel).setup(_entries, _entry_index_for_current(), func(idx: int): _choose(_entries[idx].get("id", 0)))

func _fill_blocks() -> void:
	_entries = _build_entries()
	if _wheel != null:
		(_wheel as FactoryPickerWheel).setup(_entries, _entry_index_for_current(), func(idx: int): _choose(_entries[idx].get("id", 0)))

func _section(text: String) -> void:
	pass

func _row(idx: int, title: String, recipe: String, tint: Color) -> void:
	pass

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
