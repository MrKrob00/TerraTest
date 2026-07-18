class_name BlockGlobe
extends Control
# «Гироскоп-ролодекс» выбора блока в стройке. Спереди — «Х» из двух вытянутых овалов:
#   • кольцо «/» — БЛОКИ текущей категории (реальные превью-меши). Драг по диагонали
#     «право-верх ↔ лево-низ» крутит его; ВЫБРАННЫЙ блок стоит спереди СЛЕВА-СВЕРХУ,
#     крупнее остальных и в покое медленно вращается — его и берём тапом.
#   • кольцо «\» — 4 КАТЕГОРИИ (те же G.BLOCK_CATEGORIES, что в гараже) — цветные кристаллы.
#     Драг «право-низ ↔ лево-верх» крутит его; текущая категория спереди СПРАВА-СВЕРХУ.
# НОВОЕ: у КАЖДОЙ непустой категории — СВОЁ кольцо блоков. Кольца стоят СТОПКОЙ по глубине
# (ролодекс): переднее — текущая категория в полной детализации; остальные видны ЗА ним —
# мельче, приглушены тёмной вуалью, без бейджей. Смена категории ничего не пересобирает —
# стопка плавно «перелистывается», заднее кольцо выплывает вперёд с уже расставленными
# блоками (у каждой категории свой запомненный слот и угол).
# Ось жеста лочится по первой диагонали движения; отпустил — довод до ближайшего слота.
# Тап без движения — взять текущий блок. Пустая категория — «ПУСТО», всё пусто — «НЕТ БЛОКОВ».

signal block_chosen(block_type: int)

const SIZE := 320.0                    # сторона квадрата-виджета (крупнее: в кадре вся стопка)
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

# Стопка-ролодекс: кольцо категории ci стоит на глубине posmod(ci − текущая, 4).
const DEPTH_STEP := 2.6                # м между «карточками» стопки: заднее кольцо ЦЕЛИКОМ за вуалью
const DEPTH_SCALE := 0.85              # доп. масштаб корня кольца за каждый шаг глубины
const DEPTH_SPEED := 7.0               # скорость перелистывания стопки
const VEIL_Z := -1.25                  # тёмная вуаль сразу ЗА передним кольцом (его дальняя точка −1.196)
const VEIL2_Z := -3.9                  # вторая вуаль между d=1 и d=2: три яруса яркости 100/58/34%

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

# ── Фон: два овала-«Х», эхо-овалы стопки и мягкий тёмный диск. Всё передаётся снаружи
# готовыми полилиниями (вложенный класс не видит const внешнего по «голому» имени). ────
class XBg extends Control:
	const OVAL_B := Color(0.58, 0.47, 0.78, 0.45)
	const DISC := Color(0.03, 0.10, 0.13, 0.5)
	var oval_a := PackedVector2Array()
	var oval_b := PackedVector2Array()
	var echoes: Array = []             # PackedVector2Array овалов задних «карточек» стопки
	var front_color := Color(0.247, 0.6, 0.65)   # овал «/» красится в цвет текущей категории
	var center := Vector2.ZERO
	var disc_r := 100.0
	func _draw() -> void:
		draw_circle(center, disc_r, DISC)
		for e in echoes:
			if (e as PackedVector2Array).size() > 1:
				draw_polyline(e, Color(front_color, 0.14), 1.0, true)
		if oval_b.size() > 1:
			draw_polyline(oval_b, OVAL_B, 1.5, true)
		if oval_a.size() > 1:
			draw_polyline(oval_a, Color(front_color, 0.55), 1.5, true)

# ── Оверлей поверх 3D: кольцо у выбранного блока, вспышка взятия, «ПУСТО»/«НЕТ БЛОКОВ».
# Отдельный Control (не в риге): вспышка переживает rebuild колец после взятия. ────────
class Overlay extends Control:
	const RING := Color(0.247, 0.6, 0.65, 0.55)
	var anchor := Vector2.ZERO         # экранная точка выбранного блока (передняя точка «/»)
	var empty_all := false
	var empty_cat := false
	var flash_r := 0.0
	var flash_a := 0.0
	var _tw: Tween = null
	func _draw() -> void:
		if empty_all:
			_text("НЕТ\nБЛОКОВ", size * 0.5, 18)
			return
		draw_arc(anchor, 48.0, 0, TAU, 40, RING, 2.5)
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
		if _tw:
			_tw.kill()               # быстрый двойной тап — старая вспышка не борется с новой
		flash_r = 48.0
		flash_a = 0.9
		_tw = create_tween().set_parallel(true)
		_tw.tween_property(self, "flash_r", 100.0, 0.24)
		_tw.tween_property(self, "flash_a", 0.0, 0.24)

