@tool
extends VBoxContainer

# КУБИК В ИНСПЕКТОРЕ. Тот же виджет, что и в игре (port_cube.gd), только настраивает он не
# порты клеток, а МАСКИ ГРАНЕЙ самой сцены блока:
#
#   CONNECT — connect_faces: какими сторонами блок стыкуется с соседями;
#   IN/OUT  — input_faces/output_faces фабричного блока: чем принимает и чем отдаёт.
#
# Почему не порты по клеткам. Порт хранится в осях КАРТЫ и от поворота блока не зависит —
# на машине это правильно (там видно, куда реально идёт лента), а в сцене блока такой
# настройке взяться неоткуда: сцена не знает, каким боком её потом поставят. Маски граней,
# наоборот, живут в СВОИХ осях блока и поворачиваются вместе с ним — им здесь и место.
#
# Зачем вообще. Галочки «Front (−Z) / Back (+Z) / …» требуют помнить, куда у этой конкретной
# модели смотрит нос, и ошибка видна только в игре — блоком, который не стыкуется или не
# принимает ленту. На кубике грань видно.

const MODE_CONNECT := 0
const MODE_IN := 1
const MODE_OUT := 2

const COL_OFF := Color(0.16, 0.20, 0.22, 1.0)
const COL_CONNECT := Color(0.35, 0.85, 0.45, 1.0)
const COL_IN := Color(0.25, 0.72, 0.95, 1.0)
const COL_OUT := Color(1.0, 0.72, 0.25, 1.0)

var _block: VehicleBlock = null
var _ur = null
var _mode: int = MODE_CONNECT
var _cube = null
var _buttons: Array = []

func setup(block: VehicleBlock, undo_redo) -> void:
	_block = block
	_ur = undo_redo

func _ready() -> void:
	add_theme_constant_override("separation", 4)
	var title := Label.new()
	title.text = "BLOCK FACES"
	add_child(title)

	var row := HBoxContainer.new()
	add_child(row)
	_add_mode_button(row, MODE_CONNECT, "CONNECT")
	# Вход и выход есть только у фабричного блока — у обычного эти кнопки нечему было бы менять.
	if _block is FactoryBlock:
		_add_mode_button(row, MODE_IN, "IN")
		_add_mode_button(row, MODE_OUT, "OUT")

	_cube = PortCube.new()
	_cube.cells = [Vector3i.ZERO]          # маска задаётся на грань целиком, клетки тут ни при чём
	_cube.labels = ["—", "ON", "ON"]
	_cube.custom_minimum_size = Vector2(300, 180)
	_cube.state_of = func(_off: Vector3i, di: int) -> int:
		return _bit(di)
	_cube.on_click = func(_off: Vector3i, di: int) -> void:
		_toggle(di)
	add_child(_cube)

	var hint := Label.new()
	hint.text = "Tap a face on the cube. Same values as the checkboxes below."
	hint.add_theme_font_size_override("font_size", 11)
	add_child(hint)
	_sync()

func _add_mode_button(row: HBoxContainer, mode: int, text: String) -> void:
	var b := Button.new()
	b.text = text
	b.toggle_mode = true
	b.pressed.connect(func() -> void:
		_mode = mode
		_sync())
	row.add_child(b)
	_buttons.append({"btn": b, "mode": mode})

## Какое свойство блока сейчас правим. Одно имя на всё: и чтение состояния грани, и запись,
## и подпись — иначе режим и свойство разъезжаются при первой же правке.
func _prop() -> String:
	match _mode:
		MODE_IN: return "input_faces"
		MODE_OUT: return "output_faces"
	return "connect_faces"

func _bit(di: int) -> int:
	if _block == null or not is_instance_valid(_block):
		return 0
	var v = _block.get(_prop())
	if v == null:
		return 0
	return 1 if (int(v) & (1 << di)) != 0 else 0

func _toggle(di: int) -> void:
	if _block == null or not is_instance_valid(_block):
		return
	var prop := _prop()
	var old = _block.get(prop)
	if old == null:
		return
	var nv: int = int(old) ^ (1 << di)
	# Через стек редактора, а не прямым присваиванием: правка должна попадать в Ctrl+Z и
	# помечать сцену изменённой, иначе она молча теряется при закрытии вкладки.
	if _ur != null:
		_ur.create_action("Block faces: %s" % prop)
		_ur.add_do_property(_block, prop, nv)
		_ur.add_undo_property(_block, prop, int(old))
		_ur.commit_action()
	else:
		_block.set(prop, nv)
	_sync()

## Цвет «включённой» грани у каждого режима свой: перепутать, что именно ты сейчас
# красишь — стыковку или вход, — иначе слишком легко.
func _sync() -> void:
	for e in _buttons:
		(e["btn"] as Button).button_pressed = int(e["mode"]) == _mode
	if _cube != null:
		var on: Color = COL_CONNECT
		if _mode == MODE_IN:
			on = COL_IN
		elif _mode == MODE_OUT:
			on = COL_OUT
		_cube.colors = [COL_OFF, on, on]
		_cube.queue_redraw()
