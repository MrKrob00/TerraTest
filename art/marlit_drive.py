#!/usr/bin/env python3
"""MARLIT'S CABIN AND WHEEL, 2x2x2 like every Marlit block (anchored in a corner: x -1.5..0.5,
y -0.5..1.5, z -1.5..0.5). They replace the Falsus cabin and the big wheel the faction drove on as
placeholders.

    python3 art/marlit_drive.py [marlit_cabin|marlit_wheel2]
        -> objects/<name>_texture.png + art/out/<name>.glb
    godot --headless --path . --script res://art/turret_import.gd -- <name> ...
        -> blocks/meshes/<name>_<part>.tres

CABIN - the faction's casting with its front-top edge cut away into a SLOPED CANOPY: the cockpit is
the slope, three panes of sea-teal glass in a gunmetal frame, a sunset line under them. Below it the
front is a bumper with a vented grille between two sunset lamps; the sides and the top carry the
faction's window like every Marlit block, so it still joins on every face (the slope excepted).
  body - all of it (a cabin moves nothing)

WHEEL - a wide low-poly tyre with staggered lugs, an octagonal rim on the outer side with six spokes
and a capped hub, a short axle housing back to a round bearing plate on the BACK face - the face
it bolts on by, as every wheel here (`connect_faces` 2). The tyre turns about Z through the block's
middle, so at rest it rolls across the block, as the Falsus wheels do before the hull turns them.
  body - the bearing plate and the axle housing (still)
  tyre - the tyre, rim, spokes and hub, about its own middle (turns)
"""
import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import turret_heads as th  # noqa: E402
import emitter_models as em  # noqa: E402
import marlit_weapons as mw  # noqa: E402

CX, CY, CZ = -0.5, 0.5, -0.5          # the 2x2x2 block's middle

# ── the cabin ───────────────────────────────────────────────────────────────────────────────────
# the profile in (y, z): the front's upright face up to CAB_SILL, the canopy slope up to the top
# at CAB_BROW behind the front face
CAB_SILL = 0.45
CAB_BROW = -0.45
CAB_YZ = [(-0.5, -1.5), (CAB_SILL, -1.5), (1.5, CAB_BROW), (1.5, 0.5), (-0.5, 0.5)]
CAB_PANES = (-1.32, -0.86, -0.14, 0.32)      # x of the panes' edges: a wide middle, two narrow sides
CAB_FRAME = 0.05                            # the frame's half width between panes
CAB_GLASS_IN = 0.10                         # the glass stands this far inside the slope's edges


def _slope_point(x, s, lift=0.0):
    """A point on the canopy slope: s 0 at the sill, 1 at the brow; `lift` off it along its normal."""
    y = CAB_SILL + (1.5 - CAB_SILL) * s
    z = -1.5 + (CAB_BROW + 1.5) * s
    n = th.norm((0.0, CAB_BROW + 1.5, -(1.5 - CAB_SILL)))
    return (x + n[0] * lift, y + n[1] * lift, z + n[2] * lift)


def build_marlit_cabin(pk, img):
    import random as _r
    rnd = _r.Random(57)
    parts = {"marlit_cabin_body": []}
    f = parts["marlit_cabin_body"]
    em.marlit_prism(f, CAB_YZ, -1.5, 0.5, rnd)
    # the canopy: three panes in a gunmetal frame, proud of the slope's own dressing
    span = math.hypot(1.5 - CAB_SILL, CAB_BROW + 1.5)
    s0 = CAB_GLASS_IN / span
    s1 = 1.0 - CAB_GLASS_IN / span
    xs = CAB_PANES
    centre = (CX, 0.2, -0.2)
    frame = [_slope_point(xs[0] - CAB_FRAME, s0 - 0.03, 0.010), _slope_point(xs[-1] + CAB_FRAME, s0 - 0.03, 0.010),
             _slope_point(xs[-1] + CAB_FRAME, s1 + 0.03, 0.010), _slope_point(xs[0] - CAB_FRAME, s1 + 0.03, 0.010)]
    mw._face(f, frame, centre, "mflat1", u_hint=(1, 0, 0))
    for i in range(len(xs) - 1):
        a = xs[i] + (CAB_FRAME if i > 0 else 0.0)
        b = xs[i + 1] - (CAB_FRAME if i < len(xs) - 2 else 0.0)
        pane = [_slope_point(a, s0, 0.018), _slope_point(b, s0, 0.018), _slope_point(b, s1, 0.018),
                _slope_point(a, s1, 0.018)]
        mw._face(f, pane, centre, "mglass", u_hint=(1, 0, 0))
    # a sunset line under the glass, along the sill
    line = [_slope_point(xs[0], s0 - 0.055, 0.016), _slope_point(xs[-1], s0 - 0.055, 0.016),
            _slope_point(xs[-1], s0 - 0.035, 0.016), _slope_point(xs[0], s0 - 0.035, 0.016)]
    mw._face(f, line, centre, "mglow", u_hint=(1, 0, 0))
    # the bumper: a vented grille between two sunset lamps, proud of the front face
    zf = -1.5 - 0.012
    grille = [(-0.95, -0.22, zf), (-0.05, -0.22, zf), (-0.05, 0.22, zf), (-0.95, 0.22, zf)]
    mw._face(f, grille, (CX, 0.0, 0.0), "mvent", u_hint=(1, 0, 0))
    for x0, x1 in ((-1.36, -1.08), (0.08, 0.36)):
        lamp = [(x0, -0.06, zf), (x1, -0.06, zf), (x1, 0.18, zf), (x0, 0.18, zf)]
        mw._face(f, lamp, (CX, 0.0, 0.0), "mglow", u_hint=(1, 0, 0))
    return parts


