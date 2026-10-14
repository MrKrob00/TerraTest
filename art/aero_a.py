#!/usr/bin/env python3
"""AERO DRAFT "a": FRAME & COWL - the faction's basic block and standard wheel as a racing chassis.

    python3 art/aero_a.py   -> objects/<name>_texture.png + art/out/<name>.glb + <name>_poses.json
                               for aero_a_block, aero_a_wheel (rest / steer / up / down), aero_a_rig

THE IDEA: a race car is a light TUBE FRAME with skin only where the air needs it. The block is that
frame - a box-section white frame round every face, the windows open so the block is seen through,
a white diagonal brace in each side window leaning back like a speed line - and skin in three places:
a swept blue COWL over the top, low at the nose and rising to the top plane at the tail, with an air
slot between its lip and the frame's top bar; a dark carbon FLOOR; an orange SKID along the nose's
bottom bar. The faction's three bands (blue top, white middle, orange bottom) are its three materials.
No marks: livery only (stripes, pinstripes).

The wheel is the same car's front corner, open-wheel: a white slotted MOUNT PLATE on the back face,
carbon aerofoil A-ARMS (upper and lower, parallel links) out to ball joints on a blue UPRIGHT that
steers on its kingpin, a DRIVE SHAFT with rubber CV boots between the arms, a COILOVER with an
orange spring from the upper arm to a turret on the plate, and a low-profile SLICK with an orange
sidewall band on a light ten-spoke rim. Everything stands in one cell; only the tyre and what holds
it hang below.

Parts of the wheel and their pivots:
  aero_a_wheel_mount      still
  aero_a_wheel_arm_up     about X at PU          aero_a_wheel_arm_lo   about X at PL
  aero_a_wheel_shaft      about X at PS          (all three parallel, so the upright only moves)
  aero_a_wheel_dmp_body   about X at DT          aero_a_wheel_dmp_rod  about X at E (on the upper arm)
  aero_a_wheel_knuckle    upright + hub, steers about the kingpin (vertical through the tyre's middle)
  aero_a_wheel_tyre       tyre + rim, spins about Z at its middle
"""
import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import aero_kit as ak  # noqa: E402
import turret_heads as th  # noqa: E402
import emitter_models as em  # noqa: E402

# ── shared paint ────────────────────────────────────────────────────────────────────────────────

WHITE_LO = (196, 202, 214)          # the frame's inner faces
EDGE = (128, 138, 156)              # a white part's edge line
GLINT = (255, 255, 255)
BLUE_DK = (10, 112, 160)
BLUE_LO = (8, 80, 120)
ORANGE_DK = (176, 62, 10)
SLOT = (14, 15, 20)
STEEL = (150, 156, 170)


def _hash(*v):
    h = 0
    for x in v:
        h = (h * 1000003 + int(math.floor(x * 1000.0))) & 0xFFFFFFFF
    h ^= h >> 13
    h = (h * 0x5bd1e995) & 0xFFFFFFFF
    return (h >> 8) & 0xFFFF


def facet(n):
    """The painted light of a facet (faceted round parts get one tone each)."""
    return ak.lit(n, 0.74, 0.40, 0.14)


# ── geometry helpers ────────────────────────────────────────────────────────────────────────────

def _frame(a, ref=(0, 1, 0)):
    """Two unit vectors across the direction a."""
    a = th.norm(a)
    if abs(th.dot(a, ref)) > 0.9:
        ref = (1, 0, 0)
    e1 = th.norm(th.cross(ref, a))
    e2 = th.cross(a, e1)
    return e1, e2


def prism(faces, c0, c1, r, n, style, cap0=None, cap1=None, phase=0.5, ref=(0, 1, 0), r1=None):
    """An n-sided prism (or frustum, r1) from c0 to c1."""
    t = th.sub(c1, c0)
    e1, e2 = _frame(t, ref)
    a = ak.ring(c0, e1, e2, r, n, phase)
    b = ak.ring(c1, e1, e2, r if r1 is None else r1, n, phase)
    centre = th.mul(th.add(c0, c1), 0.5)
    for i in range(n):
        j = (i + 1) % n
        ak.face(faces, [a[i], a[j], b[j], b[i]], centre, style, u_hint=th.norm(t))
    if cap0:
        ak.face(faces, a, th.add(c0, th.mul(th.norm(t), 0.05)), cap0, u_hint=e1)
    if cap1:
        ak.face(faces, b, th.sub(c1, th.mul(th.norm(t), 0.05)), cap1, u_hint=e1)


def inset(poly, c):
    """A convex 2D polygon (either winding) with every edge moved in by c."""
    n = len(poly)
    area = sum(poly[i][0] * poly[(i + 1) % n][1] - poly[(i + 1) % n][0] * poly[i][1] for i in range(n))
    sg = 1.0 if area > 0 else -1.0
    lines = []
    for i in range(n):
        (ax_, ay), (bx, by) = poly[i], poly[(i + 1) % n]
        ex, ey = bx - ax_, by - ay
        L = math.hypot(ex, ey)
        nx, ny = -ey / L * sg, ex / L * sg          # into the polygon
        lines.append(((ax_ + nx * c, ay + ny * c), (ex, ey)))
    out = []
    for i in range(n):
        (p, d1), (q, d2) = lines[i - 1], lines[i]
        den = d1[0] * d2[1] - d1[1] * d2[0]
        t = ((q[0] - p[0]) * d2[1] - (q[1] - p[1]) * d2[0]) / den
        out.append((p[0] + d1[0] * t, p[1] + d1[1] * t))
    return out


