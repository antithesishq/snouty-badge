#!/usr/bin/env python3
"""Draw the sprite sheets in assets/gen/ for Snouty Zero (code-drawn art, final per the art policy).

  python3 tools/prepare_assets.py [--contact docs/sprites_contact.png]

The machines are small 3D models (ellipsoids and convex slabs) ray-cast
orthographically at 1 sample per pixel, so the five rival yaws and the
Anteater's leans are views of one shape. Lambert shading is quantised onto
fixed colour ramps, then a 1 px outline is added at the silhouette and at
depth steps. Effects and the Snouty head are drawn directly.

Every sheet is validated against MANIFEST (size, cell grid, <= 15 opaque
colours after the converter's RGB565 cut, key usage, cell borders, the four
machine body colours) and the run exits non-zero on any violation. The
contact sheet (--contact, default docs/sprites_contact.png) tiles every sheet
at 4x with labels plus a 1x/2x mockup on a floor colour. Deterministic.
"""
from __future__ import annotations

import argparse
import math
import random
import sys
from dataclasses import dataclass
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "assets" / "gen"
KEY = (255, 0, 255)  # convert_gfx maps this to palette index 0


def hx(v: int) -> tuple[int, int, int]:
    return ((v >> 16) & 255, (v >> 8) & 255, v & 255)


# ---------------------------------------------------------------- palette
OUTLINE = hx(0x241C22)      # Anteater outline (flyover anteater)
TAN_D = hx(0x7E6E5A)        # Anteater body shadow
TAN = hx(0xB4A48C)          # Anteater body
CREAM = hx(0xECE2CC)        # Anteater body light, band edge
BAND = hx(0x3A3038)         # giant anteater shoulder band, thruster cones
CORAL = hx(0xF18271)        # brand accent
CORAL_D = hx(0xA8504A)      # accent shadow
CYAN = hx(0x4FD6E8)         # thruster glow
CYAN_W = hx(0xE8FCFF)       # thruster core
GLASS = hx(0x1E3446)        # canopy glass
FUR_M = hx(0x662BB8)        # Snouty fur (study05 FUR_DARK / FUR / FUR_LIGHT)
FUR = hx(0x8E42DE)
FUR_L = hx(0xBE7AF3)
EYE = hx(0xF4EFDF)          # study05 WHITE
GLASSES = hx(0x958D9D)      # study05 GREY
S_OUT = hx(0x17121E)        # study05 OUTLINE

# Rival body ramp: the cart recolours rivals by matching exactly these four.
BODY = [hx(0x3C3C50), hx(0x6A6A8C), hx(0x9A9AC0), hx(0xD0D0F0)]
M_OUT = hx(0x141018)        # machine outline and skids
M_GLASS = hx(0x203C50)      # machine canopy
M_GLINT = hx(0x8CE8F0)      # machine canopy glint
SHADOW = hx(0x101014)

WHITE = hx(0xFFFFFF)
YELLOW = hx(0xFFD166)
FLAME_D = hx(0x2A6CB0)


# --------------------------------------------------------------- manifest
@dataclass(frozen=True)
class Sheet:
    name: str
    width: int
    height: int
    cell_w: int
    frames: int
    border_bottom: bool = True  # False: the drawing sits on the cell's bottom row
    border: bool = True         # False: no border rule at all (the shadow)


MANIFEST = {s.name: s for s in [
    Sheet("anteater.png", 160, 24, 40, 4, border_bottom=False),
    Sheet("shadow.png", 32, 6, 32, 1, border=False),
    Sheet("machine.png", 160, 16, 32, 5, border_bottom=False),
    Sheet("fx.png", 96, 16, 16, 6),
    Sheet("snouty_head.png", 24, 8, 12, 2),
]}


