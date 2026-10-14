#!/usr/bin/env python3
"""AERO'S BASIC BLOCK AND STANDARD WHEEL, built by the brief in docs/ART_STYLE.md ("Aero"). DRAFTS for
the player's approval: generator only, not wired into the game.

    python3 art/aero_models.py [aero_block|aero_wheel]
        -> objects/<name>_texture.png + art/out/<name>.glb (one node per part, at its pivot)

The same block's second version is built in Blender (art/aero_blender.py), so the two ways of making
a model can be compared on one design.

THE TEXTURE IS PAINTED IN THE BLOCK'S OWN SPACE: every texel is mapped back to the 3D point it lands
on, so the three bands (blue top, white middle, orange bottom) run straight across faces, chamfers
and neighbouring blocks - the emblem's bands, dipping into a V in the middle of every side face, so a
row of blocks reads as a row of chevrons. The fold of the emblem - its left half a shade lighter than
the right - is kept on every face. Chamfers are 0.035 m (half of Falsus's), painted as the glint:
pure white on the white band, a light tint of the band elsewhere.

BLOCK - a full chamfered cube (it joins on every face, so every wall is on its cell's face): on every
side face the bands, a bold black chevron in the white band and three vent slots in each half of the
orange band; the top blue, the bottom orange.

WHEEL - the standard wheel's size and place (tyre r 0.5 round (0, -0.385, -0.25), bolted on by its
BACK face like every wheel) on a racing car's corner: a tapered PYLON on the hull face, two flat
aerofoil WISHBONES and a push rod out to an UPRIGHT inside the tyre's line, and a 12-sided slick
with a recessed titanium rim of six spokes.
  aero_wheel_body    the pylon (still)
  aero_wheel_arm     wishbones, push rod, upright and axle, about ARM_PIVOT (swings with the suspension)
  aero_wheel_tyre    tyre and rim about TC (spins about Z)
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
C = 0.035                      # the Aero chamfer (Falsus 0.067)

# the emblem's colours, the darker one for the right half of the fold
BLUE = ((14, 188, 232), (6, 156, 206))
WHITE = ((244, 245, 248), (224, 227, 233))
ORANGE = ((252, 94, 10), (228, 70, 12))
GLINT = {"b": (120, 222, 248), "w": (255, 255, 255), "o": (255, 160, 96)}
INK = (14, 14, 18)
VENT = (58, 60, 68)
RUBBER = (30, 30, 35)
TITAN = ((184, 190, 200), (158, 164, 176))
CARBON = (36, 38, 45)

BAND = 1.0 / 6.0               # the white band's half height at a face's edge
DIP = 0.10                     # how far the bands dip in a face's middle (the emblem's V)


# ── painting ────────────────────────────────────────────────────────────────────────────────────

def band_at(y, h):
    """Which band a point of a side face is in: y its height in the block, h its place across the
    face (-0.5..0.5). The boundaries dip by DIP in the middle."""
    dip = DIP * (1.0 - 2.0 * min(abs(h), 0.5))
    if y > BAND - dip:
        return "b"
    if y < -BAND - dip:
        return "o"
    return "w"


def band_col(b, h):
    pair = {"b": BLUE, "w": WHITE, "o": ORANGE}[b]
    return pair[0] if h < 0 else pair[1]


def across(P, n):
    """A side face's horizontal coordinate, -0.5 at its left edge seen from outside."""
    right = th.norm(th.cross((0, 1, 0), n)) if abs(n[1]) < 0.9 else (1, 0, 0)
    return -th.dot(P, right)


def _seg_d(px, py, ax, ay, bx, by):
    ex, ey = bx - ax, by - ay
    t = max(0.0, min(1.0, ((px - ax) * ex + (py - ay) * ey) / (ex * ex + ey * ey)))
    return math.hypot(px - ax - ex * t, py - ay - ey * t)