def cham_prism(faces, poly, z0, z1, c, front, back, side, cham):
    """A convex (x, y) polygon extruded along Z from z0 to z1, every edge chamfered by c."""
    inn = inset(poly, c)
    rings = [[(p[0], p[1], z0) for p in inn], [(p[0], p[1], z0 + c) for p in poly],
             [(p[0], p[1], z1 - c) for p in poly], [(p[0], p[1], z1) for p in inn]]
    cx = sum(p[0] for p in poly) / len(poly)
    cy = sum(p[1] for p in poly) / len(poly)
    centre = (cx, cy, (z0 + z1) / 2)
    n = len(poly)
    for g, st in enumerate((cham, side, cham)):
        a, b = rings[g], rings[g + 1]
        for i in range(n):
            j = (i + 1) % n
            ak.face(faces, [a[i], a[j], b[j], b[i]], centre, st, u_hint=th.sub(a[j], a[i]))
    ak.face(faces, rings[0], (cx, cy, z1), front, u_hint=(1, 0, 0))
    ak.face(faces, rings[3], (cx, cy, z0), back, u_hint=(1, 0, 0))


def section_bar(faces, a, b, sec, up, style, cap_a=None, cap_b=None):
    """A bar from a to b with the 2D section `sec` [(s, u), ...] (s across, u along `up`)."""
    t = th.norm(th.sub(b, a))
    u = th.norm(th.sub(up, th.mul(t, th.dot(up, t))))
    s = th.cross(t, u)

    def ring(base):
        return [th.add(base, th.add(th.mul(s, p[0]), th.mul(u, p[1]))) for p in sec]
    ra, rb = ring(a), ring(b)
    centre = th.mul(th.add(a, b), 0.5)
    m = len(sec)
    for i in range(m):
        j = (i + 1) % m
        ak.face(faces, [ra[i], ra[j], rb[j], rb[i]], centre, style, u_hint=t)
    if cap_a:
        ak.face(faces, ra, th.add(a, th.mul(t, 0.05)), cap_a, u_hint=s)
    if cap_b:
        ak.face(faces, rb, th.sub(b, th.mul(t, 0.05)), cap_b, u_hint=s)


def lens(w, h):
    """The aerofoil section of a wishbone leg: a flat hexagon, sharp at both edges."""
    return [(-w / 2, 0.0), (-w / 4, -h / 2), (w / 4, -h / 2), (w / 2, 0.0), (w / 4, h / 2), (-w / 4, h / 2)]


def lathe(faces, c, axis, prof, n, styles, phase=0.5):
    """Rings of `prof` [(radius, offset along axis), ...] round the axis through c."""
    e1, e2 = _frame(axis, (0, 1, 0))
    rings = [ak.ring(th.add(c, th.mul(axis, o)), e1, e2, r, n, phase) for r, o in prof]
    for i in range(len(rings) - 1):
        st = styles[i] if isinstance(styles, (list, tuple)) else styles
        if not st:
            continue
        a, b = rings[i], rings[i + 1]
        for j in range(n):
            k = (j + 1) % n
            faces.append(th.Face([a[j], a[k], b[k], b[j]], st, u_hint=axis))   # wound by the caller
    return rings


# ═══════════════════════════════════════════════════════════════════════════════════════════════
# THE BLOCK
# ═══════════════════════════════════════════════════════════════════════════════════════════════

T = 0.100          # the frame bar's width (and depth into the cell)
B = 0.016          # the bevel on each window's edge
O = 0.5 - ak.C     # a face's flat ring, outer edge
W0 = 0.5 - T + B   # its inner edge (where the window bevel starts)
W1 = 0.5 - T       # the window's wall
BX = W1 - 0.012    # the body's sides, just inside the side frames
BZ = W1 - 0.010    # its tail and nose
BODY_Y = -0.06     # its flat underside
# the body's side profile (z, y) from the tail along the top to the nose: flat over the tail, then two
# straight facets down to the nose - a wedge with creases, not a rounded cap
TOP = [(BZ, 0.5 - B), (0.16, 0.5 - B), (-0.10, 0.355), (-BZ, 0.085)]
FLOOR_Y = -0.5 + 0.055
GUSSET = 0.15


def _axes(axis):
    i = "xyz".index(axis)
    return i, [k for k in range(3) if k != i]


def _pt(i, oth, plane, u, v):
    p = [0.0, 0.0, 0.0]
    p[i] = plane
    p[oth[0]] = u
    p[oth[1]] = v
    return tuple(p)


