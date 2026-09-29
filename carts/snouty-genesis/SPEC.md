# Snouty Genesis: Sega Genesis emulator cart spec

Owner: Adrian Hatch (Antithesis). Target: SYCL Badge V2, 160x128 RGB565.
Eighth cart in this repository and the third emulator, after
`carts/snouty-boy` and `carts/snouty-gear`, which it copies wherever it
can. "Snouty Genesis" is a working title. This is the "push the limit"
cart from the 2026-09-27 emulator survey: the first one whose ROM does not
live in the cart at all but is streamed from the badge's USB drive
(`docs/ROM_STREAMING.md`). Section 18 lists the decisions still open;
status and milestones are at the bottom.

## 1. One paragraph

A Sega Genesis (Mega Drive) emulator written in Zig that plays a ROM the
user copies onto the badge's USB drive, read in place from flash. The
Genesis draws 320x224, which maps to the badge's 160x128 by rendering
every second column and 128 of the 224 lines through a line table
(section 6). The 68000 is emulated at full speed as
the goal, with rendering on every second frame so the badge presents at
30 Hz. The Z80 sound CPU runs from M1 (Snouty Gear's core) against a
YM2612 register model, and the badge's one tone voice plays the loudest
keyed-on channel (section 9): minimum viable sound, no FM synthesis.
Holding Select opens the same emulator menu and time scrubber
as Snouty Boy and Snouty Gear, backed by delta keyframes and an input log
that replays bit for bit.

## 2. Why the Genesis, and why now

- The survey ranked it borderline: the 68000 is about twice the Game
  Gear's instruction rate, and no commercial ROM fits the 256 KB cart
  flash window. The ROM-streaming finding of 2026-09-29
  (`docs/ROM_STREAMING.md`) removes the second objection for ROMs up to
  about 900 KB on stock firmware (section 13), which covers the 512 KB
  class (Sonic 1, Streets of Rage, Columns, many homebrew titles).
- It exercises the XIP cart mode for real: this cart cannot be a RAM cart
  (section 13).
- Snouty Gear's Z80 core is the Genesis sound CPU, so sound reuses it
  from M1.

Started 2026-09-29 after Snouty Gear M1 (Adrian, section 18): the Z80
core, the frontend and the drive reader exist to copy from; the XIP
numbers from the badge do not yet.

## 3. The machine being emulated

Genesis model 1, NTSC, without TMSS (the version register reports no TMSS;
games run either way). PAL is out of scope.

- Master clock 53.693175 MHz; 262 lines x 3420 master clocks per frame
  (59.92 Hz). 68000 at master / 7 = 7.670454 MHz: 128,008 cycles per frame,
  about 488.6 per line. Z80 at master / 15 = 3.579545 MHz.
- 68000 memory map:
  - `000000-3FFFFF` cartridge ROM (big-endian words), optional cartridge
    SRAM at `200000` when the header declares it (section 11);
  - `A00000-A0FFFF` Z80 address space (8 KB RAM at `A00000`, YM2612 at
    `A04000`) as seen through the bus arbiter;
  - `A10000-A1001F` version and I/O ports (two 3-button pads; port 2 idle);
  - `A11100` Z80 BUSREQ, `A11200` Z80 RESET;
  - `C00000/C00002` VDP data, `C00004/C00006` VDP control, `C00008` HV
    counter, `C00011` PSG;
  - `FF0000-FFFFFF` 64 KB work RAM (mirrored from `E00000`).
- VDP (315-5313): H40 (320 wide, the common mode) and H32 (256 wide);
  V28 (224 lines). 64 KB VRAM, CRAM 64 x 9-bit colors (4 palettes of 16),
  VSRAM 40 x 10-bit. Planes A and B (32/64/128-cell sizes), window plane,
  80 sprites in H40 (64 in H32) with the per-line limits (20 sprites, 320
  pixels in H40), linked sprite list, 4bpp 8x8 tiles with flip, palette and
  priority bits. Horizontal scroll per screen, per 8 lines or per line;
  vertical scroll per screen or per 2-cell column. Shadow/highlight mode.
  DMA: 68000 memory to VRAM/CRAM/VSRAM, VRAM fill, VRAM copy. Interrupts:
  V-int (level 6) at line 224, H-int (level 4) from the register 10
  counter. Status register, HV counter.
- Z80, YM2612 and PSG: section 9.

## 4. Accuracy target

Scanline accuracy, as in the other emulator carts.

- 68000: instruction-level timing (each instruction costs its documented
  cycle count, including effective-address and taken-branch variants),
  interrupts between instructions with the priority mask, TRAP/CHK/
  division-by-zero/privilege exceptions, supervisor/user stacks. Not
  attempted: the prefetch queue, bus-cycle-exact timing, address-error
  exceptions (odd-address word access), 68010+ instructions.
- VDP: renders each needed line at its start with the registers as they
  are then; mid-line writes are not seen, mid-frame writes are (H-int
  raster effects). DMA completes instantly and charges the 68000 an
  approximate stall. The HV counter is interpolated from the cycle offset
  in the line. Not attempted: FIFO and access-slot timing, sprite
  collision exactness on skipped lines, interlace modes.
- Must pass: Tom Harte's 68000 ProcessorTests (JSON, one file per
  instruction class; now under github.com/SingleStepTests, repository and
  license confirmed in M0): final registers, SR, memory and cycle count
  (not the per-cycle bus trace). VDP unit tests from synthetic VRAM/CRAM/
  VSRAM/register states; golden frames of the shipped ROM (no acid-style
  reference ROM is used as a build dependency).

