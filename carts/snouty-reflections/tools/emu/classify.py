#!/usr/bin/env python3
"""Label each pixel's ray path with the repo's numpy reference renderer
(tools/reference.py), so per-pixel costs can be grouped by path.

Labels read left to right from the eye: 'sky', 'S>sky' (sphere, then sky),
'W>S>W>sky', 'S(lambert)' for the depth-2 sphere shading, and '+sun' when
the final sky lookup takes the sun-glow branch (dot(d, L) > 0.9).

usage: .venv/bin/python classify.py FRAME OUTDIR   (writes OUTDIR/classes_FFFF.json,
                                                    list indexed x*128+y)
"""
import json
import os
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))  # tools/, for reference.py
import reference as R  # noqa: E402


def path(o, d, depth, t, frm):
    o1, d1 = o[None], d[None]
    ts = np.inf if frm == 'S' else R.hit_sphere(o1, d1)[0]
    tw = np.inf if frm == 'W' else R.hit_water(o1, d1)[0]
    if np.isfinite(tw) and not (np.isfinite(ts) and ts <= tw):
        p = o + d * tw
        n = R.ripple_normal(p[None], np.array([tw]), t)[0]
        r = R.reflect(d1, n[None])[0]
        r[1] = max(r[1], 0.02)
        r = r / np.linalg.norm(r)
        if depth < 2:
            return 'W>' + path(p, r, depth + 1, t, 'W')
        return 'W>sky' + ('+sun' if r @ R.SUN_L > 0.9 else '')
    if np.isfinite(ts):
        p = o + d * ts
        n = p - R.SPHERE_C
        if depth < 2:
            return 'S>' + path(p, R.reflect(d1, n[None])[0], depth + 1, t, 'S')
        return 'S(lambert)'
    return 'sky' + ('+sun' if d @ R.SUN_L > 0.9 else '')


def classify(frame, out):
    t = frame / 20.0
    eye, fwd, right, up = R.camera(frame)
    labels = []
    for x in range(R.W):
        u = (x + 0.5 - 80.0) / 80.0 * R.TAN_H
        for y in range(R.H):
            v = -(y + 0.5 - 64.0) / 80.0 * R.TAN_H
            d = fwd + right * u + up * v
            d /= np.linalg.norm(d)
            labels.append(path(eye.copy(), d, 0, t, 'eye'))
    with open(os.path.join(out, f'classes_{frame:04d}.json'), 'w') as f:
        json.dump(labels, f)
    return labels


if __name__ == '__main__':
    classify(int(sys.argv[1]), sys.argv[2])
