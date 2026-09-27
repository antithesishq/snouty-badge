#!/usr/bin/env python3
"""Side-by-side review sheet of one cycle across every rendered style.

    python3 tools/compare_styles.py run      -> out/compare_run.png (+ .gif)
    python3 tools/compare_styles.py jump

Rows are styles, columns are frames, 3x nearest-neighbour, origin guides drawn.
"""
import sys
from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parent.parent
K = 3


def main(cycle: str):
    rows = []
    for style_dir in sorted((ROOT / "out").iterdir()):
        strip = style_dir / cycle / f"snouty_{cycle}_strip.png"
        if strip.exists():
            rows.append((style_dir.name, Image.open(strip).convert("RGBA")))
    if not rows:
        raise SystemExit(f"no rendered {cycle} packs under out/")
    cell = rows[0][1].height
    n = rows[0][1].width // cell
    pad, label = 4, 14
    sheet = Image.new("RGB", (pad + n * (cell * K + pad), len(rows) * (cell * K + label + pad) + pad), (52, 52, 60))
    d = ImageDraw.Draw(sheet)
    gif_frames = []
    for r, (name, strip) in enumerate(rows):
        y0 = pad + r * (cell * K + label + pad)
        d.text((pad, y0), f"{name}  ({cycle}, {n} frames)", fill=(235, 235, 235))
        for i in range(n):
            tile = Image.new("RGB", (cell, cell), (72, 72, 82))
            td = ImageDraw.Draw(tile)
            td.line([(0, 88), (cell - 1, 88)], fill=(40, 40, 46))
            td.line([(48, 0), (48, cell - 1)], fill=(40, 40, 46))
            f = strip.crop((i * cell, 0, (i + 1) * cell, cell))
            tile.paste(f, (0, 0), f)
            sheet.paste(tile.resize((cell * K, cell * K), Image.NEAREST), (pad + i * (cell * K + pad), y0 + label))
    # animated comparison: all styles running side by side
    for i in range(n):
        fr = Image.new("RGB", (len(rows) * (cell + pad) + pad, cell + pad * 2), (52, 52, 60))
        for r, (_, strip) in enumerate(rows):
            f = strip.crop((i * cell, 0, (i + 1) * cell, cell))
            fr.paste(f, (pad + r * (cell + pad), pad), f)
        gif_frames.append(fr.resize((fr.width * 4, fr.height * 4), Image.NEAREST).quantize(colors=256, dither=Image.Dither.NONE))
    sheet.save(ROOT / "out" / f"compare_{cycle}.png")
    gif_frames[0].save(ROOT / "out" / f"compare_{cycle}.gif", save_all=True, append_images=gif_frames[1:],
                       duration=60 if cycle == "jump" else 40, loop=0)
    print(f"out/compare_{cycle}.png and .gif: {[r[0] for r in rows]}")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "run")
