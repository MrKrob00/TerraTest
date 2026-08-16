extends Node

# Стартовый капитал ≈ четыре простых блока по магазинной цене (G.shop_price). Раньше было
# 500$ при выдуманной цене блока в 5$ — сотня блоков на старте, то есть деньги в начале игры
# ничего не значили.
var money = 1000

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
	_load_settings()

# ═══ Настройки игрока (чувствительность камеры и т.п.) ════════════════════════════
# Отдельный файл от прогресса — это конфиг, не сейв. Множители к базовым константам
# камеры (1.0 = как задумано). Меняются редко → пишем сразу (без debounce).
const SETTINGS_PATH := "user://settings.json"
var cam_look_sens: float = 1.0     # чувствительность поворота камеры свайпом/мышью
var cam_zoom_sens: float = 1.0     # чувствительность пинч-зума
var cam_invert_y: bool = false     # инвертировать вертикаль (наклон взгляда)
# Куда игрок перетащил плавающие окна: имя окна -> [x, y]. Тоже конфиг, а не прогресс —
# сброс сейва их не трогает, и окно, которое игрок один раз положил себе под руку, там и
# остаётся. Пусто = окно ни разу не двигали, стоит на штатном месте из сцены.
var ui_windows: Dictionary = {}

func window_pos(id: String) -> Variant:
	var v: Variant = ui_windows.get(id)
	return Vector2(float(v[0]), float(v[1])) if v is Array and v.size() == 2 else null

func set_window_pos(id: String, pos: Vector2) -> void:
	ui_windows[id] = [pos.x, pos.y]
	save_settings()

func save_settings() -> void:
	var f = FileAccess.open(SETTINGS_PATH, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify({
			"cam_look_sens": cam_look_sens,
			"cam_zoom_sens": cam_zoom_sens,
			"cam_invert_y": cam_invert_y,
			"ui_windows": ui_windows,
		}))
		f.close()

func _load_settings() -> void:
	if not FileAccess.file_exists(SETTINGS_PATH):
		return
	var f = FileAccess.open(SETTINGS_PATH, FileAccess.READ)
	if f == null:
		return
	var data = JSON.parse_string(f.get_as_text())
	f.close()
	if not (data is Dictionary):
		return
	cam_look_sens = clampf(float(data.get("cam_look_sens", 1.0)), 0.2, 3.0)
	cam_zoom_sens = clampf(float(data.get("cam_zoom_sens", 1.0)), 0.2, 3.0)
	cam_invert_y = bool(data.get("cam_invert_y", false))
	var w = data.get("ui_windows", {})
	if w is Dictionary:
		ui_windows = w

# ═══ Прогрессия: стартовая фракция, грейды, древо технологий ══════════════════════
# ТЗ: docs/PROGRESSION_DESIGN.md. Сейчас фракция одна («start», имя дадим позже) —
# структура сразу под несколько: новый блок новой фракции = строка в BLOCK_META.
# Грейд гейтит ТОЛЬКО магазин: трофеи с врагов и пылесос ставятся без лицензии.

signal grade_up(faction: String, new_grade: int)
signal progress_changed                # XP/ДИ/исследования изменились (для UI)

