@tool
class_name GeneratedBlock
extends MeshInstance3D

# Блок собирает СЕБЯ: и меш, и текстуру, и материал. Ничего не надо назначать руками и
# нечему сбиться — раньше .obj с .png требовал настройки материала в редакторе, и с
# фильтром по умолчанию (линейный + мипы) пиксельная текстура превращалась в мыло.
# Здесь фильтр задаётся кодом и всегда nearest, а текстура рождается в памяти, поэтому
# настроек импорта у неё просто нет.
#
# ЗЕРКАЛО art/blockgen.py — там тот же генератор на Python, он нужен только чтобы
# отрисовать превью формы без запуска Godot. Правишь одно — правь и второе.
#
# Спецификация стиля:
#   габарит  0.96 в ячейке 1.0 — зазор 0.02 даёт видимый шов между блоками
#   фаска    0.10 на всех рёбрах
#   метка    выпуклая четырёхлучевая звезда по центру КАЖДОЙ грани, лучи по диагоналям
#   нормали  плоские (по грани)
#   тексель  16 пикселей на мировую единицу — совпадает с землёй
#            (PIXELS_PER_TILE = 16.0 в addons/LiteTerrain/glsl.gdshader)

const HALF: float = 0.48
const CHAMFER: float = 0.10
const INNER: float = HALF - CHAMFER

# Метка крепления: выпуклая звезда с лучами по диагоналям грани.
const PAD_RISE: float = 0.02     # «чуть-чуть» — с меткой блок ровно заполняет ячейку 1.0
const PAD_TIP: float = 0.165     # радиус луча
const PAD_VALLEY: float = 0.075  # радиус впадины: меньше луча, иначе звезда вырождается в квадрат

const CELL: int = 16
const ATLAS: int = 32

const CELL_SIDE: Vector2i = Vector2i(0, 0)
const CELL_TOP: Vector2i = Vector2i(1, 0)
const CELL_BOTTOM: Vector2i = Vector2i(0, 1)
const CELL_PAD: Vector2i = Vector2i(1, 1)

const SLATE_RIM: Color = Color(132.0 / 255.0, 140.0 / 255.0, 165.0 / 255.0)
const SLATE_LIGHT: Color = Color(110.0 / 255.0, 118.0 / 255.0, 143.0 / 255.0)
const SLATE_DARK: Color = Color(88.0 / 255.0, 95.0 / 255.0, 119.0 / 255.0)
const CREAM: Color = Color(226.0 / 255.0, 224.0 / 255.0, 212.0 / 255.0)
const PAD_FACE: Color = Color(146.0 / 255.0, 154.0 / 255.0, 178.0 / 255.0)
const PAD_MARK: Color = Color(96.0 / 255.0, 103.0 / 255.0, 126.0 / 255.0)

const KIND_WORLD: int = 0        # UV из мировой позиции — полоса непрерывна через фаски
const KIND_PAD: int = 1          # UV из собственной ячейки метки

# Меш один на все экземпляры: блоков на машине десятки, плодить копии незачем.
static var _shared_mesh: ArrayMesh = null

## Готовый меш с УЖЕ вложенным материалом. Можно звать откуда угодно:
##     mesh_instance.mesh = GeneratedBlock.block_mesh()
## Ни сцены, ни скрипта на ноде для этого не нужно.
static func block_mesh() -> ArrayMesh:
	if _shared_mesh == null:
		_shared_mesh = _build_mesh()
	return _shared_mesh

## Нажми в инспекторе — меш вместе с материалом и текстурой ляжет в файл
## res://objects/gen/armor_block.res. Дальше его можно назначить полю Mesh любого
## MeshInstance3D мышкой: ни сцены-обёртки, ни скрипта на ноде не потребуется.
@export var bake_to_file: bool = false:
	set(value):
		bake_to_file = false                 # это кнопка, а не настройка
		if value and Engine.is_editor_hint():
			_bake_to_file()

const BAKE_PATH: String = "res://objects/gen/armor_block.res"

func _bake_to_file() -> void:
	_shared_mesh = null                      # печём свежий, а не то, что лежало в кеше
	var baked: ArrayMesh = block_mesh()
	DirAccess.make_dir_recursive_absolute(BAKE_PATH.get_base_dir())
	var err: int = ResourceSaver.save(baked, BAKE_PATH)
	if err == OK:
		print("Меш блока сохранён: ", BAKE_PATH)
	else:
		push_error("Не удалось сохранить меш блока (%s), код %d" % [BAKE_PATH, err])

func _ready() -> void:
	if Engine.is_editor_hint():
		_shared_mesh = null                  # в редакторе правки констант видны сразу
	mesh = block_mesh()

# ══════════════════════════════════════════
# ГЕОМЕТРИЯ
# ══════════════════════════════════════════

