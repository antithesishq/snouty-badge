#!/usr/bin/env python3
"""Reference renderer for the M3 scene: PLAN.md "The M1 scene, exactly",
"The M2 scene, exactly", M2.2 "The scene changes, exactly" and M3 "The M3
scene, exactly", executable.

    python3 tools/reference.py --frame 0 --frame 150 --frame 300 --frame 450 --out out/
    python3 tools/reference.py --variant cut20 --preset noon --t 150 --out out/          # one M3 view
    python3 tools/reference.py --variant cut20 --view storm:300:300:1.8 --out out/       # preset:t:orbit:height
    python3 tools/reference.py --variant cut20 --frame 300 --motion 0 --out out/         # M2.2 frame 300
    python3 tools/reference.py --frame 0 --out out/ --fps 30 --scale 2                   # M2.1 variant half30

A view is what the cart's trace.View holds (PLAN.md M3 "Fixed interfaces"):
the preset, the scene time t in frames (water, logo spin, bob, sun drift;
s = t / fps seconds), the camera angle as an orbit index (theta =
orbit / orbit_frames turns) and the eye height in metres. --frame F is the
view (preset, t = F, orbit = F mod orbit_frames, height) and writes
DIR/ref_FFFF.png (FFFF = zero-padded F, matching preview.mjs's
frame_FFFF.png). --t T [--orbit O] and every --view P:T[:O[:H]] write
DIR/ref_<preset>_t<TTTT>_o<OOOO>_h<MMMM>.png (height in mm), or --name.
--dump-npy also saves the pre-quantisation linear image (128x160x3 float64,
before saturate) as the same name with .npy.

Each view is rendered with exact float64 math (numpy sin/cos, exact
normalize), saturated, quantised in dither mode `none` and written as an
8-bit RGB PNG. The one place the reference follows the cart's f32 rounding
is the runtime height basis (PLAN.md M3 "Camera height"): at a height other
than the default 1.6, the height is rounded to f32 and the basis scalars
basis_h = R / L and basis_y = (ty - h) / L are computed in f32 as
camera.zig's closed form does at run time (L = sqrt(R^2 + (ty - h)^2)); the
rest stays f64. At the default height the M2.2 f64 camera is used unchanged.

--motion 0 turns the M3 motion off (no bob, sun drift, rings or stripes);
with --motion 0, --preset sunset and the default height the output is
byte-identical to the M2.2 reference (the legacy identity). --motion 1 is
the default (the M3 cart). The motion knobs --rings, --stripes, --sun-drift
(0/1) only act with --motion 1; --stripes defaults to 0 since the cart
dropped the chrome stripes (2026-09-30, Adrian: they read as artifacting,
not chrome; PLAN.md M3.1) and the flag only keeps the old formula for
comparison. --noon-shadows and --noon-third-sphere (0/1) are preset
content and act either way. Presets (--preset
sunset|midnight|noon|storm or 0..3) set the sun direction and colour, the
sky gradient, disc and water specular on or off, the ripple amplitude
scale, the shore palette tint, the spheres (glass in sunset where the
variant has it, a matte sphere in midnight and noon, a small chrome sphere
in noon) and the water shadows (sunset: the variant's; noon: primary rays;
midnight, storm: off).

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
--texels / --palette); the shore's height is the file's row count / 8 (48
rows, y in [0, 6) for M2.2; the M2 file's 32 rows still give y in [0, 4)).

M2.2 adds the spinning Iris logo (PLAN.md M2.2 "Iris logo": slab-extruded
mark at (-15.5, 1.8, 12) since M3.1, six turns per orbit, K samples along the slab chord).
Primary rays test it, water reflections at every depth if --iris-in-water 1
(knob 6), chrome reflections (both chrome spheres) if --iris-in-chrome 1
(knob 5), rays leaving the glass never. --iris-samples K is knob 7,
--no-iris removes it; with --no-iris and the M2 texel file the output is
byte-identical to the M2.1 reference.

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
SUN_L = SUN_L / np.linalg.norm(SUN_L)         # direction toward the sun, normalised (sunset)
SUN_COL = np.array([1.00, 0.85, 0.60])

HORIZON = np.array([1.00, 0.55, 0.25])
MID = np.array([0.85, 0.35, 0.40])
ZENITH = np.array([0.15, 0.20, 0.45])

# Camera (PLAN.md M1 "Camera", M3 "Camera height")
ORBIT_R = 4.5
DEFAULT_HEIGHT = 1.6
MIN_HEIGHT = 1.0
MAX_HEIGHT = 1.8
TARGET = np.array([0.0, 0.9, 0.0])

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

# M3: matte sphere (the glass slot), small chrome sphere (noon).
MATTE_C = GLASS_C
MATTE_R = GLASS_R
MATTE_ALBEDO = np.array([0.60, 0.55, 0.50])
MATTE_OPACITY = 1.0                           # opaque; the PLAN gives no value
SMALL_C = np.array([1.8, 0.5, 1.6])
SMALL_R = 0.5
SMALL_OPACITY = 1.0

# Shore: plane z = 14 facing -z, x in (-16, 16], y in [0, rows / 8), 256 x rows
# texels (M2.2: 48 rows, y in [0, 6); M2: 32 rows, y in [0, 4)). The row count
# comes from the texel file's size (Config.tex_h, Config.shore_h).
SHORE_Z = 14.0
SHORE_X = 16.0
SHORE_TPU = 8.0                               # texels per world unit
TEX_W = 256

# Iris logo (PLAN.md M2.2 "Iris logo"): a slab-extruded mark standing on the water.
IRIS_C = np.array([-15.5, 1.8, 12.0])
IRIS_S = 1.5                                  # half-size: the mark's U, V in [-1, 1]
IRIS_HT = 0.12                                # half-thickness (world units)
IRIS_R = 1.57                                 # bounding sphere radius
IRIS_COL = np.array([1.0, 0.3467, 0.2831])    # linear of sRGB (255, 159, 145)
IRIS_SPIN = 6                                 # turns per orbit

# Water
DEEP = np.array([0.02, 0.08, 0.14])
WATER_SCATTER = 0.08 * SUN_COL                # (0.08, 0.068, 0.048); the same in every preset
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

# M3 motion (PLAN.md M3 "Motion")
BOB_AMP = 0.2                                 # y = y0 + 0.2 + 0.2 sin_turns(s / 10 + phase)
BOB_PERIOD = 10.0
BOB_PHASE = (0.0, 0.5, 0.25)                  # chrome, second sphere (glass or matte), small chrome
DRIFT_DEG = 8.0                               # L about +y by 8 deg * sin_turns(s / 60)
DRIFT_PERIOD = 60.0
RING_A = 0.006
RING_K = 1.0 / 0.6
RING_W = 1.3
RING_R = 3.0
STRIPE_FREQ = 3.0
STRIPE_DEPTH = 0.12
STRIPE_PERIOD = 20.0                          # a = s / 20 turns


def _unit(v):
    v = np.array(v, dtype=np.float64)
    return v / np.linalg.norm(v)


# PLAN.md M3 "Presets", in the cart's enum order (scene.Preset: sunset 0,
# midnight 1, noon 2, storm 3). spheres: the sphere kinds after the chrome
# ("second" is the glass where the variant has it); shadows: "variant" (the
# --water-shadows setting), "primary" (noon: depth-0 water hits, knob
# noon_shadows) or "off".
PRESET_NAMES = ["sunset", "midnight", "noon", "storm"]
PRESETS = {
    "sunset": dict(L=SUN_L, sun_col=SUN_COL, disc=True, spec=True,
                   horizon=HORIZON, mid=MID, zenith=ZENITH, amp=1.0, tint=np.array([1.0, 1.0, 1.0]),
                   second="glass", small=False, shadows="variant"),
    "midnight": dict(L=_unit([-0.40, 0.35, -0.85]), sun_col=np.array([0.55, 0.62, 0.80]), disc=True, spec=True,
                     horizon=np.array([0.06, 0.08, 0.18]), mid=np.array([0.03, 0.04, 0.12]),
                     zenith=np.array([0.01, 0.01, 0.05]), amp=0.5, tint=np.array([0.45, 0.50, 0.70]),
                     second="matte", small=False, shadows="off"),
    "noon": dict(L=_unit([0.30, 0.85, -0.43]), sun_col=np.array([1.00, 0.97, 0.92]), disc=True, spec=True,
                 horizon=np.array([0.70, 0.82, 0.95]), mid=np.array([0.45, 0.65, 0.92]),
                 zenith=np.array([0.20, 0.40, 0.85]), amp=0.8, tint=np.array([1.05, 1.02, 1.00]),
                 second="matte", small=True, shadows="primary"),
    "storm": dict(L=SUN_L, sun_col=np.array([0.40, 0.40, 0.45]), disc=False, spec=False,
                  horizon=np.array([0.35, 0.36, 0.40]), mid=np.array([0.25, 0.26, 0.30]),
                  zenith=np.array([0.12, 0.13, 0.16]), amp=2.5, tint=np.array([0.50, 0.50, 0.55]),
                  second=None, small=False, shadows="off"),
}

T_MIN = 1e-3
MAX_DEPTH = 2


class Sphere:
    """One sphere of the current view: kind is chrome, glass, matte or small
    (the small chrome sphere); c is the centre after the bob."""

    def __init__(self, kind, c, r, opacity):
        self.kind = kind
        self.c = np.array(c, dtype=np.float64)
        self.r = r
        self.opacity = opacity


class Config:
    """The M2 knobs (PLAN.md "Knobs"), the M2.1 variant settings (frame rate,
    glass on or off, knob 4, render scale), fade_k, the shore data, the M3
    knobs and the per-view state set by set_view()."""

    def __init__(self, glass="real", water_shadows="all", glass_secondary="full", fade_k=FADE_K,
                 texels_path=None, palette_path=None, fps=20, glass_enabled=True, glass_primary="full",
                 scale=1, iris=True, iris_in_chrome=True, iris_in_water=True, iris_samples=4,
                 motion=True, rings=True, stripes=False, sun_drift=True, noon_shadows=True,
                 noon_third_sphere=True):
        assert glass in ("real", "fake")
        assert water_shadows in ("all", "primary_only", "off")
        assert glass_secondary in ("full", "env")
        assert glass_primary in ("full", "env")
        assert fps > 0 and scale in (1, 2)
        assert iris_samples >= 2
        self.glass = glass
        self.water_shadows = water_shadows
        self.glass_secondary = glass_secondary
        self.glass_primary = glass_primary
        self.glass_enabled = glass_enabled
        self.fps = fps
        self.orbit_frames = 30 * fps              # one orbit per 30 s at every frame rate
        self.scale = scale
        self.fade_k = fade_k
        self.texels = load_texels(texels_path or os.path.join(CART, "cart", "src", "shore_texels.bin"))
        self.tex_h = self.texels.shape[0]
        self.shore_h = self.tex_h / SHORE_TPU
        self.base_palette = load_palette(palette_path or os.path.join(HERE, "shore_palette.json"))
        # M2.2 knobs 5-7 and --no-iris. The per-frame spin is set by set_view().
        self.iris = iris
        self.iris_in_chrome = iris and iris_in_chrome
        self.iris_in_water = iris and iris_in_water
        self.iris_samples = iris_samples
        # M3 knobs (PLAN.md M3 "Knobs"): motion is the master switch.
        self.motion = motion
        self.rings = motion and rings
        self.stripes = motion and stripes
        self.sun_drift = motion and sun_drift
        self.noon_shadows = noon_shadows
        self.noon_third_sphere = noon_third_sphere
        self.set_frame(0)

    def set_frame(self, frame, preset="sunset", height=DEFAULT_HEIGHT):
        """The legacy frame F: t = F, orbit = F mod orbit_frames."""
        self.set_view(preset, frame, frame % self.orbit_frames, height)

    def set_view(self, preset, t, orbit, height=DEFAULT_HEIGHT):
        """Everything that depends on the view: preset constants, bob, drift,
        rings, stripes, the logo spin, the camera."""
        if isinstance(preset, int):
            preset = PRESET_NAMES[preset]
        p = PRESETS[preset]
        self.preset = preset
        self.frame_t = t
        self.orbit = orbit % self.orbit_frames
        self.t = t / self.fps                     # water time in seconds (M2.1: frame / fps)
        s = self.t
        # Logo spin: phi = 2 pi ((6 t) mod orbit_frames) / orbit_frames.
        phi = 2.0 * np.pi * ((IRIS_SPIN * t) % self.orbit_frames) / self.orbit_frames
        sn, cs = np.sin(phi), np.cos(phi)
        self.iris_n = np.array([-sn, 0.0, -cs])   # faces the lake at phi = 0
        self.iris_eu = np.array([-cs, 0.0, sn])   # reads left to right from the lake
        # Sun: L rotated about +y (right-handed: x' = x cos + z sin, z' = -x sin + z cos).
        L = p["L"]
        if self.sun_drift:
            a = np.radians(DRIFT_DEG) * sin_turns(s / DRIFT_PERIOD)
            ca, sa = np.cos(a), np.sin(a)
            L = np.array([L[0] * ca + L[2] * sa, L[1], -L[0] * sa + L[2] * ca])
        self.L = L
        self.sun_col = p["sun_col"]
        self.disc = p["disc"]
        self.water_spec = p["spec"]
        self.horizon, self.mid, self.zenith = p["horizon"], p["mid"], p["zenith"]
        self.ripples = RIPPLES if p["amp"] == 1.0 else [(a * p["amp"], kx, kz, w) for a, kx, kz, w in RIPPLES]
        self.palette = self.base_palette if np.all(p["tint"] == 1.0) else np.minimum(1.0, self.base_palette * p["tint"])
        # Spheres, in hit-test order: chrome, second (glass or matte), small chrome.
        spheres = [Sphere("chrome", SPHERE_C, SPHERE_R, CHROME_OPACITY)]
        if p["second"] == "glass" and self.glass_enabled:
            spheres.append(Sphere("glass", GLASS_C, GLASS_R, GLASS_OPACITY))
        elif p["second"] == "matte":
            spheres.append(Sphere("matte", MATTE_C, MATTE_R, MATTE_OPACITY))
        if p["small"] and self.noon_third_sphere:
            spheres.append(Sphere("small", SMALL_C, SMALL_R, SMALL_OPACITY))
        if self.motion:
            phase = {"chrome": BOB_PHASE[0], "glass": BOB_PHASE[1], "matte": BOB_PHASE[1], "small": BOB_PHASE[2]}
            for sp in spheres:
                sp.c = sp.c.copy()
                sp.c[1] = sp.c[1] + BOB_AMP + BOB_AMP * sin_turns(s / BOB_PERIOD + phase[sp.kind])
        self.spheres = spheres
        # Water shadows: which depths, and the casters (every sphere of the view).
        if p["shadows"] == "variant":
            self.shadow_mode = self.water_shadows
        elif p["shadows"] == "primary" and self.noon_shadows:
            self.shadow_mode = "primary_only"
        else:
            self.shadow_mode = "off"
        self.shadow_spheres = [(sp.c, sp.r, sp.opacity) for sp in spheres]
        self.ring_centres = [sp.c for sp in spheres] if self.rings else []
        self.stripe_a = s / STRIPE_PERIOD if self.stripes else None
        self.height = height
        self.cam = camera_view(self.orbit, self.orbit_frames, height)


def load_texels(path):
    """4-bit indices as a (rows, 256) array [v, u]: byte v*128 + u/2, low nibble for even u.
    rows = file size / 128 (48 for M2.2, 32 for the M2 file)."""
    data = np.frombuffer(open(path, "rb").read(), dtype=np.uint8)
    if data.size == 0 or data.size % (TEX_W // 2):
        raise SystemExit(f"reference: {path}: size {data.size} is not a whole number of {TEX_W // 2}-byte rows")
    tex_h = data.size // (TEX_W // 2)
    rows = data.reshape(tex_h, TEX_W // 2)
    tex = np.empty((tex_h, TEX_W), dtype=np.uint8)
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


def spec_pow(x, squarings):
    for _ in range(squarings):
        x = x * x
    return x


# ---------------------------------------------------------------- sky and env
def sky(d, cfg=None):
    """The M1 gradient with the preset's colours, plus the sun (or moon)
    disc and glow where the preset has them."""
    if cfg is None:
        horizon, mid, zenith, L, sun_col, disc_on = HORIZON, MID, ZENITH, SUN_L, SUN_COL, True
    else:
        horizon, mid, zenith, L, sun_col, disc_on = cfg.horizon, cfg.mid, cfg.zenith, cfg.L, cfg.sun_col, cfg.disc
    h = clamp01(d[:, 1])
    grad = np.where((h < 0.3)[:, None],
                    lerp(horizon, mid, h / 0.3),
                    lerp(mid, zenith, (h - 0.3) / 0.7))
    if not disc_on:
        return grad
    s = dot(d, L)
    disc = smoothstep(0.9950, 0.9995, s)
    glow = smoothstep(0.90, 1.00, s)
    glow = glow * glow
    return grad + sun_col * (disc + 0.4 * glow)[:, None]


def env(o, d, cfg):
    """Shore colour where the shore test hits, else sky(d). Tests nothing else."""
    ts, idx = hit_shore(o, d, cfg)
    col = sky(d, cfg)
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
        c = lerp(DEEP + WATER_SCATTER, sky(r, cfg), f)
        if cfg.water_spec:
            spec = spec_pow(np.maximum(0.0, dot(r, cfg.L)), 6)          # ^64
            c = c + cfg.sun_col * (0.5 * spec)[:, None]
        col[down] = c
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
    inside = fwd & (ts > T_MIN) & (ys >= 0.0) & (ys < cfg.shore_h) & (xs > -SHORE_X) & (xs <= SHORE_X)
    idx = np.zeros(n, dtype=np.intp)
    if inside.any():
        u = np.minimum(TEX_W - 1, np.floor((SHORE_X - xs[inside]) * SHORE_TPU)).astype(np.intp)
        v = np.minimum(cfg.tex_h - 1, np.floor((cfg.shore_h - ys[inside]) * SHORE_TPU)).astype(np.intp)
        idx[inside] = cfg.texels[v, u]
    hit = inside & (idx != 0)
    return np.where(hit, ts, np.inf), idx


def hit_water(o, d):
    """t of the ray against the plane y = 0 where d.y < 0, np.inf elsewhere."""
    down = d[:, 1] < 0.0
    safe_dy = np.where(down, d[:, 1], -1.0)
    return np.where(down, -o[:, 1] / safe_dy, np.inf)


def ripple_normal(p, dist, t, fade_k=FADE_K, ripples=RIPPLES, ring_centres=()):
    """Water normal at p (y = 0); dist is the distance from the ray origin.
    ripples: (A, kx, kz, w) with the preset's amplitude scale folded into A.
    ring_centres: the sphere centres whose rings (PLAN.md M3 "Rings") add
    their analytic gradient; the sum is faded like the waves."""
    g = 1.0 / (1.0 + fade_k * dist)
    fade = g * g
    dhdx = np.zeros(len(p))
    dhdz = np.zeros(len(p))
    for a, kx, kz, w in ripples:
        phase = kx * p[:, 0] + kz * p[:, 2] + w * t      # in turns
        c = cos_turns(phase)
        dhdx += a * kx * 2.0 * np.pi * c
        dhdz += a * kz * 2.0 * np.pi * c
    for rc in ring_centres:
        # h = A sin_turns(k d - w t) (1 - d / R)^2 for d < R, d = |p.xz - c.xz|.
        rx = p[:, 0] - rc[0]
        rz = p[:, 2] - rc[2]
        dd = np.sqrt(rx * rx + rz * rz)
        m = (dd < RING_R) & (dd > 0.0)
        if not m.any():
            continue
        dm = dd[m]
        ph = RING_K * dm - RING_W * t
        q = 1.0 - dm / RING_R
        dhdd = RING_A * (2.0 * np.pi * RING_K * cos_turns(ph) * q * q - (2.0 / RING_R) * q * sin_turns(ph))
        dhdx[m] += dhdd * rx[m] / dm
        dhdz[m] += dhdd * rz[m] / dm
    dhdx *= fade
    dhdz *= fade
    return normalize(np.stack([-dhdx, np.ones(len(p)), -dhdz], axis=-1))


def water_shadow(p, spheres=SHADOW_SPHERES, L=SUN_L):
    """Product over the spheres of the soft shadow factor at water point p."""
    sh = np.ones(len(p))
    for c, rs, a in spheres:
        oc = c - p
        b = dot(oc, L)
        q2 = dot(oc, oc) - b * b
        s = 1.0 - a * (1.0 - smoothstep(0.72 * rs * rs, 1.21 * rs * rs, q2))
        sh *= np.where(b <= 0.0, 1.0, s)
    return sh


def iris_tl(u, v):
    """The mark's top-left bracket (PLAN.md M2.2 "Mask")."""
    return ((u <= 0.293) & (v >= -0.293) & (u >= -1.0) & (v <= 1.0)
            & ~((u > -0.65) & (v < 0.65))
            & ((u >= 0.0) | (v <= 0.0) | (u * u + v * v <= 1.0)))


