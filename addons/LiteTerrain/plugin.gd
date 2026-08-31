@tool
extends EditorPlugin

var sculpt_node     = null
var brush_radius    = 3.0
var brush_power     = 0.5      # 0..1 — the Strength slider, shown as 0..100 %
var sculpt_mode     = "raise"
var panel           = null
var radius_slider   = null
# Live references to the widgets whose value does NOT live in the plugin but in the selected
# node's biome resource. They have to be re-read when the selection changes (see _sync_dock), or
# the box shows the previous terrain's state — or the fallback resource's, if nothing was
# selected when the dock opened.
var _cb_canyon: CheckBox = null
var _cb_mountain: CheckBox = null
var _sl_stratum: HSlider = null
## Sliders the preset moves: they must be updated too, or the handle lies about its value.
var _sl_height: HSlider = null
var _sl_features: HSlider = null
var _sl_mountains: HSlider = null
var strength_slider = null
## Caption under the brush sliders: how many metres one dab moves RIGHT NOW.
var _brush_hint: Label = null

var _dirty_chunks: Dictionary = {}

# ── Stroke-level undo/redo (image mode) ──────────────────────────────────────
# Image mode edits md in place, which on its own leaves no history. To make Ctrl+Z / Ctrl+Y
# behave, we snapshot the heights at the START of a stroke (button pressed) and commit ONE
# history step at its END (button released), rather than one per pixel.
var _stroke_active := false
var _stroke_before := PackedFloat32Array()

# ── Dab spacing (throttle) ────────────────────────────────────────────────────
# _sculpt runs on EVERY mouse move, and apply_brush walks (2r+1)² cells. Dragging slowly or
# just a shaky hand turns that into dozens of overlapping dabs on one spot — pure waste. A new
# dab is laid down only once the cursor has moved a fraction of the radius from the last one;
# neighbouring dabs still overlap, so coverage does not suffer.
const DAB_SPACING_FRAC := 0.25
var _have_last_dab := false
var _last_dab_pos  := Vector3.ZERO

# ── Brush strength is a PERCENTAGE, not metres ───────────────────────────────
# Strength used to be the height of one dab in world units (a 1..1000 slider holding
# thousandths), and there was no way to reason about it. The same number built a mountain on a
# 30 m map and did nothing on a 300 m one; worse, it meant the SAME rise for a three-metre brush
# and a two-hundred-metre one, so a wide dab came out as a flat pancake and a narrow one as a
# needle through the map.
#
# Now strength is a fraction of the MAP HEIGHT (the Height knob), and it scales WITH THE RADIUS:
# at 100 % a radius-100 brush lifts by 10 % of the height, a radius-10 brush by 1 %. The dab
# therefore keeps the same SLOPE whatever the brush size — a hill comes out shaped like a hill.
const SCULPT_REF_RADIUS := 100.0   # the radius at which 100 % power == SCULPT_REF_FRAC of height
const SCULPT_REF_FRAC   := 0.10

## Metres per dab for raise/lower.
func _brush_step() -> float:
	return gen_amplitude * SCULPT_REF_FRAC * (brush_radius / SCULPT_REF_RADIUS) * brush_power

## Weight for flatten. That one is a blend towards the average height, not metres, so it does
## NOT scale with the radius: "smooth it halfway" has to mean the same thing at any brush size.
func _brush_weight() -> float:
	return clampf(brush_power, 0.0, 1.0)

# Slider handlers are named methods rather than lambdas because they now do two things (write
# the value and refresh the hint), and a multi-statement lambda in the middle of a call's
# argument list is exactly the kind of code the parser trips over.
func _set_brush_radius(v: float) -> void:
	brush_radius = v
	_update_brush_hint()
	update_overlays()

func _set_brush_power(v: float) -> void:
	brush_power = v / 100.0
	_update_brush_hint()

func _set_gen_amplitude(v: float) -> void:
	gen_amplitude = v
	_update_brush_hint()   # brush metres are a share of the map height — they move with it

## The percentage is predictable, but the world is built in metres: without this line "40 %"
## says nothing about what one dab actually does.
func _update_brush_hint() -> void:
	if _brush_hint == null or not is_instance_valid(_brush_hint):
		return
	var pct := int(round(brush_power * 100.0))
	if sculpt_mode == "flatten":
		_brush_hint.text = "%d%% towards the average" % pct
	else:
		_brush_hint.text = "%d%% · %s m per dab" % [pct, _fmt(_brush_step(), 2)]

# ---------- Noise generation parameters ----------
# FIVE KNOBS FOR THE WHOLE TERRAIN, cut down from seventeen on purpose. A setting earns its place
# only if the user can PREDICT what it will change; everything else gets turned at random and
# produces a result nobody can reproduce. Three kinds of surplus went out:
#   • what had one sensible answer (noise octaves, number of blur passes) — now a constant: more
#     octaves is noise, fewer is mush; a second blur pass shaves off exactly what the terrain was
#     built for;
#   • what always moved TOGETHER (ridge height with ridge sharpness; gully depth, size, branching
#     and taste for steepness) — one knob per group;
#   • what has to FOLLOW the map height (mesa tops, canyon floor, mountain rise, dunes, snow line)
#     — derived from it instead of set apart. Those numbers used to live in metres and broke
#     silently on any move of Height.
var gen_seed:             int   = 42
var gen_scale:           float  = 150.0   # continental frequency scale
var gen_power:           float  = 2.6     # higher = flatter plains, sharper peaks
var gen_amplitude:       float  = 30.0    # max height in world units
var gen_mountains01:     float  = 0.6     # 0 = rolling hills, 1 = sharp ridges
var gen_size:             int   = 0       # image-mode target size (0 = keep current)

## Numbers with one sensible answer. They do not deserve a knob; they do deserve an explanation.
const GEN_OCTAVES := 6        # more = high-frequency noise, fewer = blurred blobs
const GEN_SMOOTH_PASSES := 1  # one pass kills noise spikes; a second one starts eating terrain

## Derived from gen_mountains01: the two always moved together, and setting them apart only ever
## produced either a picket fence or pancakes.
func _mtn_amount() -> float:
	return lerpf(0.25, 1.1, gen_mountains01)

func _ridge_sharp() -> float:
	return lerpf(1.6, 3.6, gen_mountains01)

# ---------- Canyon carving (baked into the heights AFTER the blur, so the walls stay sheer) ----------
# The canyon shape is driven by the same mask as the canyon biome's colour (TerrainBiomes),
# so the landform and the colour line up on their own.
var gen_canyon_enable:    bool  = true
var gen_canyon_riser:     float = 0.30   # share of a step taken by the steep riser (0.30 → 70% flat, drivable tread)
var gen_canyon_gorge:     float = 70.0   # frequency of the gorge network (lower = more channels)
var gen_canyon_width:     float = 0.10   # width of the gorge floor, in noise units (larger = wider)
# Mesa tops and the canyon floor ARE NOT SET IN METRES: they are derived from Height (see
# _generate_noise). While they had sliders of their own, every change of height turned the canyon
# into either a ditch in a flat field or a chasm deeper than the mountains, and fixing that was a
# manual, blind job.
# Mesas are built at ABSOLUTE heights (each plateau at its own level, varied by the butte noise)
# and TERRACED into strata — the badlands look. No water; biomes come from the region masks.
# Biome settings (scales, thresholds, dunes, mountain height, canyon terrace) come from the
# terrain node's TerrainBiomes. Snapshot it BEFORE the rows are spread across threads: they
# only ever read it.
var _gen_biomes: TerrainBiomes = null
# With no terrain selected (the dock is open before a node exists) fall back to our own
# defaults, so the generator still runs and matches a node with a fresh resource.
var _gen_biomes_fallback: TerrainBiomes = null

# The biome resource of the SELECTED terrain node. The dock's sliders edit that resource, so
# the landform and the biome colour cannot drift apart.
func _biomes() -> TerrainBiomes:
	if sculpt_node != null and "biomes" in sculpt_node:
		if sculpt_node.biomes == null:
			sculpt_node.biomes = TerrainBiomes.new()
		return sculpt_node.biomes
	if _gen_biomes_fallback == null:
		_gen_biomes_fallback = TerrainBiomes.new()
	return _gen_biomes_fallback

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

