@tool
class_name LiteTerrainGen
extends Node
## ГЕНЕРАТОР РЕЛЬЕФА. ОТВЕЧАЕТ ПО ТОЧКЕ И БОЛЬШЕ НИКАК.
##
## `height_at(wx, wz)` — шум, размытие и врез каньона в одной мировой точке; `sample_grid` набирает
## из неё сетку. Всё. Прохода по массиву высот на весь мир здесь больше нет: он существовал ради
## ЗАПЕЧЁННОЙ карты (потоковые проходы по строкам, буферы на всю карту, план стадий с процентами,
## отмена на полпути), а запечённых карт в проекте не осталось — и мир, и фон меню считает
## чанковая земля, а она спрашивает свои вершины чанк за чанком.
##
## Здесь только СЧЁТ. Ни одного обращения к сцене или к файлам: параметры кладутся полями.
## NOTHING TO CANCEL: the terrain waits for its running group before it frees the generator
## (`ChunkTerrain.stop_generation`), so no task outlives it - the flag that used to stop a pass
## halfway belonged to the baked map's row passes.

# ── Run parameters (apply_params fills them) ────────────────────────────────
var gen_seed: int = 0
var gen_scale: float = 260.0
var gen_power: float = 3.0
var gen_amplitude: float = 90.0
var gen_canyon_enable: bool = true
var gen_canyon_riser: float = DEF_CANYON_RISER
var gen_canyon_gorge: float = DEF_CANYON_GORGE
var gen_canyon_width: float = DEF_CANYON_WIDTH
## Derived from "mountains" by apply_params.
var mtn_amount: float = 0.8
var ridge_sharp: float = 2.5

# THE HEIGHT DEPENDS ON THE WORLD POINT AND NOTHING ELSE: every noise is read at (wx, wz) as given.
# The baked maps read it by the cell's INDEX in their array (plus an offset), so the same metre came
# out differently on maps of different sizes and two pieces computed at different offsets did not meet.

# Умолчания прогона: то, чем apply_params заполняет пропуски в переданном словаре, и основа
# натурального пресета. Одна копия на всех — вторая означала бы, что мир игры и фон меню стоят
# на разных числах.
const DEF_SCALE := 150.0
const DEF_POWER := 2.6
const DEF_AMPLITUDE := 30.0
const DEF_MOUNTAINS := 0.6
const DEF_CANYON := true
const DEF_CANYON_RISER := 0.35
## THE TWO NUMBERS ARE NOT INTERCHANGEABLE. `width` is the SHARE of noise values that counts as
## floor, so raising it eats the mesas; `gorge` is the wavelength of the channel network, so it
## scales floors and mesas together and leaves the composition alone. Measured on the generator
## (floor cross-width through random floor points in canyon cores, 500 points):
##   0.27 / 120 — median 17.0 m, p90 35.0 m, floor 37% of the canyon
##   0.36 / 120 — median 23.5 m, p90 46.5 m, floor 48%   (mesas shrink)
##   0.27 / 180 — median 27.0 m, p90 51.5 m, floor 37%   (the same land, bigger)
## So "wider canyons" is `gorge`. Before 0.27 / 120 it was 0.18 / 90, a floor of a couple of metres.
const DEF_CANYON_GORGE := 180.0
const DEF_CANYON_WIDTH := 0.27

static func default_params() -> Dictionary:
	return {"scale": DEF_SCALE, "power": DEF_POWER, "amplitude": DEF_AMPLITUDE,
			"mountains": DEF_MOUNTAINS, "canyon": DEF_CANYON, "riser": DEF_CANYON_RISER,
			"gorge": DEF_CANYON_GORGE, "width": DEF_CANYON_WIDTH}

