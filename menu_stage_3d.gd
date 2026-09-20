extends Node3D
## Menu backdrop: a REAL fight on a REAL map - THE SAME CHUNKED TERRAIN THE GAME RUNS ON, and the
## game's own enemy scenes with their physics, AI and weapons. The two machines are of DIFFERENT factions,
## or enemy_vehicle._is_enemy does not see them as enemies at all.
##
## ROUND LIFECYCLE. A round runs ROUND_TIME, and only then does the next map start generating - the
## fight continues meanwhile. ОДНА КАРТА НА СЕССИЮ: раунд переезжает по ней (_move_round), а не
## round is removed first and the new one added a frame later, or machines spawn onto collision
## that is about to vanish.
##
## A DEATH DOES NOT TOUCH THE MAP: a kill takes seconds and generation tens of them. A machine that
## dies or loses its last gun is replaced on the spot (_replace_fallen).
##
## Demo machines carry `demo = true`: no rewards, no quest progress, no retreat - a backdrop where
## both sides drive apart shows nothing.
##
## THERE IS NO AUTHORED FIRST MAP ANY MORE, and the baked map it used to be is gone with it. It
## existed because the old terrain needed a minute to compute a window of heights, so the menu
## would have opened on sky; the chunked terrain builds only what the camera can see and is up in
## a moment. Every round, the first one included, is generated the same way - one code path
## instead of two, and no 256 KB of baked heights in the repository that nobody could regenerate
## without the dock. Until a map is up the stage hides behind `%Backdrop`, which covers the 3D and
## NOT the interface.

const ENEMY_SCENE := preload("res://enemy.tscn")
const MAP_SCRIPT := preload("res://addons/LiteTerrain/chunk_terrain.gd")

## How much ground the menu looks at. A fight needs a couple of hundred metres; the chunked terrain
## builds by distance rather than by map size, so this is the window the SEED IS SCORED over - the
## patch the camera will actually show.
const MAP_SIZE := 256
## What the menu map draws and what it waits for. Both are a fraction of the game's (1400 / 192):
## the camera hangs over one fight and never travels, so ground past a few hundred metres is
## horizon nobody looks at, and every metre of it is noise computed on the phone that has to run
## the menu.
##
## THE WAIT IS AS SHORT AS IT CAN BE (measured): with ready_view at 128 the backdrop sat for ten
## seconds, of which six were the view stage; at 32 the whole wait is the starting ring and
## nothing else. What is beyond it streams in behind the fade, and the camera is looking at the
## machines anyway. Since the noise went native the whole wait is 1.1 s, so there is room to raise
## this again if the first frame ever looks too bare — but bare is not what it looks.
const MENU_VIEW := 320.0
## СКОЛЬКО ЗЕМЛИ ГОТОВО ДО ПОКАЗА, и почему это два разных числа.
##
## Было одно, 32 м, а камера видит на MENU_VIEW — 320. Поэтому карта доезжала на глазах: игрок
## видел, как чанки достраиваются вокруг уже идущего боя.
##
## Но платят за это ожидание разные люди. ФОНОВУЮ карту готовит предыдущий раунд, и все тридцать
## секунд она никому не мешает: там ждать можно щедро. ПЕРВУЮ ждёт сам игрок, глядя на заставку,
## и каждая секунда его.
##
## Замерено: 32 м — 0.41 с, 96 — 0.94, 160 — 2.10, 224 — 3.02.
## Карта теперь ОДНА на сессию (раунд переезжает по ней, см. _move_round), то есть это ожидание
## платится единожды, при входе в меню, и второго такого за сессию не будет.
const MENU_READY_VIEW := 96.0
## Everything the round can reach stays resident: the map is small and lives half a minute, so
## dropping and rebuilding chunks inside it would be work for nothing.
const MENU_KEEP := 256.0
const ROUND_TIME := 30.0
## Distance between the two machines at the start: they must see each other (enemy vision is 40 m)
## and still have room to manoeuvre.
const START_GAP := 34.0
## Builds are the same enemy presets the game sends (blocks.gd): scout to siege.
const PRESETS := [5, 6, 7, 8, 9, 10]
## How long a fresh machine is left alone before it is judged disarmed. Blocks are assembled in the
## machine's own _ready and the weapons appear over the frames after that: without the grace every
## spawn counts as weaponless in the frame it is born and is replaced at once, forever.
const ARM_GRACE := 3.0
## How long the backdrop takes to cover the stage before a round is swapped. Long enough to read as
## a fade, short enough that nobody waits for it.
const SWAP_FADE := 0.4

