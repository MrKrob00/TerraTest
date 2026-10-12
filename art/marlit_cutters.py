#!/usr/bin/env python3
"""MARLIT'S CUTTERS: the laser drill (2x2x2) and the saw (2x1x2), both bolted on by their BACK face
like the Marlit drill (art/marlit_drill.py), on the same toolkit and palette.

    python3 art/marlit_cutters.py [marlit_laser_drill|marlit_saw]
        -> objects/<name>_texture.png + art/out/<name>.glb
    godot --headless --path . --script res://art/turret_import.gd -- <name>
        -> blocks/meshes/<name>_<part>.tres

LASER DRILL (anchor in a corner: x -1.5..0.5, y -0.5..1.5, z -1.5..0.5). Its tool is a beam, so the
shape is an EMITTER, not a bit: the drill's back plate with the faction's window and its octagonal
housing, then a HEAD that turns while it works (node `Head`, about the drill's axis at the collar) -
a stepped lens stack with glowing cyan bands between the steps ending in a cyan lens, and three
focusing prongs round it converging forward to cyan tips, like the laser turret's fins. The beam
itself is drawn by the script (blocks/scripts/laser_drill.gd), only while it digs.
  body - block space;   head - about its origin on the axis (-0.5, 0.5, HEAD_Z), along -Z

SAW (anchor in a corner: x -1.5..0.5, y -0.5..0.5, z -1.5..0.5, one cell high). A circular blade
lies FLAT, turning about the vertical, its rim reaching the block's front face: a vertical blade
could not be wider than the one cell of height, a flat one is the whole 2 m footprint. A low housing
across the back half carries a spindle tower, a guard arcs round the blade's back, and a sunset band
runs round the housing. The blade (node `Blade`) is a disc with a hub and a ring of raked teeth.
  body - block space;   blade - about its origin on the spindle (-0.5, BLADE_Y, -0.55), about +Y
"""
import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import turret_heads as th  # noqa: E402
import emitter_models as em  # noqa: E402
import marlit_weapons as mw  # noqa: E402

def mprism(f, lo, hi, rnd, seg=None):
    """A box in the Marlit hull's own dress (`em.marlit_prism`): every face a dark panel with the
    faction's octagon, a sunset line and facets, every edge bevelled - what the Marlit block, cabin
    and the rest wear. `em.marlit_box`'s plain grey plates did not belong among them (the player)."""
    q = [(lo[1], lo[2]), (hi[1], lo[2]), (hi[1], hi[2]), (lo[1], hi[2])]
    em.marlit_prism(f, q, lo[0], hi[0], rnd, seg=seg)


# ── the laser drill ────────────────────────────────────────────────────────────────────────────
CX, CY = -0.5, 0.5
## THE HEAD IS THE ONE THE PLAYER KEPT (the second cut's: a stepped lens stack, cyan between the steps,
## three prongs converging on the lens); THE MOUNT WAS REDRAWN THREE TIMES - a thin plate ("far too
## thin"), a flat casting with a small housing and vent squares on its corners, a frustum and finned
## barrel ("wretched") - and is offered in two forms (LD_VARIANT):
##   "cast"  - a deep, heavily bevelled casting, the housing a wide cylinder out of it;
##   "step"  - a shallower casting and a two-tier stepped plinth, each tier with a sunset rim.
VARIANT = os.environ.get("LD_VARIANT", "cast")
HEAD_Z = -0.40


def _ld_body(f, rnd):
    if VARIANT == "step":
        cz = 0.05
        mprism(f, (-1.5, -0.5, cz), (0.5, 1.5, 0.5), rnd)
        tiers = [(cz, -0.16, 0.92, 0.90), (-0.16, HEAD_Z, 0.78, 0.74)]
        for z0, z1, r0, r1 in tiers:
            mw.oct_tube(f, (CX, CY, z0), (CX, CY, z1), r0, r1, "m")
            mw.band(f, (CX, CY, z1), (CX, CY, z1 - 1.0), r1 - 0.06, r1, "mglow")
            mw.band(f, (CX, CY, z1 - 0.001), (CX, CY, z1 - 1.0), 0.0, r1 - 0.06, "mflat1")
    else:
        cz = -0.10
        mprism(f, (-1.5, -0.5, cz), (0.5, 1.5, 0.5), rnd)
        mw.oct_tube(f, (CX, CY, cz), (CX, CY, cz - 0.08), 0.86, 0.86, "m")
        mw.oct_tube(f, (CX, CY, cz - 0.08), (CX, CY, cz - 0.14), 0.87, 0.87, "c")
        mw.oct_tube(f, (CX, CY, cz - 0.14), (CX, CY, HEAD_Z), 0.86, 0.80, "m")
        mw.band(f, (CX, CY, HEAD_Z), (CX, CY, HEAD_Z - 1.0), 0.70, 0.80, "mglow")
        mw.band(f, (CX, CY, HEAD_Z - 0.001), (CX, CY, HEAD_Z - 1.0), 0.0, 0.70, "mflat0")