# ─────────────────────────────────────────────────
# GENERATION SCREEN
# ─────────────────────────────────────────────────
# Generating a map is tens of seconds during which the editor answers nothing. With no window
# that reads as "Godot has hung": you cannot tell work from a crash, so people kill the editor
# halfway through. The addon is going public, and this is the first thing a new user trips over.
#
# The bar is HONEST, not "something crawling to the right": every finished map row bumps a
# counter, so the percentage is real work. THREADS touch that counter, hence the mutex — an
# increment from several threads without one loses values.
#
# The window itself is a plain Control over the editor (EditorInterface.get_base_control): a
# GDScript plugin gets no progress dialog of its own, and this way works both in the editor and
# when the addon runs inside somebody else's project.
var _prog_root: Control = null
var _prog_step: Label = null
var _prog_note: Label = null
var _prog_eta: Label = null
var _prog_bar: ProgressBar = null
var _prog_stop: Button = null
var _gen_rows_done: int = 0
var _gen_mutex := Mutex.new()
var _generating: bool = false
## Stop was pressed. Read by every row task and between passes.
var _gen_cancel: bool = false
## When this generation started (ms). The only input the estimate has.
var _gen_t0: int = 0

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

## `can_stop = false` — окно БЕЗ кнопки «Стоп». У запекания отменять нечего: оно пишет файлы
## один за другим, и «стоп» посреди уже записанного heightmap'а не вернул бы старый.
func _progress_open(can_stop: bool = true) -> void:
	if _prog_root != null and is_instance_valid(_prog_root):
		return
	var base: Control = EditorInterface.get_base_control()
	if base == null:
		return
	_gen_cancel = false
	_gen_t0 = Time.get_ticks_msec()
	_prog_root = Control.new()
	_prog_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_prog_root.mouse_filter = Control.MOUSE_FILTER_STOP   # modal: clicking past it does nothing
	base.add_child(_prog_root)
	# The dim. Without it the panel floats in mid-air and does not read as "work in progress".
	var dim := ColorRect.new()
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.color = Color(0, 0, 0, 0.55)
	_prog_root.add_child(dim)
	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_CENTER)
	panel.custom_minimum_size = Vector2(420, 0)
	panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	panel.grow_vertical = Control.GROW_DIRECTION_BOTH
	_prog_root.add_child(panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	panel.add_child(box)
	var title := Label.new()
	title.text = "LiteTerrain — generating the world"
	title.add_theme_font_size_override("font_size", 18)
	box.add_child(title)
	_prog_step = Label.new()
	_prog_step.text = "…"
	box.add_child(_prog_step)
	_prog_bar = ProgressBar.new()
	_prog_bar.min_value = 0.0
	_prog_bar.max_value = 1.0
	_prog_bar.value = 0.0
	_prog_bar.custom_minimum_size = Vector2(0, 18)
	box.add_child(_prog_bar)
	_prog_eta = Label.new()
	_prog_eta.text = "estimating…"
	box.add_child(_prog_eta)
	_prog_note = Label.new()
	_prog_note.text = "Done ONCE: in game the map is already built and read from a file."
	_prog_note.add_theme_font_size_override("font_size", 11)
	_prog_note.modulate = Color(1, 1, 1, 0.6)
	box.add_child(_prog_note)
	# STOP, because "wait it out or kill the editor" is not a choice anybody should be given: a
	# 4096² map on a slow machine is minutes, and a wrong seed is visible in the first seconds.
	if not can_stop:
		return
	_prog_stop = Button.new()
	_prog_stop.text = "Stop"
	_prog_stop.tooltip_text = "Abandon this generation. The map and the file on disk stay as they were."
	_prog_stop.pressed.connect(_on_gen_stop)
	box.add_child(_prog_stop)

func _on_gen_stop() -> void:
	_gen_cancel = true
	if _prog_stop != null and is_instance_valid(_prog_stop):
		_prog_stop.disabled = true
	if _prog_step != null and is_instance_valid(_prog_step):
		_prog_step.text = "Stopping — letting the running pass finish"
	if _prog_eta != null and is_instance_valid(_prog_eta):
		_prog_eta.text = ""

func _progress_close() -> void:
	_generating = false
	_gen_cancel = false
	# Let the buffers go HERE and not at each caller: a stopped generation leaves whole-map
	# arrays behind (16 MB apiece at 1984²), and the next run would allocate its own on top.
	_gen_out = PackedFloat32Array()
	_gen_base_in = PackedFloat32Array()
	_gen_carved = PackedFloat32Array()
	_gen_len = 0
	if _prog_root != null and is_instance_valid(_prog_root):
		_prog_root.queue_free()
	_prog_root = null
	_prog_step = null
	_prog_bar = null
	_prog_note = null
	_prog_eta = null
	_prog_stop = null

func _progress_say(step: String, frac: float) -> void:
	if _prog_step != null and is_instance_valid(_prog_step):
		_prog_step.text = step
	if _prog_bar != null and is_instance_valid(_prog_bar):
		_prog_bar.value = clampf(frac, 0.0, 1.0)
	if _prog_eta != null and is_instance_valid(_prog_eta) and not _gen_cancel:
		_prog_eta.text = _eta_text(frac)

## Time left, from the share done and the time it took to get there. A per-pass estimate would be
## WORSE, not better: the passes differ several-fold in cost, so each one would start by promising
## a new total. Measured over the whole run the number settles within the first couple of seconds
## and only tightens after that.
func _eta_text(frac: float) -> String:
	if _gen_t0 == 0 or frac <= 0.02:
		return "estimating…"
	var elapsed: float = float(Time.get_ticks_msec() - _gen_t0) / 1000.0
	var left: float = elapsed * (1.0 - frac) / frac
	if left < 1.5:
		return "almost done"
	if left < 90.0:
		return "≈ %d s left" % int(round(left))
	return "≈ %d min %02d s left" % [int(left) / 60, int(left) % 60]

## RUN ONE PASS WITH THE BAR MOVING. Every pass used to sit on wait_for_group_task_completion —
## that blocks the main thread, and a blocked main thread redraws nothing, however pretty the
## window is. Here we wait IN A LOOP, handing a frame back to the editor, and update the bar from
## the number of finished rows.
##
## step_from/step_to is the share of the whole job this pass takes: the bar has to travel left to
## right ONCE per generation, not jump back to zero at every stage.
func _run_rows(task: Callable, rows: int, label: String, step_from: float, step_to: float) -> void:
	_gen_rows_done = 0
	var gid := WorkerThreadPool.add_group_task(task, rows, -1, false, "LiteTerrain")
	while not WorkerThreadPool.is_group_task_completed(gid):
		var done: float = float(_gen_rows_done) / float(maxi(rows, 1))
		_progress_say("%s — %d%%" % [label, int(done * 100.0)],
				lerpf(step_from, step_to, done))
		await get_tree().process_frame
	WorkerThreadPool.wait_for_group_task_completion(gid)
	if not _gen_cancel:
		_progress_say("%s — done" % label, step_to)

## ПЕРЕСБОРКА ПРЕВЬЮ С ПОЛОСОЙ. Та же работа, что и внутри map.set_heightmap, только ведём её
## сами: ставим задачу, каждый кадр спрашиваем долю готовых чанков и отдаём кадр редактору. Стоп
## здесь НЕ ПРЕДЛАГАЕМ: карта уже посчитана и записана в файл, бросить сборку превью значило бы
## оставить в сцене меш от прошлой карты — то есть картинку, которая врёт про то, что на диске.
func _rebuild_preview_with_progress(step_from: float, step_to: float) -> void:
	if sculpt_node == null or not sculpt_node.has_method("editor_rebuild_begin"):
		return
	var total: int = sculpt_node.editor_rebuild_begin()
	while not sculpt_node.editor_rebuild_done():
		var done: float = sculpt_node.editor_rebuild_progress()
		_progress_say("Building the preview — %d%% of %d chunks" % [int(done * 100.0), total],
				lerpf(step_from, step_to, done))
		await get_tree().process_frame
	# Склейка одного меша из всех чанков — единственная часть, которую нельзя разложить на кадры.
	_progress_say("Merging the mesh", step_to)
	await get_tree().process_frame
	sculpt_node.editor_rebuild_apply()

# One row z of the height fill (WorkerThreadPool.add_group_task calls this per row).
func _gen_fill_row(z: int) -> void:
	if _gen_drop_row():
		return
	var w := _gen_w
	var hw := float(w) * 0.5
	var hd := float(_gen_d) * 0.5
	var fz := float(z)
	var row := z * w
	for x in w:
		var fx := float(x)
		var base = (_gen_base.get_noise_2d(fx, fz) + 1.0) * 0.5
		var continental:float = pow(base, gen_power)
		var ridge = pow(1.0 - abs(_gen_ridge.get_noise_2d(fx, fz)), _gen_ridge_sharp)
		var mountain_mask = smoothstep(0.52, 0.78, continental)
		var ridge_term = ridge * _gen_mtn_amount * mountain_mask
		var wx := fx - hw
		var wz := fz - hd
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
		var duneph := wx / b.dune_wavelength + _gen_dune.get_noise_2d(fx, fz) * 3.5
		var dune := pow(0.5 + 0.5 * sin(duneph), 1.4) * _gen_dune_amp * land_sand
		var mtn_rise := mtn_dome * _gen_mtn_rise + _gen_dune.get_noise_2d(fx * 1.7, fz * 1.7) * 4.0 * mtn_mask
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
	var hw := float(w) * 0.5
	var hd := float(_gen_d) * 0.5
	var fz := float(z)
	var b := _gen_biomes
	if b == null or _gen_len <= 0 or z * w + w > _gen_len:
		_gen_row_done()
		return                       # as in _gen_blur_row: bounds checked against the number
	var terr: float = maxf(b.canyon_band_height, 0.5)
	for x in w:
		var idx := z * w + x
		var wx := float(x) - hw
		var wz := fz - hd
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

# ─────────────────────────────────────────────────
# Helper builders
# ─────────────────────────────────────────────────
func _sep() -> HSeparator:
	var s = HSeparator.new()
	s.custom_minimum_size = Vector2(0, 6)
	return s

func _lbl(t: String) -> Label:
	var l = Label.new()
	l.text = t
	return l

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

## Label of a fixed width, so every row in the dock lines its control up at the same x.
func _lbl_fixed(t: String) -> Label:
	var l := Label.new()
	l.text = t
	l.custom_minimum_size = Vector2(76, 0)
	return l

## One setting = ONE ROW: name on the left, control on the right. The dock used to spend two
## rows on every slider (a label line, then the slider), which is what made eighteen settings
## look like a wall.
func _row(text: String, ctrl: Control) -> HBoxContainer:
	var h := HBoxContainer.new()
	h.add_child(_lbl_fixed(text))
	ctrl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(ctrl)
	return h

## A slider row with its live value on the right. `apply` writes the value where it belongs;
## saving happens on drag end, not on every pixel of the drag.
func _slider_row(parent: Control, text: String, mn: float, mx: float, val: float, step: float,
		apply: Callable, digits: int) -> HSlider:
	var h := HBoxContainer.new()
	h.add_child(_lbl_fixed(text))
	var sl := _slider(mn, mx, val, step)
	sl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(sl)
	var val_lbl := Label.new()
	val_lbl.custom_minimum_size = Vector2(38, 0)
	val_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	val_lbl.text = _fmt(val, digits)
	h.add_child(val_lbl)
	sl.value_changed.connect(func(v: float) -> void:
		apply.call(v)
		val_lbl.text = _fmt(v, digits))
	sl.drag_ended.connect(func(_c: bool) -> void: _save_settings())
	parent.add_child(h)
	return sl

func _fmt(v: float, digits: int) -> String:
	return str(int(round(v))) if digits <= 0 else str(snappedf(v, pow(0.1, digits)))

func _slider(mn: float, mx: float, val: float, step: float = 0.0) -> HSlider:
	var sl = HSlider.new()
	sl.min_value = mn
	sl.max_value = mx
	sl.value    = val
	if step > 0.0:
		sl.step = step
	return sl

# ─────────────────────────────────────────────────
# Dock UI
# ─────────────────────────────────────────────────
func _enter_tree() -> void:
	# Pull back the dock settings saved last time (brush + generation) so they do not have to
	# be dialled in again on every visit.
	_load_settings()

	# Wrap everything in a ScrollContainer so the dock is scrollable on tablets
	var scroll = ScrollContainer.new()
	scroll.name = "LiteTerrain"
	scroll.custom_minimum_size = Vector2(220, 0)
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED

	panel = VBoxContainer.new()
	panel.custom_minimum_size = Vector2(220, 0)
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	# THE DOCK IS TWO LISTS, not one. Everything above "Advanced" is what actually changes a
	# world — seed, size, height, feature size, which biomes exist. Everything below is dialled
	# in once and then never touched, so it starts folded away: eighteen sliders in a row read
	# as "this is complicated", and the five that matter drown in them.
	#
	# Each setting is ONE ROW (label + control on the same line) rather than a label above its
	# slider. Same information, half the height, and the dock stops needing a scrollbar.

	# ── Setup ────────────────────────────────────────────────────────────────
	var create_btn = Button.new()
	create_btn.text = "Create Terrain Node"
	create_btn.tooltip_text = "Adds a single LiteTerrain node (image mode, flat 128x128). It creates its own children."
	create_btn.pressed.connect(_create_terrain)
	panel.add_child(create_btn)

	# ── Sculpt ───────────────────────────────────────────────────────────────
	panel.add_child(_sep())
	panel.add_child(_lbl("── Sculpt ──"))
	var modes := HBoxContainer.new()
	modes.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var group := ButtonGroup.new()
	# ПОДПИСИ СЛОВАМИ, А НЕ ЗНАЧКАМИ. Здесь стояли ▲ ▼ ⬛, и у шрифта редактора их нет — на
	# экране выходили пустые квадраты. Отрисовать их, как иконки в игре, тут нечем: это
	# обычные Button в доке, а не свой Control с _draw; слово же читается всегда и на любой
	# системе. Внутреннее имя режима (второй элемент) при этом не меняется.
	for m in [["RAISE", "raise"], ["LOWER", "lower"], ["FLATTEN", "flatten"]]:
		var b := Button.new()
		b.text = String(m[0])
		b.tooltip_text = String(m[1]).capitalize()
		b.toggle_mode = true
		b.button_group = group
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.button_pressed = sculpt_mode == String(m[1])
		var mode_name := String(m[1])
		b.pressed.connect(func() -> void:
			sculpt_mode = mode_name
			_update_brush_hint()
			update_overlays()
			_save_settings())
		modes.add_child(b)
	panel.add_child(modes)
	radius_slider = _slider_row(panel, "Radius", 1.0, 200.0, brush_radius, 1.0,
			_set_brush_radius, 0)
	strength_slider = _slider_row(panel, "Strength", 0.0, 100.0, brush_power * 100.0, 1.0,
			_set_brush_power, 0)
	_brush_hint = _lbl("")
	_brush_hint.modulate = Color(1, 1, 1, 0.6)   # a caption under the sliders, not a setting
	panel.add_child(_brush_hint)
	_update_brush_hint()
	# ЗДЕСЬ НЕТ И НЕ ДОЛЖНО БЫТЬ НАСТРОЕК ПОКАЗА. Док — это инструмент СОЗДАНИЯ карты: сид,
	# размер, форма, кисть, запекание. Всё, что решает, как карта ВЫГЛЯДИТ (в редакторе или в
	# игре), живёт на самой ноде, в её группах экспортов. Отсюда уехала галочка «Preview detail»:
	# она правила свойство ноды, то есть была здесь гостем. Теперь это `editor_detail` в группе
	# «Editor only», и превью пересобирается прямо по клику в инспекторе.

	# ── World ────────────────────────────────────────────────────────────────
	panel.add_child(_sep())
	panel.add_child(_lbl("── World ──"))

	var seed_row := HBoxContainer.new()
	var seed_spin = SpinBox.new()
	seed_spin.min_value = 0
	seed_spin.max_value = 99999
	seed_spin.value     = gen_seed
	seed_spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	seed_spin.value_changed.connect(func(v: float) -> void:
		gen_seed = int(v)
		_save_settings())
	var dice := Button.new()
	dice.text = "RND"
	dice.tooltip_text = "Random seed"
	dice.pressed.connect(func() -> void:
		seed_spin.value = float(randi() % 100000))     # value_changed does the rest
	seed_row.add_child(_lbl_fixed("Seed"))
	seed_row.add_child(seed_spin)
	seed_row.add_child(dice)
	panel.add_child(seed_row)

	var size_spin = SpinBox.new()
	size_spin.min_value = 0
	size_spin.max_value = 4096
	size_spin.step      = 64
	size_spin.value     = gen_size
	size_spin.tooltip_text = "Map side in cells (0 = keep the current size). One cell is one world unit."
	size_spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_spin.value_changed.connect(func(v: float) -> void:
		gen_size = int(v)
		_save_settings())
	panel.add_child(_row("Size", size_spin))

	_sl_height = _slider_row(panel, "Height", 1.0, 300.0, gen_amplitude, 1.0,
			_set_gen_amplitude, 0)
	_sl_features = _slider_row(panel, "Features", 10.0, 600.0, gen_scale, 1.0,
			func(v: float) -> void: gen_scale = v, 0)
	# ONE KNOB FOR MOUNTAINS: ridge height and ridge sharpness always moved together, and apart
	# they only ever produced a mismatch — a picket fence when sharp ridges met a low map.
	# What it pulls: see _mtn_amount and _ridge_sharp.
	_sl_mountains = _slider_row(panel, "Mountains", 0.0, 1.0, gen_mountains01, 0.05,
			func(v: float) -> void: gen_mountains01 = v, 2)

	# ── The "natural" preset ─────────────────────────────────────────────────
	# Height and feature size are linked, and the link is not something you can eyeball: 300 m of
	# height with 150 m features means slopes steeper than forty-five degrees at every step, and
	# the map reads as a pincushion. The preset sets the proportion where the masses are large and
	# the slopes are drivable. The scale is taken FROM THE BIOMES: when the terrain is larger than
	# their masks, the snow cap lands next to the mountain instead of on it.
	var preset := Button.new()
	preset.text = "Natural preset"
	preset.tooltip_text = "Large masses and drivable slopes. Then press Generate Terrain."
	preset.pressed.connect(func() -> void:
		var b := _biomes()
		gen_amplitude   = 130.0
		gen_scale       = b.mountain_scale if b != null else 420.0
		gen_power       = 2.8
		gen_mountains01 = 0.65
		_save_settings()
		# The handles are moved by hand: without this the slider shows the old number while the
		# generation runs on the new one — a mismatch that takes longer to find than to fix.
		if _sl_height != null: _sl_height.value = gen_amplitude
		if _sl_features != null: _sl_features.value = gen_scale
		if _sl_mountains != null: _sl_mountains.value = gen_mountains01
		_sync_dock())
	panel.add_child(preset)

	var canyon_cb = CheckBox.new()
	canyon_cb.text = "Canyons"
	canyon_cb.button_pressed = gen_canyon_enable
	_cb_canyon = canyon_cb
	canyon_cb.toggled.connect(func(on: bool) -> void:
		gen_canyon_enable = on
		# The same flag drives the COLOUR: the biome resource is what the shader reads, so a
		# world without carved canyons has no terracotta either.
		_biomes().canyon_enabled = on
		_save_settings())
	panel.add_child(canyon_cb)

	var mtn_cb = CheckBox.new()
	mtn_cb.text = "Mountains"
	mtn_cb.button_pressed = _biomes().mountain_enabled
	_cb_mountain = mtn_cb
	mtn_cb.toggled.connect(func(on: bool) -> void:
		_biomes().mountain_enabled = on)
	panel.add_child(mtn_cb)

	# ── Advanced (folded) ────────────────────────────────────────────────────
	var adv_body := VBoxContainer.new()
	adv_body.visible = false
	var adv_btn := Button.new()
	adv_btn.text = "▸ Advanced"
	adv_btn.toggle_mode = true
	adv_btn.toggled.connect(func(on: bool) -> void:
		adv_body.visible = on
		adv_btn.text = ("▾ " if on else "▸ ") + "Advanced")
	panel.add_child(adv_btn)
	panel.add_child(adv_body)

	# ONLY what cannot be derived from the five knobs above lives here: the character of the plains
	# and the shape of the canyon. Everything else has moved out — octaves and blur became
	# constants (they have one sensible answer), ridge height and sharpness collapsed into
	# "Mountains", and mesa tops and canyon floor are derived from Height.
	_slider_row(adv_body, "Plains power", 1.0, 8.0, gen_power, 0.1,
			func(v: float) -> void: gen_power = v, 1)

	adv_body.add_child(_lbl("Canyon shape"))
	# The terrace height lives in the BIOME RESOURCE: the shader colours its strata by the same
	# number, and two copies of it would drift apart into stripes that miss the steps.
	_sl_stratum = _slider_row(adv_body, "Stratum", 2.0, 12.0, _biomes().canyon_band_height, 0.5,
			func(v: float) -> void: _biomes().canyon_band_height = v, 1)
	_slider_row(adv_body, "Riser", 0.1, 0.6, gen_canyon_riser, 0.05,
			func(v: float) -> void: gen_canyon_riser = v, 2)
	_slider_row(adv_body, "Gorge width", 0.03, 0.30, gen_canyon_width, 0.01,
			func(v: float) -> void: gen_canyon_width = v, 2)
	_slider_row(adv_body, "Channels", 30.0, 160.0, gen_canyon_gorge, 1.0,
			func(v: float) -> void: gen_canyon_gorge = v, 0)

	# ── Actions ──────────────────────────────────────────────────────────────
	panel.add_child(_sep())
	var gen_btn = Button.new()
	gen_btn.text = "Generate Terrain"
	gen_btn.tooltip_text = "Rebuilds the whole heightmap from the settings above. Hand sculpting is lost."
	gen_btn.pressed.connect(_generate_noise)
	panel.add_child(gen_btn)
	var warn := _lbl("rebuilds everything — sculpting is lost")
	warn.add_theme_font_size_override("font_size", 10)
	warn.modulate = Color(1, 1, 1, 0.6)
	panel.add_child(warn)

	var bake_btn = Button.new()
	bake_btn.text = "Bake to files"
	bake_btn.tooltip_text = "One click: heightmap (.res) + preview mesh (.res) + greyscale PNG (for a minimap)."
	bake_btn.pressed.connect(_bake_and_export)
	panel.add_child(bake_btn)

	scroll.add_child(panel)
	add_control_to_dock(DOCK_SLOT_LEFT_UL, scroll)

func _exit_tree() -> void:
	# Persist the dock state when the editor closes or the plugin is disabled.
	_save_settings()
	if panel:
		var scroll = panel.get_parent()
		if scroll:
			remove_control_from_docks(scroll)
			scroll.queue_free()
		else:
			remove_control_from_docks(panel)
			panel.queue_free()

# ─────────────────────────────────────────────────
# Sculpt mode callbacks
# ─────────────────────────────────────────────────
# The buttons show the mode themselves (they share a ButtonGroup, exactly one is pressed), which
# is why there is no status line and no three wrapper functions any more.

# ─────────────────────────────────────────────────
# Persist the dock's brush + generation settings across editor sessions.
# Kept in the editor's per-project metadata (.godot/, not the repository), so every visit
# restores the previous state instead of making you dial everything in again.
# ─────────────────────────────────────────────────
const SETTINGS_META_SECTION := "lite_terrain"
const SETTINGS_META_KEY      := "dock_settings"

func _save_settings() -> void:
	var es := EditorInterface.get_editor_settings()
	if es == null:
		return
	es.set_project_metadata(SETTINGS_META_SECTION, SETTINGS_META_KEY, {
		"brush_radius":        brush_radius,
		# A NEW KEY rather than the old brush_strength: that one held METRES per dab, this one a
		# 0..1 share. The two overlap in range, so the old value would be read silently and give a
		# strength nobody asked for.
		"brush_power":         brush_power,
		"sculpt_mode":         sculpt_mode,
		"gen_seed":            gen_seed,
		"gen_scale":           gen_scale,
		"gen_power":           gen_power,
		"gen_amplitude":       gen_amplitude,
		"gen_mountains01":     gen_mountains01,
		"gen_size":            gen_size,
		"gen_canyon_enable":   gen_canyon_enable,
		"gen_canyon_riser":    gen_canyon_riser,
		"gen_canyon_gorge":    gen_canyon_gorge,
		"gen_canyon_width":    gen_canyon_width,
	})

func _load_settings() -> void:
	var es := EditorInterface.get_editor_settings()
	if es == null:
		return
	var d = es.get_project_metadata(SETTINGS_META_SECTION, SETTINGS_META_KEY, {})
	if typeof(d) != TYPE_DICTIONARY:
		return
	brush_radius     = float(d.get("brush_radius",     brush_radius))
	brush_power      = clampf(float(d.get("brush_power", brush_power)), 0.0, 1.0)
	sculpt_mode      = str(d.get("sculpt_mode",        sculpt_mode))
	gen_seed         = int(d.get("gen_seed",           gen_seed))
	gen_scale        = float(d.get("gen_scale",        gen_scale))
	gen_power        = float(d.get("gen_power",        gen_power))
	gen_amplitude    = float(d.get("gen_amplitude",    gen_amplitude))
	gen_mountains01  = float(d.get("gen_mountains01",  gen_mountains01))
	gen_size         = int(d.get("gen_size",           gen_size))
	gen_canyon_enable = bool(d.get("gen_canyon_enable", gen_canyon_enable))
	gen_canyon_riser  = float(d.get("gen_canyon_riser", gen_canyon_riser))
	gen_canyon_gorge  = float(d.get("gen_canyon_gorge", gen_canyon_gorge))
	gen_canyon_width  = float(d.get("gen_canyon_width", gen_canyon_width))

# ─────────────────────────────────────────────────
# Node selection
# ─────────────────────────────────────────────────
func _handles(object) -> bool:
	return object is StaticBody3D or object is CollisionShape3D

func _edit(object) -> void:
	# Switching the selected node drops an uncommitted stroke, so one terrain's "before"
	# snapshot cannot be applied to another.
	_stroke_active = false
	_stroke_before = PackedFloat32Array()
	_have_last_dab = false
	# The rings belong to the terrain that WAS selected: keep them and they would hang over the
	# viewport pointing at nothing until the next mouse move.
	_brush_hit_ok = false
	update_overlays()
	if object is StaticBody3D:
		sculpt_node = object
	elif object is CollisionShape3D:
		sculpt_node = object.get_parent()
	_sync_dock()

## Re-read into the dock whatever lives in the selected node's BIOME RESOURCE. Everything else in
## the dock belongs to the plugin itself: shared, and kept in the project metadata.
func _sync_dock() -> void:
	var b := _biomes()
	if _cb_canyon != null and is_instance_valid(_cb_canyon):
		_cb_canyon.set_pressed_no_signal(b.canyon_enabled)
		# The canyon flag has TWO owners: the resource paints, the generator carves. Sync the
		# second half too, or the box is unchecked while generation still cuts mesas.
		gen_canyon_enable = b.canyon_enabled
	if _cb_mountain != null and is_instance_valid(_cb_mountain):
		_cb_mountain.set_pressed_no_signal(b.mountain_enabled)
	if _sl_stratum != null and is_instance_valid(_sl_stratum):
		# Through .value and NOT set_value_no_signal: the number beside the slider is updated by
		# the signal handler, so without it the handle moves and the label keeps the old value.
		_sl_stratum.value = b.canyon_band_height

# ─────────────────────────────────────────────────
# Viewport input (sculpting)
# ─────────────────────────────────────────────────
func _forward_3d_gui_input(viewport_camera: Camera3D, event: InputEvent) -> int:
	if sculpt_node == null:
		return EditorPlugin.AFTER_GUI_INPUT_PASS

	# Feed the editor camera so map.gd can drive its editor LOD (editor_lod).
	if sculpt_node.has_method("set_editor_camera"):
		sculpt_node.set_editor_camera(viewport_camera)

	# Track the point under the cursor even with no button held: that is what the brush rings
	# are drawn around. Doing it here (and not only while painting) is the whole point — the
	# brush has to be visible BEFORE the click, otherwise its size is a guess.
	if event is InputEventMouseMotion:
		_brush_cam = viewport_camera
		var over = _ray_ground(viewport_camera, event.position)
		_brush_hit_ok = over != null
		if _brush_hit_ok:
			_brush_hit = over
		update_overlays()

	if event is InputEventMouseButton:
		# The wheel sizes the brush. Its range matches the slider (1..200), otherwise scrolling
		# would knock a large radius back down to 20. The step scales with the radius so big
		# brushes are reachable in a sane number of turns.
		if event.button_index == MOUSE_BUTTON_WHEEL_UP and event.pressed:
			brush_radius = clamp(brush_radius + maxf(1.0, brush_radius * 0.15), 1.0, 200.0)
			radius_slider.value = brush_radius   # its handler refreshes the hint and the rings
			return EditorPlugin.AFTER_GUI_INPUT_STOP
		if event.button_index == MOUSE_BUTTON_WHEEL_DOWN and event.pressed:
			brush_radius = clamp(brush_radius - maxf(1.0, brush_radius * 0.15), 1.0, 200.0)
			radius_slider.value = brush_radius
			return EditorPlugin.AFTER_GUI_INPUT_STOP

		if (event.button_index == MOUSE_BUTTON_LEFT or event.button_index == MOUSE_BUTTON_RIGHT) and not event.pressed:
			if _dirty_chunks.size() > 0 and sculpt_node and sculpt_node.has_method("update_chunks"):
				sculpt_node.update_chunks(_dirty_chunks.keys())
				_dirty_chunks.clear()
			# The stroke ends when the button is released and no OTHER brush button is held.
			var other := MOUSE_BUTTON_RIGHT if event.button_index == MOUSE_BUTTON_LEFT else MOUSE_BUTTON_LEFT
			if not Input.is_mouse_button_pressed(other):
				_have_last_dab = false            # the next stroke starts with clean spacing
				if _stroke_active:
					_commit_stroke_undo()
			return EditorPlugin.AFTER_GUI_INPUT_PASS

	if event is InputEventMouseMotion or event is InputEventMouseButton:
		var left  = Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)
		var right = Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT)

		if not left and not right:
			return EditorPlugin.AFTER_GUI_INPUT_PASS

		var hit = _ray_ground(viewport_camera, event.position)
		if hit == null:
			return EditorPlugin.AFTER_GUI_INPUT_PASS
		var hit_pos: Vector3 = hit

		var raise = left
		if sculpt_mode == "lower":
			raise = false
		elif sculpt_mode == "raise":
			raise = true

		# Spacing: skip the dab unless the cursor has moved a fraction of the radius from the
		# last one. The first dab of a stroke always lands (_have_last_dab = false). The event
		# is consumed either way (STOP) so the camera does not drift while painting.
		var spacing := maxf(1.0, brush_radius * DAB_SPACING_FRAC)
		if _have_last_dab and hit_pos.distance_to(_last_dab_pos) < spacing:
			return EditorPlugin.AFTER_GUI_INPUT_STOP
		_last_dab_pos = hit_pos
		_have_last_dab = true

		_sculpt(hit_pos, raise)
		return EditorPlugin.AFTER_GUI_INPUT_STOP

	return EditorPlugin.AFTER_GUI_INPUT_PASS

