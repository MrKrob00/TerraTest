extends MultiMeshInstance3D
# EVERY GLITCH-CARD CLOUD OF ONE PALETTE, IN ONE MULTIMESH (BlockFX.blast_cards and BlockFX.play).
#
# A cloud used to be a Node3D with a MeshInstance3D, a QuadMesh and a ShaderMaterial PER CARD, and a
# tween writing `progress` into every one of those materials every frame: a shield spark (10 cards)
# was ~2 ms of script on the player's profiler and ten draw calls, an explosion 34, a block shot off
# 28. Now a cloud is a few numbers in a list; this node writes every live card into one buffer a
# frame and the whole palette is one draw call. The card itself is unchanged (glitch_card_mm.gdshader
# is glitch_card.gdshader reading seed, grid, fill and progress from INSTANCE_CUSTOM).
#
# A CLOUD STAYS ON WHAT IT WAS DRAWN ON - the dome, the block, the machine - through its ANCHOR: its
# cards are placed by the anchor's transform each frame, exactly as when they were its children, and
# a freed anchor takes its clouds with it, as freeing the parent did. A null anchor is the world.

const SHADER := preload("res://glitch_card_mm.gdshader")
const STRIDE := 16              # 12 floats of transform, 4 of custom data
const PER := 7                  # per card: offset x, y, z, size, seed, grid, fill
const CAP_MIN := 64
## A ceiling, not a target: BlockFX's per-frame card budget keeps the live count far below it. Past
## it the oldest cloud makes room - a burst in a chain of blasts loses its tail, not the new one.
const CAP_MAX := 2048

var _anchors: Array = []                      # Node3D or null, per cloud; untyped (rule 4)
## Asked instead of `anchor != null`: a FREED anchor compares equal to null (CLAUDE.md rule 4), and
## a world cloud must not be told from a cloud whose block was just freed by that test.
var _anchored: PackedByteArray = PackedByteArray()
var _locals: Array[Transform3D] = []          # the cloud's origin in its anchor's space
var _t0: PackedFloat64Array = PackedFloat64Array()
var _dur: PackedFloat32Array = PackedFloat32Array()
var _grow: PackedFloat32Array = PackedFloat32Array()   # the cloud's scale at the start, 1 at the end
var _cards: Array[PackedFloat32Array] = []
var _live: int = 0                            # cards over all clouds
var _buf := PackedFloat32Array()

## The palette's node under the current scene, made on first use. `tint` false is the card's own
## cyan-to-magenta palette and ignores the colours.
##
## ADDED DEFERRED, AND KNOWN BY A REGISTRY RATHER THAN BY ITS NAME IN THE TREE. The first cloud of a
## world comes while the scene is still setting up its children - the starter machine's blocks
## glitch in from `blocks.spawn_block` inside the world's own _ready - and `add_child` there fails
## ("Parent node is busy setting up children", seen on 4.7.2). Deferred, the node is not in the tree
## until the end of the frame, so a second cloud in that frame would not find it by name.
static var _made: Dictionary = {}

static func of(n: Node, tint: bool, a: Color, b: Color) -> Node:
	if n == null or not n.is_inside_tree():
		return null
	var tree := n.get_tree()
	var host: Node = tree.current_scene if tree.current_scene != null else tree.root
	var key: String = ("CardBurst_%s_%s" % [a.to_html(false), b.to_html(false)]) if tint else "CardBurst"
	var rk: String = "%d|%s" % [host.get_instance_id(), key]
	var cb = _made.get(rk)
	if is_instance_valid(cb):
		return cb
	cb = load("res://card_burst.gd").new()         # by path, never by a class name (CLAUDE.md rule 19)
	cb.name = key
	cb.call("_setup", tint, a, b)
	host.add_child.call_deferred(cb)
	_made[rk] = cb
	return cb

func _setup(tint: bool, a: Color, b: Color) -> void:
	set_meta("block_fx", true)                   # BlockFX._local_aabb and the portrait baker skip it
	top_level = true
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var mat := ShaderMaterial.new()
	mat.shader = SHADER
	mat.set_shader_parameter("use_tint", tint)
	if tint:
		mat.set_shader_parameter("glitch_a", Vector3(a.r, a.g, a.b))
		mat.set_shader_parameter("glitch_b", Vector3(b.r, b.g, b.b))
	material_override = mat
	var q := QuadMesh.new()
	q.size = Vector2.ONE
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_custom_data = true
	mm.mesh = q
	mm.instance_count = CAP_MIN
	mm.visible_instance_count = 0
	multimesh = mm
	_buf.resize(CAP_MIN * STRIDE)
	visible = false
	set_process(false)

