# Running Snouty Gear

Build the cart, run the host tests, preview it headless or in the web
simulator, put a ROM on the badge drive and flash the cart. Commands run
from the repository root unless noted; outputs land in the root `zig-out/`.

Status: M3. The core emulates the Game Gear: Z80, VDP (mode 4, scanline
renderer, interrupts), Sega mapper with cart RAM, Game Gear port decode and
the PSG register model. The frontend has the boot splash, one-voice sound
the emulator menu and the time scrubber (section 5).

Boot splash: the Snouty mark and "SNOUTY GEAR" slide down onto a dark blue
screen for 0.8 s, a two-note chime (1046 Hz, then 2093 Hz) plays as they
land, and the game starts at 1.2 s (72 frames). Any button skips it.

Sound: the buzzer plays one voice, the loudest Game Gear tone channel as a
square wave (noise and inaudible periods dropped), louder or softer with the
channel's attenuation. It holds while the menu is open; Sound: Off in the
menu stops it. The badge plays it through its speaker; the simulator
through the browser (click the page once so the browser lets audio start).
In the simulator the cart drives the audio worklet directly: upstream's
wasm shim turns an infinite `tone2` into a 4 s fade-in that music never
gets past (frontend/audio.zig explains). `audio.max_volume` caps every
tone the cart plays.

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
carts/snouty-gear/tools/fetch_test_roms.sh --single-step       # plus a 36-file SingleStepTests Z80 subset (~30 MB)
carts/snouty-gear/tools/fetch_test_roms.sh --single-step-all   # streams the whole 1.2 GB suite in batches, logs tests/roms/z80/results.txt
zig build test                                 # every cart's host tests
zig build test -Dtest-filter=bus               # only names containing "bus"
zig build test-z80-strict -Dcart=snouty-gear   # Z80 oracles only; fails if a fixture is absent
```

Without the fetched fixtures `zig build test` reports the SingleStepTests,
ZEXDOC and ZEXALL tests as skipped, not passed; `test-z80-strict` runs them
with `SNOUTY_FIXTURES=required` (ZEXALL in Debug too), fails on a missing
fixture and prints the case counts.

Test names carry a prefix per area, so `-Dtest-filter=` picks one:

- `rom:` the ROM bank table (`from_slice` on 64 KB gives 4 banks at the
  right offsets, 48 KB gives 3, partial banks and the fallback reader).
- `bus:` the memory map and ports: fixed first 1 KB, slot switching with
  bank wrap on 64 KB (mask) and 48 KB (modulo) ROMs, cart RAM enable and
  its 8 KB mirror, the E000 RAM mirror, mapper registers readable as RAM,
  every pad bit on port DC and Start on port 00, link/stereo/control ports,
  routing to the PSG and VDP, the SDSC console capture (port FD), unlisted
  ports reading FF.
- `psg:` latch and data bytes per channel, 10-bit period assembly,
  attenuation, noise bits, `Psg.voice()` (loudest tone, ties to the lowest
  channel, silent/tiny-period/noise channels skipped).
- `smoke:` a hand-assembled ROM sets the mapper, RAM, a VDP register, CRAM,
  VRAM and the PSG through `step_frame`; frames are deterministic across
  snapshot/restore.
- `golden:` `roms/waternet.gg` for 600 frames under
  `tools/scripts/m1_play.json`, frame hashes (144 lines plus CRAM) pinned
  at frames 120 (main menu), 180 (mode select), 360 and 570 (the pipe
  grid). Any core change that alters a pixel fails here; if the change is
  intended, empty `expected` in `tests/golden.zig`, run the test to print
  the new hashes, review the preview frames by eye and paste them back.
- `keyframe` (in `core/gg.zig`): snapshot/restore round trip.
- `z80:` SingleStepTests on whatever `tests/roms/z80/v1/*.json` holds (the
  36-file subset from `--single-step`; skips with a note when absent),
  ZEXDOC always and ZEXALL unless the test binary is a Debug build
  (`GEAR_ZEXALL=1` forces it, `GEAR_ZEX=0` skips both), and unit tests for
  interrupts, HALT and the EI delay. `-Dtest-optimize` defaults to `safe`,
  where both ZEX ROMs take about 18 s together.
- `vdp:` control-port latch and codes, read-ahead buffer, CRAM pairs,
  status side effects, frame and line interrupts, counters, scroll and
  both locks, flips, priority, sprite limit/overflow/collision, 8x16,
  zoom, shift-left, backdrop, and 144 lines per frame in order.

## 4. Headless preview

```sh
node tools/preview.mjs zig-out/bin/snouty-gear.wasm --frames 600 --every 30 \
  --script carts/snouty-gear/tools/scripts/m2_play.json --out carts/snouty-gear/out/ \
  --dump-exports debug_frame_count,debug_lines,debug_pc,debug_iff1,debug_mapper,debug_vdp_regs01,debug_irq_frame \
  --expect "debug_lines == 144"
```

`tools/scripts/m2_play.json` plays Waternet: the 72-frame splash, Start
through the title and menu, cursor moves on the d-pad and button 1 (badge B)
to turn tiles, then a Select hold opens the emulator menu, two Down presses
and B resume (760 frames). The same sequence is the `press` list in
`badge-bench/carts/snouty-gear.toml`. `m1_play.json` is the same game
sequence without the splash (the golden test uses it on the core);
`m2_menu.json` walks every menu row (section 5). `m3_scrub.json` is
m2_play's game sequence with the Select hold moved to update 673 (so the
menu opens on game frame 630, a keyframe), then scrubs (1000 updates):

```sh
node tools/preview.mjs zig-out/bin/snouty-gear.wasm --frames 1000 --every 1 --start-skip 700 \
  --script carts/snouty-gear/tools/scripts/m3_scrub.json --out carts/snouty-gear/out/ \
  --dump-exports debug_state,debug_scrub_depth,debug_history,debug_keyframes,debug_frame_count \
  --at "734 debug_scrub_depth == 90" --at "745 debug_scrub_depth == 60" \
  --at "757 debug_frame_count == 571" --at "757 debug_keyframes == 13"
```

Left x3 (updates 712, 723, 734: `debug_scrub_depth` 30, 60, 90,
`debug_frame_count` 600, 570, 540), Right (745: 60), Up brings the panel
back (751), B resumes (757: depth 0, frame 571, the two keyframes ahead
dropped, 13 left, history 361 frames), 102 game frames (history grows one
frame per frame, a keyframe every 30), Select held again (menu at 861,
frame 672), Left (876: depth 12, frame 660), B (890: frame 661). The same
sequence is the `press` list of `badge-bench/carts/snouty-gear.toml`.

`out/frame_XXXX.png` are 160x128 frames. The top-left overlay shows the
`step_frame` time and FPS (always 1000 us / 500 fps in wasm, where the
clock is a stub); the bottom line is the ROM report (both only while the
debug overlay is on). Exports:
`debug_frame_count`, `debug_step_us`, `debug_lines` (144), `debug_state`
(0 splash, 1 running, 2 menu), `debug_pad` (`core.Pad` bits: up 1, down 2, left 4, right 8,
button 1 16, button 2 32, Start 64), `debug_rom_source` (0 embedded,
1 drive), `debug_rom_size`, `debug_rom_banks`, `debug_rom_crc` (drive only),
`debug_cram_rebuilds`, `debug_menu_opens`, `debug_tone_hz` (what the buzzer
was last told to play, 0 when stopped), `debug_settings` (bit 0 sound on:
clear at boot unless built with `-Dsound=true`, root docs/SOUND.md;
1 crop, 2 A/B swapped, 3 overlay on), `debug_psg_atten` (attenuations
ch0 | ch1 << 4 | ch2 << 8 | noise << 12, 15 = silent, noise control << 16,
latch << 20) and `debug_psg_tones` (10-bit periods ch0 | ch1 << 10 |
ch2 << 20), for checking what a game asks the PSG for.

Time scrubber (frontend/rewind.zig): `debug_scrub_depth` (frames the game
is parked behind live, 0 at live), `debug_history` (frames reachable back
from live), `debug_keyframes` (keyframes in the page store),
`debug_keyframe_cap` (the most it holds; 0 means no room, the scrubber is
off and the menu says "Scrub: no memory"), `debug_pool_bytes` (pool bytes
in use) and `debug_arena_bytes` (the arena the store was laid out in:
a 54 KB static in wasm, the badge's size, 15 keyframes; on the badge the
RAM between `__bss_end__` and `__stack_limit__` minus 1 KB, 56,204 B).

Boot diagnostics, for a game that shows nothing: `debug_pc`, `debug_sp`,
`debug_iff1` (1 = interrupts enabled), `debug_halted`, `debug_mapper`
(slot 0 | slot 1 << 8 | slot 2 << 16 | FFFC << 24, as written),
`debug_vdp_regs01` (register 0 | register 1 << 8; register 1 bit 6 is
display on, bit 5 frame IRQ enable), `debug_vdp_status` (flags without the
read side effect), `debug_vdp_line`, `debug_irq_frame` / `debug_irq_line`
(interrupts the CPU accepted since reset, by source), `debug_frame_t`
(T-states the last frame ran, about 59,736) and `debug_psg_voice` (the PSG
voice the buzzer plays: Hz | attenuation << 24 | channel << 28, 0 silent). A game
stuck with `debug_iff1` 0 and no IRQs usually waits on something the VDP or
a port does not deliver; a PC in RAM (`C000`+) with a wild SP is a crash.

## 5. Web simulator

As Snouty Boy (`carts/snouty-boy/docs/RUNNING.md` section 6):
`node tools/serve-cart.mjs zig-out/bin/snouty-gear.wasm` in one terminal,
`npm run dev` in `sycl-badge/simulator` in another, then
<http://localhost:1234>. Keys: arrows/WASD d-pad, X or J = badge B =
button 1, Z or K = badge A = button 2, Enter = Start, Backspace = Select.

Controls (badge / simulator key):

| Badge        | In the game                  | In the menu                      |
|--------------|------------------------------|----------------------------------|
| D-pad        | D-pad                        | Up/Down move, Left/Right flip a setting or scrub time |
| B (X, J)     | Button 1 (2 when swapped)    | Resume, or back from About       |
| A (Z, K)     | Button 2 (1 when swapped)    | Choose / flip a setting          |
| Start        | Start                        | nothing                          |
| Select tap   | nothing (reserved)           | Resume                           |
| Select hold 500 ms | opens the menu         | -                                |

Start+Select (exit to the OS menu) and the joystick click belong to the OS.

### Menu

Hold Select for half a second: the game pauses under the menu (the frame
stays visible behind it) and the sound holds its note. The band reads
SNOUTY GEAR, the ROM's file name and "verified by deterministic replay".
Rows: Resume; Buttons (`B=1 A=2`, or swapped `A=1 B=2`); Scale (Squeeze
drops every ninth line, Crop shows lines 8..135; seen after resuming);
Sound On/Off; Debug overlay On/Off (FPS, `step_frame` time and the ROM
report line); Reset (restarts the game and resumes); About. About lists
the version, file name, size and 16 KB bank count, the source (drive or
embedded), the mapper slots as written (`Map 00 01 02 FC=00`), and the
drive CRC32 plus `fragmented`, or for an embedded ROM on the badge why the
drive was not used. B or a Select tap resumes; held buttons reach the game
only after they are released. `tools/scripts/m2_menu.json` walks it in the
headless preview (`--dump-exports debug_state,debug_settings,debug_menu_opens`).

Time scrubber (SPEC.md 10): while the game runs the cart keeps a keyframe
every half second and the pad of every frame. On Resume, Reset or About
(not on a setting row) Left steps back half a second and Right forward,
four steps a second while held. The panel's bottom line reads
`Scrub: live / 5.5s` (at the live position / history held) or
`Scrub: -1.5 / 5.5s` (parked 1.5 s back), dim while there is no history;
from 10 s on it shows whole seconds. After a step the panel gives way to
that line in a bar at the bottom, so the restored frame is visible;
Left/Right keep scrubbing, Up/Down/A bring the panel back, B or a Select
tap resume from the parked position. Resuming from the past plays on from
there and drops the future (no branches). Reset also clears the history.
How deep it goes depends on how much the game changes per half second: the
store keeps only the changed 128-byte pages, and evicts the oldest
keyframes when the pool is full. `tools/scripts/m3_scrub.json` walks it
(section 4).

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
