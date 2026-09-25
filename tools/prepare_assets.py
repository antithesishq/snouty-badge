#!/usr/bin/env python3
"""Prepare build inputs in assets/gen/ from the delivered Snouty art.

Outputs:
  assets/gen/snouty_run.png   16-frame run strip, transparency flattened to #FF00FF
  assets/gen/snouty_jump.png  12-frame jump strip, transparency flattened to #FF00FF
  assets/gen/iris_16.png      16x16 pixel Iris, magenta key
  assets/gen/iris_spin.png    24-frame coin-spin strip of the Iris (16x16 cells)
  assets/gen/iris_16.png      16x16 pixel version of the Antithesis Iris, magenta key

Run from anywhere: python3 tools/prepare_assets.py
"""
from pathlib import Path

import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "assets" / "Snouty_Run_Study_05" / "snouty_run_strip.png"  # Study 05: revised chest emblem
JUMP_DIR = ROOT / "assets" / "Snouty_Jump_Study_04" / "frames"
# The jump study's indexed PNG has a broken palette and its RGBA frames are
# smooth-shaded (thousands of colors, soft alpha). We snap each frame to the
# run palette (snouty_palette.gpl, same 15 colors) with a hard alpha cut.
RUN_PALETTE = [
    (23, 18, 30), (41, 35, 47), (66, 54, 75), (70, 33, 116), (102, 43, 184),
    (142, 66, 222), (190, 122, 243), (244, 239, 223), (149, 141, 157),
    (238, 69, 60), (145, 50, 47), (96, 57, 31), (153, 98, 47), (205, 147, 75),
    (240, 195, 124),
]
OUT = ROOT / "assets" / "gen"
KEY = (255, 0, 255)  # upstream convert_gfx maps this to palette index 0 (skip)


