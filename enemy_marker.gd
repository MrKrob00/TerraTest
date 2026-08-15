class_name EnemyMarker
extends Node3D
# Метка над вражеской машиной: красный ромб и имя под ним, всегда лицом к камере.
# Нужна затем же, зачем в TerraTech: враг — это не «серая коробка вдалеке», а конкретный
# противник, которого видно и в толпе, и за деревом, и по которому понятно, кто перед тобой.
#
# Рисуем двумя Label3D, а не спрайтом: билборд, обводка и отключённый depth-тест у Label3D
# уже есть, а текстуру пришлось бы заводить и держать в атласе. Эмодзи не берём — шрифт
# проекта их не рендерит (та же причина, по которой иконки в HUD рисуются кодом).

## Дальше этого метку не показываем: у горизонта их были бы десятки поверх друг друга.
const SHOW_DISTANCE := 140.0
## Ближе этого метка не нужна — машина и так занимает пол-экрана, а метка лезет в прицел.
const HIDE_DISTANCE := 6.0
const COL := Color(1.0, 0.32, 0.30)

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
	l.no_depth_test = true              # видно и за деревом: метка — это подсказка, а не объект
	l.modulate = COL
	l.outline_size = 22
	l.outline_modulate = Color(0, 0, 0, 0.85)
	l.position.y = y
	add_child(l)
	return l

func _process(delta: float) -> void:
	var cc: Node = get_tree().get_first_node_in_group("camera_controller")
	if cc == null or not ("current_vehicle" in cc) or cc.current_vehicle == null:
		visible = false
		return
	var d: float = (cc.current_vehicle as Node3D).global_position.distance_to(global_position)
	visible = d <= SHOW_DISTANCE and d >= HIDE_DISTANCE
	if not visible:
		return
	# Размер метки НЕ должен таять с расстоянием: Label3D по умолчанию уменьшается
	# перспективой, и на боевой дистанции имя превращалось бы в пиксель. Растим сами,
	# но с потолком — вблизи метка не должна закрывать саму машину.
	var k: float = clampf(d / 26.0, 0.55, 3.0)
	scale = Vector3.ONE * k
	# Лёгкая пульсация ромба — метка живая, глаз её находит в куче деревьев.
	_t += delta
	_pin.modulate = COL * (0.85 + 0.15 * sin(_t * 3.0))
