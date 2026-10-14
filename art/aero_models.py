#!/usr/bin/env python3
"""AERO'S BASIC BLOCK AND STANDARD WHEEL, after the player's pictures of TerraTech's racing corporation.
DRAFTS for the player's approval: generator only, not wired into the game.

    python3 art/aero_models.py [aero_block|aero_wheel|aero_block_ref|aero_wheel_ref]
        -> objects/<name>_texture.png + art/out/<name>.glb (one node per part, at its pivot)

Two palettes over one shape: AERO (the emblem: blue cap, white, orange base) and REF (the pictures'
red, white, blue). The marks are the FACTION'S EMBLEM (images/faction_aero.png), sampled into the
texture - never a letter of our own.

BLOCK - three layers, as the picture: a blue octagonal base (square, corners cut) with its top edge
rounded; a white octagonal middle set in, its vertical corners cut broad; a thick cap overhanging
the white, its top edges sloping in broad bevels, a notch cut into the middle of every top edge so
the corners stand up; the emblem in a white diamond on top and on every white face.

WHEEL - TWO CELLS ALONG THE ROLL (x -0.5..1.5): the tyre in the first, its fairing trailing into the
second. A big knobbly tyre (lugs across the tread, shoulder lugs on the outer wall, a dashed ring on
the wall, a white dished hub in a blue ring); over it a WING the whole width, swept back, its top the
cap colour with a white diagonal stripe and the emblem at its front; behind the tyre a white BODY
from the hull face, its back running down to a point at the axle's height, its lower edge the
base colour.
  aero_wheel_body    wing and body (still)
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
DENS = 80.0                    # emblems on the faces need more texels than 48 a metre
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


_EMB = None


def emblem(u, v):
    """The faction's emblem, (u, v) 0..1 over its square; None outside it or where it is clear."""
    global _EMB
    if _EMB is None:
        _EMB = Image.open(os.path.join(th.ROOT, "images", "faction_aero.png")).convert("RGBA")
    if not (0.0 <= u < 1.0 and 0.0 <= v < 1.0):
        return None
    w, h = _EMB.size
    c = _EMB.getpixel((int(u * w), int(v * h)))
    if c[3] < 110:
        return None
    return c[:3]


def _over(base, P, n, centre, half, flat=None):
    """The emblem as a decal centred at `centre` (h, y) on a side face, or on the top (x, z)."""
    if flat == "top":
        u = (P[0] - centre[0] + half) / (2 * half)
        v = (P[2] - centre[1] + half) / (2 * half)
    else:
        h = -th.dot(P, th.norm(th.cross((0, 1, 0), n)))
        u = (h - centre[0] + half) / (2 * half)
        v = 1.0 - (P[1] - centre[1] + half) / (2 * half)
    c = emblem(u, v)
    return c if c is not None else base


def _mix(a, b, t):
    return tuple(a[i] * (1 - t) + b[i] * t for i in range(3))


def _slot(P):
    """The dark slot slanting down the fairing's side, toward its back."""
    x, y = P[0], P[1]
    return 0.98 < x - 0.28 * y < 1.06 and -0.24 < y < 0.06


