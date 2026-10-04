# Snouty Lynx: plan

SPEC.md is the design. This file is the working contract for the current
milestone. Nothing below starts until Adrian has answered SPEC.md
section 18 (item 1 decides whether this waits for Snouty Gear M3).

## M0 Research and scaffold (two tracks, then me)

Execution 2026-09-30: integration branch `lynx/m0` in worktree
`/home/exedev/snouty-badge-lynx`. Track A "boot" (branch `lynx/m0-boot`,
worktree `-lynx-boot`): facts check, CPU test choice, `core/boot.zig` with
host tests, cross-check against the local boot ROM, ROM candidates with
licences, compression numbers. Track B "scaffold" (branch `lynx/m0-scaffold`,
worktree `-lynx-scaffold`): cart skeleton, build wiring, ROM source
(drive/embed), romfs images, bench toml, gitignore, byte-identical check.
Integration: merge both, `zig build` + `zig build test`, sizes, tag
`snouty-lynx/m0`, push `lynx/m0:main`.


- Facts: check every SPEC.md section 3 register and section 19 item
  against the Epyx hardware spec and cc65's `lynx.h`; write corrections
  into SPEC.md with the source.
- CPU tests: pick the SingleStepTests 65x02 variant matching the 65SC02;
  sparse fetch in `tools/fetch_test_roms.sh`.
- ROMs: Adrian's dumps are at `~/roms/lynx/` on the VM (outside the
  repo): `hard_drivin.lnx`, `blue_lightning.lnx` (both 128 KB, headerless;
  SPEC 18.3) and `lynxboot.img` (SPEC 18.2). Record per-16 KB compression
  (for the 13.1 fallback). Headerless files are accepted everywhere the
  `.lnx` header is (block size from file size).
- Boot path per section 18 item 2: implement the loader decryption in
  `core/boot.zig` from the public write-ups (host-tested). Verification:
  a host-only test (skipped when the file is absent) runs Adrian's
  `~/roms/lynx/lynxboot.img` on the 65SC02 core against the real cart
  image and compares the RAM the two routes leave; the decrypted loader
  must also disassemble to sane 65SC02 code that jumps to the loaded game.
  If the public route is incomplete, the packer/boot uses constants read
  from the local image and SPEC 18.2 records it.
- ROM source per `docs/ROM_DRIVE.md`: `-Dlynx-rom-source=drive|embed`, the
  shared romfs parser (reuse it if Snouty Gear or Snouty Genesis built it
  first), romfs images for host tests and badge-bench.
- Shipped ROM candidates with licenses, as Snouty Gear section 11 did.
- Scaffold: `carts/snouty-lynx/` per SPEC.md section 15, root `build.zig`
  line, `-Dlynx-rom`, test pattern, `*.lnx`/`*.lyx` in the root
  `.gitignore`, badge-bench toml.
- Done when: the RAM cart builds, `zig build test` passes, other carts'
  uf2 byte-identical, and the ROM sizes are recorded.

## M1 Core: contract

Written 2026-10-01 after M0. Three Opus agents in their own git worktrees
and branches off the prep commit on `lynx/m1`, disjoint files, as Snouty
Gear's M1 did. Nobody edits another track's files; a needed change goes in
the final report and is stubbed locally. The prep commit holds compiling
stubs of every frozen interface below (`zig build -Dcart=snouty-lynx` and
`zig build test-lynx` pass with them), and `tests/all.zig` already imports
every test file a track will fill (`suzy_unit`, `math_unit`, `mikey_unit`,
`golden`), so no track touches `tests/all.zig` or `build.zig`.

Done when (SPEC.md section 17): host tests green (SingleStepTests on the
CPU, Suzy and math unit tests, Mikey tests, drhelius lynx-tests carts), the
shipped `roms/raycast.lnx` and Hard Drivin' (local) play in the simulator,
badge-bench numbers recorded against SPEC.md section 8, tag
`snouty-lynx/m1`, merged to main (the badge gate is show day).

### Frozen for M1: `core/lynx.zig` is the bus

- `Lynx` keeps the M0 frontend-facing shape: `init_in_place(c: Cart)`,
  `reset()`, `step_frame(pad: u16)`, `frame() Frame`, fields `cart`, `pad`,
  `frame_count`; `Pad` bits (JOYSTICK layout, bit 8 Pause) and `Frame`
  (`pixels: *const [8160]u8`, `green`, `bluered`) are unchanged.
- `Lynx` is also the CPU's bus: `pub const Cpu = cpu65.Cpu(Lynx)` and
  `Lynx` has `fetch(addr: u16) u8`, `read(addr: u16) u8`, `write(addr: u16,
  v: u8) void`, `irq_line() bool` (bodies in `core/bus.zig`, bound into the
  struct with `pub const fetch = bus.fetch;` etc.). Tick accounting is the
  bus's: `fetch` adds 4 (5 when MAPCTL bit 7 is set), RAM `read`/`write` 5,
  Mikey/Suzy writes 5, Suzy reads 9 (SPEC.md section 3: 9-15; one value is
  fine), RCART reads 15, all into `Lynx.ticks` (u64 at first; u32 from
  `tick_base` since the M1 perf pass, `time()` is the 64-bit clock).
- Memory map and MAPCTL (SPEC.md 3, 20): `$FC00-$FCFF` Suzy unless bit 0;
  `$FD00-$FDFF` Mikey unless bit 1; `$FE00-$FFF7` ROM unless bit 2;
  `$FFFA-$FFFF` vectors unless bit 3; `$FFF8` always RAM; `$FFF9` MAPCTL
  always. ROM-space reads return `boot.vector_*` for the six vector bytes
  and `0x00` elsewhere (never ROM bytes). Suzy `$B0-$B3` are the bus's:
  JOYSTICK = pad low byte with the direction bits swapped when
  `suzy.lefthand()`, SWITCHES = Pause (bit 0) plus cart-in bits as the
  hardware reads them, RCART0/1 = cart port reads (counter advances).
- Boot (docs/BOOT.md "What M1 needs"): `reset()` runs `boot.post_boot`
  over the cart port, applies `mikey_writes` through `Mikey.write`, sets
  MAPCTL/IODIR/IODAT/SYSCTL1, the port position and the CPU registers.
  Before each instruction, while MAPCTL bit 2 is clear: PC == `$FE00`
  does the block select with A, sets `SetCartBlockExit`, performs the RTS
  (pulls the return address, PC + 1), charges ~300 ticks; PC == `$FE4A`
  runs `boot.decrypt_frame` over the port, applies `frame_mikey_writes`,
  sets A/X/Y, merges `nvzc` into P, PC = `$0200`; a PC anywhere else in
  `$FE00-$FFF7` (an IRQ taken through ROM vectors, a crash) re-runs
  `reset()`. `core/boot.zig` loses its own `Cart`: `post_boot` takes the
  reader (`anytype` with `read_byte`), and the boot tests build the reader
  over `core.cart.Cart` (`tests/boot_*.zig` are Track C's to adjust).
- Frame loop: `step_frame` runs until `ticks` has advanced by 266,667
  (16,000,000 / 60; the remainder is carried in `frame_frac`), one
  `cpu.step(l)` at a time, then `mikey.advance(dt)` with the ticks the
  step charged. CPUSLEEP (`$FD91` write): if `suzy.sprites_pending()`,
  `ticks += suzy.run_sprites(&ram)` (the CPU wakes when Suzy is done; on
  hardware Suzy only gets the bus while the CPU sleeps, so SPRGO alone
  draws nothing); else the CPU sleeps until Mikey's next interrupt (ticks
  jump there, capped at the frame end; the sleep persists across
  `step_frame` calls if no interrupt comes).
- Display: when timer 2 fires (vertical blank), the 8,160 bytes at the
  latched DISPADR (low two bits ignored) and the palette are copied into
  `Lynx.display` (`pixels: [8160]u8`, `green`, `bluered`); `frame()`
  returns that. DISPCTL bit 1 (flip) ignored in M1 (noted).
- Diagnostics (SPEC.md 14, frontend overlay): `ticks`, `cpu.instr_count`,
  `suzy.pixels_drawn`, `sleep_ticks` (ticks spent asleep), `irq_count`.
- Keyframes (M3) will copy `Lynx` minus `cart` and `display`.

### Frozen for M1: `core/cpu65.zig` (Track A)

- `Cpu(comptime Bus: type)`: `regs: Regs` (a, x, y, s, p, pc), `instr_count:
  u32`, `reset(bus)`, `step(bus)`. `step` samples `bus.irq_line()` before
  the opcode fetch; when set and I is clear it runs the 7-cycle IRQ
  sequence (push PCH, PCL, P with B clear and bit 5 set; I set; D cleared
  as the 65C02 does; PC from `read($FFFE/$FFFF)`) instead of an
  instruction. No NMI.
- Bus calls: `fetch` for opcode and operand bytes, `read` for every other
  read including dummy reads, `write`. Exactly the bus cycles the hardware
  does, in order: the SingleStepTests `cycles` lists (address, value,
  read/write) are the reference and the test compares them cycle by cycle.
  P reads with bits 4 and 5 set.
