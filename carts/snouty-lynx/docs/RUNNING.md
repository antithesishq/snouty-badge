# Running Snouty Lynx

Build the cart, run the host tests, preview it headless or in the web
simulator, bench it, put a ROM on the badge drive and flash the cart.
Commands run from the repository root unless noted; outputs land in the
root `zig-out/`.

Status: M4 (perf) done, on main; M2 is the frontend described here, M3
the scrubber, M4 the perf pass (PLAN.md Status). Boot splash (the Iris mark and
"SNOUTY LYNX" slide down onto a dark screen, 1.2 s, any button skips; the
cart is silent), then the real core (`core/`: the 65C02, Mikey, Suzy, the
boot without the boot ROM). Rows 102..127 are the status strip: "SNOUTY
LYNX" and the ROM name (header title, else file name); then the origin
("drive 27 KB" / "embedded 27 KB") and the detail (the drive CRC and
`frag`/`raw`/`no-EEP`), or with the debug
overlay on (a menu row, off at boot) fps, mean (`u`) and worst (`w`) step
microseconds, then instructions (`i`) and Suzy pixels (`px`) of the last
frame. A boot error replaces the last line.

Controls: d-pad, A, B as on the Lynx; Start = Pause; Select tap = Option
1 (200 ms after the release, the fast-forward window below); Select tap,
then press and hold = fast forward; Select held 500 ms = the emulator menu over the frozen frame (Up/Down,
A chooses, B or a Select tap resumes): Resume, Buttons (A/B swap), Press
Option 2, Restart Pause+Opt1 (both hold those Lynx buttons for 4 frames
after resuming), Debug overlay, Reset (the boot again), Pick ROM (only
with more than one playable drive file), About. M3 (time scrubber,
`lynx/m3`): in the menu Left/Right on any row but the two settings step
time back/forward one undo record (30 frames, 0.5 s), 4 steps a second
while held; the panel's bottom line reads "Scrub: live / 3.5s" or "Scrub:
-1.5 / 3.5s" (dim with no history, "Scrub: no memory" when the arena has
no room for two records). After a step only a bar at the bottom remains
over the restored picture; Left/Right keep scrubbing, B or a Select tap
play on from there (the history ahead is dropped), Up/Down/A bring the
panel back. Reset and Pick ROM forget the history. Several playable files on
the drive open the picker after the splash (A plays, B runs the first);
a drive build without a usable ROM (no volume, no playable file) shows
the no-ROM screen ("No Lynx ROM on the badge drive.", how to add one, and
`drive: <reason>`) and stays there: the badge cart embeds no ROM, the OS
menu leaves.

On-screen hints (`lib/hint.zig`, shared with Boy, Gear and Genesis): the
splash and the first 3 s of play after the splash or the picker show "Hold
Select: menu" (over the status strip's last line, gone at the first button
press); in the menu the bottom line on Resume reads "Left/Right: rewind"
("Rewind: no history" before the first record; the `Scrub:` readout once
parked or on other rows) and the footer reads "B: back to game", taking
turns every 2 s with "2x Sel+hold: fast". The in-play hint shows "2x
Sel+hold: fast" for 3 s after "Hold Select: menu".