LENS_END = -1.02       # the cyan lens's face, from the head's origin (z -1.42 in the block)


def _ld_head(f):
    # a turning ring the prongs stand on
    mw.oct_tube(f, (0, 0, 0), (0, 0, -0.12), 0.64, 0.62, "m", cap_a="mflat0")
    mw.band(f, (0, 0, -0.12), (0, 0, -1.12), 0.36, 0.62, "mflat2")
    # the stepped lens stack, cyan between the steps
    zz = -0.12
    for r, ln in ((0.34, 0.19), (0.29, 0.18), (0.23, 0.16)):
        mw.oct_tube(f, (0, 0, zz), (0, 0, zz - ln), r, r, "m")
        zz -= ln
        mw.band(f, (0, 0, zz), (0, 0, zz - 1), r - 0.03, r, "mflat3")
        mw.oct_tube(f, (0, 0, zz), (0, 0, zz - 0.05), r - 0.03, r - 0.03, "c")
        zz -= 0.05
    mw.oct_tube(f, (0, 0, zz), (0, 0, LENS_END + 0.04), 0.18, 0.15, "m")
    mw.oct_tube(f, (0, 0, LENS_END + 0.04), (0, 0, LENS_END), 0.15, 0.14, "c", cap_b="cyan3")
    # three focusing prongs from the ring's rim converging forward, each ONE straight piece whose last
    # fifth is cyan - the second cut bent the tip inward on its own, and it read as a loose crystal
    for k in range(3):
        t = math.pi / 2 + k * 2.0 * math.pi / 3
        d = (math.cos(t), math.sin(t))
        a = (d[0] * 0.52, d[1] * 0.52, -0.12)
        c = (d[0] * 0.26, d[1] * 0.26, LENS_END - 0.01)
        b = th.add(a, th.mul(th.sub(c, a), 0.78))
        mw.oct_tube(f, a, b, 0.095, 0.075, "m", sides=4)
        mw.oct_tube(f, b, c, 0.075, 0.05, "c", cap_b="cyan3", sides=4)


def _ld_build(pk, img):
    import random as _r
    rnd = _r.Random(91)
    parts = {"marlit_laser_drill_body": [], "marlit_laser_drill_head": []}
    _ld_body(parts["marlit_laser_drill_body"], rnd)
    _ld_head(parts["marlit_laser_drill_head"])
    return parts


# ── the saw ────────────────────────────────────────────────────────────────────────────────────
## THE BLADE IS THE ONE THE PLAYER KEPT; EVERYTHING ROUND IT IS THE MARLIT HULL'S OWN DRESS (`mprism`).
## Three cuts were turned down: a low box with a tower and a thin arm, two slabs round a slot ("a
## drawer"), and a D-shaped guard with hazard slats ("rubbish") - all in plain grey plate that no other
## Marlit block wears. Now: a Marlit body across the back of the block, and from it a YOKE - an upper
## and a lower arm reaching out to the blade's middle, an octagonal hub through both holding the axle -
## the blade turning between them. The front of the blade is bare. The yoke was first cut in the hull's
## dress too and read as grey frames; it is the turrets' dark metal now, slit in sunset like their yokes.
SX = -0.5
BLADE_Y = -0.06
BLADE_Z = -0.70
BLADE_R = 0.76
BLADE_T = 0.035        # half its thickness
CAST_Z = 0.12          # the body's front face
ARM_W = 0.20           # half an arm's width
UP_ARM = (BLADE_Y + BLADE_T + 0.05, 0.22)      # the upper arm's bottom and top
LO_ARM = (-0.42, BLADE_Y - BLADE_T - 0.05)     # the lower arm's
WEB_Z = CAST_Z - 0.26  # the clamp's web: the arms widen here where they leave the body


