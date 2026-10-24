"""The game's sound effects (the player: "sounds are almost missing - important for atmosphere").
Recorded CC0 clips from Kenney's packs (art/sfx_src/kenney, credits in resources/sfx/CREDITS.md)
trimmed and levelled, plus synthesised shots where the packs have none (no firearms in them).
Writes resources/sfx/<name>.ogg, 22050 Hz mono Vorbis; `sfx.gd` (autoload Sfx) names them.

  gun_0..2      machine gun: a crack, a body of band noise and a short low thump
  shotgun       two barrels' worth: a longer, lower blast
  cannon        a punch and a low explosion's head
  laser         Kenney laserLarge, the lance
  rocket        an ignition pop and a rising rush of air
  mortar        a hollow tube thump
  hit_0..2      a round on a block: light metal impacts
  blast_0..1    an explosion: crunch
  shield        a hit on a dome: force field
  place_0..2    a block bolted on: heavy plate impacts
  take          a block taken off: a light plate
  drop          a block thrown on the ground: soft impact
  mine_0..2     a drill's blow on ore
  chop_0..1     a blow on a tree
  pickup        an item into a collector or the hand
  sale          the seller's sale
  click / open / close / error / licence   the interface
  engine        a 4 s LOOP of the drive (loop=true in its .import), pitched by speed in sfx.gd

Run from the repo root:  python3 art/game_sfx.py   (needs numpy, scipy, ffmpeg with libvorbis)
"""
import os, subprocess
import numpy as np
from scipy import signal

SR = 22050
HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, "sfx_src", "kenney")
OUT = os.path.join(HERE, "..", "resources", "sfx")


def load(name, rate=1.0):
    raw = subprocess.run(["ffmpeg", "-v", "0", "-i", os.path.join(SRC, name + ".ogg"), "-ac", "1",
                          "-ar", str(int(SR / rate)), "-f", "f32le", "-"], capture_output=True, check=True).stdout
    x = np.frombuffer(raw, np.float32).astype(np.float64)
    return x / (np.max(np.abs(x)) + 1e-9)


def lp(x, hz, o=2):
    return signal.lfilter(*signal.butter(o, hz / (SR / 2), "low"), x)


def hp(x, hz, o=2):
    return signal.lfilter(*signal.butter(o, hz / (SR / 2), "high"), x)


def bp(x, lo, hi, o=2):
    return signal.lfilter(*signal.butter(o, [lo / (SR / 2), hi / (SR / 2)], "band"), x)


def env(n, attack, decay):
    t = np.arange(n) / SR
    a = np.clip(t / max(attack, 1e-4), 0.0, 1.0)
    return a * np.exp(-t / decay)


def trim(x, sec, fade=0.03):
    """From the onset, `sec` long, with a fade at the tail - a clip's silence is not shipped."""
    i = int(np.argmax(np.abs(x) > 0.02))
    x = x[i:i + int(sec * SR)].copy()
    f = min(int(fade * SR), len(x))
    x[-f:] *= np.linspace(1.0, 0.0, f)
    return x


def norm(x, peak_db):
    return x / (np.max(np.abs(x)) + 1e-9) * 10 ** (peak_db / 20.0)


def mix(n, *parts):
    out = np.zeros(n)
    for p, g in parts:
        m = min(n, len(p))
        out[:m] += p[:m] * g
    return out


def write(name, x, peak_db=-1.0):
    x = norm(x, peak_db)
    os.makedirs(OUT, exist_ok=True)
    path = os.path.join(OUT, name + ".ogg")
    pcm = (np.clip(x, -1, 1) * 32767).astype("<i2").tobytes()
    subprocess.run(["ffmpeg", "-v", "0", "-y", "-f", "s16le", "-ar", str(SR), "-ac", "1", "-i", "-",
                    "-c:a", "libvorbis", "-q:a", "3", path], input=pcm, check=True)


def shot(seed, sec, crack_hz, body, thump_hz, thump_gain, tail):
    r = np.random.default_rng(seed)
    n = int(sec * SR)
    w = r.standard_normal(n)
    crack = hp(w, crack_hz) * env(n, 0.0005, 0.012)
    bod = bp(w, body[0], body[1]) * env(n, 0.001, tail)
    t = np.arange(n) / SR
    thump = np.sin(2 * np.pi * thump_hz * t * (1.0 - 0.4 * t / sec)) * env(n, 0.002, 0.05)
    return mix(n, (crack, 0.7), (bod, 1.0), (thump, thump_gain))