## 5. Controls

A 3-button pad (A, B, C, Start). The badge has A, B, Start and Select.

| Badge                  | Genesis / emulator                                     |
|------------------------|--------------------------------------------------------|
| D-pad                  | D-pad                                                  |
| B                      | B                                                      |
| A                      | C                                                      |
| Select, tap (< 500 ms) | A (sent for 4 frames on release)                       |
| Start                  | Start                                                  |
| Select, hold 500 ms    | Emulator menu opens, game paused                       |
| In menu                | as Snouty Boy: Up/Down move, A choose, B resume,       |
|                        | Left/Right step time 0.5 s back and forward            |

B and C are the buttons most games use most (Sonic jumps on any; Streets
of Rage attacks on B and jumps on C). Genesis A on a Select tap arrives on
release, so it is late; a menu item remaps the three (for example A on
badge A, C on the tap) per ROM. Section 18 item 5. Start+Select and the
joystick click are OS-owned as always. The 6-button pad is out of scope.

## 6. Screen mapping

- **H40 (320 wide)**: badge column `x` shows Genesis column `2x`. Only
  those 160 columns are ever rendered, which halves pixel work. A menu
  option averages column pairs instead (costs about 1.5x render time).
- **H32 (256 wide)**: badge column `x` shows Genesis column `x * 8 / 5`
  through a 160-entry column table (same renderer, different table).
- **Vertical, squeeze (default)**: badge row `r` shows Genesis line
  `r * 7 / 4` (lines 0..222), so 128 of 224 lines are rendered and 96 are
  never drawn. V-int, H-int and the line counter still run on every line.
- **Vertical, crop**: lines 48..175 to rows 0..127 (for games whose action
  sits in the middle band; a menu option).
- Line renderer: per output line, plane B low, plane A low, sprites low,
  then the high-priority layers, composited into 160 pixels of 6-bit
  palette indices plus a shadow/highlight tag, then mapped through a
  64-entry `Pixel` cache (9-bit CRAM to RGB565, rebuilt on CRAM writes),
  written column-major as in Snouty Boy. Tile rows decode with a
  256-entry nibble-spread table. Sprites are evaluated per output line
  only; the 20-per-line limit is applied to the lines rendered.
- Aspect: 320x224 to 160x128 is 2.0 by 1.75, so the picture is about 14
  percent taller than it should be. Accepted for M1; the crop mode is the
  alternative.

## 7. Core architecture

