extends Node

signal changed
## Последний шаг обучения закрыт — наставник по этому сигналу заканчивает вводную и
## запускает сюжет (спавнит первого врага).
signal tutorial_finished

enum Type { STORY, DAILY, TUTORIAL }
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
			["Mechanic", "Welcome back! Check the quest list at the top right."],
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
	add_quest("tut_mode_build", "Tutorial: Build mode", "Enter building mode", Type.TUTORIAL, 1, 0, "mode_building", 0, 0, 0, 1,
			"Everything starts in building mode. The button reads BUILD — tap it.")
	# Закрывается ЛЮБЫМ способом взять блок в руку (с земли, с машины, из инвентаря): игрок
	# считает, что «подобрал», и шаг обязан это засчитать.
	add_quest("tut_take_world", "Tutorial: Pick up", "Take a block in hand", Type.TUTORIAL, 1, 1, "block_taken_world", 0, 0, 0, 1,
			"Your starting blocks are lying around the cabin. Double-tap one to take it into your hand.")
	add_quest("tut_place_first", "Tutorial: First block", "Place the block", Type.TUTORIAL, 1, 2, "block_placed", 0, 0, 0, 1,
			"Now double-tap the vehicle where the block should sit.")
	# Событие пустое: прогресс СТАВИТ наставник по числу блоков на машине. По событию
	# block_placed его накручивали бы циклом «поставил — снял — поставил».
	add_quest("tut_place_all", "Tutorial: Assembly", "Mount every starting block", Type.TUTORIAL, 8, 3, "", 0, 0, 0, 1,
			"Same for the rest: pick up, place. Wheels on the sides, the drill facing forward.")
	add_quest("tut_mode_move", "Tutorial: Driving", "Leave building mode", Type.TUTORIAL, 1, 4, "mode_movement", 0, 0, 0, 1,
			"Assembled? The same button now reads MOVE — tap it to drive.")
	add_quest("tut_quests", "Tutorial: Quests", "Open the quest list", Type.TUTORIAL, 1, 5, "quests_opened", 0, 0, 0, 1,
			"Top right is the quest tracker. Tap it to see the whole list.")
	add_quest("tut_garage", "Tutorial: Garage", "Open the garage", Type.TUTORIAL, 1, 6, "garage_opened", 0, 0, 0, 1,
			"The menu is the icon in the top-left corner. Inventory opens the garage.")
	add_quest("tut_filters", "Tutorial: Inventory", "Use a category filter", Type.TUTORIAL, 1, 7, "garage_filter", 0, 0, 0, 1,
			"These are your blocks. The buttons on the left filter them by category.")
	add_quest("tut_shop", "Tutorial: Shop", "Open the shop", Type.TUTORIAL, 1, 8, "garage_shop", 0, 0, 0, 1,
			"The SHOP tab is where blocks are bought.")
	add_quest("tut_tech", "Tutorial: Research", "Open the tech tree", Type.TUTORIAL, 1, 9, "garage_tech", 0, 0, 0, 1,
			"The TECH tab is where blocks are unlocked.")
	add_quest("tut_music", "Tutorial: Music", "Open the music tab", Type.TUTORIAL, 1, 10, "garage_music", 0, 0, 0, 1,
			"Last one — the music tab.")
	# ── STORY ────────────────────────────────────────────────────────────────────
	# Первый сюжетный — сразу после обучения: наставник спавнит разведчика рядом с игроком.
	add_quest("story_first_blood", "First Blood", "Destroy the scout", Type.STORY, 1, 0, "enemy_killed", 30, 25, 5)
	add_quest("story_build", "Build a Vehicle",  "Place 5 blocks",          Type.STORY, 5,   1, "block_placed", 20, 20, 5)
	add_quest("story_ore",   "Mine Ore",         "Drill 10 ore",            Type.STORY, 10,  2, "ore_mined",    30, 30, 8)
	add_quest("story_sell",  "Earn Money",       "Earn 100$",               Type.STORY, 100, 3, "money_earned", 50, 40, 10)
	add_quest("story_kill",  "First Fight",      "Destroy an enemy cabin",  Type.STORY, 1,   4, "enemy_killed", 40, 50, 15)
	# Grade 2: mastering mining-production and the first weapon.
	add_quest("g2_ore",   "Miner II",         "Drill 50 ore",          Type.STORY, 50,   10, "ore_mined",    60,  30, 8,  2)
	add_quest("g2_kill",  "Hunter",           "Destroy 3 vehicles",    Type.STORY, 3,    11, "enemy_killed", 80,  45, 10, 2)
	add_quest("g2_money", "Trader",           "Earn 300$",             Type.STORY, 300,  12, "money_earned", 100, 40, 10, 2)
	add_quest("g2_build", "Builder II",       "Place 15 blocks",       Type.STORY, 15,   13, "block_placed", 60,  35, 8,  2)
	# Grade 3: the production chain at full scale.
	add_quest("g3_ore",   "Industrialist",    "Drill 150 ore",         Type.STORY, 150,  20, "ore_mined",    150, 50, 12, 3)
	add_quest("g3_kill",  "Wasteland Terror", "Destroy 10 vehicles",   Type.STORY, 10,   21, "enemy_killed", 200, 60, 15, 3)
	add_quest("g3_money", "Capital",          "Earn 1000$",            Type.STORY, 1000, 22, "money_earned", 250, 55, 15, 3)
	# Grade 4: heavy machinery.
	add_quest("g4_ore",   "Ore Baron",        "Drill 400 ore",         Type.STORY, 400,  30, "ore_mined",    400, 80, 18, 4)
	add_quest("g4_kill",  "Veteran",          "Destroy 25 vehicles",   Type.STORY, 25,   31, "enemy_killed", 500, 90, 20, 4)
	add_quest("g4_money", "Magnate",          "Earn 3000$",            Type.STORY, 3000, 32, "money_earned", 600, 80, 18, 4)
	# Grade 5: endgame — XP no longer needed (maxed), focus on RP to finish the tree.
	add_quest("g5_kill",  "Wasteland Legend", "Destroy 50 vehicles",   Type.STORY, 50,   40, "enemy_killed", 800,  0, 30, 5)
	add_quest("g5_ore",   "Backbone of Industry", "Drill 1000 ore",    Type.STORY, 1000, 41, "ore_mined",    800,  0, 30, 5)
	add_quest("g5_money", "Empire",           "Earn 10000$",           Type.STORY, 10000,42, "money_earned", 1000, 0, 25, 5)
	add_quest("daily_ore",   "Daily: Ore",       "Mine 20 ore",        Type.DAILY, 20,  0, "ore_mined",    25, 15, 3)
	add_quest("daily_kill",  "Daily: Enemies",   "Destroy 3 vehicles", Type.DAILY, 3,   0, "enemy_killed", 40, 20, 5)

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
	})
	changed.emit()

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
	_say("Mechanic", "Skipping ahead. Everything's in the menus when you want it.")
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
	if q["progress"] >= q["goal"]:
		q["done"] = true
	changed.emit()
	if q["done"]:
		_on_completed(q)

