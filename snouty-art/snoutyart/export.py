"""Write a study-pack directory for a Cycle: frames, strip, sheet, indexed strip,
magenta-key strip, JSON, palette, contact sheet, preview GIFs, validation."""
import json
import shutil
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw

from . import ROOT, palette
from .cycle import Cycle
from .validate import validate

BG = (52, 52, 60)
SKY = (56, 120, 200)


def _grid(frames, cols, cell):
    rows = -(-len(frames) // cols)
    sheet = Image.new("RGBA", (cols * cell[0], rows * cell[1]), (0, 0, 0, 0))
    for i, f in enumerate(frames):
        sheet.alpha_composite(f.image, ((i % cols) * cell[0], (i // cols) * cell[1]))
    return sheet


def _upscale(img, k):
    return img.resize((img.width * k, img.height * k), Image.NEAREST)


def contact_sheet(cycle: Cycle, cols=8, k=4, bg=BG):
    cell = cycle.frames[0].image.size
    pad, label_h = 6, 14
    cw, ch = cell[0] * k + pad, cell[1] * k + label_h + pad
    rows = -(-len(cycle.frames) // cols)
    sheet = Image.new("RGB", (cols * cw + pad, rows * ch + pad), bg)
    d = ImageDraw.Draw(sheet)
    for i, f in enumerate(cycle.frames):
        x, y = pad + (i % cols) * cw, pad + (i // cols) * ch + label_h
        tile = Image.new("RGB", cell, (72, 72, 82))
        # ground/origin guides
        td = ImageDraw.Draw(tile)
        td.line([(0, 88), (cell[0] - 1, 88)], fill=(40, 40, 46))
        td.line([(48, 0), (48, cell[1] - 1)], fill=(40, 40, 46))
        tile.paste(f.image, (0, 0), f.image)
        sheet.paste(_upscale(tile, k), (x, y))
        d.text((x, y - label_h), f"{i:02d} {f.label}", fill=(230, 230, 230))
    return sheet


def _gif(path, frames_rgb, durations):
    # Global palette so GIF conversion is lossless: quantize against a strip of
    # all frames.
    allpix = Image.new("RGB", (frames_rgb[0].width, frames_rgb[0].height * len(frames_rgb)))
    for i, f in enumerate(frames_rgb):
        allpix.paste(f, (0, i * f.height))
    pal = allpix.quantize(colors=256, method=Image.Quantize.MEDIANCUT, dither=Image.Dither.NONE)
    q = [f.quantize(palette=pal, dither=Image.Dither.NONE) for f in frames_rgb]
    q[0].save(path, save_all=True, append_images=q[1:], duration=durations, loop=0, disposal=2)


def preview_gifs(cycle: Cycle, out: Path, k=4):
    cell = cycle.frames[0].image.size
    durs = [f.duration_ms for f in cycle.frames]
    # isolated
    iso = []
    for f in cycle.frames:
        t = Image.new("RGB", cell, BG)
        t.paste(f.image, (0, 0), f.image)
        iso.append(_upscale(t, k))
    _gif(out / f"{cycle.name}_isolated.gif", iso, durs)
    # scrolling ground: canvas 160x96 like the badge, ground tile from ref
    ground = Image.open(ROOT / "ref" / "ghz_ground.png").convert("RGB")
    W, H = 160, 96
    ground_y = 88 - 8 + 8  # feet row 88 in cell sits on the first grass row
    frames = []
    scroll = 0
    step = cycle.step_px or 0
    for f in cycle.frames:
        c = Image.new("RGB", (W, H), SKY)
        gx = -(scroll % ground.width)
        while gx < W:
            c.paste(ground, (gx, ground_y))
            gx += ground.width
        cx = W // 2 - 48
        cy = ground_y - 88
        # place by feet row so jump arcs read correctly when meta has "lift"
        lift = f.meta.get("lift", 0)
        c.paste(f.image, (cx, cy - lift), f.image)
        frames.append(_upscale(c, k))
        scroll += step
    _gif(out / f"{cycle.name}_preview.gif", frames, durs)
    # slow
    _gif(out / f"{cycle.name}_slow.gif", iso, [max(d, 1) * 3 for d in durs])


def write_pack(cycle: Cycle, out_dir: Path | None = None, origin=(48, 88)) -> dict:
    out = out_dir or ROOT / "out" / cycle.name.replace("snouty_", "")
    report = validate(cycle)
    if report["status"] != "passed":
        raise SystemExit(f"{cycle.name} failed validation:\n  " + "\n  ".join(report["errors"]))
    if out.exists():
        shutil.rmtree(out)
    (out / "frames").mkdir(parents=True)
    cell = cycle.frames[0].image.size
    n = len(cycle.frames)
    cols = cycle.grid_columns or n // 2
    for i, f in enumerate(cycle.frames):
        f.image.save(out / "frames" / f"{cycle.name}_{i:02d}.png", optimize=True)
    strip = _grid(cycle.frames, n, cell)
    strip.save(out / f"{cycle.name}_strip.png", optimize=True)
    _grid(cycle.frames, cols, cell).save(out / f"{cycle.name}_sheet.png", optimize=True)
    palette.to_indexed(strip).save(out / f"{cycle.name}_indexed.png", optimize=True, transparency=0)
    palette.flatten_key(strip).save(out / f"{cycle.name}_key.png", optimize=True)
    (out / "snouty_palette.gpl").write_text(palette.gpl(cycle.name))
    contact_sheet(cycle, cols=min(cols, 8)).save(out / f"{cycle.name}_contact_sheet.png")
    preview_gifs(cycle, out)
    total = sum(f.duration_ms for f in cycle.frames)
    meta = {
        "name": cycle.name,
        "direction": "right",
        "frame_size": list(cell),
        "frame_count": n,
        "cycle_duration_ms": total,
        "playback": cycle.playback,
        "origin_px": list(origin),
        "coordinate_system": "top-left, x right, y down",
        "ground_baseline_y": origin[1],
        "step_px_per_frame": cycle.step_px,
        "visible_palette": palette.hexes(),
        "transparent_index": 0,
        "strip": {"file": f"{cycle.name}_strip.png", "columns": n, "rows": 1},
        "grid": {"file": f"{cycle.name}_sheet.png", "columns": cols, "rows": -(-n // cols)},
        "indexed_strip": {"file": f"{cycle.name}_indexed.png", "indexed_bits_per_pixel": 4,
                          "transparent_palette_index": 0},
        "key_strip": {"file": f"{cycle.name}_key.png", "key": "#ff00ff"},
        "feet_rows": report["feet_rows"],
        "frames": [{"index": i, "file": f"frames/{cycle.name}_{i:02d}.png", "label": f.label,
                    "duration_ms": f.duration_ms, "strip_rect": [i * cell[0], 0, cell[0], cell[1]],
                    "feet_row": report["feet_rows"][i], **f.meta}
                   for i, f in enumerate(cycle.frames)],
        **cycle.notes,
    }
    (out / f"{cycle.name}.json").write_text(json.dumps(meta, indent=1))
    (out / "validation.json").write_text(json.dumps(report, indent=1))
    print(f"{cycle.name}: {n} frames, {report['visible_color_count']} colours, feet rows {report['feet_rows']}")
    print(f"  -> {out}")
    return report
