extends SceneTree
# Turns art/out/<name>.glb (written by art/turret_heads.py, emitter_models.py or hull_models.py) into the
# meshes a block scene uses: every node of the glb becomes blocks/meshes/<node>.tres, so a turret
# head (one node, "<name>_head") and a many-part block (shield_body, shield_cap, ...) go one way.
#
#   godot --headless --path . --script res://art/turret_import.gd -- mortar shield regen
#
# The glb is not imported by the project (art/out has a .gdignore): Godot's importer would build
# its own material with its own filter, and the blocks' look depends on exactly this one - UNSHADED,
# both sides drawn, nearest texels with mipmaps, the same as the atlas material in the other
# weapon scenes. So the glb is read at run time and the mesh is saved with that material on it.
func _init() -> void:
	var names := OS.get_cmdline_user_args()
	if names.is_empty():
		names = PackedStringArray(["mortar", "shotgun", "pound_cannon", "shield", "regen", "radar", "hull"])
	for n in names:
		_convert(n)
	quit()

func _convert(n: String) -> void:
	var src := "res://art/out/%s.glb" % n
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	if doc.append_from_file(ProjectSettings.globalize_path(src), state) != OK:
		push_error("cannot read " + src)
		return
	var scene := doc.generate_scene(state)
	var mat := StandardMaterial3D.new()
	mat.resource_name = n
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	# A part set with no texture of its own (the hull) sits on the shared atlas, like the frame block.
	var tex := "res://objects/%s_texture.png" % n
	if not ResourceLoader.exists(tex):
		tex = "res://objects/Assets_main_texture_new.png"
		mat.resource_name = "main"
	mat.albedo_texture = load(tex)
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST_WITH_MIPMAPS
	for node in scene.find_children("*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		var mesh := mi.mesh as ArrayMesh
		mesh.surface_set_material(0, mat)
		mesh.resource_name = String(mi.name)
		var dst := "res://blocks/meshes/%s.tres" % String(mi.name)
		var err := ResourceSaver.save(mesh, dst)
		print("saved ", dst, " err ", err, " tris ", mesh.surface_get_array_index_len(0) / 3)
	scene.free()
