extends SceneTree
# Turns art/out/<name>.glb (written by art/turret_heads.py) into the mesh a weapon scene uses.
#
#   godot --headless --path . --script res://art/turret_import.gd -- mortar shotgun pound_cannon
#
# The glb is not imported by the project (art/out has a .gdignore): Godot's importer would build
# its own material with its own filter, and the blocks' look depends on exactly this one - UNSHADED,
# both sides drawn, nearest texels with mipmaps, the same as the atlas material in the other
# weapon scenes. So the glb is read at run time and the mesh is saved with that material on it.
func _init() -> void:
	var names := OS.get_cmdline_user_args()
	if names.is_empty():
		names = PackedStringArray(["mortar", "shotgun", "pound_cannon"])
	for n in names:
		_convert(n)
	quit()

func _convert(n: String) -> void:
	var src := "res://art/out/%s.glb" % n
	var dst := "res://blocks/meshes/%s_head.tres" % n
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	if doc.append_from_file(ProjectSettings.globalize_path(src), state) != OK:
		push_error("cannot read " + src)
		return
	var scene := doc.generate_scene(state)
	var mi := scene.find_children("*", "MeshInstance3D", true, false)[0] as MeshInstance3D
	var mesh := mi.mesh as ArrayMesh
	var mat := StandardMaterial3D.new()
	mat.resource_name = n
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_texture = load("res://objects/%s_texture.png" % n)
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST_WITH_MIPMAPS
	mesh.surface_set_material(0, mat)
	mesh.resource_name = n + "_head"
	var err := ResourceSaver.save(mesh, dst)
	print("saved ", dst, " err ", err, " tris ", mesh.surface_get_array_index_len(0) / 3)
	scene.free()
