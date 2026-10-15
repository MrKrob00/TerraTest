extends Node3D
## THE PLANETFALL INTRO (the player's call, after TerraTech's opening): a NEW world opens on the drop
## capsule falling burning out of the sky. Played once by world_persist._fresh_start, after the loading
## screen starts to dissolve; a tap skips it. Nothing here is saved and nothing here is physics: the
## capsule, the WORLDTECH sign and the debris are pictures on our own camera, and the world they fall
## into is the real one - the player's cabin stands hidden on its start point (meta `intro_hidden`,
## which world_persist's culling pass honours) until the last piece of debris lands on it.
##
## The shots, on one clock (T_*), cut like a film - the capsule's path is one straight line, every
## shot puts the camera where that line looks best:
##   0     chase from below, the capsule against the sky, heat on its nose     "...planetfall stage."
##   4     the other side                                                      "...stage two."
##   5.6   a burnt piece of something crosses it: sparks, then smoke
##   7.6   chase, burning, a smoke trail                                       "Payload failure..."
##   11    a fixed camera it whips past                                        "Crash landing imminent..."
##   12.6  the WORLDTECH sign in the sky; it crosses in front and blows up     "Brace! Brace! BRACE!"
##   16.4  the meadow: three burning pieces fall trailing smoke, the last onto the start point -
##         the smouldering ground (crash_site.gd), the cabin glitches in, the kit drops
##   20.8  the camera glides into the game camera behind the cabin; the HUD comes back
##
## NO PARTICLES (CLAUDE.md rule 11): smoke is a MultiMesh of pixel cards (resources/intro/
## smoke_card.gdshader), fire and sparks are BlockFX glitch cards, the speed streaks crossed strips.

signal finished

const POD_MESH := preload("res://resources/intro/intro_capsule.tres")
const LOGO_MESH := preload("res://resources/intro/intro_logo.tres")
const HEAT_SHADER := preload("res://resources/intro/pod_heat.gdshader")
const SMOKE_SHADER := preload("res://resources/intro/smoke_card.gdshader")
const STREAK_SHADER := preload("res://resources/intro/streak.gdshader")
const BLOCK_SCENE := "res://blocks/scenes/block.tscn"
const ATLAS := preload("res://objects/Assets_main_texture_new.png")

const T_STAGE2 := 4.0
const T_HIT := 5.6            # the passing debris strikes the capsule
const T_CHASE := 7.6
const T_PASS := 11.0          # the fixed camera it whips past
const T_LOGO := 12.6          # the sign
const T_BOOM := 15.6          # blows up in front of it
const T_GROUND := 16.4        # the meadow
const T_LAND := [19.4, 19.8, 20.3]   # the debris lands; MAIN lands on the start point
const MAIN := 1
const T_HANDOVER := 20.8
const T_END := 23.0
const SKIP_AFTER := 0.8       # a tap before this is the one that closed the loading screen

const SPEED := 62.0           # the capsule's speed along its line, m/s
const DIVE := 1.9             # how steep the line falls: vertical per horizontal
const BOOM_BACK := 140.0      # the explosion: this far back from the start point
const BOOM_UP := 240.0        # and this high over it
const LOGO_SCALE := 7.0       # the sign's model is 11.75 m wide
const DEBRIS_SPREAD := 20.0

const LINES := [
	[0.4, "Falsus deployment unit FX-2041 entering planetfall stage."],
	[T_STAGE2, "Entering planetfall stage two."],
	[T_CHASE, "Warning! Payload failure on survey mission Alpha #812311."],
	[T_PASS, "Crash landing imminent. Initiating emergency salvage protocol."],
	[13.4, "Brace! Brace! BRACE!"],
]

const FIRE_A := Color(1.0, 0.34, 0.06)
const FIRE_B := Color(1.0, 0.8, 0.25)
const SPARK_A := Color(1.0, 0.95, 0.8)
const SPARK_B := Color(0.6, 0.85, 1.0)

const SMOKE_CAP := 1024
const STREAKS := 28

var _t: float = 0.0
var _running: bool = false
var _done: bool = false
var _s := Vector3.ZERO          # the start point on the ground
var _f := Vector3.FORWARD       # the fall's heading, horizontal
var _n := Vector3.RIGHT         # its side
var _d := Vector3.DOWN          # the capsule's direction of flight
var _p_end := Vector3.ZERO      # where it blows up
var _machine: Node3D = null
var _game_cam: Camera3D = null
var _hidden_ui: Array = []      # the world's UI layers this intro hid (untyped: rule 4)
var _ui_t: float = 0.0
var _cam: Camera3D
var _pod: Node3D                # oriented along the flight, never rolled
var _pod_mesh: MeshInstance3D   # rolls inside it
var _heat_mats: Array = []
var _streaks: MultiMeshInstance3D
var _streak_y := PackedFloat32Array()
var _streak_xz := PackedVector2Array()
var _logo: MeshInstance3D
var _hitter: Node3D = null
var _debris: Array = []         # {node, to, h, hor, t1, spin, landed, emit}
var _burnt_mat: StandardMaterial3D
var _block_mesh: Mesh
var _shake: float = 0.0
var _fire_t: float = 0.0
var _emit_from := Vector3.ZERO
var _said: int = 0
var _landed_main: bool = false
var _kit_given: bool = false
var _skip_lbl: Label = null
var _cam_e := Transform3D()     # the meadow shot's pose, where the hand-over starts from