# --------------------------------------------------------------- ray caster
def rot(yaw=0.0, roll=0.0, pitch=0.0) -> np.ndarray:
    """Vehicle rotation (degrees): pitch about x (nose up +), roll about y (right side down +),
    yaw about z (nose to screen-left +). Local axes: x right, y forward, z up."""
    a, b, c = (math.radians(v) for v in (yaw, roll, pitch))
    rz = np.array([[math.cos(a), -math.sin(a), 0], [math.sin(a), math.cos(a), 0], [0, 0, 1]])
    ry = np.array([[math.cos(b), 0, math.sin(b)], [0, 1, 0], [-math.sin(b), 0, math.cos(b)]])
    rx = np.array([[1, 0, 0], [0, math.cos(c), -math.sin(c)], [0, math.sin(c), math.cos(c)]])
    return rz @ ry @ rx


@dataclass
class Prim:
    kind: str                 # "ell" or "slab"
    mat: object               # callable(p_local, n_local, lam) -> (N,3) uint8
    c: tuple = (0, 0, 0)      # ellipsoid centre
    r: tuple = (1, 1, 1)      # ellipsoid radii
    planes: list | None = None  # slab: [(n(3), d)] meaning n.p <= d
    glass: bool = False       # see-through to `inside` prims
    inside: bool = False


def ell(c, r, mat, **kw) -> Prim:
    return Prim("ell", mat, c=c, r=r, **kw)


def slab(planes, mat, **kw) -> Prim:
    return Prim("slab", mat, planes=[(np.array(n, float), d) for n, d in planes], **kw)


def box(x0, x1, y0, y1, z0, z1, mat, extra=()) -> Prim:
    return slab([((1, 0, 0), x1), ((-1, 0, 0), -x0), ((0, 1, 0), y1), ((0, -1, 0), -y0),
                 ((0, 0, 1), z1), ((0, 0, -1), -z0), *extra], mat)


def intersect(p: Prim, o: np.ndarray, d: np.ndarray):
    """(t_hit, normal) per ray; t = inf where missed."""
    n = len(o)
    if p.kind == "ell":
        r = np.array(p.r, float)
        oo, dd = (o - np.array(p.c, float)) / r, d / r
        a = (dd * dd).sum(1)
        b = (oo * dd).sum(1)
        cc = (oo * oo).sum(1) - 1
        disc = b * b - a * cc
        hit = disc >= 0
        t = np.full(n, np.inf)
        t[hit] = (-b[hit] - np.sqrt(disc[hit])) / a[hit]
        t[t < 0] = np.inf
        q = oo + dd * np.where(np.isfinite(t), t, 0)[:, None]
        nrm = q / r
        return t, nrm / np.maximum(np.linalg.norm(nrm, axis=1, keepdims=True), 1e-9)
    t0, t1 = np.full(n, -np.inf), np.full(n, np.inf)
    nrm = np.zeros((n, 3))
    for pn, pd in p.planes:
        dn, on = d @ pn, o @ pn
        with np.errstate(divide="ignore", invalid="ignore"):
            t = (pd - on) / dn
        enter = dn < 0
        upd = enter & (t > t0)
        t0 = np.where(upd, t, t0)
        nrm[upd] = pn / np.linalg.norm(pn)
        t1 = np.where((dn > 0) & (t < t1), t, t1)
        t1 = np.where((np.abs(dn) < 1e-12) & (on > pd), -np.inf, t1)
    t = np.where((t0 <= t1) & (t0 > 0), t0, np.inf)
    return t, nrm


LIGHT = np.array([-0.45, -0.55, 0.75]) / np.linalg.norm([-0.45, -0.55, 0.75])


