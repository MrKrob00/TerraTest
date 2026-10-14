#!/usr/bin/env python3
"""AERO DRAFT b - SHELL & TUB: a closed-wheel prototype (Le Mans) cut into one-cell blocks.

    python3 art/aero_b.py          -> aero_b_block, aero_b_wheel (rest/steer/up/down), aero_b_rig
    python3 art/aero_b.py clash    -> also the posed-mechanism clash check

THE BLOCK is a section of a closed-wheel racing body. A dark CARBON TUB shows at the cell's corners as
pillars and in every gap; LIVERY SHELLS are bolted over it, each a real step in the geometry: the BLUE
top shell wraps over the shoulder and overhangs a 3 cm SHADOW GAP, the WHITE side panel is recessed
under it and falls away into a SIDEPOD UNDERCUT, the ORANGE sill stands proud again at the bottom (the
skirt). A NACA duct is sunk into the white, louvres are cut into the blue, the front carries an intake
mouth with vanes and the back a diffuser with strakes. Every face keeps a flat rim on the cell plane.
No marks: only paint, panel lines, fasteners and glints.

THE WHEEL is a WHEEL POD of the same body: a crisp faceted fender (blue crown with louvres, white
flanks) over a grooved slick, its outboard ENDPLATE cut in a tight polygonal arch with an orange lip
that stops above the hub. Behind the tyre, in an open bay between two rails, the mechanism reads:
two carbon A-arms and a drive shaft as three PARALLEL LINKS from the mount plate to the upright inside
the rim (the shaft keeps its length, nothing slides), and an orange COIL-OVER standing from the upper
arm to a bracket on the plate. The kingpin is the tyre's own mid-plane, so the steered tyre stays in
the cell. Parts (pivot):
  aero_b_wheel_pod      still: mount plate, rails, fender, endplate
  aero_b_wheel_arm_up   upper A-arm + damper cross-bar (its pivot line, axis X)
  aero_b_wheel_arm_lo   lower A-arm (same)
  aero_b_wheel_shaft    drive shaft with CV boots (same: the third parallel link)
  aero_b_wheel_knuckle  upright + hub drum (on the kingpin; translates, steers about Y)
  aero_b_wheel_tyre     tyre, rim, centre-lock nut (its centre; spins about Z, steers with the knuckle)
  aero_b_wheel_damper   coil-over body + spring (its lower eye on the upper arm; turns about X)
  aero_b_wheel_rod      damper rod (its top eye on the bracket; turns about X)
"""
import json
import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import aero_kit as ak  # noqa: E402
import turret_heads as th  # noqa: E402
import emitter_models as em  # noqa: E402

ROOT = ak.ROOT
C = ak.C

# ── palette (the kit's, plus tones) ─────────────────────────────────────────────────────────────
BLUE, WHITE, ORANGE, INK, METAL, RUBBER = ak.BLUE, ak.WHITE, ak.ORANGE, ak.INK, ak.METAL, ak.RUBBER
BLUE_DK = (10, 120, 168)
BLUE_HI = (120, 214, 245)
WHITE_LO = (196, 200, 210)
ORANGE_DK = (178, 62, 10)
ORANGE_HI = (255, 170, 96)
GAP = (12, 12, 16)
STEEL = (150, 156, 170)
STEEL_HI = (212, 216, 226)


def mix(a, b, t):
    return ak.mix(a, b, t)


def sh(c, k):
    return ak.tone(c, k)


# ── geometry helpers ────────────────────────────────────────────────────────────────────────────

def cen(pts):
    return th.mul(tuple(map(sum, zip(*pts))), 1.0 / len(pts))


def facen(f, pts, nrm, style, u=None):
    """A planar polygon whose front faces along nrm."""
    ak.face(f, pts, th.sub(cen(pts), th.mul(th.norm(nrm), 0.05)), style, u_hint=u)


def poly_xy(f, poly, z, nz, style, u=(1, 0, 0)):
    """A simple polygon in the XY plane at z, facing +Z (nz=1) or -Z (nz=-1); ear-clipped."""
    for tri in ak.ear_clip(poly):
        facen(f, [(poly[i][0], poly[i][1], z) for i in tri], (0, 0, nz), style, u)


def wall_xy(f, a, b, z0, z1, style, inward=False):
    """The wall under the 2D edge a->b of a CCW polygon, from z0 to z1, facing out of the polygon."""
    dx, dy = b[0] - a[0], b[1] - a[1]
    n = th.norm((dy, -dx, 0.0))
    if inward:
        n = th.mul(n, -1)
    facen(f, [(a[0], a[1], z0), (b[0], b[1], z0), (b[0], b[1], z1), (a[0], a[1], z1)], n, style, (0, 0, 1))


def offset_poly(poly, dist):
    """Move each edge i (poly[i] -> poly[i+1], CCW) inward by dist[i]; the new vertices are where the
    moved edges meet."""
    n = len(poly)
    lines = []
    for i in range(n):
        a, b = poly[i], poly[(i + 1) % n]
        dx, dy = b[0] - a[0], b[1] - a[1]
        L = math.hypot(dx, dy)
        nx, ny = -dy / L, dx / L               # inward for CCW
        lines.append(((a[0] + nx * dist[i], a[1] + ny * dist[i]), (dx / L, dy / L)))
    out = []
    for i in range(n):
        (p1, d1), (p2, d2) = lines[i - 1], lines[i]
        den = d1[0] * d2[1] - d1[1] * d2[0]
        if abs(den) < 1e-9:
            out.append(p2)
            continue
        t = ((p2[0] - p1[0]) * d2[1] - (p2[1] - p1[1]) * d2[0]) / den
        out.append((p1[0] + d1[0] * t, p1[1] + d1[1] * t))
    return out


def frame(axis):
    t = th.norm(axis)
    ref = (0.0, 1.0, 0.0) if abs(t[1]) < 0.9 else (1.0, 0.0, 0.0)
    e1 = th.norm(th.cross(ref, t))
    e2 = th.cross(t, e1)
    return t, e1, e2


def ringp(c, e1, e2, r, n, phase=0.5):
    return [th.add(c, th.add(th.mul(e1, r * math.cos((i + phase) * 2 * math.pi / n)),
                             th.mul(e2, r * math.sin((i + phase) * 2 * math.pi / n)))) for i in range(n)]


def prism(f, c0, c1, r, n, side, cap0=None, cap1=None, phase=0.5, r1=None):
    """A round part as an n-sided prism (or frustum, r -> r1) from c0 to c1."""
    t, e1, e2 = frame(th.sub(c1, c0))
    a = ringp(c0, e1, e2, r, n, phase)
    b = ringp(c1, e1, e2, r if r1 is None else r1, n, phase)
    m = th.mul(th.add(c0, c1), 0.5)
    for i in range(n):
        j = (i + 1) % n
        ak.face(f, [a[i], a[j], b[j], b[i]], m, side, u_hint=t)
    if cap0:
        ak.face(f, a, th.add(c0, th.mul(t, 0.01)), cap0, u_hint=e1)
    if cap1:
        ak.face(f, b, th.sub(c1, th.mul(t, 0.01)), cap1, u_hint=e1)


def bar(f, a, b, w, h, up, side, top=None, bottom=None, cap_a=None, cap_b=None, ch=0.0, cham=None):
    """A bar of w x h section (along up: h) from a to b, its long edges chamfered by ch."""
    t = th.norm(th.sub(b, a))
    u = th.norm(th.sub(up, th.mul(t, th.dot(up, t))))
    s = th.cross(t, u)
    if ch:
        sec, isch = th.octagon(-w / 2, w / 2, -h / 2, h / 2, ch)
    else:
        sec = [(-w / 2, -h / 2), (w / 2, -h / 2), (w / 2, h / 2), (-w / 2, h / 2)]
        isch = [False] * 4
    # sec runs CCW in (s, u); edge i is the bottom when its middle has the lowest u
    m = th.mul(th.add(a, b), 0.5)

    def rr(base):
        return [th.add(base, th.add(th.mul(s, p[0]), th.mul(u, p[1]))) for p in sec]
    ra, rb = rr(a), rr(b)
    k = len(sec)
    for i in range(k):
        j = (i + 1) % k
        mu = (sec[i][1] + sec[j][1]) / 2
        if isch[i]:
            st = cham or side
        elif mu > h / 2 - 1e-6:
            st = top or side
        elif mu < -h / 2 + 1e-6:
            st = bottom or side
        else:
            st = side
        ak.face(f, [ra[i], ra[j], rb[j], rb[i]], m, st, u_hint=t)
    if cap_a:
        ak.face(f, ra, th.add(a, th.mul(t, 0.01)), cap_a, u_hint=s)
    if cap_b:
        ak.face(f, rb, th.sub(b, th.mul(t, 0.01)), cap_b, u_hint=s)


