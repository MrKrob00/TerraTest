"""The planetfall intro's hit, wind and fall, v2 (the player: the blow when the debris strikes the
capsule was not heard, the fall and the wind did not fit). Recorded CC0 impacts from Kenney's packs
(art/sfx_src/kenney, credits in resources/intro/CREDITS.md) layered with synthesised air.
Writes resources/intro/intro_{hit,wind,fall}.ogg, 22050 Hz mono Vorbis. intro_sounds.py still makes
the alarm and the boom.

  intro_hit.ogg   whoosh in, then AT HIT_PRE the blow: heavy metal + plate impacts, a crunch, a sub
                  thump, the hull ringing, and debris pinging off for ~1.5 s
  intro_wind.ogg  a seamless 8 s LOOP: low rushing air (brown noise, ~250-700 Hz band) with slow
                  irregular gusts and buffeting, no hiss - the loop is set by its .import (loop=true)
  intro_fall.ogg  the main piece coming down: a deep rumble and a rush of air that rises and
                  tightens as it nears, a tumbling flutter, and at FALL_HIT the landing: a heavy
                  soft impact, a low-frequency explosion tail and earth

Run from the repo root:  python3 art/intro_sfx.py   (needs numpy, scipy, ffmpeg with libvorbis)
"""
import math, os, subprocess
import numpy as np
from scipy import signal

SR = 22050
HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, "sfx_src", "kenney")
OUT = os.path.join(HERE, "..", "resources", "intro")
HIT_PRE = 0.3        # planetfall.gd HIT_PRE
FALL_HIT = 4.2       # planetfall.gd T_LAND[MAIN] - T_BOOM


def load(name, rate=1.0):
    raw = subprocess.run(["ffmpeg", "-v", "0", "-i", os.path.join(SRC, name + ".ogg"), "-ac", "1",
                          "-ar", str(int(SR / rate)), "-f", "f32le", "-"], capture_output=True, check=True).stdout
    x = np.frombuffer(raw, np.float32).astype(np.float64)   # resampled at SR/rate, read at SR: pitch*rate
    return x / (np.max(np.abs(x)) + 1e-9)


def onset(x):
    return int(np.argmax(np.abs(x) > 0.3))


def place(buf, x, at, gain):
    i = int(at * SR) - onset(x)
    if i < 0:
        x, i = x[-i:], 0
    n = min(len(x), len(buf) - i)
    buf[i:i + n] += x[:n] * gain


def lp(x, hz, o=2):
    return signal.lfilter(*signal.butter(o, hz / (SR / 2), "low"), x)


def hp(x, hz, o=2):
    return signal.lfilter(*signal.butter(o, hz / (SR / 2), "high"), x)


def bp(x, lo, hi, o=2):
    return signal.lfilter(*signal.butter(o, [lo / (SR / 2), hi / (SR / 2)], "band"), x)


def brown(r, n):
    x = np.cumsum(r.standard_normal(n))
    return hp(x, 20, 1)


