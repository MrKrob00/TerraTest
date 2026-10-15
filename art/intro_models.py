#!/usr/bin/env python3
"""THE PLANETFALL INTRO'S TWO MODELS (the player's call, after TerraTech's opening): the DROP CAPSULE
that falls burning into a new world, and the WORLDTECH sign it passes in the sky.

    python3 art/intro_models.py [intro_capsule|intro_logo]
        -> objects/<name>_texture.png + art/out/<name>.glb
    godot --headless --path . --script res://art/turret_import.gd -- intro_capsule intro_logo
        -> resources/intro/<part>.tres

Same toolkit, palette and painted light as the blocks (turret_heads.py, emitter_models.py): unshaded,
every facet painted in the tone its normal gets, edge lines for shape.

CAPSULE - TerraTech's drop pod by its PROPORTIONS, our colours (the supports' rule: their shape, not
their cream and red): a square chamfered cap behind, in GSO blue with a white band between two red
lines and a dark vent field with four vanes on its back; under it a PYRAMID turning from the square
into the round body; the body a CYLINDER with a blue seam ring; a blunt scorched dome for a nose.
The first cut was an egg on a neck, and the player turned it down for what it looked like - so the
body is a cylinder and the cap meets it by a pyramid, not a neck. Built about Y with the NOSE DOWN
(-Y): the intro turns -Y along the flight. One part, `intro_capsule`.
  cap 1.52 x 1.52 x 0.55; pyramid 0.5 long; body 1.32 across, 1.25 long; nose 0.5; 2.8 m in all.

LOGO - "WORLD" over "TECH" in chunky square letters standing out of a blue slab with rounded corners,
a badge on the left of TECH (a blue eight-pointed star with a raised white block on it), as
TerraTech's sign lays out "TERRA" / badge + "TECH". The letters are a grid font (stroke two cells of
eight, counters one), their fronts one painted island so no seam shows between the runs they are
built from, with a bevel PAINTED round every outline (lit from the upper left). Faces +Z, centred on
the origin, 11.75 x 6.25 m; the intro scales it. One part, `intro_logo`.
"""
import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import turret_heads as th  # noqa: E402
import emitter_models as em  # noqa: E402

RED = (196, 52, 46)
RED_LO = (140, 36, 34)
SCORCH = [(22, 18, 17), (34, 27, 24), (48, 37, 31), (63, 47, 38), (80, 60, 45), (98, 74, 54)]
LETTER = (206, 212, 222)
LETTER_HI = (240, 244, 250)
LETTER_LO = (128, 134, 150)
WALL = [(96, 102, 118), (120, 126, 142), (148, 154, 170)]

_base_style = th.style_px