def box(f, lo, hi, styles, skip=()):
    """An axis box; styles: dict by face key ('+x' ...), default 'side'."""
    x0, y0, z0 = lo
    x1, y1, z1 = hi
    F = {
        "+x": ([(x1, y0, z0), (x1, y1, z0), (x1, y1, z1), (x1, y0, z1)], (1, 0, 0)),
        "-x": ([(x0, y0, z0), (x0, y1, z0), (x0, y1, z1), (x0, y0, z1)], (-1, 0, 0)),
        "+y": ([(x0, y1, z0), (x1, y1, z0), (x1, y1, z1), (x0, y1, z1)], (0, 1, 0)),
        "-y": ([(x0, y0, z0), (x1, y0, z0), (x1, y0, z1), (x0, y0, z1)], (0, -1, 0)),
        "+z": ([(x0, y0, z1), (x1, y0, z1), (x1, y1, z1), (x0, y1, z1)], (0, 0, 1)),
        "-z": ([(x0, y0, z0), (x1, y0, z0), (x1, y1, z0), (x0, y1, z0)], (0, 0, -1)),
    }
    for k, (pts, n) in F.items():
        if k in skip:
            continue
        facen(f, pts, n, styles.get(k, styles.get("side")))


# ═════════════════════════════════════════════════════════════════════════════════════════════════
# THE BLOCK
# ═════════════════════════════════════════════════════════════════════════════════════════════════
B = 0.06            # the carbon bulkhead at each end (z): the tub's frame, full square
YS = 0.30           # bottom of the blue shoulder (the shadow gap is under it)
XW = 0.47           # the white side panel stands 3 cm in under the shoulder
YW = 0.0            # where the white panel ends and the carbon sidepod undercut turns in
XU, YU = 0.38, -0.24  # foot of the undercut
YK = -0.30          # top of the orange sill
C2 = 0.018          # the sill's top chamfer
# intake mouth (front, -Z) and diffuser (back, +Z)
XI, YI0, YI1, DI = 0.355, -0.272, -0.025, 0.042
XD, YD0, YD1 = 0.355, -0.272, -0.025
# louvre fields on the top
XL0, XL1, ZL0, ZL1, DLV, NL = 0.19, 0.37, -0.06, 0.32, 0.034, 4
# the NACA duct on each side
ZN0, ZN1, YN, WN0, WN1, DN = -0.30, 0.24, 0.15, 0.022, 0.078, 0.055

Z0, Z1 = -0.5 + B, 0.5 - B


def _right_profile():
    """The body's section, right half, bottom to top (CCW for the whole)."""
    return [(0.5 - C, -0.5), (0.5, -0.5 + C), (0.5, YK - C2), (0.5 - C2, YK), (XU, YK), (XU, YU),
            (XW, YW), (XW, YS), (0.5, YS), (0.5, 0.5 - C), (0.5 - C, 0.5)]


def body_profile():
    r = _right_profile()
    left = [(-x, y) for x, y in reversed(r)]
    return r + left


def _side_styles():
    # one style per edge of the right half (edge i: r[i] -> r[i+1])
    return ["cham", "sill", "cham_o", "sill_top", "carb", "under", "WHITE_SPLIT", "gap", "sh", "cham"]


def build_body(f):
    r = _right_profile()
    sty = _side_styles()
    for i in range(len(r) - 1):
        for sgn in (1, -1):
            a, b = r[i], r[i + 1]
            if sgn < 0:
                a, b = (-b[0], b[1]), (-a[0], a[1])
            if sty[i] == "WHITE_SPLIT":
                naca_panel(f, sgn)
                continue
            wall_xy(f, a, b, Z0, Z1, sty[i])
    # bottom
    facen(f, [(-0.5 + C, -0.5, Z0), (0.5 - C, -0.5, Z0), (0.5 - C, -0.5, Z1), (-0.5 + C, -0.5, Z1)],
          (0, -1, 0), "floor")
    top_with_louvres(f)


def naca_panel(f, sgn):
    """The white upper panel (x = sgn*XW, y YW..YS) with a NACA duct sunk into it."""
    x = sgn * XW
    nrm = (sgn, 0, 0)
    ylo0, yhi0 = YN - WN0, YN + WN0
    ylo1, yhi1 = YN - WN1, YN + WN1

    def q(pts, st="white"):
        facen(f, [(x, y, z) for (z, y) in pts], nrm, st, (0, 0, 1))
    q([(Z0, YW), (ZN0, YW), (ZN0, YS), (Z0, YS)])
    q([(ZN1, YW), (Z1, YW), (Z1, YS), (ZN1, YS)])
    q([(ZN0, yhi0), (ZN1, yhi1), (ZN1, YS), (ZN0, YS)])
    q([(ZN0, YW), (ZN1, YW), (ZN1, ylo1), (ZN0, ylo0)])
    xd = sgn * (XW - DN)
    # ramp floor: flush at the narrow front, DN deep at the wide back
    facen(f, [(x, ylo0, ZN0), (x, yhi0, ZN0), (xd, yhi1 - 0.006, ZN1), (xd, ylo1 + 0.006, ZN1)],
          th.norm((sgn * (ZN1 - ZN0), 0, DN)), "duct", (0, 0, 1))
    # side walls
    facen(f, [(x, yhi0, ZN0), (x, yhi1, ZN1), (xd, yhi1 - 0.006, ZN1)], (0, -1, 0), "duct_wall")
    facen(f, [(x, ylo0, ZN0), (x, ylo1, ZN1), (xd, ylo1 + 0.006, ZN1)], (0, 1, 0), "duct_wall")
    # the mouth at the back of the ramp
    facen(f, [(x, ylo1, ZN1), (x, yhi1, ZN1), (xd, yhi1 - 0.006, ZN1), (xd, ylo1 + 0.006, ZN1)], (0, 0, -1),
          "mouth")


def top_with_louvres(f):
    y = 0.5
    xa = 0.5 - C
    up = (0, 1, 0)

    def q(x0, x1, z0, z1, st="top"):
        facen(f, [(x0, y, z0), (x1, y, z0), (x1, y, z1), (x0, y, z1)], up, st, (1, 0, 0))
    q(-xa, xa, Z0, ZL0)
    q(-xa, xa, ZL1, Z1)
    q(-xa, -XL1, ZL0, ZL1)
    q(-XL0, XL0, ZL0, ZL1)
    q(XL1, xa, ZL0, ZL1)
    yb = y - DLV
    for s in (-1, 1):
        xa0, xa1 = sorted((s * XL0, s * XL1))
        # walls
        facen(f, [(xa0, yb, ZL0), (xa1, yb, ZL0), (xa1, y, ZL0), (xa0, y, ZL0)], (0, 0, 1), "louv_wall")
        facen(f, [(xa0, yb, ZL1), (xa1, yb, ZL1), (xa1, y, ZL1), (xa0, y, ZL1)], (0, 0, -1), "louv_wall")
        facen(f, [(xa0, yb, ZL0), (xa0, y, ZL0), (xa0, y, ZL1), (xa0, yb, ZL1)], (1, 0, 0), "louv_wall")
        facen(f, [(xa1, yb, ZL0), (xa1, y, ZL0), (xa1, y, ZL1), (xa1, yb, ZL1)], (-1, 0, 0), "louv_wall")
        facen(f, [(xa0, yb, ZL0), (xa1, yb, ZL0), (xa1, yb, ZL1), (xa0, yb, ZL1)], up, "louv_floor")
        # slats: each tilted, its top lip at the surface, its foot further back
        pitch = (ZL1 - ZL0) / NL
        for i in range(NL):
            z0 = ZL0 + pitch * (i + 0.15)
            z1 = z0 + pitch * 0.75
            facen(f, [(xa0 + 0.003, y - 0.004, z0), (xa1 - 0.003, y - 0.004, z0),
                      (xa1 - 0.003, yb + 0.004, z1), (xa0 + 0.003, yb + 0.004, z1)],
                  th.norm((0, 0.6, -0.8)), "slat", (1, 0, 0))


def _octring(z):
    a = 0.5 - C
    return [(a, 0.5, z), (0.5, a, z), (0.5, -a, z), (a, -0.5, z), (-a, -0.5, z), (-0.5, -a, z), (-0.5, a, z), (-a, 0.5, z)]


