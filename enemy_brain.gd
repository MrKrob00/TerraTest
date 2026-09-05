class_name EnemyBrain
extends RefCounted

# Оценочная часть ИИ врага, вынесенная из машины: чистые функции без узлов и физики.
# Каждое поведение получает оценку полезности 0..1 от «восприятия» (Dictionary), берётся
# максимум. Это не машина состояний: нет жёстких переходов, которые надо чинить по одному —
# поведение само меняется, когда меняется обстановка.
#
# Кривые проверены прогоном сценариев до переноса сюда; при правке коэффициентов
# сценарии надо перепроверять, иначе легко сломать один случай, чиня другой.
#
# Восприятие (все доли — 0..1):
#   has_target   есть живая цель
#   has_memory   помним, где цель была в последний раз
#   dist         расстояние до цели в метрах
#   range        СВОЯ эффективная дальность оружия в метрах
#   health       доля уцелевшего HP всех блоков
#   mobility     подвижность: сколько колёс осталось и сколько из них на земле
#   power_ratio  своя огневая мощь / (своя + вражеская); 0.5 = поровну
#   los          цель видна напрямую
#   stuck        насколько застряли
#   facing_us    насколько цель развёрнута носом на нас
#   flank_spent  сколько «заряда» фланга израсходовано (0 — свежий, 1 — выдохся)

enum Act { PATROL, INVESTIGATE, PURSUE, ENGAGE, FLANK, RETREAT, UNSTICK }
const ACT_COUNT: int = 7

# Бонус текущему поведению. Без него ИИ дрожит между двумя почти равными вариантами.
const HYSTERESIS: float = 0.10

static func _smoothstep(e0: float, e1: float, x: float) -> float:
	if e1 <= e0:
		return 0.0 if x < e0 else 1.0
	var t: float = clampf((x - e0) / (e1 - e0), 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)

# «Уверенность» — единственный источник осторожности. Здоровье весит больше всего,
# подвижность и перевес в огне корректируют. Именно она заставляет врага отступать,
# когда ему плохо, и возвращаться, когда он подлечился, — без отдельных флагов и таймеров.
static func confidence(p: Dictionary) -> float:
	return clampf(
		float(p["health"]) * 0.8
		+ float(p["mobility"]) * 0.2
		+ (float(p["power_ratio"]) - 0.5) * 0.6,
		0.0, 1.0)

static func score_all(p: Dictionary) -> PackedFloat32Array:
	var c: float = confidence(p)
	var rng: float = maxf(float(p["range"]), 1.0)
	var dist: float = float(p["dist"])
	var facing: float = float(p["facing_us"])
	# 1 внутри дальности своего оружия, 0 заметно снаружи.
	var band: float = 1.0 - _smoothstep(rng * 0.9, rng * 1.4, dist)
	var outside: float = _smoothstep(rng * 0.9, rng * 1.6, dist)
	var los: float = 1.0 if bool(p["los"]) else 0.35

	var s: PackedFloat32Array = PackedFloat32Array()
	s.resize(ACT_COUNT)

	# С целью в поле зрения патруль не нулевой, а тем весомее, чем меньше уверенность:
	# отбежавший подранок должен зализывать раны, а не разворачиваться в новую атаку.
	s[Act.PATROL] = 0.20 if not bool(p["has_target"]) else 0.30 * (1.0 - c)
	s[Act.INVESTIGATE] = 0.45 if (not bool(p["has_target"]) and bool(p["has_memory"])) else 0.0

	if bool(p["has_target"]):
		# В квадрате: неуверенный враг не бросается в погоню через полкарты.
		# Потеря линии огня тоже гонит вперёд — надо выйти из-за укрытия.
		s[Act.PURSUE] = 0.90 * c * c * maxf(outside, 1.0 - los)
		# Стоять в лобовом секторе цели плохо: чем сильнее она смотрит на нас, тем
		# менее привлекателен прямой бой и тем выгоднее уйти во фланг.
		s[Act.ENGAGE] = 0.85 * c * band * los * (1.0 - 0.45 * facing)
		# Фланг — короткий МАНЁВР, а не режим боя. Раньше он самоподдерживался: игрок в бою
		# всегда разворачивается на врага, facing_us держался у единицы, и ФЛАНГ (0.80)
		# стабильно перебивал БОЙ (0.85·0.55 ≈ 0.47) — враг наматывал круги весь бой и драка
		# превращалась в догонялки. Теперь база ниже, а израсходованный заряд (flank_spent,
		# копится в машине, пока манёвр идёт) гасит оценку, и враг обязан выйти на размен.
		s[Act.FLANK] = 0.62 * c * band * facing * los * (1.0 - float(p["flank_spent"]))
		var retreat: float = clampf((1.0 - c) * 1.3 - 0.25, 0.0, 1.0)
		# Отбежали достаточно далеко — отступление больше не нужно, дальше решают
		# PATROL (зализать раны) или PURSUE (если уверенность вернулась).
		retreat *= 1.0 - _smoothstep(rng * 1.5, rng * 3.0, dist)
		s[Act.RETREAT] = retreat

	# Выбирается поверх всего: застрявший враг не воюет, он сначала выбирается.
	s[Act.UNSTICK] = float(p["stuck"]) * 1.10
	return s

static func decide(p: Dictionary, current: int) -> int:
	var s: PackedFloat32Array = score_all(p)
	if current >= 0 and current < s.size():
		s[current] += HYSTERESIS
	var best: int = 0
	for i in range(1, s.size()):
		if s[i] > s[best]:
			best = i
	return best

static func act_name(a: int) -> String:
	return ["ПАТРУЛЬ", "ПОИСК", "ПРЕСЛЕДОВАНИЕ", "БОЙ", "ФЛАНГ", "ОТХОД", "ВЫБИРАЕТСЯ"][a]
