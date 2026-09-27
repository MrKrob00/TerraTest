#!/usr/bin/env python3
"""Builds the mortar's swinging head: geometry, its own texture, and a .glb an artist can open.

    python3 art/mortar_model.py        -> objects/mortar_texture.png + art/out/mortar.glb

Only the HEAD is new. The platform and the turning neck are the ones the gun, the rocket launcher
and the laser already stand on (Assets.glb `base` / `rocketgun_head`), so a mortar reads as one of
the family and the turret chain in WeaponBlock finds its parts the same way. The head's origin is
the neck's pitch axis: the tip of the dark arm, 0.42 m over the platform, 0.28 m behind the centre.

WHAT THE GAME SAYS THE MORTAR IS, and so what the model has to say:
  - EIGHT SHELLS A SALVO, all at once (mortar.gd SHELLS) -> eight tubes, 4 x 2, every mouth visible
    from the front, so the salvo can be counted on the model;
  - AIMED BY THE HULL, the barrel only trims 18 deg -> no turret drum, a pack on trunnions;
  - THROWS AT 30-60 DEG -> short fat tubes on a pack that sits OVER the pivot, so it can swing up
    without burying its tail in the neck (checked at 60 deg against the neck's collar).

STYLE is the atlas's, not a new one. The blocks are UNSHADED, so every bit of shape is painted:
the palette is sampled from Assets_main_texture_new.png (GSO blue, gunmetal, orange trim), each
face gets its own pixels at the atlas's density (~48 px/m) with the light bevel line along its
edges that the other models carry, and the chamfer strips are painted as lit lips. Faces facing
down are darkened a little and the tubes carry a top-lit ramp around their eight sides, because
with no lighting that is the only way a cylinder reads as round.

Why a texture of its own and not a corner of the shared atlas: the atlas is the artist's export,
and the next export would paint over anything added to it here.
"""
import json
import math
import os
import random
import struct
import sys

try:
    from PIL import Image
except ImportError:
    sys.exit("needs Pillow: pip install pillow")

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT_GLB = os.path.join(ROOT, "art", "out", "mortar.glb")   # .gdignore: for Blender, never imported
OUT_PNG = os.path.join(ROOT, "objects", "mortar_texture.png")

TEX = 256           # texture side, px
DENS = 48.0         # px per metre - the atlas's own density
PAD = 2             # px of bleed round every island (mipmaps and 4x4 VRAM blocks)
random.seed(7)

# Palette, sampled from the atlas.
BLUE = (76, 106, 177)
BLUE_HI = (110, 152, 217)
BLUE_MID = (97, 129, 197)
BLUE_LO = (57, 71, 110)
BLUE_DEEP = (45, 58, 96)
METAL = [(19, 18, 23), (31, 29, 34), (42, 40, 50), (50, 48, 59), (61, 59, 70), (75, 70, 87), (92, 88, 106)]
RIM = [(61, 59, 70), (75, 70, 87), (97, 94, 112), (120, 116, 135), (150, 146, 166)]
ORANGE = (212, 144, 56)
ORANGE_LO = (150, 96, 38)
WHITE = (213, 210, 222)


# ── geometry ────────────────────────────────────────────────────────────────────────────────────

class Face:
    def __init__(self, pts, style, u_hint=None, group=None, uv=None):
        self.pts = pts            # planar convex polygon, 3D
        self.style = style
        self.u_hint = u_hint      # direction the texture's u runs along
        self.group = group        # faces sharing one painted island (tube walls)
        self.uv = uv              # fixed UVs in a shared island


def sub(a, b): return (a[0] - b[0], a[1] - b[1], a[2] - b[2])
def add(a, b): return (a[0] + b[0], a[1] + b[1], a[2] + b[2])
def mul(a, s): return (a[0] * s, a[1] * s, a[2] * s)
def dot(a, b): return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]
def cross(a, b): return (a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0])
def norm(a):
    l = math.sqrt(dot(a, a)) or 1.0
    return (a[0] / l, a[1] / l, a[2] / l)


def newell(pts):
    n = [0.0, 0.0, 0.0]
    for i, p in enumerate(pts):
        q = pts[(i + 1) % len(pts)]
        n[0] += (p[1] - q[1]) * (p[2] + q[2])
        n[1] += (p[2] - q[2]) * (p[0] + q[0])
        n[2] += (p[0] - q[0]) * (p[1] + q[1])
    return norm(tuple(n))


