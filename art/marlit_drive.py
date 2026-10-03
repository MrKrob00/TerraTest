#!/usr/bin/env python3
"""MARLIT'S CABIN AND WHEEL, 2x2x2 like every Marlit block (anchored in a corner: x -1.5..0.5,
y -0.5..1.5, z -1.5..0.5). They replace the Falsus cabin and the big wheel the faction drove on as
placeholders.

    python3 art/marlit_drive.py [marlit_cabin|marlit_wheel2]
        -> objects/<name>_texture.png + art/out/<name>.glb
    godot --headless --path . --script res://art/turret_import.gd -- <name> ...
        -> blocks/meshes/<name>_<part>.tres

CABIN - a mech's head, not a car's cab (the player), in angular armour of two layers over a dark core:
slabs with 45 deg bevels, the high layer's tops the cube's faces, so it joins on every face, and no
round part anywhere. Front: helmet guards, a crest and brows over a cyan visor, a ribbed mouthplate,
intake cheeks, a chin chevron; sides: an ear with a fin, louvres, a band; roof: crest, brows, hatches;
back: a framed radiator.
  body - all of it (a cabin moves nothing)

WHEEL - after the Falsus wheel's layout (the player: "a transmission, and the wheel lower, like
Falsus"; then "look again at the transmission, how it looks and how it works"): a bearing plate on the
BACK face (`connect_faces` 2) with a gearbox; two EQUAL PARALLEL A-arms on pins, so the hub carrier
rides up and down upright; two coil-over dampers whose springs squeeze as it rises; and a drive shaft
from the gearbox to the carrier that swings, stretches and spins with the tyre. The tyre hangs below
the block, as the Falsus wheels do. Every moving piece is its own part about its own pivot - see the
wheel section.
"""
import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import turret_heads as th  # noqa: E402
import emitter_models as em  # noqa: E402
import hull_models as hm  # noqa: E402
import marlit_weapons as mw  # noqa: E402

CX, CY, CZ = -0.5, 0.5, -0.5          # the 2x2x2 block's middle


def _quad(f, pts, inside, style, u=(1, 0, 0)):
    mw._face(f, pts, inside, style, u_hint=u)


def _oct_on(f, c, u, v, r, style, inside):
    """A flat octagon of half width r across its flats, centred at c in the plane of u and v."""
    k = r / math.cos(math.pi / 8)
    pts = [th.add(c, th.add(th.mul(u, k * math.cos(math.pi / 8 + i * math.pi / 4)),
                            th.mul(v, k * math.sin(math.pi / 8 + i * math.pi / 4)))) for i in range(8)]
    mw._face(f, pts, inside, style, u_hint=u)


# ── the cabin ───────────────────────────────────────────────────────────────────────────────────
# A MECH'S HEAD, NOT A CAR'S CAB, IN ANGULAR ARMOUR OF TWO LAYERS. The player's calls, in order: "the
# cabin of some transformer, not of a machine, and connection points everywhere"; "too many holes into
# it"; "too simple, and I still do not like the circles". So: a dark core CORE inside the cube, and
# over it armour slabs with 45 deg bevels - a low layer (top at L1) and a high one whose tops ARE the
# cube's faces, so every face joins. Between slabs only seams; what light there is lies in them or on
# a slab. NO ROUND PART AND NO OCTAGON on it: the shoulder joint, the chest core and the roof hatch
# were octagons and read as circles. Front: helmet guards, a crest and brows over a cyan visor, a
# ribbed mouthplate, intake cheeks, a chin chevron. Sides: an ear module with a fin, louvres, a band.
# Roof: a crest ridge, brow wedges, hatches. Back: a framed radiator of fins. Each face owns its
# edges in turn (front/back, then the sides, then roof and floor), so slabs never cross at a corner.
CORE = 0.09                  # how far the core stands inside the cube
L1 = 0.045                   # the low layer's top, under the cube's face
E_FB = 1.0                   # front and back slabs reach the cube's edges and own its corners
E_SD = 1.0 - CORE            # the sides' reach along the body, the roof's and floor's both ways: they
                             # stop where the next face's slabs stand, so no edge is notched
LIGHT2 = (-0.37, 0.93)       # the painted light in a face's own axes: from above, a little left