- Instruction set: the full 65C02 (BRA, STZ, TRB/TSB, PHX/PHY/PLX/PLY, INC/
  DEC A, BIT #/zp,X/abs,X, (zp), JMP (abs,X), decimal mode with the fixed
  N/Z and the extra cycle) plus RMB0-7/SMB0-7/BBR0-7/BBS0-7; `$CB`/`$DB`
  and every other undefined opcode are NOPs with the byte count and cycle
  count the suite shows (SPEC.md 20: `$x3`/`$xB` 1/1, `$x2` 2/2, `$44` 2/3,
  `$54`/`$D4`/`$F4` 2/4, `$DC`/`$FC` 3/4, `$5C` 3/8 in the suite's
  rockwell variant: take the suite's). Page-crossing extra cycles and the
  65C02's dummy-read addresses per the suite.

### Frozen for M1: `core/suzy.zig` (Track B)

`Suzy` with `reset()`, `read(addr: u8) u8`, `write(addr: u8, v: u8) void`
(never called for `$B0-$B3`), `sprites_pending() bool`,
`run_sprites(ram: *[0x10000]u8) u32` (ticks to charge), `lefthand() bool`,
`pixels_drawn: u32`. Math unit operations complete inside `write`. See the
file comment for the register map. Everything Suzy touches is in `ram`.

### Track A: CPU (files `core/cpu65.zig`, `tests/cpu65_single_step.zig`, `tests/roms/65c02/*` via `tools/fetch_test_roms.sh`)

- Implement `step` per the frozen contract: a 256-entry switch (no
  comptime-generated tables bigger than a few hundred bytes: Adrian's Mac
  runs out of memory on heavy comptime), addressing-mode helpers that
  issue the exact dummy cycles, flags, decimal mode, interrupts.
- `tests/cpu65_single_step.zig`: `run_case` on a flat 64 KB test bus that
  logs every `fetch`/`read`/`write` as the suite does ("read" for both
  fetch and read); compare final registers, every RAM entry of `final`,
  the cycle count and the per-cycle address/value/kind. All 24 fetched
  files (240,000 cases) must pass; then run `tools/fetch_test_roms.sh
  --all` with `LYNX_SST_CMD` pointed at the test binary so all 256
  opcodes pass (record the results in the report; the files are not kept).
  A mismatch that is a documented suite quirk (none known) goes in the
  report, never a skip.
- Record the host run time of the suite and the instruction mix of a
  quick count (how many `fetch`/`read`/`write` calls per instruction on
  average) so the integrator can sanity-check the tick model.
- Also a `tests/roms/lynx-tests/cpu.lnx` note: the cart tests need the
  whole machine, so Track C's golden runs them; Track A does not.

### Track B: Suzy (files `core/suzy.zig`, `tests/suzy_unit.zig`, `tests/math_unit.zig`, `docs/SUZY.md`)

- Register file `$00-$92` as the Epyx hardware appendix defines it
  (`SPRCTL0`/`SPRCTL1`/`SPRCOLL` are per-sprite and loaded from the SCB;
  the CPU-written copies and the engine's working registers share the
  addresses; reads of the 16-bit engine registers return the current
  values).
- Sprite engine on `run_sprites`: walk from SCBNEXT until a zero link or
  SPRCTL1 bit 2 (skip sprite) handling; per sprite load the SCB per the
  reload depth, the pen map unless bit 3, then draw: quadrant order from
  the start quadrant with H/V flips, 8.8 HSIZ/VSIZ scaling accumulators
  with HSIZOFF/VSIZOFF, STRETCH (per line) and TILT (per line), the
  literal/packed decoders at 1-4 bpp (offset byte, packets of a literal
  bit and a 4-bit count, header 0 ends the line, totally literal mode,
  the pad-byte hardware quirk of SPEC.md 20), the eight sprite types'
  pixel and collision semantics (which pens are transparent, what writes
  to the video buffer, what writes/reads the collision buffer, the
  depository byte at SCBADR + COLLOFF for types 2, 3, 4, 6, 7 unless
  SPRSYS no-collide or SPRCOLL bit 5), clipping to 0..159 x 0..101 with
  HOFF/VOFF, the video buffer at VIDBAS and the collision buffer at
  COLLBAS (80 bytes per line, high nibble left), everon (SPRGO bit 2
  sets SPRCOLL bit 7 in the depository when the sprite was fully off
  screen). SPRSYS read: bit 0 sprite working (0 after the run), bit 7
  math in progress (0), bit 6 math warning, bit 5 last carry, bit 2
  unsafe access.
- Bus-time estimate returned by `run_sprites`: per sprite header ~ 50
  ticks, per source byte read 5, per pixel written 5 plus per collision
  buffer access 5 (document the model in `docs/SUZY.md`; it is tuned in
  M4).
- Math unit: AB x CD -> EFGH (unsigned; signed via SPRSYS bit 7 with the
  sign-magnitude conversion the hardware does), accumulate into JKLM
  (SPRSYS bit 6, with the overflow -> warning bit), EFGH / NP -> ABCD
  with remainder in JKLM (unsigned; divide by zero sets the warning and
  gives all ones), the register byte order and which write starts what
  (MATHA `$55` multiply, MATHE `$63` divide; writing MATHC/MATHA and
  MATHM/MATHE also zeroes their partner high bytes as the appendix says).
- Tests: synthetic SCBs in a 64 KB RAM: literal and packed lines at each
  bpp, pen maps, each sprite type's pixel and collision result, the
  depository, each quadrant and flip, HSIZ/VSIZ scaling (1x, 2x, 0.5x),
  stretch and tilt against hand-computed spans, clipping, everon, and
  random-operand math against Zig arithmetic (signed, accumulate,
  divide, warning cases). `docs/SUZY.md`: what is exact, what is
  approximate, the open questions (hardware behaviour not in the docs).
- Facts come from the Epyx appendix (monlynx.de lynx6/lynx9) and cc65's
  `_suzy.h`; Felix (MIT) may be read for behaviour the docs leave open,
  Handy (GPL) not at all. Write Zig, copy nothing.

### Track C: machine (files `core/lynx.zig`, `core/bus.zig`, `core/mikey.zig`, `core/boot.zig`, `tests/boot_*.zig`, `tests/mikey_unit.zig`, `tests/golden.zig`, `tests/testfiles.zig`, `tools/run_rom.zig` (+ its line in `build.zig`: the only build.zig edit, a `run-lynx` host exe step), `cart/src/**`, `tools/scripts/*.json`, `docs/RUNNING.md`, `badge-bench/carts/snouty-lynx.toml`)

- `core/bus.zig`: the functions above over `*Lynx`, the cart port
  (`CartPort`: 8-bit block shift register fed from IODAT bit 1 on SYSCTL1
  bit 0 rising edges, strobe-high counter clear, 11-bit counter masked to
  the block size, reads through `cart.Cart.read`), MAPCTL, the ROM-space
  rules, Suzy `$B0-$B3`.
- `core/mikey.zig`: 8 timers (BACKUP/CTLA/CNT/CTLB, clock select 1-64 us
  = 16-1024 ticks, linking per the two chains, reload, count enable,
  reset-done, timer-done and borrow-in/out bits, IRQ enable), INTSET/
  INTRST with the IRQ line, `advance(dt)` that advances every counting
  timer by elapsed ticks (keep a next-event tick so the common path is a
  compare), timer 2 done = vertical blank (the display copy hook), audio
  registers stored (no sound), palette, DISPCTL/DISPADR/PBKUP, CPUSLEEP
  hook, IODIR/IODAT/SYSCTL1 with the port strobes, UART registers idle
  (SERCTL reads TXRDY/TXEMPTY set), MIKEYHREV `$01`.
- `core/lynx.zig`: the frame loop, traps, sleep, display copy, `reset`
  with `post_boot`, as frozen. Unify the two header parsers (`boot.Cart`
  goes, `core.cart` stays).
- `tools/run_rom.zig` (host exe, `zig build run-lynx -- <rom> <script.json>
  <frames> <outdir>`): runs a ROM headless with the preview/badge-bench
  script format, writes `frame_NNNN.ppm` (or PNG via a tiny writer) at
  requested frames and prints per-frame hashes and the diagnostics. The
  integrator reviews those images; `tests/golden.zig` reuses the runner's
  core (shared code in `tests/golden.zig` or a `tools/runner.zig` module
  the exe and the test both import) to pin the hashes of `roms/raycast.lnx`
  and the lynx-tests carts (`tests/roms/lynx-tests/*.lnx`, skipped when
  absent: cpu, memio, page-mode, math, timers, timers2, sprites1-5,
  sdoneack, refresh-rate), hashes empty until integration.
- Frontend (`cart/src/`): `main.zig` steps the real core, overlay line
  with mean/worst step us, FPS, instructions and Suzy pixels per frame
  (`debug.zig`), `debug_*` exports for `ticks`, `instr_count`,
  `pixels_drawn`, `irq_count`, `sleep_ticks`, `display frames`; `video.zig`
  takes `frame()` as before. `tools/scripts/m1_play.json`: a 300-update
  run of raycast (splash skipped at 40, then moves and turns); update the
  bench toml to it.
- Tests (`tests/mikey_unit.zig`): timer periods and linking (0 -> 2 -> 4,
  1 -> 3 -> 5 -> 7), IRQ set/clear through INTRST, the vertical blank
  cadence (timer 0 $9E/$18 and timer 2 $68/$1F give 105 lines x 159 us =
  16.7 ms), MAPCTL overlays, the cart port protocol (select block 7 by
  strobes, counter wrap, strobe-high clear), the $FE00 and $FE4A traps on
  the raycast loader (boot lands at $0200, the loader's first $FE00 call
  selects the right block), CPUSLEEP with and without pending sprites.
  Against the stubs the golden frames are black: that is expected; the
  integrator fills the hashes.

### Integration (me, after the three merge)

1. Merge A, B, C into `lynx/m1`; `zig build`, `zig build test` green
   (demosnout's `timeline` failure is pre-existing).
2. `zig build run-lynx` on raycast.lnx, cpu.lnx, memio, page-mode, math,
   timers, sprites1-5: review the images, fix what is wrong (an Opus
   integration agent if the fixes are deep), pin the golden hashes.
3. Hard Drivin' (local, `-Dlynx-rom=~/roms/lynx/hard_drivin.lnx` and the
   romfs image) through its loader into attract mode and a drive; Blue
   Lightning as the sprite-scaling check. Images reviewed; never committed.
4. badge-bench calibrated on the RAM ELF with the raycast fixture and the
   local Hard Drivin' image: record mean, p95, worst, hot functions
   against SPEC.md section 8; sizes (`.text`, `.bss`, free arena) against
   section 13.
5. Simulator GIF of raycast; `docs/RUNNING.md`; tag `snouty-lynx/m1`;
   merge to main and push (badge gate deferred to show day).

## M2 Frontend: contract

Written 2026-10-01 after M1. One Opus agent on branch `lynx/m2` (worktree
`/home/exedev/snouty-badge-lynx-m2`), adapting `../snouty-genesis/cart/src/
frontend/` (menu, picker, help) and `../snouty-gear` where Genesis differs;
Snouty Gear's M5 shared frontend has not landed, so copy and note it for
extraction. No sound anywhere (project decision: the badge speaker is
unused; SPEC.md 9 is void, no `audio.zig`, no `-Dsound`). Decisions taken
by default (Adrian may change them later): Option 2 and the Lynx restart
chord are menu rows that hold the buttons for the game; the Iris-mark
splash from M0 stays as it is (no chime); the debug overlay is off at
boot and a menu row; the strip shows the title and the ROM name.

### Frozen for M2

```zig
// frontend/menu.zig
pub const version = "0.2.0-m2";
pub const title = "SNOUTY LYNX";                // unchanged
pub const Result = enum { stay, resume_game, pick_rom };
pub fn open() void;                             // frozen-frame copy + .copy_forward, cursor on Resume
pub fn close() void;                            // back to .no_copy_full_frame
pub fn update(l: *core.Lynx, e: input.Edge) Result;
pub var hold_pad: u16;                          // Pad bits main.zig ORs into the game pad for `hold_frames_left` frames after resuming
pub var hold_frames_left: u8;                   // set by the "Press Option 2" (Pad.opt2, 4 frames) and "Restart: Pause+Opt 1" (Pad.pause | Pad.opt1, 4 frames) rows

// frontend/input.zig (exists)
pub var swap_ab: bool;                          // the Buttons row toggles it

// frontend/picker.zig (new, Genesis's adapted)
pub fn reset() void;
pub fn update(e: input.Edge) ??usize;           // null: stay; some(null): leave without a choice (B); some(i): candidates()[i] chosen

// frontend/debug.zig (exists)
pub var enabled: bool = false;                  // off at boot (was true in M1); the Debug overlay row toggles it
```

`main.zig` states: `splash -> running | pick | help`, `running <-> menu`,
`menu -> pick -> running`. After the splash: the embedded ROM (wasm or
`-Dlynx-rom-source=embed`) or exactly one playable drive file starts at
once; several playable files open the picker (SPEC.md 18.6: the list,
A chooses, restart into that file through `romsrc`/`drive.open`, the core
re-`init_in_place`d; B picks the first); none shows the help over the
embedded ROM as M0 did. `debug_state`: 0 splash, 1 running, 2 menu, 3
pick, 4 help. Exports added: `debug_menu_opens`, `debug_settings` (bit 0
unused/sound-less, bit 2 A/B swapped, bit 3 overlay), `debug_hold_pad`.
The strip (rows 102..127) shows: line 1 "SNOUTY LYNX" + the ROM name
(header title when present, else the file name), line 2 the debug line
only when the overlay is on, else the ROM origin ("drive 128 KB" /
"embedded 27 KB"); the no-ROM help band stays as it is.

### Work (files `cart/src/frontend/{menu,picker,input,debug,romsrc}.zig`, `cart/src/main.zig`, `tools/scripts/m2_menu.json`, `tools/scripts/m2_play.json`, `badge-bench/carts/snouty-lynx.toml`, `docs/RUNNING.md`, `README.md`, this file's status)

- Menu rows (9 px rows as Genesis): `Resume`, `Buttons: A=A B=B` /
  `Buttons: A=B B=A` (`input.swap_ab`), `Press Option 2`, `Restart:
  Pause+Opt1` (both set `hold_pad`/`hold_frames_left` and resume), `Debug
  overlay: On/Off`, `Reset` (`lynx.reset()` = the boot again, resume),
  `Pick ROM` (only when the drive has more than one playable file; returns
  `.pick_rom`), `About`. Left/Right or A cycle a setting row; on other
  rows they do nothing in M2 (M3 gives them the scrubber: leave the panel's
  bottom line free, `scrub_line_y` as Genesis). Title band: "SNOUTY LYNX",
  the ROM name, "verified by" / "deterministic replay". Colours: Genesis's
  fixed scheme.
- About: version, ROM name, header title/manufacturer when headered, size
  in KB and block size, source (drive/embedded), CRC32 (drive), "fragmented"
  when not all blocks are direct, EEPROM warning, the drive fallback reason
  for an embedded ROM, and the core's boot error if any. `romsrc.zig`
  grows the accessors it lacks.
- Picker: Genesis's `picker.zig` over `romsrc.candidates()` (`drive.Candidate`:
  file name, note, playable), refused files listed dim with their reason.
  Choosing restarts: `romsrc` opens that candidate (`drive.open` into the
  shared `Source`/cluster table; the CRC recomputed; `origin`, `size`,
  `layout`, `crc`, `name()` updated), `lynx.init_in_place(cart)`. A boot
  error (`lynx.boot_error`) is shown in the strip and About, the picture
  stays black, the menu still opens.
