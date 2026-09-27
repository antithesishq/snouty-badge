#!/usr/bin/env python3
"""Reference renderer for the M1 scene: PLAN.md "The M1 scene, exactly", executable.

    python3 tools/reference.py --frame 0 --frame 300 --out out/
    python3 tools/reference.py --frame 0 --out out/ --dump-npy

Renders frame F at 160x128 with exact float64 math (numpy sin/cos, exact
normalize), saturates, quantises in dither mode `none` and writes an 8-bit RGB
PNG to DIR/ref_FFFF.png (FFFF = zero-padded frame, matching preview.mjs's
frame_FFFF.png: frame F is the value of the cart's frame counter during the
(F+1)-th update(), i.e. 0-based update index). --dump-npy also saves the
pre-quantisation linear image (128x160x3 float64, before saturate) to
DIR/ref_FFFF.npy for debugging.

Compare against the cart with tools/check_render.mjs (see docs/RUNNING.md).
The code is vectorised: every function takes arrays of N rays (N x 3) and the
bounded recursion (depth 0..2) is done by calling trace() on the masked subset
of rays that hit the sphere or the water.
"""
import argparse
import os
import sys
import zlib
import struct

import numpy as np

W, H = 160, 128
TAN_H = np.tan(np.radians(30.0))              # horizontal FOV 60 degrees

# ---------------------------------------------------------------- scene constants
SUN_L = np.array([0.40, 0.30, -0.85])
SUN_L = SUN_L / np.linalg.norm(SUN_L)         # direction toward the sun, normalised
SUN_COL = np.array([1.00, 0.85, 0.60])

HORIZON = np.array([1.00, 0.55, 0.25])
MID = np.array([0.85, 0.35, 0.40])
ZENITH = np.array([0.15, 0.20, 0.45])

SPHERE_C = np.array([0.0, 1.0, 0.0])
SPHERE_R = 1.0
SPHERE_TINT = np.array([0.95, 0.93, 0.90])

DEEP = np.array([0.02, 0.08, 0.14])
WATER_F0 = 0.02

# Ripples: (A, k.x, k.z, w)
RIPPLES = [
    (0.020, 0.90, 0.35, 0.55),
    (0.012, -0.45, 0.80, 0.80),
    (0.006, 1.70, -1.20, 1.30),
]

T_MIN = 1e-3
MAX_DEPTH = 2


# ---------------------------------------------------------------- helpers
def sin_turns(x):
    return np.sin(2.0 * np.pi * x)


def cos_turns(x):
    return np.cos(2.0 * np.pi * x)


def dot(a, b):
    """Row-wise dot product of (N,3) arrays (or an (N,3) array and a 3-vector)."""
    return np.sum(a * b, axis=-1)


def normalize(v):
    return v / np.linalg.norm(v, axis=-1, keepdims=True)


def clamp01(x):
    return np.clip(x, 0.0, 1.0)


def lerp(a, b, t):
    """a + (b - a) * t; t is (N,) and broadcast over the colour channels."""
    return a + (b - a) * np.asarray(t)[..., None]


def smoothstep(e0, e1, x):
    t = clamp01((x - e0) / (e1 - e0))
    return t * t * (3.0 - 2.0 * t)


def reflect(d, n):
    return d - 2.0 * dot(d, n)[..., None] * n


def schlick(cos_theta, f0):
    return f0 + (1.0 - f0) * (1.0 - cos_theta) ** 5


# ---------------------------------------------------------------- sky
def sky(d):
    h = clamp01(d[:, 1])
    grad = np.where((h < 0.3)[:, None],
                    lerp(HORIZON, MID, h / 0.3),
                    lerp(MID, ZENITH, (h - 0.3) / 0.7))
    s = dot(d, SUN_L)
    disc = smoothstep(0.9950, 0.9995, s)
    glow = smoothstep(0.90, 1.00, s)
    glow = glow * glow
    return grad + SUN_COL * (disc + 0.4 * glow)[:, None]


# ---------------------------------------------------------------- intersections
def hit_sphere(o, d):
    """Nearest t > T_MIN of the ray against the sphere, np.inf where there is none."""
    oc = o - SPHERE_C
    b = dot(oc, d)                              # half-b form; |d| = 1 so a = 1
    c = dot(oc, oc) - SPHERE_R * SPHERE_R
    disc = b * b - c
    ok = disc >= 0.0
    sq = np.sqrt(np.where(ok, disc, 0.0))
    t0 = -b - sq
    t1 = -b + sq
    t = np.where(t0 > T_MIN, t0, np.where(t1 > T_MIN, t1, np.inf))
    return np.where(ok, t, np.inf)


def hit_water(o, d):
    """t of the ray against the plane y = 0 where d.y < 0, np.inf elsewhere."""
    down = d[:, 1] < 0.0
    safe_dy = np.where(down, d[:, 1], -1.0)
    return np.where(down, -o[:, 1] / safe_dy, np.inf)


