extends Node

signal changed
## Последний шаг обучения закрыт — наставник по этому сигналу заканчивает вводную и
## запускает сюжет (спавнит первого врага).
signal tutorial_finished

## EVENT — разовые СОБЫТИЯ мира: не сюжет (не двигают историю и не ждут грейда) и не
## ежедневка (не считают штуки). Появляются сами, повторяются, живут своей веткой в журнале.
## Дописан В КОНЕЦ: значения enum лежат в сохранённых списках, вставка в середину сдвинула бы
## всё после себя.
enum Type { STORY, DAILY, TUTORIAL, EVENT }
# TUTORIAL — обучение: последовательное (по order), идёт ПЕРВЫМ (до сюжета), ведёт «за руку» —
# при активации шага Механик подсказывает, что сделать (поле hint). Награды символические.

var quests: Array[Dictionary] = []
var tracked_id: String = ""

func _ready() -> void:
	_seed_demo()
	var g = get_node_or_null("/root/G")
	if g:
		# Выполненные СЮЖЕТНЫЕ квесты персистятся (G.quests_done) — иначе награды
		# (XP/ДИ/$ сохраняются!) фармились бы перезапуском. Дейлики повторяемы намеренно.
		for q in quests:
			# Сюжет И обучение — одноразовые (персист в G.quests_done), иначе награды/шаги
			# фармились бы перезапуском. Дейлики повторяемы намеренно.
			# EVENT сюда НЕ попадает намеренно: событие должно случаться снова, как дейлик,
			# иначе оно бы отработало один раз за всю игру и исчезло.
			if (q["type"] == Type.STORY or q["type"] == Type.TUTORIAL) and g.quests_done.has(q["id"]):
				q["done"] = true
				q["progress"] = q["goal"]
		changed.emit()
		# Реплика Механика при новом грейде лицензии (см. G.grade_up / этап 1 прогрессии).
		g.grade_up.connect(_on_grade_up)
	_auto_track()

## ПРИВЕТСТВИЕ ГОВОРИТ МИР, А НЕ АВТОЛОАД. Раньше эти две строки стояли в _ready — а Q поднимается
## до первой сцены, то есть Механик здоровался с главным меню, где ни заданий, ни машины ещё нет
## (Dialogue такую реплику теперь и не покажет, см. dialogue.in_world). Зовёт Main, когда мир
## собран и слот уже выбран.
##
## Ведём за руку: обучение не пройдено — Механик подсказывает текущий шаг, пройдено — обычное
## приветствие.
func announce_start() -> void:
	if G.proving_ground:
		return                       # на полигоне некому и не о чем: заданий там нет (quest_arcs)
	if not _announce_tutorial():
		_say_lines([
			["Mechanic", tr("Still running. Directives are top right when you want them.")],
		])

