#!/usr/bin/env python3
"""THE AERO TOOLKIT: what every Aero model generator stands on (art/aero_<name>.py). Infrastructure
only - the palette, a painter that works in BLOCK SPACE, the rasteriser and the glb writer - so the
look is decided in the model files, not here.

    import aero_kit as ak
    def build():            -> ({part: [th.Face, ...]}, {part: (x, y, z) pivot})   faces in block space
    def paint(style, P, n, d, part, origin):
        -> (r, g, b) for the texel at block-space point P on a face of normal n, d texels from the
           face's edge (d < 1: the edge line), on `part` whose pivot is `origin`
    ak.model("aero_x_block", seed, build, paint, tex=256, dens=ak.DENS)
    ak.make("aero_x_block")  -> objects/<name>_texture.png + art/out/<name>.glb + <name>_poses.json

WHY BLOCK SPACE: the faction's livery is BANDS AND STRIPES that run across faces and on into the next
block - a band at a fixed height, a stripe along the top - and a painter that only knows a face's own
(x, y) cannot keep a line straight round a corner. Here every texel knows where it stands in the
block, so a band is `if P[1] > 0.28`.

A RIG is a preview of several models put together - a short machine of blocks and wheels - built
from the models' own faces, each painted by its own model's painter in its own space:
    ak.rig("aero_x_rig", [("aero_x_block", ak.place()), ("aero_x_wheel", ak.place(yaw=90, at=(-1,0,0)))])
Rigs are pictures only; they are never imported.

The texture is painted at DENS texels a metre - the game's 38-48 (docs/ART_STYLE.md) - and nearest-
filtered, so a line is a whole texel or nothing.
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
ROOT = th.ROOT
PAD = th.PAD
DENS = 48.0
C = 0.035                      # the Aero chamfer (docs/ART_STYLE.md): razor edges, 1-2 texels

# the emblem's three bands (images/faction_aero.png): blue top, white middle, orange bottom
BLUE = (16, 176, 226)
WHITE = (240, 242, 246)
ORANGE = (246, 96, 18)
INK = (18, 18, 24)             # the emblem's outline and wing
CARBON = ((30, 31, 36), (40, 41, 47))   # a carbon weave's two tones
RUBBER = (34, 33, 38)
METAL = (92, 96, 108)          # bare machined metal (hubs, bolts, rods)
SUN = th.norm((-0.45, 0.80, -0.40))     # the painted light: from the front, up and to the left


def lit(n, lo=0.80, hi=0.30, under=0.10):
    """The painted light for a face of normal n (the blocks are unshaded, so this is all the shading
    they get): `lo` facing away, `lo + hi` facing the sun, a little darker underneath."""
    return lo + hi * max(th.dot(n, SUN), 0.0) - under * max(-n[1], 0.0)


def tone(c, k):
    return th.shade(c, k)


def mix(a, b, t):
    return tuple(a[i] * (1 - t) + b[i] * t for i in range(3))


def jitter(c, amt=2):
    return th.jitter(c, amt)


def carbon(P, n, k=1.0, cell=0.042):
    """A carbon weave in block space: 2 x 2 texel checks of two dark tones, laid on the face's own
    plane (so it does not smear on a slope)."""
    a = th.norm(th.cross(n, (0, 1, 0))) if abs(n[1]) < 0.9 else (1, 0, 0)
    b = th.cross(n, a)
    u = th.dot(P, a) / cell
    v = th.dot(P, b) / cell
    c = CARBON[(int(math.floor(u)) + int(math.floor(v))) & 1]
    return tone(c, k)


# ── geometry helpers ─────────────────────────────────────────────────────────────────────────────

def face(faces, pts, inside, style, u_hint=None):
    """A polygon wound to face away from `inside`."""
    faces.append(th.Face(th.outward(pts, inside), style, u_hint=u_hint))


def _area(poly):
    return sum(poly[i][0] * poly[(i + 1) % len(poly)][1] - poly[(i + 1) % len(poly)][0] * poly[i][1]
               for i in range(len(poly))) / 2.0


def ear_clip(poly):
    """Triangles (index triples) of a simple 2D polygon, either winding."""
    idx = list(range(len(poly)))
    if _area(poly) < 0:
        idx.reverse()
    out = []

    def cr(o, x, y):
        return (x[0] - o[0]) * (y[1] - o[1]) - (x[1] - o[1]) * (y[0] - o[0])

    guard = 0
    while len(idx) > 3 and guard < 10000:
        guard += 1
        for k in range(len(idx)):
            a, b, c = idx[k - 1], idx[k], idx[(k + 1) % len(idx)]
            if cr(poly[a], poly[b], poly[c]) <= 1e-12:
                continue
            if any(cr(poly[a], poly[b], poly[p]) >= 0 and cr(poly[b], poly[c], poly[p]) >= 0
                   and cr(poly[c], poly[a], poly[p]) >= 0 for p in idx if p not in (a, b, c)):
                continue
            out.append((a, b, c))
            idx.pop(k)
            break
        else:
            break
    if len(idx) == 3:
        out.append(tuple(idx))
    return out


def extrude(faces, poly, axis, a0, a1, cap_styles, wall_styles, convex=False):
    """A simple polygon in the plane across `axis` ('x', 'y' or 'z') extruded from a0 to a1. `poly` is
    in the other two axes in order (x: (y, z); y: (x, z); z: (x, y)). Caps are ear-clipped (one face
    when `convex`); wall_styles is one style or one per edge (None leaves it out)."""
    ax = "xyz".index(axis)
    oth = [i for i in range(3) if i != ax]

    def P(q, a):
        p = [0.0, 0.0, 0.0]
        p[ax] = a
        p[oth[0]], p[oth[1]] = q[0], q[1]
        return tuple(p)

    cx = sum(q[0] for q in poly) / len(poly)
    cy = sum(q[1] for q in poly) / len(poly)
    sign = 1.0 if _area(poly) > 0 else -1.0
    mid = (a0 + a1) / 2
    for a, st in zip((a0, a1), cap_styles):
        if not st:
            continue
        tris = [tuple(range(len(poly)))] if convex else ear_clip(poly)
        for tri in tris:
            pts = [P(poly[i], a) for i in tri]
            c = P((cx, cy), a)
            inside = list(c)
            inside[ax] = mid
            face(faces, pts, tuple(inside), st, u_hint=tuple(1.0 if i == oth[0] else 0.0 for i in range(3)))
    n = len(poly)
    for i in range(n):
        st = wall_styles[i] if isinstance(wall_styles, (list, tuple)) else wall_styles
        if not st:
            continue
        qa, qb = poly[i], poly[(i + 1) % n]
        ex, ey = qb[0] - qa[0], qb[1] - qa[1]
        L = math.hypot(ex, ey)
        nx, ny = -ey / L * sign, ex / L * sign       # into the polygon
        m = ((qa[0] + qb[0]) / 2 + nx * 0.01, (qa[1] + qb[1]) / 2 + ny * 0.01)
        face(faces, [P(qa, a0), P(qb, a0), P(qb, a1), P(qa, a1)], P(m, mid), st,
             u_hint=P((ex, ey), 0.0))


def ring(c, axis_u, axis_v, r, n, phase=0.5):
    """n points round c in the plane of the unit vectors axis_u, axis_v."""
    return [th.add(c, th.add(th.mul(axis_u, r * math.cos((i + phase) * 2 * math.pi / n)),
                             th.mul(axis_v, r * math.sin((i + phase) * 2 * math.pi / n)))) for i in range(n)]


def loft(faces, rings, styles, centre, cap0=None, cap1=None):
    """Quads between consecutive rings of equal length (a lathe, a tube, a swept section), wound away
    from `centre`; styles is one style or one per ring gap. Caps are the first and last ring as faces."""
    for i in range(len(rings) - 1):
        st = styles[i] if isinstance(styles, (list, tuple)) else styles
        if not st:
            continue
        a, b = rings[i], rings[i + 1]
        m = len(a)
        for j in range(m):
            k = (j + 1) % m
            face(faces, [a[j], a[k], b[k], b[j]], centre, st)
    for r, st, other in ((rings[0], cap0, rings[1]), (rings[-1], cap1, rings[-2])):
        if st:
            c = th.mul(tuple(map(sum, zip(*r))), 1.0 / len(r))
            o = th.mul(tuple(map(sum, zip(*other))), 1.0 / len(other))
            face(faces, list(r), th.add(c, th.mul(th.norm(th.sub(o, c)), 0.05)), st)


def cbox(faces, lo, hi, c, styles):
    """A box chamfered by c on all twelve edges (26 faces). styles: a dict with keys '+x' '-x' '+y'
    '-y' '+z' '-z' for the six faces and 'edge' for every chamfer (or 'edge+y' / 'edge-y' / 'edge'
    for the chamfers touching the top, the bottom, and the vertical ones); a missing face key falls
    back to 'side'. A face whose style is None is left out (it lies against something)."""
    x0, y0, z0 = lo
    x1, y1, z1 = hi
    centre = ((x0 + x1) / 2, (y0 + y1) / 2, (z0 + z1) / 2)
    lo2 = (x0 + c, y0 + c, z0 + c)
    hi2 = (x1 - c, y1 - c, z1 - c)

    def st(key):
        return styles.get(key, styles.get("side"))

    # the six faces, each inset by c on its plane
    F = {
        "+x": [(x1, lo2[1], lo2[2]), (x1, hi2[1], lo2[2]), (x1, hi2[1], hi2[2]), (x1, lo2[1], hi2[2])],
        "-x": [(x0, lo2[1], lo2[2]), (x0, hi2[1], lo2[2]), (x0, hi2[1], hi2[2]), (x0, lo2[1], hi2[2])],
        "+y": [(lo2[0], y1, lo2[2]), (hi2[0], y1, lo2[2]), (hi2[0], y1, hi2[2]), (lo2[0], y1, hi2[2])],
        "-y": [(lo2[0], y0, lo2[2]), (hi2[0], y0, lo2[2]), (hi2[0], y0, hi2[2]), (lo2[0], y0, hi2[2])],
        "+z": [(lo2[0], lo2[1], z1), (hi2[0], lo2[1], z1), (hi2[0], hi2[1], z1), (lo2[0], hi2[1], z1)],
        "-z": [(lo2[0], lo2[1], z0), (hi2[0], lo2[1], z0), (hi2[0], hi2[1], z0), (lo2[0], hi2[1], z0)],
    }
    hints = {"+x": (0, 0, -1), "-x": (0, 0, 1), "+y": (1, 0, 0), "-y": (1, 0, 0), "+z": (1, 0, 0), "-z": (-1, 0, 0)}
    for k, pts in F.items():
        if st(k):
            face(faces, pts, centre, st(k), u_hint=hints[k])
    xs, ys, zs = (x0, x1), (y0, y1), (z0, z1)
    ix, iy, iz = (lo2[0], hi2[0]), (lo2[1], hi2[1]), (lo2[2], hi2[2])
    # edges along X
    for a in (0, 1):
        for b in (0, 1):
            s = styles.get("edge+y" if a else "edge-y", styles.get("edge"))
            if s:
                face(faces, [(ix[0], ys[a], iz[b]), (ix[1], ys[a], iz[b]), (ix[1], iy[a], zs[b]), (ix[0], iy[a], zs[b])],
                     centre, s, u_hint=(1, 0, 0))
    # edges along Z
    for a in (0, 1):
        for b in (0, 1):
            s = styles.get("edge+y" if a else "edge-y", styles.get("edge"))
            if s:
                face(faces, [(xs[b], iy[a], iz[0]), (xs[b], iy[a], iz[1]), (ix[b], ys[a], iz[1]), (ix[b], ys[a], iz[0])],
                     centre, s, u_hint=(0, 0, 1))
    # vertical edges
    for a in (0, 1):
        for b in (0, 1):
            s = styles.get("edge|", styles.get("edge"))
            if s:
                face(faces, [(xs[a], iy[0], iz[b]), (xs[a], iy[1], iz[b]), (ix[a], iy[1], zs[b]), (ix[a], iy[0], zs[b])],
                     centre, s, u_hint=(0, 1, 0))
    # corner triangles
    for a in (0, 1):
        for b in (0, 1):
            for e in (0, 1):
                s = styles.get("edge+y" if b else "edge-y", styles.get("edge"))
                if s:
                    face(faces, [(xs[a], iy[b], iz[e]), (ix[a], ys[b], iz[e]), (ix[a], iy[b], zs[e])], centre, s)


# ── models, rasterising and the glb ───────────────────────────────────────────────────────────────

MODELS = {}                    # name -> dict(seed, build, paint, tex, dens)
RIGS = {}                      # name -> members


def model(name, seed, build, paint, tex=256, dens=DENS):
    MODELS[name] = {"seed": seed, "build": build, "paint": paint, "tex": tex, "dens": dens}
    em.BLOCKS[name] = (seed, _em_build(name), tex)


def place(yaw=0.0, at=(0.0, 0.0, 0.0), mirror_x=False, pitch=0.0):
    """A placement for a rig member: mirror across X first (a wheel for the other side), then pitch
    about X, then yaw about Y (degrees), then move to `at`."""
    m = [[-1.0 if mirror_x else 1.0, 0.0, 0.0], [0.0, 1.0, 0.0], [0.0, 0.0, 1.0]]
    p = math.radians(pitch)
    cp, sp = math.cos(p), math.sin(p)
    rxm = [[1, 0, 0], [0, cp, -sp], [0, sp, cp]]
    y = math.radians(yaw)
    cy, sy = math.cos(y), math.sin(y)
    rym = [[cy, 0, sy], [0, 1, 0], [-sy, 0, cy]]

    def mm(A, B):
        return [[sum(A[i][k] * B[k][j] for k in range(3)) for j in range(3)] for i in range(3)]
    return (mm(rym, mm(rxm, m)), tuple(at))


def rig(name, members, tex=1024, ground=None, extra=None):
    """`extra` goes into the rest pose as it is: "_centre" [x, y, z] for the camera, "_scenes"
    [[res path, 12 floats], ...] for game scenes stood beside it (a Falsus block and wheel for scale)."""
    RIGS[name] = {"members": members, "tex": tex, "ground": ground, "extra": extra or {}}


def _apply(M, t, p):
    return tuple(sum(M[i][k] * p[k] for k in range(3)) + t[i] for i in range(3))


def _basis(f):
    n = th.norm(th.newell(f.pts))
    u = f.u_hint or (1, 0, 0)
    u = th.sub(u, th.mul(n, th.dot(u, n)))
    if th.dot(u, u) < 1e-6:
        u = th.sub((0, 1, 0), th.mul(n, th.dot((0, 1, 0), n)))
        if th.dot(u, u) < 1e-6:
            u = th.sub((1, 0, 0), th.mul(n, th.dot((1, 0, 0), n)))
    u = th.norm(u)
    v = th.mul(th.cross(n, u), -1)
    return n, u, v


def _build(name):
    """A model's parts as (parts, origins), every face tagged with how to paint it."""
    m = MODELS[name]
    random.seed(m["seed"])
    th.random.seed(m["seed"])
    parts, origins = m["build"]()
    for part, faces in parts.items():
        for f in faces:
            f.paint = m["paint"]
            f.part = part
            f.xf = None
            f.org = origins.get(part, (0.0, 0.0, 0.0))
    return parts, origins


