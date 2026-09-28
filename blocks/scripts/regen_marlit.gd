# THE GYRO REPAIR UNIT, kept for the second faction (Marlit) to be reworked into its own style;
# the game's repair unit is regen.gd / regen.tscn. Not used by the game yet.
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

# ── THE GYRO ───────────────────────────────────────────────────────────────────
# The model says whether the field works (art/emitter_models.py build_regen2): four rings round the
# crystal, seen from the front as "-", "|", "/" and "\", held on round bearings at the six faces.
# OFF: the rings stand, their energy strips are dark, and the crystal lies grey at the bottom, on the
# rings. POWER-UP: the rings wind up, each turning about its OWN axis (the normal of its plane, so it
# slides through its bearings), at its own rate and alternating in direction; the strips and the
# crystal turn green, and the crystal rises to the centre and stands up. WORKING: the rings turn and
# the crystal floats and turns slowly; every repair tick that heals something flashes it. Rings and
# crystal move (moving_parts); the crystal and the strips are re-coloured, so they draw themselves
# (unbatched) on one per-block material.
const RING_ANGLES := [0.0, 90.0, 45.0, 135.0]     # each ring's plane, turned about Z (build_regen2)
const RING_RATES := [1.0, -1.35, 0.8, -1.15]       # x RING_SPIN, rad/s: their own pace, alternating
const RING_SPIN := 1.6
const POWER_UP := 1.2              # s from off to working (and back)
const CRYSTAL_ON := Color(0.35, 1.0, 0.5)
const CRYSTAL_HEAL := Color(0.85, 1.0, 0.85)
const CRYSTAL_OFF := Color(0.26, 0.27, 0.3)
const STRIP_OFF := Color(0.1, 0.13, 0.11)
## Where the crystal lies off: on its side, down on the bottom bearing and the rings.
const REST_POS := Vector3(0.0, -0.19, 0.0)
const BOB := 0.02                  # m the crystal floats while working
const HEAL_FLASH := 0.3            # s
var _rings: Array[Node3D] = []
var _crystal: MeshInstance3D = null
var _glow_mat: StandardMaterial3D = null
var _power: float = 0.0            # 0 off .. 1 working, eased
var _crystal_turn: float = 0.0
var _heal_flash: float = 0.0

func unbatched() -> Array:
	var out: Array = []
	var c := get_node_or_null("Crystal")
	if c != null:
		out.append(c)
	for i in 4:
		var g := get_node_or_null("Ring%d/Glow" % i)
		if g != null:
			out.append(g)
	return out

func _setup_beacon() -> void:
	moving_parts = true
	for i in 4:
		var r := get_node_or_null("Ring%d" % i) as Node3D
		if r != null:
			_rings.append(r)
	_crystal = get_node_or_null("Crystal") as MeshInstance3D
	# One material for the crystal and the four strips, duplicated per block: a shared one would
	# light every repair unit in the world at once.
	var m: Material = _crystal.material_override if _crystal != null else null
	if m is StandardMaterial3D:
		_glow_mat = (m as StandardMaterial3D).duplicate()
		_glow_mat.albedo_color = CRYSTAL_OFF
		_crystal.material_override = _glow_mat
	# The strips take their own copy: they go dark to a different colour than the crystal's grey.
	var strip_mat: StandardMaterial3D = null
	if _glow_mat != null:
		strip_mat = _glow_mat.duplicate()
		strip_mat.albedo_color = STRIP_OFF
		_strip_mat = strip_mat
	for r in _rings:
		var g := r.get_node_or_null("Glow") as MeshInstance3D
		if g != null and strip_mat != null:
			g.material_override = strip_mat
	_pose_crystal(0.0)

var _strip_mat: StandardMaterial3D = null

func _animate_beacon(delta: float, on: bool) -> void:
	_power = move_toward(_power, 1.0 if on else 0.0, delta / POWER_UP)
	var p: float = _power * _power * (3.0 - 2.0 * _power)        # smoothstep: eases in and out
	for i in _rings.size():
		var w: float = RING_SPIN * float(RING_RATES[i]) * p
		if absf(w) > 0.0005:
			var a: float = deg_to_rad(float(RING_ANGLES[i]))
			_rings[i].rotate(Vector3(-sin(a), cos(a), 0.0), w * delta)
	_heal_flash = maxf(_heal_flash - delta / HEAL_FLASH, 0.0)
	_crystal_turn += delta * 0.9 * p
	_pose_crystal(p)
	if _glow_mat != null:
		var c: Color = CRYSTAL_OFF.lerp(CRYSTAL_ON, p).lerp(CRYSTAL_HEAL, _heal_flash)
		if not _glow_mat.albedo_color.is_equal_approx(c):
			_glow_mat.albedo_color = c
	if _strip_mat != null:
		var sc: Color = STRIP_OFF.lerp(CRYSTAL_ON, p)
		if not _strip_mat.albedo_color.is_equal_approx(sc):
			_strip_mat.albedo_color = sc

## The crystal at power p: lying on the bottom at 0, standing in the centre at 1, lifted along the way.
func _pose_crystal(p: float) -> void:
	if _crystal == null:
		return
	var t: float = Time.get_ticks_msec() / 1000.0
	var pos: Vector3 = REST_POS.lerp(Vector3.ZERO, p)
	pos.y += BOB * p * sin(t * 2.2)
	var lying := Basis(Vector3.RIGHT, PI * 0.5)
	var standing := Basis(Vector3.UP, _crystal_turn)
	_crystal.transform = Transform3D(lying.slerp(standing, p), pos)

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
