class_name ContextSteering
extends RefCounted

# Контекстное рулевое управление (context maps): вместо «луч уткнулся — доверни на 0.5»
# агент оценивает ВСЕ направления сразу и едет туда, где одновременно и к цели, и чисто.
#
# Почему так, а не тремя лучами с коррекцией: реактивная коррекция не видит, что справа
# тоже стена, и загоняет машину в угол — оттуда её вытаскивал отдельный режим «застрял».
# Здесь заблокированное направление просто никогда не выбирается, и выковыривать машину
# из угла обычно уже не приходится.
#
# interest — насколько направление ведёт к цели, danger — насколько оно опасно
# (препятствие, слишком крутой подъём, обрыв). Выбираем самое интересное из наименее
# опасных, а не лучшее по разнице: иначе агент лезет в стену, если за ней цель.

const SLOTS: int = 16

var interest: PackedFloat32Array = PackedFloat32Array()
var danger: PackedFloat32Array = PackedFloat32Array()

var _dirs: PackedVector3Array = PackedVector3Array()

func _init() -> void:
	interest.resize(SLOTS)
	danger.resize(SLOTS)
	for i in SLOTS:
		var a: float = TAU * float(i) / float(SLOTS)
		_dirs.append(Vector3(sin(a), 0.0, cos(a)))

# Интерес пересчитывается каждый кадр (16 скалярных произведений — копейки), а карта
# опасности переснимается реже: она зависит от мира, а не от текущего желания агента.
func clear_interest() -> void:
	for i in SLOTS:
		interest[i] = 0.0

func clear_danger() -> void:
	for i in SLOTS:
		danger[i] = 0.0

func begin() -> void:
	clear_interest()
	clear_danger()

func direction(i: int) -> Vector3:
	return _dirs[i]

# Тяга к направлению: чем ближе слот к желаемому курсу, тем интереснее.
func seek(dir: Vector3, weight: float = 1.0) -> void:
	var d: Vector3 = Vector3(dir.x, 0.0, dir.z)
	if d.length_squared() < 0.0001:
		return
	d = d.normalized()
	for i in SLOTS:
		interest[i] += maxf(0.0, _dirs[i].dot(d)) * weight

# Опасность в направлении. Мажем на соседние слоты (не только на точное попадание),
# иначе машина проскакивает впритирку к препятствию и цепляет его углом.
func add_danger(dir: Vector3, weight: float) -> void:
	var d: Vector3 = Vector3(dir.x, 0.0, dir.z)
	if d.length_squared() < 0.0001:
		return
	d = d.normalized()
	for i in SLOTS:
		var k: float = _dirs[i].dot(d)
		if k > 0.35:
			danger[i] = maxf(danger[i], weight * k)

func set_danger(i: int, weight: float) -> void:
	danger[i] = maxf(danger[i], weight)

# Самое интересное направление среди наименее опасных.
func choose(fallback: Vector3) -> Vector3:
	var min_danger: float = danger[0]
	for i in range(1, SLOTS):
		min_danger = minf(min_danger, danger[i])

	var best: int = -1
	var best_interest: float = -INF
	for i in SLOTS:
		if danger[i] > min_danger + 0.05:
			continue                      # есть направления безопаснее — это не рассматриваем
		if interest[i] > best_interest:
			best_interest = interest[i]
			best = i

	if best < 0 or best_interest <= 0.0001:
		return fallback
	return _dirs[best]