def bulkhead(f, sgn):
    """The carbon frame at one end (sgn -1: front, z -0.5..Z0; +1: back): its outer face with the
    mouth / diffuser, the chamfer ring, the octagon prism, the inner face (seen in the side pockets)."""
    zf = sgn * 0.5
    zc = sgn * (0.5 - C)
    zi = sgn * (0.5 - B)
    a = 0.5 - C
    sq = [(a, a), (-a, a), (-a, -a), (a, -a)]
    ring = _octring(zc)
    centre = (0, 0, 0)
    # chamfer quads between the face square and the ring
    fq = {(1, 0): ((a, -a), (a, a)), (0, 1): ((a, a), (-a, a)), (-1, 0): ((-a, a), (-a, -a)), (0, -1): ((-a, -a), (a, -a))}
    for (nx, ny), (p, q) in fq.items():
        pr = (p[0] + nx * C, p[1] + ny * C)
        qr = (q[0] + nx * C, q[1] + ny * C)
        ak.face(f, [(p[0], p[1], zf), (q[0], q[1], zf), (qr[0], qr[1], zc), (pr[0], pr[1], zc)], centre, "fcham")
    for cx, cy in ((1, 1), (-1, 1), (-1, -1), (1, -1)):
        ak.face(f, [(cx * a, cy * a, zf), (cx * 0.5, cy * a, zc), (cx * a, cy * 0.5, zc)], centre, "fcham")
    # octagon prism zc..zi
    ring2 = _octring(zi)
    for i in range(8):
        j = (i + 1) % 8
        p, q = ring[i], ring[j]
        diag = abs(p[0]) != abs(q[0]) and abs(p[1]) != abs(q[1])
        ak.face(f, [p, q, ring2[j], ring2[i]], (0, 0, zc), "cham" if diag else "post")
    # inner face (only its side pockets show)
    facen(f, ring2, (0, 0, -sgn), "carb")
    if sgn < 0:
        intake(f, zf, sq)
    else:
        diffuser(f, zf)


def _face_frame(f, zf, sgn, x0, x1, y0, y1, st="face"):
    """The face square minus the opening x0..x1, y0..y1."""
    a = 0.5 - C
    n = (0, 0, sgn)

    def q(xa, xb, ya, yb):
        facen(f, [(xa, ya, zf), (xb, ya, zf), (xb, yb, zf), (xa, yb, zf)], n, st, (1, 0, 0))
    q(-a, a, y1, a)
    q(-a, a, -a, y0)
    q(-a, x0, y0, y1)
    q(x1, a, y0, y1)


def _recess(f, zf, sgn, x0, x1, y0, y1, depth, floor, wall="rwall"):
    zb = zf - sgn * depth
    facen(f, [(x0, y1, zf), (x1, y1, zf), (x1, y1, zb), (x0, y1, zb)], (0, -1, 0), wall)
    facen(f, [(x0, y0, zf), (x1, y0, zf), (x1, y0, zb), (x0, y0, zb)], (0, 1, 0), wall)
    facen(f, [(x0, y0, zf), (x0, y1, zf), (x0, y1, zb), (x0, y0, zb)], (1, 0, 0), wall)
    facen(f, [(x1, y0, zf), (x1, y1, zf), (x1, y1, zb), (x1, y0, zb)], (-1, 0, 0), wall)
    facen(f, [(x0, y0, zb), (x1, y0, zb), (x1, y1, zb), (x0, y1, zb)], (0, 0, sgn), floor, (1, 0, 0))
    return zb


def intake(f, zf, sq):
    _face_frame(f, zf, -1, -XI, XI, YI0, YI1)
    zb = _recess(f, zf, -1, -XI, XI, YI0, YI1, DI, "grille")
    # two vanes across the mouth, tilted down to the front
    for yv in (YI0 + (YI1 - YI0) * 0.36, YI0 + (YI1 - YI0) * 0.70):
        t = 0.012
        p0 = [(-XI, yv, zf + 0.004), (XI, yv, zf + 0.004), (XI, yv + 0.02, zb), (-XI, yv + 0.02, zb)]
        facen(f, p0, th.norm((0, 1, 0.5)), "vane", (1, 0, 0))
        p1 = [(-XI, yv - t, zf + 0.004), (XI, yv - t, zf + 0.004), (XI, yv - t + 0.02, zb), (-XI, yv - t + 0.02, zb)]
        facen(f, p1, th.norm((0, -1, -0.5)), "vane_dk", (1, 0, 0))
        facen(f, [(-XI, yv - t, zf + 0.004), (XI, yv - t, zf + 0.004), (XI, yv, zf + 0.004), (-XI, yv, zf + 0.004)],
              (0, 0, -1), "vane_lip", (1, 0, 0))


def diffuser(f, zf):
    _face_frame(f, zf, 1, -XD, XD, YD0, YD1)
    zb = _recess(f, zf, 1, -XD, XD, YD0, YD1, DI, "diff_floor")
    # strakes: thin carbon fins standing in the recess
    for xs in (-XD * 0.5, 0.0, XD * 0.5):
        t = 0.009
        for sg in (-1, 1):
            facen(f, [(xs + sg * t, YD0, zb), (xs + sg * t, YD1, zb), (xs + sg * t, YD1 - 0.03, zf - 0.002),
                      (xs + sg * t, YD0, zf - 0.002)], (sg, 0, 0), "strake", (0, 0, 1))
        facen(f, [(xs - t, YD0, zf - 0.002), (xs + t, YD0, zf - 0.002), (xs + t, YD1 - 0.03, zf - 0.002),
                  (xs - t, YD1 - 0.03, zf - 0.002)], (0, 0, 1), "strake_lip", (0, 1, 0))
        facen(f, [(xs - t, YD1, zb), (xs + t, YD1, zb), (xs + t, YD1 - 0.03, zf - 0.002), (xs - t, YD1 - 0.03, zf - 0.002)],
              th.norm((0, 1, 0.6)), "strake_lip", (1, 0, 0))


def build_block():
    f = []
    build_body(f)
    bulkhead(f, -1)
    bulkhead(f, 1)
    return {"aero_b_block_body": f}, {}


# ── block paint ────────────────────────────────────────────────────────────────────────────────

def band(P):
    y = P[1]
    if y > YS - 0.002:
        return BLUE
    if y < YK + 0.002:
        return ORANGE
    return WHITE


def _fastener(u, v, every, off=0.0):
    """A quick-release fastener every `every` metres along u at v ~ 0: (-1 none, 0 ring, 1 centre)."""
    k = (u - off) / every
    du = (k - round(k)) * every
    if abs(du) < 0.011 and abs(v) < 0.011:
        return 1
    if abs(du) < 0.021 and abs(v) < 0.021:
        return 0
    return -1


def _edge(c, d, light=True):
    if d < 1.0:
        return mix(c, (255, 255, 255), 0.35) if light else mix(c, GAP, 0.45)
    return c


