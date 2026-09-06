# TerraTest — project map

Mobile game about machines built from blocks (Godot 4.6, GDScript). Read this before claiming
anything about how the game works.

Notes are working memory: rules, numbers, traps. History ("it used to be X and broke") stays only
where the rule looks arbitrary without it and would get broken again.

## Verifying edits

No Godot here — the game cannot be run. Syntax: `gdparse` (`pip install gdtoolkit`). Everything
else: by reading.

- `gdparse` chokes on `if face: match res.face:` in `vehicle_body_3d.gd`. Check on a copy with that
  line split in two (+ one tab for the match arms).
- **It does NOT see redeclarations.** Two `var x` in one scope is fine for it, a Parse Error for
  Godot, and the whole script fails to load. That is how the map vanished: `var _g` twice in
  `map._ready`.
- **It only knows syntax.** No base classes: calling a method the node lacks looks fine to it and is
  a Parse Error in Godot (again: whole script does not load). That is how the HUD (`CanvasLayer`,
  not `Control`) died on `accept_event()` inside a lambda. Swallow input with
  `get_viewport().set_input_as_handled()`. After adding a call, ask WHOSE method it is.
- **No comments in `project.godot`.** Godot rewrites the file and folded a `#` INTO A KEY NAME — the
  setting silently died (that is how engine occlusion came back). The `;` header is the engine's.

## Skeleton

- Autoloads: `G` (progress), `Dialogue`, `Music`, `Q` (quests), `MobileAds`.
- Main scene is `menu.tscn`: the save slot is picked BEFORE map/machines/veins read their files.
- World: `/root/Main` — `map` (LiteTerrain + veins + props), `Vehicles`, `objects` (loose blocks and
  resources), `EnemySpawner`.
- Layout: blocks in `blocks/scenes/*.tscn` + `blocks/scripts/*.gd`; everything else at the root.
- Per-system detail lives in `docs/` (index: `docs/README.md`).

## Machines

`MachineBody` (`machine_body.gd`) is the shared base: driving, suspension, mass, energy, detaching
blocks. Subclasses: `vehicle_body_3d.gd` (player), `enemy_vehicle.gd` (AI).

**The project's main trap.** A mechanic both machines need but that lives in `vehicle_body_3d`
simply DOES NOT EXIST for the enemy — usually silently, because it is called through `has_method()`.
Example: enemy blocks hung in the air because `detach_block_to_world()` existed only on the player.
Before adding anything to `vehicle_body_3d`, ask whether the enemy needs it too.

### Blocks and the grid

`blocks.gd` — the machine's 11³ grid (node `blocks` inside the machine).

- `map[x][y][z]` = block type, coordinates SHIFTED by +5 (centre = 5,5,5).
- Multi-cell blocks (2×2×2) occupy several cells, but node and rotation live on ONE anchor cell;
  `cell_owner["x,y,z"] → "ax,ay,az"`. Always go through `find_block` / `remove_block`.
- `can_attach()` forbids nothing by face. Where a block may attach is the `connect_faces` export
  (the cube widget on `VehicleBlock`); building rotates the block so that face meets the neighbour.
  Empty mask = attaches like factory blocks.
- **Connectivity is BY ATTACH FACES** (`_reachable_cells`), not by touching: an edge exists only if
  the direction is marked on BOTH sides. Otherwise a gun with its support shot out stays floating
  because it grazes something sideways. For blocks larger than one cell a side expands into cells
  (`VehicleBlock.connects_at` + `connect_defaults`); a cell without its own setting falls back to
  the mask.
- **Three roles, not "three inputs".** COLLECTOR only picks resources off the ground and works
  ALWAYS (it is a `VehicleBlock`: no outputs, no `push_item`). RECEIVER is the chain's entry: takes
  materials from the ground and ore from collectors, feeds the belt, ONLY WHILE ANCHORED, on all
  paths at once; it does not pick up loose blocks. PACKER magnetises loose BLOCKS (Area3D with point
  gravity — physics, not code) and packs them into chunks: a full one, or one that sat for
  `flush_delay`, goes to the belt; with no belt it drops into the world.
- **A MACHINE STANDS BESIDE THE BELT, NOT INSIDE A GAP IN IT.** The belt also outputs sideways
  (`output_faces`), but two rules live in `belt.gd` because the mask only knows the side while what
  matters is WHO is on that side. Never hand sideways to another BELT (two lanes are two lines,
  otherwise a two-lane conveyor feeds itself). A non-belt receives BEFORE the next belt does:
  `push_item` round-robins (needed by the splitter), so a side machine would take every second item.
- Area masks decide more than scripts here: collector zone on layer 8 (resources), receiver 24
  (machines + resources), packer magnet 2 (blocks). The packing branch in the collector was dead for
  years because of a mask, not logic.
- A block placed by the player MUST get both subscriptions: `attach_block_signals` (clears the grid
  cell) and `connect_block_signals` (drops the collision). Forgetting one leaves an occupied cell
  and a dangling collider. Quests mount blocks the same way (`quest_arcs._mount_on_player`).

### How a block dies

A machine falls apart BEFORE it is finished off, otherwise combat is silent HP subtraction.
Thresholds live on `VehicleBlock`, checked in `hurt()`:

- **below `DROP_FRAC` (20% HP)** — each hit has `DROP_CHANCE` (30%) to tear the block into the world
  (`blocks.detach_node` → `_detach_one`). The tear is DEFERRED to end of frame: `hurt` is called
  from inside a physics traversal (AOE queries bodies from space), and reparenting mid-traversal
  touches a busy physics server.
- **below `FUSE_FRAC` (5% HP)** — fuse: red matrix over the block, BRIGHTENING towards the blast
  (`BlockFX.fuse`, `progress` 1→0; in mode 2 alpha is `1 − progress`). The block itself cannot be
  tinted — model materials are SHARED between instances; a separate shell with its own material
  lifts that limit (the repair effect works the same way).
- **Three things explode**: battery (own, larger numbers), CABIN (takes the machine with it), and
  any burnt-out fuse. Radius 3 m, `BlockFX.explosion(..., push)`: damage to blocks + impulse to LOOSE
  bodies only. Drawn with the same glitch cards as spawn and destruction, but red and over the blast
  sphere (`BlockFX.blast_cards`) — the old fireball was the only cartoon effect in the game and said
  nothing about how far the damage reached. A block on a machine cannot be pushed (its parent holds
  it); ones torn loose by the blast fly via `machine_body.register_blast`.
- **THE ANCHOR SPOT IS NOT VALIDATED.** Terrain checks (slope, bump under the hull, height above
  ground) refused in places where the machine stood fine: the player pressed the button, the machine
  hopped, and why was anyone's guess. The only condition is a support block on the machine; tilt is
  handled by the levelling that puts it at 0° and lifts it half a metre.
- **The anchor is held by a BLOCK.** Shoot the support out (and no stationary block — seller, miner
  — remains) and the machine drops off the anchor by itself (`_energy_tick`). Otherwise a dead base
  hangs frozen with no way to release it: the anchor button asks about the very support that is gone.
- **Support column and rotation pivot live AT THE SUPPORT** (`vehicle_body_3d.support_block`). The
  machine's origin is the grid centre, i.e. the cabin: the column propped up the wrong block, and
  `ROT_SUPPORT` spun the base around the cabin — it swung away on an arc while the column stood.

### Weapons

- **The cabin is not an automatic verdict.** Cabin weight in target scoring (`SC_CABIN`) is LESS
  than proximity weight: otherwise every gun converges on the cabin from the first volley and the
  machine collapses whole in seconds. Each gun also has a constant "taste" (`SC_TASTE`, from block id
  and its own seed) — without it neighbouring guns compute the same score and hit the same block.
- **SPREAD IS ANGULAR AND GROWS WITH DISTANCE** (`WeaponBlock.spread_deg`, `_apply_spread`). Aiming
  is automatic (the player only holds Attack), so without spread it is an aimbot. A cone gives
  centimetres up close and metres at max range, i.e. bursts land ACROSS THE MACHINE. The cone also
  narrows as the shooter closes in. Shotgun and mortar have their own spread with the base one off
  (`spread_deg = 0`): the shotgun's must stay constant, and the mortar aims at a POINT and misses by
  metres over the ground.
