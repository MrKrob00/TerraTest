#!/usr/bin/env python3
"""MARLIT'S WEAPONS: a BALL TURRET, not Falsus's platform, neck and head on a clevis (the player's
call: "do not repeat the Falsus style, something new, and it must turn easily every way").

    python3 art/marlit_weapons.py [marlit_gun|marlit_laser|marlit_shotgun|marlit_cannon|marlit_mortar]
        -> objects/<name>_texture.png + art/out/<name>.glb
    godot --headless --path . --script res://art/turret_import.gd -- <name> ...
        -> blocks/meshes/<name>_<part>.tres

THE TURN IS THE SHAPE. A faceted ball sits in a cup on an octagonal collar: the collar turns about
the vertical (yaw), the ball turns in the cup about the axis its two side trunnions show (pitch).
A ball in a socket looks the same at every angle and touches nothing as it turns, so a turret that
swings 75 deg either way and dips 40 deg reads as one moving part, not a head bending on a neck.
What it fires comes out of the PORT on the ball's front; a vented cap closes its back.

2x2x2 like every Marlit block (the anchor in a corner: x -1.5..0.5, y -0.5..1.5, z -1.5..0.5).
Everything fits the cube at rest; aiming may swing a part out, as on every turret.
  base - the casting: a chamfered slab with the faction's window on its sides and an octagonal
         plinth on top (block space; stands still)
  yaw  - the collar, the cup and the two trunnion yokes, about the turning axis at the plinth's top
  head - the ball and the weapon, about the pitch axis (the ball's middle), firing along -Z
Each weapon's head says what it does in code:
  GUN     - two barrels in shrouds side by side on a mantlet: a steady stream.
  LASER   - no barrel: a stepped lens stack with glowing cyan bands between the steps, ending in a
            cyan lens, two fins along it - a charged shot from an emitter.
  SHOTGUN - a wide flat box with a ROW of four short bores: the cone.
  CANNON  - one thick barrel, a recoil sleeve banded with sunset, a vented brake, a counterweight
            on the ball's back: the one heavy blow.
  MORTAR  - seven short wide tubes, a ring of six round one, bound by two bands: the salvo; the
            scene parks the head pitched up like the Falsus mortar's pack.
"""
import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import turret_heads as th  # noqa: E402
import emitter_models as em  # noqa: E402

CX, CZ = -0.5, -0.5          # the turning axis in block space: the 2x2 footprint's middle
BASE_TOP = -0.02             # the plinth's top: the yaw part's origin stands here
PITCH_Y = 0.62               # the ball's middle over the yaw origin: the pitch axis
R = 0.40                     # the ball: small enough that the weapon, not the ball, is the shape
REACH = 1.0                  # from the axis to the block's front face: the weapon's end at rest
LIGHT = em.LIGHT


def _tone(n):
    t = th.dot(th.norm(n), LIGHT)
    return max(0, min(4, int((t * 0.5 + 0.5) * 5.0)))


def _face(f, pts, centre, style, u_hint=None):
    q = th.outward(pts, centre)
    n = th.newell(q)
    st = style
    if style in ("m", "c"):
        st = "%stone%d" % (style, _tone(n))
    f.append(th.Face(q, st, u_hint=u_hint or th.sub(q[1], q[0])))


def _frame(ax):
    ax = th.norm(ax)
    ref = (0.0, 1.0, 0.0) if abs(ax[1]) < 0.9 else (1.0, 0.0, 0.0)
    u = th.norm(th.cross(ax, ref))
    v = th.cross(u, ax)
    return ax, u, v


def oct_tube(f, a, b, ra, rb, style="m", cap_a=None, cap_b=None, sides=8):
    """A faceted tube from a to b, ra across its flats at a and rb at b; sides toned by the light
    ("m" metal, "c" cyan) or one style; caps where a style is given."""
    ax, u, v = _frame(th.sub(b, a))
    k = 1.0 / math.cos(math.pi / sides)

    def ring(p, r):
        return [th.add(p, th.add(th.mul(u, r * k * math.cos(math.pi / sides + 2 * math.pi * i / sides)),
                                 th.mul(v, r * k * math.sin(math.pi / sides + 2 * math.pi * i / sides))))
                for i in range(sides)]
    A, B = ring(a, ra), ring(b, rb)
    mid = th.mul(th.add(a, b), 0.5)
    for i in range(sides):
        j = (i + 1) % sides
        _face(f, [A[i], A[j], B[j], B[i]], mid, style, u_hint=ax)
    if cap_a:
        _face(f, list(A), b, cap_a, u_hint=u)
    if cap_b:
        _face(f, list(B), a, cap_b, u_hint=u)
    return A, B