Fast forward (root docs/FAST_FORWARD.md, PLAN.md "Fast forward"): tap
Select, then press it again within 200 ms (`tuning.ff_tap_window`, 12
frames) and hold it. While it is held each update spans two badge frames
(`ff_periods`) and steps unshown, silent Lynx frames until 4 a badge
frame ran or about 29.6 ms of the 33.3 went (`ff_max_frames`,
`ff_budget_us`; Gear's rule: the time so far plus twice the dearest frame
must fit), then one shown frame; the speed (`>>2x`, `>>1.5x`) sits top
right of the picture. A Lynx frame costs 6-10 ms on the badge, so that is
about 1.5x in raycast and Hard Drivin' (4x for light frames, and always
4x in the simulator, which has no clock). The d-pad and buttons reach the
game as usual; letting go is 1x and delivers nothing; the second press
never runs the menu timer. A lone Select tap is Option 1 once the window
runs out with no second press (the double tap drops it). Start in the
window or during fast forward cancels both (Start+Select is the OS's).
The scrubber records every frame.

## 0. Pull and run (review)

```sh
git fetch && git checkout lynx/m2        # or main once merged
zig build -Dcart=snouty-lynx             # uf2 + wasm
zig build test-lynx --summary all        # 90/90
node tools/preview.mjs zig-out/bin/snouty-lynx.wasm --frames 360 --every 3 \
  --script carts/snouty-lynx/tools/scripts/m2_menu.json --out carts/snouty-lynx/out/ \
  --expect "debug_menu_opens == 2" --expect "debug_settings == 8" --expect "debug_led_max == 0"
```

Then the simulator (section 4: hold Backspace for half a second for the
menu) or the badge (section 7). `docs/m2_menu.gif` is the preview above.

## 1. Build

```sh
zig build -Dcart=snouty-lynx
```

- `zig-out/firmware/snouty-lynx.uf2`: the badge cart (RAM cart)
- `zig-out/firmware/snouty-lynx.elf`: same program, for `size -A` and badge-bench
- `zig-out/bin/snouty-lynx.wasm`: simulator and `tools/preview.mjs`

Options:

- `-Dlynx-rom=PATH`: the ROM to embed (default
  `carts/snouty-lynx/roms/raycast.lnx`, the shipped Apache-2.0 raycaster).
  Repository-relative, absolute,
  or `~/x.lnx` (expanded by the build, the shell leaves `=~` alone).
  Headered `.lnx` and headerless dumps both work. To try a local dump in
  the simulator: `zig build -Dcart=snouty-lynx -Dlynx-rom=~/roms/lynx/hard_drivin.lnx`
  (local only, never commit it; `*.lnx`/`*.lyx` are gitignored). Only the
  wasm and `-Dlynx-rom-source=embed` builds embed it (a 128 KB ROM adds
  128 KB to that cart image); on the badge ROMs come from the drive
  (section 6).
- `-Dlynx-rom-source=drive|embed|pack`: `drive` (default) reads the ROM
  from the badge drive and embeds none (no usable drive ROM shows the
  no-ROM screen); `embed` uses only the embedded ROM; `pack` (SPEC.md 13.1) is not built yet,
  prints a note and builds the `drive` cart. The wasm build always embeds.
- `-Dcart-optimize=fast|small|safe|debug` (default `fast`).

`roms/placeholder.lnx` (the 576 B stand-in the drive fixtures use) is regenerated by
`python3 carts/snouty-lynx/tools/make_placeholder_rom.py` (deterministic).

## 2. Host tests

```sh
zig build test-lynx                      # this cart
zig build test                           # every cart
zig build test-lynx -Dtest-filter=drive  # only names containing "drive"
```

- `cart:` the parser: headered 128 KB bank with a short file (header
  fields, block pointers, the partial block through the slice, 0xFF past
  the end, counter wrap), block sizes 256/1024/2048, refusals (bank 1,
  rotation, bad bank 0 size, header only) and the EEPROM warning,
  headerless block size from the file size (512 KB limit), a 128 KB
  headerless dump, the fallback reader.
- `drive:` the drive scan against `tests/fixtures/m0_drive.img` (ROT.LNX
  refused, GAME.LNX the placeholder, RAW.LYX and FRAG.LNX fragmented: every
  byte read back through pointers and the cluster table) and
  `m0_none.img` (nothing playable), plus a blank image (NoVolume).
  Regenerate the images with `python3 carts/snouty-lynx/tests/fixtures/make_fixtures.py`.
- `boot:` the loader decryption (cc65 and Wookie loaders, rejected
  frames), the boot reader over `core/cart.zig`, the local dumps and the
  cross-check against the real boot ROM (skipped without `~/roms/lynx/`
  and `tests/roms/boot/*.boot.json`, docs/BOOT.md).
- `mikey:` timer periods at every clock select, global clock edges,
  linking 0 -> 2 -> 4 and 1 -> 3 -> 5 -> 7, one-shot DONE and RESET_DONE,
  the CTLB software clock, INTSET/INTRST and the UART level, palette and
  IODAT, the vertical blank cadence from the boot values (105 x 159 us),
  the DISPADR latch and the DMA/refresh steal, quiet fast timers.
- `bus:` MAPCTL overlays, tick costs (page-mode stream, Mikey timers,
  Suzy, RCART), JOYSTICK/SWITCHES/LEFTHAND, the cart port protocol.
- `lynx:` the post-boot state on raycast, the $FE00 and $FE4A traps, the
  ROM-space reboot, CPUSLEEP (sprites, SDONEACK, pending IRQs, the
  optional idle sleep), the frame clock and the display copy, a cart that
  does not boot.
- `golden:` the runner's input model and script parser; raycast under
  `tools/scripts/m1_play.json` and the drhelius lynx-tests carts
  (`tests/roms/lynx-tests/`, `tools/fetch_test_roms.sh`; skipped when
  absent). The hash tables are empty until integration: the test prints
  them.

## 2a. Run a ROM headless (`run-lynx`)

```sh
zig build run-lynx -- carts/snouty-lynx/roms/raycast.lnx \
  carts/snouty-lynx/tools/scripts/m1_play.json 300 out/run-raycast
zig build run-lynx -- carts/snouty-lynx/tests/roms/lynx-tests/timers.lnx - 300 out/run-timers --quiet --every 0
zig build run-lynx -- ~/roms/lynx/hard_drivin.lnx - 1500 out/run-hd --every 150   # local dump, never committed
zig build run-lynx -- carts/snouty-lynx/roms/raycast.lnx \
  carts/snouty-lynx/tools/scripts/m1_play.json 600 out/run-raycast --quiet --wav out/run-raycast/raycast.wav
```

Arguments: the ROM (headered `.lnx` or a headerless dump), the input
script (`-` for none: the splash then ends by itself at update 72),
the number of badge updates, the output directory. It runs the cart's
input model (`tests/runner.zig`: the splash, the held-button suppression,
a Select tap = Option 1) and prints one line per update: the frame hash
(the same hash `tests/golden.zig` pins), the pad word and the
diagnostics (ticks, instructions, IRQs taken, Suzy pixels, sleep ticks,
display frames, PC). `frame_UUUU.ppm` (160x102, the 12-bit palette
widened) is written every `--every N` updates (default 30), at each
`--at U,U,...` and at the last update. `--quiet` prints only those
updates and the summary; `--idle-sleep` switches CPUSLEEP to the
sleep-until-interrupt model (`core/lynx.zig`). `--wav FILE` writes the
run's sound: `Lynx.audio_out` after every update (735 samples, 1/60 s;
735 samples of silence, 128, for the splash updates that do not step the
core) as an 8-bit unsigned mono 44,100 Hz WAV, the badge firmware's
streaming format before the frontend's rate control (docs/AUDIO.md).
Paths are relative to the repository root. Convert with any image tool (`python3 -c "from PIL import
Image; Image.open('f.ppm').save('f.png')"`).

