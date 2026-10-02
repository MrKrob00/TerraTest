# processor.gd
extends FactoryBlock

# A PROCESSOR IS A THREE-CELL INTERNAL BELT, not one slot with a timer.
#
# Every tick (a tick is one belt move, belt.belt_speed) the contents shift one cell forward: ore
# entering the first cell leaves the last three ticks later, as an ingot. Three fit inside, three in
# a row go in and three in a row come out.
#
# NO AWAITS ANYWHERE. The state is an array of cells and movement is a tick; the tween only carries
# the PICTURE to the next cell. A chain of awaits driven by that tween used to be the whole
# implementation, and when it broke (machine rebuilt, block rotated, tween cut short) _try_push was
# never called, _push_pending never set, and the cargo stayed inside for good with a green lamp.
#
# OBLIGATION TO THE BELT: emit slot_freed the moment the INPUT cell empties. A belt that was refused
# sets waiting_for_next and subscribes to it - without the signal it waits forever and makes no
# retries of its own (FactoryBlock.push_retry_tick).
const CELLS := 3
## Длительность тика. Один тик = одно движение ленты, поэтому число то же, что belt_speed в
## belt.tscn: процессор, который тикает вдвое реже линии, копит перед собой пробку, а вдвое
## чаще — просто ждёт с пустыми клетками.
@export var tick_time: float = 1.0

## Индекс стороны +X в FACE_VECS (см. VehicleBlock): «правый борт» процессора.
const FACE_RIGHT_IDX := 3

## THE ORE GOES ROUND, CLOCKWISE SEEN FROM ABOVE, AND INTO A CLOSED FURNACE
## (art/emitter_models.py build_processor): cell 0 is the intake on the right at the back; the move
## into cell 1 lifts the back hatch and carries the ore LEFT through the mouth, shrinking it to fit,
## and there it is gone - the furnace shows the melt instead, a GAUGE of molten metal filling over
## the tick; the move into cell 2 lifts the front hatch, and out of it comes the product under a hot
## glitch, sliding RIGHT to the exit and growing back while the gauge drains. upgrade() is still
## called by the tick, so the product never depends on a tween finishing - only the picture does.
const IN_FURNACE := 0.85         # the item's scale in the mouth: the item models are ~0.45 m, the mouth 0.42 high
const LEG := 0.3                 # seconds per leg of the path
const HATCH_LIFT := 0.42         # the mouth's height: a lifted hatch clears it
const HATCH_TIME := 0.12
const GAUGE_MIN := 0.02          # never 0: a zero scale is a degenerate basis in the batch
const MELT_FX_TIME := 0.5
const MELT_A := Color(1.0, 0.55, 0.15)
const MELT_B := Color(1.0, 0.85, 0.40)
var _hatch_in: Node3D = null
var _hatch_out: Node3D = null
var _gauge: Node3D = null

var _cells: Array = []          # предметы по клеткам: 0 — вход, CELLS-1 — выход
var _slots: Array = []          # маркеры, по одному на клетку
var _t: float = 0.0

## Its heat part is re-coloured with the lamp state (_set_processing_visual).
func unbatched() -> Array:
	var m := get_node_or_null("MeshInstance3D")
	return [m] if m != null else []

func _ready() -> void:
	moving_parts = true              # the hatches and the gauge (MachineBatch copies them)
	_hatch_in = get_node_or_null("HatchIn") as Node3D
	_hatch_out = get_node_or_null("HatchOut") as Node3D
	_gauge = get_node_or_null("Gauge") as Node3D
	super._ready()
	_cells.resize(CELLS)
	_slots = _pick_slots()
	_set_processing_visual(false)
	# ПРАВЫЙ БОРТ настроен ПОКЛЕТОЧНО, а не маской. Смотрим прямо на правую сторону: снизу
	# СЛЕВА процессор забирает с ленты, снизу СПРАВА отдаёт на ленту. Так он встраивается в
	# линию, идущую ВДОЛЬ борта, и её не надо разворачивать вокруг него; вход сзади и выход
	# вперёд при этом никуда не делись — это по-прежнему маски граней.
	#
	# Верхние две клетки правого борта закрыты ЯВНО: маска input_faces включает всю сторону
	# целиком, и без этого «нет» они принимали бы ленту тоже — то есть настройка снизу
	# ничего бы не значила.
	#
	# Смещения — от якоря, а он у 2×2×2 в углу (blocks._block_footprint: x,z ∈ {-1,0},
	# y ∈ {0,1}). Отсюда и центр футпринта, вокруг которого умолчания поворачиваются вместе
	# с блоком.
	# Только если В СЦЕНЕ ничего не настроено: кубик в инспекторе пишет ровно эти же поля,
	# и код не должен затирать то, что настроил художник.
	if not port_defaults.is_empty():
		return
	cells_center = Vector3(-0.5, 0.5, -0.5)
	port_defaults = {
		port_key(Vector3i(0, 0, 0), FACE_RIGHT_IDX): PORT_IN,     # низ, ближняя к +Z клетка
		port_key(Vector3i(0, 0, -1), FACE_RIGHT_IDX): PORT_OUT,   # низ, дальняя
		port_key(Vector3i(0, 1, 0), FACE_RIGHT_IDX): PORT_NONE,
		port_key(Vector3i(0, 1, -1), FACE_RIGHT_IDX): PORT_NONE,
	}

