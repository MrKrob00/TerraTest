extends CanvasLayer

# Игровой HUD. Помимо старой логики (FPS, переключение режимов, кнопки Take/TakeOff)
# здесь живёт меню: в левом верхнем углу иконка-«бургер», по тапу под ней разворачивается
# тёмно-бирюзовая панель с Инвентарём и списком техники. Правый край HUD держим свободным —
# там радар и трекер квестов, и выезжавшая раньше оттуда панель их перекрывала.

const TECH_UI := preload("res://tech_ui.tscn")

@onready var current_vehicle = $"..".current_vehicle

# ── Меню (левый верх) ────────────────────────────────────────────────────────
const MENU_BTN: float = 72.0                # сторона иконки-кнопки
const MENU_PAD: float = 12.0                # отступ от углов экрана
var _menu_btn: Button
var _tech_ui: Control = null
var _vehicle_list: VBoxContainer            # список техники в drawer (перестраивается)
var _rotate_panel: PanelContainer           # кнопки поворота блока (видны в стройке)
var _block_globe: BlockGlobe = null          # «шар» выбора блока (видны в стройке)

# ── Вид глобуса блоков (крутится в инспекторе живьём) ─────────────────────────
# Глобус создаётся кодом (BlockGlobe.new), поэтому его @export не видны в инспекторе — рулим
# отсюда, с ноды HUD. Меняешь ползунок → globe.apply_view() перестраивает вид сразу.
@export_group("Block globe (view)")
## Наклон глобуса (смотрим сверху). ~0.5 = как сейчас.
@export var globe_tilt: float = 0.5 : set = _set_globe_tilt
## Прокрут по красному кольцу-экватору (вокруг вертикали). 0 = спереди, ~1.57 (PI/2) = сбоку.
@export var globe_spin: float = 1.5707964 : set = _set_globe_spin

func _set_globe_tilt(v: float) -> void:
	globe_tilt = v
	if _block_globe:
		_block_globe.view_pitch = v
		_block_globe.apply_view()

func _set_globe_spin(v: float) -> void:
	globe_spin = v
	if _block_globe:
		_block_globe.view_yaw = v
		_block_globe.apply_view()
var _game_controls: Array = []              # игровые кнопки/джойстики — прячем при инвентаре

func _ready() -> void:
	_build_menu_button()
	_build_rotate_panel()
	_build_hand_panel()
	_build_block_globe()
	_build_anchor_button()
	_build_radar()
	_build_money()
	# Компас задания (quest_compass.gd): ведёт к цели отслеживаемого квеста и не даёт ей
	# потеряться за кадром. Добавляем ПОСЛЕ карты, чтобы рисоваться поверх мира, но он
	# полноэкранный и прозрачный — ничего собой не закрывает.
	var qc := QuestCompass.new()
	add_child(qc)
	_quest_compass = qc
	# _build_settings_panel()   # настройки камеры переехали в гараж (tech_ui)
	_collect_game_controls()
	# Наставник обучения (палец + блокировка). Ставим ПОСЛЕ сборки кнопок: он их ищет.
	add_child(preload("res://tutorial_director.gd").new())
	# Ведущий сюжетной ветки: кладёт в мир обещанное квестом и сам следит за условиями.
	add_child(preload("res://quest_arcs.gd").new())
	# Экран мог поменять размер (поворот, ресайз окна на ПК). Масштаб держит stretch
	# (project.godot → canvas_items), но угловые элементы HUD строятся в коде от размера
	# экрана — их надо пере-разложить, иначе при expand они «отлипнут» от краёв.
	# DEFERRED: Main тоже слушает size_changed и меняет content_scale_factor (умный размер
	# UI) — deferred гарантирует, что раскладка идёт ПОСЛЕ смены масштаба, с финальным
	# логическим размером экрана, а не до неё.
	get_viewport().size_changed.connect(_relayout, CONNECT_DEFERRED)
	_relayout.call_deferred()   # стартовая раскладка после того, как Main выставит масштаб
	# Тост «сейчас играет» при каждой смене трека (атрибуция для CC-BY треков).
	var music := get_node_or_null("/root/Music")
	if music:
		music.track_changed.connect(_show_music_toast)

# Пере-раскладка построенных в коде элементов HUD под текущий размер экрана. Всё, что
# прибито к краям (меню, кнопка режима, панель поворота, кнопка якоря, «шар» блоков), пересчитываем
# от свежего get_visible_rect(). Масштаб (размер кнопок/шрифтов) держит stretch движка.
func _relayout() -> void:
	var screen: Vector2 = get_viewport().get_visible_rect().size
	if _menu_btn:
		_menu_btn.position = Vector2(MENU_PAD, MENU_PAD)
	if _drawer:
		if _drawer_tween and _drawer_tween.is_valid():
			_drawer_tween.kill()       # ресайз во время слайда — снапаем, не даём доиграть
		var dh: float = screen.y * DRAWER_H_RATIO
		var dy: float = (screen.y - dh) * 0.5
		_drawer.size = Vector2(DRAWER_W, dh)
		_drawer.position = Vector2((screen.x - DRAWER_W) if _drawer_open else screen.x, dy)
		if _handle:
			_handle.position = Vector2(
					(screen.x - DRAWER_W - 50.0) if _drawer_open else (screen.x - 50.0),
					dy + dh * 0.5 - 36.0)
	if _rotate_panel:
		_rotate_panel.position = Vector2(16.0, screen.y * 0.5 - _rotate_panel.size.y * 0.5)
	if _block_globe:
		_block_globe.position = _globe_pos(screen)
	# Кнопка режима — правее иконки меню, в один ряд с ней.
	var mode := get_node_or_null("ModeToggle") as Node2D
	if mode:
		mode.position = Vector2(MENU_PAD + MENU_BTN + 12.0, MENU_PAD)
	# Панель «блок в руке» больше не раскладывается здесь: её место считает
	# _update_hand_panel каждый кадр (она привязана к кнопкам поворота слева).
	if _anchor_btn:
		_anchor_btn.position = Vector2(16, screen.y - 170)
	if _radar:
		_radar.position = _radar_pos(screen)
	_layout_money()
	# Джойстики и FPS-метка — это ноды сцены с АБСОЛЮТНЫМИ позициями (авторились под одно
	# разрешение). При expand на не-16:9 экране они «отлипали» от краёв. Прибиваем к краям
	# от текущего размера (джойстики всё равно прыгают под палец при касании — это лишь
	# позиция покоя, но её видно). Держим авторский отступ у базы 1280×720.
	var jm := get_node_or_null("Joystick_movement") as Node2D
	if jm:
		jm.position = Vector2(186, screen.y - 249)         # низ-слева (реген у базы 720 = y 471)
	var jc := get_node_or_null("Joystick_camera") as Node2D
	if jc:
		jc.position = Vector2(screen.x - 117, 141)         # право-сверху (реген у базы 1280 = x 1163)
	var fps := get_node_or_null("Label") as Control
	if fps:
		fps.position = Vector2(screen.x * 0.5 - 75.0, 4.0) # по центру сверху

# ── Круглый индикатор энергии (аккумулятор + %) ────────────────────────────────
# Рисуется нодами: тёмный круг, дуга-прогресс по окружности (заполненность аккумуляторов),
# значок батарейки в центре, процент снизу. Обновляется из _process.
class EnergyGauge extends Control:
	var fill: float = 0.0        # 0..1
	var has_cap: bool = false    # есть ли аккумуляторы вообще

	func _draw() -> void:
		var c := size * 0.5
		var r := minf(size.x, size.y) * 0.5 - 3.0
		draw_circle(c, r, Color(0.05, 0.1, 0.12, 0.85))
		draw_arc(c, r, 0, TAU, 48, Color(0.15, 0.3, 0.35), 3.0)
		if has_cap:
			var col := Color(0.3, 1.0, 0.5) if fill > 0.25 else Color(1.0, 0.6, 0.2)
			draw_arc(c, r, -PI / 2, -PI / 2 + TAU * clampf(fill, 0.0, 1.0), 48, col, 4.5)
		# батарейка: корпус + «пипка» + заливка по fill
		var bw := r * 0.7
		var bh := r * 0.42
		var tl := c - Vector2(bw * 0.5, bh * 0.5 + r * 0.12)
		var col_body := Color(0.85, 0.95, 1.0)
		draw_rect(Rect2(tl, Vector2(bw, bh)), col_body, false, 2.0)
		draw_rect(Rect2(tl + Vector2(bw, bh * 0.3), Vector2(3.5, bh * 0.4)), col_body)
		if has_cap and fill > 0.01:
			var pad := 3.0
			draw_rect(Rect2(tl + Vector2(pad, pad), Vector2((bw - pad * 2.0) * clampf(fill, 0.0, 1.0), bh - pad * 2.0)),
					Color(0.3, 1.0, 0.5) if fill > 0.25 else Color(1.0, 0.6, 0.2))
		# процент
		var txt := "%d%%" % int(round(fill * 100.0)) if has_cap else "--"
		var f := get_theme_default_font()
		var fs := 13
		var w := f.get_string_size(txt, HORIZONTAL_ALIGNMENT_CENTER, -1, fs).x
		draw_string(f, c + Vector2(-w * 0.5, r * 0.55), txt, HORIZONTAL_ALIGNMENT_CENTER, -1, fs, Color(0.9, 0.97, 1.0))

