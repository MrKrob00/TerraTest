class_name BulletSim
extends Node3D
# EVERY FLYING BULLET IN THE WORLD, IN ONE LOOP, DRAWN BY ONE MULTIMESH PER MODEL.
#
# A bullet used to be a scene node: an Area3D with a script, a collision shape and a mesh, ticking
# on its own and writing its own transforms (the physics server re-bucketed the Area on every move).
# Now it is a Shot - plain data - and this node steps them all, sweeps each step with one reused ray
# query, and writes where each one is into a MultiMesh per model: one draw call for all the machine
# gun rounds in the air, one for all laser bolts. Nothing else changed about flight or hits:
#   - the step, the gravity drop and the expiry are bullet.gd's, line for line;
#   - the sweep skips the shooter's own blocks and friendly domes exactly as before;
#   - the model faces its STEP every tick (the mortar's lob), and stretches along the axis of its
#     mesh that points down the flight by the length of the step (a trace, not a dotted line).
#
# THE WEAPONS STILL SEE A BULLET-LIKE OBJECT. A Shot carries the fields they read and write -
# dir, speed, bullet_gravity, max_lifetime, global_position, hit_normal, shooter_blocks - so the
# shotgun's cone, the mortar's arc, the rocket's blast and the hit handler work on it unchanged.
# What defines a weapon's round is still the template bullet in its scene (Ammo/Bullet): speed,
# drop, lifetime, collision mask and model are copied from it at every shot.

const TRACE_MIN := 1.0           # a trace is never shorter than the round itself
const TRACE_MAX := 14.0          # and never a beam across the map
const SWEEP_SKIP := 0.05         # past our own body, so the ray does not stop on it again
const SWEEP_OWN_TRIES := 3       # how many of our own blocks in a row the ray may skip
const FACE_MIN_STEP := 0.0001

class Shot:
	var dir: Vector3 = Vector3.ZERO
	var speed: float = 120.0
	var bullet_gravity: float = 50.0
	var min_y: float = 0.0
	var max_lifetime: float = 3.0
	var t: float = 0.0
	var global_position: Vector3 = Vector3.ZERO
	var hit_normal: Vector3 = Vector3.UP
	var shooter_blocks: Node = null
	var weapon: Node = null
	var mask: int = 7
	var kind = null                     # BulletSim.Kind
	var facing: Basis = Basis()
	var trace: float = TRACE_MIN
	var live: bool = false

	## Kept for the mortar, which turns its shell once after setting the arc; the tick turns every
	## shot to its step anyway.
	func look_at(target: Vector3) -> void:
		face(target - global_position)

	func face(step: Vector3) -> void:
		if step.length_squared() < FACE_MIN_STEP:
			return
		var fwd: Vector3 = step.normalized()
		facing = Basis.looking_at(fwd, Vector3.UP if absf(fwd.y) < 0.99 else Vector3.FORWARD)

## One model: the template's mesh, material and its transform inside the bullet node.
class Kind:
	var mmi: MultiMeshInstance3D = null
	var rot: Basis = Basis()            # the mesh's own turn inside the bullet (the laser capsule's -90 deg)
	var scale0: Vector3 = Vector3.ONE   # its normalising scale
	var origin: Vector3 = Vector3.ZERO
	var axis: int = 2                   # which of its axes lies down the flight
	var count: int = 0

var _live: Array = []
var _spare: Array = []
var _kinds: Dictionary = {}
var _ray: PhysicsRayQueryParameters3D = null

## The world's simulator, made on first use under the current scene (the menu's fight has its own).
static func of(n: Node):
	var tree := n.get_tree()
	var host: Node = tree.current_scene if tree.current_scene != null else tree.root
	var sim = host.get_node_or_null("BulletSim")
	if sim == null:
		sim = load("res://bullet_sim.gd").new()     # its own class_name may not be cached yet
		sim.name = "BulletSim"
		host.add_child(sim)
	return sim

func _ready() -> void:
	set_meta("block_fx", true)
	top_level = true

## A new shot, filled from the weapon's template bullet (Ammo/Bullet).
func fire(weapon: Node, template: Node3D) -> Shot:
	var s: Shot = _spare.pop_back() if not _spare.is_empty() else Shot.new()
	s.dir = Vector3.ZERO
	s.t = 0.0
	s.speed = float(template.get("speed")) if template.get("speed") != null else 120.0
	s.bullet_gravity = float(template.get("bullet_gravity")) if template.get("bullet_gravity") != null else 50.0
	s.min_y = float(template.get("min_y")) if template.get("min_y") != null else 0.0
	s.max_lifetime = float(template.get("max_lifetime")) if template.get("max_lifetime") != null else 3.0
	s.mask = (template as CollisionObject3D).collision_mask if template is CollisionObject3D else 7
	s.hit_normal = Vector3.UP
	s.weapon = weapon
	s.kind = _kind_of(template)
	s.trace = TRACE_MIN
	s.facing = Basis()
	s.live = true
	_live.append(s)
	return s

## Back to the spare list: the weapon's _recycle_bullet calls this once a shot has landed or expired.
func retire(s: Shot) -> void:
	if s == null or not s.live:
		return
	s.live = false
	s.dir = Vector3.ZERO
	s.weapon = null
	s.shooter_blocks = null

