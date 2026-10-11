extends VehicleBlock
# КОЛЛЕКТОР — подбирает с земли, и всё. По ленте он НИЧЕГО НЕ ПЕРЕДАЁТ: это VehicleBlock, а не
# FactoryBlock, значит у него нет ни выходов, ни push_item. Забрать у него добычу может только
# приёмник (Receiver._take_from_vehicle), и вот он уже работает лишь на якоре.
#
# Сам коллектор якоря НЕ ТРЕБУЕТ намеренно: собирать руду на ходу — его единственная работа,
# и запрет на это сделал бы блок бессмысленным.

var is_on_vehicle: bool = false
var inventory:Array = []
@export var capacity: int = 2

# ФИЗИКА (freeze тела, monitoring ареи) — в _physics_process: это свойства физического сервера,
# менять их надо на физ-тике, а не на кадре отрисовки (иначе правки летят в произвольный момент
# шага физики и лишний раз дёргают сервер на быстрых экранах).
func _physics_process(_delta: float) -> void:
	if $"..".name == "objects":
		if is_on_vehicle:
			$collector.monitoring = false
			is_on_vehicle = false
		return
	if !is_on_vehicle:
		$collector.monitoring = true
		is_on_vehicle = true
	elif not freeze:
		freeze = true

# THE RING ON THE GROUND IS THE REACH, AND IT IS THE TRUE ONE (the player's call: "it should turn at
# the collector's pickup radius, on the ground"). The pickup zone is a SPHERE round the block
# (`$collector`), so where it meets the ground is not a fixed circle: `RING_SEGMENTS` directions are
# each walked out to the point whose distance from the block is the sphere's radius, on the terrain's
# own heights - nearer on a rise, farther in a dip, nothing at all once the block stands higher than
# the radius. A ribbon over those points, dashes running round it (blocks/collector_ring.gdshader),
# lifted out of the grass in depth as the ground marks are. Two earlier rings, both wrong: the 5 m
# one hung at the machine's centre height and read as arcs beside the block, then a 0.7 m one turned
# round the block's own base and said nothing about the reach.
#
# Built in the world (top_level), only on a machine and only within `RING_SHOW_DIST` of the camera.
# A parked block builds it once; a driving one slides it along every frame and re-reads the heights
# every `RING_REFRESH`.
const RING_SHADER := preload("res://blocks/collector_ring.gdshader")
const RING_SEGMENTS := 48
const RING_WIDTH := 0.16
const RING_DASHES := 28.0
const RING_REFRESH := 0.2
const RING_IDLE := 2.0                # s: a parked block re-reads now and then (ground still loading)
const RING_MOVE2 := 0.04              # 0.2 m: a parked block that only rocks does not rebuild
const RING_SHOW_DIST := 70.0
const RING_LIFT := 0.04               # over the grass lift, as the ground marks' HOLE_LIFT
var _ring: MeshInstance3D = null
var _ring_ok: bool = false            # the last read found ground in reach
var _ring_t: float = 0.0
var _ring_at := Vector3(1e9, 1e9, 1e9)

func _process(delta: float) -> void:
	var show: bool = is_on_vehicle and get_parent() != null and get_parent().name == "blocks"
	if show:
		var cam: Camera3D = get_viewport().get_camera_3d()
		show = cam != null and cam.global_position.distance_squared_to(global_position) \
				<= RING_SHOW_DIST * RING_SHOW_DIST
	if not show:
		if is_instance_valid(_ring):
			_ring.visible = false
		return
	var p: Vector3 = ($collector as Node3D).global_position
	var moved: bool = p.distance_squared_to(_ring_at) > RING_MOVE2
	_ring_t -= delta
	if not is_instance_valid(_ring) or (_ring_t <= 0.0 and moved) or _ring_t <= -RING_IDLE:
		_ring_t = RING_REFRESH
		_ring_at = p
		_build_ring(p)
	elif _ring_ok:
		# between reads the ribbon rides along with the block, its heights from where they were read
		_ring.visible = true
		if moved:
			_ring.global_position = Vector3(p.x, 0.0, p.z)

