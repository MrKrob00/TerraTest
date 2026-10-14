#!/usr/bin/env python3
"""THE FALSUS STABILISER (in the game) AND RISER (a draft for the player's approval): "THE ARTIST'S
OWN KIT", the player's pick of four designs ("Final_stab_a" - they liked it).

    python3 art/falsus_wheels.py
        -> objects/<name>_texture.png + art/out/<name>.glb + art/out/<name>_poses.json  (riser, stab)
    godot --headless --path <copy> --script res://art/turret_import.gd -- stab   (on a copy, CLAUDE.md 3)

The artist's wheel (Assets.glb Wheel_module / Wheel_susp_* / Wheel_Axle) is read as a machine and
re-mounted, not re-imagined: a PLATE with a slot on the joining face, a C-ARM of chamfered square
bars - an upper bar with the "+" stencil, a lower bar and an UPRIGHT between their ends, i.e. two
parallel links - and a 10-sided HUB DRUM behind the tyre. Every bar is the artist's light violet-grey
(measured off the render: sides (71,71,87), edge line (99,89,116), a dark recess on the upper bar's
top), the plate stays the artist's mesh, the tyre is the artist's small tyre, and the tyre's hub
disc is the only blue. Turned down on the way, each a rule now: thin generated arms and a bare
thick arm ("ugly without a transmission"), motor cans on the hub ("I don't like the motors"), and a
chain-case arm that read as "too strange next to the ordinary Falsus wheels".

THE TRANSMISSION IS THE ARTIST'S, MADE LEGIBLE: a third parallel link - a DRIVE SHAFT with a U-joint
collar at each end - runs between the two bars from the mount to a BEVEL BOX on the upright, and the
hub drum carries a bolted cover: power comes out of the hull, down the arm, into the hub. A shaft
parallel to the links keeps its length through the whole travel, so nothing slides.

RISER (joins by its TOP face; DRAFT): the plate under the top face, slot along Z; a HEAD hangs under
the plate's back half - the slot face the bars come out of, as the plate is on the ordinary wheel -
and the C-arm reaches out to -Z with a long upright, the drum at its foot, the tyre at the -Z side.
The upright is the kingpin: the drum and the tyre steer about it.
  riser_body    head (still)
  riser_bar_up  upper bar, about its pivot (axis X)      riser_bar_lo  lower bar, same
  riser_shaft   drive shaft, about its pivot             riser_upright upright + bevel box (translates)
  riser_knuckle hub drum + kingpin collar (translates, steers about the upright)

STABILISER (joins by its BACK face; blocks/scenes/stab_wheel.tscn, posed by stab_wheel.gd from these
very numbers - S_PU, S_PL, S_PS, S_V, S_ZK, S_K0, S_TC: change both together): the plate as on every
wheel and nothing added to it - the bars go straight into its slot - the C-arm out over the tyre to a
short upright, the steering post, and under it the knuckle: a CROWN across the tyre's top and one
LEG down its +X side to the hub drum, so the blue hub on -X stays whole. The tyre rolls along the
machine (axle X) in the middle, ride height 0.90. No still part: the plate is the artist's mesh.
  stab_bar_up / _bar_lo / _shaft / _upright      as on the riser
  stab_knuckle  steering collar, crown, leg, drum (translates, steers about the post)
"""
import json
import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import turret_heads as th  # noqa: E402
import emitter_models as em  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TYRE_R = 0.30
TYRE_W = 0.30

# ── paint: the artist's arm, measured off the small wheel's render ─────────────────────────────────
BAR = [(68, 70, 85), (71, 71, 87), (74, 69, 90), (66, 69, 82)]
BAR_LO = (59, 57, 73)
BAR_MID = (85, 79, 101)
BAR_HI = (99, 89, 116)
STENCIL = (132, 126, 150)
RECESS = [(29, 32, 38), (38, 32, 38), (33, 31, 39)]
END = (43, 41, 52)
HUB = [(50, 48, 60), (59, 57, 73), (68, 66, 82), (82, 81, 99), (92, 90, 110)]
PANEL = [(40, 43, 49), (44, 44, 53), (42, 43, 51), (47, 46, 56)]
PANEL_HI = (58, 61, 77)
PANEL_RIM = (72, 76, 96)
GROOVE = (26, 27, 33)
SHAFT = [(30, 29, 36), (38, 36, 45), (46, 44, 55), (56, 54, 66), (68, 65, 80)]