# smoke: one MultiMesh of pixel cards in world space
var _sm: MultiMeshInstance3D
var _sp := PackedVector3Array()
var _sv := PackedVector3Array()
var _sb := PackedFloat32Array()   # birth
var _sl := PackedFloat32Array()   # life
var _s0 := PackedFloat32Array()   # size at birth
var _s1 := PackedFloat32Array()   # size at death
var _sh := PackedFloat32Array()   # heat
var _ss := PackedFloat32Array()   # seed
var _so := PackedFloat32Array()   # opacity
var _sbuf := PackedFloat32Array()

## Hide the machine, wait for the loading screen to start dissolving, play. The caller awaits
## `finished` and then lays the crash site and the kit itself unless `landed` says it was done here.
static func make(parent: Node, at: Vector3, machine: Node3D) -> Node3D:
	var p: Node3D = load("res://planetfall.gd").new()
	p.name = "Planetfall"
	parent.add_child(p)
	p.call("_begin", at, machine)
	return p

func _begin(at: Vector3, machine: Node3D) -> void:
	_s = at
	_machine = machine
	if is_instance_valid(_machine):
		_machine.set_meta("intro_hidden", true)
		_machine.visible = false
		if _machine is RigidBody3D:
			(_machine as RigidBody3D).freeze = true
	# the heading is the seed's: one world always falls the same way
	var a: float = float(absi(G.world_seed) % 360) * PI / 180.0
	_f = Vector3(cos(a), 0.0, sin(a))
	_n = _f.cross(Vector3.UP).normalized()
	_d = (_f + Vector3.DOWN * DIVE).normalized()
	_p_end = _s - _f * BOOM_BACK + Vector3.UP * BOOM_UP
	set_process(false)
	await _wait_for_screen()
	if not is_inside_tree():
		return
	_build()
	_running = true
	set_process(true)

func _wait_for_screen() -> void:
	var guard: int = 0
	while guard < 3600:
		var ls: Node = get_tree().get_first_node_in_group("loading_screen")
		if ls == null:
			return
		var dv = ls.get("_dissolve")
		if dv is float and dv > 0.0:
			return
		await get_tree().process_frame
		guard += 1

func _build() -> void:
	Dialogue.clear()
	var cc: Node = get_tree().get_first_node_in_group("camera_controller")
	if cc != null:
		var c = cc.get("camera")
		_game_cam = c if c is Camera3D else null
	_hide_ui()
	_cam = Camera3D.new()
	_cam.fov = 58.0
	_cam.far = 4000.0
	add_child(_cam)
	_cam.current = true
	_cam.environment = _intro_env()
	_burnt_mat = StandardMaterial3D.new()
	_burnt_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_burnt_mat.albedo_texture = ATLAS
	_burnt_mat.albedo_color = Color(0.16, 0.14, 0.13)
	_burnt_mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	_block_mesh = _first_mesh(BLOCK_SCENE)
	_build_pod()
	_build_logo()
	_build_smoke()
	_build_skip_hint()
	_place_camera(0.0)

## The world's environment with the sky's LOWER HALF in the haze's colour: from hundreds of metres up
## the camera sees ground the terrain has not built yet (it builds round the game camera, and the far
## rings take seconds), and through those holes the sky's lower half shows - dark on purpose in the
## game (a hole in the ground must not read as sky), here it reads as horizon. Frozen at the moment
## the intro starts; day_cycle keeps the world's own copy moving.
func _intro_env() -> Environment:
	var we: Node = get_parent().find_child("WorldEnvironment", false, false) if get_parent() != null else null
	if not (we is WorldEnvironment) or (we as WorldEnvironment).environment == null:
		return null
	var env: Environment = (we as WorldEnvironment).environment.duplicate()
	if env.sky != null and env.sky.sky_material is ShaderMaterial:
		var sky: Sky = env.sky.duplicate()
		var mat: ShaderMaterial = (env.sky.sky_material as ShaderMaterial).duplicate()
		var dc: Node = get_parent().find_child("DayCycle", false, false)
		var hz = dc.get("haze_now") if dc != null else null
		var c: Color = hz if hz is Color else Color(0.75, 0.72, 0.66)
		mat.set_shader_parameter("ground_bottom", c * 0.92)
		mat.set_shader_parameter("ground_horizon", c)
		sky.sky_material = mat
		env.sky = sky
	return env

