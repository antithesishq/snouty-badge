#!/usr/bin/env python3
"""Regenerate the drive fixtures of tests/drive_unit.zig (and the default
badge-bench image, badge-bench/carts/snouty-lynx.toml). No commercial ROMs.

Run from anywhere: `python3 carts/snouty-lynx/tests/fixtures/make_fixtures.py`.
Writes, byte-for-byte reproducibly (make_romfs.py fixes timestamps):

- m0_drive.img, root in this order: ROT.LNX (the placeholder with its
  rotation byte set: refused), GAME.LNX (roms/placeholder.lnx, 576 B,
  contiguous), RAW.LYX (4 KB headerless byte pattern), FRAG.LNX (the
  placeholder's header + 2 KB of the same pattern: four 512 B blocks, each
  straddling two clusters), README.TXT. --fragment 2 splits RAW.LYX and
  FRAG.LNX into runs of two clusters: RAW.LYX's blocks are whole clusters
  (all direct), FRAG.LNX's blocks 1 and 3 cross a run boundary (null
  pointers, read through the cluster table).
- m0_none.img: ROT.LNX and README.TXT only (no playable ROM: the help).

Python 3 standard library only.
"""
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, '../../../..'))
MAKE_ROMFS = os.path.join(ROOT, 'tools/make_romfs.py')
PLACEHOLDER = os.path.join(ROOT, 'carts/snouty-lynx/roms/placeholder.lnx')


def raw_pattern():
    """4 KB: byte i is (i * 7 + i // 512) & 0xFF (tests/drive_unit.zig)."""
    return bytes((i * 7 + i // 512) & 0xFF for i in range(4096))


def run(*args):
    subprocess.run([sys.executable, MAKE_ROMFS, *args], check=True)


def main():
    placeholder = open(PLACEHOLDER, 'rb').read()
    rotated = bytearray(placeholder)
    rotated[58] = 1
    with tempfile.TemporaryDirectory() as tmp:
        def blob(name, data):
            p = os.path.join(tmp, name)
            open(p, 'wb').write(data)
            return p
        rot = blob('rot.lnx', bytes(rotated))
        raw = blob('raw.lyx', raw_pattern())
        frag = blob('frag.lnx', placeholder[:64] + raw_pattern()[:2048])
        readme = blob('readme.txt', b'Snouty Lynx drive fixture.\n')
        run(os.path.join(HERE, 'm0_drive.img'), f'{rot}=ROT.LNX', f'{PLACEHOLDER}=GAME.LNX',
            f'{raw}=RAW.LYX', f'{frag}=FRAG.LNX', f'{readme}=README.TXT', '--fragment', '2', '--truncate')
        run(os.path.join(HERE, 'm0_none.img'), f'{rot}=ROT.LNX', f'{readme}=README.TXT', '--truncate')


if __name__ == '__main__':
    main()
