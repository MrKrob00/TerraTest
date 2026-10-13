#!/usr/bin/env python3
"""Poses for the wheel drafts' pictures: every part's transform in block space for a few states (rest,
steered, compressed, drooped), written to art/out/<name>_poses.json for the picture harness
(scratch, run on a copy). The same arithmetic the block's script will do once it is wired."""
import json
import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import marlit_wheels as mwh  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def rx(a):
    c, s = math.cos(a), math.sin(a)
    return [[1, 0, 0], [0, c, -s], [0, s, c]]


def ry(a):
    c, s = math.cos(a), math.sin(a)
    return [[c, 0, s], [0, 1, 0], [-s, 0, c]]


def rz(a):
    c, s = math.cos(a), math.sin(a)
    return [[c, -s, 0], [s, c, 0], [0, 0, 1]]


def mul(A, B):
    return [[sum(A[i][k] * B[k][j] for k in range(3)) for j in range(3)] for i in range(3)]


def app(A, v):
    return [sum(A[i][k] * v[k] for k in range(3)) for i in range(3)]


def add(a, b):
    return [a[i] + b[i] for i in range(3)]


def sub(a, b):
    return [a[i] - b[i] for i in range(3)]


def look(frm, to, stretch=None):
    """A basis whose -Z points from `frm` to `to` (Godot's looking_at), Z scaled to their distance
    when `stretch`."""
    d = sub(to, frm)
    L = math.sqrt(sum(x * x for x in d))
    z = [-x / L for x in d]
    up = [1, 0, 0] if abs(z[0]) < 0.9 else [0, 1, 0]
    x = [up[1] * z[2] - up[2] * z[1], up[2] * z[0] - up[0] * z[2], up[0] * z[1] - up[1] * z[0]]
    n = math.sqrt(sum(v * v for v in x))
    x = [v / n for v in x]
    y = [z[1] * x[2] - z[2] * x[1], z[2] * x[0] - z[0] * x[2], z[0] * x[1] - z[1] * x[0]]
    k = L if stretch else 1.0
    return [[x[0], y[0], z[0] * k], [x[1], y[1], z[1] * k], [x[2], y[2], z[2] * k]]


def tf(B, o):
    """Godot Transform3D order: basis columns x, y, z, then origin."""
    return [B[0][0], B[1][0], B[2][0], B[0][1], B[1][1], B[2][1], B[0][2], B[1][2], B[2][2], o[0], o[1], o[2]]


def light(sag, steer, spin=0.0):
    L = math.hypot(mwh.TC_L[2] - mwh.PIV_L[2], 0.0)
    phi = math.asin(max(-0.9, min(0.9, sag / L)))
    A = rx(phi)
    P = list(mwh.PIV_L)
    kn = add(P, app(A, sub(mwh.KN_L, P)))
    K = mul(A, ry(steer))
    tc = add(kn, app(K, sub(mwh.TC_L, mwh.KN_L)))
    foot = list(mwh.strut_foot_l(phi))
    top = list(mwh.STRUT_TOP_L)
    p = "marlit_wlight_"
    return {p + "body": tf(rx(0), [0, 0, 0]), p + "arm": tf(A, P), p + "knuckle": tf(K, kn),
            p + "tyre": tf(mul(K, rz(spin)), tc), p + "dbody": tf(look(top, foot), top),
            p + "drod": tf(look(foot, top), foot), "_ground": tc[1] - mwh.R_L}


def heavy(sag, steer, spin=0.0):
    ax, az = mwh.AX_H
    R = ry(steer)
    p = "marlit_wheavy_"
    gap = mwh.LINK_HI - (mwh.LINK_LO + sag)
    _, ang = mwh.scissor(gap)
    off = app(R, [mwh.LINK_X, 0, 0])
    tc = app(R, [mwh.TC_H[0] - ax, mwh.TC_H[1], mwh.TC_H[2] - az])
    return {p + "body": tf(rx(0), [0, 0, 0]), p + "collar": tf(R, [ax, 0, az]),
            p + "leg": tf(R, [ax, sag, az]),
            p + "link_up": tf(mul(R, rz(ang)), [ax + off[0], mwh.LINK_HI, az + off[2]]),
            p + "link_lo": tf(mul(R, rz(math.pi - ang)), [ax + off[0], mwh.LINK_LO + sag, az + off[2]]),
            p + "tyre": tf(mul(R, rz(spin)), [ax + tc[0], tc[1] + sag, az + tc[2]]),
            "_ground": tc[1] + sag - mwh.R_H}