def paint(pal, style, P, n, d, part_origin):
    top, mid, low = pal["top"], pal["mid"], pal["low"]
    k = _lit(n)
    white = _tone(mid, max(k, 0.93))
    # ---- block
    if style == "b_base":
        return _tone(low, k)
    if style == "b_base_top":
        return _tone(_mix(low, (255, 255, 255), 0.15), k)
    if style == "b_white":
        if abs(n[1]) < 0.5 and max(abs(n[0]), abs(n[2])) > 0.95:
            return _over(white, P, n, (0.0, -0.09), 0.15)
        return _tone(mid, max(k, 0.9) * 0.93)              # the cut corners a shade down
    if style == "b_cap":
        return _tone(top, k)
    if style == "b_bevel":
        return _tone(_mix(top, (255, 255, 255), 0.10), k)
    if style == "b_notch":
        return _tone(top, k * 0.8)
    if style == "b_under":
        return _tone(top, 0.5)
    if style == "b_top":
        m = abs(P[0]) + abs(P[2])
        if m < 0.205:
            return _over(white, P, n, (0.0, 0.0), 0.115, "top")
        if m < 0.235:
            return _tone(mid, 0.97)
        return _tone(top, k)
    # ---- wheel
    if style == "w_top":
        # the cap colour along the top, a white stripe slanting across it
        t = P[0] + 0.5 * (P[2] - 0.2)
        if 0.30 < t < 0.46:
            return white
        return _tone(top, k)
    if style == "w_back":
        return _tone(top, k * 0.85) if P[1] > 0.0 else white
    if style in ("w_body", "w_mount"):
        if P[1] < -0.30 + 0.10 * max(0.0, (P[0] - 0.55)) and P[0] > 0.35:
            return _tone(low, k)
        if style == "w_body" and _slot(P):
            return (56, 58, 66)
        if style == "w_body":
            if abs(P[0] - 0.66) < 0.09 and abs(P[1] + 0.07) < 0.09:
                return _over(white, P, (0.0, 0.0, -1.0), (0.66, -0.07), 0.085)
        return white if style == "w_body" else _tone(mid, 0.9)
    if style == "w_bevel":
        return _tone(_mix(mid, (255, 255, 255), 0.6), 1.0) if P[1] > -0.2 else white
    if style == "w_bevel_low":
        return _tone(_mix(low, (255, 255, 255), 0.25), k)
    if style == "w_low":
        return _tone(low, k * 0.92)
    if style == "w_in":
        return _tone(mid, 0.6)
    if style == "w_lipwall":
        return white
    # the tyre
    q = th.sub(P, part_origin)
    r = math.hypot(q[0], q[1])
    ang = math.atan2(q[1], q[0])
    if style == "tread":
        return th.jitter(RUBBER, 2)
    if style == "lug":
        return th.jitter(th.shade(RUBBER, 1.5 if d < 1.0 else 1.28), 2)
    if style == "lug_side":
        return th.jitter(th.shade(RUBBER, 1.0), 2)
    if style == "wall":
        if abs(r - 0.335) < 0.009 and (ang * 12 / math.pi) % 1.0 < 0.62:
            return (210, 212, 218)
        return th.jitter(th.shade(RUBBER, 1.12 if r > 0.37 else 1.0), 2)
    if style == "rimwall":
        return low
    if style == "rim":
        if r > 0.185:
            return low
        if r > 0.17:
            return (24, 24, 30)
        return th.shade(mid, 0.86 + 0.5 * max(q[0] * -0.4 + q[1] * 0.6, 0.0))
    if style == "dome":
        return _tone(mid, max(k, 0.9) * 1.02)
    if style == "stub":
        return (60, 62, 70)
    return (255, 0, 255)


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

def _area(poly):
    return sum(poly[i][0] * poly[(i + 1) % len(poly)][1] - poly[(i + 1) % len(poly)][0] * poly[i][1]
               for i in range(len(poly))) / 2.0


def ear_clip(poly):
    """Triangles (index triples) of a simple polygon, either winding."""
    idx = list(range(len(poly)))
    if _area(poly) < 0:
        idx.reverse()
    out = []

    def inside(p, a, b, c):
        def cr(o, x, y):
            return (x[0] - o[0]) * (y[1] - o[1]) - (x[1] - o[1]) * (y[0] - o[0])
        return cr(a, b, p) >= 0 and cr(b, c, p) >= 0 and cr(c, a, p) >= 0

    while len(idx) > 3:
        for k in range(len(idx)):
            i0, i1, i2 = idx[k - 1], idx[k], idx[(k + 1) % len(idx)]
            a, b, c = poly[i0], poly[i1], poly[i2]
            if (b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0]) <= 1e-9:
                continue
            if any(inside(poly[j], a, b, c) for j in idx if j not in (i0, i1, i2)):
                continue
            out.append((i0, i1, i2))
            idx.pop(k)
            break
        else:
            break
    out.append(tuple(idx))
    return out


def extrude_poly_z(faces, poly, z0, z1, cap_styles, edge_styles):
    """Any simple (x, y) polygon from z0 to z1: caps as ear-clipped triangles, a wall per edge."""
    sign = 1.0 if _area(poly) > 0 else -1.0
    for z, st in zip((z0, z1), cap_styles):
        if not st:
            continue
        for tri in ear_clip(poly):
            pts = [(poly[i][0], poly[i][1], z) for i in tri]
            c = th.mul(tuple(map(sum, zip(*pts))), 1.0 / 3)
            _face(faces, pts, (c[0], c[1], (z0 + z1) / 2), st, (1, 0, 0))
    n = len(poly)
    for i in range(n):
        st = edge_styles[i] if isinstance(edge_styles, list) else edge_styles
        if not st:
            continue
        a, b = poly[i], poly[(i + 1) % n]
        ex, ey = b[0] - a[0], b[1] - a[1]
        L = math.hypot(ex, ey)
        nx, ny = -ey / L * sign, ex / L * sign          # into the polygon
        m = ((a[0] + b[0]) / 2 + nx * 0.02, (a[1] + b[1]) / 2 + ny * 0.02, (z0 + z1) / 2)
        _face(faces, [(a[0], a[1], z0), (b[0], b[1], z0), (b[0], b[1], z1), (a[0], a[1], z1)], m, st, (ex, ey, 0))


