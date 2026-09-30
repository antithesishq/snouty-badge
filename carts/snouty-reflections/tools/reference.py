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
the preset, the scene time t in frames (water, logo spin, bob, sun drift,
stripes; s = t / fps seconds), the camera angle as an orbit index (theta =
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
(0/1) only act with --motion 1; --noon-shadows and --noon-third-sphere
(0/1) are preset content and act either way. Presets (--preset
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
mark at (-13.5, 1.8, 12), six turns per orbit, K samples along the slab chord).
Primary rays test it, water reflections at every depth if --iris-in-water 1
(knob 6), chrome reflections (both chrome spheres) if --iris-in-chrome 1
(knob 5), rays leaving the glass never. --iris-samples K is knob 7,
--no-iris removes it; with --no-iris and the M2 texel file the output is
byte-identical to the M2.1 reference.

M4 (--pt): the freeze-frame path tracer's estimator, PLAN.md M4 "The M4
estimator, exactly", for pt.zig and tools/check_pt.mjs:

    python3 tools/reference.py --pt --passes 1024 --preset noon --t 0 --orbit 0     # one view
    python3 tools/reference.py --pt --passes 16,1024 --check-set                    # check_pt's references
    python3 tools/reference.py --pt --passes 64 --from 16 --view sunset:300         # passes 16 .. 63 only
    python3 tools/reference.py --rng-selftest                                       # RNG values for pt.zig

It writes the float mean of passes M .. N-1 (128 x 160 x 3 float64, not
saturated) as pt_<view>_nMMMM-NNNN[_knobs]_<scene>.npy plus a PNG (dither
none) to --out (default out/pt_ref/, the cache: an existing .npy is reused
unless --force). <scene> is pt_scene_hash(): 8 hex digits over every
upper-case scene constant (IRIS_C included), the pt_config() flags, the
knobs, fps, the shore and blue-noise files and PT_ESTIMATOR, so a scene edit
never reuses a stale reference. The scene is every preset's full content
regardless of variant (pt_config: glass in sunset, matte, small chrome,
rings, sun drift, the logo in every reflection, K = 4; stripes per
PT_STRIPES, off since M3.1). f64 throughout except the RNG (lowbias32, key,
R2 with the blue-noise rotation, to_unit), which is bit exact. Rays of
--batch passes are traced together as one masked wavefront and the passes
are split over --jobs processes. --accum simulates the cart's u32
accumulator (stochastic rounding) instead of the float mean. The knob flags
(--dof, --lens-radius, --sun-radius, --max-bounces, --water-roughness,
--sky-fill, --sample-clamp) default to pt.zig's values; a non-default one
is part of the file name.

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
IRIS_C = np.array([-13.5, 1.8, 12.0])
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
                 motion=True, rings=True, stripes=True, sun_drift=True, noon_shadows=True,
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


# ---------------------------------------------------------------- M4 path tracer (--pt)
# PLAN.md M4 "The M4 estimator, exactly". f64 everywhere except the integer
# RNG (lowbias32, the key layout, R2 with the blue-noise rotation, to_unit),
# which is bit exact with the plan and so with pt.zig. The frame is a
# wavefront: every ray of a batch of passes (pass-major, then pixel y * 160
# + x) goes through vertex b = 0 .. max_bounces together, with masks.
PT_W_H = W * H                                 # 20480: the key's pixel stride
PT_A = (np.uint32(0xC13FA9A9), np.uint32(0x91E10DA6))   # 2^32 / g, 2^32 / g^2 (plastic number)
PT_THR_MIN = 1.0 / 1024.0
PT_GLASS_VIS = 1.0 - GLASS_OPACITY             # 0.45: a shadow ray that meets only the glass
PT_CACHE = os.path.join(CART, "out", "pt_ref")


class PtKnobs:
    """The M4 knobs (PLAN.md M4 estimator; pt.zig has the same names)."""

    def __init__(self, dof=True, lens_radius=0.05, sun_radius_deg=1.5, max_bounces=4, water_roughness=0.08,
                 sky_fill=0.3, sample_clamp=4.0):
        self.dof = dof
        self.lens_radius = lens_radius
        self.sun_radius_deg = sun_radius_deg
        self.max_bounces = max_bounces
        self.water_roughness = water_roughness
        self.sky_fill = sky_fill
        self.sample_clamp = sample_clamp
        assert 4 + 4 * max_bounces + 3 < 63, "vertex dimensions would reach dimension 63 (the rounding)"

    DEFAULTS = dict(dof=True, lens_radius=0.05, sun_radius_deg=1.5, max_bounces=4, water_roughness=0.08,
                    sky_fill=0.3, sample_clamp=4.0)

    def tag(self):
        """'' at the defaults, else a short suffix for cache names."""
        diff = [f"{k}{getattr(self, k):g}" if not isinstance(v, bool) else f"{k}{int(getattr(self, k))}"
                for k, v in self.DEFAULTS.items() if getattr(self, k) != v]
        return ("_" + "_".join(diff)) if diff else ""


PT_STRIPES = False                             # M3.1: Adrian dropped the chrome stripes (all presets)
PT_ESTIMATOR = "m4-1"                          # bump when the estimator's code changes (cache key)
PT_CHECK_SET = [("sunset", 0, 0, DEFAULT_HEIGHT), ("midnight", 0, 0, DEFAULT_HEIGHT), ("noon", 0, 0, DEFAULT_HEIGHT),
                ("storm", 0, 0, DEFAULT_HEIGHT), ("sunset", 300, 300, DEFAULT_HEIGHT), ("noon", 0, 0, 1.0)]


def pt_config(fps=20):
    """The M4 scene: every preset's full content regardless of variant (glass
    in sunset, matte in midnight and noon, the small chrome in noon, rings,
    sun drift, the logo (IRIS_C) in every reflection with K = 4); stripes
    per PT_STRIPES."""
    return Config(glass="real", water_shadows="all", glass_secondary="full", fps=fps, glass_enabled=True,
                  glass_primary="full", scale=1, iris=True, iris_in_chrome=True, iris_in_water=True,
                  iris_samples=4, motion=True, rings=True, stripes=PT_STRIPES, sun_drift=True, noon_shadows=True,
                  noon_third_sphere=True)


def pt_scene_hash(knobs, fps):
    """8 hex digits over everything the estimator reads: every upper-case
    module constant (IRIS_C, the presets, sphere and water constants, ...),
    the pt_config() flags, the knobs, fps, the shore texels and palette, the
    blue-noise tile and PT_ESTIMATOR. Part of every cache name, so a scene
    change (M3.1) or a knob change never reuses a stale reference."""
    import hashlib

    def canon(v):
        if isinstance(v, np.ndarray):
            return canon(v.tolist())
        if isinstance(v, dict):
            return "{" + ",".join(f"{k!r}:{canon(v[k])}" for k in sorted(v)) + "}"
        if isinstance(v, (list, tuple)):
            return "[" + ",".join(canon(x) for x in v) + "]"
        if isinstance(v, float):
            return repr(float(v))
        if callable(v):
            return getattr(v, "__name__", "callable")         # SHADERS: never an address
        return repr(v)

    skip = {"HERE", "CART", "PT_CACHE", "VARIANTS", "IRIS_CUT", "PT_CHECK_SET"}
    consts = {k: v for k, v in globals().items()
              if k.isupper() and k not in skip and isinstance(v, (int, float, str, np.ndarray, list, tuple, dict))}
    cfg = pt_config(fps)
    flags = {k: v for k, v in vars(cfg).items() if isinstance(v, (bool, int, float, str))}
    h = hashlib.sha256()
    h.update(canon(consts).encode())
    h.update(canon(flags).encode())
    h.update(canon({k: getattr(knobs, k) for k in PtKnobs.DEFAULTS}).encode())
    h.update(cfg.texels.tobytes())
    h.update(canon(cfg.base_palette).encode())
    h.update(pt_bluenoise().tobytes())
    return h.hexdigest()[:8]


# ---- the RNG (bit exact)
def pt_lowbias32(v):
    v = np.asarray(v, dtype=np.uint32)
    with np.errstate(over="ignore"):
        v = v ^ (v >> np.uint32(16))
        v = v * np.uint32(0x7FEB352D)
        v = v ^ (v >> np.uint32(15))
        v = v * np.uint32(0x846CA68B)
        v = v ^ (v >> np.uint32(16))
    return v


def pt_key(x, y, n, d):
    """(n * 64 + d) * 20480 + y * 160 + x, u32 wrapping."""
    x, y, n = (np.asarray(a, dtype=np.uint32) for a in (x, y, n))
    with np.errstate(over="ignore"):
        return (n * np.uint32(64) + np.uint32(d)) * np.uint32(PT_W_H) + y * np.uint32(W) + x


def pt_hash(x, y, n, d):
    return pt_lowbias32(pt_key(x, y, n, d))


def pt_to_unit(h):
    """(h >> 8) * 2^-24: exact in f32 and f64."""
    return (np.asarray(h, dtype=np.uint32) >> np.uint32(8)).astype(np.float64) * (2.0 ** -24)


_BLUENOISE = None


def pt_bluenoise():
    global _BLUENOISE
    if _BLUENOISE is None:
        path = os.path.join(CART, "cart", "src", "bluenoise64.bin")
        b = np.frombuffer(open(path, "rb").read(), dtype=np.uint8)
        if b.size != 64 * 64:
            raise SystemExit(f"reference: {path}: {b.size} bytes, want 4096")
        _BLUENOISE = b.astype(np.uint32)
    return _BLUENOISE


def pt_bn(x, y):
    """bluenoise64.bin[(y & 63) * 64 + (x & 63)] (the dither's tile)."""
    x = np.asarray(x, dtype=np.uint32)
    y = np.asarray(y, dtype=np.uint32)
    return pt_bluenoise()[((y & np.uint32(63)) << np.uint32(6)) | (x & np.uint32(63))]


def pt_r2_bits(x, y, n, d):
    """The u32 before to_unit for dimensions 0..3: (bn << 24) + n * A_(d mod 2),
    bn at (x, y) for d = 0, 1 and at (x + 32, y + 32) for d = 2, 3."""
    assert 0 <= d <= 3
    x = np.asarray(x, dtype=np.uint32)
    y = np.asarray(y, dtype=np.uint32)
    off = np.uint32(32 if d >= 2 else 0)
    with np.errstate(over="ignore"):
        return (pt_bn(x + off, y + off) << np.uint32(24)) + np.asarray(n, dtype=np.uint32) * PT_A[d & 1]


def pt_u(x, y, n, d):
    """The sample in [0, 1) of dimension d."""
    if d < 4:
        return pt_to_unit(pt_r2_bits(x, y, n, d))
    return pt_to_unit(pt_hash(x, y, n, d))


def pt_rng_selftest():
    """A few values for pt.zig's test to compare against (printed by --rng-selftest)."""
    lines = []
    for v in (0, 1, 0x12345678, 0xFFFFFFFF):
        lines.append(f"lowbias32(0x{v:08x}) = 0x{int(pt_lowbias32(v)):08x}")
    for (x, y, n, d) in ((0, 0, 0, 4), (1, 0, 0, 4), (159, 127, 0, 5), (17, 42, 3, 6), (80, 64, 255, 23),
                         (5, 7, 1023, 63), (159, 127, 4095, 63)):
        k = int(pt_key(x, y, n, d))
        h = int(pt_hash(x, y, n, d))
        lines.append(f"hash(x={x}, y={y}, n={n}, d={d}): key = 0x{k:08x}, h = 0x{h:08x}, "
                     f"to_unit = {float(pt_to_unit(h)):.9f} ({h >> 8} / 2^24)")
    for (x, y) in ((0, 0), (1, 0), (63, 63), (100, 70)):
        lines.append(f"bn({x}, {y}) = {int(pt_bn(x, y))}, bn({x + 32}, {y + 32}) = {int(pt_bn(x + 32, y + 32))}")
    for (x, y, n) in ((0, 0, 0), (0, 0, 1), (17, 42, 3), (100, 70, 255)):
        vals = []
        for d in range(4):
            b = int(pt_r2_bits(x, y, n, d))
            vals.append(f"d{d} 0x{b:08x} -> {float(pt_to_unit(b)):.9f}")
        lines.append(f"R2(x={x}, y={y}, n={n}): " + ", ".join(vals))
    # The accumulator's rounding offsets for one pixel.
    h = int(pt_hash(17, 42, 3, 63))
    lines.append(f"rounding hash(17, 42, 3, 63) = 0x{h:08x}: u_r = {(h >> 21) / 2048:.9f}, "
                 f"u_g = {((h >> 10) & 2047) / 2048:.9f}, u_b = {(h & 1023) / 1024:.9f}")
    return lines


# ---- geometry helpers
def pt_onb(n):
    """PLAN.md M4 onb(n): (e1, e2), each (N, 3)."""
    s = np.where(n[:, 2] >= 0.0, 1.0, -1.0)
    a = -1.0 / (s + n[:, 2])
    b = n[:, 0] * n[:, 1] * a
    e1 = np.stack([1.0 + s * n[:, 0] * n[:, 0] * a, s * b, -s * n[:, 0]], axis=-1)
    e2 = np.stack([b, s + n[:, 1] * n[:, 1] * a, -n[:, 1]], axis=-1)
    return e1, e2


def pt_sky(d, cfg, diffuse):
    """sky(d); rays after a diffuse bounce drop the disc term (grad + sun_col
    * 0.4 * glow): the direct sun term already counts the disc."""
    col = sky(d, cfg)
    if cfg.disc and diffuse.any():
        dd = d[diffuse]
        h = clamp01(dd[:, 1])
        grad = np.where((h < 0.3)[:, None], lerp(cfg.horizon, cfg.mid, h / 0.3),
                        lerp(cfg.mid, cfg.zenith, (h - 0.3) / 0.7))
        glow = smoothstep(0.90, 1.00, dot(dd, cfg.L))
        col[diffuse] = grad + cfg.sun_col * (0.4 * glow * glow)[:, None]
    return col


def pt_vis(p, ls, cfg):
    """Shadow ray from p along ls (t > 1e-3): 0 if it meets the chrome, matte
    or small sphere or the logo, 0.45 if it meets only the glass, else 1 (the
    shore does not cast)."""
    n = len(p)
    opaque = np.zeros(n, dtype=bool)
    glass = np.zeros(n, dtype=bool)
    for sp in cfg.spheres:
        hit = np.isfinite(hit_sphere(p, ls, sp.c, sp.r))
        if sp.kind == "glass":
            glass |= hit
        else:
            opaque |= hit
    rest = ~opaque
    if rest.any():
        ti, _ = hit_iris(p[rest], ls[rest], np.full(int(rest.sum()), np.inf), cfg)
        opaque[np.flatnonzero(rest)[np.isfinite(ti)]] = True
    return np.where(opaque, 0.0, np.where(glass, PT_GLASS_VIS, 1.0))


def pt_sun_dir(u_a, u_b, cfg, knobs):
    """Ls = normalize(L + tan(sun_radius) sqrt(ua) (cos(2 pi ub) e1 + sin(2 pi ub) e2))."""
    L = np.broadcast_to(cfg.L, (len(u_a), 3))
    e1, e2 = pt_onb(np.ascontiguousarray(L))
    r = np.tan(np.radians(knobs.sun_radius_deg)) * np.sqrt(u_a)
    a = 2.0 * np.pi * u_b
    return normalize(L + (r * np.cos(a))[:, None] * e1 + (r * np.sin(a))[:, None] * e2)


def pt_camera_rays(cfg, knobs, x, y, n):
    """Origins and directions of the camera rays for pixels (x, y), pass n."""
    eye, fwd, right, up = cfg.cam
    px = x + pt_u(x, y, n, 0)
    py = y + pt_u(x, y, n, 1)
    u = (px - 80.0) / 80.0 * TAN_H
    v = -(py - 64.0) / 80.0 * TAN_H
    d = normalize(fwd + right * u[:, None] + up * v[:, None])
    o = np.broadcast_to(eye, d.shape).copy()
    if knobs.dof:
        f = float(np.dot(cfg.spheres[0].c - eye, fwd))           # chrome centre at t
        P = eye + d * (f / dot(d, fwd))[:, None]
        rl = knobs.lens_radius * np.sqrt(pt_u(x, y, n, 2))
        a = 2.0 * np.pi * pt_u(x, y, n, 3)
        o = eye + right * (rl * np.cos(a))[:, None] + up * (rl * np.sin(a))[:, None]
        d = normalize(P - o)
    return o, d


def pt_samples(cfg, knobs, x, y, n):
    """One sample per ray (min(Lsum, clamp) per channel) for pixel arrays x, y
    (uint32) at passes n (uint32): the path of PLAN.md M4 "Path"."""
    m = len(x)
    o, d = pt_camera_rays(cfg, knobs, x, y, n)
    lsum = np.zeros((m, 3))
    thr = np.ones((m, 3))
    diffuse = np.zeros(m, dtype=bool)
    inside = np.zeros(m, dtype=bool)
    alive = np.ones(m, dtype=bool)
    spheres = cfg.spheres
    ns = len(spheres)
    glass_k = next((k for k, sp in enumerate(spheres) if sp.kind == "glass"), None)
    for b in range(knobs.max_bounces + 1):
        terminal = b == knobs.max_bounces
        ids = np.flatnonzero(alive)
        if len(ids) == 0:
            break
        xo, yo, no = x[ids], y[ids], n[ids]
        oo, dd = o[ids], d[ids]
        k = len(ids)
        ins = inside[ids]
        # Nearest hit. Outside the glass: spheres (view order), shore, water,
        # then the logo, whose chord is clipped to the nearer sphere hit.
        # Inside: only the glass (its far side).
        t_cols = []
        for sp in spheres:
            t_cols.append(hit_sphere(oo, dd, sp.c, sp.r))
        if glass_k is not None and ins.any():
            for j in range(ns):
                if j != glass_k:
                    t_cols[j] = np.where(ins, np.inf, t_cols[j])
        t_sph = np.min(np.stack(t_cols, axis=-1), axis=-1)
        t_shore, shore_idx = hit_shore(oo, dd, cfg)
        t_water = hit_water(oo, dd)
        t_water = np.where(t_water > T_MIN, t_water, np.inf)
        t_shore = np.where(ins, np.inf, t_shore)
        t_water = np.where(ins, np.inf, t_water)
        t_all = np.stack(t_cols + [t_shore, t_water], axis=-1)
        which = np.argmin(t_all, axis=-1)
        tmin = t_all[np.arange(k), which]
        miss, logo = ns + 2, ns + 3
        which = np.where(np.isfinite(tmin), which, miss)
        out = ~ins
        iface = np.zeros(k, dtype=bool)
        if out.any():
            oi = np.flatnonzero(out)
            ti, fc = hit_iris(oo[oi], dd[oi], t_sph[oi], cfg)
            mi = np.isfinite(ti)
            which[oi[mi]] = logo
            iface[oi[mi]] = fc[mi]
        p = oo + dd * np.where(np.isfinite(tmin), tmin, 0.0)[:, None]
        th = thr[ids]
        add = np.zeros((k, 3))
        stop = np.zeros(k, dtype=bool)
        new_d = dd.copy()
        new_inside = ins.copy()
        new_diff = diffuse[ids].copy()
        # Sun sample of this vertex (used by water and matte).
        need_sun = (which == ns + 1) | np.isin(which, [j for j, sp in enumerate(spheres) if sp.kind == "matte"])
        ls = np.zeros((k, 3))
        if need_sun.any():
            si = np.flatnonzero(need_sun)
            ls[si] = pt_sun_dir(pt_u(xo[si], yo[si], no[si], 4 + 4 * b), pt_u(xo[si], yo[si], no[si], 5 + 4 * b),
                                cfg, knobs)
        # Sky.
        mm = which == miss
        if mm.any():
            add[mm] = th[mm] * pt_sky(dd[mm], cfg, new_diff[mm])
            stop[mm] = True
        # Shore.
        mm = which == ns
        if mm.any():
            add[mm] = th[mm] * cfg.palette[shore_idx[mm]]
            stop[mm] = True
        # Logo.
        mm = which == logo
        if mm.any():
            add[mm] = th[mm] * shade_iris(dd[mm], iface[mm], cfg)
            stop[mm] = True
        for j, sp in enumerate(spheres):
            mm = which == j
            if not mm.any():
                continue
            nrm = (p[mm] - sp.c) / sp.r
            if sp.kind in ("chrome", "small"):
                f = np.broadcast_to(SPHERE_TINT, nrm.shape).copy()
                if sp.kind == "chrome" and cfg.stripe_a is not None:
                    f = f * stripe_factor(nrm, cfg)[:, None]
                if terminal:
                    lam = 0.25 + 0.75 * np.maximum(0.0, dot(nrm, cfg.L))
                    add[mm] = th[mm] * f * cfg.sun_col * lam[:, None]
                    stop[mm] = True
                else:
                    th[mm] = th[mm] * f
                    new_d[mm] = reflect(dd[mm], nrm)
            elif sp.kind == "glass":
                if terminal:
                    add[mm] = th[mm] * GLASS_FAR
                    stop[mm] = True
                    continue
                di = dd[mm]
                dn = dot(di, nrm)
                entering = dn < 0.0
                c = np.where(entering, -dn, dn)
                eta = np.where(entering, 1.0 / GLASS_IOR, GLASS_IOR)
                nn = np.where(entering[:, None], nrm, -nrm)
                kk = 1.0 - eta * eta * (1.0 - c * c)
                tir = kk < 0.0
                sk = np.sqrt(np.maximum(kk, 0.0))
                F = np.where(tir, 1.0, schlick(np.where(entering, c, sk), GLASS_F0))
                mi = np.flatnonzero(mm)
                u = pt_u(xo[mi], yo[mi], no[mi], 6 + 4 * b)
                refl = u < F
                rd = reflect(di, nrm)
                td = normalize(eta[:, None] * di + (eta * c - sk)[:, None] * nn)
                new_d[mm] = np.where(refl[:, None], rd, td)
                tint = entering & ~refl
                tt = th[mm]
                tt[tint] = tt[tint] * GLASS_TINT
                th[mm] = tt
                new_inside[mm] = entering ^ refl
            else:  # matte
                mi = np.flatnonzero(mm)
                l_s = ls[mi]
                nl = dot(nrm, l_s)
                lit = nl > 0.0
                if lit.any():
                    v = pt_vis(p[mi[lit]], l_s[lit], cfg)
                    add[mi[lit]] = th[mi[lit]] * MATTE_ALBEDO * cfg.sun_col * (nl[lit] * v)[:, None]
                if terminal:
                    stop[mi] = True
                    continue
                e1, e2 = pt_onb(nrm)
                ra = np.sqrt(pt_u(xo[mi], yo[mi], no[mi], 6 + 4 * b))
                a = 2.0 * np.pi * pt_u(xo[mi], yo[mi], no[mi], 7 + 4 * b)
                new_d[mi] = (e1 * (ra * np.cos(a))[:, None] + nrm * np.sqrt(1.0 - ra * ra)[:, None]
                             + e2 * (ra * np.sin(a))[:, None])
                th[mi] = th[mi] * MATTE_ALBEDO * knobs.sky_fill
                new_diff[mi] = True
        # Water.
        mm = which == ns + 1
        if mm.any():
            mi = np.flatnonzero(mm)
            pw, dw = p[mi], dd[mi]
            dist = np.linalg.norm(pw - oo[mi], axis=-1)
            nrm = ripple_normal(pw, dist, cfg.t, cfg.fade_k, cfg.ripples, cfg.ring_centres)
            rr = knobs.water_roughness * np.sqrt(pt_u(xo[mi], yo[mi], no[mi], 6 + 4 * b))
            a = 2.0 * np.pi * pt_u(xo[mi], yo[mi], no[mi], 7 + 4 * b)
            n2 = normalize(nrm + np.stack([rr * np.cos(a), np.zeros(len(mi)), rr * np.sin(a)], axis=-1))
            r = reflect(dw, n2)
            low = r[:, 1] < 0.02
            if low.any():
                r[low, 1] = 0.02
                r[low] = normalize(r[low])
            F = schlick(np.maximum(0.0, -dot(dw, n2)), WATER_F0)
            l_s = ls[mi]
            v = pt_vis(pw, l_s, cfg)
            base = DEEP + WATER_SCATTER * v[:, None]
            col = (1.0 - F)[:, None] * base
            if cfg.water_spec:
                spec = spec_pow(np.maximum(0.0, dot(r, l_s)), 6) * v     # ^64
                col = col + cfg.sun_col * (0.5 * spec)[:, None]
            tw = th[mi]
            acc = tw * col
            if terminal:
                ts_, idx_ = hit_shore(pw, r, cfg)
                env_c = pt_sky(r, cfg, new_diff[mi])
                hs = np.isfinite(ts_)
                env_c[hs] = cfg.palette[idx_[hs]]
                acc = acc + tw * F[:, None] * env_c
                stop[mi] = True
            else:
                th[mi] = tw * F[:, None]
                new_d[mi] = r
            add[mi] = acc
        lsum[ids] += add
        thr[ids] = th
        o[ids] = p
        d[ids] = new_d
        inside[ids] = new_inside
        diffuse[ids] = new_diff
        still = ~stop & (np.max(th, axis=-1) >= PT_THR_MIN)
        alive[ids] = still
    return np.minimum(lsum, knobs.sample_clamp)


def pt_sum_passes(view, n0, n1, knobs, fps=20, batch=4):
    """Sum of the samples of passes n0 .. n1-1, (H, W, 3) float64."""
    preset, t, orbit, height = view
    cfg = pt_config(fps)
    cfg.set_view(preset, t, orbit, height)
    yy, xx = np.mgrid[0:H, 0:W]
    px = xx.reshape(-1).astype(np.uint32)
    py = yy.reshape(-1).astype(np.uint32)
    acc = np.zeros((H * W, 3))
    for a in range(n0, n1, batch):
        b = min(n1, a + batch)
        P = b - a
        n = np.repeat(np.arange(a, b, dtype=np.uint32), H * W)
        s = pt_samples(cfg, knobs, np.tile(px, P), np.tile(py, P), n)
        acc += s.reshape(P, H * W, 3).sum(axis=0)
    return acc.reshape(H, W, 3)


def _pt_worker(job):
    view, n0, n1, kw, fps, batch = job
    return n0, n1, pt_sum_passes(view, n0, n1, PtKnobs(**kw), fps, batch)


def pt_render(view, n0, n1, knobs, fps=20, jobs=1, batch=4, log=None):
    """Mean of passes n0 .. n1-1 (H, W, 3, float64, not saturated), split over
    `jobs` processes in chunks of passes."""
    import time
    total = n1 - n0
    kw = {k: getattr(knobs, k) for k in PtKnobs.DEFAULTS}
    chunk = max(batch, min(64, -(-total // max(1, jobs * 4))))
    work = [(view, a, min(n1, a + chunk), kw, fps, batch) for a in range(n0, n1, chunk)]
    acc = np.zeros((H, W, 3))
    t0 = time.time()
    done = 0
    if jobs <= 1 or len(work) == 1:
        results = map(_pt_worker, work)
        pool = None
    else:
        import multiprocessing as mp
        pool = mp.get_context("fork").Pool(jobs)
        results = pool.imap_unordered(_pt_worker, work)
    try:
        for a, b, s in results:
            acc += s
            done += b - a
            if log:
                el = time.time() - t0
                log(f"reference: pt {view_name(*view)}: {done}/{total} passes, {el:.1f} s "
                    f"({1000.0 * el / done:.0f} ms per pass wall)")
    finally:
        if pool is not None:
            pool.close()
            pool.join()
    return acc / total


def pt_accumulate(view, n1, knobs, seed_rgb=None, fps=20, batch=4):
    """The cart's u32 accumulator after passes 0 .. n1-1 (PLAN.md M4
    "Accumulator": 11:11:10 over [0, 4), m = decode + (s - decode) / (n + 1),
    stochastic rounding from hash(x, y, n, 63)), decoded to (H, W, 3). f64
    arithmetic, so a few values may differ by one step from the cart's f32.
    seed_rgb: the decoded real-time frame (only shows when n1 == 0)."""
    preset, t, orbit, height = view
    cfg = pt_config(fps)
    cfg.set_view(preset, t, orbit, height)
    yy, xx = np.mgrid[0:H, 0:W]
    px = xx.reshape(-1).astype(np.uint32)
    py = yy.reshape(-1).astype(np.uint32)
    scale = np.array([512.0, 512.0, 256.0])
    maxq = np.array([2047.0, 2047.0, 1023.0])
    q = np.zeros((H * W, 3)) if seed_rgb is None else np.minimum(maxq, np.floor(seed_rgb.reshape(-1, 3) * scale))
    for a in range(0, n1, batch):
        b = min(n1, a + batch)
        P = b - a
        n = np.repeat(np.arange(a, b, dtype=np.uint32), H * W)
        s = pt_samples(cfg, knobs, np.tile(px, P), np.tile(py, P), n).reshape(P, H * W, 3)
        for i in range(P):
            nn = a + i
            h = pt_hash(px, py, np.full(H * W, nn, dtype=np.uint32), 63)
            uc = np.stack([(h >> np.uint32(21)) / 2048.0, ((h >> np.uint32(10)) & np.uint32(2047)) / 2048.0,
                           (h & np.uint32(1023)) / 1024.0], axis=-1)
            dec = q / scale
            m_ = dec + (s[i] - dec) / (nn + 1)
            q = np.minimum(maxq, np.floor(m_ * scale + uc))
    return (q / scale).reshape(H, W, 3)


def pt_to8(img):
    """Means saturated to [0, 1] in 8-bit units (the check's unit), float."""
    return clamp01(img) * 255.0


def pt_main(args, ap):
    """reference.py --pt: see the module docstring."""
    import time
    if args.rng_selftest:
        for line in pt_rng_selftest():
            print(line)
        return 0
    try:
        passes_list = [int(v) for v in (args.passes or "").split(",") if v.strip()]
    except ValueError:
        ap.error("--passes takes N or a comma list N1,N2,...")
    if not passes_list or min(passes_list) < 1:
        ap.error("--pt needs --passes N (N >= 1, or a comma list)")
    n0 = args.from_pass
    if n0 and len(passes_list) > 1:
        ap.error("--from needs a single --passes N")
    if not 0 <= n0 < min(passes_list):
        ap.error("--from must be in [0, passes)")
    knobs = PtKnobs(dof=bool(args.dof), lens_radius=args.lens_radius, sun_radius_deg=args.sun_radius,
                    max_bounces=args.max_bounces, water_roughness=args.water_roughness, sky_fill=args.sky_fill,
                    sample_clamp=args.sample_clamp)
    views = list(PT_CHECK_SET) if args.check_set else []
    if args.t is not None or not (args.view or args.check_set):
        t = args.t or 0
        orbit = args.orbit if args.orbit is not None else t
        views.append((args.preset, t, orbit % (30 * args.fps), args.height))
    for v in args.view:
        parts = v.split(":")
        if not 2 <= len(parts) <= 4:
            ap.error(f"--view {v}: want PRESET:T[:ORBIT[:HEIGHT]]")
        t = int(parts[1])
        orbit = int(parts[2]) if len(parts) > 2 and parts[2] != "" else t
        views.append((parse_preset(parts[0]), t, orbit % (30 * args.fps),
                      parse_height(parts[3]) if len(parts) > 3 else DEFAULT_HEIGHT))
    out = args.out or PT_CACHE
    os.makedirs(out, exist_ok=True)
    fps_tag = "" if args.fps == 20 else f"_fps{args.fps}"
    scene = pt_scene_hash(knobs, args.fps)
    print(f"reference: pt scene hash {scene} (stripes {int(PT_STRIPES)}, IRIS_C {IRIS_C.tolist()}), "
          f"{len(views)} views x passes {','.join(map(str, passes_list))}", file=sys.stderr)
    t_all = time.time()
    for view, npass in [(v, n) for v in views for n in passes_list]:
        tag = (f"{'accum' if args.accum else 'pt'}_{view_name(*view)}_n{n0:04d}-{npass:04d}{knobs.tag()}{fps_tag}"
               f"_{scene}")
        base = os.path.join(out, tag)
        if os.path.exists(base + ".npy") and not args.force:
            print(f"reference: cached {base}.npy", file=sys.stderr)
            img = np.load(base + ".npy")
        else:
            t0 = time.time()
            if args.accum:
                if n0 != 0:
                    ap.error("--accum needs --from 0")
                img = pt_accumulate(view, npass, knobs, fps=args.fps, batch=args.batch)
            else:
                img = pt_render(view, n0, npass, knobs, fps=args.fps, jobs=args.jobs, batch=args.batch,
                                log=(lambda s: print(s, file=sys.stderr)) if args.verbose else None)
            el = time.time() - t0
            np.save(base + ".npy", img)
            print(f"reference: {tag}: {npass - n0} passes in {el:.1f} s "
                  f"({1000.0 * el / (npass - n0):.0f} ms per pass, {args.jobs} jobs)", file=sys.stderr)
            write_png(base + ".png", quantise_none(img))
        print(f"reference: wrote {base}.npy and {base}.png", file=sys.stderr)
        print(base + ".npy")
    print(f"reference: pt total {time.time() - t_all:.1f} s", file=sys.stderr)
    return 0


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
    ap.add_argument("--out", default=None, help="output directory (required, except with --pt: default out/pt_ref)")
    ap.add_argument("--motion", type=int, choices=[0, 1], default=1,
                    help="M3 motion master switch: bob, sun drift, rings, stripes (default 1; 0 = M2.2 identity)")
    ap.add_argument("--rings", type=int, choices=[0, 1], default=1, help="M3 knob: rings on the water under each sphere")
    ap.add_argument("--stripes", type=int, choices=[0, 1], default=1, help="M3 knob: stripes on the chrome sphere")
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
    pt = ap.add_argument_group("M4 path tracer (--pt, PLAN.md M4 \"The M4 estimator, exactly\")")
    pt.add_argument("--pt", action="store_true",
                    help="render the M4 path-traced mean of passes --from .. --passes-1 for the view (--preset/--t/"
                         "--orbit/--height or --view); writes pt_<view>_nMMMM-NNNN.npy/.png, cached")
    pt.add_argument("--passes", default=None,
                    help="N: passes 0 .. N-1 (or --from .. N-1); a comma list N1,N2 renders each")
    pt.add_argument("--check-set", action="store_true",
                    help="the check_pt.mjs check set (PT_CHECK_SET: each preset at t 0 orbit 0, sunset t 300, "
                         "noon at height 1.0) in addition to any --view")
    pt.add_argument("--verbose", action="store_true", help="progress lines while rendering")
    pt.add_argument("--from", dest="from_pass", type=int, default=0, help="first pass M (default 0)")
    pt.add_argument("--jobs", type=int, default=os.cpu_count() or 1, help="worker processes (default: all cores)")
    pt.add_argument("--batch", type=int, default=4, help="passes traced together in one vectorised wavefront (4)")
    pt.add_argument("--force", action="store_true", help="ignore the cache and render again")
    pt.add_argument("--accum", action="store_true",
                    help="simulate the cart's u32 11:11:10 accumulator (stochastic rounding) instead of the float "
                         "mean; one process, needs --from 0")
    pt.add_argument("--rng-selftest", action="store_true", help="print lowbias32/hash/R2/to_unit values and exit")
    pt.add_argument("--dof", type=int, choices=[0, 1], default=1, help="knob dof (default 1)")
    pt.add_argument("--lens-radius", type=float, default=0.05, help="knob lens_radius (default 0.05)")
    pt.add_argument("--sun-radius", type=float, default=1.5, help="knob sun_radius in degrees (default 1.5)")
    pt.add_argument("--max-bounces", type=int, default=4, help="knob max_bounces (default 4)")
    pt.add_argument("--water-roughness", type=float, default=0.08, help="knob water_roughness (default 0.08)")
    pt.add_argument("--sky-fill", type=float, default=0.3, help="knob sky_fill (default 0.3)")
    pt.add_argument("--sample-clamp", type=float, default=4.0, help="knob sample_clamp (default 4.0)")
    pre, _ = ap.parse_known_args()
    if pre.variant:
        ap.set_defaults(**VARIANTS[pre.variant])
    args = ap.parse_args()
    if args.fps <= 0:
        ap.error("--fps must be > 0")
    if args.pt or args.rng_selftest:
        return pt_main(args, ap)
    if args.out is None:
        ap.error("--out is required")
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
