extends FactoryBlock
# SCRAPPER — разбирает блоки обратно в материалы и отдаёт их в фабричную цепочку.
#
# Сколько и ЧЕГО вернёт — ПОЛОВИНА рецепта блока (G.scrap_yield), материал в материал.
# Правило привязано к тому, во что блок реально обошёлся в производстве, поэтому
# балансируется само: подняли цену сборки — вырос и возврат, отдельную таблицу выплат вести
# не нужно. Возврат идёт ТЕМИ ЖЕ материалами, что ушли в сборку: иначе Scrapper стал бы
# способом менять один металл на другой в обход рудников.
#
# БЛОК БЕЗ РЕЦЕПТА НЕ ПРИНИМАЕТСЯ И НЕ ПОРТИТСЯ. Это не заглушка на время, а правило:
# рецепты есть пока не у всех блоков, и «съесть» блок, за который нечего вернуть, значило
# бы молча его уничтожить. Отказ видно (блок остаётся), и как только рецепт появится в
# G.BLOCK_RECIPE, блок станет разбираемым сам — здесь править ничего не придётся.
#
# What comes in (2x2x2, the player's design - no belt port takes anything in):
#   - the SUCTION PIPE draws loose blocks and loose chunks to its mouth and swallows them (_suck);
#   - the player's HAND - a double tap on a scrapper on SOMEONE ELSE'S machine (vehicle_body_3d).
#     On your own machine the same gesture means "place the block", so feeding is barred there.
# What goes out: the materials, one at a time, through the front's bottom quarter onto a belt.
# try_receive still takes a chunk handed to it directly; with no input port a belt never does.

const RESOURCE_SCENE: String = "res://resource.tscn"
## Пауза между выдачей материалов. Разбор не мгновенный: иначе шесть тел рождаются в одном
## кадре и цепочка захлёбывается, не успевая их принять.
const EMIT_INTERVAL: float = 0.35

var _res_scene: PackedScene = null
var _queue: Array[String] = []       # что ещё осталось выдать: ключ материала на штуку
var _emit_t: float = 0.0

## THE SUCTION PIPE (art/emitter_models.py build_scrapper, the player's design): loose blocks and
## loose chunks within the `suction` sphere round the `nozzle` are drawn to its mouth and
## swallowed there. Only what can be scrapped (a recipe, see can_scrap) and never a quest item: an
## unscrappable block would pile up at the mouth, and a quest block eaten is a branch dead-locked.
## Only while anchored, like the whole factory - a scrapper does not eat what it drives past.
const SUCK_TICK: float = 0.2         # how often the list of what is in reach is refreshed
const SUCK_SPEED: float = 6.0        # m/s towards the mouth
const SUCK_TAKE: float = 1.0         # metres from the mouth: swallowed
const NOZZLE_OUT := Vector3(0.0, -0.55, 0.83)   # the way the nozzle opens, in block axes
const NOZZLE_MOUTH: float = 0.3      # the mouth, this far out along it from the marker
## The rollers turn while there is scrap to hand out (nodes `RollerA` / `RollerB`).
const SPIN: float = 12.0             # rad/s at work
const SPIN_EASE: float = 10.0        # rad/s per second up and down
var _nozzle: Node3D = null
var _suction: Area3D = null
var _pulled: Array = []
var _suck_t: float = 0.0
var _roll_a: Node3D = null
var _roll_b: Node3D = null
var _spin: float = 0.0

func _ready() -> void:
	moving_parts = true
	_nozzle = get_node_or_null("nozzle") as Node3D
	_suction = get_node_or_null("nozzle/suction") as Area3D
	_roll_a = get_node_or_null("RollerA") as Node3D
	_roll_b = get_node_or_null("RollerB") as Node3D
	super._ready()
	_res_scene = load(RESOURCE_SCENE) as PackedScene

## Можно ли разобрать блок этого типа. Публично: спрашивает и рука игрока, чтобы не
# скармливать заведомо неразбираемое.
func can_scrap(block_type: int) -> bool:
	return not G.scrap_yield(block_type).is_empty()

## Разобрать УЗЕЛ блока. true — блок принят (и уничтожен), false — рецепта нет, блок цел.
func scrap_block(node: Node) -> bool:
	if node == null or not is_instance_valid(node) or not ("block" in node):
		return false
	var bt: int = int(node.get("block"))
	var got: Dictionary = G.scrap_yield(bt)
	if got.is_empty():
		return false                      # рецепта нет — не трогаем чужое имущество
	_enqueue(got, 1)
	BlockFX.play(node as Node3D, true)    # распад в «матрицу», как при уничтожении
	node.queue_free()
	return true

