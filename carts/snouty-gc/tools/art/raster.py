"""A tiny RGB raster for code-drawn pixel art (Pillow only, deterministic).

A Canvas holds one RGB tuple or None (transparent) per pixel. Shapes are
sampled at pixel centres. Layers are Canvases drawn separately, outlined and
composited, so outlines follow each part's silhouette.
"""
from __future__ import annotations

import math

from PIL import Image

KEY = (255, 0, 255)  # convert_gfx maps this to palette index 0
LIGHT = (-0.42, -0.5, 0.76)  # from the upper left, mostly toward the viewer
_ln = math.sqrt(sum(v * v for v in LIGHT))
LIGHT = tuple(v / _ln for v in LIGHT)

BAYER4 = [[0, 8, 2, 10], [12, 4, 14, 6], [3, 11, 1, 9], [15, 7, 13, 5]]


def hx(v: int) -> tuple[int, int, int]:
    return ((v >> 16) & 255, (v >> 8) & 255, v & 255)


class Canvas:
    def __init__(self, w: int, h: int, fill=None):
        self.w, self.h = w, h
        self.px = [[fill] * w for _ in range(h)]

    # ------------------------------------------------------------ basics
    def inb(self, x, y):
        return 0 <= x < self.w and 0 <= y < self.h

    def set(self, x, y, c):
        x, y = int(x), int(y)
        if self.inb(x, y):
            self.px[y][x] = c

    def get(self, x, y):
        return self.px[y][x] if self.inb(x, y) else None

    def copy(self) -> "Canvas":
        c = Canvas(self.w, self.h)
        c.px = [row[:] for row in self.px]
        return c

    def rect(self, x0, y0, x1, y1, c):
        """Inclusive corners."""
        for y in range(int(y0), int(y1) + 1):
            for x in range(int(x0), int(x1) + 1):
                self.set(x, y, c)

    def hline(self, x0, x1, y, c):
        self.rect(min(x0, x1), y, max(x0, x1), y, c)

    def vline(self, x, y0, y1, c):
        self.rect(x, min(y0, y1), x, max(y0, y1), c)

    def ellipse(self, cx, cy, rx, ry, c, clip=None):
        for y in range(int(cy - ry) - 1, int(cy + ry) + 2):
            for x in range(int(cx - rx) - 1, int(cx + rx) + 2):
                u, v = (x + 0.5 - cx) / rx, (y + 0.5 - cy) / ry
                if u * u + v * v <= 1.0 and (clip is None or clip(x, y)):
                    self.set(x, y, c)

    def poly(self, pts, c, clip=None):
        xs = [p[0] for p in pts]
        ys = [p[1] for p in pts]
        for y in range(int(min(ys)) - 1, int(max(ys)) + 2):
            for x in range(int(min(xs)) - 1, int(max(xs)) + 2):
                if point_in_poly(x + 0.5, y + 0.5, pts) and (clip is None or clip(x, y)):
                    self.set(x, y, c)

    def line(self, x0, y0, x1, y1, c, clip=None):
        """Bresenham, inclusive."""
        x0, y0, x1, y1 = int(round(x0)), int(round(y0)), int(round(x1)), int(round(y1))
        dx, dy = abs(x1 - x0), -abs(y1 - y0)
        sx, sy = (1 if x0 < x1 else -1), (1 if y0 < y1 else -1)
        err = dx + dy
        while True:
            if clip is None or clip(x0, y0):
                self.set(x0, y0, c)
            if x0 == x1 and y0 == y1:
                break
            e2 = 2 * err
            if e2 >= dy:
                err += dy
                x0 += sx
            if e2 <= dx:
                err += dx
                y0 += sy

    def polyline(self, pts, c):
        for a, b in zip(pts, pts[1:]):
            self.line(a[0], a[1], b[0], b[1], c)

    def stamp(self, rows, x, y, cmap, flip=False):
        """ASCII art: '.' and ' ' are skipped, other characters map through cmap."""
        for j, row in enumerate(rows):
            if flip:
                row = row[::-1]
            for i, ch in enumerate(row):
                if ch in ". ":
                    continue
                col = cmap[ch]
                self.set(x + i, y + j, col)

    # ------------------------------------------------------------ masks
    def mask(self):
        return {(x, y) for y in range(self.h) for x in range(self.w) if self.px[y][x] is not None}

    def where(self, col):
        return {(x, y) for y in range(self.h) for x in range(self.w) if self.px[y][x] == col}

    def outline(self, c, diag=False, only_outside=True):
        """Paint c on every empty pixel next to a filled one."""
        src = [row[:] for row in self.px]
        nbs = [(1, 0), (-1, 0), (0, 1), (0, -1)]
        if diag:
            nbs += [(1, 1), (1, -1), (-1, 1), (-1, -1)]
        for y in range(self.h):
            for x in range(self.w):
                if src[y][x] is not None:
                    continue
                for dx, dy in nbs:
                    xx, yy = x + dx, y + dy
                    if 0 <= xx < self.w and 0 <= yy < self.h and src[yy][xx] is not None:
                        self.px[y][x] = c
                        break

    def inner_edge(self, c, against=None):
        """Recolour filled pixels that touch an empty pixel (or a pixel in `against`)."""
        src = [row[:] for row in self.px]
        for y in range(self.h):
            for x in range(self.w):
                if src[y][x] is None:
                    continue
                for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                    xx, yy = x + dx, y + dy
                    n = src[yy][xx] if (0 <= xx < self.w and 0 <= yy < self.h) else None
                    if (against is None and n is None) or (against is not None and n in against):
                        self.px[y][x] = c
                        break

    def paste(self, other: "Canvas", dx=0, dy=0, flip=False):
        for y in range(other.h):
            for x in range(other.w):
                c = other.px[y][other.w - 1 - x if flip else x]
                if c is not None:
                    self.set(x + dx, y + dy, c)

    def recolor(self, mapping: dict):
        for y in range(self.h):
            for x in range(self.w):
                c = self.px[y][x]
                if c in mapping:
                    self.px[y][x] = mapping[c]

    def shade(self, pixels, cx, cy, rx, ry, ramp, cuts, light=LIGHT, dither=0.0, only=None):
        """Spherical shading over a pixel set, normals from an ellipsoid at (cx, cy).
        ramp: dark..light colours; cuts: lambert thresholds (len(ramp) - 1).
        dither > 0 blends across each cut with a 4x4 Bayer pattern over that lambert width."""
        for (x, y) in pixels:
            if only is not None and self.px[y][x] not in only:
                continue
            u = (x + 0.5 - cx) / rx
            v = (y + 0.5 - cy) / ry
            d = u * u + v * v
            u, v = (u, v) if d <= 1 else (u / math.sqrt(d) * 0.999, v / math.sqrt(d) * 0.999)
            w = math.sqrt(max(0.0, 1 - u * u - v * v))
            lam = max(0.0, u * light[0] + v * light[1] + w * light[2])
            if dither:
                lam += (BAYER4[y % 4][x % 4] / 16 - 0.47) * dither
            k = sum(1 for t in cuts if lam >= t)
            self.px[y][x] = ramp[k]

    def to_image(self, scale=1, bg=KEY) -> Image.Image:
        im = Image.new("RGB", (self.w, self.h), bg)
        pix = im.load()
        for y in range(self.h):
            for x in range(self.w):
                c = self.px[y][x]
                if c is not None:
                    pix[x, y] = c
        if scale != 1:
            im = im.resize((self.w * scale, self.h * scale), Image.NEAREST)
        return im

    @staticmethod
    def from_image(im: Image.Image, key=KEY) -> "Canvas":
        im = im.convert("RGBA")
        c = Canvas(im.width, im.height)
        pix = im.load()
        for y in range(im.height):
            for x in range(im.width):
                r, g, b, a = pix[x, y]
                if a >= 128 and (r, g, b) != key:
                    c.px[y][x] = (r, g, b)
        return c