def window_frame(f, axis, sgn):
    """One face of the frame: the flat ring on the cell plane, the 1-texel bevel into the window,
    and the window's four walls down to the bar's depth."""
    i, oth = _axes(axis)
    pl = 0.5 * sgn
    centre = (0.0, 0.0, 0.0)
    dep = lambda d: pl - sgn * d
    corners = [(-1, -1), (1, -1), (1, 1), (-1, 1)]
    for k in range(4):
        (ua, va), (ub, vb) = corners[k], corners[(k + 1) % 4]
        ring = [_pt(i, oth, pl, ua * O, va * O), _pt(i, oth, pl, ub * O, vb * O),
                _pt(i, oth, pl, ub * W0, vb * W0), _pt(i, oth, pl, ua * W0, va * W0)]
        ak.face(f, ring, centre, "fr")
        mu, mv = (ua + ub) / 2, (va + vb) / 2
        bar_c = _pt(i, oth, dep(T / 2), mu * (0.5 - T / 2), mv * (0.5 - T / 2))   # inside the bar
        bev = [_pt(i, oth, pl, ua * W0, va * W0), _pt(i, oth, pl, ub * W0, vb * W0),
               _pt(i, oth, dep(B), ub * W1, vb * W1), _pt(i, oth, dep(B), ua * W1, va * W1)]
        ak.face(f, bev, bar_c, "bev")
        wall = [_pt(i, oth, dep(B), ua * W1, va * W1), _pt(i, oth, dep(B), ub * W1, vb * W1),
                _pt(i, oth, dep(T), ub * W1, vb * W1), _pt(i, oth, dep(T), ua * W1, va * W1)]
        ak.face(f, wall, bar_c, "frw")


def build_block():
    f = []
    # the cbox's edges and corners only: its six faces are the window frames
    ak.cbox(f, (-0.5, -0.5, -0.5), (0.5, 0.5, 0.5), ak.C,
            {"side": None, "+y": None, "-y": None, "edge": "ch"})
    for ax in "xyz":
        for s in (-1, 1):
            window_frame(f, ax, s)
    # the side windows: a diagonal brace leaning back (bottom front -> top back), a gusset at each end
    for sx in (-1, 1):
        x = sx * (0.5 - 0.046)
        a = (x, -W1 + 0.012, -W1 + 0.012)
        b = (x, W1 - 0.012, W1 - 0.012)
        prism(f, a, b, 0.030, 6, "tube", ref=(1, 0, 0), phase=0.0)
        xg = sx * (0.5 - 0.030)
        for cy, cz in ((-1, -1), (1, 1)):
            y0, z0 = cy * W1, cz * W1
            ak.face(f, [(xg, y0, z0), (xg, y0 - cy * GUSSET, z0), (xg, y0, z0 - cz * GUSSET)],
                    (0.0, 0.0, 0.0), "gus", u_hint=(0, 0, 1))
    # the body: a blue wedge in the upper half, low at the nose and up to the top plane at the tail
    poly = [(BODY_Y, BZ)] + [(y, z) for z, y in TOP] + [(BODY_Y, -BZ)]
    walls = ["bback"] + ["cowl"] * (len(TOP) - 1) + ["nose", "bunder"]
    ak.extrude(f, poly, "x", -BX, BX, ("bside", "bside"), walls, convex=True)
    # the floor: a carbon pan filling the bottom window
    ak.cbox(f, (-W1, -0.5 + B, -W1), (W1, FLOOR_Y, W1), 0.01,
            {"side": "floore", "+y": "floor", "-y": None, "edge": "floore"})
    return {"aero_a_block_body": f}, {}


def _top_at(z):
    """The body's top line at z."""
    for (za, ya), (zb, yb) in zip(TOP, TOP[1:]):
        if zb <= z <= za:
            return ya + (yb - ya) * (z - za) / (zb - za)
    return TOP[-1][1] if z < 0 else TOP[0][1]


