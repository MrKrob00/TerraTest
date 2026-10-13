#!/usr/bin/env python3
"""MARLIT'S LIGHT AND HEAVY WHEELS, beside the parallel-arm Marlit wheel (art/marlit_drive.py). DRAFTS
for the player's approval: generator only, not wired into the game.

    python3 art/marlit_wheels.py [marlit_wlight|marlit_wheavy]
        -> objects/<name>_texture.png + art/out/<name>.glb (one node per part)

Both are 2x2x2 like every Marlit block (anchor in a corner: x -1.5..0.5, y -0.5..1.5, z -1.5..0.5),
bolted on by the BACK face (+Z) like every wheel; the tyre's axle is Z, it rolls along X.

THE TRANSMISSION IS THE SHAPE, AND IT HAS TO WORK AS DRAWN (the reason wheels were turned down): the
power runs from the plate to the hub through parts that are visibly joined, and nothing changes length
or passes through anything when the suspension moves or the wheel steers. So each wheel is ONE
mechanism a real machine uses, drawn in few, big parts:

LIGHT - a SWING AXLE. A final-drive drum on the plate; the axle TUBE leaves it through a ribbed boot
(the joint inside) and runs straight out, COAXIAL with the tyre's axle - the shaft inside it is the
tyre's own axle, so there is nothing to bend or stretch. The tube pivots at the drum (rotation.x),
one air strut from a mount high on the plate to a clamp on the tube carries it, and the hub carrier
at the tube's end steers about a pin between the tube's two yoke lugs. Smaller, narrower tyre.
  body - plate, drum, pin brackets, the strut's top mount (still)
  arm  - the tube, boot, damper clamp and yoke, about PIV_L (rotation.x = swing)
  knuckle - the hub carrier about KN_L (steers about Y; rides on the arm)
  tyre - about TC_L (spins about Z)
  dbody / drod - the strut's cylinder from its top mount, its rod from its foot on the tube

HEAVY - a SLIDING PILLAR with a PORTAL BOX and DUAL TYRES (a mining truck's leg, an aircraft's oleo).
A gearbox high on the plate turns the drive DOWN into a vertical sleeve; the chrome leg slides in it
(suspension) and turns in it (steering) - the drive shaft runs down the pillar's own axis, so steering
does not wind it and sliding is a spline. At the foot a portal gear case drops the drive to the hub of
two tyres side by side. Scissor torque links tie the steering collar to the case and fold as it rises.
  body - plate, gearbox, sleeve and its clamps (still)
  collar - the steering collar under the sleeve, about AX_H (steers about Y)
  leg  - chrome leg + portal case + hub, about AX_H at rest (steers about Y, slides along Y)
  link_up / link_lo - the scissor links, about their hinges (rotation.z = fold; steer with the collar)
  tyre - both tyres, about TC_H (spins about Z)
"""
import math
import os
import random
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import turret_heads as th  # noqa: E402
import emitter_models as em  # noqa: E402
import marlit_weapons as mw  # noqa: E402

PLATE_Z = 0.30               # the bearing plate's front; the back face is z 0.5
TONES = ["mtone3", "mtone3", "mtone4", "mtone1", "mtone2", "mtone2"]


def _shift(faces, origin):
    for fc in faces:
        fc.pts = [th.sub(p, origin) for p in fc.pts]


def _ring(C, r, z, n, off=0.5):
    return [(C[0] + r * math.cos(2 * math.pi * (k + off) / n), C[1] + r * math.sin(2 * math.pi * (k + off) / n), z)
            for k in range(n)]


def _band_z(f, C, r0, z0, r1, z1, style, n):
    """A ring of quads about the Z axis through C, from radius r0 at z0 to r1 at z1."""
    a, b = _ring(C, r0, z0, n), _ring(C, r1, z1, n)
    mid = (C[0], C[1], (z0 + z1) / 2)
    for k in range(n):
        j = (k + 1) % n
        q = [a[k], a[j], b[j], b[k]]
        if math.dist(q[0], q[3]) < 1e-6 and math.dist(q[1], q[2]) < 1e-6:
            continue
        centre = mid
        if abs(z1 - z0) < 1e-6:                    # a flat ring: "inside" is behind it
            centre = (C[0], C[1], z0 - 0.3 if z0 > C[2] else z0 + 0.3)
        mw._face(f, q, centre, style, u_hint=th.sub(q[1], q[0]))


