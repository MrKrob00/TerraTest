# regen.gd — блок регенерации: раз в интервал чинит повреждённые блоки СВОЕЙ машины
# в радиусе, тратя энергию машины (vehicle.energy_consume). Нет энергии — не чинит.
extends VehicleBlock

const REGEN_RADIUS := 4.6      # м: как далеко достаёт
const REGEN_HP := 5            # HP за тик на один блок
const REGEN_COST := 2.0        # энергии за один подлеченный блок
const REGEN_INTERVAL := 1.0    # с между тиками

var _timer: float = 0.0
var _field: MeshInstance3D = null
var _field_mat: StandardMaterial3D = null
var _pulse: float = 0.0        # > 0 — только что чинили, поле ярче

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
	_field_mat.albedo_color = Color(0.25, 1.0, 0.45, 0.07)   # тот же зелёный, что у BlockFX.heal
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
	# Поле видно, только пока машине есть чем чинить: погасшая сфера — честный ответ на
	# вопрос «почему не лечит», а не молчание.
	var powered: bool = vehicle.has_method("energy_available") and vehicle.energy_available() > 0.0
	_show_field(powered)
	_fade_pulse(delta)
	_timer -= delta
	if _timer > 0.0:
		return
	_timer = REGEN_INTERVAL
	for b in blocks_node.get_children():
		# СЕБЯ ТОЖЕ ЧИНИМ. Раньше блок себя пропускал, и пробитый реген оставался пробитым:
		# чинил всё вокруг, кроме единственного блока, от которого зависит вся починка.
		if not ("current_hp" in b) or not (b is Node3D):
			continue
		if b.current_hp >= b.max_hp:
			continue
		if global_position.distance_squared_to((b as Node3D).global_position) > REGEN_RADIUS * REGEN_RADIUS:
			continue
		# Платим за каждый блок отдельно: не хватило на этого — дальше смысла нет.
		if vehicle.energy_consume(REGEN_COST) < REGEN_COST:
			break
		b.current_hp = mini(b.current_hp + REGEN_HP, b.max_hp)
		BlockFX.heal(b as Node3D)             # зелёная «матрица»: видно, ЧТО именно чинится
		if b.has_method("_refresh_hp_fx"):
			b._refresh_hp_fx()               # подлечили → цифр меньше (или блок снова чистый)
		_pulse = 1.0                          # что-то починили — поле вспыхивает

func _show_field(on: bool) -> void:
	if _field != null and _field.visible != on:
		_field.visible = on

# Вспышка поля в момент ремонта — по ней видно, что блок РАБОТАЕТ, а не просто нарисован.
func _fade_pulse(delta: float) -> void:
	if _field_mat == null:
		return
	if _pulse > 0.0:
		_pulse = maxf(_pulse - delta / 0.6, 0.0)
	_field_mat.albedo_color.a = 0.07 + 0.13 * _pulse
