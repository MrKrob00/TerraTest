extends Node
# MusicManager (autoload) — контекстная музыка с плейлистом игрока.
#
# Три типа: MENU (гараж), TRAVEL (езда по миру), BATTLE (враги рядом). Треки лежат в
# res://music/{menu,travel,battle}/ и подхватываются автоматически (см. music/README.md).
# Внутри типа трек выбирается СЛУЧАЙНО С ВЕСАМИ: любимый (♥) играет чаще, выключенный (✖)
# не играет никогда, один и тот же трек не повторяется подряд (если есть выбор).
# Переходы кроссфейдом на двух AudioStreamPlayer. Выход из боя — с задержкой (гистерезис),
# чтобы музыка не дёргалась туда-сюда, когда враг мелькнул на краю радиуса.
# Предпочтения (♥/✖) и громкость — в user://music_prefs.json.

signal track_changed(title: String, author: String)
signal prefs_changed

enum Ctx { MENU, TRAVEL, BATTLE }

# ── Параметры (подобраны по рисёрчу мобильных/консольных игр) ──────────────────
const CROSSFADE := 2.0             # с: кроссфейд между треками/контекстами
const BATTLE_ENTER_DELAY := 1.0    # с: враг рядом столько времени → бой (анти-«радар»: мгновенный бой телеграфирует невидимых врагов)
const BATTLE_EXIT_DELAY := 8.0     # с: столько без врагов → обратно в travel (анти-дёрганье)
const BATTLE_RADIUS := 32.0        # м: враг ближе — считается «рядом»
const FAV_WEIGHT := 3.0            # любимый трек втрое вероятнее обычного
const GAPS := {Ctx.MENU: 1.5, Ctx.TRAVEL: 10.0, Ctx.BATTLE: 0.8}
# с: пауза тишины между треками. В TRAVEL заметная (10 с) НАМЕРЕННО — рисёрч (Skyrim,
# Oblivion) показал: без пауз маленький плейлист приедается («same 30 seconds over and over»).
const POLL := 0.4                  # с: период опроса контекста

const DIRS := {Ctx.MENU: "res://music/menu", Ctx.TRAVEL: "res://music/travel", Ctx.BATTLE: "res://music/battle"}
const PREFS_PATH := "user://music_prefs.json"
const META_PATH := "res://music/metadata.json"

# ── Состояние ──────────────────────────────────────────────────────────────────
var tracks: Dictionary = {}        # Ctx -> Array[{path, file, title, author}]
var fav: Dictionary = {}           # file -> true (любимое)
var banned: Dictionary = {}        # file -> true (не играть)
var volume: float = 0.8            # 0..1 громкость музыки
var enabled: bool = true

var _ctx: int = Ctx.TRAVEL
var _menu_open: bool = false
var _cur: Dictionary = {}          # играющий трек ({} если тишина)
var _last_file: Dictionary = {}    # Ctx -> имя файла последнего трека (не повторять подряд)
var _resume: Dictionary = {}       # Ctx -> {file, pos}: прерванный трек контекста (возобновляем с места)
var _a: AudioStreamPlayer
var _b: AudioStreamPlayer
var _active: AudioStreamPlayer     # кто из двух сейчас «основной»
var _fade_tw: Tween = null
var _poll_t: float = 0.0
var _battle_seen: float = -1000.0  # когда последний раз видели врага рядом
var _battle_first: float = -1.0    # когда враг впервые появился (для enter delay)
var _gap_left: float = 0.0

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS   # музыка живёт и на паузе игры
	_a = AudioStreamPlayer.new()
	_b = AudioStreamPlayer.new()
	add_child(_a)
	add_child(_b)
	_active = _a
	_a.finished.connect(_on_track_finished.bind(_a))
	_b.finished.connect(_on_track_finished.bind(_b))
	_load_prefs()
	_scan_tracks()
	_play_for_context()

# ── Публичный API ──────────────────────────────────────────────────────────────

# Гараж/меню открыты? (зовёт hud при переключении tech_ui)
func set_menu_open(open: bool) -> void:
	if _menu_open == open:
		return
	_menu_open = open
	_recompute_context(true)

func set_favorite(file: String, on: bool) -> void:
	if on:
		fav[file] = true
		banned.erase(file)
	else:
		fav.erase(file)
	_save_prefs()
	prefs_changed.emit()

func set_banned(file: String, on: bool) -> void:
	if on:
		banned[file] = true
		fav.erase(file)
		if _cur.get("file", "") == file:
			skip()                     # выключили играющий — сразу следующий
	else:
		banned.erase(file)
	_save_prefs()
	prefs_changed.emit()

