@tool
class_name LiteTerrainGen
extends Node
## ГЕНЕРАТОР РЕЛЬЕФА — отдельный класс, а не часть плагина.
##
## Раньше все проходы (шум, размытие, каньоны) жили прямо в `plugin.gd`, а он —
## `@tool extends EditorPlugin`. Редакторные классы в собранной игре ВЫРЕЗАНЫ: файл в сборку
## попадал (addons экспортируются целиком), а загрузиться не мог. То есть генерация физически
## существовала и была недоступна ровно там, где она и нужна, — в игре.
##
## Здесь только СЧЁТ. Ни одного обращения к доку, к выбранной ноде или к файлам: параметры
## кладутся полями, прогресс уходит в `on_progress`, «стоп» спрашивается через `stop()`. Плагин
## остался тонким вызывающим и по-прежнему владеет своим окном и записью файлов; игра позовёт
## тот же `generate()` и запишет свои.
##
## Node, а не RefCounted: проходы отдают кадры через `await get_tree().process_frame` — иначе
## редактор не перерисовывается и генерация неотличима от зависания.

# ── Параметры прогона ────────────────────────────────────────────────────────
# Имена те же, что у ручек дока, и это НАМЕРЕННО: тела проходов переехали сюда байт в байт,
# и переименование полей означало бы правку в каждой строке — то есть ровно тот способ
# внести опечатку, которого при переносе кода надо избегать больше всего.
var gen_seed: int = 0
var gen_scale: float = 260.0
var gen_power: float = 3.0
var gen_amplitude: float = 90.0
var gen_canyon_enable: bool = true
var gen_canyon_riser: float = 0.35
var gen_canyon_gorge: float = 90.0
var gen_canyon_width: float = 0.18
## Готовые производные, которые док считает из своих ручек (см. plugin._mtn_amount/_ridge_sharp).
var mtn_amount: float = 0.8
var ridge_sharp: float = 2.5

# ── МИРОВЫЕ КООРДИНАТЫ ───────────────────────────────────────────────────────
# Высота обязана зависеть ТОЛЬКО от мировой точки, и ни от чего больше. Раньше базовый шум брался
# по ИНДЕКСУ клетки в массиве (fx, fz), то есть один и тот же мировой метр на карте 1982² и 4096²
# давал разный рельеф, а кусок, посчитанный со смещением, не сходился с соседним по шву. Для
# скользящего окна это смертельно: окно как раз и считает куски по разным смещениям.
#
# origin_* — мировая клетка, которой соответствует локальный (0,0) считаемого куска.
var origin_x: int = 0
var origin_z: int = 0
## СДВИГ ШУМА, в мировых клетках. Нужен, чтобы ВОСПРОИЗВЕСТИ старую карту байт в байт: для неё
## шум брался по индексу, то есть ровно по мировой координате плюс половина размера карты.
## generate() ставит его сам; порегионному вызову он не нужен и остаётся нулём.
var noise_offset := Vector2.ZERO

## Куда сообщать о ходе работ: on_progress.call(step: String, frac: float). Пусто — молча.
var on_progress: Callable = Callable()
## Есть ли у вызывающего СВОЯ последняя стадия (запись файлов, пересборка превью). План строит
## generate() — только он знает, сколько проходов реально запустится, — а долю под эту стадию
## вызывающий забирает потом через next_slice(). Без флага она не попала бы в план вовсе, и
## полоса добежала бы до конца раньше самой долгой части прогона.
var plan_bake: bool = false

## Доля шкалы под следующий проход плана. Публично ради той самой последней стадии.
func next_slice() -> Vector2:
	return _plan_slice()

## Прогресс идёт в ЭТУ функцию, а не прямо в окно плагина: генератор про интерфейс ничего не
## знает и знать не должен — его зовёт и редактор, и игра, а окна у них разные.
func _report(step: String, frac: float) -> void:
	if on_progress.is_valid():
		on_progress.call(step, frac)

