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
`../../docs/RUNNING.md` at the repository root. Until the `monorepo` branch
is on GitHub it lives on the exe.dev VM:

```sh
git clone -b monorepo exedev@animated-badge.exe.xyz:/home/exedev/snouty-badge
cd snouty-badge && git submodule update --init
cd carts/snouty-boy
```

Milestones are annotated tags (`git tag -n1 'snouty-boy/*'`: `snouty-boy/m1`,
`/m3`, `/m4`); work in progress is on `m<N>-*` branches.

## 3. Test ROMs

The emulator embeds one Game Boy ROM at build time; the default is
`tests/roms/dmg-acid2.gb`. The test ROMs are freely redistributable but not
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

- `-Drom=path/to/game.gb`: the ROM to embed (default
  `tests/roms/dmg-acid2.gb`, falling back to `roms/2048.gb`). The path is
  relative to the repository root, e.g. `-Drom=carts/snouty-boy/roms/2048.gb`;
  a path relative to this cart such as `-Drom=roms/2048.gb` also works. The
  shipped game goes in `roms/` with its license next to it.
- `-Dcart-optimize=fast|small|safe|debug`: optimize mode for the cart
  (default `fast`, SPEC.md section 8).
- `-Drom-source=drive|embed`: where the badge build gets its ROM (default
  `drive`: a file on the badge's USB drive, the embedded ROM as fallback;
  `embed`: the embedded ROM only, as before M5). See section 9. The wasm
  build always runs the embedded ROM. `pack` belongs to Snouty Gear and is
  refused here.

A clean build of this cart takes a couple of minutes (all carts: several);
incremental rebuilds take seconds.
`size ../../zig-out/firmware/snouty-boy.elf` shows `.text` (code plus the embedded
ROM), `.data` and `.bss` against the cart RAM budget in SPEC.md section 13.
The keyframe pool is not in any of them: at `start()` the cart takes the RAM
between the end of `.bss` and the stack (less 1 KB), so the number of
keyframe slots on the badge is `(0x20078000 - 1024 - align8(end of .bss)) /
slot size`, capped at 12, and shows in the debug overlay's third line.

## 5. Host tests

From the repository root:

```sh
zig build test                        # all core tests, natively (and every other cart's host tests)
zig build test -Dtest-filter=acid     # only tests whose name contains "acid"
```

The core (`core/`) is badge-agnostic and runs on the host: Blargg's CPU tests
(pass when the serial output says "Passed"), the dmg-acid2 image compared
byte for byte with `tests/acid2_reference.bin`, PPU and APU unit tests, the
scrubber ring logic (`tests/ring_unit.zig`) and the determinism check. They
need `tools/fetch_test_roms.sh` first.

`tests/determinism.zig` (SPEC.md 10.2, `-Dtest-filter=determinism`) reads
`roms/2048.gb` at run time (skipped if it is missing), plays 600 frames with
a scripted pseudo-random pad stream, keyframes every 30 frames, then for
each keyframe restores it into a fresh console, replays the 30 logged pads
and requires the next keyframe field for field. Keyframes are compared
with `std.meta.eql` per field, not as raw bytes: the struct has auto layout
and its padding is undefined.

The same check can run inside the cart: set `const self_check = true;` in
`cart/src/frontend/rewind.zig` and rebuild. Every new keyframe is then
re-derived from the previous one in a spare console; a mismatch paints the
debug overlay red (and `debug_alarm` reads 1). It costs a second console
in RAM (the ring shrinks to 5 keyframes) and doubles the CPU per frame, so
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

Keys (from `sycl-badge/simulator/README.md`) and what they do here:

| Keyboard           | Badge          | Game Boy / emulator                         |
|--------------------|----------------|---------------------------------------------|
| Arrow keys or WASD | Joystick       | D-pad                                       |
| Z or K             | A              | A                                           |
| X or J             | B              | B                                           |
| Enter or Y         | Start          | Start                                       |
| Backspace or T     | Select, tap    | Select, delivered on release (3 frames)     |
| Backspace or T     | Select, hold 0.5 s | opens the emulator menu, game paused    |
| Shift              | Joystick click | nothing (the OS owns it)                    |
| Escape             | System menu    | leaves the cart                             |

