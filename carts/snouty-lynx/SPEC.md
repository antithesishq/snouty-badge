# Snouty Lynx: Atari Lynx emulator cart spec

Owner: Adrian Hatch (Antithesis). Target: SYCL Badge V2, 160x128 RGB565, 60 Hz.
Eighth cart in this repository and the third emulator, after
`carts/snouty-boy` (Game Boy, built) and `carts/snouty-gear` (Game Gear,
spec only). "Snouty Lynx" is a working title. Section 18 lists the open
decisions; status is at the bottom. Facts about the Lynx below come from
memory and public docs and are marked for checking in M0 where they drive
the design (section 19).

## 1. One paragraph

An Atari Lynx emulator written in Zig, built as the badge's technical feat
of strength: the Lynx's sprite-scaling "Suzy" graphics chip is what its
filled-polygon 3D games (Hard Drivin', S.T.U.N. Runner, Battlezone 2000,
Checkered Flag) draw with, so emulating it well puts real 1990s 3D on the
badge. The Lynx screen is 160x102, exactly the badge's width, so it is shown
1:1 with no scaling and 26 rows to spare for a status and scrub bar. The
game is a `.lnx` file the user copies onto the badge's USB drive, read in
place from flash by an ordinary RAM cart (shared design in
`docs/ROM_DRIVE.md`); a licensed homebrew ROM is embedded for the web
simulator only (the badge cart embeds none since 2026-10-04: a drive without
a usable ROM shows a no-ROM screen). Holding Select opens
the same menu and time scrubber as the other emulators, with the delta
keyframes designed for Snouty Gear.

## 2. Why the Lynx

From the 2026-09-29 discussion (what is the most advanced machine that
fits):

- Genesis: only 128 KB commercial titles fit even with a bank packer
  (Genesis RAM+VRAM ~130 KB leaves too little RAM for unpacked ROM).
  SNES, Neo Geo (Metal Slug), PS1 and later: no.
- The Lynx has real polygon 3D (drawn by the CPU into Suzy sprite spans),
  hardware sprite scaling, stretch and tilt, and a 4096-color palette. The
  CPU is a 65C02-class core at about 4 MHz, close to Game Boy cost to
  emulate; the work is in Suzy.
- State is small (64 KB RAM plus chip registers): code plus state is
  about 170 KB, so it is an ordinary RAM cart with about 100 KB for the
  rewind ring.
- Most carts are 128 or 256 KB (512 KB exists); all fit on the drive
  (about 950 KB free with this cart alone).
- Runner-up was PC Engine R-Type (256 KB HuCard), rejected because its
  256-wide screen must be cropped to 160 and its CPU costs about twice as
  much.

## 3. The machine being emulated

Atari Lynx (original and Lynx II behave the same for games; Lynx II stereo
is ignored). Register addresses per the Epyx hardware documentation
(monlynx.de mirror); every item was checked in M0, section 20 lists the
verdicts and sources.

