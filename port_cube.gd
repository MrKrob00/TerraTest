@tool
extends Control
class_name PortCube

# КУБИК С КНОПКАМИ — настройка сторон блока прямо на его форме.
#
# Зачем не список. Стороны блока — это стороны КУБА, и список из шести строк заставлял
# игрока держать в голове, где у блока «зад», а где «низ», да ещё и сверять это с тем, как
# блок реально стоит на машине. На кубе видно сразу: тыкаешь в ту грань, которую видишь.
#
# ДВА КУБА, а не один вращающийся. У куба шесть граней, а видно за раз три — значит нужен
# либо поворот, либо второй куб. Второй куб честнее: обе половины видны ОДНОВРЕМЕННО, и
# ничего не надо крутить, чтобы вспомнить, что стоит на обратной стороне.
#
# Один виджет на два места: в игре им настраивают порты КЛЕТОК многоклеточного блока
# (по клетке на грань стороны), в редакторе — маски граней самой сцены (тогда футпринт
# состоит из одной клетки, и грань = одна кнопка).

## Клетки футпринта: смещения от якоря. Одна клетка = грань целиком, восемь клеток
## (блок 2×2×2) = по четыре кнопки на сторону.
var cells: Array = [Vector3i.ZERO]
## Спросить состояние: func(off: Vector3i, dir_idx: int) -> int. Индекс направления — как в
## VehicleBlock.FACE_VECS (0 front −Z, 1 back +Z, 2 left −X, 3 right +X, 4 top +Y, 5 bottom −Y).
var state_of: Callable = Callable()
## Клик по грани клетки: func(off: Vector3i, dir_idx: int) -> void. Само состояние виджет не
## хранит — он рисует то, что ответит state_of, и после клика просто перерисовывается.
var on_click: Callable = Callable()
## Подписи и цвета состояний. Их три и в игре (нет / вход / выход), и в редакторе
## (нет / есть — третье просто не используется).
var labels: Array = ["—", "IN", "OUT"]
var colors: Array = [
	Color(0.082, 0.235, 0.275, 0.95),
	Color(0.25, 0.72, 0.95, 1.0),
	Color(1.0, 0.72, 0.25, 1.0),
]

const EDGE := Color(0.247, 0.6, 0.65, 0.85)
const CAPTION := Color(0.45, 0.70, 0.75)
const PAD := 10.0
const CAP_H := 18.0

## Направления по индексам FACE_VECS. Дублировать VehicleBlock.FACE_VECS нельзя (разъедутся),
## но и зависеть от узла блока виджет не должен — он рисует и в редакторе, где блока может
## не быть вовсе. Поэтому храним ЦЕЛОЧИСЛЕННЫЕ направления в том же порядке и сверяем их
## с оригиналом одним assert'ом в _ready.
const DIRS := [
	Vector3i(0, 0, -1), Vector3i(0, 0, 1), Vector3i(-1, 0, 0),
	Vector3i(1, 0, 0), Vector3i(0, 1, 0), Vector3i(0, -1, 0),
]
const DIR_NAME := ["FRONT −Z", "BACK +Z", "LEFT −X", "RIGHT +X", "TOP +Y", "BOTTOM −Y"]
## Короткое имя стороны — его пишем ПРЯМО НА ГРАНИ, под состоянием.
const SHORT_NAME := ["front", "back", "left", "right", "top", "bottom"]

## Две изометрии, смотрящие с противоположных углов. Базис задан образами осей X/Y/Z на
## экране; ядро этого отображения — (1,1,1), то есть смотрим ровно вдоль диагонали куба, и
## видно ровно три грани. Второй вид — тот же базис со сменённым знаком: видно другие три.
const VIEWS := [
	{"ax": Vector2(0.866, 0.5), "ay": Vector2(0.0, -1.0), "az": Vector2(-0.866, 0.5),
	 "faces": [3, 4, 1], "cap": "right · top · back"},
	{"ax": Vector2(-0.866, -0.5), "ay": Vector2(0.0, 1.0), "az": Vector2(0.866, -0.5),
	 "faces": [2, 5, 0], "cap": "left · bottom · front"},
]

var _quads: Array = []          # [{poly, off, dir}] — построены последней отрисовкой

func _ready() -> void:
	# Размер ставим, только если его не задали снаружи: окно портов считает высоту от экрана,
	# и затирать её своим числом значит ломать ровно ту раскладку, ради которой её считали.
	if custom_minimum_size.y <= 0.0:
		custom_minimum_size.y = 190.0
	mouse_filter = Control.MOUSE_FILTER_STOP
	# Сверяем порядок направлений с оригиналом. Разъехавшись, эти два списка молча
	# перепутали бы грани местами, и кнопка «верх» настраивала бы, скажем, зад.
	for i in DIRS.size():
		var v: Vector3 = VehicleBlock.FACE_VECS[i]
		assert(DIRS[i] == Vector3i(int(signf(v.x)), int(signf(v.y)), int(signf(v.z))),
				"PortCube.DIRS разошёлся с VehicleBlock.FACE_VECS")

