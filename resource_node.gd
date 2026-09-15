extends StaticBody3D
# Жила руды. Руда НЕ создаётся заранее — жила хранит только счётчик _available и штампует
# готовый ресурс (resource_tscn) в мир лишь в момент выброса (экономит ~1000 узлов на карте).
# По урону (hurt) HP падает и вылетает столько руды, чтобы её осталось пропорционально HP;
# когда пусто — $RestTimer, и через паузу жила наполняется заново. instance_id — слот в
# MultiMesh для шейдера истощения; ore_type/ore_color — тип/цвет жилы (задаёт спавнер).

const MAX_RESOURCES: int = 5

@export var resource_tscn: PackedScene
@export var max_hp: int = 100

var current_hp: int = 0
var instance_id: int = 0
var ore_type: int = 0
var ore_color: Color = Color(1.0, 0.75, 0.0)        # цвет вылетающей руды (тинт)
var is_coal: bool = false                           # угольная жила: выброс = COAL, без тинта
var _available: int = MAX_RESOURCES                 # сколько руды осталось в жиле (логически)

## КТО ЗАНЯЛ ЖИЛУ (авто-шахтёр). Пока он стоит, жила НЕ ВОССТАНАВЛИВАЕТСЯ: выбирать надо —
## либо выработанную жилу медленно и вечно скребёт шахтёр, либо она отдыхает пять секунд и
## снова отдаётся буру. Обе награды сразу с одной точки — это не выбор, а бесплатный апгрейд.
var claimed_by: Node = null

## Жила выработана: руды в ней сейчас нет (идёт отдых или её занял шахтёр).
func is_depleted() -> bool:
	return _available <= 0

## Занять ВЫРАБОТАННУЮ жилу. Отказ — если в ней ещё есть руда (сначала выкопай) или её уже
## занял другой шахтёр. Отдых при этом останавливаем: пока стоит шахтёр, жиле нечего
## восстанавливать.
func claim(by: Node) -> bool:
	if by == null or not is_depleted():
		return false
	if claimed_by != null and is_instance_valid(claimed_by) and claimed_by != by:
		return false
	claimed_by = by
	$RestTimer.stop()
	return true

## Шахтёра не стало — жила снова живёт своей жизнью и начинает отдых с этой секунды.
func release(by: Node) -> void:
	if claimed_by != by:
		return
	claimed_by = null
	if _available <= 0:
		$RestTimer.start()

## Выдать одну руду ПО ТРЕБОВАНИЮ занявшего шахтёра. Ни HP, ни _available не трогаем
## намеренно: шахтёр не оживляет жилу, он выскребает то, что бур достать уже не может, и
## для всех остальных она остаётся пустой.
func mine_for_claimer(by: Node) -> bool:
	if claimed_by != by or not is_depleted():
		return false
	_eject_one()
	return true

# Второй MultiMesh — в него пишем состояние жилы для шейдера истощения.
@onready var _depletion_mm: MultiMeshInstance3D = get_node_or_null("../MultiMeshInstance3D2")

func _ready() -> void:
	current_hp = max_hp

# Урон по жиле: списываем HP и выбрасываем руду, пока её не останется пропорционально HP.
func hurt(damage: int = 10) -> void:
	if _available <= 0:
		return

	current_hp = clampi(current_hp - damage, 0, max_hp)
	# R — время удара (тряска), G — доля HP, A — тип (цвет).
	_write_shader_data(Color(_now(), float(current_hp) / float(max_hp), 0.0, float(ore_type)))

	var want_left: int = int(float(current_hp) / float(max_hp) * MAX_RESOURCES)
	while _available > want_left:
		_eject_one()
		_available -= 1

	if _available <= 0:
		$RestTimer.start()

# Штампуем один ресурс в мир рядом с жилой и красим его под цвет жилы.
func _eject_one() -> void:
	if resource_tscn == null:
		return
	var res: Node3D = resource_tscn.instantiate()
	# Выброшенная руда обязана лечь в /root/Main/objects — там живут ВСЕ свободные предметы
	# мира, и по этому родителю их узнают приёмник, упаковщик, подбор в руку и сохранение
	# мира. Раньше она падала под жилу, то есть в узел СТРИМИНГА залежей: формально в мире,
	# а по факту невидимая для всего, кроме коллектора (он смотрит на freeze, а не на имя).
	var objects: Node = get_node_or_null("/root/Main/objects")
	if objects == null:
		objects = get_parent()                # мира ещё нет (тест сцены) — как раньше, под жилу
	objects.add_child(res)
	res.global_position = global_position + Vector3(randf_range(-1.5, 1.5), 1.0, randf_range(-1.5, 1.5))
	if is_coal and "type" in res:
		res.type = res.Type.COAL              # уголь: тёмный сам по себе, тинт не нужен
	elif res.has_method("set_metal"):
		# ore_type жилы — это и есть индекс металла (G.Metal): спавнер раздаёт типы по тому же
		# списку цветов, что и G.METAL_COLOR. Цвет ставит сам set_metal, поэтому set_tint здесь
		# не нужен — иначе жила и её руда могли бы разъехаться по цвету.
		res.set_metal(ore_type)
	elif res.has_method("set_tint"):
		res.set_tint(ore_color)
	Q.report("ore_mined", 1)                    # прогресс заданий на добычу

# Жила восстановилась: снова полна руды, HP сброшен.
func _on_rest_timer_timeout() -> void:
	# ЗАНЯТАЯ ЖИЛА НЕ ВОССТАНАВЛИВАЕТСЯ. Таймер мы останавливаем в claim(), но он мог уже
	# тикать в момент постановки — и тогда жила налилась бы рудой прямо под шахтёром.
	if claimed_by != null and is_instance_valid(claimed_by):
		return
	_available = MAX_RESOURCES
	current_hp = max_hp
	# B — время респавна (рост), G=1 → жила целая, A — тип.
	_write_shader_data(Color(0.0, 1.0, _now(), float(ore_type)))

func _now() -> float:
	return Time.get_ticks_msec() / 1000.0

func _write_shader_data(data: Color) -> void:
	if _depletion_mm and _depletion_mm.multimesh:
		_depletion_mm.multimesh.set_instance_custom_data(instance_id, data)
