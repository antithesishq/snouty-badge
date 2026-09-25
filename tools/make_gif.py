#!/usr/bin/env python3
"""Stitch DIR/frame_*.png (from tools/preview.mjs) into an animated GIF.

    python3 tools/make_gif.py out/ preview.gif --scale 3 --ms 66

Frames are upscaled by an integer factor with nearest-neighbor so pixels stay
crisp. --ms is the per-frame duration (GIF stores centiseconds, so values are
rounded to 10 ms by most viewers). Loops forever unless --loop is given.
"""
import argparse
import glob
import os
import sys

from PIL import Image


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("frames_dir", help="directory containing frame_XXXX.png")
    ap.add_argument("out", help="output .gif path")
    ap.add_argument("--scale", type=int, default=3, help="integer upscale factor (default 3)")
    ap.add_argument("--ms", type=int, default=66, help="frame duration in ms (default 66)")
    ap.add_argument("--loop", type=int, default=0, help="GIF loop count, 0 = forever (default)")
    args = ap.parse_args()

    if args.scale < 1:
        ap.error("--scale must be >= 1")
    if args.ms < 10:
        ap.error("--ms must be >= 10")

    paths = sorted(glob.glob(os.path.join(args.frames_dir, "frame_*.png")))
    if not paths:
        print(f"make_gif: no frame_*.png in {args.frames_dir}", file=sys.stderr)
        return 1

    frames = []
    for p in paths:
        with Image.open(p) as im:
            im = im.convert("RGB")
            if args.scale != 1:
                im = im.resize((im.width * args.scale, im.height * args.scale), Image.NEAREST)
            # RGB565 frames usually have few colors; an adaptive palette without
            # dithering keeps flat areas flat.
            frames.append(im.quantize(colors=256, method=Image.Quantize.MEDIANCUT, dither=Image.Dither.NONE))

    frames[0].save(
        args.out,
        save_all=True,
        append_images=frames[1:],
        duration=args.ms,
        loop=args.loop,
        optimize=False,
        disposal=1,
    )
    w, h = frames[0].size
    print(f"make_gif: {len(frames)} frames, {w}x{h}, {args.ms} ms/frame -> {args.out}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
