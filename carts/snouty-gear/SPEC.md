# Snouty Gear: Game Gear emulator cart spec

Owner: Adrian Hatch (Antithesis). Target: SYCL Badge V2, 160x128 RGB565, 60 Hz.
Seventh cart in this repository and the second emulator after
`carts/snouty-boy`, which it copies wherever it can. "Snouty Gear" is a
working title. Section 18 lists the decisions still open; status and
milestones are at the bottom.

## 1. One paragraph

A full-speed Sega Game Gear emulator written in Zig, built as an
ordinary RAM cart. The game is a ROM file the user copies onto the
badge's USB drive, read in place from flash (shared design in
`docs/ROM_DRIVE.md`); one open-licensed homebrew ROM is embedded as the
fallback when no file is found and for the web simulator. The Game Gear's visible
screen is 160x144, exactly the badge's width, so the picture maps 1:1
horizontally and, as in Snouty Boy, 144 lines are squeezed to 128 by
dropping every ninth one. The Game Gear pad is a d-pad, 1, 2 and Start,
which map to the badge's d-pad, B, A and Start. Holding Select opens the
same emulator menu and time scrubber as Snouty Boy: keyframes of the whole
console every half second, an input log, and a host test showing that
replaying the log from one keyframe reproduces the next one bit for bit.

## 2. Why the Game Gear next

From the 2026-09-27 emulator survey (Game Gear first, then NES, then GBC,
then Genesis as a stretch):

- The screen fits with no scaling: 160 columns 1:1, the same 144 -> 128
  squeeze as Snouty Boy.
- The Z80 core also covers the Master System, SG-1000, ColecoVision, MSX
  and ZX Spectrum, so it is the first of two CPU cores (Z80, 6502) that
  cover most of the feasible machines.
- The CPU load is close to Snouty Boy's. The Z80 runs 59,736 T-states per
  frame (228 per line x 262 lines) and averages about 8 T-states per
  instruction, which is about 7,500 instructions per frame. A Game Boy
  frame (17,556 M-cycles at about 2.3 M-cycles per instruction) is about
  7,600. Snouty Boy measures 5.3 ms mean and 11.4 ms worst per frame
  under badge-bench with the 2026-09-29 calibration (2048-gb, 600
  frames).
- Homebrew with permissive licenses exists (section 11), and the
  devkitSMS/SMSlib toolchain could build an original Snouty ROM later.

## 3. The machine being emulated

Game Gear (NTSC timing). The Master System's mode is out of scope for
M1-M4 (section 17, stretch).

- CPU: Zilog Z80 at 3.579545 MHz. 262 lines x 228 T-states = 59,736 per
  frame at 59.92 Hz; the emulator runs one Game Gear frame per badge frame
  (0.1 percent slow). Interrupt mode 1 (RST 38h) from the VDP; NMI unused
  on the Game Gear (Start is a port bit, not the SMS pause NMI).
- Memory: `0000-BFFF` ROM through the Sega mapper (three 16 KB slots,
  `FFFC-FFFF` control registers, first 1 KB fixed), `C000-DFFF` 8 KB RAM
  mirrored at `E000-FFFF`, optional 8/16/32 KB cartridge RAM in slot 2
  when `FFFC` bit 3 is set. ROMs of 48 KB or less can also run without
  the mapper; the same code path handles both.
- I/O ports (partial decoding as on hardware): `00` Start (bit 7, active
  low) and region; `01-05` link port (stub, reads idle); `06` stereo (write
  ignored); `3E/3F` memory and I/O control (stored, mostly ignored);
  `7E/7F` read V and H counters, write PSG; `BE/BF` VDP data and control;
  `DC/DD` pad (d-pad, 1, 2).
