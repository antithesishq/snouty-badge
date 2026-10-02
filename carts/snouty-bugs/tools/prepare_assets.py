#!/usr/bin/env python3
"""Prepare the build inputs in assets/gen/ for Snouty Bughunt (Snouty vs. the Bugs).

Two modes:

  python3 tools/prepare_assets.py --placeholders
      Procedurally draws every in-build sheet (PLAN.md "Asset contract") as
      readable Genesis-style placeholder art, straight into assets/gen/.

  python3 tools/prepare_assets.py --study assets/Bugs_Study_NN [--snap FILE.gpl]
      Takes a delivered art study (ASSETS.md section 8 layout:
      <study>/sheets/<name>.png RGBA strips, <study>/assets.json metadata),
      applies a hard alpha cut, optionally snaps to a GIMP palette, flattens
      alpha 0 to the #FF00FF key and writes assets/gen/<name>.png.

Either mode (or neither) can add `--contact docs/placeholders.png`, which
tiles every sheet in assets/gen at 4x with labels plus a 160x128 mockup.

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
# Manifest. Must match SPEC.md section 12, PLAN.md "Asset contract" and
# build.zig `images`. M6 (2026-10-02): bolt.png grew to 6 cells (zap, assert
# beam, bisect seeker), new pickups.png (six crates), hud.png cell 1 = shield.
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
        Sheet("bolt.png", 96, 8, 16, 8, 6, True),
        Sheet("bugs_small.png", 32, 8, 8, 8, 4, True),
        Sheet("fx_small.png", 128, 16, 16, 16, 8, True),
        Sheet("hud.png", 48, 8, 12, 8, 4, True),
        Sheet("bg_far.png", 256, 120, 256, 120, 1, False, tile_x=True),
        Sheet("bg_near.png", 256, 24, 256, 24, 1, True, tile_x=True),
        Sheet("pickups.png", 96, 16, 16, 16, 6, True),
        # Later milestones (ASSETS.md section 7). Accepted from a study but
        # only useful once build.zig lists them.
        Sheet("bugs.png", 160, 16, 16, 16, 10, True),
        Sheet("boss.png", 240, 48, 48, 48, 5, True),
        Sheet("fx_big.png", 192, 32, 32, 32, 6, True),
        Sheet("title.png", 128, 40, 128, 40, 1, True),
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
# bolt.png  (6 cells 16x8, one per player bolt kind, two flicker frames
# each; SPEC.md 5.4).
#   0-1 FUZZER zap: 12x4 visible at x 2..13, y 2..5. Coral core, cream
#       leading tip on the right, dark red tail (unchanged since M1).
#   2-3 ASSERT beam segment: a 2 px Anti-White bar at y 3..4 over x 1..14
#       with Coral end caps and a Coral glow on y 2 and 5; frame 1 has a
#       shorter glow and two cream glints in the core. The cart draws beams as rects (thickness by
#       level); these cells are the fallback / tile for a beam segment.
#   4-5 BISECT seeker: an 9x6 purple dart pointing right at x 4..12, y 1..6
#       (body centred on the cell), swept fins, cream nose, and a short
#       purple/cream tail at x 1..3 that grows by a pixel in frame 1.
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


BEAMS = [
    ["................",
     "................",
     "..CCCCCCCCCCCC..",
     ".CwwwwwwwwwwwwC.",
     ".CwwwwwwwwwwwwC.",
     "..CCCCCCCCCCCC..",
     "................",
     "................"],
    ["................",
     "................",
     "...CCCCCCCCCC...",
     ".CwwwcwwwwwcwwC.",
     ".CwwcwwwwwcwwwC.",
     "...CCCCCCCCCC...",
     "................",
     "................"],
]
SEEKERS = [
    ["................",
     "....ooo.........",
     "....o44oo.......",
     "..4co4444ccwo...",
     "..3co3333ccwo...",
     "....o22oo.......",
     "....ooo.........",
     "................"],
    ["................",
     "....ooo.........",
     "....o44oo.......",
     ".c4co4444ccwo...",
     ".p3co3333ccwo...",
     "....o22oo.......",
     "....ooo.........",
     "................"],
]
BOLT_CMAP.update({"2": PURPLE2, "3": PURPLE3, "4": PURPLE4})


def draw_bolt() -> np.ndarray:
    a = new_sheet(MANIFEST["bolt.png"])
    for i, f in enumerate(BOLTS + BEAMS + SEEKERS):
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
# hud.png (4 cells 12x8, 1 px transparent border): 0 Snouty head (rewind
# stock), 1 RETRY shield (M6: floats centred above the ship cell at y - 6
# while the shield is up; 8x6 visible, a Coral heater shield with a cream
# rim, red on the shaded right side and a glint top left; wide, flat-topped
# and straight-sided so it never reads as the red heart in cell 3), 2 spare
# (was a bomb icon), 3 heart. The head cell went from
# 8x8 to 12x8 on 2026-09-29: at 6x6 visible the profile read as a rat (a
# tapering snout and a 1 px ear). 10x6 fits the real features: a round 2 px
# ear on the back of the dome, a 2x2 cream eye with a forward pupil and a
# blunt 3 px thick snout tube that droops at the tip, like the ship's head.
# --------------------------------------------------------------------------
HUD_CMAP = {"o": OUTLINE, "3": PURPLE3, "4": PURPLE4, "2": PURPLE2, "c": CREAM,
            "C": CORAL, "r": RED, "g": GREY, "m": MIDDARK, "w": ANTIWHITE}
HUD_HEAD = [
    "............",
    "..44........",
    ".43333......",
    ".333cc3.....",
    ".333co34444.",
    ".2333333333.",
    ".2222...222.",
    "............",
]
HUD_SHIELD = [
    "............",
    "..cccccccc..",
    "..cCwCCCrc..",
    "..cCCCCCrc..",
    "..cCCCCCrc..",
    "...cCCCrc...",
    "....cccc....",
    "............",
]
HUD_SMALL = [  # 8x8 designs, centred in the 12x8 cell (cells 2 and 3)
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
    sheet = MANIFEST["hud.png"]
    a = new_sheet(sheet)
    paint(a, HUD_HEAD, 0, 0, HUD_CMAP)
    paint(a, HUD_SHIELD, sheet.cell_w, 0, HUD_CMAP)
    for i, f in enumerate(HUD_SMALL):
        paint(a, f, (i + 2) * sheet.cell_w + 2, 0, HUD_CMAP)
    return a


# --------------------------------------------------------------------------
# pickups.png (6 cells 16x16, M6 crates, SPEC.md 5.4): 0 FUZZER "F",
# 1 ASSERT "A", 2 BISECT "B", 3 FORK (a branching path), 4 RETRY (shield),
# 5 CORE HOURS (a CPU chip with pins). Every crate is the same 14x14
# chamfered box at x 1..14, y 1..14: 1 px dark outline, a lit top row and
# left column, a shaded right column and bottom lip, and a 10x9 face that
# carries a 5x7 glyph (1 px strokes) with a 1 px drop shadow to the lower
# right. Square, solid and boxy on purpose: the enemy bullets are small
# round discs and needles and the bugs are irregular silhouettes, so a
# crate never reads as either. Fifteen colours shared by six hues (the
# light/shade tones double up across crates to stay inside 4 bits).
# --------------------------------------------------------------------------
LIGHTTEAL = hx("8fe3d6")  # assert crate lit edge (teal family, one step up)
CRATE = [
    "................",
    "..oooooooooooo..",
    ".ohhhhhhhhhhhho.",
    ".ohbbbbbbbbbbso.",
    ".ohbbbbbbbbbbso.",
    ".ohbbbbbbbbbbso.",
    ".ohbbbbbbbbbbso.",
    ".ohbbbbbbbbbbso.",
    ".ohbbbbbbbbbbso.",
    ".ohbbbbbbbbbbso.",
    ".ohbbbbbbbbbbso.",
    ".ohbbbbbbbbbbso.",
    ".ohbbbbbbbbbbso.",
    ".osssssssssssso.",
    "..oooooooooooo..",
    "................",
]
GLYPHS = {
    "F": ["#####", "#....", "#....", "####.", "#....", "#....", "#...."],
    "A": [".###.", "#...#", "#...#", "#####", "#...#", "#...#", "#...#"],
    "B": ["####.", "#...#", "#...#", "####.", "#...#", "#...#", "####."],
    # a fork in a path: two branch tips with nodes, merging into one trunk
    "Y": ["#...#", "#...#", ".#.#.", "..#..", "..#..", "..#..", ".###."],
}
# Full-face glyphs (drawn as is, no drop shadow), 10x9 at face (3, 3).
RETRY_FACE = [
    "..........",
    ".oooooooo.",
    ".oCCwCCro.",
    ".oCwCCCro.",
    ".oCCCCCro.",
    ".oCCCCCro.",
    "..oCCCro..",
    "...oCro...",
    "....oo....",
]
CHIP_FACE = [
    "..........",
    "...o.o.o..",
    "..ooooooo.",
    ".ooOOOOOoo",
    "..oOwwwOo.",
    ".ooOwwwOoo",
    "..oOOOOOo.",
    "..ooooooo.",
    "...o.o.o..",
]
CRATES = [  # glyph, body, lit edge, shade, glyph colour
    ("F", CORAL, CREAM, RED, ANTIWHITE),
    ("A", TEAL, LIGHTTEAL, DARKTEAL, ANTIWHITE),
    ("B", GREEN, LIGHTGREEN, DARKTEAL, ANTIWHITE),
    ("Y", PURPLE3, PURPLE4, PURPLE2, ANTIWHITE),
    (RETRY_FACE, CREAM, ANTIWHITE, TAN, CORAL),
    (CHIP_FACE, YELLOW, CREAM, TAN, OUTLINE),
]


def draw_pickups() -> np.ndarray:
    a = new_sheet(MANIFEST["pickups.png"])
    for i, (glyph, body, lit, shade, ink) in enumerate(CRATES):
        cmap = {"o": OUTLINE, "h": lit, "b": body, "s": shade, "#": ink, "d": shade,
                "C": CORAL, "r": RED, "w": ANTIWHITE, "O": OUTLINE}
        x0 = i * 16
        paint(a, CRATE, x0, 0, cmap)
        if isinstance(glyph, str):
            g = GLYPHS[glyph]
            shadow = [r.replace("#", "d") for r in g]
            paint(a, shadow, x0 + 6, 5, cmap)
            paint(a, g, x0 + 5, 4, cmap)
        else:
            paint(a, glyph, x0 + 3, 3, cmap)
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


# --------------------------------------------------------------------------
# bugs.png (10 cells 16x16, all enemies face left): 0-1 wasp, 2-3 beetle,
# 4-5 spider, 6-7 moth, 8 needle bullet, 9 spare (the old bomb pickup,
# unused since the bomb was dropped; crates live in pickups.png). Five distinct
# silhouettes (ASSETS.md section 5): arrow, dome, round-with-legs, delta.
# --------------------------------------------------------------------------
DKGREEN = hx("24552a")  # beetle shell shadow (placeholder mix, bug greens)
BUGS_CMAP = {"o": OUTLINE, "m": MIDDARK, "g": GREY, "c": CREAM, "w": WHITE,
             "y": YELLOW, "L": LIGHTTAN, "t": TAN, "G": GREEN, "l": LIGHTGREEN,
             "D": DKGREEN, "p": PURPLE2, "P": PURPLE3, "r": RED, "C": CORAL}


def grid(fn, size: int = 16) -> list[str]:
    """Rows from fn(x, y) -> char ('.' = empty), 1 px border kept empty."""
    return ["".join("." if x in (0, size - 1) or y in (0, size - 1) else fn(x, y)
                    for x in range(size)) for y in range(size)]


def over(base: list[str], top: list[str]) -> list[str]:
    """Overlay rows: non-empty chars of `top` win."""
    return ["".join(t if t != "." else b for b, t in zip(br, tr)) for br, tr in zip(base, top)]


def plot(rows: list[str], pts, ch: str) -> list[str]:
    out = [list(r) for r in rows]
    for x, y in pts:
        if 0 < x < len(out[0]) - 1 and 0 < y < len(out) - 1:
            out[y][x] = ch
    return ["".join(r) for r in out]


WASP_H = {2: 1.5, 3: 1.5, 4: 1.5, 5: 0.5, 6: 1.5, 7: 1.5, 8: 0.5,
          9: 2.5, 10: 2.5, 11: 2.5, 12: 1.5, 13: 0.5}  # body half-height per column


def seg_dist(x: float, y: float, a: tuple, b: tuple) -> float:
    (ax, ay), (bx, by) = a, b
    t = max(0.0, min(1.0, ((x - ax) * (bx - ax) + (y - ay) * (by - ay)) / ((bx - ax) ** 2 + (by - ay) ** 2)))
    return math.hypot(x - ax - t * (bx - ax), y - ay - t * (by - ay))


def wasp(frame: int) -> list[str]:
    # Top-down chevron pointing left: yellow head with a red eye, pinched
    # waist, black-banded abdomen ending in a stinger; two pale wings swept
    # back like arrowhead barbs, wide (0) and folded in (1).
    def body(x, y):
        h = WASP_H.get(x)
        if h is None or abs(y - 7.5) > h:
            return "."
        if x in (10, 12):
            return "o"
        return "L" if y < 7.5 and abs(y - 7.5) > h - 1 else "y"
    tip = [(11, 2), (11, 13)] if frame == 0 else [(12, 4), (12, 11)]
    def wing(x, y):
        d = min(seg_dist(x, y, (6, 6 if t[1] < 7 else 9), t) for t in tip)
        if d > 1.1:
            return "."
        return "c" if d < 0.6 else "g"
    rows = over(grid(wing), grid(body))
    rows = plot(rows, [(3, 7)], "r")
    rows = outline_rows(rows)
    return plot(rows, [(14, 7), (14, 8)], "o")  # stinger


def beetle(frame: int) -> list[str]:
    # Tall green dome (shield), tan belly, small dark head with a cream eye
    # on the left; three legs that alternate between frames.
    def shell(x, y):
        if y > 10:
            return "."
        d = ((x - 8.5) / 5.5) ** 2 + ((y - 10.5) / 7.0) ** 2
        if d > 1:
            return "."
        if ((x - 7) / 3.5) ** 2 + ((y - 6) / 2.5) ** 2 < 0.35:
            return "l"
        return "D" if d > 0.62 and x > 8 else "G"
    rows = grid(shell)
    rows = over(rows, grid(lambda x, y: "t" if y == 11 and 4 <= x <= 13 else "."))
    rows = over(rows, grid(lambda x, y: "D" if (x - 2.5) ** 2 + (y - 9.5) ** 2 <= 2.3 else "."))
    rows = plot(rows, [(2, 9)], "c")
    rows = outline_rows(rows)
    legs = [(5, 13), (8, 13), (11, 13)] if frame == 0 else [(4, 13), (7, 13), (12, 13)]
    rows = plot(rows, legs, "o")
    return plot(rows, [(1, 7)] if frame == 0 else [(1, 8)], "o")  # antenna


SPIDER_LEGS = [  # left side, per frame; the right side mirrors about x = 7.5
    [[(4, 6), (3, 5), (2, 5), (1, 6)], [(4, 8), (3, 7), (2, 7), (1, 8)],
     [(4, 9), (3, 10), (2, 10), (1, 11)], [(5, 11), (4, 12), (3, 13), (3, 14)]],
    [[(4, 6), (3, 4), (2, 4), (1, 5)], [(4, 8), (3, 8), (2, 8), (1, 9)],
     [(4, 9), (3, 10), (2, 11), (1, 12)], [(5, 11), (4, 13), (4, 14)]],
]


def spider(frame: int) -> list[str]:
    # Round purple body hanging from the thread (the cart's vline at cell
    # x 8), two red eyes, eight grey legs drawn after the outline so they
    # stay thin; the leg tips twitch between frames.
    def body(x, y):
        d = math.hypot(x - 7.5, y - 8)
        if d > 3.2:
            return "."
        return "P" if math.hypot(x - 6.5, y - 6.5) < 1.5 else "p"
    rows = outline_rows(grid(body))
    rows = plot(rows, [(6, 10), (9, 10)], "r")
    for leg in SPIDER_LEGS[frame]:
        rows = plot(rows, leg + [(15 - x, y) for x, y in leg], "g")
    return plot(rows, [(8, 1), (8, 2), (8, 3)], "g")  # thread stub meets the vline


def moth(frame: int) -> list[str]:
    # Big pale delta pointing left with a swallowtail notch: cream wings,
    # light-tan leading edges, purple eye spots, a short tan body and
    # antennae. Frame 1 raises the wings (narrower span).
    spread = 0.75 if frame == 0 else 0.5
    def wings(x, y):
        dy = abs(y - 7.5)
        h = 0.5 + (x - 3) * spread
        rear = 13 if dy > 2 else 11  # small tail notch, the body fills it
        if x < 3 or dy > h or x > rear:
            return "."
        if dy > h - 1.2 or x == rear:
            return "L"
        if x in (9, 10) and abs(dy - h * 0.55) < 0.7:
            return "P"
        if x == 7 and dy > 1:
            return "g"  # vein
        return "c"
    rows = grid(wings)
    rows = over(rows, grid(lambda x, y: "t" if y in (7, 8) and 2 <= x <= 11 else "."))
    rows = outline_rows(rows)
    return plot(rows, [(2, 5), (1, 4)] if frame == 0 else [(2, 6), (1, 5)], "L")


NEEDLE = [  # 8x4 visible at x 4..11, y 6..9: centered, cell top-left = center - (8, 8)
    "................",
    "................",
    "................",
    "................",
    "................",
    "................",
    ".....oooooo.....",
    "....ocwwwwco....",
    "....ocwwwwco....",
    ".....oooooo.....",
    "................",
    "................",
    "................",
    "................",
    "................",
    "................",
]


def bomb_pickup() -> list[str]:
    # Spare cell (unused by the cart). hud.png's old bomb icon at 16x16: cream ring, dark gap, Coral iris with a
    # red pupil and a cream catch-light.
    def f(x, y):
        d = math.hypot(x - 7.5, y - 7.5)
        if d > 6.4:
            return "."
        if d > 5.0:
            return "c"
        if d > 3.9:
            return "o"
        if d > 1.6:
            return "C"
        return "r"
    rows = outline_rows(grid(f))
    return plot(rows, [(6, 6)], "c")


def draw_bugs() -> np.ndarray:
    a = new_sheet(MANIFEST["bugs.png"])
    cells = [wasp(0), wasp(1), beetle(0), beetle(1), spider(0), spider(1),
             moth(0), moth(1), NEEDLE, bomb_pickup()]
    for i, f in enumerate(cells):
        paint(a, f, i * 16, 0, BUGS_CMAP)
    return a


# --------------------------------------------------------------------------
# fx_big.png (6 cells 32x32): player death and boss. Compact white/yellow
# core, orange and red at full size, breaking up into grey/mid-dark smoke,
# then a small puff so the pop reads.
# --------------------------------------------------------------------------
FXB = {"o": OUTLINE, "m": MIDDARK, "g": GREY, "w": WHITE, "y": FXYELLOW,
       "n": ORANGE, "r": RED, "R": DARKRED, "c": CREAM, "P": PURPLE3}


def fire_frame(rng: random.Random, radius: float, bands: list[tuple[float, str]],
               holes: float = 0.0, ring_inner: float = 0.0,
               blobs: list[tuple[float, float, float]] = ()) -> list[str]:
    """32x32 version of disc_frame with extra off-centre fireballs (dx, dy,
    r) unioned into the main disc so the silhouette is not a circle."""
    c = 15.5
    rows = []
    for y in range(32):
        row = ""
        for x in range(32):
            ch = "."
            if not (x in (0, 31) or y in (0, 31)):
                d = math.hypot(x - c, y - c)
                ang = math.atan2(y - c, x - c)
                r = radius * (1 + 0.1 * math.sin(ang * 7 + radius) + 0.06 * math.sin(ang * 3))
                inside = ring_inner <= d <= r
                frac = d / r
                for bx, by, br in blobs:
                    db = math.hypot(x - c - bx, y - c - by)
                    if db <= br and d >= ring_inner:
                        inside = True
                        frac = min(frac, max(db / br, 0.5))
                if inside:
                    ch = bands[-1][1]
                    for f, col in bands:
                        if frac <= f:
                            ch = col
                            break
                    if holes and rng.random() < holes:
                        ch = "."
            row += ch
        rows.append(row)
    return rows


def draw_fx_big() -> np.ndarray:
    rng = random.Random(11)
    a = new_sheet(MANIFEST["fx_big.png"])
    frames = [
        outline_rows(fire_frame(rng, 5.0, [(0.6, "w"), (1.0, "y")])),
        outline_rows(fire_frame(rng, 8.5, [(0.35, "w"), (0.7, "y"), (1.0, "n")],
                                blobs=[(6, -5, 3.0), (-6, 4, 3.0)])),
        outline_rows(fire_frame(rng, 11.5, [(0.25, "y"), (0.6, "n"), (1.0, "r")], holes=0.05,
                                blobs=[(8, -7, 4.0), (-8, 6, 4.0), (-7, -8, 3.0)])),
        outline_rows(fire_frame(rng, 12.5, [(0.55, "n"), (0.8, "r"), (1.0, "R")], holes=0.25,
                                ring_inner=5.0, blobs=[(9, -8, 3.5), (-9, 7, 3.5)])),
        fire_frame(rng, 13.0, [(0.75, "g"), (1.0, "m")], holes=0.4, ring_inner=8.0,
                   blobs=[(9, -8, 3.0), (-9, 7, 3.0)]),
        fire_frame(rng, 6.5, [(0.5, "g"), (1.0, "m")], holes=0.3, ring_inner=1.5,
                   blobs=[(4, -4, 2.0), (-4, 3, 2.0)]),
    ]
    # a few embers in the smoke frames so they are not a flat grey ring
    frames[4] = plot(frames[4], [(8, 9), (23, 20), (21, 7), (9, 22)], "n")
    frames[4] = plot(frames[4], [(15, 4), (27, 15)], "P")
    frames[5] = plot(frames[5], [(13, 14), (18, 17)], "n")
    for i, f in enumerate(frames):
        paint(a, f, i * 32, 0, FXB)
    return a


# --------------------------------------------------------------------------
# boss.png (5 cells 48x48): the Heisenbug, a beetle/roach hybrid in side
# view facing left. Cells 0-3 idle loop (wings, legs, antennae move; body
# fixed), cell 4 the teleport silhouette. Built from layered masks back to
# front; every layer gets its own 1 px outline, so later parts are outlined
# against earlier ones (Genesis-style internal lines).
# --------------------------------------------------------------------------
BOSS_CMAP = {"o": OUTLINE, "m": MIDDARK, "1": PURPLE1, "2": PURPLE2, "3": PURPLE3,
             "4": PURPLE4, "g": GREY, "r": RED, "R": DARKRED, "b": BROWN1,
             "B": BROWN2, "t": TAN, "y": YELLOW, "G": GREEN, "l": LIGHTGREEN}
BOSS_N = 48

# The "?" on the shell, drawn over the elytra; '.' keeps the shell.
BOSS_QMARK = [
    "..ooooo..",
    ".oyyyyyo.",
    "oyylllyyo",
    "oyyoooyyo",
    ".ooo.oyyo",
    "....oyyGo",
    "...oyyGo.",
    "...oyyo..",
    "...oooo..",
    "...oyyo..",
    "...oyGo..",
    "...oooo..",
]
BOSS_QMARK_AT = (20, 17)  # centre about (24, 23): the cell centre, where the code emits bullets

# Per idle frame: near wing tip, far wing tip, leg phase shift, antenna tip.
BOSS_POSES = [
    ((37, 3), (31, 4), 0, (3, 7)),
    ((43, 6), (38, 3), 1, (2, 8)),
    ((45, 12), (43, 6), 2, (3, 9)),
    ((40, 4), (44, 10), 3, (4, 8)),
]
BOSS_LEG_SWING = [-1, 0, 1, 0]  # knee/foot x shift by (phase + leg) % 4
BOSS_LEGS = [  # hip, knee, foot of the near legs; far legs are offset
    [(18, 34), (14, 38), (11, 43)],
    [(26, 35), (24, 40), (22, 44)],
    [(34, 35), (38, 39), (41, 44)],
]


def _mgrid() -> tuple[np.ndarray, np.ndarray]:
    ys, xs = np.mgrid[0:BOSS_N, 0:BOSS_N]
    return xs.astype(float), ys.astype(float)


def _seg_mask(pts: list[tuple[float, float]], r: float) -> np.ndarray:
    """Pixels within r of the polyline through pts."""
    m = np.zeros((BOSS_N, BOSS_N), bool)
    for y in range(BOSS_N):
        for x in range(BOSS_N):
            m[y, x] = min(seg_dist(x, y, a, b) for a, b in zip(pts, pts[1:])) <= r
    return m


def _wing(root: tuple[float, float], tip: tuple[float, float], width: float) -> tuple[np.ndarray, np.ndarray]:
    """Membrane mask (widest at 45 % of the span) and its centre vein."""
    m = np.zeros((BOSS_N, BOSS_N), bool)
    vein = np.zeros_like(m)
    (ax, ay), (bx, by) = root, tip
    L2 = (bx - ax) ** 2 + (by - ay) ** 2
    for y in range(BOSS_N):
        for x in range(BOSS_N):
            t = ((x - ax) * (bx - ax) + (y - ay) * (by - ay)) / L2
            if not 0.0 <= t <= 1.0:
                continue
            d = seg_dist(x, y, root, tip)
            w = 0.8 + width * math.sin(math.pi * min(1.0, t / 0.9)) ** 0.7
            m[y, x] = d <= w
            vein[y, x] = d <= 0.5 and 0.15 < t < 0.85
    return m, vein


def _dilate4(m: np.ndarray) -> np.ndarray:
    d = m.copy()
    d[1:] |= m[:-1]
    d[:-1] |= m[1:]
    d[:, 1:] |= m[:, :-1]
    d[:, :-1] |= m[:, 1:]
    return d


def _layer(canvas: np.ndarray, mask: np.ndarray, fill, outline: bool = True) -> None:
    """Outline ring then fill; `fill` is a char or a char array."""
    if outline:
        canvas[_dilate4(mask) & ~mask] = "o"
    canvas[mask] = fill[mask] if isinstance(fill, np.ndarray) else fill


def boss_frame(frame: int) -> list[str]:
    near_tip, far_tip, phase, ant_tip = BOSS_POSES[frame]
    xs, ys = _mgrid()
    c = np.full((BOSS_N, BOSS_N), ".", "<U1")

    # Far wing (behind everything): darker membrane.
    fw, fv = _wing((25, 15), far_tip, 3.0)
    fcol = np.where(fv, "1", "m")
    _layer(c, fw, fcol)

    # Far legs, behind the belly: thin, dark brown, shifted back and up.
    far_legs = np.zeros((BOSS_N, BOSS_N), bool)
    for i, pts in enumerate(BOSS_LEGS):
        sw = BOSS_LEG_SWING[(phase + i + 2) % 4]
        far_legs |= _seg_mask([(x + 3 + (sw if j else 0), y - (1 if j else 0))
                               for j, (x, y) in enumerate(pts)], 0.55)
    _layer(c, far_legs, "b")

    # Belly: segmented tan abdomen under the shell, with cerci at the rear.
    belly = (((xs - 29) / 14.0) ** 2 + ((ys - 31) / 5.2) ** 2 <= 1) & (ys >= 30)
    bcol = np.where(((xs.astype(int) - 17) % 4 == 0) | (ys >= 35), "B", "t")
    _layer(c, belly, bcol)
    cerci = _seg_mask([(41, 33), (45, 35)], 0.6)
    _layer(c, cerci, "B")

    # Near legs: splayed like a roach (front leg forward, back leg back).
    near_legs = np.zeros((BOSS_N, BOSS_N), bool)
    for i, pts in enumerate(BOSS_LEGS):
        sw = BOSS_LEG_SWING[(phase + i) % 4]
        near_legs |= _seg_mask([(x + (sw * j), y) for j, (x, y) in enumerate(pts)], 0.8)
    _layer(c, near_legs, "B")

    # Shell (elytra): dome, lit from the upper left.
    u, v = (xs - 28.5) / 15.5, (ys - 24.5) / 11.0
    shell = (u ** 2 + v ** 2 <= 1) & (ys <= 32)
    scol = np.full(shell.shape, "2", "<U1")
    scol[(u * 0.45 + v * 0.8) > 0.5] = "1"
    scol[(u + 0.3) ** 2 + (v + 0.55) ** 2 < 0.10] = "3"
    scol[(u + 0.35) ** 2 * 1.6 + (v + 0.72) ** 2 < 0.012] = "4"
    scol[(ys == 31) | (ys == 32)] = "1"
    _layer(c, shell, scol)

    # Pronotum: the roach shield over the head, a darker purple with a lit rim.
    pu, pv = (xs - 14.5) / 6.5, (ys - 24.0) / 8.5
    pron = pu ** 2 + pv ** 2 <= 1
    pcol = np.where(pv < -0.55, "3", np.where(pu * 0.3 + pv > 0.45, "1", "2"))
    _layer(c, pron, pcol)

    # Head: brown, big red compound eye with a yellow glint, tan mandibles.
    head = (xs - 8.5) ** 2 + (ys - 30.0) ** 2 <= 4.6 ** 2
    _layer(c, head, np.where(ys > 32, "b", "B"))
    eye = (xs - 7.5) ** 2 / 2.4 ** 2 + (ys - 28.5) ** 2 / 2.6 ** 2 <= 1
    ecol = np.where(ys >= 29.5, "R", "r")
    _layer(c, eye, ecol, outline=False)
    mand = _seg_mask([(5, 33), (3, 35), (4, 36)], 0.55)
    _layer(c, mand, "t")

    # Near wing on top, rooted on the shell top: grey membrane, dark vein.
    nw, nv = _wing((29, 15), near_tip, 4.0)
    _layer(c, nw, np.where(nv, "m", "g"))

    rows = ["".join(r) for r in c]
    rows = plot(rows, [(7, 27)], "y")  # eye glint
    # Antennae: thin lines, no outline (like the bugs' legs), curving
    # forward and up from the head; the tips wiggle per frame.
    def curve(p0, p1, p2, n=24):
        return [(round((1 - t) ** 2 * p0[0] + 2 * (1 - t) * t * p1[0] + t * t * p2[0]),
                 round((1 - t) ** 2 * p0[1] + 2 * (1 - t) * t * p1[1] + t * t * p2[1]))
                for t in (k / n for k in range(1, n + 1))]
    ax, ay = ant_tip
    rows = plot(rows, curve((10, 25), (8, 13), (ax + 7, ay - 3)), "B")  # far antenna
    rows = plot(rows, curve((7, 25), (0, 20), (ax, ay)), "t")
    # keep the 1 px empty cell border
    return ["." * BOSS_N if y in (0, BOSS_N - 1) else "." + r[1:-1] + "."
            for y, r in enumerate(rows)]


def boss_silhouette(rows: list[str]) -> list[str]:
    """Teleport cell: the same shape as flat purple 3 with a purple 4 rim."""
    m = np.array([[ch != "." for ch in r] for r in rows])
    rim = m & ~(np.roll(m, 1, 0) & np.roll(m, -1, 0) & np.roll(m, 1, 1) & np.roll(m, -1, 1))
    return ["".join("4" if rim[y, x] else "3" if m[y, x] else "." for x in range(BOSS_N))
            for y in range(BOSS_N)]


def draw_boss() -> np.ndarray:
    a = new_sheet(MANIFEST["boss.png"])
    cells = [boss_frame(i) for i in range(4)]
    cells.append(boss_silhouette(cells[0]))
    for i, f in enumerate(cells):
        paint(a, f, i * BOSS_N, 0, BOSS_CMAP)
        if i < 4:
            paint(a, BOSS_QMARK, i * BOSS_N + BOSS_QMARK_AT[0], BOSS_QMARK_AT[1], BOSS_CMAP)
    return a


# --------------------------------------------------------------------------
# title.png (128x40): "SNOUTY" / "BUGHUNT" logo from a 5x7 block font,
# scaled 3x (line 1) and 2x (line 2) with rounded outer corners, banded
# purple fill, cream top highlight, 1 px dark outline. Line 2 in Coral
# (the title was "SNOUTY vs THE BUGS" until 2026-09-29).
# --------------------------------------------------------------------------
TITLE_CMAP = {"o": OUTLINE, "1": PURPLE1, "2": PURPLE2, "3": PURPLE3, "4": PURPLE4,
              "c": CREAM, "C": CORAL, "r": RED, "R": DARKRED}
FONT5X7 = {
    "S": [".####", "#....", "#....", ".###.", "....#", "....#", "####."],
    "N": ["#...#", "##..#", "#.#.#", "#..##", "#...#", "#...#", "#...#"],
    "O": [".###.", "#...#", "#...#", "#...#", "#...#", "#...#", ".###."],
    "U": ["#...#", "#...#", "#...#", "#...#", "#...#", "#...#", ".###."],
    "T": ["#####", "..#..", "..#..", "..#..", "..#..", "..#..", "..#.."],
    "Y": ["#...#", "#...#", ".#.#.", "..#..", "..#..", "..#..", "..#.."],
    "H": ["#...#", "#...#", "#...#", "#####", "#...#", "#...#", "#...#"],
    "E": ["#####", "#....", "#....", "####.", "#....", "#....", "#####"],
    "B": ["####.", "#...#", "#...#", "####.", "#...#", "#...#", "####."],
    "G": [".###.", "#...#", "#....", "#.###", "#...#", "#...#", ".###."],
    "v": [".....", ".....", "#...#", "#...#", "#...#", ".#.#.", "..#.."],
    "s": [".....", ".....", ".####", "#....", ".###.", "....#", "####."],
}


def glyph_mask(ch: str, k: int) -> np.ndarray:
    """5x7 glyph scaled k x k. Every diagonal step (a font cell that is empty
    with both neighbours toward one corner set, and the cell between them
    empty) gets a triangle fill, so round letters come out as chamfered
    octagons and diagonals as solid 45-degree strokes."""
    g = np.array([[c == "#" for c in r] for r in FONT5X7[ch]])
    on = lambda i, j: 0 <= i < 7 and 0 <= j < 5 and g[i, j]
    m = g.repeat(k, 0).repeat(k, 1)
    for i in range(7):
        for j in range(5):
            if g[i, j]:
                continue
            for di, dj in ((-1, -1), (-1, 1), (1, -1), (1, 1)):
                if on(i + di, j) and on(i, j + dj) and not on(i + di, j + dj):
                    for py in range(k):
                        for px in range(k):
                            # distance from the corner that faces (di, dj)
                            cy = py if di < 0 else k - 1 - py
                            cx = px if dj < 0 else k - 1 - px
                            if cx + cy <= k - 2:
                                m[i * k + py, j * k + px] = True
    return m


def _logo_line(text: str, k: int, gap: int, space: int) -> tuple[np.ndarray, list[tuple[int, int, str]]]:
    """Mask of one line and the (x0, x1, char) span of each glyph."""
    parts, spans, x = [], [], 0
    for ch in text:
        if ch == " ":
            parts.append(np.zeros((7 * k, space), bool))
            x += space
            continue
        if parts and not (parts[-1].shape[1] == space and not parts[-1].any()):
            parts.append(np.zeros((7 * k, gap), bool))
            x += gap
        gm = glyph_mask(ch, k)
        spans.append((x, x + gm.shape[1], ch))
        parts.append(gm)
        x += gm.shape[1]
    return np.concatenate(parts, axis=1), spans


def draw_title() -> np.ndarray:
    a = new_sheet(MANIFEST["title.png"])
    W_, H_ = 128, 40
    c = np.full((H_, W_), ".", "<U1")
    lines = [("SNOUTY", 3, 3, 0, 1), ("BUGHUNT", 2, 2, 6, 23)]  # text, scale, gap, space, outlined top y
    for text, k, gap, space, top in lines:
        m, spans = _logo_line(text, k, gap, space)
        h, w = m.shape
        x0 = (W_ - w) // 2
        full = np.zeros((H_, W_), bool)
        full[top + 1 : top + 1 + h, x0 : x0 + w] = m
        coral = np.zeros_like(full)
        if text == "BUGHUNT":
            coral[:] = True
        coral &= full
        ring = _dilate4(full) & ~full
        # outline stays under a letter already drawn (lines share one row)
        c[ring & (c == ".")] = "o"
        yy = np.arange(H_)[:, None] - (top + 1)
        rel = yy / h  # 0 at the glyph top, 1 at the bottom
        above = np.zeros_like(full)
        above[1:] = full[:-1]
        below = np.zeros_like(full)
        below[:-1] = full[1:]
        right = np.zeros_like(full)
        right[:, :-1] = full[:, 1:]
        fill = np.where(rel < 0.34, "4", np.where(rel < 0.67, "3", "2"))
        fill = np.where(~below, "1", fill)  # shadow on the bottom edges
        fill = np.where(~above, "c", fill)  # cream top highlight
        cfill = np.where(~below, "R", np.where(~above, "c", "C"))
        cfill = np.where(rel > 0.7, np.where(cfill == "C", "r", cfill), cfill)
        fill = np.where(coral, cfill, fill)
        c[full] = fill[full]
    paint(a, ["".join(r) for r in c], 0, 0, TITLE_CMAP)
    return a


PLACEHOLDER_DRAW = {
    "ship.png": draw_ship,
    "thruster.png": draw_thruster,
    "bolt.png": draw_bolt,
    "bugs_small.png": draw_bugs_small,
    "fx_small.png": draw_fx_small,
    "hud.png": draw_hud,
    "pickups.png": draw_pickups,
    "bg_far.png": draw_bg_far,
    "bg_near.png": draw_bg_near,
    "bugs.png": draw_bugs,
    "fx_big.png": draw_fx_big,
    "boss.png": draw_boss,
    "title.png": draw_title,
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
# Contact sheet (--contact): every sheet in assets/gen at 4x nearest-neighbour
# on a checkerboard, labelled, plus a 160x128 mockup frame.
# --------------------------------------------------------------------------
CONTACT_SCALE = 4
CONTACT_BG = (22, 20, 28)
CONTACT_INK = (220, 216, 228)


def load_gen(name: str) -> tuple[np.ndarray, np.ndarray]:
    """(rgb, opaque mask) of assets/gen/<name>."""
    a = np.array(Image.open(OUT / name).convert("RGB"))
    return a, ~(a == KEY).all(axis=2)


def checker(h: int, w: int, cell: int = 8) -> np.ndarray:
    yy, xx = np.mgrid[0:h, 0:w]
    on = ((yy // cell + xx // cell) % 2).astype(bool)
    out = np.empty((h, w, 3), np.uint8)
    out[:] = (46, 42, 56)
    out[on] = (60, 56, 72)
    return out


def blit(dst: np.ndarray, src: np.ndarray, mask: np.ndarray, x: int, y: int) -> None:
    """Paste src at (x, y) where mask is set, clipped to dst."""
    h, w = src.shape[:2]
    x0, y0 = max(0, -x), max(0, -y)
    x1, y1 = min(w, dst.shape[1] - x), min(h, dst.shape[0] - y)
    if x0 >= x1 or y0 >= y1:
        return
    d = dst[y + y0 : y + y1, x + x0 : x + x1]
    m = mask[y0:y1, x0:x1]
    d[m] = src[y0:y1, x0:x1][m]


def cell_of(name: str, i: int) -> tuple[np.ndarray, np.ndarray]:
    a, m = load_gen(name)
    s = MANIFEST[name]
    return a[:, i * s.cell_w : (i + 1) * s.cell_w], m[:, i * s.cell_w : (i + 1) * s.cell_w]


def mockup() -> np.ndarray:
    """One 160x128 frame in the game's draw order, for contrast checks."""
    f = np.zeros((128, 160, 3), np.uint8)
    far, _ = load_gen("bg_far.png")
    f[8:128] = far[:, :160]
    near, nm = load_gen("bg_near.png")
    blit(f, near[:, :160], nm[:, :160], 0, 104)
    f[:8] = ANTIBLACK
    put = lambda name, i, x, y: blit(f, *cell_of(name, i), x, y)
    for i, (x, y) in enumerate([(84, 24), (116, 40)]):
        put("bugs_small.png", i, x, y)
    put("bugs.png", 0, 124, 18)   # wasp
    put("bugs.png", 2, 112, 64)   # beetle
    f[8:36, 104] = STAR_DIM       # spider thread (draw.star_dim)
    put("bugs.png", 4, 96, 36)    # spider
    put("bugs.png", 6, 136, 86)   # moth
    put("ship.png", 0, 16, 52)
    put("thruster.png", 0, 10, 60)
    for x in (52, 76):
        put("bolt.png", 0, x, 60)
    for x in (44, 68):            # assert beam segments, the row above
        put("bolt.png", 2, x, 50)
    put("bolt.png", 4, 58, 70)    # bisect seeker
    for cx, cy in [(100, 76), (92, 82), (108, 70), (72, 40), (64, 92)]:
        put("bugs_small.png", 2 + (cx // 4) % 2, cx - 4, cy - 4)
    for cx, cy in [(120, 90), (104, 94), (88, 98), (60, 30)]:
        put("bugs.png", 8, cx - 8, cy - 8)  # needle: center - (8, 8)
    put("pickups.png", 0, 140, 58)  # crates (M6): fuzzer, fork, retry
    put("pickups.png", 3, 142, 36)
    put("pickups.png", 4, 40, 84)
    put("hud.png", 1, 26, 46)     # retry shield over the ship (x + 10, y - 6)
    put("fx_small.png", 2, 126, 100)
    put("fx_big.png", 2, 40, 12)
    f[1:7, 68:100] = ANTIWHITE      # fuel bar frame (drawn in code)
    f[2:6, 69:89] = CORAL
    for i in range(3):
        put("hud.png", 0, 160 - 12 * (i + 1), 0)
    return f


def write_contact(path: Path) -> None:
    from PIL import ImageDraw, ImageFont
    k = CONTACT_SCALE
    items = []
    for name, s in MANIFEST.items():
        if not (OUT / name).exists():
            continue
        a, m = load_gen(name)
        img = checker(a.shape[0] * k, a.shape[1] * k)
        big = a.repeat(k, 0).repeat(k, 1)
        bm = m.repeat(k, 0).repeat(k, 1)
        img[bm] = big[bm]
        # thin cell dividers so frame boundaries are visible
        for i in range(1, s.frames):
            img[:, i * s.cell_w * k] = CONTACT_BG
        items.append((f"{name}  {s.frames} x {s.cell_w}x{s.cell_h} cells, shown {k}x", img))
    mk = mockup()
    items.append(("mockup 160x128", mk.repeat(k, 0).repeat(k, 1)))
    pad, label_h = 12, 20
    width = max(i.shape[1] for _, i in items) + 2 * pad
    height = sum(i.shape[0] + label_h + pad for _, i in items) + pad
    out = np.zeros((height, width, 3), np.uint8)
    out[:] = CONTACT_BG
    y = pad
    labels = []
    for label, img in items:
        labels.append((y, label))
        y += label_h
        out[y : y + img.shape[0], pad : pad + img.shape[1]] = img
        y += img.shape[0] + pad
    im = Image.fromarray(out, "RGB")
    d = ImageDraw.Draw(im)
    font = ImageFont.load_default(size=14)
    for ly, label in labels:
        d.text((pad, ly), label, fill=CONTACT_INK, font=font)
    path.parent.mkdir(parents=True, exist_ok=True)
    im.save(path, optimize=True)
    print(f"contact sheet {path} {width}x{height}")


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
    g = ap.add_mutually_exclusive_group()
    g.add_argument("--placeholders", action="store_true", help="draw placeholder art into assets/gen/")
    g.add_argument("--study", type=Path, help="import a delivered Bugs_Study_NN folder")
    ap.add_argument("--snap", type=Path, help="GIMP .gpl palette to snap study colors to")
    ap.add_argument("--contact", type=Path, metavar="PNG",
                    help="afterwards (or alone) write a 4x labelled contact sheet of assets/gen, "
                         "e.g. docs/placeholders.png")
    args = ap.parse_args()
    if not (args.placeholders or args.study or args.contact):
        ap.error("one of --placeholders, --study or --contact is required")
    OUT.mkdir(parents=True, exist_ok=True)
    status = 0
    if args.placeholders:
        status = run_placeholders()
    elif args.study:
        status = run_study(args.study, args.snap)
    if args.contact:
        write_contact(args.contact)
    return status

if __name__ == "__main__":
    sys.exit(main())
