# seller.gd
extends FactoryBlock

# ПРОДАВЕЦ. Цена берётся не отсюда, а из G.sell_price по ВИДУ материала (kind_key): раньше
# здесь лежала своя табличка на три строки — ORE/INGOT/COAL, — и все слитки мира стоили
# одинаково. С четырьмя металлами и шестью компонентами такая табличка врала бы всегда,
# поэтому цена живёт там же, где рецепты, и считается от них.

@export var sell_interval: float = 0.5  # секунд между продажами

## Краски глитча продажи: золото и зелень денег. Отличать эффекты обязан не только цвет,
## но и ФОРМА — карточки говорят «предмет исчез», цифры 0/1 говорят «хп меняется», — и
## продажа это именно исчезновение, поэтому карточки.
const SELL_A := Color(1.0, 0.82, 0.22)
const SELL_B := Color(0.45, 1.0, 0.55)
const SELL_FX_TIME := 0.45

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
	# КОНТРАКТ СЧИТАЕТСЯ ЗДЕСЬ, у продавца: только он знает, что материал действительно ушёл
	# за деньги. Считать «по складу» было бы неверно — руду можно набрать и просто возить с
	# собой, а заказ Системы закрывается поставкой (contracts.gd слушает это событие).
	# Чанк не считаем: в нём лежат БЛОКИ, а заказывают материалы.
	if kind != "" and not kind.begins_with("chunk:"):
		Q.report("sold_" + kind, 1)
	var label: String = G.kind_name(kind)
	if kind.begins_with("chunk:") and "chunk_count" in current_item:
		label += " ×" + str(int(current_item.get("chunk_count")))
	$Label3D.text = label + " +" + str(price) + "$\n" + "Cash: %s" % G.money
	# ПРОДАЖА — ЭТО ГЛИТЧ-КАРТОЧКИ, а не GPUParticles3D. В сцене висел эмиттер на 512 частиц
	# с турбулентностью и трейлом на 34.9 секунды — и всё это на КАЖДУЮ продажу, то есть
	# раз в полсекунды, пока идёт линия. На мобильном GPU это была самая дорогая мелочь в
	# игре, а выглядела она облачком искр из другой игры: у нас появление и распад предмета
	# говорят карточками. Золото с зеленью — та же матрица, только про деньги.
	#
	# И БЕЗ AWAIT. Раньше ждали сигнала finished у эмиттера, то есть логика продажи висела
	# на анимации: сбилась она — предмет не удалён, ячейка не освобождена, линия встала.
	# Ровно та беда, из-за которой переписывали процессор.
	BlockFX.play(current_item, true, SELL_FX_TIME, SELL_A, SELL_B)
	current_item.visible = false

	# Удаляем ресурс из мира
	current_item.queue_free()
	current_item = null
	slot_freed.emit()
