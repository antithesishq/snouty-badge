# romfs test fixtures

FAT12 images of the badge drive written by `tools/make_romfs.py` in the OS
geometry and truncated at the last used sector, plus the pseudo-random
source files stored in them. Used by `lib/tests/romfs_unit.zig`. Regenerate
from this directory (the output is byte-for-byte reproducible):

```
python3 -c "
import random
for name, n, seed in (('src_a.bin', 1500, 1), ('src_b.bin', 1100, 2), ('src_c.bin', 300, 3)):
    open(name, 'wb').write(random.Random(seed).randbytes(n))
"
python3 ../../../tools/make_romfs.py waternet.img \
    ../../../carts/snouty-gear/roms/waternet.gg --truncate
python3 ../../../tools/make_romfs.py drive.img --truncate --fragment 1 \
    --delete "src_c.bin=Old Game.gg" --dir .fseventsd --dir Games.gg \
    "src_a.bin=Sonic The Hedgehog (World).gg" \
    "src_c.bin=._Sonic The Hedgehog (World).gg" src_c.bin=TETRIS.GG \
    src_c.bin=readme.txt "src_b.bin=Second Game.SMS" \
    "src_c.bin=An extremely long file name that runs past the sixty-four byte limit.gg"
python3 ../../../tools/make_romfs.py --list drive.img
```

- `waternet.img` (73.5 KB): the shipped ROM alone, clusters 2..129, contiguous.
- `drive.img` (16 KB): a deleted file, two directories (one named `*.gg`), a
  long-named file and its macOS `._` AppleDouble sibling, an 8.3-only name,
  a lower-case name (LFN over `README.TXT`), a `.SMS` file and a 71-character
  name; `--fragment 1` interleaves the clusters, so the two 3-cluster files
  are in 3 runs each.
