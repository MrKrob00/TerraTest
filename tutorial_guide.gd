class_name TutorialGuide
extends CanvasLayer

# Обучающая «рука с пальцем»: показывает, КУДА нажать, и не даёт нажать никуда больше.
#
# Слой 20 — выше HUD (1), квестов (5) и гаража (он ребёнок HUD), чтобы палец был виден
# поверх любого экрана, на который он показывает.
#
# ── Как устроена блокировка ──────────────────────────────────────────────────
# Ввод в Godot идёт в три очереди: сначала _input (там сидят TouchScreenButton —
# джойстики и кнопка режима), потом GUI (обычные Control-кнопки: меню, гараж, трекер
# квестов), и только потом _unhandled_input (тапы по миру — наведение/взятие блока).
# Поэтому одной заглушки мало, их две:
#
#   • Blocker — полноэкранный Control поверх всего. Он «съедает» GUI-событие, а заодно
#     и _unhandled_input, потому что помеченное как handled дальше не идёт. Дырку в нём
#     делает _has_point: внутри разрешённого прямоугольника контрол считается непопадаемым,
#     и событие спокойно уходит вниз — к нужной кнопке или к миру.
#   • TouchScreenButton эту очередь опережает, дыркой их не остановить. Им выставляем
#     process_mode = DISABLED (нода выпадает из группы ввода) и гасим прозрачностью.
#     Видимость НЕ трогаем: ей рулит логика режимов в HUD, и подмена бы с ней подралась.

const LAYER: int = 20

# Куда показываем и что при этом разрешено нажимать.
enum Aim {
	NONE,        # подсказки нет
	NODE,        # цель — узел UI (кнопка); дырка = его прямоугольник
	WORLD,       # цель — точка мира (блок, машина); дырка = круг вокруг её проекции
}

const WORLD_HOLE_R: float = 130.0     # радиус разрешённой зоны вокруг цели в мире
const HOLE_PAD: float = 8.0           # запас вокруг кнопки, чтобы палец не промахивался

# Насколько глухо блокируем ввод на время шага.
enum Gate {
	TARGET,   # нажать можно ТОЛЬКО цель: заглушка с дыркой + тач-кнопки выключены
	WORLD,    # мир открыт (шаг «собери всё»), тач-кнопки выключены; UI гасит наставник
	OFF,      # ничего не блокируем
}

var _aim: int = Aim.NONE
var _target_node: CanvasItem = null
var _world_pos: Callable = Callable()  # () -> Vector3 (пересчитываем каждый кадр: цель движется)
var _double_tap: bool = false          # рисовать двойное касание (два кольца)
var _text: String = ""

## Игрок нажал SKIP — обучение надо закрыть целиком (подписывается наставник).
signal skip_pressed

var _blocker: Blocker = null
var _hand: Hand = null
var _bubble: PanelContainer = null
var _bubble_label: Label = null
var _skip_btn: Button = null
var _gated: Array[Node] = []           # TouchScreenButton'ы, которым выключили ввод
# Где искать тач-кнопки: палец живёт под наставником, а кнопки — у HUD, ссылку дают снаружи.
var _hud: Node = null

# ── Полноэкранная заглушка с дыркой ──────────────────────────────────────────
class Blocker extends Control:
	var hole: Rect2 = Rect2()          # пусто = не пропускаем ничего
	var round_hole: bool = false       # для целей в мире дырка круглая

	# Ключ ко всей блокировке: точка ВНУТРИ дырки считается «не нашей», и движок
	# отдаёт событие тому, кто ниже. Снаружи — контрол попадаем и глотает тап.
	func _has_point(point: Vector2) -> bool:
		if hole.size == Vector2.ZERO:
			return true
		if round_hole:
			return point.distance_to(hole.position + hole.size * 0.5) > hole.size.x * 0.5
		return not hole.has_point(point)

	func _draw() -> void:
		# Затемняем всё, кроме дырки: четырьмя прямоугольниками вокруг неё, чтобы не
		# заводить ни маску, ни шейдер ради одной подсветки.
		var dim := Color(0.0, 0.0, 0.0, 0.45)
		if hole.size == Vector2.ZERO:
			draw_rect(Rect2(Vector2.ZERO, size), dim)
			return
		var h := hole
		draw_rect(Rect2(0, 0, size.x, h.position.y), dim)
		draw_rect(Rect2(0, h.end.y, size.x, size.y - h.end.y), dim)
		draw_rect(Rect2(0, h.position.y, h.position.x, h.size.y), dim)
		draw_rect(Rect2(h.end.x, h.position.y, size.x - h.end.x, h.size.y), dim)
		# Обводка цели — чтобы взгляд шёл к ней, а не к пальцу.
		var accent := Color(1.0, 0.72, 0.25, 0.9)
		if round_hole:
			draw_arc(h.position + h.size * 0.5, h.size.x * 0.5, 0.0, TAU, 48, accent, 2.5)
		else:
			draw_rect(h, accent, false, 2.5)

