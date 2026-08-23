@tool
extends EditorPlugin

var sculpt_node     = null
var brush_radius    = 3.0
var brush_strength  = 0.1
var sculpt_mode     = "raise"
var panel           = null
var radius_slider   = null
# Живые ссылки на те виджеты, значения которых живут НЕ в плагине, а в биом-ресурсе выбранной
# ноды. Их надо пере-читать при смене выделения (см. _sync_dock), иначе галочка показывает
# состояние предыдущего рельефа — или вовсе запасного ресурса, если при открытии дока ничего
# выбрано не было.
var _cb_canyon: CheckBox = null
var _cb_mountain: CheckBox = null
var _sl_stratum: HSlider = null
var strength_slider = null

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

# ---------- Noise generation parameters ----------
var gen_seed:             int   = 42
var gen_scale:           float  = 150.0   # continental frequency scale
var gen_octaves:          int   = 6       # FBM octaves
var gen_power:           float  = 2.6
var gen_mountain_amount: float  = 0.8    # ridge contribution
var gen_ridge_sharpness: float  = 2.5    # how knife-sharp ridges are
var gen_amplitude:       float  = 30.0   # max height in world units
var gen_smooth:           int   = 1      # blur passes after generation
var gen_size:             int   = 0      # image-mode target size (0 = keep current)

# ---------- Canyon carving (baked into the heights AFTER the blur, so the walls stay sheer) ----------
# The canyon shape is driven by the same mask as the canyon biome's colour (TerrainBiomes),
# so the landform and the colour line up on their own.
var gen_canyon_enable:    bool  = true
var gen_canyon_plateau:   float = 46.0   # top of the TALLEST mesas (lower ones follow the butte noise)
var gen_canyon_floor:     float = 6.0    # absolute level of the canyon floor
var gen_canyon_riser:     float = 0.30   # share of a step taken by the steep riser (0.30 → 70% flat, drivable tread)
var gen_canyon_gorge:     float = 70.0   # frequency of the gorge network (lower = more channels)
var gen_canyon_width:     float = 0.10   # width of the gorge floor, in noise units (larger = wider)
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
var _gen_mesa_min: float = 0.0

# One row z of a blur pass. Reads _gen_base_in (the previous pass) and writes _gen_out, so no
# thread ever reads what another is writing. The border rows are copied through untouched — the
# 5-tap kernel has no neighbours there.
func _gen_blur_row(z: int) -> void:
	var w := _gen_w
	var row := z * w
	if z == 0 or z == _gen_d - 1:
		for x in w:
			_gen_out[row + x] = _gen_base_in[row + x]
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

# One row z of the height fill (WorkerThreadPool.add_group_task calls this per row).
func _gen_fill_row(z: int) -> void:
	var w := _gen_w
	var hw := float(w) * 0.5
	var hd := float(_gen_d) * 0.5
	var fz := float(z)
	var row := z * w
	for x in w:
		var fx := float(x)
		var base = (_gen_base.get_noise_2d(fx, fz) + 1.0) * 0.5
		var continental:float = pow(base, gen_power)
		var ridge = pow(1.0 - abs(_gen_ridge.get_noise_2d(fx, fz)), gen_ridge_sharpness)
		var mountain_mask = smoothstep(0.52, 0.78, continental)
		var ridge_term = ridge * gen_mountain_amount * mountain_mask
		var wx := fx - hw
		var wz := fz - hd
		var wp := Vector2(wx, wz)
		var b := _gen_biomes
		if b.canyon_enabled and ridge_term > 0.001:
			ridge_term *= 1.0 - b.canyon_mask(wp, _cv_noise)
		var sand_m := 1.0 - b.meadow_mask(wp, _cv_noise)
		var mtn_mask := b.mountain_mask(wp, _cv_noise)
		var mtn_dome := b.mountain_dome(wp, _cv_noise)
		var not_mtn := 1.0 - mtn_mask
		var land_sand := sand_m * not_mtn
		var cont_biome := continental * lerpf(1.0, b.desert_flatten, land_sand)
		var h = cont_biome + ridge_term * not_mtn
		var duneph := wx / b.dune_wavelength + _gen_dune.get_noise_2d(fx, fz) * 3.5
		var dune := pow(0.5 + 0.5 * sin(duneph), 1.4) * b.dune_amp * land_sand
		var mtn_rise := mtn_dome * b.mountain_rise + _gen_dune.get_noise_2d(fx * 1.7, fz * 1.7) * 4.0 * mtn_mask
		_gen_out[row + x] = h * gen_amplitude + dune + mtn_rise