## Маркеры под клетки. Их в сцене четыре и они ведут груз по дуге через весь станок, а клеток
## три — поэтому берём КРАЙНИЕ и середину, распределяя равномерно. Художник добавит или уберёт
## маркер — раскладка подстроится сама, а зашитые имена пришлось бы править руками.
func _pick_slots() -> Array:
	var all: Array = []
	for c in get_children():
		if c is Marker3D and String(c.name).begins_with("item_slot"):
			all.append(c)
	if all.is_empty():
		return []
	var out: Array = []
	for i in CELLS:
		var k: int = int(round(float(i) * float(all.size() - 1) / float(maxi(CELLS - 1, 1))))
		out.append(all[clampi(k, 0, all.size() - 1)])
	return out

## Можно ли отдать процессору ещё одну руду. Спрашивают снаружи (авто-шахтёр смотрит, кому
## отдать добычу), и ответ у многоклеточного блока не «занят ли current_item», а «свободна ли
## ВХОДНАЯ клетка»: остальные две могут быть заняты, а брать он всё равно готов.
func can_accept() -> bool:
	return _factory_active() and _cells.size() == CELLS and _cells[0] == null

## Ore and wood, and only while the result has somewhere to go. A processor whose output is not
## wired would fill its three cells and stop, and a belt waiting on it would stop the line behind it
## with no word; without an outlet it wants nothing, and ore passes by as it always did.
func wants(item: Node3D) -> bool:
	return _factory_active() and not _valid_targets().is_empty() \
			and is_instance_valid(item) and item.has_method("can_upgrade") and item.can_upgrade()

func try_receive(item: Node3D) -> bool:
	if not can_accept() or item == null or not is_instance_valid(item):
		return false
	# Refused BY KIND, not by outlet (that half is in wants). An ingot, coal or a component used to
	# go in whenever the intake happened to be free and ride three ticks through unchanged: the same
	# six ingots took 19.6 s past a processor against 13.4 s on a bare line.
	if not item.has_method("can_upgrade") or not item.can_upgrade():
		return false
	_cells[0] = item
	_adopt(item, 0)
	_set_processing_visual(true)
	return true

# СВОЙ _process, а не базовый: базовый ретраит зависший груз раз в секунду (push_retry_tick),
# а у нас очередь и так двигается каждый тик и сама пробует отдать. Второй механизм повторов
# тут был бы ровно тем, от чего и ломалось раньше, — вторым источником правды о состоянии.
func _process(delta: float) -> void:
	if not _factory_active():
		return
	_t -= delta
	if _t > 0.0:
		return
	_t = tick_time
	_tick()

func _tick() -> void:
	if _cells.size() != CELLS:
		return
	var last: int = CELLS - 1
	# 1. ВЫХОД. Не отдали — линия внутри стоит целиком: полный станок обязан упереться, иначе
	#    руда копилась бы в последней клетке поверх уже лежащей там.
	var out_item = _cells[last]
	if out_item != null:
		if not is_instance_valid(out_item):
			_cells[last] = null
		elif push_item(out_item):
			_cells[last] = null
		else:
			return
	# 2. СДВИГ на клетку вперёд, с конца — иначе затрём то, что ещё не уехало.
	var had_input: bool = _cells[0] != null
	for i in range(last, 0, -1):
		_cells[i] = _cells[i - 1]
		if _cells[i] == null:
			continue
		if not is_instance_valid(_cells[i]):
			_cells[i] = null
			continue
		# THE ORE BECOMES THE PRODUCT ON ENTERING THE LAST CELL - after two ticks, the third hands
		# it out. At that moment it is still inside the furnace, small; _move shows it come out of
		# the front mouth already changed.
		if i == last and _cells[i].has_method("upgrade"):
			_cells[i].upgrade()
		_move(_cells[i], i)
	_cells[0] = null
	# 3. Входная клетка освободилась — сказать об этом ленте, которая ждёт (см. шапку).
	if had_input:
		slot_freed.emit()
	_set_processing_visual(_busy())