# Скошенный куб: 6 площадок + 12 рёбер + 8 углов = 44 треугольника.
static func _chamfered_box() -> Array:
	var faces: Array = []

	for axis in 3:
		for sgn in [-1, 1]:
			var quad: Array = []
			for a in [-INNER, INNER]:
				for b in [-INNER, INNER]:
					var p: Vector3 = Vector3.ZERO
					p[axis] = sgn * HALF
					p[(axis + 1) % 3] = a
					p[(axis + 2) % 3] = b
					quad.append(p)
			faces.append([quad[0], quad[1], quad[3], quad[2]])

	for i in 3:
		for j in range(i + 1, 3):
			var k: int = 3 - i - j
			for si in [-1, 1]:
				for sj in [-1, 1]:
					var quad: Array = []
					for sk in [-1, 1]:
						for lead in [i, j]:
							var p: Vector3 = Vector3.ZERO
							p[i] = si * (HALF if lead == i else INNER)
							p[j] = sj * (HALF if lead == j else INNER)
							p[k] = sk * INNER
							quad.append(p)
					faces.append([quad[0], quad[1], quad[3], quad[2]])

	for sx in [-1, 1]:
		for sy in [-1, 1]:
			for sz in [-1, 1]:
				var s: Array = [sx, sy, sz]
				var tri: Array = []
				for lead in 3:
					var p: Vector3 = Vector3.ZERO
					for a in 3:
						p[a] = s[a] * (HALF if a == lead else INNER)
					tri.append(p)
				faces.append(tri)
	return faces

# Пара осей в плоскости грани: лучи звезды идут по диагоналям квадрата грани.
static func _face_axes(axis: int, sgn: int) -> Array:
	var u: Vector3 = Vector3.ZERO
	var v: Vector3 = Vector3.ZERO
	u[(axis + 1) % 3] = 1.0
	v[(axis + 2) % 3] = float(sgn)
	return [u, v]

# Восемь точек контура: вершины лучей на диагоналях, впадины между ними.
static func _star_outline() -> Array:
	var pts: Array = []
	for i in 8:
		var ang: float = PI / 4.0 + PI / 4.0 * float(i)
		var r: float = PAD_TIP if i % 2 == 0 else PAD_VALLEY
		pts.append(Vector2(cos(ang) * r, sin(ang) * r))
	return pts

# Выпуклая звезда: крышка веером из центра + бортик по контуру.
static func _pad_faces(axis: int, sgn: int) -> Array:
	var ax: Array = _face_axes(axis, sgn)
	var u: Vector3 = ax[0]
	var v: Vector3 = ax[1]
	var n: Vector3 = Vector3.ZERO
	n[axis] = float(sgn)

	var outline: Array = _star_outline()
	var faces: Array = []
	var centre: Vector3 = n * (HALF + PAD_RISE)
	for i in 8:
		var a: Vector2 = outline[i]
		var b: Vector2 = outline[(i + 1) % 8]
		var a_top: Vector3 = u * a.x + v * a.y + n * (HALF + PAD_RISE)
		var b_top: Vector3 = u * b.x + v * b.y + n * (HALF + PAD_RISE)
		var a_base: Vector3 = u * a.x + v * a.y + n * HALF
		var b_base: Vector3 = u * b.x + v * b.y + n * HALF
		faces.append([[centre, a_top, b_top], KIND_PAD])
		faces.append([[a_base, b_base, b_top, a_top], KIND_PAD])
	return faces

static func _block_faces() -> Array:
	var faces: Array = []
	for poly in _chamfered_box():
		faces.append([poly, KIND_WORLD])
	for axis in 3:
		for sgn in [-1, 1]:
			faces.append_array(_pad_faces(axis, sgn))
	return faces

static func _newell(poly: Array) -> Vector3:
	var n: Vector3 = Vector3.ZERO
	var count: int = poly.size()
	for i in count:
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

# Выборка в ЦЕНТР текселя: край ячейки при nearest ушёл бы в соседнюю.
static func _cell_uv(cell: Vector2i, u: float, v: float) -> Vector2:
	return Vector2(
		(cell.x * CELL + 0.5 + clampf(u, 0.0, 1.0) * (CELL - 1)) / float(ATLAS),
		(cell.y * CELL + 0.5 + clampf(v, 0.0, 1.0) * (CELL - 1)) / float(ATLAS))

