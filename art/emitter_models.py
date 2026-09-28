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


# ── the repair unit, second cut (preview) ──────────────────────────────────────────────────────
# No platform: four square-section bands (the first cut's round tubes were turned down for the old
# ring's flat band) whose whole inside is a glowing strip (a part of its own, tinted like the
# crystal: green working, dark off - emitter stubs on the inside were tried and dropped), round the crystal, seen from the front as "-", "|", "/" and "\" - every
# ring's plane holds the front axis (Z), turned about it by REGEN2_ANGLES. Nested at REGEN2_R so each
# can turn about its own axis without passing through the others; the outer one reaches the cell.
REGEN2_ANGLES = (0.0, 90.0, 45.0, 135.0)
REGEN2_R = (0.45, 0.39, 0.33, 0.27)
REGEN2_DEPTH = 0.024          # the band's half depth (radial) and half width
REGEN2_WIDTH = 0.04
REGEN2_JOINT = 2                 # a plate joint with bolts every this many facets


def _tone(n, kind):
    """The painted-light tone of a face with normal n, as the tube's facets are toned."""
    return "%stone%d" % (kind, int(round(max(0.0, min(1.0, 0.5 + 0.5 * th.dot(th.norm(n), LIGHT)))) * 4))


def square_ring(faces, glow, ang, R, depth, width, n=24):
    """A flat band of square section (the old repair ring's) round a circle of radius R whose plane
    holds the Z axis, turned about Z by ang degrees: plain blue outside and on the sides, each facet in
    its painted-light tone, and its whole INSIDE a glowing strip, a part of its own (`glow`) so the
    script can light and dim it. The outer face is dark plates drawn ACROSS the band - light running
    along each, a blue band across it with bolts every REGEN2_JOINT facets; the sides are the blue."""
    c, s_ = math.cos(math.radians(ang)), math.sin(math.radians(ang))
    nrm = (-s_, c, 0.0)                      # the ring plane's normal
    def at(t, dr, dn):
        rad = (math.cos(t) * c, math.cos(t) * s_, math.sin(t))
        return th.add(th.mul(rad, R + dr), th.mul(nrm, dn))
    for k in range(n):
        t0, t1 = 2 * math.pi * k / n, 2 * math.pi * (k + 1) / n
        tm = (t0 + t1) / 2
        rad = (math.cos(tm) * c, math.cos(tm) * s_, math.sin(tm))
        tan = (-math.sin(tm) * c, -math.sin(tm) * s_, math.cos(tm))
        for (d0, n0), (d1, n1), out, dest in (
                ((depth, -width), (depth, width), rad, faces),                      # outer
                ((-depth, width), (-depth, -width), th.mul(rad, -1), glow),         # inner: the energy
                ((-depth, width), (depth, width), nrm, faces),                      # sides
                ((depth, -width), (-depth, -width), th.mul(nrm, -1), faces)):
            q = [at(t0, d0, n0), at(t0, d1, n1), at(t1, d1, n1), at(t1, d0, n0)]
            cen = th.add(th.mul(rad, R), th.mul(out, -1.0))
            tone = _tone(out, "b")[5:]
            if dest is glow:
                style = "energy"
            elif out is rad:
                style = "rband" + tone + ("j" if k % REGEN2_JOINT == 0 else "")
            else:
                style = "rside" + tone
            dest.append(th.Face(th.outward(q, cen), style, u_hint=tan))


def obox(faces, centre, ax, half, styles):
    """A box on axes ax = (a, b, c) with half sizes half; styles[i] for the +a, -a, +b, -b, +c, -c faces."""
    k = 0
    for i in range(3):
        for sg in (1, -1):
            a, b2, c2 = ax[i], ax[(i + 1) % 3], ax[(i + 2) % 3]
            ha, hb, hc = half[i], half[(i + 1) % 3], half[(i + 2) % 3]
            f0 = th.add(centre, th.mul(a, sg * ha))
            q = [th.add(f0, th.add(th.mul(b2, x * hb), th.mul(c2, y * hc))) for x, y in
                 ((-1, -1), (1, -1), (1, 1), (-1, 1))]
            faces.append(th.Face(th.outward(q, centre), styles[k], u_hint=b2))
            k += 1


def _sleeve(faces, lo, hi, along, wall=0.018, style="dark"):
    """A hollow box open at both ends along axis `along` (0 x, 1 y, 2 z): the four walls round it."""
    for ax in range(3):
        if ax == along:
            continue
        for side in (0, 1):
            a, b = list(lo), list(hi)
            if side == 0:
                b[ax] = lo[ax] + wall
            else:
                a[ax] = hi[ax] - wall
            skip = ("+x", "-x") if along == 0 else (("+y", "-y") if along == 1 else ("+z", "-z"))
            th.box(faces, tuple(a), tuple(b), style, skip=skip)


def regen2_mounts():
    """ONE CONNECTOR FOR ALL SIX FACES (the player's call: mixed housings and hubs read as parts from
    different kits), after a gimbal's trunnions - every ring of a real gyroscope hangs on the same round
    pivot bearing where its axis meets the frame. Each is a dark hub down the face's axis, from just
    inside the ring it holds out to the face, and a blue flange flush on the face: the ring is threaded
    on the hub and slides round it. Only the hub's length differs - left/right hold the outer ring,
    top/bottom the vertical one, front/back all four, which pass the Z axis one behind the other."""
    f = []
    reach = {0: REGEN2_R[0], 1: REGEN2_R[1], 2: REGEN2_R[3]}
    for axis in (0, 1, 2):
        for sg in (1, -1):
            def p(d):
                v = [0.0, 0.0, 0.0]
                v[axis] = sg * d
                return tuple(v)
            d_in = reach[axis] - REGEN2_DEPTH - 0.04
            tube(f, [p(d_in), p(0.46)], [WL_HUB, WL_HUB], ["m"], sides=12, cap_start="cap_bolt")
            tube(f, [p(0.46), p(0.5)], [WL_FLANGE, WL_FLANGE], ["b"], sides=12, cap_start="blue",
                 cap_end="anchor_top_fixed")
    return f


WL_HUB, WL_FLANGE = 0.055, 0.105      # a connector's hub and flange radii