def paint_block(style, P, n, d, part, o):
    x, y, z = P
    k = ak.lit(n)
    if style in ("carb", "floor", "post", "rwall", "louv_wall", "duct_wall", "strake"):
        if style == "post" and n[1] > 0.5:
            return paint_top(P, n, d, k)
        if style == "post" and n[1] < -0.5:
            return ak.carbon(P, n, k)
        if style == "post" and not (YK < y < YS):
            c = band(P)
            return sh(_edge(c, d), k)
        if d < 1.0 and style in ("post", "floor"):
            return sh((70, 72, 82), k)
        return ak.carbon(P, n, k * (0.9 if style in ("rwall", "louv_wall", "duct_wall") else 1.0))
    if style in ("gap", "louv_floor", "mouth", "grille", "diff_floor"):
        if style == "grille":
            # a fine mesh in the dark: every other texel lit
            ix, iy = int(math.floor(x * 48)), int(math.floor(y * 48))
            if (ix + iy) % 2 == 0 and (ix - iy) % 4 == 0:
                return sh((52, 54, 64), k)
            return sh((16, 16, 21), k)
        if style == "diff_floor":
            return ak.carbon(P, n, k * 0.7)
        return sh(GAP, k)
    if style == "duct":
        # the ramp darkens as it sinks, a lit lip where it starts
        t = (z - ZN0) / (ZN1 - ZN0)
        if d < 1.0 and t < 0.08:
            return sh(WHITE_LO, k)
        return sh(mix((70, 74, 86), (22, 22, 28), t), k)
    if style == "slat":
        if d < 1.0:
            return sh(BLUE_HI, k)
        return sh(BLUE_DK, k)
    if style in ("vane", "vane_dk", "vane_lip", "strake_lip"):
        if style == "vane_lip" or style == "strake_lip":
            return sh((96, 100, 114), 1.0)
        return sh((60, 62, 72) if style == "vane" else (28, 28, 34), k)
    if style in ("cham", "cham_o", "fcham"):
        c = band(P)
        if style == "fcham" and YK < y < YS and abs(x) > 0.40:
            return ak.carbon(P, n, k * 1.15)
        if style == "cham_o":
            c = ORANGE
        if n[1] > 0.3 and abs(x) < 0.16:
            c = paint_top(P, (0, 1, 0), 2.0, 1.0)
        # a glint: the chamfer is a light line
        return sh(mix(c, (255, 255, 255), 0.55 if c != ORANGE else 0.35), k)
    if style == "sill_top":
        c = ORANGE_HI if d < 1.0 else ORANGE
        return sh(c, k)
    if style == "sill":
        c = ORANGE
        if d < 1.0:
            c = ORANGE_DK
        # fasteners along the sill's top
        fz = _fastener(z, y - (YK - 0.045), 0.30, 0.15)
        if fz == 1:
            return sh(ORANGE_DK, k)
        if fz == 0:
            c = ORANGE_HI
        return sh(c, k)
    if style == "sh":
        c = BLUE
        if d < 1.0:
            c = BLUE_HI if y > 0.4 else BLUE_DK
        fz = _fastener(z, y - (YS + 0.04), 0.30, 0.0)
        if fz == 1:
            return sh(BLUE_DK, k)
        if fz == 0:
            c = BLUE_HI
        return sh(c, k)
    if style == "under":
        if d < 1.0 and y > YW - 0.03:
            return sh((86, 88, 100), k)
        return ak.carbon(P, n, k * 1.05)
    if style == "white":
        return paint_white(P, n, k)
    if style == "top":
        return paint_top(P, n, d, k)
    if style == "face":
        return paint_face(P, n, d, k)
    return (255, 0, 255)


def _naca_dist(z, y):
    """Distance (m) from (z, y) to the NACA duct's outline on the side panel (0 inside)."""
    t = (z - ZN0) / (ZN1 - ZN0)
    w = WN0 + (WN1 - WN0) * max(0.0, min(1.0, t))
    if 0.0 <= t <= 1.0 and abs(y - YN) <= w:
        return 0.0
    pts = [(ZN0, YN - WN0), (ZN1, YN - WN1), (ZN1, YN + WN1), (ZN0, YN + WN0)]
    return min(_seg2(z, y, pts[i], pts[(i + 1) % 4]) for i in range(4))


def _seg2(px, py, a, b):
    ex, ey = b[0] - a[0], b[1] - a[1]
    l2 = ex * ex + ey * ey or 1e-9
    t = max(0.0, min(1.0, ((px - a[0]) * ex + (py - a[1]) * ey) / l2))
    return math.hypot(px - a[0] - ex * t, py - a[1] - ey * t)


def paint_white(P, n, k):
    x, y, z = P
    edge = min(y - YW, YS - y, z - Z0, Z1 - z) * 48.0
    c = WHITE
    if edge < 1.0:
        c = WHITE_LO
    # an orange pinstripe along the panel's foot, a lit lip round the duct
    if YW + 0.012 < y < YW + 0.032:
        c = ORANGE
    nd = _naca_dist(z, y) * 48.0
    if nd < 1.0:
        c = (150, 154, 166)
    elif nd < 2.0:
        c = (255, 255, 255)
    return sh(c, k)


def paint_top(P, n, d, k):
    x, y, z = P
    ax = abs(x)
    az = abs(z)
    c = BLUE
    # twin racing stripes along the length, a white pair with a blue gap and an orange pinline
    if 0.045 <= ax < 0.115:
        c = WHITE
    elif 0.115 <= ax < 0.135:
        c = BLUE
    elif 0.135 <= ax < 0.155:
        c = ORANGE
    # the panel line: round the rim and round the louvre fields (from position, not the face's edges)
    rim = min(0.5 - C - ax, 0.5 - C - az) * 48.0
    lv = 9.0
    if ZL0 - 0.03 < z < ZL1 + 0.03 and XL0 - 0.03 < ax < XL1 + 0.03:
        lv = min(abs(ax - XL0), abs(ax - XL1), abs(z - ZL0), abs(z - ZL1)) * 48.0
    if rim < 1.0:
        c = mix(c, (255, 255, 255), 0.3)
    elif lv < 1.0:
        c = BLUE_HI
    # fasteners round the louvre fields' outer corners and the panel rim
    for fx in (0.415,):
        for fz in (-0.40, 0.0, 0.40):
            if abs(ax - fx) < 0.011 and abs(z - fz) < 0.011:
                return sh(BLUE_DK, k)
            if abs(ax - fx) < 0.021 and abs(z - fz) < 0.021:
                c = BLUE_HI
    return sh(c, k)


def paint_face(P, n, d, k):
    x, y, z = P
    ax = abs(x)
    if (YK < y < YS and ax > 0.40) or YK < y < YW:
        if YK < y < YK + 0.022 or (YW - 0.02 < y < YW and ax < 0.40):
            return sh((86, 88, 100), k)
        return ak.carbon(P, n, k * 1.1)
    c = band(P)
    if YW + 0.012 < y < YW + 0.032:
        c = ORANGE          # the side panel's foot pinstripe, carried round the corner
    if d < 1.0:
        c = mix(c, GAP, 0.35)
    # a panel line where the blue shell meets the white, and the sill's top glint
    if abs(y - YS) < 0.011:
        c = mix(c, GAP, 0.5)
    if abs(y - (YK + 0.011)) < 0.011:
        c = ORANGE_HI
    if ax > 0.40 and YK - 0.06 < y < YK:
        pass
    # fasteners in the frame corners
    for fx, fy in ((0.42, 0.42), (0.42, -0.42), (0.20, 0.42), (0.20, -0.42)):
        if abs(ax - fx) < 0.011 and abs(y - fy) < 0.011:
            return sh(mix(c, GAP, 0.4), k)
        if abs(ax - fx) < 0.021 and abs(y - fy) < 0.021:
            c = mix(c, (255, 255, 255), 0.4)
    return sh(c, k)


ak.model("aero_b_block", 9101, build_block, paint_block, tex=256)
em.CHECKS["aero_b_block"] = {"cells": ((-0.5, -0.5, -0.5), (0.5, 0.5, 0.5)), "budget": 700}


# ═════════════════════════════════════════════════════════════════════════════════════════════════
# THE WHEEL
# ═════════════════════════════════════════════════════════════════════════════════════════════════
R_T = 0.40          # tyre radius
W_T = 0.30          # tyre width
RIDE = 0.90         # tyre bottom below the block centre
RR = 0.27           # rim radius (low-profile racing tyre: 13 cm of sidewall)
RIM_IN = 0.045      # the rim face is this far inside the outboard sidewall
NT = 16             # tyre sides
YC = -RIDE + R_T    # tyre centre y
ZC = -0.17          # tyre mid-plane = the kingpin line (so a steered tyre stays in the cell)
TC = (0.0, YC, ZC)
JS = 0.12           # ball joints this far above / below the axle, on the kingpin line
ZP = 0.37           # the arms' pivot line (z), in clevises on the mount plate
VY = -0.17          # the links fall this much from mount to upright
V = (0.0, VY, ZC - ZP)
PU = (0.0, YC + JS - VY, ZP)
PL = (0.0, YC - JS - VY, ZP)
PS = (0.0, YC - VY, ZP)          # the drive shaft: the middle link, its outer end the hub centre
K0 = (0.0, YC, ZC)               # knuckle origin: on the kingpin, at the axle
ARM_X = 0.21                     # the A-arms' legs spread to +-ARM_X at the mount
DF = 0.40                        # the damper's lower eye: this far along the upper arm from its pivot
DX = th.add(PU, th.mul(V, DF))   # the cross-bar between the upper arm's legs
DL = th.add(DX, (0.0, 0.045, 0.0))   # the damper's lower eye, in a clevis on the bar
DT = (0.0, 0.21, 0.335)          # the damper's top eye, on the bracket
ZMP = 0.40                       # the mount plate's front face
# the fender
CROWN = [(-0.42, -0.10), (-0.30, 0.04), (-0.14, 0.09), (0.14, 0.09), (0.30, 0.04), (0.42, -0.10),
         (0.47, -0.10), (0.47, 0.06), (0.36, 0.26), (0.16, 0.32), (-0.16, 0.32), (-0.36, 0.26),
         (-0.47, 0.06), (-0.47, -0.10)]