def _pick(pal):
    return pal[th.random.randint(0, len(pal) - 1)]


def _fa(style, x, y, w, h, d):
    if style == "fa_bar":
        return _pick(BAR)
    if style == "fa_low":
        return BAR_MID if d < 1.0 else th.jitter(BAR_LO, 1)
    if style == "fa_cham":
        return BAR_HI if d < 0.7 else th.jitter(BAR_MID, 1)
    if style[:8] == "fa_shaft" and style[8:].isdigit():
        # the drive shaft: darker than the bars, its facets in their own tone - it turns, they don't
        return th.jitter(SHAFT[int(style[8:])], 1)
    if style == "fa_gear":
        # a gearbox face: dark, a lit rim, one bolt in each corner
        if d < 1.0:
            return BAR_MID
        if w >= 6 and h >= 6 and (x, y) in ((2, 2), (w - 3, 2), (2, h - 3), (w - 3, h - 3)):
            return BAR_HI
        return th.jitter(END, 1)
    if style == "fa_end":
        return (74, 69, 90) if d < 1.0 else th.jitter(END, 1)
    if style == "fa_bar_top":
        # the upper bar's top: the dark recess the artist cut into its outer half
        if d >= 2.0 and w >= 12 and h >= 5 and w * 0.48 <= x < w - 3 and 2 <= y < h - 2:
            return _pick(RECESS)
        return _pick(BAR)
    if style == "fa_plus":
        # the artist's light "+" stencil near the bar's outer end (u runs out along the bar)
        if d >= 1.0 and w >= 10 and h >= 5:
            cx, cy = w - 6.0, h / 2.0
            dx, dy = abs(x + 0.5 - cx), abs(y + 0.5 - cy)
            if (dx <= 0.6 and dy <= 2.1) or (dy <= 0.6 and dx <= 2.1):
                return STENCIL
        return _pick(BAR)
    if style[:6] == "fa_hub" and style[6:].isdigit():
        # a facet of the hub drum: its own tone, a dark seam band round it near the cover
        k = int(style[6:])
        if d < 1.0:
            return HUB[min(k + 1, 4)]
        return th.jitter(HUB[k], 1)
    if style == "fa_cover":
        # the drum's end cover: dark, a lit rim, a lit ring round a boss - the bearing the hub turns in
        cx, cy = w / 2.0, h / 2.0
        R = min(w, h) / 2.0
        r = math.hypot(x + 0.5 - cx, y + 0.5 - cy)
        if d < 1.0:
            return BAR_MID
        if r < R * 0.42:
            return BAR_HI if r > R * 0.42 - 1.0 else th.jitter(BAR_LO, 1)
        return th.jitter(END, 1)
    if style in ("fa_panel", "fa_slot"):
        # the plate's language: a lit rim, a groove inside it, a diagonal brace, rivets
        if d < 1.0:
            return PANEL_RIM
        if d < 2.0:
            return (50, 52, 64)
        if style == "fa_slot":
            # the slot the bars come out of: dark, its two lips lit
            sw = max(2.0, w * 0.22)
            ax = abs(x + 0.5 - w / 2.0)
            if 3 <= y < h - 3 and ax < sw:
                return (12, 12, 16) if ax < sw - 1.0 else PANEL_HI
        if 3.0 <= d < 4.0 and min(w, h) >= 18:
            return GROOVE
        if d >= 4.0:
            if w >= 12 and h >= 12:
                for rx, ry in ((5, 5), (w - 6, 5), (5, h - 6), (w - 6, h - 6)):
                    if x == rx and y == ry:
                        return GROOVE
                    if x == rx + 1 and y == ry + 1:
                        return PANEL_RIM
            if style == "fa_panel" and abs((x + 0.5) / w - (y + 0.5) / h) * min(w, h) < 0.7:
                return PANEL_HI
        return _pick(PANEL)
    if style == "fa_pedge":
        return PANEL_RIM if d < 1.0 else th.jitter((52, 54, 66), 1)
    return None


