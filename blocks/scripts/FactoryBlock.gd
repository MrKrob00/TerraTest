# factory_block.gd
class_name FactoryBlock
extends VehicleBlock

signal slot_freed

# ── ГРАНИ ВВОДА/ВЫВОДА ────────────────────────────────────────────────────────
# Настраиваются В ИНСПЕКТОРЕ для КАЖДОЙ сцены фабричного блока (belt.tscn, processor.tscn…).
# Грани заданы в СОБСТВЕННЫХ осях блока и поворачиваются вместе с ним при постановке:
#   front = −Z (морда), back = +Z, right = +X, left = −X, top = +Y, bottom = −Y
# Ресурс уходит с грани из output_faces в соседа, у которого НАВСТРЕЧУ смотрит одна из
# input_faces. Пусто в output_faces = блок ничего не отдаёт (продавец, генератор — «сток»).
# Галочки в инспекторе: отмечаешь нужные стороны, ничего вписывать руками не надо.
# Сторон можно отметить сколько угодно — блок бывает и многовходовым, и многовыходным.
@export_flags("Front (−Z)", "Back (+Z)", "Left (−X)", "Right (+X)", "Top (+Y)", "Bottom (−Y)") \
		var input_faces: int = FACE_BACK       ## Стороны, которыми блок ПРИНИМАЕТ ресурс
@export_flags("Front (−Z)", "Back (+Z)", "Left (−X)", "Right (+X)", "Top (+Y)", "Bottom (−Y)") \
		var output_faces: int = FACE_FRONT     ## Стороны, которыми блок ОТДАЁТ ресурс

# FACE_* , FACE_VECS и face_dirs() живут в VehicleBlock: там же ими описаны грани
# СТЫКОВКИ, и держать два набора одних и тех же констант — способ их рассинхронить.

# ── ПОРТЫ: настройка ПОКЛЕТОЧНО (для блоков 2×2×2 и больше) ───────────────────
# У односкеточного блока грань и есть коннектор — шесть штук, галочек хватает. А у
# фабрикатора 2×2×2 одна сторона это ЧЕТЫРЕ клетки, и «вход слева» означало «вход во все
# четыре левых клетки сразу»: подвести к такому блоку две разные ленты с одной стороны было
# нельзя, а именно так и строят настоящие цепочки.
#
# Порт — это пара «КЛЕТКА + НАПРАВЛЕНИЕ». Ключ хранится в осях КАРТЫ, а не блока, и вот
# почему: футпринт многоклеточного блока (blocks._block_footprint) тоже строится по осям
# карты и от поворота не зависит. Держать половину описания в локальных осях, а половину в
# мировых — самый быстрый способ получить порт, который «есть, но не там».
#
# Пусто по ключу — работает СТАРОЕ правило (маски граней). Поэтому все существующие блоки,
# сцены и сейвы продолжают вести себя ровно как раньше, пока игрок ничего не трогал.
const PORT_NONE := 0
const PORT_IN := 1
const PORT_OUT := 2

## "dx,dy,dz|d" → PORT_*. dx/dy/dz — смещение клетки от якоря, d — индекс направления в
## FACE_VECS. Живёт также в раскладке машины (blocks.port_map), чтобы пережить сейв.
var ports: Dictionary = {}

## Ключ порта — тот же, что у стыковки (VehicleBlock.side_key): «клетка + сторона». Имя
## оставлено своим, потому что им пользуются сцены блоков и окно портов.
static func port_key(off: Vector3i, dir_idx: int) -> String:
	return VehicleBlock.side_key(off, dir_idx)

