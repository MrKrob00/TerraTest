#!/usr/bin/env python3
"""Builds the swinging HEADS of the turrets that had none: geometry, a texture of their own, and a
.glb an artist can open.

    python3 art/turret_heads.py [mortar|shotgun|pound_cannon ...]   (no argument: all of them)
        -> objects/<name>_texture.png + art/out/<name>.glb
    godot --headless --path . --script res://art/turret_import.gd -- <name> ...
        -> blocks/meshes/<name>_head.tres

Only the HEAD is new. The platform and the turning neck are the ones the gun, the rocket launcher
and the laser already stand on (Assets.glb `base` / `rocketgun_head`), so every weapon reads as one
of the family and the turret chain in WeaponBlock finds its parts the same way. A head's origin is
the neck's pitch axis: the tip of the dark arm, 0.42 m over the platform, 0.28 m behind the centre,
and every head grips it with the same clevis (two cheeks and a trunnion round the arm's x +-0.09).

EACH HEAD SAYS WHAT ITS WEAPON DOES IN CODE:
  - MORTAR: eight shells a salvo (mortar.gd SHELLS) -> eight tubes, 4 x 2, every mouth visible from
    the front; aimed by the hull, throws at 30-60 deg -> a short pack on trunnions, wholly in front
    of the pivot, so it fits the cell at rest and swings up clear of the neck.
  - SHOTGUN: two shots, then a reload (shotgun.gd BURST) -> two barrels side by side, and a shell box
    showing two brass bases; a wide cone -> flared muzzles.
  - POUND_CANNON: one 30-damage blow at 60 m -> one thick barrel, a heavy mantlet, a recoil
    sleeve and a muzzle brake. The heaviest silhouette of the six, inside the same cube.

STYLE is the atlas's, not a new one. The blocks are UNSHADED, so every bit of shape is painted:
the palette is sampled from Assets_main_texture_new.png (GSO blue, gunmetal, orange trim), each
face gets its own pixels at the atlas's density (~48 px/m) with the light bevel line along its
edges that the other models carry, and the chamfer strips are painted as lit lips. Faces facing
down are darkened a little and round parts carry a top-lit ramp around their eight sides, because
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
OUT_GLB = os.path.join(ROOT, "art", "out", "%s.glb")   # .gdignore: for Blender, never imported
OUT_PNG = os.path.join(ROOT, "objects", "%s_texture.png")

DENS = 48.0         # px per metre - the atlas's own density
PAD = 2             # px of bleed round every island (mipmaps and 4x4 VRAM blocks)

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
GREEN = (80, 205, 120)
WHITE = (213, 210, 222)
GOLD = (240, 196, 72)
GOLD_LO = (170, 128, 40)


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


def box(faces, lo, hi, style, skip=(), face_styles=None):
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
        st = (face_styles or {}).get(k, style)
        faces.append(Face(outward(q, centre), st, u_hint=(0, 0, -1) if k[1] in "xy" else (1, 0, 0)))


# A KIT is one kind of round part: its painted islands are reserved before the faces are packed,
# and every copy of the part (eight mortar tubes, two shotgun barrels) shares them.
ISLANDS = {}          # "<kit>.<island>" -> (x, y, w, h) in px


def reserve_kit(pk, name, wall_len_m, mouth=True, sides=8):
    ISLANDS[name + ".wall"] = pk.take(3 * sides, max(4, int(round(wall_len_m * DENS))))
    if mouth:
        ISLANDS[name + ".rim"] = pk.take(2 * sides, 4)
        ISLANDS[name + ".bore"] = pk.take(2 * sides, 6)
        ISLANDS[name + ".bottom"] = pk.take(4, 4)


def lathe(faces, kit, cx, cy, profile, r_in=None, depth=0.0, sides=8, cap_back=False):
    """A round part along Z. `profile` is [(radius, z), ...] from the back to the front; the front
    ends in a mouth (rim down to r_in, a bore `depth` deep and its bottom) when r_in is given,
    otherwise in a flat cap. The wall maps onto the kit's island by distance along Z."""
    n = sides
    ang = [math.pi / 2 + (i + 0.5) * 2 * math.pi / n for i in range(n)]   # a flat on top
    ring = lambda r, z: [(cx + r * math.cos(a), cy + r * math.sin(a), z) for a in ang]
    wx, wy, ww, wh = ISLANDS[kit + ".wall"]
    z_len = abs(profile[-1][1] - profile[0][1]) or 1.0
    z_back, z_mouth = profile[0][1], profile[-1][1]
    axis_c = (cx, cy, (z_back + z_mouth) / 2)
    rings = [ring(r, z) for r, z in profile]
    vs = [wy + wh * abs(z - z_back) / z_len for _r, z in profile]
    if r_in is not None:
        i_m, i_d = ring(r_in, z_mouth), ring(r_in, z_mouth + depth)
        rx, ry, rw, rh = ISLANDS[kit + ".rim"]
        bx, by, bw, bh = ISLANDS[kit + ".bore"]
    for i in range(n):
        j = (i + 1) % n
        u0, u1 = wx + ww * i / n, wx + ww * (i + 1) / n
        for k in range(len(rings) - 1):
            a_, b_ = rings[k], rings[k + 1]
            q = [a_[i], a_[j], b_[j], b_[i]]
            uv = [(u0, vs[k]), (u1, vs[k]), (u1, vs[k + 1]), (u0, vs[k + 1])]
            faces.append(fixed(q, uv, (cx, cy, (a_[i][2] + b_[i][2]) / 2), outward_sign=+1))
        if r_in is not None:
            # Mouth rim (annulus), column i of the rim island.
            o_m = rings[-1]
            u0, u1 = rx + rw * i / n, rx + rw * (i + 1) / n
            q = [o_m[i], o_m[j], i_m[j], i_m[i]]
            uv = [(u0, ry), (u1, ry), (u1, ry + rh), (u0, ry + rh)]
            faces.append(fixed(q, uv, (cx, cy, z_mouth + 1.0), outward_sign=+1))
            # Bore wall, seen from inside.
            u0, u1 = bx + bw * i / n, bx + bw * (i + 1) / n
            q = [i_m[i], i_m[j], i_d[j], i_d[i]]
            uv = [(u0, by), (u1, by), (u1, by + bh), (u0, by + bh)]
            faces.append(fixed(q, uv, (cx, cy, z_mouth), outward_sign=-1))
    front = +1.0 if z_mouth > z_back else -1.0
    if r_in is not None:
        cx0, cy0, cw, chh = ISLANDS[kit + ".bottom"]
        uv = [(cx0 + cw / 2 + cw / 2 * math.cos(a), cy0 + chh / 2 + chh / 2 * math.sin(a)) for a in ang]
        faces.append(fixed(i_d, uv, (cx, cy, z_mouth + front), outward_sign=+1))
    else:
        faces.append(Face(outward(list(rings[-1]), axis_c), "cap_bolt", u_hint=(1, 0, 0)))
    if cap_back:
        faces.append(Face(outward(list(rings[0]), axis_c), "cap_bolt", u_hint=(1, 0, 0)))


