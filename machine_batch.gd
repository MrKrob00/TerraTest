class_name MachineBatch
extends Node3D
# ONE DRAW CALL PER MESH PER MACHINE, NOT ONE PER BLOCK PART.
#
# Every copy of the same mesh (with the same material) on one machine is drawn by a single
# MultiMeshInstance3D. Measured in a 13-machine fight before this: 3.9 draw calls per block - plain
# blocks cost one each, a big wheel six (its model is a chain of six meshes), a shotgun up to
# fourteen - and 857 blocks came to about 3300 draw calls on top of the world's 158.
#
# THE ORIGINALS STAY WHERE THEY ARE AND KEEP THEIR `visible`. Their render LAYERS go to 0, so no
# camera draws them, while everything that asks `visible` - occlusion, effects measuring a block
# (BlockFX._local_aabb), leaving the machine - keeps working unchanged. A part leaving the machine
# gets its layers back at once (child_exiting_tree), before anything else sees it.
#
# WHAT IS BATCHED: meshes that came with the block's SCENE (owner == block) - never anything a
# script built (hp overlay, laser rings, shield dome, beams: owner is null), nothing under an Area3D
# (bullets), nothing marked block_fx, nothing the block lists in `unbatched()` (a mesh a script
# shows, hides or re-materials: the tracer, the processor's lamp).
#
# WHAT MOVES: a block with `moving_parts` (wheels, every weapon, the drill) has its instances
# copied from the live nodes every frame, AFTER the block scripts have moved them (process_priority).
# Everything else is written once per rebuild. A new block type that animates a mesh from its scene
# has to set `moving_parts`, or its part will stand still in the picture while the node turns.
#
# REBUILT WHEN THE BUILD CHANGES: a block entering or leaving `blocks`, or occlusion re-deciding
# what is walled in (blocks._apply_occlusion calls mark_dirty). Coalesced to one rebuild a frame.

var _machine: Node3D = null
var _blocks: Node = null
var _dirty: bool = true
## key -> {"mmi": MultiMeshInstance3D, "parts": Array, "dyn": PackedInt32Array}
var _groups: Dictionary = {}
## instance_id -> [MeshInstance3D, old layers]: what we hid, to give back exactly.
var _hidden: Dictionary = {}
## block instance_id -> Array of its batched meshes
var _by_block: Dictionary = {}

func setup(machine: Node3D, blocks: Node) -> void:
	_machine = machine
	_blocks = blocks
	name = "MeshBatch"
	set_meta("block_fx", true)
	process_priority = 100                     # after the blocks have moved their parts
	blocks.child_entered_tree.connect(_on_enter)
	blocks.child_exiting_tree.connect(_on_exit)

func mark_dirty() -> void:
	_dirty = true

func _on_enter(n: Node) -> void:
	if n is VehicleBlock:
		_dirty = true

func _on_exit(n: Node) -> void:
	var id: int = n.get_instance_id()
	if _by_block.has(id):
		for mi in _by_block[id]:
			_restore(mi)
		_by_block.erase(id)
	_dirty = true

func _process(_delta: float) -> void:
	var _pf := Perf.now()
	if _dirty:
		_dirty = false
		_rebuild()
	elif is_visible_in_tree():
		_update_moving()
	Perf.mark("batch", _pf)

func _restore(mi) -> void:
	if not is_instance_valid(mi):
		return
	var id: int = mi.get_instance_id()
	if _hidden.has(id):
		(mi as MeshInstance3D).layers = int(_hidden[id][1])
		_hidden.erase(id)

