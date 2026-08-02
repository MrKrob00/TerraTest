extends VehicleBlock



var is_on_vehicle: bool = false
var inventory:Array = []
@export var capacity: int = 2

# ФИЗИКА (freeze тела, monitoring ареи) — в _physics_process: это свойства физического сервера,
# менять их надо на физ-тике, а не на кадре отрисовки (иначе правки летят в произвольный момент
# шага физики и лишний раз дёргают сервер на быстрых экранах).
func _physics_process(_delta: float) -> void:
	if $"..".name in "objects":
		if is_on_vehicle:
			$collector.monitoring = false
			is_on_vehicle = false
		return
	if !is_on_vehicle:
		$collector.monitoring = true
		is_on_vehicle = true
		freeze = false
	else: freeze = true

# ВИЗУАЛ (вращение тарелки, подтяжка её высоты) — в _process: должен идти по кадрам отрисовки,
# чтобы крутился плавно и на экранах с частотой выше физ-тика.
func _process(delta: float) -> void:
	if !is_on_vehicle: return
	$collector/MeshInstance3D.rotation.y += deg_to_rad(360)*delta/6
	$collector/MeshInstance3D.global_position.y = get_parent().global_position.y


func _on_collector_body_entered(body: RigidBody3D) -> void:
	if inventory.has(body): return  # ← уже в инвентаре, игнорируем
	if inventory.size()>=capacity: 
		return 
	elif body.freeze:
		return
	body.reparent($resources)
	if inventory.has(body): return
	inventory.append(body)
	body.freeze = true
	fix_position_resources.call_deferred(body)

func fix_position_resources(body:Node3D):
	body.position = Vector3(0,inventory.find(body)+1,0)


func _on_resources_child_order_changed() -> void:
	for i in inventory:
		if i.get_parent() != $resources:
			inventory.erase(i)
		else: i.position = Vector3(0,inventory.find(i)+1,0)
