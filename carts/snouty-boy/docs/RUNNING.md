# Running Snouty Boy

Build the cart, run the host tests, play it in the web simulator or headless,
and flash it to a SYCL Badge V2.

The cart lives in `carts/snouty-boy/` of the snouty-badge repository.
Commands below run from that directory unless noted; only `zig build` runs
from the repository root (`../..`), and its outputs are in the root
`zig-out/` (`../../zig-out/...` from here).

## 1. Prerequisites

Zig, Node.js, Python with Pillow and git: see `../../docs/RUNNING.md` at the
repository root. This cart also needs curl (for `tools/fetch_test_roms.sh`);
`tools/romcheck.py` needs only Python 3.

## 2. Checkout layout

Cloning the repository with its `sycl-badge/` submodule is described in
[`docs/RUNNING.md`](../../../docs/RUNNING.md) section 2 at the
repository root; this cart is `carts/snouty-boy/` in that checkout.

Milestones are annotated tags (`git tag -n1 'snouty-boy/*'`: `snouty-boy/m1`,
`/m3`, `/m4`); work in progress is on `m<N>-*` branches.

## 3. Test ROMs

The web simulator build (and a `-Drom-source=embed` badge build) embeds one
Game Boy ROM; the default is `tests/roms/dmg-acid2.gb`. The default badge
build embeds none (section 9). The test ROMs are freely redistributable but not
committed (`tests/roms/` is gitignored), so fetch them once (without them
the build prints a note and embeds the committed `roms/2048.gb` instead):

```sh
cd carts/snouty-boy
tools/fetch_test_roms.sh
```

This downloads Blargg's `cpu_instrs` (whole and the 11 individual tests),
`instr_timing` and `mem_timing`, plus `dmg-acid2.gb` and its reference PNG.
`python3 tools/romcheck.py some.gb` prints a ROM's header (title, MBC, sizes)
and whether Snouty Boy can ship it.

Game Boy Color ROMs (SPEC.md 19): a ROM whose header byte 0x143 has bit 7
set (`.gbc` files, and CGB-enhanced `.gb` files such as Rex Runner) boots
in CGB mode; everything else runs as a DMG. The M7 candidates
`tests/roms/rex-runner.gb` (32 KB, MIT) and `tests/roms/rebound.gbc`
(128 KB, MIT) are copied into `tests/roms/` by hand; the tests that use
them are skipped when they are missing.

## 4. Build

From the repository root:

```sh
zig build -Dcart=snouty-boy   # only this cart; plain `zig build` builds every cart
```

This writes, in the root `zig-out/`:

- `zig-out/firmware/snouty-boy.uf2` for the badge
- `zig-out/firmware/snouty-boy.elf` (same program, for `size` and debugging)
- `zig-out/bin/snouty-boy.wasm` for the simulator and `preview.mjs`

Options:

- `-Drom=path/to/game.gb`: the ROM to embed in the wasm build, and with
  `-Drom-source=embed` in the badge build (default
  `tests/roms/dmg-acid2.gb`, falling back to `roms/2048.gb`). The path is
  relative to the repository root, e.g. `-Drom=carts/snouty-boy/roms/2048.gb`;
  a path relative to this cart such as `-Drom=roms/2048.gb` also works. The
  shipped game goes in `roms/` with its license next to it.
  A `.gbc` path works the same way, e.g.
  `-Drom=carts/snouty-boy/roms/rebound.gbc`.
- `-Dcart-optimize=fast|small|safe|debug`: optimize mode for the cart
  (default `fast`, SPEC.md section 8).
- `-Drom-source=drive|embed`: where the badge build gets its ROM (default
  `drive`: a `.gb`/`.gbc` file on the badge's USB drive and no ROM built
  in; `embed`: the embedded ROM only, as before M5). See section
  9. The wasm build always runs the embedded ROM. `pack` belongs to Snouty
  Gear and is refused here.
- `-Dcart-mode=ram|xip|both` (shared with every cart): `ram` (default) is
  the usual RAM cart, `snouty-boy.uf2`; `xip` builds `snouty-boy-xip.uf2`,
  which runs code and the embedded ROM from the 256 KB cart flash window
  and keeps all of the cart RAM for state (unproven on hardware so far);
  `both` builds both. It matters for `-Drom-source=embed` with a big ROM:
  an embedded ROM above about 64 KB (rebound.gbc, 128 KB) leaves the RAM
  cart too little RAM, and such a build links but shows "Not enough RAM
  for the time scrubber" at start. A drive ROM is read from flash in any
  mode.
