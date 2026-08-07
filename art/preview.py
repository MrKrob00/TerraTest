#!/usr/bin/env python3
"""Софтверный превью-рендер сгенерированного блока — чтобы видеть результат
до запуска Godot. Z-буфер, плоская закраска, выборка атласа nearest."""

import math
import os
import struct
import sys
import zlib

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from blockgen import ATLAS, chamfered_box, face_uvs, orient_outward, side_cell, top_cell, bottom_cell, CELL, CELL_SIDE, CELL_TOP, CELL_BOTTOM

W = H = 320
BG = (36, 38, 46)
LIGHT = (-0.45, 0.78, 0.44)
AMBIENT = 0.52


def atlas_pixels():
    px = [[(0, 0, 0)] * ATLAS for _ in range(ATLAS)]
    for cell, data in ((CELL_SIDE, side_cell()), (CELL_TOP, top_cell()), (CELL_BOTTOM, bottom_cell())):
        cx, cy = cell
        for y in range(CELL):
            for x in range(CELL):
                px[cy * CELL + y][cx * CELL + x] = data[y][x]
    return px


def look_at(eye, target):
    fz = [target[i] - eye[i] for i in range(3)]
    n = math.dist(eye, target)
    fz = [c / n for c in fz]
    up = (0.0, 1.0, 0.0)
    fx = [fz[1] * up[2] - fz[2] * up[1], fz[2] * up[0] - fz[0] * up[2], fz[0] * up[1] - fz[1] * up[0]]
    n = math.sqrt(sum(c * c for c in fx))
    fx = [c / n for c in fx]
    fy = [fx[1] * fz[2] - fx[2] * fz[1], fx[2] * fz[0] - fx[0] * fz[2], fx[0] * fz[1] - fx[1] * fz[0]]
    return fx, fy, fz


def render(path, eye=(1.95, 1.25, 2.75)):
    tex = atlas_pixels()
    fx, fy, fz = look_at(eye, (0.0, 0.0, 0.0))
    focal = 1.0 / math.tan(math.radians(26.0) * 0.5)

    color = [[BG] * W for _ in range(H)]
    depth = [[1e9] * W for _ in range(H)]

    for poly in chamfered_box():
        poly, normal = orient_outward(poly)
        uvs = face_uvs(poly, normal)
        lam = max(0.0, sum(normal[i] * LIGHT[i] for i in range(3)))
        shade = AMBIENT + (1.0 - AMBIENT) * lam

        proj = []
        for x, y, z in poly:
            rel = (x - eye[0], y - eye[1], z - eye[2])
            cx = sum(rel[i] * fx[i] for i in range(3))
            cy = sum(rel[i] * fy[i] for i in range(3))
            cz = sum(rel[i] * fz[i] for i in range(3))
            if cz <= 0.01:
                proj = None
                break
            proj.append(((cx * focal / cz * 0.5 + 0.5) * W, (0.5 - cy * focal / cz * 0.5) * H, cz))
        if proj is None:
            continue

        for c in range(1, len(proj) - 1):
            tri = (proj[0], proj[c], proj[c + 1])
            tuv = (uvs[0], uvs[c], uvs[c + 1])
            raster(color, depth, tri, tuv, tex, shade)

    write_png(path, color)


def raster(color, depth, tri, tuv, tex, shade):
    (x0, y0, z0), (x1, y1, z1), (x2, y2, z2) = tri
    area = (x1 - x0) * (y2 - y0) - (x2 - x0) * (y1 - y0)
    if abs(area) < 1e-9:
        return
    lo_x = max(0, int(min(x0, x1, x2)))
    hi_x = min(W - 1, int(max(x0, x1, x2)) + 1)
    lo_y = max(0, int(min(y0, y1, y2)))
    hi_y = min(H - 1, int(max(y0, y1, y2)) + 1)

    for py in range(lo_y, hi_y + 1):
        for px in range(lo_x, hi_x + 1):
            sx, sy = px + 0.5, py + 0.5
            w0 = ((x1 - sx) * (y2 - sy) - (x2 - sx) * (y1 - sy)) / area
            w1 = ((x2 - sx) * (y0 - sy) - (x0 - sx) * (y2 - sy)) / area
            w2 = 1.0 - w0 - w1
            if w0 < 0.0 or w1 < 0.0 or w2 < 0.0:
                continue
            z = w0 * z0 + w1 * z1 + w2 * z2
            if z >= depth[py][px]:
                continue
            depth[py][px] = z
            u = w0 * tuv[0][0] + w1 * tuv[1][0] + w2 * tuv[2][0]
            v = w0 * tuv[0][1] + w1 * tuv[1][1] + w2 * tuv[2][1]
            tx = min(ATLAS - 1, max(0, int(u * ATLAS)))
            ty = min(ATLAS - 1, max(0, int(v * ATLAS)))
            r, g, b = tex[ty][tx]
            color[py][px] = (min(255, int(r * shade)), min(255, int(g * shade)), min(255, int(b * shade)))


def write_png(path, rows):
    raw = b""
    for row in rows:
        raw += b"\x00" + bytes(v for px in row for v in px)

    def chunk(tag, data):
        body = tag + data
        return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)

    blob = b"\x89PNG\r\n\x1a\n"
    blob += chunk(b"IHDR", struct.pack(">IIBBBBB", len(rows[0]), len(rows), 8, 2, 0, 0, 0))
    blob += chunk(b"IDAT", zlib.compress(raw, 9))
    blob += chunk(b"IEND", b"")
    with open(path, "wb") as f:
        f.write(blob)


if __name__ == "__main__":
    out = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "objects", "gen"))
    render(os.path.join(out, "preview_armor_block.png"))
    print("превью готово")
