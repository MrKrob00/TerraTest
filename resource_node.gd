extends StaticBody3D
# Жила руды. Внутри ($resources) лежат готовые ресурсы (отключённые RigidBody). По урону
# (hurt) жила теряет HP и выбрасывает столько руды, чтобы её осталось пропорционально HP.
# Когда пусто — уходит на восстановление ($RestTimer) и через паузу наполняется заново.
# instance_id — слот в MultiMesh, куда пишем данные для шейдера (истощение/респавн).

const MAX_RESOURCES: int = 5

@export var resource_tscn: PackedScene
@export var max_hp: int = 100
@export var resources: Node3D                       # контейнер с рудой внутри жилы

var current_hp: int = 0
var instance_id: int = 0
var ore_type: int = 0                                # тип/цвет жилы (задаёт спавнер), в A-канал

# Второй MultiMesh — тот, в который пишем состояние жилы для шейдера истощения.
@onready var _depletion_mm: MultiMeshInstance3D = get_node_or_null("../MultiMeshInstance3D2")

func _ready() -> void:
	current_hp = max_hp

# Урон по жиле: списываем HP и выбрасываем руду, пока её не останется пропорционально HP.
func hurt(damage: int = 10) -> void:
	if resources == null or resources.get_child_count() == 0:
		return

	current_hp = clampi(current_hp - damage, 0, max_hp)
	# R — время удара (запускает в шейдере анимацию тряски), G — доля HP, A — тип (цвет).
	_write_shader_data(Color(_now(), float(current_hp) / float(max_hp), 0.0, float(ore_type)))

	var want_left: int = int(float(current_hp) / float(max_hp) * MAX_RESOURCES)
	while resources.get_child_count() > want_left:
		_eject_one()

	if resources.get_child_count() == 0:
		$RestTimer.start()

# Выкидываем одну руду из жилы в мир: включаем физику, ставим рядом и отвязываем от жилы
# (reparent сохраняет мировую позицию → руда падает возле жилы, а не в центре контейнера).
func _eject_one() -> void:
	var res: Node3D = resources.get_child(0)
	res.process_mode = Node.PROCESS_MODE_INHERIT
	res.position = Vector3(randf_range(-1.5, 1.5), 1.0, randf_range(-1.5, 1.5))
	res.reparent(get_parent())

# Жила восстановилась: наполняем заново отключённой рудой и сбрасываем HP.
func _on_rest_timer_timeout() -> void:
	for i in MAX_RESOURCES:
		var res := resource_tscn.instantiate()
		res.process_mode = Node.PROCESS_MODE_DISABLED
		resources.add_child(res)
	current_hp = max_hp
	# B — время респавна (запускает в шейдере анимацию роста), G=1 → жила снова целая, A — тип.
	_write_shader_data(Color(0.0, 1.0, _now(), float(ore_type)))

func _now() -> float:
	return Time.get_ticks_msec() / 1000.0

func _write_shader_data(data: Color) -> void:
	if _depletion_mm and _depletion_mm.multimesh:
		_depletion_mm.multimesh.set_instance_custom_data(instance_id, data)
