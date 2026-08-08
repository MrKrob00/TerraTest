class_name BlockBuilder
extends RefCounted

# Сборщик меша блока. Ни узел, ни сцена — просто объект, который строит ArrayMesh вместе
# с его материалом и текстурой. Пользуются им двое:
#   • addons/blockgen — плагин импорта: превращает файл .blockgen в ресурс Mesh, который
#     видно в файловой панели и можно таскать мышкой, как любой другой меш;
#   • block.gd — берёт готовый ассет, а если тот почему-то не импортировался, строит на лету.
#
# ЗЕРКАЛО art/blockgen.py — там тот же генератор на Python, он рисует превью формы без
# запуска Godot. Правишь одно — правь и второе. Намотка треугольников там ОСТАЁТСЯ против
# часовой (конвенция .obj), здесь она перевёрнута: Godot передней гранью считает намотку
# по часовой.
#
# Спецификация стиля:
#   габарит  0.96 в ячейке 1.0 — зазор 0.02 даёт видимый шов между блоками
#   фаска    0.10 на всех рёбрах
#   метка    выпуклая четырёхлучевая звезда по центру КАЖДОЙ грани, лучи по диагоналям
#   нормали  плоские (по грани)
#   тексель  16 пикселей на мировую единицу — совпадает с землёй
#            (PIXELS_PER_TILE = 16.0 в addons/LiteTerrain/glsl.gdshader)

const CELL: int = 16             # тексель-ячейка грани
const ATLAS: int = 32            # атлас 2x2 ячейки
const EDGE_EPS: float = 0.01     # отступ от края ячейки, чтобы nearest не попал в соседнюю

const CELL_SIDE: Vector2i = Vector2i(0, 0)
const CELL_TOP: Vector2i = Vector2i(1, 0)
const CELL_BOTTOM: Vector2i = Vector2i(0, 1)
const CELL_PAD: Vector2i = Vector2i(1, 1)

const KIND_WORLD: int = 0        # UV из мировой позиции — полоса непрерывна через фаски
const KIND_PAD: int = 1          # UV из собственной ячейки метки

# ── Параметры блока (перекрываются из .blockgen) ──────────────────────────────
var half: float = 0.48
var chamfer: float = 0.10
var pad_rise: float = 0.02       # «чуть-чуть» — с меткой блок ровно заполняет ячейку 1.0
var pad_tip: float = 0.165       # радиус луча звезды
var pad_valley: float = 0.075    # радиус впадины: меньше луча, иначе звезда станет квадратом
var band_from: int = 7           # первый ряд светлой полосы (из 16)
var band_to: int = 8             # последний ряд светлой полосы

var col_rim: Color = Color(132.0 / 255.0, 140.0 / 255.0, 165.0 / 255.0)
var col_light: Color = Color(110.0 / 255.0, 118.0 / 255.0, 143.0 / 255.0)
var col_dark: Color = Color(88.0 / 255.0, 95.0 / 255.0, 119.0 / 255.0)
var col_band: Color = Color(226.0 / 255.0, 224.0 / 255.0, 212.0 / 255.0)
var col_pad: Color = Color(146.0 / 255.0, 154.0 / 255.0, 178.0 / 255.0)
var col_mark: Color = Color(96.0 / 255.0, 103.0 / 255.0, 126.0 / 255.0)

var _inner: float = 0.38

func _init(cfg: Dictionary = {}) -> void:
	half = float(cfg.get("half", half))
	chamfer = float(cfg.get("chamfer", chamfer))
	var pad: Dictionary = cfg.get("pad", {})
	pad_rise = float(pad.get("rise", pad_rise))
	pad_tip = float(pad.get("tip", pad_tip))
	pad_valley = float(pad.get("valley", pad_valley))
	var band: Array = cfg.get("band_rows", [band_from, band_to])
	if band.size() == 2:
		band_from = int(band[0])
		band_to = int(band[1])
	var pal: Dictionary = cfg.get("palette", {})
	col_rim = _colour(pal.get("rim"), col_rim)
	col_light = _colour(pal.get("light"), col_light)
	col_dark = _colour(pal.get("dark"), col_dark)
	col_band = _colour(pal.get("band"), col_band)
	col_pad = _colour(pal.get("pad"), col_pad)
	col_mark = _colour(pal.get("mark"), col_mark)
	_inner = half - chamfer

