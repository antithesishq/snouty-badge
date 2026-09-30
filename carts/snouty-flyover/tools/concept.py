#!/usr/bin/env python3
"""Snouty Flyover concept renderer: "Memory Lane".

A host-side reference for the badge cart. Two halves, kept apart on purpose:

  * RENDERER (render, shade, sky): Comanche-style voxel space. One ray per
    screen column marched across a wrapping 256-wide heightmap + colour map,
    spans filled bottom-up against a per-column occlusion row, cliff faces
    drawn with the colour's side entry, 8-level dithered distance fog, a
    second march for water reflections, RGB565 output.
  * WORLD (World, gen_*): the address space. A 2048-row strip of districts
    (SORT, TREE, HASH, STACK, HEAP, PIPELINE), each preceded by a BUS
    segment, on a noisy "noise floor" with cache-line grid lines.

Usage:  python3 concept.py --out ../docs/concept --stills --gif
"""
import argparse
import math
import os
import re

import numpy as np
from PIL import Image, ImageDraw, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))

# --------------------------------------------------------------- parameters
SW, SH = 160, 128               # badge screen
MAP_W, MAP_H = 256, 2048        # map: x wraps at 256, y (flight) wraps at 2048
FLOOR, WATER = 28, 16           # noise-floor mean height, water plane
VIEW = 280.0                    # primary march distance (cells)
REFL_VIEW = 200.0               # reflection march distance
STEP0, STEP_GROW = 1.0, 1.007   # first step, per-step growth (~160 steps)
FOV = 0.8                       # tan(half horizontal FOV), ~77 degrees
SCALE = SW / 2 / FOV            # projection scale, square pixels (100)
FOG_NEAR, FOG_LEVELS, FOG_CURVE = 60.0, 8, 1.4
FACE_JUMP = 2                   # height jump along a ray that counts as a wall
SIDE_FRONT = 0.55              # fallback shade for faces facing -y (sun is ahead)
SIDE_X_MIX = 0.35              # x-facing walls: side colour mixed this much toward top
BAYER = np.array([[0, 8, 2, 10], [12, 4, 14, 6], [3, 11, 1, 9], [15, 7, 13, 5]]) / 16.0
BAY = np.tile(BAYER, (SH // 4, SW // 4))

SKY_TOP, SKY_HZ, SKY_WARM, FOG_HEX = 0x06040F, 0x2A1A5E, 0x7A3A2A, 0x3A2258
SUN_HEX, SUN_W, SUN_UP = 0xFFB040, 66, 20  # sun: core, width px, centre px above horizon

# palette layout (the cart copies this)
P_FLOOR, P_GRID, P_RUBBLE, P_WATER, P_WHITE = 0, 16, 20, 24, 31
P_A_COMET, P_A_DASH, P_B_COMET, P_B_DASH = 32, 48, 64, 80
P_DISTRICT = 96
EMISSIVE = (31, 96)             # half-strength fog for [31, 96)


def rgb(h):
    return np.array([(h >> 16) & 255, (h >> 8) & 255, h & 255], float)


def lerp(a, b, t):
    return a + (b - a) * t


def iris_rows():
    src = open(os.path.join(HERE, '..', '..', '..', 'lib', 'iris_mark.zig')).read()
    body = src[src.index('pub const rows'):]
    bits = re.findall(r'0b([01]{24})', body)[:24]
    return np.array([[ch == '1' for ch in b] for b in bits])


IRIS = iris_rows()


# ------------------------------------------------------------------ palette
class Palette:
    """256 RGB entries; 96-255 hold (top, side) pairs, top at the even index."""

    def __init__(self):
        self.rgb = np.zeros((256, 3))
        self.side = np.zeros((256, 3))
        self.next = P_DISTRICT
        self.cycles = []                      # (base, 16-entry gradient, speed)
        for i in range(16):
            self.rgb[P_FLOOR + i] = lerp(rgb(0x141833), rgb(0x1E2450), i / 15)
        for i in range(4):
            self.rgb[P_GRID + i] = lerp(rgb(0x283060), rgb(0x34407A), i / 3)
            self.rgb[P_RUBBLE + i] = lerp(rgb(0x2A2436), rgb(0x40364A), i / 3)
            self.rgb[P_WATER + i] = lerp(rgb(0x1050A0), rgb(0x0A3070), i / 3)
        self.rgb[28:31] = rgb(0x606880)
        self.rgb[P_WHITE] = rgb(0xF0F8FF)
        comet = [max(0.0, 1 - m / 8) ** 1.4 for m in range(16)]
        dash = [1, 1, .85, .6] + [0.0] * 12
        cyan = (rgb(0x0A2436), rgb(0x40E0FF), rgb(0xE8FFFF))
        amber = (rgb(0x301804), rgb(0xFFB040), rgb(0xFFF4D0))
        self.side[:P_DISTRICT] = self.rgb[:P_DISTRICT] * SIDE_FRONT
        self.side[P_WHITE] = self.rgb[P_WHITE] * 0.8
        # A pulse range has ONE fixed face colour, that of the structures it is
        # painted on: a ray sample landing on a path cell inside a ridge would
        # otherwise draw that ridge's wall in the pulse colour (stripes).
        self.cycle(P_A_COMET, cyan, comet, 1, 0x0E6A64)   # free list, hash lanes: teal
        self.cycle(P_A_DASH, cyan, dash, 2, 0x121830)     # bus lanes, packets: road
        self.cycle(P_B_COMET, amber, comet, 1, 0x1C7040)  # tree search path: green
        self.cycle(P_B_DASH, amber, dash, 2, 0x121830)    # bus, rehash seam, stack

    def cycle(self, base, cols, profile, speed, face):
        self.side[base:base + 16] = rgb(face)
        dark, mid, head = cols
        g = np.zeros((16, 3))
        for j in range(16):
            b = profile[(-j) % 16]            # grad[j]: head at 0, tail behind it
            g[j] = lerp(dark, mid, b / 0.6) if b < 0.6 else lerp(mid, head, (b - 0.6) / 0.4)
        self.cycles.append((base, g, speed))
        self.rgb[base:base + 16] = g

    def pair(self, top, side=None):
        i = self.next
        assert i < 256, 'palette full'
        self.next += 2
        self.rgb[i] = rgb(top)
        self.rgb[i + 1] = rgb(side) if side is not None else rgb(top) * SIDE_FRONT
        return i

    def at(self, frame):
        """Top and front-face RGB tables for this frame (pulse ranges rotated)."""
        top = self.rgb.copy()
        for base, g, speed in self.cycles:
            top[base:base + 16] = g[(np.arange(16) - frame * speed) % 16]
        side = self.side.copy()
        side[P_DISTRICT::2] = top[P_DISTRICT + 1::2]
        return top, side


# ----------------------------------------------------------------- renderer
def fog_amount(z, emissive):
    """8 fog levels, 4x4 Bayer dither between adjacent levels -> blend 0..1."""
    f = np.clip((z - FOG_NEAR) / (VIEW - FOG_NEAR), 0, 1) ** FOG_CURVE
    lvl = np.clip(np.floor(f * (FOG_LEVELS - 1) + BAY), 0, FOG_LEVELS - 1)
    lvl = np.where(emissive, lvl // 2, lvl)
    return (lvl / (FOG_LEVELS - 1))[..., None]


def sky(v, cols, cam):
    """Sky colour at horizon-relative row v (negative = above horizon)."""
    d = -v
    stops = [(-1, FOG_HEX), (0, SKY_WARM), (3, 0x4A2448), (16, SKY_HZ), (95, SKY_TOP)]
    xp = [s[0] for s in stops]
    out = np.stack([np.interp(d, xp, [rgb(s[1])[k] for s in stops]) for k in range(3)], -1)
    sun_x = (SW - 1) / 2 - math.tan(cam['yaw']) * SCALE
    sc = SUN_W / 24
    r = np.hypot(cols - sun_x, (v + SUN_UP) * 1.0)
    glow = np.clip(1 - r / (SUN_W * 0.8), 0, 1) ** 2 * 0.45
    out = lerp(out, rgb(0x8A3048), glow[..., None])
    su = np.floor((cols - sun_x) / sc + 12).astype(int)
    sv = np.floor((v + SUN_UP) / sc + 12).astype(int)
    inside = (su >= 0) & (su < 24) & (sv >= 0) & (sv < 24)
    bit = inside & IRIS[np.clip(sv, 0, 23), np.clip(su, 0, 23)]
    core = lerp(rgb(0xFFD878), rgb(0xFF7A30), np.clip(sv / 23, 0, 1)[..., None])
    core = lerp(core, rgb(SUN_HEX), 0.35)
    haze = np.clip((14 - d) / 20, 0, 0.55)[..., None]
    out = np.where(bit[..., None], lerp(core, rgb(SKY_WARM), haze), out)
    xw = np.round(cols - sun_x * 0.5).astype(np.int64)
    hsh = (xw * 374761393 + np.round(v).astype(np.int64) * 668265263) & 0xFFFFFFFF
    hsh = ((hsh ^ (hsh >> 13)) * 1274126177) & 0xFFFFFFFF
    star = (d > 34) & ((hsh >> 8) % 1000 < 5) & ~bit
    return np.where(star[..., None], np.where(((hsh >> 4) & 1)[..., None] == 1,
                                              rgb(0xE0E4FF), rgb(0x7078B0)), out)


def march(H, C, cam, dist):
    """Yield (z, height, colour, iy, ix) per step for all 160 columns."""
    cols = np.arange(SW)
    u = (cols - (SW - 1) / 2) / (SW / 2) * FOV
    s, c = math.sin(cam['yaw']), math.cos(cam['yaw'])
    dx, dy = s + u * c, c - u * s
    z, dz = 1.0, STEP0
    while z < dist:
        ix = np.floor(cam['x'] + dx * z).astype(np.int64) & (MAP_W - 1)
        iy = np.floor(cam['y'] + dy * z).astype(np.int64) % MAP_H
        yield z, H[iy, ix].astype(float), C[iy, ix], iy, ix
        z += dz
        dz *= STEP_GROW


def render(H, C, pal, cam, frame=0):
    """Draw one 160x128 frame. Returns float RGB (SH, SW, 3), not yet quantised."""
    top_rgb, side_rgb = pal.at(frame)
    cols = np.arange(SW)
    rows = np.arange(SH)[:, None]
    hz = cam['hz'] - (cols - (SW - 1) / 2) * math.tan(cam['roll'])   # roll = shear
    alt = cam['alt']
    ybuf = np.full(SW, SH)
    idx = np.zeros((SH, SW), np.uint8)
    zb = np.full((SH, SW), np.inf)
    face = np.zeros((SH, SW), np.uint8)
    cx, cy = int(math.floor(cam['x'])) & (MAP_W - 1), int(math.floor(cam['y'])) % MAP_H
    prev_h, prev_iy = np.full(SW, float(H[cy, cx])), np.full(SW, cy)
    for z, h, c, iy, ix in march(H, C, cam, VIEW):
        top = np.clip(np.ceil(hz + (alt - h) * SCALE / z), 0, SH).astype(int)
        if (top < ybuf).any():
            jump = h - prev_h > FACE_JUMP
            xface = H[prev_iy, ix] >= h - FACE_JUMP      # entered through a side wall
            f = np.where(jump, np.where(xface, 2, 1), 0).astype(np.uint8)
            m = (rows >= top) & (rows < ybuf)
            idx = np.where(m, c, idx)
            zb = np.where(m, z, zb)
            face = np.where(m, f, face)
            ybuf = np.minimum(ybuf, top)
            if (ybuf <= 0).all():
                break
        prev_h, prev_iy = h, iy
    # second march: reflections for water pixels (mirror the ray in the plane)
    water = (idx >= P_WATER) & (idx < P_WATER + 4) & np.isfinite(zb)
    ridx = np.zeros((SH, SW), np.uint8)
    rz = np.full((SH, SW), np.inf)
    ripple = 0.010 * np.sin(rows * 1.9 + frame * 0.8) + 0.004 * np.sin(rows * 0.7 - frame * 0.5)
    if water.any():
        e = (rows - hz) / SCALE + ripple               # mirrored ray slope per pixel
        altp = 2 * WATER - alt
        done = ~water
        for z, h, c, _, _ in march(H, C, cam, REFL_VIEW):
            mh = altp + e * z                          # mirrored ray height at z
            hit = ~done & (h >= mh) & (mh > WATER)
            if hit.any():
                ridx = np.where(hit, c, ridx)
                rz = np.where(hit, z, rz)
                done |= hit
            if done.all():
                break
    return shade(idx, zb, face, water, ridx, rz, hz, top_rgb, side_rgb, cam)


def shade(idx, zb, face, water, ridx, rz, hz, top_rgb, side_rgb, cam):
    cols = np.arange(SW)[None, :]
    rows = np.arange(SH)[:, None]
    v = rows - hz[None, :]
    emis = (idx >= EMISSIVE[0]) & (idx < EMISSIVE[1])
    base = np.where((face == 0)[..., None], top_rgb[idx],
                    np.where((face == 1)[..., None], side_rgb[idx],
                             lerp(side_rgb[idx], top_rgb[idx], np.where(emis, 0, SIDE_X_MIX)[..., None])))
    fogc = rgb(FOG_HEX)
    out = lerp(base, fogc, fog_amount(zb, emis))
    # water: reflected terrain (fogged by its own distance) or mirrored sky
    remis = (ridx >= EMISSIVE[0]) & (ridx < EMISSIVE[1])
    refl = np.where(np.isfinite(rz)[..., None],
                    lerp(top_rgb[ridx] * 0.85, fogc, fog_amount(rz, remis)),
                    sky(-v, cols, cam))
    graze = np.clip(1 - v / 70, 0, 1)[..., None]
    wcol = lerp(rgb(0x0C2C66), refl, 0.45 + 0.45 * graze) * 0.92
    wcol = lerp(wcol, fogc, fog_amount(zb, np.ones_like(water)) * 0.6)
    out = np.where(water[..., None], wcol, out)
    empty = ~np.isfinite(zb)
    s = sky(v, cols, cam) + (BAY[..., None] - 0.5) * 8   # sky is dithered to 565
    return np.where(empty[..., None], s, out)


def to565(img):
    """Quantise float RGB to RGB565 and expand back to 8 bits per channel."""
    img = np.clip(img, 0, 255)
    out = np.empty(img.shape, np.uint8)
    for k, bits in enumerate((5, 6, 5)):
        q = np.round(img[..., k] * ((1 << bits) - 1) / 255).astype(np.uint16)
        out[..., k] = (q << (8 - bits)) | (q >> (2 * bits - 8))
    return out


# ------------------------------------------------------------------ overlay
FONT = ImageFont.load_default_imagefont()


def overlay(img, title, roll):
    """Title card top-left and the 16x12 Snouty placeholder at bottom centre."""
    if title:
        d = ImageDraw.Draw(img)
        d.text((4, 4), title, font=FONT, fill=(0, 0, 0))
        d.text((3, 3), title, font=FONT, fill=(255, 236, 200))
    a = np.array(img).astype(float)
    yy, xx = np.mgrid[0:SH, 0:SW]
    cx, cy = 80, 112
    cr, sr = math.cos(roll), math.sin(roll)
    xr = (xx - cx) * cr + (yy - cy) * sr
    yr = -(xx - cx) * sr + (yy - cy) * cr
    body = (xr / 8) ** 2 + (yr / 5.5) ** 2 <= 1
    ears = ((np.abs(xr) - 5) ** 2 + (yr + 5) ** 2) <= 4.5
    snout = (xr / 3.2) ** 2 + ((yr - 1) / 2.3) ** 2 <= 1
    outline = ((xr / 9.2) ** 2 + (yr / 6.7) ** 2 <= 1) | (((np.abs(xr) - 5) ** 2 + (yr + 5) ** 2) <= 7)
    a[outline] = rgb(0x301018)
    a[body | ears] = rgb(0xE0A0A0)
    a[snout] = rgb(0x803040)
    return Image.fromarray(to565(a))


def frame_image(world, cam, t, title=None):
    H, C = world.maps(t)
    img = Image.fromarray(to565(render(H, C, world.pal, cam, t)))
    return overlay(img, title, cam['roll'])


# -------------------------------------------------------------------- world
def value_noise(ny, nx, cell, rng):
    g = rng.random((ny // cell, nx // cell))
    y = np.arange(ny) / cell
    x = np.arange(nx) / cell
    y0, x0 = np.floor(y).astype(int), np.floor(x).astype(int)
    fy, fx = (y - y0) ** 2 * (3 - 2 * (y - y0)), (x - x0) ** 2 * (3 - 2 * (x - x0))
    y1, x1 = (y0 + 1) % g.shape[0], (x0 + 1) % g.shape[1]
    a = lerp(g[y0][:, x0], g[y0][:, x1], fx[None, :])
    b = lerp(g[y1][:, x0], g[y1][:, x1], fx[None, :])
    return lerp(a, b, fy[:, None])


class World:
    ORDER = ['sort', 'tree', 'hash', 'stack', 'heap', 'pipeline']
    BUS_LEN = 64

    def __init__(self, seed=5):
        self.rng = np.random.default_rng(seed)
        self.pal = Palette()
        self.H = np.zeros((MAP_H, MAP_W), np.int16)
        self.C = np.zeros((MAP_H, MAP_W), np.uint8)
        self.regions, self.dynamic = {}, []
        gen_floor(self)
        seg = MAP_H // len(self.ORDER)
        for i, name in enumerate(self.ORDER):
            s = i * seg
            e = (i + 1) * seg if i < len(self.ORDER) - 1 else MAP_H
            gen_bus(self, s, s + self.BUS_LEN)
            self.regions['bus_' + name] = (s, s + self.BUS_LEN)
            self.regions[name] = (s + self.BUS_LEN, e)
            GEN[name](self, s + self.BUS_LEN, e)
        self.H = np.clip(self.H, 0, 255)

    def maps(self, t):
        if not self.dynamic:
            return self.H.astype(np.uint8), self.C
        H, C = self.H.copy(), self.C.copy()
        for fn in self.dynamic:
            fn(H, C, t)
        return np.clip(H, 0, 255).astype(np.uint8), C

    def box(self, x0, y0, x1, y1, h=None, c=None):
        """Fill the half-open rectangle; x and y wrap."""
        ys = np.arange(y0, y1) % MAP_H
        xs = np.arange(x0, x1) % MAP_W
        if h is not None:
            self.H[np.ix_(ys, xs)] = h
        if c is not None:
            self.C[np.ix_(ys, xs)] = c

    def path(self, pts, width, base, raise_to=None, phase=0, period=1.0, max_h=255,
             interior=False):
        """Palette-cycled polyline: cell colour = base + (distance along path) % 16.
        Cells taller than max_h are left alone (a path never paints a tall block's
        top, whose faces would then carry the pulse colour down to the floor);
        interior=True likewise skips cells on the edge of a raised ridge."""
        p = phase
        for (xa, ya), (xb, yb) in zip(pts, pts[1:]):
            n = int(max(abs(xb - xa), abs(yb - ya)))
            for k in range(n):
                x = int(round(xa + (xb - xa) * k / n)) - width // 2
                y = int(round(ya + (yb - ya) * k / n)) - width // 2
                ys, xs = np.arange(y, y + width) % MAP_H, np.arange(x, x + width) % MAP_W
                cell = np.ix_(ys, xs)
                ok = self.H[cell] <= max_h
                if interior:
                    hc = self.H[cell]
                    for dy_, dx_ in ((-1, 0), (1, 0), (0, -1), (0, 1)):
                        nb = self.H[np.ix_((ys + dy_) % MAP_H, (xs + dx_) % MAP_W)]
                        ok &= nb >= hc - FACE_JUMP
                if raise_to is not None:
                    self.H[cell] = np.where(ok, np.maximum(self.H[cell], raise_to), self.H[cell])
                self.C[cell] = np.where(ok, base + int(p / period) % 16, self.C[cell])
                p += 1
        return p


def gen_floor(w):
    n = 0.65 * value_noise(MAP_H, MAP_W, 32, w.rng) + 0.35 * value_noise(MAP_H, MAP_W, 8, w.rng)
    w.H[:] = np.round(FLOOR + (n - 0.5) * 12).astype(np.int16)
    slope = np.roll(w.H, 1, 0) - np.roll(w.H, -1, 0)
    w.C[:] = np.clip(np.round(n * 12 + slope * 1.5 + 1), 0, 15).astype(np.uint8) + P_FLOOR
    grid = np.zeros((MAP_H, MAP_W), bool)
    grid[(np.arange(MAP_H) % 64) < 2, :] = True
    grid[:, (np.arange(MAP_W) % 64) < 2] = True
    w.C[grid] = P_GRID + np.clip(np.round(n[grid] * 4), 0, 3).astype(np.uint8)


def gen_bus(w, y0, y1):
    if not hasattr(w, 'bus_cols'):
        w.bus_cols = (w.pal.pair(0x202848, 0x121830), w.pal.pair(0x3A4A86, 0x1C2448))
    road, rim = w.bus_cols
    w.box(110, y0, 146, y1, h=FLOOR + 8, c=road)
    w.box(110, y0, 112, y1, c=rim)
    w.box(144, y0, 146, y1, c=rim)
    for k, (x, base, sgn) in enumerate([(116, P_A_DASH, 1), (124, P_B_DASH, -1),
                                        (131, P_A_DASH, 1), (139, P_B_DASH, -1)]):
        pts = [(x + 1, y0), (x + 1, y1)] if sgn > 0 else [(x + 1, y1 - 1), (x + 1, y0 - 1)]
        w.path(pts, 2, base, phase=k * 5)
    for y in range(y0 + 8, y1, 16):                    # pylons under the deck
        for x in (104, 148):
            w.box(x, y, x + 4, y + 4, h=FLOOR + 14, c=rim)


def gen_heap(w, y0, y1):
    rng, pal = w.rng, w.pal
    alloc = [pal.pair(0xFFA030, 0xE06020), pal.pair(0xF08C28, 0xC85418),
             pal.pair(0xFFBE58, 0xE87028)]
    free = pal.pair(0x20C0B0, 0x0E6A64)
    blocks = []
    y = y0 + 6
    while y < y1 - 12:
        depth = int(rng.integers(10, 28))
        x = int(rng.integers(0, 6))
        while x < MAP_W - 8:
            wd = int(rng.choice([8, 10, 12, 14, 16, 20, 24, 30]))
            wd = min(wd, MAP_W - x)
            dp = min(depth - int(rng.integers(0, 5)), y1 - 4 - y)
            corridor = x < 134 and x + wd > 122
            freed = corridor or rng.random() < 0.22
            hgt = FLOOR + (int(rng.integers(6, 16)) if freed else int(rng.integers(20, 86)))
            blocks.append(dict(x=x, y=y, w=wd, d=dp, h=hgt, freed=freed,
                               unref=(not freed) and rng.random() < 0.4))
            x += wd + int(rng.integers(3, 8))
        y += depth + int(rng.integers(4, 8))
    for b in blocks:
        c = free if b['freed'] else alloc[int(rng.integers(0, 3))]
        b['c'] = c
        w.box(b['x'], b['y'], b['x'] + b['w'], b['y'] + b['d'], h=b['h'], c=c)
    # the free list: a pulse chain hopping from free block to free block
    fr = sorted([b for b in blocks if b['freed']], key=lambda b: (b['y'], b['x']))
    pts = []
    for b in fr:
        cx, cy = b['x'] + b['w'] // 2, b['y'] + b['d'] // 2
        if pts:
            pts.append((cx, pts[-1][1]))
        pts.append((cx, cy))
    w.path(pts, 2, P_A_COMET, raise_to=FLOOR + 3, max_h=FLOOR + 20)
    # garbage collector: a white wall sweeping -y (towards the camera) from the far
    # end of the heap; unreferenced blocks collapse behind it over 10 frames
    gc0, speed = y1 - 2, 4.0
    unref = [b for b in blocks if b['unref']]

    def gc(H, C, t):
        wy = gc0 - speed * t
        for b in unref:
            t0 = (gc0 - b['y'] - b['d'] / 2) / speed
            k = np.clip(1 - (t - t0) / 10, 0, 1)
            if k < 1:
                ys = slice(b['y'], b['y'] + b['d'])
                xs = np.arange(b['x'], b['x'] + b['w']) % MAP_W
                H[ys, xs] = int(FLOOR + 2 + (b['h'] - FLOOR - 2) * k)
                if k == 0:
                    C[ys, xs] = P_RUBBLE + (np.arange(b['w']) % 3)[None, :] + (b['y'] % 2)
        if y0 <= wy <= y1 - 2:
            H[int(wy):int(wy) + 2, :] = FLOOR + 24
            C[int(wy):int(wy) + 2, :] = P_WHITE
    w.dynamic.append(gc)
    w.gc = (gc0, speed)


def quicksort_snapshots(a):
    a = list(a)
    snaps, pivots = [(list(a), [])], []
    stack = [(0, len(a) - 1)]
    while stack:
        lo, hi = stack.pop()
        if lo >= hi:
            if lo == hi:
                pivots.append(lo)
            continue
        p, i = a[hi], lo
        for j in range(lo, hi):
            if a[j] < p:
                a[i], a[j] = a[j], a[i]
                i += 1
        a[i], a[hi] = a[hi], a[i]
        pivots.append(i)
        snaps.append((list(a), [i]))
        stack += [(i + 1, hi), (lo, i - 1)]
    snaps.append((list(a), []))
    return snaps


def gen_sort(w, y0, y1, nbars=64, passes=24, depth=7, gap=3):
    rng, pal = w.rng, w.pal
    hues = []
    for k in range(24):
        hh = k / 24 * 0.8                            # red -> violet
        r, g, b = [255 * (1 - 0.85 * max(0, min(1, abs((hh * 6 + o) % 6 - 3) - 1)))
                   for o in (0, 4, 2)]
        v = (int(r) << 16) | (int(g) << 8) | int(b)
        hues.append(pal.pair(v, (int(r * .5) << 16) | (int(g * .5) << 8) | int(b * .5)))
    pivot = pal.pair(0xF4F4FF, 0x9090B0)
    snaps = quicksort_snapshots(rng.permutation(nbars))
    pick = np.round(np.linspace(0, len(snaps) - 1, passes)).astype(int)
    bw = MAP_W // nbars
    for r, si in enumerate(pick):
        vals = snaps[si][0]
        piv = set(p for s in snaps[pick[r - 1] + 1 if r else 0:si + 1] for p in s[1])
        yy = y0 + 14 + r * (depth + gap)
        for i, val in enumerate(vals):
            c = pivot if (i in piv and 0 < r < passes - 1) else hues[val * 24 // nbars]
            w.box(i * bw, yy, i * bw + bw, yy + depth, h=FLOOR + 6 + int(val * 74 / nbars), c=c)


def gen_tree(w, y0, y1):
    pal = w.pal
    hts = [30, 24, 19, 15, 12, 10]
    wid = [12, 9, 7, 6, 5, 4]
    straight = [24, 14, 10, 6, 4, 0]
    cols = [pal.pair(0x90FFC0, 0x2C8C58)] + [pal.pair(0x40E080 if l % 2 else 0x20A060,
                                                      0x1C7040 if l % 2 else 0x10502C)
                                             for l in range(1, 6)]
    search = [1, 0, 0, 1, 0]                   # right, left, left, right, left
    trail = []
    top = y0 + y1                              # built root-first, stored flipped:
                                               # leaves near the camera, root far

    def box(x0, ya, x1, yb, **kw):
        w.box(x0, top - yb + 1, x1, top - ya + 1, **kw)

    def node(x, y, lvl, on_path):
        h, wd = FLOOR + hts[lvl], wid[lvl]
        ys = y + straight[lvl]
        box(x - wd // 2, y, x - wd // 2 + wd, ys + 1, h=h, c=cols[lvl])
        if on_path:
            trail.extend([(x, y), (x, ys)])
        if lvl == 5:
            box(x - 3, y - 2, x + 3, y + 4, h=h, c=cols[lvl])       # leaf mound
            return
        nw = wid[lvl] + 4
        box(x - nw // 2, ys - 2, x - nw // 2 + nw, ys + 3, h=h + 6, c=cols[lvl])
        dx = 64 >> lvl
        for side in (0, 1):
            sgn = 1 if side else -1
            cw = wid[lvl + 1]
            for s in range(1, dx + 1):
                bx, by = x + sgn * s - cw // 2, ys + s
                box(bx, by, bx + cw, by + 1, h=FLOOR + hts[lvl + 1], c=cols[lvl + 1])
            node(x + sgn * dx, ys + dx, lvl + 1, on_path and search[lvl] == side)
    node(128, y0 + 40, 0, True)
    w.path([(x, top - y) for x, y in trail], 3, P_B_COMET, interior=True)  # root -> leaf


def gen_hash(w, y0, y1):
    pal = w.pal
    bucket = pal.pair(0xE040C0, 0x80206C)
    chain = [pal.pair(0xA030A0, 0x5C1A5C), pal.pair(0x7C2480, 0x441446),
             pal.pair(0x5A1A60, 0x300E34)]
    small = pal.pair(0xFF6AE0, 0x902C80)
    rng = w.rng
    split = y0 + 158
    for j, y in enumerate(range(y0 + 10, split - 30, 36)):
        for i in range(8):                             # 8 buckets, 10x10, pitch 32
            x = 11 + 32 * i
            w.box(x, y, x + 10, y + 10, h=FLOOR + 40, c=bucket)
            n = int(rng.choice([0, 1, 1, 2, 3, 3]))
            for k in range(n):                         # collision chain: terraces down
                ly, lw = y + 11 + 7 * k, 8 - 2 * k
                w.box(x + 5 - lw // 2, ly, x + 5 + lw // 2, ly + 6, h=FLOOR + 30 - 8 * k,
                      c=chain[k])
        if j > 0:                                      # insert lane from the strip edge
            tgt = 11 + 32 * int(rng.choice([1, 2, 5, 6])) + 5
            src = 0 if j % 2 else MAP_W - 1
            w.path([(src, y - 3), (tgt, y - 3), (tgt, y)], 2, P_A_COMET, raise_to=FLOOR + 2)
    w.path([(0, split - 8), (MAP_W, split - 8)], 3, P_B_DASH, raise_to=FLOOR + 4)
    for y in range(split, y1 - 10, 18):                # after the rehash: 2x buckets, half height
        for i in range(16):
            x = 5 + 16 * i
            w.box(x, y, x + 6, y + 6, h=FLOOR + 20, c=small)


def gen_stack(w, y0, y1, plateau=90, band=8, F=10, S=5):
    pal = w.pal
    top = pal.pair(0x2A1428, 0x180A16)
    bands = [pal.pair(int(lerp(0x50, 0xFF, j / 9)) << 16 | int(lerp(0x10, 0x40, j / 9)) << 8
                      | int(lerp(0x20, 0x40, j / 9)),
                      int(lerp(0x30, 0x90, j / 9)) << 16 | int(lerp(0x08, 0x20, j / 9)) << 8
                      | int(lerp(0x12, 0x24, j / 9))) for j in range(10)]
    lip = pal.pair(0xFF9A80, 0xA04040)
    xs = np.arange(MAP_W)
    dxs = np.abs(xs - 127.5) - 0.5
    for y in range(y0, y1):
        r = y - y0
        if r < 130:
            d = 1 + r // 13
        elif r < 160:
            d = 10
        else:
            d = 10 - (r - 160) // 12
        d = int(np.clip(d, 1, 10))
        kk = np.clip(np.ceil((dxs - F + 1) / S), 0, d).astype(int)   # terrace from bottom
        h = plateau - band * (d - kk)
        j = (plateau - h) // band                                    # frame depth 1..10
        c = np.where(kk >= d, top, np.array(bands)[np.clip(j - 1, 0, 9)])
        is_lip = (kk < d) & (kk > 0) & (np.abs(dxs - (F - 1 + (kk - 1) * S)) < 0.6)
        c = np.where(is_lip, lip, c)
        w.H[y % MAP_H] = h
        w.C[y % MAP_H] = c
    w.path([(128, y0), (128, y1)], 2, P_B_DASH)    # the call / return signal


def gen_pipeline(w, y0, y1):
    pal = w.pal
    dam = pal.pair(0xB0C8F0, 0x485878)
    spring = pal.pair(0x30B0D0, 0x186078)
    lake_end = y0 + 110
    w.box(0, y0, MAP_W, lake_end, h=WATER, c=P_WATER)
    ys, ym = y1 - 22, y0 + 150                     # springs, merge point (flow is -y)
    springs = [28, 70, 108, 148, 186, 228]
    merged = [49, 128, 207]
    for y in range(lake_end - 2, ys + 1):
        if y >= ym:
            t = (ys - y) / (ys - ym)
            sep = 1 - t * t * (3 - 2 * t)
            for i, sx in enumerate(springs):
                mid = (springs[i - i % 2] + springs[i - i % 2 + 1]) / 2
                off = (sx - mid) * math.cos((ys - y) * 0.06) * sep
                x = lerp(mid, merged[i // 2], t * t * (3 - 2 * t)) + off
                w.box(int(x) - 2, y, int(x) + 2, y + 1, h=WATER, c=P_WATER)
        else:
            for m in merged:
                x = m + 6 * math.sin((ym - y) * 0.05 + m)
                wd = 7 + int(6 * (1 - (y - lake_end) / (ym - lake_end)))
                w.box(int(x) - wd // 2, y, int(x) - wd // 2 + wd, y + 1, h=WATER, c=P_WATER)
    # packets down the centre of each channel
    for i, sx in enumerate(springs):
        pts = []
        for y in range(ys, ym - 1, -2):
            t = (ys - y) / (ys - ym)
            mid = (springs[i - i % 2] + springs[i - i % 2 + 1]) / 2
            off = (sx - mid) * math.cos((ys - y) * 0.06) * (1 - t * t * (3 - 2 * t))
            pts.append((lerp(mid, merged[i // 2], t * t * (3 - 2 * t)) + off, y))
        if i % 2 == 0:
            m = merged[i // 2]
            pts += [(m + 6 * math.sin((ym - y) * 0.05 + m), y) for y in range(ym, lake_end - 2, -2)]
        w.path(pts, 1, P_A_DASH, raise_to=WATER + 1, period=1)
    ydam = ym - 34
    for m in merged:
        x = m + 6 * math.sin((ym - ydam) * 0.05 + m)
        w.box(int(x) - 9, ydam, int(x) + 9, ydam + 6, h=FLOOR + 16, c=dam)
        w.box(int(x) - 1, ydam, int(x) + 1, ydam + 6, h=WATER + 1, c=P_A_DASH)
    for sx in springs:
        w.box(sx - 4, ys, sx + 4, ys + 8, h=FLOOR + 26, c=spring)
        w.box(sx - 2, ys + 2, sx + 2, ys + 6, h=FLOOR + 28, c=P_A_COMET)


GEN = dict(heap=gen_heap, sort=gen_sort, tree=gen_tree, hash=gen_hash,
           stack=gen_stack, pipeline=gen_pipeline)


# ------------------------------------------------------------------- output
TITLES = dict(heap='HEAP  malloc / free / gc', sort='SORT  quicksort by pass',
              tree='TREE  binary search', hash='HASH  buckets + rehash',
              stack='STACK  call / return', pipeline='PIPELINE  filter->reduce',
              bus='BUS  the address bus')


def cam(x=128.0, y=0.0, alt=60.0, yaw=0.0, roll=0.0, hz=44):
    return dict(x=x, y=y, alt=alt, yaw=yaw, roll=roll, hz=hz)


def still_cams(w):
    R = w.regions
    return dict(
        heap=(cam(y=R['heap'][0] + 96, alt=FLOOR + 66, yaw=0.10, roll=0.10, hz=54), 14),
        sort=(cam(y=R['sort'][0] + 110, alt=FLOOR + 92, hz=50), 0),
        tree=(cam(y=R['tree'][0] - 45, alt=FLOOR + 185, hz=-6), 0),
        hash=(cam(x=128, y=R['hash'][0] - 6, alt=FLOOR + 70, yaw=-0.10, roll=-0.08, hz=52), 0),
        stack=(cam(y=R['stack'][0] + 90, alt=50, hz=54), 0),
        pipeline=(cam(y=R['pipeline'][0] + 2, alt=WATER + 8, hz=60), 0),
        bus=(cam(x=128, y=R['bus_heap'][0] + 4, alt=FLOOR + 26, hz=54), 0),
    )


def upscale(img, k):
    return img.resize((img.width * k, img.height * k), Image.NEAREST)


def write_stills(w, out):
    tiles = []
    for name, (c, t) in still_cams(w).items():
        img = upscale(frame_image(w, c, t, TITLES[name]), 4)
        img.save(os.path.join(out, name + '.png'))
        tiles.append((name, img))
        print('wrote', name + '.png')
    cap, cols = 28, 4
    tw, th = tiles[0][1].size
    mont = Image.new('RGB', (cols * tw, 2 * (th + cap)), (6, 4, 15))
    for i, (name, img) in enumerate(tiles):
        x, y = (i % cols) * tw, (i // cols) * (th + cap)
        mont.paste(img, (x, y))
        lab = Image.new('RGB', (tw // 2, cap // 2), (6, 4, 15))
        ImageDraw.Draw(lab).text((4, 2), name + '.png   ' + TITLES[name], font=FONT,
                                 fill=(255, 200, 120))
        mont.paste(upscale(lab, 2), (x, y + th))
    sw = tw // 32                                   # 8th tile: the palette
    for i in range(256):
        top = w.pal.at(0)[0][i]
        x0, y0 = 3 * tw + (i % 32) * sw, th + cap + (i // 32) * (th // 8)
        ImageDraw.Draw(mont).rectangle([x0, y0, x0 + sw - 1, y0 + th // 8 - 1],
                                       fill=tuple(int(v) for v in to565(top[None, None])[0, 0]))
    mont.save(os.path.join(out, 'montage.png'))
    print('wrote montage.png')


def gif_path(w, n):
    """Bus -> heap (GC wall sweeping towards us) -> bus -> out over the pipeline lake."""
    y0 = w.regions['bus_heap'][0] + 4
    speed = (w.regions['pipeline'][0] + 72 - y0) / n
    cams = []
    H, _ = w.maps(0)
    xs = [128 + 3 * math.sin(f * 0.09) for f in range(n + 2)]
    for f in range(n):
        y = y0 + f * speed
        H, _ = w.maps(f)
        win = H[int(y) + 4:int(y) + 36, int(xs[f]) - 6:int(xs[f]) + 6]
        top = int(win.max())
        cams.append([xs[f], y, top + (10 if top <= WATER + 1 else 26)])
    alt = np.array([c[2] for c in cams], float)
    for _ in range(12):                                 # zero-phase smoothing
        alt = np.maximum(alt, np.convolve(np.pad(alt, 2, mode='edge'), np.ones(5) / 5, 'valid'))
        alt = np.convolve(np.pad(alt, 2, mode='edge'), np.ones(5) / 5, 'valid')
    out = []
    for f, (x, y, _) in enumerate(cams):
        yaw = math.atan((xs[f + 1] - xs[f]) / speed)
        yaw2 = math.atan((xs[f + 2] - xs[f + 1]) / speed)
        roll = float(np.clip((yaw2 - yaw) * 40, -0.25, 0.25))
        out.append(cam(x=x, y=y, alt=float(alt[f]), yaw=yaw, roll=roll, hz=52))
    return out


def write_gif(w, out, n=90):
    frames = [upscale(frame_image(w, c, f), 2) for f, c in enumerate(gif_path(w, n))]
    sample = Image.new('RGB', (frames[0].width, frames[0].height * 6))
    for k, f in enumerate(frames[::n // 6][:6]):
        sample.paste(f, (0, k * frames[0].height))
    palimg = sample.quantize(255, method=Image.Quantize.MEDIANCUT)
    q = [f.quantize(palette=palimg, dither=Image.Dither.NONE) for f in frames]
    path = os.path.join(out, 'concept.gif')
    q[0].save(path, save_all=True, append_images=q[1:], duration=[(70, 70, 60)[k % 3] for k in range(len(q))], loop=0, optimize=True)
    print('wrote concept.gif', os.path.getsize(path) // 1024, 'KB')


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('--out', default=os.path.join(HERE, '..', 'docs', 'concept'))
    ap.add_argument('--stills', action='store_true')
    ap.add_argument('--gif', action='store_true')
    ap.add_argument('--frames', type=int, default=90)
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    w = World()
    print('palette entries used:', w.pal.next, '/ 256')
    if a.stills:
        write_stills(w, a.out)
    if a.gif:
        write_gif(w, a.out, a.frames)


if __name__ == '__main__':
    main()