## 3. Headless preview

```sh
node tools/preview.mjs zig-out/bin/snouty-lynx.wasm --frames 300 --every 30 \
  --script carts/snouty-lynx/tools/scripts/m1_play.json --out carts/snouty-lynx/out/ \
  --dump-exports debug_state,debug_boot_error,debug_instr_count,debug_display_frames,debug_led_max \
  --expect "debug_state == 1" --expect "debug_boot_error == 0" --expect "debug_led_max == 0"
```

`tools/scripts/m1_play.json`: A skips the splash at update 40, then Up
70-130, Left 131-160, Up+Right 161-210, Down 211-240, Right 241-270, Up+B
271-299 (raycast moves and turns). `tools/scripts/m0_boot.json` (Start,
Up+B, a Select tap) still works.

The menu (M2), `tools/scripts/m2_menu.json`, 360 updates: A at 40, Up
45-70, Select held 75-109 (the menu opens at 104), Down to Buttons and
Right (A/B swapped, `debug_settings` 4) at 125, Left back at 135, down to
Debug overlay and A (on, 8) at 155, Right (off) at 165, down to About and A
at 180, B back at 205, up to Press Option 2 and A at 230 (resumes with
`debug_pad` 4 for updates 230-233), Left 240-255, a second Select hold
260-294, the overlay on at 306, a Select tap resumes at 312, Up 320-350:

