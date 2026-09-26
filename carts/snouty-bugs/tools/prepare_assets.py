#!/usr/bin/env python3
"""Prepare the build inputs in assets/gen/ for Snouty vs. the Bugs.

Two modes:

  python3 tools/prepare_assets.py --placeholders
      Procedurally draws every M1 sheet (PLAN.md "Asset contract") as
      readable Genesis-style placeholder art, straight into assets/gen/.

  python3 tools/prepare_assets.py --study assets/Bugs_Study_NN [--snap FILE.gpl]
      Takes a delivered art study (ASSETS.md section 8 layout:
      <study>/sheets/<name>.png RGBA strips, <study>/assets.json metadata),
      applies a hard alpha cut, optionally snaps to a GIMP palette, flattens
      alpha 0 to the #FF00FF key and writes assets/gen/<name>.png.

Both modes validate every written sheet against the manifest below (exact
size, cell grid, <= 15 opaque colors after RGB565 quantisation, 16 for the
opaque far layer, key usage, 1 px empty cell border, ship hitbox opaque,
background tileability) and print a report. Exit status is non-zero on any
violation.

`iris_16.png` is copied from snouty-badge and is never touched here.
"""
from __future__ import annotations

import argparse
import json
import math
import random
import sys
from dataclasses import dataclass
from pathlib import Path

import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "assets" / "gen"
KEY = (255, 0, 255)  # convert_gfx maps this to palette index 0 (skipped by draw.zig)


# --------------------------------------------------------------------------
# Manifest. Must match PLAN.md "Asset contract" and build.zig `images`.
# --------------------------------------------------------------------------
@dataclass(frozen=True)
class Sheet:
    name: str
    width: int
    height: int
    cell_w: int
    cell_h: int
    frames: int
    transparent: bool
    tile_x: bool = False  # must tile seamlessly left-right
    in_build: bool = True  # listed in build.zig today

    @property
    def max_colors(self) -> int:
        # 4-bit palette: 16 entries, one reserved for the key when transparent.
        return 15 if self.transparent else 16


MANIFEST: dict[str, Sheet] = {
    s.name: s
    for s in [
        Sheet("ship.png", 96, 24, 32, 24, 3, True),
        Sheet("thruster.png", 32, 8, 8, 8, 4, True),
        Sheet("bolt.png", 32, 8, 16, 8, 2, True),
        Sheet("bugs_small.png", 32, 8, 8, 8, 4, True),
        Sheet("fx_small.png", 128, 16, 16, 16, 8, True),
        Sheet("hud.png", 32, 8, 8, 8, 4, True),
        Sheet("bg_far.png", 256, 120, 256, 120, 1, False, tile_x=True),
        Sheet("bg_near.png", 256, 24, 256, 24, 1, True, tile_x=True),
        # Later milestones (ASSETS.md section 7). Accepted from a study but
        # only useful once build.zig lists them.
        Sheet("bugs.png", 160, 16, 16, 16, 10, True),
        Sheet("boss.png", 240, 48, 48, 48, 5, True, in_build=False),
        Sheet("fx_big.png", 192, 32, 32, 32, 6, True),
        Sheet("title.png", 128, 40, 128, 40, 1, True, in_build=False),
    ]
}
PLACEHOLDER_SHEETS = [n for n, s in MANIFEST.items() if s.in_build]

# Hard-coded in cart/src/player.zig until the real sheet reports its own.
SHIP_HITBOX = (14, 9, 6, 6)  # cell-relative x, y, w, h
THRUSTER_OFFSET = (-6, 8)  # thruster cell top-left relative to ship cell

# ASSETS.md section 8 delivery layout -> assets/gen names. Today the names
# are identical; a study that renames a sheet only needs a row here.
STUDY_LAYOUT = {name: f"sheets/{name}" for name in MANIFEST}


# --------------------------------------------------------------------------
# Palette (ASSETS.md section 3) plus brand colors and per-family additions.
# --------------------------------------------------------------------------
def hx(s: str) -> tuple[int, int, int]:
    s = s.lstrip("#")
    return (int(s[0:2], 16), int(s[2:4], 16), int(s[4:6], 16))


OUTLINE = hx("17121e")
DARK = hx("29232f")
MIDDARK = hx("42364b")
PURPLE1 = hx("462174")
PURPLE2 = hx("662bb8")
PURPLE3 = hx("8e42de")
PURPLE4 = hx("be7af3")
CREAM = hx("f4efdf")
GREY = hx("958d9d")
RED = hx("ee453c")
DARKRED = hx("91322f")
BROWN1 = hx("60391f")
BROWN2 = hx("99622f")
TAN = hx("cd934b")
LIGHTTAN = hx("f0c37c")
MASTER = [OUTLINE, DARK, MIDDARK, PURPLE1, PURPLE2, PURPLE3, PURPLE4, CREAM,
          GREY, RED, DARKRED, BROWN1, BROWN2, TAN, LIGHTTAN]

