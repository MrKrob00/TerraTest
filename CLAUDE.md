# TerraTest — CLAUDE.md

Mobile game about machines built from blocks. Godot 4.6, GDScript. This file is the map of the
project: read it before claiming how anything works.

## 0. Critical rules

1. The game RUNS here, headless — see §3 "Running it". You do not get a picture, but you get the
   real engine: the import, every script compiled with the autoloads up, every scene instantiated,
   and the world booted for as many frames as you like. `gdparse` stays the two-second check; the
   engine is the one that actually knows.
2. `gdparse` does not see a **redeclared variable** or a **call to a method the node lacks**. Both
   are Parse Errors in Godot, and a Parse Error means the whole script does not load. The headless
   self-test does see them — run it before claiming a change is safe.
3. **No comments in `project.godot`** — Godot rewrites the file and folds `#` into a key name,
   silently killing the setting.
4. `node.get("field")` returns `null` when there is no such field, and `bool(null)` crashes. Write
   `v.get("field") == true`. Same family: `get_meta(name, null)` still errors when the meta is
   missing - the engine reads a null default as "no default given", so ask `has_meta` first.
   And **NEVER guard a freed reference with `!= null`** — ask `is_instance_valid` and nothing else.
   Measured on the engine: for a freed object `obj == null` is **true** and `obj != null` is
   **false**, yet it is not nil, it is an object reference to a dead address. So
   `if n != null and not is_instance_valid(n)` never runs its body, and the next line returns the
   very thing the check was written to stop: "Trying to return a previously freed instance".
   `is_instance_valid(null)` is false too, so the one call covers both cases.
5. A field named like a native class member ("Member X redefined") stops the script from loading.
   Signals count as members.
6. A single-line lambda ends at the newline; a wrapped continuation becomes an extra call argument
   with valid syntax. Use a named method instead.
7. A mechanic that lives only in `vehicle_body_3d` **does not exist for the enemy**, usually
   silently, because it is called through `has_method()`. Adding something there, ask whether
   `enemy_vehicle` needs it too.
8. A block placed on a machine at runtime needs **both** subscriptions: `attach_block_signals` and
   `connect_block_signals`. One of them missing leaves an occupied cell or a dangling collider.
9. Every gate goes at the **single door**: invulnerability in `VehicleBlock.hurt`, infinite energy
   in `MachineBody.energy_consume`, damage multiplier in `WeaponBlock._scale_damage`, aim-ray
   hiding in `WeaponBlock._ready`. Per-scene copies are how new sources slip past.
10. Debug flags are read only through `G.debug(&"flag", default)`; "no `Main` node" must never mean
    "off". Master switch `debug_overrides` is off by default.
11. **No particles and no emoji anywhere.** Effects are `BlockFX` glitch cards; icons are `_draw()`.
    The font renders emoji as empty boxes. A `BlockFX` node marks itself `block_fx` so
    `_local_aabb` skips it — without that every hit measured the previous hit's plates and the
    effect grew with each one.
12. Never set position or size on a **container child** — the container overwrites it. Only nodes
    directly under a `CanvasLayer` are positioned from code.
13. Compare distances with `distance_squared_to()`; the square root is only for formulas.
14. Terrain height is asked through `G.ground_y(point, fallback)` — raw `terrain_height_at` returns
    zero before the terrain is up. `reset_heights` FORGETS THE TERRAIN EDITS and nothing else: the
    ground comes from the seed, so there is no world to reset, and `world_persist._fresh_start`
    calls it on the first line of every new save.
15. Saves store blocks by **enum name**: renaming needs `LEGACY_BLOCK_KEYS`, removal needs the enum
    value kept plus an entry in `RETIRED_BLOCKS`. SAME SIZE IS A PREFERENCE, NOT A LAW: a save is
    restored through `apply_layout` → `set_block`, which clears `cell_owner` and recomputes the
    footprint from the block type, so mapping a 2×1×2 onto a one-cell block leaves clean empty
    cells rather than phantom occupied ones. That is how COAL_GEN was retired onto GENERATOR.
    TWO BLOCKS THAT RUN THE SAME SCRIPT ARE ONE BLOCK. The coal generator and the generator sat on
    the same `generator.gd` with the same burn time and the same per-fuel numbers, so the big one
    was four cells and 35 kg for exactly the output of one cell — not a choice, a mistake waiting
    to be made.
16. Biome masks are computed in exactly one place, `TerrainBiomes` — the value noise under them
    too (`TerrainBiomes.cv_noise`, handed to the masks as `biomes.noise`). A second copy of the
    formula diverged once and moved a whole region. THAT NOISE IS NATIVE (`FastNoiseLite`,
    `TYPE_VALUE`): it used to be eight lines of GDScript hashing, and those eight lines WERE the
    world's loading time — 17.3 us a call against 1.6 native, and three of them per mask, five
    times over for the blur. The shader is not affected either way: masks reach it baked into
    vertex colour, it never recomputes them. Swapping the noise changes the LAYOUT every seed
    draws, and it changes the DISTRIBUTION too — the old hash was flat over 0..1, value noise is
    centred, so the same threshold covers less ground. `canyon_threshold` and `mountain_threshold`
    were re-measured against it (0.70→0.66, 0.72→0.71) to keep the composition where it was. PATCH SIZE IS SET BY `scale` AND NOTHING ELSE:
    one octave plus a threshold has no size floor, so slivers of two or three chunks always appear
    near the threshold. Raising `scale` is the only lever that does not change the world — lowering
    the threshold removes slivers too but doubles how much of the map that biome covers. Blurring
    the mask noise does not work: it moves the isoline, it does not remove slivers (measured).
17. A loose item is put to sleep with `sleeping`, never `freeze`: `G.is_loose_item` checks `freeze`,
    and a frozen item stops being pickable.
18. There are NO HEIGHT FILES. The ground is the seed and nothing else, so there is nothing to bake,
    nothing to ship and nothing to go stale against a save.

## 1. Project skeleton

- Autoloads: `G` (progress, prices, block metadata), `Dialogue`, `Music`, `Q` (quests), `MobileAds`.
- Main scene is `menu.tscn`: the slot is chosen before map, machines and veins read any file.
- World root `/root/Main`: `map` (ChunkTerrain + veins + props), `Vehicles`, `objects` (loose blocks
  and resources), `EnemySpawner`.
- Blocks: scenes in `blocks/scenes/`, scripts in `blocks/scripts/`. Everything else sits at the
  repo root.
- Base classes: `MachineBody` → `vehicle_body_3d` (player) and `enemy_vehicle` (AI);
  `VehicleBlock` → `WeaponBlock`, `FactoryBlock`.

## 2. Architecture invariants

### Machines and the block grid

- `blocks.gd` holds an 11³ grid per machine; coordinates are shifted by +5, so the centre is
  (5,5,5). Multi-cell blocks keep node and rotation on one anchor cell (`cell_owner`); always go
  through `find_block` / `remove_block`.
- **A MULTI-CELL BLOCK'S FOOTPRINT ROTATES WITH IT, AND SO DOES ITS COLLIDER OFFSET.** Both the
  mesh and the collider turn about the ANCHOR, which for a big block is a corner rather than the
  middle; `_block_footprint` computed cells with no regard for the angle at all, so a block turned
  90° lay across cells the grid had reserved somewhere else. Measured on the engine: the wedge and
  the smelter got the identical cell set at 0°, 90°, 180° and 270°. The offsets now live in
  `_footprint_offsets` in the block's OWN axes and are turned by the yaw at every door — placing,
  removing, connectivity, factory links and `attach_delta`, which the builder must call with the
  angle it is about to place at.
- WHERE THE COLLIDER SITS IS `blocks.collider_offset`, one door for both ways a block is placed.
  Manual placement carried its own copy that knew exactly one size (2×2×2) and never turned it, so
  everything else went in half a cell out. The box's SIZE is the test for "does the collider span
  the whole footprint" — armour is a thin 1×1×0.2 plate standing on its own face and wants no
  centring.
- **THE COLLIDER'S POSITION IN A BLOCK SCENE IS A DRAWING FOR THE ARTIST, AND IT MUST BE DRAWN
  WHERE THE GAME PUTS IT.** `spawn_block` OVERWRITES that local position — only the SHAPE comes
  from the scene — and then applies `collider_offset`. So the collider a scene shows and the
  collider the game builds can be half a cell apart, and the editor says nothing about it. The rule
  a model is authored by is "the mesh lies exactly inside the block's collider", so a collider
  drawn in the wrong place sends the artist to align against a lie: the wedge's mesh was moved to
  sit in a collider centred on the anchor, while in game that collider stands half a cell back, on
  the cells. Most scenes already agree (smelter, seller, block2 carry the offset in the scene); the
  wedge and the fabricator had theirs at the origin and are now fixed. Measured after: in the
  editor mesh and collider both span z −1.50…0.50, and in game mesh, collider and cells all span
  the same two cells.
- A COLLIDER IS FOUND BY ITS `block_owner` TAG, not by comparing positions. The positional
  fallback only ever knew the 2×2×2 offset, and with several offsets that also turn it cannot be
  right; manual placement tagged its collider, the machine's own assembly did not, so the fallback
  was the live path for every starter and enemy block.
- THREE ANSWERS ABOUT ONE SHAPE IS TWO TOO MANY. The wedge's `BoxShape3D` was 1×1×2 (long on Z),
  its `cells_center` described a 2×1×2, and `_block_footprint` filed it with the 2×1×1 blocks
  along X. Its mesh settles it: x spans exactly one cell, z spans two. It is now 1×1×2 on Z
  everywhere, its model centred on those two cells (it sat 0.375 forward of them), and its
  per-cell attach faces moved to the cells that now exist.
- Where a block may attach is the `connect_faces` mask on `VehicleBlock`, edited on the cube widget
  (`port_cube.gd`) and nowhere else. Building rotates the block so that face meets the neighbour.
- Connectivity is by **attach faces**, not by touching: an edge exists only when both sides mark the
  direction (`_reachable_cells`). Blocks larger than a cell expand a side into cells
  (`connects_at` / `connect_defaults`).
- Factory ports are **per cell** (`FactoryBlock.ports`, key = cell offset + direction in grid axes);
  an empty key falls back to the mask. Stored in `blocks.port_map` so it survives saving. In game
  the picker only shows sides — they are authored in the block scene.
- What a factory produces lives in `blocks.output_map`, not on the node: the layout stores cells, so
  an instance field would reset on load.

### Driving and wheels

- The machine is a plain `RigidBody3D`, NOT `VehicleBody3D`. Wheels are not physics constraints and
  nothing rolls: a wheel probes the ground with a ray (`Wheel.probe_ground`), the suspension is
  `apply_force` at the wheel offset, and traction, lateral grip and braking are `apply_central_force`
  through the centre of mass. Jolt only carries the body; the car is written by hand.
- There is no engine block. Traction is the sum of `wheel_power` over driving wheels **that touch
  the ground**, times `engine_force`. A bare cabin with no blocks at all gets `chassis_power` so the
  first minutes work.
- WHEEL CHOICE IS DECIDED BY `load_capacity`, and everything else follows from it. The spring
  constant is derived from the wheel's RATING, not from the load actually on it, and the spring
  force is capped at that rating: below it the machine rides on suspension with its hull clear of
  the ground, above it the excess presses on the hull colliders, which rub, and the build buries
  itself. Overload is punished by friction — there is no penalty multiplier, and adding one would
  be a second implementation of the same rule.
- Never compensate for that friction in `_apply_engine`. A `sqrt(friction) * mass * g` term used to
  be added there; mass cancels out of force/mass, so it was a flat +14.5 m/s² handed to every build,
  weight decided nothing, and the garage's load verdict could not come true at any mass.