# ── Рука с указательным пальцем ──────────────────────────────────────────────
# Рисуется нодой: одна картинка на всю игру не стоит атласа, зато так она любого размера
# и сама поворачивается по направлению на цель.
class Hand extends Control:
	var t: float = 0.0
	var double_tap: bool = false

	func _draw() -> void:
		# Канон: кончик пальца в (0,0), рука уходит ВНИЗ. Поворот и сдвиг делает родитель.
		var skin := Color(0.96, 0.86, 0.72)
		var edge := Color(0.12, 0.09, 0.07, 0.9)
		# Покачивание вдоль пальца: касание — рука подходит к цели и отходит.
		var press: float = _press_phase()
		var off := Vector2(0.0, 20.0 + press * 14.0)

		# Кольца касания у кончика пальца (при двойном тапе — два, со сдвигом фазы).
		_draw_ripple(fmod(t, 1.4) / 1.4)
		if double_tap:
			_draw_ripple(fmod(t + 0.28, 1.4) / 1.4)

		# Капсулы рисуем дважды: тёмная потолще (контур) и светлая — так рука читается
		# и на светлом песке, и на тёмной панели гаража.
		var parts: Array = [
			[Vector2(0, 8), Vector2(0, 40), 13.0],      # указательный палец
			[Vector2(-14, 52), Vector2(-20, 64), 11.0], # большой
			[Vector2(10, 50), Vector2(14, 60), 11.0],   # сложенные пальцы
			[Vector2(3, 50), Vector2(5, 62), 11.0],
		]
		for pass_i in 2:
			var col: Color = edge if pass_i == 0 else skin
			var grow: float = 4.0 if pass_i == 0 else 0.0
			# Кулак
			_capsule(Vector2(-2, 46) + off, Vector2(4, 62) + off, 34.0 + grow, col)
			for p in parts:
				_capsule((p[0] as Vector2) + off, (p[1] as Vector2) + off, float(p[2]) + grow, col)

	# Фаза «нажатия» 0..1 — рука дважды подаётся вперёд за цикл при двойном тапе.
	func _press_phase() -> float:
		var period: float = 0.7 if double_tap else 1.4
		var k: float = fmod(t, period) / period
		return sin(k * PI)

	func _draw_ripple(k: float) -> void:
		if k <= 0.0:
			return
		var r: float = 6.0 + k * 26.0
		draw_arc(Vector2.ZERO, r, 0.0, TAU, 32, Color(1.0, 0.72, 0.25, (1.0 - k) * 0.9), 2.5)

	func _capsule(a: Vector2, b: Vector2, w: float, col: Color) -> void:
		draw_line(a, b, col, w)
		draw_circle(a, w * 0.5, col)
		draw_circle(b, w * 0.5, col)

# ── Сборка ───────────────────────────────────────────────────────────────────
func _ready() -> void:
	layer = LAYER
	add_to_group("tutorial_guide")
	_blocker = Blocker.new()
	_blocker.mouse_filter = Control.MOUSE_FILTER_STOP
	_blocker.set_anchors_preset(Control.PRESET_FULL_RECT)
	_blocker.visible = false
	add_child(_blocker)

	_hand = Hand.new()
	_hand.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hand.size = Vector2(120, 120)
	_hand.visible = false
	add_child(_hand)

	_bubble = PanelContainer.new()
	_bubble.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_bubble.add_theme_stylebox_override("panel", _bubble_style())
	_bubble.visible = false
	_bubble_label = Label.new()
	_bubble_label.add_theme_font_size_override("font_size", 17)
	_bubble_label.add_theme_color_override("font_color", Color(0.94, 0.97, 0.99))
	_bubble_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_bubble_label.custom_minimum_size = Vector2(320, 0)
	_bubble.add_child(_bubble_label)
	add_child(_bubble)

	# SKIP — ПОСЛЕДНИМ ребёнком, то есть поверх заглушки: она полноэкранная и иначе съедала
	# бы тап. Нужна не только нетерпеливым: если шаг стал непроходимым (скажем, сейв старый
	# и стартовые блоки в мир уже не выдадутся), это единственный выход.
	_skip_btn = Button.new()
	_skip_btn.text = "SKIP TUTORIAL"
	_skip_btn.add_theme_font_size_override("font_size", 15)
	_skip_btn.add_theme_color_override("font_color", Color(0.85, 0.9, 0.92))
	_skip_btn.add_theme_stylebox_override("normal", _skip_style(false))
	_skip_btn.add_theme_stylebox_override("hover", _skip_style(false))
	_skip_btn.add_theme_stylebox_override("pressed", _skip_style(true))
	_skip_btn.visible = false
	_skip_btn.pressed.connect(func() -> void: skip_pressed.emit())
	add_child(_skip_btn)

	set_process(false)