CORAL = hx("F18271")  # brand
ANTIBLACK = hx("16031B")  # brand
ANTIWHITE = hx("FCFBF9")  # brand
GREEN = hx("3c8a2e")
LIGHTGREEN = hx("8fd14f")
YELLOW = hx("e6c229")
WHITE = hx("ffffff")
FXYELLOW = hx("ffd166")
ORANGE = hx("ff7b2e")
DEEP0 = hx("0b1030")
DEEP1 = hx("182552")
DEEP2 = hx("2c3d7a")
TEAL = hx("3fb8af")

# Placeholder mixes only; each is at most one step off the brief's families.
STEEL = hx("6d6a86")  # ship hull mid tone between grey and mid-dark
DARKTEAL = hx("1f6f75")  # dimmed circuit trace
NEB_PURPLE = hx("261a4a")  # faint nebula
NEB_PURPLE2 = hx("33245e")
PLANET0 = hx("0f1838")
PLANET1 = hx("142046")
PLANET_TRACE = hx("1b3a5c")
PLANET_PAD = hx("24506e")
STAR_DIM = hx("3b4a86")
STAR_MID = hx("5866a0")


# --------------------------------------------------------------------------
# Drawing helpers
# --------------------------------------------------------------------------
def new_sheet(sheet: Sheet) -> np.ndarray:
    a = np.zeros((sheet.height, sheet.width, 3), np.uint8)
    a[:, :] = KEY
    return a


def paint(a: np.ndarray, rows: list[str], x0: int, y0: int, cmap: dict[str, tuple]) -> None:
    """Paint ASCII art; '.' and ' ' are transparent (left untouched)."""
    for y, row in enumerate(rows):
        for x, ch in enumerate(row):
            if ch in ". ":
                continue
            yy, xx = y0 + y, x0 + x
            if 0 <= yy < a.shape[0] and 0 <= xx < a.shape[1]:
                a[yy, xx] = cmap[ch]


def save(a: np.ndarray, name: str) -> None:
    Image.fromarray(a, "RGB").save(OUT / name, optimize=True)


# --------------------------------------------------------------------------
# ship.png  (3 cells 32x24: level, bank up, bank down; faces right)
# --------------------------------------------------------------------------
SHIP_CMAP = {
    "o": OUTLINE, "d": DARK, "m": MIDDARK, "s": STEEL, "g": GREY, "c": CREAM,
    "1": PURPLE1, "2": PURPLE2, "3": PURPLE3, "4": PURPLE4,
    "C": CORAL, "r": RED, "t": TEAL,
}

# Snouty, drawn at cell (11, 2) in the level pose. Ear top-left, big cream
# eye with the pupil forward, long snout to the right with a darker tip.
SNOUTY = [
    "...ooo..............",
    "..o443o.............",
    "..o433oooooo........",
    ".o3333occccoo.......",
    "o33333occccooooo....",
    "o33333occoo344443o..",
    "o33333occoo3333333o.",
    "o233333oo333333333oo",
    "o22333333322222221o.",
    ".o222233333ooooooo..",
    ".o22222222o.........",
    ".om222222mo.........",
    ".odmmmmmmdo.........",
    ".odmmmmmmdo.........",
]
SNOUTY_AT = (10, 2)

# Hull: engine block on the left (nozzle opening at x 1, y 10..13 where the
# thruster cell attaches), headrest behind Snouty, teal windscreen in front,
# cream stripe and the Coral Iris ring on the side, nose at x 30.
HULL = [
    "................................",  # 0
    "................................",  # 1
    "................................",  # 2
    "................................",  # 3
    "................................",  # 4
    "................................",  # 5
    "................................",  # 6
    "................................",  # 7
    "................................",  # 8
    ".oooo...........................",  # 9
    ".ggcgoo.........................",  # 10
    ".gsggcgo...............oo.......",  # 11
    ".gssgggoo.............otto......",  # 12
    ".gmssggggo............ottto.....",  # 13
    ".omssgggggooooooooooooooooooo...",  # 14
    ".omsssgggggccccccccccccccccggoo.",  # 15
    ".omssssgggggooogggggggggggggggo.",  # 16
    ".omssssggggoCCCoggggggggggggcoo.",  # 17
    "..omsssssssoCrCosssssssssssoo...",  # 18
    "...oommmmmmoCCCommmmmmmmoooo....",  # 19
    "....ooooooooooooooooooooo.......",  # 20
    "................................",  # 21
    "................................",  # 22
    "................................",  # 23
]

