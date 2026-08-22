@tool
extends VBoxContainer

# КУБИК В ИНСПЕКТОРЕ. Тот же виджет, что и в игре (port_cube.gd), только настраивает он не
# порты конкретной машины, а САМУ СЦЕНУ блока.
#
# Кубик СМОТРИТ НА РАЗМЕР блока и делится на столько клеток, сколько их у блока на самом деле:
# у обычного 1³ это шесть граней, у процессора 2³ — шесть сторон по четыре клетки, то есть
# двадцать четыре кнопки. Иначе настройка «вход слева» у большого блока означала бы «вход во
# все четыре левые клетки сразу», а именно ради разных клеток одной стороны всё и затевалось.
#
# Размер берём из КОЛЛИЗИИ блока, а не из таблицы в коде: коллизия и есть то, чем блок занимает
# место в мире, и держать рядом второй список размеров — способ их рассинхронить.
#
# ЧТО ИМЕННО НАСТРАИВАЕТСЯ, зависит от режима и от размера:
#
#   CONNECT — стороны СТЫКОВКИ (connect_faces). Это маска ГРАНИ целиком и по клеткам не
#             делится: связность машины считается по граням, а не по клеткам.
#   IN/OUT  — у односкеточного блока это тоже маски (input_faces / output_faces).
#   PORTS   — у блока крупнее: поклеточные умолчания (port_defaults), где у каждой клетки
#             своя сторона. Маски при этом остаются базой — клетка без своей настройки
#             ведёт себя по маске, как и раньше.
#
# Почему поклеточное — это УМОЛЧАНИЕ, а не «порт». Порт игрока (FactoryBlock.ports) живёт в
# осях КАРТЫ и принадлежит конкретной машине; сцена же не знает, каким боком её поставят,
# поэтому здесь всё в СВОИХ осях блока, а поворот учитывается при чтении.

const MODE_CONNECT := 0
const MODE_IN := 1
const MODE_OUT := 2
const MODE_PORTS := 3

const COL_OFF := Color(0.16, 0.20, 0.22, 1.0)
const COL_CONNECT := Color(0.35, 0.85, 0.45, 1.0)
const COL_IN := Color(0.25, 0.72, 0.95, 1.0)
const COL_OUT := Color(1.0, 0.72, 0.25, 1.0)

var _block: VehicleBlock = null
var _ur = null
var _mode: int = MODE_CONNECT
var _cube = null
var _buttons: Array = []
var _cells: Array = [Vector3i.ZERO]
var _size_label: Label = null

func setup(block: VehicleBlock, undo_redo) -> void:
	_block = block
	_ur = undo_redo

func _ready() -> void:
	add_theme_constant_override("separation", 4)
	_cells = _footprint()
	var title := Label.new()
	title.text = "BLOCK FACES"
	add_child(title)

	var row := HBoxContainer.new()
	add_child(row)
	_add_mode_button(row, MODE_CONNECT, "CONNECT")
	# Вход и выход есть только у фабричного блока — у обычного эти кнопки нечему было бы менять.
	if _block is FactoryBlock:
		if _cells.size() > 1:
			_add_mode_button(row, MODE_PORTS, "PORTS")     # поклеточно: off → in → out
		else:
			_add_mode_button(row, MODE_IN, "IN")
			_add_mode_button(row, MODE_OUT, "OUT")

	_cube = PortCube.new()
	_cube.cells = _cells
	_cube.custom_minimum_size = Vector2(300, 190)
	_cube.state_of = func(off: Vector3i, di: int) -> int:
		return _state(off, di)
	_cube.on_click = func(off: Vector3i, di: int) -> void:
		_toggle(off, di)
	add_child(_cube)

	_size_label = Label.new()
	_size_label.add_theme_font_size_override("font_size", 11)
	_size_label.text = "%d cell(s): %s" % [_cells.size(), _mode_hint()]
	add_child(_size_label)
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

# ── Размер блока ─────────────────────────────────────────────────────────────
## Клетки блока в тех же осях и с тем же началом отсчёта, что и в игре
## (`blocks._block_footprint`): по X и Z футпринт растёт ОТ ЯКОРЯ В МИНУС, по Y — В ПЛЮС.
## Отсюда и формулы: у ширины n клетки идут от −(n/2) до n−n/2, а по высоте просто 0..n−1.
## Разъедется с игрой — поклеточная настройка будет попадать не в те клетки.
func _footprint() -> Array:
	var sz: Vector3 = _collision_size()
	var nx: int = maxi(int(round(sz.x)), 1)
	var ny: int = maxi(int(round(sz.y)), 1)
	var nz: int = maxi(int(round(sz.z)), 1)
	var out: Array = []
	for dx in range(-(nx / 2), nx - nx / 2):
		for dy in range(0, ny):
			for dz in range(-(nz / 2), nz - nz / 2):
				out.append(Vector3i(dx, dy, dz))
	return out

## Размер коллизии блока в клетках. Берём первый BoxShape3D: у всех блоков коллизия — коробка,
## и её размер и есть занимаемое место (1³ у обычного, 2³ у процессора, 2×1×1 у длинного).
func _collision_size() -> Vector3:
	if _block == null or not is_instance_valid(_block):
		return Vector3.ONE
	for c in _block.get_children():
		var cs := c as CollisionShape3D
		if cs == null or cs.shape == null:
			continue
		var box := cs.shape as BoxShape3D
		if box != null:
			return box.size
	return Vector3.ONE