Select is never passed straight through (SPEC.md section 5): while it is
held the game sees nothing; released within 500 ms (30 frames) the game gets
a short Select press; held 500 ms, the emulator menu opens instead. Holding
Start and Select together for 250 ms exits the cart on the badge (the OS
owns that chord), so Game Boy soft-reset combos do not work; Start pressed
during a Select hold cancels both the tap and the menu.

In the menu (drawn over the frozen game frame):

| Key            | Action                                                     |
|----------------|------------------------------------------------------------|
| Up / Down      | move                                                       |
| A              | choose: Resume, cycle Palette / Scale / Sound / Debug overlay, Reset (restart the ROM), About |
| Left / Right   | on Palette / Scale / Sound / Debug overlay: cycle it. On Resume, Reset, About: time scrubber, back / forward 0.5 s (repeats 4 times a second while held) |
| B, Select tap  | resume (B also leaves About)                               |

Time scrubber (SPEC.md section 10). The cart keeps a keyframe of the whole
console every 30 frames plus the pad byte of every frame. With 2048-gb the
ring holds 7 keyframes, 3.0 to 3.5 s of history. The menu opens on Resume,
so Left right away steps back: the menu folds into a bar at the bottom
(`Scrub: -1.5 / 3.5s`, how far back you are / how much history there is)
over the restored frame. Left/Right keep stepping, Right past the newest
keyframe returns to `live`, Up/Down/A bring the full menu back, and B or a
Select tap resumes play from the shown point. Resuming from a scrubbed
point throws away the future after it (no branching history). In the full
menu the bottom line shows the same readout. While the menu is open the
five neopixels show how full the history is, one LED per fifth (dim, every
channel at most 10/255); they go off when the menu closes. Reset in the
menu also clears the history.

The picture shown after a step is the frame the game drew 1/60 s after the
keyframe (the cart steps one frame to draw it and restores the keyframe
again), so the state you resume from is exactly the keyframe.

Buttons still held when the menu closes (or the splash is skipped) reach
the game only after being released and pressed again. The boot splash
(1.2 s) is skipped by any button.

What you should see: the Snouty splash, then the embedded ROM's screen, 144 Game Boy lines squeezed
to the badge's 128 rows by dropping every ninth line, in DMG green, with the
debug overlay in the top-left corner:

```
avg NNNN max NNNNus     step_frame time, average and maximum over 60 frames
fps NN                  frames per second over 60 frames
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
  - `debug_lines`: lines the core emitted in the last frame (144 with the
    LCD on, 0 with it off)
  - `debug_step_us`: the last `step_frame` time (always 1000 in wasm)
  - `debug_palette`: the current palette index
  - `debug_state`: frontend state, 0 splash, 1 running, 2 menu, 3 ROM
    picker (badge only), 4 halted (fewer than 2 keyframe slots fit)
  - `debug_pad`: the pad byte the game was last stepped with
    (Select = 64, Start = 128)
  - `debug_scrub_depth`: frames the scrubber is parked behind live (0 live)
  - `debug_history`: frames of history in the keyframe ring
  - `debug_keyframes`: valid keyframes in the ring
  - `debug_leds`, `debug_led_max`: neopixels lit, largest channel value
  - `debug_alarm`: 1 if the rewind self-check found a mismatch
  - `debug_slots`: keyframe slots the pool holds for this ROM (wasm: a
    static 160 KB pool; 8 with 2048-gb)
  - `debug_rom_source`: 0 embedded, 1 drive (always 0 in wasm)
  - `debug_rom_size`, `debug_rom_crc`: size and CRC32 of the running ROM,
    as on the About screen
  Exports that read the console return 0 while the ROM picker is up.
- `--expect "debug_lines == 144"` (repeatable): checked at the end; a
  failure exits 3. `--at "T NAME OP VALUE"` checks right after update T.
- `--quiet`: no PNGs, only `frames.json`.

A quick smoke test:

```sh
node ../../tools/preview.mjs ../../zig-out/bin/snouty-boy.wasm --frames 132 --quiet --out out/ \
  --expect "debug_frame_count == 60" --expect "debug_lines == 144"