def _rasterise(parts, name, tex, dens):
    img = Image.new("RGB", (tex, tex), (0, 0, 0))
    pk = th.Packer(tex)
    todo = []
    for part, faces in parts.items():
        for f in faces:
            n, u, v = _basis(f)
            p0 = f.pts[0]
            pts2 = [(th.dot(th.sub(p, p0), u) * dens, th.dot(th.sub(p, p0), v) * dens) for p in f.pts]
            mx, my = min(p[0] for p in pts2), min(p[1] for p in pts2)
            pts2 = [(p[0] - mx, p[1] - my) for p in pts2]
            w = max(1, int(math.ceil(max(p[0] for p in pts2))))
            h = max(1, int(math.ceil(max(p[1] for p in pts2))))
            todo.append((h, w, f, n, u, v, p0, mx, my, pts2))
    todo.sort(key=lambda t: (-t[0], -t[1]))
    px_ = img.load()
    for h, w, f, n, u, v, p0, mx, my, pts2 in todo:
        rect = pk.take(w, h)
        x0, y0 = rect[0], rect[1]
        # paint in the model's own space (a rig member is placed by f.xf)
        if f.xf:
            M, t = f.xf
            Mt = [[M[j][i] for j in range(3)] for i in range(3)]
            to_local = lambda P: tuple(sum(Mt[i][k] * (P[k] - t[k]) for k in range(3)) for i in range(3))
            nl = tuple(sum(Mt[i][k] * n[k] for k in range(3)) for i in range(3))
        else:
            to_local = lambda P: P
            nl = n
        for yy in range(-PAD, h + PAD):
            for xx in range(-PAD, w + PAD):
                px, py = xx + 0.5, yy + 0.5
                P = th.add(p0, th.add(th.mul(u, (px + mx) / dens), th.mul(v, (py + my) / dens)))
                d = th.dist_to_edges(min(max(px, 0), w), min(max(py, 0), h), pts2)
                c = f.paint(f.style, to_local(P), nl, d, f.part, f.org)
                if c is None:
                    c = (255, 0, 255)
                px_[x0 + xx, y0 + yy] = tuple(max(0, min(255, int(v_))) for v_ in c)
        f.uv = [(x0 + p[0], y0 + p[1]) for p in pts2]
    img.save(th.OUT_PNG % name)
    return pk


