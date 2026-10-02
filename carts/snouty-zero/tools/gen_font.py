#!/usr/bin/env python3
"""Extract the SDK's 8x8 font (sycl-badge/src/font.zig, 0-bit = foreground,
bit 7 = left column) into assets/gen/font.bin: 96 glyphs for ' '..DEL, 8
bytes each, 1-bit = foreground, bit 7 = left column (768 bytes).

    python3 tools/gen_font.py        # from the cart directory
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT.parent.parent / "sycl-badge" / "src" / "font.zig"
OUT = ROOT / "assets" / "gen" / "font.bin"


def main() -> int:
    text = SRC.read_text()
    rows = [int(b, 2) for b in re.findall(r"0b([01]{8})", text)]
    if len(rows) < 96 * 8:
        print(f"gen_font: expected at least {96 * 8} rows, found {len(rows)}", file=sys.stderr)
        return 1
    data = bytes((~r) & 0xFF for r in rows[: 96 * 8])
    OUT.write_bytes(data)
    print(f"gen_font: {OUT.relative_to(ROOT)}: {len(data)} bytes, 96 glyphs")
    return 0


if __name__ == "__main__":
    sys.exit(main())
