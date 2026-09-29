# Running Snouty Gear

Build the cart, run the host tests, preview it headless or in the web
simulator, put a ROM on the badge drive and flash the cart. Commands run
from the repository root unless noted; outputs land in the root `zig-out/`.

Status: M0. The core draws a test pattern (colour bars from the 32 CRAM
entries, white diagonal stripes, a 16x16 box moved by the d-pad; button 1
inverts the palette, button 2 rotates it, Start speeds up the scroll). The
Game Gear itself is emulated from M1.

## 1. Prerequisites

Zig, Node.js, Python 3 and git as in `docs/RUNNING.md` at the repository
root. `tools/fetch_test_roms.sh` needs curl, unzip and git;
`tools/romcheck.py` needs only Python 3.

## 2. Build

```sh
zig build -Dcart=snouty-gear
```

- `zig-out/firmware/snouty-gear.uf2`: the badge cart (RAM cart)
- `zig-out/firmware/snouty-gear.elf`: same program, for `size -A`
- `zig-out/bin/snouty-gear.wasm`: simulator and `tools/preview.mjs`

Options:

- `-Dgg-rom=PATH`: the ROM to embed (default
  `carts/snouty-gear/roms/waternet.gg`). Repository-relative, cart-relative
  (`-Dgg-rom=roms/x.gg`), absolute, or `~/x.gg` (expanded by the build,
  since the shell leaves `=~` alone). Keep an embedded ROM at 128 KB or
  less (SPEC.md section 11); to try Sonic in the simulator:
  `zig build -Dcart=snouty-gear -Dgg-rom=~/sonic.gg` (local only, never
  commit it; the root `.gitignore` ignores `*.gg`/`*.sms`). The wasm
  builds; the badge ELF then fails to link (`.bss` overflows cart RAM by
  about 23 KB with 256 KB embedded), which is expected: on the badge Sonic
  comes from the drive (section 6).
- `-Dgg-rom-source=drive|embed|pack`: `drive` (default) reads the ROM from
  the badge drive and uses the embedded ROM if there is none; `embed` uses
  only the embedded ROM; `pack` (SPEC.md 13.1) is not built yet, prints a
  note and builds the `drive` cart. The wasm build always embeds.
- `-Dcart-optimize=fast|small|safe|debug` (default `fast`).

`python3 carts/snouty-gear/tools/romcheck.py ROM.gg` prints the header
(product, region, size code), mapper and cart RAM heuristics, VDP and sound
port use, and whether the ROM meets SPEC.md section 11, for the drive and
for embedding.

## 3. Host tests

```sh
carts/snouty-gear/tools/fetch_test_roms.sh     # ZEXDOC/ZEXALL into tests/roms/ (M1 uses them)
carts/snouty-gear/tools/fetch_test_roms.sh --single-step   # plus SingleStepTests Z80, ~1.2 GB
zig build test                                 # every cart's host tests
zig build test -Dtest-filter=pattern           # only names containing "pattern"
```

M0 tests: the pattern reaches the line sink (144 lines per frame, in order,
hash changing every frame and with the pad, snapshot/restore replays the
same frame), the ROM bank table (`from_slice` on 64 KB gives 4 banks at the
right offsets, 48 KB gives 3, partial banks and the fallback reader), and
the subsystem stubs' public shapes.

## 4. Headless preview

```sh
node tools/preview.mjs zig-out/bin/snouty-gear.wasm --frames 120 --every 10 \
  --script carts/snouty-gear/tools/scripts/m0_pattern.json --out carts/snouty-gear/out/ \
  --dump-exports debug_frame_count,debug_lines,debug_rom_source,debug_rom_size,debug_rom_banks \
  --expect "debug_lines == 144"
```

`out/frame_XXXX.png` are 160x128 frames. The top-left overlay shows the
`step_frame` time and FPS (always 1000 us / 500 fps in wasm, where the
clock is a stub); the bottom line is the ROM report. Exports:
`debug_frame_count`, `debug_step_us`, `debug_lines` (144), `debug_state`
(1 running), `debug_pad` (`core.Pad` bits: up 1, down 2, left 4, right 8,
button 1 16, button 2 32, Start 64), `debug_rom_source` (0 embedded,
1 drive), `debug_rom_size`, `debug_rom_banks`, `debug_rom_crc` (drive only),
`debug_cram_rebuilds`, `debug_menu_requests` (Select holds; the menu is M2).

## 5. Web simulator

As Snouty Boy (`carts/snouty-boy/docs/RUNNING.md` section 6):
`node tools/serve-cart.mjs zig-out/bin/snouty-gear.wasm` in one terminal,
`npm run dev` in `sycl-badge/simulator` in another, then
<http://localhost:1234>. Keys: arrows/WASD d-pad, X or J = badge B =
button 1, Z or K = badge A = button 2, Enter = Start, Backspace = Select.

## 6. A ROM on the badge drive

The badge's USB drive (`SYCLBADGE`, the OS romfs region) holds carts and
any other file. With the default `drive` build:

1. Plug in the badge, switch it on; the drive mounts.
2. Copy `snouty-gear.uf2` onto it (replacing `CURRENT.UF2` as for any
   cart), and copy one `.gg` file (or `.sms`) next to it. Best on a freshly
   wiped drive, so the file is contiguous; a fragmented file still works
   through the per-cluster path and the report line says `frag`.
3. **Eject the drive before playing.** The OS writes flash while a host
   writes the drive, and a cart reading it at the same time could see torn
   data (docs/ROM_DRIVE.md section 2).
4. Start Snouty Gear. The bottom line reads
   `ROM: drive NAME 256 KB crc 1A2B3C4D` (plus `(1 of N)` when several
   ROM files are on the drive: the first one in the directory wins). If
   there is no volume or no ROM file it reads
   `ROM: embedded waternet.gg 64 KB, drive: NoVolume` (or
   `drive: no .gg/.sms file`, or the romfs error name).

The ROM file also shows in the OS cart menu and fails to load if picked
there; that is cosmetic. Until the real `lib/romfs.zig` reader lands (M0
Track B) the drive path always reports `NoVolume`.

## 7. Flash the badge

As Snouty Boy (`carts/snouty-boy/docs/RUNNING.md` section 8): copy
`zig-out/firmware/snouty-gear.uf2` onto the badge drive. On the badge the
overlay's `avg`/`max` are real `step_frame` microseconds.
