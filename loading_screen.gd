extends CanvasLayer
## СТОЙКИЙ оверлей загрузки. Его поднимает loading_boot (главная сцена) и добавляет прямо в root —
## поэтому он ПЕРЕЖИВАЕТ смену сцены (change_scene освобождает только current_scene, не соседей root).
##
## Порядок: потоково грузим игровую сцену → меняем на неё → ДЕРЖИМСЯ сверху (слой 200), пока карта
## не построит ближний террейн (map.terrain_ready) → гаснем и удаляемся. Так экран крутится ВСЁ время
## загрузки: и парсинг ресурсов, и ~15с генерации террейна (раньше она шла на чёрном экране, т.к.
## происходит в _ready карты уже ПОСЛЕ смены сцены). Всё рисуется в коде, без ассетов.

var next_scene: String = "res://node_3d.tscn"

const CYAN := Color(0.15, 0.85, 1.0)
const MAGENTA := Color(0.72, 0.16, 1.0)

var _ui: Control
var _titles: Array[Label] = []
var _load: Label
var _bar: ColorRect
var _bar_bg: ColorRect
var _glitch: Control
var _t: float = 0.0
var _progress: float = 0.0
var _phase: int = 0        # 0=грузим ресурс, 1=ждём террейн, 2=гаснем
var _wait: float = 0.0
var _dissolve: float = 0.0 # 0→1 «глитч-развал» при исчезновении (как снос блока)

func _ready() -> void:
	layer = 200
	process_mode = Node.PROCESS_MODE_ALWAYS

	_ui = Control.new()
	_ui.set_anchors_preset(Control.PRESET_FULL_RECT)
	_ui.mouse_filter = Control.MOUSE_FILTER_STOP           # блокируем ввод под экраном
	add_child(_ui)

	var bg := ColorRect.new()
	bg.color = Color(0.02, 0.03, 0.06)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ui.add_child(bg)

	_glitch = _GlitchFx.new()
	_glitch.set_anchors_preset(Control.PRESET_FULL_RECT)
	_glitch.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ui.add_child(_glitch)

	# RGB-сплит в СИНЕ-ГОЛУБЫХ тонах (без магенты): глубокий синий ↔ голубой ↔ бело-голубой.
	# «Мультяшность» даёт толстая ТЁМНО-СИНЯЯ обводка (как у логотипов из мультиков).
	for col in [Color(0.20, 0.48, 1.0), Color(0.15, 0.85, 1.0), Color(0.80, 0.95, 1.0)]:
		var l := Label.new()
		l.text = "WorldTech"
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		l.add_theme_font_size_override("font_size", 104)
		l.add_theme_color_override("font_color", col)
		l.add_theme_constant_override("outline_size", 12)
		l.add_theme_color_override("font_outline_color", Color(0.03, 0.09, 0.22))
		l.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_ui.add_child(l)
		_titles.append(l)

	_load = _mk("LOADING", 16, CYAN)

	_bar_bg = ColorRect.new()
	_bar_bg.color = Color(1, 1, 1, 0.08)
	_bar_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ui.add_child(_bar_bg)
	_bar = ColorRect.new()
	_bar.color = CYAN
	_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ui.add_child(_bar)

	_layout()
	get_viewport().size_changed.connect(_layout)
	ResourceLoader.load_threaded_request(next_scene)

func _mk(txt: String, fsize: int, col: Color) -> Label:
	var l := Label.new()
	l.text = txt
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.add_theme_font_size_override("font_size", fsize)
	l.add_theme_color_override("font_color", col)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ui.add_child(l)
	return l

func _layout() -> void:
	var s := get_viewport().get_visible_rect().size
	for l in _titles:
		l.size = Vector2(s.x, 150)
		l.position = Vector2(0, s.y * 0.5 - 95.0)
	_load.size = Vector2(s.x, 22); _load.position = Vector2(0, s.y - 84.0)
	var bw: float = minf(s.x * 0.5, 460.0)
	_bar_bg.size = Vector2(bw, 4); _bar_bg.position = Vector2((s.x - bw) * 0.5, s.y - 56.0)
	_bar.size = Vector2(0, 4);     _bar.position = _bar_bg.position