## THE DOCK'S "NATURAL PRESET" AS DATA. The button in the editor and the game both call this, so a
## map generated at runtime is the same land the editor makes - two copies of these four numbers is
## a visible difference in landscape, not a style question.
##
## Height and feature size are LINKED: 130 m of relief over 420 m masses is a slope a machine drives
## up; the same height over 150 m features is a pincushion. `scale` comes from the biome
## `mountain_scale` - terrain bigger than the masks puts the snow cap beside the mountain instead of
## on it. Canyon knobs stay at their defaults: the preset is about the shape of the land.
const NAT_AMPLITUDE := 130.0
const NAT_POWER := 2.8
const NAT_MOUNTAINS := 0.65

static func natural_params(biomes: TerrainBiomes = null) -> Dictionary:
	var b: TerrainBiomes = biomes if biomes != null else TerrainBiomes.new()
	var p := default_params()
	p["amplitude"] = NAT_AMPLITUDE
	p["power"] = NAT_POWER
	p["mountains"] = NAT_MOUNTAINS
	p["scale"] = b.mountain_scale
	return p

## One door for the world and the menu. "mountains" becomes two derived numbers.
func apply_params(p: Dictionary) -> void:
	gen_scale = float(p.get("scale", DEF_SCALE))
	gen_power = float(p.get("power", DEF_POWER))
	gen_amplitude = float(p.get("amplitude", DEF_AMPLITUDE))
	gen_canyon_enable = p.get("canyon", DEF_CANYON) == true
	gen_canyon_riser = float(p.get("riser", DEF_CANYON_RISER))
	gen_canyon_gorge = float(p.get("gorge", DEF_CANYON_GORGE))
	gen_canyon_width = float(p.get("width", DEF_CANYON_WIDTH))
	var m: float = float(p.get("mountains", DEF_MOUNTAINS))
	mtn_amount = lerpf(0.25, 1.1, m)
	ridge_sharp = lerpf(1.6, 3.6, m)

# ── Биомы прогона (снимок; потоки его только читают) ─────────────────────────
var _gen_biomes: TerrainBiomes = null

## A number with one sensible answer: more is high-frequency noise, fewer blurred blobs. (The blur
## itself is the five taps in height_at - one pass kills noise spikes, a second starts eating land.)
const GEN_OCTAVES := 6

## ВСЁ, ЧТО ВЫВОДИТСЯ ИЗ ПАРАМЕТРОВ, считается ОДИН РАЗ в prepare_sampling — до того, как за
## высоты возьмутся потоки: метры (они берутся от Height) и то, что когда-то стояло на
## собственных ползунках. Задачи эти поля только читают.
var _gen_mtn_rise: float = 48.0
var _gen_dune_amp: float = 6.0
## Глубина ущелья ниже местной земли (метры, от Height). Раньше поле значило «высота меса» —
## пока верх меса задавался абсолютом; теперь абсолютов в каньоне нет вовсе.
var _gen_gorge_depth: float = 40.0
var _gen_floor: float = 6.0
var _gen_mtn_amount: float = 0.8
var _gen_ridge_sharp: float = 2.5

# ── Шумы прогона ─────────────────────────────────────────────────────────────
# Собираются один раз (prepare_sampling) на главном потоке; дальше их ТОЛЬКО ЧИТАЮТ — из задач
# WorkerThreadPool, по одной на чанк. Ни одна из них шумы не меняет, поэтому делить их на всех
# безопасно и копировать нечего.
var _gen_base: FastNoiseLite
var _gen_ridge: FastNoiseLite
var _gen_dune: FastNoiseLite
var _gen_gorge: FastNoiseLite
var _gen_ramp: FastNoiseLite