```sh
node tools/preview.mjs zig-out/bin/snouty-lynx.wasm --frames 360 --every 3 \
  --script carts/snouty-lynx/tools/scripts/m2_menu.json --out carts/snouty-lynx/out/ \
  --dump-exports debug_state,debug_settings,debug_menu_opens,debug_hold_pad,debug_led_max \
  --at "104 debug_state == 2" --at "126 debug_settings == 4" --at "156 debug_settings == 8" \
  --at "230 debug_pad == 4" --at "234 debug_pad == 0" --at "312 debug_state == 1" \
  --expect "debug_state == 1" --expect "debug_settings == 8" --expect "debug_menu_opens == 2" \
  --expect "debug_hold_pad == 4" --expect "debug_led_max == 0"
python3 tools/make_gif.py carts/snouty-lynx/out/ carts/snouty-lynx/docs/m2_menu.gif --scale 2 --ms 50
```

Exports: `debug_frame_count`,
`debug_state` (0 splash, 1 running, 2 menu, 3 picker, 4 no-ROM screen),
`debug_menu_opens`, `debug_settings` (bit 0 sound on, never in the wasm
build, which has no streaming audio; bit 2 A/B swapped, bit 3 debug
overlay on), `debug_hold_pad` (the `core.Pad` bits the
last Press Option 2 / Restart row asked for: 4 or 264),
`debug_pad` (`core.Pad` bits: A 1, B
2, Option 2 4, Option 1 8, right 16, left 32, down 64, up 128, Pause 256),
`debug_rom_source` (0 embedded, 1 drive, 2 none), `debug_rom_size` (file bytes),
`debug_rom_block_size`, `debug_rom_direct_blocks`, `debug_rom_headered`,
`debug_rom_crc` (drive only), `debug_palette_rebuilds`, `debug_led_max`
(largest neopixel channel; must be 0); from M1 the core's diagnostics:
`debug_ticks_lo`/`debug_ticks_hi` (16 MHz ticks), `debug_instr_count`,
`debug_instr_per_frame`, `debug_pixels_drawn` (Suzy), `debug_irq_count`,
`debug_sleep_ticks` (CPU asleep while Suzy draws), `debug_display_frames`
(vertical blanks copied), `debug_boot_error` (0 booted, 1-4 the
`core.boot.BootError`), `debug_pc`. In wasm `micros_since_boot` adds 1000
per call, so the strip's step times mean nothing there.

The scrubber (M3), `tools/scripts/m3_scrub.json`, 480 updates: A at 40,
`m1_play.json`'s moves up to 280 (Up+B 241-280), Select held 285-320 (the
menu opens at 314), Left held 330-375 (steps back at 330, 345, 360, 375:
the press and three repeats at 4/s), Right at 390 and 400 (forward
twice), B at 415 (play on from the parked position), then Up 420-450,
Right 451-479. With the badge-sized arena (64,232 B since M4; 63,568 at M3) raycast holds one
closed 60-frame record plus the open one, so the history is about 1.6 s:
Left reaches the oldest record on the second step and the later presses
do nothing, and two Rights are back at live.

```sh
node tools/preview.mjs zig-out/bin/snouty-lynx.wasm --frames 480 --every 5 \
  --script carts/snouty-lynx/tools/scripts/m3_scrub.json --out carts/snouty-lynx/out/ \
  --dump-exports debug_state,debug_scrub_depth,debug_scrub_history,debug_scrub_capacity,debug_scrub_arena,debug_led_max \
  --at "320 debug_state == 2" --at "414 debug_state == 2" --at "415 debug_state == 1" \
  --at "329 debug_scrub_history > 0" --at "376 debug_scrub_depth > 0" \
  --at "479 debug_scrub_depth == 0" --expect "debug_menu_opens == 1" --expect "debug_led_max == 0"
```

