extends Control
## ЗАДНИК ГЛАВНОГО МЕНЮ: бой двух машин на горизонте, нарисованный ЦЕЛИКОМ В `_draw`.
##
## ПОЧЕМУ НЕ НАСТОЯЩАЯ СЦЕНА. Показать в меню живую игру — значит поднять рельеф, физику и
## стриминг ради картинки, по которой никто не ездит: меню перестало бы открываться мгновенно,
## а на телефоне ещё и грелось бы, пока игрок выбирает слот. Вырезать ради этого отдельную
## маленькую сцену с моделями — второй набор ассетов, который надо чинить каждый раз, когда
## меняются настоящие.
##
## Поэтому задник рисованный, и это ровно тот же приём, которым в проекте сделаны все иконки
## (`RadialWheel`, `GearIcon`, `RadarHUD`): процедурная отрисовка вместо текстур. Он говорит и
## тем же языком, что игра, — машины собраны ИЗ БЛОКОВ, попадания это красная матрица, трассеры
## бирюзовые. Стоит он один `_draw` на кадр и ноль загрузки.
##
## ВСЁ ДЕТЕРМИНИРОВАНО СВОИМ RNG: хребты не пересчитываются каждый кадр, а бой идёт по таймеру.
## Глобальный `randf` не трогаем — им пользуется вся остальная игра.

const SKY_TOP    := Color(0.043, 0.094, 0.110)
const SKY_BOTTOM := Color(0.086, 0.180, 0.196)
const RIDGE_FAR  := Color(0.055, 0.122, 0.137)
const RIDGE_MID  := Color(0.043, 0.098, 0.114)
const RIDGE_NEAR := Color(0.027, 0.063, 0.075)
const MACHINE    := Color(0.075, 0.161, 0.180)
const MACHINE_LIT:= Color(0.243, 0.545, 0.588)
const TRACER     := Color(0.35, 0.95, 1.0)
const HIT_A      := Color(1.0, 0.24, 0.18)
const HIT_B      := Color(1.0, 0.62, 0.12)

## Линия горизонта — доля высоты сверху. Высоко: под меню внизу и так уходит тёмный градиент,
## а бой должен идти в чистой части экрана, а не под панелями.
const HORIZON := 0.46
const SKY_BANDS := 18            # полос градиента неба: больше на глаз уже не отличить

const SHOT_EVERY_MIN := 0.35
const SHOT_EVERY_MAX := 0.9
const SHOT_SPEED := 2.1          # доля пути в секунду
const HIT_LIFE := 0.45

var _rng := RandomNumberGenerator.new()
var _t: float = 0.0
var _shot_t: float = 0.0
## Хребты: три слоя точек в ДОЛЯХ размера (0..1), чтобы не пересчитывать их на каждый ресайз.
var _ridges: Array = []
## Летящие трассеры: {from_left: bool, p: 0..1, col}. Попадания: {pos: Vector2, t: 0..1}.
var _shots: Array = []
var _hits: Array = []
## Отдача: у каждой машины свой сдвиг, гаснущий за доли секунды. Без неё выстрел выглядит как
## полоска, вылетевшая из ниоткуда.
var _recoil := [0.0, 0.0]

func _ready() -> void:
	_rng.seed = 0x7A11
	_build_ridges()
	set_process(true)

func _build_ridges() -> void:
	_ridges.clear()
	for layer in 3:
		var pts: Array = []
		var n: int = 14 + layer * 6
		var base: float = 0.02 + float(layer) * 0.035        # ближний хребет выше
		var amp: float = 0.05 + float(layer) * 0.045
		for i in n + 1:
			var x: float = float(i) / float(n)
			# Две синусоиды со сдвигом от RNG — дёшево и не читается как повтор.
			var h: float = base + amp * (0.5 + 0.5 * sin(x * (5.0 + float(layer) * 3.0)
					+ _rng.randf() * 0.35 + float(layer)))
			pts.append(Vector2(x, h))
		_ridges.append(pts)

func _process(delta: float) -> void:
	_t += delta
	for i in 2:
		_recoil[i] = maxf(_recoil[i] - delta * 6.0, 0.0)
	_shot_t -= delta
	if _shot_t <= 0.0:
		_shot_t = _rng.randf_range(SHOT_EVERY_MIN, SHOT_EVERY_MAX)
		_fire(_rng.randf() < 0.5)
	var i: int = _shots.size() - 1
	while i >= 0:
		var s: Dictionary = _shots[i]
		s["p"] = float(s["p"]) + delta * SHOT_SPEED
		if float(s["p"]) >= 1.0:
			_land(bool(s["from_left"]))
			_shots.remove_at(i)
		i -= 1
	i = _hits.size() - 1
	while i >= 0:
		var h: Dictionary = _hits[i]
		h["t"] = float(h["t"]) + delta / HIT_LIFE
		if float(h["t"]) >= 1.0:
			_hits.remove_at(i)
		i -= 1
	queue_redraw()

func _fire(from_left: bool) -> void:
	_recoil[0 if from_left else 1] = 1.0
	_shots.append({"from_left": from_left, "p": 0.0})

func _land(from_left: bool) -> void:
	# Попадание приходится В МАШИНУ-ЦЕЛЬ, вразброс по её габариту: точка ровно в центре читалась
	# бы как лазерный прицел, а не как бой.
	var target: Vector2 = _machine_origin(not from_left)
	_hits.append({"pos": target + Vector2(_rng.randf_range(-26.0, 26.0),
			_rng.randf_range(-30.0, 4.0)), "t": 0.0})

