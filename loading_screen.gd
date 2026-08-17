extends CanvasLayer
## СТОЙКИЙ оверлей загрузки. Его поднимает loading_boot (главная сцена) и добавляет прямо в root —
## поэтому он ПЕРЕЖИВАЕТ смену сцены (change_scene освобождает только current_scene, не соседей root).
##
## Порядок: потоково грузим игровую сцену → меняем на неё → ДЕРЖИМСЯ сверху (слой 200), пока карта
## не построит ближний террейн (map.terrain_ready) → гаснем и удаляемся. Так экран крутится ВСЁ время
## загрузки: и парсинг ресурсов, и ~15с генерации террейна (раньше она шла на чёрном экране, т.к.
## происходит в _ready карты уже ПОСЛЕ смены сцены). Всё рисуется в коде, без ассетов.
##
## СЛОИ СНИЗУ ВВЕРХ: градиент → каркас (сетка, скобки, линейки) → виньетка → глитч-срезы →
## название → карточки → низ (статус, процент, полоса).
##
## Главное правило композиции: экран должен быть СПОКОЕН большую часть времени. Раньше всё
## двигалось одновременно и постоянно — рвался титр, мигали четыре слоя карточек, сыпал
## срезами фон, а поверх всего лежала сплошная штриховка скан-линий. Глитчу было нечего
## ломать, и вместе это читалось как грязь, а не как сбой. Теперь есть неподвижная геометрия
## (каркас) и длинные паузы между вспышками, и сбой снова работает акцентом.

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
var _pct: Label
var _bar: ColorRect
var _bar_bg: ColorRect
var _bar_head: ColorRect
# Типы — ИМЕННО внутренние классы, а не Control: ниже мы зовём их собственные поля
# (intensity/focus_y/tick, title_rect/bar_rect). При статическом типе Control компилятор
# GDScript такого не пропустит — «Cannot find property», причём уже на загрузке сцены.
var _glitch: _GlitchFx
var _bg: TextureRect
var _vignette: TextureRect
var _frame: _Frame
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
	# Вспышки КОРОЧЕ, а паузы ДЛИННЕЕ прежних. Раньше четыре слоя с паузами 0.2–1.4 с давали
	# почти непрерывное мигание: глитч переставал быть событием и превращался в фон. Сбой
	# работает как акцент, только если между сбоями экран спокоен.
	_burst_len[i] = randf_range(0.25, 0.6)
	_burst_cycle[i] = _burst_len[i] + randf_range(1.2, 3.4)
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

	# ФОН — вертикальный градиент, а не плоская заливка. Плоский чёрный не даёт глубины:
	# экран выглядит выключенным, а не «включающимся». Верх холоднее и светлее низа —
	# получается горизонт, к которому и привязана вся композиция.
	_bg = TextureRect.new()
	_bg.texture = _gradient([Color(0.03, 0.07, 0.11), Color(0.01, 0.02, 0.04)],
			Vector2(0.5, 0.0), Vector2(0.5, 1.0), false)
	# Растяжение задаём ЯВНО: у TextureRect по умолчанию размер считается от текстуры, а она
	# у нас крошечная (градиент не нужен в большом разрешении) — без этих двух строк фон лёг
	# бы заплаткой в углу вместо всего экрана.
	_bg.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_bg.stretch_mode = TextureRect.STRETCH_SCALE
	_bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ui.add_child(_bg)

	# Каркас: сетка, угловые скобки и две линейки вокруг названия. Это и есть та СПОКОЙНАЯ
	# часть, без которой глитч не работает: сбой читается сбоем только тогда, когда есть
	# ровная геометрия, которую он ломает. Рисуется один раз на раскладку.
	_frame = _Frame.new()
	_frame.set_anchors_preset(Control.PRESET_FULL_RECT)
	_frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ui.add_child(_frame)

	# Виньетка поверх сетки: края темнее центра. Она собирает взгляд к названию и прячет
	# то, что сетка на широком экране уходит в бесконечность.
	_vignette = TextureRect.new()
	_vignette.texture = _gradient([Color(0, 0, 0, 0.0), Color(0, 0, 0, 0.55)],
			Vector2(0.5, 0.5), Vector2(1.0, 0.5), true)
	_vignette.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_vignette.stretch_mode = TextureRect.STRETCH_SCALE
	_vignette.set_anchors_preset(Control.PRESET_FULL_RECT)
	_vignette.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ui.add_child(_vignette)

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

	# Внизу — строка состояния и процент по краям полосы, а не «LOADING...» по центру.
	# Точки не говорят ничего; «GENERATING TERRAIN 62%» говорит, что происходит и сколько
	# осталось, и заодно объясняет, почему пятнадцать секунд ничего не двигается.
	_load = _mk("LOADING ASSETS", 15, Color(0.55, 0.78, 0.86), HORIZONTAL_ALIGNMENT_LEFT)
	_pct = _mk("0%", 15, CYAN, HORIZONTAL_ALIGNMENT_RIGHT)

	_bar_bg = ColorRect.new()
	_bar_bg.color = Color(0.35, 0.62, 0.70, 0.16)
	_bar_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ui.add_child(_bar_bg)
	_bar = ColorRect.new()
	_bar.color = CYAN
	_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ui.add_child(_bar)
	# «Голова» полосы — короткий яркий блик на её конце. По нему видно, что загрузка ИДЁТ,
	# даже когда процент стоит на месте: без него замерший бар выглядит зависшим.
	_bar_head = ColorRect.new()
	_bar_head.color = Color(0.85, 0.98, 1.0)
	_bar_head.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ui.add_child(_bar_head)

	_layout()
	get_viewport().size_changed.connect(_layout)
	ResourceLoader.load_threaded_request(next_scene)