class _Face:
    """A face of the cube in its own axes: a across, b up (world up on the walls, toward the front
    on the roof and the floor), n out. d is depth INTO the block from the cube's face."""
    def __init__(self, cen, a, b, n):
        self.cen, self.a, self.b, self.n = cen, a, b, n

    def P(self, x, y, d=0.0):
        return th.add(self.cen, th.add(th.add(th.mul(self.a, x), th.mul(self.b, y)), th.mul(self.n, -d)))


def _area2(pts):
    return sum(pts[i][0] * pts[(i + 1) % len(pts)][1] - pts[(i + 1) % len(pts)][0] * pts[i][1]
               for i in range(len(pts)))


def _inset(pts, ws):
    """A convex polygon with edge i moved in by ws[i]."""
    n = len(pts)
    ccw = _area2(pts) > 0
    lines = []
    for i in range(n):
        p, q = pts[i], pts[(i + 1) % n]
        dx, dy = q[0] - p[0], q[1] - p[1]
        L = math.hypot(dx, dy)
        nx, ny = (-dy / L, dx / L) if ccw else (dy / L, -dx / L)
        lines.append(((p[0] + nx * ws[i], p[1] + ny * ws[i]), (dx, dy)))
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


def _slab(f, F, pts, top=0.0, base=CORE, style="mplate", lim=E_FB, limy=None):
    """An armour slab: footprint `pts` (convex) at depth `base`, its top at `top` inset by the drop
    (45 deg bevels, each toned by where it faces the painted light) - except along the cube's own
    edge, where the wall stands nearly upright so the face stays whole."""
    limy = lim if limy is None else limy
    n = len(pts)
    drop = base - top
    ws = []
    outer = []
    for i in range(n):
        p, q = pts[i], pts[(i + 1) % n]
        o = ((abs(p[0]) >= lim - 0.01 and abs(q[0]) >= lim - 0.01 and p[0] * q[0] > 0) or
             (abs(p[1]) >= limy - 0.01 and abs(q[1]) >= limy - 0.01 and p[1] * q[1] > 0))
        outer.append(o)
        ws.append(0.012 if o else drop)
    tp = _inset(pts, ws)
    cx = sum(p[0] for p in pts) / n
    cy = sum(p[1] for p in pts) / n
    inside = F.P(cx, cy, base + 0.05)
    mw._face(f, [F.P(x, y, top) for x, y in tp], inside, style, u_hint=F.a)
    ccw = _area2(pts) > 0
    for i in range(n):
        j = (i + 1) % n
        dx, dy = pts[j][0] - pts[i][0], pts[j][1] - pts[i][1]
        L = math.hypot(dx, dy)
        on = (dy / L, -dx / L) if ccw else (-dy / L, dx / L)          # the edge's outward normal
        k = max(0, min(5, int(round(2.5 + 2.6 * (on[0] * LIGHT2[0] + on[1] * LIGHT2[1])))))
        q = [F.P(*tp[i], top), F.P(*tp[j], top), F.P(*pts[j], base), F.P(*pts[i], base)]
        mw._face(f, q, inside, "mflat1" if outer[i] else "mbev%d" % k, u_hint=th.sub(q[1], q[0]))


def _paint(f, F, pts, d, style):
    """A flat patch at depth d: light on the core in a seam, or an inlay a few millimetres proud."""
    cx = sum(p[0] for p in pts) / len(pts)
    cy = sum(p[1] for p in pts) / len(pts)
    mw._face(f, [F.P(x, y, d) for x, y in pts], F.P(cx, cy, 0.5), style, u_hint=F.a)


def _rect(x0, y0, x1, y1):
    return [(x0, y0), (x1, y0), (x1, y1), (x0, y1)]


def _mirror(pts):
    return [(-x, y) for x, y in reversed(pts)]


def _both(fn, pts, *a, **k):
    fn(pts, *a, **k)
    fn(_mirror(pts), *a, **k)


def _bolts(f, F, at, d=-0.004, r=0.028):
    for x, y in at:
        _paint(f, F, _rect(x - r, y - r, x + r, y + r), d, "mbolt")