# Wing variants, painted over the hull bottom. Leading edge forward (right),
# tip swept back and down.
WING_LEVEL = [
    "......o3333333332o..",  # y 20
    ".....o222222222oo...",  # y 21
    "....ooooooooooo.....",  # y 22
]
WING_UP = [  # banking up: wing seen edge-on, a thin lit strip
    "......o44444444433o.",  # y 20
    ".......oooooooooo...",  # y 21
]
WING_DOWN = [  # banking down: more of the wing's top surface shows
    "......o44443333332o.",  # y 20
    "....oo33333333322o..",  # y 21
    "..oo1111111111oo....",  # y 22
]
WING_X = 4


def draw_ship() -> np.ndarray:
    sheet = MANIFEST["ship.png"]
    a = new_sheet(sheet)
    poses = [(WING_LEVEL, 0), (WING_UP, -1), (WING_DOWN, 1)]
    for i, (wing, dy) in enumerate(poses):
        cell = a[:, i * 32 : (i + 1) * 32]
        sx, sy = SNOUTY_AT
        paint(cell, SNOUTY, sx, sy + dy, SHIP_CMAP)
        paint(cell, HULL, 0, 0, SHIP_CMAP)
        paint(cell, wing, WING_X, 20, SHIP_CMAP)
    return a


# --------------------------------------------------------------------------
# thruster.png  (4 cells 8x8). Cell sits at THRUSTER_OFFSET from the ship
# cell, so cell x 7 is ship x 1 (the nozzle) and cell rows 2..5 are ship rows
# 10..13 (the nozzle opening). The flame grows leftward from x 6.
# --------------------------------------------------------------------------
FLAME_CMAP = {"o": OUTLINE, "w": WHITE, "y": FXYELLOW, "n": ORANGE, "C": CORAL,
              "r": RED, "p": PURPLE3}
FLAMES = [
    ["........",
     "........",
     "...rnyy.",
     ".rnnyww.",
     ".rnnyww.",
     "...rnyy.",
     "........",
     "........"],
    ["........",
     "........",
     "..rnnyy.",
     "rnnyyww.",
     "rnnyyww.",
     "..rnnyy.",
     "........",
     "........"],
    ["........",
     "........",
     "....nyy.",
     "..rnyww.",
     "..rnyww.",
     "....nyy.",
     "........",
     "........"],
    ["........",
     "........",
     ".r.rnyy.",
     "rnnnyww.",
     ".rnnyww.",
     "..rrnyy.",
     "........",
     "........"],
]


def draw_thruster() -> np.ndarray:
    a = new_sheet(MANIFEST["thruster.png"])
    for i, f in enumerate(FLAMES):
        # 1 px empty border: never paint column 0 of the cell.
        f = ["." + r[1:] for r in f]
        paint(a, f, i * 8, 0, FLAME_CMAP)
    return a


# --------------------------------------------------------------------------
# bolt.png  (2 cells 16x8). 12x4 visible at x 2..13, y 2..5. Coral core,
# cream leading tip on the right, dark red tail.
# --------------------------------------------------------------------------
BOLT_CMAP = {"o": OUTLINE, "R": DARKRED, "r": RED, "C": CORAL, "c": CREAM,
             "w": ANTIWHITE, "p": PURPLE2}
BOLTS = [
    ["................",
     "................",
     "..RRrrCCCCCcco..",
     "..rrCCCCCccwwo..",
     "..rrCCCCCccwwo..",
     "..RRrrCCCCCcco..",
     "................",
     "................"],
    ["................",
     "................",
     "...RrrrCCCCcco..",
     "..RrCCCCCCcwwo..",
     "..RrCCCCCCcwwo..",
     "...RrrrCCCCcco..",
     "................",
     "................"],
]


def draw_bolt() -> np.ndarray:
    a = new_sheet(MANIFEST["bolt.png"])
    for i, f in enumerate(BOLTS):
        paint(a, f, i * 16, 0, BOLT_CMAP)
    return a


# --------------------------------------------------------------------------
# bugs_small.png (4 cells 8x8): 0-1 gnat (faces left, wings flap),
# 2-3 round enemy bullet (cream/white core, purple rim, pulse).
# --------------------------------------------------------------------------
BUG_CMAP = {"o": OUTLINE, "g": GREEN, "G": LIGHTGREEN, "y": YELLOW, "c": CREAM,
            "w": WHITE, "4": PURPLE4, "3": PURPLE3, "m": MIDDARK, "e": GREY}
