extends Node3D
## A RACE TRACK: a row of gates driven through in order against the clock (Aero's races, after
## TerraTech's Venture: Race Against Time, Plateau Run, the race events). The gates are STUBS (the
## player's call: no roads or checkpoints in the game yet, so a frame GATE_W wide and GATE_H tall):
## two posts and a bar, no collider - a machine that clips a post drives on, nobody is stuck on a
## prop. Gate 0 is the start: driving through it starts the clock, and so does driving through it
## again after a failed run - the track stays where it is, there is nothing to ask for. The next gate
## is lit, the rest dim. A gate is passed when the player's machine CROSSES its plane between the
## posts (the segment from last tick's position to this one, so no speed steps over it). The clock
## and the count show at the top of the screen while a run is on.
##
## Placed by quest_arcs (`setup`), saved by world_persist once it is a track the player keeps
## (`keep` - Race Against Time leaves its course in the world as TerraTech's did).

signal finished(seconds: float)
signal failed
signal started

const GATE_W := 10.0
const GATE_H := 7.0
const POST := 0.6
## Slack round the frame for "went through it": the machine's origin is its cabin, not its hull.
const PASS_SLACK := 1.5

var points: Array = []            # ground points, gate 0 the start
var time_limit: float = 60.0
var keep: bool = false            # stays in the world (and the save) after its quest
var best: float = -1.0

var _gates: Array = []            # Node3D per gate
var _mats: Dictionary = {}
var _next: int = -1               # -1: waiting at the start
var _t: float = 0.0
var _last: Vector3 = Vector3.INF
var _hud: CanvasLayer = null
var _label: Label = null

func setup(pts: Array, limit: float) -> void:
	points = pts.duplicate()
	time_limit = limit
	for g in _gates:
		(g as Node).queue_free()
	_gates.clear()
	for i in points.size():
		_gates.append(_make_gate(i))
	_paint()

func _ready() -> void:
	add_to_group("race_tracks")
	for k in ["start", "next", "dim"]:
		var m := StandardMaterial3D.new()
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		m.albedo_color = {"start": Color(1.0, 0.62, 0.18), "next": Color(0.35, 0.95, 1.0),
				"dim": Color(0.32, 0.34, 0.4)}[k]
		_mats[k] = m
	if not points.is_empty() and _gates.is_empty():
		setup(points, time_limit)

## The gate's frame faces along the course: the mean of the legs into and out of it.
func _dir_at(i: int) -> Vector3:
	var a: Vector3 = points[maxi(i - 1, 0)]
	var b: Vector3 = points[mini(i + 1, points.size() - 1)]
	var d := b - a
	d.y = 0.0
	return d.normalized() if d.length_squared() > 0.01 else Vector3.FORWARD

func _make_gate(i: int) -> Node3D:
	var g := Node3D.new()
	add_child(g)
	var p: Vector3 = points[i]
	var d := _dir_at(i)
	g.global_transform = Transform3D(Basis.looking_at(d, Vector3.UP), p)
	var half := GATE_W * 0.5
	for x in [-half, half]:
		_box(g, Vector3(x, GATE_H * 0.5 - 0.5, 0.0), Vector3(POST, GATE_H + 1.0, POST))
	_box(g, Vector3(0.0, GATE_H, 0.0), Vector3(GATE_W + POST, POST, POST))
	return g

func _box(parent: Node3D, at: Vector3, size: Vector3) -> void:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	mi.position = at
	parent.add_child(mi)

func _paint() -> void:
	for i in _gates.size():
		var k := "dim"
		if _next < 0:
			k = "start" if i == 0 else "dim"
		elif i == _next:
			k = "next"
		for c in (_gates[i] as Node).get_children():
			(c as MeshInstance3D).material_override = _mats.get(k)

func _player_machine() -> Node3D:
	var cc: Node = get_tree().get_first_node_in_group("camera_controller")
	var v = cc.get("current_vehicle") if cc != null else null
	return v as Node3D if is_instance_valid(v) else null