const FACTIONS := {
	"start": {"name": "Starter", "grades": 5, "xp_thresholds": [0, 100, 300, 700, 1500]},
}
# Блок → фракция / грейд / цена исследования в ДИ (раскладка утверждена в ТЗ §2).
const BLOCK_META := {
	Block.CABIN:     {"f": "start", "g": 1, "rp": 0},
	Block.BLOCK:     {"f": "start", "g": 1, "rp": 5},
	Block.WHEEL:     {"f": "start", "g": 1, "rp": 5},
	Block.DRILL:     {"f": "start", "g": 1, "rp": 10},
	Block.COLLECTOR: {"f": "start", "g": 1, "rp": 10},
	Block.RECEIVER:    {"f": "start", "g": 2, "rp": 15},
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
	Block.ROCKET:      {"f": "start", "g": 4, "rp": 35},  # ракетница: снаряд с AOE-взрывом
	Block.BLOCK3:      {"f": "start", "g": 2, "rp": 10},
	Block.WEDGE:       {"f": "start", "g": 1, "rp": 5},
	Block.WEDGE2:      {"f": "start", "g": 2, "rp": 10},
	Block.ARMOR:       {"f": "start", "g": 2, "rp": 15},
	Block.SMALL_DRILL: {"f": "start", "g": 1, "rp": 8},
	Block.BELT_SPLIT:  {"f": "start", "g": 2, "rp": 15},
	Block.BELT_CROSS:  {"f": "start", "g": 3, "rp": 20},
	Block.ROT_SUPPORT: {"f": "start", "g": 3, "rp": 20},   # тир выше обычной опоры
	Block.STORAGE:     {"f": "start", "g": 3, "rp": 25},
	Block.AUTO_MINER:  {"f": "start", "g": 4, "rp": 35},
	Block.FABRICATOR:  {"f": "start", "g": 5, "rp": 40},
	Block.SCRAPPER:    {"f": "start", "g": 3, "rp": 25},   # разбор трофеев — средний тир
	Block.ARMOR2:      {"f": "start", "g": 2, "rp": 18},
	Block.ARMOR4:      {"f": "start", "g": 3, "rp": 25},
	Block.HALF_BLOCK:  {"f": "start", "g": 1, "rp": 5},
	Block.HALF_BLOCK2: {"f": "start", "g": 1, "rp": 8},
	Block.WIRELESS_CHARGER: {"f": "start", "g": 4, "rp": 30},
	Block.MORTAR:      {"f": "start", "g": 4, "rp": 35},
	Block.POUND_CANNON: {"f": "start", "g": 3, "rp": 25},
	Block.SHOTGUN:     {"f": "start", "g": 2, "rp": 18},
	Block.COMP_FACTORY: {"f": "start", "g": 4, "rp": 35},   # компоненты — ступень перед фабрикатором
}
# Дерево исследований: ребёнок → родитель (рёбра утверждены игроком, ТЗ §4).
const TECH_PARENT := {
	Block.BLOCK: Block.CABIN,     Block.WHEEL: Block.BLOCK,
	Block.DRILL: Block.CABIN,     Block.GUN: Block.DRILL,
	Block.LASER: Block.GUN,
	Block.COLLECTOR: Block.CABIN, Block.RECEIVER: Block.COLLECTOR,
	Block.BELT: Block.RECEIVER,     Block.SELLER: Block.BELT,
	Block.PROCESSOR: Block.COLLECTOR, Block.GENERATOR: Block.PROCESSOR,
	Block.SOLAR: Block.CABIN,     Block.BATTERY: Block.SOLAR,
	Block.SHIELD: Block.BATTERY,  Block.REGEN: Block.SHIELD,
	Block.RADAR: Block.CABIN,     # утилита ветвится от кабины (ранняя QoL 2-го грейда)
	Block.SUPPORT: Block.CABIN,   # опора — ранняя, чтобы якорь был доступен с начала
	Block.SMALL_WHEEL: Block.WHEEL, Block.BIG_WHEEL: Block.WHEEL,
	Block.TOP_WHEEL: Block.WHEEL,   Block.STAB_WHEEL: Block.WHEEL,
	Block.BLOCK2: Block.BLOCK,      Block.COAL_GEN: Block.GENERATOR,
	Block.ROCKET: Block.LASER,      # ракетница ветвится от лазера (продвинутое оружие)
	Block.BLOCK3: Block.BLOCK2,     Block.WEDGE: Block.BLOCK,
	Block.WEDGE2: Block.WEDGE,      Block.ARMOR: Block.BLOCK,
	Block.SMALL_DRILL: Block.DRILL, Block.BELT_SPLIT: Block.BELT,
	Block.BELT_CROSS: Block.BELT_SPLIT,
	Block.ROT_SUPPORT: Block.SUPPORT,   # апгрейд опоры: обычная всё равно нужна
	Block.STORAGE: Block.RECEIVER,
	Block.AUTO_MINER: Block.PROCESSOR,
	Block.FABRICATOR: Block.COMP_FACTORY,   # блоки собираются из компонентов, значит после них
	Block.COMP_FACTORY: Block.PROCESSOR,
	Block.SCRAPPER: Block.PROCESSOR,    # разбор — ветка переработки, не сборки
	Block.ARMOR2: Block.ARMOR,          Block.ARMOR4: Block.ARMOR2,
	Block.HALF_BLOCK: Block.BLOCK,      Block.HALF_BLOCK2: Block.HALF_BLOCK,
	Block.WIRELESS_CHARGER: Block.BATTERY,   # переливание энергии — ветка аккумулятора
	Block.POUND_CANNON: Block.GUN,      Block.SHOTGUN: Block.GUN,
	Block.MORTAR: Block.ROCKET,         # навесная стрельба ветвится от ракетницы
}
# ═══ МАТЕРИАЛЫ: руды, слитки, компоненты ═════════════════════════════════════════
# Четыре руды плавятся в четыре слитка, уголь не плавится (он топливо). Шесть компонентов
# собираются каждый ИЗ ДВУХ РАЗНЫХ материалов — это не украшение, а требование движка:
# фабрикатор различает свои два входа именно по виду материала (первый пришедший занимает
# слот A, первый отличный — слот B), поэтому рецепт из двух одинаковых собрать нечем.
#
# Хранятся не отдельными сценами, а полями на одном ресурсе (resource.gd): вид задаётся
# парой «тип + индекс», а выглядит по-разному материалом. Шестнадцать сцен ради шестнадцати
# видов грузили бы память впустую, а модели, когда они появятся, встанут в ту же точку.
enum Metal { FERRITE, CUPRITE, SILICATE, TITANITE }
const METAL_NAME := ["Ferrite", "Cuprite", "Silicate", "Titanite"]
## Цвет руды и слитка. Тот же список лежит у спавнера жил (resource_nodes.ore_colors):
## жила красится в него же, поэтому по виду залежи понятно, что из неё выйдет.
const METAL_COLOR := [
	Color(0.72, 0.44, 0.24),   # Ferrite — ржавый
	Color(0.90, 0.55, 0.25),   # Cuprite — медный
	Color(0.45, 0.75, 0.80),   # Silicate — стеклянный
	Color(0.78, 0.80, 0.86),   # Titanite — белый металл
]