def build_regen2(pk, img):
    parts = {}
    for i, (ang, R) in enumerate(zip(REGEN2_ANGLES, REGEN2_R)):
        faces, glow = [], []
        square_ring(faces, glow, ang, R, REGEN2_DEPTH, REGEN2_WIDTH)
        parts["regen2_ring%d" % i] = faces
        parts["regen2_glow%d" % i] = glow
    parts["regen2_mount"] = regen2_mounts()
    parts["regen2_crystal"] = []
    lathe_y(pk, img, parts["regen2_crystal"], [(0.0, -0.21), (0.13, -0.04), (0.13, 0.04), (0.0, 0.21)],
            CORE_RAMP, sides=6, cell=4)
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
# A FLOATING DECK IN THE MIDDLE OF THE CELL, the receiver's height: the old conveyor's column and
# base plate are gone (the player's call - it stood on a post like the old receiver), and a shallow
# dark keel under the deck is all there is below it. The deck's top is BELT_TOP and the items'
# `item_slot` (belt*.tscn) sits half a bubble over it. The belt shows where cargo goes: arrows on a
# conveyor, arrows fanning out three ways on the fork, none on the crossing, which passes both axes.

BELT_TOP = 0.06          # the receiver's chute ends at the same height (build_receiver)


def belt_stand(pk, img, faces, keel=(0.22, 0.40)):
    th.prism(faces, -0.5, 0.5, BELT_TOP - 0.14, BELT_TOP - 0.02, 0.5, -0.5, 0.04)
    th.box(faces, (-keel[0], BELT_TOP - 0.20, -keel[1]), (keel[0], BELT_TOP - 0.14, keel[1]), "dark")


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
    belt_stand(pk, img, f, keel=(0.25, 0.25))
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
    belt_stand(pk, img, f, keel=(0.25, 0.25))
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
# ground materials and collectors' cargo in through its beam - is the CONVEYOR'S HEAD: the old
# plate's outline at the belts' own height, their rails run on round it. The COLLECTOR is a cube with a round bowl in its top,
# where the one item it shows sits (collector.gd HOLD_Y); now a dark grilled cube, a blue lid, and a
# dark bowl with a boss in the middle. Both used to stand out of their cell (the plate 9 cm over
# the top, the cube 1 cm past every face and its rim 7 cm up) on 450 and 882 plain triangles.
RECV_CUT = 0.22                  # how much of each BACK corner is cut off (the front stays square)
RECV_PAD_Z = 0.04               # the pad sits a little back, clear of the chevrons
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


def extrude_xz(faces, poly, y0, y1, side, top, bottom, u_top=(0, 0, -1)):
    """A convex polygon (x, z) extruded from y0 up to y1; a style of None leaves that face out."""
    cx = sum(p[0] for p in poly) / len(poly)
    cz = sum(p[1] for p in poly) / len(poly)
    centre = (cx, (y0 + y1) / 2, cz)
    n = len(poly)
    for i in range(n):
        (xa, za), (xb, zb) = poly[i], poly[(i + 1) % n]
        if side is None:
            break
        q = [(xa, y0, za), (xb, y0, zb), (xb, y1, zb), (xa, y1, za)]
        q = th.outward(q, centre)
        nn = th.newell(q)
        faces.append(th.Face(q, side, u_hint=th.cross((0, 1, 0), th.norm((nn[0], 0.0, nn[2])))))
    if top:
        faces.append(th.Face(th.outward([(x, y1, z) for x, z in poly], centre), top, u_hint=u_top))
    if bottom:
        faces.append(th.Face(th.outward([(x, y0, z) for x, z in poly], centre), bottom, u_hint=u_top))


def build_receiver(pk, img):
    """THE CONVEYOR'S HEAD: the player's old receiver, seen from above - a square plate with its
    BACK corners cut and its FRONT edge square, a blue octagon on a pad in the middle - drawn in the
    conveyors' own parts. Its deck stands at exactly the belt's heights (BELT_TOP), it is exactly
    the belt's width, and the belt's blue rails run on round its sides and back; the floor is the
    belt's ribbed rubber with two chevrons out to the front (FactoryBlock: front = -Z). Under it a
    dark octagonal emitter gives it body and says where the beam comes from. Rejected on the way: a
    plate on a post, a platform block, round saucers and a half-saucer - too thin, lower than the
    belt, and rounder than the plate the player meant."""
    parts = {"receiver_body": []}
    body = parts["receiver_body"]
    deck_lo, deck_hi, rail_hi = BELT_TOP - 0.14, BELT_TOP, BELT_TOP + 0.07
    cb, rw = RECV_CUT, 0.12                  # back-corner cut; rail width = the belt's rails
    outline = [(-0.5, -0.5), (0.5, -0.5), (0.5, 0.5 - cb), (0.5 - cb, 0.5), (-0.5 + cb, 0.5),
               (-0.5, 0.5 - cb)]
    extrude_xz(body, outline, deck_lo, deck_hi, "blue", "recv_floor", "dark")
    # The rails, round the sides and the back, in convex pieces (each between the outline and its
    # inset by the rail width). The inset of a 45-degree cut moves along its normal.
    k = rw * (math.sqrt(2) - 1)              # how far a mitred corner of the inset line moves
    xo, xi = 0.5, 0.5 - rw
    zb_o, zb_i = 0.5, 0.5 - rw
    for s in (-1, 1):
        side_ = [(s * xo, -0.5), (s * xo, 0.5 - cb), (s * xi, 0.5 - cb - k), (s * xi, -0.5)]
        cut_ = [(s * xo, 0.5 - cb), (s * (0.5 - cb), zb_o), (s * (0.5 - cb - k), zb_i),
                (s * xi, 0.5 - cb - k)]
        for piece in (side_, cut_):
            extrude_xz(body, piece, deck_hi - 0.02, rail_hi, "blue", "blue", None)
    back_ = [(-(0.5 - cb), zb_o), (0.5 - cb, zb_o), (0.5 - cb - k, zb_i), (-(0.5 - cb - k), zb_i)]
    extrude_xz(body, back_, deck_hi - 0.02, rail_hi, "blue", "blue", None)
    # The pad, the old model's: dark, a blue octagon on it.
    pad = []
    ph = 0.26                                # a REGULAR octagon, as the old model's ring was
    th.prism(pad, -ph, ph, RECV_PAD_Z - ph, RECV_PAD_Z + ph, deck_hi + 0.03, deck_hi,
             ph * (2 - math.sqrt(2)), side="dark", cap_front=None, cap_back="recv_pad")
    for f in pad:
        if f.style == "bevel":
            f.style = "dark_edge"
    # prism builds along Z with y as its second axis; turn it up: (x, y, z) -> (x, z, -y) then fix
    for f in pad:
        f.pts = [(p[0], p[2], p[1]) for p in f.pts]
        f.pts = th.outward(f.pts, (0.0, deck_hi + 0.015, RECV_PAD_Z))
        if f.u_hint:
            f.u_hint = (f.u_hint[0], f.u_hint[2], f.u_hint[1])
    body += pad
    # The emitter under the deck: a dark octagonal frustum, its face down a blue ring.
    lo, hi = octo(0.18, 0.05, deck_lo - 0.16), octo(0.32, 0.09, deck_lo)
    centre = (0.0, deck_lo - 0.08, 0.0)
    for i in range(8):
        j = (i + 1) % 8
        q = th.outward([lo[i], lo[j], hi[j], hi[i]], centre)
        nn = th.newell(q)
        body.append(th.Face(q, "dark_edge" if i % 2 else "dark",
                            u_hint=th.cross((0, 1, 0), th.norm((nn[0], 0.0, nn[2])))))
    body.append(th.Face(th.outward(lo, (0.0, deck_lo, 0.0)), "recv_pad", u_hint=(1, 0, 0)))
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