- **THE AIM RAY IS NOT DRAWN** (`WeaponBlock._ready`, `raycast.debug_shape_thickness = 0`).
  `RayCast3D` draws its own debug line when collisions are visible, and five weapon scenes set it to
  thickness 5 and green. Killed at the SINGLE DOOR, not per scene.
- `WeaponBlock` — the turret aims ITSELF: own detection sphere (radius synced to `weapon_range` in
  `_sync_detect_radius`), nearest target, lead with drop compensation (`_lead_point`). Player taps
  play no part in aiming.
- The target is a BLOCK of the enemy machine (layer mask 2), not its body. A block on a machine has
  zero `linear_velocity` (the parent carries it), so target speed is MEASURED between physics ticks.
- All damage goes through `_scale_damage` (machine multiplier `MachineBody.damage_scale`), including
  subclass numbers (`aoe_damage` on the rocket launcher).

### Repair field

Repairs ANY blocks in radius — on the ground, on your machine, on another of yours, and on ENEMY
ones; enemy repair heals the player's blocks likewise. The field is small: touching someone else's
machine means standing right next to it. Who to repair is asked from physics (sphere query on the
block layer), not from the own `blocks` node.

## Enemies

`enemy_spawner.gd`. Density: TWO awake, 75 s pause, ONE engaging at a time (`max_engaging`). Was
9/6, then 4/40 (as in TerraTech) — still crowded.

- **The inner spawn radius is COMPUTED**: enemy vision (`detection_radius`, asked from a live one) +
  `spawn_safe_margin`. The same `spawn_safe_margin` measures clearance from OTHER enemies — "safe"
  is one quantity.
- **Terrain height is asked through ONE function — `G.ground_y(point, fallback)`.** It answers "do
  not know" (returns the fallback) until the heightmap is read: raw `terrain_height_at` returns zero
  at that moment. Measure AT THE LANDING POINT. Falling through streamed collision is caught by
  `enemy_vehicle._unsink` (for player machines it is `world_persist._rescue_fallen`, which does not
  see enemies).
- **Everyone DROPS IN** from `drop_height`. Hence no height/slope rejection: it cost five terrain
  samples per candidate across 48 candidates, and a falling machine does not need flat ground
  (`_flip_recover`).
- **The cap counts AWAKE ones.** Beyond `sleep_dist` (420 m) an enemy sleeps: physics frozen,
  `process_mode` off for the whole branch (otherwise turrets fire past the horizon). It used to
  TELEPORT to the player instead — combat could not be left.
- **ON EQUAL SECTOR LOAD, PICK THE REAR** (`_find_spawn_pos`). The `_in_player_view` ban (cone
  ±`front_cone_deg` within `front_clear_dist`) only covers the MOMENT of spawning: an enemy appears
  80 m to the side, the player turns toward a quest marker, and it is right in the way. The ring is
  80..160 m centred on the player, so this happened every time. From behind an enemy catches up
  instead of blocking.
- **THE FIRST ENEMY IN A SAVE HITS AT HALF STRENGTH** (`FIRST_ENEMY_DAMAGE = 0.5`, flag
  `G.first_enemy_met` persists). DAMAGE is reduced, not HP: it must break apart the same way or the
  fight teaches nothing. The discount goes to whoever came FOR THE PLAYER (regular stream and the
  story scout), not to event machines. **The scout always gets it**, flag or not: it arrives right
  after the tutorial when the player has the starter kit and zero research.
- **THE STORY SCOUT DROPS ALONG THE MACHINE'S HEADING** (`spawn_scout_near_player`) — the one place
  where "never appear in front" is inverted on purpose: it is the player's first enemy, they do not
  yet know the camera can be turned, and a random ring angle put it behind them. Heading comes from
  the FORWARD VECTOR flattened to the horizon, not from `global_rotation.y`.
- **AFTER THE TUTORIAL THE WORLD WAITS `first_spawn_delay`.** The number lives on the spawner and
  `tutorial_director` asks for it: otherwise "a couple of seconds to drive around" ends with someone
  from the regular stream arriving before the scout.
- **Quiet zone `quiet_radius`** around your own ANCHORED machine: no spawns there. The whole factory
  only works while anchored, and without the rule enemies arrived exactly while the player was
  laying out a conveyor and not steering.
- **Builds must agree with `connect_faces`.** Wheels are `2` (rear only, +Z), guns and radar are
  `32` (bottom only). So NOTHING can attach to a wheel or a gun: guns go on blocks, side armour on
  the SECOND FLOOR of the hull. Layouts do not check this (`set_block` puts anything anywhere), and
  the mistake only shows in game as a floating block.
- **Six enemy builds** (`blocks.gd`, presets 5–10): scout, runner, raider, lancer, breaker, siege —
  ascending in danger and SIZE. Single-cell blocks only: a 2×1×1 occupies one grid cell but has a
  wider collider. No power blocks on driving enemies: panels only produce while anchored.
- **A kill pays RP by the machine's VALUE** (`G.rp_for_kill`, base build subtracted). Value is
  measured ONCE at birth: measuring at death would pay for how neatly it was taken apart.
- **The build is chosen against the player's machine value** (`_pick_preset`, sum of `G.shop_price`),
  not by dice. `preset_tiers` order is BY DANGER, not price. Value sets the CEILING; the tier is
  rolled randomly from the first up to it.
- **FORTIFIED POINTS SIT ON THE MAP** (`outposts.gd`, presets 11-12) — the only thing in the world
  not spawned around the player. Layout comes from a CONSTANT seed, so a fort at the canyon edge is
  there tomorrow too. Cleared stays cleared — only INDICES go into the save (coordinates derive from
  the seed; storing derivable data eventually gives a save that argues with the code). Up close a
  point MATERIALISES as a normal enemy machine with `is_base`; far away the node is removed and the
  point stays. Sleep and culling are handled by the spawner (`register_base`) — one rule for
  everything that shoots. Loot: ingots of THIS BIOME'S METAL.
- **ROTATING TOWERS** (presets 13-15) — a four-storey mast, shield on top, panels and battery at the
  base, guns on side consoles. The core is `ROT_SUPPORT` and the base turns its HULL toward a visible
  target (`enemy_vehicle._turn_to_target`). The point is the dead zone: a turret covers ±`YAW_LIMIT`,
  so blind outposts and forts cover their back with guns facing different ways while a rotating one
  needs a single direction. The support is also the tower's ONLY stationary block, i.e. its core:
  shoot it and the tower collapses whole (`MachineBody.cabin_watch`). Freezing here is KINEMATIC:
  physics treats a static body as motionless and does not carry rotation into contacts.
- **THE CORE WATCHDOG RUNS FOR ENEMIES TOO** (`cabin_watch` from `_physics_ai`). Otherwise: a base
  could be stripped to the last block without dying (an invisible hull that pays no RP and never
  tells the point it was cleared), and a driving machine's cabin can be TORN OFF whole
  (`DROP_FRAC`) without a `destroyed` signal — it kept driving cabinless. The watchdog asks "is
  there still something holding this machine together", not "did a signal arrive".
- **ENEMY ENERGY IS REAL.** The energy system lives in `MachineBody`; on a tower the panels, battery
  and SHIELD all work (the dome spends energy per hit). Hence the way in: shoot out the panels or
  the battery. Only BASES tick energy (`_base_tick`).
- **"Sector scan"** — the one scripted event in the game; do not touch it. A square around the
  player, pillars at the corners, a countdown; stay and an INVADER arrives: one at a time, outside
  the cap, never removed by sleep cleanup, never forgets its target. It falls from
  `invader_drop_height` — it appears at the edge of the square, i.e. nearby.