## Приём с КОНВЕЙЕРА. Берём только чанки, и только те, чей блок разбираем: чанк однороден,
## поэтому решение принимается один раз на весь контейнер и не бывает «половину съел, половину
## оставил». Неразбираемый чанк не застревает в приёмнике — мы его просто не берём, и он
## поедет дальше по ленте или полежит на складе, пока для его блока не появится рецепт.
func try_receive(item: Node3D) -> bool:
	if not _factory_active() or item == null or not is_instance_valid(item):
		return false
	if not ("chunk_block" in item) or int(item.get("type")) != 3:   # 3 = Type.CHUNK
		return false
	var bt: int = int(item.get("chunk_block"))
	var per: Dictionary = G.scrap_yield(bt)
	if per.is_empty():
		return false                       # рецепта нет — чанк не наш, пусть едет дальше
	_take_chunk(item, per)
	return true

func _take_chunk(item: Node3D, per: Dictionary) -> void:
	_enqueue(per, maxi(int(item.get("chunk_count")), 0))
	item.queue_free()

# Положить в очередь выдачу за n блоков сразу. Очередь плоская, по одной единице материала:
# слитки выходят по одному через EMIT_INTERVAL, и порядок «сколько чего» тут не важен.
func _enqueue(yield_per_block: Dictionary, n: int) -> void:
	for key in yield_per_block:
		for _i in int(yield_per_block[key]) * n:
			_queue.append(String(key))

func _process(delta: float) -> void:
	push_retry_tick(delta)
	_spin = move_toward(_spin, SPIN if not _queue.is_empty() else 0.0, SPIN_EASE * delta)
	if _spin > 0.0 and _roll_a != null and _roll_b != null:
		_roll_a.rotate_x(_spin * delta)
		_roll_b.rotate_x(-_spin * delta)

func _mouth() -> Vector3:
	return _nozzle.global_position + _nozzle.global_basis * (NOZZLE_OUT * NOZZLE_MOUTH)

func _suckable(body: Node) -> bool:
	if not G.is_loose_item(body) or body.has_meta("quest_id"):
		return false
	if body is VehicleBlock:
		return can_scrap(int(body.get("block")))
	if "chunk_block" in body and int(body.get("type")) == 3:          # 3 = Type.CHUNK
		return not G.scrap_yield(int(body.get("chunk_block"))).is_empty()
	return false

func _suck(delta: float) -> void:
	if _suction == null or _nozzle == null:
		return
	_suck_t -= delta
	if _suck_t <= 0.0:
		_suck_t = SUCK_TICK
		_pulled.clear()
		if _factory_active():
			for body in _suction.get_overlapping_bodies():
				if _suckable(body):
					_pulled.append(body)
	if _pulled.is_empty():
		return
	var mouth: Vector3 = _mouth()
	for body in _pulled:
		if not is_instance_valid(body) or not G.is_loose_item(body):
			continue
		var rb := body as RigidBody3D
		var to: Vector3 = mouth - rb.global_position
		if to.length_squared() < SUCK_TAKE * SUCK_TAKE:
			if rb.is_queued_for_deletion():
				continue
			if rb is VehicleBlock:
				scrap_block(rb)
			else:
				BlockFX.play(rb, true)
				_take_chunk(rb, G.scrap_yield(int(rb.get("chunk_block"))))
			continue
		rb.sleeping = false
		rb.linear_velocity = to.normalized() * SUCK_SPEED

func _physics_process(delta: float) -> void:
	_suck(delta)
	if _queue.is_empty():
		return
	_emit_t -= delta
	if _emit_t > 0.0:
		return
	_emit_t = EMIT_INTERVAL
	if not _factory_active():
		return                            # вне якоря фабрика стоит — возврат подождёт в очереди
	_emit_one()

func _emit_one() -> void:
	if _res_scene == null:
		_queue.clear()
		return
	var item: Node3D = _res_scene.instantiate() as Node3D
	if item == null:
		return
	if item.has_method("set_kind_key"):
		item.set_kind_key(_queue[0])      # вид задаётся ключом: "m0" слиток, "c0" компонент
	# Предмет обязан быть в дереве до try_receive: приёмник его репарентит (как в storage).
	get_parent().add_child(item)
	item.global_position = global_position
	if push_item(item):
		_queue.remove_at(0)
	else:
		item.queue_free()                 # цепочка занята — попробуем на следующем тике
