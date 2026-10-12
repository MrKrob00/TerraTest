extends CanvasLayer

## A FEW THINGS IN THE AIR, DRAWN ON THE SCREEN (the player's call): snow over the mountains, sand
## blowing over the desert, seed fluff over the meadow, dust in the canyon. Never more than `COUNT`
## sprites - a mood, not weather - drawn with `_draw()` (rule 11: no particles), one CanvasItem.
## THE DEPTH IS FAKED, NOT SIMULATED: each sprite has a depth 0 (far) .. 1 (near) that sets its size,
## its fall speed, how faint it is and how far it slides when the camera turns (parallax), and every
## flake turns about a TILTED axis - its drawing squashed by cos(tilt) on one axis - so it reads as
## a flat thing in 3D rather than a sticker. The biome is asked under the camera once a second
## (`ChunkTerrain.biome_at`); a change fades the old kind out and the new one in.

const COUNT := 7
const BIOME_EVERY := 1.0
const FADE := 1.6
## Over this share of the snow line the mountains count as "snowy" (canyon/meadow/desert go by mask).
const SNOW_LINE_SHARE := 0.75

enum Kind { NONE, SNOW, SAND, FLUFF, DUST }

class Mote:
	var pos := Vector2.ZERO
	var depth := 0.5        # 0 far .. 1 near
	var spin := 0.0
	var spin_v := 0.0
	var tilt := 0.0         # the angle of the flake against the screen, drives the squash
	var tilt_v := 0.0
	var sway := 0.0
	var seed := 0.0

var _canvas: Control
var _motes: Array[Mote] = []
var _kind: int = Kind.NONE
var _want: int = Kind.NONE
var _alpha := 0.0
var _biome_t := 0.0
var _last_yaw := 0.0
var _last_pitch := 0.0
var _t := 0.0

func _ready() -> void:
	layer = 0                     # over the world, under every HUD layer
	_canvas = Control.new()
	_canvas.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_canvas.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_canvas.draw.connect(_on_draw)
	add_child(_canvas)
	# DEPTHS ARE SPREAD, NOT ROLLED: seven random ones are mostly middling, and the effect lives on
	# one or two big near ones against the small far ones.
	for i in COUNT:
		var m := Mote.new()
		m.depth = (float(i) + randf_range(0.2, 0.8)) / float(COUNT)
		_reset(m, true)
		_motes.append(m)

## Force a kind (the screenshots harness and a future setting); NONE goes back to the biome.
var forced: int = Kind.NONE

func _process(delta: float) -> void:
	_t += delta
	_biome_t -= delta
	if _biome_t <= 0.0:
		_biome_t = BIOME_EVERY
		_want = forced if forced != Kind.NONE else _biome_kind()
	# fade out, swap, fade in
	if _want != _kind:
		_alpha = maxf(0.0, _alpha - delta / FADE)
		if _alpha <= 0.0:
			_kind = _want
			for m in _motes:
				_reset(m, true)
	else:
		_alpha = minf(1.0, _alpha + delta / FADE)
	if _kind == Kind.NONE and _alpha <= 0.0:
		_canvas.visible = false
		return
	_canvas.visible = true
	_step(delta)
	_canvas.queue_redraw()

func _biome_kind() -> int:
	var cam := get_viewport().get_camera_3d()
	var map: Node = get_node_or_null("/root/Main/map")
	if cam == null or map == null or not map.has_method("biome_at"):
		return Kind.NONE
	var p: Vector3 = cam.global_position
	var b: Vector3 = map.biome_at(p)                       # canyon, meadow, mountain
	if map.has_method("salt_at") and float(map.salt_at(p)) > 0.5:
		return Kind.SAND
	if b.z > 0.5:
		var bio = map.get("biomes")
		var wh: float = float(map.world_height()) if map.has_method("world_height") else 0.0
		var line: float = bio.snow_line_at(wh) if bio != null and bio.has_method("snow_line_at") and wh > 0.0 else 0.0
		var gy: float = G.ground_y(p, 0.0)
		return Kind.SNOW if line <= 0.0 or gy >= line * SNOW_LINE_SHARE else Kind.DUST
	if b.x > 0.5:
		return Kind.DUST
	if b.y > 0.5:
		return Kind.FLUFF
	return Kind.SAND

