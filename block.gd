extends VehicleBlock

# Меш блока корпуса берётся у генератора, а не из objects/GSO*.res. Так он приходит вместе
# со своим материалом (текстура в памяти, фильтр nearest), и настраивать в редакторе нечего.
# Ставим в _ready, а не ссылкой в сцене: тогда правка block_mesh.gd сразу видна в игре и
# не нужно ни печь .res, ни держать в сцене ссылку на сгенерированный ресурс.
func _ready() -> void:
	super._ready()
	var mi: MeshInstance3D = get_node_or_null("Block") as MeshInstance3D
	if mi != null:
		mi.mesh = GeneratedBlock.block_mesh()