_orig_style_px = th.style_px


def _style_px(style, x, y, w, h, d):
    if isinstance(style, str) and style.startswith("fa_"):
        c = _fa(style, x, y, w, h, d)
        if c is not None:
            return c
    return _orig_style_px(style, x, y, w, h, d)


th.style_px = _style_px


# ── geometry helpers ───────────────────────────────────────────────────────────────────────────

def _shift(faces, origin):
    for fc in faces:
        fc.pts = [th.sub(p, origin) for p in fc.pts]


def obar(faces, a, b, up, w, h, c, side="fa_bar", top="fa_bar", bottom="fa_low", cham="fa_cham",
         plus=None, cap_a="fa_end", cap_b="fa_end", bevel_b=0.0):
    """The artist's arm bar: a box from a to b, w across (along t x up) and h tall (along up), its four
    long edges chamfered by c, its outer end bevelled by bevel_b. `plus` styles the +side face."""
    t = th.norm(th.sub(b, a))
    u = th.norm(th.sub(up, th.mul(t, th.dot(up, t))))
    s = th.cross(t, u)
    sec, ch = th.octagon(-w / 2, w / 2, -h / 2, h / 2, c)

    def ring(base, q):
        return [th.add(base, th.add(th.mul(s, p[0]), th.mul(u, p[1]))) for p in q]
    bb = th.sub(b, th.mul(t, bevel_b)) if bevel_b else b
    ra, rb = ring(a, sec), ring(bb, sec)
    centre = th.mul(th.add(a, b), 0.5)
    for i in range(8):
        j = (i + 1) % 8
        if ch[i]:
            st = cham
        elif i == 4:
            st = top
        elif i == 0:
            st = bottom
        elif i == 2:
            st = plus or side
        else:
            st = side
        faces.append(th.Face(th.outward([ra[i], ra[j], rb[j], rb[i]], centre), st, u_hint=t))
    if bevel_b:
        inner, _ = th.octagon(-w / 2 + bevel_b, w / 2 - bevel_b, -h / 2 + bevel_b, h / 2 - bevel_b, c * 0.5)
        rc = ring(b, inner)
        for i in range(8):
            j = (i + 1) % 8
            faces.append(th.Face(th.outward([rb[i], rb[j], rc[j], rc[i]], centre), cham,
                                 u_hint=th.sub(rb[j], rb[i])))
        if cap_b:
            faces.append(th.Face(th.outward(rc, centre), cap_b, u_hint=s))
    elif cap_b:
        faces.append(th.Face(th.outward(rb, centre), cap_b, u_hint=s))
    if cap_a:
        faces.append(th.Face(th.outward(ra, centre), cap_a, u_hint=s))


def nprism(faces, c0, c1, r, n, kind, cap0=None, cap1=None, phase=0.5):
    """A round part as an n-sided prism from c0 to c1 (circumradius r), every facet painted in its own
    tone of the painted light: `kind` + 0..4 ("fa_hub" or the toolkit's "mtone")."""
    t = th.norm(th.sub(c1, c0))
    ref = (0, 1, 0) if abs(t[1]) < 0.9 else (1, 0, 0)
    e1 = th.norm(th.cross(ref, t))
    e2 = th.cross(t, e1)

    def ring(c):
        return [th.add(c, th.add(th.mul(e1, r * math.cos((i + phase) * 2 * math.pi / n)),
                                 th.mul(e2, r * math.sin((i + phase) * 2 * math.pi / n)))) for i in range(n)]
    r0, r1 = ring(c0), ring(c1)
    centre = th.mul(th.add(c0, c1), 0.5)
    for i in range(n):
        j = (i + 1) % n
        q = th.outward([r0[i], r0[j], r1[j], r1[i]], centre)
        nn = th.norm(th.newell(q))
        k = int(round(max(0.0, min(1.0, 0.5 + 0.5 * th.dot(nn, em.LIGHT))) * 4))
        faces.append(th.Face(q, "%s%d" % (kind, k), u_hint=t))
    if cap0:
        faces.append(th.Face(th.outward(r0, th.add(c0, t)), cap0, u_hint=e1))
    if cap1:
        faces.append(th.Face(th.outward(r1, th.sub(c1, t)), cap1, u_hint=e1))


