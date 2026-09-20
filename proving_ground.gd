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
## Имя окна в настройках: место, куда игрок её оттащил, переживает перезаход.
const PANEL_ID := "proving_panel"
## Куда ставить заспавненную машину относительно игрока: вперёд по взгляду камеры.
const SPAWN_DIST := 28.0
## Радиус «убрать ближайшего»: если рядом никого, лучше ничего не трогать, чем удалить машину
## на другом конце полигона.
const PICK_DIST := 200.0

var _main: Node = null
var _spawner: Node = null
var _layer: CanvasLayer = null
var _pick_btn: Button = null            # кнопка на панели: что выбрано + вход в окно
var _picker: PanelContainer = null      # само окно выбора
var _picker_steps: VBoxContainer = null
var _picker_grid: GridContainer = null
var _picker_title: Label = null
var _picker_gi: int = 0                 # какая ступень ОТКРЫТА в окне (выбор подтверждается тапом)
var _status: Label = null
var _body: VBoxContainer = null
var _panel: PanelContainer = null
var _head: Button = null
var _drag: DragWindow = null
var _groups: Array = []                 # [{title, list}] — ступени лестницы плюс «вне лестницы»
var _gi: int = 0                        # какая ступень выбрана
var _vi: int = 0                        # какой вариант внутри неё
var _last_spawn: Node3D = null          # чей состав показывает подменю «Состав»
var _parts: VBoxContainer = null
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
	_sandbox_progress()
	_stock_all_blocks()
	_build_ui()

## ПРОГРЕСС НА ПОЛИГОНЕ — СВОЙ, И ЭТО НЕ КОСМЕТИКА.
##
## Слот полигон берёт чужой — последний игранный, иначе автолоадам неоткуда взять путь в
## `user://`, — и вместе с ним в память приезжают НАСТОЯЩИЕ деньги, грейд и список изученного.
## Игрок видит на площадке свой счёт и свой грейд и делает единственный разумный вывод: сюда
## записался его сейв. Записаться он не может (G._flush_progress), но выглядит это именно так,
## а интерфейс, который выглядит как потеря данных, ничем не лучше потери данных.
##
## Поэтому в памяти ставим заведомо ПОЛИГОННЫЕ числа: круглая сумма, верхний грейд и всё
## изученное. Заодно это снимает половину гейтов, ради которых полигон и нужен, — магазин,
## древо и грейдовые замки открыты. На диск ничего из этого не уходит, а из памяти оно исчезает
## на выходе (G.leave_proving_ground перечитывает файл слота).
const PG_MONEY := 999_999

func _sandbox_progress() -> void:
	G.money = PG_MONEY
	# Верхний грейд: берём порог последней ступени из той же таблицы, по которой грейд и считают.
	var th: Array = G.FACTIONS["start"]["xp_thresholds"]
	G.faction_xp = {"start": int(th[th.size() - 1])}
	G.research_points = PG_MONEY
	var all: Array = []
	for bt in G.Block.values():
		if bt != G.Block.EMPTY and not G.RETIRED_BLOCKS.has(bt):
			all.append(bt)
	G.researched = all
	# СИГНАЛ ОБЯЗАТЕЛЕН: счётчик в HUD обновляется не опросом, а по `money_changed` (продавец
	# начисляет пассивно). Записав поле напрямую и промолчав, мы оставили бы на экране сумму из
	# слота — ровно ту, из-за которой полигон и выглядел как чужой сейв.
	G.money_changed.emit()

## ВЫДАЁМ ВСЕ БЛОКИ НА РУКИ, а не только делаем склад бесконечным. Бесконечность отвечает на
## вопрос «хватит ли», а глобус выбора спрашивает другое: он перебирает САМ СПИСОК
## (`G.block_inventory`), и с пустым списком показывать ему нечего — на полигоне не из чего было
## строить, сколько бы ни обещал block_available.
##
## Количество любое: списание на полигоне ничего не вычитает (G.consume_block), так что стопка
## не убывает. Десяти хватает, чтобы стопка выглядела стопкой.
const PG_EACH := 10

