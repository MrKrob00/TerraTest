#!/usr/bin/env python3
"""Генератор лоу-поли блоков WorldTech: меш (.obj + .mtl) + пиксельный атлас (.png).

ЗЕРКАЛО block_mesh.gd. В игре меш и материал собирает GDScript — там гарантированно
правильный фильтр и никакой ручной настройки. Этот файл нужен, чтобы форму можно было
посмотреть (art/preview.py) до запуска Godot. Правишь одно — правь и второе.

ВНИМАНИЕ про намотку: тут она ОСТАЁТСЯ против часовой — такова конвенция .obj. В
block_mesh.gd она перевёрнута намеренно, потому что Godot передней гранью считает
намотку по часовой. Это не рассинхрон зеркал, а разные форматы.

Спецификация стиля (общая для всех блоков):
  габарит      0.96 в ячейке 1.0  — зазор 0.02 даёт видимый шов между блоками
  фаска        0.10 на всех рёбрах
  метка        выпуклая четырёхлучевая звезда по центру КАЖДОЙ грани, лучи по диагоналям
  нормали      плоские (по грани)
  тексель      16 пикселей на мировую единицу — совпадает с землёй
               (PIXELS_PER_TILE = 16.0 в addons/LiteTerrain/glsl.gdshader)
  фильтр       ТОЛЬКО nearest, без мипов — иначе пиксели мылятся

Зависимостей нет — только стандартная библиотека.
"""

import os
import struct
import zlib

HALF = 0.48          # половина габарита (блок 0.96 в ячейке 1.0)
CHAMFER = 0.10       # срез ребра
INNER = HALF - CHAMFER

# Метка крепления: выпуклая звезда с лучами по диагоналям грани.
PAD_RISE = 0.02      # «чуть-чуть» — с меткой блок ровно заполняет ячейку 1.0
PAD_TIP = 0.165      # радиус луча
PAD_VALLEY = 0.075   # радиус впадины: заметно меньше луча, иначе звезда вырождается в квадрат

CELL = 16            # тексель-ячейка грани
ATLAS = 32           # атлас 2x2 ячейки

CELL_SIDE = (0, 0)
CELL_TOP = (1, 0)
CELL_BOTTOM = (0, 1)
CELL_PAD = (1, 1)

# Палитра. Сине-серый сланец — семейство, заведённое под блок корпуса.
SLATE_RIM = (132, 140, 165)
SLATE_LIGHT = (110, 118, 143)
SLATE_DARK = (88, 95, 119)
CREAM = (226, 224, 212)
PAD_FACE = (146, 154, 178)
PAD_MARK = (96, 103, 126)

WORLD = 0            # UV из мировой позиции — полоса непрерывна через фаски
PAD = 1              # UV из собственной ячейки метки


def chamfered_box():
    """Грани скошенного куба: 6 площадок + 12 рёбер + 8 углов = 44 треугольника."""
    faces = []

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
            faces.append([quad[0], quad[1], quad[3], quad[2]])

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
                    faces.append([quad[0], quad[1], quad[3], quad[2]])

    for sx in (-1, 1):
        for sy in (-1, 1):
            for sz in (-1, 1):
                s = (sx, sy, sz)
                faces.append([tuple(s[a] * (HALF if a == lead else INNER) for a in range(3))
                              for lead in range(3)])
    return faces


def face_axes(axis, sign):
    """Пара осей в плоскости грани. u берём так, чтобы лучи звезды шли по диагоналям
    квадрата грани, а не по его сторонам."""
    u = [0.0, 0.0, 0.0]
    v = [0.0, 0.0, 0.0]
    u[(axis + 1) % 3] = 1.0
    v[(axis + 2) % 3] = float(sign)
    return tuple(u), tuple(v)


def star_outline():
    """Восемь точек контура: лучи по диагоналям (45°, 135°, 225°, 315°)."""
    import math
    pts = []
    for i in range(8):
        ang = math.pi / 4.0 + math.pi / 4.0 * i     # старт с диагонали
        r = PAD_TIP if i % 2 == 0 else PAD_VALLEY
        pts.append((math.cos(ang) * r, math.sin(ang) * r))
    return pts


def pad_faces(axis, sign):
    """Выпуклая звезда по центру грани: верхняя крышка веером + бортик по контуру."""
    u, v = face_axes(axis, sign)
    n = [0.0, 0.0, 0.0]
    n[axis] = float(sign)

    def at(su, sv, rise):
        return tuple(u[a] * su + v[a] * sv + n[a] * (HALF + rise) for a in range(3))

    outline = star_outline()
    faces = []
    centre = at(0.0, 0.0, PAD_RISE)
    for i in range(8):
        a = outline[i]
        b = outline[(i + 1) % 8]
        faces.append(([centre, at(a[0], a[1], PAD_RISE), at(b[0], b[1], PAD_RISE)], PAD))
        faces.append(([at(a[0], a[1], 0.0), at(b[0], b[1], 0.0),
                       at(b[0], b[1], PAD_RISE), at(a[0], a[1], PAD_RISE)], PAD))
    return faces


