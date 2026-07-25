class_name BlockGlobe
extends Control
# «Атом»-АРМИЛЛЯРА выбора блока в стройке (по описанию игрока, docs/atom_picker_reference.md).
# ГОРИЗОНТАЛЬНОЕ красное кольцо (в плоскости XZ, экватор) = выбор ТИПА — крутится вокруг
# вертикальной оси Y (драг влево/вправо). На нём «построены» ВЕРТИКАЛЬНЫЕ кольца-меридианы
# по одному на тип, расставленные веером через AZ=45° (PI/4) — при 4 типах они дают 4 РАЗНЫЕ
# плоскости и НИКОГДА не совпадают (при 90° передняя и задняя слипались — это и был баг).
# Вертикальное кольцо = горизонтальное, наклонённое на 90°. Отсюда раскладка жестов:
#   • ТИП: драг ВЛЕВО/ВПРАВО крутит атом (_spin) — меридианы едут по кругу; тот, что вышел
#     ЛИЦОМ к камере (β≈0, плоскость XY, вертикальный) = активная категория (1A).
#   • БЛОК: драг ВВЕРХ/ВНИЗ листает переднее вертикальное кольцо — блоки едут по нему мимо
#     точки выбора (ближний к камере верх кольца); тап без движения берёт тот, что в ней (2A).
# Смотрим чуть СВЕРХУ (VIEW_PITCH ~29°): экватор читается горизонтальным овалом-рулём, а
# переднее кольцо — вертикальным овалом лицом к игроку. Ось жеста лочится по первому движению.
# Пустая категория спереди — «ПУСТО», совсем без блоков — «НЕТ БЛОКОВ».

signal block_chosen(block_type: int)

const SIZE := 320.0
const CAT_KEYS := ["attack", "blocks", "factory", "other"]
const CAT_NAMES := {"attack": "Атака", "blocks": "Блоки", "factory": "Фабрика", "other": "Остальное"}
const CAT_COLORS := {
	"attack": Color(0.85, 0.36, 0.32), "blocks": Color(0.30, 0.62, 0.66),
	"factory": Color(0.85, 0.66, 0.30), "other": Color(0.62, 0.46, 0.80),
}

# Геометрия карусели. Категория ci стоит на ободе диска под азимутом β = base_ci + _spin;
# при β≈0 её кольцо спереди (ближе к камере) и смотрит на игрока = активная.
const AZ := TAU / 8.0                  # 45° (PI/4) между меридианами: 4 типа = 4 РАЗНЫЕ плоскости,
#                                        не слипаются (при 90° перед/зад совпадали — тот баг)
const R_DIAL := 1.05                   # радиус красного диска-руля (экватор; выбор типа)
const R_RING := 1.0                    # радиус кольца-меридиана (≈ экватор → читается как глобус)
const CORE_R := 0.26                   # радиус ядра-сферы
const CAM_Z := 6.4
const FOV := 30.0
const SLOT := 0.34                     # целевой габарит превью блока
const MIN_SLOTS_A := 5                 # меньше блоков — кольцо с «пробелом», без заворота
const SELECT_SCALE := 1.2
const IDLE_SPIN := 0.6                 # рад/с — вращение выбранного блока в покое
const GHOST_ALPHA := 0.4               # альфа «призрачных» неактивных колец
const ACTIVE_RING := Color(0.28, 0.55, 0.95)   # текущий тип — синее кольцо (по просьбе игрока)
# Смотрим на диск чуть СВЕРХУ (положительный питч: перед диска ниже зада, как на пульт) —
# руль читается горизонтальным овалом, переднее кольцо стоит вертикально. Точка выбора —
# ближний (верхний) край переднего кольца (θ_front=+90°). Только питч — симметрично.
const VIEW_PITCH := 0.5                # ~+29°
# Yaw ВСЕГО вида вокруг вертикали Y: активное (переднее) кольцо смотрит БОКОМ на камеру
# (нормаль ~68° от оси взгляда), а не лицом. Красное кольцо-экватор при этом остаётся
# горизонтальным (Y-поворот сохраняет горизонт). Смена типа плавная — это общий вид, без
# скачков. ~65° (1.134 рад). Точка выбора считается там, где дотична вертикальна → скролл ↕.
const VIEW_YAW := 1.134