- THE TYRE TURNS AT THE SPEED THE MACHINE ACTUALLY MOVES, not at the throttle (`Wheel._roll_tyre`).
  The angle used to accumulate as `throttle_input * SPIN_SPEED`, so the picture showed the PEDAL
  and disagreed with the machine in both directions at once: a light build on strong wheels shot
  off from a short tap while the tyres barely turned, and a machine jammed against a rock spun
  nothing at full throttle, which is the one place a spinning wheel would have been right.
  Rolling is ω = v / r, with v taken AT THE WHEEL'S OWN POINT (`linear_velocity +
  angular_velocity × arm`) rather than at the centre of mass — through a turn the outer wheel
  covers noticeably more ground than the inner one, and one shared vector would turn every corner
  into four identically spinning wheels. Off the ground there is nothing to roll on and the
  throttle takes over. The radius is asked of the MESH (`_measure_radius`), never derived from
  `ride_height`: that number is the radius PLUS the arm's drop, and the arm's share differs across
  the three sizes. `SPIN_MAX` is a picture limit, not physics — past roughly half the frame rate a
  tyre reads as turning backwards, and a phone's frame rate puts that threshold low.
- `ride_height` is the wheel's radius PLUS the drop of the suspension arm, and the arm is the same
  model on all three wheels — so the value scales with the tyre and nothing else. The tyres measure
  0.6 : 1.0 : 1.3 (small : standard : big); `suspension_travel` follows the same ratio.
- The garage panel must read the same numbers the physics reads: LOAD is mass against
  `load_capacity()`, ACCEL is `rated_power()/mass`. Both skip wheels whose geometry is not authored
  yet (`Wheel.geometry_ready()`, i.e. `ride_height` still 0) so an unfinished block cannot promise
  newtons or kilograms.
- THE TOP AND STABILISER WHEELS ARE ORDINARY WHEELS, differing only in which face they mount on —
  they drive and they carry. The top one is TerraTech's Riser Wheel: a wheel on an EXTENSION STRUT
  that bolts on by its TOP face and hangs below whatever it is attached to, so it adds a support
  point and lifts the machine clear instead of letting it bottom out. In our terms that is
  `load_capacity` plus a `ride_height` LARGER than the standard wheel's, and `connect_faces` of
  `FACE_TOP` (16) rather than `FACE_BACK` — neither is set yet. The stabiliser mounts on the REAR
  (or front) face and looks FORWARD rather than sideways: the third support under a nose- or
  tail-heavy build, where a block used to be propped in and then dragged along the ground. Both
  models are still to come, so their geometry, mounting face and transmission are deliberately left
  as placeholders on the standard wheel's numbers.

### Building

- BUILD MODE HOVERS OVER THE HIGHEST GROUND UNDER THE MACHINE, sampled at the corners and centre of
  its cell footprint — not under the origin, which is the cabin. Against a mountain those are
  different numbers: low under the cabin, a slope under the tail, and the machine caught on the hill
  instead of rising over it.
- Building draws from the INVENTORY PLUS whatever lies within `G.BUILD_REACH` (20 m) of the machine
  — one door, `G.block_available` / `G.consume_block`, used by the garage, the block globe and the
  serial-build refill. Asking in one place and deducting in another is how a build starts taking
  blocks out of thin air.

### Production chain

- Three roles, not three inputs. **Collector** picks resources off the ground, always. **Receiver**
  is the chain entry: ground materials and collector ore onto the belt, only while anchored.
  **Packer** magnetises loose blocks (Area3D point gravity) and packs them into chunks.
- A machine stands **beside** the belt, not in a gap in it. Belts never hand sideways to another
  belt, and a non-belt receives before the next belt does (`push_item` round-robins for the
  splitter).
- A machine beside the line also gets PRIORITY FOR THE FREED CELL (`belt.side_waiting`): it returns
  its result onto the belt one cell along and loses that cell to through traffic every time, and
  while it holds its output it takes no input — a few boxes later the line is dead.
- "Waiting for the next block" is trusted only while the one-shot `slot_freed` subscription is
  alive (`FactoryBlock._wait_on`), or a destroyed neighbour means waiting forever.
- Area masks decide as much as scripts: collector layer 8, receiver 24, packer magnet 2.
- Every recipe has exactly two different materials — the fabricator tells inputs apart by kind.
- COAL IS NOT MINED, IT IS MADE. What grows out of the ground is WOOD; the processor burns it into
  coal, and that is coal's only source (`resource.upgrade`, the one door the processor calls).
  Wood is half of coal in both numbers that matter — 6 against 12 to sell, 20 against 40 in the
  generator — so the choice is "throw it in the furnace now" against "burn it down and get twice
  as much", which is what makes the conversion a decision rather than a step.
- WOOD IS THE ONE THING THAT GROWS AT RANDOM. Ore is handed out BY REGION (`_metal_for`), so the
  metal under your wheels depends on where you stand; wood is a per-point roll, so a forest is
  never a deposit — you meet it on the way. And a felled tree does NOT grow back on its stump: it
  MOVES, up to `REPLANT_RADIUS` (8 m), which keeps the region's tree count while emptying the spot
  you just cleared. The radius is small on purpose — with a free-for-all relocation the forest
  would migrate to wherever the player chops most. The target circle is checked against other
  nodes and against machines, or a tree eventually grows inside a base.
- A REPLANT IS A MOVE, NOT A PLACEMENT, so `_free_spot_near` does not ask `min_height`. That
  threshold keeps the SEEDED layout out of the deepest basins; a tree that already stands passed it
  once, and inside an eight-metre circle the height cannot run further than `max_slope` allows.
  Asking it again forbids the move wherever the whole ground lies below the threshold — the proving
  ground exactly (h = 0.0 against `min_height` 2.0), where all sixteen tries were rejected in
  silence and the felled tree simply refilled on its stump. Measured there before the fix: fourteen
  seconds after felling, records and nodes 7 → 7, nothing moved.
- A REPLANT IS FORGOTTEN ON RELOAD, SO THE OCCUPANCY CHECK ALSO SITS AT STREAM-IN. `_data` is
  rebuilt from the seed every load: the tree the player felled last session comes back to its
  seeded point, which may now be under the base they built there. Waiting for `replant` does not
  help — that runs off the rest timer, and a freshly loaded full tree never rests. So `_stream_in`
  nudges a tree off a machine before the MultiMesh slot is taken, and shows nothing at all when
  the whole circle is occupied. It asks about MACHINES ONLY (`_machine_near`, a handful of nodes);
  the pass over all of `_data` (`_node_near`) stays on the replant path, because streaming runs
  the whole time the player is driving.
- **WOOD HAS NO AUTOMATION, AND THAT IS THE POINT — there is no harvester block and none is
  planned.** Ore is the standing economy: find a vein, park a base, come back for the cargo. Wood
  is the driving economy, and the RANDOM RELOCATION is what keeps it that way: a felled tree does
  not come back to its stump, it reappears somewhere inside `REPLANT_RADIUS`, so there is no fixed
  point for a machine to sit on. That is not a gap waiting for a radius-harvester — it is the
  mechanic that ANSWERS why the auto-miner refuses a tree. Build a block that harvests an area and
  the two economies collapse into one, and the only reason to ever drive anywhere for wood
  disappears with it.

### Block death and the anchor

- Thresholds are on `VehicleBlock`, checked in `hurt()`: below `DROP_FRAC` a hit can tear the block
  into the world (`DROP_CHANCE`), below `FUSE_FRAC` it burns a fuse and detonates. The tear is
  deferred to end of frame — `hurt` runs inside a physics traversal.
- Three things explode: battery, cabin (takes the machine with it) and any burnt-out fuse. Damage
  hits blocks, impulse only loose bodies.
- A BATTERY'S BLAST FOLLOWS ITS CHARGE: full it takes 70% of an ordinary block's HP three cells
  out, empty 20% one cell out, linear between. The damage is stored as a SHARE of `BLOCK_HP[BLOCK]`
  because that table is tuned in seconds-under-fire and moves.
- A machine carrying meta `volatile_batteries` never drops a battery — it detonates instead,
  whether shot off, burnt down or shaken loose when the build came apart. That is what the shielded
  tower and its charging towers are marked with; killing the tower blows the guards' cells too
  (`quest_arcs._blow_tower_guards`, found by meta `tower_guard`, never by a list).
- Block tinting goes through a separate shell: model materials are shared between instances.
- DAMAGE IS SHOWN AS CELLS, NOT AS A LEVEL (`block_hp.gdshader`): a cell is broken or not, decided
  by its own hash against the damage share, so a new hit ADDS glyphs to the ones already lit and
  never reshuffles them; only the symbol flips 0↔1. A repair greens the cells that stopped being
  broken and they fade over `HEAL_FADE` — there is no separate heal effect, it would draw the same
  thing twice and say nothing about WHAT was repaired.
- The anchor spot is **not** validated — the only condition is a support block. Terrain checks were
  removed because they refused on ground the machine stood on fine.
- The anchor is held by a block: lose the support (and any stationary block) and the machine drops
  off the anchor itself.
- Support column and `ROT_SUPPORT` rotation pivot are taken from the support block
  (`vehicle_body_3d.support_block`), not from the machine origin, which is the cabin.
- The core watchdog (`MachineBody.cabin_watch`) runs for enemies too: it asks whether anything still
  holds the machine together instead of waiting for a `destroyed` signal.

### Weapons

- Turrets aim themselves: own detection sphere synced to `weapon_range`, nearest target, lead with
  drop compensation. Player taps play no part.
- The target is a **block** (layer mask 2). A block on a machine has zero `linear_velocity`, so
  target speed is measured between physics ticks.
- Target scoring weighs proximity above the cabin (`SC_CABIN`) and adds a per-gun constant taste
  (`SC_TASTE`) so neighbouring guns do not converge on one block.
- Spread is angular and grows with distance; shotgun and mortar disable the base spread and use
  their own. Without spread, automatic aiming is an aimbot.
- The turret sector is per weapon (`WeaponBlock.yaw_limit` / `pitch_limit`, **variables**, not
  constants): a subclass narrows it in `_ready`, and `_is_in_cone` then gates acquisition and firing
  with no second check anywhere. Default 75°×40°.
- The MORTAR is the one weapon aimed by the HULL: `yaw_limit` 18°, so it only trims. It throws along
  an arc whose angle follows distance (60° near → 30° far) and picks the speed from
  `v = √(g·d / sin 2θ)`, which is also where the 20 m minimum range comes from — closer is not a
  ban in code but a fact of the ballistics. Its spread is in METRES ON THE GROUND, not degrees, and
  that number decides how much of a salvo lands: a wide pattern turns nominal damage into a tenth of
  it.
- Damage always goes through `_scale_damage`, subclass numbers included.
- BLOCK HP IS MEASURED IN SECONDS UNDER FIRE, against the DPS the code actually produces (gun 25/s,
  laser 32, shotgun 20 sustained, heavy cannon 25, rocket 28, mortar 23-30 — 8 shells × 12 with
  three or four landing, every 1.6 s — drill 66 at contact; enemy builds run 20-75, siege ~80). The
  mortar is the one to recheck after touching its spread: the number that matters is how much of a
  salvo lands, not what the salvo is worth. The rule the table is tuned to: a cabin survives
  six seconds of focused fire from its own tier, an ordinary block three. A weapon without its own
  row falls to `DEFAULT_HP` and becomes the most fragile thing on the machine — which is what the
  enemy aims at.
- A BULLET IS SWEPT ALONG ITS SEGMENT (`bullet._sweep`), not left to Area3D overlap: at 120 u/s it
  moves two metres per physics frame (four at 30 fps) and a block is one metre, so shots stepped
  over blocks entirely — armour stopped nothing and hits landed on whatever was at the end of the
  step. One bullet lands one hit; a spent bullet is inert and the handler checks that.
- A PROJECTILE FACES ITS VELOCITY EVERY FRAME (`bullet._face`), not only at the muzzle. The
  launch `look_at` is close enough for a flat shot and wrong for an ARC: the mortar throws at 60°,
  the shell passes its apex and comes down while the model still points at the sky, so the last
  half of the flight is tail first. The direction comes from the STEP, not from `dir` — `dir` is
  the horizontal part and gravity adds the rest inside `_tick_bullet`. Measured across a full
  lob: nose against flight, 0.03°.
- THE SHARED BULLET MODEL IS FOR ORDINARY SHOTS, and a weapon that builds its own projectile marks
  it `WeaponBlock.OWN_VISUAL`. `_apply_bullet_mesh` walks every `MeshInstance3D` under the bullet
  and replaces its mesh, and the laser calls it (through `_rebind_bullet`) right after assembling
  its own long thin capsule — so the laser fired the machine gun's round, literally the same mesh,
  and fired it SIDEWAYS, because the capsule is turned −90° about X for its own geometry. "The
  laser shoots bullets" was not a figure of speech.
- `bullet._stretch` SCALES THE AXIS THE MESH ACTUALLY POINTS ALONG, asked once from the mesh's own
  rotation. Hardcoded "stretch along Z" scaled the RADIUS of any projectile whose model is turned
  inside the bullet: the laser bolt did not lengthen, it swelled, and the worse the frame rate the
  fatter it got.
- THE LASER IS A CHARGED SHOT, and what it charges is visible: three rings running in to the
  muzzle, brightening as the shot nears (`laser._drive_charge`), then a LANCE along the barrel
  instead of a muzzle cone (`BlockFX.muzzle_lance`) — a cone is burning gas, and a laser has none.
  Rate 0.9 s at 29 damage keeps the 32 dps the HP table is tuned to; the difference is that it
  arrives in one blow with a wind-up the player can read and step behind cover for. Which effect a
  shot draws is `WeaponBlock._muzzle_fx`, overridden like `flash_color` — the door stays single
  (`_handle_fire` calls it once per shot, shotgun and mortar included).
- A weapon that bends its shot after firing (shotgun spread, mortar arc) uses
  `WeaponBlock.last_fired`. "The last child of Ammo that is in flight" is only correct while the
  pool is empty; afterwards bullets come out of it in any order.
- `_alert_victim` (weapon side) tells the victim who shot; `hurt()` must not, since drills and
  repair fields call the same `hurt`.

### Energy

- Charge lives in the batteries themselves (`battery.gd`); the machine only sums and draws. It
  travels with the block and survives saving (`blocks.charge_map`). Only the solar buffer belongs to
  the machine and exists while anchored.
- **WHAT A BLOCK HOLDS IS SAVED IN THREE PLACES, AND ALL THREE HAVE TO BE WIRED.** The state lives
  on the NODE, the save stores CELLS, so a map in `blocks.gd` carries it across: `get_layout` asks
  the live node and writes a field, `apply_layout` reads that field back INTO THE MAP, and
  `_apply_output` hands it to the node at birth. Miss the middle step and the whole thing is dead
  code that looks finished — which is exactly what battery charge was: `get_layout` wrote `"chg"`
  into every save, `apply_layout` cleared `charge_map` and never filled it, `_apply_output` read a
  map nobody wrote, and every battery came back empty. Storage cargo (`store_map`, the block's
  `store_state` / `restore_store`) runs the same three steps. An empty holder writes no field.
- Enemy energy is real: tower panels, battery and shield all work, which is the way into a shielded
  tower. Every enemy ticks it, driving machines included — they carry domes and repair fields too.

### Enemies

- `enemy_spawner.gd`: HOW MANY ARE AWAKE IS DECIDED BY DISTANCE, NOT BY A COUNTER. The awake cap
  used to be one or two, and it doubled as the population cap: while two lived nearby the world
  sent nobody, however much room there was. Now everything inside `sleep_dist` (100 m) is awake
  and everything past it sleeps, so the only ceiling left is `max_total` — and it is a real one,
  because wheels, AI and weapon ticks run for every machine that is not asleep. The boundary has
  HYSTERESIS (`wake_frac`, wake at 85 m): at four hundred metres nobody lingered on the line, at a
  hundred that line runs straight through the fight. `sleep_delay` doubles as the newcomer's
  grace: the spawn ring reaches `spawn_max_dist` (160 m), so a machine is born outside the awake
  radius and has those seconds to drive in. `max_engaging` is a SEPARATE cap and still 1 — it
  decides who opens a fight, not who is loaded, so lifting the awake cap does not by itself put
  more guns on you. Everyone drops in from `drop_height`; the inner ring radius is computed from
  enemy vision plus `spawn_safe_margin`, never hardcoded.
- THE WORLD RAMPS UP WITH THE PLAYER, from one number: `G.threat_ramp()` (0 at grade 1, 1 at
  `THREAT_FULL_GRADE` = 4). It scales how many enemies stay awake, how often the next one comes
  (`_awake_cap` / `_spawn_wait`), the tier ceiling on top of the value one (`_enemy_tier`), the
  event cooldown (`quest_arcs.EV_COOLDOWN_EARLY_MUL`) and how many events the journal holds
  (`Q.event_slots`). Grade, not hours in the save: hours can be spent parked in the garage.
- Event quests are staggered by `req_grade` (1,1,2,2,3,4) in the same order as their rewards, and
  `current_events` honours it. All six being open from minute one is what "it spawns everyone at
  once" was: a staging point with four machines could land on a player with one gun.
- Time → difficulty → reward, in that order. The last two links were already there (the enemy build
  follows the player's machine value, the payout is measured from that build, and event rewards are
  a ladder from 200 to 420); the first was missing.
- On equal sector load the spawn picks the **rear**: the "not in front" ban only covers the moment
  of appearing, and one turn of the wheel later a side spawn is in the way.
- Beyond `sleep_dist` an enemy sleeps: physics frozen, `process_mode` off, meta flag `asleep` (read
  by LiteTerrain too, to skip its collision window).
- The first enemy of a save deals halved damage (`FIRST_ENEMY_DAMAGE`); the story scout gets that
  discount unconditionally and drops along the player's heading — the one deliberate inversion of
  "never spawn in front".
- The build is picked against the player's machine value (`_pick_preset`); value sets a ceiling and
  the tier is rolled under it. Kill reward is measured once at birth.
- THE LADDER IS TWO TABLES AND NOTHING ELSE: `enemy_spawner.PRESET_TIERS` (a step per line) and
  `blocks.ENEMY_BUILDS` (what each build is — rows, wheel, width, deck, top, crown, wings). A new
  machine is A TABLE ROW AND NOTHING ELSE: `_define_layout` now asks `ENEMY_BUILDS.has()` instead
  of carrying a list of preset numbers, so a forgotten number can no longer send the player's own
  starter machine out as an enemy. TWELVE PER STEP, not three: one machine per step is one
  silhouette and one memorised answer, and three wore out inside a grade. The variant is rolled on
  every spawn, so the value is not in any single build but in the next one being different.
- A BUILD ROW IS CHECKED BY MACHINE, NOT BY EYE. Seventy-two rows cannot be read, and every error
  here is silent: a floating block just drops into the world, a barrel behind a dome just never
  sees anything, an overloaded build just digs itself in. The harness assembles every preset and
  asks four things — empty line ahead of each barrel, nothing standing on a barrel, a battery
  roofed and flanked, no cell without a neighbour — plus mass against `load_capacity()` and the
  value curve across steps. Measured after the table was written: 0 geometry complaints, nothing
  overloaded (worst 0.55 of capacity), medians 10.7k → 15.9k → 24.5k → 31.6k → 44.2k → 65.2k.
- WIDTH IS ODD AND THE GRID'S CEILING IS NINE, not five. Wheels sit at half+1 from the axis, so a
  nine-cell hull puts them on x = 0 and x = 10 — the last cells of the 11³ grid — and eleven
  carries them off it, where `set_block` drops them without a word. Measured on the engine for
  build 84: width 9 gives an 11×4×7 bounding box, 136 cells and 12 wheels with no warning;
  width 11 gives 150 cells and ZERO wheels. The tables (`ENEMY_BUILDS`) still ask for 1, 3 or 5,
  so the widest machine in the game today is 7 across where 11 would fit; that is a design
  choice about silhouettes, and the comment that used to call it a grid limit was wrong (its own
  arithmetic, "5+3+1 = 9 against a limit of 10", disproves it). The fourth floor (`crown`) stands
  only on a `BLOCK` in `top` — a barrel carries nothing (`connect_faces` = 32, bottom only), and
  guessing at a dome's faces is guessing.
- Anything that wants an enemy asks the spawner, which owns the ladder: `_pick_preset` for the
  stream, `preset_for_request` for quest events, `preset_for_value` for raids (they measure the
  BASE, not the machine the player is driving). `raids.gd` reading the tier table itself is how the
  two copies drifted apart last time.
- WHAT GOES WHERE ON A BUILD IS A RULE: value decides depth — cabin, then battery, then shield and
  repair field, then guns. The battery sits in the MIDDLE OF THE DECK, enclosed on six sides (hull
  under, dome or turret over, flank plates both sides, blocks fore and aft); guns go outside, where
  they need the arc and where the player is meant to strip them. Power hung on the tail reads as a
  feature ("drive round the back and de-power it") and is really one cheap move that deletes the
  shield mechanic entirely.
- A BARREL NEEDS AN EMPTY LINE AHEAD OF IT at its own level, so a build gets guns in exactly three
  places: the FRONT of the deck, the FRONT of the top column, and the shoulders (`wings`, x 4 and
  x 6). Everything else on the top column is dome and repair field. A gun parked behind them still
  fires — the sweep lets a bullet past its own blocks — it simply never sees anything, which reads
  as a broken turret rather than as a mistake.
- PLATES GO WHERE THEY PROTECT SOMETHING: one on the nose and a pair opposite each battery
  (`_armor_rows`). Lining every middle cell gave seven to nine plates, most of the machine's weight,
  and the silhouette read as a wall rather than a vehicle.
- A wide build is three cells wide ON BOTH FLOORS. Widening only the floor leaves a spine standing
  on a pallet, which is what "they still look small" meant.
- THE CEILING IS ONE FUNCTION, `_tier_cap`, and everything that asks for a DRIVING enemy goes
  through it. On the quest side that means `quest_arcs._spawn_hostile` — the single door in front of
  `spawn_at` — and every branch uses it: events, the story-block carrier, the salvage guard, the
  wave on your base and the crossfire duel. Naming a preset by number is exactly how it went wrong:
  the duel was hardcoded to 7 and 8, and a lancer is the first build with a dome, so the first hour
  of a save put one in front of a starter cabin. The cap only ever lowers; an ALLY (faction 0) is
  never capped, since a weak ally helps with nothing; and a preset outside the ladder — towers,
  bases, anything spawned `as_base` — is left alone, because there the build is the task.
- Builds must agree with `connect_faces` — nothing attaches to a wheel or a gun. Layouts do not
  check this; the error shows up in game as a floating block.
- FROM THE LANCER ON, ENEMIES CARRY POWER: battery + shield, battery + repair field, or both. So a
  driving enemy TICKS ENERGY (`_energy_tick` in `_physics_ai`, not only `_base_tick`) and spawns
  with its batteries full (`_charge_batteries`, retried for a few seconds because blocks appear
  later than the first tick). Panels stand only on bases, so that charge is all it gets: the dome
  and the repairs are a resource the player drains, not a wall.
- A shield protects what its SPHERE covers, not what is bolted to the machine: `SHIELD_RADIUS`
  metres around its own block, one cell to the metre. On a long build a dome parked on the tail
  lets a frontal shot reach the cabin before it ever enters the sphere — check the geometry when
  moving one.
- WHAT THE DOME COSTS DEPENDS ON WHAT HITS IT (`WeaponBlock.shield_cost_mult`, a variable set by
  a subclass in `_ready` like `flash_color`). BULLETS ARE THE ANSWER TO A SHIELD and stay at 1.0,
  which is what `SHIELD_COST_X` is tuned to — nothing in the seconds-under-fire table moves.
  A laser pays 0.35, explosives half, a drill a quarter, so bringing them to a dome is bringing
  the wrong tool. The original's spread is FOUR to one and ours is about two, on purpose: their
  laser is a mediocre gun with a shield penalty, OURS IS THE STRONGEST GUN WE HAVE (32 dps against
  the machine gun's 25), so a straight four would be half eaten by its own damage and still leave
  a battery standing for twenty-odd seconds — longer than a fight lasts. Explosives keep their own way in regardless: `BlockFX.explosion` is a SPHERE
  QUERY, not a ray, so the blast already passes through the dome and reaches the blocks under it
  — which is exactly how the original game behaves. The multiplier rides with the damage
  (`shield_dome.hurt(damage, cost_mult)`); the dome is told apart from an ordinary block by
  `has_method("struck")`, its own door, so no node-type check is needed anywhere.
- THE ENGAGEMENT CAP DECIDES WHO STARTS A FIGHT, NOT WHO ANSWERS ONE. `combat_allowed` (the
  spawner's queue) kept a shot-at enemy silent while it stood second in line — the player emptied a
  gun into a machine that never fired back. `notice_attacker` now lifts it for `ANSWER_TIME`, and
  the spawner leaves such an enemy out of the queue while that runs.
- Acquisition has two paths (area signal, periodic search) and both must go through
  `_consider_target`, which holds the line-of-sight rule. Escape is possible: no chase bonus, and a
  damaged enemy that breaks contact gives up and moves its patrol home.
- A ROLE FOLLOWS THE BUILD, AND THE DOOR IS `enemy_spawner._apply_role`. The `miner` flag used to
  be raised only in the stream (`_spawn_one`), while `spawn_at` — the door quests, raids and the
  proving-ground panel all come through — left it false. Out of that door drove a miner's HULL with
  a fighter's BRAIN: the build carries no gun, so `EnemyBrain` ran it round the ENGAGE → RETREAT
  loop — drive up, scratch with the drill, back off ten metres, come again. Measured on the engine:
  build 91 through `spawn_requested` came out `miner = false` and patrolled a 40-64 m circle for a
  minute without ever looking for a vein; with the role applied it picked a vein on the first tick
  and drove to it. The role asks `miner_presets`, the same table the stream picks from — a second
  list of "which builds dig" is how the two would disagree.
- NOT EVERYTHING THAT DRIVES CAME FOR THE PLAYER. A MINER (`enemy_vehicle.miner`, builds 90-93)
  has no gun: it looks for a vein and drills it. **ITS ANSWER TO BEING SHOT IS THE DRILL, AND IT
  RUNS ONLY WHEN THE DRILL IS GONE.** A drill is a contact weapon that bites any foreign body in
  its zone (`drill.gd`), not only a vein, so a miner with one still has something to say; fleeing
  from the first hit gave a machine that turned and left a second into the fight, which is neither
  a chase nor a fight. `MINE_FIGHT_TIME` is a window, not a vendetta — it refreshes while the two
  are within `MINE_FIGHT_HOLD`, so a player who breaks off is not followed across the map, and the
  moment the last drill is shot off the window closes and `MINE_FLEE_TIME` starts. "Has a drill" is
  asked of the block list, never of a counter in the AI (`_refresh_drills`, one list for digging
  and for fighting).
- A WORKING BLOCK IN THE `front` ROW FILLS THE WHOLE NOSE, not the middle cell. One drill on a
  three-cell hull left two empty corners and made a wide miner dig exactly as fast as the smallest
  one — width bought nothing. Every nose cell stands in front of its own hull cell, so they all
  join by the same rear face as the centre one.
- A miner gives the player a choice — chase it for the cargo or let it go — and gives the world
  someone who is busy with something else; until then every machine on the map meant a fight.
  **IT CARRIES A COLLECTOR, NOT A STORAGE, AND THAT IS WHAT
  MAKES THE CARGO REAL.** Storage takes only what a chain neighbour hands it, and only while
  anchored (`FactoryBlock._factory_active` asks the machine for `anchored`, a field
  `enemy_vehicle` does not have at all), so on a driving miner it could never receive anything:
  the deck said "cargo" and everything drilled stayed on the ground by the vein. The collector
  needs no anchor on purpose — picking up off the ground while moving is its whole job. Measured
  on the engine: a spawned miner's collector took all four ore items dropped under it. Its builds are deliberately NOT in `PRESET_TIERS` (that table
  picks by the player's machine value, so a miner would take a fighter's place) and it never
  queues for an engagement slot. `resource_nodes.vein_point_near` scores by closeness to the
  MIDDLE of the ring it is given — that was written for the battery quest, where the errand has
  to be a trip — so a miner asks a NARROW ring first and only widens when the neighbourhood is
  empty; with one wide ring it drove 190 m past nearer veins, measured.
- Fortified points (`outposts.gd`) are the only things placed on the map instead of around the
  player: constant seed, cleared stays cleared, saves store indices only.

### Terrain (LiteTerrain, third-party addon we patched)

- ONE TERRAIN NODE FOR EVERYTHING: `chunk_terrain.gd` (`ChunkTerrain`). No window, no world-sized
  height array, no heightmap file — a chunk asks the generator for its own vertices, and the game
  world and the menu backdrop are the same node with different numbers. `map.gd` (`LiteTerrain`),
  the baked-map half — a sliding window of heights, the macro mesh, sculpting, generation and
  baking — IS GONE, and with it 5,800 lines and half a megabyte of baked heights nobody could
  regenerate without the dock. Measured before deleting it: a menu round on the old node took
  8.2 s, the same round on the chunked one takes 3.9 s.
- THE MENU BACKDROP IS THE GAME'S OWN GROUND, tuned down rather than replaced: `MENU_VIEW` 320 m
  against the game's 1400, `ready_view` 32 against 192, `ready_ring` 1 against 2. It is up in
  1.1 s; the world, which waits for 192 m of view, in 3.7 s. The camera hangs
  over one fight and never travels, so everything past a few hundred metres is horizon nobody looks
  at, and every metre of it is noise computed on the phone that also has to run the menu. There is
  no authored first map any more — every round, the first included, is generated the same way.
- THERE IS NO SCULPT BRUSH, AND THAT IS THE DESIGN. It made sense while a map was a file of
  heights edited by hand; a procedural world has a SEED, and the only question is what the seed
  gives. The answer is the MAP AT THE TOP OF THE NODE'S INSPECTOR (`seed_browser.gd`): step
  through seeds and watch where the regions land. It draws the BIOME MASKS, not the heights —
  measured, three masks cost about 5 us a point against 124 for a height, so at 128×128 that is
  eighty milliseconds against two seconds: flipping through seeds against waiting on each. The
  mask offset comes from `TerrainBiomes.offset_for_seed`, the generator's own function: a second
  copy would draw a layout the game does not build. Under it, the distance rings to scale — four
  numbers in a list never showed that `keep_radius` must sit inside `view_distance`.
- THE `camera` EXPORT IS AN OVERRIDE AND STAYS EMPTY. Both terrains take the camera the scene is
  DRAWN with (`get_viewport().get_camera_3d()`), so they follow camera switches, spring arms and
  machine changes by themselves. A path stored in a scene is a liability: one once saved as the
  EDITOR VIEWPORT's camera, which does not exist in a running game.
- LOD IN THE GAME WORLD IS CHUNK MERGING: a node of level L covers 2^L × 2^L chunks of 16 cells and
  is drawn with the same 16×16 quads at step 2^L. Four chunks become one mesh, polygons drop to a
  quarter, nothing is decimated. Level 0 reaches 64 m, and each next one doubles
  (`LOD_QUALITY` = 2). Details: `docs/CHUNK_TERRAIN.md`.
- THE COST OF THE WORLD IS `height_at`, AND IT IS MEASURABLE. 124 us a point × 441 points a chunk
  × 25 chunks is the 1.1 s starting ring; before the noise went native it was 391 us and 3.7 s.
  Anything that claims to speed up loading has to move that number — or it is moving nothing.
- The generator answers BY POINT: `height_at(wx, wz)` is noise, blur and the canyon cut in one world
  point, and `sample_grid` builds a grid from it. The blur is always taken at FULL resolution, even
  when the node samples every 32nd cell — blurring an already sparse grid is a different field, and
  the join with a finer node would step. At STEP 1 those five taps are the neighbouring vertices, so
  a chunk costs (n+2)² raw heights instead of 5n² (`_sample_unit`) — four times less for the same
  answer. `begin_sampling` prepares the noises once on the main thread; after that the threads only
  read.
- A NODE IS HIDDEN ONLY WHEN OTHER GROUND ALREADY COVERS IT. A LOD change is not "the node left",
  it is "the node was replaced": one coarse becomes four fine or the other way round, and the
  replacement is still in the queue. Hiding the old one in the same tick opens a hole where it
  stood — that is what "chunks disappear while I drive" was. Cover counts only a tree neighbour the
  frame WANTS and that is already BUILT. `frustum_margin` is METRES and widens, but ONLY ON THE SIDE
  PLANES — on the near plane a positive margin means literally "draw what is behind the camera",
  which is why it once had to be pushed negative (it applied to all six at once). Near and far are
  told apart by their normal against the camera's forward, never by index. The selection is
  recomputed on camera movement, not only on `lod_interval`.
- WHICH NODES AND WHICH OF THEM ARE VISIBLE ARE TWO QUESTIONS, ASKED AT DIFFERENT RATES. Splitting
  a node depends ONLY on distance; the frustum decides only what is drawn. Asking both in one
  recursive descent per tick cost 6.6 ms — a third of a 60 fps frame, four times a second while
  the camera moves. Now the LEAF SET IS CACHED (`_build_leaves`) and a tick is a flat pass over it
  (`_select` → 1.7 ms), with the frustum folded into six rows of floats beforehand
  (`_pack_planes`) so the inner loop has no `Plane`, no `Vector3` and no calls. The descent
  repeats only when the camera has moved a whole base chunk (`LEAF_MOVE2`, 16 m): THE CAMERA
  ORBITS THE MACHINE, so a turn is not a camera standing still — it is an arc a hundred metres
  long, and a metre-sized threshold would rebuild the whole way round. The price is that an LOD
  boundary lags by those 16 m, which is ordinary hysteresis and not a hole: the ground is there,
  the seam is stitched, and collision runs its own queue along the body's corridor.
- THE FIRST RING IS BUILT AT THE START POINT: the camera in a new world, and in a LOADED one the
  primary machine's saved position, read straight out of the save (`G.saved_start_point`). The
  machine returns to its place only AFTER the terrain is ready — `world_persist` waits for it — so
  building around the camera would build where the scene happened to open. With a saved point the
  view stage waits for a DISC around it at half the radius instead of the camera's cone: where the
  player will look is unknown, and a disc is four times the nodes of a cone.
- COMPUTING IN A BATCH IS FINE, LANDING IN A BATCH IS NOT. The pool computes `build_batch` chunks
  in parallel and that is cheap — each thread writes its own slice. Landing them is main-thread
  and expensive PER CHUNK: an `ArrayMesh`, a vertex upload, a new node in the tree. Twenty-four of
  those in one frame is what a player measured as 30 fps standing still against 22 while driving
  onto new ground. So results go into a QUEUE and at most `apply_budget` (4) leave it per frame,
  with the pool held back while the queue is not empty — without that backpressure the queue grows
  faster than it drains and the ground falls further behind anyway. COLLISION TILES ARE OUTSIDE
  THE BUDGET: a tile is what the machine drives on and cannot wait a frame; a mesh is what it
  looks at and can. During loading the budget is off entirely — the screen is behind the fade,
  there is nothing to smooth, and throughput is what matters.
- NEAREST FIRST. Both queues are sorted by distance to
  the camera every LOD tick; without that the order was the tree walk, so a node a kilometre away
  could be built before the one being looked at. Coming back is cheap only while the heights are
  still cached (`HC_CAP`): rebuilding a mesh from them is vertices and colour, computing them again
  is four times that from nothing. WITHIN `keep_radius` (320 m) nothing is dropped at all, by time
  or by cap — that is the ground the player turns back onto in a second; a 320 m disc is about 150
  nodes across all levels, because the far levels cover a lot with one node.
- THE LOADING SCREEN WAITS FOR TWO THINGS: the ring of level-0 chunks with their collision
  (`ready_ring`) — the ground under the wheels — and then the nodes the frame WANTS within
  `ready_view` metres, which is what the player actually sees. `ready_view` IS A CLIFF, NOT A
  SLOPE, and the cliff is where the LOD band changes: measured at 64/96/128/160/192 m the total
  wait ran 1.1 / 1.6 / 3.0 / 4.0 / 4.1 s. Level 0 reaches 64 m and level 1 to 128, so anything
  past 96 starts waiting on level-2 nodes, and a coarse node costs five times a fine one. The
  world sits at 96 for that reason: one metre more of first-frame view past it costs whole
  seconds. With only the ring the machine stood
  on collision in the middle of nothing and the view arrived after the fade lifted. Waiting out to
  `view_distance` is not an option: a coarse node costs five times a fine one (past a one-metre step
  the blur cannot reuse neighbouring vertices), so the full set is tens of seconds. Nothing can be baked ahead: the seed is the slot's
  own, so precomputing chunks is the same work moved earlier.
- Neighbour level is asked by `_level_of` (six dictionary lookups, not a tree walk), and the finer
  node lays its extra edge vertices on the segment between the ones it shares with the coarser. A
  corner vertex is a multiple of any neighbour step, so two snapped edges never argue.
- A collision tile IS a base chunk, cut from the same heights as the level-0 mesh — under a near
  chunk it costs nothing. ITS QUEUE IS SEPARATE AND FIRST: a tile is what the machine drives on, a
  mesh is what it looks at, and behind one shared queue the ground ran out every few metres. Tiles
  are asked for along the body's CORRIDOR (where it is plus where it will be in
  `collision_lookahead` seconds), never by moving the window ahead — at speed the body would leave
  its own window. Terrain edits are a LIST applied on top of the generator in one function
  (mesh, collision and height query all go through it); there is nothing to bake.
- No skirts on seams, ever. Edges meet because every step is a power of two on one grid, and the
  chunk is restitched in the same pass the coarse mesh appeared.
- Generation and rebuilds are threaded (`WorkerThreadPool`, one task per row or chunk): a thread
  writes only its own slice, reads only immutable data, never touches the tree.
- The mesh may know more than physics: ripples and rock roughness are baked into near chunks only,
  zero at chunk edges, as a function of world position and biome.
- Layers must not eat each other: metre values derive from `Height`, and dampening a layer by a mask
  makes a step exactly as tall as what it removes — the canyon cuts finished ground instead.
- The generator NEVER writes into the biome resource except `mask_offset`. The resource is an input;
  metres that depend on Height (the snow line) are held there as a SHARE and multiplied by
  `map.world_height()` when the materials are built. A generation pass that edits an authored field
  is a slider that moves back, a scene diff per run, and a value that is right for one map only.
- The generator cancels itself on `NOTIFICATION_EXIT_TREE`/`PREDELETE`, and a terrain does the same
  for its own (`stop_generation`). A scene change or a freed map otherwise leaves worker tasks
  computing into an object that is being destroyed.
- `LiteTerrainGen` ANSWERS BY POINT AND NOTHING ELSE. The threaded row passes over a whole-world
  array, the buffers, the staged progress plan and the cancel-halfway machinery all belonged to the
  baked map and went with it. What is left is `height_at` / `sample_grid` plus `natural_params`,
  the one copy of the landform numbers that the world and the menu both build on.

### Quests

- `quest_manager.gd` (`Q`) holds data; `quest_arcs.gd` is the physics of a branch (what appears in
  the world, what counts as done, polled once a second); `quest_props.gd` owns items placed into the
  world; `quest_compass.gd` draws the marker and exposes any quest's target.
- STORY is story only. Counters live in DAILY, events repeat and are capped at two journal slots.
- Quest participants spawn immediately at `EV_SPAWN_DIST` (250-300 m) — one rule for every branch.
  Far away they cost nothing because the spawner sleeps them. Waves are the exception: they arrive
  at the player.
- A RELEASED STORY QUEST TAKES THE TRACKER (`_track_story_if_free`, called from `release_quest`).
  `hold_quest` keeps the first story quest back until its target exists — the scout arrives after
  `first_spawn_delay` — so at the moment the tutorial ended the head of `active_quests` was a
  DAILY, and that is what `_auto_track` picked. The player left the tutorial tracking "sell ore"
  while the first story quest appeared silently as the third row. It does NOT steal a story quest
  the player is already on: the tree branches, and an opening sibling must not drag them off the
  branch they chose. Dailies and events are stolen from freely — those are endless, the story is
  not.
- A HANDED-OUT BLOCK GETS THE FINGER BEFORE THE CELL DOES. `_arc_power_1` points at the panel
  lying in the grass and only shows the blueprint once it is in hand; `_arc_power_2` never copied
  that, so it asked for a repair unit to be placed while the block was still on the ground and the
  outline hung on the support — "place the repair unit" with empty hands and no idea what or
  where. Every arc that calls `_props.ensure` needs that branch, or a `Dialogue` line that says
  the kit is on the ground (`_spawn_line_kit` does the latter).
- A marker without a target is not drawn: kill quests look for a `story` machine first, then the
  nearest enemy within `KILL_MARK_DIST`. While a participant lives the marker follows it, not the
  point.
- A quest BUILDING cannot be pocketed or dismantled while its branch is open
  (`vehicle_body_3d.quest_locked`, checked in `send_to_inventory`/`disassemble`): carrying the
  factory pad away silently dead-locks the player's own branch.
- Quest items carry meta `quest_id`; that is how cleanup, saving and rescan recognise them. Handing
  out goes through `ensure`, which never duplicates something the player already owns.
- A story block is taken, not found: carried by an enemy or held by a vein, and a killed carrier
  must leave the block behind (`claim_or_drop`) or the branch dead-locks.
- Placement is shown by a blueprint (`_show_plan_on`), rebuilt only on plan change (`_plan_sig`).
- A quest may put a BUILDING in the world (`_spawn_station`): no cabin, a stationary core, anchored
  from birth, the player's faction — so it can be built on and the camera can switch to it. The
  energy branch is one: an anchored support 50 m out with the panel beside it, then the repair unit.
  Such a base carries meta `quest_id` and that tag is saved with the machine (`world_persist`), or
  every load would stand a second base next to the first — the arc's own state is memory only.
- The tutorial is five steps, assembly only. Non-obvious gestures are a Mechanic line at the end.

### The proving ground

- IT IS THE SAME WORLD, NOT A SECOND SCENE. `node_3d.tscn` with `G.proving_ground` raised: flat
  ground, no stream of enemies, no quests, no save, an endless stock of blocks and a control
  panel (`proving_ground.gd`, a node in the world scene that frees itself when the flag is down).
  A separate scene would mean a second copy of the camera, the HUD, the player machine and two
  dozen nodes, and that copy starts drifting from the original with the first edit to either.
- THE PANEL SWITCHES NOTHING OF ITS OWN. The stream, the AI, raids, outposts, the tutorial,
  invulnerability and infinite energy all already have exactly one door each — the debug flags on
  `Main` read through `G.debug` — and the panel writes those. A second "turn the AI off" is how
  the AI ends up off in one place and on in another.
- THOSE FLAGS GO UP IN `_enter_tree`, NOT IN `_ready`. Godot walks the tree twice: `_enter_tree`
  top-down over the whole branch, then `_ready` bottom-up. The panel is the last child of the
  world, so in `_ready` it is already late — `tutorial_director` has asked `G.debug("tutorial")`,
  got the default and started the walkthrough. Measured: the polygon opened with a tutorial
  tracker and a SKIP button on it.
- FLAT GROUND IS A FLAG ON THE GENERATOR (`LiteTerrainGen.flat`), because heights leave it by two
  roads — `height_at` for the query and `sample_grid` for meshes and collision — and both have to
  be shorted. Everything else (chunks, LOD, the collision queue, grass) runs exactly as in the
  game, so the polygon tests the game rather than a mock-up. The ground's colour is the meadow
  mask forced to 1 (`ChunkTerrain.FLAT_COLOR`); the masks are not sampled at all there.
- NOTHING ENTERS THE WORLD ON THE POLYGON EXCEPT THROUGH THE PANEL. Switching the stream off is
  not enough, because the stream is not the only thing that asks for a machine: the story scout
  comes from `tutorial_director` through `spawn_scout_near_player`, and quest branches call
  `spawn_at` directly. Both of the spawner's doors now refuse while `G.proving_ground` is up, and
  the panel goes through `spawn_requested`, which lifts the ban for exactly one call. Shutting the
  askers off one at a time only means waiting for the next one.
- THE POLYGON CARRIES ITS OWN MONEY, GRADE AND RESEARCH (`_sandbox_progress`), not the slot's. It
  borrows the last played slot for a path in `user://`, so the real numbers arrive in memory with
  it — and a player who sees their own balance and grade on a test ground draws the only sensible
  conclusion, that their save went in there. It cannot (`G._flush_progress`), but an interface
  that looks like data loss is no better than data loss. Writing the field is not enough either:
  the HUD counter updates on `money_changed`, never by polling.