- `-Dneopixels=true` (shared with every cart, default off): compiles the
  menu's dormant neopixel history meter back in (section 6). Development
  only; the LEDs are too bright for normal use.

The three builds that must always link:

```sh
zig build -Dcart=snouty-boy                                                        # drive (default), no ROM embedded
zig build -Dcart=snouty-boy -Drom-source=embed -Drom=carts/snouty-boy/roms/rex-runner.gb
zig build -Dcart=snouty-boy -Drom-source=embed -Drom=carts/snouty-boy/roms/rebound.gbc -Dcart-mode=xip
```

Memory (SPEC.md 19.4). Nothing is sized at compile time from the ROM.
Once the ROM is chosen, `cart/src/frontend/rewind.zig` (`layout`) takes
the RAM between the end of `.bss` and the stack, less 1 KB (the arena),
and places in it the live console (50.4 KB), its cart RAM (per header, 0
to 32 KB) and the page store: per keyframe a table (2 bytes per 512-byte
page of state) and typically 8 pool pages, at most 64 keyframes, the pool
gets the rest. When not even two keyframe tables and half a full keyframe
fit, the cart shows the halted screen instead of the game. Computed from
the linker symbols (fast, 2026-09-29; the default build's arena grew from
136 to 168 KB on 2026-10-04 when its 32 KB fallback ROM went, so its
keyframe counts are now lower bounds):

| Build | Arena | 2048-gb (DMG, 2 KB RAM) | rex-runner (CGB, 8 KB RAM) | rebound (CGB, no RAM) |
|---|---:|---|---|---|
| default (drive) | 168 KB | 160 pages (80 KB), 19 kf | 147 pages (74 KB), 18 kf | 164 pages (82 KB), 20 kf |
| `embed` rex-runner (RAM) | 158 KB | - | 189 pages (95 KB), 23 kf | - |
| `embed` rebound (XIP) | 262 KB | - | - | 404 pages (202 KB), 50 kf |

A clean build of this cart takes a couple of minutes (all carts: several);
incremental rebuilds take seconds.
`size ../../zig-out/firmware/snouty-boy.elf` shows `.text` (code plus the embedded
ROM, if any), `.data` and `.bss` against the cart RAM budget in SPEC.md sections 13
and 19.4 (`snouty-boy-xip.elf` for the XIP cart, whose `.text` is in flash).
The arena is in none of them: it is `__stack_limit__ - 1024 -
align4(__bss_end__)` (`nm ../../zig-out/firmware/snouty-boy.elf | grep -E
'__bss_end__|__stack_limit__'`), and the debug overlay's third line shows
the keyframes it currently holds.

## 5. Host tests

From the repository root:

```sh
zig build test                        # all core tests, natively (and every other cart's host tests)
zig build test -Dtest-filter=acid     # only tests whose name contains "acid"
```

The core (`core/`) is badge-agnostic and runs on the host: Blargg's CPU tests
(pass when the serial output says "Passed"), the dmg-acid2 image compared
byte for byte with `tests/acid2_reference.bin`, PPU and APU unit tests, the
scrubber ring logic (`tests/ring_unit.zig`), the keyframe page store
(`tests/kstore_unit.zig`) and the determinism check. They need
`tools/fetch_test_roms.sh` first.

`tests/determinism.zig` (SPEC.md 10.2, `-Dtest-filter=determinism`) reads
`roms/2048.gb` at run time (skipped if it is missing), plays 600 frames with
a scripted pseudo-random pad stream, keyframes every 30 frames, then for
each keyframe restores it into a fresh console, replays the 30 logged pads
and requires the next keyframe field for field. Keyframes are compared
with `std.meta.eql` per field, not as raw bytes: the struct has auto layout
and its padding is undefined.

The same file runs the check through the page store (the cart's real
keyframe path) on 2048-gb and, in CGB mode, on `tests/roms/rex-runner.gb`
and `tests/roms/rebound.gbc` when present, and prints one line per ROM with
the keyframe sizes the memory budget rests on. To see them, run the test
binary by hand from this directory after `zig build test`:

```sh
$(ls -t ../../.zig-cache/o/*/test | head -1) 2>&1 | grep kstore
# kstore roms/2048.gb (dmg, ...): first keyframe 2 pages (1 KB), later min/avg/max 3/8/14 pages, ...
```

