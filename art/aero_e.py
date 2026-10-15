#!/usr/bin/env python3
"""AERO DRAFT e - THE FAIRED WHEEL: the light wheel's corner under an aerodynamic cycle wing.

    python3 art/aero_e.py          -> aero_e_wheel (rest/steer/up/down), aero_e_rig, aero_e_rig2
    python3 art/aero_e.py check    -> only the pose checks (cell, clashes, tyre clearance)

The light wheel (art/aero_wheels.py, `aero_wheel`, in the game) is the family: this wheel stands on
the SAME tyre and rim (its very faces, painted by its very painter), and on the same white mount
plate, aerofoil A-arms, drive shaft and orange coil-over at the same pick-up points, cut to fewer
faces, posed by the light wheel's own arithmetic - so the two corners move alike and line up on one
machine. What is new is the FENDER, and it rides on the upright: it steers with the tyre and travels
with it, so its clearance to the tyre never changes and nothing has to make room for a steered tyre.

THE FENDER is a fore-and-aft symmetric aerofoil body (the wheel is turned +-90 deg, so either end
leads) in three parts that carry the faction's three colours as pieces, not paint:
  - the BLUE BLADE: a long low lens laid over the tyre, its planform pointed both ways, its section a
    low roof with a razor crest; over the tyre's crown it is open in a bay of LOUVRES (the tread shows
    through them, as through a Le Mans car's arch vents);
  - the ORANGE TIPS: knife points that carry the blade's lines on past the tyre, fore and aft;
  - the WHITE CHEEK: a strake set in under the blade's outboard edge (the blue overhangs a shadow
    line), its face undercut toward a keel that is flat over the crown and sweeps up into the tips,
    with an orange pinstripe on the keel and two brake-cooling gills at each end.
Underneath is carbon. It is held by the UPRIGHT ITSELF, carried up in its own blue: a post on its
outboard face inside the rim, a blade inboard over the upper ball joint through the rim's bore, and
up past the tyre's inner wall into the blade. Tried and dropped in this draft's own rounds (not the
player's verdicts): a crescent fender that followed the tyre (an arch again), a deep creased cheek
(read as a white bun), a bare blade with no cheek (too slight for the faction's FAIRED wheel).

Parts (pivot):
  aero_e_wheel_mount     still: plate, clevises, the shaft's housing, the coil-over's turret
  aero_e_wheel_arm_up    upper A-arm (its pivot line, axis X)      aero_e_wheel_arm_lo  lower A-arm
  aero_e_wheel_shaft     drive shaft with CV boots (the third parallel link)
  aero_e_wheel_dmp_body  coil-over body + spring (its top eye)     aero_e_wheel_dmp_rod its rod (the eye)
  aero_e_wheel_knuckle   upright, hub, the fender's stay: on the kingpin, steers about Y
  aero_e_wheel_fender    the fender: same pivot and pose as the knuckle (it steers +-25 deg, never a
                         full turn, so model_check does not spin it; the pose check below covers it)
  aero_e_wheel_tyre      the light wheel's tyre and rim: spins about Z, steers with the knuckle
"""
import math
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import aero_kit as ak  # noqa: E402
import turret_heads as th  # noqa: E402
import emitter_models as em  # noqa: E402
import aero_wheels as aw  # noqa: E402   the light wheel: its tyre, layout and painter
import aero_b  # noqa: E402,F401          the round-one B block, for the rigs

# ── the light wheel's layout, taken as it is ────────────────────────────────────────────────────
TR, TW, RIDE, YC, ZC, RIM = aw.TR, aw.TW, aw.RIDE, aw.YC, aw.ZC, aw.RIM
K0, HB, V, PU, PL, PS = aw.K0, aw.HB, aw.V, aw.PU, aw.PL, aw.PS
LEG_X, MOUNT, MZ, DT = aw.LEG_X, aw.MOUNT, aw.MZ, aw.DT
EYE = aw._eye()

BLUE, WHITE, ORANGE = ak.BLUE, ak.WHITE, ak.ORANGE
BLUE_DK = (10, 112, 160)
BLUE_LO = (8, 80, 120)
BLUE_HI = (128, 218, 248)
WHITE_LO = (196, 202, 214)
EDGE = (128, 138, 156)
ORANGE_DK = (176, 62, 10)
ORANGE_HI = (255, 172, 100)
GLINT = (255, 255, 255)
GAP = (12, 12, 16)