def outward(pts, centre):
    """Wind the polygon CCW seen from outside (glTF front face)."""
    c = mul(tuple(map(sum, zip(*pts))), 1.0 / len(pts))
    if dot(newell(pts), sub(c, centre)) < 0:
        pts = list(reversed(pts))
    return pts


def octagon(x0, x1, y0, y1, c):
    """Chamfered rectangle in XY, CCW seen from +Z. Returns (points, is_chamfer per edge)."""
    p = [(x0 + c, y0), (x1 - c, y0), (x1, y0 + c), (x1, y1 - c),
         (x1 - c, y1), (x0 + c, y1), (x0, y1 - c), (x0, y0 + c)]
    return p, [False, True, False, True, False, True, False, True]


def prism(faces, x0, x1, y0, y1, z_back, z_front, c, side="blue", cap_front="blue", cap_back="blue",
          top_style=None):
    """Chamfered box along Z. Long edges chamfered by c, caps flat."""
    oct_, ch = octagon(x0, x1, y0, y1, c)
    centre = ((x0 + x1) / 2, (y0 + y1) / 2, (z_back + z_front) / 2)
    for i in range(8):
        a, b = oct_[i], oct_[(i + 1) % 8]
        q = [(a[0], a[1], z_back), (b[0], b[1], z_back), (b[0], b[1], z_front), (a[0], a[1], z_front)]
        st = "bevel" if ch[i] else side
        if top_style and i == 4:
            st = top_style
        faces.append(Face(outward(q, centre), st, u_hint=(0, 0, -1)))
    if cap_front:
        faces.append(Face(outward([(p[0], p[1], z_front) for p in oct_], centre), cap_front, u_hint=(1, 0, 0)))
    if cap_back:
        faces.append(Face(outward([(p[0], p[1], z_back) for p in oct_], centre), cap_back, u_hint=(1, 0, 0)))


def box(faces, lo, hi, style, skip=()):
    x0, y0, z0 = lo
    x1, y1, z1 = hi
    centre = ((x0 + x1) / 2, (y0 + y1) / 2, (z0 + z1) / 2)
    quads = {
        "+x": [(x1, y0, z0), (x1, y1, z0), (x1, y1, z1), (x1, y0, z1)],
        "-x": [(x0, y0, z0), (x0, y0, z1), (x0, y1, z1), (x0, y1, z0)],
        "+y": [(x0, y1, z0), (x0, y1, z1), (x1, y1, z1), (x1, y1, z0)],
        "-y": [(x0, y0, z0), (x1, y0, z0), (x1, y0, z1), (x0, y0, z1)],
        "+z": [(x0, y0, z1), (x1, y0, z1), (x1, y1, z1), (x0, y1, z1)],
        "-z": [(x0, y0, z0), (x0, y1, z0), (x1, y1, z0), (x1, y0, z0)],
    }
    for k, q in quads.items():
        if k in skip:
            continue
        faces.append(Face(outward(q, centre), style, u_hint=(0, 0, -1) if k[1] in "xy" else (1, 0, 0)))


# Tube islands: all eight tubes share them, so they are fixed rectangles laid out first.
TUBE_R = 0.068        # outer circumradius
TUBE_IN = 0.050       # bore
TUBE_SIDES = 8
BORE_DEPTH = 0.08

ISLANDS = {}          # name -> (x, y, w, h) in px, reserved before packing


