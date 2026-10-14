extends Node3D
## WHERE THE PLAYER FIRST WAKES IN A NEW WORLD (the player's call: burnt cubes round them and the
## ground in that radius like weakly glowing embers, no capsule). Raised once by
## world_persist._fresh_start after the machine is seated on its start point; a picture, nothing to
## pick up and no collider (wheels read only the terrain's heights). Not saved: a reload of the world
## comes back without it, and it has done its job by then.
##
## The ground is A PATCH OF ITS OWN (resources/ember_patch.gdshader, one fetch of a baked crack
## texture): charred plates with weakly glowing cracks, draped on the terrain's heights a few
## centimetres up, and the grass under it pressed flat through the trample map (grass.gd
## `press_zone`) so no blade grows through the coals. It lived in the ground's own shader once and
## cost the phone close to half its frame rate (18 -> 34 fps once out) - nothing local goes there.
## It cools over COOL_TIME to COOL_FLOOR and stays so. The cubes are the Falsus block's own model,
## blackened, half sunk, tumbled at random round the start.

const BLOCK_SCENE := "res://blocks/scenes/block.tscn"
const ATLAS := preload("res://objects/Assets_main_texture_new.png")
const RADIUS := 6.5
const CUBES := 7
const CUBE_R := Vector2(2.5, 5.5)     # ring the cubes lie in round the start, inside the burnt ground
const CUBE_GAP := 1.5
const COOL_TIME := 300.0
const COOL_FLOOR := 0.45
const HEAT_EVERY := 0.5               # s between pushes of the cooling heat
const PATCH_SHADER := preload("res://resources/ember_patch.gdshader")
const CRACKS := preload("res://resources/ember_cracks.png")
const LIFT := 0.04                    # over the ground's heights (its triangles bend between nodes)
const PRESS_PAD := 1.05               # the pressed disc reaches a little past the patch's rim
const SHOW_DIST := 180.0              # past this the patch is not drawn

var _t: float = 0.0
var _push_t: float = 0.0
var _at := Vector3.ZERO
var _mat: ShaderMaterial

static func make(parent: Node, at: Vector3) -> Node3D:
	var s: Node3D = load("res://crash_site.gd").new()
	parent.add_child(s)
	s.global_position = at
	s._build(at)
	return s

func _build(at: Vector3) -> void:
	add_to_group("crash_site")
	_at = at
	_patch(at)
	_press(true)
	_cubes(at)

func _press(on: bool) -> void:
	var g: Node = get_tree().get_first_node_in_group("grass_system")
	if g == null:
		return
	if on:
		g.press_zone(self, Vector2(_at.x, _at.z), RADIUS * PRESS_PAD)
	else:
		g.release_zone(self)

func _process(delta: float) -> void:
	_t += delta
	_push_t -= delta
	if _push_t > 0.0:
		return
	_push_t = HEAT_EVERY
	# the grass system may come up after the site: asking again costs a dictionary write
	_press(true)
	var k: float = clampf(_t / COOL_TIME, 0.0, 1.0)
	if _mat != null:
		_mat.set_shader_parameter("heat", lerpf(1.0, COOL_FLOOR, k))

func _exit_tree() -> void:
	_press(false)

## A grid on whole metres, as the ground's level-0 nodes stand, every vertex on the terrain's height
## there plus LIFT; UV is the offset from the middle in radii (the shader's radial fade).
func _patch(at: Vector3) -> void:
	var n: int = int(ceil(RADIUS)) + 1
	var cx: float = floor(at.x + 0.5)
	var cz: float = floor(at.z + 0.5)
	var side: int = n * 2 + 1
	var hs := PackedFloat32Array()
	hs.resize(side * side)
	for j in side:
		for i in side:
			var wx: float = cx + float(i - n)
			var wz: float = cz + float(j - n)
			hs[j * side + i] = G.ground_y(Vector3(wx, at.y, wz), at.y)
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var uvs := PackedVector2Array()
	var idx := PackedInt32Array()
	for j in side:
		for i in side:
			var wx: float = cx + float(i - n)
			var wz: float = cz + float(j - n)
			var h: float = hs[j * side + i]
			verts.append(Vector3(wx - at.x, h + LIFT - at.y, wz - at.z))
			var hl: float = hs[j * side + maxi(i - 1, 0)]
			var hr: float = hs[j * side + mini(i + 1, side - 1)]
			var hd: float = hs[maxi(j - 1, 0) * side + i]
			var hu: float = hs[mini(j + 1, side - 1) * side + i]
			norms.append(Vector3(hl - hr, 2.0, hd - hu).normalized())
			uvs.append(Vector2(wx - at.x, wz - at.z) / RADIUS)
			if i > 0 and j > 0:
				var a: int = j * side + i
				idx.append_array(PackedInt32Array([a - side - 1, a - side, a, a - side - 1, a, a - 1]))
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_NORMAL] = norms
	arr[Mesh.ARRAY_TEX_UV] = uvs
	arr[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	_mat = ShaderMaterial.new()
	_mat.shader = PATCH_SHADER
	_mat.set_shader_parameter("cracks", CRACKS)
	_mat.set_shader_parameter("heat", 1.0)
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = _mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.visibility_range_end = SHOW_DIST
	add_child(mi)

## The Falsus block's mesh, once: the first MeshInstance3D of an uninstanced scene.
func _block_mesh() -> Mesh:
	var ps: PackedScene = load(BLOCK_SCENE)
	if ps == null:
		return null
	var inst: Node = ps.instantiate()
	var m: Mesh = null
	for c in inst.find_children("*", "MeshInstance3D", true, false):
		if (c as MeshInstance3D).mesh != null:
			m = (c as MeshInstance3D).mesh
			break
	inst.free()
	return m

func _cubes(at: Vector3) -> void:
	var mesh: Mesh = _block_mesh()
	if mesh == null:
		var bm := BoxMesh.new()
		mesh = bm
	var burnt := StandardMaterial3D.new()
	burnt.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	burnt.albedo_texture = ATLAS
	burnt.albedo_color = Color(0.17, 0.15, 0.14)
	burnt.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	var placed: Array = []
	var tries: int = 0
	while placed.size() < CUBES and tries < CUBES * 12:
		tries += 1
		var a: float = randf() * TAU
		var r: float = randf_range(CUBE_R.x, CUBE_R.y)
		var p := Vector3(at.x + cos(a) * r, 0.0, at.z + sin(a) * r)
		var ok := true
		for q in placed:
			if (q as Vector3).distance_squared_to(p) < CUBE_GAP * CUBE_GAP:
				ok = false
				break
		if not ok:
			continue
		placed.append(p)
		var mi := MeshInstance3D.new()
		mi.mesh = mesh
		mi.material_override = burnt
		add_child(mi)
		var s: float = randf_range(0.8, 1.05)
		var basis := Basis.from_euler(Vector3(randf() * TAU, randf() * TAU, randf() * TAU)).scaled(Vector3.ONE * s)
		var y: float = G.ground_y(p, at.y) - randf_range(0.15, 0.4) * s
		mi.global_transform = Transform3D(basis, Vector3(p.x, y, p.z))
