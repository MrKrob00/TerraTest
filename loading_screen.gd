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
var _title_vp: SubViewport
var _title_label: Label
var _title_rect: TextureRect
var _title_mat: ShaderMaterial
# Облако карточек — НЕСКОЛЬКО независимых слоёв. Слой был один, и он честно гас целиком
# перед каждой новой вспышкой: как ни рандомь параметры, видно, что это одна и та же
# штука мигает по кругу. Слои живут каждый по своему таймеру и в своей полосе экрана,
# поэтому пока один гаснет, соседний уже разгорается, и пауз «пусто» не остаётся.
# Полоса слоя: x — смещение верха от центра экрана, y — высота; обе в долях высоты названия.
const CARD_BANDS: Array[Vector2] = [
	Vector2(-0.85, 1.50),   # основная полоса — как было
	Vector2(-1.40, 0.75),   # выше названия
	Vector2( 0.35, 0.85),   # ниже названия
	Vector2(-0.45, 0.70),   # узкая, прямо по названию
]
var _cards: Array[ColorRect] = []
var _cards_mat: Array[ShaderMaterial] = []
var _last_rect: Vector2 = Vector2.ZERO   # следим за сменой размера ВИРТУАЛЬНОГО вьюпорта
var _load: Label
var _bar: ColorRect
var _bar_bg: ColorRect
var _glitch: Control
var _scanlines: Control
var _t: float = 0.0
var _progress: float = 0.0
var _phase: int = 0        # 0=грузим ресурс, 1=ждём террейн, 2=гаснем
var _wait: float = 0.0
var _dissolve: float = 0.0 # 0→1 «глитч-развал» при исчезновении (как снос блока)
# Таймеры вспышек — ПО СЛОЮ (см. CARD_BANDS): время внутри текущей вспышки, её
# длительность и период «вспышка + пауза». Каждый слой перезапускается сам по себе.
var _burst_t := PackedFloat32Array()
var _burst_len := PackedFloat32Array()
var _burst_cycle := PackedFloat32Array()

# Новая вспышка слоя: своя длительность, своя пауза и свой рисунок карточек. Паузы РАЗНЫЕ
# и заметно длиннее прежних — периоды слоёв не кратны друг другу и не сходятся в такт.
func _reseed_card(i: int) -> void:
	while _burst_t.size() <= i:
		_burst_t.append(0.0)
		_burst_len.append(0.7)
		_burst_cycle.append(1.0)
	_burst_len[i] = randf_range(0.45, 1.0)
	_burst_cycle[i] = _burst_len[i] + randf_range(0.2, 1.4)
	var m: ShaderMaterial = _cards_mat[i]
	m.set_shader_parameter("seed", randf() * 100.0)
	m.set_shader_parameter("grid_cells", randf_range(14.0, 30.0))
	m.set_shader_parameter("fill_threshold", randf_range(0.45, 0.62))
	m.set_shader_parameter("cell_aspect", Vector2(1.0, randf_range(0.22, 0.5)))

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

	_scanlines = _Scanlines.new()                 # статичный слой: рисуется один раз
	_scanlines.set_anchors_preset(Control.PRESET_FULL_RECT)
	_scanlines.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ui.add_child(_scanlines)

	_glitch = _GlitchFx.new()
	_glitch.set_anchors_preset(Control.PRESET_FULL_RECT)
	_glitch.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ui.add_child(_glitch)

	# RGB-сплит в СИНЕ-ГОЛУБЫХ тонах (без магенты): глубокий синий ↔ голубой ↔ бело-голубой.
	# «Мультяшность» даёт толстая ТЁМНО-СИНЯЯ обводка (как у логотипов из мультиков).
	# ── Заголовок: Label живёт в SubViewport, на экран идёт ТЕКСТУРОЙ через шейдер ──────────
	# Только так глитч может по-настоящему РВАТЬ надпись: у Label «текстура» — атлас шрифта,
	# и сдвиг UV вытащил бы соседние глифы вместо смещения текста. Через вьюпорт шейдер получает
	# готовую картинку надписи и делает с ней что угодно (разрывы полос, RGB-сплит, выпадение).
	_title_vp = SubViewport.new()
	_title_vp.transparent_bg = true
	_title_vp.render_target_clear_mode = SubViewport.CLEAR_MODE_ALWAYS
	_title_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(_title_vp)

	_title_label = Label.new()
	_title_label.text = "WorldTech"
	_title_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_title_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_title_label.add_theme_color_override("font_color", Color(0.85, 0.96, 1.0))
	_title_label.add_theme_color_override("font_outline_color", Color(0.03, 0.09, 0.22))
	_title_vp.add_child(_title_label)

	_title_rect = TextureRect.new()
	_title_rect.texture = _title_vp.get_texture()
	_title_rect.stretch_mode = TextureRect.STRETCH_KEEP
	_title_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var tmat := ShaderMaterial.new()
	tmat.shader = load("res://loading_title.gdshader")
	tmat.set_shader_parameter("seed", randf() * 100.0)
	_title_rect.material = tmat
	_title_mat = tmat
	_ui.add_child(_title_rect)

	# Облако глитч-карточек ВОКРУГ названия — тот же эффект, что у блоков (порт glitch_card).
	var shader: Shader = load("res://loading_glitch.gdshader")
	for i in CARD_BANDS.size():
		var rect := ColorRect.new()
		rect.color = Color(1, 1, 1, 1)        # цвет даёт шейдер
		rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var cmat := ShaderMaterial.new()
		cmat.shader = shader
		rect.material = cmat
		_cards.append(rect)
		_cards_mat.append(cmat)
		_ui.add_child(rect)
		_reseed_card(i)
		# Стартовая фаза у каждого своя, иначе первый раз все вспыхнут разом и слои
		# «слипнутся» в одну карточку — ровно то, от чего уходим.
		_burst_t[i] = randf_range(0.0, _burst_cycle[i])

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
	_last_rect = s
	var fs: int = clampi(int(s.y * 0.15), 44, 190)
	_title_label.add_theme_font_size_override("font_size", fs)
	_title_label.add_theme_constant_override("outline_size", maxi(int(fs * 0.11), 6))
	var tw: float = minf(s.x, fs * 8.0)
	var th: float = fs * 1.6
	_title_vp.size = Vector2i(int(tw), int(th))
	_title_label.size = Vector2(tw, th)
	_title_label.position = Vector2.ZERO
	_title_rect.size = Vector2(tw, th)
	_title_rect.position = Vector2((s.x - tw) * 0.5, s.y * 0.5 - th * 0.62)
	# Карточки — полосами вокруг названия, у каждого слоя своя (см. CARD_BANDS).
	for i in _cards.size():
		var band: Vector2 = CARD_BANDS[i]
		_cards[i].size = Vector2(s.x, th * band.y)
		_cards[i].position = Vector2(0, s.y * 0.5 + th * band.x)
	_load.size = Vector2(s.x, 22); _load.position = Vector2(0, s.y - 84.0)
	var bw: float = minf(s.x * 0.5, 460.0)
	_bar_bg.size = Vector2(bw, 4); _bar_bg.position = Vector2((s.x - bw) * 0.5, s.y - 56.0)
	_bar.size = Vector2(0, 4);     _bar.position = _bar_bg.position

