class_name BlockGlobe
extends Control
# «Шар» выбора блока для режима стройки — 3D-сфера с превью блоков в SubViewport,
# показана только ЧЕТВЕРТЬЮ КРУГА в правом нижнем углу экрана. Никаких масок/шейдеров:
# сам Control — квадрат 2R×2R, ЦЕНТР которого стоит РОВНО в правом нижнем углу экрана,
# остальные 3/4 уходят за край окна и просто не рендерятся — остаётся верхне-левая
# четверть, в ней и «всплывает» текущий выбранный блок (левее и выше центра).
#
# Два независимых вращения (как «глобус»):
#   • горизонтальный драг (X экрана) — крутит ДОЛГОТУ: перебирает блоки ВНУТРИ
#     текущей категории;
#   • вертикальный драг (Y экрана) — крутит ШИРОТУ: переключает саму категорию
#     (Атака / Блоки / Фабрика / Остальное — те же G.BLOCK_CATEGORIES, что в гараже).
# Отпустил — довод до ближайшего слота (снап). Тап без движения — берёт блок,
# который сейчас «смотрит» на камеру (в центре), в руку.

signal block_chosen(block_type: int)

const RADIUS := 190.0
const CAT_KEYS := ["attack", "blocks", "factory", "other"]
const CAT_NAMES := {"attack": "Атака", "blocks": "Блоки", "factory": "Фабрика", "other": "Остальное"}
const LAT_STEP := 0.49                 # ~28°: шаг между категориями по широте
const LON_STEP := 0.80                 # ~46°: шаг между слотами по долготе
const DRAG_SENS := 0.006               # рад на пиксель драга
const SNAP_SPEED := 8.0                # скорость довода до слота после отпускания
const ITEM_DIST := 2.4                 # радиус, на котором висят превью-кубики
const CAM_Z := 5.2                     # позиция камеры по Z (смотрит в −Z на риг)
const FOV := 30.0                      # угол камеры (для расчёта смещения рига)

# Голубой фон-«четвертькруга» в углу: рисуется нодой (draw_colored_polygon сектором),
# центр = угол экрана (локально (r,r)), сектор смотрит вверх-влево — ровно та четверть,
# что видна на экране (остальные 3/4 Control-а за краем окна). Цвета под остальной UI
# (см. hud._make_panel_style) держим ЛОКАЛЬНО: вложенный класс GDScript не видит const
# внешнего класса по «голому» имени (как и другие inner-классы в hud.gd — цвета в них свои).
class QuarterBg extends Control:
	const FILL := Color(0.055, 0.16, 0.19, 0.92)
	const ACCENT := Color(0.247, 0.6, 0.65, 0.75)
	var radius := 190.0
	func _draw() -> void:
		var c := Vector2(radius, radius)             # центр = угол экрана
		var steps := 28
		var pts := PackedVector2Array([c])
		for i in steps + 1:
			var a := PI + (PI * 0.5) * float(i) / float(steps)   # от «влево» (PI) до «вверх» (1.5PI)
			pts.append(c + Vector2(cos(a), sin(a)) * radius)
		draw_colored_polygon(pts, FILL)
		draw_arc(c, radius, PI, PI * 1.5, 40, ACCENT, 2.5)

var _lon: float = 0.0
var _lat: float = 0.0
var _lon_target: float = 0.0
var _lat_target: float = 0.0
var _cat_idx: int = 0
var _item_idx: Dictionary = {}         # cat_key -> текущий индекс слота в категории

var _rig: Node3D = null
var _label: Label = null
var _by_cat: Dictionary = {}           # cat_key -> Array[{type:int, count:int}]

var _dragging: bool = false
var _drag_moved: bool = false
var _touch_index: int = -1

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	_build_scene()

func _build_scene() -> void:
	# Голубой фон-четвертькруга ПОД 3D (SubViewport прозрачный — фон просвечивает).
	var bg := QuarterBg.new()
	bg.radius = RADIUS
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	var svc := SubViewportContainer.new()
	svc.stretch = true
	svc.set_anchors_preset(Control.PRESET_FULL_RECT)
	svc.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(svc)

	var sv := SubViewport.new()
	sv.size = Vector2i(int(RADIUS * 2.0), int(RADIUS * 2.0))
	sv.own_world_3d = true
	sv.transparent_bg = true
	# WHEN_VISIBLE (не ALWAYS): рендерится, только пока сам глобус видим (стройка) —
	# не тратит кадры, пока скрыт (тот же подход, что у кубиков в _cube_view).
	sv.render_target_update_mode = SubViewport.UPDATE_WHEN_VISIBLE
	svc.add_child(sv)

	var cam := Camera3D.new()
	cam.fov = FOV
	cam.transform = Transform3D(Basis(), Vector3(0, 0, CAM_Z))
	sv.add_child(cam)

	var light := DirectionalLight3D.new()
	light.rotation = Vector3(-0.6, -0.5, 0)
	sv.add_child(light)

	_rig = Node3D.new()
	# Смещаем риг так, чтобы ТЕКУЩИЙ (передний) блок проецировался в ЦЕНТР ВИДИМОЙ
	# четверти (uv≈0.25,0.25 — вверх-влево от угла), а не в сам угол (=центр вьюпорта),
	# где он был наполовину за краем экрана. Из-за этого раньше «нижний» тип оказывался
	# в невидимой части и его нельзя было толком выбрать. Полувысота кадра на глубине
	# переднего блока → сдвигаем на её половину влево и вверх.
	var half := tan(deg_to_rad(FOV) * 0.5) * (CAM_Z - ITEM_DIST)
	_rig.position = Vector3(-0.5 * half, 0.5 * half, 0.0)
	sv.add_child(_rig)

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
	# Если текущая категория опустела — ищем ближайшую непустую, иначе снап её потеряет.
	if (_by_cat[CAT_KEYS[_cat_idx]] as Array).is_empty():
		for ci in CAT_KEYS.size():
			if not (_by_cat[CAT_KEYS[ci]] as Array).is_empty():
				_cat_idx = ci
				break
	_lat_target = _lat_for_cat(_cat_idx)
	_lat = _lat_target
	_lon_target = float(int(_item_idx.get(CAT_KEYS[_cat_idx], 0))) * LON_STEP
	_lon = _lon_target
	_rebuild_rig()
	_update_label()

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
		c.queue_free()
	for ci in CAT_KEYS.size():
		var items: Array = _by_cat[CAT_KEYS[ci]]
		if items.is_empty():
			continue
		var lat := _lat_for_cat(ci)
		for ii in items.size():
			_rig.add_child(_make_item_node(items[ii], lat, float(ii) * LON_STEP))

