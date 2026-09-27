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
