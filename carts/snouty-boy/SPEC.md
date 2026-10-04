# Snouty Boy: Game Boy emulator cart spec

Owner: Adrian Hatch (Antithesis). Target: SYCL Badge V2, 160x128 RGB565, 60 Hz.
Fifth cart for the badge, alongside `snouty-badge` (running Snouty),
`snouty-bugs` (bullet hell), `snoutenstein` (raycaster) and
`snouty-reflections` (ray tracer). Working title; decisions are in section 18.
Status and milestones are at the bottom.

## 1. One paragraph

A full-speed Game Boy (DMG) emulator written in Zig, with one homebrew ROM
baked into the cart. The badge is almost a Game Boy already: the screen is
160 pixels wide, the buttons are Start, Select, A, B and a d-pad, and the
speaker is a single buzzer, so the emulator maps the machine onto the badge
almost one to one. The 144-line Game Boy picture is squeezed to 128 lines by
dropping every ninth scanline. Holding Select opens the emulator's own menu:
palettes, scaling, sound, reset, and the Antithesis feature, a time scrubber.
The emulator snapshots the whole console every half second and logs every
input, so Left steps the game back in time and Right steps it forward again.
Because the emulator is deterministic by construction, a test asserts that
replaying the logged inputs from one snapshot reproduces the next one bit for
bit. The title can honestly say "verified by deterministic replay".

## 2. Hardware facts the design leans on

Checked in `../../sycl-badge` (`src/os/cart/api.zig`, `src/cart/cart_ram.ld`,
`src/os/cart/platform_cart_xip.zig`, `src/os/loader/*`).

- RP2354B, Cortex-M33 at 150 MHz, hardware divide, single-cycle multiply.
  Core 1 runs only the cart. The OS entry wrapper calls `update()` then
  `present()` in a loop; `present()` waits for the previous LCD flush, so
  one `update()` gets essentially a full 16.7 ms.
- Carts are linked with `cart_ram.ld` and copied into RAM by the loader, so
  code, ROM, and state all share cart RAM: `0x20035100..0x20080000`,
  307,456 bytes, of which the last 32 KB is stack. Usable: about 268 KB.
  Running from RAM means no flash stalls in the interpreter loop.
- `read_flash` / `write_flash_page` are no-op stubs on hardware, so there is
  no way to load a ROM at runtime. The ROM is `@embedFile`d. One game per
  cart; the badge menu already switches carts.
- Screen 160x128, framebuffer column-major (`framebuffer[x][y]`), `Pixel`
  is a plain bitcast of RGB565 on hardware and byte-swapped on wasm.
  Palettes are converted to `Pixel` once in `start()`.
- Inputs: joystick 4-way, A, B, Start, Select, exactly the Game Boy pad.
  Start+Select held 250 ms and the joystick click are OS-owned and never
  bound. Consequence: Game Boy soft-reset chords that hold Start+Select
  will exit the cart instead. Documented, not fought.
- Audio: `tone2`, one voice, shapes square/triangle/sawtooth/sine, volume,
  frequency. It cancels whatever was playing. There is no PCM path and no
  mixing, so the four Game Boy channels become one chosen voice (section 9).
- Optimize mode: `add_os_cart` takes `optimize`; the other carts use
  `ReleaseSmall`. The emulator core is the one place `ReleaseFast` may earn
  its size. Measured in M1, decided by the numbers.
- Simulator: the same source builds to wasm32 and runs in the upstream web
  simulator; the core also builds natively for host tests (section 16).

## 3. The machine being emulated

DMG (original Game Boy); Game Boy Color added in section 19 (M6, M7).

- CPU: Sharp SM83, 4.194304 MHz, 1 M-cycle = 4 T-cycles. One frame is
  70,224 T-cycles (17,556 M-cycles) at 59.73 Hz. The emulator runs exactly
  one Game Boy frame per badge frame, so the game runs 0.45 percent fast.
  Nobody can tell, and it keeps frame pacing trivial.
- Memory map: `0000-3FFF` ROM bank 0, `4000-7FFF` switchable ROM bank,
  `8000-9FFF` 8 KB VRAM, `A000-BFFF` cart RAM (0 to 32 KB), `C000-DFFF`
  8 KB WRAM, `E000-FDFF` echo, `FE00-FE9F` OAM, `FF00-FF7F` I/O,
  `FF80-FFFE` HRAM, `FFFF` IE.
- PPU: 154 lines of 456 T-cycles, 144 visible. Per line: mode 2 OAM scan
  (80 T), mode 3 drawing (172 T, fixed), mode 0 HBlank (remainder). Modes
  0, 1, 2 and LY=LYC raise STAT interrupts as enabled. Background 32x32
  tile map with SCX/SCY, window with WX/WY, 40 sprites 8x8 or 8x16, at most
  10 per line, sprite priority and palettes BGP/OBP0/OBP1.
