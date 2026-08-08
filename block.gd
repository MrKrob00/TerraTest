extends VehicleBlock

# Меш блока — обычный ассет res://blocks/armor.blockgen: плагин addons/blockgen импортирует
# его в ресурс Mesh, который видно в файловой панели и можно перетащить в поле Mesh любого
# MeshInstance3D. Здесь он просто грузится по пути.
#
# Если плагин выключен и ассета нет, меш строится на лету тем же BlockBuilder: игра не
# должна ломаться из-за настроек редактора. Меш общий на все экземпляры — блоков десятки.
const MESH_PATH: String = "res://blocks/armor.blockgen"

static var _mesh: Mesh = null

func _ready() -> void:
	super._ready()
	var mi: MeshInstance3D = get_node_or_null("Block") as MeshInstance3D
	if mi != null:
		mi.mesh = _block_mesh()

static func _block_mesh() -> Mesh:
	if _mesh == null:
		if ResourceLoader.exists(MESH_PATH):
			_mesh = load(MESH_PATH) as Mesh
		if _mesh == null:
			_mesh = BlockBuilder.from_file(MESH_PATH)
	return _mesh
