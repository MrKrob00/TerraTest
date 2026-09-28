#!/usr/bin/env python3
"""Builds the SHIELD, the REPAIR UNIT (regen), the RADAR, the STABILISER wheel and the CONVEYORS.

    python3 art/emitter_models.py [shield|regen|radar|stab|belt|belt_cross|belt_split ...]
        -> objects/<name>_texture.png + art/out/<name>.glb (one node per part)
    godot --headless --path . --script res://art/turret_import.gd -- <name> ...
        -> blocks/meshes/<name>_<part>.tres

Same toolkit and palette as the turret heads (turret_heads.py); both stand on the platform the
weapons stand on, so the family reads the same. What is new here is ROUND geometry: a lathe
around Y whose every facet gets its own painted light (the blocks are unshaded, so a sphere with
one flat colour is a disc), and PARTS - each block is several meshes, because its script moves or
re-colours some of them:

SHIELD - an emitter ORB, a nod to TerraTech's without copying it: dark lower hemisphere held by
four blue claws, an equator band, and a blue CAP that lifts and turns when the dome is up. The gap
it opens shows the CORE, which the script tints: cyan while the dome stands, amber blinking while
it reboots after running dry, dark with no power.
  parts: shield_body (still), shield_cap (moves), shield_core (tinted, never batched)

REGEN - a beacon, not a second orb: a blue hub marked with the green cross, a mast, a green
CRYSTAL the script tints and pulses on every repair, and a RING with three inward nozzles that
spins while the field is powered and runs down when it is not.
  parts: regen_body (still), regen_ring (moves), regen_crystal (tinted, never batched)

RADAR - a dish on a mast, tipped RADAR_TILT up, feed horn in front; the head sweeps round while
the block sits on a machine, which is exactly when it widens the map.
  parts: radar_body (still), radar_head (turns)

SUPPORT / ROT_SUPPORT - after TerraTech's GSO anchor: a round base under a deck (square on the
fixed one, round on the turning one), a telescoping ram and a foot (see the section below).
  parts: <name>_body (still), <name>_sleeve / _leg (stretched), <name>_foot (moves), rot's _stator

GENERATOR - the first model built by the measured rules in docs/ART_STYLE.md rather than after one
reference: a dark chamfered cube, a blue housing with a turbine over a painted well, fire behind a
grate on every wall.
  parts: generator_body (still), generator_rotor (turns), generator_fire (tinted, never batched)

Every part fits the block's 1 m cell at its highest pose (the rule the turret heads follow).
"""
import json
import math
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import turret_heads as th  # noqa: E402

Image = th.Image

# Light the facets are painted by: from above, a little from the front-left, like the atlas.
LIGHT = th.norm((-0.35, 0.85, 0.40))

BLUE_RAMP = [(40, 55, 100), (57, 71, 110), (76, 106, 177), (97, 129, 197), (110, 152, 217),
             (140, 176, 232)]
METAL_RAMP = th.METAL
# The tinted parts are painted in light greys: the script multiplies them by the state colour.
CORE_RAMP = [(120, 120, 130), (160, 160, 172), (200, 200, 212), (232, 232, 240), (252, 252, 255)]


def ramp_colour(ramp, n):
    t = 0.5 + 0.5 * th.dot(n, LIGHT)
    return ramp[int(round(max(0.0, min(1.0, t)) * (len(ramp) - 1)))]