# ── the processor (smelter) and the seller: 2x2x2 ──────────────────────────────────────────────
# Both are 2x2x2 with the anchor in a corner: cells x -1/0 (left/right), z -1/0 (front/back),
# y 0/1, so the block spans x -1.5..0.5, y -0.5..1.5, z -1.5..0.5 in its own axes. EVERY PORT IS A
# QUARTER OF A FACE (blocks' port_defaults, "dx,dy,dz|face"), and the model shows exactly those:
#
# PROCESSOR: all its ports are in the RIGHT-BOTTOM column - IN on the back quarter and OUT on the
# front quarter (a line runs straight through it), and on the RIGHT face IN at the back quarter,
# OUT at the front one (a belt passing alongside hands ore in and takes the ingot, whichever way it
# runs - a belt's sides are both in and out). The ore goes ROUND through the furnace in the left
# column, clockwise (build_processor). Parts: processor_body, processor_glow (the fire: the gallery's
# ceiling and wall, the fireboxes - re-coloured by processor.gd, never batched).
#
# SELLER: one intake, the right-back-bottom quarter, from the back and from the right. So that cell
# is an open MOUTH at belt height under an open LIFT SHAFT the goods ride up to an uplink on the roof
# (build_seller). The rest is the VAULT, an L round the mouth.
CH_Y = BELT_TOP          # the channel / mouth deck top: the belts' own deck height


def crect(x0, x1, z0, z1, ch, y):
    """A rectangle with its corners cut by ch, at height y, as 8 points in order."""
    return [(x0 + ch, y, z0), (x1 - ch, y, z0), (x1, y, z0 + ch), (x1, y, z1 - ch),
            (x1 - ch, y, z1), (x0 + ch, y, z1), (x0, y, z1 - ch), (x0, y, z0 + ch)]


def frustum(faces, lo, hi, side, bevel, top):
    """Sloped housing between two 8-point rings (crect / octo); odd sides are the corner bevels."""
    cx = sum(p[0] for p in lo) / 8
    cz = sum(p[2] for p in lo) / 8
    centre = (cx, (lo[0][1] + hi[0][1]) / 2, cz)
    for i in range(8):
        j = (i + 1) % 8
        q = th.outward([lo[i], lo[j], hi[j], hi[i]], centre)
        nn = th.newell(q)
        faces.append(th.Face(q, bevel if i % 2 else side,
                             u_hint=th.cross((0, 1, 0), th.norm((nn[0], 0.0, nn[2])))))
    if top:
        faces.append(th.Face(th.outward(hi, (cx, hi[0][1] - 1.0, cz)), top, u_hint=(1, 0, 0)))


def restyle(faces, style, by_normal):
    """Give faces of `style` another style by their normal: by_normal = [((nx, nz), new), ...]."""
    for f in faces:
        if f.style != style:
            continue
        n = th.newell(f.pts)
        for (nx, nz), new in by_normal:
            if n[0] * nx + n[2] * nz > 0.9:
                f.style = new


def glow_quad(faces, centre, right, up, hw, hh, style="gen_fire"):
    """A window of glow `hw` x `hh` half-size, facing out along right x up's normal... in `faces`."""
    c, r, u = centre, right, up
    q = [th.add(c, th.add(th.mul(r, -hw), th.mul(u, -hh))), th.add(c, th.add(th.mul(r, hw), th.mul(u, -hh))),
         th.add(c, th.add(th.mul(r, hw), th.mul(u, hh))), th.add(c, th.add(th.mul(r, -hw), th.mul(u, hh)))]
    n = th.cross(r, u)
    faces.append(th.Face(th.outward(q, th.sub(c, n)), style, u_hint=r))


SM_MOUTH = 0.46         # the furnace mouths' top; the hatches cover them and lift by SM_HATCH_LIFT
SM_GAUGE = (-0.47, 0.58, -0.5)  # the gauge fill's base in block space (processor.tscn node `Gauge`)
SM_GAUGE_H = 0.36