- VDP (315-5378, the Master System 2 VDP with a 12-bit palette): mode 4,
  256x192 active, of which the Game Gear shows columns 48-207 and lines
  24-167. 16 KB VRAM, 64-byte CRAM (32 colors x 12 bits, `----BBBBGGGGRRRR`,
  written as byte pairs through a latch), 11 registers. Background: 32x28
  name table, 4bpp planar tiles, per-tile flip, palette select and priority,
  horizontal scroll (register 8) with the top-two-rows lock, vertical
  scroll (register 9, latched per frame) with the right-eight-columns lock,
  left-column blank. Sprites: 64, 8 per line with the overflow flag, 8x8 or
  8x16, zoom, the shift-left-8 bit, collision flag. Frame interrupt at line
  192, line interrupt from the register 10 down-counter. Status register
  read clears the flags and the pending interrupt. Legacy TMS9918 modes 0-3
  are not implemented (Game Gear software does not use them).
- PSG: SN76489, three square tone channels (10-bit period, 4-bit
  attenuation) and one noise channel. Register model only (section 9).
- No BIOS: registers start at the documented post-BIOS state (SP `DFF0`,
  mapper slots 0/1/2, VDP registers as the BIOS leaves them), cartridge
  header not checked.

## 4. Accuracy target

Scanline accuracy, the same standard as Snouty Boy.

- Instruction-level timing: every instruction advances the machine by its
  T-state count; the VDP catches up after each instruction. Interrupts are
  checked between instructions, with the EI delay and HALT. Undocumented
  opcodes, flags (X/Y, the MEMPTR-derived bits of BIT n,(HL)) and the
  DD/FD CB forms are implemented because the tests check them.
- The VDP renders a whole visible line at its start with the registers as
  they are then. Mid-line register writes are not seen; mid-frame writes
  (line-interrupt raster effects) are, because they land between lines.
  The H counter is approximated from the T-state offset in the line.
- Must pass: ZEXDOC and ZEXALL in Maxim's SMS port (it prints to the SDSC
  debug console, ports `FC/FD`, so the host test captures that text and
  requires every line "OK"); the SingleStepTests Z80 per-instruction
  tests (final registers incl. WZ, memory, port traffic and cycle count;
  the per-cycle bus trace is not checked). VDP unit tests from synthetic
  VRAM/CRAM/register states. No acid-style reference-image ROM exists for
  this VDP (section 16).
- Not attempted: mid-line raster effects, exact VDP access-slot timing,
  the SMS1 VDP quirks, Game Gear link cable.

## 5. Controls

| Badge                  | Game Gear / emulator                                    |
|------------------------|---------------------------------------------------------|
| D-pad                  | D-pad                                                   |
| A                      | Button 2                                                |
| B                      | Button 1                                                |
| Start                  | Start (port 00 bit 7)                                   |
| Select, tap            | Unused by the Game Gear; reserved                       |
| Select, hold 500 ms    | Emulator menu opens, game paused                        |
| In menu                | as Snouty Boy: Up/Down move, A choose, B resume,        |
|                        | Left/Right step time 0.5 s back and forward             |

The Game Gear has no Select button, so the menu could open on a Select tap.
It keeps the 500 ms hold anyway so both emulators behave the same; section
18 item 4 asks whether to change that. Start+Select and the joystick click
are OS-owned as always.

The A/B assignment follows physical position (Game Gear 1 on the left, 2 on
the right; badge B on the left, A on the right). A menu item swaps them.

## 6. Screen mapping

- Horizontal: Game Gear column `x` (0..159) -> badge column `x`, no scaling.
  Only VDP columns 48..207 are rendered at all.
- **Squeeze (default)**: Game Gear line `y` (0..143) -> badge row
  `y - y / 9`; lines with `y % 9 == 8` are skipped (16 of 144), exactly
  Snouty Boy's line map. The VDP still counts them for interrupts.
- **Crop**: lines 8..135 to rows 0..127.
- Line renderer: 4bpp planar tile rows are turned into eight 4-bit pixels
  with one 256-entry u32 bit-spread table per plane (1 KB total), BG
  priority kept per pixel for sprite compositing, then the 5-bit indices
  (palette select adds 16 for sprites) map through a 32-entry `Pixel` cache (12-bit CRAM converted to RGB565,
  rebuilt on CRAM writes), written column-major with stride stores as in
  Snouty Boy.
- Border: the Game Gear shows no border; the backdrop color (register 7)
  fills masked columns (left-column blank).

## 7. Core architecture