- `input.zig`: `swap_ab` wired (already there), the hold state machine
  unchanged; main.zig ORs `menu.hold_pad` into the pad while
  `hold_frames_left > 0`.
- `debug.zig`: `enabled = false` by default; the overlay line as in M1.
- `main.zig`: the state machine above, `suppress_held` on every state
  change, `menu.open` on `open_menu`, exports.
- Scripts: `tools/scripts/m2_menu.json` (preview: skip the splash, play
  30 updates, hold Select 35 updates, walk every row, toggle Buttons and
  the overlay once and back, Press Option 2, About, resume; check
  `debug_state`, `debug_settings`, `debug_menu_opens`, `debug_hold_pad`);
  `tools/scripts/m2_play.json` = `m1_play.json` plus a menu pass (Select
  held, two Downs, B) after update 300 (frames = 400) for the bench toml.
- Checks: both targets build, `zig build test-lynx` unchanged (90/90, the
  golden hashes are core-level), `zig fmt`, preview PNGs of the menu,
  About and the picker (a drive image with two ROMs: raycast twice under
  different names is fine for the picker fixture, built with
  tools/make_romfs.py into `out/`, not committed; the committed fixture
  `tests/fixtures/m1_drive.img` has one), badge-bench with `m2_play.json`
  (menu frames far under budget, game frames as M1 within noise), `.text`
  growth noted (the arena is 43,944 B before M2; the frontend may not grow
  it by more than ~6 KB; use ReleaseSmall-friendly code: no comptime loops,
  no big tables).
- Done when: the above, `docs/m2_menu.gif`, pull-and-run notes in
  docs/RUNNING.md, status here, tag `snouty-lynx/m2`, merge to main.

## M3 Scrub: contract

Written 2026-10-01 after M2. The time scrubber (SPEC.md section 10): an
undo record per 30 badge frames, Left/Right in the menu step half a
second back and forward, resuming from a parked position plays on from
there and drops the future. Two Opus tracks in worktrees against the prep
commit on `lynx/m3`, then integration. Prior art: Snouty Genesis M3
(`carts/snouty-genesis/core/undo.zig`, `tests/undo_unit.zig`,
`tests/scrub_sizing.zig`, `tests/determinism.zig`,
`cart/src/frontend/rewind.zig`, the menu's scrub line and scrub view) is
the design copied here; Snouty Gear's page store is not.

### Decisions defaulted here (Adrian may overrule; nothing is blocked)

- Mechanism: Genesis's copy-on-first-write undo records applied by
  swapping (Left and Right are the same operation, bit-exact, no input
  log, no replay). The live console is the newest keyframe. SPEC.md 10's
  "exclude the framebuffer and re-render by replay" mitigation is NOT
  built: without an input log there is no replay; instead the record
  simply holds the framebuffer blocks the game rewrote (measured by
  Track A: raycast redraws one 8 KB buffer per Lynx frame, Hard Drivin'
  two).
- Storage: a ring of 68-byte slots (`u16` id, `u16` pad, 64 B) in the
  run-time arena between `__bss_end__` and `__stack_limit__` minus a 1 KB
  guard. Regions: RAM (1024 blocks of 64 B over the 64 KB; the display
  and collision buffers are ordinary RAM here) and `small` (every console
  field outside `ram` that is console state: `cpu`, `mikey`, `suzy`,
  `port`, `mapctl`, `fetch_ticks`, `stream_open`, `ticks`/`tick_base`,
  `frame_end`, `frame_frac`, `fast_end`, `pad`, `frame_count`,
  `sleeping`, `sprite_left`, `halted`, `boot_error`, `vblank_seen` and
  the diagnostics; NOT `cart`, `display`, `idle_sleep`). Packed as
  `Lynx.Small` with `save_small`/`load_small`, comptime-checked complete
  against the `Lynx` field list (a new field must be classified).
- Dirty state: one byte per RAM block (1024 B in `.bss`), read on the
  bus write path (`bus.write`'s RAM branch and `high_write`'s `$FFF8`/RAM
  cases) and by Suzy (`run_sprites` writes RAM directly: it calls
  `undo.touch_range(addr, len)` once per span written, per collision
  span and per depository byte, never per pixel), cleared when a record
  closes. The `$FE4A` trap's `decrypt_frame` and `reboot` write RAM
  directly too: `touch_range` over the frame destination, and `reset`
  forgets the history (Reset row, Pick ROM, boot).
- Interval 30 frames, records capped at 64. Block 64 B.
- Memory: Track A's sizing test reports slots per record on raycast,
  Hard Drivin' (local) and Blue Lightning (local) and the history each
  arena gives: ReleaseFast as built (43,944 B free: likely 1-2 records),
  ReleaseFast with `exec` not inlined into `run_cpu` (perf pass table:
  ~1 ms for ~48 KB), ReleaseSmall (120,296 B free, badge-bench 11.28 ms
  mean / 17.0 worst on raycast), XIP (190,000 B, untested on hardware,
  not before show day). Integration picks the cheapest build that gives
  >= 2 s on raycast and Hard Drivin' (SPEC 10 target) with worst under
  the 16.7 ms budget: default order ReleaseFast un-inlined, then
  ReleaseSmall. The pick is a `-Dcart-optimize` default in
  `carts/snouty-lynx/build.zig` plus (if un-inlining) a `tunables.zig`
  switch; recorded in the status.
- Picture while parked: after a swap the console holds the keyframe
  exactly; `Lynx.refresh_display()` copies the frame at the latched
  DISPADR and the palette into `display` (what `on_vblank` does) without
  stepping, and the frontend shows it. The strip reads "Scrub: -1.5 /
  3.5s" as Genesis.
- Performance gate: +0.5 ms mean on the m2_play raycast run for the
  dirty check; section 8 totals hold.

### Frozen for M3

```zig
// core/undo.zig (Track A), file-level state as Genesis's: no cart-api, no allocator.
pub const block_size = 64;
pub const Slot = extern struct { id: u16, pad: u16 = 0, data: [block_size]u8 };
pub const frames_per_record = 30;
pub const max_records = 64;
pub const Region = enum(u4) { ram = 0, small = 15 };
pub fn init(arena: []align(4) u8) void;
pub fn capacity_slots() usize;
pub fn reset(l: *Lynx) void;                 // forget history, open record 0 from l; tracking on
pub fn disable() void;
pub fn record_frame(l: *Lynx) void;          // after every stepped frame
pub fn can_step(dir: i2) bool;
pub fn step(l: *Lynx, dir: i2) bool;         // swap one record; then l.refresh_display()
pub fn parked() bool;
pub fn resume_here(l: *Lynx) void;
pub fn depth_frames() u32;  pub fn history_frames() u32;  pub fn record_count() usize;
pub fn slots_in_use() usize;  pub fn lost_history() bool;
pub inline fn touch(addr: u16) void;         // one RAM byte, before the write
pub fn touch_range(addr: u16, bytes: u32) void;  // Suzy spans, decrypt_frame; wraps at 64 KB

// core/lynx.zig (Track A)
pub const Small = struct { ... };            // see above; comptime-complete
pub fn save_small(l: *const Lynx, out: *Small) void;
pub fn load_small(l: *Lynx, k: *const Small) void;   // keeps cart, display, idle_sleep
pub fn refresh_display(l: *Lynx) void;

// cart/src/frontend/rewind.zig (Track B), over core.undo: Genesis's shape
pub fn init() bool;  reset(l)  record_frame(l)  step(l, dir) bool  show(l)
pub fn depth_frames() u32; history_frames() u32; record_count() usize; capacity_slots() usize; slots_in_use() usize; arena_bytes() usize;
// cart/src/frontend/tuning.zig (Track B): stack_guard = 1024, wasm_arena_bytes
```

Exports (Track B): `debug_scrub_depth`, `debug_scrub_history`,
`debug_scrub_records`, `debug_scrub_slots`, `debug_scrub_capacity`,
`debug_scrub_arena`.

### Track A: core (files `core/undo.zig`, `core/lynx.zig` (Small, save/load_small, refresh_display, the touch calls in reset/traps), `core/bus.zig` (write hooks), `core/suzy.zig` (touch_range per span; keep the hot path: one call per span, not per pixel), `tests/undo_unit.zig`, `tests/determinism.zig`, `tests/scrub_sizing.zig`, `tests/all.zig` (three new lines), `SPEC.md` 10/13 numbers)

- `undo.zig` ported from Genesis with the two regions; unit tests ported
  (boundary open/close, eviction, swap back and forth bit-exact, lost
  history, resume drops the future, touch_range wrap).
- `tests/determinism.zig`: raycast 600 frames under the m1 script, a
  full `Lynx` copy every 30 frames; for each k restore k, step 30
  frames, compare with k+1 (ram + Small field by field, first differing
  field named). Then the same run through `undo`: step back to every
  record and forward again reproduces the live state bit-exactly.
- `tests/scrub_sizing.zig`: slots per record and the history at the
  four arena sizes above for raycast (1800 frames, m1 script looped),
  Hard Drivin' (`~/roms/lynx/hard_drivin.lnx`, the drive script of the
  M1 status, skipped when absent) and Blue Lightning (attract). Report
  the table.
