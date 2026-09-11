# TerraTest — CLAUDE.md

Mobile game about machines built from blocks. Godot 4.6, GDScript. This file is the map of the
project: read it before claiming how anything works.

## 0. Critical rules

1. The game cannot be run here. `gdparse` checks syntax only; everything else is verified by
   reading the code.
2. `gdparse` does not see a **redeclared variable** or a **call to a method the node lacks**. Both
   are Parse Errors in Godot, and a Parse Error means the whole script does not load.
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
    The font renders emoji as empty boxes.
12. Never set position or size on a **container child** — the container overwrites it. Only nodes
    directly under a `CanvasLayer` are positioned from code.
13. Compare distances with `distance_squared_to()`; the square root is only for formulas.
14. Terrain height is asked through `G.ground_y(point, fallback)` — raw `terrain_height_at` returns
    zero before the heightmap is read.
15. Saves store blocks by **enum name**: renaming needs `LEGACY_BLOCK_KEYS`, removal needs the enum
    value kept plus a same-size entry in `RETIRED_BLOCKS`.
16. Biome masks are computed in exactly one place, `TerrainBiomes` — the value noise under them
    too (`TerrainBiomes.cv_noise`, handed to the masks as `biomes.noise`). A second copy of the
    formula diverged once and moved a whole region.
17. A loose item is put to sleep with `sleeping`, never `freeze`: `G.is_loose_item` checks `freeze`,
    and a frozen item stops being pickable.
18. `user://` heights override packaged ones, so a regenerated map needs a fresh save; a procedural
    world never bakes a dump at all.

## 1. Project skeleton

