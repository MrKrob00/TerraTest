# block_map.gd
extends Node3D

const MAP_SIZE_X = 11
const MAP_SIZE_Y = 11
const MAP_SIZE_Z = 11
const CENTER = 5                     # индекс центральной клетки по каждой оси (0..10 → центр 5)
const CELL_SIZE = 1.0

var map: Array = []
var node_map: Dictionary = {}
var rotation_map: Dictionary = {}
# Multi-cell blocks (SELLER/PROCESSOR 2x2x2) occupy 8 cells but node and rotation live on ONE
# anchor cell. cell_owner: "x,y,z" of any occupied cell -> "ax,ay,az" of the anchor. So any of the
# 8 leads to the same block (select or remove from any side) and all 8 read as occupied.
var cell_owner: Dictionary = {}

## A file name, not a path: the layout belongs to the SLOT (G.slot_path), like the rest of the
## world state.
const SAVE_FILE = "vehicle_layout.json"

# ── Attach faces (which sides a block joins with) ────────────────────────────
# The face list lives on the BLOCK itself (VehicleBlock.connect_faces), edited per scene in the
# inspector like factory in/out. Only the rule for reading them stays here. It used to be a table
# in code, keyed by block type in unrotated axes: fixing one drill face meant editing a script,
# and block rotation took no part in the check at all.
const ALL_FACES := ["top", "bottom", "left", "right", "front", "back"]
const OPPOSITE := {
	"top": "bottom", "bottom": "top",
	"left": "right", "right": "left",
	"front": "back", "back": "front",
}
# Face name -> outward direction. Matches FACE_VECS in VehicleBlock.
const FACE_DIR := {
	"right": Vector3i(1, 0, 0), "left": Vector3i(-1, 0, 0),
	"top": Vector3i(0, 1, 0), "bottom": Vector3i(0, -1, 0),
	"back": Vector3i(0, 0, 1), "front": Vector3i(0, 0, -1),
}

## Does the block ALREADY STANDING here accept a neighbour at face `face`? Faces are taken rotated
## and PER CELL (VehicleBlock.connects_at): a mounted block faces anywhere, and on a large block
## each cell of a side may answer for itself.
##
## cell is the cell being attached to (for a normal block that is also its anchor).
func node_accepts_face(node: Node, face: String, cell: Vector3i = Vector3i.ZERO) -> bool:
	if node == null or not is_instance_valid(node) or not (node is VehicleBlock):
		return true                        # not a block (or already destroyed): do not block it
	if not FACE_DIR.has(face):
		return true
	return (node as VehicleBlock).connects_at(cell - _anchor_of(cell), FACE_DIR[face] as Vector3i)

# Can new_type attach to face attach_face of neighbor_type?
var is_station: bool = false

# What may be placed on a STATIONARY base. Forbidden is exactly what a base physically has no use
# for: a CABIN (it has its own core, a second one would make it a machine) and WHEELS (it does not
# drive).
#
# Weapons used to be forbidden too, which was a design mistake rather than protection: the game
# asks you to defend YOUR base (quest "Hold the Line") and a turret could not be placed on it.
# Supports were forbidden as well - self-contradictory ever since a support became a STATIONARY
# block (G.STATIONARY_BLOCKS), i.e. a possible base core. Everything else - factory, armour, frame,
# power, weapons - makes sense on a base.
const _STATION_BANNED := [G.Block.CABIN, G.Block.WHEEL, G.Block.SMALL_WHEEL, G.Block.BIG_WHEEL,
		G.Block.TOP_WHEEL, G.Block.STAB_WHEEL]

func _allowed_on_station(bt: int) -> bool:
	return not _STATION_BANNED.has(bt)

## Can new_node attach to face attach_face of whatever stands in cell (nx,ny,nz)? We take the CELL,
## not a type: through it we reach the neighbour NODE and therefore its rotation - without rotation
## "rear face" means nothing, since a mounted block faces any which way.
func can_attach(nx: int, ny: int, nz: int, new_node: Node, attach_face: String) -> bool:
	var new_type: int = int(new_node.get("block")) if new_node != null else G.Block.EMPTY
	# A STATIONARY block ON a machine is ALLOWED. The ban was redundant: such a block only works while
	# anchored (_factory_active), and a machine carrying one earns the right to anchor
	# (vehicle_body_3d.has_stationary). Hauling a seller around and stopping to sell is normal play.
	if is_station and not _allowed_on_station(new_type):
		return false
	# The NEW block's own face is not checked: building rotates it so its marked side meets the
	# neighbour (_face_orient), so "join with the right face" is satisfiable from any face. The only
	# failing case is having no faces marked at all.
	if new_node is VehicleBlock and (new_node as VehicleBlock).connect_faces == 0:
		return false
	# The NEIGHBOUR does decide whether to accept: nothing mounts on a drill head.
	return node_accepts_face(find_block(nx, ny, nz), attach_face, Vector3i(nx, ny, nz))

## Starting build preset. 0 is the ordinary machine (the player's - do not touch), 1+ are enemy
## variants. The enemy spawner sets a preset BEFORE adding the node to the tree.
@export var layout_preset: int = 0

# WHAT the factory block in this cell produces: "x,y,z" -> index (G.Comp for the component
# factory, G.Block for the fabricator). It lives HERE rather than only on the node for one reason:
# the choice must survive saving. The layout stores cells, not nodes, so an instance field would
# reset to the scene value on every load.
var output_map: Dictionary = {}

# Factory block PORTS: anchor cell "x,y,z" -> that block's port dictionary (FactoryBlock.ports).
# Here for the same reason as output_map: the player's setting must survive the save.
var port_map: Dictionary = {}

# BATTERY CHARGE in this cell: "x,y,z" -> stored energy. Same reason as output_map and port_map:
# charge is a property of the BLOCK (battery.gd) while the save stores cells. Without this map a
# full battery came back empty after a reload - the same way it used to empty when removed.
var charge_map: Dictionary = {}

func _ready() -> void:
	_init_map()
	_define_layout()
	_spawn_all()

# ── Init ────────────────────────────────────────────────────────────────────
func _init_map() -> void:
	map = []
	for x in range(MAP_SIZE_X):
		var plane: Array = []
		for y in range(MAP_SIZE_Y):
			var row: Array = []
			for z in range(MAP_SIZE_Z):
				row.append(G.Block.EMPTY)
			plane.append(row)
		map.append(plane)

# ── Layouts ─────────────────────────────────────────────────────────────────
func _define_layout() -> void:
	match layout_preset:
		1: _layout_dual_gun()
		2: _layout_laser_scout()
		3: _layout_starter()
		4: _layout_cabin_only()
		# Enemy machines: the ladder lives in ENEMY_BUILDS, so a new variant is a table row and
		# one number here, not another _layout_ function.
		5, 6, 7, 8, 9, 10, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34:
			_layout_enemy(layout_preset)
		11: _layout_outpost()
		12: _layout_fort()
		13: _layout_turret_post(G.Block.GUN)
		14: _layout_turret_post(G.Block.SHOTGUN)
		15: _layout_turret_post(G.Block.LASER)
		16: _layout_shielded_tower(G.Block.GUN)      # Charlie Watchtower
		17: _layout_shielded_tower(G.Block.ROCKET)   # SAM Site Ridge
		18: _layout_charge_tower()                   # зарядная башня к ним обеим
		_: _layout_default()

