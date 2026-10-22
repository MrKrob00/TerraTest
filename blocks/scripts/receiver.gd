extends FactoryBlock
class_name Receiver

# Receiver is a single-resource intake/output node that sits between belts and process blocks.
# It does not craft, it does not melt, it only stores one kind at a time and passes it on.
# This is the missing layer between a belt and a machine: a block can accept a stream of one kind,
# then release it later without letting a whole chain stall.

const RESOURCE_SCENE: String = "res://resource.tscn"
const CAPACITY: int = 12
const PUSH_INTERVAL: float = 0.35

var stored_kind: String = ""
var count: int = 0
var _push_t: float = 0.0
var _res_scene: PackedScene = null

func _ready() -> void:
	super._ready()
	_res_scene = load(RESOURCE_SCENE) as PackedScene

func works_mobile() -> bool:
	return true

func can_accept() -> bool:
	return _factory_active() and (stored_kind == "" or count < CAPACITY)

func wants(item: Node3D) -> bool:
	if not _factory_active() or item == null or not is_instance_valid(item):
		return false
	if not item.has_method("kind_key"):
		return false
	var k: String = item.kind_key()
	return k != "" and (stored_kind == "" or stored_kind == k) and count < CAPACITY

func try_receive(item: Node3D) -> bool:
	if not _factory_active() or item == null or not is_instance_valid(item):
		return false
	if not item.has_method("kind_key"):
		return false
	var k: String = item.kind_key()
	if k == "":
		return false
	if stored_kind != "" and stored_kind != k:
		return false
	if count >= CAPACITY:
		return false
	stored_kind = k
	count += 1
	item.queue_free()
	return true

func _physics_process(delta: float) -> void:
	if count <= 0 or next_blocks.is_empty():
		return
	_push_t -= delta
	if _push_t > 0.0:
		return
	_push_t = PUSH_INTERVAL
	if not _factory_active():
		return
	var item: Node3D = _make_item()
	if item == null:
		return
	get_parent().add_child(item)
	item.global_position = global_position
	if push_item(item):
		count -= 1
		if count <= 0:
			stored_kind = ""
		slot_freed.emit()
	else:
		item.queue_free()

func _make_item() -> Node3D:
	if _res_scene == null or stored_kind == "":
		return null
	var item: Node3D = _res_scene.instantiate() as Node3D
	if item == null:
		return null
	if item.has_method("set_kind_key"):
		item.set_kind_key(stored_kind)
	return item