def point_in_poly(x, y, pts) -> bool:
    inside = False
    n = len(pts)
    j = n - 1
    for i in range(n):
        xi, yi = pts[i]
        xj, yj = pts[j]
        if (yi > y) != (yj > y):
            xc = xi + (y - yi) * (xj - xi) / (yj - yi)
            if x < xc:
                inside = not inside
        j = i
    return inside


def strip(cells: list[Canvas]) -> Canvas:
    """Concatenate equal cells into a horizontal strip."""
    w, h = cells[0].w, cells[0].h
    out = Canvas(w * len(cells), h)
    for i, c in enumerate(cells):
        assert (c.w, c.h) == (w, h), "cells must be equal"
        out.paste(c, i * w, 0)
    return out


# ------------------------------------------------------------- tiny 3x5 font
F3 = {
    "A": ["010", "101", "111", "101", "101"], "B": ["110", "101", "110", "101", "110"],
    "C": ["011", "100", "100", "100", "011"], "D": ["110", "101", "101", "101", "110"],
    "E": ["111", "100", "110", "100", "111"], "F": ["111", "100", "110", "100", "100"],
    "G": ["011", "100", "101", "101", "011"], "H": ["101", "101", "111", "101", "101"],
    "I": ["111", "010", "010", "010", "111"], "K": ["101", "101", "110", "101", "101"],
    "L": ["100", "100", "100", "100", "111"], "M": ["101", "111", "111", "101", "101"],
    "N": ["110", "101", "101", "101", "101"], "O": ["010", "101", "101", "101", "010"],
    "P": ["110", "101", "110", "100", "100"], "R": ["110", "101", "110", "101", "101"],
    "S": ["011", "100", "010", "001", "110"], "T": ["111", "010", "010", "010", "010"],
    "U": ["101", "101", "101", "101", "111"], "V": ["101", "101", "101", "101", "010"],
    "X": ["101", "101", "010", "101", "101"], "Y": ["101", "101", "010", "010", "010"],
    "Z": ["111", "001", "010", "100", "111"], "0": ["010", "101", "101", "101", "010"],
    "1": ["010", "110", "010", "010", "111"], "2": ["110", "001", "010", "100", "111"],
    "?": ["110", "001", "010", "000", "010"], "!": ["010", "010", "010", "000", "010"],
    ":": ["000", "010", "000", "010", "000"], "(": ["001", "010", "010", "010", "001"],
    "#": ["101", "111", "101", "111", "101"], "&": ["010", "101", "010", "101", "011"],
    " ": ["000", "000", "000", "000", "000"], "-": ["000", "000", "111", "000", "000"],
    ">": ["100", "010", "001", "010", "100"], "_": ["000", "000", "000", "000", "111"],
}


def text3(cv: Canvas, s: str, x: int, y: int, c, gap=1):
    for ch in s:
        g = F3[ch]
        for j, row in enumerate(g):
            for i, b in enumerate(row):
                if b == "1":
                    cv.set(x + i, y + j, c)
        x += 3 + gap


def text3_width(s: str, gap=1) -> int:
    return len(s) * (3 + gap) - gap


# ------------------------------------------------------------- 8x8 font
class Font8:
    """The cart's 8x8 font (96 glyphs x 8 bytes, ASCII 32..127, bit 7 = leftmost pixel)."""

    def __init__(self, path):
        self.data = open(path, "rb").read()
        assert len(self.data) == 96 * 8, "font.bin must be 768 bytes"

    def draw(self, cv: Canvas, s: str, x: int, y: int, c):
        for ch in s:
            o = (ord(ch) - 32) * 8
            for j in range(8):
                b = self.data[o + j]
                for i in range(8):
                    if b & (0x80 >> i):
                        cv.set(x + i, y + j, c)
            x += 8
