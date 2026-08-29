# processor.gd
extends FactoryBlock

@export var process_time: float = 2.0  # секунд на переработку

var timer_visual: Timer

## Индекс стороны +X в FACE_VECS (см. VehicleBlock): «правый борт» процессора.
const FACE_RIGHT_IDX := 3

func _ready() -> void:
	super._ready()
	_set_processing_visual(false)
	# ТАЙМЕР СОЗДАЁМ ПЕРВЫМ ДЕЛОМ, до всякой настройки портов. Ниже стоит ранний выход «в сцене
	# порты уже настроены — не трогаем», и он уносил с собой создание таймера: на блоке,
	# настроенном кубиком в редакторе, timer_visual оставался null. Дальше приходил ресурс,
	# процессор загорался зелёным (_on_item_received), падал на timer_visual.start() и замирал
	# навсегда: по точкам предмет не ехал, _try_push не звался, вход был занят. Ровно то, на
	# что жаловались — «загорелся зелёным и стоит».
	timer_visual = Timer.new()
	timer_visual.wait_time = process_time / 4.0
	timer_visual.autostart = false
	timer_visual.one_shot = true
	timer_visual.timeout.connect(_on_timer_visual_timeout)
	add_child(timer_visual)
	# ПРАВЫЙ БОРТ настроен ПОКЛЕТОЧНО, а не маской. Смотрим прямо на правую сторону: снизу
	# СЛЕВА процессор забирает с ленты, снизу СПРАВА отдаёт на ленту. Так он встраивается в
	# линию, идущую ВДОЛЬ борта, и её не надо разворачивать вокруг него; вход сзади и выход
	# вперёд при этом никуда не делись — это по-прежнему маски граней.
	#
	# Верхние две клетки правого борта закрыты ЯВНО: маска input_faces включает всю сторону
	# целиком, и без этого «нет» они принимали бы ленту тоже — то есть настройка снизу
	# ничего бы не значила.
	#
	# Смещения — от якоря, а он у 2×2×2 в углу (blocks._block_footprint: x,z ∈ {-1,0},
	# y ∈ {0,1}). Отсюда и центр футпринта, вокруг которого умолчания поворачиваются вместе
	# с блоком.
	# Только если В СЦЕНЕ ничего не настроено: кубик в инспекторе пишет ровно эти же поля,
	# и код не должен затирать то, что настроил художник.
	if not port_defaults.is_empty():
		return
	cells_center = Vector3(-0.5, 0.5, -0.5)
	port_defaults = {
		port_key(Vector3i(0, 0, 0), FACE_RIGHT_IDX): PORT_IN,     # низ, ближняя к +Z клетка
		port_key(Vector3i(0, 0, -1), FACE_RIGHT_IDX): PORT_OUT,   # низ, дальняя
		port_key(Vector3i(0, 1, 0), FACE_RIGHT_IDX): PORT_NONE,
		port_key(Vector3i(0, 1, -1), FACE_RIGHT_IDX): PORT_NONE,
	}

func _on_item_received() -> void:
	_set_processing_visual(true)
	for i in 4:
		timer_visual.start()
		await timer_visual.timeout
	# Визуально — можно покрутить или поменять цвет пока идёт обработка

# Шаг конвейера внутри процессора: предмет переезжает от слота к слоту, посередине пути
# превращаясь из руды в слиток (upgrade).
#
# Следующий слот ищем ПО БЛИЖАЙШЕМУ, а не сравнением позиций на равенство. Точное сравнение
# Vector3 держалось на том, что твин доводит предмет ровно в точку, и разваливалось от любой
# мелочи — блок повернули, машину пересобрали, предмет прицепили другим путём. Промах означал
# «ни один слот не подошёл», а это в старом коде было target = Vector3.ZERO: предмет уезжал в
# центр блока и оставался там навсегда.
func _on_timer_visual_timeout() -> void:
	if current_item == null or not is_instance_valid(current_item):
		return
	var item: Node3D = current_item
	var slots: Array = [$item_slot, $item_slot2, $item_slot3, $item_slot4]
	var idx: int = 0
	var best: float = INF
	for i in slots.size():
		var d: float = item.position.distance_squared_to((slots[i] as Node3D).position)
		if d < best:
			best = d
			idx = i
	if idx >= slots.size() - 1:
		_set_processing_visual(false)
		call_deferred("_try_push")
		return
	if idx == 1 and item.has_method("upgrade"):
		item.upgrade()                       # ровно посередине пути: руда стала слитком
	var tween: Tween = create_tween()
	tween.tween_property(item, "position", (slots[idx + 1] as Node3D).position, 0.3)

func _set_processing_visual(active: bool) -> void:
	var mat: StandardMaterial3D = StandardMaterial3D.new()
	mat.albedo_color = Color.GREEN if active else Color.RED
	$MeshInstance3D.material_override = mat
	# Например мигание или вращение меша процессора
	# Переопределяй под свой визуал
	pass
