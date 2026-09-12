extends Control
class_name SwipeClose

# ЖЕСТ «СНИЗУ ВВЕРХ» — закрывает большое окно: гараж и журнал заданий.
#
# Зачем. Оба окна занимают весь экран, а закрывались одним крестиком в углу — до него надо
# дотянуться, и на телефоне это самый неудобный угол из четырёх. Жест «протянуть от нижней
# кромки вверх» — то же самое, что «назад» в системе, и рукой он делается не глядя.
#
# ГДЕ ловим. Палец должен начать у САМОЙ НИЖНЕЙ кромки и ПО ЦЕНТРУ: по краям внизу лежат
# джойстик, глобус блоков и кнопки поворота, и жест, начинающийся где угодно, отбирал бы у
# них перетаскивание. Центральная полоса внизу свободна во всех режимах.
#
# ЧТО ловим. Событие берём в _input, а не gui_input: окно сверху — это Control с
# mouse_filter STOP, он съедает ввод раньше, чем тот дойдёт до чего-либо под ним, а _input
# у узлов вызывается ДО разбора GUI. Сработавший жест гасим (set_input_as_handled), иначе
# тот же палец доедет до мира и до камеры.
#
# ПОЛОСКА внизу по центру — подсказка, что жест есть. Без неё он остаётся секретом: игрок
# не пробует того, о чём не знает. Она ничего не ловит (mouse_filter IGNORE) и живёт ровно
# столько, сколько открыто окно.

signal closed()

const BAR_W: float = 132.0
const BAR_H: float = 5.0
const BAR_BOTTOM: float = 9.0            # на сколько поднята над нижней кромкой экрана

## Полоса у нижней кромки, с которой жест начинается, и путь, который надо пройти вверх.
## Обе величины — от РАЗМЕРА ЭКРАНА, с нижней границей в пикселях: на телефоне высота
## экрана в единицах UI меняется с соотношением сторон, а палец у всех один и тот же.
const EDGE_MIN: float = 56.0
const EDGE_FRAC: float = 0.09
const TRAVEL_MIN: float = 90.0
const TRAVEL_FRAC: float = 0.14
## Половина ширины центральной зоны старта — доля ширины экрана.
const CENTER_FRAC: float = 0.25

var _on_close: Callable = Callable()
var _is_open: Callable = Callable()
var _armed: bool = false                 # жест начался в нужном месте и ещё жив
var _from: Vector2 = Vector2.ZERO

## Повесить жест на окно. `is_open` спрашиваем каждый кадр: узел живёт вместе с окном и
## получает ввод даже когда окно спрятано (видимость на _input не влияет), так что без
## этого вопроса жест закрывал бы уже закрытое.
static func attach(host: Node, on_close: Callable, is_open: Callable) -> SwipeClose:
	var s := SwipeClose.new()
	s._on_close = on_close
	s._is_open = is_open
	host.add_child(s)
	return s

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	# Якоря и смещения ЧИСЛАМИ: пресеты считают смещения от текущего прямоугольника, а у
	# только что созданного Control он нулевой — подсказка осталась бы в углу нулевого размера.
	anchor_left = 0.5
	anchor_right = 0.5
	anchor_top = 1.0
	anchor_bottom = 1.0
	offset_left = -BAR_W * 0.5
	offset_right = BAR_W * 0.5
	offset_top = -(BAR_H + BAR_BOTTOM)
	offset_bottom = -BAR_BOTTOM
	z_index = 20                          # окно рисуется поверх — подсказка не должна тонуть под ним
	var bar := Panel.new()
	bar.set_anchors_preset(Control.PRESET_FULL_RECT)
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var st := StyleBoxFlat.new()
	st.bg_color = Color(0.55, 0.86, 0.92, 0.45)
	st.set_corner_radius_all(int(BAR_H * 0.5))
	bar.add_theme_stylebox_override("panel", st)
	add_child(bar)
	visible = false

func _process(_delta: float) -> void:
	var open: bool = _open()
	if visible != open:
		visible = open
	if not open:
		_armed = false

func _open() -> bool:
	# == true, а не bool(): вызов может вернуть что угодно, а bool(null) роняет вызов.
	return _is_open.is_valid() and _is_open.call() == true

func _input(event: InputEvent) -> void:
	if not _open():
		return
	if event is InputEventScreenTouch:
		var t := event as InputEventScreenTouch
		_arm(t.position, t.pressed)
	elif event is InputEventScreenDrag and _armed:
		_advance((event as InputEventScreenDrag).position)
	elif event is InputEventMouseButton \
			and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
		# ПК: тот же жест мышью — прижать у нижней кромки и потянуть вверх.
		var mb := event as InputEventMouseButton
		_arm(mb.position, mb.pressed)
	elif event is InputEventMouseMotion and _armed:
		_advance((event as InputEventMouseMotion).position)

## Начало жеста. Отпускание всегда снимает взвод: жест либо дотянули, либо он не считается —
## докатывать его следующим касанием нельзя, иначе окно закрывалось бы «прошлым» пальцем.
func _arm(pos: Vector2, pressed: bool) -> void:
	if not pressed:
		_armed = false
		return
	var vp: Vector2 = get_viewport_rect().size
	_from = pos
	_armed = pos.y >= vp.y - maxf(EDGE_MIN, vp.y * EDGE_FRAC) \
			and absf(pos.x - vp.x * 0.5) <= vp.x * CENTER_FRAC

func _advance(pos: Vector2) -> void:
	var vp: Vector2 = get_viewport_rect().size
	var d: Vector2 = pos - _from
	if absf(d.x) > absf(d.y):
		_armed = false                    # ушёл вбок — это не наш жест, и второй попытки не даём
		return
	if d.y > -maxf(TRAVEL_MIN, vp.y * TRAVEL_FRAC):
		return                            # ещё не дотянул
	_armed = false
	get_viewport().set_input_as_handled()
	if _on_close.is_valid():
		_on_close.call()
	closed.emit()
