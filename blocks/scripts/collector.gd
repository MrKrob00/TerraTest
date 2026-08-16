extends VehicleBlock

var is_on_vehicle: bool = false
var inventory:Array = []
@export var capacity: int = 2

# ФИЗИКА (freeze тела, monitoring ареи) — в _physics_process: это свойства физического сервера,
# менять их надо на физ-тике, а не на кадре отрисовки (иначе правки летят в произвольный момент
# шага физики и лишний раз дёргают сервер на быстрых экранах).
func _physics_process(_delta: float) -> void:
	if $"..".name == "objects":
		if is_on_vehicle:
			$collector.monitoring = false
			is_on_vehicle = false
		return
	if !is_on_vehicle:
		$collector.monitoring = true
		is_on_vehicle = true
	elif not freeze:
		freeze = true

# ВИЗУАЛ (вращение тарелки, подтяжка её высоты) — в _process: должен идти по кадрам отрисовки,
# чтобы крутился плавно и на экранах с частотой выше физ-тика.
func _process(delta: float) -> void:
	if !is_on_vehicle: return
	$collector/MeshInstance3D.rotation.y += deg_to_rad(360)*delta/6
	$collector/MeshInstance3D.global_position.y = get_parent().global_position.y

const RESOURCE_SCENE: String = "res://resource.tscn"
var _res_scene: PackedScene = null

func _on_collector_body_entered(body: RigidBody3D) -> void:
	if inventory.has(body): return  # ← уже в инвентаре, игнорируем
	elif body.freeze:
		return
	# СВОБОДНЫЙ БЛОК пакуем в чанк, а не тащим как есть. Коллектор и раньше засасывал блоки
	# (они в мире незаморожены и проходят проверку выше), но нёс их целиком — тяжёлое тело с
	# коллизией занимало слот. Теперь блок исчезает, а в инвентаре растёт счётчик чанка: на
	# ленту уедет ОДИН предмет, даже если в нём двадцать четыре блока.
	if "block" in body:
		_pack_block(body)
		return
	if inventory.size()>=capacity:
		return
	body.reparent($resources)
	if inventory.has(body): return
	inventory.append(body)
	body.freeze = true
	fix_position_resources.call_deferred(body)

# Положить блок в чанк: в подходящий уже собранный, иначе завести новый.
#
# Блок ДРУГОГО типа начинает новый чанк, а не отбрасывается: выброшенный трофей — это
# молчаливая потеря добычи, то есть ровно тот сорт бага, которого мы избегаем везде.
func _pack_block(body: RigidBody3D) -> void:
	var bt: int = int(body.get("block"))
	for it in inventory:
		if not is_instance_valid(it):
			continue
		if int(it.get("type")) == 3 and int(it.get("chunk_block")) == bt \
				and int(it.get("chunk_count")) < 24:          # 3 = Type.CHUNK
			it.set("chunk_count", int(it.get("chunk_count")) + 1)
			body.queue_free()
			return
	if inventory.size() >= capacity:
		return                                                # места нет — блок остаётся лежать
	if _res_scene == null:
		_res_scene = load(RESOURCE_SCENE) as PackedScene
	if _res_scene == null:
		return
	var chunk: Node3D = _res_scene.instantiate() as Node3D
	if chunk == null:
		return
	chunk.set("type", 3)                                      # Type.CHUNK
	chunk.set("chunk_block", bt)
	chunk.set("chunk_count", 1)
	$resources.add_child(chunk)
	chunk.freeze = true
	inventory.append(chunk)
	body.queue_free()
	fix_position_resources.call_deferred(chunk)

func fix_position_resources(body:Node3D):
	body.position = Vector3(0,inventory.find(body)+1,0)

func _on_resources_child_order_changed() -> void:
	for i in inventory:
		if i.get_parent() != $resources:
			inventory.erase(i)
		else: i.position = Vector3(0,inventory.find(i)+1,0)