- Timer: 16-bit DIV counter, TIMA/TMA/TAC with the four clock rates and the
  overflow interrupt. Serial: stub that captures bytes (test ROMs print
  through it); an internal-clock transfer completes at once with `0xFF`
  received, an external-clock one (SC=`0x80`) stays pending forever, as on a
  Game Boy with no cable (Tetris and Tetris DX probe the link port this way
  on the title screen and ignore the joypad while a peer seems to answer).
  Joypad register with the interrupt on press.
- Memory bank controllers: none (32 KB), MBC1, MBC3 (no RTC), MBC5,
  selected at reset from header byte `0x147`. Bank switches are rare, so a
  runtime `switch` costs nothing measurable; reads go through a cached bank
  offset. Cart RAM is a fixed 8 KB array (`tools/romcheck.py` rejects ROMs
  that declare more), which keeps the core one concrete type for host tests
  and gives keyframes a fixed size.
- Boot ROM: not emulated. Registers start at post-boot DMG values
  (AF=01B0, BC=0013, DE=00D8, HL=014D, SP=FFFE, PC=0100) and the I/O
  registers are set to their documented post-boot values. Section 12 has
  the badge's own splash in place of the Nintendo logo scroll.

## 4. Accuracy target

Scanline accuracy, not pixel-FIFO accuracy. Rules:

- Instruction-level timing: each instruction advances the machine by its
  M-cycle count; PPU, timer, DMA and APU lengths catch up after every
  instruction. Interrupts are checked between instructions. HALT with the
  HALT bug, STOP treated as HALT.
- The PPU renders a whole line at the moment it enters mode 3, using the
  registers as they are then. Mid-line register changes are not seen.
  This is enough for `dmg-acid2` and for essentially every DMG homebrew.
- OAM DMA copies 160 bytes instantly. Games that read OAM during DMA are
  not a target.
- Must pass: Blargg `cpu_instrs` (all 11), Blargg `instr_timing`,
  `dmg-acid2` (framebuffer compared to the reference image).
  Should pass: Mooneye MBC1 bank tests for the chosen MBC.
  Not attempted: `mem_timing`, sprite FIFO tests, sound tests.

## 5. Controls

Game Boy buttons map straight through. The emulator's own controls live
behind a Select long-hold so that no Game Boy button is stolen.

| Badge            | Game Boy / emulator                                         |
|------------------|-------------------------------------------------------------|
| D-pad            | D-pad                                                       |
| A, B, Start      | A, B, Start                                                 |
| Select, tap      | Select. Delivered to the game on release if held < 500 ms   |
| Select, hold 500 ms | Emulator menu opens; game is paused; Select not delivered |
| In menu: Up/Down | Move; A choose; B or Select-release resume                  |
| In menu: Left    | Step time back 0.5 s (auto-repeat 4/s while held)           |
| In menu: Right   | Step time forward 0.5 s, as far as the log reaches          |