# New game: ONE cabin (the starter kit drops into the world nearby, see world_persist.gd). The
# core sits at the grid CENTRE, and add-on floors count from it (+5).
func _layout_cabin_only() -> void:
	set_block(5, 5, 5, G.Block.CABIN, 0.0)

# Starter machine (spawned for free on death): cabin, 4 wheels, a couple of blocks, a gun and a
# drill. More compact than the default.
func _layout_starter() -> void:
	set_block(5, 5, 5, G.Block.CABIN, 0.0)
	set_block(4, 5, 5, G.Block.WHEEL, PI / 2)
	set_block(6, 5, 5, G.Block.WHEEL, -PI / 2)
	set_block(4, 5, 6, G.Block.WHEEL, PI / 2)
	set_block(6, 5, 6, G.Block.WHEEL, -PI / 2)
	set_block(5, 5, 6, G.Block.BLOCK, 0.0)
	set_block(5, 6, 6, G.Block.BLOCK, 0.0)
	set_block(5, 5, 4, G.Block.DRILL, 0.0)
	set_block(5, 6, 5, G.Block.LASER, 0.0)
	set_block(5, 5, 6, G.Block.BLOCK, 0.0)
	set_block(5, 5, 7, G.Block.BLOCK, 0.0)

# Base build: cabin, 6 wheels, drill, gun - the player's starting machine, do not change.
func _layout_default() -> void:
	_wheels_6()
	set_block(5, 5, 5, G.Block.CABIN, 0.0)
	set_block(5, 5, 4, G.Block.DRILL, 0.0)
	set_block(5, 6, 5, G.Block.LASER, 0.0)
	#set_block(5, 1, 5, G.Block.COLLECTOR, 0.0)
	#set_block(3, 1, 7, G.Block.RECEIVER, -PI/2)
	#set_block(4, 1, 7, G.Block.BELT, 0.0)
	#set_block(4, 1, 6, G.Block.PROCESSOR, 0.0)
	#set_block(4, 1, 4, G.Block.BELT, 0.0)
	#set_block(4, 1, 3, G.Block.SELLER, 0.0)

# Heavy: two guns, spread along the hull (5 and 7, not 5 and 6) so the weight does not sit on the
# front of the wheelbase and the machine noses down less under braking or AI reverse.
func _layout_dual_gun() -> void:
	_wheels_6()
	set_block(5, 5, 5, G.Block.CABIN, 0.0)
	set_block(5, 6, 5, G.Block.GUN, 0.0)
	set_block(5, 6, 7, G.Block.GUN, 0.0)

func _layout_laser_scout() -> void:
	_wheels_6()
	set_block(5, 5, 5, G.Block.CABIN, 0.0)
	set_block(5, 6, 5, G.Block.LASER, 0.0)

func _wheels_6() -> void:
	set_block(4, 5, 5, G.Block.WHEEL, PI / 2)
	set_block(6, 5, 5, G.Block.WHEEL, -PI / 2)
	set_block(4, 5, 6, G.Block.WHEEL, PI / 2)
	set_block(6, 5, 6, G.Block.WHEEL, -PI / 2)
	set_block(4, 5, 7, G.Block.WHEEL, PI / 2)
	set_block(6, 5, 7, G.Block.WHEEL, -PI / 2)
	set_block(5, 5, 6, G.Block.BLOCK, 0.0)
	set_block(5, 5, 7, G.Block.BLOCK, 0.0)

# ══════════════════════════════════════════════════════════════════════════════
# ENEMY BUILDS: one table, not a function per machine
# ══════════════════════════════════════════════════════════════════════════════
# Ordered by DANGER and by size at once: further down means bigger, better armoured and meaner.
# The spawner picks a TIER by the player's machine value and the world ramp, then rolls one of the
# variants inside it (enemy_spawner.PRESET_TIERS), and a killed machine's value becomes RP
# (G.rp_for_kill) - so "bigger" automatically means "worth more".
#
# THREE TO FOUR BUILDS PER STEP, because one machine per tier means the horizon always holds the
# same silhouette: the player learns a single answer and the whole step is solved. Variants share
# the chassis and differ in armament and in which of shield / repair field they carry.
#
# SINGLE-CELL BLOCKS ONLY. A 2x1x1 or 2x1x2 occupies one grid cell but has a wider collider, so a
# neighbour would clip into it. Size is gained by count, not by block dimensions.
#
# WHAT GOES WHERE IS A RULE, NOT TASTE, and it is the reverse of what these builds used to do.
# Value decides depth: cabin, then battery, then shield and repair field, then guns. The battery
# sits in the MIDDLE OF THE DECK - hull under it, a turret or a dome over it, flank plates on both
# sides, blocks fore and aft - so it is enclosed on six sides. Guns live on the outside, where they
# need the firing arc and where the player is meant to be able to strip them. Power used to hang
# off the tail, which read as a feature ("go round the back and de-power it") and was really one
# cheap move that deleted the whole shield mechanic.
#
# A SHIELD PROTECTS WHAT ITS SPHERE COVERS, not what is bolted to the machine, so its cell is
# geometry: on a long hull a dome parked at the tail lets a frontal shot reach the cabin before it
# ever enters the sphere. It goes over the battery, near the middle.

