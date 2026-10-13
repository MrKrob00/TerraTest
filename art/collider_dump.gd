extends SceneTree
## Vertex dump for `art/fit_colliders.py`: every MeshInstance3D a block's scene owns, in the block's own
## axes at rest, keyed by its node path (the fitter drops the tyre and the ammo template by path), plus
## the scene's box and the block's footprint cells. Run on a COPY (CLAUDE.md §3):
##   godot --headless --path <copy> --script res://art/collider_dump.gd
## then  python3 art/fit_colliders.py <the printed path>
## A block's model changed means both re-run: a fitted collider is a picture of the model.

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	var g = root.get_node("G")
	var bl = load("res://blocks.gd").new()
	var out := {}
	for i in g.Block.size():
		var sc: PackedScene = g.get_scene(i)
		if sc == null:
			continue
		var inst: Node3D = sc.instantiate()
		var parts := {}
		for n in inst.find_children("*", "MeshInstance3D", true, false):
			var mi := n as MeshInstance3D
			if mi.mesh == null or mi.owner != inst:
				continue
			var t := Transform3D()
			var p: Node = mi
			var path := ""
			while p != inst:
				t = (p as Node3D).transform * t
				path = String(p.name) + "/" + path
				p = p.get_parent()
			var vs := []
			for s in mi.mesh.get_surface_count():
				var a: Array = mi.mesh.surface_get_arrays(s)
				var va: PackedVector3Array = a[Mesh.ARRAY_VERTEX]
				for v in va:
					var w: Vector3 = t * v
					vs.append([w.x, w.y, w.z])
			parts[path] = vs
		var col := {}
		for ch in inst.get_children():
			if ch is CollisionShape3D and ch.shape != null:
				if ch.shape is BoxShape3D:
					var off: Vector3 = bl.collider_offset(ch.shape, Vector3.ZERO)
					col = {"box": [ch.shape.size.x, ch.shape.size.y, ch.shape.size.z], "off": [off.x, off.y, off.z]}
				else:
					col = {"type": ch.shape.get_class()}
				break
		var fo := []
		for c in bl._footprint_offsets(i):
			fo.append([c.x, c.y, c.z])
		out[g.Block.keys()[i]] = {"parts": parts, "col": col, "cells": fo}
		inst.free()
	bl.free()
	var f := FileAccess.open("user://collider_dump.json", FileAccess.WRITE)
	f.store_string(JSON.stringify(out))
	f.close()
	print("DUMPED ", ProjectSettings.globalize_path("user://collider_dump.json"))
	quit()