# ── Радар-карта (даёт блок RADAR): круг справа сверху с блипами; энергия — дугой слева-снизу ──
# North-up: экран X = мир +X, экран Y (вниз) = мир +Z. Блипы — цель минус игрок (мир XZ).
class RadarHUD extends Control:
	var range_world: float = 220.0            # какой радиус мира влезает в радар
	var blips: Array = []                     # [{p: Vector2 (dx,dz мир отн. игрока), c: Color}]
	var heading: Vector2 = Vector2.UP         # «вперёд» игрока в экранных осях
	var fill: float = 0.0                     # энергия 0..1
	var has_cap: bool = false                 # есть ли аккумуляторы

	func _draw() -> void:
		var c := size * 0.5
		var r := minf(size.x, size.y) * 0.5 - 12.0
		# фон + обод + сетка
		draw_circle(c, r, Color(0.03, 0.08, 0.10, 0.82))
		draw_arc(c, r, 0, TAU, 64, Color(0.2, 0.5, 0.55, 0.9), 2.0)
		draw_arc(c, r * 0.5, 0, TAU, 40, Color(0.2, 0.5, 0.55, 0.25), 1.0)
		draw_line(c - Vector2(r, 0), c + Vector2(r, 0), Color(0.2, 0.5, 0.55, 0.22), 1.0)
		draw_line(c - Vector2(0, r), c + Vector2(0, r), Color(0.2, 0.5, 0.55, 0.22), 1.0)
		# блипы
		var scale := r / maxf(range_world, 1.0)
		for b in blips:
			var pix: Vector2 = c + (b["p"] as Vector2) * scale
			if pix.distance_to(c) > r - 2.0:
				continue
			draw_circle(pix, 3.0, b["c"])
		# игрок в центре — треугольник по heading
		var h: Vector2 = heading if heading.length() > 0.01 else Vector2.UP
		var perp := Vector2(-h.y, h.x)
		draw_colored_polygon(PackedVector2Array([c + h * 7.0, c - h * 4.0 + perp * 4.0, c - h * 4.0 - perp * 4.0]),
				Color(0.9, 0.97, 1.0))
		# энерго-дуга по ободу СНИЗУ-СЛЕВА (0=право, PI/2=низ, PI=лево)
		var ar := r + 5.0
		draw_arc(c, ar, PI * 0.5, PI, 22, Color(0.2, 0.5, 0.55, 0.35), 3.0)   # трек
		if has_cap:
			var col := Color(0.3, 1.0, 0.5) if fill > 0.25 else Color(1.0, 0.6, 0.2)
			draw_arc(c, ar, PI * 0.5, PI * 0.5 + (PI * 0.5) * clampf(fill, 0.0, 1.0), 22, col, 4.5)

var _energy_gauge: EnergyGauge = null
func _build_energy_gauge() -> void:
	_energy_gauge = EnergyGauge.new()
	_energy_gauge.size = Vector2(78, 78)
	_energy_gauge.position = Vector2(16, 16)
	_energy_gauge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_energy_gauge)

# Радар-карта: круг СПРАВА СВЕРХУ. Виден только если у активной машины есть блок RADAR.
# Энергия показана дугой по его ободу слева-снизу (см. RadarHUD._draw).
# Карта есть ВСЕГДА, но блок RADAR решает, насколько она велика. Без него — маленькая
# врезка с ближайшим окружением машины (видно, что прямо вокруг тебя); с ним — заметно
# крупнее и втрое дальше. Раньше без блока карты не было вовсе.
const RADAR_SIZE_SMALL := 96.0
const RADAR_SIZE_FULL := 150.0
const RADAR_RANGE_SMALL := 55.0     # м мира в радиусе карты
const RADAR_RANGE_FULL := 220.0
var _radar: RadarHUD = null
var _quest_compass: Control = null
var _radar_size: float = RADAR_SIZE_SMALL

func _build_radar() -> void:
	_radar = RadarHUD.new()
	_radar.size = Vector2(_radar_size, _radar_size)
	_radar.range_world = RADAR_RANGE_SMALL
	_radar.position = _radar_pos(get_viewport().get_visible_rect().size)
	_radar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_radar.visible = false
	add_child(_radar)

func _radar_pos(screen: Vector2) -> Vector2:
	return Vector2(screen.x - _radar_size - 12.0, 12.0)   # справа сверху

# ── Деньги ────────────────────────────────────────────────────────────────────
# Постоянная строка под картой, в том же правом верхнем углу. Раньше деньги на HUD не
# показывались вообще — их было видно только открыв гараж, то есть в бою и на добыче
# игрок не знал, сколько у него есть.
const MONEY_H := 30.0
var _money_lbl: Label = null

func _build_money() -> void:
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", _make_float_panel_style())
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_money_lbl = Label.new()
	_money_lbl.add_theme_font_size_override("font_size", 17)
	_money_lbl.add_theme_color_override("font_color", Color(1.0, 0.85, 0.35))
	_money_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_money_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	p.add_child(_money_lbl)
	add_child(p)
	_money_panel = p
	_refresh_money()
	G.money_changed.connect(_refresh_money)   # продавец начисляет пассивно — ловим сигналом
	_layout_money()

var _money_panel: PanelContainer = null

func _refresh_money() -> void:
	if _money_lbl:
		_money_lbl.text = "$ %s" % _thousands(int(G.money))

# 5038 → «5 038»: без разделителя длинные суммы на бегу не читаются.
func _thousands(v: int) -> String:
	var s := str(absi(v))
	var out := ""
	for i in s.length():
		if i > 0 and (s.length() - i) % 3 == 0:
			out += " "
		out += s[i]
	return ("-" if v < 0 else "") + out

func _layout_money() -> void:
	if _money_panel == null:
		return
	var screen: Vector2 = get_viewport().get_visible_rect().size
	var w: float = maxf(_radar_size, 96.0)
	_money_panel.size = Vector2(w, MONEY_H)
	_money_panel.position = Vector2(screen.x - w - 12.0, 12.0 + _radar_size + 6.0)

# Трекер квестов прибит к тому же углу, что и радар, и лежал прямо на нём. Сообщаем ему
# нижнюю кромку радара; когда радара нет (нет блока RADAR) — 0, и трекер уезжает обратно
# наверх, чтобы не висеть с пустым зазором.
func _push_quest_top(radar_on: bool) -> void:
	var y: float = 0.0
	if radar_on:
		y = _radar_pos(get_viewport().get_visible_rect().size).y + _radar_size + MONEY_H + 12.0
	for q in get_tree().get_nodes_in_group("quests"):
		if q.has_method("set_top_offset"):
			q.set_top_offset(y)

# ── Настройки (чувствительность камеры) — каждый настраивает под себя ──────────
# Панель по центру, открывается из меню. Значения хранятся в G (settings.json), меняются
# ползунками и сохраняются сразу. Панель — Control (mouse_filter STOP), тач по ней не уходит
# в камеру.
var _settings_panel: PanelContainer = null
func _build_settings_panel() -> void:
	_settings_panel = PanelContainer.new()
	_settings_panel.add_theme_stylebox_override("panel", _make_panel_style())
	_settings_panel.custom_minimum_size = Vector2(380, 300)
	_settings_panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	_settings_panel.visible = false
	add_child(_settings_panel)
	var m := MarginContainer.new()
	for s in ["left", "right", "top", "bottom"]:
		m.add_theme_constant_override("margin_" + s, 18)
	_settings_panel.add_child(m)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 14)
	m.add_child(vb)
	var t := Label.new()
	t.text = "CAMERA SETTINGS"
	t.add_theme_color_override("font_color", Color(0.55, 0.85, 0.9, 1))
	t.add_theme_font_size_override("font_size", 20)
	vb.add_child(t)
	vb.add_child(_settings_slider("Rotation sensitivity", G.cam_look_sens,
			func(v): G.cam_look_sens = v; G.save_settings()))
	vb.add_child(_settings_slider("Zoom sensitivity", G.cam_zoom_sens,
			func(v): G.cam_zoom_sens = v; G.save_settings()))
	var cb := CheckButton.new()
	cb.text = "Invert vertical"
	cb.button_pressed = G.cam_invert_y
	cb.add_theme_color_override("font_color", Color(0.9, 0.96, 0.98, 1))
	cb.toggled.connect(func(on): G.cam_invert_y = on; G.save_settings())
	vb.add_child(cb)
	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vb.add_child(spacer)
	vb.add_child(_make_drawer_button("Close", func(): _settings_panel.visible = false))

