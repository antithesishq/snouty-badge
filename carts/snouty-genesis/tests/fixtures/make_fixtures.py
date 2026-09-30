#!/usr/bin/env python3
"""Regenerate the drive fixtures of tests/drive_unit.zig (see README.md).

Run from this directory: `python3 make_fixtures.py`. Writes m2_drive.img and
m2_none.img; the source blobs it needs go to a temporary directory. Output
is byte-for-byte reproducible (make_romfs.py fixes the timestamps).
Python 3 standard library only.
"""
import os
import struct
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, '../../../..'))
MAKE_ROMFS = os.path.join(ROOT, 'tools/make_romfs.py')
TEST_ROM = os.path.join(ROOT, 'carts/snouty-genesis/roms/snouty-test.bin')


def smd(raw):
    """SMD copy: 512-byte copier header (byte 0 block count, 8-9 AA BB), then
    each 16 KB block as its odd bytes followed by its even bytes."""
    assert len(raw) % 0x4000 == 0
    hdr = bytearray(512)
    hdr[0] = len(raw) // 0x4000
    hdr[1] = 3
    hdr[8], hdr[9], hdr[10] = 0xAA, 0xBB, 0x06
    out = bytearray(hdr)
    for b in range(0, len(raw), 0x4000):
        block = raw[b:b + 0x4000]
        out += block[1::2] + block[0::2]
    return bytes(out)


def reverse_chain(img_path, name11):
    """Store the file `name11` (8.3, 11 bytes) back to front: file cluster k
    moves to the file's (n-1-k)th physical cluster and the FAT chain is
    rewritten to match, so every cluster is its own run. make_romfs.py's
    --fragment is round-robin over all files and cannot leave one 16 KB file
    contiguous while fragmenting another of the same size."""
    img = bytearray(open(img_path, 'rb').read())
    sector = struct.unpack_from('<H', img, 11)[0]
    reserved = struct.unpack_from('<H', img, 14)[0]
    nfats = img[16]
    root_entries = struct.unpack_from('<H', img, 17)[0]
    fs = struct.unpack_from('<H', img, 22)[0]
    root = (reserved + nfats * fs) * sector
    data = root + root_entries * 32
    for i in range(root_entries):
        e = root + 32 * i
        if img[e:e + 11] == name11:
            break
    else:
        raise SystemExit(f'{name11!r} not in the root directory')
    first = struct.unpack_from('<H', img, e + 26)[0]
    size = struct.unpack_from('<I', img, e + 28)[0]
    n = (size + sector - 1) // sector
    phys = list(range(first, first + n))  # make_romfs.py wrote it contiguous
    pieces = [bytes(img[data + (c - 2) * sector:][:sector]) for c in phys]
    new = phys[::-1]  # file cluster k at new[k]
    for k, c in enumerate(new):
        img[data + (c - 2) * sector:data + (c - 1) * sector] = pieces[k]
    for f in range(nfats):
        fat = (reserved + f * fs) * sector
        for k, c in enumerate(new):
            nxt = new[k + 1] if k + 1 < n else 0xFFF
            off = fat + c + c // 2
            if c & 1:
                img[off] = (img[off] & 0x0F) | ((nxt << 4) & 0xF0)
                img[off + 1] = (nxt >> 4) & 0xFF
            else:
                img[off] = nxt & 0xFF
                img[off + 1] = (img[off + 1] & 0xF0) | (nxt >> 8)
    struct.pack_into('<H', img, e + 26, new[0])
    open(img_path, 'wb').write(img)


def run(*args):
    subprocess.run([sys.executable, MAKE_ROMFS, *args], check=True)


def main():
    raw = open(TEST_ROM, 'rb').read()
    with tempfile.TemporaryDirectory() as tmp:
        nohdr = os.path.join(tmp, 'nohdr.bin')
        bad = os.path.join(tmp, 'bad.bin')
        readme = os.path.join(tmp, 'readme.txt')
        open(nohdr, 'wb').write(bytes(i & 0xFF for i in range(16384)))
        open(bad, 'wb').write(smd(raw))
        open(readme, 'wb').write(b'Genesis ROMs go in the root: .gen, .md, .bin\r\n')
        drive = os.path.join(HERE, 'm2_drive.img')
        run(drive, '--truncate', f'--delete={readme}=OLD.GEN', '--dir', '.fseventsd',
            f'{TEST_ROM}=TEST.GEN', f'{TEST_ROM}=FRAG.MD', f'{nohdr}=NOHDR.BIN',
            f'{bad}=BAD.BIN', f'{readme}=README.TXT')
        reverse_chain(drive, b'FRAG    MD ')
        run(os.path.join(HERE, 'm2_none.img'), '--truncate',
            f'{readme}=README.TXT', f'{nohdr}=JUNK.BIN')
    subprocess.run([sys.executable, MAKE_ROMFS, '--list', os.path.join(HERE, 'm2_drive.img')], check=True)


if __name__ == '__main__':
    main()