def build_processor(pk, img):
    """THE ORE GOES ROUND, CLOCKWISE SEEN FROM ABOVE, AND THE FURNACE IS SOLID - the player's design:
    taken in on the right at the back, it goes LEFT into the furnace through a mouth, is gone inside
    (the model shows the melt, not the ore), and comes out to the RIGHT at the front through the
    other mouth, already the product. So the right column is the intake (arrows into the furnace)
    and the exit (plain: it leaves forward or right, and arrows for one said half of it), split by
    a divider; the
    left column is one closed furnace with two guillotine HATCHES over its mouths and a GAUGE of
    molten metal between them that fills while the ore is inside (processor.gd drives all three).
    Rejected on the way: a hood over a straight channel, a hot bed in an open channel, an open
    gallery (the ore in plain view, the furnace in pieces)."""
    parts = {"processor_body": [], "processor_glow": [], "processor_hatch_in": [],
             "processor_hatch_out": [], "processor_gauge": []}
    b, g = parts["processor_body"], parts["processor_glow"]
    fur_hi, roof_hi, deck_lo = 1.0, 1.26, CH_Y - 0.14
    # The right column: a base, the intake deck (arrows LEFT, into the furnace), the exit deck
    # (no arrows: the product leaves forward or right), the divider and the belts' rail stubs.
    cham_box(b, (-0.5, -0.5, -1.5), (0.5, deck_lo, 0.5), 0.04, "dark", None, "dark", "dark_edge")
    belt_strip(b, (-0.5, deck_lo, -0.5), (0.5, CH_Y, 0.5), "belt_fwd", (-1, 0, 0))
    belt_strip(b, (-0.5, deck_lo, -1.5), (0.5, CH_Y, -0.5), "belt", (0, 0, -1))
    th.box(b, (-0.5, CH_Y - 0.02, -0.56), (0.5, CH_Y + 0.12, -0.44), "blue")
    for z0, z1 in ((0.38, 0.5), (-1.5, -1.38)):
        th.box(b, (0.38, CH_Y - 0.02, z0), (0.5, CH_Y + 0.07, z1), "blue")
    # The furnace: one closed body, the full left column.
    fur = []
    cham_box(fur, (-1.5, -0.5, -1.5), (-0.5, fur_hi, 0.5), 0.067, "smelt_side", None, "dark",
             "dark_edge")
    restyle(fur, "smelt_side", [((1, 0), "plain_side")])
    b += fur
    # The mouths on its right wall, each a dark opening in a blue frame, at belt height.
    for cz in (0.0, -1.0):
        glow_quad(b, (-0.496, (CH_Y + SM_MOUTH) / 2, cz), (0, 0, -1), (0, 1, 0), 0.3,
                  (SM_MOUTH - CH_Y) / 2, style="dark")
        th.box(b, (-0.5, SM_MOUTH, cz - 0.36), (-0.44, SM_MOUTH + 0.05, cz + 0.36), "blue")
        for dz in (-0.36, 0.3):
            th.box(b, (-0.5, CH_Y, cz + dz), (-0.44, SM_MOUTH, cz + dz + 0.06), "blue")
    # The hatches: blue plates with hazard trim over the mouths, lifted by processor.gd.
    for name, cz in (("processor_hatch_in", 0.0), ("processor_hatch_out", -1.0)):
        th.box(parts[name], (-0.46, CH_Y, cz - 0.3), (-0.43, SM_MOUTH, cz + 0.3), "blue",
               face_styles={"+x": "stripe", "-x": "stripe"})
    # The gauge between the mouths: a dark well in a blue frame, and the fill (a part of its own,
    # its base at SM_GAUGE so processor.gd scales it upward).
    gx, gy, gz = SM_GAUGE
    th.box(b, (-0.5, gy - 0.03, gz - 0.12), (-0.46, gy + SM_GAUGE_H + 0.03, gz + 0.12), "blue")
    glow_quad(b, (-0.458, gy + SM_GAUGE_H / 2, gz), (0, 0, -1), (0, 1, 0), 0.08, SM_GAUGE_H / 2,
              style="dark")
    th.box(parts["processor_gauge"], (-0.456 - gx, 0.0, -0.075), (-0.445 - gx, SM_GAUGE_H, 0.075),
           "molten")
    # The fire: grates on the furnace's outer walls.
    glow_quad(g, (-1.504, 0.35, -0.5), (0, 0, 1), (0, 1, 0), 0.7, 0.25)
    glow_quad(g, (-1.0, 0.35, -1.504), (-1, 0, 0), (0, 1, 0), 0.3, 0.25)
    glow_quad(g, (-1.0, 0.35, 0.504), (1, 0, 0), (0, 1, 0), 0.3, 0.25)
    # The roof over the furnace only, two chimneys on it.
    frustum(b, crect(-1.48, -0.52, -1.48, 0.48, 0.12, fur_hi), crect(-1.36, -0.64, -1.36, 0.36, 0.08, roof_hi),
            "blue", "bevel", "blue")
    for cz in (-0.95, -0.05):
        lathe_y(pk, img, b, [(0.14, roof_hi), (0.14, 1.44), (0.18, 1.47), (0.18, 1.5), (0.0, 1.5)],
                METAL_RAMP, sides=8, cx=-1.0, cz=cz, ring_ramps={1: BLUE_RAMP, 2: BLUE_RAMP,
                                                              3: [th.METAL[0]]})
    return parts


SL_TOP = 0.95           # the vault's top and the roof's underside: the shaft ends here
SL_SHAFT_R = 0.30       # the lift shaft's rails stand on this circle; the goods ride inside it
SL_BEZEL = 0.06         # how far the screen's bezel stands off the vault's front
SL_SCREEN = (-1.34, 0.34, 0.2, 0.84)   # the glass: x0, x1, y0, y1 (seller.tscn's Label3D sits on it)


def build_seller(pk, img):
    """THE SALE IS SHOWN, NOT IMPLIED. Goods come in at belt height through the MOUTH (the one
    intake quarter, right-back-bottom, from the back and the right), RIDE UP an open LIFT SHAFT - four
    rails and two rings, so they are seen going - into the roof, and are beamed off at the UPLINK on
    top: a gold ring there spins up with every sale (seller.gd) and the SCREEN across the front
    flashes and says what went for how much (the scene's Label3D stands on its glass; a coin and a
    chart painted there were replaced by a real display, the player's call). The rest is the vault,
    an L round the mouth, with a round vault door on the left.
    Parts: seller_body (still), seller_ring (turns), seller_screen (flashed, never batched)."""
    parts = {"seller_body": [], "seller_ring": [], "seller_screen": []}
    b = parts["seller_body"]
    top = SL_TOP
    # The vault: the left column full depth, and the front-right cell, both stopping short of the
    # front face by SL_BEZEL so the screen's bezel stands on it inside the cell.
    for lo, hi in (((-1.5, -0.5, -1.5 + SL_BEZEL), (-0.5, top, 0.5)),
                   ((-0.5, -0.5, -1.5 + SL_BEZEL), (0.5, top, -0.5))):
        v = []
        cham_box(v, lo, hi, 0.067, "vault", None, "dark", "dark_edge")
        restyle(v, "vault", [((0, -1), "plain_side"), ((-1, 0), "vault_door"), ((1, 0), "plain_side"),
                             ((0, 1), "plain_side")])
        b += v
    falsus_plate(b, (-1.0, 0.25, 0.504), (1, 0, 0), 0.8)   # the vault's plain back wall
    # THE SCREEN: one wide display across the whole front in a blue bezel, blank - the game writes
    # on it (the scene's Label3D stands on its glass) - with a row of status lamps under it.
    sx0, sx1, sy0, sy1 = SL_SCREEN
    th.box(b, (sx0 - 0.08, sy0 - 0.08, -1.5), (sx1 + 0.08, sy1 + 0.08, -1.5 + SL_BEZEL), "blue")
    glow_quad(parts["seller_screen"], ((sx0 + sx1) / 2, (sy0 + sy1) / 2, -1.504), (-1, 0, 0),
              (0, 1, 0), (sx1 - sx0) / 2, (sy1 - sy0) / 2, style="screen")
    glow_quad(b, ((sx0 + sx1) / 2, sy0 - 0.2, -1.5 + SL_BEZEL - 0.004), (-1, 0, 0), (0, 1, 0),
              0.55, 0.06, style="lamp_strip")
    # The mouth: the right-back cell, open to the back and the right at the belts' deck height.
    cham_box(b, (-0.5, -0.5, -0.5), (0.5, CH_Y - 0.14, 0.5), 0.04, "slab_side", None, "dark",
             "dark_edge")
    belt_strip(b, (-0.5, CH_Y - 0.14, -0.5), (0.5, CH_Y, 0.5), "belt", (0, 0, -1))
    # The lift shaft over it: four blue rails and two rings, open between them.
    for k in range(4):
        a = (k + 0.5) * math.pi / 2
        x, z = SL_SHAFT_R * math.cos(a), SL_SHAFT_R * math.sin(a)
        th.box(b, (x - 0.035, CH_Y, z - 0.035), (x + 0.035, top, z + 0.035), "blue")
    for y in (0.40, 0.70):             # two rings, their outer wall and top: all that is seen
        lathe_y(pk, img, b, [(SL_SHAFT_R + 0.05, y), (SL_SHAFT_R + 0.05, y + 0.04),
                             (SL_SHAFT_R - 0.02, y + 0.04)], METAL_RAMP, sides=8)
    # The roof, and on it the uplink the shaft feeds: a blue mast and an emitter tip.
    frustum(b, crect(-1.48, 0.48, -1.48, 0.48, 0.14, top), crect(-1.3, 0.3, -1.3, 0.3, 0.1, 1.2),
            "blue", "bevel", "blue")
    lathe_y(pk, img, b, [(0.22, 1.2), (0.22, 1.25), (0.1, 1.29), (0.08, 1.42), (0.16, 1.45),
                         (0.16, 1.48), (0.0, 1.5)], BLUE_RAMP, sides=8, ring_ramps={0: METAL_RAMP})
    # Two short aerials on the roof's front corners, gold-tipped.
    for x in (-1.2, 0.2):
        th.box(b, (x - 0.025, 1.2, -1.2 - 0.025), (x + 0.025, 1.44, -1.2 + 0.025), "dark")
        th.box(b, (x - 0.045, 1.44, -1.2 - 0.045), (x + 0.045, 1.5, -1.2 + 0.045), "blue")
    # The ring round the mast: gold with dark ticks, so its turn is seen.
    gold = [th.GOLD_LO, th.GOLD, th.GOLD, th.GOLD]
    ticks = {(i, 1): th.METAL[1] for i in range(0, 8, 2)}
    lathe_y(pk, img, parts["seller_ring"], [(0.14, 1.31), (0.28, 1.32), (0.28, 1.37), (0.14, 1.38),
                                            (0.14, 1.31)], gold, sides=8, marks=ticks)
    return parts


