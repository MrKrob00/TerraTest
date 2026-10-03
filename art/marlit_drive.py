#!/usr/bin/env python3
"""MARLIT'S CABIN AND WHEEL, 2x2x2 like every Marlit block (anchored in a corner: x -1.5..0.5,
y -0.5..1.5, z -1.5..0.5). They replace the Falsus cabin and the big wheel the faction drove on as
placeholders.

    python3 art/marlit_drive.py [marlit_cabin|marlit_wheel2]
        -> objects/<name>_texture.png + art/out/<name>.glb
    godot --headless --path . --script res://art/turret_import.gd -- <name> ...
        -> blocks/meshes/<name>_<part>.tres

CABIN - the faction's casting with its front-top edge cut away into a SLOPED CANOPY: three panes
of sea-teal glass in a gunmetal frame, a sunset line under them and a light bar along the brow.
Each side has a glass window following the slope, a door with a porthole and a handle, and hazard
slats along its foot; the front a vented grille between two sunset lamps, a tow hook and slats; the
roof a bolted hatch and a vent strip. THE FRONT AND THE BACK ARE THE FACTION'S WINDOW OPENED: an
intake of louvres framed by the window's bevel, whose upright sides are the headlamps, and a radiator
of fins - a grille, lamps and exhausts laid on as decals "did not belong" (the player). All of it lies on
the block's faces, so it still joins on every face but the slope. The first cut - the canopy on a
plain casting with the faction's window on every side - was "too simple" (the player).
  body - all of it (a cabin moves nothing)

WHEEL - after the Falsus wheel's layout (the player: "a transmission, and the wheel lower, like
Falsus"): a bearing plate on the BACK face, the face it bolts on by (`connect_faces` 2), and from it
a double wishbone - an upper and a lower A-arm - down to a hub carrier, two coil-over dampers with
sunset springs, and a gearbox on the plate driving the hub through a shaft with a boot at each end.
The tyre hangs on them BELOW the block, as the Falsus wheels hang below theirs (their tyre's middle
0.38 m under the block's, its bottom past the block's floor): a wide low-poly tyre with staggered
lugs, an octagonal rim with six spokes and a capped hub on its outer side.
  body - plate, gearbox, arms, dampers, shaft, hub carrier (still)
  tyre - the tyre, rim, spokes and hub, about its own middle (turns about Z)
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
CAB_SILL = 0.45
CAB_BROW = -0.45
CAB_YZ = [(-0.5, -1.5), (CAB_SILL, -1.5), (1.5, CAB_BROW), (1.5, 0.5), (-0.5, 0.5)]
CAB_PANES = (-1.32, -0.86, -0.14, 0.32)
CAB_FRAME = 0.05
CAB_GLASS_IN = 0.10
PROUD = 0.008                         # overlays stand this far off the face they dress


def _slope_point(x, s, lift=0.0):
    y = CAB_SILL + (1.5 - CAB_SILL) * s
    z = -1.5 + (CAB_BROW + 1.5) * s
    n = th.norm((0.0, CAB_BROW + 1.5, -(1.5 - CAB_SILL)))
    return (x + n[0] * lift, y + n[1] * lift, z + n[2] * lift)


def _cab_side(f, x, sx):
    """One side wall at x (sx +1 / -1 outward): a plate over the dressing, a window under the slope,
    a door with a porthole and a handle, hazard slats along the foot."""
    xo = x + sx * PROUD
    inside = (CX, 0.5, -0.5)

    def P(y, z, d=0.0):
        return (xo + sx * d, y, z)
    wall = hm.inset(CAB_YZ, em.MB_C)
    _quad(f, [P(p[0], p[1]) for p in wall], inside, "mplate", u=(0, 0, 1))
    # the window under the slope: a frame, then the glass
    # a quarter metre off the slope along z: the casting's 0.16 chamfer runs along that edge, and a
    # window closer than that hung in the air past the body
    win = [(0.75, -0.95), (1.15, -0.55), (1.15, -0.30), (0.75, -0.30)]
    _quad(f, [P(y + (0.03 if i in (1, 2) else -0.03), z + (-0.03 if i in (0, 1) else 0.03), 0.003)
              for i, (y, z) in enumerate(win)], inside, "mflat1", u=(0, 0, 1))
    _quad(f, [P(y, z, 0.006) for y, z in win], inside, "mglass", u=(0, 0, 1))
    # the door behind it, a porthole and a handle
    _quad(f, [P(-0.25, -0.18, 0.003), P(-0.25, 0.36, 0.003), P(1.18, 0.36, 0.003), P(1.18, -0.18, 0.003)],
          inside, "mflat1", u=(0, 0, 1))
    _quad(f, [P(-0.21, -0.14, 0.006), P(-0.21, 0.32, 0.006), P(1.14, 0.32, 0.006), P(1.14, -0.14, 0.006)],
          inside, "mpside", u=(0, 0, 1))
    _oct_on(f, P(0.86, 0.09, 0.009), (0, 0, 1), (0, 1, 0), 0.15, "mflat1", inside)
    _oct_on(f, P(0.86, 0.09, 0.012), (0, 0, 1), (0, 1, 0), 0.11, "mglass", inside)
    _quad(f, [P(0.36, -0.09, 0.012), P(0.36, 0.05, 0.012), P(0.44, 0.05, 0.012), P(0.44, -0.09, 0.012)],
          inside, "mglow", u=(0, 0, 1))
    # hazard slats along the foot
    _quad(f, [P(-0.40, -1.32, 0.004), P(-0.40, 0.32, 0.004), P(-0.28, 0.32, 0.004), P(-0.28, -1.32, 0.004)],
          inside, "mhazard", u=(0, 0, 1))


def _cab_prism(f, q, x0, x1, rnd, special):
    """`emitter_models.marlit_prism`, except that a swept face named in `special` (by the z both its
    edges stand at: the front -1.5, the back 0.5) is handed to its own function instead of the
    faction's window: there the window IS the grille or the radiator, built into the casting."""
    c = em.MB_C
    qc, kind = hm.chamfered_profile(q, c)
    wall = hm.inset(q, c)
    n = len(qc)
    xa, xb = x0 + c, x1 - c
    cy = sum(p[0] for p in q) / len(q)
    cz = sum(p[1] for p in q) / len(q)
    centre = ((x0 + x1) / 2, cy, cz)
    for i in range(n):
        a, b = qc[i], qc[(i + 1) % n]
        pts = th.outward([(xa, a[0], a[1]), (xb, a[0], a[1]), (xb, b[0], b[1]), (xa, b[0], b[1])], centre)
        if kind[i] == "chamfer":
            f.append(th.Face(pts, "medge", u_hint=(1, 0, 0)))
            continue
        key = round(a[1], 3) if abs(a[1] - b[1]) < 1e-6 else None
        if key in special:
            special[key](f, pts, rnd)
        else:
            em.marlit_poly(f, pts, rnd)
    nq = len(q)
    for xw, xf in ((x0, xa), (x1, xb)):
        em.marlit_poly(f, th.outward([(xw, p[0], p[1]) for p in wall], centre), rnd)
        for j in range(nq):
            fa, fb = qc[2 * j + 1], qc[(2 * j + 2) % n]
            wa, wb = wall[j], wall[(j + 1) % nq]
            st = [(xf, fa[0], fa[1]), (xf, fb[0], fb[1]), (xw, wb[0], wb[1]), (xw, wa[0], wa[1])]
            f.append(th.Face(th.outward(st, centre), "medge", u_hint=th.sub(st[1], st[0])))
            ca, cb = qc[(2 * j + 2) % n], qc[(2 * j + 3) % n]
            wv = wall[(j + 1) % nq]
            tri = [(xf, ca[0], ca[1]), (xf, cb[0], cb[1]), (xw, wv[0], wv[1])]
            f.append(th.Face(th.outward(tri, centre), "medge", u_hint=th.sub(tri[1], tri[0])))


