#!/usr/bin/env python3
"""Copy rendered packs into ../snouty-badge/assets/ and print what the cart needs.

    python3 tools/install_badge.py [--style NAME] [--dry-run]   (default style: study05)

Copies out/run -> ../snouty-badge/assets/Snouty_Art_Run and out/jump ->
.../Snouty_Art_Jump, then prints the feet-row tables for cart/src/main.zig and
the source paths to point tools/prepare_assets.py at. Nothing in snouty-badge is
edited automatically; the swap is a reviewed change there.
"""
import json
import shutil
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BADGE = ROOT.parent / "snouty-badge"
PACKS = {"run": "Snouty_Art_Run", "jump": "Snouty_Art_Jump"}

def main(dry: bool, style: str):
    for cycle, dest_name in PACKS.items():
        dest_name = f"{dest_name}_{style}"
        src = ROOT / "out" / style / cycle
        meta_path = src / f"snouty_{cycle}.json"
        if not meta_path.exists():
            print(f"skip {cycle}: not rendered")
            continue
        meta = json.loads(meta_path.read_text())
        dest = BADGE / "assets" / dest_name
        if not dry:
            if dest.exists():
                shutil.rmtree(dest)
            shutil.copytree(src, dest)
        rows = ", ".join(str(r) for r in meta["feet_rows"])
        print(f"{cycle}: {'would copy' if dry else 'copied'} {src} -> {dest}")
        print(f"  const {cycle}_feet_rows = [{meta['frame_count']}]u8{{ {rows} }};")
        print(f"  prepare_assets.py source: assets/{dest_name}/snouty_{cycle}_strip.png "
              f"(or the pre-keyed snouty_{cycle}_key.png)")

if __name__ == "__main__":
    a = sys.argv[1:]
    style = a[a.index("--style") + 1] if "--style" in a else "study05"
    main("--dry-run" in a, style)