def band(f, a, b, ra0, ra1, style):
    """A flat ring at a looking along a->b, from ra0 out to ra1: a lip or a step."""
    ax, u, v = _frame(th.sub(b, a))
    k = 1.0 / math.cos(math.pi / 8)
    for i in range(8):
        a0 = math.pi / 8 + 2 * math.pi * i / 8
        a1 = math.pi / 8 + 2 * math.pi * (i + 1) / 8
        p = [th.add(a, th.add(th.mul(u, r * k * math.cos(t)), th.mul(v, r * k * math.sin(t))))
             for r, t in ((ra0, a0), (ra1, a0), (ra1, a1), (ra0, a1))]
        _face(f, p, th.sub(a, ax), style, u_hint=th.sub(p[1], p[0]))


def ball(f, C, r, nlon=8, nlat=6, skip=None):
    """A faceted ball: every facet its own tone from the light (the blocks are unshaded, so a round
    thing in one colour is a disc). `skip(normal)` leaves out the facets a port covers."""
    def pt(i, j):
        la = -math.pi / 2 + math.pi * j / nlat
        lo = math.pi / nlon + 2 * math.pi * i / nlon
        return (C[0] + r * math.cos(la) * math.cos(lo), C[1] + r * math.sin(la), C[2] + r * math.cos(la) * math.sin(lo))
    for j in range(nlat):
        for i in range(nlon):
            q = [pt(i, j), pt(i + 1, j), pt(i + 1, j + 1), pt(i, j + 1)]
            uq = []
            for p in q:
                if not any(math.dist(p, s) < 1e-7 for s in uq):
                    uq.append(p)
            if len(uq) < 3:
                continue
            m = th.mul(tuple(map(sum, zip(*uq))), 1.0 / len(uq))
            if skip is not None and skip(th.norm(th.sub(m, C))):
                continue
            _face(f, uq, C, "m")


def mbox(f, lo, hi, style="m"):
    c = th.mul(th.add(lo, hi), 0.5)
    h = th.mul(th.sub(hi, lo), 0.5)
    em.obox(f, c, ((1, 0, 0), (0, 1, 0), (0, 0, 1)), h, [style] * 6)
    if style in ("m", "c"):
        for face in f[-6:]:
            face.style = "%stone%d" % (style, _tone(th.newell(face.pts)))


# ── the shared mount ───────────────────────────────────────────────────────────────────────────
def _base(f, rnd):
    # the casting: a chamfered slab on the whole footprint, the faction's window on every side
    em.marlit_box(f, (-1.5, -0.5, -1.5), (0.5, BASE_TOP - 0.10, 0.5), 0.10, rnd,
                  {(0, 1): "window", (0, -1): "window", (2, 1): "window", (2, -1): "window"}, seg=2.0)
    # an octagonal plinth stepping up to the collar, a sunset line round its foot
    C = (CX, 0.0, CZ)
    y0, y1 = BASE_TOP - 0.10, BASE_TOP
    em._oct_band(f, C, 0.86, y0 + 0.002, 0.84, y0 + 0.002, "mglow")
    em._oct_band(f, C, 0.84, y0 + 0.003, 0.80, y0 + 0.003, "mtone")
    em._oct_band(f, C, 0.80, y0, 0.74, y1, "mtone")
    em._oct_band(f, C, 0.74, y1, 0.0, y1, "mflat2")


def _yaw(f):
    """About the turning axis: the collar, the cup the ball sits in, two yokes up to its trunnions."""
    C = (0.0, 0.0, 0.0)
    em._oct_band(f, C, 0.70, 0.0, 0.70, 0.12, "mtone")            # collar
    em._oct_band(f, C, 0.70, 0.12, 0.66, 0.16, "mtone")
    em._oct_band(f, C, 0.66, 0.16, 0.64, 0.16, "mglow")           # a sunset line round it
    em._oct_band(f, C, 0.64, 0.16, 0.56, 0.30, "mtone")           # the cup's outside, up to its lip
    em._oct_band(f, C, 0.56, 0.30, 0.48, 0.30, "mflat3")          # the lip
    em._oct_band(f, C, 0.48, 0.30, 0.30, 0.22, "mflat0", down=True)   # the cup's dark inside
    em._oct_band(f, C, 0.30, 0.22, 0.0, 0.22, "mflat0")
    # the yokes: a plate either side rising to the pitch axis, a trunnion pin through its top
    for sx in (-1.0, 1.0):
        x = sx * (R + 0.09)
        mbox(f, (x - 0.06, 0.12, -0.16), (x + 0.06, PITCH_Y + 0.08, 0.16))
        em._mwl_oct_prism(f, (x + sx * 0.03, PITCH_Y, 0.0), (1.0, 0.0, 0.0), 0.10, 0.06, None, "mpin")
        # the yoke's sunset slit facing out
        xs = x + sx * 0.061
        q = [(xs, 0.24, -0.025), (xs, 0.24, 0.025), (xs, PITCH_Y - 0.14, 0.025), (xs, PITCH_Y - 0.14, -0.025)]
        _face(f, q, (x, 0.4, 0.0), "mglow", u_hint=(0, 1, 0))