## Плоский градиент как текстура — дешевле собственного шейдера и не требует файла.
## radial=true даёт виньетку (от центра наружу), иначе линейный переход.
func _gradient(cols: Array, from: Vector2, to: Vector2, radial: bool) -> GradientTexture2D:
	var g := Gradient.new()
	g.set_color(0, cols[0])
	g.set_color(1, cols[1])
	var t := GradientTexture2D.new()
	t.gradient = g
	t.fill = GradientTexture2D.FILL_RADIAL if radial else GradientTexture2D.FILL_LINEAR
	t.fill_from = from
	t.fill_to = to
	t.width = 8 if not radial else 128
	t.height = 128
	return t

func _mk(txt: String, fsize: int, col: Color, align: int = HORIZONTAL_ALIGNMENT_CENTER) -> Label:
	var l := Label.new()
	l.text = txt
	l.horizontal_alignment = align
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
	# Карточки — полосами вокруг названия (см. CARD_BANDS), но НЕ во всю ширину: полоса от
	# края до края читается как шов, а не как разрыв. Держим их в колонке названия с запасом.
	var cw: float = minf(s.x, tw * 1.35)
	for i in _cards.size():
		var band: Vector2 = CARD_BANDS[i]
		_cards[i].size = Vector2(cw, th * band.y)
		_cards[i].position = Vector2((s.x - cw) * 0.5, s.y * 0.5 + th * band.x)
	# Низ: одна колонка шириной с полосу — статус слева, процент справа, полоса под ними.
	# Раньше подпись и полоса были разной ширины и не выравнивались ни по чему.
	var bw: float = clampf(s.x * 0.62, 240.0, 620.0)
	var bx: float = (s.x - bw) * 0.5
	var by: float = s.y - maxf(s.y * 0.12, 64.0)
	var bh: float = maxf(s.y * 0.008, 5.0)
	_load.size = Vector2(bw, 20);  _load.position = Vector2(bx, by - 26.0)
	_pct.size  = Vector2(bw, 20);  _pct.position  = Vector2(bx, by - 26.0)
	_bar_bg.size = Vector2(bw, bh); _bar_bg.position = Vector2(bx, by)
	_bar.size = Vector2(0, bh);     _bar.position = _bar_bg.position
	_bar_head.size = Vector2(maxf(bh * 0.6, 3.0), bh); _bar_head.position = _bar_bg.position
	# Каркасу говорим, где название и где полоса: линейки и скобки строятся по ним, а не по
	# выдуманным координатам, поэтому при любом экране всё остаётся на своих местах.
	_frame.title_rect = _title_rect.get_rect()
	_frame.bar_rect = Rect2(Vector2(bx, by), Vector2(bw, bh))
	_frame.queue_redraw()

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
	# Что именно сейчас происходит. Генерация рельефа занимает секунд пятнадцать, и без
	# подписи это выглядит зависанием — самая частая причина «игра сломалась» на загрузке.
	var stage: String = ["LOADING ASSETS", "GENERATING TERRAIN", "READY"][_phase]
	_load.text = stage + ".".repeat(int(_t * 2.0) % 4 if _phase < 2 else 0)
	_pct.text = "%d%%" % int(round((1.0 if _phase == 2 else _progress) * 100.0))
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
	_bar_head.position.x = _bar_bg.position.x + maxf(_bar.size.x - _bar_head.size.x, 0.0)
	_bar_head.modulate.a = 0.55 + 0.45 * sin(_t * 7.0)   # блик дышит — видно, что не зависло

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

