#!/usr/bin/env python3
"""AERO'S BASIC BLOCK AND STANDARD WHEEL, after the player's reference pictures (TerraTech's racing
corporation: a red cap, white sides, a blue skirt). DRAFTS for the player's approval: generator only,
not wired into the game.

    python3 art/aero_models.py [aero_block|aero_wheel|aero_block_ref|aero_wheel_ref]
        -> objects/<name>_texture.png + art/out/<name>.glb (one node per part, at its pivot)

Two palettes over one shape: AERO (the emblem: blue cap, white, orange skirt) and REF (the pictures'
red cap, white, blue skirt) - the player picks.

THE FIRST CUT (a chamfered cube painted in bands, a racing pylon with wishbones) was turned down: "the
block is too cubic, the transmission is horrible". What the pictures say instead, and what this builds:

BLOCK - a BULLNOSE: a thick cap swept over the top and rolled down over the front edge (a quarter
ellipse), its side edges chamfered, the cap's back end split into two EARS round a V notch; under it
a white body set 3 cm in from the side faces, and a full-width skirt along the bottom whose front
slopes back under the nose. Back, bottom and sides stay flat on the cell's faces; the front and top
are the shape.

WHEEL - a FENDER, not a suspension: a cap swept over the top of the tyre (a ridge along it) from the
hull face out past the tyre's outer face, and under it, inboard of the tyre, a hull-shaped body whose
lower corners run out to points at the cell's ends (the pictures' blue winglets). The tyre is the
standard wheel's size and place (r 0.5 round (0, -0.385, -0.25), bolted on by the BACK face), a
knobbly tyre: sixteen lugs staggered across the tread, a white recessed hub.
  aero_wheel_body    fender and body (still)
  aero_wheel_tyre    tyre and hub about TC (spins about Z)
"""
import json
import math
import os
import random
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import turret_heads as th  # noqa: E402
import emitter_models as em  # noqa: E402

Image = th.Image
DENS = 48.0
PAD = th.PAD
C = 0.035                      # the Aero chamfer

PALETTES = {
    "aero": {"top": (16, 176, 226), "mid": (240, 242, 246), "low": (246, 96, 18)},
    "ref": {"top": (226, 52, 58), "mid": (240, 242, 246), "low": (64, 104, 182)},
}
INK = (18, 18, 24)
RUBBER = (34, 33, 38)
LIGHT = None                   # set below: the painted light, front-top-left


def _lit(n):
    """The painted light: a fixed sun from the front, up and left, so a curved cap reads as curved."""
    return 0.80 + 0.30 * max(th.dot(n, LIGHT), 0.0) - 0.10 * max(-n[1], 0.0)


def _tone(c, k):
    return th.shade(c, k)


