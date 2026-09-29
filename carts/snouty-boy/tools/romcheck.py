#!/usr/bin/env python3
"""Print a Game Boy (Color) ROM header and say whether Snouty Boy can ship it.

SPEC.md sections 11 and 19: CGB-flagged ROMs boot as a Game Boy Color, cart
RAM up to 32 KB, ROMs over 64 KB need the XIP cart, over 256 KB do not fit.
Also prints hints for CGB double speed (code writing KEY1, 0xFF4D) and
HDMA (code writing HDMA5, 0xFF55), which cost CPU time on the badge.
"""
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
    title = d[0x134:0x143 if d[0x143] & 0x80 else 0x144].split(b'\0')[0].decode('ascii', 'replace')
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
    if rom_kb > 256:
        problems.append(f'{rom_kb} KB ROM exceeds the 256 KB XIP cart flash window')
    elif rom_kb > 64:
        problems.append(f'note: {rom_kb} KB ROM needs the XIP cart (-Dcart-mode=xip); the RAM cart fits 64 KB')
    if ram_kb > 32:
        problems.append(f'note: {ram_kb} KB cart RAM is capped at 32 KB (banks past 3 wrap)')
    if ram_kb < 0:
        problems.append(f'unknown cart RAM size code 0x{d[0x149]:02X}')
    if hdr_sum != d[0x14D]:
        problems.append('header checksum mismatch (would not boot on hardware)')
    is_cgb = (cgb & 0x80) != 0
    flag = 'DMG' if not is_cgb else 'CGB compatible' if cgb == 0x80 else 'CGB only' if cgb == 0xC0 else 'CGB (odd flag)'
    # Code hints: LDH (0x4D),A / LD (0xFF4D),A and the same for HDMA5.
    def writes(reg):
        return d.count(bytes([0xE0, reg])) + d.count(bytes([0xEA, reg, 0xFF]))
    speed = writes(0x4D)
    hdma = writes(0x55)
    ram_used = min(max(ram_kb, 0), 32)
    print(f'{path}\n  title      {title!r}\n  cgb flag   0x{cgb:02X} ({flag})\n  model      {"CGB" if is_cgb else "DMG"}\n  cartridge  0x{mbc:02X} {MBC.get(mbc, "?")}\n  rom        {rom_kb} KB\n  ram        {ram_kb} KB (cart RAM buffer {ram_used} KB)')
    if is_cgb:
        print(f'  hints      double speed {"likely" if speed else "no"} ({speed} KEY1 writes), HDMA {"likely" if hdma else "no"} ({hdma} HDMA5 writes)')
    hard = [p for p in problems if not p.startswith('note')]
    for p in problems:
        print('  ' + ('NOTE ' if p.startswith('note') else 'FAIL ') + p.removeprefix('note: '))
    print('  ' + ('OK to ship' if not hard else 'cannot ship as is'))
    return 0 if not hard else 1

if __name__ == '__main__':
    if len(sys.argv) != 2:
        sys.exit('usage: romcheck.py ROM.gb|ROM.gbc')
    sys.exit(main(sys.argv[1]))