# Цвета в .blockgen пишутся как [r, g, b] в диапазоне 0..255 — так их проще брать из палитры.
static func _colour(value: Variant, fallback: Color) -> Color:
	if value is Array and (value as Array).size() >= 3:
		var a: Array = value
		return Color(float(a[0]) / 255.0, float(a[1]) / 255.0, float(a[2]) / 255.0)
	return fallback

## Прочитать описание блока и собрать меш. Возвращает null, если файл нечитаем.
static func from_file(path: String) -> ArrayMesh:
	if not FileAccess.file_exists(path):
		return null
	var text: String = FileAccess.get_file_as_string(path)
	var parsed: Variant = JSON.parse_string(text)
	if not (parsed is Dictionary):
		return null
	return BlockBuilder.new(parsed).build()

# ══════════════════════════════════════════
# ГЕОМЕТРИЯ
# ══════════════════════════════════════════

# Скошенный куб: 6 площадок + 12 рёбер + 8 углов = 44 треугольника.
func _chamfered_box() -> Array:
	var faces: Array = []

	for axis: int in 3:
		for sgn: int in [-1, 1]:
			var quad: Array = []
			for a in [-_inner, _inner]:
				for b in [-_inner, _inner]:
					var p: Vector3 = Vector3.ZERO
					p[axis] = sgn * half
					p[(axis + 1) % 3] = a
					p[(axis + 2) % 3] = b
					quad.append(p)
			faces.append([quad[0], quad[1], quad[3], quad[2]])

	for i: int in 3:
		for j: int in range(i + 1, 3):
			var k: int = 3 - i - j
			for si: int in [-1, 1]:
				for sj: int in [-1, 1]:
					var quad: Array = []
					for sk: int in [-1, 1]:
						for lead in [i, j]:
							var p: Vector3 = Vector3.ZERO
							p[i] = si * (half if lead == i else _inner)
							p[j] = sj * (half if lead == j else _inner)
							p[k] = sk * _inner
							quad.append(p)
					faces.append([quad[0], quad[1], quad[3], quad[2]])

	for sx: int in [-1, 1]:
		for sy: int in [-1, 1]:
			for sz: int in [-1, 1]:
				var s: Array = [sx, sy, sz]
				var tri: Array = []
				for lead: int in 3:
					var p: Vector3 = Vector3.ZERO
					for a: int in 3:
						p[a] = s[a] * (half if a == lead else _inner)
					tri.append(p)
				faces.append(tri)
	return faces

# Пара осей в плоскости грани: лучи звезды идут по диагоналям квадрата грани.
func _face_axes(axis: int, sgn: int) -> Array:
	var u: Vector3 = Vector3.ZERO
	var v: Vector3 = Vector3.ZERO
	u[(axis + 1) % 3] = 1.0
	v[(axis + 2) % 3] = float(sgn)
	return [u, v]

# Восемь точек контура: вершины лучей на диагоналях, впадины между ними.
func _star_outline() -> Array:
	var pts: Array[Vector2] = []
	for i: int in 8:
		var ang: float = PI / 4.0 + PI / 4.0 * float(i)
		var r: float = pad_tip if i % 2 == 0 else pad_valley
		pts.append(Vector2(cos(ang) * r, sin(ang) * r))
	return pts

