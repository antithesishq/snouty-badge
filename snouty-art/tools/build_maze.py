#!/usr/bin/env python3
"""Build the sheets ../snouty-maze takes from this repo into out/maze/.

    python3 tools/build_maze.py [--style study05]

Writes out/maze/snouty.png (128x32, 4 frames: 0,1 face left, 2,3 face
right, run frames 0 and 8 downscaled from 96 px on the style palette),
logo.png (Zig mark), iris.png (Iris mark), start.png (the Windows 95 Start
button with the Iris mark in place of the flag), maze_contact.png (4x).
Then in snouty-maze:
    python3 tools/prepare_assets.py --from-w95 assets/src/w95 --art ../snouty-art/out/maze
"""
from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))
from snoutyart.downscale import (KEY, downscale, fit, hex_palette, key_white, load_rgba,  # noqa: E402
                                 rgb565_snap, snap, to_cell)

OUT = ROOT / "out" / "maze"
MAZE = ROOT.parent / "snouty-maze"
CELL, BOX = 32, 30
IRIS = "#ff9f91"          # the mark's coral, measured on ref/iris-logo-ref.png
ZIG = "#f7a41d"           # ziglang/logo fill
RUN_FRAMES = (0, 8)       # opposite legs; frame 8 is half a cycle later


def style_palette(style: str) -> np.ndarray:
    roles = json.loads((ROOT / "styles" / style / "palette.json").read_text())["roles"]
    return hex_palette([r[1] for r in roles])


def snouty_sheet(style: str) -> np.ndarray:
    pal = style_palette(style)
    frames_dir = ROOT / "out" / style / "run" / "frames"
    cells = []
    for i in RUN_FRAMES:
        a = load_rgba(frames_dir / f"snouty_run_{i:02d}.png")
        cells.append(downscale(a, BOX, pal, anchor="bottom"))
    right = cells
    left = [c[:, ::-1] for c in cells]
    return np.concatenate(left + right, axis=1)


def rasterise_svg(svg: Path, px: int) -> np.ndarray:
    png = OUT / (svg.stem + ".png")
    subprocess.run(["convert", "-background", "none", "-density", "300", str(svg),
                    "-resize", f"{px}x{px}", str(png)], check=True)
    return load_rgba(png)


def zig_mark() -> np.ndarray:
    # thin diagonal stroke: keep pixels that are at least a third covered
    return downscale(rasterise_svg(ROOT / "ref" / "zig-mark.svg", 288), BOX, hex_palette([ZIG]), alpha_thresh=0.34)


def iris_ref() -> np.ndarray:
    return key_white(load_rgba(ROOT / "ref" / "iris-logo-ref.png"))


def iris_mark() -> np.ndarray:
    return downscale(iris_ref(), BOX, hex_palette([IRIS]))


def start_button() -> np.ndarray:
    """start2.png with the flag (the only saturated region) painted over in
    the button face colour and the Iris mark composited there, then fitted
    to 30 px wide."""
    a = load_rgba(MAZE / "assets" / "src" / "w95" / "start2.png")
    opaque = a[..., 3] >= 128
    rgb = a[..., :3].astype(np.int32)
    sat = (rgb.max(axis=2) - rgb.min(axis=2)) > 60
    ys, xs = np.where(sat & opaque)
    x0, y0, x1, y1 = xs.min(), ys.min(), xs.max() + 1, ys.max() + 1
    pad = 6
    x0, y0, x1, y1 = x0 - pad, y0 - pad, x1 + pad, y1 + pad
    # face colour: the most common opaque, unsaturated, light pixel
    face_px = rgb[opaque & ~sat & (rgb.min(axis=2) > 150)]
    vals, counts = np.unique(face_px, axis=0, return_counts=True)
    face = vals[counts.argmax()]
    a[y0:y1, x0:x1, :3] = face
    a[y0:y1, x0:x1, 3] = 255
    # Iris mark, fitted into the flag's box with a little margin
    mark = iris_ref()
    mw, mh = (x1 - x0) - 2 * pad, (y1 - y0) - 2 * pad
    m_rgb, m_mask = fit(mark, mw, mh)
    ox = x0 + pad + (mw - m_rgb.shape[1]) // 2
    oy = y0 + pad + (mh - m_rgb.shape[0]) // 2
    sub = a[oy:oy + m_rgb.shape[0], ox:ox + m_rgb.shape[1]]
    sub[m_mask, :3] = m_rgb[m_mask]
    # downscale: fixed palette keeps the coral exact; the rest is greys/black
    rgb_s, mask_s = fit(a, BOX, BOX)
    greys = np.array([[v, v, v] for v in (0, 48, 96, 128, 160, 192, 208, 224, 240)], np.uint8)
    pal = rgb565_snap(np.concatenate([greys, hex_palette([IRIS])]))
    return to_cell(snap(rgb_s, mask_s, pal), mask_s, CELL)


def save(a: np.ndarray, name: str) -> None:
    Image.fromarray(a, "RGB").save(OUT / name, optimize=True)


def contact(sheets: dict[str, np.ndarray], path: Path, k: int = 4) -> None:
    pad, label_h = 10, 18
    font = ImageFont.load_default(size=12)
    tiles = []
    for name, a in sheets.items():
        h, w = a.shape[:2]
        big = a.repeat(k, 0).repeat(k, 1)
        yy, xx = np.mgrid[0:h * k, 0:w * k]
        chk = np.where(((yy // 8 + xx // 8) % 2)[..., None], (60, 56, 72), (46, 42, 56)).astype(np.uint8)
        keyed = (big == KEY).all(axis=2)
        big[keyed] = chk[keyed]
        tiles.append((name, big))
    width = max(t.shape[1] for _, t in tiles) + 2 * pad
    height = sum(t.shape[0] + label_h + pad for _, t in tiles) + pad
    im = Image.new("RGB", (width, height), (22, 20, 28))
    d = ImageDraw.Draw(im)
    y = pad
    for name, t in tiles:
        d.text((pad, y), f"{name}  {t.shape[1] // k}x{t.shape[0] // k}, {k}x", fill=(220, 216, 228), font=font)
        im.paste(Image.fromarray(t, "RGB"), (pad, y + label_h))
        y += t.shape[0] + label_h + pad
    im.save(path, optimize=True)


def main() -> int:
    args = sys.argv[1:]
    style = args[args.index("--style") + 1] if "--style" in args else "study05"
    OUT.mkdir(parents=True, exist_ok=True)
    sheets = {
        "snouty.png": snouty_sheet(style),
        "logo.png": zig_mark(),
        "iris.png": iris_mark(),
        "start.png": start_button(),
    }
    for name, a in sheets.items():
        save(a, name)
        opaque = ~(a == KEY).all(axis=2)
        n = len(np.unique(a[opaque], axis=0))
        edge = opaque[0].any() or opaque[-1].any() or opaque[:, 0].any() or opaque[:, -1].any()
        print(f"{name:12s} {a.shape[1]}x{a.shape[0]}  colours {n:2d}/15  {'EDGE TOUCHED' if edge else 'border ok'}")
    contact(sheets, OUT / "maze_contact.png")
    print(f"written to {OUT}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
