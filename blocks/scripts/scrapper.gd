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
# Входа два:
#   • ЧАНК с конвейера — контейнер на 24 блока одного типа, его пакует коллектор
#     (см. collector._pack_block); принимается тем же try_receive, что и ресурсы;
#   • РУКА игрока — двойной тап по Scrapper'у на ЧУЖОЙ машине (см. vehicle_body_3d).
#     На своей машине тот же жест означает «поставить блок», поэтому там скармливать нельзя.

const RESOURCE_SCENE: String = "res://resource.tscn"
## Пауза между выдачей материалов. Разбор не мгновенный: иначе шесть тел рождаются в одном
## кадре и цепочка захлёбывается, не успевая их принять.
const EMIT_INTERVAL: float = 0.35

var _res_scene: PackedScene = null
var _queue: Array[String] = []       # что ещё осталось выдать: ключ материала на штуку
var _emit_t: float = 0.0

func _ready() -> void:
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
	_enqueue(per, maxi(int(item.get("chunk_count")), 0))
	item.queue_free()
	return true

# Положить в очередь выдачу за n блоков сразу. Очередь плоская, по одной единице материала:
# слитки выходят по одному через EMIT_INTERVAL, и порядок «сколько чего» тут не важен.
func _enqueue(yield_per_block: Dictionary, n: int) -> void:
	for key in yield_per_block:
		for _i in int(yield_per_block[key]) * n:
			_queue.append(String(key))

func _physics_process(delta: float) -> void:
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