## Остановить прогон. Уже запущенную групповую задачу отменить нельзя, поэтому «стоп» работает
## наоборот: каждая оставшаяся строка выходит сразу (см. _gen_drop_row), проход дотикивает за
## миллисекунды, а прогон останавливается МЕЖДУ проходами и ничего не отдаёт.
func stop() -> void:
	_gen_cancel = true

func cancelled() -> bool:
	return _gen_cancel


# ── Биомы прогона (снимок; потоки его только читают) ─────────────────────────
var _gen_biomes: TerrainBiomes = null

## Numbers with one sensible answer. They do not deserve a knob; they do deserve an explanation.
const GEN_OCTAVES := 6        # more = high-frequency noise, fewer = blurred blobs
const GEN_SMOOTH_PASSES := 1  # one pass kills noise spikes; a second one starts eating terrain

# ── Threaded generation (WorkerThreadPool) ────────────────────────────────────
# The two heavy noise loops (filling the heights and carving the canyons) parallelise per row,
# because rows are independent. Each thread writes only ITS OWN array indices (refcount = 1, so
# no copy-on-write races) and reads the noise objects without mutating them. The state those
# threaded callables need lives in the fields below.
var _gen_w: int = 0
var _gen_d: int = 0
var _gen_base: FastNoiseLite
var _gen_ridge: FastNoiseLite
var _gen_dune: FastNoiseLite
var _gen_gorge: FastNoiseLite
var _gen_ramp: FastNoiseLite
var _gen_out: PackedFloat32Array
var _gen_base_in: PackedFloat32Array
var _gen_carved: PackedFloat32Array
## Buffer length AS A NUMBER. Threads must bounds-check, but WITHOUT TOUCHING the array itself:
## any access to it as an object (even .size()) briefly creates a second reference, and a Packed
## array written through with a second reference alive makes a COPY — the field then points at the
## copy, every other thread's writes go nowhere, and what follows is exactly what the log showed:
## "out of bounds" at addresses the whole array could never have.
var _gen_len: int = 0

# One row z of a blur pass. Reads _gen_base_in (the previous pass) and writes _gen_out, so no
# thread ever reads what another is writing. The border rows are copied through untouched — the
# 5-tap kernel has no neighbours there.
## Allocate a whole-map buffer and MAKE SURE it was allocated. Out of memory, resize() returns an
## error and leaves the array EMPTY — after which the threads write into nothing and the log fills
## with "out of bounds" instead of one clear line saying memory ran out. On a tablet with a couple
## of gigabytes and a 1984² map (16 MB per buffer) that is not a hypothetical.
func _gen_alloc(n: int, what: String) -> PackedFloat32Array:
	var a := PackedFloat32Array()
	if a.resize(n) != OK or a.size() != n:
		push_error("LiteTerrain: could not allocate %s for %d values (%.1f MB) — out of memory"
				% [what, n, float(n) * 4.0 / 1048576.0])
		return PackedFloat32Array()
	return a

func _gen_blur_row(z: int) -> void:
	if _gen_drop_row():
		return
	var w := _gen_w
	var row := z * w
	# Bounds are checked AGAINST THE NUMBER (see _gen_len), never against the array's .size().
	if _gen_len <= 0 or row + w > _gen_len:
		_gen_row_done()
		return
	if z == 0 or z == _gen_d - 1:
		for x in w:
			_gen_out[row + x] = _gen_base_in[row + x]
		_gen_row_done()
		return
	_gen_out[row] = _gen_base_in[row]
	_gen_out[row + w - 1] = _gen_base_in[row + w - 1]
	for x in range(1, w - 1):
		_gen_out[row + x] = (
			_gen_base_in[row + x] +
			_gen_base_in[row + x - 1] +
			_gen_base_in[row + x + 1] +
			_gen_base_in[row - w + x] +
			_gen_base_in[row + w + x]
		) * 0.2
	_gen_row_done()
var _gen_rows_done: int = 0
var _gen_mutex := Mutex.new()
## Stop was pressed. Read by every row task and between passes.
var _gen_cancel: bool = false

## One row is done — called from EVERY thread at the end of its work.
func _gen_row_done() -> void:
	_gen_mutex.lock()
	_gen_rows_done += 1
	_gen_mutex.unlock()

