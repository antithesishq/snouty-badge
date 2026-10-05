#!/usr/bin/env python3
"""Prepare the build inputs in assets/gen/ for Snoutenstein 3D.

Two modes:

  python3 tools/prepare_assets.py --placeholders [--contact docs/placeholders.png]
      Procedurally draws every sheet of SPEC.md section 14 (except
      iris_16.png) as readable Genesis-style stand-in art, straight into
      assets/gen/, at the exact manifest sizes.

  python3 tools/prepare_assets.py --study assets/Snoutenstein_Study_NN [--snap FILE.gpl] [--hard-alpha]
      Takes a delivered art study (ASSETS.md section 8 layout:
      <study>/sheets/<name>.png RGBA strips, <study>/assets.json metadata),
      checks it, optionally snaps colours to a GIMP palette, flattens
      alpha 0 to the #FF00FF key and writes assets/gen/<name>.png. Sheets
      missing from the study keep their current assets/gen version.

Either mode (or neither) can add `--contact PNG`: every sheet in assets/gen
at 3x on a checkerboard with labels, each wall texture tiled 2x2, and two
160x128 mockups rendered by a small Python raycaster over the test level
(a rough preview of how the textures read at badge scale; the cart's own
renderer is authoritative).

Every sheet written is validated against the manifest below and the
converter's limits (cart/build/convert_gfx.zig builds one palette per PNG
from the RGB565-quantised pixels; transparent sheets reserve index 0 for
#FF00FF): exact size, cell grid, <= 15 opaque colours plus the key for
transparent sheets and <= 16 for the opaque walls/doors, no stray key
colour, a 1 px empty border in every sprite cell (with the documented
exceptions: the spider's thread touches the top edge, weapons touch the
bottom edge), no empty cells, and wall textures that tile in x and y.
Exit status is non-zero on any violation; a failing sheet is not written.

`iris_16.png` is copied from snouty-badge and is never touched here.
"""
from __future__ import annotations

import argparse
import json
import math
import sys
from dataclasses import dataclass
from pathlib import Path

import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "assets" / "gen"
KEY = (255, 0, 255)  # convert_gfx puts this first (index 0) in transparent sheets


# --------------------------------------------------------------------------
# Manifest: SPEC.md section 14, build.zig `images`, ASSETS.md section 7.
# --------------------------------------------------------------------------
@dataclass(frozen=True)
class Sheet:
    name: str
    cell_w: int
    cell_h: int
    frames: int
    transparent: bool
    tile: bool = False  # every cell must tile seamlessly in x and y
    edge_ok: str = ""  # cell edges the drawing may touch: "t" top, "b" bottom
    edge_cols: tuple[int, int] | None = None  # if set, only these columns may touch

    @property
    def width(self) -> int:
        return self.cell_w * self.frames

    @property
    def height(self) -> int:
        return self.cell_h

    @property
    def max_colors(self) -> int:
        # 4-bit palette: 16 entries, one of them the key when transparent.
        return 15 if self.transparent else 16


SPIDER_THREAD_X = 15  # the one column of bug_spider.png allowed to touch the top edge

MANIFEST: dict[str, Sheet] = {
    s.name: s
    for s in [
        Sheet("walls.png", 32, 32, 8, False, tile=True),
        Sheet("doors.png", 32, 32, 5, False),
        Sheet("bug_gnat.png", 32, 32, 7, True),
        Sheet("bug_wasp.png", 32, 32, 7, True),
        Sheet("bug_beetle.png", 32, 32, 7, True),
        Sheet("bug_spider.png", 32, 32, 7, True, edge_ok="t",
              edge_cols=(SPIDER_THREAD_X, SPIDER_THREAD_X)),
        Sheet("bug_boss.png", 32, 32, 8, True),
        Sheet("rival.png", 32, 32, 5, True),
        Sheet("pickups.png", 16, 16, 8, True),
        Sheet("projectiles.png", 8, 8, 6, True),
        Sheet("weapons.png", 48, 32, 12, True, edge_ok="b"),
        Sheet("face.png", 24, 24, 9, True),
        Sheet("hud.png", 8, 8, 9, True),
        Sheet("title.png", 128, 40, 1, True),
    ]
}
NEVER_TOUCH = {"iris_16.png"}

# Frame names per sheet (ASSETS.md section 7); also used for contact labels.
BUG_FRAMES = ["walk 0", "walk 1", "attack", "pain", "death 0", "death 1", "death 2"]
FRAME_NAMES = {
    "walls.png": ["server rack", "cable tray", "brick", "vent", "Iris mural",
                  "monitor wall", "pipes", "exit sign"],
    "doors.png": ["plain", "Coral lock", "Iris lock", "Gold lock", "exit elevator"],
    "bug_gnat.png": BUG_FRAMES,
    "bug_wasp.png": BUG_FRAMES,
    "bug_beetle.png": BUG_FRAMES,
    "bug_spider.png": BUG_FRAMES,
    "bug_boss.png": BUG_FRAMES + ["flicker"],
    "rival.png": ["front", "right side", "back", "left side", "down"],
    "pickups.png": ["Coral key", "Iris key", "Gold key", "hotfix", "zapper charge",
                    "spray can", "rewind battery", "Debugger cartridge"],
    "projectiles.png": ["spit 0", "spit 1", "web 0", "web 1", "debug bolt", "debug burst"],
    "weapons.png": ["swatter idle", "swing 0", "swing 1", "zapper idle", "fire 0", "fire 1",
                    "spray idle", "fire 0", "fire 1", "debugger idle", "fire 0", "fire 1"],
    "face.png": ["healthy", "hurt", "critical", "ouch", "grin", "glance L", "glance R",
                 "rewind", "dead"],
    "hud.png": ["Coral key", "Iris key", "Gold key", "charge", "spray", "clock", "<<", "heart", "debugger"],
    "title.png": ["logo"],
}


# --------------------------------------------------------------------------
# Palette (ASSETS.md section 3): Run Study 05 master, brand, additions.
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
# Additions (ASSETS.md section 3): server room and bug families.
STEEL = hx("6d6a86")  # the mid grey the master palette lacks (metal faces)
TEAL = hx("3fb8af")  # LEDs, screens, zapper
GOLD = hx("e6c229")  # Gold key and lock, wasp yellow
GREEN = hx("3c8a2e")
LIGHTGREEN = hx("8fd14f")
DKGREEN = hx("24552a")

# One character per colour for the ASCII/char-canvas drawings. Every sheet
# uses a subset; validate() counts what is actually used.
CHARS = {
    "o": OUTLINE, "d": DARK, "m": MIDDARK, "s": STEEL, "g": GREY, "c": CREAM,
    "1": PURPLE1, "2": PURPLE2, "3": PURPLE3, "4": PURPLE4,
    "r": RED, "R": DARKRED, "b": BROWN1, "B": BROWN2, "t": TAN, "L": LIGHTTAN,
    "C": CORAL, "T": TEAL, "y": GOLD, "G": GREEN, "l": LIGHTGREEN, "D": DKGREEN,
    "w": ANTIWHITE, "k": ANTIBLACK,
}


# --------------------------------------------------------------------------
# Char-canvas drawing helpers. A canvas is an (h, w) array of one-character
# strings; "." is transparent (or "not yet painted" for opaque sheets).
# --------------------------------------------------------------------------
def canvas(w: int, h: int, fill: str = ".") -> np.ndarray:
    return np.full((h, w), fill, "<U1")


def coords(w: int, h: int) -> tuple[np.ndarray, np.ndarray]:
    ys, xs = np.mgrid[0:h, 0:w]
    return xs.astype(float), ys.astype(float)


def ellipse(w: int, h: int, cx: float, cy: float, rx: float, ry: float) -> np.ndarray:
    xs, ys = coords(w, h)
    return ((xs - cx) / rx) ** 2 + ((ys - cy) / ry) ** 2 <= 1.0


def seg_mask(w: int, h: int, pts, r: float) -> np.ndarray:
    """Pixels within r of the polyline through pts (pixel centres at integers)."""
    xs, ys = coords(w, h)
    m = np.zeros((h, w), bool)
    for (ax, ay), (bx, by) in zip(pts, pts[1:]):
        dx, dy = bx - ax, by - ay
        l2 = dx * dx + dy * dy or 1e-9
        t = np.clip(((xs - ax) * dx + (ys - ay) * dy) / l2, 0.0, 1.0)
        m |= np.hypot(xs - ax - t * dx, ys - ay - t * dy) <= r
    return m


def poly_mask(w: int, h: int, pts) -> np.ndarray:
    """Even-odd fill of a polygon, sampled at pixel centres."""
    xs, ys = coords(w, h)
    m = np.zeros((h, w), bool)
    n = len(pts)
    for i in range(n):
        (x0, y0), (x1, y1) = pts[i], pts[(i + 1) % n]
        if y0 == y1:
            continue
        cond = (ys >= min(y0, y1)) & (ys < max(y0, y1))
        xi = x0 + (ys - y0) * (x1 - x0) / (y1 - y0)
        m ^= cond & (xs < xi)
    return m


def dilate4(m: np.ndarray) -> np.ndarray:
    d = m.copy()
    d[1:] |= m[:-1]
    d[:-1] |= m[1:]
    d[:, 1:] |= m[:, :-1]
    d[:, :-1] |= m[:, 1:]
    return d


def layer(c: np.ndarray, mask: np.ndarray, fill, outline: str | None = "o") -> None:
    """Outline ring (outside the mask) then fill; `fill` is a char or char array."""
    if outline:
        c[dilate4(mask) & ~mask] = outline
    c[mask] = fill[mask] if isinstance(fill, np.ndarray) else fill


def shade(mask: np.ndarray, lit: str, mid: str, dark: str, cx: float, cy: float,
          rx: float, ry: float, hi: float = -0.35, lo: float = 0.35) -> np.ndarray:
    """Three-band fill lit from the upper left: value = (u + v) of the ellipse
    coordinates; below `hi` lit, above `lo` dark."""
    h, w = mask.shape
    xs, ys = coords(w, h)
    v = (xs - cx) / rx * 0.6 + (ys - cy) / ry * 0.8
    out = np.full(mask.shape, mid, "<U1")
    out[v < hi] = lit
    out[v > lo] = dark
    return out


def plot(c: np.ndarray, pts, ch: str) -> None:
    h, w = c.shape
    for x, y in pts:
        x, y = int(round(x)), int(round(y))
        if 0 <= x < w and 0 <= y < h:
            c[y, x] = ch


def rect(c: np.ndarray, x0: int, y0: int, x1: int, y1: int, ch: str) -> None:
    """Fill the inclusive rectangle."""
    c[y0 : y1 + 1, x0 : x1 + 1] = ch


def stamp(c: np.ndarray, rows: list[str], x0: int, y0: int) -> None:
    """ASCII art onto a canvas; '.' leaves the canvas untouched."""
    for y, row in enumerate(rows):
        for x, ch in enumerate(row):
            if ch != "." and 0 <= y0 + y < c.shape[0] and 0 <= x0 + x < c.shape[1]:
                c[y0 + y, x0 + x] = ch


def mirror_x(c: np.ndarray) -> np.ndarray:
    return c[:, ::-1].copy()


def outline_all(c: np.ndarray, oc: str = "o") -> None:
    """1 px outline around every painted pixel (4-neighbourhood)."""
    m = c != "."
    c[dilate4(m) & ~m] = oc


def clear_border(c: np.ndarray, keep_top_cols: tuple[int, int] | None = None,
                 keep_bottom: bool = False) -> None:
    top = c[0].copy()
    c[0] = "."
    if keep_top_cols:
        a, b = keep_top_cols
        c[0, a : b + 1] = top[a : b + 1]
    if not keep_bottom:
        c[-1] = "."
    c[:, 0] = "."
    c[:, -1] = "."


def to_rgb(c: np.ndarray, transparent: bool) -> np.ndarray:
    h, w = c.shape
    a = np.zeros((h, w, 3), np.uint8)
    a[:, :] = KEY
    for ch in np.unique(c):
        if ch == ".":
            if not transparent:
                raise ValueError("unpainted pixel in an opaque sheet")
            continue
        a[c == ch] = CHARS[ch]
    return a


def strip(cells: list[np.ndarray]) -> np.ndarray:
    return np.concatenate(cells, axis=1)


# 5x7 / 4x7 / 3x5 bitmap glyphs used by the title, the exit sign and icons.
FONT = {
    # 4x7 condensed (title line 1)
    "S4": [".###", "#...", "#...", ".##.", "...#", "...#", "###."],
    "N4": ["#..#", "##.#", "##.#", "#.##", "#.##", "#..#", "#..#"],
    "O4": [".##.", "#..#", "#..#", "#..#", "#..#", "#..#", ".##."],
    "U4": ["#..#", "#..#", "#..#", "#..#", "#..#", "#..#", ".##."],
    "T4": ["####", ".##.", ".##.", ".##.", ".##.", ".##.", ".##."],
    "E4": ["####", "#...", "#...", "###.", "#...", "#...", "####"],
    "I4": ["####", ".##.", ".##.", ".##.", ".##.", ".##.", "####"],
    # 5x7 (title "3D")
    "3": ["####.", "....#", "....#", ".###.", "....#", "....#", "####."],
    "D": ["####.", "#...#", "#...#", "#...#", "#...#", "#...#", "####."],
    # 3x5 (exit sign)
    "E3": ["###", "#..", "##.", "#..", "###"],
    "X3": ["#.#", "#.#", ".#.", "#.#", "#.#"],
    "I3": ["###", ".#.", ".#.", ".#.", "###"],
    "T3": ["###", ".#.", ".#.", ".#.", ".#."],
}