- Clock: 16 MHz master. CPU: a 65C02 cell inside Mikey, about 4 MHz peak.
  It executes the Rockwell bit instructions RMB/SMB/BBR/BBS and has no
  WAI/STP ($CB, $DB are 1-byte NOPs) (corrected in M0: Felix's opcode
  table and 42Bastian's hardware-released size-coding carts use BBR/SMB;
  section 20). Opcode and operand fetches in page mode take 4 ticks, every
  other RAM/ROM read or write 5 ticks (corrected: Epyx CPU chapter, "a page
  mode op-code read takes 4 ticks, a normal read or write to RAM takes 5
  ticks"); hardware registers 5, Suzy reads 9-15, RCART reads 15. Timing
  is modelled in 16 MHz ticks.
- Memory: 64 KB RAM. `FC00-FCFF` Suzy, `FD00-FDFF` Mikey, `FE00-FFF7` boot
  ROM, `FFF8` always RAM, `FFF9` MAPCTL, `FFFA-FFFF` vectors (ROM or RAM
  per MAPCTL). MAPCTL: bit 0 Suzy, bit 1 Mikey, bit 2 ROM, bit 3 vectors
  (1 = RAM there), bit 7 disables sequential (page-mode) cycles; 0 after
  reset and at the loader's entry (Epyx hardware appendix; docs/BOOT.md).
- Mikey:
  - 8 timers (`FD00-FD1F`, BACKUP/CTLA/CNT/CTLB each), linkable in two
    chains: 0 -> 2 -> 4 and 1 -> 3 -> 5 -> 7 -> audio 0 -> 1 -> 2 -> 3 -> 1
    (Epyx timer chapter). Timer 0 is the horizontal line timer, timer 2
    counts lines and drives vertical blank; timer 4 is the UART baud
    clock. CTLA: bit 7 IRQ enable, 6 reset done, 4 reload, 3 count, 2-0
    clock (1 us .. 64 us, 7 = linked); CTLB bit 3 timer done.
  - 4 audio channels (`FD20-FD3F`, 8 registers each: VOLUME, FEEDBACK,
    OUTPUT, SHIFT, BACKUP, CONTROL, COUNTER, OTHER), each a timer-clocked
    12-bit LFSR with 9 selectable taps (bits 0-5, 7, 10, 11; tap 7 is
    CONTROL bit 7) and a signed 8-bit volume, optional integrate mode
    (CONTROL bit 5).
  - Interrupts: INTRST/INTSET (`FD80/FD81`), one bit per timer (bit 4 is
    the UART's, which replaces timer 4's).
  - Display: DMA from DISPADR (`FD94/FD95`), 160x102 at 4 bits per pixel
    (80 bytes per line, 8,160 bytes per frame), palette of 16 entries of
    12 bits (GREEN `FDA0-FDAF` low nibble, BLUERED `FDB0-FDBF` blue high
    / red low), DISPCTL (`FD92`: bit 1 flip, bit 0 DMA on; $0D normal).
    The high nibble is the left pixel.
  - Cart address: an 8-bit block number shifted in MSB first from IODAT
    bit 1 on each 0 -> 1 edge of SYSCTL1 (`FD87`) bit 0; the strobe held
    high also clears the 11-bit ripple counter, which advances on every
    RCART read. A cart wires as many counter bits as its block size needs
    (512 B = 9, 1 KB = 10, 2 KB = 11) (confirmed; Epyx cart chapter).
    IODAT (`FD8B`) bit 1 is also cart power (0 = on) and bit 4 AUDIN;
    SYSCTL1 bit 1 = 0 switches the Lynx off (added in M0). UART and
    ComLynx: stubbed (idle line).
- Suzy:
  - Sprite engine: a linked list of sprite control blocks (SCB) from
    SCBNEXT, started by SPRGO (`FC91`). Per sprite: 1-4 bits per pixel,
    literal or run-length packed lines, a 16-entry pen map, position,
    8.8 horizontal and vertical size, stretch and tilt per line, H/V flip,
    drawing starting in one of four quadrants (SE, NE, NW, SW), eight sprite
    types numbered 0 background-shadow, 1 background-no-collision, 2
    boundary-shadow, 3 boundary, 4 normal, 5 non-collidable, 6 xor-shadow,
    7 shadow (order corrected in M0: Epyx hardware appendix), and a
    collision buffer with the depository byte at SCB + COLLOFF (written for
    types 2, 3, 4, 6, 7). SCB: SPRCTL0, SPRCTL1, SPRCOLL, SCBNEXT, SPRDLINE,
    HPOS, VPOS, then HSIZ/VSIZ/STRETCH/TILT as SPRCTL1's reload depth
    says, then 8 palette bytes unless SPRCTL1 bit 3. Packed lines: an
    offset byte (0 end, 1 next quadrant), then packets of 1 literal bit + 4
    count bits (count + 1 pixels), header 0 ends the line; SPRCTL1 bit 7 is
    totally literal (section 20). The CPU is stopped while the sprite
    engine owns the bus.
  - Math unit (`FC52-FC6F`): 16x16 multiply to 32 bits (AB x CD = EFGH,
    started by writing MATHA `FC55`; SPRSYS bit 7 signed, bit 6 accumulate
    into JKLM), 32/16 divide with remainder (EFGH / NP, started by MATHE
    `FC63`, unsigned only).
  - Joystick and switches (`FCB0/FCB1`): the direction bits swap with
    SPRSYS's LEFTHAND bit (bit 3); cart reads RCART0/RCART1 (`FCB2/FCB3`).
- Boot ROM: 512 bytes, copyrighted. It selects block 0, reads one frame of
  1-5 RSA-encrypted 51-byte blocks (a count byte, then the blocks),
  decrypts it to $0200 and jumps there; loaders call its $FE00 (block
  select) and $FE4A (decrypt the next frame) routines again (corrected in
  M0: docs/BOOT.md). The emulator does not include it (section 11).

## 4. Accuracy target

Game-level accuracy, verified per title, not cycle accuracy.

- CPU: instruction-level, cycle counts per instruction in 16 MHz ticks
  including page-mode cost; interrupts between instructions. Passes the
  SingleStepTests 65x02 variant closest to the 65SC02 (section 16).
- Timers and interrupts: advanced per instruction by elapsed ticks, so
  line and frame interrupts land on the right instruction.
- Suzy: SPRGO latches the request; the list is drawn at once when the CPU
  sleeps (CPUSLEEP: on hardware Suzy only gets the bus while the CPU is
  asleep, and "sleep is broken in Mikey": without Suzy on the bus the CPU
  does not stay asleep, Epyx CPU chapter, confirmed by lynx-tests
  sdoneack). The CPU is charged a tick model fitted to the lynx-tests
  hardware timings (docs/SUZY.md) and an interrupt during the run wakes it
  with the run resumed on the next CPUSLEEP. Pixel output, collision buffer
  and depository values are exact (lynx-tests sprites1-5 pass); drawing
  time is approximate (within the suite's +-16 us windows).
- Display: DISPADR is latched when timer 2 reaches the third blank line;
  at the timer 2 borrow (vertical blank) the 8,160 bytes there and the
  palette are copied into the core's `display`, which the frontend shows
  (the last completed Lynx frame). Mid-frame palette changes are not seen.
  Video DMA and refresh steal bus time as timed events (ten 28-tick bursts
  per visible line, a 4-tick refresh every 256 ticks elsewhere), which is
  what makes the lynx-tests timers and page-mode rows pass.
- Not attempted: exact Suzy bus timing, UART/ComLynx, Lynx II stereo,
  rotated games (they need a 102x160 screen; the header's rotation byte
  makes `romcheck.py` refuse them).

## 5. Controls

| Badge                  | Lynx / emulator                                         |
|------------------------|---------------------------------------------------------|
| D-pad                  | D-pad                                                   |
| A                      | A (outer button)                                        |
| B                      | B (inner button)                                        |
| Start                  | Pause                                                   |
| Select, tap            | Option 1                                                |
| Select, hold 500 ms    | Emulator menu opens, game paused                        |
| Menu items             | "Press Option 2", "Press Pause + Option 1" (restart)    |
| In menu                | as Snouty Boy: Up/Down move, A choose, B resume,        |
|                        | Left/Right step time 0.5 s back and forward             |

Option 2 is rarely needed in play (it is mostly used with Pause to flip the
screen, which is disabled here), so it lives in the menu. Section 18 item 4.

## 6. Screen mapping

- 160x102 shown 1:1 at badge rows 0..101 (default) or centred at 13..114.
  Rows 102..127 (26 rows) hold a thin status strip: game title, FPS in
  debug builds, and the scrub bar while the menu is open.
- Conversion: each framebuffer byte is two pixels; a 256-entry table maps a
  byte to two palette indices, and a 16-entry `Pixel` cache (12-bit
  palette to RGB565, rebuilt on palette writes) gives the colors. Written
  column-major as the other carts do. About 16k pixels per converted frame.
- Frame pacing: games set their own refresh through timers 0 and 2 (60 Hz
  typical; 50 and 75 Hz exist). The cart runs 1/60 s of Lynx time (266,667
  ticks of 16 MHz) per badge frame and presents the last completed Lynx
  frame, so any refresh rate plays at the right speed.

## 7. Core architecture

Badge-agnostic core as in Snouty Boy and Snouty Gear: no `cart-api`, no
floats, no allocator, no clock, no randomness; the pad byte per frame is
the only input.

```
core/lynx.zig     Lynx struct (whole console), step_frame(pad), reset,
                  post-boot entry (section 11)
core/cpu65.zig    65C02 interpreter (Lynx set: bit instructions, no
                  WAI/STP) generic over a Bus type; written so a
                  6502/65C02 variant switch lets NES, 2600 or C64 reuse it
core/bus.zig      memory map, MAPCTL overlays, cart port and block select
core/mikey.zig    timers, interrupts, palette, display DMA source, audio
                  register model, IODAT/SYSCTL1 cart strobes
core/suzy.zig     SCB walker, sprite decoder (literal/packed, 1-4 bpp),
                  scaling/stretch/tilt, quadrants, sprite types, collision
                  buffer and depository, math unit, bus-time estimate
core/cart.zig     cart port over a block pointer table (from the drive file,
                  the embedded ROM, or the packed fallback of 13.1)
core/boot.zig     post-boot state: loader decryption and the register
                  state the boot ROM leaves (section 11)
```

Frontend: the console-agnostic modules from Snouty Boy / Snouty Gear
(menu, Select-hold state machine, input log, delta keyframe ring, tone2
voice setter). If Snouty Gear's M5 "shared frontend module" has landed,
use it; otherwise copy from Snouty Gear and note it for extraction.

Build: `carts/snouty-lynx/build.zig` with `-Dlynx-rom=path` (the embedded
ROM) and `-Dlynx-rom-source=drive|embed|pack` (default `drive`, no ROM in
the cart, a no-ROM screen when the drive has none; `pack` is section 13.1 and the only mode that
needs XIP). The wasm build always embeds.

## 8. Performance budget

150 MHz x 16.7 ms = 2.5 M host cycles per badge frame. The two costs trade
off: while Suzy draws, the emulated CPU is stopped, so a busy 3D frame
spends less on the CPU and more on Suzy.

| Part                                     | Target per frame | Host cycles per unit      |
|------------------------------------------|------------------|---------------------------|
| CPU, up to ~15k instructions             | <= 6.0 ms        | <= 60 per instruction     |
| Suzy, ~16k to 40k pixels drawn           | <= 5.0 ms        | <= 20 per pixel written   |
| Timers, interrupts, audio model          | <= 0.5 ms        |                           |
| Display conversion, 160x102              | <= 0.7 ms        | ~6 per pixel              |
| Cart reads from drive flash              | <= 0.5 ms        | XIP cache misses          |
| Frontend                                 | <= 0.3 ms        |                           |
| Total                                    | <= 12 ms mean    | worst under 14 ms         |

The instruction count is an estimate (a 4 MHz 65C02 averages 3 to 4
cycles per instruction, minus Suzy time and page-mode stalls) and is
measured in M1. Suzy's per-pixel cost is the main risk and the reason M1
benchmarks a 3D title early (section 17). Fallback knobs in
`tunables.zig`: Suzy span fast paths for unscaled literal sprites and for
solid runs, collision-buffer writes skipped when a sprite is
non-colliding, and, last, frame skip of the display conversion only (never
of emulation).

## 9. Audio

Four LFSR channels reduced to one `tone2` voice. A channel whose feedback
taps and shift pattern give a square wave (the common music setting) has a
pitch of timer rate / period; pick the loudest such channel (absolute
volume), ties by channel number; drop noise-like tap settings. Update
`tone2` only on change, once per frame. Menu toggle; the default comes from
`-Dsound` (off, root docs/SOUND.md). Sampled
audio (DAC writes through volume) is ignored.

## 10. Time scrubbing

Snouty Genesis M3's design (docs/SCRUB.md has it as built): the live
console is the newest keyframe; every 30 badge frames an undo record
closes. A record is the console's small state (`Lynx.Small`, 584 B = 10
slots: CPU, Mikey, Suzy, cart port, clocks, diagnostics; not the ROM,
`display` or `idle_sleep`) plus the old contents of every 64-byte RAM block
first written in its interval (1,024 blocks over 64 KB, one dirty byte per
block in `.bss`), in a ring of 68-byte slots in the run-time arena. A step
swaps one record with the console (Left and Right are the same operation,
bit-exact, no input log, no replay). Suzy's span writes, the `$FE4A`
decrypt trap and a boot re-run through ROM space go through the same
block tracking; the frontend forgets the history at reset.

Measured in M3 (tests/scrub_sizing.zig): the records are mostly
framebuffers, because games redraw every buffer every frame. raycast
triple-buffers (24 KB at $9F00-$FEFF): 405 slots = 27.5 KB per record.
Hard Drivin' and Blue Lightning double-buffer at $C000-$FFFF: 233-371
slots per record in play (16-25 KB). History held (closed records beside a
full open one, the second half of the run):

| Arena (free RAM - 1 KB guard)           | raycast | Hard Drivin' | Blue Lightning |
|-----------------------------------------|---------|--------------|----------------|
| ReleaseFast as built, 40,632 B          | 0 s     | 0 s          | 0 s            |
| ReleaseFast, exec un-inlined, ~88 KB    | 1.0 s   | 1.0 s        | 1.5 s          |
| ReleaseSmall, 120,296 B                 | 1.5 s   | 2.0 s        | 2.0 s          |
| XIP, 190,000 B                          | 2.5 s   | 3.5 s        | 4.0 s          |
| same, 60-frame records: un-inlined      | 2.0 s   | 2.0 s        | 3.0 s          |
| same, 60-frame records: ReleaseSmall    | 3.0 s   | 3.0 s        | 4.0 s          |

A 60-frame record holds the same buffer blocks as a 30-frame one, so it
doubles the history per byte at the price of 1 s steps. The 2 s target
(with the 256 KB cart) is met on raycast only by XIP or by 60-frame
records; the levers not built are zero-run coding of the slots and
leaving out the buffers not shown (docs/SCRUB.md).

The ROM is read-only and not part of the console state; records hold
only the cart port's block number and counter.

## 11. Boot and ROMs

- No boot ROM on the badge. `core/boot.zig` reads the `.lnx` header and
  produces the post-boot state: the loader decrypted into its RAM
  address, the registers and MAPCTL as the boot ROM leaves them, and the
  cart block counter where the boot ROM stops. It runs at `start()` on
  the badge (the ROM is only known once the drive file is found) and in
  host tests. The decryption is documented publicly (the annotated boot
  ROM, the Lynx encryption write-ups); where its constants come from is
  section 18 item 2. Homebrew built with cc65's `lynx` target goes
  through the same path.
- Requirements, checked by `tools/romcheck.py`: `.lnx` header ("LYNX"),
  bank 0 size 128, 256 or 512 KB, bank 1 empty, rotation none, no EEPROM (or
  EEPROM stubbed, logged as a warning).
- Shipped ROM: `roms/raycast.lnx`, 42Bastian's textured raycaster
  (Apache-2.0, `roms/LICENSE-raycast.txt`, 27 KB, headered, 1 KB pages;
  chosen in M0, `docs/ROM_CANDIDATES.md`). An original Snouty 3D demo
  built with cc65 stays a stretch. Commercial ROMs never enter the repo or
  the cart.
- Checked at runtime too: the cart applies the same checks to the drive
  file and shows the reason on screen if it refuses one.
- Local stress targets (Adrian's copies, outside the repo; copied onto the
  badge drive, or embedded in a local simulator build with `-Dlynx-rom=`;
  the root `.gitignore` gains `*.lnx` and `*.lyx`):
  Hard Drivin' (polygon 3D, 128 KB: confirmed from the dump, 512 B
  blocks, 3-block loader), S.T.U.N. Runner (256 KB),
  Battlezone 2000, Checkered Flag, Blue Lightning (sprite scaling). Sizes
  confirmed from the dumps in M0. Atari's rights to the Lynx games are
  treated as commercial.