- Autoloads: `G` (progress, prices, block metadata), `Dialogue`, `Music`, `Q` (quests), `MobileAds`.
- Main scene is `menu.tscn`: the slot is chosen before map, machines and veins read any file.
- World root `/root/Main`: `map` (LiteTerrain + veins + props), `Vehicles`, `objects` (loose blocks
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
- Block tinting goes through a separate shell: model materials are shared between instances.
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
  the tier is rolled under it. `preset_tiers` is ordered by danger. Kill reward is measured once at
  birth.
- THE CEILING IS ONE FUNCTION, `_tier_cap`, and everything that asks for an enemy goes through it —
  including a quest event, which names presets but gets them through `preset_for_request`. An event
  repeats and meets the player in any state, the state right after being taken apart included:
  without this, losing at grade 5 sent the same siege machine at the starter cabin that replaced
  the machine. It only ever lowers, and a preset outside the ladder (towers, bases, story carriers)
  is left alone — there the build is part of the task.
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
- Acquisition has two paths (area signal, periodic search) and both must go through
  `_consider_target`, which holds the line-of-sight rule. Escape is possible: no chase bonus, and a
  damaged enemy that breaks contact gives up and moves its patrol home.
- Fortified points (`outposts.gd`) are the only things placed on the map instead of around the
  player: constant seed, cleared stays cleared, saves store indices only.

### Terrain (LiteTerrain, third-party addon we patched)

- The ground is drawn three ways at once — chunk meshes, the merged macro mesh, and coarse quadtree
  node meshes — and all three are stitched through one answer, `_drawn_step_at`. Seam signatures are
  eight bits per field; four overflowed.
- No skirts on seams, ever. Edges meet because every step is a power of two on one grid, and the
  chunk is restitched in the same pass the coarse mesh appeared.
- Generation and rebuilds are threaded (`WorkerThreadPool`, one task per row or chunk): a thread
  writes only its own slice, reads only immutable data, never touches the tree.
- Flat areas merge into big quads built from rectangles; the merge ceiling is chunk size, the outer
  ring never merges, and the merge perimeter carries `no_grass`.
- The mesh may know more than physics: ripples and rock roughness are baked into near chunks only,
  zero at chunk edges, as a function of world position and biome.
- Layers must not eat each other: metre values derive from `Height`, and dampening a layer by a mask
  makes a step exactly as tall as what it removes — the canyon cuts finished ground instead.
- The generator NEVER writes into the biome resource except `mask_offset`. The resource is an input;
  metres that depend on Height (the snow line) are held there as a SHARE and multiplied by
  `map.world_height()` when the materials are built. A generation pass that edits an authored field
  is a slider that moves back, a scene diff per run, and a value that is right for one map only.
- The Height a map was built with is recorded on the terrain node (`map.built_amplitude`, written by
  the dock) — the heights on disk are bare metres and the dock's settings live in editor metadata,
  which does not ship. Procedural worlds know it from their own params; anything else falls back to
  the map's own peak over `PEAK_OVER_HEIGHT`.
- Heights are read in a strict order: `user://` override → the node's `heightmap_path` basename
  + `.bin` → that `.res`.
- The generator cancels itself on `NOTIFICATION_EXIT_TREE`/`PREDELETE`, and a map does the same for
  its own (`map._exit_tree` → `stop_generation`). A scene change or a freed map otherwise leaves
  worker rows writing into destroyed buffers — an "Out of bounds set index" from nowhere.
- EVERY terrain node owns its heightmap file (`res://terrain/<scene>_<node>.res`, given out by
  `plugin._new_heightmap_path`). The old default pointed every node at the addon's one file, and
  creating or generating a terrain in one scene erased another scene's map — two scenes, one map.
  Generating or baking moves a node still on that default onto its own file and says so.
- A world can also be **procedural**: `md` is a window that follows the player, the generator
  computes only the new strip, and chunk meshes plus collision tiles are re-indexed. "World point →
  cell" lives in `_cell_ox`/`_cell_oz` only.
- `window_margin` is clamped to `(window − step) / 2` per axis: a bigger one puts the point in the
  opposite forbidden zone right after the shift, and the window ping-pongs every frame (a 256-cell
  window with the exported 192 recomputed a strip forever).
- Generation defaults live in `LiteTerrainGen.DEF_*`; the map's exports read from there so the menu
  and the window generator cannot diverge (a divergence is a visible seam).

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
- `G.world_seed` drives everything laid out randomly (veins, outposts, props); each consumer has its
  own RNG and seed offset. `world_procedural` is stored in the world file, not derived from the slot
  index.
- Slot 1 is the file-based "original" map and absorbs the pre-slot save once, by renaming.
- The menu computes a new slot's world with a progress bar, remaining-time estimate and Stop, then
  hands it over through `G.pending_world` plus a disk cache keyed by seed and size.
- Resetting or deleting a world lives in the MENU, next to the slots (reset keeps the map, delete is
  hold-to-confirm). The in-game settings have no wipe button: one tap, irreversible, among sliders.
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
- `CanvasLayer` child order is draw order — bound panels are lifted to the end (`hud._lift`).
- LANGUAGE: en / ru / uk, picked in the menu settings (`G.set_lang`, kept in `settings.json`, empty
  means follow the system). The KEY IS THE ENGLISH STRING ITSELF (`i18n/strings.json`, loaded into
  `TranslationServer` by `G._load_translations`): a string starts being translated the moment its
  row appears, an unwrapped one keeps working, so the pass can go in slices. Scene text translates
  itself; text set from code needs `tr()`. Translated so far: menu, slots, world creation, settings,
  the radial menu, the death screen, the menu backdrop. NOT yet: quest texts, Mechanic lines, block
  names and descriptions, the garage and the shop.
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
  same thing is a second button in a crowded corner. The icon shows within `VBTN_SHOW_DIST` (60 m),
  which is what makes a base left at a vein or a quest site reachable at all.
- Menu backdrop is a REAL fight. The FIRST map is the one authored in `menu.tscn`
  (`Stage/LiteTerrain`, a baked heightmap made with the plugin) so the menu opens on a world instead
  of on sky;
  it carries `follow_world_settings = false`, or G would hand it the save slot's procedural seed.
  Every map after it is generated: a 256-cell procedural LiteTerrain map on the dock's Natural
  preset (`LiteTerrainGen.natural_params`, the single copy of those numbers) with streamed collision
  and two enemy machines of DIFFERENT factions, with their own physics, AI and weapons. Demo
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
- A generated menu map takes its HEIGHT from the map authored in the scene (`map.world_height`), not
  from the preset: a menu baked at 240 next to rounds generated at the preset's 130 is visibly two
  landscapes.
- A generated menu map AUDITIONS seeds (`_score_seed`): biome masks only, no heights. A 256 m window
  dropped at random lands inside one region, and canyon on the fringe or over desert carves
  scratches a couple of metres deep — the preset was never the problem. Scoring wants canyon over
  MEADOW, some mountain, and a clear middle for the fight.

### Input

- All tap parsing is in `vehicle_body_3d._input`; swipe is separated from tap, `_tap_over_ui` guards
  against taps through the HUD, and a double tap that fired is swallowed.
- Building on another of your machines is delegated to that machine (`_delegate_build`) — there is
  no second build implementation. Only the active machine delegates; hand flags move with the tap.
- `PhysicsRayQueryParameters3D.exclude` takes RIDs, not nodes.

### Economy

- Every price follows from `G.METAL_PRICE`: ore is 0.4 of its ingot, a component is the recipe sum
  times `CRAFT_MARKUP`, a shop block is material value times `SHOP_MARKUP`.
- `SHOP_MARKUP` > 1 is the rule that keeps crafting worth doing.
- Shop sales are discounts only, on unlocked blocks only, applied by `shop_price_now`;
  `shop_price` stays the base because machine value is measured with it.

### Performance

- Engine occlusion culling is off (no baked occluders); the terrain does horizon culling itself and
  compares slopes rather than angles.
- Seam rebuilds run on a budget per pass; a hairline crack beats a frame drop.
- Whole-machine frustum culling toggles `visible` only — `process_mode` belongs to the sleep system.
- For a loose item, drawing and script are decided separately: off-frame drawing is pointless, but
  a script gated by the frustum would stall the factory whenever the camera turns.
- Settled loose bodies are put to sleep so they stop asking terrain for a collision window.
- Anything behind the camera and past the near bubble is disabled; the near bubble stays active in
  every direction. Radar reads vein data, not what is drawn.

## 3. Working with the code

- Check syntax: `gdparse <files>`. It exits non-zero on syntax errors and says nothing useful about
  semantics.
- `vehicle_body_3d.gd` contains `if face: match res.face:`, which `gdparse` cannot parse — check
  that file on a copy with the line split in two and the match arms indented.
- After adding a method call, confirm the node's class actually has it (see rule 2).
- After adding a variable to a long function, confirm it is not already declared above.
- Reading terrain, veins or debug flags from a system that can run without `Main` — go through the
  `G` helpers, not through node paths.
- When behaviour changes, update this file and the matching `docs/` page in the same commit.

## 4. Style and conventions

- Comments and docs are in **English**: the same content costs far fewer tokens than Russian, and
  identifiers are English anyway. Old code is mostly Russian — convert a comment when editing the
  code next to it.
- A comment is a working note: the rule, the number, the trap, why not otherwise. Never restate what
  the line does. History only where the rule looks arbitrary without it.
- Do not duplicate numbers that live in code (prices, radii, timings) — name the constant instead.
- Bold for hard prohibitions; no shouting.

## 5. Where to look next

- `docs/README.md` — index of the per-system notes.
- `docs/STORY_ROADMAP.md` — story plan (TerraTech GSO skeleton on our mechanics: no shops, no
  trading stations, selling is a block on a machine).
- `docs/QUESTS_DESIGN.md`, `docs/PROGRESSION_DESIGN.md` — quest and progression design.
- `docs/BLOCKS_TODO.md`, `docs/STATIONARY_BLOCKS_DESIGN.md`, `docs/ROCKET_BLOCK.md`,
  `docs/PROPS_HOWTO.md` — blocks and world props.
- `docs/CANYON_TERRAIN.md` — terrain generation detail.