func _first_mesh(path: String) -> Mesh:
	var ps: PackedScene = load(path)
	if ps == null:
		return BoxMesh.new()
	var inst: Node = ps.instantiate()
	var m: Mesh = null
	for c in inst.find_children("*", "MeshInstance3D", true, false):
		if (c as MeshInstance3D).mesh != null:
			m = (c as MeshInstance3D).mesh
			break
	inst.free()
	return m if m != null else BoxMesh.new()

func _pod_at(t: float) -> Vector3:
	return _p_end + _d * SPEED * (t - T_BOOM)

func _build_pod() -> void:
	_pod = Node3D.new()
	add_child(_pod)
	_pod.global_transform = Transform3D(Basis(_n, -_d, _n.cross(-_d)), _pod_at(0.0))
	_pod_mesh = MeshInstance3D.new()
	_pod_mesh.mesh = POD_MESH
	_pod_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_pod.add_child(_pod_mesh)
	# two shells of heat on the nose: a hot one hugging it and a wide pale halo
	# (the nose's dome ends at y -2.25, the body's cylinder of radius 0.66 above it: art/intro_models.py)
	for spec in [[Vector3(0.78, 0.95, 0.78), -1.55, 0.55, Color(1.0, 0.86, 0.55), Color(1.0, 0.38, 0.08), 1.0],
			[Vector3(1.4, 2.0, 1.4), -1.3, 0.5, Color(1.0, 0.97, 0.9), Color(1.0, 0.6, 0.3), 0.55]]:
		var sm := SphereMesh.new()
		sm.radius = 1.0
		sm.height = 2.0
		sm.radial_segments = 18
		sm.rings = 9
		var mat := ShaderMaterial.new()
		mat.shader = HEAT_SHADER
		mat.set_shader_parameter("reach", spec[2])
		mat.set_shader_parameter("hot", spec[3])
		mat.set_shader_parameter("edge", spec[4])
		mat.set_shader_parameter("heat", spec[5])
		mat.set_meta("base", spec[5])
		var mi := MeshInstance3D.new()
		mi.mesh = sm
		mi.material_override = mat
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.position = Vector3(0.0, spec[1], 0.0)
		mi.scale = spec[0]
		_pod.add_child(mi)
		_heat_mats.append(mat)
	# speed streaks: crossed strips in the capsule's frame, rushing nose to tail
	var strip := ArrayMesh.new()
	var v := PackedVector3Array()
	var uv := PackedVector2Array()
	for k in 2:
		var ax: Vector3 = Vector3(0.04, 0, 0) if k == 0 else Vector3(0, 0, 0.04)
		var l: float = 2.6
		v.append_array([-ax + Vector3(0, -l, 0), ax + Vector3(0, -l, 0), ax + Vector3(0, l, 0),
				-ax + Vector3(0, -l, 0), ax + Vector3(0, l, 0), -ax + Vector3(0, l, 0)])
		uv.append_array([Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 0), Vector2(1, 1), Vector2(0, 1)])
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = v
	arr[Mesh.ARRAY_TEX_UV] = uv
	strip.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	var smat := ShaderMaterial.new()
	smat.shader = STREAK_SHADER
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_custom_data = true
	mm.mesh = strip
	mm.instance_count = STREAKS
	_streaks = MultiMeshInstance3D.new()
	_streaks.multimesh = mm
	_streaks.material_override = smat
	_streaks.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_streaks.custom_aabb = AABB(Vector3(-8, -12, -8), Vector3(16, 32, 16))
	_pod.add_child(_streaks)
	for i in STREAKS:
		var a: float = randf() * TAU
		var r: float = randf_range(1.4, 5.0)
		_streak_xz.append(Vector2(cos(a) * r, sin(a) * r))
		_streak_y.append(randf_range(-8.0, 16.0))

func _build_logo() -> void:
	_logo = MeshInstance3D.new()
	_logo.mesh = LOGO_MESH
	_logo.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_logo)
	var mid: Vector3 = _pod_at(T_BOOM - 0.6)
	var at: Vector3 = mid - _n * 45.0 + Vector3.UP * 8.0
	var cam: Vector3 = _logo_cam()
	var face: Vector3 = (cam - at)
	face.y = 0.0
	face = face.normalized()
	_logo.global_transform = Transform3D(Basis(Vector3.UP.cross(face).normalized(), Vector3.UP, face) \
			.scaled(Vector3.ONE * LOGO_SCALE), at)
	_logo.visible = false

func _logo_cam() -> Vector3:
	return _pod_at(T_BOOM - 0.6) + _n * 55.0 + Vector3.DOWN * 4.0

