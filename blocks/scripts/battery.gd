extends VehicleBlock
# АККУМУЛЯТОР. Заряд хранится ЗДЕСЬ, в самом блоке, а не общим числом у машины.
#
# Раньше энергия была свойством МАШИНЫ: ёмкость считалась как «число аккумуляторов × 100», а
# запас лежал одной переменной. Из этого следовало ровно то, на что жаловались: снял
# аккумулятор — общая ёмкость упала, запас обрезался по ней; поставил обратно — блок приходил
# ПУСТЫМ, потому что возвращалась только ёмкость, а заряд машина уже потеряла. Заряженную
# батарею нельзя было ни перенести на другую машину, ни отложить про запас.
#
# Теперь блок — это ёмкость С СОДЕРЖИМЫМ. Машина складывает и раздаёт по блокам
# (vehicle_body_3d._bat_*), а сколько в каком лежит — знает сам блок, и это едет вместе с ним:
# в руку, на другую машину, в сейв (blocks.charge_map).

## Сколько энергии вмещает ОДИН аккумулятор. Экспортом, а не константой у машины: разные
## аккумуляторы — это разные блоки, и ёмкость обязана быть свойством детали.
## THE ENERGY SCALE IS THE PLAYER'S (a battery 2000, a Falsus panel 80 a second, the Marlit
## accumulator 15000 and its panel 200); every consumer was scaled with it - see SHIELD_COST_X.
@export var capacity: float = 2000.0

## Сколько в нём СЕЙЧАС. Новый блок приходит пустым: заряд — это то, что машина в него
## положила, а не подарок за постановку.
var charge: float = 0.0:
	set(v):
		charge = v
		_show_charge()

## Долить. Возвращает, сколько НЕ влезло, — вызывающий раздаёт остаток дальше.
func charge_add(amount: float) -> float:
	if amount <= 0.0:
		return 0.0
	var room: float = maxf(capacity - charge, 0.0)
	var put: float = minf(amount, room)
	charge += put
	return amount - put

## Забрать. Возвращает, сколько реально удалось взять.
func charge_take(amount: float) -> float:
	var got: float = minf(maxf(amount, 0.0), charge)
	charge -= got
	return got

# ── The gauge on the walls ───────────────────────────────────────────────────────────────────────
# The charge segments (nodes Seg0..N: four rings round the Falsus cell, eight lit gaps on the Marlit
# accumulator; art/emitter_models.py build_battery / build_marlit_battery)
# light by charge / capacity, rounded UP so a battery holding anything shows one; under LOW_FRAC the
# last one blinks. A dark ring is shrunk to SEG_OFF into the cell, not hidden: MachineBatch reads
# `visible` only when it rebuilds, so it copies the parts' transforms instead (`moving_parts`).
const SEG_OFF: float = 0.001
const LOW_FRAC: float = 0.15
const BLINK_MS: int = 400

var _segs: Array[Node3D] = []
var _shown: int = -1
## The Marlit accumulator's cells carry two energy rings (Ring0 low, Ring1 high): the low one lit
## while anything is in it, the high one over RING_HIGH. Dark, a ring shrinks into its groove like
## a segment.
const RING_HIGH: float = 0.5
var _rings: Array[Node3D] = []

func _ready() -> void:
	moving_parts = true
	# As many as the scene has: four rings on the Falsus cell, eight lit gaps on the Marlit
	# accumulator (Seg0 at the bottom).
	var i := 0
	while get_node_or_null("Seg%d" % i) != null:
		_segs.append(get_node("Seg%d" % i) as Node3D)
		i += 1
	for k in 2:
		var r := get_node_or_null("Ring%d" % k) as Node3D
		if r != null:
			_rings.append(r)
	super._ready()
	_show_charge()

# SHOWN WHEN `charge` IS WRITTEN (its setter), not polled: the setter also catches the save and an
# enemy's full start, which write the field straight in. Only a battery blinking its last segment
# ticks a frame - it was every battery in the world, every frame, to find the same picture.
func _process(_delta: float) -> void:
	_show_charge()

func _show_charge() -> void:
	if _segs.is_empty():
		if is_processing():
			set_process(false)            # nothing to show (or not ready yet: _ready asks again)
		return
	var f: float = clampf(charge / capacity, 0.0, 1.0) if capacity > 0.0 else 0.0
	var lit: int = clampi(ceili(f * _segs.size() - 0.001), 0, _segs.size())
	var low: bool = lit == 1 and f < LOW_FRAC
	if low != is_processing():
		set_process(low)
	if low and (Time.get_ticks_msec() / BLINK_MS) % 2 == 1:
		lit = 0
	# the rings have thresholds of their own (anything in it / over half), so they are part of what
	# is compared: behind the segment count alone a first trickle of charge never lit Ring0
	var rings: int = (1 if f > 0.0 else 0) + (2 if f > RING_HIGH else 0)
	var state: int = lit * 4 + rings
	if state == _shown:
		return
	_shown = state
	for i in _segs.size():
		_segs[i].scale = Vector3.ONE if i < lit else Vector3.ONE * SEG_OFF
	for k in _rings.size():
		var on: bool = f > 0.0 if k == 0 else f > RING_HIGH
		_rings[k].scale = Vector3.ONE if on else Vector3.ONE * SEG_OFF