def _style(style, x, y, w, h, d):
    if style in ("pod_side", "pod_bevel"):
        # u (x here) runs from the cap's BACK toward the neck: white band at the back between two
        # red lines, blue to the front. The bevels carry the same bands, so they meet on the corners.
        f = (x + 0.5) / max(w, 1)
        if d < 1.0 and style == "pod_side":
            return th.WHITE if f < 0.42 else th.BLUE_HI
        if f < 0.05:
            return th.BLUE_MID
        if f < 0.10:
            return RED if y % 4 else RED_LO
        if f < 0.34:
            return th.jitter(th.WHITE, 2)
        if f < 0.40:
            return RED if y % 4 else RED_LO
        if style == "pod_bevel":
            return th.BLUE_MID
        return th.jitter(th.BLUE, 2)
    if style == "pod_back":
        # the vent field: blue frame, dark well, four vanes pointing in, a hatch in the middle
        if d < 1.0:
            return th.BLUE_HI
        if d < 4.0:
            return th.BLUE_MID if d < 2.0 else th.BLUE
        cx, cy = w / 2.0, h / 2.0
        px, py = x + 0.5 - cx, y + 0.5 - cy
        r = max(abs(px), abs(py))
        if r < w * 0.11:
            return th.METAL[5] if r > w * 0.08 else th.METAL[3]
        a = math.atan2(py, px)
        k = (a / (math.pi / 2)) % 1.0
        vane = abs(k - 0.5) < 0.09 * (1.0 - r / (w * 0.5)) + 0.02
        if vane:
            return th.BLUE_MID if px + py < 0 else th.BLUE_LO
        return th.METAL[1] if (int(px) + int(py)) % 5 else th.METAL[0]
    if style.startswith("pod_m"):
        c = th.METAL[int(style[5:])]
        return th.METAL[min(int(style[5:]) + 1, 6)] if d < 1.0 else th.jitter(c, 1)
    if style == "pod_front":
        if d < 1.0:
            return th.METAL[5]
        return th.jitter(th.METAL[2], 2)
    if style == "logo_wall":
        if d < 1.0:
            return WALL[2]
        return th.jitter(WALL[1], 2)
    if style == "logo_rim":
        return th.BLUE_HI if d < 1.0 else th.BLUE_MID
    if style == "logo_side":
        if d < 1.0:
            return th.BLUE_MID
        return th.jitter(th.BLUE_LO, 2)
    if style == "logo_back":
        return th.jitter(th.BLUE_DEEP, 2)
    if style == "logo_slab":
        if d < 1.0:
            return th.BLUE_HI
        if d < 3.0:
            return th.BLUE_MID
        return th.jitter(th.BLUE, 1)
    return _base_style(style, x, y, w, h, d)


th.style_px = _style


# ── the capsule ─────────────────────────────────────────────────────────────────────────────────

BODY_R = 0.66            # the body: a cylinder (the player: "more cylindrical", not an egg)
BODY_TOP = -0.5          # where the pyramid meets it
BODY_BOT = -1.75         # where the nose begins
SEAM_Y = -1.12
NOSE = 0.75              # the nose: a half sphere squashed this much along the axis
CAP_H = 0.76             # half the cap's width
CAP_LEN = 0.55
CAP_CH = 0.12
SIDES = 16


def _metal_style(n):
    """A painted facet tone for a face of normal n, as lathe_y lights its facets."""
    t = 0.5 + 0.5 * th.dot(th.norm(n), em.LIGHT)
    return "pod_m%d" % int(round(1 + max(0.0, min(1.0, t)) * 5))


def _oct_xz(a, c, y):
    """A square of half-width a with its corners cut by c, round Y at height y (CCW from above)."""
    return [(a, y, -a + c), (a, y, a - c), (a - c, y, a), (-a + c, y, a), (-a, y, a - c), (-a, y, -a + c),
            (-a + c, y, -a), (a - c, y, -a)]


def _loft(f):
    """The PYRAMID from the square cap to the round body (the player's call): a frustum of eight FLAT
    faces from the cap's chamfered square down to a regular octagon round the cylinder (apothem just
    over BODY_R, so the cylinder stands inside it), its underside a narrow ledge."""
    top = _oct_xz(CAP_H - 0.04, CAP_CH, 0.0)
    a = BODY_R + 0.03
    bot = _oct_xz(a, 2 * a / (2 + math.sqrt(2)), BODY_TOP)
    centre = (0.0, BODY_TOP * 0.5, 0.0)
    for i in range(8):
        j = (i + 1) % 8
        pts = th.outward([top[i], top[j], bot[j], bot[i]], centre)
        f.append(th.Face(pts, _metal_style(th.newell(pts)), u_hint=th.sub(top[j], top[i])))
    f.append(th.Face(th.outward(list(bot), (0.0, 0.0, 0.0)), "pod_m1", u_hint=(1, 0, 0)))
    return f


