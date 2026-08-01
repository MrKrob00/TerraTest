extends CanvasLayer
## Глючный загрузочный экран (лор «цифровой симуляции»). Всё РИСУЕТСЯ В КОДЕ — без ассетов:
## RGB-сплит названия WorldTech с джиттером, сканлайны, случайные цианово-магентовые глитч-полосы
## (та же палитра, что у зон корруптации на рельефе), псевдо-прогресс-бар. Показывается `duration`
## секунд, затем плавно гаснет и сам себя удаляет. Слой поверх всего (включая HUD). Ввод блокирует.

@export var duration: float = 2.8          # сколько показывать до фейда
@export var fade_time: float = 0.7
@export var title_text: String = "WorldTech"
@export var subtitle_text: String = "unofficial TerraTech port"

const CYAN := Color(0.15, 0.85, 1.0)
const MAGENTA := Color(0.72, 0.16, 1.0)

var _root: Control
var _titles: Array[Label] = []             # [циан, магента, белый] — RGB-сплит
var _sub: Label
var _load: Label
var _bar: ColorRect
var _bar_bg: ColorRect
var _glitch: Control
var _t: float = 0.0
var _fading := false

func _ready() -> void:
	layer = 128
	process_mode = Node.PROCESS_MODE_ALWAYS

	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_STOP     # блокируем тапы под экраном на время загрузки
	add_child(_root)

	var bg := ColorRect.new()
	bg.color = Color(0.02, 0.03, 0.06)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(bg)

	_glitch = _GlitchFx.new()
	_glitch.set_anchors_preset(Control.PRESET_FULL_RECT)
	_glitch.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_glitch)

	for col in [CYAN, MAGENTA, Color(0.95, 0.98, 1.0)]:
		var l := Label.new()
		l.text = title_text
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		l.add_theme_font_size_override("font_size", 96)
		l.add_theme_color_override("font_color", col)
		l.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_root.add_child(l)
		_titles.append(l)

	_sub = _mk_label(subtitle_text, 20, Color(0.6, 0.75, 0.85, 0.85))
	_load = _mk_label("LOADING", 16, CYAN)

	_bar_bg = ColorRect.new()
	_bar_bg.color = Color(1, 1, 1, 0.08)
	_bar_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_bar_bg)
	_bar = ColorRect.new()
	_bar.color = CYAN
	_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_bar)

	_layout()
	get_viewport().size_changed.connect(_layout)

func _mk_label(txt: String, fsize: int, col: Color) -> Label:
	var l := Label.new()
	l.text = txt
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.add_theme_font_size_override("font_size", fsize)
	l.add_theme_color_override("font_color", col)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(l)
	return l

func _layout() -> void:
	var s := get_viewport().get_visible_rect().size
	for l in _titles:
		l.size = Vector2(s.x, 120)
		l.position = Vector2(0, s.y * 0.5 - 100.0)
	_sub.size = Vector2(s.x, 28);  _sub.position = Vector2(0, s.y * 0.5 + 26.0)
	_load.size = Vector2(s.x, 22); _load.position = Vector2(0, s.y - 84.0)
	var bw: float = minf(s.x * 0.5, 460.0)
	_bar_bg.size = Vector2(bw, 4); _bar_bg.position = Vector2((s.x - bw) * 0.5, s.y - 56.0)
	_bar.size = Vector2(0, 4);     _bar.position = _bar_bg.position

func _process(delta: float) -> void:
	_t += delta
	var s := get_viewport().get_visible_rect().size
	var base_y: float = s.y * 0.5 - 100.0
	# RGB-сплит: базовый джиттер + редкий резкий глитч-сдвиг по X и Y.
	var dx: float = 2.0 + absf(sin(_t * 9.0)) * 2.5
	var gx: float = randf_range(-16.0, 16.0) if randf() < 0.05 else 0.0
	var gy: float = randf_range(-6.0, 6.0) if randf() < 0.04 else 0.0
	_titles[0].position = Vector2(-dx + gx, base_y + gy)          # циан
	_titles[1].position = Vector2(dx - gx * 0.6, base_y - gy)     # магента
	_titles[2].position = Vector2(gx * 0.25, base_y)             # белый
	_titles[2].modulate.a = 0.85 + randf() * 0.15               # мерцание белого слоя
	# «LOADING…» с бегущими точками + псевдо-прогресс.
	_load.text = "LOADING" + ".".repeat(int(_t * 2.0) % 4)
	_bar.size.x = _bar_bg.size.x * clampf(_t / maxf(duration, 0.01), 0.0, 1.0)
	_glitch.queue_redraw()
	# Фейд-аут по времени, затем самоудаление.
	if _t >= duration:
		_fading = true
	if _fading:
		_root.modulate.a = maxf(_root.modulate.a - delta / maxf(fade_time, 0.01), 0.0)
		if _root.modulate.a <= 0.001:
			queue_free()

# Слой глитч-эффектов: сканлайны + случайные цианово-магентовые полосы (перерисовка каждый кадр).
class _GlitchFx extends Control:
	func _draw() -> void:
		var s := size
		var y: float = 0.0
		while y < s.y:
			draw_line(Vector2(0, y), Vector2(s.x, y), Color(0, 0, 0, 0.13), 1.0)
			y += 3.0
		for i in 6:
			if randf() < 0.5:
				var col := Color(0.15, 0.85, 1.0) if randf() < 0.5 else Color(0.72, 0.16, 1.0)
				col.a = randf_range(0.05, 0.16)
				draw_rect(Rect2(randf_range(-30.0, 30.0), randf() * s.y, s.x + 60.0, randf_range(2.0, 9.0)), col)