## Camera: an orbit around the middle of the fight, high enough to see both machines and the ground
## between them.
const CAM_HEIGHT := 26.0
const CAM_DIST := 34.0
const CAM_ORBIT := 0.06          # rad/s
## Never closer than this to whatever is directly under the camera.
const CAM_CLEARANCE := 8.0

## SEEDS ARE AUDITIONED, NOT TAKEN AS THEY COME. The landform knobs are the dock's Natural preset,
## but the preset says nothing about WHERE the map lands: the biome regions are hundreds of metres
## across, and a 256 m window dropped at random sits inside one of them - a plain desert, or the
## fringe of a canyon where the mask is a tenth and the carve comes out as scratches a couple of
## metres deep. That is not the preset being different, it is the window missing the landscape.
##
## So a handful of seeds are scored on their biome masks (pure maths, no terrain) and the best one
## is generated. What "best" means is in _score_seed.
const SEED_TRIES := 12
## Metres between score samples. The masks are hundreds of metres wide; sampling finer only costs
## time, and this runs while the backdrop is up.
const SCORE_STEP := 24.0
## The fight happens within this radius of the origin - it must be drivable ground, not a gorge.
const CLEAR_RADIUS := 48.0
## Wanted share of the window: canyon OVER MEADOW (the ground there is high enough for a
## carve to have somewhere to go), and mountains for a skyline.
const WANT_CANYON := 0.22
const WANT_MOUNTAIN := 0.20

var _rng := RandomNumberGenerator.new()
var _t: float = 0.0
var _round_t: float = 0.0
@onready var _cam: Camera3D = %MenuCamera
@onready var _machines_root: Node3D = %Machines
@onready var _backdrop: Control = %Backdrop

var _map: Node3D = null          # the map the fight runs on
var _fighters: Array = []
## Per fighter, in the same order: when it was spawned and whether it has ever had a gun. Both are
## only there to tell "still being assembled" from "shot to pieces" (see ARM_GRACE).
var _born: Array = []
var _armed: Array = []
## Angle of the line the pair stands on. Kept for the round, so a replacement machine appears where
## its predecessor stood instead of somewhere behind the camera.
var _ring_ang: float = 0.0
## ГДЕ ИДЁТ БОЙ. Раунд не строит новую карту, он ПЕРЕЕЗЖАЕТ по одной и той же на новое место.
## Мир бесконечный и процедурный: в двухстах метрах от прежней точки другая земля, а строить её
## заново незачем — половина уже в памяти (keep_radius), остальное дотекает, пока держится фейд.
var _fight_centre: Vector3 = Vector3.ZERO
## Насколько далеко переезжает следующий раунд. Двести метров — это уже другой пейзаж, но всё ещё
## внутри того, что нода рисует (MENU_VIEW 320), то есть большая часть пути уже построена.
const ROUND_HOP := 200.0
var _swapping: bool = false
## The fight is off in the settings: no map, no machines, the backdrop is the menu.
var _off: bool = false
## REGIONS OF THE MENU'S WORLD, on the stage itself. They used to be read off the map node authored
## in the scene; with that node gone the resource has to live somewhere that is not a map, and the
## stage is what owns the rounds. Duplicated per map - the generator writes the seed's mask offset
## into it.
@export var biomes: TerrainBiomes = null

## EVERY ENTRY INTO A ROUND GETS A NUMBER, and that number is the only way to cancel one. A GDScript
## coroutine cannot be aborted: the one waiting for terrain WILL get it and carry on - into a stage
## that was switched off meanwhile, or re-opened, or already has a map. Then two of them spawn two
## pairs of machines onto two maps. Stale number = leave, and take whatever you built with you.
var _era: int = 0
## A round is still opening: the tick may not touch the timer or start a generation. Without it the
## round timer, sitting at zero, started the NEXT map in the menu's very first frame - and the first
## round ended a few seconds later, the moment that generation landed.
var _opening: bool = false

func _ready() -> void:
	_rng.randomize()
	set_process(true)       # the camera works while the first map is still being generated
	_off = G.menu_battles != true
	if _off:
		_backdrop.set_idle(true)
		_shutdown()
		return
	_backdrop.cover(true)
	await _open_round()

## The settings switch. Turning it off clears the stage in the same frame; turning it on opens a
## round from scratch, backdrop and all, exactly as if the menu had just been entered.
func set_battles(on: bool) -> void:
	if on != _off:
		return          # already in that state
	_off = not on
	if _off:
		_backdrop.set_idle(true)
		_shutdown()
		return
	_backdrop.set_idle(false)
	_backdrop.cover(true)
	await _open_round()