# Строка «подпись + ползунок + текущее значение». on_change(value) вызывается при движении.
func _settings_slider(label: String, value: float, on_change: Callable) -> Control:
	var row := VBoxContainer.new()
	row.add_theme_constant_override("separation", 2)
	var l := Label.new()
	l.text = label
	l.add_theme_font_size_override("font_size", 14)
	l.add_theme_color_override("font_color", Color(0.9, 0.96, 0.98, 1))
	row.add_child(l)
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 10)
	var s := HSlider.new()
	s.min_value = 0.2
	s.max_value = 3.0
	s.step = 0.05
	s.value = value
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	s.custom_minimum_size = Vector2(220, 32)
	var val := Label.new()
	val.text = "%.2f" % value
	val.custom_minimum_size = Vector2(52, 0)
	val.add_theme_color_override("font_color", Color(0.55, 0.85, 0.9, 1))
	s.value_changed.connect(func(v): val.text = "%.2f" % v; on_change.call(v))
	h.add_child(s)
	h.add_child(val)
	row.add_child(h)
	return row

func _toggle_settings() -> void:
	if _settings_panel == null:
		return
	_settings_panel.visible = not _settings_panel.visible
	if _settings_panel.visible and _drawer_open:
		_set_drawer(false)             # открыли настройки — прячем ящик техники

# ── Кнопка якоря (фиксация машины к миру, как блок-якорь в TerraTech) ──────────
# Иконка рисуется нодами (AnchorIcon._draw): кольцо + шток + лапы, картинка сразу понятна.
class AnchorIcon extends Control:
	var active := false
	func _draw() -> void:
		var c := size * 0.5
		var col := Color(0.3, 1.0, 0.5) if active else Color(0.88, 0.96, 0.98)
		var lw := 3.0
		draw_arc(c + Vector2(0, -14), 5.0, 0.0, TAU, 16, col, lw)          # кольцо
		draw_line(c + Vector2(0, -9), c + Vector2(0, 14), col, lw)          # шток
		draw_line(c + Vector2(-9, -2), c + Vector2(9, -2), col, lw)         # перекладина
		draw_arc(c + Vector2(0, 2), 13.0, PI * 0.15, PI * 0.85, 14, col, lw)  # лапы
		draw_line(c + Vector2(-12.3, 8.0), c + Vector2(-9.0, 3.2), col, lw)   # зубец левый
		draw_line(c + Vector2(12.3, 8.0), c + Vector2(9.0, 3.2), col, lw)     # зубец правый

var _anchor_btn: Button = null
var _anchor_icon: AnchorIcon = null
func _build_anchor_button() -> void:
	var screen: Vector2 = get_viewport().get_visible_rect().size
	_anchor_btn = Button.new()
	_anchor_btn.tooltip_text = "Anchor: lock the vehicle (level, 0°)"
	_anchor_btn.custom_minimum_size = Vector2(64, 64)
	_anchor_btn.add_theme_stylebox_override("normal", _make_button_style(false))
	_anchor_btn.add_theme_stylebox_override("hover", _make_button_style(false))
	_anchor_btn.add_theme_stylebox_override("pressed", _make_button_style(true))
	_anchor_btn.position = Vector2(16, screen.y - 170)
	_anchor_btn.pressed.connect(_on_anchor_pressed)
	_anchor_icon = AnchorIcon.new()
	_anchor_icon.set_anchors_preset(Control.PRESET_FULL_RECT)
	_anchor_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_anchor_btn.add_child(_anchor_icon)
	_anchor_btn.visible = false        # появится, когда на машине есть фикс-опора (тик радара)
	add_child(_anchor_btn)

func _on_anchor_pressed() -> void:
	var v: Node = _menu_vehicle_or_current()
	if v and v.has_method("toggle_anchor"):
		_anchor_icon.active = v.toggle_anchor()
		_anchor_icon.queue_redraw()

func _menu_vehicle_or_current() -> Node:
	var cc: Node = $".."
	if cc and "current_vehicle" in cc:
		return cc.current_vehicle
	return current_vehicle

# ── Круговое меню чужой машины (открывает vehicle_interact_button) ─────────────
# Колесо в стиле chatwheel: тёмный донат, секторы с разделителями, иконка + подпись
# в каждом секторе, центральный круг с синим кольцом = мёртвая зона (отмена).
# Жестовое: появляется вокруг 2D-кнопки машины (палец ещё зажат), тянешь к сектору
# (он подсвечивается) и отпускаешь — срабатывает. Отпустил в центре — отмена.
const VMENU_OUTER := 175.0
const VMENU_INNER := 64.0
var _vmenu: Control = null
var _vmenu_center: Vector2 = Vector2.ZERO
var _vmenu_wheel: Control = null
var _vmenu_count: int = 0
var _vmenu_vehicle: Node = null

class RadialWheel extends Control:
	var items: Array = []        # [[иконка, подпись], ...]
	var hovered: int = -1
	var outer := 175.0
	var inner := 64.0

	func _ready() -> void:
		size = Vector2(outer, outer) * 2.0
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		var c := size * 0.5
		var n := items.size()
		for i in n:
			var ang := -PI / 2 + TAU * float(i) / float(n)
			var mid := c + Vector2(cos(ang), sin(ang)) * ((outer + inner) * 0.53)
			var icon := Label.new()
			icon.text = items[i][0]
			icon.add_theme_font_size_override("font_size", 30)
			icon.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			icon.size = Vector2(120, 36)
			icon.position = mid - Vector2(60, 32)
			icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
			add_child(icon)
			var txt := Label.new()
			txt.text = items[i][1]
			txt.add_theme_font_size_override("font_size", 14)
			txt.add_theme_color_override("font_color", Color(0.92, 0.96, 1.0))
			txt.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			txt.size = Vector2(140, 20)
			txt.position = mid + Vector2(-70, 8)
			txt.mouse_filter = Control.MOUSE_FILTER_IGNORE
			add_child(txt)
		var cancel := Label.new()
		cancel.text = "CANCEL"
		cancel.add_theme_font_size_override("font_size", 15)
		cancel.add_theme_color_override("font_color", Color(0.85, 0.9, 0.96))
		cancel.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		cancel.size = Vector2(120, 20)
		cancel.position = c - Vector2(60, 10)
		cancel.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(cancel)

	func _draw() -> void:
		var c := size * 0.5
		var n := maxi(items.size(), 1)
		# донат-фон
		draw_circle(c, outer, Color(0.075, 0.095, 0.13, 0.93))
		# подсвеченный сектор (клин между inner и outer)
		if hovered >= 0:
			var a0 := -PI / 2 + TAU * (float(hovered) - 0.5) / float(n)
			var steps := 22
			var pts := PackedVector2Array()
			for s in steps + 1:
				var a := a0 + TAU / float(n) * float(s) / float(steps)
				pts.append(c + Vector2(cos(a), sin(a)) * outer)
			for s in steps + 1:
				var a := a0 + TAU / float(n) * float(steps - s) / float(steps)
				pts.append(c + Vector2(cos(a), sin(a)) * inner)
			draw_colored_polygon(pts, Color(0.18, 0.25, 0.34, 0.95))
		# разделители секторов
		for i in n:
			var ab := -PI / 2 + TAU * (float(i) - 0.5) / float(n)
			var dv := Vector2(cos(ab), sin(ab))
			draw_line(c + dv * inner, c + dv * outer, Color(1, 1, 1, 0.10), 2.0)
		# центральный круг + синее кольцо (мёртвая зона / отмена)
		draw_circle(c, inner, Color(0.05, 0.065, 0.095, 0.97))
		draw_arc(c, inner, 0, TAU, 64, Color(0.42, 0.58, 0.76, 0.9), 3.5)
		draw_arc(c, outer, 0, TAU, 64, Color(0, 0, 0, 0.35), 2.0)

func open_vehicle_menu(vehicle: Node, screen_pos: Vector2 = Vector2(-1, -1)) -> void:
	close_vehicle_menu()
	var screen: Vector2 = get_viewport().get_visible_rect().size
	# Центр колеса — где 2D-кнопка машины; прижимаем к экрану, чтобы не обрезалось.
	var center := screen * 0.5 if screen_pos.x < 0.0 else screen_pos
	center.x = clampf(center.x, VMENU_OUTER + 10.0, screen.x - VMENU_OUTER - 10.0)
	center.y = clampf(center.y, VMENU_OUTER + 10.0, screen.y - VMENU_OUTER - 10.0)
	_vmenu_center = center
	_vmenu_vehicle = vehicle
	_vmenu = Control.new()
	_vmenu.set_anchors_preset(Control.PRESET_FULL_RECT)
	_vmenu.mouse_filter = Control.MOUSE_FILTER_IGNORE   # ввод ловит hud._input, не UI
	add_child(_vmenu)
	var defense_on: bool = bool(vehicle.get("defense_mode"))
	var wheel := RadialWheel.new()
	wheel.outer = VMENU_OUTER
	wheel.inner = VMENU_INNER
	wheel.items = [
		["📦", "To inventory"],
		["🔧", "Disassemble"],
		["🛡", "Defense: OFF" if defense_on else "Defense: ON"],
		["🎥", "Control"],           # сменить камеру на эту машину/станцию
	]
	wheel.position = center - Vector2(VMENU_OUTER, VMENU_OUTER)
	_vmenu.add_child(wheel)
	_vmenu_wheel = wheel
	_vmenu_count = wheel.items.size()
	VehicleInteractButton.camera_block = true   # жест меню не должен крутить камеру

