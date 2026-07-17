class_name BlockGlobe
extends Control
# «Гироскоп» выбора блока в стройке: два ОДИНАКОВЫХ вытянутых овала-кольца в 3D, скрещенных
# буквой «Х» — общий центр, наклонены в противоположные стороны, в середине читается ромб.
#   • кольцо «/» — БЛОКИ текущей категории (реальные превью-меши). Драг по диагонали
#     «право-верх ↔ лево-низ» крутит его; ВЫБРАННЫЙ блок стоит спереди СЛЕВА-СВЕРХУ,
#     крупнее остальных и в покое медленно вращается — его и берём тапом.
#   • кольцо «\» — 4 КАТЕГОРИИ (те же G.BLOCK_CATEGORIES, что в гараже) — цветные кристаллы.
#     Драг «право-низ ↔ лево-верх» крутит его; текущая категория спереди СПРАВА-СВЕРХУ.
#     Пока крутишь категории, кольцо блоков живо перестраивается под переднюю.
# Ось жеста лочится по первой диагонали движения; отпустил — довод до ближайшего слота.
# Тап без движения — взять текущий блок. У каждой категории — свой запомненный слот.
# Пустая категория — «ПУСТО», совсем без блоков — «НЕТ БЛОКОВ».

signal block_chosen(block_type: int)

const SIZE := 264.0                    # сторона квадрата-виджета: весь «Х» виден целиком
const CAT_KEYS := ["attack", "blocks", "factory", "other"]
const CAT_NAMES := {"attack": "Атака", "blocks": "Блоки", "factory": "Фабрика", "other": "Остальное"}
const CAT_COLORS := {
	"attack": Color(0.85, 0.36, 0.32), "blocks": Color(0.30, 0.62, 0.66),
	"factory": Color(0.85, 0.66, 0.30), "other": Color(0.62, 0.46, 0.80),
}

# Геометрия колец. Наклон ±35° от горизонтали: C35/S35 — его косинус/синус (const-литералы,
# т.к. cos()/sin() в const-выражении GDScript не сворачивает). MINOR_K — сжатие овала
# (малая полуось / большая), ZK — глубинная амплитуда (передняя точка ближе к камере).
const ROLL_C := 0.8191520443           # cos 35°
const ROLL_S := 0.5735764364           # sin 35°
# MINOR_K не уже 0.46: передние точки колец расходятся на ~65px, иначе выбранный блок при
# вращении (диагональ куба шире грани!) задевал передний кристалл категории.
const MINOR_K := 0.46
const ZK := 0.92
const R_RING := 1.30
const CAM_Z := 6.4
const FOV := 30.0
const SLOT := 0.44                     # целевой габарит превью блока
const GEM := 0.23                      # размер кристалла категории
const MIN_SLOTS_A := 5                 # меньше блоков — кольцо с «пробелом», листается без заворота

# Экранные орты диагоналей (y ВНИЗ): «/» — вправо-вверх, «\» — вправо-вниз.
const U_A := Vector2(0.8191520443, -0.5735764364)
const U_B := Vector2(0.8191520443, 0.5735764364)

const STEP_B := TAU / 4.0              # шаг категорий: 4 кристалла ровно по кругу
const SLOT_DRAG_PX := 100.0            # пикселей драга на один слот (обоим кольцам)
const TAP_SLOP := 6.0                  # короче этого пути — тап (взять), не драг
const LOCK_DIST := 12.0                # путь, после которого лочится ось жеста
const SNAP_SPEED := 8.0
const SELECT_SCALE := 1.18             # больше — и вращающийся блок цепляет соседний кристалл
const IDLE_SPIN := 0.6                 # рад/с — вращение выбранного блока в покое

# ── Фон: два овала-«Х» и мягкий тёмный диск. Всё передаётся снаружи готовыми полилиниями
# (вложенный класс GDScript не видит const внешнего по «голому» имени). ────────────────
class XBg extends Control:
	const OVAL_A := Color(0.247, 0.6, 0.65, 0.5)
	const OVAL_B := Color(0.58, 0.47, 0.78, 0.45)
	const DISC := Color(0.03, 0.10, 0.13, 0.5)
	var oval_a := PackedVector2Array()
	var oval_b := PackedVector2Array()
	var center := Vector2.ZERO
	var disc_r := 100.0
	func _draw() -> void:
		draw_circle(center, disc_r, DISC)
		if oval_b.size() > 1:
			draw_polyline(oval_b, OVAL_B, 1.5, true)
		if oval_a.size() > 1:
			draw_polyline(oval_a, OVAL_A, 1.5, true)

