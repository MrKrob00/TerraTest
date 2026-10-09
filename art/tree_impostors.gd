extends SceneTree
# THE FAR TREES' PICTURES (far_trees.gd): every tree model photographed from far_trees.VIEWS sides,
# side on, through the trees' OWN shader (resources/resource.gdshader, as the tree MultiMeshes draw
# them), into one atlas - a row per kind in TREE_* order, a column per view, view k with the camera at
# angle TAU * k / VIEWS round the tree in its own frame (atan2(x, z), the card's convention).
#
# A picture needs the REAL driver (CLAUDE.md §3), and the bake runs on a copy:
#   xvfb-run -a -s "-screen 0 640x480x24" godot --path <copy> --rendering-driver opengl3 \
#       --script res://art/tree_impostors.gd
# then copy resources/far_trees.png back. Re-run it whenever a tree model changes.
#
# Rendered at OVER times the tile and boxed down, with the colour spread into the transparent pixels
# first (`fix_alpha_edges`): the card cuts at alpha 0.5, and a resize or a mip level that mixed in the
# black around the tree drew a dark rim round every far tree.

const OVER := 4
const OUT := "res://resources/far_trees.png"

func _initialize() -> void:
	await process_frame
	var far = load("res://far_trees.gd")
	# no haze in the studio: the card takes the world's own haze where it stands
	RenderingServer.global_shader_parameter_set("haze_range", Vector4(1.0e6, 2.0e6, 0.0, 0.0))
	var tile: Vector2i = far.TILE
	var vp := SubViewport.new()
	vp.size = tile * OVER
	vp.transparent_bg = true
	vp.msaa_3d = Viewport.MSAA_DISABLED
	vp.own_world_3d = true
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	get_root().add_child(vp)
	var cam := Camera3D.new()
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.keep_aspect = Camera3D.KEEP_HEIGHT
	vp.add_child(cam)
	cam.current = true
	var mi := MeshInstance3D.new()
	vp.add_child(mi)
	var mat := ShaderMaterial.new()
	mat.shader = load("res://resources/resource.gdshader")
	mat.set_shader_parameter("fells", true)
	mi.material_override = mat
	var models: Array = far.MODELS
	var views: int = far.VIEWS
	var atlas := Image.create(tile.x * views, tile.y * models.size(), false, Image.FORMAT_RGBA8)
	for k in models.size():
		var mesh: Mesh = load(models[k])
		mi.mesh = mesh
		var t: Vector3 = far.tile_for(mesh)
		cam.size = t.y
		var centre := Vector3(0.0, t.z + t.y * 0.5, 0.0)
		for view in views:
			var a: float = TAU * float(view) / float(views)
			cam.position = centre + Vector3(sin(a), 0.0, cos(a)) * 60.0
			cam.look_at(centre, Vector3.UP)
			for i in 3:
				await RenderingServer.frame_post_draw
			var img: Image = vp.get_texture().get_image()
			img.convert(Image.FORMAT_RGBA8)
			img.fix_alpha_edges()
			img.resize(tile.x, tile.y, Image.INTERPOLATE_LANCZOS)
			atlas.blit_rect(img, Rect2i(Vector2i.ZERO, tile), Vector2i(view * tile.x, k * tile.y))
	atlas.fix_alpha_edges()
	atlas.save_png(ProjectSettings.globalize_path(OUT))
	print("far trees: ", OUT, " ", atlas.get_size())
	quit()