N = "aero_e_wheel_"


def T(u, v, w):
    """Tyre-relative (u along the travel, v up from the axle, w along the axle, + inboard) -> block."""
    return (u, YC + v, ZC + w)


def cen(pts):
    return th.mul(tuple(map(sum, zip(*pts))), 1.0 / len(pts))


def quad(faces, pts, out, style, u_hint=(1, 0, 0)):
    """A quad facing along `out` (a loft quad may twist a little between stations: it is painted on
    its mean plane, one tone, which is what keeps a facet a facet)."""
    ak.face(faces, list(pts), th.sub(cen(pts), th.mul(th.norm(out), 0.05)), style, u_hint=u_hint)


def loft(faces, stations, styles, skip=()):
    """Stations [(u, [(w, v), ...]), ...]: the same CCW section (w right, v up) at each u. styles is
    one style per section edge (None leaves that strip out); edges in `skip` are left out too."""
    for k in range(len(stations) - 1):
        (u0, s0), (u1, s1) = stations[k], stations[k + 1]
        m = len(s0)
        for i in range(m):
            st = styles[i]
            if not st or i in skip:
                continue
            j = (i + 1) % m
            dw, dv = s0[j][0] - s0[i][0], s0[j][1] - s0[i][1]
            out = (0.0, -dw, dv)                  # the edge's outward normal in the section plane
            pts = [T(u0, s0[i][1], s0[i][0]), T(u0, s0[j][1], s0[j][0]),
                   T(u1, s1[j][1], s1[j][0]), T(u1, s1[i][1], s1[i][0])]
            quad(faces, pts, out, st)


def cap(faces, u, sec, facing, style):
    """A station's section as a face facing +u (facing=1) or -u."""
    pts = [T(u, v, w) for w, v in sec]
    for tri in ak.ear_clip([(w, v) for w, v in sec]):
        tp = [pts[i] for i in tri]
        ak.face(faces, tp, th.sub(cen(tp), (0.05 * facing, 0, 0)), style, u_hint=(0, 0, 1))


def mirror_u(stations):
    return [(-u, s) for u, s in reversed(stations)]


# ═════════════════════════════════════════════════════════════════════════════════════════════════
# THE FENDER
# ═════════════════════════════════════════════════════════════════════════════════════════════════
# THE BLADE (blue): u, outboard half-width, inboard half-width, underside, crest. A long low lens
# laid over the tyre, its tips well past it; the half-widths are what 25 deg of steer leaves in the
# cell (|u| sin 25 + w_out cos 25 <= 0.30 outboard of the kingpin).
BLADE = [(0.11, 0.205, 0.190, 0.462, 0.535),
         (0.27, 0.165, 0.148, 0.440, 0.508),
         (0.38, 0.112, 0.098, 0.408, 0.462)]
BAY = BLADE[0][0]                  # the louvre bay spans |u| < BAY
LOUVRES = 4
# THE TIPS (orange): from inside the blade's end to a knife point past the tyre
TIPS = [(0.375, 0.104, 0.090, 0.414, 0.454),
        (0.490, 0.006, 0.006, 0.398, 0.405)]
# THE CHEEK (white): a strake under the blade's outboard edge, set in under it so the blue overhangs a
# shadow line, its face slanted in toward its keel (an undercut, as a sidepod's); the keel line is flat
# over the tyre's crown and sweeps up into the tips (u, keel v), clear of the tyre by TYRE_GAP_MIN
CHEEK = [(0.0, 0.345), (0.11, 0.349), (0.27, 0.358), (0.375, 0.362), (0.44, 0.394)]
CHEEK_IN = 0.008                   # its top, set in under the blade's edge
CHEEK_T = 0.016                    # its thickness
TUCK = 0.014                       # the keel stands this much further in than the top
GILLS = (0.25, 0.29)               # brake-cooling gills in the cheek, |u| of each


def blade_sec(wo, wi, vb, vt):
    """CCW: outboard foot, inboard foot, inboard edge, inboard shoulder, crest, outboard shoulder,
    outboard edge. The crest stands a little outboard of the middle: the side the camera sees is the
    long slope."""
    return [(-wo, vb), (wi, vb), (wi, vb + 0.020), (0.42 * wi, vt - 0.014), (-0.16 * wo, vt),
            (-0.60 * wo, vt - 0.026), (-wo, vb + 0.030)]