def iris_mask(u, v):
    """M(U, V) = diamond or TL or BR, BR(U, V) = TL(-U, -V)."""
    return (np.abs(u) + np.abs(v) <= 0.414) | iris_tl(u, v) | iris_tl(-u, -v)


def hit_iris(o, d, t_near, cfg):
    """(t, face) of the rays against the logo; t = np.inf on a miss. t_near is
    the nearest other hit that can be in front of the logo (the spheres), which
    clips the bounding-sphere chord. Follows PLAN.md M2.2 "Hit" literally: the
    chord (t_min, t_max), the slab entry and exit, K samples from t0 to t1, and
    face = the first sample hit and t0 is the slab entry."""
    n_rays = len(d)
    t_hit = np.full(n_rays, np.inf)
    face = np.zeros(n_rays, dtype=bool)
    # Bounding sphere chord, clipped to t > T_MIN and to t < t_near.
    oc = o - IRIS_C
    b = dot(oc, d)
    disc = b * b - (dot(oc, oc) - IRIS_R * IRIS_R)
    ok = disc >= 0.0
    sq = np.sqrt(np.where(ok, disc, 0.0))
    t_min = np.maximum(-b - sq, T_MIN)
    t_max = np.minimum(-b + sq, t_near)
    # Slab |W| <= h along n.
    n = cfg.iris_n
    wo = dot(oc, n)
    wd = dot(d, n)
    par = np.abs(wd) <= 1e-6
    safe = np.where(par, 1.0, wd)
    ta_ = (-IRIS_HT - wo) / safe
    tb_ = (IRIS_HT - wo) / safe
    ta = np.where(par, -np.inf, np.minimum(ta_, tb_))
    tb = np.where(par, np.inf, np.maximum(ta_, tb_))
    ok &= ~(par & (np.abs(wo) > IRIS_HT))
    t0 = np.maximum(ta, t_min)
    t1 = np.minimum(tb, t_max)
    ok &= t0 < t1
    live = ok.copy()
    k = cfg.iris_samples
    for i in range(k):
        if not live.any():
            break
        t = t0 + (t1 - t0) * (i / (k - 1))
        p = o + d * np.where(live, t, 0.0)[:, None]
        q = p - IRIS_C
        m = live & iris_mask(dot(q, cfg.iris_eu) / IRIS_S, q[:, 1] / IRIS_S)
        t_hit[m] = t[m]
        if i == 0:
            face[m] = t0[m] == ta[m]
        live &= ~m
    return t_hit, face


