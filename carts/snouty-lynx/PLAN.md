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
  fine), RCART reads 15, all into `Lynx.ticks: u64`.
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

## Status

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
