#!/usr/bin/env python3
"""Tessellates the Utah teapot into the cart's triangle table.

    python3 tools/gen_teapot.py            # writes cart/src/render/teapot_mesh.zig
    python3 tools/gen_teapot.py --check    # exit 1 if the committed file is stale

Run from carts/snouty-pipes/ (or anywhere: paths are relative to this file).
The output is committed, so the build never runs this and the cart does no
comptime work on the mesh (Adrian's Mac runs out of memory on heavy comptime).

Source data: Martin Newell's 1975 teapot, 32 bicubic Bezier patches over 290
control points, in Jim Blinn's vertically squashed proportions as Eric
Haines's Standard Procedural Databases and nearly every renderer since
distribute it (the copy here was checked against three.js's
TeapotGeometry). The lid is widened by 7.7% in x and y so it meets the rim
(three.js's `fitLid`).

What it writes (SPEC.md section 4, PLAN.md Track C item 1):
- rim, body, lid, handle and spout; the 4 bottom patches are dropped (the
  teapot sits on a pipe joint, its base is rarely seen and the triangles
  are better spent on the silhouette);
- about 260 triangles: each patch is cut into its own (columns x rows) grid,
  and triangles collapsed at the lid's pole are removed;
- local axes: +y up (Newell's +z), +x towards the spout (Newell's +x), +z =
  x cross y; centred on the box around the kept patches and scaled to unit
  height;
- per-vertex unit normals from the patch derivatives, pointing outwards,
  averaged where patches of the same part meet (rim and body are one part,
  lid, handle and spout one each: the handle's end touches the body at a
  shared control point and must not be welded to it);
- triangles wound counter-clockwise seen from outside (right-handed), so
  cross(b - a, c - a) points out of the surface;
- `[3]f32` rows only, never `@Vector` (the thumb ABI stride bug in
  CLAUDE.md).
"""
import argparse
import math
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", "cart", "src", "render", "teapot_mesh.zig")