# Пока меню открыто — весь ввод сюда: движение подсвечивает сектор, отпускание выбирает.
func _input(event: InputEvent) -> void:
	if _vmenu == null:
		return
	var pos := Vector2.ZERO
	var is_motion := false
	var is_release := false
	if event is InputEventScreenDrag:
		pos = event.position; is_motion = true
	elif event is InputEventMouseMotion:
		pos = event.position; is_motion = true
	elif event is InputEventScreenTouch and not event.pressed:
		pos = event.position; is_release = true
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and not event.pressed:
		pos = event.position; is_release = true
	else:
		return
	var idx := _vmenu_pick(pos)
	if is_motion:
		if _vmenu_wheel and _vmenu_wheel.hovered != idx:
			_vmenu_wheel.hovered = idx
			_vmenu_wheel.queue_redraw()
		get_viewport().set_input_as_handled()
	elif is_release:
		var vehicle := _vmenu_vehicle
		close_vehicle_menu()
		if idx >= 0:
			_do_vmenu_action(idx, vehicle)
		get_viewport().set_input_as_handled()

# Какой пункт выбирает точка pos: -1 = мёртвая зона (отмена), иначе индекс по углу.
func _vmenu_pick(pos: Vector2) -> int:
	var v := pos - _vmenu_center
	if v.length() < VMENU_INNER:
		return -1
	var best := 0
	var best_d := INF
	for i in _vmenu_count:
		var ang := -PI / 2 + TAU * float(i) / float(_vmenu_count)
		var d: float = absf(angle_difference(v.angle(), ang))
		if d < best_d:
			best_d = d
			best = i
	return best

func _do_vmenu_action(idx: int, vehicle: Node) -> void:
	if vehicle == null or not is_instance_valid(vehicle):
		return
	match idx:
		0:
			if vehicle.has_method("send_to_inventory"):
				vehicle.send_to_inventory()
		1:
			if vehicle.has_method("disassemble"):
				vehicle.disassemble()
		2:
			if vehicle.has_method("set_defense"):
				vehicle.set_defense(not bool(vehicle.get("defense_mode")))
		3:
			# Сменить камеру: садимся управлять этой машиной/станцией.
			var cc: Node = get_tree().get_first_node_in_group("camera_controller")
			if cc and cc.has_method("switch_to_vehicle"):
				cc.switch_to_vehicle(vehicle)

func close_vehicle_menu() -> void:
	if _vmenu != null and is_instance_valid(_vmenu):
		_vmenu.queue_free()
	_vmenu = null
	_vmenu_wheel = null
	_vmenu_vehicle = null
	VehicleInteractButton.camera_block = false

# ── Панель поворота блока (низ по центру, только в режиме стройки) ─────────────
# Сетка 2×2: верхний ряд — НАКЛОН влево/вправо (крен вокруг Z), нижний ряд —
# ПОВОРОТ влево/вправо (вокруг Y). Иконки рисуются нодами (RotIcon._draw):
# кубик-блок + дуга-стрелка, никаких текстур.

# Стрелка направления поверх 3D-кубика (сам кубик — настоящий 3D в SubViewport).
# kind: tilt_left / tilt_right — дуга над кубом (крен), yaw_left / yaw_right —
# сплюснутый эллипс вокруг куба (поворот в горизонтальной плоскости).
class RotIcon extends Control:
	var kind := "yaw_left"
	const COL := Color(0.95, 0.99, 1.0, 1)

	func _arrow(p: Vector2, dir: Vector2) -> void:
		var n := Vector2(-dir.y, dir.x)
		draw_colored_polygon(PackedVector2Array([
			p + dir * 8.0, p + n * 4.5, p - n * 4.5]), COL)

	func _draw() -> void:
		var c := size * 0.5
		var lw := 2.5
		var r := minf(size.x, size.y) * 0.5 - 6.0
		if kind.begins_with("tilt"):
			# дуга над кубом: слева-сверху-направо (экранная плоскость = крен)
			var a0 := -PI + 0.55
			var a1 := -0.55
			draw_arc(c, r, a0, a1, 20, COL, lw)
			if kind == "tilt_right":
				var p := c + Vector2(cos(a1), sin(a1)) * r
				_arrow(p, Vector2(-sin(a1), cos(a1)))
			else:
				var p := c + Vector2(cos(a0), sin(a0)) * r
				_arrow(p, Vector2(sin(a0), -cos(a0)))
		else:
			# сплюснутый эллипс = горизонтальная плоскость вокруг куба (вид сверху под 45°)
			var ec := c + Vector2(0, 7)
			draw_set_transform(ec, 0.0, Vector2(1.0, 0.45))
			draw_arc(Vector2.ZERO, r, 0.35, PI - 0.35, 20, COL, lw)
			draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
			# Стрелка на конце дуги, по касательной наружу: правый конец (a=0.35) —
			# против роста угла, левый (a=PI-0.35) — по росту.
			var a := 0.35 if kind == "yaw_right" else PI - 0.35
			var p := ec + Vector2(cos(a) * r, sin(a) * r * 0.45)
			var t := Vector2(-sin(a), cos(a) * 0.45).normalized()
			_arrow(p, -t if kind == "yaw_right" else t)

# ── Панель «убрать блок из руки» (стройка) ─────────────────────────────────────
# Две кнопки: спрятать блок В ИНВЕНТАРЬ (ящик) и бросить его В МИР (блок падает на землю). Иконки
# РИСУЕМ в коде (шрифт проекта не рендерит эмодзи — были пустые кнопки). Видна в стройке рядом с
# кнопкой Take/Place, когда в руке есть блок. Стиль — палитра tech_ui, как у остальных панелей.
var _hand_panel: PanelContainer
func _build_hand_panel() -> void:
	_hand_panel = PanelContainer.new()
	_hand_panel.add_theme_stylebox_override("panel", _make_float_panel_style())
	_hand_panel.visible = false
	add_child(_hand_panel)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	_hand_panel.add_child(row)
	# Кнопку «в инвентарь» держим ссылкой: с РЕСУРСОМ в руке она бессмысленна — инвентарь
	# хранит типы блоков, руде там места нет, — и её надо гасить, а не молча ничего не делать.
	_stash_btn = _hand_btn(InvIcon.new(), "Inventory", "Put the held block into inventory",
			func(): _hand_action("stash"))
	row.add_child(_stash_btn)
	row.add_child(_hand_btn(DropIcon.new(), "Drop", "Drop the held item into the world", func(): _hand_action("drop")))

var _stash_btn: Button = null

# Кнопка = ИКОНКА сверху + ПОДПИСЬ снизу (подписи чинят «непонятность» иконок — шрифт текст рендерит).
func _hand_btn(icon: Control, label: String, tip: String, cb: Callable) -> Button:
	var b := Button.new()
	b.custom_minimum_size = Vector2(84, 72)
	b.tooltip_text = tip
	b.add_theme_stylebox_override("normal", _make_button_style(false))
	b.add_theme_stylebox_override("hover", _make_button_style(false))
	b.add_theme_stylebox_override("pressed", _make_button_style(true))
	icon.set_anchors_preset(Control.PRESET_TOP_WIDE)
	icon.offset_top = 5
	icon.offset_bottom = 47
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	b.add_child(icon)
	var lbl := Label.new()
	lbl.text = label
	lbl.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	lbl.offset_top = -22
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	lbl.add_theme_font_size_override("font_size", 11)
	lbl.add_theme_color_override("font_color", Color(0.88, 0.96, 0.98, 1))
	lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	b.add_child(lbl)
	b.pressed.connect(cb)
	return b

# Рисованные иконки для кнопок руки (эмодзи шрифт не тянет). Стиль — тонкая светлая обводка,
# как AnchorIcon/RotIcon.
class InvIcon extends Control:            # «в инвентарь»: стрелка вниз в ОТКРЫТУЮ коробку (с створками)
	func _draw() -> void:
		var c := size * 0.5
		var col := Color(0.88, 0.96, 0.98)
		var lw := 2.6
		# открытая коробка: отогнутая створка → стенка → дно → стенка → отогнутая створка
		draw_polyline(PackedVector2Array([
			c + Vector2(-15, -2), c + Vector2(-11, 3), c + Vector2(-11, 13),
			c + Vector2(11, 13),  c + Vector2(11, 3),  c + Vector2(15, -2)]), col, lw)
		# стрелка ВНИЗ внутрь коробки
		draw_line(c + Vector2(0, -16), c + Vector2(0, 0), col, lw)
		draw_line(c + Vector2(-5, -5), c + Vector2(0, 0), col, lw)
		draw_line(c + Vector2(5, -5), c + Vector2(0, 0), col, lw)