enum Comp { PLATE, COIL, LENS, SERVO, CIRCUIT, CORE }
const COMP_NAME := ["Plate", "Coil", "Lens", "Servo", "Circuit", "Core"]
const COMP_COLOR := [
	Color(0.70, 0.72, 0.78),   # Plate
	Color(0.95, 0.62, 0.30),   # Coil
	Color(0.55, 0.85, 0.95),   # Lens
	Color(0.60, 0.70, 0.55),   # Servo
	Color(0.45, 0.90, 0.55),   # Circuit
	Color(0.85, 0.55, 1.00),   # Core
]

## Из чего собирается компонент: ровно ДВА РАЗНЫХ материала и сколько штук каждого.
## Ключ материала — тот же, что возвращает resource.kind_key(): "m<металл>" слиток,
## "c<компонент>" компонент. Первые три компонента варятся из слитков, вторые три — из
## компонентов, отсюда и два «яруса»: без первого яруса второй не собрать.
const COMP_RECIPE := {
	Comp.PLATE:   {"m0": 2, "m3": 1},   # Ferrite + Titanite
	Comp.COIL:    {"m1": 2, "m0": 1},   # Cuprite + Ferrite
	Comp.LENS:    {"m2": 2, "m1": 1},   # Silicate + Cuprite
	Comp.SERVO:   {"c1": 1, "c0": 1},   # Coil + Plate
	Comp.CIRCUIT: {"c2": 1, "c1": 1},   # Lens + Coil
	Comp.CORE:    {"c4": 1, "c3": 1},   # Circuit + Servo
}

## Ключ слитка/компонента для рецептов и складов.
static func metal_key(m: int) -> String:
	return "m%d" % m

static func comp_key(c: int) -> String:
	return "c%d" % c

## Человеческое имя материала по ключу — для табличек и подсказок.
## Порядок проверок важен: «coal» и «chunk:» начинаются с той же буквы, что и компоненты.
func kind_name(key: String) -> String:
	if key == "coal":
		return "Coal"
	if key.begins_with("chunk:"):
		return block_name(int(key.substr(6)))   # сколько внутри — знает только держатель чанка
	if key.begins_with("ore"):
		var o: int = int(key.substr(3))
		return "%s Ore" % METAL_NAME[o] if o < METAL_NAME.size() else key
	if key.begins_with("m"):
		var i: int = int(key.substr(1))
		return METAL_NAME[i] if i < METAL_NAME.size() else key
	if key.begins_with("c"):
		var j: int = int(key.substr(1))
		return COMP_NAME[j] if j < COMP_NAME.size() else key
	return key