def chevron(h, y, yc, half_w=0.19, height=0.12, stroke=0.075):
    """A bold V centred at (0, yc): two thick strokes from the top corners down to the point, the same
    width all along (distance to the stroke's line, not a vertical band)."""
    top = yc + height / 2
    bot = yc - height / 2
    d = min(_seg_d(h, y, -half_w, top, 0.0, bot), _seg_d(h, y, half_w, top, 0.0, bot))
    return d < stroke / 2


def paint_block(style, P, n, d):
    x, y, z = P
    if style == "a_top":
        c = BLUE[0] if x < 0 else BLUE[1]
        return GLINT["b"] if d < 1.0 else c
    if style == "a_bottom":
        return ORANGE[1] if x < 0 else th.shade(ORANGE[1], 0.85)
    if style == "a_edge":
        h = across(P, n) if abs(n[1]) < 0.5 else 0.0
        return GLINT[band_at(y, h)] if abs(n[1]) < 0.5 else (GLINT["b"] if n[1] > 0 else GLINT["o"])
    # a side face
    h = across(P, n)
    b = band_at(y, h)
    col = band_col(b, h)
    # one texel of seam where two bands meet
    dip = DIP * (1.0 - 2.0 * min(abs(h), 0.5))
    for edge in (BAND - dip, -BAND - dip):
        if abs(y - edge) < 0.6 / DENS:
            return th.shade(col, 0.72)
    if b == "w" and chevron(h, y, -dip * 0.5 - 0.0):
        return INK
    if b == "o":
        for k in range(3):
            yy = -0.27 - 0.065 * k
            if abs(y - yy) < 0.7 / DENS and 0.20 < abs(h) < 0.40 - 0.03 * k:
                return VENT
    return col


def paint_wheel(style, P, n, d, part_origin):
    if style in ("w_tread", "w_shoulder", "w_inner"):
        base = {"w_tread": RUBBER, "w_shoulder": (62, 62, 70), "w_inner": (24, 24, 28)}[style]
        return th.jitter(base, 2)
    if style in ("w_side", "w_rim", "w_rimwall"):
        q = th.sub(P, part_origin)
        r = math.hypot(q[0], q[1])
        a = math.atan2(q[1], q[0])
        if style == "w_rimwall":
            return (18, 18, 22)
        if style == "w_side":
            if 0.425 < r < 0.452:
                return ORANGE[0]
            return th.jitter(RUBBER, 2)
        # the rim: six spokes, the holes between them dark, a blue hub ringed white
        if r < 0.085:
            return BLUE[0] if q[0] < 0 else BLUE[1]
        if r < 0.105:
            return WHITE[0]
        if r > 0.315:
            return TITAN[0] if r < 0.33 else (220, 225, 232)
        sp = (a / (2 * math.pi) * 6) % 1.0
        width = 0.20 + 0.10 * (0.30 - r) / 0.30
        if abs(sp - 0.5) > width / 2 + 0.25 and r > 0.13:
            return (20, 20, 24)
        lit = TITAN[0] if math.sin(a * 6) > 0 else TITAN[1]
        return lit
    if style == "w_carbon":
        k = 0.85 + 0.6 * max(n[1], 0.0) - 0.2 * max(-n[1], 0.0)
        return th.shade(CARBON, k) if d >= 1.0 else th.shade(CARBON, k * 1.6)
    if style == "w_upright":
        return WHITE[0] if P[1] > -0.385 else ORANGE[0]
    if style == "w_pylon":
        # the pylon's own three bands, over its height (-0.32 .. 0.22)
        t = (P[1] + 0.32) / 0.54
        b = "b" if t > 0.66 else ("w" if t > 0.33 else "o")
        if d < 1.0:
            return GLINT[b]
        return band_col(b, P[0])
    if style == "w_pylon_face":
        t = (P[1] + 0.22) / 0.32
        b = "b" if t > 0.66 else ("w" if t > 0.33 else "o")
        if d < 1.0:
            return GLINT[b]
        if b == "w" and chevron(P[0], P[1], -0.06, half_w=0.07, height=0.05, stroke=0.03):
            return INK
        return band_col(b, -P[0])
    return (255, 0, 255)