def _cab_front(f, F):
    E = E_FB
    S = lambda pts, *a, **k: _slab(f, F, pts, *a, lim=E, **k)      # noqa: E731
    lamp = lambda pts, st: _paint(f, F, pts, CORE - 0.003, st)      # noqa: E731
    # the seams' light: sunset down the helmet guards' joint, cyan behind the visor
    _both(lambda p: lamp(p, "mglow"), _rect(-E, 0.01, -0.55, 0.07))
    lamp(_rect(-0.56, 0.20, 0.56, 0.70), "cyan1")
    # the helmet guards, upper and lower, either side of the face
    _both(S, [(-E, E), (-0.60, E), (-0.54, 0.40), (-0.55, 0.08), (-E, 0.08)])
    _both(S, [(-E, 0.0), (-0.555, 0.0), (-0.60, -0.30), (-0.70, -E), (-E, -E)])
    _both(lambda p: _bolts(f, F, p), [(-0.86, -0.12), (-0.86, -0.84), (-0.76, -0.84)])
    _both(lambda p: _paint(f, F, p, -0.003, "cyan2"), [(-0.90, 0.20), (-0.86, 0.20), (-0.86, 0.86), (-0.90, 0.86)])
    # the crest, and a brow either side angled down to it
    S([(-0.14, E), (0.14, E), (0.14, 0.62), (0.0, 0.42), (-0.14, 0.62)])
    _paint(f, F, [(-0.03, 0.90), (0.03, 0.90), (0.03, 0.62), (0.0, 0.56), (-0.03, 0.62)], -0.003, "mglow")
    _both(S, [(-0.56, E), (-0.18, E), (-0.18, 0.52), (-0.53, 0.66)])
    # the visor on the low layer, eyes standing out of it
    S(_rect(-0.54, 0.22, 0.54, 0.68), L1, CORE, "cyan1")
    _both(lambda p: S(p, L1 - 0.012, CORE, "cyan3"), [(-0.50, 0.29), (-0.21, 0.29), (-0.21, 0.40), (-0.47, 0.50)])
    # the mouthplate: a low plate with four ribs standing to the face
    S([(-0.34, 0.18), (0.34, 0.18), (0.34, -0.38), (0.24, -0.46), (-0.24, -0.46), (-0.34, -0.38)], L1, CORE, "mflat0")
    for x in (-0.23, -0.08, 0.08, 0.23):
        y1 = -0.40 if abs(x) > 0.15 else -0.44
        S(_rect(x - 0.055, y1, x + 0.055, 0.12), 0.0, L1)
    # the cheeks: intakes beside it
    _both(lambda p: S(p, L1, CORE, "mvent"), [(-0.52, 0.18), (-0.38, 0.18), (-0.38, -0.40), (-0.58, -0.52)])
    # the chin: a chevron the other way, a sunset seam at its point
    lamp(_rect(-0.03, -0.54, 0.03, -E), "mglow")
    _both(S, [(-0.62, -0.58), (-0.38, -0.45), (-0.03, -0.53), (-0.03, -E), (-0.70, -E)])
    _both(lambda p: _bolts(f, F, p), [(-0.50, -0.84), (-0.14, -0.84)])


def _cab_side(f, F):
    E, Y = E_SD, E_FB
    S = lambda pts, *a, **k: _slab(f, F, pts, *a, lim=E, limy=Y, **k)      # noqa: E731
    lamp = lambda pts, st: _paint(f, F, pts, CORE - 0.003, st)      # noqa: E731
    # the ear: a low plate at the front with a fin standing out of it and a cyan strip beside the fin
    S([(0.36, Y), (E, Y), (E, -0.10), (0.50, -0.10), (0.36, 0.20)], L1, CORE, "mflat1")
    S([(0.50, 0.92), (0.70, 0.92), (0.64, 0.02), (0.50, 0.02)])
    S(_rect(0.76, 0.06, 0.82, 0.86), L1 - 0.012, L1 + 0.01, "cyan2")
    # the louvres: a low plate, horizontal fins on it, their bevels dark below and lit above
    S([(-E, Y), (0.32, Y), (0.32, 0.24), (0.18, -0.10), (-E, -0.10)], L1, CORE, "mflat0")
    for y in (0.80, 0.60, 0.40, 0.20):
        S(_rect(-0.78, y - 0.06, 0.14 if y > 0.25 else 0.10, y + 0.06), 0.0, L1)
    # the band: two slabs and a sunset seam, hazard aft
    lamp(_rect(-0.05, -0.14, 0.05, -Y), "mglow")
    lamp(_rect(-E, -0.14, E, -0.10), "mglow")
    S(_rect(-E, -0.18, -0.06, -Y), style="mhazard")
    S(_rect(0.06, -0.18, E, -Y))
    _bolts(f, F, [(0.18, -0.30), (0.76, -0.30), (0.18, -0.84), (0.76, -0.84), (0.44, -0.84)])