## Take the stage down: everything the fight owns goes. Left standing, a map would go on streaming
## terrain behind an opaque backdrop, which is the exact cost the switch exists to remove.
func _shutdown() -> void:
	_era += 1               # whatever is waiting on terrain right now is no longer ours
	_opening = false
	_swapping = false
	for c in _machines_root.get_children():
		_machines_root.remove_child(c)
		c.queue_free()
	_fighters.clear()
	_born.clear()
	_armed.clear()
	for m in [_map]:
		_discard(m)
	_map = null

## Is the round that started with this number still the current one? A coroutine asks after every
## await; false means it must leave without touching the stage.
func _live(era: int) -> bool:
	return era == _era and not _off

## Take a map off generation and out of the tree. ONE DOOR, because a map can be dropped from four
## places - the round reset, the switch, a cancelled coroutine, a prepared map nobody needed - and
## every one of them has to stop its generation first: the worker rows write into buffers that live
## inside the node being freed.
func _discard(m: Node3D) -> void:
	if not is_instance_valid(m):
		return
	if m.has_method("stop_generation"):
		m.stop_generation()
	# И СТРИМИНГ КОЛЛИЗИИ ТОЖЕ ВЫКЛЮЧАЕМ, ДО ОСВОБОЖДЕНИЯ. Рельеф держит плитки как владельцев
	# форм и добавляет-убирает их по ходу; узел, который освобождают прямо посреди этого, даёт
	# ошибки «shapes.has(owner)» пачками. Генерацию мы останавливаем строкой выше по той же
	# причине — коллизия просто вторая половина того же правила.
	if m.has_method("set_collision_streaming"):
		m.set_collision_streaming(false)
	var parent: Node = m.get_parent()
	if parent != null:
		parent.remove_child(m)
	m.queue_free()

# ── Rounds ───────────────────────────────────────────────────────────────────
## Open a round: generate a map, stand two machines on it, start the clock.
func _open_round() -> void:
	_era += 1
	var era: int = _era
	_opening = true
	# The map is a LOCAL until the round is actually open. Assigning it up front let the tick see a
	# map that was still loading, run its timer down and start generating the next one before the
	# first had begun.
	var m: Node3D = await _make_map(true)
	if not _live(era):
		# Switched off, or opened again, while we waited. Take our map with us - the stage has moved
		# on without it, and nobody else holds a reference.
		_discard(m)
		return
	if m == null:
		# NOTHING TO STAND ON - the map never became ready (the generator gave up, the node died).
		# Settling into the plain backdrop is the honest end: it is a finished picture rather than a
		# progress plate that never fills, and the settings switch can ask for a round again.
		push_warning("menu: no map for the round; the backdrop stays up")
		_opening = false
		_backdrop.cover(false)
		return
	_enable_collision(m)
	_map = m
	_spawn_pair()
	# ТА ЖЕ ПРОВЕРКА, ЧТО И У СВОПА, и забыть её здесь стоило ровно того, что игрок и увидел:
	# первый раунд открывался белым кадром без машин, а со второй генерации всё было нормально.
	# Первый раунд идёт своим путём (_open_round), своп — своим (_swap_round), и починка одного
	# не чинит второй. Камера тоже измеряет высоту земли под точкой взгляда: пока её нет, она
	# уезжает в пустоту.
	await _await_ground(era)
	if not _live(era):
		_opening = false
		return
	_reseat_fighters()
	_round_t = ROUND_TIME
	# ФЛАГ СНИМАЕТСЯ ПОСЛЕДНИМ, И ЭТО НЕ ФОРМАЛЬНОСТЬ. Раунд не открыт, пока не открыт. Сняв его
	# до ожидания земли, я дал тику увидеть готовую карту с обнулённым _round_t — и тот сразу
	# начинал генерировать СЛЕДУЮЩУЮ, прямо поверх открывающейся. Две карты разом дают ошибки
	# владельцев коллизии и белый кадр вместо боя.
	_opening = false
	_move_camera()          # first frame already looks at the fight, not at the origin
	_backdrop.reveal()