def _window_open(f, pts, rnd, louvres, lamps):
    """The faction's window on this face, OPEN (`marlit_poly(floor=False)`): its bevel and sunset line
    frame a dark well filled with louvres - horizontal (the front's intake) or upright (the back's
    radiator fins). `lamps` turns the window's two upright side bevels into headlamp lenses, so the
    lights are part of the frame rather than stuck on beside it."""
    start = len(f)
    ring, d2 = em.marlit_poly(f, pts, rnd, floor=False)
    cen = th.mul(tuple(map(sum, zip(*pts))), 1.0 / len(pts))
    n = th.norm(th.newell(pts))
    u = th.norm(th.sub(pts[1], pts[0]))
    v = th.norm(th.cross(n, u))
    if abs(u[1]) > abs(u[0]):             # work in world axes: a across (x), b up (y)
        u, v = v, u
    if u[0] < 0:
        u = th.mul(u, -1.0)
    if v[1] < 0:
        v = th.mul(v, -1.0)
    ring = [(th.dot(th.sub(p, cen), u), th.dot(th.sub(p, cen), v))
            for p in [th.add(cen, th.add(th.mul(th.norm(th.sub(pts[1], pts[0])), x),
                                         th.mul(th.norm(th.cross(n, th.norm(th.sub(pts[1], pts[0])))), y)))
                      for x, y in ring]]

    def P(x, y, d):
        return th.add(cen, th.add(th.add(th.mul(u, x), th.mul(v, y)), th.mul(n, -d)))
    inside = th.add(cen, th.mul(n, -1.0))
    if lamps:
        for face in f[start:]:
            if face.style.startswith("mbev"):
                nn = th.norm(th.newell(face.pts))
                if abs(nn[0]) > 0.3:          # the upright sides and the four corner facets: lamp clusters
                    face.style = "mlamp"
    floor = d2 + 0.08
    mw._face(f, [P(x, y, floor) for x, y in ring], th.add(cen, th.mul(n, -2.0)), "mflat0", u_hint=u)

    def span(t, along_y):
        """Where a line at t (a height, or an x) crosses the ring: its two ends."""
        hits = []
        for i in range(len(ring)):
            a, b = ring[i], ring[(i + 1) % len(ring)]
            ka, kb = (a[1], b[1]) if along_y else (a[0], b[0])
            if (ka - t) * (kb - t) <= 0 and abs(kb - ka) > 1e-9:
                s2 = (t - ka) / (kb - ka)
                hits.append(a[0] + (b[0] - a[0]) * s2 if along_y else a[1] + (b[1] - a[1]) * s2)
        return (min(hits), max(hits)) if len(hits) >= 2 else None
    ys = [p[1] for p in ring]
    xs = [p[0] for p in ring]
    if louvres == "h":
        lo, hi = min(ys), max(ys)
        k = 6
        for i in range(k):
            y = lo + (hi - lo) * (i + 0.6) / (k + 0.2)
            sp = span(y, True)
            if sp is None:
                continue
            x0, x1 = sp[0] + 0.01, sp[1] - 0.01
            # a slat tipped down toward the front: its lit top, then its dark lip
            mw._face(f, [P(x0, y, d2 + 0.01), P(x1, y, d2 + 0.01), P(x1, y - 0.06, floor - 0.01),
                         P(x0, y - 0.06, floor - 0.01)], inside, "mbev3", u_hint=u)
            mw._face(f, [P(x0, y, d2 + 0.01), P(x1, y, d2 + 0.01), P(x1, y - 0.012, d2 + 0.01),
                         P(x0, y - 0.012, d2 + 0.01)], inside, "mbev4", u_hint=u)
    else:
        lo, hi = min(xs), max(xs)
        k = 9
        for i in range(k):
            x = lo + (hi - lo) * (i + 0.6) / (k + 0.2)
            sp = span(x, False)
            if sp is None:
                continue
            y0, y1 = sp[0] + 0.01, sp[1] - 0.01
            # a radiator fin, edge on to the back: two faces and a lit edge
            for dx, st in ((-0.018, "mbev2"), (0.018, "mbev3")):
                mw._face(f, [P(x, y0, d2 + 0.005), P(x, y1, d2 + 0.005), P(x + dx, y1, floor - 0.01),
                             P(x + dx, y0, floor - 0.01)], inside, st, u_hint=v)
            mw._face(f, [P(x - 0.006, y0, d2 + 0.004), P(x + 0.006, y0, d2 + 0.004), P(x + 0.006, y1, d2 + 0.004),
                         P(x - 0.006, y1, d2 + 0.004)], inside, "mbev4", u_hint=v)