func _stock_all_blocks() -> void:
	var inv: Array = []
	for bt in G.Block.values():
		# Пустая клетка — не блок; снятые блоки (RETIRED_BLOCKS) существуют только ради старых
		# сейвов; блок без сцены поставить нельзя, и в списке он был бы ловушкой.
		if bt == G.Block.EMPTY or G.RETIRED_BLOCKS.has(bt) or G.get_scene(bt) == null:
			continue
		for _i in PG_EACH:
			inv.append(bt)
	G.block_inventory = inv
	_stocked = inv.size()

var _stocked: int = 0

## Сборки берём ИЗ ТЕХ ЖЕ ТАБЛИЦ, по которым мир их и строит, и СОХРАНЯЕМ ИХ СТУПЕНИ. Плоский
## список из семидесяти шести номеров отвечал на «какая по счёту», а спрашивают у него другое —
## «насколько сильная»: ступень и есть та самая крутизна, ради которой в панель лезут. Своё
## деление здесь разъехалось бы с лестницей спавнера при первой же правке таблицы.
##
## Последней группой идёт всё, чего в лестнице нет: шахтёры и любая будущая строка. Прятать их
## нельзя — на полигоне смотрят в том числе и то, что в обычной игре по цене не выпадает.
func _collect_presets() -> void:
	_groups.clear()
	var seen := {}
	if _spawner != null:
		var tiers: Array = _spawner.PRESET_TIERS
		for i in tiers.size():
			var list: Array[int] = []
			for p in (tiers[i] as Array):
				seen[int(p)] = true
				list.append(int(p))
			if not list.is_empty():
				_groups.append({"title": tr("step %d") % (i + 1), "list": list})
	var rest: Array[int] = []
	for p in BLOCKS_SCRIPT.ENEMY_BUILDS.keys():
		if not seen.has(int(p)):
			rest.append(int(p))
	rest.sort()
	if not rest.is_empty():
		_groups.append({"title": tr("off-ladder"), "list": rest})
	if _groups.is_empty():
		_groups.append({"title": tr("off-ladder"), "list": [5] as Array[int]})
	_gi = 0
	_vi = 0

func _cur_list() -> Array:
	return (_groups[_gi] as Dictionary)["list"]

func _cur_preset() -> int:
	var l: Array = _cur_list()
	return int(l[clampi(_vi, 0, l.size() - 1)])

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
	add_to_group("hud_float")               # HUD убирает нас на время гаража
	var panel := PanelContainer.new()
	_panel = panel
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
	_head = head
	# ТАСКАЕТСЯ ЗА ШАПКУ И ПОМНИТ МЕСТО — тем же механизмом, что трекер заданий и журнал
	# (DragWindow). Панель разработчика мешает ровно так же, как любая другая, и убирать её
	# игрок должен тем же движением, которым убирает остальные.
	_drag = DragWindow.attach(panel, head, PANEL_ID)

	_body = VBoxContainer.new()
	_body.add_theme_constant_override("separation", 5)
	box.add_child(_body)
	box = _body                             # дальше всё складывается внутрь тела панели

	# ВЫБОР ВРАГА — ОТДЕЛЬНОЕ ОКНО, а не стрелки в углу панели. Стрелками нельзя ни сравнить
	# соседние сборки, ни увидеть, сколько их вообще: чтобы понять, что стоит на ступени, надо
	# было прощёлкать её целиком и запомнить. В окне ступени лежат колонкой, сборки — карточками,
	# и выбор виден целиком.
	_pick_btn = _btn("", _on_open_picker, 0.0)
	_pick_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_pick_btn.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_pick_btn)
	var spawn_btn := _btn(tr("Spawn"), _on_spawn, 0.0)
	spawn_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_child(spawn_btn)

	# СОСТАВ — ПОДМЕНЮ, а не строка в панели: список блоков это десяток строк, и висеть им
	# всё время незачем.
	var parts_btn := _btn(tr("Parts list"), _on_parts, 0.0)
	parts_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_child(parts_btn)
	_parts = VBoxContainer.new()
	_parts.add_theme_constant_override("separation", 1)
	_parts.visible = false
	box.add_child(_parts)

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

