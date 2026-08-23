# LiteTerrain

**Version 1.3** · Godot 4 · tuned for mobile

Lightweight heightmap terrain. One node builds its own collision body, collision
shape and render mesh, then keeps a large map affordable through quadtree LOD and
streaming collision. An editor dock creates, generates, sculpts and bakes it.

Biomes — desert, meadow, canyon, mountains — live in a single resource that drives
the landform, the masks and the colours at once, so a biome's shape cannot drift
away from how it looks.

Built and tuned on an Adreno 610, a low-end mobile GPU, so the defaults lean
towards performance.

## Contents

- [Requirements](#requirements)
- [Install](#install)
- [Quick start](#quick-start)
- [The terrain node](#the-terrain-node)
- [Biomes](#biomes)
- [Appearance](#appearance)
- [Runtime API](#runtime-api)
- [Physics and collision](#physics-and-collision)
- [Sculpting](#sculpting)
- [Generating terrain](#generating-terrain)
- [Baking and shipping a big map](#baking-and-shipping-a-big-map)
- [Performance tuning](#performance-tuning)
- [How it works](#how-it-works)
- [Property reference](#property-reference)
- [Shader reference](#shader-reference)
- [Troubleshooting](#troubleshooting)
- [Upgrading from 1.0](#upgrading-from-10)

## Requirements

- Godot 4.x.
- Renderer: Compatibility (GLES3) recommended. It also runs on Forward+.

## Install

1. Copy the `LiteTerrain` folder into your project's `res://addons/`.
2. Project Settings → Plugins → enable LiteTerrain.
3. A LiteTerrain dock appears on the left. Everything is driven from there.

## Quick start

1. Open a 3D scene.
2. Press **Create Terrain Node**. This bakes a flat 128×128 heightmap into the addon
   folder (`terrain_height.res`) and drops in a ready terrain: a StaticBody3D running
   the `LiteTerrain` script with the terrain shader already applied. It starts in
   image mode with streaming collision on.
3. Select the node and shape it:
   - **Generate Terrain** builds noise-based terrain. The dock shows the five settings
     that decide what a world is — seed, size, height, feature size, and which biomes
     exist — and folds the rest away under **Advanced** (octaves, plains power, ridge
     sharpness, smoothing and the canyon shape). Generate rebuilds the whole heightmap,
     so hand sculpting is lost.
   - Or sculpt by hand with **Raise**, **Lower** and **Flatten**. Paint with the left
     mouse button in the viewport; radius and strength are in the dock. Each stroke is
     one undo step (Ctrl+Z / Ctrl+Y).
4. Press **Bake → files** to write everything the runtime needs at once: the heightmap
   (`terrain_height.res`), a preview mesh (`terrain_mesh.res`) and a greyscale PNG
   (`terrain_heightmap.png`, useful for a minimap).

The dock remembers its brush and generation settings per project.

## The terrain node

The class is `LiteTerrain` (`map.gd`). It extends StaticBody3D and needs a
`CollisionShape3D` and a `MeshInstance3D`, both of which it creates itself as
internal children — they stay out of the scene tree and out of the `.tscn`, so a
LiteTerrain is one clean node.

The properties you will touch most often:

| Property | Default | What it does |
|---|---|---|
| `camera` | empty | Optional. Left empty, the terrain uses the currently active camera and follows camera switches. Set it only to force LOD from one specific camera. |
| `biomes` | auto | The [biome resource](#biomes). Empty means a default set is created at runtime; save it as a `.tres` to edit it. |
| `surface_material` | addon `terrain_shader.res` | The terrain material. Texture and quality settings live on it. |
| `use_image_data` | `true` | On: heights live in an R32F image (`heightmap_path`) and collision streams under moving bodies. Off: one HeightMapShape3D holds the whole map. |
| `heightmap_path` | addon `terrain_height.res` | The R32F resource loaded in image mode. Hidden in the inspector when image mode is off. |
| `triangle_size` | `1 (detailed)` | Grid cell size at the finest LOD. See [Performance tuning](#performance-tuning). |
| `max_render_distance` | `1400.0` | How far terrain is drawn. Match it to your visibility distance. |

Full list in the [Property reference](#property-reference).

## Biomes

Everything about biomes lives in one `TerrainBiomes` resource, assigned to the node's
`biomes` property. The landform generator, the CPU masks and the material colours all
read the same resource, so a biome's terrain and its colour always agree.

A biome is a 0..1 **mask** of world-XZ noise. Layers stack in this order:

```
base DESERT ↔ MEADOW split  →  CANYON on top  →  MOUNTAINS on top
```

Each optional layer has an **enable flag**. Turning one off zeroes its mask, so it
leaves both the colour and the landform — a world with `canyon_enabled = false` has
no canyons carved and no terracotta anywhere.

| Group | Settings |
|---|---|
| Desert / Meadow | `biome_scale`, `biome_bias`, `biome_blend`, `biome_contrast`, `color_sand`, `color_grass`, `dune_amp`, `dune_wavelength`, `desert_flatten` |
| Canyon | `canyon_enabled`, `canyon_scale`, `canyon_threshold`, `canyon_edge`, `color_canyon`, `canyon_band_height`, `canyon_butte_scale` |
| Mountains | `mountain_enabled`, `mountain_scale`, `mountain_threshold`, `mountain_edge`, `mountain_rise` |
| Snow / rock | `color_snow`, `color_rock`, `rock_threshold`, `rock_blend` |
| Grass | `grass_density`, `grass_height`, `sand_grass`, `grass_shade` |

Notes:

- Snow follows the **mountain** layer, not altitude. High ground outside a mountain
  region is not white.
- Rock is driven by **slope** (`rock_threshold`), independently of the biome.
- Grass grows in the meadow only. `sand_grass` lets a little into the desert; rock,
  canyon and mountains never carry grass.
- `canyon_band_height` sizes both the colour strata and the geometry terraces — the
  dock's terrace slider edits this same value, which is why they cannot desync.

Changing a biome's **shape** parameters (scales, thresholds) requires re-running
**Generate Terrain**: the masks are baked into vertex colours and into the heights.
Changing **colours** takes effect immediately.

**Adding a biome of your own** takes a shader edit. Each layer's colour is written
out in `glsl.gdshader`'s `vertex()` where `v_base_col` is assembled, so a new layer
means a new mask in the resource plus a new `mix()` there.

## Appearance

Biome colours and grass come from the biomes resource. What is left on the material
(`surface_material`, the bundled `terrain_shader.res`) is texture and quality:

| Shader parameter | Default | What it does |
|---|---|---|
| `tile_texture` | `Dark/6.png` | Surface tile texture. |
| `texture_blend` | `0.06` | How much the tile texture shows over the biome colours. `0` is colours only. |
| `tile_world_size` | `31.0` | World units per texture tile. Tiling is computed from world position, so it is automatic at any map size, in game and in editor. |
| `color_variation` | `0.06` | Per-pixel colour noise. |
| `low_quality` | `false` | Drops the per-pixel noise and the tile fetch for weak GPUs. |
| `corrupt_*` | — | Optional glitch-zone overlay, driven by an external state map. `corrupt_amount = 0` switches it off entirely, including its vertex texture fetch. |

Full list in the [Shader reference](#shader-reference).

## Runtime API

```gdscript
terrain.terrain_height_at(world_pos: Vector3) -> float   # ground height under a world point
terrain.get_dims() -> Vector2i                           # heightmap width and depth in cells
terrain.terrain_is_ready -> bool                         # near terrain built
terrain.terrain_ready                                    # signal, same thing
```

Use `terrain_height_at` to place objects on the ground instead of dropping them:

```gdscript
body.global_position.y = terrain.terrain_height_at(body.global_position) + clearance
```

`collision_debug_at(world_pos) -> String` returns one line describing the streaming
collision at a point — whether a tile exists there, how many are live, how many
bodies are tracked. Useful when something falls through and you want a fact rather
than a guess.

### Editing the ground at runtime

```gdscript
terrain.flatten_area(center: Vector3, half_extent: Vector2, height: float,
                     feather := 4.0, record := true) -> void
terrain.ground_edits() -> Array          # the edits so far, plain dictionaries, JSON-ready
terrain.apply_ground_edits(list: Array)  # replay them, once, on load
terrain.bake_heights() -> bool           # write the current heights to user://terrain_height.bin
terrain.reset_heights()                  # forget every edit and go back to the shipped map
```

`flatten_area` levels a **rectangular** pad — buildings are oblong, and a circle sized
to fit one strips three times as much ground. It edits the heights, rebuilds the chunks
it touched and drops the streaming collision there so it is re-cut against the new
surface.

Persistence is deliberately two mechanisms, not one. The **edit list** is four numbers
per edit, costs nothing to keep, and survives a crash, so it is what a game saves during
a session. The **baked file** is the whole heightmap, so it is written once at load time
— after the edits have been replayed — and afterwards the list is empty because the
ground itself is now shaped that way. A long loading screen is the right place for a
15 MB dump; mid-session it shows up as a hitch.

Replay edits **before** you restore anything that stands on them, or a building put back
first ends up hovering. Every edit carries a running sequence number and the baked file
remembers the last one it contains: without that, an edit still sitting in a game save
(the player quit before the first autosave) would be applied a second time on top of
already-flat ground, and the pad's rim would get steeper every session.

The baked file lives in `user://`, so it is per-device application data: it is never in
the project and never in an exported PCK. `res://` keeps the shipped map, and
`reset_heights()` returns to it.

The node also exposes the sculpt and data API the dock uses (`is_image_mode`,
`get_heights`, `set_heightmap`, `apply_brush`, `raycast_heightmap`, `apply_heightmap`)
if you want to build your own tooling.

## Physics and collision

The terrain gives itself collision; you never add a CollisionShape3D by hand.

By default it runs in image mode with streaming collision: instead of one giant shape,
a small collision window follows each moving body. That is what keeps a large map
cheap.

Bodies are discovered automatically — every moving physics body in the scene
(RigidBody3D, VehicleBody3D, CharacterBody3D) gets a window sized by
`collision_radius`, found through the tree's `node_added`/`node_removed` signals with
no per-frame polling and no node paths to configure.

Things to know:

- Only terrain inside an active window has collision. A body far from any tracked body
  sits on nothing. Raise `collision_radius` if a fast body outruns its window.
- A body riding on another body (a part welded to a vehicle) is skipped — the parent's
  window already covers it.
- Area3D and StaticBody3D are never tracked.
- `HeightMapShape3D` works with both Godot Physics and Jolt; it was tuned on Jolt.
  Jolt treats a heightfield's outer edge as an active edge, which a wheel can catch
  on, so `collision_overlap` grows each tile into its neighbours and buries that edge
  under real surface.

## Sculpting

Select the terrain node, pick a mode in the dock and paint with the left mouse button.

- **Raise** and **Lower** move the surface under the brush.
- **Flatten** pulls towards the average height inside the brush without overshooting.
- Radius and Strength come from the dock sliders. Radius also responds to the mouse
  wheel over the viewport while the terrain is selected, over the same range.
- Each stroke, mouse-down to mouse-up, is one Undo/Redo step.

In image mode the preview mesh and the heightmap file update on mouse-up, so undo and
redo stay in sync with what is on disk.

## Why generation is fast (and what to keep that way)

Every full-map sweep in the addon is threaded through `WorkerThreadPool.add_group_task`, one
task per ROW or per CHUNK: the noise fill, the canyon carve, the blur passes, the runtime chunk
builds, the macro merges and the editor rebuilds. The rule that makes it safe is always the
same — a worker writes only into its own slice of an array that was sized beforehand, reads
data nobody mutates, and never touches the scene tree.

The other half is not threading at all but **not doing the work twice**. Biome masks come from
a lattice sampled every `MASK_STEP` cells and read back bilinearly; without it every vertex
derives its biome from three noise calls of its own, which on a 1982² map is around twelve
million calls against a hundred and ninety thousand. The editor rebuild used to skip building
that lattice, and that alone was most of the minutes a full generate took.

## Generating terrain

**Generate Terrain** fills the map with layered noise, then carves canyons into the
result.

| Parameter | Default | Meaning |
|---|---|---|
| Seed | 42 | Same seed, same terrain. |
| Scale | 150 | Size of the land masses. |
| Octaves | 6 | Detail layers in the base noise. |
| Plains Power | 2.6 | Higher flattens the plains and sharpens the peaks. |
| Mountains | 0.8 | How strongly ridges are added on high ground. |
| Ridge Sharpness | 2.5 | How knife-edged the ridges are. |
| Amplitude | 30 | Maximum height in world units. |
| Smooth Passes | 1 | Box-blur passes, to soften spikes. |
| Map Size | 0 | Target size in image mode. `0` keeps the current size — this is how the map grows. |
| Canyons | on | Master switch for carving. Canyons also need `canyon_enabled` in the biomes. |
| Plateau height / Canyon floor / Stratum height / Riser steepness / Gorge width / Channel frequency | — | Badlands shaping. Stratum height edits `canyon_band_height` on the biome resource. |

Both heavy noise passes run across the WorkerThreadPool, one row per task.

Generation replaces the whole heightmap and writes it to the R32F file, so both the
runtime and a reopened editor load the new terrain.

## Baking and shipping a big map

1. Keep `use_image_data` on (the default).
2. Press **Bake → files** to write `terrain_height.res`, `terrain_mesh.res` and the PNG.
3. Save the scene.

The runtime loads the baked `.res` and streams a small collision window under tracked
bodies, so the scene file stays small and nothing heavy loads at startup. The node's
children are internal and are not saved into the scene, so there is nothing to detach
by hand.

## Performance tuning

Already built in: quadtree LOD, a resident macro grid with streamed chunks so memory
stays bounded, streaming collision, and frustum plus range culling.

Levers, roughly in order of payoff:

1. **`triangle_size`** (node). The grid cell size at the finest LOD, scaling the whole
   hierarchy at once. `2` is a quarter of the vertices, `4` a sixteenth. The terrain
   shader does real work per vertex, so this is substantial — but note that grass is a
   displaced vertex, so coarsening thins the grass too.
2. **`scaling_3d/scale`** (Project Settings → Rendering). The single biggest lever when
   fill-bound. `0.75` is a good mobile default; compare `0.5` against `1.0` to find out
   how fill-bound you actually are.
3. **`max_render_distance`** (node). Terrain drawn beyond what the player can make out
   is pure cost. If you use fog, match this to it.
4. **Directional shadows.** Expensive on mobile. Lower the atlas size and max distance,
   or switch them off, and compare.
5. **`grass_density` / `grass_height`** (biomes). Grass is a vertex cost; `0` density
   removes it.
6. **`low_quality`** (material). Drops the per-pixel noise and the tile fetch. All
   pixels take the same branch, so it is cheap on mobile GPUs.

## How it works

For anyone modifying the plugin.

### Data model: image mode versus shape mode

The heightmap is a flat float array (`md`), `w` by `d`.

- **Image mode** (`use_image_data` on, the default): heights come from an R32F image
  saved as a `.res`, and that image is the single source of truth for both the render
  mesh and the collision. In the editor, sculpting edits the array directly and
  hit-testing ray-marches the heightmap, so no physics shape is needed while you work.
- **Shape mode** (off): one HeightMapShape3D holds both data and collision for the
  whole map. Simple, but it does not scale.

### Chunks and quadtree LOD

The map is split into `chunk_size` squares, each prebuilt at several LOD levels where
the vertex step doubles per level (`LOD_STEPS` is `[1, 2, 4]`, multiplied by
`triangle_size`). Thresholds are `lod_distance_0` and `lod_distance_1`.

Above that sits a quadtree over the macro grid. Selection descends from the root every
frame; any subtree outside the frustum or beyond `max_render_distance` is pruned
without being visited, so per-frame cull cost scales with the visible area rather than
the map size. Internal nodes carry a coarse merged mesh, so distant terrain collapses
into a handful of big low-poly meshes.

A chunk flatter than `flat_lod_error` is allowed a coarser mesh at any distance: on
level ground large triangles follow the surface almost exactly.

Neighbouring chunks at different LODs would crack at the seam, so each chunk carries a
stitch signature encoding its own step and the step on each of its four borders, and
is rebuilt whenever that signature changes. This makes stitching self-healing
regardless of the order events arrive in.

**The ground is drawn three different ways at once**, and the seam contract has to cover
all three: individual chunk meshes (steps 1/2/4), one merged mesh per macro group
(step 4), and one coarse mesh per internal quadtree node (step = its macro span, so 8,
16, 64… samples per quad). A fourth exists but never renders at runtime — the editor's
single full-map mesh.

`_neighbour_step()` is where a border learns what is on the other side, and it must
answer for whichever of the three actually draws that area right now — the quadtree node
first (`_node_step_covering` walks down from the root), then an active macro, then the
chunk itself. A chunk hidden under a node keeps a stale LOD, so asking it directly
returns a number that means nothing.

Snapping is also guarded by alignment (`_snap_ok`): it interpolates between two samples
the coarse neighbour is assumed to have, which holds on the chunk grid but not for every
quadtree step, and moving a border to a height nothing matches is worse than the crack.

**Flat ground is merged into big quads.** A canyon floor or a mesa top used to cost two
triangles per cell for a surface one quad describes exactly, so the chunk builder runs a greedy
pass: a run of cells that is FLAT AT THE SAME HEIGHT becomes a single quad, the way block-world
renderers merge their faces. Only exact flatness qualifies (`MERGE_EPS`, a millimetre) — the
dropped interior samples were already lying in that plane, so nothing moves, the surface cannot
drift away from the collision, and no T-junction can open a crack. Anything sloped, and any
sand carrying wind ripples, is not flat and is left alone. The chunk's outer ring never merges:
those vertices are the seam. Vertices nothing points at afterwards are dropped in one remap
pass, so the saving is in memory as well as in triangles.

**Every step is a power of two, and that is what makes the seam exact.** Snapping reads the
two coarse samples a border vertex falls between, which is only meaningful if the coarse
grid is a superset of the fine one and starts on it. Chunk steps (2/4/8 at
`triangle_size = 1`) divide `chunk_size`, and node steps are rounded DOWN to a power of two
capped at the macro origin granularity (`_qt_step`), so both hold everywhere. A node with a
three-macro span used to take step 24, the assumption broke, and the seam simply did not
meet. Rounding down leaves such a node slightly denser than it needs to be — a root node
goes from ~64 quads to ~960, which costs nothing.

There is deliberately **no skirt**: a dropped wall along every seam costs triangles across
the whole terrain and looks wrong wherever it peeks. The seam is closed by making the two
meshes meet, not by hiding the gap. The other half of that is timing — a chunk re-stitches
in the same pass in which a neighbouring node or macro appears (`_qt_apply` forces the
stitch loop when the coarse set changed), instead of waiting for the throttled LOD pass.

This is a per-border seam skirt, and is unrelated to the old quadtree-node skirt
removed in 1.1 — that one hung visibly off the edges of quadtree nodes.

### Macro chunks

Groups of `MACRO_SIZE` × `MACRO_SIZE` chunks (4×4 = 16) merge into one MeshInstance3D
with shadows off, for terrain past `lod_distance_1`. Sixteen draw calls become one,
plus the matching shadow passes.

### Streaming collision

Collision is a grid of tiled HeightMapShape3D cells. Each tracked body marks the cells
within `collision_radius` as needed, and bodies sharing a cell share its shape. Tile
size is `collision_cell`.

Tiles are grown by `collision_overlap` cells on each side so they overlap, burying each
tile's boundary edge under the neighbour's real surface. The overlap carries real
heights: a dropped skirt cannot be used here, because a neighbour is sometimes not
streamed in yet and the skirt would become the only surface there — a pit.

A tracked body carrying the metadata flag `asleep` is skipped and gets no ground under
it. That is the hook a game uses for dormant far-away actors: they are frozen anyway, so
paying for a collision window under each of them is waste. Clear the flag before you
wake one, or it will fall.

### Biome masks

The masks are computed on the CPU (`map.gd`), once, on a sparse lattice with a
`MASK_STEP` spacing, and read back with bilinear interpolation. The layout is a pure
function of (x,z) and the masks are hundreds of world units across, so the lattice
costs orders of magnitude fewer noise calls than one evaluation per vertex, with no
visible difference. It is built before the threaded mesh build and never mutated,
which makes reading it from worker threads safe.

The results are baked into the vertex COLOR: `.g` canyon, `.b` meadow, `.a` mountains,
with `.r` reserved for the grass seam mask. The shader only reads them. This is why a
disabled biome vanishes on its own with no flag in the shader, and why the generator
and the colour cannot disagree.

### The shader

`glsl.gdshader` assembles the zone colour and the slope fade into rock in the **vertex**
stage (`v_base_col`) and interpolates it: the terrain is fill-bound and there are
orders of magnitude fewer vertices than pixels. The fragment stage keeps only what has
to be per-pixel — the colour noise and the tile texture, both skipped by `low_quality`.

Grass is a vertex displacement along the normal, gated by `lod_grass_enabled`, which is
1 only on the near LOD-0 material. The optional `trample_map` presses it down under
objects and defaults to black (no effect).

Two material variants (`_mat_lod0`, `_mat_lod_high`) are duplicated once at build time
and swapped per instance, rather than using `set_instance_shader_parameter` — that
allocates from the global shader variables buffer, whose GLES3 limit of 4096 hundreds
of chunks would overflow instantly.

### Editor state

Dock settings live in the editor's per-project metadata (inside `.godot/`, not your
repository), so each machine keeps its own values across sessions.

## Property reference

Culling and drawing:

| Property | Default | What it does |
|---|---|---|
| `enable_frustum_culling` | `true` | Skip chunks outside the camera frustum. |
| `frustum_margin` | `-0.05` | Frustum test margin. Negative culls slightly harder. |
| `max_render_distance` | `1400.0` | Draw distance for chunks. |
| `enable_occlusion_culling` | `false` | Hide chunks below the terrain horizon. Off by default: the horizon method false-culls on a steep top-down camera. |
| `occlusion_min_dist` | `40.0` | Chunks closer than this are never occlusion-culled. |
| `occlusion_bias` | `1.5` | Added to a chunk top before the horizon test. Higher is more conservative. |
| `occlusion_samples` | `8` | Heightmap samples per camera-to-chunk ray. |

LOD and chunks:

| Property | Default | What it does |
|---|---|---|
| `enable_lod` | `true` | Turn LOD off without changing the distances. |
| `lod_distance_0` | `40.0` | Under this distance a chunk is full resolution. This also bounds the grass, which only renders on the LOD-0 material. |
| `lod_distance_1` | `80.0` | Under this distance a chunk uses a quarter of the triangles; past it, the merged macro mesh takes over. |
| `lod_distance_2` | `160.0` | Kept for the editor LOD preview. |
| `flat_lod_error` | `0.35` | How far a chunk may depart from flat and still be drawn coarsely. `0` disables it. |
| `triangle_size` | `0` (= 1) | Grid cell size at the finest LOD: 1, 2 or 4. |
| `chunk_size` | `16` | Cells per chunk side. |
| `editor_lod` | `false` | Off bakes one full-resolution merged mesh in the editor; on builds the whole map with LOD and rebuilds only once the editor camera settles. |

Streaming and collision:

| Property | Default | What it does |
|---|---|---|
| `use_image_data` | `true` | Image mode master switch. |
| `heightmap_path` | addon `terrain_height.res` | The R32F resource loaded in image mode. |
| `enable_streaming_collision` | `true` | Stream a small collision window under tracked bodies. |
| `stream_batch_size` | `8` | Chunks meshed per streaming batch. Lower means fewer hitches. |
| `collision_cell` | `16` | Heightmap cells per collision tile. |
| `collision_radius` | `8` | Cells covered around each tracked body. |
| `collision_overlap` | `8` | Cells each tile is grown on every side. |

Biomes and appearance:

| Property | Default | What it does |
|---|---|---|
| `biomes` | auto | The `TerrainBiomes` resource. See [Biomes](#biomes). |
| `surface_material` | addon `terrain_shader.res` | Texture and quality settings. |

## Shader reference

Parameters in `glsl.gdshader`, by inspector group. Colours and grass are overwritten
from the biomes resource at build time — edit them there, not here.

- **Quality**: `low_quality`.
- **Texture**: `tile_texture`, `tile_world_size`, `texture_blend`.
- **Colors**: `color_sand`, `color_grass`, `color_snow`, `color_rock` *(from biomes)*.
- **Terrain**: `rock_threshold`, `rock_blend` *(from biomes)*, `color_variation`.
- **Biomes**: `sand_grass`, `color_canyon`, `canyon_band_h` *(from biomes)*.
- **Grass**: `grass_density`, `grass_height`, `grass_shade` *(from biomes)*,
  `lod_grass_enabled` *(driven by the plugin)*.
- **Trample**: `trample_map`, `trample_center`, `trample_size` *(driven at runtime)*.
- **Corruption**: `corrupt_amount`, `corrupt_map`, `corrupt_world_center`,
  `corrupt_world_size`, `glitch_cell`, `glitch_speed`, `corrupt_cyan`,
  `corrupt_magenta`, `corrupt_glow`.

## Troubleshooting

**The map is flat or wrong after reopening the project.** In image mode the runtime
loads `heightmap_path`. If that file is missing the node warns in the output and falls
back to the embedded shape. Press **Bake → files**.

**A body falls through the terrain.** With streaming collision on, ground only exists
inside a window under a tracked body. Only moving bodies are tracked (RigidBody3D,
VehicleBody3D, CharacterBody3D) — not Area3D or StaticBody3D. Call
`collision_debug_at(pos)` to get a one-line answer about what was actually there.

**A fast body outruns its collision.** Raise `collision_radius`.

**The tile texture does not show.** Raise `texture_blend` above `0` on the material and
make sure `low_quality` is off, since low quality skips the tile fetch.

**Biome colours ignore the material.** They are meant to: `TerrainBiomes` writes them
into the material at build time. Edit the resource.

**A biome's shape did not change.** Shape parameters are baked into the heightmap and
the vertex colours. Re-run **Generate Terrain**.

## What is new in 1.3

- **Runtime ground editing**: `flatten_area`, plus the two-mechanism persistence around it
  (`ground_edits` / `apply_ground_edits` / `bake_heights` / `reset_heights`). See
  [Runtime API](#runtime-api).
- **LOD seam skirts**: a chunk bordering a different LOD drops a vertical wall along that
  border, so no sky shows through during the frame or two before both sides are rebuilt.
- **`asleep` bodies get no collision window**: a hook for dormant far-away actors.

## Upgrading from 1.0

- Biome parameters moved out of the shader and the generator into the new
  `TerrainBiomes` resource. **If you had customised biome colours on the material, move
  them to the resource** — the material's copies are overwritten at build time. Every
  other value keeps its 1.0 default, so an untouched project looks the same.
- Thirteen shader uniforms that nothing read were removed: `biome_scale`,
  `biome_blend`, `biome_grass_bias`, `canyon_scale`, `canyon_threshold`, `canyon_edge`
  (the shader never computed biome noise — the masks arrive baked into COLOR),
  `height_grass_start`, `height_snow_start`, `zone_blend` (height zones were replaced
  by the biome masks; snow is now the mountain layer), `grass_min_height`,
  `grass_max_height`, `bend_radius` and `snow_grass`. Saved values for them are simply
  ignored.
- The chunk-mesh skirt was removed. `QT_SKIRT` had been 0 since it was found to hang
  visibly off the edges of quadtree nodes, so the code was unreachable.
- Code comments and the editor dock are English throughout.

## Notes

- Designed for the Compatibility (GLES3) backend.
- The bundled `Dark` folder holds sixteen tile textures; the default is `Dark/6.png`.