## Should this row give up? A group task that is already running cannot be un-scheduled, so Stop
## works the other way round: every remaining row returns at once, the pass ends in milliseconds
## and the generation stops between passes, with the map on disk untouched.
func _gen_drop_row() -> bool:
	if not _gen_cancel:
		return false
	_gen_row_done()
	return true

# ── ПЛАН ПРОГОНА: СКОЛЬКО РАБОТЫ В КАЖДОМ ПРОХОДЕ ────────────────────────────
# Полоса и оценка времени делили прогон по ЗАШИТЫМ долям (Heights 0.02..0.5, Smoothing
# 0.5..0.62, Canyons 0.62..0.95), и это врало тремя способами сразу:
#
#   • РАЗМЫТИЙ БЫВАЕТ НЕСКОЛЬКО (GEN_SMOOTH_PASSES), а доля у них одна на всех: полоса
#     проходила 0.5→0.62, откатывалась назад и шла заново. Это и есть «перед каньонами
#     что-то пролетело»;
#   • КАНЬОНЫ МОГУТ БЫТЬ ВЫКЛЮЧЕНЫ — тогда треть шкалы просто перепрыгивалась;
#   • ЗАПИСЬ И ПЕРЕСБОРКА ПРЕВЬЮ занимали последние 4.5 % шкалы, хотя превью — самая долгая
#     стадия во всём прогоне.
#
# А оценка времени считается как elapsed × (1 − frac) / frac, то есть она честна ровно
# настолько, насколько ПОЛОСА ПРОПОРЦИОНАЛЬНА РАБОТЕ. С долями на глаз она и не могла не врать
# с самого начала.
#
# Поэтому план собирается ДО прогона: каждый проход объявляет свою цену, доли шкалы получаются
# делением, и «сколько осталось» становится правдой с первых секунд.
#
# ЦЕНА МЕРЯЕТСЯ В ВЫЗОВАХ ШУМА НА СЭМПЛ — их и считаем, потому что в этих проходах шум занимает
# почти всё время, а пара smoothstep и умножений на его фоне теряется. Числа не на глаз, а
# пересчитаны по коду самой строки (см. ссылки):
const CV_NOISE_COST := 5.0     ## _cv_noise написан на GDScript и стоит примерно впятеро дороже
                               ## нативного FastNoiseLite.get_noise_2d — отсюда множитель.
## _gen_fill_row: base + ridge + dune×2 = 4 нативных, meadow_mask + mountain_mask + mountain_dome
## = 3 вызова _cv_noise. 4 + 3×5 = 19.
const COST_HEIGHTS := 19.0
## _gen_blur_row: шума нет вовсе, пять чтений массива на сэмпл. Против одного вызова шума это
## заметно меньше единицы.
const COST_SMOOTH := 0.5
## _gen_carve_row: canyon_mask (1×_cv_noise) — и ВЫХОД, если маска нулевая. Каньон занимает малую
## долю карты, поэтому полная цена (mountain_mask + butte + gorge + ramp ≈ 17) платится только на
## CANYON_SHARE площади: 5 + 17×0.2 ≈ 8.
const COST_CANYON := 8.0
const CANYON_SHARE := 0.2
## Запись .res + .bin + ПЕРЕСБОРКА ПРЕВЬЮ. Шума здесь нет, но есть полный обход карты с постройкой
## мешей всех чанков, и по времени это сопоставимо с проходом высот. Число — оценка, а не подсчёт
## вызовов: считать нечего, стадия не наша (map.editor_rebuild_*).
const COST_BAKE := 6.0

var _plan: Array = []            # [{label, units}] СТРОГО в порядке запуска
var _plan_total: float = 0.0
var _plan_done: float = 0.0      # units уже отданных проходов
var _plan_i: int = 0