## Свернуть/развернуть. Свёрнутая панель — это одна строка заголовка, которую можно оттащить в
## любой угол: на телефоне свободного места нет нигде, и «сделать поменьше» тут значит «убрать».
func _on_fold() -> void:
	# Шапка — кнопка, и Button шлёт pressed по отпусканию даже после того, как её утащили через
	# полэкрана. Переезд нажатием не считаем (та же грабля, что у трекера заданий).
	if _drag != null and _drag.dragged():
		return
	if _body == null or _panel == null:
		return
	var open: bool = not _body.visible
	_body.visible = open
	_head.text = tr("PROVING GROUND") if open else tr("PG")
	# Ширину держим только у развёрнутой: свёрнутая должна быть ярлыком, а не пустой полосой в
	# треть экрана.
	_panel.custom_minimum_size.x = PANEL_W if open else 0.0
	_panel.reset_size()
	# Развернулась у нижней кромки — прижимаем обратно, иначе половина кнопок за экраном.
	_clamp_later.call_deferred()

func _clamp_later() -> void:
	if _drag != null and _panel != null:
		_panel.position = _drag.clamp_on_screen(_panel, _panel.position)

## HUD зовёт при открытии гаража — через ту же группу, что и трекер заданий. Гараж
## полноэкранный, и панель поверх него не управляет ничем, что видно.
func set_inventory_open(open: bool) -> void:
	if _layer != null:
		_layer.visible = not open

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

# ── Выбор сборки: сначала СТУПЕНЬ, потом вариант внутри неё ───────────────────
# Два ряда, а не один длинный список: ступень — это сила машины, вариант — её силуэт, и
# смешивать их в одном счётчике значит листать семьдесят шесть позиций, чтобы поднять уровень.
func _refresh_build() -> void:
	if _pick_btn == null:
		return
	_pick_btn.text = "%s\n%s" % [String((_groups[_gi] as Dictionary)["title"]),
			_build_title(_cur_preset())]

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
	var guns: String = _build_guns(preset)
	var tail: String = guns if guns != "" else tr("no weapons")
	var head: String = (tr("step %d") % (step + 1)) if step >= 0 else tr("off-ladder")
	return "#%d · %s · %s" % [preset, head, tail]

## ЧТО В СБОРКЕ — СЧИТАЕТСЯ ПО НАСТОЯЩЕЙ РАСКЛАДКЕ, а не по строке таблицы.
##
## Строка отвечает только на часть вопроса: `wings` это ОДИН тип на ДВА плеча, плиты брони и
## пол вообще не перечислены — их раскладывает `_layout_enemy` из числа рядов и ширины. Считать
## всё это здесь заново значило бы завести второе воплощение раскладки, и разойтись они обязаны
## при первой же правке.
##
## Поэтому сборка собирается ПО-НАСТОЯЩЕМУ, но БЕЗ МИРА: узел `blocks.gd` вне дерева, ему
## хватает `_init_map` + `_define_layout`. `set_block` пишет только сетку — ни одной сцены блока
## при этом не создаётся, так что двенадцать карточек ступени стоят двенадцать словарей.
## Сверено с живой машиной: у сборки #25 обе дороги дают 29 блоков.
##
## Считаем ЯКОРЯ, а не клетки: многоклеточный блок занимает несколько и посчитался бы дважды.
var _sum_cache: Dictionary = {}