def shade_iris(d, face, cfg):
    """Face: lambert plus a ^32 highlight off the facing normal; side: flat 0.18.
    The preset's sun direction and colour light it (the highlight stays on in
    every preset, storm included: it is not the water specular)."""
    col = np.broadcast_to(IRIS_COL * 0.18, d.shape).copy()
    if face.any():
        df = d[face]
        n = cfg.iris_n
        s = np.where(dot(df, n) < 0.0, 1.0, -1.0)[:, None]
        nf = n * s
        lam = 0.30 + 0.70 * np.maximum(0.0, dot(nf, cfg.L))
        spec = spec_pow(np.maximum(0.0, dot(reflect(df, nf), cfg.L)), 5)   # ^32
        col[face] = IRIS_COL * lam[:, None] + cfg.sun_col * (0.6 * spec)[:, None]
    return col


def env_iris(o, d, cfg):
    """env() with the logo in front: the depth-2 water reflection (knob 6)."""
    col = env(o, d, cfg)
    if cfg.iris_in_water and len(d):
        ti, face = hit_iris(o, d, np.full(len(d), np.inf), cfg)
        m = np.isfinite(ti)
        if m.any():
            col[m] = shade_iris(d[m], face[m], cfg)
    return col


# ---------------------------------------------------------------- shading
def shade_glass(o, d, ts, depth, t, cfg, sp):
    """Glass sphere hit from outside at o + d ts (PLAN "Glass shading")."""
    if depth >= MAX_DEPTH:
        return np.broadcast_to(GLASS_FAR, d.shape).copy()
    gc = sp.c
    p = o + d * ts[:, None]
    n = (p - gc) / GLASS_R
    c = -dot(d, n)
    f = schlick(c, GLASS_F0)[:, None]
    r = reflect(d, n)
    d1 = normalize(refract(d, n, 1.0 / GLASS_IOR, c))       # entering
    if cfg.glass == "real":
        t1 = -2.0 * dot(p - gc, d1)
        q = p + d1 * t1[:, None]                            # exit point
        n2 = (q - gc) / GLASS_R
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
        refl = trace(p, r, depth + 1, t, cfg, skip_glass=True, iris=False)     # rays leaving the glass
        trans = trace(o2, d2, depth + 1, t, cfg, skip_glass=True, iris=False)  # never see the logo
    return f * refl + (1.0 - f) * GLASS_TINT * trans


