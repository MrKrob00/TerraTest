# LiteTerrain

**Version 2.0** · Godot 4 · tuned for mobile

Procedural terrain stored and drawn in CHUNKS. One node builds the whole world from a
seed: no heightmap file, no world-sized array, no edge. A chunk asks the generator for
its own vertices, LOD merges four chunks into one mesh instead of decimating anything,
and collision is cut only under the bodies that need it.

Biomes — desert, meadow, canyon, mountains — live in a single resource that drives
the landform, the masks and the colours at once, so a biome's shape cannot drift
away from how it looks.

Built and tuned on an Adreno 610, a low-end mobile GPU, so the defaults lean
towards performance.

> **2.0 removed the baked half.** Version 1.x also carried a heightmap node
> (`LiteTerrain`/`map.gd`) with a sliding window of heights, a sculpt brush, noise
> generation into an array, and baking to `.res`/`.bin`/PNG. All of it is gone: a
> procedural world has nothing to sculpt and nothing to bake. Measured on the way out —
> one 256-cell map on the old node took 8.2 s to become ready, the same ground on the
> chunked node takes 3.9 s.

## Contents

- [Quick start](#quick-start)
- [The terrain node](#the-terrain-node)
- [Biomes](#biomes)
- [Appearance](#appearance)
- [Runtime API](#runtime-api)
- [Physics and collision](#physics-and-collision)
- [Choosing a world](#choosing-a-world)
- [Performance tuning](#performance-tuning)
- [How it works](#how-it-works)
- [Property reference](#property-reference)
- [Shader reference](#shader-reference)
- [Troubleshooting](#troubleshooting)

## Requirements

- Godot 4.x.
- Renderer: Compatibility (GLES3) recommended. It also runs on Forward+.

## Install

1. Copy the `LiteTerrain` folder into your project's `res://addons/`.
2. Project Settings → Plugins → enable LiteTerrain.

The plugin has no dock. It adds one panel to the inspector of a selected terrain
(the seed map) and hands the node the editor viewport camera; everything else is on
the node itself.

## Quick start

1. Open a 3D scene and add a **ChunkTerrain** node (Add Node, by name — the script has a
   `class_name`).
2. Give it a `TerrainBiomes` resource in `biomes`, or leave it empty and it makes one.
3. Look at the top of its inspector: the map of the world for the current seed. Step
   through seeds until you like where the regions land, then press **Показать в сцене** to build the
   real ground around the editor camera.

That is the whole workflow. There is nothing to generate into a file and nothing to bake:
the ground IS the seed, and the same seed gives the same world in the editor and in the
running game.

## The terrain node

The class is `ChunkTerrain` (`chunk_terrain.gd`). It extends StaticBody3D and creates
everything it needs itself — chunk meshes as internal children, collision bodies per
tile — so the `.tscn` stays a single node.

Two properties decide what world it is:

| Property | What it does |
|---|---|
| `forced_seed` | The seed. One number, and the entire world follows from it. |
| `follow_world_settings` | On, the node takes the seed from an autoload `G` (`G.world_seed`) instead — that is how a game gives each save slot its own world. Off, `forced_seed` is used, which is what a menu backdrop or an editor preview wants. |

`camera` exists but should stay EMPTY: the node uses whichever camera the scene is drawn
with (`get_viewport().get_camera_3d()`), so it follows camera switches and spring arms by
itself. Set it only to drive LOD from a camera the scene is NOT drawn with.

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

The value noise the masks are built on lives in the same resource
(`TerrainBiomes.cv_noise`, passed to the mask calls as `biomes.noise`). Callers used to
carry their own copies of those eight lines — that is how a carved region and a painted
region stopped being the same region once already.

| Group | Settings |
|---|---|
| Desert / Meadow | `biome_scale`, `biome_bias`, `biome_blend`, `biome_contrast`, `color_sand`, `color_grass`, `dune_amp`, `dune_wavelength`, `desert_flatten` |
| Canyon | `canyon_enabled`, `canyon_scale`, `canyon_threshold`, `canyon_edge`, `color_canyon`, `canyon_band_height`, `canyon_butte_scale` |
| Mountains | `mountain_enabled`, `mountain_scale`, `mountain_threshold`, `mountain_edge`, `mountain_rise` |
| Snow / rock | `color_snow`, `snow_frac`, `snow_blend_frac`, `color_rock`, `rock_threshold`, `rock_blend` |
| Grass | `grass_density`, `grass_height`, `sand_grass`, `grass_shade` |

Notes:

- Snow follows the **mountain** layer, not altitude. High ground outside a mountain
  region is not white.
- Rock is driven by **slope** (`rock_threshold`), independently of the biome.
- Grass grows in the meadow only. `sand_grass` lets a little into the desert; rock,
  canyon and mountains never carry grass.
- `canyon_band_height` sizes both the colour strata and the geometry terraces — the
  colour strata and the geometry terraces read the same number, so they cannot desync.

Changing a biome's **shape** parameters (scales, thresholds) changes the world itself, so the
chunks already built keep the old shape until they are rebuilt — in the editor, press the
preview button again. Changing **colours** takes effect immediately.

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
terrain.world_height() -> float                          # the amplitude the world was built with
terrain.terrain_is_ready -> bool                         # the near ground is up
terrain.terrain_ready                                    # signal, same thing
terrain.set_collision_streaming(on: bool)                # collision on or off wholesale
terrain.stop_generation()                                # cancel the running tasks (before freeing)
```

Use `terrain_height_at` to place objects on the ground instead of dropping them:

```gdscript
body.global_position.y = terrain.terrain_height_at(body.global_position) + clearance
```

WAIT FOR THE GROUND BY THE CLOCK, NOT BY FRAMES. `terrain_is_ready` turns true when the
threads have finished, and that is real seconds — a frame count is a race that is won or
lost by how fast the device happens to be:

```gdscript
var deadline := Time.get_ticks_msec() + 120_000
while is_instance_valid(t) and not t.terrain_is_ready and Time.get_ticks_msec() < deadline:
    await get_tree().process_frame
```

### Editing the ground at runtime

```gdscript
terrain.flatten_area(center: Vector3, half_extent: Vector2, height: float,
                     feather := 4.0, record := true) -> void
terrain.ground_edits() -> Array          # the edits so far, plain dictionaries, JSON-ready
terrain.apply_ground_edits(list: Array)  # replay them, once, on load
terrain.reset_heights()                  # forget every edit
```

`flatten_area` levels a **rectangular** pad — buildings are oblong, and a circle sized to
fit one strips three times as much ground. The edits are a LIST applied on top of the
generator in one function, so the mesh, the collision and a height query all see the same
ground; there is nothing to bake and no file to go stale.

Replay edits **before** you restore anything that stands on them, or a building put back
first ends up hovering. Every edit carries a running sequence number so replaying a save
twice cannot deepen a pad.

## Physics and collision

The terrain gives itself collision; you never add a CollisionShape3D by hand.

A collision tile IS a base chunk, cut from the same heights as the level-0 mesh, so under
near ground it costs nothing extra. Tiles have their OWN queue and it goes first: a tile is
what a machine drives on, a mesh is what it looks at, and behind one shared queue the ground
runs out every few metres.

Tiles are asked for along a body's CORRIDOR — where it is now plus where it will be in
`collision_lookahead` seconds — rather than by moving a window along behind it: at speed a
body outruns its own window.

Bodies are discovered automatically: every moving physics body in the scene (RigidBody3D,
VehicleBody3D, CharacterBody3D) is tracked through the tree's `node_added`/`node_removed`
signals — no per-frame polling and no node paths to configure.

Things to know:

- Only ground under a tracked body has collision. Raise `collision_radius` if something
  fast outruns its tiles.
- A body riding on another body (a part welded to a vehicle) is skipped — the parent
  covers it.
- Area3D and StaticBody3D are never tracked, and a sleeping body is dropped.
- `HeightMapShape3D` works with both Godot Physics and Jolt; it was tuned on Jolt.

## Choosing a world

There is no sculpt brush any more, and its absence is the design. A brush made sense while the
map was a file of heights somebody edited by hand; a procedural world has nothing to edit — it
has a SEED, and the only question is what that seed gives.

Select the terrain node and the answer is at the top of the inspector: a map of the regions for
that seed, redrawn as you step through seeds with ◀ ▶ or roll one with RND. It draws the BIOME
MASKS rather than the heights — a mask costs three noise samples per pixel, a height costs five
with blur and the canyon cut, and at 128×128 that is the difference between flipping through
seeds and waiting on each one. The regions are what you pick a seed for anyway; the relief
inside them varies far less between seeds than their layout does.

**Show in scene** then builds the real ground, with the real generator, around the editor
camera — nothing is written into the scene.

Under the map is a ruler of the distance rings (`view_distance`, `keep_radius`, `ready_view`
and the collision radius) drawn to scale. Four numbers in a list say nothing about their
proportion, and the proportion is the whole point: holding more in memory than is drawn is
waste, and waiting on load for more than is held is worse.


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

### Data model: there is none

There is no height array and no file. `LiteTerrainGen.height_at(wx, wz)` answers for a world
point — noise, a five-tap blur and the canyon cut — and `sample_grid` builds a grid out of it.
That is the only source of ground in the addon, which is why the world has no edge and memory
equals what is on screen.

Terrain edits (`flatten_area`) are a LIST applied on top of that answer in one function, so the
mesh, the collision and a height query cannot disagree.

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

The masks are computed on the CPU, once, on a sparse lattice with a
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

## Why this addon is shaped differently from HTerrain and Terrain3D

Both of the well-known Godot terrains build the mesh ONCE and never rebuild it. HTerrain keeps
a shared mesh per (LOD, seam) pair and Terrain3D uses a geometry clipmap re-centred on the
camera; in both, the heights arrive as a TEXTURE READ IN THE VERTEX SHADER, so editing terrain
costs a texture update and nothing else.

That is the better design — on a GPU. It trades CPU mesh building for a texture fetch per
vertex per frame, which is free on hardware and is the whole budget on a software rasteriser.
This addon targets devices where the rasteriser may BE the CPU, so it does the opposite trade:
build a real mesh per chunk once, keep it until the LOD changes, and spend the build on merging
flat ground away (greedy meshing) so the rasteriser has less to do every frame. That is also
why a heightmap texture is not used for displacement here — the heights live in a plain array
the mesh builder reads, and the shader only colours.

What was worth taking from them:

- **Recompute when the viewer crosses a cell, not on a timer** (HTerrain's detail layer). A
  full pass over every scattered object several times a second answers the same question over
  and over while the player stands still.
- **Pool instances instead of freeing them** — HTerrain recycles its MultiMesh instances rather
  than allocating per chunk.
- **A time budget in microseconds for pending work**, so a queue drains at whatever rate the
  frame can afford instead of a fixed count that is too slow on a good frame and a hitch on a
  bad one.
- **Detail/foliage as MultiMesh per chunk** — one draw call per type per chunk instead of a
  node per bush. Ore veins here already work that way; scattered props still do not, and that
  is the next thing to change once there are prop models to look at.

## Property reference

**Everything lives on the node.** There is no dock and no second place to look.

The world:

| Property | Default | What it does |
|---|---|---|
| `forced_seed` | `0` | The seed. The whole world follows from it. |
| `follow_world_settings` | `true` | Take the seed from an autoload `G` (`G.world_seed`) instead, so each save slot gets its own world. Off for menus and previews. |
| `biomes` | auto | The `TerrainBiomes` resource. See [Biomes](#biomes). |
| `surface_material` | addon `terrain_shader.res` | Texture and quality settings. |
| `world_cells` | `2048` | A NOMINAL square, not an edge: the world has none. Shops, ore veins and points of interest need a rectangle to lay themselves out in, and this is it. |

What is drawn:

| Property | Default | What it does |
|---|---|---|
| `view_distance` | `1400.0` | How far ground is drawn. |
| `enable_frustum_culling` | `true` | Skip nodes outside the camera frustum. |
| `frustum_margin` | `12.0` | Metres of slack, and ONLY on the side planes — on the near plane a positive margin means "draw what is behind the camera". |
| `enable_occlusion_culling` | `false` | Hide nodes below the terrain horizon. |
| `occlusion_min_dist` | `80.0` | Never occlusion-cull anything nearer than this. |
| `lod_interval` | `0.15` | Seconds between LOD passes; the selection is also recomputed whenever the camera moves. |
| `build_batch` | `24` | Node builds started per pass. |
| `stitch_budget` | `16` | Seam rebuilds per pass. A hairline crack for a frame beats a frame drop. |

Memory and loading:

| Property | Default | What it does |
|---|---|---|
| `keep_radius` | `320.0` | Inside this radius nothing is ever dropped, by time or by cap — it is the ground the player turns back onto in a second. |
| `ready_view` | `192.0` | How far the ground must be up before the loading screen may lift. |
| `ready_ring` | `2` | Chunks each way that must exist, with collision, before anything is shown. 2 is 80 m; a menu backdrop wants 1. |

Collision:

| Property | Default | What it does |
|---|---|---|
| `enable_streaming_collision` | `true` | Cut collision under tracked bodies. |
| `collision_radius` | `12` | Cells covered around each tracked body. |
| `collision_lookahead` | `1.2` | Seconds of travel to ask for ahead of a body. |

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

**Nothing appears.** The node builds around the camera the scene is DRAWN with. In a scene
with no current camera there is no point to build around — check that one is `current`, and
leave the node's `camera` property empty.

**The machine falls through at load.** Something asked for a height before
`terrain_is_ready`; `terrain_height_at` answers 0 until the generator exists. Wait for the
flag BY THE CLOCK (see [Runtime API](#runtime-api)), never by a frame count.

**A hole opens in the ground while driving.** A LOD change is "the node was replaced", not
"the node left", and the replacement may still be in the queue. A node is hidden only once a
neighbour the frame wants is already built — if you touch that rule, this is what breaks.

**The editor preview is somewhere else.** It builds around the editor viewport camera, which
the plugin hands over on mouse movement over the viewport. Move the mouse over the 3D view
once, then press the button.

## Notes

- Designed for the Compatibility (GLES3) backend.
- The bundled `Dark` folder holds sixteen tile textures; the default is `Dark/6.png`.
