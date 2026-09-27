#!/usr/bin/env python3
"""Describe a UF2 file the way the badge OS loader sees it.

    python3 tools/uf2_info.py zig-out/firmware/snouty-boy-xip.uf2 [...]

Prints block count, family id, payload bytes and the target address ranges,
then says whether every block targets the cart flash window (an XIP cart),
the cart RAM window (a RAM cart), or both (which the loader rejects with
AddressMismatch). Exit 1 if a file is malformed or mixed.
Windows: sycl-badge/src/cart/cart_xip.ld and cart_ram.ld.
"""
import struct
import sys

MAGIC0, MAGIC1, MAGIC_END = 0x0A324655, 0x9E5D5157, 0x0AB16F30
FLAG_FAMILY = 0x2000
FLASH = (0x101C0000, 0x10200000)
RAM = (0x20020000, 0x20080000)


def info(path):
    data = open(path, 'rb').read()
    if len(data) % 512:
        return f"{path}: size {len(data)} is not a multiple of 512", 1
    blocks = []
    for i in range(0, len(data), 512):
        m0, m1, flags, addr, size, no, total, fam = struct.unpack_from('<8I', data, i)
        end = struct.unpack_from('<I', data, i + 508)[0]
        if (m0, m1, end) != (MAGIC0, MAGIC1, MAGIC_END):
            return f"{path}: block {i // 512} has bad magic", 1
        blocks.append((addr, size, no, total, fam if flags & FLAG_FAMILY else None))
    fams = {b[4] for b in blocks}
    payload = sum(b[1] for b in blocks)
    lo, hi = min(b[0] for b in blocks), max(b[0] + b[1] for b in blocks)
    in_flash = all(FLASH[0] <= b[0] and b[0] + b[1] <= FLASH[1] for b in blocks)
    in_ram = all(RAM[0] <= b[0] and b[0] + b[1] <= RAM[1] for b in blocks)
    any_flash = any(FLASH[0] <= b[0] < FLASH[1] for b in blocks)
    any_ram = any(RAM[0] <= b[0] < RAM[1] for b in blocks)
    kind = ("XIP cart: every block in the flash window" if in_flash else
            "RAM cart: every block in the cart RAM window" if in_ram else
            "MIXED flash and RAM blocks: the loader rejects this (AddressMismatch)" if any_flash and any_ram else
            "blocks outside both cart windows")
    fam_s = ", ".join(f"{f:#010x}" for f in fams if f is not None) or "none"
    out = (f"{path}: {len(blocks)} blocks ({len(data)} bytes on disk), payload {payload} bytes, "
           f"family {fam_s}\n  targets {lo:#010x}..{hi:#010x} ({hi - lo} bytes)\n  {kind}")
    if in_flash:
        out += f"\n  flash window use: {hi - FLASH[0]} of {FLASH[1] - FLASH[0]} bytes"
    return out, 0 if (in_flash or in_ram) else 1


if __name__ == '__main__':
    if len(sys.argv) < 2 or sys.argv[1] in ('-h', '--help'):
        print(__doc__.strip()); sys.exit(2)
    rc = 0
    for p in sys.argv[1:]:
        s, r = info(p); print(s); rc |= r
    sys.exit(rc)
