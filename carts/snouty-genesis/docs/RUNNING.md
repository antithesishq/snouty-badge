# Running Snouty Genesis

Build the cart, run the host tests, preview it headless or in the web
simulator, benchmark it, put a ROM on the badge drive and flash the cart.
Commands run from the repository root; outputs land in the root `zig-out/`.

Status: M0 scaffold. The core holds the whole console state but emulates
nothing yet: each rendered frame is a test pattern (four bands of color
bars, a shadow and a highlight band, a white block moving 2 px per Genesis
frame; `docs/m0_pattern.png`). No sound, menu or rewind (M1-M3).

## 1. Prerequisites

Zig, Node.js and Python 3 as in `docs/RUNNING.md` at the repository root.

## 2. Build

This is an XIP cart only (SPEC.md section 13):

```sh
zig build -Dcart=snouty-genesis -Dcart-mode=xip
```

- `zig-out/firmware/snouty-genesis-xip.uf2`: the badge cart
- `zig-out/firmware/snouty-genesis-xip.elf`: same program, for `size -A`
  and badge-bench
- `zig-out/bin/snouty-genesis.wasm`: simulator and `tools/preview.mjs`

`zig build -Dcart=snouty-genesis` (RAM mode, the default) stops at
configure time and says to pass `-Dcart-mode=xip`. A plain `zig build`
(all carts) builds this one as XIP whatever `-Dcart-mode` says.

Options:

- `-Dmd-rom=PATH`: the ROM to embed (default
  `carts/snouty-genesis/roms/snouty-test.bin`). Repository-relative,
  cart-relative (`-Dmd-rom=roms/x.bin`), absolute, or `~/x.bin` (expanded
  by the build, since the shell leaves `=~` alone). While the default file
  does not exist and no `-Dmd-rom` is given, the build embeds a generated
  512-byte placeholder (a valid header, "SNOUTY PLACEHOLDER", and a
  `BRA.S *` loop); the report line then reads `ROM: embedded
  placeholder.bin 1 KB`. Keep an embedded badge ROM small: every KB of
  cart image costs 2 KB of drive space (SPEC.md section 13). Commercial
  ROMs stay local (`*.gen`, `*.smd` and this cart's `roms/*.bin`,
  `roms/*.md` are gitignored).
- `-Dmd-rom-source=drive|embed`: `drive` (default) reads the ROM from the
  badge drive and uses the embedded ROM if there is none; `embed` uses only
  the embedded ROM. The wasm build always embeds.
- `-Dcart-optimize=fast|small|safe|debug` (default `fast`).

Sizes: `size -A zig-out/firmware/snouty-genesis-xip.elf` (`.text` is the
flash image, `.data` + `.bss` the RAM) against SPEC.md section 13.

## 3. Host tests

```sh
zig build test-genesis -Dcart=snouty-genesis -Dcart-mode=xip   # this cart only
zig build test                                                 # every cart's host tests
zig build test-genesis -Dcart=snouty-genesis -Dcart-mode=xip -Dtest-filter=smoke
```

The size test prints `@sizeOf(Md)` and `@sizeOf(Keyframe)` (Zig shows a
passing test's stderr with its command line; that is not a failure).

- `smoke:` `Md` and `Keyframe` under 140 KB and 139 KB (SPEC.md section
  13); the console built on the embedded ROM (reset vectors fetched), one
  unrendered and one rendered frame (128 rows through `line_sink`); the
  embedded ROM's header ("SEGA" at 0x100, the placeholder's exact fields);
  a Z80 program in Z80 RAM run through `Z80Bus` by Gear's core.
- `md:` keyframe snapshot/restore round trip.
- `rom:` a contiguous and a clustered `RomSource` over the same bytes read
  identically.

## 4. Headless preview

```sh
node tools/preview.mjs zig-out/bin/snouty-genesis.wasm --frames 60 --every 30 \
  --out carts/snouty-genesis/out/ \
  --dump-exports debug_frame_count,debug_lines,debug_rom_source,debug_rom_size,debug_pc \
  --expect "debug_lines == 128"
```