def _slit(f, x, y0, y1, z0, z1, side):
    """A sunset slit on an arm's outer face (x = const), as on the Marlit gun's yokes."""
    q = [(x, y0, z0), (x, y0, z1), (x, y1, z1), (x, y1, z0)]
    _face_out(f, q, (x - side, (y0 + y1) / 2, (z0 + z1) / 2))


def _face_out(f, q, inside):
    mw._face(f, q, inside, "mglow", u_hint=(0, 0, 1))


def _saw_body(f, rnd):
    # the body on the back face: the Marlit hull's own dress, the face it joins by
    mprism(f, (-1.5, -0.5, CAST_Z), (0.5, 0.5, 0.5), rnd, seg=2.0)
    # the CLAMP in the turrets' dark metal (the gun's yokes): a web out of the body and two arms
    # reaching over and under the blade to its middle, a sunset slit down every outer face
    for y0, y1 in (UP_ARM, LO_ARM):      # the web split by the blade's slot: the blade sweeps past it
        mw.mbox(f, (SX - ARM_W - 0.04, y0, WEB_Z), (SX + ARM_W + 0.04, y1, CAST_Z + 0.01))
    for y0, y1 in (UP_ARM, LO_ARM):
        mw.mbox(f, (SX - ARM_W, y0, BLADE_Z - 0.22), (SX + ARM_W, y1, WEB_Z + 0.01))
        for sd in (-1.0, 1.0):
            x = SX + sd * (ARM_W + 0.001)
            ym = (y0 + y1) / 2
            _slit(f, x, ym - 0.025, ym + 0.025, BLADE_Z - 0.10, WEB_Z - 0.04, sd)
    # the hub through both arms: an octagonal boss on top with a sunset ring, the axle to the blade
    em._oct_band(f, (SX, 0.0, BLADE_Z), 0.21, UP_ARM[1], 0.19, UP_ARM[1] + 0.07, "mtone")
    em._oct_band(f, (SX, 0.0, BLADE_Z), 0.19, UP_ARM[1] + 0.07, 0.17, UP_ARM[1] + 0.07, "mglow")
    em._oct_band(f, (SX, 0.0, BLADE_Z), 0.17, UP_ARM[1] + 0.07, 0.0, UP_ARM[1] + 0.07, "mflat2")
    em._oct_band(f, (SX, 0.0, BLADE_Z), 0.21, LO_ARM[0] - 0.05, 0.21, LO_ARM[0], "mtone")
    em._oct_band(f, (SX, 0.0, BLADE_Z), 0.0, LO_ARM[0] - 0.05, 0.21, LO_ARM[0] - 0.05, "mflat2", down=True)
    mw.oct_tube(f, (SX, UP_ARM[0], BLADE_Z), (SX, BLADE_Y + BLADE_T + 0.004, BLADE_Z), 0.11, 0.11, "m")
    mw.oct_tube(f, (SX, LO_ARM[1], BLADE_Z), (SX, BLADE_Y - BLADE_T - 0.004, BLADE_Z), 0.11, 0.11, "m")


def _saw_blade(f):
    # the disc in ground steel, thick, a bevelled rim
    rb = BLADE_R - 0.10
    mw.oct_tube(f, (0, -BLADE_T, 0), (0, BLADE_T, 0), rb - 0.04, rb - 0.04, "m",
                cap_a="msteel", cap_b="msteel", sides=16)
    mw.oct_tube(f, (0, -BLADE_T * 0.5, 0), (0, BLADE_T * 0.5, 0), rb, rb, "msteel", sides=16)
    top = (0, BLADE_T + 0.001, 0)
    # four dark expansion slots running in from the rim
    for k in range(4):
        t = math.pi / 4 + k * math.pi / 2
        d = (math.cos(t), 0.0, math.sin(t))
        tg = (-math.sin(t), 0.0, math.cos(t))
        a, b = th.mul(d, 0.40), th.mul(d, rb - 0.10)
        q = [th.add(th.add(a, th.mul(tg, -0.025)), top), th.add(th.add(b, th.mul(tg, -0.025)), top),
             th.add(th.add(b, th.mul(tg, 0.025)), top), th.add(th.add(a, th.mul(tg, 0.025)), top)]
        mw._face(f, q, (0, -1.0, 0), "mflat0", u_hint=d)
    mw.oct_tube(f, (0, BLADE_T, 0), (0, BLADE_T + 0.012, 0), 0.24, 0.24, "mglow", cap_b="mflat2")
    # big hooked teeth: a wedge each, raked forward in the turn, sunset-tipped
    nt = 16
    for k in range(nt):
        t = 2.0 * math.pi * k / nt
        d = (math.cos(t), 0.0, math.sin(t))
        tg = (-math.sin(t), 0.0, math.cos(t))
        root0 = th.add(th.mul(d, rb - 0.03), th.mul(tg, -0.09))
        root1 = th.add(th.mul(d, rb - 0.03), th.mul(tg, 0.07))
        tip = th.add(th.mul(d, BLADE_R), th.mul(tg, 0.08))
        for y0, y1 in ((-BLADE_T * 0.6, BLADE_T * 0.6),):
            lo = [(p[0], y0, p[2]) for p in (root0, root1, tip)]
            hi = [(p[0], y1, p[2]) for p in (root0, root1, tip)]
            mw._face(f, hi, (0, -1.0, 0), "msteel", u_hint=tg)
            mw._face(f, lo, (0, 1.0, 0), "msteel", u_hint=tg)
            mw._face(f, [lo[0], lo[2], hi[2], hi[0]], (0, 0, 0), "mflat3", u_hint=tg)
            mw._face(f, [lo[1], lo[2], hi[2], hi[1]], (0, 0, 0), "mglow", u_hint=tg)


