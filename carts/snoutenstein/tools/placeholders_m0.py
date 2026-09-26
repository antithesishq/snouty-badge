#!/usr/bin/env python3
"""M0 stand-in sheets at the exact manifest sizes (SPEC.md section 14).
Solid tinted cells with a 1 px darker frame so every sheet is distinguishable
in the simulator. tools/prepare_assets.py (M1 track) replaces this."""
from pathlib import Path
from PIL import Image, ImageDraw

OUT = Path(__file__).resolve().parent.parent / "assets" / "gen"
KEY = (255, 0, 255)
# name, cell_w, cell_h, frames, transparent, base color
SHEETS = [
    ("walls", 32, 32, 8, False, (110, 80, 140)),
    ("doors", 32, 32, 5, False, (90, 120, 100)),
    ("bug_gnat", 32, 32, 7, True, (140, 200, 80)),
    ("bug_wasp", 32, 32, 7, True, (230, 194, 41)),
    ("bug_beetle", 32, 32, 7, True, (60, 138, 46)),
    ("bug_spider", 32, 32, 7, True, (66, 54, 75)),
    ("bug_boss", 32, 32, 8, True, (190, 122, 243)),
    ("pickups", 16, 16, 8, True, (241, 130, 113)),
    ("projectiles", 8, 8, 4, True, (244, 239, 223)),
    ("weapons", 48, 32, 9, True, (149, 141, 157)),
    ("face", 24, 24, 9, True, (142, 66, 222)),
    ("hud", 8, 8, 8, True, (252, 251, 249)),
    ("title", 128, 40, 1, True, (241, 130, 113)),
]
for name, cw, ch, n, transparent, base in SHEETS:
    img = Image.new("RGB", (cw * n, ch), KEY if transparent else base)
    d = ImageDraw.Draw(img)
    for i in range(n):
        shade = tuple(max(0, min(255, c + ((i % 4) * 20) - 30)) for c in base)
        dark = tuple(c // 2 for c in shade)
        if transparent:
            d.rectangle([i * cw + 1, 1, i * cw + cw - 2, ch - 2], fill=shade, outline=dark)
        else:
            d.rectangle([i * cw, 0, i * cw + cw - 1, ch - 1], fill=shade, outline=dark)
            # a diagonal stripe so wall slices show texture orientation
            for k in range(0, cw, 8):
                d.line([i * cw + k, 0, i * cw + k + ch - 1, ch - 1], fill=dark)
    img.save(OUT / f"{name}.png")
    print(f"{name}.png {img.size}")