`out/frame_XXXX.png` are 160x128 frames. The top-left overlay shows the
update time (both Genesis frames) and presents per second plus emulated
frames per second (always 1000 us / 500 / 1000 in wasm, where the clock is
a stub); the bottom lines are the ROM report. Exports: `debug_frame_count`
(Genesis frames, two per update), `debug_step_us`, `debug_lines` (rows
rendered last frame, 128), `debug_state` (1 running), `debug_pad`
(`core.Pad` bits: up 1, down 2, left 4, right 8, A 16, B 32, C 64, Start
128), `debug_rom_source` (0 none, 1 embedded, 2 drive contiguous, 3 drive
fragmented), `debug_rom_size`, `debug_rom_crc` (drive only),
`debug_cram_rebuilds`, `debug_menu_requests`, `debug_tone_calls`,
`debug_pc`, `debug_sp`, `debug_sr` (68000), `debug_vdp_line`,
`debug_z80_pc`.

## 5. Web simulator

As Snouty Gear (`carts/snouty-gear/docs/RUNNING.md` section 5):
`node tools/serve-cart.mjs zig-out/bin/snouty-genesis.wasm` in one
terminal, `npm run dev` in `sycl-badge/simulator` in another, then
<http://localhost:1234>. Keys: arrows/WASD d-pad, X or J = badge B =
Genesis B, Z or K = badge A = Genesis C, Enter = Start, Backspace = Select
(tap: Genesis A).

## 6. Benchmark

```sh
zig build -Dcart=snouty-genesis -Dcart-mode=xip
python3 tools/make_romfs.py carts/snouty-genesis/out/romfs.img
badge-bench/bench.sh zig-out/firmware/snouty-genesis-xip.elf \
  --config badge-bench/carts/snouty-genesis.toml --symbols
```

The toml is not picked up by name (the ELF's basename has `-xip`), hence
`--config`. It runs 120 updates without input against a 33.3 ms budget.
The default build reads the drive, so the bench needs a drive image
(without one it faults reading the boot sector, a bench artefact); the
image above is an empty volume, so the cart falls back to the embedded ROM.
To bench the drive path, put a ROM on the image, e.g.
`python3 tools/make_romfs.py carts/snouty-genesis/out/romfs.img carts/snouty-genesis/roms/snouty-test.bin=TEST.GEN`
(add `--fragment 4` with two files to get a fragmented one), or pass
`--romfs IMAGE`.

## 7. A ROM on the badge drive

The badge's USB drive (`SYCLBADGE`, the OS romfs region) holds carts and
any other file. With the default `drive` build:

1. Plug in the badge, switch it on; the drive mounts.
2. Copy `snouty-genesis-xip.uf2` onto it, and one `.gen` (or `.md`, `.bin`)
   Genesis ROM next to it. Best on a freshly wiped drive, so the file is
   contiguous; a fragmented one runs through the cluster table and the
   report says so.
3. **Eject the drive before playing** (docs/ROM_DRIVE.md section 2).
4. Start Snouty Genesis. The bottom lines read
   `ROM: drive contiguous NAME 512 KB crc 1A2B3C4D` (or `fragmented`; plus
   `(1 of N)` when several Genesis files are on the drive: the first in the
   directory wins until M2's picker). Files whose word at 0x100 is not
   "SEGA" are skipped. With no volume or no ROM file it reads
   `ROM: embedded placeholder.bin 1 KB, drive: no .gen/.md/.bin file` (or
   the romfs error name).

## 8. Flash the badge

Copy `zig-out/firmware/snouty-genesis-xip.uf2` onto the badge drive. XIP
carts are not yet confirmed on hardware: the M0 gate is that this cart
launches and shows the test pattern. On the badge the overlay's `avg`/`max`
are real update microseconds.
