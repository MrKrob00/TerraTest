# regen.gd — блок регенерации: раз в интервал чинит повреждённые блоки В РАДИУСЕ, тратя
# энергию своей машины (vehicle.energy_consume). Нет энергии — не чинит.
#
# ЧИНИТ ВСЁ, ДО ЧЕГО ДОТЯГИВАЕТСЯ, а не только свою машину: блок, лежащий на земле, блок
# другой твоей машины, блок ВРАЖЕСКОЙ машины — тоже. И наоборот: вражеский реген лечит блоки
# игрока. Это не недосмотр, а правило — поле маленькое (REGEN_RADIUS), и чтобы им зацепить
# чужую технику, надо стоять к ней вплотную; зато починить сбитый борт соседней машины или
# подобранный хлам можно, не разбирая половину сборки.
extends VehicleBlock

const REGEN_RADIUS := 4.6      # м: как далеко достаёт
## HP ЗА ТИК НА ОДИН БЛОК. Пять в секунду против входящих 25-75 не читались вовсе — поле работало
## только между боями. Это ЕДИНСТВЕННЫЙ ответ игрока на длительный огонь (во вражеских сборках
## регена нет ни в одной, см. blocks.gd), и он обязан быть заметен в бою, а не только после него.
const REGEN_HP := 12
const REGEN_COST := 2.0        # энергии за один подлеченный блок
const REGEN_INTERVAL := 1.0    # с между тиками

## Яркость поля: рабочая и «энергии нет». Поле показывает РАДИУС и то, что блок работает;
## моргать ради привлечения внимания оно не должно, поэтому переход плавный.
const FIELD_ALPHA := 0.09
const FIELD_ALPHA_DEAD := 0.03
## За сколько секунд поле переходит между этими двумя состояниями.
const FIELD_FADE := 0.4

var _timer: float = 0.0
var _field: MultiMeshInstance3D = null
var _field_mat: ShaderMaterial = null
var _alpha: float = FIELD_ALPHA_DEAD

func _ready() -> void:
	super._ready()
	_build_field()

# ── Поле ремонта ─────────────────────────────────────────────────────────────
# Видимая сфера радиусом ровно REGEN_RADIUS, как купол у щита. Без неё радиус был
# невидимой цифрой в коде: игрок не мог знать, дотягивается блок до пробитого борта или
# нет, и ставил реген наугад. Сфера отвечает на это одним взглядом.
#
# Отличие от щита принципиальное: у того купол — ФИЗИЧЕСКОЕ тело, он ловит снаряды и лежит
# на слое блоков. Здесь это чистая графика, без коллизии вовсе: реген ничего не
# перехватывает, он только чинит, и тело ему не нужно.
## Сколько цифр в облаке. Их больше, чем было (14), потому что по набору читается РАДИУС поля:
## пятью-шестью точками сферу не очертить. Закрыть машину они при этом не стали — карточка
## вдвое меньше прежней, и суммарной краски в кадре даже меньше: 30 × 0.4² против 14 × 0.8².
const FIELD_DIGITS := 30
## Размер карточки. Половина прежнего: глиф читается, а сквозь облако видно чинимый борт.
const DIGIT_SIZE := 0.4

func _build_field() -> void:
	# ЦИФРЫ ЛЕТАЮТ ВНУТРИ ОБЪЁМА, А НЕ ПО ОБОЛОЧКЕ ШАРА. Сфера с узором по поверхности честно
	# показывала радиус, но узор на оболочке остаётся узором на оболочке: внутрь он не попадёт
	# никак, сколько его ни двигай. Радиус теперь показывает сам разлёт цифр.
	#
	# MultiMesh: один узел и один вызов отрисовки на всё поле, орбиты считаются в шейдере из
	# TIME, на стороне игры — только четыре числа на цифру, записанные один раз.
	_field = MultiMeshInstance3D.new()
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_custom_data = true
	var q := QuadMesh.new()
	q.size = Vector2(DIGIT_SIZE, DIGIT_SIZE)
	mm.mesh = q
	mm.instance_count = FIELD_DIGITS
	for i in FIELD_DIGITS:
		# Положение задаёт шейдер, поэтому трансформы единичные; фаза, скорость, ВЫСОТА и
		# зерно уезжают в custom data.
		#
		# ВЫСОТА НЕ СЛУЧАЙНАЯ, А ПО НОМЕРУ. Случайная широта на три десятка цифр обязательно
		# оставит дыру у макушки и сгусток у пояса — и поле снова будет читаться как облако на
		# одном уровне. Раскладка по номеру (i + 0.5) / N покрывает высоты ровно.
		var lat: float = (float(i) + 0.5) / float(FIELD_DIGITS)
		mm.set_instance_transform(i, Transform3D())
		mm.set_instance_custom_data(i, Color(randf(), randf(), lat, randf()))
	_field.multimesh = mm
	_field_mat = ShaderMaterial.new()
	_field_mat.shader = preload("res://regen_code.gdshader")
	_field_mat.set_shader_parameter("radius", REGEN_RADIUS)
	_field_mat.set_shader_parameter("active", 0.0)
	_field.material_override = _field_mat
	_field.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# Габарит задаём руками: трансформы инстансов единичные, и посчитанный по ним габарит был
	# бы точкой — поле пропадало бы, едва блок ушёл с края экрана.
	_field.custom_aabb = AABB(Vector3.ONE * -REGEN_RADIUS, Vector3.ONE * (REGEN_RADIUS * 2.0))
	_field.set_meta("block_fx", true)       # в габарит блока не входит (см. _local_aabb)
	add_child(_field)

