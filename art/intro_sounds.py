"""The planetfall intro's sound, synthesised (the player's call: the music goes quiet for the intro,
and the fall has a voice of its own). Writes resources/intro/*.wav, 22050 Hz mono 16-bit:

  intro_wind.wav     a LOOP: the rush of air round the falling capsule - noise through a resonant band
                     whose centre wanders (gusts), a low rumble under it, a thin hiss over it
  intro_alarm.wav    a LOOP: "piu-piu" and a pause - two falling electronic chirps, not loud; from the
                     moment the capsule is hit until it blows up
  intro_boom.wav     the explosion: a crack, a boom whose brightness falls away, a sub thump, crackle
  intro_fall.wav     the main piece falling: a descending whistle and a rising rush of air, ending in
                     a dull thud at FALL_HIT seconds - planetfall.gd starts it at the blast so the thud
                     lands with the piece (T_LAND[MAIN] - T_BOOM)

The loops carry a WAV 'smpl' chunk with their loop points; Godot's importer reads it ("Detect From
WAV", the default). Every number is seeded, so a re-run writes the same files.

Run from the repo root:  python3 art/intro_sounds.py
"""
import math
import os
import struct

import numpy as np
from scipy import signal

SR = 22050
OUT = os.path.join(os.path.dirname(__file__), "..", "resources", "intro")
FALL_HIT = 4.2          # planetfall.gd: T_LAND[MAIN] - T_BOOM


def rng(seed):
    return np.random.default_rng(seed)


def t_axis(sec):
    return np.arange(int(sec * SR)) / SR


def lowpass(x, hz, order=2):
    b, a = signal.butter(order, hz / (SR / 2), "low")
    return signal.lfilter(b, a, x)


def highpass(x, hz, order=2):
    b, a = signal.butter(order, hz / (SR / 2), "high")
    return signal.lfilter(b, a, x)


def swept_band(x, centre, q):
    """A resonant band-pass whose centre moves per sample (a state-variable filter)."""
    y = np.zeros_like(x)
    low = band = 0.0
    damp = 1.0 / q
    for i in range(len(x)):
        f = 2.0 * math.sin(math.pi * min(centre[i], SR * 0.2) / SR)
        high = x[i] - low - damp * band
        band += f * high
        low += f * band
        y[i] = band
    return y


def swept_low(x, cutoff):
    """A one-pole low-pass whose cutoff moves per sample."""
    y = np.zeros_like(x)
    s = 0.0
    for i in range(len(x)):
        a = 1.0 - math.exp(-2.0 * math.pi * cutoff[i] / SR)
        s += a * (x[i] - s)
        y[i] = s
    return y


def norm(x, peak_db):
    return x / (np.max(np.abs(x)) + 1e-9) * 10 ** (peak_db / 20.0)


def loop_xfade(x, n, fade):
    """x has n + fade samples; returns n samples whose end runs smoothly into their start."""
    y = x[fade:fade + n].copy()
    w = np.sin(np.linspace(0.0, math.pi / 2, fade)) ** 2
    y[n - fade:] = x[n:n + fade] * np.sqrt(1.0 - w) + x[0:fade] * np.sqrt(w)
    return y


def write_wav(name, x, loop=False):
    pcm = np.clip(np.round(x * 32767.0), -32768, 32767).astype("<i2").tobytes()
    fmt = struct.pack("<HHIIHH", 1, 1, SR, SR * 2, 2, 16)
    chunks = b"fmt " + struct.pack("<I", len(fmt)) + fmt
    chunks += b"data" + struct.pack("<I", len(pcm)) + pcm
    if loop:
        # smpl: manufacturer, product, period, unity note, pitch fraction, SMPTE format, offset,
        # one loop, no extra data; the loop: id, type 0 (forward), start, end (inclusive), 0, 0
        period = int(1e9 / SR)
        smpl = struct.pack("<9I", 0, 0, period, 60, 0, 0, 0, 1, 0)
        smpl += struct.pack("<6I", 0, 0, 0, len(x) - 1, 0, 0)
        chunks += b"smpl" + struct.pack("<I", len(smpl)) + smpl
    data = b"RIFF" + struct.pack("<I", 4 + len(chunks)) + b"WAVE" + chunks
    path = os.path.join(OUT, name)
    with open(path, "wb") as f:
        f.write(data)
    print(name, f"{len(x) / SR:.2f} s", f"{len(data) // 1024} KB")


def wind():
    n = int(4.0 * SR)
    fade = int(0.6 * SR)
    t = np.arange(n + fade) / SR
    r = rng(11)
    white = r.standard_normal(len(t))
    # gusts: the band's centre wanders on two slow waves (whole periods over the loop, so the
    # crossfade only has to hide the noise)
    centre = 520 + 210 * np.sin(2 * np.pi * 0.25 * t) + 120 * np.sin(2 * np.pi * 0.75 * t + 1.3)
    # a band of BROWN noise, not white: the band's skirts fall at 6 dB an octave, and white noise
    # leaked enough treble through them to read as hiss, not as a roar
    roar = swept_band(lowpass(white, 1200, 2), centre, 1.8)
    roar *= 0.75 + 0.25 * np.sin(2 * np.pi * 0.5 * t + 0.4)
    rumble = lowpass(r.standard_normal(len(t)), 90, 2) * 4.0
    rumble *= 0.8 + 0.2 * np.sin(2 * np.pi * 1.0 * t)
    hiss = lowpass(highpass(r.standard_normal(len(t)), 2200, 2), 5000, 2)
    x = norm(roar, 0) * 0.7 + norm(rumble, 0) * 0.5 + norm(hiss, 0) * 0.05
    y = loop_xfade(x, n, fade)
    write_wav("intro_wind.wav", norm(np.tanh(y * 1.3), -3.0), loop=True)