def flatten_strip(src: Path = SRC, name: str = "snouty_run.png", cell: int = 96) -> None:
    strip = Image.open(src).convert("RGBA")
    bg = Image.new("RGBA", strip.size, KEY + (255,))
    bg.alpha_composite(strip)
    rgb = bg.convert("RGB")
    colors = rgb.getcolors(maxcolors=256)
    assert colors is not None and len(colors) <= 16, f"too many colors: {len(colors)}"
    rgb.save(OUT / name, optimize=True)
    print(f"{name} {rgb.size} {len(colors)} colors incl. key")
    # Lowest opaque row per cell: the cart aligns these rows to the ground or
    # to the jump arc, so paste the printed table into cart/src/main.zig.
    alpha = np.array(strip)[:, :, 3]
    feet = [int(np.nonzero(alpha[:, i * cell : (i + 1) * cell])[0].max()) for i in range(strip.width // cell)]
    print(f"  feet rows: {feet}")


# Green Hill Zone style palette (original pixels, drawn here, not ripped).
GRASS_LIGHT = (0x60, 0xE0, 0x38)
GRASS_DARK = (0x00, 0xA0, 0x20)
GRASS_EDGE = (0x00, 0x60, 0x18)
BROWN_LIGHT = (0xE0, 0x98, 0x48)
BROWN_DARK = (0xA8, 0x60, 0x20)
BROWN_SHADOW = (0x70, 0x38, 0x10)


def draw_ground(width: int = 32, height: int = 12) -> None:
    img = Image.new("RGB", (width, height))
    px = img.load()
    for x in range(width):
        # 3 rows of grass: bright tuft row with gaps, solid mid, dark edge
        px[x, 0] = GRASS_LIGHT if (x % 4) != 3 else GRASS_DARK
        px[x, 1] = GRASS_DARK if (x % 8) != 5 else GRASS_LIGHT
        px[x, 2] = GRASS_EDGE
        # checkerboard of 8x8 squares below, with a 1px shadow row under grass
        for y in range(3, height):
            cy = y - 3
            check = ((x // 8) + (cy // 8)) % 2 == 0
            color = BROWN_LIGHT if check else BROWN_DARK
            if cy == 0:
                color = BROWN_SHADOW
            # subtle inner bevel: darken the last row/col of each light square
            if check and (x % 8 == 7 or cy % 8 == 7):
                color = BROWN_DARK
            px[x, y] = color
    img.save(OUT / "ghz_ground.png", optimize=True)
    print(f"ghz_ground.png {img.size} {len(img.getcolors())} colors")


def snap_jump_strip(cell: int = 96, frames: int = 12) -> None:
    pal = np.array(RUN_PALETTE, dtype=np.int32)
    strip = np.zeros((cell, cell * frames, 3), np.uint8)
    strip[:, :] = KEY
    feet = []
    for i in range(frames):
        f = np.array(Image.open(JUMP_DIR / f"snouty_jump_{i:02d}.png").convert("RGBA")).astype(np.int32)
        opaque = f[:, :, 3] >= 128
        d = ((f[:, :, None, :3] - pal[None, None, :, :]) ** 2).sum(axis=3)
        nearest = pal[d.argmin(axis=2)].astype(np.uint8)
        cellimg = strip[:, i * cell : (i + 1) * cell]
        cellimg[opaque] = nearest[opaque]
        feet.append(int(np.nonzero(opaque)[0].max()))
    img = Image.fromarray(strip)
    colors = img.getcolors(maxcolors=256)
    assert colors is not None and len(colors) <= 16, len(colors)
    img.save(OUT / "snouty_jump.png", optimize=True)
    print(f"snouty_jump.png {img.size} {len(colors)} colors incl. key")
    print(f"  feet rows: {feet}")


# Hand-pixelled from assets/logo/White Logo Mark.png (288 px, 280 visible):
# two 3 px brackets with a rounded outer corner around a 7 px diamond.
IRIS_16 = [
    "...##########...",
    "..###########...",
    ".############...",
    "###.............",
    "###.............",
    "###.....#....###",
    "###....###...###",
    "###...#####..###",
    "###..#######.###",
    "###...#####..###",
    "###....###...###",
    "........#....###",
    ".............###",
    "...############.",
    "...###########..",
    "...##########...",
]
WHITE = (0xFC, 0xFB, 0xF9)


def draw_iris() -> None:
    assert len(IRIS_16) == 16 and all(len(r) == 16 for r in IRIS_16)
    img = Image.new("RGB", (16, 16), KEY)
    px = img.load()
    for y, row in enumerate(IRIS_16):
        for x, ch in enumerate(row):
            if ch == "#":
                px[x, y] = WHITE
    img.save(OUT / "iris_16.png", optimize=True)
    print("iris_16.png 16x16")


# Coin spin: the Iris rotates about its vertical axis. Frame k of SPIN_FRAMES is
# angle k*360/N; the visible width is 16*|cos| (never below 1), sampled with
# nearest-neighbor from the 16 px art. Between 90 and 270 degrees we see the
# back face: mirrored and drawn in brand Grey 2 so the two faces read apart.
SPIN_FRAMES = 24
GREY_2 = (0xD3, 0xCD, 0xD4)


def draw_iris_spin() -> None:
    import math

    src = [[ch == "#" for ch in row] for row in IRIS_16]
    strip = Image.new("RGB", (16 * SPIN_FRAMES, 16), KEY)
    px = strip.load()
    for k in range(SPIN_FRAMES):
        theta = 2 * math.pi * k / SPIN_FRAMES
        c = math.cos(theta)
        width = max(1, round(16 * abs(c)))
        back = c < 0
        color = GREY_2 if back else WHITE
        x0 = k * 16 + (16 - width) // 2
        for y in range(16):
            for x in range(width):
                # source column for this output column (nearest), mirrored on the back face
                sx = min(15, (x * 16) // width)
                if back:
                    sx = 15 - sx
                if src[y][sx]:
                    px[x0 + x, y] = color
    strip.save(OUT / "iris_spin.png", optimize=True)
    print(f"iris_spin.png {strip.size} {len(strip.getcolors())} colors incl. key")


if __name__ == "__main__":
    OUT.mkdir(parents=True, exist_ok=True)
    flatten_strip()
    snap_jump_strip()
    draw_iris()
    draw_iris_spin()
