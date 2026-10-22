extends Node3D
# The startup reward blocks are not just “dropped into inventory” — they materialise in a short loop as
# a simulation bootstrap artifact, then fall into the world as normal blocks. The effect stays subtle:
# it reads as a recovered world coming back online, not as a dramatic loot pop or a combat reward drop.

@export var radius: float = 3.4
@export var height: float = 2.0
@export var ang_speed: float = 1.2            # rad/s — slower orbit for a softer handoff into the world
@export var lifetime: float = 3.6             # a little longer so the handoff reads as stable and intentional

var target: Node3D = null                     # machine around which we orbit
var _block: Node3D = null                     # block scene instance
var _phase: float = 0.0
var _t: float = 0.0
var _glitch_t: float = 0.0
var _dropped: bool = false

## Marks an orbiter so QuestProps counts a block still circling as already handed out; without it
## ensure would drop a second copy during the three seconds before this one lands.
const META := "reward_orbiter"

func setup(tgt: Node3D, block_type: int, phase: float) -> void:
	target = tgt
	_phase = phase
	set_meta(META, true)
	top_level = true                          # world coordinates: we keep the orbit position ourselves
	var scene: PackedScene = G.get_scene(block_type)
	if scene == null:
		queue_free()
		return
	_block = scene.instantiate()
	add_child(_block)
	if _block is RigidBody3D:
		(_block as RigidBody3D).freeze = true
		(_block as RigidBody3D).collision_layer = 0   # keeps it out of world interaction while it orbits
	if target != null and is_instance_valid(target):
		global_position = target.global_position + Vector3(cos(_phase) * radius, height, sin(_phase) * radius)
	if _block != null:
		BlockFX.play(_block, false)            # glitch appearance on spawn
	_glitch_t = 0.9

## The block itself, for a caller that has to tag it before it lands.
func block() -> Node3D:
	return _block

func _physics_process(delta: float) -> void:
	if _dropped:
		return
	if target == null or not is_instance_valid(target):
		_drop()                                # machine disappeared — let the block fall where it is
		return
	_t += delta
	var a := _phase + _t * ang_speed
	var bob := sin(_t * 3.0) * 0.18            # subtle drift; keeps the handoff read as recover-and-stabilise
	global_position = target.global_position + Vector3(cos(a) * radius, height + bob, sin(a) * radius)
	if _block != null and is_instance_valid(_block):
		_block.rotation.y += delta * 2.0       # the block slowly spins while circling
	_glitch_t -= delta
	if _glitch_t <= 0.0 and _block != null and is_instance_valid(_block):
		BlockFX.play(_block, false)
		_glitch_t = 1.1
	if _t >= lifetime:
		_drop()

func _drop() -> void:
	_dropped = true
	if _block == null or not is_instance_valid(_block):
		queue_free()
		return
	var objects := get_node_or_null("/root/Main/objects")
	if objects == null:
		objects = get_tree().current_scene
	_block.reparent(objects)
	if _block is RigidBody3D:
		var rb := _block as RigidBody3D
		rb.collision_layer = 2                 # normal world block again
		rb.freeze = false
		rb.sleeping = false
		rb.apply_central_impulse(Vector3(randf() - 0.5, 0.15, randf() - 0.5).normalized() * 1.2 * rb.mass)
	queue_free()                               # orbiter container is removed, block remains in world