func _rebuild() -> void:
	if _blocks == null or not is_instance_valid(_blocks) or not is_instance_valid(_machine):
		return
	for id in _hidden.keys():
		_restore(_hidden[id][0])
	_hidden.clear()
	_by_block.clear()
	var inv: Transform3D = _machine.global_transform.affine_inverse()
	var found: Dictionary = {}                 # key -> [[mi, moving], ...]
	for b in _blocks.get_children():
		if not (b is VehicleBlock) or (b as Node3D).top_level or not (b as Node3D).visible:
			continue
		if b.is_queued_for_deletion() or not b.is_inside_tree():
			continue
		var skip: Array = (b as VehicleBlock).unbatched()
		var moving: bool = (b as VehicleBlock).moving_parts
		var mine: Array = []
		_collect(b, b, skip, mine)
		if mine.is_empty():
			continue
		_by_block[b.get_instance_id()] = mine
		for mi in mine:
			var key: String = _key(mi)
			if not found.has(key):
				found[key] = []
			found[key].append([mi, moving])
	# Drop groups that no longer exist, reuse the rest.
	for key in _groups.keys():
		if not found.has(key):
			var old = _groups[key]["mmi"]
			if is_instance_valid(old):
				old.queue_free()
			_groups.erase(key)
	for key in found:
		var list: Array = found[key]
		var first: MeshInstance3D = list[0][0]
		var g: Dictionary = _groups.get(key, {})
		var mmi: MultiMeshInstance3D = g.get("mmi", null)
		if not is_instance_valid(mmi):
			mmi = MultiMeshInstance3D.new()
			mmi.set_meta("block_fx", true)
			mmi.multimesh = MultiMesh.new()
			mmi.multimesh.transform_format = MultiMesh.TRANSFORM_3D
			mmi.multimesh.mesh = first.mesh
			mmi.material_override = first.material_override
			mmi.cast_shadow = first.cast_shadow
			add_child(mmi)
		var mm: MultiMesh = mmi.multimesh
		mm.instance_count = list.size()
		var parts: Array = []
		var dyn := PackedInt32Array()
		for i in list.size():
			var mi: MeshInstance3D = list[i][0]
			mm.set_instance_transform(i, inv * mi.global_transform)
			parts.append(mi)
			if list[i][1]:
				dyn.append(i)
			_hidden[mi.get_instance_id()] = [mi, mi.layers]
			mi.layers = 0
		_groups[key] = {"mmi": mmi, "parts": parts, "dyn": dyn}

## The block's own scene meshes, depth first, skipping whole branches that are not model.
func _collect(n: Node, block: Node, skip: Array, out: Array) -> void:
	for c in n.get_children():
		if skip.has(c) or c is Area3D or c.has_meta("block_fx") or c is VehicleBlock:
			continue
		if c is Node3D and not (c as Node3D).visible:
			continue
		# A per-surface override cannot ride in a MultiMesh (it has one material_override for the
		# whole mesh), so such a part is left to draw itself. No block scene uses one today.
		if c is MeshInstance3D and c.owner == block and (c as MeshInstance3D).mesh != null \
				and not _has_surface_override(c):
			out.append(c)
		_collect(c, block, skip, out)

func _has_surface_override(mi: MeshInstance3D) -> bool:
	for i in mi.get_surface_override_material_count():
		if mi.get_surface_override_material(i) != null:
			return true
	return false

func _key(mi: MeshInstance3D) -> String:
	var mat = mi.material_override
	return "%d|%d|%d" % [mi.mesh.get_rid().get_id(),
			mat.get_rid().get_id() if mat != null else 0, mi.cast_shadow]

func _update_moving() -> void:
	var inv: Transform3D = _machine.global_transform.affine_inverse()
	for key in _groups:
		var g: Dictionary = _groups[key]
		var dyn: PackedInt32Array = g["dyn"]
		if dyn.is_empty():
			continue
		var parts: Array = g["parts"]
		var mm: MultiMesh = (g["mmi"] as MultiMeshInstance3D).multimesh
		for i in dyn:
			var mi = parts[i]
			if is_instance_valid(mi):
				mm.set_instance_transform(i, inv * (mi as MeshInstance3D).global_transform)
