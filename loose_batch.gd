extends Node
# A SLEEPING LOOSE BLOCK IS DRAWN BY A MULTIMESH, like a block on a machine (machine_batch.gd).
#
# Measured on the real driver: fifty blocks lying in view added 130 draw calls, 2.6 a block - a gun
# or a big wheel is a chain of meshes, and each loose block drew all of them itself. A block that
# has come to rest does not move, so its instances are written once; the moment it wakes, is picked
# up or is bolted onto a machine it takes its own drawing back, before anything else sees it.
#
# ONLY SLEEPING BLOCKS. A falling or rolling one would need its transform copied every frame, and
# the whole point is that settled debris costs nothing. Membership is decided by world_persist's
# cull pass (the one walk over loose items that already exists); the WAKE is caught at once through
# `sleeping_state_changed`, or a knocked block would hang in its old place for a quarter second.
#
# SPLIT BY CELL, not one MultiMesh per mesh for the whole world: a MultiMesh is culled by its AABB as
# a single object, and one spanning every scrap heap on the map would never leave the frame.
#
# The originals keep `visible` and lose only their LAYERS, as on a machine, so everything that asks
# `visible` (the cull pass, effects measuring a block) behaves as before.

const MACHINE_BATCH := preload("res://machine_batch.gd")
const CELL := 64.0

var _members: Dictionary = {}    # block instance_id -> block
var _by_block: Dictionary = {}   # block instance_id -> Array of its batched meshes
var _hidden: Dictionary = {}     # mesh instance_id -> [mesh, old layers]
var _groups: Dictionary = {}     # key -> MultiMeshInstance3D
var _dirty: bool = false

func _ready() -> void:
	name = "LooseBatch"
	set_meta("block_fx", true)

## Should this loose block be batched right now. Cheap when nothing changes.
func want(b: VehicleBlock, on: bool) -> void:
	var id: int = b.get_instance_id()
	if on == _members.has(id):
		return
	if on:
		_members[id] = b
		b.sleeping_state_changed.connect(_on_sleep_changed.bind(b))
		b.tree_exiting.connect(_on_gone.bind(b))
	else:
		_drop(b)
	_dirty = true

func count() -> int:
	return _members.size()

func _on_sleep_changed(b: VehicleBlock) -> void:
	if is_instance_valid(b) and not b.sleeping:
		want(b, false)

func _on_gone(b: VehicleBlock) -> void:
	if is_instance_valid(b):
		want(b, false)

func _drop(b: VehicleBlock) -> void:
	var id: int = b.get_instance_id()
	_members.erase(id)
	for mi in _by_block.get(id, []):
		_restore(mi)
	_by_block.erase(id)
	if b.sleeping_state_changed.is_connected(_on_sleep_changed):
		b.sleeping_state_changed.disconnect(_on_sleep_changed)
	if b.tree_exiting.is_connected(_on_gone):
		b.tree_exiting.disconnect(_on_gone)

func _restore(mi) -> void:
	if not is_instance_valid(mi):
		return
	var id: int = mi.get_instance_id()
	if _hidden.has(id):
		(mi as MeshInstance3D).layers = int(_hidden[id][1])
		_hidden.erase(id)

func _process(_delta: float) -> void:
	if not _dirty:
		return
	_dirty = false
	var _pf := Perf.now()
	_rebuild()
	Perf.mark("batch", _pf)

func _rebuild() -> void:
	for id in _hidden.keys():
		_restore(_hidden[id][0])
	_hidden.clear()
	_by_block.clear()
	var found: Dictionary = {}               # key -> [mesh, ...]
	for id in _members.keys():
		var b = _members[id]
		if not is_instance_valid(b) or not (b as Node).is_inside_tree() or b.is_queued_for_deletion():
			_members.erase(id)
			continue
		var mine: Array = []
		MACHINE_BATCH._collect(b, b, (b as VehicleBlock).unbatched(), mine)
		if mine.is_empty():
			continue
		_by_block[id] = mine
		var p: Vector3 = (b as Node3D).global_position
		var cell: String = "%d,%d" % [floori(p.x / CELL), floori(p.z / CELL)]
		for mi in mine:
			var key: String = MACHINE_BATCH._key(mi) + "@" + cell
			if not found.has(key):
				found[key] = []
			found[key].append(mi)
	for key in _groups.keys():
		if not found.has(key):
			var old = _groups[key]
			if is_instance_valid(old):
				old.queue_free()
			_groups.erase(key)
	for key in found:
		var list: Array = found[key]
		var first: MeshInstance3D = list[0]
		var mmi: MultiMeshInstance3D = _groups.get(key, null)
		if not is_instance_valid(mmi):
			mmi = MultiMeshInstance3D.new()
			mmi.set_meta("block_fx", true)
			mmi.multimesh = MultiMesh.new()
			mmi.multimesh.transform_format = MultiMesh.TRANSFORM_3D
			mmi.multimesh.mesh = first.mesh
			mmi.material_override = MACHINE_BATCH.lit_material(first)
			mmi.cast_shadow = first.cast_shadow
			add_child(mmi)                   # under a plain Node: its transform IS the world
			_groups[key] = mmi
		var mm: MultiMesh = mmi.multimesh
		mm.instance_count = list.size()
		for i in list.size():
			var mi: MeshInstance3D = list[i]
			mm.set_instance_transform(i, mi.global_transform)
			_hidden[mi.get_instance_id()] = [mi, mi.layers]
			mi.layers = 0