# ── Оверлей поверх 3D: кольцо у выбранного блока, вспышка взятия, «ПУСТО»/«НЕТ БЛОКОВ».
# Отдельный Control (не в риге): вспышка переживает rebuild кольца после взятия. ───────
class Overlay extends Control:
	const RING := Color(0.247, 0.6, 0.65, 0.55)
	var anchor := Vector2.ZERO         # экранная точка выбранного блока (передняя точка «/»)
	var empty_all := false
	var empty_cat := false
	var flash_r := 0.0
	var flash_a := 0.0
	func _draw() -> void:
		if empty_all:
			_text("НЕТ\nБЛОКОВ", size * 0.5, 18)
			return
		draw_arc(anchor, 40.0, 0, TAU, 40, RING, 2.5)
		if empty_cat:
			_text("ПУСТО", anchor, 13)
		if flash_a > 0.01:
			draw_arc(anchor, flash_r, 0, TAU, 40, Color(1, 1, 1, flash_a), 3.0)
	func _text(txt: String, at: Vector2, px: int) -> void:
		var f := get_theme_default_font()
		var lines := txt.split("\n")
		for li in lines.size():
			var w := f.get_string_size(lines[li], HORIZONTAL_ALIGNMENT_CENTER, -1, px).x
			draw_string(f, at + Vector2(-w * 0.5, -4 + li * (px + 4)), lines[li],
					HORIZONTAL_ALIGNMENT_CENTER, -1, px, Color(0.7, 0.85, 0.9, 0.8))
	func _process(_delta: float) -> void:
		if flash_a > 0.001:            # перерисовка только пока играет вспышка
			queue_redraw()
	func flash() -> void:
		flash_r = 40.0
		flash_a = 0.9
		var tw := create_tween().set_parallel(true)
		tw.tween_property(self, "flash_r", 84.0, 0.24)
		tw.tween_property(self, "flash_a", 0.0, 0.24)

var _ang_a := 0.0                      # угол кольца блоков (растёт непрерывно, слоты кратны _step_a)
var _ang_a_t := 0.0
var _ang_b := 0.0                      # угол кольца категорий (слоты кратны STEP_B)
var _ang_b_t := 0.0
var _step_a := TAU / float(MIN_SLOTS_A)
var _cat_idx := 0                      # закоммиченная категория
var _live_cat := 0                     # категория, чьи блоки сейчас на кольце (во время драга «\»)
var _item_idx := {}                    # cat_key -> запомненный слот категории
var _items: Array = []                 # блоки live-категории: [{type, count}]
var _by_cat := {}                      # cat_key -> Array[{type, count}]

var _root_a: Node3D = null             # держатели блоков (позиции считаем каждый кадр)
var _root_b: Node3D = null             # держатели кристаллов категорий
var _slots: Array = []                 # [{node, visual}] — блоки, индекс = слот
var _gems: Array = []                  # [{node, mat}] — кристаллы, индекс = категория
var _label: Label = null
var _bg: XBg = null
var _overlay: Overlay = null
var _visual_cache := {}                # block_type -> шаблон меша (строим один раз)
var _all_empty := false

var _dragging := false
var _drag_dist := 0.0
var _drag_acc := Vector2.ZERO
var _axis := -1                        # -1 не решено, 0 — кольцо блоков «/», 1 — категорий «\»

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	for k in CAT_KEYS:
		_by_cat[k] = []
		_item_idx[k] = 0
	_build_scene()

# Точка кольца: базовая карусель в XZ, наклон до овала (MINOR_K), крен на ±35° (gs=+1 — «/»
# блоки, gs=−1 — «\» категории). Передняя точка (phi=0) ближе всего к камере и СВЕРХУ:
# у «/» — слева, у «\» — справа. Большая ось — соответствующая диагональ.
func _ring_point(phi: float, gs: float) -> Vector3:
	var sp := sin(phi)
	var cp := cos(phi)
	return Vector3(
			R_RING * (sp * ROLL_C - MINOR_K * cp * ROLL_S * gs),
			R_RING * (sp * ROLL_S * gs + MINOR_K * cp * ROLL_C),
			R_RING * ZK * cp)

