class_name BlockGlobe
extends Control
# «Шар» выбора блока для режима стройки — 3D-сфера с превью РЕАЛЬНЫХ блоков в SubViewport,
# показана только ЧЕТВЕРТЬЮ КРУГА в правом нижнем углу экрана. Никаких масок/шейдеров: сам
# Control — квадрат 2R×2R, ЦЕНТР которого стоит РОВНО в углу экрана; остальные 3/4 уходят за
# край окна и не рендерятся — видна верхне-левая четверть, туда риг смещён так, что ТЕКУЩИЙ
# блок оказывается по центру видимой зоны (uv≈0.25,0.25).
#
# Два независимых вращения (как «глобус»):
#   • горизонтальный драг — ДОЛГОТА: перебор блоков ВНУТРИ категории;
#   • вертикальный драг — ШИРОТА: переключение категории (Атака/Блоки/Фабрика/Остальное,
#     те же G.BLOCK_CATEGORIES, что в гараже). У каждой категории свой запомненный слот.
# Отпустил — довод до ближайшего слота. Тап без движения — берёт текущий (центральный) блок.
# Текущий блок крупнее, медленно вращается; на дуге — точки-индикаторы категорий; в углу —
# кольцо выбора и вспышка при взятии; пустой инвентарь показывает «НЕТ БЛОКОВ».

signal block_chosen(block_type: int)

const RADIUS := 190.0
const CAT_KEYS := ["attack", "blocks", "factory", "other"]
const CAT_NAMES := {"attack": "Атака", "blocks": "Блоки", "factory": "Фабрика", "other": "Остальное"}
const LAT_STEP := 0.49                 # ~28°: шаг между категориями по широте
const LON_STEP := 0.80                 # ~46°: шаг между слотами по долготе
const DRAG_SENS := 0.006               # рад на пиксель драга
const SNAP_SPEED := 8.0                # скорость довода до слота после отпускания
const ITEM_DIST := 2.4                 # радиус, на котором висят превью
const CAM_Z := 6.4                     # камера дальше (был 5.2) — блоки мельче, меньше тесноты
const FOV := 30.0                      # угол камеры (square viewport → hfov==vfov)
const SLOT := 0.48                     # целевой габарит превью (был 0.62) — блоки поменьше
const TAP_SLOP := 6.0                  # < столько пикселей пути — это тап (взять), не драг
const SELECT_SCALE := 1.28             # во сколько раз крупнее текущий блок
const IDLE_SPIN := 0.6                 # рад/с — медленное вращение текущего блока в покое
const ANCHOR := Vector2(RADIUS * 0.5, RADIUS * 0.5)   # центр видимой зоны (=uv 0.25 → 95px)

# ── Голубой фон-«четвертькруга» + точки-индикаторы категорий на дуге. ─────────────
# Цвета под остальной UI (см. hud._make_panel_style) держим ЛОКАЛЬНО: вложенный класс
# GDScript не видит const внешнего класса по «голому» имени.
class QuarterBg extends Control:
	const FILL := Color(0.055, 0.16, 0.19, 0.92)
	const ACCENT := Color(0.247, 0.6, 0.65, 0.85)
	var radius := 190.0
	var active_cat := 0
	var cat_has: Array = [true, true, true, true]
	func _draw() -> void:
		var c := Vector2(radius, radius)             # центр = угол экрана
		var steps := 28
		var pts := PackedVector2Array([c])
		for i in steps + 1:
			var a := PI + (PI * 0.5) * float(i) / float(steps)   # от «влево» (PI) до «вверх» (1.5PI)
			pts.append(c + Vector2(cos(a), sin(a)) * radius)
		draw_colored_polygon(pts, FILL)
		draw_arc(c, radius, PI, PI * 1.5, 40, ACCENT, 2.5)
		# 4 точки-индикатора категорий вдоль дуги: заполненная = текущая, контур = есть блоки,
		# тусклая = пусто. Подсказывает, что категорий четыре и переключаются они драгом вверх/вниз.
		var n := cat_has.size()
		for i in n:
			var a := PI + (PI * 0.5) * (float(i) + 0.5) / float(n)
			var p := c + Vector2(cos(a), sin(a)) * (radius - 15.0)
			if i == active_cat:
				draw_circle(p, 6.0, ACCENT)
			elif bool(cat_has[i]):
				draw_arc(p, 5.0, 0, TAU, 12, ACCENT, 2.0)
			else:
				draw_circle(p, 3.5, Color(ACCENT.r, ACCENT.g, ACCENT.b, 0.25))