- **Enemy sight** (`enemy_vehicle`): target acquisition has TWO paths — the area signal and the
  periodic search — and both must go through `_consider_target`, which also holds the visibility
  rule. When the signal set the target itself, the check was skipped almost always. Acquisition needs
  LINE OF SIGHT; inside `hear_radius` it does not. Losing sight starts a forget timer, so hills work
  as cover. The 40 m radius is deliberately SMALLER than gun range: a hit reveals the shooter through
  `notice_attacker` at any distance and through anything. That call belongs to the weapon
  (`WeaponBlock._alert_victim`), not to `hurt()`: the same `hurt` is called by drills on veins and by
  repair fields.
- **Escape IS possible.** No chase speed bonus (there was `chase_boost` +25%), and a damaged enemy
  that breaks contact GIVES UP (`_give_up`): for `GIVE_UP_TIME` it takes no targets and moves its
  patrol "home" away. A timer alone is not enough — patrol points are built around the spawn point,
  i.e. where the fight happened. Getting hit cancels the give-up.
- **Engagement range is capped by vision radius** (`_own_weapon_range`): otherwise the enemy keeps
  gun-range distance, backs out of its own detection radius and loses the target in a loop.
- **A sleeper carries meta flag `asleep`**, read by more than the spawner: LiteTerrain
  (`map._update_collision_cells`) skips such bodies and keeps no terrain collision window under them.
  This is an edit to a THIRD-PARTY addon — restore it after updates.

## Terrain (LiteTerrain)

- **The ground is drawn THREE ways at once** and seams must know all three: chunk meshes (step
  2/4/8), the merged macro-group mesh (step 8), and one coarse mesh per internal quadtree node (8…64
  samples). Stitching knew only the first two. Ask `_neighbour_step`, order "node → macro → chunk":
  for a chunk hidden under a node, `_chunk_lod` is stale and lies.
- **GENERATION AND REBUILDS ARE THREADED** (`WorkerThreadPool.add_group_task`, one task per ROW or
  CHUNK). Rule: a thread writes only into its own slice of a pre-sized array, reads only immutable
  data, never touches the scene tree. The other half of the speed is NOT COMPUTING TWICE: biome masks
  come from a lattice with step `MASK_STEP` (on a 1982² map that is 190k noise calls instead of 12M).
- **FLAT AREAS MERGE INTO BIG QUADS** (`_compute_chunk_data`). Merge only strictly flat cells
  (`MERGE_EPS`, a millimetre): the dropped interior vertices already lay in that plane, so the mesh
  cannot drift from collision and a T-junction cannot open a gap. Slopes and rippled sand are not
  flat and never merge. The chunk's outer ring never merges — that is the seam. Unreferenced vertices
  are dropped in one remap pass.
  - **ANY SHAPE, BUT BUILT FROM RECTANGLES** (`_flat_rect`): a rectangle is ALWAYS two triangles
    regardless of area, while an honest polygon with a ragged 40-vertex border is 38. Growth order
    matters: "right then down" and "down then right" split the same area differently, so both are
    computed and the one covering more cells wins.
  - Merge ceiling is CHUNK SIZE. It costs the chunk mesh nothing, but a coarse node mesh spans dozens
    of chunks: without a ceiling one quad would stretch a kilometre, and biome colour lives in
    VERTICES — the gradient would interpolate across half the map.
  - **NO GRASS ALONG A MERGE EDGE** (`no_grass` → `COLOR.r = 0`, the same flag as on LOD seams).
    "T-junctions cannot gap" holds only while all vertices are coplanar, and grass is raised by the
    VERTEX shader per vertex: the neighbour's mid-edge vertex rises while the big quad's edge stays a
    straight line. The WHOLE perimeter is flagged, corners included.
- **FIVE KNOBS FOR THE WHOLE TERRAIN** (seed, size, Height, Features, Mountains). Was 17, then 6. A
  setting earns its place only if the player can PREDICT what it changes. Cut: things with one sane
  answer (octaves, blur count → constants), things that always moved TOGETHER (ridge height with
  sharpness → one knob), and things that must FOLLOW map height (mountain lift, dunes, mesa top,
  canyon floor, snow line — all derived from `Height`).
- **EROSION IS GONE, AND THAT IS A DRIVING DECISION.** The gully filter made the map prettier but
  produced FREQUENT ELEVATION CHANGES on every slope, and driving is what the player does all the
  time. Removed entirely (pass, knob, 4 derived numbers, 150 lines); history `e2c4b7a`, `d6ec5df` —
  restoring it is a revert. What survived from that work: the generation screen with Stop and an
  estimate, the natural preset, snow by height, split passes, fewer knobs.
- **A CANYON IS MESA LAND CUT BY GORGES** (`plugin._gen_carve_row`), not a pit and not a slab. Three
  rules, each bought with a breakage: the top is LOCAL GROUND (`surface`), otherwise the region
  either sticks out as a slab or drowns into a flat terracotta field; gorges are a MINORITY of the
  area (making the floor half of it sank the whole region — a bowl walled off from everywhere);
  steps only ON THE WALL (terrace a fraction of the rise, not the height itself), otherwise contour
  lines run across the whole region and a six-metre cliff appears on flat ground.
- **MOUNTAINS OUTRANK CANYONS, AND SHAPE MUST SAY WHAT COLOUR SAYS.** Shader layers go "desert↔meadow
  → canyon → MOUNTAINS ON TOP", but the carve did not know and cut into mountains. The carve is now
  DAMPENED by the mountain mask. The reverse (dampening mountain lift by the canyon mask) does not
  work: dampening is a step exactly as tall as what it removes (0.75 of map height). The carve is
  only 0.3 and fades out with its mask.
- **GORGE DEPTH FOLLOWS HOW FAR THE NOISE WENT UNDER THE THRESHOLD.** Otherwise a two-metre spot
  where `|fbm|` dipped by a hair became a well. Full depth only in the channel core (`deep_k`).
- **UVs COME FROM THE PLANE THE FACE LOOKS INTO** (`glsl.gdshader`, `wall_uv`). On a canyon wall the
  normal lies sideways, XZ degenerates, and texture plus per-pixel noise stretched into vertical
  streaks. Plane choice is HARD (one texture fetch, we are fill-bound) and happens IN THE FRAGMENT:
  per-vertex is impossible, since one triangle's corners would be computed in different planes. Grass
  stays on XZ (vertex stage, gentle slopes only).
- **BIOME MASKS ARE COMPUTED IN ONE PLACE — `TerrainBiomes`.** The canyon carve kept a SECOND copy of
  the formula and it silently diverged: `canyon_mask` shifts noise by `mask_offset` (that is how the
  seed moves all geography) and the copy did not know. The carve ran WHERE THE CANYON WAS NOT
  painted: the real region stayed untouched while pits appeared all over the map, with an edge twice
  as sharp.
- **DAMPENING A LAYER BY A MASK MAKES A STEP OF THE SAME HEIGHT.** Mountain lift (0.75 of map height)
  and dunes were dampened under the canyon mask — along the mask edge a hundred-metre pit opened.
  Now the canyon CUTS finished ground from its own level.
- **THE MESH MAY KNOW MORE THAN PHYSICS.** Collision is cut from `md`, the mesh is built separately,
  so sand ripples and rock roughness can be baked into the mesh only (`_detail_height`). Three rules:
  near chunks only (step ≤ `DETAIL_MAX_STEP`), ZERO AT CHUNK EDGES (the neighbour may have another
  LOD), and a function of world coordinates and biome ONLY. Wavelength is set by grid step: shorter
  than four steps there is nothing to draw the wave with. The normal must follow the offset (terrain
  is Lambert). Strength is exported (`detail_ripples`, `detail_rock`); rock roughness was cut 4× —
  0.45 m on a 7 m wave is crumpled paper across every hill. The editor has detail OFF by default
  (`editor_detail`): it rebuilds every visible chunk after every brush stroke. Hence "pretty in the
  editor, different in game".
- **NO SKIRTS ON SEAMS, EVER** (tried: extra triangles everywhere and the wall shows). Seams close
  because edges MEET: every step is a power of two on one grid (chunk step divides `chunk_size`, node
  step rounds DOWN to a power of two, `_qt_step`). The other half is timing: a chunk is restitched in
  the same pass where the node or macro appeared (`_qt_apply` on `coarse_changed`).
