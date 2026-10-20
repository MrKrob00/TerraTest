extends Node3D
# THE FIRST SHOT OF A RUN MUST NOT COMPILE ANYTHING (the player: "a jerk on the first shot"). A shader
# is compiled the first time something draws with it and the frame waits (CLAUDE.md, Look and light),
# and in GLES3 the first LAMP is the worst of it: an OmniLight3D brings the lit-by-omni pass of every
# lit material in its reach - the terrain's included - to compile in that frame. So before the
# loading screen dissolves (loading_screen._finish) every effect a fight draws is played ONCE, for
# real, in the world in front of the camera, behind the still opaque cover: the muzzle jet and its
# lance, a flash lamp, a ground mark, the landing wave, a blast, a block's glitch and hit overlay,
# a lock frame; and the MultiMesh variants (a different program in GLES3) of the rounds' streak and
# the digits. A few frames later it is all gone, and so is this node.
#
# THE SAME FOR EVERYTHING ELSE THE WORLD DRAWS LATER (the player: "every new shader freezes the game on
# the first start"). After the effects, every block model (as a plain mesh AND as a MultiMesh - the
# machine batch draws them that way, a different program in GLES3) and every material item - ore,
# ingots, coal, wood, components - is shown for a couple of frames in front of the camera, BLOCKS_PER_FRAME
# at a time so no single frame waits for all of them, under a lamp of our own (WARM_LAMP) so the
# omni-lit variant of each, the terrain's too, compiles here and not at the first explosion.

signal done

const FRAMES := 4
const AHEAD := 8.0
## Block models put up per frame; each stays HOLD_FRAMES frames (the draw that compiles must happen).
const BLOCKS_PER_FRAME := 6
const HOLD_FRAMES := 2
const ITEM_SCENE := preload("res://resource.tscn")

var _parts: Array = []

func _ready() -> void:
	_run.call_deferred()

func _run() -> void:
	var cam := get_viewport().get_camera_3d()
	if cam != null:
		var dir: Vector3 = -cam.global_transform.basis.z
		var pos: Vector3 = cam.global_position + dir * AHEAD
		global_position = pos
		var lamp := OmniLight3D.new()           # WARM_LAMP: lit-by-omni variants for all below
		lamp.omni_range = 12.0
		add_child(lamp)
		lamp.global_position = pos + Vector3.UP * 2.0
		_parts.append(lamp)
		_effects(pos, dir)
		_multimeshes(pos)
		for i in FRAMES:
			await get_tree().process_frame
		await _models(pos, cam)
	for i in FRAMES:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	for p in _parts:
		if is_instance_valid(p):
			p.queue_free()
	done.emit()
	queue_free()

func _effects(pos: Vector3, dir: Vector3) -> void:
	BlockFX.muzzle_fire(self, dir, Color(1.0, 0.75, 0.35), 0.42, 0.18)
	BlockFX.muzzle_lance(self, dir, Color(0.3, 0.9, 1.0), 1.2, 0.08, 0.2)
	BlockFX.flash(self, pos, Color(1.0, 0.8, 0.5), 3.0, 0.1)
	BlockFX.ground_glitch(self, pos + Vector3.DOWN, Vector3.UP)
	BlockFX.ground_wave(self, pos + Vector3.DOWN, Vector3.UP, 30.0)
	BlockFX.blast_cards(self, pos, 1.5)
	# a stand-in block: a box, so the glitch cards, the hit overlay and the lock frame have
	# something to measure
	var block := Node3D.new()
	var mi := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3.ONE * 0.6
	mi.mesh = box
	block.add_child(mi)
	add_child(block)
	block.global_position = pos + Vector3.UP * 0.5
	_parts.append(block)
	BlockFX.play(block, false)
	BlockFX.hit(block)
	BlockFX.hp_overlay(block)
	BlockFX.lock_hold(block)