def build_capsule(pk, img):
    f = []
    # the nose: a blunt dome, scorched toward the pole
    nose = [(r, BODY_BOT + (y - BODY_BOT) * NOSE) for r, y in em.sphere_profile(BODY_BOT, BODY_R, -90, 0, 5)]
    em.lathe_y(pk, img, f, nose, th.METAL, sides=SIDES, cell=4,
               ring_ramps={0: SCORCH, 1: SCORCH, 2: SCORCH[1:] + [th.METAL[4]]})
    # the body: a cylinder with a blue seam ring and a rib near each end
    em.lathe_y(pk, img, f, [(BODY_R, BODY_BOT), (BODY_R + 0.03, BODY_BOT + 0.02), (BODY_R + 0.03, BODY_BOT + 0.1),
                            (BODY_R, BODY_BOT + 0.12), (BODY_R, SEAM_Y - 0.05), (BODY_R + 0.03, SEAM_Y - 0.035),
                            (BODY_R + 0.03, SEAM_Y + 0.035), (BODY_R, SEAM_Y + 0.05), (BODY_R, BODY_TOP)],
               th.METAL, sides=SIDES, cell=4, ring_ramps={1: em.BLUE_RAMP, 5: em.BLUE_RAMP})
    _loft(f)
    # the cap: a chamfered box along the axis, its back the vent field
    cap = []
    th.prism(cap, -CAP_H, CAP_H, -CAP_H, CAP_H, 0.0, CAP_LEN, CAP_CH, side="pod_side",
             cap_front="pod_back", cap_back="pod_front")
    for fc in cap:
        if fc.style == "bevel":
            fc.style = "pod_bevel"
        # bands are laid from the back: u runs toward the body
        fc.u_hint = (0, 0, -1) if fc.style in ("pod_side", "pod_bevel") else fc.u_hint
    f += em.along_y(cap)
    return {"intro_capsule": f}


# ── the logo ────────────────────────────────────────────────────────────────────────────────────

U = 0.25                 # one cell of the grid font, metres
LINE = 8                 # cells a letter is tall
SLAB_W = 47 * U
SLAB_H = 25 * U
SLAB_D = 0.5             # slab thickness, front at z 0
RIM = 0.12               # the slab's front chamfer
CORNER = 0.6
LETTER_Z = 0.36          # how far the letters stand out of the slab
BADGE_Z = 0.42
BLOCK_Z = 0.62
LOGO_DENS = 40.0
SHADOW = 0.14             # the letters' painted shadow on the slab, down and right

# rows top to bottom, each a string of the letter's width ('#' filled)
FONT = {
    "W": ["##..##..##", "##..##..##", "##..##..##", "##..##..##", "##..##..##", "##..##..##",
          "##########", "##########"],
    "O": ["#######", "#######", "##...##", "##...##", "##...##", "##...##", "#######", "#######"],
    "R": ["#######", "#######", "##...##", "#######", "#######", "##..##.", "##...##", "##...##"],
    "L": ["##....", "##....", "##....", "##....", "##....", "##....", "######", "######"],
    "D": ["######.", "#######", "##...##", "##...##", "##...##", "##...##", "#######", "######."],
    "T": ["########", "########", "...##...", "...##...", "...##...", "...##...", "...##...", "...##..."],
    "E": ["######", "######", "##....", "#####.", "#####.", "##....", "######", "######"],
    "C": ["######", "######", "##....", "##....", "##....", "##....", "######", "######"],
    "H": ["##...##", "##...##", "##...##", "#######", "#######", "##...##", "##...##", "##...##"],
}
# the W's middle stem is shorter, so the two counters read as a W and not a comb
FONT["W"] = ["##....##", "##....##", "##....##", "##.##.##", "##.##.##", "##.##.##", "########", "########"]


