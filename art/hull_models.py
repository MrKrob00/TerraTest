#!/usr/bin/env python3
"""Builds the HULL blocks the way the Frame Block is built, on the shared atlas.

    python3 art/hull_models.py            -> art/out/hull.glb (one node per block)
    godot --headless --path . --script res://art/turret_import.gd -- hull
        -> blocks/meshes/hull_<part>.tres, on the atlas material every block uses

The Frame Block (Assets.glb `block_construct`) is the reference, and everything here copies it:
a solid whose every edge is chamfered by CHAMFER (0.067 m), walls standing exactly on the cell's
faces, and texels taken straight from the SAME atlas islands - the striped panel with the cross on
upright faces, the diagonal-braced panel on top and bottom, the thin strip on every chamfer. No
texture of their own: the atlas is where the frame block's look lives, and a copy would drift.

THE RULE THAT MAKES TWO BLOCKS READ AS ONE HULL: walls on the cell faces and the same small chamfer
everywhere. Two frame blocks side by side meet flat and show only a shallow bevel seam. The old
wedge did not: its side walls stood 2 cm inside the cell and the edges of its slope fell 0.2 m to
them, so a row of wedges was a row of ridges with a V-groove between every pair. Here the wedge is
the same solid as the block - a chamfered prism - with a triangle for a profile.

A LONG FACE IS TILED PER CELL: each cell's stretch of a face gets a whole panel, so Frame Block x2 is
one part that still shows its two cells, instead of one panel stretched to twice its width.

Blocks (in their anchor's axes; the scenes keep the anchor where the grid puts it):
  hull_block2  2x1x1, cells x -1 and 0          hull_block3  3x1x1, cells x -1, 0, +1
  hull_half    1x1x1, the cube cut corner to corner  hull_half2   the same triangle 2 wide, cells x -1 and 0
  hull_wedge2  1x1x2, cells z 0 and -1, full height at the back (z +0.5), edge on the ground at the front
"""
import json
import math
import os
import struct
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ATLAS = os.path.join(ROOT, "objects", "Assets_main_texture_new.png")
OUT_GLB = os.path.join(ROOT, "art", "out", "hull.glb")
TEX = 1024.0

CHAMFER = 0.5 - 0.433      # the frame block's own bevel

# Atlas islands, in pixels (x0, y0, x1, y1), read off block_construct and the artist's wedge.
SIDE = (0, 206, 23, 229)       # upright faces: striped panel with the cross
TOP = (53, 128, 89, 165)       # top and bottom: the braced panel
STRIP = (76, 171, 98, 174)     # every chamfer
CORNER = (75, 172)             # the corner triangles: one texel
SLOPE = (325, 212, 354, 282)   # the wedge's slope, tip at y0, top at y1
SLOPE_ASPECT = (SLOPE[3] - SLOPE[1]) / (SLOPE[2] - SLOPE[0])   # metres of slope one cell wide


def sub(a, b): return (a[0] - b[0], a[1] - b[1], a[2] - b[2])
def cross(a, b): return (a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0])
def dot(a, b): return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]
def norm(a):
    l = math.sqrt(dot(a, a)) or 1.0
    return (a[0] / l, a[1] / l, a[2] / l)
def lerp2(a, b, t): return (a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t)


def newell(pts):
    n = [0.0, 0.0, 0.0]
    for i, p in enumerate(pts):
        q = pts[(i + 1) % len(pts)]
        n[0] += (p[1] - q[1]) * (p[2] + q[2])
        n[1] += (p[2] - q[2]) * (p[0] + q[0])
        n[2] += (p[0] - q[0]) * (p[1] + q[1])
    return norm(tuple(n))


class Mesh:
    def __init__(self):
        self.faces = []                     # (pts, uvs) in pixels

    def add(self, pts, uvs, outward):
        """Wind CCW seen from outside (glTF front face) against a known outward direction."""
        if dot(newell(pts), outward) < 0:
            pts, uvs = list(reversed(pts)), list(reversed(uvs))
        self.faces.append((pts, uvs))


def island_uv(isl, u, v):
    return (isl[0] + (isl[2] - isl[0]) * u, isl[1] + (isl[3] - isl[1]) * v)


def span(length, full):
    """The share of an island a stretch of `length` shows, centred: a whole face shows it all, a
    half-height face shows its middle - squashing the panel would bend its pixels."""
    f = min(1.0, length / full)
    return 0.5 - f / 2, 0.5 + f / 2


def chamfered_profile(q, c):
    """Cut every corner of a sharp convex polygon by c along both edges. Returns (points, kind)
    where kind[i] says whether edge i (points i -> i+1) is a face or a chamfer."""
    n = len(q)
    pts, kind = [], []
    for i in range(n):
        a, b, p = q[i - 1], q[i], q[(i + 1) % n]
        da = math.hypot(b[0] - a[0], b[1] - a[1])
        db = math.hypot(p[0] - b[0], p[1] - b[1])
        pts.append(lerp2(b, a, c / da))
        pts.append(lerp2(b, p, c / db))
    for i in range(len(pts)):
        kind.append("chamfer" if i % 2 == 0 else "face")
    return pts, kind