def make(name, states=None):
    """Build, paint and write a model (or a rig): the texture, the glb (one node per part, standing at
    its pivot) and the poses file the picture harness reads. `states` is {state: {part: Transform3D
    list}} (see art/falsus_wheels.py for the arithmetic); by default one "rest" state."""
    if name in RIGS:
        return _make_rig(name)
    m = MODELS[name]
    parts, origins = _build(name)
    pk = _rasterise(parts, name, m["tex"], m["dens"])
    write_glb(parts, origins, name, m["tex"])
    poses = states or {"rest": {}}
    with open(os.path.join(ROOT, "art", "out", name + "_poses.json"), "w") as fh:
        json.dump(poses, fh)
    total = 0
    for part, faces in parts.items():
        t = sum(len(fc.pts) - 2 for fc in faces)
        total += t
        print("  %-28s %4d triangles" % (part, t))
    print("%s: %d triangles, texture %dx%d, rows used to %d px" % (name, total, m["tex"], m["tex"], pk.y + pk.row_h))
    return parts


def _make_rig(name):
    r = RIGS[name]
    parts = {}
    for i, (member, (M, t)) in enumerate(r["members"]):
        mp, origins = _build(member)
        det = (M[0][0] * (M[1][1] * M[2][2] - M[1][2] * M[2][1]) - M[0][1] * (M[1][0] * M[2][2] - M[1][2] * M[2][0])
               + M[0][2] * (M[1][0] * M[2][1] - M[1][1] * M[2][0]))
        for part, faces in mp.items():
            for f in faces:
                f.pts = [_apply(M, t, p) for p in f.pts]
                if det < 0:
                    f.pts = list(reversed(f.pts))
                f.xf = (M, t)
                if f.u_hint:
                    f.u_hint = tuple(sum(M[i2][k] * f.u_hint[k] for k in range(3)) for i2 in range(3))
            parts["%s_%d_%s" % (member, i, part)] = faces
    pk = _rasterise(parts, name, r["tex"], DENS)
    write_glb(parts, {}, name, r["tex"])
    with open(os.path.join(ROOT, "art", "out", name + "_poses.json"), "w") as fh:
        st = {"rest": {}}
        if r["ground"] is not None:
            st["rest"]["_ground"] = r["ground"]
        st["rest"].update(r["extra"])
        json.dump(st, fh)
    print("%s: rig of %d, texture rows used to %d px" % (name, len(r["members"]), pk.y + pk.row_h))


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
            n = th.norm(th.newell(f.pts))
            base = len(pos)
            for p, t in zip(f.pts, f.uv):
                pos.append(th.sub(p, o))
                nrm.append(n)
                uvs.append((t[0] / tex, t[1] / tex))
            for k in range(1, len(f.pts) - 1):
                idx += [base, base + k, base + k + 1]
        if not pos:
            continue
        a_pos = acc(put(pos, "3f", 34962), 5126, len(pos), "VEC3",
                    [min(p[i] for p in pos) for i in range(3)], [max(p[i] for p in pos) for i in range(3)])
        a_nrm = acc(put(nrm, "3f", 34962), 5126, len(nrm), "VEC3")
        a_uv = acc(put(uvs, "2f", 34962), 5126, len(uvs), "VEC2")
        ifmt, ictype = ("H", 5123) if len(pos) < 65536 else ("I", 5125)
        a_idx = acc(put(idx, ifmt, 34963), ictype, len(idx), "SCALAR")
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
        "asset": {"version": "2.0", "generator": "art/aero_kit.py"},
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


def _em_build(name):
    """For art/model_check.py: the parts' faces in each part's own space (about its pivot)."""
    def fn(pk, img):
        parts, origins = MODELS[name]["build"]()
        for part, faces in parts.items():
            o = origins.get(part, (0.0, 0.0, 0.0))
            for fc in faces:
                fc.pts = [th.sub(p, o) for p in fc.pts]
        return parts
    return fn


if not hasattr(em, "CHECKS"):
    em.CHECKS = {}
