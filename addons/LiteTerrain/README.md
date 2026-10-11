# LiteTerrain

**Version 2.2** · Godot 4.6 / 4.7 · Compatibility (GLES3) · tuned for mobile

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
> shader's `low_quality`, `tile_texture` and `texture_blend`. **2.2 emptied the inspector of engine
> numbers and the seed map**: the node shows its material (`surface_material`, back as the text
> `terrain_shader.tres`), `biomes` and the behind-a-hill switch, under two buttons that build the
> ground in the editor. The numbers nobody changed are constants, the menu's own are fields its
> script sets.

## Files

| File | What it is |
|---|---|
| `chunk_terrain.gd` | `ChunkTerrain`, the node: LOD selection, the build queue, collision tiles, edits. |
| `terrain_gen.gd` | `LiteTerrainGen`: the height at a world point (`height_at`) and grids of it (`sample_grid`). |
| `terrain_biomes.gd` | `TerrainBiomes`: the biome masks, their noise and the colours handed to the shader. |
| `glsl.gdshader` | The ground shader: biome colour, slope rock, grass lift, detail masks, haze. |
| `ground_detail.png` | Four tileable detail masks in one texture (built by `art/ground_detail.py`). |
| `plugin.gd`, `terrain_inspector.gd`, `preview_panel.gd` | Editor only: the buttons at the top of the node's inspector that build the ground round the editor camera. |

## Quick start

1. Add a **ChunkTerrain** node to a 3D scene (by name — the script has a `class_name`).
2. Give it a `TerrainBiomes` resource in `biomes`, or leave it empty and it makes one.
3. Press **Build in scene** at the top of its inspector to build the real ground round the editor
   camera; after changing the material's settings press it again to see them.

There is nothing to generate into a file and nothing to bake: the ground IS the seed, and the
same seed gives the same world in the editor and in the game.

## The node

`ChunkTerrain` extends StaticBody3D and makes everything it needs itself (chunk meshes, collision
shapes as internal children), so the scene stays a single node.

In the inspector:

| Property | What it does |
|---|---|
| `surface_material` | The ground's material: `terrain_shader.tres` (a ShaderMaterial on `glsl.gdshader`) by default, every uniform in the inspector. The node draws with a copy, into which `biomes` and the game write their part (see the shader reference). |
| `biomes` | The `TerrainBiomes` resource. |
| `enable_occlusion_culling` | What stands behind a hill is not drawn (`is_point_hidden`, asked by the game's veins, loose items and machines). |

Fields a script sets (the menu backdrop does, `menu_stage_3d._make_map`):

| Field | What it does |
|---|---|
| `follow_world_settings` | On: the seed comes from the autoload `G` (`G.world_seed`), one world per save slot. Off: `forced_seed`. |
| `forced_seed` | The seed when not following the slot; the editor's preview builds with it. |
| `view_distance`, `keep_radius` | How far ground is drawn; inside what radius nothing built is ever dropped. |
| `ready_ring`, `ready_view` | What must be up before the loading screen lifts: chunks with collision round the start, then the view out to this many metres. |
| `enable_streaming_collision` | Collision tiles round moving bodies; a map being prepared keeps it off. |

Constants, not settings: `FRUSTUM_MARGIN`, `BUILD_BATCH`, `STITCH_BUDGET`, `LOD_INTERVAL`,
`APPLY_BUDGET`, `COLLISION_RADIUS`, `COLLISION_LOOKAHEAD`, `WORLD_CELLS` (a NOMINAL square for
`get_dims`, not an edge), `OCCL_MIN_DIST`, `OCCL_BIAS`. The camera is always the one the scene is
drawn with, the material always `glsl.gdshader`, frustum culling always on.

## Biomes

A biome is a 0..1 **mask** of world-XZ value noise (`TerrainBiomes.cv_noise`, handed to the masks
as `biomes.noise`). Layers stack in this order:

```
base DESERT ↔ MEADOW  →  SALT FLATS on the desert  →  CANYON  →  MOUNTAINS
```

| Group | Settings |
|---|---|
| Desert / Meadow | `biome_scale`, `biome_bias`, `biome_blend`, `biome_contrast`, `color_sand`, `color_grass`, `dune_wavelength`, `desert_flatten` |
| Salt flats | `salt_scale`, `salt_threshold`, `salt_edge`, `color_salt` |
| Canyon | `canyon_scale`, `canyon_threshold`, `canyon_edge`, `color_canyon`, `canyon_band_height`, `canyon_butte_scale` |
| Mountains | `mountain_scale`, `mountain_threshold`, `mountain_edge` |
| Snow / rock | `color_snow`, `snow_frac`, `snow_blend_frac`, `color_rock`, `rock_threshold`, `rock_blend` |
| Grass | `grass_density`, `grass_height`, `sand_grass`, `grass_shade` |

- Every layer is always on. `mask_offset` is not a setting: it is worked out from the seed
  (`offset_for_seed`) wherever a world is built.
- Heights in metres follow the world's Height, not knobs: dunes, a mountain's rise, the gorge depth
  (`terrain_gen.prepare_sampling`) and the snow line (`snow_frac` × Height).
- Rock follows SLOPE, snow follows the mountain mask AND height, grass grows on the meadow and,
  sparser, on sand (`sand_grass`).
- `canyon_band_height` sizes both the colour strata and the geometry terraces.
- A new biome is a shader edit too: each layer's colour is a `mix()` in `glsl.gdshader`'s `vertex()`.

The masks are baked into the vertex COLOR per vertex (`ChunkTerrain._biome_colour`): `.g` canyon,
`.b` meadow, `.a` mountain, and `.r` carries two things — the vertex's border code (0 inside its
node, 1 on a border along x, 2 along z) and the salt flat: `EDGE_STEP` × code + `SALT_SPAN` × salt.

