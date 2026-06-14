extends Node3D


func _on_hole_body_entered(body: Node3D) -> void:
	if body.get_parent().name != "objects": return
	G.block_inventory.append(body.block)
	body.queue_free()
	var block_type = G.block_inventory[0]
	var block = G.get_scene(block_type).instantiate()
	block.position = Vector3(5,3,0)
	G.block_inventory.erase(block_type)
	get_node("/root/Main/objects").add_child(block)
