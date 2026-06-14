extends Node3D

@export var resource_nodes: Array[PackedScene]
@export var HeightMap: HeightMapShape3D
@export var multimesh_nodes: Array[MultiMeshInstance3D]

func _ready() -> void:
	var max_x = HeightMap.map_depth
	var max_y = HeightMap.map_width
	var map_data = HeightMap.map_data
	
	var offset_x = (max_x - 1) / 2.0
	var offset_y = (max_y - 1) / 2.0
	
	
	# Сначала собираем все подходящие позиции в массив
	var spawn_positions: Array[Vector3] = []
	

	for i in 200:
		var x = randi()%200
		var y = randi()%200
		var index = y * max_x + x
		var height = map_data[index]
		var pos_x = (x - offset_x)
		var pos_z = (y - offset_y)
		spawn_positions.append(Vector3(pos_x, height+0.25, pos_z))
	
	for i in multimesh_nodes:
		i.multimesh.instance_count = 0
		i.multimesh.use_custom_data = true 
		i.multimesh.instance_count = spawn_positions.size()
	# Передаем координаты и пустые кастомные данные видеокарте
	for i in spawn_positions.size():
		var basis = Basis() # Здесь можно добавить случайный поворот или масштаб
		var transform_3d = Transform3D(basis, spawn_positions[i])
		
		var resource_node = resource_nodes.pick_random().instantiate()
		resource_node.position = spawn_positions[i]
		resource_node.instance_id = i
		add_child(resource_node)
		# Создаем "пустой" цвет. 0.0 в R-канале скажет шейдеру: "урона еще не было"
		var default_custom_data = Color(0.0, 0.0, 0.0, 0.0)
		
		for j in multimesh_nodes:
			j.multimesh.set_instance_transform(i, transform_3d)
			# 3. Заполняем память нулями для каждого объекта
			j.multimesh.set_instance_custom_data(i, default_custom_data)