# ── 2D-оверлей поверх 3D: кольцо выбора, вспышка при взятии, «НЕТ БЛОКОВ». ─────────
# Держим отдельным Control-ом (не в риге), чтобы вспышка пережила rebuild рига при взятии.
class Overlay extends Control:
	const RING := Color(0.247, 0.6, 0.65, 0.55)
	var anchor := Vector2(95, 95)
	var empty := false
	var flash_r := 0.0
	var flash_a := 0.0
	func _draw() -> void:
		if empty:
			var f := get_theme_default_font()
			var txt := "НЕТ\nБЛОКОВ"
			for li in txt.split("\n").size():
				var line: String = txt.split("\n")[li]
				var w := f.get_string_size(line, HORIZONTAL_ALIGNMENT_CENTER, -1, 18).x
				draw_string(f, anchor + Vector2(-w * 0.5, -8 + li * 22), line,
						HORIZONTAL_ALIGNMENT_CENTER, -1, 18, Color(0.7, 0.85, 0.9, 0.8))
			return
		draw_arc(anchor, 50.0, 0, TAU, 40, RING, 2.5)   # кольцо-зона текущего блока
		if flash_a > 0.01:
			draw_arc(anchor, flash_r, 0, TAU, 40, Color(1, 1, 1, flash_a), 3.0)
	func _process(_delta: float) -> void:
		if flash_a > 0.001:          # перерисовываем, только пока играет вспышка
			queue_redraw()
	func flash() -> void:
		flash_r = 50.0
		flash_a = 0.9
		var tw := create_tween().set_parallel(true)
		tw.tween_property(self, "flash_r", 100.0, 0.24)
		tw.tween_property(self, "flash_a", 0.0, 0.24)

var _lon: float = 0.0
var _lat: float = 0.0
var _lon_target: float = 0.0
var _lat_target: float = 0.0
var _cat_idx: int = 0
var _item_idx: Dictionary = {}         # cat_key -> запомненный слот в этой категории

var _rig: Node3D = null
var _label: Label = null
var _bg: QuarterBg = null
var _overlay: Overlay = null
var _by_cat: Dictionary = {}           # cat_key -> Array[{type:int, count:int}]
var _holders: Array = []               # [{node, visual, cat, idx}]
var _visual_cache: Dictionary = {}     # block_type -> шаблон меша (строим один раз)
var _all_empty: bool = false

var _dragging: bool = false
var _drag_dist: float = 0.0            # накопленный путь драга (тап vs драг по сумме)

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	for k in CAT_KEYS:
		_by_cat[k] = []          # инициализируем ДО первого refresh, чтобы прямые _by_cat[k] были безопасны
	_build_scene()

func _build_scene() -> void:
	_bg = QuarterBg.new()
	_bg.radius = RADIUS
	_bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_bg)

	var svc := SubViewportContainer.new()
	svc.stretch = true
	svc.set_anchors_preset(Control.PRESET_FULL_RECT)
	svc.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(svc)

	var sv := SubViewport.new()
	sv.size = Vector2i(int(RADIUS * 2.0), int(RADIUS * 2.0))
	sv.own_world_3d = true
	sv.transparent_bg = true
	sv.render_target_update_mode = SubViewport.UPDATE_WHEN_VISIBLE
	svc.add_child(sv)

	var cam := Camera3D.new()
	cam.fov = FOV
	cam.transform = Transform3D(Basis(), Vector3(0, 0, CAM_Z))
	sv.add_child(cam)

	var light := DirectionalLight3D.new()
	light.rotation = Vector3(-0.6, -0.5, 0)
	sv.add_child(light)
	var fill := DirectionalLight3D.new()   # слабая подсветка сзади-снизу, чтобы низ не был чёрным
	fill.rotation = Vector3(0.7, 2.4, 0)
	fill.light_energy = 0.4
	sv.add_child(fill)

	_rig = Node3D.new()
	# Смещаем риг так, чтобы ТЕКУЩИЙ (передний) блок проецировался в ЦЕНТР ВИДИМОЙ четверти
	# (uv≈0.25,0.25), а не в угол. Верно, пока вьюпорт КВАДРАТНЫЙ (hfov==vfov) и константы FOV/
	# CAM_Z/ITEM_DIST согласованы — иначе центр «уедет» (см. ANCHOR тоже завязан на это).
	var half := tan(deg_to_rad(FOV) * 0.5) * (CAM_Z - ITEM_DIST)
	_rig.position = Vector3(-0.5 * half, 0.5 * half, 0.0)
	sv.add_child(_rig)

	_overlay = Overlay.new()
	_overlay.anchor = ANCHOR
	_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_overlay)                    # ПОСЛЕ svc — рисуется поверх 3D

	_label = Label.new()
	_label.position = Vector2(16, 12)
	_label.add_theme_font_size_override("font_size", 15)
	_label.add_theme_color_override("font_color", Color(0.85, 0.95, 1.0))
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_label)