## РЕЦЕПТЫ БЛОКОВ: {ключ материала → сколько штук}. Один источник правды на двоих — по
## нему фабрикатор собирает, а Scrapper возвращает половину при разборе.
##
## В каждом рецепте РОВНО ДВА разных ключа, и это не стиль, а требование фабрикатора: он
## различает свои входы по виду материала (слот A — первый пришедший вид, слот B — первый
## отличный), третьему виду там просто некуда встать. Хотите усложнить блок — поднимайте
## ярус материала, а не число слагаемых.
##
## Блока без рецепта Scrapper не принимает и не портит (см. scrapper.gd), поэтому пустая
## строка здесь — это не «пока не сделали», а «разбирать нельзя».
const BLOCK_RECIPE := {
	# ── Корпус и броня ────────────────────────────────────────────────────────
	Block.BLOCK:        {"m0": 2, "m3": 2},
	Block.BLOCK2:       {"m0": 4, "m3": 3},
	Block.BLOCK3:       {"m0": 5, "m3": 5},
	Block.WEDGE:        {"m0": 1, "m3": 1},
	Block.WEDGE2:       {"m0": 2, "m3": 2},
	Block.HALF_BLOCK:   {"m0": 1, "m3": 1},
	Block.HALF_BLOCK2:  {"m0": 2, "m3": 1},
	Block.ARMOR:        {"c0": 2, "m3": 2},
	Block.ARMOR2:       {"c0": 3, "m3": 4},
	Block.ARMOR4:       {"c0": 6, "m3": 8},
	Block.SUPPORT:      {"m0": 4, "m1": 2},
	Block.ROT_SUPPORT:  {"c3": 2, "m0": 6},
	Block.CABIN:        {"c5": 1, "c0": 4},
	# ── Ход ───────────────────────────────────────────────────────────────────
	Block.WHEEL:        {"c3": 1, "m0": 4},
	Block.SMALL_WHEEL:  {"c3": 1, "m0": 2},
	Block.BIG_WHEEL:    {"c3": 2, "m0": 8},
	Block.TOP_WHEEL:    {"c3": 1, "m0": 3},
	Block.STAB_WHEEL:   {"c3": 1, "m0": 3},
	# ── Добыча и фабрика ──────────────────────────────────────────────────────
	Block.DRILL:        {"c3": 2, "m3": 6},
	Block.SMALL_DRILL:  {"c3": 1, "m3": 3},
	Block.COLLECTOR:    {"c1": 2, "m1": 4},
	Block.RECEIVER:     {"c1": 1, "m1": 3},
	Block.BELT:         {"c1": 1, "m0": 2},
	Block.BELT_SPLIT:   {"c1": 2, "m0": 3},
	Block.BELT_CROSS:   {"c1": 2, "m0": 4},
	Block.PROCESSOR:    {"c4": 2, "m0": 6},
	Block.SELLER:       {"c4": 1, "m1": 4},
	Block.STORAGE:      {"c0": 3, "m0": 6},
	Block.AUTO_MINER:   {"c5": 1, "c3": 3},
	Block.FABRICATOR:   {"c5": 1, "c4": 3},
	Block.COMP_FACTORY: {"c4": 2, "c1": 4},
	Block.SCRAPPER:     {"c3": 2, "c0": 4},
	# ── Энергия ───────────────────────────────────────────────────────────────
	Block.BATTERY:      {"c1": 4, "m1": 5},
	Block.SOLAR:        {"c2": 4, "m2": 4},
	Block.GENERATOR:    {"c1": 4, "m0": 6},
	Block.COAL_GEN:     {"c1": 2, "m0": 6},
	Block.WIRELESS_CHARGER: {"c4": 2, "c1": 3},
	# ── Поддержка ─────────────────────────────────────────────────────────────
	Block.REGEN:        {"c4": 2, "c2": 2},
	Block.SHIELD:       {"c4": 2, "c2": 3},
	Block.RADAR:        {"c2": 3, "c4": 1},
	# ── Оружие ────────────────────────────────────────────────────────────────
	Block.GUN:          {"c1": 3, "m3": 6},
	Block.SHOTGUN:      {"c1": 3, "m3": 5},
	Block.POUND_CANNON: {"c0": 4, "c1": 3},
	Block.LASER:        {"c2": 3, "c4": 2},
	Block.ROCKET:       {"c4": 3, "c1": 3},
	Block.MORTAR:       {"c0": 5, "c4": 2},
}

## Из чего собирается блок: {ключ материала → штук}. Пустой словарь — рецепта нет.
func block_recipe(bt: int) -> Dictionary:
	return BLOCK_RECIPE.get(bt, {})

## Во что обходится блок ВСЕГО, штуками материала. Для прикидок и подписей.
func recipe_total(bt: int) -> int:
	var n: int = 0
	for k in block_recipe(bt):
		n += int(block_recipe(bt)[k])
	return n

## ЦЕНА материала у продавца. Задана только у слитков — всё остальное считается ОТ НЕЁ:
## руда вчетверо дешевле своего слитка (переплавка и есть работа), а компонент стоит сумму
## своего рецепта с наценкой за сборку. Цены компонентов поэтому не надо балансировать
## отдельно: поменяли цену металла — вся ветка пересчиталась сама и осталась согласованной.
## Якорь всей экономики — РУДА: ферритовая стоит те же 10$, что стоила единственная руда
## до появления металлов, и на этом настроены задания «заработай N$». Всё остальное считается
## от неё, поэтому подвинуть экономику можно одной таблицей.
##
## Слиток дороже руды в 2.5 раза, а НЕ в пять: переплавка идёт ОДИН К ОДНОМУ (processor
## upgrade меняет тип, а не количество). Была бы разница пятикратной, продавать руду не имело
## бы смысла никогда, а склад руды превратился бы в кнопку «умножить деньги на пять».
const METAL_PRICE := [25, 35, 45, 60]      # Ferrite, Cuprite, Silicate, Titanite
const ORE_FRACTION := 0.4                  # руда = 0.4 своего слитка (переплавка 1:1)
const COAL_PRICE := 12
## Наценка за сборку: компонент стоит дороже своих частей, иначе собирать его ради продажи
## было бы бессмысленно. Она же делает второй ярус заметно дороже первого.
const CRAFT_MARKUP := 1.25
## Насколько магазин дороже материалов, из которых блок собирается. БОЛЬШЕ ЕДИНИЦЫ — и это
## главное правило экономики: «продать материалы и купить блок» обязано быть ХУЖЕ, чем
## «собрать блок самому». Иначе фабрикатор, компонентный завод и Scrapper не нужны вовсе —
## а именно так и было: блок стоил в магазине 5$ при материалах на 300$.
const SHOP_MARKUP := 1.3

