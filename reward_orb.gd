extends Node3D
# A REWARD THAT IS NOT YET GIVEN: a sphere of glitch cards hanging over the ground (Supply Drop).
#
# The cards are the ones a block or a machine appears with (BlockFX.CARD_SHADER, same palette), and
# they never stand still: every card lives its own short cycle - comes up, peaks, fades - and is
# then reborn at a new point of the sphere with a new pattern, so the orb is always the same shape
# made of different pieces.
#
# It opens by being STOOD NEXT TO: HOLD_TIME seconds within HOLD_DIST. While that runs the orb
# gradually comes apart - fewer cards are reborn - which is also the progress bar; walk away and it
# fills back in. `locked` (a trap whose owners still live) holds it shut. When it opens, the last
# cards burn out, `opened` fires with the centre, and the caller drops the reward there.
#
# No class_name: reached by preload (CLAUDE.md rule 19).

signal opened(at: Vector3)

const RADIUS := 1.0
const HOVER := 3.0               # metres over the ground
const CARDS := 24
const CYCLE_MIN := 0.55          # seconds one card lives
const CYCLE_MAX := 1.2
const SIZE_MIN := 0.22
const SIZE_MAX := 0.5
const HOLD_DIST := 10.0
const HOLD_TIME := 3.0

var locked: bool = false

var _cards: Array = []           # [MeshInstance3D, ShaderMaterial, t, period]
var _hold: float = 0.0
var _open: bool = false

func setup(ground_point: Vector3) -> void:
	global_position = Vector3(ground_point.x, G.ground_y(ground_point, ground_point.y) + HOVER,
			ground_point.z)

func _ready() -> void:
	set_meta("block_fx", true)
	for i in CARDS:
		var mi := MeshInstance3D.new()
		var q := QuadMesh.new()
		q.size = Vector2.ONE
		mi.mesh = q
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.set_meta("block_fx", true)
		var m := ShaderMaterial.new()
		m.shader = BlockFX.CARD_SHADER
		mi.material_override = m
		add_child(mi)
		var period: float = randf_range(CYCLE_MIN, CYCLE_MAX)
		# Staggered from the start: all sixteen born together would pulse as one.
		_cards.append([mi, m, randf() * period, period])
		_reborn(_cards[i])

## A new life for one card: a new spot inside the sphere, a new pattern, a new size.
func _reborn(c: Array) -> void:
	var mi: MeshInstance3D = c[0]
	var m: ShaderMaterial = c[1]
	var d := Vector3(randf() - 0.5, randf() - 0.5, randf() - 0.5)
	d = d.normalized() if d.length_squared() > 0.0001 else Vector3.UP
	# Uniform over the VOLUME (cube root), or the cards would crowd the middle.
	mi.position = d * RADIUS * pow(randf(), 1.0 / 3.0)
	var s: float = randf_range(SIZE_MIN, SIZE_MAX)
	mi.scale = Vector3(s, s, 1.0)
	m.set_shader_parameter("seed", randf() * 100.0)
	m.set_shader_parameter("grid_cells", 4.0 if randf() < 0.5 else 6.0)
	m.set_shader_parameter("fill_threshold", randf_range(0.30, 0.46))
	c[3] = randf_range(CYCLE_MIN, CYCLE_MAX)
	mi.visible = true

func _process(delta: float) -> void:
	if not _open:
		_tick_hold(delta)
	# How many cards may be reborn: all of them at rest, fewer as the hold runs, none once open.
	var keep: int = 0 if _open else int(ceil(float(CARDS) * (1.0 - _hold / HOLD_TIME)))
	var alive: int = 0
	for i in _cards.size():
		var c: Array = _cards[i]
		var mi: MeshInstance3D = c[0]
		if not mi.visible:
			if i < keep:
				_reborn(c)
				c[2] = 0.0
			continue
		c[2] = float(c[2]) + delta
		if float(c[2]) >= float(c[3]):
			if i < keep:
				_reborn(c)
				c[2] = 0.0
			else:
				mi.visible = false
				continue
		alive += 1
		(c[1] as ShaderMaterial).set_shader_parameter("progress", float(c[2]) / float(c[3]))
	if _open and alive == 0:
		queue_free()

func _tick_hold(delta: float) -> void:
	var near: bool = false
	if not locked:
		var p: Node3D = _player()
		near = p != null and p.global_position.distance_squared_to(global_position) \
				<= HOLD_DIST * HOLD_DIST
	# Leaving (or a lock coming back) undoes it at the same pace, so the orb visibly fills back in.
	_hold = clampf(_hold + (delta if near else -delta), 0.0, HOLD_TIME)
	if _hold >= HOLD_TIME:
		_open = true
		opened.emit(global_position)

func is_open() -> bool:
	return _open

## 0 untouched .. 1 about to open.
func progress() -> float:
	return _hold / HOLD_TIME

func _player() -> Node3D:
	var cc: Node = get_tree().get_first_node_in_group("camera_controller")
	if cc != null and "current_vehicle" in cc and is_instance_valid(cc.current_vehicle):
		return cc.current_vehicle as Node3D
	return null
