extends Node
# THE RING ON THE GROUND IS THE REACH, AND IT IS THE TRUE ONE (the player's call: "it should turn at
# the collector's pickup radius, on the ground"; then the receiver got the same ring in place of its
# old torus hanging at block height). One child node of the block, ticking on its own: a factory block
# switches its own `_process` off (FactoryBlock._process), and a ring riding that would stall.
#
# The pickup zone is a SPHERE round the block (`area`), so where it meets the ground is not a fixed
# circle: `SEGMENTS` directions are each walked out to the point whose distance from the zone's middle
# is the sphere's radius, on the terrain's own heights - nearer on a rise, farther in a dip, nothing
# at all once the block stands higher than the radius. A ribbon over those points, dashes running
# round it (blocks/collector_ring.gdshader), lifted out of the grass in depth as the ground marks are.
# Two earlier rings, both wrong: the 5 m one hung at the machine's centre height and read as arcs
# beside the block, then a 0.7 m one turned round the block's own base and said nothing about the
# reach.
#
# Built in the world (top_level), only while `active` says so and within `SHOW_DIST` of the camera.
# A parked block builds it once; a driving one slides it along every frame and re-reads the heights
# every `REFRESH`.

const SHADER := preload("res://blocks/collector_ring.gdshader")
const SEGMENTS := 48
const WIDTH := 0.16
const DASHES := 28.0
const REFRESH := 0.2
const IDLE := 2.0                     # s: a parked block re-reads now and then (ground still loading)
const MOVE2 := 0.04                   # 0.2 m: a parked block that only rocks does not rebuild
const SHOW_DIST := 70.0
const LIFT := 0.04                    # over the grass lift, as the ground marks' HOLE_LIFT

## The pickup zone whose sphere is drawn.
var area: Area3D = null
## Whether the ring is wanted now (on a machine, working); called every frame.
var active: Callable

var _ring: MeshInstance3D = null
var _ok: bool = false                 # the last read found ground in reach
var _t: float = 0.0
var _at := Vector3(1e9, 1e9, 1e9)

func _process(delta: float) -> void:
	var show: bool = is_instance_valid(area) and area.is_inside_tree() and active.is_valid() and active.call()
	if show:
		var cam: Camera3D = get_viewport().get_camera_3d()
		show = cam != null and cam.global_position.distance_squared_to(area.global_position) \
				<= SHOW_DIST * SHOW_DIST
	if not show:
		if is_instance_valid(_ring):
			_ring.visible = false
		return
	var p: Vector3 = area.global_position
	var moved: bool = p.distance_squared_to(_at) > MOVE2
	_t -= delta
	if not is_instance_valid(_ring) or (_t <= 0.0 and moved) or _t <= -IDLE:
		_t = REFRESH
		_at = p
		_build(p)
	elif _ok:
		# between reads the ribbon rides along with the block, its heights from where they were read
		_ring.visible = true
		if moved:
			_ring.global_position = Vector3(p.x, 0.0, p.z)

## The reach where it meets the ground, in world space: per direction the distance r at which the
## ground point is the sphere's radius away from the zone's middle - a few fixed-point steps on the
## heights (r = sqrt(R² - dy²), dy re-read at the new r). No ground in reach - no ring.
func _build(p: Vector3) -> void:
	var reach: float = _radius()
	if reach <= 0.0:
		return
	var r0: float = _ground_reach(p, Vector2.ZERO, reach, -1.0).x
	_ok = r0 > 0.0
	if not _ok:
		if not is_instance_valid(_ring):
			_make()                                 # so the next read is a refresh, not a first build
		_ring.visible = false
		return
	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	var idx := PackedInt32Array()
	var half: float = WIDTH * 0.5
	for i in SEGMENTS + 1:                          # the seam repeats the first point: UV runs 0..1
		var a: float = TAU * float(i % SEGMENTS) / float(SEGMENTS)
		var dir := Vector2(cos(a), sin(a))
		var ry: Vector2 = _ground_reach(p, dir, reach, r0)
		var r: float = ry.x if ry.x > 0.0 else r0
		var y: float = ry.y                          # one height for both edges
		for side in 2:
			var o: Vector2 = dir * (r + (half if side == 1 else -half))
			verts.append(Vector3(o.x, y, o.y))
			uvs.append(Vector2(float(i) / float(SEGMENTS), float(side)))
		if i > 0:
			var b: int = i * 2
			idx.append_array(PackedInt32Array([b - 2, b - 1, b + 1, b - 2, b + 1, b]))
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_TEX_UV] = uvs
	arr[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	if not is_instance_valid(_ring):
		_make()
	(_ring.material_override as ShaderMaterial).set_shader_parameter("depth_lift", G.grass_lift() + LIFT)
	_ring.mesh = mesh
	_ring.global_transform = Transform3D(Basis(), Vector3(p.x, 0.0, p.z))
	_ring.visible = true

func _radius() -> float:
	for c in area.get_children():
		if c is CollisionShape3D and (c as CollisionShape3D).shape is SphereShape3D:
			return ((c as CollisionShape3D).shape as SphereShape3D).radius
	return 0.0

func _make() -> void:
	_ring = MeshInstance3D.new()
	_ring.top_level = true
	_ring.set_meta("block_fx", true)                # not the block's own model: _local_aabb skips it
	_ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var mat := ShaderMaterial.new()
	mat.shader = SHADER
	mat.set_shader_parameter("dashes", DASHES)
	_ring.material_override = mat
	add_child(_ring)

## (r, ground height): how far out along `dir` the ground is `reach` away from `p`, and the height last
## read on the way (the ribbon's); r 0 when the ground there is out of reach. dir zero asks straight
## down. Two steps from the guess (the reach under the block) are within centimetres on any slope a
## machine stands on, and the ribbon is rebuilt five times a second while moving.
func _ground_reach(p: Vector3, dir: Vector2, reach: float, guess: float) -> Vector2:
	var r: float = maxf(guess, 0.0)
	var y: float = p.y
	for step in 2:
		var q := Vector2(p.x, p.z) + dir * r
		y = G.ground_y(Vector3(q.x, p.y, q.y), p.y - reach)
		var dy: float = p.y - y
		if absf(dy) >= reach:
			return Vector2(0.0, y)
		r = sqrt(reach * reach - dy * dy)
		if dir == Vector2.ZERO:
			break
	return Vector2(r, y)