## 12. Boot splash and presentation

Snouty splash and chime, then the game. Menu title "SNOUTY LYNX", ROM name,
"verified by deterministic replay". The status strip under the picture
shows the ROM title. The
neopixels are off: the cart never writes non-zero values (root
`docs/NEOPIXELS.md`; a coworker's badge shows the LEDs are unusably bright
even at 1%, 2026-09-29).

## 13. Memory budget

Default build: RAM cart, ROM on the drive (costs no cart RAM). 268 KiB of
RAM after the stack.

| Item                                   | RAM            |
|----------------------------------------|----------------|
| Code, frontend, tables (ReleaseFast)   | ~90-100 KB     |
| Embedded fallback ROM (small homebrew) | ~16-32 KB      |
| Drive file map (fragmented case)       | <= 4 KB        |
| Console: 64 KB RAM + chip registers    | ~66 KB         |
| Undo ring (M3: 27.5 KB per 0.5 s on raycast) | what is left (40 KB as built) |
| Frontend state, input log              | ~4 KB          |
| **Total**                              | **~250-296 KB** |

The top of the range does not fit, so the ring takes what is left after
the code is measured in M1 (target at least 64 KB), and the fallback ROM
stays small. Measured (M2/M3): ReleaseFast leaves 40,632 B, ReleaseSmall
120,296 B; a record costs 27.5 KB on raycast and 16-25 KB on the
double-buffered commercial games (section 10 table). ReleaseSmall for the frontend is the first lever if code
comes in high.

