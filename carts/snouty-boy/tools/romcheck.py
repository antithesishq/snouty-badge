#!/usr/bin/env python3
"""Print a Game Boy (Color) ROM header, say whether Snouty Boy can ship it
embedded (SPEC.md sections 11 and 19) and what the badge-drive loader will do
with the file (PLAN.md M5, docs/ROM_DRIVE.md at the repository root).

CGB-flagged ROMs boot as a Game Boy Color, cart RAM up to 32 KB. Embedded,
ROMs over 64 KB need the XIP cart and over 256 KB do not fit; from the drive
anything up to 1 MB plays. Also prints hints for CGB double speed (code
writing KEY1, 0xFF4D) and HDMA (code writing HDMA5, 0xFF55), which cost CPU
time on the badge.

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
    if code == 2:
        return 0x2000
    return 0x8000


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
    if cgb & 0x80:
        lines.append(f'cgb        0x{cgb:02X}: runs as a Game Boy Color (picker hint "Color")')
    else:
        lines.append(f'cgb        0x{cgb:02X}: runs as a DMG')

    want = header_checksum(d)
    if want == d[0x14D]:
        lines.append(f'checksum   0x14D = 0x{want:02X} OK over 0x134..0x14C')
    else:
        lines.append(f'checksum   0x14D = 0x{d[0x14D]:02X}, computed 0x{want:02X}: mismatch, listed as unplayable')
        playable = False

    lines.append(f'keyframe   {ram} bytes of cart RAM beside the live console and in every keyframe '
                 f'(page store, {(ram + 511) // 512} of its 512-byte pages)')
    lines.append(f'crc32      {zlib.crc32(d[:kept]) & 0xFFFFFFFF:08X} (the About screen shows the same)')
    return lines, playable


def main(path):
    d = open(path, 'rb').read()
    if len(d) < 0x150:
        print(f'{path}: too small to be a ROM ({len(d)} bytes)')
        print('  drive loader: listed as unplayable')
        return 1
    title = d[0x134:0x143 if d[0x143] & 0x80 else 0x144].split(b'\0')[0].decode('ascii', 'replace')
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
    if rom_kb > 256:
        problems.append(f'{rom_kb} KB ROM exceeds the 256 KB XIP cart flash window')
    elif rom_kb > 64:
        problems.append(f'note: {rom_kb} KB ROM needs the XIP cart (-Dcart-mode=xip); the RAM cart fits 64 KB')
    if ram_kb > 32:
        problems.append(f'note: {ram_kb} KB cart RAM is capped at 32 KB (banks past 3 wrap)')
    if ram_kb < 0:
        problems.append(f'unknown cart RAM size code 0x{d[0x149]:02X}')
    if header_checksum(d) != d[0x14D]:
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
        sys.exit('usage: romcheck.py ROM.gb|ROM.gbc')
    sys.exit(main(sys.argv[1]))