The same check can run inside the cart: set `const self_check = true;` in
`cart/src/frontend/rewind.zig` and rebuild. Every new keyframe is then
re-derived from the previous one in a spare console; a mismatch paints the
debug overlay red (and `debug_alarm` reads 1). It costs a second console
and its cart RAM (about 50 KB less pool) and doubles the CPU per frame, so
it is off by default. `-Dtest-optimize=` sets their optimize mode
(default `safe`).

## 6. Web simulator

Terminal 1 serves the cart and live-reloads it:

```sh
cd carts/snouty-boy
node ../../tools/serve-cart.mjs            # serves ../../zig-out/bin/snouty-boy.wasm on :2468
# or: node ../../tools/serve-cart.mjs path/to/other.wasm --port 2468
```

This serves `http://localhost:2468/cart.wasm` (with CORS) and
`ws://localhost:2468/ws`. Whenever the file changes, which happens after
every `zig build`, it sends `reload` to the page.

Terminal 2 runs the simulator UI:

```sh
cd ../../sycl-badge/simulator
npm install
npm run dev
```

Then open <http://localhost:1234>. The hosted simulator at
<https://badgesim.microzig.tech/> also fetches from `localhost:2468` and should
work with the same watcher in Chrome; if it does not load, use the local UI.

Sound: off at boot unless built with `-Dsound=true`; the menu's Sound row
toggles it (root docs/SOUND.md). On the badge the core renders all four
Game Boy channels at 44.1 kHz and streams them to the newer firmware's
audio ring (SPEC.md 9); the show badges run that firmware. On the old
firmware the badge stays silent (no `tone2` is sent: on the new firmware
those words are the ring's). With the debug overlay on, line 4 reads
`q N u N`: samples queued in the ring (about 1,476 when settled) and the
updates that found it empty. In the simulator, which has no streaming
audio, the cart plays one voice (the loudest of channels 1..3) through
the audio worklet directly (click the page once so the browser lets audio
start): upstream's wasm shim turns an infinite `tone2` into a 4 s fade-in
that music never gets past (`frontend/audio.zig` explains).

Keys (from `sycl-badge/simulator/README.md`) and what they do here:

| Keyboard           | Badge          | Game Boy / emulator                         |
|--------------------|----------------|---------------------------------------------|
| Arrow keys or WASD | Joystick       | D-pad                                       |
| Z or K             | A              | A                                           |
| X or J             | B              | B                                           |
| Enter or Y         | Start          | Start                                       |
| Backspace or T     | Select, tap    | Select (3 frames), 200 ms after the release |
| Backspace or T     | Select, hold 0.5 s | opens the emulator menu, game paused    |
| Backspace or T, tap then hold | Select, tap then press and hold | fast forward while held (up to 4x) |
| ... then Left arrow (WASD: A) | ... then Left (held Select) | chorded rewind: game frozen, Left/Right step 0.5 s, let go of Select to play on |
| Shift              | Joystick click | nothing (the OS owns it)                    |
| Escape             | System menu    | leaves the cart                             |

Select is never passed straight through (SPEC.md section 5): while it is
held the game sees nothing; released within 500 ms (30 frames) the game gets
a short Select press 200 ms later (the fast-forward window below); held
500 ms, the emulator menu opens instead. Holding
Start and Select together for 250 ms exits the cart on the badge (the OS
owns that chord), so Game Boy soft-reset combos do not work; Start pressed
during a Select hold cancels both the tap and the menu.

Fast forward (root `docs/FAST_FORWARD.md`): tap Select, then press it again
within 200 ms and hold it (`input.ff_tap_window`, 12 frames). Fast forward
runs from that second press while Select is held; the first tap never
reaches the game, the second press never starts the menu timer, and letting
go returns to 1x and delivers nothing. The d-pad and the other buttons
reach the game as usual meanwhile. Each badge update steps up to 4 game
frames (`tuning.ff_max_frames`) within about 13 ms (`tuning.ff_budget_us`),
drawing only the last, so the game runs 2x to 4x depending on how heavy it
is; a game too heavy for that (DMG Tetris busy-waits for VBlank) gets up to
8 frames in two refreshes instead (`tuning.ff_slow_budget_us`, the picture
at 30 Hz). `>>4.0x` in the bottom-right corner shows the speed, game frames
per 60 Hz refresh. Sound is silent and every frame goes into the
scrubber's history as usual. Start during the 200 ms window or during fast
forward is the OS chord: nothing is delivered. In the simulator and
`preview.mjs` (no real clock) every fast update steps 4 frames, e.g.
`node ../../tools/preview.mjs <rex-runner wasm> --frames 420 --script
tools/scripts/ff_rex.json` (`docs/fast_forward.gif`: Rex Runner at 1x, at
4x, at 1x again). While fast forwarding, the debug overlay's `avg`/`max`
time every frame of the update, not one step. During fast forward Left is
reserved for the chorded rewind and never reaches the game (a Left held
from before stays masked until released and pressed again).

Chorded rewind (root `docs/FAST_FORWARD.md`, "Chorded rewind"): press Left
while fast forwarding. The game freezes and steps back 0.5 s at once; with
Select still held, Left steps back and Right forward 0.5 s at a time,
repeating 4 times a second while held, exactly as the menu's scrubber
(the same `rewind.step`). Only the menu's scrub bar shows, at the bottom
("Scrub: -1.5 / 3.5s", or "Rewind: no history"); no `>>`. Let go of
Select: the game plays on from that position and the future after it is
dropped, as resuming from the menu does (a Left or Right still held waits
for a release). No button reaches the game meanwhile, and Start (the OS
chord with the held Select) changes nothing. `docs/rewind.gif`
(`tools/scripts/rewind_rex.json`): Rex Runner at 1x, fast forwarded into
a cactus, rewound 1.2 s, forward 0.5 s, played on; `docs/rewind_sheet.png`.
`tools/scripts/rewind_eq_menu.json` and `rewind_eq_chord.json` reach game
frame 198 by the menu and by fast forward, step back three times to frame
120, resume and jump twice: frames 290..419 of the first equal frames
264..393 of the second below the debug overlay (PLAN.md).

In the menu (drawn over the frozen game frame):

| Key            | Action                                                     |
|----------------|------------------------------------------------------------|
| Up / Down      | move                                                       |
| A              | choose: Resume, cycle Palette (Color in CGB mode) / Scale / Sound / Debug overlay, Reset (restart the ROM), About |
| Left / Right   | on Palette / Color / Scale / Sound / Debug overlay: cycle it. On Resume, Reset, About: time scrubber, back / forward 0.5 s (repeats 4 times a second while held) |
| B, Select tap  | resume (B also leaves About)                               |

On-screen hints (`lib/hint.zig`, shared with Gear, Genesis and Lynx): the
splash shows "Hold Select: menu"; the first 3 s of play after the splash or
the picker show it with "2x Sel+hold: fast" under it (a two-line strip at
the bottom, gone at the first button press); About ends with "2x
Sel+hold: fast", "then Left: rewind" and "B: back"; in
the menu, the bottom line on Resume reads "Left/Right: rewind" ("Rewind: no
history" before the first keyframe; the `Scrub:` readout once parked or on
other rows) and the footer reads "B: back to game".

Game Boy Color mode. The title band and splash read "SNOUTY BOY COLOR"
and the menu is black on white. The Palette row becomes `Color: LCD` /
`Color: Raw`: LCD (default) is a GBC screen approximation (colours mixed
and slightly compressed, as on the real, paler LCD), Raw shows palette RAM
as exact RGB555. The frozen frame keeps its colours until the next frame is
drawn (a scrub step or resuming). With the LCD off a CGB shows white.

Time scrubber (SPEC.md sections 10 and 19.3). The cart keeps a keyframe of
the whole console every 30 frames plus the pad byte of every frame.
Keyframes live in a page store: the state is cut into 512-byte pages, a page
unchanged since the previous keyframe is shared and an all-zero page costs
nothing, so a 2048-gb keyframe costs about 4 KB and the default build holds
up to 19 of them (9 s; up to 50 in an XIP build); when the pool fills, the
oldest keyframes go first. The menu opens on Resume,
so Left right away steps back: the menu folds into a bar at the bottom
(`Scrub: -1.5 / 3.5s`, how far back you are / how much history there is)
over the restored frame. Left/Right keep stepping, Right past the newest
keyframe returns to `live`, Up/Down/A bring the full menu back, and B or a
Select tap resumes play from the shown point. Resuming from a scrubbed
point throws away the future after it (no branching history). In the full
menu the bottom line shows the same readout. Reset in the menu also clears
the history.

Neopixels are off: the cart never writes a non-zero value (a coworker's
badge showed the LEDs are unusably bright even at 1%, 2026-09-29; see
docs/NEOPIXELS.md at the repository root). The menu's history meter (one
LED per fifth while the menu is open) is compiled out; build with
`zig build -Dcart=snouty-boy -Dneopixels=true` to re-enable it for
development, and build that way once after touching `frontend/menu.zig` so
the dormant path keeps compiling.