# Демо-набор. event — какое игровое событие двигает прогресс (см. Q.report ниже);
# reward_money/xp/rp — награды при выполнении ($ / XP фракции / ДИ); req_grade — с какого
# грейда лицензии цепочка доступна (сюжет ПАУЗИТСЯ на квесте, чей грейд ещё не взят).
# ДИ по всем сюжеткам: 38+36+42+56+85 (+5 за первый килл) = 262 ≥ 260 на всё дерево —
# древо добивается сюжетом, дейлики лишь ускоряют. Порядок — order (грейд N = 10*N-10).
func _seed_demo() -> void:
	# ── ОБУЧЕНИЕ (идёт первым, ведёт за руку; hint — что нажать) ──────────────────
	# Пока на существующих событиях (build/ore/sell/kill); остальные шаги (камера, движение,
	# якорь, сбор, энерго, фабрика) добавятся, когда докинем их события — см. docs/QUESTS_DESIGN.
	# Шаги ведёт «рука с пальцем» (tutorial_director.gd): она показывает, куда нажать, и на
	# время шага не даёт нажать никуда больше. hint — реплика Механика при активации шага;
	# Шагов ровно пять, и все они про сборку: остальное игрок понимает сам (см. ниже).
	add_quest("tut_mode_build", "Boot: Assembly", "Enter assembly mode", Type.TUTORIAL, 1, 0, "mode_building", 0, 0, 0, 1,
			"You came online as a bare cabin. Everything starts in assembly — the button reads BUILD.")
	# Закрывается ЛЮБЫМ способом взять блок в руку (с земли, с машины, из инвентаря): игрок
	# считает, что «подобрал», и шаг обязан это засчитать.
	add_quest("tut_take_world", "Boot: Retrieval", "Hold a block", Type.TUTORIAL, 1, 1, "block_taken_world", 0, 0, 0, 1,
			"Your parts spilled on arrival and are lying around you. Double-tap one to hold it.")
	add_quest("tut_place_first", "Boot: Attachment", "Attach the block", Type.TUTORIAL, 1, 2, "block_placed", 0, 0, 0, 1,
			"Now double-tap yourself where it should attach. Any face will take it.")
	# Событие пустое: прогресс СТАВИТ наставник по числу блоков на машине. По событию
	# block_placed его накручивали бы циклом «поставил — снял — поставил».
	add_quest("tut_place_all", "Boot: Assembly", "Attach every part", Type.TUTORIAL, 8, 3, "", 0, 0, 0, 1,
			"Same for the rest. Wheels to the sides, drill facing out — you decide what you are.")
	# THE TUTORIAL IS ASSEMBLY ONLY, AND IT ENDS WHEN THE MACHINE IS BUILT (the player's call: a "Leave
	# assembly / Drive" step came after it and is gone; the scout is the first STORY quest). Journal, storage, shop, tree and sound steps were six taps on
	# buttons already in plain sight; what cannot be guessed is that blocks join by FACES, each with
	# its own, and go on with a double tap. Genuinely non-obvious mechanics are taught WHERE THEY
	# COME UP: the anchor by the panel quest, ports by the line quest, gestures by a Mechanic line at
	# the end (tutorial_director.FINAL_HINTS).
	# ── STORY ────────────────────────────────────────────────────────────────────
	# STORY ONLY. Counter quests ("place 5 blocks", "mine 10 ore") live in DAILIES at the bottom of
	# the file - they tell nothing, and they buried the real branches in the journal.
	# Money rewards are on the SHOP's scale, and shop prices come from recipes (G.shop_price): a
	# plain block is ~220$, a cabin ~1800$. "Earn N$" goals are untouched - ore still sells for the
	# same, so the work behind those numbers has not changed.
	# First story quest, straight after the tutorial: the mentor spawns a scout beside the player.
	add_quest("story_first_blood", "Noticed", "Destroy the scout", Type.STORY, 1, 0, "enemy_killed", 90, 25, 5)
	# ── СЮЖЕТ ПОСЛЕ РАЗВЕДЧИКА: ветка выбора ────────────────────────────────────
	# Три квеста, каждый в двух частях. Первый ведёт к остальным двум, и дальше игрок сам
	# решает, какой брать: они открываются одновременно и друг друга не ждут.
	add_quest("arc_power", "Draw Power", "", Type.STORY, 1, 5, "", 180, 40, 12)
	add_stages("arc_power", [
		{"desc": "Mount the panel on the support",
		 "event": "quest_arc_power_1", "goal": 1,
		 "hint": "A support is anchored out in the field with a solar panel lying beside it. Put the panel on top of the support: a panel only draws power on something that stands still."},
		{"desc": "Set the repair unit beside the support",
		 "event": "quest_arc_power_2", "goal": 1,
		 "hint": "A repair unit turned up at the same site. Set it next to the support — it mends whatever stands inside its radius, the panel included."},
	])
	add_quest("arc_radar", "Line of Sight", "", Type.STORY, 1, 6, "", 210, 45, 14)
	add_stages("arc_radar", [
		{"desc": "Take the scanner off the machine carrying it",
		 "event": "quest_arc_radar_1", "goal": 1,
		 "hint": "Something out there is driving around with a scanner bolted to its roof. Take it apart and the scanner is yours — it widens what you can see, which right now is almost nothing."},
	])
	add_quest("arc_battery", "Buried Charge", "", Type.STORY, 1, 7, "", 210, 45, 14)
	add_stages("arc_battery", [
		{"desc": "Drive out to the vein with the cell in it",
		 "event": "quest_arc_battery_1", "goal": 1,
		 "hint": "A power cell resolved inside an ore vein and the rock closed over it. You will see it sitting in the vein when you get there — drive out first."},
		{"desc": "Drill the vein dry, then attach the cell",
		 "event": "quest_arc_battery_2", "goal": 1,
		 "hint": "Nothing comes loose while there is ore left around it: drill the vein until it is empty, pick the cell up and attach it. A cell stores charge for whatever you bolt it to."},
	])
	# ── Продолжение: груз, производство, оборона ────────────────────────────────
	# Скелет взят у GSO-кампании TerraTech, но переложен на наши механики — см.
	# docs/STORY_ROADMAP.md. Главное отличие: у нас НЕТ торговых станций и не будет, поэтому
	# всё, что в оригинале крутилось вокруг станции (миссион-борд, продажа, хранилище),
	# заменено на СВОЮ БАЗУ: продаёт блок на машине, задания шлёт Система напрямую.
	add_quest("arc_salvage", "Salvage Run", "", Type.STORY, 1, 8, "", 240, 45, 14)
	add_stages("arc_salvage", [
		{"desc": "Reach the downed cargo",
		 "event": "quest_salvage_1", "goal": 1,
		 "hint": "A GSO drop came down short and something is already sitting on it. The System would like it back."},
		{"desc": "Clear the scavenger and take the collector",
		 "event": "quest_salvage_2", "goal": 1,
		 "hint": "Whatever is sitting on it is wearing the collector. Take the machine apart and pick the block out of the wreck."},
	])
	add_quest("arc_line", "Production Line", "", Type.STORY, 1, 9, "", 300, 55, 16)
	add_stages("arc_line", [
		{"desc": "Reach the salvage site and build the line",
		 "event": "quest_line_1", "goal": 1,
		 "hint": "A seller is already anchored there with one belt on it. The receiver and the rest of the belts are on the ground — link them up. Standing next to each other is not the same as connected."},
		{"desc": "Cut the processor into the line",
		 "event": "quest_line_2", "goal": 1,
		 "hint": "Ore sells for scraps; metal does not. The processor takes on the lower left of its right face and gives out on the lower right — so it drops into a belt run along the side."},
	])
	# SOLVENT IS TEN THINGS SOLD, NOT A SUM (the player's call): any material the seller takes counts -
	# raw ore as well as an ingot - so the quest asks for a running line, not for a price. The Mechanic
	# says what to do (quest_arcs._solvent).
	add_quest("arc_solvent", "Solvent", "Sell 10 resources through the line", Type.STORY, 10, 10, "item_sold", 400, 60, 18)
	add_quest("arc_hold", "Hold the Line", "", Type.STORY, 1, 11, "", 450, 70, 20)
	add_stages("arc_hold", [
		{"desc": "They are coming for the line",
		 "event": "quest_hold_1", "goal": 1,
		 "hint": "Something logged your production. They are coming for the machine that makes it, not for you."},
		{"desc": "Destroy the raid",
		 "event": "quest_hold_2", "goal": 1,
		 "hint": "Your base cannot drive away — this one you finish standing."},
	])

	requires("arc_power", ["story_first_blood"])
	requires("arc_radar", ["arc_power"])      # развилка: оба открываются вместе,
	requires("arc_battery", ["arc_power"])    # и порядок между ними выбирает игрок
	# Дальше ветки сходятся: груз даёт коллектор, без него цепочку не построить, а без
	# цепочки нечего оборонять. Порядок здесь ЖЁСТКИЙ и по делу, а не по привычке.
	requires("arc_salvage", ["arc_radar", "arc_battery"])
	# ── ВЫШКИ ПОД ЩИТОМ: Charlie Watchtower и SAM Site Ridge ────────────────────
	# Both from the GSO campaign plan (docs/STORY_ROADMAP.md, #11 and #13), and they climb: the
	# WATCHTOWER stands alone under a dome on its own batteries (the player: the stations made it too
	# hard), SAM is the same dome FED by four charging towers round it - the lesson "kill what pays
	# for the shield" moved to the second quest, where the player has a grade more to do it with.
	#
	# Порядок ЖЁСТКИЙ и по делу: сюда игрок приходит после «Hold the Line», где впервые дрался
	# за неподвижную постройку. Вышка — то же самое наоборот: теперь неподвижную постройку надо
	# СНЕСТИ, и лобовой размен с ней не работает.
	add_quest("arc_tower", "Charlie Watchtower", "", Type.STORY, 1, 12, "", 500, 80, 22)
	add_stages("arc_tower", [
		{"desc": "Reach the watchtower",
		 "event": "quest_tower_1", "goal": 1,
		 "hint": "Something is holding a ridge out there under a shield. The System wants the ridge."},
		{"desc": "Drain its shield, then bring it down",
		 "event": "quest_tower_2", "goal": 1,
		 "hint": "Nothing feeds this dome: it runs on the tower's own batteries. Keep firing at it until it runs dry, then the tower is open."},
	])
	# SAM ОТКРЫВАЕТСЯ НА 5 ГРЕЙДЕ, и раньше его в журнале нет. Watchtower и SAM — одна задача
	# дважды, и подряд они читаются как повтор; лицензия разводит их по времени и заодно
	# гарантирует, что во второй раз у игрока есть чем ломать ракетную точку.
	add_quest("arc_sam", "SAM Site Ridge", "", Type.STORY, 1, 13, "", 700, 100, 26, 5)
	add_stages("arc_sam", [
		{"desc": "Reach the missile site",
		 "event": "quest_sam_1", "goal": 1,
		 "hint": "Rocket batteries under a dome, and this time charging towers round it keep the dome up."},
		{"desc": "Take the site apart",
		 "event": "quest_sam_2", "goal": 1,
		 "hint": "The dome is not its own. Charging towers stand around it feeding the tower power — kill those first and the shield dies on its own."},
	])

	# ── MARLIT'S CHAMPION: THE SECOND FACTION'S LICENCE ─────────────────────────
	# The player's design: Marlit sends a machine of the fourth step built of its own blocks; beat it
	# and Marlit's licence is yours (G.FACTION_LICENCE, granted in _on_completed). The id stays
	# "arc_yellow" - saves and the licence table key on it.
	add_quest("arc_yellow", "Marlit's Champion", "", Type.STORY, 1, 14, "", 500, 80, 22)
	add_stages("arc_yellow", [
		{"desc": "Destroy the Marlit champion",
		 "event": "quest_yellow_1", "goal": 1,
		 "hint": "Marlit only deals with those who can beat them. Their champion is out in the field - heavy hull, heavy wheels, guns that hit harder than ours."},
	])
	requires("arc_yellow", ["arc_hold"])

	# ── AERO'S LICENCE: RACE AGAINST TIME (TerraTech's Venture licence, GSO grade 3) ───────────
	# Aero deals with the fast: a course of gates out in the field, start to finish in under a minute
	# (quest_arcs._race_*, race_track.gd). The course stays in the world after it, a track to beat.
	add_quest("arc_aero", "Race Against Time", "", Type.STORY, 1, 15, "", 450, 70, 20, 3)
	add_stages("arc_aero", [
		{"desc": "Reach Aero's course",
		 "event": "quest_race_1", "goal": 1,
		 "hint": "Aero does not care what your machine can carry. It cares how fast it gets there."},
		{"desc": "Run the course in under a minute",
		 "event": "quest_race_2", "goal": 1,
		 "hint": "Through the start gate and the clock runs; every gate in order. Too slow - the start gate again."},
	])
	requires("arc_aero", ["arc_salvage"])

	# ── STRYX'S LICENCE: BIRD OF PREY (TerraTech's Hawkeye licence, GSO grade 4) ───────────────
	# A crashed Stryx capsule, and three "Cleanup Crew" machines that drop in once the player is
	# near it (quest_arcs._bop_*). Story, so it is guaranteed - the original drew it from a board.
	add_quest("arc_stryx", "Bird of Prey", "", Type.STORY, 1, 16, "", 650, 100, 26, 4)
	add_stages("arc_stryx", [
		{"desc": "Check the heat signature",
		 "event": "quest_bop_1", "goal": 1,
		 "hint": "GSO picked up a heat signature where nothing should be burning. Go and look."},
		{"desc": "Destroy the Cleanup Crew",
		 "event": "quest_bop_2", "goal": 1,
		 "hint": "Whoever lost that capsule does not want it found. Three of them - all three go."},
	])
	requires("arc_stryx", ["arc_hold"])

	requires("arc_line", ["arc_salvage"])
	requires("arc_solvent", ["arc_line"])
	requires("arc_hold", ["arc_solvent"])
	requires("arc_tower", ["arc_hold"])
	requires("arc_sam", ["arc_tower"])

	# EVENTS: the original's board types. There is no board - the System announces them, and they
	# repeat after a cooldown (quest_arcs, "REPEATABLE EVENTS"). One rule for all: drive 500 m away
	# from the target and the event is dropped. Crossfire and Hold Position were taken out (the
	# player's call).
	add_quest("event_gang", "Tech Gang", "", Type.EVENT, 1, 0, "", 320, 40, 8, 2)
	add_stages("event_gang", [
		{"desc": "Reach the reported camp",
		 "event": "quest_gang_1", "goal": 1,
		 "hint": "Three unmarked units parked together. They are not going anywhere on their own."},
		{"desc": "Break the gang",
		 "event": "quest_gang_2", "goal": 1,
		 "hint": "They stand until someone shoots. That someone is you."},
	])
	add_quest("event_supply", "Supply Drop", "", Type.EVENT, 1, 0, "", 200, 25, 5, 1)
	add_stages("event_supply", [
		{"desc": "Reach the drop",
		 "event": "quest_supply_1", "goal": 1,
		 "hint": "Something came down intact. Whether anyone else got the signal is the interesting part."},
		{"desc": "Stay by the drop until it opens",
		 "event": "quest_supply_2", "goal": 1,
		 "hint": "Keep within ten metres and it comes apart into whatever it holds. If it was bait, it stays shut while the bait's owners live."},
	])
	add_quest("event_defend", "Cover the Convoy", "", Type.EVENT, 1, 0, "", 300, 35, 7, 2)
	add_stages("event_defend", [
		{"desc": "Reach the friendly unit",
		 "event": "quest_defend_1", "goal": 1,
		 "hint": "One of ours is pinned down and will not hold long."},
		{"desc": "Keep it alive for two minutes",
		 "event": "quest_defend_2", "goal": 1,
		 "hint": "Stay close and keep it standing. Hold for two minutes and it joins you."},
	])
	add_quest("event_camp", "Take the Staging Point", "", Type.EVENT, 1, 0, "", 420, 55, 12, 4)
	add_stages("event_camp", [
		{"desc": "Reach the staging point",
		 "event": "quest_camp_1", "goal": 1,
		 "hint": "Not a patrol — a place they come back to. A turret post and its guard hold it."},
		{"desc": "Break the guard and disarm the post",
		 "event": "quest_camp_2", "goal": 1,
		 "hint": "Shoot every gun off the post, but keep its core standing: a wreck cannot be taken."},
		{"desc": "Hold the point",
		 "event": "quest_camp_3", "goal": 1,
		 "hint": "Stay by the post a few seconds and it becomes one of your bases."},
	])

	# MARLIT'S EVENTS: the same four the original's GeoCorp board repeats (the player's list) -
	# Supply Drop, Tech Gang, Defend Friendly Tech - under Marlit's flag (waves were taken out). The arcs
	# are Falsus's own (quest_arcs takes the key from the stage); the faction sends Marlit machines
	# (quest_arcs._faction_preset), fills the drop with Marlit blocks and takes the XP. They open with
	# the licence and climb Marlit's grades in the same order as Falsus's.
	_marlit_event("event_msupply", "Supply Drop", 200, 25, 5, 1, "event_supply", "msupply")
	_marlit_event("event_mgang", "Tech Gang", 320, 40, 8, 1, "event_gang", "mgang")
	_marlit_event("event_mdefend", "Cover the Convoy", 300, 35, 7, 2, "event_defend", "mdefend")

	# ── MARLIT'S STORY: THE HARVESTER LINE (the player's design, after GeoCorp's own) ───────────
	# Marlit trades in what the ground gives, so its story is the work itself: felling, collecting
	# ore metal by metal, refining and selling. Counters, against the rule that counters are
	# dailies - here the count IS the story, and it is the player's call. What counts:
	#   tree_felled            a tree's last wood out (resource_node.hurt)
	#   ore_collected[_<m>]    an ore item's FIRST pick-up - collector, receiver or hand, so the auto
	#                          miner's ore counts when it is taken and a drilled ore once
	#                          (resource.harvest)
	#   processed              a product out of the processor
	#   item_sold              anything the seller takes
	# EVERY LINE OPENS WITH MARLIT'S LICENCE, EACH LINE A CHAIN (the player's call, after GeoCorp's
	# Harvester board): Novice, Mineral and Master all stand on the board at once, but each shows only
	# its next step - Novice I > II > III > IV, the metals Ferrite > Cuprite > Silicate > Titanite,
	# Master I > II > III > IV (`requires`). All twelve at once read as a wall of counters.
	_marlit_story("mh_novice1", "Novice Harvester I", "Fell 10 trees", 10, 20, "tree_felled", 150, 30, 6, 1,
			"Marlit pays for work, not talk. Start with timber: drill a tree until it comes down.")
	_marlit_story("mh_novice2", "Novice Harvester II", "Collect 20 ore", 20, 21, "ore_collected", 180, 35, 7, 1,
			"Ore counts once it is picked up - by a collector, a receiver or your own hand. Drilled and left lying, it is just rock.")
	_marlit_story("mh_novice3", "Novice Harvester III", "Fell 25 trees", 25, 22, "tree_felled", 220, 45, 8, 1,
			"More timber. A felled tree does not grow back where it stood - look a little further out.")
	_marlit_story("mh_novice4", "Novice Harvester IV", "Collect 50 ore", 50, 23, "ore_collected", 280, 55, 10, 1,
			"An auto miner on an anchored base digs while you are away; what it digs counts when a receiver takes it.")
	# One per metal: which metal a deposit holds depends on its biome (resource_nodes._metal_for), so
	# the player takes the one nearest.
	var minerals := [["Ferrite", 20, 1, 300, 60, 10], ["Cuprite", 30, 1, 360, 70, 12],
			["Silicate", 40, 1, 440, 85, 14], ["Titanite", 50, 1, 520, 100, 16]]
	for i in minerals.size():
		var m: Array = minerals[i]
		var mid := "mh_mineral%d" % i
		_marlit_story(mid, "Mineral Harvester: %s" % m[0], "Collect %d %s ore" % [m[1], m[0]], m[1],
				24 + i, "ore_collected_%d" % i, m[3], m[4], m[5], m[2],
				"Only %s counts here. Every region holds its own metal - find where it grows." % m[0])
	_marlit_story("mh_master1", "Master Harvester I", "Fell 100 trees", 100, 28, "tree_felled", 600, 110, 18, 1,
			"A hundred trees. Bring a drill that bites and a collector that does not fill up.")
	_marlit_story("mh_master2", "Master Harvester II", "Collect 200 ore", 200, 29, "ore_collected", 750, 130, 20, 1,
			"Two hundred ore. This is what bases are for: park on a vein and let the line do it.")
	_marlit_story("mh_master3", "Master Harvester III", "Refine 300 items", 300, 30, "processed", 900, 150, 24, 1,
			"Raw ore is worth little. Run it through a processor - every product out of it counts.")
	_marlit_story("mh_master4", "Master Harvester IV", "Sell 500 items", 500, 31, "item_sold", 1200, 200, 30, 1,
			"Marlit's last test is the market: five hundred items through a seller.")
	for line in [["mh_novice1", "mh_novice2", "mh_novice3", "mh_novice4"],
			["mh_mineral0", "mh_mineral1", "mh_mineral2", "mh_mineral3"],
			["mh_master1", "mh_master2", "mh_master3", "mh_master4"]]:
		for k in range(1, line.size()):
			requires(String(line[k]), [line[k - 1]])

	# ── THE ALMIGHTY CUBE: MARLIT'S COMBAT LINE ────────────────────────────────────
	# Three cubes of Marlit modules WITH NO GUNS (blocks.MARLIT_CUBE_*) - a target, not a fight - each its own
	# point; ALL THREE OPEN TOGETHER AT MARLIT'S GRADE 3 (the player's call), not one after another.
	# The branch is the shielded towers' (quest_arcs CUBE_*): reach it, then bring it down.
	for i in 3:
		var cid := "mc_cube%d" % (i + 1)
		add_quest(cid, "The Almighty Cube %s" % ["I", "II", "III"][i], "", Type.STORY, 1, 32 + i, "",
				[600, 800, 1000][i], [120, 150, 190][i], [22, 26, 30][i], 3)
		add_stages(cid, [
			{"desc": "Reach the cube",
			 "event": "quest_cube%d_1" % (i + 1), "goal": 1,
			 "hint": ["Marlit has parked a cube of its own blocks out in the field and wants to see it come apart.",
				"A bigger cube, and this one mends itself: there is a repair unit and a battery inside.",
				"The last cube: a solar array on its roof keeps the repairs going. Bring heavy guns."][i]},
			{"desc": "Break the cube",
			 "event": "quest_cube%d_2" % (i + 1), "goal": 1,
			 "hint": "It does not shoot back. From the first hit you have 20 seconds to bring it down, or it stands up whole."},
		])
		_find(cid)["faction"] = "marlit"

	# ── AERO'S STORY (TerraTech's Venture campaign, the player's call: our names, their meaning) ──
	# Plateau Run - a timed course that climbs; Stranded Racer (Mine Island Rescue) - an Aero machine
	# stuck among hostiles, clear them off it; Loose Ground (A Slippery Slope) - a timed course down.
	# One after another, on Aero's grades (quest_arcs COURSES, `_strand_*`).
	_faction_story("aero", "aero_plateau", "Plateau Run", 40, 350, 70, 14, 1, [
		{"desc": "Reach the foot of the plateau", "event": "quest_plateau_1", "goal": 1,
		 "hint": "Aero wants to see your machine climb. The course starts at the bottom."},
		{"desc": "Run the climb inside the time", "event": "quest_plateau_2", "goal": 1,
		 "hint": "Every gate in order, up to the top. Too slow - back through the start gate."}])
	_faction_story("aero", "aero_strand", "Stranded Racer", 41, 450, 85, 16, 2, [
		{"desc": "Reach the stranded racer", "event": "quest_astrand_1", "goal": 1,
		 "hint": "One of Aero's machines lost its wheels out there, and it is not alone."},
		{"desc": "Clear the hostiles off it", "event": "quest_astrand_2", "goal": 1,
		 "hint": "It cannot move and it cannot hold long. Everything hostile round it goes."}])
	_faction_story("aero", "aero_descent", "Loose Ground", 42, 550, 100, 18, 3, [
		{"desc": "Reach the top of the run", "event": "quest_descent_1", "goal": 1,
		 "hint": "Downhill is fast and loose. Aero wants it fast."},
		{"desc": "Run it down inside the time", "event": "quest_descent_2", "goal": 1,
		 "hint": "Every gate in order, down to the bottom - on your wheels, not your roof."}])
	requires("aero_strand", ["aero_plateau"])
	requires("aero_descent", ["aero_strand"])

	# ── ROCK CREEK BRIDGE: Marlit's story (TerraTech's GeoCorp mission) ─────────────────────────
	# A toll keeper on the crossing: pay or fight; winning pays in Stryx blocks early (quest_arcs).
	_faction_story("marlit", "mrock", "Rock Creek Bridge", 36, 700, 120, 24, 2, [
		{"desc": "Reach the crossing", "event": "quest_rock_1", "goal": 1,
		 "hint": "Someone has taken the crossing at Rock Creek and charges for it."},
		{"desc": "Pay the toll or break through", "event": "quest_rock_2", "goal": 1,
		 "hint": "Pay and drive on, or cross the line and fight. Its hardware is better than ours."}])

	# ── STRYX'S STORY (TerraTech's Hawkeye campaign): Quiet Job (Wet Work, renamed), then
	# Crowntop Hill Fort and its Spider King (quest_arcs `_quiet_*`, CROWN).
	_faction_story("stryx", "stryx_quiet", "Quiet Job", 50, 600, 110, 22, 1, [
		{"desc": "Find the courier", "event": "quest_quiet_1", "goal": 1,
		 "hint": "A courier waits out there with an escort. It will run the moment it sees you."},
		{"desc": "Stop the courier before it reaches its drop", "event": "quest_quiet_2", "goal": 1,
		 "hint": "The escort does not matter. The courier must not arrive."}])
	_faction_story("stryx", "stryx_crown", "Crowntop Hill Fort", 51, 900, 160, 30, 2, [
		{"desc": "Reach Crowntop Hill", "event": "quest_crown_1", "goal": 1,
		 "hint": "The Spider King holds the hill: an anchored fort with rockets, lasers and a dome."},
		{"desc": "Bring down the Spider King", "event": "quest_crown_2", "goal": 1,
		 "hint": "Its dome lives on panels and batteries. At night the panels give nothing."}])
	requires("stryx_crown", ["stryx_quiet"])

	# ── AERO'S EVENTS: races and a chase (TerraTech's Venture board) ───────────────────────────
	_faction_event("aero", "event_acourse", "Checkpoint Race", 260, 40, 8, 1, "acourse",
			"Reach the start gate", "Run the course inside the time",
			"A course of gates. Through each in order, against the clock.")
	_faction_event("aero", "event_adrag", "Drag Strip", 220, 35, 7, 1, "adrag",
			"Reach the strip", "Cover the strip inside the time",
			"Two gates and a straight line between them. Nothing to it but speed.")
	_faction_event("aero", "event_aslalom", "Slalom", 280, 45, 9, 2, "aslalom",
			"Reach the start gate", "Weave through every gate inside the time",
			"Every gate swings to the other side. Lose speed in the turns and you lose the run.")
	add_quest("event_achase", "Pursuit", "", Type.EVENT, 1, 0, "", 320, 50, 10, 2)
	add_stages("event_achase", [
		{"desc": "Find the runner", "event": "quest_achase_1", "goal": 1,
		 "hint": "Something fast is parked out there. It will not wait for you once it sees you."},
		{"desc": "Catch it within a minute", "event": "quest_achase_2", "goal": 1,
		 "hint": "It runs from the moment it sees you. Bring it down before it is gone."}])
	_find("event_achase")["faction"] = "aero"

	add_quest("daily_ore",   "Cycle: Ore",       "Mine 20 ore",        Type.DAILY, 20,  0, "ore_mined",    75, 15, 3)
	add_quest("daily_kill",  "Cycle: Sweep",     "Destroy 3 vehicles", Type.DAILY, 3,   0, "enemy_killed", 120, 20, 5)