# ── geometry ────────────────────────────────────────────────────────────────────────────────────

def ngon(r, n, phase=0.5):
    return [(r * math.cos((i + phase) * 2 * math.pi / n), r * math.sin((i + phase) * 2 * math.pi / n))
            for i in range(n)]


def ring_band(faces, ra, za, rb, zb, n, style, centre):
    """Quads between two coaxial n-gons (radius, z) round the Z axis."""
    A, B = ngon(ra, n), ngon(rb, n)
    for i in range(n):
        j = (i + 1) % n
        q = [(A[i][0], A[i][1], za), (A[j][0], A[j][1], za), (B[j][0], B[j][1], zb), (B[i][0], B[i][1], zb)]
        faces.append(th.Face(th.outward(q, centre), style, u_hint=(0, 0, 1)))


def ngon_cap(faces, r, z, n, style, centre):
    faces.append(th.Face(th.outward([(p[0], p[1], z) for p in ngon(r, n)], centre), style, u_hint=(1, 0, 0)))


def bar(faces, a, b, w, t, up, style):
    """A flat aerofoil bar from a to b: a hexagonal section w wide and t thick, its flat face along `up`."""
    ax = th.norm(th.sub(b, a))
    side = th.norm(th.cross(ax, up))
    upn = th.cross(side, ax)
    sec = [(w / 2, 0.0), (w / 4, t / 2), (-w / 4, t / 2), (-w / 2, 0.0), (-w / 4, -t / 2), (w / 4, -t / 2)]
    ra = [th.add(a, th.add(th.mul(side, s), th.mul(upn, u))) for s, u in sec]
    rb = [th.add(b, th.add(th.mul(side, s), th.mul(upn, u))) for s, u in sec]
    centre = th.mul(th.add(a, b), 0.5)
    for i in range(6):
        j = (i + 1) % 6
        faces.append(th.Face(th.outward([ra[i], ra[j], rb[j], rb[i]], centre), style, u_hint=ax))
    faces.append(th.Face(th.outward(list(ra), centre), style))
    faces.append(th.Face(th.outward(list(rb), centre), style))


def frustum(faces, back, front, z_back, z_front, side, cap):
    """A tapered box along Z: rectangle `back` (x0, x1, y0, y1) at z_back to `front` at z_front."""
    def corners(r, z):
        return [(r[0], r[2], z), (r[1], r[2], z), (r[1], r[3], z), (r[0], r[3], z)]
    A, B = corners(back, z_back), corners(front, z_front)
    centre = ((back[0] + back[1]) / 2, (back[2] + back[3]) / 2, (z_back + z_front) / 2)
    for i in range(4):
        j = (i + 1) % 4
        faces.append(th.Face(th.outward([A[i], A[j], B[j], B[i]], centre), side, u_hint=(1, 0, 0) if i % 2 == 0 else (0, 1, 0)))
    faces.append(th.Face(th.outward(B, centre), cap, u_hint=(1, 0, 0)))
    faces.append(th.Face(th.outward(A, centre), side, u_hint=(1, 0, 0)))


def build_block():
    f = []
    em.cham_box(f, (-0.5, -0.5, -0.5), (0.5, 0.5, 0.5), C, "a_side", "a_top", "a_bottom", "a_edge")
    return {"aero_block": f}, {"aero_block": (0.0, 0.0, 0.0)}


TC = (0.0, -0.385, -0.25)      # the standard wheel's tyre centre
R, W = 0.50, 0.36              # tyre radius and width
RIM_R = 0.34
N = 12
ARM_PIVOT = (0.0, -0.05, 0.28)