func sell_price(key: String) -> int:
	if key == "coal":
		return COAL_PRICE
	if key.begins_with("chunk:"):
		# Чанк оценивается по тому, во что обошлись лежащие в нём блоки — ЗА ОДИН блок.
		# Умножить на количество — дело продавца, он один знает, сколько внутри.
		var bt: int = int(key.substr(6))
		var sum: int = 0
		var rec: Dictionary = block_recipe(bt)
		for k in rec:
			sum += sell_price(String(k)) * int(rec[k])
		return sum
	if key.begins_with("ore"):
		var mi: int = int(key.substr(3))
		return int(METAL_PRICE[mi] * ORE_FRACTION) if mi < METAL_PRICE.size() else 10
	if key.begins_with("m"):
		var m: int = int(key.substr(1))
		return METAL_PRICE[m] if m < METAL_PRICE.size() else 10
	if key.begins_with("c"):
		var rec2: Dictionary = COMP_RECIPE.get(int(key.substr(1)), {})
		var sum2: float = 0.0
		for k in rec2:
			sum2 += sell_price(String(k)) * int(rec2[k])
		return int(sum2 * CRAFT_MARKUP)
	return 0

## ЦЕНА БЛОКА В МАГАЗИНЕ — не список, а следствие рецепта. Раньше цены лежали руками в
## tech_ui (BLOCK 5$, GUN 35$…) и с материалами не сверялись никак: блок из материалов на
## 300$ продавался за пятёрку, и весь смысл добычи, переработки и сборки исчезал —
## выгоднее было продать всё сырьё и купить готовое.
##
## Теперь цена = стоимость материалов × SHOP_MARKUP, то есть магазин ВСЕГДА дороже сборки.
## Новый блок получает осмысленную цену сам, как только у него появился рецепт.
func shop_price(bt: int) -> int:
	var rec: Dictionary = block_recipe(bt)
	if rec.is_empty():
		return 5                     # рецепта нет — блок не из материалов, ставим минимум
	var sum: float = 0.0
	for k in rec:
		sum += sell_price(String(k)) * int(rec[k])
	return maxi(int(sum * SHOP_MARKUP), 5)

## Что вернёт разбор: ПОЛОВИНА каждого материала, вниз. Пустой словарь — разбирать нельзя.
## Материалы возвращаются ТЕ ЖЕ, что ушли в сборку: разбор — это возврат, а не переплавка
## во что-то универсальное, иначе Scrapper стал бы способом менять один металл на другой.
func scrap_yield(bt: int) -> Dictionary:
	var out: Dictionary = {}
	var rec: Dictionary = block_recipe(bt)
	for k in rec:
		var half: int = int(rec[k]) / 2
		if half > 0:
			out[k] = half
	return out

# Исследовано с самого начала — иначе не собрать машину и нет цикла денег.
const START_RESEARCHED := [Block.CABIN, Block.BLOCK, Block.WHEEL, Block.DRILL, Block.COLLECTOR, Block.SUPPORT]

## Базовый набор блоков: выдаётся на новом сейве и при возрождении после гибели кабины.
## Блоки кружат вокруг машины и осыпаются рядом (reward_orbiter.gd) — игрок собирает сам.
## Один список на оба места, чтобы «начало игры» и «после смерти» не разъезжались.
const STARTER_KIT := [Block.BLOCK, Block.BLOCK, Block.WHEEL, Block.WHEEL,
		Block.WHEEL, Block.WHEEL, Block.DRILL, Block.GUN]

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
# ── Идентификатор блока для СЕЙВОВ ────────────────────────────────────────────
# Версия формата сохранений. Поднимать при несовместимом изменении структуры.
const SAVE_FORMAT := 2

# Имя блока для записи в файл. Пишем строку, а не число: числовой enum ломается от любой
# вставки блока в середину списка (все последующие значения сдвигаются и старый сейв читается
# как совсем другие блоки — колесо становится буром).
func block_key(bt: int) -> String:
	var names: Array = Block.keys()
	if bt >= 0 and bt < names.size():
		return str(names[bt])
	return "EMPTY"

# Чтение блока из сейва: строка (новый формат) ИЛИ число (старые файлы) — понимаем оба.
#
# СТАРЫЕ ИМЕНА. Раз в сейв пишется имя enum, то переименование блока осиротило бы все
# сохранения: имени в списке больше нет, block_from_key вернул бы EMPTY, и блок молча
# исчез бы из сохранённых машин и мира. Поэтому у переименованных блоков остаётся здесь
# запись «как назывался раньше → как называется теперь». Строку НЕ удалять: сейвы с этим
# именем существуют. Переименовал блок — допиши сюда.
const LEGACY_BLOCK_KEYS := {
	"INTAKE": "RECEIVER",       # приёмник, переименован после того, как сейвы уже писались
}