def paint_block(style, P, n, d, part, origin):
    k = ak.lit(n)
    x, y, z = P
    tx = 1.0 / ak.DENS
    if style in ("fr", "frw", "bev", "ch"):
        # the bottom ring of bars is the orange skid: the faction's bottom band
        if y < -0.5 + T + 0.002 and (abs(z) > W1 - 0.002 or abs(x) > W1 - 0.002):
            if style in ("bev", "ch"):
                return ak.tone(ak.mix(ak.ORANGE, GLINT, 0.45), 1.0)
            if style == "fr" and d >= 1.0 and n[1] > -0.5:
                u = x if abs(n[2]) > 0.5 else z
                if abs(u) < W1 - 0.03 and (int((u + 0.5) * ak.DENS) % 9) == 4:
                    return ak.tone(ORANGE_DK, k)               # bolts along the skid
            return ak.tone(ak.ORANGE if style == "fr" else ORANGE_DK, k * (1.0 if style == "fr" else 0.95))
        if style == "ch":
            return ak.tone(GLINT, 1.0)
        if style == "bev":
            return ak.tone(ak.mix(ak.WHITE, GLINT, 0.6), 1.0)
        if style == "frw":
            return ak.jitter(ak.tone(WHITE_LO, ak.lit(n, 0.72, 0.30, 0.10)), 1)
        if d < 1.0:
            return ak.tone(EDGE, k)
        # the flat ring: white; at each corner a grey node plate with its bolt
        q = [abs(P[j]) for j in range(3) if abs(n[j]) < 0.5]
        if len(q) == 2 and min(q) > W0 - 0.002:
            c0 = 0.5 - T / 2 + 0.008
            if abs(q[0] - c0) < 0.75 * tx and abs(q[1] - c0) < 0.75 * tx:
                return ak.tone((64, 70, 86), k)
            return ak.tone((206, 212, 224), k)
        return ak.jitter(ak.tone(ak.WHITE, k), 1)
    if style == "tube":
        kk = facet(n)
        if d < 0.7:
            return ak.tone(EDGE, kk)
        return ak.jitter(ak.tone(ak.WHITE, kk), 1)
    if style == "gus":
        # a gusset plate with its lightening hole
        cy = -1 if y < 0 else 1
        gy, gz = cy * (W1 - GUSSET / 3), cy * (W1 - GUSSET / 3)
        r = math.hypot(y - gy, z - gz)
        if d < 1.0:
            return ak.tone(EDGE, k)
        if r < 0.026:
            return ak.tone(SLOT, 1.0) if r < 0.019 else ak.tone(EDGE, k)
        return ak.tone(ak.WHITE, k * 0.95)
    if style == "cowl":
        ax_ = abs(x)
        if ax_ > BX - 1.2 * tx:
            return ak.tone(ak.mix(ak.BLUE, GLINT, 0.55), 1.0)      # the edges' glint
        crease = [zz for zz, yy in TOP[1:-1]]
        if any(0.0 <= zc_ - z < 1.0 * tx for zc_ in crease) and n[2] < -0.05:
            return ak.tone(ak.mix(ak.BLUE, GLINT, 0.45), 1.0)      # a crease catches the light below it
        # twin white racing stripes down the cowl, an orange pinstripe inside each edge
        if 0.040 < ax_ < 0.100:
            return ak.jitter(ak.tone(ak.WHITE, k), 1)
        if 0.300 < ax_ < 0.322:
            return ak.tone(ak.ORANGE, k)
        # louvres across the flat tail: dark slots, each with its lit lip in front
        if z > 0.14 and 0.135 < ax_ < 0.27:
            for zs in (0.19, 0.27, 0.35):
                if zs - 0.026 < z < zs + 0.016:
                    return ak.tone(SLOT, 1.0) if z > zs - 0.006 else ak.tone(ak.mix(ak.BLUE, GLINT, 0.5), k)
        return ak.jitter(ak.tone(ak.BLUE, k), 1)
    if style == "bside":
        top = _top_at(z)
        if top - y < 1.2 * tx:
            return ak.tone(ak.mix(ak.BLUE, GLINT, 0.55), 1.0)
        if y - BODY_Y < 2.2 * tx:
            return ak.tone(ak.ORANGE, k)                         # the orange pinstripe along its foot
        if top - y < 3.2 * tx and top - y > 2.0 * tx:
            return ak.tone(ak.WHITE, k)                          # a white pinstripe under the top line
        if z < -BZ + 1.2 * tx or z > BZ - 1.2 * tx:
            return ak.tone(BLUE_DK, k)
        # three vents cut along the flank
        for ys in (0.13, 0.21, 0.29):
            if ys - 0.018 < y < ys + 0.010 and 0.02 < z < 0.30 and z - 0.02 > (0.29 - ys) * 0.6:
                return ak.tone(SLOT, 1.0) if y > ys - 0.006 else ak.tone(ak.mix(ak.BLUE, GLINT, 0.4), k)
        return ak.jitter(ak.tone(ak.BLUE, k * 0.97), 1)
    if style == "bback":
        if d < 1.0:
            return ak.tone(BLUE_DK, k)
        # the tail: a grille of dark slots over an orange light bar
        if abs(x) < 0.30 and 0.30 < y < 0.44:
            if int((y - 0.30) * ak.DENS) % 3 == 0:
                return ak.tone(ak.mix(ak.BLUE, GLINT, 0.3), k)
            return ak.tone(SLOT, 1.0)
        if abs(x) < 0.30 and 0.18 < y < 0.23:
            return ak.tone(ak.ORANGE, 1.05)
        return ak.jitter(ak.tone(ak.BLUE, k), 1)
    if style == "nose":
        # the nose: an orange leading edge over a dark intake with its grille
        top = TOP[-1][1]
        if top - y < 2.2 * tx:
            return ak.tone(ak.mix(ak.ORANGE, GLINT, 0.35) if top - y < 1.0 * tx else ak.ORANGE, 1.0)
        if abs(x) > BX - 2.2 * tx or y - BODY_Y < 1.5 * tx:
            return ak.tone(BLUE_DK, k)
        if int((top - y) * ak.DENS) % 3 == 0:
            return ak.tone((70, 76, 92), k)
        return ak.tone(SLOT, 1.0)
    if style == "bunder":
        return ak.carbon(P, n, 0.85)
    if style in ("floor", "floore"):
        if style == "floore":
            return ak.tone((60, 62, 70), k)
        return ak.carbon(P, n, 1.0)
    return (255, 0, 255)


ak.model("aero_a_block", 501, build_block, paint_block, tex=512)
em.CHECKS["aero_a_block"] = {"cells": ((-0.5, -0.5, -0.5), (0.5, 0.5, 0.5)), "budget": 700}


# ═══════════════════════════════════════════════════════════════════════════════════════════════
# THE WHEEL
# ═══════════════════════════════════════════════════════════════════════════════════════════════

