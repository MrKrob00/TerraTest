class_name Contracts
extends Node
# КОНТРАКТЫ — заказы Системы на партию материала: «привези N штук такого-то к продавцу».
#
# Зачем. Продавец брал всё подряд и по одной цене, поэтому производственная цепочка работала
# в пустоту: собрал линию — и дальше просто копишь деньги, ни одного решения. Контракт даёт
# цепочке ЦЕЛЬ на ближайшие минуты («нужен куприт, значит еду на луг и гоню слитки»), а
# вместе с рынком (G.market_mods) — ещё и выбор: везти дорогое сейчас или закрывать заказ.
#
# КОНТРАКТ — ЭТО ОБЫЧНЫЙ КВЕСТ, а не вторая система заданий. Слот в журнале один и тот же
# (SLOT_ID), у него переписываются название, цель и событие. Иначе пришлось бы заводить второй
# трекер, второй список и второе окно, а игрок всё равно читает их как задания.
#
# Прогресс считает ПРОДАВЕЦ: он единственный знает, что материал действительно ушёл за деньги
# (seller.gd шлёт Q.report("sold_<вид>", n)). Считать «по складу» было бы неверно — руду можно
# набрать и просто возить с собой.

## Слот в журнале. Один: два контракта разом превращают журнал в доску объявлений, а этого мы
## уже избегали с событиями (Q.EVENT_SLOTS).
const SLOT_ID := "contract"
## Сколько даётся на выполнение. Восемь минут — это доехать до жилы, накопать и вернуться;
## меньше означало бы «успей, если фабрика уже стоит рядом с нужным металлом».
const TIME_LIMIT := 480.0
## Пауза между заказами. Заказ каждую минуту превратил бы игру в конвейер поручений.
const GAP_MIN := 90.0
const GAP_MAX := 180.0
## Наценка за срочность: платим ЗАМЕТНО больше, чем та же партия стоила бы у продавца, иначе
## контракт — это просто «продай, но по расписанию».
const PAY_MARKUP := 1.8

## Что заказывают и сколько. Руду просят помногу (она дешёвая и добывается быстро), слитки —
## вдвое меньше, компоненты — штучно. Виды берём из ЖИВЫХ таблиц G, а не списком здесь:
## список металлов там уже есть, и второй его копии рядом быть не должно.
const ORE_MIN := 8
const ORE_MAX := 18
const INGOT_MIN := 4
const INGOT_MAX := 10
const COMP_MIN := 2
const COMP_MAX := 4

var _gap: float = 30.0            # первый заказ — через полминуты после появления условий
var _left: float = 0.0            # сколько осталось на текущий заказ
var _active: bool = false
var _kind: String = ""

func _ready() -> void:
	add_to_group("contracts")

func _process(delta: float) -> void:
	if get_node_or_null("/root/Q") == null:
		return
	if _active:
		_tick_active(delta)
	else:
		_tick_idle(delta)

# ── Пока заказа нет ──────────────────────────────────────────────────────────
func _tick_idle(delta: float) -> void:
	if not _unlocked():
		return
	_gap -= delta
	if _gap <= 0.0:
		_offer()

## Контракты начинаются ПОСЛЕ того, как игрок собрал первую линию. До этого заказ на партию
## слитков — это требование того, чего игрок ещё не умеет: переплавлять руду нечем, а возить
## сырьё к продавцу вручную и называть это производством было бы обманом.
func _unlocked() -> bool:
	return G.quests_done.has("arc_line") or G.quests_done.has("arc_solvent")

func _offer() -> void:
	_kind = _pick_kind()
	var count: int = _count_for(_kind)
	var pay: int = int(round(G.base_price(_kind) * count * PAY_MARKUP))
	var title: String = "Contract: %s" % G.kind_name(_kind)
	var desc: String = "Sell %d × %s" % [count, G.kind_name(_kind)]
	# Событие своё на каждый вид: продавец шлёт ровно его (см. seller.gd).
	_write_slot(title, desc, count, "sold_" + _kind, pay)
	_active = true
	_left = TIME_LIMIT
	Dialogue.say("System", "%s. Payment %d$ on delivery — you have %d minutes."
			% [desc, pay, int(TIME_LIMIT / 60.0)])

## Заполнить слот-квест. Квеста может ещё не быть (первый заказ) — тогда создаём.
func _write_slot(title: String, desc: String, goal: int, event: String, pay: int) -> void:
	var q: Dictionary = Q.find_quest(SLOT_ID)
	if q.is_empty():
		Q.add_quest(SLOT_ID, title, desc, Q.Type.DAILY, goal, 99, event, pay, 20, 4)
		return
	q["title"] = title
	q["desc"] = desc
	q["goal"] = maxi(goal, 1)
	q["event"] = event
	q["progress"] = 0
	q["done"] = false
	q["skipped"] = false
	q["reward_money"] = pay
	Q.changed.emit()

# ── Пока заказ идёт ──────────────────────────────────────────────────────────
func _tick_active(delta: float) -> void:
	var q: Dictionary = Q.find_quest(SLOT_ID)
	if q.is_empty():
		_active = false
		return
	if bool(q.get("done", false)):
		_active = false
		_gap = randf_range(GAP_MIN, GAP_MAX)
		return
	_left -= delta
	if _left > 0.0:
		return
	# СРОК ВЫШЕЛ — заказ снимается, а не висит вечно. skip_quest закрывает его без награды и
	# говорит об этом сам; следующий придёт после обычной паузы.
	Q.skip_quest(SLOT_ID)
	_active = false
	_gap = randf_range(GAP_MIN, GAP_MAX)

# ── Что именно заказать ──────────────────────────────────────────────────────
func _pick_kind() -> String:
	var roll: float = randf()
	var metals: int = G.METAL_PRICE.size()
	if roll < 0.45:
		return "ore%d" % (randi() % metals)
	if roll < 0.85:
		return "m%d" % (randi() % metals)
	# Компонент ПЕРВОГО яруса: он собирается из двух металлов, то есть требует работающего
	# компонентного завода, но не цепочки из двух заводов подряд.
	return "c%d" % (randi() % mini(6, G.COMP_NAME.size()))

func _count_for(kind: String) -> int:
	if kind.begins_with("ore"):
		return randi_range(ORE_MIN, ORE_MAX)
	if kind.begins_with("m"):
		return randi_range(INGOT_MIN, INGOT_MAX)
	return randi_range(COMP_MIN, COMP_MAX)

## Сколько осталось времени — для UI (журнал показывает срок отдельной строкой).
func seconds_left() -> float:
	return maxf(_left, 0.0) if _active else 0.0

func active_quest_id() -> String:
	return SLOT_ID if _active else ""
