extends FactoryBlock

# ФАБРИКАТОР 2×2×2. Копит ДВА разных материала и, набрав рецепт, штампует готовый блок —
# тот вылетает в мир с матричным эффектом появления, как награда.
#
# Два входа различаются НЕ гранью, а материалом: первый пришедший вид занимает слот A,
# первый ОТЛИЧНЫЙ от него — слот B. Так конвейеры можно свести хоть в одну грань, и рецепт
# всё равно соберётся правильно. Отсюда же и правило рецептов: ровно два разных материала,
# третьему тут просто негде встать (см. G.BLOCK_RECIPE).
#
# Что и из чего — НЕ здесь, а в G.BLOCK_RECIPE: тот же словарь читает Scrapper, чтобы вернуть
# половину. Держать цену сборки в двух местах значит однажды их разойтись.

## Что штампуем (значение G.Block). Тип НЕ G.Block: enum живёт в автолоаде, в @export его
## не подставить. Рецепт подтягивается по этому номеру сам.
@export var output_block: int = 3        # G.Block.BLOCK
## Пауза сборки, секунд.
@export var craft_time: float = 2.5

var _need: Dictionary = {}               # ключ материала → сколько надо (копия рецепта)
var _have: Dictionary = {}               # ключ материала → сколько уже лежит
var _crafting: bool = false

func _ready() -> void:
	super._ready()
	_need = G.block_recipe(output_block).duplicate()   # копия: словарь рецептов общий на всех

# Фабрикатор ничего не держит в слоте: ресурс сразу засчитывается и исчезает, иначе на
# каждую из шести единиц пришлось бы гонять анимацию и ждать освобождения.
func try_receive(item: Node3D) -> bool:
	if not _factory_active() or _crafting or _need.is_empty():
		return false
	if item == null or not is_instance_valid(item):
		return false
	var kind: String = item.kind_key() if item.has_method("kind_key") else ""
	# Материал не из рецепта не принимаем ВОВСЕ — и это заодно отсекает руду: рецепты просят
	# слитки ("m0"), а у руды ключ другой ("ore0"). Отдельной проверки «только слитки» больше
	# не нужно, правило целиком живёт в рецепте.
	if not _need.has(kind):
		return false
	var have: int = int(_have.get(kind, 0))
	if have >= int(_need[kind]):
		return false                      # этого материала уже достаточно
	_have[kind] = have + 1
	item.queue_free()
	if _recipe_full():
		_start_craft()
	return true

## Продукт сменили (см. blocks.set_factory_output) — перечитываем рецепт. Уже набранное НЕ
## выбрасываем: материал того же вида, который нужен и новому рецепту, остаётся зачтённым, а
## лишнее подрезается по новой норме. Обнулять всё было бы проще, но это молча съело бы
## ресурсы, которые игрок уже отправил в цепочку.
func reload_recipe() -> void:
	_need = G.block_recipe(output_block).duplicate()
	for k in _have.keys():
		if _need.has(k):
			_have[k] = mini(int(_have[k]), int(_need[k]))
		else:
			_have.erase(k)

func _recipe_full() -> bool:
	for k in _need:
		if int(_have.get(k, 0)) < int(_need[k]):
			return false
	return true

func _start_craft() -> void:
	_crafting = true
	await get_tree().create_timer(craft_time).timeout
	if not is_instance_valid(self):
		return
	_have.clear()
	_crafting = false
	_eject_block()

# Готовый блок появляется В МИРЕ рядом с фабрикатором — подобрать его игрок должен сам,
# как и любой трофей. Матричный эффект тот же, что при спавне блока в руке.
func _eject_block() -> void:
	var scene: PackedScene = G.get_scene(output_block)
	var objects: Node = get_node_or_null("/root/Main/objects")
	if scene == null or objects == null:
		return
	var inst: Node3D = scene.instantiate() as Node3D
	if inst == null:
		return
	objects.add_child(inst)
	inst.global_position = global_position + _eject_dir() * 1.6 + Vector3.UP * 0.6
	if inst is RigidBody3D:
		var rb := inst as RigidBody3D
		rb.freeze = false
		rb.sleeping = false
		rb.apply_central_impulse((_eject_dir() * 2.0 + Vector3.UP * 2.5) * rb.mass)
	BlockFX.play(inst, false)

# Куда выбрасывать: наружу по грани вывода. Граней несколько (противоположная сторона
# 2×2) — берём первую, направление у них общее.
func _eject_dir() -> Vector3:
	var dirs: Array = face_dirs(output_faces)
	if dirs.is_empty():
		return -global_transform.basis.z
	var d: Vector3i = dirs[0]
	return Vector3(d.x, d.y, d.z).normalized()