func _skip_style(pressed: bool) -> StyleBoxFlat:
	var st := StyleBoxFlat.new()
	st.bg_color = Color(0.2, 0.22, 0.24, 0.9) if pressed else Color(0.08, 0.1, 0.12, 0.8)
	st.border_color = Color(0.6, 0.65, 0.68, 0.5)
	st.set_border_width_all(1)
	st.set_corner_radius_all(8)
	st.content_margin_left = 16
	st.content_margin_right = 16
	st.content_margin_top = 9
	st.content_margin_bottom = 9
	return st

# Правый нижний угол. Пересчитываем каждый кадр — экран может повернуться.
func _place_skip() -> void:
	if _skip_btn == null or not _skip_btn.visible:
		return
	_skip_btn.reset_size()
	var screen: Vector2 = get_viewport().get_visible_rect().size
	_skip_btn.position = Vector2(screen.x - _skip_btn.size.x - 16.0,
			screen.y - _skip_btn.size.y - 16.0)

func _bubble_style() -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = Color(0.043, 0.122, 0.149, 0.96)
	s.border_color = Color(1.0, 0.72, 0.25, 0.75)
	s.set_border_width_all(2)
	s.set_corner_radius_all(12)
	s.content_margin_left = 14
	s.content_margin_right = 14
	s.content_margin_top = 10
	s.content_margin_bottom = 10
	return s

# ── Публичный интерфейс ──────────────────────────────────────────────────────
## Показать палец на узел UI. gate — насколько глухо блокируем остальное (см. Gate).
func point_at_node(node: CanvasItem, text: String, double_tap: bool = false, gate: int = Gate.TARGET) -> void:
	_aim = Aim.NODE
	_target_node = node
	_world_pos = Callable()
	_text = text
	_double_tap = double_tap
	_start(gate)

## Показать палец на точку мира. getter возвращает Vector3 (цель может двигаться).
func point_at_world(getter: Callable, text: String, double_tap: bool = true, gate: int = Gate.TARGET) -> void:
	_aim = Aim.WORLD
	_target_node = null
	_world_pos = getter
	_text = text
	_double_tap = double_tap
	_start(gate)

## Убрать подсказку и вернуть управление.
func clear() -> void:
	_aim = Aim.NONE
	_target_node = null
	_world_pos = Callable()
	set_process(false)
	_blocker.visible = false
	_hand.visible = false
	_bubble.visible = false
	_skip_btn.visible = false
	_ungate_touch_buttons()

## Наставник отдаёт HUD, у которого лежат тач-кнопки (сам палец висит на слое поверх всего).
func bind_hud(h: Node) -> void:
	_hud = h

func is_active() -> bool:
	return _aim != Aim.NONE

func _start(gate: int) -> void:
	_skip_btn.visible = true
	_hand.double_tap = _double_tap
	_hand.visible = true
	_bubble_label.text = _text
	_bubble.visible = _text != ""
	_bubble.reset_size()          # размер нужен уже сейчас: по нему считаем, где встать
	var block_ui: bool = gate == Gate.TARGET
	_blocker.visible = block_ui
	_blocker.mouse_filter = Control.MOUSE_FILTER_STOP if block_ui else Control.MOUSE_FILTER_IGNORE
	if gate == Gate.OFF:
		_ungate_touch_buttons()
	else:
		_gate_touch_buttons()
	set_process(true)
	_tick()

# ── Кадр ─────────────────────────────────────────────────────────────────────
func _process(delta: float) -> void:
	_hand.t += delta
	_hand.queue_redraw()
	_tick()

func _tick() -> void:
	# Кнопку двигаем ПЕРВОЙ: ниже есть ранние выходы (цель ещё не появилась, точка мира за
	# спиной), а именно в таком застревании SKIP и нужен — не в углу (0,0).
	_place_skip()
	var hole := Rect2()
	var tip := Vector2.ZERO
	var round_hole := false
	match _aim:
		Aim.NODE:
			if not is_instance_valid(_target_node):
				clear()
				return
			var r := _node_rect(_target_node)
			if r.size == Vector2.ZERO:
				return
			hole = r.grow(HOLE_PAD)
			tip = r.position + r.size * 0.5
		Aim.WORLD:
			var p = _project_world()
			if p == null:
				# Цель исчезла (блок подобран/уничтожен) — подсказку снимает тот, кто её ставил.
				return
			tip = p
			hole = Rect2(tip - Vector2(WORLD_HOLE_R, WORLD_HOLE_R),
					Vector2(WORLD_HOLE_R * 2.0, WORLD_HOLE_R * 2.0))
			round_hole = true
		_:
			return
	_blocker.hole = hole
	_blocker.round_hole = round_hole
	_blocker.queue_redraw()
	_place_hand(tip, hole)