def tube(faces, cx, cy, z_back, z_mouth):
    n = TUBE_SIDES
    ang = [math.pi / 2 + (i + 0.5) * 2 * math.pi / n for i in range(n)]   # a flat on top
    ring = lambda r, z: [(cx + r * math.cos(a), cy + r * math.sin(a), z) for a in ang]
    o_b, o_m = ring(TUBE_R, z_back), ring(TUBE_R, z_mouth)
    i_m, i_d = ring(TUBE_IN, z_mouth), ring(TUBE_IN, z_mouth + BORE_DEPTH)
    axis_c = (cx, cy, (z_back + z_mouth) / 2)
    wx, wy, ww, wh = ISLANDS["wall"]
    rx, ry, rw, rh = ISLANDS["rim"]
    bx, by, bw, bh = ISLANDS["bore"]
    for i in range(n):
        j = (i + 1) % n
        # Outer wall: column i of the wall island, v along the length.
        u0, u1 = wx + ww * i / n, wx + ww * (i + 1) / n
        q = [o_b[i], o_b[j], o_m[j], o_m[i]]
        uv = [(u0, wy), (u1, wy), (u1, wy + wh), (u0, wy + wh)]
        faces.append(fixed(q, uv, axis_c, outward_sign=+1))
        # Mouth rim (annulus), column i of the rim island.
        u0, u1 = rx + rw * i / n, rx + rw * (i + 1) / n
        q = [o_m[i], o_m[j], i_m[j], i_m[i]]
        uv = [(u0, ry), (u1, ry), (u1, ry + rh), (u0, ry + rh)]
        faces.append(fixed(q, uv, (cx, cy, z_mouth + 1.0), outward_sign=+1))
        # Bore wall, seen from inside.
        u0, u1 = bx + bw * i / n, bx + bw * (i + 1) / n
        q = [i_m[i], i_m[j], i_d[j], i_d[i]]
        uv = [(u0, by), (u1, by), (u1, by + bh), (u0, by + bh)]
        faces.append(fixed(q, uv, (cx, cy, z_mouth), outward_sign=-1))
    # Bore bottom.
    cx0, cy0, cw, chh = ISLANDS["bottom"]
    uv = [(cx0 + cw / 2 + cw / 2 * math.cos(a), cy0 + chh / 2 + chh / 2 * math.sin(a)) for a in ang]
    faces.append(fixed(i_d, uv, (cx, cy, z_mouth - 1.0), outward_sign=+1))


def fixed(pts, uv, ref, outward_sign):
    """A face with UVs in a shared island; wound so its normal points away from (or toward) ref."""
    c = mul(tuple(map(sum, zip(*pts))), 1.0 / len(pts))
    if dot(newell(pts), sub(c, ref)) * outward_sign < 0:
        pts, uv = list(reversed(pts)), list(reversed(uv))
    f = Face(pts, None)
    f.uv = uv
    return f


def build():
    faces = []
    # Tubes: 4 x 2, a flat on top, row centres over the pivot so the pack clears the neck's arm.
    cols = [-0.225, -0.075, 0.075, 0.225]
    rows = [0.165, 0.315]
    for y in rows:
        for x in cols:
            tube(faces, x, y, 0.03, -0.62)
    # Breech housing, behind the tubes. Top panel carries the forward arrow.
    # Its rear-bottom edge is what meets the neck's collar at 60 deg: at z 0.15 / y 0.055 it clears
    # the collar's back edge by ~7 cm (it touched at 0.20 / 0.035).
    prism(faces, -0.34, 0.34, 0.055, 0.425, 0.15, -0.04, 0.045,
          cap_front="blue", cap_back="grille", top_style="blue_arrow")
    # Two bands holding the cluster; the front one carries the orange trim of the platform.
    prism(faces, -0.315, 0.315, 0.08, 0.40, -0.22, -0.30, 0.03)
    prism(faces, -0.315, 0.315, 0.08, 0.40, -0.44, -0.51, 0.03, side="stripe")
    # Clevis round the neck's arm tip (x +-0.09): two gunmetal cheeks and the trunnion between.
    for s in (-1, 1):
        box(faces, (s * 0.10 if s > 0 else -0.15, -0.075, -0.07),
            (0.15 if s > 0 else -0.10, 0.065, 0.11), "dark")
    prism_x(faces, -0.18, 0.18, 0.0, 0.0, 0.045)
    return faces


def prism_x(faces, x0, x1, cy, cz, r):
    """Trunnion: an octagonal rod along X."""
    n = 8
    ang = [(i + 0.5) * 2 * math.pi / n for i in range(n)]
    a_ = [(x0, cy + r * math.sin(a), cz + r * math.cos(a)) for a in ang]
    b_ = [(x1, cy + r * math.sin(a), cz + r * math.cos(a)) for a in ang]
    centre = ((x0 + x1) / 2, cy, cz)
    for i in range(n):
        j = (i + 1) % n
        faces.append(Face(outward([a_[i], a_[j], b_[j], b_[i]], centre), "metal_rod", u_hint=(1, 0, 0)))
    faces.append(Face(outward(list(a_), centre), "cap_bolt", u_hint=(0, 0, 1)))
    faces.append(Face(outward(list(b_), centre), "cap_bolt", u_hint=(0, 0, 1)))