def block_faces():
    """Полный блок: корпус (UV из мира) + шесть меток (UV из своей ячейки)."""
    faces = [(poly, WORLD) for poly in chamfered_box()]
    for axis in range(3):
        for sign in (-1, 1):
            faces.extend(pad_faces(axis, sign))
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
    length = (nx * nx + ny * ny + nz * nz) ** 0.5 or 1.0
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
    au = (cx * CELL + 0.5 + min(max(u, 0.0), 1.0) * (CELL - 1)) / ATLAS
    av = (cy * CELL + 0.5 + min(max(v, 0.0), 1.0) * (CELL - 1)) / ATLAS
    return au, av


def face_uvs(poly, normal, kind):
    if kind == PAD:
        # Метка берёт цвет из своей ячейки: центр звезды — в центр ячейки.
        axis = max(range(3), key=lambda a: abs(normal[a]))
        sign = 1 if normal[axis] > 0 else -1
        u, v = face_axes(axis, sign)
        out = []
        for p in poly:
            su = sum(p[a] * u[a] for a in range(3)) / (PAD_TIP * 2.0) + 0.5
            sv = sum(p[a] * v[a] for a in range(3)) / (PAD_TIP * 2.0) + 0.5
            out.append(cell_uv(CELL_PAD, su, 1.0 - sv))
        return out

    # UV корпуса считаются из МИРОВОЙ позиции, а не по грани — тогда полоса непрерывно
    # продолжается через фаски, а не обрывается на каждом ребре.
    span = 2.0 * HALF
    out = []
    if abs(normal[1]) > 0.999:
        cell = CELL_TOP if normal[1] > 0.0 else CELL_BOTTOM
        for x, y, z in poly:
            uu = (x + HALF) / span
            vv = (z + HALF) / span
            if normal[1] < 0.0:
                vv = 1.0 - vv
            out.append(cell_uv(cell, uu, vv))
        return out

    horizontal_x = abs(normal[0]) >= abs(normal[2])
    for x, y, z in poly:
        vv = (HALF - y) / span
        if horizontal_x:
            uu = (z + HALF) / span
            if normal[0] > 0.0:
                uu = 1.0 - uu
        else:
            uu = (x + HALF) / span
            if normal[2] < 0.0:
                uu = 1.0 - uu
        out.append(cell_uv(CELL_SIDE, uu, vv))
    return out


def write_obj(path, name, mtl_name):
    verts, uvs, norms, lines = [], [], [], []
    tris = 0
    for poly, kind in block_faces():
        poly, normal = orient_outward(poly)
        uv = face_uvs(poly, normal, kind)
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
        f.write("mtllib %s\n" % mtl_name)
        f.write("o %s\n" % name)
        for x, y, z in verts:
            f.write("v %.5f %.5f %.5f\n" % (x, y, z))
        for u, v in uvs:
            f.write("vt %.6f %.6f\n" % (u, 1.0 - v))     # OBJ считает V снизу
        for x, y, z in norms:
            f.write("vn %.5f %.5f %.5f\n" % (x, y, z))
        f.write("usemtl block\n")
        for a, b, c, n in lines:
            f.write("f %d/%d/%d %d/%d/%d %d/%d/%d\n" % (a, a, n, b, b, n, c, c, n))
    return len(block_faces()), tris, len(verts)


def write_mtl(path, texture_name):
    """Чтобы .obj тянул текстуру сам, а не руками. Фильтр отсюда не задать — за этим
    в игре следит block_mesh.gd, который собирает материал сам."""
    with open(path, "w") as f:
        f.write("newmtl block\n")
        f.write("Ka 1.000 1.000 1.000\n")
        f.write("Kd 1.000 1.000 1.000\n")
        f.write("Ks 0.000 0.000 0.000\n")
        f.write("d 1.0\nillum 1\n")
        f.write("map_Kd %s\n" % texture_name)


def side_cell():
    rows = []
    for y in range(CELL):
        if y == 0:
            col = SLATE_RIM
        elif y <= 6:
            col = SLATE_LIGHT
        elif y <= 8:
            col = CREAM          # ровно по середине грани (ряды 7-8 из 16)
        else:
            col = SLATE_DARK
        rows.append([col] * CELL)
    return rows


def top_cell():
    rows = [[SLATE_LIGHT] * CELL for _ in range(CELL)]
    for i in range(CELL):
        rows[0][i] = SLATE_RIM
        rows[i][0] = SLATE_RIM
        rows[CELL - 1][i] = SLATE_DARK
        rows[i][CELL - 1] = SLATE_DARK
    return rows


def bottom_cell():
    return [[SLATE_DARK] * CELL for _ in range(CELL)]


def pad_cell():
    """Ячейка метки: ровный светлый тон с чуть темнее серединой. Форму лучей даёт
    геометрия — рисовать её ещё и пикселями значит получить грязь поверх граней."""
    rows = [[PAD_FACE] * CELL for _ in range(CELL)]
    for y in range(7, 9):
        for x in range(7, 9):
            rows[y][x] = PAD_MARK          # только точка в центре — «ось» крепления
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
    blit(CELL_PAD, pad_cell())

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
    out = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "objects", "gen"))
    os.makedirs(out, exist_ok=True)
    nf, nt, nv = write_obj(os.path.join(out, "armor_block.obj"), "armor_block", "armor_block.mtl")
    write_mtl(os.path.join(out, "armor_block.mtl"), "blocks_atlas.png")
    write_png(os.path.join(out, "blocks_atlas.png"))
    print("граней %d, треугольников %d, вершин %d" % (nf, nt, nv))
    print("атлас %dx%d, ячейка %dx%d" % (ATLAS, ATLAS, CELL, CELL))