func _multimeshes(pos: Vector3) -> void:
	for sh in [load("res://bullet_streak.gdshader"), load("res://vein_digit.gdshader"),
			load("res://regen_digit.gdshader")]:
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_colors = true
		mm.use_custom_data = true
		var q := QuadMesh.new()
		q.size = Vector2.ONE * 0.3
		mm.mesh = q
		mm.instance_count = 1
		mm.set_instance_transform(0, Transform3D(Basis(), Vector3.ZERO))
		mm.set_instance_custom_data(0, Color(0.5, 0.5, 0, 0))
		var mmi := MultiMeshInstance3D.new()
		mmi.multimesh = mm
		var mat := ShaderMaterial.new()
		mat.shader = sh
		mmi.material_override = mat
		mmi.set_meta("block_fx", true)
		add_child(mmi)
		mmi.global_position = pos
		_parts.append(mmi)

## Every block's meshes and every material item, a batch a frame (see the header).
func _models(pos: Vector3, cam: Camera3D) -> void:
	var batch: Array = []
	for bt in G.Block.values():
		var b: int = int(bt)
		if b == G.Block.EMPTY or G.RETIRED_BLOCKS.has(b):
			continue
		var scn: PackedScene = G.get_scene(b)
		if scn != null:
			batch.append(scn)
	var keys: Array = Icons.material_keys() if Icons.has_method("material_keys") else []
	var i := 0
	while i < batch.size() + keys.size():
		var shown: Array = []
		for _j in BLOCKS_PER_FRAME:
			if i >= batch.size() + keys.size():
				break
			var n: Node3D = _block_copy(batch[i]) if i < batch.size() else _item(String(keys[i - batch.size()]))
			i += 1
			if n == null:
				continue
			add_child(n)
			# a little apart and in front, so none is culled behind another
			n.global_position = pos + cam.global_transform.basis.x * (float(shown.size()) - 2.5) * 1.2
			shown.append(n)
		for _f in HOLD_FRAMES:
			await get_tree().process_frame
		for n in shown:
			n.queue_free()

## A block's meshes only (no script, no body): its own materials, once plain and once as a MultiMesh.
func _block_copy(scn: PackedScene) -> Node3D:
	var src: Node = scn.instantiate()
	var root := Node3D.new()
	for c in _walk(src):
		var mi := c as MeshInstance3D
		if mi == null or mi.mesh == null:
			continue
		var cp := MeshInstance3D.new()
		cp.mesh = mi.mesh
		cp.material_override = mi.material_override
		for si in mi.get_surface_override_material_count():
			cp.set_surface_override_material(si, mi.get_surface_override_material(si))
		cp.transform = _local_to(src, mi)
		root.add_child(cp)
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = mi.mesh
		mm.instance_count = 1
		mm.set_instance_transform(0, cp.transform.translated(Vector3.UP * 0.8))
		var mmi := MultiMeshInstance3D.new()
		mmi.multimesh = mm
		mmi.material_override = mi.material_override
		root.add_child(mmi)
	src.free()
	return root

func _item(key: String) -> Node3D:
	var it := ITEM_SCENE.instantiate() as RigidBody3D
	it.freeze = true
	it.collision_layer = 0
	it.collision_mask = 0
	it.process_mode = Node.PROCESS_MODE_DISABLED
	it.ready.connect(func(): it.set_kind_key(key), CONNECT_ONE_SHOT)
	return it

## A node's transform relative to an ancestor outside the tree (global_transform needs the tree).
func _local_to(root: Node, n: Node) -> Transform3D:
	var t := Transform3D.IDENTITY
	var cur: Node = n
	while cur != null and cur != root:
		if cur is Node3D:
			t = (cur as Node3D).transform * t
		cur = cur.get_parent()
	return t

func _walk(n: Node) -> Array:
	var out: Array = [n]
	for c in n.get_children():
		out.append_array(_walk(c))
	return out
