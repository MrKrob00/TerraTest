class_name ShieldHex
extends RefCounted
## КУПОЛ ЩИТА: ШЕСТИУГОЛЬНИКИ — ЭТО ГЕОМЕТРИЯ, А НЕ УЗОР В ШЕЙДЕРЕ.
##
## Рисовать сетку по поверхности сферы бесполезно, и это не вопрос настроек. По UV линии
## долготы сходятся к полюсам и узор закручивается; по грани куба полюсов нет, но клетка
## тянется к силуэту и на краю перестаёт быть шестиугольником. Равномерной шестиугольной
## РАЗМЕТКИ сферы не существует в принципе.
##
## Существует шестиугольный МНОГОГРАННИК: многогранник Голдберга — двойственный к геодезической
## сфере. Икосаэдр делится на sub² треугольников на грань, вершины выносятся на сферу, и вокруг
## каждой вершины собирается ячейка из центров прилежащих треугольников. Получается 10·sub²+2
## ячейки: ровно двенадцать пятиугольников (над вершинами исходного икосаэдра) и все остальные
## шестиугольники, одного размера по всему куполу. Двенадцать пятиугольников убрать нельзя, это
## топология — у футбольного мяча они ровно по той же причине.
##
## КАЖДАЯ ЯЧЕЙКА ЗНАЕТ СЕБЯ. В цвет вершины кладётся направление на центр ячейки (rgb) и её
## случайное число (a), в UV — сколько до ребра (x) и место вдоль ребра (y). Отсюда шейдер
## получает всё даром: шов, угловые точки, какие пластины гаснут с разрядом и — главное — какая
## ОДНА пластина вспыхнула от попадания. Ни хешей на пиксель, ни mod, ни atan.

## Дно ячейки строится веером от её центра, поэтому UV.x — это барицентрическая доля от центра
## к ребру: ровно «насколько близко к краю пластины», и линии уровня повторяют сам многоугольник.
const UV_CENTER := Vector2(0.0, 0.5)
const UV_EDGE_A := Vector2(1.0, 0.0)
const UV_EDGE_B := Vector2(1.0, 1.0)

## Зерно у раскладки постоянное: какие пластины гаснут первыми, должно совпадать у всех куполов
## и не меняться между запусками.
const CELL_SEED := 20260919

## Возвращает {"mesh": ArrayMesh, "centers": Array[Vector3]} — меш купола и единичные
## направления на центры ячеек в том же порядке, в каком они попали в меш.
static func build(radius: float, sub: int) -> Dictionary:
	sub = maxi(sub, 1)
	var pts: Array[Vector3] = []
	var seen := {}
	var tris: Array = []
	var ico := _icosahedron()
	var iv: Array = ico[0]
	for face in ico[1]:
		var a: Vector3 = iv[face[0]]
		var b: Vector3 = iv[face[1]]
		var c: Vector3 = iv[face[2]]
		for i in sub:
			for j in range(sub - i):
				var i00 := _index(pts, seen, _bary(a, b, c, i, j, sub))
				var i10 := _index(pts, seen, _bary(a, b, c, i + 1, j, sub))
				var i01 := _index(pts, seen, _bary(a, b, c, i, j + 1, sub))
				tris.append([i00, i10, i01])
				if i + j < sub - 1:
					var i11 := _index(pts, seen, _bary(a, b, c, i + 1, j + 1, sub))
					tris.append([i10, i11, i01])

	# Центр каждого треугольника — вершина будущей ячейки; ячейка стоит НА вершине сетки.
	var cent: Array[Vector3] = []
	for t in tris:
		cent.append(((pts[t[0]] + pts[t[1]] + pts[t[2]]) / 3.0).normalized())
	var around := {}
	for ti in tris.size():
		for vi in tris[ti]:
			if not around.has(vi):
				around[vi] = []
			(around[vi] as Array).append(ti)

	var rng := RandomNumberGenerator.new()
	rng.seed = CELL_SEED
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var centers: Array[Vector3] = []
	for vi in pts.size():
		var c: Vector3 = pts[vi]
		var ring: Array = _sorted_ring(c, around.get(vi, []), cent)
		if ring.size() < 3:
			continue
		centers.append(c)
		var col := Color(c.x * 0.5 + 0.5, c.y * 0.5 + 0.5, c.z * 0.5 + 0.5, rng.randf())
		var n := ring.size()
		for k in n:
			var p0: Vector3 = ring[k]
			var p1: Vector3 = ring[(k + 1) % n]
			_vertex(st, col, c, UV_CENTER, radius)
			_vertex(st, col, p0, UV_EDGE_A, radius)
			_vertex(st, col, p1, UV_EDGE_B, radius)
	var mesh := st.commit()
	return {"mesh": mesh, "centers": centers}

