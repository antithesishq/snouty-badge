#!/usr/bin/env python3
"""Print an Atari Lynx cart's header, loader and compression numbers, and say
whether Snouty Lynx can run it (SPEC.md section 11).

usage: romcheck.py CART.lnx [...]

Headered files ("LYNX", 64 bytes) are trusted; headerless dumps get their
block size from the file size (SPEC 18.3: 128 KB = 256 x 512 B, 256 KB =
256 x 1 KB, 512 KB = 256 x 2 KB). The first-frame loader is decrypted the
way core/boot.zig does it (c^3 mod N, docs/BOOT.md) to show that it boots.
Compression: zlib -9 and, when the `zstandard` module is installed (e.g.
tools/.venv), zstd -19, per 16 KB group of blocks (SPEC 13.1 fallback).
Prints no ROM bytes.
"""
import hashlib
import sys
import zlib

try:
    import zstandard
except ImportError:
    zstandard = None

# Public modulus, docs/BOOT.md ([A] $FF9A, lynx-encryption-tools keys.h).
N = int('35B5A3942806D8A22695D771B23CFD561C4A19B6A3B02600365A306E3C4D6338'
        '1BD41C136489364CF2BA2A58F4FEE1FDAC7E79', 16)
HEADERLESS = {128 * 1024: 512, 256 * 1024: 1024, 512 * 1024: 2048}
BANK_OK = {128 * 1024, 256 * 1024, 512 * 1024}
GROUP = 16 * 1024
EMBED_MAX = 32 * 1024    # SPEC 13: the embedded fallback ROM stays small
ROTATION = {0: 'none', 1: 'left', 2: 'right'}
EEPROM = {0: 'none', 1: '93C46 (128 B)', 2: '93C56 (256 B)', 3: '93C66 (512 B)',
          4: '93C76 (1 KB)', 5: '93C86 (2 KB)'}


def cstr(b):
    return b.split(b'\0', 1)[0].decode('latin-1', 'replace').strip()


def first_frame(data):
    """(blocks, ok, reason) for the loader at the start of block 0."""
    if not data:
        return 0, False, 'empty'
    count = data[0]
    if count < 0xFB:
        return 0, False, f'count byte {count:02X} < FB (not a Lynx loader)'
    n = 256 - count
    acc = 0
    for b in range(n):
        blk = data[1 + 51 * b: 1 + 51 * (b + 1)]
        if len(blk) < 51:
            return n, False, 'file ends inside the loader'
        p = pow(int.from_bytes(blk, 'little'), 3, N).to_bytes(51, 'big')
        if p[0] != 0x15:
            return n, False, f'block {b}: check byte {p[0]:02X}, not 15'
        for i in range(50, 0, -1):
            acc = (acc + p[i]) & 0xFF
    if acc != 0:
        return n, False, 'last plaintext byte not 0'
    return n, True, 'decrypts (check bytes 15, last byte 0)'


def ratios(payload):
    out = []
    for off in range(0, len(payload), GROUP):
        g = payload[off:off + GROUP]
        z = len(zlib.compress(g, 9))
        s = len(zstandard.ZstdCompressor(level=19).compress(g)) if zstandard else None
        out.append((len(g), z, s))
    return out


def main(path):
    d = open(path, 'rb').read()
    print(path)
    print(f'  size       {len(d)} bytes ({len(d) / 1024:g} KB)')
    print(f'  md5        {hashlib.md5(d).hexdigest()}  crc32 {zlib.crc32(d):08X}')
    problems, notes = [], []
    if d[:4] == b'LYNX' and len(d) >= 64:
        page0 = d[4] | d[5] << 8
        page1 = d[6] | d[7] << 8
        version = d[8] | d[9] << 8
        rot, audin, eep = d[58], d[59], d[60]
        payload = d[64:]
        bs = page0
        print(f'  header     LYNX v{version}: "{cstr(d[10:42])}" by "{cstr(d[42:58])}"')
        print(f'  banks      bank0 page {page0} B ({page0 * 256 // 1024} KB), bank1 page {page1} B'
              f'{"" if page1 else " (none)"}')
        print(f'  rotation   {rot} ({ROTATION.get(rot, "unknown")}), AUDIN {audin}, '
              f'EEPROM byte {eep:02X} ({EEPROM.get(eep & 7, "unknown")}'
              f'{", SD" if eep & 0x40 else ""}{", 8-bit" if eep & 0x80 else ""})')
        bank0 = page0 * 256
        if bank0 not in BANK_OK:
            problems.append(f'bank 0 is {bank0 // 1024} KB (128, 256 or 512 KB supported)')
        if page1:
            problems.append('uses bank 1 (RCART1): not supported')
        if rot:
            problems.append(f'rotated screen ({ROTATION.get(rot, rot)}): needs 102x160 (SPEC 4)')
        if audin:
            problems.append('AUDIN bank switching: not supported')
        if eep & 7:
            notes.append('EEPROM: stubbed (reads 0xFF, writes dropped), saves are lost (SPEC 11)')
        if len(payload) < bank0:
            notes.append(f'image is {len(payload)} B, shorter than its {bank0 // 1024} KB bank: '
                         'reads past the end return FF')
        elif len(payload) > bank0:
            notes.append(f'{len(payload) - bank0} B after bank 0 ignored')
    else:
        payload = d
        bs = HEADERLESS.get(len(d))
        print('  header     none (headerless dump)')
        if bs is None:
            problems.append('headerless file that is not 128, 256 or 512 KB: block size unknown')
        else:
            print(f'  banks      block size {bs} B inferred from the size, 256 blocks')
    n, ok, why = first_frame(payload)
    print(f'  loader     {n} block(s), {n * 50} B at $0200: {why}')
    if not ok:
        problems.append(f'loader: {why}')
    groups = ratios(payload)
    zt = sum(z for _, z, _ in groups)
    line = ' '.join(f'{100 * z / n_:.0f}' for n_, z, _ in groups)
    print(f'  zlib -9    {zt} B = {100 * zt / max(1, len(payload)):.1f}% in {len(groups)} x 16 KB groups; per group %: {line}')
    if zstandard:
        st = sum(s for _, _, s in groups)
        line = ' '.join(f'{100 * s / n_:.0f}' for n_, _, s in groups)
        print(f'  zstd -19   {st} B = {100 * st / max(1, len(payload)):.1f}%; per group %: {line}')
    blank = sum(1 for off in range(0, len(payload), 1024) if len(set(payload[off:off + 1024])) == 1)
    print(f'  blank      {blank} of {(len(payload) + 1023) // 1024} KB are one repeated byte')
    for m in notes:
        print(f'  NOTE {m}')
    for p in problems:
        print(f'  FAIL {p}')
    good = not problems
    embed = good and len(payload) <= EMBED_MAX
    print(f'  verdict    drive: {"OK" if good else "no"}, embed (-Dlynx-rom): '
          f'{"OK" if embed else "no" if not good else "too big for the fallback (32 KB)"}')
    return 0 if good else 1


if __name__ == '__main__':
    if len(sys.argv) < 2:
        sys.exit(__doc__.strip().split('\n\n')[1])
    rc = 0
    for p in sys.argv[1:]:
        rc |= main(p)
    sys.exit(rc)