- **ALL THREE REPRESENTATIONS ARE STITCHED.** Macro and node meshes are built ONCE at load, so their
  edges went years without fitting anyone. And those are the two seams with the BIGGEST step gap:
  macro (4) next to a node (8…64) — macro is the finer one, so it must adapt; and node next to node
  (a quadtree by construction draws neighbouring areas at NEIGHBOURING levels). Both now go through
  the same signature as chunks (`_restitch_macro` / `_restitch_node`), and "what is drawn in this
  cell" is answered by ONE function, `_drawn_step_at`. Rebuilds are cheap by construction: node step
  grows with node size, so any coarse mesh is ~16×16 quads.
- **A SEAM SIGNATURE IS EIGHT BITS PER FIELD** (`_encode_sig`). It was four, and a node neighbour's
  step reaches 64: the overflow spilled into the next field, DIFFERENT neighbourhoods encoded to the
  same number and the mesh was never rebuilt.
- **A CHUNK CORNER MAY NOT MEET, AND THAT IS A LIMIT, NOT A BUG.** A corner vertex lies on TWO seams,
  and the W/E block in `_compute_chunk_data` overwrites what N/S decided. Only reachable when both
  sides are coarser AND our start is not a multiple of their step — i.e. a chunk (every 16 cells)
  against a node (step up to 64). Macro and node starts are multiples of 64, so they are immune.
- **BRUSH STRENGTH IS A PERCENTAGE AND SCALES WITH RADIUS** (`plugin._brush_step`): at 100%, radius
  100 raises by 10% of map height, radius 10 by 1%. Strength used to be METRES per stroke: the same
  number built a mountain on a 30 m map and did nothing on a 300 m one, and behaved identically for a
  3 m and a 200 m brush. A fraction of height keeps stroke SLOPE constant. For flatten the percentage
  means the blend toward the mean height and does not depend on radius. The cursor is TWO rings drawn
  on the ground (`_forward_3d_draw_over_viewport`): outer = reach, inner (a tenth) = core.
- **THREE FILES ARE READ, IN STRICT ORDER** (`map._load_heightmap`): `user://terrain_height.bin`
  (baked player edits) → `res://terrain_height.bin` (stream dump) → `res://terrain_height.res`
  (image). Hence: generation must write BOTH `.res` and `.bin` (otherwise the editor has the new map
  and the game the old one), and after generation you need a NEW SAVE, since `user://` overrides
  everything. `G.wipe_save` removes it through `map.reset_heights` (the node owns the path). Heights
  are already in memory, so the current session finishes on the old terrain.
- **THE BIG GAME-VS-EDITOR DIFFERENCE IS LOD** (`lod_distance_0/1/2`). The editor builds the whole
  preview at step 1; in game a chunk 40 m away was 4× coarser and 80 m away 16× — and 40 metres take
  three seconds to drive. Pushed out to 60/120/240. Second is mesh DETAIL (absent in the editor),
  third is flat merging (biome colour lives in vertices, so on a 16 m quad the gradient stretches).
- **THE LONGEST STAGE IS THE LAST ONE, AND IT RUNS IN STEPS.** Setting heights rebuilt the whole
  editor preview inside `set_heightmap` in one blocking call: the bar sits at 96% and the editor does
  not repaint. The plugin now drives the rebuild (`map.editor_rebuild_begin/_done/_progress/_apply`),
  polling each frame; only mesh merging stays blocking. There is ONE implementation —
  `_rebuild_editor_full` calls the same steps in sequence.
- **THE GENERATION SCREEN CAN STOP AND ESTIMATES THE REMAINDER.** A launched group task cannot be
  cancelled, so Stop works the other way round: every remaining row exits immediately, the pass
  finishes in milliseconds, and generation stops BETWEEN passes writing nothing (a half-generated map
  is worse than the old one). The estimate covers the whole run, not the current pass.
- **THE BAR FOLLOWS A WORK PLAN** (`plugin._plan_build` / `_plan_slice`), not hardcoded fractions.
  Those lied three ways: several blur passes shared one fraction (the bar rolled back), the canyon
  pass can be off (a third of the scale skipped), and writing plus preview rebuild took 4.5% while
  being the longest stage. `elapsed × (1 − frac) / frac` is honest exactly as far as the bar is
  proportional to WORK. Pass cost is measured in NOISE CALLS PER SAMPLE, counted from the code:
  Heights = 4 native + 3 `_cv_noise` (GDScript, ×5) = 19; Smoothing = 0.5 (no noise, five array
  reads); Canyons ≈ 8 (mask and early-out are cheap; full price only over the canyon's share of
  area). The plan is built BEFORE the run from the same conditions that start the passes. The
  estimate is smoothed: rows inside a pass are not equal.
- **LAYERS MUST NOT EAT EACH OTHER.** Metre values (mountain lift, dunes, mesa top, canyon floor,
  snow line) derive FROM `Height`: half the settings are fractions, so moving one knob otherwise
  broke the other half invisibly.
- **WHERE A SETTING LIVES IS WHAT IT MEANS.** The plugin dock CREATES the map (seed, size, shape,
  brush, baking) and holds no display settings; the node DISPLAYS it and holds no generation
  settings. Inside the node one group is special — "Editor only" (`editor_lod`,
  `editor_view_distance`, `editor_detail`) — absent from a built game. "Preview detail" moved from
  dock to node for that reason, and its setter does the preview rebuild.
- **Respawn** (`camera_controller._respawn_point`) searches rings outward from the death spot, and
  clearance is measured FROM THE ENEMY'S `detection_radius`, not a round number: the hardcoded 40 m
  was smaller than enemy vision (85), so a bare cabin respawned inside someone's aggro zone.

## Materials

One `resource.tscn` for ALL kinds: a kind is the `type` + `metal`/`component` fields. Models are
swapped in `_update_visual` — physics and the production chain never notice.

- 4 metals (`G.Metal`) + coal; vein type = metal index, colours from `G.METAL_COLOR`.
- **THE MINER'S PUMP MOVES ONLY WHILE IT WORKS** (`auto_miner._set_rig`). The animation is not
  invented: made in Blender, lives in `objects/Assets.glb` (Armature.001Action, 2.5 s), keys ported
  into `blocks/scenes/auto_miner_pump.tres` — four `rotation_3d` tracks on four moving bones. Moving =
  mining; a machine waving for nothing lies twice. Tempo follows `mine_interval`; touch the player
  only ON STATE CHANGE (otherwise `play()` restarts the animation every frame) and stop with
  `pause()`, not `stop()`. Beyond `RIG_VIEW_DIST` the rig is disabled: skeleton poses and
  `BoneAttachment3D` recompute every frame for a two-metre rig a hundred metres away.
- **A VEIN BELONGS TO THE DRILL OR TO THE MINER, NOT BOTH.** The auto-miner can only be placed at an
  ALREADY EXHAUSTED vein and CLAIMS it (`resource_node.claim`): `RestTimer` stops, the vein does not
  regenerate, and it slowly scrapes ore out (`mine_for_claimer` — touching neither HP nor counter,
  since for everyone else the vein is empty). It used to hit the same vein with the same `hurt`, i.e.
  it was a drill that never tires. It is placed BESIDE the vein, facing it with −Z, overriding the
  player's manual rotation.
- **METAL BELONGS TO THE BIOME** (`resource_nodes._metal_for`): desert → ferrite, meadow → cuprite,
  canyon → silicate, mountains → titanite. Weights, not hard mapping (biomes blend), plus
  `WILD_CHANCE` veins against the rule: a perfectly sorted map reads like a table. The biome comes
  from the terrain (`map.biome_at`) — the SAME mask lattice that paints the ground. The radar tints
  blips by metal, otherwise the rule is unreadable.
- **21 components** (`G.Comp`) in two tiers, and the list is ENUMERATED (`_build_comp_recipes`):
  basic = a pair of METALS, C(4,2)=6; advanced = a pair of BASICS, C(6,2)=15. Recipes and colours
  derive from the pair (colour = parent mix); only names are written by hand.