const SPIN_SPEED := 8.0
const SCROLL_SPEED := 8.0
const SPIN_DRAG_PX := 90.0             # px горизонтального драга на одну категорию (шаг 45°)
const SCROLL_DRAG_PX := 90.0           # px вертикального драга на один блок
const TAP_SLOP := 6.0
const LOCK_DIST := 10.0

# ── Фон: ядро-диск, красный обод-руль и контуры колец категорий (в их цветах). ────────
class XBg extends Control:
	const CORE := Color(0.78, 0.80, 0.86, 0.9)
	const DIAL := Color(0.90, 0.28, 0.28, 0.85)
	var dial := PackedVector2Array()
	var ovals: Array = []              # [{pts, color, w}]
	var core_at := Vector2.ZERO
	var core_r := 26.0
	func _draw() -> void:
		if dial.size() > 1:
			draw_polyline(dial, DIAL, 2.5, true)
		for o in ovals:
			var pts: PackedVector2Array = o["pts"]
			if pts.size() > 1:
				draw_polyline(pts, o["color"], o["w"], true)
		draw_circle(core_at, core_r, CORE)

# ── Оверлей поверх 3D: кольцо у точки выбора, вспышка взятия, «ПУСТО»/«НЕТ БЛОКОВ». ────
class Overlay extends Control:
	const RING := Color(0.90, 0.28, 0.28, 0.75)
	var anchor := Vector2.ZERO
	var empty_all := false
	var empty_cat := false
	var flash_r := 0.0
	var flash_a := 0.0
	var _tw: Tween = null
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
		if flash_a > 0.001:
			queue_redraw()
	func flash() -> void:
		if _tw:
			_tw.kill()
		flash_r = 40.0
		flash_a = 0.9
		_tw = create_tween().set_parallel(true)
		_tw.tween_property(self, "flash_r", 86.0, 0.24)
		_tw.tween_property(self, "flash_a", 0.0, 0.24)

var _spin := 0.0                       # угол диска (растёт непрерывно, категории кратны AZ)
var _spin_t := 0.0
var _cat_idx := 0                      # закоммиченная (передняя) категория
var _item_idx := {}                    # cat_key -> запомненный слот
var _by_cat := {}                      # cat_key -> Array[{type, count}]

# Кольцо: {ci, items, root, slots:[{node, visual, badge}], meshes:[{mi, orig}], ghost,
#          ghosted, ang, ang_t, step}
var _rings: Array = []
var _ring_by_ci := {}

var _view := Basis()                   # наклон вида (смотрим сверху на диск)
var _theta_front := 0.0                # угол точки выбора на переднем кольце (ближняя точка)
var _root: Node3D = null
var _label: Label = null
var _bg: XBg = null
var _overlay: Overlay = null
var _visual_cache := {}
var _all_empty := false
var _inv_seen := -1

var _dragging := false
var _drag_dist := 0.0
var _drag_acc := Vector2.ZERO
var _axis := -1                        # -1 не решено, 0 — блоки (верт.), 1 — тип (гориз.)

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	for k in CAT_KEYS:
		_by_cat[k] = []
		_item_idx[k] = 0
	_view = Basis(Vector3.UP, VIEW_YAW) * Basis(Vector3.RIGHT, VIEW_PITCH)
	# Точка выбора: θ на переднем кольце (β=0), где ЭКРАННАЯ дотична максимально ВЕРТИКАЛЬНА
	# (тогда драг вверх/вниз катит блоки ↕) и блок ближе к камере. Раньше брали ближнюю точку
	# (atan2), но при yaw её дотична диагональна — искали бы косой скролл. Считаем перебором.
	var best := -INF
	for i in 360:
		var th := TAU * float(i) / 360.0
		var sc := _vtan_score(th)
		if sc > best:
			best = sc
			_theta_front = th
	_build_scene()

# Кольца-категории — МЕРИДИАНЫ на общей вертикальной оси (как в прототипе-«атоме»), а не
# карусель по ободу. Все концентричны в центре → поворот всей конструкции на AZ переводит
# меридианы друг в друга (та же фигура). Центр всегда в начале координат.
func _ring_center(_beta: float) -> Vector3:
	return Vector3.ZERO

# Точка кольца-меридиана: вертикальный круг радиуса R_RING в плоскости, содержащей ось Y,
# повёрнутой вокруг Y на азимут β (tiltY из прототипа). Полюса (0,±R,0) общие у всех колец.
# На переднем (β=0) круг в плоскости XY — лицом к камере; боковые (β=±90°) видны с ребра,
# «повёрнуты влево-вправо», а не наклонены.
func _ring_point(theta: float, beta: float) -> Vector3:
	var ct := cos(theta)
	return R_RING * Vector3(ct * cos(beta), sin(theta), -ct * sin(beta))