def tyre(t, R, z_out, z_in, n, lug_rows=2, glow=True, hub_r=0.16, rim=True):
    """A tyre about the origin, axle Z, from z_out (the outer, -Z face) to z_in. Sidewalls toned by
    the light, a shoulder, a dark tread and raised lugs staggered row to row; on the outer face a
    sunset ring, a dished rim, six bolts and the hub cap - the parts that SPIN, so the roll shows."""
    O = (0.0, 0.0, 0.0)
    sh = 0.06 * R / 0.85
    tread = R - 0.06
    side_in = R * 0.58
    _band_z(t, O, side_in, z_out, tread - 0.04, z_out, "m", n)
    _band_z(t, O, side_in, z_in, tread - 0.04, z_in, "m", n)
    if glow:
        _band_z(t, O, tread - 0.12, z_out - 0.004, tread - 0.09, z_out - 0.004, "mglow", n)
    _band_z(t, O, tread - 0.04, z_out, tread, z_out + sh, "m", n)
    _band_z(t, O, tread - 0.04, z_in, tread, z_in - sh, "m", n)
    _band_z(t, O, tread, z_out + sh, tread, z_in - sh, "mflat0", n)
    width = (z_in - sh) - (z_out + sh)
    rows = [(z_out + sh + 0.03 + width * i / lug_rows, z_out + sh + width * (i + 1) / lug_rows - 0.03, 0.5 * (i % 2))
            for i in range(lug_rows)]
    for row, (za, zb, off) in enumerate(rows):
        for k in range(n):
            a0 = 2 * math.pi * (k + off + 0.12) / n
            a1 = 2 * math.pi * (k + off + 0.62) / n

            def P(a, r, z):
                return (r * math.cos(a), r * math.sin(a), z)
            lo = [P(a0, tread, za), P(a1, tread, za), P(a1, tread, zb), P(a0, tread, zb)]
            hi = [P(a0, R, za), P(a1, R, za), P(a1, R, zb), P(a0, R, zb)]
            mid = P((a0 + a1) / 2, tread - 0.2, (za + zb) / 2)
            mw._face(t, hi, mid, "mflat2" if (k + row) % 2 else "mflat1", u_hint=th.sub(hi[1], hi[0]))
            for i in (1, 3):
                j = (i + 1) % 4
                mw._face(t, [lo[i], lo[j], hi[j], hi[i]], mid, "mflat0", u_hint=th.sub(lo[j], lo[i]))
    if not rim:                                    # a dual's inner tyre: a plain dish to the hub
        _band_z(t, O, side_in, z_out, hub_r + 0.04, z_out + 0.05, "m", 8)
        _band_z(t, O, side_in, z_in, hub_r + 0.04, z_in - 0.05, "m", 8)
        return
    # the rim, dished in from the sidewall, a sunset lip, bolts on a circle and the cap
    _band_z(t, O, side_in, z_out, side_in - 0.03, z_out + 0.05, "m", 8)
    _band_z(t, O, side_in - 0.03, z_out + 0.05, side_in - 0.06, z_out + 0.05, "mglow", 8)
    _band_z(t, O, side_in - 0.06, z_out + 0.05, 0.0, z_out + 0.12, "mflat0", 8)
    rb = (side_in - 0.06) * 0.55
    for k in range(6):
        a = 2 * math.pi * k / 6
        d = (math.cos(a), math.sin(a), 0.0)
        s = (-math.sin(a), math.cos(a), 0.0)
        em.obox(t, (d[0] * rb, d[1] * rb, z_out + 0.07), (d, s, (0.0, 0.0, 1.0)),
                (0.05 * R / 0.62, 0.035, 0.035), ["mtone3"] * 6)
    mw.oct_tube(t, (0, 0, z_out + 0.12), (0, 0, z_out - 0.04), hub_r, hub_r - 0.03, "m", cap_b="mpin")
    _band_z(t, O, side_in, z_in, hub_r + 0.04, z_in - 0.05, "m", 8)


# ── the light wheel: a swing axle ───────────────────────────────────────────────────────────────

