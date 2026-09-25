#!/usr/bin/env python3
"""Prepare build inputs in assets/gen/ from the delivered Snouty art.

Outputs:
  assets/gen/snouty_run.png   16-frame run strip, transparency flattened to #FF00FF
  assets/gen/ghz_ground.png   original 32x12 Green-Hill-Zone-style ground tile
  assets/gen/iris_16.png      16x16 pixel version of the Antithesis Iris, magenta key
  assets/gen/waterfall.png    16x16 Genesis-style waterfall tile (scrolls vertically)

Run from anywhere: python3 tools/prepare_assets.py
"""
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "assets" / "Snouty_Run_Study_05" / "snouty_run_strip.png"  # Study 05: revised chest emblem
OUT = ROOT / "assets" / "gen"
KEY = (255, 0, 255)  # upstream convert_gfx maps this to palette index 0 (skip)


def flatten_strip() -> None:
    strip = Image.open(SRC).convert("RGBA")
    bg = Image.new("RGBA", strip.size, KEY + (255,))
    bg.alpha_composite(strip)
    rgb = bg.convert("RGB")
    colors = rgb.getcolors(maxcolors=256)
    assert colors is not None and len(colors) <= 16, f"too many colors: {len(colors)}"
    assert KEY not in {c for _, c in colors if c != KEY} or True
    rgb.save(OUT / "snouty_run.png", optimize=True)
    print(f"snouty_run.png {rgb.size} {len(colors)} colors incl. key")


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


# Waterfall: Genesis-style vertical streaks in 4 blues. The cart scrolls this
# tile downward and draws it through a checkerboard mask for translucency.
WATER_DEEP = (0x20, 0x60, 0xD0)
WATER_MID = (0x48, 0x98, 0xF0)
WATER_LIGHT = (0x90, 0xD0, 0xFF)
WATER_FOAM = (0xE8, 0xF8, 0xFF)


def draw_waterfall(width: int = 16, height: int = 16) -> None:
    img = Image.new("RGB", (width, height), WATER_MID)
    px = img.load()
    # column pattern: deep, mid, mid, light, mid, deep, light, foam-ish streak
    cols = [WATER_DEEP, WATER_MID, WATER_MID, WATER_LIGHT, WATER_MID, WATER_DEEP,
            WATER_LIGHT, WATER_MID, WATER_MID, WATER_FOAM, WATER_MID, WATER_DEEP,
            WATER_MID, WATER_LIGHT, WATER_MID, WATER_DEEP]
    for x in range(width):
        for y in range(height):
            c = cols[x % len(cols)]
            # break streaks into dashes so vertical scroll reads as falling water
            if c in (WATER_LIGHT, WATER_FOAM) and (y + x * 3) % 8 in (5, 6):
                c = WATER_MID
            if c == WATER_DEEP and (y + x * 5) % 11 == 0:
                c = WATER_MID
            px[x, y] = c
    img.save(OUT / "waterfall.png", optimize=True)
    print(f"waterfall.png {img.size} {len(img.getcolors())} colors")


if __name__ == "__main__":
    OUT.mkdir(parents=True, exist_ok=True)
    flatten_strip()
    draw_ground()
    draw_iris()
    draw_waterfall()