The core is badge-agnostic in the same way as Snouty Boy's: no `cart-api`,
no floats, no allocator, no clock, no randomness; the pad byte per frame is
the only input.

```
core/gg.zig       Gg struct (whole console), step_frame(pad),
                  snapshot/restore, reset to post-BIOS state
core/z80.zig      Z80 interpreter, generic over a Bus type (comptime param
                  with read/write/in/out/tick), so the file can move to a
                  shared lib/ when a second Z80 machine arrives. Decode is a
                  switch per prefix group (none, CB, ED, DD/FD, DDCB/FDCB);
                  flag tables built by a host generator, not comptime loops
                  (Adrian's Mac Zig OOMs on heavy comptime)
core/bus.zig      memory map, Sega mapper, cart RAM, port decode
core/vdp.zig      registers, control-port latch, VRAM/CRAM access, counters,
                  interrupts, line renderer, `line_sink` callback
core/psg.zig      SN76489 register model: latch/data writes, periods,
                  attenuations, noise mode (no sample synthesis)
core/rom.zig      bank pointer table (from the drive file, the embedded
                  ROM or the packed fallback), size and mapper detection
```

The core only ever sees `rom.banks: [N][*]const u8` of 16 KB banks. Where
the bytes live is the frontend's business (`lib/romdrive.zig` for the
drive, `@embedFile` for the fallback, section 13.1 for packing).

Frontend: copied from `carts/snouty-boy/cart/src/frontend/` and adapted
(video, input, menu, rewind, splash, debug, audio). The first copy is
deliberate: once both carts work, the console-agnostic parts (keyframe
ring and input log, Select-hold state machine, menu drawing, squeeze line
map, tone2 voice setter) move to a shared module in one change that keeps
Snouty Boy's frames byte-identical under badge-bench (section 17, M5).

Build: `carts/snouty-gear/build.zig` with its own ROM options:
`-Dgg-rom=path` picks the embedded ROM (the existing root `-Drom` is Snouty
Boy's; a shared option would silently feed a Game Boy ROM to the Game Gear
cart) and `-Dgg-rom-source=drive|embed|pack` (default `drive`: the drive
file with the embedded ROM as fallback; `pack` is section 13.1). The wasm
build always embeds.

## 8. Performance budget

150 MHz x 16.7 ms = 2.5 M host cycles per frame, about 42 per Game Gear
T-state. Targets, measured with badge-bench (calibrated, the default) on
600 scripted frames, then on hardware:

| Part                                  | Target per frame | Host cycles per unit     |
|---------------------------------------|------------------|--------------------------|
| Z80, about 7,500 instructions         | <= 5.0 ms        | <= 100 per instruction   |
| VDP lines, 128 x 160 px + sprites     | <= 2.0 ms        | <= 15 per pixel          |
| Counters, interrupts, PSG, mapper     | <= 0.5 ms        |                          |
| Frontend (audio, input, overlay)      | <= 0.3 ms        |                          |
| Total                                 | <= 8 ms          | worst frame under 12 ms  |

Worst frame under 12 ms leaves the same kind of headroom over the model
that Adrian asked for (the model is a floor). Tunables live in one
`tunables.zig`: VDP catch-up granularity (per instruction or per N
T-states), sprite line cap, whether skipped squeeze lines evaluate sprites
(needed for the overflow and collision flags; on by default).

## 9. Audio

One `tone2` voice, following Snouty Boy section 9:

- Candidates: the three tone channels with attenuation below 15 and a
  period above a floor (periods 0 and 1 are the "DC" tricks samples use;
  dropped). Noise dropped.
- Pick the loudest; ties go to channel 0, 1, 2. Frequency
  `3579545 / (32 x period)` Hz, square wave, volume from the attenuation
  (2 dB steps) mapped to 0.2..1.0.
- Issue `tone2` only when frequency or volume changes, once per frame;
  stop when nothing is audible. Menu toggle, default on.

## 10. Time scrubbing

The same model as Snouty Boy section 10.

- Keyframe: RAM 8 KB, VRAM 16 KB, CRAM 64 B, VDP registers and latch,
  Z80 registers, mapper, PSG, counters, about 24.3 KB; plus cart RAM if
  the ROM uses it (8/16/32 KB).
