# grass_system.gd
extends Node3D

@export var map_node: StaticBody3D
@export var max_benders: int = 64
@export var update_threshold: float = 0.3
## A bender only presses grass while it is within this height of the terrain. Objects
## higher up (e.g. blocks riding on a vehicle, not touching the grass) are ignored.
@export var ground_touch_height: float = 2.0

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

	# Prefer the map's set_grass_benders() (targets the real LOD0 grass material). Only
	# fall back to grabbing a material directly if the map doesn't expose it.
	if not map_node.has_method("set_grass_benders"):
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

func _positions_changed(positions: Array[Vector2]) -> bool:
	if positions.size() != _cached_positions.size():
		return true
	for i in positions.size():
		if positions[i].distance_to(_cached_positions[i]) > update_threshold:
			return true
	return false

func _update_benders() -> void:
	_benders = _benders.filter(func(t): return is_instance_valid(t))

	var has_map := map_node != null and map_node.has_method("terrain_height_at")
	var positions: Array[Vector2] = []
	for b in _benders:
		if positions.size() >= max_benders:
			break
		var bp: Vector3 = b.global_position
		# Skip benders that aren't actually on the grass (too high above the terrain).
		if has_map and bp.y - map_node.terrain_height_at(bp) > ground_touch_height:
			continue
		positions.append(Vector2(bp.x, bp.z))

	if not _positions_changed(positions):
		return
	_cached_positions = positions

	# Без заполнения нулями — шейдер читає тільки до bender_count
	if map_node.has_method("set_grass_benders"):
		map_node.set_grass_benders(positions, positions.size())
	elif _map_material:
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