func complete(id: String) -> void:
	set_progress(id, _find(id).get("goal", 1))

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
	# Одноразовые квесты (сюжет и обучение) помечаем пройденными В СЕЙВЕ. Запись жила
	# ВНУТРИ ветки «награда блоком», поэтому шаги обучения — а у них награды блоком нет —
	# не сохранялись вовсе, и после перезапуска обучение начиналось заново.
	if g != null and (int(q["type"]) == Type.STORY or int(q["type"]) == Type.TUTORIAL) \
			and not g.quests_done.has(q["id"]):
		g.quests_done.append(q["id"])
		g.mark_progress_dirty()
	_say("System", _completion_message(str(q["title"]), reward))
	# Обучение ведёт за руку: закрыл шаг — сразу подсказываем следующий.
	if int(q["type"]) == Type.TUTORIAL:
		if not _announce_tutorial():
			tutorial_finished.emit()
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
			"Quest '%s' complete, reward %d$.",
			"Quest '%s' done! Here's %d$.",
			"Nice — '%s' done. Reward: %d$.",
			"'%s' finished. Your cut — %d$.",
			"Quest '%s' complete. Credited %d$.",
		]
		return with_reward[randi() % with_reward.size()] % [title, reward]
	var no_reward := [
		"Quest '%s' complete.",
		"Quest '%s' done!",
		"Done — '%s' complete.",
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
	var cur := _current_story()
	if not cur.is_empty():
		out.append(cur)
	for q in quests:
		if q["type"] == Type.DAILY and not q["done"]:
			out.append(q)
	return out

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
	# ИНВАРИАНТ: quests_done — префикс порядка order (сюжет выполняется последовательно);
	# новые квесты добавляй ТОЛЬКО с order больше существующих, иначе префикс сломается.
	var out: Array[Dictionary] = []
	for q in _sorted_tutorial():
		if not q["done"]:
			out.append(q)
			break
	for q in _sorted_story():
		if not q["done"]:
			out.append(q)
			break
	for q in quests:
		if q["type"] == Type.DAILY and not q["done"]:
			out.append(q)
	return out

func _current_story() -> Dictionary:
	# Первый невыполненный по order. Если его грейд ещё не взят — сюжет НА ПАУЗЕ
	# (не перескакиваем вперёд): активного сюжетного нет, остаются дейлики.
	for q in _sorted_story():
		if not q["done"]:
			return q if _grade_ok(q) else {}
	return {}

func _sorted_story() -> Array[Dictionary]:
	var s: Array[Dictionary] = []
	for q in quests:
		if q["type"] == Type.STORY:
			s.append(q)
	s.sort_custom(func(a, b): return a["order"] < b["order"])
	return s
