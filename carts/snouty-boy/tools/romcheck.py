#!/usr/bin/env python3
"""Print a Game Boy ROM header, say whether Snouty Boy can ship it embedded
(SPEC.md section 11) and what the badge-drive loader will do with the file
(PLAN.md M5, docs/ROM_DRIVE.md at the repository root).

The drive section mirrors the core (core/rom.zig, core/mmu.zig) and the
frontend's checks (cart/src/frontend/romsrc.zig); keep them in step."""
import sys
import zlib

MBC = {0x00: 'none', 0x08: 'none+ram', 0x09: 'none+ram+battery',
       0x01: 'MBC1', 0x02: 'MBC1+ram', 0x03: 'MBC1+ram+battery',
       0x0F: 'MBC3+rtc+battery', 0x10: 'MBC3+rtc+ram+battery', 0x11: 'MBC3', 0x12: 'MBC3+ram', 0x13: 'MBC3+ram+battery',
       0x19: 'MBC5', 0x1A: 'MBC5+ram', 0x1B: 'MBC5+ram+battery', 0x1C: 'MBC5+rumble', 0x1D: 'MBC5+rumble+ram', 0x1E: 'MBC5+rumble+ram+battery'}
RAM_KB = {0: 0, 1: 2, 2: 8, 3: 32, 4: 128, 5: 64}

# core/rom.zig max_bytes: the core keeps at most 64 banks of 16 KB.
MAX_BYTES = 1024 * 1024
BANK = 0x4000
# The frontend's playable range (romsrc.zig): a header needs 0x150 bytes.
MIN_BYTES = 0x150


def core_mapper(code):
    """mmu.Mbc.from_header: the controller the core emulates for 0x147."""
    if code in (0x00, 0x08, 0x09):
        return 'none', True
    if code in (0x01, 0x02, 0x03):
        return 'MBC1', True
    if 0x0F <= code <= 0x13:
        return 'MBC3', True
    if 0x19 <= code <= 0x1E:
        return 'MBC5', True
    return 'none', False


def core_ram_len(code):
    """mmu.ram_len_for: cart RAM bytes the core uses (and keyframes hold)."""
    if code == 0:
        return 0
    if code == 1:
        return 0x800
    return 0x2000


def header_checksum(d):
    s = 0
    for b in d[0x134:0x14D]:
        s = (s - b - 1) & 0xFF
    return s


def drive_report(d):
    """What the badge-drive loader does with this file; returns (lines, playable)."""
    lines = []
    n = len(d)
    if n < MIN_BYTES:
        return [f'size       {n} bytes: too small for a header, listed as unplayable'], False
    if n > MAX_BYTES:
        lines.append(f'size       {n} bytes: over the 1 MB cap, listed as unplayable '
                     f'(the core would keep only the first {MAX_BYTES} bytes)')
        playable = False
    else:
        lines.append(f'size       {n} bytes: fits the 1 MB cap')
        playable = True
    kept = min(n, MAX_BYTES)
    banks = 2
    while banks * BANK < kept:
        banks *= 2
    partial = ' (last bank partial, reads past the end give 0xFF)' if kept % BANK else ''
    lines.append(f'banks      {(kept + BANK - 1) // BANK} of 16 KB, bank mask {banks - 1}{partial}')

    mbc = d[0x147]
    kind, known = core_mapper(mbc)
    if known:
        lines.append(f'mapper     0x{mbc:02X} {MBC.get(mbc, "?")}: core runs it as {kind}')
    else:
        lines.append(f'mapper     0x{mbc:02X}: not supported (none/MBC1/MBC3/MBC5); '
                     'hint only, the core runs it without a controller and it will likely crash')
    if mbc in (0x0F, 0x10):
        lines.append('           hint: MBC3 real-time clock not emulated (clock reads return 0xFF)')

    ram_code = d[0x149]
    ram = core_ram_len(ram_code)
    declared = RAM_KB.get(ram_code)
    declared_s = f'{declared} KB' if declared is not None else 'unknown size'
    capped = ''
    if declared is not None and declared * 1024 > ram:
        capped = f', capped to {ram // 1024} KB (hint: a game using more RAM banks will misbehave)'
    elif declared is None:
        capped = f', core uses {ram // 1024} KB'
    elif ram_code == 1:
        capped = ', mirrored every 2 KB'
    lines.append(f'cart ram   code 0x{ram_code:02X} = {declared_s}{capped}')

    cgb = d[0x143]
    if cgb == 0xC0:
        lines.append('cgb        0xC0 CGB only: hint only, it will likely show garbage or stop on a DMG')
    elif cgb == 0x80:
        lines.append('cgb        0x80 CGB compatible: runs in DMG mode')
    else:
        lines.append(f'cgb        0x{cgb:02X} DMG')

    want = header_checksum(d)
    if want == d[0x14D]:
        lines.append(f'checksum   0x14D = 0x{want:02X} OK over 0x134..0x14C')
    else:
        lines.append(f'checksum   0x14D = 0x{d[0x14D]:02X}, computed 0x{want:02X}: mismatch, listed as unplayable')
        playable = False

    lines.append(f'keyframe   {ram} bytes of cart RAM per slot, plus the fixed keyframe (@sizeOf(Gb.Fixed))')
    lines.append(f'crc32      {zlib.crc32(d[:kept]) & 0xFFFFFFFF:08X} (the About screen shows the same)')
    return lines, playable