func block_from_key(v) -> int:
	if typeof(v) == TYPE_STRING or typeof(v) == TYPE_STRING_NAME:
		var key: String = str(v)
		key = String(LEGACY_BLOCK_KEYS.get(key, key))
		var idx: int = Block.keys().find(key)
		if idx >= 0:
			return int(Block.values()[idx])
		return int(Block.EMPTY)
	return int(v)

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
		return "already researched"
	var m: Dictionary = BLOCK_META.get(bt, {})
	if m.is_empty():
		return "no data"
	var parent := int(TECH_PARENT.get(bt, -1))
	if parent >= 0 and not researched.has(parent):
		return "need previous block: %s" % block_name(parent)
	if grade(m["f"]) < int(m["g"]):
		return "need grade %d" % int(m["g"])
	if research_points < int(m["rp"]):
		return "need RP: %d" % int(m["rp"])
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

# ── Сброс сейва (кнопка в НАСТРОЙКАХ гаража) ──────────────────────────────────
# Стираем ПРОГРЕСС и МИР; настройки устройства (settings.json, музыкальные предпочтения)
# остаются — это конфиг, а не сейв, и сбрасывать чувствительность камеры вместе с игрой
# незачем. Обнуляем и то, что уже в памяти: G — автолоад, он переживёт смену сцены и без
# этого записал бы старые деньги/исследования поверх только что удалённых файлов.
const WIPE_PATHS := [
	PROGRESS_PATH,
	BUILDS_PATH,
	"user://world_save.json",
	"user://world_save.bad.json",
	"user://vehicle_layout.json",
]

func wipe_save() -> void:
	_progress_dirty = false             # чтобы отложенный флеш не воскресил старый прогресс
	for p in WIPE_PATHS:
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(p)
	money = 500
	block_inventory = []
	saved_builds = {}
	faction_xp = {"start": 0}
	research_points = 0
	researched = START_RESEARCHED.duplicate()
	quests_done = []
	killed_kinds = []
	money_changed.emit()
	progress_changed.emit()

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

# Переименовать сборку. Возвращает false, если имя пустое или уже занято (порядок сборок
# сохраняем: Dictionary в GDScript помнит порядок вставки, поэтому пересобираем его целиком,
# иначе переименованная сборка прыгала бы в конец списка).
func rename_build(old_name: String, new_name: String) -> bool:
	new_name = new_name.strip_edges()
	if new_name.is_empty() or not saved_builds.has(old_name):
		return false
	if new_name == old_name:
		return true
	if saved_builds.has(new_name):
		return false
	var rebuilt: Dictionary = {}
	for k in saved_builds:
		if k == old_name:
			rebuilt[new_name] = saved_builds[k]
		else:
			rebuilt[k] = saved_builds[k]
	saved_builds = rebuilt
	_persist_builds()
	return true

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
		var t := block_from_key(e["block"])
		c[t] = c.get(t, 0) + 1
	return c