def paint(pal, style, P, n, d, part_origin):
    top, mid, low = pal["top"], pal["mid"], pal["low"]
    k = _lit(n)
    if style == "cap":
        return _tone(top, k)
    if style == "cap_top":
        return _tone(top, k * 0.92)
    if style == "top_mid":
        return _diamond(P, pal) or _tone(top, k)
    if style == "cap_edge":
        return _tone(_mix(top, (255, 255, 255), 0.35), k)
    if style == "cap_end":
        return _tone(top, k * 0.72)
    if style == "ridge":
        return _tone(_mix(top, (255, 255, 255), 0.12), k * 1.05)
    if style == "under":
        return _tone(top, 0.5)
    if style == "side":
        if _bolt(P, n):
            return _tone(low, max(k, 0.9))
        return _tone(mid, max(k, 0.94))
    if style == "skirt":
        return _tone(low, k)
    if style == "skirt_top":
        return _tone(_mix(low, (255, 255, 255), 0.18), k)
    if style == "fwall":
        if P[1] < TC[1] - 0.02:
            return _tone(low, max(k, 0.9))
        return _tone(mid, max(k, 0.94))
    if style == "fin":
        return (44, 44, 52)
    if style == "arch":
        # the three bands down the arch: the cap's colour over the crest, white, the skirt's at the points
        hi, lo = TC[1] + 0.24, TC[1] - 0.02
        if abs(P[1] - hi) < 0.8 / DENS or abs(P[1] - lo) < 0.8 / DENS:
            return _tone(mid, 0.62)
        if P[1] > hi:
            return _tone(top, k)
        if P[1] < lo:
            return _tone(low, k)
        return _tone(mid, max(k, 0.94))
    if style == "arch_end":
        return _tone(mid, 0.85)
    if style in ("hull", "mount"):
        # white over a blue chine that rises toward the points
        line = -0.62 + 0.18 * (abs(P[0]) / 0.5)
        if abs(P[1] - line) < 0.8 / DENS:
            return _tone(low, 0.6)
        if P[1] < line:
            return _tone(low, k)
        if style == "hull" and _bolt((P[2], P[1] + 0.32, -P[0]), n, scale=0.75):
            return _tone(low, 0.9)
        return _tone(mid, max(k, 0.94) * (0.92 if style == "mount" else 1.0))
    # the tyre
    q = th.sub(P, part_origin)
    r = math.hypot(q[0], q[1])
    if style == "tread":
        return th.jitter(RUBBER, 2)
    if style == "lug":
        return th.jitter(th.shade(RUBBER, 1.45 if d < 1.0 else 1.25), 2)
    if style == "lug_side":
        return th.jitter(th.shade(RUBBER, 0.95), 2)
    if style == "wall":
        return th.jitter(th.shade(RUBBER, 1.1 if r > 0.30 else 1.0), 2)
    if style == "rimwall":
        return (20, 20, 24)
    if style == "rim":
        if r < 0.045:
            return low
        if r < 0.075:
            return (26, 26, 30)
        if r > 0.165:
            return (200, 204, 212)
        return mid if q[0] < q[1] else th.shade(mid, 0.9)
    if style == "stub":
        return (60, 62, 70)
    return (255, 0, 255)


def _mix(a, b, t):
    return tuple(a[i] * (1 - t) + b[i] * t for i in range(3))


def _diamond(P, pal):
    """The emblem on the top: a white diamond with a ring of the skirt's colour round its middle."""
    m = abs(P[0]) + abs(P[2])
    if m < 0.07:
        return pal["low"]
    if m < 0.10:
        return pal["mid"]
    if m < 0.135:
        return pal["low"]
    if m < 0.18:
        return pal["mid"]
    return None


def _bolt(P, n, scale=1.0):
    """The side mark: a bolt of lightning (a Z), in the skirt's colour, in the middle of the white."""
    if abs(n[1]) > 0.5:
        return False
    h = th.dot(P, th.norm(th.cross((0, 1, 0), n))) / scale
    y = (P[1] + 0.09) / scale
    w = 0.045
    pts = [(-0.10, 0.11), (0.05, 0.11), (-0.05, -0.11), (0.10, -0.11)]
    return min(_seg(h, y, *pts[0], *pts[1]), _seg(h, y, *pts[1], *pts[2]), _seg(h, y, *pts[2], *pts[3])) < w / 2


def _seg(px, py, ax, ay, bx, by):
    ex, ey = bx - ax, by - ay
    t = max(0.0, min(1.0, ((px - ax) * ex + (py - ay) * ey) / (ex * ex + ey * ey)))
    return math.hypot(px - ax - ex * t, py - ay - ey * t)


# ── geometry ────────────────────────────────────────────────────────────────────────────────────

def _face(faces, pts, inside, style, u_hint=None):
    faces.append(th.Face(th.outward(pts, inside), style, u_hint=u_hint))