# Полное обновление содержимого — звать при входе в стройку (инвентарь мог измениться).
func refresh() -> void:
	_by_cat.clear()
	for k in CAT_KEYS:
		_by_cat[k] = []
	var counts: Dictionary = {}
	for b in G.block_inventory:
		counts[b] = counts.get(b, 0) + 1
	for block_type in counts:
		var key := _category_of(int(block_type))
		(_by_cat[key] as Array).append({"type": int(block_type), "count": int(counts[block_type])})
	for k in CAT_KEYS:
		if not _item_idx.has(k):
			_item_idx[k] = 0
		var items: Array = _by_cat[k]
		if not items.is_empty():
			_item_idx[k] = clampi(int(_item_idx[k]), 0, items.size() - 1)
	# Текущая категория опустела → ближайшая непустая ОТ ТЕКУЩЕЙ (не с нуля — иначе глобус
	# прокатывался через все категории после взятия последнего блока в «other»).
	if (_by_cat[CAT_KEYS[_cat_idx]] as Array).is_empty():
		_cat_idx = _nearest_cat(_lat_for_cat(_cat_idx))
	_lat_target = _lat_for_cat(_cat_idx)
	_lat = _lat_target
	_lon_target = float(int(_item_idx.get(CAT_KEYS[_cat_idx], 0))) * LON_STEP
	_lon = _lon_target
	_rebuild_rig()
	_update_label()
	_sync_bg()

func _lat_for_cat(ci: int) -> float:
	return (float(ci) - float(CAT_KEYS.size() - 1) * 0.5) * LAT_STEP

func _category_of(block_type: int) -> String:
	for k in G.BLOCK_CATEGORIES:
		if (G.BLOCK_CATEGORIES[k] as Array).has(block_type):
			return k
	return "other"

func _rebuild_rig() -> void:
	if _rig == null:
		return
	for c in _rig.get_children():
		_rig.remove_child(c)      # remove ДО free: иначе старый и новый набор кадр сосуществуют
		c.queue_free()
	_holders.clear()
	for ci in CAT_KEYS.size():
		var items: Array = _by_cat[CAT_KEYS[ci]]
		if items.is_empty():
			continue
		var lat := _lat_for_cat(ci)
		for ii in items.size():
			var h := _make_item_node(items[ii], lat, float(ii) * LON_STEP)
			_rig.add_child(h["node"])
			h["cat"] = ci
			h["idx"] = ii
			_holders.append(h)

func _make_item_node(it: Dictionary, lat: float, lon: float) -> Dictionary:
	var holder := Node3D.new()
	holder.position = Vector3(sin(lon) * cos(lat), sin(lat), cos(lon) * cos(lat)) * ITEM_DIST
	var visual := _make_visual(int(it["type"]))
	holder.add_child(visual)
	if int(it["count"]) > 1:
		var lbl := Label3D.new()
		lbl.text = "×%d" % int(it["count"])
		lbl.font_size = 40
		lbl.position = Vector3(0, -0.46, 0)
		lbl.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		lbl.no_depth_test = true
		holder.add_child(lbl)
	return {"node": holder, "visual": visual}