The grass is the same function of the world point on every level (`blade_at` in the shader): each
vertex lifted straight up, a border vertex at an odd metre taking the mean of its two neighbours
along the border, so a seam between any two levels lifts alike whenever each side was built. It
fades out before level 2 begins (`ChunkTerrain.grass_fade`).

## Runtime API

```gdscript
terrain.terrain_height_at(world_pos: Vector3) -> float  # ground height under a world point
terrain.ground_sample(world_pos: Vector3) -> Vector3    # (height, dh/dx, dh/dz): the same patch, with its slope
terrain.biome_at(world_pos: Vector3) -> Vector3         # (canyon, meadow, mountain) masks
terrain.salt_at(world_pos: Vector3) -> float
terrain.world_height() -> float                         # the Height the world was built with
terrain.terrain_is_ready                                # the near ground is up (a bool and a signal, terrain_ready)
terrain.set_collision_streaming(on: bool)
terrain.is_point_hidden(world_pos: Vector3, height := 1.0, was_hidden := false) -> bool  # behind a hill?
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
`COLLISION_LOOKAHEAD` seconds. Moving bodies (RigidBody3D, CharacterBody3D) are found through the
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
- **Compute in a batch, land on a budget.** The pool computes `BUILD_BATCH` chunks at once; the
  main thread lands at most `APPLY_BUDGET` meshes a frame (none of that while loading).
- **A node is hidden only when other ground covers it** (`_covered`): a LOD change is a
  replacement still in the queue, and hiding the old node at once opened a hole.
- **One material, no instance uniforms**: the grass is the same function of the world point on
  every level. An instance uniform on a chunk takes 16 slots of the global shader buffer each, and
  there are hundreds of chunks.
- **Behind a hill reads the drawn ground** (`is_point_hidden`): the heights the drawn node's mesh
  was built from, never the generator - cheaper, and what the screen shows.

## Shader reference

`glsl.gdshader`, worn by the node's `surface_material` (`terrain_shader.tres`), where every uniform
shows in the inspector. The node draws with a copy of that material, into which the biomes write the
colours, snow, rock, sand grass, canyon bands, grass density/height/shade and the detail texture
(`TerrainBiomes.apply_to_material`) and the game the grass fade, the trample and the corruption map:
tune those in the biomes, everything else on the material.

- **Texture**: `tile_world_size` (the colour noise's cell), `ground_detail`,
  `detail_world_size`, `ripple_strength`, `grass_detail`, `patch_strength`.
- **Colours / terrain / biomes**: `color_*`, `snow_line`, `snow_blend`, `rock_threshold`,
  `rock_blend`, `color_variation`, `sand_grass`, `canyon_band_h`, `crack_strength`.
- **Grass**: `grass_density`, `grass_height`, `grass_shade`, `grass_fade` (set by the node).
- **Trample**: `trample_map`, `trample_center`, `trample_size` (driven by the game's `grass.gd`).
- **Corruption**: `corrupt_amount`, `corrupt_map`, `corrupt_world_center`, `corrupt_world_size`,
  `glitch_cell`, `glitch_speed`, `corrupt_cyan`, `corrupt_magenta`, `corrupt_glow`.
- **Haze**: the global uniforms `world_haze` and `haze_range` (project settings), written to FOG.

## Troubleshooting

**Nothing appears.** The node builds round the camera the scene is DRAWN with — check one is
`current`.

**A machine falls through at load.** Something asked for a height before `terrain_is_ready`;
wait for it by the clock.

**A hole opens while driving.** See `_covered` above: if you touch that rule, this is what breaks.

**The editor preview is somewhere else.** It builds round the editor viewport's camera, which the
plugin hands over when the mouse moves over the 3D view.