func _summary(preset: int) -> Dictionary:
	if _sum_cache.has(preset):
		return _sum_cache[preset]
	var n := Node3D.new()
	n.set_script(BLOCKS_SCRIPT)
	n.set("layout_preset", preset)
	n.call("_init_map")
	n.call("_define_layout")
	var count := {}
	var total := 0
	var m: Array = n.get("map")
	var owners: Dictionary = n.get("cell_owner")
	var seen := {}
	for x in m.size():
		for y in (m[x] as Array).size():
			for z in ((m[x] as Array)[y] as Array).size():
				var bt: int = int(((m[x] as Array)[y] as Array)[z])
				if bt == G.Block.EMPTY:
					continue
				var key: String = String(owners.get("%d,%d,%d" % [x, y, z], "%d,%d,%d" % [x, y, z]))
				if seen.has(key):
					continue
				seen[key] = true
				count[bt] = int(count.get(bt, 0)) + 1
				total += 1
	n.free()
	var out := {"total": total, "count": count}
	_sum_cache[preset] = out
	return out

## Список «имя ×N» по заданным типам, "" если ни одного. Порядок — по УБЫВАНИЮ количества, чтобы
## главное оружие сборки стояло первым.
func _sum_line(preset: int, types: Array) -> String:
	var count: Dictionary = (_summary(preset) as Dictionary)["count"]
	var rows: Array = []
	for bt in types:
		var k: int = int(bt)
		if count.has(k):
			rows.append({"n": G.block_name(k), "c": int(count[k])})
	rows.sort_custom(func(a, b): return a["c"] > b["c"] if a["c"] != b["c"] else a["n"] < b["n"])
	var parts: Array[String] = []
	for r in rows:
		parts.append("%s x%d" % [String(r["n"]), int(r["c"])])
	return ", ".join(parts)

## ЭНЕРГЕТИКА СБОРКИ — аккумуляторы, купол, поле ремонта. Три номера перечислены здесь, а не
## взяты категорией: категории магазина делят блоки по прилавку («атака», «блоки», «фабрика»),
## а вопрос тут другой — «чем эта машина держится под огнём».
const POWER_BLOCKS := [G.Block.BATTERY, G.Block.SHIELD, G.Block.REGEN]

func _build_guns(preset: int) -> String:
	return _sum_line(preset, G.BLOCK_CATEGORIES.get("attack", []))

func _build_power(preset: int) -> String:
	return _sum_line(preset, POWER_BLOCKS)

# ── Действия ─────────────────────────────────────────────────────────────────
func _on_spawn() -> void:
	if _spawner == null or not _spawner.has_method("spawn_at"):
		_say(tr("No spawner in the scene."))
		return
	var at: Vector3 = _spawn_point()
	var preset: int = _cur_preset()
	# faction 0 — своя, всё остальное враждебно. Союзник нужен, чтобы смотреть бой со стороны,
	# а не только на себе.
	# spawn_requested, а не spawn_at: на полигоне спавнер отказывает всем, кроме этой двери —
	# иначе сюжетный разведчик и ветки квестов ставили бы машины, которых никто не звал.
	var e = _spawner.call("spawn_requested", at, preset, 0 if _ally else 1, false)
	if e == null:
		_say(tr("Spawn refused."))
		return
	_last_spawn = e as Node3D
	_say(tr("Spawned %s") % _build_title(preset))
	if _parts != null and _parts.visible:
		_refresh_parts()                     # подменю открыто — показываем состав нового

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

# ── Окно выбора врага ────────────────────────────────────────────────────────
# Слева ступени колонкой, справа карточки сборок этой ступени. Выбор — тап по карточке; окно
# закрывается сразу, потому что выбрали ровно то, что хотели, и второго подтверждения это не
# требует. Заспавнить можно и отсюда — кнопкой внизу, не закрывая окна: на полигоне чаще
# ставят подряд несколько машин одной ступени, чем одну.
const PICK_W_MAX := 560.0
const PICK_H_FRAC := 0.74
const PICK_COLS := 2
const PICK_ID := "proving_picker"

func _on_open_picker() -> void:
	if _picker == null:
		_build_picker()
	_picker_gi = _gi
	_fill_picker()
	_picker.visible = true
	_fit_picker()