def lathe_y(pk, img, faces, profile, ramp, sides=16, cell=3, cx=0.0, cz=0.0, ring_ramps=None,
            phase=0.5, marks=None):
    """A round part about the Y axis. `profile` is [(radius, y), ...] from the bottom up; a radius
    of 0 closes a pole. Every facet owns a `cell`-pixel square of one island, painted flat in the
    colour its normal gets from LIGHT - the painted equivalent of flat shading."""
    rings = len(profile) - 1
    x0, y0, w, h = pk.take(sides * cell, rings * cell)
    ang = [(i + phase) * 2 * math.pi / sides for i in range(sides)]
    P = lambda r, y, i: (cx + r * math.cos(ang[i]), y, cz + r * math.sin(ang[i]))
    cells = {}
    for k in range(rings):
        (r0, ya), (r1, yb) = profile[k], profile[k + 1]
        rr = (ring_ramps or {}).get(k, ramp)
        for i in range(sides):
            j = (i + 1) % sides
            q = [P(r0, ya, i), P(r0, ya, j), P(r1, yb, j), P(r1, yb, i)]
            u0, v0 = x0 + i * cell, y0 + (rings - 1 - k) * cell
            uv = [(u0, v0 + cell), (u0 + cell, v0 + cell), (u0 + cell, v0), (u0, v0)]
            # The profile runs round its section counter-clockwise, so outward is the tangent
            # turned by -90 deg: (dy, -dr) in the (radial, up) plane.
            am = ang[i] + math.pi / sides
            dr, dy = r1 - r0, yb - ya
            want = (dy * math.cos(am), -dr, dy * math.sin(am))
            if th.dot(th.newell(q), want) < 0:
                q, uv = list(reversed(q)), list(reversed(uv))
            f = th.Face(q, None)
            f.uv = uv
            faces.append(f)
            cells[(i, k)] = (marks or {}).get((i, k)) or ramp_colour(rr, th.norm(want))
    for yy in range(-th.PAD, h + th.PAD):
        for xx in range(-th.PAD, w + th.PAD):
            i = min(max(xx // cell, 0), sides - 1)
            k = rings - 1 - min(max(yy // cell, 0), rings - 1)
            img.putpixel((x0 + xx, y0 + yy), th.jitter(cells[(i, k)], 1))


def sphere_profile(yc, r, lat0, lat1, steps):
    """[(radius, y)] along a sphere of radius r centred at yc, latitude lat0..lat1 degrees."""
    out = []
    for s in range(steps + 1):
        a = math.radians(lat0 + (lat1 - lat0) * s / steps)
        out.append((max(r * math.cos(a), 0.0), yc + r * math.sin(a)))
    return out


def along_y(faces_z, fn=None):
    """Stand faces built along Z (th.prism / th.box) up along Y: (x, y, z) -> (x, z, -y)."""
    out = []
    for f in faces_z:
        pts = [(p[0], p[2], -p[1]) for p in f.pts]
        f.pts = pts
        if f.u_hint:
            f.u_hint = (f.u_hint[0], f.u_hint[2], -f.u_hint[1])
        out.append(f)
    return out


# ── the shield ──────────────────────────────────────────────────────────────────────────────────

SHIELD_R = 0.36          # orb radius
SHIELD_LIFT = 0.09       # how far the cap rises when the dome is up (shield.gd reads the node)


def build_shield(pk, img):
    parts = {"shield_body": [], "shield_cap": [], "shield_core": []}
    body, cap, core = parts["shield_body"], parts["shield_cap"], parts["shield_core"]
    # Lower hemisphere, dark metal, sitting on the platform (its pole on the plate's top).
    lathe_y(pk, img, body, sphere_profile(0.0, SHIELD_R, -90, 0, 4), METAL_RAMP)
    # Equator band: the rim the cap closes onto.
    lathe_y(pk, img, body, [(SHIELD_R - 0.01, -0.035), (SHIELD_R + 0.018, -0.03),
                            (SHIELD_R + 0.018, 0.008), (SHIELD_R - 0.005, 0.012)],
            BLUE_RAMP, ring_ramps={1: METAL_RAMP})
    # Four blue claws gripping the orb from the plate up to just under the band: shorter ones stood
    # beside the sphere with a gap where it curves in, and read as blocks set down next to it.
    for sx, sz in ((1, 0), (-1, 0), (0, 1), (0, -1)):
        if sx:
            lo, hi = (min(sx * 0.29, sx * 0.40), -0.36, -0.06), (max(sx * 0.29, sx * 0.40), -0.05, 0.06)
        else:
            lo, hi = (-0.06, -0.36, min(sz * 0.29, sz * 0.40)), (0.06, -0.05, max(sz * 0.29, sz * 0.40))
        th.box(body, lo, hi, "blue")
    # The core: what shows through the gap when the cap lifts. Built round (0, 0, 0).
    lathe_y(pk, img, core, sphere_profile(0.0, SHIELD_R - 0.03, -60, 75, 5), CORE_RAMP, sides=12)
    # The cap: upper hemisphere in GSO blue, a dark lip at its rim, a light emitter disc on top.
    # Built with its rim at y 0, so the node's own height is the lift.
    prof = [(SHIELD_R + 0.005, 0.0)] + [(r, y + 0.012) for r, y in
                                         sphere_profile(0.0, SHIELD_R + 0.005, 0, 90, 5)[1:]]
    lathe_y(pk, img, cap, [(SHIELD_R - 0.005, 0.0)] + prof, BLUE_RAMP,
            ring_ramps={0: METAL_RAMP, 5: CORE_RAMP})
    return parts


REGEN_Y = 0.20           # crystal and ring centre height (regen.gd reads the nodes)

# ── the repair unit ─────────────────────────────────────────────────────────────────────────────

def build_regen(pk, img):
    parts = {"regen_body": [], "regen_ring": [], "regen_crystal": []}
    body, ring, crystal = parts["regen_body"], parts["regen_ring"], parts["regen_crystal"]
    # Hub: a chamfered blue box standing on the platform, the green cross on all four sides.
    hub = []
    # Built along Z and stood up: z becomes y, so the back cap (z -0.10) is the top.
    th.prism(hub, -0.33, 0.33, -0.33, 0.33, -0.10, -0.36, 0.08, side="blue_cross",
             cap_front=None, cap_back="blue")
    body += along_y(hub)
    # Mast, up to the crystal (whose node sits at REGEN_Y).
    lathe_y(pk, img, body, [(0.075, -0.10), (0.075, 0.04), (0.05, 0.07), (0.0, 0.07)], METAL_RAMP,
            sides=8)
    # Crystal: an elongated octahedron over the mast. Built round (0, 0, 0).
    lathe_y(pk, img, crystal, [(0.0, -0.16), (0.11, 0.0), (0.0, 0.16)], CORE_RAMP, sides=6,
            cell=4)
    # Ring: square section, three nozzles pointing in at the crystal. Built round (0, 0, 0).
    lathe_y(pk, img, ring, [(0.25, -0.04), (0.31, -0.04), (0.31, 0.04), (0.25, 0.04), (0.25, -0.04)],
            BLUE_RAMP, sides=16, ring_ramps={3: METAL_RAMP})
    for k in range(3):
        a = k * 2 * math.pi / 3
        nz = []
        th.box(nz, (0.17, -0.025, -0.03), (0.26, 0.025, 0.03), "dark")
        for f in nz:
            f.pts = [(p[0] * math.cos(a) - p[2] * math.sin(a), p[1],
                      p[0] * math.sin(a) + p[2] * math.cos(a)) for p in f.pts]
            if f.u_hint:
                u = f.u_hint
                f.u_hint = (u[0] * math.cos(a) - u[2] * math.sin(a), u[1],
                            u[0] * math.sin(a) + u[2] * math.cos(a))
        ring += nz
    return parts


# ── the radar ───────────────────────────────────────────────────────────────────────────────────

DISH_RAMP = [(70, 78, 100), (95, 104, 130), (120, 130, 158), (145, 155, 182), (165, 175, 200)]
# The dish looks up this far; tipped less, the turntable and its mount stood in FRONT of the bowl's
# lower half and pierced it, and a bowl raised clear of them no longer fits the cell.
RADAR_TILT = 45.0
RADAR_Y = 0.0            # the head's spin axis starts at the mast's top (radar.gd reads the node)


def xform(faces, fn):
    """Move built faces by a point function (and their u hints by its linear part)."""
    for f in faces:
        f.pts = [fn(p) for p in f.pts]
        if f.u_hint:
            o = fn((0.0, 0.0, 0.0))
            q = fn(f.u_hint)
            f.u_hint = (q[0] - o[0], q[1] - o[1], q[2] - o[2])
    return faces


def build_radar(pk, img):
    parts = {"radar_body": [], "radar_head": []}
    body, head = parts["radar_body"], parts["radar_head"]
    # Pedestal and mast on the platform.
    lathe_y(pk, img, body, [(0.30, -0.36), (0.30, -0.27), (0.24, -0.21), (0.0, -0.21)], BLUE_RAMP,
            sides=8)
    lathe_y(pk, img, body, [(0.07, -0.21), (0.07, 0.0), (0.0, 0.0)], METAL_RAMP, sides=8)
    # Head, built round its spin axis at the mast top: a turntable, a mount, the dish and its feed.
    lathe_y(pk, img, head, [(0.12, 0.0), (0.12, 0.04), (0.09, 0.06), (0.0, 0.06)], BLUE_RAMP,
            sides=8)
    th.box(head, (-0.06, 0.03, -0.08), (0.06, 0.15, 0.02), "dark")
    # The dish is a bowl about its own axis (local Y): back surface, rim, concave front.
    dish = []
    lathe_y(pk, img, dish, [(0.0, -0.035), (0.12, -0.02), (0.24, 0.015), (0.345, 0.07),
                            (0.345, 0.10), (0.24, 0.045), (0.12, 0.012), (0.0, 0.0)],
            BLUE_RAMP, sides=16, ring_ramps={3: METAL_RAMP, 4: DISH_RAMP, 5: DISH_RAMP, 6: DISH_RAMP})
    # The feed horn on its rod, out in front of the bowl.
    lathe_y(pk, img, dish, [(0.018, 0.0), (0.018, 0.2), (0.042, 0.2), (0.042, 0.245), (0.0, 0.245)],
            METAL_RAMP, sides=6, ring_ramps={3: th.RIM})
    # Tip the bowl's axis from up to forward-and-up, then sit it on the mount.
    a = math.radians(-(90.0 - RADAR_TILT))
    ca, sa = math.cos(a), math.sin(a)
    head += xform(dish, lambda p: (p[0], p[1] * ca - p[2] * sa + 0.18, p[1] * sa + p[2] * ca - 0.06))
    return parts


# ── the stabiliser wheel ────────────────────────────────────────────────────────────────────────
# It carries the artist's SMALL tyre and hub (Assets.glb Wheel_small / Wheel_Axle) and the artist's
# mounting plate; what is generated here is only what those lack - a mount and trailing arms - so
# the tyre on it is the very tyre on the small wheel.

STAB_RIDE = 0.90         # same as the standard wheel: the stabiliser carries at the same height
STAB_AXLE = (-0.60, -0.12)   # (y, z) of its axle, reaching away from the hull on its +Z side


def rod_x(pk, img, faces, y, z, r, x0, x1, ramp=None):
    """An octagonal rod along X (an axle through a hub)."""
    part = []
    lathe_y(pk, img, part, [(r, x0), (r, x1)], ramp or METAL_RAMP, sides=8)
    # lathe_y builds about Y; lay it down: (x, y, z) -> (y, x, z), then move to (y, z).
    for f in part:
        f.pts = [(p[1], p[0] + y, p[2] + z) for p in f.pts]
    faces += part


def build_stab(pk, img):
    parts = {"stab_mount": [], "stab_arm": []}
    mount, arm = parts["stab_mount"], parts["stab_arm"]
    # Mount on the back plate: a dark sleeve tall enough to hide the arm roots at full travel.
    th.box(mount, (-0.19, -0.17, 0.18), (0.19, 0.17, 0.37), "dark", face_styles={"-z": "blue"})
    # Trailing arms from inside the sleeve down to the axle, beside the tyre.
    ay, az = STAB_AXLE
    y0, z0 = 0.0, 0.27
    ln = math.hypot(ay - y0, az - z0)
    ang = math.atan2(az - z0, -(ay - y0))       # tilt from straight down, towards -Z
    for sx in (-1, 1):
        lo, hi = sorted((sx * 0.19, sx * 0.25))
        a = []
        th.box(a, (lo, -ln, -0.035), (hi, 0.04, 0.035), "blue")
        ca, sa = math.cos(-ang), math.sin(-ang)
        xform(a, lambda p: (p[0], p[1] * ca - p[2] * sa + y0, p[1] * sa + p[2] * ca + z0))
        arm += a
    rod_x(pk, img, arm, ay, az, 0.035, -0.26, 0.26)
    return parts


# ── the conveyors ───────────────────────────────────────────────────────────────────────────────
# The shape of the old conveyor (a deck on a column) kept, drawn the way the other blocks are and
# light: the old mesh was 1344 triangles a cell. The deck's top stays at the old height (the items'
# `item_slot` sits over it), the belt shows where cargo goes: arrows on a conveyor, arrows fanning out
# three ways on the fork, none on the crossing, which passes both axes.

BELT_TOP = 0.44


def belt_stand(pk, img, faces):
    th.box(faces, (-0.30, -0.50, -0.30), (0.30, -0.43, 0.30), "dark")
    lathe_y(pk, img, faces, [(0.13, -0.43), (0.13, 0.18)], METAL_RAMP, sides=8)
    th.prism(faces, -0.5, 0.5, 0.18, BELT_TOP - 0.02, 0.5, -0.5, 0.05)


def belt_strip(faces, lo, hi, style, u_hint):
    """A belt run on the deck; its top carries `style`, u running along `u_hint` (the flow)."""
    part = []
    th.box(part, lo, hi, "dark")
    for f in part:
        if th.newell(f.pts)[1] > 0.9:
            f.style = style
            f.u_hint = u_hint
    faces += part


def build_belt(pk, img):
    parts = {"belt_body": []}
    f = parts["belt_body"]
    belt_stand(pk, img, f)
    belt_strip(f, (-0.36, BELT_TOP - 0.02, -0.5), (0.36, BELT_TOP, 0.5), "belt_fwd", (0, 0, -1))
    for sx in (-1, 1):
        lo, hi = sorted((sx * 0.38, sx * 0.5))
        th.box(f, (lo, BELT_TOP - 0.02, -0.5), (hi, BELT_TOP + 0.07, 0.5), "blue")
    return parts


def build_belt_cross(pk, img):
    parts = {"belt_cross_body": []}
    f = parts["belt_cross_body"]
    belt_stand(pk, img, f)
    belt_strip(f, (-0.36, BELT_TOP - 0.02, -0.5), (0.36, BELT_TOP, 0.5), "belt", (0, 0, -1))
    belt_strip(f, (-0.5, BELT_TOP - 0.02, -0.36), (0.5, BELT_TOP + 0.004, 0.36), "belt", (1, 0, 0))
    for sx in (-1, 1):
        for sz in (-1, 1):
            xl, xh = sorted((sx * 0.38, sx * 0.5))
            zl, zh = sorted((sz * 0.38, sz * 0.5))
            th.box(f, (xl, BELT_TOP - 0.02, zl), (xh, BELT_TOP + 0.09, zh), "blue")
    return parts


def build_belt_split(pk, img):
    parts = {"belt_split_body": []}
    f = parts["belt_split_body"]
    belt_stand(pk, img, f)
    # A distribution plate in the middle carrying one T of arrows (in from the back, out front,
    # left and right), and short plain runs from it to the four cell edges. Four arrowed runs
    # crossing in the middle were tried first and read as a heap of chevrons.
    belt_strip(f, (-0.34, BELT_TOP - 0.01, -0.34), (0.34, BELT_TOP + 0.01, 0.34), "fork_hub", (0, 0, -1))
    belt_strip(f, (-0.30, BELT_TOP - 0.02, 0.34), (0.30, BELT_TOP, 0.5), "belt", (0, 0, -1))
    belt_strip(f, (-0.30, BELT_TOP - 0.02, -0.5), (0.30, BELT_TOP, -0.34), "belt", (0, 0, -1))
    belt_strip(f, (-0.5, BELT_TOP - 0.02, -0.30), (-0.34, BELT_TOP, 0.30), "belt", (-1, 0, 0))
    belt_strip(f, (0.34, BELT_TOP - 0.02, -0.30), (0.5, BELT_TOP, 0.30), "belt", (1, 0, 0))
    for sx in (-1, 1):
        for sz in (-1, 1):
            xl, xh = sorted((sx * 0.38, sx * 0.5))
            zl, zh = sorted((sz * 0.38, sz * 0.5))
            th.box(f, (xl, BELT_TOP - 0.02, zl), (xh, BELT_TOP + 0.09, zh), "blue")
    return parts


# ── the supports ────────────────────────────────────────────────────────────────────────────────
# What they DO decides the shape. The SUPPORT is what lets a machine anchor: a housing that bolts on
# by its top and sides, with a JACK under it - a sleeve, a piston and a round foot - and when the
# machine anchors the piston runs down and the foot stands on the ground (support.gd; that used to
# be a white cylinder the machine grew under itself). The ROTATING SUPPORT is the same jack under a
# TURNTABLE: the housing and its rotor ring turn with the machine, the stator ring below holds its
# heading on the ground (it carries orange ticks and two lugs so the turn is seen against it).
# Parts: <name>_body (still), <name>_leg (a unit rod the script stretches), <name>_foot (moves
# down), and for the turntable <name>_stator (holds world yaw while anchored).

# The reference is TerraTech's GSO rotating anchor (its shape; the colours are ours - dark metal and
# GSO blue, like every block from Assets.glb): a round BASE and a flat round DECK on it that
# blocks stand on, joining by the four sides and the top, never the bottom. Every round part here has
# its flats ON the cell's faces (16 sides, `flat_r`), so a neighbour meets a face rather than a curve
# standing off it - the first cut, a housing on a thin sleeve, read as joining by its top only.
SUP_FOOT_Y = -0.42       # the foot's top at rest; the scene's leg/sleeve sit above it (support.gd)
RAM_R, SLEEVE_R = 0.19, 0.27
ORANGE_RAMP = [th.ORANGE_LO, th.ORANGE_LO, th.ORANGE, th.ORANGE]
BASE_RAMP = METAL_RAMP   # the base in the dark metal every other block is built on


def flat_r(r_flat, sides=16):
    """Circumradius of a `sides`-gon whose flats stand r_flat from the axis."""
    return r_flat / math.cos(math.pi / sides)


def support_ram(pk, img, leg, sleeve, foot):
    """The two telescoping stages (unit length, hanging down from their nodes) and the foot."""
    lathe_y(pk, img, leg, [(RAM_R, -1.0), (RAM_R, 0.0)], th.RIM, sides=12)
    lathe_y(pk, img, sleeve, [(SLEEVE_R - 0.02, -1.0), (SLEEVE_R, -0.97), (SLEEVE_R, 0.0)],
            METAL_RAMP, sides=12)
    R = flat_r(0.5)
    lathe_y(pk, img, foot, [(0.0, -0.5), (R, -0.5), (R, -0.465), (flat_r(0.46), -0.44),
                            (0.32, SUP_FOOT_Y), (0.0, SUP_FOOT_Y)], METAL_RAMP, sides=16,
            ring_ramps={1: ORANGE_RAMP})


DECK_Y = -0.15           # the deck's underside: blue from here up (the player's sketch - it was
                         # 0.12, and the dark neck under it read as the block's bulk)


def support_base(pk, img, faces, marks):
    """The round base from the foot up to the deck: a wall, and a ridge band right under the deck."""
    r0, r1 = flat_r(0.45), flat_r(0.5)
    lathe_y(pk, img, faces, [(0.0, SUP_FOOT_Y), (r0, SUP_FOOT_Y), (r0, DECK_Y - 0.12),
                             (r1, DECK_Y - 0.10), (r1, DECK_Y), (0.30, DECK_Y)], BASE_RAMP,
            sides=16, marks=marks, ring_ramps={2: BLUE_RAMP})


def deck_top(faces, y, style, square=False):
    if square:
        pts = [(-0.5, y, -0.5), (0.5, y, -0.5), (0.5, y, 0.5), (-0.5, y, 0.5)]
    else:
        R = flat_r(0.5)
        pts = [(R * math.cos((i + 0.5) * math.pi / 8), y, R * math.sin((i + 0.5) * math.pi / 8))
               for i in range(16)]
    faces.append(th.Face(th.outward(pts, (0.0, y - 1.0, 0.0)), style, u_hint=(0, 0, -1)))


def build_support(pk, img):
    parts = {"support_body": [], "support_sleeve": [], "support_leg": [], "support_foot": []}
    body = parts["support_body"]
    # A square deck the full cell across (it does not turn, so it may meet its neighbours flat).
    h = []
    th.prism(h, -0.5, 0.5, -0.5, 0.5, 0.5, DECK_Y, 0.067, side="blue", cap_front="dark",
             cap_back=None)
    body += along_y(h)
    deck_top(body, 0.5, "anchor_top_fixed", square=True)
    # Round base with a hazard band on its ridge: the fixed one says "stand clear", not "turns".
    hazard = {(i, 3): (th.ORANGE if i % 2 else METAL_RAMP[1]) for i in range(16)}
    support_base(pk, img, body, hazard)
    support_ram(pk, img, parts["support_leg"], parts["support_sleeve"], parts["support_foot"])
    return parts


def build_rot_support(pk, img):
    parts = {"rot_support_body": [], "rot_support_stator": [], "rot_support_sleeve": [],
             "rot_support_leg": [], "rot_support_foot": []}
    body, stator = parts["rot_support_body"], parts["rot_support_stator"]
    # The deck: a round platform, the blocks stand on it and turn with it; the chevron shows where.
    R = flat_r(0.5)
    lathe_y(pk, img, body, [(flat_r(0.44), DECK_Y), (flat_r(0.47), DECK_Y + 0.02),
                            (R, DECK_Y + 0.04), (R, 0.47), (flat_r(0.485), 0.5)], BLUE_RAMP,
            sides=16, ring_ramps={0: METAL_RAMP})
    deck_top(body, 0.5, "anchor_top")
    # The base holds its heading on the ground: four orange ticks on its ridge, so a turn is seen.
    ticks = {(i, 3): th.ORANGE for i in (0, 4, 8, 12)}
    support_base(pk, img, stator, ticks)
    support_ram(pk, img, parts["rot_support_leg"], parts["rot_support_sleeve"],
                parts["rot_support_foot"])
    return parts


# ── the generator ───────────────────────────────────────────────────────────────────────────────
# Built to the style rules in docs/ART_STYLE.md, not after any one reference: a DARK CHAMFERED CUBE
# (it joins on every face, so its walls stand on the cell's faces like the frame block's), a GSO
# BLUE HOUSING on top as the weapons carry, and ONE POP COLOUR that says what the block does - the
# amber of fire behind a grate on every wall, lit only while it burns. The turbine in the housing's
# well spins up with the fire. Parts: generator_body (still), generator_rotor (turns),
# generator_fire (re-coloured by generator.gd, never batched).
GEN_TOP = 0.20           # the cube's top; the housing stands on it
GEN_WELL_Y = 0.40        # the housing's top, where the rotor turns (generator.gd reads nothing)


def cham_box(faces, lo, hi, c, side, top, bottom, edge):
    """A box with EVERY edge chamfered by c: six inset faces, twelve edge strips, eight corners."""
    x = (lo[0], hi[0])
    y = (lo[1], hi[1])
    z = (lo[2], hi[2])
    centre = tuple((lo[i] + hi[i]) / 2 for i in range(3))

    def pt(ix, iy, iz, pull):
        # the corner (ix, iy, iz) of the box, pulled in by c along every axis except `pull`
        s = [1 if ix else -1, 1 if iy else -1, 1 if iz else -1]
        p = [x[ix], y[iy], z[iz]]
        for a in range(3):
            if a != pull:
                p[a] -= s[a] * c
        return tuple(p)

    for a in range(3):
        for side_i in (0, 1):
            q = []
            for u, v in ((0, 0), (1, 0), (1, 1), (0, 1)):
                idx = [0, 0, 0]
                idx[a] = side_i
                idx[(a + 1) % 3], idx[(a + 2) % 3] = u, v
                q.append(pt(idx[0], idx[1], idx[2], a))
            n = [0.0, 0.0, 0.0]
            n[a] = 1.0 if side_i else -1.0
            if a == 1:
                st, uh = (top if side_i else bottom), (1, 0, 0)
            else:
                st, uh = side, th.cross((0, 1, 0), tuple(n))
            if st is not None:
                faces.append(th.Face(th.outward(q, centre), st, u_hint=uh))
    for a in range(3):                       # the edge runs along axis a
        b, cc = (a + 1) % 3, (a + 2) % 3
        for sb in (0, 1):
            for sc in (0, 1):
                q = []
                for sa in (0, 1):
                    for pull in (b, cc):
                        idx = [0, 0, 0]
                        idx[a], idx[b], idx[cc] = sa, sb, sc
                        q.append(pt(idx[0], idx[1], idx[2], pull))
                q = [q[0], q[1], q[3], q[2]]
                uh = [0, 0, 0]
                uh[a] = 1
                faces.append(th.Face(th.outward(q, centre), edge, u_hint=tuple(uh)))
    for ix in (0, 1):
        for iy in (0, 1):
            for iz in (0, 1):
                tri = [pt(ix, iy, iz, a) for a in range(3)]
                faces.append(th.Face(th.outward(tri, centre), edge))


def octo(half, ch, y):
    """A chamfered square at height y, half-width `half`, corners cut by ch."""
    p, _ = th.octagon(-half, half, -half, half, ch)
    return [(u, y, v) for u, v in p]


def build_generator(pk, img):
    parts = {"generator_body": [], "generator_rotor": [], "generator_fire": []}
    body, rotor, fire = parts["generator_body"], parts["generator_rotor"], parts["generator_fire"]
    cham_box(body, (-0.5, -0.5, -0.5), (0.5, GEN_TOP, 0.5), 0.067, "gen_side", "dark", "dark",
             "dark_edge")
    # The housing: a chamfered frustum, the weapons' blue, its corners the lighter bevel.
    lo, hi = octo(0.45, 0.13, GEN_TOP), octo(0.31, 0.09, GEN_WELL_Y)
    centre = (0.0, (GEN_TOP + GEN_WELL_Y) / 2, 0.0)
    for i in range(8):
        j = (i + 1) % 8
        q = [lo[i], lo[j], hi[j], hi[i]]
        n = th.newell(th.outward(q, centre))
        uh = th.cross((0, 1, 0), th.norm((n[0], 0.0, n[2])))
        body.append(th.Face(th.outward(q, centre), "bevel" if i % 2 else "blue", u_hint=uh))
    # The intake is PAINTED, not cut: a dark well on a solid lid. The rotor and the fuel sink through
    # the lid (generator.gd RETRACT) and vanish into the dark, so nobody sees where they go - a real
    # well was tried and showed the blades lying in a pit and the fuel sitting on its floor.
    body.append(th.Face(th.outward(hi, (0.0, 0.0, 0.0)), "gen_top", u_hint=(1, 0, 0)))
    # The firebox windows: one on every wall, standing a hair proud of it.
    for k in range(4):
        a = k * math.pi / 2
        nx, nz = math.cos(a), math.sin(a)
        tx, tz = -nz, nx
        off = 0.5 + 0.004
        q = [(nx * off + tx * s, yy, nz * off + tz * s) for s, yy in
             ((-0.30, -0.40), (0.30, -0.40), (0.30, -0.17), (-0.30, -0.17))]
        fire.append(th.Face(th.outward(q, (0.0, -0.28, 0.0)), "gen_fire", u_hint=(tx, 0.0, tz)))
    # The rotor: an octagonal hub with a bolt and six pitched blades, all inside the painted well.
    hub = []
    th.prism(hub, -0.06, 0.06, -0.06, 0.06, GEN_WELL_Y + 0.07, GEN_WELL_Y, 0.03, side="dark",
             cap_front=None, cap_back="cap_bolt")
    rotor += along_y(hub)
    for k in range(6):
        a = k * math.pi / 3
        ca, sa = math.cos(a), math.sin(a)
        pts = []
        for r, w in ((0.06, 0.035), (0.235, 0.05)):
            for s in (-1, 1):
                # the blade's edge rises on one side: a 25 deg pitch, so it reads as a turbine
                pts.append((ca * r - sa * s * w, GEN_WELL_Y + 0.035 + s * w * 0.47, sa * r + ca * s * w))
        q = [pts[0], pts[1], pts[3], pts[2]]
        rotor.append(th.Face(th.outward(q, (0.0, GEN_WELL_Y - 1.0, 0.0)), "blade", u_hint=(ca, 0.0, sa)))
    return parts


# ── the receiver and the collector ──────────────────────────────────────────────────────────────
# The player's own shapes redrawn to docs/ART_STYLE.md. The RECEIVER - the chain's entry, pulling
# ground materials and collectors' cargo in through its beam - was a plate on a post; on a post it
# read as a saucer hovering at the top of its cell, so it now stands on the floor as the platform
# blocks do: a slatted dark platform, a low blue housing, and the old dark pad with its blue
# octagon on top. The COLLECTOR is a cube with a round bowl in its top,
# where the one item it shows sits (collector.gd HOLD_Y); now a dark grilled cube, a blue lid, and a
# dark bowl with a boss in the middle. Both used to stand out of their cell (the plate 9 cm over
# the top, the cube 1 cm past every face and its rim 7 cm up) on 450 and 882 plain triangles.
RECV_BASE = (-0.34, -0.14)       # the platform's top and the housing's top; the pad adds 0.04
COL_BOWL_R = 0.36                # the bowl's mouth


def lid_ring(pk, img, faces, outer, y, R, n, lip=True):
    """A flat plate between the convex polygon `outer` and a round hole of radius R (n sides, the
    lathe's own phase), cut into n convex pieces that share ONE painted island, so it reads as one
    blue plate with a dark lip round the hole and four rivets on the diagonals."""
    half = max(max(abs(p[0]), abs(p[2])) for p in outer)
    w = int(math.ceil(2 * half * th.DENS))
    x0, y0, _, _ = pk.take(w, w)
    uv = lambda p: (x0 + (p[0] + half) * th.DENS, y0 + (p[2] + half) * th.DENS)
    poly = [((p[0] + half) * th.DENS, (p[2] + half) * th.DENS) for p in outer]
    rw = R * th.DENS
    for yy in range(-th.PAD, w + th.PAD):
        for xx in range(-th.PAD, w + th.PAD):
            px, py = xx + 0.5, yy + 0.5
            d = th.dist_to_edges(min(max(px, 0), w), min(max(py, 0), w), poly)
            r = math.hypot(px - w / 2.0, py - w / 2.0)
            if d < 1.0:
                c = th.BLUE_HI
            elif d < 2.0:
                c = th.BLUE_MID
            elif lip and r < rw + 1.2:
                c = th.RIM[1]
            else:
                c = th.jitter(th.BLUE, 2)
                for k in range(4):
                    ang = (k + 0.5) * math.pi / 2
                    rr = (rw + min(w / 2.0 * 1.41 - 3.0, rw + 6.0)) / 2.0
                    rx, ry = w / 2.0 + math.cos(ang) * rr, w / 2.0 + math.sin(ang) * rr
                    if int(px) == int(rx) and int(py) == int(ry):
                        c = th.BLUE_DEEP
                    elif int(px) == int(rx) + 1 and int(py) == int(ry) + 1:
                        c = th.BLUE_HI
            img.putpixel((x0 + xx, y0 + yy), th.shade(c, 1.06))

    def hit(a):
        dx, dz = math.cos(a), math.sin(a)
        best = None
        for i in range(len(outer)):
            p, q = outer[i], outer[(i + 1) % len(outer)]
            ex, ez = q[0] - p[0], q[2] - p[2]
            den = dx * ez - dz * ex
            if abs(den) < 1e-9:
                continue
            t = (p[0] * ez - p[2] * ex) / den
            u = (p[0] * dz - p[2] * dx) / den
            if t > 0 and -1e-9 <= u <= 1 + 1e-9 and (best is None or t < best):
                best = t
        return (dx * best, y, dz * best)

    corners = [(math.atan2(p[2], p[0]) % (2 * math.pi), p) for p in outer]
    for i in range(n):
        a0, a1 = (i + 0.5) * 2 * math.pi / n, (i + 1.5) * 2 * math.pi / n
        mid = [p for ang, p in corners if 0 < (ang - a0) % (2 * math.pi) < a1 - a0]
        mid.sort(key=lambda p: -((math.atan2(p[2], p[0]) - a0) % (2 * math.pi)))
        pts = [(R * math.cos(a0), y, R * math.sin(a0)), (R * math.cos(a1), y, R * math.sin(a1)),
               hit(a1)] + mid + [hit(a0)]
        pts = th.outward(pts, (0.0, y - 1.0, 0.0))
        f = th.Face(pts, None)
        f.uv = [uv(p) for p in pts]
        faces.append(f)


def build_receiver(pk, img):
    """The platform archetype, the turret base's: it stands ON the cell's floor, not on a post - on
    a post it read as a saucer hovering at the top of its cell."""
    parts = {"receiver_body": []}
    body = parts["receiver_body"]
    lo_y, hi_y = RECV_BASE
    # The platform: a whole cell across, the family's orange slats on its sides.
    cham_box(body, (-0.5, -0.5, -0.5), (0.5, lo_y, 0.5), 0.025, "slab_side", "dark", "dark",
             "dark_edge")
    # The housing: the weapons' sloped blue frustum, and its top a blue ring round the pad.
    lo, hi = octo(0.44, 0.13, lo_y), octo(0.30, 0.09, hi_y)
    centre = (0.0, (lo_y + hi_y) / 2, 0.0)
    for i in range(8):
        j = (i + 1) % 8
        q = [lo[i], lo[j], hi[j], hi[i]]
        n = th.newell(th.outward(q, centre))
        uh = th.cross((0, 1, 0), th.norm((n[0], 0.0, n[2])))
        body.append(th.Face(th.outward(q, centre), "bevel" if i % 2 else "blue", u_hint=uh))
    body.append(th.Face(th.outward(hi, (0.0, hi_y - 1.0, 0.0)), "blue", u_hint=(1, 0, 0)))
    # The pad, where the beam starts: dark rubber with the old model's blue octagon.
    pad = []
    th.prism(pad, -0.24, 0.24, -0.24, 0.24, hi_y + 0.04, hi_y, 0.07, side="dark", cap_front=None,
             cap_back="recv_pad")
    for f in pad:
        if f.style == "bevel":
            f.style = "dark_edge"                 # the pad is dark metal all round, not a housing
    body += along_y(pad)
    return parts


def build_collector(pk, img):
    parts = {"collector_body": []}
    body = parts["collector_body"]
    c = 0.067
    cham_box(body, (-0.5, -0.5, -0.5), (0.5, 0.5, 0.5), c, "col_side", None, "dark", "dark_edge")
    top = [(-0.5 + c, 0.5, -0.5 + c), (0.5 - c, 0.5, -0.5 + c), (0.5 - c, 0.5, 0.5 - c),
           (-0.5 + c, 0.5, 0.5 - c)]
    lid_ring(pk, img, body, top, 0.5, COL_BOWL_R, 12)
    # The bowl: a dark cone down to a floor, a lighter boss in the middle the item rests over.
    lathe_y(pk, img, body, [(0.0, 0.34), (0.11, 0.34), (COL_BOWL_R * 0.8, 0.30), (COL_BOWL_R, 0.5)],
            METAL_RAMP[:4], sides=12, ring_ramps={0: th.RIM})
    return parts


BLOCKS = {
    "receiver": (61, build_receiver, 256),
    "collector": (67, build_collector, 256),
    "generator": (59, build_generator, 256),
    "shield": (17, build_shield, 256),
    "regen": (19, build_regen, 256),
    "radar": (23, build_radar, 256),
    "stab": (31, build_stab, 256),
    "belt": (37, build_belt, 256),
    "belt_cross": (41, build_belt_cross, 256),
    "belt_split": (43, build_belt_split, 256),
    "support": (47, build_support, 256),
    "rot_support": (53, build_rot_support, 256),
}


def make(name):
    seed, build, tex = BLOCKS[name]
    th.random.seed(seed)
    th.ISLANDS.clear()
    img = Image.new("RGB", (tex, tex), th.BLUE)
    pk = th.Packer(tex)
    parts = build(pk, img)
    todo = []
    for part, faces in parts.items():
        for f in faces:
            if f.uv is not None:
                continue
            n, pts2 = th.project(f)
            w = max(1, int(math.ceil(max(p[0] for p in pts2))))
            h = max(1, int(math.ceil(max(p[1] for p in pts2))))
            todo.append((h, w, f, n, pts2))
    todo.sort(key=lambda t: (-t[0], -t[1]))
    for h, w, f, n, pts2 in todo:
        rect = pk.take(w, h)
        th.paint_face(img, rect, pts2, f.style, n[1])
        f.uv = [(rect[0] + p[0], rect[1] + p[1]) for p in pts2]
    img.save(th.OUT_PNG % name)
    write_glb(parts, name, tex)
    for part, faces in parts.items():
        print("%s: %d triangles" % (part, sum(len(f.pts) - 2 for f in faces)))
    print("%s: texture %dx%d, used rows to %d px" % (name, tex, tex, pk.y + pk.row_h))


def write_glb(parts, name, tex):
    """One node and one mesh per part, all on one material and one embedded texture."""
    blob = bytearray()
    views, accs, meshes, nodes = [], [], [], []

    def put(data, fmt, target=None):
        off = len(blob)
        for row in data:
            blob.extend(struct.pack("<" + fmt, *(row if isinstance(row, tuple) else (row,))))
        while len(blob) % 4:
            blob.append(0)
        v = {"buffer": 0, "byteOffset": off, "byteLength": len(blob) - off}
        if target:
            v["target"] = target
        views.append(v)
        return len(views) - 1

    def acc(vi, ctype, count, typ, mn=None, mx=None):
        a = {"bufferView": vi, "componentType": ctype, "count": count, "type": typ}
        if mn is not None:
            a["min"], a["max"] = mn, mx
        accs.append(a)
        return len(accs) - 1

    for part, faces in parts.items():
        pos, nrm, uvs, idx = [], [], [], []
        for f in faces:
            n = th.newell(f.pts)
            base = len(pos)
            for p, t in zip(f.pts, f.uv):
                pos.append(p)
                nrm.append(n)
                uvs.append((t[0] / tex, t[1] / tex))
            for k in range(1, len(f.pts) - 1):
                idx += [base, base + k, base + k + 1]
        a_pos = acc(put(pos, "3f", 34962), 5126, len(pos), "VEC3",
                    [min(p[i] for p in pos) for i in range(3)], [max(p[i] for p in pos) for i in range(3)])
        a_nrm = acc(put(nrm, "3f", 34962), 5126, len(nrm), "VEC3")
        a_uv = acc(put(uvs, "2f", 34962), 5126, len(uvs), "VEC2")
        a_idx = acc(put(idx, "H", 34963), 5123, len(idx), "SCALAR")
        meshes.append({"name": part, "primitives": [{
            "attributes": {"POSITION": a_pos, "NORMAL": a_nrm, "TEXCOORD_0": a_uv},
            "indices": a_idx, "material": 0}]})
        nodes.append({"name": part, "mesh": len(meshes) - 1})
    png = open(th.OUT_PNG % name, "rb").read()
    off = len(blob)
    blob.extend(png)
    while len(blob) % 4:
        blob.append(0)
    views.append({"buffer": 0, "byteOffset": off, "byteLength": len(png)})
    gltf = {
        "asset": {"version": "2.0", "generator": "art/emitter_models.py"},
        "extensionsUsed": ["KHR_materials_unlit"],
        "scene": 0,
        "scenes": [{"nodes": list(range(len(nodes)))}],
        "nodes": nodes,
        "meshes": meshes,
        "materials": [{"name": name, "doubleSided": True,
                       "extensions": {"KHR_materials_unlit": {}},
                       "pbrMetallicRoughness": {"baseColorTexture": {"index": 0},
                                                "metallicFactor": 0, "roughnessFactor": 0.9}}],
        "textures": [{"source": 0, "sampler": 0}],
        "samplers": [{"magFilter": 9728, "minFilter": 9986}],
        "images": [{"bufferView": len(views) - 1, "mimeType": "image/png", "name": name + "_texture"}],
        "buffers": [{"byteLength": len(blob)}],
        "bufferViews": views,
        "accessors": accs,
    }
    js = json.dumps(gltf, separators=(",", ":")).encode()
    while len(js) % 4:
        js += b" "
    total = 12 + 8 + len(js) + 8 + len(blob)
    with open(th.OUT_GLB % name, "wb") as fh:
        fh.write(struct.pack("<III", 0x46546C67, 2, total))
        fh.write(struct.pack("<II", len(js), 0x4E4F534A) + js)
        fh.write(struct.pack("<II", len(blob), 0x004E4942) + bytes(blob))


if __name__ == "__main__":
    for nm in (sys.argv[1:] or list(BLOCKS)):
        make(nm)
