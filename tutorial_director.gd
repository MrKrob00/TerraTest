class_name TutorialDirector
extends Node

# Наставник обучения: смотрит, какой шаг сейчас активен (это решает Q), и ставит палец
# (TutorialGuide) на то, что надо нажать. Шаги — обычные квесты типа TUTORIAL, поэтому
# прогресс, персист и трекер достаются даром; здесь только «куда показать и что сказать».
#
# Живёт под HUD: цели — это его же кнопки, а палец должен гаситься вместе с ним.

const GUIDE := preload("res://tutorial_guide.gd")

# Стартовая машина — ОДНА кабина, вокруг падает базовый набор (world_persist._fresh_start).
const STARTER_BLOCKS: int = 8    # столько блоков надо навесить в шаге tut_place_all
const CABIN_BLOCKS: int = 1      # что уже стоит на машине к началу обучения

var _guide: TutorialGuide = null
var _step: String = ""           # id текущего шага (пусто — обучение не идёт)
# Ключ текущего наведения: шаг + цель + текст. Именно ТЕКСТ в ключе важен — соседние шаги
# показывают на одну и ту же точку (машину), и по одной лишь цели палец не обновлялся:
# после первого поставленного блока подсказка так и висела со старым текстом.
var _aimed: String = ""
var _story_started: bool = false
var _assembly_shown: int = -1    # что уже записано в прогресс шага сборки

# Пояснения к ЗАКРЫТОМУ шагу. Каждая реплика показывает пальцем на ТУ САМУЮ часть экрана,
# о которой говорит, и только когда очередь кончится, палец уходит на следующий шаг. Раньше
# текст читался, пока палец уже стоял на следующей кнопке, — объясняли одно, показывали другое.
# t — ключ цели (см. _explain_target), s — что написать в пузыре.
const EXPLAIN := {
	"tut_quests": [
		{"t": "quest_list", "s": "Every quest lives here: tutorial first, then story, then dailies."},
		{"t": "quest_star", "s": "The star picks which quest the tracker shows. Nothing here is mandatory."},
	],
	"tut_filters": [
		{"t": "garage_grid", "s": "These are the blocks you own. The number in the corner is how many."},
		{"t": "garage_filters", "s": "These buttons filter the list by category."},
	],
	"tut_shop": [
		{"t": "garage_currency", "s": "Your money. Everything in the shop is bought with it."},
		{"t": "garage_slot", "s": "The price sits on the slot's button. Greyed out means you cannot afford it."},
		{"t": "garage_grid", "s": "A block you have not researched is not sold at all — research comes first."},
	],
	"tut_tech": [
		{"t": "garage_progress", "s": "RP means Research Points. Quests give them, so does the first kill of each enemy type."},
		{"t": "garage_tech", "s": "RP unlocks blocks here. Until a block is researched, the shop will not sell it."},
		{"t": "garage_progress", "s": "Gr is your licence grade. Faction XP raises it, and it gates whole branches."},
	],
	"tut_music": [
		{"t": "garage_extra", "s": "Tracks and volume. Nothing you have to press — just so you know it is here."},
	],
}

# Очередь пояснений текущего шага. Пока она не пуста, палец на следующий шаг НЕ переходит.
var _explain: Array = []
var _explain_t: float = 0.0
const EXPLAIN_CHARS_PER_SEC: float = 17.0    # медленнее реплик Механика: тут ещё и смотреть надо
const EXPLAIN_MIN: float = 2.6
const EXPLAIN_MAX: float = 8.0
const EXPLAIN_MAX_WAIT: int = 12         # ~3 с ожидания цели, потом реплика пропускается
var _explain_wait: int = 0

func _ready() -> void:
	_guide = GUIDE.new()
	add_child(_guide)
	_guide.bind_hud(get_parent())
	_guide.skip_pressed.connect(Q.skip_tutorial)
	Q.changed.connect(_on_quests_changed)
	Q.tutorial_finished.connect(_on_tutorial_finished)
	set_process(true)
	_on_quests_changed()

# ── Текущий шаг ──────────────────────────────────────────────────────────────
func _on_quests_changed() -> void:
	var id := _current_step_id()
	if id == _step:
		return
	# Шаг сменился. Если у закрытого шага есть пояснения — сначала проговариваем их, показывая
	# пальцем на разбираемую часть, и только потом наводимся на следующий шаг.
	var closed := _step
	_step = id
	_aimed = ""
	if closed != "" and EXPLAIN.has(closed):
		_explain = (EXPLAIN[closed] as Array).duplicate()
		_show_explain()
		return
	if _step == "":
		_guide.clear()
		_set_ui_locked(false)

func _current_step_id() -> String:
	for q in Q.quests:
		if int(q["type"]) != Q.Type.TUTORIAL or q["done"]:
			continue
		# quests хранит шаги в порядке добавления, он же order — первый невыполненный и есть
		# текущий (ту же выборку делает Q._current_tutorial).
		return str(q["id"])
	return ""

