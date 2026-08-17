class_name EnemyMarker
extends Node3D
# Метка над вражеской машиной: красный ромб и имя под ним, всегда лицом к камере.
# Нужна затем же, зачем в TerraTech: враг — это не «серая коробка вдалеке», а конкретный
# противник, которого видно и в толпе, и за деревом, и по которому понятно, кто перед тобой.
#
# Рисуем двумя Label3D, а не спрайтом: билборд и обводка у Label3D уже есть, а текстуру
# пришлось бы заводить и держать в атласе. Эмодзи не берём — шрифт проекта их не рендерит
# (та же причина, по которой иконки в HUD рисуются кодом).

## Дальше этого метку не показываем: у горизонта их были бы десятки поверх друг друга.
## Значение больше, чем радиус обнаружения врага (85), и это главное: игрок обязан увидеть
## противника ЗАРАНЕЕ, пока тот ещё патрулирует, а не в момент, когда тот уже бросился.
const SHOW_DISTANCE := 220.0
## Ближе этого метка не нужна — машина и так занимает пол-экрана, а метка лезет в прицел.
const HIDE_DISTANCE := 6.0
const COL := Color(1.0, 0.32, 0.30)
## Цвет НАЗНАЧЕННОЙ цели: приказ «бей вот этого» обязан быть виден, иначе игрок не понимает,
## сработал тап или нет и по кому сейчас работают орудия.
const COL_MARKED := Color(1.0, 0.85, 0.2)

# Имя собираем из двух списков по идентификатору узла: одна и та же машина всегда
# называется одинаково, а сохранять имя никуда не нужно.
const ADJ := ["Tiny", "Rusty", "Grim", "Swift", "Iron", "Mad", "Lone", "Bitter",
		"Quick", "Old", "Blind", "Sharp"]
const NOUN := ["Seal", "Wolf", "Crow", "Boar", "Hawk", "Toad", "Lynx", "Moth",
		"Rat", "Bull", "Kite", "Mole"]

var vehicle: Node3D = null           # машина-владелец (ставит machine_body при создании)

var _pin: Label3D = null
var _name: Label3D = null
var _t: float = 0.0

static func name_for(id: int) -> String:
	return "%s %s" % [ADJ[absi(id) % ADJ.size()], NOUN[absi(id / ADJ.size()) % NOUN.size()]]

func _ready() -> void:
	_pin = _label("◆", 150, 0.0)
	_name = _label(name_for(int(vehicle.get_instance_id()) if vehicle else get_instance_id()),
			64, -0.55)

func _label(text: String, font_size: int, y: float) -> Label3D:
	var l := Label3D.new()
	l.text = text
	l.font_size = font_size
	l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	# Depth-тест ВКЛЮЧЁН: метка должна прятаться за рельефом, иначе враг за холмом
	# «просвечивает» сквозь карту и выглядит стоящим на склоне перед тобой.
	l.no_depth_test = false
	l.modulate = COL
	l.outline_size = 22
	l.outline_modulate = Color(0, 0, 0, 0.85)
	l.position.y = y
	add_child(l)
	return l

## Контроллер камеры кешируем. Он один на сцену и не меняется, а поиск по группе шёл
## КАЖДЫЙ кадр у КАЖДОЙ метки — это обход дерева ради ссылки, которая не менялась с
## запуска, и стоит он больше любого корня, который мы отсюда убрали.
var _cc: Node = null

func _camera_controller() -> Node:
	if _cc != null and is_instance_valid(_cc):
		return _cc
	_cc = get_tree().get_first_node_in_group("camera_controller")
	return _cc

func _process(delta: float) -> void:
	var cc: Node = _camera_controller()
	if cc == null or not ("current_vehicle" in cc) or cc.current_vehicle == null:
		visible = false
		return
	# Гейт видимости считаем по КВАДРАТУ: _process идёт каждый кадр у каждой метки, а
	# большинство их невидимо — корень для них считался впустую. Настоящее расстояние
	# берём ниже, уже только для видимых: там оно нужно значением, а не сравнением.
	var d2: float = (cc.current_vehicle as Node3D).global_position.distance_squared_to(global_position)
	visible = d2 <= SHOW_DISTANCE * SHOW_DISTANCE and d2 >= HIDE_DISTANCE * HIDE_DISTANCE
	if not visible:
		return
	var d: float = sqrt(d2)
	# Размер метки НЕ должен таять с расстоянием: Label3D по умолчанию уменьшается
	# перспективой, и на боевой дистанции имя превращалось бы в пиксель. Растим сами,
	# но с потолком — вблизи метка не должна закрывать саму машину.
	var k: float = clampf(d / 26.0, 0.55, 3.0)
	scale = Vector3.ONE * k
	# Лёгкая пульсация ромба — метка живая, глаз её находит в куче деревьев. У назначенной
	# цели пульсация ЗАМЕТНЕЕ и цвет другой: её видно среди прочих врагов сразу.
	_t += delta
	var marked: bool = _is_marked(cc.current_vehicle)
	var base: Color = COL_MARKED if marked else COL
	var amp: float = 0.35 if marked else 0.15
	_pin.modulate = base * (0.85 + amp * sin(_t * (6.0 if marked else 3.0)))
	_name.modulate = base

# Назначена ли ЭТА машина (или её блок) приоритетной целью активной машины игрока.
func _is_marked(player: Node) -> bool:
	if player == null or not is_instance_valid(player) or not ("priority_target" in player):
		return false
	var t = player.priority_target
	if t == null or not is_instance_valid(t):
		return false
	var p: Node = t
	while p != null:
		if p == vehicle:
			return true
		p = p.get_parent()
	return false