## A story quest of another faction, with its stages: its grade, its XP, its emblem.
func _faction_story(f: String, id: String, title: String, order: int, money: int, xp: int, rp: int,
		grade: int, stages: Array) -> void:
	add_quest(id, title, "", Type.STORY, 1, order, "", money, xp, rp, grade)
	add_stages(id, stages)
	_find(id)["faction"] = f

## A two-stage event of another faction: reach, then do (the course events).
func _faction_event(f: String, id: String, title: String, money: int, xp: int, rp: int, grade: int,
		key: String, reach: String, run: String, hint: String) -> void:
	add_quest(id, title, "", Type.EVENT, 1, 0, "", money, xp, rp, grade)
	add_stages(id, [
		{"desc": reach, "event": "quest_%s_1" % key, "goal": 1, "hint": hint},
		{"desc": run, "event": "quest_%s_2" % key, "goal": 1,
		 "hint": "Through the start gate and the clock runs. Too slow - the start gate again."}])
	_find(id)["faction"] = f

## A Marlit story quest: an ordinary STORY quest under Marlit's flag (its grade, its XP, its emblem).
func _marlit_story(id: String, title: String, desc: String, goal: int, order: int, event: String,
		money: int, xp: int, rp: int, grade: int, hint: String) -> void:
	add_quest(id, title, desc, Type.STORY, goal, order, event, money, xp, rp, grade, hint)
	_find(id)["faction"] = "marlit"

