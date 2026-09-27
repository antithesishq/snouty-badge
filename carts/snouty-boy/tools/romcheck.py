#!/usr/bin/env python3
"""Print a Game Boy ROM header and say whether Snouty Boy can ship it (SPEC.md section 11)."""
import sys

MBC = {0x00: 'none', 0x08: 'none+ram', 0x09: 'none+ram+battery',
       0x01: 'MBC1', 0x02: 'MBC1+ram', 0x03: 'MBC1+ram+battery',
       0x0F: 'MBC3+rtc+battery', 0x10: 'MBC3+rtc+ram+battery', 0x11: 'MBC3', 0x12: 'MBC3+ram', 0x13: 'MBC3+ram+battery',
       0x19: 'MBC5', 0x1A: 'MBC5+ram', 0x1B: 'MBC5+ram+battery', 0x1C: 'MBC5+rumble', 0x1D: 'MBC5+rumble+ram', 0x1E: 'MBC5+rumble+ram+battery'}
RAM_KB = {0: 0, 1: 2, 2: 8, 3: 32, 4: 128, 5: 64}

def main(path):
    d = open(path, 'rb').read()
    if len(d) < 0x150:
        sys.exit(f'{path}: too small to be a ROM')
    title = d[0x134:0x144].split(b'\0')[0].decode('ascii', 'replace')
    cgb = d[0x143]
    mbc = d[0x147]
    rom_kb = 32 << d[0x148]
    ram_kb = RAM_KB.get(d[0x149], -1)
    hdr_sum = 0
    for b in d[0x134:0x14D]:
        hdr_sum = (hdr_sum - b - 1) & 0xFF
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
    if hdr_sum != d[0x14D]:
        problems.append('header checksum mismatch (would not boot on hardware)')
    print(f'{path}\n  title      {title!r}\n  cgb flag   0x{cgb:02X} ({"DMG" if cgb not in (0x80, 0xC0) else "CGB compatible" if cgb == 0x80 else "CGB only"})\n  cartridge  0x{mbc:02X} {MBC.get(mbc, "?")}\n  rom        {rom_kb} KB\n  ram        {ram_kb} KB')
    hard = [p for p in problems if not p.startswith('note')]
    for p in problems:
        print('  ' + ('NOTE ' if p.startswith('note') else 'FAIL ') + p.removeprefix('note: '))
    print('  ' + ('OK to ship' if not hard else 'cannot ship as is'))
    return 0 if not hard else 1

if __name__ == '__main__':
    if len(sys.argv) != 2:
        sys.exit('usage: romcheck.py ROM.gb')
    sys.exit(main(sys.argv[1]))
