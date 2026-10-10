# LiteTerrain

**Version 2.1** · Godot 4.6 / 4.7 · Compatibility (GLES3) · tuned for mobile

Procedural terrain stored and drawn in CHUNKS. One node builds the whole world from a seed: no
heightmap file, no world-sized array, no edge. A chunk asks the generator for its own vertices,
LOD merges four chunks into one mesh instead of decimating anything, and collision is cut only
under the bodies that need it.

Biomes — desert, meadow, salt flats, canyon, mountains — live in one resource that drives the
landform, the masks and the colours at once, so a biome's shape cannot drift away from its look.

The game's own notes on the terrain (measurements, the rules each number came from) are in
`docs/CHUNK_TERRAIN.md` and the Terrain section of `CLAUDE.md`; this file is the addon's manual.

> **2.0 removed the baked half** (`map.gd`: a sliding window of heights, a sculpt brush, noise
> generation into an array, baking to `.res`/`.bin`/PNG). **2.1 removed what it left behind**: the
> tile textures (`Dark/`), the binary material that pointed at one of them, the generator's
> cancel flag and noise offset, the dead biome knobs `dune_amp` / `mountain_rise`, and the
> shader's `low_quality`, `tile_texture` and `texture_blend`.

## Files

| File | What it is |
|---|---|
| `chunk_terrain.gd` | `ChunkTerrain`, the node: LOD selection, the build queue, collision tiles, edits. |
| `terrain_gen.gd` | `LiteTerrainGen`: the height at a world point (`height_at`) and grids of it (`sample_grid`). |
| `terrain_biomes.gd` | `TerrainBiomes`: the biome masks, their noise and the colours handed to the shader. |
| `glsl.gdshader` | The ground shader: biome colour, slope rock, grass lift, detail masks, haze. |
| `ground_detail.png` | Four tileable detail masks in one texture (built by `art/ground_detail.py`). |
| `plugin.gd`, `terrain_inspector.gd`, `seed_browser.gd` | Editor only: the seed map at the top of the node's inspector. |

## Quick start

1. Add a **ChunkTerrain** node to a 3D scene (by name — the script has a `class_name`).
2. Give it a `TerrainBiomes` resource in `biomes`, or leave it empty and it makes one.
3. The top of its inspector shows the world's regions for the current seed. Step through seeds,
   then press **Показать в сцене** to build the real ground round the editor camera.

There is nothing to generate into a file and nothing to bake: the ground IS the seed, and the
same seed gives the same world in the editor and in the game.

## The node

`ChunkTerrain` extends StaticBody3D and makes everything it needs itself (chunk meshes, collision
shapes as internal children), so the scene stays a single node.

| Property | What it does |
|---|---|
| `forced_seed` | The seed. The entire world follows from it. |
| `follow_world_settings` | On: the seed comes from the autoload `G` (`G.world_seed`), one world per save slot. Off: `forced_seed`, for a menu backdrop or a preview. |
| `biomes` | The `TerrainBiomes` resource. |
| `camera` | Leave EMPTY: the node follows whichever camera the scene is drawn with. Set it only to drive LOD from a camera that does not draw. |
| `surface_material` | Leave EMPTY: the ground draws with `glsl.gdshader`. Set it only to try another material. |
| `world_cells` | A NOMINAL square (`get_dims`), not an edge: things laid out over the world need a rectangle. |

## Biomes

A biome is a 0..1 **mask** of world-XZ value noise (`TerrainBiomes.cv_noise`, handed to the masks
as `biomes.noise`). Layers stack in this order:

```
base DESERT ↔ MEADOW  →  SALT FLATS on the desert  →  CANYON  →  MOUNTAINS
```

| Group | Settings |
|---|---|
| Desert / Meadow | `biome_scale`, `biome_bias`, `biome_blend`, `biome_contrast`, `color_sand`, `color_grass`, `dune_wavelength`, `desert_flatten` |
| Salt flats | `salt_enabled`, `salt_scale`, `salt_threshold`, `salt_edge`, `color_salt` |
| Canyon | `canyon_enabled`, `canyon_scale`, `canyon_threshold`, `canyon_edge`, `color_canyon`, `canyon_band_height`, `canyon_butte_scale` |
| Mountains | `mountain_enabled`, `mountain_scale`, `mountain_threshold`, `mountain_edge` |
| Snow / rock | `color_snow`, `snow_frac`, `snow_blend_frac`, `color_rock`, `rock_threshold`, `rock_blend` |
| Grass | `grass_density`, `grass_height`, `sand_grass`, `grass_shade` |

- A disabled layer has a zero mask, so it leaves both the colour and the landform.
- Heights in metres follow the world's Height, not knobs: dunes, a mountain's rise, the gorge depth
  (`terrain_gen.prepare_sampling`) and the snow line (`snow_frac` × Height).
- Rock follows SLOPE, snow follows the mountain mask AND height, grass grows on the meadow only.
- `canyon_band_height` sizes both the colour strata and the geometry terraces.
- A new biome is a shader edit too: each layer's colour is a `mix()` in `glsl.gdshader`'s `vertex()`.