def fixed(pts, uv, ref, outward_sign):
    """A face with UVs in a shared island; wound so its normal points away from (or toward) ref."""
    c = mul(tuple(map(sum, zip(*pts))), 1.0 / len(pts))
    if dot(newell(pts), sub(c, ref)) * outward_sign < 0:
        pts, uv = list(reversed(pts)), list(reversed(uv))
    f = Face(pts, None)
    f.uv = uv
    return f


def clevis(faces, top):
    """Two gunmetal cheeks round the neck's arm tip and the trunnion through them."""
    for sg in (-1, 1):
        box(faces, (0.10 if sg > 0 else -0.15, -0.075, -0.07),
            (0.15 if sg > 0 else -0.10, top, 0.11), "dark")
    prism_x(faces, -0.18, 0.18, 0.0, 0.0, 0.045)


# EVERY HEAD FITS ITS CELL AT REST, the way the artist's gun, laser and rocket launcher do (their
# vertices measure inside -0.52..0.52). The head hangs at block (0, -0.081, 0.28), so in head axes
# a flat head has z in -0.78..0.22 and y up to 0.58. A head parked at an angle turns that box: at
# the mortar's 45 deg the limits are y - z <= 0.82 (top), y + z <= 0.31 (back), and the pack has to
# stand wholly IN FRONT of the pivot - the first pack reached 0.62 up and 0.69 back.
def reserve_mortar(pk):
    reserve_kit(pk, "tube", 0.05 + 0.49)


def build_mortar():
    faces = []
    # Tubes: 4 x 2, a flat on top, every mouth visible from the front.
    cols = [-0.21, -0.07, 0.07, 0.21]
    rows = [0.105, 0.245]
    for y in rows:
        for x in cols:
            lathe(faces, "tube", x, y, [(0.062, -0.05), (0.062, -0.49)], r_in=0.046, depth=0.07)
    # Breech housing, behind the tubes and in front of the pivot; its top-back edge sits exactly on
    # the cell's back wall at rest. Top panel carries the forward arrow.
    prism(faces, -0.31, 0.31, 0.03, 0.33, -0.02, -0.15, 0.04,
          cap_front="blue", cap_back="grille", top_style="blue_arrow")
    # One band round the cluster, in the platform's orange trim.
    prism(faces, -0.29, 0.29, 0.035, 0.315, -0.30, -0.36, 0.03, side="stripe")
    clevis(faces, 0.065)
    return faces


# A FLAT-FIRING HEAD SITS HIGH ON THE ARM, the way the gun's and the rocket launcher's do: at the
# 40 deg depression WeaponBlock allows, a barrel 0.13 m over the pivot went straight through the neck's
# collar and the cannon's brake came out under the platform. At 0.30 the barrel's middle stays over
# the collar top at full depression, and the clevis grows up to meet the body.
FLAT_Y = 0.30


