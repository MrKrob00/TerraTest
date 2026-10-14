extends Node3D
## WHERE THE PLAYER FIRST WAKES IN A NEW WORLD (the player's call: burnt cubes round them and the
## ground in that radius like weakly glowing embers, no capsule). Raised once by
## world_persist._fresh_start after the machine is seated on its start point; a picture, nothing to
## pick up and no collider (wheels read only the terrain's heights). Not saved: a reload of the world
## comes back without it, and it has done its job by then.
##
## The ground is the TERRAIN'S OWN SHADER (glsl.gdshader `ember_spot`, through
## ChunkTerrain.set_ember_spot): charred plates with glowing cracks, no grass on it. A patch drawn over
## the ground had to be pulled toward the camera to clear the grass and darkened every block standing
## on it. It cools over COOL_TIME to COOL_FLOOR and stays so. The cubes are the Falsus block's own
## model, blackened, half sunk, tumbled at random round the start.

const BLOCK_SCENE := "res://blocks/scenes/block.tscn"
const ATLAS := preload("res://objects/Assets_main_texture_new.png")
const RADIUS := 6.5
const CUBES := 7
const CUBE_R := Vector2(2.5, 5.5)     # ring the cubes lie in round the start, inside the burnt ground
const CUBE_GAP := 1.5
const COOL_TIME := 300.0
const COOL_FLOOR := 0.45
const HEAT_EVERY := 0.5               # s between pushes of the cooling heat

var _t: float = 0.0
var _push_t: float = 0.0
var _at := Vector3.ZERO

static func make(parent: Node, at: Vector3) -> Node3D:
	var s: Node3D = load("res://crash_site.gd").new()
	parent.add_child(s)
	s.global_position = at
	s._build(at)
	return s

func _build(at: Vector3) -> void:
	add_to_group("crash_site")
	_at = at
	_push(1.0)
	_cubes(at)

func _terrain() -> Node:
	var m: Node = get_node_or_null("/root/Main/map")
	return m if m != null and m.has_method("set_ember_spot") else null

func _push(heat: float) -> void:
	var t: Node = _terrain()
	if t != null:
		t.set_ember_spot(Vector4(_at.x, _at.z, RADIUS, heat))

func _process(delta: float) -> void:
	_t += delta
	_push_t -= delta
	if _push_t > 0.0:
		return
	_push_t = HEAT_EVERY
	var k: float = clampf(_t / COOL_TIME, 0.0, 1.0)
	_push(lerpf(1.0, COOL_FLOOR, k))
	if k >= 1.0:
		set_process(false)

func _exit_tree() -> void:
	var t: Node = _terrain()
	if t != null:
		t.set_ember_spot(Vector4.ZERO)

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
