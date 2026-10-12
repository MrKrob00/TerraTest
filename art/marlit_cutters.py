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

# ── the laser drill ────────────────────────────────────────────────────────────────────────────
CX, CY = -0.5, 0.5
## THE MOUNT IS A CASTING, NOT A PLATE (the player: "the mount is far too thin"): the back 0.65 m of
## the block is one chamfered Marlit body with the faction's window on its back and on all four sides,
## the emitter's housing standing out of its front face.
CAST_Z = -0.15
HEAD_Z = -0.40


def _ld_body(f, rnd):
    em.marlit_box(f, (-1.5, -0.5, CAST_Z), (0.5, 1.5, 0.5), 0.10, rnd,
                  {(2, 1): "window", (0, 1): "window", (0, -1): "window", (1, 1): "window",
                   (1, -1): "window"})
    # vented heat sinks on the casting's front corners
    for sx in (-1.0, 1.0):
        for sy in (-1.0, 1.0):
            x, y = CX + sx * 0.72, CY + sy * 0.72
            mw.mbox(f, (x - 0.16, y - 0.16, CAST_Z - 0.16), (x + 0.16, y + 0.16, CAST_Z), "mvent")
    # the housing out of the casting's face, a cyan band round it, the collar
    mw.oct_tube(f, (CX, CY, CAST_Z), (CX, CY, CAST_Z - 0.10), 0.84, 0.82, "m")
    mw.oct_tube(f, (CX, CY, CAST_Z - 0.10), (CX, CY, CAST_Z - 0.16), 0.825, 0.825, "c")
    mw.oct_tube(f, (CX, CY, CAST_Z - 0.16), (CX, CY, HEAD_Z), 0.82, 0.76, "m")
    end = (CX, CY, HEAD_Z)
    mw.band(f, end, (CX, CY, HEAD_Z - 1.0), 0.66, 0.76, "mglow")
    mw.band(f, end, (CX, CY, HEAD_Z - 1.0), 0.0, 0.66, "mflat0")


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
    # three focusing prongs from the ring's rim converging forward, cyan tips
    for k in range(3):
        t = math.pi / 2 + k * 2.0 * math.pi / 3
        d = (math.cos(t), math.sin(t))
        a = (d[0] * 0.52, d[1] * 0.52, -0.12)
        b = (d[0] * 0.36, d[1] * 0.36, LENS_END + 0.12)
        c = (d[0] * 0.24, d[1] * 0.24, LENS_END - 0.03)
        mw.oct_tube(f, a, b, 0.09, 0.075, "m", sides=4)
        mw.oct_tube(f, b, c, 0.075, 0.04, "c", cap_b="cyan3", sides=4)


def _ld_build(pk, img):
    import random as _r
    rnd = _r.Random(91)
    parts = {"marlit_laser_drill_body": [], "marlit_laser_drill_head": []}
    _ld_body(parts["marlit_laser_drill_body"], rnd)
    _ld_head(parts["marlit_laser_drill_head"])
    return parts


# ── the saw ────────────────────────────────────────────────────────────────────────────────────
## THE BODY IS A SAW HOUSING THE BLADE RUNS INTO (the player: "everything but the blade is rubbish" -
## a low box, a tower, a thin arm and an arc of plates): two chamfered Marlit castings, one over and
## one under a dark SLOT the blade's back runs in, joined by the back wall the block bolts on by; the
## upper one carries a nose forward over the blade to the spindle, hazard slats on its front.
SX = -0.5
BLADE_Y = -0.02
BLADE_Z = -0.60
BLADE_R = 0.88
SLOT = 0.07            # half the slot's height round the blade
CAST_FRONT = -0.30     # the castings' front face