# Выпуклая звезда: крышка веером из центра + бортик по контуру.
func _pad_faces(axis: int, sgn: int) -> Array:
	var ax: Array = _face_axes(axis, sgn)
	var u: Vector3 = ax[0]
	var v: Vector3 = ax[1]
	var n: Vector3 = Vector3.ZERO
	n[axis] = float(sgn)

	var outline: Array = _star_outline()
	var faces: Array = []
	var centre: Vector3 = n * (half + pad_rise)
	for i: int in 8:
		var a: Vector2 = outline[i]
		var b: Vector2 = outline[(i + 1) % 8]
		var a_top: Vector3 = u * a.x + v * a.y + n * (half + pad_rise)
		var b_top: Vector3 = u * b.x + v * b.y + n * (half + pad_rise)
		var a_base: Vector3 = u * a.x + v * a.y + n * half
		var b_base: Vector3 = u * b.x + v * b.y + n * half
		faces.append([[centre, a_top, b_top], KIND_PAD])
		faces.append([[a_base, b_base, b_top, a_top], KIND_PAD])
	return faces

func _block_faces() -> Array:
	var faces: Array = []
	for poly in _chamfered_box():
		faces.append([poly, KIND_WORLD])
	for axis: int in 3:
		for sgn: int in [-1, 1]:
			faces.append_array(_pad_faces(axis, sgn))
	return faces

static func _newell(poly: Array) -> Vector3:
	var n: Vector3 = Vector3.ZERO
	var count: int = poly.size()
	for i: int in count:
		var p0: Vector3 = poly[i]
		var p1: Vector3 = poly[(i + 1) % count]
		n.x += (p0.y - p1.y) * (p0.z + p1.z)
		n.y += (p0.z - p1.z) * (p0.x + p1.x)
		n.z += (p0.x - p1.x) * (p0.y + p1.y)
	return n.normalized() if n.length_squared() > 0.0 else Vector3.UP

# Тело выпуклое и центрировано, поэтому наружу = в сторону центроида грани. Обход
# задавать вручную не нужно — порядок чинится сам, ошибиться негде.
static func _orient_outward(poly: Array) -> Array:
	var normal: Vector3 = _newell(poly)
	var centroid: Vector3 = Vector3.ZERO
	for p in poly:
		centroid += p
	centroid /= float(poly.size())
	if normal.dot(centroid) < 0.0:
		poly = poly.duplicate()
		poly.reverse()
		normal = _newell(poly)
	return [poly, normal]

# ══════════════════════════════════════════
# UV
# ══════════════════════════════════════════

# u,v растягиваются на ПОЛНУЮ ширину ячейки, а не на центры крайних текселей. При
# отображении «центр-в-центр» крайним рядам доставалась вдвое меньшая доля u, и ободок
# на грани выходил вдвое тоньше остальных полос.
static func _cell_uv(cell: Vector2i, u: float, v: float) -> Vector2:
	var span: float = float(CELL) - 2.0 * EDGE_EPS
	return Vector2(
		(cell.x * CELL + EDGE_EPS + clampf(u, 0.0, 1.0) * span) / float(ATLAS),
		(cell.y * CELL + EDGE_EPS + clampf(v, 0.0, 1.0) * span) / float(ATLAS))

func _face_uvs(poly: Array, normal: Vector3, kind: int) -> Array:
	var out: Array = []

	if kind == KIND_PAD:
		var axis: int = 0
		for a: int in 3:
			if absf(normal[a]) > absf(normal[axis]):
				axis = a
		var sgn: int = 1 if normal[axis] > 0.0 else -1
		var ax: Array = _face_axes(axis, sgn)
		var au: Vector3 = ax[0]
		var av: Vector3 = ax[1]
		for p in poly:
			var pv: Vector3 = p
			var su: float = pv.dot(au) / (pad_tip * 2.0) + 0.5
			var sv: float = pv.dot(av) / (pad_tip * 2.0) + 0.5
			out.append(_cell_uv(CELL_PAD, su, 1.0 - sv))
		return out

	# UV корпуса считаются из МИРОВОЙ позиции, а не по грани — тогда светлая полоса
	# непрерывно продолжается через фаску на соседнюю грань, а не обрывается на ребре.
	var span: float = 2.0 * half
	if absf(normal.y) > 0.999:
		var cell: Vector2i = CELL_TOP if normal.y > 0.0 else CELL_BOTTOM
		for p in poly:
			var pt: Vector3 = p
			var uu: float = (pt.x + half) / span
			var vv: float = (pt.z + half) / span
			if normal.y < 0.0:
				vv = 1.0 - vv
			out.append(_cell_uv(cell, uu, vv))
		return out

	var horizontal_x: bool = absf(normal.x) >= absf(normal.z)
	for p in poly:
		var pv: Vector3 = p
		var vv: float = (half - pv.y) / span
		var uu: float = 0.0
		if horizontal_x:
			uu = (pv.z + half) / span
			if normal.x > 0.0:
				uu = 1.0 - uu
		else:
			uu = (pv.x + half) / span
			if normal.z < 0.0:
				uu = 1.0 - uu
		out.append(_cell_uv(CELL_SIDE, uu, vv))
	return out

