#!/usr/bin/env python3
"""Reference renderer for the M2 scene: PLAN.md "The M1 scene, exactly" plus
"The M2 scene, exactly", executable.

    python3 tools/reference.py --frame 0 --frame 150 --frame 300 --frame 450 --out out/
    python3 tools/reference.py --frame 0 --out out/ --glass fake --water-shadows primary_only
    python3 tools/reference.py --frame 0 --out out/ --dump-npy
    python3 tools/reference.py --frame 0 --out out/ --fps 30 --scale 2       # M2.1 variant half30

Renders frame F at 160x128 with exact float64 math (numpy sin/cos, exact
normalize), saturates, quantises in dither mode `none` and writes an 8-bit RGB
PNG to DIR/ref_FFFF.png (FFFF = zero-padded frame, matching preview.mjs's
frame_FFFF.png: frame F is the value of the cart's frame counter during the
(F+1)-th update(), i.e. 0-based update index). --dump-npy also saves the
pre-quantisation linear image (128x160x3 float64, before saturate) to
DIR/ref_FFFF.npy for debugging.

Scene: chrome sphere, glass sphere (real or fake refraction), textured shore
plane at z = 14, rippling water with sphere shadows and a scatter term, sunset
sky. The M2 knobs are flags with the PLAN defaults (--glass real,
--water-shadows all, --glass-secondary full, --fade-k 0.05); run with the
cart's shipped settings. The M2.1 variant settings (PLAN.md "M2.1 Perf
variants") are flags too: --fps N (one orbit is 30 s at every rate, so
orbit_frames = 30 N, theta = (F mod orbit_frames) / orbit_frames turns and the
water time is F / N s), --no-glass (the glass sphere and its shadow removed),
--glass-primary env (knob 4, trace.zig's env_flat) and --scale 2 (rays only at
the even pixels of the full-resolution camera, each copied to its 2x2 block). The shore texture and palette are read at run time
from cart/src/shore_texels.bin and tools/shore_palette.json (override with
--texels / --palette).

Compare against the cart with tools/check_render.mjs (see docs/RUNNING.md).
The code is vectorised: every function takes arrays of N rays (N x 3) and the
bounded recursion (depth 0..2) is done by calling trace() on the masked subset
of rays that hit each object.
"""
import argparse
import json
import os
import struct
import sys
import zlib

import numpy as np

W, H = 160, 128
TAN_H = np.tan(np.radians(30.0))              # horizontal FOV 60 degrees
HERE = os.path.dirname(os.path.abspath(__file__))
CART = os.path.dirname(HERE)

# ---------------------------------------------------------------- scene constants
SUN_L = np.array([0.40, 0.30, -0.85])
SUN_L = SUN_L / np.linalg.norm(SUN_L)         # direction toward the sun, normalised
SUN_COL = np.array([1.00, 0.85, 0.60])

HORIZON = np.array([1.00, 0.55, 0.25])
MID = np.array([0.85, 0.35, 0.40])
ZENITH = np.array([0.15, 0.20, 0.45])

# Chrome sphere
SPHERE_C = np.array([0.0, 1.0, 0.0])
SPHERE_R = 1.0
SPHERE_TINT = np.array([0.95, 0.93, 0.90])
CHROME_OPACITY = 1.0

# Glass sphere
GLASS_C = np.array([-1.9, 0.75, 1.3])
GLASS_R = 0.7
GLASS_IOR = 1.5
GLASS_TINT = np.array([0.90, 0.96, 1.00])
GLASS_F0 = 0.04
GLASS_OPACITY = 0.55
GLASS_FAR = np.array([0.45, 0.33, 0.35])      # glass reached at depth 2

# Shore: plane z = 14 facing -z, x in (-16, 16], y in [0, 4), 256 x 32 texels
SHORE_Z = 14.0
SHORE_X = 16.0
SHORE_H = 4.0
SHORE_TPU = 8.0                               # texels per world unit
TEX_W, TEX_H = 256, 32

# Water
DEEP = np.array([0.02, 0.08, 0.14])
WATER_SCATTER = 0.08 * SUN_COL                # (0.08, 0.068, 0.048)
WATER_F0 = 0.02
FADE_K = 0.05                                 # g = 1 / (1 + fade_k * dist), fade = g * g