# ── the storage ─────────────────────────────────────────────────────────────────────────────────
# One kind of material, up to storage.gd CAPACITY, in and out on all four sides. What it has to SAY
# is how full it is, so that is its one pop colour: a level bar in a slot down the middle of every
# wall (storage_level, scaled by storage.gd from its base). The one item it shows sits in a tray in
# the lid (storage.tscn item_slot). The walls are a container's corrugation - the frame block's
# grille would make it one more generator.
STORE_TRAY = 0.30        # the tray's half-width in the lid
STORE_FLOOR = 0.32       # the tray's floor
STORE_LEVEL_Y = -0.355   # the level bar's base (storage.tscn node `Level`)
STORE_LEVEL_H = 0.70     # its full height: the slot painted in store_side


def build_storage(pk, img):
    parts = {"storage_body": [], "storage_level": []}
    b = parts["storage_body"]
    c, o, t = 0.067, 0.5 - 0.067, STORE_TRAY
    cham_box(b, (-0.5, -0.5, -0.5), (0.5, 0.5, 0.5), c, "store_side", None, "dark", "dark_edge")
    # The upright edges are the container's blue corner posts: next to the collector's all-dark
    # cube it would otherwise read as the same block with a square hole.
    for f in b:
        if f.style == "dark_edge" and len(f.pts) == 4 and abs(th.norm(th.newell(f.pts))[1]) < 0.1:
            f.style = "bevel"
    # The lid: a blue frame round the tray, four trapezoids.
    for k in range(4):
        a = k * math.pi / 2
        ca, sa = round(math.cos(a)), round(math.sin(a))

        def pt(u, v):   # u across the side, v outward from the middle
            return (ca * v - sa * u, 0.5, sa * v + ca * u)
        q = [pt(-o, o), pt(o, o), pt(t, t), pt(-t, t)]
        b.append(th.Face(th.outward(q, (0.0, -1.0, 0.0)), "blue", u_hint=(-sa, 0, ca)))
        # the tray's wall under that side, facing in
        w = [pt(-t, t), pt(t, t), (pt(t, t)[0], STORE_FLOOR, pt(t, t)[2]),
             (pt(-t, t)[0], STORE_FLOOR, pt(-t, t)[2])]
        b.append(th.Face(th.outward(w, (ca * 2.0, 0.4, sa * 2.0)), "dark", u_hint=(-sa, 0, ca)))
    floor = [(-t, STORE_FLOOR, -t), (t, STORE_FLOOR, -t), (t, STORE_FLOOR, t), (-t, STORE_FLOOR, t)]
    b.append(th.Face(th.outward(floor, (0.0, -1.0, 0.0)), "store_floor", u_hint=(1, 0, 0)))
    # The level bars: one per wall, a hair proud of it, built from y 0 so the script scales them up.
    for k in range(4):
        a = k * math.pi / 2
        nx, nz = round(math.cos(a)), round(math.sin(a))
        tx, tz = -nz, nx
        off = 0.5 + 0.004
        q = [(nx * off + tx * s, yy, nz * off + tz * s) for s, yy in
             ((-0.055, 0.0), (0.055, 0.0), (0.055, STORE_LEVEL_H), (-0.055, STORE_LEVEL_H))]
        parts["storage_level"].append(th.Face(th.outward(q, (0.0, STORE_LEVEL_H / 2, 0.0)), "level",
                                              u_hint=(tx, 0.0, tz)))
    return parts


# ── the packer, and the three 2x2x2 machines drawn from their ports ─────────────────────────────
# PACKER (one cell, in and out on all four sides) - an ELECTROMAGNET: copper windings (its recipe
# is coils) between a blue flange and cap, on a dark base with a horseshoe on every wall, and a
# polished pole on top the chunks it packs rest on.
#
# FABRICATOR and SCRAPPER are 2x2x2, anchored in a corner like the smelter (cells
# x -1/0, z -1/0, y 0/1: the block spans x -1.5..0.5, y -0.5..1.5, z -1.5..0.5). The player's
# design, port by port - every port a quarter of a face, all at the belts' height:
#   COMPONENT PLANT - 2x1x2 (cells x -1/0, z -1/0, one high): IN on both halves of the back, OUT on
#     the front's right column (x 0, the smelter's). Nothing on its roof but a drawing: two ingots,
#     arrows in to a gear, an arrow out.
#   FABRICATOR - IN on both bottom quarters of the back; the finished block leaves through a PIPE
#     on the roof and is thrown out of its mouth at the front (fabricator.gd, marker `pipe_mouth`).
#     Cyan windows in its sides: the grid a block materialises on.
#   SCRAPPER - a SUCTION PIPE draws loose blocks in (scrapper.gd, marker `nozzle`) and feeds a
#     hopper on the roof with two toothed rollers that turn while it works (`RollerA/B`); the
#     materials leave on the front's bottom quarter, right column.
BIG_TOP = 0.55           # the 2x2x2 bases' roof: the ground floor and a little over
MOUTH_HW = 0.44          # a belt mouth's half-width: its frame on the belt's rails
PLANT_MOUTH = 0.40       # the plant's mouths' top: its wall ends under the chamfer at 0.433
SC_ROLL = (-0.5, 0.76, -0.8, 0.135, 0.12)   # scrapper rollers: x, y, z, z-offset each, radius


