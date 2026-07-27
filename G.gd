extends Node

var money = 500

signal money_changed                   # для UI: деньги могли измениться пассивно (продавец)

func add_money(value):
	money+= value
	mark_progress_dirty()
	money_changed.emit()
	# Заработок двигает задания «заработай денег». Q грузится после G — берём безопасно.
	var q = get_node_or_null("/root/Q")
	if q:
		q.report("money_earned", value)

var block_inventory = []

# ─── Сохранённые сборки машины ────────────────────────────────────────────────
# name -> layout (массив {x,y,z,block,rot_y}, как blocks.get_layout()). Персистится в user://.
var saved_builds: Dictionary = {}
const BUILDS_PATH := "user://vehicle_builds.json"

func _ready() -> void:
	_load_builds()
	_load_progress()

# ═══ Прогрессия: стартовая фракция, грейды, древо технологий ══════════════════════
# ТЗ: docs/PROGRESSION_DESIGN.md. Сейчас фракция одна («start», имя дадим позже) —
# структура сразу под несколько: новый блок новой фракции = строка в BLOCK_META.
# Грейд гейтит ТОЛЬКО магазин: трофеи с врагов и пылесос ставятся без лицензии.

signal grade_up(faction: String, new_grade: int)
signal progress_changed                # XP/ДИ/исследования изменились (для UI)

const FACTIONS := {
	"start": {"name": "Стартовая", "grades": 5, "xp_thresholds": [0, 100, 300, 700, 1500]},
}
# Блок → фракция / грейд / цена исследования в ДИ (раскладка утверждена в ТЗ §2).
const BLOCK_META := {
	Block.CABIN:     {"f": "start", "g": 1, "rp": 0},
	Block.BLOCK:     {"f": "start", "g": 1, "rp": 5},
	Block.WHEEL:     {"f": "start", "g": 1, "rp": 5},
	Block.DRILL:     {"f": "start", "g": 1, "rp": 10},
	Block.COLLECTOR: {"f": "start", "g": 1, "rp": 10},
	Block.INTAKE:    {"f": "start", "g": 2, "rp": 15},
	Block.BELT:      {"f": "start", "g": 2, "rp": 15},
	Block.GUN:       {"f": "start", "g": 2, "rp": 15},
	Block.SOLAR:     {"f": "start", "g": 2, "rp": 15},
	Block.PROCESSOR: {"f": "start", "g": 3, "rp": 20},
	Block.SELLER:    {"f": "start", "g": 3, "rp": 20},
	Block.BATTERY:   {"f": "start", "g": 3, "rp": 20},
	Block.LASER:     {"f": "start", "g": 4, "rp": 30},
	Block.GENERATOR: {"f": "start", "g": 4, "rp": 30},
	Block.REGEN:     {"f": "start", "g": 5, "rp": 40},
	Block.SHIELD:    {"f": "start", "g": 5, "rp": 40},
	Block.RADAR:     {"f": "start", "g": 2, "rp": 15},   # утилита: включает карту-радар на машине
	Block.SUPPORT:   {"f": "start", "g": 1, "rp": 5},    # фикс-опора: без неё нельзя встать на якорь
	Block.SMALL_WHEEL: {"f": "start", "g": 1, "rp": 5},
	Block.BIG_WHEEL:   {"f": "start", "g": 2, "rp": 15},
	Block.TOP_WHEEL:   {"f": "start", "g": 2, "rp": 15},
	Block.STAB_WHEEL:  {"f": "start", "g": 2, "rp": 15},
	Block.BLOCK2:      {"f": "start", "g": 1, "rp": 5},
	Block.COAL_GEN:    {"f": "start", "g": 4, "rp": 30},  # большой генератор: уголь→энергия на якоре
}
# Дерево исследований: ребёнок → родитель (рёбра утверждены игроком, ТЗ §4).
const TECH_PARENT := {
	Block.BLOCK: Block.CABIN,     Block.WHEEL: Block.BLOCK,
	Block.DRILL: Block.CABIN,     Block.GUN: Block.DRILL,
	Block.LASER: Block.GUN,
	Block.COLLECTOR: Block.CABIN, Block.INTAKE: Block.COLLECTOR,
	Block.BELT: Block.INTAKE,     Block.SELLER: Block.BELT,
	Block.PROCESSOR: Block.COLLECTOR, Block.GENERATOR: Block.PROCESSOR,
	Block.SOLAR: Block.CABIN,     Block.BATTERY: Block.SOLAR,
	Block.SHIELD: Block.BATTERY,  Block.REGEN: Block.SHIELD,
	Block.RADAR: Block.CABIN,     # утилита ветвится от кабины (ранняя QoL 2-го грейда)
	Block.SUPPORT: Block.CABIN,   # опора — ранняя, чтобы якорь был доступен с начала
	Block.SMALL_WHEEL: Block.WHEEL, Block.BIG_WHEEL: Block.WHEEL,
	Block.TOP_WHEEL: Block.WHEEL,   Block.STAB_WHEEL: Block.WHEEL,
	Block.BLOCK2: Block.BLOCK,      Block.COAL_GEN: Block.GENERATOR,
}
# Исследовано с самого начала — иначе не собрать машину и нет цикла денег.
const START_RESEARCHED := [Block.CABIN, Block.BLOCK, Block.WHEEL, Block.DRILL, Block.COLLECTOR, Block.SUPPORT]

