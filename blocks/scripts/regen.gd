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
const REGEN_HP := 5            # HP за тик на один блок
const REGEN_COST := 2.0        # энергии за один подлеченный блок
const REGEN_INTERVAL := 1.0    # с между тиками

## Прозрачность поля: обычная и «энергии нет». Разница небольшая намеренно — поле показывает
## РАДИУС, это его работа, а моргать ради привлечения внимания оно не должно.
const FIELD_ALPHA := 0.09
const FIELD_ALPHA_DEAD := 0.03
## За сколько секунд поле переходит между этими двумя состояниями.
const FIELD_FADE := 0.4

var _timer: float = 0.0
var _field: MeshInstance3D = null
var _field_mat: StandardMaterial3D = null
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
func _build_field() -> void:
	_field = MeshInstance3D.new()
	var m := SphereMesh.new()
	m.radius = REGEN_RADIUS
	m.height = REGEN_RADIUS * 2.0
	m.radial_segments = 16
	m.rings = 8
	_field_mat = StandardMaterial3D.new()
	_field_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_field_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_field_mat.albedo_color = Color(0.25, 1.0, 0.45, FIELD_ALPHA_DEAD)   # зелёный как у BlockFX.heal
	# Рисуем ИЗНАНКУ сферы: снаружи она почти прозрачна, а изнутри не закрывает игроку обзор
	# и не отсекает камеру, когда та въезжает внутрь поля.
	_field_mat.cull_mode = BaseMaterial3D.CULL_FRONT
	m.material = _field_mat
	_field.mesh = m
	_field.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
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
		BlockFX.heal(b)                       # зелёная «матрица»: видно, ЧТО именно чинится
		if b.has_method("_refresh_hp_fx"):
			b._refresh_hp_fx()               # подлечили → цифр меньше (или блок снова чистый)

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
# чинимых блоках (BlockFX.heal) — полю мигать ради этого незачем, оно показывает радиус.
func _fade_field(delta: float, target: float) -> void:
	if _field_mat == null:
		return
	_alpha = move_toward(_alpha, target, delta * (FIELD_ALPHA - FIELD_ALPHA_DEAD) / FIELD_FADE)
	_field_mat.albedo_color.a = _alpha
