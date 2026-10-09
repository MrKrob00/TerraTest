extends MultiMeshInstance3D
## THE FAR TREES: past the veins' draw distance a tree is a PICTURE of itself (the player's call:
## "trees as pictures"). The near tree is the model on its MultiMesh with a node and a collider
## (resource_nodes, inside `render_distance`); out to `resource_nodes.FAR_TREES` the same tree, from the
## same record, is one camera-facing card on this one MultiMesh - two triangles, one draw call for all
## of them, no node. Before this a forest simply ended at 160 m, where the haze has hardly begun
## (`haze_range` 150..750), and every tree popped in at full contrast.
##
## THE PICTURES ARE THE MODELS, PHOTOGRAPHED (`art/tree_impostors.gd` -> `ATLAS`): every tree kind from
## `VIEWS` sides, side on, through the trees' own shader, so the card carries the model's own colours
## and goes through the same tonemap and the same haze. A card shows the side the camera stands on in
## the tree's own frame (its yaw comes with it), so two trees of one kind do not look alike and a tree
## does not turn its picture as the camera circles it. One door for a card's frame: `tile_for`, which
## the bake and the card both read.

const MODELS := [
	"res://resources/vein_tree1.tres",      # TREE_BROAD
	"res://resources/vein_tree2.tres",      # TREE_TEAL
	"res://resources/vein_tree3.tres",      # TREE_PALM
]
const VIEWS := 8
## A picture's pixels, square: the trees stand 0.8 to 1.3 times as wide as they are tall (the palm's
## crown the widest), and a 10 m tree at the far layer's nearest (160 m) is ~45 px tall on a phone at
## 0.75 render scale - 96 is the nearest mip, and the rest only shrink.
const TILE := Vector2i(96, 96)
const ATLAS := "res://resources/far_trees.png"
const SHADER := preload("res://resources/far_tree.gdshader")

## The card's frame in the model's units: (width, height, bottom). Tall enough for the tree, wide
## enough for its crown seen from any side - the farthest VERTEX from the trunk's axis, not the
## bounding box's corner, which is up to 1.41 times that and left every tree small in its tile - the
## tile's aspect kept, the bottom at the model's lowest point. The bake frames its camera with exactly
## this, and so does the card: one function, or the picture and its card disagree in size.
static func tile_for(mesh: Mesh) -> Vector3:
	var reach := 0.0
	var lo := INF
	var hi := -INF
	for si in mesh.get_surface_count():
		for q in mesh.surface_get_arrays(si)[Mesh.ARRAY_VERTEX]:
			reach = maxf(reach, Vector2(q.x, q.z).length())
			lo = minf(lo, q.y)
			hi = maxf(hi, q.y)
	if lo > hi:                                  # no vertices came back: frame by the box instead
		var ab: AABB = mesh.get_aabb()
		lo = ab.position.y
		hi = ab.end.y
		reach = Vector2(maxf(absf(ab.position.x), absf(ab.end.x)), maxf(absf(ab.position.z), absf(ab.end.z))).length()
	var aspect: float = float(TILE.x) / float(TILE.y)
	var tall: float = hi - lo
	var height: float = maxf(tall * 1.03, 2.0 * reach * 1.03 / aspect)
	return Vector3(height * aspect, height, lo - tall * 0.015)

var _buf := PackedFloat32Array()

func setup() -> void:
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_custom_data = true                 # before instance_count, as the veins do
	mm.mesh = _card_mesh()
	mm.instance_count = 0
	multimesh = mm
	# the cards' own bounds are the camera's business: the MultiMesh is drawn whole, like the veins
	custom_aabb = AABB(Vector3(-4000, -2000, -4000), Vector3(8000, 4000, 8000))
	var mat := ShaderMaterial.new()
	mat.shader = SHADER
	mat.set_shader_parameter("atlas", load(ATLAS))
	var tiles := PackedVector4Array()
	for path in MODELS:
		var t: Vector3 = tile_for(load(path) as Mesh)
		tiles.append(Vector4(t.x, t.y, t.z, 0.0))
	mat.set_shader_parameter("tiles", tiles)
	mat.set_shader_parameter("views", float(VIEWS))
	mat.set_shader_parameter("kinds", float(MODELS.size()))
	material_override = mat

## The fade at the far edge, so the layer ends by dissolving rather than at a line.
func set_reach(fade_from: float, fade_to: float) -> void:
	var mat := material_override as ShaderMaterial
	if mat != null:
		mat.set_shader_parameter("fade_from", fade_from)
		mat.set_shader_parameter("fade_to", fade_to)

## The cards to draw: `list` holds, per tree, its position (this node's space), yaw, size and kind.
## Written whole each streaming pass - a few dozen trees, and only when the camera has moved a cell.
func set_trees(list: Array) -> void:
	var n: int = list.size()
	var mm := multimesh
	if mm == null:
		return
	if mm.instance_count < n:
		mm.instance_count = maxi(n, mm.instance_count * 2)
	_buf.resize(mm.instance_count * 16)
	var o: int = 0
	for t in list:
		var p: Vector3 = t[0]
		var s: float = t[2]
		# basis: a uniform scale (the card turns itself to the camera), origin the tree's point
		_buf[o] = s
		_buf[o + 1] = 0.0
		_buf[o + 2] = 0.0
		_buf[o + 3] = p.x
		_buf[o + 4] = 0.0
		_buf[o + 5] = s
		_buf[o + 6] = 0.0
		_buf[o + 7] = p.y
		_buf[o + 8] = 0.0
		_buf[o + 9] = 0.0
		_buf[o + 10] = s
		_buf[o + 11] = p.z
		_buf[o + 12] = float(t[1])          # yaw
		_buf[o + 13] = float(t[3])          # kind
		_buf[o + 14] = 0.0
		_buf[o + 15] = 0.0
		o += 16
	mm.buffer = _buf
	mm.visible_instance_count = n

## One card: x -0.5..0.5 across, y 0..1 up from the tree's foot; UV with the picture's top at the top.
func _card_mesh() -> ArrayMesh:
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = PackedVector3Array([Vector3(-0.5, 0, 0), Vector3(0.5, 0, 0),
			Vector3(0.5, 1, 0), Vector3(-0.5, 1, 0)])
	arr[Mesh.ARRAY_TEX_UV] = PackedVector2Array([Vector2(0, 1), Vector2(1, 1), Vector2(1, 0), Vector2(0, 0)])
	arr[Mesh.ARRAY_NORMAL] = PackedVector3Array([Vector3.BACK, Vector3.BACK, Vector3.BACK, Vector3.BACK])
	arr[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 2, 1, 0, 3, 2])
	var am := ArrayMesh.new()
	am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	# the card is stretched by its shader, not by its vertices: bounds cover the tallest tree
	am.custom_aabb = AABB(Vector3(-20, -2, -20), Vector3(40, 40, 40))
	return am
