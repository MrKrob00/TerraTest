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

signal done

const FRAMES := 4
const AHEAD := 8.0

var _parts: Array = []

func _ready() -> void:
	_run.call_deferred()

func _run() -> void:
	var cam := get_viewport().get_camera_3d()
	if cam != null:
		var dir: Vector3 = -cam.global_transform.basis.z
		var pos: Vector3 = cam.global_position + dir * AHEAD
		global_position = pos
		_effects(pos, dir)
		_multimeshes(pos)
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