## The ground point under a viewport position, or null. ONE function for both worlds: the dab
## and the brush cursor have to agree on where the brush is, and two copies of this would drift
## apart the moment one of the two modes changed.
func _ray_ground(cam: Camera3D, screen_pos: Vector2) -> Variant:
	if sculpt_node == null or cam == null:
		return null
	var ray_origin := cam.project_ray_origin(screen_pos)
	var ray_dir    := cam.project_ray_normal(screen_pos)
	if sculpt_node.has_method("is_image_mode") and sculpt_node.is_image_mode():
		# Image mode: hit the heightmap by ray-marching it — no physics shape needed.
		return sculpt_node.raycast_heightmap(ray_origin, ray_dir)
	# sculpt_node is untyped (it is whatever the editor selected), so nothing here can be
	# inferred with := — the parser refuses to guess a type off a Variant call.
	var space: PhysicsDirectSpaceState3D = sculpt_node.get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(ray_origin, ray_origin + ray_dir * 1000.0)
	query.collide_with_bodies = true
	var result: Dictionary = space.intersect_ray(query)
	if result.is_empty():
		return null
	return result.position

# ─────────────────────────────────────────────────
# Brush cursor: TWO rings, drawn OVER the viewport
# ─────────────────────────────────────────────────
# There was no brush cursor at all: the radius was a number in the dock, and where it landed was
# only visible after the dab. Rings are drawn as 2D over the viewport rather than as a mesh in
# the scene — a mesh would need a node, a material and a place in the tree of somebody else's
# scene, and would still be hidden by the very hill being sculpted.
#
# TWO rings, because strength now depends on the radius (see SCULPT_REF_RADIUS): the outer one is
# the reach, where the falloff has run down to zero, and the inner one is the core that moves by
# the full step. The inner one is a TENTH of the outer, which is exactly the ratio in the
# strength rule — a radius-100 brush shows what a radius-10 brush would cover.
const BRUSH_CORE_FRAC := 0.1
const BRUSH_RING_SEGS := 56

