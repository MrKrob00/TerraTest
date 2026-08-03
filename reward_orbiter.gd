extends Node3D
# Награда блоками (подача, а не «молча в инвентарь»): блок ГЛЮЧНО появляется и КРУЖИТ вокруг
# машины, следуя за её МИРОВОЙ позицией — поэтому держится вокруг и при движении, и при повороте.
# Через lifetime блок ПАДАЕТ в мир обычным свободным блоком. Глюк-эффект (BlockFX) держится, пока
# блок кружит. Ставится из vehicle_body_3d.award_blocks().

@export var radius: float = 3.4
@export var height: float = 2.4
@export var ang_speed: float = 1.5            # рад/с — скорость облёта вокруг машины
@export var lifetime: float = 6.0             # сколько кружит до падения

var target: Node3D = null                     # машина, вокруг которой кружим
var _block: Node3D = null                     # сам блок (инстанс сцены блока)
var _phase: float = 0.0
var _t: float = 0.0
var _glitch_t: float = 0.0
var _dropped: bool = false

func setup(tgt: Node3D, block_type: int, phase: float) -> void:
	target = tgt
	_phase = phase
	top_level = true                          # мировые координаты: сами держим позицию вокруг машины
	var scene: PackedScene = G.get_scene(block_type)
	if scene == null:
		queue_free()
		return
	_block = scene.instantiate()
	add_child(_block)
	if _block is RigidBody3D:
		(_block as RigidBody3D).freeze = true
		(_block as RigidBody3D).collision_layer = 0   # пока кружит — не мешает (оружие/движение не задевают)
	if target != null and is_instance_valid(target):
		global_position = target.global_position + Vector3(cos(_phase) * radius, height, sin(_phase) * radius)
	if _block != null:
		BlockFX.play(_block, false)            # глюк появления
	_glitch_t = 0.9

func _physics_process(delta: float) -> void:
	if _dropped:
		return
	if target == null or not is_instance_valid(target):
		_drop()                                # машина исчезла — блок падает там, где был
		return
	_t += delta
	var a := _phase + _t * ang_speed
	var bob := sin(_t * 3.0) * 0.25            # лёгкое покачивание
	global_position = target.global_position + Vector3(cos(a) * radius, height + bob, sin(a) * radius)
	if _block != null and is_instance_valid(_block):
		_block.rotation.y += delta * 2.2       # блок медленно крутится сам
	# держим глюк живым, пока кружит — перезапускаем короткий эффект появления
	_glitch_t -= delta
	if _glitch_t <= 0.0 and _block != null and is_instance_valid(_block):
		BlockFX.play(_block, false)
		_glitch_t = 0.9
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
		rb.collision_layer = 2                 # снова обычный блок (падает и лежит в мире)
		rb.freeze = false
		rb.sleeping = false
		rb.apply_central_impulse(Vector3(randf() - 0.5, 0.15, randf() - 0.5).normalized() * 1.2 * rb.mass)
	queue_free()                               # контейнер-орбитёр убираем; блок остаётся в мире