# Newell's 32 bicubic Bezier patches: 16 control point indices each, row-major
# (4 rows of 4), grouped rim 0-3, body 4-11, handle 12-15, spout 16-19,
# lid 20-27, bottom 28-31.
PATCHES = [
    (0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15),  # 0 rim
    (3, 16, 17, 18, 7, 19, 20, 21, 11, 22, 23, 24, 15, 25, 26, 27),  # 1 rim
    (18, 28, 29, 30, 21, 31, 32, 33, 24, 34, 35, 36, 27, 37, 38, 39),  # 2 rim
    (30, 40, 41, 0, 33, 42, 43, 4, 36, 44, 45, 8, 39, 46, 47, 12),  # 3 rim
    (12, 13, 14, 15, 48, 49, 50, 51, 52, 53, 54, 55, 56, 57, 58, 59),  # 4 body
    (15, 25, 26, 27, 51, 60, 61, 62, 55, 63, 64, 65, 59, 66, 67, 68),  # 5 body
    (27, 37, 38, 39, 62, 69, 70, 71, 65, 72, 73, 74, 68, 75, 76, 77),  # 6 body
    (39, 46, 47, 12, 71, 78, 79, 48, 74, 80, 81, 52, 77, 82, 83, 56),  # 7 body
    (56, 57, 58, 59, 84, 85, 86, 87, 88, 89, 90, 91, 92, 93, 94, 95),  # 8 body
    (59, 66, 67, 68, 87, 96, 97, 98, 91, 99, 100, 101, 95, 102, 103, 104),  # 9 body
    (68, 75, 76, 77, 98, 105, 106, 107, 101, 108, 109, 110, 104, 111, 112, 113),  # 10 body
    (77, 82, 83, 56, 107, 114, 115, 84, 110, 116, 117, 88, 113, 118, 119, 92),  # 11 body
    (120, 121, 122, 123, 124, 125, 126, 127, 128, 129, 130, 131, 132, 133, 134, 135),  # 12 handle
    (123, 136, 137, 120, 127, 138, 139, 124, 131, 140, 141, 128, 135, 142, 143, 132),  # 13 handle
    (132, 133, 134, 135, 144, 145, 146, 147, 148, 149, 150, 151, 68, 152, 153, 154),  # 14 handle
    (135, 142, 143, 132, 147, 155, 156, 144, 151, 157, 158, 148, 154, 159, 160, 68),  # 15 handle
    (161, 162, 163, 164, 165, 166, 167, 168, 169, 170, 171, 172, 173, 174, 175, 176),  # 16 spout
    (164, 177, 178, 161, 168, 179, 180, 165, 172, 181, 182, 169, 176, 183, 184, 173),  # 17 spout
    (173, 174, 175, 176, 185, 186, 187, 188, 189, 190, 191, 192, 193, 194, 195, 196),  # 18 spout
    (176, 183, 184, 173, 188, 197, 198, 185, 192, 199, 200, 189, 196, 201, 202, 193),  # 19 spout
    (203, 203, 203, 203, 204, 205, 206, 207, 208, 208, 208, 208, 209, 210, 211, 212),  # 20 lid
    (203, 203, 203, 203, 207, 213, 214, 215, 208, 208, 208, 208, 212, 216, 217, 218),  # 21 lid
    (203, 203, 203, 203, 215, 219, 220, 221, 208, 208, 208, 208, 218, 222, 223, 224),  # 22 lid
    (203, 203, 203, 203, 221, 225, 226, 204, 208, 208, 208, 208, 224, 227, 228, 209),  # 23 lid
    (209, 210, 211, 212, 229, 230, 231, 232, 233, 234, 235, 236, 237, 238, 239, 240),  # 24 lid
    (212, 216, 217, 218, 232, 241, 242, 243, 236, 244, 245, 246, 240, 247, 248, 249),  # 25 lid
    (218, 222, 223, 224, 243, 250, 251, 252, 246, 253, 254, 255, 249, 256, 257, 258),  # 26 lid
    (224, 227, 228, 209, 252, 259, 260, 229, 255, 261, 262, 233, 258, 263, 264, 237),  # 27 lid
    (265, 265, 265, 265, 266, 267, 268, 269, 270, 271, 272, 273, 92, 119, 118, 113),  # 28 bottom
    (265, 265, 265, 265, 269, 274, 275, 276, 273, 277, 278, 279, 113, 112, 111, 104),  # 29 bottom
    (265, 265, 265, 265, 276, 280, 281, 282, 279, 283, 284, 285, 104, 103, 102, 95),  # 30 bottom
    (265, 265, 265, 265, 282, 286, 287, 266, 285, 288, 289, 270, 95, 94, 93, 92),  # 31 bottom
]