func raw_height_at(wx: float, wz: float) -> float:
	var base = (_gen_base.get_noise_2d(wx, wz) + 1.0) * 0.5
	var continental:float = pow(base, gen_power)
	var ridge = pow(1.0 - abs(_gen_ridge.get_noise_2d(wx, wz)), _gen_ridge_sharp)
	var mountain_mask = smoothstep(0.52, 0.78, continental)
	var ridge_term = ridge * _gen_mtn_amount * mountain_mask
	var wp := Vector2(wx, wz)
	var b := _gen_biomes
	# КАНЬОН БОЛЬШЕ НИЧЕГО НЕ ГАСИТ, и это следствие смены его модели. Пока он ЗАМЕЩАЛ высоту
	# своими абсолютными террасами, поднимать под ним горный купол и рисовать дюны было
	# работой на выброс, и её глушили множителем (1 − маска). Но глушение — это ступень
	# ровно такой высоты, какую оно снимает: подъём гор — 0.75 высоты карты, то есть под
	# краем каньонной маски в горах открывалась яма почти в сто метров. «В горах иногда
	# резкие углубления, в которых можно застрять» — это она.
	#
	# Теперь каньон РЕЖЕТ уже готовую землю (см. carve_at): что бы здесь ни подняли,
	# врез считается от этого же уровня. Гасить нечего, и ступеней от гашения нет.
	var sand_m := 1.0 - b.meadow_mask(wp, _cv_noise)
	var mtn_mask := b.mountain_mask(wp, _cv_noise)
	var mtn_dome := b.mountain_dome(wp, _cv_noise)
	var not_mtn := 1.0 - mtn_mask
	var land_sand := sand_m * not_mtn
	var cont_biome := continental * lerpf(1.0, b.desert_flatten, land_sand)
	var h = cont_biome + ridge_term * not_mtn
	var duneph := wx / b.dune_wavelength + _gen_dune.get_noise_2d(wx, wz) * 3.5
	var dune := pow(0.5 + 0.5 * sin(duneph), 1.4) * _gen_dune_amp * land_sand
	var mtn_rise := mtn_dome * _gen_mtn_rise + _gen_dune.get_noise_2d(wx * 1.7, wz * 1.7) * 4.0 * mtn_mask
	var land: float = h * gen_amplitude + dune + mtn_rise
	# THE SALT FLAT: the land eases down to a lake bed built from the SAME base noise read at a
	# twentieth of its frequency - so it sits where the desert around it sits, and stays near flat
	# across the whole patch. The mask's wide edge is the shore: a slope, not a step. No dunes,
	# no ridges on it.
	var salt: float = b.salt_raw(wp, _cv_noise) * land_sand     # = salt_mask, from the masks in hand
	if salt > 0.0:
		var lo: float = (_gen_base.get_noise_2d(wx * 0.05, wz * 0.05) + 1.0) * 0.5
		var bed: float = pow(lo, gen_power) * b.desert_flatten * gen_amplitude
		land = lerpf(land, bed, smoothstep(0.0, 1.0, salt))
	return land

## РОВНАЯ ЗЕМЛЯ ОДНИМ ФЛАГОМ. Нужна испытательному полигону: там измеряют машину, а не рельеф,
## и любой холм под колесом — это лишняя переменная в замере. Флаг стоит ЗДЕСЬ, на генераторе,
## потому что высоты уходят наружу двумя путями — `height_at` для запроса высоты и `sample_grid`
## для мешей с коллизией, — и ровно их обоих надо закоротить. Всё остальное (чанки, LOD, очередь
## коллизии, стрижка травы) работает как в игре, а значит полигон и проверяет игру, а не макет.
##
## Заодно это самая быстрая земля, какая тут бывает: `height_at` стоит 124 мкс, а здесь — ноль.
var flat: bool = false
var flat_y: float = 0.0

## begin_sampling must be behind (it is, for the terrain's `_gen`): a lazy prepare in here could not
## work anyway - it needs the biomes - and two threads would run it at once.
func height_at(wx: float, wz: float) -> float:
	if flat:
		return flat_y
	var h: float = (raw_height_at(wx, wz)
			+ raw_height_at(wx - 1.0, wz) + raw_height_at(wx + 1.0, wz)
			+ raw_height_at(wx, wz - 1.0) + raw_height_at(wx, wz + 1.0)) * 0.2
	if gen_canyon_enable and _gen_biomes != null and _gen_biomes.canyon_enabled:
		h = carve_at(wx, wz, h)
	return h