- LEAVING THE POLYGON IS ONE FUNCTION, `G.leave_proving_ground`, and it does three things in order:
  drops the flag, drops the pending write, re-reads progress from the slot file. The ban on
  writing holds only WHILE THE FLAG IS UP, so a `mark_progress_dirty` left over from the polygon —
  a one-second timer — would land sandbox numbers in the real slot the moment the flag cleared.
- CHOOSING AN ENEMY IS ITS OWN WINDOW: steps down the left with a count each, cards on the right
  carrying the build's number, floors, width and weapons. Arrows in the corner of the panel could
  not do this — they compare nothing and never say how many there are, so learning what a step
  holds meant clicking through all twelve and remembering. Spawn works without closing the window,
  since several machines of one step usually go down in a row. Every word on a card is computed
  by BUILDING THE LAYOUT FOR REAL — a `blocks.gd` node outside the tree, `_init_map` plus
  `_define_layout`. The table row answers only part of the question: `wings` is one type across
  two shoulders, and armour plates and the floor are not in it at all — `_layout_enemy` lays those
  out from the row count and the width. Counting them again here would be a second copy of that
  function. `set_block` only writes the grid, so not one block scene is instantiated and twelve
  cards cost twelve dictionaries; answers are cached. Cross-checked against a live machine: build
  #25 comes out at 29 blocks both ways. The groups come from `PRESET_TIERS` itself, plus one last group for everything not on
  the ladder (miners and any future row), because a proving ground has to show what the value curve
  never rolls.