def reserve_shotgun(pk):
    reserve_kit(pk, "barrel", 0.58)


def build_shotgun():
    faces = []
    y = FLAT_Y
    # Two barrels, one per shot of the burst, flaring a little at the muzzle: the cone is the weapon.
    # A rib runs between them - without it, two short flared tubes read as binoculars from the front.
    for x in (-0.085, 0.085):
        lathe(faces, "barrel", x, y, [(0.062, -0.20), (0.062, -0.70), (0.082, -0.78)],
              r_in=0.050, depth=0.09)
    box(faces, (-0.025, y, -0.68), (0.025, y + 0.075, -0.20), "dark")
    # Receiver: the blue body the barrels leave, grille at the back, arrow on top.
    prism(faces, -0.20, 0.20, y - 0.14, y + 0.14, 0.14, -0.22, 0.04,
          cap_front="blue", cap_back="grille", top_style="blue_arrow")
    # Clamp round both barrels, carrying the platform's orange trim.
    prism(faces, -0.18, 0.18, y - 0.095, y + 0.095, -0.46, -0.52, 0.03, side="stripe")
    # Shell box on the right: two brass bases, one per shot before the reload.
    box(faces, (0.20, y - 0.10, -0.13), (0.265, y + 0.08, 0.07), "dark", face_styles={"+x": "shells"})
    clevis(faces, y - 0.13)
    return faces


def reserve_pound_cannon(pk):
    reserve_kit(pk, "barrel", 0.48)
    reserve_kit(pk, "sleeve", 0.20, mouth=False)


def build_pound_cannon():
    faces = []
    y = FLAT_Y
    # One thick barrel ending on the cell's front wall (-0.78): a single heavy blow at sixty metres.
    lathe(faces, "barrel", 0.0, y, [(0.072, -0.30), (0.072, -0.78)], r_in=0.050, depth=0.05)
    # Recoil sleeve where it leaves the mantlet, banded in the platform's orange.
    lathe(faces, "sleeve", 0.0, y, [(0.11, -0.10), (0.11, -0.30)])
    prism(faces, -0.122, 0.122, y - 0.122, y + 0.122, -0.22, -0.26, 0.038, side="stripe")
    # Muzzle brake, slotted on both sides; its front stays behind the bore's bottom.
    box(faces, (-0.105, y - 0.08, -0.72), (0.105, y + 0.08, -0.62), "dark",
        face_styles={"+x": "brake", "-x": "brake"})
    # Mantlet: a heavy armoured block, its back on the cell's back wall, with a thicker face plate.
    prism(faces, -0.25, 0.25, y - 0.17, y + 0.17, 0.22, -0.06, 0.06,
          cap_front="blue", cap_back="grille", top_style="blue_arrow")
    prism(faces, -0.27, 0.27, y - 0.19, y + 0.19, -0.06, -0.11, 0.07)
    clevis(faces, y - 0.16)
    return faces


# name: (seed, reserve, build, texture side)
WEAPONS = {
    "mortar": (7, reserve_mortar, build_mortar, 256),
    "shotgun": (11, reserve_shotgun, build_shotgun, 256),
    "pound_cannon": (13, reserve_pound_cannon, build_pound_cannon, 256),
}


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


_FALSUS = {}


def _falsus_cov(w, h):
    """Coverage of the Falsus emblem (art/faction_emblem.py, the one drawing of it) centred in a
    w x h plate, cached per size. Under ~8 px of hole the eye is a dot: finer, it is mush."""
    if (w, h) not in _FALSUS:
        import numpy as np
        import faction_emblem as fe
        size = min(w, h)
        R = size * 0.42
        simple = R * fe.HOLE < 8
        cov = fe.coverage(lambda x, y: fe.inside(x, y, simple), size, R, ss=3)
        full = np.zeros((h, w), dtype=np.float32)
        oy, ox = (h - size) // 2, (w - size) // 2
        full[oy:oy + size, ox:ox + size] = cov
        _FALSUS[(w, h)] = full
    return _FALSUS[(w, h)]


def _gear(bx, by):
    r = math.hypot(bx, by)
    if r < 1.3:
        return False
    if r <= 3.3:
        return True
    ang = math.atan2(by, bx)
    return r <= 4.8 and abs(((ang / (2 * math.pi) * 8) % 1.0) - 0.5) < 0.22


def _split_block(bx, by):
    # a square broken down a jagged line, the halves pushed apart
    if abs(by) > 4.0:
        return False
    crack = 0.6 * (1 if int(by + 4) % 2 else -1)
    if bx < crack - 0.8:
        return -4.6 <= bx and abs(by + 0.6) <= 3.4
    if bx > crack + 0.8:
        return bx <= 4.6 and abs(by - 0.6) <= 3.4
    return False