# КАРКАС — спокойная геометрия экрана: сетка, угловые скобки, линейки вокруг названия и
# засечки у полосы загрузки.
#
# Он здесь не для украшения. Раньше на экране НЕ БЫЛО ничего неподвижного: рвался титр,
# мигали четыре слоя карточек, сыпал срезами фон — и глитчу было нечего ломать, поэтому всё
# вместе читалось как рябь. Сбой выглядит сбоем только рядом с ровной линией.
#
# Скан-линии, что были тут раньше, эту роль не тянули: сплошная штриховка через каждые три
# пикселя — это не структура, а грязь, и на телефоне с дробным content_scale она вдобавок
# лесенкой муарит. Редкая сетка даёт структуру и почти ничего не стоит.
class _Frame extends Control:
	const GRID := Color(0.25, 0.55, 0.62, 0.10)
	const LINE := Color(0.35, 0.75, 0.85, 0.55)
	const BRACKET := Color(0.15, 0.85, 1.0, 0.75)

	var title_rect: Rect2 = Rect2()
	var bar_rect: Rect2 = Rect2()

	func _draw() -> void:
		var s := size
		if s.x < 2.0:
			return
		# Сетка. Шаг от высоты экрана, а не в пикселях: на телефоне и на планшете плотность
		# должна выглядеть одинаково, а не превращаться в кашу на одном из них.
		var step: float = maxf(s.y / 18.0, 28.0)
		var x: float = step
		while x < s.x:
			draw_line(Vector2(x, 0), Vector2(x, s.y), GRID, 1.0)
			x += step
		var y: float = step
		while y < s.y:
			draw_line(Vector2(0, y), Vector2(s.x, y), GRID, 1.0)
			y += step

		# Угловые скобки — рамка кадра. Дёшево и сразу задаёт «это интерфейс системы».
		var m: float = maxf(s.y * 0.045, 22.0)
		var l: float = maxf(s.y * 0.055, 26.0)
		for c in [Vector2(m, m), Vector2(s.x - m, m), Vector2(m, s.y - m), Vector2(s.x - m, s.y - m)]:
			var sx: float = 1.0 if c.x < s.x * 0.5 else -1.0
			var sy: float = 1.0 if c.y < s.y * 0.5 else -1.0
			draw_line(c, c + Vector2(l * sx, 0.0), BRACKET, 2.0)
			draw_line(c, c + Vector2(0.0, l * sy), BRACKET, 2.0)

		# Линейки над и под названием: они превращают надпись в ЛОГОТИП, а не в текст,
		# висящий в пустоте, и дают глитчу что ломать.
		if title_rect.size.x > 1.0:
			var pad: float = title_rect.size.x * 0.06
			var x0: float = title_rect.position.x - pad
			var x1: float = title_rect.end.x + pad
			for ty in [title_rect.position.y + title_rect.size.y * 0.16,
					title_rect.end.y - title_rect.size.y * 0.16]:
				draw_line(Vector2(x0, ty), Vector2(x1, ty), LINE, 1.0)
				# Короткие засечки на концах — линия «заканчивается», а не обрывается.
				draw_line(Vector2(x0, ty - 5.0), Vector2(x0, ty + 5.0), LINE, 1.0)
				draw_line(Vector2(x1, ty - 5.0), Vector2(x1, ty + 5.0), LINE, 1.0)

		# Засечки под полосой загрузки — четверти пути. Полоса перестаёт быть просто чертой:
		# по ним видно, сколько пройдено, даже боковым зрением.
		if bar_rect.size.x > 1.0:
			for i in range(1, 4):
				var tx: float = bar_rect.position.x + bar_rect.size.x * (float(i) / 4.0)
				draw_line(Vector2(tx, bar_rect.end.y + 3.0), Vector2(tx, bar_rect.end.y + 8.0),
						Color(0.35, 0.75, 0.85, 0.35), 1.0)

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
			# В спокойные моменты срезов почти нет — они приходят вместе со вспышкой.
			"on": randf() < 0.08 + intensity * 0.70,
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