# ── the wheel ───────────────────────────────────────────────────────────────────────────────────
WH_R = 0.95                  # the tyre's radius over the lugs
WH_TREAD = 0.89              # under them
WH_SIDE_IN = 0.56            # the sidewall's inner edge, where the rim starts
WH_Z = (-1.45, -0.27)        # the tyre's outer and inner faces (the outer side looks along -Z)
WH_N = 16                    # facets round
WH_HUB = (0.20, 0.30)        # the hub cap and the axle housing, across their flats
WH_PLATE = (0.78, 0.30)      # the bearing plate on the back face: across its flats, its front z


def _ring(C, r, z, n=WH_N, off=0.5):
    return [(C[0] + r * math.cos(2 * math.pi * (k + off) / n), C[1] + r * math.sin(2 * math.pi * (k + off) / n), z)
            for k in range(n)]


def _band_z(f, C, r0, z0, r1, z1, style, n=WH_N):
    a, b = _ring(C, r0, z0, n), _ring(C, r1, z1, n)
    mid = (C[0], C[1], (z0 + z1) / 2)
    for k in range(n):
        j = (k + 1) % n
        q = [a[k], a[j], b[j], b[k]]
        if math.dist(q[0], q[3]) < 1e-6 and math.dist(q[1], q[2]) < 1e-6:
            continue
        if r0 == r1:
            centre = mid
        else:
            centre = (C[0], C[1], z0 + (1.0 if z1 > z0 else -1.0)) if abs(z1 - z0) < 1e-6 else mid
        mw._face(f, q, centre, style, u_hint=th.sub(q[1], q[0]))