YTOP = 0.32          # a low fender: the tub stands higher between the wheels
YBLUE = 0.17         # the blue shell's lower edge on the fender
CROWN_TOP = [False] * 6 + [True] * 7 + [False]   # sides and top: offset by the inboard bevel
# the outboard plate: the crown's outline plus the legs, minus the arch
PLATE = [(-0.47, -0.46), (-0.41, -0.40), (-0.41, -0.32), (-0.33, -0.16), (-0.16, -0.06), (0.16, -0.06),
         (0.33, -0.16), (0.41, -0.32), (0.41, -0.40), (0.47, -0.46), (0.47, 0.06), (0.36, 0.26),
         (0.16, 0.32), (-0.16, 0.32), (-0.36, 0.26), (-0.47, 0.06)]
PLATE_CH = [False] * 10 + [True] * 5 + [False]   # the top chamfered; arch, feet and legs sharp
ARCH = PLATE[1:9]                       # the arch line (for the orange lip)
ZE0, ZE1 = -0.5, -0.5 + C               # the plate's thickness = one chamfer
ZF1 = -0.02                             # the fender's inboard face
ZLEG = -0.38                            # the legs reach this far in from the outboard face
LOUV = (-0.13, 0.13, -0.42, -0.15, 0.03, 5)   # crown louvres: x0, x1, z0, z1, depth, count
PLATE_OUT = None                        # the plate's face outline (set by build_pod, read by the paint)


def build_pod(f):
    # the outboard plate: face, chamfer ring, arch walls
    global PLATE_OUT
    outer = offset_poly(PLATE, [C if ch else 0.0 for ch in PLATE_CH])
    PLATE_OUT = outer
    poly_xy(f, outer, ZE0, -1, "fside")
    n = len(PLATE)
    for i in range(n):
        j = (i + 1) % n
        a0, b0 = outer[i], outer[j]
        a1, b1 = PLATE[i], PLATE[j]
        st = "fcham" if PLATE_CH[i] else "arch"
        dx, dy = a1[0] - b1[0], a1[1] - b1[1]
        nrm = th.norm((-dy, dx, -0.4 if PLATE_CH[i] else 0.0))
        facen(f, [(a0[0], a0[1], ZE0), (b0[0], b0[1], ZE0), (b1[0], b1[1], ZE1), (a1[0], a1[1], ZE1)],
              nrm, st, (0, 0, 1))
    # the plate's inner face below the crown (legs and the band over the arch)
    band_poly = PLATE[0:10] + [(0.47, -0.10)] + list(reversed(CROWN[0:6])) + [(-0.47, -0.10)]
    poly_xy(f, band_poly, ZE1, 1, "ceil")
    # the crown, lofted inboard: full section to z -0.12, bevelled to the inboard face
    inb = offset_poly(CROWN, [0.04 if t else 0.0 for t in CROWN_TOP])
    zs = [ZE1, -0.12, ZF1]
    rings = [CROWN, CROWN, inb]
    m = len(CROWN)
    lx0, lx1, lz0, lz1, ldep, lnum = LOUV
    for g in range(2):
        za, zb = zs[g], zs[g + 1]
        ra, rb = rings[g], rings[g + 1]
        for i in range(m):
            j = (i + 1) % m
            pa, pb, qa, qb = ra[i], ra[j], rb[i], rb[j]
            quad = [(pa[0], pa[1], za), (pb[0], pb[1], za), (qb[0], qb[1], zb), (qa[0], qa[1], zb)]
            dx, dy = pb[0] - pa[0], pb[1] - pa[1]
            if i < 6:
                st = "ceil"
            elif i == 6 or i == 12:
                st = "fside_x" if g == 0 else "fcham"
            else:
                st = "crown" if g == 0 else "fcham"
            if g == 0 and i == 9:
                crown_louvres(f, za, zb)
                continue
            nrm = th.norm((dy, -dx, 0.0))
            if g == 1 and CROWN_TOP[i]:
                nrm = th.norm((dy, -dx, 0.9))
            facen(f, quad, nrm, st, (0, 0, 1))
    poly_xy(f, inb, ZF1, 1, "inboard")
    # the deck from the fender to the mount plate, in two halves: the slot between them shows the coil-over
    for s in (-1, 1):
        x0, x1 = sorted((s * 0.17, s * 0.34))
        box(f, (x0, 0.10, ZF1), (x1, 0.19, ZMP), {"side": "rail", "+y": "rail_top", "-y": "rail_dk"},
            skip=("+z", "-z"))
    # the legs: the fender's skin wrapped down round the tyre's front and back, 12 cm deep
    for s in (-1, 1):
        leg = [(0.41, -0.40), (0.47, -0.46), (0.47, -0.10), (0.41, -0.10)]
        if s < 0:
            leg = [(-x, y) for x, y in reversed(leg)]
        # edges: foot cut, outer side, top (under the crown, hidden), inner side
        sty = ["arch", "fside_x", None, "ceil"] if s > 0 else [None, "fside_x", "arch", "ceil"]
        for i in range(4):
            if sty[i]:
                wall_xy(f, leg[i], leg[(i + 1) % 4], ZE1, ZLEG, sty[i])
        poly_xy(f, leg, ZLEG, 1, "ceil")
    # the mount plate
    ak.cbox(f, (-0.36, -0.48, ZMP), (0.36, 0.24, 0.5), C,
            {"side": "mount", "+z": "mount_back", "-z": "mount_face", "+y": "mount_top", "edge": "mcham"})
    # clevises for the two arms, the shaft's output boss, the damper bracket
    for py in (PU[1], PL[1]):
        for s in (-1, 1):
            x0, x1 = sorted((s * (ARM_X + 0.012), s * (ARM_X + 0.045)))
            box(f, (x0, py - 0.035, ZP - 0.035), (x1, py + 0.035, ZMP), {"side": "clevis"}, skip=("+z",))
    prism(f, (0.0, PS[1], ZMP), (0.0, PS[1], ZP + 0.002), 0.052, 8, "boss", cap1="boss_cap")
    # the damper's top bracket: a block on the plate and two ears round the eye
    box(f, (-0.045, DT[1] - 0.03, DT[2] + 0.016), (0.045, DT[1] + 0.035, ZMP), {"side": "clevis"}, skip=("+z",))
    for s in (-1, 1):
        x0, x1 = sorted((s * 0.026, s * 0.044))
        box(f, (x0, DT[1] - 0.026, DT[2] - 0.026), (x1, DT[1] + 0.026, DT[2] + 0.016), {"side": "clevis"},
            skip=("+z",))


def crown_louvres(f, za, zb):
    """The crown's top facet (y 0.45, x -0.18..0.18, z za..zb) with a recessed louvre field."""
    lx0, lx1, lz0, lz1, ldep, lnum = LOUV
    y = YTOP
    up = (0, 1, 0)
    xt = CROWN[9][0]

    def q(x0, x1, z0, z1):
        facen(f, [(x0, y, z0), (x1, y, z0), (x1, y, z1), (x0, y, z1)], up, "crown", (1, 0, 0))
    q(-xt, xt, za, lz0)
    q(-xt, xt, lz1, zb)
    q(-xt, lx0, lz0, lz1)
    q(lx1, xt, lz0, lz1)
    yb = y - ldep
    facen(f, [(lx0, yb, lz0), (lx1, yb, lz0), (lx1, y, lz0), (lx0, y, lz0)], (0, 0, 1), "louv_wall")
    facen(f, [(lx0, yb, lz1), (lx1, yb, lz1), (lx1, y, lz1), (lx0, y, lz1)], (0, 0, -1), "louv_wall")
    facen(f, [(lx0, yb, lz0), (lx0, y, lz0), (lx0, y, lz1), (lx0, yb, lz1)], (1, 0, 0), "louv_wall")
    facen(f, [(lx1, yb, lz0), (lx1, y, lz0), (lx1, y, lz1), (lx1, yb, lz1)], (-1, 0, 0), "louv_wall")
    facen(f, [(lx0, yb, lz0), (lx1, yb, lz0), (lx1, yb, lz1), (lx0, yb, lz1)], up, "louv_floor")
    # slats across the flow (the flow runs along X): long in Z, tilted
    pitch = (lx1 - lx0) / lnum
    for i in range(lnum):
        x0 = lx0 + pitch * (i + 0.15)
        x1 = x0 + pitch * 0.75
        facen(f, [(x0, y - 0.004, lz0 + 0.003), (x0, y - 0.004, lz1 - 0.003), (x1, yb + 0.004, lz1 - 0.003),
                  (x1, yb + 0.004, lz0 + 0.003)], th.norm((-0.8, 0.6, 0)), "slat", (0, 0, 1))


