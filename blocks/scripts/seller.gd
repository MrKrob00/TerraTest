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
# mast spins up, and the money rises over it as a "+N$" (sale_popup.gd; the screen across the front
# that said it in text is gone, the player's call). `Ring` moves (moving_parts).

@export var sell_interval: float = 0.5  # seconds between sales

## The sale's glitch colours: the gold and green of money. Effects are told apart by FORM as well as
## colour - cards say "the item is gone", 0/1 digits say "hp is changing" - and a sale is exactly
## a disappearance, so cards.
const SELL_A := Color(1.0, 0.82, 0.22)
const SELL_B := Color(0.45, 1.0, 0.55)
const SELL_FX_TIME := 0.45
## The goods shrink to ride inside the shaft's rails: 0.8 of the model's own size, and a loose item is
## drawn at ITEM_SIZE.
const LIFT_SCALE := 0.8 / preload("res://resource.gd").ITEM_SIZE
const SHAFT_TOP := 0.92          # where they vanish into the roof (just under SL_TOP)
## The ring's turn is the clip "spin" on the scene's `Anim` player, keyed at RING_SPIN; a sale runs
## it at full pace and it eases out at RING_EASE.
const RING_SPIN := 14.0          # rad/s right after a sale
const RING_EASE := 7.0           # rad/s per second back down
const SALE_POPUP := preload("res://sale_popup.gd")
const POPUP_Y := 1.9             # over the uplink's tip

var timer: Timer
var _anim: AnimationPlayer = null
var _popup = null                # the last "+N$" (sale_popup.gd), merged into while young
var _spin: float = 0.0

func _ready() -> void:
	moving_parts = true
	if _ours():
		add_to_group("sellers")    # the quest compass leads a "sell" quest to the nearest one (ours)
	_anim = get_node_or_null("Anim") as AnimationPlayer
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
		drive_clip(_anim, &"spin", _spin / RING_SPIN)

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

	# AN ENEMY'S SELLER PAYS NOBODY: an enemy factory runs its line for show and for itself, and the
	# player's money and sale counts come only from a seller on the player's own side.
	if not _ours():
		price = 0
		kind = ""
	if price > 0 and G.has_method("add_money"):
		G.add_money(price)
	# THE CONTRACT IS COUNTED HERE, at the seller: only it knows the material really went for money.
	# Counting by storage would be wrong - ore can be collected and just carried about - while a
	# System order closes on delivery (contracts.gd listens for this event). A chunk is not counted:
	# it holds BLOCKS, and orders are for materials.
	if kind != "" and not kind.begins_with("chunk:"):
		Q.report("sold_" + kind, 1)
	if _ours():
		Q.report("item_sold", 1)                   # Marlit's market count: anything sold
	if price > 0:
		Sfx.at("sale", global_position)
		if is_instance_valid(_popup) and _popup.can_merge():
			_popup.add(price)
		else:
			var at: Vector3 = global_transform * Vector3(0.0, POPUP_Y, 0.0)
			_popup = SALE_POPUP.spawn(self, at, price)
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

## On the player's side: the machine this seller stands on is faction 0 (or has no faction - a
## loose seller in the world is no one's and sells for the player as before).
func _ours() -> bool:
	var p: Node = get_parent()
	var v: Node = p.get_parent() if p != null else null
	return v == null or v.get("faction") == null or int(v.get("faction")) == 0