var faction_xp := {"start": 0}
var research_points := 0               # ДИ — валюта дерева
var researched: Array = []             # изученные Block (int)
var quests_done: Array = []            # id выполненных квестов (подключим на этапе 3)

# Текущий грейд фракции по накопленному XP (1..grades).
func grade(f: String) -> int:
	if not FACTIONS.has(f):
		return 1
	var th: Array = FACTIONS[f]["xp_thresholds"]
	var xp := int(faction_xp.get(f, 0))
	var g := 1
	for i in th.size():
		if xp >= int(th[i]):
			g = i + 1
	return mini(g, int(FACTIONS[f]["grades"]))

func add_faction_xp(f: String, amount: int) -> void:
	if amount <= 0 or not FACTIONS.has(f):
		return
	var before := grade(f)
	faction_xp[f] = int(faction_xp.get(f, 0)) + amount
	mark_progress_dirty()
	progress_changed.emit()
	var after := grade(f)
	for gi in range(before + 1, after + 1):
		grade_up.emit(f, gi)           # скачок через 2+ порога объявляет КАЖДЫЙ грейд

func add_research_points(amount: int) -> void:
	if amount <= 0:
		return
	research_points += amount
	mark_progress_dirty()
	progress_changed.emit()

# Единая точка конверсии игровых событий в прогрессию (зовёт Q.report — он уже шина
# всех событий). Правила из ТЗ §3: убийство +15 XP (первый килл нового ВИДА врага
# ещё +5 ДИ — видов пока один, задел на будущее), добыча +1 XP. money_earned XP не даёт.
var killed_kinds: Array = []           # виды врагов, за которые уже выдали ДИ первого килла

func on_game_event(event: String, amount: int = 1, kind: String = "default") -> void:
	match event:
		"enemy_killed":
			add_faction_xp("start", 15 * amount)
			if not killed_kinds.has(kind):
				killed_kinds.append(kind)
				add_research_points(5)
		"ore_mined":
			add_faction_xp("start", amount)

# Имя блока для UI (реплика Механика, замки) — из ключей enum.
func block_name(bt: int) -> String:
	var names: Array = Block.keys()
	if bt >= 0 and bt < names.size():
		return str(names[bt]).capitalize()
	return "?"

# Блоки заданного грейда фракции (для «открылось в магазине: …»).
func blocks_of_grade(f: String, g: int) -> Array:
	var out: Array = []
	for bt in BLOCK_META:
		var m: Dictionary = BLOCK_META[bt]
		if m["f"] == f and int(m["g"]) == g:
			out.append(bt)
	return out

# Доступен ли блок в МАГАЗИНЕ (гараж SHOP). Трофеи этим не гейтятся.
func is_block_shop_unlocked(bt: int) -> bool:
	var m: Dictionary = BLOCK_META.get(bt, {})
	if m.is_empty():
		return true
	return researched.has(bt) and grade(m["f"]) >= int(m["g"])

# Почему блок нельзя исследовать; "" — можно (текст для замка в UI).
func research_lock_reason(bt: int) -> String:
	if researched.has(bt):
		return "уже исследовано"
	var m: Dictionary = BLOCK_META.get(bt, {})
	if m.is_empty():
		return "нет данных"
	var parent := int(TECH_PARENT.get(bt, -1))
	if parent >= 0 and not researched.has(parent):
		return "нужен предыдущий блок: %s" % block_name(parent)
	if grade(m["f"]) < int(m["g"]):
		return "нужен грейд %d" % int(m["g"])
	if research_points < int(m["rp"]):
		return "нужно ДИ: %d" % int(m["rp"])
	return ""

# Исследовать блок: списывает ДИ, «дарит» ПЕРВЫЙ экземпляр в инвентарь (без двойного
# гейта «исследовал → ещё накопи»), открывает блок в магазине.
func research(bt: int) -> bool:
	if research_lock_reason(bt) != "":
		return false
	research_points -= int((BLOCK_META[bt] as Dictionary)["rp"])
	researched.append(bt)
	block_inventory.append(bt)
	mark_progress_dirty()
	progress_changed.emit()
	return true

