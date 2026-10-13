#!/usr/bin/env python3
"""FALSUS'S RISER AND STABILISER, one cell each. DRAFTS for the player's approval: generator only.

    python3 art/falsus_wheels.py [riser|stab2]
        -> objects/<name>_texture.png + art/out/<name>.glb (one node per part)

THE ARTIST'S WHEEL IS THE GRAMMAR (Assets.glb Wheel_module / Wheel_susp_* / Wheel_Axle): a flat
PLATFORM PLATE on the face the block joins by, a short arm of chamfered bars out of it, the hub, the
tyre. Both blocks keep that: the artist's plate on the joining face (placed by the scene), the
artist's SMALL tyre (r 0.30, 0.30 wide), and between them only what is new - in the family's
colours: GSO blue for housings, dark metal for what moves, the light edge line on every face.

RISER - joins by its TOP face (the player: "it hangs by its top, a little wheel sticks out at the
side"). The plate lies under the cell's top and a drive box hangs from it; the tyre stands at the
box's front (-Z) side, its outer face a few centimetres past the cell and its bottom under it - the
block lifts the machine by most of a cell.
  body - the drive box and the slot's rails (still)
  slider - the shoe in the slot and the stub to the steering clevis (slides along Y)
  knuckle - the steering pin's upright and the hub drum, about KP_R (rides the slider, turns about Y)

STAB2 - joins by its BACK face like every wheel, but the tyre ROLLS ALONG THE MACHINE (axle X), in
the middle, like a tricycle's single wheel (the player). A steering head on the plate, a crown
under it, and a FORK of two telescoping legs that trail back to a through-axle with a hub motor
drum - the drive sits in the hub, so nothing between the plate and the tyre has to turn.
  body  - steering head and its brackets (still)
  crown - the crown and the legs' upper sleeves, about HEAD (turns about Y)
  fork  - the legs' lower sliders, the axle and the hub drum, about HEAD (slides along FORK_DIR)
"""
import math
import os
import random
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import turret_heads as th  # noqa: E402
import emitter_models as em  # noqa: E402

PLATE_IN = 0.373              # the artist's plate is 0.127 thick: its inner face stands here
TYRE_R = 0.30                 # the artist's small tyre
TYRE_W = 0.30


def _shift(faces, origin):
    for fc in faces:
        fc.pts = [th.sub(p, origin) for p in fc.pts]


def bar(faces, a, b, r, kind="m", sides=8, cap=True):
    """A chamfered bar from a to b: an octagonal prism toned facet by facet (dark metal "m", blue "b"),
    its ends capped with the family's edge line."""
    em.tube(faces, [a, b], [r / math.cos(math.pi / sides)] * 2, [kind], sides=sides,
            cap_start="dark_edge" if cap else None, cap_end="dark_edge" if cap else None)


def cbox(faces, lo, hi, c=0.03, side="dark", top="dark", bottom="dark", edge="dark_edge"):
    em.cham_box(faces, lo, hi, c, side, top, bottom, edge)


def sweep(faces, path, side, w, h, kind="b", sides=12, taper=1.0, caps=True):
    """A thick CAST ARM along a 3D polyline: a rounded-rectangle section (superellipse) w across along
    `side` and h thick, shrinking to `taper` at the far end; every facet toned by the painted light
    ("b" GSO blue, "m" dark metal) - the blocks are unshaded, so a round bar needs its light painted."""
    n = len(path)
    rings = []
    for i, p in enumerate(path):
        t = th.norm(th.sub(path[min(i + 1, n - 1)], path[max(i - 1, 0)]))
        sd = th.norm(th.sub(side, th.mul(t, th.dot(side, t))))
        nm = th.cross(sd, t)
        k = 1.0 + (taper - 1.0) * i / max(n - 1, 1)
        ring = []
        for j in range(sides):
            ang = (j + 0.5) * 2 * math.pi / sides
            c, sn = math.cos(ang), math.sin(ang)
            cu = math.copysign(abs(c) ** 0.5, c) * w / 2 * k
            su = math.copysign(abs(sn) ** 0.5, sn) * h / 2 * k
            ring.append(th.add(p, th.add(th.mul(sd, cu), th.mul(nm, su))))
        rings.append(ring)
    for i in range(n - 1):
        mid = th.mul(th.add(path[i], path[i + 1]), 0.5)
        for j in range(sides):
            jj = (j + 1) % sides
            q = th.outward([rings[i][j], rings[i][jj], rings[i + 1][jj], rings[i + 1][j]], mid)
            tone = int(round(max(0.0, min(1.0, 0.5 + 0.5 * th.dot(th.norm(th.newell(q)), em.LIGHT))) * 4))
            st = ("bflat%d" % tone) if kind == "b" else ("%stone%d" % (kind, tone))
            faces.append(th.Face(q, st, u_hint=th.sub(path[i + 1], path[i])))
    if caps:
        for ring, i, j in ((rings[0], 0, 1), (rings[-1], n - 1, n - 2)):
            inside = th.add(path[i], th.mul(th.norm(th.sub(path[j], path[i])), 0.05))
            faces.append(th.Face(th.outward(list(ring), inside), "dark_edge", u_hint=side))