The picture shown after a step is the frame the game drew 1/60 s after the
keyframe (the cart steps one frame to draw it and restores the keyframe
again), so the state you resume from is exactly the keyframe.

Buttons still held when the menu closes (or the splash is skipped) reach
the game only after being released and pressed again. The boot splash
(1.2 s) is skipped by any button.

What you should see (simulator, embedded ROM): the Snouty splash, then the embedded ROM's screen, 144 Game Boy lines squeezed
to the badge's 128 rows by dropping every ninth line, in DMG green, with the
debug overlay in the top-left corner:

```
avg NNNN max NNNNus     step_frame time, average and maximum over 60 frames
fps NN pool NNK         frames per second over 60 frames, page-store KB in use
kf NN D                 keyframes held, ROM source (D drive, E embedded)
```

In wasm the upstream `micros_since_boot` is a stub that adds 1000 on every
call, so the simulator always shows `avg 1000 max 1000us` and `fps 500`. Only
the numbers on the badge mean anything.

Upstream simulator quirks (current sycl-badge `main`) and how the cart copes,
all in `cart/src/main.zig` and compiled only into the wasm:

- The simulator shows a fixed region of wasm memory (address 0x20), not the
  cart API's framebuffer, so `present_wasm()` copies each frame there.
- Buttons are written to 0x04, which the cart API no longer reads, so
  `read_controls()` reads that address itself.