# Control points (x, y, z), z up, Blinn's proportions: 0 <= z <= 3.15.
VERTICES = [
    (1.4, 0, 2.4), (1.4, -0.784, 2.4), (0.784, -1.4, 2.4), (0, -1.4, 2.4),
    (1.3375, 0, 2.53125), (1.3375, -0.749, 2.53125), (0.749, -1.3375, 2.53125), (0, -1.3375, 2.53125),
    (1.4375, 0, 2.53125), (1.4375, -0.805, 2.53125), (0.805, -1.4375, 2.53125), (0, -1.4375, 2.53125),
    (1.5, 0, 2.4), (1.5, -0.84, 2.4), (0.84, -1.5, 2.4), (0, -1.5, 2.4),
    (-0.784, -1.4, 2.4), (-1.4, -0.784, 2.4), (-1.4, 0, 2.4), (-0.749, -1.3375, 2.53125),
    (-1.3375, -0.749, 2.53125), (-1.3375, 0, 2.53125), (-0.805, -1.4375, 2.53125), (-1.4375, -0.805, 2.53125),
    (-1.4375, 0, 2.53125), (-0.84, -1.5, 2.4), (-1.5, -0.84, 2.4), (-1.5, 0, 2.4),
    (-1.4, 0.784, 2.4), (-0.784, 1.4, 2.4), (0, 1.4, 2.4), (-1.3375, 0.749, 2.53125),
    (-0.749, 1.3375, 2.53125), (0, 1.3375, 2.53125), (-1.4375, 0.805, 2.53125), (-0.805, 1.4375, 2.53125),
    (0, 1.4375, 2.53125), (-1.5, 0.84, 2.4), (-0.84, 1.5, 2.4), (0, 1.5, 2.4),
    (0.784, 1.4, 2.4), (1.4, 0.784, 2.4), (0.749, 1.3375, 2.53125), (1.3375, 0.749, 2.53125),
    (0.805, 1.4375, 2.53125), (1.4375, 0.805, 2.53125), (0.84, 1.5, 2.4), (1.5, 0.84, 2.4),
    (1.75, 0, 1.875), (1.75, -0.98, 1.875), (0.98, -1.75, 1.875), (0, -1.75, 1.875),
    (2, 0, 1.35), (2, -1.12, 1.35), (1.12, -2, 1.35), (0, -2, 1.35),
    (2, 0, 0.9), (2, -1.12, 0.9), (1.12, -2, 0.9), (0, -2, 0.9),
    (-0.98, -1.75, 1.875), (-1.75, -0.98, 1.875), (-1.75, 0, 1.875), (-1.12, -2, 1.35),
    (-2, -1.12, 1.35), (-2, 0, 1.35), (-1.12, -2, 0.9), (-2, -1.12, 0.9),
    (-2, 0, 0.9), (-1.75, 0.98, 1.875), (-0.98, 1.75, 1.875), (0, 1.75, 1.875),
    (-2, 1.12, 1.35), (-1.12, 2, 1.35), (0, 2, 1.35), (-2, 1.12, 0.9),
    (-1.12, 2, 0.9), (0, 2, 0.9), (0.98, 1.75, 1.875), (1.75, 0.98, 1.875),
    (1.12, 2, 1.35), (2, 1.12, 1.35), (1.12, 2, 0.9), (2, 1.12, 0.9),
    (2, 0, 0.45), (2, -1.12, 0.45), (1.12, -2, 0.45), (0, -2, 0.45),
    (1.5, 0, 0.225), (1.5, -0.84, 0.225), (0.84, -1.5, 0.225), (0, -1.5, 0.225),
    (1.5, 0, 0.15), (1.5, -0.84, 0.15), (0.84, -1.5, 0.15), (0, -1.5, 0.15),
    (-1.12, -2, 0.45), (-2, -1.12, 0.45), (-2, 0, 0.45), (-0.84, -1.5, 0.225),
    (-1.5, -0.84, 0.225), (-1.5, 0, 0.225), (-0.84, -1.5, 0.15), (-1.5, -0.84, 0.15),
    (-1.5, 0, 0.15), (-2, 1.12, 0.45), (-1.12, 2, 0.45), (0, 2, 0.45),
    (-1.5, 0.84, 0.225), (-0.84, 1.5, 0.225), (0, 1.5, 0.225), (-1.5, 0.84, 0.15),
    (-0.84, 1.5, 0.15), (0, 1.5, 0.15), (1.12, 2, 0.45), (2, 1.12, 0.45),
    (0.84, 1.5, 0.225), (1.5, 0.84, 0.225), (0.84, 1.5, 0.15), (1.5, 0.84, 0.15),
    (-1.6, 0, 2.025), (-1.6, -0.3, 2.025), (-1.5, -0.3, 2.25), (-1.5, 0, 2.25),
    (-2.3, 0, 2.025), (-2.3, -0.3, 2.025), (-2.5, -0.3, 2.25), (-2.5, 0, 2.25),
    (-2.7, 0, 2.025), (-2.7, -0.3, 2.025), (-3, -0.3, 2.25), (-3, 0, 2.25),
    (-2.7, 0, 1.8), (-2.7, -0.3, 1.8), (-3, -0.3, 1.8), (-3, 0, 1.8),
    (-1.5, 0.3, 2.25), (-1.6, 0.3, 2.025), (-2.5, 0.3, 2.25), (-2.3, 0.3, 2.025),
    (-3, 0.3, 2.25), (-2.7, 0.3, 2.025), (-3, 0.3, 1.8), (-2.7, 0.3, 1.8),
    (-2.7, 0, 1.575), (-2.7, -0.3, 1.575), (-3, -0.3, 1.35), (-3, 0, 1.35),
    (-2.5, 0, 1.125), (-2.5, -0.3, 1.125), (-2.65, -0.3, 0.9375), (-2.65, 0, 0.9375),
    (-2, -0.3, 0.9), (-1.9, -0.3, 0.6), (-1.9, 0, 0.6), (-3, 0.3, 1.35),
    (-2.7, 0.3, 1.575), (-2.65, 0.3, 0.9375), (-2.5, 0.3, 1.125), (-1.9, 0.3, 0.6),
    (-2, 0.3, 0.9), (1.7, 0, 1.425), (1.7, -0.66, 1.425), (1.7, -0.66, 0.6),
    (1.7, 0, 0.6), (2.6, 0, 1.425), (2.6, -0.66, 1.425), (3.1, -0.66, 0.825),
    (3.1, 0, 0.825), (2.3, 0, 2.1), (2.3, -0.25, 2.1), (2.4, -0.25, 2.025),
    (2.4, 0, 2.025), (2.7, 0, 2.4), (2.7, -0.25, 2.4), (3.3, -0.25, 2.4),
    (3.3, 0, 2.4), (1.7, 0.66, 0.6), (1.7, 0.66, 1.425), (3.1, 0.66, 0.825),
    (2.6, 0.66, 1.425), (2.4, 0.25, 2.025), (2.3, 0.25, 2.1), (3.3, 0.25, 2.4),
    (2.7, 0.25, 2.4), (2.8, 0, 2.475), (2.8, -0.25, 2.475), (3.525, -0.25, 2.49375),
    (3.525, 0, 2.49375), (2.9, 0, 2.475), (2.9, -0.15, 2.475), (3.45, -0.15, 2.5125),
    (3.45, 0, 2.5125), (2.8, 0, 2.4), (2.8, -0.15, 2.4), (3.2, -0.15, 2.4),
    (3.2, 0, 2.4), (3.525, 0.25, 2.49375), (2.8, 0.25, 2.475), (3.45, 0.15, 2.5125),
    (2.9, 0.15, 2.475), (3.2, 0.15, 2.4), (2.8, 0.15, 2.4), (0, 0, 3.15),
    (0.8, 0, 3.15), (0.8, -0.45, 3.15), (0.45, -0.8, 3.15), (0, -0.8, 3.15),
    (0, 0, 2.85), (0.2, 0, 2.7), (0.2, -0.112, 2.7), (0.112, -0.2, 2.7),
    (0, -0.2, 2.7), (-0.45, -0.8, 3.15), (-0.8, -0.45, 3.15), (-0.8, 0, 3.15),
    (-0.112, -0.2, 2.7), (-0.2, -0.112, 2.7), (-0.2, 0, 2.7), (-0.8, 0.45, 3.15),
    (-0.45, 0.8, 3.15), (0, 0.8, 3.15), (-0.2, 0.112, 2.7), (-0.112, 0.2, 2.7),
    (0, 0.2, 2.7), (0.45, 0.8, 3.15), (0.8, 0.45, 3.15), (0.112, 0.2, 2.7),
    (0.2, 0.112, 2.7), (0.4, 0, 2.55), (0.4, -0.224, 2.55), (0.224, -0.4, 2.55),
    (0, -0.4, 2.55), (1.3, 0, 2.55), (1.3, -0.728, 2.55), (0.728, -1.3, 2.55),
    (0, -1.3, 2.55), (1.3, 0, 2.4), (1.3, -0.728, 2.4), (0.728, -1.3, 2.4),
    (0, -1.3, 2.4), (-0.224, -0.4, 2.55), (-0.4, -0.224, 2.55), (-0.4, 0, 2.55),
    (-0.728, -1.3, 2.55), (-1.3, -0.728, 2.55), (-1.3, 0, 2.55), (-0.728, -1.3, 2.4),
    (-1.3, -0.728, 2.4), (-1.3, 0, 2.4), (-0.4, 0.224, 2.55), (-0.224, 0.4, 2.55),
    (0, 0.4, 2.55), (-1.3, 0.728, 2.55), (-0.728, 1.3, 2.55), (0, 1.3, 2.55),
    (-1.3, 0.728, 2.4), (-0.728, 1.3, 2.4), (0, 1.3, 2.4), (0.224, 0.4, 2.55),
    (0.4, 0.224, 2.55), (0.728, 1.3, 2.55), (1.3, 0.728, 2.55), (0.728, 1.3, 2.4),
    (1.3, 0.728, 2.4), (0, 0, 0), (1.425, 0, 0), (1.425, 0.798, 0),
    (0.798, 1.425, 0), (0, 1.425, 0), (1.5, 0, 0.075), (1.5, 0.84, 0.075),
    (0.84, 1.5, 0.075), (0, 1.5, 0.075), (-0.798, 1.425, 0), (-1.425, 0.798, 0),
    (-1.425, 0, 0), (-0.84, 1.5, 0.075), (-1.5, 0.84, 0.075), (-1.5, 0, 0.075),
    (-1.425, -0.798, 0), (-0.798, -1.425, 0), (0, -1.425, 0), (-1.5, -0.84, 0.075),
    (-0.84, -1.5, 0.075), (0, -1.5, 0.075), (0.798, -1.425, 0), (1.425, -0.798, 0),
    (0.84, -1.5, 0.075), (1.5, -0.84, 0.075),
]