var _ang_b := 0.0                      # угол кольца категорий (слоты кратны STEP_B)
var _ang_b_t := 0.0
var _cat_idx := 0                      # закоммиченная категория
var _item_idx := {}                    # cat_key -> запомненный слот категории
var _by_cat := {}                      # cat_key -> Array[{type, count}]

# Стопка колец: по одному на НЕПУСТУЮ категорию.
# Кольцо: {ci, items, root, slots:[{node, visual, badge}], ang, ang_t, step, depth, depth_t}
var _rings: Array = []
var _ring_by_ci := {}                  # ci -> кольцо (Dictionary)

var _root_a: Node3D = null             # родитель корней всех колец стопки
var _root_b: Node3D = null             # держатели кристаллов категорий
var _gems: Array = []                  # [{node, mat}] — кристаллы, индекс = категория
var _label: Label = null
var _bg: XBg = null
var _overlay: Overlay = null
var _visual_cache := {}                # block_type -> шаблон меша (строим один раз)
var _all_empty := false
var _inv_seen := -1                    # размер инвентаря на последнем refresh (см. _process)

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

func _oval_px(gs: float, depth: float = 0.0) -> PackedVector2Array:
	var pts := PackedVector2Array()
	var s := pow(DEPTH_SCALE, depth)
	var dz := -DEPTH_STEP * depth
	for i in 49:
		var p := _ring_point(TAU * float(i) / 48.0, gs) * s
		pts.append(_to_px(Vector3(p.x, p.y, p.z + dz)))
	return pts

func _build_scene() -> void:
	_bg = XBg.new()
	_bg.center = Vector2(SIZE * 0.5, SIZE * 0.5)
	_bg.disc_r = SIZE * 0.485
	_bg.oval_a = _oval_px(1.0)
	_bg.oval_b = _oval_px(-1.0)
	_bg.echoes = [_oval_px(1.0, 1.0), _oval_px(1.0, 2.0)]   # эхо стопки: намёк на задние кольца
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

	# Тёмные вуали (прозрачные квады, глубину НЕ пишут — дефолт для transparent):
	# первая — сразу за передним кольцом (задние ярусы приглушены), вторая — между
	# ярусами d=1 и d=2 (глубже — ещё темнее): три яруса яркости под три яруса размера.
	# Размер квада — по ширине фрустума на его глубине (у второй он шире).
	_add_veil(sv, VEIL_Z, 4.8, 0.30)
	_add_veil(sv, VEIL2_Z, 6.0, 0.35)

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

func _add_veil(sv: SubViewport, z: float, side: float, alpha: float) -> void:
	var veil := MeshInstance3D.new()
	var q := QuadMesh.new()
	q.size = Vector2(side, side)
	var vm := StandardMaterial3D.new()
	vm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	vm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	vm.albedo_color = Color(0.02, 0.08, 0.11, alpha)
	q.material = vm
	veil.mesh = q
	veil.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	veil.position = Vector3(0, 0, z)
	sv.add_child(veil)

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
	_inv_seen = G.block_inventory.size()
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
	_rebuild_rings()
	_retarget_depths(true)
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

