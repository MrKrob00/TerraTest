"""THE EMBER PATCH'S ONE TEXTURE (crash_site.gd, resources/ember_patch.gdshader).

Run: python3 art/ember_cracks.py  ->  resources/ember_cracks.png (256 px, tileable, lossless, mipmaps).

Everything the patch needs per pixel is baked here so the shader fetches once and does a few
multiplies: the ground's fragment shader is the phone's fill, and the first embers lived there
(18 -> 34 fps once they were out), so a local effect is its own small mesh with its own cheap shader.

  R  distance to the nearest crack, 0 on the crack, 1 at half a plate's width or more
     (Voronoi plates on a jittered grid, the sample point warped so the cracks run ragged)
  G  the plate's own random number: its tone and the phase its cracks breathe at
  B  fine noise: grain on the charcoal and the ragged edge of the patch
"""
import numpy as np
from PIL import Image
import os

N = 256          # pixels a side
CELLS = 7        # plates a side
SEED = 7331
rng = np.random.default_rng(SEED)


def value_noise(freq, rng):
    """Tileable value noise at `freq` lattice cells a side, smoothstep-interpolated."""
    lat = rng.random((freq, freq))
    xs = np.arange(N) / N * freq
    i0 = np.floor(xs).astype(int)
    f = xs - i0
    f = f * f * (3 - 2 * f)
    i1 = (i0 + 1) % freq
    a = lat[np.ix_(i0, i0)]
    b = lat[np.ix_(i0, i1)]
    c = lat[np.ix_(i1, i0)]
    d = lat[np.ix_(i1, i1)]
    fy = f[:, None]
    fx = f[None, :]
    return (a * (1 - fx) + b * fx) * (1 - fy) + (c * (1 - fx) + d * fx) * fy


def fbm(freqs, amps, rng):
    out = sum(a * value_noise(f, rng) for f, a in zip(freqs, amps))
    return out / sum(amps)


# plate centres on a jittered grid, in tile units 0..1, with their 3x3 wrapped copies
gx, gy = np.meshgrid(np.arange(CELLS), np.arange(CELLS))
pts = np.stack([(gx + 0.15 + 0.7 * rng.random(gx.shape)) / CELLS,
                (gy + 0.15 + 0.7 * rng.random(gy.shape)) / CELLS], -1).reshape(-1, 2)
ids = rng.random(len(pts))
copies, cid = [], []
for ox in (-1, 0, 1):
    for oy in (-1, 0, 1):
        copies.append(pts + np.array([ox, oy]))
        cid.append(ids)
P = np.concatenate(copies)            # (M, 2)
ID = np.concatenate(cid)

# the sample point, warped a little so the crack lines are ragged rather than straight
yy, xx = np.meshgrid(np.arange(N) / N, np.arange(N) / N, indexing="ij")
warp = 0.22 / CELLS
wx = (fbm([6, 12], [1.0, 0.5], rng) - 0.5) * 2 * warp
wy = (fbm([6, 12], [1.0, 0.5], rng) - 0.5) * 2 * warp
sx = xx + wx
sy = yy + wy

d2 = (sx[..., None] - P[:, 0]) ** 2 + (sy[..., None] - P[:, 1]) ** 2     # (N, N, M)
near = np.argmin(d2, -1)
p1 = P[near]                                                            # (N, N, 2)
d1 = np.take_along_axis(d2, near[..., None], -1)[..., 0]
# distance to the bisector between the nearest centre and every other: the plate's border
sep = np.sqrt((P[None, None, :, 0] - p1[..., 0:1]) ** 2 + (P[None, None, :, 1] - p1[..., 1:2]) ** 2)
sep = np.where(sep < 1e-9, np.inf, sep)
border = np.where(np.isinf(sep), np.inf, (d2 - d1[..., None]) / (2 * sep))
bd = border.min(-1)                                                     # tile units
R = np.clip(bd / (0.5 / CELLS), 0, 1)
G = ID[near]
B = fbm([16, 32, 64], [1.0, 0.6, 0.35], rng)
B = (B - B.min()) / (B.max() - B.min())

img = np.stack([R, G, B], -1)
img = (np.clip(img, 0, 1) * 255 + 0.5).astype(np.uint8)
out = os.path.join(os.path.dirname(__file__), "..", "resources", "ember_cracks.png")
Image.fromarray(img, "RGB").save(out)
print("wrote", os.path.normpath(out))
