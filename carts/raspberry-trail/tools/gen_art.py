#!/usr/bin/env python3
"""Paints every picture of The Raspberry Trail (SPEC 5) in code and writes
them as palette-indexed data for the cart.

Every picture is drawn at 1x on a pixel grid with the primitives below
(rectangles, polygons, ellipses, lines, ASCII sprites, checker dithers),
using only colours from the master palette MASTER. Each picture keeps its
own palette of at most 15 colours plus index 0 = transparent, and each
frame is stored either run-length encoded or as plain 4 bits per pixel,
whichever is smaller (ASSETS.md has the format).

Outputs (committed, read by cart/src/art/art.zig):
  cart/src/art/gen/art_data.zig   the Pic enum, sizes, frame and palette
                                  tables, layout constants
  cart/src/art/gen/art.bin        the pixel streams (@embedFile)
  docs/art_sheet.png              contact sheet, 1x and 3x (--sheet)

  tools/gen_art.py            # rewrite the generated data and the sheet
  tools/gen_art.py --check    # exit 1 if the committed data is stale
  tools/gen_art.py --png DIR  # also write every picture at 4x into DIR

The data is pure Python (no PIL needed for it or for --check); PIL draws
only the contact sheet and the --png previews.
"""
import argparse
import math
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
CART = os.path.normpath(os.path.join(HERE, ".."))
OUT_DIR = os.path.join(CART, "cart", "src", "art", "gen")
OUT_ZIG = os.path.join(OUT_DIR, "art_data.zig")
OUT_BIN = os.path.join(OUT_DIR, "art.bin")
OUT_CHECK = os.path.join(OUT_DIR, "art_check.zig")
OUT_SHEET = os.path.join(CART, "docs", "art_sheet.png")

# ----------------------------------------------------------------- palette
# The master palette. Every picture picks at most 15 of these.


def rgb(v):
    return ((v >> 16) & 255, (v >> 8) & 255, v & 255)


MASTER = {
    "INK": 0x1A1410,  # near-black, warm
    "BROWN_D": 0x3B2A20,
    "BROWN": 0x6B4A2F,
    "WOOD": 0xA0703F,
    "WOOD_L": 0xC9A06A,
    "PAPER": 0xF4E9D0,  # trail paper
    "PAPER_D": 0xE2D2AE,
    "WHITE": 0xFFFDF5,
    "GREY_D": 0x4E4A44,
    "GREY": 0x8A8478,
    "GREY_L": 0xBDB6A6,
    "RASP": 0xE30B5C,  # raspberry
    "RASP_D": 0x9E0842,
    "RASP_L": 0xF2558C,
    "RASP_P": 0xF8A5C2,
    "LEAF": 0x4C9A2A,
    "LEAF_D": 0x2E6B1E,
    "LEAF_L": 0x8CC152,
    "PINE": 0x1E4A2A,
    "GOLD": 0xC8B45A,  # dry prairie grass
    "GOLD_L": 0xE6D482,
    "SUN_O": 0xF29A3A,
    "SUN_Y": 0xF7D46B,
    "SUN_P": 0xE86A7A,
    "DUSK_P": 0x6A4A7A,
    "DUSK_V": 0x3E2E5A,
    "NIGHT": 0x22284A,
    "SKY": 0x8EC5E8,
    "SKY_L": 0xCFE6F2,
    "WATER": 0x3D7FB5,
    "WATER_D": 0x24527A,
    "MTN": 0x7A6A9A,
    "MTN_L": 0xA890B0,
    "FIRE_Y": 0xFFE070,
    "FIRE_O": 0xF28A1E,
    "FIRE_R": 0xD23A1A,
    "SKIN": 0xE0A878,
    "MURK": 0x6B7A3A,
    "MURK_D": 0x4A522A,
    "ICE": 0xDDEFF7,
    "ICE_B": 0xA8D0E6,
    "STORM": 0x5A6478,
    "STORM_L": 0x8A94A6,
}
for _k, _v in MASTER.items():
    globals()[_k] = rgb(_v)
T = None  # transparent


def to565(c):
    r, g, b = c
    return (r >> 3, g >> 2, b >> 3)


def from565(c):
    r, g, b = to565(c)
    return ((r << 3) | (r >> 2), (g << 2) | (g >> 4), (b << 3) | (b >> 2))


def display_bits(c):
    """The colour as cart-api DisplayColor bits: r in bits 0-4, g 5-10, b 11-15."""
    r, g, b = to565(c)
    return r | (g << 5) | (b << 11)


# ----------------------------------------------------------------- canvas


class Canvas:
    """A w x h grid of colours (None = transparent) with pixel-art tools.
    Coordinates are inclusive pixel indices; shapes are sets of (x, y)."""

    def __init__(self, w, h, fill=None):
        self.w, self.h = w, h
        self.p = [[fill] * w for _ in range(h)]

    def copy(self):
        c = Canvas(self.w, self.h)
        c.p = [row[:] for row in self.p]
        return c

    def get(self, x, y):
        if 0 <= x < self.w and 0 <= y < self.h:
            return self.p[y][x]
        return None

    def px(self, x, y, c):
        if 0 <= x < self.w and 0 <= y < self.h:
            self.p[y][x] = c

    def fill(self, pts, c):
        for x, y in pts:
            self.px(x, y, c)
        return pts

    def rect(self, x0, y0, x1, y1, c):
        return self.fill(rect(x0, y0, x1, y1), c)

    def hline(self, x0, x1, y, c):
        return self.rect(min(x0, x1), y, max(x0, x1), y, c)

    def vline(self, x, y0, y1, c):
        return self.rect(x, min(y0, y1), x, max(y0, y1), c)

    def line(self, x0, y0, x1, y1, c):
        return self.fill(line(x0, y0, x1, y1), c)

    def poly(self, pts, c):
        return self.fill(poly(pts), c)

    def ell(self, x0, y0, x1, y1, c):
        return self.fill(ellipse(x0, y0, x1, y1), c)

    def disk(self, cx, cy, r, c):
        return self.ell(cx - r, cy - r, cx + r, cy + r, c)

    def dither(self, pts, c, phase=0):
        for x, y in pts:
            if (x + y + phase) % 2 == 0:
                self.px(x, y, c)

    def sprite(self, x, y, art, key, flip=False, scale=1):
        rows = [r for r in art.strip("\n").split("\n")]
        rows = [r.strip() for r in rows]
        w = max(len(r) for r in rows)
        for j, r in enumerate(rows):
            for i, ch in enumerate(r):
                if ch == "." or ch == " ":
                    continue
                xx = x + (w - 1 - i if flip else i) * scale
                for a in range(scale):
                    for b in range(scale):
                        self.px(xx + a, y + j * scale + b, key[ch])

    def remap(self, m):
        for row in self.p:
            for i, c in enumerate(row):
                if c in m:
                    row[i] = m[c]

    def outline(self, c, diag=False, only_on=None):
        """Draws c on every transparent pixel next to an opaque one."""
        add = []
        for y in range(self.h):
            for x in range(self.w):
                if self.p[y][x] is not None:
                    continue
                nb = [(1, 0), (-1, 0), (0, 1), (0, -1)]
                if diag:
                    nb += [(1, 1), (-1, 1), (1, -1), (-1, -1)]
                for dx, dy in nb:
                    v = self.get(x + dx, y + dy)
                    if v is not None and v != c and (only_on is None or v in only_on):
                        add.append((x, y))
                        break
        for x, y in add:
            self.p[y][x] = c

    def blit(self, other, x, y):
        for j in range(other.h):
            for i in range(other.w):
                v = other.p[j][i]
                if v is not None:
                    self.px(x + i, y + j, v)

    def bands(self, x0, x1, stops, dither=True):
        """Horizontal bands: stops = [(y0, colour), ...] ascending; each
        boundary row pair gets a checker of the two colours."""
        for i, (y0, c) in enumerate(stops):
            y1 = stops[i + 1][0] - 1 if i + 1 < len(stops) else self.h - 1
            self.rect(x0, y0, x1, y1, c)
        if dither:
            for i in range(1, len(stops)):
                y = stops[i][0]
                c0 = stops[i - 1][1]
                self.dither(rect(x0, y, x1, y), c0, 0)

    def frame(self, c=None, corner=True):
        """1 px border (vignette framing) with clipped corners."""
        c = c or INK
        self.rect(0, 0, self.w - 1, 0, c)
        self.rect(0, self.h - 1, self.w - 1, self.h - 1, c)
        self.rect(0, 0, 0, self.h - 1, c)
        self.rect(self.w - 1, 0, self.w - 1, self.h - 1, c)
        if corner:
            for x, y in [(0, 0), (self.w - 1, 0), (0, self.h - 1), (self.w - 1, self.h - 1)]:
                self.p[y][x] = None
            for x, y in [(1, 1), (self.w - 2, 1), (1, self.h - 2), (self.w - 2, self.h - 2)]:
                self.p[y][x] = c


def rect(x0, y0, x1, y1):
    return {(x, y) for y in range(y0, y1 + 1) for x in range(x0, x1 + 1)}


def line(x0, y0, x1, y1):
    pts = set()
    dx, dy = abs(x1 - x0), -abs(y1 - y0)
    sx, sy = (1 if x0 < x1 else -1), (1 if y0 < y1 else -1)
    err = dx + dy
    while True:
        pts.add((x0, y0))
        if x0 == x1 and y0 == y1:
            break
        e2 = 2 * err
        if e2 >= dy:
            err += dy
            x0 += sx
        if e2 <= dx:
            err += dx
            y0 += sy
    return pts


def poly(pts):
    """Filled polygon, pixel centres inside (even-odd)."""
    out = set()
    ys = [p[1] for p in pts]
    n = len(pts)
    for y in range(int(math.floor(min(ys))), int(math.ceil(max(ys))) + 1):
        yc = y + 0.5
        xs = []
        for i in range(n):
            (xa, ya), (xb, yb) = pts[i], pts[(i + 1) % n]
            if (ya <= yc < yb) or (yb <= yc < ya):
                xs.append(xa + (yc - ya) * (xb - xa) / (yb - ya))
        xs.sort()
        for k in range(0, len(xs) - 1, 2):
            for x in range(int(math.ceil(xs[k] - 0.5)), int(math.floor(xs[k + 1] - 0.5)) + 1):
                out.add((x, y))
    return out


def ellipse(x0, y0, x1, y1):
    out = set()
    rx, ry = (x1 - x0 + 1) / 2, (y1 - y0 + 1) / 2
    cx, cy = x0 + rx, y0 + ry
    for y in range(y0, y1 + 1):
        t = (y + 0.5 - cy) / ry
        if abs(t) > 1:
            continue
        half = rx * math.sqrt(max(0.0, 1 - t * t))
        for x in range(x0, x1 + 1):
            if abs(x + 0.5 - cx) <= half + 0.01:
                out.add((x, y))
    return out


def border(pts, diag=False):
    """The pixels of a shape that touch the outside."""
    out = set()
    for x, y in pts:
        nb = [(1, 0), (-1, 0), (0, 1), (0, -1)]
        if diag:
            nb += [(1, 1), (-1, 1), (1, -1), (-1, -1)]
        for dx, dy in nb:
            if (x + dx, y + dy) not in pts:
                out.add((x, y))
                break
    return out


def shift(pts, dx, dy):
    return {(x + dx, y + dy) for x, y in pts}


def rng(seed):
    """Small deterministic LCG (stable across Python versions)."""
    s = [seed & 0xFFFFFFFF]

    def nxt(n):
        s[0] = (s[0] * 1103515245 + 12345) & 0x7FFFFFFF
        return (s[0] >> 8) % n

    return nxt


# ----------------------------------------------------------------- sprites
# Shared ASCII sprites. '.' is transparent.

OX_COLS = dict(body=WOOD, shade=BROWN, light=WOOD_L, head=WOOD, horn=PAPER, hoof=INK, line=INK)
OX_DARK = dict(body=BROWN, shade=BROWN_D, light=WOOD, head=BROWN, horn=PAPER_D, hoof=INK, line=INK)


