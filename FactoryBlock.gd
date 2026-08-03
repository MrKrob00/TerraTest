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
const FACES := ["front", "back", "left", "right", "top", "bottom"]

@export var input_faces: Array[String] = ["back"]     ## Откуда блок ПРИНИМАЕТ ресурс
@export var output_faces: Array[String] = ["front"]   ## Куда блок ОТДАЁТ ресурс

var current_item: Node3D = null
var next_block: FactoryBlock = null
var waiting_for_next: bool = false

# Принимает ли блок ресурс, приходящий с направления from_dir (вектор в осях РОДИТЕЛЯ,
# указывает ОТ соседа К нам). Зовётся из blocks.rebuild_factory_links.
func accepts_from(from_dir: Vector3i) -> bool:
	for f in input_faces:
		if face_dir(f) == -from_dir:      # грань ввода смотрит навстречу приходящему ресурсу
			return true
	return false

# Мировое (в осях родителя-blocks) направление грани с учётом ПОВОРОТА блока.
func face_dir(face: String) -> Vector3i:
	var local: Vector3 = LOCAL_FACE.get(face, Vector3.ZERO)
	if local == Vector3.ZERO:
		return Vector3i.ZERO
	var v: Vector3 = (basis * local).normalized()
	# Прижимаем к ближайшей оси: блок стоит по сетке, поворот кратен 90°.
	if absf(v.x) >= absf(v.y) and absf(v.x) >= absf(v.z):
		return Vector3i(signi(int(signf(v.x))), 0, 0)
	if absf(v.y) >= absf(v.z):
		return Vector3i(0, signi(int(signf(v.y))), 0)
	return Vector3i(0, 0, signi(int(signf(v.z))))

const LOCAL_FACE := {
	"front":  Vector3(0, 0, -1),
	"back":   Vector3(0, 0, 1),
	"right":  Vector3(1, 0, 0),
	"left":   Vector3(-1, 0, 0),
	"top":    Vector3(0, 1, 0),
	"bottom": Vector3(0, -1, 0),
}

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
	if next_block == null or not is_instance_valid(next_block):
		next_block = null                 # следующий блок исчез (разрушен/снят) — не течём в мёртвую ссылку
		return
	if next_block.try_receive(current_item):
		current_item = null
		waiting_for_next = false
		slot_freed.emit()
	else:
		if not waiting_for_next:
			waiting_for_next = true
			next_block.slot_freed.connect(_on_next_block_freed, CONNECT_ONE_SHOT)

func _on_next_block_freed() -> void:
	waiting_for_next = false
	_try_push()
