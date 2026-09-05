# processor.gd
extends FactoryBlock

# ПРОЦЕССОР — ЭТО ВНУТРЕННИЙ КОНВЕЙЕР НА ТРИ КЛЕТКИ, а не одна ячейка с таймером.
#
# Каждый тик (тик = одно движение ленты, см. belt.belt_speed) всё внутри сдвигается на клетку
# вперёд: руда, вошедшая в первую, выходит из последней через ТРИ тика — уже слитком. Отсюда
# всё поведение, которое и просили: внутрь помещается три штуки, три подряд вошло — три подряд
# и выйдет, и на переработку одной уходит три тика.
#
# ЧТО БЫЛО РАНЬШЕ И ПОЧЕМУ ЭТО ЛОМАЛОСЬ. Ячейка была ОДНА (base.current_item), а «переработка»
# висела на цепочке из четырёх await'ов по таймеру, которую запускал ТВИН, довозивший предмет
# до слота. Из этого выходило две беды, и обе видел игрок:
#
#   • из трёх выданных на ленту руд процессор брал одну, а две проезжали мимо — брать было
#     некуда, пока первая не доедет по слотам;
#   • если цепочка await'ов обрывалась (машину пересобрали, блок повернули, твин не доиграл),
#     _try_push не звался ВООБЩЕ — а значит и _push_pending не выставлялся, и ретрай из базы
#     не срабатывал. Груз оставался внутри навсегда, лампа горела зелёным. Ровно то, на что
#     жаловались: «первую так и не выдал».
#
# Теперь состояние — это массив клеток, а движение — тик. Ни одного await, ни одной зависимости
# от анимации: твин только ВЕЗЁТ картинку в новую клетку, а очередь живёт сама по себе.
#
# ОБЯЗАТЕЛЬСТВО ПЕРЕД ЛЕНТОЙ: как только освободилась ВХОДНАЯ клетка, шлём slot_freed. Лента,
# которой отказали, ставит waiting_for_next и подписывается на этот сигнал — без него она ждёт
# его вечно и своих повторов не делает (см. FactoryBlock.push_retry_tick).

## Сколько руды помещается внутрь. Оно же — сколько тиков идёт переработка одной штуки:
## клетка за тик, три клетки — три тика.
const CELLS := 3
## Длительность тика. Один тик = одно движение ленты, поэтому число то же, что belt_speed в
## belt.tscn: процессор, который тикает вдвое реже линии, копит перед собой пробку, а вдвое
## чаще — просто ждёт с пустыми клетками.
@export var tick_time: float = 1.0

## Индекс стороны +X в FACE_VECS (см. VehicleBlock): «правый борт» процессора.
const FACE_RIGHT_IDX := 3

var _cells: Array = []          # предметы по клеткам: 0 — вход, CELLS-1 — выход
var _slots: Array = []          # маркеры, по одному на клетку
var _t: float = 0.0

func _ready() -> void:
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

func try_receive(item: Node3D) -> bool:
	if not can_accept() or item == null or not is_instance_valid(item):
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
		# РУДА СТАНОВИТСЯ СЛИТКОМ НА ВХОДЕ В ПОСЛЕДНЮЮ КЛЕТКУ, то есть после двух тиков, и
		# третий тик её уже выдаёт. Так игрок видит готовый слиток внутри станка, а не
		# превращение в момент выдачи, когда смотреть уже некуда.
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

## Твин ВЕЗЁТ ТОЛЬКО КАРТИНКУ. Очередь на него не смотрит: не доиграл, оборвался, блок
## повернули посреди пути — предмет всё равно числится в своей клетке и уедет следующим тиком.
## Раньше вся логика висела на его сигнале, и любой сбой означал груз, застрявший навсегда.
func _move(item: Node3D, cell: int) -> void:
	if cell >= _slots.size() or _slots[cell] == null:
		return
	var tween: Tween = create_tween()
	tween.tween_property(item, "position", (_slots[cell] as Node3D).position,
			minf(0.3, tick_time * 0.8))

## Материал КЕШИРУЕМ. Он ставится на свой MeshInstance через material_override, но создавать
## его заново на каждый вызов нельзя: тик идёт раз в секунду, и каждый раз рождался бы новый
## StandardMaterial3D.
var _lamp: StandardMaterial3D = null

func _set_processing_visual(active: bool) -> void:
	if _lamp == null:
		_lamp = StandardMaterial3D.new()
		$MeshInstance3D.material_override = _lamp
	_lamp.albedo_color = Color.GREEN if active else Color.RED