## ГЕНЕРАТОР ГОТОВ ОТВЕЧАТЬ ПО ТОЧКАМ, без прохода по массиву. Зовёт тот, кто считает землю
## чанками: шумы собираются один раз на главном потоке, дальше их только читают.
func begin_sampling(b: TerrainBiomes) -> void:
	_gen_biomes = b
	prepare_sampling()

## СЕТКА n×n ОТ МИРОВОЙ ТОЧКИ С ШАГОМ step. step = 1 — чанк, step = 2ⁿ — слияние 2ⁿ×2ⁿ чанков
## в один меш того же размера. Считается синхронно: зовётся из задачи WorkerThreadPool, по одной
## на чанк, и begin_sampling обязан быть позади.
func sample_grid(ox: float, oz: float, n: int, step: float) -> PackedFloat32Array:
	if flat:
		var f := PackedFloat32Array()
		f.resize(n * n)
		f.fill(flat_y)
		return f
	if step == 1.0:
		return _sample_unit(ox, oz, n)
	var out := PackedFloat32Array()
	out.resize(n * n)
	for j in n:
		var wz := oz + float(j) * step
		var row := j * n
		for i in n:
			out[row + i] = height_at(ox + float(i) * step, wz)
	return out

## ТО ЖЕ, НО С ШАГОМ 1 И БЕЗ ПОВТОРНОГО СЧЁТА ШУМА. Размытие берёт пять отсчётов вокруг вершины,
## а на сетке с шагом 1 эти отсчёты — соседние вершины: сырых высот хватает (n+2)² вместо 5n².
## Вчетверо меньше работы на чанк при том же ответе до бита, и это ровно те чанки, по которым
## игрок ездит и на которых стоит загрузка.
##
## Для грубых уровней так нельзя: там шаг больше метра, а размытие всё равно считается по
## соседям В МЕТРЕ — иначе поле было бы другим и на стыке с мелким уровнем встала бы ступень.
func _sample_unit(ox: float, oz: float, n: int) -> PackedFloat32Array:
	var m: int = n + 2
	var raw := PackedFloat32Array()
	raw.resize(m * m)
	for j in m:
		var wz := oz + float(j - 1)
		var row := j * m
		for i in m:
			raw[row + i] = raw_height_at(ox + float(i - 1), wz)
	var carve: bool = gen_canyon_enable and _gen_biomes != null and _gen_biomes.canyon_enabled
	var out := PackedFloat32Array()
	out.resize(n * n)
	for j in n:
		var c: int = (j + 1) * m
		var u: int = j * m
		var d: int = (j + 2) * m
		var wz := oz + float(j)
		for i in n:
			var h: float = (raw[c + i + 1] + raw[c + i] + raw[c + i + 2]
					+ raw[u + i + 1] + raw[d + i + 1]) * 0.2
			if carve:
				h = carve_at(ox + float(i), wz, h)
			out[j * n + i] = h
	return out