def _cab_top(f, F):
    E = E_SD
    S = lambda pts, *a, **k: _slab(f, F, pts, *a, lim=E, **k)      # noqa: E731
    # the crest ridge, its sunset inlay, continuing the front's
    S([(-0.12, -E), (0.12, -E), (0.12, 0.70), (0.0, E), (-0.12, 0.70)])
    _paint(f, F, _rect(-0.03, -0.70, 0.03, 0.66), -0.003, "mglow")
    # either side: a low plate, a brow wedge at the front, a hatch aft
    _both(lambda p: S(p, L1, CORE, "mflat1"), _rect(-E, -E, -0.16, E))
    _both(S, [(-E, 0.62), (-0.16, 0.40), (-0.16, E), (-E, E)])
    _both(S, _rect(-0.76, -0.76, -0.28, 0.04))
    _both(lambda p: _bolts(f, F, p), [(-0.70, -0.70), (-0.34, -0.70), (-0.70, -0.02), (-0.34, -0.02)])
    _both(lambda p: _paint(f, F, p, L1 - 0.003, "cyan2"), _rect(-0.76, 0.14, -0.28, 0.20))


def _cab_back(f, F):
    E = E_FB
    S = lambda pts, *a, **k: _slab(f, F, pts, *a, lim=E, **k)      # noqa: E731
    # a frame round a radiator: the top band, two pillars, a hazard band under
    S([(-E, E), (E, E), (E, 0.62), (0.78, 0.56), (-0.78, 0.56), (-E, 0.62)])
    _both(S, [(-E, 0.56), (-0.70, 0.52), (-0.70, -0.48), (-E, -0.52)])
    S(_rect(-E, -0.56, E, -E), style="mhazard")
    _both(lambda p: _bolts(f, F, p), [(-0.84, 0.40), (-0.84, -0.36), (-0.84, 0.86), (-0.20, 0.86)])
    _both(lambda p: _paint(f, F, p, -0.003, "cyan2"), _rect(-0.88, -0.10, -0.80, 0.14))
    # the radiator: a low plate and five fins
    S(_rect(-0.66, -0.52, 0.66, 0.52), L1, CORE, "mflat0")
    for k in range(5):
        y = -0.38 + k * 0.19
        S(_rect(-0.58, y - 0.045, 0.58, y + 0.045), 0.0, L1)


def _cab_bottom(f, F):
    E = E_SD
    S = lambda pts, *a, **k: _slab(f, F, pts, *a, lim=E, **k)      # noqa: E731
    for sx in (-1, 1):
        for sy in (-1, 1):
            p = _rect(sx * 0.03, sy * 0.03, sx * E, sy * E)
            S(p if _area2(p) > 0 else list(reversed(p)), style="mpside")


def build_marlit_cabin(pk, img):
    parts = {"marlit_cabin_body": []}
    f = parts["marlit_cabin_body"]
    lo, hi = (-1.5, -0.5, -1.5), (0.5, 1.5, 0.5)
    em.cham_box(f, tuple(v + CORE for v in lo), tuple(v - CORE for v in hi), 0.03,
                "mflat0", "mflat0", "mflat0", "mflat0")
    for axis in range(3):
        for side in (0, 1):
            n = [0.0, 0.0, 0.0]
            n[axis] = 1.0 if side else -1.0
            n = tuple(n)
            cen = list((CX, CY, CZ))
            cen[axis] = hi[axis] if side else lo[axis]
            cen = tuple(cen)
            if axis == 1:
                F = _Face(cen, (1.0, 0.0, 0.0), (0.0, 0.0, -1.0), n)
                (_cab_top if side else _cab_bottom)(f, F)
            elif axis == 0:
                # across runs toward the front on both sides, so the ear leads on each
                _cab_side(f, _Face(cen, (0.0, 0.0, -1.0), (0.0, 1.0, 0.0), n))
            else:
                F = _Face(cen, th.cross((0.0, 1.0, 0.0), n), (0.0, 1.0, 0.0), n)
                (_cab_back if side else _cab_front)(f, F)
    return parts