## A Marlit copy of a Falsus event: its stages with the stage events renamed to its own key.
func _marlit_event(id: String, title: String, money: int, xp: int, rp: int, grade: int,
		like: String, key: String) -> void:
	add_quest(id, title, "", Type.EVENT, 1, 0, "", money, xp, rp, grade)
	var src := _find(like)
	var stages: Array = []
	for st in src.get("stages", []):
		var c: Dictionary = (st as Dictionary).duplicate()
		var ev := String(c["event"])
		c["event"] = "quest_" + key + "_" + ev.get_slice("_", ev.get_slice_count("_") - 1)
		stages.append(c)
	add_stages(id, stages)
	_find(id)["faction"] = "marlit"

# ── Данные ────────────────────────────────────────────────────────────────────
func add_quest(id: String, title: String, desc: String, type: int, goal: int,
		order: int = 0, event: String = "", reward_money: int = 0,
		reward_xp: int = 0, reward_rp: int = 0, req_grade: int = 1, hint: String = "",
		reward_block: int = 0, reward_block_count: int = 1) -> void:
	quests.append({
		"id": id, "title": title, "desc": desc, "type": type,
		"goal": maxi(goal, 1), "progress": 0, "done": false, "order": order,
		"event": event, "reward_money": reward_money,
		"reward_xp": reward_xp, "reward_rp": reward_rp, "req_grade": req_grade,
		"hint": hint,        # подсказка Механика (обучение) — говорится при активации шага
		"reward_block": reward_block, "reward_block_count": reward_block_count,  # награда БЛОКАМИ (кружат→в мир)
		"stages": [], "stage": 0,   # см. add_stages
		"requires": [],             # см. requires (пусто = доступен сразу)
		"skipped": false,           # закрыт «вхолостую», без награды (см. skip_quest)
	})
	changed.emit()

