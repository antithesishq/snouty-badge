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
`docs/ROM_DRIVE.md`); a licensed homebrew ROM is embedded as the fallback
and for the web simulator. Holding Select opens
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
is ignored). Register addresses per the Epyx "Handy" hardware spec; check
each in M0.

- Clock: 16 MHz master. CPU: 65SC02 inside Mikey (a 65C02 without the
  Rockwell bit instructions RMB/SMB/BBR/BBS), about 4 MHz; RAM cycles use
  page mode, so effective speed is lower than 4 MHz. Timing is modelled in
  16 MHz ticks.
- Memory: 64 KB RAM. `FC00-FCFF` Suzy, `FD00-FDFF` Mikey, `FE00-FFF7` boot
  ROM, `FFF8` reserved, `FFF9` MAPCTL (each of the four overlays can be
  switched off to expose RAM), `FFFA-FFFF` vectors (ROM or RAM per MAPCTL).
- Mikey:
  - 8 timers (`FD00-FD1F`, backup/control/count/control-B each), linkable.
    Timer 0 is the horizontal line timer, timer 2 counts lines and drives
    vertical blank; timer 4 is the UART baud clock.
  - 4 audio channels (`FD20-FD3F`), each a timer-clocked 12-bit LFSR with
    a feedback tap mask and a signed 8-bit volume, optional integrate mode.
  - Interrupts: INTRST/INTSET (`FD80/FD81`), one bit per timer.
  - Display: DMA from DISPADR (`FD94/FD95`), 160x102 at 4 bits per pixel
    (80 bytes per line, 8,160 bytes per frame), palette of 16 entries of
    12 bits (GREEN `FDA0-FDAF`, BLUERED `FDB0-FDBF`), DISPCTL flip bit.
  - Cart address: an 8-bit block number shifted in through IODAT/SYSCTL1
    strobes; within a block, an 11-bit ripple counter advances on every
    cart read. IODIR/IODAT (`FD8A/FD8B`) also carry the cart power/audin
    bit. UART and ComLynx: stubbed (idle line).
- Suzy:
  - Sprite engine: a linked list of sprite control blocks (SCB) from
    SCBNEXT, started by SPRGO (`FC91`). Per sprite: 1-4 bits per pixel,
    literal or run-length packed lines, a 16-entry pen map, position,
    8.8 horizontal and vertical size, stretch and tilt per line, H/V flip,
    drawing starting in one of four quadrants, eight sprite types
    (background, background-no-collide, boundary, boundary-shadow, normal,
    non-collide, xor-shadow, shadow) and a collision buffer with depository.
    The CPU is stopped while the sprite engine owns the bus.
  - Math unit (`FC52-FC6F`): 16x16 multiply to 32 bits (signed option,
    accumulate), 32/16 divide with remainder, started by register writes.
  - Joystick and switches (`FCB0/FCB1`), cart reads RCART0/RCART1
    (`FCB2/FCB3`).
- Boot ROM: 512 bytes, copyrighted, reads and decrypts the first cart block
  (the encrypted loader) into RAM and jumps to it. The emulator does not
  include it (section 11).

## 4. Accuracy target

Game-level accuracy, verified per title, not cycle accuracy.

- CPU: instruction-level, cycle counts per instruction in 16 MHz ticks
  including page-mode cost; interrupts between instructions. Passes the
  SingleStepTests 65x02 variant closest to the 65SC02 (section 16).
- Timers and interrupts: advanced per instruction by elapsed ticks, so
  line and frame interrupts land on the right instruction.
- Suzy: when SPRGO is written the whole sprite list is drawn at once, the
  CPU is charged an estimate of the bus time Suzy would have used (pixels
  written, bytes read), and SPRSYS reports done. Pixel output, collision
  buffer and depository values must be exact; drawing time is approximate.
