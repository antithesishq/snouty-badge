#!/usr/bin/env python3
"""Print a Game Gear / Master System ROM's header and code heuristics, and say
whether Snouty Gear can run it (SPEC.md section 11).

usage: romcheck.py ROM.gg [ROM.sms ...]

The header ("TMR SEGA") is looked for at 7FF0, then 3FF0 and 1FF0. The
mapper and port summaries come from scanning the bytes for Z80 instruction
patterns (LD (nn),A; LD (nn),HL; OUT (n),A; LD A,n before them), so they
are heuristics: data can look like code, and code that computes addresses
or uses OUT (C) is missed.
"""
import sys
import zlib
import hashlib

REGION = {3: 'SMS Japan', 4: 'SMS export', 5: 'GG Japan', 6: 'GG export', 7: 'GG international'}
SIZE_KB = {0xA: 8, 0xB: 16, 0xC: 32, 0xD: 48, 0xE: 64, 0xF: 128, 0x0: 256, 0x1: 512, 0x2: 1024}
EMBED_MAX = 128 * 1024   # SPEC 11: embedded fallback / simulator ROM
DRIVE_MAX = 512 * 1024   # core/rom.zig max_banks (32 x 16 KB)
BANK = 0x4000


def find_header(d):
    for off in (0x7FF0, 0x3FF0, 0x1FF0):
        if len(d) >= off + 16 and d[off:off + 8] == b'TMR SEGA':
            return off
    return None


def bcd(b):
    return f'{b >> 4:x}{b & 0xF:x}'


def scan(d, pattern):
    """Offsets where `pattern` (bytes) occurs."""
    out, i = [], d.find(pattern)
    while i >= 0:
        out.append(i)
        i = d.find(pattern, i + 1)
    return out


def imm_before(d, off):
    """Value of an `LD A,n` (3E n) right before `off`, else None."""
    if off >= 2 and d[off - 2] == 0x3E:
        return d[off - 1]
    return None