- THE PARTS LIST READS THE MACHINE, NOT THE TABLE (`_refresh_parts` over `blocks.get_layout`).
  Counting from `ENEMY_BUILDS` would be a second copy of `_layout_enemy` — rows, width, armour
  plates, wings, the nose cell — and the two are obliged to disagree at the first edit. The same
  `get_layout` the save uses already resolves anchors and footprints, so a multi-cell block counts
  once.
- ALL BLOCKS ARE HANDED OUT, not merely made unlimited. `block_available` answers "is there
  enough"; the picker globe asks something else — it walks `G.block_inventory` itself, and an
  empty list gives it nothing to show. The count does not matter: `consume_block` deducts nothing
  there, so the stack never shrinks.
- RAW MATERIAL IS HANDED OUT TOO, and it has to be: veins and trees are laid out by RELIEF AND
  BIOME, and flat ground has neither (`min_height` 2.0 against `flat_y` 0.0), so nothing will ever
  grow on the polygon by itself. THE RESOURCES WINDOW HANDS OUT BOTH HALVES, and they are not
  interchangeable. A VEIN (`resource_nodes.spawn_vein`) answers everything up to the belt: does the
  drill aim at it, does the auto-miner find it, does the collector pick up what flew out, does an
  enemy miner drive to it. An ITEM lying on the ground answers what comes after: does the crate
  reach the fabricator. Six blocks — receiver, belt, processor, storage, fabricator, seller —
  cannot be tested at all without one, because every one of them starts with an item somebody
  delivered. Batches are `VEIN_BATCH` (3: the auto-miner picks the NEAREST of several, and on one
  vein that half of its behaviour is invisible) and `RES_BATCH` (5: a chain is interesting as a
  STREAM). Item kinds are `resource.set_kind_key` KEYS — the same strings storage, the fabricator
  and the save tell materials apart by; a local "metal + type" list here would be a second parser
  of the same key. COMPONENTS ARE DELIBERATELY ABSENT: the fabricator makes them out of ingots, and
  handing them over ready would delete the one step the chain is tested for.