## A map generated from its own seed. `follow_world_settings = false` keeps it away from G: the
## slot's seed belongs to the save, this one is scenery.
func _make_map(report: bool = false) -> Node3D:
	# The biomes are the STAGE's, copied: the regions, their scales and the terrace height all live
	# in that resource. The copy is per map because the generator writes the seed's mask offset into
	# it - one shared resource would mean the map being prepared in the background moving the
	# regions of the map currently on screen.
	var b: TerrainBiomes = (biomes.duplicate() as TerrainBiomes) if biomes != null \
			else TerrainBiomes.new()
	var m := StaticBody3D.new()
	m.set_script(MAP_SCRIPT)
	m.follow_world_settings = false
	m.forced_seed = _pick_seed(b)
	m.biomes = b
	# NO LANDFORM KNOBS HERE. The chunked terrain builds on the natural preset itself
	# (chunk_terrain._proc_params), which is the same preset the game's own world uses, so the menu
	# shows the same land the player is about to drive into. Setting them from here would be a second
	# copy of those numbers and, sooner or later, a different landscape behind the same menu.
	m.view_distance = MENU_VIEW
	m.ready_view = MENU_READY_VIEW
	m.keep_radius = MENU_KEEP
	# ЗЕМЛИ ДО ПОКАЗА — ОДИН ЧАНК В КАЖДУЮ СТОРОНУ. Игре нужны восемьдесят метров во все стороны
	# от машины, которая сейчас поедет; здесь две машины стоят в тридцати метрах от начала
	# координат и дерутся на месте, а каждый лишний чанк — это секунда под затемнением.
	m.ready_ring = 1
	# COLLISION OFF FROM THE START: while this map builds its chunks it stands at the same origin as
	# the one on screen, and two heightfields under the same machines fight each other. The flag is
	# what `set_collision_streaming` checks, so the node's own _ready cannot switch it on behind our
	# back either. It goes on in the frame this map becomes the visible one (_enable_collision).
	m.enable_streaming_collision = false
	add_child(m)
	if not await _wait_terrain(m, report):
		_discard(m)
		return null
	return m

## The map has become the one on screen: it is the only one allowed to carry collision.
func _enable_collision(m: Node3D) -> void:
	if not is_instance_valid(m):
		return
	m.enable_streaming_collision = true
	m.set_collision_streaming(true)

## The seed whose window shows the most landscape. Scoring reads the biome masks only - no heights,
## no threads - so auditing a dozen of them costs a few milliseconds, once per round.
func _pick_seed(b: TerrainBiomes) -> int:
	var best: int = 0
	var best_score: float = -1.0
	for i in SEED_TRIES:
		var s: int = _rng.randi() | 1
		b.mask_offset = TerrainBiomes.offset_for_seed(s)
		var sc: float = _score_seed(b)
		if sc > best_score:
			best_score = sc
			best = s
	return best

## What makes a menu map worth looking at:
##
## - CANYON COUNTRY OVER MEADOW. The carve is measured down from the local ground and stops at a
##   floor, so in the desert - which the preset flattens - there is barely anything above that floor
##   to cut into, and the result is the scratch the eye reads as "no canyons". Over meadow the same
##   region cuts real walls. So canyon mask alone is not the score; canyon over meadow is.
## - SOME MOUNTAIN for a skyline, but not a window full of it.
## - A CLEAR MIDDLE. The machines are dropped at the origin and have to drive; a gorge or a peak
##   there is a fight nobody can see.
func _score_seed(b: TerrainBiomes) -> float:
	var half: float = float(MAP_SIZE) * 0.5
	# One Callable for the whole sweep: building it per sample allocates thousands of them.
	var nz: Callable = b.noise
	var canyon: float = 0.0
	var mountain: float = 0.0
	var blocked: float = 0.0
	var n: int = 0
	var x: float = -half
	while x < half:
		var z: float = -half
		while z < half:
			var wp := Vector2(x, z)
			var c: float = b.canyon_mask(wp, nz)
			var mt: float = b.mountain_mask(wp, nz)
			canyon += c * b.meadow_mask(wp, nz)
			mountain += mt
			if wp.length_squared() <= CLEAR_RADIUS * CLEAR_RADIUS:
				blocked = maxf(blocked, maxf(c, mt))
			n += 1
			z += SCORE_STEP
		x += SCORE_STEP
	if n == 0:
		return 0.0
	var cs: float = _near(canyon / float(n), WANT_CANYON)
	var ms: float = _near(mountain / float(n), WANT_MOUNTAIN)
	return cs + ms * 0.7 + (1.0 - blocked) * 1.5

## 1 at the wanted share, falling to 0 at zero and at twice it. A plain distance would rank an empty
## window the same as one covered edge to edge.
func _near(v: float, want: float) -> float:
	return clampf(1.0 - absf(v - want) / maxf(want, 0.001), 0.0, 1.0)