def bezier3(p0, p1, p2, steps):
    return [tuple((1 - t) ** 2 * p0[k] + 2 * (1 - t) * t * p1[k] + t * t * p2[k] for k in range(3))
            for t in [i / steps for i in range(steps + 1)]]


def bezier4(p0, p1, p2, p3, steps):
    return [tuple((1 - t) ** 3 * p0[k] + 3 * (1 - t) ** 2 * t * p1[k] + 3 * (1 - t) * t * t * p2[k] + t ** 3 * p3[k]
                  for k in range(3)) for t in [i / steps for i in range(steps + 1)]]


def arc(c, r, a0, a1, steps, x):
    """Points on a circle in the YZ plane round c (angle 0 = toward -Z, 90 = up), at x."""
    out = []
    for i in range(steps + 1):
        a = math.radians(a0 + (a1 - a0) * i / steps)
        out.append((x, c[1] + r * math.sin(a), c[2] - r * math.cos(a)))
    return out


def boss(faces, c, axis, r, length, kind="b"):
    """A round boss on an axis: the hub cap where an arm meets the tyre."""
    e = th.add(c, th.mul(axis, length))
    em.tube(faces, [c, e], [r / math.cos(math.pi / 10)] * 2, [kind], sides=10, cap_start="dark_edge",
            cap_end="dark_edge")


# ── the drive, shared by both ───────────────────────────────────────────────────────────────────
# THE TRANSMISSION IS DRAWN, AND IT IS ONE STORY ON BOTH BLOCKS (the player: the bare cast arm was
# "ugly without a transmission"): the ARM is a CHAIN CASE, a stadium of GSO blue between two round
# SPROCKET COVERS (dark, bolted, a hub cap in the middle) - the round ends say "a chain turns in here"
# - its near end turning on a blue bearing housing on the mount, its far cover the tyre's hub. A swing
# arm with the drive in it changes no length when it swings: the chain runs between two fixed centres.
# NO MOTOR CAN: a finned can on the pivot was tried and the player did not like it - the drive sits in
# the mount.


def chain_case(faces, P, H, rp, rh, n, t, steps=6):
    """The swing arm as a CHAIN CASE: a stadium outline from the pivot P (radius rp) to the hub H
    (radius rh) in the plane normal to n, t thick along n; flat faces painted as GSO panels, the rim
    toned facet by facet."""
    u = th.norm(th.sub(H, P))
    v = th.norm(th.cross(n, u))
    out = []
    for i in range(steps + 1):                      # round the pivot end, from +v to -v the back way
        a = math.pi / 2 + math.pi * i / steps
        out.append(th.add(P, th.add(th.mul(u, rp * math.cos(a)), th.mul(v, rp * math.sin(a)))))
    for i in range(steps + 1):                      # round the hub end, from -v to +v the front way
        a = -math.pi / 2 + math.pi * i / steps
        out.append(th.add(H, th.add(th.mul(u, rh * math.cos(a)), th.mul(v, rh * math.sin(a)))))
    lo = [th.add(p, th.mul(n, -t / 2)) for p in out]
    hi = [th.add(p, th.mul(n, t / 2)) for p in out]
    c = th.mul(th.add(P, H), 0.5)
    m = len(out)
    for i in range(m):
        j = (i + 1) % m
        q = th.outward([lo[i], lo[j], hi[j], hi[i]], c)
        tone = int(round(max(0.0, min(1.0, 0.5 + 0.5 * th.dot(th.norm(th.newell(q)), em.LIGHT))) * 4))
        faces.append(th.Face(q, "bflat%d" % tone, u_hint=th.sub(hi[i], lo[i])))
    faces.append(th.Face(th.outward(list(lo), th.add(c, n)), "blue", u_hint=u))
    faces.append(th.Face(th.outward(list(hi), th.sub(c, n)), "blue", u_hint=u))