class DropIcon extends Control:           # «в мир»: блок падает стрелкой вниз на землю
	func _draw() -> void:
		var c := size * 0.5
		var col := Color(0.88, 0.96, 0.98)
		var lw := 2.6
		draw_rect(Rect2(c + Vector2(-6, -18), Vector2(12, 11)), col, false, lw)  # падающий блок
		draw_line(c + Vector2(0, -5), c + Vector2(0, 7), col, lw)                # стрелка вниз…
		draw_line(c + Vector2(-5, 2), c + Vector2(0, 7), col, lw)
		draw_line(c + Vector2(5, 2), c + Vector2(0, 7), col, lw)
		draw_line(c + Vector2(-13, 15), c + Vector2(13, 15), col, lw)            # земля (мир)
		draw_line(c + Vector2(-9, 19), c + Vector2(-5, 15), col, lw * 0.8)       # штриховка грунта
		draw_line(c + Vector2(2, 19), c + Vector2(6, 15), col, lw * 0.8)

func _hand_action(kind: String) -> void:
	var v: Node = _menu_vehicle_or_current()
	if v == null:
		return
	if kind == "stash" and v.has_method("stash_hand_to_inventory"):
		v.stash_hand_to_inventory()
	elif kind == "drop" and v.has_method("drop_hand_to_world"):
		v.drop_hand_to_world()
	if _block_globe:
		_block_globe.refresh()             # инвентарь мог измениться (стос в инвентарь)

func _update_hand_panel() -> void:
	if _hand_panel == null:
		return
	var v: Node = _menu_vehicle_or_current()
	# Панель гасил общий признак «открыт гараж» — но стройка ИДЁТ с открытым гаражом: взяв
	# блок, tech_ui не закрывается, а переключается на вкладку СТРОЙКА (см. _take_into_hand).
	# Поэтому кнопок «в инвентарь» и «в мир» в стройке не было видно вообще никогда — ровно
	# там, где они и нужны. Гараж на вкладке СТРОЙКА равносилен закрытому: мир кликабелен,
	# левая панель убрана.
	var overlay_ok: bool = (not _controls_hidden) or _build_tab_open()
	var show_it: bool = overlay_ok and v != null and ("block_take" in v) and v.block_take \
			and ("Building" in v) and v.Building
	if _hand_panel.visible != show_it:
		_hand_panel.visible = show_it
		if show_it:
			# Гараж добавлен в HUD позже — он рисуется поверх. Поднимаем панель над ним,
			# как это уже делают глобус и кнопки поворота.
			move_child(_hand_panel, get_child_count() - 1)
	if show_it and _stash_btn != null:
		var res_in_hand: bool = ("hand_kind" in v) and int(v.hand_kind) == 2   # Hand.RESOURCE
		_stash_btn.disabled = res_in_hand
		_stash_btn.modulate = Color(1, 1, 1, 0.35 if res_in_hand else 1.0)
	if show_it:
		# Слева, НАД кнопками поворота: всё, что делается с блоком в руке, — одной колонкой.
		# Раньше панель липла к кнопке Take справа, но в стройке Take прячет гараж, а правый
		# край занимает его же панель — кнопки оказывались под ней.
		var screen: Vector2 = get_viewport().get_visible_rect().size
		var rot_top: float = screen.y * 0.5 - 70.0
		if _rotate_panel != null and is_instance_valid(_rotate_panel):
			rot_top = _rotate_panel.position.y
		_hand_panel.position = Vector2(16.0, rot_top - 12.0 - _hand_panel.size.y)

func _build_rotate_panel() -> void:
	var screen: Vector2 = get_viewport().get_visible_rect().size
	_rotate_panel = PanelContainer.new()
	_rotate_panel.add_theme_stylebox_override("panel", _make_float_panel_style())
	_rotate_panel.visible = false
	var pw: float = 180.0
	_rotate_panel.size = Vector2(pw, 140)
	_rotate_panel.position = Vector2(16.0, screen.y * 0.5 - 70.0)
	add_child(_rotate_panel)
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 8)
	grid.add_theme_constant_override("v_separation", 8)
	_rotate_panel.add_child(grid)
	# верхний ряд — наклон (крен вокруг оси Z), нижний — поворот (вокруг Y)
	grid.add_child(_rot_btn("tilt_left",  "Tilt left",   Vector3.BACK,  PI / 2))
	grid.add_child(_rot_btn("tilt_right", "Tilt right",  Vector3.BACK, -PI / 2))
	grid.add_child(_rot_btn("yaw_left",   "Turn left",   Vector3.UP,    PI / 2))
	grid.add_child(_rot_btn("yaw_right",  "Turn right",  Vector3.UP,   -PI / 2))

# ── «Гироскоп» выбора блока (стройка) ──────────────────────────────────────────
# Квадрат SIZE×SIZE у правого-нижнего края, ЛЕВЕЕ колонки кнопок Take/TakeOff (они
# ~200px у правой кромки — виджет их не перекрывает и не ворует их тапы). Внутри —
# два скрещенных овала-кольца «Х»: блоки и категории, крутятся диагональными
# драгами; тап без движения берёт выбранный блок в руку — см. block_globe.gd.
func _globe_pos(screen: Vector2) -> Vector2:
	# 218 — чтобы до колонки Take/TakeOff (~200px у правой кромки) оставался зазор под палец.
	# С Attack виджет пересекается, но они взаимоисключающие: Attack виден только в movement,
	# гироскоп — только в building (_on_movement_pressed/_on_building_pressed).
	return Vector2(screen.x - BlockGlobe.SIZE - 218.0, screen.y - BlockGlobe.SIZE - 6.0)

func _build_block_globe() -> void:
	var globe := BlockGlobe.new()
	globe.size = Vector2(BlockGlobe.SIZE, BlockGlobe.SIZE)
	globe.position = _globe_pos(get_viewport().get_visible_rect().size)
	globe.visible = false
	globe.view_pitch = globe_tilt        # начальные наклон/прокрут из инспектора HUD
	globe.view_yaw = globe_spin
	globe.block_chosen.connect(_on_globe_block_chosen)
	add_child(globe)                     # _ready глобуса построит вид с этими значениями
	_block_globe = globe

func _on_globe_block_chosen(block_type: int) -> void:
	var v: Node = _menu_vehicle_or_current()
	if v == null or not v.has_method("take_block_into_hand"):
		return
	if not v.take_block_into_hand(block_type):
		return
	G.block_inventory.erase(block_type)          # списываем взятый экземпляр (блок из руки вернулся в inv внутри take)
	G.mark_progress_dirty()
	if _block_globe:
		_block_globe.refresh()

func _rot_btn(kind: String, tip: String, axis: Vector3, ang: float) -> Button:
	var b := Button.new()
	b.custom_minimum_size = Vector2(74, 62)
	b.tooltip_text = tip
	b.add_theme_stylebox_override("normal", _make_button_style(false))
	b.add_theme_stylebox_override("hover", _make_button_style(false))
	b.add_theme_stylebox_override("pressed", _make_button_style(true))
	b.add_child(_cube_view(kind))
	var ic := RotIcon.new()
	ic.kind = kind
	ic.set_anchors_preset(Control.PRESET_FULL_RECT)
	ic.mouse_filter = Control.MOUSE_FILTER_IGNORE
	b.add_child(ic)
	b.pressed.connect(func(): _rotate_block(axis, ang))
	return b

# Настоящий 3D-куб внутри кнопки: свой мини-мир в SubViewport, камера смотрит на куб
# СВЕРХУ под углом 45°. Ряд «наклон» показывает куб уже накренённым в сторону действия,
# ряд «поворот» — куб, довёрнутый по Y. Рендерится только пока панель видна (стройка),
# вьюпорт крошечный — по цене это ничто.
func _cube_view(kind: String) -> SubViewportContainer:
	var svc := SubViewportContainer.new()
	svc.stretch = true
	svc.set_anchors_preset(Control.PRESET_FULL_RECT)
	svc.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sv := SubViewport.new()
	sv.own_world_3d = true
	sv.transparent_bg = true
	sv.render_target_update_mode = SubViewport.UPDATE_WHEN_VISIBLE
	svc.add_child(sv)

	var cam := Camera3D.new()
	cam.fov = 40.0
	# 45° сверху: позиция по дуге (0, sin45, cos45)·d, наклон камеры -45° по X.
	var d := 3.2
	cam.transform = Transform3D(Basis(Vector3.RIGHT, -PI / 4), Vector3(0, d * sin(PI / 4), d * cos(PI / 4)))
	sv.add_child(cam)

	var light := DirectionalLight3D.new()
	light.rotation = Vector3(-0.9, -0.5, 0)
	sv.add_child(light)

	var box := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = Vector3.ONE
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.35, 0.72, 0.78)
	mat.roughness = 0.6
	mesh.material = mat
	box.mesh = mesh
	match kind:                      # куб показывает РЕЗУЛЬТАТ нажатия
		"tilt_left":  box.rotation = Vector3(0, 0,  0.4)
		"tilt_right": box.rotation = Vector3(0, 0, -0.4)
		"yaw_left":   box.rotation = Vector3(0,  0.5, 0)
		"yaw_right":  box.rotation = Vector3(0, -0.5, 0)
	sv.add_child(box)
	return svc

