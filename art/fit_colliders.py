"""Fitted machine colliders: blocks/colliders/<KEY>.tres, one ConvexPolygonShape3D per block whose
model fills its box badly (a drill, a turret, a wheel's mount, a wedge).

Input is the vertex dump `art/collider_dump.gd` writes (run it on a COPY with the engine, see CLAUDE.md
§3): every MeshInstance3D a block's scene owns, in the block's own axes, at rest. The hull is taken
over those vertices
  - WITHOUT THE TYRE (a node path ending `wheel/` or `Tyre/`): the wheel's probe carries the machine,
    a collider round the tyre would drag it on the ground for good;
  - WITHOUT THE AMMO TEMPLATE (`Ammo/`), which is a hidden round, not the block;
  - CLAMPED INTO THE BLOCK'S CELLS: a fitted collider is the old box or LESS, never more, so it can
    only remove contacts, never add one (the big wheel's arm reaches under its cell, the solar panel's
    old box floated in the middle of its cell over a panel lying on the floor).
then cut to MAX_POINTS by farthest-point sampling (inside the true hull, never outside).
A block is fitted when the hull is under KEEP of its old box. Armour plates keep their boxes (thin
slabs, measured to the plate already) and so do the base machines (FACTORY_LIKE): they stand still.

  godot --headless --path <copy> --script res://art/collider_dump.gd
  python3 art/fit_colliders.py <the path it printed>
"""
import json, sys, os
import numpy as np
from scipy.spatial import ConvexHull

KEEP = 0.85
MAX_POINTS = 48
TYRE = ('wheel/', 'Tyre/')
SKIP = {'ARMOR', 'ARMOR2', 'ARMOR4', 'ARMOR9', 'MARLIT_ARMOR2', 'MARLIT_ARMOR4', 'MARLIT_ARMOR8'}
FACTORY_LIKE = {'PROCESSOR', 'SELLER', 'FABRICATOR', 'SCRAPPER', 'COMP_FACTORY', 'STORAGE', 'PACKER',
		'AUTO_MINER', 'SUPPORT', 'ROT_SUPPORT', 'MARLIT_SUPPORT', 'MARLIT_ROT_SUPPORT'}
# also fitted when the old box stands away from the model (its middle this far off the hull's)
OFF_CENTRE = 0.1
OUT = os.path.join(os.path.dirname(__file__), '..', 'blocks', 'colliders')

def fps(p, n):
	if len(p) <= n:
		return p
	idx = [int(np.argmax(np.linalg.norm(p - p.mean(0), axis=1)))]
	dist = np.linalg.norm(p - p[idx[0]], axis=1)
	while len(idx) < n:
		i = int(np.argmax(dist))
		idx.append(i)
		dist = np.minimum(dist, np.linalg.norm(p - p[i], axis=1))
	return p[idx]

def main(path):
	d = json.load(open(path))
	os.makedirs(OUT, exist_ok=True)
	made = []
	for key, v in sorted(d.items()):
		if key in SKIP or key in FACTORY_LIKE or 'box' not in v['col']:
			continue
		box = np.prod(v['col']['box'])
		cells = np.array(v['cells'], dtype=float)
		lo = cells.min(0) - 0.5
		hi = cells.max(0) + 0.5
		pts = np.array([p for part, vs in v['parts'].items()
				if not part.endswith(TYRE) and 'Ammo/' not in part for p in vs])
		if len(pts) < 4:
			continue
		pts = np.clip(pts, lo, hi)
		hull = ConvexHull(pts, qhull_options='QJ')
		hv = fps(pts[hull.vertices], MAX_POINTS)
		vol = ConvexHull(hv, qhull_options='QJ').volume
		share = vol / box
		bc = np.array(v['col']['off'])
		off = np.linalg.norm((hv.min(0) + hv.max(0)) * 0.5 - bc)
		if share >= KEEP and off < OFF_CENTRE:
			continue
		body = ', '.join('%.4g, %.4g, %.4g' % tuple(q) for q in hv)
		with open(os.path.join(OUT, key + '.tres'), 'w') as f:
			f.write('[gd_resource type="ConvexPolygonShape3D" format=3]\n\n[resource]\n')
			f.write('points = PackedVector3Array(%s)\n' % body)
		made.append((key, share, len(hv)))
	for key, share, n in made:
		print('%-20s %3d%% of its box, %d points' % (key, share * 100, n))
	print(len(made), 'fitted')

if __name__ == '__main__':
	main(sys.argv[1])