def ox(frame=0, cols=None, outline=True):
    """An ox facing right on its own 30x18 canvas, ink outline, 2 leg frames."""
    c = cols or OX_COLS
    cv = Canvas(30, 18)
    body = rect(3, 4, 18, 11) | ellipse(1, 3, 9, 12) | ellipse(11, 2, 20, 12) | ellipse(4, 3, 18, 12)
    neck = poly([(16, 4), (21, 5), (23, 11), (17, 12)])
    head = ellipse(20, 4, 26, 11) | rect(23, 8, 27, 11)
    cv.fill(body | neck, c["body"])
    cv.fill({(x, y) for x, y in body if y >= 11}, c["shade"])
    cv.dither({(x, y) for x, y in body if y == 10}, c["shade"])
    cv.fill({(x, y) for x, y in body if (x, y - 1) not in body and 4 <= x <= 17}, c["light"])
    # dewlap under the neck
    cv.fill({(19, 12), (20, 12), (20, 13)}, c["shade"])
    cv.fill(head, c["head"])
    # the back of the head in shade so it reads apart from the neck
    cv.fill({(x, y) for x, y in head if (x - 1, y) not in head and y >= 6}, c["shade"])
    cv.fill(rect(25, 9, 27, 11), c["horn"])  # pale muzzle
    cv.px(27, 10, c["line"])  # nostril
    cv.px(23, 7, c["line"])  # eye
    # ear back, horn forward and up
    cv.fill({(19, 6), (20, 6), (18, 7)}, c["shade"])
    cv.fill({(21, 4), (22, 4), (22, 3), (23, 3), (23, 2), (24, 2), (25, 1)}, c["horn"])
    # tail
    cv.fill(line(1, 5, 0, 10), c["shade"])
    cv.px(0, 11, c["line"])
    # legs
    legs = [(3, 0), (7, 1), (13, 1), (17, 0)]
    for i, (lx, ph) in enumerate(legs):
        off = (1 if (ph + frame) % 2 else -1) if frame >= 0 else 0
        x0 = lx + (off if i % 2 == 0 else 0)
        cv.rect(x0, 12, x0 + 1, 15, c["shade"] if i in (1, 2) else c["body"])
        cv.rect(x0, 16, x0 + 1, 16, c["hoof"])
    if outline:
        cv.outline(c["line"])
    return cv


# ----------------------------------------------------------------- pictures
# Each painter returns a list of Canvas frames (all the same size).

PICS = []  # (name, doc, painter)
LAYOUT = {}  # name -> (x, y, w, h), exported as art.zig constants


def pic(name, doc):
    def reg(f):
        PICS.append((name, doc, f))
        return f

    return reg


# ---- title


def wheel(cv, cx, cy, r, spoke_phase=0, rim=INK, spoke=BROWN_D, hub=WOOD_L):
    d = ellipse(cx - r, cy - r, cx + r, cy + r)
    inner = ellipse(cx - r + 1, cy - r + 1, cx + r - 1, cy + r - 1)
    cv.fill(border(d), rim)
    n = 4
    for k in range(n):
        a = math.pi * k / n + spoke_phase * math.pi / (2 * n)
        ex, ey = round(cx + math.cos(a) * (r - 1)), round(cy + math.sin(a) * (r - 1))
        fx, fy = round(cx - math.cos(a) * (r - 1)), round(cy - math.sin(a) * (r - 1))
        cv.fill(line(ex, ey, fx, fy) & inner, spoke)
    cv.px(cx, cy, hub)


def covered_wagon(cv, x, y, frame=0):
    """A covered wagon facing right; (x, y) is the top-left of a 46x32 box."""
    # bonnet: the end bows lean out past the bed, the top sags a little
    bon = poly([(x + 6, y + 18), (x + 0, y + 3), (x + 0, y + 1), (x + 3, y - 1), (x + 12, y - 2), (x + 34, y - 2),
                (x + 43, y - 1), (x + 46, y + 1), (x + 46, y + 3), (x + 40, y + 18)])
    cv.fill(bon, RASP)
    # shading: lower part darker, highlight up top
    cv.fill({(px_, py_) for px_, py_ in bon if py_ >= y + 14}, RASP_D)
    cv.dither({(px_, py_) for px_, py_ in bon if py_ == y + 13}, RASP_D)
    cv.fill({(px_, py_) for px_, py_ in bon if py_ <= y + 3 and x + 5 <= px_ <= x + 40}, RASP_L)
    cv.dither({(px_, py_) for px_, py_ in bon if py_ == y + 4 and x + 5 <= px_ <= x + 40}, RASP_L)
    # bows (ribs), following the lean of the ends
    for bx, lean in ((x + 9, -2), (x + 17, -1), (x + 29, 1), (x + 37, 2)):
        cv.fill(line(bx + lean, y - 1, bx, y + 17) & bon, RASP_D)
    # the puckered rear opening
    cv.fill(ellipse(x + 1, y + 3, x + 4, y + 9) & bon, INK)
    cv.fill(border(bon), INK)
    # bed
    cv.rect(x + 4, y + 18, x + 42, y + 23, WOOD)
    cv.hline(x + 4, x + 42, y + 18, WOOD_L)
    cv.hline(x + 4, x + 42, y + 21, BROWN)
    cv.hline(x + 4, x + 42, y + 23, BROWN_D)
    cv.vline(x + 3, y + 18, y + 23, INK)
    cv.vline(x + 43, y + 18, y + 23, INK)
    cv.vline(x + 23, y + 19, y + 22, BROWN)
    # tongue to the oxen
    cv.hline(x + 44, x + 52, y + 22, BROWN_D)
    # wheels: big at the back, small at the front
    wheel(cv, x + 11, y + 24, 7, frame)
    wheel(cv, x + 36, y + 25, 6, frame)


@pic("title_bg", "Title background: sunset prairie, mountains, trail ruts")
def p_title_bg():
    cv = Canvas(160, 128)
    sky_bottom = 64
    cv.bands(0, 159, [(0, DUSK_V), (20, DUSK_P), (31, SUN_P), (42, SUN_O), (53, SUN_Y)])
    # sun setting in the west (right), behind the far range
    sun = ellipse(96, 38, 120, 62)
    cv.fill(sun, SUN_Y)
    cv.fill(ellipse(99, 41, 117, 59), WHITE)
    # far range with snow caps
    far = poly([(0, 58), (14, 50), (24, 54), (40, 41), (52, 50), (62, 46), (78, 56), (92, 47), (100, 52),
                (126, 38), (140, 50), (150, 46), (160, 52), (160, 66), (0, 66)])
    cv.fill(far, MTN_L)
    for peak, (px_, py_) in enumerate([(40, 41), (126, 38), (92, 47)]):
        cap = poly([(px_ - 6, py_ + 6), (px_, py_), (px_ + 6, py_ + 6), (px_ + 3, py_ + 5), (px_, py_ + 7), (px_ - 3, py_ + 5)])
        cv.fill(cap & far, WHITE)
    # near range, darker
    near = poly([(0, 60), (20, 53), (34, 58), (60, 52), (84, 60), (110, 54), (130, 59), (148, 55), (160, 58),
                 (160, 66), (0, 66)])
    cv.fill(near, MTN)
    # prairie
    cv.rect(0, sky_bottom - 2, 159, 127, GOLD)
    cv.dither(rect(0, sky_bottom - 2, 159, sky_bottom - 2), MTN)
    cv.rect(0, sky_bottom + 8, 159, 127, LEAF)
    cv.dither(rect(0, sky_bottom + 7, 159, sky_bottom + 8), GOLD)
    cv.rect(0, 100, 159, 127, LEAF_D)
    cv.dither(rect(0, 99, 159, 100), LEAF)
    # sunlit streaks in the gold band
    r = rng(3)
    for _ in range(26):
        sx, sy = r(160), sky_bottom - 1 + r(9)
        cv.hline(sx, sx + 2 + r(5), sy, SUN_Y)
    # trail ruts from the bottom left toward the horizon at the right
    ruts = poly([(0, 104), (0, 96), (60, 84), (124, 70), (140, 64), (144, 64), (132, 71), (70, 88), (20, 102)])
    cv.fill(ruts, WOOD_L)
    cv.fill(line(0, 99, 60, 87) | line(60, 87, 136, 67), GOLD)
    # grass tufts in the green
    for _ in range(40):
        tx, ty = r(160), 76 + r(22)
        if (tx, ty) in ruts:
            continue
        cv.px(tx, ty, LEAF_L)
        cv.px(tx + 1, ty - 1, LEAF_L)
    # foreground raspberry bushes at the corners (the menu goes in the middle)
    for bx, by in [(6, 108), (16, 116), (146, 110), (136, 118)]:
        b = ellipse(bx - 6, by - 4, bx + 6, by + 4)
        cv.fill(b, PINE)
        cv.fill(border(b) & rect(bx - 6, by - 4, bx + 6, by - 2), LEAF)
        rr = rng(bx * 7 + by)
        for _ in range(7):
            cv.px(bx - 4 + rr(9), by - 2 + rr(5), RASP)
    LAYOUT["title_menu"] = (34, 100, 92, 28)
    return [cv]


@pic("title_wagon", "Title sprite: the wagon and two oxen, wheels and legs in 2 frames")
def p_title_wagon():
    frames = []
    for f in range(2):
        cv = Canvas(90, 36)
        cv.blit(ox(1 - f, OX_DARK), 59, 15)
        cv.blit(ox(f), 54, 18)
        covered_wagon(cv, 1, 3, f)
        # yoke across the necks
        cv.rect(75, 19, 76, 24, BROWN_D)
        frames.append(cv)
    LAYOUT["title_wagon"] = (14, 59, 90, 36)
    return frames


# A blocky woodtype face for the logo, 7 wide x 9 tall.
LOGO_FONT = {
    "T": ["#######", "#######", "..###..", "..###..", "..###..", "..###..", "..###..", "..###..", "..###.."],
    "H": ["##...##", "##...##", "##...##", "#######", "#######", "##...##", "##...##", "##...##", "##...##"],
    "E": ["#######", "##.....", "##.....", "######.", "######.", "##.....", "##.....", "#######", "#######"],
    "R": ["######.", "##...##", "##...##", "##...##", "######.", "####...", "##.##..", "##..##.", "##...##"],
    "A": ["..###..", ".##.##.", "##...##", "##...##", "#######", "#######", "##...##", "##...##", "##...##"],
    "S": [".#####.", "##...##", "##.....", ".####..", "...###.", ".....##", "##...##", "##...##", ".#####."],
    "P": ["######.", "##...##", "##...##", "##...##", "######.", "##.....", "##.....", "##.....", "##....."],
    "B": ["######.", "##...##", "##...##", "######.", "######.", "##...##", "##...##", "##...##", "######."],
    "Y": ["##...##", "##...##", ".##.##.", "..###..", "..###..", "..###..", "..###..", "..###..", "..###.."],
    "I": ["#####", ".###.", ".###.", ".###.", ".###.", ".###.", ".###.", ".###.", "#####"],
    "L": ["##.....", "##.....", "##.....", "##.....", "##.....", "##.....", "##.....", "#######", "#######"],
}


def logo_word(word, scale_y=1):
    """Returns (pts, width) of a word in LOGO_FONT, 1 px apart."""
    pts, x = set(), 0
    for ch in word:
        g = LOGO_FONT[ch]
        for j, row in enumerate(g):
            for i, v in enumerate(row):
                if v == "#":
                    for s in range(scale_y):
                        pts.add((x + i, j * scale_y + s))
        x += len(g[0]) + 2
    return pts, x - 2


