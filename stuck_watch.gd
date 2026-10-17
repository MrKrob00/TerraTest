extends CanvasLayer
## "YOU CANNOT GO ON" (the player: offer to surrender when there is no way to continue - beautifully,
## and not at every sneeze). Twice a second it looks at the machine the player drives and, when the
## machine is overturned or stuck, slides a card down from the top: the reason in plain words and the
## FIX THAT EXISTS - back on its wheels, lifted out, assembly with the wheels at hand, the shop.
## Surrender is offered only when nothing fixes it: no wheels to bolt on, none to buy, or a lift that
## did not help. Never in a fight, the tutorial, the intro, assembly, the garage, the menu, on the
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
const LIFT_CLEAR := 1.6            # right_up: the lowest block this far over the ground

const CARD_W := 470.0
const CARD_TOP := 96.0             # under the top row of buttons (hud.MENU_PAD + MENU_BTN + 12)
const FILL := Color(0.043, 0.122, 0.149, 0.95)
const RING := Color(0.247, 0.6, 0.65)
const WARN := Color(1.0, 0.7, 0.25)          # hud.BUILD_COL, the HUD's one amber
const INK := Color(0.9, 0.97, 0.98)
const DIM := Color(0.62, 0.74, 0.78)
const DANGER := Color(0.95, 0.5, 0.45)

enum Fix { RIGHT_UP, LIFT, ASSEMBLY, SHOP, SURRENDER }

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
var _shown_fix: int = -1
var _shown_at: Vector3 = Vector3.ZERO
var _confirm_t: float = 0.0
var _root: Control
var _card: PanelContainer
var _title: Label
var _text: Label
var _act: Button
var _later: Button
var _tween: Tween

func _ready() -> void:
	layer = LAYER
	_build()

func _process(delta: float) -> void:
	_now += delta
	if _confirm_t > 0.0:
		_confirm_t -= delta
		if _confirm_t <= 0.0:
			_act.text = tr("Surrender")
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
	if _card.visible:
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
	var title: String
	var text: String
	var fix: int
	if kind == "flip":
		title = tr("Machine overturned")
		text = tr("It will not get back on its wheels by itself.")
		fix = Fix.RIGHT_UP
	else:
		var power: float = v.rated_power() if v.has_method("rated_power") else 0.0
		var cap: float = v.load_capacity() if v.has_method("load_capacity") else 0.0
		var heavy: bool = cap > 0.0 and (v as RigidBody3D).mass > cap
		if power > 0.0 and not heavy and _now - _lift_t > RELIFT:
			title = tr("Machine stuck")
			text = tr("The wheels are not getting it anywhere.")
			fix = Fix.LIFT
		else:
			title = tr("Machine cannot drive")
			var why: String
			if cap <= 0.0:
				why = tr("It has no wheels.")
			elif heavy:
				why = tr("It is too heavy for its wheels.")
			else:
				why = tr("Lifting it out did not help.")
			var price: int = _cheapest_wheel()
			if heavy or _wheel_at_hand():
				fix = Fix.ASSEMBLY
				text = why + " " + (tr("Take blocks off or bolt on more wheels in assembly.") if heavy
						else tr("Wheels are at hand: bolt them on in assembly."))
			elif price > 0:
				fix = Fix.SHOP
				text = why + " " + tr("A wheel costs %d in the shop.") % price
			else:
				fix = Fix.SURRENDER
				text = why + " " + (tr("Nothing to fix it with: surrender, and you take over your other machine.")
						if _other_machine(v) else
						tr("Nothing to fix it with: surrender, and you start again in a new cabin with a starter kit."))
	_last_offer = _now
	_show(kind, fix, title, text, at)

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

# ── The fixes ────────────────────────────────────────────────────────────────────

func _on_act() -> void:
	var v: Node = _vehicle()
	match _shown_fix:
		Fix.RIGHT_UP, Fix.LIFT:
			if v != null and v.has_method("right_up"):
				v.right_up(LIFT_CLEAR)
			_lift_t = _now
			_episode.erase("stuck")             # a lift that does not help shows up as a new episode
			_hide()
		Fix.ASSEMBLY:
			_hide()
			if v != null and v.has_method("_on_building_pressed"):
				v._on_building_pressed()        # the BUILD button's own door; the HUD follows it
		Fix.SHOP:
			_hide()
			if hud != null and hud.has_method("open_garage_tab"):
				hud.open_garage_tab(&"shop")
		Fix.SURRENDER:
			if _confirm_t <= 0.0:
				_confirm_t = CONFIRM_TIME
				_act.text = tr("Tap again to surrender")
				return
			_hide()
			preload("res://game_menu.gd").surrender(hud)

func _on_later() -> void:
	var n: int = int(_snooze_n.get(_shown_kind, 0))
	_snooze_until[_shown_kind] = _now + minf(SNOOZE * pow(2.0, n), SNOOZE_MAX)
	_snooze_n[_shown_kind] = n + 1
	_hide()

# ── The card ─────────────────────────────────────────────────────────────────────