def sweep(faces, stations, section, styles, caps=None):
    """A section swept along a path. stations: (q, X, N) - a point of the path, the section's across
    axis and its outward normal there; section: closed (s, n) polygon; styles: one per section edge
    (None leaves that strip out). caps: (style_start, style_end, [index lists of convex pieces])."""
    stations = [st if len(st) == 4 else (st[0], st[1], st[2], 1.0) for st in stations]
    rings = [[th.add(q, th.add(th.mul(X, s), th.mul(N, nn * k))) for s, nn in section] for q, X, N, k in stations]
    sc = sum(p[0] for p in section) / len(section)
    nc = sum(p[1] for p in section) / len(section)
    mids = [th.add(q, th.add(th.mul(X, sc), th.mul(N, nc * k))) for q, X, N, k in stations]
    m = len(section)
    for i in range(len(stations) - 1):
        inside = th.mul(th.add(mids[i], mids[i + 1]), 0.5)
        along = th.sub(stations[i + 1][0], stations[i][0])
        for j in range(m):
            if styles[j] is None:
                continue
            k = (j + 1) % m
            _face(faces, [rings[i][j], rings[i][k], rings[i + 1][k], rings[i + 1][j]], inside, styles[j], along)
    if caps:
        st0, st1, pieces = caps
        for ring, st, other in ((rings[0], st0, mids[1]), (rings[-1], st1, mids[-2])):
            if st is None:
                continue
            for piece in pieces:
                pts = [ring[i] for i in piece]
                c = th.mul(tuple(map(sum, zip(*pts))), 1.0 / len(pts))
                # outward = away from the rest of the sweep
                _face(faces, pts, th.add(c, th.mul(th.norm(th.sub(other, c)), 0.05)), st)


def prism(faces, poly, y0, y1, steps, modes, top_style, side_style, cham_style, bottom_style=None):
    """A convex polygon in XZ ((x, z) points, any winding) standing from y0 to y1. Its rounded top
    edge is `steps`, (inset, y) pairs from the wall's top to the top face. modes per edge (edge i runs
    poly[i] -> poly[i+1]): 'c' a wall with that rounded top edge, 'f' a plain wall, 'x' no wall (it
    meets another part)."""
    n = len(poly)
    cx = sum(p[0] for p in poly) / n
    cz = sum(p[1] for p in poly) / n

    def line(i, o):
        a, b = poly[i], poly[(i + 1) % n]
        ex, ez = b[0] - a[0], b[1] - a[1]
        L = math.hypot(ex, ez)
        nx, nz = -ez / L, ex / L
        if nx * (cx - a[0]) + nz * (cz - a[1]) < 0:
            nx, nz = -nx, -nz
        return (a[0] + nx * o, a[1] + nz * o), (ex, ez)

    def meet(l1, l2):
        (p, d), (q, e) = l1, l2
        den = d[0] * e[1] - d[1] * e[0]
        t = ((q[0] - p[0]) * e[1] - (q[1] - p[1]) * e[0]) / den
        return (p[0] + d[0] * t, p[1] + d[1] * t)

    rings = []                                     # one inset polygon per step, at its height
    for o, y in steps:
        ls = [line(i, o if modes[i] == "c" else 0.0) for i in range(n)]
        rings.append(([meet(ls[i - 1], ls[i]) for i in range(n)], y))
    inside = (cx, (y0 + y1) / 2, cz)
    P = lambda a, y: (a[0], y, a[1])
    _face(faces, [P(p, rings[-1][1]) for p in rings[-1][0]], inside, top_style, (1, 0, 0))
    if bottom_style:
        _face(faces, [P(p, y0) for p in poly], inside, bottom_style, (1, 0, 0))
    for i in range(n):
        j = (i + 1) % n
        if modes[i] == "x":
            continue
        if modes[i] == "c":
            _face(faces, [P(poly[i], y0), P(poly[j], y0), P(rings[0][0][j], rings[0][1]), P(rings[0][0][i], rings[0][1])],
                  inside, side_style, (0, 1, 0))
            for k in range(len(rings) - 1):
                (ra, ya), (rb, yb) = rings[k], rings[k + 1]
                _face(faces, [P(ra[i], ya), P(ra[j], ya), P(rb[j], yb), P(rb[i], yb)], inside, cham_style)
        else:
            pts = [P(poly[i], y0), P(poly[j], y0)]
            right = [P(r[j], y) for r, y in rings] if modes[j] == "c" else [P(rings[-1][0][j], rings[-1][1])]
            left = [P(r[i], y) for r, y in rings] if modes[i - 1] == "c" else [P(rings[-1][0][i], rings[-1][1])]
            _face(faces, pts + right + list(reversed(left)), inside, side_style, (0, 1, 0))