```

The first 72 updates are the boot splash, during which the core is not
stepped, hence 132 updates for 60 Game Boy frames.

A scrubber check with 2048-gb (start the game, play, hold Select for the
menu, step back twice, resume):

```sh
node ../../tools/preview.mjs ../../zig-out/bin/snouty-boy.wasm --frames 380 --every 10 --out out/ \
  --press START:150-152,LEFT:170-175,UP:190-195,SELECT:260-300,LEFT:310-310,LEFT:320-320,B:340-341 \
  --at "310 debug_scrub_depth == 7" --at "320 debug_frame_count == 180" \
  --at "330 debug_leds == 5" --at "379 debug_frame_count > 200"
```

Exit codes: 1 the cart cannot be loaded, 2 usage error, 3 the cart trapped or
an expectation failed. One update is one 60 Hz badge frame, which is one Game
Boy frame.

## 8. Flash the badge

Carts go onto the badge's own USB drive; this is not the RP2350 bootloader
(from the sycl-badge README "Flash a UF2 to the Badge" and the user manual,
<https://zigembeddedgroup.github.io/sycl-badge/>):

1. Plug the badge into your computer over USB-C and switch it on. It mounts
   as a mass-storage drive named `SYCLBADGE`.
2. Copy `zig-out/firmware/snouty-boy.uf2` (repository root) onto the drive, replacing
   `CURRENT.UF2`. The badge shows a progress indicator while it copies.
3. The cart starts when the copy finishes.

Holding the `RESET` and `BOOT_SEL` buttons (releasing `RESET` first) mounts
the RP2350 bootloader drive instead; that is for flashing the badge OS
(`sycl-os-kernel.uf2`), not carts.

On the badge the overlay's numbers are real: `avg`/`max` are the
microseconds `gb.step_frame` takes per Game Boy frame (M1 target under
14,000, SPEC.md section 8, goal 8,000), and `fps` should read 60.

## 9. ROMs from the badge drive

Since M5 the badge build (`-Drom-source=drive`, the default) looks for Game
Boy ROM files on the badge's own USB drive and reads the chosen one in
place from flash, so the ROM costs no cart RAM and may be up to 1 MB.
Design and its open questions: `docs/ROM_DRIVE.md` at the repository root;
SPEC.md section 11.1.

1. Mount the badge drive (section 8) and copy `snouty-boy.uf2` onto it if
   it is not there yet.
2. Copy one or more `.gb` (or DMG-compatible `.gbc`) files onto the drive,
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
  0x14D, or the drive error). Playable files may carry hints: "CGB only"
  (a Game Boy Color game; this is a DMG, it may not run), "no RTC" (MBC3
  clock not emulated), "mapper?" (a mapper the core does not know), "RAM>8K"
  (cart RAM over 8 KB is cut). Up/Down move, A plays, B runs the embedded
  ROM.
- None, no readable drive, or a file that cannot be mapped: the embedded
  ROM (`-Drom`, `roms/2048.gb` or the acid2 test ROM) runs, as before.

Menu > About shows the ROM's header title, mapper and size, "Source:
drive" with the file name (cut to 18 characters) or "Source: embedded"
with the embedded file's name, its CRC32, "fragmented: N banks" when a
drive file is not contiguous (those banks go through a slower per-sector
path), and "drive: <reason>" when the drive was tried and the embedded ROM
runs instead. The debug overlay's third line is the keyframe slot count and
`D` (drive) or `E` (embedded).

The ROM file also shows in the OS cart menu, where picking it fails to load;
that is cosmetic. Cart RAM (saves) is not kept between runs.

Build options: `-Drom-source=embed` builds the pre-M5 behaviour (the drive
is never looked at); `-Drom=...` still picks the fallback ROM. The web
simulator and `preview.mjs` always run the embedded ROM, so the drive path
is only exercised on the badge (and, once it gains a `--romfs` option, in
badge-bench).

Still open on hardware (docs/ROM_DRIVE.md section 6): until the Snouty Gear
branch lands the real FAT12 reader in `lib/romfs.zig`, the badge build finds
no volume and About reads "drive: NoVolume". After that: that reading a
file by pointer through the XIP flash window works and is fast enough (FPS
with the ROM in flash, cache misses on bank reads), how long finding and
mapping takes at start, and that the drive still mounts and the OS menu
still works with ROM files on it.