- badge-bench before/after on m2_play (the dirty check cost).

### Track B: frontend (files `cart/src/frontend/rewind.zig`, `tuning.zig`, `menu.zig` (scrub line, scrub view, Left/Right, repeat), `debug.zig`, `main.zig` (init/reset/record_frame/resume_here calls, exports), `tools/scripts/m3_scrub.json`, `badge-bench/carts/snouty-lynx.toml`, `docs/RUNNING.md`)

- Genesis's `rewind.zig` and menu scrub UI adapted; `resume_here` before
  the first `step_frame` after a scrub; Reset and Pick ROM forget the
  history; "Scrub: no memory" when fewer than two records fit.
- `m3_scrub.json`: play 240 updates, open the menu, Left x4 with the
  repeat, Right x2, resume, play on; exports checked in the preview
  (`debug_scrub_depth` back to 0 after resuming, history growing).
- wasm arena: a static of `tuning.wasm_arena_bytes` (set to the badge's
  figure at integration).

### Integration

Merge, `zig build test` green, pick the build per the sizing table,
preview GIF `docs/m3_scrub.gif`, badge-bench on m3_scrub, sizes, status,
tag `snouty-lynx/m3`, merge to main.

## M4 Perf: contract

Written 2026-10-01 after M3. One Opus agent on `lynx/m4` (worktree
`/home/exedev/snouty-badge-lynx-m4`). The hardware half of SPEC.md 17's
M4 (every stress target measured on a badge) is show day's; this is the
host-side half against the calibrated badge-bench. The 13.1 packed
fallback is not needed (the drive path works in the bench; hardware
pending).

Baseline (M3, RAM cart, ReleaseFast with `cpu65.exec` not inlined, undo
hooks on; m2_play.json 400 frames): all frames mean 9.58 ms, worst 16.13;
game frames 41-299 mean 11.64; m3_scrub.json: worst 16.81 at the second
frame after resume (1 of 480 over). Per unit: CPU ~100 host cycles per
instruction (target 60), Suzy ~74 per pixel written on raycast's 5-pixel
rows (target 20), display 0.25 ms. Hard Drivin' drive (local script):
mean 11.6, worst 20.1 (one spike).

Targets: raycast game frames worst under 14 ms and mean under 11 in the
RAM build; the resume spike gone (no frame over budget in m3_scrub); Hard
Drivin' worst under 16.7. Emulated behaviour unchanged: the golden hashes
and every lynx-tests row stay as they are (a deliberate timing fix, e.g.
sprites4 DMA EXP W24, is allowed only as a separate commit that re-pins
the hashes it changes and keeps every other row).

Work, in order of expected payoff:
1. Suzy per-row cost (docs/SUZY.md "Performance shape"): the decoded-row
   path (~235 cycles per row), the per-span accounting of the tick model
   (keep the result bit-identical), sprite-type-specialised span writers,
   the collision-span `touch_range` (one call per span is the rule; batch
   per row where the spans are contiguous).
2. CPU dispatcher without inlining it into the run loop: the `exec` call
   overhead (register saves), keeping `regs` in locals across an
   instruction, the fetch/read/write fast paths (`undo.touch` is one byte
   load and a branch), `after_step`. The inlined variant stays one
   keyword away for the XIP build (note how to switch it).
3. The resume spike: `resume_here` + the first `step_frame` +
   `record_frame` land in one frame; spread or cheapen (e.g. truncate
   records lazily, open the record without copying).
4. Mikey events, `video.show`, the strip (small).
Each change measured; keep what pays; the before/after table in the
Status. `zig build test-lynx` 108/108 unchanged, `zig fmt`, both cart
modes build, preview of m3_scrub.json still passes its checks.

## M5 Sound: contract

Written 2026-10-04. Adrian: "Let's build sound support, I want to hear it
through the terrible speaker playing it. The badges have the new firmware."
This reverses the project's "no sound" rule for this cart only (root
docs/SOUND.md; the 2026-09-30 "no audio work" call stands for the others).
Integration worktree `/home/exedev/snouty-badge-lynx-sound`, branch
`lynx/m5-sound` (from origin/main 074557f); plan commit = this section, the
SPEC.md section 9 rewrite and the frozen interface stub below. Three Opus
tracks, each in its own worktree off the plan commit; they commit on their
branch, I merge, tag `snouty-lynx/m5`, merge to main and push.

### The badge side (verified 2026-10-04 against sycl-badge upstream 3392a1b)

The new firmware (commit 97c093e "Streaming Audio, v1 Mixer") drops the
`tone` voice and plays a cart-owned ring of unsigned 8-bit mono samples at
44,100 Hz (128 = silence; `drivers/audio.zig` `mix_audio_samples` maps
0..255 to -vol..+vol). Our pin (a6ce19f) has no API for it, so the cart
speaks the ABI itself (no pin bump, SYCL upstream drift note):

- IPC block base `0x20020000` (same in both firmwares). The old
  `tone_freq/duration/volume/flags` words are now, at `0x2003509C`,
  `0x200350A0`, `0x200350A4`, `0x200350A8`: `audio_buffer_ptr` (u32
  address, buffer `align(8)`), `audio_buffer_len` (u32), `audio_buffer_head`
  (u32, cart writes: next sample the cart will write), `audio_buffer_tail`
  (u32, OS writes: next sample the OS will read). Empty when head == tail;
  the cart may fill up to len-1. Indices wrap at len.
- Start: write ptr, len, head = 0, tail = 0, `dmb`, then FIFO word
  `0x29000002` (CART_START_AUDIO) to SIO FIFO_WR `0xD0000054` (wait for
  FIFO_ST `0xD0000050` bit 1 RDY first, as the pinned runtime does).
  Submitting = write samples at head, `dmb`, store the new head.
- The OS mixes 512 samples per DMA buffer (~11.6 ms), two buffers ping-
  pong; on underrun it pads with silence. It stops audio itself when the
  cart exits (kernel `audio.stop()`).
- Never send CART_STOP_AUDIO (`0x29000001`): the OS answers with a FIFO
  word (`0x29000003`) the pinned runtime does not expect. To go quiet,
  stop submitting (the OS pads with silence).
- Old firmware: `0x29000002` has type byte 0x29 = its CART_VOLUME, which
  re-applies `global_volume` (`0x200350AC`, which we never write) and
  plays nothing. Harmless; no firmware detection needed.
- The wasm simulator (pinned) has no streaming audio: the wasm build is
  silent and hides the Sound row.

### Frozen interface (in the plan commit)

- `core/audio.zig`: `sample_rate = 44100`, `samples_per_frame = 735`
  (1/60 s exactly), `silence = 128`. Track A grows the channel model here.
- `Lynx.audio_out: [735]u8`: after every `step_frame`, the sound of exactly
  that frame's Lynx time (the frame's `n` ticks split into 735 bins on the
  16 MHz clock, bin edges at `frame_start + floor(i * n / 735)`).
  `Lynx.audio_render: bool` (true after `init_in_place`): when false,
  `step_frame` may skip filling `audio_out` (it keeps its last content);
  the channels keep running regardless (their registers are CPU-visible
  and part of determinism). Both are in `Lynx.small_excluded`.
- Audio state that the CPU can see (registers, counters, shift registers,
  outputs, stereo and attenuation) lives in `Mikey` (so `Lynx.Small`, the
  scrubber and determinism cover it with no extra work).
- `lib/stream_audio.zig` (Track B, shared, for any cart later):
  `pub const sample_rate = 44100;` `pub fn start(buf: []align(8) u8) void`,
  `pub fn queued() u32`, `pub fn free() u32`, `pub fn push(s: []const u8)
  u32` (copies with wrap, returns the count written), all over a
  `Ring = extern struct { ptr: u32, len: u32, head: u32, tail: u32 }`
  reached through a pointer the caller can replace (host tests use a plain
  struct; the badge build uses `@ptrFromInt(0x2003509C)`), plus the FIFO
  send. The badge path compiles only for the badge target.