func _build_smoke() -> void:
	var q := QuadMesh.new()
	q.size = Vector2.ONE
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_custom_data = true
	mm.mesh = q
	mm.instance_count = SMOKE_CAP
	mm.visible_instance_count = 0
	var mat := ShaderMaterial.new()
	mat.shader = SMOKE_SHADER
	_sm = MultiMeshInstance3D.new()
	_sm.multimesh = mm
	_sm.material_override = mat
	_sm.top_level = true
	_sm.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_sm)
	_sbuf.resize(SMOKE_CAP * 16)

func _build_skip_hint() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 95
	add_child(layer)
	_skip_lbl = Label.new()
	_skip_lbl.text = tr("Tap to skip")
	_skip_lbl.add_theme_font_size_override("font_size", 15)
	_skip_lbl.modulate = Color(1, 1, 1, 0.0)
	_skip_lbl.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT)
	_skip_lbl.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_skip_lbl.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_skip_lbl.offset_right = -16.0
	_skip_lbl.offset_bottom = -26.0
	layer.add_child(_skip_lbl)

## EVERY UI LAYER OF THE WORLD GOES, NOT ONLY THE HUD (the player: "the quests stayed up"): the quest
## tracker, the compass, the licence card and the FPS counter are canvas layers of their own, some of
## them made later and some showing themselves again, so the scene is swept again every UI_SWEEP
## while the intro runs. Dialogue is an autoload outside the scene and keeps its lines on screen.
const UI_SWEEP := 0.25

func _hide_ui() -> void:
	var scn: Node = get_tree().current_scene
	if scn == null:
		return
	for n in scn.find_children("*", "CanvasLayer", true, false):
		var l := n as CanvasLayer
		if l == null or is_ancestor_of(l) or not l.visible:
			continue
		l.visible = false
		if not _hidden_ui.has(l):
			_hidden_ui.append(l)

func _show_ui() -> void:
	for l in _hidden_ui:
		if is_instance_valid(l):
			(l as CanvasLayer).visible = true
	_hidden_ui.clear()

# ── the clock ───────────────────────────────────────────────────────────────────────────────────

func _process(delta: float) -> void:
	if _running:
		_t += delta
		_lines()
		_ui_t -= delta
		if _ui_t <= 0.0:
			_ui_t = UI_SWEEP
			_hide_ui()
		_tick_pod(delta)
		_tick_hitter()
		_tick_debris(delta)
		if is_instance_valid(_skip_lbl):
			_skip_lbl.modulate.a = clampf((_t - 1.5) * 2.0, 0.0, 0.55) * (1.0 - clampf((_t - (T_END - 1.5)) * 2.0, 0.0, 1.0))
		_place_camera(delta)
		if _t >= T_END:
			_finish()
	_tick_smoke()
	if _done and _sp.is_empty():
		queue_free()

func _lines() -> void:
	while _said < LINES.size() and _t >= float(LINES[_said][0]):
		var nxt: float = float(LINES[_said + 1][0]) if _said + 1 < LINES.size() else _t + 2.6
		Dialogue.say("System", tr(String(LINES[_said][1])), maxf(nxt - float(LINES[_said][0]) - 0.15, 1.2))
		_said += 1

func _input(event: InputEvent) -> void:
	if not _running:
		return
	# nothing under the intro hears a finger: the hidden machine would build, the camera would turn
	var tap_end: bool = (event is InputEventScreenTouch and not (event as InputEventScreenTouch).pressed) \
			or (event is InputEventMouseButton and not (event as InputEventMouseButton).pressed)
	if event is InputEventScreenTouch or event is InputEventScreenDrag or event is InputEventMouseButton \
			or event is InputEventMouseMotion:
		get_viewport().set_input_as_handled()
	if tap_end and _t > SKIP_AFTER:
		_skip()

# ── the capsule ─────────────────────────────────────────────────────────────────────────────────

func _tick_pod(delta: float) -> void:
	if not is_instance_valid(_pod) or not _pod.visible:
		return
	if _t >= T_BOOM:
		_explode()
		return
	var at: Vector3 = _pod_at(_t)
	_pod.global_position = at
	# a slow roll, faster and wobbling once it is hit
	var hit: bool = _t >= T_HIT
	_pod_mesh.rotate_y(delta * (0.6 if not hit else 2.4))
	if hit:
		var w: float = sin(_t * 7.0) * 0.08
		_pod_mesh.rotation.x = w
		_pod_mesh.rotation.z = cos(_t * 5.3) * 0.08
	var heat: float = clampf(_t / 1.2, 0.0, 1.0) * (1.25 if hit else 1.0)
	for m in _heat_mats:
		(m as ShaderMaterial).set_shader_parameter("heat", float((m as ShaderMaterial).get_meta("base")) * heat)
	_tick_streaks(delta)
	if hit:
		_fire_t -= delta
		if _fire_t <= 0.0:
			_fire_t = 0.11
			var off: Vector3 = _pod.global_basis * Vector3(randf_range(-0.6, 0.6), randf_range(-1.8, 0.3), randf_range(-0.6, 0.6))
			BlockFX.blast_cards(_pod, at + off, randf_range(0.9, 1.5), FIRE_A, FIRE_B, 9, 0.4)
		_trail(at, 1.6, 1.8, 8.0, 4.2, 1.0, 0.9)
	else:
		_emit_from = at

