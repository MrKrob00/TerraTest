extends Node
# THE GAME'S SOUND EFFECTS, ONE DOOR (autoload `Sfx`; the player: "sounds are almost missing -
# important for atmosphere"). The clips are `resources/sfx/*.ogg`, made by art/game_sfx.py.
#
#   Sfx.at(key, pos)   a sound in the world, from a pool of AudioStreamPlayer3D
#   Sfx.ui(key)        a flat interface sound
#
# A key names a clip or a set of variants (`gun` -> gun_0..2), one picked at random, the pitch
# nudged a little each time so a burst does not read as a loop. Every key has a GAP and a VOICE cap:
# a fight is two dozen guns at five shots a second, and a sound per round is noise and a pile of
# players. Past `HEAR_DIST` of the camera nothing is started. Clips are loaded at run time, so one
# not imported yet is silence, never a script that fails to load.
#
# THE ENGINE is one flat loop for the machine the player drives, pitched and levelled by its speed
# and throttle (`_engine_tick`), silent in assembly, the garage and the menu.

const DIR := "res://resources/sfx/"
const POOL_3D := 24
const POOL_UI := 4
const HEAR_DIST := 140.0

## key: [variants, volume dB, min gap ms, max voices, unit size (m for -6 dB)]
const KEYS := {
	"gun":     [3, -6.0, 45, 6, 10.0],
	"shotgun": [1, -3.0, 90, 3, 12.0],
	"cannon":  [1, 0.0, 120, 3, 18.0],
	"laser":   [1, -5.0, 90, 3, 12.0],
	"rocket":  [1, -4.0, 90, 3, 12.0],
	"mortar":  [1, -3.0, 120, 3, 14.0],
	"hit":     [3, -10.0, 60, 4, 6.0],
	"blast":   [2, 0.0, 120, 4, 20.0],
	"shield":  [1, -9.0, 90, 2, 8.0],
	"place":   [3, -3.0, 60, 2, 8.0],
	"take":    [1, -4.0, 60, 2, 8.0],
	"drop":    [1, -4.0, 60, 2, 8.0],
	"mine":    [3, -8.0, 140, 3, 6.0],
	"chop":    [2, -6.0, 140, 3, 8.0],
	"pickup":  [1, -8.0, 50, 3, 5.0],
	"sale":    [1, -8.0, 300, 1, 8.0],
	"click":   [1, -6.0, 40, 2, 1.0],
	"open":    [1, -6.0, 150, 1, 1.0],
	"close":   [1, -6.0, 150, 1, 1.0],
	"error":   [1, -6.0, 300, 1, 1.0],
	"licence": [1, -4.0, 300, 1, 1.0],
}

var volume: float = 0.8                 # 0..1, SETTINGS -> AUDIO; kept in settings.json
var _streams: Dictionary = {}           # clip name -> AudioStream (or null when missing)
var _last: Dictionary = {}              # key -> ms
var _p3: Array[AudioStreamPlayer3D] = []
var _pu: Array[AudioStreamPlayer] = []
var _next3: int = 0
var _nextu: int = 0
var _engine: AudioStreamPlayer = null
var _rng := RandomNumberGenerator.new()

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	var v = G.settings_raw().get("sfx_volume", 0.8)
	volume = clampf(float(v), 0.0, 1.0)
	for i in POOL_3D:
		var p := AudioStreamPlayer3D.new()
		p.max_distance = HEAR_DIST
		p.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
		p.doppler_tracking = AudioStreamPlayer3D.DOPPLER_TRACKING_DISABLED
		add_child(p)
		_p3.append(p)
	for i in POOL_UI:
		var u := AudioStreamPlayer.new()
		add_child(u)
		_pu.append(u)

func set_volume(v: float) -> void:
	volume = clampf(v, 0.0, 1.0)
	G.settings_merge({"sfx_volume": volume})

func _stream(name: String) -> AudioStream:
	if not _streams.has(name):
		var path := DIR + name + ".ogg"
		_streams[name] = load(path) if ResourceLoader.exists(path) else null
	return _streams[name]

## A clip of the key, or null: the key unknown, too soon after the last one, or silenced.
func _pick(key: String) -> AudioStream:
	if volume <= 0.001 or not KEYS.has(key):
		return null
	var row: Array = KEYS[key]
	var now := Time.get_ticks_msec()
	if now - int(_last.get(key, -100000)) < int(row[2]):
		return null
	var n: int = int(row[0])
	var s := _stream(key if n == 1 else "%s_%d" % [key, _rng.randi_range(0, n - 1)])
	if s != null:
		_last[key] = now
	return s