## СТАДИИ квеста: «сначала доехать, потом подобрать блок». Один квест, который игрок берёт
## один раз, и который сам ведёт по шагам — а не три отдельных задания в списке.
##
## Каждая стадия — {"desc", "event", "goal", "hint"}. Прогресс и цель квеста ВСЕГДА равны
## прогрессу и цели текущей стадии: так весь остальной код (трекер, проценты, report)
## работает как раньше и ничего не знает про стадии.
func add_stages(id: String, stages: Array) -> void:
	var q := _find(id)
	if q.is_empty() or stages.is_empty():
		return
	q["stages"] = stages
	q["stage"] = 0
	_apply_stage(q)

## Что должно быть выполнено, чтобы квест появился. Пусто — доступен сразу. Заменяет
## прежний строгий порядок по order: тот пускал сюжет ровно одной цепочкой, а нам нужна
## развилка «после первого квеста открылись сразу второй и третий, бери любой».
func requires(id: String, ids: Array) -> void:
	var q := _find(id)
	if not q.is_empty():
		q["requires"] = ids

# Переносим в квест поля ТЕКУЩЕЙ стадии. Прогресс с нуля: у новой стадии своё условие.
func _apply_stage(q: Dictionary) -> void:
	var st: Array = q.get("stages", [])
	var i: int = int(q.get("stage", 0))
	if i < 0 or i >= st.size():
		return
	var s: Dictionary = st[i]
	q["desc"] = String(s.get("desc", q.get("desc", "")))
	q["event"] = String(s.get("event", ""))
	q["goal"] = maxi(int(s.get("goal", 1)), 1)
	q["hint"] = String(s.get("hint", ""))
	q["progress"] = 0

## Сколько стадий и на какой мы сейчас — для UI («часть 2 из 2»).
func stage_info(q: Dictionary) -> Vector2i:
	var n: int = (q.get("stages", []) as Array).size()
	return Vector2i(int(q.get("stage", 0)) + 1, n) if n > 1 else Vector2i.ZERO

## Доступен ли квест: все его требования закрыты (выполнены ИЛИ пропущены — пропуск
## обязан открывать продолжение, иначе одна недоступная ветка вешает всё дерево).
func unlocked(q: Dictionary) -> bool:
	for r in q.get("requires", []):
		var dep := _find(String(r))
		if dep.is_empty() or not dep["done"]:
			return false
	return true

## Закрыть квест ВХОЛОСТУЮ: он считается выполненным (дерево идёт дальше), но награды нет.
## Нужен там, где цель может исчезнуть не по вине игрока — например, радар вора уничтожен
## в бою, и отбирать уже нечего. Делать цель неуязвимой было бы хуже: неуязвимость пришлось
## бы ставить и снимать по всем веткам завершения, а результат тот же.
func skip_quest(id: String) -> void:
	var q := _find(id)
	if q.is_empty() or q["done"]:
		return
	q["skipped"] = true
	q["progress"] = q["goal"]
	q["done"] = true
	_persist_done(q)
	_say("System", tr("Directive '%s' is no longer resolvable. Dropped.") % tr(String(q["title"])))
	changed.emit()
	_auto_track()

# Взят ли грейд, нужный квесту (гейт цепочек по лицензии).
func _grade_ok(q: Dictionary) -> bool:
	var g = get_node_or_null("/root/G")
	if g == null:
		return true
	# ANOTHER FACTION'S QUEST WAITS FOR ITS LICENCE, and its grade is that faction's grade.
	if not g.faction_open(faction_of(q)):
		return false
	var need := int(q.get("req_grade", 1))
	return need <= 1 or g.grade(faction_of(q)) >= need

# Игра сообщает о событии — двигаем ВСЕ активные задания с таким event (и сюжет, и дейлики):
#   Q.report("ore_mined", 1) / Q.report("enemy_killed", 1) / Q.report("money_earned", 5)
# Q — общая шина событий, поэтому здесь же событие конвертируется в XP/ДИ фракции (G).
func report(event: String, amount: int = 1) -> void:
	if event == "":
		return
	var g = get_node_or_null("/root/G")
	if g:
		g.on_game_event(event, amount)
	for q in active_quests():
		if q.get("event", "") == event and not q["done"]:
			add_progress(q["id"], amount)

## Пропустить обучение целиком (кнопка SKIP). Шаги закрываем МОЛЧА: наград у них нет, а
## одиннадцать подряд «задание выполнено» — это шум. Персистим как обычно, иначе после
## перезапуска обучение началось бы заново.
## Нужно не только нетерпеливым: если шаг стал непроходимым (например, сейв старый и
## стартовые блоки в мир уже не выдадутся), это единственный выход.
## Идёт ли ещё обучение. Спавнер врагов держит мир пустым, пока игрок учится: разбираться
## с рейдером в середине вводной незачем, а первого врага сюжет приводит сам.
func tutorial_active() -> bool:
	return not _current_tutorial().is_empty()

func skip_tutorial() -> void:
	var g = get_node_or_null("/root/G")
	var any := false
	for q in quests:
		if int(q["type"]) != Type.TUTORIAL or q["done"]:
			continue
		q["progress"] = q["goal"]
		q["done"] = true
		any = true
		if g != null and not g.quests_done.has(q["id"]):
			g.quests_done.append(q["id"])
	if not any:
		return
	if g != null:
		g.mark_progress_dirty()
	_say("Mechanic", tr("Skipping the walkthrough. It is all in the menus when you need it."))
	changed.emit()
	_auto_track()
	tutorial_finished.emit()

# Сброс сейва (кнопка в настройках): G уже вычистил quests_done, а здесь в памяти лежат
# те же квесты с done/progress. Без этого после перезапуска сцены обучение считалось бы
# пройденным — автолоад Q смену сцены переживает.
func reset_all() -> void:
	for q in quests:
		q["progress"] = 0
		q["done"] = false
		_rewind_stage(q)
	tracked_id = ""
	changed.emit()

