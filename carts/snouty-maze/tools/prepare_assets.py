#!/usr/bin/env python3
"""Prepare the build inputs in assets/gen/ for Snouty Maze.

  python3 tools/prepare_assets.py --placeholders [--contact docs/placeholders.png]
      Procedurally draws the eight sheets of SPEC.md section 10 as
      Genesis-style placeholder art, validates them and writes assets/gen/.

  python3 tools/prepare_assets.py --check
      Validates the sheets already in assets/gen/ (e.g. delivered art).

  python3 tools/prepare_assets.py --contact docs/placeholders.png
      Alone or after either mode: tiles every sheet in assets/gen at 4x with
      labels (plus a tiled preview of each texture, so seams show).

Validation per sheet (the build.zig `images` table and PLAN.md Track C):
exact size, cell grid, <= 15 opaque colours after RGB565 quantisation for
transparent sheets and <= 16 for opaque ones, the #FF00FF key only in
transparent sheets (index 0 in convert_gfx), no colour that collapses onto
the key in RGB565, and a 1 px empty border around every cell of a
transparent sheet. A report is printed; exit status is 1 on any violation
(nothing is written for a sheet that fails).
"""
from __future__ import annotations

import argparse
import sys
from dataclasses import dataclass
from pathlib import Path

import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "assets" / "gen"
KEY = (255, 0, 255)  # convert_gfx maps this to palette index 0 for transparent sheets


# --------------------------------------------------------------------------
# Manifest. Must match SPEC.md section 10 and build.zig `images`.
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

    @property
    def max_colors(self) -> int:
        # 4-bit palette: 16 entries, one reserved for the key when transparent.
        return 15 if self.transparent else 16


MANIFEST: dict[str, Sheet] = {
    s.name: s
    for s in [
        Sheet("wall.png", 32, 32, 32, 32, 1, False),
        Sheet("floor.png", 32, 32, 32, 32, 1, False),
        Sheet("ceiling.png", 32, 32, 32, 32, 1, False),
        Sheet("finish.png", 32, 32, 32, 32, 1, False),
        Sheet("snouty.png", 128, 32, 32, 32, 4, True),
        Sheet("snouty_top.png", 16, 16, 16, 16, 1, True),
        Sheet("smiley.png", 32, 32, 32, 32, 1, True),
        Sheet("logo.png", 32, 32, 32, 32, 1, True),
    ]
}


# --------------------------------------------------------------------------
# Palette. Genesis VDP levels (3 bits per channel) so everything survives
# RGB565 and looks of the era.
# --------------------------------------------------------------------------
L = [0, 36, 72, 108, 144, 180, 216, 252]


def g(r: int, gg: int, b: int) -> tuple[int, int, int]:
    return (L[r], L[gg], L[b])


OUTLINE = g(1, 0, 2)
# Iris purple (0x7B5CC8-ish) ramp
PURPLE1 = g(2, 1, 4)
PURPLE2 = g(3, 2, 6)   # ~ 0x6C48D8
PURPLE3 = g(4, 3, 6)   # ~ 0x906CD8
PURPLE4 = g(5, 5, 7)
PINK = g(7, 4, 5)
PINK_DARK = g(5, 2, 3)
CREAM = g(7, 7, 6)
WHITE = g(7, 7, 7)
BLACK = g(0, 0, 0)


def new_sheet(s: Sheet) -> np.ndarray:
    a = np.zeros((s.height, s.width, 3), np.uint8)
    a[:, :] = KEY if s.transparent else (0, 0, 0)
    return a


def save(a: np.ndarray, name: str) -> None:
    Image.fromarray(a, "RGB").save(OUT / name, optimize=True)


def grid(h: int, w: int) -> tuple[np.ndarray, np.ndarray]:
    """Pixel-centre coordinates (y, x)."""
    yy, xx = np.mgrid[0:h, 0:w].astype(np.float32)
    return yy + 0.5, xx + 0.5