# Азимут кольца ci: base + _spin. Диск крутится непрерывно; передняя = β≈0.
func _beta_of(ci: int) -> float:
	return float(ci) * AZ + _spin

func _to_px(world: Vector3) -> Vector2:
	var ppw := (SIZE * 0.5) / (tan(deg_to_rad(FOV) * 0.5) * (CAM_Z - world.z))
	return Vector2(SIZE * 0.5 + world.x * ppw, SIZE * 0.5 - world.y * ppw)

# Оценка «здесь скролл будет вертикальным»: угол экранной дотичной переднего кольца (β=0) в
# точке θ (π/2 = вертикаль) плюс близость к камере. Максимум → точка выбора (см. _ready).
func _vtan_score(th: float) -> float:
	var e := 0.005
	var a := _to_px(_view * _ring_point(th - e, 0.0))
	var b := _to_px(_view * _ring_point(th + e, 0.0))
	var vert := atan2(absf(b.y - a.y), absf(b.x - a.x))
	return vert + (_view * _ring_point(th, 0.0)).z * 8.0

func _ring_oval_px(beta: float) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for i in 33:
		pts.append(_to_px(_view * _ring_point(TAU * float(i) / 32.0, beta)))
	return pts

func _dial_px() -> PackedVector2Array:
	var pts := PackedVector2Array()
	for i in 49:
		var a := TAU * float(i) / 48.0
		pts.append(_to_px(_view * (R_DIAL * Vector3(cos(a), 0, sin(a)))))
	return pts

func _build_scene() -> void:
	_bg = XBg.new()
	_bg.core_at = _to_px(_view * Vector3.ZERO)
	_bg.core_r = CORE_R * (SIZE * 0.5) / (tan(deg_to_rad(FOV) * 0.5) * CAM_Z)
	_bg.dial = _dial_px()
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
	var fill := DirectionalLight3D.new()
	fill.rotation = Vector3(0.7, 2.4, 0)
	fill.light_energy = 0.4
	sv.add_child(fill)

	var core := MeshInstance3D.new()
	var sph := SphereMesh.new()
	sph.radius = CORE_R
	sph.height = CORE_R * 2.0
	var cm := StandardMaterial3D.new()
	cm.albedo_color = Color(0.72, 0.75, 0.82)
	cm.metallic = 0.3
	cm.roughness = 0.35
	sph.material = cm
	core.mesh = sph
	core.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	sv.add_child(core)

	_root = Node3D.new()
	_root.basis = _view
	sv.add_child(_root)

	_overlay = Overlay.new()
	_overlay.anchor = _to_px(_view * _ring_point(_theta_front, 0.0))
	_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_overlay)

	_label = Label.new()
	_label.position = Vector2(8, 0)
	_label.add_theme_font_size_override("font_size", 14)
	_label.add_theme_color_override("font_color", Color(0.85, 0.95, 1.0))
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_label)

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
	if (_by_cat[CAT_KEYS[_cat_idx]] as Array).is_empty() and not _all_empty:
		_cat_idx = _nearest_nonempty(_cat_idx)
	# Ставим передней текущую категорию (β=0 → _spin = −cat·AZ).
	_spin = -float(_cat_idx) * AZ
	_spin_t = _spin
	_rebuild_rings()
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

func _rebuild_rings() -> void:
	for r in _rings:
		_root.remove_child(r["root"])
		(r["root"] as Node).queue_free()
	_rings.clear()
	_ring_by_ci.clear()
	for ci in CAT_KEYS.size():
		var items: Array = _by_cat[CAT_KEYS[ci]]
		if items.is_empty():
			continue
		var root := Node3D.new()
		_root.add_child(root)
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
				badge.position = Vector3(0, -0.34, 0)
				badge.billboard = BaseMaterial3D.BILLBOARD_ENABLED
				badge.no_depth_test = true
				badge.visible = false
				holder.add_child(badge)
			root.add_child(holder)
			slots.append({"node": holder, "visual": visual, "badge": badge})
		var meshes: Array = []
		for s2 in slots:
			for m in (s2["visual"] as Node).find_children("*", "MeshInstance3D", true, false):
				meshes.append({"mi": m, "orig": (m as MeshInstance3D).material_override})
		var ghost := StandardMaterial3D.new()
		ghost.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		ghost.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		ghost.cull_mode = BaseMaterial3D.CULL_DISABLED
		ghost.albedo_color = Color(CAT_COLORS[CAT_KEYS[ci]], GHOST_ALPHA)
		_rings.append({
			"ci": ci, "items": items, "root": root, "slots": slots, "meshes": meshes,
			"ghost": ghost, "ghosted": -1,
			"ang": float(mem) * step, "ang_t": float(mem) * step, "step": step,
		})
		_ring_by_ci[ci] = _rings[_rings.size() - 1]