func _busy() -> bool:
	for c in _cells:
		if c != null and is_instance_valid(c):
			return true
	return false

## Забрать предмет себе: заморозить, перецепить и повезти в клетку. Мировую позицию
## запоминаем ДО reparent и возвращаем ПОСЛЕ — иначе предмет прыгает в начало координат блока.
func _adopt(item: Node3D, cell: int) -> void:
	if item is RigidBody3D:
		(item as RigidBody3D).freeze = true
	var world_pos: Vector3 = item.global_position
	item.reparent(self, true)
	item.global_position = world_pos
	_move(item, cell)

## THE TWEEN CARRIES THE PICTURE ONLY. The queue never looks at it: cut short, the machine rotated
## mid-way - the item still counts as in its cell and leaves on the next tick. The whole logic used
## to hang on its signal, and any hiccup meant cargo stuck for good.
func _move(item: Node3D, cell: int) -> void:
	if cell >= _slots.size() or _slots[cell] == null:
		return
	var vis := item.get_node_or_null("MeshInstance3D") as Node3D
	var to: Vector3 = (_slots[cell] as Node3D).position
	var tw: Tween = create_tween()
	match cell:
		1:   # left through the back mouth, and gone; the gauge fills while it melts
			_open_hatch(_hatch_in)
			tw.tween_property(item, "position", to, LEG)
			if vis != null:
				tw.parallel().tween_property(vis, "scale", Vector3.ONE * IN_FURNACE, LEG)
			tw.tween_callback(item.set.bind("visible", false))
			_fill_gauge(1.0, tick_time * 0.9)
		2:   # out of the front mouth already changed, right to the exit, growing back
			_open_hatch(_hatch_out)
			var mouth := get_node_or_null("furnace_out") as Node3D
			if mouth != null:
				item.position = mouth.position
			if vis != null:
				vis.scale = Vector3.ONE * IN_FURNACE
			item.visible = true
			_melt_fx(item)
			tw.tween_property(item, "position", to, LEG)
			if vis != null:
				tw.parallel().tween_property(vis, "scale", Vector3.ONE, LEG)
			_fill_gauge(GAUGE_MIN, 0.4)
		_:
			item.visible = true
			tw.tween_property(item, "position", to, minf(LEG, tick_time * 0.8))
			if vis != null:
				tw.parallel().tween_property(vis, "scale", Vector3.ONE, minf(LEG, tick_time * 0.8))

## A guillotine hatch: up, held while the item passes, down.
func _open_hatch(h: Node3D) -> void:
	if h == null:
		return
	var tw := create_tween()
	tw.tween_property(h, "position:y", HATCH_LIFT, HATCH_TIME)
	tw.tween_interval(LEG)
	tw.tween_property(h, "position:y", 0.0, HATCH_TIME * 1.5)

func _fill_gauge(level: float, time: float) -> void:
	if _gauge == null:
		return
	var tw := create_tween()
	tw.tween_property(_gauge, "scale:y", maxf(level, GAUGE_MIN), time)

func _melt_fx(item: Node3D) -> void:
	if is_instance_valid(item) and item.get_parent() == self:
		BlockFX.play(item, false, MELT_FX_TIME, MELT_A, MELT_B)

## THE HEAT IS THE LAMP (art/emitter_models.py build_processor): the hood's underside over the
## channel, the window on its open side and the furnace's fireboxes, painted LIT and darkened here
## while nothing is inside - the old red/green ball said the same thing in a language no other
## block speaks. A per-block copy of the part's material, made once (a shared one would light every
## processor in the world; a new one per tick would allocate once a second).
const HEAT_COLD := Color(0.20, 0.18, 0.22)
var _lamp: StandardMaterial3D = null

func _set_processing_visual(active: bool) -> void:
	if _lamp == null:
		var mi := get_node_or_null("MeshInstance3D") as MeshInstance3D
		if mi == null:
			return
		var m: Material = mi.mesh.surface_get_material(0) if mi.mesh != null else null
		_lamp = (m as StandardMaterial3D).duplicate() if m is StandardMaterial3D else StandardMaterial3D.new()
		mi.material_override = _lamp
	_lamp.albedo_color = Color.WHITE if active else HEAT_COLD