## Puffs every `step` metres along the path walked since the last call.
func _trail(at: Vector3, step: float, s0: float, s1: float, life: float, heat: float, op: float) -> void:
	var gap: float = _emit_from.distance_to(at)
	if gap > 200.0:
		_emit_from = at
		return
	while gap >= step:
		_emit_from = _emit_from.move_toward(at, step)
		gap -= step
		var jit := Vector3(randf_range(-0.5, 0.5), randf_range(-0.5, 0.5), randf_range(-0.5, 0.5))
		_puff(_emit_from + jit, jit * 2.0 + Vector3.UP * 1.5, s0, s1, life, heat, op)

func _tick_streaks(delta: float) -> void:
	var mm := _streaks.multimesh
	for i in STREAKS:
		var y: float = _streak_y[i] + delta * 75.0
		if y > 16.0:
			y = -8.0
			var a: float = randf() * TAU
			var r: float = randf_range(1.4, 5.0)
			_streak_xz[i] = Vector2(cos(a) * r, sin(a) * r)
		_streak_y[i] = y
		var p: Vector2 = _streak_xz[i]
		mm.set_instance_transform(i, Transform3D(Basis(), Vector3(p.x, y, p.y)))
		var b: float = (1.0 - absf((y - 4.0) / 12.0)) * 0.8
		mm.set_instance_custom_data(i, Color(b, 0, 0, 0))

func _tick_hitter() -> void:
	# the burnt thing that clips the capsule: it crosses from the side in 0.6 s
	var t0: float = T_HIT - 0.35
	var t1: float = T_HIT + 0.35
	if _t < t0 - 0.05:
		return
	if _hitter == null and _t < t1:
		_hitter = _chunk(5, 2.2)
		add_child(_hitter)
	if _hitter == null or not is_instance_valid(_hitter):
		return
	var k: float = (_t - t0) / (t1 - t0)
	var c: Vector3 = _pod_at(T_HIT)
	var from: Vector3 = c + _n * 70.0 - _d * 8.0 + Vector3.UP * 3.0
	var to: Vector3 = c - _n * 70.0 + _d * 14.0
	_hitter.global_position = from.lerp(to, k) + _d * SPEED * (_t - T_HIT)
	_hitter.rotate(Vector3(0.3, 1, 0.2).normalized(), 0.12)
	if k >= 0.5 and not _hitter.has_meta("struck"):
		_hitter.set_meta("struck", true)
		_shake = 0.9
		var at: Vector3 = _pod_at(_t)
		BlockFX.blast_cards(self, at + _n * 0.8, 3.2, SPARK_A, SPARK_B, 40, 0.5)
		BlockFX.blast_cards(_pod, at, 1.8, FIRE_A, FIRE_B, 24, 0.6)
		_emit_from = at
	if k >= 1.0:
		_hitter.queue_free()
		_hitter = null

func _explode() -> void:
	_pod.visible = false
	_shake = 1.4
	BlockFX.blast_cards(self, _p_end, 10.0, BlockFX.BLAST_A, BlockFX.BLAST_B, 70, 1.0)
	BlockFX.blast_cards(self, _p_end + _n * 3.0, 6.0, FIRE_A, FIRE_B, 40, 0.8)
	for i in 34:
		var dir := Vector3(randf() - 0.5, randf() - 0.5, randf() - 0.5).normalized()
		_puff(_p_end + dir * randf_range(0.0, 5.0), dir * randf_range(4.0, 11.0) + _d * 8.0,
				randf_range(4.0, 6.0), randf_range(11.0, 16.0), randf_range(3.5, 5.0), 1.0, 0.95)
	var targets: Array = [_s + _n * DEBRIS_SPREAD - _f * 8.0, _s, _s - _n * (DEBRIS_SPREAD * 0.9) + _f * 10.0]
	for i in targets.size():
		var to: Vector3 = targets[i]
		to.y = G.ground_y(to, _s.y)
		var node: Node3D = _chunk(3 if i == MAIN else 2, 1.1 if i == MAIN else 0.9)
		add_child(node)
		node.global_position = _p_end
		var hor: Vector3 = _p_end - to
		hor.y = 0.0
		hor += Vector3(randf_range(-20, 20), 0, randf_range(-20, 20))
		_debris.append({"node": node, "to": to, "h": _p_end.y - to.y, "hor": hor, "t1": float(T_LAND[i]),
				"spin": Vector3(randf() - 0.5, randf() - 0.5, randf() - 0.5).normalized(),
				"landed": false, "emit": _p_end, "fire": 0.0, "main": i == MAIN})