PART = {"rim": "body", "body": "body", "lid": "lid", "handle": "handle", "spout": "spout", "bottom": "bottom"}
GROUP = ["rim"] * 4 + ["body"] * 8 + ["handle"] * 4 + ["spout"] * 4 + ["lid"] * 8 + ["bottom"] * 4

# Cuts per patch: (along a row = control point columns, along a column = rows).
# Rim/body/lid rows run round the pot (a quarter turn per patch), columns run
# down it; handle and spout patches run round the tube in rows, along it in
# columns. Tuned for a teapot about 20 px tall: silhouette first.
CUTS = {
    "rim": (3, 2),
    "body": (3, 2),
    "lid_knob": (2, 2),
    "lid": (2, 1),
    "handle": (2, 2),
    "spout": (2, 3),
}
LID_FIT = 1.077


def cuts_for(i):
    g = GROUP[i]
    if g == "lid":
        return CUTS["lid_knob"] if i < 24 else CUTS["lid"]
    return CUTS[g]


def control_points(i):
    pts = []
    for k in PATCHES[i]:
        x, y, z = VERTICES[k]
        if GROUP[i] == "lid":
            x, y = x * LID_FIT, y * LID_FIT
        pts.append((x, y, z))
    return [pts[r * 4:(r + 1) * 4] for r in range(4)]


