#!/usr/bin/env python3
"""Write (or list) a FAT12 image of the badge USB drive, the OS "romfs" region.

    python3 tools/make_romfs.py OUT.img FILE... [--size 1280K] [--truncate]
                                [--fragment N] [--delete FILE] [--dir NAME]
    python3 tools/make_romfs.py --list IMG

The image is a super-floppy in exactly the geometry the badge OS formats
(sycl-badge/src/os/loader/storage.zig, formatVolume): 512-byte sectors,
1 reserved sector, 2 FATs, 32 root entries, 1 sector per cluster, total
sectors = size / 512, FAT size from the same fixed-point loop, the OS boot
sector fields, the "SYCLBADGE" volume label as the first root entry. Files
are then added the way a macOS or Windows host writes them: an 8.3 alias
(NAME~1.EXT when the long name does not fit 8.3) preceded by long-file-name
entries whenever the name is not already an upper-case 8.3 name.

FILE may be PATH=NAME to store PATH under the drive name NAME (so a test can
add "Sonic The Hedgehog (World).gg" or a macOS "._" AppleDouble sibling
without such a file on disk).

  --size S       volume size (default 1280K, the OS romfs region; K/M suffix)
  --truncate     end the image at the last used sector (committed fixtures)
  --fragment N   hand out clusters N at a time round-robin over the files,
                 so files with more than N clusters are not contiguous (with
                 one file, leave N free clusters after every N)
  --delete FILE  add FILE (PATH or PATH=NAME) first, then mark its directory
                 entries deleted (0xE5) and free its FAT chain, leaving its
                 data in place, as a host delete does; repeatable
  --dir NAME     add an empty sub-directory NAME (one cluster with . and ..),
                 like the .fseventsd a Mac leaves; repeatable
  --list IMG     print the boot sector geometry, every root entry (deleted
                 ones too) and each file's cluster chain

Entries go into the root directory in this order: volume label, --delete
files, --dir directories, FILEs. Timestamps are fixed so images are
reproducible. Python 3 standard library only.
"""
import argparse
import os
import struct
import sys

SECTOR = 512
RESERVED = 1
NUM_FATS = 2
ROOT_ENTRIES = 32
SPC = 1
MEDIA = 0xF8
ROOT_SECTORS = (ROOT_ENTRIES * 32 + SECTOR - 1) // SECTOR
EOC = 0xFFF
# 2026-09-29 12:00:00, FAT packed date and time.
FAT_DATE = ((2026 - 1980) << 9) | (9 << 5) | 29
FAT_TIME = (12 << 11)
SFN_OK = set(b"ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!#$%&'()-@^_`{}~")


