# The block style, measured

The artist's models in `objects/Assets.glb` are the reference. That reference was 18 models
(frame block, both batteries, solar panel, wedge, weapon base, gun, laser, rocket launcher, three
wheel modules, two drills, auto miner, ingot, coal, SOXA). They were measured on the engine and read
side by side before these rules were written. Every number below came out of that pass, and the
harness is described at the end so it can be run again when the atlas changes.

A new model is built BY these rules, not traced from one reference. The first one built that way
is the generator (`art/emitter_models.py build_generator`), and the last section shows how each
rule landed on it.

## 1. Colour: dark metal, one blue, one pop

Area-weighted over every surface of the 14 block models (31 434 samples):

| family | share | typical values |
|---|---|---|
| dark violet-grey metal | 78 % | (21,23,26) … (60,57,69), hue 225-275, saturation 0.1 |
| GSO blue | 12 % | (76,106,177) body, (57,71,110) shade, (110,152,217) edge |
| orange / amber | 3 % | (212,144,56), (150,96,38) |
| light grey / white | 3 % | (164,171,187) and up |

- **The body is dark metal.** Blue is a HOUSING or a COVER: the weapon base, a turret shell, the
  wheel hub, the solar frame. On the plain frame block the share is 0 %, on the gun it is 40 %.
- **One pop colour, and it says what the block does:**
  - the battery's amber cells (19 % of its area);
  - the drill's white crystal (31-37 %);
  - the solar panel's lit cells;
  - the hazard slats on a platform's side, which say "this is the base".

  Never two pop colours on one block.
- **The metal is never grey.** It leans violet (blue slightly over red over green) and never goes
  above lightness 0.33. The atlas's lightest metal is an EDGE LINE, not a surface.

## 2. Light: none painted, all drawn

- **The materials are unshaded, and the atlas paints NO directional light.** Mean luminance of
  faces looking up, sideways and down is about 0.22 each. A top is not lighter than a side.
- **Shape reads by EDGE LINES.** Every face carries a one- or two-texel lighter line along its
  edges, and every chamfer is a strip of its own. Chamfers are 22 % of all surface area.
- A round part (tyre, lens, barrel) is the exception: it is a prism of 8-16 facets, each painted
  flat in its own tone. With no lighting, one colour round a cylinder is a flat disc.

## 3. Form: chamfered boxes and frustums

- **Every edge is chamfered.** The cube's chamfer is 0.067 m, a fifteenth of the cell. A housing
  is a frustum with a heavier chamfer, often not square: the weapon base's is a pentagon.
- **No smooth curves.** Round parts are low-sided prisms, and silhouettes are made of flats.
- **Two archetypes, decided by how the block joins:**
  - **The full cube** joins on every face: frame block, battery. Walls stand ON the cell's faces,
    so two cubes meet flat.
  - **The platform block** joins by one face: a dark platform 1.0 × 0.13 with orange slats on its
    sides, a blue neck or housing about 0.92 × 0.4, and a head 0.5-0.9 across (gun, laser, rocket,
    drills, wheels, solar).
- **Everything fits its 1 m cell at rest.**

## 4. Detail lives in the texture

- Triangles:
  - frame block, battery: 44;
  - solar: 48;
  - weapon base: 59;
  - drill bases: 36-60;
  - rocket launcher 88, gun 137, laser 153;
  - the wheels are the outlier at 286, and 188 of that is the tyre.

  A block is 40-150 triangles.
- **Texel density is 38-48 px per metre**, filtered nearest, so a texel is readable on a phone.
  Detail finer than two texels does not exist.