def tip_sec(wo, wi, vb, vt):
    return [(-wo, vb), (wi, vb), (wi, vb + 0.014), (-0.16 * wo, vt), (-wo, vb + 0.02)]


def _lerp_rows(rows, u):
    """Rows (u, a, b, ...): linear in |u| between rows, held flat before the first."""
    u = abs(u)
    if u <= rows[0][0]:
        return rows[0][1:]
    for r0, r1 in zip(rows, rows[1:]):
        if r0[0] <= u <= r1[0]:
            t = (u - r0[0]) / (r1[0] - r0[0])
            return tuple(r0[i] + (r1[i] - r0[i]) * t for i in range(1, len(r0)))
    return rows[-1][1:]


def edge_at(u):
    """The fender's outboard edge and underside at |u| (blade, then tip): (wo, vb)."""
    if abs(u) <= BLADE[-1][0]:
        wo, wi, vb, vt = _lerp_rows(BLADE, u)
    else:
        wo, wi, vb, vt = _lerp_rows(TIPS, u)
    return wo, vb


def build_fender(f):
    secs = [(u, blade_sec(wo, wi, vb, vt)) for u, wo, wi, vb, vt in BLADE]
    sty = ["f_under", "f_edge_in", "f_shell", "f_shell", "f_shell", "f_shell", "f_edge_out"]
    for side in (1, -1):
        st = [(side * u, s) for u, s in secs]
        loft(f, st if side > 0 else list(reversed(st)), sty)
        # the blade's end, where the orange tip comes out of it: a blue rim round the tip
        cap(f, side * BLADE[-1][0], secs[-1][1], side, "f_cap")
    # ── the louvre bay: the crest is open between the shoulders; two rails carry the blade's edges,
    # the bay's end walls close it and blades stand across the opening
    s = secs[0][1]
    wa, wb = s[5][0], s[3][0]                      # outboard and inboard shoulder
    va, vb_, vt, vbot = s[5][1], s[3][1], s[4][1], s[0][1]
    rail_out = [s[0], (wa, vbot), s[5], s[6]]      # CCW: foot, under the shoulder, shoulder, edge
    rail_in = [(wb, vbot), s[1], s[2], s[3]]
    loft(f, [(-BAY, rail_out), (BAY, rail_out)], ["f_under", "f_wall", "f_shell", "f_edge_out"])
    loft(f, [(-BAY, rail_in), (BAY, rail_in)], ["f_under", "f_edge_in", "f_shell", "f_wall"])
    end = [(wa, vbot), (wb, vbot), s[3], s[4], s[5]]
    for side in (1, -1):
        cap(f, side * BAY, end, -side, "f_wall")
    for i in range(LOUVRES):
        u = -BAY + 2 * BAY * (i + 0.5) / LOUVRES
        vt_ = min(va, vb_) - 0.010
        quad(f, [T(u, vt_, wa), T(u, vt_, wb), T(u, vt_ - 0.04, wb), T(u, vt_ - 0.04, wa)], (1, 0, 0), "f_slat",
             u_hint=(0, 0, 1))
    # ── the orange knife tips, fore and aft
    tsecs = [(u, tip_sec(wo, wi, vb, vt)) for u, wo, wi, vb, vt in TIPS]
    tsty = ["f_tip_under", "f_tip", "f_tip", "f_tip", "f_tip"]
    for side in (1, -1):
        st = [(side * u, s2) for u, s2 in tsecs]
        loft(f, st if side > 0 else list(reversed(st)), tsty)
    # ── the white cheek under the blade's outboard edge
    rows = []
    for u, vlo in CHEEK:
        wo, vb = edge_at(u)
        rows.append((u, cheek_sec(wo - CHEEK_IN, vb, vlo)))
    st = mirror_u(rows[1:]) + rows
    loft(f, st, ["f_cheek_low", "f_cheek_in", None, "f_cheek"])
    for side in (1, -1):
        cap(f, side * CHEEK[-1][0], rows[-1][1], side, "f_cheek")


def cheek_sec(o, vb, vlo):
    """CCW: keel outside, keel inside, top inside, top outside (under the blade)."""
    return [(-(o - TUCK), vlo), (-(o - TUCK - CHEEK_T), vlo), (-(o - CHEEK_T), vb + 0.004), (-o, vb + 0.004)]