func _make_item_node(it: Dictionary, lat: float, lon: float) -> Node3D:
	var holder := Node3D.new()
	holder.position = Vector3(sin(lon) * cos(lat), sin(lat), cos(lon) * cos(lat)) * ITEM_DIST

	var mesh := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(0.62, 0.62, 0.62)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = _color_for(int(it["type"]))
	mat.roughness = 0.55
	box.material = mat
	mesh.mesh = box
	holder.add_child(mesh)

	if int(it["count"]) > 1:
		var lbl := Label3D.new()
		lbl.text = "×%d" % int(it["count"])
		lbl.font_size = 40
		lbl.position = Vector3(0, -0.5, 0)
		lbl.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		lbl.no_depth_test = true
		holder.add_child(lbl)

	return holder

# Цвет-заглушка по типу (v1 — плейсхолдер вместо реальных мешей блоков: настоящие
# сцены блоков — RigidBody3D с логикой/скриптами, тащить их в мини-превью тяжелее и
# рискованнее; можно заменить на реальные меши позже).
func _color_for(block_type: int) -> Color:
	var h := float(block_type % 12) / 12.0
	return Color.from_hsv(h, 0.55, 0.95)

func _update_label() -> void:
	var key: String = CAT_KEYS[_cat_idx]
	var items: Array = _by_cat.get(key, [])
	var name := "" if items.is_empty() else _block_display_name(int(items[int(_item_idx.get(key, 0))]["type"]))
	_label.text = "%s\n%s" % [CAT_NAMES.get(key, key), name]

func _block_display_name(block_type: int) -> String:
	var names: Array = G.Block.keys()
	if block_type >= 0 and block_type < names.size():
		return str(names[block_type]).capitalize()
	return "?"

func _process(delta: float) -> void:
	if not visible or _rig == null:
		return
	_lon = lerp_angle(_lon, _lon_target, SNAP_SPEED * delta)
	_lat = lerp(_lat, _lat_target, SNAP_SPEED * delta)
	_rig.rotation = Vector3(-_lat, -_lon, 0)

func _gui_input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		if event.pressed:
			_touch_index = event.index
			_dragging = true
			_drag_moved = false
		elif event.index == _touch_index:
			_end_drag()
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_dragging = true
			_drag_moved = false
		else:
			_end_drag()
	elif event is InputEventScreenDrag and event.index == _touch_index:
		_apply_drag(event.relative)
	elif event is InputEventMouseMotion and _dragging:
		_apply_drag(event.relative)

func _apply_drag(rel: Vector2) -> void:
	if rel.length() > 1.0:
		_drag_moved = true
	_lon_target -= rel.x * DRAG_SENS
	var half_span := LAT_STEP * float(CAT_KEYS.size() - 1) * 0.5
	_lat_target = clampf(_lat_target - rel.y * DRAG_SENS, -half_span, half_span)
	_update_label_live()          # лейбл сразу показывает, что окажется под выбором

func _end_drag() -> void:
	_dragging = false
	_touch_index = -1
	if not _drag_moved:
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

func _snap_to_nearest() -> void:
	_cat_idx = _nearest_cat(_lat_target)
	_lat_target = _lat_for_cat(_cat_idx)
	var idx := _item_at_lon(_cat_idx)
	if idx < 0:
		_update_label()
		return
	_item_idx[CAT_KEYS[_cat_idx]] = idx
	_lon_target = float(idx) * LON_STEP
	_update_label()

# Живой лейбл во время драга — от ТЕКУЩИХ целей (до снапа), чтобы игрок видел выбор сразу.
func _update_label_live() -> void:
	var ci := _nearest_cat(_lat_target)
	var key: String = CAT_KEYS[ci]
	var idx := _item_at_lon(ci)
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
	block_chosen.emit(int(items[idx]["type"]))