def build_wheel():
    body, arm, tyre = [], [], []
    # the PYLON: tapered from the hull face, bands over its height, a small chevron on its face
    frustum(body, (-0.20, 0.20, -0.32, 0.22), (-0.13, 0.13, -0.22, 0.10), 0.5, 0.28, "w_pylon", "w_pylon_face")
    # the ARM: two flat wishbones, a push rod, the upright and the axle stub
    up_top = (0.0, TC[1] + 0.17, -0.02)
    up_bot = (0.0, TC[1] - 0.13, -0.02)
    for sx in (-0.10, 0.10):
        bar(arm, (sx, 0.04, 0.28), up_top, 0.06, 0.02, (0, 1, 0), "w_carbon")
        bar(arm, (sx, -0.18, 0.28), up_bot, 0.06, 0.02, (0, 1, 0), "w_carbon")
    bar(arm, (0.0, 0.09, 0.30), th.add(up_bot, (0.0, 0.03, 0.03)), 0.035, 0.035, (1, 0, 0), "w_carbon")
    em.cham_box(arm, (-0.07, up_bot[1] - 0.03, -0.065), (0.07, up_top[1] + 0.03, 0.025), 0.02,
                "w_upright", "w_upright", "w_upright", "w_upright")
    ring_band(arm, 0.06, -0.065, 0.06, -0.07 + 0.005, 6, "w_carbon", (0, TC[1], -0.07))
    # the TYRE: a 12-sided slick with shouldered edges, the rim recessed into its outer face
    zi, zo = TC[2] + W / 2, TC[2] - W / 2          # inner (hull side) and outer faces
    sh = 0.035
    cen = TC
    def rb(ra, za, rb_, zb, st):
        ring_band(tyre, ra, za, rb_, zb, N, st, (0, 0, TC[2]))
    rb(R - sh, zo, R, zo + sh, "w_shoulder")
    rb(R, zo + sh, R, zi - sh, "w_tread")
    rb(R, zi - sh, R - sh, zi, "w_shoulder")
    rb(R - sh, zo, RIM_R, zo, "w_side")
    rb(RIM_R, zo, RIM_R, zo + 0.03, "w_rimwall")
    ngon_cap(tyre, RIM_R, zo + 0.03, N, "w_rim", (0, 0, TC[2]))
    ngon_cap(tyre, R - sh, zi, N, "w_inner", (0, 0, TC[2]))
    # tyre faces were built round (0, 0, z): move them onto the tyre's centre
    for fc in tyre:
        fc.pts = [(p[0] + TC[0], p[1] + TC[1], p[2]) for p in fc.pts]
    return ({"aero_wheel_body": body, "aero_wheel_arm": arm, "aero_wheel_tyre": tyre},
            {"aero_wheel_body": (0.0, 0.0, 0.0), "aero_wheel_arm": ARM_PIVOT, "aero_wheel_tyre": TC})


MODELS = {"aero_block": (701, build_block, 256), "aero_wheel": (702, build_wheel, 256)}


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
    seed, build, tex = MODELS[name]
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
                if name == "aero_block":
                    c = paint_block(f.style, P, n, d)
                else:
                    c = paint_wheel(f.style, P, n, d, TC if part == "aero_wheel_tyre" else (0, 0, 0))
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


for _nm, (_seed, _fn, _tex) in MODELS.items():
    em.BLOCKS[_nm] = (_seed, _em_build(_nm), _tex)
if not hasattr(em, "CHECKS"):
    em.CHECKS = {}
em.CHECKS["aero_block"] = {"cells": ((-0.5, -0.5, -0.5), (0.5, 0.5, 0.5)), "budget": 700}
em.CHECKS["aero_wheel"] = {"cells": ((-0.5, -0.9, -0.5), (0.5, 0.5, 0.5)), "budget": 700,
                           "spin": {"aero_wheel_tyre": (0, 0, 1)},
                           "origins": {"aero_wheel_tyre": TC, "aero_wheel_arm": ARM_PIVOT},
                           "solid": [((-0.20, -0.32, 0.28), (0.20, 0.22, 0.5))]}

if __name__ == "__main__":
    for nm in (sys.argv[1:] or list(MODELS)):
        make(nm)
