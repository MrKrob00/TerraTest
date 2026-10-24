extends StaticBody3D
# Жила руды. Руда НЕ создаётся заранее — жила хранит только счётчик _available и штампует
# готовый ресурс (resource_tscn) в мир лишь в момент выброса (экономит ~1000 узлов на карте).
# По урону (hurt) HP падает и вылетает столько руды, чтобы её осталось пропорционально HP;
# когда пусто — $RestTimer, и через паузу жила наполняется заново. instance_id — слот в
# MultiMesh для шейдера истощения; ore_type/ore_color — тип/цвет жилы (задаёт спавнер).

const MAX_RESOURCES: int = 5        # a tree's wood
## EVERY ORE VEIN HAS ITS OWN NUMBERS (the player's balance): ORE_COUNT ore (3..5), ORE_REST seconds
## of rest once spent (~15), and its max_hp times HP_SPREAD - drawn from the vein's ground point
## (`vein_stats`), so a vein keeps them through a restream and a reload. An ore leaves per
## max_hp / its count of damage. 600 ore and 30 minutes' rest was tried and taken back (the player).
## What is left and when it comes back outlive the node: the owner keeps them by the vein's point
## (`resource_nodes.ore_state`) and the world save carries them.
const ORE_COUNT := Vector2i(3, 5)
const ORE_REST := Vector2(10.0, 20.0)
const HP_SPREAD := Vector2(0.75, 1.25)

## x the vein's ore, y its rest in seconds, z its HP factor - the same for a key every time asked.
static func vein_stats(key: Variant) -> Vector3:
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(String(key)) if key != null else randi()
	var n: int = rng.randi_range(ORE_COUNT.x, ORE_COUNT.y)
	return Vector3(n, rng.randf_range(ORE_REST.x, ORE_REST.y), rng.randf_range(HP_SPREAD.x, HP_SPREAD.y))

@export var resource_tscn: PackedScene
@export var max_hp: int = 500   # in the weapons' scale (BLOCK_HP): a gun takes a vein in ~4 s, halved with damage

var current_hp: int = 0
var instance_id: int = 0
var ore_type: int = 0
var ore_color: Color = Color(1.0, 0.75, 0.0)        # цвет вылетающей руды (тинт)
## A TREE. It used to be a coal vein; coal is made now (resource.upgrade) and wood grows instead.
## Drawn by the owner's wood MultiMeshes (a stump and a tree that falls as it is chopped).
var is_wood: bool = false
## Which tree model this is (resource_nodes TREE_*): the battery errand hangs its block per model.
var tree_kind: int = 0
var _available: int = MAX_RESOURCES                 # how much is left (an ore vein: up to ore_total)
var ore_total: int = MAX_RESOURCES                  # an ore vein's own count (`vein_stats`)
var _dmg: int = 0                                   # an ore vein's damage toward its next ore
## Set by the owner before add_child: the vein's key in its state table, what was left, and how many
## seconds were still to rest (-1: not resting).
var vein_key: Variant = null
var restore_left: int = -1
var restore_wait: float = -1.0

## WHO WORKS THE VEIN (an auto miner): one miner a vein. The miner digs from the same store a drill
## does and waits out the same rest.
var claimed_by: Node = null

## Жила выработана: руды в ней сейчас нет (идёт отдых или её занял шахтёр).
func is_depleted() -> bool:
	return _available <= 0

## Take the vein for a miner. Refused if another miner has it.
func claim(by: Node) -> bool:
	# АВТО-ШАХТЁР НА ДЕРЕВО НЕ СТАВИТСЯ, И ЭТО ПРАВИЛО, А НЕ НЕДОДЕЛКА. Руда — экономика
	# стоячая: нашёл жилу, поставил базу, вернулся за грузом. Дерево — экономика ездящая: оно
	# раскидано поодиночке, и шахтёр на одном дереве был бы шахтёром на одном дереве. Что
	# встанет на его место для леса, см. комментарий у wood_chance в resource_nodes.gd.
	if is_wood:
		return false
	if by == null:
		return false
	if claimed_by != null and is_instance_valid(claimed_by) and claimed_by != by:
		return shares_claim(by)            # a miner of the SAME machine digs alongside
	claimed_by = by
	return true

## Miners on one machine share its vein: three on a rig by one vein used to leave two idle (the
## first claimed, the rest found nothing free). A different machine still may not.
func shares_claim(by: Node) -> bool:
	if by == null or claimed_by == null or not is_instance_valid(claimed_by):
		return false
	return by == claimed_by or (by.get_parent() != null and by.get_parent() == claimed_by.get_parent())