def _cells():
    """Every filled cell of both lines, in grid units: x right, y DOWN from the slab's top edge."""
    cells = set()
    x = 4
    for ch in "WORLD":
        rows = FONT[ch]
        for r, row in enumerate(rows):
            for c, v in enumerate(row):
                if v == "#":
                    cells.add((x + c, 3 + r))
        x += len(rows[0]) + 1
    x = 3 + 11
    for ch in "TECH":
        rows = FONT[ch]
        for r, row in enumerate(rows):
            for c, v in enumerate(row):
                if v == "#":
                    cells.add((x + c, 14 + r))
        x += len(rows[0]) + 1
    return cells


def _w(cx, cy):
    """Grid corner -> slab coordinates (metres, y up, centred)."""
    return (cx * U - SLAB_W / 2, SLAB_H / 2 - cy * U)


BADGE_C = (3 + 4.5, 18.0)       # grid units
BADGE_R = 5.6 * U
BLOCK_R = 2.3 * U


def _star():
    cx, cy = _w(*BADGE_C)
    pts = []
    for i in range(16):
        a = math.pi / 2 + i * math.pi / 8
        r = BADGE_R if i % 2 == 0 else BADGE_R * 0.80
        pts.append((cx + r * math.cos(a), cy + r * math.sin(a)))
    return pts


def _hexagon():
    cx, cy = _w(*BADGE_C)
    return [(cx + BLOCK_R * math.cos(math.pi / 6 + i * math.pi / 3),
             cy + BLOCK_R * math.sin(math.pi / 6 + i * math.pi / 3)) for i in range(6)]


def _in_poly(x, y, poly):
    inside = False
    for i in range(len(poly)):
        x1, y1 = poly[i]
        x2, y2 = poly[(i + 1) % len(poly)]
        if (y1 > y) != (y2 > y) and x < (x2 - x1) * (y - y1) / (y2 - y1) + x1:
            inside = not inside
    return inside


def _rounded_rect(hw, hh, r, seg=4):
    pts = []
    for cx, cy, a0 in ((hw - r, hh - r, 0.0), (-hw + r, hh - r, 90.0), (-hw + r, -hh + r, 180.0),
                       (hw - r, -hh + r, 270.0)):
        for s in range(seg + 1):
            a = math.radians(a0 + 90.0 * s / seg)
            pts.append((cx + r * math.cos(a), cy + r * math.sin(a)))
    return pts


def _island(pk, img, x0, x1, y0, y1, paint):
    """A front island mapped straight onto the slab's xy plane at LOGO_DENS; `paint(px, py)` gives a
    pixel's colour from its pixel coordinates (row 0 = top). Returns the mapping world xy -> uv px."""
    w = int(math.ceil((x1 - x0) * LOGO_DENS))
    h = int(math.ceil((y1 - y0) * LOGO_DENS))
    rx, ry, _, _ = pk.take(w, h)
    for yy in range(-th.PAD, h + th.PAD):
        for xx in range(-th.PAD, w + th.PAD):
            img.putpixel((rx + xx, ry + yy), paint(min(max(xx, 0), w - 1), min(max(yy, 0), h - 1)))
    return lambda x, y: (rx + (x - x0) * LOGO_DENS, ry + (y1 - y) * LOGO_DENS)


def _bevel_tones(mask, depth, hi, mid, lo):
    """A painted bevel round a mask's outline: each pixel's distance in (up to depth) and the side
    the outline lies on, lit from the upper left. Returns a function (px, py) -> tone or None."""
    import numpy as np
    m = np.array(mask, dtype=bool)
    dist = np.full(m.shape, depth + 1, dtype=np.int32)
    cur = m.copy()
    for k in range(depth + 1):
        er = cur.copy()
        er[1:, :] &= cur[:-1, :]
        er[:-1, :] &= cur[1:, :]
        er[:, 1:] &= cur[:, :-1]
        er[:, :-1] &= cur[:, 1:]
        dist[cur & ~er] = k
        cur = er
    gy, gx = np.gradient(dist.astype(np.float32))

    def tone(px, py):
        if not m[py, px]:
            return None
        d = dist[py, px]
        if d > depth:
            return None
        # outward is -gradient; light from the upper left (-x, -y in pixel rows)
        ox, oy = -gx[py, px], -gy[py, px]
        lit = (-ox - oy) / (math.hypot(ox, oy) + 1e-6)
        if d == 0:
            return hi if lit > -0.2 else lo
        return hi if lit > 0.35 else (lo if lit < -0.35 else mid)
    return tone