# ══════════════════════════════════════════
# СБОРКА
# ══════════════════════════════════════════

func build() -> ArrayMesh:
	var st: SurfaceTool = SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for entry in _block_faces():
		var oriented: Array = _orient_outward(entry[0])
		var poly: Array = oriented[0]
		var normal: Vector3 = oriented[1]
		var uvs: Array = _face_uvs(poly, normal, entry[1])
		st.set_normal(normal)                    # нормаль по грани — плоская закраска
		for c: int in range(1, poly.size() - 1):
			# Обход задом наперёд: _orient_outward выдаёт грань против часовой (правило
			# Ньюэлла), а Godot передней считает намотку ПО часовой. С прямым порядком
			# все грани отбраковывались как задние — блок просвечивал изнанкой.
			for idx in [0, c + 1, c]:
				st.set_uv(uvs[idx])
				st.add_vertex(poly[idx])
	# Материал кладём В МЕШ, а не на ноду: тогда меш можно назначить любому MeshInstance3D
	# и он приедет уже со своим материалом. С material_override материал оставался у ноды,
	# и голый меш терял и текстуру, и фильтр — отсюда мыло.
	st.set_material(build_material())
	return st.commit()

func atlas_image() -> Image:
	var img: Image = Image.create_empty(ATLAS, ATLAS, false, Image.FORMAT_RGB8)

	for y: int in CELL:
		var side: Color = col_light
		if y == 0:
			side = col_rim
		elif y > band_to:
			side = col_dark
		elif y >= band_from:
			side = col_band
		for x: int in CELL:
			img.set_pixel(CELL_SIDE.x * CELL + x, CELL_SIDE.y * CELL + y, side)

			var top: Color = col_light
			if y == 0 or x == 0:
				top = col_rim
			elif y == CELL - 1 or x == CELL - 1:
				top = col_dark
			img.set_pixel(CELL_TOP.x * CELL + x, CELL_TOP.y * CELL + y, top)

			img.set_pixel(CELL_BOTTOM.x * CELL + x, CELL_BOTTOM.y * CELL + y, col_dark)

			# Форму лучей даёт геометрия; рисовать её ещё и пикселями — получить грязь
			# поверх граней. В текстуре только точка «оси» в центре метки.
			var pad: Color = col_mark if (x >= 7 and x <= 8 and y >= 7 and y <= 8) else col_pad
			img.set_pixel(CELL_PAD.x * CELL + x, CELL_PAD.y * CELL + y, pad)
	return img

func build_material() -> StandardMaterial3D:
	var mat: StandardMaterial3D = StandardMaterial3D.new()
	mat.albedo_texture = ImageTexture.create_from_image(atlas_image())
	# Вот эти две строки и есть ответ на «текстура мыльная»: по умолчанию Godot берёт
	# линейный фильтр с мипами, и 16 текселей растягиваются в градиент. Nearest держит
	# пиксель пикселем, мипы такой мелкой текстуре не нужны — она и так вся в кэше.
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	mat.texture_repeat = false
	mat.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	mat.roughness = 1.0
	return mat