# Проекция 3D-точки в пиксели виджета (вьюпорт — квадрат SIZE, камера на +Z смотрит в −Z).
func _to_px(p: Vector3) -> Vector2:
	var ppw := (SIZE * 0.5) / (tan(deg_to_rad(FOV) * 0.5) * (CAM_Z - p.z))
	return Vector2(SIZE * 0.5 + p.x * ppw, SIZE * 0.5 - p.y * ppw)

func _oval_px(gs: float) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for i in 49:
		pts.append(_to_px(_ring_point(TAU * float(i) / 48.0, gs)))
	return pts

func _build_scene() -> void:
	_bg = XBg.new()
	_bg.center = Vector2(SIZE * 0.5, SIZE * 0.5)
	_bg.disc_r = SIZE * 0.485
	_bg.oval_a = _oval_px(1.0)
	_bg.oval_b = _oval_px(-1.0)
	_bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_bg)

	var svc := SubViewportContainer.new()
	svc.stretch = true
	svc.set_anchors_preset(Control.PRESET_FULL_RECT)
	svc.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(svc)

	var sv := SubViewport.new()
	sv.size = Vector2i(int(SIZE), int(SIZE))
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
	var fill := DirectionalLight3D.new()   # слабый контражур, чтобы низ блоков не был чёрным
	fill.rotation = Vector3(0.7, 2.4, 0)
	fill.light_energy = 0.4
	sv.add_child(fill)

	_root_a = Node3D.new()
	sv.add_child(_root_a)
	_root_b = Node3D.new()
	sv.add_child(_root_b)
	_build_gems()

	_overlay = Overlay.new()
	_overlay.anchor = _to_px(_ring_point(0.0, 1.0))
	_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_overlay)                    # после svc — рисуется поверх 3D

	_label = Label.new()
	_label.position = Vector2(8, 0)
	_label.add_theme_font_size_override("font_size", 14)
	_label.add_theme_color_override("font_color", Color(0.85, 0.95, 1.0))
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_label)

# Кристаллы категорий — кубик на «уголке» (поворот 45°+35°), цвет из CAT_COLORS.
# Строятся один раз; пустые категории затемняются в _sync_state().
func _build_gems() -> void:
	_gems.clear()
	for k in CAT_KEYS:
		var holder := Node3D.new()
		var mi := MeshInstance3D.new()
		var box := BoxMesh.new()
		box.size = Vector3(GEM, GEM, GEM)
		var mat := StandardMaterial3D.new()
		mat.albedo_color = CAT_COLORS[k]
		mat.emission_enabled = true
		mat.emission = CAT_COLORS[k] * 0.35
		mat.roughness = 0.35
		box.material = mat
		mi.mesh = box
		mi.rotation = Vector3(0.6155, PI / 4.0, 0)   # «стоит на вершине» — читается как кристалл
		holder.add_child(mi)
		_root_b.add_child(holder)
		_gems.append({"node": holder, "mat": mat})

# Полное обновление содержимого — звать при входе в стройку и после взятия блока.
func refresh() -> void:
	for k in CAT_KEYS:
		(_by_cat[k] as Array).clear()
	var counts: Dictionary = {}
	for b in G.block_inventory:
		counts[b] = counts.get(b, 0) + 1
	for block_type in counts:
		var key := _category_of(int(block_type))
		(_by_cat[key] as Array).append({"type": int(block_type), "count": int(counts[block_type])})
	_all_empty = true
	for k in CAT_KEYS:
		var items: Array = _by_cat[k]
		if not items.is_empty():
			_all_empty = false
			_item_idx[k] = clampi(int(_item_idx[k]), 0, items.size() - 1)
	# Текущая категория опустела → ближайшая непустая ПО КОЛЬЦУ (не с нуля).
	if (_by_cat[CAT_KEYS[_cat_idx]] as Array).is_empty() and not _all_empty:
		_cat_idx = _nearest_nonempty(_cat_idx)
	_ang_b = float(_cat_idx) * STEP_B
	_ang_b_t = _ang_b
	_load_cat(_cat_idx)
	_update_label()
	_sync_state()

func _category_of(block_type: int) -> String:
	for k in G.BLOCK_CATEGORIES:
		if (G.BLOCK_CATEGORIES[k] as Array).has(block_type):
			return k
	return "other"

