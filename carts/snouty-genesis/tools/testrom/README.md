# Snouty test ROM

`roms/snouty-test.bin` (16384 bytes, header checksum `BCA2`) is an original
Genesis program written for this cart: the golden-test and badge-bench
target of M1, and the ROM embedded by default (`-Dmd-rom`). It uses no DMA,
no window, no plane B, no scrolling and no sprites beyond one, so every
feature it touches is one M1 must have anyway. Licence: MIT,
`roms/LICENSE-snouty-test`.

## Building

```sh
sudo apt-get install -y gcc-m68k-linux-gnu binutils-m68k-linux-gnu z80asm
tools/testrom/build.sh           # rebuild roms/snouty-test.bin
tools/testrom/build.sh --check   # rebuild and compare with the committed file
```

Built and verified with gcc 13.3.0 (Ubuntu 13.3.0-6ubuntu2~24.04), GNU
binutils 2.42 and z80asm 1.8 (Bas Wijnen's, Debian package `z80asm`). The
binary is committed, so nobody needs the toolchain to build the cart
(Adrian's Mac does not have it). The image depends only on the sources: no
`-g`, `-frandom-seed`, `--build-id=none`, a fixed section order in `md.ld`,
and `fixup.py` pads to 16 KB and fills in the header ROM end (`0x3FFF`) and
checksum (sum of the words from `0x200` to the end). Another gcc version may
produce different code; the committed binary is the reference.

| File | What |
|------|------|
| `crt0.s` | vectors, header at `0x100`, TMSS, stack, `.data`/`.bss`, the two interrupt stubs, `.incbin` of the Z80 driver |
| `main.c` | VDP, tiles, plane A, sprite, pad, PSG, Z80 loading, the interrupt handlers |
| `z80.s` | the Z80 driver (z80asm syntax), 264 bytes |
| `md.ld` | ROM at 0, RAM at `FF0000`, stack at `FFFE00` |
| `fixup.py` | padding and header checksum |

## Header

System `SEGA GENESIS`, copyright `(C)SNTY 2026.SEP`, domestic and overseas
name `SNOUTY TEST`, product `GM SNOUTY01-00`, I/O `J`, ROM `000000-003FFF`,
RAM `FF0000-FFFFFF`, no SRAM, region `JUE`. `tools/romcheck.py` passes it.

## Boot (before the first displayed frame)

1. Reset: SSP `00FFFE00`, PC `0x200`. `SR = 2700`. If the version register
   (`A10001`) has a non-zero hardware version, `"SEGA"` is written to
   `A14000` (TMSS; SPEC section 3 has no TMSS, so the core skips it).
2. `.bss` (4 bytes at `FF0000`: `hints`, `vblank`, `frame`) is cleared;
   there is no `.data`.
3. VDP registers (display off, V-int off, H-int enabled in register 0):

   | Reg | Value | Meaning |
   |----:|------:|---------|
   | 0 | `14` | H-int on |
   | 1 | `04` then `64` | mode 5; later display on + V-int on, V28 |
   | 2 | `30` | plane A at `C000` |
   | 3 | `34` | window at `D000` (unused) |
   | 4 | `07` | plane B at `E000` (all tile 0) |
   | 5 | `6C` | sprite table at `D800` |
   | 7 | `00` | backdrop = palette 0 colour 0 |
   | 10 | `6F` | H-int counter 111 |
   | 11 | `00` | full-screen H and V scroll |
   | 12 | `81` | H40 |
   | 13 | `37` | H scroll table at `DC00` (all zero) |
   | 15 | `02` | auto-increment 2 |
   | 16 | `01` | planes 64x32 cells |
   | 6, 8, 9, 14, 17, 18 | `00` | |

4. All 64 KB of VRAM and the 40 VSRAM words are cleared through the data
   port (32768 word writes: about 1.1 M 68000 cycles, the bulk of the boot
   time), then CRAM: palette 0, palette 1, palettes 2-3 zero.
5. Tiles and plane A are written, the sprite entry and the counters
   (`0000`, `00`) are written.
6. PSG: all four channels silenced, then tone 0 period `0x1FC` (220.2 Hz)
   at attenuation 4. Bytes written to `C00011`: `9F BF DF FF 8C 1F 94`.
7. Z80: `0100` to `A11100` (BUSREQ), `0100` to `A11200` (out of reset),
   wait until bit 8 of the word at `A11100` reads 0, copy the 264 driver
   bytes to `A00000`, `0000` to `A11200` (reset), a short delay, `0000` to
   `A11100` (release), `0100` to `A11200` (run). The Z80 starts at 0.
8. Register 1 = `64` (display on, V-int on), `SR = 2300` (levels 4 and 6
   accepted).

The display comes on roughly 12 frames after reset (about 1.5 M cycles of
setup; M1 measures the exact frame). Until then the screen is blank
(display off shows the backdrop colour on real hardware). H-int is enabled
in register 0 from the start but masked by `SR` until step 8, so an
emulator that latches a pending H-int may take one at once when `SR`
drops: the partial first frame can turn dark red early. From the first
V-int on, every frame is as below.

## Palettes

Palette 0: 0 `0800` dark blue (backdrop above the raster line), 1 `0EEE`
white, 2 `000E` red, 3 `00E0` green, 4 `0E00` blue, 5 `00EE` yellow, 6
`0E0E` magenta, 7 `0EE0` cyan, 8 `0888` grey, 9 `006E` orange, 10 `0060`
dark green, 11 `0806` purple, 12 `0E86` light blue, 13 `088E` pink, 14
`0246` brown, 15 `0000` black. Palette 1 (sprite): 0 transparent, 1 `00EE`
yellow, 2 `0000` black, 3 `004E` orange. CRAM colour format `0BBB0GGG0RRR0`.

## Tiles

| Index | Content |
|------:|---------|
| 0 | blank |
| 1 | grid: row 0 and column 0 grey (8), rest transparent |
| 2 | vertical stripes: even x red (2), odd x green (3) |
| 3 | horizontal stripes: even y blue (4), odd y yellow (5) |
| 4 | diagonal: pixel (i, i) white (1), rest transparent |
| 5-19 | solid colour 1-15 (tile 5 + n - 1 is colour n) |
| 32-47 | hex digits 0-F, white (1) on black (15) |
| 48-51 | the 16x16 sprite, column-major (TL, BL, TR, BR): black (2) 1-pixel border, yellow (1) fill, orange (3) 4x4 centre at pixels 6-9 |

## Plane A (visible 40x28 cells; palette 0, no flips, low priority)

| Rows | Cells |
|------|-------|
| 0-3, 8-9, 14-15, 18-19, 24-27 | grid (tile 1): an 8-pixel grey grid over the backdrop |
| 1 | cols 1-4: the frame counter, 4 hex digits; cols 7-8: the pad byte, 2 hex digits (the rest of row 1 is grid) |
| 4-7 | vertical stripes (tile 2): 1-pixel red/green columns |
| 10-13 | horizontal stripes (tile 3): 1-pixel blue/yellow lines |
| 16-17 | colour ramp: column c is solid colour 1 + (c mod 15) |
| 20-23 | diagonal (tile 4): 45-degree white lines through each cell |

What the badge's 320x224 to 160x128 mapping should show: keeping every
other column turns the vertical stripes into solid red (or green, if the odd
columns are kept) and a blend if columns are averaged; dropping lines
breaks the horizontal stripes into an irregular blue/yellow pattern and
the diagonals into staircases; the grid lines disappear in every dropped
column or line, so the dropped ones can be read off the grid directly.

## Every frame

The V-int handler (level 6, vector 30) increments `frame` (u16 at
`FF0002`), sets `vblank`, resets the H-int count and writes backdrop
colour `0800` (dark blue) to CRAM 0. The main loop, released by `vblank`,
then during the same vertical blank:

1. Reads pad 1 (TH high: `C B R L D U`; TH low: `Start A`), as a byte with
   1 = pressed: bit 0 up, 1 down, 2 left, 3 right, 4 B, 5 C, 6 A, 7 Start.
2. Moves the sprite: Start puts it back at the start position; each held
   direction moves it 1 pixel (2 with B held) that frame, clamped to
   x 0-304, y 0-208 (screen pixels). Start position: x 152, y 104 (sprite
   table values 280 and 232, i.e. +128). Up and down together, or left and
   right together, cancel only at the clamp: both are applied in order
   left, right, up, down.
3. Writes sprite 0 at `D800`: y + 128, `0500` (2x2 cells, link 0), `2030`
   (palette 1, tile 48, low priority), x + 128.
4. Writes `frame` as 4 hex digits at plane A row 1 cols 1-4, and the pad
   byte as 2 hex digits at cols 7-8. So the frame displayed after V-int n
   shows `n` (the first displayed frame shows `0000`, the next `0001`...).
5. A held: PSG tone 0 muted (`9F`); released: attenuation 4 again (`94`).
   Only changes are written.

The H-int handler (level 4, vector 28): register 10 = 111, so H-int fires
after line 111 and again after line 223 (every 112 lines). The first one of
the frame writes backdrop colour `0008` (dark red) to CRAM 0; the second
changes nothing. So the backdrop (visible through the grid and diagonal
cells, not through the stripes or the ramp) is dark blue on lines 0-111
and dark red on lines 112-223, give or take one line depending on where in
the line the emulator lets the CRAM write land.

## Sound

- PSG: tone 0 at 220.2 Hz (period `0x1FC`, 3579545 / 32 / 508),
  attenuation 4, from the end of boot; channels 1-3 and noise silent. A
  mutes it while held.
- YM2612, from the Z80 driver: channel 1 (part I, channel index 0),
  algorithm 4, feedback 0; operator 1 (modulator) TL `1C`, operator 2
  (carrier) TL `08`, operators 3 and 4 TL `7F` (muted); all MUL 1, DT 0,
  AR 31, D1R 0, D2R 0, SL 0, RR 15, SSG-EG off; `B4 = C0` (both speakers).
  LFO off, timers off, DAC off, every channel keyed off first.
- Notes: key on (`28 = F0`) at A4 (`A4 = 24`, `A0 = 3A`: block 4, F-number
  1082, 439.73 Hz) as soon as the driver starts, i.e. during boot, before
  the display comes on. On every 30th Z80 interrupt after that the driver
  keys off (`28 = 00`), writes the other note and keys on again: E5 (`A4 =
  26`, `A0 = 56`: block 4, F-number 1622, 659.17 Hz), then A4, and so on.
  Frequencies use the YM2612 clock, the 68000 clock 53693175 / 7 Hz:
  `f = fnum * 2^(block - 1) * 53693175 / (7 * 144 * 2^20)`.
- The Z80 counts its own interrupts (V-int INT, one per frame, from the
  moment it is released, whether or not the 68000's V-int is enabled), so
  the toggles land on frames R + 30, R + 60, ... where R is the frame in
  which the 68000 released the Z80 (a few frames before the display comes
  on). Between interrupts it sits in `HALT`.

Z80 driver memory: code `0000-0107`, `vcount` at `1F00`, `note` at `1F01`
(0 = A4, 1 = E5), stack below `2000`. It writes the YM2612 only through
`4000`/`4001` (part I) and polls the busy flag (bit 7 of `4000`) before
each address and data write, so a YM2612 model that reads "not busy" is
enough.

## Verified so far (M0, statically)

The ROM has not been run: no emulator exists yet. Checked: the build
reproduces the committed binary (`build.sh --check`); `romcheck.py` parses
the header and matches the checksum; `m68k-linux-gnu-objdump -d` shows
68000-only code (assembled with `-m68000`, no libgcc calls, no unresolved
symbols) with the handlers on vectors 28 and 30; the Z80 bytes were
assembled from `z80.s` and the listing (`z80asm -l`) matches the comments.
M1's golden test is the first run; expect to fix the ROM then if it
disagrees with a reference emulator.
