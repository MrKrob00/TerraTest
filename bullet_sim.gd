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
## AN ORDINARY ROUND DRAGS A FIRE STREAK, AND BOTH ARE ONE SURFACE OF ONE MESH (`_streak_mesh`,
## `bullet_streak.gdshader`): the round's own model, and behind it two crossed strips (seen from any
## side), white-yellow fading through orange to nothing. One material, so one MultiMesh is still one
## draw call - a trail as a second MultiMesh cost a call more, and replacing the round with the streak
## lost the model. Premultiplied alpha lets one pass draw the round opaque and ADD the streak. The
## streak starts at the round's tail and is the path of the last TRAIL_TIME, capped at TRAIL_MAX and
## at what the round has flown (never back past the muzzle); lengths travel per shot in the
## MultiMesh's custom data. A round that brings its own projectile (WeaponBlock.OWN_VISUAL, the
## laser's bolt) keeps its model and material.
const TRAIL_TIME := 0.03
const TRAIL_MAX := 4.0
const TRAIL_W0 := 0.10           # half-width at the round
const TRAIL_W1 := 0.015          # half-width at the tail
const STREAK_SHADER := preload("res://bullet_streak.gdshader")
const OWN_VISUAL := &"own_visual"   # WeaponBlock.OWN_VISUAL; not named from there (rule 19)

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
	var flown: float = 0.0              # metres since the muzzle: caps the trail
	var live: bool = false
	var last_step: Vector3 = Vector3.ZERO   # the latest tick's step, turned into `facing` when drawn

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
	var streak: bool = false            # the round plus its fire streak (_streak_mesh)
	var tail: float = 0.0               # the round's back end on +Z at trace 1
	var head_col = null                 # the streak's colours when the template names its own
	var mid_col = null

## A TEMPLATE IS READ ONCE. Every shot used to ask its template for five fields by name and build its
## model's key out of `str(transform)` (`_kind_of`): 33-57 us a round, measured, and a volley of two
## dozen shotguns (8 pellets, two shots) and a dozen mortars (8 shells) is ~290 rounds in one frame -
## 10-16 ms on one frame, the player's "FPS drops on every volley". Now the first shot of a template
## reads it into a Tpl and the rest copy numbers. The template is set up in its weapon's _ready
## (`_rebind_bullet`, `_apply_flat_range`) and then never changes; a model swapped later (a laser's
## own bolt) is caught by `_fresh`.
class Tpl:
	var mi: MeshInstance3D = null
	var mesh: Mesh = null
	var mat: Material = null
	var kind = null
	var speed: float = 120.0
	var gravity: float = 50.0
	var min_y: float = 0.0
	var max_life: float = 3.0
	var mask: int = 7

var _live: Array = []
var _spare: Array = []
var _kinds: Dictionary = {}
var _tpls: Dictionary = {}                 # template instance id -> Tpl
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
	var id: int = template.get_instance_id()
	var t: Tpl = _tpls.get(id)
	if t == null or not _fresh(t):
		t = _read_tpl(template)
		_tpls[id] = t
	var s: Shot = _spare.pop_back() if not _spare.is_empty() else Shot.new()
	s.dir = Vector3.ZERO
	s.t = 0.0
	s.speed = t.speed
	s.bullet_gravity = t.gravity
	s.min_y = t.min_y
	s.max_lifetime = t.max_life
	s.mask = t.mask
	s.hit_normal = Vector3.UP
	s.weapon = weapon
	s.kind = t.kind
	s.trace = TRACE_MIN
	s.flown = 0.0
	s.facing = Basis()
	s.last_step = Vector3.ZERO
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

func _read_tpl(template: Node3D) -> Tpl:
	var t := Tpl.new()
	var v = template.get("speed")
	t.speed = float(v) if v != null else 120.0
	v = template.get("bullet_gravity")
	t.gravity = float(v) if v != null else 50.0
	v = template.get("min_y")
	t.min_y = float(v) if v != null else 0.0
	v = template.get("max_lifetime")
	t.max_life = float(v) if v != null else 3.0
	t.mask = (template as CollisionObject3D).collision_mask if template is CollisionObject3D else 7
	for c in template.get_children():
		if c is MeshInstance3D and (c as MeshInstance3D).mesh != null:
			t.mi = c
			break
	if t.mi != null:
		t.mesh = t.mi.mesh
		t.mat = t.mi.material_override
	t.kind = _kind_of(template)
	return t