## Wait until a map has its terrain up. Polled rather than awaiting terrain_ready: a map that never
## finishes (empty heights, a freed node) would leave this coroutine hanging forever, and with it
## the whole round loop.
##
## `report` sends what the map is doing to the backdrop. Only the map the player is WAITING for
## reports: the one generated in the background is not worth a progress bar, the fight is on screen.
func _wait_terrain(m: Node3D, report: bool = false) -> bool:
	var guard: int = 0
	while is_instance_valid(m) and not m.terrain_is_ready and guard < 3600:
		if report:
			# THE METER RUNS, IT DOES NOT FILL. The old map reported a fraction because it computed
			# a whole window of heights and knew how far along it was; the chunked one builds the
			# chunks the camera asks for and has no total to be a fraction OF. A bar that cannot be
			# honest is worse than a meter that just says "working".
			_backdrop.set_progress(tr("reading terrain"), -1.0)
		await get_tree().process_frame
		guard += 1
	if is_instance_valid(m) and m.terrain_is_ready:
		return true
	push_warning("menu: terrain never became ready (%d frames)" % guard)
	return false
func _spawn_pair() -> void:
	_ring_ang = _rng.randf() * TAU
	_fighters = [null, null]
	_born = [0.0, 0.0]
	_armed = [false, false]
	for side in 2:
		_spawn_fighter(side)
	_retarget()

## One machine on its side of the line, with a random build. Also the replacement for a machine that
## died or lost its guns - which is why the side, and not the machine, is what this takes.
func _spawn_fighter(side: int) -> void:
	var e: Node3D = ENEMY_SCENE.instantiate()
	# The build is set BEFORE add_child: blocks assembles the machine in its own _ready.
	var blocks := e.get_node_or_null("blocks")
	if blocks != null and "layout_preset" in blocks:
		blocks.layout_preset = int(PRESETS[_rng.randi() % PRESETS.size()])
	# DIFFERENT factions, otherwise they do not see each other as enemies at all. Neither is 0,
	# so neither of them counts as the player's.
	e.set("faction", 1 + side)
	e.set("demo", true)
	_machines_root.add_child(e)
	var dir := Vector3(cos(_ring_ang), 0.0, sin(_ring_ang))
	var p: Vector3 = _fight_centre + (dir * (START_GAP * 0.5) if side == 0 else dir * (-START_GAP * 0.5))
	# A REPLACEMENT LANDS BESIDE THE MACHINE THAT IS STILL STANDING, not on the spot the round
	# started from: a survivor that has driven off would otherwise get an opponent a hundred metres
	# away, and the camera - which frames the middle of the pair - would show neither of them.
	var other: Variant = _fighters[1 - side] if _fighters.size() == 2 else null
	if is_instance_valid(other):
		var op: Vector3 = (other as Node3D).global_position
		p = Vector3(op.x, 0.0, op.z) + dir * (START_GAP if side == 0 else -START_GAP)
	e.global_position = Vector3(p.x, _ground_y(p) + 6.0, p.z)   # dropped in, like in game
	# FACING THE OPPONENT, not whatever rotation the scene was saved with. Nothing turned these
	# machines before, so which way they landed was luck: one of them regularly started the round
	# with its back to the fight, spent the first seconds turning around and took hits for free.
	# A demo fight that opens with a free beating reads as a broken fight.
	#
	# Forward is -Z (look_at points that axis), which is the same forward the rest of the project
	# uses. The look point is level with the machine: aiming at ground height would tilt it.
	var face: Vector3 = Vector3(-dir.x, 0.0, -dir.z) if side == 0 else dir
	if face.length_squared() > 0.0001:
		e.look_at(e.global_position + face, Vector3.UP)
	if e is RigidBody3D:
		(e as RigidBody3D).linear_velocity = Vector3.ZERO
		(e as RigidBody3D).angular_velocity = Vector3.ZERO
		# ЗАМОРОЖЕНЫ, ПОКА ПОД НИМИ НЕТ ЗЕМЛИ. Плитки коллизии режутся ВОКРУГ ТЕЛ и на свежей карте
		# ждут в очереди за первичной постройкой мешей: замер дал НОЛЬ плиток на протяжении ста
		# пятидесяти кадров, и машины всё это время просто падали — к концу на четырнадцать метров
		# под землю. Снаружи это «враги застревают в карте».
		#
		# Размораживает _await_ground, когда плитки появились.
		(e as RigidBody3D).freeze = true
	_fighters[side] = e
	_born[side] = _t
	_armed[side] = false