# ── the wheel ───────────────────────────────────────────────────────────────────────────────────
# A MECHANISM THAT MOVES, SO EVERY MOVING PIECE IS ITS OWN PART (the player: "look again at the
# transmission, how it looks and how it works"). The two A-arms are EQUAL AND PARALLEL - a
# parallelogram - so as they swing on their pins the hub carrier rides up and down without tilting and
# the tyre stays upright; the dampers turn to follow the lower arm and their springs squeeze; the drive
# shaft runs from the gearbox to the carrier, swings and stretches with it, and spins with the tyre.
# Every part is built about its own pivot, so the scene's node stands there and only turns:
#   body     - plate, gearbox, the pins' brackets, the dampers' top mounts (still)
#   armup / armlo - an A-arm about its pin at PIV_UP / PIV_LO (rotation.x = swing)
#   knuckle  - the hub carrier about KN (moves with the arms' ends)
#   tyre     - about TC (moves with the carrier, spins about Z)
#   shaft    - unit length down its -Z from the gearbox output (look_at the carrier, scale z, spin)
#   dbody / drod / spring - a damper's cylinder from its top mount, its rod from its bottom mount
#              (each look_at the other end), the spring unit length from the top (scale z)
TC = (-0.5, -0.20, -0.86)    # the tyre's middle at rest: under the block, as the Falsus wheels hang
KN = (-0.5, -0.20, -0.20)    # the hub carrier's middle
PIV_UP = (-0.5, 0.20, 0.24)  # the arms' pins on the plate
PIV_LO = (-0.5, -0.40, 0.24)
# from a pin to its arm's ball joint on the carrier: one vector, so a parallelogram. NEARLY LEVEL: an
# arm pointing steeply down (the first cut, 60 deg) swings its end OUT more than up, and the tyre
# scrubbed sideways 0.2 m over a 0.16 m bump
ARM_V = (0.0, -0.10, -0.44)
ARM_X = (-1.06, 0.06)        # the arms' two legs at the plate
SHAFT_O = (-0.5, -0.20, 0.10)    # the gearbox's output, level with the hub: the shaft runs between the arms
SHAFT_T = (-0.5, -0.20, -0.13)   # where the shaft meets the carrier (moves with it)
DAMP_TOP = ((-0.86, 1.00, 0.18), (-0.14, 1.00, 0.18))
DAMP_AT = 0.45               # where on the UPPER arm's leg a damper's bottom is pinned (nothing above it)
WH_R = 0.85
WH_TREAD = 0.79
WH_SIDE_IN = 0.50
WH_Z = (-1.45, -0.30)
WH_N = 16
WH_HUB = 0.18
PLATE_Z = 0.30


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
        centre = mid
        if abs(z1 - z0) < 1e-6:
            centre = (C[0], C[1], z0 + (0.3 if z0 > C[2] else -0.3) * -1.0)
        mw._face(f, q, centre, style, u_hint=th.sub(q[1], q[0]))


def _shift(faces, origin):
    for fc in faces:
        fc.pts = [th.sub(p, origin) for p in fc.pts]


def _tyre(t):
    O = (0.0, 0.0, 0.0)
    zo, zi = WH_Z[0] - TC[2], WH_Z[1] - TC[2]
    sh = 0.07
    _band_z(t, O, WH_SIDE_IN, zo, WH_TREAD - 0.04, zo, "m")
    _band_z(t, O, WH_SIDE_IN, zi, WH_TREAD - 0.04, zi, "m")
    _band_z(t, O, WH_TREAD - 0.12, zo - 0.004, WH_TREAD - 0.09, zo - 0.004, "mglow")
    _band_z(t, O, WH_TREAD - 0.04, zo, WH_TREAD, zo + sh, "m")
    _band_z(t, O, WH_TREAD - 0.04, zi, WH_TREAD, zi - sh, "m")
    _band_z(t, O, WH_TREAD, zo + sh, WH_TREAD, zi - sh, "mflat0")
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
    _band_z(t, O, WH_SIDE_IN, zo, WH_SIDE_IN - 0.03, zo + 0.05, "m", n=8)
    _band_z(t, O, WH_SIDE_IN - 0.03, zo + 0.05, WH_SIDE_IN - 0.06, zo + 0.05, "mglow", n=8)
    _band_z(t, O, WH_SIDE_IN - 0.06, zo + 0.05, 0.0, zo + 0.12, "mflat0", n=8)
    for k in range(6):
        a = 2 * math.pi * k / 6
        d = (math.cos(a), math.sin(a), 0.0)
        s = (-math.sin(a), math.cos(a), 0.0)
        em.obox(t, (d[0] * 0.29, d[1] * 0.29, zo + 0.07), (d, s, (0.0, 0.0, 1.0)), (0.15, 0.04, 0.04), ["mtone3"] * 6)
    mw.oct_tube(t, (0, 0, zo + 0.12), (0, 0, zo - 0.04), WH_HUB, WH_HUB - 0.03, "m", cap_b="mpin")
    _band_z(t, O, WH_SIDE_IN, zi, 0.22, zi - 0.05, "m", n=8)