## rows  - floor length in cells, z = 5 .. 5+rows-1 (the cabin takes z=5)
## wheel - wheel block for both side rows
## wide  - 3-cell-wide floor (x 4..6) with the wheels moved out to x 3/7. A one-cell spine with
##         wheels bolted to it is why the machines read as small on an 11-cube grid.
## nose  - armour plate ahead of the floor
## deck  - second floor, front to back from z=5. EMPTY leaves the cell open.
## top   - third floor, front to back from z=6. Needs the deck cell under it filled.
const ENEMY_BUILDS: Dictionary = {
	# ── Tier 0: light scouts. Small wheels, one gun, no plating - the machine a first cabin can
	# actually beat.
	5:  {"rows": 2, "wheel": G.Block.SMALL_WHEEL, "wide": false, "nose": false,
		"deck": [G.Block.GUN]},
	19: {"rows": 2, "wheel": G.Block.SMALL_WHEEL, "wide": false, "nose": false,
		"deck": [G.Block.LASER]},
	20: {"rows": 2, "wheel": G.Block.SMALL_WHEEL, "wide": false, "nose": false,
		"deck": [G.Block.SHOTGUN]},

	# ── Tier 1: runners. Full wheels and a nose plate: they have to be let close, or outrun.
	6:  {"rows": 3, "wheel": G.Block.WHEEL, "wide": false, "deck": [G.Block.SHOTGUN]},
	21: {"rows": 3, "wheel": G.Block.WHEEL, "wide": false,
		"deck": [G.Block.GUN, G.Block.EMPTY, G.Block.GUN]},
	22: {"rows": 3, "wheel": G.Block.WHEEL, "wide": false, "deck": [G.Block.LASER]},

	# ── Tier 2: raiders. First WIDE hull and flank plates - the first machine that cannot be shot
	# down on approach and has to be out-manoeuvred.
	7:  {"rows": 3, "wheel": G.Block.WHEEL, "wide": true,
		"deck": [G.Block.GUN, G.Block.BLOCK, G.Block.GUN]},
	23: {"rows": 3, "wheel": G.Block.WHEEL, "wide": true,
		"deck": [G.Block.SHOTGUN, G.Block.BLOCK, G.Block.GUN]},
	24: {"rows": 3, "wheel": G.Block.WHEEL, "wide": true,
		"deck": [G.Block.LASER, G.Block.BLOCK, G.Block.GUN]},
	25: {"rows": 3, "wheel": G.Block.WHEEL, "wide": true,
		"deck": [G.Block.POUND_CANNON, G.Block.BLOCK, G.Block.EMPTY]},

	# ── Tier 3: lancers. THE STEP WHERE POWER APPEARS - a battery feeding a dome or a repair field.
	# The fight becomes two stages, drain it and then break the machine, and the battery is what is
	# drained: panels stand only on bases, so a driving machine spawns full and never refills.
	8:  {"rows": 4, "wheel": G.Block.WHEEL, "wide": true,
		"deck": [G.Block.LASER, G.Block.BLOCK, G.Block.BATTERY, G.Block.GUN],
		"top": [G.Block.EMPTY, G.Block.SHIELD]},
	26: {"rows": 4, "wheel": G.Block.WHEEL, "wide": true,
		"deck": [G.Block.GUN, G.Block.BLOCK, G.Block.BATTERY, G.Block.GUN],
		"top": [G.Block.EMPTY, G.Block.REGEN]},
	27: {"rows": 4, "wheel": G.Block.WHEEL, "wide": true,
		"deck": [G.Block.ROCKET, G.Block.BLOCK, G.Block.BATTERY, G.Block.GUN],
		"top": [G.Block.EMPTY, G.Block.SHIELD]},
	28: {"rows": 4, "wheel": G.Block.WHEEL, "wide": true,
		"deck": [G.Block.SHOTGUN, G.Block.BLOCK, G.Block.BATTERY, G.Block.LASER],
		"top": [G.Block.EMPTY, G.Block.REGEN]},

	# ── Tier 4: breakers. Big wheels, heavy barrels, and both kinds of power on some variants.
	# Already a LARGE machine, read off the horizon.
	9:  {"rows": 4, "wheel": G.Block.BIG_WHEEL, "wide": true,
		"deck": [G.Block.POUND_CANNON, G.Block.BLOCK, G.Block.BATTERY, G.Block.BLOCK],
		"top": [G.Block.GUN, G.Block.SHIELD, G.Block.GUN]},
	29: {"rows": 4, "wheel": G.Block.BIG_WHEEL, "wide": true,
		"deck": [G.Block.MORTAR, G.Block.BLOCK, G.Block.BATTERY, G.Block.BLOCK],
		"top": [G.Block.GUN, G.Block.SHIELD, G.Block.REGEN]},
	30: {"rows": 4, "wheel": G.Block.BIG_WHEEL, "wide": true,
		"deck": [G.Block.POUND_CANNON, G.Block.BLOCK, G.Block.BATTERY, G.Block.POUND_CANNON],
		"top": [G.Block.GUN, G.Block.REGEN]},
	31: {"rows": 4, "wheel": G.Block.BIG_WHEEL, "wide": true,
		"deck": [G.Block.ROCKET, G.Block.BLOCK, G.Block.BATTERY, G.Block.LASER],
		"top": [G.Block.GUN, G.Block.SHIELD]},

	# ── Tier 5: siege. The largest: five rows on big wheels, TWO batteries, dome and repair field
	# together, four barrels. Meeting one is an event, not a routine skirmish.
	10: {"rows": 5, "wheel": G.Block.BIG_WHEEL, "wide": true,
		"deck": [G.Block.MORTAR, G.Block.BLOCK, G.Block.BATTERY, G.Block.BATTERY, G.Block.BLOCK],
		"top": [G.Block.GUN, G.Block.SHIELD, G.Block.REGEN, G.Block.ROCKET]},
	32: {"rows": 5, "wheel": G.Block.BIG_WHEEL, "wide": true,
		"deck": [G.Block.POUND_CANNON, G.Block.BLOCK, G.Block.BATTERY, G.Block.BATTERY,
			G.Block.BLOCK],
		"top": [G.Block.GUN, G.Block.SHIELD, G.Block.REGEN, G.Block.POUND_CANNON]},
	33: {"rows": 5, "wheel": G.Block.BIG_WHEEL, "wide": true,
		"deck": [G.Block.MORTAR, G.Block.BLOCK, G.Block.BATTERY, G.Block.BATTERY, G.Block.BLOCK],
		"top": [G.Block.LASER, G.Block.SHIELD, G.Block.REGEN, G.Block.LASER]},
	34: {"rows": 5, "wheel": G.Block.BIG_WHEEL, "wide": true,
		"deck": [G.Block.ROCKET, G.Block.BLOCK, G.Block.BATTERY, G.Block.BATTERY, G.Block.BLOCK],
		"top": [G.Block.GUN, G.Block.SHIELD, G.Block.REGEN, G.Block.GUN]},
}

func _layout_enemy(preset: int) -> void:
	var b: Dictionary = ENEMY_BUILDS.get(preset, {})
	if b.is_empty():
		_layout_default()
		return
	var rows: int = maxi(int(b.get("rows", 2)), 1)
	var wide: bool = b.get("wide", false) == true
	var half: int = 1 if wide else 0
	var deck: Array = b.get("deck", [])
	var top: Array = b.get("top", [])

	# FLOOR. The cabin sits at the grid centre because that is the machine's origin (cell_to_local
	# counts from CENTER); the hull runs backwards from it.
	set_block(5, 5, 5, G.Block.CABIN, 0.0)
	for i in rows:
		for x in range(5 - half, 5 + half + 1):
			if x != 5 or i != 0:
				set_block(x, 5, 5 + i, G.Block.BLOCK, 0.0)
	if b.get("nose", true) == true:
		_front_armor(half)
	var zs: Array = []
	for i in rows:
		zs.append(5 + i)
	_side_wheels(int(b.get("wheel", G.Block.WHEEL)), zs, 2 if wide else 1)

	for i in deck.size():
		if int(deck[i]) != G.Block.EMPTY:
			set_block(5, 6, 5 + i, int(deck[i]), 0.0)
	# FLANK PLATES cover the MIDDLE of the deck, which is exactly where the power stands. Skipping
	# the end cells is not laziness: the ends hold guns, and armour must not grow over a barrel.
	for i in range(1, deck.size() - 1):
		if int(deck[i]) != G.Block.EMPTY:
			_side_armor(5 + i)
	for i in top.size():
		if int(top[i]) != G.Block.EMPTY:
			set_block(5, 7, 6 + i, int(top[i]), 0.0)

## Wheels along the hull sides. Rotations are not by eye: every wheel has connect_faces = 2, i.e.
## it joins with its REAR (+Z), so that is the side that must face the hull. A +-90 deg yaw turns +Z
## into -+X, so the left row looks right and the right row looks left, both into the hull.
## dx is how far out the rows sit: 1 against a one-cell spine, 2 against a three-cell floor. Either
## way the wheel meets the hull cell right beside it, so the rotation does not change with width.
func _side_wheels(kind: int, zs: Array, dx: int = 1) -> void:
	for z in zs:
		set_block(5 - dx, 5, int(z), kind, PI / 2)
		set_block(5 + dx, 5, int(z), kind, -PI / 2)