- **Everything loose lives in `/root/Main/objects`**, including ore from a vein (`_eject_one` puts it
  there, not under the vein, or it would land inside the vein-streaming node). But "lies in the
  world" is checked by `G.is_loose_item` — an unfrozen body outside `blocks`/`resources` — not by
  parent name. On a machine, in a collector and in hand items are held with `freeze = true`.
- **Kind key** — `resource.kind_key()`: `ore0` / `m0` / `c0` / `coal` / `chunk:<block>`. Those strings
  spell `G.BLOCK_RECIPE` and `G.COMP_RECIPE`. Inverse: `set_kind_key()`.
- **Every recipe has EXACTLY TWO DIFFERENT materials** — an engine requirement: the fabricator tells
  inputs apart by kind (slot A = first arrival, slot B = first different one).
- Seller prices derive from `G.METAL_PRICE` (`G.sell_price`); components have no table of their own.

### Energy

**CHARGE LIVES IN THE BATTERIES THEMSELVES** (`battery.gd`: own `capacity`, own `charge`); the
machine only sums them and draws from them (`_bat_add` / `_bat_take`). While charge was a machine
number, a battery removed and refitted came back EMPTY. Charge travels with the block and survives
saving (`blocks.charge_map`, field `chg`). The machine keeps only the solar buffer: it appears with
the anchor and disappears with it.

## Economy

All prices FOLLOW from `G.METAL_PRICE`. The anchor is ferrite ore at 10$: "earn N$" quests are tuned
on it.

- ore = 0.4 of its ingot (smelting is 1:1, so a 5× gap is impossible);
- component = recipe sum × `CRAFT_MARKUP`;
- shop block price = material value × `SHOP_MARKUP` (`G.shop_price`).

`SHOP_MARKUP` > 1 is THE rule: "sell materials and buy the block" must be worse than "build it
yourself", or the fabricator, component factory and Scrapper are pointless. That was exactly what was
broken: a block worth 300$ in materials cost 5$ in the shop.

**SALES LIVE IN THE SHOP, ON BLOCKS** (`G.shop_sales`, three items at −20/−30/−40% for 15 min).
There used to be a MARKET with material-price swings and a corner panel: using it meant memorising
four table rows and hauling the right metal in time, while the "what to haul" decision is made at the
seller where no panel exists. A discount must live WHERE IT IS USED. Three rules:

- **discounts only, no markups** — a markup is a penalty for entering at the wrong minute;
- **discounts only on UNLOCKED blocks** (`is_block_shop_unlocked`);
- **`shop_price` stays the BASE**; the discount is applied by `shop_price_now`, and only by the shop:
  `shop_price` is what measures machine value (which enemy to send, how much RP to pay).

## Input

All tap parsing is in `vehicle_body_3d._input`. Picking up and placing blocks works in ANY mode;
`Building` only adds conveniences (block globe, rotation, preview). Swipe is separated from tap
(`_build_tap_moved`), otherwise camera orbit eats aiming. `_tap_over_ui` guards against taps through
the HUD. A double tap that FIRED is swallowed (`set_input_as_handled`), otherwise it reaches the
camera and resets the view.

**BUILDING ON ANOTHER OF YOUR MACHINES GOES THROUGH THAT MACHINE** (`_player_machine_under`,
`_delegate_build`). There is NO separate code path: the ray found another player machine, so we ask
IT to handle the same tap (`_handle_click` / `_commit_build_tap`). Same script, so it builds with its
own grid, ghost, colliders and subscriptions. The alternative was tried — threading the target
through grid, preview, body-under-collision, both subscriptions and link rebuilding — and produced a
SECOND build implementation that behaved differently (aim missed cells, preview disagreed with the
result). Two rules: only the ACTIVE machine delegates (`is_active`, which also prevents chains), and
hand flags (`block_take`, its contents, manual rotation, origin) are moved into the target and taken
back — the hand holder is shared, the flags are per machine.

**Long press on a block is the single entry to all machine windows** (`_try_open_factory_ui`): own
factory block → ports/product, ANOTHER of your machines → its radial menu. The ⚙ marker above a
machine is a hint but cannot be relied on: it hangs on viewport physics picking (`Area3D._input_event`)
and only receives events nobody marked handled.

`PhysicsRayQueryParameters3D.exclude` takes **RIDs**, not nodes: `[self]` silently does nothing, only
`[get_rid()]`.

## What gives the world content

- **`outposts.gd`** — fortified points ON THE MAP (see Enemies): fixed coordinates, permanent
  clearing, biome loot. The only thing not spawned around the player.
- **`contracts.gd`** — System orders: "sell N × cuprite in 8 minutes, ×1.8 pay". A contract lives as
  an ORDINARY quest in one reusable journal slot, and progress is counted by the SELLER
  (`sold_<kind>`) — only it knows the material was sold rather than carried. Unlocked after the first
  assembled line. Deadline and pay live IN THE QUEST DESCRIPTION and the deadline TICKS (`_desc_text`,
  rewritten on minute change); the System's line only says "cuprite, urgently". Numbers you must
  remember for the whole trip belong where you can come back for them.
- **`raids.gd`** — raids on the player's base: the more expensive the build, the shorter the pause
  (12 → 5 min). The ONLY exception to the quiet zone, hence the 20-second warning. The squad's target
  is assigned to the base directly (`assign_target`), otherwise a "raid" is an ordinary field
  encounter.

## Quests

`quest_manager.gd` (autoload `Q`) holds data and rules. STORY is story only: seventeen counter quests
were deleted (they told nothing and buried real branches). Counters live in DAILY.

- **AT MOST TWO EVENTS IN THE JOURNAL** (`Q.current_events`, `EVENT_SLOTS`), started ones held first.
  Cooldown is one to two minutes with jitter (`_event_cooldown`). Drive `EV_ABANDON` (500 m) from the
  point and the event is dropped and cools down; measured from the POINT, without waiting for
  participants to spawn.
- Types: TUTORIAL / STORY / DAILY / **EVENT**. An event REPEATS (not persisted in `G.quests_done`,
  recharged by cooldown) and is never offered during the tutorial. Only one so far — "Crossfire": a
  fight between two machines of DIFFERENT factions (1 and 2, otherwise they do not see each other).
- **Stages** (`add_stages`): quest progress and goal ALWAYS equal the current stage's, so the tracker
  and `report()` know nothing about stages.
- **Requirements** (`requires`): what must be finished for a quest to appear. `order` is only display
  order now. The tree branches; several story quests can be available at once.
- **Skip** (`skip_quest`): the target vanished through no fault of the player → closed without
  reward, tree moves on.
- Progress is driven by events: `Q.report("ore_mined", 1)`.

**The tutorial is about ASSEMBLY only, five steps.** Journal, storage, shop, tech tree and sound were
cut: those are buttons in plain sight. Assembly is shown by a BLUEPRINT
(`tutorial_director.BLUEPRINT`): white ghosts in the cells where blocks belong, with a finger
pointing at the nearest. The layout is exactly `G.STARTER_KIT` around the cabin. Non-obvious gestures
(long press, swipe to close) are a Mechanic line AT THE END (`FINAL_HINTS`), not separate steps.

**THE SHIELDED TOWER IS A GAME RULE, NOT QUEST CODE** (`arc_tower`, `arc_sam`). The tower (presets
16-17) has a shield and batteries but NO PANELS: zero generation of its own. Charging towers (preset
18) with `WIRELESS_CHARGER` stand around it: while one lives the dome holds; kill them all, the
reserve drains under fire and the shield dies by itself. The quest places machines and waits for the
tower's death; it knows nothing about shields. For that the charger stopped being a "player block"
(it was hardcoded to `faction == 0`, now it feeds ITS OWN faction) — the same trap about mechanics
the enemy does not have.

**PARTICIPANTS APPEAR IMMEDIATELY, AT 250-300 m** (`EV_SPAWN_DIST`, `_quest_dist`) — one rule for
every spawning branch (carrier, salvage, towers, duel, gang, supply, camp, defend). It used to be a
per-branch number (170..260) plus a "get there and they appear" gate: the marker led into an empty
field where there was nothing to see even through binoculars. Far away they cost nothing (the spawner
puts them to sleep). Exception: waves, which by definition arrive at the player's position.

