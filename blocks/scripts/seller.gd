# seller.gd
extends FactoryBlock

# ПРОДАВЕЦ. Цена берётся не отсюда, а из G.sell_price по ВИДУ материала (kind_key): раньше
# здесь лежала своя табличка на три строки — ORE/INGOT/COAL, — и все слитки мира стоили
# одинаково. С четырьмя металлами и шестью компонентами такая табличка врала бы всегда,
# поэтому цена живёт там же, где рецепты, и считается от них.

@export var sell_interval: float = 0.5  # секунд между продажами

var timer: Timer

func _ready() -> void:
	super._ready()

	timer = Timer.new()
	timer.wait_time = sell_interval
	timer.autostart = false
	timer.one_shot = true
	timer.timeout.connect(_on_timer_timeout)
	add_child(timer)

func _on_item_received() -> void:
	timer.start()

func _on_timer_timeout() -> void:
	if current_item == null:
		return

	var kind: String = current_item.kind_key() if current_item.has_method("kind_key") else ""
	var price: int = G.sell_price(kind)
	# Чанк — контейнер: G.sell_price оценивает ОДИН блок внутри, сколько их там, знаем только мы.
	if kind.begins_with("chunk:") and "chunk_count" in current_item:
		price *= maxi(int(current_item.get("chunk_count")), 0)

	if G.has_method("add_money"):
		G.add_money(price)
	var label: String = G.kind_name(kind)
	if kind.begins_with("chunk:") and "chunk_count" in current_item:
		label += " ×" + str(int(current_item.get("chunk_count")))
	$Label3D.text = label + " +" + str(price) + "$\n" + "Cash: %s" % G.money
	$GPUParticles3D.emitting = true
	await $GPUParticles3D.finished
	current_item.visible = false

	# Удаляем ресурс из мира
	current_item.queue_free()
	current_item = null
	slot_freed.emit()