Deferred Select delivery adds latency of up to the release time on one
button that games use for menus and pause, which is acceptable (section 18, item 4).
Menu items: Resume, Palette, Scale (squeeze / crop), Sound (on / off),
Reset, About (version, ROM title from the header, "verified by
deterministic replay").

## 6. Screen mapping

- **Squeeze (default)**: Game Boy line `ly` maps to badge row
  `ly - ly / 9`; lines where `ly % 9 == 8` are not drawn at all
  (16 of 144 lines). The PPU still runs those lines for timing and
  interrupts; it only skips the pixel work, so the squeeze is free.
- **Crop**: lines 8 to 135 drawn to rows 0 to 127; the top and bottom 8
  lines are not drawn. Better for games whose HUD sits in the middle.
- Horizontal: 1:1, all 160 columns.
- The line renderer produces a 160-entry 2-bit color-index buffer plus a
  BG-priority buffer for sprite compositing, then writes RGB565 into the
  column-major framebuffer with stride writes (one 16-bit store per pixel,
  stride 256 bytes). `.no_copy_full_frame` double-buffer mode, whole screen
  marked dirty, as in the other carts.
- Palettes (4 shades each, converted to `Pixel` once): DMG green
  (`0x9BBC0F 0x8BAC0F 0x306230 0x0F380F`), Pocket grey, Light (crisp black
  on white), and a Snouty palette in Antithesis colors. Menu-selectable.

## 7. Core architecture

The core knows nothing about the badge. It imports no `cart-api` and uses
no floats, no allocator, no randomness and no clock: everything comes from
`Gb` state plus the joypad byte fed in per frame. That is what makes it
host-testable and what makes section 10's determinism check meaningful.

```
core/gb.zig       Gb struct; step_frame(joypad) runs 17,556 M-cycles;
                  snapshot(*Keyframe) / restore(*const Keyframe)
core/cpu.zig      SM83 interpreter: registers, decode via switch on opcode
                  (Zig emits a jump table), CB prefix, interrupts, HALT
core/mmu.zig      read8/write8 with fast paths for ROM, VRAM, WRAM, HRAM;
                  I/O dispatch; OAM DMA; MBC specialized at comptime
core/ppu.zig      mode state machine, STAT/LY/LYC, scanline renderer into
                  a 2-bit line buffer, `line_sink` callback to the frontend
core/timer.zig    DIV, TIMA, TMA, TAC
core/apu.zig      register model for ch1 (sweep), ch2, ch3; length counters,
                  envelopes, frame sequencer at 512 Hz; no sample mixing
core/joypad.zig   P1 register, interrupt on press
core/serial.zig   SB/SC stub; captured bytes exposed for tests
core/rom.zig      @embedFile(build option `rom`); comptime header parse
```

Frontend (badge side):

```
cart/src/main.zig          start()/update(); owns Gb, Frontend, Rewind
cart/src/frontend/video.zig   line sink: 2-bit line -> RGB565 columns with
                              the squeeze/crop line map and current palette
cart/src/frontend/audio.zig   APU samples -> the streaming ring; wasm: one voice (section 9)
cart/src/frontend/input.zig   controls -> joypad byte; Select-hold state
                              machine with deferred delivery
cart/src/frontend/menu.zig    overlay menu drawn with api.text/rect
cart/src/frontend/rewind.zig  keyframe ring, input log, scrub (section 10)
cart/src/frontend/splash.zig  boot splash (section 12)
cart/src/frontend/debug.zig   FPS and microseconds overlay (section 14)
```

Frame loop in `update()`: read controls, run the Select state machine, if
not in the menu then `gb.step_frame(joypad)`, log the input, snapshot if
the frame counter hits the keyframe interval, then audio and overlay.

## 8. Performance budget

150 MHz over 16.7 ms is 2.5 M host cycles per badge frame. A Game Boy
frame is 17,556 M-cycles, so the whole emulator has about 140 host cycles
per emulated M-cycle including video. Targets, measured on hardware in M1
with `micros_since_boot` around `step_frame`:

| Part                                   | Target per frame | Host cycles / unit  |
|----------------------------------------|------------------|---------------------|
| CPU interpreter, 17,556 M-cycles       | <= 5.0 ms        | <= 43 per M-cycle   |
| PPU line render, 128 lines x 160 px    | <= 2.0 ms        | <= 15 per pixel     |
| Timer, DMA, APU bookkeeping            | <= 0.5 ms        |                     |
| Frontend (audio, input, overlay)       | <= 0.3 ms        |                     |
| Total                                  | <= 8 ms          | about half a frame  |

M1 ships if the total is under 14 ms; optimization then continues toward
8 ms. Peanut-GB reaches full speed on an RP2040 Cortex-M0+ at 266 MHz,
which has less per-clock throughput than this M33 at 150 MHz, so the
target is grounded. Levers, in order: `ReleaseFast` for the core, tick
batching (catch the PPU up once per instruction, not per M-cycle), direct
array indexing for ROM/WRAM reads, tile-row fetch cached per 8 pixels,
comptime-specialized MBC, and the skipped ninth lines.

## 9. Audio

Rewritten 2026-10-04 (root docs/EMU_SOUND.md, PLAN.md "Sound on the new
firmware"). The show badges run newer upstream firmware, which ignores
`CART_TONE` and plays only a cart-owned ring of 44.1 kHz unsigned 8-bit
mono samples (`lib/stream_audio.zig`). So:

- The core renders all four channels (`core/apu.zig` "Sample generation"):
  squares with duty, sweep and envelope; the wave channel from wave RAM
  with its output level; noise from the 15/7-bit LFSR with its envelope
  and length; DAC enables, NR51 routing and NR50 volume mixed to mono (a
  channel on one side is half as loud as on both); one gain constant
  (`apu.gain`, chosen from Tetris and Tetris DX levels); a first-order
  high-pass at ~27 Hz like the console's output capacitor. Each output
  sample is the mean level over its 95/96-dot bin (box filter). Rendering
  is lazy: pending time is rendered before an APU register write, before
  a frame sequencer step and at the end of the frame. A frame leaves 738
  or 739 samples (738.4: the partial bin carries over) in `Gb.snd.out`,
  `Gb.audio_len` of them; CGB double speed changes nothing (time is dots).
- `Gb.audio_render` (off by default) gates all of it; off, the register
  model runs exactly as before and a sound-off build pays a branch per
  subsystem flush. Render state is not console state: keyframes do not
  hold it, a restore resets it.
- Badge frontend: every stepped frame's samples go through the shared
  `audio_feed` (rate control against the OS's clock, ramp-out when the
  game stops stepping). No `tone2` and no `tone` import on the badge (on
  the new firmware they would overwrite the ring words). On old firmware
  the badge is silent. The boot chime is a 60 ms square burst per note
  through the feed.
- Wasm (simulator, which has no streaming audio): unchanged, one voice
  from `pick_voice` (the loudest of ch1..3, square or triangle) through
  the simulator's `tone` import.
- Menu Sound row, off at boot unless built with `-Dsound=true` (section
  18 item 6). The debug overlay's fourth line shows the ring's queue and
  underrun count while sound is on.

## 10. Time scrubbing (the Antithesis feature)

### 10.1 Model

- A `Keyframe` is the complete console: WRAM 8 KB, VRAM 8 KB, OAM 160 B,
  HRAM 127 B, I/O registers 128 B, CPU/PPU/timer/APU/MBC state about
  256 B, plus cart RAM if the header declares any. About 16.5 KB for a
  32 KB no-RAM game, about 24.5 KB with 8 KB cart RAM.
- Every 30 frames (0.5 s) the frontend snapshots into a ring of N
  keyframes (N from the memory budget, section 13). Every frame the joypad
  byte is appended to an input log ring covering the same span.
- In the menu, Left restores the previous keyframe and Right the next one,
  as long as they are still in the ring. Live play from a restored point
  overwrites the keyframes ahead of it (no branching history).
- No reverse video at full frame rate in this version: rewind is a
  scrubber that steps in half-second increments. Smooth reverse is the
  M5 stretch (restore keyframe k, replay forward rendering every 5th
  frame, roughly 12 fps backwards).

### 10.2 Determinism check

`tests/determinism.zig`: run the shipped ROM with a scripted input stream
for 600 frames taking keyframes every 30; then for each k, restore
keyframe k, replay the 30 logged inputs, and require the resulting state to
equal keyframe k+1 byte for byte. The same check runs in the simulator
build behind a debug flag and paints the overlay red if it ever fails.
This is the sentence the title screen gets to make.

### 10.3 Determinism rules

The core has no `rand`, no clock, no floats, no allocator and no reads of
badge state. The only external input is the joypad byte per frame. Serial
input reads as `0xFF` (internal clock) or never arrives (external clock). Uninitialized memory does not exist: VRAM, WRAM and
cart RAM are zeroed at reset (real hardware is random, homebrew does not
rely on it).

### 10.4 Keyframe compression (only if depth is short)

If the budget gives less than 3 s of history, keyframes are stored as
XOR against the previous keyframe with zero-run RLE. Tile data in VRAM
and most of WRAM change little in half a second, so 3x to 5x is typical.
Restore then walks the chain from the oldest full keyframe; with N <= 12
that is cheap.

## 11. The ROM

The cart ships exactly one ROM. Adrian provides it (decided 2026-09-26);
it is needed by M2, and M1 runs on `dmg-acid2` and the Blargg ROMs.

- Rights: Adrian supplies a ROM he may redistribute. Commercial ROMs never
  enter the repo or the cart. Test ROMs (Blargg, `dmg-acid2`, Mooneye) are
  freely redistributable and fetched by `tools/fetch_test_roms.sh` into
  `tests/roms/` (gitignored).
- What the ROM must be, checked by `tools/romcheck.py` before it is
  accepted: DMG or DMG-compatible (not Color-only), MBC none, MBC1, MBC3
  without RTC use, or MBC5; at most 128 KB, ideally 32 to 64 KB because ROM
  size trades directly against scrub depth (section 13); cart RAM at most
  8 KB. Sizes outside that are possible but shrink the scrubber.
- Alternative for M5: an original Antithesis mini-game built with
  GBDK-2020, starring Snouty, so the emulator runs "our" software.
- Selected via build option `-Drom=roms/<name>.gb`; default is the
  chosen game; `-Drom=tests/roms/dmg-acid2.gb` builds the acid cart.

### 11.1 ROMs from the badge drive (M5, 2026-09-29)

The embedded ROM is the fallback only. On the badge the cart looks for
`.gb`/`.gbc` files on the USB drive (the OS `romfs` FAT12 region of the
internal flash) and reads the chosen one in place through the XIP flash
window, by pointer: nothing is copied into RAM, so the ROM no longer
trades against scrub depth and may be up to 1 MB (64 banks). Shared design
and its open hardware checks: `docs/ROM_DRIVE.md` at the repository root;
the FAT12 reader is `lib/romfs.zig`, shared with Snouty Gear. One file
starts directly, several show a picker after the splash, none (or a
fragmented file's unmappable banks, an unreadable volume) fall back as
described in PLAN.md M5. `-Drom-source=embed` restores the old behaviour;
the web simulator always embeds. Eject the drive before playing: the OS
may write flash while the cart runs. Cart RAM is still not saved between
runs (no flash writes from the cart).

Since M8 (section 19) the drive path and the Color core are one cart: the
picker lists `.gb` and `.gbc` files alike, the header's 0x143 bit 7 picks
the model (a CGB-flagged file plays in colour, the picker marks it
"Color"), and cart RAM up to 32 KB is kept. The embedded alternative stays
for a single-game cart: `-Drom-source=embed -Drom=...`, with
`-Dcart-mode=xip` for ROMs above about 64 KB (section 19.4).

## 12. Boot splash and presentation

- On `start()`: 1.2 s splash where the Antithesis Iris mark (the shared
  1-bit 24x24 bitmap in `lib/iris_mark.zig`, drawn at 2x in the palette's
  darkest shade) scrolls down from the top like the DMG logo, then the two-note DMG-style chime (a square burst through the streaming ring, section 9)
  (1 kHz then 2 kHz, 60 ms each), then the game. Select-hold skips.
- Title bar in the menu: "SNOUTY BOY" in the badge font, the ROM's header
  title, and the tag line "verified by deterministic replay".
- Neopixels: off. The cart never writes a non-zero value to the strip: a
  coworker's badge showed the LEDs are unusably bright even at 1%
  (2026-09-29, docs/NEOPIXELS.md at the repository root). The history
  meter below is compiled out; `-Dneopixels=true` re-enables it for
  development.

### Dormant neopixel meter (behind -Dneopixels)

Built with `-Dneopixels=true`, the five LEDs show how much history is in
the ring while the menu is open (one LED per fifth, every channel at most
10/255, enforced by a compileError in `frontend/menu.zig`) and go off when
it closes. In the default build `set_leds` returns at once.

## 13. Memory budget

Usable cart RAM is about 268 KB (307 KB minus 32 KB stack). Measured with
`size -A` at every milestone.

| Item                                   | Where   | 32 KB game | 64 KB game |
|----------------------------------------|---------|-----------:|-----------:|
| Emulator code + frontend (ReleaseFast) | .text   | ~45 KB     | ~45 KB     |
| ROM                                    | .rodata | 32 KB      | 64 KB      |
| Splash art, fonts, palettes            | .rodata | ~4 KB      | ~4 KB      |
| Live console (WRAM, VRAM, OAM, regs)   | .bss    | 17 KB      | 17 KB      |
| Cart RAM (per header, 0 to 32 KB)      | .bss    | 0          | 8 KB       |
| Line buffers, frontend state           | .bss    | 1 KB       | 1 KB       |
| Input log ring (1 byte per frame)      | .bss    | 1 KB       | 1 KB       |
| Keyframe ring                          | .bss    | remainder  | remainder  |
| Keyframe ring, uncompressed            |         | ~165 KB = 10 x 16.5 KB = 5 s | ~125 KB = 5 x 24.5 KB = 2.5 s |

A 128 KB game leaves about 60 KB for keyframes, so it needs section 10.4
to offer more than 1.5 s of history. That is the reason the ROM should be
small, not any CPU limit.

M5 changes the table: a drive ROM costs no RAM at all (only the 32 KB
embedded fallback still does), the keyframe pool is sized at run time from
the RAM left between `.bss` and the stack, and its slot size follows the
running ROM's cart RAM (0, 2 or 8 KB), so a RAM-less game gets more
keyframes than one with 8 KB of save RAM. Because that pool is no longer
`.bss`, the UF2 shrinks by twice the pool size (RAM-cart UF2s ship their
zero-filled `.bss`, docs/ROM_DRIVE.md section 3), which is drive space for
ROMs. M8 keeps that arena and puts the page store (section 19.3) and the
live console in it; the numbers are in section 19.4.

## 14. Instrumentation

- `debug.zig` overlay (toggled in the menu): FPS, `step_frame`
  microseconds (min/avg/max over 60 frames), keyframes in ring, free
  bss. This is what Adrian reads off the badge for the M1 gate.
- `api.zone` profiling markers around CPU, PPU and frontend for the
  upstream trace tooling, compiled out unless `-Dprofile`.
- Serial capture printed via `api.trace` in the simulator so Blargg output
  is readable in the browser console.

## 15. Tooling and repo layout

Copied from `snouty-bugs`: `build.zig` shape (`add_os_cart` with a
`custom_builder` that adds nothing yet), `build.zig.zon` pointing at
`../../sycl-badge`, `docs/RUNNING.md` structure, `CLAUDE.md`. `preview.mjs`,
`serve-cart.mjs` and `make_gif.py` are the shared ones in `../../tools/`.

```
SPEC.md  PLAN.md  README.md  CLAUDE.md  docs/RUNNING.md
build.zig  build.zig.zon
cart/src/main.zig  cart/src/frontend/*.zig
core/*.zig
tests/{blargg,acid2,determinism}.zig  tests/roms/ (gitignored)
roms/<game>.gb + roms/LICENSE-<game>
tools/fetch_test_roms.sh  tools/romcheck.py  tools/acid2_reference.png
```

New build steps: `zig build` (uf2 + elf + wasm as before), `zig build test`
(native core tests, needs `tests/roms/` fetched), `zig build -Drom=...`.

## 16. Verification

- **Host unit tests** (`zig build test`, native x86_64): Blargg
  `cpu_instrs` and `instr_timing` pass by watching serial output for
  "Passed"; `dmg-acid2` runs 20 frames and its 2-bit framebuffer must
  match `tools/acid2_reference.png` exactly; Mooneye MBC tests for the
  shipped MBC; the determinism check of section 10.2; keyframe
  snapshot/restore round trip.
- **Simulator**: the wasm build in the upstream simulator, keyboard
  controls, used for visual review on Adrian's laptop and for the
  `preview.mjs` GIFs in `docs/`.
- **Hardware**: the M1 gate. Adrian flashes the uf2 and reports FPS and
  the microsecond readout; M2 repeats with the game ROM and the overlay
  off; M4 confirms scrubbing works with the OS-owned chords untouched.

## 17. Milestones

Each milestone: a tag, a GIF in `docs/`, a "pull and run" note. Parallel
tracks go to Opus subagents with disjoint files, as before.

- **M0 Scaffold**: repo from `snouty-bugs`, `-Drom` option, host test
  target, `fetch_test_roms.sh`, `romcheck.py`, ROM candidates verified and
  one chosen, `docs/RUNNING.md`, `PLAN.md`, this spec.
- **M1 Core on hardware** (the risk milestone): CPU, timer, interrupts,
  MMU with the comptime MBC; Blargg `cpu_instrs` and `instr_timing` green
  on host; background-only scanline PPU with the squeeze line map; the
  chosen ROM's title screen on the badge with the debug overlay. Tracks:
  A `core/cpu.zig` + Blargg harness, B `core/{mmu,ppu,timer}.zig` + acid
  harness, C frontend (`video`, `input`, `debug`) + tools + RUNNING.md.
  Gate: Adrian flashes it and reports FPS and microseconds.
- **M2 Playable**: sprites, window, OAM DMA, joypad, cart RAM,
  `dmg-acid2` exact match, both scale modes, the game playable start to
  finish at 60 fps with the overlay off. Optimization pass to the section
  8 budget.
- **M3 Frontend**: Select-hold state machine, menu, palettes, sound
  approximation, boot splash, reset, About screen.
- **M4 Scrub**: keyframe ring, input log, Left/Right stepping, neopixel
  history meter (now dormant behind `-Dneopixels`, section 12),
  `tests/determinism.zig`, in-cart determinism assertion,
  keyframe compression if the depth is under 3 s.
- **M5 Stretch** (pick with Adrian): original GBDK Snouty ROM, several
  small ROMs in one cart with a picker, smooth reverse playback, Game Boy
  Color.

## 18. Decisions

Decided 2026-09-26. Adrian asked for the recommendation on every point
except the ROM, which he will provide.

1. Name: "Snouty Boy" stays as the working title and repo name until the
   remote is created.
2. ROM: Adrian provides it; section 11 lists what it must be. Until then
   development runs on `dmg-acid2` and the Blargg ROMs.
3. Default scale mode: squeeze (every ninth line dropped). Crop stays in
   the menu.
4. Menu key: Select held 500 ms, with short presses delivered to the game
   on release, as spec'd in section 5.
5. Scrub depth: build the keyframe ring uncompressed in M4, measure the
   depth with the real ROM, add section 10.4 compression only if it is
   under 3 s.
6. Sound approximation toggled in the menu; the default comes from
   `-Dsound` (off since 2026-09-30, root docs/SOUND.md; it was on).
7. Keyframes every 30 frames (0.5 s steps).
8. Game Boy Color out of scope; M5 stretch at most. Reopened 2026-09-29:
   Adrian asked for the Color upgrade, designed in section 19.
9. Tag line "verified by deterministic replay" on the menu title: yes.

Added 2026-09-29 (M5, Adrian asked for the drive loader planned for Snouty
Gear; recommendations taken without a separate round):

10. ROM source on the badge: drive first, embedded fallback; the picker
    appears only with more than one playable file.
11. Fragmented drive files are played through the per-sector slow path
    with a hint on the About screen rather than refused.
12. Keyframe pool outside `.bss`, sized at run time; slot count at most 12.
    Since M8 the page store (section 19.3) takes its place in the same
    arena, together with the live console, at most 64 keyframes.
13. (M8, 2026-09-29) One cart for both: M5's drive loader and `core.Rom`
    bank table, M6/M7's Color core and page store (PLAN.md M8).

## 19. Game Boy Color (M6, M7; added 2026-09-29)

Adrian asked on 2026-09-29 for Snouty Boy to emulate the Game Boy Color.
It is an upgrade of this cart, not a new one: one core with a model
switch, the DMG path unchanged (Blargg, dmg-acid2 and determinism stay
green and byte exact), and CGB-flagged ROMs (header 0x143 bit 7) booting
in CGB mode.

### 19.1 What CGB adds, and how the core models it

| Feature | Hardware | Core |
|---|---|---|
| Model | CGB boot ROM leaves A = 0x11 (how games detect it) | `Model` enum, argument of `Gb.init`; `default_model(rom)` from 0x143. Tests force either model (Blargg ROMs are flagged 0x80). DMG games run as a DMG, no CGB compatibility palettes. |
| VRAM | 2 x 8 KB, VBK 0xFF4F | `vram: [0x4000]u8`, cached `banks.vram_off` |
| WRAM | 8 x 4 KB, SVBK 0xFF70 (0 means 1) | `wram: [0x8000]u8`, cached `banks.wram_off` for D000; C000 is always bank 0. DMG mode keeps the offset at 0x1000 so the fast path has no model branch. |
| Palettes | 8 BG + 8 OBJ palettes x 4 colours RGB555, BCPS/BCPD/OCPS/OCPD 0xFF68..6B, auto-increment | 64 + 64 bytes in `Ppu`; any write sets `Gb.pal_dirty` (outside the keyframe state) |
| BG attributes | VRAM bank 1 map byte: palette, tile bank, X/Y flip, BG priority | PPU line renderer |
| OBJ | attribute bits 0..2 palette, bit 3 tile bank; priority by OAM order (OPRI 0xFF6C) | PPU |
| LCDC.0 | BG/window master priority instead of BG enable | PPU, CGB mode only |
| Double speed | KEY1 0xFF4D + STOP; CPU, timer, DIV, serial twice as fast; PPU, APU, HDMA not | `Gb.dot_shift` (2 normal, 1 double): `tick(m)` gives the PPU and APU `m << dot_shift` dots; the frame loop counts dots |
| GDMA / HDMA | 0xFF51..55: general DMA stalls the CPU, HBlank DMA copies 16 bytes per HBlank | `mmu.Hdma` state; stalls add to `Gb.stall_m`, which the frame loop ticks away after the instruction; the PPU calls `mmu.hdma_hblank` on entering mode 0 of lines 0..143 |
| Cart RAM | CGB games often 32 KB (MBC5, 4 banks) | `cart_ram: []u8`, a buffer the owner sizes from the header (`mmu.cart_ram_len`, now up to 32 KB); banked through `ram_bank_offset` |
| Misc | FF72..75 plain registers, FF76/77 PCM read 0, RP 0xFF56 reads 0xFF | stored, no effect |

Not in scope: DMG-on-CGB compatibility palettes, the CGB boot ROM, IR,
MBC3 RTC, accurate STOP/speed-switch timing beyond the documented 2050
M-cycle pause, pixel-FIFO timing (still scanline accuracy, section 4).

### 19.2 Line format

`LineSink` keeps its signature. In DMG mode a pixel byte is a shade 0..3 as
before. In CGB mode it is a colour index: `pal * 4 + colour` for BG
(0..31) and `32 + pal * 4 + colour` for OBJ (32..63). The frontend's
256-entry `lut` is already indexed by that byte, so the store loop does not
change: in CGB mode `lut[0..64]` is rebuilt from palette RAM (RGB555 to the
badge's RGB565) whenever `gb.pal_dirty` is set, checked once per line, so
games that rewrite palettes in HBlank still show every colour. A menu item
chooses raw colours or a GBC-LCD colour correction; both are just LUT
builders.

### 19.3 Keyframes: page store

A CGB console is about 57 KB of state (VRAM 16 KB, WRAM 32 KB, cart RAM up
to 32 KB, the rest under 1.5 KB), three times a DMG one, so the fixed ring
of whole keyframes (section 10) holds one or two slots. M7 replaces the
slots with a page store (`core/kstore.zig`, host tested):

- The state is a list of byte regions: VRAM, WRAM, cart RAM and `Small`
  (every other snapshotted field, packed into a zero-initialised struct so
  padding is deterministic). Each region is cut into pages of
  `page_size` bytes (default 512).
- A keyframe is a table of page references. On snapshot each page is
  compared with the same page of the previous keyframe: equal means share
  it (reference count + 1), all-zero means the shared zero page, anything
  else takes a page from the pool and copies it.
- When the pool is exhausted the oldest keyframe is dropped until the new
  one fits; the ring (`core/ring.zig`) gains that eviction and a runtime
  count, so depth adapts to how much the game changes. If not even the new
  keyframe fits alone, the history is empty until the next one that does.
- The store's memory is handed in at run time (`Store.init`, M8): the
  frontend lays it out in the arena of section 19.4.
- Restore copies every page back (about 57 KB of `memcpy`, well under a
  millisecond). Snapshot compares about 57 KB against the previous
  keyframe. Both costs are flat, so no worst-case spike.
- DMG mode gets the same store: banks the game never touches are zero
  pages and cost only their table entries, so 2048-gb's history gets longer.

Section 10.4 (XOR + RLE) is superseded: a page store has no chain to walk
on restore and needs no decompression buffer.

### 19.4 Memory budget (M8: the run-time arena)

The RAM window is 307 KB, 32 KB of it stack. `.text`/`.rodata` (code, and
in a RAM build the embedded ROM) and a small `.bss` come first; everything
else up to the stack, minus a 1 KB guard, is the arena that
`frontend/rewind.zig` lays out once the ROM is chosen: the live console
(`Gb`, 50.4 KB, mostly VRAM and WRAM), its cart RAM (0 to 32 KB, per the
header), then the page store. The store's keyframe count is split from what
is left like the M7 budget did: per keyframe its table (2 bytes per page)
plus `typical_pages_per_keyframe` (8) pool pages, at most 64 keyframes;
the pool gets the rest. Comptime only knows the maxima, nothing depends on
the embedded ROM's size, and the arena is not `.bss`, so the UF2 does not
ship it as zeros.

| Build (fast, 2026-09-29) | .text | .bss | Arena | 2048-gb (2 KB RAM) | Rex Runner (8 KB) | Rebound (0) |
|---|---:|---:|---:|---|---|---|
| default: drive, 32 KB fallback embedded, RAM | 115 KB | 18 KB | 136 KB | 19 kf, 80 KB pool | 18 kf, 74 KB | 20 kf, 82 KB |
| `embed` rex-runner, RAM | 107 KB | 4 KB | 158 KB | - | 23 kf, 95 KB | - |
| `embed` rebound, XIP (code + ROM in flash) | flash | 4 KB | 262 KB | - | - | 50 kf, 202 KB |

The first keyframe pays for every non-zero page (typically 15 to 30 KB);
later ones pay only for pages that changed in 0.5 s (typically 2 to 8 KB).
An 80 KB pool is therefore about 10 to 20 keyframes, 5 to 10 s. A ROM
embedded in a RAM build costs its size in arena: above about 64 KB use the
XIP cart. `layout` refuses (the `halted` screen) when two keyframe tables
and half a keyframe with every page non-zero do not fit; a game with 32 KB
of cart RAM still fits the default build (12 keyframes, 48 KB pool).

### 19.5 Performance

Double speed doubles CPU work per frame; the PPU work is the same plus
attribute fetches. Anchor (badge-bench, calibrated, 2048-gb DMG):
5.04 ms mean / 11.41 ms worst of 16.7 ms. Target for the shipped Color ROM
under the calibrated model: mean <= 10 ms, worst <= 13.4 ms (80% of the
frame, headroom per Adrian's tuning policy). Knobs, in one place in the
frontend: auto frame skip (render lines only every other frame when the
previous frame ran over a threshold; the core still runs every frame, so
determinism is untouched), `page_size`, pool size, keyframe interval.

### 19.6 Tests

- cgb-acid2 byte exact against a committed reference made by a host tool
  (no comptime image decoding, see CLAUDE.md), compared as RGB555.
- Blargg cpu_instrs and instr_timing in both models (instr_timing at
  normal speed).
- Mooneye CGB-relevant tests where they are small and headless.
- Unit tests: VRAM/WRAM banking, palette auto-increment, GDMA length and
  stall, HBlank DMA 16 bytes per line, speed switch halves the PPU dots per
  CPU M-cycle, OPRI/OAM-order priority, BG attribute flips and priority.
- Determinism (section 10.2) on the Color ROM through the page store, and
  page store unit tests (sharing, zero page, eviction, restore exact).

## Status

- 2026-09-26: spec drafted, nothing built yet.
- 2026-09-26: section 18 decided (recommendations accepted, Adrian supplies
  the ROM).
- 2026-09-26: M0 and M1 done (tag `m1`). Core passes Blargg cpu_instrs (all
  11 + combined) and instr_timing, and dmg-acid2 byte for byte; 2048-gb
  (zlib, 32 KB MBC1) plays in the simulator as the development ROM.
  Sizes with that ROM: fast .text 65 KB / .bss 26 KB, small .text 52 KB.
  Waiting on the M1 gate: Adrian flashes and reports FPS + microseconds.
- 2026-09-26: M3 done (tag `m3`): Select-hold menu (palette, scale, sound,
  debug, reset, about), boot splash with chime, APU register model for
  ch1-3 reduced to one `tone2` voice. 47 host tests. Fast build with
  2048-gb: .text 78 KB, .bss 26 KB. Note: 2048-gb writes no sound
  registers, so the audio path is unheard until a ROM with music arrives.
  Next: M4 scrubber; hardware check of the frozen-frame menu and the chime.
- 2026-09-26: M4 scrubber implemented on `m4-scrub`: 7-keyframe ring
  (keyframes sized to the ROM's cart RAM, 18.9 KB with 2048-gb) plus input
  log, 3.0 to 3.5 s of history, uncompressed (section 10.4 not needed).
  Determinism test green. Fast build with 2048-gb: .text 80 KB, .bss 159 KB.
- 2026-09-29: M5 ROM loader started on `boy/rom-loader` (PLAN.md M5): ROMs
  from the badge drive through the shared `lib/romfs.zig`, `Rom` bank table
  in the core, run-time keyframe pool.
- 2026-09-29: M5 done (tag `snouty-boy/m5`): picker, About and overlay
  report the drive ROM; UF2 245 KB (from 497); 77 host tests; drive path
  proven in badge-bench against the gear branch's reader, hardware pending
  (PLAN.md "M5 status").
- 2026-09-29: Game Boy Color (section 19) built on branch
  `snouty-boy-color`: CGB CPU/MMU/KEY1/GDMA/HDMA, CGB renderer (cgb-acid2
  exact), 512 B page store for keyframes, colour LUT frontend. Ships
  Rebound (XIP) and Rex Runner (RAM). Calibrated busy ms mean / p95:
  Rebound 5.3 / 10.3, Rex Runner 3.5 / 6.8, 2048-gb 3.9 / 6.0.
- 2026-09-29: M8 (PLAN.md M8): the Color branch merged onto M5. One UF2
  plays `.gb` and `.gbc` files from the badge drive in the right model;
  the page store and the live console live in the run-time arena
  (section 19.4). 132 host tests.
