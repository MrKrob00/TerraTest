extends Node
# ИСПЫТАТЕЛЬНЫЙ ПОЛИГОН — тот же мир (node_3d.tscn), но с ровной землёй, пустым небом и панелью
# управления. Отдельной сцены у него нет намеренно: мир — это ещё камера, HUD, машина игрока и
# два десятка узлов, и копия всего этого ради одной галочки начала бы отставать от оригинала с
# первой же правки. Разница держится флагом G.proving_ground.
#
# НИЧЕГО СВОЕГО ЭТОТ УЗЕЛ НЕ ВЫКЛЮЧАЕТ. Поток врагов, ИИ, налёты, точки, обучение,
# неуязвимость и бесконечная энергия уже имеют по одной двери — отладочные флаги на Main,
# которые читают через `G.debug` (см. CLAUDE.md, правила 9 и 10). Панель дёргает ровно их.
# Вторая реализация «выключить ИИ» означала бы, что однажды ИИ выключится в одном месте и
# останется включённым в другом.
#
# Склад, земля, квесты и сейв — не флаги, а режим: они спрашивают G.proving_ground напрямую
# (G.block_available / chunk_terrain.flat_ground / quest_arcs._ready / world_persist).

## Таблица сборок лежит на скрипте узла машины, а class_name у него нет — берём константу прямо
## со скрипта. Свой список здесь означал бы, что новая строка в таблице на полигон не попадёт.
const BLOCKS_SCRIPT := preload("res://blocks.gd")

const PANEL_W := 300.0
const PANEL_MARGIN := 12.0
## СВЕРХУ ПАНЕЛЬ НЕ СТАВИМ: там кнопка режима сборки, и панель легла ровно на неё. Отступ — её
## высота с запасом.
const PANEL_TOP := 104.0
## Куда ставить заспавненную машину относительно игрока: вперёд по взгляду камеры.
const SPAWN_DIST := 28.0
## Радиус «убрать ближайшего»: если рядом никого, лучше ничего не трогать, чем удалить машину
## на другом конце полигона.
const PICK_DIST := 200.0

var _main: Node = null
var _spawner: Node = null
var _layer: CanvasLayer = null
var _build_label: Label = null
var _status: Label = null
var _body: VBoxContainer = null
var _presets: Array[int] = []
var _pick: int = 0
var _ally: bool = false

## ФЛАГИ ПОДНИМАЮТСЯ В _enter_tree, А НЕ В _ready, И ЭТО НЕ ПРИДИРКА. Годот обходит дерево
## дважды: сначала _enter_tree сверху вниз на всю ветку, потом _ready снизу вверх. Этот узел —
## последний ребёнок мира, значит в _ready он опаздывает: tutorial_director к тому моменту уже
## спросил `G.debug("tutorial")`, получил ответ по умолчанию и завёл обучение, а спавнер успел
## поставить первый отсчёт. Измерено — на полигоне шло обучение со своим трекером и кнопкой
## «пропустить». В _enter_tree флаги стоят раньше любого _ready в сцене.
func _enter_tree() -> void:
	if not G.proving_ground:
		return
	_main = get_parent()                    # это и есть Main; путь строкой был бы лишним допущением
	_quiet_world()

func _ready() -> void:
	# В обычной игре узла просто нет. Не «спрятан», не «спит»: его нет в дереве, и он не стоит
	# ни кадра, ни проверки.
	if not G.proving_ground:
		queue_free()
		return
	_spawner = get_tree().get_first_node_in_group("enemy_spawner")
	if _spawner == null:
		_spawner = get_node_or_null("/root/Main/EnemySpawner")
	# ОБУЧЕНИЕ ЗАКРЫВАЕМ ТОЙ ЖЕ ДВЕРЬЮ, ЧТО И ОТЛАДОЧНЫЙ ФЛАГ (tutorial_director): не «спрятать
	# шаги», а пройти их. Остальная игра спрашивает Q.tutorial_active(), и спрятанное обучение
	# оставило бы мир ждать сигнала, которого не будет.
	if Q.tutorial_active():
		Q.skip_tutorial()
	_collect_presets()
	_build_ui()