TR = 0.42            # tyre radius
TW = 0.14            # half its width
RIDE = 0.88
YC = -RIDE + TR      # the tyre's middle
ZC = -0.20           # ... and where it stands along Z: 25 deg of steer keeps it in the cell
RIM = 0.29           # the bead
K0 = (0.0, YC, ZC)   # kingpin through the tyre's middle
HB = 0.14            # ball joints this far over and under the hub
Z_IN = 0.36          # inboard pivots
V = (0.0, -0.13, ZC - Z_IN)     # every link: from its inboard pivot to its outboard end
PU = (0.0, YC + HB - V[1], Z_IN)
PS = (0.0, YC - V[1], Z_IN)
PL = (0.0, YC - HB - V[1], Z_IN)
LEG_X = 0.19         # the A-arms' inboard legs stand this far out along X
# the mount: a trapezoid flush on the back face, as wide as the pickups at its foot and narrowing to
# the coilover's turret - a bulkhead, not a board
MOUNT = [(-0.30, -0.50), (0.30, -0.50), (0.14, 0.27), (-0.14, 0.27)]
MZ = (0.40, 0.50)
F_EYE = 0.60         # the coilover's lower eye, this far out along the upper arm
DT = (0.0, 0.20, 0.335)          # ... and its top eye on the plate's turret


def _eye():
    return th.add(PU, th.mul(V, F_EYE))


def build_wheel():
    P = {k: [] for k in ("aero_a_wheel_mount", "aero_a_wheel_arm_up", "aero_a_wheel_arm_lo",
                         "aero_a_wheel_shaft", "aero_a_wheel_dmp_body", "aero_a_wheel_dmp_rod",
                         "aero_a_wheel_knuckle", "aero_a_wheel_tyre")}
    # ── the mount plate: white, flush on the back face, its face toward the tyre carrying the
    # pickups; lightening slots and the coilover's turret
    m = P["aero_a_wheel_mount"]
    cham_prism(m, MOUNT, MZ[0], MZ[1], ak.C, "plate", "pl_back", "pl_side", "ch")
    for sx in (-1, 1):
        for py in (PU[1], PL[1]):
            th.box(m, (sx * LEG_X - 0.04, py - 0.03, 0.335), (sx * LEG_X + 0.04, py + 0.03, 0.40), "brk",
                   skip=("+z",))
    # the shaft's output: a round housing on the plate
    prism(m, (0.0, PS[1], 0.40), (0.0, PS[1], 0.345), 0.052, 8, "hous", cap1="hous_cap", ref=(0, 1, 0))
    # the turret the coilover hangs from
    th.box(m, (-0.045, DT[1] - 0.05, 0.33), (0.045, DT[1] + 0.04, 0.40), "brk", skip=("+z",))

    # ── the A-arms: carbon aerofoil legs from the two pickups to the ball joint
    for part, piv in (("aero_a_wheel_arm_up", PU), ("aero_a_wheel_arm_lo", PL)):
        a = P[part]
        bj = th.add(piv, V)
        for sx in (-1, 1):
            ia = (sx * LEG_X, piv[1], piv[2])
            ob = th.add(bj, (sx * 0.028, 0.0, 0.02))
            section_bar(a, th.add(ia, (0, 0, -0.01)), ob, lens(0.088, 0.036), (0, 1, 0), "arm")
            prism(a, (sx * LEG_X - 0.06, piv[1], piv[2]), (sx * LEG_X + 0.06, piv[1], piv[2]), 0.022, 6,
                  "bush", cap0="bush_cap", cap1="bush_cap", ref=(0, 1, 0), phase=0.0)
        # the ball joint's housing
        prism(a, th.add(bj, (0, -0.03, 0)), th.add(bj, (0, 0.03, 0)), 0.036, 8, "bj", cap0="bj_cap",
              cap1="bj_cap", ref=(1, 0, 0))
        if part == "aero_a_wheel_arm_up":
            # a bridge across the legs where the coilover bolts on
            e = _eye()
            w = LEG_X * (1 - F_EYE) + 0.03
            th.box(a, (e[0] - w, e[1] - 0.016, e[2] - 0.025), (e[0] + w, e[1] + 0.016, e[2] + 0.025), "arm")

    # ── the drive shaft with its two CV boots
    s = P["aero_a_wheel_shaft"]
    so = th.add(PS, V)
    t = th.norm(V)
    p0 = th.add(PS, th.mul(t, -0.01))
    prism(s, p0, th.sub(so, th.mul(t, 0.07)), 0.020, 8, "shaft", ref=(1, 0, 0))
    prism(s, th.add(PS, th.mul(t, -0.012)), th.add(PS, th.mul(t, 0.075)), 0.046, 8, "boot",
          r1=0.024, ref=(1, 0, 0), cap0="boot_cap")
    prism(s, th.sub(so, th.mul(t, 0.15)), th.sub(so, th.mul(t, 0.065)), 0.024, 8, "boot",
          r1=0.044, ref=(1, 0, 0), cap1="boot_cap")

    # ── the coilover: a body with the orange spring hanging from the turret, a rod up from the arm
    e = _eye()
    dirn = th.norm(th.sub(e, DT))
    L = math.sqrt(sum((e[i] - DT[i]) ** 2 for i in range(3)))
    body = P["aero_a_wheel_dmp_body"]
    prism(body, DT, th.add(DT, th.mul(dirn, 0.05)), 0.026, 8, "dmp_top", cap0="bush_cap", ref=(1, 0, 0))
    prism(body, th.add(DT, th.mul(dirn, 0.05)), th.add(DT, th.mul(dirn, L * 0.62)), 0.042, 8, "spring",
          cap0="dmp_cap", cap1="dmp_cap", ref=(1, 0, 0))
    rod = P["aero_a_wheel_dmp_rod"]
    prism(rod, th.add(e, th.mul(dirn, 0.0)), th.sub(e, th.mul(dirn, L * 0.72)), 0.013, 6, "rod",
          ref=(1, 0, 0))
    prism(rod, (e[0] - 0.035, e[1], e[2]), (e[0] + 0.035, e[1], e[2]), 0.022, 8, "bush",
          cap0="bush_cap", cap1="bush_cap", ref=(0, 1, 0))

    # ── the upright: blue, between the ball joints, steering about the kingpin; the hub out of it
    k = P["aero_a_wheel_knuckle"]
    ak.cbox(k, (-0.040, YC - HB + 0.025, ZC - 0.03), (0.040, YC + HB - 0.025, ZC + 0.045), 0.012,
            {"side": "upr", "edge": "upr_e"})
    prism(k, (0.0, YC, ZC - 0.03), (0.0, YC, ZC - 0.068), 0.040, 8, "hub", ref=(0, 1, 0))

    # ── the tyre: a low slick on a light ten-spoke rim
    ty = P["aero_a_wheel_tyre"]
    n = 18
    zt = (0, 0, 1)
    prof = [(RIM, -0.128), (0.392, -TW), (TR, -0.112), (TR, 0.112), (0.392, TW), (RIM, 0.128)]
    lathe(ty, K0, zt, prof, n, ["side", "shoulder", "tread", "shoulder", "side"])
    # the rim: lip, a dished spoke face, the barrel inside, the centre lock
    lathe(ty, K0, zt, [(RIM, -0.128), (0.262, -0.118), (0.034, -0.072)], n, ["rim_lip", "rim_face"])
    lathe(ty, K0, zt, [(RIM, -0.128), (RIM, 0.128)], n, ["barrel"])
    prism(ty, (0.0, YC, ZC - 0.07), (0.0, YC, ZC - 0.118), 0.036, 6, "nut", cap1="nut_cap",
          ref=(0, 1, 0), phase=0.0)
    for f in ty:
        if f.style in ("side", "shoulder", "tread", "rim_lip", "rim_face", "rim_hub", "barrel"):
            c = th.mul(tuple(map(sum, zip(*f.pts))), 1.0 / len(f.pts))
            nn = th.newell(f.pts)
            if f.style == "barrel":
                # seen from inside the tyre: the barrel faces the axle
                o = (K0[0], K0[1], c[2])
                if th.dot(nn, th.sub(c, o)) > 0:
                    f.pts = list(reversed(f.pts))
            elif f.style in ("rim_face", "rim_hub", "rim_lip"):
                if nn[2] > 0:
                    f.pts = list(reversed(f.pts))
            else:
                o = K0
                if th.dot(nn, th.sub(c, o)) < 0:
                    f.pts = list(reversed(f.pts))
    origins = {"aero_a_wheel_arm_up": PU, "aero_a_wheel_arm_lo": PL, "aero_a_wheel_shaft": PS,
               "aero_a_wheel_dmp_body": DT, "aero_a_wheel_dmp_rod": _eye(),
               "aero_a_wheel_knuckle": K0, "aero_a_wheel_tyre": K0}
    return P, origins