## Did the segment a..b go through gate i's frame?
func _crossed(i: int, a: Vector3, b: Vector3) -> bool:
	var g: Node3D = _gates[i]
	var inv := g.global_transform.affine_inverse()
	var la: Vector3 = inv * a
	var lb: Vector3 = inv * b
	if signf(la.z) == signf(lb.z) or is_equal_approx(la.z, lb.z):
		return false
	var t: float = la.z / (la.z - lb.z)
	var hit: Vector3 = la.lerp(lb, t)
	return absf(hit.x) <= GATE_W * 0.5 + PASS_SLACK and hit.y >= -3.0 and hit.y <= GATE_H + PASS_SLACK

func _physics_process(delta: float) -> void:
	if _gates.is_empty():
		return
	var m: Node3D = _player_machine()
	if m == null:
		_last = Vector3.INF
		return
	var now: Vector3 = m.global_position
	var was: Vector3 = _last
	_last = now
	if _next >= 0:
		_t += delta
		_show()
		if _t > time_limit:
			_end(false)
			return
	if was == Vector3.INF or was.distance_squared_to(now) > 2500.0:
		return                             # a respawn or a teleport, not a drive
	if _next < 0:
		if _crossed(0, was, now):
			_next = 1
			_t = 0.0
			_paint()
			started.emit()
		return
	if _crossed(_next, was, now):
		_next += 1
		if _next >= _gates.size():
			_end(true)
		else:
			_paint()

func _end(ok: bool) -> void:
	var t := _t
	_next = -1
	_paint()
	if ok:
		if best < 0.0 or t < best:
			best = t
		_say_time(t)
		finished.emit(t)
	else:
		_label_text(tr("Too slow. Drive through the start gate to try again."))
		failed.emit()
	get_tree().create_timer(4.0).timeout.connect(_hide_hud)

func _say_time(t: float) -> void:
	_label_text(tr("Finish: %s") % _clock(t))

static func _clock(t: float) -> String:
	return "%d:%04.1f" % [int(t) / 60, fmod(t, 60.0)]

func _show() -> void:
	_label_text("%s / %s   %d/%d" % [_clock(_t), _clock(time_limit), _next, _gates.size() - 1])

func _label_text(s: String) -> void:
	if _hud == null:
		_hud = CanvasLayer.new()
		_hud.layer = 5
		add_child(_hud)
		_label = Label.new()
		_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_label.add_theme_font_size_override("font_size", 34)
		_label.add_theme_color_override("font_color", Color(0.85, 0.97, 1.0))
		_label.add_theme_color_override("font_outline_color", Color(0.02, 0.05, 0.08))
		_label.add_theme_constant_override("outline_size", 8)
		_label.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
		_label.offset_top = 70.0
		_hud.add_child(_label)
	_hud.visible = true
	_label.text = s

func _hide_hud() -> void:
	if _hud != null and _next < 0:
		_hud.visible = false

## Where the compass should lead: the next gate in a run, the start otherwise.
func aim_point() -> Variant:
	if points.is_empty():
		return null
	return points[clampi(_next, 0, points.size() - 1)] if _next >= 0 else points[0]

## Running right now (a quest may want to wait for the end of a run).
func running() -> bool:
	return _next >= 0

func save_state() -> Dictionary:
	var pts: Array = []
	for p in points:
		pts.append([snappedf(p.x, 0.01), snappedf(p.y, 0.01), snappedf(p.z, 0.01)])
	return {"points": pts, "limit": time_limit, "best": best, "key": String(get_meta("track_key", ""))}

func load_state(d: Dictionary) -> void:
	var pts: Array = []
	for e in d.get("points", []):
		pts.append(Vector3(float(e[0]), float(e[1]), float(e[2])))
	best = float(d.get("best", -1.0))
	keep = true
	set_meta("track_key", String(d.get("key", "")))
	points = pts
	time_limit = float(d.get("limit", 60.0))
	if is_inside_tree():
		setup(points, time_limit)