var _brush_cam: Camera3D = null
var _brush_hit: Vector3 = Vector3.ZERO
var _brush_hit_ok := false

func _forward_3d_draw_over_viewport(overlay: Control) -> void:
	if not _brush_hit_ok or sculpt_node == null:
		return
	if _brush_cam == null or not is_instance_valid(_brush_cam):
		return
	var col := Color(0.35, 1.0, 0.55, 0.9)          # raise
	if sculpt_mode == "lower":
		col = Color(1.0, 0.5, 0.25, 0.9)
	elif sculpt_mode == "flatten":
		col = Color(0.45, 0.75, 1.0, 0.9)
	_draw_ring(overlay, brush_radius, col, 2.0)
	_draw_ring(overlay, brush_radius * BRUSH_CORE_FRAC, Color(col, 0.45), 1.0)

## One ring, laid ON the ground rather than on a flat disc: on a slope a flat circle sinks into
## the hill and stops saying anything about what the brush will touch.
func _draw_ring(overlay: Control, radius: float, col: Color, width: float) -> void:
	if radius < 0.05:
		return
	var pts := PackedVector2Array()
	for i in BRUSH_RING_SEGS + 1:
		var a := TAU * float(i) / float(BRUSH_RING_SEGS)
		var p := _brush_hit + Vector3(cos(a) * radius, 0.0, sin(a) * radius)
		if sculpt_node.has_method("terrain_height_at"):
			p.y = sculpt_node.terrain_height_at(p)
		# A point BEHIND the camera unprojects to a mirrored dot in front of it, and joining it
		# to its neighbours throws a stray line across the whole viewport. Break the line there.
		if _brush_cam.is_position_behind(p):
			if pts.size() > 1:
				overlay.draw_polyline(pts, col, width)
			pts = PackedVector2Array()
			continue
		pts.append(_brush_cam.unproject_position(p))
	if pts.size() > 1:
		overlay.draw_polyline(pts, col, width)