Fast forward, `tools/scripts/ff_play.json`, 900 updates: A at 40, no
input until 250 (the play hints: "Hold Select: menu", then "2x Sel+hold:
fast" from 220), a Select tap 250-252 and the second press 258-440 (fast
forward, Left 260-290, Up 291-400, Up+Right 401-440), again 470-472 and
476-510 with Down, a lone tap 540-542 (Option 1 on 555-557), a 21-update
press 560-580 (a tap too: Option 1 on 593-595), Up+Right 600-660, the
menu hold 680-720 (open at 709; its footer turns to "2x Sel+hold: fast"
at 829). `docs/ff_2026-10-04.png` is a contact sheet of updates 100, 230,
300, 450, 760 and 860:

```sh
node tools/preview.mjs zig-out/bin/snouty-lynx.wasm --frames 900 --every 10 \
  --script carts/snouty-lynx/tools/scripts/ff_play.json --out carts/snouty-lynx/out/ff/ \
  --sample debug_frame_count,debug_ff_frames,debug_pad --sample-every 1 \
  --at "300 debug_ff_frames == 4" --at "490 debug_ff_frames == 4" --at "450 debug_ff_frames == 1" \
  --at "554 debug_pad == 0" --at "555 debug_pad == 8" --at "558 debug_pad == 0" --at "593 debug_pad == 8" \
  --at "709 debug_state == 2" --expect "debug_menu_opens == 1" --expect "debug_led_max == 0"
```

`debug_ff_frames` is the frames the last update stepped (1 at 1x, 4 while
fast in the simulator, up to 8 on the badge; 0 outside play).

The scrubber's exports: `debug_scrub_depth` (Lynx frames parked behind
live, 0 live), `debug_scrub_history` (frames reachable back from live),
`debug_scrub_records` (closed undo records held), `debug_scrub_slots`
(68-byte ring slots in use), `debug_scrub_capacity` (slots the arena
holds; 0 = no memory, scrubber off), `debug_scrub_arena` (arena bytes; in
wasm `tuning.wasm_arena_bytes`, on the badge `__stack_limit__` -
`__bss_end__` - 1 KB).

## 4. Web simulator

As Snouty Boy (`carts/snouty-boy/docs/RUNNING.md` section 6). Terminal 1:

```sh
cd carts/snouty-lynx
node ../../tools/serve-cart.mjs      # serves ../../zig-out/bin/snouty-lynx.wasm on :2468, reloads on rebuild
```

Terminal 2: `cd sycl-badge/simulator && npm install && npm run dev`, then
<http://localhost:1234>. Keys: arrows/WASD d-pad, Z or K = badge A = Lynx
A, X or J = badge B = Lynx B, Enter = Start = Pause, Backspace = Select
(tap = Option 1; tap, then press and hold = fast forward, 4x here; held
half a second = the menu). The simulator always
runs the embedded ROM, so it never shows the picker or the no-ROM screen.

## 5. badge-bench

```sh
badge-bench/bench.sh zig-out/firmware/snouty-lynx.elf --symbols
```