- Every 30 frames into a ring; the pad byte per frame into an input log.
  Left/Right in the menu restore the neighbouring keyframes.
- `tests/determinism.zig`: 600 scripted frames of the shipped ROM, then
  restore each keyframe, replay 30 logged inputs, require byte equality
  with the next keyframe.
- Depth: section 13.
- Keyframes are stored as deltas in every build (Adrian, 2026-09-29),
  because the packing fallback for a 256 KB ROM (section 13.1) leaves 16
  to 32 KB for the ring, where one full 24 KB keyframe would not fit;
  with the ROM on the drive (the default) they simply give more depth. Only the live console is kept
  whole. Design: RAM and VRAM are split into 64-byte blocks (384 blocks,
  a 48-byte dirty bitmap). The first write to a block after a keyframe
  copies its old contents into an undo record; the bus write path pays
  one bit test. Taking a keyframe closes the record (dirty blocks' old
  bytes, zero-run RLE, plus the small registers whole) and clears the
  bitmap. Restoring keyframe k undoes the open record, then applies
  closed records newest to oldest down to k. Nothing is compressed on the
  badge in the hot path and no full keyframe copy exists.
- Record size per half second is not known yet (Sonic streams tiles into
  VRAM while scrolling); M3 measures it. Target: at least 3 s of history
  for any ROM from the drive, at least 1 s for Sonic in the packing
  fallback. The oldest record is dropped when
  the ring is full.

## 11. The ROM

One ROM, shipped publicly, so its license must allow redistribution.
Commercial ROMs never enter the repo or the cart (local testing with them
is Adrian's business, as with Super Mario Land on Snouty Boy).

- Requirements, checked by `tools/romcheck.py`: Game Gear ROM (or an SMS
  ROM that runs in Game Gear mode, which few do), at most 128 KB (ideally
  64 KB, section 13) stored as is, or up to 256 KB through the bank packer
  in an XIP build (section 13.1), Sega mapper or none, cart RAM at most
  8 KB unless the XIP build is chosen, no FM sound, no mid-line raster
  effects.
- ROM source on the badge: a `.gg` (or `.sms`) file on the badge drive,
  per `docs/ROM_DRIVE.md`. Any size the drive holds works (up to about
  950 KB free with this cart alone; the largest Game Gear games are
  512 KB). The embedded ROM, chosen with `-Dgg-rom`, is only the fallback
  and the simulator's ROM, so it keeps the 128 KB limit above.
- Local stress target (never shipped): **Sonic the Hedgehog, Game Gear**
  (Sega/Ancient 1991, 256 KB, Sega mapper, no cart RAM; header region code
  0x6 at `7FFF`, md5 `8a95b36139206a5ba13a38bb626aee25`). It is the 8-bit
  Sonic, a different game from the Genesis one. Embedded, it would fill the
  whole cart flash window, which is why the packing fallback (13.1)
  exists; from the drive it needs nothing special.
  Adrian's copy is at `~/sonic.gg` on the VM (the file named `~/sonic.sms`
  there is the same Game Gear image). On the badge it is simply copied
  onto the drive; in the simulator it is embedded locally with
  `-Dgg-rom=~/sonic.gg`. Commercial ROMs stay outside the repository; the root
  `.gitignore` ignores `*.gg` and `*.sms` so a copy in `roms/` cannot be
  committed by accident (the shipped ROM is added with an explicit
  exception).
- Candidates (research 2026-09-29: release zips downloaded, LICENSE files
  read, ROM bytes scanned for mapper and port use):
  1. **Waternet** (Willems Davy, github.com/joyrider3774/waternet), MIT,
     LICENSE in the release zip. Pipe-connecting puzzle game, three modes,
     built with GBDK-2020. 64 KB file with about 32 KB of real content (two
     non-empty banks), Sega mapper, writes `FFFC` (probably cart RAM for
     saves). Music is written as single-channel note tables, which suits
     one tone2 voice. Simplest VDP use of the three. **Recommended.**
  2. **Sushi Nights** (Zalo et al., CrossZGB port by Toxa), MIT for the
     code; 128 KB, about 80 KB used, multi-channel PSG music. Art and
     music are by other credited people and whether MIT covers them is
     unverified. The more fun game; a stretch or second cart.
  3. **GLUF Tesla Frog** (Toxa, SMS Power 2026 competition), MIT for
     Toxa's code; 128 KB, about 112 KB used. A remake of RetroSouls' ZX
     Spectrum game with no statement of permission found. Tightest fit.
  Rejected: Petris (CC-BY-NC-SA), and SMS Power homebrew pages with no
  license. Neither Waternet nor the others use FM or the stereo port;
  line-interrupt use is not yet checked (the CrossZGB games probably use
  one for a status bar, which section 4 supports).