# ── Реальный меш блока: собираем из его сцены, НЕ запуская логику ─────────────────
# instantiate() не вызывает _ready() (там весь сайд-эффект: add_to_group/freeze/сигналы/
# процедурные FX-меши), поэтому off-tree обход безопасен. Копируем меши+материалы ПО ССЫЛКЕ,
# нормализуем в SLOT, инстанс free(). Шаблон кешируем — rebuild не пере-инстансит сцену.
func _make_visual(block_type: int) -> Node3D:
	var data := _visual_template(block_type)
	var container := Node3D.new()
	if not bool(data["ok"]):
		# Фолбэк: цветной кубик (как раньше), если реального меша не нашлось.
		var mi := MeshInstance3D.new()
		var box := BoxMesh.new(); box.size = Vector3(SLOT, SLOT, SLOT)
		var m := StandardMaterial3D.new(); m.albedo_color = _color_for(block_type); m.roughness = 0.55
		box.material = m; mi.mesh = box
		container.add_child(mi)
		return container
	var inner := Node3D.new()
	var s: float = data["scale"]
	var ctr: Vector3 = data["center"]
	inner.transform = Transform3D(Basis().scaled(Vector3.ONE * s), -ctr * s)  # scale-then-recenter
	container.add_child(inner)
	for p in data["parts"]:
		var mc := MeshInstance3D.new()
		mc.mesh = p["mesh"]
		if p["mat"] != null:
			mc.material_override = p["mat"]
		var surf: Array = p["surf"]
		for si in surf.size():
			if surf[si] != null:
				mc.set_surface_override_material(si, surf[si])
		mc.transform = p["xform"]
		inner.add_child(mc)
	return container

func _visual_template(block_type: int) -> Dictionary:
	if _visual_cache.has(block_type):
		return _visual_cache[block_type]
	var data := {"parts": [], "scale": 1.0, "center": Vector3.ZERO, "ok": false}
	var scene: PackedScene = G.get_scene(block_type)
	if scene == null:
		_visual_cache[block_type] = data
		return data
	var inst: Node = scene.instantiate()          # _ready НЕ вызывается — сайд-эффектов нет
	var acc := AABB()
	var has := false
	var stack: Array = [[inst, Transform3D.IDENTITY]]
	while not stack.is_empty():
		var pair = stack.pop_back()
		var n = pair[0]
		var xf: Transform3D = pair[1]
		# Пропускаем ветки-НЕ-тело блока: скрытые, триггеры/индикаторы (Area3D), хосты
		# трассера (RayCast3D — у оружия track_visual виден в .tscn, прячется только в _ready).
		if n != inst:
			if n is Area3D or n is RayCast3D:
				continue
			if n is Node3D and not (n as Node3D).visible:
				continue
		var here := xf
		if n is Node3D:
			here = xf * (n as Node3D).transform
		for c in n.get_children():
			stack.append([c, here])
		if n is MeshInstance3D and n.mesh != null:
			var mat := _active_material(n)
			if mat is BaseMaterial3D:
				var bm := (mat as BaseMaterial3D).blend_mode
				if bm == BaseMaterial3D.BLEND_MODE_ADD or bm == BaseMaterial3D.BLEND_MODE_SUB:
					continue    # аддитивный FX (луч/всасывающая капсула коллектора) — не тело
			var surf: Array = []
			for si in n.get_surface_override_material_count():
				surf.append(n.get_surface_override_material(si))
			data["parts"].append({"mesh": n.mesh, "mat": n.material_override, "surf": surf, "xform": here})
			var la: AABB = n.mesh.get_aabb()
			for i in 8:
				var corner := la.position + Vector3(
						la.size.x * float(i & 1), la.size.y * float((i >> 1) & 1), la.size.z * float((i >> 2) & 1))
				var wp := here * corner
				if not has:
					acc = AABB(wp, Vector3.ZERO); has = true
				else:
					acc = acc.expand(wp)
	inst.free()      # off-tree узел — free() безопасен; меши/материалы (RefCounted) переживут
	if has and not (data["parts"] as Array).is_empty():
		var maxd: float = maxf(acc.size.x, maxf(acc.size.y, acc.size.z))
		data["scale"] = (SLOT / maxd) if maxd > 1e-4 else 1.0
		data["center"] = acc.get_center()
		data["ok"] = true
	_visual_cache[block_type] = data
	return data

