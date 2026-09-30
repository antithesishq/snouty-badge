#!/usr/bin/env python3
"""Generate the 16-colour palette dither tables (SPEC.md 5.5 mode 3, PLAN.md M3).

Run from the cart directory:  python3 tools/gen_palette16.py

Writes, deterministically:
  cart/src/palette16.bin       16 x u16 little-endian RGB565 (DisplayColor
                               bits: r 0..4, g 5..10, b 11..15)
  cart/src/palette16_cube.bin  4096 bytes: the palette index nearest to the
                               colour (r, g, b) / 15, at index r + 16 * g + 256 * b

The cart quantises each channel to 0..15 with an 8x8 Bayer threshold,
floor(c * 15 + th), looks the cell up in the cube and stores the palette
entry. Colours are in the cart's output space (linear, no gamma: the traced
value goes straight to the panel), nearest by weighted Euclidean distance
(weights 2, 4, 3 on r, g, b).

The palette: k-means (k = 14, same weights) over 20 frames of the M2.2
sunset orbit rendered with dither `none`, plus black and white, then one
of two near-duplicate pinks swapped for a mid blue so the noon and midnight
presets keep a blue. Sorted by luma. Needs nothing beyond the standard
library.
"""
import os
import struct

PALETTE = [
    (0.000, 0.000, 0.000),
    (0.029, 0.046, 0.074),
    (0.091, 0.135, 0.168),
    (0.153, 0.159, 0.191),
    (0.261, 0.199, 0.216),
    (0.351, 0.180, 0.075),
    (0.264, 0.202, 0.390),
    (0.399, 0.270, 0.233),
    (0.300, 0.450, 0.800),
    (0.558, 0.276, 0.347),
    (0.553, 0.361, 0.267),
    (0.743, 0.436, 0.250),
    (0.856, 0.378, 0.349),
    (0.951, 0.508, 0.262),
    (0.972, 0.741, 0.535),
    (1.000, 1.000, 1.000),
]
WEIGHTS = (2.0, 4.0, 3.0)

HERE = os.path.dirname(__file__)
SRC = os.path.join(HERE, "..", "cart", "src")


def rgb565(c):
    r = round(c[0] * 31)
    g = round(c[1] * 63)
    b = round(c[2] * 31)
    return r | (g << 5) | (b << 11)


def nearest(c):
    best, best_d = 0, float("inf")
    for i, p in enumerate(PALETTE):
        d = sum(w * (a - b) ** 2 for w, a, b in zip(WEIGHTS, c, p))
        if d < best_d:
            best, best_d = i, d
    return best


def main():
    assert len(PALETTE) == 16
    pal = b"".join(struct.pack("<H", rgb565(c)) for c in PALETTE)
    cube = bytes(
        nearest((r / 15, g / 15, b / 15)) for b in range(16) for g in range(16) for r in range(16)
    )
    for name, data in (("palette16.bin", pal), ("palette16_cube.bin", cube)):
        path = os.path.join(SRC, name)
        with open(path, "wb") as f:
            f.write(data)
        print(f"wrote {os.path.normpath(path)} ({len(data)} bytes)")


if __name__ == "__main__":
    main()