def sprocket_cover(faces, c, n, r, depth=0.035, bolts=6):
    """A round bolted cover on a chain case's face at c, looking along n: a dark disc, a bolt ring and
    a raised hub cap in the middle."""
    k = 1.0 / math.cos(math.pi / 10)
    e = th.add(c, th.mul(n, depth))
    em.tube(faces, [c, e], [r * k] * 2, ["m"], sides=10, cap_end="dark")
    ref = (0, 1, 0) if abs(n[1]) < 0.9 else (1, 0, 0)
    u = th.norm(th.cross(n, ref))
    v = th.cross(n, u)
    for i in range(bolts):
        a = 2 * math.pi * i / bolts
        d = th.add(th.mul(u, math.cos(a) * r * 0.72), th.mul(v, math.sin(a) * r * 0.72))
        em.obox(faces, th.add(e, d), (n, u, v), (0.008, 0.018, 0.018), ["dark_edge"] * 6)
    em.tube(faces, [e, th.add(e, th.mul(n, 0.03))], [r * 0.38 * k] * 2, ["b"], sides=8, cap_end="cap_bolt")


# ── the riser ───────────────────────────────────────────────────────────────────────────────────
# AFTER THE PLAYER'S FIRST PICTURE: a mount under the top face and one thick arm from its upper corner
# down and sideways to the hub, the tyre beside it. Here: a blue turntable housing under the artist's
# plate; under it the HEAD that steers - a bracket and the bearing housing of the arm's pivot; the CHAIN CASE
# from the pivot down-left to the hub; the tyre at the side, its outer face a few cm past the cell.

TURN_AX = (0.10, 0.02)        # (x, z) of the steering axis: the turntable's middle
PIVOT_R = (0.16, 0.06, -0.15) # the arm's pivot (axis Z), the motor's shaft
TC_R = (-0.14, -0.36, -0.40)  # the tyre's middle: outer face at z -0.55, bottom at y -0.66
TYRE_IN_R = TC_R[2] + TYRE_W / 2
ARM_Z = TYRE_IN_R + 0.065     # the chain case's mid-plane, just inside the tyre's inner face


def build_riser(pk, img):
    parts = {"riser_body": [], "riser_head": [], "riser_arm": []}
    b, h, a = parts["riser_body"], parts["riser_head"], parts["riser_arm"]
    tx, tz = TURN_AX
    # the turntable housing under the plate, and its dark bearing ring
    th.prism(b, -0.42, 0.42, 0.22, PLATE_IN, 0.44, -0.30, 0.09, cap_front="blue", cap_back="blue", top_style="blue")
    em.tube(b, [(tx, 0.22, tz), (tx, 0.18, tz)], [0.22, 0.22], ["m"], sides=12, cap_end="dark")
    # the HEAD: a bracket hanging from the bearing, the motor on the pivot (axis Z, from the back)
    px, py, pz = PIVOT_R
    em.cham_box(h, (tx - 0.13, py + 0.08, tz - 0.13), (tx + 0.13, 0.18, tz + 0.13), 0.03, "dark", "dark", "dark",
                "dark_edge")
    # the pivot's bearing housing: a short blue drum the chain case turns on, the drive inside it
    em.tube(h, [(px, py, tz + 0.12), (px, py, ARM_Z + 0.05)], [0.15, 0.15], ["b"], sides=10, cap_start="blue")
    _shift(h, (tx, 0.0, tz))
    # the ARM: the chain case from the pivot to the hub, a sprocket cover at each end on its outer face
    P = (px, py, ARM_Z)
    H = (TC_R[0], TC_R[1], ARM_Z)
    chain_case(a, P, H, 0.12, 0.13, (0, 0, 1), 0.10)
    sprocket_cover(a, (P[0], P[1], ARM_Z - 0.05), (0, 0, -1), 0.10)
    sprocket_cover(a, (H[0], H[1], ARM_Z - 0.05), (0, 0, -1), 0.11, bolts=5)
    _shift(a, PIVOT_R)
    return parts


