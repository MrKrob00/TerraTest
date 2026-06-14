extends VehicleBlock

@export var laser_damage: int = 5
@export var laser_range: float = 10.0
@export var fire_rate: float = 0.2
@export var raycast: RayCast3D
@export var pivot: Node3D

const YAW_LIMIT   = 45.0
const PITCH_LIMIT = 30.0

var _fire_timer: float = 0.0
var _firing: bool = false
var _targets: Array[Node3D] = []
var _current_target: Node3D = null

func _ready() -> void:
	super._ready()
	raycast.target_position = Vector3(0, 0, -laser_range)

func _process(delta: float) -> void:
	_update_current_target()
	raycast.force_raycast_update()
	_track_target(delta)
	if not _firing:
		return
	if Input.is_action_just_released("Attack"):
		_firing = false
	_handle_fire(delta)

func attack() -> void:
	_firing = true

func _is_in_cone(body: Node3D) -> bool:
	var dir_world = (body.global_position - pivot.global_position).normalized()
	var dir_local = pivot.global_transform.basis.inverse() * dir_world
	var yaw   = abs(rad_to_deg(atan2(-dir_local.x, -dir_local.z)))
	var pitch = abs(rad_to_deg(atan2(dir_local.y,
			Vector2(dir_local.x, dir_local.z).length())))
	return yaw <= YAW_LIMIT and pitch <= PITCH_LIMIT

func _update_current_target() -> void:
	#_targets = _targets.filter(func(t): return is_instance_valid(t) and _is_in_cone(t))

	if _targets.is_empty():
		_current_target = null
		return

	var closest: Node3D = null
	var closest_dist = INF
	for t in _targets:
		var d = pivot.global_position.distance_to(t.global_position)
		if d < closest_dist:
			closest_dist = d
			closest = t
	_current_target = closest

func _track_target(delta: float) -> void:
	var laser_visual = raycast.get_node("laservisual")
	var laser_mat = laser_visual.get_active_material(0)
	var mesh = laser_visual.mesh as CylinderMesh

	if _current_target == null or !_is_in_cone(_current_target):
		raycast.debug_shape_custom_color = Color(0, 1, 0)
		mesh.height = laser_range
		laser_visual.position.z = -laser_range / 2.0
		if laser_mat:
			laser_mat.albedo_color = Color(0, 1, 0)
		pivot.rotation = lerp(pivot.rotation, Vector3.ZERO, 0.1)
		return

	# Берём центр AABB блока а не origin
	var target_pos = _current_target.global_position
	if _current_target is MeshInstance3D:
		target_pos = _current_target.get_aabb().get_center() + _current_target.global_position
	elif _current_target.has_node("CollisionShape3D"):
		target_pos = _current_target.get_node("CollisionShape3D").global_position

	var dir_world = (target_pos - pivot.global_position).normalized()
	var dir_local = global_transform.basis.inverse() * dir_world

	var yaw   = rad_to_deg(atan2(-dir_local.x, -dir_local.z))
	var pitch = rad_to_deg(atan2(dir_local.y,
			Vector2(dir_local.x, dir_local.z).length()))

	yaw   = clamp(yaw,   -YAW_LIMIT,   YAW_LIMIT)
	pitch = clamp(pitch, -PITCH_LIMIT, PITCH_LIMIT)

	if laser_mat:
		laser_mat.albedo_color = Color(1, 0, 0)

	var target_rot = Vector3(deg_to_rad(pitch), deg_to_rad(yaw), 0)
	pivot.rotation = lerp(pivot.rotation, target_rot, 15.0 * delta)

	if raycast.is_colliding():
		raycast.debug_shape_custom_color = Color(1, 0, 0)
		var hit_point = raycast.get_collision_point()
		var dist = min(raycast.global_position.distance_to(hit_point), laser_range)
		mesh.height = dist
		laser_visual.position.z = -dist / 2.0
	else:
		raycast.debug_shape_custom_color = Color(0, 1, 0)
		mesh.height = laser_range
		laser_visual.position.z = -laser_range / 2.0

func _handle_fire(delta: float) -> void:
	if _current_target == null or not raycast.is_colliding():
		return
	var body = raycast.get_collider()
	if body == self or body.get_parent() == get_parent():
		return
	_fire_timer -= delta
	if _fire_timer > 0.0:
		return
	_fire_timer = fire_rate
	if body.has_method("hurt"):
		body.hurt(laser_damage)

func _on_area_3d_body_entered(body: Node3D) -> void:
	if body == self or body.get_parent() == get_parent():
		return
	if not _targets.has(body):
		_targets.append(body)

func _on_area_3d_body_exited(body: Node3D) -> void:
	_targets.erase(body)