def stripe_factor(n, cfg):
    """PLAN.md M3 "Stripes": 1 - 0.12 [fract(3 (n.x cos a + n.z sin a)) < 0.5],
    a = s / 20 turns, fract(x) = x - floor(x)."""
    a = cfg.stripe_a
    x = STRIPE_FREQ * (n[:, 0] * cos_turns(a) + n[:, 2] * sin_turns(a))
    return 1.0 - STRIPE_DEPTH * ((x - np.floor(x)) < 0.5)


def shade_chrome(o, d, ts, depth, t, cfg, sp):
    """The chrome sphere and the small chrome sphere (same tint); only the
    big one carries the stripes."""
    p = o + d * ts[:, None]
    n = (p - sp.c) / sp.r
    if depth < MAX_DEPTH:
        col = SPHERE_TINT * trace(p, reflect(d, n), depth + 1, t, cfg, iris=cfg.iris_in_chrome)
    else:
        lam = 0.25 + 0.75 * np.maximum(0.0, dot(n, cfg.L))
        col = SPHERE_TINT * cfg.sun_col * lam[:, None]
    if sp.kind == "chrome" and cfg.stripe_a is not None:
        col = col * stripe_factor(n, cfg)[:, None]
    return col


def shade_matte(o, d, ts, depth, t, cfg, sp):
    """albedo * (0.15 * sky_mid + sun_col * max(0, n.L)) at every depth; no
    reflection, no shadow ray."""
    p = o + d * ts[:, None]
    n = (p - sp.c) / sp.r
    lam = np.maximum(0.0, dot(n, cfg.L))
    return MATTE_ALBEDO * (0.15 * cfg.mid + cfg.sun_col * lam[:, None])


