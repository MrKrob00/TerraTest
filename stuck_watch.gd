extends CanvasLayer
## "YOU CANNOT GO ON". Twice a second it looks at the machine the player drives and, when the machine
## is overturned or stuck, SHOWS THE FINGER FOR `HINT_TIME` AND NOTHING ELSE (the player's call: no
## card, no menu, only hints): on BUILD for a machine that is on its side or does not move with the
## stick held (assembly lifts it clear), on the garage when wheels are needed, on the in-game menu
## when only surrender is left - no wheels to bolt on, none to buy, or assembly did not help. Never in a fight, the tutorial, the intro, assembly, the garage, the menu, on the
## anchor or a base; once per episode; "Not now" snoozes that kind for `SNOOZE`, doubling each time.
## Rule 7: the ENEMY has its own way back (`enemy_vehicle._flip_recover`), this is the player's.

const LAYER := 55                  # over the HUD, under the menu (game_menu.gd)
const TICK := 0.5
const GRACE := 20.0                # quiet after the world comes up, a switch or a respawn
const COMBAT_QUIET := 15.0         # the machine lost hit points: no advice for this long
const FLIP_DOT := 0.35             # up . UP under this: on its side or roof
const UPRIGHT_DOT := 0.6           # over this the stuck test runs
const FLIP_TIME := 3.0
const REST_V := 2.0                # m/s and rad/s: it has stopped tumbling
const REST_W := 1.5
const WINDOW := 20                 # samples (10 s) of position and stick
const PUSH_SHARE := 0.7            # of them with the stick pushed
const THROTTLE_ON := 0.4
const STUCK_PATH := 6.0            # metres driven over the window: under this it is not going anywhere
const STUCK_NET := 2.5             # and under this from where the window began
const EPISODE_LEAVE := 15.0        # metres from where it stuck that end the episode
const CLEAR_MOVE := 6.0            # the card goes away by itself once the machine has moved this far
const RELIFT := 60.0               # stuck again this soon after a lift: lifting does not help
const SNOOZE := 180.0
const SNOOZE_MAX := 1800.0
const OFFER_GAP := 45.0            # between any two cards
const CONFIRM_TIME := 4.0
const HINT_TIME := 3.0             # seconds the finger stands

enum Fix { BUILD, SHOP, SURRENDER }

var hud: Node = null
var _t: float = 0.0
var _now: float = 0.0
var _v: Node = null
var _grace_until: float = 0.0
var _hp_last: int = -1
var _hit_t: float = -1e9
var _flip_t: float = 0.0
var _samples: Array = []                     # [Vector3 position, bool pushed]
var _episode: Dictionary = {}                # kind -> where it began (Vector3)
var _snooze_until: Dictionary = {}           # kind -> time
var _snooze_n: Dictionary = {}               # kind -> how many "Not now" this session
var _last_offer: float = -1e9
var _lift_t: float = -1e9

var _shown_kind: String = ""
var _shown_at: Vector3 = Vector3.ZERO
var _hint_t: float = 0.0
var _guide: TutorialGuide = null

func _ready() -> void:
	layer = LAYER
	_guide = preload("res://tutorial_guide.gd").new()
	add_child(_guide)
	_guide.remove_from_group("tutorial_guide")   # quest_arcs takes the first one in it for its own finger
	if hud != null:
		_guide.bind_hud(hud)

func _process(delta: float) -> void:
	_now += delta
	if _hint_t > 0.0:
		_hint_t -= delta
		if _hint_t <= 0.0:
			_hide()
	_t += delta
	if _t < TICK:
		return
	_t = 0.0
	_tick()

# ── The watch ────────────────────────────────────────────────────────────────────