## Центр футпринта в смещениях — его же кладём блоку (cells_center), чтобы поклеточные
## умолчания поворачивались вместе с блоком.
func _footprint_center() -> Vector3:
	var lo := Vector3(INF, INF, INF)
	var hi := Vector3(-INF, -INF, -INF)
	for c in _cells:
		var v := Vector3((c as Vector3i).x, (c as Vector3i).y, (c as Vector3i).z)
		lo = Vector3(minf(lo.x, v.x), minf(lo.y, v.y), minf(lo.z, v.z))
		hi = Vector3(maxf(hi.x, v.x), maxf(hi.y, v.y), maxf(hi.z, v.z))
	return (lo + hi) * 0.5

# ── Состояние клетки ─────────────────────────────────────────────────────────
## Что показывать на грани клетки: в режиме масок — бит грани (0/1), в поклеточном —
## состояние порта (нет / вход / выход), с откатом на маску, как и в игре.
func _state(off: Vector3i, di: int) -> int:
	if _block == null or not is_instance_valid(_block):
		return 0
	if _mode == MODE_PORTS:
		var key := _port_key(off, di)
		var d: Dictionary = _block.get("port_defaults")
		if d != null and d.has(key):
			return int(d[key])
		# Не задано — работает маска, как и в рантайме (FactoryBlock.port_state).
		if _bit("output_faces", di) == 1:
			return 2
		if _bit("input_faces", di) == 1:
			return 1
		return 0
	return _bit(_prop(), di)

func _bit(prop: String, di: int) -> int:
	var v = _block.get(prop)
	if v == null:
		return 0
	return 1 if (int(v) & (1 << di)) != 0 else 0

func _port_key(off: Vector3i, di: int) -> String:
	return "%d,%d,%d|%d" % [off.x, off.y, off.z, di]

## Какое свойство правим в режимах масок.
func _prop() -> String:
	match _mode:
		MODE_IN: return "input_faces"
		MODE_OUT: return "output_faces"
	return "connect_faces"

# ── Правка ───────────────────────────────────────────────────────────────────
func _toggle(off: Vector3i, di: int) -> void:
	if _block == null or not is_instance_valid(_block):
		return
	if _mode == MODE_PORTS:
		_toggle_port(off, di)
	else:
		_toggle_mask(di)
	_sync()

## Маска грани: клетка тут ни при чём, грань включается целиком.
func _toggle_mask(di: int) -> void:
	var prop := _prop()
	var old = _block.get(prop)
	if old == null:
		return
	_commit(prop, int(old) ^ (1 << di), "Block faces: %s" % prop)

## Поклеточное умолчание: по кругу НЕТ → ВХОД → ВЫХОД. Пишем СЛОВАРЁМ целиком — редактор
## сохраняет свойство, а не его отдельный ключ.
func _toggle_port(off: Vector3i, di: int) -> void:
	var d: Dictionary = (_block.get("port_defaults") as Dictionary).duplicate()
	var key := _port_key(off, di)
	d[key] = (_state(off, di) + 1) % 3
	# Центр футпринта кладём заодно: без него поворот блока увёл бы клетки за его пределы,
	# а вручную это число никто не впишет.
	_commit("cells_center", _footprint_center(), "Block ports: cells_center")
	_commit("port_defaults", d, "Block ports")

## Через стек редактора, а не прямым присваиванием: правка должна попадать в Ctrl+Z и
## помечать сцену изменённой, иначе она молча теряется при закрытии вкладки.
func _commit(prop: String, value, action: String) -> void:
	var old = _block.get(prop)
	if _ur != null:
		_ur.create_action(action)
		_ur.add_do_property(_block, prop, value)
		_ur.add_undo_property(_block, prop, old)
		_ur.commit_action()
	else:
		_block.set(prop, value)

## Цвет «включённой» грани у каждого режима свой: перепутать, что именно ты сейчас
## красишь — стыковку или вход, — иначе слишком легко.
func _sync() -> void:
	for e in _buttons:
		(e["btn"] as Button).button_pressed = int(e["mode"]) == _mode
	if _size_label != null:
		_size_label.text = "%d cell(s): %s" % [_cells.size(), _mode_hint()]
	if _cube == null:
		return
	match _mode:
		MODE_PORTS:
			_cube.labels = ["—", "IN", "OUT"]
			_cube.colors = [COL_OFF, COL_IN, COL_OUT]
		MODE_IN:
			_cube.labels = ["—", "ON", "ON"]
			_cube.colors = [COL_OFF, COL_IN, COL_IN]
		MODE_OUT:
			_cube.labels = ["—", "ON", "ON"]
			_cube.colors = [COL_OFF, COL_OUT, COL_OUT]
		_:
			_cube.labels = ["—", "ON", "ON"]
			_cube.colors = [COL_OFF, COL_CONNECT, COL_CONNECT]
	_cube.queue_redraw()

func _mode_hint() -> String:
	match _mode:
		MODE_PORTS: return "tap a cell: off -> in -> out (per-cell defaults)"
		MODE_IN:    return "tap a face: input side"
		MODE_OUT:   return "tap a face: output side"
	return "tap a face: attaches to neighbours"