# Действующий материал MeshInstance3D: override → override поверхности → материал меша.
func _active_material(mi: MeshInstance3D) -> Material:
	if mi.material_override != null:
		return mi.material_override
	if mi.get_surface_override_material_count() > 0 and mi.get_surface_override_material(0) != null:
		return mi.get_surface_override_material(0)
	if mi.mesh != null and mi.mesh.get_surface_count() > 0:
		return mi.mesh.surface_get_material(0)
	return null

# Цвет-заглушка по типу (фолбэк, если реальный меш не собрался).
func _color_for(block_type: int) -> Color:
	var h := float(block_type % 12) / 12.0
	return Color.from_hsv(h, 0.55, 0.95)

func _update_label() -> void:
	var key: String = CAT_KEYS[_cat_idx]
	var items: Array = _by_cat.get(key, [])
	var disp := ""
	if not items.is_empty():
		var i := clampi(int(_item_idx.get(key, 0)), 0, items.size() - 1)
		disp = _block_display_name(int(items[i]["type"]))
	_label.text = "%s\n%s" % [CAT_NAMES.get(key, key), disp]

func _block_display_name(block_type: int) -> String:
	var names: Array = G.Block.keys()
	if block_type >= 0 and block_type < names.size():
		return str(names[block_type]).capitalize()
	return "?"

func _sync_bg() -> void:
	if _bg:
		_bg.active_cat = _cat_idx
		var has: Array = []
		for k in CAT_KEYS:
			has.append(not (_by_cat.get(k, []) as Array).is_empty())
		_bg.cat_has = has
		_bg.queue_redraw()
	_all_empty = true
	for k in CAT_KEYS:
		if not (_by_cat.get(k, []) as Array).is_empty():
			_all_empty = false
			break
	if _overlay:
		_overlay.empty = _all_empty
		_overlay.queue_redraw()
	if _label:
		_label.visible = not _all_empty     # при пустом инвентаре текст ведёт оверлей «НЕТ БЛОКОВ»

func _process(delta: float) -> void:
	if not visible or _rig == null:
		return
	_lon = lerp_angle(_lon, _lon_target, SNAP_SPEED * delta)
	_lat = lerp(_lat, _lat_target, SNAP_SPEED * delta)
	# Блок стоит на сфере как P = Ry(lon)·Rx(−lat)·ẑ, поэтому чтобы вывести выбранный блок
	# ВПЕРЁД (к камере, ẑ) рига-базис должен быть Rx(lat)·Ry(−lon) — именно в этом порядке.
	# Прежний Vector3(−lat,−lon,0) в YXZ-порядке Godot давал Ry(−lon)·Rx(−lat) — верно ТОЛЬКО
	# на экваторе (lat=0, одна категория), а при смене категории центрировался НЕ тот блок.
	_rig.basis = Basis(Vector3.RIGHT, _lat) * Basis(Vector3.UP, -_lon)
	# Подсветка текущего блока: он крупнее и, в покое, медленно вращается. Ведём подсветку
	# по ЖИВОМУ центру (nearest cat + _preview_idx) — тому же, что показывает лейбл — иначе во
	# время горизонтального драга крупным оставался старый (закоммиченный) блок, а по центру
	# уже другой. В покое живой центр совпадает с закоммиченным выбором.
	var settled := absf(wrapf(_lon - _lon_target, -PI, PI)) < 0.02 \
			and absf(_lat - _lat_target) < 0.02 and not _dragging
	var hi_cat := _nearest_cat(_lat_target)
	var hi_idx := _preview_idx(hi_cat)
	for h in _holders:
		var is_center: bool = hi_idx >= 0 and int(h["cat"]) == hi_cat and int(h["idx"]) == hi_idx
		var holder: Node3D = h["node"]
		var target_s := SELECT_SCALE if is_center else 1.0
		holder.scale = holder.scale.lerp(Vector3.ONE * target_s, 10.0 * delta)
		var vis: Node3D = h["visual"]
		if is_center:
			if settled:
				vis.rotation.y += IDLE_SPIN * delta
		else:
			vis.rotation.y = 0.0