def build_marlit_cabin(pk, img):
    import random as _r
    rnd = _r.Random(57)
    parts = {"marlit_cabin_body": []}
    f = parts["marlit_cabin_body"]
    # THE FRONT AND THE BACK ARE THE FACTION'S WINDOW ITSELF, OPENED: the intake and its lamps on the
    # front, the radiator on the back. Decals of a grille, lamps and exhausts laid over the window
    # "did not belong" (the player) - two styles on one face.
    _cab_prism(f, CAB_YZ, -1.5, 0.5, rnd, {
        -1.5: lambda ff, pts, r: _window_open(ff, pts, r, "h", True),
        0.5: lambda ff, pts, r: _window_open(ff, pts, r, "v", False)})
    inside = (CX, 0.3, -0.4)
    # the canopy: three panes in a gunmetal frame, a sunset line under them
    span = math.hypot(1.5 - CAB_SILL, CAB_BROW + 1.5)
    s0, s1 = CAB_GLASS_IN / span, 1.0 - CAB_GLASS_IN / span
    xs = CAB_PANES
    frame = [_slope_point(xs[0] - CAB_FRAME, s0 - 0.03, 0.010), _slope_point(xs[-1] + CAB_FRAME, s0 - 0.03, 0.010),
             _slope_point(xs[-1] + CAB_FRAME, s1 + 0.03, 0.010), _slope_point(xs[0] - CAB_FRAME, s1 + 0.03, 0.010)]
    _quad(f, frame, inside, "mflat1")
    for i in range(len(xs) - 1):
        a = xs[i] + (CAB_FRAME if i > 0 else 0.0)
        b = xs[i + 1] - (CAB_FRAME if i < len(xs) - 2 else 0.0)
        _quad(f, [_slope_point(a, s0, 0.018), _slope_point(b, s0, 0.018), _slope_point(b, s1, 0.018),
                  _slope_point(a, s1, 0.018)], inside, "mglass")
    _quad(f, [_slope_point(xs[0], s0 - 0.055, 0.016), _slope_point(xs[-1], s0 - 0.055, 0.016),
              _slope_point(xs[-1], s0 - 0.035, 0.016), _slope_point(xs[0], s0 - 0.035, 0.016)], inside, "mglow")
    # a light bar along the brow, on the roof
    yt = 1.5 + PROUD
    _quad(f, [(-1.34, yt, CAB_BROW + 0.04), (0.34, yt, CAB_BROW + 0.04), (0.34, yt, CAB_BROW + 0.20),
              (-1.34, yt, CAB_BROW + 0.20)], inside, "mflat1")
    for k in range(5):
        x0 = -1.28 + k * 0.33
        _quad(f, [(x0, yt + 0.004, CAB_BROW + 0.07), (x0 + 0.24, yt + 0.004, CAB_BROW + 0.07),
                  (x0 + 0.24, yt + 0.004, CAB_BROW + 0.17), (x0, yt + 0.004, CAB_BROW + 0.17)], inside, "mglow")
    # the roof: a bolted hatch and a vent strip
    _oct_on(f, (-0.5, yt, 0.06), (1, 0, 0), (0, 0, 1), 0.30, "mflat1", inside)
    _oct_on(f, (-0.5, yt + 0.004, 0.06), (1, 0, 0), (0, 0, 1), 0.25, "mpside", inside)
    for i in range(4):
        a = math.pi / 4 + i * math.pi / 2
        c = (-0.5 + math.cos(a) * 0.19, yt + 0.008, 0.06 + math.sin(a) * 0.19)
        _quad(f, [th.add(c, (-0.035, 0, -0.035)), th.add(c, (0.035, 0, -0.035)), th.add(c, (0.035, 0, 0.035)),
                  th.add(c, (-0.035, 0, 0.035))], inside, "mbolt")
    _quad(f, [(-1.3, yt, 0.24), (-0.95, yt, 0.24), (-0.95, yt, 0.36), (-1.3, yt, 0.36)], inside, "mvent")
    _quad(f, [(-0.05, yt, 0.24), (0.3, yt, 0.24), (0.3, yt, 0.36), (-0.05, yt, 0.36)], inside, "mvent")
    # the sides
    _cab_side(f, -1.5, -1.0)
    _cab_side(f, 0.5, 1.0)
    return parts