func _nearest_nonempty(ci: int) -> int:
	for d in [1, 2]:
		for cand in [posmod(ci - d, CAT_KEYS.size()), posmod(ci + d, CAT_KEYS.size())]:
			if not (_by_cat[CAT_KEYS[cand]] as Array).is_empty():
				return cand
	return ci

# Поставить на кольцо блоки категории ci (и вспомнить её сохранённый слот).
func _load_cat(ci: int) -> void:
	_live_cat = ci
	_items = _by_cat[CAT_KEYS[ci]]
	_step_a = TAU / float(maxi(_items.size(), MIN_SLOTS_A))
	var mem := 0
	if not _items.is_empty():
		mem = clampi(int(_item_idx[CAT_KEYS[ci]]), 0, _items.size() - 1)
	_ang_a = float(mem) * _step_a
	_ang_a_t = _ang_a
	for s in _slots:
		_root_a.remove_child(s["node"])   # remove ДО free: без кадра сосуществования наборов
		(s["node"] as Node).queue_free()
	_slots.clear()
	for it in _items:
		var holder := Node3D.new()
		var visual := _make_visual(int(it["type"]))
		holder.add_child(visual)
		if int(it["count"]) > 1:
			var lbl := Label3D.new()
			lbl.text = "×%d" % int(it["count"])
			lbl.font_size = 34
			lbl.position = Vector3(0, -0.40, 0)
			lbl.billboard = BaseMaterial3D.BILLBOARD_ENABLED
			lbl.no_depth_test = true
			holder.add_child(lbl)
		_root_a.add_child(holder)
		_slots.append({"node": holder, "visual": visual})
	if _overlay:
		_overlay.empty_cat = _items.is_empty() and not _all_empty
		_overlay.queue_redraw()

# ── Реальный меш блока: собираем из его сцены, НЕ запуская логику ─────────────────
# instantiate() не вызывает _ready() (там весь сайд-эффект: add_to_group/freeze/сигналы/
# процедурные FX-меши), поэтому off-tree обход безопасен. Копируем меши+материалы ПО ССЫЛКЕ,
# нормализуем в SLOT, инстанс free(). Шаблон кешируем — rebuild не пере-инстансит сцену.
func _make_visual(block_type: int) -> Node3D:
	var data := _visual_template(block_type)
	var container := Node3D.new()
	if not bool(data["ok"]):
		# Фолбэк: цветной кубик, если реального меша не нашлось.
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

# Слот у передней точки кольца блоков. Кольцо с «пробелом» (мало блоков) не заворачивается —
# края клампятся; полное (n >= MIN_SLOTS_A, шаг ровно TAU/n) листается по кругу бесшовно.
func _live_idx() -> int:
	var n := _items.size()
	if n == 0:
		return -1
	if n < MIN_SLOTS_A:
		return clampi(roundi(_ang_a_t / _step_a), 0, n - 1)
	return posmod(roundi(_ang_a_t / _step_a), n)

func _front_cat() -> int:
	return posmod(roundi(_ang_b_t / STEP_B), CAT_KEYS.size())

func _update_label() -> void:
	var key: String = CAT_KEYS[_live_cat]
	var idx := _live_idx()
	var disp := "—"
	if idx >= 0:
		disp = _block_display_name(int(_items[idx]["type"]))
	_label.text = "%s\n%s" % [CAT_NAMES[key], disp]

func _block_display_name(block_type: int) -> String:
	var names: Array = G.Block.keys()
	if block_type >= 0 and block_type < names.size():
		return str(names[block_type]).capitalize()
	return "?"

func _sync_state() -> void:
	for ci in _gems.size():
		var base: Color = CAT_COLORS[CAT_KEYS[ci]]
		var has_items: bool = not (_by_cat[CAT_KEYS[ci]] as Array).is_empty()
		var mat: StandardMaterial3D = _gems[ci]["mat"]
		mat.albedo_color = base if has_items else base.darkened(0.65)
		mat.emission_energy_multiplier = 1.0 if has_items else 0.0
	if _overlay:
		_overlay.empty_all = _all_empty
		_overlay.empty_cat = _items.is_empty() and not _all_empty
		_overlay.queue_redraw()
	if _label:
		_label.visible = not _all_empty     # при пустом инвентаре текст ведёт оверлей

