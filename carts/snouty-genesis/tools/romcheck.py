#!/usr/bin/env python3
"""Print a Genesis / Mega Drive ROM's header and code heuristics, and say
whether Snouty Genesis can run it (SPEC.md sections 11 and 13).

usage: romcheck.py ROM.bin [ROM.gen ...]

Checks: the header at 0x100 (system, copyright, names, product code,
checksum declared vs computed, I/O support, ROM/RAM ranges, SRAM, region),
SMD interleaving (512-byte SMD header, 16 KB odd/even blocks), size against
the romfs ceiling (warn above 840 KB, refuse above 990 KB), mappers (SSF2
bank registers A130F3-A130FF, "SEGA SSF", over 4 MB), the SVP chip
(Virtua Racing), and the Z80 driver (BUSREQ A11100 / RESET A11200 and
copies into Z80 RAM at A00000). The code scans look for 32-bit absolute
addresses at even offsets, the way 68000 code encodes them (`move.w #n,
$A11100`, `lea $A00000,a0`), so they are heuristics: a driver reached
through a computed address is missed, and data can look like an address
(a given 4-byte pattern turns up about once in 4 GB of random bytes, so
chance hits are rare). Exit status 0 when the verdict is OK or WARN.
"""
import hashlib
import struct
import sys
import zlib

WARN_SIZE = 840 * 1024    # SPEC 13: romfs left over, lower estimate
MAX_SIZE = 990 * 1024     # SPEC 13: upper estimate, refused above
SRAM_MAX = 16 * 1024      # SPEC 11: kept in RAM, not saved
EMBED_BADGE = 8 * 1024    # SPEC 13: embedded ROM in the badge build
IO = {'J': '3-button pad', '6': '6-button pad', 'K': 'keyboard', 'P': 'printer',
      'B': 'control ball', 'F': 'floppy', 'L': 'activator', '4': 'team player',
      '0': 'SMS pad', 'R': 'RS232C', 'T': 'tablet', 'V': 'paddle', 'C': 'CD-ROM',
      'M': 'mouse', 'G': 'light gun'}


def text(d, off, n):
    return d[off:off + n].decode('latin-1').rstrip(' \0')


def u32(d, off):
    return struct.unpack_from('>I', d, off)[0]


def addr_refs(d, addr):
    """Even offsets where the 32-bit big-endian `addr` appears."""
    pat, out, i = struct.pack('>I', addr), [], d.find(struct.pack('>I', addr))
    while i >= 0:
        if i % 2 == 0:
            out.append(i)
        i = d.find(pat, i + 1)
    return out


def deinterleave_smd(body):
    """SMD format: each 16 KB block holds the odd bytes, then the even bytes."""
    out = bytearray(len(body))
    for b in range(0, len(body) - len(body) % 0x4000, 0x4000):
        blk = body[b:b + 0x4000]
        out[b + 1:b + 0x4000:2] = blk[:0x2000]
        out[b:b + 0x4000:2] = blk[0x2000:]
    return bytes(out)


