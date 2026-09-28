# THE FIRST MODEL of the repair unit (a hub on the weapons' platform, one ring, a crystal), kept by
# the player's wish as a spare: scene blocks/scenes/regen_v1.tscn. Not used by the game.
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
	_setup_beacon()

# ── THE BEACON ──────────────────────────────────────────────────────────────────
# The model says whether the field works: powered, the RING spins up and the CRYSTAL glows green
# and floats; every repair tick that heals something flashes it; unpowered, the ring runs down and
# the crystal goes dark. `Ring` and `Crystal` move (moving_parts), the crystal is re-coloured and
# so draws itself (unbatched).
const RING_SPIN := 1.8             # rad/s at full power
const RING_SPIN_UP := 1.2          # rad/s² - it winds up and runs down, it does not snap
const CRYSTAL_ON := Color(0.35, 1.0, 0.5)
const CRYSTAL_HEAL := Color(0.85, 1.0, 0.85)
const CRYSTAL_OFF := Color(0.07, 0.16, 0.1)
const BOB := 0.025                 # m the crystal floats while powered
const HEAL_FLASH := 0.3            # s
var _ring: Node3D = null
var _crystal: MeshInstance3D = null
var _crystal_mat: StandardMaterial3D = null
var _crystal_y: float = 0.0
var _crystal_col: Color = CRYSTAL_OFF
var _spin: float = 0.0
var _bob: float = 0.0
var _heal_flash: float = 0.0

func unbatched() -> Array:
	var c := get_node_or_null("Crystal")
	return [c] if c != null else []

func _setup_beacon() -> void:
	moving_parts = true
	_ring = get_node_or_null("Ring") as Node3D
	_crystal = get_node_or_null("Crystal") as MeshInstance3D
	if _crystal != null:
		_crystal_y = _crystal.position.y
		var m: Material = _crystal.material_override
		if m == null and _crystal.mesh != null:
			m = _crystal.mesh.surface_get_material(0)
		if m is StandardMaterial3D:
			_crystal_mat = (m as StandardMaterial3D).duplicate()
			_crystal_mat.albedo_color = _crystal_col
			_crystal.material_override = _crystal_mat

func _animate_beacon(delta: float, on: bool) -> void:
	if _ring == null:
		return
	_spin = move_toward(_spin, RING_SPIN if on else 0.0, delta * RING_SPIN_UP)
	if _spin > 0.001:
		_ring.rotate_y(_spin * delta)
	_heal_flash = maxf(_heal_flash - delta / HEAL_FLASH, 0.0)
	if _crystal == null:
		return
	_bob = move_toward(_bob, 1.0 if on else 0.0, delta * 1.5)
	var t: float = Time.get_ticks_msec() / 1000.0
	_crystal.position.y = _crystal_y + BOB * _bob * sin(t * 2.2)
	if _bob > 0.001:
		_crystal.rotate_y(delta * 0.9 * _bob)
	if _crystal_mat != null:
		var target: Color = CRYSTAL_ON if on else CRYSTAL_OFF
		target = target.lerp(CRYSTAL_HEAL, _heal_flash)
		_crystal_col = _crystal_col.lerp(target, clampf(delta * 8.0, 0.0, 1.0))
		if not _crystal_mat.albedo_color.is_equal_approx(_crystal_col):
			_crystal_mat.albedo_color = _crystal_col

# ── Поле ремонта ─────────────────────────────────────────────────────────────
# Видимая сфера радиусом ровно REGEN_RADIUS, как купол у щита. Без неё радиус был
# невидимой цифрой в коде: игрок не мог знать, дотягивается блок до пробитого борта или
# нет, и ставил реген наугад. Сфера отвечает на это одним взглядом.
#
# Отличие от щита принципиальное: у того купол — ФИЗИЧЕСКОЕ тело, он ловит снаряды и лежит
# на слое блоков. Здесь это чистая графика, без коллизии вовсе: реген ничего не
# перехватывает, он только чинит, и тело ему не нужно.
## Сколько цифр в облаке. По набору читается РАДИУС поля, а тридцатью точками сфера всё ещё
## очерчивалась пунктиром — девяносто дают сплошной силуэт. Дороже это не стало: MultiMesh рисует
## всё облако одним вызовом, и цена в нём — пиксели, а не число инстансов.
const FIELD_DIGITS := 90
## Размер карточки. Снова половина прежнего, и это важно именно вместе с утроением числа: втрое
## больше цифр при вчетверо меньшей площади каждой — 90 × 0.2² против 30 × 0.4², то есть краски в
## кадре даже МЕНЬШЕ (3.6 против 4.8), и сквозь облако по-прежнему видно чинимый борт.
const DIGIT_SIZE := 0.2

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
	_animate_beacon(delta, _work(delta))

## The field's tick; true while it is powered and mounted.
func _work(delta: float) -> bool:
	if freeze == false:
		_show_field(false)
		return false                         # валяется в мире — не работает
	var blocks_node := get_parent()
	if blocks_node == null or blocks_node.name != "blocks":
		_show_field(false)
		return false
	var vehicle := blocks_node.get_parent()
	if vehicle == null or not vehicle.has_method("energy_consume"):
		_show_field(false)
		return false
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
		return false
	_fade_field(delta, FIELD_ALPHA)
	_timer -= delta
	if _timer > 0.0:
		return true
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
		BlockFX.repair_stream(self, b, REGEN_RADIUS)
		_heal_flash = 1.0
	return true

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