R_L = 0.62                    # tyre radius: three quarters of the Marlit wheel's 0.85
TC_L = (-0.5, -0.10, -1.12)   # the tyre's middle at rest: ride height 0.72 (0.10 + R_L)
TYRE_Z_L = (-1.44, -0.80)     # outer face, inner face
PIV_L = (-0.5, -0.10, 0.02)   # the swing pivot: on the tyre's own axle line, in the drum's mouth
KN_L = (-0.5, -0.10, -0.66)   # the kingpin: between the yoke's lugs at the tube's end
TUBE_R = (0.13, 0.11)         # the tube across its flats at the drum and at the yoke
STRUT_TOP_L = (-0.5, 1.02, 0.18)
STRUT_AT_L = -0.40            # where on the tube (z) the strut's foot is clamped
DRUM_R = 0.32


def build_wlight(pk, img):
    rnd = random.Random(401)
    names = ["body", "arm", "knuckle", "tyre", "dbody", "drod"]
    parts = {"marlit_wlight_" + n: [] for n in names}
    P_ = lambda n: parts["marlit_wlight_" + n]          # noqa: E731
    b = P_("body")
    # the bearing plate on the back face, the faction's window on the face it joins by
    em.marlit_box(b, (-1.38, -0.48, PLATE_Z), (0.38, 1.38, 0.5), 0.06, rnd, {(2, 0): "window"})
    # the final-drive drum, its axis on the tyre's axle line; a sunset ring round its mouth
    cy, cx = PIV_L[1], PIV_L[0]
    DF = PIV_L[2] + 0.04           # the drum's face
    mw.oct_tube(b, (cx, cy, PLATE_Z), (cx, cy, DF + 0.06), DRUM_R, DRUM_R, "m")
    mw.oct_tube(b, (cx, cy, DF + 0.13), (cx, cy, DF + 0.09), DRUM_R + 0.025, DRUM_R + 0.025, "mglow")
    mw.oct_tube(b, (cx, cy, DF + 0.06), (cx, cy, DF), DRUM_R - 0.01, DRUM_R - 0.05, "m")
    mw.band(b, (cx, cy, DF), (cx, cy, -1.0), TUBE_R[0] + 0.08, DRUM_R - 0.05, "mflat1")
    mw.band(b, (cx, cy, DF - 0.002), (cx, cy, -1.0), TUBE_R[0] + 0.04, TUBE_R[0] + 0.08, "mglow")
    # the ring-gear cover's bolts round the drum's face
    for k in range(8):
        a = math.pi / 8 + k * math.pi / 4
        p = (cx + math.cos(a) * (DRUM_R - 0.075), cy + math.sin(a) * (DRUM_R - 0.075), DF - 0.005)
        em.obox(b, p, ((1, 0, 0), (0, 1, 0), (0, 0, 1)), (0.025, 0.025, 0.012), ["mtone4"] * 6)
    # the pivot pin's brackets: two lugs either side of the tube, the pin across them (axis X)
    for sx in (-1, 1):
        x = cx + sx * 0.22
        em.obox(b, (x, cy, PIV_L[2]), ((1, 0, 0), (0, 1, 0), (0, 0, 1)), (0.035, 0.11, 0.09), TONES)
    mw.oct_tube(b, (cx - 0.27, cy, PIV_L[2]), (cx + 0.27, cy, PIV_L[2]), 0.05, 0.05, "m", cap_a="mpin", cap_b="mpin")
    # the strut's top mount: a clevis on a boss high on the plate
    tx, ty, tz = STRUT_TOP_L
    em.obox(b, (tx, ty, (tz + PLATE_Z) / 2 + 0.02), ((1, 0, 0), (0, 1, 0), (0, 0, 1)),
            (0.16, 0.10, (PLATE_Z - tz) / 2 + 0.04), TONES)
    for sx in (-1, 1):
        em.obox(b, (tx + sx * 0.09, ty, tz - 0.03), ((1, 0, 0), (0, 1, 0), (0, 0, 1)), (0.025, 0.08, 0.07), TONES)

    # the ARM: the axle tube, about the pivot. Built in block space, then shifted to PIV_L
    a = P_("arm")
    z0, z1 = PIV_L[2] + 0.04, KN_L[2] + 0.10
    # the boot: a gaiter of three ribs from the drum's mouth over the joint
    zb = [z0, z0 - 0.04, z0 - 0.08, z0 - 0.12, z0 - 0.16]
    rr = [TUBE_R[0] + 0.05, TUBE_R[0] + 0.01, TUBE_R[0] + 0.05, TUBE_R[0] + 0.01, TUBE_R[0]]
    for i in range(4):
        mw.oct_tube(a, (cx, cy, zb[i]), (cx, cy, zb[i + 1]), rr[i], rr[i + 1], "mtone1" if i % 2 else "mtone0")
    mw.band(a, (cx, cy, z0), (cx, cy, 1.0), 0.0, rr[0], "mflat0")
    # the tube, a sunset stripe on its top flat (it swings, never spins: the stripe stays put)
    mw.oct_tube(a, (cx, cy, zb[-1]), (cx, cy, z1), TUBE_R[0], TUBE_R[1], "m")
    # the strut's clamp on the tube: a collar with an eye on top
    mw.oct_tube(a, (cx, cy, STRUT_AT_L + 0.05), (cx, cy, STRUT_AT_L - 0.05), TUBE_R[0] + 0.03, TUBE_R[0] + 0.03, "m",
                cap_a="mflat1", cap_b="mflat1")
    em.obox(a, (cx, cy + TUBE_R[0] + 0.05, STRUT_AT_L), ((1, 0, 0), (0, 1, 0), (0, 0, 1)), (0.06, 0.05, 0.04), TONES)
    mw._face(a, [(cx - 0.035, cy + 0.006 + TUBE_R[0] / math.cos(math.pi / 8) * 0.92, zb[-1] - 0.02),
                 (cx + 0.035, cy + 0.006 + TUBE_R[0] / math.cos(math.pi / 8) * 0.92, zb[-1] - 0.02),
                 (cx + 0.035, cy + 0.006 + TUBE_R[1] / math.cos(math.pi / 8) * 0.92, STRUT_AT_L + 0.06),
                 (cx - 0.035, cy + 0.006 + TUBE_R[1] / math.cos(math.pi / 8) * 0.92, STRUT_AT_L + 0.06)],
             (cx, cy, (zb[-1] + STRUT_AT_L) / 2), "mglow", u_hint=(0, 0, -1))
    # the yoke: two lugs over and under the kingpin
    for sy in (-1, 1):
        em.obox(a, (cx, cy + sy * 0.15, KN_L[2] + 0.02), ((1, 0, 0), (0, 1, 0), (0, 0, 1)), (0.10, 0.035, 0.11), TONES)
    em.obox(a, (cx, cy, z1 + 0.03), ((1, 0, 0), (0, 1, 0), (0, 0, 1)), (0.10, 0.16, 0.04), TONES)
    _shift(a, PIV_L)

    # the KNUCKLE: the hub carrier between the lugs, its pin, the hub flange out to the tyre
    k = P_("knuckle")
    mw.oct_tube(k, (cx, cy - 0.17, KN_L[2]), (cx, cy + 0.17, KN_L[2]), 0.045, 0.045, "m", cap_a="mpin", cap_b="mpin")
    em.obox(k, (cx, cy, KN_L[2] - 0.02), ((1, 0, 0), (0, 1, 0), (0, 0, 1)), (0.09, 0.11, 0.07), TONES)
    mw.oct_tube(k, (cx, cy, KN_L[2] - 0.09), (cx, cy, TYRE_Z_L[1] + 0.01), 0.17, 0.15, "m")
    em.obox(k, (cx + 0.13, cy, KN_L[2] - 0.02), ((1, 0, 0), (0, 1, 0), (0, 0, 1)), (0.05, 0.03, 0.03), TONES)
    _shift(k, KN_L)

    # the TYRE about its middle
    t = P_("tyre")
    tyre(t, R_L, TYRE_Z_L[0] - TC_L[2], TYRE_Z_L[1] - TC_L[2], 14, lug_rows=2, hub_r=0.13)

    # the STRUT: a fat cylinder from the top mount down -Z, a chrome rod up from the foot, eyes at ends
    d = P_("dbody")
    mw.oct_tube(d, (0, 0, 0.0), (0, 0, -0.50), 0.085, 0.085, "m", cap_b="mflat1", sides=6)
    mw.oct_tube(d, (0, 0, -0.20), (0, 0, -0.26), 0.095, 0.095, "mglow", sides=6)
    mw.oct_tube(d, (-0.06, 0, 0.0), (0.06, 0, 0.0), 0.05, 0.05, "m", cap_a="mpin", cap_b="mpin", sides=6)
    r = P_("drod")
    mw.oct_tube(r, (0, 0, 0.0), (0, 0, -0.60), 0.042, 0.042, "msteel", sides=6)
    mw.oct_tube(r, (-0.05, 0, 0.0), (0.05, 0, 0.0), 0.045, 0.045, "m", cap_a="mpin", cap_b="mpin", sides=6)
    return parts