# ── Персист прогресса (money/инвентарь/XP/ДИ/исследования) ────────────────────────
# Debounce ~1с: mark_progress_dirty() зови после КАЖДОЙ мутации money/block_inventory
# извне (tech_ui/hud/black_hole/vehicle_body_3d уже зовут). Сворачивание приложения
# (мобайл!) и закрытие окна пишут немедленно.
const PROGRESS_PATH := "user://progress.json"
var _progress_dirty := false

func mark_progress_dirty() -> void:
	if _progress_dirty:
		return
	_progress_dirty = true
	get_tree().create_timer(1.0).timeout.connect(_flush_progress)

func _flush_progress() -> void:
	if not _progress_dirty:
		return
	_progress_dirty = false
	var f = FileAccess.open(PROGRESS_PATH, FileAccess.WRITE)
	if f:
		# Имена ключей = имена полей (ТЗ §1): формат «навсегда», меняем осознанно.
		f.store_string(JSON.stringify({
			"money": money,
			"block_inventory": block_inventory,
			"faction_xp": faction_xp,
			"research_points": research_points,
			"researched": researched,
			"quests_done": quests_done,
			"killed_kinds": killed_kinds,
		}))
		f.close()

func _load_progress() -> void:
	researched = START_RESEARCHED.duplicate()
	if not FileAccess.file_exists(PROGRESS_PATH):
		return
	var f = FileAccess.open(PROGRESS_PATH, FileAccess.READ)
	if f == null:
		return
	var data = JSON.parse_string(f.get_as_text())
	f.close()
	if not (data is Dictionary):
		return
	money = int(data.get("money", money))
	block_inventory = []
	for b in data.get("block_inventory", []):
		block_inventory.append(int(b))       # JSON отдаёт float — приводим
	var fx = data.get("faction_xp", {})
	if fx is Dictionary:
		for k in fx:
			faction_xp[str(k)] = int(fx[k])
	research_points = int(data.get("research_points", 0))
	var res = data.get("researched", [])
	if res is Array and not res.is_empty():
		researched = []
		for b in res:
			researched.append(int(b))
	quests_done = []
	for q in data.get("quests_done", []):
		quests_done.append(str(q))
	killed_kinds = []
	for k2 in data.get("killed_kinds", []):
		killed_kinds.append(str(k2))

func _notification(what: int) -> void:
	# Мобайл: сворачивание/кнопка «назад» (Android выходит по ней по умолчанию) — пишем
	# сразу, не ждём debounce.
	if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_APPLICATION_PAUSED \
			or what == NOTIFICATION_WM_GO_BACK_REQUEST:
		_progress_dirty = true
		_flush_progress()

func save_build(build_name: String, layout: Array) -> void:
	saved_builds[build_name] = layout
	_persist_builds()

func delete_build(build_name: String) -> void:
	saved_builds.erase(build_name)
	_persist_builds()

func _persist_builds() -> void:
	var f = FileAccess.open(BUILDS_PATH, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(saved_builds))
		f.close()

func _load_builds() -> void:
	if not FileAccess.file_exists(BUILDS_PATH):
		return
	var f = FileAccess.open(BUILDS_PATH, FileAccess.READ)
	if f == null:
		return
	var data = JSON.parse_string(f.get_as_text())
	f.close()
	if data is Dictionary:
		saved_builds = data

# Кол-во блоков по типам в раскладке (значения из JSON приходят float — приводим к int).
func layout_counts(layout: Array) -> Dictionary:
	var c: Dictionary = {}
	for e in layout:
		var t := int(e["block"])
		c[t] = c.get(t, 0) + 1
	return c