# Рука и пузырь встают ВОКРУГ цели, никогда на неё. Считаем от прямоугольника цели, а не
# от одной точки: у кнопки под верхней кромкой экрана «выше» не влезало, и прежний клампинг
# клал пузырь ровно на ту кнопку, которую он объясняет.
const BUBBLE_GAP: float = 22.0     # зазор от цели
const HAND_SPAN: float = 130.0     # сколько места занимает рука со своей стороны

func _place_hand(tip: Vector2, target: Rect2) -> void:
	var screen: Vector2 = get_viewport().get_visible_rect().size
	var bw: float = _bubble.size.x
	var bh: float = _bubble.size.y

	# По умолчанию рука СНИЗУ и показывает вверх; сверху заходит, только если снизу места
	# нет, а сверху есть — иначе у цели под верхней кромкой она ушла бы за экран.
	var hand_below: bool = (screen.y - target.end.y) >= HAND_SPAN or target.position.y < HAND_SPAN
	_hand.rotation = 0.0 if hand_below else PI
	_hand.position = tip + (Vector2(14.0, 26.0) if hand_below else Vector2(-14.0, -26.0))

	# Пузырь — с противоположной стороны от руки. Не влезает — уводим на сторону руки, но ЗА
	# неё. Не выходит и так — вбок.
	var bx: float = clampf(tip.x - bw * 0.5, 12.0, maxf(12.0, screen.x - bw - 12.0))
	var opposite: float = (target.position.y - bh - BUBBLE_GAP) if hand_below \
			else (target.end.y + BUBBLE_GAP)
	var behind_hand: float = (target.end.y + HAND_SPAN + BUBBLE_GAP) if hand_below \
			else (target.position.y - HAND_SPAN - bh - BUBBLE_GAP)
	var by: float = INF
	if opposite >= 12.0 and opposite + bh <= screen.y - 12.0:
		by = opposite
	elif behind_hand >= 12.0 and behind_hand + bh <= screen.y - 12.0:
		by = behind_hand
	if by == INF:
		by = clampf(tip.y - bh * 0.5, 12.0, maxf(12.0, screen.y - bh - 12.0))
		bx = target.end.x + BUBBLE_GAP
		if bx + bw > screen.x - 12.0:
			bx = target.position.x - bw - BUBBLE_GAP
		bx = clampf(bx, 12.0, maxf(12.0, screen.x - bw - 12.0))
	_bubble.position = Vector2(bx, by)

# Прямоугольник узла на экране. Control знает свой rect; TouchScreenButton — нет, у него
# считаем по текстуре (её левый верх = позиция ноды), как это делает сам движок.
func _node_rect(n: CanvasItem) -> Rect2:
	if n is Control:
		var c := n as Control
		return Rect2(c.global_position, c.size)
	if n is TouchScreenButton:
		var b := n as TouchScreenButton
		var sz := b.texture_normal.get_size() if b.texture_normal != null else Vector2(64, 64)
		return Rect2(b.global_position, sz)
	if n is Node2D:
		return Rect2((n as Node2D).global_position - Vector2(32, 32), Vector2(64, 64))
	return Rect2()

# Проекция цели мира на экран: Vector2 либо null (камеры нет, цель за спиной или её больше
# не существует). Тип возврата объявлен явно — иначе на стороне вызова `:=` не выводится.
func _project_world() -> Variant:
	if not _world_pos.is_valid():
		return null
	var wp = _world_pos.call()
	if not (wp is Vector3):
		return null
	var cam := get_viewport().get_camera_3d()
	if cam == null or cam.is_position_behind(wp):
		return null
	return cam.unproject_position(wp)

# ── Гашение тач-кнопок (они опережают GUI, дыркой их не остановить) ───────────
func _gate_touch_buttons() -> void:
	_ungate_touch_buttons()
	if _hud != null:
		_gate_subtree(_hud)

# Рекурсивно: часть тач-кнопок вложена в Control-обёртки (Attack/Take/TakeOff — это
# TextureButton с TouchScreenButton внутри), и обход только прямых детей их пропускал.
func _gate_subtree(n: Node) -> void:
	for c in n.get_children():
		if c is TouchScreenButton and c != _target_node:
			c.process_mode = Node.PROCESS_MODE_DISABLED
			(c as CanvasItem).modulate.a = 0.35
			_gated.append(c)
			continue
		_gate_subtree(c)

func _ungate_touch_buttons() -> void:
	for c in _gated:
		if is_instance_valid(c):
			c.process_mode = Node.PROCESS_MODE_INHERIT
			(c as CanvasItem).modulate.a = 1.0
	_gated.clear()
