#!/usr/bin/env python3
"""Генератор лоу-поли блоков WorldTech: меш (.obj) + пиксельный атлас (.png).

Спецификация стиля (общая для всех блоков):
  габарит      0.96 в ячейке 1.0  — зазор 0.02 даёт видимый шов между блоками
  фаска        0.10 на всех рёбрах
  нормали      плоские (по грани)
  тексель      16 пикселей на мировую единицу — совпадает с землёй
               (PIXELS_PER_TILE = 16.0 в addons/LiteTerrain/glsl.gdshader)
  атлас        ячейки 16x16, выборка в центр текселя, мипы не нужны

Зависимостей нет — только стандартная библиотека.
"""

import os
import struct
import zlib

HALF = 0.48          # половина габарита (блок 0.96 в ячейке 1.0)
CHAMFER = 0.10       # срез ребра
INNER = HALF - CHAMFER

CELL = 16            # тексель-ячейка грани
ATLAS = 32           # атлас 2x2 ячейки

# Ячейки атласа: (столбец, строка)
CELL_SIDE = (0, 0)
CELL_TOP = (1, 0)
CELL_BOTTOM = (0, 1)

# Палитра. Сине-серый сланец — новое семейство, добавлено под блок корпуса.
SLATE_RIM = (132, 140, 165)
SLATE_LIGHT = (110, 118, 143)
SLATE_DARK = (88, 95, 119)
CREAM = (226, 224, 212)

# Метка точки крепления. Кольцо 4x4 центрируется точно (6..9 при 16 текселях),
# ряды 2..5 — над кремовой полосой, в светлой зоне.
MARK_COL = SLATE_RIM
MARK_TOP = 2
MARK_LEFT = 6


def chamfered_box():
    """Грани скошенного куба: 6 площадок + 12 рёбер + 8 углов = 44 треугольника."""
    faces = []

    # 6 основных площадок
    for axis in range(3):
        for sign in (-1, 1):
            quad = []
            for a in (-INNER, INNER):
                for b in (-INNER, INNER):
                    p = [0.0, 0.0, 0.0]
                    p[axis] = sign * HALF
                    p[(axis + 1) % 3] = a
                    p[(axis + 2) % 3] = b
                    quad.append(tuple(p))
            # порядок по кольцу, а не змейкой
            quad = [quad[0], quad[1], quad[3], quad[2]]
            faces.append(quad)

    # 12 рёберных полос
    for i in range(3):
        for j in range(i + 1, 3):
            k = 3 - i - j
            for si in (-1, 1):
                for sj in (-1, 1):
                    quad = []
                    for sk in (-1, 1):
                        for lead in (i, j):
                            p = [0.0, 0.0, 0.0]
                            p[i] = si * (HALF if lead == i else INNER)
                            p[j] = sj * (HALF if lead == j else INNER)
                            p[k] = sk * INNER
                            quad.append(tuple(p))
                    quad = [quad[0], quad[1], quad[3], quad[2]]
                    faces.append(quad)

    # 8 угловых треугольников
    for sx in (-1, 1):
        for sy in (-1, 1):
            for sz in (-1, 1):
                s = (sx, sy, sz)
                tri = []
                for lead in range(3):
                    p = [s[a] * (HALF if a == lead else INNER) for a in range(3)]
                    tri.append(tuple(p))
                faces.append(tri)

    return faces


def newell_normal(poly):
    nx = ny = nz = 0.0
    n = len(poly)
    for idx in range(n):
        x0, y0, z0 = poly[idx]
        x1, y1, z1 = poly[(idx + 1) % n]
        nx += (y0 - y1) * (z0 + z1)
        ny += (z0 - z1) * (x0 + x1)
        nz += (x0 - x1) * (y0 + y1)
    length = (nx * nx + ny * ny + nz * nz) ** 0.5
    return (nx / length, ny / length, nz / length)


def orient_outward(poly):
    """Тело выпуклое и центрировано, поэтому наружу = в сторону центроида грани."""
    normal = newell_normal(poly)
    cx = sum(p[0] for p in poly) / len(poly)
    cy = sum(p[1] for p in poly) / len(poly)
    cz = sum(p[2] for p in poly) / len(poly)
    if normal[0] * cx + normal[1] * cy + normal[2] * cz < 0.0:
        poly = list(reversed(poly))
        normal = newell_normal(poly)
    return poly, normal


def cell_uv(cell, u, v):
    """Выборка в ЦЕНТР текселя: край ячейки при nearest ушёл бы в соседнюю."""
    cx, cy = cell
    au = (cx * CELL + 0.5 + u * (CELL - 1)) / ATLAS
    av = (cy * CELL + 0.5 + v * (CELL - 1)) / ATLAS
    return au, av


