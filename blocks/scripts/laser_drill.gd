extends "res://blocks/scripts/drill.gd"
## THE MARLIT LASER DRILL: the drill's blows and reach (`drill.gd`), an ENERGY blow on a machine, and
## a cyan BEAM from the lens out through its zone while it works. The beam is a node this script makes
## (not batched: MachineBatch takes only the scene's own meshes), shown only while the head turns.

## The lens's face, in block space (art/marlit_cutters.py LENS_END), and THE BEAM'S REACH, 3 m out of
## it (the player's call): the zone in the scene is a capsule along exactly that stretch, so whatever
## the beam reaches is what a blow hits. The DRAWN beam stops at the first thing in its way (a ray while
## it is on), or it would run through the vein it is cutting.
const LENS := Vector3(-0.5, 0.5, -1.42)
const REACH := 3.0
const BEAM_END_Z := LENS.z - REACH
const BEAM_R := 0.07
const BEAM_COLOR := Color(0.35, 0.95, 1.0, 0.85)
## The beam flickers by this much of its width, so a still frame does not read as a rod.
const FLICKER := 0.35

var _beam: MeshInstance3D = null

func _init() -> void:
	dig_kind = VehicleBlock.Dmg.ENERGY

func _ready() -> void:
	super()
	_beam = MeshInstance3D.new()
	_beam.set_meta(&"block_fx", true)        # _local_aabb and the portrait skip it
	var m := CylinderMesh.new()
	m.top_radius = BEAM_R
	m.bottom_radius = BEAM_R
	m.height = 1.0              # scaled to the beam's length along its axis
	m.radial_segments = 6
	m.rings = 1
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	mat.albedo_color = BEAM_COLOR
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.material = mat
	_beam.mesh = m
	_beam.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_beam.visible = false
	add_child(_beam)

func _physics_process(delta: float) -> void:
	super(delta)
	if _beam == null:
		return
	var on: bool = _spin_t > 0.0
	if _beam.visible != on:
		_beam.visible = on
	if on:
		var w: float = 1.0 + randf_range(-FLICKER, FLICKER)
		var ln: float = _beam_length()
		# a cylinder stands along Y: turned onto the drill's axis, its middle halfway out
		_beam.transform = Transform3D(Basis(Vector3.RIGHT, PI / 2) * Basis.from_scale(Vector3(w, ln, w)),
				Vector3(LENS.x, LENS.y, LENS.z - ln * 0.5))

var _ray: PhysicsRayQueryParameters3D = null

## How far the beam runs before it meets something: the ground, a vein or a block not of this machine.
func _beam_length() -> float:
	var world := get_world_3d()
	if world == null or not is_inside_tree():
		return REACH
	if _ray == null:
		_ray = PhysicsRayQueryParameters3D.new()
		_ray.collision_mask = VehicleBlock.block_mask(1 | 2 | 4)
		_ray.hit_back_faces = false
	var own := _root_body()
	_ray.exclude = [(own as CollisionObject3D).get_rid()] if own is CollisionObject3D else []
	_ray.from = to_global(LENS)
	_ray.to = to_global(Vector3(LENS.x, LENS.y, BEAM_END_Z))
	var hit := world.direct_space_state.intersect_ray(_ray)
	if hit.is_empty():
		return REACH
	return clampf(_ray.from.distance_to(hit.position), 0.05, REACH)