# ── Кухня ─────────────────────────────────────────────────────────────────────

static func _icosahedron() -> Array:
	var t := (1.0 + sqrt(5.0)) * 0.5
	var v: Array[Vector3] = [
		Vector3(-1, t, 0), Vector3(1, t, 0), Vector3(-1, -t, 0), Vector3(1, -t, 0),
		Vector3(0, -1, t), Vector3(0, 1, t), Vector3(0, -1, -t), Vector3(0, 1, -t),
		Vector3(t, 0, -1), Vector3(t, 0, 1), Vector3(-t, 0, -1), Vector3(-t, 0, 1)]
	for i in v.size():
		v[i] = v[i].normalized()
	var f := [
		[0, 11, 5], [0, 5, 1], [0, 1, 7], [0, 7, 10], [0, 10, 11],
		[1, 5, 9], [5, 11, 4], [11, 10, 2], [10, 7, 6], [7, 1, 8],
		[3, 9, 4], [3, 4, 2], [3, 2, 6], [3, 6, 8], [3, 8, 9],
		[4, 9, 5], [2, 4, 11], [6, 2, 10], [8, 6, 7], [9, 8, 1]]
	return [v, f]

static func _bary(a: Vector3, b: Vector3, c: Vector3, i: int, j: int, n: int) -> Vector3:
	var u := float(i) / float(n)
	var v := float(j) / float(n)
	return (a * (1.0 - u - v) + b * u + c * v).normalized()

## Один и тот же узел приходит от соседних граней — склеиваем по округлённым координатам,
## иначе у каждой ячейки окажется по своему экземпляру соседа и веер не сомкнётся.
static func _index(pts: Array[Vector3], seen: Dictionary, p: Vector3) -> int:
	var key := Vector3i(roundi(p.x * 100000.0), roundi(p.y * 100000.0), roundi(p.z * 100000.0))
	if seen.has(key):
		return int(seen[key])
	pts.append(p)
	seen[key] = pts.size() - 1
	return pts.size() - 1

## Соседние центры по кругу вокруг вершины. Без сортировки веер выходит «звездой»: порядок
## треугольников в списке — это порядок их создания, а не обход по кругу.
static func _sorted_ring(c: Vector3, faces: Array, cent: Array[Vector3]) -> Array:
	if faces.size() < 3:
		return []
	var e1: Vector3 = _tangent(c, cent[int(faces[0])])
	var e2: Vector3 = c.cross(e1)
	var pairs: Array = []
	for ti in faces:
		var p: Vector3 = cent[int(ti)]
		var d: Vector3 = p - c * p.dot(c)
		pairs.append([atan2(d.dot(e2), d.dot(e1)), p])
	pairs.sort_custom(_by_angle)
	var ring: Array = []
	for pr in pairs:
		ring.append(pr[1])
	# ЛИЦЕВОЙ ОБХОД В GODOT — ПО ЧАСОВОЙ СТРЕЛКЕ, если смотреть снаружи. По правилу правой руки
	# это нормаль, направленная ВНУТРЬ, поэтому условие выглядит перевёрнутым. Ошибиться здесь
	# нельзя незаметно: купол с обратным обходом просто не рисуется — его срежет отсечение.
	var nrm: Vector3 = (ring[0] - c).cross(ring[1] - c)
	if nrm.dot(c) > 0.0:
		ring.reverse()
	return ring

static func _by_angle(x, y) -> bool:
	return float(x[0]) < float(y[0])

static func _tangent(c: Vector3, p: Vector3) -> Vector3:
	var d: Vector3 = p - c * p.dot(c)
	if d.length_squared() < 1e-12:
		d = c.cross(Vector3.UP if absf(c.y) < 0.9 else Vector3.RIGHT)
	return d.normalized()

static func _vertex(st: SurfaceTool, col: Color, dir: Vector3, uv: Vector2, radius: float) -> void:
	st.set_color(col)
	st.set_uv(uv)
	st.set_normal(dir)              # нормаль сферы, а не грани: френель обязан быть гладким
	st.add_vertex(dir * radius)