# ── texture ─────────────────────────────────────────────────────────────────────────────────────

class Packer:
    """Shelf packer on a 4-px grid, so no VRAM block straddles two islands."""
    def __init__(self, size):
        self.size, self.x, self.y, self.row_h = size, 0, 0, 0

    def take(self, w, h):
        w4, h4 = (w + 2 * PAD + 3) // 4 * 4, (h + 2 * PAD + 3) // 4 * 4
        if self.x + w4 > self.size:
            self.x, self.y, self.row_h = 0, self.y + self.row_h, 0
        if self.y + h4 > self.size:
            raise RuntimeError("texture full")
        r = (self.x + PAD, self.y + PAD, w, h)
        self.x += w4
        self.row_h = max(self.row_h, h4)
        return r


def shade(c, k):
    return tuple(max(0, min(255, int(round(v * k)))) for v in c)


def jitter(c, amt=3):
    j = random.randint(-amt, amt)
    return tuple(max(0, min(255, v + j)) for v in c)


def dist_to_edges(px, py, poly):
    best = 1e9
    for i, a in enumerate(poly):
        b = poly[(i + 1) % len(poly)]
        ex, ey = b[0] - a[0], b[1] - a[1]
        l2 = ex * ex + ey * ey or 1e-9
        t = max(0.0, min(1.0, ((px - a[0]) * ex + (py - a[1]) * ey) / l2))
        dx, dy = px - (a[0] + ex * t), py - (a[1] + ey * t)
        best = min(best, math.hypot(dx, dy))
    return best


def paint_face(img, rect, poly2d, style, facing):
    x0, y0, w, h = rect
    # Faces looking down are in the machine's own shadow; the top catches the sky.
    k = 1.0 + 0.06 * max(facing, 0.0) - 0.22 * max(-facing, 0.0)
    for yy in range(-PAD, h + PAD):
        for xx in range(-PAD, w + PAD):
            px, py = xx + 0.5, yy + 0.5
            d = dist_to_edges(min(max(px, 0), w), min(max(py, 0), h), poly2d)
            img.putpixel((x0 + xx, y0 + yy), shade(style_px(style, xx, yy, w, h, d), k))