func _voices(key: String) -> int:
	var c := 0
	for p in _p3:
		if p.playing and p.get_meta("key", "") == key:
			c += 1
	return c

## A sound at a world point. `pitch` scales the clip's own (a Marlit gun is lower).
func at(key: String, pos: Vector3, pitch: float = 1.0, gain_db: float = 0.0) -> void:
	var cam := get_viewport().get_camera_3d()
	if cam == null or cam.global_position.distance_squared_to(pos) > HEAR_DIST * HEAR_DIST:
		return
	if not KEYS.has(key) or _voices(key) >= int((KEYS[key] as Array)[3]):
		return
	var s := _pick(key)
	if s == null:
		return
	var row: Array = KEYS[key]
	# the oldest player in the ring, skipping one still busy with a loud key when a free one waits
	var p: AudioStreamPlayer3D = null
	for i in POOL_3D:
		var c: AudioStreamPlayer3D = _p3[(_next3 + i) % POOL_3D]
		if not c.playing:
			p = c
			_next3 = (_next3 + i + 1) % POOL_3D
			break
	if p == null:
		p = _p3[_next3]
		_next3 = (_next3 + 1) % POOL_3D
	p.stream = s
	p.set_meta("key", key)
	p.unit_size = float(row[4])
	p.volume_db = float(row[1]) + gain_db + linear_to_db(volume)
	p.pitch_scale = pitch * _rng.randf_range(0.93, 1.07)
	p.global_position = pos
	p.play()

## A flat interface sound.
func ui(key: String) -> void:
	var s := _pick(key)
	if s == null:
		return
	var u: AudioStreamPlayer = _pu[_nextu]
	_nextu = (_nextu + 1) % POOL_UI
	u.stream = s
	u.volume_db = float((KEYS[key] as Array)[1]) + linear_to_db(volume)
	u.pitch_scale = _rng.randf_range(0.97, 1.03)
	u.play()

# ── The engine ───────────────────────────────────────────────────────────────────────────────
const ENGINE_DB := -14.0
const ENGINE_IDLE := 0.25               # share of the level at rest, engine on
func _process(delta: float) -> void:
	_engine_tick(delta)

func _engine_tick(delta: float) -> void:
	var v: Node = null
	var cc: Node = get_tree().get_first_node_in_group("camera_controller")
	if cc != null and "current_vehicle" in cc:
		v = cc.current_vehicle
	var want := 0.0
	var speed := 0.0
	if is_instance_valid(v) and v is RigidBody3D and v.is_inside_tree() and not (v.get("Building") == true) \
			and not (v.get("anchored") == true) and not (v.get("is_station") == true) \
			and get_tree().get_first_node_in_group("planetfall_intro") == null:
		speed = (v as RigidBody3D).linear_velocity.length()
		var thr := 0.0
		if v.has_method("drive_throttle"):
			thr = absf(float(v.drive_throttle()))
		want = clampf(ENGINE_IDLE + 0.5 * thr + speed / 40.0, 0.0, 1.0)
	if want <= 0.0 and (_engine == null or not _engine.playing):
		return
	if _engine == null:
		var s := _stream("engine")
		if s == null:
			return
		s = s.duplicate()
		if "loop" in s:
			s.set("loop", true)
		_engine = AudioStreamPlayer.new()
		_engine.stream = s
		_engine.volume_db = -60.0
		add_child(_engine)
	if want > 0.0 and not _engine.playing:
		_engine.play()
	var cur := db_to_linear(_engine.volume_db) / maxf(db_to_linear(ENGINE_DB) * volume, 0.0001)
	var lvl := move_toward(clampf(cur, 0.0, 1.0), want, delta * 1.5)
	if lvl <= 0.01 and want <= 0.0:
		_engine.stop()
		_engine.volume_db = -60.0
		return
	_engine.volume_db = linear_to_db(maxf(lvl * db_to_linear(ENGINE_DB) * volume, 0.00001))
	_engine.pitch_scale = lerpf(_engine.pitch_scale, 0.75 + clampf(speed / 25.0, 0.0, 1.0) * 0.8, minf(delta * 3.0, 1.0))