The masks are baked into the vertex COLOR per vertex (`ChunkTerrain._biome_colour`): `.g` canyon,
`.b` meadow, `.a` mountain, and `.r` carries two things — the grass flag (0 on a seam vertex) and
the salt flat (`SEAM_ON` + `SALT_SPAN` × salt, split at `SEAM_TEST` in the shader).

## Runtime API

```gdscript
terrain.terrain_height_at(world_pos: Vector3) -> float  # ground height under a world point
terrain.ground_sample(world_pos: Vector3) -> Vector3    # (height, dh/dx, dh/dz): the same patch, with its slope
terrain.biome_at(world_pos: Vector3) -> Vector3         # (canyon, meadow, mountain) masks
terrain.salt_at(world_pos: Vector3) -> float
terrain.world_height() -> float                         # the Height the world was built with
terrain.terrain_is_ready                                # the near ground is up (a bool and a signal, terrain_ready)
terrain.set_collision_streaming(on: bool)
terrain.stop_generation()                               # wait out the running tasks; call before freeing
```

A height is read from a BUILT level-0 chunk when one holds that cell, and asked of the generator
only otherwise (`_memo_h`). WAIT FOR THE GROUND BY THE CLOCK, NOT BY FRAMES: readiness is worker
threads computing heights, which is real seconds.

### Editing the ground at runtime

```gdscript
terrain.flatten_area(center: Vector3, half_extent: Vector2, height: float, feather := 4.0, record := true)
terrain.ground_edits() -> Array          # plain dictionaries, JSON-ready
terrain.apply_ground_edits(list: Array)  # replay them on load
terrain.reset_heights()                  # forget every edit
```

A pad is a RECTANGLE (buildings are oblong). Edits are a LIST applied on top of the generator in
one function, so the mesh, the collision and a height query see the same ground; replay them before
restoring anything that stands on them. Every edit carries a running number, so a save replayed
twice cannot deepen a pad.

## Collision

A collision tile IS a base chunk, cut from the same heights as the level-0 mesh. Tiles have their
OWN queue and it goes first (a tile is what a machine drives on, a mesh what it looks at), and they
are asked for along each body's CORRIDOR: where it is plus where it will be in
`collision_lookahead` seconds. Moving bodies (RigidBody3D, CharacterBody3D) are found through the
tree's `node_added` / `node_removed`; a body riding another is covered by its parent, a sleeping
one and one carrying the meta `asleep` get no tiles.

## How it works (short)

- **No data model.** `LiteTerrainGen.height_at(wx, wz)` is noise, a five-tap blur and the canyon
  cut at one world point; that is the only ground there is. At step 1 the blur's taps are the
  neighbouring vertices, so a chunk costs (n+2)² raw heights instead of 5n² (`_sample_unit`).
- **LOD is chunk merging.** A node of level L covers 2^L × 2^L chunks of 16 cells and is drawn
  with the same 16×16 quads at step 2^L. Neighbours differ by one level at most, and the finer one
  snaps its edge onto the coarser's line — no skirts anywhere.
- **Two questions, two rates.** The leaf set comes from distance alone and is cached
  (`_build_leaves`, rebuilt after 16 m of camera travel); the frustum is a flat pass over it.
- **Compute in a batch, land on a budget.** The pool computes `build_batch` chunks at once; the
  main thread lands at most `apply_budget` meshes a frame (none of that while loading).
- **A node is hidden only when other ground covers it** (`_covered`): a LOD change is a
  replacement still in the queue, and hiding the old node at once opened a hole.
- **Two materials, not instance uniforms**: grass on the near one only. An instance uniform on a
  chunk takes 16 slots of the global shader buffer each, and there are hundreds of chunks.

## Shader reference

`glsl.gdshader`. The colours, rock and grass numbers are written from the biomes resource at
build time (`TerrainBiomes.apply_to_material`) — edit them there, not here.

- **Texture**: `tile_world_size` (the colour noise's and the grass's cell), `ground_detail`,
  `detail_world_size`, `ripple_strength`, `grass_detail`, `patch_strength`.
- **Colours / terrain / biomes**: `color_*`, `snow_line`, `snow_blend`, `rock_threshold`,
  `rock_blend`, `color_variation`, `sand_grass`, `canyon_band_h`, `crack_strength`.
- **Grass**: `grass_density`, `grass_height`, `grass_shade`, `lod_grass_enabled` (per material).
- **Trample**: `trample_map`, `trample_center`, `trample_size` (driven by the game's `grass.gd`).
- **Corruption**: `corrupt_amount`, `corrupt_map`, `corrupt_world_center`, `corrupt_world_size`,
  `glitch_cell`, `glitch_speed`, `corrupt_cyan`, `corrupt_magenta`, `corrupt_glow`.
- **Haze**: the global uniforms `world_haze` and `haze_range` (project settings), written to FOG.

## Troubleshooting

**Nothing appears.** The node builds round the camera the scene is DRAWN with — check one is
`current`, and leave `camera` empty.

**A machine falls through at load.** Something asked for a height before `terrain_is_ready`;
wait for it by the clock.

**A hole opens while driving.** See `_covered` above: if you touch that rule, this is what breaks.

**The editor preview is somewhere else.** It builds round the editor viewport's camera, which the
plugin hands over when the mouse moves over the 3D view.