def _ball_and_port(f, port=0.30, back="vent"):
    """The ball about the pitch axis, a port on its front for the weapon, a cap on its back."""
    zf = -math.sqrt(max(R * R - port * port, 0.0))
    ball(f, (0.0, 0.0, 0.0), R, skip=lambda n: n[2] < -0.80)
    # the port: a flat octagonal collar proud of the ball, a sunset rim, a dark face
    a, b = (0.0, 0.0, zf + 0.06), (0.0, 0.0, zf - 0.04)
    oct_tube(f, a, b, port + 0.02, port, "m")
    band(f, b, th.add(b, (0, 0, -1)), port - 0.035, port, "mglow")
    band(f, b, th.add(b, (0, 0, -1)), 0.0, port - 0.035, "mflat1")
    # the back: a vented cap, or a counterweight for the heavy gun
    zb = math.sqrt(R * R - 0.18 * 0.18)
    if back == "vent":
        oct_tube(f, (0, 0, zb - 0.06), (0, 0, zb + 0.05), 0.20, 0.18, "m", cap_b="mvent")
    return zf - 0.04


def _head_gun(f):
    z = _ball_and_port(f)
    # a mantlet plate, the two shrouded barrels side by side, a rib between them over the top
    em.marlit_box(f, (-0.30, -0.17, z - 0.10), (0.30, 0.17, z), 0.03, None)
    z0 = z - 0.10
    for sx in (-1.0, 1.0):
        x = sx * 0.15
        oct_tube(f, (x, 0, z0), (x, 0, z0 - 0.36), 0.11, 0.10, "m")
        band(f, (x, 0, z0 - 0.36), (x, 0, z0 - 1.0), 0.065, 0.10, "mflat2")
        oct_tube(f, (x, 0, z0 - 0.36), (x, 0, -REACH + 0.09), 0.065, 0.065, "m")
        oct_tube(f, (x, 0, -REACH + 0.09), (x, 0, -REACH), 0.09, 0.09, "m", cap_b="mflat0")
        band(f, (x, 0, -REACH - 0.001), (x, 0, -REACH - 1), 0.06, 0.09, "mglow")
        # the sunset slits along each shroud's top
        q = [(x - 0.025, 0.112, z0 - 0.05), (x + 0.025, 0.112, z0 - 0.05), (x + 0.025, 0.112, z0 - 0.31),
             (x - 0.025, 0.112, z0 - 0.31)]
        _face(f, q, (x, 0, z0 - 0.17), "mglow", u_hint=(0, 0, 1))
    mbox(f, (-0.04, 0.03, z0 - 0.32), (0.04, 0.14, z0))


def _head_laser(f):
    z = _ball_and_port(f, port=0.26)
    # a stepped lens stack: metal steps with glowing cyan bands between them, narrowing to the lens
    steps = [(0.25, 0.14), (0.215, 0.13), (0.18, 0.12)]
    zz = z
    for i, (r, ln) in enumerate(steps):
        oct_tube(f, (0, 0, zz), (0, 0, zz - ln), r, r, "m")
        zz -= ln
        band(f, (0, 0, zz), (0, 0, zz - 1), r - 0.03, r, "mflat3")
        oct_tube(f, (0, 0, zz), (0, 0, zz - 0.035), r - 0.03, r - 0.03, "c")
        zz -= 0.035
    oct_tube(f, (0, 0, zz), (0, 0, -REACH + 0.03), 0.15, 0.12, "m")
    oct_tube(f, (0, 0, -REACH + 0.03), (0, 0, -REACH), 0.12, 0.11, "c", cap_b="cyan3")
    # two fins along the stack, a sunset edge on each
    for sx in (-1.0, 1.0):
        x0, x1 = sx * 0.22, sx * 0.40
        y = 0.03
        top = [(x0, y, z - 0.02), (x1, y, z - 0.10), (x1, y, -REACH + 0.20), (x0 * 0.6, y, -REACH + 0.10)]
        bot = [(p[0], -y, p[2]) for p in top]
        _face(f, top, (sx * 0.25, -1, -0.6), "m")
        _face(f, bot, (sx * 0.25, 1, -0.6), "m")
        for i in range(4):
            j = (i + 1) % 4
            st = "mglow" if i == 1 else "m"
            _face(f, [top[i], top[j], bot[j], bot[i]], (sx * 0.25, 0, -0.6), st)