# Пересобрать ВСЮ стопку (инвентарь изменился): по кольцу на каждую непустую категорию.
# Каждое кольцо несёт ПОЛНЫЙ набор своих блоков и помнит свой угол (слот) — смена
# категории потом ничего не пересобирает, только глубины (см. _retarget_depths).
func _rebuild_rings() -> void:
	for r in _rings:
		_root_a.remove_child(r["root"])   # remove ДО free: без кадра сосуществования наборов
		(r["root"] as Node).queue_free()
	_rings.clear()
	_ring_by_ci.clear()
	for ci in CAT_KEYS.size():
		var items: Array = _by_cat[CAT_KEYS[ci]]
		if items.is_empty():
			continue
		var root := Node3D.new()
		_root_a.add_child(root)
		var step := TAU / float(maxi(items.size(), MIN_SLOTS_A))
		var mem := clampi(int(_item_idx[CAT_KEYS[ci]]), 0, items.size() - 1)
		var slots: Array = []
		for it in items:
			var holder := Node3D.new()
			var visual := _make_visual(int(it["type"]))
			holder.add_child(visual)
			var badge: Label3D = null
			if int(it["count"]) > 1:
				badge = Label3D.new()
				badge.text = "×%d" % int(it["count"])
				badge.font_size = 34
				badge.position = Vector3(0, -0.40, 0)
				badge.billboard = BaseMaterial3D.BILLBOARD_ENABLED
				# no_depth_test игнорирует вуаль — на задних кольцах бейдж прятался бы
				# некрасиво поверх неё, поэтому бейджи видны только у переднего кольца.
				badge.no_depth_test = true
				badge.visible = false
				holder.add_child(badge)
			root.add_child(holder)
			slots.append({"node": holder, "visual": visual, "badge": badge})
		var ring := {
			"ci": ci, "items": items, "root": root, "slots": slots,
			"ang": float(mem) * step, "ang_t": float(mem) * step, "step": step,
			"depth": 3.0, "depth_t": 0.0,
		}
		_rings.append(ring)
		_ring_by_ci[ci] = ring

# Цели глубин стопки: кольцо категории ci — на posmod(ci − текущая, 4). Переднее (0) —
# текущая категория; драг «\» вживую перекатывает стопку. Бейджи ×N — только спереди.
func _retarget_depths(instant: bool) -> void:
	var front := _front_cat()
	for r in _rings:
		r["depth_t"] = float(posmod(int(r["ci"]) - front, CAT_KEYS.size()))
		if instant:
			r["depth"] = r["depth_t"]
		var is_front: bool = int(r["ci"]) == front
		for s in r["slots"]:
			if s["badge"] != null:
				(s["badge"] as Label3D).visible = is_front

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

func _front_cat() -> int:
	return posmod(roundi(_ang_b_t / STEP_B), CAT_KEYS.size())

# Кольцо текущей (передней) категории; пустой Dictionary, если категория без блоков.
func _front_ring() -> Dictionary:
	return _ring_by_ci.get(_front_cat(), {})

# Слот у передней точки переднего кольца. Кольцо с «пробелом» (мало блоков) не заворачивается —
# края клампятся; полное (n >= MIN_SLOTS_A, шаг ровно TAU/n) листается по кругу бесшовно.
func _live_idx() -> int:
	var r := _front_ring()
	if r.is_empty():
		return -1
	var n: int = (r["items"] as Array).size()
	if n < MIN_SLOTS_A:
		return clampi(roundi(float(r["ang_t"]) / float(r["step"])), 0, n - 1)
	return posmod(roundi(float(r["ang_t"]) / float(r["step"])), n)

func _update_label() -> void:
	var key: String = CAT_KEYS[_front_cat()]
	var idx := _live_idx()
	var disp := "—"
	if idx >= 0:
		disp = _block_display_name(int(((_front_ring())["items"] as Array)[idx]["type"]))
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
	if _bg:
		_bg.front_color = CAT_COLORS[CAT_KEYS[_front_cat()]]
		_bg.queue_redraw()
	if _overlay:
		_overlay.empty_all = _all_empty
		_overlay.empty_cat = _front_ring().is_empty() and not _all_empty
		_overlay.queue_redraw()
	if _label:
		_label.visible = not _all_empty     # при пустом инвентаре текст ведёт оверлей