## Locked on each other and relentless: no searching, no losing interest, no walking away.
func _retarget() -> void:
	for i in _fighters.size():
		var a = _fighters[i]
		var b = _fighters[1 - i]
		if is_instance_valid(a) and is_instance_valid(b) and a.has_method("assign_target"):
			a.assign_target(b, true)

## A machine that is gone, or has been stripped of its last gun, is REPLACED - the round is not cut
## short for it. A fresh machine is left alone for ARM_GRACE while it assembles itself; after that a
## build without a single weapon is a broken one and goes the same way.
func _replace_fallen() -> void:
	var changed: bool = false
	for side in _fighters.size():
		var f = _fighters[side]
		var alive: bool = is_instance_valid(f)
		if alive and _weapon_count(f as Node3D) > 0:
			_armed[side] = true
			continue
		if alive and not _armed[side] and _t - float(_born[side]) < ARM_GRACE:
			continue                      # still putting itself together
		if alive:
			(f as Node).queue_free()
		_spawn_fighter(side)
		# И ПОСАДИТЬ ЕЁ. Открытие раунда сажает пару само (_await_ground → _reseat_fighters);
		# у замены такого шага не было вовсе, и она оставалась замороженной в воздухе.
		_land_fighter(side, _era)
		changed = true
	if changed:
		_clear_debris()
		_retarget()

## ОБЛОМКИ УБИТОЙ МАШИНЫ НЕ ОСТАЮТСЯ ЛЕЖАТЬ. Погибая, машина роняет свои блоки в мир, и в меню
## они падают сюда же, под _machines_root. За раунд с несколькими заменами их набирается столько,
## что фон превращается в свалку, а каждый блок — это физическое тело, которое ещё и просит у
## рельефа плитку коллизии под собой.
##
## Чистим В МОМЕНТ ЗАМЕНЫ, а не по таймеру: замена и есть признак того, что бой пошёл дальше и
## старые обломки уже ни о чём не рассказывают. Живые бойцы, понятно, не трогаются.
func _clear_debris() -> void:
	for c in _machines_root.get_children():
		if _fighters.has(c):
			continue
		_machines_root.remove_child(c)
		c.queue_free()

func _ground_y(p: Vector3) -> float:
	if _map != null and is_instance_valid(_map) and _map.has_method("terrain_height_at"):
		return float(_map.terrain_height_at(p))
	return 0.0

## ПЕРЕЕЗД РАУНДА: КАРТА ОДНА НА ВСЮ СЕССИЮ, МЕНЯЕТСЯ МЕСТО.
##
## Раньше каждый раунд строил НОВУЮ карту, а старую выбрасывал. Отсюда шло всё сразу: земля
## доезжала на глазах, на свопе сыпались ошибки владельцев форм коллизии, а машины падали с
## шести метров над высотой, которую спрашивали у карты, ещё не построенной в той точке, —
## и садились внутрь холма. Игрок назвал это «враги застревают в карте».
##
## Мир бесконечный и процедурный, значит новую землю искать не нужно — до неё можно доехать.
## Раунд переезжает на ROUND_HOP метров: там другой пейзаж, но это та же нода, половина пути
## уже в памяти (keep_radius), а высота в любой точке известна ВСЕГДА — terrain_height_at
## отвечает по генератору, а не по построенным мешам. Поэтому машины садятся на землю, а не в неё.
##
## Ничего не создаётся и не освобождается: ни карты, ни коллизии, ни владельцев форм.
func _move_round() -> void:
	if _swapping:
		return
	var era: int = _era
	_swapping = true
	_backdrop.cover(false)
	await get_tree().create_timer(SWAP_FADE).timeout
	if not _live(era):
		_swapping = false
		return
	# Машины, их обломки и эффекты прошлого раунда уходят целиком.
	_fighters.clear()
	_born.clear()
	_armed.clear()
	for c in _machines_root.get_children():
		_machines_root.remove_child(c)
		c.queue_free()
	await get_tree().process_frame
	if not _live(era):
		_swapping = false
		return
	# Новое место: направление случайное, расстояние постоянное. Случайная ДЛИНА дала бы раунды,
	# которые визуально не отличаются от предыдущего.
	var ang: float = _rng.randf() * TAU
	_fight_centre += Vector3(cos(ang), 0.0, sin(ang)) * ROUND_HOP
	_spawn_pair()
	_move_camera()          # камера уезжает туда же, и рельеф начинает достраивать вокруг неё
	await _await_ground(era)
	if not _live(era):
		_swapping = false
		return
	_reseat_fighters()
	_round_t = ROUND_TIME
	_backdrop.reveal()
	_swapping = false

