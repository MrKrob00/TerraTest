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
#
# A STILL BLOCK CASTS ITS SHADOW AS ITS COLLIDER BOX (`_proxy`, one SHADOWS_ONLY MultiMesh of unit
# boxes for the machine). The shadow pass drew every model again - measured on the real driver,
# Marlit's champion: 13.4k primitives in the main pass and 13.1k more in the shadow pass, ~780 a
# block a pass - while at the sun's map (1024 px over 80 m, ~8 cm a texel) a block's shadow is its
# outline, and the collider IS the outline the model is authored inside. 12 triangles a block. What
# MOVES keeps its own shadow (a turret's barrel, a tyre), and so does a group that has to keep a
# twin anyway; a block whose models all cast nothing gets no box.

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
var _proxy: MultiMeshInstance3D = null
static var _proxy_mesh: BoxMesh = null
static var _proxy_mat: StandardMaterial3D = null

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
	var boxed: Array = []                      # still blocks that cast: their shadow is their box
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
		if not moving:
			for mi in mine:
				if (mi as MeshInstance3D).cast_shadow != GeometryInstance3D.SHADOW_CASTING_SETTING_OFF:
					boxed.append(b)
					break
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
		if not moving.has(1):
			# still parts only: their shadow is their blocks' boxes (_proxy)
			mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		elif cullable and first.cast_shadow != GeometryInstance3D.SHADOW_CASTING_SETTING_OFF:
			mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			smmi = _new_mmi(first)
			smmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY
			add_child(smmi)
			_fill(smmi.multimesh, parts, range(parts.size()), inv)
		_groups[key] = {"mmi": mmi, "smmi": smmi, "parts": parts, "moving": moving, "owner": owner_i,
				"cullable": cullable, "vis": PackedInt32Array()}
	_fill_proxy(boxed)
	_view_key = Vector3i(1 << 20, 0, 0)
	_view_changed()
	_apply_view()

## One unit box per still block, placed and sized as the machine's copy of its collider (the
## CollisionShape3D under the machine tagged `block_owner`, blocks.spawn_block) - machine space, as
## the batch is. A shape that is not a box gives the box round its points; a block with no tagged
## collider gives the box round its models.
func _fill_proxy(boxed: Array) -> void:
	var cols: Dictionary = {}
	for c in _machine.get_children():
		if c is CollisionShape3D and c.has_meta(&"block_owner"):
			var o = c.get_meta(&"block_owner")
			if is_instance_valid(o):
				cols[o.get_instance_id()] = c
	var xf: Array[Transform3D] = []
	var inv: Transform3D = _machine.global_transform.affine_inverse()
	for b in boxed:
		var c = cols.get(b.get_instance_id())
		var box := AABB()
		var at := Transform3D()
		if c != null and (c as CollisionShape3D).shape != null:
			at = (c as CollisionShape3D).transform
			var sh: Shape3D = (c as CollisionShape3D).shape
			if sh is BoxShape3D:
				box = AABB(-(sh as BoxShape3D).size * 0.5, (sh as BoxShape3D).size)
			elif sh is ConvexPolygonShape3D and (sh as ConvexPolygonShape3D).points.size() > 0:
				var pts: PackedVector3Array = (sh as ConvexPolygonShape3D).points
				box = AABB(pts[0], Vector3.ZERO)
				for q in pts:
					box = box.expand(q)
		if box.size == Vector3.ZERO:
			# no usable collider: the box round the block's own models, in machine space
			at = Transform3D()
			var first := true
			for mi in _by_block.get(b.get_instance_id(), []):
				var mb: AABB = inv * (mi as MeshInstance3D).global_transform * (mi as MeshInstance3D).get_aabb()
				box = mb if first else box.merge(mb)
				first = false
		if box.size == Vector3.ZERO:
			continue
		xf.append(at * Transform3D(Basis.from_scale(box.size), box.get_center()))
	if xf.is_empty():
		if is_instance_valid(_proxy):
			_proxy.visible = false
		return
	if not is_instance_valid(_proxy):
		if _proxy_mesh == null:
			_proxy_mesh = BoxMesh.new()
			_proxy_mesh.size = Vector3.ONE
			_proxy_mat = StandardMaterial3D.new()
			_proxy_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_proxy = MultiMeshInstance3D.new()
		_proxy.set_meta("block_fx", true)
		_proxy.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY
		_proxy.material_override = _proxy_mat
		_proxy.multimesh = MultiMesh.new()
		_proxy.multimesh.transform_format = MultiMesh.TRANSFORM_3D
		_proxy.multimesh.mesh = _proxy_mesh
		add_child(_proxy)
	_proxy.visible = true
	var mm: MultiMesh = _proxy.multimesh
	mm.instance_count = xf.size()
	for i in xf.size():
		mm.set_instance_transform(i, xf[i])

func _new_mmi(first: MeshInstance3D) -> MultiMeshInstance3D:
	var mmi := MultiMeshInstance3D.new()
	mmi.set_meta("block_fx", true)
	mmi.multimesh = MultiMesh.new()
	mmi.multimesh.transform_format = MultiMesh.TRANSFORM_3D
	mmi.multimesh.mesh = first.mesh
	mmi.material_override = lit_material(first)
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

## THE SUN ON A BATCHED BLOCK (block_lit.gdshader, the player's call after TerraTech): a part whose
## every surface is one opaque UNSHADED StandardMaterial gets the same texture, colour and UV under
## the lit shader, one ShaderMaterial per source material for the whole game. Anything else - an
## override a script set (a tinted shield cap), a lit or transparent material, a mesh of several
## materials - draws as it did. The originals keep their own materials: a portrait, the block in
## the hand and a part leaving the machine are drawn by them, unchanged.
const BLOCK_LIT := preload("res://block_lit.gdshader")
static var _lit_cache: Dictionary = {}

static func lit_material(mi: MeshInstance3D) -> Material:
	if mi.material_override != null:
		return mi.material_override
	var mesh: Mesh = mi.mesh
	if mesh == null or mesh.get_surface_count() == 0:
		return null
	var src: Material = mi.get_active_material(0)
	for i in range(1, mesh.get_surface_count()):
		if mi.get_active_material(i) != src:
			return null
	var sm := src as BaseMaterial3D
	if sm == null or sm.shading_mode != BaseMaterial3D.SHADING_MODE_UNSHADED \
			or sm.transparency != BaseMaterial3D.TRANSPARENCY_DISABLED \
			or sm.blend_mode != BaseMaterial3D.BLEND_MODE_MIX:
		return null
	var id: int = sm.get_instance_id()
	if _lit_cache.has(id):
		return _lit_cache[id]
	var m := ShaderMaterial.new()
	m.shader = BLOCK_LIT
	m.set_shader_parameter("albedo_texture", sm.albedo_texture)
	m.set_shader_parameter("albedo_color", sm.albedo_color)
	m.set_shader_parameter("use_vertex_color", sm.vertex_color_use_as_albedo)
	m.set_shader_parameter("uv_scale", sm.uv1_scale)
	m.set_shader_parameter("uv_offset", sm.uv1_offset)
	_lit_cache[id] = m
	return m

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