def face_uvs(poly, normal):
    """UV считаются из МИРОВОЙ позиции, а не по грани — тогда полоса непрерывно
    продолжается через фаски, а не обрывается на каждом ребре."""
    span = 2.0 * HALF
    out = []
    if abs(normal[1]) > 0.999:
        cell = CELL_TOP if normal[1] > 0.0 else CELL_BOTTOM
        for x, y, z in poly:
            u = (x + HALF) / span
            v = (z + HALF) / span
            if normal[1] < 0.0:
                v = 1.0 - v
            out.append(cell_uv(cell, min(max(u, 0.0), 1.0), min(max(v, 0.0), 1.0)))
        return out

    horizontal_x = abs(normal[0]) >= abs(normal[2])
    for x, y, z in poly:
        v = (HALF - y) / span
        if horizontal_x:
            u = (z + HALF) / span
            if normal[0] > 0.0:
                u = 1.0 - u
        else:
            u = (x + HALF) / span
            if normal[2] < 0.0:
                u = 1.0 - u
        out.append(cell_uv(CELL_SIDE, min(max(u, 0.0), 1.0), min(max(v, 0.0), 1.0)))
    return out


def write_obj(path, name):
    faces = chamfered_box()
    verts, uvs, norms, lines = [], [], [], []
    tris = 0

    for poly in faces:
        poly, normal = orient_outward(poly)
        uv = face_uvs(poly, normal)
        norms.append(normal)
        ni = len(norms)
        idx = []
        for p, t in zip(poly, uv):
            verts.append(p)
            uvs.append(t)
            idx.append(len(verts))
        for c in range(1, len(idx) - 1):
            lines.append((idx[0], idx[c], idx[c + 1], ni))
            tris += 1

    with open(path, "w") as f:
        f.write("# WorldTech low-poly block, generated by art/blockgen.py\n")
        f.write(f"o {name}\n")
        for x, y, z in verts:
            f.write(f"v {x:.5f} {y:.5f} {z:.5f}\n")
        for u, v in uvs:
            f.write(f"vt {u:.6f} {1.0 - v:.6f}\n")   # OBJ считает V снизу
        for x, y, z in norms:
            f.write(f"vn {x:.5f} {y:.5f} {z:.5f}\n")
        for a, b, c, n in lines:
            f.write(f"f {a}/{a}/{n} {b}/{b}/{n} {c}/{c}/{n}\n")

    return len(faces), tris, len(verts)


def stamp_mark(rows, top, left, col, size=4):
    """Метка точки крепления: квадратное кольцо size x size без заливки.
    Кольцо, а не сплошной квадрат — на 16 текселях контур читается, пятно нет."""
    for y in range(size):
        for x in range(size):
            edge = y in (0, size - 1) or x in (0, size - 1)
            if edge:
                rows[top + y][left + x] = col


def side_cell():
    rows = []
    for y in range(CELL):
        if y == 0:
            col = SLATE_RIM
        elif y <= 6:
            col = SLATE_LIGHT
        elif y <= 8:
            col = CREAM
        else:
            col = SLATE_DARK
        rows.append([col] * CELL)
    stamp_mark(rows, MARK_TOP, MARK_LEFT, MARK_COL)
    return rows


def top_cell():
    rows = [[SLATE_LIGHT] * CELL for _ in range(CELL)]
    for i in range(CELL):
        rows[0][i] = SLATE_RIM
        rows[i][0] = SLATE_RIM
        rows[CELL - 1][i] = SLATE_DARK
        rows[i][CELL - 1] = SLATE_DARK
    stamp_mark(rows, 6, MARK_LEFT, MARK_COL)   # на крышке метка по центру грани
    return rows


def bottom_cell():
    rows = [[SLATE_DARK] * CELL for _ in range(CELL)]
    stamp_mark(rows, 6, MARK_LEFT, SLATE_LIGHT)
    return rows


def write_png(path):
    pixels = [[(0, 0, 0)] * ATLAS for _ in range(ATLAS)]

    def blit(cell, data):
        cx, cy = cell
        for y in range(CELL):
            for x in range(CELL):
                pixels[cy * CELL + y][cx * CELL + x] = data[y][x]

    blit(CELL_SIDE, side_cell())
    blit(CELL_TOP, top_cell())
    blit(CELL_BOTTOM, bottom_cell())

    raw = b""
    for row in pixels:
        raw += b"\x00" + bytes(v for px in row for v in px)

    def chunk(tag, data):
        body = tag + data
        return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)

    blob = b"\x89PNG\r\n\x1a\n"
    blob += chunk(b"IHDR", struct.pack(">IIBBBBB", ATLAS, ATLAS, 8, 2, 0, 0, 0))
    blob += chunk(b"IDAT", zlib.compress(raw, 9))
    blob += chunk(b"IEND", b"")
    with open(path, "wb") as f:
        f.write(blob)


if __name__ == "__main__":
    out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "objects", "gen")
    out = os.path.normpath(out)
    os.makedirs(out, exist_ok=True)

    nf, nt, nv = write_obj(os.path.join(out, "armor_block.obj"), "armor_block")
    write_png(os.path.join(out, "blocks_atlas.png"))
    print(f"граней {nf}, треугольников {nt}, вершин {nv}")
    print(f"атлас {ATLAS}x{ATLAS}, ячейка {CELL}x{CELL}")