## A pair of side plates on the SECOND FLOOR, in cell z. The plate joins with its REAR like a wheel
## (connect_faces = 2), so it is turned the same way: unrotated, its only face would point outward
## into nothing, connectivity (_reachable_cells) would call it detached, and the machine would drop
## it on birth.
##
## Cell (5, 6, z) must be HULL: a gun has connect_faces = 32 (bottom only), nothing mounts on its
## side.
func _side_armor(z: int) -> void:
	set_block(4, 6, z, G.Block.ARMOR, PI / 2)
	set_block(6, 6, z, G.Block.ARMOR, -PI / 2)

## Front plate ahead of the cabin. Zero rotation: its rear face (+Z) already looks into the cabin,
## which accepts neighbours on every side.
## half widens the plate to match the floor: 0 is a single plate on a spine, 1 covers a three-cell
## nose. Each plate accepts its neighbour behind it, so every one of them has hull to bolt to.
func _front_armor(half: int = 0) -> void:
	for x in range(5 - half, 5 + half + 1):
		set_block(x, 5, 4, G.Block.ARMOR, 0.0)

## ENEMY BASES (presets 11-12). The core is a SUPPORT, not a cabin: a base does not drive and holds
## on to the same thing ours does (G.STATIONARY_BLOCKS). It has no cabin on purpose - its death is
## decided by the core watchdog in MachineBody, exactly like the player's station.
##
## There are no wheels, so the hull can spread sideways freely; guns, as everywhere, join with the
## BOTTOM only (connect_faces = 32), so each one stands ON a block rather than in the air. Armour
## joins with its rear (+Z), hence the same +-90 deg on the flanks as on machines.

## Outpost: support, a couple of blocks, two guns and flank armour. The first base the player meets.
func _layout_outpost() -> void:
	set_block(5, 5, 5, G.Block.SUPPORT, 0.0)
	set_block(5, 5, 6, G.Block.BLOCK, 0.0)
	set_block(5, 5, 4, G.Block.BLOCK, 0.0)
	set_block(5, 6, 5, G.Block.BLOCK, 0.0)
	_side_armor(5)
	set_block(5, 7, 5, G.Block.GUN, 0.0)
	set_block(5, 6, 6, G.Block.GUN, 0.0)

## Fort: wider, taller, with a rocket launcher and a battery. The battery is not there for energy (a
## base needs none) but for the blast: finishing a fort off at point blank should be dangerous.
func _layout_fort() -> void:
	set_block(5, 5, 5, G.Block.SUPPORT, 0.0)
	for z in [4, 6]:
		set_block(5, 5, z, G.Block.BLOCK, 0.0)
		set_block(5, 6, z, G.Block.BLOCK, 0.0)
	set_block(4, 5, 5, G.Block.BLOCK, 0.0)
	set_block(6, 5, 5, G.Block.BLOCK, 0.0)
	set_block(5, 6, 5, G.Block.BATTERY, 0.0)
	_side_armor(4)
	_side_armor(6)
	set_block(5, 7, 4, G.Block.GUN, 0.0)
	set_block(5, 7, 6, G.Block.ROCKET, 0.0)
	set_block(4, 6, 5, G.Block.GUN, PI / 2)
	set_block(6, 6, 5, G.Block.GUN, -PI / 2)

## ROTATING TOWER - a defensive tower like TerraTech's fortified points: a tall mast, shield on top,
## panels and battery at the base, guns on side consoles.
##
## The core is ROT_SUPPORT, and that changes the build itself. An outpost and a fort have a bolted
## hull, so they need guns pointing DIFFERENT ways: a turret covers +-yaw_limit and a fixed box
## otherwise has a dead zone behind it. Here the hull turns to the target itself
## (enemy_vehicle._turn_to_target), so both guns face forward and hit the same spot.
##
## THE ENERGY HERE IS REAL. Panels and battery work on an enemy exactly as on the player (the energy
## system lives in MachineBody) and the shield spends machine energy on every hit. Hence the way in:
## shoot the panels or the battery and the dome dies by itself.
##
## FOUR floors hold the height: the tower is visible from afar and a 4 m dome covers it whole. Guns
## join with the bottom only (connect_faces = 32), so each has a console block under it; the panel
## likewise, so it sits on a base block rather than on the bare core.
##
## The weapon is a PARAMETER: gun, shotgun and laser give three different towers from one layout -
## long range, close spread and a continuous beam.
func _layout_turret_post(weapon: int) -> void:
	set_block(5, 5, 5, G.Block.ROT_SUPPORT, 0.0)     # ядро: его и доворачивает ИИ
	set_block(5, 5, 4, G.Block.BLOCK, 0.0)
	set_block(5, 5, 6, G.Block.BLOCK, 0.0)
	set_block(4, 5, 5, G.Block.BATTERY, 0.0)         # запас: щит живёт с него, когда солнца мало
	set_block(6, 5, 5, G.Block.BLOCK, 0.0)
	set_block(5, 6, 5, G.Block.BLOCK, 0.0)           # мачта
	set_block(4, 6, 5, G.Block.BLOCK, 0.0)           # консоли под стволы
	set_block(6, 6, 5, G.Block.BLOCK, 0.0)
	set_block(5, 6, 4, G.Block.SOLAR, 0.0)           # питание щита
	set_block(5, 6, 6, G.Block.SOLAR, 0.0)
	set_block(5, 7, 5, G.Block.BLOCK, 0.0)
	set_block(4, 7, 5, weapon, 0.0)                  # стволы по бокам
	set_block(6, 7, 5, weapon, 0.0)
	set_block(5, 8, 5, G.Block.SHIELD, 0.0)          # купол накрывает всю башню

# ── SHIELDED TOWER (presets 16-17) and its CHARGING TOWERS (18) ──────────────
# The pair behind the story Watchtower and SAM. One idea: a target under a dome held up by OTHER
# machines around it, and while one of them lives the dome stays.
#
# It runs ON ORDINARY RULES, without a line of code in the quest. The tower has a shield and
# batteries but NOT ONE PANEL: its own production is zero, and every hit on the dome spends a
# reserve it cannot refill. Charging towers stand around it - panels, battery and a
# WIRELESS_CHARGER that pours energy into a neighbour of ITS OWN faction (that is what was fixed in
# the block: it used to feed player machines only). While one tower lives the shielded one gets
# current and the dome holds; kill them all and the reserve drains under fire.
#
# The player sees this without a hint: a charging beam runs from each tower to the shielded one.
func _layout_shielded_tower(weapon: int) -> void:
	set_block(5, 5, 5, G.Block.ROT_SUPPORT, 0.0)     # ядро: его доворачивает ИИ
	set_block(5, 5, 4, G.Block.BLOCK, 0.0)
	set_block(5, 5, 6, G.Block.BLOCK, 0.0)
	# TWO batteries instead of panels: this is CAPACITY, not production. Without capacity the charger
	# has nowhere to pour (wireless_charger looks for a battery block on the target) and the whole
	# "towers hold the shield" chain would not assemble.
	set_block(4, 5, 5, G.Block.BATTERY, 0.0)
	set_block(6, 5, 5, G.Block.BATTERY, 0.0)
	set_block(5, 6, 5, G.Block.BLOCK, 0.0)           # мачта
	set_block(4, 6, 5, G.Block.BLOCK, 0.0)           # консоли под стволы
	set_block(6, 6, 5, G.Block.BLOCK, 0.0)
	set_block(5, 7, 5, G.Block.BLOCK, 0.0)
	set_block(4, 7, 5, weapon, 0.0)                  # стволы низом на консолях (connect_faces = 32)
	set_block(6, 7, 5, weapon, 0.0)
	set_block(5, 8, 5, G.Block.SHIELD, 0.0)          # купол накрывает всю вышку

