#!/usr/bin/env python3
"""Build the test pack cart/src/gen/packs/TEST.GCP (docs/PACKS.md, M7.0).

    python3 tools/test_pack/make.py [--out FILE]      (from the cart directory)

The Dumps' committed art and data (cart/src/gen/tracks/) as a pack, to
prove the path from build_pack.py to the cart: the Dumps palette, horizon
and tileset (plus the three crust tiles 121..123, painted here), two race
tracks and an arena:

  LANDFILL TEST  Landfill Loop unchanged, with props beside the top
                 straight (one of them solid, on the road's edge)
  CRUST LOOP     Landfill Loop with a breakable crust band across the top
                 straight (a crust feat record) and the Sweeper drawn with
                 a props cell
  TEST SANDBOX   The Sandbox, with two props

Beside it go the host tests' drive images drive_test.img and
drive_frag.img (`drives`). The props sheet tools/test_pack/props.png is
drawn here too (4 cells of
32x48: a monitor stack, a cooling tower, a cone, a sign). Deterministic;
check.sh rebuilds it and compares.
"""
import argparse
import shutil
import struct
import subprocess
import sys
import tempfile
from pathlib import Path

import numpy as np
from PIL import Image

HERE = Path(__file__).resolve().parent
CART = HERE.parent.parent
sys.dont_write_bytecode = True
sys.path.insert(0, str(HERE.parent))
import build_tracks as bt  # noqa: E402
import build_pack  # noqa: E402
from leagues import CRUST, A_CRUST, SURF  # noqa: E402

GEN = CART / "cart" / "src" / "gen" / "tracks"
OUT = CART / "cart" / "src" / "gen" / "packs" / "TEST.GCP"
# The crust band: whole tiles across the top straight of Landfill Loop.
CRUST_X0, CRUST_X1 = 400, 424
CW, CH = 32, 48