func _process(delta: float) -> void:
	_t += delta
	# Виртуальный вьюпорт мог смениться (новая сцена ставит content_scale_factor) — тогда
	# пересобираем раскладку, иначе надпись «уменьшалась» относительно экрана.
	var s := get_viewport().get_visible_rect().size
	if s != _last_rect:
		_layout()
	var appear: float = clampf(_t / 0.9, 0.0, 1.0)

	# Сила: максимум при ПОЯВЛЕНИИ экрана и при РАЗВАЛЕ, между ними — ритм вспышек.
	var edge: float = maxf(1.0 - appear, _dissolve)
	var pulse_max: float = 0.0
	for i in _cards.size():
		_burst_t[i] += delta
		if _burst_t[i] >= _burst_cycle[i]:
			_burst_t[i] = 0.0
			_reseed_card(i)
			# Название дёргается вместе с любым слоем — иначе оно бы жило своим ритмом.
			_title_mat.set_shader_parameter("seed", randf() * 100.0)
			_title_mat.set_shader_parameter("slices", randf_range(12.0, 30.0))
		# Прогресс ТЕКУЩЕЙ вспышки 0→1; после её конца остаётся 1 (всё погашено) до цикла.
		var burst_p: float = clampf(_burst_t[i] / maxf(_burst_len[i], 0.01), 0.0, 1.0)
		var pulse: float = 1.0 - absf(burst_p * 2.0 - 1.0)   # 0→1→0 внутри вспышки
		pulse_max = maxf(pulse_max, pulse)
		var m: ShaderMaterial = _cards_mat[i]
		m.set_shader_parameter("progress", burst_p if edge <= 0.0 else minf(burst_p, 0.5))
		m.set_shader_parameter("intensity", clampf(maxf(edge, pulse), 0.0, 1.0))
	var gi: float = clampf(maxf(edge, pulse_max * 0.85), 0.06, 1.0)
	_title_mat.set_shader_parameter("glitch", gi)
	_load.text = "LOADING" + ".".repeat(int(_t * 2.0) % 4)
	# Фон дышит тем же `gi`, что название и карточки, и знает, где надпись, — срезы кучнее
	# у центра композиции, а не размазаны по всему экрану.
	_glitch.intensity = gi
	_glitch.focus_y = _title_rect.position.y + _title_rect.size.y * 0.5
	_glitch.focus_h = maxf(_title_rect.size.y * 0.9, 60.0)
	_glitch.tick(delta)

	# --- логика загрузки ---
	if _phase == 0:
		_wait += delta
		var prog: Array = []
		var st := ResourceLoader.load_threaded_get_status(next_scene, prog)
		if prog.size() > 0:
			_progress = float(prog[0]) * 0.4               # ресурс = первые 40% бара
		if st == ResourceLoader.THREAD_LOAD_LOADED:
			_wait = 0.0
			_swap()
		elif st == ResourceLoader.THREAD_LOAD_FAILED or st == ResourceLoader.THREAD_LOAD_INVALID_RESOURCE \
				or _wait > 60.0:
			_phase = 1
			_wait = 0.0
			get_tree().change_scene_to_file(next_scene)     # фолбэк
			await get_tree().process_frame
			_hook_terrain()
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