func _build_picker() -> void:
	_picker = PanelContainer.new()
	_picker.set_anchors_preset(Control.PRESET_TOP_LEFT)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.04, 0.07, 0.09, 0.97)
	sb.border_color = Color(0.3, 0.85, 0.6, 0.7)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(7)
	sb.set_content_margin_all(9)
	_picker.add_theme_stylebox_override("panel", sb)
	_picker.visible = false
	_layer.add_child(_picker)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 6)
	_picker.add_child(col)

	var head := HBoxContainer.new()
	col.add_child(head)
	_picker_title = Label.new()
	_picker_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_picker_title.add_theme_font_size_override("font_size", 15)
	_picker_title.add_theme_color_override("font_color", Color(0.45, 1.0, 0.7))
	head.add_child(_picker_title)
	var close := _btn("X", _on_close_picker, 30.0)
	head.add_child(close)
	# Окно тоже таскается за шапку и помнит место — тем же DragWindow, что и всё остальное.
	DragWindow.attach(_picker, _picker_title, PICK_ID)

	var mid := HBoxContainer.new()
	mid.size_flags_vertical = Control.SIZE_EXPAND_FILL
	mid.add_theme_constant_override("separation", 8)
	col.add_child(mid)

	# СТУПЕНИ КОЛОНКОЙ. Их семь, они короткие и не меняются — список, а не выпадашка: выпадашка
	# на телефоне это лишний тап и закрытый экран ради того, что и так помещается.
	var steps_scroll := ScrollContainer.new()
	steps_scroll.custom_minimum_size = Vector2(118, 0)
	steps_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	mid.add_child(steps_scroll)
	_picker_steps = VBoxContainer.new()
	_picker_steps.add_theme_constant_override("separation", 3)
	_picker_steps.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	steps_scroll.add_child(_picker_steps)

	var grid_scroll := ScrollContainer.new()
	grid_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	mid.add_child(grid_scroll)
	_picker_grid = GridContainer.new()
	_picker_grid.columns = PICK_COLS
	_picker_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_picker_grid.add_theme_constant_override("h_separation", 5)
	_picker_grid.add_theme_constant_override("v_separation", 5)
	grid_scroll.add_child(_picker_grid)

	var foot := HBoxContainer.new()
	foot.add_theme_constant_override("separation", 5)
	col.add_child(foot)
	var sp := _btn(tr("Spawn"), _on_spawn, 0.0)
	sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	foot.add_child(sp)
	var done := _btn(tr("Done"), _on_close_picker, 0.0)
	done.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	foot.add_child(done)

func _on_close_picker() -> void:
	if _picker != null:
		_picker.visible = false

## Размер от ЭКРАНА, а не константой: на телефоне и на планшете это разные окна, а вылезшее за
## край всё равно пришлось бы прижимать (DragWindow.clamp_on_screen).
func _fit_picker() -> void:
	var vp: Vector2 = get_viewport().get_visible_rect().size
	_picker.custom_minimum_size = Vector2(minf(PICK_W_MAX, vp.x * 0.94), vp.y * PICK_H_FRAC)
	_picker.reset_size()
	_picker.position = ((vp - _picker.size) * 0.5).max(Vector2(8.0, 8.0))

func _fill_picker() -> void:
	_picker_title.text = tr("Pick an enemy")
	for c in _picker_steps.get_children():
		_picker_steps.remove_child(c)
		c.queue_free()
	for i in _groups.size():
		var g: Dictionary = _groups[i]
		var b := Button.new()
		b.text = "%s\n(%d)" % [String(g["title"]), (g["list"] as Array).size()]
		b.toggle_mode = true
		b.button_pressed = (i == _picker_gi)
		b.add_theme_font_size_override("font_size", 12)
		b.pressed.connect(_on_pick_step.bind(i))
		_picker_steps.add_child(b)
	for c in _picker_grid.get_children():
		_picker_grid.remove_child(c)
		c.queue_free()
	var list: Array = (_groups[_picker_gi] as Dictionary)["list"]
	for vi in list.size():
		_picker_grid.add_child(_pick_card(int(list[vi]), vi))

func _on_pick_step(i: int) -> void:
	_picker_gi = i
	_fill_picker()

