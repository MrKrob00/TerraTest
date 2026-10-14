#!/usr/bin/env python3
"""AERO'S WHEELS. The LIGHT WHEEL is in the game (`AERO_WHEEL`, blocks/scenes/aero_wheel.tscn, posed by
blocks/scripts/aero_wheel.gd from these very numbers - K0, V, PU, PS, PL, DT, F_EYE: change both
together); it is round one's design A, the player's pick ("basic and light").

    python3 art/aero_wheels.py      -> objects/aero_wheel_texture.png + art/out/aero_wheel.glb + poses
    godot --headless --path <copy> --script res://art/turret_import.gd -- aero_wheel   (on a copy)

The wheel is a race car's front corner, open-wheel: a white slotted MOUNT PLATE on the back face,
carbon aerofoil A-ARMS (upper and lower, parallel links) out to ball joints on a blue UPRIGHT that
steers on its kingpin, a DRIVE SHAFT with rubber CV boots between the arms, a COILOVER with an
orange spring from the upper arm to a turret on the plate, and a low-profile SLICK with an orange
sidewall band on a light ten-spoke rim. Everything stands in one cell; only the tyre and what holds
it hang below. Turned down on the way to it (other sessions and round one): a racing pylon with
wishbones ("the transmission is horrible"), a mudguard ("a half circle over a tyre is lazy"), a wheel
two cells long ("I am not sure it fits in 1^3").

Parts and their pivots:
  aero_wheel_mount      still
  aero_wheel_arm_up     about X at PU          aero_wheel_arm_lo   about X at PL
  aero_wheel_shaft      about X at PS          (all three parallel, so the upright only moves)
  aero_wheel_dmp_body   about X at DT          aero_wheel_dmp_rod  about X at the eye on the upper arm
  aero_wheel_knuckle    upright + hub, steers about the kingpin (vertical through the tyre's middle)
  aero_wheel_tyre       tyre + rim, spins about Z at its middle (in the scene it hangs under a node
                        turned so its X is that axle: wheel.gd rolls about the tyre node's X)
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
    P = {k: [] for k in ("aero_wheel_mount", "aero_wheel_arm_up", "aero_wheel_arm_lo",
                         "aero_wheel_shaft", "aero_wheel_dmp_body", "aero_wheel_dmp_rod",
                         "aero_wheel_knuckle", "aero_wheel_tyre")}
    # ── the mount plate: white, flush on the back face, its face toward the tyre carrying the
    # pickups; lightening slots and the coilover's turret
    m = P["aero_wheel_mount"]
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
    for part, piv in (("aero_wheel_arm_up", PU), ("aero_wheel_arm_lo", PL)):
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
        if part == "aero_wheel_arm_up":
            # a bridge across the legs where the coilover bolts on
            e = _eye()
            w = LEG_X * (1 - F_EYE) + 0.03
            th.box(a, (e[0] - w, e[1] - 0.016, e[2] - 0.025), (e[0] + w, e[1] + 0.016, e[2] + 0.025), "arm")

    # ── the drive shaft with its two CV boots
    s = P["aero_wheel_shaft"]
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
    body = P["aero_wheel_dmp_body"]
    prism(body, DT, th.add(DT, th.mul(dirn, 0.05)), 0.026, 8, "dmp_top", cap0="bush_cap", ref=(1, 0, 0))
    prism(body, th.add(DT, th.mul(dirn, 0.05)), th.add(DT, th.mul(dirn, L * 0.62)), 0.042, 8, "spring",
          cap0="dmp_cap", cap1="dmp_cap", ref=(1, 0, 0))
    rod = P["aero_wheel_dmp_rod"]
    prism(rod, th.add(e, th.mul(dirn, 0.0)), th.sub(e, th.mul(dirn, L * 0.72)), 0.013, 6, "rod",
          ref=(1, 0, 0))
    prism(rod, (e[0] - 0.035, e[1], e[2]), (e[0] + 0.035, e[1], e[2]), 0.022, 8, "bush",
          cap0="bush_cap", cap1="bush_cap", ref=(0, 1, 0))

    # ── the upright: blue, between the ball joints, steering about the kingpin; the hub out of it
    k = P["aero_wheel_knuckle"]
    ak.cbox(k, (-0.040, YC - HB + 0.025, ZC - 0.03), (0.040, YC + HB - 0.025, ZC + 0.045), 0.012,
            {"side": "upr", "edge": "upr_e"})
    prism(k, (0.0, YC, ZC - 0.03), (0.0, YC, ZC - 0.068), 0.040, 8, "hub", ref=(0, 1, 0))

    # ── the tyre: a low slick on a light ten-spoke rim
    ty = P["aero_wheel_tyre"]
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
    origins = {"aero_wheel_arm_up": PU, "aero_wheel_arm_lo": PL, "aero_wheel_shaft": PS,
               "aero_wheel_dmp_body": DT, "aero_wheel_dmp_rod": _eye(),
               "aero_wheel_knuckle": K0, "aero_wheel_tyre": K0}
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


ak.model("aero_wheel", 502, build_wheel, paint_wheel, tex=512)
em.CHECKS["aero_wheel"] = {
    "cells": ((-0.5, -RIDE, -0.5), (0.5, 0.5, 0.5)), "budget": 900,
    "origins": {"aero_wheel_arm_up": PU, "aero_wheel_arm_lo": PL, "aero_wheel_shaft": PS,
                "aero_wheel_dmp_body": DT, "aero_wheel_dmp_rod": _eye(),
                "aero_wheel_knuckle": K0, "aero_wheel_tyre": K0},
    "spin": {"aero_wheel_tyre": (0, 0, 1), "aero_wheel_knuckle": (0, 1, 0)}}


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
    out = {"aero_wheel_mount": _tf(I, (0, 0, 0)),
           "aero_wheel_arm_up": _tf(S, PU), "aero_wheel_arm_lo": _tf(S, PL),
           "aero_wheel_shaft": _tf(S, PS),
           "aero_wheel_knuckle": _tf(R, th.add(K0, Tv)), "aero_wheel_tyre": _tf(R, th.add(K0, Tv))}
    e0 = _eye()
    e1 = th.add(PU, _app(S, th.sub(e0, PU)))
    d0 = th.sub(e0, DT)
    d1 = th.sub(e1, DT)
    th_ = math.atan2(d1[2], d1[1]) - math.atan2(d0[2], d0[1])
    D = _rx(th_)
    out["aero_wheel_dmp_body"] = _tf(D, DT)
    out["aero_wheel_dmp_rod"] = _tf(D, e1)
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
    ak.make("aero_wheel", wheel_states())
    check_poses()