def build_marlit_wheel2(pk, img):
    parts = {"marlit_wheel2_body": [], "marlit_wheel2_tyre": []}
    b = parts["marlit_wheel2_body"]
    # the bearing plate on the back face, the axle housing out to the tyre's inner face
    mw.oct_tube(b, (CX, CY, 0.5), (CX, CY, WH_PLATE[1]), WH_PLATE[0], WH_PLATE[0] - 0.04, "m",
                cap_a="mflat2", cap_b="mflat3")
    mw.band(b, (CX, CY, WH_PLATE[1] - 0.001), (CX, CY, -1.0), WH_PLATE[0] - 0.10, WH_PLATE[0] - 0.07, "mglow")
    mw.oct_tube(b, (CX, CY, WH_PLATE[1]), (CX, CY, WH_Z[1] + 0.02), WH_HUB[1], WH_HUB[1] - 0.03, "m")
    for k in range(4):
        a = math.pi / 4 + k * math.pi / 2
        p = (CX + math.cos(a) * (WH_PLATE[0] - 0.17), CY + math.sin(a) * (WH_PLATE[0] - 0.17), WH_PLATE[1] - 0.012)
        bolt = [th.add(p, (-0.05, -0.05, 0)), th.add(p, (0.05, -0.05, 0)), th.add(p, (0.05, 0.05, 0)),
                th.add(p, (-0.05, 0.05, 0))]
        mw._face(b, bolt, (CX, CY, 0.5), "mbolt", u_hint=(1, 0, 0))
    # the tyre, about its own middle (the scene's tyre node stands at the block's middle)
    t = parts["marlit_wheel2_tyre"]
    O = (0.0, 0.0, 0.0)
    zo, zi = WH_Z[0] - CZ, WH_Z[1] - CZ          # in the tyre's own frame
    sh = 0.08                                    # the shoulder's run-in
    _band_z(t, O, WH_SIDE_IN, zo, WH_TREAD - 0.04, zo, "m")          # outer sidewall
    _band_z(t, O, WH_SIDE_IN, zi, WH_TREAD - 0.04, zi, "m")          # inner sidewall
    _band_z(t, O, WH_TREAD - 0.13, zo - 0.004, WH_TREAD - 0.10, zo - 0.004, "mglow")   # a sunset line
    _band_z(t, O, WH_TREAD - 0.04, zo, WH_TREAD, zo + sh, "m")       # shoulders
    _band_z(t, O, WH_TREAD - 0.04, zi, WH_TREAD, zi - sh, "m")
    _band_z(t, O, WH_TREAD, zo + sh, WH_TREAD, zi - sh, "mflat0")     # the tread's floor
    # staggered lugs: two rows, the second half a facet round, each a block standing on the floor
    width = (zi - sh) - (zo + sh)
    for row, (za, zb, off) in enumerate(((zo + sh + 0.03, zo + sh + width * 0.48, 0.0),
                                         (zo + sh + width * 0.52, zi - sh - 0.03, 0.5))):
        for k in range(WH_N):
            a0 = 2 * math.pi * (k + off + 0.12) / WH_N
            a1 = 2 * math.pi * (k + off + 0.62) / WH_N
            def P(a, r, z):
                return (r * math.cos(a), r * math.sin(a), z)
            lo = [P(a0, WH_TREAD, za), P(a1, WH_TREAD, za), P(a1, WH_TREAD, zb), P(a0, WH_TREAD, zb)]
            hi = [P(a0, WH_R, za), P(a1, WH_R, za), P(a1, WH_R, zb), P(a0, WH_R, zb)]
            mid = P((a0 + a1) / 2, WH_TREAD - 0.2, (za + zb) / 2)
            mw._face(t, hi, mid, "mflat2" if (k + row) % 2 else "mflat1", u_hint=th.sub(hi[1], hi[0]))
            for i in range(4):
                j = (i + 1) % 4
                mw._face(t, [lo[i], lo[j], hi[j], hi[i]], mid, "mflat0", u_hint=th.sub(lo[j], lo[i]))
    # the rim on the outer side: a dark dish, a sunset line round its lip, six spokes to a capped hub
    _band_z(t, O, WH_SIDE_IN, zo, WH_SIDE_IN - 0.03, zo + 0.05, "m", n=8)
    _band_z(t, O, WH_SIDE_IN - 0.03, zo + 0.05, WH_SIDE_IN - 0.06, zo + 0.05, "mglow", n=8)
    _band_z(t, O, WH_SIDE_IN - 0.06, zo + 0.05, 0.0, zo + 0.12, "mflat0", n=8)
    for k in range(6):
        a = 2 * math.pi * k / 6
        d = (math.cos(a), math.sin(a), 0.0)
        s = (-math.sin(a), math.cos(a), 0.0)
        em.obox(t, (d[0] * 0.33, d[1] * 0.33, zo + 0.07), (d, s, (0.0, 0.0, 1.0)), (0.17, 0.045, 0.045),
                ["mtone3"] * 6)
    mw.oct_tube(t, (0, 0, zo + 0.12), (0, 0, zo - 0.04), WH_HUB[0], WH_HUB[0] - 0.03, "m", cap_b="mpin")
    # the inner side's hub face, round the housing
    _band_z(t, O, WH_SIDE_IN, zi, WH_HUB[1] + 0.01, zi - 0.05, "m", n=8)
    return parts


em.BLOCKS["marlit_cabin"] = (331, build_marlit_cabin, 512)
em.BLOCKS["marlit_wheel2"] = (337, build_marlit_wheel2, 512)
em.DENSITY["marlit_cabin"] = 36.0
em.DENSITY["marlit_wheel2"] = 36.0

if __name__ == "__main__":
    for nm in (sys.argv[1:] or ["marlit_cabin", "marlit_wheel2"]):
        em.make(nm)