## One cloud: `cards` holds PER floats a card (offset in the cloud's axes, size, seed, grid, fill).
func add(anchor: Node3D, local: Transform3D, cards: PackedFloat32Array, dur: float, grow: float) -> void:
	var n: int = cards.size() / PER
	if n <= 0:
		return
	while _live + n > CAP_MAX and not _anchors.is_empty():
		_drop(0)
	_anchors.append(anchor)
	_anchored.append(1 if is_instance_valid(anchor) else 0)
	_locals.append(local)
	_t0.append(Time.get_ticks_msec() * 0.001)
	_dur.append(maxf(dur, 0.01))
	_grow.append(grow)
	_cards.append(cards)
	_live += n
	visible = true
	set_process(true)

func _drop(i: int) -> void:
	_live -= _cards[i].size() / PER
	_anchors.remove_at(i)
	_anchored.remove_at(i)
	_locals.remove_at(i)
	_t0.remove_at(i)
	_dur.remove_at(i)
	_grow.remove_at(i)
	_cards.remove_at(i)

func _process(_delta: float) -> void:
	var now: float = Time.get_ticks_msec() * 0.001
	var i: int = 0
	while i < _anchors.size():
		# an anchor that left the tree takes its cloud with it, as it did when the cloud was its
		# child: still valid but detached (a round reset, a block being freed), it has no global
		# transform to ride - asking for one is an engine error
		if (now - _t0[i]) >= _dur[i] or (_anchored[i] == 1 and (not is_instance_valid(_anchors[i])
				or not (_anchors[i] as Node).is_inside_tree())):
			_drop(i)
			continue
		i += 1
	if _anchors.is_empty():
		multimesh.visible_instance_count = 0
		visible = false
		set_process(false)
		return
	_room(_live)
	var n: int = 0
	var lo := Vector3(INF, INF, INF)
	var hi := -lo
	for c in _anchors.size():
		var p: float = clampf((now - _t0[c]) / _dur[c], 0.0, 1.0)
		var sc: float = lerpf(_grow[c], 1.0, p)
		var x: Transform3D = _locals[c]
		if _anchored[c] == 1:
			x = (_anchors[c] as Node3D).global_transform * x
		var cards: PackedFloat32Array = _cards[c]
		var k: int = 0
		while k < cards.size():
			var at: Vector3 = x * (Vector3(cards[k], cards[k + 1], cards[k + 2]) * sc)
			var s: float = cards[k + 3] * sc
			var o: int = n * STRIDE
			_buf[o] = s
			_buf[o + 1] = 0.0
			_buf[o + 2] = 0.0
			_buf[o + 3] = at.x
			_buf[o + 4] = 0.0
			_buf[o + 5] = s
			_buf[o + 6] = 0.0
			_buf[o + 7] = at.y
			_buf[o + 8] = 0.0
			_buf[o + 9] = 0.0
			_buf[o + 10] = s
			_buf[o + 11] = at.z
			_buf[o + 12] = cards[k + 4]
			_buf[o + 13] = cards[k + 5]
			_buf[o + 14] = cards[k + 6]
			_buf[o + 15] = p
			lo = lo.min(at - Vector3.ONE * s)
			hi = hi.max(at + Vector3.ONE * s)
			n += 1
			k += PER
	multimesh.buffer = _buf
	multimesh.visible_instance_count = n
	# The bounds of what is live: culled as one box, and sorted among the transparent by its middle
	# (a spark on a dome has to sort near the dome, not at the world's origin).
	custom_aabb = AABB(lo, hi - lo)

## Room for `n` cards. The buffer is rebuilt whole every frame, so growing loses nothing.
func _room(n: int) -> void:
	var cap: int = multimesh.instance_count
	if n <= cap:
		return
	while cap < n:
		cap *= 2
	cap = mini(cap, CAP_MAX)
	multimesh.instance_count = cap
	_buf.resize(cap * STRIDE)
