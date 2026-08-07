#!/usr/bin/env python3
"""Проверка кривых полезности для ИИ врага ДО переноса в GDScript.
Модель здесь обязана совпадать с enemy_brain.gd один в один."""

PATROL, INVESTIGATE, PURSUE, ENGAGE, FLANK, RETREAT, UNSTICK = range(7)
NAMES = "PATROL INVESTIGATE PURSUE ENGAGE FLANK RETREAT UNSTICK".split()

HYSTERESIS = 0.10


def clamp(v, a=0.0, b=1.0):
    return max(a, min(b, v))


def smoothstep(e0, e1, x):
    if e1 <= e0:
        return 0.0 if x < e0 else 1.0
    t = clamp((x - e0) / (e1 - e0))
    return t * t * (3.0 - 2.0 * t)


def confidence(p):
    return clamp(p["health"] * 0.8 + p["mobility"] * 0.2 + (p["power_ratio"] - 0.5) * 0.6)


def score_all(p):
    c = confidence(p)
    rng = max(p["range"], 1.0)
    dist = p["dist"]
    # 1 внутри дальности оружия, 0 заметно снаружи
    band = 1.0 - smoothstep(rng * 0.9, rng * 1.4, dist)
    outside = smoothstep(rng * 0.9, rng * 1.6, dist)
    los = 1.0 if p["los"] else 0.35

    s = [0.0] * 7
    # С целью в поле зрения патруль не нулевой, а тем весомее, чем меньше уверенность:
    # отбежавший подранок должен зализывать раны, а не разворачиваться в новую атаку.
    s[PATROL] = 0.20 if not p["has_target"] else 0.30 * (1.0 - c)
    s[INVESTIGATE] = 0.45 if (not p["has_target"] and p["has_memory"]) else 0.0
    if p["has_target"]:
        s[PURSUE] = 0.90 * c * c * max(outside, 1.0 - los)
        # Стоять в лобовом секторе цели плохо: чем сильнее она смотрит на нас, тем
        # менее привлекателен прямой бой и тем выгоднее уйти во фланг.
        s[ENGAGE] = 0.85 * c * band * los * (1.0 - 0.45 * p["facing_us"])
        s[FLANK] = 0.80 * c * band * p["facing_us"] * los
        retreat = clamp((1.0 - c) * 1.3 - 0.25)
        # Отбежали достаточно далеко — отступление больше не нужно, дальше решают
        # PATROL (зализать раны) или PURSUE (если уверенность вернулась).
        retreat *= 1.0 - smoothstep(rng * 1.5, rng * 3.0, dist)
        s[RETREAT] = retreat
    s[UNSTICK] = p["stuck"] * 1.10
    return s


def decide(p, current=PATROL):
    s = score_all(p)
    s[current] += HYSTERESIS
    best = max(range(7), key=lambda i: s[i])
    return best, s


def make(**kw):
    p = dict(has_target=False, has_memory=False, dist=99.0, range=12.0, health=1.0,
             mobility=1.0, power_ratio=0.5, los=True, stuck=0.0, facing_us=0.0)
    p.update(kw)
    return p


CASES = [
    ("нет цели, нет памяти",                 make(),                                                              PATROL),
    ("нет цели, помним где была",            make(has_memory=True),                                               INVESTIGATE),
    ("цель втрое дальше дальности",          make(has_target=True, dist=36),                                      PURSUE),
    ("цель в дальности, к нам боком",        make(has_target=True, dist=9, facing_us=0.1),                        ENGAGE),
    ("цель в дальности, смотрит на нас",     make(has_target=True, dist=9, facing_us=0.95),                       FLANK),
    ("бой, здоровья 25%",                    make(has_target=True, dist=9, health=0.25),                          RETREAT),
    ("отбежал далеко, здоровья 25%",         make(has_target=True, dist=40, health=0.25),                         PATROL),
    ("подлечился до 90%, цель далеко",       make(has_target=True, dist=40, health=0.9),                          PURSUE),
    ("застрял",                              make(has_target=True, dist=9, stuck=1.0),                            UNSTICK),
    ("цель в дальности, но за скалой",       make(has_target=True, dist=9, los=False),                            PURSUE),
    ("сбили половину колёс, бой",            make(has_target=True, dist=9, mobility=0.3, health=0.5),             RETREAT),
    ("сильно превосходим, здоровья 40%",     make(has_target=True, dist=9, health=0.4, power_ratio=0.9),          ENGAGE),
    ("здоров, цель смотрит в упор",          make(has_target=True, dist=5, facing_us=1.0),                        FLANK),
    ("здоров, цель далеко и смотрит",        make(has_target=True, dist=40, facing_us=1.0),                       PURSUE),
]

ok = True
for name, p, want in CASES:
    got, s = decide(p)
    mark = "ok " if got == want else "ПЛОХО"
    if got != want:
        ok = False
    print(f"{mark} {name:38s} -> {NAMES[got]:12s} (ждали {NAMES[want]})")
    if got != want:
        print("      ", {NAMES[i]: round(v, 3) for i, v in enumerate(s) if v > 0.001})

print()
print("уверенность: полное здоровье =", round(confidence(make()), 3),
      "| 30% хп =", round(confidence(make(health=0.3)), 3),
      "| 30% хп и вдвое слабее =", round(confidence(make(health=0.3, power_ratio=0.25)), 3))
print("ВСЕ СЦЕНАРИИ ПРОШЛИ" if ok else "ЕСТЬ РАСХОЖДЕНИЯ")