def funnel(faces, top, bottom, style):
    """The INSIDE of a hopper between two 8-point rings (crect), every quad facing the axis."""
    for i in range(8):
        j = (i + 1) % 8
        q = [top[i], top[j], bottom[j], bottom[i]]
        mid = tuple(sum(p[k] for p in q) / 4 for k in range(3))
        ax = (sum(p[0] for p in bottom) / 8, mid[1], sum(p[2] for p in bottom) / 8)
        out = th.norm((mid[0] - ax[0], 0.0, mid[2] - ax[2]))
        faces.append(th.Face(th.outward(q, th.add(mid, th.mul(out, 3.0))), style,
                             u_hint=th.cross((0, 1, 0), out)))


def flat_ring(faces, outer, inner, style):
    """A flat band between two 8-point rings at one height, facing up."""
    for i in range(8):
        j = (i + 1) % 8
        q = [outer[i], outer[j], inner[j], inner[i]]
        e = th.norm(th.sub(outer[j], outer[i]))
        faces.append(th.Face(th.outward(q, (0.0, q[0][1] - 1.0, 0.0)), style, u_hint=e))


def tube(faces, path, radii, kinds, sides=8, cap_start=None, cap_end=None):
    """A pipe along a polyline: rings carried along by parallel transport (no twist), one kind per
    segment - "m" dark metal, "b" blue, "c" glowing cyan - every facet toned by the painted light
    (mtone / btone / ctone)."""
    rings, u_prev = [], None
    n = len(path)
    for i, p in enumerate(path):
        if i == 0:
            t = th.sub(path[1], path[0])
        elif i == n - 1:
            t = th.sub(path[-1], path[-2])
        else:
            t = th.add(th.norm(th.sub(path[i], path[i - 1])), th.norm(th.sub(path[i + 1], path[i])))
        t = th.norm(t)
        if u_prev is None:
            a = (0, 1, 0) if abs(t[1]) < 0.9 else (1, 0, 0)
            u = th.norm(th.cross(a, t))
        else:
            u = th.norm(th.sub(u_prev, th.mul(t, th.dot(u_prev, t))))
        v = th.cross(t, u)
        u_prev = u
        ring = []
        for j in range(sides):
            ang = (j + 0.5) * 2 * math.pi / sides
            ring.append(th.add(p, th.add(th.mul(u, radii[i] * math.cos(ang)), th.mul(v, radii[i] * math.sin(ang)))))
        rings.append(ring)
    for k in range(n - 1):
        c = th.mul(th.add(path[k], path[k + 1]), 0.5)
        along = th.norm(th.sub(path[k + 1], path[k]))
        for j in range(sides):
            jj = (j + 1) % sides
            q = th.outward([rings[k][j], rings[k][jj], rings[k + 1][jj], rings[k + 1][j]], c)
            nn = th.norm(th.newell(q))
            tone = int(round(max(0.0, min(1.0, 0.5 + 0.5 * th.dot(nn, LIGHT))) * 4))
            faces.append(th.Face(q, "%stone%d" % (kinds[k], tone), u_hint=along))
    for cap, i, j in ((cap_start, 0, 1), (cap_end, n - 1, n - 2)):
        if cap:
            inside = th.add(path[i], th.mul(th.norm(th.sub(path[j], path[i])), 0.1))
            faces.append(th.Face(th.outward(list(rings[i]), inside), cap, u_hint=u_prev))


def belt_mouth(faces, cx, cz, nrm, top=SM_MOUTH):
    """An opening at belt height in the wall whose outward normal is nrm (+-X or +-Z), centred on
    (cx, cz) of that face, as WIDE AS THE BELT (its blue frame on the belt's rails, the dark hole
    the belt's floor): a painted frame a hair proud of the wall - a frame of boxes would stand out
    of the cell, since this wall IS the cell's face. Narrower, it read as smaller than the belt."""
    nx, nz = nrm
    glow_quad(faces, (cx + nx * 0.004, (CH_Y - 0.06 + top) / 2, cz + nz * 0.004), (-nz, 0, nx),
              (0, 1, 0), MOUTH_HW, (top - CH_Y + 0.06) / 2, style="mouth")


def paint_island(pk, img, faces, x0, x1, z0, z1, y, fn):
    """A face on top at height y whose texels map straight onto the world: pixel x runs along +X,
    pixel y along +Z (so low rows are the FRONT), painted by fn(px, py, w, h) -> colour. For a
    drawing that has to know which way the machine faces."""
    w, h = int(math.ceil((x1 - x0) * th.DENS)), int(math.ceil((z1 - z0) * th.DENS))
    rx, ry, _, _ = pk.take(w, h)
    for yy in range(-th.PAD, h + th.PAD):
        for xx in range(-th.PAD, w + th.PAD):
            img.putpixel((rx + xx, ry + yy), fn(min(max(xx, 0), w - 1) + 0.5, min(max(yy, 0), h - 1) + 0.5, w, h))
    pts = th.outward([(x0, y, z0), (x1, y, z0), (x1, y, z1), (x0, y, z1)], (0.0, y - 1.0, 0.0))
    f = th.Face(pts, None)
    f.uv = [(rx + (p[0] - x0) * th.DENS, ry + (p[2] - z0) * th.DENS) for p in pts]
    faces.append(f)


def plant_top(px, py, w, h):
    """The component plant's roof: two ingots at the back (its two inputs), arrows in to a big gear
    (what it makes), and one arrow out to the front in the right column (its output)."""
    d = min(px, py, w - px, h - py)
    if d < 1.0:
        return th.BLUE_HI
    if d < 2.0:
        return th.BLUE_MID
    for rx, ry in ((4, 4), (w - 5, 4), (4, h - 5), (w - 5, h - 5)):
        if int(px) == rx and int(py) == ry:
            return th.BLUE_DEEP
    s = min(w, h) / 24.0
    gx, gy = (px - w * 0.5) / s, (py - h * 0.48) / s
    if math.hypot(gx, gy) <= 5.4:
        return th.RIM[4] if th._gear(gx, gy) else th.BLUE_DEEP
    for cx in (w * 0.25, w * 0.75):
        bx, by = px - cx, py - h * 0.86
        if -2.5 <= by <= 2.5 and abs(bx) <= 4.5 + (by + 2.5) * 0.5:
            return th.WHITE if by < -1.0 else th.RIM[3]
    for tx, ty in ((w * 0.25, h * 0.66), (w * 0.75, h * 0.66), (w * 0.75, h * 0.14)):
        a = py - ty                              # behind the tip, toward the back (+py)
        off = abs(px - tx)
        if 0 <= a <= 5 and abs(off - a) < 1.0:
            return th.ORANGE if a > 1 else th.ORANGE_LO
    return th.jitter(th.BLUE, 2)