func _rotate_block(axis: Vector3, ang: float) -> void:
	var v: Node = current_vehicle
	var cc: Node = $".."
	if cc and "current_vehicle" in cc:
		v = cc.current_vehicle
	if v and v.has_method("rotate_build"):
		v.rotate_build(axis, ang)

func _process(delta: float) -> void:
	$Label.text = str(int(Engine.get_frames_per_second())) + " FPS"
	_update_radar(delta)
	_update_hand_panel()
	_sync_mode_visuals()      # дешёвый сторож: работает только когда режим реально сменился

# Радар обновляем не каждый кадр (сбор блипов — O(враги+жилы)): раз в 0.15с. Виден только
# если у активной машины есть блок RADAR. Блипы: враги (красные), активные жилы (жёлтые).
# Энергия текущей машины — дугой по ободу радара (см. RadarHUD).
var _radar_t: float = 0.0
func _update_radar(delta: float) -> void:
	if _radar == null:
		return
	_radar_t -= delta
	if _radar_t > 0.0:
		return
	_radar_t = 0.15
	var v: Node = _menu_vehicle_or_current()
	# Кнопка якоря видна ТОЛЬКО если машина может якориться (есть фикс-опора SUPPORT или это
	# база) и инвентарь закрыт. Без опоры — кнопки нет (по ТЗ: без неё нельзя сесть на якорь).
	if _anchor_btn:
		_anchor_btn.visible = (not _controls_hidden) and v != null \
				and v.has_method("can_anchor") and v.can_anchor()
	# Размер и охват — по наличию блока RADAR; сама карта видна, пока есть машина.
	var on: bool = _has_radar(v)
	var want: float = RADAR_SIZE_FULL if on else RADAR_SIZE_SMALL
	if not is_equal_approx(_radar_size, want):
		_radar_size = want
		_radar.size = Vector2(want, want)
		_radar.range_world = RADAR_RANGE_FULL if on else RADAR_RANGE_SMALL
		_radar.position = _radar_pos(get_viewport().get_visible_rect().size)
		_layout_money()
		_push_quest_top(true)      # карта и трекер квестов делят правый верхний угол
	var live: bool = v != null and v is Node3D and not _controls_hidden
	if _money_panel:
		_money_panel.visible = live
	if _quest_compass:
		_quest_compass.visible = live
	if _radar.visible != live:
		_radar.visible = live
		_push_quest_top(live)
	if not live:
		return
	var origin: Vector3 = (v as Node3D).global_position
	var fwd: Vector3 = -(v as Node3D).global_transform.basis.z
	var head := Vector2(fwd.x, fwd.z)
	_radar.heading = head.normalized() if head.length() > 0.01 else Vector2.UP
	_radar.fill = v.energy_fill() if v.has_method("energy_fill") else 0.0
	_radar.has_cap = v.has_method("energy_cap") and v.energy_cap() > 0.0
	var blips: Array = []
	var vehicles := get_node_or_null("/root/Main/Vehicles")
	if vehicles:
		for e in vehicles.get_children():
			if e == v or not (e is Node3D):
				continue
			var f = e.get("faction")
			if f != null and int(f) != 0:
				var rel: Vector3 = (e as Node3D).global_position - origin
				blips.append({"p": Vector2(rel.x, rel.z), "c": Color(1.0, 0.32, 0.32)})
	var rn := get_node_or_null("/root/Main/map/Resource_Nodes")
	if rn and rn.has_method("active_positions"):
		for wp in rn.active_positions():
			var rel2: Vector3 = (wp as Vector3) - origin
			blips.append({"p": Vector2(rel2.x, rel2.z), "c": Color(1.0, 0.82, 0.25)})
	_radar.blips = blips
	_radar.queue_redraw()

# Есть ли у машины блок RADAR (тогда показываем радар-карту).
func _has_radar(v) -> bool:
	if v == null or not ("block_map_node" in v) or v.block_map_node == null:
		return false
	for b in v.block_map_node.get_children():
		if "block" in b and int(b.block) == G.Block.RADAR:
			return true
	return false

# ── Иконка меню: рюкзак (вход в инвентарь) ────────────────────────────────────
class MenuIcon extends Control:
	# Рюкзак — КАРТИНКА (images/icon_backpack.png), раньше рисовался примитивами.
	#
	# Исходник — чёрный силуэт на белом JPEG, и в таком виде он на кнопку не годится:
	# белый фон непрозрачен, а сам рюкзак чёрный, то есть на тёмно-бирюзовой кнопке вышел бы
	# белый квадрат с невидимым рюкзаком внутри. Поэтому в PNG силуэт переложен в АЛЬФУ, а
	# цвет оставлен белым — modulate при отрисовке красит его в палитру HUD, и значок живёт
	# в том же цвете, что панели и остальные иконки. Порог при переводе съел звон JPEG на
	# фоне, полутона по краям остались и дают сглаживание.
	const TEX := preload("res://images/icon_backpack.png")
	const PAD: float = 0.14        # поле, чтобы значок не липнул к рамке кнопки

	func _draw() -> void:
		var s: float = minf(size.x, size.y) * (1.0 - PAD * 2.0)
		draw_texture_rect(TEX, Rect2((size - Vector2(s, s)) * 0.5, Vector2(s, s)), false,
				Color(0.85, 0.95, 0.97))

var _menu_icon: MenuIcon = null

# ── Цели и блокировка для обучающего пальца ──────────────────────────────────
# Наставник (tutorial_director.gd) спрашивает узлы по имени, а не лезет внутрь HUD.
func tutorial_target(key: String) -> Control:
	match key:
		"menu":      return _menu_btn
		"inventory": return _menu_btn      # иконка и есть вход в инвентарь
		"garage":    return _tech_ui       # null, пока гараж ни разу не открывали
	return null

## На шагах со свободным миром (собери все блоки) тапы по миру нужны, а UI — нет.
## Заглушка обучения тут не годится: она бы съела и мировой тап вместе с UI.
func set_ui_locked(locked: bool) -> void:
	if _menu_btn:
		_menu_btn.disabled = locked
	if _handle:
		_handle.disabled = locked
	if locked:
		_set_drawer(false)

# ── Сборка меню целиком в коде (тема — как у tech_ui) ─────────────────────────
func _build_menu_button() -> void:
	# Одна кнопка-иконка в левом верхнем углу: тап — и сразу гараж. Выпадающего меню больше
	# нет, содержимое разошлось по вкладкам гаража и по правому ящику с техникой.
	_menu_btn = Button.new()
	_menu_btn.tooltip_text = "Inventory"
	_menu_btn.custom_minimum_size = Vector2(MENU_BTN, MENU_BTN)
	_menu_btn.size = Vector2(MENU_BTN, MENU_BTN)
	_menu_btn.position = Vector2(MENU_PAD, MENU_PAD)
	_menu_btn.add_theme_stylebox_override("normal", _make_button_style(false))
	_menu_btn.add_theme_stylebox_override("hover", _make_button_style(false))
	_menu_btn.add_theme_stylebox_override("pressed", _make_button_style(true))
	_menu_btn.pressed.connect(_open_garage)
	_menu_icon = MenuIcon.new()
	_menu_icon.set_anchors_preset(Control.PRESET_FULL_RECT)
	_menu_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_menu_btn.add_child(_menu_icon)
	add_child(_menu_btn)

	# Правый ящик с ТЕХНИКОЙ — как было до переделки HUD: язычок у края, по тапу выезжает
	# список машин. В гараж он не переехал: пересаживаться между машинами надо на ходу, а не
	# через полноэкранное меню.
	_build_vehicle_drawer()

# ── Правый ящик: смена машины ────────────────────────────────────────────────
# Вернулся туда, где был до переделки HUD: язычок у правого края, по тапу выезжает список
# машин. В гараж он не поехал — пересаживаться надо на ходу, а не через полноэкранное меню.
const DRAWER_W: float = 250.0
const DRAWER_H_RATIO: float = 0.46
var _drawer: PanelContainer = null
var _handle: Button = null
var _drawer_open: bool = false
var _drawer_tween: Tween = null

