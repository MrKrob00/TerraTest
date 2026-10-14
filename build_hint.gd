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
var _conn_mask: int = 63               # the new block's own attach faces (its scene's connect_faces)
var _strict_yaw: bool = false
var _mat: StandardMaterial3D = null
var _t: float = 0.0
var _check: float = 0.0

## Поставить призрак в клетку машины. rot — тот же поворот, каким блок встанет по-настоящему.
## strict_yaw: the ghost is done only when the block went in TURNED as drawn, not merely when the
## cell holds that type. Opt-in, because for some blocks the yaw does not matter (a panel) or the
## builder picks it by the face it attaches to (a wheel) — a strict ghost would hang over a block
## that works. For a belt or a processor the yaw IS the function: turned wrong it links to nothing,
## and a type-only ghost vanished anyway, leaving the player with no hint at all.
static func create(blocks_node: Node, cell_pos: Vector3i, bt: int, rot: Vector3 = Vector3.ZERO,
		strict_yaw: bool = false) -> BuildHint:
	if blocks_node == null or not is_instance_valid(blocks_node):
		return null
	var h := BuildHint.new()
	h.cell = cell_pos
	h.block_type = bt
	h._strict_yaw = strict_yaw
	h._map = blocks_node
	blocks_node.add_child(h)
	# The formula blocks.gd places a real block by: the cell less the centre cell (5).
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
	if "connect_faces" in src:
		_conn_mask = int(src.get("connect_faces"))
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
	if satisfied_by(_map, cell, block_type, rotation.y if _strict_yaw else NAN):
		queue_free()

## One answer for the ghost and for whoever decides whether to draw it (quest_arcs._show_plan_on).
## NAN yaw means "any turn will do".
static func satisfied_by(bm: Node, c: Vector3i, bt: int, yaw: float) -> bool:
	if bm == null or not bm.has_method("get_block") or int(bm.get_block(c.x, c.y, c.z)) != bt:
		return false
	# THE PLAN'S CELL HAS TO BE THE BLOCK'S ANCHOR. get_block answers for every cell a big block
	# covers, so a processor anchored a cell off still "stood" on the planned cell: the ghost and
	# the finger went out while its ports faced the wrong belts and the stage never closed.
	if bm.has_method("anchor_of") and bm.anchor_of(c) != c:
		return false
	if is_nan(yaw) or not bm.has_method("yaw_at"):
		return true
	return absf(angle_difference(float(bm.yaw_at(c.x, c.y, c.z)), yaw)) < 0.05

## CAN THE BLOCK GO HERE NOW: one of the cell's six neighbours is already taken on the machine.
## A finger on a cell with nothing beside it asks for a block that cannot be placed yet - a wheel
## before the hull block it hangs on, a receiver at the far end of a line with no belt there yet
## (the player's report). Neighbours by the grid, not by attach faces: the plan is drawn to join.
const _NEIGH := [Vector3i(1, 0, 0), Vector3i(-1, 0, 0), Vector3i(0, 1, 0), Vector3i(0, -1, 0),
		Vector3i(0, 0, 1), Vector3i(0, 0, -1)]
func reachable() -> bool:
	if _map == null or not is_instance_valid(_map) or not ("map" in _map):
		return true
	var m: Dictionary = _map.get("map")
	for d in _NEIGH:
		if m.has(cell + d):
			return true
	return false

## The open ghost to point at among `hints`: a REACHABLE one, earliest in the plan's own order
## (`hints` is in plan order - the hull before the wheels on it, the belt nearest the seller first),
## of type `want` when given. None reachable - the nearest to `from`, as before. One answer for the
## tutorial and the quest arcs.
static func pick(hints: Array, want: int, from: Vector3) -> Variant:
	for h in hints:
		if is_instance_valid(h) and (want < 0 or (h as BuildHint).block_type == want) and (h as BuildHint).reachable():
			return h
	var best = null
	var best_d: float = INF
	for h in hints:
		if not is_instance_valid(h) or (want >= 0 and (h as BuildHint).block_type != want):
			continue
		var d: float = from.distance_squared_to((h as Node3D).global_position)
		if d < best_d:
			best_d = d
			best = h
	return best

## Мировая точка призрака — для пальца наставника.
func target_position() -> Vector3:
	return global_position

## WHERE THE FINGER POINTS: THE FACE THE BLOCK IS BOLTED ONTO, not the middle of its cell (the
## player: "it points at the middle of the cell, and a tap there misses"). Placing is a tap on a
## face of a block ALREADY ON THE MACHINE; the middle of an empty cell is air, and a tap there goes
## through to whatever lies behind. So: the faces between the ghost's cells and the taken cells
## beside them, kept only where the neighbour joins on that face and the new block's own mask
## (turned by the ghost's rotation) joins back; of those, the side facing the camera, then the one
## with the most cells touching; the point is the middle of that contact patch, which is also where
## `attach_candidates` lines a big block's middle up with the tap. Nothing beside it yet - the
## ghost's middle, as before.
func tap_point(eye: Vector3) -> Vector3:
	if _map == null or not is_instance_valid(_map) or not ("map" in _map) \
			or not _map.has_method("_block_footprint"):
		return global_position
	var m: Dictionary = _map.get("map")
	var cells: Array = _map._block_footprint(block_type, cell.x, cell.y, cell.z, rotation)
	var own := {}
	for c in cells:
		own[c] = true
	var b := Basis.from_euler(rotation)
	var mine: Dictionary = {}
	for i in 6:
		if _conn_mask & (1 << i):
			mine[Vector3i((b * VehicleBlock.FACE_VECS[i]).round())] = true
	var best_pt: Vector3 = global_position
	var best_score: float = -INF
	for d in _NEIGH:
		var dir: Vector3i = d
		if not mine.is_empty() and not mine.has(dir):
			continue
		var sum := Vector3.ZERO
		var n: int = 0
		for c in cells:
			var nb: Vector3i = (c as Vector3i) + dir
			if own.has(nb) or not m.has(nb):
				continue
			if _map.has_method("find_block") and _map.has_method("anchor_of"):
				var blk = _map.find_block(nb.x, nb.y, nb.z)
				if is_instance_valid(blk) and blk is VehicleBlock \
						and not (blk as VehicleBlock).connects_at(nb - _map.anchor_of(nb), -dir):
					continue
			sum += Vector3(c as Vector3i) + Vector3(dir) * 0.5
			n += 1
		if n == 0:
			continue
		var local: Vector3 = sum / float(n) - Vector3(5.0, 5.0, 5.0)
		var pt: Vector3 = (_map as Node3D).global_transform * local
		# the neighbour's face looks back at the ghost (-dir); seen from the eye or not
		var normal: Vector3 = ((_map as Node3D).global_basis * -Vector3(dir)).normalized()
		var seen: bool = normal.dot(eye - pt) > 0.0
		var score: float = (100.0 if seen else 0.0) + float(n)
		if score > best_score:
			best_score = score
			best_pt = pt
	return best_pt