### 13.1 Fallback: ROM packed into the cart

Only if the drive path fails on hardware (`docs/ROM_DRIVE.md` section 6).
Then a 256 KB cart must live in the cart image, which needs an XIP cart:

| Item                                   | Flash (256 KiB)  | RAM (268 KiB)  |
|----------------------------------------|------------------|----------------|
| Code, frontend, tables (ReleaseSmall)  | ~80 KB           |                |
| Inflate decoder                        | ~10 KB           |                |
| ROM, 256 KB compressed (est. 55-60%)   | ~140-155 KB      |                |
| Console                                |                  | ~66 KB         |
| Cart block cache                       |                  | 96 KB (tunable)|
| Keyframe ring                          |                  | ~90 KB         |
| Frontend state                         |                  | ~4 KB          |
| **Total**                              | **~230-245 KB**  | **~256 KB**    |

- The Lynx cart is not memory-mapped (block select, then sequential
  reads), so the ROM can stay compressed in 16 KB groups of blocks and be
  inflated on a cache miss into an LRU cache; misses happen at level
  loads, not per frame. Group size is a tunable.
- `tools/pack_rom.py` writes the groups and an index; the core's block
  pointer table points into the cache.
- Flash is the tight side: the ratio is unknown until M0 compresses real
  dumps. Levers: zstd, better host compression, ReleaseSmall everywhere,
  and last, 128 KB titles only. This path also needs XIP proven on
  hardware.