## ВРЕЗ КАНЬОНА В ОДНОЙ ТОЧКЕ. surface — уже размытая земля в ней же. height_at and the step-1 grid
## (`_sample_unit`) both call it: one copy of the formula.
func carve_at(wx: float, wz: float, surface: float) -> float:
	var b := _gen_biomes
	if b == null:
		return surface
	var terr: float = maxf(b.canyon_band_height, 0.5)
	var wp := Vector2(wx, wz)
	# One call, the SAME mask the shader colours with. A second copy of the formula lived here
	# and missed `mask_offset`, so the cut landed where the canyon was not painted.
	var hmask: float = b.canyon_mask(wp, _cv_noise)
	if hmask <= 0.001:
		return surface
	# Mountain wins over canyon (shader order: desert/meadow -> canyon -> mountains on top).
	# Damp the CUT by the mountain mask, never the mountain RISE by the canyon one: damping a
	# rise leaves a step as tall as what it removed (0.75 of map height), while the cut is 0.3
	# and fades out with hmask by itself.
	hmask *= 1.0 - b.mountain_mask(wp, _cv_noise)
	# ...and the salt flat over the canyon, the same way: a gorge through a lake bed is neither
	hmask *= 1.0 - b.salt_mask(wp, _cv_noise)
	if hmask <= 0.001:
		return surface
	# mask_offset here too, or the butte hierarchy repeats on every seed.
	var bt := _cv_noise(wp / b.canyon_butte_scale + Vector2(300.0, 300.0) + b.mask_offset)
	# MESA LAND CUT BY GORGES, not a pit and not a slab. The top is the LOCAL surface, and that
	# is what keeps the region border from being a cliff: up there canyon_h equals surface, so
	# the hmask blend moves nothing. Gorges are a minority of the area, and steps belong on the
	# wall only - quantise anywhere else and the flat floor gets terraces you cannot drive over.

	var gv := absf(_gen_gorge.get_noise_2d(wx, wz))
	var ramp := smoothstep(0.5, 0.75, (_gen_ramp.get_noise_2d(wx, wz) + 1.0) * 0.5)
	# |fbm| near zero runs along branching lines - those are the channels. Below gen_canyon_width
	# is floor, above is wall; ramp stretches the wall into a way in.
	var wall_lo: float = gen_canyon_width * 0.55
	# Steep, not razor thin: on a 0.02 band a 40 m drop fits in a metre and a half, which reads
	# as a hole in the mesh and stripes the texture (world-XZ UVs degenerate on a sheer face).
	var wall_hi: float = wall_lo + lerpf(0.05, 0.14, ramp)
	var wall_t := smoothstep(wall_lo, wall_hi, gv)
	# Depth follows HOW FAR under the threshold: full depth only in the channel core. Flat
	# "anything below the threshold" turned a two-metre dip into a well.
	var deep_k: float = smoothstep(wall_lo, wall_lo * 0.35, gv)
	var floor_h: float = minf(maxf(surface - _gen_gorge_depth * deep_k, _gen_floor), surface)
	var mesa_top: float = surface + _gen_floor * bt
	# TERRACE THE RISE, NOT THE HEIGHT: quantising height itself also steps the flat floor and
	# the mesa top. Step height stays ~terr, so the shader's height colour bands still line up.
	var span: float = maxf(mesa_top - floor_h, 0.0)
	var steps: float = maxf(1.0, floor(span / terr))
	var t: float = wall_t * steps
	var ti: float = floor(t)
	var riser: float = smoothstep(1.0 - lerpf(gen_canyon_riser, 0.02, ramp), 1.0, t - ti)
	var canyon_h: float = floor_h + (ti + riser) * (span / steps)
	return lerpf(surface, canyon_h, hmask)

func _cv_noise(p: Vector2) -> float:
	return TerrainBiomes.cv_noise(p)

