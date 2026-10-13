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


# ── the riser ───────────────────────────────────────────────────────────────────────────────────
# A BODY WITH A WHEEL AT ITS SIDE, not a leg: the back two-thirds of the cell is the drive box hanging
# from the plate, grilled on its sides like the family's panels; on its front (-Z) face two blue
# rails frame a slot, and the SLIDER rides in it (the artist's wheel arm runs in the same kind of slot
# in its plate). From the slider a short stub carries the steering clevis, and the KNUCKLE turns in
# it, right beside the tyre - so steering turns the tyre about a pin near its own face instead of
# swinging it round the box.

BOX = (-0.42, 0.42, -0.46, PLATE_IN, -0.04, 0.42)    # x0, x1, y0, y1, z0, z1
TC_R = (0.0, -0.36, -0.40)    # the tyre's middle: outer face at z -0.55, bottom at y -0.66
KP_R = (0.0, -0.36, -0.17)    # the steering pin, between the box's face and the tyre's inner face
RAIL_X = 0.13


def build_riser(pk, img):
    parts = {"riser_body": [], "riser_slider": [], "riser_knuckle": []}
    b, sl, k = parts["riser_body"], parts["riser_slider"], parts["riser_knuckle"]
    x0, x1, y0, y1, z0, z1 = BOX
    # the box: grilled dark sides, a plain dark front behind the slot, a hazard band at its foot
    cbox(b, (x0, y0 + 0.06, z0), (x1, y1, z1), 0.05, side="plain_side", top="dark", bottom="dark")
    cbox(b, (x0 + 0.01, y0, z0 + 0.01), (x1 - 0.01, y0 + 0.07, z1 - 0.01), 0.03, side="stripe")
    # the slot's rails, standing proud of the front face
    for sx in (-1, 1):
        th.box(b, (sx * RAIL_X - 0.04, y0 + 0.04, z0 - 0.05), (sx * RAIL_X + 0.04, 0.24, z0 + 0.005), "blue",
               skip=("+z",))
    th.box(b, (-RAIL_X - 0.04, 0.20, z0 - 0.05), (RAIL_X + 0.04, 0.27, z0 + 0.005), "blue", skip=("+z",))
    # the SLIDER: a shoe between the rails, the stub out to the clevis round the steering pin
    ky = KP_R[1]
    th.box(sl, (-RAIL_X + 0.045, ky - 0.10, z0 - 0.05), (RAIL_X - 0.045, ky + 0.10, z0 + 0.02), "dark", skip=("+z",))
    bar(sl, (0, ky, z0 - 0.05), (0, ky, KP_R[2] + 0.06), 0.06)
    for sy in (-1, 1):
        th.box(sl, (-0.07, ky + sy * 0.085 - 0.025, KP_R[2] - 0.06), (0.07, ky + sy * 0.085 + 0.025, KP_R[2] + 0.07),
               "dark")
    _shift(sl, (0.0, 0.0, 0.0))
    # the KNUCKLE: the pin, an upright between the clevis plates, the hub drum against the tyre
    bar(k, (0, ky - 0.12, KP_R[2]), (0, ky + 0.12, KP_R[2]), 0.035, kind="m")
    th.box(k, (-0.06, ky - 0.055, KP_R[2] - 0.05), (0.06, ky + 0.055, KP_R[2] + 0.05), "dark")
    zin = TC_R[2] + TYRE_W / 2
    bar(k, (0, ky, KP_R[2] - 0.05), (0, ky, zin + 0.004), 0.12, kind="b")
    _shift(k, KP_R)
    return parts


# ── the stabiliser ──────────────────────────────────────────────────────────────────────────────

HEAD = (0.0, 0.0, 0.23)       # the steering axis' foot: on the plate, in the middle
TC_S = (0.0, -0.60, -0.12)    # the tyre's middle: ride height 0.90, like the standard wheel
CROWN_Y = -0.10
LEG_X = 0.215                 # the fork legs, either side of the 0.30 tyre


def build_stab2(pk, img):
    parts = {"stab2_body": [], "stab2_crown": [], "stab2_fork": []}
    b, c, f = parts["stab2_body"], parts["stab2_crown"], parts["stab2_fork"]
    hx, hy, hz = HEAD
    # the steering head: a blue housing on the plate, the bearing under it
    cbox(b, (hx - 0.20, hy - 0.06, hz - 0.06), (hx + 0.20, hy + 0.36, PLATE_IN), 0.04,
         side="blue", top="blue", bottom="blue", edge="bevel")
    bar(b, (hx, hy - 0.06, hz), (hx, CROWN_Y + 0.05, hz), 0.11, kind="b")
    # the CROWN: a yoke across under the head, the legs' upper sleeves down from its ends
    cbox(c, (hx - LEG_X - 0.07, CROWN_Y - 0.05, hz - 0.08), (hx + LEG_X + 0.07, CROWN_Y + 0.05, hz + 0.08), 0.025)
    top = (CROWN_Y - 0.05)
    fd = th.norm(th.sub((0, TC_S[1], TC_S[2]), (0, top, hz)))
    for sx in (-1, 1):
        x = hx + sx * LEG_X
        a = (x, top, hz)
        bar(c, a, th.add(a, th.mul(fd, 0.26)), 0.065, kind="b")
    # the FORK: lower sliders from inside the sleeves to the axle, the through-axle, the hub drum
    for sx in (-1, 1):
        x = hx + sx * LEG_X
        a = th.add((x, top, hz), th.mul(fd, 0.16))
        bar(f, a, (x, TC_S[1], TC_S[2]), 0.048)
        th.box(f, (x - 0.045, TC_S[1] - 0.07, TC_S[2] - 0.07), (x + 0.045, TC_S[1] + 0.07, TC_S[2] + 0.07), "dark")
    bar(f, (hx - LEG_X - 0.05, TC_S[1], TC_S[2]), (hx + LEG_X + 0.05, TC_S[1], TC_S[2]), 0.025, kind="m")
    for sx in (-1, 1):
        bar(f, (hx + sx * (TYRE_W / 2 + 0.005), TC_S[1], TC_S[2]), (hx + sx * (TYRE_W / 2 + 0.05), TC_S[1], TC_S[2]),
            0.09, kind="b")
    _shift(c, HEAD)
    _shift(f, HEAD)
    return parts


em.BLOCKS["riser"] = (431, build_riser, 256)
em.BLOCKS["stab2"] = (433, build_stab2, 256)
em.CULL |= {"riser", "stab2"}
if not hasattr(em, "CHECKS"):
    em.CHECKS = {}
em.CHECKS["riser"] = {"cells": ((-0.5, -0.75, -0.6), (0.5, 0.5, 0.5)), "budget": 400,
                      "origins": {"riser_knuckle": KP_R}}
em.CHECKS["stab2"] = {"cells": ((-0.5, -0.75, -0.5), (0.5, 0.5, 0.5)), "budget": 400,
                      "origins": {"stab2_crown": HEAD, "stab2_fork": HEAD}}

if __name__ == "__main__":
    for nm in (sys.argv[1:] or ["riser", "stab2"]):
        em.make(nm)