- **The pattern vocabulary is small, and it repeats:**
  - a vertical slot grille;
  - a small emblem in a square in its middle (the frame block's cross);
  - rivets in the corners of any face big enough;
  - a diagonal-braced panel on tops;
  - hazard slats on platform sides;
  - checkers on the rocket's head;
  - tiny white stencil marks (the gun's "01", the neck's arrow).

  A new block speaks these words before it invents new ones.

## 5. Function is readable at a glance

The part that WORKS is where the pop colour is. The battery shows its cells, the drill its
crystal, the gun its barrel. A block that changes state shows the state on that part. Examples
here: the shield's core, the repair unit's crystal, the generator's fire. It is not shown by a
HUD label.

## The generator, built by these rules

| rule | on the generator |
|---|---|
| archetype | full cube: it joins on every face (the default mask), walls on the cell faces, chamfer 0.067 |
| body | dark metal, slot grille across the top of each wall, a sign plate in its middle (a bolt, not the frame block's cross), rivets |
| blue | a low chamfered frustum on top, a housing like the weapons', 0.2 m tall |
| pop | amber fire behind a grate in every wall, and nothing else amber |
| light | none painted; edge lines on every face, chamfer strips a shade lighter than the wall |
| detail | 108 triangles, 48 px/m, 256 px texture of its own; the well is PAINTED on a solid lid, so what sinks into it vanishes (a modelled well showed the blades lying in a pit) |
| function | the grate is LIT only while it burns (`generator.gd`, cold otherwise); fuel goes in through the top - the turbine sinks through the lid, the fuel drops into the painted well, the fire flares, the turbine rises and spins up |

What was changed after the first render against the family, and why:

- The chamfer lines were one step too light. The frame block's edges are quiet, and those read as
  grey columns.
- The housing was 0.24 m tall and nearly vertical. The GSO housings are low and sloped, and that
  one read as a lid.

## Re-measuring

The harness is not kept in the repo; this describes what it does.

- **Instance the models.** Put every mesh node of `Assets.glb` in the tree.
- **Collect statistics per model:**
  - triangles;
  - texel density (UV area against world area);
  - chamfer share (faces whose normal is not axis-aligned);
  - mean luminance per facing (up / side / down, sampled from the atlas at each face's UVs).
- **Sample the palette.** Take `ceil(area × 400)` random points per triangle, weighted by AREA, and
  cluster them. Sampling the atlas image itself is wrong: 93 % of it is unused background, the
  flat (76,106,177) fill.

## Redrawn to the rules

The collector kept the shape the player had made for it: a cube with a bowl. The receiver took
five tries, and every miss was the same mistake: inventing a shape instead of reading the one the
player had drawn.

- **A plate on a post.** It hung at the top of its cell.
- **A platform block.** It stood on the floor, but it was not a saucer.
- **Two round saucers.** One on the floor, one with a chute.
- **A half-saucer.** Thin, lower than the belt, and far rounder than the plate the player meant.

The old model seen from above answers it: a square plate with its back corners cut, its output
edge square, a blue octagon in the middle. The receiver is now exactly that, drawn in the
conveyors' own parts: the belt's height, width, rails and ribbed floor. It reads as the conveyor's
head, not as a gadget standing next to it.

- **Colour.** Dark metal, the conveyor's blue rails and deck, a GSO-blue lid on the collector.
- **Emblem.** A sign plate on the collector's grille: a down-pointing triangle, because things go
  in at the top and stay.
- **Size.** Both now fit their cell: 114 and 139 triangles, down from 450 and 882 untextured.

A sign smaller than about five texels breaks up under mip-mapping at a grazing angle. The first
three-row triangle read as a bird from 35°, while straight on it was clean. Draw emblems at least
nine texels across.

## Machines drawn from their ports

The smelter and the seller are 2×2×2, and each face is four quarters, only some of which are
ports. The model's first job is to show WHICH quarters, because that decides how a line is
built round the machine:

- **The smelter.** Its ports are all in one column at belt height, and the ore goes round,
  clockwise: in on the right at the back, left into the furnace, forward through its glowing
  gallery, and out to the right at the front. The right column is an open intake and exit split
  by a divider. Two tries went before it, and both are rules now: a hood over the channel hid the
  work, and a hot bed in an open channel was not a smelter.
- **The seller.** Its one intake corner is an open mouth under the tube that carries sold goods
  away.

Everything else is closed: a wall, a vault, a furnace.
