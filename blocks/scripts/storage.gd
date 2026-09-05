extends FactoryBlock

# СКЛАД. Принимает ОДИН ВИД материала и держит до CAPACITY штук. Все четыре горизонтальные
# грани работают и на вход, и на выход — что именно окажется входом, решает то, с какой
# стороны подвели конвейер.
#
# Внутри лежит НЕ двадцать предметов, а один показательный: физика двух десятков тел на
# каждом складе — это не про мобилку. Количество читается с таблички рядом.
#
# «Вид» — это kind_key ресурса, а не его Type: ферритовый слиток и титанитовый это РАЗНЫЕ
# вещи, и ссыпать их в одну кучу нельзя — иначе склад отдавал бы наружу не то, что съел,
# и рецепты собирались бы из воздуха. Раньше здесь стоял именно Type, и все слитки мира
# были для склада одним предметом.

const CAPACITY: int = 20
const RESOURCE_SCENE: String = "res://resource.tscn"
## Как часто склад пробует отдать наружу. Каждый кадр незачем: приёмник освобождается редко.
const PUSH_INTERVAL: float = 0.35

var stored_kind: String = ""               # "" — склад пуст и примет любой вид
var count: int = 0
var _chunk_counts: Array[int] = []         # сколько блоков в каждом принятом чанке, по порядку

var _display: Node3D = null                # тот самый один предмет-витрина
var _label: Label3D = null
var _push_t: float = 0.0
var _res_scene: PackedScene = null

func _ready() -> void:
	super._ready()
	_res_scene = load(RESOURCE_SCENE) as PackedScene
	_build_label()
	_refresh_visual()

# ── Приём ────────────────────────────────────────────────────────────────────
# Предмет не кладём внутрь, а СЧИТАЕМ и уничтожаем: витрина одна на весь склад.
func try_receive(item: Node3D) -> bool:
	if not _factory_active() or item == null or not is_instance_valid(item):
		return false
	var k: String = item.kind_key() if item.has_method("kind_key") else ""
	if k == "":
		return false                       # не материал — складу такое не положишь
	if stored_kind != "" and k != stored_kind:
		return false                       # склад держит ОДИН вид
	if count >= CAPACITY:
		return false
	stored_kind = k
	count += 1
	# У ЧАНКА мало знать вид: «chunk:5» говорит, ЧТО внутри, но не СКОЛЬКО. Держим счётчики
	# по одному на принятый чанк — иначе склад отдал бы наружу пустой контейнер, а блоки в
	# нём просто исчезли бы.
	if k.begins_with("chunk:"):
		_chunk_counts.append(int(item.get("chunk_count")) if "chunk_count" in item else 0)
	item.queue_free()
	_refresh_visual()
	return true

# ── Выдача ───────────────────────────────────────────────────────────────────
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
	# Предмет обязан существовать в дереве до try_receive: приёмник его репарентит.
	get_parent().add_child(item)
	item.global_position = global_position
	if push_item(item):
		count -= 1
		if not _chunk_counts.is_empty():
			_chunk_counts.remove_at(0)     # снимаем счётчик только после УДАЧНОЙ отправки
		if count == 0:
			stored_kind = ""               # опустел — примет любой вид
		_refresh_visual()
	else:
		item.queue_free()                  # никто не принял — не плодим тела в мире

# Предмет по хранимому виду. Счётчик чанка ПОДСМАТРИВАЕМ, а не снимаем: отправка может не
# состояться (приёмник занят), и тогда предмет уничтожается — снятый счётчик пропал бы с ним.
func _make_item() -> Node3D:
	if _res_scene == null or stored_kind == "":
		return null
	var it: Node3D = _res_scene.instantiate() as Node3D
	if it == null:
		return null
	if it.has_method("set_kind_key"):
		it.set_kind_key(stored_kind)
	if not _chunk_counts.is_empty() and "chunk_count" in it:
		it.set("chunk_count", _chunk_counts[0])
	return it

# ── Витрина: один предмет + табличка с количеством ───────────────────────────
func _refresh_visual() -> void:
	if count <= 0:
		if is_instance_valid(_display):
			_display.queue_free()
		_display = null
	elif _display == null or not is_instance_valid(_display):
		_display = _make_item()
		if _display != null:
			add_child(_display)
			_display.position = $item_slot.position if has_node("item_slot") else Vector3.ZERO
			if _display is RigidBody3D:
				var rb := _display as RigidBody3D
				rb.freeze = true             # витрина не должна ни падать, ни толкаться
				rb.collision_layer = 0
				rb.collision_mask = 0
	if _label != null:
		_label.text = str(count)
		_label.visible = count > 0

func _build_label() -> void:
	_label = Label3D.new()
	_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED   # текст всегда развёрнут к игроку
	_label.no_depth_test = true
	_label.fixed_size = true                              # не мельчает с расстоянием
	_label.pixel_size = 0.0016
	_label.font_size = 96
	_label.outline_size = 24
	_label.modulate = Color(1.0, 0.95, 0.75)
	_label.visible = false
	add_child(_label)

# Табличка ОБЛЕТАЕТ предмет вслед за игроком: она всегда снизу-справа ОТ КАМЕРЫ, а не с
# фиксированной стороны блока — иначе с половины ракурсов она пряталась бы за самим складом.
func _process(_delta: float) -> void:
	# Свой _process заслоняет базовый (FactoryBlock), поэтому его тик зовём сами: без него
	# склад с готовым грузом никогда не повторил бы попытку отдать (см. push_retry_tick).
	push_retry_tick(_delta)
	if _label == null or not _label.visible:
		return
	var cam: Camera3D = get_viewport().get_camera_3d()
	if cam == null:
		return
	var centre: Vector3 = _display.global_position if is_instance_valid(_display) else global_position
	var right: Vector3 = cam.global_transform.basis.x
	var up: Vector3 = cam.global_transform.basis.y
	_label.global_position = centre + right * 0.34 - up * 0.3