def shade_water(o, d, tw, depth, t, cfg):
    p = o + d * tw[:, None]
    dist = np.linalg.norm(p - o, axis=-1)       # from the camera at depth 0, else the ray origin
    n = ripple_normal(p, dist, t, cfg.fade_k, cfg.ripples, cfg.ring_centres)
    r = reflect(d, n)
    r[:, 1] = np.maximum(r[:, 1], 0.02)         # if r.y < 0.02: r.y = 0.02
    r = normalize(r)
    if depth < MAX_DEPTH:
        refl = trace(p, r, depth + 1, t, cfg, iris=cfg.iris_in_water)
    else:
        refl = env_iris(p, r, cfg)              # knob 6 covers water reflections at every depth
    f = schlick(np.maximum(0.0, dot(-d, n)), WATER_F0)
    if cfg.shadow_mode == "all" or (cfg.shadow_mode == "primary_only" and depth == 0):
        sh = water_shadow(p, cfg.shadow_spheres, cfg.L)
    else:
        sh = np.ones(len(p))
    base = DEEP + WATER_SCATTER * sh[:, None]
    col = lerp(base, refl, f)
    if cfg.water_spec:
        spec = spec_pow(np.maximum(0.0, dot(r, cfg.L)), 6)   # ^64, six squarings
        spec = spec * sh
        col = col + cfg.sun_col * (0.5 * spec)[:, None]
    return col