def extrude_x(faces, prof, x0, x1, side_style, edge_styles):
    """A convex (z, y) profile extruded across x0..x1; edge_styles per profile edge (None: no face)."""
    n = len(prof)
    cz = sum(p[0] for p in prof) / n
    cy = sum(p[1] for p in prof) / n
    inside = ((x0 + x1) / 2, cy, cz)
    for x in (x0, x1):
        if side_style:
            _face(faces, [(x, p[1], p[0]) for p in prof], inside, side_style, (0, 0, 1))
    for i in range(n):
        st = edge_styles[i] if isinstance(edge_styles, list) else edge_styles
        if st is None:
            continue
        a, b = prof[i], prof[(i + 1) % n]
        _face(faces, [(x0, a[1], a[0]), (x1, a[1], a[0]), (x1, b[1], b[0]), (x0, b[1], b[0])], inside, st, (1, 0, 0))


def extrude_z(faces, prof, z0, z1, cap_style, edge_style, cap_styles=None):
    """A convex (x, y) profile extruded from z0 to z1."""
    n = len(prof)
    cx = sum(p[0] for p in prof) / n
    cy = sum(p[1] for p in prof) / n
    inside = (cx, cy, (z0 + z1) / 2)
    for z, st in zip((z0, z1), cap_styles or (cap_style, cap_style)):
        if st:
            _face(faces, [(p[0], p[1], z) for p in prof], inside, st, (1, 0, 0))
    for i in range(n):
        st = edge_style[i] if isinstance(edge_style, list) else edge_style
        if st is None:
            continue
        a, b = prof[i], prof[(i + 1) % n]
        _face(faces, [(a[0], a[1], z0), (b[0], b[1], z0), (b[0], b[1], z1), (a[0], a[1], z1)], inside, st, (0, 0, 1))


# ── the block ──────────────────────────────────────────────────────────────────────────────────

# ── the block: three layers, as the player's picture of the basic block ──────────────────────────

BASE_Y = -0.30                 # the blue base's top
CAP_Y0 = 0.12                  # the red cap's underside
CAP_Y1 = 0.42                  # the cap slab's top, under the raised top
BODY_IN = 0.05                 # the white middle set in under the cap's overhang
TOP_IN = 0.04                  # the raised top set in from the slab's edge
NOTCH = (0.17, 0.08, 0.15)     # the notch in every top edge's middle: half width outside, inside, depth


def _rounded(y1, r):
    return [(0.0, y1 - r), (r * 0.3, y1 - r * 0.32), (r, y1)]


def build_block():
    f = []
    # BASE: full width, its top edge rounded down into the white
    sq = [(-0.5, -0.5), (0.5, -0.5), (0.5, 0.5), (-0.5, 0.5)]
    prism(f, sq, -0.5, BASE_Y, _rounded(BASE_Y, 0.06), ["c"] * 4, "skirt_top", "skirt", "skirt_top", "skirt")
    # BODY: the white middle, set in
    w = 0.5 - BODY_IN
    extrude_x(f, [(w, BASE_Y), (w, CAP_Y0), (-w, CAP_Y0), (-w, BASE_Y)], -w, w, "side", ["side", None, "side", None])
    # CAP: the slab, overhanging the white, its top edge rounded
    prism(f, sq, CAP_Y0, CAP_Y1, _rounded(CAP_Y1, 0.03), ["c"] * 4, "cap_top", "cap", "cap_edge", "under")
    # the raised TOP over it: a notch in the middle of every edge, cut as convex pieces
    a = 0.5 - TOP_IN
    no, ni, nd = NOTCH
    bb = a - nd
    r = _rounded(0.5, 0.04)
    pieces = []
    for sx in (-1, 1):                              # the strips along +z / -z, corners included
        for sz in (-1, 1):
            pieces.append(([(sx * a, sz * bb), (sx * ni, sz * bb), (sx * no, sz * a), (sx * a, sz * a)], ["x", "f", "c", "c"]))
            pieces.append(([(sx * bb, sz * bb), (sx * a, sz * bb), (sx * a, sz * no), (sx * bb, sz * ni)], ["c", "c", "f", "x"]))
    for poly, modes in pieces:
        prism(f, poly, CAP_Y1, 0.5, r, modes, "cap", "cap", "cap_edge")
    prism(f, [(-bb, -bb), (bb, -bb), (bb, bb), (-bb, bb)], CAP_Y1, 0.5, r, ["x"] * 4, "top_mid", "cap", "cap_edge")
    # the notches' inner walls
    for k in range(4):
        ang = k * math.pi / 2
        c, s_ = math.cos(ang), math.sin(ang)
        rot = lambda x, z: (x * c - z * s_, z * c + x * s_)
        p0, p1 = rot(-ni, bb), rot(ni, bb)
        _face(f, [(p0[0], CAP_Y1, p0[1]), (p1[0], CAP_Y1, p1[1]), (p1[0], 0.5, p1[1]), (p0[0], 0.5, p0[1])],
              (0.0, 0.46, 0.0), "cap_end", (1, 0, 0))
    return {"aero_block": f}, {"aero_block": (0.0, 0.0, 0.0)}