Badge-agnostic core, as in Snouty Boy and Snouty Gear: no `cart-api`, no
floats, no allocator, no clock, no randomness; the pad state per frame is
the only input.

```
core/md.zig       Md struct (whole console), step_frame(pad, render: bool),
                  snapshot hooks, reset to power-on state
core/m68k.zig     68000 interpreter, generic over a Bus type (comptime param
                  with read8/read16/write8/write16/tick/irq_level). Decode
                  from a host-generated table (tools/gen_m68k.py writes
                  core/m68k_tables.zig; Adrian's Mac OOMs on heavy comptime).
                  Table shape (64 K x u8 handler index in flash, or a
                  two-level decode) is chosen in M1 by size and speed
core/bus.zig      68000 memory map, I/O and pads, Z80 bus arbiter
                  (BUSREQ/RESET), SRAM, forwarding of A00000-A0FFFF to
                  the Z80 side
core/vdp.zig      ports, control-word latch, VRAM/CRAM/VSRAM, DMA, counters,
                  interrupts, column and line tables, line renderer,
                  line_sink callback
core/z80bus.zig   the Z80's memory map (section 9): 8 KB RAM, YM2612 ports,
                  bank register, PSG, the 32 KB 68000 bank window
core/ym2612.zig   YM2612 register model (no synthesis) and the loudest
                  keyed-on channel -> frequency pick
core/psg.zig      SN76489 register model (written from either CPU)
core/rom.zig      the RomSource interface (section 11), header parse,
                  byte order
```

The Z80 interpreter is Snouty Gear's `core/z80.zig` (`Z80(comptime BusT)`),
imported as a module by path from `carts/snouty-gear/core/`, not copied: a
fix needed here goes into Gear's file with Gear's tests still green.

Byte order: the ROM is stored exactly as the file (big-endian words), so
the same bytes serve the embedded and the streamed source. 16-bit reads
byte-swap (one `rev16`); work RAM and VRAM are kept in host order where
the renderer benefits and documented per array in `md.zig`.

Frontend: copied from Snouty Gear's `cart/src/frontend/` (itself from
Snouty Boy) and adapted: video, input (Select tap and hold), menu, rewind,
splash, debug, plus `romfs.zig` (section 11). If Snouty Gear's M5 shared
frontend module exists by then, use it instead.

Build: `carts/snouty-genesis/build.zig`, XIP mode only
(`-Dcart-mode=xip`; a RAM build fails with a message pointing at section
13), with its own ROM option `-Dmd-rom=path` for the embedded source.

## 8. Performance budget

150 MHz. The badge presents at 30 Hz: each `update()` runs two Genesis
frames and renders only the second ("60/30"). The game runs at full speed
if the 33.3 ms budget holds. Targets, measured with badge-bench
(calibrated, the default) on the embedded build, then on hardware:

| Part (per 33.3 ms update)             | Target      | Host cycles per unit        |
|---------------------------------------|-------------|-----------------------------|
| 68000, 2 x ~12,800 instructions       | <= 19 ms    | <= 110 per instruction      |
| Z80, 2 x ~59,700 Z80 cycles           | <= 6 ms     | Snouty Gear's core as is    |
| VDP bookkeeping, DMA, interrupts, x2  | <= 1.5 ms   |                             |
| Render 128 lines x 160 px + sprites   | <= 4 ms     | <= 30 per output pixel      |
| Frontend (input, overlay, tone, rewind)| <= 0.5 ms  |                             |
| Total                                 | <= 31 ms    | worst update under 33 ms    |

(About 10 68000 cycles per instruction on average; measured in M1 from
the golden run.) Running the Z80 from M1 (Adrian, 2026-09-29) costs about
a Game Gear's worth of CPU: Snouty Gear's whole frame is 3.7-5.7 ms mean
on badge-bench with the same Z80 clock, so the Z80 alone should be under
3 ms per Genesis frame. The 68000 target tightens from 130 to 110 host
cycles per instruction to pay for it, and the headroom is thin: this is
the M1 risk, measured before anything else is tuned. Fallbacks in the
order they are tried, all tunables in one `tunables.zig`:

