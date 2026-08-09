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
var _aimed = null                # на что палец наведён сейчас (узел или ключ) — чтобы не пересобирать каждый кадр
var _story_started: bool = false
var _assembly_shown: int = -1    # что уже записано в прогресс шага сборки

# Что Механик говорит, КОГДА ШАГ ЗАКРЫТ: объяснение того, что игрок только что открыл.
# Подсказка «что нажать» — это hint самого квеста, её говорит Q при активации.
const DONE_LINES := {
	"tut_quests": [
		"This is the full quest list. Tutorial on top, then story, then dailies.",
		"The star picks which quest the tracker shows. Nothing here is mandatory — look whenever you like.",
	],
	"tut_filters": [
		"Inventory holds every block you own. The count sits in the slot corner.",
		"Tapping a slot takes the block into your hand — then place it on the vehicle in build mode.",
	],
	"tut_shop": [
		"This is the shop. Your money is in the header, top right; the price is on the slot's button.",
		"A locked block means one of two things: not enough money, or it is not researched yet. Research comes first, buying second.",
	],
	"tut_tech": [
		"The tech tree. RP stands for Research Points — you get them from quests and from the first kill of each enemy type.",
		"RP unlocks blocks: until a block is researched, the shop will not sell it.",
		"Grade is your licence level. It rises with faction XP and gates whole branches of the tree and of the story.",
	],
	"tut_music": [
		"And the music tab — tracks and volume. Nothing you have to press, just so you know where it is.",
	],
}

func _ready() -> void:
	_guide = GUIDE.new()
	add_child(_guide)
	_guide.bind_hud(get_parent())
	Q.changed.connect(_on_quests_changed)
	Q.tutorial_finished.connect(_on_tutorial_finished)
	set_process(true)
	_on_quests_changed()

# ── Текущий шаг ──────────────────────────────────────────────────────────────
func _on_quests_changed() -> void:
	var id := _current_step_id()
	if id == _step:
		return
	# Шаг сменился — объясняем то, что игрок только что увидел, и переносим палец.
	if _step != "" and DONE_LINES.has(_step):
		_say_lines(DONE_LINES[_step])
	_step = id
	_aimed = null
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
func _process(_delta: float) -> void:
	if _step == "":
		return
	if _step == "tut_place_all":
		_drive_assembly_progress()
	_aim_current_step()

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
			_aim_node(_hud_node("ModeToggle"), "Tap here — this is BUILD mode")
		"tut_take_world":
			_aim_world(_nearest_loose_block, "Double-tap the block to take it into your hand")
		"tut_place_first":
			_aim_world(_vehicle_point, "Double-tap the vehicle where the block should go")
		"tut_place_all":
			# Свободный шаг: тут много тапов по миру, точку не угадать. Мир открыт, UI — нет.
			_aim_world(_vehicle_point, "Mount the rest the same way", TutorialGuide.Gate.WORLD)
		"tut_mode_move":
			_aim_node(_hud_node("ModeToggle"), "Tap again — back to driving")
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
		if _aimed != null:
			_guide.clear()
			_aimed = null
		return
	if _aimed == node:
		return
	_aimed = node
	_set_ui_locked(false)
	_guide.point_at_node(node, text)

func _aim_world(getter: Callable, text: String, gate: int = TutorialGuide.Gate.TARGET) -> void:
	var key: String = str(getter.get_method())
	if _aimed is String and _aimed == key:
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

# Ближайший СВОБОДНЫЙ блок в мире — на него показываем в шаге «подбери блок».
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
	# Реплику про музыку уже сказал _on_quests_changed при смене шага на пустой.
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
