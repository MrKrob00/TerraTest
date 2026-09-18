@tool
extends VBoxContainer

# КАРТА МИРА ПРЯМО В ИНСПЕКТОРЕ: меняешь сид — видишь страну, которую он даёт.
#
# Это замена лепке. Кисть существовала, пока карта была файлом высот, который правят руками; с
# процедурной землёй править нечего — есть сид, и вопрос только один: ЧТО ОН ДАЁТ. Раньше ответ
# стоил запуска игры, теперь он рисуется за долю секунды, и десяток сидов можно пролистать
# подряд.
#
# ЧТО ИМЕННО НАРИСОВАНО — МАСКИ БИОМОВ, А НЕ ВЫСОТЫ, и это не экономия, а выбор. Высота в точке
# стоит пяти отсчётов шума с размытием и врезом каньона (LiteTerrainGen.height_at); маска — трёх
# вызовов cv_noise. На 128×128 это разница между «полсекунды» и «пять секунд», то есть между
# «листаю сиды» и «жду». А выбирают сид ИМЕННО ПО СТРАНЕ: где луг, где пустыня, где каньон и где
# горы. Рельеф внутри региона от сида к сиду отличается куда меньше, чем их расположение, и
# смотреть его надо всё равно в 3D — для этого рядом кнопка «Показать в сцене», которая строит
# настоящую землю тем же генератором.
#
# Цвета и масштабы регионов берём из САМОЙ НОДЫ — из её ресурса biomes, того же, по которому мир
# красит шейдер. Своя палитра здесь означала бы карту не того мира.

const PREVIEW_PX := 128           ## сторона картинки в пикселях; растягивается до ширины панели
const SPANS := [1024, 2048, 4096, 8192]   ## сторона участка в метрах

var _node: Node = null            ## ChunkTerrain (или любая нода с biomes + forced_seed)
var _undo = null

var _tex: TextureRect = null
var _seed_spin: SpinBox = null
var _span_idx: int = 1
var _span_btn: OptionButton = null
var _legend: Label = null
var _ruler: Control = null

func setup(n: Node, undo_redo) -> void:
	_node = n
	_undo = undo_redo
	_build_ui()
	_redraw()

# ── Интерфейс ────────────────────────────────────────────────────────────────
func _build_ui() -> void:
	add_theme_constant_override("separation", 4)

	var title := Label.new()
	title.text = "МИР ЭТОГО СИДА"
	title.add_theme_font_size_override("font_size", 11)
	title.modulate = Color(1, 1, 1, 0.7)
	add_child(title)

	# Картинка квадратная и тянется по ширине инспектора: панель узкая, и фиксированный размер
	# либо не влезал бы, либо оставлял половину места пустой.
	_tex = TextureRect.new()
	_tex.custom_minimum_size = Vector2(0, 180)
	_tex.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_tex.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_tex.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	add_child(_tex)

	_legend = Label.new()
	_legend.add_theme_font_size_override("font_size", 10)
	_legend.modulate = Color(1, 1, 1, 0.55)
	_legend.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(_legend)

	# ── Сид ──
	var row := HBoxContainer.new()
	add_child(row)
	var lbl := Label.new()
	lbl.text = "Сид"
	lbl.custom_minimum_size = Vector2(34, 0)
	row.add_child(lbl)

	_seed_spin = SpinBox.new()
	_seed_spin.min_value = 0
	_seed_spin.max_value = 2147483647
	_seed_spin.step = 1
	_seed_spin.value = float(_read_seed())
	_seed_spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_seed_spin.value_changed.connect(_on_seed_changed)
	row.add_child(_seed_spin)

	# Шаг на единицу — чтобы соседний сид можно было посмотреть, не придумывая число.
	row.add_child(_mini("◀", "Предыдущий сид", func() -> void:
		_seed_spin.value = maxf(0.0, _seed_spin.value - 1.0)))
	row.add_child(_mini("▶", "Следующий сид", func() -> void:
		_seed_spin.value = _seed_spin.value + 1.0))
	row.add_child(_mini("RND", "Случайный сид", func() -> void:
		_seed_spin.value = float(randi() & 0x7FFFFFFF)))

	# ── Охват ──
	var srow := HBoxContainer.new()
	add_child(srow)
	var slbl := Label.new()
	slbl.text = "Охват"
	slbl.custom_minimum_size = Vector2(34, 0)
	srow.add_child(slbl)
	_span_btn = OptionButton.new()
	for i in SPANS.size():
		_span_btn.add_item("%d м" % int(SPANS[i]), i)
	_span_btn.selected = _span_idx
	_span_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_span_btn.item_selected.connect(func(i: int) -> void:
		_span_idx = i
		_redraw())
	srow.add_child(_span_btn)

	# ── В сцену ──
	var arow := HBoxContainer.new()
	add_child(arow)
	var show_btn := Button.new()
	show_btn.text = "Показать в сцене"
	show_btn.tooltip_text = "Строит вокруг камеры редактора ту же землю, что увидит игра. В сцену не сохраняется ничего."
	show_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	show_btn.pressed.connect(_on_show)
	arow.add_child(show_btn)
	var clear_btn := Button.new()
	clear_btn.text = "Убрать"
	clear_btn.pressed.connect(func() -> void:
		if _node != null and is_instance_valid(_node) and _node.has_method("preview_clear"):
			_node.preview_clear())
	arow.add_child(clear_btn)

	# Кольца дальности — тот же рисунок, что и карта выше, только про память и загрузку.
	_ruler = RingRuler.new()
	_ruler.node = _node
	add_child(_ruler)