## Собрать план под конкретный прогон. do_canyons/blur_passes — ровно те условия, по которым
## проходы и запускаются ниже: план, разошедшийся с прогоном, врёт не меньше зашитых долей.
func _plan_build(width: int, depth: int, blur_passes: int, do_canyons: bool, do_bake: bool) -> void:
	var samples: float = float(width) * float(depth)
	_plan = [{"label": "Heights", "units": samples * COST_HEIGHTS}]
	for _i in blur_passes:
		_plan.append({"label": "Smoothing", "units": samples * COST_SMOOTH})
	if do_canyons:
		_plan.append({"label": "Canyons", "units": samples * COST_CANYON})
	if do_bake:
		_plan.append({"label": "Bake", "units": samples * COST_BAKE})
	_plan_total = 0.0
	for e in _plan:
		_plan_total += float(e["units"])
	_plan_done = 0.0
	_plan_i = 0

## Доля шкалы под СЛЕДУЮЩИЙ проход плана; курсор сдвигается. Идём строго по порядку — план
## построен ровно в том, в каком проходы и запускаются.
func _plan_slice() -> Vector2:
	var a: float = _plan_done / maxf(_plan_total, 1.0)
	if _plan_i >= _plan.size() or _plan_total <= 0.0:
		return Vector2(a, 1.0)
	_plan_done += float(_plan[_plan_i]["units"])
	_plan_i += 1
	return Vector2(a, _plan_done / _plan_total)

## RUN ONE PASS WITH THE BAR MOVING. Every pass used to sit on wait_for_group_task_completion —
## that blocks the main thread, and a blocked main thread redraws nothing, however pretty the
## window is. Here we wait IN A LOOP, handing a frame back to the editor, and update the bar from
## the number of finished rows.
##
## step_from/step_to is the share of the whole job this pass takes: the bar has to travel left to
## right ONCE per generation, not jump back to zero at every stage.
func _run_rows(task: Callable, rows: int, label: String) -> void:
	# Долю шкалы НЕ ПЕРЕДАЁМ: её знает план (_plan_slice). Пока границы приходили аргументами,
	# они были зашитыми числами в месте вызова — и разъезжались с тем, сколько проходов реально
	# запустится.
	var slice := _plan_slice()
	var step_from: float = slice.x
	var step_to: float = slice.y
	_gen_rows_done = 0
	var gid := WorkerThreadPool.add_group_task(task, rows, -1, false, "LiteTerrain")
	while not WorkerThreadPool.is_group_task_completed(gid):
		var done: float = float(_gen_rows_done) / float(maxi(rows, 1))
		_report("%s — %d%%" % [label, int(done * 100.0)],
				lerpf(step_from, step_to, done))
		await get_tree().process_frame
	WorkerThreadPool.wait_for_group_task_completion(gid)
	if not _gen_cancel:
		_report("%s — done" % label, step_to)

# One row z of the height fill (WorkerThreadPool.add_group_task calls this per row).
func _gen_fill_row(z: int) -> void:
	if _gen_drop_row():
		return
	var w := _gen_w
	# МИРОВАЯ координата строки, а не индекс в массиве: кусок, посчитанный по любому смещению,
	# обязан дать те же высоты (см. «МИРОВЫЕ КООРДИНАТЫ» вверху файла).
	var wz := float(origin_z + z)
	var nz := wz + noise_offset.y
	var row := z * w
	for x in w:
		var wx := float(origin_x + x)
		var nx := wx + noise_offset.x
		var base = (_gen_base.get_noise_2d(nx, nz) + 1.0) * 0.5
		var continental:float = pow(base, gen_power)
		var ridge = pow(1.0 - abs(_gen_ridge.get_noise_2d(nx, nz)), _gen_ridge_sharp)
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
		# Теперь каньон РЕЖЕТ уже готовую землю (см. _gen_carve_row): что бы здесь ни подняли,
		# врез считается от этого же уровня. Гасить нечего, и ступеней от гашения нет.
		var sand_m := 1.0 - b.meadow_mask(wp, _cv_noise)
		var mtn_mask := b.mountain_mask(wp, _cv_noise)
		var mtn_dome := b.mountain_dome(wp, _cv_noise)
		var not_mtn := 1.0 - mtn_mask
		var land_sand := sand_m * not_mtn
		var cont_biome := continental * lerpf(1.0, b.desert_flatten, land_sand)
		var h = cont_biome + ridge_term * not_mtn
		var duneph := wx / b.dune_wavelength + _gen_dune.get_noise_2d(nx, nz) * 3.5
		var dune := pow(0.5 + 0.5 * sin(duneph), 1.4) * _gen_dune_amp * land_sand
		var mtn_rise := mtn_dome * _gen_mtn_rise + _gen_dune.get_noise_2d(nx * 1.7, nz * 1.7) * 4.0 * mtn_mask
		_gen_out[row + x] = h * gen_amplitude + dune + mtn_rise
	_gen_row_done()