- WHAT IS HANDED OUT HAS TO BE REMOVABLE, AND THE SWEEP BUTTON IS THAT DOOR. Requested veins are
  three per press and nothing took them away: the sweep cleared `/root/Main/objects`, where loose
  items live, while a vein is a node under its owner plus a record in `_made`. Ten presses piled
  thirty of them into one spot, which reads as "they multiply" — measured, the records grow by
  exactly three a press, so nothing was ever duplicated, it simply never left. `clear_made` sits
  with the owner, beside `spawn_vein`, and touches nothing seeded.
- A QUEST CAN BE HANDED TO YOURSELF, AND THE DOOR IS `Q.force_quest` — the mirror of `hold_quest`.
  A branch is locked behind four different gates (the previous quests' `requires`, `req_grade`, the
  two journal slots, and "no story while the tutorial runs"), so waiting for the proving ground to
  grow into a quest means never testing it. A forced quest is reset to its first stage before it is
  handed over — the polygon borrows the last played slot, where the story may already be finished —
  and it rides in `active_quests` / `visible_quests` ahead of everything else. TUTORIALS ARE
  REFUSED: `tutorial_director` walks those step by step, and a step torn out of the middle tests
  the desync, not the branch.
  **THE LIST IS MEMORY ONLY AND IS CLEARED IN `reload_from_progress`,** beside `_held`. `Q` is an
  autoload and outlives a scene change: hand yourself a branch on the polygon, leave to the menu,
  start a real game, and it would still be running past `requires` and grade inside a save. Every
  way into a real game picks a slot, so `G.use_slot` is that single door.
- `quest_arcs` NO LONGER SWITCHES ITSELF OFF ON THE POLYGON — it drives ONLY what was handed out
  (`_arc_quests`), which is the same rule the spawner lives by there: nothing enters that world on
  its own. Asking `active_quests` there would be wrong rather than merely wasteful, because the
  borrowed progress can have the story finished, and its branches would open with no button
  pressed. Measured on the engine: before issuing, the polygon held zero quest machines; issuing
  "Draw Power" put its anchored station in the world within seconds, and a tutorial step was
  refused.
- A REQUESTED VEIN LIVES IN ITS OWN LIST (`resource_nodes._made`), never in a region. A region is
  computed FROM THE SEED and is obliged to give the same set however many times it is asked; a row
  appended to it would vanish at the first rebuild, which is the moment the player drives one
  region away and comes back. The record itself has the shape `_build_region` writes and goes to
  the same `_stream_in`: the MultiMesh slot, the collision node, the ore colour and the streaming
  are all already there.
- THE PANEL IS IN THREE PARTS, and that is not decoration. Twelve controls of three different
  kinds live there — what to spawn, what to switch in the world, what to clear up — and in one
  column they read as a list you search through every time. Long lists (builds, materials) are
  WINDOWS, not fold-outs in a 300-point panel: fifteen buttons there are a column the height of
  the screen, and everything else slides under it.
- WHAT IS A MODE AND WHAT IS A FLAG. The stock, the ground, the quests and the save ask
  `G.proving_ground` directly — they are not debug switches anyone may flip. The save is barred at
  `G._flush_progress`, the single write to disk, not at `save_now` and `mark_progress_dirty`
  separately: there are two of those and one day there will be a third. The polygon borrows the
  last played SLOT (autoloads need a path in `user://`) and must never be able to spoil it.
- The flag is cleared in `menu._ready`, unconditionally. Clearing it only on the way out
  (`tech_ui._to_main_menu`) is not enough: it lives in an autoload and survives a scene change,
  and there are other ways out — a crash, the back key, returning from a minimised app. A
  forgotten flag would mean the next REAL game on flat ground with an endless stock and no save.

### Saving and slots

- A slot is a path prefix (`user://sN/`); file names never changed. Device config
  (`settings.json`) lives outside slots.
- World and progress are separate: `WORLD_FILES` (seed + window cache) versus `PROGRESS_FILES`.
  The menu can create a world without starting it, reset a playthrough while keeping the map, or
  delete the world outright.
- `G.world_seed` drives EVERYTHING: the ground itself (the chunked terrain computes it) and
  everything laid out on it (veins, outposts, props), each consumer with its own RNG and seed
  offset. ALL SLOTS ARE THE SAME — every new world is a new seed. Slot 1 used to be the "original"
  map on a fixed seed, back when it meant a baked file; with no file maps left, a special slot would
  only mean the same world three times.
- CREATING A WORLD IS PICKING A SEED, and it is instant — `create_world(slot, seed)` writes one
  line. The menu used to compute a window of heights first (a minute with a bar and a Stop), hand it
  over through `G.pending_world` and cache it on disk; the chunked terrain reads none of that, so
  the handoff, the cache and the reset-progress button are all gone. Deleting a slot erases the
  world and the save together.
- Deleting a world lives in the MENU, next to the slots: hold, then a question that names the slot.
  The in-game settings have no wipe button: one tap, irreversible, among sliders.
- Autoloads must be told the slot changed: `G.use_slot` calls `Q.reload_from_progress()`, otherwise
  a reset slot opens with the story already finished.
- Death holds a screen for `DEATH_PAUSE` before the hand-over (`hud.show_death`): the camera stays
  where it was, so the wreck and whoever made it are still in frame, and the name comes from the
  same generator the enemy labels use (`EnemyMarker.name_for`, fed by `notice_attacker` — which the
  player machine now has too, see rule 7).
- Death hands the camera to the nearest own machine WITH A CABIN, and spawns a starter one (kit
  included) when there is none: `vehicles` also holds stations, and handing over to one of those
  read as "I respawned on my base" — no cabin, nothing to drive.
- `world_persist.gd` saves machines, loose blocks and a 10-minute TTL. A base is a machine with the
  `station` flag; `machines[0]` is the one the player controls; restoring runs across frames, so
  `is_instance_valid` after every `await`.
- Terrain edits survive two ways: an edit list in the save for the session, and a baked dump applied
  at load. Every edit has a running number so it cannot be applied twice.
- WAITING FOR THE TERRAIN IS MEASURED IN SECONDS, NEVER IN FRAMES (`world_persist.TERRAIN_WAIT_SEC`,
  and `resource_nodes` was the first to learn it). Readiness is worker threads computing heights —
  real seconds, about 3.7 of them for the world. A frame count guesses at what those seconds cost
  and guesses wrong in both directions: 120 frames is four seconds on a phone and a blink headless.
  When the wait expired everything behind it was skipped WITHOUT A WORD — the saved terrain edits
  were never replayed, so a quest's levelled pad came back as raw hillside on every load, and
  restored machines kept only their X/Z.

### UI

- The scene holds what stands still (frame, padding, style, nesting); code holds what changes (text,
  visibility, edge layout, anything built from data). Code fetches nodes by unique name.