# Ripples: (A, k.x, k.z, w)
RIPPLES = [
    (0.020, 0.90, 0.35, 0.55),
    (0.012, -0.45, 0.80, 0.80),
    (0.006, 1.70, -1.20, 1.30),
]

# Shadow casters: (centre, radius, opacity)
SHADOW_SPHERES = [
    (SPHERE_C, SPHERE_R, CHROME_OPACITY),
    (GLASS_C, GLASS_R, GLASS_OPACITY),
]

T_MIN = 1e-3
MAX_DEPTH = 2


class Config:
    """The M2 knobs (PLAN.md "Knobs"), the M2.1 variant settings (frame rate,
    glass on or off, knob 4, render scale), fade_k and the shore data."""

    def __init__(self, glass="real", water_shadows="all", glass_secondary="full", fade_k=FADE_K,
                 texels_path=None, palette_path=None, fps=20, glass_enabled=True, glass_primary="full",
                 scale=1):
        assert glass in ("real", "fake")
        assert water_shadows in ("all", "primary_only", "off")
        assert glass_secondary in ("full", "env")
        assert glass_primary in ("full", "env")
        assert fps > 0 and scale in (1, 2)
        self.glass = glass
        self.water_shadows = water_shadows
        self.glass_secondary = glass_secondary
        self.glass_primary = glass_primary
        self.glass_enabled = glass_enabled
        self.fps = fps
        self.orbit_frames = 30 * fps              # one orbit per 30 s at every frame rate
        self.scale = scale
        self.fade_k = fade_k
        # Shadow casters: the glass casts only while it exists.
        self.shadow_spheres = SHADOW_SPHERES if glass_enabled else SHADOW_SPHERES[:1]
        self.texels = load_texels(texels_path or os.path.join(CART, "cart", "src", "shore_texels.bin"))
        self.palette = load_palette(palette_path or os.path.join(HERE, "shore_palette.json"))