# One row z of the canyon carve (reads _gen_base_in, writes _gen_carved).
func _gen_carve_row(z: int) -> void:
	var w := _gen_w
	var hw := float(w) * 0.5
	var hd := float(_gen_d) * 0.5
	var fz := float(z)
	var b := _gen_biomes
	var terr: float = maxf(b.canyon_band_height, 0.5)
	for x in w:
		var idx := z * w + x
		var wx := float(x) - hw
		var wz := fz - hd
		var wp := Vector2(wx, wz)
		if b.canyon_mask(wp, _cv_noise) <= 0.001:
			continue
		var cn := _cv_noise(wp / b.canyon_scale + TerrainBiomes.CANYON_OFFSET)
		var hmask := smoothstep(b.canyon_threshold - 0.02, b.canyon_threshold + 0.02, cn)
		var bt := _cv_noise(wp / b.canyon_butte_scale + Vector2(300.0, 300.0))
		var mesa_top: float = lerpf(_gen_mesa_min, gen_canyon_plateau, bt)
		var gv := absf(_gen_gorge.get_noise_2d(wx, wz))
		var ramp := smoothstep(0.5, 0.75, (_gen_ramp.get_noise_2d(wx, wz) + 1.0) * 0.5)
		var wall_hi: float = lerpf(gen_canyon_width, gen_canyon_width * 3.5, ramp)
		var wall_t := smoothstep(gen_canyon_width * 0.55, wall_hi, gv)
		var canyon_h := lerpf(gen_canyon_floor, mesa_top, wall_t)
		var lvl: float = canyon_h / terr
		var li: float = floor(lvl)
		var riser: float = smoothstep(1.0 - lerpf(gen_canyon_riser, 0.02, ramp), 1.0, lvl - li)
		canyon_h = (li + riser) * terr
		_gen_carved[idx] = lerpf(_gen_base_in[idx], canyon_h, hmask)

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
	create_btn.text = "➕ Create Terrain Node"
	create_btn.tooltip_text = "Adds a single LiteTerrain node (image mode, flat 128x128). It creates its own children."
	create_btn.pressed.connect(_create_terrain)
	panel.add_child(create_btn)

	# ── Sculpt ───────────────────────────────────────────────────────────────
	panel.add_child(_sep())
	panel.add_child(_lbl("── Sculpt ──"))
	var modes := HBoxContainer.new()
	modes.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var group := ButtonGroup.new()
	for m in [["▲", "raise"], ["▼", "lower"], ["⬛", "flatten"]]:
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
			_save_settings())
		modes.add_child(b)
	panel.add_child(modes)
	radius_slider = _slider_row(panel, "Radius", 1.0, 200.0, brush_radius, 1.0,
			func(v: float) -> void: brush_radius = v, 0)
	strength_slider = _slider_row(panel, "Strength", 1.0, 1000.0, brush_strength * 1000.0, 1.0,
			func(v: float) -> void: brush_strength = v / 1000.0, 0)

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
	dice.text = "🎲"
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

	_slider_row(panel, "Height", 1.0, 300.0, gen_amplitude, 1.0,
			func(v: float) -> void: gen_amplitude = v, 0)
	_slider_row(panel, "Features", 10.0, 600.0, gen_scale, 1.0,
			func(v: float) -> void: gen_scale = v, 0)

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

	var oct_spin = SpinBox.new()
	oct_spin.min_value = 1
	oct_spin.max_value = 8
	oct_spin.value     = gen_octaves
	oct_spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	oct_spin.value_changed.connect(func(v: float) -> void:
		gen_octaves = int(v)
		_save_settings())
	adv_body.add_child(_row("Octaves", oct_spin))

	_slider_row(adv_body, "Plains power", 1.0, 8.0, gen_power, 0.1,
			func(v: float) -> void: gen_power = v, 1)
	_slider_row(adv_body, "Mountain amt", 0.0, 1.0, gen_mountain_amount, 0.01,
			func(v: float) -> void: gen_mountain_amount = v, 2)
	_slider_row(adv_body, "Ridge sharp", 1.0, 8.0, gen_ridge_sharpness, 0.1,
			func(v: float) -> void: gen_ridge_sharpness = v, 1)

	var smooth_spin = SpinBox.new()
	smooth_spin.min_value = 0
	smooth_spin.max_value = 5
	smooth_spin.value     = gen_smooth
	smooth_spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	smooth_spin.value_changed.connect(func(v: float) -> void:
		gen_smooth = int(v)
		_save_settings())
	adv_body.add_child(_row("Smoothing", smooth_spin))

	adv_body.add_child(_lbl("Canyon shape"))
	_slider_row(adv_body, "Mesa top", 20.0, 60.0, gen_canyon_plateau, 1.0,
			func(v: float) -> void: gen_canyon_plateau = v, 0)
	_slider_row(adv_body, "Floor", 0.0, 20.0, gen_canyon_floor, 1.0,
			func(v: float) -> void: gen_canyon_floor = v, 0)
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
	gen_btn.text = "🌍 Generate Terrain"
	gen_btn.tooltip_text = "Rebuilds the whole heightmap from the settings above. Hand sculpting is lost."
	gen_btn.pressed.connect(_generate_noise)
	panel.add_child(gen_btn)
	var warn := _lbl("rebuilds everything — sculpting is lost")
	warn.add_theme_font_size_override("font_size", 10)
	warn.modulate = Color(1, 1, 1, 0.6)
	panel.add_child(warn)

	var bake_btn = Button.new()
	bake_btn.text = "💾 Bake → files"
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
# Режим показывают сами кнопки (они в ButtonGroup, нажата ровно одна), поэтому отдельной
# строки-статуса и трёх функций-обёрток больше нет.

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
		"brush_strength":      brush_strength,
		"sculpt_mode":         sculpt_mode,
		"gen_seed":            gen_seed,
		"gen_scale":           gen_scale,
		"gen_octaves":         gen_octaves,
		"gen_power":           gen_power,
		"gen_mountain_amount": gen_mountain_amount,
		"gen_ridge_sharpness": gen_ridge_sharpness,
		"gen_amplitude":       gen_amplitude,
		"gen_smooth":          gen_smooth,
		"gen_size":            gen_size,
		"gen_canyon_enable":    gen_canyon_enable,
		"gen_canyon_plateau":   gen_canyon_plateau,
		"gen_canyon_floor":     gen_canyon_floor,
		"gen_canyon_riser":     gen_canyon_riser,
		"gen_canyon_gorge":     gen_canyon_gorge,
		"gen_canyon_width":     gen_canyon_width,
	})

