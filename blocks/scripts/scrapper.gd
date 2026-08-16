extends FactoryBlock
# SCRAPPER — разбирает блоки обратно в слитки и отдаёт их в фабричную цепочку.
#
# Сколько вернёт — ПОЛОВИНА рецепта блока (G.scrap_yield). Правило привязано к тому, во
# что блок реально обошёлся в производстве, поэтому балансируется само: подняли цену
# сборки — вырос и возврат, отдельную таблицу выплат вести не нужно.
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
## Пауза между выдачей слитков. Разбор не мгновенный: иначе шесть тел рождаются в одном
## кадре и цепочка захлёбывается, не успевая их принять.
const EMIT_INTERVAL: float = 0.35

var _res_scene: PackedScene = null
var _queue: Array[int] = []          # что ещё осталось выдать: тип ресурса на штуку
var _emit_t: float = 0.0

func _ready() -> void:
	super._ready()
	_res_scene = load(RESOURCE_SCENE) as PackedScene

## Можно ли разобрать блок этого типа. Публично: спрашивает и рука игрока, чтобы не
# скармливать заведомо неразбираемое.
func can_scrap(block_type: int) -> bool:
	return G.scrap_yield(block_type) > 0

## Разобрать УЗЕЛ блока. true — блок принят (и уничтожен), false — рецепта нет, блок цел.
func scrap_block(node: Node) -> bool:
	if node == null or not is_instance_valid(node) or not ("block" in node):
		return false
	var bt: int = int(node.get("block"))
	var got: int = G.scrap_yield(bt)
	if got <= 0:
		return false                      # рецепта нет — не трогаем чужое имущество
	for _i in got:
		_queue.append(1)                  # 1 = Type.INGOT (см. resource.gd)
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
	var per: int = G.scrap_yield(bt)
	if per <= 0:
		return false                       # рецепта нет — чанк не наш, пусть едет дальше
	var n: int = maxi(int(item.get("chunk_count")), 0)
	for _i in n * per:
		_queue.append(1)                   # 1 = Type.INGOT
	item.queue_free()
	return true

func _physics_process(delta: float) -> void:
	if _queue.is_empty():
		return
	_emit_t -= delta
	if _emit_t > 0.0:
		return
	_emit_t = EMIT_INTERVAL
	if not _factory_active():
		return                            # вне якоря фабрика стоит — слитки подождут в очереди
	_emit_one()

func _emit_one() -> void:
	if _res_scene == null:
		_queue.clear()
		return
	var item: Node3D = _res_scene.instantiate() as Node3D
	if item == null:
		return
	if "type" in item:
		item.set("type", _queue[0])
	# Предмет обязан быть в дереве до try_receive: приёмник его репарентит (как в storage).
	get_parent().add_child(item)
	item.global_position = global_position
	if push_item(item):
		_queue.remove_at(0)
	else:
		item.queue_free()                 # цепочка занята — попробуем на следующем тике