- The simulator's compositor swaps red and blue relative to the cart API, so
  `present_wasm()` pre-swaps while copying (`sim_swap_rb`). If the DMG green
  ever looks teal-blue, that swap and the simulator have gotten out of step.

## 7. Headless preview (no browser)

```sh
node ../../tools/preview.mjs ../../zig-out/bin/snouty-boy.wasm --frames 60 --every 10 --out out/
python3 ../../tools/make_gif.py out/ preview.gif --scale 3 --ms 166
```

`preview.mjs` runs `start()` and then `update()` N times, writing every K-th
frame to `out/frame_XXXX.png` (160x128) and metadata to `out/frames.json`.
Useful options (the header of the shared `../../tools/preview.mjs` has the full list):

- `--press A:30-31,UP:60-99,START:300-301`: hold buttons during those update
  ranges (inclusive). Buttons are `A B START SELECT UP DOWN LEFT RIGHT`;
  `CLICK` is refused.
- `--script FILE.json`: `[{ "from": 60, "to": 99, "hold": ["A", "UP"] }]`.
- `--dump-exports NAME,...`: call zero-argument exports after the last
  update and record them. This cart exports:
  - `debug_frame_count`: frames stepped since reset (`gb.frame_count`)
  - `debug_lines`: lines the core emitted in the last frame (128 with the
    LCD on, 0 with it off)
  - `debug_step_us`: the last `step_frame` time (always 1000 in wasm)
  - `debug_palette`: the current palette index (DMG mode)
  - `debug_state`: frontend state, 0 splash, 1 running, 2 menu, 3 ROM
    picker (badge only), 4 halted (fewer than 2 keyframes fit)
  - `debug_pad`: the pad byte the game was last stepped with
    (Select = 64, Start = 128)
  - `debug_scrub_depth`: frames the scrubber is parked behind live (0 live)
  - `debug_history`: frames of history in the keyframe ring
  - `debug_keyframes`: valid keyframes in the ring
  - `debug_pool_bytes`: page-store pool bytes in use
  - `debug_cgb`: 1 when the ROM runs in CGB mode
  - `debug_leds`, `debug_led_max`: neopixels lit, largest channel value;
    both must be 0 in the default build (with `-Dneopixels=true` the menu
    lights up to 5, channel at most 10)
  - `debug_alarm`: 1 if the rewind self-check found a mismatch
  - `debug_tone_hz`: what the buzzer was last told to play, 0 when stopped
  - `debug_slots`: keyframes the store can hold at most for this ROM
    (wasm: a static 256 KB arena)
  - `debug_arena_bytes`: bytes of that arena
  - `debug_rom_source`: 0 embedded, 1 drive (always 0 in wasm)
  - `debug_rom_size`, `debug_rom_crc`: size and CRC32 of the running ROM,
    as on the About screen
  Exports that read the console return 0 while the ROM picker is up.