def dilate(m: np.ndarray) -> np.ndarray:
    d = m.copy()
    d[1:] |= m[:-1]
    d[:-1] |= m[1:]
    d[:, 1:] |= m[:, :-1]
    d[:, :-1] |= m[:, 1:]
    return d


def ellipse(h: int, w: int, cy: float, cx: float, ry: float, rx: float) -> np.ndarray:
    yy, xx = grid(h, w)
    return ((yy - cy) / ry) ** 2 + ((xx - cx) / rx) ** 2 <= 1.0


def paint(a: np.ndarray, rows: list[str], x0: int, y0: int, cmap: dict[str, tuple]) -> None:
    """ASCII art; '.' leaves the pixel untouched."""
    for y, row in enumerate(rows):
        for x, ch in enumerate(row):
            if ch != ".":
                a[y0 + y, x0 + x] = cmap[ch]


# --------------------------------------------------------------------------
# wall.png: red bricks. 4 courses of 2 bricks (16x8 incl. 1 px mortar) in
# running bond, i.e. 8 bricks per 32 px; tiles in both directions because
# the offset course wraps at u = 32.
# --------------------------------------------------------------------------
MORTAR = g(5, 5, 4)
MORTAR_DARK = g(3, 3, 3)
BRICK_TINTS = [
    # (highlight, base, shadow)
    (g(6, 2, 1), g(5, 1, 1), g(3, 1, 0)),
    (g(7, 3, 2), g(6, 2, 1), g(4, 1, 1)),
    (g(5, 2, 1), g(4, 1, 0), g(3, 0, 0)),
]
BRICK_SPECK = g(3, 1, 1)
# tint per (course, brick); brick 0 of an offset course wraps across u = 0.
BRICK_PATTERN = [[0, 1], [2, 0], [1, 2], [0, 2]]


def draw_wall() -> np.ndarray:
    a = np.zeros((32, 32, 3), np.uint8)
    a[:, :] = MORTAR
    for course in range(4):
        y0 = course * 8
        off = 8 if course % 2 else 0
        for b in range(2):
            hi, base, sh = BRICK_TINTS[BRICK_PATTERN[course][b]]
            x_start = off + b * 16
            # brick body: x_start+1 .. x_start+15 (mortar column at x_start), rows y0 .. y0+6 (mortar at y0+7)
            for dx in range(1, 16):
                x = (x_start + dx) % 32
                for dy in range(7):
                    y = y0 + dy
                    c = base
                    if dy == 0 or dx == 1:
                        c = hi
                    if dy == 6 or dx == 15:
                        c = sh
                    a[y, x] = c
            # a couple of speckles so large bricks are not flat at 4x
            for sx, sy in ((5 + 3 * b + course, 3), (11 - course, 2 + (course + b) % 3)):
                a[y0 + sy, (x_start + sx) % 32] = BRICK_SPECK if (course + b) % 2 else sh
        # darker mortar under each course
        a[y0 + 7, :] = MORTAR_DARK
    return a


# --------------------------------------------------------------------------
# floor.png: 4x4 checker of 8 px squares in two greys, bevelled.
# --------------------------------------------------------------------------
def draw_floor() -> np.ndarray:
    a = np.zeros((32, 32, 3), np.uint8)
    dark = (g(2, 2, 2), g(3, 3, 3), g(1, 1, 1))
    light = (g(4, 4, 4), g(5, 5, 5), g(3, 3, 3))
    for ty in range(4):
        for tx in range(4):
            base, hi, sh = light if (tx + ty) % 2 == 0 else dark
            y0, x0 = ty * 8, tx * 8
            a[y0 : y0 + 8, x0 : x0 + 8] = base
            a[y0, x0 : x0 + 8] = hi
            a[y0 : y0 + 8, x0] = hi
            a[y0 + 7, x0 + 1 : x0 + 8] = sh
            a[y0 + 1 : y0 + 8, x0 + 7] = sh
    return a