# ── the wheel ───────────────────────────────────────────────────────────────────────────────────
TC = (-0.5, -0.25, -0.86)    # the tyre's middle: under the block, as the Falsus wheels hang
WH_R = 0.85                  # the tyre's radius over the lugs
WH_TREAD = 0.79
WH_SIDE_IN = 0.50
WH_Z = (-1.45, -0.30)        # the tyre's outer and inner faces (the outer side looks along -Z)
WH_N = 16
WH_HUB = 0.18
PLATE_Z = 0.30               # the bearing plate's front face


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
        centre = (C[0], C[1], z0 + (1.0 if z1 > z0 else -1.0)) if abs(z1 - z0) < 1e-6 and r0 != r1 else mid
        if abs(z1 - z0) < 1e-6:
            centre = (C[0], C[1], z0 + (0.3 if z0 > C[2] else -0.3) * -1.0)
        mw._face(f, q, centre, style, u_hint=th.sub(q[1], q[0]))


def _coil(f, a, b, r, turns, wire):
    """A coil spring from a to b, `turns` round, its wire a four-sided tube in sunset."""
    ax, u, v = mw._frame(th.sub(b, a))
    n = turns * 8
    pts = []
    for i in range(n + 1):
        t = i / n
        ang = 2 * math.pi * turns * t
        pts.append(th.add(th.add(a, th.mul(th.sub(b, a), t)),
                          th.add(th.mul(u, r * math.cos(ang)), th.mul(v, r * math.sin(ang)))))
    for i in range(n):
        mw.oct_tube(f, pts[i], pts[i + 1], wire, wire, "mglow", sides=4)