## 14. Instrumentation

Overlay (mean and worst `step_frame` microseconds, FPS, Suzy pixels per
frame; the OS overlay's XIP hit and stall rates cover drive reads), `debug_*` exports for `tools/preview.mjs`,
`badge-bench/carts/snouty-lynx.toml` with a scripted run.

## 15. Repo layout

```
carts/snouty-lynx/
  SPEC.md PLAN.md CLAUDE.md README.md build.zig
  core/        lynx.zig cpu65.zig bus.zig mikey.zig suzy.zig cart.zig
  cart/src/    main.zig frontend/{video,input,menu,rewind,splash,debug,audio}.zig
  tests/       all.zig cpu65_single_step.zig suzy_unit.zig math_unit.zig
               timers_unit.zig cart_unit.zig determinism.zig golden.zig
               roms/ (gitignored)
  tools/       fetch_test_roms.sh romcheck.py pack_rom.py (fallback only)
               scripts/*.json   (romfs images: root tools/make_romfs.py)
  roms/        the shipped ROM and its LICENSE
  docs/        RUNNING.md, preview GIFs
```

## 16. Verification

- CPU: SingleStepTests 65x02 (github.com/SingleStepTests/65x02, JSON per
  opcode), variant `rockwell65c02/v1` (M0): the Lynx's 65C02 has the
  Rockwell bit instructions and no WAI/STP, which is the Rockwell set;
  `synertek65c02` (no bit instructions) and `wdc65c02` (WAI/STP) do not
  match. `tools/fetch_test_roms.sh` fetches 24 files (default) or streams
  all 256 (`--all`; all parse). Known deviations from the Lynx: cycle
  counts are 6502 cycles, the tick cost (4/5 per section 3) is ours;
  $5C is a 3-byte NOP of 4 cycles in the suite but 8 in Felix (not
  measured on hardware); M1 takes the suite's timings for every
  undefined opcode (docs/CPU.md lists them and the suite's dummy-read
  patterns). drhelius's MIT lynx-tests (cpu,
  page-mode, math, timers, sprites) are fetched too, for M1.
  Klaus Dormann's 6502/65C02 functional tests as a second opinion (GPL,
  test-only, never committed).