def bern(t):
    s = 1.0 - t
    return (s * s * s, 3 * t * s * s, 3 * t * t * s, t * t * t)


def dbern(t):
    s = 1.0 - t
    return (-3 * s * s, 3 * s * s - 6 * t * s, 6 * t * s - 3 * t * t, 3 * t * t)


def add(a, b):
    return (a[0] + b[0], a[1] + b[1], a[2] + b[2])


def sub(a, b):
    return (a[0] - b[0], a[1] - b[1], a[2] - b[2])


def mul(a, s):
    return (a[0] * s, a[1] * s, a[2] * s)


def dot(a, b):
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]


def cross(a, b):
    return (a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0])


def norm(a):
    return math.sqrt(dot(a, a))


def unit(a):
    n = norm(a)
    return mul(a, 1.0 / n) if n > 0 else a


def evaluate(cp, u, v):
    """Point and d/du x d/dv at (u along a row, v along a column)."""
    bu, bv, du, dv = bern(u), bern(v), dbern(u), dbern(v)
    p = pu = pv = (0.0, 0.0, 0.0)
    for r in range(4):
        for c in range(4):
            q = cp[r][c]
            p = add(p, mul(q, bv[r] * bu[c]))
            pu = add(pu, mul(q, bv[r] * du[c]))
            pv = add(pv, mul(q, dv[r] * bu[c]))
    return p, cross(pu, pv)