## Где стоит машина. Левая и правая слегка ПОКАЧИВАЮТСЯ и дышат по высоте — неподвижный
## силуэт на движущемся фоне читается как картинка, а не как бой.
func _machine_origin(left: bool) -> Vector2:
	var y: float = size.y * HORIZON
	var side: float = 0.22 if left else 0.78
	var sway: float = sin(_t * (0.7 if left else 0.55) + (0.0 if left else 1.7)) * 10.0
	var kick: float = float(_recoil[0 if left else 1]) * (6.0 if left else -6.0)
	return Vector2(size.x * side + sway + kick, y)

func _draw() -> void:
	_draw_sky()
	_draw_ridges()
	_draw_machine(true)
	_draw_machine(false)
	_draw_shots()
	_draw_hits()

func _draw_sky() -> void:
	# Полосами, а не текстурой: градиент на фоне — единственное место, где она понадобилась бы,
	# а восемнадцать прямоугольников стоят дешевле, чем ресурс, который надо держать и ресайзить.
	var h: float = size.y * HORIZON
	for i in SKY_BANDS:
		var t: float = float(i) / float(SKY_BANDS - 1)
		draw_rect(Rect2(0.0, h * t, size.x, h / float(SKY_BANDS) + 1.0),
				SKY_TOP.lerp(SKY_BOTTOM, t), true)
	draw_rect(Rect2(0.0, h, size.x, size.y - h), RIDGE_NEAR, true)

func _draw_ridges() -> void:
	var cols := [RIDGE_FAR, RIDGE_MID, RIDGE_NEAR]
	var h: float = size.y * HORIZON
	for layer in _ridges.size():
		# ПАРАЛЛАКС: дальний слой ползёт медленнее ближнего, и от этого горизонт кажется
		# глубоким без единого лишнего пикселя.
		var drift: float = fmod(_t * (0.004 + float(layer) * 0.006), 1.0)
		var poly := PackedVector2Array()
		poly.append(Vector2(0.0, h))
		for p in _ridges[layer]:
			var x: float = fposmod(float((p as Vector2).x) - drift, 1.0) * size.x
			poly.append(Vector2(x, h - (p as Vector2).y * size.y))
		poly.append(Vector2(size.x, h))
		# Точки после сдвига идут не по порядку — сортируем по X, иначе полигон схлопывается.
		var body: Array = []
		for i in range(1, poly.size() - 1):
			body.append(poly[i])
		body.sort_custom(func(a, b): return (a as Vector2).x < (b as Vector2).x)
		var final := PackedVector2Array()
		final.append(Vector2(0.0, h))
		for v in body:
			final.append(v)
		final.append(Vector2(size.x, h))
		draw_colored_polygon(final, cols[layer])

## Машина — СЕТКА БЛОКОВ, как в самой игре: корпус, кабина сверху, ствол вперёд, колёса снизу.
## Рисуем прямоугольниками, потому что машина в этой игре из них и состоит.
func _draw_machine(left: bool) -> void:
	var o: Vector2 = _machine_origin(left)
	var s: float = clampf(size.y * 0.032, 9.0, 22.0)      # сторона «клетки» в пикселях
	var dir: float = 1.0 if left else -1.0
	var breathe: float = sin(_t * 1.6 + (0.0 if left else 2.2)) * s * 0.06
	# Клетки в «блочных» координатах: x вперёд, y вверх. Тот же силуэт, что у стартовой машины,
	# — корпус в три клетки, кабина, ствол и четыре колеса.
	var body := [Vector2(-1, 0), Vector2(0, 0), Vector2(1, 0), Vector2(0, 1)]
	var gun := [Vector2(1, 1), Vector2(2, 1)]
	var wheels := [Vector2(-1, -1), Vector2(1, -1)]
	for c in body:
		_cell(o, c, s, dir, breathe, MACHINE)
	for c in gun:
		_cell(o, c, s, dir, breathe, MACHINE_LIT)
	for c in wheels:
		_cell(o, c, s * 0.9, dir, breathe, MACHINE * Color(0.7, 0.7, 0.7, 1.0))

func _cell(o: Vector2, c: Vector2, s: float, dir: float, breathe: float, col: Color) -> void:
	var p := Vector2(o.x + c.x * s * dir, o.y - c.y * s - s * 0.5 + breathe)
	draw_rect(Rect2(p - Vector2(s, s) * 0.5, Vector2(s, s) * 0.94), col, true)

func _draw_shots() -> void:
	for s in _shots:
		var from_left: bool = bool(s["from_left"])
		var a: Vector2 = _machine_origin(from_left) + Vector2((1.0 if from_left else -1.0) * 40.0, -26.0)
		var b: Vector2 = _machine_origin(not from_left) + Vector2(0.0, -18.0)
		var p: float = float(s["p"])
		var head: Vector2 = a.lerp(b, p)
		var tail: Vector2 = a.lerp(b, maxf(p - 0.09, 0.0))
		draw_line(tail, head, TRACER * Color(1, 1, 1, 0.85), 2.0)

## Попадание — КРАСНЫЕ ГЛИТЧ-КАРТОЧКИ, тот же словарь, которым игра говорит про урон и взрыв
## (см. BlockFX). Одинаковый смысл обязан выглядеть одинаково и в меню, и в бою.
func _draw_hits() -> void:
	for h in _hits:
		var t: float = float(h["t"])
		var pos: Vector2 = h["pos"]
		var fade: float = 1.0 - t
		for i in 5:
			var ang: float = float(i) * 1.9 + t * 3.0
			var r: float = 6.0 + t * 26.0 + float(i) * 2.0
			var q: Vector2 = pos + Vector2(cos(ang), sin(ang) * 0.7) * r
			var w: float = 7.0 - float(i) * 0.8
			draw_rect(Rect2(q - Vector2(w, w) * 0.5, Vector2(w, w)),
					(HIT_A if i % 2 == 0 else HIT_B) * Color(1, 1, 1, fade * 0.9), true)