func set_volume(v: float) -> void:
	volume = clampf(v, 0.0, 1.0)
	if _active and _active.playing and (_fade_tw == null or not _fade_tw.is_valid()):
		_active.volume_db = linear_to_db(maxf(volume, 0.0001))
	_save_prefs()

func skip() -> void:
	_start_track(_pick(_ctx), true)

func current_track() -> Dictionary:
	return _cur

func context_name() -> String:
	return ["Меню", "Путешествие", "Бой"][_ctx]

# ── Контекст ───────────────────────────────────────────────────────────────────

func _process(delta: float) -> void:
	if _gap_left > 0.0:
		_gap_left -= delta
		if _gap_left <= 0.0:
			_start_track(_pick(_ctx), false)
	_poll_t -= delta
	if _poll_t > 0.0:
		return
	_poll_t = POLL
	_recompute_context(false)

func _recompute_context(force: bool) -> void:
	var now := Time.get_ticks_msec() / 1000.0
	var want: int = Ctx.TRAVEL
	if _menu_open:
		want = Ctx.MENU
		_battle_first = -1.0
	else:
		if _enemy_near():
			if _battle_first < 0.0:
				_battle_first = now
			if now - _battle_first >= BATTLE_ENTER_DELAY:
				_battle_seen = now
		else:
			_battle_first = -1.0
		# Бой «липкий»: держим BATTLE ещё BATTLE_EXIT_DELAY после исчезновения врагов.
		if now - _battle_seen < BATTLE_EXIT_DELAY:
			want = Ctx.BATTLE
	if want != _ctx or force:
		_save_resume(_ctx)          # запоминаем, где прервали трек уходящего контекста
		_ctx = want
		_play_for_context()

# Трек прерван переключением контекста (не доиграл сам) → запоминаем позицию, чтобы при
# возврате в контекст продолжить С ТОГО ЖЕ МЕСТА (рисёрч: иначе игрок слышит первые
# 30 секунд трека сотни раз — Xenoblade X добавили resume патчем по жалобам).
func _save_resume(ctx: int) -> void:
	if _cur.is_empty() or not _active.playing:
		return
	_resume[ctx] = {"file": _cur["file"], "pos": _active.get_playback_position()}

func _enemy_near() -> bool:
	var cc: Node = get_tree().get_first_node_in_group("camera_controller")
	if cc == null or not ("current_vehicle" in cc) or not is_instance_valid(cc.current_vehicle):
		return false
	var me: Node3D = cc.current_vehicle
	var vehicles := cc.get_parent()      # Camera Controller живёт под Vehicles
	if vehicles == null:
		return false
	for v in vehicles.get_children():
		if v is Node3D and v != me:
			var f = v.get("faction")
			if f != null and int(f) != 0 \
					and me.global_position.distance_to((v as Node3D).global_position) <= BATTLE_RADIUS:
				return true
	return false

# ── Выбор и запуск треков ──────────────────────────────────────────────────────

func _play_for_context() -> void:
	# Возврат в контекст с прерванным треком → продолжаем его с места остановки.
	var r: Dictionary = _resume.get(_ctx, {})
	if not r.is_empty():
		_resume.erase(_ctx)
		if not banned.has(r["file"]):
			for tr in tracks.get(_ctx, []):
				if tr["file"] == r["file"]:
					if tr.get("file", "") == _cur.get("file", "") and _active.playing:
						return
					_start_track(tr, true, float(r["pos"]))
					return
	var t := _pick(_ctx)
	# Тот же трек уже играет (например, force-пересчёт) — не перезапускаем.
	if not t.is_empty() and t.get("file", "") == _cur.get("file", "") and _active.playing:
		return
	_start_track(t, true)

# Взвешенный рандом: любимые ×FAV_WEIGHT, забаненные исключены, без повтора подряд.
func _pick(ctx: int) -> Dictionary:
	var pool: Array = tracks.get(ctx, [])
	var candidates: Array = []
	for t in pool:
		if banned.has(t["file"]):
			continue
		candidates.append(t)
	if candidates.is_empty():
		return {}
	if candidates.size() > 1:
		var last: String = _last_file.get(ctx, "")
		var without_last: Array = candidates.filter(func(t): return t["file"] != last)
		if not without_last.is_empty():
			candidates = without_last
	var total := 0.0
	for t in candidates:
		total += FAV_WEIGHT if fav.has(t["file"]) else 1.0
	var roll := randf() * total
	for t in candidates:
		roll -= FAV_WEIGHT if fav.has(t["file"]) else 1.0
		if roll <= 0.0:
			return t
	return candidates.back()