### Track A: the channels (`core/audio.zig`, `core/mikey.zig`, tests)

Branch `lynx/m5-a`, worktree `/home/exedev/snouty-badge-lynx-m5a`.

Model Mikey's four audio channels from the public documents (the Epyx
hardware appendix and audio chapter at monlynx.de, cc65 `_mikey.h`; Felix
and Handy may be read for behaviour the documents leave open, nothing
copied; cite in the file comment as mikey.zig does):

- Registers `$FD20-$FD3F`, eight per channel: VOLUME (signed), FEEDBACK
  (tap select), OUTPUT (signed, current output; a CPU write sets it: the
  "DAC" path games use for sampled sound), SHIFT (low 8 bits of the 12-bit
  shift register), BACKUP, CONTROL (taps bit 7, integrate, reload, enable,
  clock select), COUNTER, OTHER (shift bits 11-8, last clock, borrow in /
  out). Lynx II: ATTEN_A-D `$FD40-$FD43`, MPAN `$FD44`, MSTEREO `$FD50`.
  Read-back exactly as hardware where documented.
- Clocking as the timers (same prescaler edges, `16 << sel` ticks; sel 7 =
  linked): chain timer 7 -> audio 0 -> 1 -> 2 -> 3 -> timer 1 (the
  `mikey.zig` simplification "the tail of chain B is cut" goes away).
- On each underflow: the 12-bit LFSR shifts, the new bit is the
  complement of the XOR of the selected taps (check the polarity against
  the documents, it decides square vs inverted), and OUTPUT becomes
  +VOLUME / -VOLUME (normal) or accumulates +/-VOLUME with clamping to
  -128..127 (integrate mode).
- Mix to mono: per channel the left and right levels (MSTEREO disables,
  ATTEN via MPAN on the Lynx II; a Lynx I game never writes them, so the
  reset values must give plain sums), averaged to mono; the four summed;
  gain and clamp into 0..255 around 128. Choose the gain from the real
  games' levels (Hard Drivin' and Blue Lightning from `~/roms/lynx/`,
  raycast): loud (the speaker is weak) without clipping the common case.
  One named constant, its reasoning in a comment.
- Bins: integrate level x duration exactly (box filter) into 735 bins per
  frame. Per channel independently into a shared i32 accumulator is fine
  (no cross-channel ordering needed except through links).
- Speed: channels are lazy. Catch up a channel when the CPU reads or
  writes any audio register, when a link needs its borrow, and at the end
  of `step_frame`; never an event per underflow on Mikey's `next_event`
  unless timer 1 is linked behind audio 3 (rare; an event is fine there).
  Budget: on the calibrated badge-bench, the m2_play and m3_scrub scripts
  and the local Hard Drivin' drive script (`out/hd_drive.json` in
  `/home/exedev/snouty-badge-lynx`) keep 0 updates over 16.67 ms; report
  the audio share (mean and worst ms) per script. If a channel runs faster
  than ~one underflow per 4 bins, a closed-form or table fast path that is
  bit-identical is welcome; measure first.
- Behaviour: golden frame hashes and lynx-tests rows unchanged, unless a
  game reads audio registers or links timer 1 (then a separate commit
  re-pins the hashes it changes with the reason). New unit tests
  (`tests/audio_unit.zig`, prefix `audio:`): LFSR sequences for known tap
  settings, a square wave's pitch from BACKUP and clock select, integrate
  clamping, DAC writes landing in the right bin, link chain timer 7 ->
  audio 0, register read-back, stereo/attenuation mix, scrub round trip
  (restore -> identical `audio_out` on the next frame).

### Track B: badge plumbing and frontend

Branch `lynx/m5-b`, worktree `/home/exedev/snouty-badge-lynx-m5b`.

- `lib/stream_audio.zig` as frozen above, with host tests (wrap, full
  ring, empty, len-1 capacity) wired into `zig build test`.
- `cart/src/frontend/audio.zig`: a 4,096-byte ring (`align(8)`, .bss;
  the scrub arena shrinks by that, report the new arena size), `start`
  on the first running frame. Each running frame push the core's 735
  samples with rate control: target queue 1,470 (two frames); push
  `735 + (target - queued) / 8` samples clamped to 640..830, resampled from
  the 735 by nearest neighbour (a pitch wobble well under 1%). When the
  game stops stepping (menu, picker, scrub, help) push one 64-sample ramp
  from the last sample to 128 and then nothing; on resume push 735
  samples of silence first, then the frame.
