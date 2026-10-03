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
#
# THE FAR SIDE OF A MACHINE IS LEFT OUT OF THE MAIN PASS. Occlusion hides what is walled in; what
# stands on the surface facing away is hidden by the machine itself, and drawing it is vertices for
# nothing. A block is seen only THROUGH an open face (blocks' `open_mask`: the cell beyond it is
# see-through and reached from outside), and a ray enters through a face only from the outer side of
# its plane - so a block none of whose open faces has the camera in front of it cannot be seen. Asked
# in the grid's own planes, so it is re-decided only when the camera crosses one (`_view_key`), not
# every frame. Two exceptions draw always: a block with `moving_parts` (a turret swings out of its
# cell, a tyre hangs under it) and one whose model reaches past its cells (`VIEW_SLACK`). SHADOWS
# KEEP THE WHOLE MACHINE: a group with a culled member draws its main pass without shadow and a
# second MultiMesh, SHADOWS_ONLY, with every instance - one draw call in each pass, as before.

var _machine: Node3D = null
var _blocks: Node = null
var _dirty: bool = true
## key -> {"mmi": MultiMeshInstance3D, "parts": Array, "dyn": PackedInt32Array}
var _groups: Dictionary = {}
## instance_id -> [MeshInstance3D, old layers]: what we hid, to give back exactly.
var _hidden: Dictionary = {}
## block instance_id -> Array of its batched meshes
var _by_block: Dictionary = {}
## per rebuilt block: [cell_lo, cell_hi, open_mask, cullable, seen_now]
var _binfo: Array = []
var _view_key := Vector3i(1 << 20, 0, 0)
const VIEW_SLACK := 0.06       # how far past its cells a model may reach and still be culled

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
		if _view_changed():
			_apply_view()
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
	var binv: Transform3D = (_blocks as Node3D).global_transform.affine_inverse()
	var found: Dictionary = {}                 # key -> [[mi, moving, block index], ...]
	_binfo.clear()
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
		var bi: int = _binfo.size()
		_binfo.append(_view_info(b, mine, moving, binv))
		for mi in mine:
			var key: String = _key(mi)
			if not found.has(key):
				found[key] = []
			found[key].append([mi, moving, bi])
	# Drop groups that no longer exist, reuse the rest.
	for key in _groups.keys():
		if not found.has(key):
			var old = _groups[key]["mmi"]
			if is_instance_valid(old):
				old.queue_free()
			_groups.erase(key)
	for key in _groups.keys():
		var sh = _groups[key].get("smmi", null)
		if is_instance_valid(sh):
			sh.queue_free()
	var old_groups: Dictionary = _groups
	_groups = {}
	for key in found:
		var list: Array = found[key]
		var first: MeshInstance3D = list[0][0]
		var mmi: MultiMeshInstance3D = old_groups.get(key, {}).get("mmi", null)
		if not is_instance_valid(mmi):
			mmi = _new_mmi(first)
			add_child(mmi)
		var parts: Array = []
		var moving := PackedByteArray()
		var owner_i := PackedInt32Array()
		var cullable := false
		for e in list:
			var mi: MeshInstance3D = e[0]
			parts.append(mi)
			moving.append(1 if e[1] else 0)
			owner_i.append(int(e[2]))
			if _binfo[int(e[2])][3]:
				cullable = true
			_hidden[mi.get_instance_id()] = [mi, mi.layers]
			mi.layers = 0
		var smmi: MultiMeshInstance3D = null
		mmi.cast_shadow = first.cast_shadow
		if cullable and first.cast_shadow != GeometryInstance3D.SHADOW_CASTING_SETTING_OFF:
			mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			smmi = _new_mmi(first)
			smmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY
			add_child(smmi)
			_fill(smmi.multimesh, parts, range(parts.size()), inv)
		_groups[key] = {"mmi": mmi, "smmi": smmi, "parts": parts, "moving": moving, "owner": owner_i,
				"cullable": cullable, "vis": PackedInt32Array()}
	_view_key = Vector3i(1 << 20, 0, 0)
	_view_changed()
	_apply_view()

func _new_mmi(first: MeshInstance3D) -> MultiMeshInstance3D:
	var mmi := MultiMeshInstance3D.new()
	mmi.set_meta("block_fx", true)
	mmi.multimesh = MultiMesh.new()
	mmi.multimesh.transform_format = MultiMesh.TRANSFORM_3D
	mmi.multimesh.mesh = first.mesh
	mmi.material_override = first.material_override
	return mmi

func _fill(mm: MultiMesh, parts: Array, idx, inv: Transform3D) -> void:
	var n: int = idx.size() if not (idx is Array) else (idx as Array).size()
	mm.instance_count = n
	var j := 0
	for i in idx:
		var mi = parts[i]
		if is_instance_valid(mi):
			mm.set_instance_transform(j, inv * (mi as MeshInstance3D).global_transform)
		j += 1