## The reach where it meets the ground, in world space: per direction the distance r at which the
## ground point is the sphere's radius away from the block - a few fixed-point steps on the heights
## (r = sqrt(R² - dy²), dy re-read at the new r). No ground in reach - no ring.
func _build_ring(p: Vector3) -> void:
	var shape := get_node_or_null("collector/CollisionShape3D") as CollisionShape3D
	var sphere := shape.shape as SphereShape3D if shape != null else null
	if sphere == null:
		return
	var reach: float = sphere.radius
	var r0: float = _ground_reach(p, Vector2.ZERO, reach, -1.0).x
	_ring_ok = r0 > 0.0
	if not _ring_ok:
		if is_instance_valid(_ring):
			_ring.visible = false
		else:
			_make_ring()                            # so the next read is a refresh, not a first build
			_ring.visible = false
		return
	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	var idx := PackedInt32Array()
	var half: float = RING_WIDTH * 0.5
	for i in RING_SEGMENTS + 1:                     # the seam repeats the first point: UV runs 0..1
		var a: float = TAU * float(i % RING_SEGMENTS) / float(RING_SEGMENTS)
		var dir := Vector2(cos(a), sin(a))
		var ry: Vector2 = _ground_reach(p, dir, reach, r0)
		var r: float = ry.x if ry.x > 0.0 else r0
		var y: float = ry.y                          # one height for both edges
		for side in 2:
			var o: Vector2 = dir * (r + (half if side == 1 else -half))
			verts.append(Vector3(o.x, y, o.y))
			uvs.append(Vector2(float(i) / float(RING_SEGMENTS), float(side)))
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
		_make_ring()
	(_ring.material_override as ShaderMaterial).set_shader_parameter("depth_lift", G.grass_lift() + RING_LIFT)
	_ring.mesh = mesh
	_ring.global_transform = Transform3D(Basis(), Vector3(p.x, 0.0, p.z))
	_ring.visible = true

func _make_ring() -> void:
	_ring = MeshInstance3D.new()
	_ring.top_level = true
	_ring.set_meta("block_fx", true)                # not the block's own model: _local_aabb skips it
	_ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var mat := ShaderMaterial.new()
	mat.shader = RING_SHADER
	mat.set_shader_parameter("dashes", RING_DASHES)
	_ring.material_override = mat
	add_child(_ring)

## (r, ground height): how far out along `dir` the ground is `reach` away from the block at `p`, and
## the height last read on the way (the ribbon's); r 0 when the ground there is out of reach. dir zero
## asks straight down. Two steps from the guess (the reach under the block) are within centimetres
## on any slope a machine stands on, and the ribbon is rebuilt five times a second while moving.
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

func _on_collector_body_entered(body: RigidBody3D) -> void:
	if inventory.has(body): return  # ← уже в инвентаре, игнорируем
	elif body.freeze:
		return
	# СВОБОДНЫЕ БЛОКИ — не его работа, для них есть упаковщик (packer.gd). Здесь стояла
	# ветка упаковки, но зона коллектора имеет маску 8 (ТОЛЬКО ресурсы), так что блока она не
	# видела никогда: код был мёртвый, а комментарий рядом с ним утверждал обратное.
	# Готовые ЧАНКИ коллектор берёт как обычный ресурс — они лежат на том же слое.
	if inventory.size()>=capacity:
		return
	body.reparent($resources)
	if inventory.has(body): return
	inventory.append(body)
	body.freeze = true
	fix_position_resources.call_deferred(body)

## Отдать предмет приёмнику. Он это уже зовёт (Receiver._take_from_vehicle), но метода не
## было, и вызов молча пропускался: список чистился лишь потом, сигналом child_order_changed.
## Пока он не сработал, коллектор считал слот занятым и мог не взять следующую руду.
func remove_from_inventory(item: Node) -> void:
	inventory.erase(item)
	# The single door out puts the item back as a loose one: visible, seated as loose items sit.
	if is_instance_valid(item) and item is Node3D:
		(item as Node3D).visible = true
		if item.has_method("unseat"):
			item.unseat()
	_layout()

## WHAT IT PICKED UP STANDS IN A STACK IN THE BOWL, AS THE RECEIVER LIFTS ITS CARGO (the player's
## call: it showed one and hid the rest, so a collector carrying five looked like it carried one).
## Each item stands on the one under it (`model_height` + `STACK_GAP`): the first stack, of
## metre-wide bubbles one metre apart, grew a tower taller than the machine - which is why it was
## cut down to one.
const HOLD_Y := 0.45
## The bottom item's model stands this far under HOLD_Y, on the bowl's boss (resource.seat).
const HOLD_FOOT := -0.12
const STACK_GAP := 0.02

func _layout() -> void:
	var holder := get_node_or_null("resources")
	if holder == null:
		return                     # the block is being torn down; its children go first
	inventory = inventory.filter(func(i):
		return is_instance_valid(i) and i.get_parent() == holder)
	var y := HOLD_Y
	for idx in inventory.size():
		var n := inventory[idx] as Node3D
		if n == null:
			continue
		n.position = Vector3(0, y, 0)
		n.visible = true
		if n.has_method("seat"):
			n.seat(HOLD_FOOT)
		y += (n.model_height() if n.has_method("model_height") else 0.3) + STACK_GAP

func fix_position_resources(body: Node3D) -> void:
	if not is_instance_valid(body):
		return                     # taken and freed while the call waited for the frame
	_layout()

## The list is cleaned FIRST and laid out after: a node a receiver took may already be freed (a
## freed reference is not null), and erasing inside the loop over the same array skipped items.
func _on_resources_child_order_changed() -> void:
	_layout()