def falsus_plate(faces, centre, right, size):
    """The Falsus faction's sign plate (turret_heads "falsus_plate"), a hair proud of a wall whose
    outward normal is right x up. ONE per block, and only where a wall has room: the player's
    call - not on every block, and two on one read as clutter."""
    glow_quad(faces, centre, right, (0, 1, 0), size / 2, size / 2, style="falsus_plate")


def big_base(b, side):
    """The 2x2x2 machines' ground floor: one dark body the full footprint up to BIG_TOP."""
    cham_box(b, (-1.5, -0.5, -1.5), (0.5, BIG_TOP, 0.5), 0.067, side, "dark", "dark", "dark_edge")


def build_comp_factory(pk, img):
    """2x1x2, flat on the floor of its cells (the player's call): nothing on the roof but a drawing
    of what it does - a press, bins and an off-centre press were tried first and read as detail with
    nothing to say."""
    parts = {"comp_factory_body": []}
    b = parts["comp_factory_body"]
    c = 0.067
    cham_box(b, (-1.5, -0.5, -1.5), (0.5, 0.5, 0.5), c, "comp_side", None, "dark", "dark_edge")
    paint_island(pk, img, b, -1.5 + c, 0.5 - c, -1.5 + c, 0.5 - c, 0.5, plant_top)
    for cx in (-1.0, 0.0):
        belt_mouth(b, cx, 0.5, (0, 1), top=PLANT_MOUTH)   # the two inputs: the back
    belt_mouth(b, 0.0, -1.5, (0, -1), top=PLANT_MOUTH)    # the output: the front, right column
    falsus_plate(b, (-1.504, 0.0, 0.1), (0, 0, 1), 0.6)   # the left wall, beside the gear
    return parts


def build_fabricator(pk, img):
    parts = {"fabricator_body": []}
    b = parts["fabricator_body"]
    big_base(b, "fab_side")
    for cx in (-1.0, 0.0):
        belt_mouth(b, cx, 0.5, (0, 1))
    # The assembly windows, one in each side wall: the grid a block materialises on.
    glow_quad(b, (-1.504, 0.12, -0.5), (0, 0, 1), (0, 1, 0), 0.62, 0.26, style="fab_window")
    glow_quad(b, (0.504, 0.12, -0.5), (0, 0, -1), (0, 1, 0), 0.62, 0.26, style="fab_window")
    falsus_plate(b, (-1.1, 0.02, -1.504), (-1, 0, 0), 0.66)  # the front wall, beside the block sign
    # The assembly housing over the base, and on it the PIPE the block leaves by: up, over and out
    # of a flared mouth at the front.
    frustum(b, crect(-1.46, 0.46, -1.46, 0.46, 0.14, BIG_TOP), crect(-1.3, 0.3, -1.3, 0.3, 0.12, 0.95),
            "blue", "bevel", "dark")
    # It starts near the front: a pipe run back across the roof and round read as a hose.
    path = [(-0.5, 0.95, -0.72), (-0.5, 1.07, -0.72), (-0.5, 1.16, -0.8), (-0.5, 1.2, -0.92),
            (-0.5, 1.2, -1.36), (-0.5, 1.2, -1.42), (-0.5, 1.2, -1.5)]
    tube(b, path, [0.26, 0.2, 0.2, 0.2, 0.2, 0.24, 0.28], ["b", "m", "m", "m", "b", "b"],
         cap_end="dark")
    return parts


def build_scrapper(pk, img):
    parts = {"scrapper_body": [], "scrapper_roller_a": [], "scrapper_roller_b": []}
    b = parts["scrapper_body"]
    big_base(b, "scrap_side")
    belt_mouth(b, 0.0, -1.5, (0, -1))           # the output: the front's bottom quarter, right column
    falsus_plate(b, (-1.504, 0.02, 0.1), (0, 0, 1), 0.66)  # the left wall, beside the split block
    # The hopper on the front half of the roof, hazard slats round its rim.
    lo, hi = crect(-1.3, 0.3, -1.35, -0.25, 0.10, BIG_TOP), crect(-1.45, 0.45, -1.48, -0.12, 0.12, 1.05)
    frustum(b, lo, hi, "blue", "bevel", None)
    inner = crect(-1.35, 0.35, -1.38, -0.22, 0.10, 1.05)
    flat_ring(b, hi, inner, "slab_side")
    bottom = crect(-1.2, 0.2, -1.08, -0.52, 0.06, 0.62)
    funnel(b, inner, bottom, "dark")
    b.append(th.Face(th.outward(bottom, (-0.5, 0.0, -0.8)), "dark", u_hint=(1, 0, 0)))
    # The suction pipe: a flared nozzle at the back, over the roof and down into the hopper.
    path = [(-0.5, 1.0, 0.36), (-0.5, 1.08, 0.24), (-0.5, 1.26, 0.08), (-0.5, 1.34, -0.1),
            (-0.5, 1.28, -0.3), (-0.5, 1.12, -0.46)]
    tube(b, path, [0.26, 0.14, 0.13, 0.13, 0.13, 0.13], ["b", "m", "m", "m", "b"], cap_start="dark")
    # The rollers, each about its own axle along X through the origin (the scene places them):
    # light teeth on every other facet, so the turn is seen.
    r, half = SC_ROLL[4], 0.62
    teeth = {(i, k): (th.RIM[4] if i % 2 else th.METAL[1]) for i in range(8) for k in (1, 2, 3)}
    for name in ("scrapper_roller_a", "scrapper_roller_b"):
        prof = [(0.0, -half), (r * 0.7, -half), (r, -half + 0.08), (r, 0.0), (r, half - 0.08),
                (r * 0.7, half), (0.0, half)]
        part = []
        lathe_y(pk, img, part, prof, METAL_RAMP, sides=8, marks=teeth)
        for f in part:
            f.pts = [(p[1], p[0], p[2]) for p in f.pts]
        parts[name] += part
    return parts


