extends Node
class_name DragWindow

# ПЛАВАЮЩАЯ ПАНЕЛЬ HUD: таскается пальцем, помнит своё место, не уезжает за экран.
#
# Одна реализация на всех. Такие панели уже две — трекер заданий и его журнал, — а с полигоном
# стало три, и переписывать сорок строк разбора ввода в каждую значило бы ровно то, что в этом
# проекте уже случалось: одна копия однажды научится чему-то, чего не знают остальные.
#
# Вешается так же, как SwipeClose: `DragWindow.attach(окно, ручка, "имя")`. Ручка — тот узел, за
# который тащат: у трекера это он сам, у журнала — только шапка (внутри список, и ловля
# перетаскивания всей панелью отняла бы у него прокрутку пальцем).
#
# ТАП И ПЕРЕТАСКИВАНИЕ РАЗЛИЧАЮТСЯ ПО ПРОЙДЕННОМУ ПУТИ, а не по времени: палец на тапе всегда
# чуть дрожит, а «подержал» — это уже другой жест, и он занят. Уехавший тап не должен считаться
# нажатием, поэтому ручка-кнопка спрашивает `dragged()` и гасит своё срабатывание.

const DRAG_SLOP: float = 8.0          # дальше этого палец уже тащит, а не нажимает
const SCREEN_PAD: float = 8.0         # окно не заходит за край экрана дальше отступа

var _win: Control = null
var _id: String = ""
var _from: Vector2 = Vector2.ZERO     # позиция окна в момент захвата
var _ptr: Vector2 = Vector2.ZERO      # где был палец в момент захвата
var _holding: bool = false
var _dragged: bool = false
var _moved: bool = false              # игрок сам выбрал место — держим его при смене экрана

## Привязать. Позиция из настроек восстанавливается ОТЛОЖЕННО: сохранённое место прижимают к
## экрану по размеру окна, а контейнеры досчитывают его только после первой раскладки.
static func attach(win: Control, handle: Control, id: String) -> DragWindow:
	var d := DragWindow.new()
	d.name = "DragWindow"
	d._win = win
	d._id = id
	handle.add_child(d)
	handle.gui_input.connect(d._on_input)
	d._restore.call_deferred()
	return d

func _ready() -> void:
	get_viewport().size_changed.connect(_keep_on_screen)

## Уехал ли последний тап в перетаскивание. Спрашивает ручка-кнопка, чтобы не сработать; ответ
## СНИМАЕТСЯ вопросом — иначе один раз уехавший тап глушил бы все следующие нажатия.
func dragged() -> bool:
	var was: bool = _dragged
	_dragged = false
	return was

## Трогал ли ОКНО игрок. Спрашивают те, кто двигает панель сам (радар уводит трекер из-под
## себя): выбранное игроком место важнее любой автоматической раскладки.
func moved() -> bool:
	return _moved

func _on_input(ev: InputEvent) -> void:
	if _win == null or not is_instance_valid(_win):
		return
	if ev is InputEventMouseButton and (ev as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
		if (ev as InputEventMouseButton).pressed:
			_holding = true
			_dragged = false
			_from = _win.position
			_ptr = _win.get_global_mouse_position()
		elif _holding:
			_holding = false
			if _dragged:
				G.set_window_pos(_id, _win.position)   # в конфиг на отпускании, не на каждый кадр
	elif ev is InputEventMouseMotion and _holding:
		var moved: Vector2 = _win.get_global_mouse_position() - _ptr
		if not _dragged and moved.length_squared() < DRAG_SLOP * DRAG_SLOP:
			return                    # дрожание пальца на тапе — это ещё не перетаскивание
		_dragged = true
		_moved = true
		_win.position = clamp_on_screen(_win, _from + moved)

## Прижать окно к экрану. Публично: панель зовёт это сама, когда изменила свой размер (свернулась
## или развернулась) и могла вылезти за нижнюю кромку.
func clamp_on_screen(win: Control, pos: Vector2) -> Vector2:
	var vp: Vector2 = get_viewport().get_visible_rect().size
	# Окно шире экрана прижимаем к левому/верхнему краю, иначе clampf получил бы min > max.
	return Vector2(
		clampf(pos.x, SCREEN_PAD, maxf(SCREEN_PAD, vp.x - win.size.x - SCREEN_PAD)),
		clampf(pos.y, SCREEN_PAD, maxf(SCREEN_PAD, vp.y - win.size.y - SCREEN_PAD)))

func keep_on_screen() -> void:
	_keep_on_screen()

func _restore() -> void:
	if _win == null or not is_instance_valid(_win):
		return
	var p: Variant = G.window_pos(_id)
	if p == null:
		return
	_moved = true
	_win.position = clamp_on_screen(_win, p)

# Поворот экрана или смена разрешения: то, что игрок оставил у правого края, иначе оказалось бы
# за его пределами, и вернуть окно было бы нечем.
func _keep_on_screen() -> void:
	if _moved and _win != null and is_instance_valid(_win):
		_win.position = clamp_on_screen(_win, _win.position)
