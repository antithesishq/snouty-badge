# Running Snouty Genesis

Build the cart, run the host tests, preview it headless or in the web
simulator, benchmark it, put a ROM on the badge drive and flash the cart.
Commands run from the repository root; outputs land in the root `zig-out/`.

Status: M1 in progress (tracks merging). The frame loop of PLAN.md runs:
262 lines per frame, the 68000 per line, the Z80 slice when released,
V-int and H-int from the VDP, the pad with its TH protocol, the one tone
voice (`Md.tone()` -> `tone2`). Until the 68000 (Track A) and VDP (Track
B) land, the picture is the backdrop colour only; once merged, the test
ROM shows its grid, stripes, colour ramp, frame counter and a sprite the
d-pad moves (`tools/testrom/README.md`). A Select hold pauses under a
"MENU (M2)" banner; badge B resumes. No splash, real menu or rewind (M2,
M3).

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
  by the build, since the shell leaves `=~` alone). The report line reads
  `ROM: embedded snouty-test.bin 16 KB`. Keep an embedded badge ROM small: every KB of
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

- `smoke:` `Md` and `Keyframe` under 156 KB and 155 KB (SPEC.md section
  13's 140/139 KB plus the 16 KB SRAM row); the console built on the
  embedded ROM (reset vectors fetched), one unrendered and one rendered
  frame (128 rows through `line_sink`); the
  embedded ROM's header ("SEGA" at 0x100, the test ROM's exact fields);
  a Z80 program in Z80 RAM run through `Z80Bus` by Gear's core.
- `md:` keyframe snapshot/restore round trip; the line table (128 rows,
  lines 0..222); a frame's 68000 budget and the DMA stall carry.
- `rom:` a contiguous and a clustered `RomSource` over the same bytes read
  identically; the load-time refusals (no header, SMD with and without the
  copier header, SSF mapper, over 4 MB, SVP).
- `bus:` the 68000 map on synthetic ROMs: work RAM mirrors and big-endian
  words, ROM open bus past the end, reset vectors, version register `A0`,
  the pad's TH protocol for every button, BUSREQ/RESET and open bus on the
  Z80 side, the Z80 running only when released, VDP port mirrors and PSG
  writes, SRAM (declared, EEPROM, oversized, A130F1), IRQ level/ack,
  `dma_read16`.
- `golden:` the scripted run of `roms/snouty-test.bin` (below),
  two runs from reset compared (determinism), snapshot/restore mid-run.

### Golden hashes

`tests/golden.zig` runs `roms/snouty-test.bin` for 300 Genesis frames (150
badge updates) under `tools/scripts/m1_play.json`, the same script
preview and badge-bench use (ticks are badge updates, two Genesis frames
each; badge A = Genesis C, B = B, a SELECT hold shorter than 15 updates =
Genesis A for the 2 updates after it). It renders every second frame as
the badge does and hashes each rendered frame's 128 rows (tagged indices
plus the CRAM each row carried), and hashes the list of `tone()` changes.
While `golden_hashes` is empty and `golden_tone_hash` is 0 the test only
prints them:

```sh
zig build test-genesis -Dcart=snouty-genesis -Dcart-mode=xip -Dtest-filter=golden 2>&1 | grep -A12 "golden:"
```

Procedure (integration): look at the preview frames at the same updates
(section 4, `--script` the same file), listen once in the simulator, then
copy the printed hashes into `golden_hashes` / `golden_tone_hash`. From
then on any change to a checkpoint frame or to the tone sequence fails the
test; re-record only after re-checking by eye and ear.

## 4. Headless preview

```sh
node tools/preview.mjs zig-out/bin/snouty-genesis.wasm --frames 150 --every 10 \
  --out carts/snouty-genesis/out/m1/ \
  --script carts/snouty-genesis/tools/scripts/m1_play.json \
  --dump-exports debug_frame_count,debug_lines,debug_pc,debug_z80_state,debug_tone_hz \
  --expect "debug_lines == 128"
```

`out/m1/frame_XXXX.png` are 160x128 frames, one per 10 updates (20 Genesis
frames). The script (`tools/scripts/m1_play.json`, ticks = updates): idle
to 29 (boot), Right 30-59, Down+B 60-74, Start 80-81 (sprite back to the
centre), badge A = Genesis C 90-94, a Select tap 100-101 (Genesis A for 4
frames: the PSG tone mutes), Up+Left 105-119.