# ── the wheel: a fairing round a smaller knobbly tyre ───────────────────────────────────────────

TC = (0.0, -0.46, -0.20)       # the tyre's centre (its bottom 0.82 under the block's middle)
R, W = 0.36, 0.30              # tyre radius (over the lugs) and width
R0 = 0.325                     # the tread under the lugs
RIM_R = 0.18
LUGS = 14
FR = 0.40                      # the arch's underside, round TC
FT = 0.13                      # its thickness: a broad white band seen from outside
F_ANG = (27.0, 153.0)          # its arc over the top (the outside stays in the cell's x)
F_SEG = 10
TIP_ANG = -16.0                # the legs run on down past the axle to points (the pictures' wings)
TIP_R = 0.42
TIP_K = 0.3                    # the arch's thickness left at a point
Z_OUT = -0.39                  # the arch's outboard edge, past the tyre's outer face
Z_BODY = -0.025                # the hull's outboard face, inboard of the tyre
TIP_Y = -0.52                  # the hull's points, past the tyre fore and aft
HULL_BOT = -0.70


def _ring(r, n, z, phase=0.5):
    return [(TC[0] + r * math.cos((i + phase) * 2 * math.pi / n), TC[1] + r * math.sin((i + phase) * 2 * math.pi / n), z)
            for i in range(n)]


def _band(faces, ra, za, rb, zb, n, style, phase=0.5):
    A, B = _ring(ra, n, za, phase), _ring(rb, n, zb, phase)
    cen = (TC[0], TC[1], (za + zb) / 2)
    for i in range(n):
        j = (i + 1) % n
        q = [A[i], A[j], B[j], B[i]]
        mid = th.mul(tuple(map(sum, zip(*q))), 0.25)
        inside = cen if abs(ra - rb) < 1e-6 else (mid[0], mid[1], mid[2] + (0.05 if za < TC[2] else -0.05))
        faces.append(th.Face(th.outward(q, inside), style, u_hint=(0, 0, 1)))