## Пересобрать состояние под ТЕКУЩИЙ прогресс (G.use_slot зовёт это после смены слота). Q —
## автолоад: он читает quests_done один раз в _ready, и без этого сброшенный или чужой слот
## открывался с закрытым сюжетом и пройденным обучением.
func reload_from_progress() -> void:
	# Придержки — состояние СЕАНСА (см. hold_quest): смена слота или загрузка означает, что
	# ждать больше некого, и придержанный квест иначе не открылся бы никогда.
	_held.clear()
	_roster.clear()                    # the drawn events belong to the session, like _held
	# ВЫДАННОЕ РУКАМИ ЧИСТИМ ЗДЕСЬ ЖЕ, И ЭТО ВАЖНЕЕ, ЧЕМ КАЖЕТСЯ. `Q` — автолоад, он переживает
	# смену сцены: выдал себе ветку на полигоне, вышел в меню, начал настоящую игру — и она
	# продолжала бы идти мимо требований и грейда уже в сейве. В настоящую игру заходят только
	# через выбор слота (G.use_slot), то есть через эту функцию, — здесь дверь и есть.
	_forced.clear()
	var g = get_node_or_null("/root/G")
	for q in quests:
		q["progress"] = 0
		q["done"] = false
		_rewind_stage(q)
		if g == null:
			continue
		if (q["type"] == Type.STORY or q["type"] == Type.TUTORIAL) and g.quests_done.has(q["id"]):
			q["done"] = true
			q["progress"] = q["goal"]
	tracked_id = ""
	changed.emit()
	_auto_track()
	_seed_story_known()

## Квест по id — ПУБЛИЧНО. Нужен тем, кто квест не создаёт, а ВЕДЁТ: контракты (contracts.gd)
## переписывают один и тот же слот вместо того, чтобы плодить задания. Лезть за этим в
## приватный _find значит однажды переименовать его и молча сломать чужой код.
func find_quest(id: String) -> Dictionary:
	return _find(id)

func _find(id: String) -> Dictionary:
	for q in quests:
		if q["id"] == id:
			return q
	return {}

func add_progress(id: String, amount: int = 1) -> void:
	set_progress(id, _find(id).get("progress", 0) + amount)

func set_progress(id: String, value: int) -> void:
	var q := _find(id)
	if q.is_empty() or q["done"]:
		return
	q["progress"] = clampi(value, 0, q["goal"])
	if q["progress"] < q["goal"]:
		changed.emit()
		return
	# Стадия закрыта. Есть следующая — переходим к ней, квест остаётся активным; это и
	# есть «взял один квест и идёшь по частям». Стадий больше нет — закрыт весь квест.
	var st: Array = q.get("stages", [])
	var i: int = int(q.get("stage", 0))
	if i + 1 < st.size():
		q["stage"] = i + 1
		_apply_stage(q)
		changed.emit()
		var hint: String = String(q.get("hint", ""))
		if hint != "":
			_say("Mechanic", tr(hint))
		return
	q["done"] = true
	changed.emit()
	_on_completed(q)

## Открыть квест ЗАНОВО (события повторяются). Прогресс и стадию откатываем в начало — иначе
## перезаряженное событие сразу оказалось бы на своей второй части.
## STAGES ARE MEMORY ONLY (nothing saves them), so whatever re-reads progress starts every quest at
## its first stage. Without this a slot switch or a reset kept the stage the last session ended
## on: a quest half done in one slot opened on its second stage in another, before the first
## stage's task was ever done.
func _rewind_stage(q: Dictionary) -> void:
	q.erase("reward_mult")
	if q.has("stages") and not (q["stages"] as Array).is_empty():
		q["stage"] = 0
		_apply_stage(q)

func reset_quest(id: String) -> void:
	var q := _find(id)
	if q.is_empty():
		return
	q["done"] = false
	q["progress"] = 0
	q.erase("reward_mult")
	if q.has("stages") and not (q["stages"] as Array).is_empty():
		q["stage"] = 0
		_apply_stage(q)
	changed.emit()

func complete(id: String) -> void:
	set_progress(id, _find(id).get("goal", 1))

# Одноразовые квесты (сюжет и обучение) помечаем пройденными В СЕЙВЕ. Запись когда-то жила
# ВНУТРИ ветки «награда блоком», поэтому шаги обучения — а у них награды блоком нет — не
# сохранялись вовсе, и после перезапуска обучение начиналось заново. Пропущенный квест
# персистится наравне с выполненным: иначе он воскресал бы при каждом запуске.
func _persist_done(q: Dictionary) -> void:
	var g = get_node_or_null("/root/G")
	if g == null:
		return
	if int(q["type"]) != Type.STORY and int(q["type"]) != Type.TUTORIAL:
		return
	if not g.quests_done.has(q["id"]):
		g.quests_done.append(q["id"])
		g.mark_progress_dirty()

## The reward multiplier a quest earned from the strength of the enemies it put up (quest_arcs
## `_on_quest_kill`). Read once at completion and dropped, so a repeating event starts at 1 again.
func set_reward_mult(id: String, m: float) -> void:
	var q := _find(id)
	if not q.is_empty():
		q["reward_mult"] = m

## Whose quest this is: a G.FACTIONS id. Every quest today is the first faction's (Falsus); a
## quest of another names it in a "faction" field. The XP goes there, and the UI shows its emblem.
func faction_of(q: Dictionary) -> String:
	return String(q.get("faction", "start"))

func _on_completed(q: Dictionary) -> void:
	var mult: float = float(q.get("reward_mult", 1.0))
	q.erase("reward_mult")
	# Награда деньгами. Начисляем НАПРЯМУЮ (g.money += ...), а не через add_money, чтобы
	# награда сама не засчитывалась в задание «заработай денег».
	var reward: int = roundi(float(q.get("reward_money", 0)) * mult)
	var g = get_node_or_null("/root/G")
	if g:
		if reward > 0:
			g.money += reward
			g.mark_progress_dirty()   # мимо add_money — сейв надо пометить самим
			g.money_changed.emit()
		g.add_faction_xp(faction_of(q), roundi(float(q.get("reward_xp", 0)) * mult))
		g.add_research_points(roundi(float(q.get("reward_rp", 0)) * mult))
	# Награда БЛОКАМИ: блоки глючно кружат вокруг машины игрока, затем падают в мир (не молча в
	# инвентарь). Ставим на активную машину игрока.
	# A FACTION'S LICENCE IS A QUEST'S REWARD (G.FACTION_LICENCE): its root blocks arrive researched.
	if g:
		for f in g.FACTION_LICENCE:
			if String(g.FACTION_LICENCE[f]) == String(q["id"]):
				g.grant_licence(String(f))
				_say("System", tr("%s licence granted. Its blocks are in the tech tree.") % tr(String((g.FACTIONS[f] as Dictionary)["name"])))
	var rblock: int = int(q.get("reward_block", 0))
	if rblock > 0:
		var cc = get_tree().get_first_node_in_group("camera_controller")
		if cc != null and "current_vehicle" in cc and cc.current_vehicle != null \
				and cc.current_vehicle.has_method("award_blocks"):
			cc.current_vehicle.award_blocks(rblock, int(q.get("reward_block_count", 1)))
	_persist_done(q)
	# ШАГИ ОБУЧЕНИЯ ЗАКРЫВАЮТСЯ МОЛЧА. Их одиннадцать подряд, наград у них нет, и «директива
	# выполнена» после каждого — это одиннадцать реплик, которые отталкивают ровно ту
	# подсказку, ради которой обучение и существует: следующий шаг объявляется строкой ниже,
	# и раньше он выходил ВТОРЫМ, после поздравления ни с чем.
	# Ровно так же молча закрывает их кнопка SKIP (см. skip_tutorial) — теперь это одно правило
	# на оба пути, а не исключение для пропуска.
	if int(q["type"]) == Type.TUTORIAL:
		# Обучение ведёт за руку: закрыл шаг — сразу подсказываем следующий.
		if not _announce_tutorial():
			tutorial_finished.emit()
	else:
		_say("System", _completion_message(str(q["title"]), reward))
	# Сюжет двигается сам (visible_quests покажет следующее). Отслеживаемое могло закрыться —
	# перецепляемся на следующее активное.
	if tracked_id == "" or _find(tracked_id).get("done", true):
		_auto_track()
	_story_appeared()          # the completion may have unlocked the next one