# ── Реальный меш блока: собираем из сцены, НЕ запуская логику ─────────────────────
func _make_visual(block_type: int) -> Node3D:
	var data := _visual_template(block_type)
	var container := Node3D.new()
	if not bool(data["ok"]):
		var mi := MeshInstance3D.new()
		var box := BoxMesh.new(); box.size = Vector3(SLOT, SLOT, SLOT)
		var m := StandardMaterial3D.new(); m.albedo_color = _color_for(block_type); m.roughness = 0.55
		box.material = m; mi.mesh = box
		container.add_child(mi)
		return container
	var inner := Node3D.new()
	var s: float = data["scale"]
	var ctr: Vector3 = data["center"]
	inner.transform = Transform3D(Basis().scaled(Vector3.ONE * s), -ctr * s)
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
	var inst: Node = scene.instantiate()
	var acc := AABB()
	var has := false
	var stack: Array = [[inst, Transform3D.IDENTITY]]
	while not stack.is_empty():
		var pair = stack.pop_back()
		var n = pair[0]
		var xf: Transform3D = pair[1]
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
					continue
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
	inst.free()
	if has and not (data["parts"] as Array).is_empty():
		var maxd: float = maxf(acc.size.x, maxf(acc.size.y, acc.size.z))
		data["scale"] = (SLOT / maxd) if maxd > 1e-4 else 1.0
		data["center"] = acc.get_center()
		data["ok"] = true
	_visual_cache[block_type] = data
	return data

func _active_material(mi: MeshInstance3D) -> Material:
	if mi.material_override != null:
		return mi.material_override
	if mi.get_surface_override_material_count() > 0 and mi.get_surface_override_material(0) != null:
		return mi.get_surface_override_material(0)
	if mi.mesh != null and mi.mesh.get_surface_count() > 0:
		return mi.mesh.surface_get_material(0)
	return null

func _color_for(block_type: int) -> Color:
	var h := float(block_type % 12) / 12.0
	return Color.from_hsv(h, 0.55, 0.95)

# Передняя (активная) категория: та, чей азимут ближе к 0 (перед). β=ci·AZ+_spin_t → ci≈−_spin/AZ.
func _front_cat() -> int:
	return posmod(roundi(-_spin_t / AZ), CAT_KEYS.size())

func _front_ring() -> Dictionary:
	return _ring_by_ci.get(_front_cat(), {})

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

# Контуры колец на фоне — цвет категории, активное ярче.
func _sync_bg_ovals() -> void:
	if _bg == null:
		return
	var front := _front_cat()
	var ovals: Array = []
	for r in _rings:
		var ci := int(r["ci"])
		if ci == front:
			continue
		ovals.append({"pts": _ring_oval_px(_beta_of(ci)),
				"color": Color(CAT_COLORS[CAT_KEYS[ci]], 0.25), "w": 1.0})
	if _ring_by_ci.has(front):
		ovals.append({"pts": _ring_oval_px(_beta_of(front)),
				"color": Color(ACTIVE_RING, 0.9), "w": 1.8})   # текущий тип — синее вертикальное кольцо
	_bg.ovals = ovals
	_bg.queue_redraw()

func _sync_state() -> void:
	_sync_bg_ovals()
	if _overlay:
		_overlay.empty_all = _all_empty
		_overlay.empty_cat = _front_ring().is_empty() and not _all_empty
		_overlay.queue_redraw()
	if _label:
		_label.visible = not _all_empty

func _stack_settled() -> bool:
	if absf(_spin - _spin_t) >= 0.01:
		return false
	for r in _rings:
		if absf(float(r["ang"]) - float(r["ang_t"])) >= 0.02:
			return false
	return true

