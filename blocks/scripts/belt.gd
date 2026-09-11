# belt.gd
extends FactoryBlock
#
# ЛЕНТА ОТДАЁТ И ВБОК — СТАНКУ, СТОЯЩЕМУ РЯДОМ С ЛИНИЕЙ (output_faces в сцене: вперёд + оба
# борта). Так собирают фабрику в TerraTech: конвейер идёт своей полосой, а процессор,
# фабрикатор или скраппер стоят ВОЗЛЕ него и снимают с него груз; раньше станок приходилось
# врезать В РАЗРЫВ линии, то есть ставить вместо куска ленты.
#
# Из этого следуют два правила, и оба живут здесь, а не в масках: маска знает только сторону,
# а нам важно, КТО с той стороны стоит.
#
#   • ДВЕ ЛЕНТЫ БОК О БОК — ЭТО ДВЕ ЛИНИИ, а не одна. Боковой выход к соседней ленте
#     запрещён: иначе параллельные полосы начали бы перекидывать груз друг другу, и
#     двухполосный конвейер, который игрок собирал как две дороги, превращался бы в кашу.
#   • СТАНОК ВАЖНЕЕ СЛЕДУЮЩЕЙ ЛЕНТЫ. push_item раздаёт по кругу (это нужно делителю), и
#     станок сбоку получал бы каждый второй предмет, а остальное уезжало бы к продавцу
#     сырьём. Поэтому сначала предлагаем тем, кто не лента, и лишь потом гоним дальше.

@export var belt_speed: float = 1.0

var timer: Timer

func _ready() -> void:
	super._ready()
	timer = Timer.new()
	timer.wait_time = belt_speed
	timer.autostart = false
	timer.one_shot = true
	timer.timeout.connect(_on_timer_timeout)
	add_child(timer)

func _on_item_received() -> void:
	timer.stop()
	timer.start()

## Соседние ленты по БОРТУ из целей выкидываем (см. шапку). Прямо (по −Z) лента ленте отдаёт
## как и раньше — на это вся линия и держится.
func _valid_targets() -> Array:
	var out: Array = []
	for t in super._valid_targets():
		if _is_belt(t) and _is_side(t):
			continue
		out.append(t)
	return out

func _is_belt(t: Node) -> bool:
	var bt = t.get("block")
	return bt != null and int(bt) in [G.Block.BELT, G.Block.BELT_SPLIT, G.Block.BELT_CROSS]

## Стоит ли сосед СБОКУ, а не по ходу ленты. Считаем в СВОИХ осях: лента бывает повёрнута
## как угодно, и «вбок» — это её собственный борт, а не ось мира.
func _is_side(t: Node) -> bool:
	if not (t is Node3D):
		return false
	var d: Vector3 = global_transform.basis.inverse() * ((t as Node3D).global_position - global_position)
	return absf(d.x) > absf(d.z)

func push_item(item: Node3D) -> bool:
	if item == null or not is_instance_valid(item):
		return false
	for t in _valid_targets():
		if _is_belt(t):
			continue                       # ленту оставляем на второй заход
		if (t as FactoryBlock).try_receive(item):
			next_block = t
			return true
	# ВТОРОЙ ЗАХОД — ЛЕНТЫ, и не всякая: за той, у которой в очереди стоит станок, место
	# занято (см. side_waiting). Раньше здесь стоял super.push_item, то есть круговой обход
	# всех целей, — и сквозной поток забирал каждую освободившуюся клетку.
	for t in _valid_targets():
		if not _is_belt(t):
			continue
		if t.has_method("side_waiting") and t.side_waiting():
			continue
		if (t as FactoryBlock).try_receive(item):
			next_block = t
			return true
	return false

## СТАНОК СБОКУ ВПЕРЁД СКВОЗНОГО ПОТОКА — ждёт ли кто-то эту клетку.
##
## Станок снимает груз с ленты и возвращает результат НА НЕЁ ЖЕ, клеткой ближе к выходу. За эту
## клетку он соревнуется с соседней лентой и проигрывает: та отдаёт каждый свой такт, а он ждёт
## сигнала об освободившемся месте. Пока станок стоит с готовым грузом, он НЕ БЕРЁТ новый — и
## через несколько ящиков линия встаёт целиком: лента перед станком забита, станок держит выход,
## отдать некуда.
##
## Спрашиваем у соседей по машине, а не держим список: подписчиков у клетки не бывает больше
## горстки, а вторая структура про то же самое разъехалась бы при первой же пересборке цепочки.
func side_waiting() -> bool:
	var host: Node = get_parent()
	if host == null:
		return false
	for b in host.get_children():
		if b == self or not (b is FactoryBlock) or _is_belt(b):
			continue
		var f := b as FactoryBlock
		if f.current_item != null and f.waiting_for_next and f.next_blocks.has(self):
			return true
	return false

func _on_timer_timeout() -> void:
	_try_push()
	# trying again 
	if current_item != null:
		timer.wait_time = 0.1
		timer.start()
	else:
		timer.wait_time = belt_speed
