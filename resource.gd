# resource_item.gd
extends RigidBody3D

enum Type { ORE, INGOT, COAL }

@export var type: Type = Type.ORE

# Материалы для каждого типа — назначаешь в инспекторе
@export var ore_material: Material
@export var ingot_material: Material

## Вдали от игрока коллизия чанков не прогружена → ресурс проваливался «за окно коллизий»
## в пустоту. Вместо коллизии под каждым (сотни!) — прижимаем ресурс к ПОВЕРХНОСТИ heightmap
## (map.terrain_height_at, дешёвый сэмпл, есть всегда): он ложится на землю и, погасив
## скорость, засыпает — не жрёт физику. freeze НЕ трогаем — коллектор его собирает как обычно.
@export var rest_offset: float = 0.3          # приподнять над поверхностью, чтобы не тонул
var _map_cache: Node = null

func _map() -> Node:
	if _map_cache != null and is_instance_valid(_map_cache):
		return _map_cache
	var scene := get_tree().current_scene
	if scene:
		for c in scene.get_children():
			if c.has_method("terrain_height_at"):
				_map_cache = c
				return _map_cache
	_map_cache = get_node_or_null("/root/Main/map")
	return _map_cache

func _integrate_forces(state: PhysicsDirectBodyState3D) -> void:
	var map := _map()
	if map == null:
		return
	var origin: Vector3 = state.transform.origin
	var h: float = map.terrain_height_at(origin) + rest_offset
	if origin.y < h:                          # опустились до/ниже поверхности — держим на ней
		var t := state.transform
		t.origin.y = h
		state.transform = t
		var v := state.linear_velocity
		if v.y < 0.0:
			v.y = 0.0                         # дальше не проваливаемся
		v.x *= 0.5
		v.z *= 0.5                            # опоры-трения нет — гасим скольжение → уснёт
		state.linear_velocity = v

# Тинт под цвет жилы, из которой выпала руда (ставит resource_node.set_tint).
# Материалы кешируются по цвету (static), чтобы руда одного цвета батчилась одним материалом.
static var _tint_mats: Dictionary = {}
var _tint: Color = Color.WHITE
var _has_tint: bool = false

func _ready() -> void:
	add_to_group("grass_benders")
	_update_visual()

# Красим руду под цвет жилы (вызывает жила при выбросе).
func set_tint(c: Color) -> void:
	_tint = c
	_has_tint = true
	_update_visual()

# Вызывается Processor-ом
func upgrade() -> void:
	match type:
		Type.ORE:
			type = Type.INGOT
		# COAL слитка НЕ имеет — процессор его не переплавляет, уголь остаётся углём.
		# В будущем: INGOT → ALLOY и т.д.
	_update_visual()

func _update_visual() -> void:
	var mesh := get_node_or_null("MeshInstance3D/ResourceMesh")
	if mesh == null:
		return
	# Форма: руда — шар, слиток — примятый (сплющенный) шар внутри внешней сферы.
	# Внешний шар (MeshInstance3D) не трогаем — меняем только внутренний ResourceMesh.
	mesh.scale = Vector3(1.3, 0.3, 1.3) if type == Type.INGOT else Vector3.ONE
	# Уголь всегда тёмный (тинт жилы к нему не применяется).
	if type == Type.COAL:
		mesh.material_override = _coal_material()
		return
	if _has_tint:
		mesh.material_override = _tint_material(_tint)
		return
	match type:
		Type.ORE:
			if ore_material:
				mesh.material_override = ore_material
		Type.INGOT:
			if ingot_material:
				mesh.material_override = ingot_material

func _tint_material(c: Color) -> StandardMaterial3D:
	var key := c.to_rgba32()
	var cached: Variant = _tint_mats.get(key)
	if cached == null:
		var m := StandardMaterial3D.new()
		m.albedo_color = c
		m.emission_enabled = true
		m.emission = c * 0.4
		_tint_mats[key] = m
		cached = m
	return cached

static var _coal_mat: StandardMaterial3D = null
static func _coal_material() -> StandardMaterial3D:
	if _coal_mat == null:
		_coal_mat = StandardMaterial3D.new()
		_coal_mat.albedo_color = Color(0.12, 0.12, 0.14)
		_coal_mat.roughness = 0.95
	return _coal_mat