def _saw_build(pk, img):
    import random as _r
    rnd = _r.Random(93)
    parts = {"marlit_saw_body": [], "marlit_saw_blade": []}
    _saw_body(parts["marlit_saw_body"], rnd)
    _saw_blade(parts["marlit_saw_blade"])
    return parts


# The self-check (art/model_check.py): cells, part origins (the scenes' nodes), what turns and the
# still body it must keep clear of.
if not hasattr(em, "CHECKS"):
    em.CHECKS = {}
em.CHECKS["marlit_laser_drill"] = {
    "cells": ((-1.5, -0.5, -1.5), (0.5, 1.5, 0.5)),
    "origins": {"marlit_laser_drill_head": (CX, CY, HEAD_Z)},
    "spin": {"marlit_laser_drill_head": (0.0, 0.0, -1.0)},
    "solid": [((-1.5, -0.5, -0.10), (0.5, 1.5, 0.5))],
}
em.CHECKS["marlit_saw"] = {
    "cells": ((-1.5, -0.5, -1.5), (0.5, 0.5, 0.5)),
    "origins": {"marlit_saw_blade": (SX, BLADE_Y, BLADE_Z)},
    "spin": {"marlit_saw_blade": (0.0, 1.0, 0.0)},
    "solid": [((-1.5, -0.5, CAST_Z), (0.5, 0.5, 0.5)),
              ((SX - ARM_W, UP_ARM[0], BLADE_Z - 0.2), (SX + ARM_W, UP_ARM[1], CAST_Z)),
              ((SX - ARM_W, LO_ARM[0], BLADE_Z - 0.2), (SX + ARM_W, LO_ARM[1], CAST_Z)),
              ((SX - ARM_W - 0.04, UP_ARM[0], WEB_Z), (SX + ARM_W + 0.04, UP_ARM[1], CAST_Z)),
              ((SX - ARM_W - 0.04, LO_ARM[0], WEB_Z), (SX + ARM_W + 0.04, LO_ARM[1], CAST_Z))],
}

# The Marlit dress is dear in triangles (the basic block alone is 536): the hidden faces go offline
# (`em.CULL`), and the budget is the Marlit blocks' own (the cabin 1029, the repair unit 1800).
em.CULL.add("marlit_laser_drill") if isinstance(em.CULL, set) else em.CULL.append("marlit_laser_drill")
em.CULL.add("marlit_saw") if isinstance(em.CULL, set) else em.CULL.append("marlit_saw")
em.CHECKS["marlit_laser_drill"]["budget"] = 1300
em.CHECKS["marlit_saw"]["budget"] = 1300

em.BLOCKS["marlit_laser_drill"] = (391, _ld_build, 512)
em.DENSITY["marlit_laser_drill"] = 40.0
em.BLOCKS["marlit_saw"] = (397, _saw_build, 512)
em.DENSITY["marlit_saw"] = 40.0

if __name__ == "__main__":
    for nm in (sys.argv[1:] or ["marlit_laser_drill", "marlit_saw"]):
        em.make(nm)