# ═════════════════════════════════════════════════════════════════════════════════════════════════
# THE MECHANISM: the light wheel's, at its pick-up points, cut to fewer faces; painted by its painter
# ═════════════════════════════════════════════════════════════════════════════════════════════════
def diamond(w, h):
    """A thin blade section: w across, h along the bar's `up`."""
    return [(-w / 2, 0.0), (0.0, -h / 2), (w / 2, 0.0), (0.0, h / 2)]


def build_mount(m):
    aw.cham_prism(m, MOUNT, MZ[0], MZ[1], ak.C, "plate", "pl_back", "pl_side", "ch")
    for sx in (-1, 1):
        for py in (PU[1], PL[1]):
            th.box(m, (sx * LEG_X - 0.04, py - 0.03, 0.335), (sx * LEG_X + 0.04, py + 0.03, 0.40), "brk",
                   skip=("+z",))
    aw.prism(m, (0.0, PS[1], 0.40), (0.0, PS[1], 0.345), 0.052, 8, "hous", cap1="hous_cap", ref=(0, 1, 0))
    th.box(m, (-0.045, DT[1] - 0.05, 0.33), (0.045, DT[1] + 0.04, 0.40), "brk", skip=("+z",))


def build_arm(a, piv, upper):
    bj = th.add(piv, V)
    for sx in (-1, 1):
        ia = (sx * LEG_X, piv[1], piv[2])
        ob = th.add(bj, (sx * 0.028, 0.0, 0.02))
        aw.section_bar(a, th.add(ia, (0, 0, -0.01)), ob, aw.lens(0.088, 0.036), (0, 1, 0), "arm")
    # one pivot tube through both clevises
    aw.prism(a, (-LEG_X - 0.06, piv[1], piv[2]), (LEG_X + 0.06, piv[1], piv[2]), 0.022, 8, "bush",
             ref=(0, 1, 0), phase=0.0)
    aw.prism(a, th.add(bj, (0, -0.03, 0)), th.add(bj, (0, 0.03, 0)), 0.036, 8, "bj", ref=(1, 0, 0))
    if upper:
        w = LEG_X * (1 - aw.F_EYE) + 0.03
        th.box(a, (EYE[0] - w, EYE[1] - 0.016, EYE[2] - 0.025), (EYE[0] + w, EYE[1] + 0.016, EYE[2] + 0.025),
               "arm")


def build_shaft(s):
    so = th.add(PS, V)
    t = th.norm(V)
    aw.prism(s, th.add(PS, th.mul(t, -0.01)), th.sub(so, th.mul(t, 0.07)), 0.020, 8, "shaft", ref=(1, 0, 0))
    aw.prism(s, th.add(PS, th.mul(t, -0.012)), th.add(PS, th.mul(t, 0.075)), 0.046, 8, "boot",
             r1=0.024, ref=(1, 0, 0))
    aw.prism(s, th.sub(so, th.mul(t, 0.15)), th.sub(so, th.mul(t, 0.065)), 0.024, 8, "boot",
             r1=0.044, ref=(1, 0, 0))


def build_damper(body, rod):
    dirn = th.norm(th.sub(EYE, DT))
    L = math.sqrt(sum((EYE[i] - DT[i]) ** 2 for i in range(3)))
    aw.prism(body, DT, th.add(DT, th.mul(dirn, 0.05)), 0.026, 8, "dmp_top", ref=(1, 0, 0))
    aw.prism(body, th.add(DT, th.mul(dirn, 0.05)), th.add(DT, th.mul(dirn, L * 0.62)), 0.042, 8, "spring",
             cap0="dmp_cap", cap1="dmp_cap", ref=(1, 0, 0))
    aw.prism(rod, EYE, th.sub(EYE, th.mul(dirn, L * 0.72)), 0.013, 6, "rod", ref=(1, 0, 0))
    aw.prism(rod, (EYE[0] - 0.035, EYE[1], EYE[2]), (EYE[0] + 0.035, EYE[1], EYE[2]), 0.022, 8, "bush",
             ref=(0, 1, 0))


