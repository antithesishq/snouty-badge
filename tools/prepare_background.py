#!/usr/bin/env python3
"""Build the Green Hill Zone waterfall backdrop for the badge from ripped assets.

Inputs (assets/ref/):
  GHZ_Background_S1.png   background strips rip (clouds, mountains, cliffs, lake)
  GHZ_Chunks_S1.png       foreground chunk sheet; holds the 192x192 waterfall chunk
  Sonic-1-Waterfall.gif   in-game screenshot (2x, 4 palette-cycle frames) used for
                          the grass strip and to derive the exact water colors

Outputs (assets/gen/):
  ghz_bg_0.png .. ghz_bg_3.png   160x96 composite, one per palette-cycle frame
                                 (about 20 colors each; converted at 8 bits)
  ghz_ground.png                 96x12 grass strip

How the original works: the background strips and the waterfall chunk are drawn
with four "placeholder" palette entries (purples in the rips) that the game
rotates every 100 ms through four blues. The waterfall chunk sits in front of
the background with roughly half its columns transparent, which is the Genesis
column-dither translucency. We reproduce that literally: compose the strips,
overlay the chunk, then emit one PNG per cycle step with the purples replaced.
"""
from pathlib import Path

import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
REF = ROOT / "assets" / "ref"
OUT = ROOT / "assets" / "gen"

W, H = 160, 96
# Overlay the foreground waterfall chunk over the whole window (the famous look).
# False gives only the background strips, which still shimmer.
CURTAIN = True

# Purple placeholder levels as they appear in the rips, darkest first. The
# lake and cliff-gap shimmer in the background rip use two more purples for the
# same cycling palette entries; ALIASES folds them onto a level.
PURPLES = [(153, 51, 154), (187, 85, 187), (221, 119, 221), (255, 153, 255)]
ALIASES = {(153, 51, 153): 0, (119, 17, 119): 2}
# Console blues in cycle order, measured from the screenshot by aligning the
# chunk pattern to it: at cycle step k, level i shows BLUES[(i - k) % 4].
BLUES = [(102, 136, 238), (136, 170, 238), (170, 204, 238), (102, 136, 170)]
SHEET_BG = (135, 16, 19)

# Rip geometry (pixel rows in GHZ_Background_S1.png; content starts at x=17).
STRIP_X = 17
CLOUDS_SMALL = (245, 261)   # 16 rows, small clouds
MOUNTAINS = (272, 317)      # 45 rows, sky + mountain silhouette
CLIFFS = (325, 365)         # 40 rows, cliffs, bushes, waterfall gaps
LAKE = (373, 477)           # 104 rows, lake with shimmer placeholders

# Chunk sheet geometry: the waterfall chunk.
CHUNK = (1144, 592, 192, 192)

# Composition: (strip, first row within strip, row count, x offset into strip)
LAYOUT = [
    (CLOUDS_SMALL, 0, 16, 56),
    (MOUNTAINS, 17, 28, 56),
    (CLIFFS, 0, 40, 56),
    (LAKE, 0, 12, 56),
]


def load(p: Path) -> np.ndarray:
    return np.array(Image.open(p).convert("RGB"))


def compose_base() -> np.ndarray:
    bg = load(REF / "GHZ_Background_S1.png")
    out = np.zeros((H, W, 3), np.uint8)
    y = 0
    for (a, _b), r0, n, x0 in LAYOUT:
        out[y : y + n] = bg[a + r0 : a + r0 + n, STRIP_X + x0 : STRIP_X + x0 + W]
        y += n
    assert y == H, y
    return out


def overlay_waterfall(base: np.ndarray, row_offset: int = 16) -> np.ndarray:
    ch = load(REF / "GHZ_Chunks_S1.png")
    cx, cy, cw, chh = CHUNK
    chunk = ch[cy : cy + chh, cx : cx + cw]
    out = base.copy()
    for y in range(H):
        src = chunk[(y + row_offset) % chh, :W]
        opaque = ~np.all(src == SHEET_BG, axis=1)
        out[y][opaque] = src[opaque]
    return out


def cycle(img: np.ndarray, k: int) -> np.ndarray:
    out = img.copy()
    for i, p in enumerate(PURPLES):
        out[np.all(img == p, axis=2)] = BLUES[(i - k) % 4]
    for p, i in ALIASES.items():
        out[np.all(img == p, axis=2)] = BLUES[(i - k) % 4]
    return out


def write_backgrounds() -> None:
    comp = overlay_waterfall(compose_base()) if CURTAIN else compose_base()
    leftover = {tuple(c) for c in comp.reshape(-1, 3).tolist()} & {SHEET_BG}
    assert not leftover, "sheet background leaked into composite"
    for k in range(4):
        frame = cycle(comp, k)
        colors = {tuple(c) for c in frame.reshape(-1, 3).tolist()}
        # The strips span several Genesis palette lines, so a frame needs more
        # than 16 colors; build.zig converts these with 8-bit indices.
        assert len(colors) <= 256, f"frame {k}: {len(colors)} colors"
        assert not any(c in PURPLES or c in ALIASES for c in colors)
        Image.fromarray(frame).save(OUT / f"ghz_bg_{k}.png", optimize=True)
        print(f"ghz_bg_{k}.png {W}x{H} {len(colors)} colors")


def write_ground() -> None:
    gif = Image.open(REF / "Sonic-1-Waterfall.gif")
    gif.seek(0)
    native = np.array(gif.convert("RGB"))[::2, ::2]   # 320x224
    strip = native[191:203, 120:216].astype(np.uint16)  # 96x12, grass only, period 96
    # Screenshot uses the 0..238 (step 34) Genesis ramp; the rips use 0..252
    # (step 36). Rescale so the grass matches the backdrop's ramp.
    strip = (strip * 36 // 34).clip(0, 255).astype(np.uint8)
    img = Image.fromarray(strip)
    img.save(OUT / "ghz_ground.png", optimize=True)
    print(f"ghz_ground.png {img.size} {len(img.getcolors())} colors")


if __name__ == "__main__":
    OUT.mkdir(parents=True, exist_ok=True)
    write_backgrounds()
    write_ground()