def inset(q, c):
    """Offset a convex polygon's edges inward by c (the side wall inside its chamfer strips)."""
    n = len(q)
    lines = []
    cx = sum(p[0] for p in q) / n
    cy = sum(p[1] for p in q) / n
    for i in range(n):
        a, b = q[i], q[(i + 1) % n]
        dx, dy = b[0] - a[0], b[1] - a[1]
        l = math.hypot(dx, dy)
        nx, ny = dy / l, -dx / l
        if nx * (cx - a[0]) + ny * (cy - a[1]) < 0:
            nx, ny = -nx, -ny
        lines.append(((a[0] + nx * c, a[1] + ny * c), (dx, dy)))
    out = []
    for i in range(n):
        (p1, d1), (p2, d2) = lines[i - 1], lines[i]
        den = d1[0] * d2[1] - d1[1] * d2[0]
        t = ((p2[0] - p1[0]) * d2[1] - (p2[1] - p1[1]) * d2[0]) / den
        out.append((p1[0] + d1[0] * t, p1[1] + d1[1] * t))
    return out


def prism_x(m, q, x0, x1, c=CHAMFER, cell_x=1.0, slope_edge=None, side_uv=None):
    """A chamfered solid: profile q (sharp, convex, in (y, z)) swept from x0 to x1.

    Faces along X are split per cell (cell_x) and each piece gets a whole panel; upright faces take
    SIDE, flat ones TOP, the edge given by `slope_edge` (index into q) takes SLOPE. The two end
    walls are q inset by c, joined to the faces by chamfer strips, as on the frame block."""
    qc, kind = chamfered_profile(q, c)
    wall = inset(q, c)
    n = len(qc)
    xa, xb = x0 + c, x1 - c
    cells = max(1, int(round((x1 - x0) / cell_x)))
    cuts = [xa] + [x0 + k * cell_x for k in range(1, cells)] + [xb]
    cy = sum(p[0] for p in q) / len(q)
    cz = sum(p[1] for p in q) / len(q)
    for i in range(n):
        a, b = qc[i], qc[(i + 1) % n]
        mid = ((a[0] + b[0]) / 2, (a[1] + b[1]) / 2)
        out_yz = norm((0.0, mid[0] - cy, mid[1] - cz))
        edge_len = math.hypot(b[0] - a[0], b[1] - a[1])
        # The normal of the face this edge sweeps, from the edge itself (not from the centre).
        ey, ez = b[0] - a[0], b[1] - a[1]
        fn = norm((0.0, -ez, ey))
        if dot(fn, out_yz) < 0:
            fn = (0.0, ez, -ey)
            fn = norm(fn)
        is_slope = slope_edge is not None and kind[i] == "face" and (i // 2) == slope_edge
        for k in range(len(cuts) - 1):
            s0, s1 = cuts[k], cuts[k + 1]
            pts = [(s0, a[0], a[1]), (s1, a[0], a[1]), (s1, b[0], b[1]), (s0, b[0], b[1])]
            if kind[i] == "chamfer":
                uvs = [island_uv(STRIP, 0, 0), island_uv(STRIP, 1, 0), island_uv(STRIP, 1, 1),
                       island_uv(STRIP, 0, 1)]
            elif is_slope:
                # Tip end of the edge at the island's y0, as the artist's wedge maps it. A slope
                # shorter than the wedge's shows the middle of the island rather than a squashed
                # whole (the half block's 1.41 m against the island's 2.4 : 1), and every cell
                # across gets its own panel, as the other faces do.
                tip_first = a[0] < b[0]
                ca_, cb_ = span(edge_len, SLOPE_ASPECT)
                v0, v1 = (ca_, cb_) if tip_first else (cb_, ca_)
                cell0 = x0 + math.floor((s0 - x0) / cell_x + 1e-6) * cell_x
                u0, u1 = 1 - (s0 - cell0) / cell_x, 1 - (s1 - cell0) / cell_x
                uvs = [island_uv(SLOPE, u0, v0), island_uv(SLOPE, u1, v0), island_uv(SLOPE, u1, v1),
                       island_uv(SLOPE, u0, v1)]
            else:
                flat = abs(fn[1]) > 0.7
                isl = TOP if flat else SIDE
                # Split long edges per cell too (a wedge's bottom runs two cells).
                parts = max(1, int(round(edge_len / 1.0)))
                for p in range(parts):
                    ta, tb = p / parts, (p + 1) / parts
                    pa, pb = lerp2(a, b, ta), lerp2(a, b, tb)
                    ps = [(s0, pa[0], pa[1]), (s1, pa[0], pa[1]), (s1, pb[0], pb[1]), (s0, pb[0], pb[1])]
                    ea, eb = span(edge_len / parts, 1.0 - 2 * c)      # along the profile edge
                    xa_, xb_ = span(s1 - s0, 1.0 - 2 * c)              # along X
                    us = [_frame_uv(isl, flat, fn, pt, pa, pb, s0, s1, ea, eb, xa_, xb_) for pt in ps]
                    m.add(ps, us, fn)
                continue
            m.add(pts, uvs, fn)
    # End walls and the strips joining them to the faces.
    for sx, xw, xf in ((-1.0, x0, xa), (1.0, x1, xb)):
        out = (sx, 0.0, 0.0)
        wp = [(xw, p[0], p[1]) for p in wall]
        if side_uv is not None:
            uvs = side_uv(sx, wall)
        else:
            ys = [p[0] for p in wall]
            zs = [p[1] for p in wall]
            y0, y1, z0, z1 = min(ys), max(ys), min(zs), max(zs)
            isl = SIDE
            # As on block_construct's X walls: u down the wall, v along Z (+Z far on the +X wall).
            h = y1 - y0
            w = z1 - z0
            ua, ub = span(h, w) if h < w * 0.9 else (0.0, 1.0)    # a low wall shows the middle
            uvs = []
            for p in wall:
                fz = (p[1] - z0) / max(w, 1e-6)
                uvs.append(island_uv(isl, ua + (ub - ua) * (1 - (p[0] - y0) / max(h, 1e-6)),
                                     fz if sx > 0 else 1 - fz))
        m.add(wp, uvs, out)
        # Strip i joins face edge i of the swept profile to the wall edge it runs along.
        nq = len(q)
        for j in range(nq):
            fa, fb = qc[2 * j + 1], qc[(2 * j + 2) % n]         # the face edge between corners j, j+1
            wa, wb = wall[j], wall[(j + 1) % nq]
            pts = [(xf, fa[0], fa[1]), (xf, fb[0], fb[1]), (xw, wb[0], wb[1]), (xw, wa[0], wa[1])]
            mid = ((fa[0] + fb[0]) / 2, (fa[1] + fb[1]) / 2)
            ob = norm((sx, mid[0] - cy, mid[1] - cz))
            m.add(pts, [island_uv(STRIP, 0, 0), island_uv(STRIP, 1, 0), island_uv(STRIP, 1, 1),
                        island_uv(STRIP, 0, 1)], ob)
            # Corner triangle at corner j+1: the chamfer edge there and the wall vertex.
            ca, cb = qc[(2 * j + 2) % n], qc[(2 * j + 3) % n]
            wv = wall[(j + 1) % nq]
            tri = [(xf, ca[0], ca[1]), (xf, cb[0], cb[1]), (xw, wv[0], wv[1])]
            mid = ((ca[0] + cb[0]) / 2, (ca[1] + cb[1]) / 2)
            oc = norm((sx, mid[0] - cy, mid[1] - cz))
            cu = (CORNER[0] + 0.5, CORNER[1] + 0.5)
            m.add(tri, [cu, cu, cu], oc)


def _frame_uv(isl, flat, fn, pt, pa, pb, s0, s1, ea, eb, xa_, xb_):
    """UVs laid the way block_construct lays them, so the panels read the same way round.

    Top and bottom: u along +X; v along +Z on top, along -Z underneath. Upright faces: u runs down
    the face (top of the panel at the top), v along the face - towards -X on a +Z face and towards
    +X on a -Z face. The share of the island shown (ea..eb, xa_..xb_) keeps a short face's pixels
    square instead of squashing the panel."""
    fx = (pt[0] - s0) / max(s1 - s0, 1e-9)                 # 0..1 along X
    ez = (pt[1] - pa[0], pt[2] - pa[1])
    el = math.hypot(pb[0] - pa[0], pb[1] - pa[1]) or 1e-9
    fe = math.hypot(*ez) / el                               # 0..1 from pa to pb
    if flat:
        u = xa_ + (xb_ - xa_) * fx
        # v by Z: pa -> pb runs along Z one way or the other.
        z = pt[2]
        z0, z1 = min(pa[1], pb[1]), max(pa[1], pb[1])
        fz = (z - z0) / max(z1 - z0, 1e-9)
        if fn[1] < 0:
            fz = 1.0 - fz
        v = ea + (eb - ea) * fz
    else:
        y = pt[1]
        y0, y1 = min(pa[0], pb[0]), max(pa[0], pb[0])
        fy = (y1 - y) / max(y1 - y0, 1e-9)                   # 0 at the top
        u = ea + (eb - ea) * fy
        fxx = 1.0 - fx if fn[2] > 0 else fx
        v = xa_ + (xb_ - xa_) * fxx
    return island_uv(isl, u, v)


def box_profile(y0, y1, z0, z1):
    return [(y0, z0), (y0, z1), (y1, z1), (y1, z0)]


def build():
    blocks = {}
    m = Mesh(); prism_x(m, box_profile(-0.5, 0.5, -0.5, 0.5), -1.5, 0.5); blocks["hull_block2"] = m
    m = Mesh(); prism_x(m, box_profile(-0.5, 0.5, -0.5, 0.5), -1.5, 1.5); blocks["hull_block3"] = m
    # Half block: the cube cut corner to corner - full height at the back, a 45 deg slope down to
    # the front edge. x2 is the same triangle two cells WIDE (along X), like the other x2 blocks.
    half = [(-0.5, 0.5), (0.5, 0.5), (-0.5, -0.5)]
    m = Mesh(); prism_x(m, half, -0.5, 0.5, slope_edge=1); blocks["hull_half"] = m
    m = Mesh(); prism_x(m, half, -1.5, 0.5, slope_edge=1); blocks["hull_half2"] = m
    # Wedge: (y, z) triangle - back-bottom, back-top, front tip on the ground. Edge 1 (back-top ->
    # tip) is the slope.
    wedge = [(-0.5, 0.5), (0.5, 0.5), (-0.5, -1.5)]
    m = Mesh(); prism_x(m, wedge, -0.5, 0.5, slope_edge=1, side_uv=wedge_side_uv); blocks["hull_wedge2"] = m
    return blocks


def wedge_side_uv(sx, wall):
    """The artist's painted side triangle: back-top, back-bottom and tip corners of the island."""
    if sx > 0:
        top, bottom, tip = (320, 275), (294, 259), (319, 218)
    else:
        top, bottom, tip = (360, 275), (385, 259), (360, 218)
    # wall is [back-bottom, back-top, tip] in (y, z) order of the sharp profile.
    return [bottom, top, tip]


def write_glb(blocks):
    blob = bytearray()
    views, accs, meshes, nodes = [], [], [], []

    def put(data, fmt, target=None):
        off = len(blob)
        for row in data:
            blob.extend(struct.pack("<" + fmt, *(row if isinstance(row, tuple) else (row,))))
        while len(blob) % 4:
            blob.append(0)
        v = {"buffer": 0, "byteOffset": off, "byteLength": len(blob) - off}
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

    for name, m in blocks.items():
        pos, nrm, uvs, idx = [], [], [], []
        for pts, uv in m.faces:
            n = newell(pts)
            base = len(pos)
            for p, t in zip(pts, uv):
                pos.append(p)
                nrm.append(n)
                uvs.append((t[0] / TEX, t[1] / TEX))
            for k in range(1, len(pts) - 1):
                idx += [base, base + k, base + k + 1]
        a_pos = acc(put(pos, "3f", 34962), 5126, len(pos), "VEC3",
                    [min(p[i] for p in pos) for i in range(3)], [max(p[i] for p in pos) for i in range(3)])
        a_nrm = acc(put(nrm, "3f", 34962), 5126, len(nrm), "VEC3")
        a_uv = acc(put(uvs, "2f", 34962), 5126, len(uvs), "VEC2")
        a_idx = acc(put(idx, "H", 34963), 5123, len(idx), "SCALAR")
        meshes.append({"name": name, "primitives": [{
            "attributes": {"POSITION": a_pos, "NORMAL": a_nrm, "TEXCOORD_0": a_uv},
            "indices": a_idx, "material": 0}]})
        nodes.append({"name": name, "mesh": len(meshes) - 1})
        print("%s: %d triangles" % (name, len(idx) // 3))
    png = open(ATLAS, "rb").read()
    off = len(blob)
    blob.extend(png)
    while len(blob) % 4:
        blob.append(0)
    views.append({"buffer": 0, "byteOffset": off, "byteLength": len(png)})
    gltf = {
        "asset": {"version": "2.0", "generator": "art/hull_models.py"},
        "extensionsUsed": ["KHR_materials_unlit"],
        "scene": 0,
        "scenes": [{"nodes": list(range(len(nodes)))}],
        "nodes": nodes,
        "meshes": meshes,
        "materials": [{"name": "main", "doubleSided": True,
                       "extensions": {"KHR_materials_unlit": {}},
                       "pbrMetallicRoughness": {"baseColorTexture": {"index": 0},
                                                "metallicFactor": 0, "roughnessFactor": 0.9}}],
        "textures": [{"source": 0, "sampler": 0}],
        "samplers": [{"magFilter": 9728, "minFilter": 9986}],
        "images": [{"bufferView": len(views) - 1, "mimeType": "image/png", "name": "Assets_main_texture_new"}],
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
    write_glb(build())