# the swan neck: up the upright inside the rim, inboard over the upper ball joint through the rim's
# bore, then up past the tyre's inner wall to the shell's inboard edge
NECK = [(0.0, 0.262, -0.056), (0.0, 0.262, 0.146), (0.0, 0.312, 0.166), (0.0, 0.425, 0.166)]
NECK_SEC = diamond(0.026, 0.09)


def build_knuckle(k):
    th.box(k, (-0.040, YC - HB + 0.025, ZC - 0.03), (0.040, YC + HB - 0.025, ZC + 0.045), "upr")
    aw.prism(k, (0.0, YC, ZC - 0.03), (0.0, YC, ZC - 0.068), 0.040, 8, "hub", ref=(0, 1, 0))
    # the post on the upright's outboard face, clear of the upper ball joint
    th.box(k, (-0.032, YC + 0.09, ZC - 0.068), (0.032, YC + 0.262 + 0.012, ZC - 0.044), "neck_post")
    # the blade: a thin aerofoil, its chord along the travel
    pts = [T(u, v, w) for u, v, w in NECK]
    ends = [(th.add(pts[0], (0, 0, -0.012)), pts[1]), (pts[1], pts[2]), (pts[2], th.add(pts[3], (0, 0.045, 0)))]
    for a, b in ends:
        aw.section_bar(k, a, b, NECK_SEC, (1, 0, 0), "neck")


def build_tyre():
    P, _ = aw.build_wheel()
    return P["aero_wheel_tyre"]


ORIGINS = {N + "mount": (0.0, 0.0, 0.0), N + "arm_up": PU, N + "arm_lo": PL, N + "shaft": PS,
           N + "dmp_body": DT, N + "dmp_rod": EYE, N + "knuckle": K0, N + "fender": K0, N + "tyre": K0}


def build_wheel():
    P = {k: [] for k in ORIGINS}
    build_mount(P[N + "mount"])
    build_arm(P[N + "arm_up"], PU, True)
    build_arm(P[N + "arm_lo"], PL, False)
    build_shaft(P[N + "shaft"])
    build_damper(P[N + "dmp_body"], P[N + "dmp_rod"])
    build_knuckle(P[N + "knuckle"])
    build_fender(P[N + "fender"])
    P[N + "tyre"] = build_tyre()
    return P, dict(ORIGINS)


# ═════════════════════════════════════════════════════════════════════════════════════════════════
# PAINT
# ═════════════════════════════════════════════════════════════════════════════════════════════════
AW_PART = {N + "mount": "aero_wheel_mount", N + "arm_up": "aero_wheel_arm_up", N + "arm_lo": "aero_wheel_arm_lo",
           N + "shaft": "aero_wheel_shaft", N + "dmp_body": "aero_wheel_dmp_body",
           N + "dmp_rod": "aero_wheel_dmp_rod", N + "knuckle": "aero_wheel_knuckle", N + "tyre": "aero_wheel_tyre"}


PX = 1.0 / ak.DENS


def _blade_row(u):
    return BLADE[0][1:] if abs(u) <= BAY else _lerp_rows(BLADE, u)