`badge-bench/carts/snouty-lynx.toml` runs `m3_scrub.json` for 480 frames
(section 3: play to 280, the menu from update 314, four scrubs back, two
forward, B at 415, play to 479) over the committed drive fixture `tests/fixtures/m1_drive.img`
(RAYCAST.LNX = roms/raycast.lnx), so the cart reads the drive as on the
badge. M3 (ReleaseFast with the CPU dispatcher not inlined, the undo
hooks on): all 480 frames busy mean 9.00 ms, p95 14.57, worst 16.81 (the
second frame after resuming, the one frame over the 16.7 ms budget);
game frames 41-284 mean 12.04, worst 16.13; menu frames 0.93; a scrub step
1.61; the resume frame 16.47. M4 (PLAN.md "M4 perf pass", same build
settings): mean 6.13, p95 9.47, worst 10.73 (frame 418), 0 over; game
frames 41-284 mean 8.27; the resume frame 10.50 (the game's heavy phase
of its three-frame cycle, as 418: resuming itself costs next to
nothing). M2 for comparison (exec inlined, no hooks):
game frames 0-299 mean 8.42, p95 11.50, worst 12.94 (M1 8.44 / 11.53 /
12.96); menu frames 334-364 mean 0.92, worst 1.17 (the frozen-frame copy).
The default build also writes `snouty-lynx-xip.uf2` (docs/SCRUB.md: the
XIP cart has 187,712 B of arena, about 3-6 s of history; untested on
hardware). `m2_play.json` still runs with `--script
carts/snouty-lynx/tools/scripts/m2_play.json --frames 400`.

Fast forward on the bench (PLAN.md "Fast forward" has the numbers): the
same script over the drive fixture, and Hard Drivin' with
`tools/scripts/hd_ff.json` (hd_drive.json's presses plus fast forward
through the title, 106-560, and the drive, 1306-1790):

```sh
badge-bench/bench.sh zig-out/firmware/snouty-lynx.elf --frames 900 \
  --script carts/snouty-lynx/tools/scripts/ff_play.json
python3 tools/make_romfs.py out/lynx-romfs.img ~/roms/lynx/hard_drivin.lnx
badge-bench/bench.sh zig-out/firmware/snouty-lynx.elf --romfs out/lynx-romfs.img \
  --frames 1800 --script carts/snouty-lynx/tools/scripts/hd_ff.json
```

A fast-forward update is meant to take up to ~30 ms (two badge frames), so
it reads as over the 16.7 ms budget there; count it against 33.3 ms.
`--lcd --png 1` shows the `>>` indicator gone the update after release.

The picker (drive builds only, never in wasm): a drive with two playable
files, raycast under two names (not committed), and a script that skips
the splash, moves down and plays the second file, then opens it again
from the menu:

```sh
python3 tools/make_romfs.py out/lynx-two.img carts/snouty-lynx/roms/raycast.lnx=RAYCAST.LNX \
  carts/snouty-lynx/roms/raycast.lnx=AGAIN.LNX
badge-bench/bench.sh zig-out/firmware/snouty-lynx.elf --romfs out/lynx-two.img \
  --press A:40-40 --press DOWN:50-50 --press A:60-60 --frames 120 --png 5 --out out/bench-pick
```

`frame_0045.png` is the picker, `frame_0100.png` the game with `AGAIN.LNX`
(About names the file). `tests/fixtures/m0_none.img` (only a refused
`ROT.LNX`) shows the no-ROM screen (`drive: ROT.LNX: rotated`); so does
an empty `tools/make_romfs.py out/empty.img` (`drive: no .lnx/.lyx file`).
With a local dump:

```sh
python3 tools/make_romfs.py out/lynx-romfs.img ~/roms/lynx/hard_drivin.lnx
badge-bench/bench.sh zig-out/firmware/snouty-lynx.elf --romfs out/lynx-romfs.img --png 100 --out out/bench-lynx
```

## 6. A ROM on the badge drive

See README.md ("A ROM on the badge drive"): copy the UF2 and one `.lnx`
file onto `SYCLBADGE`, **eject**, start the cart; the strip names the file.

## 7. Flash the badge

Install it as in [docs/INSTALL.md](../../../docs/INSTALL.md) (the badge's
`SYCLBADGE` drive, not the RP2350 bootloader): copy
`zig-out/firmware/snouty-lynx.uf2` (repository root) onto the drive, plus
a `.lnx` file if you want one (section 6), eject, and start Snouty Lynx
from the OS menu. The default build also writes `snouty-lynx-xip.uf2`,
the XIP cart with the longer scrub history (section 5); install that one
instead to try it (XIP carts are not yet confirmed on a badge).