## [cell_lo, cell_hi, open_mask, cullable, seen]: may this block leave the main pass, and on what.
func _view_info(b: Node, mine: Array, moving: bool, binv: Transform3D) -> Array:
	if moving or not b.has_meta(&"open_mask"):
		return [Vector3i.ZERO, Vector3i.ZERO, 63, false, true]
	var lo: Vector3i = b.get_meta(&"cell_lo")
	var hi: Vector3i = b.get_meta(&"cell_hi")
	var cs: float = _blocks.CELL_SIZE
	var c0 := (Vector3(lo - Vector3i.ONE * _blocks.CENTER) - Vector3.ONE * 0.5) * cs - Vector3.ONE * VIEW_SLACK
	var c1 := (Vector3(hi - Vector3i.ONE * _blocks.CENTER) + Vector3.ONE * 0.5) * cs + Vector3.ONE * VIEW_SLACK
	for mi in mine:
		var box: AABB = binv * (mi as MeshInstance3D).global_transform * (mi as MeshInstance3D).get_aabb()
		if box.position.x < c0.x or box.position.y < c0.y or box.position.z < c0.z \
				or box.end.x > c1.x or box.end.y > c1.y or box.end.z > c1.z:
			return [lo, hi, 63, false, true]
	return [lo, hi, int(b.get_meta(&"open_mask")), true, true]

## The camera's place among the grid's planes: r on an axis is k while it is between the planes
## k + 0.5 and k + 1.5. True when it moved to another place.
func _view_changed() -> bool:
	var cam: Camera3D = get_viewport().get_camera_3d() if is_inside_tree() else null
	var key := Vector3i(1 << 20, 1, 1)                 # no camera: everything in
	if cam != null and is_instance_valid(_blocks):
		var g: Vector3 = (_blocks as Node3D).global_transform.affine_inverse() * cam.global_position
		g = g / float(_blocks.CELL_SIZE) + Vector3.ONE * float(_blocks.CENTER)
		key = Vector3i(floori(g.x - 0.5), floori(g.y - 0.5), floori(g.z - 0.5))
	if key == _view_key:
		return false
	_view_key = key
	return true

func _apply_view() -> void:
	var r := _view_key
	var all_in: bool = r.x == 1 << 20
	for e in _binfo:
		if not e[3] or all_in:
			e[4] = true
			continue
		var lo: Vector3i = e[0]
		var hi: Vector3i = e[1]
		var m: int = e[2]
		e[4] = ((m & 1) != 0 and r.x >= hi.x) or ((m & 2) != 0 and r.x <= lo.x - 2) \
				or ((m & 4) != 0 and r.y >= hi.y) or ((m & 8) != 0 and r.y <= lo.y - 2) \
				or ((m & 16) != 0 and r.z >= hi.z) or ((m & 32) != 0 and r.z <= lo.z - 2)
	if not is_instance_valid(_machine):
		return
	var inv: Transform3D = _machine.global_transform.affine_inverse()
	for key in _groups:
		var g: Dictionary = _groups[key]
		var vis := PackedInt32Array()
		var owner_i: PackedInt32Array = g["owner"]
		for i in owner_i.size():
			if _binfo[owner_i[i]][4]:
				vis.append(i)
		if vis == g["vis"] and (g["mmi"] as MultiMeshInstance3D).multimesh.instance_count == vis.size():
			continue
		g["vis"] = vis
		_fill((g["mmi"] as MultiMeshInstance3D).multimesh, g["parts"], vis, inv)

## The block's own scene meshes, depth first, skipping whole branches that are not model.
## Static because LooseBatch asks the same question of a block lying on the ground.
static func _collect(n: Node, block: Node, skip: Array, out: Array) -> void:
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

static func _has_surface_override(mi: MeshInstance3D) -> bool:
	for i in mi.get_surface_override_material_count():
		if mi.get_surface_override_material(i) != null:
			return true
	return false

static func _key(mi: MeshInstance3D) -> String:
	var mat = mi.material_override
	return "%d|%d|%d" % [mi.mesh.get_rid().get_id(),
			mat.get_rid().get_id() if mat != null else 0, mi.cast_shadow]

func _update_moving() -> void:
	var inv: Transform3D = _machine.global_transform.affine_inverse()
	for key in _groups:
		var g: Dictionary = _groups[key]
		var moving: PackedByteArray = g["moving"]
		if not moving.has(1):
			continue
		var parts: Array = g["parts"]
		var mm: MultiMesh = (g["mmi"] as MultiMeshInstance3D).multimesh
		var vis: PackedInt32Array = g["vis"]
		for j in vis.size():
			var i: int = vis[j]
			if moving[i] == 1 and is_instance_valid(parts[i]):
				mm.set_instance_transform(j, inv * (parts[i] as MeshInstance3D).global_transform)
		var sh = g["smmi"]
		if sh != null and is_instance_valid(sh):
			var smm: MultiMesh = (sh as MultiMeshInstance3D).multimesh
			for i in moving.size():
				if moving[i] == 1 and is_instance_valid(parts[i]):
					smm.set_instance_transform(i, inv * (parts[i] as MeshInstance3D).global_transform)
