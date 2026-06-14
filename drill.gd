extends VehicleBlock

@export var drill_damage: int = 20

func attack():
	if $AnimationPlayer.is_playing(): return
	$drill.monitoring = true
	$AnimationPlayer.play("drilling")
	await $AnimationPlayer.animation_finished
	$drill.monitoring = false



func _on_drill_body_entered(body: Node3D) -> void:
	# Игнорируем себя и все блоки своей машины
	if body == self: return
	if body.get_parent() == get_parent(): return
	if body.has_method("hurt"):
		body.hurt(drill_damage)
