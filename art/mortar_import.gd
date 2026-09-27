extends SceneTree
# Turns art/out/mortar.glb (written by art/mortar_model.py) into the mesh the mortar scene uses.
#
#   godot --headless --path . --script res://art/mortar_import.gd
#
# The glb is not imported by the project (art/out has a .gdignore): Godot's importer would build
# its own material with its own filter, and the blocks' look depends on exactly this one - UNSHADED,
# both sides drawn, nearest texels with mipmaps, the same as the atlas material in the other
# weapon scenes. So the glb is read at run time and the mesh is saved with that material on it.
const SRC := "res://art/out/mortar.glb"
const DST := "res://blocks/meshes/mortar_head.tres"
const TEX := "res://objects/mortar_texture.png"

func _init() -> void:
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	if doc.append_from_file(ProjectSettings.globalize_path(SRC), state) != OK:
		push_error("cannot read " + SRC)
		quit(1)
		return
	var scene := doc.generate_scene(state)
	var mi := scene.find_children("*", "MeshInstance3D", true, false)[0] as MeshInstance3D
	var mesh := mi.mesh as ArrayMesh
	var mat := StandardMaterial3D.new()
	mat.resource_name = "mortar"
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_texture = load(TEX)
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST_WITH_MIPMAPS
	mesh.surface_set_material(0, mat)
	mesh.resource_name = "mortar_head"
	var err := ResourceSaver.save(mesh, DST)
	print("saved ", DST, " err ", err, " tris ", mesh.surface_get_array_index_len(0) / 3)
	scene.free()
	quit()
