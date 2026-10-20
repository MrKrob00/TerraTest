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

const EJECT_CLEAR: float = 0.9      # the new block appears this far past the pipe's mouth
const EJECT_PUSH: float = 3.0       # m/s along the pipe
const EJECT_LIFT: float = 1.5       # m/s up

func _ready() -> void:
	super._ready()
	_need = G.block_recipe(output_block).duplicate()   # копия: словарь рецептов общий на всех

# A belt facing us holds a recipe material while our intake has room for it, instead of sending it past.
func wants(item: Node3D) -> bool:
	if not _factory_active() or _need.is_empty() or not is_instance_valid(item):
		return false
	var kind: String = item.kind_key() if item.has_method("kind_key") else ""
	return _need.has(kind) and int(_have.get(kind, 0)) < _cap(kind)

# Фабрикатор ничего не держит в слоте: ресурс сразу засчитывается и исчезает, иначе на
# каждую из шести единиц пришлось бы гонять анимацию и ждать освобождения.
func try_receive(item: Node3D) -> bool:
	if not _factory_active() or _need.is_empty():
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
	if have >= _cap(kind):
		return false                      # этого материала уже достаточно
	_have[kind] = have + 1
	item.queue_free()
	if not _crafting and _recipe_full():
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
			_have[k] = clampi(int(_have[k]), 0, _cap(k))
		else:
			_have.erase(k)

func _recipe_full() -> bool:
	for k in _need:
		if int(_have.get(k, 0)) < int(_need[k]):
			return false
	return true

## THE INTAKE HOLDS TWO RECIPES' WORTH OF EACH INPUT. It used to hold exactly one and refuse
## everything while crafting: the belt that feeds the machine head-on then got a "no" for a third
## ingot of a kind already counted, waited for this machine's slot_freed - and the fabricator never
## sent one, the plant only at the end of a craft that could not start, because the other ingot was
## queued BEHIND the refused one. So the first craft ran and the line stood for good after it.
const BUFFER_RECIPES := 2

func _cap(kind) -> int:
	return int(_need.get(kind, 0)) * BUFFER_RECIPES

func _start_craft() -> void:
	_crafting = true
	# The recipe is taken out at the START: whatever arrives during the craft fills the next one.
	for k in _need:
		_have[k] = int(_have.get(k, 0)) - int(_need[k])
	slot_freed.emit()                  # room in the intake: a belt waiting on us offers again
	await get_tree().create_timer(craft_time).timeout
	if not is_instance_valid(self):
		return
	_crafting = false
	_eject_block()
	slot_freed.emit()
	if _factory_active() and _recipe_full():
		_start_craft()                  # the next recipe is already inside

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
	# OUT OF THE PIPE ON THE ROOF (marker `pipe_mouth`, facing its -Z): the player's design - the
	# block is spat into the world, not handed to a belt.
	var mouth := get_node_or_null("pipe_mouth") as Node3D
	var dir: Vector3 = -mouth.global_basis.z if mouth != null else _eject_dir()
	var from: Vector3 = mouth.global_position if mouth != null else global_position
	inst.global_position = from + dir * EJECT_CLEAR
	if inst is RigidBody3D:
		var rb := inst as RigidBody3D
		rb.freeze = false
		rb.sleeping = false
		rb.apply_central_impulse((dir * EJECT_PUSH + Vector3.UP * EJECT_LIFT) * rb.mass)
	BlockFX.play(inst, false)

# Куда выбрасывать: наружу по грани вывода. Граней несколько (противоположная сторона
# 2×2) — берём первую, направление у них общее.
func _eject_dir() -> Vector3:
	var dirs: Array = face_dirs(output_faces)
	if dirs.is_empty():
		return -global_transform.basis.z
	var d: Vector3i = dirs[0]
	return Vector3(d.x, d.y, d.z).normalized()