- Suzy: unit tests from synthetic SCBs: literal and packed lines at each
  bpp, pen maps, each sprite type, collision and depository values,
  quadrants and flips, scaling, stretch and tilt against hand-computed
  spans; math unit against Zig integer arithmetic for random operands,
  signed and accumulate modes included.
- Cart: every byte of the ROM read back through block select and
  sequential reads equals the file, for the drive source (a romfs image
  from `tools/make_romfs.py`, fresh and fragmented) and the embedded
  source; the packed source and cache eviction too if 13.1 is built.
- Boot: `core/boot.zig` against the real boot ROM run on a host 6502
  (`tools/bootrom_crosscheck.py`, `tests/boot_crosscheck.zig`; M0: both
  local titles match), plus public known-answer loaders (docs/BOOT.md).
- Golden frames: scripted runs of the shipped ROM and, locally only, the
  stress targets; frames reviewed by eye once and pinned by hash. Local
  cross-check against a reference emulator run by hand (Handy or
  Gearlynx), never a build dependency.
- Determinism: as Snouty Gear, with the framebuffer-exclusion replay path.
- Badge: badge-bench on the RAM ELF with a romfs image holding a 3D
  title and its scripted run; then hardware, including the drive checks
  in `docs/ROM_DRIVE.md` section 6.

## 17. Milestones

Tags `snouty-lynx/mN`, preview GIF, pull-and-run notes, Opus agents per
track in worktrees with disjoint files.

- **M0 Research and scaffold**: confirm section 3 registers against the
  hardware spec; pick the 65x02 test variant; settle the boot path
  (section 18 item 2) and prototype `core/boot.zig`; find the shipped ROM;
  record the per-16 KB compression of Adrian's dumps for 13.1 (cheap, in
  case the fallback is needed); cart directory wired into the root build
  with a test pattern; `romcheck.py`, `fetch_test_roms.sh`, badge-bench
  toml.
- **M1 Core** (risk milestone): tracks A CPU + tests, B Suzy + math unit
  + tests, C Mikey, bus, cart port over the drive and embedded sources,
  boot, frame loop, video.
  Done when: host tests green, the shipped ROM and one 3D title play in
  the simulator, badge-bench numbers recorded against section 8. Gate:
  Adrian copies the ROMs to the drive, ejects, flashes the RAM cart
  and reports the overlay numbers. If the drive path fails here, M4 adds
  the 13.1 fallback.
- **M2 Frontend**: menu, splash, status strip, audio to tone2, Option
  mapping, adapted from Snouty Gear.
- **M3 Scrub**: delta ring with the framebuffer mitigation, determinism
  test, depth measured.
- **M4 Perf**: Suzy fast paths from the bench profile, every stress target
  measured on hardware; the 13.1 packed fallback only if M1 needed it.
- **M5 Stretch** (pick with Adrian): an original Snouty polygon demo built
  with cc65; move `cpu65.zig` to a shared `lib/` for a NES cart; Lynx II
  stereo ignored cleanly; EEPROM saves to badge flash.

## 18. Decisions (closed 2026-09-30, Adrian)

1. Order: build now. Snouty Gear M3 (the page-store scrub ring, tag
   `snouty-gear/m3`) landed on 2026-09-30, so the ring is available for
   reuse from the start.
2. Boot path: the cart performs the loader decryption itself from the
   public write-ups (the annotated boot ROM disassembly and the community
   encryption documents); no boot ROM on the badge or in the repo. Adrian's
   own `lynxboot.img` (512 B, md5 fcd403db69f54290b51035d82f835e7b) is at
   `~/roms/lynx/lynxboot.img` on the VM, outside the repo, and serves two
   purposes only: a host-test cross-check that the public constants
   reproduce what the real ROM does, and a fallback if the public route
   turns out incomplete. It is never committed and never shipped.
   M0 result: the public route is complete (modulus from the annotated
   disassembly and lynx-encryption-tools, which agree); the cross-check
   matches for Hard Drivin' and Blue Lightning; the fallback was not
   needed. Without a ROM the emulator traps $FE00 and $FE4A
   (docs/BOOT.md).
3. Shipped ROM: our choice (Adrian, 2026-09-30): pick the best licensed
   homebrew in M0; if nothing suitable exists, ship a cc65-built Snouty
   demo. Parked stretch idea: port the Snouty Flyover voxel flyer
   (`carts/snouty-flyover`) to the Lynx as our own 3D showcase ROM; not on
   any plan yet. Commercial titles stay local:
   `~/roms/lynx/hard_drivin.lnx` and `~/roms/lynx/blue_lightning.lnx`
   (both 131,072 B, **headerless** dumps despite the `.lnx` name, so the
   loader and `romcheck.py` must accept a headerless file and infer the
   block size from the file size: 128 KB = 256 blocks of 512 B, 256 KB =
   1 KB blocks, 512 KB = 2 KB blocks; header present = trust the header).
4. Controls: as the other emulator carts. D-pad, A, B, Start = Pause,
   Select tap = Option 1, Select hold = menu, Option 2 lives in the menu;
   the menu has the A/B swap row that Snouty Boy and Snouty Gear have.