**NO MARKER WITHOUT A TARGET** (`quest_compass._nearest_enemy`): for kill quests the marker first
looks for a STORY machine (at any distance), then the nearest enemy within `KILL_MARK_DIST`. It used
to point at a random enemy half a map away — before the scout spawned, the arrow honestly pointed at
the horizon.

**THE MARKER FOLLOWS A LIVE PARTICIPANT, NOT A POINT** (`_live_target`). The point is chosen once
while enemies drive around: by the time the fight starts the target is elsewhere, and after the
player dies the marker pointed into an empty field. Quest machines carry meta flag `story` (set by
`spawn_at`): `enemy_marker` tints them specially and shows them four times farther. A player-assigned
target still outranks it.

**A STORY BLOCK IS NOT LYING IN A FIELD — IT MUST BE TAKEN.** The radar and the collector are CARRIED
by an enemy machine (`_carry_stage` / `_carrier_spawn`, block placed on the cabin so it is visible
from outside), the battery is HELD BY A VEIN (`_battery_stage`: while ore remains, no block). The rule
that keeps this from breaking: a killed carrier and an exhausted vein MUST leave the block behind even
if it burned in the fight (`QuestProps.claim_or_drop`: adopt the real one if it is there, drop a new
one if nothing is). Hold the vein BY POINT, NOT BY REFERENCE: veins are streamed and the reference
goes stale on the first drive away.

**WHERE TO PUT A BLOCK IS SHOWN BY A BLUEPRINT, NOT TEXT** (`_show_plan_on` — the same markup as the
factory site, but on ANY machine). "Attach the panel and the anchor" reads as "hang them anywhere".
The markup is rebuilt only on a PLAN CHANGE (`_plan_sig`): conditions are polled once a second, so
otherwise the ghosts would flicker every poll.

- Energy branch: THE QUEST MOUNTS THE SUPPORT ITSELF (`_mount_support` → `_mount_on_player`: grid +
  `spawn_block` + BOTH subscriptions) and drops the panel next to it. The stage teaches one thing —
  "a panel only produces on a support and only while anchored"; handing over both blocks loose asked
  the player to assemble a structure from two unfamiliar parts instead. If every cell is taken, the
  support falls into the world as before, otherwise the branch dead-locks.
- THE BLUEPRINT IS COMPUTED FROM THE SUPPORT ITSELF (`_support_cell`), not from hardcoded cells: the
  player mounts it wherever they like, and a panel ghost above (5,6,7) would hang in mid-air. The
  repair unit takes the first FREE cell next to it (`POWER_REGEN_TRY`).
- **The white ghost** (`build_hint.gd`) is a copy of the block's MESHES in the target cell, parented
  under the machine's `blocks` node so it moves with it. We copy meshes rather than instancing the
  scene: a scene is a body with scripts and areas — it would start working and occupy the cell. It
  disappears once the right block appears in the cell. The pointing finger is the tutorial's
  (`TutorialGuide.point_at_world`, `show_skip = false`).

**Story plan — `docs/STORY_ROADMAP.md`**: the TerraTech GSO campaign skeleton mapped onto our
mechanics. Two differences drive everything: there are no shops or trading stations and there never
will be (everything that revolved around a station is replaced by YOUR OWN BASE), and selling is a
block on a machine.

`quest_arcs.gd` is a branch's "physics": what appears in the world and what counts as done
(conditions are POLLED once a second — the placement event does not know the block type).
`quest_props.gd` holds items placed into the world by quests. **Each carries meta `quest_id`**, and
that is how systems that know nothing about quests recognise them: world cleanup does not TTL them
away, the save writes the tag next to the block, and `QuestProps` rebuilds its list from the world
after a reload (`_rescan`). Items are handed out via `ensure`: take what already lies in the world,
otherwise drop a new one — but ONLY while the player does not own it (`_player_owns`: machine,
inventory, hand). Same for quest ENEMIES: an empty reference alone is not a victory (after loading it
is always empty), so a guard's death is remembered by a flag. `quest_compass.gd` draws the target
marker and also exposes any quest's target (the journal takes distance from there).

## Saving

**THREE SLOTS, AND A SLOT IS A PATH PREFIX** (`G.slot_path` → `user://sN/`). File formats never
changed: all code writes the same names and one function prepends the prefix. Everything belonging to
THIS world lives in the slot; the DEVICE config (`settings.json`) stays outside.

**THE WORLD SEED** (`G.world_seed`) drives everything laid out randomly: veins, fortified points,
props. They used to come from the GLOBAL `randf`, i.e. anew on every launch — the player returned to
their base and the veins it was built around had moved. Each consumer has its OWN
`RandomNumberGenerator` and its own seed offset: from one stream the rocks would land exactly on the
veins.

**A WORLD WITHOUT EDGES: GROUND IS COMPUTED, NOT READ.** `md` is a WINDOW (`window_size`, 2048² = 16
MB — exactly what the whole old map used) starting at world cell (`_win_x`, `_win_z`). The player
drives, the window follows: the overlap is copied, the generator computes only the new strip
(`generate_region`), and chunk meshes plus collision tiles are RE-INDEXED (they live in the node's
local coordinates). The shift step is a multiple of the macro group. Holding the whole map is
impossible at any size beyond the old one: 8192² is 268 MB and a billion noise calls. "World point →
cell" lives in ONE place (`_cell_ox`/`_cell_oz`): it had been written 26 times as
`local.x + w * 0.5 − 0.5`, and the twenty-sixth hid inside `(W − w) * 0.5` in the collision tile.

**SLOT ONE IS FILE-BASED, THE OTHERS ARE PROCEDURAL** (`G.world_procedural` lives in the world file
rather than being derived from the slot index: it is a property of the world). A file world has edges
and bakes edits as a dump; a procedural one has no edges, and `bake_heights` is skipped entirely
there — a window dump would declare "this is all the land" and everything outside would be clipped to
it. Player edits live as a list of world-space rectangles applied to every fresh strip, and ONLY to
it. Slot one has a constant seed: it is "our" map, and the pre-slot save in `user://` migrates into it
(`_migrate_legacy`, once, by renaming — a copy would leave a second truth about the same world).

**THE MENU BUILDS A NEW SLOT'S WORLD** (`menu._begin_create`). A 2048² run takes a minute or more;
under the loading screen that is indistinguishable from a hang, so it gets a bar, a remaining-time
estimate (`elapsed × (1−frac)/frac`, smoothed) and a STOP. The slot is wiped only on "play"
(`G.new_game(n, seed)`): abort halfway and the old world is intact. The ground travels into the game
through `G.pending_world` (the only thing that survives the scene change), and `map.setup_procedural`
takes it together with the run's PARAMETERS — the window later computes strips with its own
generator, and diverging numbers would mean a seam. For the same reason defaults live in one place,
`LiteTerrainGen.DEF_*`, and the map's exports read from there.

**MENU: REAL MACHINES IN THE BACKGROUND, CONTROLS IN THE CORNERS** (`menu.gd` + `menu_stage_3d.gd`;
root is a `Node3D`, UI on a `CanvasLayer`). The backdrop used to be DRAWN in `_draw`
(`menu_battle.gd`, deleted): the argument "do not spin up terrain and physics for a picture" was
sound, but machines made of rectangles had nothing to do with what the player builds. Compromise: a
real 3D scene with NO GAME SCRIPTS IN IT — machines are assembled FROM REAL BLOCK MESHES (the
`build_hint.gd` trick: take only `MeshInstance3D` with their own materials, discard body and scripts,
never add the scene to the tree). Ground is a flat mesh with fog; the builds mirror `blocks.gd`
presets but are listed as cells here (calling `blocks.gd` would drag in the 11³ grid with its
scripts). Effects match the game: cyan tracers, red glitch cards on hits, no particles. BRIGHT: day
sky, sun, fog; no screen dimming at all — readability comes from panel backgrounds and title outline.
Machines DRIVE: heading, speed, turn rate limit, circling each other and leaning into turns; turrets
track separately from the hull, fire comes in BURSTS with a muzzle flash. Layout is BY CORNERS:
controls bottom-left (thumb zone), news top-right. News is a DATED, SCROLLABLE feed and only carries
what changes the game FOR THE PLAYER. The first screen answers one question: PLAY and SETTINGS, with
three slots appearing after PLAY. Settings write the same `G` fields as the in-game panel.