## Everything DERIVED FROM THE FIVE KNOBS for this generation: the metre values (from Height) and
## what used to sit on sliders of its own. Computed once, before the first pass — the threads only
## read these fields.
var _gen_mtn_rise: float = 48.0
var _gen_dune_amp: float = 6.0
## Глубина ущелья ниже местной земли (метры, от Height). Раньше поле значило «высота меса» —
## пока верх меса задавался абсолютом; теперь абсолютов в каньоне нет вовсе.
var _gen_gorge_depth: float = 40.0
var _gen_floor: float = 6.0
var _gen_mtn_amount: float = 0.8
var _gen_ridge_sharp: float = 2.5

# One row z of the canyon carve (reads _gen_base_in, writes _gen_carved).
func _gen_carve_row(z: int) -> void:
	if _gen_drop_row():
		return
	var w := _gen_w
	var wz := float(origin_z + z)
	var b := _gen_biomes
	if b == null or _gen_len <= 0 or z * w + w > _gen_len:
		_gen_row_done()
		return                       # as in _gen_blur_row: bounds checked against the number
	var terr: float = maxf(b.canyon_band_height, 0.5)
	for x in w:
		var idx := z * w + x
		var wx := float(origin_x + x)
		var wp := Vector2(wx, wz)
		# МАСКА ОБЛАСТИ — ТА ЖЕ САМАЯ, ЧТО У ЦВЕТА, И БЕРЁТСЯ ОДНИМ ВЫЗОВОМ. Здесь была вторая
		# копия её формулы, и она молча разошлась с оригиналом: `canyon_mask` сдвигает шум на
		# `mask_offset` (это смещение двигает ВСЮ географию при смене сида), а копия про него не
		# знала. То есть врез считался НЕ ТАМ, где каньон покрашен: настоящая область оставалась
		# нетронутой («каньоны выглядят как обычный рельеф»), а по карте — в пустыне, в горах,
		# где угодно — вылезали ямы там, где сдвинутый шум случайно перевалил порог.
		#
		# Вторая половина той же беды — ШИРИНА края. Копия размывала границу на ±0.02, а цвет
		# фадится по `canyon_edge` (0.05): даже там, где они совпадали, у ямы был почти отвесный
		# борт, а терракота растекалась мягко. Теперь и форма, и цвет идут по одному числу.
		var hmask: float = b.canyon_mask(wp, _cv_noise)
		if hmask <= 0.001:
			continue
		# ГОРА ГЛАВНЕЕ КАНЬОНА, и это не вкус: в шейдере слои идут «пустыня↔луг → каньон →
		# ГОРЫ СВЕРХУ», то есть по цвету гора уже перекрывает каньон. Форма обязана говорить то
		# же самое, иначе выходит то, что и вышло: заснеженная гора, изрезанная терракотовыми
		# ущельями с отвесными боками.
		#
		# Гасим ВРЕЗ по горной маске, а НЕ подъём гор по каньонной, как было раньше. Разница
		# принципиальная: гашение подъёма — это ступень ровно той высоты, какую оно снимает
		# (0.75 высоты карты), и по краю маски открывалась стометровая яма. Врез же всего 0.3
		# высоты и сам по себе плавно сходит на нет по hmask — гасить его безопасно.
		hmask *= 1.0 - b.mountain_mask(wp, _cv_noise)
		if hmask <= 0.001:
			continue
		# Смещение сида и здесь: иначе иерархия столовых гор осталась бы одинаковой на всех сидах.
		var bt := _cv_noise(wp / b.canyon_butte_scale + Vector2(300.0, 300.0) + b.mask_offset)
		# КАНЬОН — ЭТО СТОЛОВАЯ ЗЕМЛЯ, ПРОРЕЗАННАЯ УЩЕЛЬЯМИ, а не яма и не отдельная плита.
		# Через три захода это единственная модель, которая сходится со всеми симптомами:
		#
		#   • верх — ЭТО МЕСТНАЯ ЗЕМЛЯ (surface). Пока он задавался абсолютом, область то торчала
		#     плитой над равниной, то тонула в ней ровным терракотовым полем без единой стенки;
		#   • ущелья — МЕНЬШИНСТВО площади. Когда я сделал дно половиной области, вся она ушла
		#     вниз от окрестной земли: получилась чаша с обрывом по всей границе, куда не въехать
		#     и откуда не выехать. «Плато с парой царапин» было верным симптомом НЕВЕРНОЙ высоты
		#     верха, а не ширины ущелий;
		#   • ступени — ТОЛЬКО НА СТЕНКЕ. Квантование дна и верха давало горизонтали по всей
		#     области: обрыв в шесть метров посреди ровного места, ездить невозможно.
		#
		# Отсюда и граница области перестаёт быть обрывом: наверху canyon_h равен surface, и
		# смешивание по hmask ничего не двигает — каньон входит в окрестную землю незаметно.
		var surface: float = _gen_base_in[idx]
		var gv := absf(_gen_gorge.get_noise_2d(wx, wz))
		var ramp := smoothstep(0.5, 0.75, (_gen_ramp.get_noise_2d(wx, wz) + 1.0) * 0.5)
		# |fbm| близок к нулю ВДОЛЬ ВЕТВЯЩИХСЯ ЛИНИЙ — это и есть русла. Дно там, где значение
		# ниже gen_canyon_width; выше — стенка. Пандус (ramp) растягивает её в съезд: без таких
		# мест в ущелье нельзя было бы попасть.
		var wall_lo: float = gen_canyon_width * 0.55
		# СТЕНКА КРУТАЯ, НО НЕ БРИТВЕННАЯ. На полосе в 0.02 перепад в сорок метров укладывался
		# в метр-полтора по горизонтали: щель читалась как ДЫРА в меше, а шейдер вдобавок мазал
		# по ней текстуру полосами (UV берутся из мировых XZ, и на отвесе они вырождаются).
		# 0.05 даёт те же несколько метров подъёма — уклон всё ещё обрывистый, но это стенка.
		var wall_hi: float = wall_lo + lerpf(0.05, 0.14, ramp)
		var wall_t := smoothstep(wall_lo, wall_hi, gv)
		# ГЛУБИНА СЛЕДУЕТ ЗА ТЕМ, НАСКОЛЬКО ШУМ УШЁЛ ПОД ПОРОГ. Раньше любое место с gv ниже
		# порога проваливалось на ПОЛНУЮ глубину — и пятачок в пару метров, где шум случайно
		# нырнул на волосок, становился колодцем посреди ровной терракоты (те самые чёрные
		# точки на карте). Теперь полная глубина только в СЕРДЦЕВИНЕ русла, а к его краю
		# остаётся царапина.
		var deep_k: float = smoothstep(wall_lo, wall_lo * 0.35, gv)
		var floor_h: float = minf(maxf(surface - _gen_gorge_depth * deep_k, _gen_floor), surface)
		var mesa_top: float = surface + _gen_floor * bt
		# ТЕРРАСИМ ПОДЪЁМ, А НЕ ВЫСОТУ. Раньше на сетку снималась сама высота — то есть и ровное
		# дно, и верх меса, где никаких ступеней быть не должно. Теперь ступени нарезаются на
		# ДОЛЕ подъёма от дна к верху: внизу ровно дно, наверху ровно верх, а между ними столько
		# ступеней, сколько раз terr укладывается в перепад. Высота ступени та же ≈ terr, значит
		# и с цветными слоями шейдера (он красит по мировой высоте) они по-прежнему в лад.
		var span: float = maxf(mesa_top - floor_h, 0.0)
		var steps: float = maxf(1.0, floor(span / terr))
		var t: float = wall_t * steps
		var ti: float = floor(t)
		var riser: float = smoothstep(1.0 - lerpf(gen_canyon_riser, 0.02, ramp), 1.0, t - ti)
		var canyon_h: float = floor_h + (ti + riser) * (span / steps)
		_gen_carved[idx] = lerpf(_gen_base_in[idx], canyon_h, hmask)
	_gen_row_done()