def build_packer(pk, img):
    parts = {"packer_body": []}
    b = parts["packer_body"]
    o = 0.5 - 0.067
    cham_box(b, (-0.5, -0.5, -0.5), (0.5, 0.0, 0.5), 0.067, "pack_side", None, "dark", "dark_edge")
    frustum(b, crect(-o, o, -o, o, 0.12, 0.0), crect(-o, o, -o, o, 0.12, 0.06), "blue", "bevel", "blue")
    frustum(b, crect(-0.37, 0.37, -0.37, 0.37, 0.10, 0.06), crect(-0.37, 0.37, -0.37, 0.37, 0.10, 0.34),
            "coil", "coil", None)
    frustum(b, crect(-0.42, 0.42, -0.42, 0.42, 0.12, 0.34), crect(-0.42, 0.42, -0.42, 0.42, 0.12, 0.40),
            "blue", "bevel", "blue")
    frustum(b, crect(-0.17, 0.17, -0.17, 0.17, 0.05, 0.40), crect(-0.14, 0.14, -0.14, 0.14, 0.04, 0.5),
            "dark", "dark_edge", "pole")
    return parts


# ── the battery and the wireless charger ────────────────────────────────────────────────────────
# THE BATTERY JOINS ON ALL SIX FACES, AND THE BLOCK ITSELF REACHES THEM - no frame round it (a cage of posts
# and beams was tried and the player turned it down). Round parts have 12 sides with their FLATS ON
# THE CELL'S FACES (flat_r, 12 sides), so a round body meets a side neighbour on a face, not an edge.
# BATTERY - a cell as wide as the cell: flats on the four sides, the flat - end on the bottom face,
#   the + nub up to the top face, a blue top band. Four charge rings sit in GROOVES round the body
#   (battery_seg, one mesh on nodes Seg0..3) and light by the block's own charge (battery.gd); a dark
#   ring leaves its groove showing, so an empty battery still reads as one.
# WIRELESS CHARGER - TerraTech's GSO charger's two cyan coils, held by a shell on the back face.
BAT_SEG_Y = (-0.32, -0.20, -0.08, 0.04)   # charge ring centres, bottom up (battery.tscn Seg0..3)
BAT_SEG_HH = 0.04
BAT_GROOVE = 0.46                # the grooves' floor; the rings stand in them to BAT_RING
BAT_RING = 0.49
GREEN_RAMP = [(34, 104, 62), (52, 146, 86), (80, 205, 120), (120, 230, 150), (170, 248, 192)]
SLOT_RAMP = [(20, 30, 25), (26, 40, 33), (34, 50, 42), (44, 62, 52), (56, 76, 64)]
WL_COIL = (0.415, 0.08)          # a coil: radius and tube - its outside reaches the side faces
WL_COILS_Y = (-0.1, 0.1)         # the two coils' heights, one over the other round the middle
WL_CLAMP = math.radians(30)      # the shell's arc: a twelfth of the coil's round
CYAN_RAMP = [(18, 60, 78), (26, 98, 124), (52, 158, 190), (104, 214, 236), (186, 248, 255)]


def build_battery(pk, img):
    parts = {"battery_body": [], "battery_seg": []}
    fr = lambda r: flat_r(r, 12)
    hh = BAT_SEG_HH
    prof = [(0.0, -0.5), (fr(0.45), -0.5), (fr(0.5), -0.46)]
    ramps = {}
    for yc in BAT_SEG_Y:
        # a groove: in, down its floor, out again - the charge ring stands in it
        prof += [(fr(0.5), yc - hh), (fr(BAT_GROOVE), yc - hh), (fr(BAT_GROOVE), yc + hh), (fr(0.5), yc + hh)]
        for k in (len(prof) - 4, len(prof) - 3, len(prof) - 2):
            ramps[k] = SLOT_RAMP
    k = len(prof)
    prof += [(fr(0.5), 0.14), (fr(0.5), 0.40), (fr(0.44), 0.45), (fr(0.15), 0.45), (fr(0.15), 0.5), (0.0, 0.5)]
    ramps[k - 1] = METAL_RAMP                      # the body up to the band
    ramps[k] = BLUE_RAMP                           # the blue top band and its shoulder
    ramps[k + 1] = BLUE_RAMP
    ramps[k + 3] = th.RIM                          # the + nub
    ramps[k + 4] = th.RIM
    lathe_y(pk, img, parts["battery_body"], prof, METAL_RAMP, sides=12, ring_ramps=ramps)
    # one charge ring, centred on y 0: the scene stands four copies at BAT_SEG_Y
    e = hh - 0.006
    lathe_y(pk, img, parts["battery_seg"], [(fr(BAT_GROOVE), -e), (fr(BAT_RING), -e), (fr(BAT_RING), e),
                                            (fr(BAT_GROOVE), e)], GREEN_RAMP, sides=12)
    return parts


def build_wireless(pk, img):
    """TerraTech's GSO Wireless Charger, the player's cut of it: NOTHING BUT THE TWO COILS - thick
    glowing cyan rings as wide as the cell, so they reach its side faces - and, on the back, a SHELL
    wrapped round both over a twelfth of their round (`WL_CLAMP`), standing flush on the back face.
    That shell is the mount: the block joins by its back only (`connect_faces` FACE_BACK, like a
    wheel; TerraTech's joins by one side too). No platform, no post, no dome - each was tried and
    turned down. The coils turn through the shell while energy flows (wireless_charger.gd `Ring`);
    the beam leaves their middle (`EMIT`)."""
    parts = {"wireless_body": [], "wireless_ring": []}
    b, ring = parts["wireless_body"], parts["wireless_ring"]
    R, r = WL_COIL
    # the shell: a chamfered block round both coils on the back, its back face on the cell's
    half = R * math.sin(WL_CLAMP / 2) + 0.02
    top = max(abs(y) for y in WL_COILS_Y) + r + 0.035
    cham_box(b, (-half, -top, R - r - 0.035), (half, top, 0.5), 0.03, "wl_shell", "blue", "blue", "bevel")
    # the two coils: cyan, a dark seam every few segments so their turn is seen
    n = 24
    for yc in WL_COILS_Y:
        path = [(R * math.cos(a), yc, R * math.sin(a)) for a in (2 * math.pi * k / n for k in range(n + 1))]
        tube(ring, path, [r] * (n + 1), ["m" if k % 6 == 0 else "c" for k in range(n)], sides=6)
    return parts


BLOCKS = {
    "regen2": (109, build_regen2, 512),
    "wireless": (107, build_wireless, 256),
    "battery": (103, build_battery, 256),
    "comp_factory": (83, build_comp_factory, 512),
    "fabricator": (101, build_fabricator, 512),
    "scrapper": (89, build_scrapper, 512),
    "packer": (97, build_packer, 256),
    "storage": (79, build_storage, 256),
    "processor": (71, build_processor, 512),
    "seller": (73, build_seller, 512),
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


# A model whose details are finer than the atlas's ~48 px/m paints at its own density (texels per
# metre); everything else keeps the family's.
DENSITY = {"regen2": 128.0}


def make(name):
    seed, build, tex = BLOCKS[name]
    th.DENS = DENSITY.get(name, 48.0)
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