def _head_shotgun(f):
    z = _ball_and_port(f)
    # a wide flat box, a sunset band round its front, a row of four short wide bores
    em.marlit_box(f, (-0.38, -0.15, z - 0.36), (0.38, 0.15, z), 0.035, None)
    zf = z - 0.36
    for y in (0.15 + 0.002, -0.15 - 0.002):
        q = [(-0.34, y, zf + 0.04), (0.34, y, zf + 0.04), (0.34, y, zf + 0.10), (-0.34, y, zf + 0.10)]
        _face(f, q, (0, 0, zf + 0.06), "mhazard", u_hint=(1, 0, 0))
    for x in (-0.27, -0.09, 0.09, 0.27):
        oct_tube(f, (x, 0, zf), (x, 0, -REACH + 0.05), 0.075, 0.075, "m")
        oct_tube(f, (x, 0, -REACH + 0.05), (x, 0, -REACH), 0.082, 0.088, "m", cap_b="mflat0")
        band(f, (x, 0, -REACH - 0.001), (x, 0, -REACH - 1), 0.055, 0.085, "mglow")


def _head_cannon(f):
    z = _ball_and_port(f, port=0.30, back="weight")
    # the counterweight: a heavy octagonal block on the ball's back
    zb = math.sqrt(R * R - 0.25 * 0.25)
    oct_tube(f, (0, 0, zb - 0.08), (0, 0, zb + 0.18), 0.28, 0.25, "m", cap_b="mvent")
    # the recoil sleeve, banded, then the barrel and a vented brake
    oct_tube(f, (0, 0, z), (0, 0, z - 0.24), 0.23, 0.20, "m")
    for zz, rr in ((z - 0.06, 0.226), (z - 0.17, 0.214)):
        oct_tube(f, (0, 0, zz), (0, 0, zz - 0.03), rr, rr, "mglow")
    band(f, (0, 0, z - 0.24), (0, 0, z - 1), 0.13, 0.20, "mflat2")
    oct_tube(f, (0, 0, z - 0.24), (0, 0, -REACH + 0.16), 0.13, 0.125, "m")
    oct_tube(f, (0, 0, -REACH + 0.16), (0, 0, -REACH), 0.19, 0.19, "mvent", cap_a="mflat2", cap_b="mflat0")
    band(f, (0, 0, -REACH - 0.001), (0, 0, -REACH - 1), 0.085, 0.18, "mtone2")


def _head_mortar(f):
    z = _ball_and_port(f, port=0.34)
    # seven short wide tubes - a ring of six round one - bound by two bands
    pos = [(0.0, 0.0)] + [(0.21 * math.cos(math.pi / 6 + k * math.pi / 3), 0.21 * math.sin(math.pi / 6 + k * math.pi / 3))
                          for k in range(6)]
    zend = -REACH + 0.10
    for x, y in pos:
        oct_tube(f, (x, y, z), (x, y, zend), 0.085, 0.085, "m")
        oct_tube(f, (x, y, zend), (x, y, zend - 0.05), 0.095, 0.095, "m", cap_b="mflat0")
        band(f, (x, y, zend - 0.051), (x, y, zend - 1), 0.06, 0.095, "mglow")
    for zz in (z - 0.08, zend + 0.05):
        oct_tube(f, (0, 0, zz), (0, 0, zz - 0.07), 0.33, 0.33, "m")
        band(f, (0, 0, zz), (0, 0, zz + 1), 0.29, 0.33, "mflat3")
        band(f, (0, 0, zz - 0.07), (0, 0, zz - 1), 0.29, 0.33, "mflat2")


HEADS = {
    "marlit_gun": _head_gun,
    "marlit_laser": _head_laser,
    "marlit_shotgun": _head_shotgun,
    "marlit_cannon": _head_cannon,
    "marlit_mortar": _head_mortar,
}


def _builder(name):
    def build(pk, img):
        import random as _r
        rnd = _r.Random(len(name) * 31)
        parts = {name + "_base": [], name + "_yaw": [], name + "_head": []}
        _base(parts[name + "_base"], rnd)
        _yaw(parts[name + "_yaw"])
        HEADS[name](parts[name + "_head"])
        return parts
    return build


for _i, _n in enumerate(HEADS):
    em.BLOCKS[_n] = (301 + _i * 7, _builder(_n), 512)
    em.DENSITY[_n] = 40.0

if __name__ == "__main__":
    for nm in (sys.argv[1:] or list(HEADS)):
        em.make(nm)