GNAT = [
    ["........",
     "..c.cc..",
     "..oeoe..",
     "..oGGGo.",
     ".oyGGGo.",
     ".oGggGo.",
     "..oooo..",
     "........"],
    ["........",
     "........",
     "..ooo...",
     ".oGGGoc.",
     ".oyGGec.",
     ".oGggGo.",
     "..oooo..",
     "........"],
]
ROUND = [
    ["........",
     "..oooo..",
     ".o4cc4o.",
     ".ocwwco.",
     ".ocwwco.",
     ".o4cc4o.",
     "..oooo..",
     "........"],
    ["........",
     "..o44o..",
     ".o4ww4o.",
     ".4wwww4.",
     ".4wwww4.",
     ".o4ww4o.",
     "..o44o..",
     "........"],
]


def draw_bugs_small() -> np.ndarray:
    a = new_sheet(MANIFEST["bugs_small.png"])
    for i, f in enumerate(GNAT + ROUND):
        paint(a, f, i * 8, 0, BUG_CMAP)
    return a


# --------------------------------------------------------------------------
# fx_small.png (8 cells 16x16): 0-4 explosion, 5-7 spark (8x8 centered).
# --------------------------------------------------------------------------
FX = {"o": OUTLINE, "d": DARK, "m": MIDDARK, "w": WHITE, "y": FXYELLOW,
      "n": ORANGE, "r": RED, "R": DARKRED, "c": CREAM, "p": PURPLE2, "g": GREY}


def disc_frame(rng: random.Random, radius: float, bands: list[tuple[float, str]],
               holes: float = 0.0, ring_inner: float = 0.0) -> list[str]:
    """Rows for one 16x16 explosion frame: concentric colour bands by radius
    fraction, optional random holes and an optional hollow centre."""
    rows = []
    cx = cy = 7.5
    for y in range(16):
        row = ""
        for x in range(16):
            d = math.hypot(x - cx, y - cy)
            # a lumpy edge so it reads as fire, not a circle
            ang = math.atan2(y - cy, x - cx)
            r = radius * (1 + 0.12 * math.sin(ang * 5 + radius))
            ch = "."
            if d <= r and d >= ring_inner and not (x in (0, 15) or y in (0, 15)):
                ch = bands[-1][1]
                for frac, c in bands:
                    if d <= r * frac:
                        ch = c
                        break
                if holes and rng.random() < holes:
                    ch = "."
            row += ch
        rows.append(row)
    return rows


def outline_rows(rows: list[str], color: str = "o") -> list[str]:
    """Add a 1 px dark outline around opaque pixels (inside the 1 px border)."""
    h, w = len(rows), len(rows[0])
    out = [list(r) for r in rows]
    for y in range(1, h - 1):
        for x in range(1, w - 1):
            if rows[y][x] != ".":
                continue
            if any(rows[y + dy][x + dx] not in ".o" for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1))):
                out[y][x] = color
    return ["".join(r) for r in out]


SPARKS = [
    ["................",
     "................",
     "................",
     "................",
     ".......y........",
     ".......w........",
     ".....y.w.y......",
     "....ywwwwwy.....",
     ".....y.w.y......",
     ".......w........",
     ".......y........",
     "................",
     "................",
     "................",
     "................",
     "................"],
    ["................",
     "................",
     "................",
     "................",
     "....y.....y.....",
     ".....y...y......",
     "......n.n.......",
     "....y..w..y.....",
     "......n.n.......",
     ".....y...y......",
     "....y.....y.....",
     "................",
     "................",
     "................",
     "................",
     "................"],
    ["................",
     "................",
     "................",
     "................",
     "....n.....n.....",
     "................",
     "................",
     "....r.....r.....",
     "................",
     "................",
     "....n.....n.....",
     "................",
     "................",
     "................",
     "................",
     "................"],
]


def draw_fx_small() -> np.ndarray:
    rng = random.Random(7)
    a = new_sheet(MANIFEST["fx_small.png"])
    frames = [
        outline_rows(disc_frame(rng, 3.0, [(0.55, "w"), (1.0, "y")])),
        outline_rows(disc_frame(rng, 4.8, [(0.35, "w"), (0.65, "y"), (1.0, "n")])),
        outline_rows(disc_frame(rng, 6.2, [(0.3, "y"), (0.65, "n"), (1.0, "r")], holes=0.08)),
        outline_rows(disc_frame(rng, 6.8, [(0.75, "r"), (1.0, "R")], holes=0.35, ring_inner=3.2)),
        disc_frame(rng, 6.8, [(0.8, "R"), (1.0, "g")], holes=0.8, ring_inner=4.5),
    ]
    for i, f in enumerate(frames + SPARKS):
        paint(a, f, i * 16, 0, FX)
    return a