def build_wheel():
    body, tyre = [], []
    zi, zo = TC[2] + W / 2, TC[2] - W / 2
    # the ARCH over the tyre, from the hull face past its outer face, a ridge along its crest
    def st(ang, r, k):
        a = math.radians(ang)
        N = (math.cos(a), math.sin(a), 0.0)
        return ((TC[0] + r * N[0], TC[1] + r * N[1], 0.0), (0.0, 0.0, 1.0), N, k)
    stations = [st(180.0 - TIP_ANG, TIP_R, TIP_K), st(180.0 - (TIP_ANG + F_ANG[0]) / 2, (FR + TIP_R) / 2, 0.5)]
    for i in range(F_SEG + 1):
        stations.append(st(F_ANG[1] + (F_ANG[0] - F_ANG[1]) * i / F_SEG, FR, 1.0))
    stations += [st((TIP_ANG + F_ANG[0]) / 2, (FR + TIP_R) / 2, 0.5), st(TIP_ANG, TIP_R, TIP_K)]
    rz0, rz1 = -0.02, 0.14
    sec = [(0.5, 0.0), (0.5, FT), (rz1 + 0.03, FT), (rz1, FT + 0.03), (rz0, FT + 0.03), (rz0 - 0.03, FT),
           (Z_OUT + C, FT), (Z_OUT, FT - C), (Z_OUT, 0.0)]
    sweep(body, stations, sec, [None, "arch", "cap_edge", "ridge", "cap_edge", "arch", "cap_edge", "fwall", "fin"],
          caps=("arch_end", "arch_end", [[0, 1, 2, 5, 6, 7, 8], [2, 3, 4, 5]]))
    # the HULL inboard of the tyre: under the arch, its lower corners out past the tyre to points
    prof = [(-0.5, TIP_Y), (-0.24, HULL_BOT), (0.24, HULL_BOT), (0.5, TIP_Y)]
    for i in range(F_SEG + 1):
        a = math.radians(F_ANG[0] + (F_ANG[1] - F_ANG[0]) * i / F_SEG)
        prof.append((TC[0] + FR * math.cos(a), TC[1] + FR * math.sin(a)))
    edges = ["hull", "hull", "hull", "hull"] + [None] * F_SEG + ["hull"]
    extrude_z(body, prof, Z_BODY, 0.5, None, edges, cap_styles=("hull", "mount"))
    # the TYRE: tread under the lugs, lugs staggered across it, sidewalls, a recessed hub
    _band(tyre, R0, zo, R0, zi, LUGS, "tread")
    _band(tyre, R0, zo, RIM_R, zo, LUGS, "wall")
    _band(tyre, R0, zi, 0.07, zi, LUGS, "wall")
    _band(tyre, RIM_R, zo, RIM_R, zo + 0.035, 12, "rimwall")
    hub = _ring(RIM_R, 12, zo + 0.035)
    tyre.append(th.Face(th.outward(hub, (TC[0], TC[1], zo + 0.2)), "rim", u_hint=(1, 0, 0)))
    _band(tyre, 0.07, zi, 0.07, zi + 0.02, 8, "stub")
    hw = math.pi / LUGS * 0.62
    for k in range(LUGS):
        a = (k + 0.5) * 2 * math.pi / LUGS
        z0, z1 = (zo, TC[2] + 0.035) if k % 2 == 0 else (TC[2] - 0.035, zi)
        def pt(r, ang, z):
            return (TC[0] + r * math.cos(ang), TC[1] + r * math.sin(ang), z)
        inside = pt((R0 + R) / 2, a, (z0 + z1) / 2)
        r0 = R0 - 0.004
        top = [pt(R, a - hw * 0.85, z0), pt(R, a + hw * 0.85, z0), pt(R, a + hw * 0.85, z1), pt(R, a - hw * 0.85, z1)]
        _face(tyre, top, inside, "lug", (0, 0, 1))
        for sgn in (-1, 1):
            _face(tyre, [pt(r0, a + sgn * hw, z0), pt(R, a + sgn * hw * 0.85, z0), pt(R, a + sgn * hw * 0.85, z1),
                         pt(r0, a + sgn * hw, z1)], inside, "lug_side", (0, 0, 1))
        for z in (z0, z1):
            _face(tyre, [pt(r0, a - hw, z), pt(r0, a + hw, z), pt(R, a + hw * 0.85, z), pt(R, a - hw * 0.85, z)],
                  inside, "lug_side", (1, 0, 0))
    return ({"aero_wheel_body": body, "aero_wheel_tyre": tyre},
            {"aero_wheel_body": (0.0, 0.0, 0.0), "aero_wheel_tyre": TC})


LIGHT = th.norm((-0.35, 0.85, -0.45))

# name: (seed, builder, texture size, palette)
MODELS = {"aero_block": (701, build_block, 256, "aero"), "aero_wheel": (702, build_wheel, 256, "aero"),
          "aero_block_ref": (701, build_block, 256, "ref"), "aero_wheel_ref": (702, build_wheel, 256, "ref")}