- Icons are `_draw()` classes with no node representation — EXCEPT a block's own portrait, which
  the game BAKES ITSELF at first launch (`icon_baker.gd`, autoload `Icons`). Shipping PNGs was the
  alternative and it is worse: they go stale against the models at the first mesh swap, and go
  stale SILENTLY. The source here is the model the block is built from. It bakes at STARTUP rather
  than when the shop opens, because it is needed once per install and the menu's first seconds are
  already spent computing ground behind the backdrop; the node is an AUTOLOAD because the player
  may hit PLAY a second later and the work has to survive the scene change. Measured: 45 icons in
  1.8 s, 198 KB in `user://icons`.
- WHAT IS BAKED IS THE MODEL, NOT A WORKING PART. A live block builds a four-metre shield dome, the
  laser's charge rings, the repair cloud and the damage shell in `_ready`; none of that belongs in a
  portrait, and the dome alone shrank the block to a hundredth of the frame. So scripts are stripped
  BEFORE the node enters the tree and effect meshes are skipped by the same `block_fx` meta
  `_local_aabb` uses, plus the dome's own door `struck`. Files are named by ENUM KEY like saves
  (`G.block_key`), never by number: renumbering the enum is an edit nobody would notice.
- **A BAKE VIEWPORT NEEDS AN `Environment` WITH `CameraAttributes`, OR EVERY LIT SURFACE COMES OUT
  PURE WHITE.** The project runs on PHYSICAL LIGHT UNITS (`rendering/lights_and_shadows/
  use_physical_light_units`), so a `DirectionalLight3D` is measured in LUX and `light_energy` barely
  matters; lux only means something against an exposure, and a viewport with no `CameraAttributes`
  has no normalization at all. The first bake had neither, and 26 of the 45 icons were blank white
  silhouettes — the shop's whole grey GSO half. The survivors survived for a reason that pointed
  straight at the cause: their materials are `unshaded` and never see a light. Two more things go
  with it. REFLECTIONS ARE DISABLED, not dimmed: with `transparent_bg` there is no sky to reflect,
  the engine's fallback one is WHITE, and the older models sit at roughness 0.5, so they collected
  it over the whole surface — which is why the white did not move when the light energy was swept
  from 0.1 to 4.0. And AMBIENT IS A COLOUR, because that missing sky was also the fill light: with
  none, shadow faces go black and the icon reads as a silhouette again. The exposure numbers are
  the world's own (aperture 19, shutter 1/100.5), so lux in the studio means what lux means in the
  game.
- THE STAMP CARRIES A RECIPE NUMBER (`icon_baker.RECIPE`), not only the app version and the block
  count. A change to the LIGHTING moves neither of those, so a player who already has a batch on
  disk would keep it for ever — which is exactly what the white icons would have done.
- A PORTRAIT IS SKIPPED WHEN ITS MESH IS ADDITIVE (`icon_baker._is_glow`). The receiver and the
  collector each carry a four-metre capsule with `blend_mode = ADD`: in the world it is an intake
  beam, in a portrait's bounding box it is a pole next to which the block shrinks to a dot, and
  both icons came out as vertical slivers. The `block_fx` meta cannot help — the beam lives in the
  block's own scene, not in the effects — so the material answers instead: only a glow is drawn by
  adding to the background. Measured after: those two went from 0.24 saturation to 0.37 and 0.43.
- THE SAME PORTRAIT IS ON FOUR SCREENS NOW, through one door each way: shop and inventory rows
  (`_set_slot_icon`), the tech tree and the codex graphs (`_node_icon`, shared because their layout
  is shared), and the proving-ground build cards (`_card_icons`). A graph node grew from 96 to 136
  points to hold a 40-point portrait on the left, and `TCOL_W` grew with it so the gap the link
  lines run through stayed the same. `Icons.baked` rebuilds whichever tab is open: the bake finishes
  seconds after launch and the player can be in the garage before it does.
- The single door out is `Icons.get_icon(bt)`, and it returns NULL until the bake finishes. An icon
  is decoration, never a condition for the shop to work: the caller draws as it drew, and
  `Icons.baked` tells an open panel to redraw.
- A SHOP/INVENTORY ENTRY IS A ROW, NOT A TILE. Four columns on the narrow left panel gave sixty-point
  tiles, which fit neither the model nor the name — and a translated name is twice the English
  («Stabiliser Wheel» against «Стабилизирующее колесо»). A row gives the picture its own square on
  the left, the name the whole remaining width and the price the right edge, and it reads at any
  panel width. The grid stays an `HFlowContainer`: rows happen by themselves because a slot's
  minimum width is the grid's width. That also deleted the per-word font fitting — there is room
  now, so nothing has to shrink.
- The garage CODEX tab is built from the same tables the game runs on (`G.Block`, `METAL_NAME`,
  `COMP_NAME`): a hand-written second catalogue would fall one block behind and say nothing about
  it. BOTH ITS KINDS ARE GRAPHS on the tech tree's canvas (`TechGraph`), and neither is a grid of
  tiles. BLOCKS reuse the tech tree's OWN layout (`_tech_layout`, edges from `G.TECH_PARENT`): the
  order blocks are researched in IS the shape of the progression, and a second layout here would
  drift from the tree at the first change of a parent. They differ from the tree in one thing —
  no RP and no locks, because the codex explains rather than sells. CHAIN is columns for raw,
  ingots, simple and complex with real edges from `G.COMP_PARENT`; every component has EXACTLY
  TWO parents, and only lines show that. THE FLAT LIST OF RESOURCES IS GONE: it answered "what
  exists" and said nothing about where it comes from, which is the one thing CHAIN already shows
  with the same names. The category filter is gone from the codex with it — filtering a TREE
  leaves it with holes, because the edges run through the hidden nodes.
- A CODEX ENTRY OPENS IN A STRIP ALONG THE BOTTOM, not a centred dialog. A centred window covers
  exactly the node just tapped and has to be dismissed before the next one: reading three entries
  was three opens and three closes. The strip lies over the graph, swaps its contents on the next
  tap and takes no height from the layout. Block text lives in `G.BLOCK_DESC` — one sentence about
  what the part DOES, never numbers, which move; a component's text is derived from its recipe.
- MUSIC CONTROLS ARE ONE PANEL, `music_panel.gd`, used by the garage tab and by the main-menu
  settings; the only difference is WHICH context lists it is given. The menu shows its own,
  the garage the two the world plays. The MENU context itself is set by `menu.gd` while that
  scene is up and cleared when it leaves — the flag sat in the manager unused for months and
  `music/menu/` never played once, because the autoload outlives the scene and nobody owned the
  switch. Turning music off is `set_enabled`, not volume zero, which forgets the level.
- **A LABEL ON A BLOCK LIVES BY THE BLOCK'S RULES.** The storage counter was a `Label3D` with
  `fixed_size`, i.e. the same size on screen at any distance, and on a base with three storages the
  numbers covered the base — «742» measured wider than the deck it stood on. It is now world-scaled
  and hidden past `LABEL_DIST` (14 m), the same shape of rule as the machine icon's
  `VBTN_SHOW_DIST`. The distance check must come BEFORE the early return in `_process`, or a label
  hidden once never comes back: ask the COUNT, not the current visibility. The enemy marker is NOT
  this bug — it is an ordinary billboard in world space and shrinks with distance as it should.
- A COLLECTOR SHOWS ONE PICKED ITEM, not the stack. It used to place each one a metre above the
  last (`y = index + 1`), so at capacity ten a tower of ore grew taller than the machine carrying
  it. Same answer as the storage's showcase: one visible, the rest hidden — and the visibility
  comes back at the SINGLE DOOR OUT (`remove_from_inventory`), or a hidden lump would ride the
  belt invisible.
- `CanvasLayer` child order is draw order — bound panels are lifted to the end (`hud._lift`).
- A FLOATING HUD PANEL IS `DragWindow`, ONE IMPLEMENTATION FOR ALL OF THEM (quest tracker, quest
  journal, the proving-ground panel). It is attached the way `SwipeClose` is —
  `DragWindow.attach(window, handle, id)` — and it owns the drag, the remembered place
  (`G.set_window_pos`) and the clamp on resize. The HANDLE is not always the window: the journal
  is dragged by its header only, because a list that catches the drag with its whole body stops
  scrolling under a finger. A handle that is a Button must ask `dragged()` and swallow its own
  press: `Button` fires `pressed` on release even after the finger has hauled it across half the
  screen. `dragged()` clears the flag as it answers, or one stray drag would mute every tap after
  it. Panels that merely hover over the world go in the group `hud_float`, so the garage hides
  them all at once; `quests` stays its own group, since the radar moves THAT window
  (`set_top_offset`) and has no business moving a developer panel.
- LANGUAGE: en / ru / uk, picked in the menu settings (`G.set_lang`, kept in `settings.json`, empty
  means English). The KEY IS THE ENGLISH STRING ITSELF (`i18n/strings.json`, loaded into
  `TranslationServer` by `G._load_translations`): a string starts being translated the moment its
  row appears, an unwrapped one keeps working. Scene text translates itself; text set from code
  needs `tr()`. **The game is translated in full** — menu, HUD, garage, shop, tech tree, codex,
  quests, Mechanic and System lines, block and material names. A new user-facing string is a `tr()`
  plus a row in the same commit; `i18n/strings.json` keys are matched BYTE FOR BYTE, leading and
  trailing spaces included.
- WHERE A STRING IS TRANSLATED IS AT THE EDGE, not where the data is written. Quest titles, hints
  and descriptions stay ENGLISH in `quest_manager`; `quests.gd`, the tracker and `Dialogue` call
  `tr()` on them as they draw. The same rule made `research_lock_reason` split in two: a CODE for
  the code to branch on, a phrase for the player — the UI used to test `why.begins_with("need RP")`,
  and a translated phrase does not begin with that.
- **THE TRANSLATION IS LONGER THAN THE ORIGINAL, AND THE LAYOUT HAS TO TAKE IT, NOT THE WORDING.**
  «CODEX» is five letters and «СПРАВОЧНИК» is ten. The garage tab row picks its font size from the
  row's own minimum width (`tech_ui._fit_tab_row`); a shop tile picks its font from the LONGEST WORD
  in the name, because wrapping saves a line but never a word; the quest tracker and the journal
  rows clip with an ellipsis instead of spilling past their panel.
- NOBODY SPEAKS OUTSIDE THE WORLD. `Dialogue.say` drops the line when `/root/Main` is absent, and
  clears a visible one when the world goes away: `Q` is an autoload that comes up before the first
  scene, so its greeting used to land on the main menu. The greeting itself is asked for by the
  world (`Main._ready` → `Q.announce_start`), not by the autoload.
- A code-built window is centred by `CenterContainer`, not anchors: its minimum size changes after
  the children are added.
- A window scene whose own script opens it must use `load()`, not `preload` (compile-time cycle).
- Camera: down orbits the camera up, up raises the look point; heading comes from the forward vector
  flattened to the horizon, never from `global_rotation.y`.
- Switching between your machines is the ICON ABOVE THE MACHINE and its radial menu
  (`hud._update_vehicle_button` → `open_vehicle_menu`), and nothing else: a second way to do the
  same thing is a second button in a crowded corner. The icon shows within `VBTN_SHOW_DIST` (15 m):
  it is a button over THAT machine, and at sixty it hung over every machine in sight and read as a
  map marker. The price is that a base left at a vein has to be driven up to.
- Menu backdrop is a REAL fight on a REAL `ChunkTerrain`, generated per round from an audition of
  seeds, with streamed collision and two enemy machines of DIFFERENT factions carrying their own
  physics, AI and weapons. It carries `follow_world_settings = false`, or G would hand it the save
  slot's seed. Its biome resource lives on the STAGE (`menu_stage_3d.biomes`) and is duplicated per
  map: the generator writes the seed's mask offset into it, so one shared copy would move the
  regions of the map currently on screen while the next one is being prepared. Demo
  machines carry `demo = true` (no rewards, no quest progress, no retreat). A round runs 30 s and
  only THEN starts generating the next map, with the fight continuing meanwhile; the reset happens
  when that generation finishes, and never two generations at once. A death or a machine left
  without weapons does NOT touch the map — it is replaced by another random build beside the
  survivor (`_replace_fallen`, after `ARM_GRACE`, because a machine has no weapons in the frame it
  is born). A REPLACEMENT HAS TO BE LANDED TOO (`_land_fighter`). `_spawn_fighter` freezes every
  machine — collision tiles are cut around bodies and arrive after the spawn, so an unfrozen one
  sinks — and the only thing that ever unfroze them was `_reseat_fighters`, called exactly twice:
  at round open and at the hop. A machine born mid-fight went through neither and hung at its drop
  height, frozen, for the rest of the round. It waits for ground UNDER ITSELF (a ray on layer 1),
  not for the map's tile count: it lands `START_GAP` (34 m) from the survivor, well outside that
  machine's collision corridor, so a map with dozens of tiles can still have none under it. The reset REMOVES EVERYTHING FIRST and adds the new round a frame later, or machines
  spawn onto collision that is about to vanish. A map being freed is taken off generation first
  (`map.stop_generation`): its worker rows write into buffers that live in the node.
  Collision on a prepared map stays OFF until it is the visible one
  (`map.set_collision_streaming`), or two heightfields fight over the same bodies. Camera height is
  measured FROM THE GROUND under its look point and kept clear of whatever is under the eye: a fixed
  altitude put it inside a hill, which reads as a white screen with stray polygons.