func _tick() -> void:
	var v: Node = _vehicle()
	if v != _v:                                  # a switch, a respawn, the first machine
		_v = v
		_reset()
		_grace_until = _now + GRACE
		_hp_last = -1
	if v == null:
		_hide()
		return
	var hp: int = v.hp_totals().x if v.has_method("hp_totals") else 0
	if _hp_last >= 0 and hp < _hp_last:
		_hit_t = _now
	_hp_last = hp
	if not _may_watch(v):
		_reset()
		_hide()
		return
	var body := v as RigidBody3D
	var up: float = body.global_basis.y.dot(Vector3.UP)
	var at: Vector3 = body.global_position
	_close_episodes(at, up)
	if _hint_t > 0.0:
		_maybe_clear(at, up)
		return
	if up < FLIP_DOT:
		_samples.clear()
		var resting: bool = body.linear_velocity.length_squared() < REST_V * REST_V \
				and body.angular_velocity.length_squared() < REST_W * REST_W
		_flip_t = _flip_t + TICK if resting else 0.0
		if _flip_t >= FLIP_TIME:
			_flip_t = 0.0
			_offer("flip", at, v)
		return
	_flip_t = 0.0
	if up < UPRIGHT_DOT:
		_samples.clear()
		return
	var th = v.get("_throttle")
	_samples.append([at, th != null and absf(float(th)) > THROTTLE_ON])
	if _samples.size() > WINDOW:
		_samples.pop_front()
	if _samples.size() == WINDOW and _stuck():
		_samples.clear()
		_offer("stuck", at, v)

## The context that rules advice out. Each gate is a place where a machine stands still on purpose
## or where a card would be in the way.
func _may_watch(v: Node) -> bool:
	if not G.world_ready() or _now < _grace_until or _now - _hit_t < COMBAT_QUIET:
		return false
	if Q.tutorial_active() or get_tree().get_first_node_in_group("planetfall_intro") != null:
		return false
	if (v as Node).has_meta("intro_hidden"):
		return false
	if v.get("is_active") != true or v.get("Building") == true or v.get("anchored") == true \
			or v.get("is_station") == true:
		return false
	if not v.has_method("can_surrender") or not v.can_surrender():
		return false
	var tu = hud.get("_tech_ui")
	if tu is Control and is_instance_valid(tu) and (tu as Control).visible:
		return false
	var le = hud.get("_layout_editor")
	if le is Node and is_instance_valid(le):
		return false
	var gm = hud.get("_game_menu")
	if gm is CanvasLayer and is_instance_valid(gm) and (gm as CanvasLayer).visible:
		return false
	var cc: Node = get_tree().get_first_node_in_group("camera_controller")
	if cc != null and float(cc.get("_death_t")) > 0.0:
		return false
	return true

## Stuck: the stick held for most of ten seconds and the machine went nowhere - neither along a path
## nor away from where it began (a tight circle with the stick held is driving, not stuck).
func _stuck() -> bool:
	var pushed: int = 0
	var path: float = 0.0
	for i in _samples.size():
		if _samples[i][1]:
			pushed += 1
		if i > 0:
			path += _flat(_samples[i][0] - _samples[i - 1][0]).length()
	if pushed < int(WINDOW * PUSH_SHARE) or path > STUCK_PATH:
		return false
	return _flat(_samples[-1][0] - _samples[0][0]).length() < STUCK_NET

func _close_episodes(at: Vector3, up: float) -> void:
	for k in _episode.keys():
		var gone: bool = _flat(at - (_episode[k] as Vector3)).length() > EPISODE_LEAVE
		if k == "flip" and up > 0.8:
			gone = true
		if gone:
			_episode.erase(k)

func _maybe_clear(at: Vector3, up: float) -> void:
	if _shown_kind == "flip" and up > 0.8:
		_hide()
	elif _shown_kind == "stuck" and _flat(at - _shown_at).length() > CLEAR_MOVE:
		_hide()

func _reset() -> void:
	_flip_t = 0.0
	_samples.clear()

# ── What to offer ────────────────────────────────────────────────────────────────