func _build() -> void:
	_root = Control.new()
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)
	_card = PanelContainer.new()
	_card.custom_minimum_size = Vector2(CARD_W, 0)
	_card.visible = false
	var sb := StyleBoxFlat.new()
	sb.bg_color = FILL
	sb.border_color = RING
	sb.set_border_width_all(2)
	sb.border_width_left = 5
	sb.set_corner_radius_all(10)
	sb.content_margin_left = 16.0
	sb.content_margin_right = 18.0
	sb.content_margin_top = 14.0
	sb.content_margin_bottom = 14.0
	_card.add_theme_stylebox_override("panel", sb)
	_root.add_child(_card)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 14)
	_card.add_child(row)
	var icon := WarnIcon.new()
	icon.custom_minimum_size = Vector2(44, 44)
	icon.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	row.add_child(icon)
	var col := VBoxContainer.new()
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.add_theme_constant_override("separation", 6)
	row.add_child(col)
	_title = Label.new()
	_title.add_theme_font_size_override("font_size", 19)
	_title.add_theme_color_override("font_color", WARN)
	col.add_child(_title)
	_text = Label.new()
	_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_text.add_theme_font_size_override("font_size", 15)
	_text.add_theme_color_override("font_color", INK)
	col.add_child(_text)
	var btns := HBoxContainer.new()
	btns.alignment = BoxContainer.ALIGNMENT_END
	btns.add_theme_constant_override("separation", 10)
	col.add_child(btns)
	_later = _button(WARN, false)
	_later.text = "Not now"
	_later.pressed.connect(_on_later)
	btns.add_child(_later)
	_act = _button(WARN, true)
	_act.pressed.connect(_on_act)
	btns.add_child(_act)

func _button(edge: Color, primary: bool) -> Button:
	var b := Button.new()
	b.custom_minimum_size = Vector2(0, 50)
	b.focus_mode = Control.FOCUS_NONE
	b.add_theme_font_size_override("font_size", 17)
	b.add_theme_color_override("font_color", Color(0.08, 0.06, 0.03) if primary else DIM)
	b.add_theme_color_override("font_hover_color", Color(0.08, 0.06, 0.03) if primary else INK)
	b.add_theme_color_override("font_pressed_color", Color(0.08, 0.06, 0.03) if primary else INK)
	for st in ["normal", "hover", "pressed"]:
		var s := StyleBoxFlat.new()
		s.bg_color = edge if primary else Color(0.07, 0.19, 0.23)
		if st != "normal":
			s.bg_color = s.bg_color.lightened(0.15)
		s.border_color = Color(edge, 0.9) if primary else Color(RING, 0.6)
		s.set_border_width_all(2)
		s.set_corner_radius_all(6)
		s.content_margin_left = 18.0
		s.content_margin_right = 18.0
		b.add_theme_stylebox_override(st, s)
	return b

const FIX_LABEL := {Fix.RIGHT_UP: "Put it on its wheels", Fix.LIFT: "Lift it out",
		Fix.ASSEMBLY: "Open assembly", Fix.SHOP: "Open shop", Fix.SURRENDER: "Surrender"}

func _show(kind: String, fix: int, title: String, text: String, at: Vector3) -> void:
	_shown_kind = kind
	_shown_fix = fix
	_shown_at = at
	_confirm_t = 0.0
	_title.text = title
	_text.text = text
	_act.text = tr(FIX_LABEL[fix])
	var danger: bool = fix == Fix.SURRENDER
	for st in ["normal", "hover", "pressed"]:
		var s := _act.get_theme_stylebox(st).duplicate() as StyleBoxFlat
		s.bg_color = (DANGER if danger else WARN).lightened(0.0 if st == "normal" else 0.15)
		s.border_color = DANGER if danger else WARN
		_act.add_theme_stylebox_override(st, s)
	_card.visible = true
	_card.reset_size()
	var screen: Vector2 = _root.get_viewport_rect().size
	var x: float = (screen.x - _card.size.x) * 0.5
	_card.position = Vector2(x, -_card.size.y - 10.0)
	_card.modulate.a = 0.0
	if _tween != null and _tween.is_valid():
		_tween.kill()
	_tween = create_tween().set_parallel(true)
	_tween.tween_property(_card, "position:y", CARD_TOP, 0.32).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_tween.tween_property(_card, "modulate:a", 1.0, 0.2)

func _hide() -> void:
	if not _card.visible:
		return
	_confirm_t = 0.0
	if _tween != null and _tween.is_valid():
		_tween.kill()
	_tween = create_tween()
	_tween.tween_property(_card, "modulate:a", 0.0, 0.18)
	_tween.tween_callback(_card.hide)

func is_showing() -> bool:
	return _card.visible

## An amber warning sign, drawn (rule 11: no glyph the font lacks; "!" is plain ASCII but a drawn
## mark reads at any size).
class WarnIcon extends Control:
	func _draw() -> void:
		var s: float = minf(size.x, size.y)
		var c := size * 0.5
		var r: float = s * 0.48
		var pts := PackedVector2Array([c + Vector2(0, -r), c + Vector2(r * 0.95, r * 0.75), c + Vector2(-r * 0.95, r * 0.75)])
		draw_colored_polygon(pts, Color(1.0, 0.7, 0.25))
		var bar := Rect2(c.x - s * 0.05, c.y - r * 0.38, s * 0.1, r * 0.62)
		draw_rect(bar, Color(0.08, 0.06, 0.03))
		draw_circle(Vector2(c.x, c.y + r * 0.48), s * 0.06, Color(0.08, 0.06, 0.03))