func _mini(text: String, tip: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.tooltip_text = tip
	b.custom_minimum_size = Vector2(30, 0)
	b.pressed.connect(cb)
	return b

# ── Сид ──────────────────────────────────────────────────────────────────────
## Сид, который нода возьмёт БЕЗ игры: forced_seed. В игре его может перебить слот
## (follow_world_settings), и об этом честно говорит подпись под картинкой — иначе превью
## обещало бы мир, которого игрок не увидит.
func _read_seed() -> int:
	if _node == null or not is_instance_valid(_node):
		return 0
	var v = _node.get("forced_seed")
	return int(v) if v != null else 0

func _on_seed_changed(v: float) -> void:
	if _node == null or not is_instance_valid(_node):
		return
	var new_seed := int(v)
	if new_seed == _read_seed():
		_redraw()
		return
	# Через общий стек отмен, как любая правка свойства: Ctrl+Z обязан возвращать сид.
	if _undo != null:
		_undo.create_action("LiteTerrain: seed")
		_undo.add_do_property(_node, "forced_seed", new_seed)
		_undo.add_undo_property(_node, "forced_seed", _read_seed())
		_undo.commit_action()
	else:
		_node.set("forced_seed", new_seed)
	_redraw()

## Строим вокруг КАМЕРЫ РЕДАКТОРА, поэтому сначала отдаём её ноде: своей камеры в редакторе у
## неё нет, а без точки обзора первое кольцо встало бы в начале координат — то есть, скорее
## всего, не там, куда смотрят.
func _on_show() -> void:
	if _node == null or not is_instance_valid(_node) or not _node.has_method("preview_build"):
		return
	var vp := EditorInterface.get_editor_viewport_3d(0)
	var cam: Camera3D = vp.get_camera_3d() if vp != null else null
	if cam != null and _node.has_method("set_editor_camera"):
		_node.set_editor_camera(cam)
	_node.preview_build(_read_seed())

# ── Отрисовка карты ──────────────────────────────────────────────────────────
## Цвет пикселя собирается из трёх масок ровно в том порядке, в каком их накладывает сам мир:
## луг поверх песка, каньон поверх них, горы сверху всего. Тени — от «купола» гор
## (mountain_dome): это единственная величина, которая даёт рельеф, не считая высоту.
func _redraw() -> void:
	if _tex == null or _node == null or not is_instance_valid(_node):
		return
	var b: TerrainBiomes = _node.get("biomes") as TerrainBiomes
	if b == null:
		b = TerrainBiomes.new()
	var span: float = float(SPANS[_span_idx])
	var step: float = span / float(PREVIEW_PX)
	var half: float = span * 0.5

	# Сид сдвигает МАСКИ, и сдвиг берём ТОЙ ЖЕ ФУНКЦИЕЙ, что и генератор
	# (TerrainBiomes.offset_for_seed): своя копия формулы здесь означала бы, что на одном сиде
	# превью и игра рисуют разные страны — ровно та ошибка, ради которой превью и заводят.
	var work: TerrainBiomes = b.duplicate() as TerrainBiomes
	work.mask_offset = TerrainBiomes.offset_for_seed(_read_seed())
	# Один Callable на весь проход: маски зовут его трижды на пиксель, и создавать его в цикле
	# значило бы наплодить полсотни тысяч штук. Берём МЕТОД РЕСУРСА (TerrainBiomes.noise), а не
	# статическую функцию по имени — так же, как это делает отбор сидов у фона меню.
	var cv: Callable = work.noise

	var img := Image.create(PREVIEW_PX, PREVIEW_PX, false, Image.FORMAT_RGB8)
	for j in PREVIEW_PX:
		var wz: float = -half + float(j) * step
		for i in PREVIEW_PX:
			var wp := Vector2(-half + float(i) * step, wz)
			img.set_pixel(i, j, _colour_at(work, wp, cv))
	_mark_origin(img)
	_tex.texture = ImageTexture.create_from_image(img)

	var follows: bool = _node.get("follow_world_settings") == true
	_legend.text = "%d×%d м · маски биомов, не высоты%s" % [
		int(span), int(span),
		"\nВ ИГРЕ сид берётся из слота — это превью только для редактора." if follows else ""]

func _colour_at(b: TerrainBiomes, wp: Vector2, cv: Callable) -> Color:
	var meadow: float = b.meadow_mask(wp, cv)
	var canyon: float = b.canyon_mask(wp, cv)
	var mtn: float = b.mountain_mask(wp, cv)
	var dome: float = b.mountain_dome(wp, cv)
	var c: Color = b.color_sand.lerp(b.color_grass, meadow)
	c = c.lerp(b.color_canyon, canyon * (1.0 - mtn))
	c = c.lerp(b.color_rock, mtn)
	# Снег на вершинах купола: без него горы читаются плоским серым пятном, а на карте их узнают
	# именно по белой шапке.
	c = c.lerp(b.color_snow, clampf((dome - 0.75) * 4.0, 0.0, 1.0))
	# Затенение по куполу — дешёвый намёк на объём: середина массива светлее его краёв.
	return c * (0.82 + 0.28 * dome)

## Крест в середине: превью всегда центрировано на начале координат ноды, и без метки нельзя
## сказать, где на этой карте окажется игрок.
func _mark_origin(img: Image) -> void:
	var c: int = PREVIEW_PX / 2
	var col := Color(1, 1, 1, 1)
	for d in range(-4, 5):
		if absi(d) <= 1:
			continue
		img.set_pixel(clampi(c + d, 0, PREVIEW_PX - 1), c, col)
		img.set_pixel(c, clampi(c + d, 0, PREVIEW_PX - 1), col)

# ── КОЛЬЦА ДАЛЬНОСТИ ─────────────────────────────────────────────────────────
# Четыре числа в инспекторе — view_distance, keep_radius, ready_view и радиус коллизии — это на
# самом деле ОДИН рисунок: вложенные круги вокруг игрока. По списку чисел их соотношение не
# читается вовсе, а именно оно и решает: держать в памяти больше, чем рисуем, бессмысленно;
# ждать на загрузке дальше, чем держим, — тоже. Полоска показывает все четыре в масштабе, и
# перевёрнутый порядок виден сразу, без запуска.
class RingRuler extends Control:
	var node: Node = null
	const ROWS := [
		["коллизия", "collision_radius", Color(0.95, 0.45, 0.35), 16.0],   # в КЛЕТКАХ → метры
		["загрузка", "ready_view",       Color(1.00, 0.78, 0.25), 1.0],
		["в памяти", "keep_radius",      Color(0.35, 0.80, 0.55), 1.0],
		["видно",    "view_distance",    Color(0.40, 0.70, 0.95), 1.0],
	]

	func _init() -> void:
		custom_minimum_size = Vector2(0, 74)

	func _draw() -> void:
		if node == null or not is_instance_valid(node):
			return
		var vals: Array = []
		var top: float = 1.0
		for r in ROWS:
			var v = node.get(String(r[1]))
			# Клетка коллизии — не метр: радиус задан в клетках чанка, и без множителя красная
			# полоска врала бы в шестнадцать раз.
			var m: float = (float(v) * float(r[3])) if v != null else 0.0
			vals.append(m)
			top = maxf(top, m)
		var font := get_theme_default_font()
		var fs := 10
		var bar_x := 74.0
		var w: float = maxf(size.x - bar_x - 46.0, 20.0)
		for i in ROWS.size():
			var y: float = 4.0 + float(i) * 17.0
			draw_string(font, Vector2(0, y + 9), String(ROWS[i][0]),
					HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(1, 1, 1, 0.65))
			draw_rect(Rect2(bar_x, y, w, 10.0), Color(1, 1, 1, 0.07), true)
			var frac: float = clampf(float(vals[i]) / top, 0.0, 1.0)
			draw_rect(Rect2(bar_x, y, w * frac, 10.0), ROWS[i][2], true)
			draw_string(font, Vector2(bar_x + w + 4.0, y + 9), "%d м" % int(vals[i]),
					HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(1, 1, 1, 0.8))
