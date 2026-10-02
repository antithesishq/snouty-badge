#!/usr/bin/env python3
"""Write roms/placeholder.lnx: the M0 build's embedded stand-in ROM.

Not a Lynx program. It only gives the build something to embed until the
shipped homebrew ROM is chosen (PLAN.md M0 Track A), and it exercises the
headered path of core/cart.zig: a 64-byte "LYNX" header declaring a 128 KB
bank 0 (512-byte blocks), followed by ONE block (512 bytes) of data. The
parser accepts short files (the rest of the bank reads 0xFF), so the file
is 576 bytes and adds 576 bytes to the cart image.

Block 0: bytes 0..319 are four rows of 160 4-bit pixels (diagonal colour
stripes; the M0 test pattern shows them in picture rows 0..3), then an
ASCII note, then 0xFF.

    python3 carts/snouty-lynx/tools/make_placeholder_rom.py [OUT]

Deterministic: running it again gives the same bytes.
"""
import os
import struct
import sys

BLOCK = 512
NOTE = b"SNOUTY LYNX M0 PLACEHOLDER: not a Lynx program, see PLAN.md M0."


def build() -> bytes:
    header = bytearray(64)
    header[0:4] = b"LYNX"
    struct.pack_into("<HHH", header, 4, BLOCK, 0, 1)  # bank0 page size, bank1, version
    name = b"Snouty Lynx placeholder"
    header[10:10 + len(name)] = name
    maker = b"Snouty"
    header[42:42 + len(maker)] = maker
    header[58] = 0  # rotation: none
    header[59] = 0  # AUDIN: unused
    header[60] = 0  # EEPROM: none

    block = bytearray(b"\xff" * BLOCK)
    for r in range(4):
        for bx in range(80):
            x = bx * 2
            left = (x // 10 + r * 4) % 16
            right = ((x + 1) // 10 + r * 4) % 16
            block[r * 80 + bx] = left << 4 | right
    block[320:320 + len(NOTE)] = NOTE
    return bytes(header + block)


def main() -> None:
    here = os.path.dirname(os.path.abspath(__file__))
    out = sys.argv[1] if len(sys.argv) > 1 else os.path.join(here, "..", "roms", "placeholder.lnx")
    data = build()
    with open(out, "wb") as f:
        f.write(data)
    print(f"{out}: {len(data)} bytes")


if __name__ == "__main__":
    main()