def _arm(f, piv, w):
    """An A-arm about its pin: two keeled legs from the plate to a ball joint, a crossbar near the pin,
    the pin through both legs."""
    joint = th.add(piv, ARM_V)
    for x in ARM_X:
        a = (x, piv[1], piv[2])
        em._mwl_plate(f, a, joint, (0.0, 1.0, 0.0), w, w * 0.8, w * 0.8, w * 0.7)
    bar = [th.add((x, piv[1], piv[2]), th.mul(th.sub(joint, (x, piv[1], piv[2])), 0.2)) for x in ARM_X]
    mw.oct_tube(f, bar[0], bar[1], 0.035, 0.035, "m")
    mw.oct_tube(f, (ARM_X[0] - 0.05, piv[1], piv[2]), (ARM_X[1] + 0.05, piv[1], piv[2]), 0.045, 0.045, "m",
                cap_a="mpin", cap_b="mpin")
    em.obox(f, joint, ((1, 0, 0), (0, 1, 0), (0, 0, 1)), (0.07, 0.07, 0.07),
            ["mtone3", "mtone3", "mtone4", "mtone1", "mtone2", "mtone2"])
    _shift(f, piv)


def _shaft(f):
    """The drive shaft, unit length down -Z: a boot at each end and a sunset stripe down two of its
    eight flats, so its spin shows."""
    mw.oct_tube(f, (0, 0, 0.0), (0, 0, -0.12), 0.10, 0.07, "mtone1")
    mw.oct_tube(f, (0, 0, -0.88), (0, 0, -1.0), 0.07, 0.10, "mtone1")
    r = 0.05 / math.cos(math.pi / 8)
    for i in range(8):
        a0 = math.pi / 8 + i * math.pi / 4
        a1 = a0 + math.pi / 4
        q = [(r * math.cos(a0), r * math.sin(a0), -0.12), (r * math.cos(a1), r * math.sin(a1), -0.12),
             (r * math.cos(a1), r * math.sin(a1), -0.88), (r * math.cos(a0), r * math.sin(a0), -0.88)]
        mw._face(f, q, (0, 0, -0.5), "mglow" if i in (0, 4) else "mtone%d" % (1 + i % 3), u_hint=(0, 0, 1))