func _layout_charge_tower() -> void:
	set_block(5, 5, 5, G.Block.SUPPORT, 0.0)         # ядро: стационарное, никуда не едет
	set_block(4, 5, 5, G.Block.BLOCK, 0.0)           # опоры под панели: у SOLAR
	set_block(6, 5, 5, G.Block.BLOCK, 0.0)           # connect_faces = 32, ей нужен блок СНИЗУ
	set_block(4, 6, 5, G.Block.SOLAR, 0.0)
	set_block(6, 6, 5, G.Block.SOLAR, 0.0)
	set_block(5, 6, 5, G.Block.BATTERY, 0.0)         # свой запас — из него и льём
	set_block(5, 7, 5, G.Block.WIRELESS_CHARGER, 0.0)

# ── Spawning all blocks ─────────────────────────────────────────────────────
func _spawn_all() -> void:
	for x in range(MAP_SIZE_X):
		for y in range(MAP_SIZE_Y):
			for z in range(MAP_SIZE_Z):
				var block: G.Block = map[x][y][z]
				# anchor cells only, or a multi-cell block spawns eight times
				if block != G.Block.EMPTY and _is_anchor(x, y, z):
					spawn_block(block, x, y, z)

# True if (x,y,z) is its block's anchor cell (always true for single-cell blocks).
func _is_anchor(x: int, y: int, z: int) -> bool:
	var key := "%d,%d,%d" % [x, y, z]
	return cell_owner.get(key, key) == key

# ── Cells a block occupies ──────────────────────────────────────────────────
# Anchor (x,y,z). A 2x2x2 (SELLER/PROCESSOR) takes x-1..x, y..y+1, z-1..z (8 cells); everything
# else takes one.
func _block_footprint(block: int, x: int, y: int, z: int) -> Array:
	if block == G.Block.PROCESSOR or block == G.Block.SELLER or block == G.Block.FABRICATOR:
		var cells: Array = []
		for dx in [-1, 0]:
			for dy in [0, 1]:
				for dz in [-1, 0]:
					cells.append(Vector3i(x + dx, y + dy, z + dz))
		return cells
	if block == G.Block.ARMOR4:
		var cells4: Array = []               # 2×1×2 (xyz), как у COAL_GEN
		for dx in [-1, 0]:
			for dz in [-1, 0]:
				cells4.append(Vector3i(x + dx, y, z + dz))
		return cells4
	if block == G.Block.COAL_GEN:
		var cells2: Array = []               # 2×1×2 (xyz): dx∈[-1,0], dy=0, dz∈[-1,0]
		for dx in [-1, 0]:
			for dz in [-1, 0]:
				cells2.append(Vector3i(x + dx, y, z + dz))
		return cells2
	if block == G.Block.BLOCK2 or block == G.Block.WEDGE2 \
			or block == G.Block.ARMOR2 or block == G.Block.HALF_BLOCK2:
		return [Vector3i(x - 1, y, z), Vector3i(x, y, z)]   # 2×1×1
	if block == G.Block.BLOCK3:
		return [Vector3i(x - 1, y, z), Vector3i(x, y, z), Vector3i(x + 1, y, z)]   # 3×1×1
	return [Vector3i(x, y, z)]

# Can `block` be placed with anchor (x,y,z)? All footprint cells in bounds and empty.
func can_place(block: int, x: int, y: int, z: int) -> bool:
	for c in _block_footprint(block, x, y, z):
		if not _in_bounds(c.x, c.y, c.z) or map[c.x][c.y][c.z] != G.Block.EMPTY:
			return false
	return true

# ── Write / read ────────────────────────────────────────────────────────────
func set_block(x: int, y: int, z: int, block: G.Block, rot = 0.0) -> bool:
	if not _in_bounds(x, y, z):
		push_warning("set_block: cell (%d,%d,%d) is out of bounds" % [x, y, z])
		return false
	if not can_place(block, x, y, z):
		return false   # overlap or edge: refuse
	var anchor := "%d,%d,%d" % [x, y, z]
	for c in _block_footprint(block, x, y, z):
		map[c.x][c.y][c.z] = block
		cell_owner["%d,%d,%d" % [c.x, c.y, c.z]] = anchor
	rotation_map[anchor] = rot if rot is Vector3 else Vector3(0, float(rot), 0)
	return true

func remove_block(x: int, y: int, z: int) -> void:
	if not _in_bounds(x, y, z):
		return
	# Removes the whole block even if a non-anchor cell of it was tapped.
	var anchor: String = cell_owner.get("%d,%d,%d" % [x, y, z], "%d,%d,%d" % [x, y, z])
	var parts := anchor.split(",")
	var ax := int(parts[0]); var ay := int(parts[1]); var az := int(parts[2])
	if not _in_bounds(ax, ay, az) or map[ax][ay][az] == G.Block.EMPTY:
		return
	for c in _block_footprint(map[ax][ay][az], ax, ay, az):
		if _in_bounds(c.x, c.y, c.z):
			map[c.x][c.y][c.z] = G.Block.EMPTY
			cell_owner.erase("%d,%d,%d" % [c.x, c.y, c.z])
	node_map.erase(anchor)
	rotation_map.erase(anchor)
	output_map.erase(anchor)
	port_map.erase(anchor)
	charge_map.erase(anchor)

func get_block(x: int, y: int, z: int) -> G.Block:
	if _in_bounds(x, y, z):
		return map[x][y][z]
	return G.Block.EMPTY

func find_block(x: int, y: int, z: int) -> Node3D:
	if not _in_bounds(x, y, z):
		push_warning("find_block: cell (%d,%d,%d) is out of bounds" % [x, y, z])
		return null
	# Any cell of a multi-cell block leads to its anchor node.
	var anchor: String = cell_owner.get("%d,%d,%d" % [x, y, z], "%d,%d,%d" % [x, y, z])
	var n = node_map.get(anchor, null)
	# THE NODE MAY ALREADY BE FREED while the map entry survives: blocks die through queue_free and
	# several paths lead there (blast, disassembly, build change). A reference to a freed instance is
	# NOT null, and returning it from a typed function crashes the call ("Trying to return a previously
	# freed instance") - that is exactly how the connectivity walk fell over after blocks were torn
	# off. The entry is cleaned here too, or the next call trips over the same one.
	if n != null and not is_instance_valid(n):
		node_map.erase(anchor)
		return null
	return n

func _in_bounds(x: int, y: int, z: int) -> bool:
	return (
		x >= 0 and x < MAP_SIZE_X and
		y >= 0 and y < MAP_SIZE_Y and
		z >= 0 and z < MAP_SIZE_Z
	)