# ── Геометрия ────────────────────────────────────────────────────────────────
## Габариты футпринта в клетках: от минимального угла до максимального ВКЛЮЧАЯ саму клетку.
func _bounds() -> Array:
	var lo := Vector3(0, 0, 0)
	var hi := Vector3(1, 1, 1)
	var first := true
	for c in cells:
		var o: Vector3i = c
		var a := Vector3(o.x, o.y, o.z)
		var b := a + Vector3.ONE
		if first:
			lo = a
			hi = b
			first = false
			continue
		lo = Vector3(minf(lo.x, a.x), minf(lo.y, a.y), minf(lo.z, a.z))
		hi = Vector3(maxf(hi.x, b.x), maxf(hi.y, b.y), maxf(hi.z, b.z))
	return [lo, hi]

## Масштаб и точка отсчёта одного вида: куб вписан в свою половину виджета.
func _geom(vi: int) -> Dictionary:
	var v: Dictionary = VIEWS[vi]
	var half := Vector2(size.x * 0.5, size.y)
	var rect := Rect2(Vector2(half.x * float(vi) + PAD, PAD),
			Vector2(maxf(half.x - PAD * 2.0, 8.0), maxf(half.y - PAD * 2.0 - CAP_H, 8.0)))
	var b: Array = _bounds()
	var lo: Vector3 = b[0]
	var hi: Vector3 = b[1]
	# Проекции восьми углов при единичном масштабе — по ним и считаем габарит картинки.
	var mn := Vector2(INF, INF)
	var mx := Vector2(-INF, -INF)
	for i in 8:
		var p := Vector3(hi.x if (i & 1) else lo.x, hi.y if (i & 2) else lo.y, hi.z if (i & 4) else lo.z)
		var s: Vector2 = v["ax"] * p.x + v["ay"] * p.y + v["az"] * p.z
		mn = Vector2(minf(mn.x, s.x), minf(mn.y, s.y))
		mx = Vector2(maxf(mx.x, s.x), maxf(mx.y, s.y))
	var span: Vector2 = mx - mn
	var sc: float = minf(rect.size.x / maxf(span.x, 0.001), rect.size.y / maxf(span.y, 0.001))
	var origin: Vector2 = rect.position + (rect.size - span * sc) * 0.5 - mn * sc
	return {"v": v, "sc": sc, "origin": origin, "rect": rect}

func _project(g: Dictionary, p: Vector3) -> Vector2:
	var v: Dictionary = g["v"]
	return g["origin"] + (v["ax"] * p.x + v["ay"] * p.y + v["az"] * p.z) * float(g["sc"])

## Четыре угла грани клетки в координатах клеток. Клетка o занимает куб [o, o+1].
func _face_corners(o: Vector3i, d: Vector3i) -> Array:
	var base := Vector3(o.x, o.y, o.z)
	if d.x > 0: base.x += 1.0
	if d.y > 0: base.y += 1.0
	if d.z > 0: base.z += 1.0
	# Два направления вдоль грани — те оси, по которым нормаль равна нулю.
	var u := Vector3.ZERO
	var w := Vector3.ZERO
	if d.x != 0:
		u = Vector3(0, 1, 0); w = Vector3(0, 0, 1)
	elif d.y != 0:
		u = Vector3(1, 0, 0); w = Vector3(0, 0, 1)
	else:
		u = Vector3(1, 0, 0); w = Vector3(0, 1, 0)
	return [base, base + u, base + u + w, base + w]