func _reset(m: Mote, anywhere: bool) -> void:
	var sz: Vector2 = _canvas.size if _canvas != null and _canvas.size.x > 0.0 else Vector2(1280, 720)
	m.seed = randf() * 100.0
	m.spin = randf() * TAU
	m.spin_v = randf_range(-0.6, 0.6)
	m.tilt = randf() * TAU
	m.tilt_v = randf_range(0.4, 1.2) * (1.0 if randf() < 0.5 else -1.0)
	m.sway = randf() * TAU
	if anywhere:
		m.pos = Vector2(randf() * sz.x, randf() * sz.y)
		return
	match _kind:
		Kind.SAND:                         # blows in from the left edge
			m.pos = Vector2(-60.0, randf() * sz.y)
		Kind.DUST:                         # rises from below
			m.pos = Vector2(randf() * sz.x, sz.y + 60.0)
		_:                                 # falls from above
			m.pos = Vector2(randf() * sz.x, -60.0)

## How big a mote is on screen, in points, at its depth (a phone is ~720 high).
func _size(m: Mote) -> float:
	var sz: Vector2 = _canvas.size
	var base: float = sz.y / 720.0
	match _kind:
		Kind.SNOW: return base * lerpf(7.0, 44.0, m.depth * m.depth)
		Kind.FLUFF: return base * lerpf(9.0, 46.0, m.depth * m.depth)
		Kind.SAND: return base * lerpf(3.0, 12.0, m.depth)
		_: return base * lerpf(4.0, 16.0, m.depth)

func _step(delta: float) -> void:
	var sz: Vector2 = _canvas.size
	# PARALLAX: a turn of the camera slides near motes further than far ones, which is most of what
	# makes a flat overlay read as standing in the world.
	var dyaw := 0.0
	var dpitch := 0.0
	var cam := get_viewport().get_camera_3d()
	if cam != null:
		var f: Vector3 = -cam.global_basis.z
		var yaw: float = atan2(f.x, f.z)
		var pitch: float = asin(clampf(f.y, -1.0, 1.0))
		dyaw = wrapf(yaw - _last_yaw, -PI, PI)
		dpitch = pitch - _last_pitch
		_last_yaw = yaw
		_last_pitch = pitch
		if absf(dyaw) > 0.5 or absf(dpitch) > 0.5:
			dyaw = 0.0                     # a camera cut, not a turn
			dpitch = 0.0
	var scale: float = sz.y / 720.0
	for m in _motes:
		var d: float = m.depth
		var near: float = lerpf(0.35, 1.0, d)
		var v := Vector2.ZERO
		match _kind:
			Kind.SNOW:
				v = Vector2(sin(_t * 0.7 + m.seed) * 18.0, 42.0) * near
			Kind.FLUFF:
				v = Vector2(16.0 + sin(_t * 0.5 + m.seed) * 14.0, 8.0 + sin(_t * 0.9 + m.seed * 2.0) * 10.0) * near
			Kind.SAND:
				v = Vector2(150.0, 10.0 + sin(_t * 2.0 + m.seed) * 12.0) * near
			Kind.DUST:
				v = Vector2(sin(_t * 0.4 + m.seed) * 10.0, -9.0) * near
		m.pos += v * scale * delta
		m.pos.x += dyaw * sz.x * 0.9 * near
		m.pos.y -= dpitch * sz.y * 0.9 * near
		m.spin += m.spin_v * delta
		m.tilt += m.tilt_v * delta
		var r: float = _size(m) + 40.0
		if m.pos.y > sz.y + r or m.pos.y < -r - 80.0 or m.pos.x > sz.x + r + 80.0 or m.pos.x < -r - 80.0:
			_reset(m, false)
			if m.pos.x < -r - 80.0 or m.pos.x > sz.x + r + 80.0:
				m.pos.x = wrapf(m.pos.x, 0.0, sz.x)

