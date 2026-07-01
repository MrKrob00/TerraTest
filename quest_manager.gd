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

# Демо-набор. Замени/дополни своими; порядок сюжета — поле order.
func _seed_demo() -> void:
	add_quest("story_build",  "Собери машину",     "Поставь кабину и 4 колеса",        Type.STORY, 5, 0)
	add_quest("story_ore",    "Добудь руду",       "Насверли 10 руды дрелью",          Type.STORY, 10, 1)
	add_quest("story_sell",   "Заработай денег",   "Продай ресурсы на 100$",           Type.STORY, 100, 2)
	add_quest("story_kill",   "Первый бой",        "Уничтожь кабину врага",            Type.STORY, 1, 3)
	add_quest("daily_ore",    "Ежедневно: руда",   "Добудь 20 руды",                   Type.DAILY, 20, 0)
	add_quest("daily_kill",   "Ежедневно: враги",  "Уничтожь 3 машины",                Type.DAILY, 3, 0)

# ── Данные ────────────────────────────────────────────────────────────────────
func add_quest(id: String, title: String, desc: String, type: int, goal: int, order: int = 0) -> void:
	quests.append({
		"id": id, "title": title, "desc": desc, "type": type,
		"goal": maxi(goal, 1), "progress": 0, "done": false, "order": order,
	})
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

func _on_completed(_q: Dictionary) -> void:
	# Сюжет двигается сам (visible_quests покажет следующее). Отслеживаемое могло закрыться —
	# перецепляемся на следующее активное.
	if tracked_id == "" or _find(tracked_id).get("done", true):
		_auto_track()

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
	var cur_order := _current_story().get("order", 999999)
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
