#!/usr/bin/env python3
"""THE MARLIT DRILL: Marlit's first mining tool, 2x2x2 like every Marlit block (the anchor in a corner:
x -1.5..0.5, y -0.5..1.5, z -1.5..0.5), bolted on by its BACK face like the Falsus drill.

    python3 art/marlit_drill.py              -> objects/marlit_drill_texture.png + art/out/marlit_drill.glb
    godot --headless --path . --script res://art/turret_import.gd -- marlit_drill
        -> blocks/meshes/marlit_drill_body.tres, marlit_drill_bit.tres

WHAT IT SAYS IS WHAT IT DOES. The body stands still: a mount plate filling the back face with the
faction's window on it (the face it joins by), an octagonal housing narrowing toward the front with a
sunset band round it and four ribs along it, and a dark collar the bit comes out of. The BIT turns
(the clip "drilling", art/block_anims.gd, read off the part's own axis): a hub and three stepped
faceted tiers narrowing to a point on the block's front face, every tier ringed with square teeth set
at a twist to the one before, so the turn reads even from the side. Parts:
  body - block space
  bit  - about its own origin on the drill's axis at the collar (-0.5, 0.5, BIT_Z), along -Z
"""
import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import turret_heads as th  # noqa: E402
import emitter_models as em  # noqa: E402
import marlit_weapons as mw  # noqa: E402

CX, CY = -0.5, 0.5           # the drill's axis in block space: the 2x2 face's middle
PLATE_Z = 0.25               # the mount plate's front: the back face is z 0.5
BIT_Z = -0.42                # the collar's front, where the bit's origin stands
FRONT = -1.5                 # the block's front face: the bit's point reaches it at rest


def _body(f, rnd):
    # the mount plate on the whole back face, the faction's window on the face it joins by
    em.marlit_box(f, (-1.5, -0.5, PLATE_Z), (0.5, 1.5, 0.5), 0.08, rnd, {(2, 1): "window"})
    a = (CX, CY, PLATE_Z)
    # the housing, narrowing to the collar
    mw.oct_tube(f, a, (CX, CY, -0.05), 0.86, 0.82, "m")
    mw.oct_tube(f, (CX, CY, -0.05), (CX, CY, -0.13), 0.835, 0.835, "mglow")   # the sunset band
    mw.oct_tube(f, (CX, CY, -0.13), (CX, CY, BIT_Z + 0.08), 0.82, 0.72, "m")
    # the collar: a step in, a sunset rim, a dark throat the bit turns in
    mw.oct_tube(f, (CX, CY, BIT_Z + 0.08), (CX, CY, BIT_Z), 0.74, 0.74, "m")
    end = (CX, CY, BIT_Z)
    mw.band(f, end, (CX, CY, BIT_Z - 1.0), 0.66, 0.74, "mglow")
    mw.band(f, end, (CX, CY, BIT_Z - 1.0), 0.0, 0.66, "mflat0")
    # four ribs along the housing, on the diagonals, from the plate to the collar
    for k in range(4):
        t = math.pi / 4 + k * math.pi / 2
        dx, dy = math.cos(t), math.sin(t)
        r0, r1 = 0.80, 0.70
        mw.oct_tube(f, (CX + dx * r0, CY + dy * r0, PLATE_Z), (CX + dx * r1, CY + dy * r1, BIT_Z + 0.10),
                    0.07, 0.06, "m", cap_b="mflat2", sides=4)


TIERS = [  # (z from, z to, radius from, radius to, teeth)
    (-0.12, -0.42, 0.58, 0.44, 8),
    (-0.42, -0.70, 0.42, 0.26, 6),
    (-0.70, FRONT - BIT_Z, 0.24, 0.035, 4),
]


def _bit(f):
    o = (0.0, 0.0, 0.0)
    # the hub, turning in the collar
    mw.oct_tube(f, o, (0.0, 0.0, -0.12), 0.62, 0.60, "m", cap_a="mflat0")
    mw.band(f, (0.0, 0.0, -0.12), (0.0, 0.0, -1.12), 0.58, 0.60, "mflat2")
    twist = 0.0
    for i, (z0, z1, r0, r1, n) in enumerate(TIERS):
        cap = "mflat0" if i == len(TIERS) - 1 else None
        mw.oct_tube(f, (0.0, 0.0, z0), (0.0, 0.0, z1), r0, r1, "m", cap_b=cap)
        if i + 1 < len(TIERS):
            mw.band(f, (0.0, 0.0, z1), (0.0, 0.0, z1 - 1.0), TIERS[i + 1][2], r1, "mflat3")
        # square teeth round the tier's foot, standing out radially and raked forward
        zt = z0 - 0.07
        rt = r0 - (r0 - r1) * 0.25
        for k in range(n):
            t = twist + k * 2.0 * math.pi / n
            d = (math.cos(t), math.sin(t), 0.0)
            a = (d[0] * (rt - 0.03), d[1] * (rt - 0.03), zt)
            b = (d[0] * (rt + 0.10), d[1] * (rt + 0.10), zt - 0.07)
            mw.oct_tube(f, a, b, 0.045, 0.035, "m", cap_b="mglow", sides=4)
        twist += math.pi / n


def build(pk, img):
    import random as _r
    rnd = _r.Random(77)
    parts = {"marlit_drill_body": [], "marlit_drill_bit": []}
    _body(parts["marlit_drill_body"], rnd)
    _bit(parts["marlit_drill_bit"])
    return parts


em.BLOCKS["marlit_drill"] = (377, build, 512)
em.DENSITY["marlit_drill"] = 40.0

if __name__ == "__main__":
    em.make("marlit_drill")