- Test ROMs, fetched by `tools/fetch_test_roms.sh`: `zexdoc.sms` and
  `zexall.sms` (github.com/maxim-zhao/zexall-sms v0.21, GPL-2.0, fine as
  unshipped fixtures); SingleStepTests Z80 (github.com/SingleStepTests/z80,
  MIT, `v1/*.json`, one file per opcode, 1,000 cases each, about 1.2 GB
  unpacked, fetched sparsely); FluBBa's SMS VDP Test and sverx's SMS Test
  Suite as visual checks in the simulator only (no license files, never
  committed).
- Test ROMs are fetched by `tools/fetch_test_roms.sh` into `tests/roms/`
  (gitignored), never committed unless their license allows and the build
  needs a fallback, as with `2048.gb`.

## 12. Boot splash and presentation

Snouty Boy's splash, recolored: the Snouty mark slides in, then a two-note
chime, then the game. The menu title reads "SNOUTY GEAR", the ROM name, and
"verified by deterministic replay". The
neopixels are off: the cart never writes non-zero values (root
`docs/NEOPIXELS.md`; a coworker's badge shows the LEDs are unusably bright
even at 1%, 2026-09-29).

## 13. Memory budget

Estimates, measured with `size -A` at each milestone. Code is larger than
Snouty Boy's (82 KB fast with the frontend) because the Z80 has four prefix
groups.

Default build: a RAM cart with the ROM on the drive, so the ROM costs no
cart RAM at all. The embedded fallback ROM does (it is in the RAM image).

| Item                              | RAM cart, drive ROM   |
|-----------------------------------|----------------------:|
| Code + frontend (ReleaseFast)     | ~95 KB                |
| Splash, fonts, tables             | ~6 KB                 |
| Embedded fallback ROM             | 32-64 KB              |
| Drive file map (fragmented case)  | <= 4 KB               |
| Live console + cart RAM 8 KB      | ~33 KB                |
| Frontend state, input log         | ~3 KB                 |
| Keyframe ring (deltas, section 10)| ~60-100 KB            |
| Total of ~268 KiB                 | fits                  |

The fallback ROM competes with the ring, so it stays small (Waternet's
two used banks, section 11). XIP is not needed for this cart any more;
it only returns with the packing fallback (13.1).

### 13.1 Fallback: ROMs over 128 KB packed into the cart

Only if the drive path fails on hardware (`docs/ROM_DRIVE.md` section 6)
or a single-file cart with a large ROM is wanted.

A 256 KB ROM stored as is fills the 256 KB XIP flash window with no room
for code, and it cannot all be unpacked into RAM either (256 KB of banks
plus about 28 KB of live console and frontend state is more than the
268 KiB of RAM left after the stack). So, in XIP builds only:

