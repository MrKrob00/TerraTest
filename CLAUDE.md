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
    value kept plus a same-size entry in `RETIRED_BLOCKS`.
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
- A weapon that bends its shot after firing (shotgun spread, mortar arc) uses
  `WeaponBlock.last_fired`. "The last child of Ammo that is in flight" is only correct while the
  pool is empty; afterwards bullets come out of it in any order.
- `_alert_victim` (weapon side) tells the victim who shot; `hurt()` must not, since drills and
  repair fields call the same `hurt`.

### Energy

- Charge lives in the batteries themselves (`battery.gd`); the machine only sums and draws. It
  travels with the block and survives saving (`blocks.charge_map`). Only the solar buffer belongs to
  the machine and exists while anchored.
- Enemy energy is real: tower panels, battery and shield all work, which is the way into a shielded
  tower. Every enemy ticks it, driving machines included — they carry domes and repair fields too.

### Enemies

- `enemy_spawner.gd`: two awake at a time, one engaging, everyone drops in from `drop_height`. The
  inner ring radius is computed from enemy vision plus `spawn_safe_margin`, never hardcoded.
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
- THE LADDER IS TWO TABLES AND NOTHING ELSE: `enemy_spawner.PRESET_TIERS` (a step per line, 3-4
  builds per step) and `blocks.ENEMY_BUILDS` (what each build is — rows, wheel, width, deck, top).
  A new machine is a table row plus its number in `_define_layout`, never another `_layout_` method.
  Several builds per step is the point: one machine per step means one silhouette, one memorised
  answer, and the whole grade is solved. The variant is rolled on every spawn.
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
- THE ENGAGEMENT CAP DECIDES WHO STARTS A FIGHT, NOT WHO ANSWERS ONE. `combat_allowed` (the
  spawner's queue) kept a shot-at enemy silent while it stood second in line — the player emptied a
  gun into a machine that never fired back. `notice_attacker` now lifts it for `ANSWER_TIME`, and
  the spawner leaves such an enemy out of the queue while that runs.
- Acquisition has two paths (area signal, periodic search) and both must go through
  `_consider_target`, which holds the line-of-sight rule. Escape is possible: no chase bonus, and a
  damaged enemy that breaks contact gives up and moves its patrol home.
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

### UI

- The scene holds what stands still (frame, padding, style, nesting); code holds what changes (text,
  visibility, edge layout, anything built from data). Code fetches nodes by unique name.
- Icons are `_draw()` classes with no node representation.
- The garage CODEX tab is built from the same tables the game runs on (`G.Block`, `METAL_NAME`,
  `COMP_NAME`): a hand-written second catalogue would fall one block behind and say nothing about
  it. It has THREE kinds. Blocks are ordered BY GRADE and filtered by the SHOP's own category
  list (`_passes_filter`, `G.BLOCK_CATEGORIES`) — enum order is the history of edits, not the
  shape of the game, and a second category list would drift from the first. Resources are the
  flat list. CHAIN is a GRAPH on the same canvas the tech tree uses (`TechGraph`): columns for
  raw, ingots, simple and complex, with real edges from `G.COMP_PARENT`. Every component has
  EXACTLY TWO parents, and only lines show that; a stage list with an arrow showed the order and
  hid the dependency. Block text lives in `G.BLOCK_DESC` — one sentence about what the part DOES,
  never numbers, which move; a component's text is derived from its recipe, never typed out.
- MUSIC CONTROLS ARE ONE PANEL, `music_panel.gd`, used by the garage tab and by the main-menu
  settings; the only difference is WHICH context lists it is given. The menu shows its own,
  the garage the two the world plays. The MENU context itself is set by `menu.gd` while that
  scene is up and cleared when it leaves — the flag sat in the manager unused for months and
  `music/menu/` never played once, because the autoload outlives the scene and nobody owned the
  switch. Turning music off is `set_enabled`, not volume zero, which forgets the level.
- `CanvasLayer` child order is draw order — bound panels are lifted to the end (`hud._lift`).
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
  is born). The reset REMOVES EVERYTHING FIRST and adds the new round a frame later, or machines
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
- WHAT IS IN THE HAND IS `hand_node()`. `block_body` is the block being AIMED AT on a machine, and
  it is already counted by whoever counts machines. Asking `block_body` for "does the player have
  this block" made a block in the hand belong to nobody — the energy branch dropped a second panel
  every second while the player carried the first one to the support.
- `PhysicsRayQueryParameters3D.exclude` takes RIDs, not nodes.

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