SHADERS = {"chrome": shade_chrome, "small": shade_chrome, "glass": shade_glass, "matte": shade_matte}


def trace(o, d, depth, t, cfg, skip_glass=False, iris=False):
    """Linear RGB for N rays (o, d: N x 3, d unit). depth 0..2, t = scene seconds.
    skip_glass: the rays start on the glass sphere (reflection, exit or fake
    refraction), which they cannot hit again, so it is not tested (the view
    has no glass sphere when the variant or preset removes it).
    iris: the rays test the logo (primary rays, and water / chrome reflections
    per knobs 6 / 5; never rays leaving the glass). The caller has already
    folded --no-iris and the knobs into it; cfg.set_view() set the spin."""
    n_rays = len(d)
    col = np.zeros((n_rays, 3))
    if n_rays == 0:
        return col

    # Nearest hit; ties go to the earlier column (the spheres in view order,
    # then shore, then water), as M1's `ts <= tw`.
    spheres = cfg.spheres
    ns = len(spheres)
    cols = [np.full(n_rays, np.inf) if (skip_glass and sp.kind == "glass") else hit_sphere(o, d, sp.c, sp.r)
            for sp in spheres]
    t_sph = np.min(np.stack(cols, axis=-1), axis=-1)
    t_all = np.stack(cols + [hit_shore(o, d, cfg)[0], hit_water(o, d)], axis=-1)
    which = np.argmin(t_all, axis=-1)
    tmin = t_all[np.arange(n_rays), which]
    miss, logo = ns + 2, ns + 3
    which = np.where(np.isfinite(tmin), which, miss)

    # The logo: in front of the shore and above the water, so only a sphere
    # can be nearer; its chord is clipped to t below the nearer sphere hit.
    if iris:
        ti, iface = hit_iris(o, d, t_sph, cfg)
        mi = np.isfinite(ti)
        which = np.where(mi, logo, which)
        if mi.any():
            col[mi] = shade_iris(d[mi], iface[mi], cfg)

    for k, sp in enumerate(spheres):
        m = which == k
        if m.any():
            col[m] = SHADERS[sp.kind](o[m], d[m], tmin[m], depth, t, cfg, sp)
    m = which == ns                                         # shore: palette colour, already lit
    if m.any():
        col[m] = cfg.palette[hit_shore(o[m], d[m], cfg)[1]]
    m = which == ns + 1
    if m.any():
        col[m] = shade_water(o[m], d[m], tmin[m], depth, t, cfg)
    m = which == miss
    if m.any():
        col[m] = sky(d[m], cfg)
    return col


# ---------------------------------------------------------------- camera and frame
def camera(frame, orbit_frames=600):
    """The M2.2 camera at the default height, all f64 (legacy)."""
    theta = (frame % orbit_frames) / orbit_frames   # turns; one orbit per 30 s
    eye = np.array([ORBIT_R * sin_turns(theta), DEFAULT_HEIGHT, ORBIT_R * cos_turns(theta)])
    fwd = TARGET - eye
    fwd /= np.linalg.norm(fwd)
    right = np.cross(fwd, [0.0, 1.0, 0.0])
    right /= np.linalg.norm(right)
    up = np.cross(right, fwd)
    return eye, fwd, right, up