**Main scene is `menu.tscn`.** The map ASKS `G` for the baked-edits path itself (`map._ready`): at
that moment the scene does not exist yet.

`G.gd`: progress in `user://`. A block is saved **as its enum name string**, not a number — inserting
a block mid-list would otherwise shift everything after it. Hence: **renamed a block → add the old
name to `LEGACY_BLOCK_KEYS`**, or every save loses it silently. **Removed a block → do not delete its
enum value** (`block_key` indexes `Block.keys()` by value) and **add a replacement to
`RETIRED_BLOCKS`**: the block still stands in saved machines, and the replacement must be THE SAME
SIZE. Then clean it out of `BLOCK_META`, `BLOCK_CATEGORIES`, `TECH_PARENT` (rehanging children) and
`BLOCK_RECIPE`.

**Terrain CAN be levelled in game** — `map.flatten_area(centre, XZ half-size, height, feather)`: edits
heights, rebuilds affected chunk meshes and drops streamed collision so it is re-cut. The pad is
RECTANGULAR: buildings are elongated (a conveyor line is 6 cells by 2) and a circle would strip three
times more ground. First user: the factory site (`quest_arcs._flatten_line_site`).

**Terrain edits survive loading TWO ways** — division of labour, not duplication: the edit list
(`map.ground_edits` → save key `ground`) for the session (four numbers cost nothing and survive a
crash), and the baked `user://terrain_height.bin` at LOAD time (edits are applied to heights and
cleared in one go; the dump is the full map size, 15 MB — visible as a hitch mid-game, unnoticeable
under the loading screen). Edits are replayed FIRST, before machines return: a base stands on level
ground, and restored before its edit it would hang in the air. Every edit has a RUNNING NUMBER and the
baked file remembers the last one — otherwise an edit left in the save would apply a second time and
the pad's edge would get steeper. Edits never reach an export by construction: they are written to
`user://`.

`world_persist.gd` — world state (machines, loose blocks, 10-minute TTL).

- **A saved machine is layout, position, rotation AND the `station` flag.** A base differs from a
  machine not by blocks but by the flag (`is_station` on the machine and on its `blocks`): it has no
  cabin and is always anchored. Without the flag a base came back as an ordinary machine and the
  cabin watchdog deleted it half a second later. Old saves lack the flag, hence a fallback by layout
  (`_is_station_data`).
- **`machines[0]` is the machine the player CONTROLS**: loading puts it on `primary`. Child order in
  `Vehicles` knows nothing about that, so saving writes it first.
- **Restoring runs ACROSS FRAMES** (wait for terrain up to 120 frames, then a couple more for
  collision). After EVERY `await`, check `is_instance_valid`: a reference to a freed node is NOT
  `null`.

## UI

**Block faces are configured ON THE CUBE** (`port_cube.gd`) and nowhere else: the fields under it are
`@export_storage`. Per-face checkboxes next to the cube were a SECOND control for the same numbers,
and two ways to set one thing eventually diverge; besides, "Left" makes you remember where the block's
left is. In game the cube edits cell ports (`port_picker.gd`), in the editor it edits the block scene
(plugin `addons/blockfaces`). The editor cube LOOKS AT BLOCK SIZE and splits into its cells: six
faces for 1³, six sides of four cells for 2³. Size comes from COLLISION (first `BoxShape3D`), and the
cell layout mirrors `blocks._block_footprint`: along X and Z the footprint grows negative from the
anchor, along Y positive. TWO cubes are drawn from opposite corners (a cube has six faces but only
three are visible). Attachment is the `connect_faces` mask for single-cell blocks and per-cell
`connect_defaults` for larger ones. In/out is masks for single-cell blocks and PER-CELL DEFAULTS for
larger ones (`FactoryBlock.port_defaults`, PORTS mode): those are in block axes and rotate with it,
while a player-set port lives in GRID axes.

**Factory block ports are configured PER CELL** (`FactoryBlock.ports`, window `port_picker.gd` on long
press). On a 2×2×2 a side is four cells, and the old "input on the left" meant input into all four.
The port key is "cell offset + direction" in GRID axes, because the footprint is too and does not
depend on rotation. An empty key falls back to the old mask rule. Stored in `blocks.port_map`. **IN
GAME the window only SHOWS** sides: they are authored in the block scene — a side is a property of the
part, and chains are built around known parts.

**What a factory produces** is the player's choice: a long press (`LONG_PRESS_MS`) on your own
fabricator or component factory opens `factory_picker.gd`. The choice is stored in
`blocks.output_map` ("x,y,z" → index), NOT only on the node: the layout stores cells, so an instance
field would reset on every load. Changing the product calls `reload_recipe()`.

**Big windows close with a bottom-up SWIPE** (`swipe_close.gd`): the finger starts at the bottom edge,
centred, and pulls up. One node for both garage and journal; the hint strip lives exactly as long as
the window is open. The event is taken in `_input`, not `gui_input`: the window above is a Control
with `mouse_filter STOP`, and `_input` runs BEFORE GUI parsing.

**A code-built window is centred by `CenterContainer`, not anchors.** A panel filled with children
after anchors are set changes its minimum size later and nobody recomputes offsets (that is how
`port_picker` ended up in the top-left corner, half off-screen). List height inside also comes from
screen size, or CLOSE ends up past the edge on a short screen.

**CAMERA: down orbits, up raises the aim point** (`camera_controller.camera_movement`). Tilting the
view in place is not enough: looking down the machine covers the ground, looking up the sky never
appears because the camera stayed at the same height. So "down" raises the CAMERA along its orbit
(look_at keeps the machine framed) and "up" moves the LOOK POINT above the machine (lowering the
camera would bury it in terrain). In build mode only the orbit works, but in both directions.

**Machine heading for the camera comes from the FORWARD VECTOR flattened to the horizon**, not from
`global_rotation.y`: on a tilted machine the Euler angle is not a heading and the decomposition
drifts.

**SWITCHING BETWEEN YOUR MACHINES IS A BUTTON** (`hud._swap_btn`, label "2/3"). The radial menu
requires driving up to the machine and holding a finger on it — a base left at a vein is
unreachable that way, and that is exactly when you need it. The button cycles
`camera_controller.vehicles` and appears only with more than one machine.

**THE NODE-OR-CODE LINE IS THE SAME EVERYWHERE.** The scene holds what STANDS STILL: frame, padding,
style, nesting (`node_3d.tscn` under HUD; separate scenes `tech_ui.tscn`, `quests.tscn`,
`dialogue.tscn`, `port_picker.tscn`, `factory_picker.tscn`). Code holds what CHANGES: text,
visibility, edge positioning (`hud._relayout`) and anything built FROM DATA. Code fetches nodes by
unique name (`%Money`) instead of creating them.

Icons never move into scenes — `MenuIcon`, `AnchorIcon`, `RotIcon`, `InvIcon`, `DropIcon`,
`EnergyGauge`, `RadarHUD`, `GearIcon`: they are `_draw()` and have no node representation at all.

**`CanvasLayer` child order IS draw order**, and moving a panel from code into the scene moves it
BACK in that order (code used to create it in `_ready`, i.e. after the joysticks and buttons authored
in the scene). Hence bound panels are lifted to the end (`hud._lift`), or the tech drawer slides out
under Take and the anchor button hides behind a joystick.

**A window scene whose own script opens it must use `load()`, not `preload`**: the scene holds that
script, and `preload` makes a compile-time cycle. `load()` hits the `ResourceLoader` cache.

**Never set position or size on CONTAINER children** — the container overwrites them on the next
layout pass (engine rule). Use `custom_minimum_size` and `size_flags`. Code positions only what sits
DIRECTLY in a `CanvasLayer`.

