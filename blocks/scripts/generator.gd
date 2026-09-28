# generator.gd — фабричный блок: принимает ресурс по цепочке (лента/приёмник), сжигает
# его BURN_TIME секунд и выдаёт энергию в машину (руда меньше, слиток больше).
# Как и вся фабрика — работает только под якорем: горение вне якоря стоит на паузе.
extends FactoryBlock

const BURN_TIME := 3.0
const ENERGY_COAL := 40.0     # уголь — основное топливо
## ДЕРЕВО ГОРИТ, НО ХУЖЕ УГЛЯ, И ЭТО ТА ЖЕ ПОЛОВИНА, ЧТО В ЦЕНЕ. Его можно кинуть в топку
## прямо с дороги — и тогда процессор не нужен вовсе; можно пережечь и получить вдвое больше.
## Выбор между «сейчас» и «вдвое» — это и есть смысл передела.
const ENERGY_WOOD := 20.0
const ENERGY_ORE := 25.0
const ENERGY_INGOT := 80.0

var _burn_left: float = 0.0
var _burn_energy: float = 0.0

# The model says whether it burns (art/emitter_models.py build_generator): fire behind the grate on
# every wall, painted LIT and darkened here when cold, and a turbine in the housing's well that
# spins up with the fire and runs down after it. `Rotor` moves (moving_parts), `Fire` is
# re-coloured per block (unbatched, its own material copy - a shared one would light every
# generator in the world at once).
const FIRE_COLD := Color(0.20, 0.18, 0.22)
const ROTOR_SPIN := 9.0          # rad/s at full fire
const ROTOR_EASE := 6.0          # rad/s per second: full speed in half a burn (BURN_TIME)
var _rotor: Node3D = null
var _fire: MeshInstance3D = null
var _fire_mat: StandardMaterial3D = null
var _spin: float = 0.0
var _flick: float = 0.0

func unbatched() -> Array:
	return [_fire] if _fire != null else []

func _ready() -> void:
	moving_parts = true
	_rotor = get_node_or_null("Rotor") as Node3D
	_fire = get_node_or_null("Fire") as MeshInstance3D
	if _fire != null and _fire.mesh != null:
		var m := _fire.mesh.surface_get_material(0) as StandardMaterial3D
		if m != null:
			_fire_mat = m.duplicate()
			_fire_mat.albedo_color = FIRE_COLD
			_fire.material_override = _fire_mat
	super._ready()

func _burning() -> bool:
	return _burn_left > 0.0 and current_item != null and _factory_active()

func _process(delta: float) -> void:
	push_retry_tick(delta)
	var on := _burning()
	if not on and _spin <= 0.0:
		if _fire_mat != null and _fire_mat.albedo_color != FIRE_COLD:
			_fire_mat.albedo_color = FIRE_COLD
		return
	_spin = move_toward(_spin, ROTOR_SPIN if on else 0.0, ROTOR_EASE * delta)
	if _rotor != null:
		_rotor.rotate_y(_spin * delta)
	if _fire_mat != null:
		var target := FIRE_COLD
		if on:
			_flick = move_toward(_flick, randf_range(0.78, 1.0), delta * 4.0)
			target = Color(_flick, _flick, _flick)
		_fire_mat.albedo_color = _fire_mat.albedo_color.lerp(target, clampf(delta * 5.0, 0.0, 1.0))

# КОМПОНЕНТ в топку не берём вовсе. Он не топливо: сжечь деталь, которая стоит двух слитков,
# ради энергии одной руды — это не выбор игрока, а потеря по невнимательности. Отказ виден:
# компонент остаётся на ленте и едет дальше.
func try_receive(item: Node3D) -> bool:
	if item != null and "type" in item and int(item.get("type")) == 4:   # 4 = Type.COMPONENT
		return false
	return super.try_receive(item)

func _on_item_received() -> void:
	if current_item == null:
		return
	# Сколько энергии даст топливо: по типу ресурса (ORE/INGOT/COAL).
	_burn_energy = ENERGY_ORE
	if "type" in current_item and current_item.has_method("upgrade"):
		var tname: String = current_item.Type.keys()[current_item.type]
		match tname:
			"COAL":  _burn_energy = ENERGY_COAL
			"WOOD":  _burn_energy = ENERGY_WOOD
			"INGOT": _burn_energy = ENERGY_INGOT
			_:       _burn_energy = ENERGY_ORE
	_burn_left = BURN_TIME
	current_item.visible = false          # топливо «в топке»

func _physics_process(delta: float) -> void:
	if _burn_left <= 0.0 or current_item == null:
		return
	if not _factory_active():
		return                            # не на якоре — топка на паузе
	_burn_left -= delta
	if _burn_left > 0.0:
		return
	# Догорело: энергия в машину, топливо испарилось, слот свободен.
	var v := _gen_vehicle_root()
	if v and v.has_method("energy_produce"):
		v.energy_produce(_burn_energy)
	if is_instance_valid(current_item):
		current_item.queue_free()
	current_item = null
	slot_freed.emit()

func _gen_vehicle_root() -> Node:
	var p := get_parent()
	while p != null and not (p is RigidBody3D):
		p = p.get_parent()
	return p