def paint_wheel(style, P, n, d, part, origin):
    k = ak.lit(n)
    x, y, z = P
    if style == "ch":
        return GLINT
    if style in ("plate", "pl_side", "pl_back"):
        if d < 1.0:
            return ak.tone(EDGE, k)
        if style == "pl_side" or d < 2.6:
            return ak.jitter(ak.tone(ak.WHITE, k), 1)
        # inside a white border (measured from the face's own edges, so the slant stays straight):
        # a blue panel with two lightening holes and a rivet in each corner
        if d < 3.6:
            return ak.tone(BLUE_DK, k)
        if style == "plate":
            # one lightening slot across the panel, its lower lip lit
            sx_ = max(0.0, abs(x) - 0.075)
            r = math.hypot(sx_, (y + 0.07) * 1.0)
            if r < 0.030:
                return ak.tone(SLOT, 1.0) if r < 0.020 or y > -0.07 else ak.tone(ak.mix(ak.BLUE, GLINT, 0.5), k)
            for rx_, ry_ in ((-0.20, -0.42), (0.20, -0.42), (-0.06, 0.19), (0.06, 0.19)):
                if abs(x - rx_) < 0.011 and abs(y - ry_) < 0.011:
                    return ak.tone((40, 60, 84), k)
        return ak.jitter(ak.tone(ak.BLUE, k * (1.0 if style == "plate" else 0.9)), 1)
    if style in ("brk", "hous", "hous_cap", "brk_e", "bj", "bj_cap", "bush", "bush_cap", "dmp_top", "nut",
                 "nut_cap", "hub", "dmp_cap"):
        kk = facet(n)
        if style in ("brk_e",):
            return ak.tone(ak.mix(STEEL, GLINT, 0.4), kk)
        if style in ("nut", "nut_cap"):
            return ak.tone(ak.ORANGE if style == "nut" else ak.mix(ak.ORANGE, GLINT, 0.3), kk)
        if style == "dmp_cap":
            return ak.tone(ak.METAL, kk)
        if style in ("bush_cap", "bj_cap", "hous_cap"):
            return ak.tone((60, 64, 74), kk) if d >= 1.0 else ak.tone(STEEL, kk)
        if d < 0.7:
            return ak.tone(ak.mix(STEEL, GLINT, 0.3), kk)
        return ak.tone(STEEL if style != "brk" else (120, 126, 140), kk)
    if style in ("arm", "arm_e"):
        # an aerofoil wishbone in the frame's own white: a white top (the face the game's camera
        # sees), grey-blue flanks with their edge line, and a carbon belly (a weave on 2-texel faces
        # is only noise, so the belly is a plain dark)
        if n[1] > 0.95:
            return ak.jitter(ak.tone(ak.WHITE, 0.98), 1)
        if n[1] > 0.3:
            return ak.tone(EDGE, 1.0) if d < 0.6 else ak.tone(WHITE_LO, 0.86)
        if n[1] > -0.95:
            return ak.jitter((40, 41, 50), 1)
        return ak.jitter((28, 28, 34), 1)
    if style == "shaft":
        return ak.tone(STEEL, facet(n))
    if style in ("boot", "boot_cap"):
        # rubber bellows: dark rings round the boot
        kk = facet(n)
        q = th.sub(P, PS) if part.endswith("shaft") else P
        along = th.dot(q, th.norm(V))
        if (int(along * 48 * 0.5) & 1):
            return ak.tone((24, 24, 29), kk)
        return ak.tone(ak.RUBBER, kk * 1.15)
    if style == "spring":
        kk = facet(n)
        dirn = th.norm(th.sub(_eye(), DT))
        along = th.dot(th.sub(P, DT), dirn)
        if (int(along * 48) % 3) == 0:
            return ak.tone((20, 20, 26), kk)
        return ak.tone(ak.ORANGE, kk)
    if style == "rod":
        return ak.tone(ak.mix(STEEL, GLINT, 0.35), facet(n))
    if style in ("upr", "upr_e"):
        kk = facet(n)
        if style == "upr_e" or d < 1.0:
            return ak.tone(ak.mix(ak.BLUE, GLINT, 0.45), kk)
        return ak.tone(ak.BLUE, kk)
    # the tyre and rim, painted round the axle on the polygon (18 sides), so a ring is straight
    # along each facet instead of a circle stepping across them
    rx, ry = x - K0[0], y - K0[1]
    ang = math.atan2(ry, rx)
    sd = 2 * math.pi / 18
    m = round(ang / sd) * sd
    r = rx * math.cos(m) + ry * math.sin(m)
    if style in ("side", "shoulder", "tread"):
        kk = facet(n)
        if style == "tread":
            # a slick: rubber, two worn lines near the shoulders
            if 0.086 < abs(z - ZC) < 0.098:
                return ak.tone((24, 23, 28), kk)
            return ak.jitter(ak.tone(ak.RUBBER, kk * 1.05), 1)
        if style == "shoulder":
            return ak.tone(ak.mix(ak.RUBBER, (120, 120, 132), 0.30), kk)
        if 0.334 < r < 0.360:
            return ak.tone(ak.ORANGE, kk * 1.05)
        if r < RIM + 0.012:
            return ak.tone((20, 20, 24), kk)
        return ak.jitter(ak.tone(ak.RUBBER, kk * 1.08), 1)
    if style == "barrel":
        return ak.tone((70, 74, 84), facet(n) * 0.8)
    if style == "rim_lip":
        return ak.tone(ak.mix(ak.WHITE, STEEL, 0.25), facet(n))
    if style == "rim_face":
        kk = facet(n)
        rc = math.hypot(rx, ry)
        sp = 2 * math.pi / 7
        da = abs(((ang + sp / 2) % sp) - sp / 2)
        half = 0.030 + 0.016 * (1 - min(rc, 0.25) / 0.25)
        if rc > 0.238:
            return ak.tone(ak.mix(ak.WHITE, STEEL, 0.15), kk)          # the rim's flange
        if rc < 0.072 or da * rc < half:
            if da * rc > half - 1.2 / ak.DENS and rc > 0.072:
                return ak.tone(STEEL, kk * 0.9)                        # the spoke's shaded edge
            return ak.tone(ak.WHITE, kk)
        # between the spokes: the dark of the wheel, and the brake disc's face behind it
        if 0.135 < rc < 0.205:
            return ak.tone((52, 55, 66), 0.95 if rc > 0.142 else 0.7)
        return (14, 14, 19)
    return (255, 0, 255)