def _damper(f, top, bottom):
    """A coil-over: a fat body up top, a thin rod down, a sunset spring round both, eyes at the ends."""
    mid = th.add(top, th.mul(th.sub(bottom, top), 0.55))
    mw.oct_tube(f, top, mid, 0.075, 0.075, "m", cap_a="mflat2")
    mw.oct_tube(f, mid, bottom, 0.04, 0.04, "m", cap_b="mflat2")
    _coil(f, th.add(top, th.mul(th.sub(bottom, top), 0.12)), th.add(top, th.mul(th.sub(bottom, top), 0.88)),
          0.12, 4, 0.018)


def build_marlit_wheel2(pk, img):
    import random as _r
    rnd = _r.Random(73)
    parts = {"marlit_wheel2_body": [], "marlit_wheel2_tyre": []}
    b = parts["marlit_wheel2_body"]
    # the bearing plate on the back face, the faction's window on its front
    em.marlit_box(b, (-1.38, -0.12, PLATE_Z), (0.38, 1.38, 0.5), 0.06, rnd, {(2, 0): "window"})
    # the gearbox on the plate, vented, its output boot
    gb = ((-0.86, 0.26, 0.12), (-0.14, 0.78, PLATE_Z))
    mw.mbox(b, gb[0], gb[1])
    _quad(b, [(-0.80, 0.32, 0.12 - 0.004), (-0.20, 0.32, 0.12 - 0.004), (-0.20, 0.72, 0.12 - 0.004),
              (-0.80, 0.72, 0.12 - 0.004)], (-0.5, 0.5, 0.2), "mvent")
    hub_in = (TC[0], TC[1], WH_Z[1] + 0.06)                  # the hub carrier's inner face
    knuckle = (TC[0], TC[1], WH_Z[1] + 0.10)
    out = (-0.5, 0.30, 0.10)
    mw.oct_tube(b, (out[0], out[1], 0.12), out, 0.11, 0.11, "m")
    # the drive shaft, a boot at each end
    shaft_a = th.add(out, (0, 0, -0.08))
    shaft_b = th.add(knuckle, (0, 0, 0.10))
    mw.oct_tube(b, out, shaft_a, 0.10, 0.07, "mtone1")
    mw.oct_tube(b, shaft_a, shaft_b, 0.05, 0.05, "m")
    mw.oct_tube(b, shaft_b, th.add(knuckle, (0, 0, 0.02)), 0.07, 0.10, "mtone1")
    # the hub carrier
    em.obox(b, knuckle, ((1, 0, 0), (0, 1, 0), (0, 0, 1)), (0.16, 0.30, 0.06),
            ["mtone3", "mtone3", "mtone4", "mtone1", "mtone2", "mtone2"])
    mw.oct_tube(b, th.add(knuckle, (0, 0, -0.06)), hub_in, 0.20, 0.20, "m")
    # the double wishbone: an upper and a lower A-arm, each two keeled plates from the plate to the
    # carrier, with pins at the plate
    for y_plate, y_knuckle, w in ((1.02, TC[1] + 0.26, 0.11), (0.06, TC[1] - 0.26, 0.13)):
        apex = (TC[0], y_knuckle, knuckle[2] + 0.04)
        for x_plate in (-1.06, 0.06):
            a = (x_plate, y_plate, PLATE_Z - 0.02)
            em._mwl_plate(b, a, apex, (0.0, 1.0, 0.0), w, w * 0.8, w * 0.8, w * 0.7)
            em._mwl_oct_prism(b, (x_plate, y_plate, PLATE_Z - 0.04), (1.0, 0.0, 0.0), 0.05, 0.08, None, "mpin")
    # two coil-over dampers from high on the plate to the lower arms
    for xs in (-1.15, 0.15):
        top = (xs, 1.24, PLATE_Z - 0.06)
        bot = (TC[0] + (xs - TC[0]) * 0.45, TC[1] - 0.10, knuckle[2] + 0.30)
        _damper(b, top, bot)
    # the tyre, about its own middle (the scene's tyre node stands at TC)
    t = parts["marlit_wheel2_tyre"]
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
    return parts


em.BLOCKS["marlit_cabin"] = (331, build_marlit_cabin, 512)
em.BLOCKS["marlit_wheel2"] = (337, build_marlit_wheel2, 512)
em.DENSITY["marlit_cabin"] = 36.0
em.DENSITY["marlit_wheel2"] = 34.0

if __name__ == "__main__":
    for nm in (sys.argv[1:] or ["marlit_cabin", "marlit_wheel2"]):
        em.make(nm)