# ── texture, glb ───────────────────────────────────────────────────────────────────────────────

def _basis(f):
    n = th.newell(f.pts)
    u = f.u_hint or (1, 0, 0)
    u = th.sub(u, th.mul(n, th.dot(u, n)))
    if th.dot(u, u) < 1e-6:
        u = th.sub((0, 1, 0), th.mul(n, th.dot((0, 1, 0), n)))
    u = th.norm(u)
    v = th.mul(th.cross(n, u), -1)
    return n, u, v


def make(name):
    seed, build, tex, pal = MODELS[name]
    pal = PALETTES[pal]
    random.seed(seed)
    th.random.seed(seed)
    parts, origins = build()
    img = Image.new("RGB", (tex, tex), (0, 0, 0))
    pk = th.Packer(tex)
    todo = []
    for part, faces in parts.items():
        for f in faces:
            n, u, v = _basis(f)
            p0 = f.pts[0]
            pts2 = [(th.dot(th.sub(p, p0), u) * DENS, th.dot(th.sub(p, p0), v) * DENS) for p in f.pts]
            mx, my = min(p[0] for p in pts2), min(p[1] for p in pts2)
            pts2 = [(p[0] - mx, p[1] - my) for p in pts2]
            w = max(1, int(math.ceil(max(p[0] for p in pts2))))
            h = max(1, int(math.ceil(max(p[1] for p in pts2))))
            todo.append((h, w, f, n, u, v, p0, mx, my, pts2, part))
    todo.sort(key=lambda t: (-t[0], -t[1]))
    for h, w, f, n, u, v, p0, mx, my, pts2, part in todo:
        rect = pk.take(w, h)
        x0, y0 = rect[0], rect[1]
        for yy in range(-PAD, h + PAD):
            for xx in range(-PAD, w + PAD):
                px, py = xx + 0.5, yy + 0.5
                P = th.add(p0, th.add(th.mul(u, (px + mx) / DENS), th.mul(v, (py + my) / DENS)))
                d = th.dist_to_edges(min(max(px, 0), w), min(max(py, 0), h), pts2)
                c = paint(pal, f.style, P, n, d, TC if part == "aero_wheel_tyre" else (0, 0, 0))
                img.putpixel((x0 + xx, y0 + yy), tuple(int(v_) for v_ in c))
        f.uv = [(x0 + p[0], y0 + p[1]) for p in pts2]
    img.save(th.OUT_PNG % name)
    write_glb(parts, origins, name, tex)
    total = 0
    for part, faces in parts.items():
        t = sum(len(fc.pts) - 2 for fc in faces)
        total += t
        print("%s: %d triangles" % (part, t))
    print("%s: %d triangles, texture %dx%d, used rows to %d px" % (name, total, tex, tex, pk.y + pk.row_h))