## Земля под машинами нарезана. Ограничено по времени: если коллизия почему-то не поедет, раунд
## всё равно обязан начаться — пустой экран хуже машины, просевшей на полметра.
##
## Переезд ждёт не только плитки под машинами, но и меши вокруг: раньше карта на новом месте была
## построена заранее целиком, теперь она дотекает по ходу переезда.
const GROUND_WAIT_MAX := 4.0
## Одной плитки мало: первая появляется прямо под машиной, а рядом ещё пусто.
const GROUND_TILES_MIN := 3

## ПОСАДКА ПОСЛЕ ОЖИДАНИЯ. Машины роняются с шести метров, а плитки коллизии под ними режутся
## ВОКРУГ ТЕЛ, то есть появляются уже после спавна. В это окно машина успевает провалиться сквозь
## землю и остаётся внутри холма — игрок назвал это «враги застревают в карте». Замер на движке:
## в первом раунде тонули обе.
##
## Поэтому, дождавшись земли, ставим их на неё явно. Высота берётся у ГЕНЕРАТОРА (terrain_height_at
## отвечает по точке, а не по построенным мешам), значит она верна и там, куда карта ещё дотекает.
func _reseat_fighters(unfreeze: bool = true) -> void:
	for f in _fighters:
		_seat_one(f, unfreeze)

## Одна машина на землю. Отдельной функцией, потому что садятся они двумя путями: парой в начале
## раунда и поодиночке при замене, — а высота, обнуление скоростей и снятие заморозки у обоих
## одни и те же.
func _seat_one(f: Variant, unfreeze: bool) -> void:
	var m := f as Node3D
	if m == null or not is_instance_valid(m):
		return
	var gy: float = _ground_y(m.global_position)
	m.global_position = Vector3(m.global_position.x, gy + 1.2, m.global_position.z)
	var rb := m as RigidBody3D
	if rb == null:
		return
	rb.linear_velocity = Vector3.ZERO
	rb.angular_velocity = Vector3.ZERO
	if unfreeze:
		rb.freeze = false

## ЗАМЕНА САДИТСЯ САМА, И БЕЗ ЭТОГО ОНА ВИСИТ В ВОЗДУХЕ. `_spawn_fighter` замораживает машину
## всегда — иначе она провалится, пока под ней режется плитка коллизии, — а размораживал её
## только `_reseat_fighters`, который зовут ровно два раза: при открытии раунда и при переезде.
## Машина, родившаяся в середине боя вместо убитой, не проходила ни через один из них и
## оставалась замороженной на высоте спавна до конца раунда.
##
## Ждём землю ПОД САМОЙ МАШИНОЙ, а не общий счётчик плиток: замена встаёт в START_GAP (34 м) от
## выжившего, то есть заведомо вне его коридора коллизии, и на карте с десятками готовых плиток
## под ней самой может не быть ни одной. Луч по слою рельефа (1) отвечает именно про это место.
##
## Срок тот же, что у раунда: если коллизия почему-то не поедет, лучше машина, просевшая на
## полметра, чем машина, висящая в воздухе.
##
## Пока ждём — машину НЕ ТРОГАЕМ, в отличие от открытия раунда. Там земля дотекает под ногами и
## высота под машиной меняется, поэтому её и держат на поверхности каждый кадр; здесь карта уже
## стоит, `terrain_height_at` отвечает по точке и его ответ не изменится. Лишняя запись позиции
## каждый кадр — это ещё и обращение к телу ровно тогда, когда рельеф добавляет и убирает
## владельцев плиток, то есть «shapes.has(owner)» пачками.
func _land_fighter(side: int, era: int) -> void:
	var f: Variant = _fighters[side]
	var waited := 0.0
	while waited < GROUND_WAIT_MAX:
		if not _live(era) or not is_instance_valid(f) or _fighters[side] != f:
			return                       # раунд сменился или машину уже убрали
		if _tile_under(f as Node3D):
			break
		await get_tree().process_frame
		waited += get_process_delta_time()
	if _live(era) and is_instance_valid(f) and _fighters[side] == f:
		_seat_one(f, true)