def mount(faces, lo, hi, c, slot_face, back_face=None):
    """The block a C-arm comes out of: the plate's dark braced panel, the slot on `slot_face`
    ((nx, nz) of the face the bars leave by); `back_face` names the face against the plate (no face)."""
    tops = {"top": "fa_panel", "bottom": "fa_panel"}
    if back_face == "top":
        tops["top"] = None
    em.cham_box(faces, lo, hi, c, "fa_panel", tops["top"], tops["bottom"], "fa_pedge")
    if back_face == "back":
        faces[:] = [f for f in faces if not (f.style == "fa_panel" and th.newell(f.pts)[2] > 0.9)]
    em.restyle(faces, "fa_panel", [(slot_face, "fa_slot")])


def collar(faces, c, axis, r, half):
    """A U-joint / kingpin collar: a short 8-sided ring in the arm's metal."""
    nprism(faces, th.sub(c, th.mul(axis, half)), th.add(c, th.mul(axis, half)), r, 8, "fa_hub",
           cap0="fa_end", cap1="fa_end")


def lerp(a, b, k):
    return tuple(a[i] + (b[i] - a[i]) * k for i in range(3))


def at_z(p, v, z):
    """The point on the line p + k v whose z is z."""
    k = (z - p[2]) / v[2]
    return th.add(p, th.mul(v, k))


# ── the riser ───────────────────────────────────────────────────────────────────────────────────
# The head hangs under the plate's back half as deep as the artist's arm needs, so the C-arm comes out
# of a slotted face exactly as it does on the ordinary wheel: bars short and level, the lower bar
# landing on the hub drum, the upright between their ends.
R_HEAD = ((-0.12, -0.20, 0.10), (0.12, 0.373, 0.38))   # its foot; it flares to R_HEAD_TOP under the plate
R_HEAD_TOP = ((-0.18, 0.05), (0.18, 0.45))             # (x, z) of the flare where it meets the plate
R_PU = (0.0, 0.23, 0.25)       # pivots inside the head: upper bar, shaft, lower bar
R_PS = (0.0, 0.0525, 0.25)
R_PL = (0.0, -0.125, 0.25)
R_ZK = -0.12                   # the upright (kingpin) stands here
R_V = (0.0, -0.075, R_ZK - 0.25)   # the links: out to -Z, down 11 deg like the artist's
R_TC = (0.0, -0.43, -0.40)     # tyre middle: outer face z -0.55, bottom y -0.73
R_DRUM = (-0.28, -0.11, 0.18)  # the drum: z from, z to, radius (the artist's is 0.2: it covers the hub's back)
R_K0 = (0.0, R_TC[1], R_ZK)    # the knuckle turns about the upright's line