# ── Кадр: цель может появиться/переехать (гараж открылся, машина едет) ────────
func _process(delta: float) -> void:
	if not _explain.is_empty():
		_explain_tick(delta)
		return
	if _step == "":
		return
	if _step == "tut_place_all":
		_drive_assembly_progress()
	_aim_current_step()

# ── Пояснения ────────────────────────────────────────────────────────────────
func _explain_tick(delta: float) -> void:
	_explain_t -= delta
	if _explain_t > 0.0:
		return
	_explain.pop_front()
	_show_explain()

func _show_explain() -> void:
	if _explain.is_empty():
		_aimed = ""                       # очередь кончилась — палец возвращается к шагу
		if _step == "":
			_guide.clear()
			_set_ui_locked(false)
		return
	var e: Dictionary = _explain[0]
	var text := str(e["s"])
	var node: Control = _explain_target(str(e["t"]))
	if node == null or not node.is_visible_in_tree():
		# Цель ещё не построена (панель только открылась) — ждём, но не вечно: заглушка
		# висит, и застрять перед ней хуже, чем пропустить одну реплику.
		_explain_wait += 1
		if _explain_wait > EXPLAIN_MAX_WAIT:
			_explain_wait = 0
			_explain.pop_front()
			_show_explain()
			return
		_explain_t = 0.25
		return
	_explain_wait = 0
	_explain_t = clampf(float(text.length()) / EXPLAIN_CHARS_PER_SEC, EXPLAIN_MIN, EXPLAIN_MAX)
	_guide.point_at_node(node, text)

func _explain_target(key: String) -> Control:
	if key.begins_with("quest_"):
		var q: Node = get_tree().get_first_node_in_group("quests")
		if q == null or not q.has_method("tutorial_target"):
			return null
		return q.tutorial_target(key.substr(6))
	if key.begins_with("garage_"):
		return _garage_node(key.substr(7))
	return null

# Прогресс сборки СЧИТАЕМ, а не накапливаем по событию: по block_placed его крутили бы
# циклом «поставил — снял — поставил». Здесь снятый блок сразу уменьшает прогресс.
func _drive_assembly_progress() -> void:
	var v: Node = _vehicle()
	if v == null or v.get("block_map_node") == null:
		return
	var n: int = 0
	for b in v.block_map_node.get_children():
		if "block" in b:
			n += 1                       # у меша-призрака поля block нет — он не считается
	var want: int = clampi(n - CABIN_BLOCKS, 0, STARTER_BLOCKS)
	if want == _assembly_shown:
		return                           # set_progress шлёт changed БЕЗУСЛОВНО — иначе весь
	_assembly_shown = want               # список квестов пересобирался бы каждый кадр
	Q.set_progress("tut_place_all", want)

func _aim_current_step() -> void:
	match _step:
		"tut_mode_build":
			_aim_node(_hud_node("ModeToggle"), "Tap BUILD — the button says where it takes you")
		"tut_take_world":
			# Рука уже занята (блок взяли раньше, чем шаг стал текущим) — засчитываем сразу.
			# Иначе тупик: поставить нельзя (цель — блок на земле), взять нечем.
			var vt: Node = _vehicle()
			if vt != null and "block_take" in vt and vt.block_take:
				Q.report("block_taken_world", 1)
				return
			# Gate.WORLD, а не круг вокруг цели: игрок берёт не тот блок, промахивается мимо
			# круга, и любой из этих случаев запирал его насмерть. Мир открыт целиком, UI — нет.
			_aim_world(_nearest_loose_block, "Double-tap a block to take it into your hand",
					TutorialGuide.Gate.WORLD)
		"tut_place_first":
			_aim_world(_vehicle_point, "Double-tap the vehicle where the block should go",
					TutorialGuide.Gate.WORLD)
		"tut_place_all":
			# Свободный шаг: мир открыт, UI — нет. Палец не висит на машине всё время, а
			# показывает, что делать СЕЙЧАС: блок в руке — куда ставить, рука пуста — что брать.
			var v: Node = _vehicle()
			var holding: bool = v != null and "block_take" in v and v.block_take
			if holding:
				_aim_world(_vehicle_point, "Now place it on the vehicle",
						TutorialGuide.Gate.WORLD)
			else:
				_aim_world(_nearest_loose_block, "Pick up the next block",
						TutorialGuide.Gate.WORLD)
		"tut_mode_move":
			_aim_node(_hud_node("ModeToggle"), "Tap MOVE to get back behind the wheel")
		"tut_quests":
			_aim_node(_quest_tracker(), "Your quest tracker. Tap it")
		"tut_garage":
			# Гараж за два тапа: сначала иконка меню, потом Inventory внутри него.
			var hud: Node = get_parent()
			var open: bool = hud != null and hud.has_method("menu_is_open") and hud.menu_is_open()
			if open:
				_aim_node(_hud_ui("inventory"), "Inventory — that's the garage")
			else:
				_aim_node(_hud_ui("menu"), "The menu lives here now")
		"tut_filters":
			_aim_node(_garage_node("filters"), "These filter your blocks by category. Try one")
		"tut_shop":
			_aim_node(_garage_node("tab_shop"), "SHOP — this is where blocks are bought")
		"tut_tech":
			_aim_node(_garage_node("tab_tech"), "TECH — this is where blocks are unlocked")
		"tut_music":
			_aim_node(_garage_node("tab_music"), "And the music tab")

