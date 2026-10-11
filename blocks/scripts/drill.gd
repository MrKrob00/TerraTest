extends VehicleBlock

@export var drill_damage: int = 103
const DIG_INTERVAL := 0.3   # пауза между ударами, пока зажата атака и бур в контакте
var _dig_cd := 0.0

# ── THE SPINNING BIT ─────────────────────────────────────────────────────────
# The bit is its own node in both models (Drill_rotor_big, Drill_rotor_small in Assets.glb),
# and its turn is the clip "drilling" on the scene's AnimationPlayer (art/block_anims.gd): 2.5 turns
# a second about the block's FRONT taken in the bit's own axes - the two meshes point differently,
# the big bit along its Y and the small one along -X, so the axis is read off the scene when the clip
# is made, never typed. That player used to hold an EMPTY "drilling" - a length and no track - which
# attack() faithfully played, so the call was there and the motion never was.
## How long the bit turns AFTER the last blow: a little over DIG_INTERVAL, so it turns without a break
## while the attack is held.
const SPIN_COAST := 0.45
var _anim: AnimationPlayer = null
var _spin_t := 0.0

func _ready() -> void:
	super()                  # VehicleBlock._ready (слои, hp, заморозка)
	moving_parts = true      # the rotor spins (MachineBatch)
	$drill.monitoring = true # сенсор бура держим включённым: overlaps готовы к первому же удару
	_anim = get_node_or_null("AnimationPlayer") as AnimationPlayer

func _physics_process(delta: float) -> void:
	if _dig_cd > 0.0:
		_dig_cd -= delta
	if _spin_t > 0.0:
		_spin_t -= delta
		drive_clip(_anim, &"drilling", 1.0 if _spin_t > 0.0 else 0.0)

func attack() -> void:
	_spin_t = SPIN_COAST     # ДО проверки паузы: коронка крутится всё время, пока держат атаку,
	if _dig_cd > 0.0:        # а удары идут своим темпом (DIG_INTERVAL)
		return
	_dig_cd = DIG_INTERVAL
	_dig()

# Каждый удар бьёт по ВСЕМ рудам, что сейчас перекрывают зону бура. Опрос get_overlapping_bodies()
# (а не сигнал body_entered, который срабатывает лишь при ВХОДЕ тела) добывает и застрявшую вплотную
# руду, оставшуюся в контакте после первого удара.
func _dig() -> void:
	for body in $drill.get_overlapping_bodies():
		if body == self: continue
		if body.get_parent() == get_parent(): continue   # свои блоки не бурим
		# Купол своего щита бур тоже не грызёт: он лежит на слое блоков, а родитель у него —
		# сам блок щита, а не blocks, поэтому проверка выше его не ловила.
		# _root_body(), а не _vehicle_root(): второй живёт в WeaponBlock и в shield, а бур —
		# обычный VehicleBlock, и вызова с чужим именем хватило бы, чтобы скрипт не загрузился.
		if G.is_friendly_dome(body, _root_body()): continue
		# Купол берёт энергией, и резка ему почти не страшна: в оригинале щит и пилы друг друга
		# не видят вовсе, у нас бур купол всё же ковыряет — просто вчетверо дороже по времени.
		# Иначе сборка с одним буром осталась бы вообще без ответа на щит.
		if body.has_method("struck"):
			body.hurt(drill_damage, WeaponBlock.SHIELD_MULT_CONTACT)
			# Место удара отмечаем как от пули: бур стоит вплотную, своё положение и есть контакт.
			body.struck(global_position)
		elif body is VehicleBlock:
			body.hurt(drill_damage, VehicleBlock.Dmg.CUTTING)
		elif body.has_method("hurt"):
			body.hurt(drill_damage)            # a vein
