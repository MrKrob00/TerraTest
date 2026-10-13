#!/usr/bin/env python3
"""A GENERATED MODEL'S SELF-CHECK, run after every build of it (the player's rule: "after every run,
self-test the quality").

    python3 art/model_check.py <name> [...]

A model registers a CHECK beside its builder (`em.CHECKS[name]`):
    {"cells": (lo, hi),                  the block's own box in block space
     "origins": {part: (x, y, z)},       where each part's origin stands in block space (default 0)
     "spin": {part: (ax, ay, az)},       a part that turns, and the axis it turns about
     "solid": [(lo, hi), ...],           boxes of the STILL body nothing that turns may enter
     "budget": 700}                      triangles for the whole block (CLAUDE.md: past it, CULL)
and is failed when:
  - a vertex of any part (a turning part at 16 angles) stands outside the cells by more than TOL;
  - the block is over its triangle budget;
  - a turning part enters a solid box at any of those angles.
Prints each part's box and triangle count, then PASS or the failures.
"""
import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import turret_heads as th  # noqa: E402
import emitter_models as em  # noqa: E402

TOL = 0.01
ANGLES = 16
if not hasattr(em, "CHECKS"):
    em.CHECKS = {}


def _rot(p, axis, a):
    """p turned by angle a about the unit axis through the origin (Rodrigues)."""
    k = th.norm(axis)
    c, s = math.cos(a), math.sin(a)
    kxp = th.cross(k, p)
    kdp = th.dot(k, p)
    return tuple(p[i] * c + kxp[i] * s + k[i] * kdp * (1 - c) for i in range(3))


def check(name):
    seed, build, tex = em.BLOCKS[name]
    th.random.seed(seed)
    th.ISLANDS.clear()
    from PIL import Image
    parts = build(th.Packer(tex), Image.new("RGB", (tex, tex)))
    if name in em.CULL:
        parts = {k: em.cull_hidden(v) for k, v in parts.items()}
    cfg = em.CHECKS.get(name, {})
    lo, hi = cfg.get("cells", ((-1e9,) * 3, (1e9,) * 3))
    origins = cfg.get("origins", {})
    spin = cfg.get("spin", {})
    solid = cfg.get("solid", [])
    budget = cfg.get("budget", 700)
    fails = []
    total = 0
    for part, faces in parts.items():
        o = origins.get(part, (0.0, 0.0, 0.0))
        tris = sum(len(fc.pts) - 2 for fc in faces)
        total += tris
        angles = [2 * math.pi * i / ANGLES for i in range(ANGLES)] if part in spin else [0.0]
        mn, mx = [1e9] * 3, [-1e9] * 3
        out = inside = 0
        for a in angles:
            for fc in faces:
                for p in fc.pts:
                    q = _rot(p, spin[part], a) if part in spin else p
                    w = th.add(q, o)
                    for i in range(3):
                        mn[i] = min(mn[i], w[i])
                        mx[i] = max(mx[i], w[i])
                    if any(w[i] < lo[i] - TOL or w[i] > hi[i] + TOL for i in range(3)):
                        out += 1
                    if part in spin and any(all(b[0][i] + TOL < w[i] < b[1][i] - TOL for i in range(3))
                                            for b in solid):
                        inside += 1
        print("  %-28s %4d tris  box (%.2f %.2f %.2f)..(%.2f %.2f %.2f)%s" % (
            part, tris, mn[0], mn[1], mn[2], mx[0], mx[1], mx[2], "  turning" if part in spin else ""))
        if out:
            fails.append("%s: %d vertices outside the cells" % (part, out))
        if inside:
            fails.append("%s: %d vertices enter the still body while turning" % (part, inside))
    if total > budget:
        fails.append("%d triangles over the budget %d" % (total, budget))
    print("%s: %d triangles - %s" % (name, total, "PASS" if not fails else "FAIL"))
    for x in fails:
        print("   FAIL " + x)
    return not fails


if __name__ == "__main__":
    import importlib
    ok = True
    for nm in sys.argv[1:]:
        if nm not in em.BLOCKS:
            for mod in ("marlit_cutters", "marlit_drill", "marlit_weapons", "marlit_drive", "marlit_wheels", "falsus_wheels"):
                importlib.import_module(mod)
                if nm in em.BLOCKS:
                    break
        ok = check(nm) and ok
    sys.exit(0 if ok else 1)