- Display: a frame is converted from DISPADR at the start of vertical
  blank (games change DISPADR there to flip double buffers). Mid-frame
  palette changes are not seen.
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
core/cpu65.zig    65SC02 interpreter generic over a Bus type; written so a
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
ROM) and `-Dlynx-rom-source=drive|embed|pack` (default `drive` with the
embedded ROM as fallback; `pack` is section 13.1 and the only mode that
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
`tone2` only on change, once per frame. Menu toggle, default on. Sampled
audio (DAC writes through volume) is ignored.

## 10. Time scrubbing

Snouty Gear section 10's design unchanged: live console whole, keyframes
every 30 badge frames as undo records (first write to a 64-byte block
after a keyframe saves its old bytes; 1,024 blocks over 64 KB RAM, a
128-byte dirty bitmap), plus the chip registers whole per keyframe.
Suzy's writes go through the same block tracking.

Double-buffered games rewrite two 8 KB framebuffers every frame, so each
record carries up to ~16 KB of framebuffer blocks. Two mitigations,
measured in M3: framebuffer blocks may be excluded from the record and
re-rendered on restore by replaying from the keyframe (the replay already
runs for the determinism test), and records are zero-run RLE coded.
Target: at least 2 s of history with a 256 KB cart.

The ROM is read-only and not part of the console state; keyframes hold
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
- Shipped ROM: one with a license that allows redistribution, found in M0
  (cc65 examples, AtariAge homebrew with explicit licenses, or an original
  Snouty 3D demo built with cc65 as a stretch). Commercial ROMs never enter
  the repo or the cart.
- Checked at runtime too: the cart applies the same checks to the drive
  file and shows the reason on screen if it refuses one.
- Local stress targets (Adrian's copies, outside the repo; copied onto the
  badge drive, or embedded in a local simulator build with `-Dlynx-rom=`;
  the root `.gitignore` gains `*.lnx` and `*.lyx`):
  Hard Drivin' (polygon 3D, probably 128 KB), S.T.U.N. Runner (256 KB),
  Battlezone 2000, Checkered Flag, Blue Lightning (sprite scaling). Sizes
  confirmed from the dumps in M0. Atari's rights to the Lynx games are
  treated as commercial.

## 12. Boot splash and presentation

Snouty splash and chime, then the game. Menu title "SNOUTY LYNX", ROM name,
"verified by deterministic replay". The status strip under the picture
shows the ROM title; neopixels show ring depth in the menu only, at most
10/255 per channel.

## 13. Memory budget

Default build: RAM cart, ROM on the drive (costs no cart RAM). 268 KiB of
RAM after the stack.

| Item                                   | RAM            |
|----------------------------------------|----------------|
| Code, frontend, tables (ReleaseFast)   | ~90-100 KB     |
| Embedded fallback ROM (small homebrew) | ~16-32 KB      |
| Drive file map (fragmented case)       | <= 4 KB        |
| Console: 64 KB RAM + chip registers    | ~66 KB         |
| Keyframe ring                          | ~70-90 KB      |
| Frontend state, input log              | ~4 KB          |
| **Total**                              | **~250-296 KB** |

The top of the range does not fit, so the ring takes what is left after
the code is measured in M1 (target at least 64 KB), and the fallback ROM
stays small. ReleaseSmall for the frontend is the first lever if code
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
  opcode) using the variant whose opcode set matches the 65SC02; which
  one is an M0 check (the Rockwell bit instructions must be absent).
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
- Boot: `core/boot.zig` output for each local title equals a post-boot
  RAM dump from a reference emulator run by hand (M0).
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

## 18. Decisions (open, 2026-09-29)

1. Order: build after Snouty Gear reaches M3 (reuses its delta ring, bank
   packing experience and possibly the shared frontend; recommended), or
   in parallel now.
2. Boot path: the host packer performs the loader decryption itself from
   the public write-ups (recommended; nothing copyrighted on the badge or
   in the repo, constants to be checked for provenance in M0), or the
   packer reads Adrian's own `lynxboot.img` locally and never commits it.
3. Shipped ROM: decided in M0 from what is licensed; if nothing suitable
   exists, ship a cc65-built Snouty demo and keep commercial titles local.
4. Controls: Select tap = Option 1 and Option 2 in the menu (recommended),
   or Start+A chords for the options.
5. Screen: picture at the top with a 26-row strip below (recommended), or
   centred with 13-row bars.
6. Several `.lnx` files on the drive: list them in the menu and restart
   into the chosen one (recommended), or require exactly one.

## 19. Facts to check in M0

Everything in section 3, especially: 65SC02 opcode set and undefined
opcode behaviour; page-mode cycle costs; the cart block-select protocol
and counter width; SCB field layout and the packed-data format; the exact
sprite-type semantics for collision; the post-boot register state. Source
of truth: the Epyx hardware specification, cc65's `lynx.h`, and public
emulator source used as reference only (Handy is GPL; write Zig, do not
copy).

## Status

- 2026-09-29: spec drafted from the feat-of-strength discussion; decisions
  in section 18 open. Nothing built.
- 2026-09-29: switched to a RAM cart reading the ROM from the badge drive
  (Adrian; `docs/ROM_DRIVE.md`); the compressed flash cache is now the
  13.1 fallback, and boot decryption moved from a host tool into
  `core/boot.zig`.