# --------------------------------------------------------------------------
# ceiling.png: pale tiles (2x2 of 16 px) with a dark grid and a dot pattern.
# --------------------------------------------------------------------------
def draw_ceiling() -> np.ndarray:
    a = np.zeros((32, 32, 3), np.uint8)
    base, hi, sh, line, dot = g(6, 6, 5), g(7, 7, 6), g(5, 5, 4), g(2, 2, 3), g(5, 5, 5)
    a[:, :] = base
    for t in (0, 16):
        a[t, :] = line
        a[:, t] = line
        a[t + 1, :] = hi
        a[:, t + 1] = hi
        a[(t + 15) % 32, :] = sh
        a[:, (t + 15) % 32] = sh
    for t in (0, 16):
        a[t, :] = line
        a[:, t] = line
    for ty in (0, 16):
        for tx in (0, 16):
            for y in range(ty + 4, ty + 14, 4):
                for x in range(tx + 4, tx + 14, 4):
                    a[y, x] = dot
    return a


# --------------------------------------------------------------------------
# finish.png: black and white 8x8 checker.
# --------------------------------------------------------------------------
def draw_finish() -> np.ndarray:
    yy, xx = np.mgrid[0:32, 0:32]
    on = ((yy // 8 + xx // 8) % 2 == 0)
    a = np.zeros((32, 32, 3), np.uint8)
    a[on] = WHITE
    a[~on] = BLACK
    return a


# --------------------------------------------------------------------------
# snouty.png: 4 cells 32x32. Cells 0,1 walk left, cells 2,3 walk right,
# legs alternating. Drawn facing right, mirrored for left.
# --------------------------------------------------------------------------
S_GLYPH = [
    ".xxx.",
    "x...x",
    "x....",
    ".xxx.",
    "....x",
    "x...x",
    ".xxx.",
]


def snouty_right(frame: int) -> np.ndarray:
    h = w = 32
    cell = np.zeros((h, w, 3), np.uint8)
    cell[:, :] = KEY
    yy, xx = grid(h, w)
    body = ellipse(h, w, 17.5, 13.5, 8.5, 10.0)
    snout = ellipse(h, w, 19.0, 24.0, 3.2, 6.0) & (xx > 18)
    ear = ellipse(h, w, 8.5, 9.5, 3.0, 2.5)
    # legs: two pairs, alternating length/position by frame
    legs = np.zeros((h, w), bool)
    fwd, back = ((6, 19), (9, 16)) if frame == 0 else ((9, 16), (6, 19))
    for x0 in fwd:  # planted legs (long)
        legs |= (xx >= x0) & (xx < x0 + 3) & (yy >= 24) & (yy < 29)
    for x0 in back:  # lifted legs (short)
        legs |= (xx >= x0) & (xx < x0 + 3) & (yy >= 24) & (yy < 27)
    tail = np.zeros((h, w), bool)
    for i, (ty, tx) in enumerate([(19, 3), (18, 2), (17, 2), (16, 2), (15, 3)]):
        tail[ty, tx] = True
    silhouette = body | snout | ear | legs | tail
    outline = dilate(silhouette) & ~silhouette
    # keep a 1 px empty border
    outline[0, :] = outline[-1, :] = outline[:, 0] = outline[:, -1] = False
    cell[outline] = OUTLINE
    cell[legs] = PURPLE1
    cell[body] = PURPLE2
    # shading: lighter upper-left, darker belly
    shade = body & (((yy - 13.5) / 7.0) ** 2 + ((xx - 11.0) / 7.5) ** 2 <= 1.0)
    cell[shade] = PURPLE3
    cell[body & (yy > 22.5)] = PURPLE1
    cell[ear] = PURPLE3
    cell[ellipse(h, w, 8.8, 9.5, 1.6, 1.2)] = PINK_DARK
    cell[snout] = PURPLE3
    cell[snout & (yy > 20.5)] = PURPLE2
    cell[ellipse(h, w, 18.5, 29.0, 1.6, 1.4) & snout] = PINK  # nose tip
    cell[tail] = PINK_DARK
    # eye
    cell[12:15, 18:20] = WHITE
    cell[13:15, 19] = BLACK
    return cell


def draw_snouty() -> np.ndarray:
    s = MANIFEST["snouty.png"]
    a = new_sheet(s)
    for i, (frame, left) in enumerate([(0, True), (1, True), (0, False), (1, False)]):
        c = snouty_right(frame)
        if left:
            c = c[:, ::-1].copy()
        # the "S" on the flank, painted after mirroring so it always reads as S
        paint(c, S_GLYPH, 17 if left else 10, 14, {"x": CREAM})
        a[:, i * 32 : (i + 1) * 32] = c
    return a


# --------------------------------------------------------------------------
# snouty_top.png: 16x16 top-down Snouty, snout pointing up (north).
# --------------------------------------------------------------------------
def draw_snouty_top() -> np.ndarray:
    s = MANIFEST["snouty_top.png"]
    a = new_sheet(s)
    body = ellipse(16, 16, 9.5, 8.0, 4.8, 4.2)
    snout = ellipse(16, 16, 4.0, 8.0, 2.8, 1.6)
    ears = ellipse(16, 16, 6.2, 4.5, 1.3, 1.3) | ellipse(16, 16, 6.2, 11.5, 1.3, 1.3)
    tail = np.zeros((16, 16), bool)
    tail[14, 8] = True
    sil = body | snout | ears | tail
    out = dilate(sil) & ~sil
    out[0, :] = out[-1, :] = out[:, 0] = out[:, -1] = False
    a[out] = OUTLINE
    a[body] = PURPLE2
    a[body & ellipse(16, 16, 8.5, 7.0, 3.0, 2.4)] = PURPLE3
    a[snout] = PURPLE3
    a[2, 8] = PINK
    a[2, 7] = PINK
    a[ears] = PINK_DARK
    a[tail] = PINK_DARK
    a[6, 6] = BLACK
    a[6, 9] = BLACK
    return a


# --------------------------------------------------------------------------
# smiley.png: yellow disc, two eyes, a smile.
# --------------------------------------------------------------------------
def draw_smiley() -> np.ndarray:
    s = MANIFEST["smiley.png"]
    a = new_sheet(s)
    yy, xx = grid(32, 32)
    disc = ellipse(32, 32, 16, 16, 14.0, 14.0)
    rim = disc & ~ellipse(32, 32, 16, 16, 12.9, 12.9)
    a[disc] = g(7, 6, 0)
    a[disc & ellipse(32, 32, 12, 12, 7.5, 7.5)] = g(7, 7, 3)
    a[disc & ~ellipse(32, 32, 14.5, 14.5, 12.5, 12.5)] = g(6, 4, 0)
    a[rim] = g(4, 2, 0)
    for ex in (11.5, 20.5):
        a[ellipse(32, 32, 12.0, ex, 2.8, 1.6)] = BLACK
    r = np.hypot(yy - 15.0, xx - 16.0)
    smile = (r >= 7.8) & (r <= 9.6) & (yy > 18.5) & disc
    a[smile] = BLACK
    return a


# --------------------------------------------------------------------------
# logo.png: an iris-like mark: a diamond frame around a round iris with a
# pupil and a highlight.
# --------------------------------------------------------------------------
def draw_logo() -> np.ndarray:
    s = MANIFEST["logo.png"]
    a = new_sheet(s)
    yy, xx = grid(32, 32)
    d = np.abs(yy - 16) + np.abs(xx - 16)
    diamond = d <= 14.6
    a[diamond] = OUTLINE
    a[(d <= 13.4)] = PURPLE1
    a[(d <= 12.4) & (d > 10.0)] = PURPLE3
    a[(d <= 10.0)] = g(1, 1, 3)
    r = np.hypot(yy - 16, xx - 16)
    a[r <= 8.2] = PURPLE2
    a[(r <= 8.2) & (r > 7.0)] = PURPLE4
    a[r <= 5.6] = g(4, 3, 7)
    a[r <= 3.2] = BLACK
    a[ellipse(32, 32, 13.5, 13.5, 1.3, 1.3)] = WHITE
    return a


DRAW = {
    "wall.png": draw_wall,
    "floor.png": draw_floor,
    "ceiling.png": draw_ceiling,
    "finish.png": draw_finish,
    "snouty.png": draw_snouty,
    "snouty_top.png": draw_snouty_top,
    "smiley.png": draw_smiley,
    "logo.png": draw_logo,
}


# --------------------------------------------------------------------------
# Validation
# --------------------------------------------------------------------------
def rgb565(a: np.ndarray) -> np.ndarray:
    a = a.astype(np.uint32)
    return ((a[..., 0] >> 3) << 11) | ((a[..., 1] >> 2) << 5) | (a[..., 2] >> 3)


KEY565 = (31 << 11) | 31


def validate(s: Sheet, a: np.ndarray) -> list[str]:
    errors: list[str] = []
    h, w = a.shape[:2]
    info = f"{s.name:15s} {w:3d}x{h:<3d}"
    if (w, h) != (s.width, s.height):
        errors.append(f"size {w}x{h}, expected {s.width}x{s.height}")
    if s.width != s.cell_w * s.frames or s.height != s.cell_h:
        errors.append("manifest cell grid inconsistent")
    q = rgb565(a)
    is_key = (a == KEY).all(axis=2)
    near_key = (q == KEY565) & ~is_key
    if near_key.any():
        errors.append(f"{int(near_key.sum())} px collapse to the key in RGB565 but are not #FF00FF")
    if s.transparent:
        opaque = ~is_key
        if not is_key.any():
            errors.append("no #FF00FF key pixels: transparent sheet has no empty space")
    else:
        opaque = ~np.zeros((h, w), bool)
        if is_key.any():
            errors.append(f"{int(is_key.sum())} px of #FF00FF key in an opaque sheet")
    ncol = len(np.unique(q[opaque])) if opaque.any() else 0
    if ncol > s.max_colors:
        errors.append(f"{ncol} opaque colours after RGB565, max {s.max_colors}")
    info += f"  {s.frames} x {s.cell_w}x{s.cell_h}  {'transparent' if s.transparent else 'opaque     '}  colours {ncol:2d}/{s.max_colors}"
    if s.transparent and (w, h) == (s.width, s.height):
        for i in range(s.frames):
            c = opaque[:, i * s.cell_w : (i + 1) * s.cell_w]
            if c[0].any() or c[-1].any() or c[:, 0].any() or c[:, -1].any():
                errors.append(f"cell {i}: drawing touches the cell edge (keep a 1 px empty border)")
            if not c.any():
                errors.append(f"cell {i}: empty")
        info += "  border ok" if not any("border" in e for e in errors) else ""
    print(info + ("  OK" if not errors else ""))
    for e in errors:
        print(f"{'':15s} ERROR {e}")
    return errors


def load_gen(name: str) -> tuple[np.ndarray, np.ndarray]:
    a = np.array(Image.open(OUT / name).convert("RGB"))
    return a, ~(a == KEY).all(axis=2)


# --------------------------------------------------------------------------
# Contact sheet
# --------------------------------------------------------------------------
SCALE = 4
BG = (22, 20, 28)
INK = (220, 216, 228)


def checker(h: int, w: int, cell: int = 8) -> np.ndarray:
    yy, xx = np.mgrid[0:h, 0:w]
    on = ((yy // cell + xx // cell) % 2).astype(bool)
    out = np.empty((h, w, 3), np.uint8)
    out[:] = (46, 42, 56)
    out[on] = (60, 56, 72)
    return out


def write_contact(path: Path) -> None:
    from PIL import ImageDraw, ImageFont
    k = SCALE
    items = []
    for name, s in MANIFEST.items():
        if not (OUT / name).exists():
            continue
        a, m = load_gen(name)
        img = checker(a.shape[0] * k, a.shape[1] * k)
        big = a.repeat(k, 0).repeat(k, 1)
        bm = m.repeat(k, 0).repeat(k, 1)
        img[bm] = big[bm]
        for i in range(1, s.frames):
            img[:, i * s.cell_w * k] = BG
        label = f"{name}  {s.frames} x {s.cell_w}x{s.cell_h}, {k}x"
        if not s.transparent:
            # the texture tiled 3x2 at 2x next to it, so seams are visible
            t = np.tile(a, (2, 3, 1)).repeat(2, 0).repeat(2, 1)
            gap = np.zeros((img.shape[0], 16, 3), np.uint8)
            gap[:] = BG
            img = np.concatenate([img, gap, t], axis=1)
            label += " | tiled 3x2 at 2x"
        items.append((label, img))
    pad, label_h, cols = 12, 20, 2
    rows = [items[i : i + cols] for i in range(0, len(items), cols)]
    col_w = max(i.shape[1] for _, i in items) + pad
    width = cols * col_w + pad
    height = sum(max(i.shape[0] for _, i in r) + label_h + pad for r in rows) + pad
    out = np.zeros((height, width, 3), np.uint8)
    out[:] = BG
    labels = []
    y = pad
    for r in rows:
        for j, (label, img) in enumerate(r):
            x = pad + j * col_w
            labels.append((x, y, label))
            out[y + label_h : y + label_h + img.shape[0], x : x + img.shape[1]] = img
        y += label_h + max(i.shape[0] for _, i in r) + pad
    im = Image.fromarray(out, "RGB")
    d = ImageDraw.Draw(im)
    font = ImageFont.load_default(size=13)
    for x, ly, label in labels:
        d.text((x, ly), label, fill=INK, font=font)
    path.parent.mkdir(parents=True, exist_ok=True)
    im.save(path, optimize=True)
    print(f"contact sheet {path} {width}x{height}")


# --------------------------------------------------------------------------
# Modes
# --------------------------------------------------------------------------
def run_placeholders() -> int:
    errors = 0
    for name, s in MANIFEST.items():
        a = DRAW[name]()
        errs = validate(s, a)
        errors += len(errs)
        if not errs:
            save(a, name)
    print(f"{'placeholders written to ' + str(OUT) if not errors else f'{errors} violation(s); failing sheets not written'}")
    return 1 if errors else 0


def run_check() -> int:
    errors = 0
    for name, s in MANIFEST.items():
        p = OUT / name
        if not p.exists():
            print(f"{name:15s} ERROR missing")
            errors += 1
            continue
        errors += len(validate(s, load_gen(name)[0]))
    print(f"{errors} violation(s)")
    return 1 if errors else 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    grp = ap.add_mutually_exclusive_group()
    grp.add_argument("--placeholders", action="store_true", help="draw placeholder art into assets/gen/")
    grp.add_argument("--check", action="store_true", help="validate the sheets in assets/gen/ only")
    ap.add_argument("--contact", type=Path, metavar="PNG",
                    help="afterwards (or alone) write a 4x labelled contact sheet, e.g. docs/placeholders.png")
    args = ap.parse_args()
    if not (args.placeholders or args.check or args.contact):
        ap.error("one of --placeholders, --check or --contact is required")
    OUT.mkdir(parents=True, exist_ok=True)
    status = 0
    if args.placeholders:
        status = run_placeholders()
    elif args.check:
        status = run_check()
    if args.contact:
        write_contact(args.contact)
    return status


if __name__ == "__main__":
    sys.exit(main())