def main(path):
    d = open(path, 'rb').read()
    size = len(d)
    banks = (size + BANK - 1) // BANK
    used = sum(1 for i in range(banks) if len(set(d[i * BANK:(i + 1) * BANK])) > 1)
    print(f'{path}')
    print(f'  size       {size} bytes ({size / 1024:g} KB), {banks} banks of 16 KB, {used} not blank')
    print(f'  md5        {hashlib.md5(d).hexdigest()}  crc32 {zlib.crc32(d):08X}')

    problems, notes = [], []
    h = find_header(d)
    region = None
    if h is None:
        notes.append('no "TMR SEGA" header (fine on the Game Gear, which does not check it)')
    else:
        r = d[h + 15]
        region = r >> 4
        code = (f'{d[h + 14] >> 4:x}' if d[h + 14] >> 4 else '') + bcd(d[h + 13]) + bcd(d[h + 12])
        stored = d[h + 10] | d[h + 11] << 8
        hdr_kb = SIZE_KB.get(r & 0xF)
        end = min(size, (hdr_kb or 0) * 1024)
        calc = (sum(d[:min(end, h)]) + sum(d[0x8000:end])) & 0xFFFF
        print(f'  header     at {h:04X}: product {code}, version {d[h + 14] & 0xF}, '
              f'region {region} ({REGION.get(region, "unknown")}), size code {r & 0xF:X} '
              f'({str(hdr_kb) + " KB" if hdr_kb else "invalid"})')
        print(f'  checksum   stored {stored:04X}, computed {calc:04X} '
              f'({"match" if stored == calc else "mismatch; the Game Gear does not check it"})')
        if hdr_kb and hdr_kb * 1024 != size:
            notes.append(f'header size code says {hdr_kb} KB, file is {size // 1024} KB')
        if region in (3, 4):
            problems.append('Master System ROM: runs only if it works in Game Gear mode (few do)')
        elif region not in (5, 6, 7):
            notes.append(f'unknown region code {region}')

    # Mapper: writes to FFFC-FFFF.
    writes = {}
    for reg in (0xFC, 0xFD, 0xFE, 0xFF):
        sites = scan(d, bytes([0x32, reg, 0xFF]))            # LD (FFxx),A
        sites += scan(d, bytes([0x22, reg, 0xFF]))           # LD (FFxx),HL
        for op in (0x43, 0x53, 0x63, 0x73):
            sites += scan(d, bytes([0xED, op, reg, 0xFF]))   # LD (FFxx),rr
        writes[reg] = sites
    hl_refs = len(scan(d, bytes([0x21, 0xFC, 0xFF]))) + len(scan(d, bytes([0x21, 0xFD, 0xFF])))
    slot_writes = sum(len(writes[r]) for r in (0xFD, 0xFE, 0xFF))
    fffc_vals = sorted({v for o in writes[0xFC] if (v := imm_before(d, o)) is not None})
    mapper = 'Sega' if slot_writes or hl_refs or size > 48 * 1024 else 'none (<= 48 KB, no slot writes found)'
    print(f'  mapper     {mapper}: FFFC x{len(writes[0xFC])}, FFFD x{len(writes[0xFD])}, '
          f'FFFE x{len(writes[0xFE])}, FFFF x{len(writes[0xFF])} direct writes, '
          f'{hl_refs} LD HL,FFFC/FFFD')
    cart_ram = 'none seen'
    if fffc_vals:
        vals = ', '.join(f'{v:02X}' for v in fffc_vals)
        if any(v & 0x04 for v in fffc_vals if v & 0x08):
            cart_ram = f'32 KB (FFFC values {vals}: bit 3 with bank bit 2)'
            problems.append('cart RAM over 8 KB (FFFC bit 2 with bit 3)')
        elif any(v & 0x08 for v in fffc_vals):
            cart_ram = f'yes, 8-16 KB bank 0 (FFFC values {vals}: bit 3)'
        else:
            cart_ram = f'no (FFFC values {vals}: bit 3 clear)'
    elif writes[0xFC]:
        cart_ram = 'unknown (FFFC written with a computed value)'
        notes.append('FFFC is written; cart RAM use cannot be told from the bytes')
    print(f'  cart RAM   {cart_ram}')

    # Ports.
    out = lambda p: scan(d, bytes([0xD3, p]))
    vdp_ctl = out(0xBF)
    regs = {}
    for o in vdp_ctl:
        v = imm_before(d, o)
        if v is not None and v & 0xC0 == 0x80 and o >= 6 and d[o - 4] == 0xD3 and d[o - 3] == 0xBF:
            val = imm_before(d, o - 4)
            regs.setdefault(v & 0x0F, set()).add(val)
    ld_c_bf = len(scan(d, bytes([0x0E, 0xBF])))
    print(f'  VDP        OUT (BF),A x{len(vdp_ctl)}, OUT (BE),A x{len(out(0xBE))}, LD C,BF x{ld_c_bf} (OUT (C) paths)')
    if regs:
        desc = '; '.join(f'r{r}=' + ','.join('??' if v is None else f'{v:02X}' for v in sorted(vals, key=lambda x: -1 if x is None else x))
                         for r, vals in sorted(regs.items()))
        print(f'  VDP regs   immediate register writes: {desc}')
    line_irq = 10 in regs or any(v is not None and v & 0x10 for v in regs.get(0, ()))
    print(f'  line IRQ   {"likely (register 10 or r0 bit 4 written)" if line_irq else "not seen"}')
    psg = len(out(0x7F)) + len(out(0x7E))
    fm_any = sum(len(out(p)) for p in (0xF0, 0xF1, 0xF2))
    # A two-byte pattern turns up about size / 64 KB times in random data,
    # so FM use needs the stricter LD A,n; OUT (F0-F2),A form, twice.
    fm = sum(1 for p in (0xF0, 0xF1, 0xF2) for o in out(p) if imm_before(d, o) is not None)
    stereo = len(out(0x06))
    print(f'  sound      PSG OUT (7E/7F),A x{psg}, stereo OUT (06),A x{stereo}, '
          f'FM OUT (F0-F2),A x{fm_any} ({fm} after LD A,n)')
    print(f'  (chance)   any 2-byte pattern appears ~{size / 65536:.0f}x in {size // 1024} KB of non-code bytes')
    if fm >= 2:
        problems.append(f'writes the FM ports F0-F2 ({fm} LD A,n; OUT sites; no FM on the Game Gear)')
    elif fm_any:
        notes.append('OUT (F0-F2) byte pairs seen, at chance level: probably data, not FM')
    if line_irq:
        notes.append('uses the line interrupt: fine unless it changes registers mid-line (SPEC 4)')

    # Verdict (SPEC.md section 11).
    embed_ok = size <= EMBED_MAX
    drive_ok = size <= DRIVE_MAX
    if size > EMBED_MAX:
        notes.append(f'{size // 1024} KB: too big to embed (128 KB max); from the drive, or the XIP packer (SPEC 13.1)')
    elif size > 64 * 1024:
        notes.append(f'{size // 1024} KB embedded leaves less RAM for the keyframe ring (64 KB ideal, SPEC 13)')
    if not drive_ok:
        problems.append(f'{size // 1024} KB is over the 512 KB bank table')
    for n in notes:
        print(f'  NOTE {n}')
    for p in problems:
        print(f'  FAIL {p}')
    ok = not problems
    print(f'  verdict    drive: {"OK" if ok and drive_ok else "no"}, embed (-Dgg-rom): {"OK" if ok and embed_ok else "no"}')
    return 0 if ok else 1


if __name__ == '__main__':
    if len(sys.argv) < 2:
        sys.exit(__doc__.strip().split('\n\n')[1])
    rc = 0
    for p in sys.argv[1:]:
        rc |= main(p)
    sys.exit(rc)
