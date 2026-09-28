#!/usr/bin/env python3
"""The FALSUS faction's emblem - the first faction (G.FACTIONS "start").

    python3 art/faction_emblem.py
        -> images/faction_falsus.png (the UI's: quest tracker, journal)

Redrawn from the faction's art: a pointy-top hexagon cut into four parallelogram panels round a
lozenge, and in the lozenge a round hole with an EYE in it (the art had a fish). Bright green
shapes and nothing else: the gaps between them and the hole are see-through, and a little neon - a
pale edge inside every shape, a short faint halo off the big ones (off the fine parts it gathered
into haze in the hole).

THE SHAPE IS ONE FUNCTION, `inside(x, y)`, in units of the hexagon's radius. The UI picture is
rendered from it here, and the block sign plates (turret_heads.py style "falsus_plate") ask the
same function per texel - a second drawing of the emblem would drift from this one."""
import math
import os

import numpy as np

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT_PNG = os.path.join(ROOT, "images", "faction_falsus.png")

W, H, GAP = 1.0, 0.5, 0.075      # half-width, the sides' half-height, the gaps
# The hole, well inside the lozenge (whose inradius less half a gap is 0.41): at 0.41 it cut the
# lozenge into hairline slivers above and below.
HOLE = 0.30
# The centre, in units of the hole: an aperture ring cut into RING_N, the eye, an iris cut into
# IRIS_N petals, a slit pupil.
RING_IN, RING_OUT, RING_N, RING_CUT = 0.82, 0.93, 8, 0.08
EYE_HW, EYE_HH, EYE_ST = 0.72, 0.44, 0.13
IRIS_OUT, IRIS_IN, IRIS_N, IRIS_CUT = 0.26, 0.13, 8, 0.05
SLIT = (0.05, 0.12)
SIMPLE_DOT = 0.35                # below ~8 px of hole the eye is one dot of this radius

GREEN = (60, 222, 76)
TUBE = (200, 255, 205)
GLOW = (80, 255, 100)
GLOW_R, GLOW_A = 0.022, 0.55     # halo blur (x radius) and strength: short and faint
TUBE_R = 0.006                   # how deep the pale edge reaches in


def _cut(ex, ey, n, cut, phase):
    """True where (ex, ey) falls in one of n radial cuts `cut` wide, the first at `phase`."""
    hit = np.zeros(np.shape(ex), dtype=bool)
    for k in range(n // 2):
        a = phase + k * 2 * math.pi / n
        hit |= np.abs(-math.sin(a) * ex + math.cos(a) * ey) < cut / 2
    return hit


def _almond(ex, ey, hw, hh):
    t = np.clip(np.abs(ex) / hw, 0.0, 1.0)
    return (np.abs(ex) <= hw) & (np.abs(ey) <= hh * (1 - t * t) ** 0.8)


def eye(ex, ey, simple=False):
    """The hole's content, in units of the hole."""
    r = np.hypot(ex, ey)
    if simple:
        return r < SIMPLE_DOT
    ring = (r >= RING_IN) & (r <= RING_OUT) & ~_cut(ex, ey, RING_N, RING_CUT, math.pi / RING_N)
    st = EYE_ST
    lid = _almond(ex, ey, EYE_HW, EYE_HH) & ~_almond(ex, ey, EYE_HW - st * 1.9, EYE_HH - st)
    iris = (r >= IRIS_IN) & (r <= IRIS_OUT) & ~_cut(ex, ey, IRIS_N, IRIS_CUT, 0.0)
    slit = (ex / SLIT[0]) ** 2 + (ey / SLIT[1]) ** 2 <= 1.0
    return ring | lid | iris | slit


def panels(x, y):
    """The big shapes: the hexagon less its gaps and the hole."""
    ax, ay = np.abs(x), np.abs(y)
    hexa = (ax <= W) & (ay <= 1 - (1 - H) * ax / W)
    d = 1 - H
    loz_gap = np.abs(ax / W + ay / d - 1) / math.hypot(1 / W, 1 / d) < GAP / 2
    stem = (ax < GAP / 2) & (ay > d)
    return hexa & ~loz_gap & ~stem & (np.hypot(x, y) >= HOLE)


def inside(x, y, simple=False):
    """The whole emblem at (x, y), y DOWN (image rows), in units of the hexagon's radius."""
    return panels(x, y) | (eye(x / HOLE, y / HOLE, simple) & (np.hypot(x, y) < HOLE))


def coverage(fn, size, radius_px, ss=4):
    """0..1 coverage of fn on a size x size image, the emblem centred with radius radius_px."""
    n = size * ss
    c = (np.arange(n) + 0.5) / ss - size / 2
    x, y = np.meshgrid(c / radius_px, c / radius_px)
    m = fn(x, y).astype(np.float32)
    return m.reshape(size, ss, size, ss).mean(axis=(1, 3))


def render(size):
    from PIL import Image, ImageFilter
    R = size / 2 / 1.2
    full = Image.fromarray((coverage(inside, size, R) * 255).astype(np.uint8))
    big = Image.fromarray((coverage(panels, size, R) * 255).astype(np.uint8))
    soft = full.filter(ImageFilter.GaussianBlur(max(0.6, R * TUBE_R)))
    edge = Image.composite(soft.point(lambda v: min(255, int((255 - v) * 2.2))),
                           Image.new("L", full.size, 0), full)
    body = Image.composite(Image.new("RGB", full.size, TUBE), Image.new("RGB", full.size, GREEN), edge)
    img = body.convert("RGBA")
    img.putalpha(full)
    halo = Image.new("RGBA", full.size, GLOW + (0,))
    halo.putalpha(big.filter(ImageFilter.GaussianBlur(R * GLOW_R)).point(lambda v: int(v * GLOW_A)))
    return Image.alpha_composite(halo, img)


if __name__ == "__main__":
    render(256).save(OUT_PNG)     # the UI shows it at 20-32 px, with mipmaps
    print("wrote", OUT_PNG)