def grid(cp, nu, nv):
    return [[evaluate(cp, j / nu, i / nv) for j in range(nu + 1)] for i in range(nv + 1)]


def ray_hits(o, d, tris):
    """Möller-Trumbore: number of triangles the ray o + t d (t > 0) crosses."""
    n = 0
    for a, b, c in tris:
        e1, e2 = sub(b, a), sub(c, a)
        h = cross(d, e2)
        det = dot(e1, h)
        if abs(det) < 1e-12:
            continue
        f = 1.0 / det
        s = sub(o, a)
        u = f * dot(s, h)
        if u < 0 or u > 1:
            continue
        q = cross(s, e1)
        w = f * dot(d, q)
        if w < 0 or u + w > 1:
            continue
        if f * dot(e2, q) > 1e-6:
            n += 1
    return n


def outward_signs():
    """+1 where d/du x d/dv points out of the teapot, -1 where it points in,
    per patch: parity of ray crossings against a fine mesh of all 32
    patches (the bottom closes the pot), voted over a few points."""
    fine = []
    for i in range(32):
        g = grid(control_points(i), 8, 8)
        for r in range(8):
            for c in range(8):
                a, b, cc, d = g[r][c][0], g[r][c + 1][0], g[r + 1][c + 1][0], g[r + 1][c][0]
                fine += [(a, b, cc), (a, cc, d)]
    signs = []
    for i in range(32):
        cp = control_points(i)
        vote = 0
        for u, v in ((0.5, 0.5), (0.3, 0.6), (0.7, 0.4)):
            p, n = evaluate(cp, u, v)
            n = unit(n)
            # Jitter the direction a little so the ray avoids grazing seams.
            d = unit(add(n, (0.013, 0.007, 0.011)))
            vote += 1 if ray_hits(add(p, mul(n, 1e-3)), d, fine) % 2 == 0 else -1
        signs.append(1 if vote > 0 else -1)
    return signs


def build():
    signs = outward_signs()
    verts = {}  # (part, rounded position) -> index
    pos, nsum, fsum = [], [], []
    tris = []
    counts = {}

    def vid(part, p, n):
        key = (part, round(p[0], 5), round(p[1], 5), round(p[2], 5))
        k = verts.get(key)
        if k is None:
            k = verts[key] = len(pos)
            pos.append(p)
            nsum.append((0.0, 0.0, 0.0))
            fsum.append((0.0, 0.0, 0.0))
        if norm(n) > 1e-6:
            nsum[k] = add(nsum[k], unit(n))
        return k

    for i in range(32):
        g = GROUP[i]
        if g == "bottom":
            continue
        nu, nv = cuts_for(i)
        cp = control_points(i)
        sgn = signs[i]
        pts = grid(cp, nu, nv)
        ids = [[vid(PART[g], p, mul(n, sgn)) for (p, n) in row] for row in pts]
        for r in range(nv):
            for c in range(nu):
                a, b, cc, d = ids[r][c], ids[r][c + 1], ids[r + 1][c + 1], ids[r + 1][c]
                _, mid_n = evaluate(cp, (c + 0.5) / nu, (r + 0.5) / nv)
                mid_n = mul(mid_n, sgn)
                for t in ((a, b, cc), (a, cc, d)):
                    if len(set(t)) < 3:
                        continue  # collapsed at the lid's pole
                    fn = cross(sub(pos[t[1]], pos[t[0]]), sub(pos[t[2]], pos[t[0]]))
                    if norm(fn) < 1e-9:
                        continue
                    if dot(fn, mid_n) < 0:
                        t = (t[0], t[2], t[1])
                        fn = mul(fn, -1)
                    for k in t:
                        fsum[k] = add(fsum[k], fn)
                    tris.append(t)
                    counts[g] = counts.get(g, 0) + 1

    normals = []
    for k in range(len(pos)):
        n = nsum[k] if norm(nsum[k]) > 1e-6 else fsum[k]
        normals.append(unit(n))

    # Newell (x, y, z) z up -> local (x, z, -y) y up: a rotation, so the
    # winding and the outward normals survive.
    pos = [(p[0], p[2], -p[1]) for p in pos]
    normals = [(n[0], n[2], -n[1]) for n in normals]
    lo = [min(p[a] for p in pos) for a in range(3)]
    hi = [max(p[a] for p in pos) for a in range(3)]
    mid = [(lo[a] + hi[a]) * 0.5 for a in range(3)]
    s = 1.0 / (hi[1] - lo[1])
    pos = [tuple((p[a] - mid[a]) * s for a in range(3)) for p in pos]
    half = [(hi[a] - lo[a]) * 0.5 * s for a in range(3)]
    return pos, normals, tris, half, counts


