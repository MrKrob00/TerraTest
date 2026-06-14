extends StaticBody3D

@export var resource_tscn: PackedScene
@export var max_hp: int = 100
@export var resources:Node3D
var current_hp: int = 100
var _last_resource_count: int = 5  # сколько ресурсов было при полном 
var instance_id
func _ready() -> void:
	current_hp = max_hp

func hurt(damage: int = 10) -> void:
	# Получаем точное текущее время движка
	var current_time = Time.get_ticks_msec() / 1000.0
	

	if resources.get_child_count() == 0: return

	current_hp -= damage
	current_hp = max(current_hp, 0)

	var j = $"../MultiMeshInstance3D2"
	if j:
		var depleted_data = Color(current_time, current_hp/100.0, 0.0, 0.0)
		# Обновляем кастомные данные ТОЛЬКО для одного побитого объекта
		j.multimesh.set_instance_custom_data(instance_id, depleted_data)
		j.multimesh.notify_property_list_changed() # Сколько ресурсов должно быть при текущем HP
	var total = resources.get_child_count() + _spawned_count()
	var target = int(float(current_hp) / float(max_hp) * 5.0)
	var to_spawn = _spawned_count() - target  # сколько выкинуть

	for i in to_spawn:
		if resources.get_child_count() == 0: break
		if $AnimationPlayer.is_playing():
			await $AnimationPlayer.animation_finished
		#$AnimationPlayer.play("breaking")
		#await $AnimationPlayer.animation_finished
		_eject_resource()

	if resources.get_child_count() == 0:
		$RestTimer.start()

var _ejected: int = 0

func _spawned_count() -> int:
	return resources.get_child_count()

func _eject_resource() -> void:
	if resources.get_child_count() == 0: return
	
	# ДОПИСАНО: Перед тем как выкинуть дроп, говорим шейдеру, что эта жила исчерпана (Зеленый канал = 1.0)


	var resource = resources.get_child(0)
	resource.process_mode = Node.PROCESS_MODE_INHERIT
	resource.position = Vector3(randf_range(-1.5, 1.5), 1.0, randf_range(-1.5, 1.5))
	resource.reparent(get_parent())


func _on_rest_timer_timeout() -> void:
	for i in 5:
		var resource = resource_tscn.instantiate()
		resource.process_mode = Node.PROCESS_MODE_DISABLED
		resources.add_child(resource)

	current_hp = max_hp
	
	# ДОПИСАНО: Руда восстановилась, передаем время респавна в Синий канал (B)
	var j = $"../MultiMeshInstance3D2"
	if j:
		var current_time = Time.get_ticks_msec() / 1000.0
		# R=0, G=0 (снова целая), B=время респавна (запустит анимацию роста)
		var respawn_data = Color(0.0, 1.0, current_time, 0.0)
		j.multimesh.set_instance_custom_data(instance_id, respawn_data)
		j.multimesh.notify_property_list_changed()