def paint(style, P, n, d, part, o):
    if not style.startswith(("f_", "neck")):
        return aw.paint_wheel(style, P, n, d, AW_PART.get(part, part), o)
    k = ak.lit(n)
    up = n[1]
    u, v, w = P[0], P[1] - YC, P[2] - ZC          # tyre-relative, at rest
    if style == "f_shell":
        sec = blade_sec(*_blade_row(u))
        if abs(w - sec[4][0]) < 0.6 * PX and up > 0.3:
            return ak.tone(GLINT, k)                                  # the crest: a razor glint
        if abs(abs(u) - BLADE[1][0]) < 0.5 * PX:
            return ak.tone(BLUE_DK, k)                                # a panel seam across the flow
        return ak.jitter(ak.tone(BLUE, k), 1)
    if style in ("f_edge_out", "f_edge_in"):
        wo, wi, vb, vt = _blade_row(u)
        top = vb + (0.030 if style == "f_edge_out" else 0.020)
        if top - v < PX:
            return ak.tone(BLUE_HI, k)                                # the lip catches the light
        if v - vb < PX:
            return ak.tone(BLUE_LO, k)
        return ak.tone(BLUE_DK, k)
    if style == "f_cap":
        return ak.tone(BLUE_LO if d >= 1.0 else BLUE_DK, k)
    if style == "f_under":
        return ak.carbon(P, n, k * 0.85)
    if style == "f_wall":
        return ak.tone(GAP, 1.0) if d >= 1.0 else ak.tone((40, 42, 52), k)
    if style == "f_slat":
        sec = blade_sec(*BLADE[0][1:])
        top = min(sec[5][1], sec[3][1]) - 0.010
        if top - v < PX:
            return ak.tone(GLINT, 1.0)
        return ak.tone(WHITE_LO, 0.78)                                # white blades in the dark bay
    if style == "f_tip":
        wo, wi, vb, vt = _lerp_rows(TIPS, u)
        if abs(w + 0.16 * wo) < PX and up > 0.3:
            return ak.tone(ak.mix(ORANGE_HI, GLINT, 0.4), k)          # the crest runs on into the tip
        if v - vb < 0.024 and up < 0.3:
            return ak.tone(ORANGE_DK, k)
        return ak.jitter(ak.tone(ORANGE, k), 1)
    if style == "f_tip_under":
        return ak.tone(ORANGE_DK, k * 0.9)
    if style == "f_cheek":
        vlo = _lerp_rows(CHEEK, u)[0]
        wo, vb = edge_at(u)
        if v - vlo < PX:
            return ak.tone(ORANGE, k)                                 # the keel's pinstripe
        if vb - v < 0.018:
            return ak.tone(WHITE_LO, k * 0.80)                        # in the blade's shadow
        # brake-cooling gills toward both ends: dark slots raked with the keel's sweep
        h = vb - vlo
        t = (v - vlo) / h
        if 0.30 < t < 0.76:
            for g in GILLS:
                du = abs(u) - g
                if abs(du) < 0.5 * PX:
                    return ak.tone(GAP, 1.0)
                if 0.5 * PX <= du < 1.5 * PX:
                    return ak.tone(WHITE_LO, k * 0.85)                # the slot's far wall
        return ak.jitter(ak.tone(WHITE, k), 1)
    if style == "f_cheek_low":
        return ak.tone(WHITE_LO, k * 0.85)
    if style == "f_cheek_in":
        return ak.carbon(P, n, k * 0.85)
    if style in ("neck", "neck_post"):
        # the upright's own blue, carried up to the fender: what holds the fender reads as the upright
        if d < 0.8:
            return ak.tone(ak.mix(BLUE, GLINT, 0.45), aw.facet(n))
        return ak.tone(BLUE if style == "neck" else BLUE_DK, aw.facet(n))
    return (255, 0, 255)


ak.model("aero_e_wheel", 5150, build_wheel, paint, tex=512)
em.CHECKS["aero_e_wheel"] = {
    "cells": ((-0.5, -RIDE, -0.5), (0.5, 0.5, 0.5)), "budget": 900,
    "origins": {k: v for k, v in ORIGINS.items() if k != N + "mount"},
    "spin": {N + "tyre": (0, 0, 1), N + "knuckle": (0, 1, 0)}}


# ═════════════════════════════════════════════════════════════════════════════════════════════════
# POSES: the light wheel's own arithmetic (aw.wheel_pose), so both corners move alike
# ═════════════════════════════════════════════════════════════════════════════════════════════════
def pose(sag, steer):
    p = aw.wheel_pose(sag, steer)
    out = {}
    for mine, theirs in AW_PART.items():
        out[mine] = p[theirs]
    out[N + "fender"] = p["aero_wheel_knuckle"]
    return out


STATES = {"rest": (0.0, 0.0), "steer": (0.0, math.radians(25)), "up": (0.14, 0.0), "down": (-0.14, 0.0)}


def wheel_states():
    st = {}
    for nm, (sag, steer) in STATES.items():
        p = pose(sag, steer)
        p["_ground"] = -RIDE + sag
        p["_centre"] = [0.0, -0.2, 0.0]
        st[nm] = p
    return st


# ── the checks: every vertex in the cell at every pose (both steer directions), and no two parts
# that do not share a joint passing through each other ─────────────────────────────────────────
def _posed(parts, origins, p):
    out = {}
    for part, faces in parts.items():
        t = p[part]
        Bm = np.array([[t[0], t[3], t[6]], [t[1], t[4], t[7]], [t[2], t[5], t[8]]])
        o = np.array(origins.get(part, (0.0, 0.0, 0.0)))
        tris = []
        for fc in faces:
            pts = [np.array(q) for q in fc.pts]
            for i in range(1, len(pts) - 1):
                tris.append([pts[0], pts[i], pts[i + 1]])
        a = np.array(tris) - o
        out[part] = a @ Bm.T + np.array(t[9:12])
    return out