func _build_vehicle_drawer() -> void:
	var screen: Vector2 = get_viewport().get_visible_rect().size
	var dh: float = screen.y * DRAWER_H_RATIO
	var dy: float = (screen.y - dh) * 0.5

	_drawer = PanelContainer.new()
	_drawer.add_theme_stylebox_override("panel", _make_panel_style())
	_drawer.size = Vector2(DRAWER_W, dh)
	_drawer.position = Vector2(screen.x, dy)      # стартует за краем экрана
	add_child(_drawer)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 10)
	vb.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_drawer.add_child(vb)

	var title := Label.new()
	title.text = "VEHICLES"
	title.add_theme_color_override("font_color", Color(0.55, 0.85, 0.9, 1))
	title.add_theme_font_size_override("font_size", 20)
	vb.add_child(title)

	# Список строится при каждом открытии: машины известны только после _ready
	# камеры-контроллера, а он отрабатывает позже HUD.
	_vehicle_list = VBoxContainer.new()
	_vehicle_list.add_theme_constant_override("separation", 6)
	vb.add_child(_vehicle_list)

	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vb.add_child(spacer)

	_handle = Button.new()
	_handle.text = "<"
	_handle.add_theme_font_size_override("font_size", 28)
	_handle.add_theme_stylebox_override("normal", _make_button_style(false))
	_handle.add_theme_stylebox_override("hover", _make_button_style(false))
	_handle.add_theme_stylebox_override("pressed", _make_button_style(true))
	_handle.add_theme_color_override("font_color", Color(0.85, 0.95, 0.97, 1))
	_handle.custom_minimum_size = Vector2(50, 72)
	_handle.size = Vector2(50, 72)
	_handle.position = Vector2(screen.x - 50, dy + dh * 0.5 - 36)
	_handle.pressed.connect(_toggle_drawer)
	add_child(_handle)

func _toggle_drawer() -> void:
	_set_drawer(not _drawer_open)

func _set_drawer(open: bool) -> void:
	if _drawer == null:
		return
	_drawer_open = open
	if open:
		_rebuild_vehicle_list()
	var screen: Vector2 = get_viewport().get_visible_rect().size
	var target_x: float = (screen.x - DRAWER_W) if open else screen.x
	var handle_x: float = (screen.x - DRAWER_W - 50.0) if open else (screen.x - 50.0)
	if _drawer_tween and _drawer_tween.is_valid():
		_drawer_tween.kill()
	var tw := create_tween().set_parallel(true)
	_drawer_tween = tw
	tw.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tw.tween_property(_drawer, "position:x", target_x, 0.22)
	if _handle:
		tw.tween_property(_handle, "position:x", handle_x, 0.22)
		_handle.text = ">" if open else "<"

# ── Действия панели ───────────────────────────────────────────────────────────
func _toggle_inventory() -> void:
	if _tech_ui == null:
		_tech_ui = TECH_UI.instantiate()
		_tech_ui.visible = false          # известное состояние до add_child (без вспышки)
		add_child(_tech_ui)
		# Один обработчик на открытие И закрытие (в т.ч. крестиком X и при взятии блока):
		# прячем/возвращаем игровые кнопки, чтобы они не светились сквозь инвентарь.
		_tech_ui.visibility_changed.connect(_on_tech_ui_visibility)
		if _tech_ui.has_signal("tab_changed"):
			_tech_ui.tab_changed.connect(func(_i: int) -> void: _update_build_widgets())
	_set_drawer(false)
	_tech_ui.visible = not _tech_ui.visible
	if _tech_ui.visible and _tech_ui.has_method("refresh"):
		_tech_ui.refresh()

## Иконка в углу: открыть гараж на ИНВЕНТАРЕ. Отдельно от _toggle_inventory, потому что
## вход в стройку открывает тот же гараж, но на своей вкладке.
func _open_garage() -> void:
	if _tech_ui == null or not _tech_ui.visible:
		_toggle_inventory()
	if _tech_ui != null and _tech_ui.has_method("open_tab"):
		_tech_ui.open_tab(TECH_TAB_INVENTORY)

const TECH_TAB_INVENTORY: int = 0
const TECH_TAB_BUILD: int = 6

## Вход в режим стройки: тот же гараж, но сразу на вкладке СТРОЙКА. Она прячет левую панель,
## чтобы было видно машину; глобус и кнопки поворота остаются на своих местах поверх мира.
func _open_build_tab() -> void:
	if _tech_ui == null or not _tech_ui.visible:
		_toggle_inventory()
	if _tech_ui != null and _tech_ui.has_method("open_tab"):
		_tech_ui.open_tab(TECH_TAB_BUILD)

# Глобус и кнопки поворота видны РОВНО тогда, когда гараж открыт на вкладке СТРОЙКА.
# Никуда они не переезжали: лежат поверх мира там же, где и раньше.
func _build_tab_open() -> bool:
	return _tech_ui != null and is_instance_valid(_tech_ui) and _tech_ui.visible \
			and _tech_ui.has_method("current_tab") and int(_tech_ui.current_tab()) == TECH_TAB_BUILD

func _update_build_widgets() -> void:
	var on: bool = _build_tab_open()
	if _rotate_panel:
		_rotate_panel.visible = on
	if _block_globe:
		_block_globe.visible = on
		if on:
			_block_globe.refresh()     # инвентарь мог измениться с прошлого раза
	if not on:
		return
	# Гараж добавлен в HUD ПОЗЖЕ этих виджетов, значит рисуется поверх — его тёмная подложка
	# гасила блоки в глобусе. Поднимаем их в конец списка детей, чтобы легли на гараж сверху.
	for w in [_rotate_panel, _block_globe]:
		if w != null and is_instance_valid(w) and w.get_parent() == self:
			move_child(w, get_child_count() - 1)

## Машина изменилась (блок поставлен или снят) — зовёт сама машина. Гараж пересчитывает
## вес и характеристики, глобус — остаток блоков в инвентаре.
func notify_build_changed() -> void:
	if _tech_ui != null and is_instance_valid(_tech_ui) and _tech_ui.has_method("notify_build_changed"):
		_tech_ui.notify_build_changed()
	if _block_globe != null and is_instance_valid(_block_globe) and _block_globe.visible:
		_block_globe.refresh()

func _on_tech_ui_visibility() -> void:
	var open: bool = _tech_ui != null and _tech_ui.visible
	if not open:
		# Панель только скрывается (visible=false), фокус (напр. поле поиска) сам не
		# снимается — на ПК залипший фокус в LineEdit гасил бы клавиатурные действия
		# машины и после закрытия гаража (см. vehicle_body_3d._typing_in_ui).
		var focused := get_viewport().gui_get_focus_owner()
		if focused != null:
			focused.release_focus()
	if open:
		Q.report("garage_opened", 1)   # шаг обучения «зайти в гараж»
	# Гараж закрыли — выходим из стройки: пока он открыт, машина остаётся левитировать,
	# на какой бы вкладке игрок ни находился (так и просили).
	if not open:
		var v: Node = _menu_vehicle_or_current()
		if v != null and ("Building" in v) and v.Building and v.has_method("_on_movement_pressed"):
			v._on_movement_pressed()
	_set_game_controls_hidden(open)
	_update_build_widgets()
	# Гараж музыку НЕ переключает: в нём продолжает играть музыка путешествий.
	# Тип «меню» зарезервирован под будущее главное меню игры (кнопка «Начать» и т.д.).
	# Уводим трекер квестов вниз, чтобы не перекрывал статистику и кнопку закрытия.
	for q in get_tree().get_nodes_in_group("quests"):
		if q.has_method("set_inventory_open"):
			q.set_inventory_open(open)

# ── Выбор техники (список в drawer) ───────────────────────────────────────────
func _player_vehicles() -> Array:
	var cc: Node = $".."
	if cc and "vehicles" in cc:
		return cc.vehicles
	return []

func _rebuild_vehicle_list() -> void:
	if _vehicle_list == null:
		return
	for c in _vehicle_list.get_children():
		c.queue_free()
	var cur: Node = current_vehicle
	var cc: Node = $".."
	if cc and "current_vehicle" in cc:
		cur = cc.current_vehicle
	var i := 0
	for v in _player_vehicles():
		if not is_instance_valid(v):
			continue
		i += 1
		var is_cur: bool = (v == cur)
		var label: String = ("● " if is_cur else "  ") + str(v.name)
		var btn := _make_drawer_button(label, _select_vehicle.bind(v))
		if is_cur:
			btn.add_theme_color_override("font_color", Color(1.0, 0.65, 0.2, 1))  # текущая — оранжевым
			btn.disabled = true
		_vehicle_list.add_child(btn)
	if i == 0:
		var empty := Label.new()
		empty.text = "no vehicles"
		empty.modulate = Color(1, 1, 1, 0.5)
		_vehicle_list.add_child(empty)

func _select_vehicle(v: Node) -> void:
	var cc: Node = $".."
	if cc and cc.has_method("switch_to_vehicle") and is_instance_valid(v):
		cc.switch_to_vehicle(v)
		current_vehicle = cc.current_vehicle
	_rebuild_vehicle_list()        # обновляем подсветку текущей

