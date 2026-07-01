# resource_item.gd
extends RigidBody3D

enum Type { ORE, INGOT }

@export var type: Type = Type.ORE

# Материалы для каждого типа — назначаешь в инспекторе
@export var ore_material: Material
@export var ingot_material: Material

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
		# В будущем: INGOT → ALLOY и т.д.
	_update_visual()

func _update_visual() -> void:
	var mesh = get_node_or_null("MeshInstance3D/ResourceMesh")
	if mesh == null:
		return
	# Форма: руда — шар, слиток — примятый (сплющенный) шар внутри внешней сферы.
	# Внешний шар (MeshInstance3D) не трогаем — меняем только внутренний ResourceMesh.
	mesh.scale = Vector3(1.3, 0.3, 1.3) if type == Type.INGOT else Vector3.ONE
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
	var cached = _tint_mats.get(key)
	if cached == null:
		var m := StandardMaterial3D.new()
		m.albedo_color = c
		m.emission_enabled = true
		m.emission = c * 0.4
		_tint_mats[key] = m
		cached = m
	return cached