def _seg_tri(P0, P1, T3, eps=1e-6):
    """Segments (S, 2, 3) against triangles (M, 3, 3): True where a segment crosses a triangle's
    inside (Moller-Trumbore, touching at the rims not counted)."""
    d = P1 - P0                                   # S x 3
    e1 = T3[:, 1] - T3[:, 0]
    e2 = T3[:, 2] - T3[:, 0]                       # M x 3
    pv = np.cross(d[:, None, :], e2[None, :, :])   # S x M x 3
    det = np.einsum("smk,mk->sm", pv, e1)
    ok = np.abs(det) > 1e-12
    inv = np.where(ok, 1.0 / np.where(ok, det, 1.0), 0.0)
    tv = P0[:, None, :] - T3[None, :, 0, :]
    uu = np.einsum("smk,smk->sm", tv, pv) * inv
    qv = np.cross(tv, e1[None, :, :])
    vv = np.einsum("sk,smk->sm", d, qv) * inv
    tt = np.einsum("mk,smk->sm", e2, qv) * inv
    m = 2e-3
    return ok & (uu > m) & (vv > m) & (uu + vv < 1 - m) & (tt > 0.002) & (tt < 0.998)


def _tris_clash(A, B):
    # bounding-box cull first
    lo = np.maximum(A.reshape(-1, 3).min(0), B.reshape(-1, 3).min(0))
    hi = np.minimum(A.reshape(-1, 3).max(0), B.reshape(-1, 3).max(0))
    if np.any(lo > hi):
        return 0
    n = 0
    for X, Y in ((A, B), (B, A)):
        segs0 = np.concatenate([X[:, 0], X[:, 1], X[:, 2]])
        segs1 = np.concatenate([X[:, 1], X[:, 2], X[:, 0]])
        n += int(_seg_tri(segs0, segs1, Y).sum())
    return n


JOINTS = {frozenset(p) for p in [
    ("mount", "arm_up"), ("mount", "arm_lo"), ("mount", "shaft"), ("mount", "dmp_body"),
    ("knuckle", "arm_up"), ("knuckle", "arm_lo"), ("knuckle", "shaft"), ("knuckle", "tyre"),
    ("knuckle", "fender"), ("arm_up", "dmp_rod"), ("dmp_body", "dmp_rod"), ("arm_up", "shaft"),
    ("arm_lo", "shaft"), ("tyre", "shaft")]}


# the tyre and rim as a solid of revolution: (radius, w) outlines, from aero_wheels' lathe profiles
TYRE_RW = [(RIM, -0.128), (0.392, -TW), (TR, -0.112), (TR, 0.112), (0.392, TW), (RIM, 0.128)]
RIM_RW = [(0.0, -0.072), (0.034, -0.072), (0.262, -0.118), (RIM, -0.128), (RIM, -0.16), (0.0, -0.16)]


def _poly_gap(p, poly):
    inside = False
    best = 1e9
    for i in range(len(poly)):
        a, b = poly[i], poly[(i + 1) % len(poly)]
        if (a[1] > p[1]) != (b[1] > p[1]):
            if p[0] < a[0] + (p[1] - a[1]) * (b[0] - a[0]) / (b[1] - a[1]):
                inside = not inside
        ex, ey = b[0] - a[0], b[1] - a[1]
        t = max(0.0, min(1.0, ((p[0] - a[0]) * ex + (p[1] - a[1]) * ey) / (ex * ex + ey * ey or 1e-12)))
        best = min(best, math.hypot(p[0] - a[0] - ex * t, p[1] - a[1] - ey * t))
    return -best if inside else best


TYRE_GAP_MIN = 0.010