def strut_foot_l(phi):
    """Where the strut's foot stands in block space with the arm swung by phi (rotation.x)."""
    off = (0.0, TUBE_R[0] + 0.05, STRUT_AT_L - PIV_L[2])
    c, s = math.cos(phi), math.sin(phi)
    return (PIV_L[0], PIV_L[1] + off[1] * c - off[2] * s, PIV_L[2] + off[1] * s + off[2] * c)


# ── the heavy wheel: a sliding pillar, a portal box, dual tyres ─────────────────────────────────

R_H = 1.0
AX_H = (-0.5, -0.08)          # (x, z) of the pillar's axis: steering turns about it, the leg slides on it
TC_H = (-0.5, -0.50, -1.00)   # the hub at rest: ride height 1.50 (0.50 + R_H)
TYRES_H = ((-1.44, -1.02), (-0.98, -0.56))   # (outer, inner) faces of each tyre
SLEEVE = (1.08, 0.62)         # the sleeve's top and bottom (y)
SLEEVE_R = 0.22
LEG_R = 0.14
CASE = (-0.04, -0.76)          # the portal case's top and bottom (y) at rest
LINK_X = 0.33                 # the scissor links stand this far +X off the axis
LINK_HI = 0.50                # upper hinge (y), on the collar
LINK_LO = 0.00                # lower hinge (y), on the case at rest
LINK_LEN = 0.30


