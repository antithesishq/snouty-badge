# snouty-genesis drive fixtures

FAT12 images of the badge drive for `tests/drive_unit.zig` (PLAN.md M2
Track B), written by the shared `tools/make_romfs.py` in the OS geometry and
truncated at the last used sector. Regenerate from this directory (the
output is byte-for-byte reproducible; it also prints `make_romfs.py --list`
of the main image):

```
python3 make_fixtures.py
```

`make_fixtures.py` builds three source blobs in a temporary directory from
`roms/snouty-test.bin` (16 KB, zlib.crc32 `e5d1c6bf`):

- `nohdr.bin`: `bytes(i & 0xFF for i in range(16384))`, no "SEGA" header.
- `bad.bin`: the SMD-interleaved test ROM, 16,896 bytes:
  ```python
  hdr = bytearray(512)
  hdr[0] = len(raw) // 0x4000          # 16 KB blocks
  hdr[1] = 3
  hdr[8], hdr[9], hdr[10] = 0xAA, 0xBB, 0x06
  out = bytearray(hdr)
  for b in range(0, len(raw), 0x4000):
      block = raw[b:b + 0x4000]
      out += block[1::2] + block[0::2]  # odd bytes, then even bytes
  ```
- `readme.txt`: one line of text (46 bytes).

and then runs, with `ROM=../../../../carts/snouty-genesis/roms/snouty-test.bin`
spelled out as an absolute path:

```
python3 ../../../../tools/make_romfs.py m2_drive.img --truncate \
    --delete=readme.txt=OLD.GEN --dir .fseventsd \
    $ROM=TEST.GEN $ROM=FRAG.MD nohdr.bin=NOHDR.BIN bad.bin=BAD.BIN \
    readme.txt=README.TXT
python3 ../../../../tools/make_romfs.py m2_none.img --truncate \
    readme.txt=README.TXT nohdr.bin=JUNK.BIN
```

followed by one post-processing step on `m2_drive.img`: `FRAG.MD` is
stored back to front (file cluster k moves to the file's (31-k)th cluster,
the FAT chain in both FATs and the directory entry's first cluster are
rewritten to match), so its 32 clusters are 32 runs. `make_romfs.py
--fragment N` cannot do this: it hands out clusters round-robin over every
file, and a 16 KB `TEST.GEN` stays contiguous only when N >= 32, which
leaves the equally sized `FRAG.MD` contiguous too.

- `m2_drive.img` (77,312 bytes): label, a deleted `OLD.GEN` (cluster 2),
  `.fseventsd` (LFN over `FSEVEN~1`, cluster 3), `TEST.GEN` (clusters
  4..35, contiguous), `FRAG.MD` (67 down to 36), `NOHDR.BIN` (68..99),
  `BAD.BIN` (100..132), `README.TXT` (133). The scan lists the four
  `.gen`/`.md`/`.bin` files with verdicts ok, ok, no_header,
  smd_interleaved.
- `m2_none.img` (26,624 bytes): `README.TXT` and `JUNK.BIN` (the `nohdr`
  pattern): a volume with no playable ROM, the help screen's case.