## КАРТОЧКА ОТВЕЧАЕТ НА «ЧТО ЭТО», а не только «какая по счёту». Всё в ней считается из строки
## таблицы (`ENEMY_BUILDS`): номер, оружие, этажи и ширина. Подписи руками — это семьдесят шесть
## мест, где однажды будет написано не то, что стоит в таблице.
func _pick_card(preset: int, vi: int) -> Control:
	var b := Button.new()
	b.toggle_mode = true
	b.button_pressed = (_picker_gi == _gi and vi == _vi)
	b.custom_minimum_size = Vector2(0, 68)
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	b.add_theme_font_size_override("font_size", 11)
	var guns: String = _build_guns(preset)
	var power: String = _build_power(preset)
	b.text = "#%d  %s\n%s\n%s" % [preset,
			tr("%d blocks") % int((_summary(preset) as Dictionary)["total"]),
			guns if guns != "" else tr("no weapons"),
			power if power != "" else tr("no power")]
	b.pressed.connect(_on_pick_build.bind(vi))
	return b

func _on_pick_build(vi: int) -> void:
	_gi = _picker_gi
	_vi = vi
	_refresh_build()
	_fill_picker()                          # подсветка выбранной карточки

## СОСТАВ ПОСЛЕДНЕЙ ЗАСПАВНЕННОЙ МАШИНЫ — по её настоящим блокам, а не по строке таблицы.
##
## Пересчитать состав из `ENEMY_BUILDS` было бы вторым воплощением `blocks._layout_enemy`: там
## и ряды, и ширина, и плиты брони, и крылья, и носовая клетка, — и разойтись эти две версии
## обязаны на первой же правке раскладки. Спрашиваем то, что действительно стоит в мире.
func _on_parts() -> void:
	if _parts == null:
		return
	_parts.visible = not _parts.visible
	if _parts.visible:
		_refresh_parts()
	_clamp_later.call_deferred()

func _refresh_parts() -> void:
	for c in _parts.get_children():
		_parts.remove_child(c)
		c.queue_free()
	if not is_instance_valid(_last_spawn):
		_parts.add_child(_part_row(tr("Spawn a machine to see its parts."), ""))
		return
	var host: Node = _last_spawn.get("block_map_node") as Node
	if host == null:
		host = _last_spawn.get_node_or_null("blocks")
	if host == null or not host.has_method("get_layout"):
		_parts.add_child(_part_row(tr("Spawn a machine to see its parts."), ""))
		return
	# ПЕРЕБИРАЕМ ТЕМ ЖЕ `get_layout`, ЧТО И СОХРАНЕНИЕ. Тип блока живёт в сетке, а не на узле, и
	# свой обход `node_map` пришлось бы писать вместе с разбором якорей и футпринтов — ровно то,
	# что эта функция уже делает и делает правильно (одна запись на многоклеточный блок).
	# Имя — через G.block_name, ту же дверь, что и у магазина: свой перевод здесь означал бы
	# переведённый магазин и непереведённый полигон рядом.
	var count := {}
	var total := 0
	for e in host.call("get_layout"):
		var bt: int = G.block_from_key((e as Dictionary).get("block", ""))
		if bt == G.Block.EMPTY:
			continue
		var n: String = G.block_name(bt)
		count[n] = int(count.get(n, 0)) + 1
		total += 1
	var names: Array = count.keys()
	names.sort()
	_parts.add_child(_part_row(tr("Parts: %d") % total, ""))
	for n in names:
		_parts.add_child(_part_row(String(n), "x%d" % int(count[n])))

func _part_row(left: String, right: String) -> Control:
	var row := HBoxContainer.new()
	var a := Label.new()
	a.text = left
	a.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	a.add_theme_font_size_override("font_size", 12)
	a.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	a.clip_text = true
	row.add_child(a)
	if right != "":
		var b := Label.new()
		b.text = right
		b.add_theme_font_size_override("font_size", 12)
		b.add_theme_color_override("font_color", Color(0.6, 0.85, 0.7))
		row.add_child(b)
	return row

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