def arm(P, prefix, PU, PS, PL, V, ZK, face_z, y_foot):
    """The artist's C-arm out of a slotted face at face_z: upper bar (bevelled, the "+"), lower bar,
    the drive shaft between them with its U-joint collars, and the upright from under the upper bar's
    end down to y_foot, with the bevel box the shaft drives into."""
    U1 = at_z(PU, V, ZK)
    S1 = at_z(PS, V, ZK)
    bu = P[prefix + "_bar_up"]
    obar(bu, at_z(PU, V, face_z + 0.04), at_z(PU, V, ZK - 0.08), (0, 1, 0), 0.15, 0.14, 0.012,
         top="fa_bar_top", plus="fa_plus", cap_a=None, bevel_b=0.022)
    _shift(bu, PU)
    bl = P[prefix + "_bar_lo"]
    obar(bl, at_z(PL, V, face_z + 0.04), at_z(PL, V, ZK - 0.065), (0, 1, 0), 0.14, 0.12, 0.012, cap_a=None)
    _shift(bl, PL)
    sh = P[prefix + "_shaft"]
    t = th.norm(V)
    nprism(sh, at_z(PS, V, face_z + 0.03), at_z(PS, V, ZK + 0.07), 0.028, 8, "fa_shaft")
    collar(sh, at_z(PS, V, face_z - 0.018), t, 0.045, 0.02)
    collar(sh, at_z(PS, V, ZK + 0.088), t, 0.045, 0.02)
    _shift(sh, PS)
    up = P[prefix + "_upright"]
    obar(up, (0.0, U1[1] - 0.03, ZK), (0.0, y_foot, ZK), (0, 0, -1), 0.10, 0.09, 0.012,
         side="fa_bar", top="fa_bar", bottom="fa_bar", cap_a=None, cap_b=None)
    obar(up, (0.0, S1[1], ZK + 0.035), (0.0, S1[1], ZK + 0.105), (0, 1, 0), 0.11, 0.11, 0.014,
         side="fa_gear", top="fa_gear", bottom="fa_gear", cap_a=None, cap_b="fa_gear")
    _shift(up, (0.0, S1[1], ZK))


def hanger(f):
    """The riser's head: a slotted block hanging under the plate, flaring out where it is bolted on -
    the plate's dark braced panel on its sides, the slot on its -Z face."""
    (x0, y0, z0), (x1, y1, z1) = R_HEAD
    (tx0, tz0), (tx1, tz1) = R_HEAD_TOP
    yf = y1 - 0.12                     # where the flare starts
    lo = em.crect(x0, x1, z0, z1, 0.04, y0)
    mid = em.crect(x0, x1, z0, z1, 0.04, yf)
    top = em.crect(tx0, tx1, tz0, tz1, 0.06, y1)
    em.frustum(f, lo, mid, "fa_panel", "fa_pedge", None)
    em.frustum(f, mid, top, "fa_pedge", "fa_pedge", None)
    f.append(th.Face(th.outward(list(lo), (0.0, y0 + 1.0, (z0 + z1) / 2)), "fa_panel", u_hint=(1, 0, 0)))
    em.restyle(f, "fa_panel", [((0, -1), "fa_slot")])


def build_riser(pk, img):
    P = {k: [] for k in ("riser_body", "riser_bar_up", "riser_bar_lo", "riser_shaft",
                         "riser_upright", "riser_knuckle")}
    hanger(P["riser_body"])
    z0, z1, r = R_DRUM
    arm(P, "riser", R_PU, R_PS, R_PL, R_V, R_ZK, R_HEAD[0][2], R_TC[1] + r * 0.9)
    # knuckle: the hub drum behind the tyre and its cover - the final drive the hub turns in
    kn = P["riser_knuckle"]
    nprism(kn, (0.0, R_TC[1], z0), (0.0, R_TC[1], z1), r, 10, "fa_hub", cap1="fa_cover", phase=0.0)
    _shift(kn, R_K0)
    return P


# ── the stabiliser ──────────────────────────────────────────────────────────────────────────────
# No bracket: the bars go straight into the plate's slot, as on the ordinary wheel. The C-arm stands
# over the tyre; its upright is the steering post, and the knuckle under it is a CROWN across the
# tyre's top and one LEG down its +X side to the drum - single-sided, so the blue hub on -X is whole.
S_PU = (0.0, 0.28, 0.44)       # pivots in the plate's slot
S_PS = (0.0, 0.12, 0.44)
S_PL = (0.0, -0.04, 0.44)
S_ZK = -0.02                   # the steering post
S_V = (0.0, -0.08, S_ZK - 0.44)
S_TC = (0.0, -0.60, S_ZK)      # tyre middle: ride height 0.90, under the post
S_CROWN_Y = (-0.285, -0.185)
S_LEG_X = 0.21
S_DRUM = (0.115, 0.255, 0.20)  # x from, x to, radius
S_K0 = (0.0, S_CROWN_Y[1], S_ZK)   # the knuckle's origin: on the post, at the crown's top