# --------------------------------------------------------------------------
# hud.png (4 cells 8x8, 1 px transparent border): Snouty head, bomb (Coral
# Iris mark in a cream ring), empty bomb slot (grey ring), heart.
# --------------------------------------------------------------------------
HUD_CMAP = {"o": OUTLINE, "3": PURPLE3, "4": PURPLE4, "2": PURPLE2, "c": CREAM,
            "C": CORAL, "r": RED, "g": GREY, "m": MIDDARK, "w": ANTIWHITE}
HUD = [
    ["........",
     ".4......",
     ".333....",
     ".3co3o..",
     ".233334.",
     ".22233o.",
     "..22....",
     "........"],
    ["........",
     "..cccc..",
     ".cooooc.",
     ".coCCoc.",
     ".coCCoc.",
     ".cooooc.",
     "..cccc..",
     "........"],
    ["........",
     "..gggg..",
     ".goooog.",
     ".go..og.",
     ".go..og.",
     ".goooog.",
     "..gggg..",
     "........"],
    ["........",
     "..o..o..",
     ".oCooro.",
     ".oCrrro.",
     ".orrrro.",
     "..orro..",
     "...oo...",
     "........"],
]


def draw_hud() -> np.ndarray:
    a = new_sheet(MANIFEST["hud.png"])
    # The head icon's snout would touch the right cell edge; keep col 7 empty.
    for i, f in enumerate(HUD):
        f = [r[:7] + "." for r in f]
        paint(a, f, i * 8, 0, HUD_CMAP)
    return a


# --------------------------------------------------------------------------
# bg_far.png: 256x120 opaque, periodic in x with period 256 by construction
# (every x term is a whole number of sine periods or indexed modulo 256).
# --------------------------------------------------------------------------
BAYER4 = np.array([[0, 8, 2, 10], [12, 4, 14, 6], [3, 11, 1, 9], [15, 7, 13, 5]]) / 16.0
W = 256


def per_sin(x: np.ndarray, k: int, phase: float = 0.0) -> np.ndarray:
    return np.sin(2 * np.pi * k * x / W + phase)