# The Antithesis Iris mark (snouty-badge/assets/logo), box-downsampled to
# 22x22 and made 180-degree symmetric in code. '#' = mark.
IRIS22 = [
    "........######........",
    ".....#########........",
    "....##########........",
    "...###########........",
    "..##..................",
    ".###..................",
    ".###..................",
    ".###......##..........",
    "####.....####.....####",
    "####....######....####",
    "####...########...####",
    "####...########...####",
    "####....######....####",
    "####.....####.....####",
    "..........##......###.",
    "..................###.",
    "..................###.",
    "..................##..",
    "........###########...",
    "........##########....",
    "........#########.....",
    "........######........",
]


def iris_mask(n: int = 22) -> np.ndarray:
    m = np.array([[ch == "#" for ch in r] for r in IRIS22])
    m |= m[::-1, ::-1]
    if n != 22:
        im = Image.fromarray((m * 255).astype(np.uint8)).resize((n, n), Image.BOX)
        m = np.array(im) > 110
        m |= m[::-1, ::-1]
    return m


# --------------------------------------------------------------------------
# walls.png: 8 opaque 32x32 textures, one shared 16-colour palette. Light
# comes from the upper left in every texture (lit top/left edges, dark
# bottom/right), drawn into the pixels: the renderer's lit/dark palette
# sets only distinguish wall orientation. Every texture is periodic with
# period 32 in x and y (verified by validate()).
# --------------------------------------------------------------------------
WALL_CHARS = "odmsgc1234RrbBtT"  # 16: the walls.png palette (ASSETS.md section 3)


def wall_rack() -> np.ndarray:
    """Server rack: side rails with screw holes, four 8-row units (drive
    bays, a switch, a vented server with a purple power LED, bays again)."""
    c = canvas(32, 32, "s")
    c[:, 0] = "o"
    c[:, 1] = "g"
    c[:, 2] = "s"
    c[:, 3] = "m"
    c[:, 28] = "m"
    c[:, 29] = "s"
    c[:, 30] = "m"
    c[:, 31] = "d"
    for y in (3, 11, 19, 27):
        c[y, 1:3] = "o"
        c[y, 29:31] = "o"
    for u in range(4):
        y0 = u * 8
        face = "m" if u == 1 else "s"
        rect(c, 4, y0, 27, y0 + 6, face)
        c[y0, 4:28] = "g"
        c[y0 : y0 + 7, 4] = "g"
        c[y0 + 6, 4:28] = "d"
        c[y0 : y0 + 7, 27] = "d"
        c[y0 + 7, 4:28] = "o"
        if u in (0, 3):  # drive bays with pull tabs, status LEDs
            for i, bx in enumerate(range(6, 22, 4)):
                rect(c, bx, y0 + 2, bx + 2, y0 + 4, "d")
                c[y0 + 2, bx : bx + 3] = "o"
                c[y0 + 4, bx + 1] = "g"
            c[y0 + 2, 24] = "T"
            c[y0 + 4, 24] = "r" if u == 0 else "T"
            c[y0 + 2, 25] = "o"
            c[y0 + 4, 25] = "o"
        elif u == 1:  # switch: LED row over a row of ports
            for i, px in enumerate(range(6, 25, 3)):
                c[y0 + 2, px] = "T" if i % 3 else "4"
                rect(c, px, y0 + 3, px + 1, y0 + 4, "o")
                c[y0 + 3, px] = "d"
        else:  # vented server with a power button
            for y in (y0 + 2, y0 + 4):
                for x in range(6, 20, 2):
                    c[y, x] = "d"
            rect(c, 22, y0 + 2, 24, y0 + 4, "o")
            c[y0 + 3, 23] = "4"
            c[y0 + 2, 23] = "3"
    return c


def wall_cables() -> np.ndarray:
    """Cable trays: dark wall, two trays of four wavy cables each behind a
    lit front rail, threaded hanger rods running floor to ceiling."""
    c = canvas(32, 32, "d")
    c[:, 31] = "o"  # panel seam
    c[:, 0] = "m"
    for rx in (6, 25):
        c[:, rx] = "s"
        c[:, rx + 1] = "o"
    cables = [("4", "2"), ("r", "R"), ("t", "B"), ("T", "s")]
    for ti, ty in enumerate((3, 19)):
        order = cables if ti == 0 else cables[2:] + cables[:2]
        for k, (hi, lo) in enumerate(order):
            for x in range(32):
                wave = 0.9 * math.sin(2 * math.pi * (x + 7 * k + 11 * ti) / 32 * (1 + k % 2))
                y = int(round(ty + k * 1.4 + wave))
                c[y, x] = hi
                c[y + 1, x] = lo
                c[y + 2, x] = "o" if k == len(order) - 1 else c[y + 2, x]
        # front rail: lit lip, face, dark underside, shadow on the wall
        c[ty + 6, :] = "g"
        c[ty + 7, :] = "s"
        c[ty + 8, :] = "m"
        c[ty + 9, :] = "o"
        for rx in (6, 25):  # hanger brackets over the rail
            rect(c, rx - 1, ty + 6, rx + 1, ty + 8, "m")
            c[ty + 6, rx - 1 : rx + 2] = "s"
            c[ty + 7, rx] = "o"
    return c


def wall_brick() -> np.ndarray:
    """Brick: 15x7 bricks in running bond, dark red and brown2 varieties,
    each with a lit top/left edge, a dark bottom/right edge, mortar between."""
    c = canvas(32, 32, "m")
    rng = np.random.default_rng(3)
    for course in range(4):
        y0 = course * 8
        off = 0 if course % 2 == 0 else 8
        for b in range(2):
            x0 = off + b * 16
            brown = (course * 2 + b) % 3 == 1
            base, hi, lo = ("B", "t", "b") if brown else ("R", "r", "b")
            for dy in range(7):
                for dx in range(15):
                    x = (x0 + dx) % 32
                    ch = base
                    if dy == 0 or dx == 0:
                        ch = hi
                    if dy == 6 or dx == 14:
                        ch = lo
                    c[y0 + dy, x] = ch
            for _ in range(3):  # pits and chips
                x = (x0 + int(rng.integers(2, 13))) % 32
                y = y0 + int(rng.integers(2, 5))
                c[y, x] = lo
            c[y0 + 7, [(x0 + dx) % 32 for dx in range(15)]] = "d"  # mortar shadow row
    return c


def wall_vent() -> np.ndarray:
    """Vent panel: bevelled steel frame, corner screws, a recessed louvred
    grille (the recess is dark at the top/left, lit at the bottom/right)."""
    c = canvas(32, 32, "s")
    c[0, :] = "g"
    c[:, 0] = "g"
    c[31, :] = "o"
    c[:, 31] = "o"
    c[30, 1:31] = "m"
    c[1:31, 30] = "m"
    for x, y in ((3, 3), (27, 3), (3, 27), (27, 27)):
        c[y, x] = "g"
        c[y, x + 1] = "m"
        c[y + 1, x] = "m"
        c[y + 1, x + 1] = "o"
    rect(c, 5, 5, 26, 26, "d")
    c[5, 5:27] = "o"
    c[5:27, 5] = "o"
    c[26, 5:27] = "g"
    c[5:27, 26] = "g"
    for y in range(7, 25, 4):
        c[y, 6:26] = "g"
        c[y + 1, 6:26] = "s"
        c[y + 2, 6:26] = "m"
    return c


def wall_mural() -> np.ndarray:
    """Iris mural: purple bevelled tiles with the Antithesis Iris mark in
    cream, dark drop shadow down-right, purple-4 lower edges."""
    c = canvas(32, 32, "2")
    for t in range(0, 32, 8):
        c[t, :] = "3"
        c[:, t] = "3"
        c[t + 7, :] = "1"
        c[:, t + 7] = "1"
    m = np.zeros((32, 32), bool)
    m[5:27, 5:27] = iris_mask(22)
    sh = np.zeros_like(m)
    sh[1:, 1:] = m[:-1, :-1]
    c[sh & ~m] = "o"
    c[m] = "c"
    below = np.zeros_like(m)
    below[:-1] = m[1:]
    right = np.zeros_like(m)
    right[:, :-1] = m[:, 1:]
    c[m & (~below | ~right)] = "4"
    return c


def wall_monitors() -> np.ndarray:
    """Monitor wall: 2x2 monitors with bevelled bezels: a log, a graph, a
    red failure, an Iris progress screen."""
    c = canvas(32, 32, "m")
    for mi, (mx, my) in enumerate(((0, 0), (16, 0), (0, 16), (16, 16))):
        c[my, mx : mx + 16] = "s"
        c[my : my + 16, mx] = "s"
        c[my + 15, mx : mx + 16] = "o"
        c[my : my + 16, mx + 15] = "o"
        rect(c, mx + 2, my + 2, mx + 13, my + 11, "d")
        c[my + 2, mx + 2 : mx + 14] = "o"
        c[my + 2 : my + 12, mx + 2] = "o"
        c[my + 12, mx + 2 : mx + 14] = "g"
        c[my + 13, mx + 7 : mx + 9] = "4"
        c[my + 13, mx + 12] = "r" if mi == 2 else "T"
        sx, sy = mx + 3, my + 3
        if mi == 0:  # log lines
            for i, n in enumerate((7, 9, 4, 8)):
                c[sy + 1 + 2 * i, sx + 1 : sx + 1 + n] = "T"
                c[sy + 1 + 2 * i, sx + 1] = "c" if i == 3 else "T"
        elif mi == 1:  # graph
            ys = [7, 6, 6, 4, 5, 3, 4, 2, 3, 1]
            c[sy + 8, sx : sx + 10] = "m"
            for i, v in enumerate(ys):
                c[sy + v, sx + i] = "T"
                c[sy + v + 1 : sy + 8, sx + i] = "s" if i % 2 else "m"
        elif mi == 2:  # red failure cross
            for i in range(8):
                c[sy + 1 + i, sx + 1 + i] = "r"
                c[sy + 1 + i, sx + 8 - i] = "r"
            c[sy + 1, sx + 1] = "c"
        else:  # Iris diamond and a progress bar
            for dy in range(-3, 4):
                for dx in range(-3, 4):
                    d = abs(dx) + abs(dy)
                    if d <= 3:
                        c[sy + 4 + dy, sx + 5 + dx] = "4" if d <= 1 else "3"
            c[sy + 8, sx : sx + 10] = "m"
            c[sy + 8, sx : sx + 6] = "T"
    return c


def wall_pipes() -> np.ndarray:
    """Pipes: copper, steel and red sprinkler pipes running floor to
    ceiling, cylindrical shading (highlight left of centre), flanges and a
    clamp; horizontal panel seams on the wall behind."""
    c = canvas(32, 32, "d")
    c[15, :] = "m"
    c[31, :] = "o"
    c[16, :] = "o"

    def pipe(x0: int, cols: str) -> None:
        for i, ch in enumerate(cols):
            c[:, x0 + i] = ch

    pipe(2, "otcttBbo")  # copper
    pipe(12, "ogsmo")  # steel
    pipe(20, "orcrrrRRo")  # red

    def flange(x0: int, x1: int, y: int) -> None:
        c[y, x0 : x1 + 1] = "g"
        c[y + 1, x0 : x1 + 1] = "s"
        c[y + 2, x0 : x1 + 1] = "m"
        c[y + 3, x0 : x1 + 1] = "o"
        c[y : y + 3, x0] = "o"
        c[y : y + 3, x1] = "o"
        c[y + 1, x0 + 2] = "o"
        c[y + 1, x1 - 2] = "o"

    flange(1, 10, 5)
    flange(19, 29, 21)
    c[10, 11:18] = "g"  # clamp on the steel pipe, bracket to the wall
    c[11, 11:18] = "m"
    c[12, 11:18] = "o"
    c[10:12, 18] = "s"
    return c


def wall_exit() -> np.ndarray:
    """Exit sign strip: dark steel wall with a lit cream EXIT sign (red
    letters and arrow, drop shadow) and a red/black hazard band below."""
    c = canvas(32, 32, "m")
    c[0, :] = "s"
    c[31, :] = "o"
    for x in range(0, 32, 8):
        c[1:31, x] = "d"
        c[1:31, x + 1] = "s"
    rect(c, 4, 3, 26, 15, "o")
    rect(c, 5, 4, 25, 14, "c")
    c[14, 5:26] = "g"
    c[4:15, 25] = "g"
    c[16, 5:28] = "o"  # drop shadow
    c[4:17, 27] = "o"
    x = 8
    for g in ("E3", "X3", "I3", "T3"):
        stamp(c, [r.replace("#", "r") for r in FONT[g]], x, 5)
        x += 4
    c[12, 11:19] = "r"  # arrow
    c[11, 18] = "r"
    c[13, 18] = "r"
    c[10, 17] = "r"
    c[14, 17] = "r"
    c[22, :] = "g"
    for y in range(23, 28):
        for x in range(32):
            c[y, x] = "r" if (x + y) % 8 < 4 else "o"
    c[28, :] = "d"
    return c


WALL_DRAW = [wall_rack, wall_cables, wall_brick, wall_vent, wall_mural,
             wall_monitors, wall_pipes, wall_exit]


def draw_walls() -> np.ndarray:
    return strip([to_rgb(f(), False) for f in WALL_DRAW])


# --------------------------------------------------------------------------
# doors.png: 5 opaque 32x32 sliding door panels. Steel with ribbed upper
# and lower panels, a horizontal stripe and a big lock plate in the key
# colour (plain: steel); the exit is a two-leaf elevator door.
# --------------------------------------------------------------------------
DOOR_KEY = {  # lit, face, dark
    "plain": ("g", "s", "m"),
    "coral": ("c", "C", "R"),
    "iris": ("4", "3", "1"),
    "gold": ("c", "y", "B"),
}


def door_frame(face: str = "s") -> np.ndarray:
    c = canvas(32, 32, face)
    c[0, :] = "g"
    c[:, 0] = "g"
    c[31, :] = "o"
    c[:, 31] = "o"
    c[30, 1:31] = "m"
    c[1:31, 30] = "m"
    return c