## A burnt lump of `n` blackened Falsus blocks, `size` metres a block, and a small heat shell.
func _chunk(n: int, size: float) -> Node3D:
	var root := Node3D.new()
	for i in n:
		var mi := MeshInstance3D.new()
		mi.mesh = _block_mesh
		mi.material_override = _burnt_mat
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.position = Vector3(randf_range(-0.5, 0.5), randf_range(-0.5, 0.5), randf_range(-0.5, 0.5)) * size * (0.0 if i == 0 else 1.2)
		mi.rotation = Vector3(randf() * TAU, randf() * TAU, randf() * TAU)
		mi.scale = Vector3.ONE * size * randf_range(0.8, 1.15)
		root.add_child(mi)
	var sm := SphereMesh.new()
	sm.radial_segments = 12
	sm.rings = 6
	var mat := ShaderMaterial.new()
	mat.shader = HEAT_SHADER
	mat.set_shader_parameter("reach", 1.0)
	mat.set_shader_parameter("heat", 0.7)
	var glow := MeshInstance3D.new()
	glow.mesh = sm
	glow.material_override = mat
	glow.scale = Vector3.ONE * size * 1.3
	glow.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	glow.set_meta("glow", true)
	root.add_child(glow)
	return root

## Where piece `i` is at time t: down at a steady speed, its sideways drift dying off as the cube of
## what is left, so the last part of every fall - the smoke column - is near vertical.
func _debris_at(i: int, t: float) -> Vector3:
	if i >= _debris.size():
		return _s + Vector3.UP * 60.0
	var d: Dictionary = _debris[i]
	var k: float = clampf((t - T_BOOM) / (float(d["t1"]) - T_BOOM), 0.0, 1.0)
	return (d["to"] as Vector3) + Vector3.UP * (float(d["h"]) * (1.0 - k) + 0.6) + (d["hor"] as Vector3) * pow(1.0 - k, 3.0)

func _tick_debris(delta: float) -> void:
	for d in _debris:
		# untyped: the main piece is freed on landing, and a freed node assigned to a typed local is
		# an error (CLAUDE.md rule 4)
		var node = d["node"]
		if d["landed"] or not is_instance_valid(node):
			continue
		var k: float = clampf((_t - T_BOOM) / (float(d["t1"]) - T_BOOM), 0.0, 1.0)
		var to: Vector3 = d["to"]
		var at: Vector3 = _debris_at(_debris.find(d), _t)
		node.global_position = at
		node.rotate(d["spin"], delta * 4.0)
		d["fire"] = float(d["fire"]) - delta
		if float(d["fire"]) <= 0.0:
			d["fire"] = 0.14
			BlockFX.blast_cards(node, at, randf_range(0.8, 1.3), FIRE_A, FIRE_B, 6, 0.35)
		var from: Vector3 = d["emit"]
		var gap: float = from.distance_to(at)
		while gap >= 1.6:
			from = from.move_toward(at, 1.6)
			gap -= 1.6
			# the column's foot goes first: low puffs would sit over the cabin as the camera comes in
			var low: float = clampf((from.y - to.y) / 40.0, 0.0, 1.0)
			_puff(from, Vector3(randf_range(-0.6, 0.6), 2.5, randf_range(-0.6, 0.6)), 2.0, 6.5,
					lerpf(1.8, 6.5, low), 0.8, 0.85)
		d["emit"] = from
		if k >= 1.0:
			_land(d)

func _land(d: Dictionary) -> void:
	d["landed"] = true
	var node = d["node"]
	var to: Vector3 = d["to"]
	if not is_instance_valid(node):
		return
	_shake = maxf(_shake, 1.0 if d["main"] else 0.5)
	BlockFX.blast_cards(self, to + Vector3.UP * 1.2, 4.0 if d["main"] else 2.6, BlockFX.BLAST_A, BlockFX.BLAST_B, 40, 0.7)
	BlockFX.ground_wave(self, to, Vector3.UP, 30.0)
	for i in 8:
		var dir := Vector3(randf() - 0.5, randf() * 0.6, randf() - 0.5).normalized()
		_puff(to + dir * 1.5, dir * randf_range(2.0, 6.0) + Vector3.UP * 4.0, 1.6, 5.5, randf_range(1.4, 2.2), 0.9, 0.75)
	if d["main"]:
		node.queue_free()
		_lay_site()
	else:
		# what is left lies by the site, half sunk, burnt: it stays with the site, not with the intro
		for c in node.get_children():
			if c.has_meta("glow"):
				c.queue_free()
		node.global_position = to + Vector3.DOWN * 0.3
		var site: Node = get_tree().get_first_node_in_group("crash_site")
		if site != null:
			node.reparent(site, true)