def build_marlit_wheel2(pk, img):
    import random as _r
    rnd = _r.Random(73)
    names = ["body", "armup", "armlo", "knuckle", "shaft", "dbody", "drod", "spring", "tyre"]
    parts = {"marlit_wheel2_" + n: [] for n in names}
    P_ = lambda n: parts["marlit_wheel2_" + n]          # noqa: E731
    b = P_("body")
    # the bearing plate on the back face, the faction's window on its front
    em.marlit_box(b, (-1.38, -0.48, PLATE_Z), (0.38, 1.38, 0.5), 0.06, rnd, {(2, 0): "window"})
    # the gearbox, vented, with its output flange
    mw.mbox(b, (-0.84, -0.32, 0.14), (-0.16, 0.06, PLATE_Z))
    for x0, x1 in ((-0.80, -0.66), (-0.34, -0.20)):
        _quad(b, [(x0, -0.28, 0.14 - 0.004), (x1, -0.28, 0.14 - 0.004), (x1, 0.02, 0.14 - 0.004),
                  (x0, 0.02, 0.14 - 0.004)], (-0.5, -0.1, 0.2), "mvent")
    mw.oct_tube(b, (SHAFT_O[0], SHAFT_O[1], 0.14), (SHAFT_O[0], SHAFT_O[1], SHAFT_O[2] + 0.005), 0.13, 0.13, "m")
    # the pins' brackets: a clevis either side of every leg
    for piv in (PIV_UP, PIV_LO):
        for x in ARM_X:
            for dx in (-0.09, 0.09):
                em.obox(b, (x + dx, piv[1], (piv[2] + PLATE_Z) / 2 + 0.01), ((1, 0, 0), (0, 1, 0), (0, 0, 1)),
                        (0.025, 0.08, (PLATE_Z - piv[2]) / 2 + 0.07),
                        ["mtone3", "mtone3", "mtone4", "mtone1", "mtone2", "mtone2"])
    # the dampers' top mounts
    for top in DAMP_TOP:
        em.obox(b, (top[0], top[1], (top[2] + PLATE_Z) / 2), ((1, 0, 0), (0, 1, 0), (0, 0, 1)),
                (0.08, 0.06, (PLATE_Z - top[2]) / 2 + 0.02), ["mtone3", "mtone3", "mtone4", "mtone1", "mtone2", "mtone2"])
    _arm(P_("armup"), PIV_UP, 0.10)
    _arm(P_("armlo"), PIV_LO, 0.12)
    # the hub carrier: an upright between the two ball joints, the hub stub out to the tyre
    k = P_("knuckle")
    em.obox(k, KN, ((1, 0, 0), (0, 1, 0), (0, 0, 1)), (0.12, 0.33, 0.07),
            ["mtone3", "mtone3", "mtone4", "mtone1", "mtone2", "mtone2"])
    mw.oct_tube(k, (KN[0], KN[1], KN[2] - 0.07), (KN[0], KN[1], WH_Z[1] + 0.01), 0.22, 0.20, "m")
    mw.oct_tube(k, (KN[0], KN[1], KN[2] + 0.07), (KN[0], KN[1], SHAFT_T[2]), 0.12, 0.12, "m")
    _quad(k, [(KN[0] - 0.121, KN[1] - 0.24, KN[2] - 0.05), (KN[0] - 0.121, KN[1] - 0.24, KN[2] + 0.05),
              (KN[0] - 0.121, KN[1] + 0.24, KN[2] + 0.05), (KN[0] - 0.121, KN[1] + 0.24, KN[2] - 0.05)],
          KN, "mglow", u=(0, 1, 0))
    _shift(k, KN)
    _shaft(P_("shaft"))
    # a damper: its cylinder down from the top mount, its rod up from the bottom, eyes at both ends
    d = P_("dbody")
    mw.oct_tube(d, (0, 0, 0.04), (0, 0, -0.42), 0.075, 0.075, "m", cap_a="mflat2", cap_b="mflat1")
    mw.oct_tube(d, (-0.05, 0, 0.0), (0.05, 0, 0.0), 0.05, 0.05, "m", cap_a="mpin", cap_b="mpin")
    r = P_("drod")
    mw.oct_tube(r, (0, 0, 0.04), (0, 0, -0.52), 0.038, 0.038, "mtone4", cap_a="mflat2")
    mw.oct_tube(r, (-0.05, 0, 0.0), (0.05, 0, 0.0), 0.045, 0.045, "m", cap_a="mpin", cap_b="mpin")
    # the spring: unit length, squeezed by scaling the part along its axis
    sp = P_("spring")
    turns, n = 5, 40
    pts = [(0.12 * math.cos(2 * math.pi * turns * i / n), 0.12 * math.sin(2 * math.pi * turns * i / n),
            -0.10 - 0.80 * i / n) for i in range(n + 1)]
    for i in range(n):
        mw.oct_tube(sp, pts[i], pts[i + 1], 0.02, 0.02, "mglow", sides=4)
    _tyre(P_("tyre"))
    return parts


# The rest pose the scene stands its nodes in, and what the wheel's script moves them by: one
# function of the travel `s` (metres the hub rises) for everything that moves with the arms.
def arm_angle(s):
    """The arms' swing for a hub rise of s metres: ARM_V turned by phi about X rises by
    R sin(phi - a) - ARM_V.y, with R its length and a its angle under the level."""
    R = math.hypot(ARM_V[1], ARM_V[2])
    a = math.atan2(-ARM_V[1], -ARM_V[2])
    return a + math.asin(max(-0.95, min(0.95, (s + ARM_V[1]) / R)))


em.BLOCKS["marlit_cabin"] = (331, build_marlit_cabin, 512)
em.BLOCKS["marlit_wheel2"] = (337, build_marlit_wheel2, 512)
em.DENSITY["marlit_cabin"] = 36.0
em.DENSITY["marlit_wheel2"] = 34.0

if __name__ == "__main__":
    for nm in (sys.argv[1:] or ["marlit_cabin", "marlit_wheel2"]):
        em.make(nm)