# ВАЖНО: значения enum ЗАФИКСИРОВАНЫ явно и менять их нельзя — они лежат в старых сейвах.
# Новые блоки добавлять ТОЛЬКО в конец, со следующим свободным номером.
# Сейвы пишутся по ИМЕНИ блока (block_key), поэтому даже перестановка enum их не сломает;
# числа остаются лишь для чтения старых файлов.
enum Block {
	EMPTY = 0,
	CABIN = 1,
	WHEEL = 2,
	BLOCK = 3,
	DRILL = 4,
	COLLECTOR = 5,
	RECEIVER = 6,
	BELT = 7,
	PROCESSOR = 8,
	SELLER = 9,
	LASER = 10,
	GUN = 11,
	BATTERY = 12,
	SOLAR = 13,
	GENERATOR = 14,
	REGEN = 15,
	SHIELD = 16,
	RADAR = 17,
	SUPPORT = 18,
	SMALL_WHEEL = 19,
	BIG_WHEEL = 20,
	TOP_WHEEL = 21,
	STAB_WHEEL = 22,
	BLOCK2 = 23,
	COAL_GEN = 24,
	ROCKET = 25,
	# Новые id дописываем В КОНЕЦ: сейв хранит блоки СТРОКОЙ (block_key), но вставка в
	# середину всё равно сдвинула бы значения и сломала всё, что сравнивает числа.
	BLOCK3 = 26,        # блок 3×1×1
	WEDGE = 27,         # клин 1³
	WEDGE2 = 28,        # клин 2×1×1
	ARMOR = 29,         # защитная пластина: то же место, втрое больше hp
	SMALL_DRILL = 30,   # малый бур: слабее и с меньшей зоной
	BELT_SPLIT = 31,    # развилка конвейера: один вход, три выхода
	BELT_CROSS = 32,    # перекрёсток: пропускает по очереди север↔юг и запад↔восток
	ROT_SUPPORT = 33,   # вращающаяся опора: якорь + разворот машины джойстиком
	STORAGE = 34,       # склад: один тип ресурса, до 20 штук
	AUTO_MINER = 35,    # авто-шахтёр: стационарный, ставится на жилу
	FABRICATOR = 36,    # фабрикатор 2³: два материала на входе, готовый блок на выходе
	SCRAPPER = 37,      # разбирает блоки обратно в слитки: половина рецепта (см. BLOCK_RECIPE)
	ARMOR2 = 38,        # защитная плита 2×1×1
	ARMOR4 = 39,        # защитная плита 2×1×2
	HALF_BLOCK = 40,    # половина блока: занимает ЦЕЛУЮ клетку, просто скошена — ровные края
	HALF_BLOCK2 = 41,   # две половины подряд, 2×1×1
	WIRELESS_CHARGER = 42,  # шлёт энергию в аккумулятор ДРУГОЙ машины игрока, свою игнорирует
	MORTAR = 43,        # 8 стволов, залп навесом, БЕЗ башни — бьёт по направлению корпуса
	POUND_CANNON = 44,  # тяжёлая пушка: бьёт сильно и редко
	SHOTGUN = 45,       # дробовик: дробь, ближний бой, два выстрела и перезарядка
	COMP_FACTORY = 46,  # варит КОМПОНЕНТЫ из слитков (см. COMP_RECIPE) и отдаёт их на ленту
}
@onready var cabin_scene: PackedScene = preload("res://blocks/scenes/cabin.tscn")
@onready var wheel_scene: PackedScene = preload("res://blocks/scenes/wheel.tscn")
@onready var block_scene: PackedScene = preload("res://blocks/scenes/block.tscn")
@onready var drill_scene: PackedScene = preload("res://blocks/scenes/drill.tscn")
@onready var collector_scene: PackedScene = preload("res://blocks/scenes/collector.tscn")
@onready var receiver_scene: PackedScene = preload("res://blocks/scenes/Receiver.tscn")
@onready var belt_scene: PackedScene = preload("res://blocks/scenes/belt.tscn")
@onready var processor_scene: PackedScene = preload("res://blocks/scenes/processor.tscn")
@onready var seller_scene: PackedScene = preload("res://blocks/scenes/seller.tscn")
@onready var laser_scene: PackedScene = preload("res://blocks/scenes/laser.tscn")
@onready var gun_scene: PackedScene = preload("res://blocks/scenes/gun.tscn")
@onready var battery_scene: PackedScene = preload("res://blocks/scenes/battery.tscn")
@onready var solar_scene: PackedScene = preload("res://blocks/scenes/solar.tscn")
@onready var generator_scene: PackedScene = preload("res://blocks/scenes/generator.tscn")
@onready var regen_scene: PackedScene = preload("res://blocks/scenes/regen.tscn")
@onready var shield_scene: PackedScene = preload("res://blocks/scenes/shield.tscn")
@onready var radar_scene: PackedScene = preload("res://blocks/scenes/radar.tscn")   # при установке даёт карту-радар
@onready var support_scene: PackedScene = preload("res://blocks/scenes/support.tscn")   # фикс-опора: без неё нет якоря
@onready var small_wheel_scene: PackedScene = preload("res://blocks/scenes/small_wheel.tscn")
@onready var big_wheel_scene: PackedScene = preload("res://blocks/scenes/big_wheel.tscn")
@onready var top_wheel_scene: PackedScene = preload("res://blocks/scenes/top_wheel.tscn")     # крепление сверху
@onready var stab_wheel_scene: PackedScene = preload("res://blocks/scenes/stab_wheel.tscn")   # стабилизирующее (90°)
@onready var block2_scene: PackedScene = preload("res://blocks/scenes/block2.tscn")           # 2×1×1
@onready var coal_gen_scene: PackedScene = preload("res://blocks/scenes/coal_gen.tscn")       # 2×1×2, уголь→энергия на якоре
@onready var rocket_scene: PackedScene = preload("res://blocks/scenes/rocket_launcher.tscn")
@onready var block3_scene: PackedScene = preload("res://blocks/scenes/block3.tscn")
@onready var wedge_scene: PackedScene = preload("res://blocks/scenes/wedge.tscn")
@onready var wedge2_scene: PackedScene = preload("res://blocks/scenes/wedge2.tscn")
@onready var armor_scene: PackedScene = preload("res://blocks/scenes/armor.tscn")
@onready var small_drill_scene: PackedScene = preload("res://blocks/scenes/small_drill.tscn")
@onready var belt_split_scene: PackedScene = preload("res://blocks/scenes/belt_split.tscn")
@onready var belt_cross_scene: PackedScene = preload("res://blocks/scenes/belt_cross.tscn")
@onready var rot_support_scene: PackedScene = preload("res://blocks/scenes/rot_support.tscn")
@onready var storage_scene: PackedScene = preload("res://blocks/scenes/storage.tscn")
@onready var auto_miner_scene: PackedScene = preload("res://blocks/scenes/auto_miner.tscn")
@onready var fabricator_scene: PackedScene = preload("res://blocks/scenes/fabricator.tscn")
@onready var comp_factory_scene: PackedScene = preload("res://blocks/scenes/comp_factory.tscn")
@onready var scrapper_scene: PackedScene = preload("res://blocks/scenes/scrapper.tscn")
@onready var armor2_scene: PackedScene = preload("res://blocks/scenes/armor2.tscn")
@onready var armor4_scene: PackedScene = preload("res://blocks/scenes/armor4.tscn")
@onready var half_block_scene: PackedScene = preload("res://blocks/scenes/half_block.tscn")
@onready var half_block2_scene: PackedScene = preload("res://blocks/scenes/half_block2.tscn")
@onready var wireless_charger_scene: PackedScene = preload("res://blocks/scenes/wireless_charger.tscn")
@onready var mortar_scene: PackedScene = preload("res://blocks/scenes/mortar.tscn")
@onready var pound_cannon_scene: PackedScene = preload("res://blocks/scenes/pound_cannon.tscn")
@onready var shotgun_scene: PackedScene = preload("res://blocks/scenes/shotgun.tscn")