# ── Spawning one block ──────────────────────────────────────────────────────
func spawn_block(block: G.Block, x: int, y: int, z: int) -> void:
	var scene: PackedScene = G.get_scene(block)
	if scene == null:
		push_warning("Сцена не назначена для блока: %s" % G.Block.keys()[block])
		return

	var instance: Node3D = scene.instantiate()
	add_child(instance)

	attach_block_signals(instance, x, y, z)

	var key := "%d,%d,%d" % [x, y, z]
	var rot: Vector3 = rotation_map.get(key, Vector3.ZERO)
	instance.rotation = rot

	# The collider is found by SEARCH, not as the first child: node order inside block scenes gets
	# changed without thinking, and a miss here would break the whole build's spawn (same rake as
	# vehicle_body_3d._first_collision).
	var src_col: CollisionShape3D = null
	for ch in instance.get_children():
		var cs := ch as CollisionShape3D
		if cs != null and cs.shape != null:
			src_col = cs
			break
	if src_col == null:
		push_error("blocks: у блока %s нет CollisionShape3D" % G.block_name(int(instance.get("block"))))
		return
	var collision: CollisionShape3D = src_col.duplicate()
	collision.position = Vector3(x - CENTER, y - CENTER, z - CENTER)
	collision.rotation = rot                     # коллизия наклоняется вместе с блоком
	# Offset applies to BOXES only: any other shape has no .size, and touching it would abort the
	# spawn halfway.
	var box: BoxShape3D = collision.shape as BoxShape3D
	if box != null:
		if box.size == Vector3(2,2,2):
			collision.position += Vector3(-0.5,0.5,-0.5)
		elif box.size == Vector3(2,1,1):
			collision.position += Vector3(-0.5,0.0,0.0)   # BLOCK2: центрируем 2-широкую коллизию
		elif box.size == Vector3(2,1,2):
			collision.position += Vector3(-0.5,0.0,-0.5)  # COAL_GEN: 2×1×2
	if !get_parent().is_node_ready():
		await get_parent().ready
	get_parent().add_child(collision)
	collision.add_to_group("block_collision")   # чтобы смена сборки могла их убрать
	node_map[key] = instance
	_apply_output(instance, key)

	instance.position = Vector3(
		(x - CENTER) * CELL_SIZE,
		(y - CENTER) * CELL_SIZE,
		(z - CENTER) * CELL_SIZE
	)

	# The matrix spawn effect plays only when a machine is built FROM SCRATCH (spawn_block is called
	# from _spawn_all only: first machine, load, build change). Manual placement no longer plays it.
	BlockFX.play(instance, false)

# Apply the saved product choice to a block. The field name differs between the two factories, so
# both are checked: they share no interface and adding one for a single number is not worth it.
func _apply_output(inst: Node, key: String) -> void:
	if charge_map.has(key) and inst != null and ("charge" in inst):
		inst.set("charge", float(charge_map[key]))     # аккумулятор родился с сохранённым зарядом
	if inst is FactoryBlock and port_map.has(key):
		(inst as FactoryBlock).ports = (port_map[key] as Dictionary).duplicate()
	if not output_map.has(key) or inst == null:
		return
	var v: int = int(output_map[key])
	if "output_comp" in inst:
		inst.set("output_comp", v)
	elif "output_block" in inst:
		inst.set("output_block", v)

## Cell offsets of a block from its anchor. One cell for a normal block, eight for a 2x2x2. Public:
## the port window (port_picker) draws sides from these, and recomputing the footprint on the UI
## side would mean a second copy of the block-size rule.
func footprint_offsets(inst: Node) -> Array:
	var key: String = cell_of_node(inst)
	if key == "":
		return []
	var parts: PackedStringArray = key.split(",")
	var ax := int(parts[0]); var ay := int(parts[1]); var az := int(parts[2])
	if not _in_bounds(ax, ay, az):
		return []
	var anchor := Vector3i(ax, ay, az)
	var out: Array = []
	for c in _block_footprint(int(map[ax][ay][az]), ax, ay, az):
		out.append((c as Vector3i) - anchor)
	return out

## The cell this node stands in ("x,y,z"), or "" if the node is not ours.
func cell_of_node(inst: Node) -> String:
	for k in node_map:
		if node_map[k] == inst:
			return String(k)
	return ""

## Set a factory block's port on the node now and in the map, so it survives the save.
## state: FactoryBlock.PORT_NONE / PORT_IN / PORT_OUT / PORT_BOTH.
func set_block_port(inst: Node, off: Vector3i, dir_idx: int, state: int) -> bool:
	if not (inst is FactoryBlock):
		return false
	var key: String = cell_of_node(inst)
	if key == "":
		return false
	var fb := inst as FactoryBlock
	fb.set_port(off, dir_idx, state)
	port_map[key] = fb.ports.duplicate()
	rebuild_factory_links()          # цепочка меняется прямо сейчас, а не при следующей правке
	return true

## Set WHAT a factory block produces, on the node now and in the map so it survives the save.
## Returns false if the node is not ours or is not a factory with a choice.
func set_factory_output(inst: Node, value: int) -> bool:
	var key: String = cell_of_node(inst)
	if key == "":
		return false
	if "output_comp" in inst:
		inst.set("output_comp", value)
	elif "output_block" in inst:
		inst.set("output_block", value)
	else:
		return false
	output_map[key] = value
	if inst.has_method("reload_recipe"):
		inst.reload_recipe()            # фабрика пересобирает рецепт под новый продукт
	return true

## Subscribe a block to its OWN destruction: the map must clear its cells, otherwise the dead
## block's spot stays "occupied" forever and nothing can be placed there (can_place reads the map).
##
## Called on BOTH paths a block appears by - build spawn and player placement
## (vehicle_body_3d._on_take_pressed). The subscription used to live inside spawn_block, so
## player-placed blocks never got it: burn one and its cell was occupied forever.
func attach_block_signals(instance: Node, x: int, y: int, z: int) -> void:
	if not instance.has_signal("destroyed"):
		return
	var cb: Callable = _on_block_destroyed.bind(x, y, z)
	if not instance.destroyed.is_connected(cb):
		instance.destroyed.connect(cb)

# ── Handler: block destroyed ────────────────────────────────────────────────
func _on_block_destroyed(_block_node: VehicleBlock, x: int, y: int, z: int) -> void:
	remove_block(x, y, z)
	if not _rebuild_queued:
		_rebuild_queued = true
		call_deferred("_deferred_rebuild")

var _rebuild_queued: bool = false

func _deferred_rebuild() -> void:
	_rebuild_queued = false
	_detach_orphans()
	rebuild_factory_links()                  # топология изменилась — пересчитать цепочку фабрики

# ── Structural integrity ────────────────────────────────────────────────────
# The root is the CABIN (mobile machine) or a STATIONARY block (base). Anything that cannot reach
# the root is detached, and one BFS catches a whole detached chunk at once.
#
# BY ATTACH POINTS, not by mere contact. The walk used to run over any neighbouring occupied cell
# with faces taking no part, which is why a gun with its support shot out KEPT FLOATING: it grazed
# some block sideways, the walk counted that as a connection, and the block was never called
# detached. By the attach rules there is no connection there: a gun marks its bottom only.
#
# The edge condition is the one building uses (can_attach): direction d must be among A's attach
# faces and -d among B's. There is no one-sided connection.
const BFS_DIRS := [Vector3i(1,0,0), Vector3i(-1,0,0), Vector3i(0,1,0),
		Vector3i(0,-1,0), Vector3i(0,0,1), Vector3i(0,0,-1)]