## Still the model the kind was built from: the same node, mesh and material.
static func _fresh(t: Tpl) -> bool:
	if t.mi == null:
		return true
	return is_instance_valid(t.mi) and t.mi.mesh == t.mesh and t.mi.material_override == t.mat

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
	var smesh: ArrayMesh = null
	var smat: ShaderMaterial = null
	if mi.has_meta(&"streak_head"):
		k.head_col = mi.get_meta(&"streak_head")
	if mi.has_meta(&"streak_mid"):
		k.mid_col = mi.get_meta(&"streak_mid")
	if not mi.has_meta(OWN_VISUAL):
		smesh = _streak_mesh(mi.mesh, k)
		if smesh != null:
			smat = _streak_material(mi.mesh, mat, k)
	k.streak = smesh != null
	k.mmi = MultiMeshInstance3D.new()
	k.mmi.set_meta("block_fx", true)
	k.mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	k.mmi.material_override = smat if k.streak else mat
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_custom_data = k.streak
	mm.mesh = smesh if k.streak else mi.mesh
	mm.instance_count = 32
	mm.visible_instance_count = 0
	k.mmi.multimesh = mm
	add_child(k.mmi)
	_kinds[key] = k
	return k

## The round's model turned and scaled into bullet space (looking down -Z), UV2 (1, 1), after two
## crossed strips from z 0 to z 1 (+Z, behind the round), tapering, UV2 (0, 0), u head to tail
## for the gradient. The shader stretches the round by the trace and moves the strips to its tail.
## null when the model's arrays cannot be read: the kind then draws the plain model.
static func _streak_mesh(src: Mesh, k: Kind) -> ArrayMesh:
	if src == null or src.get_surface_count() < 1:
		return null
	var arr: Array = src.surface_get_arrays(0)
	var sv = arr[Mesh.ARRAY_VERTEX]
	if sv == null or (sv as PackedVector3Array).is_empty():
		return null
	var v := PackedVector3Array()
	var uv := PackedVector2Array()
	var flag := PackedVector2Array()
	var idx := PackedInt32Array()
	for side in [Vector3.RIGHT, Vector3.UP]:
		var a0: Vector3 = side * TRAIL_W0
		var a1: Vector3 = side * TRAIL_W1
		var quad := [-a0, a0, a1 + Vector3.BACK, -a1 + Vector3.BACK]
		var uvs := [Vector2(0, 0), Vector2(0, 1), Vector2(1, 1), Vector2(1, 0)]
		for q in [0, 1, 2, 0, 2, 3]:
			idx.append(v.size())
			v.append(quad[q])
			uv.append(uvs[q])
			flag.append(Vector2.ZERO)
	var base: int = v.size()
	var b: Basis = k.rot * Basis.from_scale(k.scale0)
	var suv = arr[Mesh.ARRAY_TEX_UV]
	var tail: float = -INF
	for i in (sv as PackedVector3Array).size():
		var p: Vector3 = b * (sv as PackedVector3Array)[i]
		tail = maxf(tail, p.z)
		v.append(p)
		uv.append((suv as PackedVector2Array)[i] if suv != null else Vector2.ZERO)
		flag.append(Vector2.ONE)
	var si = arr[Mesh.ARRAY_INDEX]
	if si != null and not (si as PackedInt32Array).is_empty():
		for i in (si as PackedInt32Array):
			idx.append(base + i)
	else:
		for i in (sv as PackedVector3Array).size():
			idx.append(base + i)
	k.tail = tail
	var out := []
	out.resize(Mesh.ARRAY_MAX)
	out[Mesh.ARRAY_VERTEX] = v
	out[Mesh.ARRAY_TEX_UV] = uv
	out[Mesh.ARRAY_TEX_UV2] = flag
	out[Mesh.ARRAY_INDEX] = idx
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, out)
	return m

## The round's own texture and tint go into the shader; the model's material stays untouched.
static func _streak_material(src: Mesh, override: Material, k: Kind) -> ShaderMaterial:
	var sm := ShaderMaterial.new()
	sm.shader = STREAK_SHADER
	var base = override if override != null else src.surface_get_material(0)
	if base is BaseMaterial3D:
		sm.set_shader_parameter("albedo_tex", (base as BaseMaterial3D).albedo_texture)
		sm.set_shader_parameter("albedo", (base as BaseMaterial3D).albedo_color)
	# a faction's round brings its streak's colours on the template (WeaponBlock._apply_bullet_mesh)
	if k.head_col != null:
		sm.set_shader_parameter("head_col", k.head_col)
	if k.mid_col != null:
		sm.set_shader_parameter("mid_col", k.mid_col)
	sm.set_shader_parameter("origin", k.origin)
	sm.set_shader_parameter("tail", k.tail)
	return sm

func _physics_process(delta: float) -> void:
	var _pf := Perf.now()
	_step(delta)
	Perf.mark("bullets", _pf)