def main(path):
    d = open(path, 'rb').read()
    if len(d) < 0x150:
        print(f'{path}: too small to be a ROM ({len(d)} bytes)')
        print('  drive loader: listed as unplayable')
        return 1
    title = d[0x134:0x144].split(b'\0')[0].decode('ascii', 'replace')
    cgb = d[0x143]
    mbc = d[0x147]
    rom_kb = 32 << d[0x148]
    ram_kb = RAM_KB.get(d[0x149], -1)
    problems = []
    if len(d) != rom_kb * 1024:
        problems.append(f'file is {len(d)} bytes but header says {rom_kb} KB')
    if mbc not in MBC:
        problems.append(f'unsupported cartridge type 0x{mbc:02X}')
    if 0x0F <= mbc <= 0x10:
        problems.append('uses the MBC3 real-time clock (not emulated)')
    if cgb == 0xC0:
        problems.append('Game Boy Color only')
    if rom_kb > 128:
        problems.append(f'{rom_kb} KB ROM exceeds the 128 KB cart budget')
    elif rom_kb > 64:
        problems.append(f'note: {rom_kb} KB ROM leaves under 2 s of scrub depth')
    if ram_kb > 8:
        problems.append(f'{ram_kb} KB cart RAM exceeds the 8 KB supported')
    if header_checksum(d) != d[0x14D]:
        problems.append('header checksum mismatch (would not boot on hardware)')
    print(f'{path}\n  title      {title!r}\n  cgb flag   0x{cgb:02X} ({"DMG" if cgb not in (0x80, 0xC0) else "CGB compatible" if cgb == 0x80 else "CGB only"})\n  cartridge  0x{mbc:02X} {MBC.get(mbc, "?")}\n  rom        {rom_kb} KB\n  ram        {ram_kb} KB')
    hard = [p for p in problems if not p.startswith('note')]
    print('embedded (-Drom):')
    for p in problems:
        print('  ' + ('NOTE ' if p.startswith('note') else 'FAIL ') + p.removeprefix('note: '))
    print('  ' + ('OK to ship' if not hard else 'cannot ship as is'))

    lines, playable = drive_report(d)
    print('badge drive:')
    for line in lines:
        print('  ' + line)
    print('  ' + ('playable from the drive' if playable else 'not playable from the drive'))
    return 0 if not hard else 1


if __name__ == '__main__':
    if len(sys.argv) != 2:
        sys.exit('usage: romcheck.py ROM.gb')
    sys.exit(main(sys.argv[1]))