func _physics_process(delta: float) -> void:
	if freeze == false:
		_show_field(false)
		return                               # валяется в мире — не работает
	var blocks_node := get_parent()
	if blocks_node == null or blocks_node.name != "blocks":
		_show_field(false)
		return
	var vehicle := blocks_node.get_parent()
	if vehicle == null or not vehicle.has_method("energy_consume"):
		_show_field(false)
		return
	# Нехватку энергии показываем ПРИГЛУШЕНИЕМ, а не включением-выключением.
	#
	# Мигало здесь по двум причинам, и обе убраны. Первая: поле вспыхивало на каждый ремонт —
	# раз в секунду, бесконечно, пока идёт починка. Вторая и куда хуже: видимость гонялась
	# напрямую от energy_available(), а та скачет через ноль КАЖДЫЙ тик — выработка панели
	# приходит по капле за кадр, а реген снимает 2.0 разом. Сфера моргала с частотой кадров.
	# Теперь яркость едет к цели плавно, и дрожание источника до картинки не доходит.
	# БЕЗ ЭНЕРГИИ ПОЛЯ НЕТ ВОВСЕ. Раньше оно лишь тускнело, и обесточенный реген выглядел
	# работающим: игрок видел купол и ждал починки, которой не будет. Показываем ровно то,
	# что происходит, — как это делает щит (shield.gd прячет свой купол по тому же признаку).
	var powered: bool = vehicle.has_method("energy_available") and vehicle.energy_available() > 0.0
	_show_field(powered)
	if not powered:
		return
	_fade_field(delta, FIELD_ALPHA)
	_timer -= delta
	if _timer > 0.0:
		return
	_timer = REGEN_INTERVAL
	# Кого чинить, спрашиваем У ФИЗИКИ, а не у своего узла blocks: раньше перебирались только
	# соседи по машине, и поле, накрывшее лежащий на земле блок или борт стоящей рядом машины,
	# не делало с ними ничего. Слой 2 — это блоки, все и всюду: на машине, на базе, в мире.
	for b in _blocks_in_field():
		# СЕБЯ ТОЖЕ ЧИНИМ. Раньше блок себя пропускал, и пробитый реген оставался пробитым:
		# чинил всё вокруг, кроме единственного блока, от которого зависит вся починка.
		if b.current_hp >= b.max_hp:
			continue
		# Платим за каждый блок отдельно: не хватило на этого — дальше смысла нет.
		if vehicle.energy_consume(REGEN_COST) < REGEN_COST:
			break
		b.current_hp = mini(b.current_hp + REGEN_HP, b.max_hp)
		# ПОЧИНКУ ПОКАЗЫВАЕТ САМ ОВЕРЛЁЙ ПОВРЕЖДЕНИЙ: цифры, переставшие быть красными, зеленеют
		# и гаснут. Отдельная зелёная оболочка поверх блока (BlockFX.heal) рисовала то же самое
		# вторым мешем и не говорила, ЧТО именно починили.
		if b.has_method("_refresh_hp_fx"):
			b._refresh_hp_fx()
		# И КОД ЛЕТИТ В БЛОК. Орбита вокруг поля показывает, что оно работает; этот поток
		# показывает, КОГО оно чинит прямо сейчас (см. BlockFX.repair_stream).
		BlockFX.repair_stream(self, b)

## Все блоки в поле — запросом сферой по слою блоков. Потолок в 32 тела берём такой же, как у
## взрыва: поле маленькое, и упереться в него можно только внутри плотной сборки, где лишний
## блок починится следующим тиком.
const FIELD_MAX_BODIES := 32

func _blocks_in_field() -> Array:
	var world := get_world_3d()
	if world == null:
		return []
	var sphere := SphereShape3D.new()
	sphere.radius = REGEN_RADIUS
	var q := PhysicsShapeQueryParameters3D.new()
	q.shape = sphere
	q.transform = Transform3D(Basis(), global_position)
	q.collision_mask = 2                      # слой блоков (VehicleBlock.collision_layer = 2)
	q.collide_with_bodies = true
	var out: Array = []
	for hit in world.direct_space_state.intersect_shape(q, FIELD_MAX_BODIES):
		var b = hit.get("collider")
		if b is Node3D and ("current_hp" in b) and ("max_hp" in b):
			out.append(b)
	return out

func _show_field(on: bool) -> void:
	if _field != null and _field.visible != on:
		_field.visible = on

# Плавный переход яркости к цели. Что блок РАБОТАЕТ, и так видно по зелёным цифрам на самих
# чинимых блоках (зелёные цифры) — полю мигать ради этого незачем, оно показывает радиус.
func _fade_field(delta: float, target: float) -> void:
	if _field_mat == null:
		return
	_alpha = move_toward(_alpha, target, delta * (FIELD_ALPHA - FIELD_ALPHA_DEAD) / FIELD_FADE)
	_field_mat.set_shader_parameter("active", _alpha / maxf(FIELD_ALPHA, 0.001))