## THE PICTURE IS WRITTEN ONCE A DRAWN FRAME, NOT ONCE A PHYSICS TICK. Physics runs at 60 Hz, and at
## 25 fps a frame holds two or three ticks: every round's transform went to the MultiMesh two or
## three times for the one picture that used the last. The rounds stand where the last tick put them,
## exactly as before.
func _process(_delta: float) -> void:
	if _live.is_empty() and _drawn == 0:
		return
	var _pf := Perf.now()
	_draw()
	Perf.mark("bullet_draw", _pf)

var _drawn: int = 0

func _step(delta: float) -> void:
	# one space for the whole tick, not one fetch per round
	var space := get_world_3d().direct_space_state
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
		if _sweep(s, from, to, space):
			if not s.live:
				_spare.append(s)
				continue
		else:
			s.global_position = to
			# the facing is worked out where it is used, once a drawn frame (_draw), from this step
			s.last_step = to - from
			var step: float = s.last_step.length()
			s.trace = clampf(step, TRACE_MIN, TRACE_MAX)
			s.flown += step
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
func _sweep(s: Shot, from: Vector3, to: Vector3, space: PhysicsDirectSpaceState3D) -> bool:
	if space == null:
		return false
	var step: Vector3 = to - from
	if step.length_squared() < 0.000001:
		return false
	if _ray == null:
		_ray = PhysicsRayQueryParameters3D.new()
		_ray.collide_with_areas = false
	var start: Vector3 = from
	_ray.collision_mask = s.mask
	for _i in SWEEP_OWN_TRIES + 1:
		_ray.from = start
		_ray.to = to
		var h := space.intersect_ray(_ray)
		if h.is_empty():
			return false
		# what was hit is looked at only when something was: most ticks of most rounds hit nothing
		var body = h.get("collider")
		var own_blocks = s.shooter_blocks if is_instance_valid(s.shooter_blocks) else null
		if body != null and own_blocks != null and body.get_parent() == own_blocks:
			start = (h["position"] as Vector3) + step.normalized() * SWEEP_SKIP
			continue
		if body != null and G.is_friendly_dome(body, own_blocks.get_parent() if own_blocks != null else null):
			start = (h["position"] as Vector3) + step.normalized() * SWEEP_SKIP
			continue
		s.global_position = h["position"]
		s.hit_normal = h.get("normal", Vector3.UP)
		if is_instance_valid(s.weapon) and s.weapon.has_method("_on_bullet_body_entered"):
			s.weapon.call("_on_bullet_body_entered", body, s)
		retire(s)                              # one bullet, one hit, whatever the handler did
		return true
	return false

## Room for one more instance: the buffer doubles and keeps what it had. THE NEW BUFFER IS BUILT
## HERE, at the old one's stride: read back after `instance_count` changed, `mm.buffer` did not come
## at the new size, `set_buffer` refused it ("a different size") and every round in the air lost its
## place the moment the pool grew - in the first bursts of a fight.
static func _room(mm: MultiMesh, n: int) -> void:
	if n < mm.instance_count:
		return
	var old_n: int = mm.instance_count
	var old := PackedFloat32Array(mm.buffer)
	var new_n: int = maxi(old_n * 2, 1)
	if old_n == 0 or old.size() == 0:
		mm.instance_count = new_n
		return
	var stride: int = old.size() / old_n
	var buf := PackedFloat32Array()
	buf.resize(new_n * stride)
	for j in old.size():
		buf[j] = old[j]
	mm.instance_count = new_n
	mm.buffer = buf

func _draw() -> void:
	for key in _kinds:
		(_kinds[key] as Kind).count = 0
	for sh in _live:
		var s: Shot = sh
		var k: Kind = s.kind
		if k == null:
			continue
		if s.last_step != Vector3.ZERO:
			s.face(s.last_step)
			s.last_step = Vector3.ZERO
		var mm: MultiMesh = k.mmi.multimesh
		if k.count >= mm.instance_count:
			_room(mm, k.count)
		var at := Transform3D(s.facing, s.global_position)
		if k.streak:
			var length: float = minf(s.speed * TRAIL_TIME, TRAIL_MAX)
			length = clampf(s.flown - k.tail * s.trace, 0.0, length)
			mm.set_instance_transform(k.count, at)
			mm.set_instance_custom_data(k.count, Color(length, s.trace, 0.0, 0.0))
		else:
			var sc: Vector3 = k.scale0
			sc[k.axis] = k.scale0[k.axis] * s.trace
			mm.set_instance_transform(k.count, at * Transform3D(k.rot * Basis.from_scale(sc), k.origin))
		k.count += 1
	for key in _kinds:
		var k: Kind = _kinds[key]
		k.mmi.multimesh.visible_instance_count = k.count
	_drawn = _live.size()