- The menu has its OWN loading screen, `%Backdrop` (`menu_backdrop.gd` + `.gdshader`) on a
  CanvasLayer BELOW the UI: it hides the 3D stage while the ground is computed and leaves PLAY, the
  slots and the settings working. It also covers the round swap, and stays up permanently when the
  fight is switched off (`G.menu_battles`, in the settings; `stage.set_battles` takes it up at
  once). Its look is a survey chart of the same value noise the terrain is built from — deliberately
  not `loading_screen.gd`'s glitch language. A canvas shader must end with `COLOR.a`, not `1.0`, or
  it throws away the modulate the fade is made of.
- A generated menu map AUDITIONS seeds (`_score_seed`): biome masks only, no heights. A 256 m window
  dropped at random lands inside one region, and canyon on the fringe or over desert carves
  scratches a couple of metres deep — the preset was never the problem. Scoring wants canyon over
  MEADOW, some mountain, and a clear middle for the fight.

### Input

- All tap parsing is in `vehicle_body_3d._input`; swipe is separated from tap, `_tap_over_ui` guards
  against taps through the HUD, and a double tap that fired is swallowed.
- Building on another of your machines is delegated to that machine (`_delegate_build`) — there is
  no second build implementation. Only the active machine delegates; hand flags move with the tap.
- THE CONFIRMING TAP RE-AIMS. Placing reads `_preview_res` and `BuildingBlock`, i.e. what the LAST
  aiming pass left; on a phone the confirmation is the second tap of a double, the finger has moved,
  and a delegate machine may have had no aiming pass that frame at all. So `_commit_build_tap` aims
  again at its own tap position before placing.
- A REFUSED PLACEMENT SAYS WHY. Silent `return` reads exactly like "I missed": the ghost is still
  on the cell, the block is still in hand, and closing the garage then returns it to the inventory —
  from the outside that is "the block I placed vanished".
- PICKING A BLOCK UP OFF THE GROUND OPENS ASSEMBLY, AND THAT IS A SETTING (`G.build_on_pickup`,
  in the garage settings under BUILDING), not a rule. The block has nowhere to go but onto a
  machine, so for one player the mode switch is a tap saved; for another, who collects scrap on
  the way without meaning to build anything, it is being thrown out of driving every time. The
  door is single — `vehicle_body_3d._grab_world_block`. Taking a block OUT OF THE INVENTORY is not
  under the setting: that already happens inside the assembly screen.
- WHAT IS IN THE HAND IS `hand_node()`. `block_body` is the block being AIMED AT on a machine, and
  it is already counted by whoever counts machines. Asking `block_body` for "does the player have
  this block" made a block in the hand belong to nobody — the energy branch dropped a second panel
  every second while the player carried the first one to the support.
- `PhysicsRayQueryParameters3D.exclude` takes RIDs, not nodes.
- A TOUCH RELEASE IS RECORDED BEFORE EVERY GATE (`camera_controller._unhandled_input`). A press may
  be skipped — "not my finger" — but a release means one thing only, "the finger left the glass",
  and that is true whatever gate is up. The `G.ui_grab` early return used to sit first, and the UI
  raises that flag MID-GESTURE: a long press on a machine or a hold on the icon opens the radial
  menu while the finger is still down. The release never reached the camera, the index stayed in
  `_cam_touches` forever, and the next SINGLE-finger swipe was read as the second finger of a
  pinch — the player turned the view and got zoom. Raising `ui_grab` also clears the set outright:
  a finger that went off into someone else's handler may never report a release at all.

### Economy

- Every price follows from `G.METAL_PRICE`: ore is 0.4 of its ingot, a component is the recipe sum
  times `CRAFT_MARKUP`, a shop block is material value times `SHOP_MARKUP`.
- `SHOP_MARKUP` > 1 is the rule that keeps crafting worth doing.
- Shop sales are discounts only, on unlocked blocks only, applied by `shop_price_now`;
  `shop_price` stays the base because machine value is measured with it.

### Look and light

- THE RENDERER IS COMPATIBILITY (`gl_compatibility`, both desktop and mobile), picked for FPS, and
  that decides what is even available: no SSAO, no SSR, no SDFGI, no volumetric fog. GLOW, DEPTH
  FOG and TONEMAPPING all work there in 4.6, and those three are the whole post-processing budget.
- **GLOW AND FOG ARE OFF, AND THE REASON IS A MEASUREMENT ON THE DEVICE: 23 fps clean, 18-20 with
  glow, 13 with fog on top.** That is 43% of the frame rate for two settings, on a phone that only
  had 23 fps to give. Both were tried and both came back out. The effect language WAS written for
  glow — every glitch card ends `EMISSION = col * 2.0`, the matrix digits burn above 1.0, the
  laser fakes its muzzle with an emissive sphere — and it all clamps to white without it. That is
  a real loss and it is still not worth 10 fps. If glow ever comes back it has to be a GRAPHICS
  SETTING that is OFF by default, not a scene value, and the thing to fix first is the 23.
  Headless cannot see any of this: only the phone can.
- `tonemap_mode` HAS TO BE SET, not just its contrast. `tonemap_agx_contrast = 1.7` sat in both
  scenes while `tonemap_mode` stayed at its default Linear, so the number did nothing and
  highlights clipped flat. AgX is **4** in that enum (Linear, Reinhard, Filmic, ACES, AgX).
- If fog is ever retried: depth fog reads `fog_density` as a CEILING, not as a rate — the shader
  is `pow(smoothstep(begin, end, z), curve) * density`, so the default 0.01 with `fog_mode` Depth
  gives one per cent fog and looks like fog that does not work. It did NOT buy frames by hiding
  the far edge, which was the hope; it cost five to seven.
- REAL LIGHT IS A POOL OF SIX LAMPS AND NOTHING ELSE (`BlockFX.flash`). Besides the directional
  sun those are the only `OmniLight3D` in the game, and they are REUSED: a new flash takes the
  oldest lamp, so a firefight costs six nodes rather than one per shot. Shadows are off on all of
  them, and past `FLASH_DIST` (110 m) a flash is not lit at all — it lives a tenth of a second and
  nobody sees it across the map. A flash with no scene falls back to the tree root: an empty
  `current_scene` used to mean no light at all, and that fails SILENTLY — the effect does not
  crash, it simply never appears.
- THE MUZZLE IS `Pivot/Marker3D` AND NOTHING ELSE. `_muzzle_point` used to prefer `DrillBody2`,
  which is the barrel MESH: its origin sits in the middle of the turret. The shotgun, the mortar
  and the heavy cannon are the only three that carry that node, so those three spawned their round
  0.561 m from the real muzzle — inside their own body — and lit the flash there too, while the
  gun, the laser and the rocket launcher fired correctly. The difference between weapons read as
  random. Measured on the real driver against the models.
- A MUZZLE FLASH GROWS AND SITS IN FRONT OF THE BARREL. The cone was pointed the wrong way (tip
  away from the gun), CENTRED on the muzzle so half of it lived inside the barrel, and it
  SHRANK over its life — wide and short to narrow and long, the opposite of what gas does. It now
  has its tip in the muzzle, flares forward, and widens as it fades (`BlockFX.MUZZLE_R0/L0/R1/L1`).
- THE DOOR FOR A MUZZLE FLASH IS `WeaponBlock._handle_fire`, NOT `fire_bullet`. The shotgun calls
  `fire_bullet` once per pellet, eight times a shot, and the mortar overrides it without calling
  `super` at all. `_handle_fire` sees every weapon exactly once per shot. Blast light goes in
  `BlockFX.blast_cards`, the single door every explosion already passes through. Flash colour is a
  VARIABLE (`flash_color`), set by a subclass in `_ready` like `yaw_limit` and `spread_deg`.
- **NEVER PUT AN `instance uniform` ON A TERRAIN CHUNK — OR ON ANYTHING THERE ARE MANY OF.** One
  `MeshInstance3D` that uses instance uniforms allocates `MAX_INSTANCE_UNIFORM_INDICES` = **16**
  slots out of the global shader uniform buffer, no matter how many variables the shader declares
  (one is enough to pay 16). The phone reports a ceiling of 4096 items, so the whole game gets
  **256 such objects**, against a terrain that holds up to `LIVE_CAP` = 420 live chunks. Past that
  the allocation fails, returns -1, and the instance reads someone else's slot — which on the
  device looked like a matrix effect flickering across the entire map, not like a broken effect on
  one chunk. Raising `rendering/limits/global_shader_variables/buffer_size` does not help: the
  4096 is the hardware's, not the setting's. Per-chunk values have to travel some other way —
  vertex data, or a shared uniform plus something already in the mesh.
- **A NORMAL MAP DOES NOTHING ON THESE BLOCKS, AND IT IS NOT A SETTING AWAY.** Measured on the
  real driver, one block rendered with and without one: the shipped material is `shading_mode = 0`
  (UNSHADED), and the difference is **0.000** — an unshaded material never samples a normal map,
  because it never lights anything. Switching that material to PER_PIXEL is still not enough:
  `force_vertex_shading` computes lighting per VERTEX, so the difference stays at 0.102, which is
  rounding. Only with BOTH changed does the map reach the frame, and then it is 1.66 (3.94 at
  `normal_scale` 3) — visible on an edge, small. The cost of getting there is the whole look:
  unshaded against per-pixel is a 13.5 difference on the same block, i.e. the flat, bright,
  reads-on-a-phone style the game is drawn in, traded for real lighting, plus the frames that
  lighting costs on a device that measured 23 fps clean.
  WHICH IS WHY THE SHADING IS PAINTED INTO THE TEXTURE. `art/bake_normal.py` does that from a
  normal map: it lights the map against a fixed tangent-space direction and multiplies the
  DIFFERENCE from flat into the albedo atlas, so the 96% of the map that is flat leaves the
  texture byte for byte unchanged and only the bevels get their lip. Free at runtime, no setting
  moved, no art direction changed. `objects/Assets_main_texture_new_normal.png` is the map the
  atlas was baked from; it is kept as the SOURCE for that tool, not as something the game loads.
- Two settings in `project.godot` flatten the picture on purpose, and both are speed:
  `shading/overrides/force_vertex_shading` (lighting per vertex, so no per-pixel specular) and
  `scaling_3d/scale = 0.75` (the 3D image is rendered at three quarters and upscaled).
- **Headless cannot judge any of this.** The dummy driver draws nothing, so these numbers are set
  by reading the shader and the docs; only the device settles them. A shader's SHAPE, though, can
  be seen — see §3 "Shaders need a REAL driver".
- **`EMISSION` DOES NOTHING UNDER `render_mode unshaded` IN COMPATIBILITY.** Measured on the real
  driver: albedo 0.2 alone reads 0.498, emission 0.8 alone reads 0.302, and the two TOGETHER read
  0.498 — the same as albedo by itself. So every brightness multiplier written onto `EMISSION` in
  an unshaded shader was decoration; the colour that reaches the frame is `ALBEDO`. That is where
  the shield's "why is it so dim whatever I do" came from. `glitch_card.gdshader` still ends
  `EMISSION = col * 2.0` and is unshaded — its cards are running at plain `ALBEDO` brightness.
- A HEXAGONAL SHIELD IS GEOMETRY, NOT A PATTERN (`shield_hex.gd`). Painting a grid onto a sphere
  fails for a reason that is not about settings: sphere UV winds the lines into spirals at the
  poles, a cube-face projection has no poles but stretches the cell toward the silhouette, and a
  uniform hexagonal MARKING of a sphere does not exist at all. A hexagonal SOLID does — the
  Goldberg polyhedron, dual of a geodesic sphere: 10·sub²+2 cells, twelve of them pentagons, the
  rest equal hexagons (sub 3 → 92 cells, 540 triangles, built once and shared by every shield).
  Each cell carries its own centre direction and random number in the vertex COLOR and its
  distance-to-edge in UV, so the shader has no hash, no `mod` and no `atan` left, and lighting ONE
  cell on a hit is an exact comparison rather than a distance on the sphere.
- A DRAINING DOME KEEPS ITS PLATES AROUND THE LAST HIT, so the shield says where it is being
  worked on. Dropping them by their own random number was stable but told the player nothing —
  the dome thinned evenly, including on the side nobody was shooting at. The cap never empties:
  `keep_cos` comes from `shield.gd`, computed per hit cell against the real plate centres so at
  least KEEP_MIN (7) survive — the struck plate and its whole ring. One number for the whole dome
  cannot do that: twelve of the 92 cells are pentagons with five neighbours, and across the entire
  0.80–0.90 threshold plateau the minimum sits at six (measured).
- CHARGE DRIVES THE CAP'S RADIUS ON SCREEN, not its cosine and not its angle. The dome is seen as
  a DISC, and a cap of half-angle θ takes up sin θ of it. Running the threshold linearly in cosine
  spent half the scale on the far hemisphere, which is CULLED — frames at charge 1.0 and 0.6 came
  out identical to the pixel. Stopping at the near hemisphere was better and still wasted the top
  of the scale on the silhouette ring, which is seen edge-on and weighs nothing. Underneath the cap
  the old uniform gate stays and carries the middle of the scale: 92 plates sit in rings around any
  chosen one, so the cap itself grows in jumps of 7 → 13 → 22.
