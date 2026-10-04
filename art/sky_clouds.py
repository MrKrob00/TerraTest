#!/usr/bin/env python3
"""THE SKY'S CLOUDS: two tileable noise masks in one small texture, read by sky.gdshader with two
fetches a background pixel (the phone is fill-bound - CLAUDE.md, Look and light).

  R  CUMULUS - broad fbm, the clouds' bodies (thresholded by `cloud_cover` in the shader)
  G  DETAIL  - finer fbm the shader erodes the edges with and shades by, so a cloud is not a blob

    python3 art/sky_clouds.py  ->  images/sky_clouds.png

Value noise on a WRAPPING lattice, so every octave is periodic over the tile and the shader repeats
it across the sky without a seam. Data, not colour: imported lossless, no sRGB in the shader.
"""
import os

import numpy as np
from PIL import Image

N = 256
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "images", "sky_clouds.png")
rng = np.random.default_rng(4711)


def value_noise(cells):
    """Smooth value noise with `cells` lattice cells across the tile, wrapping at the edge."""
    lat = rng.random((cells, cells))
    t = np.arange(N) / N * cells
    i0 = np.floor(t).astype(int)
    f = t - i0
    f = f * f * (3 - 2 * f)
    i1 = (i0 + 1) % cells
    i0 = i0 % cells
    a = lat[np.ix_(i0, i0)]
    b = lat[np.ix_(i0, i1)]
    c = lat[np.ix_(i1, i0)]
    d = lat[np.ix_(i1, i1)]
    fy = f[:, None]
    fx = f[None, :]
    return (a * (1 - fx) + b * fx) * (1 - fy) + (c * (1 - fx) + d * fx) * fy


def fbm(base, octaves, gain=0.5):
    out = np.zeros((N, N))
    amp, tot = 1.0, 0.0
    for o in range(octaves):
        out += amp * value_noise(base * 2 ** o)
        tot += amp
        amp *= gain
    return out / tot


def norm(a):
    return (a - a.min()) / (a.max() - a.min() + 1e-9)


r = norm(fbm(4, 5, 0.55))
g = norm(fbm(16, 3, 0.5))
img = np.stack([r, g, np.zeros_like(r)], axis=-1)
Image.fromarray((img * 255).round().astype(np.uint8), "RGB").save(OUT)
print("saved", os.path.normpath(OUT))