def _saw_body(f, rnd):
    lo_top, up_bot = BLADE_Y - SLOT, BLADE_Y + SLOT
    em.marlit_box(f, (-1.5, -0.5, CAST_FRONT), (0.5, lo_top, 0.5), 0.06, rnd,
                  {(0, 1): "window", (0, -1): "window"}, seg=2.0)
    em.marlit_box(f, (-1.5, up_bot, CAST_FRONT), (0.5, 0.5, 0.5), 0.06, rnd,
                  {(1, 1): "window", (0, 1): "window", (0, -1): "window"}, seg=2.0)
    # the slot: a dark back wall and dark floor and ceiling, so the blade reads as running into it
    zb = 0.40
    for q in ([(-1.44, lo_top, zb), (0.44, lo_top, zb), (0.44, up_bot, zb), (-1.44, up_bot, zb)],):
        mw._face(f, q, (-0.5, BLADE_Y, CAST_FRONT), "mflat0", u_hint=(1, 0, 0))
    mw._face(f, [(-1.44, lo_top, CAST_FRONT), (0.44, lo_top, CAST_FRONT), (0.44, lo_top, zb), (-1.44, lo_top, zb)],
             (-0.5, BLADE_Y + 1.0, 0.0), "mflat1", u_hint=(1, 0, 0))
    mw._face(f, [(-1.44, up_bot, CAST_FRONT), (0.44, up_bot, CAST_FRONT), (0.44, up_bot, zb), (-1.44, up_bot, zb)],
             (-0.5, BLADE_Y - 1.0, 0.0), "mflat1", u_hint=(1, 0, 0))
    # sunset bands along the castings' fronts, by the slot
    for y0, y1 in ((lo_top - 0.08, lo_top - 0.03), (up_bot + 0.03, up_bot + 0.08)):
        q = [(-1.42, y0, CAST_FRONT - 0.002), (0.42, y0, CAST_FRONT - 0.002),
             (0.42, y1, CAST_FRONT - 0.002), (-1.42, y1, CAST_FRONT - 0.002)]
        mw._face(f, q, (-0.5, BLADE_Y, 0.0), "mglow", u_hint=(1, 0, 0))
    # the nose: forward from the upper casting over the blade to the spindle, hazard slats on its front
    nx0, nx1 = SX - 0.26, SX + 0.26
    em.marlit_box(f, (nx0, up_bot + 0.02, BLADE_Z - 0.20), (nx1, 0.42, CAST_FRONT + 0.02), 0.05, rnd, {})
    q = [(nx0 + 0.04, up_bot + 0.08, BLADE_Z - 0.202), (nx1 - 0.04, up_bot + 0.08, BLADE_Z - 0.202),
         (nx1 - 0.04, 0.36, BLADE_Z - 0.202), (nx0 + 0.04, 0.36, BLADE_Z - 0.202)]
    mw._face(f, q, (SX, 0.2, 0.0), "mhazard", u_hint=(1, 0, 0))
    # the spindle down from the nose to the hub
    mw.oct_tube(f, (SX, up_bot + 0.02, BLADE_Z), (SX, BLADE_Y + 0.05, BLADE_Z), 0.13, 0.12, "m")


def _saw_blade(f):
    # the disc: sixteen sides, thin, in ground steel on both faces
    mw.oct_tube(f, (0, -0.025, 0), (0, 0.025, 0), BLADE_R - 0.10, BLADE_R - 0.10, "m",
                cap_a="msteel", cap_b="msteel", sides=16)
    top = (0, 0.026, 0)
    # four dark expansion slots running in from the rim, as on a real blade
    for k in range(4):
        t = math.pi / 4 + k * math.pi / 2
        d = (math.cos(t), 0.0, math.sin(t))
        tg = (-math.sin(t), 0.0, math.cos(t))
        a, b = th.mul(d, 0.42), th.mul(d, BLADE_R - 0.16)
        q = [th.add(th.add(a, th.mul(tg, -0.025)), top), th.add(th.add(b, th.mul(tg, -0.025)), top),
             th.add(th.add(b, th.mul(tg, 0.025)), top), th.add(th.add(a, th.mul(tg, 0.025)), top)]
        mw._face(f, q, (0, -1.0, 0), "mflat0", u_hint=d)
    # a sunset ring and the hub
    mw.oct_tube(f, (0, 0.026, 0), (0, 0.035, 0), 0.30, 0.30, "mglow", cap_b="mflat2")
    mw.oct_tube(f, (0, 0.035, 0), (0, 0.05, 0), 0.16, 0.15, "m", cap_b="mflat0")
    # raked teeth round the rim, sunset-tipped so the turn reads
    nt = 20
    for k in range(nt):
        t = 2.0 * math.pi * k / nt
        d = (math.cos(t), 0.0, math.sin(t))
        tg = (-math.sin(t), 0.0, math.cos(t))
        a = th.mul(d, BLADE_R - 0.12)
        b = th.add(th.mul(d, BLADE_R), th.mul(tg, 0.06))
        mw.oct_tube(f, a, b, 0.035, 0.012, "msteel", cap_b="mglow", sides=4)


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
    "solid": [((-1.5, -0.5, CAST_Z), (0.5, 1.5, 0.5))],
}
em.CHECKS["marlit_saw"] = {
    "cells": ((-1.5, -0.5, -1.5), (0.5, 0.5, 0.5)),
    "origins": {"marlit_saw_blade": (SX, BLADE_Y, BLADE_Z)},
    "spin": {"marlit_saw_blade": (0.0, 1.0, 0.0)},
    "solid": [((-1.5, -0.5, CAST_FRONT), (0.5, BLADE_Y - SLOT, 0.5)),
              ((-1.5, BLADE_Y + SLOT, CAST_FRONT), (0.5, 0.5, 0.5)),
              ((SX - 0.26, BLADE_Y + SLOT + 0.02, BLADE_Z - 0.20), (SX + 0.26, 0.42, CAST_FRONT))],
}

em.BLOCKS["marlit_laser_drill"] = (391, _ld_build, 512)
em.DENSITY["marlit_laser_drill"] = 40.0
em.BLOCKS["marlit_saw"] = (397, _saw_build, 512)
em.DENSITY["marlit_saw"] = 40.0

if __name__ == "__main__":
    for nm in (sys.argv[1:] or ["marlit_laser_drill", "marlit_saw"]):
        em.make(nm)
