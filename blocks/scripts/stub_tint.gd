extends RefCounted
## A STUB BLOCK'S TINT (Aero and Stryx have no models yet - G.STUB_BASE): every model part of the
## scene draws with a copy of its mesh whose surface materials are copies of the scene's own, their
## colour times the faction's (`G.FACTIONS[f]["tint"]`). The MESH is swapped, not the material
## overridden: the artist's plates carry two materials on one mesh, and an override has one. One copy
## per source mesh and faction, kept for the run, so a stub's parts still batch (MachineBatch keys its
## groups by mesh and material) and are lit like Falsus's (`MachineBatch.lit_material` reads the
## mesh's own material). Called from VehicleBlock on SCENE_INSTANTIATED - before any tree, so the
## portrait studio, which strips scripts after instancing, gets the tint too.

static var _meshes: Dictionary = {}
static var _mats: Dictionary = {}

static func apply(root: Node, faction: String) -> void:
	var f: Dictionary = G.FACTIONS.get(faction, {})
	if not f.has("tint"):
		return
	_walk(root, root, f["tint"] as Color, faction)

static func _walk(n: Node, root: Node, tint: Color, faction: String) -> void:
	for c in n.get_children():
		var mi := c as MeshInstance3D
		if mi != null and mi.owner == root and mi.mesh is ArrayMesh and mi.material_override == null:
			mi.mesh = _tinted_mesh(mi.mesh as ArrayMesh, tint, faction)
		_walk(c, root, tint, faction)

static func _tinted_mesh(src: ArrayMesh, tint: Color, faction: String) -> ArrayMesh:
	var key := "%d|%s" % [src.get_instance_id(), faction]
	if _meshes.has(key):
		return _meshes[key]
	var m: ArrayMesh = src.duplicate()
	for i in m.get_surface_count():
		var sm := m.surface_get_material(i) as StandardMaterial3D
		if sm != null:
			m.surface_set_material(i, _tinted_mat(sm, tint, faction))
	_meshes[key] = m
	return m

static func _tinted_mat(src: StandardMaterial3D, tint: Color, faction: String) -> StandardMaterial3D:
	var key := "%d|%s" % [src.get_instance_id(), faction]
	if not _mats.has(key):
		var m: StandardMaterial3D = src.duplicate()
		m.albedo_color = src.albedo_color * tint
		_mats[key] = m
	return _mats[key]
