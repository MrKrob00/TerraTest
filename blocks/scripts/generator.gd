# generator.gd - a factory block: takes fuel off the chain (belt / receiver), burns it for BURN_TIME
# seconds and hands the energy to the machine (ore gives less, an ingot more). Like the whole
# factory it works only while anchored: off the anchor the burn is paused.
extends FactoryBlock

const BURN_TIME := 3.0
## Energy per load, scaled with the panels when the energy scale grew (SOLAR_RATE 6 -> 80, x40/3):
## a burning generator is still worth what it was against a panel, about 2.2 of them on coal.
const ENERGY_COAL := 540.0    # coal is the fuel
## WOOD BURNS, BUT WORSE THAN COAL, AND BY THE SAME HALF AS ITS PRICE. It can go into the furnace
## straight off the road - and then no processor is needed at all; or it can be burnt down into
## twice as much. "Now" against "double" is the whole point of the conversion.
const ENERGY_WOOD := 270.0
const ENERGY_ORE := 330.0
const ENERGY_INGOT := 1070.0

var _burn_left: float = 0.0
var _burn_energy: float = 0.0

# The model says whether it burns (art/emitter_models.py build_generator): fire behind the grate on
# every wall, painted LIT and darkened here when cold, and a turbine
# that spins up with the fire and runs down after it. `Rotor` moves (moving_parts), `Fire` is
# re-coloured per block (unbatched, its own material copy - a shared one would light every
# generator in the world at once).
#
# FUEL GOES IN THROUGH THE TOP, FROM WHICHEVER SIDE IT CAME: one door serves all four sides, where
# side doors would have been four moving parts. It rises from the belt (mid-cell) onto the lid,
# then drops in. The turbine sinks through the lid
# (RETRACT), the fuel settles over the well, shrinks and drops in (`_swallow`), and only THEN the
# fire flares and the burn starts - the turbine comes back up and spins. THE WELL IS PAINTED ON A
# SOLID LID: whatever sinks below it is simply gone into the dark. A real well was tried and showed
# the blades lying in a pit and the fuel on its floor.
const FIRE_COLD := Color(0.20, 0.18, 0.22)
const ROTOR_SPIN := 9.0          # rad/s at full fire
const ROTOR_EASE := 6.0          # rad/s per second: full speed in half a burn (BURN_TIME)
const RETRACT := 0.16            # how far the rotor sinks: its top (0.47) ends under the lid (0.40)
const GATE_TIME := 0.25          # s to sink or rise; the fuel's slide onto the lid takes 0.3
const SETTLE_TIME := 0.15        # s the fuel shrinks to the well's width over the lid
const SINK_TIME := 0.3           # s it drops in
const SINK_Y := 0.25             # where it vanishes, well under the lid
var _rotor: Node3D = null
var _fire: MeshInstance3D = null
var _fire_mat: StandardMaterial3D = null
var _spin: float = 0.0
var _flick: float = 0.0
var _gate: float = 0.0           # 0 rotor up, 1 sunk
var _intake: bool = false        # fuel on its way in: keep the well open

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
	if not on and _spin <= 0.0 and _gate <= 0.0 and not _intake:
		if _fire_mat != null and _fire_mat.albedo_color != FIRE_COLD:
			_fire_mat.albedo_color = FIRE_COLD
		return
	_spin = move_toward(_spin, ROTOR_SPIN if on else 0.0, ROTOR_EASE * delta)
	_gate = move_toward(_gate, 1.0 if _intake else 0.0, delta / GATE_TIME)
	if _rotor != null:
		_rotor.rotate_y(_spin * delta)
		_rotor.position.y = -RETRACT * smoothstep(0.0, 1.0, _gate)
	if _fire_mat != null:
		var target := FIRE_COLD
		if on:
			_flick = move_toward(_flick, randf_range(0.78, 1.0), delta * 4.0)
			target = Color(_flick, _flick, _flick)
		_fire_mat.albedo_color = _fire_mat.albedo_color.lerp(target, clampf(delta * 5.0, 0.0, 1.0))

# A COMPONENT is never taken. It is not fuel: burning a part worth two ingots for one ore's energy
# is not a player's choice but a loss by inattention. The refusal shows: the component stays on
# the belt and rides on.
func try_receive(item: Node3D) -> bool:
	if item != null and "type" in item and int(item.get("type")) == 4:   # 4 = Type.COMPONENT
		return false
	if not super.try_receive(item):
		return false
	_intake = true                        # open the well while the fuel slides onto the lid
	return true

func _on_item_received() -> void:
	if current_item == null:
		return
	# The energy the fuel gives, by resource type.
	_burn_energy = ENERGY_ORE
	if "type" in current_item and current_item.has_method("upgrade"):
		var tname: String = current_item.Type.keys()[current_item.type]
		match tname:
			"COAL":  _burn_energy = ENERGY_COAL
			"WOOD":  _burn_energy = ENERGY_WOOD
			"INGOT": _burn_energy = ENERGY_INGOT
			_:       _burn_energy = ENERGY_ORE
	# The item is a metre-wide bubble; its picture shrinks to the well's width, then drops in.
	var vis := current_item.get_node_or_null("MeshInstance3D") as Node3D
	var tw := create_tween()
	if vis != null:
		tw.tween_property(vis, "scale", Vector3.ONE * 0.5, SETTLE_TIME)
	tw.tween_property(current_item, "position", Vector3(0.0, SINK_Y, 0.0), SINK_TIME) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	if vis != null:
		tw.parallel().tween_property(vis, "scale", Vector3.ONE * 0.15, SINK_TIME)
	tw.finished.connect(_swallow, CONNECT_ONE_SHOT)

func _swallow() -> void:
	_intake = false
	if not is_instance_valid(current_item):
		return
	current_item.visible = false          # in the furnace
	_burn_left = BURN_TIME
	if _fire_mat != null:                 # the flare: straight to full, the flicker takes over
		_fire_mat.albedo_color = Color.WHITE
		_flick = 1.0

func _physics_process(delta: float) -> void:
	if _burn_left <= 0.0 or current_item == null:
		return
	if not _factory_active():
		return                            # off the anchor the burn is paused
	_burn_left -= delta
	if _burn_left > 0.0:
		return
	# Burnt out: energy to the machine, the fuel is gone, the slot is free.
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