STATES = [("rest", 0.0, 0.0), ("steer", 0.0, math.radians(25)), ("up", 0.18, 0.0), ("down", -0.14, 0.0)]

if __name__ == "__main__":
    for name, fn in (("marlit_wlight", light), ("marlit_wheavy", heavy)):
        out = {st: fn(sag, steer) for st, sag, steer in STATES}
        with open(os.path.join(ROOT, "art", "out", name + "_poses.json"), "w") as fh:
            json.dump(out, fh)
        print("wrote", name)


# ── the Falsus drafts: the artist's plate and small tyre are placed from their scenes ('@' keys) ──
import falsus_wheels as fw  # noqa: E402

PLATE = "@res://blocks/scenes/small_wheel.tscn|Wheel_module_small"
TYRE = "@res://blocks/scenes/small_wheel.tscn|Wheel_module_small/Wheel_susp_high/Wheel_susp_low/Wheel_susp_mid/Wheel_Axle/wheel"


def _swing(pin, tc, sag, axis):
    """The arm's swing about its pivot (axis "x" or "z") that lifts the hub by `sag`, as a matrix."""
    d = sub(tc, pin)
    if axis == "z":                       # the arm in the XY plane
        L = math.hypot(d[0], d[1])
        a0 = math.atan2(d[1], d[0])
        a1 = math.asin(max(-0.95, min(0.95, (L * math.sin(a0) + sag) / L)))
        a1 = math.pi - a1 if d[0] < 0 else a1
        return rz(a1 - a0)
    L = math.hypot(d[1], d[2])            # the arm in the YZ plane
    a0 = math.atan2(d[1], -d[2])
    a1 = math.asin(max(-0.95, min(0.95, (L * math.sin(a0) + sag) / L)))
    return rx(-(a1 - a0))


def riser(sag, steer, spin=0.0):
    tax = [fw.TURN_AX[0], 0.0, fw.TURN_AX[1]]
    R = ry(steer)
    S = _swing(fw.PIVOT_R, fw.TC_R, sag, "z")
    pv = add(tax, app(R, sub(fw.PIVOT_R, tax)))
    A = mul(R, S)
    tc = add(pv, app(A, sub(fw.TC_R, fw.PIVOT_R)))
    plate = tf([[1, 0, 0], [0, -1, 0], [0, 0, -1]], [0, 0.5, 0])
    T = mul(R, mul([[0, 0, -1], [0, 1, 0], [1, 0, 0]], rx(spin)))
    return {"riser_body": tf(rx(0), [0, 0, 0]), "riser_head": tf(R, tax), "riser_arm": tf(A, pv), PLATE: plate,
            TYRE + "#": tf(T, add(tc, app(R, [0, 0, fw.TYRE_W / 2]))), "_ground": tc[1] - fw.TYRE_R}


def stab2(sag, steer, spin=0.0):
    tax = [fw.TURN_S[0], 0.0, fw.TURN_S[1]]
    R = ry(steer)
    S = _swing(fw.PIN_S, fw.TC_S, sag, "x")
    pv = add(tax, app(R, sub(fw.PIN_S, tax)))
    A = mul(R, S)
    tc = add(pv, app(A, sub(fw.TC_S, fw.PIN_S)))
    plate = tf([[0, -1, 0], [0, 0, -1], [1, 0, 0]], [0, 0, 0.5])
    T = mul(A, rx(spin))
    return {"stab2_body": tf(rx(0), [0, 0, 0]), "stab2_head": tf(R, tax), "stab2_arm": tf(A, pv), PLATE: plate,
            TYRE + "#": tf(T, add(tc, app(A, [fw.TYRE_W / 2, 0, 0]))), "_ground": tc[1] - fw.TYRE_R}

if __name__ == "__main__":
    for name, fn in (("riser", riser), ("stab2", stab2)):
        out = {st: fn(sag, steer) for st, sag, steer in STATES}
        with open(os.path.join(ROOT, "art", "out", name + "_poses.json"), "w") as fh:
            json.dump(out, fh)
        print("wrote", name)