def render(prims: list[Prim], cw: int, ch: int, scale: float, pitch: float, R: np.ndarray,
           outline=OUTLINE, depth_edge=0.35, ground: float = 0.0):
    """Ray-cast the model into a cw x ch cell, bottom-aligned on the last row, centred on the
    model origin. pitch = camera look-down angle (degrees)."""
    W, H = cw * 2, ch * 3
    p = math.radians(pitch)
    fwd = np.array([0, math.cos(p), -math.sin(p)])
    up = np.array([0, math.sin(p), math.cos(p)])
    jj, ii = np.mgrid[0:H, 0:W]
    sx = (ii.ravel() + 0.5 - W / 2) / scale
    sy = (H / 2 - (jj.ravel() + 0.5)) / scale
    o_w = sx[:, None] * np.array([1, 0, 0]) + sy[:, None] * up - fwd * 50
    o_l, d_l = o_w @ R, np.tile(fwd @ R, (len(o_w), 1))   # R^T applied to row vectors
    hits = [intersect(pr, o_l, d_l) for pr in prims]
    ts = np.stack([h[0] for h in hits])
    solid = np.array([not pr.glass for pr in prims])
    ts_s = np.where(solid[:, None], ts, np.inf)
    ts_g = np.where(~solid[:, None], ts, np.inf)
    k_s, t_s = ts_s.argmin(0), ts_s.min(0)
    k_g, t_g = ts_g.argmin(0), ts_g.min(0)
    inside = np.array([pr.inside for pr in prims])[k_s]
    use_g = np.isfinite(t_g) & (t_g < t_s) & ~(inside & np.isfinite(t_s))
    k = np.where(use_g, k_g, k_s)
    t = np.where(use_g, t_g, t_s)
    rgb = np.zeros((len(t), 3), np.uint8)
    for i, pr in enumerate(prims):
        m = (k == i) & np.isfinite(t)
        if not m.any():
            continue
        pl = o_l[m] + d_l[m] * t[m][:, None]
        nl = hits[i][1][m]
        lam = np.clip((nl @ R.T) @ LIGHT, 0, 1)
        rgb[m] = pr.mat(pl, nl, lam)
    hit = np.isfinite(t).reshape(H, W)
    rgb, depth = rgb.reshape(H, W, 3), np.where(hit, t.reshape(H, W), np.inf)
    # interior lines: a pixel whose neighbour is clearly nearer gets the outline colour
    edge = np.zeros_like(hit)
    for dy, dx in ((1, 0), (-1, 0), (0, 1), (0, -1)):
        nb = np.roll(np.roll(depth, dy, 0), dx, 1)
        edge |= hit & (nb < depth - depth_edge)
    rgb[edge] = outline
    sil = np.zeros_like(hit)
    for dy, dx in ((1, 0), (-1, 0), (0, 1), (0, -1)):
        sil |= np.roll(np.roll(hit, dy, 0), dx, 1)
    sil &= ~hit
    rgb[sil] = outline
    mask = hit | sil
    ys = np.nonzero(mask.any(1))[0]
    shift = (ch - 1) - ys[-1]                     # bottom-align
    xs = np.nonzero(mask.any(0))[0]
    x0 = (xs[0] + xs[-1] + 1) // 2 - cw // 2          # centre the silhouette
    cell = np.full((ch, cw, 3), KEY, np.uint8)
    y_src = np.arange(ch) - shift
    ok = (y_src >= 0) & (y_src < H)
    src = rgb[y_src[ok], x0:x0 + cw]
    msk = mask[y_src[ok], x0:x0 + cw]
    sub = cell[ok]
    sub[msk] = src[msk]
    cell[ok] = sub
    lost = mask.sum() - msk.sum()
    if lost:
        print(f"  warning: {lost} px of the model fall outside the {cw}x{ch} cell")
    return cell


def ramp(cols, cuts):
    """Material: lambert -> colour by thresholds (len(cuts) == len(cols) - 1)."""
    lut = np.array(cols, np.uint8)
    return lambda p, n, lam: lut[np.searchsorted(np.array(cuts), lam)]


def flat(col):
    return lambda p, n, lam: np.tile(np.array(col, np.uint8), (len(lam), 1))