# Только мышь: касания Godot эмулирует событиями мыши (emulate_mouse_from_touch, как и
# vehicle_interact_button.gd) — отдельная ветка на ScreenTouch/Drag ловила бы палец дважды.
func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_dragging = true
			_drag_dist = 0.0
		elif _dragging:
			_end_drag()
	elif event is InputEventMouseMotion and _dragging:
		_apply_drag(event.relative)

func _apply_drag(rel: Vector2) -> void:
	_drag_dist += rel.length()        # тап/драг решаем по НАКОПЛЕННОМУ пути (медленный драг тоже драг)
	_lon_target -= rel.x * DRAG_SENS
	var half_span := LAT_STEP * float(CAT_KEYS.size() - 1) * 0.5
	_lat_target = clampf(_lat_target - rel.y * DRAG_SENS, -half_span, half_span)
	_update_label_live()

func _end_drag() -> void:
	_dragging = false
	if _drag_dist < TAP_SLOP:
		# Тап: канонизируем цели под текущий выбор (сгладить суб-slop дрейф) и берём блок.
		_lat_target = _lat_for_cat(_cat_idx)
		var key: String = CAT_KEYS[_cat_idx]
		var items: Array = _by_cat.get(key, [])
		if not items.is_empty():
			_lon_target = float(clampi(int(_item_idx.get(key, 0)), 0, items.size() - 1)) * LON_STEP
		_choose_center()
		return
	_snap_to_nearest()

# Ближайшая НЕПУСТАЯ категория к заданной широте (общее для снапа и живого лейбла).
func _nearest_cat(lat: float) -> int:
	var half_span := LAT_STEP * float(CAT_KEYS.size() - 1) * 0.5
	var raw := clampi(roundi((lat + half_span) / LAT_STEP), 0, CAT_KEYS.size() - 1)
	if not (_by_cat[CAT_KEYS[raw]] as Array).is_empty():
		return raw
	for d in range(1, CAT_KEYS.size()):
		for cand in [raw - d, raw + d]:
			if cand >= 0 and cand < CAT_KEYS.size() and not (_by_cat[CAT_KEYS[cand]] as Array).is_empty():
				return cand
	return raw

# Индекс слота внутри категории ci по текущей долготе (с заворотом по кругу).
func _item_at_lon(ci: int) -> int:
	var items: Array = _by_cat.get(CAT_KEYS[ci], [])
	if items.is_empty():
		return -1
	var n := items.size()
	return ((roundi(_lon_target / LON_STEP) % n) + n) % n

# Какой слот показать/выбрать в категории ci: та же категория → по долготе (браузинг);
# ДРУГАЯ категория → её запомненный слот (не теряем позицию при переключении вверх/вниз).
func _preview_idx(ci: int) -> int:
	var items: Array = _by_cat.get(CAT_KEYS[ci], [])
	if items.is_empty():
		return -1
	if ci != _cat_idx:
		return clampi(int(_item_idx.get(CAT_KEYS[ci], 0)), 0, items.size() - 1)
	return _item_at_lon(ci)

func _snap_to_nearest() -> void:
	var ci := _nearest_cat(_lat_target)
	var idx := _preview_idx(ci)
	_cat_idx = ci
	_lat_target = _lat_for_cat(ci)
	if idx < 0:
		_update_label(); _sync_bg()
		return
	_item_idx[CAT_KEYS[ci]] = idx
	_lon_target = float(idx) * LON_STEP
	_update_label()
	_sync_bg()

# Живой лейбл во время драга — от ТЕКУЩИХ целей (до снапа), чтобы игрок видел выбор сразу.
func _update_label_live() -> void:
	var ci := _nearest_cat(_lat_target)
	var key: String = CAT_KEYS[ci]
	var idx := _preview_idx(ci)
	if idx < 0:
		_label.text = CAT_NAMES.get(key, key)
		return
	var items: Array = _by_cat[key]
	_label.text = "%s\n%s" % [CAT_NAMES.get(key, key), _block_display_name(int(items[idx]["type"]))]

func _choose_center() -> void:
	var key: String = CAT_KEYS[_cat_idx]
	var items: Array = _by_cat.get(key, [])
	if items.is_empty():
		return
	var idx: int = clampi(int(_item_idx.get(key, 0)), 0, items.size() - 1)
	if _overlay:
		_overlay.flash()             # подтверждение взятия — переживает rebuild рига
	block_chosen.emit(int(items[idx]["type"]))