def ripple_normal(p, dist, t):
    """Water normal at p (y = 0); dist is the distance from the ray origin."""
    fade = 1.0 / (1.0 + 0.06 * dist)
    dhdx = np.zeros(len(p))
    dhdz = np.zeros(len(p))
    for a, kx, kz, w in RIPPLES:
        phase = kx * p[:, 0] + kz * p[:, 2] + w * t      # in turns
        c = cos_turns(phase)
        dhdx += a * kx * 2.0 * np.pi * c
        dhdz += a * kz * 2.0 * np.pi * c
    dhdx *= fade
    dhdz *= fade
    return normalize(np.stack([-dhdx, np.ones(len(p)), -dhdz], axis=-1))


# ---------------------------------------------------------------- shading
def trace(o, d, depth, t):
    """Linear RGB for N rays (o, d: N x 3, d unit). depth 0..2, t = frame / 20."""
    n_rays = len(d)
    col = np.zeros((n_rays, 3))
    if n_rays == 0:
        return col

    ts = hit_sphere(o, d)
    tw = hit_water(o, d)
    sphere = np.isfinite(ts) & (ts <= tw)       # sphere is the nearest hit
    water = np.isfinite(tw) & ~sphere           # d.y < 0 and no sphere hit closer
    miss = ~sphere & ~water

    # hit sphere
    if sphere.any():
        so, sd = o[sphere], d[sphere]
        p = so + sd * ts[sphere][:, None]
        n = (p - SPHERE_C) / SPHERE_R
        if depth < MAX_DEPTH:
            col[sphere] = SPHERE_TINT * trace(p, reflect(sd, n), depth + 1, t)
        else:
            lam = 0.25 + 0.75 * np.maximum(0.0, dot(n, SUN_L))
            col[sphere] = SPHERE_TINT * SUN_COL * lam[:, None]

    # hit water
    if water.any():
        wo, wd = o[water], d[water]
        twm = tw[water]
        p = wo + wd * twm[:, None]
        dist = np.linalg.norm(p - wo, axis=-1)  # from the camera at depth 0, else the ray origin
        n = ripple_normal(p, dist, t)
        r = reflect(wd, n)
        r[:, 1] = np.maximum(r[:, 1], 0.02)     # if r.y < 0.02: r.y = 0.02
        r = normalize(r)
        refl = trace(p, r, depth + 1, t) if depth < MAX_DEPTH else sky(r)
        f = schlick(np.maximum(0.0, dot(-wd, n)), WATER_F0)
        spec = np.maximum(0.0, dot(r, SUN_L))
        for _ in range(6):                      # ^64, six squarings
            spec = spec * spec
        col[water] = lerp(DEEP, refl, f) + SUN_COL * (0.5 * spec)[:, None]

    # miss
    if miss.any():
        col[miss] = sky(d[miss])

    return col


# ---------------------------------------------------------------- camera and frame
def camera(frame):
    theta = frame / 600.0                       # turns; one orbit per 30 s at 20 fps
    eye = np.array([4.5 * sin_turns(theta), 1.6, 4.5 * cos_turns(theta)])
    target = np.array([0.0, 0.9, 0.0])
    fwd = target - eye
    fwd /= np.linalg.norm(fwd)
    right = np.cross(fwd, [0.0, 1.0, 0.0])
    right /= np.linalg.norm(right)
    up = np.cross(right, fwd)
    return eye, fwd, right, up


def render(frame):
    """Linear RGB image (H x W x 3, float64), before saturate."""
    t = frame / 20.0
    eye, fwd, right, up = camera(frame)
    x = np.arange(W)
    y = np.arange(H)
    u = (x + 0.5 - 80.0) / 80.0 * TAN_H         # (W,)
    v = -(y + 0.5 - 64.0) / 80.0 * TAN_H        # (H,)
    dirs = fwd + right * u[None, :, None] + up * v[:, None, None]   # (H, W, 3)
    d = normalize(dirs.reshape(-1, 3))
    o = np.broadcast_to(eye, d.shape).copy()
    return trace(o, d, 0, t).reshape(H, W, 3)


def quantise_none(img):
    """Mode `none`: saturate, floor(c * max + 1e-4), expand to 8 bits (r5 * 255 / 31, rounded)."""
    c = clamp01(img)
    maxv = np.array([31.0, 63.0, 31.0])
    q = np.floor(c * maxv + 1e-4)
    return np.rint(q * 255.0 / maxv).astype(np.uint8)


# ---------------------------------------------------------------- PNG
def write_png(path, rgb):
    h, w, _ = rgb.shape
    raw = b"".join(b"\x00" + rgb[yy].tobytes() for yy in range(h))

    def chunk(tag, data):
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

    ihdr = struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)
    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr) + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b""))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--frame", type=int, action="append", required=True, help="frame index (repeatable)")
    ap.add_argument("--out", required=True, help="output directory")
    ap.add_argument("--dump-npy", action="store_true", help="also save the float image as ref_FFFF.npy")
    args = ap.parse_args()
    os.makedirs(args.out, exist_ok=True)
    for frame in args.frame:
        if frame < 0:
            ap.error("--frame must be >= 0")
        img = render(frame)
        name = os.path.join(args.out, f"ref_{frame:04d}")
        write_png(name + ".png", quantise_none(img))
        if args.dump_npy:
            np.save(name + ".npy", img)
        print(f"reference: wrote {name}.png", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