# ----------------------------------------------------------- the Anteater
def anteater_model(tucked: bool = False) -> list[Prim]:
    tan3 = [TAN_D, TAN, CREAM]

    def hull(p, n, lam):
        out = np.array(tan3, np.uint8)[np.searchsorted([0.35, 0.8], lam)]
        x, y, z = p[:, 0], p[:, 1], p[:, 2]
        band = y - 0.6 * np.abs(x)                       # the shoulder band, a chevron pointing back
        out[(band > -1.0) & (band < -0.78)] = BAND
        out[(band >= -0.78) & (band < -0.66)] = CREAM
        stripe = (z < 0.34) & (z > 0.22)                 # coral waterline
        out[stripe & (lam >= 0.35)] = CORAL
        out[stripe & (lam < 0.35)] = CORAL_D
        return out

    def snout(p, n, lam):
        out = np.array(tan3, np.uint8)[np.searchsorted([0.3, 0.72], lam)]
        out[p[:, 1] > SNOUT_TIP - 0.12] = OUTLINE        # dark nose
        return out

    fur = ramp([FUR_M, FUR, FUR_L], [0.35, 0.8])
    ear = ramp([FUR, FUR_L], [0.4])
    prims = [
        ell((0, -0.2, 0.48), (1.1, 1.2, 0.4), hull),
        ell((0, HEAD_Y, 0.8), (0.42, 0.55, 0.34), flat(GLASS), glass=True),   # humped canopy
        ell((0, HEAD_Y - 0.02, 0.82), (0.25, 0.22, 0.24), fur, inside=True),  # Snouty's head
        ell((-0.2, HEAD_Y - 0.1, 1.0), (0.12, 0.07, 0.12), ear, inside=True),   # ears
        ell((0.2, HEAD_Y - 0.1, 1.0), (0.12, 0.07, 0.12), ear, inside=True),
        ell((0, HEAD_Y + 0.28, 0.8), (0.08, 0.2, 0.08), fur, inside=True),    # his snout, forward
    ]
    # the Anteater's snout: rises off the hull nose, then droops to the tip
    pts = [(0.7, 0.62, 0.3), (1.05, 0.78, 0.27), (1.4, 0.83, 0.23), (1.8, 0.76, 0.19),
           (2.15, 0.6, 0.15), (2.45, 0.42, 0.13), (SNOUT_TIP - 0.1, 0.28, 0.11)]
    for y, z, r in pts:
        prims.append(ell((0, y, z), (r * 1.1, r * 1.5, r), snout))
    for sx in (-1, 1):
        prims += [
            ell((sx * 0.55, -1.15, 0.45), (0.3, 0.36, 0.27), ramp([BAND, OUTLINE], [0.0])),    # cones
            ell((sx * 0.55, -1.48, 0.45), (0.19, 0.04, 0.17), lambda p, n, lam, sx=sx: np.where(
                ((p[:, 0] - sx * 0.55) ** 2 + (p[:, 2] - 0.45) ** 2 < 0.008)[:, None],
                np.array(CYAN_W, np.uint8), np.array(CYAN, np.uint8))),                         # glow
            box(sx * 1.16 - 0.08, sx * 1.16 + 0.08, -0.9, 0.1, 0.24, 0.38, ramp([CORAL_D, CORAL], [0.5])),  # side fins
        ]
        if tucked:   # skids folded away: the hover pads glow on the underside
            prims.append(ell((sx * 0.5, -0.45, 0.1), (0.3, 0.8, 0.05), flat(CYAN)))
        else:
            prims.append(box(sx * 0.6 - 0.1, sx * 0.6 + 0.1, -0.9, 0.6, 0.0, 0.1, flat(OUTLINE)))   # skids
    return prims


SNOUT_TIP = 2.75
HEAD_Y = -0.55          # canopy and head position along the hull
CAM_PITCH = 26          # camera look-down angle for the player machine (degrees)


def draw_anteater() -> np.ndarray:
    poses = [rot(), rot(yaw=8, roll=-12), rot(yaw=-8, roll=12), rot(pitch=-10)]
    cells = []
    for i, R in enumerate(poses):   # hop: nose dipped 10 degrees, skids folded, hover pads show
        cells.append(render(anteater_model(tucked=i == 3), 40, 24, 9.7, CAM_PITCH, R))
    return np.concatenate(cells, 1)