# Новый грейд лицензии: Механик объявляет, что открылось в магазине (этап 1 прогрессии).
func _on_grade_up(faction: String, new_grade: int) -> void:
	var g = get_node_or_null("/root/G")
	if g == null:
		return
	var names: Array = []
	for bt in g.blocks_of_grade(faction, new_grade):
		names.append(g.block_name(int(bt)))
	var what := tr("new blocks") if names.is_empty() else ", ".join(names)
	# «Можно исследовать», не «в магазине»: до исследования в древе блок в магазине под замком.
	var extra_line := ""
	for q in quests:
		if q["type"] == Type.STORY and int(q.get("req_grade", 1)) == new_grade and not q["done"] \
				and faction_of(q) == faction:
			extra_line = tr(" And new quests have arrived.")
			break
	_say("Mechanic", tr("License — grade %d! You can now research: %s.%s") % [new_grade, what, extra_line])
	# Пауза сюжета могла сняться — обновляем список и трекер.
	changed.emit()
	if tracked_id == "" or _find(tracked_id).get("done", true):
		_auto_track()
	_story_appeared()          # a grade-gated story quest (SAM at 5) opens exactly here

# Случайная фраза о выполнении. С наградой и без — свои наборы.
func _completion_message(title: String, reward: int) -> String:
	if reward > 0:
		var with_reward := [
			"Directive '%s' resolved. Credited %d$.",
			"'%s' closed. %d$ posted to you.",
			"'%s' resolved — %d$.",
			"Logged: '%s'. Payment %d$.",
			"'%s' complete. The System credits %d$.",
		]
		return tr(with_reward[randi() % with_reward.size()]) % [tr(title), reward]
	var no_reward := [
		"Directive '%s' resolved.",
		"'%s' closed.",
		"Logged: '%s'.",
		"'%s' complete.",
	]
	return tr(no_reward[randi() % no_reward.size()]) % tr(title)

func _say(speaker: String, text: String) -> void:
	var d = get_node_or_null("/root/Dialogue")
	if d:
		d.say(speaker, text)

func _say_lines(lines: Array) -> void:
	var d = get_node_or_null("/root/Dialogue")
	if d:
		d.say_lines(lines)

# ── Отслеживание (звёздочка) ──────────────────────────────────────────────────
func track(id: String) -> void:
	tracked_id = id
	changed.emit()

func tracked() -> Dictionary:
	var q := _find(tracked_id)
	return q if not q.is_empty() else _first_active()

func _auto_track() -> void:
	var q := _first_active()
	tracked_id = q.get("id", "")
	changed.emit()

## A STORY QUEST THAT HAS JUST APPEARED TAKES THE TRACKER - from a daily or an event, never from
## another story quest (the tree branches, and an opening sibling must not drag the player off the
## branch they chose). Called from the three places a story quest can appear: a quest completing,
## a grade-up, and a held quest being released. Only on APPEARANCE: a player who deliberately
## switched to an event keeps it until the next story quest opens.
##
## The grade-up call is the one that was missing. SAM opens at grade 5, after Watchtower is done,
## so between the two the tracker had fallen to an event or a daily; grade 5 then opened SAM, and
## the old check - "retrack only if nothing is tracked or it is finished" - left the event on.
var _story_known: Dictionary = {}

func _story_appeared() -> void:
	var fresh: Dictionary = {}
	for q in available_story():
		var id := String(q["id"])
		if _story_known.has(id):
			continue
		_story_known[id] = true
		if fresh.is_empty():
			fresh = q
	if fresh.is_empty():
		return
	var cur := _find(tracked_id)
	if not cur.is_empty() and int(cur.get("type", -1)) == Type.STORY and cur["done"] == false:
		return
	track(String(fresh["id"]))

## What is already open when a save loads is not "new": seeing it again must not steal the tracker.
func _seed_story_known() -> void:
	_story_known.clear()
	for q in available_story():
		_story_known[String(q["id"])] = true

func _first_active() -> Dictionary:
	for q in active_quests():
		return q
	return {}

# ── Выборки для UI ────────────────────────────────────────────────────────────
# Активные (можно отслеживать/двигать): текущее сюжетное + все незавершённые ежедневные.
func active_quests() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	# ВЫДАННОЕ РУКАМИ ИДЁТ ПЕРВЫМ И МИМО ВОРОТ (см. force_quest): его затем и выдавали, чтобы
	# посмотреть прямо сейчас. Ниже те же квесты пропускаем, иначе они попали бы в список дважды.
	for q in forced_quests():
		out.append(q)
	# Обучение ПЕРВЫМ — оно и трекается первым (_first_active берёт голову списка).
	var tut := _current_tutorial()
	if not tut.is_empty():
		out.append(tut)
	for q in available_story():
		if not _forced.has(String(q["id"])):
			out.append(q)
	for q in quests:
		if q["type"] == Type.DAILY and not q["done"] and not _forced.has(String(q["id"])):
			out.append(q)
	for ev in current_events():
		if not _forced.has(String(ev["id"])):
			out.append(ev)
	return out

## СОБЫТИЙ В ЖУРНАЛЕ НЕ БОЛЬШЕ ДВУХ. Их шесть, все повторяемые, и появись они разом — журнал
## превратился бы в список поручений, а «событие» перестало бы что-либо значить. Два — это
## выбор («еду на груз или разгоняю банду») без превращения журнала в доску объявлений.
##
## НАЧАТЫЕ ИДУТ ПЕРВЫМИ: то, куда игрок уже едет и где дерётся, не должно вытесняться свежим
## объявлением. Остальные места добираем по списку; закончилось — следующее откроется само,
## когда это остынет (quest_arcs._ev_cooldowns, минута-две).
##
## Во время обучения событий нет вовсе: игроку ещё нечем ехать за двести метров, и наставник
## ведёт его за руку — вторая цель в журнале только сбивает.
## МЕСТ В ЖУРНАЛЕ — ПО ДАВЛЕНИЮ МИРА. Два события сразу — это уже выбор «еду на груз или разгоняю
## банду», и он хорош, когда есть чем ехать; на первом грейде это просто две беды разом. Пока мир
## слабый (G.threat_ramp), место одно.
const EVENT_SLOTS := 3
const EVENT_SLOTS_EARLY := 1
## С какого давления открывается второе место.
const EVENT_SLOTS_AT := 0.6

func event_slots() -> int:
	var g = get_node_or_null("/root/G")
	if g == null:
		return EVENT_SLOTS
	return EVENT_SLOTS if g.threat_ramp() >= EVENT_SLOTS_AT else EVENT_SLOTS_EARLY

## WHICH EVENTS ARE ON THE BOARD (the player's rules): EVENT_SLOTS places; one of them is GUARANTEED
## to an event of the highest faction the player holds; the rest are drawn at random; and a faction
## at its last grade stops sending events once a better one is open - with Marlit licensed and
## Falsus at grade 5, the board is Marlit's. A drawn event keeps its place until it is done or
## dropped (`_roster`, memory only): drawing on every call would shuffle the journal each frame.
var _roster: Array[String] = []

## Factions whose events may be drawn, in the table's order (the last is the highest).
func _event_factions() -> Array:
	var g = get_node_or_null("/root/G")
	if g == null:
		return ["start"]
	var open: Array = g.open_factions() if g.has_method("open_factions") else ["start"]
	var out: Array = []
	for i in open.size():
		var f := String(open[i])
		var last_grade: int = int((g.FACTIONS[f] as Dictionary).get("grades", 5))
		if i < open.size() - 1 and g.grade(f) >= last_grade:
			continue                          # maxed, and a better faction is open
		out.append(f)
	return out