## The start point's own ending: the smouldering ground, the cabin glitching in, the kit.
func _lay_site() -> void:
	if _landed_main:
		return
	_landed_main = true
	var host: Node = get_parent()
	if host != null:
		load("res://crash_site.gd").make(host, _s)
	if is_instance_valid(_machine):
		_machine.remove_meta("intro_hidden")
		_machine.visible = true
		if _machine is RigidBody3D:
			(_machine as RigidBody3D).freeze = false
		# its own glitch, not BlockFX.materialise: that one sizes its cards by every child of the
		# machine's `blocks`, and on the player's cabin they came out as 20 m panels over the screen
		BlockFX.blast_cards(_machine, _machine.global_position + Vector3.UP * 0.6, 1.8, BlockFX.SPARK_A,
				BlockFX.SPARK_B, 26, 0.9)
	# the other pieces that already landed lie by the site
	var site: Node = get_tree().get_first_node_in_group("crash_site")
	for d in _debris:
		if d["landed"] and not d["main"] and is_instance_valid(d["node"]) and site != null \
				and (d["node"] as Node).get_parent() == self:
			(d["node"] as Node).reparent(site, true)

func _give_kit() -> void:
	if _kit_given:
		return
	_kit_given = true
	if is_instance_valid(_machine) and _machine.has_method("award_block_list"):
		_machine.award_block_list(G.STARTER_KIT)

# ── the camera ──────────────────────────────────────────────────────────────────────────────────

func _place_camera(delta: float) -> void:
	if not is_instance_valid(_cam) or not _cam.current:
		return
	var x: Transform3D = _shot(_t)
	if _shake > 0.0:
		x.origin += Vector3(randf() - 0.5, randf() - 0.5, randf() - 0.5) * _shake * 0.9
		_shake = maxf(_shake - delta * 2.2, 0.0)
	_cam.global_transform = x

func _look(from: Vector3, at: Vector3) -> Transform3D:
	var dir: Vector3 = at - from
	var up: Vector3 = Vector3.UP if absf(dir.normalized().dot(Vector3.UP)) < 0.97 else _f
	return Transform3D(Basis.looking_at(dir, up), from)

func _shot(t: float) -> Transform3D:
	var pod: Vector3 = _pod_at(minf(t, T_BOOM))
	if t < T_STAGE2:
		var a: float = t * 0.08
		var side: Vector3 = (_n * cos(a) + _f * sin(a)).normalized()
		return _look(pod + _d * 15.0 + side * 8.0 + Vector3.UP * 1.0, pod + _d * -1.0)
	if t < T_CHASE:
		return _look(pod + _d * 12.0 - _n * 8.5 + Vector3.UP * 2.5, pod)
	if t < T_PASS:
		var a2: float = (t - T_CHASE) * 0.12
		var side2: Vector3 = (_n * cos(a2) - _f * sin(a2)).normalized()
		return _look(pod + _d * 19.0 + side2 * 6.0 - Vector3.UP * 1.0, pod - _d * 1.5)
	if t < T_LOGO:
		# it passes closest just before the cut: after that the camera would look down on it, at the
		# ground the far terrain has not built yet
		var fixed: Vector3 = _pod_at(T_LOGO - 0.1) + _n * 11.0 + _f * 3.0 + Vector3.DOWN * 4.0
		return _look(fixed, pod)
	if t < T_GROUND:
		if is_instance_valid(_logo):
			_logo.visible = true
		var c: Vector3 = _logo_cam()
		var drift: float = (t - T_LOGO) * 1.2
		return _look(c - _n * drift, _pod_at(T_BOOM - 0.6) + Vector3.DOWN * 7.0)
	if is_instance_valid(_logo) and _logo.visible:
		_logo.queue_free()
	# far enough back to see the pieces high up as the shot opens, tilting down with the main one
	var cam_e: Vector3 = _s - _f * 50.0 + _n * 45.0
	cam_e.y = maxf(_s.y + 16.0, G.ground_y(cam_e, _s.y) + 6.0)
	# the camera follows the main piece down out of the smoke cloud, and settles on the start point
	var target: Vector3 = _s + Vector3.UP * 2.0
	if t < float(T_LAND[MAIN]):
		var fall: Vector3 = _debris_at(MAIN, t)
		target = fall.lerp(target, smoothstep(float(T_LAND[MAIN]) - 0.9, float(T_LAND[MAIN]), t))
	var e: Transform3D = _look(cam_e, target)
	if t < T_HANDOVER:
		_cam_e = e
		return e
	if not is_instance_valid(_game_cam):
		return e
	_give_kit()
	var h: float = smoothstep(T_HANDOVER, T_END, t)
	return e.interpolate_with(_game_cam.global_transform, h)