- `--expect "debug_lines == 128"` (repeatable): checked at the end; a
  failure exits 3. `--at "T NAME OP VALUE"` checks right after update T.
- `--quiet`: no PNGs, only `frames.json`.

A quick smoke test:

```sh
node ../../tools/preview.mjs ../../zig-out/bin/snouty-boy.wasm --frames 132 --quiet --out out/ \
  --expect "debug_frame_count == 60" --expect "debug_lines == 128"
```

The first 72 updates are the boot splash, during which the core is not
stepped, hence 132 updates for 60 Game Boy frames.

A scrubber check with 2048-gb (start the game, play, hold Select for the
menu, step back twice, resume):

```sh
node ../../tools/preview.mjs ../../zig-out/bin/snouty-boy.wasm --frames 380 --every 10 --out out/ \
  --press START:150-152,LEFT:170-175,UP:190-195,SELECT:260-300,LEFT:310-310,LEFT:320-320,B:340-341 \
  --at "310 debug_scrub_depth == 7" --at "320 debug_frame_count == 180" \
  --at "330 debug_leds == 0" --at "330 debug_led_max == 0" --at "379 debug_frame_count > 200"
```

Exit codes: 1 the cart cannot be loaded, 2 usage error, 3 the cart trapped or
an expectation failed. One update is one 60 Hz badge frame, which is one Game
Boy frame.

## 8. Flash the badge

Install it as in [docs/INSTALL.md](../../../docs/INSTALL.md) (the badge's
`SYCLBADGE` drive, not the RP2350 bootloader): copy
`zig-out/firmware/snouty-boy.uf2` (repository root) onto the drive, copy
any `.gb`/`.gbc` files next to it (section 9), eject, and start Snouty Boy
from the OS menu.

An XIP build (`-Dcart-mode=xip`, section 4) is `snouty-boy-xip.uf2`;
install that one instead (XIP launch is still unproven on hardware). It is
only needed for a `-Drom-source=embed` ROM above about 64 KB.

On the badge the overlay's numbers are real: `avg`/`max` are the
microseconds `gb.step_frame` takes per Game Boy frame (M1 target under
14,000, SPEC.md section 8, goal 8,000), and `fps` should read 60.

## 9. ROMs from the badge drive

Since M5 the badge build (`-Drom-source=drive`, the default) looks for Game
Boy and Game Boy Color ROM files on the badge's own USB drive and reads the chosen one in
place from flash, so the ROM costs no cart RAM and may be up to 1 MB.
Since 2026-10-04 that build embeds no ROM at all (the UF2 is about 200 KB
instead of 266 KB; a UF2 costs twice its payload on the 1280 KB drive, so
this leaves room for a bigger game).
Design and its open questions: `docs/ROM_DRIVE.md` at the repository root;
SPEC.md section 11.1.

1. Mount the badge drive (section 8) and copy `snouty-boy.uf2` onto it if
   it is not there yet.
2. Copy one or more `.gb` or `.gbc` files onto the drive,
   next to `snouty-boy.uf2`, in the top directory. For best speed copy them
   onto a freshly wiped drive so each file is contiguous.
3. **Eject the drive** before playing: the OS may write flash while a host
   still has it mounted, and the cart reads the file from that flash.
4. Run Snouty Boy from the OS menu.

What happens:

- One playable file: it starts after the splash.
- Several: a picker follows the splash, listing up to 8 files with their
  size. Files that cannot be played are dimmed with the reason under the
  list ("too small", "over 1 MB", "bad checksum" for the header checksum at
  0x14D, or the drive error). Playable files may carry hints: "Color" (the
  header asks for a Game Boy Color, so it runs in CGB mode, M8), "no RTC"
  (MBC3 clock not emulated), "mapper?" (a mapper the core does not know),
  "RAM>32K" (cart RAM over 32 KB is cut). Up/Down move, A plays; the only
  way out without playing is the OS menu (Start+Select).