def smooth_noise(r, n, hz):
    """A slow random curve in 0..1: noise low-passed far down."""
    k = max(int(SR / hz), 1)
    pts = r.random(n // k + 3)
    c = np.interp(np.arange(n) / k, np.arange(len(pts)), pts)
    return lp(c, hz * 2, 1)


def norm(x, peak_db):
    return x / (np.max(np.abs(x)) + 1e-9) * 10 ** (peak_db / 20.0)


def limit(x, peak_db):
    """Soft clip then normalise: never above peak_db."""
    return norm(np.tanh(norm(x, 0) * 1.4), peak_db)


def write_ogg(name, x):
    path = os.path.join(OUT, name)
    pcm = np.clip(x, -1, 1).astype("<f4").tobytes()
    subprocess.run(["ffmpeg", "-v", "0", "-y", "-f", "f32le", "-ar", str(SR), "-ac", "1", "-i", "-",
                    "-c:a", "libvorbis", "-q:a", "3", path], input=pcm, check=True)
    print(name, f"{len(x) / SR:.2f} s", f"{os.path.getsize(path) // 1024} KB",
          f"peak {20 * math.log10(np.max(np.abs(x))):.1f} dBFS")


def hit():
    sec = HIT_PRE + 2.4
    n = int(sec * SR)
    t = np.arange(n) / SR
    r = np.random.default_rng(41)
    ta = np.clip(t - HIT_PRE, 0, None)
    after = t >= HIT_PRE
    # the piece closing in: a rising band of noise, cut at the blow
    k = np.clip(t / HIT_PRE, 0, 1)
    whoosh = bp(brown(r, n), 200, 1800) * k ** 3 * (t < HIT_PRE + 0.02)
    x = norm(whoosh, 0) * 0.35
    # the blow: recorded impacts stacked on the same instant, pitched down for mass
    place(x, load("impactMetal_heavy_001", 0.72), HIT_PRE, 0.95)
    place(x, load("impactPlate_heavy_004", 0.8), HIT_PRE, 0.75)
    place(x, load("impactPlate_heavy_000", 0.6), HIT_PRE + 0.004, 0.5)
    place(x, lp(load("explosionCrunch_001", 0.85), 4500), HIT_PRE, 0.55)
    # the hull ringing on after it: a bell impact far down and low-passed
    place(x, lp(load("impactBell_heavy_001", 0.45), 2500), HIT_PRE + 0.01, 0.28)
    # the sub thump the recordings lack
    thump = np.sin(2 * np.pi * np.cumsum(48 + 60 * np.exp(-ta / 0.03)) / SR) * np.exp(-ta / 0.22) * after
    x += thump * 0.8
    # debris pinging off the hull, thinning out
    bits = ["impactMetal_light_000", "impactMetal_light_003", "impactPlate_light_001"]
    for j in range(11):
        at = HIT_PRE + 0.12 + r.exponential(0.4)
        if at < sec - 0.4:
            place(x, load(bits[j % 3], r.uniform(0.8, 1.4)), at, r.uniform(0.08, 0.25) * math.exp(-(at - HIT_PRE) / 0.9))
    x *= np.minimum((sec - t) / 0.3, 1.0)
    write_ogg("intro_hit.ogg", limit(x, -1.0))


def wind():
    n = int(8.0 * SR)
    fade = int(1.0 * SR)
    m = n + fade
    r = np.random.default_rng(12)
    t = np.arange(m) / SR
    b = brown(r, m)
    body = bp(b, 120, 700)
    gust = 0.55 + 0.45 * smooth_noise(r, m, 0.35) ** 1.5           # slow gusts
    buffet = 0.85 + 0.15 * smooth_noise(r, m, 6.0)                  # the capsule buffeting
    upper = bp(b, 500, 1400) * smooth_noise(r, m, 0.5) ** 2         # the gust's edge, only in gusts
    rumble = lp(r.standard_normal(m), 60, 2)
    x = norm(body, 0) * gust * buffet + norm(upper, 0) * 0.25 + norm(rumble, 0) * 0.45
    # seamless loop: the tail crossfaded (equal power) into the head
    y = x[fade:fade + n].copy()
    w = np.sin(np.linspace(0, math.pi / 2, fade)) ** 2
    y[n - fade:] = x[n:n + fade] * np.sqrt(1 - w) + x[:fade] * np.sqrt(w)
    write_ogg("intro_wind.ogg", limit(y, -3.0))


def fall():
    sec = FALL_HIT + 1.6
    n = int(sec * SR)
    t = np.arange(n) / SR
    r = np.random.default_rng(37)
    before = t < FALL_HIT
    k = np.clip(t / FALL_HIT, 0, 1)
    b = brown(r, n)
    # rush of air rising and brightening as it nears; a tumbling flutter
    lo = 150 + 250 * k
    rush = np.zeros(n)
    for a, z in ((0, n // 3), (n // 3, 2 * n // 3), (2 * n // 3, n)):   # three bands stepping up
        f0 = float(np.mean(lo[a:z]))
        rush[a:z] = bp(b, f0, f0 * 3.2)[a:z]
    rush = lp(rush, 3000)
    flutter = 0.75 + 0.25 * np.sin(2 * np.pi * np.cumsum(3.0 + 3.0 * k) / SR)
    rush *= (0.12 + 0.88 * k ** 2.2) * flutter * before
    rumble = lp(r.standard_normal(n), 70, 2) * (0.3 + 0.7 * k ** 1.5) * before
    swell = np.minimum(t / 0.8, 1.0)
    x = (norm(rush, 0) * 0.4 + norm(rumble, 0) * 0.3) * swell
    # the cut just before landing: the air stops dead under the thud
    x *= np.where(before, np.minimum((FALL_HIT - t) / 0.04 + 0.2, 1.0), 1.0)
    # the landing
    place(x, load("impactSoft_heavy_001", 0.6), FALL_HIT, 1.0)
    place(x, load("lowFrequency_explosion_001", 1.0), FALL_HIT, 0.7)
    place(x, load("impactPlate_heavy_000", 0.55), FALL_HIT + 0.01, 0.35)
    ta = np.clip(t - FALL_HIT, 0, None)
    x += np.sin(2 * np.pi * np.cumsum(40 + 50 * np.exp(-ta / 0.05)) / SR) * np.exp(-ta / 0.3) * ~before * 0.8
    x += lp(r.standard_normal(n), 900) * np.exp(-ta / 0.25) * ~before * 0.25   # earth
    x *= np.minimum((sec - t) / 0.3, 1.0)
    write_ogg("intro_fall.ogg", limit(x, -1.0))


if __name__ == "__main__":
    hit()
    wind()
    fall()
