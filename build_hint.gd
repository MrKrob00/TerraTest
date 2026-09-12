class_name BuildHint
extends Node3D

# БЕЛЫЙ ПРИЗРАК БЛОКА В КЛЕТКЕ — «поставь сюда вот это».
#
# Зачем. Задание может сказать «собери линию», но не может объяснить словами, какой блок в
# какую клетку и каким боком. Схема в тексте этого тоже не делает: игрок читает её, смотрит
# на машину и всё равно ставит наугад. Призрак отвечает на вопрос там, где вопрос возникает —
# прямо на месте, формой самого блока и его поворотом.
#
# Почему копируем МЕШИ, а не ставим сцену блока. Сцена блока — это физическое тело со
# скриптом, зонами и сигналами: коллектор начнёт собирать, турель наводиться, а карта машины
# посчитает клетку занятой. Призраку нужна только форма, поэтому берём из сцены меши и
# выбрасываем всё остальное; сама сцена в дерево не попадает, и её _ready не срабатывает.
#
# Живёт призрак ПОД УЗЛОМ blocks машины, как настоящий блок: значит, едет и поворачивается
# вместе с ней, и держать его положение в коде не надо.

## Цвет и прозрачность: белый, потому что он не «часть машины», а разметка. Пульсация нужна,
## чтобы призрак читался и на светлом рельефе, и на тёмном корпусе.
const COL := Color(1.0, 1.0, 1.0)
const ALPHA_MIN := 0.16
const ALPHA_MAX := 0.42
const PULSE_PERIOD := 1.6
## Как часто спрашиваем карту, не поставили ли уже. Раз в кадр незачем: клетку заполняют руками.
const CHECK_PERIOD := 0.25

var cell := Vector3i.ZERO
var block_type: int = 0

var _map: Node = null                  # узел blocks машины (он же родитель)
var _mat: StandardMaterial3D = null
var _t: float = 0.0
var _check: float = 0.0

## Поставить призрак в клетку машины. rot — тот же поворот, каким блок встанет по-настоящему.
static func create(blocks_node: Node, cell_pos: Vector3i, bt: int, rot: Vector3 = Vector3.ZERO) -> BuildHint:
	if blocks_node == null or not is_instance_valid(blocks_node):
		return null
	var h := BuildHint.new()
	h.cell = cell_pos
	h.block_type = bt
	h._map = blocks_node
	blocks_node.add_child(h)
	# Та же формула, по которой blocks.gd ставит настоящий блок: сетка 11³ со сдвигом на центр.
	h.position = Vector3(float(cell_pos.x - 5), float(cell_pos.y - 5), float(cell_pos.z - 5))
	h.rotation = rot
	h._build_ghost()
	return h

func _build_ghost() -> void:
	_mat = StandardMaterial3D.new()
	_mat.albedo_color = Color(COL.r, COL.g, COL.b, ALPHA_MIN)
	_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_mat.no_depth_test = true          # призрак виден и когда его закрывает корпус машины
	var scene: PackedScene = G.get_scene(block_type)
	if scene == null:
		return
	var src: Node = scene.instantiate()
	_copy_meshes(src, self, Transform3D.IDENTITY)
	src.free()                         # орфан: в дерево не попадал, _ready не отработал
	if get_child_count() == 0:
		# У блока нет меша (или сцена его не отдала) — рисуем куб по размеру клетки, чтобы
		# подсказка не исчезала молча.
		var mi := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3.ONE * 0.9
		mi.mesh = bm
		mi.material_override = _mat
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(mi)

## Рекурсивно переносим ВИДИМУЮ часть блока: каждый MeshInstance3D со своим положением
## относительно корня сцены. Всё остальное (тела, коллизии, зоны, скрипты) не трогаем.
func _copy_meshes(node: Node, dst: Node3D, xform: Transform3D) -> void:
	var here := xform
	if node is Node3D and node.get_parent() != null:
		here = xform * (node as Node3D).transform
	if node is MeshInstance3D and (node as MeshInstance3D).mesh != null:
		var mi := MeshInstance3D.new()
		mi.mesh = (node as MeshInstance3D).mesh
		mi.transform = here
		mi.material_override = _mat
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		dst.add_child(mi)
	for c in node.get_children():
		_copy_meshes(c, dst, here)

func _process(delta: float) -> void:
	_t += delta
	if _mat != null:
		var k: float = 0.5 + 0.5 * sin(_t * TAU / PULSE_PERIOD)
		_mat.albedo_color.a = lerpf(ALPHA_MIN, ALPHA_MAX, k)
	_check -= delta
	if _check > 0.0:
		return
	_check = CHECK_PERIOD
	if _map == null or not is_instance_valid(_map) or not _map.has_method("get_block"):
		queue_free()
		return
	# Поставили ЧТО НАДО — подсказка своё отработала. Поставили что-то другое — остаёмся:
	# игрок ошибся клеткой, и убирать разметку в этот момент значит бросить его без ответа.
	if int(_map.get_block(cell.x, cell.y, cell.z)) == block_type:
		queue_free()

## Мировая точка призрака — для пальца наставника.
func target_position() -> Vector3:
	return global_position