- GODOT'S FRONT FACE IS THE CLOCKWISE ONE, seen from outside — the opposite of the right-hand
  rule most mesh-building code reaches for. A code-built mesh with the intuitive winding renders
  inside-out, and then `FRONT_FACING` answers backwards and `NORMAL` comes through flipped: the
  near hemisphere was being dimmed as if it were the far one. Neither built-in is safe on such a
  mesh — near or far is `dot(outward_direction, direction_to_camera)` computed from `VERTEX` and
  `CAMERA_POSITION_WORLD`, which owes nothing to any convention. With back-face culling on, a
  wrong winding is loud instead of silent: the mesh simply does not draw.
- AN EFFECT THAT PLAYS WHEN NOTHING HAPPENED IS NOISE. The shield glitched a share of its plates
  at all times, so it rippled while nobody was shooting at it. Anything that says "I was hit"
  hangs off the hit value, and putting it behind `if (hit > 0.001)` costs nothing the rest of the
  time: it is a uniform, so the branch is coherent across the whole surface.
- A FULL-SCREEN TRANSPARENT SPHERE IS EXPENSIVE, AND `cull_disabled` PAYS FOR IT TWICE. Both the
  dome and the repair field were such spheres with hashes in every pixel. The repair field is now
  a MultiMesh of a dozen billboard cards — one draw call, no fragment cost worth the name — and
  the dome culls its back faces outright: half the fragments, no lattice added on top of itself,
  and the near/far question gone. The cost is that the dome is invisible from inside it, which at
  a four-metre radius the camera almost never is.
- THE REPAIR FIELD'S DIGITS RIDE PARALLELS OF A SPHERE, one height per digit, and the height comes
  from the INSTANCE NUMBER (`(i + 0.5) / N`), never from a roll. A random orbit axis per digit was
  the obvious thing and it produced none of what was wanted: random axes pile the cloud toward the
  middle, the circles cross at arbitrary angles and read as debris rather than an orbit, and the
  visible arc was a fixed slice of each lap — half the digits only ever appeared on the low part
  of it, which is what "they are all at block level or below" was. Random LATITUDE has the same
  flaw in miniature: over thirty digits it will leave a hole at the crown and a clot at the waist.
  Ninety cards at 0.2 carry LESS ink than thirty at 0.4 (3.6 against 4.8) while actually
  outlining `REGEN_RADIUS`, which is the one thing the field exists to say — thirty still drew
  that outline as a dotted line. A MultiMesh bills for pixels, not for instances.
- A REPAIR BOLT LEAVES THE CLOUD, NOT THE BLOCK, and there is ONE per block healed
  (`BlockFX.repair_stream`). It started at the regen's own centre with half a metre of scatter
  against a 4.6 m field, so it read as a line the block draws to its target — but it is the FIELD
  that repairs. The start is now a random point on the same shell the shader puts the digits on
  (0.82–1.0 of the radius), in the hemisphere facing the target so the glyph does not fly through
  the whole machine. WHICH digit is never asked: their orbits are computed in the shader from
  `TIME`, and repeating that on the game side would be a second copy of the formula that drifts
  silently. Three bolts per block turned a dense build into a flash; one per target means the
  number of lines IS the number of blocks under repair.

### Performance

- Engine occlusion culling is off (no baked occluders); the terrain does horizon culling itself and
  compares slopes rather than angles.
- Seam rebuilds run on a budget per pass; a hairline crack beats a frame drop.
- Whole-machine frustum culling toggles `visible` only — `process_mode` belongs to the sleep system.
- A WALLED-IN BLOCK IS NOT DRAWN (`blocks._apply_occlusion`), and "walled in" is decided by a FLOOD
  FILL FROM OUTSIDE, not by counting six neighbours: a neighbour may be a part that does not fill
  its cell (wheel, belt, barrel, half-block), and you see straight through it. `VehicleBlock.
  solid_cell` is that flag, default **false** — a wrong "no" costs one drawn cube, a wrong "yes" is
  a hole in the hull. A block leaving the machine (torn off, taken, scattered) is made visible
  again at the single door it leaves through.
- For a loose item, drawing and script are decided separately: off-frame drawing is pointless, but
  a script gated by the frustum would stall the factory whenever the camera turns.
- Settled loose bodies are put to sleep so they stop asking terrain for a collision window.
- **A BULLET'S TICK IS MOSTLY NOT THE RAYCAST.** Measured on the engine, 200 bullets, one physics
  tick: raycast with a fresh `PhysicsRayQueryParameters3D.create` 1224 us, the same raycast reusing
  one object 744 us, `Basis.looking_at` + `global_basis` 466 us, the child walk `_mesh_node` did per
  tick 415 us, the position write 222 us, the two `Perf` marks 345 us — 2672 us in total, of which
  the physics is 744. So the allocation cost more than a quarter of the "bullets" line and the mesh
  search nearly as much; both are now done once per bullet rather than once per tick, and the sweep
  was checked to behave identically (same hit at 3 m, same miss at 15 and 40 on a flat-aimed test,
  before and after). Anything that claims to speed bullets up has to move those numbers — and a
  move to MultiMesh would remove the node costs but NOT the 744 us, which is the part that decides
  whether a shot lands.
- A BULLET FLIES WITH `monitoring` OFF. `body_entered` and the sweep's `hit` land in the SAME
  handler, so the Area was a second path to one answer, and the physics server was computing
  overlaps for every bullet in the air every tick to provide it. What it could add over the sweep
  is a hit at zero metres, which the sweep's first segment already covers.
- **MEASURE A PHYSICS COST BY ALTERNATING, NEVER BY ONE PASS.** A single before/after of that same
  flag read 48 ms against 2 — and it was an artefact: chunk streaming was still running and landed
  in `TIME_PHYSICS_PROCESS`. Alternating OFF/ON six times over the same 200 nodes gave
  18.2 / 18.7 / 17.7 / 19.6 / 21.0, i.e. about 2 ms, with the first sample of the run an outlier
  in both directions. Also never time a tick with `await physics_frame` around it: that waits for
  the next tick and always returns 1/60 s, however much work the tick did. Ask
  `Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS)`.
- A TURRET'S AIM RAY IS NOT `enabled`. `RayCast3D` defaults to on, so the engine updated it every
  physics tick for every weapon in the world, and the tick called `force_raycast_update()` on top —
  two physics queries per weapon per tick. Its result is read by exactly two things: the "is my own
  barrel blocked" check, which is needed once per SHOT, and the tracer beam, which needs it every
  tick and exists on three of the six weapons (mortar, heavy cannon, shotgun). So the ray is forced
  where the answer is used. The blocked check moved AFTER the fire timer and does not reset it on
  refusal, so a weapon still fires on the first tick the obstruction clears.
- **A FIGHT IS TOO NOISY TO JUDGE FROM ONE RUN.** The same 15-second fight, damage dealt: 120 / 135
  / 129 before a change and 134 / 235 / 186 after. A single pair would have "proved" either a 36%
  regression or a 55% improvement depending on which two samples you took. Three runs a side, and
  read the band, not the number.
- A TURRET'S TARGET LIST IS PRUNED WHERE IT IS READ (`WeaponBlock._update_current_target`):
  `body_exited` never fires for a destroyed block — the body vanishes rather than leaves — so
  without that the list grew to everything that ever entered the sphere, and scoring walked those
  dead references every tick. Scoring itself runs at `RETARGET_PERIOD`, not per frame (`SC_STICKY`
  holds the choice anyway), and a turret that has reached neutral stops ticking until it fires
  again.
- Anything behind the camera and past the near bubble is disabled; the near bubble stays active in
  every direction. Radar reads vein data, not what is drawn.

## 3. Running it

There is no Godot in a fresh container and **it cannot be downloaded**: the egress proxy answers
403 for godotengine.org and for `github.com/.../releases/download`. What it does allow is `git
clone` of any GitHub repository and the Ubuntu archive — so the engine is BUILT, once, in about
sixteen minutes on four cores:

```sh
apt-get install -y --no-install-recommends scons pkg-config build-essential \
  libx11-dev libxcursor-dev libxinerama-dev libxi-dev libxrandr-dev libxext-dev libxrender-dev \
  libgl1-mesa-dev libglu1-mesa-dev libasound2-dev libpulse-dev libudev-dev libdbus-1-dev \
  libspeechd-dev libwayland-dev wayland-protocols libxkbcommon-dev
git clone --depth 1 -b 4.6.3-stable https://github.com/godotengine/godot.git /tmp/godot
cd /tmp/godot && scons platform=linuxbsd target=editor optimize=none debug_symbols=no lto=none \
  module_text_server_adv_enabled=no module_text_server_fb_enabled=yes \
  module_raycast_enabled=no module_lightmapper_rd_enabled=no \
  module_openxr_enabled=no module_webxr_enabled=no module_mobile_vr_enabled=no \
  module_webrtc_enabled=no module_websocket_enabled=no module_camera_enabled=no -j4
# -> /tmp/godot/bin/godot.linuxbsd.editor.x86_64
```

`optimize=none` is for COMPILE time, not run time; the disabled modules are the expensive ones the
project never touches. Jolt, GDScript, 3D and glTF stay — the game stands on them. The tag must
match `config/features` in `project.godot`.

**RUN IT ON A COPY, NEVER ON THE REPO.** Importing rewrites tracked files: my headless build writes
`.import` files without the `etc2_astc` variant (mobile textures), re-serialises every `.res` cut
from a `.glb`, and reorders keys in `project.godot`. Committing that breaks mobile texture import
for real. So:

```sh
rm -rf /tmp/ttrun && mkdir /tmp/ttrun
tar -cf - --exclude=.git --exclude=.godot -C /path/to/repo . | tar -xf - -C /tmp/ttrun
G=/tmp/godot/bin/godot.linuxbsd.editor.x86_64
$G --headless --path /tmp/ttrun --import                    # first, or nothing resolves
$G --headless --path /tmp/ttrun --script res://_selftest.gd # every script + every scene
$G --headless --path /tmp/ttrun res://node_3d.tscn --quit-after 12000   # boot the world
```

`_selftest.gd` (a `SceneTree` script, kept in the run copy, not in the repo) walks the project,
`load()`s every `.gd` and instantiates every `.tscn`. **The import must run first** — without
`.godot/` every scene that touches a model or a font fails with "Can't load dependency", which
looks exactly like a broken scene and is not one.

Do NOT use `--check-only --script file.gd` for a sweep: autoloads are not registered in that mode,
so every file that mentions `G` or `Q` reports "Identifier not found" — a hundred false positives
and nothing else.

### Shaders need a REAL driver, and there is one

**Headless never compiles a shader.** The dummy driver parses nothing, so a broken `.gdshader`
loads without a word and ships; on the phone it shows as a pink or invisible surface. Measured:
a shader whose body is `ALBEDO = vec3(zzz)` loads clean under `--headless`.

Xvfb and Mesa are installed, so the engine can run with the real GLES3 driver on llvmpipe:

```sh
xvfb-run -a -s "-screen 0 700x700x24" $G --path /tmp/ttrun \
  --rendering-driver opengl3 --resolution 700x700 --script res://_shot.gd
```

There the shader is compiled and an error is printed with its line. **And the frame is really
drawn**, so `get_viewport().get_texture().get_image().save_png("user://x.png")` after
`await RenderingServer.frame_post_draw` gives a PICTURE of the effect to look at. Two traps in
such a harness: the frame is cleared to WHITE, and an additive effect on white is invisible —
put a dark sphere behind the scene rather than fighting the clear colour; and llvmpipe is slow,
so keep it to a handful of frames per shot.

What is still unavailable: the device's frame rate, touch gestures, and how any of it reads on a
real screen. Those stay with the person holding the phone.

## 4. Working with the code

- Check syntax: `gdparse <files>`. It exits non-zero on syntax errors and says nothing useful about
  semantics.
- `vehicle_body_3d.gd` contains `if face: match res.face:`, which `gdparse` cannot parse — check
  that file on a copy with the line split in two and the match arms indented.
- After adding a method call, confirm the node's class actually has it (see rule 2).
- After adding a variable to a long function, confirm it is not already declared above.
- Reading terrain, veins or debug flags from a system that can run without `Main` — go through the
  `G` helpers, not through node paths.
- When behaviour changes, update this file and the matching `docs/` page in the same commit.

## 5. Style and conventions

- Comments and docs are in **English**: the same content costs far fewer tokens than Russian, and
  identifiers are English anyway. Old code is mostly Russian — convert a comment when editing the
  code next to it.
- A comment is a working note: the rule, the number, the trap, why not otherwise. Never restate what
  the line does. History only where the rule looks arbitrary without it.
- Do not duplicate numbers that live in code (prices, radii, timings) — name the constant instead.
- Bold for hard prohibitions; no shouting.

## 6. Where to look next

- `docs/README.md` — index of the per-system notes.
- `docs/STORY_ROADMAP.md` — story plan (TerraTech GSO skeleton on our mechanics: no shops, no
  trading stations, selling is a block on a machine).
- `docs/QUESTS_DESIGN.md`, `docs/PROGRESSION_DESIGN.md` — quest and progression design.
- `docs/BLOCKS_TODO.md`, `docs/STATIONARY_BLOCKS_DESIGN.md`, `docs/ROCKET_BLOCK.md`,
  `docs/PROPS_HOWTO.md` — blocks and world props.
- `docs/CANYON_TERRAIN.md` — terrain generation detail.
- `docs/PROVING_GROUND.md` — the proving ground: flat ground, spawning any build, what switches what.
