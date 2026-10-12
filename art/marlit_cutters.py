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
        em.marlit_box(f, (-1.5, -0.5, cz), (0.5, 1.5, 0.5), 0.12, rnd,
                      {(2, 1): "window", (0, 1): "window", (0, -1): "window", (1, 1): "window",
                       (1, -1): "window"})
        tiers = [(cz, -0.16, 0.92, 0.90), (-0.16, HEAD_Z, 0.78, 0.74)]
        for z0, z1, r0, r1 in tiers:
            mw.oct_tube(f, (CX, CY, z0), (CX, CY, z1), r0, r1, "m")
            mw.band(f, (CX, CY, z1), (CX, CY, z1 - 1.0), r1 - 0.06, r1, "mglow")
            mw.band(f, (CX, CY, z1 - 0.001), (CX, CY, z1 - 1.0), 0.0, r1 - 0.06, "mflat1")
    else:
        cz = -0.10
        em.marlit_box(f, (-1.5, -0.5, cz), (0.5, 1.5, 0.5), 0.20, rnd,
                      {(2, 1): "window", (0, 1): "window", (0, -1): "window", (1, 1): "window",
                       (1, -1): "window"})
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
## A CIRCULAR SAW, READ AT A GLANCE (the player: "everything but the blade is rubbish", then "no
## taste": two slabs round a slot read as a drawer, then a beam over a recess read as a pipe on a box,
## and a vented drum as a tower block). It is drawn as a real saw is: a D-shaped GUARD over the
## blade's back half - the arc behind, a straight front edge across the blade's middle carrying hazard
## slats - flowing into a casting across the back of the block, and the MOTOR standing on the guard
## over the spindle. The front half of the blade is bare; the back half runs under the guard.
SX = -0.5
BLADE_Y = -0.18
BLADE_Z = -0.72
BLADE_R = 0.75
BLADE_T = 0.035        # half its thickness
CAST_Z = 0.08          # the back casting's front face
GUARD_R = 0.84
GUARD_Y0 = BLADE_Y + BLADE_T + 0.03
GUARD_Y1 = 0.24
MOTOR_R = 0.27


def _d_prism(f, pts, y0, y1, side, top, bottom=None):
    """A prism over a convex outline in x-z: its sides toned (or one style), its top, maybe a bottom."""
    c = (sum(p[0] for p in pts) / len(pts), (y0 + y1) * 0.5, sum(p[1] for p in pts) / len(pts))
    n = len(pts)
    for i in range(n):
        j = (i + 1) % n
        q = [(pts[i][0], y0, pts[i][1]), (pts[j][0], y0, pts[j][1]), (pts[j][0], y1, pts[j][1]),
             (pts[i][0], y1, pts[i][1])]
        mw._face(f, q, c, side(i) if callable(side) else side, u_hint=th.sub(q[1], q[0]))
    mw._face(f, [(p[0], y1, p[1]) for p in pts], (c[0], y0 - 1.0, c[2]), top, u_hint=(1, 0, 0))
    if bottom:
        mw._face(f, [(p[0], y0, p[1]) for p in pts], (c[0], y1 + 1.0, c[2]), bottom, u_hint=(1, 0, 0))


def _guard_outline(r, n=10):
    # the arc behind the blade's middle (z grows to the back), closed by the straight front edge
    return [(SX + r * math.cos(math.pi * i / n), BLADE_Z + r * math.sin(math.pi * i / n)) for i in range(n + 1)]


def _saw_body(f, rnd):
    # the casting across the back, full height, the faction's window on its top and sides
    # its top FLUSH WITH THE GUARD'S, so casting and guard read as one housing (standing the full
    # cell high it read as a board behind the saw)
    em.marlit_box(f, (-1.5, -0.5, CAST_Z), (0.5, GUARD_Y1, 0.5), 0.06, rnd,
                  {(0, 1): "window", (0, -1): "window", (2, 1): "window"}, seg=2.0)
    # the guard: a D over the blade's back half, its arc a sunset-edged wall, its front edge slats
    out = _guard_outline(GUARD_R)
    nseg = len(out)

    def side(i):
        return "mhazard" if i == nseg - 1 else "m"
    _d_prism(f, out, GUARD_Y0, GUARD_Y1, side, "mflat2", bottom="mflat0")
    # a sunset line round the guard's foot, and a raised rim round its top
    inner = _guard_outline(GUARD_R - 0.06)
    for i in range(len(out) - 1):
        a0, a1 = out[i], out[i + 1]
        q = [(a0[0], GUARD_Y0 + 0.02, a0[1]), (a1[0], GUARD_Y0 + 0.02, a1[1]),
             (a1[0], GUARD_Y0 + 0.055, a1[1]), (a0[0], GUARD_Y0 + 0.055, a0[1])]
        mw._face(f, [(p[0] + (p[0] - SX) * 0.004, p[1], p[2] + (p[2] - BLADE_Z) * 0.004) for p in q],
                 (SX, GUARD_Y0, BLADE_Z), "mglow", u_hint=th.sub(q[1], q[0]))
        b0, b1 = inner[i], inner[i + 1]
        q = [(a0[0], GUARD_Y1, a0[1]), (a1[0], GUARD_Y1, a1[1]), (b1[0], GUARD_Y1 + 0.04, b1[1]),
             (b0[0], GUARD_Y1 + 0.04, b0[1])]
        mw._face(f, q, (SX, GUARD_Y1 - 1.0, BLADE_Z), "mflat3", u_hint=th.sub(q[1], q[0]))
    # the motor on the guard over the spindle: a drum, a sunset band, a vented cap
    mw.oct_tube(f, (SX, GUARD_Y1, BLADE_Z), (SX, 0.40, BLADE_Z), MOTOR_R, MOTOR_R, "m")
    mw.oct_tube(f, (SX, 0.40, BLADE_Z), (SX, 0.43, BLADE_Z), MOTOR_R + 0.01, MOTOR_R + 0.01, "mglow")
    mw.oct_tube(f, (SX, 0.43, BLADE_Z), (SX, 0.49, BLADE_Z), MOTOR_R, MOTOR_R - 0.05, "m", cap_b="mvent")
    # the spindle under the guard down to the blade's hub
    mw.oct_tube(f, (SX, GUARD_Y0, BLADE_Z), (SX, BLADE_Y + BLADE_T + 0.004, BLADE_Z), 0.12, 0.12, "m")


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
    "solid": [((-1.5, -0.5, CAST_Z), (0.5, GUARD_Y1, 0.5)),
              ((SX - 0.6, GUARD_Y0, BLADE_Z), (SX + 0.6, GUARD_Y1, BLADE_Z + 0.6))],
}

em.BLOCKS["marlit_laser_drill"] = (391, _ld_build, 512)
em.DENSITY["marlit_laser_drill"] = 40.0
em.BLOCKS["marlit_saw"] = (397, _saw_build, 512)
em.DENSITY["marlit_saw"] = 40.0

if __name__ == "__main__":
    for nm in (sys.argv[1:] or ["marlit_laser_drill", "marlit_saw"]):
        em.make(nm)