def fmt(x):
    s = "%.5f" % x
    return "0.00000" if s == "-0.00000" else s


def render(pos, normals, tris, half, counts):
    out = []
    w = out.append
    w("//! GENERATED by tools/gen_teapot.py from Newell's Utah teapot patches; do")
    w("//! not edit (re-run the script). Rim, body, lid, handle and spout, no")
    w("//! bottom: %d triangles (%s)." % (len(tris), ", ".join("%s %d" % (g, counts[g]) for g in ("rim", "body", "lid", "handle", "spout"))))
    w("//! Local axes: +y up, +x towards the spout, +z = x cross y; unit height,")
    w("//! centred on the bounding box. Triangles are counter-clockwise seen from")
    w("//! outside: cross(b - a, c - a) points out. Normals are unit, outwards.")
    w("//! Plain [3]f32 rows (never @Vector in a table: thumb ABI stride bug).")
    w("")
    w("/// Half the bounding box along local x, y, z (y is 0.5: unit height).")
    w("pub const half_extent = [3]f32{ %s, %s, %s };" % tuple(fmt(h) for h in half))
    w("")
    w("pub const positions = [%d][3]f32{" % len(pos))
    for p in pos:
        w("    .{ %s, %s, %s }," % tuple(fmt(c) for c in p))
    w("};")
    w("")
    w("pub const normals = [%d][3]f32{" % len(normals))
    for n in normals:
        w("    .{ %s, %s, %s }," % tuple(fmt(c) for c in n))
    w("};")
    w("")
    w("pub const triangles = [%d][3]u16{" % len(tris))
    for t in tris:
        w("    .{ %d, %d, %d }," % t)
    w("};")
    return "\n".join(out) + "\n"


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--check", action="store_true", help="exit 1 if the committed file differs")
    ap.add_argument("--out", default=OUT, help="output path (default cart/src/render/teapot_mesh.zig)")
    a = ap.parse_args()
    pos, normals, tris, half, counts = build()
    text = render(pos, normals, tris, half, counts)
    if a.check:
        try:
            same = open(a.out).read() == text
        except OSError:
            same = False
        print("gen_teapot: %s is %s" % (os.path.relpath(a.out), "up to date" if same else "STALE (run tools/gen_teapot.py)"))
        sys.exit(0 if same else 1)
    with open(a.out, "w") as f:
        f.write(text)
    size = len(pos) * 24 + len(tris) * 6
    print("gen_teapot: %d vertices, %d triangles (%s), %d bytes of tables, half extent %s -> %s"
          % (len(pos), len(tris), ", ".join("%s %d" % kv for kv in sorted(counts.items())), size,
             " ".join(fmt(h) for h in half), os.path.relpath(a.out)))


if __name__ == "__main__":
    main()