func _reachable_cells() -> Dictionary:
	var seen: Dictionary = {}
	var queue: Array = []
	for x in MAP_SIZE_X:
		for y in MAP_SIZE_Y:
			for z in MAP_SIZE_Z:
				var bt: int = map[x][y][z]
				if bt != G.Block.EMPTY and (bt == G.Block.CABIN or G.is_stationary(bt)):
					var k := "%d,%d,%d" % [x, y, z]
					if not seen.has(k):
						seen[k] = true
						queue.append(Vector3i(x, y, z))
	while not queue.is_empty():
		var c: Vector3i = queue.pop_back()
		var a: Node = find_block(c.x, c.y, c.z)
		for d in BFS_DIRS:
			var n: Vector3i = c + d
			if not _in_bounds(n.x, n.y, n.z):
				continue
			if map[n.x][n.y][n.z] == G.Block.EMPTY:
				continue
			var nk := "%d,%d,%d" % [n.x, n.y, n.z]
			if seen.has(nk):
				continue
			if not _cells_linked(a, find_block(n.x, n.y, n.z), c, n, d):
				continue
			seen[nk] = true
			queue.append(n)
	return seen

## Is there a REAL join between neighbouring CELLS ca and cb along d?
##
## Cells are asked, not blocks: on a block larger than one cell a side consists of several cells, and
## "joins with its left side" no longer means "with all left cells at once" (VehicleBlock.connects_at).
## For an ordinary block the cell is the side, so the answer is what it always was.
func _cells_linked(a: Node, b: Node, ca: Vector3i, cb: Vector3i, d: Vector3i) -> bool:
	if a == b:
		return true                        # две клетки одного многоклеточного блока
	if a == null or b == null:
		return true                        # узла нет (ещё не заспавнен) — не рвём связь на пустом месте
	if not (a is VehicleBlock) or not (b is VehicleBlock):
		return true
	return (a as VehicleBlock).connects_at(ca - _anchor_of(ca), d) \
			and (b as VehicleBlock).connects_at(cb - _anchor_of(cb), -d)

## The anchor cell that cell c belongs to. The offset from it is "which cell of the block this is" -
## the same key per-cell settings are described by.
func _anchor_of(c: Vector3i) -> Vector3i:
	var key := "%d,%d,%d" % [c.x, c.y, c.z]
	var anchor: String = cell_owner.get(key, key)
	var parts: PackedStringArray = anchor.split(",")
	if parts.size() < 3:
		return c
	return Vector3i(int(parts[0]), int(parts[1]), int(parts[2]))

func _detach_orphans() -> void:
	if node_map.is_empty():
		return
	var reachable := _reachable_cells()
	if reachable.is_empty():
		return   # корня нет (кабина/база уничтожена) — этим займётся смерть машины (MachineBody.scatter_blocks)
	var orphans: Array = []
	for anchor in node_map.keys():
		var parts: PackedStringArray = anchor.split(",")
		var ax := int(parts[0]); var ay := int(parts[1]); var az := int(parts[2])
		if not _in_bounds(ax, ay, az):
			continue
		var bt: int = map[ax][ay][az]
		if bt == G.Block.EMPTY:
			continue
		var grounded := false
		for c in _block_footprint(bt, ax, ay, az):
			if reachable.has("%d,%d,%d" % [c.x, c.y, c.z]):
				grounded = true
				break
		if not grounded:
			orphans.append(Vector3i(ax, ay, az))
	for o in orphans:
		_detach_one(o.x, o.y, o.z)

## Tear a SPECIFIC block node into the world. Called by the block itself when it is beaten near zero
## and its mounts do not hold (VehicleBlock._check_critical). The cell is found through node_map: a
## block does not know its own coordinates, and the map already keeps anchor -> node.
##
## The tear is deferred to end of frame: it comes from hurt(), and hurt is called from inside a
## physics traversal (an AOE blast queries bodies from space) - reparenting and removing colliders
## mid-traversal touch the physics server while it is busy.
func detach_node(node: Node) -> void:
	if node == null or not is_instance_valid(node):
		return
	for anchor in node_map.keys():
		if node_map[anchor] != node:
			continue
		var parts: PackedStringArray = String(anchor).split(",")
		if parts.size() < 3:
			return
		call_deferred("_detach_one", int(parts[0]), int(parts[1]), int(parts[2]))
		# Then a recount: half a machine could have been hanging on the torn block (call_deferred is a
		# queue, so the recount runs AFTER the tear).
		if not _rebuild_queued:
			_rebuild_queued = true
			call_deferred("_deferred_rebuild")
		return

# Tear a block into the world: drop the destruction signals (so a now-loose block's death does not
# touch the machine map), clear the map, and let the machine drop the node (collider, reparent,
# impulse).
func _detach_one(ax: int, ay: int, az: int) -> void:
	# NEVER drop the CABIN. It is the root the whole build hangs on, and a torn block loses its death
	# subscriptions (below) - together that meant a machine with no root and no death signal: the rest
	# fell off as detached while a live empty hull kept driving with nothing able to kill it.
	if _in_bounds(ax, ay, az) and map[ax][ay][az] == G.Block.CABIN:
		return
	var anchor := "%d,%d,%d" % [ax, ay, az]
	var node: Node = node_map.get(anchor, null)
	if node != null and is_instance_valid(node) and node.has_signal("destroyed"):
		for con in node.destroyed.get_connections():
			node.destroyed.disconnect(con["callable"])
	remove_block(ax, ay, az)                       # чистит карту, сам узел НЕ трогает
	if node == null or not is_instance_valid(node):
		return
	var veh := get_parent()
	if veh != null and veh.has_method("detach_block_to_world"):
		veh.detach_block_to_world(node)

# ══════════════════════════════════════════════════════════════════════════════
# SAVE / LOAD
# ══════════════════════════════════════════════════════════════════════════════

func save_layout() -> void:
	var blocks_array: Array = []
	for x in range(MAP_SIZE_X):
		for y in range(MAP_SIZE_Y):
			for z in range(MAP_SIZE_Z):
				var block: G.Block = map[x][y][z]
				if block != G.Block.EMPTY and _is_anchor(x, y, z):
					var key: String = "%d,%d,%d" % [x, y, z]
					blocks_array.append({
						"x": x,
						"y": y,
						"z": z,
						"block": G.block_key(block),
						"rot": _rot_array(rotation_map.get(key, Vector3.ZERO))
					})

	var json_string: String = JSON.stringify(blocks_array, "\t")
	var file: FileAccess = FileAccess.open(G.slot_path(SAVE_FILE), FileAccess.WRITE)
	file.store_string(json_string)
	file.close()
	print("Машина сохранена: ", G.slot_path(SAVE_FILE))

func load_layout() -> void:
	if not FileAccess.file_exists(G.slot_path(SAVE_FILE)):
		push_warning("Файл сохранения не найден: ", G.slot_path(SAVE_FILE))
		return

	for child in get_children():
		child.queue_free()
	node_map.clear()
	rotation_map.clear()
	cell_owner.clear()
	_init_map()

	var file: FileAccess = FileAccess.open(G.slot_path(SAVE_FILE), FileAccess.READ)
	var json: JSON = JSON.new()
	json.parse(file.get_as_text())
	file.close()

	var blocks_array = json.get_data()
	for entry in blocks_array:
		set_block(int(entry["x"]), int(entry["y"]), int(entry["z"]), G.block_from_key(entry["block"]), _read_rot(entry))

	_spawn_all()
	print("Машина загружена!")