## Список сборок берём ИЗ ТЕХ ЖЕ ТАБЛИЦ, по которым мир их и строит: ступени спавнера по порядку,
## потом всё остальное, что есть в blocks.ENEMY_BUILDS (шахтёры и любая будущая строка). Свой
## список номеров здесь отстал бы от таблицы на первой же добавленной машине.
func _collect_presets() -> void:
	var seen := {}
	if _spawner != null:
		for step in _spawner.PRESET_TIERS:
			for p in step:
				if not seen.has(p):
					seen[int(p)] = true
					_presets.append(int(p))
	for p in BLOCKS_SCRIPT.ENEMY_BUILDS.keys():
		if not seen.has(p):
			seen[int(p)] = true
			_presets.append(int(p))
	if _presets.is_empty():
		_presets.append(5)

## Мир замолкает: поток врагов, налёты, точки, сканы сектора и обучение. Всё — через штатные
## отладочные флаги, мастер-выключатель на время полигона поднят.
func _quiet_world() -> void:
	if _main == null:
		return
	_main.set("debug_overrides", true)
	_main.set("enemy_spawn", false)
	_main.set("raids", false)
	_main.set("outposts", false)
	_main.set("sector_scan", false)
	_main.set("tutorial", false)
	_main.set("enemy_ai", true)

func _flag(name: StringName) -> bool:
	return _main != null and _main.get(name) == true

func _set_flag(name: StringName, on: bool) -> void:
	if _main != null:
		_main.set(name, on)

# ── Панель ───────────────────────────────────────────────────────────────────
# Строится кодом целиком: она существует только на полигоне, и узлы в общей сцене мира,
# которых в игре не бывает, — это узлы, о которых однажды забудут.
func _build_ui() -> void:
	_layer = CanvasLayer.new()
	_layer.layer = 40                       # выше HUD, ниже окон гаража
	add_child(_layer)
	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_TOP_LEFT)
	panel.position = Vector2(PANEL_MARGIN, PANEL_TOP)
	panel.custom_minimum_size = Vector2(PANEL_W, 0)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.04, 0.06, 0.08, 0.82)
	sb.border_color = Color(0.25, 0.85, 0.55, 0.65)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(6)
	sb.set_content_margin_all(8)
	panel.add_theme_stylebox_override("panel", sb)
	_layer.add_child(panel)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 5)
	panel.add_child(box)

	# ПАНЕЛЬ СКЛАДЫВАЕТСЯ. Экран телефона занят под завязку, а полигон нужен не каждую секунду:
	# сложенная, она оставляет одну строку заголовка и не спорит ни с чем.
	var head := Button.new()
	head.flat = true
	head.text = tr("PROVING GROUND")
	head.add_theme_color_override("font_color", Color(0.4, 1.0, 0.65))
	head.pressed.connect(_on_fold)
	box.add_child(head)

	_body = VBoxContainer.new()
	_body.add_theme_constant_override("separation", 5)
	box.add_child(_body)
	box = _body                             # дальше всё складывается внутрь тела панели

	_build_label = Label.new()
	_build_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_build_label)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	box.add_child(row)
	row.add_child(_btn("<", _on_prev, 40.0))
	row.add_child(_btn(">", _on_next, 40.0))
	var spawn_btn := _btn(tr("Spawn"), _on_spawn, 0.0)
	spawn_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(spawn_btn)

	box.add_child(_toggle(tr("Enemy AI"), _flag(&"enemy_ai"), _on_ai))
	box.add_child(_toggle(tr("Spawn as ally"), false, _on_ally))
	box.add_child(_toggle(tr("Player invulnerable"), _flag(&"player_invulnerable"), _on_invuln))
	box.add_child(_toggle(tr("Infinite energy"), _flag(&"infinite_energy"), _on_energy))

	var row2 := HBoxContainer.new()
	row2.add_theme_constant_override("separation", 4)
	box.add_child(row2)
	var b1 := _btn(tr("Remove nearest"), _on_remove_near, 0.0)
	b1.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row2.add_child(b1)
	var b2 := _btn(tr("Clear all"), _on_clear, 0.0)
	b2.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row2.add_child(b2)

	var row3 := HBoxContainer.new()
	row3.add_theme_constant_override("separation", 4)
	box.add_child(row3)
	var b3 := _btn(tr("Repair machine"), _on_repair, 0.0)
	b3.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row3.add_child(b3)
	var b4 := _btn(tr("Sweep debris"), _on_sweep, 0.0)
	b4.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row3.add_child(b4)

	_status = Label.new()
	_status.add_theme_font_size_override("font_size", 12)
	_status.add_theme_color_override("font_color", Color(0.65, 0.75, 0.8))
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_status)
	_refresh_build()
	_say(tr("No saves here, no quests, no stream of enemies. Blocks are unlimited."))

