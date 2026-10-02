# Running Snouty Genesis

Build the cart, run the host tests, preview it headless or in the web
simulator, benchmark it, put a ROM on the badge drive and flash the cart.
Commands run from the repository root; outputs land in the root `zig-out/`.

Status: M4. Boot: a 1.2 s splash (the Iris mark and "SNOUTY GENESIS";
any button skips it), then the game, or on the badge the ROM picker when
the drive holds several Genesis ROMs and a help screen when it holds none.
Holding Select for 500 ms opens the emulator menu (section 5). Sound is off
at boot unless built with `-Dsound=true` (root docs/SOUND.md); the menu's
Sound row turns it on. In the menu Left/Right scrub time back and forward
in half-second steps (section 5). H40 games show every column pair
averaged (the menu's `Smooth H40` row, on by default); a fragmented drive
ROM runs at the speed of a contiguous one, and its CRC32 is computed in
the background over the first two seconds of play (section 7).

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
zig build test-m68k-strict -Dcart=snouty-genesis -Dcart-mode=xip   # 68000 oracle only; fails if fixtures are absent
```

Without `tests/roms/68000/*.json.gz` (`tools/fetch_test_roms.sh`) the
default run reports the SingleStepTests as skipped, not passed;
`test-m68k-strict` fails instead and prints the case counts.

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
- `drive:` the drive scan (`cart/src/frontend/drive.zig`, a module with no
  cart-api import) over `tests/fixtures/m2_drive.img`: four `.gen/.md/.bin`
  files listed in order with verdicts ok / ok / no header / SMD, the test
  ROM's header name, a contiguous and a fragmented copy both reading back
  byte-identical to `roms/snouty-test.bin` (CRC `E5D1C6BF`), an image with
  no ROM, a broken boot sector. `tests/fixtures/make_fixtures.py`
  regenerates the images (README.md there).

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
node tools/preview.mjs zig-out/bin/snouty-genesis.wasm --frames 186 --every 10 \
  --out carts/snouty-genesis/out/m2/ \
  --script carts/snouty-genesis/tools/scripts/m2_play.json \
  --dump-exports debug_frame_count,debug_lines,debug_state,debug_settings \
  --expect "debug_state == 1"
```

`out/m2/frame_XXXX.png` are 160x128 frames, one per 10 updates (20 Genesis
frames). Updates 0-35 are the splash; the game starts at update 36.
`tools/scripts/m2_play.json` is M1's script (ticks = updates) shifted by
those 36: idle to 65 (boot), Right 66-95, Down+B 96-110, Start 116-117
(sprite back to the centre), badge A = Genesis C 126-130, a Select tap
136-137 (Genesis A for 4 frames: the PSG tone mutes), Up+Left 141-155.
`m2_menu.json` (220 updates) opens the menu twice and walks every row
(`docs/m2_splash_menu.gif` is that run, every second update):

```sh
node tools/preview.mjs zig-out/bin/snouty-genesis.wasm --frames 220 --every 4 \
  --out carts/snouty-genesis/out/m2menu/ \
  --script carts/snouty-genesis/tools/scripts/m2_menu.json \
  --dump-exports debug_state,debug_menu_opens,debug_settings
```

It ends with `debug_state=1 debug_menu_opens=2 debug_settings=75` (sound
on, crop, layout 2, overlay off, Smooth H40 still on from its default;
since M4 one more Down at 88 steps over the Smooth H40 row).

The top-left overlay (menu row "Debug overlay", on by default until the
hardware numbers are in): line 1 update time (both Genesis frames), line 2
presents per second and emulated frames per second (always 1000 us / 500
/ 1000 in wasm, where the clock is a stub), line 3 `z80:on r2 z100 c100`:
the Z80 (`on`, `req` held by BUSREQ, `rst` in reset, `off` switched off)
and the tunables (`render_every`, `z80_scale` and `cpu_scale` in percent).
The bottom lines are the ROM report, shown only with the overlay. Exports:
`debug_frame_count` (Genesis frames, two per update), `debug_step_us`,
`debug_lines` (rows rendered last frame, 128), `debug_state` (0 splash, 1
running, 2 menu, 3 picker, 4 help), `debug_pad` (`core.Pad` bits: up 1,
down 2, left 4, right 8, A 16, B 32, C 64, Start 128), `debug_rom_source`
(0 none, 1 embedded, 2 drive contiguous, 3 drive fragmented),
`debug_rom_size`, `debug_rom_crc` (drive only), `debug_cram_rebuilds`,
`debug_menu_opens`, `debug_settings` (bit 0 sound on, bit 1 crop, bits 2-4
the button layout index, bit 5 overlay on, bit 6 Smooth H40 on), `debug_tone_calls`,
`debug_tone_hz` (0 silent), `debug_sound_on`, `debug_pc`, `debug_sp`,
`debug_sr` (68000), `debug_vdp_line`, `debug_z80_pc`, `debug_z80_state`
(bit 0 BUSREQ, bit 1 reset, bit 2 off). Exports that read the console
return 0 until a ROM is loaded (the picker or help screen is up). The
scrubber's: `debug_scrub_depth` (Genesis frames parked behind live, 0
live), `debug_scrub_history` (frames reachable back from live),
`debug_scrub_records` (closed undo records held), `debug_scrub_slots`
(68-byte ring slots in use), `debug_scrub_capacity` (slots the arena
holds; 0 = no memory, scrubber off), `debug_scrub_arena` (arena bytes;
in wasm `tuning.wasm_arena_bytes`).

Miniplanets (Sik's homebrew, 512 KB, zlib licence, `roms/miniplanets.bin`)
in the simulator or preview: build with it embedded. It is too big for
the badge's flash window, so this is a simulator/preview build only (the
badge reads it from the drive, section 7):

```sh
zig build -Dcart=snouty-genesis -Dcart-mode=xip -Dmd-rom=carts/snouty-genesis/roms/miniplanets.bin
node tools/preview.mjs zig-out/bin/snouty-genesis.wasm --frames 640 --every 60 \
  --out carts/snouty-genesis/out/miniplanets/ --press START:236-239
```

The firmware link of that build fails (`section '.text' will not fit in
region 'FLASH'`: the 512 KB ROM cannot be embedded in the 256 KB XIP
window) and `zig build` exits non-zero, but the wasm is still installed to
`zig-out/bin/snouty-genesis.wasm`, which is all the simulator and preview
need (check the About screen or `debug_rom_size` = 524288). Rebuild without
`-Dmd-rom` to go back to the test ROM.

The scrubber on Miniplanets (with that wasm), `tools/scripts/m3_scrub.json`
(540 updates): `m2_mini300.json`'s presses into level 1 up to update 296,
then a Select hold 300-334 (the menu opens at 314), Left x4 (338, 346,
354, 362), Right x2 (370, 378), Down (382: the panel comes back), Down
(386: cursor on Btns), Right and Left (390, 394: the layout cycles and
back, no scrub), Up (398), B (402: resume, 40 updates of play), a Select
hold 444-478 with Left held 450-462 across the opening (458: must not
scrub), Left x2 (484, 492), B (500), play to 539. `--call-at` reads the
exports after given updates (preview.mjs `--dump-exports` only reads them
at the end):

```sh
node tools/preview.mjs zig-out/bin/snouty-genesis.wasm --frames 540 --every 2 --start-skip 296 \
  --out carts/snouty-genesis/out/m3_scrub/ \
  --script carts/snouty-genesis/tools/scripts/m3_scrub.json \
  --dump-exports debug_state,debug_scrub_depth,debug_scrub_history,debug_scrub_records,debug_scrub_capacity \
  --call-at "340 debug_scrub_depth" --call-at "340 debug_frame_count" \
  --call-at "364 debug_scrub_depth" --call-at "380 debug_scrub_depth" \
  --call-at "400 debug_scrub_records" --call-at "404 debug_scrub_records" \
  --call-at "404 debug_frame_count" --call-at "470 debug_scrub_depth"
```

Verified at the M3 integration (the undo boundaries every 30 frames from
the reset in `begin`, `frame_count` 0): the menu opens at `debug_frame_count` 556, so the first
Left parks on the boundary at frame 540 (depth 16; from live a step goes
back to the start of the open record, a full 30 only when live sits on a
boundary), then 510, 480, 450 (depth 46, 76, 106), Right x2 back to 480
and 510 (76, 46). `debug_frame_count` follows the parked frame (it is
console state). The Btns row cycles `debug_settings` bits 2-4 and back
without moving the depth. B resumes from frame 510: the record 510-540 is
dropped (`debug_scrub_records` one lower at 404 than at 400) and play
continues from 510 (`debug_frame_count` 516 at update 404). The held Left
at the second opening leaves the depth at 0 (update 470); the two Lefts
after it park 22 and 52 frames back (frames 600 and 570), and B resumes
from 570. `debug_state` is 2 from 314 to 402 and 458 to 500, 1 otherwise.
PNGs: the scrub bar over the restored picture after each step
(`frame_0340.png` ...), the full panel again at 384.
`docs/m3_scrub.gif` is updates 290-512 of this run, every third one.

Smooth H40 on Miniplanets (same wasm), `tools/scripts/m4_smooth.json`
(460 updates): `m2_mini300.json`'s presses into level 1 up to update 296,
a Select hold 300-334 (the menu opens at 314), Down x3 (338, 342, 346:
cursor on `Smooth H40`), Right (350: off, it is on by default), B (354:
resume), then Up
360-395 and Right+A 400-440 in play:

```sh
node tools/preview.mjs zig-out/bin/snouty-genesis.wasm --frames 460 --every 20 \
  --out carts/snouty-genesis/out/m4_smooth/smooth/ \
  --script carts/snouty-genesis/tools/scripts/m4_smooth.json \
  --dump-exports debug_settings,debug_state \
  --call-at "340 debug_settings" --call-at "358 debug_settings"
```

`debug_settings` reads 96 at 340 (overlay on, smooth on) and 32 at 358 and
at the end (bit 6 clear: sharp). For the smooth twin of the same frames
drop the Right at 350 from a copy of the script: the emulation is the
same, only the H40 columns differ (each pair averaged vs every second one
dropped). `docs/m4_smooth.png` is update 420 of both, sharp left and
smooth right.

## 5. Controls and the menu

D-pad, badge B = Genesis B, badge A = Genesis C, Start = Start; a Select
tap (under 500 ms) = Genesis A, sent for 4 Genesis frames from the release
(SPEC.md section 5). Holding Select for 500 ms pauses the game under the
menu:

- Up/Down move, A chooses, B or a Select tap resumes; Left/Right (or A)
  cycle a setting row. On the other rows (Resume, where the menu opens,
  Reset, Pick ROM, About) Left/Right scrub time, below.
- `Resume`.
- `Btns B=B A=C S=A`: which Genesis button badge B, badge A and the Select
  tap (S) send; six layouts, this one first.
- `Scale: Squeeze` (badge row r shows Genesis line r*7/4, all 224 lines
  squeezed into 128) or `Scale: Crop` (lines 48..175 at full height, for
  games whose action sits in the middle band). Takes effect on resume.
- `Smooth H40: On/Off` (on by default since M4): how a 320-pixel (H40)
  line fits the 160 columns. Off drops every second Genesis column (sharp,
  about 2.6 ms cheaper per update); On draws all 320
  and shows the average of each pair, so thin H40 text and 1-pixel
  details stay visible (SPEC.md section 6). H32 games look the same either
  way. Takes effect on resume.
- `Sound: Off/On` (the one tone voice; off at boot, root docs/SOUND.md).
- `Debug overlay: On/Off` (also hides the ROM report line).
- `Reset`: the console from its reset vector, settings kept.
- `Pick ROM` (only on the badge with ROM files on the drive): back to the
  picker.
- `About`: version, file name, header name, size, source, region and
  SRAM, CRC and "fragmented" for a drive ROM, or why the drive was not
  used. B back.

The title band shows the ROM's name from its header (Miniplanets says
"MINIPLANETS", the test ROM "SNOUTY TEST").

Time scrubber (SPEC.md section 10). The cart keeps an undo record every 30
Genesis frames (0.5 s) in the RAM left free after the console. In the menu,
on a row that is not a setting, Left steps 0.5 s back and Right 0.5 s
forward (holding one repeats about 4 times a second); a Left or Right
still held from the game does nothing until pressed again. The panel's
bottom line reads `Scrub: live / 3.5s` (at the live position, 3.5 s of
history) or `Scrub: -1.5 / 3.5s` (parked 1.5 s back), dim while there is
no history yet, and `Scrub: no memory` if the cart found no RAM for it.
After a step the panel gives way to that line in a bar at the bottom so
the picture of that moment shows; Left/Right keep scrubbing, Up/Down/A
bring the menu back, B or a Select tap resume. Resuming from a scrubbed
position plays on from there and drops everything after it. Stepping is
exact (the records are swapped with the console's memory, nothing is
replayed). Reset and Pick ROM forget the history. How far back it goes
depends on how much the game writes: about 5 s in play, more on title
screens and menus, under 1 s right after a level load (one load fills most
of the ring; the history then rebuilds at a second per second).

## 6. Web simulator

As Snouty Gear (`carts/snouty-gear/docs/RUNNING.md` section 5):
`node tools/serve-cart.mjs zig-out/bin/snouty-genesis.wasm` in one
terminal, `npm run dev` in `sycl-badge/simulator` in another, then
<http://localhost:1234>. Keys: arrows/WASD d-pad, X or J = badge B =
Genesis B, Z or K = badge A = Genesis C, Enter = Start, Backspace = Select
(tap: Genesis A).

Sound: one voice (`Md.tone()`), a square tone at the level's volume, off
at boot unless built with `-Dsound=true` (badge A in the menu toggles it;
root docs/SOUND.md). The badge plays it through its speaker; the simulator through the browser
(click the page once so the browser lets audio start). In the simulator
the cart drives the audio worklet directly: upstream's wasm shim turns an
infinite `tone2` into a 4 s fade-in that music never gets past
(`cart/src/frontend/audio.zig` explains).

## 7. Benchmark

```sh
zig build -Dcart=snouty-genesis -Dcart-mode=xip
python3 tools/make_romfs.py carts/snouty-genesis/out/romfs_test.img \
  carts/snouty-genesis/roms/snouty-test.bin=TEST.GEN
badge-bench/bench.sh zig-out/firmware/snouty-genesis-xip.elf \
  --config badge-bench/carts/snouty-genesis.toml --symbols
```

The toml is not picked up by name (the ELF's basename has `-xip`), hence
`--config`. It runs 156 updates under `tools/scripts/m2_play.json`: the
36-update splash, then the M1 sequence on the test ROM read from the drive
image (one ROM file: no picker), against the 33.3 ms budget; the M1
targets are a mean under 31 ms and a worst update under 33 ms (calibrated,
the `busy ms` column; the splash updates pull the mean down, so compare
the M1 numbers with the per-update output from update 36 on). The romfs
image is required: the default build reads the drive, and without an
image the run faults reading the boot sector (a bench artefact). An empty
image (`python3 tools/make_romfs.py carts/snouty-genesis/out/romfs.img`)
shows the help screen instead of the game; `--press A:38-39` leaves it for
the embedded ROM. Miniplanets from the drive:
`python3 tools/make_romfs.py carts/snouty-genesis/out/romfs_mini.img carts/snouty-genesis/roms/miniplanets.bin=MINI.GEN`
with `--romfs carts/snouty-genesis/out/romfs_mini.img --script
carts/snouty-genesis/tools/scripts/m2_mini300.json --frames 336`. The
scrubber's menu updates (`render_still` per step) on Miniplanets:
`--script carts/snouty-genesis/tools/scripts/m3_scrub.json --frames 540`
with the same `--romfs` (the drive image's splash has the same 36 updates
as the wasm's, so the ticks line up).

A fragmented drive file (the attendee case: a ROM copied onto a drive
that already holds other files) is made with a second, non-ROM pad file
and `--fragment N`, which hands out clusters N at a time round-robin over
the files. The pad's extension is not scanned (`.DAT`), so the ROM still
starts without the picker:

```sh
head -c 524288 /dev/zero > carts/snouty-genesis/out/pad512.dat
python3 tools/make_romfs.py carts/snouty-genesis/out/romfs_test_frag4.img \
  carts/snouty-genesis/roms/snouty-test.bin=TEST.GEN \
  carts/snouty-genesis/out/pad512.dat=PAD.DAT --fragment 4
python3 tools/make_romfs.py carts/snouty-genesis/out/romfs_mini_frag4.img \
  carts/snouty-genesis/roms/miniplanets.bin=MINI.GEN \
  carts/snouty-genesis/out/pad512.dat=PAD.DAT --fragment 4
```

then the runs above with `--romfs` pointing at the image. `--fragment 4`
gives 2 KB runs, `--fragment 1` single 512-byte clusters (the worst case).
The pad must be at least as large as the ROM for the whole file to be
fragmented: a smaller pad (e.g. 16 KB) fragments only the ROM's first
2 x pad bytes and the rest is one run. The report line says
`drive fragmented` (overlay on). Since M4 the 68000 fetches and the VDP
DMAs straight from each cluster run (`rom.run_at`), so a fragmented file
should bench within about 1 ms of the contiguous one. The picker and help
screens can be captured the same way (`--png 10`, `--press DOWN:40-41`,
`--out DIR`; there is no wasm path to them). The Z80's share: rebuild with
`tunables.z80_scale = 0` (or `z80_enabled = false`) and compare.

### Flash sensitivity (for show day)

badge-bench models flash as zero-wait memory. The XIP cache is 16 KB,
shared with the OS and with the drive ROM's data reads, and no badge has
run this cart yet, so the stall rate is unknown. `--flash-cycles N` adds
a flat N cycles to every instruction fetched from the cart flash window
and `--flash-read-cycles N` N cycles to every data load from the romfs
image; M4 numbers (Miniplanets contiguous, `m2_mini300`, 336 updates,
Smooth H40 on):

| Penalty                      | mean ms | worst ms | over budget |
|------------------------------|--------:|---------:|------------:|
| none                         |   20.74 |    29.07 |           0 |
| `--flash-cycles 1`           |   41.25 |    55.39 |         all |
| `--flash-cycles 2`           |   61.77 |    81.96 |         all |
| `--flash-cycles 4`           |  102.98 |   135.29 |         all |
| `--flash-read-cycles 1`      |   20.88 |    29.39 |           0 |
| `--flash-read-cycles 2`      |   21.03 |    29.71 |           0 |
| `--flash-read-cycles 4`      |   21.31 |    30.35 |           0 |

Reading: about 2.6 M instructions run per update, so every 0.1 cycle of
average instruction-fetch stall costs 1.7 ms mean; the budget's 2.5 ms
of headroom is gone at an average stall of 0.15 cycles per instruction
(a cache miss costs tens of cycles, so the XIP hit rate must stay above
roughly 99.5%). ROM data reads hardly matter: even 4 wait cycles on
every load adds 0.6 ms. On the badge, read the OS overlay's XIP hit and
stall rates (joystick click) with the game running. If the game runs
slow: first `render_every = 3` (20 Hz presents, 50 ms budget, section
8 of SPEC.md), then `z80_scale`, then `cpu_scale`. The lasting fix is a
RAM-text section for the hot loops, which needs a linker-script change
in the SDK (`cart_xip.ld` has no such section): the hot code is
`run_z80` 76 KB, `step_frame` 37 KB (the 68000 interpreter inlined),
`render_line` + `plane` + `on_line` 20 KB, so only the renderer or the
68000 fits beside the 104 KB scrub arena, not all three.

## 8. A ROM on the badge drive

The badge's USB drive (`SYCLBADGE`, the OS romfs region) holds carts and
any other file. With the default `drive` build:

1. Plug in the badge, switch it on; the drive mounts.
2. Copy `snouty-genesis-xip.uf2` onto it, and one `.gen` (or `.md`, `.bin`)
   Genesis ROM next to it. Best on a freshly wiped drive, so the file is
   contiguous; a fragmented one runs through the cluster table and the
   report says so.
3. **Eject the drive before playing** (docs/ROM_DRIVE.md section 2).
4. Start Snouty Genesis. After the splash the game runs (one ROM file), or
   the picker lists the drive's `.gen`/`.md`/`.bin` files (several): file
   name and size per row, the selected file's header name under the list,
   files that cannot run dimmed with the reason (`no SEGA header`, `SMD
   interleaved: convert to .bin`, `mapper or over 4 MB: unsupported`, `SVP
   chip: unsupported`); Up/Down, A plays, B runs the embedded test ROM
   (`docs/m2_picker.png`). With a drive but no Genesis file a help screen
   says to copy one and lists the skipped files; A runs the test ROM
   (`docs/m2_help.png`). The menu's `Pick ROM` row returns to the picker.
   With the overlay on, the bottom lines read
   `ROM: drive contiguous NAME 512 KB crc 1A2B3C4D` (or `fragmented`; plus
   `(i of N)` with several files); with no volume they read
   `ROM: embedded snouty-test.bin 16 KB, drive: NoVolume`.

## 9. Flash the badge

Copy `zig-out/firmware/snouty-genesis-xip.uf2` onto the badge drive. XIP
carts are not yet confirmed on hardware (an open item, not a gate: no
badge until the show). On the badge the overlay's `avg`/`max`
are real update microseconds.