- `tools/pack_rom.py` (a host step, not comptime, for Adrian's Mac) splits
  the ROM into its 16 KB banks and compresses each one alone. It keeps the
  `R` banks that compress worst uncompressed in flash and stores the rest
  compressed. It writes `rom_packed.bin` plus a small index (per bank: raw
  or packed, offset, length) that `core/rom.zig` embeds.
- At `start()` the packed banks are inflated into one `.bss` array. The
  mapper already maps slots through a 16-entry table of bank pointers, so
  after boot a raw bank points into flash and a packed bank into RAM, at no
  cost per access.
- `R` is chosen by the tool from two inputs: the RAM to keep free for the
  keyframe ring (default 32 KB) and the flash size of the code, read from
  the linked ELF. If both cannot be met it fails with the numbers, rather
  than building a cart that overflows.
- Codec: deflate (Zig `std.compress.flate`) unless the M4 size check shows
  the zstd decoder is small enough for its 3 to 5 KB smaller output. The
  compressor may use any setting; only the decoder is on the badge.
- Boot inflates up to 224 KB once. Its time is measured in M4 (unknown;
  expected well under a second) and covered by the splash.

Measured on Sonic GG (2026-09-29, per-bank deflate -9 via Python `zlib`;
zstd -19 for comparison). The banks compress to 6.1 to 13.1 KB each and
none is padding. Raw banks are picked worst-first (9, 13, 12, 14):

| Raw banks | ROM in flash | Flash left for code, tables, decoder | RAM left for the ring |
|----------:|-------------:|-------------------------------------:|----------------------:|
| 1         | 156.6 KiB    | 99.4 KiB                             | 0.2 KiB               |
| 2         | 160.4 KiB    | 95.6 KiB                             | 16.2 KiB              |
| 3         | 164.6 KiB    | 91.4 KiB                             | 32.2 KiB              |
| 4         | 168.9 KiB    | 87.1 KiB                             | 48.2 KiB              |

(zstd gives 3.5 to 4.3 KiB more flash for code in each row.) This is
tighter than section 13's code estimate: ~95 KB of ReleaseFast code plus
~6 KB of tables plus the decoder does not fit next to 3 raw banks.
Therefore the Sonic build is ReleaseSmall, or ReleaseSmall for the
frontend with the Z80 and VDP modules in ReleaseFast. The M1 `size -A`
numbers settle which. Code copied to a RAM-text section (XIP open item 4)
takes RAM as well as flash, so it comes out of the ring budget.

## 14. Instrumentation

Snouty Boy's overlay (average and worst `step_frame` microseconds, FPS),
`debug_*` exports for `tools/preview.mjs --dump-exports`, and a
`badge-bench/carts/snouty-gear.toml` with a scripted input run (title,
start, some play, a scrub).

## 15. Repo layout

```
carts/snouty-gear/
  SPEC.md PLAN.md CLAUDE.md README.md build.zig
  core/        gg.zig z80.zig bus.zig vdp.zig psg.zig rom.zig tables.zig (generated)
  cart/src/    main.zig frontend/{video,input,menu,rewind,splash,debug,audio}.zig
  tests/       all.zig z80_zex.zig z80_single_step.zig vdp_unit.zig
               psg_unit.zig determinism.zig roms/ (gitignored)
  tools/       fetch_test_roms.sh romcheck.py gen_tables.py pack_rom.py
               scripts/*.json (badge-bench and preview input scripts)
  roms/        the shipped ROM and its LICENSE
  docs/        RUNNING.md, preview GIFs
```

Root `build.zig` gains one line in `carts`; root README gains a row.

## 16. Verification

- Host (`zig build test`): ZEXDOC and ZEXALL to completion with no
  "ERROR" lines; SingleStepTests (full set if it runs in under a minute,
  otherwise a committed sample of about 100 cases per opcode converted to
  a compact binary by a host script); VDP unit tests (scroll and locks,
  priority, flips, sprite limit and overflow, zoom, 8x16, line interrupt
  counter, status read side effects, CRAM latch); PSG register tests;
  mapper tests; determinism.
- VDP reference: there is no dmg-acid2 equivalent for this VDP, so the
  shipped ROM gets golden frames (a scripted input run, frames reviewed by
  eye once, then pinned by hash in a host test). Optional cross-check:
  the same frames from a reference emulator (Gearsystem or Emulicious) run
  locally, compared by hand; never a build dependency.
- Badge: badge-bench on the RAM ELF with the scripted run and the ROM in a
  romfs image (`--romfs`, `docs/ROM_DRIVE.md` section 6; the XIP ELF
  only if the packing fallback is used); numbers
  recorded in PLAN.md; preview GIF.
- Hardware (Adrian): overlay numbers, and the drive checks in
  `docs/ROM_DRIVE.md` section 6 (read speed, XIP hit rate, startup).

## 17. Milestones

Each milestone: a tag `snouty-gear/mN`, a preview GIF in `docs/`, and pull
and run notes. Parallel tracks go to Opus agents in git worktrees with
disjoint files, as for Snouty Boy.

- **M0 Scaffold**: this spec and PLAN.md, the cart directory wired into the
  root build, `-Dgg-rom`, stubbed core that shows a test pattern,
  `fetch_test_roms.sh`, `romcheck.py`, the ROM chosen and committed with
  its LICENSE (as `2048.gb` is for Snouty Boy), badge-bench toml. Check
  the ROM's line-interrupt and cart-RAM use with a quick port/address
  trace once the Z80 runs.
- **M1 Core** (the risk milestone), three tracks:
  A `core/z80.zig` + table generator + ZEX and SingleStepTests harnesses;
  B `core/vdp.zig` + VDP unit tests + the reference-frame test;
  C `core/bus.zig`, `psg.zig`, `rom.zig`, `gg.zig` frame loop, frontend
  video and input, tools, RUNNING.md.
  Done when: every host test green, the shipped ROM plays in the simulator,
  badge-bench mean under 8 ms and worst under 12 ms (RAM ELF, ROM from a
  romfs image), `lib/romfs` parser tests green.
  Gate: Adrian copies Waternet and Sonic GG to the drive, ejects, runs
  both, and reports the overlay numbers (incl. XIP hit and stall rates).
  If the drive path fails here, M4 builds the packing fallback.
- **M2 Frontend**: menu, splash, PSG to one tone2 voice, A/B swap, scale
  modes, all adapted from Snouty Boy.
- **M3 Scrub**: delta keyframe ring (section 10), input log, scrubbing,
  determinism test (it must also pass with the undo
  records, restoring every keyframe in the ring), record sizes measured.
- **M4 Hardware polish and big ROMs**: tune from Adrian's numbers. Bank
  packer (section 13.1) with a host test that the unpacked bank table is
  byte-identical to the ROM, only if the drive path failed in M1; Sonic
  GG from the drive on hardware, badge-bench and hardware numbers,
  history depth recorded.
- **M5 Stretch** (pick with Adrian): shared emulator frontend module used
  by both emulator carts; Master System mode (256 -> 160 by following the
  horizontal scroll or a 1.6:1 column map); an original Snouty ROM built
  with devkitSMS; move `z80.zig` to a shared `lib/` for the next Z80
  machine.

## 18. Decisions

Decided 2026-09-29: Adrian accepted every recommendation.

1. Name: "Snouty Gear" is the working title and directory name.
2. ROM: Waternet (MIT, section 11).
3. Mode: develop and bench RAM and XIP from M1; ship the RAM cart (small
   ROM, compressed keyframes) until XIP is proven on the badge, then decide
   in M4. **Superseded 2026-09-29:** RAM cart with the ROM read from the
   badge drive (`docs/ROM_DRIVE.md`), embedded ROM as fallback; XIP only
   for the packing fallback (section 13.1).
4. Menu key: Select held 500 ms, the same as Snouty Boy.
5. Frontend sharing: copy from Snouty Boy now; extract a shared module in
   M5 with Snouty Boy's frames byte-identical under badge-bench.

## Status

- 2026-09-29: spec drafted; section 18 decided (recommendations accepted).
  Next: M0 scaffold.
- 2026-09-29: Adrian chose delta keyframes (section 10). Added the bank
  packer for 256 KB ROMs (section 13.1) with Sonic GG as the local stress
  target (section 11); measurements in 13.1.
- 2026-09-29: Adrian chose ROMs read from the badge drive
  (`docs/ROM_DRIVE.md`) as the default, RAM cart, with packing the ROM
  into the cart image kept as the fallback (13.1). Section 13 redone.
- 2026-09-29: M0 done (tag `snouty-gear/m0`): scaffold, stub core with a
  test pattern, `lib/romfs.zig` FAT12 reader proven under badge-bench with
  a Waternet drive image, `tools/make_romfs.py`, badge-bench `--romfs`.
  Numbers in PLAN.md. Hardware checks (docs/ROM_DRIVE.md section 6) pending.