enum Block {
	EMPTY,
	CABIN,#1
	WHEEL,#2
	BLOCK,#3
	DRILL,#4
	COLLECTOR,#5
	INTAKE,#6
	BELT,#7
	PROCESSOR,#8
	SELLER,#9
	LASER,#10
	GUN,#11
	BATTERY,#12
	SOLAR,#13
	GENERATOR,#14
	REGEN,#15
	SHIELD,#16
	RADAR,#17
	SUPPORT,#18
	SMALL_WHEEL,#19
	BIG_WHEEL,#20
	TOP_WHEEL,#21
	STAB_WHEEL,#22
	BLOCK2,#23
	COAL_GEN,#24
}
@onready var cabin_scene: PackedScene = preload("res://cabin.tscn")
@onready var wheel_scene: PackedScene = preload("res://wheel.tscn")
@onready var block_scene: PackedScene = preload("res://block.tscn")
@onready var drill_scene: PackedScene = preload("res://drill.tscn")
@onready var collector_scene: PackedScene = preload("res://collector.tscn")
@onready var intake_scene: PackedScene = preload("res://intake.tscn")
@onready var belt_scene: PackedScene = preload("res://belt.tscn")
@onready var processor_scene: PackedScene = preload("res://processor.tscn")
@onready var seller_scene: PackedScene = preload("res://seller.tscn")
@onready var laser_scene: PackedScene = preload("res://laser.tscn")
@onready var gun_scene: PackedScene = preload("res://gun.tscn")
@onready var battery_scene: PackedScene = preload("res://battery.tscn")
@onready var solar_scene: PackedScene = preload("res://solar.tscn")
@onready var generator_scene: PackedScene = preload("res://generator.tscn")
@onready var regen_scene: PackedScene = preload("res://regen.tscn")
@onready var shield_scene: PackedScene = preload("res://shield.tscn")
@onready var radar_scene: PackedScene = preload("res://radar.tscn")   # при установке даёт карту-радар
@onready var support_scene: PackedScene = preload("res://support.tscn")   # фикс-опора: без неё нет якоря
@onready var small_wheel_scene: PackedScene = preload("res://small_wheel.tscn")
@onready var big_wheel_scene: PackedScene = preload("res://big_wheel.tscn")
@onready var top_wheel_scene: PackedScene = preload("res://top_wheel.tscn")     # крепление сверху
@onready var stab_wheel_scene: PackedScene = preload("res://stab_wheel.tscn")   # стабилизирующее (90°)
@onready var block2_scene: PackedScene = preload("res://block2.tscn")           # 2×1×1
@onready var coal_gen_scene: PackedScene = preload("res://coal_gen.tscn")       # 2×1×2, уголь→энергия на якоре

# Категории блоков — общие для гаража (tech_ui SHOP-фильтр) и «шара» выбора блока
# в стройке (block_globe.gd). Ключ "other" не хранится явно — это всё, что не попало
# ни в одну из категорий ниже.
# Стационарные блоки (базы): при постановке на ЗЕМЛЮ рождают якорную структуру, на
# мобильную машину не ставятся (см. docs/STATIONARY_BLOCKS_DESIGN.md). Пока — только продавец.
const STATIONARY_BLOCKS := [Block.SELLER]
func is_stationary(bt: int) -> bool:
	return STATIONARY_BLOCKS.has(int(bt))

const BLOCK_CATEGORIES := {
	"attack":  [Block.GUN, Block.LASER, Block.DRILL],
	"blocks":  [Block.BLOCK, Block.CABIN, Block.WHEEL, Block.BLOCK2,
		Block.SMALL_WHEEL, Block.BIG_WHEEL, Block.TOP_WHEEL, Block.STAB_WHEEL, Block.SUPPORT],
	"factory": [Block.COLLECTOR, Block.INTAKE, Block.BELT, Block.PROCESSOR, Block.SELLER, Block.GENERATOR, Block.COAL_GEN],
}

func get_scene(block: Block) -> PackedScene:
	match block:
		Block.CABIN:   return cabin_scene
		Block.WHEEL: return wheel_scene
		Block.BLOCK:   return block_scene
		Block.DRILL:   return drill_scene
		Block.COLLECTOR:   return collector_scene
		Block.INTAKE: return intake_scene
		Block.BELT: return belt_scene
		Block.PROCESSOR: return processor_scene
		Block.SELLER: return seller_scene
		Block.LASER: return laser_scene
		Block.GUN: return gun_scene
		Block.BATTERY: return battery_scene
		Block.SOLAR: return solar_scene
		Block.GENERATOR: return generator_scene
		Block.REGEN: return regen_scene
		Block.SHIELD: return shield_scene
		Block.RADAR: return radar_scene
		Block.SUPPORT: return support_scene
		Block.SMALL_WHEEL: return small_wheel_scene
		Block.BIG_WHEEL: return big_wheel_scene
		Block.TOP_WHEEL: return top_wheel_scene
		Block.STAB_WHEEL: return stab_wheel_scene
		Block.BLOCK2: return block2_scene
		Block.COAL_GEN: return coal_gen_scene
	return null

# Любой вариант колеса (для авто-ориентации по грани и т.п.).
func is_wheel(bt: int) -> bool:
	return int(bt) in [Block.WHEEL, Block.SMALL_WHEEL, Block.BIG_WHEEL, Block.TOP_WHEEL, Block.STAB_WHEEL]