def _octagon(h, cut):
    return [(-h + cut, -h), (h - cut, -h), (h, -h + cut), (h, h - cut), (h - cut, h), (-h + cut, h), (-h, h - cut), (-h, -h + cut)]


# ── the block: three layers, as the player's picture of the basic block ──────────────────────────

BASE_Y = -0.30                 # the base's top
CAP_Y0 = 0.10                  # the cap's underside
CAP_Y1 = 0.36                  # where its top bevels start (at the cell's face)
BEVEL = 0.11                   # how far in the bevel runs over the top
WHITE_H = 0.465                # the white middle's half width
WHITE_CUT = 0.11               # its cut corners
BASE_CUT = 0.07
NOTCH = (0.15, 0.09, 0.12)     # the notch in every top edge's middle: half width outside, inside, depth


def _rounded(y1, r):
    return [(0.0, y1 - r), (r * 0.3, y1 - r * 0.32), (r, y1)]


def build_block():
    f = []
    # BASE: an octagon, its top edge rounded down to the white
    prism(f, _octagon(0.5, BASE_CUT), -0.5, BASE_Y, _rounded(BASE_Y, 0.06), ["c"] * 8,
          "b_base_top", "b_base", "b_base_top", "b_base")
    # the WHITE middle: an octagon set in, its corners cut broad
    prism(f, _octagon(WHITE_H, WHITE_CUT), BASE_Y, CAP_Y0, [(0.0, CAP_Y0)], ["f"] * 8, "b_white", "b_white", "b_white")
    # the CAP: a slab overhanging the white, then the top: broad bevels from the cell's face in
    sq = [(-0.5, -0.5), (0.5, -0.5), (0.5, 0.5), (-0.5, 0.5)]
    prism(f, sq, CAP_Y0, CAP_Y1, [(0.0, CAP_Y1)], ["f"] * 4, "b_cap", "b_cap", "b_cap", "b_under")
    bev = [(0.0, CAP_Y1), (BEVEL * 0.55, 0.5 - 0.035), (BEVEL, 0.5)]
    a = 0.5
    no, ni, nd = NOTCH
    bb = a - nd
    for sx in (-1, 1):
        for sz in (-1, 1):
            prism(f, [(sx * a, sz * bb), (sx * ni, sz * bb), (sx * no, sz * a), (sx * a, sz * a)], CAP_Y1, 0.5, bev,
                  ["x", "f", "c", "c"], "b_cap", "b_notch", "b_bevel")
            prism(f, [(sx * bb, sz * bb), (sx * a, sz * bb), (sx * a, sz * no), (sx * bb, sz * ni)], CAP_Y1, 0.5, bev,
                  ["c", "c", "f", "x"], "b_cap", "b_notch", "b_bevel")
    prism(f, [(-bb, -bb), (bb, -bb), (bb, bb), (-bb, bb)], CAP_Y1, 0.5, [(0.0, 0.5)], ["x"] * 4, "b_top", "b_cap", "b_cap")
    for k in range(4):                              # the notches' inner walls
        ang = k * math.pi / 2
        c, s_ = math.cos(ang), math.sin(ang)
        rot = lambda x, z: (x * c - z * s_, z * c + x * s_)
        p0, p1 = rot(-ni, bb), rot(ni, bb)
        _face(f, [(p0[0], CAP_Y1, p0[1]), (p1[0], CAP_Y1, p1[1]), (p1[0], 0.5, p1[1]), (p0[0], 0.5, p0[1])],
              (0.0, 0.45, 0.0), "b_notch", (1, 0, 0))
    return {"aero_block": f}, {"aero_block": (0.0, 0.0, 0.0)}


# ── the wheel: two cells along the roll, the tyre in the first ──────────────────────────────────