def build_arm(f, P0, prefix, cross=False):
    """An A-arm: two carbon legs from the pivot tube (along X at P0) to the ball joint on the kingpin."""
    J = th.add(P0, V)
    for s in (-1, 1):
        a = (s * ARM_X, P0[1], P0[2])
        bar(f, a, J, 0.032, 0.026, (0, 1, 0), "arm", top="arm_top", cap_a=None, cap_b=None)
    prism(f, (-ARM_X - 0.012, P0[1], P0[2]), (ARM_X + 0.012, P0[1], P0[2]), 0.02, 6, "tube",
          cap0="tube_cap", cap1="tube_cap")
    # the ball joint: a short vertical collar on the kingpin line
    prism(f, th.add(J, (0, -0.026, 0)), th.add(J, (0, 0.026, 0)), 0.032, 6, "joint", cap0="joint_cap", cap1="joint_cap")
    if cross:
        y, z = DX[1], DX[2]
        xo = ARM_X * (1 - DF)
        bar(f, (-xo, y, z), (xo, y, z), 0.026, 0.024, (0, 1, 0), "arm", top="arm_top")
        # the damper's lower clevis: two ears on the bar
        for s in (-1, 1):
            x0, x1 = sorted((s * 0.026, s * 0.042))
            box(f, (x0, y, z - 0.02), (x1, DL[1] + 0.022, z + 0.02), {"side": "clevis"}, skip=("-y",))


def build_shaft(f):
    """The drive shaft: the middle parallel link from the output boss to the hub, a CV boot each end."""
    a, b = PS, th.add(PS, V)
    t = th.norm(V)
    prism(f, th.add(a, th.mul(t, 0.02)), th.add(b, th.mul(t, -0.06)), 0.019, 6, "shaft")
    prism(f, a, th.add(a, th.mul(t, 0.11)), 0.044, 8, "boot", r1=0.026, cap0="boot_cap")
    prism(f, th.add(b, th.mul(t, -0.20)), th.add(b, th.mul(t, -0.08)), 0.026, 8, "boot", r1=0.046)


def build_knuckle(f):
    """The upright on the kingpin line between the ball joints, and the hub drum to the rim."""
    yt, yb = YC + JS - 0.03, YC - JS + 0.03
    bar(f, (0.0, yb, ZC + 0.01), (0.0, yt, ZC + 0.01), 0.07, 0.06, (0, 0, -1), "upright", cap_a="upright_end",
        cap_b="upright_end", ch=0.012, cham="upright_ch")
    z_face = ZC - W_T / 2 + RIM_IN
    prism(f, (0.0, YC, ZC + 0.07), (0.0, YC, z_face + 0.006), 0.085, 8, "drum", cap0="drum_cap", phase=0.0)


def build_tyre(f):
    """The grooved slick on a deep racing rim, open on the inboard side (the arms reach in)."""
    o = TC
    zo, zi = ZC - W_T / 2, ZC + W_T / 2
    RS = R_T - 0.032
    prof = [(RR, zo, "lip"), (RS, zo, "tsw"), (R_T, zo + 0.034, "tsh"), (R_T, zi - 0.034, "tread"),
            (RR + 0.03, zi, "tsw"), (RR, zo + RIM_IN, "barrel")]
    rings = [ringp((0, YC, z), (1, 0, 0), (0, 1, 0), r, NT) for r, z, _ in prof]
    for g in range(len(prof) - 1):
        st = prof[g + 1][2]
        ra, rb = rings[g], rings[g + 1]
        inner = prof[g][0] <= RR + 1e-6 and prof[g + 1][0] <= RR + 1e-6
        for i in range(NT):
            j = (i + 1) % NT
            quad = [ra[i], ra[j], rb[j], rb[i]]
            cq = cen(quad)
            radial = th.norm((cq[0] - o[0], cq[1] - o[1], 0.0))
            if inner:
                ak.face(f, quad, th.add(cq, th.mul(radial, 0.05)), st, u_hint=(0, 0, 1))
            else:
                nrm = _ring_normal(prof[g], prof[g + 1], radial)
                ak.face(f, quad, th.sub(cq, th.mul(nrm, 0.05)), st, u_hint=(0, 0, 1))
    # lip: outboard edge ring back to the rim face (A -> G is rings[0] -> rings[-1])
    ra, rb = rings[0], rings[-1]
    for i in range(NT):
        j = (i + 1) % NT
        quad = [ra[i], ra[j], rb[j], rb[i]]
        cq = cen(quad)
        radial = th.norm((cq[0] - o[0], cq[1] - o[1], 0.0))
        ak.face(f, quad, th.add(cq, th.mul(radial, 0.05)), "lip", u_hint=(0, 0, 1))
    z_face = zo + RIM_IN
    facen(f, [(p[0], p[1], z_face) for p in rings[-1]], (0, 0, -1), "rim", (1, 0, 0))
    # the centre-lock nut
    prism(f, (0.0, YC, z_face), (0.0, YC, zo + 0.006), 0.052, 6, "nut", cap1="nut_cap", phase=0.0)


def _ring_normal(p0, p1, radial):
    """Outward normal of the lathe band between profile points (r, z)."""
    dr, dz = p1[0] - p0[0], p1[1] - p0[1]
    # the profile runs outboard -> inboard; outward is (dz, -dr) in (r, z) for that direction... pick the
    # one pointing away from the axle / the tyre's middle
    nr, nz = dz, -dr
    if nr < -1e-9 or (abs(nr) < 1e-9 and nz * ((p0[1] + p1[1]) / 2 - ZC) < 0):
        nr, nz = -nr, -nz
    return th.norm((radial[0] * nr, radial[1] * nr, nz))


def build_damper(f):
    """The coil-over body with its spring, about its lower eye on the upper arm."""
    t = th.norm(th.sub(DT, DL))
    prism(f, th.add(DL, (-0.024, 0, 0)), th.add(DL, (0.024, 0, 0)), 0.02, 6, "eye")
    b0 = th.add(DL, th.mul(t, 0.02))
    b1 = th.add(DL, th.mul(t, 0.25))
    prism(f, b0, b1, 0.026, 8, "damp", cap1="damp_cap")
    prism(f, th.add(DL, th.mul(t, 0.045)), th.add(DL, th.mul(t, 0.235)), 0.047, 8, "spring",
          cap0="perch", cap1="perch")


def build_rod(f):
    """The damper rod, about its top eye on the bracket."""
    t = th.norm(th.sub(DL, DT))
    prism(f, th.add(DT, (-0.024, 0, 0)), th.add(DT, (0.024, 0, 0)), 0.02, 6, "eye")
    prism(f, th.add(DT, th.mul(t, 0.015)), th.add(DT, th.mul(t, 0.33)), 0.012, 6, "rod")
    prism(f, th.add(DT, th.mul(t, 0.015)), th.add(DT, th.mul(t, 0.07)), 0.03, 8, "damp", cap0="damp_cap")


ORIGINS = {"aero_b_wheel_pod": (0.0, 0.0, 0.0), "aero_b_wheel_arm_up": PU, "aero_b_wheel_arm_lo": PL,
           "aero_b_wheel_shaft": PS, "aero_b_wheel_knuckle": K0, "aero_b_wheel_tyre": TC,
           "aero_b_wheel_damper": DL, "aero_b_wheel_rod": DT}


def build_wheel():
    P = {k: [] for k in ORIGINS}
    build_pod(P["aero_b_wheel_pod"])
    build_arm(P["aero_b_wheel_arm_up"], PU, "up", cross=True)
    build_arm(P["aero_b_wheel_arm_lo"], PL, "lo")
    build_shaft(P["aero_b_wheel_shaft"])
    build_knuckle(P["aero_b_wheel_knuckle"])
    build_tyre(P["aero_b_wheel_tyre"])
    build_damper(P["aero_b_wheel_damper"])
    build_rod(P["aero_b_wheel_rod"])
    return P, dict(ORIGINS)


# ── wheel paint ────────────────────────────────────────────────────────────────────────────────

def _seg_dist(p, a, b):
    ex, ey = b[0] - a[0], b[1] - a[1]
    l2 = ex * ex + ey * ey or 1e-9
    t = max(0.0, min(1.0, ((p[0] - a[0]) * ex + (p[1] - a[1]) * ey) / l2))
    return math.hypot(p[0] - a[0] - ex * t, p[1] - a[1] - ey * t)