# ── Наведение ────────────────────────────────────────────────────────────────
# Цели-кнопки появляются не сразу (гараж инстансится при первом открытии), поэтому
# отсутствие цели — не ошибка: просто ждём следующего кадра.
func _aim_node(node: CanvasItem, text: String) -> void:
	if node == null or not is_instance_valid(node) or not node.is_visible_in_tree():
		if _aimed != "":
			_guide.clear()
			_aimed = ""
		return
	var key := "%s|%d|%s" % [_step, node.get_instance_id(), text]
	if _aimed == key:
		return
	_aimed = key
	_set_ui_locked(false)
	_guide.point_at_node(node, text)

func _aim_world(getter: Callable, text: String, gate: int = TutorialGuide.Gate.TARGET) -> void:
	var key := "%s|%s|%s" % [_step, getter.get_method(), text]
	if _aimed == key:
		return
	_aimed = key
	# В режиме WORLD заглушки нет (иначе она съела бы и тап по миру), поэтому меню/гараж
	# на время шага гасим отдельно — руками HUD.
	_set_ui_locked(gate == TutorialGuide.Gate.WORLD)
	_guide.point_at_world(getter, text, true, gate)

func _set_ui_locked(locked: bool) -> void:
	var hud: Node = get_parent()
	if hud != null and hud.has_method("set_ui_locked"):
		hud.set_ui_locked(locked)

# ── Поиск целей ──────────────────────────────────────────────────────────────
func _hud_node(name: String) -> CanvasItem:
	var hud: Node = get_parent()
	if hud == null:
		return null
	return hud.get_node_or_null(name) as CanvasItem

func _hud_ui(key: String) -> Control:
	var hud: Node = get_parent()
	if hud == null or not hud.has_method("tutorial_target"):
		return null
	return hud.tutorial_target(key)

func _garage_node(key: String) -> Control:
	var g: Node = _hud_ui("garage")
	if g == null or not g.has_method("tutorial_target"):
		return null
	return g.tutorial_target(key)

func _quest_tracker() -> Control:
	var q: Node = get_tree().get_first_node_in_group("quests")
	if q == null or not q.has_method("tracker_node"):
		return null
	return q.tracker_node()

func _vehicle() -> Node:
	var cc: Node = get_tree().get_first_node_in_group("camera_controller")
	if cc != null and "current_vehicle" in cc:
		return cc.current_vehicle
	return null

func _vehicle_point() -> Vector3:
	var v: Node = _vehicle()
	if not (v is Node3D):
		return Vector3.ZERO
	return (v as Node3D).global_position + Vector3.UP

# Ближайший ПОДБИРАЕМЫЙ блок в мире — на него показываем в шаге «подбери блок».
# Отбор ровно тот же, что у _grab_world_block: кабину и стационарные блоки взять нельзя,
# и палец на них показывал тупик — игрок тапал, ничего не происходило.
func _nearest_loose_block() -> Vector3:
	var objects: Node = get_node_or_null("/root/Main/objects")
	var v: Node = _vehicle()
	if objects == null or not (v is Node3D):
		return Vector3.ZERO
	var origin: Vector3 = (v as Node3D).global_position
	var best: Vector3 = Vector3.ZERO
	var best_d: float = INF
	for c in objects.get_children():
		if not ("block" in c) or not (c is Node3D):
			continue
		var bt: int = int(c.get("block"))
		if bt == G.Block.CABIN or G.is_stationary(bt):
			continue
		var d: float = origin.distance_squared_to((c as Node3D).global_position)
		if d < best_d:
			best_d = d
			best = (c as Node3D).global_position
	return best if best_d < INF else origin

# ── Конец обучения → первый сюжетный бой ─────────────────────────────────────
func _on_tutorial_finished() -> void:
	if _story_started:
		return
	_story_started = true
	_explain.clear()                      # пропуск в середине пояснения не должен держать заглушку
	_guide.clear()
	_set_ui_locked(false)
	_step = ""
	_spawn_first_enemy.call_deferred()

func _spawn_first_enemy() -> void:
	var sp: Node = get_node_or_null("/root/Main/EnemySpawner")
	var enemy: Node = null
	if sp != null and sp.has_method("spawn_scout_near_player"):
		enemy = sp.spawn_scout_near_player()
	if enemy == null:
		# Ровного места рядом не нашлось — квест всё равно закрываемый: обычный поток
		# врагов приведёт кого-нибудь сам, просто не так быстро.
		_say_lines(["That's the basics. Raiders roam out there — the first one you meet is yours."])
		return
	_say_lines([
		"A scout picked up your signal. He's already close.",
		"Aim at him and hit Attack. Go for the CABIN — break it and the whole vehicle falls apart.",
	])

func _say_lines(lines: Array) -> void:
	var d: Node = get_node_or_null("/root/Dialogue")
	if d == null:
		return
	for l in lines:
		d.say("Mechanic", str(l))