def gun():
    for i in range(3):
        write("gun_%d" % i, shot(11 + i, 0.22, 2500 + 300 * i, (300, 2400), 70 + 6 * i, 0.9, 0.045), -3.0)


def shotgun():
    a = shot(31, 0.45, 1800, (150, 1500), 55, 1.4, 0.11)
    write("shotgun", lp(a, 5000), -2.0)


def cannon():
    p = load("impactPunch_heavy_000", 0.8)
    e = load("lowFrequency_explosion_000")
    n = int(0.9 * SR)
    s = shot(41, 0.9, 1500, (80, 900), 45, 1.6, 0.16)
    x = mix(n, (trim(p, 0.4), 0.8), (trim(e, 0.9, 0.3), 0.9), (s, 0.7))
    write("cannon", x, -1.0)


def laser():
    write("laser", trim(load("laserLarge_000"), 0.65, 0.12), -3.0)


def rocket():
    r = np.random.default_rng(51)
    n = int(0.75 * SR)
    t = np.arange(n) / SR
    w = r.standard_normal(n)
    # a rush whose band rises as the rocket leaves: three bands faded across each other
    lo = bp(w, 250, 900) * np.clip(1.0 - t / 0.4, 0, 1)
    mid = bp(w, 700, 2200) * np.clip(t / 0.25, 0, 1) * np.clip(1.0 - (t - 0.25) / 0.45, 0, 1)
    rush = (lo + mid) * env(n, 0.02, 0.35)
    pop = shot(52, 0.75, 2000, (200, 1200), 60, 0.8, 0.03)
    write("rocket", mix(n, (rush, 1.0), (pop, 0.6)), -3.0)


def mortar():
    p = load("impactPunch_heavy_002", 0.7)
    n = int(0.5 * SR)
    t = np.arange(n) / SR
    tube = np.sin(2 * np.pi * 95 * t) * env(n, 0.002, 0.09) + 0.4 * np.sin(2 * np.pi * 190 * t) * env(n, 0.002, 0.05)
    write("mortar", mix(n, (trim(p, 0.5), 0.8), (tube, 0.9)), -2.0)


def clip(name, src, sec, peak=-3.0, rate=1.0, fade=0.03):
    write(name, trim(load(src, rate), sec, fade), peak)


def engine():
    """A 4 s loop from Kenney's circular engine: cut where the waveform crosses zero rising and
    cross-faded over 0.3 s, so the loop point does not click."""
    x = load("engineCircular_000")
    n = int(4.0 * SR)
    f = int(0.3 * SR)
    a = x[int(0.5 * SR):int(0.5 * SR) + n + f].copy()
    out = a[:n].copy()
    k = np.linspace(0.0, 1.0, f)
    out[:f] = a[n:n + f] * (1.0 - k) + a[:f] * k
    write("engine", lp(out, 3000), -6.0)


if __name__ == "__main__":
    gun()
    shotgun()
    cannon()
    laser()
    rocket()
    mortar()
    for i, s in enumerate(["impactMetal_light_001", "impactMetal_light_002", "impactMetal_light_004"]):
        clip("hit_%d" % i, s, 0.25, -6.0)
    clip("blast_0", "explosionCrunch_000", 1.2, -1.0, fade=0.3)
    clip("blast_1", "explosionCrunch_002", 1.2, -1.0, fade=0.3)
    clip("shield", "forceField_001", 0.5, -6.0, fade=0.15)
    for i, s in enumerate(["impactPlate_heavy_001", "impactPlate_heavy_002", "impactPlate_heavy_003"]):
        clip("place_%d" % i, s, 0.4, -4.0)
    clip("take", "impactPlate_light_002", 0.3, -6.0)
    clip("drop", "impactSoft_medium_001", 0.35, -5.0)
    for i in range(3):
        clip("mine_%d" % i, "impactMining_00%d" % i, 0.35, -5.0)
    clip("chop_0", "impactWood_heavy_000", 0.4, -4.0)
    clip("chop_1", "impactWood_heavy_001", 0.4, -4.0)
    clip("pickup", "pluck_001", 0.3, -8.0)
    clip("sale", "confirmation_002", 0.6, -6.0)
    clip("click", "click_002", 0.15, -10.0)
    clip("open", "open_002", 0.4, -8.0)
    clip("close", "close_002", 0.4, -8.0)
    clip("error", "error_006", 0.4, -8.0)
    clip("licence", "maximize_006", 0.8, -6.0)
    engine()
