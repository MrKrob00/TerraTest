# seller.gd
extends FactoryBlock

# THE SELLER. The price is not kept here but asked of G.sell_price by the material's KIND
# (kind_key): a local three-row table (ORE/INGOT/COAL) used to make every ingot in the world worth
# the same. With four metals and six components such a table would always lie, so the price lives
# where the recipes do and is computed from them.
#
# THE SALE IS SHOWN, NOT IMPLIED (art/emitter_models.py build_seller): the goods arrive in the mouth
# at belt height, ride up the open lift shaft into the roof (_on_item_received), and at the sale
# are beamed off at the uplink on top - the gold-and-green glitch plays THERE, the ring round the
# mast spins up, and the SCREEN across the front says what went for how much (`Label3D` stands on
# its glass) with the text flashing gold. `Ring` moves (moving_parts).

@export var sell_interval: float = 0.5  # seconds between sales

## The sale's glitch colours: the gold and green of money. Effects are told apart by FORM as well as
## colour - cards say "the item is gone", 0/1 digits say "hp is changing" - and a sale is exactly
## a disappearance, so cards.
const SELL_A := Color(1.0, 0.82, 0.22)
const SELL_B := Color(0.45, 1.0, 0.55)
const SELL_FX_TIME := 0.45
const LIFT_SCALE := 0.5          # the goods shrink to ride inside the shaft's rails
const SHAFT_TOP := 0.92          # where they vanish into the roof (just under SL_TOP)
const RING_SPIN := 14.0          # rad/s right after a sale
const RING_EASE := 7.0           # rad/s per second back down
const TEXT_IDLE := Color(0.45, 1.0, 0.55)   # the screen's terminal green (seller.tscn Label3D)
const TEXT_FADE := 1.6           # per second, back from the gold flash

var timer: Timer
var _ring: Node3D = null
var _text: Label3D = null
var _spin: float = 0.0

func _ready() -> void:
	moving_parts = true
	_ring = get_node_or_null("Ring") as Node3D
	_text = get_node_or_null("Label3D") as Label3D
	if _text != null:
		_text.text = tr("Cash: %s") % G.money
	super._ready()

	timer = Timer.new()
	timer.wait_time = sell_interval
	timer.autostart = false
	timer.one_shot = true
	timer.timeout.connect(_on_timer_timeout)
	add_child(timer)

func _process(delta: float) -> void:
	push_retry_tick(delta)
	if _spin > 0.0:
		_spin = move_toward(_spin, 0.0, RING_EASE * delta)
		if _ring != null:
			_ring.rotate_y(_spin * delta)
	if _text != null and _text.modulate != TEXT_IDLE:
		_text.modulate = _text.modulate.lerp(TEXT_IDLE, clampf(TEXT_FADE * delta, 0.0, 1.0))

## Up the shaft while the sale is timed. The tween carries the PICTURE only: the sale happens on the
## timer whether or not it finished.
func _on_item_received() -> void:
	timer.start()
	if current_item == null:
		return
	var tw := create_tween()
	var vis := current_item.get_node_or_null("MeshInstance3D") as Node3D
	if vis != null:
		tw.tween_property(vis, "scale", Vector3.ONE * LIFT_SCALE, 0.15)
	tw.tween_property(current_item, "position:y", SHAFT_TOP, sell_interval * 0.7) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)

func _on_timer_timeout() -> void:
	if current_item == null:
		return

	var kind: String = current_item.kind_key() if current_item.has_method("kind_key") else ""
	var price: int = G.sell_price(kind)
	# A chunk is a container: G.sell_price prices ONE block inside, only we know how many there are.
	if kind.begins_with("chunk:") and "chunk_count" in current_item:
		price *= maxi(int(current_item.get("chunk_count")), 0)

	if G.has_method("add_money"):
		G.add_money(price)
	# THE CONTRACT IS COUNTED HERE, at the seller: only it knows the material really went for money.
	# Counting by storage would be wrong - ore can be collected and just carried about - while a
	# System order closes on delivery (contracts.gd listens for this event). A chunk is not counted:
	# it holds BLOCKS, and orders are for materials.
	if kind != "" and not kind.begins_with("chunk:"):
		Q.report("sold_" + kind, 1)
	var label: String = G.kind_name(kind)
	if kind.begins_with("chunk:") and "chunk_count" in current_item:
		label += " ×" + str(int(current_item.get("chunk_count")))
	if _text != null:
		_text.text = label + " +" + str(price) + "$\n" + tr("Cash: %s") % G.money
		_text.modulate = SELL_A
	# THE SALE IS GLITCH CARDS AT THE UPLINK, not GPUParticles3D and not at the mouth. The scene
	# used to carry a 512-particle emitter with turbulence and a 34.9 s trail - every sale, twice a
	# second while a line ran - the most expensive trifle in the game on a phone, and a spark cloud
	# from another game. AND NO AWAIT: the sale once waited for the emitter's `finished`, so a broken
	# animation meant an item never removed, a slot never freed and a dead line.
	var up := get_node_or_null("uplink_top") as Node3D
	if up != null:
		current_item.position = up.position
	BlockFX.play(current_item, true, SELL_FX_TIME, SELL_A, SELL_B)
	current_item.visible = false
	_spin = RING_SPIN

	current_item.queue_free()
	current_item = null
	slot_freed.emit()
