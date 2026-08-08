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

const FACE_FRONT  := 1
const FACE_BACK   := 2
const FACE_LEFT   := 4
const FACE_RIGHT  := 8
const FACE_TOP    := 16
const FACE_BOTTOM := 32

# Локальные направления сторон (в осях самого блока; поворот учитывается в face_dirs).
const FACE_VECS := [
	Vector3(0, 0, -1),   # Front
	Vector3(0, 0, 1),    # Back
	Vector3(-1, 0, 0),   # Left
	Vector3(1, 0, 0),    # Right
	Vector3(0, 1, 0),    # Top
	Vector3(0, -1, 0),   # Bottom
]

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

# Направления отмеченных сторон в осях РОДИТЕЛЯ (с учётом поворота блока).
func face_dirs(mask: int) -> Array:
	var out: Array[Vector3i] = []
	for i: int in FACE_VECS.size():
		if mask & (1 << i) == 0:
			continue
		var v: Vector3 = (basis * FACE_VECS[i]).normalized()
		# Прижимаем к ближайшей оси: блок стоит по сетке, поворот кратен 90°.
		if absf(v.x) >= absf(v.y) and absf(v.x) >= absf(v.z):
			out.append(Vector3i(int(signf(v.x)), 0, 0))
		elif absf(v.y) >= absf(v.z):
			out.append(Vector3i(0, int(signf(v.y)), 0))
		else:
			out.append(Vector3i(0, 0, int(signf(v.z))))
	return out

func _ready() -> void:
	await get_tree().process_frame
	super._ready()


# Фабрика работает ТОЛЬКО под якорем: машина должна стоять заякоренной. Исключение —
# коллектор (он не в этой цепочке): подбирает с земли всегда, а вот передача дальше
# (intake забирает у него и пушит по цепочке) уже гейтится этим условием.
func _factory_active() -> bool:
	var p := get_parent()
	if p == null or p.name != "blocks":
		return false                      # блок валяется в мире — фабрика не работает
	var vehicle := p.get_parent()
	return vehicle != null and bool(vehicle.get("anchored"))

func try_receive(item: Node3D) -> bool:
	if not _factory_active():
		return false                      # без якоря цепочка стоит
	if current_item != null:
		return false
	if not is_instance_valid(item):
		return false
	current_item = item
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
		return                            # без якоря дальше не передаём
	if current_item == null or not is_instance_valid(current_item):
		current_item = null
		return
	if push_item(current_item):
		current_item = null
		waiting_for_next = false
		slot_freed.emit()
		return
	# Никто не принял — ждём, когда освободится первый занятый приёмник.
	var wait_on := _first_valid_target()
	if wait_on != null and not waiting_for_next:
		waiting_for_next = true
		wait_on.slot_freed.connect(_on_next_block_freed, CONNECT_ONE_SHOT)

# Отдать предмет ЛЮБОМУ из подключённых приёмников. Обходим их ПО КРУГУ (_out_turn), поэтому
# блок с несколькими выходами работает делителем и раздаёт поровну, а не забивает первый.
func push_item(item: Node3D) -> bool:
	var targets := _valid_targets()
	if targets.is_empty() or item == null or not is_instance_valid(item):
		return false
	for i: int in targets.size():
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