func _process(delta: float) -> void:
	if not visible or _root == null:
		return
	if not _dragging and G.block_inventory.size() != _inv_seen and _stack_settled():
		refresh()
	var pk := minf(SPIN_SPEED * delta, 1.0)
	_spin = lerpf(_spin, _spin_t, pk)
	var ak := minf(SCROLL_SPEED * delta, 1.0)
	var sk := minf(10.0 * delta, 1.0)
	var front := _front_cat()
	var sel := _live_idx()
	var settled := absf(_spin - _spin_t) < 0.01 and not _dragging
	for r in _rings:
		r["ang"] = lerpf(float(r["ang"]), float(r["ang_t"]), ak)
		var ci := int(r["ci"])
		var beta := _beta_of(ci)
		var is_front: bool = ci == front
		var want_ghost := 0 if is_front else 1
		if int(r["ghosted"]) != want_ghost:
			r["ghosted"] = want_ghost
			for me in r["meshes"]:
				(me["mi"] as MeshInstance3D).material_override = \
						(r["ghost"] if want_ghost == 1 else me["orig"])
		var ring_settled := is_front and settled \
				and absf(float(r["ang"]) - float(r["ang_t"])) < 0.02
		var slots: Array = r["slots"]
		for i in slots.size():
			var holder: Node3D = slots[i]["node"]
			# Активное (переднее) кольцо вертикально ЛИЦОМ к камере, листается вверх/вниз (точка
			# выбора = θ_front); остальные меридианы стоят веером через 45°, призрачные.
			holder.position = _ring_point(_theta_front + float(i) * float(r["step"]) - float(r["ang"]), beta)
			var target_s := SELECT_SCALE if (is_front and i == sel) else 1.0
			holder.scale = holder.scale.lerp(Vector3.ONE * target_s, sk)
			if slots[i]["badge"] != null:
				(slots[i]["badge"] as Label3D).visible = is_front
			var vis: Node3D = slots[i]["visual"]
			if is_front and i == sel:
				if ring_settled:
					vis.rotation.y += IDLE_SPIN * delta
			else:
				vis.rotation.y = 0.0
	if not settled:
		_sync_bg_ovals()

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
	_drag_dist += rel.length()
	_drag_acc += rel
	if _axis < 0:
		if _drag_dist < LOCK_DIST:
			return
		# Горизонталь (|x|>|y|) — крутим диск (тип); вертикаль — листаем переднее кольцо (блок).
		_axis = 1 if absf(_drag_acc.x) >= absf(_drag_acc.y) else 0
	if _axis == 1:
		_spin_t += rel.x * (AZ / SPIN_DRAG_PX)
	else:
		var r := _front_ring()
		if not r.is_empty():
			var n: int = (r["items"] as Array).size()
			r["ang_t"] = float(r["ang_t"]) - rel.y * (float(r["step"]) / SCROLL_DRAG_PX)
			if n < MIN_SLOTS_A:
				r["ang_t"] = clampf(float(r["ang_t"]), 0.0, float(n - 1) * float(r["step"]))
	_update_label()
	_sync_state()

func _end_drag() -> void:
	_dragging = false
	var was_tap := _drag_dist < TAP_SLOP
	_snap_all()
	if was_tap:
		_choose()

func _snap_all() -> void:
	_spin_t = float(roundi(_spin_t / AZ)) * AZ
	# Не залипаем на пустой категории: доводим до ближайшей непустой кратчайшим шагом.
	if not _all_empty and (_by_cat[CAT_KEYS[_front_cat()]] as Array).is_empty():
		var d := posmod(_nearest_nonempty(_front_cat()) - _front_cat() + 2, CAT_KEYS.size()) - 2
		_spin_t -= float(d) * AZ                # front = −_spin/AZ, поэтому шаг d по front = −d·AZ по _spin
	# Гигиена роста (период TAU вид не меняет).
	var wraps := floorf(_spin_t / TAU)
	_spin_t -= wraps * TAU
	_spin -= wraps * TAU
	_cat_idx = _front_cat()
	var r := _front_ring()
	if not r.is_empty():
		var idx := _live_idx()
		if idx >= 0:
			r["ang_t"] = _canon_ang(r, idx)
			_item_idx[CAT_KEYS[_cat_idx]] = idx
	_update_label()
	_sync_state()

func _canon_ang(r: Dictionary, idx: int) -> float:
	var raw := float(roundi(float(r["ang_t"]) / float(r["step"]))) * float(r["step"])
	if (r["items"] as Array).size() >= MIN_SLOTS_A:
		return raw
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
		_overlay.flash()
	block_chosen.emit(int((r["items"] as Array)[idx]["type"]))