func _load_settings() -> void:
	var es := EditorInterface.get_editor_settings()
	if es == null:
		return
	var d = es.get_project_metadata(SETTINGS_META_SECTION, SETTINGS_META_KEY, {})
	if typeof(d) != TYPE_DICTIONARY:
		return
	brush_radius        = float(d.get("brush_radius",        brush_radius))
	brush_strength      = float(d.get("brush_strength",      brush_strength))
	sculpt_mode         = str(d.get("sculpt_mode",           sculpt_mode))
	gen_seed            = int(d.get("gen_seed",              gen_seed))
	gen_scale           = float(d.get("gen_scale",           gen_scale))
	gen_octaves         = int(d.get("gen_octaves",           gen_octaves))
	gen_power           = float(d.get("gen_power",           gen_power))
	gen_mountain_amount = float(d.get("gen_mountain_amount", gen_mountain_amount))
	gen_ridge_sharpness = float(d.get("gen_ridge_sharpness", gen_ridge_sharpness))
	gen_amplitude       = float(d.get("gen_amplitude",       gen_amplitude))
	gen_smooth          = int(d.get("gen_smooth",            gen_smooth))
	gen_size            = int(d.get("gen_size",              gen_size))
	gen_canyon_enable    = bool(d.get("gen_canyon_enable",    gen_canyon_enable))
	gen_canyon_plateau   = float(d.get("gen_canyon_plateau",   gen_canyon_plateau))
	gen_canyon_floor     = float(d.get("gen_canyon_floor",     gen_canyon_floor))
	gen_canyon_riser     = float(d.get("gen_canyon_riser",     gen_canyon_riser))
	gen_canyon_gorge     = float(d.get("gen_canyon_gorge",     gen_canyon_gorge))
	gen_canyon_width     = float(d.get("gen_canyon_width",     gen_canyon_width))

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
	if object is StaticBody3D:
		sculpt_node = object
	elif object is CollisionShape3D:
		sculpt_node = object.get_parent()
	_sync_dock()