def _magnet(bx, by):
    # a horseshoe, open at the top
    r = math.hypot(bx, by - 0.5)
    if by >= 0.5:
        return 1.8 <= r <= 4.0
    return 1.8 <= abs(bx) <= 4.0 and by >= -4.2


def _cube(bx, by):
    # a block: its outline and a solid core
    m = max(abs(bx), abs(by))
    return 3.4 <= m <= 4.6 or m <= 1.7


EMBLEMS = {"comp_side": _gear, "scrap_side": _split_block, "pack_side": _magnet, "fab_side": _cube}


def style_px(style, x, y, w, h, d):
    if style == "blue_cross":
        # The repair unit's mark: a green cross outlined in white, the same on every side.
        if d < 1.0:
            return BLUE_HI
        if d < 2.0:
            return BLUE_MID
        cx, cy = w / 2.0, h / 2.0
        arm, half = min(w, h) * 0.32, min(w, h) * 0.11
        ax, ay = abs(x + 0.5 - cx), abs(y + 0.5 - cy)
        inside = (ax <= half and ay <= arm) or (ay <= half and ax <= arm)
        edge = (ax <= half + 1 and ay <= arm + 1) or (ay <= half + 1 and ax <= arm + 1)
        if inside:
            return GREEN
        if edge:
            return WHITE
        return jitter(BLUE, 2)
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
    if style in ("anchor_top", "anchor_top_fixed"):
        # The supports' deck: plain blue, the player's call - the turning one's chevron and the fixed
        # one's ring of bolts read as a design laid over the deck (and the chevron sat off the
        # turn's centre). The fixed square deck keeps a bolt in each corner, where a deck is bolted.
        if d < 1.0:
            return BLUE_HI
        if d < 2.0:
            return BLUE_MID
        if style == "anchor_top_fixed":
            for rx, ry in ((4, 4), (w - 6, 4), (4, h - 6), (w - 6, h - 6)):
                if rx <= x < rx + 2 and ry <= y < ry + 2:
                    return BLUE_DEEP
                if (x == rx + 2 and ry <= y <= ry + 2) or (y == ry + 2 and rx <= x <= rx + 2):
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
    if style == "shells":
        # Two brass shell bases in a dark box: the burst, counted.
        if d < 1.0:
            return METAL[5]
        for cx in (w * 0.3, w * 0.7):
            r = math.hypot(x + 0.5 - cx, y + 0.5 - h / 2)
            if r <= 2.2:
                return WHITE if (r <= 0.8) else ORANGE
            if r <= 3.0:
                return ORANGE_LO
        return jitter(METAL[2], 2)
    if style == "brake":
        # Muzzle brake: two vertical ports cut through the side.
        if d < 1.0:
            return METAL[5]
        if 2 <= y < h - 2 and (x % 5) in (2, 3):
            return METAL[0]
        return jitter(METAL[3], 2)
    if style == "fork_hub":
        # The fork's middle: the background first, then open chevrons laid over it - two pointing
        # out front, left and right, one coming in from the back. Filled heads on shafts merged
        # into one orange blot at this size (33 texels); an open ">" never covers its neighbour.
        # u runs forward, v across.
        if d < 1.0:
            return METAL[5]
        cu, cv = w / 2.0, h / 2.0
        px, py = x + 0.5, y + 0.5
        # (tip u, tip v, direction u, direction v, colour): each chevron's tip, pointing along dir.
        marks = []
        for k in (0, 1):
            s = 3.0 + k * 4.0
            marks.append((w - s, cv, 1, 0, ORANGE))
            marks.append((cu, s, 0, -1, ORANGE))
            marks.append((cu, h - s, 0, 1, ORANGE))
        marks.append((7.0, cv, 1, 0, ORANGE_LO))
        for tu, tv, du, dv, col in marks:
            a = (tu - px) * du + (tv - py) * dv                   # distance back from the tip
            off = abs((px - tu) * dv - (py - tv) * du)            # distance across the axis
            if 0 <= a <= 3.2 and abs(off - a) < 0.85:
                return col
        if math.hypot(px - cu, py - cv) <= 2.2:
            return METAL[4]                                        # the pivot the flow splits at
        return METAL[2] if (x % 4) == 0 else METAL[1]
    if style in ("belt", "belt_fwd"):
        # Rubber belt: ribs across the run, and for a directed belt chevrons pointing along +u
        # (the way the cargo goes). The face's u runs along the flow, v across it.
        if d < 1.0:
            return METAL[2]
        if style == "belt_fwd":
            for u0 in (w * 0.18, w * 0.62):
                a = (x + 0.5) - u0
                off = abs(y + 0.5 - h / 2)
                if 0 <= a < 6 and abs(off - (6 - a) * 0.9) < 1.2 and off < h / 2 - 2:
                    return ORANGE if a > 1 else ORANGE_LO
        return METAL[2] if (x % 4) == 0 else METAL[1]
    if style == "gen_side":
        # The generator's wall, the frame block's language in our own drawing: a light edge line,
        # a slot grille across the top with a bolt sign in the middle, and under it the dark frame
        # the firebox window (a part of its own, generator_fire) sits in. Rows run down from the top.
        if d < 1.0:
            return METAL[5]
        if d < 2.0:
            return METAL[4]
        g0, g1 = 3, int(h * 0.46)
        cx = w / 2.0
        if g0 <= y < g1 and 3 <= x < w - 3:
            bx, by = x + 0.5 - cx, y + 0.5 - (g0 + g1) / 2.0
            if abs(bx) <= 4.5 and abs(by) <= 4.5:
                # The sign plate: a bolt, drawn as two offset bars, on a dark square.
                if abs(bx) > 3.5 or abs(by) > 3.5:
                    return METAL[5]
                if (by < 0 and 0 <= bx + by * 0.5 + 0.5 <= 1.6) or (by >= 0 and 0 <= bx + by * 0.5 + 1.5 <= 1.6) \
                        or (abs(by) < 0.6 and -1.5 <= bx <= 1.5):
                    return RIM[4]
                return METAL[1]
            return METAL[1] if (x % 3) == 0 else METAL[3]
        if y >= g1 + 1:
            return METAL[2] if (x + y) % 5 else METAL[1]
        for rx, ry in ((2, h - 3), (w - 3, h - 3)):
            if x == rx and y == ry:
                return METAL[6]
        return jitter(METAL[3], 2)
    if style == "plain_side":
        # A dark grilled wall with no sign: the family's panel where there is nothing to say.
        if d < 1.0:
            return METAL[5]
        if d < 2.0:
            return METAL[4]
        if 3 <= y < h - 3 and 3 <= x < w - 3:
            return METAL[1] if (x % 3) == 0 else METAL[3]
        for rx, ry in ((2, 2), (w - 3, 2), (2, h - 3), (w - 3, h - 3)):
            if x == rx and y == ry:
                return METAL[6]
        return jitter(METAL[3], 2)
    if style == "col_side":
        # The collector's wall: the slot grille the whole height, and on a plate in the middle a
        # chevron pointing DOWN - things go in at the top and stay.
        if d < 1.0:
            return METAL[5]
        if d < 2.0:
            return METAL[4]
        cx, cy = w / 2.0, h / 2.0
        bx, by = x + 0.5 - cx, y + 0.5 - cy
        if abs(bx) <= 5.5 and abs(by) <= 5.5:
            if abs(bx) > 4.5 or abs(by) > 4.5:
                return METAL[5]
            if -2.5 <= by <= 2.5 and abs(bx) <= (2.5 - by) * 0.75 + 0.4:   # a triangle, point down
                return RIM[4]
            return METAL[1]
        if 3 <= y < h - 3 and 3 <= x < w - 3:
            return METAL[1] if (x % 3) == 0 else METAL[3]
        for rx, ry in ((2, 2), (w - 3, 2), (2, h - 3), (w - 3, h - 3)):
            if x == rx and y == ry:
                return METAL[6]
        return jitter(METAL[3], 2)
    if style == "slab_side":
        # A platform's side, the family's: dark edge lines and orange hazard slats between them.
        if d < 1.0:
            return METAL[5]
        if 1 <= y < h - 1 and 2 <= x < w - 2:
            return METAL[1] if (x // 2) % 2 else (ORANGE if y < h - 2 else ORANGE_LO)
        return METAL[2]
    if style == "smelt_side":
        # The smelter's furnace wall: the slot grille, and on a plate in the middle an INGOT (a
        # trapezoid, narrow on top) - what comes out of it.
        if d < 1.0:
            return METAL[5]
        if d < 2.0:
            return METAL[4]
        cx, cy = w / 2.0, h * 0.40
        bx, by = x + 0.5 - cx, y + 0.5 - cy
        if abs(bx) <= 6.5 and abs(by) <= 4.5:
            if abs(bx) > 5.5 or abs(by) > 3.5:
                return METAL[5]
            if -1.5 <= by <= 1.5 and abs(bx) <= 2.6 + (by + 1.5) * 0.6:
                return WHITE if by < -0.5 else RIM[3]
            return METAL[1]
        if 3 <= y < h - 3 and 3 <= x < w - 3:
            return METAL[1] if (x % 3) == 0 else METAL[3]
        return jitter(METAL[3], 2)
    if style == "vault_door":
        # The seller's vault: a round door with spokes and a ring of bolts.
        if d < 1.0:
            return METAL[5]
        cx, cy = w / 2.0, h / 2.0
        px, py = x + 0.5 - cx, y + 0.5 - cy
        R = min(w, h) * 0.36
        r = math.hypot(px, py)
        if R - 1.6 <= r < R:
            return METAL[5]
        if r < 2.6:
            return RIM[3]
        if r < R - 1.6:
            if abs(px) < 0.8 or abs(py) < 0.8:
                return METAL[1]
            return METAL[3]
        for k in range(8):
            a = k * math.pi / 4
            if int(px + cx) == int(cx + math.cos(a) * (R + 2.5)) and int(py + cy) == int(cy + math.sin(a) * (R + 2.5)):
                return METAL[6]
        return jitter(METAL[2], 2)
    if style == "sell_panel":
        # The seller's front: a dark screen with a gold coin and three green bars rising - trade.
        if d < 1.0:
            return METAL[5]
        if d < 2.0:
            return METAL[4]
        if 4 <= x < w - 4 and 4 <= y < h - 4:
            cx, cy = w * 0.33, h * 0.42
            r = math.hypot(x + 0.5 - cx, y + 0.5 - cy)
            R = min(w, h) * 0.20
            if r < R:
                if abs(x + 0.5 - cx) < 1.0 and abs(y + 0.5 - cy) < R * 0.6:
                    return GOLD
                return GOLD if r > R - 1.4 else GOLD_LO
            base = h * 0.62
            for k, top in enumerate((0.44, 0.34, 0.22)):
                bx0 = w * 0.58 + k * 4
                if bx0 <= x < bx0 + 3 and h * top <= y < base:
                    return GREEN
            if int(h * 0.62) == y and w * 0.55 <= x < w - 5:
                return RIM[1]
            return METAL[0] if (x + y) % 7 else METAL[1]
        return jitter(METAL[3], 2)
    if style == "molten":
        # The smelter's gauge fill: molten metal, bright at the bottom.
        t = (y + 0.5) / max(h, 1)
        if d < 1.0:
            return ORANGE_LO
        return (255, 222, 130) if t > 0.7 else ((250, 180, 80) if t > 0.35 else ORANGE)
    if style == "screen":
        # A display the game writes on (the seller's Label3D stands on it): near-black glass with
        # faint scanlines, a thin gold header bar and corner brackets - no picture of its own.
        if d < 1.0:
            return METAL[1]
        px, py = x + 0.5, y + 0.5
        if 3 <= py < 5 and 4 <= px < w - 4:
            return GOLD_LO
        for cx, cy, sx, sy in ((3, 3, 1, 1), (w - 3, 3, -1, 1), (3, h - 3, 1, -1), (w - 3, h - 3, -1, -1)):
            ax, ay = (px - cx) * sx, (py - cy) * sy
            if (0 <= ax < 5 and 0 <= ay < 1.2) or (0 <= ay < 5 and 0 <= ax < 1.2):
                return (70, 120, 110)
        return (14, 22, 26) if y % 3 else (20, 30, 34)
    if style == "lamp_strip":
        # A row of status lamps under the screen: green, green, amber, green, green.
        if d < 1.0:
            return METAL[5]
        n = 5
        for k in range(n):
            cx = w * (k + 0.5) / n
            if abs(x + 0.5 - cx) <= 2.2 and abs(y + 0.5 - h / 2.0) <= 2.0:
                return ORANGE if k == 2 else GREEN
        return METAL[1]
    if style == "recv_floor":
        # The receiver's deck: the belt's own ribbed rubber, and two chevrons at the front edge
        # pointing out (+u) to the conveyor it feeds.
        if d < 1.0:
            return METAL[2]
        for u0 in (w - 13.0, w - 7.0):
            a = (x + 0.5) - u0
            off = abs(y + 0.5 - h / 2)
            if 0 <= a < 6 and abs(off - (6 - a) * 0.9) < 1.2 and off < 7:
                return ORANGE if a > 1 else ORANGE_LO
        return METAL[2] if (x % 4) == 0 else METAL[1]
    if style == "recv_pad":
        # The receiver's pad: dark rubber with the blue octagon the old model carried.
        if d < 1.0:
            return METAL[4]
        if 3.0 <= d < 4.6:
            return BLUE_HI if d < 3.8 else BLUE
        return jitter(METAL[1], 2)
    if style == "dark_edge":
        # A chamfer on dark metal: the light line the atlas draws along every bevel.
        return RIM[1] if d < 1.0 else METAL[4]
    if style == "gen_top":
        # The housing's top: a blue lip round a dark round well the rotor turns in.
        if d < 1.0:
            return BLUE_HI
        if d < 2.0:
            return BLUE_MID
        r = math.hypot(x + 0.5 - w / 2.0, y + 0.5 - h / 2.0)
        R = min(w, h) * 0.5 - 2.5
        if R - 1.0 <= r < R:
            return RIM[1]
        if r < R - 1.0:
            return METAL[0] if r < R * 0.55 else METAL[1]
        return jitter(BLUE, 2)
    if style == "gen_fire":
        # Fire behind a grate, painted in its LIT state; generator.gd darkens it when cold.
        if d < 1.0:
            return METAL[0]
        if x % 4 == 1:
            return METAL[1]                          # grate bars
        t = (y + 0.5) / h                            # 0 at the top, 1 at the bottom
        if t > 0.72:
            return (255, 214, 120)
        if t > 0.40:
            return (240, 170, 70)
        return ORANGE if t > 0.18 else ORANGE_LO
    if style == "store_side":
        # The storage's wall: a container's corrugation, and down the middle a dark slot with a
        # tick every quarter - the level bar (storage_level, its own part) rises in it.
        if d < 1.0:
            return METAL[5]
        if d < 2.0:
            return METAL[4]
        cx = w / 2.0
        s0, s1 = 4, h - 4
        if abs(x + 0.5 - cx) <= 4.0 and s0 - 1 <= y < s1 + 1:
            if abs(x + 0.5 - cx) > 3.0 or y in (s0 - 1, s1):
                return METAL[5]
            for k in range(1, 4):
                if y == int(s1 - (s1 - s0) * k / 4.0) and abs(x + 0.5 - cx) > 1.5:
                    return RIM[1]
            return METAL[0]
        for rx, ry in ((3, 3), (w - 4, 3), (3, h - 4), (w - 4, h - 4)):
            if x == rx and y == ry:
                return METAL[6]
        if 3 <= y < h - 3:
            k = x % 5
            return METAL[4] if k == 0 else (METAL[3] if k < 3 else METAL[2])
        return jitter(METAL[3], 2)
    if style in EMBLEMS:
        # A factory wall that says what the block does: the family's slot grille, and on a plate
        # in the middle a mark nine-plus texels across (smaller breaks up under mipmaps, see
        # docs/ART_STYLE.md) - a gear for the component plant, a split block for the scrapper, a
        # horseshoe magnet for the packer.
        if d < 1.0:
            return METAL[5]
        if d < 2.0:
            return METAL[4]
        cx, cy = w / 2.0, h * 0.42
        bx, by = x + 0.5 - cx, y + 0.5 - cy
        if abs(bx) <= 6.5 and abs(by) <= 6.5:
            if abs(bx) > 5.5 or abs(by) > 5.5:
                return METAL[5]
            return RIM[4] if EMBLEMS[style](bx, by) else METAL[1]
        if 3 <= y < h - 3 and 3 <= x < w - 3:
            return METAL[1] if (x % 3) == 0 else METAL[3]
        for rx, ry in ((2, 2), (w - 3, 2), (2, h - 3), (w - 3, h - 3)):
            if x == rx and y == ry:
                return METAL[6]
        return jitter(METAL[3], 2)
    if style[:5] in ("mtone", "btone") and style[5:].isdigit():
        # A facet of a round part built as flat quads (emitter_models.tube): its own tone from the
        # painted light, and the atlas's edge line - a pipe reads round only this way, unshaded.
        k = int(style[5:])
        if style[0] == "m":
            c = METAL[2 + k]
            return RIM[1] if d < 1.0 else jitter(c, 1)
        c = [BLUE_DEEP, BLUE_LO, BLUE, BLUE_MID, BLUE_HI][k]
        return BLUE_HI if d < 1.0 and k < 4 else jitter(c, 1)
    if style == "mouth":
        # A belt-height opening in a machine's wall: a blue frame, a dark hole, a light sill.
        if x < 3 or x >= w - 3 or y < 3:
            return BLUE_HI if (d < 1.0) else (BLUE_MID if (x in (2, w - 3) or y == 2) else BLUE)
        if y >= h - 3:
            return RIM[2] if y == h - 3 else METAL[2]
        return METAL[0] if y > 5 else METAL[1]
    if style == "falsus_plate":
        # The faction's sign on a machine: its emblem in its green on a dark plate with the edge line.
        if d < 1.0:
            return METAL[5]
        if d < 2.0:
            return METAL[4]
        if 0 <= y < h and 0 <= x < w and _falsus_cov(w, h)[y][x] >= 0.5:
            return (60, 222, 76)
        return METAL[1]
    if style == "fab_window":
        # The fabricator's assembly window: dark glass with the cyan grid a block materialises on.
        if d < 1.0:
            return METAL[1]
        if (x % 6 == 0) or (y % 6 == 0):
            return (70, 190, 200)
        return (14, 30, 36) if (x + y) % 2 else (18, 36, 42)
    if style == "coil":
        # The packer's electromagnet: copper windings, a dark line between every turn.
        if d < 1.0:
            return ORANGE_LO
        return ORANGE_LO if y % 3 == 0 else (ORANGE if (y // 3) % 2 else (190, 124, 50))
    if style == "pole":
        # The magnet's pole face: bright polished metal with a dark ring.
        r = math.hypot(x + 0.5 - w / 2.0, y + 0.5 - h / 2.0)
        if d < 1.0:
            return RIM[1]
        if abs(r - min(w, h) * 0.28) < 0.8:
            return METAL[2]
        return RIM[3] if r < min(w, h) * 0.28 else RIM[2]
    if style == "level":
        # The storage's fill: a bright bar in segments, the storage's one pop colour.
        if d < 1.0:
            return (150, 240, 170)
        return GREEN if (y % 4) else (60, 160, 95)
    if style == "store_floor":
        # The tray the one shown item sits in: dark checker plate.
        if d < 1.0:
            return METAL[4]
        return METAL[2] if ((x // 3) + (y // 3)) % 2 else METAL[1]
    if style == "blade":
        return RIM[4] if d < 1.0 else RIM[2]
    if style == "metal_rod":
        return METAL[4] if y < h / 2 else METAL[3]
    if style == "cap_bolt":
        return METAL[5] if d < 1.0 else METAL[2]
    return (255, 0, 255)


def paint_kit(img, kit, sides=8):
    n = sides
    # Wall: a top-lit ramp round the eight sides, a darker seam ring, and a lit lip at the mouth
    # end - the only way a round part reads with no lighting.
    x0, y0, w, h = ISLANDS[kit + ".wall"]
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
    if kit + ".rim" not in ISLANDS:
        return
    x0, y0, w, h = ISLANDS[kit + ".rim"]
    for yy in range(-PAD, h + PAD):
        for xx in range(-PAD, w + PAD):
            i = min(max(int((xx + 0.5) / w * n), 0), n - 1)
            a = math.pi / 2 + (i + 1.0) * 2 * math.pi / n
            lit = math.sin(a)
            c = RIM[int(round((lit + 1) / 2 * 4))]
            img.putpixel((x0 + xx, y0 + yy), c)
    x0, y0, w, h = ISLANDS[kit + ".bore"]
    for yy in range(-PAD, h + PAD):
        for xx in range(-PAD, w + PAD):
            t = min(max(yy / max(h - 1, 1), 0.0), 1.0)
            img.putpixel((x0 + xx, y0 + yy), METAL[1] if t < 0.35 else METAL[0])
    x0, y0, w, h = ISLANDS[kit + ".bottom"]
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


def make(name):
    seed, reserve, build, tex = WEAPONS[name]
    random.seed(seed)
    ISLANDS.clear()
    img = Image.new("RGB", (tex, tex), BLUE)
    pk = Packer(tex)
    reserve(pk)
    for kit in dict.fromkeys(k.split(".")[0] for k in ISLANDS):
        paint_kit(img, kit)
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
    img.save(OUT_PNG % name)
    write_glb(faces, name, tex)
    tris = sum(len(f.pts) - 2 for f in faces)
    print("%s: faces %d, triangles %d, texture %dx%d, used rows to %d px"
          % (name, len(faces), tris, tex, tex, pk.y + pk.row_h))


def main():
    for name in (sys.argv[1:] or list(WEAPONS)):
        make(name)


# ── glTF ────────────────────────────────────────────────────────────────────────────────────────

def write_glb(faces, name, tex):
    pos, nrm, uvs, idx = [], [], [], []
    for f in faces:
        n = newell(f.pts)
        base = len(pos)
        for p, t in zip(f.pts, f.uv):
            pos.append(p)
            nrm.append(n)
            uvs.append((t[0] / tex, t[1] / tex))
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
    png = open(OUT_PNG % name, "rb").read()
    off = len(blob)
    blob.extend(png)
    while len(blob) % 4:
        blob.append(0)
    v_img = view(off, len(png))
    gltf = {
        "asset": {"version": "2.0", "generator": "art/turret_heads.py"},
        "extensionsUsed": ["KHR_materials_unlit"],
        "scene": 0,
        "scenes": [{"nodes": [0]}],
        "nodes": [{"name": name + "_head", "mesh": 0}],
        "meshes": [{"name": name + "_head", "primitives": [{
            "attributes": {"POSITION": a_pos, "NORMAL": a_nrm, "TEXCOORD_0": a_uv},
            "indices": a_idx, "material": 0}]}],
        "materials": [{"name": name, "doubleSided": True,
                       "extensions": {"KHR_materials_unlit": {}},
                       "pbrMetallicRoughness": {"baseColorTexture": {"index": 0},
                                                "metallicFactor": 0, "roughnessFactor": 0.9}}],
        "textures": [{"source": 0, "sampler": 0}],
        "samplers": [{"magFilter": 9728, "minFilter": 9986}],
        "images": [{"bufferView": v_img, "mimeType": "image/png", "name": name + "_texture"}],
        "buffers": [{"byteLength": len(blob)}],
        "bufferViews": views,
        "accessors": accs,
    }
    js = json.dumps(gltf, separators=(",", ":")).encode()
    while len(js) % 4:
        js += b" "
    total = 12 + 8 + len(js) + 8 + len(blob)
    with open(OUT_GLB % name, "wb") as fh:
        fh.write(struct.pack("<III", 0x46546C67, 2, total))
        fh.write(struct.pack("<II", len(js), 0x4E4F534A) + js)
        fh.write(struct.pack("<II", len(blob), 0x004E4942) + bytes(blob))


if __name__ == "__main__":
    main()