# ------------------------------------------------------- the rival machine
def machine_model() -> list[Prim]:
    body = ramp(BODY, [0.25, 0.5, 0.78])

    def canopy(p, n, lam):
        return np.where((lam > 0.85)[:, None], np.array(M_GLINT, np.uint8), np.array(M_GLASS, np.uint8))

    def glow(p, n, lam):
        core = (np.abs(p[:, 0]) - 0.66) ** 2 + (p[:, 2] - 0.3) ** 2 < 0.004
        return np.where(core[:, None], np.array(CYAN_W, np.uint8), np.array(CYAN, np.uint8))

    # wedge hull: flat bottom, rear face, top sloping down to the nose, tapered sides, chamfers
    wedge = slab([((0, 0, -1), -0.12), ((0, -1, 0), 0.9), ((0, 1, 0), 0.95),
                  ((0, 0.16, 1), 0.42), ((1, 0.29, 0), 0.5), ((-1, 0.29, 0), 0.5),
                  ((0.8, 0.1, 1), 0.85), ((-0.8, 0.1, 1), 0.85)], body)
    prims = [wedge,
             ell((0, -0.2, 0.5), (0.26, 0.4, 0.16), canopy),
             box(-0.035, 0.035, -0.9, -0.5, 0.3, 0.76, body, extra=[((0, 0.6, 1), 0.2)])]   # tail fin
    for sx in (-1, 1):
        prims += [ell((sx * 0.66, -0.5, 0.3), (0.18, 0.42, 0.17), body),                     # pods
                  ell((sx * 0.66, -0.93, 0.3), (0.13, 0.03, 0.12), glow),
                  box(sx * 0.55 - 0.05, sx * 0.55 + 0.05, -0.6, 0.45, 0.02, 0.12, flat(M_OUT))]  # skids
    return prims


MACHINE_YAWS = [0, 45, -45, 90, -90]  # + = nose toward screen-left


def draw_machine() -> np.ndarray:
    m = machine_model()
    return np.concatenate([render(m, 32, 16, 12.0, CAM_PITCH, rot(yaw=y), outline=M_OUT) for y in MACHINE_YAWS], 1)


# --------------------------------------------------------------- shadow
def draw_shadow() -> np.ndarray:
    yy, xx = np.mgrid[0:6, 0:32]
    m = ((xx + 0.5 - 16) / 16) ** 2 + ((yy + 0.5 - 3) / 3) ** 2 <= 1.0
    a = np.full((6, 32, 3), KEY, np.uint8)
    a[m] = SHADOW
    return a


# --------------------------------------------------------------- effects
def draw_fx() -> np.ndarray:
    a = np.full((16, 96, 3), KEY, np.uint8)
    rng = random.Random(7)
    rays = [(k * math.pi / 4 + rng.uniform(-0.25, 0.25), rng.uniform(0.8, 1.0)) for k in range(8)]
    # spark burst: (inner, outer radius, head colour, tail colour, rays kept)
    burst = [(0.0, 3.0, WHITE, YELLOW, 8), (2.0, 5.0, WHITE, YELLOW, 8),
             (4.0, 6.6, YELLOW, CORAL, 8), (5.6, 6.9, CORAL, CORAL_D, 4)]
    for f, (r0, r1, head, tail, keep) in enumerate(burst):
        for k, (ang, sc) in enumerate(rays):
            if keep < 8 and k % 2:
                continue
            steps = int((r1 - r0) * 2) + 1
            for j in range(steps + 1):
                rr = (r0 + (r1 - r0) * j / steps) * sc
                x, y = int(round(7.5 + rr * math.cos(ang))), int(round(7.5 + rr * math.sin(ang)))
                if 1 <= x <= 14 and 1 <= y <= 14:
                    a[y, f * 16 + x] = head if j >= steps - 1 else tail
    a[6:10, 7:9] = WHITE                                 # frame 0: the flash at the centre
    a[7:9, 6:10] = WHITE
    a[7:9, 23:25] = YELLOW
    for f, (rw, rh) in enumerate([(3.0, 5.5), (4.5, 6.8)]):   # exhaust flames, round end up
        yy, xx = np.mgrid[0:16, 0:16]
        cx, cy = 7.5, 4.5
        u, v = (xx + 0.5 - 8) / rw, (yy + 0.5 - cy - 0.5)
        shape = np.where(v < 0, u ** 2 + (v / (rw * 0.9)) ** 2, u ** 2 / np.maximum(1 - v / (rh + 4), 0.01) ** 2)
        cell = np.full((16, 16, 3), KEY, np.uint8)
        for lim, col in [(1.0, FLAME_D), (0.62, CYAN), (0.28, CYAN_W)]:
            cell[(shape <= lim) & (yy >= 1) & (yy <= 14) & (xx >= 1) & (xx <= 14)] = col
        a[:, 64 + f * 16:80 + f * 16] = cell
    return a


