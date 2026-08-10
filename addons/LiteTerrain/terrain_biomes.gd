@tool
class_name TerrainBiomes
extends Resource

## Единственный источник правды по биомам: форма рельефа (генератор в plugin.gd), маски на
## стороне CPU (map.gd) и цвета в материале берутся отсюда, поэтому цвет биома не может
## разъехаться с его рельефом.
##
## Биом — это МАСКА 0..1 от шума по мировым XZ. Слои накладываются в таком порядке:
##   базовый раскол ПУСТЫНЯ ↔ ЛУГ  →  КАНЬОН поверх  →  ГОРЫ поверх.
## Выключенный слой даёт маску 0 и исчезает и из цвета, и из рельефа.
##
## Добавить СВОЙ биом одними настройками нельзя: цвет каждого слоя расписан в
## glsl.gdshader (vertex(), сборка v_base_col), поэтому новый слой — это правка шейдера
## плюс своя маска здесь.

# ── Базовый раскол суши: ПУСТЫНЯ ↔ ЛУГ ────────────────────────────────────────
@export_group("Desert / Meadow")
## Размер пятна биома в единицах мира. Мельче → на экран влезает несколько биомов.
@export_range(30.0, 1000.0, 1.0) var biome_scale: float = 230.0
## Порог раскола: > 0.5 — больше песка, < 0.5 — больше луга.
@export_range(0.0, 1.0, 0.01) var biome_bias: float = 0.5
## Ширина перехода. Уже → чётче граница, а не «мешанина».
@export_range(0.02, 0.5, 0.01) var biome_blend: float = 0.07
## Растяжка контраста шума до порога: выше → пятна плотнее, границы решительнее.
@export_range(0.5, 4.0, 0.1) var biome_contrast: float = 1.8
@export var color_sand: Color = Color(0.87, 0.74, 0.49)
@export var color_grass: Color = Color(0.33, 0.56, 0.23)
## Высота песчаных гряд, м (только рельеф, генератор).
@export_range(0.0, 40.0, 0.5) var dune_amp: float = 9.0
## Длина волны гряд, м.
@export_range(5.0, 200.0, 1.0) var dune_wavelength: float = 34.0
## Насколько сплющить холмы в пустыне: 0 — стол, 1 — как на лугу.
@export_range(0.0, 1.0, 0.05) var desert_flatten: float = 0.4

# ── КАНЬОН ────────────────────────────────────────────────────────────────────
@export_group("Canyon")
## Выключенный биом не появляется ни в цвете, ни в рельефе.
@export var canyon_enabled: bool = true
@export_range(30.0, 1000.0, 1.0) var canyon_scale: float = 250.0
## Выше порог — реже каньоны.
@export_range(0.0, 1.0, 0.01) var canyon_threshold: float = 0.70
## Уже край — отвеснее внешняя стена.
@export_range(0.02, 0.5, 0.01) var canyon_edge: float = 0.05
@export var color_canyon: Color = Color(0.70, 0.30, 0.15)
## Высота страты-полосы. Должна совпадать с террасой геометрии, иначе цвет «поедет» по стене.
@export_range(2.0, 12.0, 0.5) var canyon_band_height: float = 6.0
## Масштаб вариации высоты мес — крупные бьютты (только рельеф).
@export_range(20.0, 400.0, 1.0) var canyon_butte_scale: float = 110.0

# ── ГОРЫ ──────────────────────────────────────────────────────────────────────
@export_group("Mountains")
@export var mountain_enabled: bool = true
@export_range(30.0, 1500.0, 1.0) var mountain_scale: float = 420.0
@export_range(0.0, 1.0, 0.01) var mountain_threshold: float = 0.72
@export_range(0.02, 0.5, 0.01) var mountain_edge: float = 0.05
## Высота гор, м (только рельеф, генератор).
@export_range(0.0, 300.0, 1.0) var mountain_rise: float = 48.0

