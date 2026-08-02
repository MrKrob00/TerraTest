extends VehicleBlock

@export var drill_damage: int = 20
const DIG_INTERVAL := 0.3   # пауза между ударами, пока зажата атака и бур в контакте
var _dig_cd := 0.0

func _ready() -> void:
	super()                  # VehicleBlock._ready (слои, hp, заморозка)
	$drill.monitoring = true # сенсор бура держим включённым: overlaps готовы к первому же удару

# Кулдаун тикает на ФИЗ-ТИКЕ, потому что и тратится он оттуда же: attack() зовётся из
# _physics_process машины (зажатая Атака) и из ИИ-таймера. Раньше он убывал на кадре отрисовки —
# счёт шёл по реальному времени и в целом совпадал, но темп бурения зависел от FPS.
func _physics_process(delta: float) -> void:
	if _dig_cd > 0.0:
		_dig_cd -= delta

# Зовётся КАЖДЫЙ физ-кадр, пока зажата Атака (см. vehicle_body_3d._on_attack_timeout), и раз в
# ~0.3с у ИИ. Раньше attack() ждал конца анимации через `await animation_finished` и дёргал
# monitoring вкл/выкл. При вызове каждый кадр это давало гонку корутин: monitoring мог погаснуть
# ПЕРЕД _dig, и после первого удара бур замолкал (добывал «только один раз в начале»). Теперь
# удар идёт по таймеру-кулдауну, сенсор всегда включён, а анимация — лишь визуал (без await).
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