def build_stab(pk, img):
    P = {k: [] for k in ("stab_bar_up", "stab_bar_lo", "stab_shaft", "stab_upright",
                         "stab_knuckle")}
    arm(P, "stab", S_PU, S_PS, S_PL, S_V, S_ZK, 0.373, S_CROWN_Y[1] + 0.03)
    kn = P["stab_knuckle"]
    collar(kn, (0.0, S_CROWN_Y[1] + 0.02, S_ZK), (0, 1, 0), 0.07, 0.02)   # the steering joint
    cy = (S_CROWN_Y[0] + S_CROWN_Y[1]) / 2
    ch = S_CROWN_Y[1] - S_CROWN_Y[0]
    x0, x1, r = S_DRUM
    obar(kn, (-0.11, cy, S_ZK), (S_LEG_X + 0.06, cy, S_ZK), (0, 1, 0), 0.13, ch, 0.012,
         top="fa_bar_top", bottom="fa_low", bevel_b=0.02)
    obar(kn, (S_LEG_X, S_CROWN_Y[0] + 0.01, S_ZK), (S_LEG_X, S_TC[1] + r * 0.85, S_ZK), (0, 0, -1), 0.10, 0.10,
         0.012, side="fa_bar", top="fa_bar", bottom="fa_bar", cap_a=None, cap_b=None)
    nprism(kn, (x0, S_TC[1], S_ZK), (x1, S_TC[1], S_ZK), r, 10, "fa_hub", cap1="fa_cover", phase=0.0)
    _shift(kn, S_K0)
    return P


em.BLOCKS["riser"] = (441, build_riser, 256)
em.BLOCKS["stab"] = (443, build_stab, 256)
if not hasattr(em, "CHECKS"):
    em.CHECKS = {}
em.CHECKS["riser"] = {
    "cells": ((-0.5, -0.75, -0.6), (0.5, 0.5, 0.5)), "budget": 350,
    "origins": {"riser_bar_up": R_PU, "riser_bar_lo": R_PL, "riser_shaft": R_PS,
                "riser_upright": (0.0, at_z(R_PS, R_V, R_ZK)[1], R_ZK), "riser_knuckle": R_K0},
    "spin": {"riser_knuckle": (0, 1, 0)},
    "solid": [R_HEAD]}
em.CHECKS["stab"] = {
    "cells": ((-0.5, -0.95, -0.55), (0.5, 0.5, 0.5)), "budget": 350,
    "origins": {"stab_bar_up": S_PU, "stab_bar_lo": S_PL, "stab_shaft": S_PS,
                "stab_upright": (0.0, at_z(S_PS, S_V, S_ZK)[1], S_ZK), "stab_knuckle": S_K0},
    "spin": {"stab_knuckle": (0, 1, 0)}}


# ── poses (the arithmetic of art/wheel_poses.py) ────────────────────────────────────────────────
PLATE = "@res://blocks/scenes/small_wheel.tscn|Wheel_module_small"
TYRE = ("@res://blocks/scenes/small_wheel.tscn|Wheel_module_small/Wheel_susp_high/Wheel_susp_low/"
        "Wheel_susp_mid/Wheel_Axle/wheel")


def rx(a):
    c, s = math.cos(a), math.sin(a)
    return [[1, 0, 0], [0, c, -s], [0, s, c]]


def ry(a):
    c, s = math.cos(a), math.sin(a)
    return [[c, 0, s], [0, 1, 0], [-s, 0, c]]