## Есть ли под телом плитка коллизии рельефа. Слой 1 — сам рельеф (ChunkTerrain.collision_layer).
const TILE_PROBE_UP := 2.0
const TILE_PROBE_DOWN := 8.0

func _tile_under(m: Node3D) -> bool:
	if m == null or not is_instance_valid(m) or not m.is_inside_tree():
		return false
	var space := m.get_world_3d().direct_space_state
	if space == null:
		return false
	var q := PhysicsRayQueryParameters3D.create(
			m.global_position + Vector3.UP * TILE_PROBE_UP,
			m.global_position + Vector3.DOWN * TILE_PROBE_DOWN)
	q.collision_mask = 1
	q.collide_with_areas = false
	return not space.intersect_ray(q).is_empty()

func _await_ground(era: int) -> void:
	var waited := 0.0
	while waited < GROUND_WAIT_MAX:
		if not _live(era) or not is_instance_valid(_map):
			return
		# Пока ждём — ДЕРЖИМ машины на поверхности. Они заморожены, но высота под ними меняется
		# по мере того, как рельеф достраивается, и без этого замороженная машина осталась бы
		# висеть там, где её поставили до появления земли.
		_reseat_fighters(false)
		if _map.has_method("collision_stats"):
			var cs: Vector2i = _map.collision_stats()
			if cs.x >= GROUND_TILES_MIN:
				# Плитки есть — даём им ещё кадр, чтобы физика успела их увидеть.
				#
				# ЖДЁМ КАДР ОТРИСОВКИ, А НЕ ФИЗИЧЕСКИЙ. physics_frame возвращает управление
				# ПОСРЕДИ шага физики, а рельеф в этот момент как раз добавляет и убирает
				# владельцев плиток коллизии. Трогать сцену оттуда — это ошибки вида
				# «shapes.has(owner)» пачками; они и посыпались, как только ожидание появилось
				# в обоих путях открытия раунда.
				await get_tree().process_frame
				return
		await get_tree().process_frame
		waited += get_process_delta_time()

# ── Tick ─────────────────────────────────────────────────────────────────────
func _process(delta: float) -> void:
	_t += delta
	# While the round is being swapped the camera holds still: the old map is already gone and the
	# new one is not in place yet, so there is no ground to measure a height against.
	if _swapping or _off:
		return
	_move_camera()
	# A round that is still opening owns the stage: the tick must not run its timer (it stands at
	# zero until the round is open) nor start a generation against a map that is not up yet.
	if _opening or _map == null:
		return
	_round_t -= delta
	# Время вышло — ПЕРЕЕЗЖАЕМ, а не строим новую карту. Защита внутри: _round_t тикает и дальше
	# нуля, а второй переезд поверх идущего был бы двумя наборами машин на стадии.
	if _round_t <= 0.0:
		_move_round()
	# The fight is kept alive the whole time, generation or not: a machine that died or lost its guns
	# is replaced where it stood.
	_replace_fallen()

func _weapon_count(m: Node3D) -> int:
	var blocks := m.get_node_or_null("blocks")
	if blocks == null:
		return 0
	var n: int = 0
	for b in blocks.get_children():
		if b is WeaponBlock:
			n += 1
	return n

## The camera watches the middle of the fight from above and orbits slowly.
##
## Height is counted FROM THE GROUND under that middle, not from the machines: hills here reach
## tens of metres, and a fixed altitude put the camera inside a slope - the menu opened on a black
## screen. Before the first machines exist the middle is the map centre, so the ground is still
## what the height is measured against.
func _move_camera() -> void:
	var mid := Vector3.ZERO
	var live: int = 0
	for f in _fighters:
		if is_instance_valid(f):
			mid += (f as Node3D).global_position
			live += 1
	if live > 0:
		mid /= float(live)
	# No map yet (the first one is still generating): sit above everything the generator can build,
	# so the ground appears in frame the moment it exists instead of somewhere behind the camera.
	var gy: float = _ground_y(mid) if _map != null and is_instance_valid(_map) else 100.0
	var a: float = _t * CAM_ORBIT
	var eye := Vector3(mid.x + cos(a) * CAM_DIST, gy + CAM_HEIGHT, mid.z + sin(a) * CAM_DIST)
	# The orbit point may land on a hill higher than the camera itself - then the eye goes under the
	# ground and the screen fills with the inside of a slope. Keep it above whatever is under it.
	eye.y = maxf(eye.y, _ground_y(eye) + CAM_CLEARANCE)
	_cam.position = eye
	_cam.look_at(Vector3(mid.x, gy + 2.0, mid.z), Vector3.UP)