def _arch_dist(x, y):
    return min(_seg_dist((x, y), ARCH[i], ARCH[i + 1]) for i in range(len(ARCH) - 1))


def wband(P):
    y = P[1]
    if y > YBLUE:
        return BLUE
    if y < -0.30:
        return ORANGE
    return WHITE


def paint_wheel(style, P, n, d, part, o):
    x, y, z = P
    k = ak.lit(n)
    # ── the pod ──
    if style == "fside":
        c = wband(P)
        ad = _arch_dist(x, y)
        od = min(_seg_dist((x, y), PLATE_OUT[i], PLATE_OUT[(i + 1) % len(PLATE_OUT)])
                 for i in range(len(PLATE_OUT)) if PLATE_CH[i])
        if ad < 0.032:
            c = ORANGE if ad > 0.012 else ORANGE_HI
        elif ad < 0.044:
            c = mix(c, GAP, 0.25)
        if od * 48.0 < 1.0:
            c = mix(c, (255, 255, 255), 0.35)
        # panel lines: where the blue shell meets the white, and the skirt panel's top; fasteners on them
        # the blue shell's edge: a dark shut line under a lit lip
        if YBLUE - 0.021 < y <= YBLUE and ad > 0.05:
            c = mix(WHITE, GAP, 0.55)
        elif YBLUE < y < YBLUE + 0.021:
            c = BLUE_HI
        return sh(c, k)
    if style == "arch":
        return sh(ORANGE_HI if d < 1.0 else ORANGE, k)
    if style == "fcham":
        c = wband(P)
        return sh(mix(c, (255, 255, 255), 0.5 if c != ORANGE else 0.3), k)
    if style == "fside_x":
        c = wband(P)
        if d < 1.0:
            c = mix(c, GAP, 0.3)
        # a brake-cooling duct: a dark mouth with a lit lip, near the outboard edge
        bz0, bz1, by0, by1 = -0.43, -0.25, -0.065, 0.055
        if bz0 <= z <= bz1 and by0 <= y <= by1:
            e = min(z - bz0, bz1 - z, y - by0, by1 - y) * 48.0
            if e < 1.0:
                return sh(WHITE_LO, k)
            return sh(GAP if e > 2.0 else (40, 40, 48), k)
        return sh(c, k)
    if style == "crown":
        c = BLUE
        if d < 1.0:
            c = BLUE_DK
        # a white pinstripe round the louvre field
        lx0, lx1, lz0, lz1, _, _ = LOUV
        if (lx0 - 0.04 < x < lx1 + 0.04 and lz0 - 0.04 < z < lz1 + 0.04 and
                not (lx0 - 0.02 < x < lx1 + 0.02 and lz0 - 0.02 < z < lz1 + 0.02)):
            c = WHITE
        return sh(c, k)
    if style in ("ceil", "inboard", "rail_dk"):
        if style == "inboard" and y > YBLUE:
            c = BLUE_DK if d >= 1.0 else BLUE
            return sh(c, k)
        return ak.carbon(P, n, k * 0.85)
    if style in ("rail", "rail_top"):
        if style == "rail_top":
            c = BLUE if d >= 1.0 else BLUE_HI
            return sh(c, k)
        c = WHITE if d >= 1.0 else WHITE_LO
        if 0.12 < y < 0.135:
            c = ORANGE
        return sh(c, k)
    if style in ("louv_wall", "louv_floor"):
        return sh(GAP, k) if style == "louv_floor" else ak.carbon(P, n, k * 0.8)
    if style == "slat":
        return sh(BLUE_HI if d < 1.0 else BLUE_DK, k)
    if style in ("mount", "mount_face", "mount_back", "mount_top", "mcham"):
        if style == "mcham":
            return sh((84, 86, 98), k)
        if style == "mount_top":
            c = BLUE if d >= 1.0 else BLUE_HI
            return sh(c, k)
        if d < 1.0:
            return sh((74, 76, 88), k)
        if style == "mount_face":
            # a blue band over the deck, a white pinstripe inset round the carbon, bolts in the corners
            ax = abs(x)
            if y > 0.13:
                c = BLUE if y < 0.205 else BLUE_HI
                return sh(c, k)
            fr = min(0.36 - C - ax, y + 0.48 - C, 0.13 - y)
            if 0.022 < fr < 0.042:
                return sh(WHITE_LO, k)
            for fx, fy in ((0.28, -0.41), (0.28, 0.06), (0.0, -0.41)):
                if abs(ax - fx) < 0.011 and abs(y - fy) < 0.011:
                    return sh(STEEL_HI, k)
        return ak.carbon(P, n, k)
    if style in ("clevis", "boss", "boss_cap"):
        c = STEEL if style != "boss_cap" else (70, 72, 82)
        if d < 1.0:
            c = STEEL_HI
        return sh(c, k * 0.85)
    # ── the mechanism ──
    if style in ("arm", "arm_top"):
        if d < 1.0:
            return sh((88, 90, 104), k)
        return ak.carbon(P, n, k * (1.15 if style == "arm_top" else 1.0))
    if style in ("tube", "tube_cap", "joint", "joint_cap", "eye", "eye_cap", "shaft", "rod"):
        c = STEEL if style in ("tube", "joint", "eye", "rod", "shaft") else (64, 66, 76)
        if style == "shaft":
            c = (96, 100, 114)
        if d < 1.0:
            c = mix(c, (255, 255, 255), 0.3)
        return sh(c, k)
    if style in ("boot", "boot_cap"):
        c = (40, 40, 48)
        if d < 1.0:
            c = (70, 70, 82)
        return sh(c, k)
    if style in ("upright", "upright_end", "upright_ch"):
        c = (112, 116, 130) if style != "upright_ch" else STEEL_HI
        if style == "upright" and d < 1.0:
            c = STEEL_HI
        return sh(c, k)
    if style in ("drum", "drum_cap"):
        c = (84, 88, 102) if style == "drum" else (60, 62, 72)
        if d < 1.0:
            c = STEEL
        return sh(c, k)
    if style in ("damp", "damp_cap"):
        c = BLUE if style == "damp" else BLUE_DK
        if d < 1.0:
            c = BLUE_HI
        return sh(c, k)
    if style == "perch":
        return sh(STEEL, k)
    if style == "spring":
        # coils: orange bands with dark gaps, along the damper's axis
        ax = th.norm(th.sub(DT, DL))
        s = th.dot(th.sub(P, o), ax)
        ph = (s / 0.034) % 1.0
        if ph < 0.32:
            return sh((40, 24, 14), k)
        if ph < 0.45:
            return sh(ORANGE_HI, k)
        return sh(ORANGE, k)
    # ── the tyre ──
    rr = math.hypot(x - o[0], y - o[1])
    zl = z - o[2]
    if style == "tread":
        c = RUBBER
        # four circumferential grooves (the grooved slick)
        for gz in (-0.085, -0.03, 0.03, 0.085):
            if abs(zl - gz) < 0.0105:
                c = (14, 14, 18)
        if d < 1.0:
            c = mix(c, (70, 70, 80), 0.18)
        return sh(c, k)
    if style == "tsh":
        return sh((58, 58, 66) if d < 1.0 else (44, 44, 52), k)
    if style == "tsw":
        c = (30, 30, 36)
        if 0.306 < rr < 0.338:
            c = ORANGE          # the compound band, mid-sidewall: clear of the arch lip and the rim
        elif rr > R_T - 0.04:
            c = (40, 40, 48)
        return sh(c, k)
    if style == "lip":
        return sh(STEEL_HI if d < 1.0 else (200, 204, 214), k)
    if style == "barrel":
        return sh((48, 50, 58), k)
    if style == "rim":
        return paint_rim(x - o[0], y - o[1], rr, k)
    if style in ("nut", "nut_cap"):
        if style == "nut_cap":
            if rr < 0.016:
                return sh(GAP, k)
            return sh(ORANGE_HI if d < 1.0 else ORANGE, k)
        return sh(ORANGE if d >= 1.0 else ORANGE_HI, k)
    return (255, 0, 255)


