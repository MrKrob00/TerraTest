extends SceneTree
# Builds the big armour plates out of the artist's one-cell plate (objects/GSO_Plane.res):
#
#   godot --headless --path . --script res://art/armor_plates.gd
#       -> blocks/meshes/armor_2x1.tres, armor_2x2.tres, armor_3x3.tres
#
# Each cell of a big plate is the small plate itself - its grey panel, its bolts, its frame - on
# the artist's own two materials, so a x4 beside a x1 is one family, not a copy of it in another
# palette. On the edges INSIDE the plate the bevel is flattened out (0.4654 -> 0.5): the bevel is
# what makes a plate's edge, and left on every cell it cut a groove between them, so four cells
# read as four plates bolted side by side instead of one slab (the hull blocks' rule: two parts
# read as one only when they meet flat).
#
# The small plate lies in its mesh's XZ plane and the scenes turn it -90 deg about X onto the cell's
# back face, so a cell at block (dx, dy) sits at mesh (dx, 0, -dy). The cells are the footprints in
# blocks._footprint_offsets: x2 dx -1..0; x4 dx -1..0, dy 0..1; x9 dx -1..1, dy -1..1.
const SRC := "res://objects/GSO_Plane.res"
const BEVEL := 0.465401        # the small plate's bevel foot, in its own mesh
const HALF := 0.5

const PLATES := {
	"armor_2x1": [Vector2i(-1, 0), Vector2i(0, 0)],
	"armor_2x2": [Vector2i(-1, 0), Vector2i(0, 0), Vector2i(-1, 1), Vector2i(0, 1)],
	"armor_3x3": [Vector2i(-1, -1), Vector2i(0, -1), Vector2i(1, -1), Vector2i(-1, 0), Vector2i(0, 0),
			Vector2i(1, 0), Vector2i(-1, 1), Vector2i(0, 1), Vector2i(1, 1)],
}

func _init() -> void:
	var src: ArrayMesh = load(SRC)
	for name in PLATES:
		var cells: Array = PLATES[name]
		var out := ArrayMesh.new()
		for s in src.get_surface_count():
			var a := src.surface_get_arrays(s)
			var sv: PackedVector3Array = a[Mesh.ARRAY_VERTEX]
			var sn: PackedVector3Array = a[Mesh.ARRAY_NORMAL]
			var suv: PackedVector2Array = a[Mesh.ARRAY_TEX_UV]
			var si = a[Mesh.ARRAY_INDEX]
			var v := PackedVector3Array()
			var n := PackedVector3Array()
			var uv := PackedVector2Array()
			var idx := PackedInt32Array()
			for c in cells:
				var cell: Vector2i = c
				# Which of this cell's four sides meet another cell of the plate.
				var inner_px: bool = cells.has(Vector2i(cell.x + 1, cell.y))
				var inner_nx: bool = cells.has(Vector2i(cell.x - 1, cell.y))
				var inner_top: bool = cells.has(Vector2i(cell.x, cell.y + 1))     # block +Y = mesh -Z
				var inner_bot: bool = cells.has(Vector2i(cell.x, cell.y - 1))
				var base: int = v.size()
				for i in sv.size():
					var p: Vector3 = sv[i]
					if inner_px and is_equal_approx(p.x, BEVEL): p.x = HALF
					if inner_nx and is_equal_approx(p.x, -BEVEL): p.x = -HALF
					if inner_top and is_equal_approx(p.z, -BEVEL): p.z = -HALF
					if inner_bot and is_equal_approx(p.z, BEVEL): p.z = HALF
					v.append(p + Vector3(cell.x, 0.0, -cell.y))
					n.append(sn[i] if sn.size() > i else Vector3.UP)
					uv.append(suv[i] if suv.size() > i else Vector2.ZERO)
				if si != null:
					for k in (si as PackedInt32Array):
						idx.append(base + k)
				else:
					for k in sv.size():
						idx.append(base + k)
			var arr := []
			arr.resize(Mesh.ARRAY_MAX)
			arr[Mesh.ARRAY_VERTEX] = v
			arr[Mesh.ARRAY_NORMAL] = n
			arr[Mesh.ARRAY_TEX_UV] = uv
			arr[Mesh.ARRAY_INDEX] = idx
			out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
			out.surface_set_material(out.get_surface_count() - 1, src.surface_get_material(s))
		out.resource_name = name
		var dst := "res://blocks/meshes/%s.tres" % name
		var err := ResourceSaver.save(out, dst)
		print("saved ", dst, " err ", err, " cells ", cells.size())
	quit()