# Ищем ноду террейна ВГЛУБЬ (не только среди прямых детей): если карту завернут в контейнер,
# поиск по одному уровню вернул бы null и экран снялся бы сразу, вернув чёрную загрузку.
func _find_terrain(n: Node) -> Node:
	if n == null:
		return null
	for c in n.get_children():
		if c.has_method("terrain_height_at"):
			return c
		var deep := _find_terrain(c)
		if deep != null:
			return deep
	return null

# Подписываемся на готовность террейна в НОВОЙ игровой сцене (или уходим, если её нет/уже готова).
func _hook_terrain() -> void:
	var scn := get_tree().current_scene
	var map: Node = _find_terrain(scn)              # рекурсивно: карта может лежать не первым уровнем
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

class _Scanlines extends Control:
	func _draw() -> void:
		var s := size
		var y: float = 0.0
		while y < s.y:
			draw_line(Vector2(0, y), Vector2(s.x, y), Color(0, 0, 0, 0.13), 1.0)
			y += 3.0

# Только анимируемая часть: несколько сине-голубых полос (≤6 draw_rect за кадр).
# Глитч-полосы фона.
#
# Было две беды, и обе делали из эффекта грязь. Первая — ширина `s.x + 60`: каждая полоса
# шла ОТ КРАЯ ДО КРАЯ, а сплошная линия через весь экран не читается как сбой, она читается
# как криво нарисованный прямоугольник. Вторая — полосы перебирались заново КАЖДЫЙ кадр, то
# есть мигали шестьдесят раз в секунду: это рябь телевизора, а не глитч.
#
# Теперь полоса — КОРОТКИЙ срез (6–30% ширины экрана) в случайном месте, и он ЖИВЁТ
# десятые доли секунды. Разрыв, который держится, выглядит намеренным; разрыв, который
# меняется каждый кадр, — шумом. Плотность и яркость идут от той же `intensity`, что и
# карточки с названием, поэтому фон дышит вместе с ними, а не живёт своим ритмом.
class _GlitchFx extends Control:
	const COUNT := 9
	## Палитра та же, что у всей заставки: голубой и синий, магенты здесь нет намеренно.
	const C_CYAN := Color(0.15, 0.85, 1.0)
	const C_BLUE := Color(0.35, 0.55, 1.0)

	var intensity: float = 0.0      # 0..1 — общий ритм заставки
	var focus_y: float = 0.0        # середина надписи: около неё срезы гуще
	var focus_h: float = 120.0

	var _sl: Array = []

	func tick(delta: float) -> void:
		if size.x <= 1.0:
			return
		while _sl.size() < COUNT:
			_sl.append(_born())
		for i in _sl.size():
			var d: Dictionary = _sl[i]
			d["life"] = float(d["life"]) - delta
			if d["life"] <= 0.0:
				_sl[i] = _born()
		queue_redraw()

	# Новый срез. Ширина НИКОГДА не доходит до полного экрана — в этом вся разница.
	func _born() -> Dictionary:
		var s := size
		var w: float = s.x * randf_range(0.06, 0.30)
		# Три четверти срезов ложатся полосой вокруг надписи, остальные — где угодно.
		# Равномерно по всему экрану выглядит как загрязнение, у центра — как композиция.
		var y: float = focus_y + randf_range(-focus_h, focus_h) if randf() < 0.75 else randf() * s.y
		var cyan_first: bool = randf() < 0.55
		return {
			"x": randf() * maxf(s.x - w, 1.0),
			"y": clampf(y, 0.0, maxf(s.y - 2.0, 1.0)),
			"w": w,
			"h": randf_range(1.5, 7.0),
			"col": C_CYAN if cyan_first else C_BLUE,
			"col2": C_BLUE if cyan_first else C_CYAN,
			# Развод каналов: сдвинутый дубль другим цветом. Именно он и читается как сбой
			# картинки. Сдвиг ФИКСИРУЕМ при рождении — дёргать его каждый кадр значило бы
			# вернуть ту же рябь, от которой уходим.
			"dx": randf_range(-5.0, 5.0) if randf() < 0.35 else 0.0,
			"a": randf_range(0.10, 0.26),
			"on": randf() < 0.25 + intensity * 0.65,
			"life": randf_range(0.06, 0.22),
		}

	func _draw() -> void:
		var k: float = clampf(0.35 + intensity, 0.0, 1.0)
		for d in _sl:
			if not bool(d["on"]):
				continue
			var col: Color = d["col"]
			col.a = float(d["a"]) * k
			var r := Rect2(float(d["x"]), float(d["y"]), float(d["w"]), float(d["h"]))
			draw_rect(r, col)
			var dx: float = float(d["dx"])
			if dx != 0.0:
				var c2: Color = d["col2"]
				c2.a = col.a * 0.7
				draw_rect(Rect2(r.position + Vector2(dx, 0.0), r.size), c2)