func current_events() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if tutorial_active():
		return out
	var factions: Array = _event_factions()
	var pool: Array[Dictionary] = []
	for q in quests:
		if q["type"] != Type.EVENT or q["done"]:
			continue
		if int(q.get("stage", 0)) > 0 or int(q.get("progress", 0)) > 0:
			out.append(q)                 # это уже идёт — держим в любом случае
		elif _grade_ok(q) and factions.has(faction_of(q)):
			pool.append(q)
	var slots: int = event_slots()
	# keep what was drawn while it is still on offer
	var kept: Array[String] = []
	for id in _roster:
		var q := _find(id)
		if not q.is_empty() and (out.has(q) or pool.has(q)):
			kept.append(id)
	_roster = kept
	var shown: Array[String] = []
	for q in out:
		shown.append(String(q["id"]))
	for id in _roster:
		if not shown.has(id):
			shown.append(id)
	# the guaranteed place: an event of the highest faction
	var top := String(factions[-1]) if not factions.is_empty() else "start"
	var has_top := false
	for id in shown:
		if faction_of(_find(id)) == top:
			has_top = true
	if not has_top and shown.size() < slots:
		var tops: Array = pool.filter(func(q): return faction_of(q) == top and not shown.has(String(q["id"])))
		if not tops.is_empty():
			var pick: Dictionary = tops.pick_random()
			shown.append(String(pick["id"]))
			_roster.append(String(pick["id"]))
	# the rest at random
	var rest: Array = pool.filter(func(q): return not shown.has(String(q["id"])))
	rest.shuffle()
	for q in rest:
		if shown.size() >= slots:
			break
		shown.append(String(q["id"]))
		_roster.append(String(q["id"]))
	var res: Array[Dictionary] = []
	for id in shown.slice(0, slots):
		res.append(_find(id))
	return res

# Текущий шаг обучения (первый невыполненный по order) или пусто, если обучение пройдено.
func _current_tutorial() -> Dictionary:
	for q in _sorted_tutorial():
		if not q["done"]:
			return q
	return {}

func _sorted_tutorial() -> Array[Dictionary]:
	var s: Array[Dictionary] = []
	for q in quests:
		if q["type"] == Type.TUTORIAL:
			s.append(q)
	s.sort_custom(func(a, b): return a["order"] < b["order"])
	return s

# Механик подсказывает текущий шаг обучения. Возвращает true, если обучение ещё идёт.
func _announce_tutorial() -> bool:
	var t := _current_tutorial()
	if t.is_empty():
		return false
	var h := str(t.get("hint", ""))
	if h != "":
		_say("Mechanic", tr(h))
	return true

# Что показать в списке: все сюжетные ДО текущего включительно (выполненные + текущее) и
# все ежедневные. Будущие сюжетные (ещё закрытые) не показываем.
func visible_quests() -> Array[Dictionary]:
	# ТОЛЬКО невыполненное: ПЕРВЫЙ незакрытый шаг обучения, ПЕРВЫЙ незакрытый сюжетный
	# (он же ждущий грейда — тогда quests.gd подпишет «откроется на грейде N») и активные
	# дейлики. Выполненный квест просто пропадает из списка: галочки копились, и к середине
	# обучения трекер превращался в простыню из одиннадцати «✓».
	# Сюжетных показываем ВСЕ доступные, а не один: дерево ветвится, и игрок выбирает,
	# какую ветку вести. order остался только порядком показа внутри списка.
	var out: Array[Dictionary] = []
	for q in forced_quests():          # выданное руками видно в журнале так же, как обычное
		out.append(q)
	for q in _sorted_tutorial():
		if not q["done"]:
			out.append(q)
			break
	for q in available_story():
		if not _forced.has(String(q["id"])):
			out.append(q)
	for q in quests:
		if q["type"] == Type.DAILY and not q["done"] and not _forced.has(String(q["id"])):
			out.append(q)
	for ev in current_events():
		if not _forced.has(String(ev["id"])):
			out.append(ev)
	return out

# Сюжетные, доступные ПРЯМО СЕЙЧАС: не выполнены, требования закрыты, грейд взят.
# Раньше отдавался ровно один — первый невыполненный по order, и сюжет шёл одной ниткой.
# Теперь их может быть несколько сразу: закрыл первый квест — открылись второй и третий,
# бери любой, как это устроено у дейликов.
## КВЕСТ, КОТОРЫЙ ЖДЁТ СВОЮ ЦЕЛЬ. «Уничтожь разведчика» объявлялся сразу по окончании обучения, а
## сам разведчик прилетал через first_spawn_delay — восемь секунд. Всё это время в журнале висело
## задание, у которого нет цели, и метка вести было некуда.
##
## Придержка снимается ТЕМ, КТО ЦЕЛЬ СОЗДАЁТ (tutorial_director после спавна), а не по таймеру:
## таймер пришлось бы держать в синхроне с задержкой спавна, и он разъехался бы с ней при первой
## же правке.
##
## ХРАНИТСЯ ТОЛЬКО В ПАМЯТИ И НЕ СОХРАНЯЕТСЯ. Придержка имеет смысл ровно в тот сеанс, когда
## обучение закончилось; в загруженном сейве разведчика давно нет, и вечно придержанный квест
## означал бы сюжет, который не начнётся никогда.
var _held: Dictionary = {}

func hold_quest(id: String) -> void:
	_held[id] = true
	changed.emit()

func release_quest(id: String) -> void:
	if _held.erase(id):
		changed.emit()
		# ОТПУЩЕННЫЙ СЮЖЕТ ЗАБИРАЕТ ТРЕКЕР. Придержка снимается позже, чем квест стал доступен
		# по бумагам: разведчик прилетает через first_spawn_delay, и всё это время головой списка
		# была ЕЖЕДНЕВКА — её и брал _auto_track в конце обучения. Игрок выходил из обучения с
		# «продай руды» вместо первого сюжетного, а тот молча появлялся третьей строкой.
		_story_appeared()

## ── ЗАДАНИЕ, ВЫДАННОЕ РУКАМИ (полигон) ──────────────────────────────────────
## Обратная сторона `_held`: там квест придерживают, здесь проталкивают мимо всех ворот сразу —
## требований предыдущих квестов, грейда, двух мест в журнале и «пока идёт обучение, сюжета нет».
## Иначе ветку на полигоне не проверить вовсе: сюжет заперт тем, что до него не дошли, события —
## грейдом, а обучение там не проходят.
##
## ТОЛЬКО ПАМЯТЬ, НИКАКОГО СОХРАНЕНИЯ — как у `_held`. Полигон и так ничего не пишет на диск
## (`G._flush_progress`), но выданное руками не должно пережить даже выход в меню.
##
## ОБУЧЕНИЕ СЮДА НЕ ВХОДИТ. Его ведёт `tutorial_director` шаг за шагом, и вырванный из середины
## шаг проверяет не ветку, а рассинхрон между шагом и тем, кто его ведёт.
var _forced: Dictionary = {}

func force_quest(id: String) -> bool:
	var q := _find(id)
	if q.is_empty() or int(q["type"]) == Type.TUTORIAL:
		return false
	# СБРАСЫВАЕМ В НАЧАЛО. Полигон одалживает последний игранный слот, и сюжет в нём может быть
	# уже пройден; проверять надо ветку целиком, а не её последнюю секунду.
	reset_quest(id)
	# The branch's memory lives in quest_arcs and outlives the quest: forget it, or a branch forced
	# a second time starts from where the first run left it.
	get_tree().call_group("quest_arcs", "forget_quest", id)
	_forced[id] = true
	changed.emit()
	_auto_track()
	return true

## Снять выданное: без имени — всё сразу.
func drop_forced(id: String = "") -> void:
	if id == "":
		if _forced.is_empty():
			return
		_forced.clear()
	elif not _forced.erase(id):
		return
	changed.emit()
	_auto_track()

func is_forced(id: String) -> bool:
	return _forced.has(id)

## Выданные руками — в том виде, в каком их ждут ветки (`quest_arcs`) и журнал.
func forced_quests() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for id in _forced:
		var q := _find(String(id))
		if not q.is_empty() and not q["done"]:
			out.append(q)
	return out

func available_story() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	# Пока идёт обучение, сюжета нет: иначе игрок на первом шаге видел бы список заданий,
	# для которых у него ещё нет ни машины, ни блоков.
	if tutorial_active():
		return out
	for q in _sorted_story():
		if _held.has(String(q["id"])):
			continue                        # цель ещё не появилась — см. hold_quest
		if not q["done"] and unlocked(q) and _grade_ok(q):
			out.append(q)
	return out

func _current_story() -> Dictionary:
	var a := available_story()
	return a[0] if not a.is_empty() else {}

func _sorted_story() -> Array[Dictionary]:
	var s: Array[Dictionary] = []
	for q in quests:
		if q["type"] == Type.STORY:
			s.append(q)
	s.sort_custom(func(a, b): return a["order"] < b["order"])
	return s