- None, no readable drive, nothing playable, or a file that cannot be
  mapped: a screen right after start says "No ROM on the badge drive.",
  "Copy a .gb or .gbc file to the drive, eject, then restart this cart."
  and "Why: <reason>" ("no ROM file", "none playable", "NoVolume" for an
  unformatted drive, ...). It stays up; Start+Select leaves (the
  frontend state is `halted`, as for "Not enough RAM").

Menu > About shows the ROM's header title, mapper and size, "Source:
drive" with the file name (cut to 18 characters) or "Source: embedded"
with the embedded file's name (simulator and `-Drom-source=embed`), its
CRC32 and the model (DMG or CGB); "Fragmented: N" replaces "Source: drive"
when N banks of a drive file are not contiguous (those banks go through a
slower per-sector path).
The debug overlay's third line is the keyframe count and `D` (drive) or
`E` (embedded).

The ROM file also shows in the OS cart menu, where picking it fails to load;
that is cosmetic. Cart RAM (saves) is not kept between runs.

Build options: `-Drom-source=embed` builds the pre-M5 behaviour (the drive
is never looked at, `-Drom=...` picks the ROM built in). The web
simulator and `preview.mjs` always run the embedded ROM, so the drive path
is only exercised on the badge and in badge-bench (9.1). An embedded ROM
above about 64 KB needs `-Dcart-mode=xip` (section 4); flash
`snouty-boy-xip.uf2` then (section 8).

### 9.1 Exercising the drive path without a badge (badge-bench)

badge-bench maps a drive image at the romfs address with `--romfs` (Snouty
Gear M0 added it together with `tools/make_romfs.py`). A drive build needs the option in the
bench: without an image the region is unmapped and the bench reports a read
fault in `romfs.geometry` during start-up. On the badge the flash is always
there, so this is a bench artefact, not a cart bug; `-Drom-source=embed`
builds bench without it.

```
# one contiguous ROM, and two ROMs stored in 8-cluster runs (fragmented)
python3 tools/make_romfs.py out/one.img carts/snouty-boy/roms/2048.gb=2048.gb
python3 tools/make_romfs.py out/two.img carts/snouty-boy/roms/2048.gb=2048-gb.gb \
    carts/snouty-boy/tests/roms/cpu_instrs.gb="Blargg cpu_instrs.gb" --fragment 8
python3 tools/make_romfs.py --list out/two.img
cd badge-bench
./bench.sh ../zig-out/firmware/snouty-boy.elf --romfs ../out/one.img --frames 300 --png 60 --out ../out/one \
    --press START:30-31,START:120-121,SELECT:200-240
./bench.sh ../zig-out/firmware/snouty-boy.elf --romfs ../out/two.img --frames 300 --png 10 --out ../out/two \
    --press START:30-31,A:60-61,START:120-121,SELECT:180-220,DOWN:230-231,DOWN:235-236,DOWN:240-241,DOWN:245-246,DOWN:250-251,DOWN:255-256,A:265-266
```

The first run's frame 180 shows 2048 with the overlay line `kf N D` (M5
showed `slots 6 D`, its pool form); the
second shows the picker at frame 50 (`docs/m5_picker.png`) and the About
screen at frame 280 (`docs/m5_about.png`: Source drive, CRC 4380CC7A, which
is `zlib.crc32` of `roms/2048.gb`, "fragmented: 2 banks", since
2026-10-04 "Fragmented: 2"). Picking the
second file (`--press START:30-31,DOWN:45-46,A:60-61`) runs Blargg's
`cpu_instrs` from a fragmented 64 KB MBC1 file through the per-sector path.
This was done on 2026-09-29 in a scratch merge of M5 with `gear/m0`; the
numbers above are from that build. M8 benches the Color ROMs the same way
(PLAN.md M8 status, `badge-bench/carts/snouty-boy-color.toml`).

An empty drive (`python3 tools/make_romfs.py out/empty.img`, no files) or
an all-0xFF image (unformatted) shows the no-ROM screen from the first
frame (`--frames 60 --png 30`; "Why: no ROM file" / "Why: NoVolume").

Still open on hardware (docs/ROM_DRIVE.md section 6): that reading a file
by pointer through the XIP flash window works and is fast enough (FPS with
the ROM in flash, cache misses on bank reads; the bench models flash loads
as zero-wait unless `--flash-read-cycles N` is given), how long finding and
mapping takes at start (the bench's modelled start-up is 1.5 ms with one
file), and that the drive still mounts and the OS menu still works with ROM
files on it.
