#!/usr/bin/env python3
"""Builds the SHIELD, the REPAIR UNIT (regen), the RADAR and the RISER / STABILISER wheels.

    python3 art/emitter_models.py [shield|regen|radar|riser|stab ...]    (no argument: all)
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
            phase=0.5):
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
            cells[(i, k)] = ramp_colour(rr, th.norm(want))
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


# ── the riser and the stabiliser wheels ─────────────────────────────────────────────────────────
# Both carry the artist's SMALL tyre and hub (Assets.glb Wheel_small / Wheel_Axle) and the artist's
# mounting plate; what is generated here is only what those two lack - a strut and a fork, a mount
# and trailing arms - so the tyre on them is the very tyre on the small wheel.

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


def seg_xy(faces, p0, p1, w, h, style):
    """A bar from p0 to p1 in the XY plane, w wide (along Z) and h thick."""
    dx, dy = p1[0] - p0[0], p1[1] - p0[1]
    ln = math.hypot(dx, dy)
    a = math.atan2(dy, dx)
    part = []
    th.box(part, (0.0, -h / 2, -w / 2), (ln, h / 2, w / 2), style)
    ca, sa = math.cos(a), math.sin(a)
    xform(part, lambda p: (p[0] * ca - p[1] * sa + p0[0], p[0] * sa + p[1] * ca + p0[1], p[2]))
    faces += part


def sweep(pk, img, faces, path, w, h, ramp, sides=12, cell=3, taper=1.0):
    """A thick rounded bar swept along a curve in the XY plane: `path` is a list of (x, y) points,
    the section a rounded rectangle w across (along Z) and h thick, shrinking to `taper` of its size
    at the far end. Every facet is painted by its own normal, so the bar reads round unshaded."""
    n = len(path)
    rings = []
    for i, (x, y) in enumerate(path):
        # Tangent from the neighbours; the section's "up" is the tangent turned in the XY plane.
        pa = path[max(i - 1, 0)]
        pb = path[min(i + 1, n - 1)]
        tx, ty = pb[0] - pa[0], pb[1] - pa[1]
        tl = math.hypot(tx, ty) or 1.0
        nx, ny = -ty / tl, tx / tl
        k = 1.0 + (taper - 1.0) * i / max(n - 1, 1)
        ring = []
        for j in range(sides):
            ang = (j + 0.5) * 2 * math.pi / sides
            c, sn = math.cos(ang), math.sin(ang)
            # Superellipse: a rounded rectangle rather than an ellipse, like a cast arm.
            e = 0.5
            cu = math.copysign(abs(c) ** e, c) * h / 2 * k
            su = math.copysign(abs(sn) ** e, sn) * w / 2 * k
            ring.append((x + nx * cu, y + ny * cu, su))
        rings.append(ring)
    segs = n - 1
    x0, y0, iw, ih = pk.take(sides * cell, segs * cell)
    cells = {}
    for i in range(segs):
        for j in range(sides):
            jj = (j + 1) % sides
            q = [rings[i][j], rings[i][jj], rings[i + 1][jj], rings[i + 1][j]]
            mid = [sum(p[t] for p in q) / 4 for t in range(3)]
            cx = (path[i][0] + path[i + 1][0]) / 2
            cy = (path[i][1] + path[i + 1][1]) / 2
            out = th.norm((mid[0] - cx, mid[1] - cy, mid[2]))
            u0, v0 = x0 + j * cell, y0 + i * cell
            uv = [(u0, v0), (u0 + cell, v0), (u0 + cell, v0 + cell), (u0, v0 + cell)]
            if th.dot(th.newell(q), out) < 0:
                q, uv = list(reversed(q)), list(reversed(uv))
            f = th.Face(q, None)
            f.uv = uv
            faces.append(f)
            cells[(i, j)] = ramp_colour(ramp, th.newell(q))
    for yy in range(-th.PAD, ih + th.PAD):
        for xx in range(-th.PAD, iw + th.PAD):
            i = min(max(yy // cell, 0), segs - 1)
            j = min(max(xx // cell, 0), sides - 1)
            img.putpixel((x0 + xx, y0 + yy), th.jitter(cells[(i, j)], 1))
    # End caps.
    for ring, t in ((rings[0], path[0]), (rings[-1], path[-1])):
        other = path[1] if ring is rings[0] else path[-2]
        out = th.norm((t[0] - other[0], t[1] - other[1], 0.0))
        pts = th.outward(list(ring), (t[0] - out[0], t[1] - out[1], 0.0))
        faces.append(th.Face(pts, "dark", u_hint=(0, 0, 1)))


def bezier(p0, p1, p2, steps):
    return [((1 - t) ** 2 * p0[0] + 2 * (1 - t) * t * p1[0] + t * t * p2[0],
             (1 - t) ** 2 * p0[1] + 2 * (1 - t) * t * p1[1] + t * t * p2[1])
            for t in [k / steps for k in range(steps + 1)]]


# The riser, as TerraTech draws theirs (the reference picture): a heavy rounded MOUNT bolted under the
# hull, a THICK cast arm leaving its underside and sweeping down and out in one curve, and an ordinary
# tyre on the arm's end, the arm meeting the hub on the tyre's inner face. Two cells wide: the
# anchor is the tyre's cell (x 0) so the suspension probes from under the tyre; the bracket is the
# cell at x -1, and only its top face attaches. The arm turns about the mount's axis when steering
# and slides into the mount with the suspension, so its root starts well inside the mount.
RISER_TYRE_C = (0.15, -0.40)     # (x, y) of the tyre's centre in the anchor cell
RISER_BEARING = (-1.0, 0.37)     # (x, y) of the steering axis' top, under the hull


def build_riser(pk, img):
    parts = {"riser_mount": [], "riser_arm": []}
    mount, arm = parts["riser_mount"], parts["riser_arm"]
    bx, by = RISER_BEARING
    # Mount: a heavy chamfered body under the hull, nearly the tyre's width, a dark bearing ring
    # where the arm leaves it.
    th.prism(mount, bx - 0.40, bx + 0.40, 0.10, 0.50, 0.36, -0.36, 0.11,
             cap_front="blue", cap_back="blue", top_style="blue")
    part = []
    lathe_y(pk, img, part, [(0.20, 0.04), (0.22, 0.07), (0.22, 0.10)], METAL_RAMP, sides=12)
    for f in part:
        f.pts = [(p[0] + bx, p[1], p[2]) for p in f.pts]
    mount += part
    # Arm, about the steering axis (the node's origin) in block axes: root inside the mount, one
    # curve down and out, ending on the hub's inner face.
    tx, ty = RISER_TYRE_C
    hub_in = tx - 0.36
    p0 = (0.0, 0.28 - by)
    p1 = (0.0, ty - by)
    p2 = (hub_in - bx, ty - by)
    sweep(pk, img, arm, bezier(p0, p1, p2, 9), 0.26, 0.22, BLUE_RAMP, taper=0.85)
    # Boss: the round cap where the arm meets the hub.
    rod_x(pk, img, arm, ty - by, 0.0, 0.14, hub_in - bx - 0.02, hub_in - bx + 0.06)
    return parts


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


BLOCKS = {
    "shield": (17, build_shield, 256),
    "regen": (19, build_regen, 256),
    "radar": (23, build_radar, 256),
    "riser": (29, build_riser, 256),
    "stab": (31, build_stab, 256),
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