def scissor(gap):
    """The knee's offset in +X from the hinges' line and each link's angle off the vertical, for a
    vertical gap between the hinges."""
    h = min(gap / 2.0, LINK_LEN * 0.999)
    out = math.sqrt(LINK_LEN * LINK_LEN - h * h)
    return out, math.atan2(out, h)


def _link(f, length, w, zoff):
    """A scissor link down -Y from its hinge: two plates zoff either side and the hinge pins."""
    for sz in (-1, 1):
        em.obox(f, (0, -length / 2, sz * zoff), ((1, 0, 0), (0, 1, 0), (0, 0, 1)), (w, length / 2 + 0.03, 0.018),
                TONES)
    for y in (0.0, -length):
        mw.oct_tube(f, (0, y, -0.08), (0, y, 0.08), 0.035, 0.035, "m", cap_a="mpin", cap_b="mpin", sides=6)


def build_wheavy(pk, img):
    rnd = random.Random(409)
    names = ["body", "collar", "leg", "link_up", "link_lo", "tyre"]
    parts = {"marlit_wheavy_" + n: [] for n in names}
    P_ = lambda n: parts["marlit_wheavy_" + n]          # noqa: E731
    ax, az = AX_H
    b = P_("body")
    em.marlit_box(b, (-1.38, -0.48, PLATE_Z), (0.38, 1.38, 0.5), 0.06, rnd, {(2, 0): "window"})
    # the gearbox: a case high on the plate over the pillar, vents on its sides, the drive turning
    # down into the sleeve under its sunset ring
    gb_lo, gb_hi = (ax - 0.36, SLEEVE[0] - 0.02, az - 0.30), (ax + 0.36, 1.40, PLATE_Z)
    em.cham_box(b, gb_lo, gb_hi, 0.05, "mbev2", "mbev4", "mbev1", "medge")
    for sx in (-1, 1):
        x = ax + sx * 0.362
        mw._face(b, [(x, gb_lo[1] + 0.06, gb_lo[2] + 0.08), (x, gb_lo[1] + 0.06, PLATE_Z - 0.06),
                     (x, gb_hi[1] - 0.06, PLATE_Z - 0.06), (x, gb_hi[1] - 0.06, gb_lo[2] + 0.08)],
                 (ax, 1.2, 0.0), "mvent", u_hint=(0, 0, 1))
    mw.oct_tube(b, (ax, SLEEVE[0] + 0.02, az), (ax, SLEEVE[0] - 0.05, az), SLEEVE_R + 0.06, SLEEVE_R + 0.06, "mglow",
                cap_b="mflat1")
    # the sleeve, two bands where the clamps hold it
    mw.oct_tube(b, (ax, SLEEVE[0], az), (ax, SLEEVE[1], az), SLEEVE_R, SLEEVE_R, "m", cap_b="mflat0")
    for y in (0.98, 0.76):
        mw.oct_tube(b, (ax, y + 0.05, az), (ax, y - 0.05, az), SLEEVE_R + 0.035, SLEEVE_R + 0.035, "m",
                    cap_a="mflat2", cap_b="mflat1")
        for sx in (-1, 1):
            mw.mbox(b, (ax + sx * 0.10 - 0.04, y - 0.05, az + SLEEVE_R), (ax + sx * 0.10 + 0.04, y + 0.05, PLATE_Z))
    # the COLLAR under the sleeve: it turns with the steering; the upper link hangs from its +X ear
    c = P_("collar")
    mw.oct_tube(c, (ax, SLEEVE[1], az), (ax, LINK_HI - 0.04, az), SLEEVE_R + 0.02, SLEEVE_R - 0.01, "m",
                cap_b="mflat0")
    mw.band(c, (ax, SLEEVE[1] - 0.004, az), (ax, -1.0, az), SLEEVE_R - 0.03, SLEEVE_R + 0.02, "mglow")
    em.obox(c, (ax + SLEEVE_R + 0.02, LINK_HI, az), ((1, 0, 0), (0, 1, 0), (0, 0, 1)), (0.09, 0.05, 0.09), TONES)
    _shift(c, (ax, 0.0, az))
    # the LEG: chrome inner tube (it slides into the sleeve), the portal case at its foot, the hub
    g = P_("leg")
    mw.oct_tube(g, (ax, SLEEVE[0] - 0.10, az), (ax, CASE[0], az), LEG_R, LEG_R, "msteel")
    cl, ch = (ax - 0.28, CASE[1], az - 0.30), (ax + 0.28, CASE[0], az + 0.22)
    em.cham_box(g, cl, ch, 0.07, "mbev2", "mbev4", "mbev1", "medge")
    hy = TC_H[1]
    # the ring-gear cover on the case's outer face, round the hub
    mw.oct_tube(g, (ax, hy, cl[2]), (ax, hy, cl[2] - 0.04), 0.27, 0.25, "m", cap_b="mflat1")
    mw.band(g, (ax, hy, cl[2] - 0.042), (ax, hy, -2.0), 0.20, 0.24, "mglow")
    # the case's stripe: a sunset band round its top
    for sx in (-1, 1):
        x = ax + sx * 0.282
        mw._face(g, [(x, CASE[0] - 0.12, cl[2] + 0.08), (x, CASE[0] - 0.12, ch[2] - 0.08),
                     (x, CASE[0] - 0.18, ch[2] - 0.08), (x, CASE[0] - 0.18, cl[2] + 0.08)],
                 (ax, hy, az), "mglow", u_hint=(0, 0, 1))
    # the stub axle out to the tyres
    mw.oct_tube(g, (ax, hy, cl[2] - 0.04), (ax, hy, TYRES_H[1][1] + 0.01), 0.17, 0.17, "m")
    # the lower link's ear on the case
    em.obox(g, (ax + 0.28 + 0.02, LINK_LO, az), ((1, 0, 0), (0, 1, 0), (0, 0, 1)), (0.06, 0.05, 0.09), TONES)
    _shift(g, (ax, 0.0, az))
    # the scissor links, each about its own hinge, hanging -Y at rest angle 0
    _link(P_("link_up"), LINK_LEN, 0.045, 0.065)
    _link(P_("link_lo"), LINK_LEN, 0.035, 0.03)
    # the dual tyres about the hub: the outer one shows the rim and cap, the inner one a plain dish
    t = P_("tyre")
    (o0, o1), (i0, i1) = TYRES_H
    tyre(t, R_H, o0 - TC_H[2], o1 - TC_H[2], 14, lug_rows=2, hub_r=0.19)
    tyre(t, R_H, i0 - TC_H[2], i1 - TC_H[2], 14, lug_rows=2, glow=False, hub_r=0.19, rim=False)
    # the spacer between them
    mw.oct_tube(t, (0, 0, o1 - TC_H[2]), (0, 0, i0 - TC_H[2]), 0.30, 0.30, "m")
    return parts