func get_layout() -> Array:
	var blocks_array: Array = []
	for x in range(MAP_SIZE_X):
		for y in range(MAP_SIZE_Y):
			for z in range(MAP_SIZE_Z):
				var block: G.Block = map[x][y][z]
				if block != G.Block.EMPTY and _is_anchor(x, y, z):
					var key: String = "%d,%d,%d" % [x, y, z]
					var entry: Dictionary = {
						"x": x, "y": y, "z": z,
						"block": G.block_key(block),
						"rot": _rot_array(rotation_map.get(key, Vector3.ZERO))
					}
					# "out" is written ONLY for factories whose choice was changed: an extra field in each of fifty
					# cells would bloat the save for a default value.
					if output_map.has(key):
						entry["out"] = int(output_map[key])
					# Ports are written ONLY where the player changed them: the rest run on the default rule (face
					# masks), and storing emptiness is pointless.
					if port_map.has(key) and not (port_map[key] as Dictionary).is_empty():
						entry["ports"] = port_map[key]
					# Charge is asked FROM THE LIVE NODE: it is spent and gained every second while the map only holds
					# what the block was born with. An empty battery writes no field.
					var bnode: Node = node_map.get(key)
					if bnode != null and is_instance_valid(bnode) and ("charge" in bnode) \
							and float(bnode.get("charge")) > 0.01:
						entry["chg"] = float(bnode.get("charge"))
					blocks_array.append(entry)
	return blocks_array

func _rot_array(v: Vector3) -> Array:
	return [v.x, v.y, v.z]

# Reads rotation from a layout entry: the new format "rot":[x,y,z] or the old "rot_y":float.
func _read_rot(entry: Dictionary) -> Vector3:
	if entry.has("rot"):
		var r: Array = entry["rot"]
		return Vector3(float(r[0]), float(r[1]), float(r[2]))
	if entry.has("rot_y"):
		return Vector3(0.0, float(entry["rot_y"]), 0.0)
	return Vector3.ZERO

func apply_layout(blocks_array: Array) -> void:
	# Free block instances only (they live in node_map), NOT all children: among the children is the
	# build ghost (blocks/MeshInstance3D, the machine's ghost_block), and freeing it crashes
	# _on_building_pressed on a freed object.
	for inst in node_map.values():
		if is_instance_valid(inst):
			inst.queue_free()
	_clear_block_collisions()          # убираем коллизии блоков с кузова машины
	node_map.clear()
	rotation_map.clear()
	cell_owner.clear()
	_init_map()
	output_map.clear()
	port_map.clear()
	charge_map.clear()
	for entry in blocks_array:
		set_block(int(entry["x"]), int(entry["y"]), int(entry["z"]), G.block_from_key(entry["block"]), _read_rot(entry))
		# Product choices go into the map BEFORE _spawn_all: nodes read them at birth.
		if entry.has("out"):
			output_map["%d,%d,%d" % [int(entry["x"]), int(entry["y"]), int(entry["z"])]] = int(entry["out"])
		if entry.has("ports") and entry["ports"] is Dictionary:
			port_map["%d,%d,%d" % [int(entry["x"]), int(entry["y"]), int(entry["z"])]] = entry["ports"]
	_spawn_all()

# Removes block colliders (group block_collision) from the parent body on a build change, or the
# old machine's colliders keep hanging around.
func _clear_block_collisions() -> void:
	var parent := get_parent()
	if parent == null:
		return
	for c in parent.get_children():
		if c is CollisionShape3D and c.is_in_group("block_collision"):
			c.queue_free()

# ANCHOR offset when attaching a block to a neighbour's face. For MULTI-CELL blocks (processor,
# seller 2x2x2) a plain +-1 is not enough: the footprint grows one way, so on "positive" faces it
# would clip into the neighbour. The shift is computed from the real footprint bounds; for 1x1x1
# it gives +-1.
func attach_delta(block_type: int, face: String) -> Vector3i:
	var lo := Vector3i(0, 0, 0)
	var hi := Vector3i(0, 0, 0)
	for c in _block_footprint(block_type, 0, 0, 0):
		lo.x = mini(lo.x, c.x); lo.y = mini(lo.y, c.y); lo.z = mini(lo.z, c.z)
		hi.x = maxi(hi.x, c.x); hi.y = maxi(hi.y, c.y); hi.z = maxi(hi.z, c.z)
	match face:
		"right":  return Vector3i(-lo.x + 1, 0, 0)
		"left":   return Vector3i(-hi.x - 1, 0, 0)
		"top":    return Vector3i(0, -lo.y + 1, 0)
		"bottom": return Vector3i(0, -hi.y - 1, 0)
		"back":   return Vector3i(0, 0, -lo.z + 1)
		"front":  return Vector3i(0, 0, -hi.z - 1)
	return Vector3i.ZERO

# ══════════════════════════════════════════════════════════════════════════════
# FACTORY LINKS
# ══════════════════════════════════════════════════════════════════════════════
# Where a block hands resources is set by ITS OWN faces (FactoryBlock.output_faces / input_faces,
# edited in the block scene) with its rotation applied. A link A->B exists when A's output face
# looks at cell B AND B's input face looks back. Multi-cell blocks (2x2x2) give and take from any
# of their cells.
func rebuild_factory_links() -> void:
	var facs: Array = []
	var cells: Dictionary = {}                    # node → клетки его футпринта
	var anchors: Dictionary = {}                  # node → его якорная клетка
	for k in node_map.keys():
		var n = node_map[k]
		if n == null or not is_instance_valid(n) or not (n is FactoryBlock):
			continue
		var parts: PackedStringArray = k.split(",")
		var ax := int(parts[0]); var ay := int(parts[1]); var az := int(parts[2])
		if not _in_bounds(ax, ay, az):
			continue
		cells[n] = _block_footprint(int(map[ax][ay][az]), ax, ay, az)
		anchors[n] = Vector3i(ax, ay, az)     # смещения клеток считаем от якоря
		facs.append(n)
	# Links are computed PER CELL. The old code walked the block's marked FACES and took the FIRST
	# matching neighbour across the whole footprint (there was a break). For a single-cell block that
	# is the same thing, but on a 2x2x2 a side is four cells: two different belts could not be brought
	# to it - the second was silently ignored because the first had already "taken" the face.
	#
	# Now a "cell + direction" pair is considered on its own and both sides must agree: an OUTPUT in
	# our cell, an INPUT in the neighbour's cell facing back.
	for n in facs:
		n.next_blocks = []
		n.next_block = null
		var own: Array = cells[n]
		var anchor: Vector3i = anchors.get(n, Vector3i.ZERO)
		for c in own:
			var off: Vector3i = c - anchor
			for di in 6:
				var d: Vector3i = n.dir_of(di)
				if d == Vector3i.ZERO or not n.outputs_at(off, d):
					continue
				var t: Vector3i = c + d
				if not _in_bounds(t.x, t.y, t.z):
					continue
				var nb = find_block(t.x, t.y, t.z)
				if nb == null or nb == n or not cells.has(nb):
					continue                      # не фабричный сосед — ресурс туда не идёт
				# The NEIGHBOUR is asked about ITS cell: on a multi-cell block an input may exist in one cell of a
				# side and not in the next.
				if not nb.accepts_at(t - Vector3i(anchors.get(nb, t)), d):
					continue                      # у соседа в этой клетке нет входа навстречу
				if not n.next_blocks.has(nb):
					n.next_blocks.append(nb)
		if not n.next_blocks.is_empty():
			n.next_block = n.next_blocks[0]