func _on_fold() -> void:
	if _body != null:
		_body.visible = not _body.visible

func _btn(text: String, cb: Callable, min_w: float) -> Button:
	var b := Button.new()
	b.text = text
	if min_w > 0.0:
		b.custom_minimum_size = Vector2(min_w, 0)
	b.pressed.connect(cb)
	return b

func _toggle(text: String, on: bool, cb: Callable) -> CheckBox:
	var c := CheckBox.new()
	c.text = text
	c.button_pressed = on
	c.toggled.connect(cb)
	return c

func _say(text: String) -> void:
	if _status != null:
		_status.text = text

# ── Выбор сборки ─────────────────────────────────────────────────────────────
func _on_prev() -> void:
	_pick = (_pick - 1 + _presets.size()) % _presets.size()
	_refresh_build()

func _on_next() -> void:
	_pick = (_pick + 1) % _presets.size()
	_refresh_build()

func _refresh_build() -> void:
	if _build_label == null:
		return
	var p: int = _presets[_pick]
	_build_label.text = "%d/%d   %s" % [_pick + 1, _presets.size(), _build_title(p)]

## Подпись сборки СЧИТАЕТСЯ ИЗ ЕЁ СТРОКИ, а не написана рядом: семьдесят шесть подписей руками
## — это семьдесят шесть мест, где однажды будет написано не то, что стоит в таблице.
func _build_title(preset: int) -> String:
	var b: Dictionary = BLOCKS_SCRIPT.ENEMY_BUILDS.get(preset, {})
	if b.is_empty():
		return "#%d" % preset
	var step := -1
	if _spawner != null:
		for i in _spawner.PRESET_TIERS.size():
			if (_spawner.PRESET_TIERS[i] as Array).has(preset):
				step = i
				break
	var guns: Array[String] = []
	for key in ["deck", "top", "crown", "wings", "front"]:
		for v in _as_list(b.get(key)):
			var n: String = G.block_name(int(v))
			if _is_weapon(int(v)) and not guns.has(n):
				guns.append(n)
	var tail: String = ", ".join(guns) if not guns.is_empty() else tr("no weapons")
	var head: String = (tr("step %d") % (step + 1)) if step >= 0 else tr("off-ladder")
	return "#%d · %s · %s" % [preset, head, tail]

func _as_list(v: Variant) -> Array:
	if v is Array:
		return v as Array
	return [] if v == null else [v]

## Оружие или нет — спрашиваем У СПИСКА МАГАЗИНА, а не у своего перечня номеров: категории
## уже есть (G.BLOCK_CATEGORIES), по ним фильтрует и магазин, и справочник, и вторая копия
## разошлась бы с ними на первой же новой пушке.
func _is_weapon(bt: int) -> bool:
	var atk = G.BLOCK_CATEGORIES.get("attack", [])
	return atk is Array and (atk as Array).has(bt)