ak.model("aero_a_wheel", 502, build_wheel, paint_wheel, tex=512)
em.CHECKS["aero_a_wheel"] = {
    "cells": ((-0.5, -RIDE, -0.5), (0.5, 0.5, 0.5)), "budget": 900,
    "origins": {"aero_a_wheel_arm_up": PU, "aero_a_wheel_arm_lo": PL, "aero_a_wheel_shaft": PS,
                "aero_a_wheel_dmp_body": DT, "aero_a_wheel_dmp_rod": _eye(),
                "aero_a_wheel_knuckle": K0, "aero_a_wheel_tyre": K0},
    "spin": {"aero_a_wheel_tyre": (0, 0, 1), "aero_a_wheel_knuckle": (0, 1, 0)}}


# ── poses ───────────────────────────────────────────────────────────────────────────────────────

def _rx(a):
    c, s = math.cos(a), math.sin(a)
    return [[1, 0, 0], [0, c, -s], [0, s, c]]


def _ry(a):
    c, s = math.cos(a), math.sin(a)
    return [[c, 0, s], [0, 1, 0], [-s, 0, c]]


def _app(A, v):
    return tuple(sum(A[i][k] * v[k] for k in range(3)) for i in range(3))


def _tf(Bm, o):
    return [Bm[0][0], Bm[1][0], Bm[2][0], Bm[0][1], Bm[1][1], Bm[2][1], Bm[0][2], Bm[1][2], Bm[2][2],
            o[0], o[1], o[2]]