func _process(delta: float) -> void:
	_t += delta
	# --- глитч-анимация заголовка (как «лаг» блоков при появлении/исчезновении) ---
	var s := get_viewport().get_visible_rect().size
	var base_y: float = s.y * 0.5 - 95.0
	var appear: float = clampf(_t / 0.9, 0.0, 1.0)            # 0→1 материализация при появлении
	var gi: float = maxf(1.0 - appear, _dissolve)            # сильный глитч в начале И при развале
	gi = maxf(gi, 0.12)                                      # базовый холостой дребезг
	var dx: float = (2.5 + absf(sin(_t * 9.0)) * 2.5) * (1.0 + gi * 4.0)
	var gx: float = randf_range(-28.0, 28.0) * gi if randf() < 0.06 + gi * 0.4 else 0.0
	var gy: float = randf_range(-12.0, 12.0) * gi if randf() < 0.05 + gi * 0.3 else 0.0
	_titles[0].position = Vector2(-dx + gx, base_y + gy)      # синий
	_titles[1].position = Vector2(dx - gx * 0.6, base_y - gy) # голубой
	_titles[2].position = Vector2(gx * 0.25, base_y)         # бело-голубой
	# Мерцание/пропадание (как глитч-карточки блока то видны, то нет): сильнее глитч → чаще гаснет.
	var vis: float = 1.0 if randf() > gi * 0.55 else randf() * (1.0 - gi * 0.6)
	for l in _titles:
		l.modulate.a = vis
	_load.text = "LOADING" + ".".repeat(int(_t * 2.0) % 4)
	_glitch.queue_redraw()

	# --- логика загрузки ---
	if _phase == 0:
		var prog: Array = []
		var st := ResourceLoader.load_threaded_get_status(next_scene, prog)
		if prog.size() > 0:
			_progress = float(prog[0]) * 0.4               # ресурс = первые 40% бара
		if st == ResourceLoader.THREAD_LOAD_LOADED:
			_swap()
		elif st == ResourceLoader.THREAD_LOAD_FAILED or st == ResourceLoader.THREAD_LOAD_INVALID_RESOURCE:
			get_tree().change_scene_to_file(next_scene)     # фолбэк
			_finish()
	elif _phase == 1:
		_wait += delta
		_progress = 0.4 + clampf(_wait / 12.0, 0.0, 0.55)   # генерация террейна = остальное (по времени)
		if _wait > 40.0:
			_finish()                                       # жёсткий фолбэк, если сигнала так и нет

	_bar.size.x = _bar_bg.size.x * (1.0 if _phase == 2 else _progress)

func _swap() -> void:
	if _phase != 0:
		return
	_phase = 1
	var packed: Variant = ResourceLoader.load_threaded_get(next_scene)
	if not (packed is PackedScene):
		get_tree().change_scene_to_file(next_scene)
		_finish()
		return
	get_tree().change_scene_to_packed(packed)               # освободит Boot(current_scene); мы — сосед root, выживем
	await get_tree().process_frame                          # даём смене сцены произойти
	await get_tree().process_frame
	_hook_terrain()

# Подписываемся на готовность террейна в НОВОЙ игровой сцене (или уходим, если её нет/уже готова).
func _hook_terrain() -> void:
	var scn := get_tree().current_scene
	var map: Node = null
	if scn != null:
		for c in scn.get_children():
			if c.has_method("terrain_height_at"):
				map = c
				break
	if map != null and ("terrain_is_ready" in map):
		if map.terrain_is_ready:
			_finish()
		elif map.has_signal("terrain_ready"):
			map.terrain_ready.connect(_finish, CONNECT_ONE_SHOT)
		else:
			_finish()
	else:
		_finish()

func _finish() -> void:
	if _phase == 2:
		return
	_phase = 2
	var tw := create_tween()
	tw.set_parallel(true)
	tw.tween_property(self, "_dissolve", 1.0, 0.5)          # нарастающий глитч-развал (как снос блока)
	tw.tween_property(_ui, "modulate:a", 0.0, 0.5)
	tw.set_parallel(false)
	tw.tween_callback(queue_free)

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
