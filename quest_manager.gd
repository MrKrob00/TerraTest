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
	# Ведём за руку: если обучение не пройдено — Механик сразу подсказывает текущий шаг.
	# Пройдено — обычное приветствие.
	if not _announce_tutorial():
		_say_lines([
			["Mechanic", "Still running. Directives are top right when you want them."],
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
	# развёрнутые объяснения (магазин, древо, музыка) живут в самом наставнике.
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
	add_quest("tut_mode_move", "Boot: Motion", "Leave assembly", Type.TUTORIAL, 1, 4, "mode_movement", 0, 0, 0, 1,
			"Assembled? The same button reads MOVE. Let us see if you hold together.")
	add_quest("tut_quests", "Boot: Directives", "Open the log", Type.TUTORIAL, 1, 5, "quests_opened", 0, 0, 0, 1,
			"Directives come from the System. The tracker is top right — tap it for the full log.")
	add_quest("tut_garage", "Boot: Storage", "Open storage", Type.TUTORIAL, 1, 6, "garage_opened", 0, 0, 0, 1,
			"Your storage is the pack in the corner. Everything you own is in there.")
	add_quest("tut_filters", "Boot: Sorting", "Filter the parts", Type.TUTORIAL, 1, 7, "garage_filter", 0, 0, 0, 1,
			"These are your parts. The buttons on the left sort them by kind.")
	add_quest("tut_shop", "Boot: Trade", "Open trade", Type.TUTORIAL, 1, 8, "garage_shop", 0, 0, 0, 1,
			"TRADE is where parts are bought. The System charges for everything it lets you have.")
	add_quest("tut_tech", "Boot: Research", "Open research", Type.TUTORIAL, 1, 9, "garage_tech", 0, 0, 0, 1,
			"RESEARCH is where you unlock schematics. Nothing here is given for free.")
	add_quest("tut_music", "Boot: Audio", "Open audio", Type.TUTORIAL, 1, 10, "garage_music", 0, 0, 0, 1,
			"Last one. Even a simulation lets you pick what plays.")
	# ── STORY ────────────────────────────────────────────────────────────────────
	# ЗДЕСЬ ТОЛЬКО СЮЖЕТ. Раньше сюда же было насыпано семнадцать заданий-счётчиков
	# («поставь 5 блоков», «накопай 10 руды», «заработай 100$», «убей 3 машины» и так далее
	# по всем пяти грейдам). Они не рассказывали ничего: то же самое игрок делает и без
	# задания, а журнал они забивали так, что настоящие сюжетные ветки в нём терялись.
	# Счётчики остались там, где они уместны, — в ЕЖЕДНЕВКАХ внизу файла.
	# Награды деньгами живут в масштабе МАГАЗИНА, а цены там считаются из рецептов
	# (G.shop_price): простой блок стоит ~220$, кабина ~1800$. Пока цены были выдуманы
	# руками (блок за 5$), награды в 50$ выглядели щедро; после привязки к материалам они
	# стали бы мелочью, поэтому подняты втрое.
	# ЦЕЛИ «заработай N$» при этом не тронуты: цена руды осталась прежней (10$ за
	# ферритовую), значит и работа за этими числами ровно та же, что была.
	# Первый сюжетный — сразу после обучения: наставник спавнит разведчика рядом с игроком.
	add_quest("story_first_blood", "Noticed", "Destroy the scout", Type.STORY, 1, 0, "enemy_killed", 90, 25, 5)
	# ── СЮЖЕТ ПОСЛЕ РАЗВЕДЧИКА: ветка выбора ────────────────────────────────────
	# Три квеста, каждый в двух частях. Первый ведёт к остальным двум, и дальше игрок сам
	# решает, какой брать: они открываются одновременно и друг друга не ждут.
	add_quest("arc_power", "Draw Power", "", Type.STORY, 1, 5, "", 180, 40, 12)
	add_stages("arc_power", [
		{"desc": "Recover the panel and the anchor, then hold ground",
		 "event": "quest_arc_power_1", "goal": 1,
		 "hint": "Two parts surfaced in the field — a panel and an anchor. Attach both, then set down and hold: the panel only draws power while you are anchored."},
		{"desc": "Attach the repair unit",
		 "event": "quest_arc_power_2", "goal": 1,
		 "hint": "A repair unit resolved beside you. Attach it — it stitches the rest of you back together."},
	])
	add_quest("arc_radar", "Line of Sight", "", Type.STORY, 1, 6, "", 210, 45, 14)
	add_stages("arc_radar", [
		{"desc": "Recover the scanner and attach it",
		 "event": "quest_arc_radar_1", "goal": 1,
		 "hint": "A scanner is lying out there. It widens what you can see — right now that is almost nothing."},
		{"desc": "Take the scanner from the other one",
		 "event": "quest_arc_radar_2", "goal": 1,
		 "hint": "Something else out there is carrying one too. It will not hand it over."},
	])
	add_quest("arc_battery", "Buried Charge", "", Type.STORY, 1, 7, "", 210, 45, 14)
	add_stages("arc_battery", [
		{"desc": "Recover the cell",
		 "event": "quest_arc_battery_1", "goal": 1,
		 "hint": "A power cell resolved somewhere in the field. Go and take it before something else does."},
		{"desc": "Break the vein holding the cell",
		 "event": "quest_arc_battery_2", "goal": 1,
		 "hint": "It resolved inside a vein — the terrain closed over it. Mine the vein out and it drops free."},
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
		 "hint": "Whatever is guarding it does not own it either. The collector inside is yours once it is gone."},
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
	add_quest("arc_solvent", "Solvent", "Earn 600$ through the line", Type.STORY, 600, 10, "money_earned", 400, 60, 18)
	add_quest("arc_hold", "Hold the Line", "", Type.STORY, 1, 11, "", 450, 70, 20)
	add_stages("arc_hold", [
		{"desc": "They are coming for the line",
		 "event": "quest_hold_1", "goal": 1,
		 "hint": "Something logged your production. They are coming for the machine that makes it, not for you."},
		{"desc": "Destroy the raid",
		 "event": "quest_hold_2", "goal": 1,
		 "hint": "Two of them. Your base cannot drive away — this one you finish standing."},
	])

	requires("arc_power", ["story_first_blood"])
	requires("arc_radar", ["arc_power"])      # развилка: оба открываются вместе,
	requires("arc_battery", ["arc_power"])    # и порядок между ними выбирает игрок
	# Дальше ветки сходятся: груз даёт коллектор, без него цепочку не построить, а без
	# цепочки нечего оборонять. Порядок здесь ЖЁСТКИЙ и по делу, а не по привычке.
	requires("arc_salvage", ["arc_radar", "arc_battery"])
	requires("arc_line", ["arc_salvage"])
	requires("arc_solvent", ["arc_line"])
	requires("arc_hold", ["arc_solvent"])

	# ── СОБЫТИЕ ─────────────────────────────────────────────────────────────────
	# Не сюжет и не счётчик: Система засекла чужую стычку и предлагает вмешаться. Две части —
	# доехать и победить. Повторяется: quest_arcs перезаряжает его после остывания.
	add_quest("event_duel", "Crossfire", "", Type.EVENT, 1, 0, "", 260, 30, 6)
	add_stages("event_duel", [
		{"desc": "Reach the contact coordinates",
		 "event": "quest_duel_1", "goal": 1,
		 "hint": "Two units are shooting at each other out there. The System would rather neither of them finished."},
		{"desc": "Be the one that drives away",
		 "event": "quest_duel_2", "goal": 1,
		 "hint": "Neither of them cares which of you it is. Take both, or wait and take what is left."},
	])

	# Пять типов с борда оригинала. Борда у нас нет — их объявляет Система, а повторяются они
	# по остыванию, как «Crossfire» (см. quest_arcs, раздел «ПОВТОРЯЕМЫЕ СОБЫТИЯ»). Общее
	# правило у всех одно: уехал от цели за 500 м — задание снято.
	add_quest("event_gang", "Tech Gang", "", Type.EVENT, 1, 0, "", 320, 40, 8)
	add_stages("event_gang", [
		{"desc": "Reach the reported camp",
		 "event": "quest_gang_1", "goal": 1,
		 "hint": "Three unmarked units parked together. They are not going anywhere on their own."},
		{"desc": "Break the gang",
		 "event": "quest_gang_2", "goal": 1,
		 "hint": "They stand until someone shoots. That someone is you."},
	])
	add_quest("event_supply", "Supply Drop", "", Type.EVENT, 1, 0, "", 200, 25, 5)
	add_stages("event_supply", [
		{"desc": "Reach the drop",
		 "event": "quest_supply_1", "goal": 1,
		 "hint": "A crate came down intact. Whether anyone else got the signal is the interesting part."},
		{"desc": "Take the crate",
		 "event": "quest_supply_2", "goal": 1,
		 "hint": "The crate is the objective. Whatever is guarding it is only in the way."},
	])
	add_quest("event_defend", "Cover the Convoy", "", Type.EVENT, 1, 0, "", 300, 35, 7)
	add_stages("event_defend", [
		{"desc": "Reach the friendly unit",
		 "event": "quest_defend_1", "goal": 1,
		 "hint": "One of ours is pinned down and will not hold long."},
		{"desc": "Drive the raiders off",
		 "event": "quest_defend_2", "goal": 1,
		 "hint": "It survives or it does not. There is no partial credit for this one."},
	])
	add_quest("event_waves", "Hold Position", "", Type.EVENT, 1, 0, "", 340, 45, 9)
	add_stages("event_waves", [
		{"desc": "Survive the first wave",
		 "event": "quest_waves_1", "goal": 1,
		 "hint": "They are coming to you. Pick your ground before they arrive."},
		{"desc": "Survive the second wave",
		 "event": "quest_waves_2", "goal": 1,
		 "hint": "Heavier than the first. Repairs, if you have them, happen now."},
	])
	add_quest("event_camp", "Take the Staging Point", "", Type.EVENT, 1, 0, "", 420, 55, 12)
	add_stages("event_camp", [
		{"desc": "Reach the staging point",
		 "event": "quest_camp_1", "goal": 1,
		 "hint": "Not a patrol — a place they come back to. Three units hold it."},
		{"desc": "Clear it and take what is left",
		 "event": "quest_camp_2", "goal": 1,
		 "hint": "The point is not taken until the crate on it is yours."},
	])

	add_quest("daily_ore",   "Cycle: Ore",       "Mine 20 ore",        Type.DAILY, 20,  0, "ore_mined",    75, 15, 3)
	add_quest("daily_kill",  "Cycle: Sweep",     "Destroy 3 vehicles", Type.DAILY, 3,   0, "enemy_killed", 120, 20, 5)

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
	_say("System", "Directive '%s' is no longer resolvable. Dropped." % String(q["title"]))
	changed.emit()
	_auto_track()

# Взят ли грейд, нужный квесту (гейт цепочек по лицензии).
func _grade_ok(q: Dictionary) -> bool:
	var need := int(q.get("req_grade", 1))
	if need <= 1:
		return true
	var g = get_node_or_null("/root/G")
	return g == null or g.grade("start") >= need

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
	_say("Mechanic", "Skipping the walkthrough. It is all in the menus when you need it.")
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
	tracked_id = ""
	changed.emit()

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
			_say("Mechanic", hint)
		return
	q["done"] = true
	changed.emit()
	_on_completed(q)

## Открыть квест ЗАНОВО (события повторяются). Прогресс и стадию откатываем в начало — иначе
## перезаряженное событие сразу оказалось бы на своей второй части.
func reset_quest(id: String) -> void:
	var q := _find(id)
	if q.is_empty():
		return
	q["done"] = false
	q["progress"] = 0
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

func _on_completed(q: Dictionary) -> void:
	# Награда деньгами. Начисляем НАПРЯМУЮ (g.money += ...), а не через add_money, чтобы
	# награда сама не засчитывалась в задание «заработай денег».
	var reward: int = int(q.get("reward_money", 0))
	var g = get_node_or_null("/root/G")
	if g:
		if reward > 0:
			g.money += reward
			g.mark_progress_dirty()   # мимо add_money — сейв надо пометить самим
			g.money_changed.emit()
		g.add_faction_xp("start", int(q.get("reward_xp", 0)))
		g.add_research_points(int(q.get("reward_rp", 0)))
	# Награда БЛОКАМИ: блоки глючно кружат вокруг машины игрока, затем падают в мир (не молча в
	# инвентарь). Ставим на активную машину игрока.
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

# Новый грейд лицензии: Механик объявляет, что открылось в магазине (этап 1 прогрессии).
func _on_grade_up(faction: String, new_grade: int) -> void:
	var g = get_node_or_null("/root/G")
	if g == null:
		return
	var names: Array = []
	for bt in g.blocks_of_grade(faction, new_grade):
		names.append(g.block_name(int(bt)))
	var what := "new blocks" if names.is_empty() else ", ".join(names)
	# «Можно исследовать», не «в магазине»: до исследования в древе блок в магазине под замком.
	var extra_line := ""
	for q in quests:
		if q["type"] == Type.STORY and int(q.get("req_grade", 1)) == new_grade and not q["done"]:
			extra_line = " And new quests have arrived."
			break
	_say("Mechanic", "License — grade %d! You can now research: %s.%s" % [new_grade, what, extra_line])
	# Пауза сюжета могла сняться — обновляем список и трекер.
	changed.emit()
	if tracked_id == "" or _find(tracked_id).get("done", true):
		_auto_track()

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
		return with_reward[randi() % with_reward.size()] % [title, reward]
	var no_reward := [
		"Directive '%s' resolved.",
		"'%s' closed.",
		"Logged: '%s'.",
		"'%s' complete.",
	]
	return no_reward[randi() % no_reward.size()] % title

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

func _first_active() -> Dictionary:
	for q in active_quests():
		return q
	return {}

# ── Выборки для UI ────────────────────────────────────────────────────────────
# Активные (можно отслеживать/двигать): текущее сюжетное + все незавершённые ежедневные.
func active_quests() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	# Обучение ПЕРВЫМ — оно и трекается первым (_first_active берёт голову списка).
	var tut := _current_tutorial()
	if not tut.is_empty():
		out.append(tut)
	for q in available_story():
		out.append(q)
	for q in quests:
		if q["type"] == Type.DAILY and not q["done"]:
			out.append(q)
	var ev := _current_event()
	if not ev.is_empty():
		out.append(ev)
	return out

## СОБЫТИЕ ПОКАЗЫВАЕМ ОДНО ЗА РАЗ. Их пять, все повторяемые, и появись они разом — журнал
## превратился бы в список поручений, а «событие» перестало бы что-либо значить. Берём то,
## которое УЖЕ НАЧАТО (игрок доехал, дерётся), иначе первое доступное по списку; закончилось —
## следующее откроется само, когда это остынет (quest_arcs._ev_cooldowns).
##
## Во время обучения событий нет вовсе: игроку ещё нечем ехать за двести метров, и наставник
## ведёт его за руку — вторая цель в журнале только сбивает.
func _current_event() -> Dictionary:
	if tutorial_active():
		return {}
	var first: Dictionary = {}
	for q in quests:
		if q["type"] != Type.EVENT or q["done"]:
			continue
		if int(q.get("stage", 0)) > 0 or int(q.get("progress", 0)) > 0:
			return q                      # это уже идёт — его и держим
		if first.is_empty():
			first = q
	return first

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
		_say("Mechanic", h)
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
	for q in _sorted_tutorial():
		if not q["done"]:
			out.append(q)
			break
	for q in available_story():
		out.append(q)
	for q in quests:
		if q["type"] == Type.DAILY and not q["done"]:
			out.append(q)
	var ev := _current_event()
	if not ev.is_empty():
		out.append(ev)
	return out

# Сюжетные, доступные ПРЯМО СЕЙЧАС: не выполнены, требования закрыты, грейд взят.
# Раньше отдавался ровно один — первый невыполненный по order, и сюжет шёл одной ниткой.
# Теперь их может быть несколько сразу: закрыл первый квест — открылись второй и третий,
# бери любой, как это устроено у дейликов.
func available_story() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	# Пока идёт обучение, сюжета нет: иначе игрок на первом шаге видел бы список заданий,
	# для которых у него ещё нет ни машины, ни блоков.
	if tutorial_active():
		return out
	for q in _sorted_story():
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