# ── smoke ───────────────────────────────────────────────────────────────────────────────────────

func _puff(at: Vector3, vel: Vector3, s0: float, s1: float, life: float, heat: float, op: float) -> void:
	if _sp.size() >= SMOKE_CAP:
		_kill_puff(0)
	_sp.append(at)
	_sv.append(vel)
	_sb.append(_t)
	_sl.append(life)
	_s0.append(s0)
	_s1.append(s1)
	_sh.append(heat)
	_ss.append(randf() * 100.0)
	_so.append(op)

func _kill_puff(i: int) -> void:
	var last: int = _sp.size() - 1
	if i != last:
		_sp[i] = _sp[last]
		_sv[i] = _sv[last]
		_sb[i] = _sb[last]
		_sl[i] = _sl[last]
		_s0[i] = _s0[last]
		_s1[i] = _s1[last]
		_sh[i] = _sh[last]
		_ss[i] = _ss[last]
		_so[i] = _so[last]
	_sp.resize(last)
	_sv.resize(last)
	_sb.resize(last)
	_sl.resize(last)
	_s0.resize(last)
	_s1.resize(last)
	_sh.resize(last)
	_ss.resize(last)
	_so.resize(last)

func _tick_smoke() -> void:
	if not is_instance_valid(_sm):
		return
	var dt: float = get_process_delta_time()
	if _done:
		_t += dt                    # the clock runs on for the smoke after the hand-over
	var i: int = 0
	while i < _sp.size():
		if _t - _sb[i] >= _sl[i]:
			_kill_puff(i)
			continue
		_sp[i] += _sv[i] * dt
		_sv[i] *= 1.0 - minf(dt * 0.8, 0.5)
		i += 1
	var n: int = _sp.size()
	var lo := Vector3(INF, INF, INF)
	var hi := -lo
	for k in n:
		var age: float = (_t - _sb[k]) / _sl[k]
		var s: float = lerpf(_s0[k], _s1[k], sqrt(age))
		var p: Vector3 = _sp[k]
		var o: int = k * 16
		_sbuf[o] = s
		_sbuf[o + 1] = 0.0
		_sbuf[o + 2] = 0.0
		_sbuf[o + 3] = p.x
		_sbuf[o + 4] = 0.0
		_sbuf[o + 5] = s
		_sbuf[o + 6] = 0.0
		_sbuf[o + 7] = p.y
		_sbuf[o + 8] = 0.0
		_sbuf[o + 9] = 0.0
		_sbuf[o + 10] = s
		_sbuf[o + 11] = p.z
		_sbuf[o + 12] = _ss[k]
		_sbuf[o + 13] = age
		_sbuf[o + 14] = _sh[k]
		_sbuf[o + 15] = _so[k]
		lo = lo.min(p - Vector3.ONE * s)
		hi = hi.max(p + Vector3.ONE * s)
	_sm.multimesh.buffer = _sbuf
	_sm.multimesh.visible_instance_count = n
	_sm.visible = n > 0
	if n > 0:
		_sm.custom_aabb = AABB(lo, hi - lo)

# ── the end ─────────────────────────────────────────────────────────────────────────────────────

func _skip() -> void:
	Dialogue.clear()
	if is_instance_valid(_pod):
		_pod.queue_free()
	if is_instance_valid(_hitter):
		_hitter.queue_free()
	if is_instance_valid(_logo):
		_logo.queue_free()
	for d in _debris:
		if not d["landed"] and is_instance_valid(d["node"]):
			(d["node"] as Node).queue_free()
	_debris.clear()
	_sp.clear()
	_sv.clear()
	_sb.clear()
	_sl.clear()
	_s0.clear()
	_s1.clear()
	_sh.clear()
	_ss.clear()
	_so.clear()
	_lay_site()
	_give_kit()
	_finish()

func _finish() -> void:
	if _done:
		return
	_done = true
	_running = false
	if is_instance_valid(_game_cam):
		_game_cam.current = true
	if is_instance_valid(_cam):
		_cam.queue_free()
	_show_ui()
	if is_instance_valid(_skip_lbl):
		_skip_lbl.get_parent().queue_free()
	_lay_site()
	_give_kit()
	var q: Node = get_node_or_null("/root/Q")
	if q != null and q.has_method("announce_start"):
		q.announce_start()
	finished.emit()

func _exit_tree() -> void:
	_show_ui()
	# a scene change mid-intro must not leave the cabin hidden in a world that outlives us
	if is_instance_valid(_machine) and _machine.has_meta("intro_hidden"):
		_machine.remove_meta("intro_hidden")
		_machine.visible = true