def door_locked(kind: str) -> np.ndarray:
    c = door_frame()
    for y in (3, 6, 9, 21, 24, 27):
        c[y, 3:28] = "g"
        c[y + 1, 3:28] = "m"
    hi, face, lo = DOOR_KEY[kind]
    # stripe across the door, readable from far away
    c[13, 1:30] = "o" if kind != "plain" else "m"
    c[14, 1:30] = hi
    c[15:17, 1:30] = face
    c[17, 1:30] = lo
    c[18, 1:30] = "o" if kind != "plain" else "m"
    # lock plate
    x0, y0, x1, y1 = 18, 9, 27, 22
    rect(c, x0, y0, x1, y1, "o")
    rect(c, x0 + 1, y0 + 1, x1 - 1, y1 - 1, face)
    c[y0 + 1, x0 + 1 : x1] = hi
    c[y0 + 1 : y1, x0 + 1] = hi
    c[y1 - 1, x0 + 2 : x1] = lo
    c[y0 + 2 : y1, x1 - 1] = lo
    # keyhole (plain: a recessed pull handle instead)
    if kind == "plain":
        rect(c, x0 + 3, y0 + 3, x0 + 5, y1 - 3, "d")
        c[y0 + 3 : y1 - 2, x0 + 3] = "o"
    else:
        rect(c, x0 + 4, y0 + 4, x0 + 5, y0 + 6, "o")
        rect(c, x0 + 4, y0 + 7, x0 + 5, y0 + 9, "d")
        c[y0 + 8, x0 + 4 : x0 + 6] = "o"
        c[y0 + 4 : y0 + 10, x0 + 6] = lo
    c[y0 + 2, x1 + 1] = "o"  # plate shadow on the door
    c[y0 + 2 : y1 + 2, x1 + 1] = "o"
    c[y1 + 1, x0 + 1 : x1 + 2] = "o"
    return c


def door_exit() -> np.ndarray:
    c = door_frame()
    for x in range(2, 30):
        if (x * 7) % 5 == 0:
            c[8:29, x] = "g" if x < 15 else "m"
    c[1:31, 15] = "o"
    c[1:31, 16] = "g"
    rect(c, 9, 2, 22, 7, "o")
    rect(c, 10, 3, 21, 6, "d")
    for i, y in enumerate(range(3, 7)):  # up arrow, teal = go
        c[y, 13 - i : 14 + i] = "T"
        c[y, 18 - i : 19 + i] = "T"
    c[3, 20] = "r"
    c[17, 1:30] = "T"  # teal light strip across both leaves
    c[18, 1:30] = "o"
    c[16, 1:30] = "m"
    rect(c, 12, 22, 13, 26, "m")  # finger pulls
    rect(c, 18, 22, 19, 26, "m")
    c[22:27, 12] = "o"
    c[22:27, 18] = "o"
    return c


def draw_doors() -> np.ndarray:
    cells = [door_locked(k) for k in ("plain", "coral", "iris", "gold")] + [door_exit()]
    return strip([to_rgb(c, False) for c in cells])


# --------------------------------------------------------------------------
# Bug sheets: 32x32 cells, always seen from the front (they face the
# camera), frames walk 0, walk 1, attack, pain, death 0..2 (boss adds a
# flicker frame). The cell spans floor (bottom row) to ceiling (top row),
# like a wall slice: walkers stand on row 30, flyers hover, the spider
# hangs from a thread that touches the top edge at x SPIDER_THREAD_X.
# Death 1 and 2 are derived from death 0 (flipped onto its back, then
# flattened) so the three read as one fall.
# --------------------------------------------------------------------------
N = 32


def ellipse_rot(cx: float, cy: float, rx: float, ry: float, deg: float, n: int = N) -> np.ndarray:
    xs, ys = coords(n, n)
    a = math.radians(deg)
    u = (xs - cx) * math.cos(a) + (ys - cy) * math.sin(a)
    v = -(xs - cx) * math.sin(a) + (ys - cy) * math.cos(a)
    return (u / rx) ** 2 + (v / ry) ** 2 <= 1.0


def bbox_rows(c: np.ndarray) -> tuple[int, int]:
    rows = np.nonzero((c != ".").any(axis=1))[0]
    return int(rows[0]), int(rows[-1])


def shift(c: np.ndarray, dx: int, dy: int) -> np.ndarray:
    out = canvas(c.shape[1], c.shape[0])
    h, w = c.shape
    ys, xs = np.nonzero(c != ".")
    ny, nx = ys + dy, xs + dx
    ok = (ny >= 0) & (ny < h) & (nx >= 0) & (nx < w)
    out[ny[ok], nx[ok]] = c[ys[ok], xs[ok]]
    return out


def anchor_bottom(c: np.ndarray, bottom: int = 30) -> np.ndarray:
    return shift(c, 0, bottom - bbox_rows(c)[1])


def on_back(c: np.ndarray, bottom: int = 30) -> np.ndarray:
    """Death 1: the same bug upside down on the floor."""
    return anchor_bottom(c[::-1].copy(), bottom)


def flatten_bug(c: np.ndarray, f: float = 0.45, bottom: int = 30) -> np.ndarray:
    """Death 2: squash vertically toward the floor (nearest-row sampling),
    then re-outline so the squashed shape keeps a clean edge."""
    top, bot = bbox_rows(c)
    h = bot - top + 1
    nh = max(4, int(round(h * f)))
    out = canvas(c.shape[1], c.shape[0])
    for i in range(nh):
        src = top + min(h - 1, int((i + 0.5) * h / nh))
        out[bottom - nh + 1 + i] = c[src]
    m = out != "."
    out[dilate4(m) & ~m & (np.arange(N)[:, None] <= bottom)] = "o"
    return out


def finish(c: np.ndarray, thread: bool = False) -> np.ndarray:
    clear_border(c, keep_top_cols=(SPIDER_THREAD_X, SPIDER_THREAD_X) if thread else None)
    return c


def eyes_x(c: np.ndarray, centres, ch: str = "o") -> None:
    for x, y in centres:
        plot(c, [(x - 1, y - 1), (x + 1, y - 1), (x, y), (x - 1, y + 1), (x + 1, y + 1)], ch)


def eyes_shut(c: np.ndarray, centres, w: int = 1) -> None:
    for x, y in centres:
        plot(c, [(x + dx, y) for dx in range(-w, w + 1)], "o")


def bug_frames(draw, thread: bool = False, fly: bool = False) -> list[np.ndarray]:
    walk0 = draw(phase=0)
    walk1 = draw(phase=1)
    attack = draw(phase=0, attack=True)
    pain = draw(phase=1, pain=True)
    dead = draw(phase=0, dead=True)
    if thread:
        dead_body = dead.copy()
        dead_body[:, SPIDER_THREAD_X][dead_body[:, SPIDER_THREAD_X] == "g"] = "."
        d1 = on_back(dead_body, bottom=24)
    else:
        dead_body = dead
        d1 = on_back(dead, 30)
    d2 = flatten_bug(on_back(dead_body, 30), 0.4)
    frames = [walk0, walk1, attack, pain, dead, d1, d2]
    return [finish(f, thread=thread and i < 5) for i, f in enumerate(frames)]


# --- gnat (Off-by-one): small round green bug with big buzzing wings,
# hovering at about 60 % of the wall height. One antenna is one pixel too
# long.
def gnat(phase: int = 0, attack: bool = False, pain: bool = False, dead: bool = False) -> np.ndarray:
    c = canvas(N, N)
    cy = 15 + phase - (1 if pain else 0) + (3 if dead else 0)
    cx = 15.5
    # wings behind: up (phase 0) or down (phase 1); folded when hurt
    ang, wy = (-30, cy - 4) if phase == 0 else (25, cy + 1)
    if attack:
        ang, wy = (-10, cy - 2)
    if pain or dead:
        ang, wy = (40 if dead else -55, cy + (4 if dead else -3))
    for side in (-1, 1):
        wx = cx + side * 8.5
        wm = ellipse_rot(wx, wy, 6.0 if not pain else 4.5, 3.0, side * -ang)
        layer(c, wm, "c")
        vein = ellipse_rot(wx, wy, 4.5, 0.6, side * -ang) & wm
        c[vein] = "g"
    r = 6.5 if attack else 5.5
    ab = ellipse(N, N, cx, cy + 6.5, 3.6, 3.4)
    layer(c, ab, shade(ab, "l", "G", "D", cx, cy + 6.5, 3.6, 3.4))
    c[ab & (np.arange(N)[:, None] == int(cy + 7))] = "D"  # abdomen band
    hd = ellipse(N, N, cx, cy, r, r - 0.5)
    layer(c, hd, shade(hd, "l", "G", "D", cx, cy, r, r))
    # antennae: the right one is one pixel longer (off by one)
    plot(c, [(13, cy - r), (12, cy - r - 1), (11, cy - r - 2)], "o")
    plot(c, [(18, cy - r), (19, cy - r - 1), (20, cy - r - 2), (21, cy - r - 3)], "o")
    plot(c, [(11, cy - r - 3), (21, cy - r - 4)], "y")
    # legs dangling from the abdomen
    for lx, fx in ((13, 12), (15, 15), (18, 19)):
        plot(c, [(lx, cy + 10), (fx, cy + 11)], "o")
    eyes = [(13, int(cy - 1)), (18, int(cy - 1))]
    if dead:
        for x, y in eyes:
            rect(c, x - 1, y - 1, x + 1, y + 1, "c")
        eyes_x(c, eyes)
    elif pain:
        eyes_shut(c, eyes)
        plot(c, [(12, cy - 3), (14, cy - 2), (19, cy - 3), (17, cy - 2)], "o")
    else:
        for x, y in eyes:
            e = ellipse(N, N, x, y, 1.6, 2.1)
            c[e] = "c"
            px = x + (0 if attack else (1 if x < cx else 0))
            c[y : y + 2, px] = "o"
            if attack:
                plot(c, [(x - 1, y - 3), (x + 1, y - 2)] if x < cx else [(x + 1, y - 3), (x - 1, y - 2)], "o")
    my = int(cy + 3)
    if attack:
        rect(c, 14, my, 17, my + 1, "r")
        c[my, 14:18] = "c"
        c[my + 2, 14:18] = "o"
    elif pain:
        rect(c, 15, my, 16, my + 1, "R")
    else:
        plot(c, [(15, my), (16, my)], "o")
    return c


# --- wasp (Race Condition): yellow/black striped abdomen curled toward
# the camera, stinger pointing down (at the player in the charge frame),
# big dark-red compound eyes, wings in a raised V.
def wasp(phase: int = 0, attack: bool = False, pain: bool = False, dead: bool = False) -> np.ndarray:
    c = canvas(N, N)
    cx = 15.5
    dy = (1 if phase else 0) - (1 if pain else 0) + (3 if dead else 0)
    hy = 8 + dy
    ang = -40 if phase == 0 else -20
    wr = 7.5
    if attack:
        ang, wr = -8, 9.0
    if pain:
        ang, wr = -65, 6.0
    if dead:
        ang, wr = 25, 7.0
    for side in (-1, 1):
        wx = cx + side * 7.5
        wm = ellipse_rot(wx, hy + 2 - (2 if ang < -30 else 0), wr, 2.4, side * -ang)
        layer(c, wm, "c")
        c[ellipse_rot(wx, hy + 2 - (2 if ang < -30 else 0), wr - 1.5, 0.5, side * -ang) & wm] = "g"
    # abdomen (behind the thorax), banded, lit on the left
    ay, ary = (hy + 14, 5.0) if attack else (hy + 15, 6.2)
    ab = ellipse(N, N, cx, ay, 4.6, ary)
    band = np.where((np.arange(N)[:, None] - int(ay - ary)) % 4 < 2, "y", "o")
    band = np.broadcast_to(band, (N, N)).copy()
    xs, _ = coords(N, N)
    band[(band == "y") & (xs < cx - 2.5)] = "L"
    band[(band == "y") & (xs > cx + 2.5)] = "B"
    layer(c, ab, band)
    # stinger
    sy = int(ay + ary)
    if attack:  # pointed at the viewer: a lit diamond at the tip
        plot(c, [(15, sy - 1), (16, sy - 1), (14, sy), (17, sy), (15, sy + 1), (16, sy + 1)], "o")
        plot(c, [(15, sy), (16, sy)], "c")
    else:
        plot(c, [(15, sy + 1), (16, sy + 1), (15, sy + 2)], "o")
        plot(c, [(16, sy + 1)], "g")
    # thorax
    th = ellipse(N, N, cx, hy + 6.5, 4.0, 3.0)
    layer(c, th, "d")
    plot(c, [(14, hy + 6), (17, hy + 6)], "y")
    # legs
    for side in (-1, 1):
        pts = [(cx + side * 3.5, hy + 7), (cx + side * 7, hy + 10 + phase), (cx + side * 7, hy + 14 + phase)]
        c[seg_mask(N, N, pts, 0.5)] = "o"
    # head
    hd = ellipse(N, N, cx, hy, 5.0, 4.4)
    layer(c, hd, shade(hd, "L", "y", "B", cx, hy, 5, 4.4))
    eyes = [(12, hy), (19, hy)]
    for x, y in eyes:
        e = ellipse(N, N, x, y, 1.8, 3.0)
        c[e] = "R"
        if dead:
            eyes_x(c, [(x, y)], "c")
        elif pain:
            c[e] = "B"
            eyes_shut(c, [(x, y)])
        else:
            plot(c, [(x - 1 if x < cx else x, y - 1)], "r")
    if attack:  # angry brow
        plot(c, [(11, hy - 4), (12, hy - 3), (13, hy - 3), (20, hy - 4), (19, hy - 3), (18, hy - 3)], "o")
    # mandibles and antennae
    plot(c, [(14, hy + 4), (17, hy + 4)] + ([(13, hy + 5), (18, hy + 5)] if attack else []), "o")
    for side in (-1, 1):
        plot(c, [(cx + side * 2.5, hy - 4), (cx + side * 3.5, hy - 5), (cx + side * 4.5, hy - 6),
                 (cx + side * 5.5, hy - 6)], "o")
    return c