def style_px(style, x, y, w, h, d):
    if style in ("blue", "blue_arrow", "stripe"):
        # A face only a few texels across keeps ONE light line: the full two-texel lip on all
        # sides turned the bands into solid highlight and the whole pack read paler than the gun.
        thin = min(w, h) < 7
        if d < 1.0:
            return BLUE_HI if not thin or y == 0 else BLUE
        if d < 2.0 and not thin:
            return BLUE_MID
        if style == "stripe" and 3 <= y < h - 3 and 4 <= x < w - 4:
            # Hazard trim, the platform's orange on dark.
            return ORANGE if ((x + y) // 3) % 2 == 0 else METAL[2]
        if style == "blue_arrow":
            # The small white arrow the neck carries, pointing FORWARD (+u runs along -Z).
            tip = w * 0.5 + 3
            ax = tip - (x + 0.5)
            if 0 <= ax <= 5 and abs(y + 0.5 - h / 2) <= ax * 0.7 + 0.2:
                return WHITE
        # Rivets in the corners of anything big enough to hold them.
        if w >= 12 and h >= 10:
            for rx, ry in ((3, 3), (w - 4, 3), (3, h - 4), (w - 4, h - 4)):
                if x == rx and y == ry:
                    return BLUE_DEEP
                if x == rx + 1 and y == ry + 1:
                    return BLUE_HI
        return jitter(BLUE, 2)
    if style == "bevel":
        return BLUE_MID if d >= 1.0 else BLUE
    if style == "dark":
        if d < 1.0:
            return METAL[5]
        return jitter(METAL[3], 2)
    if style == "grille":
        if d < 1.0:
            return BLUE_HI
        if d < 2.0:
            return BLUE_MID
        if 4 <= x < w - 4 and 4 <= y < h - 4:
            return METAL[1] if (y - 4) % 3 == 0 else METAL[3]
        return jitter(BLUE, 2)
    if style == "metal_rod":
        return METAL[4] if y < h / 2 else METAL[3]
    if style == "cap_bolt":
        return METAL[5] if d < 1.0 else METAL[2]
    return (255, 0, 255)


def paint_islands(img):
    n = TUBE_SIDES
    # Tube wall: a top-lit ramp round the eight sides, a darker ring where it leaves the band,
    # and a lit line down the upper flat - the only way a round tube reads with no lighting.
    x0, y0, w, h = ISLANDS["wall"]
    for yy in range(-PAD, h + PAD):
        for xx in range(-PAD, w + PAD):
            i = min(max(int((xx + 0.5) / w * n), 0), n - 1)
            a = math.pi / 2 + (i + 1.0) * 2 * math.pi / n     # face normal angle
            lit = math.sin(a)                                  # +1 up, -1 down
            idx = int(round(2 + (lit + 1) / 2 * 4))            # METAL[2..6]
            c = METAL[idx]
            if 0 <= yy < h and (yy in (int(h * 0.62), int(h * 0.62) + 1)):
                c = METAL[max(idx - 2, 0)]                    # a seam ring
            if yy >= h - 2:
                c = METAL[min(idx + 1, 6)]                    # the muzzle lip
            img.putpixel((x0 + xx, y0 + yy), jitter(c, 1))
    x0, y0, w, h = ISLANDS["rim"]
    for yy in range(-PAD, h + PAD):
        for xx in range(-PAD, w + PAD):
            i = min(max(int((xx + 0.5) / w * n), 0), n - 1)
            a = math.pi / 2 + (i + 1.0) * 2 * math.pi / n
            lit = math.sin(a)
            c = RIM[int(round((lit + 1) / 2 * 4))]
            img.putpixel((x0 + xx, y0 + yy), c)
    x0, y0, w, h = ISLANDS["bore"]
    for yy in range(-PAD, h + PAD):
        for xx in range(-PAD, w + PAD):
            t = min(max(yy / max(h - 1, 1), 0.0), 1.0)
            img.putpixel((x0 + xx, y0 + yy), METAL[1] if t < 0.35 else METAL[0])
    x0, y0, w, h = ISLANDS["bottom"]
    for yy in range(-PAD, h + PAD):
        for xx in range(-PAD, w + PAD):
            img.putpixel((x0 + xx, y0 + yy), (10, 9, 12))


def project(face):
    n = newell(face.pts)
    u = face.u_hint or (1, 0, 0)
    u = sub(u, mul(n, dot(u, n)))
    if dot(u, u) < 1e-6:
        u = sub((0, 1, 0), mul(n, dot((0, 1, 0), n)))
    u = norm(u)
    v = cross(n, u)
    v = mul(v, -1)     # image rows grow downward
    p0 = face.pts[0]
    pts2 = [(dot(sub(p, p0), u) * DENS, dot(sub(p, p0), v) * DENS) for p in face.pts]
    mx, my = min(p[0] for p in pts2), min(p[1] for p in pts2)
    return n, [(p[0] - mx, p[1] - my) for p in pts2]


def main():
    img = Image.new("RGB", (TEX, TEX), BLUE)
    pk = Packer(TEX)
    wall_len = int(round((0.03 + 0.62) * DENS))
    ISLANDS["wall"] = pk.take(24, wall_len)
    ISLANDS["rim"] = pk.take(16, 4)
    ISLANDS["bore"] = pk.take(16, 6)
    ISLANDS["bottom"] = pk.take(4, 4)
    paint_islands(img)
    faces = build()
    todo = []
    for f in faces:
        if f.uv is not None:
            continue
        n, pts2 = project(f)
        w = max(1, int(math.ceil(max(p[0] for p in pts2))))
        h = max(1, int(math.ceil(max(p[1] for p in pts2))))
        todo.append((h, w, f, n, pts2))
    # Tallest first: a shelf packer wastes least that way.
    todo.sort(key=lambda t: (-t[0], -t[1]))
    for h, w, f, n, pts2 in todo:
        rect = pk.take(w, h)
        paint_face(img, rect, pts2, f.style, n[1])
        f.uv = [(rect[0] + p[0], rect[1] + p[1]) for p in pts2]
    img.save(OUT_PNG)
    write_glb(faces)
    tris = sum(len(f.pts) - 2 for f in faces)
    print("faces %d, triangles %d, texture %dx%d, used rows to %d px"
          % (len(faces), tris, TEX, TEX, pk.y + pk.row_h))


# ── glTF ────────────────────────────────────────────────────────────────────────────────────────

def write_glb(faces):
    pos, nrm, uvs, idx = [], [], [], []
    for f in faces:
        n = newell(f.pts)
        base = len(pos)
        for p, t in zip(f.pts, f.uv):
            pos.append(p)
            nrm.append(n)
            uvs.append((t[0] / TEX, t[1] / TEX))
        for k in range(1, len(f.pts) - 1):
            idx += [base, base + k, base + k + 1]
    blob = bytearray()

    def chunk(data, fmt):
        off = len(blob)
        for row in data:
            blob.extend(struct.pack("<" + fmt, *row) if isinstance(row, tuple) else struct.pack("<" + fmt, row))
        while len(blob) % 4:
            blob.append(0)
        return off, len(blob) - off

    views, accs = [], []

    def view(off, ln, target=None):
        v = {"buffer": 0, "byteOffset": off, "byteLength": ln}
        if target:
            v["target"] = target
        views.append(v)
        return len(views) - 1

    def acc(vi, ctype, count, typ, mn=None, mx=None):
        a = {"bufferView": vi, "componentType": ctype, "count": count, "type": typ}
        if mn is not None:
            a["min"], a["max"] = mn, mx
        accs.append(a)
        return len(accs) - 1

    o, l = chunk(pos, "3f")
    a_pos = acc(view(o, l, 34962), 5126, len(pos), "VEC3",
                [min(p[i] for p in pos) for i in range(3)], [max(p[i] for p in pos) for i in range(3)])
    o, l = chunk(nrm, "3f")
    a_nrm = acc(view(o, l, 34962), 5126, len(nrm), "VEC3")
    o, l = chunk(uvs, "2f")
    a_uv = acc(view(o, l, 34962), 5126, len(uvs), "VEC2")
    o, l = chunk(idx, "H")
    a_idx = acc(view(o, l, 34963), 5123, len(idx), "SCALAR")
    png = open(OUT_PNG, "rb").read()
    off = len(blob)
    blob.extend(png)
    while len(blob) % 4:
        blob.append(0)
    v_img = view(off, len(png))
    gltf = {
        "asset": {"version": "2.0", "generator": "art/mortar_model.py"},
        "extensionsUsed": ["KHR_materials_unlit"],
        "scene": 0,
        "scenes": [{"nodes": [0]}],
        "nodes": [{"name": "mortar_head", "mesh": 0}],
        "meshes": [{"name": "mortar_head", "primitives": [{
            "attributes": {"POSITION": a_pos, "NORMAL": a_nrm, "TEXCOORD_0": a_uv},
            "indices": a_idx, "material": 0}]}],
        "materials": [{"name": "mortar", "doubleSided": True,
                       "extensions": {"KHR_materials_unlit": {}},
                       "pbrMetallicRoughness": {"baseColorTexture": {"index": 0},
                                                "metallicFactor": 0, "roughnessFactor": 0.9}}],
        "textures": [{"source": 0, "sampler": 0}],
        "samplers": [{"magFilter": 9728, "minFilter": 9986}],
        "images": [{"bufferView": v_img, "mimeType": "image/png", "name": "mortar_texture"}],
        "buffers": [{"byteLength": len(blob)}],
        "bufferViews": views,
        "accessors": accs,
    }
    js = json.dumps(gltf, separators=(",", ":")).encode()
    while len(js) % 4:
        js += b" "
    total = 12 + 8 + len(js) + 8 + len(blob)
    with open(OUT_GLB, "wb") as fh:
        fh.write(struct.pack("<III", 0x46546C67, 2, total))
        fh.write(struct.pack("<II", len(js), 0x4E4F534A) + js)
        fh.write(struct.pack("<II", len(blob), 0x004E4942) + bytes(blob))


if __name__ == "__main__":
    main()