static func _face_uvs(poly: Array, normal: Vector3, kind: int) -> Array:
	var out: Array = []

	if kind == KIND_PAD:
		var axis: int = 0
		for a in 3:
			if absf(normal[a]) > absf(normal[axis]):
				axis = a
		var sgn: int = 1 if normal[axis] > 0.0 else -1
		var ax: Array = _face_axes(axis, sgn)
		var au: Vector3 = ax[0]
		var av: Vector3 = ax[1]
		for p in poly:
			var pv: Vector3 = p
			var su: float = pv.dot(au) / (PAD_TIP * 2.0) + 0.5
			var sv: float = pv.dot(av) / (PAD_TIP * 2.0) + 0.5
			out.append(_cell_uv(CELL_PAD, su, 1.0 - sv))
		return out

	# UV корпуса считаются из МИРОВОЙ позиции, а не по грани — тогда светлая полоса
	# непрерывно продолжается через фаску на соседнюю грань, а не обрывается на ребре.
	var span: float = 2.0 * HALF
	if absf(normal.y) > 0.999:
		var cell: Vector2i = CELL_TOP if normal.y > 0.0 else CELL_BOTTOM
		for p in poly:
			var pt: Vector3 = p
			var uu: float = (pt.x + HALF) / span
			var vv: float = (pt.z + HALF) / span
			if normal.y < 0.0:
				vv = 1.0 - vv
			out.append(_cell_uv(cell, uu, vv))
		return out

	var horizontal_x: bool = absf(normal.x) >= absf(normal.z)
	for p in poly:
		var pv: Vector3 = p
		var vv: float = (HALF - pv.y) / span
		var uu: float = 0.0
		if horizontal_x:
			uu = (pv.z + HALF) / span
			if normal.x > 0.0:
				uu = 1.0 - uu
		else:
			uu = (pv.x + HALF) / span
			if normal.z < 0.0:
				uu = 1.0 - uu
		out.append(_cell_uv(CELL_SIDE, uu, vv))
	return out

# ══════════════════════════════════════════
# СБОРКА
# ══════════════════════════════════════════

static func _build_mesh() -> ArrayMesh:
	var st: SurfaceTool = SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for entry in _block_faces():
		var oriented: Array = _orient_outward(entry[0])
		var poly: Array = oriented[0]
		var normal: Vector3 = oriented[1]
		var uvs: Array = _face_uvs(poly, normal, entry[1])
		st.set_normal(normal)                    # нормаль по грани — плоская закраска
		for c in range(1, poly.size() - 1):
			# Обход задом наперёд: _orient_outward выдаёт грань против часовой (правило
			# Ньюэлла), а Godot передней считает намотку ПО часовой. С прямым порядком
			# все грани отбраковывались как задние — блок просвечивал изнанкой.
			for idx in [0, c + 1, c]:
				st.set_uv(uvs[idx])
				st.add_vertex(poly[idx])
	# Материал кладём В МЕШ, а не на ноду: тогда меш можно назначить любому
	# MeshInstance3D и он приедет уже со своим материалом. С material_override
	# материал оставался у ноды, и голый меш терял и текстуру, и фильтр — отсюда мыло.
	st.set_material(_build_material())
	return st.commit()

static func _atlas_image() -> Image:
	var img: Image = Image.create_empty(ATLAS, ATLAS, false, Image.FORMAT_RGB8)

	for y in CELL:
		var side: Color = SLATE_LIGHT
		if y == 0:
			side = SLATE_RIM
		elif y > 8:
			side = SLATE_DARK
		elif y > 6:
			side = CREAM             # ровно по середине грани (ряды 7-8 из 16)
		for x in CELL:
			img.set_pixel(CELL_SIDE.x * CELL + x, CELL_SIDE.y * CELL + y, side)

			var top: Color = SLATE_LIGHT
			if y == 0 or x == 0:
				top = SLATE_RIM
			elif y == CELL - 1 or x == CELL - 1:
				top = SLATE_DARK
			img.set_pixel(CELL_TOP.x * CELL + x, CELL_TOP.y * CELL + y, top)

			img.set_pixel(CELL_BOTTOM.x * CELL + x, CELL_BOTTOM.y * CELL + y, SLATE_DARK)

			# Форму лучей даёт геометрия; рисовать её ещё и пикселями — получить грязь
			# поверх граней. В текстуре только точка «оси» в центре метки.
			var pad: Color = PAD_MARK if (x >= 7 and x <= 8 and y >= 7 and y <= 8) else PAD_FACE
			img.set_pixel(CELL_PAD.x * CELL + x, CELL_PAD.y * CELL + y, pad)
	return img

static func _build_material() -> StandardMaterial3D:
	var mat: StandardMaterial3D = StandardMaterial3D.new()
	mat.albedo_texture = ImageTexture.create_from_image(_atlas_image())
	# Вот эти две строки и есть ответ на «текстура мыльная»: по умолчанию Godot берёт
	# линейный фильтр с мипами, и 16 текселей растягиваются в градиент. Nearest держит
	# пиксель пикселем, мипы такой мелкой текстуре не нужны — она и так вся в кэше.
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	mat.texture_repeat = false
	mat.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	mat.roughness = 1.0
	return mat