# --- beetle (Memory Leak): wide low green dome on the floor, dark head
# with red eyes and tan mandibles, three legs a side, leaking a purple
# drip of memory. Spits green globs (attack).
def beetle(phase: int = 0, attack: bool = False, pain: bool = False, dead: bool = False) -> np.ndarray:
    c = canvas(N, N)
    cx = 15.5
    dy = (1 if phase else 0) - (1 if attack else 0)
    # legs first (behind the shell), feet on row 30
    for side in (-1, 1):
        for k, (hx_, hy_, kx, ky, fx) in enumerate(((10, 20, 5, 19, 2), (10, 23, 5, 24, 3), (11, 25, 8, 27, 6))):
            swing = (1 if (k + phase) % 2 else 0) * side
            if dead:
                pts = [(cx + side * (cx - hx_), hy_ + dy), (cx + side * (cx - kx), ky - 3), (cx + side * (cx - kx - 2), ky - 5)]
            else:
                pts = [(cx + side * (cx - hx_), hy_ + dy), (cx + side * (cx - kx) + swing, ky + dy),
                       (cx + side * (cx - fx) + swing, 30)]
            layer(c, seg_mask(N, N, pts, 0.55), "b")
    sy = 21 + dy
    ry = 9.5 - (1.5 if pain else 0)
    sh = ellipse(N, N, cx, sy, 12.5, ry) & (np.arange(N)[:, None] <= sy + 3)
    fill = shade(sh, "l", "G", "D", cx - 3, sy - 4, 12.5, ry, hi=-0.55, lo=0.1)
    fill[sh & (np.abs(coords(N, N)[0] - cx) < 0.6)] = "D"  # elytra seam
    layer(c, sh, fill)
    c[sh & (np.arange(N)[:, None] == int(sy + 3))] = "t"  # belly rim under the shell
    hd = ellipse(N, N, cx, sy + 3, 5.5, 4.0)
    layer(c, hd, shade(hd, "G", "D", "o", cx, sy + 3, 5.5, 4, hi=-0.6, lo=0.5))
    eyes = [(13, int(sy + 2)), (18, int(sy + 2))]
    if dead:
        eyes_x(c, eyes, "r")
    elif pain:
        eyes_shut(c, eyes)
    else:
        for x, y in eyes:
            rect(c, x, y, x + 1, y + 1, "r")
            c[y, x] = "c"
    my = int(sy + 6)
    if attack:  # mandibles wide, a glob of spit
        plot(c, [(11, my - 1), (12, my), (20, my - 1), (19, my)], "t")
        g = ellipse(N, N, cx, my + 1.5, 2.2, 2.0)
        layer(c, g, "l")
        plot(c, [(15, my + 1)], "c")
    else:
        plot(c, [(13, my), (14, my + 1), (18, my), (17, my + 1)], "t")
        if not dead:
            plot(c, [(16, my + 1), (16, my + 2)], "3")  # the leak
            plot(c, [(16, my + 3)], "4")
    return c


# --- spider (Deadlock): hangs on a grey thread from the ceiling (top
# edge), round purple abdomen with a gold padlock mark, four red eyes,
# eight grey jointed legs.
def spider(phase: int = 0, attack: bool = False, pain: bool = False, dead: bool = False) -> np.ndarray:
    c = canvas(N, N)
    cx = 15.5
    by = 11 + phase + (2 if attack else 0) - (1 if pain else 0)
    legs = [  # hip dy, knee (dx, dy), foot (dx, dy) relative to (cx, by); left side
        (1, (-9, -5), (-12, 1)), (3, (-10, -1), (-13, 6)),
        (5, (-9, 4), (-12, 10)), (7, (-7, 8), (-9, 14)),
    ]
    for side in (-1, 1):
        for k, (hdy, (kx, ky), (fx, fy)) in enumerate(legs):
            tw = (1 if (k + phase) % 2 else 0)
            if attack and k == 0:
                ky, fy, fx = ky - 3, fy - 8, fx + 2
            if pain or dead:  # curled in
                kx, ky, fx, fy = kx * 0.55, ky * 0.6 - 2, kx * 0.25, ky * 0.3 + 2
            pts = [(cx + side * 3, by + hdy), (cx + side * abs(kx), by + ky - tw),
                   (cx + side * abs(fx), by + fy + tw)]
            c[seg_mask(N, N, pts, 0.5)] = "g"
    ab = ellipse(N, N, cx, by, 6.5, 6.0)
    layer(c, ab, shade(ab, "3", "2", "1", cx, by, 6.5, 6))
    # padlock on the abdomen
    stamp(c, ["..gg..", ".g..g.", ".g..g.", "yyyyyy", "yyooyy", "yyooyy", "BBBBBB"], 13, by - 5)
    hd = ellipse(N, N, cx, by + 7.5, 4.5, 3.2)
    layer(c, hd, shade(hd, "2", "1", "d", cx, by + 7.5, 4.5, 3.2))
    ey = int(by + 7)
    if dead:
        eyes_x(c, [(13, ey), (18, ey)], "r")
    elif pain:
        eyes_shut(c, [(13, ey), (18, ey)])
    else:
        plot(c, [(12, ey), (19, ey)], "r")
        rect(c, 14, ey - 1, 14, ey, "r")
        rect(c, 17, ey - 1, 17, ey, "r")
        plot(c, [(14, ey - 1), (17, ey - 1)], "c")
    fy = int(by + 10)
    if attack:
        plot(c, [(13, fy), (12, fy + 1), (18, fy), (19, fy + 1)], "c")
    else:
        plot(c, [(14, fy), (17, fy), (14, fy + 1), (17, fy + 1)], "c")
    # thread from the ceiling to the top of the abdomen (bug_frames removes
    # it for the falling and floor frames)
    c[0 : int(by - 6) + 1, SPIDER_THREAD_X] = "g"
    return c


# --- boss (Heisenbug): big purple roach seen head-on, a yellow "?" on the
# shield, huge red eyes, long antennae, spiky brown legs. Drawn at 1.5x by
# the code. Frame 7: flat purple-3 silhouette of frame 0 with a purple-4
# rim (the code flickers it).
QMARK = [".ooooo.", "oyyyyyo", "oyoooyo", "ooo.oyo", "..oyyo.", "..oyo..", "..ooo..", "..oyo..", "..ooo.."]


def boss(phase: int = 0, attack: bool = False, pain: bool = False, dead: bool = False) -> np.ndarray:
    c = canvas(N, N)
    cx = 15.5
    dy = (1 if phase else 0) - (1 if attack else 0)
    # wings flaring at the sides behind the shield
    for side in (-1, 1):
        wm = ellipse_rot(cx + side * 10, 15 + dy, 4.0, 8.5, side * 15)
        layer(c, wm, np.where(ellipse_rot(cx + side * 10, 15 + dy, 1.0, 7, side * 15), "m", "g"))
    # legs: three a side, spiky, feet on row 30
    for side in (-1, 1):
        for k, (hx_, hy_, kx, ky, fx) in enumerate(((10, 20, 4, 21, 2), (11, 22, 6, 25, 5), (12, 24, 10, 27, 9))):
            sw = (1 if (k + phase) % 2 else -1) * side if not dead else 0
            if dead:
                pts = [(cx - side * (cx - hx_), hy_), (cx - side * (cx - kx), ky - 5), (cx - side * (cx - kx + 1), ky - 8)]
            else:
                pts = [(cx - side * (cx - hx_), hy_ + dy), (cx - side * (cx - kx) + sw, ky + dy),
                       (cx - side * (cx - fx) + sw, 30)]
            layer(c, seg_mask(N, N, pts, 0.6), "B")
    # shield (pronotum) with the "?"
    ry = 7.5 - (1 if pain else 0)
    sh = ellipse(N, N, cx, 11 + dy, 11.0, ry)
    layer(c, sh, shade(sh, "3", "2", "1", cx, 11 + dy, 11, ry))
    c[sh & ellipse(N, N, cx - 4, 7 + dy, 3.5, 1.5)] = "4"
    stamp(c, QMARK, 12, 5 + dy)
    # head, eyes, mandibles
    hd = ellipse(N, N, cx, 20 + dy, 6.5, 4.5)
    layer(c, hd, shade(hd, "t", "B", "b", cx, 20 + dy, 6.5, 4.5))
    eyes = [(12, 19 + dy), (19, 19 + dy)]
    for x, y in eyes:
        e = ellipse(N, N, x + 0.5 if x > cx else x - 0.5, y, 2.4, 2.4)
        layer(c, e, "R" if (pain or dead) else "r")
        if dead:
            eyes_x(c, [(x, y)])
        elif pain:
            eyes_shut(c, [(x, y)])
        else:
            plot(c, [(x - 1, y - 1)], "y" if attack else "c")
    my = 24 + dy
    if attack:
        rect(c, 13, my, 18, my + 1, "o")
        g = ellipse(N, N, cx, my + 2, 2.4, 1.8)
        layer(c, g, "l")
        plot(c, [(14, my + 1)], "c")
    plot(c, [(13, my), (12, my + 1), (18, my), (19, my + 1)], "t")
    # antennae curving up and out
    for side in (-1, 1):
        wig = (phase * 2 - 1) * side if not dead else 3
        pts = [(cx + side * 2, 5 + dy), (cx + side * 6, 1.5), (cx + side * 12 + wig, 2 + abs(wig))]
        c[seg_mask(N, N, pts, 0.45) & (c == ".")] = "t"
    return c


def silhouette(c: np.ndarray, fill: str = "3", rim: str = "4") -> np.ndarray:
    m = c != "."
    inner = m & np.roll(m, 1, 0) & np.roll(m, -1, 0) & np.roll(m, 1, 1) & np.roll(m, -1, 1)
    out = canvas(c.shape[1], c.shape[0])
    out[m] = rim
    out[inner] = fill
    return out


BUG_CMAPS = {  # documented per-sheet palettes (validate() counts the real use)
    "bug_gnat.png": "odDGlcgryR",
    "bug_wasp.png": "odyLBcgRrm",
    "bug_beetle.png": "odDGlbtrc34",
    "bug_spider.png": "od123gyBrc",
    "bug_boss.png": "om1234grRbBtylc",
}


def draw_bug(name: str) -> np.ndarray:
    if name == "bug_boss.png":
        frames = bug_frames(boss)
        frames.append(finish(silhouette(frames[0])))
    elif name == "bug_spider.png":
        frames = bug_frames(spider, thread=True)
    else:
        frames = bug_frames({"bug_gnat.png": gnat, "bug_wasp.png": wasp, "bug_beetle.png": beetle}[name])
    return strip([to_rgb(f, True) for f in frames])


# --------------------------------------------------------------------------
# rival.png (deathmatch, M7): the other player, a rival Snouty in a Coral
# shirt holding a zapper, 5 cells 32x32 bottom-anchored like the bugs:
# front (facing the viewer), right side (facing screen right), back, left
# side (the mirror), and down (the death view: lying on the floor, X eyes).
# Purple fur as on the portrait, Coral shirt (Iris badge), dark trousers,
# teal zapper. The engine draws the hit flash (all white), as for bugs.
# --------------------------------------------------------------------------
def rival_legs(c: np.ndarray, xs: list[int], y0: int = 24) -> None:
    for x in xs:
        rect(c, x, y0, x + 2, 28, "m")
        rect(c, x, y0, x, 28, "d")
        rect(c, x - (1 if x < 15 else 0), 29, x + 2 + (0 if x < 15 else 1), 29, "o")


def rival_shirt(c: np.ndarray, cx: float, rx: float, badge: bool) -> None:
    body = ellipse(N, N, cx, 20.5, rx, 6.2) & (np.arange(N)[:, None] >= 15) & (np.arange(N)[:, None] <= 25)
    layer(c, body, shade(body, "C", "C", "R", cx, 20.5, rx, 6.2, hi=-0.9, lo=0.35))
    if badge:
        c[18:20, int(cx) + 2 : int(cx) + 4] = "4"


def rival_front() -> np.ndarray:
    c = canvas(N, N)
    rival_legs(c, [12, 17])
    rival_shirt(c, 15.5, 6.2, True)
    # arms: left hangs, right holds the zapper forward
    layer(c, seg_mask(N, N, [(9.5, 17), (8.5, 23)], 1.3), "3")
    layer(c, seg_mask(N, N, [(21.5, 17), (22.5, 21)], 1.3), "3")
    layer(c, ellipse(N, N, 8.5, 24, 1.6, 1.4), "4")
    zap = np.zeros((N, N), bool)
    zap[20:24, 21:26] = True
    layer(c, zap, "s")
    c[21, 22:25] = "T"
    c[23, 24] = "T"
    # head: ears, round head, the snout coming at the viewer
    for ex in (10.0, 21.0):
        layer(c, ellipse(N, N, ex, 4.5, 2.4, 2.4), "3")
        c[ellipse(N, N, ex, 4.7, 1.1, 1.1)] = "2"
    head = ellipse(N, N, 15.5, 9.5, 6.3, 5.4)
    layer(c, head, shade(head, "4", "3", "2", 15.5, 9.5, 6.3, 5.4, hi=-0.45, lo=0.45))
    for ex in (12.5, 18.5):
        e = ellipse(N, N, ex, 8.5, 1.5, 1.9)
        c[e] = "c"
        c[8:10, int(ex)] = "o"
    # angry brows: a rival
    plot(c, [(11, 6), (12, 6), (13, 7)], "o")
    plot(c, [(20, 6), (19, 6), (18, 7)], "o")
    sn = poly_mask(N, N, [(13.6, 10.5), (17.4, 10.5), (16.6, 16.0), (14.4, 16.0)])
    xs, _ = coords(N, N)
    layer(c, sn, np.where(xs < 14.8, "4", np.where(xs > 16.2, "2", "3")))
    c[15:17, 15:17] = "o"
    return c