@pic("title_logo", "Title words THE RASPBERRY TRAIL, raspberry and cream woodtype")
def p_title_logo():
    w, h = 116, 40
    cv = Canvas(w, h)
    # RASPBERRY: 9 px tall letters stretched to 13
    rp, rw = logo_word("RASPBERRY", 1)
    rp = {(x, y + (y // 3)) for x, y in rp} | {(x, y + (y // 3) + 1) for x, y in rp if y % 3 == 2}
    tp, tw = logo_word("TRAIL", 1)
    tp = {(x, y + (y // 3)) for x, y in tp} | {(x, y + (y // 3) + 1) for x, y in tp if y % 3 == 2}
    ox_r = (w - rw) // 2
    ox_t = (w - tw) // 2
    yr, yt = 9, 25
    rp = shift(rp, ox_r, yr)
    tp = shift(tp, ox_t, yt)
    # drop shadow, then outline, then fill
    for pts, fill_c, hi in ((rp, RASP, RASP_L), (tp, PAPER, WHITE)):
        sh = shift(pts, 1, 1) | shift(pts, 2, 2)
        cv.fill(sh, INK)
    for pts, fill_c, hi in ((rp, RASP, RASP_L), (tp, PAPER, WHITE)):
        cv.fill(pts, fill_c)
        top = {(x, y) for x, y in pts if (x, y - 1) not in pts}
        cv.fill(top, hi)
        bot = {(x, y) for x, y in pts if (x, y + 1) not in pts}
        cv.fill(bot, RASP_D if fill_c == RASP else PAPER_D)
    # THE: small caps from the UI-ish 5x7 cut, cream
    the = {"T": ["#####", "..#..", "..#..", "..#..", "..#.."],
           "H": ["#...#", "#...#", "#####", "#...#", "#...#"],
           "E": ["#####", "#....", "####.", "#....", "#####"]}
    x = (w - 17) // 2
    pts = set()
    for ch in "THE":
        for j, row in enumerate(the[ch]):
            for i, v in enumerate(row):
                if v == "#":
                    pts.add((x + i, 1 + j))
        x += 6
    cv.fill(shift(pts, 1, 1), INK)
    cv.fill(pts, PAPER)
    # little rules either side of THE
    for x0, x1 in ((ox_r + 4, (w - 17) // 2 - 4), ((w + 17) // 2 + 3, ox_r + rw - 5)):
        cv.hline(x0, x1, 3, RASP_L)
        cv.hline(x0 + 1, x1 + 1, 4, INK)
    cv.outline(INK)
    LAYOUT["title_logo"] = ((160 - w) // 2, 3, w, h)
    return [cv]


# ---- trail strip

WAGON_ICON = """
...kkkkkk...
..kpppppkk..
.kpwppppppk.
.kppppppppk.
kkkkkkkkkkkk
.bbbbbbbbbb.
"""


@pic("strip_wagon", "Trail strip wagon icon facing right, 2 wheel frames")
def p_strip_wagon():
    frames = []
    for f in range(2):
        cv = Canvas(12, 9)
        cv.sprite(0, 0, WAGON_ICON, {"k": INK, "p": RASP, "w": RASP_P, "b": BROWN})
        for wx in (2, 9):
            if f == 0:
                cv.sprite(wx - 1, 6, "kgk\ngkg\nkgk", {"k": INK, "g": GREY_L})
            else:
                cv.sprite(wx - 1, 6, "gkg\nkgk\ngkg", {"k": INK, "g": GREY_L})
        frames.append(cv)
    return frames


@pic("mark_start", "Trail strip marker: Independence (a signpost)")
def p_mark_start():
    cv = Canvas(7, 9)
    cv.sprite(0, 0, """
kkkkkk.
kwwwwwk
kkkkkk.
..kb...
..kb...
..kb...
..kb...
..kb...
.kkkk..
""", {"k": INK, "w": PAPER, "b": WOOD})
    return [cv]


@pic("mark_pass", "Trail strip marker: South Pass (a bare mountain pass)")
def p_mark_pass():
    cv = Canvas(11, 9)
    cv.sprite(0, 0, """
...k.......
..kgk...k..
.kgggk.kgk.
.kgggkkgggk
kgggggkgggk
kggggggggggk
""".replace("kggggggggggk", "kgggggggggk"), {"k": INK, "g": WOOD})
    cv.sprite(0, 6, """
kgggggggggk
kgggggggggk
kkkkkkkkkkk
""", {"k": INK, "g": WOOD})
    cv.px(3, 1, WOOD_L)
    cv.px(8, 2, WOOD_L)
    return [cv]


@pic("mark_mountains", "Trail strip marker: Blue Mountains (snowy blue peaks)")
def p_mark_mountains():
    cv = Canvas(11, 9)
    cv.sprite(0, 0, """
....k......
...kwk.....
..kwwwk.k..
..kmwmkkwk.
.kmmmmkmwmk
.kmmmmmmmmk
kmmmmmmmmmk
kmmmmmmmmmk
kkkkkkkkkkk
""", {"k": INK, "w": WHITE, "m": WATER})
    return [cv]


@pic("mark_fort", "Trail strip marker: a fort (palisade and flag)")
def p_mark_fort():
    cv = Canvas(9, 9)
    cv.sprite(0, 0, """
....krrr.
....krr..
....k....
.k.kkk.k.
kbkbbbkbk
kbbbbbbbk
kbbbkbbbk
kbbkkkbbk
kkkkkkkkk
""", {"k": INK, "b": WOOD, "r": RASP})
    return [cv]


@pic("mark_city", "Trail strip marker: Oregon City (cabin under a pine)")
def p_mark_city():
    cv = Canvas(11, 9)
    cv.sprite(0, 0, """
........k..
.......kgk.
...k...kgk.
..krk.kgggk
.krrrk.kgk.
krrrrrkkgggk
.kbbbk..kk.
.kbkbk..kk.
kkkkkkkkkkk
""".replace("krrrrrkkgggk", "krrrrrkgggk"), {"k": INK, "r": RASP, "b": WOOD, "g": LEAF})
    return [cv]


# ---- button glyphs

GLYPH_SHAPES = {
    "up": ["...#...", "..###..", ".#####.", "#######", "..###..", "..###..", "..###.."],
    "down": ["..###..", "..###..", "..###..", "#######", ".#####.", "..###..", "...#..."],
    "left": ["...#...", "..##...", ".######", "#######", ".######", "..##...", "...#..."],
    "right": ["...#...", "...##..", "######.", "#######", "######.", "...##..", "...#..."],
    "a": ["..###..", ".##.##.", "##...##", "##...##", "#######", "##...##", "##...##"],
    "b": ["######.", "##...##", "##...##", "######.", "##...##", "##...##", "######."],
}


def glyph_frames(name):
    frames = []
    for state in range(3):  # 0 normal, 1 highlighted (the one to press), 2 done
        cv = Canvas(14, 14)
        face, ink, edge = {0: (PAPER, INK, PAPER_D), 1: (RASP, WHITE, RASP_D), 2: (LEAF, WHITE, LEAF_D)}[state]
        dy = 0 if state != 2 else 1
        cap = rect(1, 0 + dy, 12, 11 + dy) - {(1, dy), (12, dy), (1, 11 + dy), (12, 11 + dy)}
        if state != 2:
            base = shift(cap, 0, 2)
            cv.fill(base, INK)
        cv.fill(cap, face)
        cv.fill({(x, y) for x, y in cap if y == 11 + dy}, edge)
        cv.fill(border(cap, diag=False), INK)
        for j, row in enumerate(GLYPH_SHAPES[name]):
            for i, v in enumerate(row):
                if v == "#":
                    cv.px(3 + i, 2 + dy + j, ink)
        frames.append(cv)
    return frames


for _g in ("up", "down", "left", "right", "a", "b"):
    pic("btn_" + _g, "Shooting cue button %s: frame 0 normal, 1 highlighted, 2 done" % _g.upper())(
        (lambda n: lambda: glyph_frames(n))(_g))


# ---- event vignettes (64x40, framed)

VW, VH = 64, 40


def vig(sky, ground, horizon=26, sky2=None, ground2=None):
    """A framed vignette canvas with a sky and a ground band."""
    cv = Canvas(VW, VH)
    stops = [(0, sky)] + ([(horizon // 2, sky2)] if sky2 else [])
    cv.bands(0, VW - 1, stops)
    cv.rect(0, horizon, VW - 1, VH - 1, ground)
    if ground2:
        cv.rect(0, horizon + (VH - horizon) // 2, VW - 1, VH - 1, ground2)
        cv.dither(rect(0, horizon + (VH - horizon) // 2, VW - 1, horizon + (VH - horizon) // 2), ground)
    return cv


def done(cv):
    cv.frame(INK)
    return cv


def small_wheel(cv, cx, cy, r, phase=0):
    d = ellipse(cx - r, cy - r, cx + r, cy + r)
    cv.fill(border(d), INK)
    if phase % 2 == 0:
        cv.fill((line(cx - r + 1, cy, cx + r - 1, cy) | line(cx, cy - r + 1, cx, cy + r - 1)) - border(d), BROWN_D)
    else:
        cv.fill((line(cx - r + 1, cy - r + 1, cx + r - 1, cy + r - 1) | line(cx - r + 1, cy + r - 1, cx + r - 1, cy - r + 1))
                & ellipse(cx - r + 1, cy - r + 1, cx + r - 1, cy + r - 1), BROWN_D)


def small_wagon(cv, x, y, frame=0, canopy=RASP, canopy_d=RASP_D, canopy_l=RASP_L, wheels=True, tilt=0):
    """A 31x20 covered wagon facing right. tilt > 0 sinks the front."""
    def t(px_, py_):
        return (px_, py_ + (tilt * (px_ - x) // 30 if tilt else 0))
    bon = poly([t(x + 4, y + 12), t(x + 0, y + 2), t(x + 2, y + 0), t(x + 8, y - 1), t(x + 23, y - 1), t(x + 29, y + 0),
                t(x + 31, y + 2), t(x + 27, y + 12)])
    cv.fill(bon, canopy)
    top = min(py_ for _, py_ in bon)
    cv.fill({q for q in bon if q[1] >= t(q[0], y + 9)[1]}, canopy_d)
    if canopy_l:
        cv.fill({q for q in bon if q[1] <= t(q[0], y + 1)[1] and x + 4 <= q[0] <= x + 26}, canopy_l)
    for bx in (x + 10, x + 21):
        cv.fill(line(*t(bx, y - 1), *t(bx, y + 11)) & bon, canopy_d)
    cv.fill(border(bon), INK)
    bed = poly([t(x + 2, y + 12), t(x + 30, y + 12), t(x + 30, y + 16), t(x + 2, y + 16)])
    cv.fill(bed, WOOD)
    cv.fill({q for q in bed if q[1] == t(q[0], y + 15)[1] or q[1] == t(q[0], y + 16)[1]}, BROWN)
    cv.fill(border(bed) & {q for q in bed if q[0] in (x + 2, x + 30)}, INK)
    if wheels:
        small_wheel(cv, *t(x + 8, y + 16), 4, frame)
        small_wheel(cv, *t(x + 25, y + 16), 4, frame)
    return bon | bed


@pic("v_wagon_breaks", "Vignette: wagon breakdown, the front wheel off and broken")
def p_v_wagon_breaks():
    cv = vig(SKY, GOLD, 24, SKY_L, LEAF)
    small_wagon(cv, 8, 13, tilt=5, wheels=False)
    small_wheel(cv, 16, 30, 4)
    # front corner on the ground; the wheel lies flat, spokes scattered
    cv.fill(border(ellipse(40, 31, 54, 35)), INK)
    cv.fill(ellipse(41, 32, 53, 34) - border(ellipse(40, 31, 54, 35)), GOLD)
    cv.px(47, 33, BROWN_D)
    cv.line(36, 36, 39, 34, BROWN_D)
    cv.line(55, 30, 58, 31, BROWN_D)
    cv.line(50, 28, 52, 26, BROWN_D)
    # a "crack" burst
    for dx, dy in ((0, -3), (2, -2), (-2, -2), (3, 0), (-3, 0)):
        cv.px(41 + dx, 22 + dy, WHITE)
    return [done(cv)]


@pic("v_ox_injured", "Vignette: an injured ox lying down, a bandaged leg")
def p_v_ox_injured():
    cv = vig(SKY, LEAF, 24, SKY_L, LEAF_D)
    o = ox(-1, outline=False)
    # lay it down: drop the legs, keep the body
    lying = Canvas(30, 18)
    for y in range(18):
        for x in range(30):
            v = o.p[y][x]
            if v is not None and y <= 12:
                lying.px(x, y + 3, v)
    lying.rect(13, 14, 17, 15, WOOD)  # folded front leg
    lying.rect(14, 14, 15, 15, PAPER)  # bandage
    lying.px(16, 14, RASP)
    lying.outline(INK)
    cv.blit(lying, 16, 12)
    # a sad sweat drop
    cv.fill({(46, 10), (45, 11), (46, 11), (45, 12), (46, 12)}, SKY_L)
    cv.px(46, 12, WHITE)
    return [done(cv)]


@pic("v_ox_wanders", "Vignette: an ox wanders off; an empty yoke and a question mark")
def p_v_ox_wanders():
    cv = vig(SKY, GOLD, 18, SKY_L, LEAF)
    # tiny ox far away on the horizon
    cv.sprite(45, 11, """
.......w.
.......kk
kbbbbbbkkk
.bbbbbbbk.
.b.b..b.b.
""", {"k": BROWN_D, "b": BROWN, "w": PAPER})
    # empty yoke and a loose rope in front
    cv.rect(6, 30, 26, 31, WOOD)
    cv.hline(6, 26, 32, BROWN_D)
    for bx in (10, 22):
        cv.fill(border(ellipse(bx - 3, 29, bx + 3, 37)) & rect(bx - 3, 32, bx + 3, 37), BROWN_D)
    cv.line(26, 31, 34, 35, WOOD_L)
    cv.line(34, 35, 40, 33, WOOD_L)
    # hoofprints leading away
    for i, (hx, hy) in enumerate([(42, 34), (45, 29), (47, 25), (49, 21), (50, 18)]):
        cv.px(hx, hy, BROWN_D)
        if i < 3:
            cv.px(hx + 1, hy, BROWN_D)
    # question mark
    cv.sprite(28, 4, """
.kkkk.
kk..kk
....kk
...kk.
..kk..
......
..kk..
""", {"k": RASP})
    return [done(cv)]


@pic("v_daughter_arm", "Vignette: a broken arm in a white sling (no gore)")
def p_v_daughter_arm():
    cv = vig(PAPER, PAPER_D, 32)
    # a wagon wheel behind
    cv.fill(border(ellipse(36, 8, 60, 32)), WOOD)
    cv.fill(border(ellipse(37, 9, 59, 31)), WOOD)
    for a in range(0, 180, 30):
        r = math.radians(a)
        cv.line(48 + round(math.cos(r) * 11), 20 + round(math.sin(r) * 11),
                48 - round(math.cos(r) * 11), 20 - round(math.sin(r) * 11), WOOD_L)
    cv.disk(48, 20, 2, BROWN)
    # a girl in a bonnet and calico dress
    f = Canvas(VW, VH)
    f.ell(15, 4, 27, 15, RASP)  # bonnet
    f.ell(18, 7, 25, 15, SKIN)  # face
    f.px(20, 11, INK)
    f.px(23, 11, INK)
    f.px(21, 13, RASP_D)
    f.px(22, 13, RASP_D)
    f.poly([(14, 38), (17, 17), (26, 17), (30, 38)], RASP_D)  # dress
    f.dither(rect(15, 18, 29, 38) & poly([(14, 38), (17, 17), (26, 17), (30, 38)]), RASP, 1)
    f.rect(17, 30, 27, 30, PAPER)  # apron hem
    # left arm hanging
    f.rect(13, 19, 14, 29, SKIN)
    # sling: strap over the shoulder, a white triangle holding the forearm
    f.line(19, 16, 25, 23, WHITE)
    f.line(20, 16, 26, 23, WHITE)
    f.poly([(16, 22), (31, 22), (28, 28), (19, 27)], WHITE)
    f.rect(27, 22, 30, 24, SKIN)  # hand peeking out
    f.hline(17, 29, 27, PAPER_D)
    f.outline(INK)
    cv.blit(f, 0, 0)
    return [done(cv)]


@pic("v_son_lost", "Vignette: searching for the lost son at night, lantern and footprints")
def p_v_son_lost():
    frames = []
    for fr in range(2):
        cv = vig(NIGHT, PINE, 24, DUSK_V)
        r = rng(11)
        for _ in range(14):
            cv.px(r(64), r(20), PAPER if r(3) else SUN_Y)
        cv.disk(52, 7, 3, PAPER)
        cv.disk(53, 6, 2, DUSK_V)
        # pine silhouettes
        for tx, th in ((4, 12), (12, 16), (58, 14)):
            cv.poly([(tx - 4, 26), (tx, 26 - th), (tx + 4, 26)], INK)
        # footprints wandering off to the right
        for i, (fx, fy) in enumerate([(30, 36), (35, 34), (39, 33), (44, 31), (48, 30), (52, 29), (55, 28)]):
            cv.rect(fx, fy - (i % 2), fx + 1, fy - (i % 2), BROWN)
        # lantern glow and the lantern
        g = 0 if fr == 0 else 1
        cv.dither(ellipse(3 + g, 22 + g, 31 - g, 40 - g) & rect(1, 1, 62, 38), MURK)
        cv.fill(ellipse(8 + g, 25 + g, 26 - g, 37 - g) & rect(1, 1, 62, 38), MURK)
        # the searcher holding the lantern out
        cv.sprite(18, 17, """
.kkk.
kkkkk
.kkk.
.kkk.
kkkkkk
kkkkk.
kkkkk.
.kkk..
.k.k..
.k.k..
.k..k.
""", {"k": INK})
        cv.hline(23, 25, 21, INK)
        cv.sprite(24, 21, """
..kk..
.k..k.
kkkkkk
kyyyyk
kywwyk
kyyyyk
kkkkkk
""".replace("..kk..", "...k..").replace(".k..k.", "..kk.."), {"k": INK, "y": FIRE_Y if fr == 0 else FIRE_O, "w": WHITE})
        frames.append(done(cv))
    return frames


@pic("v_bad_water", "Vignette: a murky pond with bubbles and a warning sign")
def p_v_bad_water():
    cv = vig(SKY, GOLD, 18, SKY_L)
    pond = ellipse(4, 22, 58, 39)
    cv.fill(pond, MURK)
    cv.fill(border(pond), MURK_D)
    cv.dither(ellipse(10, 27, 50, 37), MURK_D)
    for bx, by, r in ((20, 29, 1), (34, 32, 2), (42, 27, 1), (27, 34, 1)):
        cv.fill(border(ellipse(bx - r, by - r, bx + r, by + r)), LEAF_L)
    # cattails
    for cx in (6, 9, 56):
        cv.vline(cx, 15, 25, LEAF_D)
        cv.rect(cx, 15, cx, 18, BROWN)
    # sign with a skull-and-crossbones mark
    cv.vline(50, 12, 24, BROWN_D)
    cv.rect(43, 5, 57, 14, WOOD)
    cv.fill(border(rect(43, 5, 57, 14)), BROWN_D)
    cv.sprite(47, 6, """
.www.
wkwkw
.www.
w.w.w
.w.w.
w...w
""", {"w": PAPER, "k": INK})
    return [done(cv)]


@pic("v_heavy_rain", "Vignette: heavy rain over the wagon, 2 frames")
def p_v_heavy_rain():
    frames = []
    for fr in range(2):
        cv = vig(STORM, LEAF_D, 28, STORM_L)
        for cx, cy, rx in ((10, 2, 14), (34, 0, 16), (56, 3, 12)):
            cv.ell(cx - rx, cy - 5, cx + rx, cy + 6, STORM)
        small_wagon(cv, 16, 14)
        # puddles
        cv.hline(4, 12, 36, SKY)
        cv.hline(44, 56, 34, SKY)
        r = rng(5)
        for _ in range(26):
            x0, y0 = r(70) - 6, r(40)
            y0 = (y0 + fr * 5) % 40
            cv.fill(line(x0, y0, x0 - 2, y0 + 4) & rect(1, 1, 62, 38), SKY_L)
        frames.append(done(cv))
    return frames


@pic("v_hail", "Vignette: hail stones bouncing around the wagon, 2 frames")
def p_v_hail():
    frames = []
    for fr in range(2):
        cv = vig(STORM, LEAF, 28, STORM_L)
        for cx, cy, rx in ((12, 1, 15), (36, 0, 14), (58, 2, 12)):
            cv.ell(cx - rx, cy - 5, cx + rx, cy + 6, STORM)
        small_wagon(cv, 16, 14)
        r = rng(8)
        for _ in range(22):
            x0, y0 = r(62) + 1, r(38)
            y0 = (y0 + fr * 6) % 36 + 1
            cv.fill(rect(x0, y0, x0 + 1, y0 + 1), WHITE)
            cv.px(x0 + 1, y0 + 1, ICE_B)
        # stones lying on the grass
        for x0 in range(3, 60, 7):
            cv.px(x0 + (x0 * 3) % 4, 33 + (x0 % 5), WHITE)
        frames.append(done(cv))
    return frames


@pic("v_fire", "Vignette: fire in the wagon, flames and smoke, 2 frames")
def p_v_fire():
    frames = []
    for fr in range(2):
        cv = vig(DUSK_P, BROWN, 30, SUN_P, BROWN_D)
        small_wagon(cv, 16, 15, canopy=PAPER_D, canopy_d=GREY_L, canopy_l=None)
        # smoke
        for i, (sx, sy, rr) in enumerate(((30, 6, 5), (38, 3, 4), (24, 3, 3), (44, 1, 3))):
            cv.disk(sx + fr, sy, rr, GREY_D if i % 2 else GREY)
        # flames rising from the canopy
        r = rng(21 + fr)
        for k in range(9):
            fx = 18 + k * 3 + r(2)
            fh = 6 + r(8)
            base = 18
            cv.poly([(fx - 2, base), (fx + (r(3) - 1), base - fh), (fx + 3, base)], FIRE_R)
            cv.poly([(fx - 1, base), (fx + 1, base - fh + 3), (fx + 2, base)], FIRE_O)
            if fh > 9:
                cv.vline(fx, base - fh + 6, base - 1, FIRE_Y)
        frames.append(done(cv))
    return frames


@pic("v_fog", "Vignette: the wagon fading into fog")
def p_v_fog():
    cv = vig(GREY_L, GREY, 30)
    small_wagon(cv, 18, 13, canopy=GREY, canopy_d=GREY_D, canopy_l=GREY_L)
    # mute the whole wagon: no ink, no wood
    for y in range(VH):
        for x in range(VW):
            if cv.p[y][x] in (INK, BROWN_D):
                cv.p[y][x] = GREY_D
            elif cv.p[y][x] in (WOOD, BROWN):
                cv.p[y][x] = GREY
    for y0, y1 in ((3, 5), (34, 36)):
        cv.rect(1, y0, 62, y1, PAPER)
        cv.dither(rect(1, y0 - 1, 62, y0 - 1) | rect(1, y1 + 1, 62, y1 + 1), PAPER)
    cv.dither(rect(1, 9, 62, 10), PAPER)
    cv.dither(rect(1, 19, 62, 20), PAPER, 1)
    cv.dither(rect(1, 28, 62, 29), PAPER)
    return [done(cv)]


@pic("v_snake", "Vignette: a coiled rattlesnake, head up")
def p_v_snake():
    cv = vig(SKY, GOLD, 20, SKY_L, WOOD_L)
    # rocks
    cv.ell(44, 22, 60, 32, GREY)
    cv.ell(46, 22, 56, 27, GREY_L)
    cv.fill(border(ellipse(44, 22, 60, 32)), GREY_D)
    s = Canvas(VW, VH)
    # coils, back to front
    for (x0, y0, x1, y1) in ((10, 29, 38, 37), (13, 25, 35, 33), (17, 21, 31, 29)):
        e = ellipse(x0, y0, x1, y1)
        s.fill(e, GOLD_L if False else SUN_O)
        s.fill(ellipse(x0 + 3, y0 + 2, x1 - 3, y1 - 2), None)
        for k, (px_, py_) in enumerate(sorted(e)):
            pass
    # diamonds on the coils
    for (px_, py_) in list((x, y) for y in range(40) for x in range(64) if s.get(x, y) is not None):
        if (px_ // 2 + py_) % 4 == 0:
            s.px(px_, py_, BROWN)
    # neck rising and the head
    s.poly([(28, 22), (31, 22), (33, 12), (30, 12)], SUN_O)
    s.ell(29, 7, 37, 13, SUN_O)
    s.px(34, 9, INK)
    s.fill({(38, 11), (39, 11), (40, 10), (40, 12)}, RASP)  # tongue
    # rattle
    s.fill({(9, 33), (8, 33), (7, 32), (6, 32), (5, 31)}, WOOD_L)
    s.outline(INK)
    cv.blit(s, 0, 0)
    return [done(cv)]


@pic("v_river", "Vignette: the wagon swamped in a river crossing, 2 frames")
def p_v_river():
    frames = []
    for fr in range(2):
        cv = vig(SKY, LEAF, 12, SKY_L)
        cv.rect(0, 16, 63, 39, WATER)
        cv.dither(rect(0, 16, 63, 17), LEAF)
        small_wagon(cv, 16, 11 + fr, tilt=4)
        # water over the bed and wheels
        cv.rect(1, 25 + fr, 62, 38, WATER)
        for y0 in range(21 + fr, 39, 4):
            for x0 in range((y0 * 5 + fr * 3) % 8, 63, 8):
                cv.hline(x0, x0 + 3, y0, SKY_L if y0 < 30 else WATER_D)
        # splashes and a floating barrel
        for sx, sy in ((14, 22), (48, 21)):
            cv.fill({(sx, sy), (sx - 1, sy - 1), (sx + 1, sy - 1), (sx, sy - 2)}, WHITE)
        cv.rect(52, 29 + fr, 56, 32 + fr, WOOD)
        cv.hline(52, 56, 30 + fr, BROWN_D)
        cv.fill(border(rect(52, 29 + fr, 56, 32 + fr)) - {(52, 29 + fr), (56, 29 + fr)}, INK)
        frames.append(done(cv))
    return frames


WOLF = """
...............k.k..
...............kkk..
..............kkkkkk
.kkkkkkkkkkkkkkkkk..
kkkkkkkkkkkkkkkkk...
kk.kkkkkkkkkkkkk....
k..kkkkkkkkkkkk.....
...kk.kk...kk.kk....
...kk..kk..kk..kk...
"""

WOLF_HOWL = """
...........k....
..........kk....
.........kkk....
........kkkk....
......k.kkkk....
......kkkkkk....
......kkkkk.....
.....kkkkkk.....
.....kkkkkkk....
....kkkkkkkk....
...kkkkkkkkk....
..kkkkkkk.kk....
.kkkkkkkk.kk....
kkkkkkkkk.kk....
kkkkkkkk..kk....
kkkkkkkkkkkkk...
"""


@pic("v_wild_animals", "Vignette: wolves on a ridge at dusk, one howling at the moon")
def p_v_wild_animals():
    cv = vig(DUSK_P, PINE, 28, SUN_P)
    cv.disk(24, 11, 9, PAPER)
    cv.disk(20, 7, 1, PAPER_D)
    cv.disk(28, 14, 1, PAPER_D)
    ridge = poly([(0, 30), (12, 24), (30, 22), (44, 26), (64, 24), (64, 40), (0, 40)])
    cv.fill(ridge, INK)
    cv.sprite(16, 7, WOLF_HOWL, {"k": INK})
    cv.fill(line(15, 22, 9, 24), INK)  # tail along the ground
    cv.sprite(36, 15, WOLF, {"k": INK})
    cv.px(52, 17, SUN_Y)  # eyes catching the light
    cv.sprite(0, 20, WOLF, {"k": INK}, flip=True)
    cv.px(3, 22, SUN_Y)
    return [done(cv)]


@pic("v_cold", "Vignette: bitter cold, icicles and a low thermometer")
def p_v_cold():
    cv = vig(ICE_B, ICE, 26, SKY_L)
    # icicles hanging from the top
    r = rng(4)
    for x0 in range(2, 62, 4):
        hgt = 4 + r(8)
        cv.poly([(x0, 1), (x0 + 3, 1), (x0 + 1.5, 1 + hgt)], WHITE)
        cv.vline(x0 + 2, 2, 1 + hgt // 2, ICE_B)
    cv.rect(1, 1, 62, 2, WHITE)
    # thermometer
    cv.rect(26, 8, 32, 34, WHITE)
    cv.fill(border(rect(26, 8, 32, 34)), INK)
    cv.disk(29, 33, 4, RASP)
    cv.fill(border(ellipse(25, 29, 33, 37)), INK)
    cv.rect(28, 26, 30, 31, RASP)
    for ty in range(11, 30, 3):
        cv.hline(33, 34, ty, INK)
    # snowflakes
    for sx, sy in ((10, 16), (48, 12), (54, 28), (14, 32), (42, 34)):
        cv.fill({(sx, sy), (sx - 1, sy), (sx + 1, sy), (sx, sy - 1), (sx, sy + 1)}, WHITE)
        cv.fill({(sx - 1, sy - 1), (sx + 1, sy + 1), (sx + 1, sy - 1), (sx - 1, sy + 1)}, ICE_B)
    return [done(cv)]


@pic("v_blizzard", "Vignette: a blizzard burying the wagon, 2 frames")
def p_v_blizzard():
    frames = []
    for fr in range(2):
        cv = vig(STORM, WHITE, 28, STORM_L)
        small_wagon(cv, 16, 14, canopy=RASP, canopy_d=RASP_D, canopy_l=WHITE)
        drift = poly([(0, 27), (12, 26), (22, 31), (34, 29), (46, 32), (56, 28), (64, 29), (64, 40), (0, 40)])
        cv.fill(drift, WHITE)
        cv.fill({q for q in border(drift) if (q[0], q[1] - 1) not in drift}, ICE_B)
        r = rng(9)
        for _ in range(40):
            x0, y0 = r(64), r(40)
            x0 = (x0 + fr * 4) % 64
            y0 = (y0 + fr * 2) % 40
            cv.fill(line(x0, y0, x0 + 2, y0 + 1) & rect(1, 1, 62, 38), WHITE)
        frames.append(done(cv))
    return frames


@pic("v_mountains", "Vignette: rugged mountains and a switchback trail")
def p_v_mountains():
    cv = vig(SKY, GREY, 30, SKY_L)
    back = poly([(0, 28), (10, 10), (18, 18), (30, 3), (42, 16), (50, 8), (64, 22), (64, 40), (0, 40)])
    cv.fill(back, MTN)
    for px_, py_ in ((10, 10), (30, 3), (50, 8)):
        cv.fill(poly([(px_ - 4, py_ + 5), (px_, py_), (px_ + 4, py_ + 5), (px_, py_ + 3)]) & back, WHITE)
    front = poly([(0, 34), (8, 22), (20, 30), (34, 16), (48, 30), (58, 24), (64, 30), (64, 40), (0, 40)])
    cv.fill(front, GREY_D)
    cv.fill({q for q in front if (q[0] + q[1]) % 7 == 0}, GREY)
    # light faces
    cv.fill(poly([(34, 16), (48, 30), (40, 30)]) & front, GREY)
    cv.fill(poly([(8, 22), (20, 30), (14, 30)]) & front, GREY)
    # switchback trail
    cv.fill(line(4, 38, 30, 33) | line(30, 33, 14, 29) | line(14, 29, 34, 24) | line(34, 24, 28, 21), WOOD_L)
    # tiny wagon on the trail
    cv.sprite(27, 17, "kkk.\nkrrk\nkkkk\n.k.k", {"k": INK, "r": RASP})
    return [done(cv)]


@pic("v_fort", "Vignette: a frontier fort, palisade, blockhouse and flag")
def p_v_fort():
    cv = vig(SKY, LEAF, 30, SKY_L, LEAF_D)
    cv.ell(40, 2, 54, 8, WHITE)
    cv.ell(46, 0, 60, 7, WHITE)
    # blockhouse
    cv.rect(38, 8, 52, 20, WOOD)
    cv.poly([(36, 9), (45, 3), (54, 9)], BROWN)
    cv.fill(border(rect(38, 8, 52, 20)) | border(poly([(36, 9), (45, 3), (54, 9)])), INK)
    cv.rect(44, 12, 46, 14, INK)
    # palisade
    for x0 in range(4, 60, 3):
        h = 12 + (x0 % 2)
        cv.rect(x0, 33 - h, x0 + 2, 33, WOOD)
        cv.px(x0 + 1, 33 - h - 1, WOOD)
        cv.vline(x0 + 2, 33 - h, 33, BROWN)
    cv.hline(4, 60, 24, BROWN_D)
    cv.hline(4, 60, 30, BROWN_D)
    # gate
    cv.rect(26, 23, 34, 33, BROWN_D)
    cv.vline(30, 23, 33, INK)
    # flagpole and a raspberry flag
    cv.vline(15, 4, 20, INK)
    cv.rect(16, 4, 24, 9, RASP)
    cv.hline(16, 24, 6, WHITE)
    cv.rect(16, 4, 18, 6, WATER_D)
    # trail to the gate
    cv.poly([(27, 34), (33, 34), (40, 39), (22, 39)], WOOD_L)
    return [done(cv)]


RIDER = """
.........kk.....
........kkkk....
.......kkkk.....
......kkkkkk....
.....k.kkkk.....
......kkkkk.....
...kkkkkkkkkkkk.
..kkkkkkkkkkkkkk
kkkkkkkkkkkkkkk.
k.kkkkkkkkkkkk..
.kkk.kk...kk.k..
.k...k.k..k...k.
k....k..k.k....k
"""
RIDER_HAT = """
.......kkkk.....
......kkkkkk....
"""


def rider(cv, x, y, c=INK, flip=False):
    cv.sprite(x, y + 2, RIDER, {"k": c}, flip)
    cv.sprite(x, y, RIDER_HAT, {"k": c}, flip)


@pic("v_riders", "Vignette: riders ahead, horse-and-rider silhouettes at sunset")
def p_v_riders():
    cv = vig(SUN_O, GOLD, 26, SUN_Y)
    cv.disk(32, 26, 9, WHITE)
    hills = poly([(0, 27), (16, 22), (34, 25), (50, 21), (64, 24), (64, 40), (0, 40)])
    cv.fill(hills, WOOD)
    cv.rect(0, 32, 63, 39, WOOD_L)
    cv.dither(rect(0, 31, 63, 32), WOOD)
    rider(cv, 8, 14, INK, flip=True)
    rider(cv, 26, 11, INK, flip=True)
    rider(cv, 44, 15, INK, flip=True)
    # dust
    for dx in (24, 42, 60):
        cv.dither(ellipse(dx - 2, 26, dx + 5, 31), PAPER_D)
    return [done(cv)]


@pic("v_bandits", "Vignette: masked bandits in the moonlight")
def p_v_bandits():
    cv = vig(NIGHT, DUSK_V, 30, DUSK_V)
    cv.disk(54, 8, 4, PAPER)
    for bx in (8, 34):
        f = Canvas(30, 40)
        # hat
        f.rect(2, 8, 25, 9, INK)
        f.px(1, 7, INK)
        f.px(26, 7, INK)
        f.poly([(7, 8), (8, 2), (12, 1), (13.5, 3), (15, 1), (19, 2), (20, 8)], INK)
        f.hline(8, 19, 7, RASP_D)  # hat band
        # head with eyes
        f.ell(6, 9, 21, 25, GREY_D)
        f.rect(8, 14, 19, 16, INK)  # mask band across the eyes
        f.rect(10, 15, 11, 15, WHITE)
        f.rect(16, 15, 17, 15, WHITE)
        # bandana over the mouth
        f.poly([(6, 18), (22, 18), (14, 29)], RASP)
        f.dither(poly([(6, 18), (22, 18), (14, 29)]), RASP_D)
        # shoulders
        f.ell(0, 26, 27, 44, INK)
        cv.blit(f, bx, 3)
    return [done(cv)]


@pic("v_illness", "Vignette: illness, a medicine bottle and spoon")
def p_v_illness():
    cv = vig(PAPER, WOOD, 30, PAPER, BROWN)
    # bottle
    b = Canvas(VW, VH)
    b.rect(26, 4, 34, 7, PAPER_D)  # cork
    b.rect(27, 8, 33, 11, BROWN)  # neck
    b.ell(20, 10, 40, 36, BROWN) | b.rect(20, 18, 40, 34, BROWN)
    b.rect(20, 18, 40, 34, BROWN)
    b.rect(22, 20, 38, 30, PAPER)  # label
    b.fill(border(rect(22, 20, 38, 30)), RASP_D)
    b.rect(29, 22, 31, 28, RASP)  # cross
    b.rect(26, 24, 34, 26, RASP)
    b.vline(22, 13, 18, WOOD_L)  # glint
    b.vline(37, 31, 33, WOOD_L)
    # spoon
    b.line(44, 34, 56, 28, GREY_L)
    b.ell(41, 32, 47, 36, GREY_L)
    b.ell(42, 33, 46, 35, LEAF_L)
    b.outline(INK)
    cv.blit(b, 0, 0)
    return [done(cv)]


@pic("v_helpful_food", "Vignette: a basket of wild raspberries and berries (no people)")
def p_v_helpful_food():
    cv = vig(SKY_L, LEAF, 26, SKY_L, LEAF_D)
    # leaves behind
    for lx, ly in ((10, 14), (52, 12), (6, 22), (56, 22)):
        cv.ell(lx - 4, ly - 2, lx + 4, ly + 2, LEAF_D)
        cv.hline(lx - 3, lx + 3, ly, LEAF_L)
    b = Canvas(VW, VH)
    # berry heap above the rim
    heap = ellipse(14, 8, 50, 26)
    b.fill(heap, RASP_D)
    r = rng(7)
    for _ in range(46):
        bx, by = 16 + r(33), 9 + r(13)
        if (bx, by) not in heap:
            continue
        c = RASP if r(5) else INK
        b.fill({(bx, by), (bx + 1, by), (bx, by + 1), (bx + 1, by + 1)}, c)
        b.px(bx, by, RASP_L if c == RASP else GREY_D)
    # a leaf on top
    b.fill({(30, 7), (31, 7), (32, 6), (33, 6), (31, 8), (32, 8)}, LEAF_L)
    # basket
    basket = poly([(10, 19), (54, 19), (48, 36), (16, 36)])
    b.fill(basket, WOOD)
    for y0 in range(21, 36, 3):
        b.fill({q for q in basket if q[1] == y0}, BROWN)
    for x0 in range(12, 54, 4):
        b.fill({q for q in basket if q[0] == x0 + (q[1] - 19) // 6}, WOOD_L)
    b.rect(9, 18, 55, 20, WOOD_L)
    b.hline(9, 55, 20, BROWN)
    # handle
    b.fill(border(ellipse(16, 2, 48, 36)) & rect(0, 0, 64, 17) - heap, BROWN)
    b.outline(INK)
    cv.blit(b, 0, 0)
    return [done(cv)]


@pic("v_hunt_result", "Vignette: the hunt's result, a haunch of meat and the rifle")
def p_v_hunt_result():
    cv = vig(PAPER, WOOD, 28, PAPER, BROWN)
    b = Canvas(VW, VH)
    # rifle across the back
    b.line(4, 30, 58, 10, BROWN_D)
    b.line(4, 31, 58, 11, BROWN_D)
    b.poly([(2, 30), (12, 26), (14, 31), (4, 35)], WOOD)
    # a roast drumstick, the bone end out to the upper right
    b.line(28, 22, 50, 10, WHITE)
    b.line(28, 23, 50, 11, WHITE)
    b.line(29, 23, 51, 11, WHITE)
    b.disk(50, 8, 2, WHITE)
    b.disk(53, 11, 2, WHITE)
    meat = ellipse(10, 12, 38, 34)
    b.fill(meat, BROWN)
    b.fill({q for q in meat if q[0] + q[1] < 44}, WOOD)
    b.fill({q for q in meat if q[0] + q[1] < 34}, WOOD_L)
    b.dither(border(meat) & {q for q in meat if q[0] + q[1] >= 54}, BROWN_D)
    b.fill({(16, 18), (17, 17), (18, 17)}, PAPER)  # glint
    b.outline(INK)
    cv.blit(b, 0, 0)
    # steam
    for sx in (24, 30):
        cv.fill({(sx, 8), (sx + 1, 7), (sx, 6), (sx - 1, 5), (sx, 4)}, GREY_L)
    return [done(cv)]


@pic("v_south_pass", "Vignette: South Pass, a wide grassy saddle with no snow")
def p_v_south_pass():
    cv = vig(SKY, GOLD, 24, SKY_L, LEAF)
    left = poly([(0, 30), (0, 10), (10, 7), (24, 22), (32, 28), (0, 40)])
    right = poly([(64, 30), (64, 8), (52, 6), (40, 22), (32, 28), (64, 40)])
    cv.fill(left, LEAF_D)
    cv.fill(right, LEAF_D)
    cv.fill(poly([(10, 7), (24, 22), (16, 22)]) & left, LEAF)
    cv.fill(poly([(52, 6), (40, 22), (48, 22)]) & right, LEAF)
    cv.ell(14, 3, 30, 9, WHITE)
    # the trail through the saddle
    cv.poly([(28, 39), (36, 39), (33, 26), (31, 26)], WOOD_L)
    # signpost
    cv.vline(44, 26, 36, BROWN_D)
    cv.rect(39, 26, 52, 30, WOOD)
    cv.fill(border(rect(39, 26, 52, 30)), BROWN_D)
    cv.hline(41, 50, 28, BROWN_D)
    return [done(cv)]


@pic("v_doctor", "Vignette: the doctor's bag and a bandage roll")
def p_v_doctor():
    cv = vig(PAPER, WOOD, 30, PAPER, BROWN)
    b = Canvas(VW, VH)
    # handle
    b.fill(border(ellipse(20, 3, 38, 17)) & rect(0, 0, 64, 10), GREY_D)
    # bag
    bag = poly([(12, 12), (46, 12), (50, 36), (8, 36)])
    b.fill(bag, GREY_D)
    b.fill({q for q in bag if q[1] <= 15}, GREY)
    b.hline(10, 48, 16, INK)
    b.rect(23, 21, 35, 33, WHITE)
    b.rect(27, 22, 31, 32, RASP)
    b.rect(24, 25, 34, 29, RASP)
    b.rect(28, 13, 30, 15, SUN_Y)  # clasp
    # bandage roll
    b.ell(46, 26, 58, 38, WHITE)
    b.ell(50, 30, 54, 34, GREY_L)
    b.poly([(52, 38), (60, 38), (62, 34), (56, 36)], WHITE)
    b.outline(INK)
    cv.blit(b, 0, 0)
    return [done(cv)]


# ---- shooting scenes (160x80): the top band stays quiet for the cue

SW, SH = 160, 80
LAYOUT["shoot_cue"] = (4, 1, 152, 20)


def buffalo(frame=0):
    cv = Canvas(44, 30)
    hind = ellipse(2, 8, 24, 24)
    cv.fill(hind, BROWN)
    cv.fill({q for q in hind if q[1] <= 11}, WOOD)
    hump = ellipse(14, 1, 36, 25)
    cv.fill(hump, BROWN_D)
    # shaggy mane edge
    cv.dither(border(hump) & {q for q in hump if q[0] < 26}, BROWN)
    head = ellipse(30, 10, 41, 23)
    cv.fill(head, BROWN_D)
    cv.fill(rect(33, 21, 37, 27), BROWN_D)  # beard
    cv.dither(rect(33, 22, 37, 27), BROWN)
    cv.fill({(35, 10), (36, 9), (37, 8), (38, 8), (38, 9)}, PAPER)  # horn
    cv.px(37, 14, SUN_Y)  # eye
    cv.fill(line(2, 10, 0, 18), BROWN_D)  # tail
    legs = [(5, 0), (10, 1), (20, 1), (27, 0)]
    for i, (lx, ph) in enumerate(legs):
        dx = (1 if (ph + frame) % 2 else -1) if i % 2 == 0 else 0
        cv.rect(lx + dx, 22, lx + dx + 2, 27, BROWN_D if i >= 2 else BROWN)
        cv.hline(lx + dx, lx + dx + 2, 28, INK)
    cv.outline(INK)
    return cv


DEER = """
.......b.b...
........bb...
........hhh..
.......hhhhk.
.......hh....
.hhhhhhhh....
whhhhhhhh....
.hhhhhhh.....
.h.h...h.h...
.h.h...h.h...
.k.k...k.k...
"""


@pic("shoot_hunt", "Shooting scene: hunting, a buffalo and a deer on the prairie")
def p_shoot_hunt():
    cv = Canvas(SW, SH)
    cv.bands(0, SW - 1, [(0, SKY), (24, SKY_L)])
    cv.ell(10, 8, 40, 16, WHITE)
    cv.ell(24, 5, 50, 14, WHITE)
    cv.ell(116, 12, 146, 19, WHITE)
    hills = poly([(0, 44), (30, 36), (64, 42), (100, 34), (140, 40), (160, 37), (160, 50), (0, 50)])
    cv.fill(hills, LEAF)
    cv.rect(0, 46, 159, 79, GOLD)
    cv.dither(rect(0, 46, 159, 46), LEAF)
    cv.rect(0, 66, 159, 79, LEAF)
    cv.dither(rect(0, 65, 159, 65), LEAF, 1)
    r = rng(17)
    for _ in range(50):
        gx, gy = r(160), 48 + r(30)
        cv.fill({(gx, gy), (gx + 1, gy - 1), (gx + 2, gy)}, LEAF_D if gy > 64 else WOOD)
    cv.blit(buffalo(), 92, 40)
    cv.sprite(30, 42, DEER, {"h": WOOD_L, "b": BROWN_D, "k": INK, "w": WHITE}, scale=2)
    return [cv]


def galloper(c=INK, frame=0):
    """A horse and rider at full gallop facing right, 34x28 silhouette."""
    cv = Canvas(34, 28)
    cv.fill(ellipse(5, 11, 24, 20), c)  # barrel
    cv.poly([(19, 13), (24, 5), (28, 6), (25, 15)], c)  # neck
    cv.poly([(24, 4), (30, 6), (33, 10), (31, 12), (26, 9)], c)  # head
    cv.fill({(25, 3), (26, 2), (27, 3)}, c)  # ears
    cv.poly([(6, 12), (0, 10), (1, 14), (5, 15)], c)  # tail streaming
    fl = [(20, 18, 28, 20, 31, 18), (18, 18, 23, 23, 27, 24)]  # front legs
    bl = [(9, 18, 4, 22, 0, 24), (11, 18, 8, 23, 6, 27)]  # hind legs
    if frame:
        fl = [(20, 18, 23, 23, 22, 27), (18, 18, 20, 23, 17, 27)]
        bl = [(9, 18, 10, 23, 13, 27), (11, 18, 13, 23, 16, 26)]
    for ax, ay, bx, by, ex, ey in fl + bl:
        for d in (0, 1):
            cv.line(ax + d, ay, bx + d, by, c)
            cv.line(bx + d, by, ex + d, ey, c)
    # rider leaning forward, hat, rifle held up
    cv.poly([(12, 12), (17, 12), (18, 4), (14, 3)], c)
    cv.disk(17, 2, 2, c)
    cv.hline(13, 21, 1, c)
    cv.rect(15, -1, 19, 0, c)
    cv.line(16, 6, 24, 0, c)  # arm and rifle
    cv.line(19, 5, 27, -1, c)
    cv.fill(rect(12, 13, 14, 17), c)  # leg over the flank
    return cv


@pic("shoot_riders", "Shooting scene: riders charging out of the sunset")
def p_shoot_riders():
    cv = Canvas(SW, SH)
    cv.bands(0, SW - 1, [(0, DUSK_P), (16, SUN_P), (32, SUN_O), (42, SUN_Y)])
    cv.disk(120, 48, 14, WHITE)
    hills = poly([(0, 52), (40, 44), (80, 50), (120, 46), (160, 50), (160, 80), (0, 80)])
    cv.fill(hills, WOOD)
    cv.rect(0, 60, 159, 79, WOOD_L)
    cv.dither(rect(0, 59, 159, 60), WOOD)
    for k, (rx, ry) in enumerate(((10, 40), (62, 33), (112, 42))):
        g = galloper(INK, k % 2)
        flipped = Canvas(g.w, g.h)
        for y in range(g.h):
            flipped.p[y] = g.p[y][::-1]
        cv.dither(ellipse(rx + 28, ry + 18, rx + 44, ry + 30), PAPER_D)
        cv.blit(flipped, rx, ry)
    return [cv]


@pic("shoot_bandits", "Shooting scene: bandits behind the rocks at night")
def p_shoot_bandits():
    cv = Canvas(SW, SH)
    cv.bands(0, SW - 1, [(0, NIGHT), (30, DUSK_V)])
    r = rng(23)
    for _ in range(24):
        cv.px(r(160), r(34), PAPER if r(3) else SUN_Y)
    cv.disk(140, 12, 6, PAPER)
    cv.disk(142, 10, 5, NIGHT)
    cv.rect(0, 58, 159, 79, BROWN_D)
    # bandits peeking over boulders, rifles out
    for bx in (26, 98):
        f = Canvas(40, 40)
        f.rect(4, 7, 25, 8, INK)
        f.poly([(9, 7), (10, 1), (14, 0), (15.5, 2), (17, 0), (21, 1), (22, 7)], INK)
        f.hline(10, 21, 6, RASP_D)
        f.ell(8, 8, 23, 24, GREY_D)
        f.rect(10, 13, 21, 15, INK)
        f.rect(12, 14, 13, 14, WHITE)
        f.rect(18, 14, 19, 14, WHITE)
        f.poly([(8, 17), (24, 17), (16, 27)], RASP)
        f.dither(poly([(8, 17), (24, 17), (16, 27)]), RASP_D)
        f.ell(1, 24, 30, 40, INK)  # shoulders
        f.rect(22, 25, 39, 26, GREY)  # rifle barrel
        f.rect(18, 25, 24, 28, BROWN)  # stock
        cv.blit(f, bx, 22)
    for x0, x1, y0 in ((-8, 26, 54), (14, 72, 50), (86, 140, 52), (62, 96, 60), (132, 168, 56)):
        rock = ellipse(x0, y0, x1, y0 + 44)
        cv.fill(rock, GREY_D)
        cv.fill({q for q in rock if q[0] - x0 < (x1 - x0) * 0.45 and q[1] < y0 + 14}, GREY)
        cv.fill({q for q in border(rock) if q[1] < y0 + 6}, GREY_L)
        cv.fill(border(rock), INK)
    return [cv]


@pic("shoot_animals", "Shooting scene: wild animals, wolves at dusk")
def p_shoot_animals():
    cv = Canvas(SW, SH)
    cv.bands(0, SW - 1, [(0, DUSK_V), (18, DUSK_P), (34, SUN_P)])
    cv.disk(28, 20, 9, PAPER)
    cv.disk(25, 17, 1, PAPER_D)
    for tx, th in ((6, 26), (16, 34), (140, 30), (152, 38), (124, 22)):
        cv.poly([(tx - 7, 54), (tx, 54 - th), (tx + 7, 54)], PINE)
    ground = poly([(0, 54), (50, 50), (110, 54), (160, 50), (160, 80), (0, 80)])
    cv.fill(ground, PINE)
    cv.rect(0, 66, 159, 79, INK)
    cv.dither(rect(0, 65, 159, 65), INK)
    for wx, wy, fl in ((30, 38, False), (74, 44, True), (110, 36, False)):
        cv.sprite(wx, wy, WOLF, {"k": INK}, flip=fl, scale=2)
        ex = wx + (6 if fl else 32)
        cv.fill({(ex, wy + 5), (ex + 1, wy + 5)}, SUN_Y)
    return [cv]


@pic("muzzle_flash", "Shot sprite: muzzle flash, 2 frames")
def p_muzzle_flash():
    frames = []
    for fr in range(2):
        cv = Canvas(18, 18)
        rr = 8 if fr == 0 else 6
        pts = []
        for k in range(16):
            a = math.pi * 2 * k / 16 + (0.2 if fr else 0)
            rad = rr if k % 2 == 0 else rr * 0.45
            pts.append((8.5 + math.cos(a) * rad, 8.5 + math.sin(a) * rad))
        cv.poly(pts, FIRE_O)
        cv.poly([(8.5 + (x - 8.5) * 0.6, 8.5 + (y - 8.5) * 0.6) for x, y in pts], FIRE_Y)
        cv.disk(8, 8, 3 if fr == 0 else 2, WHITE)
        frames.append(cv)
    return frames


@pic("mark_hit", "Shot result: a hit, raspberry starburst")
def p_mark_hit():
    cv = Canvas(18, 18)
    pts = []
    for k in range(14):
        a = math.pi * 2 * k / 14
        rad = 8 if k % 2 == 0 else 4
        pts.append((8.5 + math.cos(a) * rad, 8.5 + math.sin(a) * rad))
    cv.poly(pts, RASP)
    cv.poly([(8.5 + (x - 8.5) * 0.55, 8.5 + (y - 8.5) * 0.55) for x, y in pts], RASP_L)
    cv.disk(8, 8, 1, WHITE)
    cv.outline(INK)
    return [cv]


@pic("mark_miss", "Shot result: a miss, a puff of dust")
def p_mark_miss():
    cv = Canvas(18, 14)
    for cx, cy, r in ((4, 9, 3), (9, 7, 4), (14, 9, 3), (8, 4, 2)):
        cv.disk(cx, cy, r, PAPER_D)
    cv.fill({q for q in rect(0, 0, 17, 13) if cv.get(*q) is not None and q[1] >= 11}, GREY_L)
    cv.disk(8, 6, 1, WHITE)
    cv.outline(GREY)
    for px_, py_ in ((0, 3), (17, 4), (2, 0), (15, 1)):
        cv.px(px_, py_, BROWN)
    return [cv]


# ---- end scenes (160x96)

EW, EH = 160, 96
RIP = {"R": ["##.", "#.#", "##.", "#.#", "#.#"], "I": ["#", "#", "#", "#", "#"], "P": ["##.", "#.#", "##.", "#..", "#.."],
       ".": [".", ".", ".", ".", "#"]}


@pic("tombstone", "Death: a tombstone on the prairie at dusk; the UI writes the cause on it")
def p_tombstone():
    cv = Canvas(EW, EH)
    cv.bands(0, EW - 1, [(0, DUSK_V), (22, DUSK_P), (40, SUN_P), (54, SUN_O)])
    far = poly([(0, 62), (30, 56), (70, 60), (110, 54), (160, 60), (160, 70), (0, 70)])
    cv.fill(far, DUSK_P)
    cv.rect(0, 66, 159, 95, LEAF_D)
    cv.dither(rect(0, 65, 159, 65), DUSK_P)
    cv.rect(0, 82, 159, 95, PINE)
    cv.dither(rect(0, 81, 159, 81), LEAF_D)
    # the stone: rounded top, 72 x 70
    x0, x1, y0, y1 = 44, 115, 10, 84
    stone = rect(x0, y0 + 36, x1, y1) | ellipse(x0, y0, x1, y0 + 71)
    stone = {q for q in stone if q[1] <= y1}
    cv.fill(shift(stone, 3, 1) - stone, INK)  # shadow side
    cv.fill(stone, GREY_L)
    cv.fill({q for q in stone if q[0] >= x1 - 4}, GREY)
    cv.fill({q for q in stone if q[0] <= x0 + 2 or (q[1] <= y0 + 3)}, PAPER_D)
    cv.fill(border(stone), INK)
    # carved R.I.P. and a cross
    cx = (x0 + x1) // 2
    cv.rect(cx - 1, y0 + 6, cx, y0 + 15, GREY)
    cv.rect(cx - 4, y0 + 8, cx + 3, y0 + 9, GREY)
    word = "R.I.P."
    wx = cx - 8
    for ch in word:
        g = RIP[ch]
        for j, row in enumerate(g):
            for i, v in enumerate(row):
                if v == "#":
                    cv.px(wx + i, y0 + 20 + j, GREY_D)
        wx += len(g[0]) + 1
    # mound and a few flowers
    mound = ellipse(36, 80, 124, 96)
    cv.fill(mound - stone, BROWN)
    cv.fill({q for q in border(mound) if q[1] < 88} - stone, WOOD)
    for fx, fy in ((40, 84), (50, 88), (110, 86), (118, 84), (60, 90), (100, 90)):
        cv.vline(fx, fy, fy + 3, LEAF)
        cv.px(fx, fy - 1, RASP)
    # a broken wagon wheel leaning on the stone
    cv.fill(border(ellipse(116, 58, 138, 84)) | border(ellipse(117, 59, 137, 83)), WOOD)
    for a in (20, 80, 140):
        rr = math.radians(a)
        cv.line(127 + round(math.cos(rr) * 10), 71 + round(math.sin(rr) * 11),
                127 - round(math.cos(rr) * 6), 71 - round(math.sin(rr) * 6), BROWN)
    cv.disk(127, 71, 1, BROWN)
    cv.fill(rect(130, 56, 140, 66) & border(ellipse(116, 58, 138, 84)), PINE if False else DUSK_P)
    LAYOUT["tomb_text"] = (x0 + 6, y0 + 30, x1 - x0 - 11, 40)
    return [cv]


@pic("arrival", "Arrival: Oregon City, cabins by the river under Mt Hood")
def p_arrival():
    cv = Canvas(EW, EH)
    cv.bands(0, EW - 1, [(0, SKY), (30, SKY_L)])
    cv.ell(14, 10, 46, 18, WHITE)
    cv.ell(28, 6, 56, 15, WHITE)
    # Mt Hood
    hood = poly([(70, 52), (104, 8), (108, 7), (146, 52)])
    cv.fill(hood, MTN)
    snow = poly([(91, 25), (104, 8), (108, 7), (122, 24), (115, 22), (111, 27), (105, 21), (99, 27)])
    cv.fill(snow, WHITE)
    cv.fill(poly([(106, 8), (108, 7), (146, 52), (128, 52)]) & hood - snow, MTN_L)
    # hills
    hills = poly([(0, 48), (30, 40), (64, 46), (100, 42), (130, 48), (160, 44), (160, 70), (0, 70)])
    cv.fill(hills, LEAF)
    near = poly([(0, 60), (40, 54), (90, 58), (160, 54), (160, 96), (0, 96)])
    cv.fill(near, LEAF_L)
    # river from the mountains down to the right
    river = poly([(108, 52), (118, 52), (160, 74), (160, 90), (132, 70)])
    cv.fill(river, WATER)
    cv.fill({q for q in river if (q[0] * 3 + q[1] * 5) % 11 == 0}, SKY_L)
    # pines
    for tx, ty, th in ((8, 60, 22), (18, 64, 26), (150, 50, 18), (64, 54, 16), (140, 48, 14)):
        cv.poly([(tx - 5, ty), (tx, ty - th), (tx + 5, ty)], PINE)
        cv.vline(tx, ty, ty + 2, BROWN_D)
    # cabins with smoke
    for bx, by in ((34, 58), (56, 62), (82, 60)):
        cv.rect(bx, by, bx + 14, by + 10, WOOD)
        for yy in range(by + 2, by + 10, 3):
            cv.hline(bx, bx + 14, yy, BROWN_D)
        cv.poly([(bx - 2, by + 1), (bx + 7, by - 6), (bx + 16, by + 1)], RASP)
        cv.fill(border(poly([(bx - 2, by + 1), (bx + 7, by - 6), (bx + 16, by + 1)])) & rect(0, 0, 160, by), INK)
        cv.rect(bx + 6, by + 5, bx + 8, by + 10, INK)
        cv.rect(bx + 11, by - 5, bx + 12, by - 1, BROWN_D)
        for k, (sx, sy) in enumerate(((bx + 12, by - 7), (bx + 13, by - 9), (bx + 15, by - 11), (bx + 17, by - 12))):
            cv.px(sx, sy, GREY_L)
            cv.px(sx + 1, sy, GREY_L)
    # the road and the wagon arriving
    road = poly([(0, 86), (0, 80), (40, 76), (74, 72), (78, 74), (44, 82), (12, 96), (0, 96)])
    cv.fill(road, WOOD_L)
    small_wagon(cv, 6, 66, canopy=RASP, canopy_d=RASP, canopy_l=None)
    cv.remap({BROWN: BROWN_D})
    # fence
    for fx in range(96, 160, 6):
        cv.vline(fx, 82, 88, BROWN_D)
    cv.hline(96, 159, 84, WOOD)
    return [cv]


# ----------------------------------------------------------------- encoding


def palette_of(frames):
    cols = []
    for cv in frames:
        for row in cv.p:
            for c in row:
                if c is not None:
                    c5 = from565(c)
                    if c5 not in cols:
                        cols.append(c5)
    return cols


def indices(cv, pal):
    out = []
    for row in cv.p:
        for c in row:
            out.append(0 if c is None else 1 + pal.index(from565(c)))
    return out


def rle(idx):
    """Tokens: byte (n << 4) | i; n < 15 -> run n + 1, n == 15 -> run 16 +
    next byte (16..271). Runs continue across rows."""
    out = bytearray()
    i = 0
    while i < len(idx):
        v = idx[i]
        j = i
        while j < len(idx) and idx[j] == v and j - i < 271:
            j += 1
        n = j - i
        if n <= 15:
            out.append(((n - 1) << 4) | v)
        else:
            out.append(0xF0 | v)
            out.append(n - 16)
        i = j
    return bytes(out)


def raw4(idx):
    out = bytearray()
    for i in range(0, len(idx), 2):
        lo = idx[i]
        hi = idx[i + 1] if i + 1 < len(idx) else 0
        out.append(lo | (hi << 4))
    return bytes(out)


def unrle(data, n):
    out = []
    i = 0
    while i < len(data):
        b = data[i]
        i += 1
        k = b >> 4
        run = k + 1
        if k == 15:
            run = 16 + data[i]
            i += 1
        out += [b & 15] * run
    assert len(out) == n, (len(out), n)
    return out


def build():
    pics = []
    for name, doc, painter in PICS:
        frames = painter()
        w, h = frames[0].w, frames[0].h
        assert all(f.w == w and f.h == h for f in frames), name
        assert w <= 255 and h <= 255, name
        pal = palette_of(frames)
        if len(pal) > 15:
            raise SystemExit("%s: %d colours (max 15): %s" % (name, len(pal), pal))
        encs = []
        for cv in frames:
            idx = indices(cv, pal)
            a, b = rle(idx), raw4(idx)
            assert unrle(a, len(idx)) == idx
            encs.append((True, a) if len(a) < len(b) else (False, b))
        pics.append(dict(name=name, doc=doc, w=w, h=h, frames=frames, pal=pal, encs=encs,
                         transparent=any(c is None for f in frames for row in f.p for c in row)))
    return pics


def render(pics):
    blob = bytearray()
    frame_rows, pal_rows, info_rows = [], [], []
    pal_all = []
    for p in pics:
        pal_off = len(pal_all)
        pal_all += [0] + [display_bits(c) for c in p["pal"]]
        f_off = len(frame_rows)
        for is_rle, data in p["encs"]:
            frame_rows.append("    .{ .off = %d, .len = %d, .rle = %s }," % (len(blob), len(data), "true" if is_rle else "false"))
            blob += data
        info_rows.append("    .{ .w = %d, .h = %d, .frames = %d, .frame = %d, .pal = %d, .colors = %d }, // %s"
                         % (p["w"], p["h"], len(p["encs"]), f_off, pal_off, len(p["pal"]) + 1, p["name"]))
        p["bytes"] = sum(len(d) for _, d in p["encs"]) + 2 * (len(p["pal"]) + 1)
    lines = [
        "//! Generated by tools/gen_art.py; do not edit. ASSETS.md describes the format.",
        "//! art.bin holds every frame's pixel stream: palette indices, 0 = transparent,",
        "//! RLE (byte = (n << 4) | index, n < 15: run n + 1, n == 15: run 16 + next",
        "//! byte, runs continue across rows) or raw (4 bits per pixel, row-major, low",
        "//! nibble first). Palettes are cart-api DisplayColor bits (r low, b high).",
        "",
        "pub const Pic = enum(u8) {",
    ]
    for p in pics:
        lines.append("    %s, // %dx%d, %d frame(s): %s" % (p["name"], p["w"], p["h"], len(p["encs"]), p["doc"]))
    lines += [
        "};",
        "",
        "pub const Info = struct { w: u8, h: u8, frames: u8, frame: u16, pal: u16, colors: u8 };",
        "pub const Frame = struct { off: u32, len: u32, rle: bool };",
        "",
        "pub const infos = [_]Info{",
    ] + info_rows + [
        "};",
        "",
        "pub const frames = [_]Frame{",
    ] + frame_rows + [
        "};",
        "",
        "/// Index 0 of each picture's palette is transparent; its slot holds 0 and is",
        "/// never drawn.",
        "pub const palette = [_]u16{",
    ]
    for p in pics:
        cols = ["0x0000"] + ["0x%04X" % display_bits(c) for c in p["pal"]]
        lines.append("    " + ", ".join(cols) + ", // " + p["name"])
    lines += ["};", ""]
    lines.append("pub const Rect = struct { x: i16, y: i16, w: i16, h: i16 };")
    lines.append("")
    lines.append("/// Where things go. title_*: screen coordinates. shoot_cue, tomb_text:")
    lines.append("/// relative to the top-left of their picture.")
    lines.append("pub const layout = struct {")
    for k in sorted(LAYOUT):
        x, y, w, h = LAYOUT[k]
        lines.append("    pub const %s: Rect = .{ .x = %d, .y = %d, .w = %d, .h = %d };" % (k, x, y, w, h))
    lines += ["};", "", "pub const data: *const [%d]u8 = @embedFile(\"art.bin\");" % len(blob), ""]
    return "\n".join(lines), bytes(blob)


def render_check(pics):
    """Expected decode results for cart/src/art/tests.zig: per frame the
    opaque pixel count and a checksum, plus a few sample pixels."""
    lines = [
        "//! Generated by tools/gen_art.py; do not edit. Expected decode results",
        "//! for tests.zig: per frame (same order as art_data.frames) the opaque",
        "//! pixel count and sum over opaque pixels of (index + 1) * (colour + 1),",
        "//! index = y * w + x, wrapping u32; plus sample pixels (null = clear).",
        "",
        "pub const Check = struct { opaque_px: u32, sum: u32 };",
        "pub const checks = [_]Check{",
    ]
    for p in pics:
        for cv in p["frames"]:
            n, sm = 0, 0
            for y in range(cv.h):
                for x in range(cv.w):
                    c = cv.p[y][x]
                    if c is not None:
                        n += 1
                        sm = (sm + (y * cv.w + x + 1) * (display_bits(c) + 1)) & 0xFFFFFFFF
            lines.append("    .{ .opaque_px = %d, .sum = %d }, // %s" % (n, sm, p["name"]))
    lines += ["};", "", "pub const Sample = struct { pic: u8, frame: u8, x: u8, y: u8, c: ?u16 };",
              "pub const samples = [_]Sample{"]
    for k, p in enumerate(pics):
        w, h = p["w"], p["h"]
        for fi, cv in enumerate(p["frames"]):
            pts = [(0, 0), (w - 1, h - 1), (w // 2, h // 2), (w // 3, (2 * h) // 3), ((3 * w) // 4, h // 4)]
            for x, y in pts:
                c = cv.p[y][x]
                lines.append("    .{ .pic = %d, .frame = %d, .x = %d, .y = %d, .c = %s }," % (
                    k, fi, x, y, "null" if c is None else "0x%04X" % display_bits(c)))
    lines += ["};", ""]
    return "\n".join(lines)


# ----------------------------------------------------------------- previews


def to_image(cv, scale=1, bg=None):
    from PIL import Image

    im = Image.new("RGBA", (cv.w, cv.h), (0, 0, 0, 0))
    im.putdata([(0, 0, 0, 0) if c is None else from565(c) + (255,) for row in cv.p for c in row])
    if bg is not None:
        base = Image.new("RGBA", im.size, bg + (255,))
        base.alpha_composite(im)
        im = base
    if scale != 1:
        im = im.resize((cv.w * scale, cv.h * scale), Image.NEAREST)
    return im


def checker_bg(w, h):
    from PIL import Image

    im = Image.new("RGBA", (w, h))
    px_ = im.load()
    for y in range(h):
        for x in range(w):
            px_[x, y] = (0xE8, 0xDC, 0xC0, 255) if ((x // 4 + y // 4) % 2) else (0xF4, 0xE9, 0xD0, 255)
    return im


def sheet(pics, path):
    from PIL import Image, ImageDraw

    pad = 8
    width = 1100
    # layout rows greedily
    items = []
    for p in pics:
        n = len(p["frames"])
        scale = 3 if p["w"] <= 160 else 2
        w1 = n * (p["w"] + 4)
        w3 = n * (p["w"] * scale + 6)
        items.append((p, scale, max(w1 + w3 + 12, 120), p["h"] * scale + 14))
    x = y = pad
    rowh = 0
    places = []
    for p, scale, iw, ih in items:
        if x + iw > width - pad:
            x = pad
            y += rowh + pad
            rowh = 0
        places.append((p, scale, x, y))
        x += iw + pad
        rowh = max(rowh, ih)
    height = y + rowh + pad
    im = Image.new("RGBA", (width, height), (0x2A, 0x24, 0x20, 255))
    d = ImageDraw.Draw(im)
    for p, scale, x, y in places:
        label = "%s %dx%d %dB" % (p["name"], p["w"], p["h"], p["bytes"])
        d.text((x, y), label, fill=(0xF4, 0xE9, 0xD0, 255))
        yy = y + 12
        xx = x
        for f in p["frames"]:
            bg = checker_bg(f.w, f.h)
            bg.alpha_composite(to_image(f))
            im.alpha_composite(bg, (xx, yy))
            xx += f.w + 4
        xx += 8
        for f in p["frames"]:
            bg = checker_bg(f.w * scale, f.h * scale)
            bg.alpha_composite(to_image(f, scale))
            im.alpha_composite(bg, (xx, yy))
            xx += f.w * scale + 6
    im.convert("RGB").save(path, optimize=True)


def composed_title(pics):
    """The title screen as the UI will compose it (for the sheet and review)."""
    by = {p["name"]: p for p in pics}
    cv = by["title_bg"]["frames"][0].copy()
    x, y, _, _ = LAYOUT["title_wagon"]
    cv.blit(by["title_wagon"]["frames"][0], x, y)
    x, y, _, _ = LAYOUT["title_logo"]
    cv.blit(by["title_logo"]["frames"][0], x, y)
    return cv


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--png", help="also write each picture at 4x into this directory")
    ap.add_argument("--no-sheet", action="store_true")
    a = ap.parse_args()
    pics = build()
    text, blob = render(pics)
    check = render_check(pics)
    if a.check:
        ok = os.path.exists(OUT_ZIG) and open(OUT_ZIG).read() == text
        ok = ok and os.path.exists(OUT_BIN) and open(OUT_BIN, "rb").read() == blob
        ok = ok and os.path.exists(OUT_CHECK) and open(OUT_CHECK).read() == check
        if not ok:
            print("gen_art: cart/src/art/gen/ is stale; run tools/gen_art.py", file=sys.stderr)
            sys.exit(1)
        return
    os.makedirs(OUT_DIR, exist_ok=True)
    with open(OUT_ZIG, "w") as f:
        f.write(text)
    with open(OUT_BIN, "wb") as f:
        f.write(blob)
    with open(OUT_CHECK, "w") as f:
        f.write(check)
    total = len(blob) + 2 * sum(len(p["pal"]) + 1 for p in pics)
    for p in pics:
        print("%-16s %3dx%-3d %d fr %2d col %5d B" % (p["name"], p["w"], p["h"], len(p["frames"]), len(p["pal"]), p["bytes"]))
    print("total %d bytes (pixels %d)" % (total, len(blob)))
    if not a.no_sheet:
        sheet(pics, OUT_SHEET)
    if a.png:
        os.makedirs(a.png, exist_ok=True)
        for p in pics:
            for i, f in enumerate(p["frames"]):
                bg = checker_bg(f.w * 4, f.h * 4)
                bg.alpha_composite(to_image(f, 4))
                bg.convert("RGB").save(os.path.join(a.png, "%s_%d.png" % (p["name"], i)))
        to_image(composed_title(pics), 4).convert("RGB").save(os.path.join(a.png, "screen_title.png"))


if __name__ == "__main__":
    main()
