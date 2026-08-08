# seller.gd
extends FactoryBlock

@export var sell_interval: float = 0.5  # секунд между продажами

# Цены за каждый тип ресурса
@export var prices: Dictionary = {
	"ORE": 10,
	"INGOT": 50,
	"COAL": 8,
}

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

	# Получаем цену
	var item_type: Variant = current_item.get("type")
	var type_name: String = ""
	if item_type != null:
		type_name = current_item.Type.keys()[item_type]  # 0 → "ORE"
	else:
		type_name = "ORE"
	var price: Variant = prices.get(type_name, 0)

	# Добавляем деньги (G — глобальный синглтон)
	if G.has_method("add_money"):
		G.add_money(price)
	$Label3D.text = str(type_name)+" +"+str(price)+"$\n"+"Cash: %s" % G.money
	$GPUParticles3D.emitting = true
	await $GPUParticles3D.finished
	current_item.visible=false

	# Удаляем ресурс из мира
	current_item.queue_free()
	current_item = null 
	slot_freed.emit()