def rival_side() -> np.ndarray:
    """Facing screen right."""
    c = canvas(N, N)
    # tail behind (left), bushy
    tail = ellipse_rot(7.5, 19.5, 2.8, 6.0, -25)
    layer(c, tail, shade(tail, "3", "2", "1", 7.5, 19.5, 2.8, 6.0))
    rival_legs(c, [12, 16])
    rival_shirt(c, 14.5, 4.8, False)
    # arm forward with the zapper pointing right
    layer(c, seg_mask(N, N, [(14.5, 17.5), (19.5, 20.0)], 1.3), "3")
    zap = np.zeros((N, N), bool)
    zap[18:21, 19:27] = True
    layer(c, zap, "s")
    c[19, 21:26] = "T"
    c[18, 26] = "T"
    # head, ear, long anteater snout to the right
    layer(c, ellipse(N, N, 11.5, 4.5, 2.2, 2.4), "3")
    c[ellipse(N, N, 11.5, 4.8, 1.0, 1.0)] = "2"
    head = ellipse(N, N, 13.5, 9.5, 5.4, 5.2)
    layer(c, head, shade(head, "4", "3", "2", 13.5, 9.5, 5.4, 5.2, hi=-0.45, lo=0.45))
    sn = poly_mask(N, N, [(17.0, 7.6), (27.5, 10.2), (27.5, 11.8), (17.0, 13.4)])
    xs, ys = coords(N, N)
    layer(c, sn, np.where(ys < 9.8, "4", np.where(ys > 11.8, "2", "3")))
    c[10:12, 27:29] = "o"  # nose tip
    e = ellipse(N, N, 15.5, 8.2, 1.4, 1.8)
    c[e] = "c"
    c[8:10, 16] = "o"
    plot(c, [(14, 6), (15, 6), (16, 7)], "o")
    return c


def rival_back() -> np.ndarray:
    c = canvas(N, N)
    rival_legs(c, [12, 17])
    # tail hanging behind the legs
    tail = ellipse(N, N, 15.5, 24.0, 2.8, 5.0)
    rival_shirt(c, 15.5, 6.2, False)
    layer(c, tail, shade(tail, "3", "2", "1", 15.5, 24.0, 2.8, 5.0))
    layer(c, seg_mask(N, N, [(9.5, 17), (8.5, 23)], 1.3), "3")
    layer(c, seg_mask(N, N, [(21.5, 17), (22.5, 23)], 1.3), "3")
    for ex in (10.0, 21.0):
        layer(c, ellipse(N, N, ex, 4.5, 2.4, 2.4), "3")
    head = ellipse(N, N, 15.5, 9.5, 6.3, 5.4)
    layer(c, head, shade(head, "3", "2", "1", 15.5, 9.5, 6.3, 5.4, hi=-0.45, lo=0.45))
    c[13, 13:19] = "2"  # the collar line
    return c


def rival_down() -> np.ndarray:
    """The death view: the side drawing turned onto its back, X eyes."""
    side = rival_side()
    lying = np.rot90(side, k=1).copy()  # head to the left, feet up-right
    lying = anchor_bottom(lying, 30)
    # X eyes where the eye landed
    ys, xs = np.nonzero(lying == "c")
    if len(xs):
        cx, cy = int(round(xs.mean())), int(round(ys.mean()))
        rect(lying, cx - 1, cy - 1, cx + 1, cy + 1, "c")
        eyes_x(lying, [(cx, cy)])
    return lying


RIVAL_FRAMES = ["front", "right side", "back", "left side", "down"]


def draw_rival() -> np.ndarray:
    side = rival_side()
    cells = [rival_front(), side, rival_back(), mirror_x(side), rival_down()]
    for cl in cells:
        clear_border(cl)
    return strip([to_rgb(cl, True) for cl in cells])


# --------------------------------------------------------------------------
# pickups.png: 8 cells 16x16, standing on the floor (bottom-centre anchor:
# drawings rest on row 14). Keys, hotfix medkit, zapper charge cell, bug
# spray can, rewind battery, Debugger cartridge (red breakpoint dot).
# --------------------------------------------------------------------------
KEY_COLORS = {"coral": ("c", "C", "R"), "iris": ("4", "3", "1"), "gold": ("c", "y", "B")}


def pickup_key(kind: str) -> np.ndarray:
    hi, face, lo = KEY_COLORS[kind]
    c = canvas(16, 16)
    bow = ellipse(16, 16, 7.5, 5.0, 3.6, 3.6) & ~ellipse(16, 16, 7.5, 5.0, 1.3, 1.3)
    shaft = np.zeros((16, 16), bool)
    shaft[8:14, 7:9] = True
    teeth = np.zeros((16, 16), bool)
    teeth[10, 9:11] = True
    teeth[12:14, 9:11] = True
    m = bow | shaft | teeth
    fill = np.full((16, 16), face, "<U1")
    xs, ys = coords(16, 16)
    fill[(xs + ys) < 10.5] = hi
    fill[(xs - 7.5) + (ys - 5) * 0.3 > 2.2] = lo
    fill[shaft & (xs == 8)] = lo
    fill[teeth] = face
    layer(c, m, fill)
    return c


def pickup_hotfix() -> np.ndarray:
    c = canvas(16, 16)
    box = np.zeros((16, 16), bool)
    box[6:15, 2:14] = True
    fill = np.full((16, 16), "c", "<U1")
    fill[:, 12:14] = "g"
    fill[13:15, :] = "g"
    layer(c, box, fill)
    rect(c, 7, 7, 8, 12, "r")
    rect(c, 5, 9, 10, 10, "r")
    c[7, 7] = "C"
    c[9, 5] = "C"
    c[4, 6:10] = "o"  # handle
    c[5, 5] = "o"
    c[5, 10] = "o"
    c[5, 6:10] = "."
    return c


def pickup_charge() -> np.ndarray:
    c = canvas(16, 16)
    cell = np.zeros((16, 16), bool)
    cell[5:15, 4:12] = True
    fill = np.full((16, 16), "T", "<U1")
    fill[:, 4:6] = "c"
    fill[:, 10:12] = "m"
    layer(c, cell, fill)
    c[3:5, 6:10] = "g"
    c[2, 6:10] = "o"
    c[3:5, 5] = "o"
    c[3:5, 10] = "o"
    stamp(c, ["..yy", ".yy.", "yyyy", ".yy.", "yy.."], 6, 7)
    return c


def pickup_spray() -> np.ndarray:
    c = canvas(16, 16)
    can = np.zeros((16, 16), bool)
    can[5:15, 4:12] = True
    fill = np.full((16, 16), "g", "<U1")
    fill[:, 4:6] = "c"
    fill[:, 10:12] = "m"
    fill[8:12, 4:12] = "G"
    fill[8:12, 4:6] = "l"
    layer(c, can, fill)
    c[9:11, 7:9] = "o"  # the bug on the label, crossed out
    c[8, 6] = "r"
    c[9, 7] = "r"
    c[10, 8] = "r"
    c[11, 9] = "r"
    rect(c, 6, 3, 9, 4, "r")
    c[2, 6:10] = "o"
    c[3:5, 5] = "o"
    c[3:5, 10] = "o"
    c[3, 10] = "o"
    c[3, 11] = "o"  # nozzle
    return c


def pickup_battery() -> np.ndarray:
    c = canvas(16, 16)
    body = np.zeros((16, 16), bool)
    body[7:15, 1:13] = True
    body[9:13, 13:15] = True  # terminal
    fill = np.full((16, 16), "3", "<U1")
    fill[7:9, :] = "4"
    fill[13:15, :] = "1"
    fill[9:13, 13:15] = "g"
    layer(c, body, fill)
    stamp(c, ["...c..c", "..cc.cc", ".ccccc.", "..cc.cc", "...c..c"], 2, 8)
    c[:, 0] = "."
    c[:, 15] = "."
    return c


def pickup_debugger() -> np.ndarray:
    """The Debugger cartridge: a grey cartridge with grip ridges, a cream
    label and the red breakpoint dot on it."""
    c = canvas(16, 16)
    body = np.zeros((16, 16), bool)
    body[3:15, 3:13] = True
    body[3, 11:13] = False  # chamfered top-right corner
    body[4, 12] = False
    fill = np.full((16, 16), "g", "<U1")
    fill[:, 3] = "c"
    fill[:, 12] = "m"
    fill[14, :] = "m"
    layer(c, body, fill)
    for y in (4, 6):  # grip ridges
        c[y, 5:10] = "m"
    rect(c, 4, 8, 11, 13, "c")  # label
    dot = ellipse(16, 16, 7.5, 10.5, 2.6, 2.6)
    layer(c, dot, shade(dot, "C", "r", "R", 7.5, 10.5, 2.6, 2.6))
    c[9, 6] = "c"  # specular
    return c


def draw_pickups() -> np.ndarray:
    cells = [pickup_key("coral"), pickup_key("iris"), pickup_key("gold"), pickup_hotfix(),
             pickup_charge(), pickup_spray(), pickup_battery(), pickup_debugger()]
    for c in cells:
        clear_border(c)
    return strip([to_rgb(c, True) for c in cells])


# --------------------------------------------------------------------------
# projectiles.png: 6 cells 8x8, centre anchor: spit x2 (green glob,
# pulsing), web x2 (cream strands, rotated 45 degrees between frames), the
# Debugger bolt (red breakpoint dot, cream core, drawn at 0.25 cells) and
# its burst (red and cream ring with rays, drawn at 1.0 cell).
# --------------------------------------------------------------------------
PROJECTILES = [
    ["........", "..ooo...", ".olclo..", ".ollllo.", ".olllGo.", "..oGGo..", "...oo...", "........"],
    ["........", "........", "..ooo...", ".olclo..", ".ollGo..", "..oGo...", "...o....", "........"],
    ["........", "...c....", ".g.c.g..", "..ggg...", "ccgcgcc.", "..ggg...", ".g.c.g..", "...c...."],
    ["........", ".c...c..", "..cgc...", ".gg.gg..", "..cgc...", ".c...c..", "........", "........"],
    ["........", "..oooo..", ".orCCro.", ".oCccro.", ".orccRo.", ".orrRRo.", "..oooo..", "........"],
    ["........", ".r.cc.r.", "..rCCr..", ".cC..Cc.", ".cC..Cc.", "..rCCr..", ".r.cc.r.", "........"],
]


def draw_projectiles() -> np.ndarray:
    cells = []
    for rows in PROJECTILES:
        c = canvas(8, 8)
        stamp(c, rows, 0, 0)
        clear_border(c)
        cells.append(c)
    return strip([to_rgb(c, True) for c in cells])


# --------------------------------------------------------------------------
# weapons.png: 12 cells 48x32, first person, seen from behind and below,
# drawn at the bottom centre of the view. Snouty's purple paw and forearm
# come in from the bottom edge (the only edge a weapon cell may touch).
# 0-2 swatter idle/swing/swing, 3-5 zapper idle/fire/fire, 6-8 spray,
# 9-11 Debugger idle/fire/fire (breakpoint gun).
# --------------------------------------------------------------------------
WW, WH = 48, 32


def paw(c: np.ndarray, px: float, py: float, arm_dx: float = 4.0) -> None:
    """Forearm in a black shirt sleeve from the bottom edge up to a paw
    centred at (px, py)."""
    arm = poly_mask(WW, WH, [(px - 5, py + 1), (px + 5, py + 1), (px + 7 + arm_dx, 32.5), (px - 5 + arm_dx, 32.5)])
    layer(c, arm, shade(arm, "3", "2", "2", px, py + 6, 5, 6, hi=-0.2, lo=0.3))
    _, ys = coords(WW, WH)
    sleeve = arm & (ys >= 29)
    c[sleeve] = "d"
    c[sleeve & (ys == 29)] = "m"
    pm = ellipse(WW, WH, px, py, 6.5, 4.6)
    layer(c, pm, shade(pm, "4", "3", "2", px, py, 6.5, 4.6))
    for k in (-3, -1, 1, 3):  # finger creases wrapped round the grip
        plot(c, [(px + k, py - 3), (px + k, py - 2)], "2")


def mesh(c: np.ndarray, x0: int, y0: int, x1: int, y1: int, pitch: int = 3) -> None:
    m = np.zeros((WH, WW), bool)
    m[y0 : y1 + 1, x0 : x1 + 1] = True
    for x, y in ((x0, y0), (x1, y0), (x0, y1), (x1, y1)):
        m[y, x] = False
    xs, ys = coords(WW, WH)
    fill = np.where(((xs - x0) % pitch == 0) | ((ys - y0) % pitch == 0), "C", "R")
    fill[y0, :] = "c"
    fill[:, x0] = np.where(m[:, x0], "c", fill[:, x0])
    layer(c, m, fill)


def handle(c: np.ndarray, a, b) -> None:
    hm = seg_mask(WW, WH, [a, b], 0.9)
    layer(c, hm, "g")
    c[seg_mask(WW, WH, [(a[0] - 0.6, a[1]), (b[0] - 0.6, b[1])], 0.35) & hm] = "c"


def weapon_swatter(pose: int) -> np.ndarray:
    c = canvas(WW, WH)
    if pose == 0:  # idle: head up, a little left of centre
        handle(c, (30, 24), (22, 11))
        mesh(c, 13, 2, 27, 12)
        paw(c, 30, 26)
    elif pose == 1:  # wind-up: pulled back to the right, higher
        handle(c, (35, 23), (35, 10))
        mesh(c, 29, 1, 41, 10)
        paw(c, 35, 25, 3)
    else:  # swat: slammed forward, big and low, motion streaks
        handle(c, (29, 27), (24, 21))
        mesh(c, 8, 8, 30, 21, 4)
        for y, x0, x1 in ((3, 10, 22), (5, 6, 18), (2, 26, 32)):
            c[y, x0 : x1 + 1] = "c"
        paw(c, 30, 28, 2)
    return c