# ─────────────────────────────────────────────────
# Sculpt brush
# ─────────────────────────────────────────────────
func _sculpt(hit_pos: Vector3, raise: bool) -> void:
	# Image mode: edit the heightmap array directly, no HeightMapShape3D involved.
	if sculpt_node.has_method("is_image_mode") and sculpt_node.is_image_mode():
		# Start of a stroke: snapshot the heights BEFORE any edits, once per stroke, for undo.
		if not _stroke_active:
			_stroke_before = sculpt_node.get_heights().duplicate()
			_stroke_active = true
		var mode_int := 0
		if sculpt_mode != "flatten":
			mode_int = 1 if raise else -1
		# Two different quantities behind one argument: metres for raise/lower, a blend weight
		# for flatten. apply_brush uses it accordingly, so pick it here by mode.
		var power: float = _brush_weight() if mode_int == 0 else _brush_step()
		var dirty: PackedInt32Array = sculpt_node.apply_brush(
				hit_pos, brush_radius, power, mode_int)
		for ci in dirty:
			_dirty_chunks[ci] = true
		return

	var col_shape = sculpt_node.get_node("CollisionShape3D")
	if col_shape == null:
		return
	var shape = col_shape.shape
	if not shape is HeightMapShape3D:
		return

	var width        = shape.map_width
	var depth        = shape.map_depth
	var map_data_old = shape.map_data.duplicate()
	var map_data     = shape.map_data

	var local_pos = sculpt_node.to_local(hit_pos)
	var cx = int(local_pos.x + width / 2.0)
	var cz = int(local_pos.z + depth / 2.0)

	var r     = int(ceil(brush_radius))
	var x_min = clamp(cx - r, 0, width - 1)
	var x_max = clamp(cx + r, 0, width - 1)
	var z_min = clamp(cz - r, 0, depth - 1)
	var z_max = clamp(cz + r, 0, depth - 1)

	if sculpt_mode == "flatten":
		var avg_height = 0.0
		var count      = 0
		for z in range(z_min, z_max + 1):
			for x in range(x_min, x_max + 1):
				var dx = x - cx
				var dz = z - cz
				if sqrt(dx*dx + dz*dz) <= brush_radius:
					avg_height += map_data[z * width + x]
					count += 1
		if count > 0:
			avg_height /= count
		for z in range(z_min, z_max + 1):
			for x in range(x_min, x_max + 1):
				var dx   = x - cx
				var dz   = z - cz
				var dist = sqrt(dx*dx + dz*dz)
				if dist <= brush_radius:
					var falloff = 1.0 - (dist / brush_radius)
					var index   = z * width + x
					# Keep the lerp weight in [0,1], as in image mode: an unclamped *5 overshot
					# the average at high strength and wrecked the map.
					map_data[index] = lerp(map_data[index], avg_height, clampf(falloff * _brush_weight(), 0.0, 1.0))
	else:
		var step := _brush_step()
		for z in range(z_min, z_max + 1):
			for x in range(x_min, x_max + 1):
				var dx   = x - cx
				var dz   = z - cz
				var dist = sqrt(dx*dx + dz*dz)
				if dist <= brush_radius:
					var falloff = 1.0 - (dist / brush_radius)
					var index   = z * width + x
					if raise:
						map_data[index] += step * falloff
					else:
						map_data[index] -= step * falloff

	var ur = get_undo_redo()
	ur.create_action("Sculpt Terrain", UndoRedo.MERGE_ALL)
	ur.add_do_property(shape, "map_data", map_data)
	ur.add_undo_property(shape, "map_data", map_data_old)
	ur.commit_action()

	if sculpt_node.has_method("get_chunk_info"):
		var info      = sculpt_node.get_chunk_info()
		var cs        = info["chunk_size"]
		var chunks_x  = info["chunks_x"]
		var map_w     = info["map_width"]
		var map_d     = info["map_depth"]
		var chunks_z  = ceili(float(map_d - 1) / cs)
		var total_chunks = chunks_x * chunks_z
		var cx_center = int(local_pos.x + map_w / 2.0) / cs
		var cz_center = int(local_pos.z + map_d / 2.0) / cs
		var cr        = int(ceil(brush_radius / cs)) + 1
		for dz in range(-cr, cr + 1):
			for dx in range(-cr, cr + 1):
				var ci = (cz_center + dz) * chunks_x + (cx_center + dx)
				if ci >= 0 and ci < total_chunks:
					_dirty_chunks[ci] = true

