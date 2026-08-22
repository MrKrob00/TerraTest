class_name Perf
extends RefCounted

# ЗАМЕР ВРЕМЕНИ ПО СИСТЕМАМ.
#
# Нужен ровно затем, чтобы не гадать, «физика это или рендер» и «правда ли карта съедает
# процессор». На первый вопрос движок отвечает сам (Performance.TIME_PROCESS против
# TIME_PHYSICS_PROCESS против времени кадра), но он НЕ говорит, какой именно скрипт съел
# кадр: у него всё в куче. Отсюда самодельные метки — система оборачивает свой тик в
# now()/mark(), а HUD (панель по тапу в счётчик FPS) показывает таблицу.
#
# Мерить надо НА УСТРОЙСТВЕ и в бою: на редакторе те же сорок блоков лежат иначе, а
# просадку даёт как раз момент, когда машина разваливается.
#
# ВЫКЛЮЧЕННЫЙ замер стоит один статический вызов на систему за кадр и ноль обращений к
# часам: now() возвращает 0, mark() по нулю выходит сразу. Включать умеет только панель.

static var enabled: bool = false

static var _acc: Dictionary = {}       # ключ → мкс, накоплено за ТЕКУЩИЙ кадр
static var _shown: Dictionary = {}     # последний снимок (его и рисует панель)

## Начало замера. Ноль — «замер выключен», и mark() по такому значению ничего не делает:
## так вызовы можно оставить в коде навсегда, не пряча их за if.
static func now() -> int:
	return Time.get_ticks_usec() if enabled else 0

static func mark(key: String, t0: int) -> void:
	if t0 == 0:
		return
	_acc[key] = float(_acc.get(key, 0.0)) + float(Time.get_ticks_usec() - t0)

## Снимок за кадр + обнуление. Зовёт панель, один раз за кадр.
static func snapshot() -> Dictionary:
	_shown = _acc.duplicate()
	_acc.clear()
	return _shown

static func last() -> Dictionary:
	return _shown

static func reset() -> void:
	_acc.clear()
	_shown.clear()