# --------------------------------------------------------- Snouty head 12x8
# Study05 Snouty in profile facing right: round purple head, ear, big eye
# behind round glasses, long snout with a light tip. o outline, m/f/l fur
# ramp, w eye white, k pupil, g glasses, p tongue. Hit: eye squeezed shut,
# mouth open with the tongue out.
HEAD = [
    "............",
    "..oo........",
    ".olfoooo....",
    ".offfgwwgo..",
    ".offfgwkgoo.",
    ".ommffggffl.",
    "..ommmoooo..",
    "............",
]
HEAD_HIT = [
    "............",
    "..oo........",
    ".olfoooo....",
    ".offfgffgo..",
    ".offfgkkgoo.",
    ".ommffggffl.",
    "..ommmoppp..",
    "............",
]
HEAD_CMAP = {"o": S_OUT, "p": CORAL, "m": FUR_M, "f": FUR, "l": FUR_L, "w": EYE, "k": S_OUT, "g": GLASSES}


def draw_head() -> np.ndarray:
    a = np.full((8, 24, 3), KEY, np.uint8)
    for f, rows in enumerate((HEAD, HEAD_HIT)):
        for y, row in enumerate(rows):
            for x, ch in enumerate(row):
                if ch != ".":
                    a[y, f * 12 + x] = HEAD_CMAP[ch]
    return a


DRAW = {"anteater.png": draw_anteater, "shadow.png": draw_shadow, "machine.png": draw_machine,
        "fx.png": draw_fx, "snouty_head.png": draw_head}