def paint_rim(dx, dy, r, k):
    """A light racing rim: ten thin spokes in five pairs, dark windows between, a lit lip."""
    if r > RR - 0.018:
        return sh((226, 230, 238), k)
    if r > RR - 0.032:
        return sh((150, 154, 166), k)
    if r < 0.075:
        return sh((170, 174, 186), k)
    a = math.atan2(dy, dx) % (2 * math.pi)
    sector = 2 * math.pi / 5
    u = (a % sector) / sector                        # 0..1 across one pair and its window
    # a pair of spokes splaying from the hub: narrow at the hub, apart at the rim
    spread = 0.06 + 0.10 * (r - 0.075) / (RR - 0.107)
    w = 0.045
    if abs(u - (0.5 - spread)) < w or abs(u - (0.5 + spread)) < w:
        return sh((214, 218, 228), k)
    if abs(u - (0.5 - spread)) < w + 0.035 or abs(u - (0.5 + spread)) < w + 0.035:
        return sh((150, 154, 166), k)
    return sh((20, 20, 26), k)


ak.model("aero_b_wheel", 9102, build_wheel, paint_wheel, tex=512)
build_pod([])   # sets PLATE_OUT for the painter
em.CHECKS["aero_b_wheel"] = {
    "cells": ((-0.5, -RIDE, -0.5), (0.5, 0.5, 0.5)), "budget": 900,
    "origins": dict(ORIGINS),
    "spin": {"aero_b_wheel_tyre": (0, 0, 1), "aero_b_wheel_knuckle": (0, 1, 0)},
    "solid": [((-0.47, 0.09, ZE1), (0.47, YTOP, ZF1)), ((-0.36, -0.48, ZMP), (0.36, 0.24, 0.5))]}


# ── poses ──────────────────────────────────────────────────────────────────────────────────────

def rx(a):
    c, s = math.cos(a), math.sin(a)
    return [[1, 0, 0], [0, c, -s], [0, s, c]]


def ry(a):
    c, s = math.cos(a), math.sin(a)
    return [[c, 0, s], [0, 1, 0], [-s, 0, c]]


def mm(A, Bm):
    return [[sum(A[i][k] * Bm[k][j] for k in range(3)) for j in range(3)] for i in range(3)]


def app(A, v):
    return tuple(sum(A[i][k] * v[k] for k in range(3)) for i in range(3))


def tf(Bm, o):
    """Godot Transform3D order: basis columns x, y, z, then origin."""
    return [Bm[0][0], Bm[1][0], Bm[2][0], Bm[0][1], Bm[1][1], Bm[2][1], Bm[0][2], Bm[1][2], Bm[2][2],
            o[0], o[1], o[2]]


I3 = [[1, 0, 0], [0, 1, 0], [0, 0, 1]]


def swing_x(v, sag):
    """The turn about X that lifts the far end of the link vector v by `sag`."""
    lo, hi = -1.2, 1.2

    def fn(a):
        return app(rx(a), v)[1] - v[1] - sag
    if fn(lo) > fn(hi):
        lo, hi = hi, lo
    for _ in range(60):
        mid = (lo + hi) / 2
        if fn(mid) < 0:
            lo = mid
        else:
            hi = mid
    return rx((lo + hi) / 2)


def pose(sag, steer):
    """{part: Transform3D} for a suspension lift `sag` (m) and a steer angle (rad)."""
    S = swing_x(V, sag)
    T = th.sub(app(S, V), V)
    R = ry(steer)
    dl = th.add(PU, app(S, th.sub(DL, PU)))
    u0 = th.sub(DT, DL)
    u1 = th.sub(DT, dl)
    beta = math.atan2(u1[2], u1[1]) - math.atan2(u0[2], u0[1])
    Rd = rx(beta)
    out = {
        "aero_b_wheel_pod": tf(I3, (0, 0, 0)),
        "aero_b_wheel_arm_up": tf(S, PU), "aero_b_wheel_arm_lo": tf(S, PL), "aero_b_wheel_shaft": tf(S, PS),
        "aero_b_wheel_knuckle": tf(R, th.add(K0, T)), "aero_b_wheel_tyre": tf(R, th.add(TC, T)),
        "aero_b_wheel_damper": tf(Rd, dl), "aero_b_wheel_rod": tf(Rd, DT),
        "_ground": TC[1] + T[1] - R_T, "_centre": [0.0, -0.25, 0.0],
    }
    return out


STATES = {"rest": (0.0, 0.0), "steer": (0.0, math.radians(25)), "up": (0.14, 0.0), "down": (-0.14, 0.0)}


# ── the rig ────────────────────────────────────────────────────────────────────────────────────
ak.rig("aero_b_rig", [
    ("aero_b_block", ak.place()),
    ("aero_b_block", ak.place(at=(0, 0, -1))),
    ("aero_b_wheel", ak.place(yaw=90, at=(-1, 0, 0))),
    ("aero_b_wheel", ak.place(yaw=90, at=(-1, 0, -1))),
    ("aero_b_wheel", ak.place(yaw=-90, at=(1, 0, 0))),
    ("aero_b_wheel", ak.place(yaw=-90, at=(1, 0, -1))),
], ground=-RIDE, extra={
    "_centre": [0.9, -0.3, -0.5],
    "_scenes": [["res://blocks/scenes/block.tscn", [1, 0, 0, 0, 1, 0, 0, 0, 1, 3.2, 0, 0]],
                ["res://blocks/scenes/wheel.tscn", [0, 0, -1, 0, 1, 0, 1, 0, 0, 2.2, 0, 0]]]})


# ── the clash check: the posed parts against the cell and against each other ─────────────────────

def _local_parts():
    parts, origins = build_wheel()
    out = {}
    for p, faces in parts.items():
        o = origins[p]
        out[p] = [th.sub(q, o) for fc in faces for q in fc.pts]
    return out


def _xf(t, p):
    return (t[0] * p[0] + t[3] * p[1] + t[6] * p[2] + t[9],
            t[1] * p[0] + t[4] * p[1] + t[7] * p[2] + t[10],
            t[2] * p[0] + t[5] * p[1] + t[8] * p[2] + t[11])


def _inv_xf(t, p):
    q = (p[0] - t[9], p[1] - t[10], p[2] - t[11])
    return (t[0] * q[0] + t[1] * q[1] + t[2] * q[2], t[3] * q[0] + t[4] * q[1] + t[5] * q[2],
            t[6] * q[0] + t[7] * q[1] + t[8] * q[2])


def _in_poly(p, poly):
    inside = False
    n = len(poly)
    for i in range(n):
        a, b = poly[i], poly[(i + 1) % n]
        if (a[1] > p[1]) != (b[1] > p[1]):
            xx = a[0] + (p[1] - a[1]) * (b[0] - a[0]) / (b[1] - a[1])
            if p[0] < xx:
                inside = not inside
    return inside


def clash():
    loc = _local_parts()
    ok = True
    for st, (sag, steer) in STATES.items():
        ps = pose(sag, steer)
        world = {p: [_xf(ps[p], q) for q in pts] for p, pts in loc.items()}
        bad = []
        for p, pts in world.items():
            for q in pts:
                if abs(q[0]) > 0.5 + 0.005 or abs(q[2]) > 0.5 + 0.005 or q[1] > 0.5 + 0.005:
                    bad.append("%s outside the cell at %s" % (p, tuple(round(v, 3) for v in q)))
                    break
        # tyre against the pod: the plate slab and the crown
        for q in world["aero_b_wheel_tyre"]:
            if q[2] < ZE1 + 0.003 and _in_poly((q[0], q[1]), PLATE):
                bad.append("tyre enters the endplate at %s" % (tuple(round(v, 3) for v in q),))
                break
            if ZE1 < q[2] < ZF1 and _in_poly((q[0], q[1]), CROWN):
                bad.append("tyre enters the crown at %s" % (tuple(round(v, 3) for v in q),))
                break
        # the mechanism against the tyre's solid (between rim and tread, within its width)
        tt = ps["aero_b_wheel_tyre"]
        for p in ("aero_b_wheel_arm_up", "aero_b_wheel_arm_lo", "aero_b_wheel_shaft", "aero_b_wheel_damper",
                  "aero_b_wheel_rod"):
            for q in world[p]:
                l = _inv_xf(tt, q)
                r = math.hypot(l[0], l[1])
                if RR + 0.003 < r < R_T and abs(l[2]) < W_T / 2 - 0.003:
                    bad.append("%s enters the tyre at %s (r %.3f)" % (p, tuple(round(v, 3) for v in q), r))
                    break
        print("%-6s %s" % (st, "clear" if not bad else "; ".join(bad)))
        ok = ok and not bad
    return ok


if __name__ == "__main__":
    ak.make("aero_b_block")
    ak.make("aero_b_wheel", {s: pose(*v) for s, v in STATES.items()})
    ak.make("aero_b_rig")
    if "clash" in sys.argv[1:]:
        sys.exit(0 if clash() else 1)