def mul(A, B):
    return [[sum(A[i][k] * B[k][j] for k in range(3)) for j in range(3)] for i in range(3)]


def app(A, v):
    return [sum(A[i][k] * v[k] for k in range(3)) for i in range(3)]


def add(a, b):
    return [a[i] + b[i] for i in range(3)]


def sub(a, b):
    return [a[i] - b[i] for i in range(3)]


def tf(B, o):
    """Godot Transform3D order: basis columns x, y, z, then origin."""
    return [B[0][0], B[1][0], B[2][0], B[0][1], B[1][1], B[2][1], B[0][2], B[1][2], B[2][2], o[0], o[1], o[2]]


I3 = [[1, 0, 0], [0, 1, 0], [0, 0, 1]]


def swing_x(v, sag):
    """The turn about X that lifts the far end of the link vector v by `sag` (bisection, the branch
    near zero)."""
    lo, hi = -1.2, 1.2
    f = lambda a: app(rx(a), v)[1] - v[1] - sag
    if f(lo) > f(hi):
        lo, hi = hi, lo
    for _ in range(60):
        m = (lo + hi) / 2
        if f(m) < 0:
            lo = m
        else:
            hi = m
    return rx((lo + hi) / 2)


def arm_pose(prefix, PU, PL, PS, V, up0, K0, sag, steer):
    S = swing_x(list(V), sag)
    T = sub(app(S, list(V)), list(V))
    R = ry(steer)
    out = {prefix + "_body": tf(I3, [0, 0, 0]),
           prefix + "_bar_up": tf(S, list(PU)), prefix + "_bar_lo": tf(S, list(PL)),
           prefix + "_shaft": tf(S, list(PS)),
           prefix + "_upright": tf(I3, add(list(up0), T)),
           prefix + "_knuckle": tf(R, add(list(K0), T))}
    return out, R, T


def riser_pose(sag, steer, spin=0.0):
    up0 = (0.0, at_z(R_PS, R_V, R_ZK)[1], R_ZK)
    out, R, T = arm_pose("riser", R_PU, R_PL, R_PS, R_V, up0, R_K0, sag, steer)
    K = add(list(R_K0), T)
    tc = add(K, app(R, sub(list(R_TC), list(R_K0))))
    # plate under the top face, its slot turned along Z (the plane the arm swings in)
    out[PLATE] = [0, 0, 1, 0, -1, 0, 1, 0, 0, 0, 0.5, 0]
    B = mul(R, mul([[0, 0, -1], [0, 1, 0], [1, 0, 0]], rx(spin)))
    out[TYRE + "#"] = tf(B, add(tc, app(R, [0, 0, TYRE_W / 2])))
    out["_ground"] = tc[1] - TYRE_R
    return out


def stab_pose(sag, steer, spin=0.0):
    up0 = (0.0, at_z(S_PS, S_V, S_ZK)[1], S_ZK)
    out, R, T = arm_pose("stab", S_PU, S_PL, S_PS, S_V, up0, S_K0, sag, steer)
    K = add(list(S_K0), T)
    tc = add(K, app(R, sub(list(S_TC), list(S_K0))))
    out[PLATE] = [0, -1, 0, 0, 0, -1, 1, 0, 0, 0, 0, 0.5]
    B = mul(R, rx(spin))
    out[TYRE + "#"] = tf(B, add(tc, app(R, [TYRE_W / 2, 0, 0])))
    out["_ground"] = tc[1] - TYRE_R
    return out


STATES = [("rest", 0.0, 0.0), ("steer", 0.0, math.radians(25)), ("up", 0.18, 0.0), ("down", -0.14, 0.0)]


if __name__ == "__main__":
    for nm, fn in (("riser", riser_pose), ("stab", stab_pose)):
        em.make(nm)
        with open(os.path.join(ROOT, "art", "out", nm + "_poses.json"), "w") as fh:
            json.dump({st: fn(sag, steer) for st, sag, steer in STATES}, fh)
        print("wrote", nm + "_poses.json")