def tyre_gap():
    """The least gap between what rides with the tyre (fender, neck) and the spinning tyre and rim:
    they turn together, so this one number holds at every pose."""
    parts, _ = build_wheel()
    worst = (1e9, None)
    for part in (N + "fender", N + "knuckle"):
        for fc in parts[part]:
            pts = list(fc.pts)
            pts += [th.mul(th.add(pts[i], pts[(i + 1) % len(pts)]), 0.5) for i in range(len(pts))]
            pts.append(cen(fc.pts))
            for q in pts:
                u, v, w = q[0] - K0[0], q[1] - K0[1], q[2] - K0[2]
                r = math.hypot(u, v)
                if fc.style in ("upr", "hub"):
                    continue                     # the upright and hub sit on the axle by design
                g = min(_poly_gap((r, w), TYRE_RW), _poly_gap((r, w), RIM_RW))
                if g < worst[0]:
                    worst = (g, "%s %s at u %.3f v %.3f w %.3f" % (part[len(N):], fc.style, u, v, w))
    return worst


def check_poses(verbose=True):
    parts, origins = build_wheel()
    ok = True
    states = dict(STATES)
    states["steer-"] = (0.0, -math.radians(25))
    # combined extremes are printed for information only: at full droop AND full lock the light
    # wheel's own upper arm meets its own rim barrel (aero_wheels.py, the same arm here) - a shared
    # limit of the in-game mechanism, not of the fender
    info = {"up+steer": (0.14, math.radians(25)), "down+steer": (-0.14, -math.radians(25))}
    states.update(info)
    names = [k[len(N):] for k in parts]
    for nm, (sag, steer) in states.items():
        posed = _posed(parts, origins, pose(sag, steer))
        allv = np.concatenate([a.reshape(-1, 3) for a in posed.values()])
        mx = (np.abs(allv[:, 0]).max() - 0.5, allv[:, 1].max() - 0.5, np.abs(allv[:, 2]).max() - 0.5)
        bad = max(mx) > 0.005
        clashes = []
        for i, a in enumerate(names):
            for b in names[i + 1:]:
                if frozenset((a, b)) in JOINTS:
                    continue
                c = _tris_clash(posed[N + a], posed[N + b])
                if c:
                    clashes.append("%s/%s %d" % (a, b, c))
        if nm not in info:
            ok = ok and not bad and not clashes
        if verbose:
            print("  pose %-10s cell margin x %+.3f y %+.3f z %+.3f  lowest y %.3f  %s%s%s" % (
                nm, mx[0], mx[1], mx[2], allv[:, 1].min(), "OUT " if bad else "ok ",
                ("CLASH " + ", ".join(clashes)) if clashes else "", "  (info)" if nm in info else ""))
    return ok


# ═════════════════════════════════════════════════════════════════════════════════════════════════
# THE RIGS
# ═════════════════════════════════════════════════════════════════════════════════════════════════
FALSUS = [["res://blocks/scenes/block.tscn", [1, 0, 0, 0, 1, 0, 0, 0, 1, 3.2, 0, 0]],
          ["res://blocks/scenes/wheel.tscn", [0, 0, -1, 0, 1, 0, 1, 0, 0, 2.2, 0, 0]]]
ak.rig("aero_e_rig", [
    ("aero_b_block", ak.place()),
    ("aero_b_block", ak.place(at=(0, 0, -1))),
    ("aero_e_wheel", ak.place(yaw=90, at=(-1, 0, 0))),
    ("aero_e_wheel", ak.place(yaw=90, at=(-1, 0, -1))),
    ("aero_e_wheel", ak.place(yaw=-90, at=(1, 0, 0))),
    ("aero_e_wheel", ak.place(yaw=-90, at=(1, 0, -1))),
], ground=-RIDE, extra={"_centre": [0.9, -0.3, -0.5], "_scenes": FALSUS})
# the family: the faired wheel on the block's left, the light wheel on its right
ak.rig("aero_e_rig2", [
    ("aero_b_block", ak.place()),
    ("aero_e_wheel", ak.place(yaw=90, at=(-1, 0, 0))),
    ("aero_wheel", ak.place(yaw=-90, at=(1, 0, 0))),
], ground=-RIDE, extra={"_centre": [0.0, -0.3, 0.0]})


if __name__ == "__main__":
    if "check" not in sys.argv:
        ak.make("aero_e_wheel", wheel_states())
        ak.make("aero_e_rig")
        ak.make("aero_e_rig2")
    ok = check_poses()
    g, where = tyre_gap()
    print("  least gap to the tyre and rim: %.3f m (%s)" % (g, where))
    ok = ok and g >= TYRE_GAP_MIN
    print("pose check:", "PASS" if ok else "FAIL")