func _kind_of(template: Node3D) -> Kind:
	var mi: MeshInstance3D = null
	for c in template.get_children():
		if c is MeshInstance3D and (c as MeshInstance3D).mesh != null:
			mi = c
			break
	if mi == null:
		return null
	var mat = mi.material_override
	var key: String = "%d|%d|%s" % [mi.mesh.get_rid().get_id(),
			mat.get_rid().get_id() if mat != null else 0, str(mi.transform)]
	if _kinds.has(key):
		return _kinds[key]
	var k := Kind.new()
	k.rot = mi.transform.basis.orthonormalized()
	k.scale0 = mi.transform.basis.get_scale()
	k.origin = mi.transform.origin
	# The bullet looks down -Z; which axis of the MESH lies that way is asked of its own turn.
	var local: Vector3 = (k.rot.inverse() * Vector3.BACK).abs()
	k.axis = 2
	if local.x > local.y and local.x > local.z:
		k.axis = 0
	elif local.y > local.z:
		k.axis = 1
	k.mmi = MultiMeshInstance3D.new()
	k.mmi.set_meta("block_fx", true)
	k.mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	k.mmi.material_override = mat
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = mi.mesh
	mm.instance_count = 32
	mm.visible_instance_count = 0
	k.mmi.multimesh = mm
	add_child(k.mmi)
	_kinds[key] = k
	return k

func _physics_process(delta: float) -> void:
	var _pf := Perf.now()
	_step(delta)
	_draw()
	Perf.mark("bullets", _pf)

func _step(delta: float) -> void:
	var keep: int = 0
	for i in _live.size():
		var s: Shot = _live[i]
		if s.live and not is_instance_valid(s.weapon):
			retire(s)                          # the gun is gone; its rounds go with it, as before
		if not s.live:
			_spare.append(s)
			continue
		s.t += delta
		var from: Vector3 = s.global_position
		var to: Vector3 = from + s.dir * s.speed * delta
		to.y -= s.t * s.bullet_gravity * delta
		if _sweep(s, from, to):
			if not s.live:
				_spare.append(s)
				continue
		else:
			s.global_position = to
			s.face(to - from)
			s.trace = clampf(from.distance_to(to), TRACE_MIN, TRACE_MAX)
			if s.global_position.y < s.min_y or s.t > s.max_lifetime:
				s.dir = Vector3.ZERO
				if is_instance_valid(s.weapon) and s.weapon.has_method("_on_bullet_expired"):
					s.weapon.call("_on_bullet_expired", s)
				retire(s)
				_spare.append(s)
				continue
		_live[keep] = s
		keep += 1
	_live.resize(keep)

## The whole step, one ray, skipping our own blocks and friendly domes. true: something was hit.
func _sweep(s: Shot, from: Vector3, to: Vector3) -> bool:
	var space := get_world_3d().direct_space_state
	if space == null:
		return false
	var step: Vector3 = to - from
	if step.length_squared() < 0.000001:
		return false
	var fwd: Vector3 = step.normalized()
	if _ray == null:
		_ray = PhysicsRayQueryParameters3D.new()
		_ray.collide_with_areas = false
	var start: Vector3 = from
	var own_root: Node = s.shooter_blocks.get_parent() if is_instance_valid(s.shooter_blocks) else null
	for _i in SWEEP_OWN_TRIES + 1:
		_ray.from = start
		_ray.to = to
		_ray.collision_mask = s.mask
		var h := space.intersect_ray(_ray)
		if h.is_empty():
			return false
		var body = h.get("collider")
		if body != null and is_instance_valid(s.shooter_blocks) and body.get_parent() == s.shooter_blocks:
			start = (h["position"] as Vector3) + fwd * SWEEP_SKIP
			continue
		if body != null and G.is_friendly_dome(body, own_root):
			start = (h["position"] as Vector3) + fwd * SWEEP_SKIP
			continue
		s.global_position = h["position"]
		s.hit_normal = h.get("normal", Vector3.UP)
		if is_instance_valid(s.weapon) and s.weapon.has_method("_on_bullet_body_entered"):
			s.weapon.call("_on_bullet_body_entered", body, s)
		retire(s)                              # one bullet, one hit, whatever the handler did
		return true
	return false

func _draw() -> void:
	for key in _kinds:
		(_kinds[key] as Kind).count = 0
	for s in _live:
		var k: Kind = (s as Shot).kind
		if k == null:
			continue
		var mm: MultiMesh = k.mmi.multimesh
		if k.count >= mm.instance_count:
			var keep_n: int = mm.instance_count
			var old := PackedFloat32Array(mm.buffer)
			mm.instance_count = keep_n * 2
			var buf := mm.buffer
			for j in old.size():
				buf[j] = old[j]
			mm.buffer = buf
		var sc: Vector3 = k.scale0
		sc[k.axis] = k.scale0[k.axis] * (s as Shot).trace
		var local := Transform3D(k.rot * Basis.from_scale(sc), k.origin)
		mm.set_instance_transform(k.count, Transform3D((s as Shot).facing, (s as Shot).global_position) * local)
		k.count += 1
	for key in _kinds:
		var k: Kind = _kinds[key]
		k.mmi.multimesh.visible_instance_count = k.count