func _offer(kind: String, at: Vector3, v: Node) -> void:
	if _episode.has(kind) or _now < float(_snooze_until.get(kind, 0.0)) or _now - _last_offer < OFFER_GAP:
		return
	_episode[kind] = at
	var text: String
	var fix: int
	if kind == "flip":
		fix = Fix.BUILD
		text = tr("Overturned: press BUILD for a couple of seconds")
	else:
		var power: float = v.rated_power() if v.has_method("rated_power") else 0.0
		var cap: float = v.load_capacity() if v.has_method("load_capacity") else 0.0
		var heavy: bool = cap > 0.0 and (v as RigidBody3D).mass > cap
		if power > 0.0 and not heavy and _now - _lift_t > RELIFT:
			fix = Fix.BUILD
			text = tr("Stuck: press BUILD for a couple of seconds")
			_lift_t = _now
			_episode.erase("stuck")         # stuck again soon after: building did not help
		elif heavy or _wheel_at_hand():
			fix = Fix.BUILD
			text = tr("Too heavy for its wheels: bolt on more in BUILD") if heavy \
					else tr("No wheels: bolt them on in BUILD")
		elif _cheapest_wheel() > 0:
			fix = Fix.SHOP
			text = tr("No wheels: buy one in the shop")
		else:
			fix = Fix.SURRENDER
			text = tr("Nothing to fix it with: Menu - Surrender")
	_last_offer = _now
	_show(kind, fix, text, at)

func _wheel_at_hand() -> bool:
	for bt in _wheels():
		if G.block_available(bt) > 0:
			return true
	return false

## The cheapest wheel the shop sells today that the money covers, 0 when none.
func _cheapest_wheel() -> int:
	var best: int = 0
	for bt in _wheels():
		if G.shop_count(bt) == 0 or not G.is_block_shop_unlocked(bt):
			continue
		var p: int = G.shop_price_now(bt)
		if p <= int(G.money) and (best == 0 or p < best):
			best = p
	return best

## Every wheel that carries a machine: the top wheel has no geometry yet (`Wheel.geometry_ready`).
func _wheels() -> Array:
	var out: Array = []
	for bt in G.BLOCK_META:
		if G.is_wheel(int(bt)) and int(bt) != G.Block.TOP_WHEEL:
			out.append(int(bt))
	return out

func _other_machine(v: Node) -> bool:
	var cc: Node = get_tree().get_first_node_in_group("camera_controller")
	if cc == null or not cc.has_method("_drivable"):
		return false
	for m in cc.get("vehicles"):
		if m != v and cc._drivable(m):
			return true
	return false

func _vehicle() -> Node:
	var cc: Node = get_tree().get_first_node_in_group("camera_controller")
	if cc == null or not ("current_vehicle" in cc):
		return null
	var v = cc.current_vehicle
	return v if is_instance_valid(v) else null

static func _flat(d: Vector3) -> Vector2:
	return Vector2(d.x, d.z)

# ── The hint ─────────────────────────────────────────────────────────────────────

func _target(fix: int) -> CanvasItem:
	if hud == null:
		return null
	match fix:
		Fix.BUILD:
			return hud.get_node_or_null("ModeToggle") as CanvasItem
		Fix.SHOP:
			return hud.tutorial_target("menu") if hud.has_method("tutorial_target") else null
		Fix.SURRENDER:
			return hud.get("_pause_btn") as CanvasItem
	return null

func _show(kind: String, fix: int, text: String, at: Vector3) -> void:
	var node: CanvasItem = _target(fix)
	if node == null or not is_instance_valid(node) or not node.is_visible_in_tree():
		return
	_shown_kind = kind
	_shown_at = at
	_hint_t = HINT_TIME
	_guide.point_at_node(node, text, false, TutorialGuide.Gate.OFF, false)

func _hide() -> void:
	_hint_t = 0.0
	if _guide != null and _guide.is_active():
		_guide.clear()

func is_showing() -> bool:
	return _hint_t > 0.0