func release(by: Node) -> void:
	if claimed_by == by:
		claimed_by = null
		# hand it to a sibling still digging it, so its claim is not lost under it
		var p: Node = by.get_parent() if is_instance_valid(by) else null
		if p != null:
			for b in p.get_children():
				if b != by and b.get("_vein") == self:
					claimed_by = b
					break

## One ore for the miner that holds the vein, out of the same store a drill digs.
func mine_for_claimer(by: Node) -> bool:
	if claimed_by == null or not is_instance_valid(claimed_by):
		claimed_by = by                    # its holder left: whoever still digs it takes it
	if not (claimed_by == by or shares_claim(by)) or is_wood or is_depleted():
		return false
	_eject_one()
	_available -= 1
	_after_take()
	return true


var _rest_time: float = 5.0

func _ready() -> void:
	current_hp = max_hp
	_rest_time = $RestTimer.wait_time
	if is_wood:
		return
	var st: Vector3 = vein_stats(vein_key if vein_key != null
			else "%d,%d" % [roundi(global_position.x * 2.0), roundi(global_position.z * 2.0)])
	ore_total = int(st.x)
	_rest_time = st.y
	max_hp = maxi(roundi(float(max_hp) * st.z), 1)
	current_hp = max_hp
	_available = ore_total if restore_left < 0 else clampi(restore_left, 0, ore_total)
	if _available <= 0:
		_set_solid(false)
		$RestTimer.start(maxf(restore_wait, 0.05))

# Урон по жиле: списываем HP и выбрасываем руду, пока её не останется пропорционально HP.
func hurt(damage: int = 10) -> void:
	if _available <= 0:
		return

	var owner_node: Node = get_parent()
	if owner_node != null and owner_node.has_method("vein_hit"):
		owner_node.vein_hit(self)
	Sfx.at("chop" if is_wood else "mine", global_position + Vector3.UP)   # the key's own gap paces a drill
	if not is_wood:
		var per: int = maxi(max_hp / ore_total, 1)
		_dmg += damage
		while _dmg >= per and _available > 0:
			_dmg -= per
			_eject_one()
			_available -= 1
		current_hp = max_hp - _dmg
		_after_take()
		return
	current_hp = clampi(current_hp - damage, 0, max_hp)
	var want_left: int = int(float(current_hp) / float(max_hp) * MAX_RESOURCES)
	while _available > want_left:
		_eject_one()
		_available -= 1
		if is_wood and _available <= 0:
			Q.report("tree_felled", 1)          # the blow that brings the tree down (Marlit's line)

	# R the hit's time (shake), G what the shader breaks by, A the metal. AN ORE VEIN BREAKS BY WHAT
	# IT HAS THROWN, NOT BY ITS HP: a part goes at its break point (0.8 ... 0.0) and an ore leaves when
	# int(hp * 5) drops, so by HP every part went one ore late - and the last one, at 0.0, never went,
	# since the fifth ore leaves under a fifth of HP and an empty vein takes no more hits. A tree keeps
	# its HP for the lean and reads 0 the moment its last wood is out, so it falls on that blow.
	var share: float = float(current_hp) / float(max_hp)
	if _available <= 0:
		share = 0.0
	_write_shader_data(Color(_now(), share, 0.0, float(ore_type)))

	if _available <= 0:
		_set_solid(false)
		$RestTimer.start()

## An ore vein after ore left it: the picture breaks by what is left, a spent vein rests, and the
## owner is told, so the state outlives this node.
func _after_take() -> void:
	_write_shader_data(Color(_now(), float(_available) / float(ore_total), 0.0, float(ore_type)))
	if _available <= 0:
		_dmg = 0
		_set_solid(false)
		$RestTimer.start(_rest_time)
	_tell_state()

func _tell_state() -> void:
	var owner_node: Node = get_parent()
	if vein_key != null and owner_node != null and owner_node.has_method("ore_state_set"):
		owner_node.ore_state_set(vein_key, _available, _rest_time if _available <= 0 else -1.0)

## AN EMPTY VEIN IS NOT IN THE WAY. What stays of a worked-out vein is rubble and of a felled tree
## a stump, and a 3 m cylinder (a 7 m trunk) left standing over them stopped machines and shots on
## air. The collider goes with the last ore and comes back with the refill; a vein the auto miner
## holds stays open the whole time. Deferred: `hurt` runs inside a physics traversal.
func _set_solid(on: bool) -> void:
	var col := get_node_or_null("CollisionShape3D") as CollisionShape3D
	if col != null:
		col.set_deferred("disabled", not on)