**NO EMOJI, IN GAME OR IN THE PLUGIN DOCK** — the font does not render them and leaves an empty box.
New code breaks this most easily: 📦🔧🛡🎥 lived in the radial menu, 🔍⚠ in System lines,
👆🛒🔍🚗✋🤏 in garage hints. An icon is either DRAWN (`_draw`, like `RadialWheel._draw_glyph`) or does
not exist, with the label carrying the meaning. In the plugin dock the font is the editor's and has no
emoji either, and there is nothing to draw with (plain `Button`s), so labels are WORDS: RAISE / LOWER
/ FLATTEN, RND, "Bake to files".

`hud.gd` (1900 lines) — the rest of the game UI, dark teal palette, styles via `_make_*_style()`.
`tech_ui.gd` — the garage (inventory/shop/tech tree/build/music). `quests.gd` — tracker and journal.
The garage on the BUILD tab is equivalent to closed: the world stays clickable and build widgets rise
above it.

## Effects

`BlockFX` — a "matrix" of glitch cards: cyan/magenta = spawn and destruction, green (`heal`) =
repair, red over a sphere = explosion (`blast_cards`), gold-green = sale. Effects differ by SHAPE as
well as colour: CARDS say "an object is gone", 0/1 DIGITS over the shell say "HP is changing".

**THERE ARE NO PARTICLES IN THE GAME, AND THAT IS A RULE.** The seller had a `GPUParticles3D` with 512
particles, turbulence and a 34.9 s trail — on EVERY sale, i.e. twice a second while a line runs. The
`await` on the emitter signal went with it: sale logic hung on an animation, and a hiccup left the
item undeleted and the slot occupied. There is a PER-FRAME cap on cards — assembling a machine fires
the effect for every block at once.

## Debug flags

Checkboxes on `Main` (`@export_group`): ore by type, regular enemy stream, enemy AI, fortified points,
raids, sector scan, player invulnerability and infinite energy, tutorial, profile panel at start.

- **READ THEM ONLY THROUGH `G.debug(&"flag", default)`.** The flags live on a SCENE NODE while half
  the readers (veins, spawner, enemy AI, raids) must work without it. "No Main" must never mean
  "off". Inside use `v is bool`, not `bool(v)`: `get()` returns `null` on a node without the field.
- **THE MASTER SWITCH `debug_overrides` IS OFF BY DEFAULT.** A built game must behave like a game even
  if someone forgot to restore a checkbox.
- **THE GATE GOES AT THE SINGLE DOOR.** Invulnerability in `VehicleBlock.hurt` (otherwise drills, AOE
  and any new source slip past), infinite energy in `MachineBody.energy_consume`. Both faction 0 only.
- **A disabled ore type is NOT replaced by another** — the vein simply does not appear.
- What the gate must NOT break: quest spawns (`enemy_spawn` does not touch them), the core watchdog
  (`enemy_ai` is checked AFTER `cabin_watch`) and an announced raid (gate in `_tick`, not `_process`).
- The tutorial is disabled through `Q.skip_tutorial()`, not by hiding steps: `tutorial_active()` is
  asked by the spawner and the story, and a hidden tutorial would leave the world frozen.

## Performance

`distance_to()` takes a square root. Where distance is only COMPARED, use `distance_squared_to()` and
square the threshold. Real distance is needed only inside a FORMULA (target score `1 - d/range`, AOE
falloff, flight time, ray length).

- **Engine `occlusion_culling` is OFF**: it needs baked `OccluderInstance3D` and the project has none,
  so it ran a thread and culled nothing. Horizon culling is done by the terrain itself
  (`LiteTerrain.enable_occlusion_culling`, `map.is_point_hidden`).
- **CULLING COMPARES SLOPES, NOT ANGLES** (`_is_aabb_occluded`). There was an `atan2` PER ray sample
  (up to 32) purely to COMPARE angles. `atan2` is strictly monotonic in `dy/dist`, so comparing slopes
  gives the identical answer. `OCCL_HYST` kept its value: occlusion happens near the horizon where
  `tan(x) ≈ x`.
- **SEAM REBUILDS RUN ON A BUDGET** (`STITCH_BUDGET`, `_qt_apply`). Recomputing a signature is cheap;
  rebuilding a mesh is `_compute_chunk_data` over three hundred vertices on the main thread. Without a
  budget a camera turn brought dozens of chunks into frame at once. The rest catches up next pass: a
  hairline crack at the screen edge beats a frame drop.
- **A VEIN KNOWS ITS OWN WORLD POSITION** (`gpos`). Streaming asked `to_global` THREE times per vein
  per tick across two thousand veins.
- **CULLING MUST NOT FLICKER**: anything that JUST entered the frame is checked immediately
  (`_occlude_newcomers`) instead of waiting for the slow pass, and the check has a DEAD ZONE
  (`OCCL_HYST`) — hiding something visible and showing something hidden need different thresholds.
- **A MACHINE OUT OF FRAME IS NOT DRAWN** (`world_persist._vehicle_render_tick`). The engine culls each
  `MeshInstance3D` itself, but a machine has 30-40 and there can be a dozen machines around: one
  whole-machine test (sphere against six frustum planes plus horizon) is cheaper. Only `visible` is
  touched: `process_mode` is never changed — an enemy behind you must keep driving and shooting, which
  is decided by its SLEEP. The check runs EVERY FRAME: a machine must appear the same frame the camera
  turns to it. Your own active machine is never hidden.
- **FOR A LOOSE ITEM, DRAWING AND SCRIPT ARE DECIDED SEPARATELY** (`_cull_tick`). Drawing off-frame is
  pointless — same exact frustum test. But the script must not follow it: a collector lying at the
  base thirty metres to the side is off-frame, and the factory would stall whenever the camera turned.
  The script keeps the old soft rule — "strictly behind you or behind a ridge" plus a near bubble.
- **SETTLED MEANS ASLEEP** (`_settle_tick`). Every non-sleeping `RigidBody3D` asks terrain for its own
  streamed collision window. Godot sleeps bodies itself, but a block resting on a streamed heightfield
  can jitter at the sleep threshold forever: micro-velocity keeps it awake, awake keeps the window,
  the window keeps the ground. So we sleep it ourselves: slower than `SETTLE_SPEED` for longer than
  `SETTLE_TIME` → `sleeping`. `sleeping`, NOT `freeze`: a frozen body means "not lying in the world"
  (`G.is_loose_item` checks exactly `freeze`), so hand, collector and receiver would stop picking it
  up and explosion impulses would not apply.
- **What is BEHIND YOU is not kept alive.** Vein streaming and loose-block cleanup disable everything
  past the near bubble AND behind the camera: for a vein the collision node and MultiMesh slot, for a
  block its script (a lying collector iterates resources, a charger walks machines — behind you that
  costs the same as in front). The near bubble is active in ANY direction (what a drill bites, what a
  packer magnetises). A loose block is only disabled while SLEEPING — a flying one would freeze
  mid-air. The RADAR looks down from above in all directions, so vein blips come from DATA and
  distance (`active_positions`), not from what is drawn.

## GDScript gotchas

- `bool(null)` cannot be constructed — it fails at runtime. And `node.get("field")` returns exactly
  `null` when the field does not exist, so `bool(v.get("anchored"))` crashes on any machine without
  that field. Write `v.get("field") == true`.
- **A field name must not collide with a native class member** — otherwise "Member X redefined" and
  the script does NOT LOAD AT ALL. Caught on `var ready` in a `Control` subclass (`ready` is a `Node`
  signal). Taken names are non-obvious (signals count) and `gdparse` does not see them.
- **A single-line lambda ends at the newline.** A wrapped continuation becomes an EXTRA ARGUMENT to
  the call while the syntax stays valid. Multi-statement bodies: a named method or a multi-line lambda.

## Code style

**Comments and docs are in ENGLISH** (this file included). Not a style preference: the same content
costs two to three times fewer tokens than Russian, and every identifier in the code is English
anyway. Old code is mostly Russian — rewrite a comment into English when you are editing the code next
to it.

**A comment is a working note to myself, not a lesson for a newcomer.** Write dense: the rule, the
number, the trap, why not otherwise. Never restate what the line does, never explain language basics.
History belongs only where the rule looks arbitrary without it.
