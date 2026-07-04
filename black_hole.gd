extends Node3D
# Приёмник мирового магазина. Всё, что падает в дыру:
#   • РЕСУРС (руда/слиток) → продаётся за деньги (цены как у блока-продавца);
#   • свободный БЛОК (лежит в мире под "objects") → в инвентарь игрока (G.block_inventory).
# Покупка блоков — только в UI гаража; у мирового магазина своего меню нет.

const RESOURCE_PRICES := {"ORE": 10, "INGOT": 50}

func _on_hole_body_entered(body: Node3D) -> void:
	# Ресурс: у него есть type + upgrade() (см. resource.gd). У машин/блоков upgrade нет.
	if "type" in body and body.has_method("upgrade"):
		var type_name: String = body.Type.keys()[body.type]
		G.add_money(RESOURCE_PRICES.get(type_name, 5))
		body.queue_free()
		return
	# Свободный блок из мира → в инвентарь (виден в гараже).
	if body.get_parent() != null and body.get_parent().name == "objects" and "block" in body:
		G.block_inventory.append(body.block)
		body.queue_free()