## A REFILL WAITS FOR A MACHINE TO LEAVE (TerraTech's rule for what regrows): a collider switched on
## inside a machine throws it out with the full force of the solver. Asked with the vein's own shape,
## against machines (16) ONLY: loose items and blocks are not asked, because the ore the vein itself
## threw lies round its edge, inside that shape - asking them, measured, kept every vein empty until
## its own ore was picked up. A loose thing in the way is simply pushed out.
const BLOCKING_MASK := 16
## How long a blocked refill waits before it asks again.
const BLOCKED_RETRY := 3.0

func _spot_blocked() -> bool:
	var col := get_node_or_null("CollisionShape3D") as CollisionShape3D
	if col == null or col.shape == null or not is_inside_tree():
		return false
	var q := PhysicsShapeQueryParameters3D.new()
	q.shape = col.shape
	q.transform = col.global_transform
	q.collision_mask = BLOCKING_MASK
	q.exclude = [get_rid()]
	return not get_world_3d().direct_space_state.intersect_shape(q, 1).is_empty()

# Штампуем один ресурс в мир рядом с жилой и красим его под цвет жилы.
func _eject_one() -> void:
	if resource_tscn == null:
		return
	var res: Node3D = resource_tscn.instantiate()
	# Выброшенная руда обязана лечь в /root/Main/objects — там живут ВСЕ свободные предметы
	# мира, и по этому родителю их узнают приёмник, упаковщик, подбор в руку и сохранение
	# мира. Раньше она падала под жилу, то есть в узел СТРИМИНГА залежей: формально в мире,
	# а по факту невидимая для всего, кроме коллектора (он смотрит на freeze, а не на имя).
	var objects: Node = get_node_or_null("/root/Main/objects")
	if objects == null:
		objects = get_parent()                # мира ещё нет (тест сцены) — как раньше, под жилу
	objects.add_child(res)
	# round the outside of the drawn vein, not inside it: veins are drawn at a size (`vein_basis`)
	var s: float = (get_meta("vein_basis") as Basis).get_scale().x if has_meta("vein_basis") else 1.0
	var a: float = randf() * TAU
	var r: float = 0.55 * s + randf_range(0.3, 1.0)
	res.global_position = global_position + Vector3(cos(a) * r, 0.4 * s + 0.6, sin(a) * r)
	if is_wood and "type" in res:
		res.type = res.Type.WOOD              # дерево: свой цвет, тинт жилы не нужен
	elif res.has_method("set_metal"):
		# ore_type жилы — это и есть индекс металла (G.Metal): спавнер раздаёт типы по тому же
		# списку цветов, что и G.METAL_COLOR. Цвет ставит сам set_metal, поэтому set_tint здесь
		# не нужен — иначе жила и её руда могли бы разъехаться по цвету.
		res.set_metal(ore_type)
	elif res.has_method("set_tint"):
		res.set_tint(ore_color)
	Q.report("ore_mined", 1)                    # прогресс заданий на добычу

# Жила восстановилась: снова полна руды, HP сброшен.
func _on_rest_timer_timeout() -> void:
	# ДЕРЕВО НЕ ОТДЫХАЕТ, А ПЕРЕЕЗЖАЕТ. Срубленное дерево не отрастает на пне; вместо этого
	# лес прорастает в другом месте — пересадку делает владелец, он один знает правила
	# раскладки (resource_nodes.replant).
	if is_wood:
		var owner_node: Node = get_parent()
		if owner_node != null and owner_node.has_method("replant") and owner_node.replant(self):
			return                              # узел уже освобождён пересадкой
	if _spot_blocked():
		$RestTimer.start(BLOCKED_RETRY)
		return
	$RestTimer.wait_time = _rest_time       # start(BLOCKED_RETRY) above rewrote it
	_set_solid(true)
	_available = MAX_RESOURCES if is_wood else ore_total
	current_hp = max_hp
	_dmg = 0
	_tell_state()
	# B — время респавна (рост), G=1 → жила целая, A — тип.
	_write_shader_data(Color(0.0, 1.0, _now(), float(ore_type)))

func _now() -> float:
	var owner_node: Node = get_parent()
	if owner_node != null and owner_node.has_method("shader_now"):
		return owner_node.shader_now()
	return Time.get_ticks_msec() / 1000.0

# The vein's state for resources/resource.gdshader, in every MultiMesh of the owner (ore and wood).
func _write_shader_data(data: Color) -> void:
	var owner_node: Node = get_parent()
	if owner_node != null and owner_node.has_method("write_custom"):
		owner_node.write_custom(instance_id, data, self)