## ПОРТЫ ПО УМОЛЧАНИЮ — ключ той же формы, но в ЛОКАЛЬНЫХ осях блока и с ЛОКАЛЬНЫМ
## смещением клетки. Разница с ports принципиальная: ports правит игрок на конкретной машине,
## и они живут в осях КАРТЫ (там видно, куда реально идёт лента), а defaults описывают САМ
## БЛОК — «снизу слева забираю, снизу справа отдаю» — и обязаны поворачиваться вместе с ним.
## Иначе повёрнутый процессор ждал бы ленту не с той клетки.
## ЭКСПОРТ, а не просто поле: их настраивают В РЕДАКТОРЕ, кубиком в инспекторе
## (addons/blockfaces), и значение обязано лежать в сцене блока, а не в коде.
@export var port_defaults: Dictionary = {}
## Что делает эта клетка в эту сторону. Порядок ответов: правка игрока → умолчание сцены →
## маски граней. Не задано ничего — блок ведёт себя ровно как до появления портов.
func port_state(off: Vector3i, dir_idx: int) -> int:
	var k := port_key(off, dir_idx)
	if ports.has(k):
		return int(ports[k])
	var def: int = _default_state(off, dir_idx)
	if def >= 0:
		return def
	var d: Vector3i = dir_of(dir_idx)
	if face_dirs(output_faces).has(d):
		return PORT_OUT
	if face_dirs(input_faces).has(d):
		return PORT_IN
	return PORT_NONE

## Умолчание для этой клетки и стороны, переведённое в СВОИ оси блока, или -1 (нет такого).
func _default_state(off: Vector3i, dir_idx: int) -> int:
	if port_defaults.is_empty():
		return -1
	# Перевод «клетка + сторона» из осей карты в свои — общий с настройками стыковки
	# (VehicleBlock._local_side): правило одно, и разъезжаться ему негде.
	var lk := _local_side(off, dir_of(dir_idx))
	return int(port_defaults[lk]) if lk != "" and port_defaults.has(lk) else -1

func set_port(off: Vector3i, dir_idx: int, state: int) -> void:
	ports[port_key(off, dir_idx)] = state

var current_item: Node3D = null
var next_block: FactoryBlock = null       # текущая цель выдачи (одна из next_blocks)
var next_blocks: Array = []               # ВСЕ подключённые приёмники (многовыходный блок)
var _out_turn: int = 0                    # по кругу между выходами, чтобы делитель делил поровну
var waiting_for_next: bool = false

# Принимает ли блок ресурс, приходящий с направления from_dir (вектор в осях РОДИТЕЛЯ,
# указывает ОТ соседа К нам). Зовётся из blocks.rebuild_factory_links.
func accepts_from(from_dir: Vector3i) -> bool:
	for dir in face_dirs(input_faces):
		if dir == -from_dir:              # сторона ввода смотрит навстречу приходящему ресурсу
			return true
	return false

## То же, но для КОНКРЕТНОЙ клетки многоклеточного блока: ресурс приходит В клетку off с
## направления from_dir. Порт этой клетки должен смотреть навстречу — то есть быть входом
## в сторону −from_dir.
func accepts_at(off: Vector3i, from_dir: Vector3i) -> bool:
	var idx: int = idx_of(-from_dir)
	return idx >= 0 and port_state(off, idx) == PORT_IN

## Отдаёт ли клетка off в сторону dir.
func outputs_at(off: Vector3i, dir: Vector3i) -> bool:
	var idx: int = idx_of(dir)
	return idx >= 0 and port_state(off, idx) == PORT_OUT

# Направления отмеченных сторон в осях РОДИТЕЛЯ (с учётом поворота блока).
func _ready() -> void:
	await get_tree().process_frame
	super._ready()


# Фабрика работает ТОЛЬКО под якорем: машина должна стоять заякоренной. Исключение —
# коллектор (он не в этой цепочке): подбирает с земли всегда, а вот передача дальше
# (приёмник забирает у него и пушит по цепочке) уже гейтится этим условием.
func _factory_active() -> bool:
	var p := get_parent()
	if p == null or p.name != "blocks":
		return false                      # блок валяется в мире — фабрика не работает
	var vehicle := p.get_parent()
	# == true, а не bool(): у машины без поля anchored (враги его не имеют) get() вернёт null,
	# а bool(null) роняет вызов в рантайме.
	return vehicle != null and vehicle.get("anchored") == true