# ─────────────────────────────────────────────────
# End of an image-mode stroke → one undo/redo step.
# The "before" snapshot was taken when the stroke began; here we take "after" and register an
# action that swaps the whole heightmap between the two. Ctrl+Z restores "before", Ctrl+Y
# "after". set_heightmap rebuilds the preview in full, and _persist_heightmap rewrites the
# .res so the disk keeps up with undo/redo.
# ─────────────────────────────────────────────────
func _commit_stroke_undo() -> void:
	_stroke_active = false
	if sculpt_node == null or not (sculpt_node.has_method("is_image_mode") and sculpt_node.is_image_mode()):
		return
	var after: PackedFloat32Array = sculpt_node.get_heights().duplicate()
	if _stroke_before.size() != after.size() or after.is_empty():
		return
	if _stroke_before == after:      # the stroke changed nothing — do not litter the history
		return
	var dims: Vector2i = sculpt_node.get_dims()
	var ur = get_undo_redo()
	ur.create_action("Sculpt Terrain", UndoRedo.MERGE_DISABLE, sculpt_node)
	ur.add_do_method(sculpt_node, "set_heightmap", after, dims.x, dims.y)
	ur.add_do_method(self, "_persist_heightmap")
	ur.add_undo_method(sculpt_node, "set_heightmap", _stroke_before, dims.x, dims.y)
	ur.add_undo_method(self, "_persist_heightmap")
	# execute=false: the live md already equals "after", so there is no need to rebuild now.
	ur.commit_action(false)
	# ...but the .res on disk is still "before" — sync it once, after the stroke.
	_persist_heightmap()
	_stroke_before = PackedFloat32Array()

# Rewrites the R32F heightmap into the file the node loads (its heightmap_path), so the disk
# keeps up with sculpting and undo/redo. Without it, edits would live in memory until Bake.
func _persist_heightmap() -> void:
	if sculpt_node == null or not sculpt_node.has_method("get_heights"):
		return
	var data: PackedFloat32Array = sculpt_node.get_heights()
	var dims: Vector2i = sculpt_node.get_dims()
	if dims.x <= 0 or dims.y <= 0 or data.size() != dims.x * dims.y:
		return
	var img := Image.create_from_data(dims.x, dims.y, false, Image.FORMAT_RF, data.to_byte_array())
	ResourceSaver.save(img, _heightmap_target())

# ─────────────────────────────────────────────────
# Bake the sculpted HeightMapShape3D into an R32F image
# ─────────────────────────────────────────────────
# map.gd loads this image at runtime as the heightmap source of truth and builds a
# small streaming collision window from it — so the map can be huge without the giant
# HeightMapShape3D physics body. Run this whenever you change the terrain in-editor.
const HEIGHTMAP_PATH := "res://addons/LiteTerrain/terrain_height.res"
const MESH_PATH      := "res://addons/LiteTerrain/terrain_mesh.res"

# Where the heightmap goes: ALWAYS the selected node's heightmap_path. Otherwise baking and
# generation write to one place while the node loads from another, and the terrain comes back
# empty after a reopen. Falls back to the constant when the node's path is blank.
func _heightmap_target() -> String:
	if sculpt_node != null:
		var p := str(sculpt_node.get("heightmap_path"))
		if p != "":
			return p
	return HEIGHTMAP_PATH