5. Screen: picture at the top with the 26-row strip below (rows 102..127).
6. Several `.lnx` files on the drive: list them in the menu and restart
   into the chosen one.

## 19. Facts to check in M0

Everything in section 3, especially: 65SC02 opcode set and undefined
opcode behaviour; page-mode cycle costs; the cart block-select protocol
and counter width; SCB field layout and the packed-data format; the exact
sprite-type semantics for collision; the post-boot register state. Source
of truth: the Epyx hardware specification, cc65's `lynx.h`, and public
emulator source used as reference only (Handy is GPL; write Zig, do not
copy). Done in M0: section 20.

## 20. Facts checked in M0

Checked 2026-09-30 against fetched sources (M0 Track A). Sources:
[HW] Epyx hardware appendix https://www.monlynx.de/lynx/hardware.html ;
[CPU] https://www.monlynx.de/lynx/lynx4.html ; [DISP] .../lynx5.html ;
[SPR] .../lynx6.html ; [CART] (cart and audio) .../lynx7.html ;
[TIM] .../lynx8.html ; [MATH] (math and I/O) .../lynx9.html ;
[BUGS] .../lynx10.html ; [CC65] https://github.com/cc65/cc65 include/_mikey.h,
_suzy.h, libsrc/lynx/bootldr.s, lynx-cart.s ; [FELIX] the Felix emulator,
https://github.com/laoo/Felix libFelix/Opcodes.hpp, CPU.cpp (read for facts
only) ; [SNAKE] 42Bastian's Snake249,
https://codeberg.org/42Bastian/lynx_hacking/raw/branch/master/248b/snake/snake.asm ;
[SC] http://www.sizecoding.org/wiki/Atari_Lynx ; [CYC] 42Bastian's hardware
cycle measurements, https://github.com/42Bastian/lynx_hacking/tree/master/cycle_check ;
[A] the annotated boot ROM,
https://forums.atariage.com/topic/191953-annotated-lynx-boot-rom/ ;
[H] https://github.com/dhuseby/lynx-encryption-tools ; [X] our cross-check
against the real ROM (docs/BOOT.md).

