extends Node3D
# Приёмник мирового магазина. Всё, что падает в дыру:
#   • РЕСУРС (руда/слиток) → продаётся за деньги (цены как у блока-продавца);
#   • свободный БЛОК (лежит в мире под "objects") → в инвентарь игрока (G.block_inventory).
# Покупка блоков — только в UI гаража; у мирового магазина своего меню нет.

func _on_hole_body_entered(body: Node3D) -> void:
	# Ресурс: у него есть type + upgrade() (см. resource.gd). У машин/блоков upgrade нет.
	if "type" in body and body.has_method("upgrade"):
		# Цена — та же, что у блока-продавца (G.sell_price по виду материала). Своя табличка
		# на три строки жила здесь, пока слиток был один; с четырьмя металлами и шестью
		# компонентами она врала бы всегда, а разъехавшиеся цены игрок читает как баг.
		var kind: String = body.kind_key() if body.has_method("kind_key") else ""
		var price: int = G.sell_price(kind)
		if kind.begins_with("chunk:") and "chunk_count" in body:
			price *= maxi(int(body.get("chunk_count")), 0)
		G.add_money(price)
		body.queue_free()
		return
	# Свободный блок из мира → в инвентарь (виден в гараже).
	if body.get_parent() != null and body.get_parent().name == "objects" and "block" in body:
		G.block_inventory.append(body.block)
		G.mark_progress_dirty()
		body.queue_free()