func _process(delta: float) -> void:
	if not visible or _root_a == null:
		return
	var k := minf(SNAP_SPEED * delta, 1.0)
	_ang_a = lerpf(_ang_a, _ang_a_t, k)
	_ang_b = lerpf(_ang_b, _ang_b_t, k)
	var settled := absf(_ang_a - _ang_a_t) < 0.02 and absf(_ang_b - _ang_b_t) < 0.02 \
			and not _dragging
	# Кольцо блоков: позиции каждый кадр (углы плывут), выбранный крупнее и в покое крутится.
	var sel := _live_idx()
	for i in _slots.size():
		var holder: Node3D = _slots[i]["node"]
		holder.position = _ring_point(float(i) * _step_a - _ang_a, 1.0)
		var target_s := SELECT_SCALE if i == sel else 1.0
		holder.scale = holder.scale.lerp(Vector3.ONE * target_s, 10.0 * delta)
		var vis: Node3D = _slots[i]["visual"]
		if i == sel:
			if settled:
				vis.rotation.y += IDLE_SPIN * delta
		else:
			vis.rotation.y = 0.0
	# Кольцо категорий: передний кристалл крупнее и медленно крутится.
	var fc := _front_cat()
	for ci in _gems.size():
		var g: Node3D = _gems[ci]["node"]
		g.position = _ring_point(float(ci) * STEP_B - _ang_b, -1.0)
		var gs := 1.18 if ci == fc else 1.0
		g.scale = g.scale.lerp(Vector3.ONE * gs, 10.0 * delta)
		if ci == fc and settled:
			g.rotation.y += IDLE_SPIN * delta

# Только мышь: касания Godot эмулирует событиями мыши (emulate_mouse_from_touch, как и
# vehicle_interact_button.gd) — отдельная ветка на ScreenTouch/Drag ловила бы палец дважды.
func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_dragging = true
			_drag_dist = 0.0
			_drag_acc = Vector2.ZERO
			_axis = -1
		elif _dragging:
			_end_drag()
	elif event is InputEventMouseMotion and _dragging:
		_apply_drag(event.relative)

func _apply_drag(rel: Vector2) -> void:
	_drag_dist += rel.length()        # тап/драг решаем по накопленному пути
	_drag_acc += rel
	if _axis < 0:
		if _drag_dist < LOCK_DIST:
			return
		# Ось — та диагональ, вдоль которой жест прошёл дальше.
		_axis = 0 if absf(_drag_acc.dot(U_A)) >= absf(_drag_acc.dot(U_B)) else 1
	if _axis == 0:
		_ang_a_t -= rel.dot(U_A) * (_step_a / SLOT_DRAG_PX)
		if _items.size() < MIN_SLOTS_A and _items.size() > 0:
			_ang_a_t = clampf(_ang_a_t, 0.0, float(_items.size() - 1) * _step_a)
	else:
		_ang_b_t -= rel.dot(U_B) * (STEP_B / SLOT_DRAG_PX)
		var lc := _front_cat()
		if lc != _live_cat:
			_load_cat(lc)             # блоки на кольце живо следуют за передней категорией
	_update_label()

func _end_drag() -> void:
	_dragging = false
	var was_tap := _drag_dist < TAP_SLOP
	_snap_all()
	if was_tap:
		_choose()

# Довод обоих колец до ближайших слотов + коммит выбора.
func _snap_all() -> void:
	_ang_b_t = float(roundi(_ang_b_t / STEP_B)) * STEP_B
	_cat_idx = _front_cat()
	if _live_cat != _cat_idx:
		_load_cat(_cat_idx)           # страховка: live-догрузка могла не успеть за жестом
	var idx := _live_idx()
	if idx >= 0:
		_ang_a_t = _canon_ang_a(idx)
		_item_idx[CAT_KEYS[_cat_idx]] = idx
	_update_label()
	_sync_state()

# Ближайшее к текущему углу представление слота idx (для полного кольца слот повторяется
# каждый оборот — доводим в короткую сторону, а не через весь круг).
func _canon_ang_a(idx: int) -> float:
	var raw := float(roundi(_ang_a_t / _step_a)) * _step_a
	if _items.size() >= MIN_SLOTS_A:
		return raw                    # roundi уже дал ближайший кратный слот — он и есть idx
	return float(idx) * _step_a

func _choose() -> void:
	if _items.is_empty():
		return
	var idx := _live_idx()
	if idx < 0:
		return
	_item_idx[CAT_KEYS[_live_cat]] = idx
	if _overlay:
		_overlay.flash()              # подтверждение взятия — переживает rebuild кольца
	block_chosen.emit(int(_items[idx]["type"]))