| Fact | Verdict | Source |
|---|---|---|
| 16 MHz master clock, timing in ticks | confirmed | [CART] |
| CPU is a 65C02 cell in Mikey, ~4 MHz peak | confirmed (wording: "65C02 cell", not a separate 65SC02) | [CPU] |
| No RMB/SMB/BBR/BBS | **corrected**: the Lynx runs them | [FELIX], [SNAKE], [SC] |
| No WAI/STP; $CB/$DB are 1-byte NOPs | confirmed | [FELIX] |
| STZ, BRA, PHX/PLX/PHY/PLY, TRB/TSB, (zp), INC/DEC A, BIT #/zp,X/abs,X, JMP (abs,X) | confirmed | [FELIX] |
| Undefined opcodes are NOPs: $x3/$xB 1 byte 1 cycle; $x2 2/2; $44 2/3; $54/$D4/$F4 2/4; $5C/$DC/$FC 3/4; $CB 1 byte 2 cycles; $DB 2 bytes 4 cycles (zp,X pattern) | confirmed per SingleStepTests (M1: all 256 opcodes pass; $5C is 4 there, 8 in Felix; $CB/$DB corrected from "1/1") | [FELIX], [CYC], section 16, docs/CPU.md |
| Decimal ADC/SBC take one extra cycle (65C02) | confirmed | [FELIX] |
| Page mode: opcode/operand fetch 4 ticks, other RAM/ROM access 5 ticks; MAPCTL bit 7 forces 5 | **corrected** (5 ticks is every data access, not only page breaks) | [CPU], [HW], [FELIX] |
| Other costs: hardware 5, palette 5, Suzy write 5, Suzy read 9-15, RCART 15 ticks | added | [CPU], [CART] |
| Memory map FC00 Suzy, FD00 Mikey, FE00-FFF7 ROM, FFF8, FFF9 MAPCTL, FFFA-FFFF vectors | confirmed; FFF8 is always RAM | [HW] |
| MAPCTL bits: 0 Suzy, 1 Mikey, 2 ROM, 3 vectors (1 = RAM), 7 sequential disable; 0 at reset | confirmed | [HW] |
| MAPCTL = 0 at the jump to $0200 | confirmed (the clear loop writes $FFF9) | [A], [X] |
| 8 timers FD00-FD1F, BACKUP/CTLA/CNT/CTLB | confirmed | [HW] |
| Timer 0 line, timer 2 vertical, timer 4 UART baud | confirmed | [TIM] |
| Link chains 0-2-4 and 1-3-5-7-audio0-3-1 | added | [TIM] |
| Audio FD20-FD3F, 8 registers per channel, 12-bit LFSR, integrate | confirmed; taps 0-5, 7, 10, 11 | [HW], [CART] |
| INTRST FD80 / INTSET FD81, one bit per timer | confirmed; bit 4 is the UART's | [HW], [TIM] |
| DISPADR FD94/95, DISPCTL FD92, PBKUP FD93 | confirmed; DISPADR's low 2 bits ignored, latched in vertical blank | [HW], [DISP] |
| Palette GREEN FDA0-AF, BLUERED FDB0-BF, 160x102 4 bpp, 80 B/line | confirmed; high nibble = left pixel | [HW], [DISP] |
| IODIR FD8A, IODAT FD8B, SYSCTL1 FD87 | confirmed | [HW] |
| Block select: 8 bits MSB first from IODAT bit 1 on SYSCTL1 bit 0 rising edges; strobe high clears the counter | confirmed | [CART], [CC65], [A], [X] |
| Counter: 11-bit ripple counter, the cart wires 9/10/11 bits for 512 B/1 KB/2 KB blocks | confirmed | [CART] |
| IODAT bit 1 = cart address data and cart power (0 = on), bit 4 AUDIN; SYSCTL1 bit 1 = 0 powers off | added | [HW], [MATH] |
| RCART0 FCB2 / RCART1 FCB3 | confirmed | [HW] |
| SCBNEXT FC10, SPRGO FC91, SPRSYS FC92, SPRCTL0/1 FC80/81, SPRCOLL FC82 | confirmed | [HW] |
| SCB layout and SPRCTL1 reload depth, palette skip bit 3 | confirmed | [SPR], [HW] |
| Packed data: offset byte, 1+4-bit packets (count + 1 pixels), totally literal mode | confirmed; a packet ending on bit 0 of a byte needs a pad byte (hardware bug) | [SPR], [BUGS] |
| Quadrant order SE, NE, NW, SW; flips about the reference point | confirmed | [SPR] |
| Sprite type numbering 0-7 | **corrected** (order: background-shadow, background-no-collision, boundary-shadow, boundary, normal, non-collidable, xor-shadow, shadow) | [HW], [SPR] |
| Depository at SCB + COLLOFF, written for types 2, 3, 4, 6, 7 | added | [SPR], [MATH] |
| Math unit FC52-FC6F; MATHA FC55 starts multiply, MATHE FC63 divide; SPRSYS signed/accumulate | confirmed; divide unsigned only, signed-multiply sign bugs | [MATH], [CC65] |
| Joystick FCB0 / switches FCB1 | confirmed; directions swap with SPRSYS LEFTHAND | [HW], [CC65] |
| Boot: one frame of 1-5 blocks (count byte $FB-$FF), 51-byte blocks, c^3 mod N, $15 check byte, running-sum obfuscation, loaded at $0200 | confirmed/**corrected** (not "the first cart block": a frame, and loaders re-enter the ROM at $FE00/$FE4A) | [A], [H], [X] |
| Registers at the jump: A = 0, X = 0, Y = 2, I = 1, Z = 1, C/V from the last add, SP = $01 if SP was 0 before reset | confirmed (SP is an assumption) | [A], [X] |
| Mikey after boot: TIM0 $9E/$18, TIM2 $68/$1F, PBKUP $29, DISPADR $2000, DISPCTL $0D, pens 0 and 15 black, IODIR 3, IODAT 2, SYSCTL1 2; Suzy untouched | confirmed | [A], [X] |
| Cart position after boot: block 0, counter 1 + 51 x blocks | confirmed | [X], [CC65] |

Still open: $5C's cycle count and the other undefined-opcode timings on
real hardware; SP before reset.

## Status

- 2026-09-29: spec drafted from the feat-of-strength discussion; decisions
  in section 18 open. Nothing built.
- 2026-09-29: switched to a RAM cart reading the ROM from the badge drive
  (Adrian; `docs/ROM_DRIVE.md`); the compressed flash cache is now the
  13.1 fallback, and boot decryption moved from a host tool into
  `core/boot.zig`.
- 2026-09-30: section 18 closed by Adrian (build now, public-write-up
  decryption with his boot ROM as a local cross-check only, controls as the
  other emulators, strip below, drive list). Hard Drivin' and Blue
  Lightning dumps received: headerless 128 KB files. M0 started on branch
  `lynx/m0`.
- 2026-09-30: M0 Track A (branch `lynx/m0-boot`): section 3 checked and
  corrected (section 20: the CPU has the bit instructions, 5-tick data
  cycles, sprite type order, boot frames), `core/boot.zig` cross-checked
  against the real boot ROM, SingleStepTests `rockwell65c02` chosen,
  `roms/raycast.lnx` (Apache-2.0) shipped.
- 2026-10-01: M1 core built (three Opus tracks, two fixers, a perf pass;
  PLAN.md). CPU passes all 256 SingleStepTests files; drhelius's
  lynx-tests pass every row except sprites4 DMA EXP W24; raycast.lnx,
  Hard Drivin' and Blue Lightning (local) run. Section 3/4 updated with
  the hardware findings (CPUSLEEP, display latch, DMA steal, undefined
  opcode timings); SP before reset and $5C on hardware still open.
- 2026-10-01: M2 (menu, picker) and M3 (scrubber) built. M3 integration:
  60-frame undo records and the un-inlined CPU dispatcher give 1-2 s of
  history in the RAM cart, short of section 10's 2 s; the XIP cart
  (built beside it, untested on hardware) would give 2.5-3.5 s. PLAN.md
  M3 status has the decision table for Adrian.