TC = (0.0, -0.40, -0.28)       # the tyre's centre
R, W = 0.46, 0.38              # tyre radius (over the lugs) and width
R0 = 0.40                      # the tread under the lugs
RIM_R = 0.20
LUGS = 18
FENDER_R = 0.53                # the fairing's lower edge, round the tyre
FIN_Z = -0.07                  # the fairing's outboard face, inboard of the tyre
FIN_BEVEL = 0.035              # its outboard edge, bevelled all round
NOSE = (-0.5, 0.04)            # the fairing's front point, over the tyre's front
SPIKE = (1.48, -0.44)          # its back point, at the axle's height
TOP = [(-0.30, 0.17), (0.40, 0.19), (1.08, 0.15)]   # its top edge, front to back
LIP_ANG = (128.0, 52.0)        # the lip over the tyre, front to back
LIP_SEG = 8
LIP_Z = -0.48                  # its outboard edge


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


def _offset(poly, d):
    """The polygon moved in by d (mitred), either winding."""
    sign = 1.0 if _area(poly) > 0 else -1.0
    out = []
    n = len(poly)
    for i in range(n):
        p0, p1, p2 = poly[i - 1], poly[i], poly[(i + 1) % n]
        def nrm(a, b):
            ex, ey = b[0] - a[0], b[1] - a[1]
            L = math.hypot(ex, ey)
            return (-ey / L * sign, ex / L * sign)
        n1, n2 = nrm(p0, p1), nrm(p1, p2)
        m = (n1[0] + n2[0], n1[1] + n2[1])
        L = math.hypot(*m)
        m = (m[0] / L, m[1] / L)
        k = d / max(0.35, m[0] * n1[0] + m[1] * n1[1])
        out.append((p1[0] + m[0] * k, p1[1] + m[1] * k))
    return out