# Value noise matching the one map.gd uses for the biome masks, so the generator's canyon
# region is exactly the region the shader paints terracotta.
func _cv_fract(x: float) -> float:
	return x - floor(x)

func _cv_hash2d(p: Vector2) -> float:
	p = Vector2(_cv_fract(p.x * 123.34), _cv_fract(p.y * 456.21))
	var d: float = p.dot(p + Vector2(45.32, 45.32))
	p += Vector2(d, d)
	return _cv_fract(p.x * p.y)

func _cv_noise(p: Vector2) -> float:
	var i := Vector2(floor(p.x), floor(p.y))
	var f := p - i
	f = f * f * (Vector2(3.0, 3.0) - 2.0 * f)
	var a := _cv_hash2d(i)
	var b := _cv_hash2d(i + Vector2(1.0, 0.0))
	var c := _cv_hash2d(i + Vector2(0.0, 1.0))
	var dd := _cv_hash2d(i + Vector2(1.0, 1.0))
	return lerpf(lerpf(a, b, f.x), lerpf(c, dd, f.x), f.y)

## ПРОГОН ЦЕЛИКОМ: шум → размытие → каньоны. Возвращает высоты или ПУСТОЙ массив, если не
## хватило памяти или нажали «стоп». Пустой ответ обязателен именно как ответ, а не как
## полурезультат: полугенерированная карта хуже старой, и записывать её нельзя.
##
## Окно, файлы, undo и пересборку превью делает вызывающий — здесь только счёт.
func generate(width: int, depth: int, biomes: TerrainBiomes) -> PackedFloat32Array:
	_gen_cancel = false
	_gen_biomes = biomes
	# Минимальный размер: меньше двух чанков даёт вырожденные чанки и ошибки сборки.
	width = maxi(width, 32)
	depth = maxi(depth, 32)
	# КАРТА ЦЕЛИКОМ — ЭТО КУСОК С НАЧАЛОМ В ЛЕВОМ ВЕРХНЕМ УГЛУ. Мир у нас центрирован на нуле
	# (map.gd ставит вершины в `x − w/2`), поэтому мировая клетка локального (0,0) — это минус
	# половина размера. А сдвиг шума равен ровно той же половине: так генератор, перешедший на
	# мировые координаты, воспроизводит прежнюю карту байт в байт, а не «почти такую же».
	origin_x = -int(width / 2)
	origin_z = -int(depth / 2)
	# Сдвиг выводим ИЗ НАЧАЛА КУСКА, а не из размера: тогда nx = wx − origin_x = x, то есть шум
	# берётся ровно в той же точке, что и раньше, при любой чётности размера.
	noise_offset = Vector2(float(-origin_x), float(-origin_z))
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

	# ── Height fill, THREADED ─────────────────────────────────────────────────
	# Rows are independent, so they go to the WorkerThreadPool (roughly a core-count speedup).
	# The noise objects are fields the threads only read. Output goes to _gen_out (refcount = 1,
	# so no copy-on-write).
	_gen_w = width
	_gen_d = depth
	# Биомы кладёт вызывающий (док берёт их у выбранной ноды, игра — у своей карты):
	# генератор про сцену ничего не знает.
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
	# The snow line lives in the RESOURCE: the shader reads it, not the generator, and there is
	# nowhere to keep it "for this generation" — the map is painted by the game later.
	_gen_biomes.snow_line = gen_amplitude * 0.55
	_gen_biomes.snow_blend = maxf(gen_amplitude * 0.12, 8.0)
	_gen_base = base_noise
	_gen_ridge = ridge_noise
	_gen_dune = dune_noise
	_gen_len = width * depth
	_gen_out = _gen_alloc(_gen_len, "the heightmap")
	if _gen_out.is_empty():
		_gen_len = 0
		return PackedFloat32Array()
	# ПЛАН СТРОИМ ЗДЕСЬ, по тем же условиям, по которым проходы и запускаются ниже. Каньоны
	# спрашиваем у обеих сторон — у дока и у ресурса биомов: врез идёт только когда включены обе,
	# и план, посчитавший каньон включённым, оставил бы в конце шкалы непройденную треть.
	var will_carve: bool = gen_canyon_enable and _gen_biomes != null and _gen_biomes.canyon_enabled
	_plan_build(width, depth, GEN_SMOOTH_PASSES, will_carve, plan_bake)
	await _run_rows(_gen_fill_row, depth, "Heights")
	# STOP IS CHECKED BETWEEN PASSES, and every check leaves without writing anything: a map
	# half-generated is worse than the old one, and the file on disk must stay usable.
	if _gen_cancel:
		return PackedFloat32Array()
	var new_data := _gen_out
	_gen_out = PackedFloat32Array()          # drop the field's reference; new_data owns it now

	# ── Optional blur passes ─────────────────────
	# Simple 5-tap box blur to soften extreme spikes.
	# Each pass slightly reduces aliasing without destroying ridges.
	# THREADED, like the fill and the carve above: a blur pass is a full sweep of the map, and on
	# a big one that was seconds of main thread per pass, twice over — once here and once as the
	# `duplicate()` it needed to avoid reading its own output.
	for _p in GEN_SMOOTH_PASSES:
		_gen_base_in = new_data
		_gen_out = _gen_alloc(width * depth, "the blur buffer")
		if _gen_out.is_empty():
			break                      # no buffer, no blur — the map itself already exists
		await _run_rows(_gen_blur_row, depth, "Smoothing")
		if _gen_cancel:
			return PackedFloat32Array()
		new_data = _gen_out
		_gen_out = PackedFloat32Array()
		_gen_base_in = PackedFloat32Array()

	# ── Canyon carve (AFTER the blur, which would otherwise round off the sheer walls) ──
	# Badlands: mesas at ABSOLUTE heights (varied by the butte noise, so there is a hierarchy
	# rather than one slab), TERRACED into flat treads and sharp risers, plus a network of
	# gorges and the occasional ramp down. The region is the canyon biome's own mask.
	# Carve only when canyons are enabled in BOTH the dock and the biomes, otherwise the
	# landform would be cut up where the canyon colour is switched off.
	if gen_canyon_enable and _gen_biomes.canyon_enabled:
		# Channel network: abs(fbm) is near 0 along branching lines — like ridges, but cut down.
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
		# Canyon carving, THREADED (rows are independent): read _gen_base_in, write _gen_carved.
		_gen_gorge = gorge_noise
		_gen_ramp = ramp_noise
		_gen_base_in = new_data
		# duplicate() AND a size CHECK: out of memory it returns an empty array, and without the
		# check the threads would start writing into nothing — thirty "out of bounds" lines instead
		# of one clear one. Copying element by element is not an option: four million assignments
		# in GDScript is seconds for nothing.
		_gen_carved = new_data.duplicate()
		if _gen_carved.size() != width * depth:
			push_error("LiteTerrain: out of memory for the canyon buffer (%d values, %.1f MB) — canyons skipped"
					% [width * depth, float(width * depth) * 4.0 / 1048576.0])
			_gen_carved = PackedFloat32Array()
		else:
			await _run_rows(_gen_carve_row, depth, "Canyons")
			if _gen_cancel:
				return PackedFloat32Array()
			new_data = _gen_carved
		_gen_carved = PackedFloat32Array()
		_gen_base_in = PackedFloat32Array()

	return new_data
