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
30 Hz. The Z80 and the YM2612 FM chip are not emulated in M1-M4, so games
are silent. Holding Select opens the same emulator menu and time scrubber
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
- Snouty Gear's Z80 core is the Genesis sound CPU, so the M5 sound
  stretch reuses it.

It should start after Snouty Gear M1, so that the frontend, the delta
keyframes and the XIP numbers from the badge exist to copy from.

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
core/bus.zig      memory map, I/O and pads, Z80 bus arbiter stub, SRAM
core/vdp.zig      ports, control-word latch, VRAM/CRAM/VSRAM, DMA, counters,
                  interrupts, column and line tables, line renderer,
                  line_sink callback
core/psg.zig      SN76489 register model (68000-side writes only in M1-M4)
core/rom.zig      the RomSource interface (section 11), header parse,
                  byte order
```

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
| 68000, 2 x ~12,800 instructions       | <= 22 ms    | <= 130 per instruction      |
| VDP bookkeeping, DMA, interrupts, x2  | <= 1.5 ms   |                             |
| Render 128 lines x 160 px + sprites   | <= 4 ms     | <= 30 per output pixel      |
| Frontend (input, overlay, rewind)     | <= 0.5 ms   |                             |
| Total                                 | <= 28 ms    | worst update under 31 ms    |

(About 10 68000 cycles per instruction on average; measured in M1 from
the golden run.) Tunables in one `tunables.zig`:

- `render_every`: 2 by default (60/30); 1 for 60 Hz presentation if the
  numbers allow it, 3 for 20 Hz.
- `cpu_scale`: fraction of 128,008 cycles the 68000 gets per frame
  (underclock before dropping emulated frames; most games slow down
  gracefully). Default 1.0.
- Column averaging on or off; sprite evaluation on skipped lines off.

badge-bench models the embedded build with its flash as ordinary memory,
so it misses XIP cache misses on ROM fetches. Streaming cost is measured
only on the badge (section 16).

## 9. Audio

- **M1-M4: silent**, except 68000 writes to the PSG, which drive the one
  `tone2` voice as in Snouty Gear section 9 (few games do this).
- The Z80 is not run. The bus arbiter is stubbed so games do not hang:
  BUSREQ reports granted immediately, RESET is recorded, Z80 RAM is plain
  memory the 68000 can read and write, YM2612 status reads "not busy".
  Games that wait for a Z80 driver's handshake in Z80 RAM will hang;
  `tools/romcheck.py` cannot detect this, the golden run does.
- **M5 stretch**: run Snouty Gear's `z80.zig` (underclocked by a tunable)
  with a YM2612 register model and no synthesis. Pick the loudest keyed-on
  FM channel; its F-number and block give the frequency directly. One
  `tone2` voice, issued on change once per frame.

## 10. Time scrubbing

Delta keyframes, the design Adrian chose for Snouty Gear (section 10
there), because a full Genesis keyframe does not fit twice in RAM.

- State: work RAM 64 KB, VRAM 64 KB, CRAM/VSRAM 208 B, VDP registers and
  latch, 68000 registers, pads, PSG, counters: about 129 KB, plus
  cartridge SRAM if any (section 11), plus 8 KB Z80 RAM (the 68000 can
  write it even with the Z80 stopped).
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
- **Streamed from `romfs`** (badge only): `cart/src/frontend/romfs.zig`
  parses the FAT12 volume at `0x10080000` read-only and lists root files
  with extension `.GEN`, `.MD` or `.BIN` whose word at `0x100` reads
  "SEGA". One file starts directly; several give a picker at boot.
  Builds the cluster table (a 1 MB ROM is 2048 u16 entries, 4 KB),
  detects the contiguous fast path. Host-tested against FAT12 images made
  by `tools/make_fat_image.py` (contiguous, fragmented, long names,
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
"verified by deterministic replay". Neopixels show ring depth in the menu
only, at most 10/255 per channel. If no ROM is found on the drive, a help
screen says to copy a `.gen` file to the badge's USB drive.

## 13. Memory budget

XIP cart only. A RAM cart would have to hold the code (about 110 KB) and
about 137 KB of console state in the 268 KB window, leaving nothing for
the rewind ring. Estimates, measured with `size -A` at each milestone:

| Flash (256 KB cart window)           | Estimate   |
|--------------------------------------|-----------:|
| Code + frontend                      | ~110 KB    |
| 68000 decode table                   | 0-64 KB    |
| Render tables, fonts, splash         | ~8 KB      |
| Embedded ROM (badge build)           | 0-8 KB     |
| Total                                | 118-190 KB |

| RAM (~275 KB of XIP data window)      | Estimate   |
|--------------------------------------|-----------:|
| Live console (section 10) + Z80 RAM  | ~137 KB    |
| Cartridge SRAM (optional)            | 0-16 KB    |
| Cluster table, ROM up to 1 MB        | 4 KB       |
| RAM-text: 68000 core and line render | ~24 KB     |
| Frontend state, input log            | ~4 KB      |
| Left for rewind ring and ROM cache   | ~90-106 KB |

ROM size ceiling on stock firmware: `romfs` is 1280 KB, the cart's own
UF2 costs twice its flash image (236-380 KB), FAT and directory overhead
is about 8 KB. That leaves **about 890-1030 KB for ROMs** if nothing else
is on the drive: 512 KB titles fit comfortably, 1 MB titles only with the
64 KB decode table dropped and an otherwise empty drive. This is why the
flash image is kept small. A firmware layout change raises the ceiling
by about 380 KB (`docs/ROM_STREAMING.md`, section 18 item 7).

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
- **M1 Core** (the risk milestone), three tracks: A `m68k.zig` + table
  generator + ProcessorTests harness; B `vdp.zig` + unit tests; C
  `bus.zig`, `psg.zig`, `rom.zig`, `md.zig` frame loop, frontend video and
  input, golden test, RUNNING.md. Done when: host tests green, the shipped
  ROM plays in the simulator, badge-bench update mean under 28 ms and
  worst under 31 ms. Gate: Adrian flashes it and reports overlay numbers.
- **M2 Streaming and frontend**: `romfs.zig` + FAT image tests + picker +
  no-ROM help screen; menu, splash, remap, scale and crop modes. Gate:
  Adrian copies Sonic 1 to the drive and reports update ms and XIP hit and
  stall rates, contiguous and fragmented.
- **M3 Scrub**: delta keyframes, input log, scrubbing, neopixel meter,
  determinism test, record sizes measured with DMA-heavy scenes.
- **M4 Hardware polish**: tune from Adrian's numbers: RAM-text placement,
  a RAM cache for hot ROM ranges if the XIP stall rate calls for it,
  `render_every` and `cpu_scale` defaults, decode-table choice revisited
  against the ROM ceiling.
- **M5 Stretch** (pick with Adrian): Z80 + YM2612 register model to one
  tone voice (section 9); the firmware layout change proposed upstream;
  external flash if the board has it (section 18 item 6).

## 18. Decisions (open, 2026-09-29)

1. Name: "Snouty Genesis" as the working title and directory name?
2. Shipped ROM: research a licensed homebrew in M0, or build a small
   original Snouty ROM with SGDK (MIT) if none is clean.
3. Sound: silent in M1-M4 with Z80 + FM as the M5 stretch (recommended:
   the Z80 costs about a Game Gear's worth of CPU the 68000 needs), or run
   the Z80 from M1.
4. Speed: present at 30 Hz with two emulated frames per update and
   `cpu_scale` as the fallback (recommended), or aim for 60 Hz.
5. Genesis A on a Select tap (recommended), or another default mapping.
6. Does the V2 board have a second flash or PSRAM chip on QMI CS1? The
   simulator claims 2 MB external flash; the OS does not use any. Adrian
   checks the schematic; if yes, 2-4 MB ROMs become a firmware project.
7. Stay on stock firmware (recommended; ROMs up to about 900 KB), or
   propose the smaller OS region upstream for about 1.3 MB.
8. SRAM saves: in-RAM only (recommended), or a firmware write path later.
9. Start order: after Snouty Gear M1 (recommended), or in parallel.

## Status

- 2026-09-29: spec drafted from the ROM-streaming investigation
  (`docs/ROM_STREAMING.md`); decisions in section 18 open. Nothing built.