func prepare_sampling() -> void:
	var gorge_noise := FastNoiseLite.new()
	gorge_noise.seed          = gen_seed + 91
	gorge_noise.noise_type    = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	gorge_noise.fractal_type  = FastNoiseLite.FRACTAL_FBM
	gorge_noise.fractal_octaves = 3
	gorge_noise.frequency     = 1.0 / maxf(gen_canyon_gorge, 1.0)
	# Where the ramp value is high the wall is gentle (a way down); elsewhere it is sheer.
	var ramp_noise := FastNoiseLite.new()
	ramp_noise.seed        = gen_seed + 143
	ramp_noise.noise_type  = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	ramp_noise.frequency   = 1.0 / 55.0
	_gen_gorge = gorge_noise
	_gen_ramp = ramp_noise
	# ── Layer 1: Continental FBM ─────────────────
	# Low-frequency simplex FBM defines the overall land masses.
	# After remapping to [0,1], we raise to gen_power (e.g. ^4):
	# values below 0.5 collapse toward 0 (flat plains),
	# while values above 0.7 stay high (mountain bases).
	var base_noise = FastNoiseLite.new()
	base_noise.seed             = gen_seed
	base_noise.noise_type       = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	base_noise.fractal_type     = FastNoiseLite.FRACTAL_FBM
	base_noise.fractal_octaves  = GEN_OCTAVES
	base_noise.frequency        = 1.0 / gen_scale
	base_noise.fractal_lacunarity = 2.0
	base_noise.fractal_gain     = 0.42   # softer high frequencies: rolling plains, not ripples

	# ── Layer 2: Ridge noise ─────────────────────
	# A separate FBM sampled at slightly higher frequency.
	# Formula:  ridge = (1 - |n|) ^ sharpness
	# This creates a network of sharp crests wherever the raw
	# noise crosses zero.  We then mask it by the continental
	# elevation so ridges only form on already-high terrain.
	var ridge_noise = FastNoiseLite.new()
	ridge_noise.seed              = gen_seed + 17
	ridge_noise.noise_type        = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	ridge_noise.fractal_type      = FastNoiseLite.FRACTAL_FBM
	ridge_noise.fractal_octaves   = GEN_OCTAVES - 1
	ridge_noise.frequency         = 1.0 / (gen_scale * 0.55)
	ridge_noise.fractal_lacunarity = 2.2
	ridge_noise.fractal_gain      = 0.45

	# Dunes: a low-frequency warp of the ridge direction, so they are not perfectly straight.
	var dune_noise := FastNoiseLite.new()
	dune_noise.seed        = gen_seed + 211
	dune_noise.noise_type  = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	dune_noise.frequency   = 1.0 / 140.0

	# The noises are FIELDS, and the chunk threads only read them. The biomes come from the caller
	# (begin_sampling): the generator knows nothing of the scene.
	# THE SEED MOVES THE BIOMES TOO. Their masks are built on hash noise with fixed offsets, so a
	# new seed used to give new hills IN THE SAME desert with the canyon in the same corner: the
	# world changed shape but not geography. The offset is stored in the RESOURCE — the shader
	# paints from it and the game lays out its ore veins from it, so they cannot drift apart from
	# the generator.
	_gen_biomes.mask_offset = TerrainBiomes.offset_for_seed(gen_seed)
	# EVERYTHING DERIVED IN ONE PLACE, BEFORE THE FIRST PASS. Threads come next, and they only
	# read these fields.
	_gen_mtn_amount = mtn_amount
	_gen_ridge_sharp = ridge_sharp
	# METRES ALWAYS COME FROM HEIGHT. As sliders of their own they broke silently on any move of
	# the height: mountains became a bump under snow, the canyon a ditch or a chasm, snow flooded
	# the whole map. The fractions are picked so a mountain stands well above the hills around it,
	# the canyon floor sits close to the ground, and snow starts nearer the summits.
	_gen_mtn_rise = gen_amplitude * 0.75
	_gen_dune_amp = clampf(gen_amplitude * 0.05, 1.0, 14.0)
	# Треть высоты карты: ущелье должно быть заметным, но по его стенке ещё можно спуститься по
	# террасам, а на 0.42 это была пропасть, вокруг которой оставалось только ездить.
	_gen_gorge_depth = gen_amplitude * 0.30
	_gen_floor = gen_amplitude * 0.06
	# THE SNOW LINE IS NOT WRITTEN HERE ANY MORE, and nothing else of the caller's is either. It
	# used to be set as metres on the biome resource, which is an INPUT: the run overwrote a field
	# the author could edit, dirtied the scene the resource is saved in, and left a number that only
	# matched the Height of whichever run touched it last. The resource now holds the SHARE and the
	# terrain multiplies it by the Height of the world it is showing (TerrainBiomes.apply_to_material).
	_gen_base = base_noise
	_gen_ridge = ridge_noise
	_gen_dune = dune_noise