def camera_view(orbit, orbit_frames, height=DEFAULT_HEIGHT):
    """The camera at orbit index `orbit` and eye height `height`. The default
    height is the legacy f64 camera. Any other height is rounded to f32 and
    the closed-form basis scalars are computed in f32, as camera.zig does at
    run time:
        dy = ty - h;  L = sqrt(R * R + dy * dy);  basis_h = R / L;  basis_y = dy / L
        fwd = (-sin * basis_h, basis_y, -cos * basis_h), right = (cos, 0, -sin),
        up = (sin * basis_y, basis_h, cos * basis_y)
    with sin, cos of theta = orbit / orbit_frames turns in f64."""
    if height == DEFAULT_HEIGHT:
        return camera(orbit, orbit_frames)
    f32 = np.float32
    h = f32(height)
    dy = f32(TARGET[1]) - h
    ln = np.sqrt(f32(ORBIT_R) * f32(ORBIT_R) + dy * dy, dtype=np.float32)
    bh = float(f32(ORBIT_R) / ln)
    by = float(dy / ln)
    theta = (orbit % orbit_frames) / orbit_frames
    s, c = sin_turns(theta), cos_turns(theta)
    eye = np.array([ORBIT_R * s, float(h), ORBIT_R * c])
    fwd = np.array([-s * bh, by, -c * bh])
    right = np.array([c, 0.0, -s])
    up = np.array([s * by, bh, c * by])
    return eye, fwd, right, up


def render_view(cfg):
    """Linear RGB image (H x W x 3, float64), before saturate, of the view
    set with cfg.set_view(). With scale 2 only the even (x, y) pixels are
    traced, with exactly the full-resolution pixel's ray, and each is copied
    to its 2x2 block."""
    eye, fwd, right, up = cfg.cam
    s = cfg.scale
    x = np.arange(0, W, s)
    y = np.arange(0, H, s)
    u = (x + 0.5 - 80.0) / 80.0 * TAN_H         # (W,)
    v = -(y + 0.5 - 64.0) / 80.0 * TAN_H        # (H,)
    dirs = fwd + right * u[None, :, None] + up * v[:, None, None]   # (H, W, 3)
    d = normalize(dirs.reshape(-1, 3))
    o = np.broadcast_to(eye, d.shape).copy()
    img = trace(o, d, 0, cfg.t, cfg, iris=cfg.iris).reshape(len(y), len(x), 3)
    if s > 1:
        img = np.repeat(np.repeat(img, s, axis=0), s, axis=1)
    return img


def render(frame, cfg=None, preset="sunset", height=DEFAULT_HEIGHT):
    """The legacy frame F (t = F, orbit = F mod orbit_frames)."""
    cfg = cfg or Config()
    cfg.set_frame(frame, preset, height)
    return render_view(cfg)


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


# PLAN.md "M2.1 Perf variants": the flag defaults each variant sets, mirroring
# cart/src/variant.zig. check_render.mjs and tools/emu pass --variant.
IRIS_CUT = {"iris_in_chrome": 0, "iris_in_water": 0, "iris_samples": 3}  # variant.zig iris_cut
VARIANTS = {
    "full20": {**IRIS_CUT},
    "cut20": {"no_glass": True, "water_shadows": "off", **IRIS_CUT},
    "full15": {"fps": 15, "glass_primary": "env", **IRIS_CUT},
    "half30": {"fps": 30, "scale": 2},
}


def parse_preset(s):
    s = s.strip().lower()
    if s.isdigit() and int(s) < len(PRESET_NAMES):
        return PRESET_NAMES[int(s)]
    if s in PRESETS:
        return s
    raise argparse.ArgumentTypeError(f"unknown preset '{s}' (want {', '.join(PRESET_NAMES)} or 0..3)")


def parse_height(s):
    h = float(s)
    if not (MIN_HEIGHT <= h <= MAX_HEIGHT):
        raise argparse.ArgumentTypeError(f"height {h} outside [{MIN_HEIGHT}, {MAX_HEIGHT}]")
    return h


