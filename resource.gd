# resource_item.gd
extends RigidBody3D

enum Type { ORE, INGOT }

@export var type: Type = Type.ORE

# Материалы для каждого типа — назначаешь в инспекторе
@export var ore_material: Material
@export var ingot_material: Material

func _ready() -> void:
	add_to_group("grass_benders")
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
	match type:
		Type.ORE:
			if ore_material:
				mesh.material_override = ore_material
		Type.INGOT:
			if ingot_material:
				mesh.material_override = ingot_material