# ── Снег и камень ─────────────────────────────────────────────────────────────
# Снег привязан к биому ГОР, а не к высоте: цвет берётся по маске гор.
@export_group("Snow / rock")
@export var color_snow: Color = Color(0.94, 0.96, 1.00)
@export var color_rock: Color = Color(0.40, 0.41, 0.43)
## С какого уклона поверхность становится камнем.
@export_range(0.0, 1.0, 0.01) var rock_threshold: float = 0.7
@export_range(0.0, 0.5, 0.01) var rock_blend: float = 0.15

# ── Трава ─────────────────────────────────────────────────────────────────────
@export_group("Grass")
@export_range(0.0, 1.0, 0.01) var grass_density: float = 0.4
@export_range(0.0, 1.0, 0.01) var grass_height: float = 0.15
## Сколько травы в ПУСТЫНЕ относительно луга. 0 — сухой песок. На камне, в каньоне и в
## горах травы нет всегда.
@export_range(0.0, 0.5, 0.01) var sand_grass: float = 0.0
## < 0.65 — трава чуть темнее земли (мягкая тень у корня, а не светлое пятно).
@export_range(0.4, 1.2, 0.01) var grass_shade: float = 0.62

# ── Маски (та же математика, что в шейдере) ───────────────────────────────────
# Смещения шума у каждого слоя свои — иначе каньоны и горы легли бы одним пятном.
const CANYON_OFFSET := Vector2(101.0, 53.0)
const MOUNTAIN_OFFSET := Vector2(211.0, 77.0)

## 0 — пустыня, 1 — луг. wp — мировые XZ.
func meadow_mask(wp: Vector2, noise: Callable) -> float:
	var n: float = noise.call(wp / biome_scale)
	n = clampf((n - 0.5) * biome_contrast + 0.5, 0.0, 1.0)
	return smoothstep(biome_bias - biome_blend, biome_bias + biome_blend, n)

func canyon_mask(wp: Vector2, noise: Callable) -> float:
	if not canyon_enabled:
		return 0.0
	var n: float = noise.call(wp / canyon_scale + CANYON_OFFSET)
	return smoothstep(canyon_threshold - canyon_edge, canyon_threshold + canyon_edge, n)

func mountain_mask(wp: Vector2, noise: Callable) -> float:
	if not mountain_enabled:
		return 0.0
	var n: float = noise.call(wp / mountain_scale + MOUNTAIN_OFFSET)
	return smoothstep(mountain_threshold - mountain_edge, mountain_threshold + mountain_edge, n)

## Купол горы (не маска, а её «внутренность»): плавно растёт от порога к пику — им генератор
## поднимает рельеф, чтобы склоны остались пологими и проезжаемыми.
func mountain_dome(wp: Vector2, noise: Callable) -> float:
	if not mountain_enabled:
		return 0.0
	var n: float = noise.call(wp / mountain_scale + MOUNTAIN_OFFSET)
	return smoothstep(mountain_threshold - mountain_edge, 0.95, n)

# ── Раздача в шейдер ──────────────────────────────────────────────────────────
## Кладёт ЦВЕТА и параметры травы в uniform-ы материала. Пороги и масштабы шума сюда не идут:
## маски биомов считает CPU (map.gd) и запекает в COLOR вершины — шейдер их только читает,
## поэтому выключённый биом исчезает сам, без флага в шейдере.
func apply_to_material(mat: ShaderMaterial) -> void:
	if mat == null:
		return
	mat.set_shader_parameter("color_sand", color_sand)
	mat.set_shader_parameter("color_grass", color_grass)
	mat.set_shader_parameter("color_canyon", color_canyon)
	mat.set_shader_parameter("canyon_band_h", canyon_band_height)
	mat.set_shader_parameter("color_snow", color_snow)
	mat.set_shader_parameter("color_rock", color_rock)
	mat.set_shader_parameter("rock_threshold", rock_threshold)
	mat.set_shader_parameter("rock_blend", rock_blend)
	mat.set_shader_parameter("grass_density", grass_density)
	mat.set_shader_parameter("grass_height", grass_height)
	mat.set_shader_parameter("sand_grass", sand_grass)
	mat.set_shader_parameter("grass_shade", grass_shade)