def view_name(preset, t, orbit, height):
    return f"{preset}_t{t:04d}_o{orbit:04d}_h{int(round(height * 1000)):04d}"


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--frame", type=int, action="append", default=[],
                    help="legacy frame F: t = F, orbit = F mod orbit_frames, writes ref_FFFF.png (repeatable)")
    ap.add_argument("--preset", type=parse_preset, default="sunset",
                    help="M3 preset for --frame and --t: sunset, midnight, noon, storm or 0..3 (default sunset)")
    ap.add_argument("--t", type=int, default=None, help="M3 view: scene time in frames (with --orbit, --height)")
    ap.add_argument("--orbit", type=int, default=None, help="M3 view: orbit index (default t mod orbit_frames)")
    ap.add_argument("--height", type=parse_height, default=DEFAULT_HEIGHT,
                    help=f"eye height in metres, [{MIN_HEIGHT}, {MAX_HEIGHT}] (default {DEFAULT_HEIGHT})")
    ap.add_argument("--view", action="append", default=[],
                    help="M3 view PRESET:T[:ORBIT[:HEIGHT]] (repeatable); ORBIT defaults to T mod orbit_frames")
    ap.add_argument("--name", default=None, help="output basename (without ref_ and .png) for a single --t view")
    ap.add_argument("--out", required=True, help="output directory")
    ap.add_argument("--motion", type=int, choices=[0, 1], default=1,
                    help="M3 motion master switch: bob, sun drift, rings, stripes (default 1; 0 = M2.2 identity)")
    ap.add_argument("--rings", type=int, choices=[0, 1], default=1, help="M3 knob: rings on the water under each sphere")
    ap.add_argument("--stripes", type=int, choices=[0, 1], default=0,
                    help="M3 knob: stripes on the chrome sphere (default 0: dropped from the cart 2026-09-30)")
    ap.add_argument("--sun-drift", type=int, choices=[0, 1], default=1, help="M3 knob: the sun drifts about +y")
    ap.add_argument("--noon-shadows", type=int, choices=[0, 1], default=1,
                    help="M3 knob: noon shadows primary water hits (default 1)")
    ap.add_argument("--noon-third-sphere", type=int, choices=[0, 1], default=1,
                    help="M3 knob: noon has the small chrome sphere (default 1)")
    ap.add_argument("--glass", choices=["real", "fake"], default="real",
                    help="knob 1: real exit refraction or fake single refraction (default real)")
    ap.add_argument("--water-shadows", choices=["all", "primary_only", "off"], default="all",
                    help="knob 2: which water hits get sphere shadows in the sunset preset (default all)")
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
    ap.add_argument("--no-iris", action="store_true", help="remove the Iris logo (M2.2) everywhere")
    ap.add_argument("--iris-in-chrome", type=int, choices=[0, 1], default=1,
                    help="knob 5: chrome reflections show the logo (default 1)")
    ap.add_argument("--iris-in-water", type=int, choices=[0, 1], default=1,
                    help="knob 6: water reflections, at every depth, show the logo (default 1)")
    ap.add_argument("--iris-samples", type=int, default=4,
                    help="knob 7: K, samples along the slab chord (default 4, minimum 2)")
    ap.add_argument("--fade-k", type=float, default=FADE_K, help=f"ripple fade constant (default {FADE_K})")
    ap.add_argument("--texels", default=None, help="shore texels (default cart/src/shore_texels.bin)")
    ap.add_argument("--palette", default=None, help="shore palette JSON (default tools/shore_palette.json)")
    ap.add_argument("--dump-npy", action="store_true", help="also save the float image as ref_*.npy")
    ap.add_argument("--variant", choices=sorted(VARIANTS),
                    help="preset the flags of an M2.1 variant (cart/src/variant.zig); explicit flags still win")
    pre, _ = ap.parse_known_args()
    if pre.variant:
        ap.set_defaults(**VARIANTS[pre.variant])
    args = ap.parse_args()
    if args.fps <= 0:
        ap.error("--fps must be > 0")
    if args.iris_samples < 2:
        ap.error("--iris-samples must be >= 2")
    cfg = Config(args.glass, args.water_shadows, args.glass_secondary, args.fade_k, args.texels, args.palette,
                 fps=args.fps, glass_enabled=not args.no_glass, glass_primary=args.glass_primary,
                 scale=args.scale, iris=not args.no_iris, iris_in_chrome=bool(args.iris_in_chrome),
                 iris_in_water=bool(args.iris_in_water), iris_samples=args.iris_samples,
                 motion=bool(args.motion), rings=bool(args.rings), stripes=bool(args.stripes),
                 sun_drift=bool(args.sun_drift), noon_shadows=bool(args.noon_shadows),
                 noon_third_sphere=bool(args.noon_third_sphere))

    # (name, preset, t, orbit, height)
    jobs = []
    for frame in args.frame:
        if frame < 0:
            ap.error("--frame must be >= 0")
        jobs.append((f"{frame:04d}", args.preset, frame, frame % cfg.orbit_frames, args.height))
    if args.t is not None:
        if args.t < 0:
            ap.error("--t must be >= 0")
        orbit = args.orbit if args.orbit is not None else args.t
        if orbit < 0:
            ap.error("--orbit must be >= 0")
        orbit %= cfg.orbit_frames
        jobs.append((args.name or view_name(args.preset, args.t, orbit, args.height), args.preset, args.t, orbit,
                     args.height))
    elif args.orbit is not None or args.name is not None:
        ap.error("--orbit and --name need --t")
    for v in args.view:
        parts = v.split(":")
        try:
            if not 2 <= len(parts) <= 4:
                raise ValueError("want PRESET:T[:ORBIT[:HEIGHT]]")
            preset = parse_preset(parts[0])
            t = int(parts[1])
            orbit = int(parts[2]) if len(parts) > 2 and parts[2] != "" else t
            height = parse_height(parts[3]) if len(parts) > 3 else DEFAULT_HEIGHT
            if t < 0 or orbit < 0:
                raise ValueError("t and orbit must be >= 0")
        except (ValueError, argparse.ArgumentTypeError) as e:
            ap.error(f"--view {v}: {e}")
        orbit %= cfg.orbit_frames
        jobs.append((view_name(preset, t, orbit, height), preset, t, orbit, height))
    if not jobs:
        ap.error("nothing to render: give --frame, --t or --view")

    os.makedirs(args.out, exist_ok=True)
    print(f"reference: glass={'off' if args.no_glass else cfg.glass} water_shadows={cfg.water_shadows} "
          f"glass_secondary={cfg.glass_secondary} glass_primary={cfg.glass_primary} fade_k={cfg.fade_k:g} "
          f"fps={cfg.fps} (orbit {cfg.orbit_frames} frames) scale={cfg.scale} shore_rows={cfg.tex_h} "
          f"iris={'off' if not cfg.iris else f'chrome={int(cfg.iris_in_chrome)} water={int(cfg.iris_in_water)} K={cfg.iris_samples}'} "
          f"motion={int(cfg.motion)} rings={int(cfg.rings)} stripes={int(cfg.stripes)} sun_drift={int(cfg.sun_drift)} "
          f"noon_shadows={int(cfg.noon_shadows)} noon_third_sphere={int(cfg.noon_third_sphere)}",
          file=sys.stderr)
    for name, preset, t, orbit, height in jobs:
        cfg.set_view(preset, t, orbit, height)
        img = render_view(cfg)
        base = os.path.join(args.out, f"ref_{name}")
        write_png(base + ".png", quantise_none(img))
        if args.dump_npy:
            np.save(base + ".npy", img)
        print(f"reference: wrote {base}.png ({preset} t={t} orbit={orbit} height={height:g})", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
