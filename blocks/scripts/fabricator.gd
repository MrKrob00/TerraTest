extends FactoryBlock

# ФАБРИКАТОР 2×2×2. Копит ДВА разных материала и, набрав рецепт, штампует готовый блок —
# тот вылетает в мир с матричным эффектом появления, как награда.
#
# Два входа различаются НЕ гранью, а материалом: первый пришедший вид занимает слот A,
# первый ОТЛИЧНЫЙ от него — слот B. Так конвейеры можно свести хоть в одну грань, и рецепт
# всё равно соберётся правильно.
#
# Единственный рецепт пока такой: 3 слитка одного вида + 3 другого = обычный блок 1³.
# Добавлять новые — строкой в RECIPES; ключ материала даёт resource.kind_key().

## Сколько единиц КАЖДОГО из двух материалов нужно на одну сборку.
@export var per_kind: int = 3
## Что штампуем (значение G.Block). Пока рецепт один, поэтому и выход один.
## Тип НЕ G.Block: enum живёт в автолоаде, в @export его не подставить.
@export var output_block: int = 3        # G.Block.BLOCK
## Пауза сборки, секунд.
@export var craft_time: float = 2.5
## Принимаем только слитки: руду сперва в переработчик.
@export var require_ingot: bool = true

var _kind_a: String = ""
var _kind_b: String = ""
var _count_a: int = 0
var _count_b: int = 0
var _crafting: bool = false

# Фабрикатор ничего не держит в слоте: ресурс сразу засчитывается и исчезает, иначе на
# каждую из шести единиц пришлось бы гонять анимацию и ждать освобождения.
func try_receive(item: Node3D) -> bool:
	if not _factory_active() or _crafting:
		return false
	if item == null or not is_instance_valid(item):
		return false
	if require_ingot and "type" in item and int(item.get("type")) != 1:
		return false                      # 1 = Type.INGOT (см. resource.gd)
	var kind: String = item.kind_key() if item.has_method("kind_key") else str(item.get("type"))

	if kind == _kind_a and _count_a < per_kind:
		_count_a += 1
	elif kind == _kind_b and _count_b < per_kind:
		_count_b += 1
	elif _kind_a == "":
		_kind_a = kind
		_count_a = 1
	elif _kind_b == "" and kind != _kind_a:
		_kind_b = kind
		_count_b = 1
	else:
		return false                      # оба слота заняты другими видами или уже полны
	item.queue_free()
	if _count_a >= per_kind and _count_b >= per_kind:
		_start_craft()
	return true

func _start_craft() -> void:
	_crafting = true
	await get_tree().create_timer(craft_time).timeout
	if not is_instance_valid(self):
		return
	_count_a = 0
	_count_b = 0
	_kind_a = ""
	_kind_b = ""
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