def build_wheel():
    body, tyre = [], []
    zi, zo = TC[2] + W / 2, TC[2] - W / 2
    # the FAIRING inboard of the tyre: its side a swoosh - a point over the tyre's front, the top
    # running back, the back down to a point at the axle's height, the lower edge round the tyre
    arc = []
    a0 = math.degrees(math.atan2(NOSE[1] - 0.10 - TC[1], NOSE[0] + 0.03 - TC[0]))
    for i in range(10):
        a = math.radians(a0 * (1 - i / 9.0))
        arc.append((TC[0] + FENDER_R * math.cos(a), TC[1] + FENDER_R * math.sin(a)))
    poly = [NOSE] + TOP + [SPIKE, (TC[0] + FENDER_R + 0.06, SPIKE[1] + 0.02)] + list(reversed(arc))
    # its edge styles: top (cap colour), back, bottom (base colour), the arc (inside, round the tyre)
    nt = len(TOP)
    edges = ["w_top"] * (nt + 0) + ["w_back", "w_low"] + ["w_in"] * (len(poly) - nt - 2)
    inner = _offset(poly, FIN_BEVEL)
    extrude_poly_z(body, poly, FIN_Z + FIN_BEVEL, 0.5, (None, "w_mount"), edges)
    extrude_poly_z(body, inner, FIN_Z, FIN_Z + FIN_BEVEL, ("w_body", None), None)
    for i in range(len(poly)):                      # the bevel round the outboard face
        j = (i + 1) % len(poly)
        q = [(poly[i][0], poly[i][1], FIN_Z + FIN_BEVEL), (poly[j][0], poly[j][1], FIN_Z + FIN_BEVEL),
             (inner[j][0], inner[j][1], FIN_Z), (inner[i][0], inner[i][1], FIN_Z)]
        c = th.mul(tuple(map(sum, zip(*q))), 0.25)
        cen = th.mul(tuple(map(sum, zip(*[(p[0], p[1], 0.0) for p in poly]))), 1.0 / len(poly))
        st = "w_bevel_low" if edges[i] == "w_low" else ("w_in" if edges[i] == "w_in" else "w_bevel")
        _face(body, q, (cen[0], cen[1], 0.2), st)
    # the LIP: the fairing's top runs on out over the tyre, its front a point
    stations = []
    for i in range(LIP_SEG + 1):
        t = i / LIP_SEG
        a = math.radians(LIP_ANG[0] + (LIP_ANG[1] - LIP_ANG[0]) * t)
        N = (math.cos(a), math.sin(a), 0.0)
        k = 0.35 + 0.65 * min(1.0, t * 3.0)
        stations.append(((TC[0] + FENDER_R * N[0], TC[1] + FENDER_R * N[1], 0.0), (0.0, 0.0, 1.0), N, k))
    lt = 0.07
    sec = [(FIN_Z + 0.01, 0.0), (FIN_Z + 0.01, lt), (LIP_Z + 0.03, lt), (LIP_Z, lt - 0.03), (LIP_Z, 0.0)]
    sweep(body, stations, sec, [None, "w_top", "w_bevel", "w_lipwall", "w_in"],
          caps=("w_lipwall", "w_lipwall", [[0, 1, 2, 3, 4]]))
    # the TYRE: tread under the lugs, lugs across it, shoulder lugs on the outer wall, a dished hub
    _band(tyre, R0, zo, R0, zi, LUGS, "tread")
    _band(tyre, R0, zo, RIM_R, zo, LUGS, "wall")
    _band(tyre, R0, zi, 0.07, zi, LUGS, "wall")
    _band(tyre, RIM_R, zo, RIM_R, zo + 0.04, 12, "rimwall")
    ring = _ring(RIM_R, 12, zo + 0.04)
    peak = (TC[0], TC[1], zo + 0.005)
    tip = _ring(0.09, 12, zo + 0.012)
    for i in range(12):
        j = (i + 1) % 12
        _face(tyre, [ring[i], ring[j], tip[j], tip[i]], (TC[0], TC[1], zo + 0.2), "rim")
    _face(tyre, tip, (TC[0], TC[1], zo + 0.2), "dome")
    _band(tyre, 0.07, zi, 0.07, zi + 0.02, 8, "stub")
    hw = math.pi / LUGS * 0.66

    def pt(r, ang, z):
        return (TC[0] + r * math.cos(ang), TC[1] + r * math.sin(ang), z)

    for k in range(LUGS):
        a = (k + 0.5) * 2 * math.pi / LUGS
        z0, z1 = (zo, TC[2] + 0.06) if k % 2 == 0 else (TC[2] - 0.06, zi)
        inside = pt((R0 + R) / 2, a, (z0 + z1) / 2)
        r0 = R0 - 0.004
        _face(tyre, [pt(R, a - hw * 0.85, z0), pt(R, a + hw * 0.85, z0), pt(R, a + hw * 0.85, z1), pt(R, a - hw * 0.85, z1)],
              inside, "lug", (0, 0, 1))
        for sgn in (-1, 1):
            _face(tyre, [pt(r0, a + sgn * hw, z0), pt(R, a + sgn * hw * 0.85, z0), pt(R, a + sgn * hw * 0.85, z1),
                         pt(r0, a + sgn * hw, z1)], inside, "lug_side", (0, 0, 1))
        for z in (z0, z1):
            _face(tyre, [pt(r0, a - hw, z), pt(r0, a + hw, z), pt(R, a + hw * 0.85, z), pt(R, a - hw * 0.85, z)],
                  inside, "lug_side", (1, 0, 0))
        if k % 2 == 0:                              # a shoulder lug down the outer wall
            sz = zo - 0.025
            ins = pt(0.37, a, zo + 0.01)
            q0 = [pt(0.335, a - hw * 0.7, zo), pt(R0, a - hw * 0.85, zo), pt(R0, a + hw * 0.85, zo), pt(0.335, a + hw * 0.7, zo)]
            q1 = [(p[0], p[1], sz) for p in q0]
            _face(tyre, q1, ins, "lug", (1, 0, 0))
            for i in range(4):
                j = (i + 1) % 4
                _face(tyre, [q0[i], q0[j], q1[j], q1[i]], ins, "lug_side", (1, 0, 0))
    return ({"aero_wheel_body": body, "aero_wheel_tyre": tyre},
            {"aero_wheel_body": (0.0, 0.0, 0.0), "aero_wheel_tyre": TC})


LIGHT = th.norm((-0.35, 0.85, -0.45))

# name: (seed, builder, texture size, palette)
MODELS = {"aero_block": (701, build_block, 512, "aero"), "aero_wheel": (702, build_wheel, 512, "aero"),
          "aero_block_ref": (701, build_block, 512, "ref"), "aero_wheel_ref": (702, build_wheel, 512, "ref")}


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
em.CHECKS["aero_wheel"] = {"cells": ((-0.5, -0.9, -0.5), (1.5, 0.5, 0.5)), "budget": 700,
                           "spin": {"aero_wheel_tyre": (0, 0, 1)},
                           "origins": {"aero_wheel_tyre": TC},
                           "solid": [((-0.5, -0.30, FIN_Z), (1.5, 0.15, 0.5))]}

if __name__ == "__main__":
    for nm in (sys.argv[1:] or list(MODELS)):
        make(nm)
