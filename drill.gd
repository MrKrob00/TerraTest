extends VehicleBlock

@export var drill_damage: int = 20
const DIG_INTERVAL := 0.3   # пауза между ударами, пока зажата атака и бур в контакте
var _dig_cd := 0.0

func _ready() -> void:
	super()                  # VehicleBlock._ready (слои, hp, заморозка)
	$drill.monitoring = true # сенсор бура держим включённым: overlaps готовы к первому же удару

func _physics_process(delta: float) -> void:
	if _dig_cd > 0.0:
		_dig_cd -= delta

func attack() -> void:
	if _dig_cd > 0.0:
		return
	_dig_cd = DIG_INTERVAL
	if not $AnimationPlayer.is_playing():
		$AnimationPlayer.play("drilling")
	_dig()

# Каждый удар бьёт по ВСЕМ рудам, что сейчас перекрывают зону бура. Опрос get_overlapping_bodies()
# (а не сигнал body_entered, который срабатывает лишь при ВХОДЕ тела) добывает и застрявшую вплотную
# руду, оставшуюся в контакте после первого удара.
func _dig() -> void:
	for body in $drill.get_overlapping_bodies():
		if body == self: continue
		if body.get_parent() == get_parent(): continue   # свои блоки не бурим
		if body.has_method("hurt"):
			body.hurt(drill_damage)