func try_receive(item: Node3D) -> bool:
	if not _factory_active():
		return false                      # без якоря цепочка стоит
	if current_item != null:
		return false
	if not is_instance_valid(item):
		return false
	current_item = item
	_push_pending = false                 # новый груз: прошлая неудача к нему отношения не имеет
	if item is RigidBody3D:
		item.freeze = true
	# Запоминаем мировую позицию ДО reparent
	var world_pos: Vector3 = item.global_position
	item.reparent(self, true)
	# Восстанавливаем мировую позицию ПОСЛЕ reparent
	item.global_position = world_pos
	# Анимируем к item_slot
	var target: Vector3 = Vector3.ZERO
	if has_node("item_slot"):
		target = to_local(global_position) + $item_slot.position
		target = $item_slot.position
	var tween: Tween = create_tween()
	tween.tween_property(item, "position", target, 0.3)
	tween.finished.connect(func(): _on_item_received(), CONNECT_ONE_SHOT)
	return true

func _on_item_received() -> void:
	pass

func _try_push() -> void:
	if not _factory_active():
		_push_pending = true              # без якоря дальше не передаём, но попытку не теряем
		return
	if current_item == null or not is_instance_valid(current_item):
		current_item = null
		_push_pending = false
		return
	if push_item(current_item):
		current_item = null
		waiting_for_next = false
		_push_pending = false
		slot_freed.emit()
		return
	# Никто не принял. Ждём, когда освободится первый занятый приёмник...
	var wait_on := _first_valid_target()
	if wait_on != null and not waiting_for_next:
		waiting_for_next = true
		wait_on.slot_freed.connect(_on_next_block_freed, CONNECT_ONE_SHOT)
	# ...и В ЛЮБОМ СЛУЧАЕ помечаем, что отдать не удалось (см. push_retry_tick).
	_push_pending = true

## ПОВТОРНАЯ ПОПЫТКА ОТДАТЬ — иначе блок с готовым грузом застревает НАВСЕГДА.
##
## Единственным способом попробовать ещё раз была подписка на slot_freed ПЕРВОГО подключённого
## приёмника. Значит: соседей нет вовсе (игрок ещё не положил ленту, её сбили, цепочку
## пересобрали) — подписываться не на кого, и блок стоял с грузом до конца игры, даже когда
## ленту наконец ставили. То же самое, если приёмник появился уже ПОСЛЕ неудачной попытки:
## его slot_freed мы не слушаем, потому что подписка ушла в другой узел.
##
## Ретраим ТОЛЬКО то, что уже пыталось уйти (_push_pending). Это важно: процессор ведёт
## предмет по слотам две секунды, и ретрай «просто по таймеру» отдал бы руду дальше НЕДОДЕЛАННОЙ.
const PUSH_RETRY := 1.0
var _push_pending: bool = false
var _retry_t: float = 0.0

func _process(delta: float) -> void:
	push_retry_tick(delta)

## Вынесено отдельным методом, потому что наследник может определить свой _process и заслонить
## базовый (так делает storage.gd) — тогда он зовёт этот тик сам.
func push_retry_tick(delta: float) -> void:
	if not _push_pending or current_item == null or waiting_for_next:
		return
	_retry_t -= delta
	if _retry_t > 0.0:
		return
	_retry_t = PUSH_RETRY
	_try_push()

# Отдать предмет ЛЮБОМУ из подключённых приёмников. Обходим их ПО КРУГУ (_out_turn), поэтому
# блок с несколькими выходами работает делителем и раздаёт поровну, а не забивает первый.
func push_item(item: Node3D) -> bool:
	var targets := _valid_targets()
	if targets.is_empty() or item == null or not is_instance_valid(item):
		return false
	for i in targets.size():
		var t: FactoryBlock = targets[(_out_turn + i) % targets.size()]
		if t.try_receive(item):
			_out_turn = (_out_turn + i + 1) % targets.size()
			next_block = t
			return true
	return false

func _valid_targets() -> Array:
	var out: Array = []
	for t in next_blocks:
		if t != null and is_instance_valid(t):
			out.append(t)
	return out

func _first_valid_target() -> FactoryBlock:
	var t := _valid_targets()
	return t[0] if not t.is_empty() else null

func _on_next_block_freed() -> void:
	waiting_for_next = false
	_try_push()