func _process(delta: float) -> void:
	if not visible or _root_a == null:
		return
	# Пылесос чёрной дыры может докинуть блок прямо во время стройки — подхватываем
	# (не в драге: refresh пересаживает углы мгновенно и сбил бы жест).
	if not _dragging and G.block_inventory.size() != _inv_seen:
		refresh()
	var k := minf(SNAP_SPEED * delta, 1.0)
	_ang_b = lerpf(_ang_b, _ang_b_t, k)
	var dk := minf(DEPTH_SPEED * delta, 1.0)
	var sk := minf(10.0 * delta, 1.0)   # без клампа фриз-кадр перебрасывает lerp за цель
	var front := _front_cat()
	var sel := _live_idx()
	var settled := absf(_ang_b - _ang_b_t) < 0.02 and not _dragging
	# Стопка колец: глубина/масштаб корня, позиции блоков; у переднего — выбор и вращение.
	for r in _rings:
		r["ang"] = lerpf(float(r["ang"]), float(r["ang_t"]), k)
		r["depth"] = lerpf(float(r["depth"]), float(r["depth_t"]), dk)
		var d: float = r["depth"]
		var root: Node3D = r["root"]
		root.position = Vector3(0, 0, -DEPTH_STEP * d)
		root.scale = Vector3.ONE * pow(DEPTH_SCALE, d)
		var is_front: bool = int(r["ci"]) == front
		var ring_settled := is_front and settled \
				and absf(float(r["ang"]) - float(r["ang_t"])) < 0.02 and d < 0.05
		var slots: Array = r["slots"]
		for i in slots.size():
			var holder: Node3D = slots[i]["node"]
			holder.position = _ring_point(float(i) * float(r["step"]) - float(r["ang"]), 1.0)
			var target_s := SELECT_SCALE if (is_front and i == sel) else 1.0
			holder.scale = holder.scale.lerp(Vector3.ONE * target_s, sk)
			var vis: Node3D = slots[i]["visual"]
			if is_front and i == sel:
				if ring_settled:
					vis.rotation.y += IDLE_SPIN * delta
			else:
				vis.rotation.y = 0.0
	# Кольцо категорий: передний кристалл крупнее и медленно крутится.
	for ci in _gems.size():
		var g: Node3D = _gems[ci]["node"]
		g.position = _ring_point(float(ci) * STEP_B - _ang_b, -1.0)
		var gs := 1.18 if ci == front else 1.0
		g.scale = g.scale.lerp(Vector3.ONE * gs, sk)
		if ci == front and settled:
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
		var r := _front_ring()
		if not r.is_empty():
			var n: int = (r["items"] as Array).size()
			r["ang_t"] = float(r["ang_t"]) - rel.dot(U_A) * (float(r["step"]) / SLOT_DRAG_PX)
			if n < MIN_SLOTS_A:
				r["ang_t"] = clampf(float(r["ang_t"]), 0.0, float(n - 1) * float(r["step"]))
	else:
		_ang_b_t -= rel.dot(U_B) * (STEP_B / SLOT_DRAG_PX)
		_retarget_depths(false)       # стопка вживую перекатывается за передней категорией
	_update_label()
	_sync_state_light()

# Лёгкая версия _sync_state для драга: только цвет переднего овала и флаг «ПУСТО».
func _sync_state_light() -> void:
	if _bg:
		_bg.front_color = CAT_COLORS[CAT_KEYS[_front_cat()]]
		_bg.queue_redraw()
	if _overlay:
		_overlay.empty_cat = _front_ring().is_empty() and not _all_empty
		_overlay.queue_redraw()

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
	_retarget_depths(false)
	var r := _front_ring()
	if not r.is_empty():
		var idx := _live_idx()
		if idx >= 0:
			r["ang_t"] = _canon_ang(r, idx)
			_item_idx[CAT_KEYS[_cat_idx]] = idx
	_update_label()
	_sync_state()

# Ближайшее к текущему углу представление слота idx (для полного кольца слот повторяется
# каждый оборот — доводим в короткую сторону, а не через весь круг).
func _canon_ang(r: Dictionary, idx: int) -> float:
	var raw := float(roundi(float(r["ang_t"]) / float(r["step"]))) * float(r["step"])
	if (r["items"] as Array).size() >= MIN_SLOTS_A:
		return raw                    # roundi уже дал ближайший кратный слот — он и есть idx
	return float(idx) * float(r["step"])

func _choose() -> void:
	var r := _front_ring()
	if r.is_empty():
		return
	var idx := _live_idx()
	if idx < 0:
		return
	_item_idx[CAT_KEYS[_front_cat()]] = idx
	if _overlay:
		_overlay.flash()              # подтверждение взятия — переживает rebuild колец
	block_chosen.emit(int((r["items"] as Array)[idx]["type"]))