def main(path):
    d = open(path, 'rb').read()
    size = len(d)
    print(path)
    print(f'  size       {size} bytes ({size / 1024:g} KB)')
    print(f'  md5        {hashlib.md5(d).hexdigest()}  crc32 {zlib.crc32(d):08X}')
    problems, notes = [], []

    # SMD interleave: header or interleaved blocks (SPEC 11: refused).
    smd_hdr = size % 0x4000 == 512 and d[8:10] == b'\xAA\xBB'
    raw_ok = d[0x100:0x104] == b'SEGA' or d[0x101:0x105] == b'SEGA'
    smd = False
    if not raw_ok and size > 0x200:
        for skip in ((512, 0) if size % 0x4000 == 512 else (0,)):
            body = d[skip:skip + 0x4000]
            if len(body) == 0x4000 and deinterleave_smd(body)[0x100:0x104] == b'SEGA':
                smd = True
    if smd or smd_hdr:
        print(f'  format     SMD ({"512-byte header" if smd_hdr else "no header"}, '
              f'{"16 KB interleaved blocks" if smd else "interleave not confirmed"})')
        problems.append('SMD-interleaved: convert to a raw .bin first (SPEC 11)')
    else:
        print('  format     raw binary' + ('' if raw_ok else ' (no SEGA at 0x100)'))

    if size < 0x200 or not raw_ok:
        if not smd:
            problems.append('no header: "SEGA" is not at 0x100 (the cart lists only such files)')
        return verdict(problems, notes, size)

    system, copyright_ = text(d, 0x100, 16), text(d, 0x110, 16)
    dom, over = text(d, 0x120, 48), text(d, 0x150, 48)
    product = text(d, 0x180, 14)
    declared = struct.unpack_from('>H', d, 0x18E)[0]
    io = text(d, 0x190, 16)
    rom_s, rom_e, ram_s, ram_e = u32(d, 0x1A0), u32(d, 0x1A4), u32(d, 0x1A8), u32(d, 0x1AC)
    region = text(d, 0x1F0, 16)
    words = d[0x200:size - (size & 1)]
    computed = sum(struct.unpack(f'>{len(words) // 2}H', words)) & 0xFFFF
    hdr_len = rom_e + 1 if rom_e >= 0x200 else None
    if hdr_len and 0x200 <= hdr_len <= size:
        w2 = d[0x200:hdr_len - (hdr_len & 1)]
        computed_hdr = sum(struct.unpack(f'>{len(w2) // 2}H', w2)) & 0xFFFF
    else:
        computed_hdr = None
    print(f'  system     "{system}"   copyright "{copyright_}"')
    print(f'  domestic   "{dom}"')
    print(f'  overseas   "{over}"')
    print(f'  product    "{product}"   region "{region}"')
    print(f'  I/O        "{io}" ({", ".join(IO.get(c, "?" + c) for c in io.replace(" ", "")) or "none"})')
    print(f'  ROM        {rom_s:06X}-{rom_e:06X} declared, file ends at {size - 1:06X}')
    print(f'  RAM        {ram_s:06X}-{ram_e:06X}')
    ok_sum = computed == declared or computed_hdr == declared
    extra = f', {computed_hdr:04X} up to the header ROM end' if computed_hdr not in (None, computed) else ''
    print(f'  checksum   declared {declared:04X}, computed {computed:04X} over 0x200-EOF{extra} '
          f'({"match" if ok_sum else "mismatch"})')
    if not ok_sum:
        notes.append('checksum mismatch: fine unless the game checks it (the core never patches ROM)')
    if not system.startswith(('SEGA', ' SEGA')):
        notes.append(f'system name "{system}" does not start with SEGA')
    if rom_e + 1 != size:
        notes.append(f'header ROM end {rom_e:06X} does not match the file size ({size - 1:06X})')
    if size & 1:
        notes.append('odd file size (a trailing byte the 68000 cannot address as a word)')
    # Old-style letters (J, U, E) or a new-style hex digit (bit 0 Japan,
    # bit 2 USA, bit 3 Europe). The core is an NTSC export machine (SPEC 3).
    ntsc = 'U' in region or 'J' in region or any(
        c in '0123456789ABCDEF' and int(c, 16) & 0x5 for c in region[:3])
    if not ntsc:
        notes.append(f'region "{region}" looks PAL-only; a region check in the game may refuse to run')
    # SRAM (SPEC 11: up to 16 KB, in RAM, not saved).
    if d[0x1B0:0x1B2] == b'RA':
        # "RA", 1x1yz000, then 20 (SRAM) or 40 (serial EEPROM): x = backed
        # up, yz = 00 both bytes (16-bit), 10 even bytes, 11 odd bytes.
        kind = d[0x1B2]
        s_start, s_end = u32(d, 0x1B4), u32(d, 0x1B8)
        yz = (kind >> 3) & 3
        lanes = {0: 'both bytes', 2: 'even bytes', 3: 'odd bytes'}.get(yz, 'lanes ?')
        nbytes = (s_end - s_start) // 2 + 1 if yz in (2, 3) else s_end - s_start + 1
        eeprom = d[0x1B3] == 0x40
        print(f'  SRAM       "RA" type {kind:02X} ({"EEPROM" if eeprom else "SRAM"}, '
              f'{"backup" if kind & 0x40 else "no backup"}, {lanes}), '
              f'{s_start:06X}-{s_end:06X}, {nbytes} bytes')
        if eeprom:
            problems.append('serial EEPROM save chip: not emulated')
        elif nbytes > SRAM_MAX:
            problems.append(f'SRAM of {nbytes} bytes is over the 16 KB limit')
        elif nbytes <= 0:
            notes.append('SRAM range is empty or reversed')
    else:
        print('  SRAM       none declared')

    # Size (SPEC 13).
    if size > MAX_SIZE:
        problems.append(f'{size // 1024} KB is over the ~990 KB romfs ceiling (SPEC 13)')
    elif size > WARN_SIZE:
        notes.append(f'{size // 1024} KB is above 840 KB: fits only with a small cart image and an otherwise empty drive')

    # Mapper (SSF2) and SVP.
    ssf = {a: len(addr_refs(d, a)) for a in range(0xA130F3, 0xA13100, 2)}
    ssf_total = sum(ssf.values())
    sram_ctl = len(addr_refs(d, 0xA130F1))
    ssf_hdr = 'SSF' in system
    print(f'  mapper     bank regs A130F3-FF x{ssf_total}'
          + (f' ({", ".join(f"{a:06X} x{n}" for a, n in ssf.items() if n)})' if ssf_total else '')
          + f', SRAM control A130F1 x{sram_ctl}, system "SEGA SSF" {"yes" if ssf_hdr else "no"}')
    if size > 4 * 1024 * 1024 or ssf_hdr or ssf_total >= 2:
        problems.append('bank-switching mapper (SSF2 style) or over 4 MB: not supported')
    elif ssf_total:
        notes.append('one A130Fx bank-register reference: probably data')
    svp_regs = len(addr_refs(d, 0xA15000)) + len(addr_refs(d, 0xA15004)) + len(addr_refs(d, 0xA15006))
    svp = 'VIRTUA RACING' in (dom + over).upper() or 'MK-1229' in product or d[0x1C8:0x1CA] == b'SV'
    print(f'  SVP        {"YES" if svp else "no"} (name/product/"SV" at 1C8), A15000-6 refs x{svp_regs}')
    if svp:
        problems.append('SVP chip (Virtua Racing): not emulated')

    # Z80 driver and sound.
    busreq, reset = len(addr_refs(d, 0xA11100)), len(addr_refs(d, 0xA11200))
    z80ram = addr_refs(d, 0xA00000)
    # lea $A00000,an (41F9|n<<9) or movea.l #$A00000,an (207C|n<<9) before it.
    copies = sum(1 for o in z80ram if o >= 2 and
                 (struct.unpack_from('>H', d, o - 2)[0] & 0xF1FF) in (0x41F9, 0x207C))
    ym = sum(len(addr_refs(d, a)) for a in (0xA04000, 0xA04001, 0xA04002, 0xA04003))
    psg = len(addr_refs(d, 0xC00011))
    vdp = len(addr_refs(d, 0xC00004)) + len(addr_refs(d, 0xC00000))
    print(f'  Z80        BUSREQ A11100 x{busreq}, RESET A11200 x{reset}, A00000 x{len(z80ram)} '
          f'({copies} as lea/movea base)')
    print(f'  sound      YM2612 A04000-3 from the 68000 x{ym}, PSG C00011 x{psg}')
    print(f'  VDP        C00000/C00004 refs x{vdp}')
    if busreq and reset and (z80ram or copies):
        print('  driver     Z80 sound driver likely (bus request, reset and Z80 RAM all referenced)')
    elif busreq or reset:
        print('  driver     Z80 bus touched, no copy into A00000 seen (computed address or none)')
    else:
        print('  driver     no Z80 driver seen (the Z80 may stay in reset; PSG/YM from the 68000 only)')
    if size <= EMBED_BADGE:
        notes.append(f'{size} bytes: small enough to embed in the badge build (SPEC 13: 0-8 KB)')
    return verdict(problems, notes, size)


def verdict(problems, notes, size):
    for n in notes:
        print(f'  NOTE {n}')
    for p in problems:
        print(f'  FAIL {p}')
    if problems:
        v = 'REFUSED'
    elif size > WARN_SIZE:
        v = 'WARN'
    else:
        v = 'OK'
    where = 'drive (romfs) and -Dmd-rom' if v != 'REFUSED' else 'none'
    print(f'  verdict    {v}: {where}')
    return 1 if problems else 0


if __name__ == '__main__':
    if len(sys.argv) < 2:
        sys.exit(__doc__.strip().split('\n\n')[1])
    rc = 0
    for p in sys.argv[1:]:
        rc |= main(p)
    sys.exit(rc)