func _on_draw() -> void:
	# far ones first, so a near flake is drawn over a far one
	var order: Array[Mote] = _motes.duplicate()
	order.sort_custom(func(a: Mote, b: Mote) -> bool: return a.depth < b.depth)
	for m in order:
		var s: float = _size(m)
		# near motes are out of focus: fainter and softer, far ones small and crisp
		var a: float = _alpha * lerpf(0.85, 0.6, m.depth)
		var squash: float = 0.25 + 0.75 * absf(cos(m.tilt))
		var xf := Transform2D(m.spin, m.pos) * Transform2D(0.0, Vector2(1.0, squash), 0.0, Vector2.ZERO)
		_canvas.draw_set_transform_matrix(xf)
		match _kind:
			Kind.SNOW: _draw_flake(s, a, m.depth)
			Kind.FLUFF: _draw_fluff(s, a, m.depth)
			Kind.SAND: _draw_grain(s, a, Color(0.93, 0.80, 0.58))
			Kind.DUST: _draw_grain(s, a, Color(0.86, 0.66, 0.48))
	_canvas.draw_set_transform_matrix(Transform2D.IDENTITY)

## A six-armed flake: arms with two pairs of side twigs, a soft halo behind for the near ones.
func _draw_flake(s: float, a: float, depth: float) -> void:
	var w: float = maxf(1.0, s * 0.07)
	var halo := Color(0.85, 0.92, 1.0, a * 0.18 * depth)
	if depth > 0.4:
		_canvas.draw_circle(Vector2.ZERO, s * 0.9, halo)
	var c := Color(0.95, 0.98, 1.0, a)
	for i in 6:
		var dir := Vector2.from_angle(TAU * i / 6.0)
		var side := dir.orthogonal()
		_canvas.draw_line(Vector2.ZERO, dir * s, c, w, true)
		for k in [0.45, 0.72]:
			var p: Vector2 = dir * s * k
			var tw: float = s * (0.30 if k < 0.5 else 0.2)
			_canvas.draw_line(p, p + (dir * 0.6 + side).normalized() * tw, c, w * 0.8, true)
			_canvas.draw_line(p, p + (dir * 0.6 - side).normalized() * tw, c, w * 0.8, true)
	_canvas.draw_circle(Vector2.ZERO, w * 1.4, c)

## A dandelion seed: a dark seed, a stalk, and a crown of fine hairs fanned at its top.
func _draw_fluff(s: float, a: float, depth: float) -> void:
	var w: float = maxf(1.2, s * 0.06)
	var hair := Color(1.0, 1.0, 0.96, a)
	var top := Vector2(0.0, -s * 0.35)
	_canvas.draw_line(Vector2(0.0, s * 0.45), top, Color(0.9, 0.88, 0.8, a), w, true)
	_canvas.draw_circle(Vector2(0.0, s * 0.5), maxf(1.2, s * 0.07), Color(0.45, 0.36, 0.25, a))
	for i in 11:
		var ang: float = PI + PI * (float(i) / 10.0)          # a fan opening upward
		var tip: Vector2 = top + Vector2.from_angle(ang) * s * 0.6
		_canvas.draw_line(top, tip, hair, w * 0.7, true)
		_canvas.draw_circle(tip, w * 0.9, Color(1, 1, 1, a * 0.7))
	if depth > 0.5:
		_canvas.draw_circle(top, s * 0.55, Color(1, 1, 0.95, a * 0.10))

## A grain or a mote: a short soft streak (its squash and spin do the rest).
func _draw_grain(s: float, a: float, col: Color) -> void:
	_canvas.draw_circle(Vector2.ZERO, s * 1.6, Color(col.r, col.g, col.b, a * 0.15))
	_canvas.draw_line(Vector2(-s * 1.4, 0.0), Vector2(s * 1.4, 0.0), Color(col.r, col.g, col.b, a * 0.55), s * 0.7, true)
	_canvas.draw_circle(Vector2.ZERO, s * 0.55, Color(col.r, col.g, col.b, a))