def weapon_zapper(pose: int) -> np.ndarray:
    c = canvas(WW, WH)
    dy = 2 if pose == 1 else (1 if pose == 2 else 0)
    body = np.zeros((WH, WW), bool)
    body[9 + dy : 24 + dy, 18:30] = True
    xs, ys = coords(WW, WH)
    fill = np.full((WH, WW), "s", "<U1")
    fill[ys < 11 + dy] = "g"
    fill[:, 18:20] = "g"
    fill[:, 27:30] = "m"
    layer(c, body, fill)
    c[14 + dy : 18 + dy, 21:27] = "o"  # vent
    c[15 + dy, 22:26] = "T"
    c[16 + dy, 22:26] = "T" if pose else "m"
    for x in (20, 27):  # emitter prongs
        c[3 + dy : 9 + dy, x] = "g"
        c[3 + dy : 9 + dy, x + 1] = "m"
        c[2 + dy, x : x + 2] = "o"
    for y in range(4 + dy, 9 + dy, 2):  # coil
        c[y, 22:27] = "T"
    if pose == 1:  # big bolt
        f = ellipse(WW, WH, 24.0, 4.0, 7.0, 3.0)
        c[f] = "T"
        c[ellipse(WW, WH, 24.0, 4.0, 4.5, 1.8)] = "c"
        plot(c, [(15, 3), (14, 4), (13, 3), (12, 4), (33, 3), (34, 4), (35, 3), (36, 4)], "T")
        plot(c, [(24, 1), (23, 1), (25, 1)], "c")
    elif pose == 2:  # fading: small spark and crackle
        c[ellipse(WW, WH, 24.0, 4.0, 3.0, 1.6)] = "4"
        c[ellipse(WW, WH, 24.0, 4.0, 1.5, 0.8)] = "c"
        plot(c, [(18, 2), (30, 2), (17, 5), (31, 5)], "4")
    paw(c, 24, 26 + dy // 2, 3)
    return c


def weapon_spray(pose: int) -> np.ndarray:
    c = canvas(WW, WH)
    dy = 1 if pose else 0
    can = np.zeros((WH, WW), bool)
    can[7 + dy : 27, 19:29] = True
    fill = np.full((WH, WW), "g", "<U1")
    fill[:, 19:21] = "c"
    fill[:, 25:27] = "s"
    fill[:, 27:29] = "m"
    fill[12 + dy : 19 + dy, 19:29] = "G"
    fill[12 + dy : 19 + dy, 19:21] = "l"
    fill[12 + dy, 19:29] = "l"
    layer(c, can, fill)
    rect(c, 22, 14 + dy, 25, 16 + dy, "o")  # crossed-out bug
    plot(c, [(21, 13 + dy), (22, 14 + dy), (23, 15 + dy), (24, 16 + dy), (25, 17 + dy), (26, 18 + dy)], "r")
    shoulder = ellipse(WW, WH, 24, 7 + dy, 5.0, 2.0)
    layer(c, shoulder, "g")
    rect(c, 22, 3 + dy, 25, 5 + dy, "r")  # cap / nozzle
    c[3 + dy, 22:26] = "c"
    c[2 + dy, 22:26] = "o"
    c[3 + dy : 6 + dy, 21] = "o"
    c[3 + dy : 6 + dy, 26] = "o"
    if pose:  # mist: dithered cloud, bigger and sparser in the second frame
        rx, ry, dens = (8.0, 3.0, 2) if pose == 1 else (12.0, 3.2, 3)
        cloud = ellipse(WW, WH, 24, 3.0, rx, ry) & (c == ".")
        xs, ys = coords(WW, WH)
        dots = cloud & ((xs.astype(int) + 2 * ys.astype(int)) % dens == 0)
        c[dots] = "c" if pose == 1 else "g"
        c[cloud & ((xs.astype(int) * 3 + ys.astype(int)) % 5 == 0)] = "g"
    paw(c, 24, 26, 3)
    return c


def weapon_debugger(pose: int) -> np.ndarray:
    """The breakpoint gun: a boxy steel body with the big red breakpoint
    dot on its back face, a short wide muzzle slab on top (pointing into
    the screen). Fire 0 sends a red bolt out of the muzzle, fire 1 is the
    recoil (body kicked down, sparks)."""
    c = canvas(WW, WH)
    dy = 1 if pose == 1 else (2 if pose == 2 else 0)
    muzzle = np.zeros((WH, WW), bool)
    muzzle[5 + dy : 10 + dy, 16:32] = True
    mf = np.full((WH, WW), "m", "<U1")
    mf[5 + dy, :] = "g"
    mf[:, 16] = "g"
    layer(c, muzzle, mf)
    c[ellipse(WW, WH, 23.5, 7.5 + dy, 5.2, 1.2) & muzzle] = "o"  # wide bore
    body = np.zeros((WH, WW), bool)
    body[10 + dy : 26 + dy, 14:34] = True
    bf = np.full((WH, WW), "s", "<U1")
    bf[10 + dy : 12 + dy, :] = "g"  # top face
    bf[:, 14:16] = "g"
    bf[:, 14] = "c"
    bf[:, 31:34] = "m"
    layer(c, body, bf)
    for y in (22 + dy, 24 + dy):  # grip ribs
        c[y, 17:31] = "m"
    dot = ellipse(WW, WH, 23.5, 16.5 + dy, 4.3, 3.9)
    layer(c, dot, shade(dot, "C", "r", "R", 23.5, 16.5 + dy, 4.3, 3.9))
    plot(c, [(21, 14 + dy), (22, 14 + dy)], "c")  # specular
    if pose == 1:  # bolt leaving the muzzle in a flash
        flash = ellipse(WW, WH, 23.5, 4.0, 11.0, 3.2) & (c == ".")
        c[flash] = "C"
        c[ellipse(WW, WH, 23.5, 4.0, 7.5, 2.2) & flash] = "c"
        bolt = ellipse(WW, WH, 23.5, 3.5, 3.2, 2.3)
        layer(c, bolt, shade(bolt, "C", "r", "R", 23.5, 3.5, 3.2, 2.3))
        c[3, 22] = "c"
        plot(c, [(10, 3), (11, 2), (37, 3), (36, 2), (9, 5), (38, 5)], "C")
    elif pose == 2:  # recoil: body kicked down, sparks at the muzzle corners
        plot(c, [(14, 4), (13, 3), (33, 4), (34, 3), (23, 3), (24, 2)], "c")
        plot(c, [(15, 3), (32, 3)], "C")
    paw(c, 24, 27 + dy // 2, 3)
    return c


def draw_weapons() -> np.ndarray:
    cells = [weapon_swatter(i) for i in range(3)] + [weapon_zapper(i) for i in range(3)] + \
            [weapon_spray(i) for i in range(3)] + [weapon_debugger(i) for i in range(3)]
    for c in cells:
        clear_border(c, keep_bottom=True)
    return strip([to_rgb(c, True) for c in cells])


# --------------------------------------------------------------------------
# face.png: 9 cells 24x24, Snouty's portrait head-on (Doom-style HUD
# face): purple head and round ears, big cream eyes, the long snout
# foreshortened toward the viewer, black shirt with the Coral Iris.
# --------------------------------------------------------------------------
FW = 24
EYES = [(7.5, 9.5), (15.5, 9.5)]


def face_base() -> np.ndarray:
    c = canvas(FW, FW)
    xs, ys = coords(FW, FW)
    shirt = ellipse(FW, FW, 11.5, 26.0, 10.5, 7.5) & (ys <= 22)
    layer(c, shirt, np.where(ys <= 19, "m", "d"))
    for ex in (5.0, 18.0):
        ear = ellipse(FW, FW, ex, 4.5, 3.2, 3.2)
        layer(c, ear, "3")
        c[ellipse(FW, FW, ex, 4.8, 1.6, 1.6)] = "2"
    head = ellipse(FW, FW, 11.5, 11.0, 8.6, 7.6)
    layer(c, head, shade(head, "4", "3", "2", 11.5, 11, 8.6, 7.6, hi=-0.45, lo=0.45))
    c[20:22, 15:17] = "C"  # Iris on the shirt
    return c


def face_eyes(c: np.ndarray, look: int = 0, drop: int = 0) -> None:
    for ex, ey in EYES:
        e = ellipse(FW, FW, ex, ey, 2.1, 2.6)
        layer(c, e, "c")
        px = int(ex - 0.5) + look
        c[int(ey) + drop : int(ey) + 2 + drop, px : px + 2] = "o"


def face_snout(c: np.ndarray, mouth: str = "") -> None:
    sn = poly_mask(FW, FW, [(8.6, 11.5), (14.4, 11.5), (13.6, 20.2), (9.4, 20.2)])
    xs, ys = coords(FW, FW)
    layer(c, sn, np.where(xs < 10.5, "4", np.where(xs > 12.5, "2", "3")))
    c[19:21, 10:13] = "o"  # nose tip
    c[19, 10] = "d"
    if mouth == "open":
        c[21, 10:13] = "R"
        c[22, 10:13] = "o"
        c[21, 11] = "r"
    elif mouth == "tongue":
        c[20:23, 11:13] = "C"
        c[22, 11:13] = "R"


def face(expr: str) -> np.ndarray:
    c = face_base()
    if expr in ("healthy", "glance L", "glance R", "hurt", "grin"):
        face_eyes(c, look={"glance L": -1, "glance R": 1}.get(expr, 0))
    if expr == "hurt":
        plot(c, [(5, 6), (6, 6), (7, 5), (8, 5), (18, 6), (17, 6), (16, 5), (15, 5)], "o")  # worried brows
        rect(c, 4, 13, 5, 14, "1")  # bruise
        rect(c, 14, 3, 16, 4, "c")  # plaster
        c[3, 15] = "g"
    elif expr == "critical":
        face_eyes(c, drop=1)
        for ex, ey in EYES:  # heavy lids
            x0, x1 = int(ex - 2), int(ex + 2)
            c[int(ey) - 2 : int(ey), x0 : x1 + 1][c[int(ey) - 2 : int(ey), x0 : x1 + 1] == "c"] = "2"
            c[int(ey), x0 : x1 + 1][c[int(ey), x0 : x1 + 1] == "c"] = "o"
        c[4:6, 4:20][c[4:6, 4:20] != "."] = "c"  # bandage round the head
        c[5, 4:20][c[5, 4:20] == "c"] = "g"
        c[4:6, 3] = "o"
        c[4:6, 20] = "o"
        rect(c, 3, 13, 4, 14, "1")
        rect(c, 18, 14, 19, 15, "1")
        plot(c, [(20, 9), (20, 10), (21, 10)], "T")  # sweat
    elif expr == "ouch":
        for ex, ey in EYES:
            x, y = int(ex), int(ey)
            d = 1 if ex < 11.5 else -1  # > <
            plot(c, [(x - d, y - 2), (x, y - 1), (x + d, y), (x, y + 1), (x - d, y + 2)], "o")
        plot(c, [(5, 5), (7, 6), (18, 5), (16, 6)], "o")
    elif expr == "grin":
        for ex, ey in EYES:  # happy squint: lower lids up
            x0 = int(ex - 2)
            c[int(ey) + 1 : int(ey) + 3, x0 : x0 + 5][c[int(ey) + 1 : int(ey) + 3, x0 : x0 + 5] == "c"] = "3"
            c[int(ey) + 1, x0 + 1 : x0 + 4] = "o"
        plot(c, [(4, 14), (5, 15), (6, 16), (7, 16), (19, 14), (18, 15), (17, 16), (16, 16)], "o")  # grin
        plot(c, [(6, 15), (7, 15), (16, 15), (17, 15)], "c")  # teeth
        rect(c, 3, 12, 4, 12, "C")  # blush
        rect(c, 19, 12, 20, 12, "C")
    elif expr == "rewind":
        for ex, ey in EYES:
            e = ellipse(FW, FW, ex, ey, 2.6, 2.8)
            layer(c, e, "c")
            x0, y0 = int(ex - 2), int(ey - 2)
            stamp(c, [".333.", "3...3", "3.3.3", "3..33", ".3..."], x0, y0)
    elif expr == "dead":
        for ex, ey in EYES:
            e = ellipse(FW, FW, ex, ey, 2.1, 2.6)
            layer(c, e, "c")
            eyes_x(c, [(int(ex), int(ey))])
    face_snout(c, mouth={"ouch": "open", "dead": "tongue"}.get(expr, ""))
    if expr == "grin":
        c[21, 10:13] = "o"
        c[20, 9] = "o"
        c[20, 13] = "o"
    clear_border(c)
    return c


def draw_face() -> np.ndarray:
    return strip([to_rgb(face(e), True) for e in FRAME_NAMES["face.png"]])


# --------------------------------------------------------------------------
# hud.png: 9 cells 8x8 with a 1 px empty border: three keys (lit; the code
# dims them), zapper charge, spray can, clock, "<<", heart, Debugger ammo
# (the red breakpoint dot in a small grey box).
# --------------------------------------------------------------------------
HUD_KEY = ["........", "........", ".HHH....", ".H.HHHH.", ".LLL.LL.", "......L.", "........", "........"]
HUD_ICONS = [
    ["........", "....TT..", "...TT...", "..TTTT..", "...TT...", "..TT....", ".T......", "........"],
    ["........", "...rr...", "..gccg..", "..GllG..", "..GooG..", "..gggg..", "..mmmm..", "........"],
    ["........", "..4444..", ".4cc3c4.", ".4cc3c4.", ".4c33c4.", ".4cccc4.", "..4444..", "........"],
    ["........", "...4..4.", "..44.44.", ".444444.", "..33.33.", "...3..3.", "........", "........"],
    ["........", "........", ".rr..rr.", ".rCrrrr.", ".rrrrrr.", "..rrrR..", "...rR...", "........"],
    ["........", ".gggggg.", ".g.rr.g.", ".grCrrg.", ".grrrRg.", ".g.RR.g.", ".gggggg.", "........"],
]


def draw_hud() -> np.ndarray:
    cells = []
    for kind in ("coral", "iris", "gold"):
        hi, face_, lo = KEY_COLORS[kind]
        rows = [r.replace("H", face_ if kind != "iris" else "4").replace("L", lo if kind != "iris" else "3") for r in HUD_KEY]
        if kind == "gold":
            rows = [r.replace("y", "y") for r in rows]
        c = canvas(8, 8)
        stamp(c, rows, 0, 0)
        cells.append(c)
    for rows in HUD_ICONS:
        c = canvas(8, 8)
        stamp(c, rows, 0, 0)
        cells.append(c)
    for c in cells:
        clear_border(c)
    return strip([to_rgb(c, True) for c in cells])


# --------------------------------------------------------------------------
# title.png: 128x40, "SNOUTENSTEIN" in a 4x7 block font at 2x over a big
# Coral "3D" at 3x flanked by two cream Iris marks; banded purple fill,
# cream top edges, dark bottom edges, 1 px outline, 45-degree chamfers.
# Never rendered with a font rasteriser (anti-aliasing breaks the palette).
# --------------------------------------------------------------------------
def glyph_mask(key: str, k: int) -> np.ndarray:
    g = np.array([[ch == "#" for ch in r] for r in FONT[key]])
    gh, gw = g.shape
    on = lambda i, j: 0 <= i < gh and 0 <= j < gw and g[i, j]
    m = g.repeat(k, 0).repeat(k, 1)
    for i in range(gh):
        for j in range(gw):
            if g[i, j]:
                continue
            for di, dj in ((-1, -1), (-1, 1), (1, -1), (1, 1)):
                if on(i + di, j) and on(i, j + dj) and not on(i + di, j + dj):
                    for py in range(k):
                        for px in range(k):
                            cy = py if di < 0 else k - 1 - py
                            cx = px if dj < 0 else k - 1 - px
                            if cx + cy <= k - 2:
                                m[i * k + py, j * k + px] = True
    return m


def logo_line(keys: list[str], k: int, gap: int) -> np.ndarray:
    parts = []
    for i, key in enumerate(keys):
        if i:
            parts.append(np.zeros((7 * k, gap), bool))
        parts.append(glyph_mask(key, k))
    return np.concatenate(parts, axis=1)


def draw_title() -> np.ndarray:
    W_, H_ = 128, 40
    c = canvas(W_, H_)
    lines = [
        ([ch + "4" for ch in "SNOUTENSTEIN"], 2, 2, 2, False),  # keys, scale, gap, top row, coral
        (["3", "D"], 3, 3, 17, True),
    ]
    for keys, k, gap, top, coral in lines:
        m = logo_line(keys, k, gap)
        h, w = m.shape
        x0 = (W_ - w) // 2
        full = np.zeros((H_, W_), bool)
        full[top : top + h, x0 : x0 + w] = m
        ring = dilate4(full) & ~full
        c[ring & (c == ".")] = "o"
        above = np.zeros_like(full)
        above[1:] = full[:-1]
        below = np.zeros_like(full)
        below[:-1] = full[1:]
        rel = (np.arange(H_)[:, None] - top) / h
        if coral:
            fill = np.where(rel < 0.5, "C", "r")
            fill = np.where(~below, "R", fill)
        else:
            fill = np.where(rel < 0.4, "4", np.where(rel < 0.75, "3", "2"))
            fill = np.where(~below, "1", fill)
        fill = np.where(~above, "c", fill)
        c[full] = fill[full]
    # Iris marks either side of "3D"
    im = iris_mask(16)
    for x0 in (25, 87):
        sub = c[20:36, x0 : x0 + 16]
        ring = dilate4(im) & ~im
        sub[ring & (sub == ".")] = "o"
        sub[im] = "c"
    return to_rgb(c, True)


PLACEHOLDER_DRAW = {
    "walls.png": draw_walls,
    "doors.png": draw_doors,
    "bug_gnat.png": lambda: draw_bug("bug_gnat.png"),
    "bug_wasp.png": lambda: draw_bug("bug_wasp.png"),
    "bug_beetle.png": lambda: draw_bug("bug_beetle.png"),
    "bug_spider.png": lambda: draw_bug("bug_spider.png"),
    "bug_boss.png": lambda: draw_bug("bug_boss.png"),
    "rival.png": draw_rival,
    "pickups.png": draw_pickups,
    "projectiles.png": draw_projectiles,
    "weapons.png": draw_weapons,
    "face.png": draw_face,
    "hud.png": draw_hud,
    "title.png": draw_title,
}


# --------------------------------------------------------------------------
# Validation
# --------------------------------------------------------------------------
def q565(a: np.ndarray) -> np.ndarray:
    """RGB565 exactly as convert_gfx.zig computes it: f32 channel in 0..1
    times 31/63/31, truncated."""
    f = a.astype(np.float32) / np.float32(255.0)
    r = (f[..., 0] * np.float32(31.0)).astype(np.uint32)
    g = (f[..., 1] * np.float32(63.0)).astype(np.uint32)
    b = (f[..., 2] * np.float32(31.0)).astype(np.uint32)
    return (r << 11) | (g << 5) | b


def q565_shift(a: np.ndarray) -> np.ndarray:
    """The usual >> 3 / >> 2 cut (what a hardware-minded artist will assume)."""
    a = a.astype(np.uint32)
    return ((a[..., 0] >> 3) << 11) | ((a[..., 1] >> 2) << 5) | (a[..., 2] >> 3)


KEY565 = (31 << 11) | 31


def seam_ok(q: np.ndarray, axis: int) -> tuple[bool, float, float]:
    """Wrap-around seam vs. the texture's own neighbour-to-neighbour
    changes: the seam may not be sharper than the sharpest edge inside the
    texture (a bevelled panel edge is fine, a feature cut in half against
    smooth surroundings is not). axis 1: column 31 against column 0
    (tiles left-right); axis 0: row 31 against row 0 (tiles top-bottom)."""
    if axis == 1:
        inner = (q[:, 1:] != q[:, :-1]).mean(axis=0)
        seam = float((q[:, -1] != q[:, 0]).mean())
    else:
        inner = (q[1:] != q[:-1]).mean(axis=1)
        seam = float((q[-1] != q[0]).mean())
    typical = float(inner.max())
    return seam <= typical + 0.05, seam, typical


def validate(sheet: Sheet, a: np.ndarray, quiet: bool = False) -> tuple[list[str], int]:
    """Returns (errors, opaque colour count after the converter's RGB565)."""
    errors: list[str] = []
    h, w = a.shape[:2]
    if (w, h) != (sheet.width, sheet.height):
        errors.append(f"size {w}x{h}, expected {sheet.width}x{sheet.height} "
                      f"({sheet.frames} cells of {sheet.cell_w}x{sheet.cell_h})")
    q = q565(a)
    is_key = (a == KEY).all(axis=2)
    stray = (q == KEY565) & ~is_key
    if stray.any():
        errors.append(f"{int(stray.sum())} px turn into the #FF00FF key in RGB565 but are not #FF00FF")
    if sheet.transparent:
        opaque = ~is_key
        if not is_key.any():
            errors.append("no transparent pixels at all in a transparent sheet")
    else:
        opaque = np.ones((h, w), bool)
        if is_key.any():
            errors.append(f"{int(is_key.sum())} px of #FF00FF in an opaque sheet")
    ncol = len(np.unique(q[opaque]))
    ncol_shift = len(np.unique(q565_shift(a)[opaque]))
    if max(ncol, ncol_shift) > sheet.max_colors:
        errors.append(f"{ncol} opaque colours after RGB565 ({ncol_shift} with >>3 rounding), "
                      f"max {sheet.max_colors}{' plus the key' if sheet.transparent else ''}")
    info = (f"{sheet.name:16s} {w}x{h}  {sheet.frames} x {sheet.cell_w}x{sheet.cell_h}  "
            f"colours {ncol}/{sheet.max_colors}{' + key' if sheet.transparent else ' (opaque)'}")

    if (w, h) == (sheet.width, sheet.height):
        for i in range(sheet.frames):
            sl = slice(i * sheet.cell_w, (i + 1) * sheet.cell_w)
            cm = opaque[:, sl]
            label = f"cell {i} ({FRAME_NAMES.get(sheet.name, [''] * 99)[i]})"
            if sheet.transparent:
                if not cm.any():
                    errors.append(f"{label}: empty")
                    continue
                top = cm[0].copy()
                if "t" in sheet.edge_ok and sheet.edge_cols:
                    x0, x1 = sheet.edge_cols
                    top[x0 : x1 + 1] = False
                elif "t" in sheet.edge_ok:
                    top[:] = False
                bottom = cm[-1] if "b" not in sheet.edge_ok else np.zeros(sheet.cell_w, bool)
                if top.any() or bottom.any() or cm[:, 0].any() or cm[:, -1].any():
                    errors.append(f"{label}: drawing touches the cell edge (keep a 1 px empty border"
                                  f"{'; only the thread column may touch the top' if sheet.edge_cols else ''}"
                                  f"{'; only the bottom edge may be touched' if 'b' in sheet.edge_ok else ''})")
                if "b" in sheet.edge_ok and not cm[-1].any():
                    errors.append(f"{label}: nothing reaches the bottom edge (the arm must come in from below)")
            if sheet.tile:
                cq = q[:, sl]
                for axis, what in ((1, "left-right"), (0, "top-bottom")):
                    ok, seam, typ = seam_ok(cq, axis)
                    if not ok:
                        errors.append(f"{label}: does not tile {what}: seam mismatch {seam:.2f} "
                                      f"> sharpest inner edge {typ:.2f} + 0.05")
    if not quiet:
        print(info)
        for e in errors:
            print(f"{'':16s} ERROR {e}")
    return errors, ncol


# --------------------------------------------------------------------------
# --study: ingest a delivered art study (ASSETS.md section 8)
# --------------------------------------------------------------------------
def read_gpl(path: Path) -> list[tuple[int, int, int]]:
    cols = []
    for line in path.read_text().splitlines():
        parts = line.split()
        if len(parts) >= 3 and all(p.isdigit() for p in parts[:3]):
            cols.append(tuple(int(p) for p in parts[:3]))
    if not cols:
        raise SystemExit(f"{path}: no colours found in GIMP palette")
    return cols


def snap(rgb: np.ndarray, mask: np.ndarray, palette) -> np.ndarray:
    pal = np.array(palette, np.int32)
    d = ((rgb.astype(np.int32)[:, :, None, :] - pal[None, None]) ** 2).sum(axis=3)
    out = rgb.copy()
    out[mask] = pal[d.argmin(axis=2)][mask].astype(np.uint8)
    return out


def check_meta(name: str, sheet: Sheet, meta: dict) -> list[str]:
    """assets.json may describe each sheet; if it does, it must agree."""
    m = meta.get(name) or meta.get(name.removesuffix(".png")) or {}
    errs = []
    cell = m.get("cell") or m.get("cell_size")
    if cell:
        cw, ch = (cell["w"], cell["h"]) if isinstance(cell, dict) else tuple(cell)
        if (cw, ch) != (sheet.cell_w, sheet.cell_h):
            errs.append(f"assets.json cell {cw}x{ch} != manifest {sheet.cell_w}x{sheet.cell_h}")
    frames = m.get("frames") or m.get("frame_count")
    if isinstance(frames, list):
        frames = len(frames)
    if frames and frames != sheet.frames:
        errs.append(f"assets.json frames {frames} != manifest {sheet.frames}")
    return errs


def run_study(study: Path, snap_gpl: Path | None, hard_alpha: bool) -> int:
    if not study.is_dir():
        raise SystemExit(f"{study}: not a directory")
    meta_path = study / "assets.json"
    meta = json.loads(meta_path.read_text()) if meta_path.exists() else {}
    if not meta:
        print(f"note: {meta_path} missing or empty; checking the PNGs against the manifest only")
    palette = read_gpl(snap_gpl) if snap_gpl else None
    errors = found = 0
    for name, sheet in MANIFEST.items():
        src = study / "sheets" / name
        if not src.exists():
            print(f"{name:16s} not in study, assets/gen/{name} unchanged")
            continue
        found += 1
        rgba = np.array(Image.open(src).convert("RGBA"))
        rgb, alpha = rgba[:, :, :3].copy(), rgba[:, :, 3]
        errs = check_meta(name, sheet, meta)
        soft = int(((alpha > 0) & (alpha < 255)).sum())
        if soft:
            if hard_alpha:
                print(f"{name:16s} note: {soft} semi-transparent px cut at alpha 128 (--hard-alpha)")
            else:
                errs.append(f"{soft} semi-transparent px (alpha must be 0 or 255; --hard-alpha cuts at 128)")
        mask = alpha >= 128
        magenta = (rgb == KEY).all(axis=2) & mask
        if magenta.any():
            errs.append(f"{int(magenta.sum())} opaque #FF00FF px in the source (reserved for the key)")
        if palette:
            rgb = snap(rgb, mask, palette)
        if sheet.transparent:
            a = rgb.copy()
            a[~mask] = KEY
        else:
            if not mask.all():
                errs.append(f"{int((~mask).sum())} transparent px in an opaque sheet")
            a = rgb
        verrs, _ = validate(sheet, a)
        for e in errs:
            print(f"{'':16s} ERROR {e}")
        errs += verrs
        errors += len(errs)
        if not errs:
            save(a, name)
    for extra in sorted((study / "sheets").glob("*.png")) if (study / "sheets").is_dir() else []:
        if extra.name in NEVER_TOUCH:
            print(f"{extra.name:16s} ignored: comes from snouty-badge, never replaced here")
        elif extra.name not in MANIFEST and not extra.name.endswith("_indexed.png"):
            print(f"{extra.name:16s} note: not in the manifest, ignored")
    if not found:
        print(f"ERROR: no manifest sheets under {study}/sheets/")
        errors += 1
    return 1 if errors else 0


def save(a: np.ndarray, name: str) -> None:
    if name in NEVER_TOUCH:
        raise SystemExit(f"refusing to write {name}")
    Image.fromarray(a, "RGB").save(OUT / name, optimize=True)


# --------------------------------------------------------------------------
# Contact sheet: every sheet at 3x with frame captions, wall textures tiled
# 2x2, and three 160x128 mockups from a tiny raycaster over the test level.
# --------------------------------------------------------------------------
CONTACT_SCALE = 3
CONTACT_BG = (22, 20, 28)
CONTACT_INK = (220, 216, 228)
CONTACT_DIM = (150, 144, 160)


def load_gen(name: str) -> tuple[np.ndarray, np.ndarray]:
    a = np.array(Image.open(OUT / name).convert("RGB"))
    return a, ~(a == KEY).all(axis=2)


def checker(h: int, w: int, cell: int = 6) -> np.ndarray:
    yy, xx = np.mgrid[0:h, 0:w]
    out = np.empty((h, w, 3), np.uint8)
    out[:] = (46, 42, 56)
    out[((yy // cell + xx // cell) % 2).astype(bool)] = (60, 56, 72)
    return out


def blit(dst: np.ndarray, src: np.ndarray, mask: np.ndarray, x: int, y: int) -> None:
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
    s = MANIFEST[name] if name in MANIFEST else Sheet(name, a.shape[1], a.shape[0], 1, True)
    sl = slice(i * s.cell_w, (i + 1) * s.cell_w)
    return a[:, sl], m[:, sl]


def load_level(path: Path = ROOT / "cart" / "src" / "levels" / "test.txt") -> list[str]:
    rows = [l.rstrip("\r ") for l in path.read_text().split("\n")]
    rows = [l for l in rows if l and l[0] != "#"]
    w = max(map(len, rows))
    return [r.ljust(w, "#") for r in rows]


def raycast(level: list[str], px: float, py: float, deg: float,
            sprites: list[tuple[float, float, str, int, float, float]] = (),
            weapon: int | None = 3, face_i: int = 0) -> np.ndarray:
    """Very small stand-in for the cart renderer (PLAN.md contract A):
    66-degree FOV, 160 rays, perpendicular distance, h = 104 / dist, dark
    y faces, dimmer beyond 6 and 10 cells, fog beyond 24, closed doors on
    the cell midline. sprites: (x, y, sheet, cell, scale, lift) with lift
    in cells above the floor."""
    walls, _ = load_gen("walls.png")
    doors, _ = load_gen("doors.png")
    f = np.zeros((128, 160, 3), np.float32)
    for y in range(52):
        t = y / 51
        f[y] = np.array((46, 40, 58)) * (1 - t) + np.array((24, 20, 32)) * t
        f[103 - y] = np.array((62, 56, 70)) * (1 - t) + np.array((26, 22, 30)) * t
    H, W = len(level), len(level[0])
    a = math.radians(deg)
    dx, dy = math.cos(a), math.sin(a)
    k = math.tan(math.radians(33))
    plx, ply = -dy * k, dx * k
    depth = np.full(160, 99.0)
    fog = np.array((20, 16, 28), np.float32)

    def ch(x, y):
        return level[y][x] if 0 <= x < W and 0 <= y < H else "#"

    def is_wall(c):
        return c == "#" or c in "12345678"

    for x in range(160):
        cam = 2 * (x + 0.5) / 160 - 1
        rx, ry = dx + plx * cam, dy + ply * cam
        mx, my = int(px), int(py)
        ddx = abs(1 / rx) if rx else 1e30
        ddy = abs(1 / ry) if ry else 1e30
        sx, sdx = (-1, (px - mx) * ddx) if rx < 0 else (1, (mx + 1 - px) * ddx)
        sy, sdy = (-1, (py - my) * ddy) if ry < 0 else (1, (my + 1 - py) * ddy)
        hit = None
        for _ in range(64):
            if sdx < sdy:
                sdx += ddx
                mx += sx
                side = 0
            else:
                sdy += ddy
                my += sy
                side = 1
            c = ch(mx, my)
            if c in "DCIGE":
                vertical = not (is_wall(ch(mx - 1, my)) and is_wall(ch(mx + 1, my)))
                if vertical and rx:
                    t = (mx + 0.5 - px) / rx
                    hy = py + t * ry
                    if int(math.floor(hy)) == my and t > 0:
                        hit = (t, hy - my, doors, "DCIGE".index(c), 0)
                        break
                elif not vertical and ry:
                    t = (my + 0.5 - py) / ry
                    hx_ = px + t * rx
                    if int(math.floor(hx_)) == mx and t > 0:
                        hit = (t, hx_ - mx, doors, "DCIGE".index(c), 1)
                        break
                continue
            if is_wall(c):
                dist = (sdx - ddx) if side == 0 else (sdy - ddy)
                wx = (py + dist * ry) if side == 0 else (px + dist * rx)
                u = wx - math.floor(wx)
                if (side == 0 and rx > 0) or (side == 1 and ry < 0):
                    u = 1 - u
                tex = int(c) - 1 if c != "#" else 0
                hit = (dist, u, walls, tex, side)
                break
        if not hit:
            f[0:104, x] = fog
            continue
        dist, u, sheet, idx, side = hit
        depth[x] = dist
        if dist > 24:
            f[0:104, x] = fog
            continue
        mul = (0.72 if side else 1.0) * (0.72 if dist > 6 else 1.0) * (0.7 if dist > 10 else 1.0)
        h = 104 / max(dist, 1e-3)
        tx = min(31, int(u * 32))
        y0 = 52 - h / 2
        for y in range(max(0, int(y0)), min(104, int(52 + h / 2) + 1)):
            ty = int((y + 0.5 - y0) / h * 32)
            if 0 <= ty < 32:
                f[y, x] = sheet[ty, idx * 32 + tx] * mul
    # sprites, far to near, clipped against the wall depth per column
    inv = 1.0 / (plx * dy - dx * ply)
    order = sorted(sprites, key=lambda s: -((s[0] - px) ** 2 + (s[1] - py) ** 2))
    for sx_, sy_, name, cell, scale, lift in order:
        img, m = cell_of(name, cell)
        ox, oy = sx_ - px, sy_ - py
        tx_ = inv * (dy * ox - dx * oy)
        tz = inv * (-ply * ox + plx * oy)
        if tz <= 0.2:
            continue
        cx = 80 * (1 + tx_ / tz)
        unit = 104 / tz  # one cell in pixels at this depth
        hpx = img.shape[0] / 32 * unit * scale
        wpx = img.shape[1] / 32 * unit * scale
        bottom = 52 + unit / 2 - lift * unit
        for x in range(max(0, int(cx - wpx / 2)), min(160, int(cx + wpx / 2) + 1)):
            if tz >= depth[x]:
                continue
            u = int((x + 0.5 - (cx - wpx / 2)) / wpx * img.shape[1])
            if not 0 <= u < img.shape[1]:
                continue
            for y in range(max(0, int(bottom - hpx)), min(104, int(bottom) + 1)):
                v = int((y + 0.5 - (bottom - hpx)) / hpx * img.shape[0])
                if 0 <= v < img.shape[0] and m[v, u]:
                    f[y, x] = img[v, u] * (0.72 if tz > 6 else 1.0)
    out = f.clip(0, 255).astype(np.uint8)
    if weapon is not None:
        blit(out, *cell_of("weapons.png", weapon), 56, 72)
    out[104:128] = ANTIBLACK
    blit(out, *cell_of("hud.png", 7), 2, 108)
    out[118:122, 2:32] = RED
    blit(out, *cell_of("hud.png", 3), 34, 108)
    out[104, 64:96] = MIDDARK
    blit(out, *cell_of("face.png", face_i), 68, 104)
    for i in range(3):
        blit(out, *cell_of("hud.png", i), 98 + i * 8, 112)
    blit(out, *cell_of("hud.png", 5), 122, 104)
    out[114:120, 122:158] = PURPLE1
    out[114:120, 122:150] = PURPLE3
    return out


MOCKUPS = [
    ("gate view: (1.5, 22.5) facing east down the long corridor", 1.5, 22.5, 0.0,
     [(8.5, 22.5, "bug_gnat.png", 0, 1.0, 0.1), (11.5, 22.5, "pickups.png", 3, 1.0, 0),
      (16.5, 22.5, "pickups.png", 4, 1.0, 0), (21.5, 22.5, "pickups.png", 5, 1.0, 0),
      (5.5, 22.3, "projectiles.png", 0, 1.0, 0.4)], 3, 0),
    ("start room: facing the plain door (7, 4)", 3.5, 4.5, 0.0,
     [(5.5, 3.6, "pickups.png", 0, 1.0, 0)], 0, 5),
    ("row 8: facing north at the Iris door (20, 6)", 20.5, 8.5, 270.0,
     [(22.5, 7.5, "bug_spider.png", 0, 1.0, 0), (18.3, 7.6, "bug_boss.png", 2, 1.5, 0)], 6, 4),
]


def write_contact(path: Path) -> None:
    from PIL import ImageDraw, ImageFont
    k = CONTACT_SCALE
    font = ImageFont.load_default(size=14)
    small = ImageFont.load_default(size=10)
    blocks = []  # (label, image, captions [(x, text)])
    for name, s in MANIFEST.items():
        if not (OUT / name).exists():
            continue
        a, m = load_gen(name)
        img = checker(a.shape[0] * k, a.shape[1] * k)
        big = a.repeat(k, 0).repeat(k, 1)
        bm = m.repeat(k, 0).repeat(k, 1)
        img[bm] = big[bm]
        for i in range(1, s.frames):
            img[:, i * s.cell_w * k] = CONTACT_BG
        names = FRAME_NAMES.get(name, [])
        caps = [(i * s.cell_w * k + 2, f"{i} {names[i]}" if s.cell_w >= 24 and i < len(names) else str(i))
                for i in range(s.frames)]
        blocks.append((f"{name}   {s.frames} x {s.cell_w}x{s.cell_h}, shown {k}x", img, caps))
    if (OUT / "walls.png").exists():
        a, _ = load_gen("walls.png")
        tiles = [np.tile(a[:, i * 32 : (i + 1) * 32], (2, 2, 1)) for i in range(8)]
        gap = np.zeros((64, 4, 3), np.uint8)
        gap[:] = CONTACT_BG
        row = np.concatenate(sum([[t, gap] for t in tiles], [])[:-1], axis=1)
        blocks.append(("walls.png tiled 2x2 per texture (seams), shown 2x", row.repeat(2, 0).repeat(2, 1),
                       [(i * 136 + 2, FRAME_NAMES['walls.png'][i]) for i in range(8)]))
    level = load_level()
    shots = []
    for label, x, y, deg, spr, wpn, face_i in MOCKUPS:
        shots.append((label, raycast(level, x, y, deg, spr, wpn, face_i).repeat(k, 0).repeat(k, 1)))
    gapw = 12
    mock = np.zeros((128 * k, (160 * k + gapw) * len(shots) - gapw, 3), np.uint8)
    mock[:] = CONTACT_BG
    caps = []
    for i, (label, img) in enumerate(shots):
        mock[:, i * (160 * k + gapw) : i * (160 * k + gapw) + 160 * k] = img
        caps.append((i * (160 * k + gapw) + 2, label))
    blocks.append(("mockups 160x128 (Python raycaster stand-in, not the cart renderer), shown 3x", mock, caps))

    pad, label_h, cap_h = 12, 20, 14
    width = max(b[1].shape[1] for b in blocks) + 2 * pad
    height = sum(b[1].shape[0] + label_h + 2 + cap_h + pad for b in blocks) + pad
    out = np.zeros((height, width, 3), np.uint8)
    out[:] = CONTACT_BG
    y = pad
    texts = []
    for label, img, caps in blocks:
        texts.append((pad, y, label, font, CONTACT_INK))
        y += label_h
        out[y : y + img.shape[0], pad : pad + img.shape[1]] = img
        y += img.shape[0] + 2
        for cx, t in caps:
            texts.append((pad + cx, y, t, small, CONTACT_DIM))
        y += cap_h + pad
    im = Image.fromarray(out, "RGB")
    d = ImageDraw.Draw(im)
    for x, y, t, fnt, col in texts:
        d.text((x, y), t, fill=col, font=fnt)
    path.parent.mkdir(parents=True, exist_ok=True)
    im.save(path, optimize=True)
    print(f"contact sheet {path} {width}x{height}")


# --------------------------------------------------------------------------
# Modes
# --------------------------------------------------------------------------
def run_placeholders() -> int:
    errors = 0
    for name, sheet in MANIFEST.items():
        a = PLACEHOLDER_DRAW[name]()
        errs, _ = validate(sheet, a)
        errors += len(errs)
        if not errs:
            save(a, name)
    return 1 if errors else 0


def run_check() -> int:
    errors = 0
    for name, sheet in MANIFEST.items():
        a = np.array(Image.open(OUT / name).convert("RGB"))
        errors += len(validate(sheet, a)[0])
    return 1 if errors else 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    g = ap.add_mutually_exclusive_group()
    g.add_argument("--placeholders", action="store_true", help="draw stand-in art into assets/gen/")
    g.add_argument("--study", type=Path, help="import a delivered Snoutenstein_Study_NN folder")
    g.add_argument("--check", action="store_true", help="only validate the sheets in assets/gen/")
    ap.add_argument("--snap", type=Path, help="GIMP .gpl palette to snap study colours to")
    ap.add_argument("--hard-alpha", action="store_true",
                    help="cut semi-transparent study pixels at alpha 128 instead of failing")
    ap.add_argument("--contact", type=Path, metavar="PNG",
                    help="afterwards (or alone) write the 3x contact sheet, e.g. docs/placeholders.png")
    args = ap.parse_args()
    if not (args.placeholders or args.study or args.check or args.contact):
        ap.error("one of --placeholders, --study, --check or --contact is required")
    OUT.mkdir(parents=True, exist_ok=True)
    status = 0
    if args.placeholders:
        status = run_placeholders()
    elif args.study:
        status = run_study(args.study, args.snap, args.hard_alpha)
    elif args.check:
        status = run_check()
    if args.contact:
        write_contact(args.contact)
    return status


if __name__ == "__main__":
    sys.exit(main())