def load_texels(path):
    """4-bit indices as a (32, 256) array [v, u]: byte v*128 + u/2, low nibble for even u."""
    data = np.frombuffer(open(path, "rb").read(), dtype=np.uint8)
    if data.size != TEX_W * TEX_H // 2:
        raise SystemExit(f"reference: {path}: expected {TEX_W * TEX_H // 2} bytes, got {data.size}")
    rows = data.reshape(TEX_H, TEX_W // 2)
    tex = np.empty((TEX_H, TEX_W), dtype=np.uint8)
    tex[:, 0::2] = rows & 0x0F
    tex[:, 1::2] = rows >> 4
    return tex


def load_palette(path):
    with open(path) as f:
        pal = np.array(json.load(f), dtype=np.float64)
    if pal.shape != (16, 3):
        raise SystemExit(f"reference: {path}: expected 16 [r, g, b] entries, got shape {pal.shape}")
    return pal


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


def refract(i, n, eta, c):
    """PLAN: k = max(0, 1 - eta^2 (1 - c^2)); eta I + (eta c - sqrt(k)) N, with c = -dot(I, N)."""
    k = np.maximum(0.0, 1.0 - eta * eta * (1.0 - c * c))
    return eta * i + (eta * c - np.sqrt(k))[:, None] * n


def schlick(cos_theta, f0):
    return f0 + (1.0 - f0) * (1.0 - cos_theta) ** 5


# ---------------------------------------------------------------- sky and env
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


def env(o, d, cfg):
    """Shore colour where the shore test hits, else sky(d). Tests nothing else."""
    ts, idx = hit_shore(o, d, cfg)
    col = sky(d)
    hit = np.isfinite(ts)
    col[hit] = cfg.palette[idx[hit]]
    return col


def env_flat(o, d, cfg):
    """Knob 4's lookup (trace.zig env_flat): env() for rays with d.y >= 0; a
    downward ray sees flat, unshadowed, unrippled water reflecting the sky (no
    shore, no spheres). The reflected direction is (d.x, max(-d.y, 0.02), d.z),
    not renormalised, as in the cart."""
    col = np.empty((len(d), 3))
    down = d[:, 1] < 0.0
    up = ~down
    if up.any():
        col[up] = env(o[up], d[up], cfg)
    if down.any():
        dd = d[down]
        r = np.stack([dd[:, 0], np.maximum(-dd[:, 1], 0.02), dd[:, 2]], axis=-1)
        f = schlick(-dd[:, 1], WATER_F0)
        spec = np.maximum(0.0, dot(r, SUN_L))
        for _ in range(6):                      # ^64
            spec = spec * spec
        col[down] = lerp(DEEP + WATER_SCATTER, sky(r), f) + SUN_COL * (0.5 * spec)[:, None]
    return col


# ---------------------------------------------------------------- intersections
def hit_sphere(o, d, c=SPHERE_C, r=SPHERE_R):
    """Nearest t > T_MIN of the ray against the sphere (c, r), np.inf where there is none."""
    oc = o - c
    b = dot(oc, d)                              # half-b form; |d| = 1 so a = 1
    cc = dot(oc, oc) - r * r
    disc = b * b - cc
    ok = disc >= 0.0
    sq = np.sqrt(np.where(ok, disc, 0.0))
    t0 = -b - sq
    t1 = -b + sq
    t = np.where(t0 > T_MIN, t0, np.where(t1 > T_MIN, t1, np.inf))
    return np.where(ok, t, np.inf)


def hit_shore(o, d, cfg):
    """(t, texel index) of the ray against the shore; t = np.inf where it misses or
    the texel is transparent (index 0). Only rays with d.z > 0 can hit (the plane
    faces -z), and only in front of the origin (t > T_MIN)."""
    n = len(d)
    fwd = d[:, 2] > 0.0
    safe_dz = np.where(fwd, d[:, 2], 1.0)
    ts = (SHORE_Z - o[:, 2]) / safe_dz
    xs = o[:, 0] + d[:, 0] * ts
    ys = o[:, 1] + d[:, 1] * ts
    inside = fwd & (ts > T_MIN) & (ys >= 0.0) & (ys < SHORE_H) & (xs > -SHORE_X) & (xs <= SHORE_X)
    idx = np.zeros(n, dtype=np.intp)
    if inside.any():
        u = np.minimum(TEX_W - 1, np.floor((SHORE_X - xs[inside]) * SHORE_TPU)).astype(np.intp)
        v = np.minimum(TEX_H - 1, np.floor((SHORE_H - ys[inside]) * SHORE_TPU)).astype(np.intp)
        idx[inside] = cfg.texels[v, u]
    hit = inside & (idx != 0)
    return np.where(hit, ts, np.inf), idx


def hit_water(o, d):
    """t of the ray against the plane y = 0 where d.y < 0, np.inf elsewhere."""
    down = d[:, 1] < 0.0
    safe_dy = np.where(down, d[:, 1], -1.0)
    return np.where(down, -o[:, 1] / safe_dy, np.inf)


def ripple_normal(p, dist, t, fade_k=FADE_K):
    """Water normal at p (y = 0); dist is the distance from the ray origin."""
    g = 1.0 / (1.0 + fade_k * dist)
    fade = g * g
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


def water_shadow(p, spheres=SHADOW_SPHERES):
    """Product over the spheres of the soft shadow factor at water point p."""
    sh = np.ones(len(p))
    for c, rs, a in spheres:
        oc = c - p
        b = dot(oc, SUN_L)
        q2 = dot(oc, oc) - b * b
        s = 1.0 - a * (1.0 - smoothstep(0.72 * rs * rs, 1.21 * rs * rs, q2))
        sh *= np.where(b <= 0.0, 1.0, s)
    return sh


# ---------------------------------------------------------------- shading
def shade_glass(o, d, ts, depth, t, cfg):
    """Glass sphere hit from outside at o + d ts (PLAN "Glass shading")."""
    if depth >= MAX_DEPTH:
        return np.broadcast_to(GLASS_FAR, d.shape).copy()
    p = o + d * ts[:, None]
    n = (p - GLASS_C) / GLASS_R
    c = -dot(d, n)
    f = schlick(c, GLASS_F0)[:, None]
    r = reflect(d, n)
    d1 = normalize(refract(d, n, 1.0 / GLASS_IOR, c))       # entering
    if cfg.glass == "real":
        t1 = -2.0 * dot(p - GLASS_C, d1)
        q = p + d1 * t1[:, None]                            # exit point
        n2 = (q - GLASS_C) / GLASS_R
        c2 = dot(d1, n2)
        d2 = normalize(refract(d1, -n2, GLASS_IOR, c2))     # leaving
        o2 = q
    else:                                                   # fake: no exit intersection
        d2 = d1
        o2 = p
    if depth == 1 and cfg.glass_secondary == "env":
        refl = env(p, r, cfg)
        trans = env(o2, d2, cfg)
    elif depth == 0 and cfg.glass_primary == "env":
        refl = env_flat(p, r, cfg)
        trans = env_flat(o2, d2, cfg)
    else:
        refl = trace(p, r, depth + 1, t, cfg, skip_glass=True)
        trans = trace(o2, d2, depth + 1, t, cfg, skip_glass=True)
    return f * refl + (1.0 - f) * GLASS_TINT * trans


def shade_chrome(o, d, ts, depth, t, cfg):
    p = o + d * ts[:, None]
    n = (p - SPHERE_C) / SPHERE_R
    if depth < MAX_DEPTH:
        return SPHERE_TINT * trace(p, reflect(d, n), depth + 1, t, cfg)
    lam = 0.25 + 0.75 * np.maximum(0.0, dot(n, SUN_L))
    return SPHERE_TINT * SUN_COL * lam[:, None]


def shade_water(o, d, tw, depth, t, cfg):
    p = o + d * tw[:, None]
    dist = np.linalg.norm(p - o, axis=-1)       # from the camera at depth 0, else the ray origin
    n = ripple_normal(p, dist, t, cfg.fade_k)
    r = reflect(d, n)
    r[:, 1] = np.maximum(r[:, 1], 0.02)         # if r.y < 0.02: r.y = 0.02
    r = normalize(r)
    refl = trace(p, r, depth + 1, t, cfg) if depth < MAX_DEPTH else env(p, r, cfg)
    f = schlick(np.maximum(0.0, dot(-d, n)), WATER_F0)
    if cfg.water_shadows == "all" or (cfg.water_shadows == "primary_only" and depth == 0):
        sh = water_shadow(p, cfg.shadow_spheres)
    else:
        sh = np.ones(len(p))
    base = DEEP + WATER_SCATTER * sh[:, None]
    spec = np.maximum(0.0, dot(r, SUN_L))
    for _ in range(6):                          # ^64, six squarings
        spec = spec * spec
    spec = spec * sh
    return lerp(base, refl, f) + SUN_COL * (0.5 * spec)[:, None]


def trace(o, d, depth, t, cfg, skip_glass=False):
    """Linear RGB for N rays (o, d: N x 3, d unit). depth 0..2, t = frame / fps.
    skip_glass: the rays start on the glass sphere (reflection, exit or fake
    refraction), which they cannot hit again, so it is not tested; also set
    for every ray when the glass is disabled (--no-glass)."""
    skip_glass = skip_glass or not cfg.glass_enabled
    n_rays = len(d)
    col = np.zeros((n_rays, 3))
    if n_rays == 0:
        return col

    # Nearest hit; ties go to the earlier column (chrome, glass, shore, water),
    # as M1's `ts <= tw`.
    t_all = np.stack([
        hit_sphere(o, d, SPHERE_C, SPHERE_R),
        np.full(n_rays, np.inf) if skip_glass else hit_sphere(o, d, GLASS_C, GLASS_R),
        hit_shore(o, d, cfg)[0],
        hit_water(o, d),
    ], axis=-1)
    which = np.argmin(t_all, axis=-1)
    tmin = t_all[np.arange(n_rays), which]
    which = np.where(np.isfinite(tmin), which, 4)          # 4 = miss

    shaders = [shade_chrome, shade_glass, None, shade_water]
    for k, fn in enumerate(shaders):
        m = which == k
        if not m.any():
            continue
        if fn is None:                                      # shore: palette colour, already lit
            col[m] = cfg.palette[hit_shore(o[m], d[m], cfg)[1]]
        else:
            col[m] = fn(o[m], d[m], tmin[m], depth, t, cfg)
    m = which == 4
    if m.any():
        col[m] = sky(d[m])
    return col


# ---------------------------------------------------------------- camera and frame
def camera(frame, orbit_frames=600):
    theta = (frame % orbit_frames) / orbit_frames   # turns; one orbit per 30 s
    eye = np.array([4.5 * sin_turns(theta), 1.6, 4.5 * cos_turns(theta)])
    target = np.array([0.0, 0.9, 0.0])
    fwd = target - eye
    fwd /= np.linalg.norm(fwd)
    right = np.cross(fwd, [0.0, 1.0, 0.0])
    right /= np.linalg.norm(right)
    up = np.cross(right, fwd)
    return eye, fwd, right, up


def render(frame, cfg=None):
    """Linear RGB image (H x W x 3, float64), before saturate. With scale 2
    only the even (x, y) pixels are traced, with exactly the full-resolution
    pixel's ray, and each is copied to its 2x2 block."""
    cfg = cfg or Config()
    t = frame / cfg.fps
    eye, fwd, right, up = camera(frame, cfg.orbit_frames)
    s = cfg.scale
    x = np.arange(0, W, s)
    y = np.arange(0, H, s)
    u = (x + 0.5 - 80.0) / 80.0 * TAN_H         # (W,)
    v = -(y + 0.5 - 64.0) / 80.0 * TAN_H        # (H,)
    dirs = fwd + right * u[None, :, None] + up * v[:, None, None]   # (H, W, 3)
    d = normalize(dirs.reshape(-1, 3))
    o = np.broadcast_to(eye, d.shape).copy()
    img = trace(o, d, 0, t, cfg).reshape(len(y), len(x), 3)
    if s > 1:
        img = np.repeat(np.repeat(img, s, axis=0), s, axis=1)
    return img


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
    ap.add_argument("--glass", choices=["real", "fake"], default="real",
                    help="knob 1: real exit refraction or fake single refraction (default real)")
    ap.add_argument("--water-shadows", choices=["all", "primary_only", "off"], default="all",
                    help="knob 2: which water hits get sphere shadows (default all)")
    ap.add_argument("--glass-secondary", choices=["full", "env"], default="full",
                    help="knob 3: glass at depth 1 traces its rays (full) or looks up env() (default full)")
    ap.add_argument("--glass-primary", choices=["full", "env"], default="full",
                    help="knob 4: glass seen by primary rays traces its rays (full) or looks them up in "
                         "env_flat (default full)")
    ap.add_argument("--no-glass", action="store_true",
                    help="remove the glass sphere everywhere, its shadow included (variant cut20)")
    ap.add_argument("--fps", type=int, default=20,
                    help="frame rate: orbit_frames = 30 * fps, water t = frame / fps (default 20)")
    ap.add_argument("--scale", type=int, choices=[1, 2], default=1,
                    help="render scale: 2 traces the even pixels and fills 2x2 blocks (default 1)")
    ap.add_argument("--fade-k", type=float, default=FADE_K, help=f"ripple fade constant (default {FADE_K})")
    ap.add_argument("--texels", default=None, help="shore texels (default cart/src/shore_texels.bin)")
    ap.add_argument("--palette", default=None, help="shore palette JSON (default tools/shore_palette.json)")
    ap.add_argument("--dump-npy", action="store_true", help="also save the float image as ref_FFFF.npy")
    args = ap.parse_args()
    if args.fps <= 0:
        ap.error("--fps must be > 0")
    cfg = Config(args.glass, args.water_shadows, args.glass_secondary, args.fade_k, args.texels, args.palette,
                 fps=args.fps, glass_enabled=not args.no_glass, glass_primary=args.glass_primary,
                 scale=args.scale)
    os.makedirs(args.out, exist_ok=True)
    print(f"reference: glass={'off' if args.no_glass else cfg.glass} water_shadows={cfg.water_shadows} "
          f"glass_secondary={cfg.glass_secondary} glass_primary={cfg.glass_primary} fade_k={cfg.fade_k:g} "
          f"fps={cfg.fps} (orbit {cfg.orbit_frames} frames) scale={cfg.scale}", file=sys.stderr)
    for frame in args.frame:
        if frame < 0:
            ap.error("--frame must be >= 0")
        img = render(frame, cfg)
        name = os.path.join(args.out, f"ref_{frame:04d}")
        write_png(name + ".png", quantise_none(img))
        if args.dump_npy:
            np.save(name + ".npy", img)
        print(f"reference: wrote {name}.png", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