def write_glb(parts, origins, name, tex):
    """One node per part, its mesh in the part's own space and the node standing at its pivot."""
    blob = bytearray()
    views, accs, meshes, nodes = [], [], [], []

    def put(data, fmt, target=None):
        off = len(blob)
        for row in data:
            blob.extend(struct.pack("<" + fmt, *(row if isinstance(row, tuple) else (row,))))
        while len(blob) % 4:
            blob.append(0)
        vw = {"buffer": 0, "byteOffset": off, "byteLength": len(blob) - off}
        if target:
            vw["target"] = target
        views.append(vw)
        return len(views) - 1

    def acc(vi, ctype, count, typ, mn=None, mx=None):
        a = {"bufferView": vi, "componentType": ctype, "count": count, "type": typ}
        if mn is not None:
            a["min"], a["max"] = mn, mx
        accs.append(a)
        return len(accs) - 1

    for part, faces in parts.items():
        o = origins.get(part, (0.0, 0.0, 0.0))
        pos, nrm, uvs, idx = [], [], [], []
        for f in faces:
            n = th.newell(f.pts)
            base = len(pos)
            for p, t in zip(f.pts, f.uv):
                pos.append(th.sub(p, o))
                nrm.append(n)
                uvs.append((t[0] / tex, t[1] / tex))
            for k in range(1, len(f.pts) - 1):
                idx += [base, base + k, base + k + 1]
        a_pos = acc(put(pos, "3f", 34962), 5126, len(pos), "VEC3",
                    [min(p[i] for p in pos) for i in range(3)], [max(p[i] for p in pos) for i in range(3)])
        a_nrm = acc(put(nrm, "3f", 34962), 5126, len(nrm), "VEC3")
        a_uv = acc(put(uvs, "2f", 34962), 5126, len(uvs), "VEC2")
        a_idx = acc(put(idx, "H", 34963), 5123, len(idx), "SCALAR")
        meshes.append({"name": part, "primitives": [{
            "attributes": {"POSITION": a_pos, "NORMAL": a_nrm, "TEXCOORD_0": a_uv},
            "indices": a_idx, "material": 0}]})
        nodes.append({"name": part, "mesh": len(meshes) - 1, "translation": list(o)})
    png = open(th.OUT_PNG % name, "rb").read()
    off = len(blob)
    blob.extend(png)
    while len(blob) % 4:
        blob.append(0)
    views.append({"buffer": 0, "byteOffset": off, "byteLength": len(png)})
    gltf = {
        "asset": {"version": "2.0", "generator": "art/aero_models.py"},
        "extensionsUsed": ["KHR_materials_unlit"],
        "scene": 0,
        "scenes": [{"nodes": list(range(len(nodes)))}],
        "nodes": nodes,
        "meshes": meshes,
        "materials": [{"name": name, "doubleSided": True,
                       "extensions": {"KHR_materials_unlit": {}},
                       "pbrMetallicRoughness": {"baseColorTexture": {"index": 0},
                                                "metallicFactor": 0, "roughnessFactor": 0.9}}],
        "textures": [{"source": 0, "sampler": 0}],
        "samplers": [{"magFilter": 9728, "minFilter": 9986}],
        "images": [{"bufferView": len(views) - 1, "mimeType": "image/png", "name": name + "_texture"}],
        "buffers": [{"byteLength": len(blob)}],
        "bufferViews": views,
        "accessors": accs,
    }
    js = json.dumps(gltf, separators=(",", ":")).encode()
    while len(js) % 4:
        js += b" "
    total = 12 + 8 + len(js) + 8 + len(blob)
    with open(th.OUT_GLB % name, "wb") as fh:
        fh.write(struct.pack("<III", 0x46546C67, 2, total))
        fh.write(struct.pack("<II", len(js), 0x4E4F534A) + js)
        fh.write(struct.pack("<II", len(blob), 0x004E4942) + bytes(blob))


# the self-check (art/model_check.py) reads em.BLOCKS / em.CHECKS
def _em_build(name):
    def fn(pk, img):
        parts, origins = MODELS[name][1]()
        for part, faces in parts.items():
            o = origins.get(part, (0.0, 0.0, 0.0))
            for fc in faces:
                fc.pts = [th.sub(p, o) for p in fc.pts]
        return parts
    return fn


for _nm, (_seed, _fn, _tex, _pal) in MODELS.items():
    em.BLOCKS[_nm] = (_seed, _em_build(_nm), _tex)
if not hasattr(em, "CHECKS"):
    em.CHECKS = {}
em.CHECKS["aero_block"] = {"cells": ((-0.5, -0.5, -0.5), (0.5, 0.5, 0.5)), "budget": 700}
em.CHECKS["aero_wheel"] = {"cells": ((-0.5, -0.9, -0.5), (0.5, 0.5, 0.5)), "budget": 700,
                           "spin": {"aero_wheel_tyre": (0, 0, 1)},
                           "origins": {"aero_wheel_tyre": TC},
                           "solid": [((-0.5, HULL_BOT, Z_BODY), (0.5, 0.3, 0.5))]}

if __name__ == "__main__":
    for nm in (sys.argv[1:] or list(MODELS)):
        make(nm)