1. `render_every`: 2 by default (60/30); 3 presents at 20 Hz with the game
   and the sound still at full speed (50 ms budget); 1 for 60 Hz if the
   numbers ever allow it.
2. `z80_scale`: fraction of the Z80's 59,659 cycles per frame it gets
   (sound drivers idle-loop between V-ints, so most tolerate some
   underclocking before the tempo drags). Default 1.0.
3. `cpu_scale`: fraction of 128,008 cycles the 68000 gets per frame
   (underclock before dropping emulated frames; most games slow down
   gracefully). Default 1.0.
4. A menu item turns the Z80 off entirely (arbiter stub behaviour of
   section 9); games that hang without their sound driver say so in the
   overlay.

Also: column averaging on or off; sprite evaluation on skipped lines off.

badge-bench models the embedded build with its flash as ordinary memory,
so it misses XIP cache misses on ROM fetches. Streaming cost is measured
only on the badge (section 16).

## 9. Audio

Minimum viable sound from M1 (Adrian, 2026-09-29): the real sound driver
runs on an emulated Z80, the chips are register models without synthesis,
and the badge's one `tone2` voice plays one note chosen from them.

- **Z80**: Snouty Gear's `z80.zig` at master / 15 = 3.579545 MHz, 59,659
  cycles per frame (228 per line), run in line slices interleaved with the
  68000 (section 7 of PLAN.md fixes the slice). Interrupt mode 1 `INT` is
  asserted at V-int for one line. `HALT` skips straight to the next event.
- **Z80 memory map** (`core/z80bus.zig`): `0000-1FFF` 8 KB RAM (mirror
  `2000-3FFF`), `4000-4003` YM2612, `6000` bank register (9 bits, shifted
  in one bit per write), `7F00-7F1F` VDP and PSG (`7F11`), `8000-FFFF` the
  32 KB window into 68000 space selected by the bank register (ROM via
  `RomSource`, work RAM; VDP or Z80-side addresses through the window are
  not reachable and read `FF`).
- **Bus arbiter** (`core/bus.zig`): `A11100` BUSREQ takes the bus from the
  Z80 (it stops until released; reads report the state), `A11200` RESET
  holds the Z80 and the YM2612 in reset. While the 68000 holds the bus it
  reads and writes Z80 RAM and the YM2612 at `A00000-A0FFFF`; otherwise
  those reads return open-bus `FF`. Games that write Z80 RAM without
  BUSREQ get what the hardware would give them.
- **YM2612** (`core/ym2612.zig`): the register file for both parts (6
  channels x 4 operators, key-on, F-number and block, total level,
  algorithm, LFO, channel 3 special mode, channel 6 DAC enable), the timer
  A and B flags in the status byte (drivers poll them for tempo), the
  address and data latches. No envelopes and no output.
- **PSG** (`core/psg.zig`): SN76489 register model, tone periods and
  attenuations, written from either CPU.
- **The one voice**: once per emulated frame `Md.tone()` picks the
  channel to play: among keyed-on FM channels (channel 6 skipped when its
  DAC is enabled) the one whose carrier operators have the lowest total
  level; frequency from F-number and block
  (`f = fnum * 2^(block-1) * 53693175 / (144 * 2^20)` in integer math), against the
  loudest PSG tone channel (attenuation below 15, period above 6); FM wins
  ties. The frontend issues `tone2` on change and stops it when nothing
  is keyed on. Noise, DAC samples, envelopes and vibrato are lost by
  design.
- **Z80 off** (tunable and menu item, fallback 4 of section 8): the
  arbiter stub. BUSREQ reports granted at once, RESET is recorded, Z80 RAM
  is plain memory, the YM2612 status reads "not busy" and the tone comes
  from 68000-side PSG writes only. Games that wait for their driver's
  handshake hang in this mode; the overlay shows the mode.

## 10. Time scrubbing

Delta keyframes, the design Adrian chose for Snouty Gear (section 10
there), because a full Genesis keyframe does not fit twice in RAM.