def heavy_pose(sag, steer):
    """Transforms (in block space) the scene gives each heavy part for a hub rise `sag` and a steer
    angle: returns {part: (basis rows as a 3x3, origin)}. Used by the picture harness and, once the
    block is wired, mirrored by its script."""
    out = {}

    def rot_y(a):
        c, s = math.cos(a), math.sin(a)
        return ((c, 0, s), (0, 1, 0), (-s, 0, c))

    def mul(A, B):
        return tuple(tuple(sum(A[i][k] * B[k][j] for k in range(3)) for j in range(3)) for i in range(3))

    def app(A, v):
        return tuple(sum(A[i][k] * v[k] for k in range(3)) for i in range(3))

    ax, az = AX_H
    R = rot_y(steer)
    out["collar"] = (R, (ax, 0.0, az))
    out["leg"] = (R, (ax, sag, az))
    gap = (LINK_HI) - (LINK_LO + sag)
    _, ang = scissor(gap)
    rz = lambda a: ((math.cos(a), -math.sin(a), 0), (math.sin(a), math.cos(a), 0), (0, 0, 1))  # noqa: E731
    # the upper link leans out (+X in the leg's frame) by ang from hanging straight down
    out["link_up"] = (mul(R, rz(ang)), (ax + app(R, (LINK_X, 0, 0))[0], LINK_HI, az + app(R, (LINK_X, 0, 0))[2]))
    lo = (ax + app(R, (LINK_X, 0, 0))[0], LINK_LO + sag, az + app(R, (LINK_X, 0, 0))[2])
    out["link_lo"] = (mul(R, rz(math.pi - ang)), lo)
    tc = app(R, (TC_H[0] - ax, TC_H[1], TC_H[2] - az))
    out["tyre"] = (R, (ax + tc[0], tc[1] + sag, az + tc[2]))
    return out