# ── Отрисовка ────────────────────────────────────────────────────────────────
func _draw() -> void:
	_quads.clear()
	var font: Font = get_theme_default_font()
	var fs: int = maxi(get_theme_default_font_size() - 2, 9)
	var fn: int = maxi(fs - 3, 7)          # имя стороны мельче состояния: оно подпись, а не кнопка
	for vi in VIEWS.size():
		var g: Dictionary = _geom(vi)
		for di in (g["v"]["faces"] as Array):
			var d: Vector3i = DIRS[int(di)]
			for c in cells:
				var o: Vector3i = c
				if cells.has(o + d):
					continue          # внутренняя клетка: с этой стороны она закрыта соседкой
				var poly := PackedVector2Array()
				for p in _face_corners(o, d):
					poly.append(_project(g, p))
				var st: int = _state(o, int(di))
				draw_colored_polygon(poly, colors[clampi(st, 0, colors.size() - 1)])
				var outline := PackedVector2Array(poly)
				outline.append(poly[0])
				draw_polyline(outline, EDGE, 1.5)
				if font != null:
					var mid: Vector2 = (poly[0] + poly[1] + poly[2] + poly[3]) * 0.25
					var t: String = String(labels[clampi(st, 0, labels.size() - 1)])
					var w: float = font.get_string_size(t, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
					var ink: Color = Color(0.05, 0.10, 0.12) if st != 0 else Color(0.55, 0.75, 0.80)
					draw_string(font, mid + Vector2(-w * 0.5, -1.0), t,
							HORIZONTAL_ALIGNMENT_LEFT, -1, fs, ink)
					# ИМЯ СТОРОНЫ ПОД СОСТОЯНИЕМ. Без него по картинке не понять, которая из
					# трёх видимых граней «right», а которая «back»: подпись под кубиком
					# перечисляет их разом, а какая где — приходится угадывать.
					var nm: String = String(SHORT_NAME[int(di)])
					var nw: float = font.get_string_size(nm, HORIZONTAL_ALIGNMENT_LEFT, -1, fn).x
					draw_string(font, mid + Vector2(-nw * 0.5, fn + 2.0), nm,
							HORIZONTAL_ALIGNMENT_LEFT, -1, fn, ink * Color(1, 1, 1, 0.75))
				_quads.append({"poly": poly, "off": o, "dir": int(di)})
		if font != null:
			var cap: String = String(g["v"]["cap"])
			var cw: float = font.get_string_size(cap, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
			var r: Rect2 = g["rect"]
			draw_string(font, Vector2(r.position.x + (r.size.x - cw) * 0.5, size.y - 4.0),
					cap, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, CAPTION)

func _state(o: Vector3i, di: int) -> int:
	if not state_of.is_valid():
		return 0
	var v = state_of.call(o, di)
	return int(v) if v != null else 0

# ── Клик ─────────────────────────────────────────────────────────────────────
# Ввод берём в _input, а НЕ в _gui_input. Кубик лежит в окне, которое само по себе Control с
# mouse_filter STOP, поверх него — затемнение и панель, а над всем этим ещё и разбор тапа
# машиной: до gui_input событие может просто не дойти, и кубик оказывался «только показывает».
# _input у узлов вызывается ДО разбора GUI, поэтому попадание проверяем сами по своему
# прямоугольнику. Ровно так же в проекте сделаны круговое меню и жест закрытия окна.
#
# gui_input оставлен запасным путём для РЕДАКТОРА: там инспектор раздаёт ввод по-своему.
# Двойной обработки не будет — сработавший _input гасит событие, а совпадающие по времени и
# месту касания отсекает _dedup (тач и эмулированная из него мышь приходят ПАРОЙ).
const DEDUP_MS: int = 120
var _last_ms: int = 0
var _last_pos: Vector2 = Vector2(-9999, -9999)

func _input(event: InputEvent) -> void:
	if not is_visible_in_tree():
		return
	var pos: Variant = _press_pos(event)
	if pos == null or not get_global_rect().has_point(pos):
		return
	if _hit(pos as Vector2 - global_position):
		get_viewport().set_input_as_handled()

func _gui_input(event: InputEvent) -> void:
	var pos: Variant = _press_pos(event)
	if pos == null:
		return
	if _hit(pos as Vector2):
		accept_event()

## Позиция НАЖАТИЯ или null, если это не оно. Отпускание не трогаем: грань должна
## переключаться в момент касания, как кнопка.
func _press_pos(event: InputEvent) -> Variant:
	if event is InputEventMouseButton and (event as InputEventMouseButton).pressed \
			and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
		return (event as InputEventMouseButton).position
	if event is InputEventScreenTouch and (event as InputEventScreenTouch).pressed:
		return (event as InputEventScreenTouch).position
	return null

## Попадание по грани. Перебираем В ОБРАТНОМ порядке отрисовки: последняя нарисованная лежит
## сверху, и именно в неё игрок целился, если квадраты где-то накладываются.
func _hit(local: Vector2) -> bool:
	var now: int = Time.get_ticks_msec()
	if now - _last_ms < DEDUP_MS and _last_pos.distance_squared_to(local) < 25.0:
		return true                   # тот же тап пришёл вторым событием — гасим, но не крутим
	for i in range(_quads.size() - 1, -1, -1):
		var q: Dictionary = _quads[i]
		if not _inside(q["poly"], local):
			continue
		_last_ms = now
		_last_pos = local
		if on_click.is_valid():
			on_click.call(q["off"], int(q["dir"]))
		queue_redraw()
		return true
	return false

## Точка внутри параллелограмма: раскладываем её по двум сторонам грани. Общий алгоритм для
## произвольного многоугольника здесь не нужен — все грани куба параллелограммы по построению.
func _inside(poly: PackedVector2Array, p: Vector2) -> bool:
	if poly.size() < 4:
		return false
	var u: Vector2 = poly[1] - poly[0]
	var w: Vector2 = poly[3] - poly[0]
	var det: float = u.x * w.y - u.y * w.x
	if absf(det) < 0.0001:
		return false
	var r: Vector2 = p - poly[0]
	var a: float = (r.x * w.y - r.y * w.x) / det
	var b: float = (u.x * r.y - u.y * r.x) / det
	return a >= 0.0 and a <= 1.0 and b >= 0.0 and b <= 1.0
