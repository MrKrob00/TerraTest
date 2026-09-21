#!/usr/bin/env python3
"""Впекает нормал-карту в альбедо-атлас.

Блоки в игре идут unshaded: свет им уже нарисован в текстуре. Нормаль в рантайме на них не
действует вовсе (замерено: разница кадров 0.000), поэтому рельеф с карты переносим в сам атлас
как разницу освещённости относительно ПЛОСКОЙ нормали. На плоских участках разница ровно ноль,
то есть 96% текстуры не меняется ни на единицу, а фаски по краям островов получают губу:
одна сторона светлеет, другая темнеет.

Свет берём в касательном пространстве — одно направление на весь атлас. Для фасок это ровно то,
что делает художник, рисуя блик по краю вручную; для крупных наклонных поверхностей это было бы
приближением, но таких на этой карте нет.
"""
import struct
import sys
import zlib

LIGHT = (-0.40, 0.55, 0.73)   # в касательном: x вправо по UV, y вверх, z из поверхности
STRENGTH = 1.35               # насколько сильно губа влияет на цвет


def _unfilter(raw, w, h, ch):
    stride = w * ch
    out = []
    prev = bytearray(stride)
    i = 0
    for _y in range(h):
        f = raw[i]
        i += 1
        line = bytearray(raw[i:i + stride])
        i += stride
        if f == 1:
            for x in range(ch, stride):
                line[x] = (line[x] + line[x - ch]) & 255
        elif f == 2:
            for x in range(stride):
                line[x] = (line[x] + prev[x]) & 255
        elif f == 3:
            for x in range(stride):
                a = line[x - ch] if x >= ch else 0
                line[x] = (line[x] + ((a + prev[x]) >> 1)) & 255
        elif f == 4:
            for x in range(stride):
                a = line[x - ch] if x >= ch else 0
                b = prev[x]
                c = prev[x - ch] if x >= ch else 0
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                line[x] = (line[x] + pr) & 255
        out.append(line)
        prev = line
    return out


def read_png(path):
    d = open(path, 'rb').read()
    pos, idat, w, h, bd, ct = 8, b'', 0, 0, 0, 0
    while pos < len(d):
        ln = struct.unpack('>I', d[pos:pos + 4])[0]
        typ = d[pos + 4:pos + 8]
        data = d[pos + 8:pos + 8 + ln]
        pos += 12 + ln
        if typ == b'IHDR':
            w, h, bd, ct = struct.unpack('>IIBB', data[:10])
        elif typ == b'IDAT':
            idat += data
    if bd != 8 or ct not in (2, 6):
        raise SystemExit('%s: нужен 8-битный RGB или RGBA, а тут глубина %d тип %d' % (path, bd, ct))
    ch = 4 if ct == 6 else 3
    return w, h, ch, _unfilter(zlib.decompress(idat), w, h, ch)


def write_png(path, w, h, ch, rows):
    raw = bytearray()
    for r in rows:
        raw.append(0)
        raw += r
    ct = 6 if ch == 4 else 2

    def chunk(tag, data):
        return (struct.pack('>I', len(data)) + tag + data
                + struct.pack('>I', zlib.crc32(tag + data) & 0xFFFFFFFF))

    out = (b'\x89PNG\r\n\x1a\n'
           + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, ct, 0, 0, 0))
           + chunk(b'IDAT', zlib.compress(bytes(raw), 9))
           + chunk(b'IEND', b''))
    open(path, 'wb').write(out)


def main(albedo_path, normal_path, out_path):
    aw, ah, ach, arows = read_png(albedo_path)
    nw, nh, nch, nrows = read_png(normal_path)
    if (aw, ah) != (nw, nh):
        raise SystemExit('размеры не совпадают: альбедо %dx%d, нормаль %dx%d' % (aw, ah, nw, nh))
    lx, ly, lz = LIGHT
    ln = (lx * lx + ly * ly + lz * lz) ** 0.5
    lx, ly, lz = lx / ln, ly / ln, lz / ln
    flat = lz                       # освещённость плоской нормали (0,0,1)
    touched = 0
    for y in range(ah):
        arow, nrow = arows[y], nrows[y]
        for x in range(aw):
            ni = x * nch
            nxv = nrow[ni] / 127.5 - 1.0
            nyv = nrow[ni + 1] / 127.5 - 1.0
            nzv = nrow[ni + 2] / 127.5 - 1.0
            m = (nxv * nxv + nyv * nyv + nzv * nzv) ** 0.5
            if m < 1e-4:
                continue
            nxv, nyv, nzv = nxv / m, nyv / m, nzv / m
            delta = (nxv * lx + nyv * ly + nzv * lz) - flat
            if -0.004 < delta < 0.004:
                continue            # плоско: не трогаем вовсе
            touched += 1
            f = 1.0 + STRENGTH * delta
            if f < 0.0:
                f = 0.0
            ai = x * ach
            for c in range(3):
                v = int(arow[ai + c] * f + 0.5)
                arow[ai + c] = 0 if v < 0 else (255 if v > 255 else v)
    write_png(out_path, aw, ah, ach, arows)
    print('изменено пикселей: %d из %d (%.1f%%)' % (touched, aw * ah, 100.0 * touched / (aw * ah)))
    print('записано: %s' % out_path)


if __name__ == '__main__':
    main(sys.argv[1], sys.argv[2], sys.argv[3])
