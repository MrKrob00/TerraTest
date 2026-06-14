# grass_system.gd
extends Node3D

@export var map_node: StaticBody3D
@export var max_benders: int = 64
@export var update_threshold: float = 0.3

var _map_material: ShaderMaterial = null
var _initialized: bool = false
var _benders: Array = []
var _cached_positions: Array[Vector2] = []

func _ready() -> void:
	await get_tree().process_frame
	_benders = get_tree().get_nodes_in_group("grass_benders")
	_setup()

func _setup() -> void:
	if not map_node:
		push_error("GrassSystem: map_node не назначен!")
		return

	_map_material = _find_map_material()
	if not _map_material:
		push_error("GrassSystem: материал карты не найден!")
		return

	_initialized = true

func _find_map_material() -> ShaderMaterial:
	for child in map_node.get_children():
		if child is MeshInstance3D:
			var mat = child.get_surface_override_material(0)
			if mat is ShaderMaterial:
				return mat as ShaderMaterial
			if child.mesh:
				mat = child.mesh.surface_get_material(0)
				if mat is ShaderMaterial:
					return mat as ShaderMaterial
	return null

func _has_moved() -> bool:
	if _benders.size() != _cached_positions.size():
		return true
	for i in _benders.size():
		var cur = Vector2(_benders[i].global_position.x, _benders[i].global_position.z)
		if cur.distance_to(_cached_positions[i]) > update_threshold:
			return true
	return false

func _update_benders() -> void:
	_benders = _benders.filter(func(t): return is_instance_valid(t))
	if not _has_moved():
		return

	var positions: Array[Vector2] = []
	_cached_positions.clear()

	for b in _benders:
		if positions.size() >= max_benders:
			break
		var xz = Vector2(b.global_position.x, b.global_position.z)
		positions.append(xz)
		_cached_positions.append(xz)

	# Без заполнения нулями — шейдер читает только до bender_count
	_map_material.set_shader_parameter("bender_count", positions.size())
	_map_material.set_shader_parameter("bender_positions", positions)

var _check_counter: int = 0
const CHECK_EVERY: int = 3  # перевіряємо кожен 3й кадр

func _process(_delta: float) -> void:
	if not _initialized:
		return
	_check_counter += 1
	if _check_counter >= CHECK_EVERY:
		_check_counter = 0
		_update_benders()
