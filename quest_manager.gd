extends Node
# Автолоад Q — менеджер заданий. Два вида:
#   • STORY — сюжетные/последовательные: показывается только текущее незавершённое (плюс
#     уже выполненные); следующее открывается, когда предыдущее сдано (по полю order).
#   • DAILY — ежедневные: доступны все сразу.
# UI (quests.gd) читает отсюда и пересобирается по сигналу changed. Прогресс двигай из
# игры: Q.add_progress("story_ore", 1) — когда добыл руду, убил врага и т.п.

signal changed

enum Type { STORY, DAILY }

var quests: Array[Dictionary] = []
var tracked_id: String = ""

func _ready() -> void:
	_seed_demo()
	_auto_track()
	# Реплика Механика при новом грейде лицензии (см. G.grade_up / этап 1 прогрессии).
	var g = get_node_or_null("/root/G")
	if g:
		g.grade_up.connect(_on_grade_up)
	_say_lines([
		["Механик", "Эй, новичок! Сначала собери себе машину — поставь пару блоков."],
		["Механик", "Потом сгоняй за рудой и глянь список заданий справа сверху."],
	])

# Демо-набор. event — какое игровое событие двигает прогресс (см. Q.report ниже);
# reward_money/xp/rp — награды при выполнении ($ / XP фракции / ДИ). Порядок — order.
func _seed_demo() -> void:
	add_quest("story_build", "Собери машину",    "Поставь 5 блоков",        Type.STORY, 5,   0, "block_placed", 20, 20, 5)
	add_quest("story_ore",   "Добудь руду",      "Насверли 10 руды",        Type.STORY, 10,  1, "ore_mined",    30, 30, 8)
	add_quest("story_sell",  "Заработай денег",  "Заработай 100$",          Type.STORY, 100, 2, "money_earned", 50, 40, 10)
	add_quest("story_kill",  "Первый бой",       "Уничтожь кабину врага",   Type.STORY, 1,   3, "enemy_killed", 40, 50, 15)
	add_quest("daily_ore",   "Ежедневно: руда",  "Добудь 20 руды",          Type.DAILY, 20,  0, "ore_mined",    25, 15, 3)
	add_quest("daily_kill",  "Ежедневно: враги", "Уничтожь 3 машины",       Type.DAILY, 3,   0, "enemy_killed", 40, 20, 5)

# ── Данные ────────────────────────────────────────────────────────────────────
func add_quest(id: String, title: String, desc: String, type: int, goal: int,
		order: int = 0, event: String = "", reward_money: int = 0,
		reward_xp: int = 0, reward_rp: int = 0) -> void:
	quests.append({
		"id": id, "title": title, "desc": desc, "type": type,
		"goal": maxi(goal, 1), "progress": 0, "done": false, "order": order,
		"event": event, "reward_money": reward_money,
		"reward_xp": reward_xp, "reward_rp": reward_rp,
	})
	changed.emit()

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
		g.add_faction_xp("start", int(q.get("reward_xp", 0)))
		g.add_research_points(int(q.get("reward_rp", 0)))
	# Реплика о выполнении от «системы» — случайный шаблон, чтобы не было монотонно.
	_say("Система", _completion_message(str(q["title"]), reward))
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
	var what := "новые блоки" if names.is_empty() else ", ".join(names)
	_say("Механик", "Лицензия — грейд %d! В магазине открылось: %s." % [new_grade, what])

# Случайная фраза о выполнении. С наградой и без — свои наборы.
func _completion_message(title: String, reward: int) -> String:
	if reward > 0:
		var with_reward := [
			"Квест «%s» выполнен, в награду %d$.",
			"Задание «%s» закрыто! Держи %d$.",
			"Отлично — «%s» сделано. Награда: %d$.",
			"«%s» готово. Твоя доля — %d$.",
			"Задание «%s» выполнено. Начислено %d$.",
		]
		return with_reward[randi() % with_reward.size()] % [title, reward]
	var no_reward := [
		"Квест «%s» выполнен.",
		"Задание «%s» закрыто!",
		"Готово — «%s» сделано.",
		"«%s» выполнено.",
	]
	return no_reward[randi() % no_reward.size()] % title

# ── Мостик к диалогам (Dialogue — автолоад, грузится раньше Q) ─────────────────
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
	var cur := _current_story()
	if not cur.is_empty():
		out.append(cur)
	for q in quests:
		if q["type"] == Type.DAILY and not q["done"]:
			out.append(q)
	return out

# Что показать в списке: все сюжетные ДО текущего включительно (выполненные + текущее) и
# все ежедневные. Будущие сюжетные (ещё закрытые) не показываем.
func visible_quests() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var cur_order = _current_story().get("order", 999999)
	for q in _sorted_story():
		if q["done"] or q["order"] <= cur_order:
			out.append(q)
	for q in quests:
		if q["type"] == Type.DAILY:
			out.append(q)
	return out

func _current_story() -> Dictionary:
	for q in _sorted_story():
		if not q["done"]:
			return q
	return {}

func _sorted_story() -> Array[Dictionary]:
	var s: Array[Dictionary] = []
	for q in quests:
		if q["type"] == Type.STORY:
			s.append(q)
	s.sort_custom(func(a, b): return a["order"] < b["order"])
	return s
