extends Node3D


func _on_hole_body_entered(body: Node3D) -> void:
	if body.get_parent().name != "objects": return
	# Засосали блок → кладём в инвентарь (виден в tech_ui) и убираем из мира.
	# Раньше тут же доставали блок обратно в мир, поэтому в инвентаре ничего не оставалось.
	G.block_inventory.append(body.block)
	body.queue_free()