# ── the stabiliser ──────────────────────────────────────────────────────────────────────────────
# AFTER THE PLAYER'S SECOND PICTURE: the tyre rolls along the machine in the middle (a tricycle's one
# wheel) and a curved GUARD arches over it. Here: a blue mount on the artist's plate, a bearing housing
# across it on the arm's pivot (axis X), the CHAIN CASE trailing back and down the tyre's +X side to the hub,
# and the guard riding on the arm over the tyre's crown. The mount's lower half (the head) steers.

TURN_S = (0.0, 0.16)          # (x, z) of the steering axis
PIN_S = (0.0, -0.10, 0.16)    # the arm's pivot (axis X), the motor's shaft
TC_S = (0.0, -0.60, -0.12)    # the tyre's middle: ride height 0.90, like the standard wheel
ARM_X = TYRE_W / 2 + 0.07     # the chain case's mid-plane, on the tyre's +X side
GUARD_R = 0.40


def build_stab2(pk, img):
    parts = {"stab2_body": [], "stab2_head": [], "stab2_arm": []}
    b, h, a = parts["stab2_body"], parts["stab2_head"], parts["stab2_arm"]
    tx, tz = TURN_S
    # the mount on the plate and the turntable under it
    th.prism(b, -0.30, 0.30, 0.06, 0.34, PLATE_IN, 0.02, 0.08, cap_front="blue", cap_back="blue", top_style="blue")
    em.tube(b, [(tx, 0.06, tz), (tx, 0.02, tz)], [0.20, 0.20], ["m"], sides=12, cap_end="dark")
    # the HEAD: a bracket under the turntable, the motor across it on the pivot
    px, py, pz = PIN_S
    em.cham_box(h, (tx - 0.20, py - 0.06, tz - 0.12), (tx + 0.20, 0.02, tz + 0.12), 0.03, "dark", "dark", "dark",
                "dark_edge")
    # the pivot's bearing housing across the head, the drive inside it
    em.tube(h, [(-0.24, py, pz), (ARM_X - 0.045, py, pz)], [0.12, 0.12], ["b"], sides=10, cap_start="blue")
    _shift(h, (tx, 0.0, tz))
    # the ARM: the chain case back and down to the hub, covers outward (+X), and the guard on it
    P = (ARM_X, py, pz)
    H = (ARM_X, TC_S[1], TC_S[2])
    chain_case(a, P, H, 0.11, 0.12, (1, 0, 0), 0.09)
    sprocket_cover(a, (ARM_X + 0.045, P[1], P[2]), (1, 0, 0), 0.09)
    sprocket_cover(a, (ARM_X + 0.045, H[1], H[2]), (1, 0, 0), 0.10, bolts=5)
    # the axle stub through the hub to the tyre
    em.tube(a, [(ARM_X - 0.05, H[1], H[2]), (TYRE_W / 2 - 0.02, H[1], H[2])], [0.07, 0.07], ["m"], sides=8)
    # the GUARD: an arc over the tyre's crown, its strut down to the case
    path = arc(TC_S, GUARD_R, 35, 150, 8, 0.0)
    sweep(a, path, (1, 0, 0), TYRE_W + 0.10, 0.05, kind="b", sides=8)
    mid = path[3]
    sweep(a, [(ARM_X, mid[1], mid[2]), (ARM_X, (mid[1] + H[1]) / 2 + 0.05, (mid[2] + H[2]) / 2)], (0, 0, 1),
          0.08, 0.06, kind="b", sides=8)
    _shift(a, PIN_S)
    return parts


em.BLOCKS["riser"] = (431, build_riser, 256)
em.BLOCKS["stab2"] = (433, build_stab2, 256)
em.CULL |= {"riser", "stab2"}
if not hasattr(em, "CHECKS"):
    em.CHECKS = {}
em.CHECKS["riser"] = {"cells": ((-0.5, -0.75, -0.6), (0.5, 0.5, 0.5)), "budget": 600,
                      "origins": {"riser_head": (TURN_AX[0], 0.0, TURN_AX[1]), "riser_arm": PIVOT_R}}
em.CHECKS["stab2"] = {"cells": ((-0.5, -0.75, -0.5), (0.5, 0.5, 0.5)), "budget": 600,
                      "origins": {"stab2_head": (TURN_S[0], 0.0, TURN_S[1]), "stab2_arm": PIN_S}}

if __name__ == "__main__":
    for nm in (sys.argv[1:] or ["riser", "stab2"]):
        em.make(nm)