- State: work RAM 64 KB, VRAM 64 KB, CRAM/VSRAM 208 B, VDP registers and
  latch, 68000 registers, pads, PSG, counters: about 129 KB, plus
  cartridge SRAM if any (section 11), plus 8 KB Z80 RAM, the Z80
  registers, the bank register, the arbiter state and the YM2612 register
  file (about 600 B).
- Work RAM, VRAM and Z80 RAM split into 64-byte blocks (2176 blocks, a
  272-byte dirty bitmap); first write to a block after a keyframe copies
  its old contents into the open undo record. Keyframe every 30 Genesis
  frames; pad state per frame into the input log.
- VRAM DMA makes records large (games stream tiles every frame). The bus
  write path and the DMA path both mark blocks; DMA marks a run at once.
- `tests/determinism.zig`: 600 scripted frames of the shipped ROM,
  restore every keyframe in the ring, replay 30 logged inputs, require
  byte equality with the next keyframe.
- Target: at least 1 s of history. M3 measures record sizes; if 1 s does
  not fit, the menu says "rewind unavailable" rather than shipping a
  scrubber that cannot go back.

## 11. The ROM

Two sources behind one interface, `RomSource` in `core/rom.zig`: a base
pointer for contiguous ROMs, or a cluster table (section 1 of
`docs/ROM_STREAMING.md`), plus the size. The CPU's ROM read is
`base + addr` on the fast path and one table lookup otherwise.

- **Embedded** (`-Dmd-rom=path`, default the shipped ROM in `roms/`):
  linked into flash as `.rodata`. The simulator, the headless preview,
  badge-bench and the host tests use this source. Size limit: whatever
  section 13 leaves in the 256 KB window, and the badge build keeps it
  small (a tiny test ROM or none) because every KB of cart flash image
  costs 2 KB of `romfs` (section 13).