def draw_bg_far() -> np.ndarray:
    h = 120
    a = np.zeros((h, W, 3), np.uint8)
    xs = np.arange(W)
    th = BAYER4[np.arange(h)[:, None] % 4, xs[None, :] % 4]
    yy = np.arange(h)[:, None].astype(float)

    a[:, :] = DEEP0
    # Nebula band 1: a blue haze, centre wandering with x.
    c1 = 34 + 8 * per_sin(xs, 1, 0.4) + 4 * per_sin(xs, 3, 1.3)
    w1 = 10 + 4 * per_sin(xs, 2, 2.0)
    d1 = 1 - np.abs(yy - c1[None, :]) / w1[None, :]
    a[(d1 > th * 0.9)] = DEEP1
    # Nebula band 2: faint purple, lower and thinner.
    c2 = 60 + 6 * per_sin(xs, 2, 4.1) + 3 * per_sin(xs, 5, 0.2)
    w2 = 7 + 3 * per_sin(xs, 3, 1.0)
    d2 = 1 - np.abs(yy - c2[None, :]) / w2[None, :]
    a[(d2 > th)] = NEB_PURPLE
    a[(d2 > 0.5 + th * 0.5)] = NEB_PURPLE2
    # Brighter knots in band 1 only where both bands thicken.
    a[(d1 > 0.7 + th * 0.3) & (per_sin(xs, 4, 0.7)[None, :] > 0.3)] = NEB_PURPLE

    # Dim fixed stars (the cart draws the bright moving ones).
    rng = random.Random(1234)
    for _ in range(70):
        x, y = rng.randrange(W), rng.randrange(0, 76)
        a[y, x] = STAR_DIM if rng.random() < 0.8 else STAR_MID

    # Motherboard planet: horizon along the bottom third.
    horizon = np.round(82 + 3 * per_sin(xs, 1, 0.9) + 1.5 * per_sin(xs, 3, 2.2)).astype(int)
    for x in range(W):
        hy = horizon[x]
        # thin atmosphere glow above the rim, dithered
        for y in range(hy - 4, hy):
            if (hy - y) <= 1 or BAYER4[y % 4, x % 4] < 0.5 - (hy - y) * 0.1:
                a[y, x] = DEEP1
        a[hy, x] = DEEP2  # rim
        a[hy + 1 : h, x] = PLANET0
        for y in range(hy + 1, h):
            depth = y - hy
            # nearer ground gets the slightly lighter tone, dithered in
            if BAYER4[y % 4, x % 4] < min(1.0, depth / 30.0):
                a[y, x] = PLANET1

    # Circuit traces on the planet: horizontal runs whose spacing grows with
    # depth (fake perspective), vertical risers at fixed x, pads at joints.
    runs = [3, 7, 13, 21, 31]
    risers = rng.sample(range(0, W, 8), 14)
    for x in range(W):
        hy = horizon[x]
        for r in runs:
            y = hy + r
            if y < h and ((x // 16 + r) % 5 != 0):
                a[y, x] = PLANET_TRACE
    for rx in risers:
        r0, r1 = sorted(rng.sample(runs, 2))
        for y in range(horizon[rx] + r0, min(h, horizon[rx] + r1 + 1)):
            a[y, rx] = PLANET_TRACE
        for r in (r0, r1):
            y = horizon[rx] + r
            if y < h:
                a[y, rx] = PLANET_PAD
    # a few dim "chips" (dark blocks with a lighter top edge) far down
    for cx in (40, 132, 210):
        y0 = horizon[cx] + 15
        a[y0 : y0 + 4, cx : cx + 10] = DEEP0
        a[y0, cx : cx + 10] = PLANET_PAD
    return a


# --------------------------------------------------------------------------
# bg_near.png: 256x24, transparent above a circuit-board ridge.
# --------------------------------------------------------------------------
def draw_bg_near() -> np.ndarray:
    h = 24
    a = np.zeros((h, W, 3), np.uint8)
    a[:, :] = KEY
    rng = random.Random(99)
    # board top edge: stepped profile, one level per 32 px segment
    levels = [9, 8, 10, 9, 7, 9, 10, 8]
    top = np.array([levels[x // 32] for x in range(W)])
    # Foreground silhouette: lit top edge, then darker than the far planet,
    # dithering down to the outline colour at the bottom.
    for x in range(W):
        t = top[x]
        a[t:h, x] = DEEP0
        a[t, x] = DEEP2
        a[t + 1, x] = DEEP1
        for y in range(t + 2, h):
            if BAYER4[y % 4, x % 4] < (y - t - 4) / 10.0:
                a[y, x] = OUTLINE
    # step risers
    for x in range(W):
        xn = (x + 1) % W
        if top[xn] != top[x]:
            lo, hi = sorted((top[x], top[xn]))
            col = xn if top[xn] < top[x] else x
            a[lo:hi + 1, col] = DEEP2

    # traces: two lanes with 45-degree jogs between 32 px segments. The jog
    # pattern is indexed modulo the segment count so the wrap is seamless.
    for lane, offs in ((14, [0, 1, 0, -1, 0, 1, 1, 0]), (19, [0, -1, -1, 0, 1, 0, -1, 0])):
        for x in range(W):
            seg, pos = divmod(x, 32)
            cur, nxt = offs[seg], offs[(seg + 1) % len(offs)]
            d = nxt - cur
            y = lane + cur + int(np.sign(d)) * max(0, pos - (31 - abs(d)))
            y = max(int(top[x]) + 3, min(h - 2, y))
            a[y, x] = DARKTEAL
    # pads and vias on the traces
    for x in range(4, W, 23):
        for y in range(top[x] + 3, h - 1):
            if tuple(a[y, x]) == DARKTEAL:
                a[y, x] = TEAL
                break
    for x in range(10, W, 37):
        y = top[x] + 4
        a[y, x] = OUTLINE
        a[y, x - 1] = DARKTEAL
        a[y, (x + 1) % W] = DARKTEAL

    # chips standing on the board: dark body, lighter lid edge, grey pins
    def chip(x0: int, w: int, hgt: int) -> None:
        base = int(min(top[x0 : x0 + w]))
        y0 = base - hgt
        a[y0:base + 2, x0:x0 + w] = DARK
        a[y0, x0:x0 + w] = OUTLINE
        a[y0:base + 2, x0] = OUTLINE
        a[y0:base + 2, x0 + w - 1] = OUTLINE
        a[y0 + 1, x0 + 1:x0 + w - 1] = MIDDARK
        a[y0 + 2, x0 + 2] = GREY  # pin-1 dot
        for px in range(x0 + 2, x0 + w - 2, 2):
            a[base + 2, px] = GREY  # pins on the board
        # tiny Iris-ish marking
        mx = x0 + w // 2
        a[y0 + 3, mx - 1:mx + 2] = PURPLE1
    chip(66, 18, 5)
    chip(176, 10, 3)
    # capacitors: 3 px cylinders
    for cx in (20, 130, 228):
        t = top[cx]
        a[t - 3:t, cx:cx + 3] = DEEP2
        a[t - 3, cx:cx + 3] = OUTLINE
        a[t - 2:t, cx + 1] = DARKTEAL
    return a


PLACEHOLDER_DRAW = {
    "ship.png": draw_ship,
    "thruster.png": draw_thruster,
    "bolt.png": draw_bolt,
    "bugs_small.png": draw_bugs_small,
    "fx_small.png": draw_fx_small,
    "hud.png": draw_hud,
    "bg_far.png": draw_bg_far,
    "bg_near.png": draw_bg_near,
}


# --------------------------------------------------------------------------
# Generic helpers for delivered art (--study)
# --------------------------------------------------------------------------
def load_rgba(path: Path) -> np.ndarray:
    return np.array(Image.open(path).convert("RGBA"))


def hard_alpha(rgba: np.ndarray, cut: int = 128) -> tuple[np.ndarray, np.ndarray, int]:
    """Returns (rgb, opaque mask, soft pixel count)."""
    alpha = rgba[:, :, 3]
    soft = int(((alpha > 0) & (alpha < 255)).sum())
    return rgba[:, :, :3].copy(), alpha >= cut, soft


def read_gpl(path: Path) -> list[tuple[int, int, int]]:
    cols = []
    for line in path.read_text().splitlines():
        parts = line.split()
        if len(parts) >= 3 and all(p.isdigit() for p in parts[:3]):
            cols.append(tuple(int(p) for p in parts[:3]))
    if not cols:
        raise SystemExit(f"{path}: no colors found in GIMP palette")
    return cols


def snap(rgb: np.ndarray, mask: np.ndarray, palette: list[tuple[int, int, int]]) -> np.ndarray:
    pal = np.array(palette, np.int32)
    d = ((rgb.astype(np.int32)[:, :, None, :] - pal[None, None]) ** 2).sum(axis=3)
    out = rgb.copy()
    out[mask] = pal[d.argmin(axis=2)][mask].astype(np.uint8)
    return out


def flatten(rgb: np.ndarray, mask: np.ndarray) -> np.ndarray:
    out = rgb.copy()
    out[~mask] = KEY
    return out


# --------------------------------------------------------------------------
# Validation
# --------------------------------------------------------------------------
def rgb565(a: np.ndarray) -> np.ndarray:
    a = a.astype(np.uint32)
    return ((a[..., 0] >> 3) << 11) | ((a[..., 1] >> 2) << 5) | (a[..., 2] >> 3)


KEY565 = (31 << 11) | (0 << 5) | 31  # the converter's key after its own 5-6-5 cut


def validate(sheet: Sheet, a: np.ndarray, hitbox=SHIP_HITBOX) -> list[str]:
    errors: list[str] = []
    h, w = a.shape[:2]
    info = f"{sheet.name:15s} {w}x{h}"
    if (w, h) != (sheet.width, sheet.height):
        errors.append(f"size {w}x{h}, expected {sheet.width}x{sheet.height}")
    if sheet.width % sheet.cell_w or sheet.width // sheet.cell_w != sheet.frames or sheet.height != sheet.cell_h:
        errors.append("manifest cell grid inconsistent")
    q = rgb565(a)
    is_key = (a == KEY).all(axis=2)
    near_key = (q == KEY565) & ~is_key
    if near_key.any():
        errors.append(f"{int(near_key.sum())} px collapse to the key in RGB565 but are not #FF00FF")
    if sheet.transparent:
        opaque = ~is_key
        if not is_key.any():
            errors.append("no #FF00FF key pixels: transparent sheet has no empty space")
    else:
        opaque = np.ones((h, w), bool)
        if is_key.any():
            errors.append(f"{int(is_key.sum())} px of #FF00FF in an opaque sheet")
    ncol = len(np.unique(q[opaque]))
    if ncol > sheet.max_colors:
        errors.append(f"{ncol} opaque colors after RGB565, max {sheet.max_colors}")
    info += f"  cells {sheet.frames}x {sheet.cell_w}x{sheet.cell_h}  opaque colors {ncol}/{sheet.max_colors}"

    if sheet.transparent and not sheet.tile_x and (w, h) == (sheet.width, sheet.height):
        for i in range(sheet.frames):
            c = opaque[:, i * sheet.cell_w : (i + 1) * sheet.cell_w]
            if c[0].any() or c[-1].any() or c[:, 0].any() or c[:, -1].any():
                errors.append(f"cell {i}: drawing touches the cell edge (keep a 1 px border)")
            if not c.any():
                errors.append(f"cell {i}: empty")

    if sheet.name == "ship.png" and (w, h) == (sheet.width, sheet.height):
        x, y, bw, bh = hitbox
        ok = all(opaque[y : y + bh, i * 32 + x : i * 32 + x + bw].all() for i in range(sheet.frames))
        info += f"\n{'':15s} hitbox ({x},{y}) {bw}x{bh}: {'opaque in all frames' if ok else 'NOT fully opaque'}"
        if not ok:
            errors.append("ship hitbox rectangle has transparent pixels")

    if sheet.tile_x:
        # Seam = mismatch between column w-1 and column 0, compared with the
        # typical mismatch between neighbouring columns inside the image.
        cols = q
        inner = (cols[:, 1:] != cols[:, :-1]).mean(axis=0)
        seam = float((cols[:, -1] != cols[:, 0]).mean())
        typical = float(np.percentile(inner, 90))
        info += f"\n{'':15s} seam mismatch {seam:.2f} (90th pct inner {typical:.2f})"
        if seam > typical + 0.05:
            errors.append(f"does not tile: seam mismatch {seam:.2f} > {typical:.2f}")
    print(info)
    for e in errors:
        print(f"{'':15s} ERROR {e}")
    return errors


# --------------------------------------------------------------------------
# Modes
# --------------------------------------------------------------------------
def run_placeholders() -> int:
    errors = 0
    for name in PLACEHOLDER_SHEETS:
        a = PLACEHOLDER_DRAW[name]()
        errs = validate(MANIFEST[name], a)
        errors += len(errs)
        if not errs:
            save(a, name)
    print(f"ship hitbox {SHIP_HITBOX}, thruster offset {THRUSTER_OFFSET} (cart/src/player.zig)")
    return 1 if errors else 0


def run_study(study: Path, snap_gpl: Path | None) -> int:
    if not study.is_dir():
        raise SystemExit(f"{study}: not a directory")
    meta_path = study / "assets.json"
    meta = json.loads(meta_path.read_text()) if meta_path.exists() else {}
    if not meta:
        print(f"warning: {meta_path} missing or empty; using manifest hitbox/offset")
    palette = read_gpl(snap_gpl) if snap_gpl else None
    errors = 0
    found = 0
    for name, rel in STUDY_LAYOUT.items():
        src = study / rel
        if not src.exists():
            if MANIFEST[name].in_build:
                print(f"{name:15s} ERROR missing {src} (expected ASSETS.md section 8 layout)")
                errors += 1
            continue
        found += 1
        rgb, mask, soft = hard_alpha(load_rgba(src))
        if soft:
            print(f"{name:15s} note: {soft} semi-transparent px hard-cut at alpha 128")
        if palette:
            rgb = snap(rgb, mask, palette)
        if MANIFEST[name].transparent:
            a = flatten(rgb, mask)
        else:
            if not mask.all():
                print(f"{name:15s} ERROR opaque sheet has transparent pixels")
                errors += 1
            a = rgb
        hitbox = SHIP_HITBOX
        meta_errors = errors
        if name == "ship.png":
            m = meta.get("ship.png") or meta.get("ship") or {}
            hb = m.get("hitbox") or m.get("ship_hitbox")
            if hb:
                hb = tuple(hb[k] for k in ("x", "y", "w", "h")) if isinstance(hb, dict) else tuple(hb)
                if hb != SHIP_HITBOX:
                    print(f"{name:15s} ERROR study hitbox {hb} != hard-coded {SHIP_HITBOX}: "
                          "update cart/src/player.zig and SHIP_HITBOX here")
                    errors += 1
                hitbox = hb
            th = m.get("thruster_offset") or (meta.get("thruster.png") or {}).get("offset")
            if th and tuple(th) != THRUSTER_OFFSET:
                print(f"{name:15s} ERROR study thruster offset {tuple(th)} != {THRUSTER_OFFSET}: "
                      "update cart/src/player.zig and THRUSTER_OFFSET here")
                errors += 1
        errs = validate(MANIFEST[name], a, hitbox)
        if not errs and errors == meta_errors:
            save(a, name)
        errors += len(errs)
        if not errs and errors == meta_errors:
            if not MANIFEST[name].in_build:
                print(f"{'':15s} note: not yet in build.zig `images`")
    if not found:
        print(f"ERROR: no sheets found under {study}/sheets/")
        errors += 1
    return 1 if errors else 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--placeholders", action="store_true", help="draw placeholder art into assets/gen/")
    g.add_argument("--study", type=Path, help="import a delivered Bugs_Study_NN folder")
    ap.add_argument("--snap", type=Path, help="GIMP .gpl palette to snap study colors to")
    args = ap.parse_args()
    OUT.mkdir(parents=True, exist_ok=True)
    if args.placeholders:
        return run_placeholders()
    return run_study(args.study, args.snap)


if __name__ == "__main__":
    sys.exit(main())