func _start_track(t: Dictionary, crossfade: bool, from_pos: float = 0.0) -> void:
	_gap_left = 0.0
	if t.is_empty() or not enabled:
		_fade_out_all()
		_cur = {}
		return
	var stream := load(t["path"]) as AudioStream
	if stream == null:
		return
	# Resume у самого конца трека смысла не имеет — начинаем с нуля.
	if from_pos > 0.0 and stream.get_length() > 0.0 and from_pos >= stream.get_length() - 10.0:
		from_pos = 0.0
	_cur = t
	_last_file[_ctx] = t["file"]
	var next: AudioStreamPlayer = _b if _active == _a else _a
	next.stream = stream
	next.volume_db = linear_to_db(0.0001)
	next.play(from_pos)
	var old := _active
	_active = next
	if _fade_tw != null and _fade_tw.is_valid():
		_fade_tw.kill()
	_fade_tw = create_tween()
	var dur := CROSSFADE if crossfade else CROSSFADE * 0.5
	_fade_tw.set_parallel(true)
	_fade_tw.tween_method(_set_player_vol.bind(next), 0.0, 1.0, dur)
	if old.playing:
		_fade_tw.tween_method(_set_player_vol.bind(old), 1.0, 0.0, dur)
		_fade_tw.chain().tween_callback(old.stop)
	track_changed.emit(str(t["title"]), str(t["author"]))

func _fade_out_all() -> void:
	if _fade_tw != null and _fade_tw.is_valid():
		_fade_tw.kill()
	_fade_tw = create_tween()
	for p in [_a, _b]:
		if p.playing:
			_fade_tw.parallel().tween_method(_set_player_vol.bind(p), 1.0, 0.0, 1.0)
	_fade_tw.chain().tween_callback(_stop_all)

# Трек доиграл сам → короткая пауза тишины и следующий из того же контекста.
# finished может прилететь и от СТАРОГО (затухающего) плеера — его игнорируем.
func _on_track_finished(p: AudioStreamPlayer) -> void:
	if p != _active or _cur.is_empty():
		return
	_cur = {}
	_gap_left = float(GAPS.get(_ctx, 1.5))

# ── Сканирование треков ────────────────────────────────────────────────────────

# В экспортированной сборке файлы видны как .import/.remap — учитываем оба варианта.
func _scan_tracks() -> void:
	var meta := _load_meta()
	for ctx in DIRS:
		var list: Array = []
		var dir := DirAccess.open(DIRS[ctx])
		if dir != null:
			dir.list_dir_begin()
			var seen := {}
			var f := dir.get_next()
			while f != "":
				if not dir.current_is_dir():
					var name := f
					if name.ends_with(".import") or name.ends_with(".remap"):
						name = name.get_basename()      # отрезали .import/.remap
					var ext := name.get_extension().to_lower()
					if ext in ["ogg", "mp3", "wav"] and not seen.has(name):
						seen[name] = true
						list.append(_make_track(DIRS[ctx] + "/" + name, name, meta))
				f = dir.get_next()
			dir.list_dir_end()
		tracks[ctx] = list

func _make_track(path: String, file: String, meta: Dictionary) -> Dictionary:
	var title := file.get_basename()
	var author := "Неизвестен"
	# Имя файла «Автор - Название.ogg» → метаданные.
	var dash := title.find(" - ")
	if dash > 0:
		author = title.substr(0, dash).strip_edges()
		title = title.substr(dash + 3).strip_edges()
	var m: Dictionary = meta.get(file, {})
	return {
		"path": path,
		"file": file,
		"title": str(m.get("title", title)),
		"author": str(m.get("author", author)),
	}

func _load_meta() -> Dictionary:
	if not FileAccess.file_exists(META_PATH):
		return {}
	var txt := FileAccess.get_file_as_string(META_PATH)
	var parsed = JSON.parse_string(txt)
	return parsed if parsed is Dictionary else {}

# ── Персист предпочтений ───────────────────────────────────────────────────────

func _save_prefs() -> void:
	var f := FileAccess.open(PREFS_PATH, FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify({
		"fav": fav.keys(), "banned": banned.keys(), "volume": volume, "enabled": enabled,
	}))

func _load_prefs() -> void:
	if not FileAccess.file_exists(PREFS_PATH):
		return
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(PREFS_PATH))
	if not (parsed is Dictionary):
		return
	for k in parsed.get("fav", []):
		fav[str(k)] = true
	for k in parsed.get("banned", []):
		banned[str(k)] = true
	volume = clampf(float(parsed.get("volume", 0.8)), 0.0, 1.0)
	enabled = bool(parsed.get("enabled", true))

# Хелперы твинов (bind вместо многострочных лямбд в аргументах — те хрупко парсятся).
func _set_player_vol(v: float, p: AudioStreamPlayer) -> void:
	p.volume_db = linear_to_db(maxf(v * volume, 0.0001))

func _stop_all() -> void:
	_a.stop()
	_b.stop()