def _swing(sag):
    """The turn about X that lifts the end of V by `sag`."""
    lo, hi = -1.2, 1.2
    f = lambda a: _app(_rx(a), V)[1] - V[1] - sag
    if f(lo) > f(hi):
        lo, hi = hi, lo
    for _ in range(80):
        mid = (lo + hi) / 2
        if f(mid) < 0:
            lo = mid
        else:
            hi = mid
    return (lo + hi) / 2


def wheel_pose(sag, steer):
    a = _swing(sag)
    S = _rx(a)
    Tv = th.sub(_app(S, V), V)
    R = _ry(steer)
    I = [[1, 0, 0], [0, 1, 0], [0, 0, 1]]
    out = {"aero_a_wheel_mount": _tf(I, (0, 0, 0)),
           "aero_a_wheel_arm_up": _tf(S, PU), "aero_a_wheel_arm_lo": _tf(S, PL),
           "aero_a_wheel_shaft": _tf(S, PS),
           "aero_a_wheel_knuckle": _tf(R, th.add(K0, Tv)), "aero_a_wheel_tyre": _tf(R, th.add(K0, Tv))}
    e0 = _eye()
    e1 = th.add(PU, _app(S, th.sub(e0, PU)))
    d0 = th.sub(e0, DT)
    d1 = th.sub(e1, DT)
    th_ = math.atan2(d1[2], d1[1]) - math.atan2(d0[2], d0[1])
    D = _rx(th_)
    out["aero_a_wheel_dmp_body"] = _tf(D, DT)
    out["aero_a_wheel_dmp_rod"] = _tf(D, e1)
    return out


def wheel_states():
    st = {}
    for nm, sag, steer in (("rest", 0.0, 0.0), ("steer", 0.0, math.radians(25)), ("up", 0.14, 0.0),
                           ("down", -0.14, 0.0)):
        p = wheel_pose(sag, steer)
        p["_ground"] = -RIDE + sag
        p["_centre"] = [0.0, -0.2, 0.0]
        st[nm] = p
    return st


# ── the rig: two blocks, four wheels, a Falsus block and wheel for scale ────────────────────────

ak.rig("aero_a_rig", [
    ("aero_a_block", ak.place(at=(0, 0, 0))),
    ("aero_a_block", ak.place(at=(0, 0, -1))),
    ("aero_a_wheel", ak.place(yaw=90, at=(-1, 0, 0))),
    ("aero_a_wheel", ak.place(yaw=90, at=(-1, 0, -1))),
    ("aero_a_wheel", ak.place(yaw=-90, at=(1, 0, 0))),
    ("aero_a_wheel", ak.place(yaw=-90, at=(1, 0, -1))),
], ground=-RIDE, extra={
    "_centre": [0.6, -0.2, -0.5],
    "_scenes": [["res://blocks/scenes/block.tscn", [1, 0, 0, 0, 1, 0, 0, 0, 1, 3.2, 0, 0]],
                ["res://blocks/scenes/wheel.tscn", [0, 0, -1, 0, 1, 0, 1, 0, 0, 2.2, 0, 0]]]})


def check_poses():
    """The poses against the cell: every vertex of every part, in every state, inside x/z +-0.5 and
    under y 0.5 (only downward may the tyre and its carriers leave)."""
    parts, origins = build_wheel()
    ok = True
    for nm, pose in wheel_states().items():
        worst = [-1.0, -1.0, -1.0, 0.0]
        for part, faces in parts.items():
            t = pose[part]
            Bm = [[t[0], t[3], t[6]], [t[1], t[4], t[7]], [t[2], t[5], t[8]]]
            o = origins.get(part, (0.0, 0.0, 0.0))
            for f in faces:
                for p in f.pts:
                    q = th.add(_app(Bm, th.sub(p, o)), (t[9], t[10], t[11]))
                    worst[0] = max(worst[0], abs(q[0]) - 0.5)
                    worst[1] = max(worst[1], q[1] - 0.5)
                    worst[2] = max(worst[2], abs(q[2]) - 0.5)
                    worst[3] = min(worst[3], q[1])
        bad = max(worst[:3]) > 0.005
        ok = ok and not bad
        print("  pose %-6s margin to the cell: x %.3f  y %.3f  z %.3f (negative = inside)   lowest y %.3f  %s" % (
            nm, worst[0], worst[1], worst[2], worst[3], "FAIL" if bad else "ok"))
    return ok


if __name__ == "__main__":
    ak.make("aero_a_block")
    ak.make("aero_a_wheel", wheel_states())
    ak.make("aero_a_rig")
    check_poses()