def fat_sectors(total):
    """storage.zig fatSectors(): iterate until the FAT covers the data clusters."""
    fs = 1
    while True:
        data = total - RESERVED - ROOT_SECTORS - NUM_FATS * fs
        need = ((data // SPC * 3 + 1) // 2 + SECTOR - 1) // SECTOR
        if need == fs:
            return fs
        fs = need


def parse_size(s):
    s = s.strip().upper()
    mul = 1
    if s.endswith('K'):
        mul, s = 1024, s[:-1]
    elif s.endswith('M'):
        mul, s = 1024 * 1024, s[:-1]
    n = int(s, 0) * mul
    if n % SECTOR or n < 64 * SECTOR:
        raise SystemExit(f"make_romfs: --size must be a multiple of 512 and at least 32 KB, got {n}")
    return n


def boot_sector(total, fs):
    """formatVolume()'s boot sector, field for field."""
    b = bytearray(SECTOR)
    b[0:3] = b'\xEB\x3C\x90'
    b[3:11] = b'SYCLBADG'
    struct.pack_into('<H', b, 11, SECTOR)
    b[13] = SPC
    struct.pack_into('<H', b, 14, RESERVED)
    b[16] = NUM_FATS
    struct.pack_into('<H', b, 17, ROOT_ENTRIES)
    struct.pack_into('<H', b, 19, total)
    b[21] = MEDIA
    struct.pack_into('<H', b, 22, fs)
    struct.pack_into('<H', b, 24, 32)
    struct.pack_into('<H', b, 26, 64)
    struct.pack_into('<I', b, 28, 0)
    struct.pack_into('<I', b, 32, 0)
    b[36] = 0x80
    b[38] = 0x29
    struct.pack_into('<I', b, 39, 0x20260120)
    b[43:54] = b'SYCLBADGE  '
    b[54:62] = b'FAT12   '
    struct.pack_into('<H', b, 510, 0xAA55)
    return b


def fat_set(fat, cluster, value):
    off = cluster + cluster // 2
    value &= 0xFFF
    if cluster & 1:
        fat[off] = (fat[off] & 0x0F) | ((value << 4) & 0xF0)
        fat[off + 1] = (value >> 4) & 0xFF
    else:
        fat[off] = value & 0xFF
        fat[off + 1] = (fat[off + 1] & 0xF0) | (value >> 8)


def fat_get(fat, cluster):
    off = cluster + cluster // 2
    v = fat[off] | (fat[off + 1] << 8)
    return (v >> 4) if cluster & 1 else (v & 0xFFF)


def sfn_checksum(name11):
    s = 0
    for c in name11:
        s = (((s & 1) << 7) + (s >> 1) + c) & 0xFF
    return s


def short_name(long, taken):
    """(11-byte 8.3 name, needs_lfn) the way Windows/macOS derive an alias."""
    base, dot, ext = long.rpartition('.')
    if not dot or not base:
        base, ext = long, ''

    def clean(s):
        out, lossy = bytearray(), False
        for ch in s:
            if ch in ' .':
                lossy = True
                continue
            c = ch.upper()
            if len(c) == 1 and ord(c) < 128 and ord(c) in SFN_OK:
                out.append(ord(c))
            else:
                out.append(ord('_'))
                lossy = True
        return bytes(out), lossy

    b, lb = clean(base.lstrip('.'))
    e, le = clean(ext)
    if long.startswith('.'):
        lb = True
    exact = (not lb and not le and 0 < len(b) <= 8 and len(e) <= 3
             and long.upper() == (b.decode() + ('.' + e.decode() if e else '')))
    if exact:
        n11 = b.ljust(8, b' ') + e.ljust(3, b' ')
        if n11 in taken:
            raise SystemExit(f"make_romfs: duplicate name {long}")
        return n11, False
    e = e[:3]
    if not b:
        b = b'_'
    for i in range(1, 1000000):
        tail = b'~%d' % i
        n11 = (b[:8 - len(tail)] + tail).ljust(8, b' ') + e.ljust(3, b' ')
        if n11 not in taken:
            return n11, True
    raise SystemExit("make_romfs: out of 8.3 aliases")


def lfn_entries(long, checksum):
    """LFN directory entries in on-disk order (highest sequence first)."""
    units = list(long.encode('utf-16-le'))
    chars = [units[i] | (units[i + 1] << 8) for i in range(0, len(units), 2)]
    if len(chars) > 255:
        raise SystemExit(f"make_romfs: name longer than 255 characters: {long}")
    if len(chars) % 13:
        chars.append(0)
    while len(chars) % 13:
        chars.append(0xFFFF)
    n = len(chars) // 13
    ents = []
    for k in range(n, 0, -1):
        e = bytearray(32)
        e[0] = k | (0x40 if k == n else 0)
        part = chars[(k - 1) * 13:k * 13]
        for i, c in enumerate(part):
            off = (1 + 2 * i) if i < 5 else (14 + 2 * (i - 5)) if i < 11 else (28 + 2 * (i - 11))
            struct.pack_into('<H', e, off, c)
        e[11] = 0x0F
        e[12] = 0
        e[13] = checksum
        ents.append(e)
    return ents


def sfn_entry(n11, attr, cluster, size):
    e = bytearray(32)
    e[0:11] = n11
    e[11] = attr
    struct.pack_into('<HHH', e, 14, FAT_TIME, FAT_DATE, FAT_DATE)
    struct.pack_into('<HH', e, 22, FAT_TIME, FAT_DATE)
    struct.pack_into('<H', e, 26, cluster)
    struct.pack_into('<I', e, 28, size)
    return e


def split_spec(spec):
    if '=' in spec:
        path, name = spec.split('=', 1)
    else:
        path, name = spec, os.path.basename(spec)
    return path, name


def build(a):
    size = parse_size(a.size)
    total = size // SECTOR
    fs = fat_sectors(total)
    data_start = RESERVED + NUM_FATS * fs + ROOT_SECTORS
    nclusters = (total - data_start) // SPC

    items = []   # dict(name, data, attr, deleted)
    for spec in a.delete:
        path, name = split_spec(spec)
        items.append(dict(name=name, data=open(path, 'rb').read(), attr=0x20, deleted=True))
    for name in a.dir:
        items.append(dict(name=name, data=None, attr=0x10, deleted=False))
    for spec in a.files:
        path, name = split_spec(spec)
        items.append(dict(name=name, data=open(path, 'rb').read(), attr=0x20, deleted=False))

    # Cluster counts, then allocation (sequential, or round-robin N at a time).
    for it in items:
        n = 1 if it['data'] is None else (len(it['data']) + SECTOR - 1) // SECTOR
        it['need'], it['clusters'] = n, []
    nxt = 2
    if a.fragment:
        live = [it for it in items if it['need']]
        while any(len(it['clusters']) < it['need'] for it in live):
            for it in live:
                for _ in range(min(a.fragment, it['need'] - len(it['clusters']))):
                    it['clusters'].append(nxt)
                    nxt += 1
            if len(live) == 1 and len(live[0]['clusters']) < live[0]['need']:
                nxt += a.fragment
    else:
        for it in items:
            it['clusters'] = list(range(nxt, nxt + it['need']))
            nxt += it['need']
    used_top = max([c for it in items for c in it['clusters']], default=1)
    if used_top >= nclusters + 2:
        raise SystemExit(f"make_romfs: files need clusters up to {used_top}, "
                         f"the volume has {nclusters} (2..{nclusters + 1})")

    img = bytearray(size)
    img[0:SECTOR] = boot_sector(total, fs)
    fat = bytearray(fs * SECTOR)
    fat[0:3] = bytes([MEDIA, 0xFF, 0xFF])
    root = bytearray(ROOT_SECTORS * SECTOR)
    ents = [sfn_entry(b'SYCLBADGE  ', 0x08, 0, 0)]
    taken = set()
    for it in items:
        cl = it['clusters']
        for i, c in enumerate(cl):
            fat_set(fat, c, cl[i + 1] if i + 1 < len(cl) else EOC)
        off = (data_start + cl[0] - 2) * SECTOR
        if it['data'] is None:
            dot = sfn_entry(b'.          ', 0x10, cl[0], 0)
            dotdot = sfn_entry(b'..         ', 0x10, 0, 0)
            img[off:off + 64] = dot + dotdot
        else:
            for i, c in enumerate(cl):
                chunk = it['data'][i * SECTOR:(i + 1) * SECTOR]
                o = (data_start + c - 2) * SECTOR
                img[o:o + len(chunk)] = chunk
        n11, need_lfn = short_name(it['name'], taken)
        taken.add(n11)
        group = (lfn_entries(it['name'], sfn_checksum(n11)) if need_lfn or
                 it['name'] != it['name'].upper() else [])
        size_field = 0 if it['data'] is None else len(it['data'])
        group.append(sfn_entry(n11, it['attr'], cl[0] if cl else 0, size_field))
        if it['deleted']:
            for e in group:
                e[0] = 0xE5
            for c in cl:
                fat_set(fat, c, 0)
        it['entries'] = len(group)
        ents += group
    if len(ents) > ROOT_ENTRIES:
        raise SystemExit(f"make_romfs: {len(ents)} directory entries, the root holds {ROOT_ENTRIES}")
    for i, e in enumerate(ents):
        root[i * 32:(i + 1) * 32] = e
    for k in range(NUM_FATS):
        o = (RESERVED + k * fs) * SECTOR
        img[o:o + len(fat)] = fat
    o = (RESERVED + NUM_FATS * fs) * SECTOR
    img[o:o + len(root)] = root

    end = total
    if a.truncate:
        end = data_start + (used_top - 1 if used_top >= 2 else 0)
    with open(a.out, 'wb') as fh:
        fh.write(img[:end * SECTOR])

    used = sum(len(it['clusters']) for it in items if not it['deleted'])
    print(f"{a.out}: {total} sectors ({size // 1024} KB volume), FAT {fs} sectors x2, "
          f"data from sector {data_start}, {nclusters} clusters"
          + (f"; truncated to {end} sectors ({end * SECTOR} bytes)" if a.truncate else ''))
    for it in items:
        cl = it['clusters']
        contig = all(cl[i + 1] == cl[i] + 1 for i in range(len(cl) - 1))
        kind = 'dir' if it['data'] is None else f"{len(it['data'])} bytes"
        print(f"  {'deleted ' if it['deleted'] else ''}{it['name']}: {kind}, {len(cl)} clusters "
              f"{cl[0] if cl else '-'}..{cl[-1] if cl else '-'}, "
              f"{'contiguous' if contig else 'fragmented'}, {it['entries']} dir entries")
    print(f"  {used} clusters used, {nclusters - used} free ({(nclusters - used) * SECTOR // 1024} KB), "
          f"{len(ents)} of {ROOT_ENTRIES} root entries")


def lfn_chars(e):
    offs = [1 + 2 * i for i in range(5)] + [14 + 2 * i for i in range(6)] + [28, 30]
    return [struct.unpack_from('<H', e, o)[0] for o in offs]


def list_image(path):
    img = open(path, 'rb').read()
    if len(img) < SECTOR or struct.unpack_from('<H', img, 510)[0] != 0xAA55:
        raise SystemExit(f"make_romfs: {path}: no boot sector signature")
    bps, spc, res, nf, rootn, tot, fs = (struct.unpack_from('<H', img, 11)[0], img[13],
                                         struct.unpack_from('<H', img, 14)[0], img[16],
                                         struct.unpack_from('<H', img, 17)[0],
                                         struct.unpack_from('<H', img, 19)[0],
                                         struct.unpack_from('<H', img, 22)[0])
    root_start = res + nf * fs
    data_start = root_start + (rootn * 32 + bps - 1) // bps
    ncl = (tot - data_start) // max(spc, 1)
    print(f"{path}: {len(img)} bytes; {bps} B/sector, {spc} sector/cluster, {res} reserved, "
          f"{nf} FATs x {fs} sectors, {rootn} root entries, {tot} total sectors, "
          f"type '{img[54:62].decode(errors='replace')}', label '{img[43:54].decode(errors='replace')}'")
    print(f"  FAT at sector {res}, root at {root_start}, data at {data_start}, {ncl} clusters")
    fat = img[res * bps:(res + fs) * bps]
    lfn = []
    for i in range(rootn):
        e = img[root_start * bps + i * 32:root_start * bps + (i + 1) * 32]
        if len(e) < 32 or e[0] == 0:
            break
        attr = e[11]
        if attr == 0x0F:
            if e[0] == 0xE5:
                print(f"  [{i:2}] deleted LFN")
                lfn = []
                continue
            if e[0] & 0x40:
                lfn = []
            lfn.append(e)
            continue
        name = (e[0:8].decode('latin-1').rstrip() +
                ('.' + e[8:11].decode('latin-1').rstrip() if e[8:11].strip() else ''))
        long = None
        if lfn and all(x[13] == sfn_checksum(e[0:11]) for x in lfn):
            cs = []
            for x in reversed(lfn):
                cs += lfn_chars(x)
            cs = cs[:cs.index(0)] if 0 in cs else [c for c in cs if c != 0xFFFF]
            long = ''.join(chr(c) for c in cs)
        lfn = []
        cl0 = struct.unpack_from('<H', e, 26)[0]
        size = struct.unpack_from('<I', e, 28)[0]
        tag = ('deleted ' if e[0] == 0xE5 else '') + (
            'label' if attr & 0x08 else 'dir' if attr & 0x10 else 'file')
        line = f"  [{i:2}] {tag} {name!r}" + (f" long {long!r}" if long else '') + f" attr {attr:#04x}"
        if attr & 0x08:
            print(line)
            continue
        line += f" size {size} first cluster {cl0}"
        if e[0] != 0xE5 and not attr & 0x08 and cl0 >= 2:
            chain, c, seen = [], cl0, set()
            while 2 <= c < 0xFF0 and c not in seen and len(chain) <= ncl:
                seen.add(c)
                chain.append(c)
                if (c + c // 2 + 1) >= len(fat):
                    break
                c = fat_get(fat, c)
            runs = []
            for x in chain:
                if runs and runs[-1][1] + 1 == x:
                    runs[-1][1] = x
                else:
                    runs.append([x, x])
            need = (size + bps - 1) // bps
            ok = 'ok' if attr & 0x10 or len(chain) == need else f'BAD (want {need})'
            line += (f"; chain {len(chain)} clusters ({ok}), "
                     f"{'contiguous' if len(runs) == 1 else f'{len(runs)} runs'}: "
                     + ' '.join(f"{a}" if a == b else f"{a}-{b}" for a, b in runs)
                     + f", end {c:#05x}")
        print(line)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split('\n\n')[0],
                                 formatter_class=argparse.RawDescriptionHelpFormatter,
                                 epilog=__doc__.split('\n\n', 1)[1])
    ap.add_argument('out', nargs='?', help='image to write')
    ap.add_argument('files', nargs='*', help='files to add (PATH or PATH=NAME)')
    ap.add_argument('--size', default='1280K')
    ap.add_argument('--truncate', action='store_true')
    ap.add_argument('--fragment', type=int, default=0, metavar='N')
    ap.add_argument('--delete', action='append', default=[], metavar='FILE')
    ap.add_argument('--dir', action='append', default=[], metavar='NAME')
    ap.add_argument('--list', metavar='IMG')
    a = ap.parse_intermixed_args(argv)
    if a.list:
        list_image(a.list)
        return 0
    if not a.out:
        ap.error('OUT.img is required (or --list IMG)')
    if a.fragment < 0:
        ap.error('--fragment must be positive')
    build(a)
    return 0


if __name__ == '__main__':
    sys.exit(main())