# The heightmap PNG goes next to the heightmap itself (in the heightmap_path folder) rather
# than the project root, so the plugin does not litter someone else's res://.
func _heightmap_png_target() -> String:
	return _heightmap_target().get_base_dir().path_join("terrain_heightmap.png")

# One "Bake -> files" button: heightmap, preview mesh and PNG in a single click.
## ЗАПЕКАНИЕ ТОЖЕ ПОД ОКНОМ. Оно пишет четыре файла подряд, и три из них — полный проход по
## карте (таблица мин/макс на чанк, дамп высот, перевод высот в серый PNG). На 1984² это
## секунды-десятки секунд молчания с застывшим редактором, неотличимые от зависания; а кнопка
## одна, и понять, на каком она файле, было неоткуда. Между файлами отдаём кадр редактору —
## тогда полоса и подпись успевают перерисоваться.
##
## Тот же флаг _generating, что и у генерации: окно прогресса одно на двоих, и запустить
## запекание поверх генерации значило бы, что один закроет окно другого.
func _bake_and_export() -> void:
	if sculpt_node == null:
		push_warning("LiteTerrain: select the terrain StaticBody3D node first")
		return
	if _generating:
		return
	_generating = true
	_progress_open(false)
	_progress_say("Heightmap (.res)", 0.0)
	await get_tree().process_frame
	_bake_heightmap()
	_progress_say("Greyscale PNG", 0.75)
	await get_tree().process_frame
	_generate_png()
	_progress_say("Done", 1.0)
	await get_tree().process_frame
	_progress_close()

func _bake_heightmap() -> void:
	if sculpt_node == null:
		push_warning("LiteTerrain: select the terrain StaticBody3D node first")
		return

	var width: int
	var depth: int
	var data: PackedFloat32Array

	if sculpt_node.has_method("is_image_mode") and sculpt_node.is_image_mode():
		# Image mode: the heights live in md, not in the CollisionShape3D.
		var dims: Vector2i = sculpt_node.get_dims()
		width  = dims.x
		depth  = dims.y
		data   = sculpt_node.get_heights()
	else:
		var col_shape = sculpt_node.get_node_or_null("CollisionShape3D")
		if col_shape == null or not (col_shape.shape is HeightMapShape3D):
			push_warning("LiteTerrain: no HeightMapShape3D found on the selected node")
			return
		var shape = col_shape.shape
		width = shape.map_width
		depth = shape.map_depth
		data  = shape.map_data

	if width <= 0 or depth <= 0 or data.size() != width * depth:
		push_error("LiteTerrain: bad heightmap (%d values for %dx%d) — nothing baked" % [data.size(), width, depth])
		return
	# ── Physical: R32F heightmap image (runtime data + streaming collision) ──────
	# Exact round-trip with md = img.get_data().to_float32_array().
	var img := Image.create_from_data(width, depth, false, Image.FORMAT_RF, data.to_byte_array())
	var hm_path := _heightmap_target()
	var err := ResourceSaver.save(img, hm_path)
	if err == OK:
		print("LiteTerrain: baked heightmap %dx%d -> %s" % [width, depth, hm_path])
	else:
		push_error("LiteTerrain: failed to save heightmap (error %d)" % err)
	_bake_stream_file(width, depth, data)

## STREAMABLE COPY OF THE HEIGHTS, next to the .res image.
##
## An Image resource can only be loaded WHOLE: to read the heights around the player you must
## first hold the entire map in memory, which is what caps the map size. This file is raw rows
## of float32 with a header, so any rectangle is a seek and a read — that is the whole point,
## and it is why the runtime prefers it even today, when it still reads all of it: a raw read
## costs one allocation instead of "load resource → convert format → to_float32_array".
##
## It also carries a per-chunk MIN/MAX table. Whoever streams regions still has to know how
## high the ground is everywhere — the LOD tree needs a bounding box per chunk before a single
## height near it is loaded — and a table of two floats per chunk is a rounding error next to
## the heights themselves (some 120 KB for a 1984² map).
const STREAM_MAGIC := 0x4C545331          # "LTS1"
const STREAM_EXT := ".bin"

func _bake_stream_file(width: int, depth: int, data: PackedFloat32Array) -> void:
	var path: String = _heightmap_target().get_basename() + STREAM_EXT
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_error("LiteTerrain: could not write %s" % path)
		return
	var cs: int = 16
	if sculpt_node != null and "chunk_size" in sculpt_node:
		cs = maxi(int(sculpt_node.chunk_size), 1)
	var cx: int = ceili(float(width - 1) / float(cs))
	var cz: int = ceili(float(depth - 1) / float(cs))
	f.store_32(STREAM_MAGIC)
	f.store_32(width)
	f.store_32(depth)
	f.store_32(cs)
	# The per-chunk min/max table comes BEFORE the heights: it is read whole and at once, while the
	# heights are read in pieces.
	var mins := PackedFloat32Array()
	var maxs := PackedFloat32Array()
	mins.resize(cx * cz)
	maxs.resize(cx * cz)
	for i in cx * cz:
		mins[i] = INF
		maxs[i] = -INF
	for z in depth:
		var row := z * width
		var czi: int = mini(z / cs, cz - 1)
		for x in width:
			var h: float = data[row + x]
			var ci: int = czi * cx + mini(x / cs, cx - 1)
			if h < mins[ci]:
				mins[ci] = h
			if h > maxs[ci]:
				maxs[ci] = h
	f.store_buffer(mins.to_byte_array())
	f.store_buffer(maxs.to_byte_array())
	f.store_buffer(data.to_byte_array())
	f.close()
	print("LiteTerrain: streamable heights %dx%d (chunk %d) -> %s (%.1f MB)"
			% [width, depth, cs, path, float(data.size()) * 4.0 / 1048576.0])

	# ── Visual: editor preview mesh → external .res ──────────────────────────────
	# Without this the generated ArrayMesh is unique-to-scene and gets embedded into the
	# .tscn on save (bloat + manual re-link each time). take_over_path() makes the live
	# mesh point at the file, so the scene just references it externally.
	var mi = sculpt_node.get_node_or_null("MeshInstance3D")
	if mi != null and mi.mesh != null:
		var merr := ResourceSaver.save(mi.mesh, MESH_PATH)
		if merr == OK:
			mi.mesh.take_over_path(MESH_PATH)
			print("LiteTerrain: baked visual mesh → %s" % MESH_PATH)
		else:
			push_error("LiteTerrain: failed to save visual mesh (error %d)" % merr)
	else:
		push_warning("LiteTerrain: MeshInstance3D has no mesh to bake yet")

# The "Create Terrain Node" button adds a SINGLE LiteTerrain node. It creates its own
# CollisionShape3D and MeshInstance3D (_ensure_children); we never assemble those by hand.
const TERRAIN_SCRIPT   := "res://addons/LiteTerrain/map.gd"
const NEW_MAP_SIZE     := 128
const PLUGIN_HEIGHTMAP := "res://addons/LiteTerrain/terrain_height.res"

func _create_terrain() -> void:
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		push_warning("LiteTerrain: open a scene first")
		return
	var script := load(TERRAIN_SCRIPT)
	if script == null:
		push_error("LiteTerrain: could not find %s" % TERRAIN_SCRIPT)
		return

	# A flat starting heightmap in the addon folder, so image mode works out of the box.
	var flat := PackedFloat32Array()
	flat.resize(NEW_MAP_SIZE * NEW_MAP_SIZE)
	var img := Image.create_from_data(NEW_MAP_SIZE, NEW_MAP_SIZE, false, Image.FORMAT_RF, flat.to_byte_array())
	ResourceSaver.save(img, PLUGIN_HEIGHTMAP)
	EditorInterface.get_resource_filesystem().scan()

	var body := StaticBody3D.new()
	body.name = "LiteTerrain"
	body.set_script(script)
	body.set("heightmap_path", PLUGIN_HEIGHTMAP)

	var parent: Node = root
	var sel := EditorInterface.get_selection().get_selected_nodes()
	if sel.size() > 0 and sel[0] is Node:
		parent = sel[0]

	# One node. It creates its CollisionShape3D and MeshInstance3D as INTERNAL children (they
	# stay out of the scene tree) and builds the preview in _ready from the flat baked map.
	var ur := get_undo_redo()
	ur.create_action("Create Terrain")
	ur.add_do_method(parent, "add_child", body)
	ur.add_do_method(body, "set_owner", root)
	ur.add_do_reference(body)
	ur.add_undo_method(parent, "remove_child", body)
	ur.commit_action()

	EditorInterface.get_selection().clear()
	EditorInterface.get_selection().add_node(body)
	print("LiteTerrain: created a LiteTerrain node (%dx%d, image mode). Next: Generate or Sculpt." % [NEW_MAP_SIZE, NEW_MAP_SIZE])