def chirp(sec, f0, f1):
    t = t_axis(sec)
    f = f0 * (f1 / f0) ** (t / sec)
    ph = 2 * np.pi * np.cumsum(f) / SR
    tone = np.sin(ph) + 0.28 * np.sin(3 * ph) + 0.12 * np.sin(5 * ph)
    env = np.minimum(t / 0.006, 1.0) * np.exp(-t / (sec * 0.45))
    return tone * env


def alarm():
    n = int(1.15 * SR)
    x = np.zeros(n)
    for start in (0.0, 0.27):
        c = chirp(0.21, 1650.0, 720.0)
        i = int(start * SR)
        x[i:i + len(c)] += c
    # a little room so it does not sound like a dry beeper
    echo = np.zeros(n)
    d = int(0.055 * SR)
    echo[d:] = x[:-d] * 0.25
    x = lowpass(x + echo, 5000, 2)
    write_wav("intro_alarm.wav", norm(x, -6.0), loop=True)


def boom():
    sec = 3.6
    t = t_axis(sec)
    r = rng(23)
    white = r.standard_normal(len(t))
    crack = highpass(white, 900, 2) * np.exp(-t / 0.03)
    cutoff = 150 + 2400 * np.exp(-t / 0.35)
    body = swept_low(swept_low(white, cutoff), cutoff) * np.minimum(t / 0.008, 1.0) * np.exp(-t / 0.75)
    f = 34 + 30 * np.exp(-t / 0.25)
    thump = np.sin(2 * np.pi * np.cumsum(f) / SR) * np.exp(-t / 0.55)
    # crackle: sparse sharp ticks dying off over a couple of seconds
    ticks = np.zeros(len(t))
    for _ in range(140):
        at = r.uniform(0.15, 2.6) ** 1.4 / 2.6 ** 0.4
        i = int(at * SR)
        if i < len(t) - 200:
            ticks[i:i + 60] += r.uniform(0.3, 1.0) * np.exp(-np.arange(60) / 9.0) * r.choice([-1, 1])
    ticks = highpass(ticks, 700, 1) * np.exp(-t / 1.1)
    rumble = lowpass(r.standard_normal(len(t)), 70, 2) * np.minimum(t / 0.05, 1.0) * np.exp(-t / 1.4)
    x = norm(crack, 0) * 0.35 + norm(body, 0) * 1.0 + norm(thump, 0) * 0.9 \
        + norm(ticks, 0) * 0.22 + norm(rumble, 0) * 0.55
    x *= np.minimum((sec - t) / 0.3, 1.0)
    write_wav("intro_boom.wav", norm(np.tanh(x * 1.6), -1.0))


def fall():
    sec = FALL_HIT + 0.9
    t = t_axis(sec)
    r = rng(37)
    before = t < FALL_HIT
    k = np.clip(t / FALL_HIT, 0.0, 1.0)
    # the whistle drops in pitch and swells as it comes
    f = 1250.0 * (480.0 / 1250.0) ** k + 9.0 * np.sin(2 * np.pi * 5.5 * t)
    ph = 2 * np.pi * np.cumsum(f) / SR
    whistle = (np.sin(ph) + 0.15 * np.sin(2 * ph)) * (0.15 + 0.85 * k ** 1.6) * before
    # the rush of air round a tumbling lump: a band rising with the speed, a wobble from the tumble
    white = r.standard_normal(len(t))
    centre = 380 + 900 * k ** 1.3
    rush = swept_band(lowpass(white, 2500, 2), centre, 1.3) * (0.1 + 0.9 * k ** 1.8) * before
    rush *= 0.8 + 0.2 * np.sin(2 * np.pi * 3.1 * t)
    swell = np.minimum(t / 0.6, 1.0)             # out of the explosion, not over it
    # the thud as it lands: a dull low knock and a short burst of earth
    ta = np.clip(t - FALL_HIT, 0.0, None)
    after = ~before
    knock = np.sin(2 * np.pi * np.cumsum(46 + 40 * np.exp(-ta / 0.08)) / SR) * np.exp(-ta / 0.22) * after
    dirt = lowpass(r.standard_normal(len(t)), 600, 2) * np.exp(-ta / 0.16) * after
    x = (norm(whistle, 0) * 0.42 + norm(rush, 0) * 0.6) * swell + norm(knock, 0) * 0.95 + norm(dirt, 0) * 0.5
    x *= np.minimum((sec - t) / 0.2, 1.0)
    write_wav("intro_fall.wav", norm(np.tanh(x * 1.3), -1.5))


if __name__ == "__main__":
    wind()
    alarm()
    boom()
    fall()