## Пере-читать в док то, что хранится в БИОМ-РЕСУРСЕ выбранной ноды. Всё остальное в доке —
## настройки самого плагина, они общие и живут в метаданных проекта.
func _sync_dock() -> void:
	var b := _biomes()
	if _cb_canyon != null and is_instance_valid(_cb_canyon):
		_cb_canyon.set_pressed_no_signal(b.canyon_enabled)
		# У флага каньонов ДВА владельца: ресурс красит, генератор режет. Синхронизируем и
		# вторую половину, иначе галочка снята, а генерация всё равно вырезает меса.
		gen_canyon_enable = b.canyon_enabled
	if _cb_mountain != null and is_instance_valid(_cb_mountain):
		_cb_mountain.set_pressed_no_signal(b.mountain_enabled)
	if _sl_stratum != null and is_instance_valid(_sl_stratum):
		# Через .value, а НЕ set_value_no_signal: подпись со значением обновляет обработчик
		# сигнала, и без него ползунок встанет на место, а число рядом останется старым.
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

	if event is InputEventMouseButton:
		# The wheel sizes the brush. Its range matches the slider (1..200), otherwise scrolling
		# would knock a large radius back down to 20. The step scales with the radius so big
		# brushes are reachable in a sane number of turns.
		if event.button_index == MOUSE_BUTTON_WHEEL_UP and event.pressed:
			brush_radius = clamp(brush_radius + maxf(1.0, brush_radius * 0.15), 1.0, 200.0)
			radius_slider.value = brush_radius
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

		var ray_origin = viewport_camera.project_ray_origin(event.position)
		var ray_dir    = viewport_camera.project_ray_normal(event.position)

		var hit_pos
		if sculpt_node.has_method("is_image_mode") and sculpt_node.is_image_mode():
			# Image mode: hit the heightmap by ray-marching it — no physics shape needed.
			var rh = sculpt_node.raycast_heightmap(ray_origin, ray_dir)
			if rh == null:
				return EditorPlugin.AFTER_GUI_INPUT_PASS
			hit_pos = rh
		else:
			var space = sculpt_node.get_world_3d().direct_space_state
			var query = PhysicsRayQueryParameters3D.create(
				ray_origin, ray_origin + ray_dir * 1000.0)
			query.collide_with_bodies = true
			var result = space.intersect_ray(query)
			if result.is_empty():
				return EditorPlugin.AFTER_GUI_INPUT_PASS
			hit_pos = result.position

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
		var dirty: PackedInt32Array = sculpt_node.apply_brush(
				hit_pos, brush_radius, brush_strength, mode_int)
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
					map_data[index] = lerp(map_data[index], avg_height, clampf(falloff * brush_strength, 0.0, 1.0))
	else:
		for z in range(z_min, z_max + 1):
			for x in range(x_min, x_max + 1):
				var dx   = x - cx
				var dz   = z - cz
				var dist = sqrt(dx*dx + dz*dz)
				if dist <= brush_radius:
					var falloff = 1.0 - (dist / brush_radius)
					var index   = z * width + x
					if raise:
						map_data[index] += brush_strength * falloff
					else:
						map_data[index] -= brush_strength * falloff

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
func _bake_and_export() -> void:
	_bake_heightmap()
	_generate_png()

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

	var img := Image.create(width, depth, false, Image.FORMAT_L8)
	for z in depth:
		for x in width:
			var v := (data[z * width + x] - mn) / rng
			img.set_pixel(x, z, Color(v, v, v))

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
			return
		shape = col_shape.shape
		if not shape is HeightMapShape3D:
			push_warning("LiteTerrain: shape is not a HeightMapShape3D")
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
	base_noise.fractal_octaves  = gen_octaves
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
	ridge_noise.fractal_octaves   = maxi(gen_octaves - 1, 1)
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
	_gen_base = base_noise
	_gen_ridge = ridge_noise
	_gen_dune = dune_noise
	_gen_out = PackedFloat32Array()
	_gen_out.resize(width * depth)
	var _fill_gid := WorkerThreadPool.add_group_task(_gen_fill_row, depth, -1, false, "LiteTerrain: heights")
	WorkerThreadPool.wait_for_group_task_completion(_fill_gid)
	var new_data := _gen_out
	_gen_out = PackedFloat32Array()          # drop the field's reference; new_data owns it now

	# ── Optional blur passes ─────────────────────
	# Simple 5-tap box blur to soften extreme spikes.
	# Each pass slightly reduces aliasing without destroying ridges.
	# THREADED, like the fill and the carve above: a blur pass is a full sweep of the map, and on
	# a big one that was seconds of main thread per pass, twice over — once here and once as the
	# `duplicate()` it needed to avoid reading its own output.
	for _p in gen_smooth:
		_gen_base_in = new_data
		_gen_out = PackedFloat32Array()
		_gen_out.resize(width * depth)
		var blur_gid := WorkerThreadPool.add_group_task(_gen_blur_row, depth, -1, false, "LiteTerrain: blur")
		WorkerThreadPool.wait_for_group_task_completion(blur_gid)
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
		_gen_mesa_min = maxf(gen_canyon_plateau - 22.0, gen_canyon_floor + 8.0)   # bottom of the mesa-height spread
		_gen_base_in = new_data
		_gen_carved = new_data.duplicate()      # refcount = 1: threads write their own rows, no CoW
		var _carve_gid := WorkerThreadPool.add_group_task(_gen_carve_row, depth, -1, false, "LiteTerrain: canyons")
		WorkerThreadPool.wait_for_group_task_completion(_carve_gid)
		new_data = _gen_carved
		_gen_carved = PackedFloat32Array()
		_gen_base_in = PackedFloat32Array()

	if image_mode:
		# Set md + size, rebuild the editor preview, and write the heightmap image so the
		# runtime (and re-opening the editor) loads it. No undo here — it's a full regen.
		sculpt_node.set_heightmap(new_data, width, depth)
		var img := Image.create_from_data(width, depth, false, Image.FORMAT_RF, new_data.to_byte_array())
		var gm_path := _heightmap_target()
		var gerr := ResourceSaver.save(img, gm_path)
		if gerr == OK:
			print("LiteTerrain: generated %dx%d -> %s" % [width, depth, gm_path])
		else:
			push_error("LiteTerrain: failed to save generated heightmap (error %d)" % gerr)
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