# Категории блоков — общие для гаража (tech_ui SHOP-фильтр) и «шара» выбора блока
# в стройке (block_globe.gd). Ключ "other" не хранится явно — это всё, что не попало
# ни в одну из категорий ниже.
# Стационарные блоки (базы): при постановке на ЗЕМЛЮ рождают якорную структуру, на
# мобильную машину не ставятся (см. docs/STATIONARY_BLOCKS_DESIGN.md): продавец и
# авто-шахтёр — последний вдобавок требует жилы под собой.
const STATIONARY_BLOCKS := [Block.SELLER, Block.AUTO_MINER]
func is_stationary(bt: int) -> bool:
	return STATIONARY_BLOCKS.has(int(bt))

const BLOCK_CATEGORIES := {
	"attack":  [Block.GUN, Block.LASER, Block.ROCKET, Block.DRILL, Block.SMALL_DRILL,
		Block.MORTAR, Block.POUND_CANNON, Block.SHOTGUN],
	"blocks":  [Block.ARMOR2, Block.ARMOR4, Block.HALF_BLOCK, Block.HALF_BLOCK2,
		Block.BLOCK, Block.CABIN, Block.WHEEL, Block.BLOCK2, Block.BLOCK3,
		Block.WEDGE, Block.WEDGE2, Block.ARMOR,
		Block.SMALL_WHEEL, Block.BIG_WHEEL, Block.TOP_WHEEL, Block.STAB_WHEEL,
		Block.SUPPORT, Block.ROT_SUPPORT],
	"factory": [Block.COLLECTOR, Block.RECEIVER, Block.BELT, Block.BELT_SPLIT, Block.BELT_CROSS,
		Block.SCRAPPER,
		Block.STORAGE, Block.PROCESSOR, Block.SELLER, Block.GENERATOR, Block.COAL_GEN,
		Block.AUTO_MINER, Block.FABRICATOR, Block.COMP_FACTORY],
}

func get_scene(block: Block) -> PackedScene:
	match block:
		Block.CABIN:   return cabin_scene
		Block.WHEEL: return wheel_scene
		Block.BLOCK:   return block_scene
		Block.DRILL:   return drill_scene
		Block.COLLECTOR:   return collector_scene
		Block.RECEIVER: return receiver_scene
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
		Block.ROCKET: return rocket_scene
		Block.BLOCK3: return block3_scene
		Block.WEDGE: return wedge_scene
		Block.WEDGE2: return wedge2_scene
		Block.ARMOR: return armor_scene
		Block.SMALL_DRILL: return small_drill_scene
		Block.BELT_SPLIT: return belt_split_scene
		Block.BELT_CROSS: return belt_cross_scene
		Block.ROT_SUPPORT: return rot_support_scene
		Block.STORAGE: return storage_scene
		Block.AUTO_MINER: return auto_miner_scene
		Block.FABRICATOR: return fabricator_scene
		Block.COMP_FACTORY: return comp_factory_scene
		Block.SCRAPPER: return scrapper_scene
		Block.ARMOR2: return armor2_scene
		Block.ARMOR4: return armor4_scene
		Block.HALF_BLOCK: return half_block_scene
		Block.HALF_BLOCK2: return half_block2_scene
		Block.WIRELESS_CHARGER: return wireless_charger_scene
		Block.MORTAR: return mortar_scene
		Block.POUND_CANNON: return pound_cannon_scene
		Block.SHOTGUN: return shotgun_scene
	return null

# Любой вариант колеса (для авто-ориентации по грани и т.п.).
func is_wheel(bt: int) -> bool:
	return int(bt) in [Block.WHEEL, Block.SMALL_WHEEL, Block.BIG_WHEEL, Block.TOP_WHEEL, Block.STAB_WHEEL]