- Sound row in the menu ("Sound: On/Off", settings bit 0, after
  Buttons). **Boots On** in this cart (Adrian asked to hear it; the new
  firmware's Start+Select box has a volume control); off sets
  `l.audio_render = false` and stops pushing. Hidden in the wasm build.
  Deferred question for Adrian: keep the Lynx loud by default, or follow
  docs/SOUND.md's off-by-default with `-Dsound`?
- Debug overlay: one more figure, the audio queue (samples) and underruns
  since start (an underrun = `queued() == 0` at a push).
- Docs: README, CLAUDE.md (the "Sound: none" rule), root docs/SOUND.md
  (the Lynx row, a "Streaming audio (new firmware)" section with the ABI
  above), docs/INSTALL.md controls line if it mentions sound,
  `version = "0.5.0-m5"`.
- Both cart modes build; other carts' UF2s byte-identical to a build of
  the plan commit.

### Track C: hearing it off the badge

Branch `lynx/m5-c`, worktree `/home/exedev/snouty-badge-lynx-m5c`.

- `tools/run_rom.zig`: `--wav <file>` writes `audio_out` of every update
  as an 8-bit unsigned mono 44,100 Hz WAV (works with the stub: silence).
- badge-bench (`badge-bench/badge_bench/os_fake.py`, `run.py`, `cli.py`):
  the new firmware's audio. On FIFO word `0x29000002` read ptr/len from the
  IPC block and start consuming: per 512 samples of wall time (the bench
  clock, 44.1 kHz) advance `audio_buffer_tail` by up to 512 queued samples,
  as the OS does. Report: audio started (frame), samples consumed,
  underrun samples, queue min/mean/max; `--wav <file>` writes the consumed
  stream (silence for underruns), so the cart's real ELF can be listened
  to. Old-firmware words (`0x29` type) must no longer count as unknown.
  Bench unit tests for the consumer. Nothing changes for carts that never
  start audio (every other cart's report identical).
- A short `docs/AUDIO.md` in this cart: how to make the WAVs (run-lynx and
  bench), and the listening checklist below.

### Integration (me)

Merge A, B, C on `lynx/m5-sound`; `zig build`, `zig build test`,
`zig build check-float` (the core stays float-free), lynx tests; bench
m2_play, m3_scrub and hd_drive with `--wav`; run-lynx WAVs of raycast,
Hard Drivin' and Blue Lightning: pitch and level sanity (numpy: no
clipping run, RMS, dominant frequency matches the register-derived one,
no 60 Hz click); copy the WAVs to `out/` for Adrian to listen to on his
Mac before flashing. Tag `snouty-lynx/m5`, merge to main, push.

## Status

- 2026-10-01: M4 perf pass on `lynx/m4` (host side; every target met).
  Emulated behaviour unchanged: the same frame hash, ticks, instructions,
  IRQs, pixels, sleep ticks and display frames at every update of
  raycast (m1_play, 600), Hard Drivin' (hd_drive, 1,800), Blue Lightning
  (900) and all 19 lynx-tests carts (300, sprites1-5 450), compared after
  every change; `test-lynx` 108/108 (golden hashes, SingleStepTests,
  determinism untouched); m3_scrub preview passes its four checks and
  LEDs 0; both cart modes build. Calibrated badge-bench, RAM cart,
  ReleaseFast, undo hooks on, busy ms:

  | run                         | mean  | p95   | worst          | over |
  |-----------------------------|-------|-------|----------------|------|
  | m2_play 400, M3 (2c70bec)   | 9.58  | 14.27 | 16.13 (226)    | 0    |
  | m2_play 400, M4             | 6.70  | 8.98  | 10.23 (226)    | 0    |
  | m3_scrub 480, M3            | 9.00  | 14.57 | 16.81 (418)    | 1    |
  | m3_scrub 480, M4            | 6.13  | 9.45  | 10.73 (418)    | 0    |
  | Hard Drivin' 1,800, M3      | 14.66 | 16.77 | 24.13 (1088)   | 101  |
  | Hard Drivin' 1,800, M4      | 8.45  | 10.92 | 15.33 (1088)   | 0    |

  raycast game frames 41-299 mean 11.64 -> 8.10 (target 11), worst
  16.13 -> 10.23 (target 14); m3_scrub game frames 41-284 12.04 -> 8.27,
  the resume frame 16.47 -> 10.50, scrub step 1.61, menu 0.93 (both
  unchanged). The "resume spike" was the game's heavy frame of its
  three-frame cycle (415 and 418 cost the same before and after):
  `resume_here` and the first frame's block saves cost next to nothing,
  so nothing was spread. Hard Drivin' driving 900-1800 mean 15.32 ->
  8.60; its worst frames are 1088 and 1784 (a 41k-pixel dashboard and
  sky redraw on top of a full CPU frame) and a ~14.5 ms redraw every ~94
  frames. Per unit: CPU `run_cpu` cycles per Lynx instruction 123 -> 64
  (raycast) and 140 -> 71 (Hard Drivin', exec + run loop before);
  Suzy (all of high_write before; draw_sprite + cpu_sleep + high_write
  after) 85 -> 74 cycles per pixel on raycast's 2-pixel rows (~270 per
  drawn row), Hard Drivin's update 1088 1.39M -> ~0.95M. Steps
  (m2_play's first 200 frames: mean, CPU, Suzy cycles a frame; HD 1088):

  | step (commit)                                        | mean | CPU  | Suzy | HD 1088 |
  |------------------------------------------------------|------|------|------|---------|
  | M3 (2c70bec)                                         | 9.30 | 752k | 514k | 24.13   |
  | switch inside run_cpu, one copy (494526c)            | 8.34 | 610k | 508k |         |
  | fetch_cost byte, IRQ line + P once per run; Suzy row stats in locals (f6d90be, 5dc496a) | 7.63 | 509k | 502k | |
  | one compare for ROM/IRQ, u32 fetch fields (99a5aed)  | 7.49 | 479k | 510k |         |
  | instruction count in a register; word span stores, draw_sprite out of line (835adb4, 6b2db23) | 7.42 | 472k | 506k | 18.20 |
  | sleep loop, Mikey paths out of line (984537a)        | 7.24 | 472k | 480k | 17.77   |
  | clock in registers: bus.Port (76c4693)               | 7.07 | 438k | 485k | 17.34   |
  | video-only decoder copy (2adbd5c)                    | 6.91 | 438k | 462k | 16.44   |
  | one slow-path compare per instruction (c1228c8)      | 6.78 | 418k | 462k | 15.94   |
  | run's end bound in a register (9d35776)              | 6.60 | 391k | 462k |         |
  | short fill for replayed rows (5494fe4)               | 6.54 | 391k | 453k | 15.33*  |

  (* the full 1,800-frame run; the Suzy column moves ~2% with code
  layout alone.) Hot functions after, m2_play 400
  (cycles a frame): run_cpu 406k (the CPU loop with the whole opcode
  switch), draw_sprite 400k, cpu_sleep 34k, video.show 28k, high_write
  22k, high_read 15k, text.draw 13k, after_step 13k, memcpy 10k (the
  vblank copy), Mikey run_events 10k + underflow 9k + mikey_write 9k +
  write 8k + reschedule 6k; Hard Drivin' 1,800: run_cpu 878k,
  draw_sprite 203k, high_read 49k (SPRSYS polls and math reads, ~1,000
  a frame), video.show 32k, high_write 29k. Sizes (RAM ELF): .text
  122,136 -> 121,408 B, .bss 86,328 -> 86,344 (fetch_cost/fetch_ticks
  are u32 now), `__bss_end__` 0x200683b0 -> 0x20068118: arena 64,592 ->
  65,256 B (934 -> 944 slots after the guard; `tuning.wasm_arena_bytes`
  64,232); XIP .text 122,452 -> 121,724, `__bss_end__` 0x2004a2c0 ->
  0x2004a2d0. `exec` is now `inline` and exists once, inside
  `Lynx.run_cpu` (out of line, the whole run loop; `step_one` goes
  through it): the "inlined for XIP" knob is `noinline` -> `inline` on
  `run_cpu`, which would only save its call per Mikey event (docs/CPU.md
  "Speed"). Tried and dropped (measured slower or not paying): the
  console address hidden from the optimizer (601k vs 533k CPU), a local
  copy of the CPU registers in the loop (+18k), `ram` aligned or moved
  (field offsets out of immediate range, +13 KB), a two-pass Suzy row,
  `draw_row` out of line, one decoder per direction, not recording
  stretched rows, the sleep loop with locals only (the tight DMA-only
  loop is what paid). ReleaseSmall now leaves 105,528 B of arena but is
  still over budget (m2_play first 200 frames mean 8.09; Hard Drivin'
  1088 19.86 ms). Not done: sprites4 DMA EXP W24 (charging part of the
  video-DMA steal inside sprite runs shifts every sprite run's time the
  tick model was fitted with, so the other sprite rows would need a
  refit: not cheap). Left: Suzy's per-row setup and per-span decode
  still run spilled (~270 cycles a drawn row); the CPU's flags are
  computed eagerly (lazy N/Z would be the next large CPU step, a cpu65
  change); hardware numbers are show day's.
- 2026-10-01: M4 contract written on `lynx/m4`; one Opus agent started.
- 2026-10-01: M3 INTEGRATED. Tracks A (undo core) and B (scrub frontend)
  merged on `lynx/m3`; 108/108 host tests (13 undo, 2 determinism: raycast
  600 frames restore-and-step equals the next copy, every record back and
  forth bit-exact, resume + replay equals live; 3 sizing, print only); the
  golden hashes unchanged. Preview of `m3_scrub.json`: the menu opens at
  314 with "Scrub: live / 1.6s", Left parks at -0.6 s then -1.6 s (the
  oldest record) with the restored picture under the bar, two Rights are
  live, B resumes and the history regrows (99 frames at 479); GIF
  `docs/m3_scrub.gif`. DECISIONS (defaults, Adrian may change them):
  (1) `undo.frames_per_record` = 60 (1 s steps) instead of SPEC 10's 30:
  the games redraw their 8 KB screen buffers every frame (raycast three
  buffers, 405 slots = 27.5 KB per record whatever its length; Hard
  Drivin' two, 230-400 slots; Blue Lightning ~290), so a longer record
  doubles the history per byte; the unit tests keep 30-frame arithmetic
  by setting the variable. (2) Build: ReleaseFast with `cpu65.exec` not
  inlined (cpu65.zig), which gives 64,592 B of arena (63,568 B = 934
  slots after the guard) for ~0.7 ms a frame: history raycast ~1.0-1.6 s,
  Hard Drivin' ~1-2 s, Blue Lightning ~2 s, all SHORT of SPEC 10's 2 s.
  Measured alternatives: exec inlined 40,632 B = 0 records (scrubber says
  "no memory" on every title); ReleaseSmall 120,296 B = raycast 1.5 s /
  HD 1.5 s / BL 2 s at 60-frame records (11.28 ms mean, worst 17.0, over
  budget); `frames_per_record` = 120: raycast 2 s / HD 2 s / BL 4 s at 2 s
  steps; XIP (`snouty-lynx-xip.uf2`, now built by default beside the RAM
  cart) 187,712 B = raycast 2.5 s / HD 3 s / BL 3.5 s with the fast CPU,
  but XIP is untested on hardware. RECOMMENDATION for Adrian's badge run:
  flash `snouty-lynx-xip.uf2` once; if it runs, XIP becomes the Lynx
  default (and exec can be inlined again). badge-bench (calibrated,
  m3_scrub.json, drive fixture): all frames mean 9.00 / p95 14.57 / worst
  16.81 ms (frame 418, the second after resume: 1 of 480 over budget);
  game frames 41-284 mean 12.04, worst 16.13; menu 0.93; scrub step 1.61;
  resume frame 16.47. On m2_play: mean 9.58, worst 16.13, 0 over (M2 was
  8.42 game-frame mean). Hook cost +0.45 ms mean (Track A), un-inlining
  +0.7. Sizes: RAM .text 122,136 B, .bss 86,328, `__bss_end__`
  0x200683b0; XIP .text 122,452 (flash), `__bss_end__` 0x2004a2c0.
  `tuning.wasm_arena_bytes` = 63,568. Open: the resume-frame spike (M4:
  spread resume_here + the first step), sprites4 DMA EXP W24, `exec`
  inlining as a per-mode knob. Tag `snouty-lynx/m3`.
- 2026-10-01: M3 Track B (frontend) done on `lynx/m3-frontend`, against
  the undo stub. `frontend/rewind.zig` (Genesis's: arena from
  `__bss_end__`/`__stack_limit__` minus `tuning.stack_guard`, wasm static
  `tuning.wasm_arena_bytes` = 40 KB until integration; `min_slots` = two
  records' small state + 64, small state from `undo.small_slots` or
  `Lynx.Small` once Track A lands, an over-estimate before; `show` =
  `refresh_display` + `video.show` + the strip), `frontend/tuning.zig`,
  `frontend/strip.zig` (the status strip moved out of main.zig so `show`
  can redraw the whole parked screen). Menu: scrub line on y 110, Left/Right
  on every non-setting row, repeat 15 updates (4/s), `scrub_view` bar
  y 118..127, Reset calls `rewind.reset`; main.zig: `rewind.init` in start,
  `rewind.reset` in `boot` (start, picker), `resume_if_parked` +
  `record_frame` around `step_frame`, the six `debug_scrub_*` exports;
  `debug.core_moved` after a step or reset so the overlay's per-frame
  counts never show a wrapped delta. `tools/scripts/m3_scrub.json` (480
  updates), the bench toml points at it. Checks: both targets build,
  `test-lynx` 93/93, preview of m3_scrub passes (menu at 314..414, resume
  at 415, depth 0, LEDs 0, wasm capacity 602 slots); with a local hack
  forcing `step` to succeed the scrub bar and the redrawn picture + strip
  were checked, then reverted. badge-bench m2_play (same script on the
  prep ELF and this one): game 0-299 mean 8.43 / p95 11.52 / worst 12.94
  (prep 8.42 / 11.52 / 12.94), menu 0.94 / 1.19 (0.92 / 1.17). Sizes
  (ReleaseFast RAM): .text 148,844 (+372), .bss 84,168 (+8); `__bss_end__`
  0x2006e2e8, arena 40,216 B - 1 KB guard = 39,192 B (576 slots). The
  undo itself is still a stub: its cost lands with Track A.
- 2026-10-01: M3 contract written on `lynx/m3` with the undo stubs; tracks A (core) and B (frontend) started.
- 2026-10-01: M2 DONE on `lynx/m2` (frontend agent; not tagged or merged:
  the integrator tags `snouty-lynx/m2` and merges). Menu (frontend/menu.zig,
  Genesis's adapted, a copy until Gear's M5 shared frontend): Resume,
  `Buttons: A=A B=B`/`A=B B=A`, Press Option 2, `Restart Pause+Opt1` (the
  contract's "Restart: Pause+Opt1" is 19 columns, one more than the panel;
  both hold rows set `hold_pad`/`hold_frames_left` = 4 and resume), Debug
  overlay (off at boot), Reset (`init_in_place` on the same cart = the boot
  again), Pick ROM (only with more than one playable drive file), About
  (version, file, header title + maker, size + block size, source, then
  boot error, drive-not-used reason, CRC, fragmented, EEPROM while lines
  remain). Frozen frame as Genesis; Left/Right only flip the two settings;
  the panel's bottom line (`scrub_line_y` = 110) is left for M3. States
  splash -> running | pick | help, running <-> menu, menu -> pick -> running
  (`debug_state` 0..4); help = the embedded ROM under the M0 band, A or B
  hides it. Picker (frontend/picker.zig): from the splash B keeps the first
  playable file (booted in `start`), from the menu B goes back; the cursor
  starts on the running file. Strip: "SNOUTY LYNX" + the ROM name (header
  title, else file name); origin + size, or the debug line; then the boot
  error, or the debug line 2, or the CRC/flags / drive fallback reason.
  romsrc: `select` returns the cart and the next state, `open(i)` for the
  picker (drive.open into the shared Source/cluster table, CRC again),
  `title_name`, `fallback`, `fragmented`; the report string is gone.
  Exports `debug_menu_opens`, `debug_settings` (bit 2 swap, bit 3 overlay),
  `debug_hold_pad`. No sound, neopixels never written (`debug_led_max` 0).
  Checks: both targets build; `zig build test-lynx` 90/90; preview
  `m2_menu.json` (360 updates) passes 11 checks (menu at 104, settings 4 /
  0 / 8 / 0, `debug_pad` 4 on updates 230-233 and 0 at 234, Select-tap
  resume at 312, opens 2, hold pad 4, LEDs 0), `docs/m2_menu.gif` (134 KB).
  Picker verified in badge-bench on `out/lynx-two.img` (raycast as
  RAYCAST.LNX and AGAIN.LNX, tools/make_romfs.py, not committed): the list
  after the splash, Down + A plays AGAIN.LNX (About names it, the strip
  reads "drive 27 KB"), the menu shows Pick ROM and reopens the list with
  "B: back", B resumes; the choosing frame is 13.30 ms (boot + CRC). Help
  checked on `tests/fixtures/m0_none.img`. badge-bench (calibrated,
  `m2_play.json`, 400 frames, fixture drive): game frames 0-299 busy mean
  8.42 ms, p95 11.50, worst 12.94 (M1 8.44 / 11.53 / 12.96); menu frames
  334-364 mean 0.92, worst 1.17 (the frozen-frame copy); after resuming
  mean 9.26, worst 12.32; 0 of 400 over. Sizes (ReleaseFast, drive source,
  raycast embedded): .text 148,472 B (cf132ba built in the same tree:
  145,560), .data 120, .bss 84,160; free arena `__bss_end__` 0x2006e148 ..
  0x20078000 = 40,632 B (cf132ba: 43,712), so the frontend took 3,080 B.
  The first cut took 8.7 KB: ReleaseFast inlined the romsrc/debug number
  and size helpers at every call site, now `noinline`; the boot is one
  out-of-line `init_in_place` for start, the picker and Reset. Deferred:
  the scrubber (M3, Left/Right and the bottom line), no hint on the help
  band that A/B hides it, the strip cannot tell two files with the same
  header title apart (About can), the Gear/Genesis/Lynx menu extraction.
- 2026-10-01: M2 contract written on `lynx/m2`; one Opus agent started.
- 2026-10-01: M1 INTEGRATED. Tracks A (CPU), B (Suzy), C (machine) merged on
  `lynx/m1`, then two fixers (Suzy vs the lynx-tests carts: math flags and
  busy timing, register mirrors, flip offsets, a hardware-fitted tick
  model; machine: page-mode stream rules, DMA/refresh as timed events,
  one-instruction-late CLI/SEI/PLP, Mikey timer slot timing, interrupted
  sprite runs) and the perf pass below. Results: SingleStepTests 256/256
  files (2,560,000 cases); drhelius lynx-tests (MIT) every row PASS on
  cpu (8), memio (3), page-mode (6), math (8), timers (7), timers2 (10),
  sdoneack (9), sprites1 (8), sprites2 (8), sprites3 (8), sprites5 (8),
  sprites4 7 of 8 (DMA EXP W24 code 3: we charge the full video-DMA steal
  inside a sprite run, hardware hides ~60% of it; M4); refresh-rate shows
  158/041/104. Golden hashes pinned in tests/golden.zig (raycast at 6
  checkpoints, each test cart's result screen). `zig build test-lynx`
  90/90. Local only (never committed): Hard Drivin' boots through its
  two-trap loader, title, track map, high scores, transmission menu and a
  drive with the polygon road, cars and dashboard (`out/hd_drive.json`:
  A at 600 and 800, Up from 900); Blue Lightning boots to its logo,
  attract (scaled explosion, jets) and the mission-code screen, which
  reads the d-pad. badge-bench (calibrated, raycast from the fixture
  drive image, m1_play.json): busy mean 8.44 ms, p95 11.53, worst 12.96,
  0 of 300 over; Hard Drivin' drive script mean 11.6, p95 14.6, worst
  20.1 (one spike), 2 of 1300 over (SPEC 8: mean <= 12, worst < 14; the
  spike is M4's). Sizes (ReleaseFast, drive source, raycast embedded):
  .text 145,328 B (97 KB before the perf inlining), .data 112, .bss
  84,168; free arena `__bss_end__` 0x2006d458 .. 0x20078000 = 43,944 B.
  OPEN for M3: the scrub ring wanted >= 64 KB; levers are ReleaseSmall
  for the frontend, un-inlining `exec` (~1 ms for ~48 KB), or the XIP
  cart mode (256 KB flash for code, untested on hardware). Also open:
  `debug.enabled` is on until M2's menu row; SP before reset; $5C on
  hardware. Deferred decisions taken by default: Suzy draws on CPUSLEEP
  (hardware model), the display is copied at vblank, no sound (project
  decision), Option 2 only in the M2 menu. Docs: docs/CPU.md, docs/SUZY.md,
  docs/RUNNING.md (run-lynx), docs/m1_raycast.gif. Tag `snouty-lynx/m1`.
- 2026-10-01: M1 perf pass on `lynx/m1-perf` (host-side speed only: same
  hashes, tick counts, IRQs, pixels and sleep ticks at every 25th update
  of every lynx-tests cart, raycast every 10th, Hard Drivin' every 50th
  to update 1299; also with the clock rebase forced every 2^21 ticks;
  SingleStepTests 240,000 pass; 90 host tests). Calibrated badge-bench,
  RAM ELF, raycast m1_play.json, busy ms per 16.7 ms frame:

  | step (commit)                                   | mean  | p95   | worst | over |
  |-------------------------------------------------|-------|-------|-------|------|
  | before (234f47d)                                | 16.69 | 22.23 | 24.29 | 255  |
  | run loop skips Mikey catch-up between events    | 14.90 | 18.87 | 20.64 | 167  |
  | Suzy row stats: two counters, no per-row memcpy | 12.77 | 18.02 | 19.36 | 36   |
  | exec: one compile-time case per opcode          | 11.74 | 15.93 | 17.21 | 2    |
  | step + exec inlined into the run loop           | 10.70 | 13.99 | 15.11 | 0    |
  | bus clock and Mikey times in 32 bits            | 9.52  | 11.94 | 13.33 | 0    |
  | Suzy replays a line's spans on its next rows    | 8.86  | 12.27 | 13.69 | 0    |
  | display: pair table, two rows per word store    | 8.71  | 12.10 | 13.52 | 0    |
  | DMA/refresh catch-up in the run loop            | 8.53  | 11.55 | 12.99 | 0    |
  | Mikey advance_to (sprite-run sleep loop)        | 8.44  | 11.53 | 12.96 | 0    |

  Hot functions per frame, before -> after: run_frame (CPU loop +
  display) 808k -> run_cpu 617k + run_frame 38k (display 64k -> 42k);
  high_write (Suzy) 744k -> 511k; exec 461k -> inlined; memcpy 192k
  (1,278 calls) -> 7k (3.5: the vblank copy); run_events 88k -> 10k;
  alu/branch/rmw/bbx 130k -> inlined. Per unit: CPU ~99 host cycles per
  instruction (SPEC 8: 60), Suzy ~74 per pixel written (20: raycast's
  rows are ~5 px wide, per-row cost dominates), display 0.25 ms. Hard
  Drivin' (local romfs, hd_drive.json, 1,300 updates incl. menus): mean
  22.14 -> 11.59, p95 25.79 -> 14.58, worst 35.48 -> 20.07 (frame 1088),
  1,218 -> 2 frames over; CPU-bound (11.7k instructions a frame, run_cpu
  1.24M cycles). Tried and dropped: sampling the IRQ line once per run
  (fewer instructions, more cycles). Left for M4: the CPU loop (regs, PC
  and ticks live in memory: a register-resident tick count or PC would
  need a Bus contract change), Suzy's decoded-row cost (~235 cycles; the
  literal-bus udiv, per-type row functions), sprites4 DMA EXP W24 (needs
  a change to the DMA steal charged inside sprite runs: emulated timing,
  not done here).
- 2026-10-01: M1 contract written, prep commit with the frozen stubs on
  `lynx/m1`; tracks A (CPU), B (Suzy), C (machine) started.
- 2026-09-29: SPEC.md and this plan drafted; waiting on section 18.
- 2026-09-30: M0 DONE. Tracks A and B merged on `lynx/m0` (b950ebe), tag
  `snouty-lynx/m0`. Merged tree: root `zig build` builds every cart; the 22
  other uf2/wasm files are byte-identical to origin/main 2680e2a (compared
  from the same directory: the wasm files embed the build path, so hashes
  from different worktrees differ); `zig build test` 461/462, the one
  failure is demosnout's pre-existing `timeline` test (fails at 2680e2a
  too, not ours); Lynx 22/22 with the local test data (both boot ROM
  cross-checks match, 240,000 SingleStepTests cases parse). Sizes with
  raycast.lnx embedded: .text 57,124 B (27,765 of it the ROM), .bss 73,920,
  uf2 264,192, wasm 258,974. badge-bench fixture run: busy mean 0.70 ms,
  worst 0.76, 0 over, LEDs off. Open for M1: `core/boot.zig` and
  `core/cart.zig` each parse the header (unify in M1; boot's `Cart` is the
  test-side one), M1 must trap $FE00/$FE4A (docs/BOOT.md), badge-manager
  station set registration, hardware never seen (show-day gate).
- 2026-09-30: M0 Track A (boot) done on `lynx/m0-boot`; report below.
  ROM sizes and compression (tools/romcheck.py, sizes only): Hard Drivin'
  131,072 B headerless, 256 x 512 B, 3-block loader, zlib -9 57.8% (per
  16 KB: 70 55 66 52 58 60 43 59), zstd -19 55.0%; Blue Lightning 131,072
  B headerless, 256 x 512 B, 5-block loader, zlib 69.2% (73 66 67 55 84 87
  96 26), zstd 68.1%; raycast.lnx (shipped) 27,765 B headered, 1 KB
  pages, 1-block loader, zlib 27.5%, zstd 25.1%; lniccc2000_tsc.lnx (not
  shipped) 524,352 B, 2 KB pages, zlib 83.2%, zstd 83.0%. For SPEC 13.1: a
  128 KB commercial title packs to ~72-91 KB, so 256 KB titles would need
  ~140-180 KB of flash, the top of the estimate.


## Track B report (scaffold, branch `lynx/m0-scaffold`, 2026-09-30)

Files (all new unless noted):

- Root: `build.zig` (carts table line, `-Dlynx-rom`, `-Dlynx-rom-source`),
  `build/common.zig` (`lynx_rom`, `lynx_rom_source: RomSource`),
  `.gitignore` (`*.lnx`, `*.lyx`, `!carts/snouty-lynx/roms/placeholder.lnx`),
  `README.md` (cart row), `badge-bench/carts/snouty-lynx.toml`.
- `carts/snouty-lynx/`: `build.zig` (RAM cart + wasm, generated `rom`
  module, `drive` module, host tests on `zig build test` and
  `zig build test-lynx`), `CLAUDE.md`, `README.md` (ROM on the drive,
  Gear's wording), `docs/RUNNING.md`, `docs/m0_splash.png`,
  `docs/m0_screen.png`, `.gitignore`.
- `core/`: `lynx.zig` (`Lynx`, `Pad`, `Frame`, `init_in_place`, `reset`,
  `step_frame` = M0 test pattern, `frame()`), `cart.zig` (SPEC 7's name;
  `parse` -> `Layout`/`Refusal`, `Cart` = 256 block pointers + fallback),
  stubs `cpu65.zig` (`Regs`, `Cpu(Bus)`), `bus.zig` (addresses, MAPCTL
  bits), `mikey.zig` (palette, DISPADR), `suzy.zig`.
- `cart/src/`: `main.zig` (splash -> running, status strip, no-ROM help,
  wasm shims, 11 `debug_*` exports), `frontend/{video,input,drive,romsrc,
  splash,debug,text,menu}.zig` (`menu` is an M2 stub; `text` is Gear's
  verbatim; `drive` is a module of its own, as Genesis's).
- `tests/`: `all.zig`, `cart_unit.zig` (6 tests), `drive_unit.zig`
  (4 tests), `fixtures/make_fixtures.py` + `m0_drive.img` (18,944 B) and
  `m0_none.img` (11,264 B); plus the `lynx:` test in core/lynx.zig: 11/11.
- `roms/placeholder.lnx` (576 B: header declaring a 128 KB bank + one
  512 B block; not a Lynx program) from `tools/make_placeholder_rom.py`;
  `tools/scripts/m0_boot.json`.

Parser: headered = trust the header (bank 0 page size 256/512/1024/2048,
data at 64, short files allowed, missing bytes 0xFF); headerless = block
size from the file size (<= 128 KB 512 B, <= 256 KB 1 KB, <= 512 KB 2 KB).
Refused: bank 1, rotation, bad bank 0 size, over 512 KB, empty. EEPROM:
accepted, `warn_eeprom()`, strip shows `no-EEPROM`. Deviation: 64 KB banks
(256 B blocks) are accepted too (SPEC 11 lists 128/256/512 KB); Track A's
romcheck.py may want the same.

Sizes (ReleaseFast, drive source, placeholder embedded): `.text` 29,944 B,
`.data` 112, `.bss` 73,920 (the `Lynx` static 66,644 B, the romfs cluster
table 5,120 B); uf2 209,920 B; wasm 231,442 B. Free run-time arena
`__bss_end__` 0x2004e838 .. `__stack_limit__` 0x20078000 = 169,928 B
(168,904 B after Gear's 1 KB guard): what M1's code growth and the M3
scrub ring share. Console RAM is already in `.bss`, the ~8 KB frame lives
inside it (DISPADR), so the SPEC 13 ring target (>= 64 KB) fits unless M1
code grows by more than ~100 KB.

badge-bench (calibrated, busy ms, 300 frames, `m0_boot.json`, splash
skipped at 40 then the placeholder screen): fixture drive (GAME.LNX runs)
mean 0.70, p95 0.76, worst 0.76 (frame 40), start-up 2.28 ms; local
Hard Drivin' drive image (`out/lynx-romfs.img`, 128 KB headerless, crc
6DF63834) mean 0.71, worst 0.77, start-up 7.32 ms (the CRC over 128 KB);
no-ROM help (`m0_none.img`) mean 0.88, worst 0.96. 0 frames over budget,
neopixels never written. Hot: `run_frame` 81% (the frame conversion),
`text.draw` 13%.

Byte-identical check: every other cart's uf2 (11 files) and wasm
(11 files) from a clean `zig build` at `c25f5bb` (`out/baseline-*.sha256`)
equals the build with this branch. `zig build` succeeds for all carts;
`zig build test`: 472/473, the one failure is demosnout's
`timeline.test.hold: endless parts run on...` (expected .seamless, found
.fade), which fails identically at `c25f5bb` (checked in a detached
worktree): pre-existing, not touched here.

Preview: `node tools/preview.mjs` with `m0_boot.json` passes
`debug_state == 1`, `debug_led_max == 0`, Pause 256 at 105, Up+B 130 at
135, Option 1 (8) after the Select tap at 163.

Left as stubs / for later: cpu65, bus, mikey, suzy (M1); menu (M2; a
Select hold does nothing yet); no sound and no `build_options.sound` (add
it with the first tone, docs/SOUND.md); the 256-entry byte -> pair table
of SPEC 6 is a shift and mask for now (M4 measures); the picker (M2)
reads `romsrc.candidates()`; `pack` prints "not built". `-Dlynx-rom` has
no cart-relative form (no filesystem probe). Not registered in the
badge-manager station sets.

## Track A report (M0 boot, 2026-09-30)

**Facts (SPEC section 3, section 20).** Every item checked against the
Epyx documentation (monlynx.de), cc65, Felix (facts only), 42Bastian's
hardware carts and our boot ROM cross-check. Corrected in place: (1) the
Lynx CPU does execute RMB/SMB/BBR/BBS (Felix; 42Bastian's hardware
Snake249 uses BBR/SMB) and has no WAI/STP, so it is the Rockwell 65C02
set, not a "65SC02 without bit instructions"; (2) page mode: fetches 4
ticks, every other RAM/ROM access 5 ticks (not only page breaks); (3)
sprite type numbering (0 background-shadow .. 7 shadow); (4) the boot ROM
loads a frame of 1-5 blocks and loaders re-enter it at $FE00/$FE4A.
Confirmed: memory map and MAPCTL bits, timers and their chains, audio
registers, interrupts, display registers, cart block select (MSB first,
IODAT bit 1, SYSCTL1 bit 0 edge) and the 11-bit counter, SCB layout,
packed format, math unit, joystick (with the LEFTHAND swap). Open:
undefined-opcode timings on hardware ($5C: 4 cycles in SingleStepTests,
8 in Felix) and SP before reset.

**CPU tests (SPEC 16).** SingleStepTests `rockwell65c02/v1`.
`tools/fetch_test_roms.sh` fetches 24 files (~97 MB, 240,000 cases) plus
drhelius's MIT lynx-tests (19 carts); `--all` streamed all 256 files in
batches of 32 and all parse (tests/roms/65c02/results.txt).
`tests/cpu65_single_step.zig` parses and shape-checks them; M1 adds the
CPU run.

**Boot (core/boot.zig, docs/BOOT.md).** `Cart.from_file` (headered or
headerless), `post_boot(cart, ram) BootError!BootState` (RAM, registers,
MAPCTL, IODIR/IODAT/SYSCTL1, Mikey writes, cart block/counter),
`decrypt_frame(reader, ram)` for the $FE4A trap, `SetCartBlockExit` for
the $FE00 trap. Public constants only (annotated disassembly and
lynx-encryption-tools, which agree); 13 x 32-bit limbs, no allocator, no
floats. Functions are snake_case per the repo style (`post_boot`, not
`postBoot`).

**Cross-check.** `tools/bootrom_crosscheck.py` (py65) runs the local boot
ROM image against each cart until the loader hands over to the game;
`tests/boot_crosscheck.zig` compares. Hard Drivin' and Blue Lightning
match exactly in registers (A 0, X 0, Y 2, P $37, SP $01), MAPCTL 0,
IODIR 3, IODAT 2, SYSCTL1 2, cart counter (154, 256), Mikey values, the
loader bytes, zero page $00-$07, all other RAM outside the ROM's work
areas, and the second $FE4A pass of each (bytes, counter, flags; Hard
Drivin' leaves P $36). Loaders use only $FE00 (331 and 266 calls) and
$FE4A (once) and reach game code at $3A51 / $137B with no timer model.
The public route is complete; the 18.2 fallback was not used. Not
reproduced: ROM work bytes in $08-$1FF and its routine copy at
$5000-$50FF (ROM code; no loader calls it directly).

**Shipped ROM.** `roms/raycast.lnx`, 42Bastian's textured raycaster,
Apache-2.0 (`roms/LICENSE-raycast.txt`), 27,765 B; boots in a host test.
Survey in `docs/ROM_CANDIDATES.md`.

**Tests.** 12 host tests (`zig build test -Dcart=snouty-lynx`): 5
known-answer/unit (cc65 bootldr.s and Wookie loaders, arithmetic, rejects,
header), 3 loader plausibility (2 local dumps, skipped when absent;
raycast), 2 boot ROM cross-checks (skipped without the JSON), 1 SST parse
(skipped without data), plus the entry test. All pass on the VM.

**Files.** `build.zig` (root: one cart line), `.gitignore` (root: `*.lnx`,
`*.lyx`, raycast exception), `carts/snouty-lynx/`: `.gitignore`,
`build.zig` (tests only), `core/boot.zig`, `tests/{all,testfiles,
boot_unit,boot_local,boot_crosscheck,cpu65_single_step}.zig`,
`tools/{fetch_test_roms.sh,bootrom_crosscheck.py,romcheck.py}`,
`docs/{BOOT,ROM_CANDIDATES}.md`, `roms/{raycast.lnx,LICENSE-raycast.txt}`,
`SPEC.md` (sections 3, 7, 11, 16, 18.2, 19, 20, status), this file.

**For the integrator (merge with Track B).** `carts/snouty-lynx/build.zig`
is Track A's tests-only `add`: keep Track B's, and add the test block
(a `boot` module rooted at `core/boot.zig`, imported by `tests/all.zig`;
or a `core` module and `tests/*.zig` switched to it). The root
`build.zig` cart line and the root `.gitignore` `*.lnx`/`*.lyx` lines
will conflict with Track B's identical ones: keep one copy and keep the
`!carts/snouty-lynx/roms/raycast.lnx` exception below them. If Track B
added `tests/all.zig` or `carts/snouty-lynx/.gitignore`, merge the
imports / lines (`tests/roms/`, `out/`). Track B's `-Dlynx-rom` default
should be `roms/raycast.lnx`. M1 must trap $FE00 and $FE4A (docs/BOOT.md
"What M1 needs").
