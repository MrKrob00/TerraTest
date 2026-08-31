extends VehicleBlock

@export var drill_damage: int = 20
const DIG_INTERVAL := 0.3   # пауза между ударами, пока зажата атака и бур в контакте
var _dig_cd := 0.0

# ── КРУТЯЩАЯСЯ ЧАСТЬ ─────────────────────────────────────────────────────────
# В обеих моделях коронка вынесена ОТДЕЛЬНЫМ УЗЛОМ (в Assets.glb это Drill_rotor_*, у малого
# бура — drillsharp), то есть крутить её можно, ничего не переделывая. До сих пор бур не
# двигался вовсе: в сцене лежит AnimationPlayer с анимацией "drilling", в которой НЕТ НИ ОДНОГО
# ТРЕКА (только length), а attack() её исправно проигрывал — то есть вызов был, а движения не
# было никогда. Пустую анимацию не чиним: непрерывное вращение это одна строка кода, а
# анимация под него — файл, который надо держать в согласии с моделью.
#
# ОСЬ НЕ ЗАШИТА, А СЧИТАЕТСЯ: у большого бура коронка смотрит своей локальной осью Y, у малого —
# минус X, потому что меши в моделях повёрнуты по-разному. Вместо двух чисел в коде спрашиваем
# у сцены: берём ПЕРЁД БЛОКА (−Z, рабочая сторона у всех буров) и переводим его в локальные оси
# самой коронки. Художник повернёт меш иначе — код это переживёт.
const SPIN_NAMES := ["Drill_rotor_small", "Drill_rotor_big", "drillsharp"]
const SPIN_SPEED := TAU * 2.5      # оборотов в секунду
## Сколько коронка крутится ПОСЛЕ последнего удара. Чуть больше паузы между ударами
## (DIG_INTERVAL): пока игрок держит атаку, вращение непрерывно, а отпустил — бур не встаёт
## колом, а замедляется по инерции.
const SPIN_COAST := 0.45
var _rotor: Node3D = null
var _rotor_axis := Vector3.UP
var _spin_t := 0.0

func _ready() -> void:
	super()                  # VehicleBlock._ready (слои, hp, заморозка)
	$drill.monitoring = true # сенсор бура держим включённым: overlaps готовы к первому же удару
	_rotor = _find_rotor(self)
	if _rotor != null:
		# Ось в осях КОРОНКИ: относительный базис «блок ← коронка», обращённый на перёд блока.
		var rel: Basis = global_transform.basis.inverse() * _rotor.global_transform.basis
		_rotor_axis = (rel.inverse() * Vector3.FORWARD).normalized()

func _find_rotor(n: Node) -> Node3D:
	for c in n.get_children():
		if c is Node3D and SPIN_NAMES.has(c.name):
			return c as Node3D
		var deep: Node3D = _find_rotor(c)
		if deep != null:
			return deep
	return null

func _physics_process(delta: float) -> void:
	if _dig_cd > 0.0:
		_dig_cd -= delta
	if _spin_t > 0.0:
		_spin_t -= delta
		if _rotor != null and is_instance_valid(_rotor):
			# rotate_object_local, а не rotate: ось посчитана в СВОИХ осях коронки, и вращать
			# надо вокруг неё же — rotate() крутил бы вокруг оси родителя.
			_rotor.rotate_object_local(_rotor_axis, SPIN_SPEED * delta)

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
		if body.has_method("hurt"):
			body.hurt(drill_damage)
