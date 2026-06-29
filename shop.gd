extends Node3D

var inventory1:Array = []
var inventory2:Array = []
var inventory3:Array = []


func _on_taker_resource(resource: RigidBody3D) -> void:
	if !inventory1.has(resource): inventory1.append(resource)
	if $blocks/taker/Sell.is_stopped(): $blocks/taker/Sell.start()

func _on_taker_2_resource(resource: RigidBody3D) -> void:
	if !inventory2.has(resource): inventory2.append(resource)
	if $blocks/taker2/Sell.is_stopped(): $blocks/taker2/Sell.start()

func _on_taker_3_resource(resource: RigidBody3D) -> void:
	if !inventory3.has(resource): inventory3.append(resource)
	if $blocks/taker3/Sell.is_stopped(): $blocks/taker3/Sell.start()

func _on_sell_timeout() -> void:
	inventory1[0].queue_free()
	inventory1.erase(inventory1[0])
	G.add_money(5)
	if inventory1.size()>0:
		$blocks/taker/Sell.start()
		update_position()

func _unhandled_input(event: InputEvent) -> void:
	print(get_global_mouse_position())

func _on_sell_2_timeout() -> void:
	inventory2[0].queue_free()
	inventory2.erase(inventory2[0])
	G.add_money(5)
	if inventory2.size()>0:
		$blocks/taker2/Sell.start()
		update_position()

func _on_sell_3_timeout() -> void:
	inventory3[0].queue_free()
	inventory3.erase(inventory3[0])
	G.add_money(5)
	if inventory3.size()>0:
		$blocks/taker3/Sell.start()
		update_position()

func update_position():
	for i in inventory1:
		i.position = Vector3(0,inventory1.find(i)+1,0)
	for i in inventory2:
		i.position = Vector3(0,inventory2.find(i)+1,0)
	for i in inventory3:
		i.position = Vector3(0,inventory3.find(i)+1,0)