# ── Прятать/возвращать игровой HUD под инвентарём ─────────────────────────────
func _collect_game_controls() -> void:
	_game_controls.clear()
	for n in ["ModeToggle", "Take", "TakeOff", "Attack",
			"Joystick_movement", "Joystick_camera", "Label"]:
		var node: Node = get_node_or_null(n)
		if node:
			_game_controls.append(node)
	# _drawer НЕ в общем списке: его видимость — это _drawer_open. Скопом выставленный
	# visible=true вернул бы уже закрытый ящик, ловящий тапы за краем.
	if _handle:
		_game_controls.append(_handle)
	if _menu_btn:
		_game_controls.append(_menu_btn)
	# _rotate_panel и _block_globe НЕ в общем списке: их видимость — это вкладка СТРОЙКА
	# в гараже, а скоп «спрятать игровой HUD» её бы затирал.
	if _radar:
		_game_controls.append(_radar)
	# _anchor_btn НЕ в общем списке: его видимостью рулит тик радара (нужна фикс-опора).

var _controls_hidden: bool = false
func _set_game_controls_hidden(hidden: bool) -> void:
	_controls_hidden = hidden
	if hidden:
		_set_drawer(false)             # под инвентарём ящик закрываем, а не просто прячем
	for n in _game_controls:
		if is_instance_valid(n):
			n.visible = not hidden
	# При закрытии инвентаря возвращаем кнопки в правильный режим машины
	# (мог поменяться, если игрок взял блок в руку → стройка).
	if not hidden:
		_apply_mode_visibility()

func _apply_mode_visibility() -> void:
	var v: Node = current_vehicle
	var cc: Node = $".."
	if cc and "current_vehicle" in cc:
		v = cc.current_vehicle
	if v and "Building" in v and v.Building:
		_on_building_pressed()
	else:
		_on_movement_pressed()

# ── Стили (тёмно-бирюзовая палитра tech_ui) ───────────────────────────────────
func _make_panel_style() -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = Color(0.043, 0.122, 0.149, 0.95)
	s.border_color = Color(0.247, 0.6, 0.65, 0.5)
	s.set_border_width(SIDE_LEFT, 2)
	s.set_border_width(SIDE_TOP, 1)
	s.set_border_width(SIDE_BOTTOM, 1)
	s.corner_radius_top_left = 10
	s.corner_radius_bottom_left = 10
	s.content_margin_left = 14
	s.content_margin_right = 14
	s.content_margin_top = 12
	s.content_margin_bottom = 12
	return s

# Стиль для ПЛАВАЮЩИХ панелей (поворот блока, рука): ВСЕ углы скруглены и рамка со всех сторон —
# _make_panel_style скругляет только левую кромку (он для приклеенных к правому краю ящиков), из-за
# чего в центре экрана правый бок был «квадратным».
func _make_float_panel_style() -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = Color(0.043, 0.122, 0.149, 0.95)
	s.border_color = Color(0.247, 0.6, 0.65, 0.5)
	s.set_border_width_all(2)
	s.set_corner_radius_all(14)
	s.content_margin_left = 12
	s.content_margin_right = 12
	s.content_margin_top = 10
	s.content_margin_bottom = 10
	return s

func _make_button_style(pressed: bool) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = Color(0.247, 0.6, 0.65, 1) if pressed else Color(0.082, 0.235, 0.275, 0.95)
	s.border_color = Color(0.247, 0.6, 0.65, 0.45)
	s.set_border_width_all(1)
	s.set_corner_radius_all(6)
	s.content_margin_left = 12
	s.content_margin_right = 12
	s.content_margin_top = 12
	s.content_margin_bottom = 12
	return s

func _make_drawer_button(label: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = label
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.add_theme_font_size_override("font_size", 18)
	b.add_theme_color_override("font_color", Color(0.88, 0.96, 0.98, 1))
	b.add_theme_stylebox_override("normal", _make_button_style(false))
	b.add_theme_stylebox_override("hover", _make_button_style(false))
	b.add_theme_stylebox_override("pressed", _make_button_style(true))
	b.pressed.connect(cb)
	return b

# ── Режимы: одна кнопка на оба ────────────────────────────────────────────────
# Кнопка ModeToggle шлёт действие ModeToggle — машина по нему сама решает, куда
# переключаться (см. vehicle_body_3d). Сюда прилетает её сигнал pressed; читать режим
# прямо тут нельзя — порядок «действие раньше сигнала» не гарантирован, поэтому
# перекладываем визуал на следующий кадр, когда Building уже точно новый.
func _on_mode_toggle_pressed() -> void:
	_sync_mode_visuals.call_deferred()

# Визуал режима ведём ОТ СОСТОЯНИЯ машины, а не от факта нажатия кнопки: в стройку можно
# попасть и мимо кнопки (клавиша B на ПК, взятие блока в руку из «гироскопа»), и раньше
# подпись с панелями оставались от прошлого режима до открытия/закрытия гаража.
var _mode_was_building: bool = false
var _mode_was_vehicle: Node = null

func _sync_mode_visuals() -> void:
	var v: Node = _menu_vehicle_or_current()
	var building: bool = v != null and ("Building" in v) and v.Building
	# СМЕНА МАШИНЫ (пересел, возродился) — состояние сторожа относится к прежней машине и
	# сравнивать с ним нечего. Раньше этого не проверялось, и после гибели В СТРОЙКЕ флаг
	# оставался поднятым, новая машина рождалась в движении, а первое нажатие BUILD сторож
	# считал «ничего не изменилось» — гараж не открывался вовсе.
	var switched: bool = v != _mode_was_vehicle
	if switched:
		_mode_was_vehicle = v
		current_vehicle = v          # ссылка была захвачена один раз при старте и после
		#                              возрождения указывала на освобождённый узел
	if building == _mode_was_building and not switched:
		return
	_mode_was_building = building
	if not _controls_hidden:
		_apply_mode_visibility()

# Подпись на кнопке = КУДА она переключит, а не где ты сейчас. С названием текущего режима
# приходилось жать «MOVE», чтобы попасть в стройку, — читается наоборот.
func _set_mode_label(text: String, col: Color) -> void:
	var lbl := get_node_or_null("ModeToggle/Label") as Label
	if lbl == null:
		return
	lbl.text = text
	lbl.add_theme_color_override("font_color", col)

func _on_movement_pressed() -> void:
	$Attack.visible = true
	$Take.visible = false
	$TakeOff.visible = false
	%Joystick_movement.visible=true
	_set_mode_label("BUILD", Color(1.0, 0.7, 0.25))   # едем → кнопка ведёт в стройку

func _on_building_pressed() -> void:
	$Attack.visible =false
	$Take.visible = false               # кнопка Take не нужна: двойной тап по клетке ставит блок,
	$TakeOff.visible = false            # двойной тап по блоку машины/мира берёт его; убрать — панель рук (📦/🗑)
	%Joystick_movement.visible=true    # в стройке джойстик МЕДЛЕННО двигает платформу (репозиция)
	_set_mode_label("MOVE", Color(0.4, 1.0, 0.6))     # строим → кнопка возвращает за руль
	_open_build_tab.call_deferred()    # стройка живёт в гараже: открываем его на своей вкладке

func _on_take_pressed() -> void:
	if current_vehicle.block_map_node.get_block(current_vehicle.BuildingBlock["x"],current_vehicle.BuildingBlock["y"],current_vehicle.BuildingBlock["z"])!=0:
		return #if no empty return
	$Take/Label.text = "Take"
	$TakeOff.visible = false
	if current_vehicle.block_body: #Take blocking
		$Take/Label.text = "Place"

func _on_take_off_pressed() -> void:
	if current_vehicle.block_take:

		$HUD/Build/Label.text = "Take"
		$HUD/TakeOff.visible = false

# ── Музыка: UI переехал в гараж (tech_ui, вкладка МУЗЫКА). В HUD остался только
# тост-атрибуция «сейчас играет» ниже. ─────────────────────────────────────────
var _music_toast: Label = null

# Тост «сейчас играет» внизу экрана при смене трека (атрибуция: название — автор).
func _show_music_toast(title: String, author: String) -> void:
	if _music_toast == null or not is_instance_valid(_music_toast):
		_music_toast = Label.new()
		_music_toast.add_theme_font_size_override("font_size", 14)
		_music_toast.add_theme_color_override("font_color", Color(0.85, 0.95, 1.0))
		_music_toast.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(_music_toast)
	var screen: Vector2 = get_viewport().get_visible_rect().size
	_music_toast.text = "♪ %s — %s" % [title, author]
	_music_toast.reset_size()
	_music_toast.position = Vector2(screen.x * 0.5 - _music_toast.size.x * 0.5, screen.y - 40.0)
	_music_toast.modulate = Color(1, 1, 1, 0.0)
	var tw := create_tween()
	tw.tween_property(_music_toast, "modulate:a", 1.0, 0.4)
	tw.tween_interval(3.0)
	tw.tween_property(_music_toast, "modulate:a", 0.0, 1.0)
