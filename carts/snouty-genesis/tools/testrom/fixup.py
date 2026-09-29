#!/usr/bin/env python3
"""Pads the linked Snouty test ROM image and completes its header.

usage: fixup.py in.bin out.bin [size]

Pads with 0x00 to `size` bytes (default 16384), writes ROM end (size - 1)
at 0x1A4 and the checksum at 0x18E: the sum of the big-endian 16-bit words
from 0x200 to the end, modulo 0x10000 (what the BIOS-less boot code of most
games and tools/romcheck.py verify). Deterministic: output depends only on
the input bytes.
"""
import struct
import sys


def main() -> int:
    src, dst = sys.argv[1], sys.argv[2]
    size = int(sys.argv[3], 0) if len(sys.argv) > 3 else 16384
    data = bytearray(open(src, "rb").read())
    if len(data) > size:
        sys.exit(f"fixup: image is {len(data)} bytes, over the {size}-byte pad")
    if data[0x100:0x104] != b"SEGA":
        sys.exit("fixup: no SEGA header at 0x100")
    data += bytes(size - len(data))
    struct.pack_into(">I", data, 0x1A4, size - 1)
    words = struct.unpack(f">{(size - 0x200) // 2}H", data[0x200:])
    struct.pack_into(">H", data, 0x18E, sum(words) & 0xFFFF)
    open(dst, "wb").write(data)
    print(f"fixup: {dst}: {size} bytes, checksum {sum(words) & 0xFFFF:04X}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
