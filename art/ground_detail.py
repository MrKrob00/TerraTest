#!/usr/bin/env python3
"""THE GROUND'S DETAIL TEXTURE: four tileable masks in one RGBA image, so the terrain shader reads
all of them in the ONE texture fetch it already spent on the old tile (the phone is fill-bound -
CLAUDE.md, Look and light). After TerraTech's ground (the player's screenshots):

  R  CRACKED EARTH - Voronoi cells, 0 in the cracks, a tone per cell inside (the salt flats)
  G  SAND RIPPLES - wind ripples, sharp crest and long back, wavering (the desert)
  B  GRASS - clumps and tufts, darker hollows (the meadow)
  A  PATCHES - a low, broad variation every biome is tinted by, so no ground is one flat colour

    python3 art/ground_detail.py  ->  addons/LiteTerrain/ground_detail.png

Every pattern is PERIODIC over the tile (Voronoi seeded with wrapped points, sines with whole
frequencies), so the shader can repeat it across the world without a seam. The masks are data, not
colour: the shader samples them without sRGB, and the file is imported LOSSLESS (VRAM compression
works in 4x4 blocks and would smear a crack line into a grey square, as it did the belt arrows).
"""
import math
import os

import numpy as np
from PIL import Image

N = 512
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "addons", "LiteTerrain",
                   "ground_detail.png")
rng = np.random.default_rng(1234)
y, x = np.mgrid[0:N, 0:N] / float(N)


def periodic_noise(freqs, amps):
    """Sum of sines with whole frequencies and random phases: periodic over [0, 1)^2."""
    out = np.zeros((N, N))
    for (fx, fy), a in zip(freqs, amps):
        out += a * np.sin(2 * math.pi * (fx * x + fy * y) + rng.uniform(0, 2 * math.pi))
    return out


def norm(a):
    return (a - a.min()) / (a.max() - a.min() + 1e-9)


# R: cracked earth. A JITTERED 8 x 8 GRID, not random points: random ones bunch up, and a cluster of
# tiny cells fills in solid black; F2 - F1 is the distance to the nearest cell edge.
def cracks():
    g = 8
    gx, gy = np.meshgrid(np.arange(g), np.arange(g))
    pts = (np.stack([gx.ravel(), gy.ravel()], 1) + 0.5 + rng.uniform(-0.38, 0.38, (g * g, 2))) / g
    tiles = np.concatenate([pts + [dx, dy] for dx in (-1, 0, 1) for dy in (-1, 0, 1)])
    d = np.sqrt((x[..., None] - tiles[:, 0]) ** 2 + (y[..., None] - tiles[:, 1]) ** 2)
    order = np.argsort(d, axis=2)
    f1 = np.take_along_axis(d, order[..., :1], 2)[..., 0]
    f2 = np.take_along_axis(d, order[..., 1:2], 2)[..., 0]
    cell = order[..., 0] % len(pts)
    edge = f2 - f1
    # the crack's width wavers along it, so the lines read drawn, not ruled
    width = 0.006 + 0.004 * norm(periodic_noise([(3, 5), (7, 2), (4, 9)], [1, 0.6, 0.4]))
    tone = 0.80 + 0.20 * rng.random(len(pts))[cell]     # one dried crust, a little uneven
    inner = np.clip((edge - width) / 0.01, 0, 1)        # a soft lip on the crack's edge
    return np.where(edge < width, 0.0, tone * (0.82 + 0.18 * inner))


# G: ripples along X with a wavering front, sharp crest and long back slope.
def ripples():
    warp = periodic_noise([(1, 2), (2, 1), (3, 3)], [0.35, 0.25, 0.12])
    ph = 18 * x + 2 * y + warp
    t = ph - np.floor(ph)
    return np.where(t < 0.78, t / 0.78, (1 - t) / 0.22) ** 1.4


# B: grass clumps - broad tufts and fine speckle.
def grass():
    broad = norm(periodic_noise([(5, 3), (3, 7), (8, 6), (11, 4), (6, 12)], [1, 0.9, 0.6, 0.5, 0.4]))
    fine = rng.random((N // 4, N // 4))
    fine = np.kron(fine, np.ones((4, 4)))                # 4-px speckle: the game's pixel scale
    return np.clip(0.55 * broad + 0.45 * fine, 0, 1)


# A: broad patches, a couple of blotches across the tile.
def patches():
    return norm(periodic_noise([(1, 1), (2, 1), (1, 2), (3, 2)], [1, 0.7, 0.6, 0.35]))


img = np.stack([cracks(), ripples(), grass(), patches()], axis=-1)
Image.fromarray((img * 255).round().astype(np.uint8), "RGBA").save(OUT)
print("saved", os.path.normpath(OUT))
