extends FactoryBlock

# ПЕРЕКРЁСТНЫЙ КОНВЕЙЕР. Пропускает предметы НАСКВОЗЬ и строго ПО ОЧЕРЕДИ по осям:
# сначала один предмет по линии север↔юг, потом один по линии запад↔восток, и снова.
# Так две линии делят один перекрёсток и ни одна не забивает его насовсем.
#
# Отсюда два отличия от обычного конвейера:
#   • принимаем только с той оси, чья сейчас очередь;
#   • отдаём ТОЛЬКО в блок с противоположной стороны, а не первому подключённому.
#
# Направление прихода узнаём по отдающему блоку: в момент try_receive предмет ещё
# лежит в нём, а оба блока — соседи по сетке, поэтому разность их локальных позиций и
# есть ось. Плести это через сигнатуру try_receive не пришлось.

## Ось, чья сейчас очередь: true — Z (север↔юг), false — X (запад↔восток).
var _axis_z: bool = true
var _in_dir: Vector3i = Vector3i.ZERO      # с какой стороны пришёл предмет, что лежит внутри

func try_receive(item: Node3D) -> bool:
	if current_item != null:
		return false
	var d: Vector3i = _incoming_dir(item)
	if d == Vector3i.ZERO:
		return false                       # отдающий не сосед по сетке — пропускаем
	if (d.z != 0) != _axis_z:
		return false                       # сейчас очередь другой оси
	if not super.try_receive(item):
		return false
	_in_dir = d
	return true

func _on_item_received() -> void:
	call_deferred("_try_push")

# Отдаём насквозь: цель — сосед РОВНО с противоположной стороны от входа. Успех передаёт
# очередь другой оси.
func push_item(item: Node3D) -> bool:
	if item == null or not is_instance_valid(item) or _in_dir == Vector3i.ZERO:
		return false
	for t in next_blocks:
		if t == null or not is_instance_valid(t):
			continue
		if _grid_dir(self, t) != _in_dir:
			continue
		if t.try_receive(item):
			next_block = t
			_axis_z = not _axis_z          # предмет прошёл — очередь переходит другой оси
			_in_dir = Vector3i.ZERO
			return true
	return false

# Ось, по которой предмет пришёл (вектор ОТ отдающего К нам), или ZERO.
func _incoming_dir(item: Node3D) -> Vector3i:
	var from: Node = item.get_parent()
	if from == null or not (from is Node3D) or from.get_parent() != get_parent():
		return Vector3i.ZERO
	return _grid_dir(from as Node3D, self)

# Единичное направление по сетке от a к b. Блоки стоят по клеткам, поэтому разность
# позиций всегда почти осевая — берём доминирующую компоненту.
static func _grid_dir(a: Node3D, b: Node3D) -> Vector3i:
	var d: Vector3 = b.position - a.position
	if absf(d.x) >= absf(d.y) and absf(d.x) >= absf(d.z):
		return Vector3i(int(signf(d.x)), 0, 0) if absf(d.x) > 0.01 else Vector3i.ZERO
	if absf(d.y) >= absf(d.z):
		return Vector3i(0, int(signf(d.y)), 0) if absf(d.y) > 0.01 else Vector3i.ZERO
	return Vector3i(0, 0, int(signf(d.z))) if absf(d.z) > 0.01 else Vector3i.ZERO