- **Streamed from `romfs`** (badge only): the shared FAT12 reader
  `lib/romfs.zig` (Snouty Gear M0; `Volume.open`, `find`, `map`,
  `Mapped.contiguous`/`chunk`) lists root files with extension `.GEN`,
  `.MD` or `.BIN` whose word at `0x100` reads "SEGA". One file starts
  directly; several give a picker at boot. `cart/src/frontend/romsrc.zig`
  (adapted from Gear's) turns the `Mapped` into a `RomSource`: the base
  pointer when `contiguous()` succeeds, else the cluster table (a 1 MB ROM
  is 2048 u16 entries, 4 KB). Drive images for badge-bench and host tests
  come from the shared `tools/make_romfs.py` (contiguous, fragmented,
  deleted entries). No firmware change (`docs/ROM_STREAMING.md`).
- Requirements, checked by `tools/romcheck.py` on the host and by the
  cart at load: raw binary (not SMD-interleaved; detected and refused),
  header at `0x100`, size up to the section 13 ceiling, no mapper beyond
  4 MB (SSF2) and no SVP chip (Virtua Racing), SRAM up to 16 KB (kept in
  RAM, not saved, since writes need firmware; section 18 item 8).
- Shipped ROM: must be redistributable. Candidates are researched in M0:
  homebrew with an explicit license, or an original Snouty ROM built with
  SGDK (MIT). Test ROMs are fetched by `tools/fetch_test_roms.sh` into
  `tests/roms/` (gitignored).
- Local stress targets (never shipped, never in the repo): Adrian's
  commercial ROMs, copied to the badge's USB drive or passed with
  `-Dmd-rom=` for simulator runs. Sonic the Hedgehog (512 KB) is the
  natural first target. The root `.gitignore` gains `*.gen` and `*.smd`.
  `*.md` cannot be a pattern (it would ignore Markdown), so `.bin` and
  `.md` ROMs under `carts/snouty-genesis/roms/` and `tests/roms/` are
  ignored by path, with an explicit exception for the shipped ROM.

## 12. Boot splash and presentation

The Snouty splash from the other emulators, recolored. The menu title
reads "SNOUTY GENESIS", the ROM's domestic name from its header, and
"verified by deterministic replay". The
neopixels are off: the cart never writes non-zero values (root
`docs/NEOPIXELS.md`; a coworker's badge shows the LEDs are unusably bright
even at 1%, 2026-09-29). If no ROM is found on the drive, a help
screen says to copy a `.gen` file to the badge's USB drive.

## 13. Memory budget

XIP cart only. A RAM cart would have to hold the code (about 110 KB) and
about 137 KB of console state in the 268 KB window, leaving nothing for
the rewind ring. Estimates, measured with `size -A` at each milestone:

| Flash (256 KB cart window)           | Estimate   |
|--------------------------------------|-----------:|
| Code + frontend                      | ~110 KB    |
| Z80 core and tables (Snouty Gear's)  | ~24 KB     |
| 68000 decode table                   | 0-64 KB    |
| Render tables, fonts, splash         | ~8 KB      |
| Embedded ROM (badge build)           | 0-8 KB     |
| Total                                | 142-214 KB |

| RAM (~275 KB of XIP data window)      | Estimate   |
|--------------------------------------|-----------:|
| Live console (section 10) + Z80 side | ~138 KB    |
| Cartridge SRAM (optional)            | 0-16 KB    |
| Cluster table, ROM up to 1 MB        | 4 KB       |
| RAM-text: 68000, Z80 and line render | ~32 KB     |
| Frontend state, input log            | ~4 KB      |
| Left for rewind ring and ROM cache   | ~80-96 KB  |

ROM size ceiling on stock firmware: `romfs` is 1280 KB, the cart's own
UF2 costs twice its flash image (284-428 KB), FAT and directory overhead
is about 8 KB. That leaves **about 840-990 KB for ROMs** if nothing else
is on the drive: 512 KB titles fit comfortably, 1 MB titles do not unless
the decode table is dropped and the code shrinks. This is why the flash
image is kept small. The firmware is not changed for this conference
(Adrian, section 18 items 6 and 7); `docs/ROM_STREAMING.md` keeps the
layout-change arithmetic for later.

XIP mode has not yet been confirmed on the badge (the Snouty Gear M4 and
this cart's M0 gate check it). The hot loops run from a RAM-text section
(XIP open item 4) because the 16 KB XIP cache is shared with the OS and
with ROM fetches.

## 14. Instrumentation

The overlay from the other emulators (average and worst `update()`
microseconds, emulated frames per second, render skip in use), `debug_*`
exports for `tools/preview.mjs --dump-exports`, a
`badge-bench/carts/snouty-genesis.toml` with a scripted run, and an
overlay line with the ROM source (embedded, contiguous or fragmented).
The OS FPS overlay's XIP hit and stall rates are the streaming numbers.

## 15. Repo layout

```
carts/snouty-genesis/
  SPEC.md PLAN.md CLAUDE.md README.md build.zig
  core/        md.zig m68k.zig m68k_tables.zig (generated) bus.zig vdp.zig
               psg.zig rom.zig
  cart/src/    main.zig frontend/{video,input,menu,rewind,splash,debug,
               romfs}.zig
  tests/       all.zig m68k_single_step.zig vdp_unit.zig bus_unit.zig
               romfs_unit.zig golden.zig determinism.zig roms/ (gitignored)
  tools/       fetch_test_roms.sh romcheck.py gen_m68k.py make_fat_image.py
               scripts/*.json
  roms/        the shipped ROM and its LICENSE
  docs/        ROM_STREAMING.md RUNNING.md, preview GIFs
```

Root `build.zig` gains one line in `carts`; root README gains a row.

## 16. Verification

- Host (`zig build test`): 68000 ProcessorTests (full set if it runs in
  under a minute, otherwise a committed sample per instruction class
  converted to a compact binary by a host script); VDP unit tests (plane
  sizes and scroll modes, window, priority, flips, sprite link list and
  per-line limits, shadow/highlight, DMA fill and copy, H-int counter,
  status and HV counter, column and line tables); bus tests (map, mirrors,
  arbiter stub, pads); FAT12 reader tests; golden frames; determinism.
- Simulator: the shipped ROM playable start to finish; preview GIF.
- badge-bench on the XIP ELF with the embedded ROM and the scripted run.
- Hardware (Adrian): XIP launch, a ROM copied to the USB drive and played,
  overlay numbers, OS overlay XIP hit and stall rates, streaming versus
  embedded time for the same ROM.

## 17. Milestones

Each milestone: a tag `snouty-genesis/mN`, a preview GIF in `docs/`, pull
and run notes. Parallel tracks go to Opus agents in git worktrees with
disjoint files.

- **M0 Scaffold**: this spec and PLAN.md, the cart wired into the root
  build (XIP only), `-Dmd-rom`, stubbed core showing a test pattern,
  `fetch_test_roms.sh`, `romcheck.py`, `.gitignore` entries, the shipped
  ROM chosen and committed with its LICENSE, badge-bench toml. Gate:
  Adrian confirms an XIP cart launches on the badge (shared with Snouty
  Gear M4 if that comes first).
- **M1 Core** (the risk milestone), four tracks: A `m68k.zig` + table
  generator + ProcessorTests harness; B `vdp.zig` + unit tests; C
  `bus.zig`, `rom.zig`, `md.zig` frame loop, frontend video, input and
  tone, golden test, RUNNING.md; D `z80bus.zig`, `ym2612.zig`, `psg.zig`,
  the Z80 hook-up and `Md.tone()`, sound unit tests. Done when: host
  tests green, the shipped ROM plays in the simulator with its music's
  lead line audible, badge-bench update mean under 31 ms and worst under
  33 ms. Gate: Adrian flashes it and reports overlay numbers.
- **M2 Streaming and frontend**: `romfs.zig` + FAT image tests + picker +
  no-ROM help screen; menu, splash, remap, scale and crop modes. Gate:
  Adrian copies Sonic 1 to the drive and reports update ms and XIP hit and
  stall rates, contiguous and fragmented.
- **M3 Scrub**: delta keyframes, input log, scrubbing,
  determinism test, record sizes measured with DMA-heavy scenes.
- **M4 Hardware polish**: tune from Adrian's numbers: RAM-text placement,
  a RAM cache for hot ROM ranges if the XIP stall rate calls for it,
  `render_every` and `cpu_scale` defaults, decode-table choice revisited
  against the ROM ceiling.
- **M5 Stretch** (pick with Adrian): a second voice if the OS ever offers
  one; the 6-button pad; a better note picker (envelope-aware). Firmware
  work (layout change, external flash) is out for this conference.

## 18. Decisions (closed 2026-09-29, Adrian)

1. Name: "Snouty Genesis", directory `carts/snouty-genesis`.
2. Shipped ROM: M0 researches licensed homebrew and, regardless, builds a
   small original test ROM from source in the repo (m68k GNU toolchain on
   the VM, binary committed) so the golden test and the badge build never
   depend on a third-party licence.
3. Sound: **minimum viable sound from M1**: the Z80 runs, the YM2612 and
   PSG are register models, one tone voice plays the loudest keyed-on
   channel (section 9). Not the silent M1-M4 route.
4. Speed: present at 30 Hz with two emulated frames per update;
   fallbacks in the order of section 8.
5. Genesis A on a Select tap; remap in the menu (M2).
6. External flash: not investigated; no firmware work for this conference.
7. Stock firmware; ROM ceiling about 840-990 KB (section 13).
8. SRAM saves: in-RAM only.
9. Start order: now, after Snouty Gear M1 (done 2026-09-29).

## Status

- 2026-09-29: spec drafted from the ROM-streaming investigation
  (`docs/ROM_STREAMING.md`); decisions in section 18 open. Nothing built.
- 2026-09-29 (later): Adrian closed section 18: execute now, sound from
  M1 (Z80 + register models + one voice), stock firmware. Sections 1, 2,
  7, 8, 9, 10, 11, 13 and 17 updated to match; M0 started on branch
  `genesis/m0`.