def draw_props(path):
    """Four 32x48 cells, RGB with the #FF00FF key."""
    key = (255, 0, 255)
    img = np.zeros((CH, CW * 4, 3), np.uint8)
    img[:] = key

    def rect(c, x0, y0, x1, y1, col):
        img[y0:y1, c * CW + x0:c * CW + x1] = col
    # 0: a monitor stack (three CRTs).
    for k, y in enumerate((30, 15, 0)):
        rect(0, 4 + k, y + 2, 28 - k, y + 16, (92, 88, 80))
        rect(0, 7 + k, y + 4, 25 - k, y + 13, (40, 90, 60) if k != 1 else (110, 230, 140))
    rect(0, 10, 46, 22, 48, (60, 56, 50))
    # 1: a cooling tower (a waisted cylinder) with a steam cap.
    for y in range(8, 48):
        t = abs(y - 30) / 22
        half = int(8 + 6 * t)
        rect(1, 16 - half, y, 16 + half, y + 1, (186, 192, 190) if y % 8 else (150, 158, 160))
    rect(1, 6, 0, 26, 8, (230, 232, 236))
    # 2: a traffic cone.
    for y in range(20, 46):
        half = 1 + (y - 20) // 3
        rect(2, 16 - half, y, 16 + half, y + 1, (250, 120, 30) if (y // 6) % 2 else (240, 240, 240))
    rect(2, 6, 46, 26, 48, (60, 56, 50))
    # 3: a sign on a post.
    rect(3, 15, 18, 17, 48, (120, 126, 128))
    rect(3, 3, 2, 29, 18, (236, 186, 44))
    rect(3, 5, 4, 27, 16, (30, 30, 34))
    rect(3, 8, 8, 24, 12, (236, 186, 44))
    Image.fromarray(img).save(path, optimize=False)


def crust_tiles(tiles):
    """Paint 121 (cracked road), 122 (more cracks), 123 (the pit look)."""
    t = np.frombuffer(tiles, np.uint8).reshape(128, 8, 8).copy()
    road = t[SURF].copy()
    dark = int(t[120][3, 3])
    a = road.copy()
    for x, y in ((1, 2), (2, 3), (3, 3), (4, 4), (5, 4), (6, 5)):
        a[y, x] = dark
    b = a.copy()
    for x, y in ((2, 6), (3, 5), (4, 5), (5, 2), (6, 1), (1, 1), (4, 3)):
        b[y, x] = dark
    t[CRUST], t[CRUST + 1], t[CRUST + 2] = a, b, t[120]
    return t.tobytes()


def crust_map(packed):
    """Landfill Loop's map with crust over the road in the band."""
    m = np.frombuffer(bt.unpack_map(packed), np.uint8).reshape(128, 128).copy()
    ys = []
    for ty in range(0, 40):
        for tx in range(CRUST_X0 // 8, CRUST_X1 // 8):
            if 16 <= m[ty, tx] <= 22:
                m[ty, tx] = CRUST
                ys.append(ty)
    p = bt.pack_map(m.tobytes())
    assert bt.unpack_map(p) == m.tobytes()
    return p, min(ys) * 8, (max(ys) + 1) * 8


def stage(d):
    """Write the test pack's directory (pack.toml, the .bin files,
    props.png) into `d`."""
    for f in ("dumps_pal", "dumps_horizon"):
        shutil.copy(GEN / f"{f}.bin", d / f"{f.split('_')[1]}.bin")
    tiles = crust_tiles(bt.unpack_map((GEN / "dumps_tiles.bin").read_bytes(), 8192))
    (d / "tiles.bin").write_bytes(bt.pack_map(tiles))
    attr = bytearray((GEN / "dumps_attr.bin").read_bytes())
    attr[CRUST:CRUST + 3] = bytes([A_CRUST] * 3)
    (d / "attr.bin").write_bytes(bytes(attr))
    for kind in ("map", "center", "feat"):
        shutil.copy(GEN / f"landfill_loop_{kind}.bin", d / f"landfill_{kind}.bin")
    for kind in ("map", "center", "feat", "arena"):
        shutil.copy(GEN / f"sandbox_{kind}.bin", d / f"sandbox_{kind}.bin")
    cmap, y0, y1 = crust_map((GEN / "landfill_loop_map.bin").read_bytes())
    (d / "crust_map.bin").write_bytes(cmap)
    shutil.copy(GEN / "landfill_loop_center.bin", d / "crust_center.bin")
    # Landfill Loop's Sweeper, drawn with props cell 0 (the monitor stack:
    # the mover's sprite is cell + 1 in the kind byte's high nibble), then
    # the crust band (24 px deep, the whole road): break 30 ticks after the
    # first touch (docs/PACKS.md's minimum: (24 + 24) / 1.7), broken for 120
    # (a band across the whole road heals in time for a car that brakes
    # when it sees the hole: docs/PACKS.md).
    feat = bytearray((GEN / "landfill_loop_feat.bin").read_bytes())
    feat[0] = (feat[0] & 15) | (1 << 4)
    feat += bytes([4, 30, 0, 0]) + struct.pack("<7H", CRUST_X0, y0, CRUST_X1, y1, 120, 0, 0) + bytes([0, 0])
    (d / "crust_feat.bin").write_bytes(bytes(feat))
    draw_props(HERE / "props.png")
    shutil.copy(HERE / "props.png", d / "props.png")
    shutil.copy(HERE / "pack.toml", d / "pack.toml")


def drives(data, out_dir):
    """The host tests' drive images (tools/make_romfs.py, truncated):
    drive_test.img holds TEST.GCP, a bit-flipped copy (BROKEN.GCP), a
    text file (JUNK.GCP), a version-2 copy (NEWER.GCP) and a ROM; a
    second test pack whose clusters are handed out 2 at a time (FRAG.GCP:
    split, so RECOPY PACK) is drive_frag.img. drive_empty.img is a drive
    with no files (the default bench), drive_packs.img the content packs
    and the test pack (the pack benches and previews)."""
    rom = (CART.parent.parent / "tools" / "make_romfs.py")
    with tempfile.TemporaryDirectory() as tmp:
        t = Path(tmp)
        (t / "TEST.GCP").write_bytes(data)
        broken = bytearray(data)
        broken[len(broken) // 2] ^= 0x10
        (t / "BROKEN.GCP").write_bytes(bytes(broken))
        (t / "JUNK.GCP").write_bytes(b"not a track pack\n" * 8)
        newer = bytearray(data)
        newer[4] = 2
        (t / "NEWER.GCP").write_bytes(bytes(newer))
        (t / "OTHER.GB").write_bytes(bytes(1024))
        files = [str(t / f) for f in ("TEST.GCP", "BROKEN.GCP", "JUNK.GCP", "NEWER.GCP", "OTHER.GB")]
        subprocess.run([sys.executable, str(rom), str(out_dir / "drive_test.img"), *files, "--truncate"],
                       check=True, stdout=subprocess.DEVNULL)
        # The bench's and the simulator's drives: none, and the content
        # packs (Track B's copies in gen/packs) with the test pack.
        subprocess.run([sys.executable, str(rom), str(out_dir / "drive_empty.img"), "--truncate"],
                       check=True, stdout=subprocess.DEVNULL)
        shelf = [str(out_dir / f) for f in ("DEADMALL.GCP", "BONEYARD.GCP", "SEABED.GCP", "COLDSTOR.GCP") if (out_dir / f).exists()]
        (t / "TEST.GCP").write_bytes(data)
        subprocess.run([sys.executable, str(rom), str(out_dir / "drive_packs.img"), *shelf, str(t / "TEST.GCP"),
                        "--truncate"], check=True, stdout=subprocess.DEVNULL)
        (t / "FRAG.GCP").write_bytes(data)
        subprocess.run([sys.executable, str(rom), str(out_dir / "drive_frag.img"), str(t / "FRAG.GCP"),
                        "--fragment", "2", "--truncate"], check=True, stdout=subprocess.DEVNULL)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--out", default=str(OUT))
    a = ap.parse_args()
    with tempfile.TemporaryDirectory() as tmp:
        stage(Path(tmp))
        file, data, report = build_pack.build(Path(tmp))
    Path(a.out).write_bytes(data)
    drives(data, Path(a.out).parent)
    print("\n".join(report))
    print(f"  wrote {a.out} and the drive images beside it")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except build_pack.PackError as e:
        print(f"make.py: ERROR: {e}", file=sys.stderr)
        sys.exit(1)
