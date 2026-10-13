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


# ── the riser ───────────────────────────────────────────────────────────────────────────────────
# AFTER THE PLAYER'S PICTURE OF TERRATECH'S: a rounded mount under the top face and ONE THICK CAST ARM
# leaving its underside, sweeping down and out to the hub on the tyre's inner face; the tyre stands at
# the side, its outer face a few centimetres past the cell, its bottom under it. The arm turns about the
# mount's bearing (steering) and slides into it (suspension). No box, no slot, no thin parts.

PIVOT_R = (0.0, 0.10, 0.18)   # the bearing under the mount: the steering axis' foot
TC_R = (0.0, -0.36, -0.40)    # the tyre's middle: outer face at z -0.55, bottom at y -0.66
TYRE_IN_R = TC_R[2] + TYRE_W / 2


def build_riser(pk, img):
    parts = {"riser_body": [], "riser_arm": []}
    b, a = parts["riser_body"], parts["riser_arm"]
    px, py, pz = PIVOT_R
    # the mount: a heavy, deeply chamfered blue block nearly the cell's width under the plate
    th.prism(b, -0.40, 0.40, py + 0.04, PLATE_IN, 0.46, -0.10, 0.10, cap_front="blue", cap_back="blue",
             top_style="blue")
    # the bearing ring the arm leaves through
    em.tube(b, [(px, py + 0.05, pz), (px, py - 0.02, pz)], [0.17, 0.17], ["m"], sides=10, cap_end="dark_edge")
    # the ARM: root inside the bearing, one curve down and out to the hub
    hub = (TC_R[0], TC_R[1], TYRE_IN_R + 0.07)
    path = bezier3((px, py + 0.04, pz), (px, TC_R[1] + 0.02, pz + 0.02), hub, 8)
    sweep(a, path, (1, 0, 0), 0.24, 0.17, taper=0.85)
    boss(a, hub, (0, 0, -1), 0.12, 0.07)
    _shift(a, PIVOT_R)
    return parts


# ── the stabiliser ──────────────────────────────────────────────────────────────────────────────
# AFTER THE PLAYER'S SECOND PICTURE: the tyre rolls along the machine in the middle (a tricycle's one
# wheel), and ONE THICK ARM leaves the mount on the plate on the tyre's +X side, runs back over the
# tyre, bends down behind it and hooks forward into the hub - a C round the tyre's back half. It swings
# about a pin across the mount (suspension); the mount turns about the vertical (steering).

PIN_S = (0.0, -0.06, 0.20)    # the arm's pin across the mount (axis X): the suspension swings about it
TC_S = (0.0, -0.60, -0.04)    # the tyre's middle: ride height 0.90, like the standard wheel
ARM_X = TYRE_W / 2 + 0.075    # the arm runs down the tyre's +X side


def build_stab2(pk, img):
    parts = {"stab2_body": [], "stab2_arm": []}
    b, a = parts["stab2_body"], parts["stab2_arm"]
    # the mount on the plate: a deep chamfered blue block
    th.prism(b, -0.30, 0.30, -0.16, 0.24, PLATE_IN, 0.06, 0.09, cap_front="blue", cap_back="blue",
             top_style="blue")
    c = TC_S
    # the ARM: from the pin back over the tyre, down behind it, forward into the hub
    path = bezier4((ARM_X, PIN_S[1], PIN_S[2]), (ARM_X, -0.16, -0.30), (ARM_X, c[1] - 0.02, -0.62),
                   (ARM_X, c[1], c[2] - 0.08), 10)
    sweep(a, path, (1, 0, 0), 0.12, 0.17, taper=0.9)
    boss(a, (ARM_X + 0.06, c[1], c[2]), (-1, 0, 0), 0.13, 0.12)
    boss(a, (TYRE_W / 2 + 0.005, c[1], c[2]), (1, 0, 0), 0.06, 0.02, kind="m")
    # the pin through the arm's root, its boss on the mount's side
    em.tube(a, [(-0.32, PIN_S[1], PIN_S[2]), (ARM_X + 0.08, PIN_S[1], PIN_S[2])], [0.08, 0.08], ["m"], sides=8,
            cap_start="dark_edge", cap_end="dark_edge")
    _shift(a, PIN_S)
    return parts


em.BLOCKS["riser"] = (431, build_riser, 256)
em.BLOCKS["stab2"] = (433, build_stab2, 256)
em.CULL |= {"riser", "stab2"}
if not hasattr(em, "CHECKS"):
    em.CHECKS = {}
em.CHECKS["riser"] = {"cells": ((-0.5, -0.75, -0.6), (0.5, 0.5, 0.5)), "budget": 400,
                      "origins": {"riser_arm": PIVOT_R}}
em.CHECKS["stab2"] = {"cells": ((-0.5, -0.75, -0.5), (0.5, 0.5, 0.5)), "budget": 400,
                      "origins": {"stab2_arm": PIN_S}}

if __name__ == "__main__":
    for nm in (sys.argv[1:] or ["riser", "stab2"]):
        em.make(nm)
