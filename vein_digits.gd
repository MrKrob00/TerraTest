extends MultiMeshInstance3D
# RED DIGITS THAT BOUNCE OFF A STRUCK VEIN (the player's call, in place of the white flash the vein
# shader used to draw on a hit, which read as a placeholder). The same 0/1 cards the repair unit
# flies and the damage overlay is written in (vein_digit.gdshader, the repair digit blended rather
# than added), red: a hit on the world says "damage" in the game's own alphabet.
#
# ONE MultiMesh for every vein, owned by resource_nodes: a pool of POOL cards moved on the CPU only
# while one is in flight, the oldest reused when a drill keeps biting. World space (top_level), so
# the box is the world's; idle, `visible_instance_count` is 0 and nothing is drawn.

const POOL := 48
const PER_HIT := 3
const LIFE := 0.9               # s a digit lives
const SIZE := 0.36
const GRAVITY := 14.0
const BOUNCE := 0.45            # the share of its fall speed a digit keeps off the ground
const SPEED_UP := Vector2(2.2, 3.4)
const SPEED_OUT := Vector2(1.6, 2.8)
const SPREAD := 0.9             # rad either side of `out` a digit may leave at
const MIN_GAP := 0.12           # s between two bursts off one vein (a drill hits every tick)

var _live: Array = []           # [{slot, pos, vel, age, floor, seed}]
var _next := 0
var _last_burst: Dictionary = {}    # vein instance id -> time of its last burst

func _ready() -> void:
	top_level = true
	global_transform = Transform3D.IDENTITY
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_custom_data = true
	var q := QuadMesh.new()
	q.size = Vector2.ONE
	mm.mesh = q
	mm.instance_count = POOL
	mm.visible_instance_count = 0
	multimesh = mm
	var mat := ShaderMaterial.new()
	mat.shader = preload("res://vein_digit.gdshader")
	material_override = mat
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	custom_aabb = AABB(Vector3.ONE * -1.0e5, Vector3.ONE * 2.0e5)
	set_meta("block_fx", true)
	set_process(false)

## A few digits out of the vein at `top` toward `out` (flat, toward the viewer: thrown straight up
## they flew into a tree's crown and its needles hid them), landing on the ground at `ground_y`.
func burst(vein: Object, top: Vector3, ground_y: float, out_dir: Vector3 = Vector3.ZERO) -> void:
	var now := Time.get_ticks_msec() / 1000.0
	var id := vein.get_instance_id()
	if now - float(_last_burst.get(id, -10.0)) < MIN_GAP:
		return
	_last_burst[id] = now
	if _last_burst.size() > 256:
		_last_burst.clear()
	for i in PER_HIT:
		var a := randf() * TAU
		if out_dir.length_squared() > 0.01:
			a = atan2(out_dir.z, out_dir.x) + randf_range(-SPREAD, SPREAD)
		var out := randf_range(SPEED_OUT.x, SPEED_OUT.y)
		var d := {"slot": _next, "pos": top + Vector3(cos(a), 0.0, sin(a)) * 0.15,
				"vel": Vector3(cos(a) * out, randf_range(SPEED_UP.x, SPEED_UP.y), sin(a) * out),
				"age": 0.0, "floor": ground_y + SIZE * 0.5, "seed": randf()}
		# a reused slot takes over: drop whoever flew in it
		for k in range(_live.size() - 1, -1, -1):
			if int(_live[k]["slot"]) == _next:
				_live.remove_at(k)
		_live.append(d)
		_next = (_next + 1) % POOL
	multimesh.visible_instance_count = -1
	set_process(true)

func _process(delta: float) -> void:
	var mm := multimesh
	for k in range(_live.size() - 1, -1, -1):
		var d: Dictionary = _live[k]
		d["age"] = float(d["age"]) + delta
		var slot: int = d["slot"]
		if float(d["age"]) >= LIFE:
			mm.set_instance_custom_data(slot, Color(0, 0, 0, 0))
			_live.remove_at(k)
			continue
		var v: Vector3 = d["vel"]
		v.y -= GRAVITY * delta
		var p: Vector3 = d["pos"] + v * delta
		if p.y < float(d["floor"]) and v.y < 0.0:
			p.y = float(d["floor"])
			v = Vector3(v.x * 0.6, -v.y * BOUNCE, v.z * 0.6)
		d["pos"] = p
		d["vel"] = v
		var t: float = float(d["age"]) / LIFE
		var alpha: float = 1.0 - smoothstep(0.6, 1.0, t)
		mm.set_instance_transform(slot, Transform3D(Basis.from_scale(Vector3.ONE * SIZE), p))
		mm.set_instance_custom_data(slot, Color(alpha, float(d["seed"]), 0, 0))
	if _live.is_empty():
		mm.visible_instance_count = 0
		set_process(false)