# ─────────────────────────────────────────────────
# Exports the heightmap as a greyscale PNG (heights normalised into 0..255) — useful for a
# minimap or for editing elsewhere. The data is sourced exactly as baking sources it.
# ─────────────────────────────────────────────────
func _generate_png() -> void:
	if sculpt_node == null:
		push_warning("LiteTerrain: select a terrain node")
		return
	var width: int
	var depth: int
	var data: PackedFloat32Array
	if sculpt_node.has_method("is_image_mode") and sculpt_node.is_image_mode():
		var dims: Vector2i = sculpt_node.get_dims()
		width = dims.x
		depth = dims.y
		data  = sculpt_node.get_heights()
	else:
		var col = sculpt_node.get_node_or_null("CollisionShape3D")
		if col == null or not (col.shape is HeightMapShape3D):
			push_warning("LiteTerrain: no HeightMapShape3D")
			return
		width = col.shape.map_width
		depth = col.shape.map_depth
		data  = col.shape.map_data
	if width <= 0 or depth <= 0 or data.size() != width * depth:
		push_error("LiteTerrain: bad heightmap (%d values for %dx%d)" % [data.size(), width, depth])
		return

	var mn := INF
	var mx := -INF
	for h in data:
		mn = minf(mn, h)
		mx = maxf(mx, h)
	var rng := maxf(mx - mn, 0.0001)

	# ЧЕРЕЗ БАЙТОВЫЙ БУФЕР, А НЕ set_pixel. Тот на каждый пиксель собирает Color и уходит в
	# движок через Variant: на карте 1984² это без малого четыре миллиона таких вызовов, то
	# есть минуты — и всё это молча, потому что до окна прогресса дело не доходило. Здесь
	# байты пишутся в заранее выделенный массив, а картинка собирается из него одним вызовом.
	var bytes := PackedByteArray()
	bytes.resize(width * depth)
	var k: float = 255.0 / rng
	for i in width * depth:
		bytes[i] = clampi(int((data[i] - mn) * k), 0, 255)
	var img := Image.create_from_data(width, depth, false, Image.FORMAT_L8, bytes)

	var png_path := _heightmap_png_target()
	var err := img.save_png(png_path)
	if err == OK:
		print("LiteTerrain: heightmap PNG %dx%d -> %s (min %.1f, max %.1f)" % [width, depth, png_path, mn, mx])
		EditorInterface.get_resource_filesystem().scan()
	else:
		push_error("LiteTerrain: could not save the PNG (error %d)" % err)

# ─────────────────────────────────────────────────
# Noise terrain generation
# ─────────────────────────────────────────────────
func _generate_noise() -> void:
	_save_settings()   # commit the current generation parameters to disk
	if sculpt_node == null:
		push_warning("LiteTerrain: select a terrain StaticBody3D node first")
		return
	# A SECOND RUN ON TOP OF THE FIRST is a reliable way to get mush: generation now proceeds in
	# frames, and both runs would write into the same buffers. _progress_close clears the flag, so
	# it is reset on every exit, error paths included.
	if _generating:
		return
	_generating = true
	# The window opens BEFORE the first heavy line: generation runs in frames (see _run_rows), and
	# everything below has to close it on every exit or the editor stays covered.
	_progress_open()
	_progress_say("Preparing", 0.0)
	await get_tree().process_frame

	var image_mode: bool = sculpt_node.has_method("is_image_mode") and sculpt_node.is_image_mode()
	var width: int
	var depth: int
	var shape = null
	var map_data_old := PackedFloat32Array()

	if image_mode:
		# Size from the Map Size field (0 = keep current). This is how the map grows.
		var dims: Vector2i = sculpt_node.get_dims()
		width  = gen_size if gen_size > 0 else dims.x
		depth  = gen_size if gen_size > 0 else dims.y
		if width  <= 0: width  = 512
		if depth  <= 0: depth  = 512
	else:
		var col_shape = sculpt_node.get_node_or_null("CollisionShape3D")
		if col_shape == null:
			push_warning("LiteTerrain: no CollisionShape3D child found")
			_progress_close()
			return
		shape = col_shape.shape
		if not shape is HeightMapShape3D:
			push_warning("LiteTerrain: shape is not a HeightMapShape3D")
			_progress_close()
			return
		width = shape.map_width
		depth = shape.map_depth
		map_data_old = shape.map_data.duplicate()

	# Minimum map size: anything under two chunks produces degenerate chunks and errors.
	width  = maxi(width, 32)
	depth  = maxi(depth, 32)

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
	_gen_biomes = _biomes()        # snapshot BEFORE the threads start; read-only from here
	# THE SEED MOVES THE BIOMES TOO. Their masks are built on hash noise with fixed offsets, so a
	# new seed used to give new hills IN THE SAME desert with the canyon in the same corner: the
	# world changed shape but not geography. The offset is stored in the RESOURCE — the shader
	# paints from it and the game lays out its ore veins from it, so they cannot drift apart from
	# the generator.
	_gen_biomes.mask_offset = TerrainBiomes.offset_for_seed(gen_seed)
	# EVERYTHING DERIVED IN ONE PLACE, BEFORE THE FIRST PASS. Threads come next, and they only
	# read these fields.
	_gen_mtn_amount = _mtn_amount()
	_gen_ridge_sharp = _ridge_sharp()
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
		_progress_close()
		return
	await _run_rows(_gen_fill_row, depth, "Heights", 0.02, 0.5)
	# STOP IS CHECKED BETWEEN PASSES, and every check leaves without writing anything: a map
	# half-generated is worse than the old one, and the file on disk must stay usable.
	if _gen_cancel:
		_progress_close()
		return
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
		await _run_rows(_gen_blur_row, depth, "Smoothing", 0.5, 0.62)
		if _gen_cancel:
			_progress_close()
			return
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
			await _run_rows(_gen_carve_row, depth, "Canyons", 0.62, 0.95)
			if _gen_cancel:
				_progress_close()
				return
			new_data = _gen_carved
		_gen_carved = PackedFloat32Array()
		_gen_base_in = PackedFloat32Array()

	if image_mode:
		# THE LAST STAGE IS THE LONGEST ONE, and it used to be a single blocking call with the bar
		# frozen at 96 %: setting the heights rebuilt the whole editor preview inside
		# set_heightmap, and nothing could redraw meanwhile. Indistinguishable from a hang — which
		# is exactly what it was reported as. Now it is split, and every part says what it is
		# doing: heights, file, chunks (with a moving bar), mesh.
		_progress_say("Writing the heights", 0.955)
		await get_tree().process_frame
		sculpt_node.set_heightmap(new_data, width, depth, false)   # false: превью соберём сами
		var img := Image.create_from_data(width, depth, false, Image.FORMAT_RF, new_data.to_byte_array())
		var gm_path := _heightmap_target()
		var gerr := ResourceSaver.save(img, gm_path)
		if gerr == OK:
			print("LiteTerrain: generated %dx%d -> %s" % [width, depth, gm_path])
		else:
			push_error("LiteTerrain: failed to save generated heightmap (error %d)" % gerr)
		# ПОТОКОВЫЙ .bin ПИШЕМ ЗДЕСЬ ЖЕ. Игра читает его РАНЬШЕ картинки (см. map._load_heightmap:
		# user:// → res://….bin → res://….res), поэтому генерация, обновлявшая только .res,
		# оставляла на диске СТАРУЮ карту: в редакторе новая, в игре прежняя, и понять это можно
		# было только по коду. Два файла об одной карте обязаны меняться вместе.
		_progress_say("Streamable heights (.bin)", 0.955)
		await get_tree().process_frame
		_bake_stream_file(width, depth, new_data)
		await _rebuild_preview_with_progress(0.96, 0.99)
		_progress_say("Done", 1.0)
		await get_tree().process_frame
		_progress_close()
		return

	# ── Legacy (shape) undo/redo + apply ─────────
	# Route BOTH the do and the undo through the node's apply_heightmap() so the whole
	# action lives in the scene-node history. (Mixing add_do_property on the heightmap
	# resource with add_do_method on the node caused "UndoRedo history mismatch".)
	# custom_context = sculpt_node pins the action to the node's history as well.
	var ur = get_undo_redo()
	ur.create_action("Generate Terrain Noise", UndoRedo.MERGE_DISABLE, sculpt_node)
	ur.add_do_method(sculpt_node, "apply_heightmap", new_data)
	ur.add_undo_method(sculpt_node, "apply_heightmap", map_data_old)
	ur.commit_action()
	_progress_close()