em.BLOCKS["marlit_wlight"] = (419, build_wlight, 512)
em.BLOCKS["marlit_wheavy"] = (421, build_wheavy, 512)
em.DENSITY["marlit_wlight"] = 36.0
em.DENSITY["marlit_wheavy"] = 32.0
em.CULL |= {"marlit_wlight", "marlit_wheavy"}
if not hasattr(em, "CHECKS"):
    em.CHECKS = {}
CELLS_M = ((-1.5, -0.5, -1.5), (0.5, 1.5, 0.5))
em.CHECKS["marlit_wlight"] = {"cells": ((-1.5, -1.5, -1.5), (0.5, 1.5, 0.5)), "budget": 1250,
                              "origins": {"marlit_wlight_arm": PIV_L, "marlit_wlight_knuckle": KN_L,
                                          "marlit_wlight_tyre": TC_L, "marlit_wlight_dbody": STRUT_TOP_L,
                                          "marlit_wlight_drod": STRUT_TOP_L},
                              "spin": {"marlit_wlight_tyre": (0, 0, 1)}}
em.CHECKS["marlit_wheavy"] = {"cells": ((-1.5, -1.5, -1.5), (0.5, 1.5, 0.5)), "budget": 1700,
                              "origins": {"marlit_wheavy_collar": (AX_H[0], 0, AX_H[1]),
                                          "marlit_wheavy_leg": (AX_H[0], 0, AX_H[1]),
                                          "marlit_wheavy_link_up": (AX_H[0] + LINK_X, LINK_HI, AX_H[1]),
                                          "marlit_wheavy_link_lo": (AX_H[0] + LINK_X, LINK_LO, AX_H[1]),
                                          "marlit_wheavy_tyre": TC_H},
                              "spin": {"marlit_wheavy_tyre": (0, 0, 1)}}

if __name__ == "__main__":
    for nm in (sys.argv[1:] or ["marlit_wlight", "marlit_wheavy"]):
        em.make(nm)