# ------------------------------------------------------------- validation
def q565(a: np.ndarray) -> np.ndarray:
    """The converter's cut (cart/build/convert_gfx.zig): floor(31 r/255), floor(63 g/255), floor(31 b/255)."""
    a = a.astype(np.uint32)
    return ((a[..., 0] * 31 // 255) << 11) | ((a[..., 1] * 63 // 255) << 5) | (a[..., 2] * 31 // 255)


KEY565 = (31 << 11) | 31


def validate(s: Sheet, a: np.ndarray) -> list[str]:
    err = []
    h, w = a.shape[:2]
    if (w, h) != (s.width, s.height):
        err.append(f"size {w}x{h}, expected {s.width}x{s.height}")
        return err
    if s.width != s.cell_w * s.frames:
        err.append("manifest cell grid inconsistent")
    key = (a == KEY).all(2)
    q = q565(a)
    if ((q == KEY565) & ~key).any():
        err.append("opaque pixels collapse to the key after RGB565")
    if not key.any():
        err.append("no key pixels")
    cols = np.unique(q[~key])
    if len(cols) > 15:
        err.append(f"{len(cols)} opaque colours after RGB565, max 15")
    for i in range(s.frames):
        c = ~key[:, i * s.cell_w:(i + 1) * s.cell_w]
        if not c.any():
            err.append(f"cell {i} empty")
        if s.border:
            sides = {"top": c[0].any(), "left": c[:, 0].any(), "right": c[:, -1].any(),
                     "bottom": s.border_bottom and c[-1].any()}
            if any(sides.values()):
                err.append(f"cell {i} touches its border: {', '.join(k for k, v in sides.items() if v)}")
        if not s.border_bottom and not c[-1].any():
            err.append(f"cell {i}: nothing on the bottom (floor) row")
    body = [q565(np.array([c], np.uint8))[0] for c in BODY]
    exact = [(a == c).all(2) for c in BODY]
    near = np.isin(q, body)
    if s.name == "machine.png":
        for c, m in zip(BODY, exact):
            if not m.any():
                err.append(f"body colour #{c[0]:02X}{c[1]:02X}{c[2]:02X} unused")
        if (near & ~np.any(exact, 0)).any():
            err.append("a non-body colour quantises onto a body colour")
    elif near.any():
        err.append("uses a machine body colour (reserved for machine.png)")
    print(f"{s.name:16s} {w}x{h}  {s.frames} x {s.cell_w}x{h}  opaque colours {len(cols)}/15")
    for e in err:
        print(f"{'':16s} ERROR {e}")
    return err


# ----------------------------------------------------------- contact sheet
def checker(h, w, k=8):
    yy, xx = np.mgrid[0:h, 0:w]
    out = np.empty((h, w, 3), np.uint8)
    out[:] = (46, 42, 56)
    out[((yy // k + xx // k) % 2).astype(bool)] = (60, 56, 72)
    return out


def paste(dst, src, x, y):
    m = ~(src == KEY).all(2)
    d = dst[y:y + src.shape[0], x:x + src.shape[1]]
    d[m] = src[m]


def mockup(sheets) -> np.ndarray:
    """160x40 strip at 1x: every sprite on a floor colour, shadows under the Anteaters."""
    f = np.zeros((40, 160, 3), np.uint8)
    f[:] = (70, 78, 92)
    f[::4, :] = (84, 92, 108)
    a, m, fx, hd, sh = (sheets[n] for n in ("anteater.png", "machine.png", "fx.png", "snouty_head.png", "shadow.png"))
    for i in range(4):
        x = i * 40
        sm = f[34:40, x + 4:x + 36]
        sm[~(sh == KEY).all(2)] = SHADOW
        paste(f, a[:, i * 40:(i + 1) * 40], x, 36 - 24 - (6 if i == 3 else 0))
    return f, np.concatenate([m, np.full((16, 4, 3), KEY, np.uint8), fx], 1), hd


def write_contact(path: Path, sheets: dict) -> None:
    k = 4
    items = []
    for name, s in MANIFEST.items():
        a = sheets[name]
        img = checker(a.shape[0] * k, a.shape[1] * k)
        big = a.repeat(k, 0).repeat(k, 1)
        msk = ~(big == KEY).all(2)
        img[msk] = big[msk]
        for i in range(1, s.frames):
            img[:, i * s.cell_w * k] = (22, 20, 28)
        items.append((f"{name}  {s.frames} x {s.cell_w}x{s.height}, 4x", img))
    floor, row2, hd = mockup(sheets)
    r2 = np.zeros((16, row2.shape[1] + 30, 3), np.uint8)
    r2[:] = (70, 78, 92)
    paste(r2, row2, 0, 0)
    paste(r2, hd, row2.shape[1] + 4, 4)
    both = np.zeros((40 + 4 + 16, max(160, r2.shape[1]), 3), np.uint8)
    both[:] = (22, 20, 28)
    both[:40, :160] = floor
    both[44:, :r2.shape[1]] = r2
    for z in (1, 2):
        items.append((f"mockup on a floor colour, {z}x", both.repeat(z, 0).repeat(z, 1)))
    pad, lh = 12, 20
    W = max(i.shape[1] for _, i in items) + 2 * pad
    H = sum(i.shape[0] + lh + pad for _, i in items) + pad
    out = np.zeros((H, W, 3), np.uint8)
    out[:] = (22, 20, 28)
    y, labels = pad, []
    for label, img in items:
        labels.append((y, label))
        y += lh
        out[y:y + img.shape[0], pad:pad + img.shape[1]] = img
        y += img.shape[0] + pad
    im = Image.fromarray(out, "RGB")
    d = ImageDraw.Draw(im)
    font = ImageFont.load_default(size=14)
    for ly, label in labels:
        d.text((pad, ly), label, fill=(220, 216, 228), font=font)
    path.parent.mkdir(parents=True, exist_ok=True)
    im.save(path, optimize=True)
    print(f"contact sheet {path} {W}x{H}")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--contact", type=Path, default=ROOT / "docs" / "sprites_contact.png",
                    help="contact sheet path (default docs/sprites_contact.png)")
    args = ap.parse_args()
    OUT.mkdir(parents=True, exist_ok=True)
    errors, sheets = 0, {}
    for name, s in MANIFEST.items():
        a = DRAW[name]()
        sheets[name] = a
        errs = validate(s, a)
        errors += len(errs)
        if not errs:
            Image.fromarray(a, "RGB").save(OUT / name, optimize=True)
    path = args.contact if args.contact.is_absolute() else Path.cwd() / args.contact
    write_contact(path, sheets)
    print("OK" if not errors else f"{errors} error(s); failing sheets not written")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
