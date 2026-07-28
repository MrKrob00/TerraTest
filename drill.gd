extends VehicleBlock

@export var drill_damage: int = 20

func attack():
	if $AnimationPlayer.is_playing(): return
	$drill.monitoring = true                 # сенсор активен только на время бурения
	$AnimationPlayer.play("drilling")
	await $AnimationPlayer.animation_finished
	_dig()                                    # бьём по тому, что СЕЙЧАС в контакте
	$drill.monitoring = false

# Каждый удар наносит урон ВСЕМ рудам, что сейчас перекрывают зону бура.
# Раньше урон шёл от сигнала body_entered — а он срабатывает лишь в момент ВХОДА тела в зону.
# Руда, оставшаяся в контакте после первого удара, повторно «не входит», поэтому со второй
# атаки не добывалась. Опрос get_overlapping_bodies() снимает зависимость от событий входа.
func _dig() -> void:
	for body in $drill.get_overlapping_bodies():
		if body == self: continue
		if body.get_parent() == get_parent(): continue   # свои блоки не бурим
		if body.has_method("hurt"):
			body.hurt(drill_damage)