The top-left overlay: line 1 update time (both Genesis frames), line 2
presents per second and emulated frames per second (always 1000 us / 500
/ 1000 in wasm, where the clock is a stub), line 3 `z80:on r2 z100 c100`:
the Z80 (`on`, `req` held by BUSREQ, `rst` in reset, `off` switched off)
and the tunables (`render_every`, `z80_scale` and `cpu_scale` in percent).
The bottom lines are the ROM report. Exports: `debug_frame_count`
(Genesis frames, two per update), `debug_step_us`, `debug_lines` (rows
rendered last frame, 128), `debug_state` (1 running, 2 menu
placeholder), `debug_pad` (`core.Pad` bits: up 1, down 2, left 4, right
8, A 16, B 32, C 64, Start 128), `debug_rom_source` (0 none, 1 embedded,
2 drive contiguous, 3 drive fragmented), `debug_rom_size`,
`debug_rom_crc` (drive only), `debug_cram_rebuilds`,
`debug_menu_requests`, `debug_tone_calls`, `debug_tone_hz` (0 silent),
`debug_sound_on` (1 when sound is on: 0 at boot unless built with
`-Dsound=true`, badge A in the menu toggles it; root docs/SOUND.md),
`debug_pc`, `debug_sp`, `debug_sr` (68000), `debug_vdp_line`,
`debug_z80_pc`, `debug_z80_state` (bit 0 BUSREQ, bit 1 reset, bit 2 off).

Miniplanets (Sik's homebrew, 512 KB, zlib licence, `roms/miniplanets.bin`)
in the simulator or preview: build with it embedded. It is too big for
the badge's flash window, so this is a simulator/preview build only (the
badge reads it from the drive, section 7):

```sh
zig build -Dcart=snouty-genesis -Dcart-mode=xip -Dmd-rom=carts/snouty-genesis/roms/miniplanets.bin
node tools/preview.mjs zig-out/bin/snouty-genesis.wasm --frames 600 --every 60 \
  --out carts/snouty-genesis/out/miniplanets/ --press START:200-203
```

The firmware link of that build fails (`section '.text' will not fit in
region 'FLASH'`: the 512 KB ROM cannot be embedded in the 256 KB XIP
window) and `zig build` exits non-zero, but the wasm is still installed to
`zig-out/bin/snouty-genesis.wasm`, which is all the simulator and preview
need (check the report line or `debug_rom_size` = 524288). Rebuild without
`-Dmd-rom` to go back to the test ROM.

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
`--config`. It runs 120 updates (240 Genesis frames) of the embedded test
ROM under `tools/scripts/m1_play.json` against the 33.3 ms budget; M1's
target is a mean under 31 ms and a worst update under 33 ms (calibrated,
the `busy ms` column). The romfs image is required: the default build
reads the drive, and without an image the run faults reading the boot
sector (a bench artefact); the image above is an empty volume, so the cart
falls back to the embedded ROM. To bench the drive path, put a ROM on the
image, e.g.
`python3 tools/make_romfs.py carts/snouty-genesis/out/romfs.img carts/snouty-genesis/roms/snouty-test.bin=TEST.GEN`
(add `--fragment 4` with two files to get a fragmented one), or pass
`--romfs IMAGE`. The Z80's share: rebuild with `tunables.z80_scale = 0`
(or `z80_enabled = false`) and compare.

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
   "SEGA" are skipped; SMD-interleaved files, SSF2-mapper or over-4 MB
   ROMs and SVP (Virtua Racing) are refused and the report names the
   reason (e.g. `drive: SMD interleaved: convert to .bin`). With no volume
   or no ROM file it reads
   `ROM: embedded snouty-test.bin 16 KB, drive: no .gen/.md/.bin file` (or
   the romfs error name).

## 8. Flash the badge

Copy `zig-out/firmware/snouty-genesis-xip.uf2` onto the badge drive. XIP
carts are not yet confirmed on hardware (an open item, not a gate: no
badge until the show). On the badge the overlay's `avg`/`max`
are real update microseconds.
