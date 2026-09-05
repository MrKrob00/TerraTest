extends FactoryBlock
# УПАКОВЩИК — притягивает свободные БЛОКИ и пакует их в чанки.
#
# Зачем отдельный блок. Блок в мире это RigidBody с коллизией и весом; двадцать четыре штуки
# на ленте — двадцать четыре физических тела. Чанк же на ленте всегда ОДИН предмет, сколько бы
# блоков в нём ни лежало (см. resource.gd). Раньше упаковку пытался делать коллектор, но у его
# зоны маска 8 — только РЕСУРСЫ, — то есть свободного блока он не видел никогда, и ветка
# упаковки в нём была мёртвой. Роль вынесена сюда целиком.
#
# МАГНИТ — не код, а физика. Area3D с точечной гравитацией (gravity_point) тянет к себе всё,
# что лежит на слое блоков. Тот же приём, что у чёрной дыры магазина: сервер физики делает это
# сам, без единой строки в _process и без перебора тел каждый кадр.
#
# КУДА УХОДИТ ЧАНК: сперва пробуем на ленту (push_item), не приняли — роняем в мир. Второе не
# запасной путь, а полноценный режим: на ходу конвейер не работает (вся фабрика живёт под
# якорем), и упаковщик тогда просто складывает трофеи под себя. Оба вида чанков потом
# подбираются приёмником и коллектором — это обычный предмет на слое ресурсов.

## Сколько открытых чанков держим. Больше одного нужно, потому что чанк однороден: подобрали
## колесо и блок — это два разных контейнера, и второй не должен ждать, пока уедет первый.
@export var capacity: int = 2
## Через сколько секунд без новых блоков недособранный чанк всё равно отправляется дальше.
## Без этого один-единственный трофей лежал бы в упаковщике вечно, ожидая двадцать четвёртого.
@export var flush_delay: float = 4.0
## Как часто пробуем отдать готовое. Каждый кадр незачем: приёмник освобождается редко.
const PUSH_INTERVAL: float = 0.35

var _chunks: Array = []            # открытые чанки (узлы под $resources)
var _idle: float = 0.0             # сколько секунд не приходило новых блоков
var _push_t: float = 0.0

func _ready() -> void:
	super._ready()
	if not has_node("resources"):
		var holder := Node3D.new()
		holder.name = "resources"
		add_child(holder)
	$intake.body_entered.connect(_on_intake)

# ── Приём блока ──────────────────────────────────────────────────────────────
# Берём ТОЛЬКО то, что лежит в мире: блок на чужой машине тоже на слое 2, и без этой проверки
# упаковщик разбирал бы проезжающие мимо машины по кусочку.
func _on_intake(body: Node3D) -> void:
	if body == null or not is_instance_valid(body) or not ("block" in body):
		return
	if not G.is_loose_item(body):
		return
	if pack_block_into(_chunks, $resources, body, capacity):
		_idle = 0.0
		_stack_chunks()

# Складываем чанки столбиком над блоком — то же, что делает коллектор со своей добычей:
# видно, что упаковщик не пустой, и сколько в нём ждёт отправки.
func _stack_chunks() -> void:
	_chunks = _chunks.filter(func(c): return is_instance_valid(c))
	for i in _chunks.size():
		(_chunks[i] as Node3D).position = Vector3(0.0, float(i) + 1.0, 0.0)

# ── Отправка ─────────────────────────────────────────────────────────────────
func _physics_process(delta: float) -> void:
	var _pf := Perf.now()          # profiler mark (perf.gd)
	_tick_packer(delta)
	Perf.mark("factory", _pf)

func _tick_packer(delta: float) -> void:
	_chunks = _chunks.filter(func(c): return is_instance_valid(c))
	if _chunks.is_empty():
		_idle = 0.0
		return
	_idle += delta
	_push_t -= delta
	if _push_t > 0.0:
		return
	_push_t = PUSH_INTERVAL
	# Полный чанк уходит сразу, недособранный — когда стало ясно, что добавлять больше нечего.
	var first: Node3D = _chunks[0]
	var full: bool = int(first.get("chunk_count")) >= 24
	if not full and _idle < flush_delay:
		return
	_send(first)

func _send(chunk: Node3D) -> void:
	var world_pos: Vector3 = chunk.global_position
	# Предмет обязан быть в дереве и с чистой мировой позицией до try_receive: приёмник его
	# репарентит (как в storage и в приёмнике).
	chunk.reparent(get_tree().root, false)
	chunk.global_position = world_pos
	if push_item(chunk):
		_chunks.erase(chunk)
		_idle = 0.0
		_stack_chunks()
		return
	# Ленты нет или она занята — кладём под себя, в мир. Чанк становится обычным предметом:
	# его подберёт приёмник, коллектор или сам игрок.
	var objects: Node = get_node_or_null("/root/Main/objects")
	if objects == null:
		chunk.reparent($resources, false)      # мира нет — пусть лучше подождёт внутри
		_stack_chunks()
		return
	chunk.reparent(objects, false)
	chunk.global_position = global_position + _drop_dir() * 1.4 + Vector3.UP * 0.6
	if chunk is RigidBody3D:
		var rb := chunk as RigidBody3D
		rb.freeze = false                      # замороженный чанк никто не подберёт
		rb.sleeping = false
	_chunks.erase(chunk)
	_idle = 0.0
	_stack_chunks()

# Куда ронять: наружу по грани вывода, как это делает фабрикатор. Направление у нескольких
# граней общее, поэтому берём первую.
func _drop_dir() -> Vector3:
	var dirs: Array = face_dirs(output_faces)
	if dirs.is_empty():
		return -global_transform.basis.z
	var d: Vector3i = dirs[0]
	return Vector3(d.x, d.y, d.z).normalized()