def build_logo(pk, img):
    f = []
    hw, hh = SLAB_W / 2, SLAB_H / 2
    outer = _rounded_rect(hw, hh, CORNER)
    inner = _rounded_rect(hw - RIM, hh - RIM, CORNER - RIM)
    # slab: front, rim chamfer, sides, back
    # the slab's front is painted as one island: its rim, and the letters' and badge's SHADOW laid on
    # it down and to the right (the bevel's light comes from the upper left), so they stand out of it
    cells = _cells()
    star = _star()
    bcx0, bcy0 = _w(*BADGE_C)

    def paint_slab(px, py):
        x, y = -hw + RIM + (px + 0.5) / LOGO_DENS, hh - RIM - (py + 0.5) / LOGO_DENS
        ex = (hw - RIM) - abs(x)
        ey = (hh - RIM) - abs(y)
        cr = CORNER - RIM
        if ex < cr and ey < cr:
            edge = cr - math.hypot(cr - ex, cr - ey)
        else:
            edge = min(ex, ey)
        if edge * LOGO_DENS < 1.0:
            return th.BLUE_HI
        if edge * LOGO_DENS < 3.0:
            return th.BLUE_MID
        sx, sy = x - SHADOW, y + SHADOW
        gx = (sx + SLAB_W / 2) / U
        gy = (SLAB_H / 2 - sy) / U
        if (int(math.floor(gx)), int(math.floor(gy))) in cells or \
                math.hypot(sx - bcx0, sy - bcy0) < BADGE_R * 0.9:
            return th.jitter(th.BLUE_DEEP, 1)
        return th.jitter(th.BLUE, 1)
    suv0 = _island(pk, img, -hw + RIM, hw - RIM, -hh + RIM, hh - RIM, paint_slab)
    front = th.Face(th.outward([(x, y, 0.0) for x, y in inner], (0, 0, -1)), None)
    front.uv = [suv0(p[0], p[1]) for p in front.pts]
    f.append(front)
    n = len(outer)
    for i in range(n):
        j = (i + 1) % n
        q = [(*outer[i], -RIM), (*outer[j], -RIM), (*inner[j], 0.0), (*inner[i], 0.0)]
        f.append(th.Face(th.outward(q, (0, 0, -0.3)), "logo_rim", u_hint=th.sub(q[1], q[0])))
        q = [(*outer[i], -SLAB_D), (*outer[j], -SLAB_D), (*outer[j], -RIM), (*outer[i], -RIM)]
        f.append(th.Face(th.outward(q, (0, 0, -0.3)), "logo_side", u_hint=th.sub(q[1], q[0])))
    f.append(th.Face(th.outward([(x, y, -SLAB_D) for x, y in outer], (0, 0, 0)), "logo_back", u_hint=(1, 0, 0)))

    # letters: one island for every front, runs of cells as quads on it
    gx0, gx1 = min(c[0] for c in cells), max(c[0] for c in cells) + 1
    gy0, gy1 = min(c[1] for c in cells), max(c[1] for c in cells) + 1
    wx0, wy1 = _w(gx0, gy0)
    wx1, wy0 = _w(gx1, gy1)
    pw = int(math.ceil((wx1 - wx0) * LOGO_DENS))
    ph = int(math.ceil((wy1 - wy0) * LOGO_DENS))
    mask = [[(gx0 + int((px + 0.5) / LOGO_DENS / U), gy0 + int((py + 0.5) / LOGO_DENS / U)) in cells
             for px in range(pw)] for py in range(ph)]
    bev = _bevel_tones(mask, 3, LETTER_HI, LETTER, LETTER_LO)

    def paint_letters(px, py):
        t = bev(px, py)
        if t is not None:
            return t
        return th.jitter(LETTER, 1) if mask[py][px] else WALL[0]
    uv = _island(pk, img, wx0, wx1, wy0, wy1, paint_letters)
    rows = {}
    for (cx, cy) in cells:
        rows.setdefault(cy, []).append(cx)
    for cy, xs in rows.items():
        xs.sort()
        start = prev = xs[0]
        for x in xs[1:] + [None]:
            if x is not None and x == prev + 1:
                prev = x
                continue
            (ax, ay), (bx, by) = _w(start, cy), _w(prev + 1, cy + 1)
            q = [(ax, by, LETTER_Z), (bx, by, LETTER_Z), (bx, ay, LETTER_Z), (ax, ay, LETTER_Z)]
            fc = th.Face(th.outward(q, (0, 0, 0)), None)
            fc.uv = [uv(p[0], p[1]) for p in fc.pts]
            f.append(fc)
            if x is not None:
                start = prev = x
    # letter walls: every outline edge, merged into runs along its row or column
    edges = {}
    for (cx, cy) in cells:
        for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
            if (cx + dx, cy + dy) not in cells:
                edges.setdefault((dx, dy), set()).add((cx, cy))
    for (dx, dy), es in edges.items():
        lines = {}
        for (cx, cy) in es:
            key, along = (cy, cx) if dy != 0 else (cx, cy)
            lines.setdefault(key, []).append(along)
        for key, al in lines.items():
            al.sort()
            runs, s, p = [], al[0], al[0]
            for a in al[1:] + [None]:
                if a is not None and a == p + 1:
                    p = a
                    continue
                runs.append((s, p))
                if a is not None:
                    s = p = a
            for s, p in runs:
                if dy != 0:
                    cy = key
                    yy = cy + (1 if dy > 0 else 0)
                    a2, b2 = _w(s, yy), _w(p + 1, yy)
                    inside = _w(s + 0.5, cy + 0.5)
                else:
                    cx = key
                    xx = cx + (1 if dx > 0 else 0)
                    a2, b2 = _w(xx, s), _w(xx, p + 1)
                    inside = _w(cx + 0.5, s + 0.5)
                q = [(a2[0], a2[1], 0.0), (b2[0], b2[1], 0.0), (b2[0], b2[1], LETTER_Z), (a2[0], a2[1], LETTER_Z)]
                f.append(th.Face(th.outward(q, (inside[0], inside[1], LETTER_Z * 0.5)), "logo_wall",
                                 u_hint=th.sub(q[1], q[0])))

    # the badge: a star, and on it a raised block
    hexa = _hexagon()
    bcx, bcy = _w(*BADGE_C)
    sx0, sx1 = bcx - BADGE_R - 0.02, bcx + BADGE_R + 0.02
    sy0, sy1 = bcy - BADGE_R - 0.02, bcy + BADGE_R + 0.02
    sw = int(math.ceil((sx1 - sx0) * LOGO_DENS))
    sh = int(math.ceil((sy1 - sy0) * LOGO_DENS))
    smask = [[_in_poly(sx0 + (px + 0.5) / LOGO_DENS, sy1 - (py + 0.5) / LOGO_DENS, star) for px in range(sw)]
             for py in range(sh)]
    sbev = _bevel_tones(smask, 3, th.BLUE_HI, th.BLUE_MID, th.BLUE_LO)
    inner_oct = [(bcx + BADGE_R * 0.62 * math.cos(math.pi / 8 + i * math.pi / 4),
                  bcy + BADGE_R * 0.62 * math.sin(math.pi / 8 + i * math.pi / 4)) for i in range(8)]

    def paint_star(px, py):
        t = sbev(px, py)
        if t is not None:
            return t
        x, y = sx0 + (px + 0.5) / LOGO_DENS, sy1 - (py + 0.5) / LOGO_DENS
        if _in_poly(x, y, inner_oct):
            return th.jitter(th.BLUE_LO, 1)
        return th.jitter(th.BLUE, 1)
    suv = _island(pk, img, sx0, sx1, sy0, sy1, paint_star)
    for i in range(len(star)):
        a, b = star[i], star[(i + 1) % len(star)]
        fc = th.Face(th.outward([(bcx, bcy, BADGE_Z), (*a, BADGE_Z), (*b, BADGE_Z)], (bcx, bcy, 0)), None)
        fc.uv = [suv(p[0], p[1]) for p in fc.pts]
        f.append(fc)
        q = [(*a, 0.0), (*b, 0.0), (*b, BADGE_Z), (*a, BADGE_Z)]
        f.append(th.Face(th.outward(q, (bcx, bcy, BADGE_Z * 0.5)), "logo_side", u_hint=th.sub(q[1], q[0])))
    # the block: a hexagon standing out of the star, its front painted as a cube's three faces
    hx0, hx1 = bcx - BLOCK_R - 0.02, bcx + BLOCK_R + 0.02
    hy0, hy1 = bcy - BLOCK_R - 0.02, bcy + BLOCK_R + 0.02
    hw_ = int(math.ceil((hx1 - hx0) * LOGO_DENS))
    hh_ = int(math.ceil((hy1 - hy0) * LOGO_DENS))
    hmask = [[_in_poly(hx0 + (px + 0.5) / LOGO_DENS, hy1 - (py + 0.5) / LOGO_DENS, hexa) for px in range(hw_)]
             for py in range(hh_)]
    hbev = _bevel_tones(hmask, 1, LETTER_HI, LETTER, LETTER_LO)

    def paint_block(px, py):
        if not hmask[py][px]:
            return th.BLUE_LO
        t = hbev(px, py)
        if t is not None:
            return t
        x, y = hx0 + (px + 0.5) / LOGO_DENS - bcx, hy1 - (py + 0.5) / LOGO_DENS - bcy
        # the cube's three faces meet at the middle: top above both lower edges, left and right below
        line = 0.035
        a = math.degrees(math.atan2(y, x)) % 360
        for ed in (90.0, 210.0, 330.0):
            dirx, diry = math.cos(math.radians(ed)), math.sin(math.radians(ed))
            along = x * dirx + y * diry
            if along > 0 and abs(-x * diry + y * dirx) < line:
                return (70, 76, 96)
        if 30 <= a < 150:
            return LETTER_HI
        if 150 <= a < 270:
            return LETTER
        return (162, 168, 186)
    huv = _island(pk, img, hx0, hx1, hy0, hy1, paint_block)
    fc = th.Face(th.outward([(x, y, BLOCK_Z) for x, y in hexa], (bcx, bcy, 0)), None)
    fc.uv = [huv(p[0], p[1]) for p in fc.pts]
    f.append(fc)
    for i in range(6):
        a, b = hexa[i], hexa[(i + 1) % 6]
        q = [(*a, BADGE_Z), (*b, BADGE_Z), (*b, BLOCK_Z), (*a, BLOCK_Z)]
        f.append(th.Face(th.outward(q, (bcx, bcy, BLOCK_Z * 0.8)), "logo_wall", u_hint=th.sub(q[1], q[0])))
    return {"intro_logo": f}


em.BLOCKS["intro_capsule"] = (911, build_capsule, 512)
em.BLOCKS["intro_logo"] = (912, build_logo, 1024)
em.DENSITY["intro_capsule"] = 48.0
em.DENSITY["intro_logo"] = LOGO_DENS

if __name__ == "__main__":
    for nm in (sys.argv[1:] or ["intro_capsule", "intro_logo"]):
        em.make(nm)