# ── Действия ─────────────────────────────────────────────────────────────────
func _on_spawn() -> void:
	if _spawner == null or not _spawner.has_method("spawn_at"):
		_say(tr("No spawner in the scene."))
		return
	var at: Vector3 = _spawn_point()
	var preset: int = _presets[_pick]
	# faction 0 — своя, всё остальное враждебно. Союзник нужен, чтобы смотреть бой со стороны,
	# а не только на себе.
	var e = _spawner.call("spawn_at", at, preset, 0 if _ally else 1, false)
	if e == null:
		_say(tr("Spawn refused."))
		return
	_say(tr("Spawned %s") % _build_title(preset))

## Перед камерой, на расстоянии SPAWN_DIST. Не «вокруг игрока по кольцу», как в игре: на полигоне
## машину ставят, чтобы на неё смотреть.
func _spawn_point() -> Vector3:
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return Vector3.ZERO
	var fwd: Vector3 = -cam.global_transform.basis.z
	fwd.y = 0.0
	if fwd.length_squared() < 0.0001:
		fwd = Vector3.FORWARD
	var p: Vector3 = cam.global_position + fwd.normalized() * SPAWN_DIST
	return Vector3(p.x, G.ground_y(p, p.y), p.z)

func _on_ai(on: bool) -> void:
	_set_flag(&"enemy_ai", on)
	_say(tr("Enemy AI: %s") % (tr("on") if on else tr("off")))

func _on_ally(on: bool) -> void:
	_ally = on

func _on_invuln(on: bool) -> void:
	_set_flag(&"player_invulnerable", on)

func _on_energy(on: bool) -> void:
	_set_flag(&"infinite_energy", on)

## Ближайшая ЧУЖАЯ машина: свою (faction 0) не трогаем, иначе кнопка «убрать» однажды удалит
## игрока вместе с кабиной.
func _on_remove_near() -> void:
	var from = G.build_origin()
	if not (from is Vector3):
		_say(tr("No machine to measure from."))
		return
	var best: Node3D = null
	var best_d := PICK_DIST * PICK_DIST
	for m in _foreign_machines():
		var d: float = (m as Node3D).global_position.distance_squared_to(from as Vector3)
		if d < best_d:
			best_d = d
			best = m
	if best == null:
		_say(tr("Nothing within reach."))
		return
	best.queue_free()
	_say(tr("Removed one machine."))

func _on_clear() -> void:
	var n := 0
	for m in _foreign_machines():
		m.queue_free()
		n += 1
	_say(tr("Removed machines: %d") % n)

func _foreign_machines() -> Array:
	var out: Array = []
	var vr: Node = get_node_or_null("/root/Main/Vehicles")
	if vr == null:
		return out
	for c in vr.get_children():
		if c is Node3D and "faction" in c and int(c.get("faction")) != 0:
			out.append(c)
	return out

## Чинит машину, которой управляет игрок, — целиком и сразу. На полигоне смотрят, КАК сборка
## держит огонь, а не как она чинится: перебирать блоки руками между заходами незачем.
func _on_repair() -> void:
	var cc: Node = get_tree().get_first_node_in_group("camera_controller")
	var v = cc.get("current_vehicle") if cc != null else null
	if v == null or not is_instance_valid(v):
		_say(tr("No machine under control."))
		return
	var blocks = v.get("block_map_node")
	if blocks == null:
		_say(tr("No machine under control."))
		return
	var n := 0
	for b in (blocks as Node).get_children():
		if ("current_hp" in b) and ("max_hp" in b) and b.current_hp < b.max_hp:
			b.current_hp = b.max_hp
			if b.has_method("_refresh_hp_fx"):
				b._refresh_hp_fx()
			n += 1
	_say(tr("Repaired blocks: %d") % n)

## Обломки и брошенное добро. На полигоне их набирается больше, чем в игре: машины тут не
## доезжают до смерти естественным путём, их убирают кнопкой, и всё, что с них осыпалось,
## остаётся лежать физическим телом и просить у земли плитку под собой.
func _on_sweep() -> void:
	var o: Node = get_node_or_null("/root/Main/objects")
	if o == null:
		_say(tr("Nothing to sweep."))
		return
	var n := 0
	for c in o.get_children():
		c.queue_free()
		n += 1
	_say(tr("Swept items: %d") % n)
