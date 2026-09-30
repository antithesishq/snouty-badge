# Snouty Genesis: plan

SPEC.md is the design. This file is the working contract for the current
milestone: who owns which files, the frozen interfaces, what "done" means.
Section 18 of SPEC.md was closed by Adrian on 2026-09-29: execute now,
sound from M1, stock firmware. Work happens in git worktrees on
`genesis/*` branches (the main tree carries other sessions' work);
milestones ff-merge into main.

## M0 Scaffold (two Opus tracks, then integration)

Both tracks branch from `genesis/m0`, own disjoint files, and never touch
another cart. Snouty Gear (`carts/snouty-gear/`) is the template for
everything: copy, rename, cut.

### Track S: cart scaffold (branch `genesis/m0-scaffold`)

Files: `carts/snouty-genesis/{build.zig,CLAUDE.md,README.md}`,
`core/*.zig`, `cart/src/**`, `tests/all.zig`, `tests/smoke.zig`,
`badge-bench/carts/snouty-genesis.toml`, `docs/RUNNING.md`, one line in
the root `build.zig` `carts` table and its `-Dmd-rom` /
`-Dmd-rom-source` options in `build/common.zig`, one row in the root
README, `.gitignore` entries per SPEC.md section 11.

- The cart builds in XIP mode only: `-Dcart=snouty-genesis` without
  `-Dcart-mode=xip` fails at configure time with a message pointing at
  SPEC.md section 13. `-Dmd-rom=path` picks the embedded ROM (default
  `roms/snouty-test.bin`, produced by Track R).
- `core/md.zig` defines the whole console state (`Md`) with every field
  of SPEC.md section 10 sized for real, `reset()`, `step_frame(pad,
  render)` and `tone()` as stubs, and `Keyframe`. The subsystem files of
  SPEC.md section 7 exist as compiling stubs with their public function
  signatures from the M1 contract below, so the M1 tracks start from
  agreed names. `core/z80bus.zig` instantiates Gear's `Z80(Z80Bus)` once
  to prove the cross-cart module import builds.
- The frontend (`cart/src/main.zig`, `frontend/{video,input,debug,text,
  romsrc}.zig`) is Gear's, adapted: draws a 160x128 test pattern through
  the `line_sink` path, shows the overlay with the ROM source line, has
  the wasm shims so `tools/preview.mjs` works.
- `tests/all.zig` imports `tests/smoke.zig` (Md constructs, one frame
  steps, sizes of `Md` and `Keyframe` printed and asserted under the
  SPEC.md section 13 estimates).
- `badge-bench/carts/snouty-genesis.toml`: XIP ELF, 120 updates, no
  input. `docs/RUNNING.md`: build, preview, bench, drive image.
- Done when `zig build -Dcart=snouty-genesis -Dcart-mode=xip`,
  `zig build test -Dcart=snouty-genesis` (or the equivalent test step)
  and `zig build` (all carts) pass, the test pattern shows in
  `tools/preview.mjs`, badge-bench runs the toml, and every other cart's
  uf2 is byte-identical to before (hashes in `out/m0_baseline.txt`).

### Track R: ROMs and tools (branch `genesis/m0-roms`)

Files: `carts/snouty-genesis/tools/{fetch_test_roms.sh,romcheck.py}`,
`tools/testrom/**`, `roms/**`, `docs/ROMS.md`.

- `tools/testrom/`: a small original Genesis ROM built from source with
  the GNU m68k toolchain (`gcc-m68k-linux-gnu`, `binutils-m68k-linux-gnu`
  from apt; Adrian's Mac does not need it because the binary is
  committed): `crt0.s` (vectors, header at `0x100` with "SEGA GENESIS",
  domestic name "SNOUTY TEST", checksum), `main.c` (VDP init for H40 V28,
  palette, a tile pattern on plane A, a moving sprite driven by the pad,
  a PSG tone from the 68000, a Z80 driver loaded to Z80 RAM that keys one
  YM2612 channel and toggles a note every 30 frames, an H-int raster
  colour change), `z80.s` (the driver), `md.ld`, `Makefile`, `build.sh`
  that reproduces `roms/snouty-test.bin` byte for byte. Repository
  licence, `roms/LICENSE-snouty-test`. Keep it under 32 KB. This ROM is
  the golden-test and badge-bench target.
- Homebrew research: find Genesis homebrew with an explicit
  redistributable licence (candidates to check: Sik's Project MD and
  other SGDK-era releases, Mojon Twins titles, Retail Clerk '89,
  itch.io freeware with CC licences). GitHub's API is rate-limited from
  the VM: read release and repository pages as HTML. Record every
  candidate, its licence text location and a verdict in `docs/ROMS.md`;
  commit at most one clean ROM under `roms/` with `roms/LICENSE-<name>`
  and a root `.gitignore` exception (coordinate the pattern with Track S:
  Track R owns the exception lines, Track S owns the ignore lines).
- `tools/fetch_test_roms.sh`: confirms the 68000 SingleStepTests
  repository (`github.com/SingleStepTests/680x0`, or wherever it lives
  now) and its licence, downloads the JSON per instruction class into
  `tests/roms/68000/` (gitignored) in batches as Gear does, with a
  `--all` mode; prints the total size first. Record the repository URL,
  licence, file count and size in `docs/ROMS.md`.
- `tools/romcheck.py`: header parse (name, region, checksum, SRAM
  declaration), SMD interleave detection, size against the SPEC.md
  section 13 ceiling, mapper and SVP refusal, Z80 driver heuristics
  (writes to `A11100`/`A11200`, copies into `A00000`), verdict. Run it on
  `roms/snouty-test.bin` and on Adrian's local ROMs if any are on the VM
  (`ls ~/*.gen ~/*.bin ~/*.md 2>/dev/null`; never copy them into the
  repo).
- Done when `build.sh` reproduces the committed binary, `romcheck.py`
  passes it, `fetch_test_roms.sh` works, and `docs/ROMS.md` is written.

### M0 integration (me)

1. Merge both tracks into `genesis/m0`; default `-Dmd-rom` to
   `roms/snouty-test.bin`; rerun the scaffold's done list.
2. Sizes (`size -A` of the XIP ELF) and `Md`/`Keyframe` sizes recorded in
   the status below against SPEC.md section 13.
3. Tag `snouty-genesis/m0`, ff-merge to main, push, pull-and-run notes.
4. Hardware check (open, not a gate since 2026-09-29): Adrian confirms
   an XIP cart launches on the badge when one is available.

## M1 Core: contract

Four Opus agents in their own git worktrees and branches, disjoint files.
Nobody edits another track's files; a needed change goes in the final
report and is stubbed locally.

### Frozen for M1: `core/md.zig`, `core/rom.zig`'s interface, timing

- `Md.step_frame(pad: u16, render: bool)`: for each of the 262 lines,
  runs the 68000 until it has consumed the line's 488 or 489 cycles
  (`m68k.step(&bus)` returns 68000 cycles; the remainder carries over),
  then runs the Z80 for the line's 228 Z80 cycles (`z80_scale` applied,
  remainder carried over) unless it is stopped by BUSREQ or RESET, then
  `vdp.end_line()`. Lines are rendered at their start, only when `render`
  is set and only those in the line table. V-int (68000 level 6, Z80 INT
  for one line) at line 224; H-int (level 4) from the register 10 counter.
- `Bus` (in `core/bus.zig`, a concrete struct holding `*Md`) provides
  `read8(addr: u24) u8`, `read16(addr: u24) u16`, `write8`, `write16`.
  `M68k(comptime BusT)` calls only those, plus `BusT.irq_level() u3`
  sampled between instructions and `BusT.ack_irq(level)`.
- `Z80Bus` (in `core/z80bus.zig`, a concrete struct holding `*Md`)
  satisfies Gear's `Z80(comptime BusT)` requirements exactly as Gear's
  `bus.zig` does (read/write memory, in/out ports, irq state); ports are
  unused on the Genesis (no `IN`/`OUT` devices; reads return `FF`).
- `RomSource`: `size: u32`, `base: ?[*]const u8` (contiguous fast path),
  `clusters: []const u16` (cluster number per 512 B otherwise, over
  `data_base`). `rom.read16(src, addr)` and `rom.read8` are the only
  accessors either bus uses.
- `md.line_sink` receives each rendered badge row as `[160]u8` (6-bit
  palette index plus the shadow/highlight tag in bits 6-7) and the current
  `*const [64]u16` 9-bit CRAM, so the frontend owns color conversion.
- `Md.tone() ?Tone` with `Tone = struct { hz: u16, level: u4 }`: SPEC.md
  section 9's pick, computed from the register models at the end of
  `step_frame`; the frontend issues `tone2` on change.
- Pad: bit set = pressed, `up down left right a b c start`.
- `Keyframe` covers `Md` minus the ROM source and the sink.

### Track A: 68000 (files `core/m68k.zig`, `core/m68k_tables.zig` (generated), `tools/gen_m68k.py`, `tests/m68k_single_step.zig`)

- Every 68000 instruction and addressing mode, SR and CCR semantics,
  supervisor/user stacks, exceptions (TRAP, TRAPV, CHK, divide by zero,
  privilege violation, illegal and line A/F), interrupt priority mask and
  autovectors, STOP, documented cycle counts incl. EA and taken-branch
  variants, MOVEM, DIVU/DIVS/MULU/MULS timing formulas.
- Decode: build both a 64 K x u8 handler table and a two-level decode
  behind one switch, report code size and badge-bench cycles per
  instruction for each; M1 integration picks one against SPEC.md
  section 13.
- `tests/m68k_single_step.zig`: reads `tests/roms/68000/*.json` with
  `std.json` on the host, flat 16 MB sparse memory bus; checks final
  registers, SR, memory and cycle count. Skips cleanly if the files are
  absent.
- Record host run times; if the full set takes over 60 s in Debug, run it
  under `ReleaseSafe` via the test optimize option.

### Track B: VDP (files `core/vdp.zig`, `core/vdp_tables.zig`, `tests/vdp_unit.zig`)

- Control-word latch (two-word commands with code and address), data port
  reads and writes to VRAM/CRAM/VSRAM, auto-increment, register writes,
  status read side effects, HV counter.
- DMA: 68000 to VRAM/CRAM/VSRAM (through a bus read callback, so ROM DMA
  reads use `RomSource`), VRAM fill, VRAM copy; instant, with a cycle
  charge returned to the caller.
- Counters: lines 0..261, V-int at 224, H-int counter from register 10,
  `irq_level()`.
- Column and line tables (SPEC.md section 6), `render_line(row)` for H40
  and H32: planes A and B with every scroll mode, window, sprites with
  the link list and per-line limits, priority, shadow/highlight.
- Tests: each item above from synthetic states.

### Track C: machine and frontend (files `core/bus.zig`, `core/rom.zig`, `core/md.zig` (frame loop only), `tests/bus_unit.zig`, `tests/golden.zig`, `cart/src/**`, `tools/scripts/*.json`, `docs/RUNNING.md`)

- Bus: 68000 memory map, mirrors, I/O and 3-button pad protocol (TH
  select), arbiter (BUSREQ/RESET state, forwarding of `A00000-A0FFFF` to
  `Z80Bus` when held), SRAM, 68000-side PSG writes.
- `rom.zig`: embedded source, header parse, SMD detection, `read16`.
- `md.zig`: the frame loop of the contract above, `tone()` calling into
  Track D's picker.
- Frontend: `video.zig` (index to `Pixel` cache, shadow/highlight),
  `input.zig` (Select tap versus hold), `audio.zig` (tone on change),
  `debug.zig` overlay, `main.zig` with the wasm shims and the 60/30 loop,
  from M0's scaffold.
- `tests/golden.zig`: scripted run of the shipped ROM, frame hashes and
  the `tone()` sequence at fixed frames; filled in at integration after
  an eyeball and an ear check.

### Track D: sound side (files `core/z80bus.zig`, `core/ym2612.zig`, `core/psg.zig`, `tests/sound_unit.zig`)

- `Z80Bus`: SPEC.md section 9's map, bank register shifting, the 68000
  bank window through `rom.read8` and work RAM, `INT` for one line at
  V-int, HALT handling with Gear's core.
- `ym2612.zig`: register file for both parts, latches, key-on, timers A
  and B (flag set from the 68000/Z80 cycle count fed by `md.zig`, busy
  flag never set), DAC enable, channel 3 special mode; `pick()` per
  section 9.
- `psg.zig`: SN76489 register model, either CPU writes, `pick()`.
- Tests: bank register sequences, window reads, timer flag timing, the
  picker on synthetic register files (key-on/off, TL ordering, DAC skip,
  PSG versus FM), and a Z80 program in Z80 RAM that writes the YM2612
  through Gear's core.

### Integration (me, after the four merge)

1. `zig build test` green; ProcessorTests numbers recorded.
2. The shipped test ROM and any clean homebrew playable in the simulator;
   Sonic 1 from `~/` if present (never committed); preview GIF; the tone
   sequence heard once in the simulator.
3. Decode-table choice made from Track A's numbers.
4. badge-bench on the XIP ELF with `tools/scripts/m1_play.json`: update
   mean under 31 ms, worst under 33 ms, calibrated; the Z80's share
   measured separately (`z80_scale = 0` run). Record the table here and
   apply SPEC.md section 8's fallbacks in order if it misses.
5. Sizes (`size -A`) recorded against SPEC.md section 13, and the ROM
   ceiling recomputed from the real flash image.
6. Tag `snouty-genesis/m1`; pull-and-run notes. Hardware check (open,
   not a gate): Adrian flashes and reports the overlay numbers when a
   badge is available.

## Status

- 2026-09-29: SPEC.md, this plan and `docs/ROM_STREAMING.md` drafted;
  waiting on section 18.
- 2026-09-29 (later): section 18 closed by Adrian. M0 started on
  `genesis/m0` (worktree `/home/exedev/snouty-badge-genesis`), tracks S
  and R as above.
- 2026-09-29 (M0 DONE): tag `snouty-genesis/m0`. Track S (4 commits) and
  Track R (5 commits) merged; main (Snouty Gear M2) merged in.
  - Shipped ROMs: `roms/snouty-test.bin` (16 KB, original, rebuilt byte
    for byte by `tools/testrom/build.sh`, MIT) and `roms/miniplanets.bin`
    (Sik's Miniplanets REMIX REV04, 512 KB, zlib; drive/simulator target
    only). Verdicts for the rest in `docs/ROMS.md`.
  - 68000 SingleStepTests: `github.com/SingleStepTests/680x0`, 124 gzipped
    JSON files, 193 MB, no licence file (fetched, never committed); the
    default subset (36 files, 57 MB) is in `tests/roms/68000/`.
  - Verification: XIP build, RAM build refused, `-Dcart` lists and the
    all-carts build all embed the test ROM; 7/7 host tests; test pattern
    in `docs/m0_pattern.png`; every other cart's uf2 byte-identical.
  - Sizes: `.text` 45,100 B (incl. the 16 KB ROM), `.data` 140, `.bss`
    147,704 (`Md` 140,264, `Keyframe` 140,200); uf2 91,136 B. The Z80
    core is not linked yet (nothing calls it), so the flash estimate of
    SPEC section 13 is untested until M1.
  - badge-bench (stub, empty drive image): 1.14 ms mean, 1.17 worst.
  - Lessons: this Zig caches the configure phase's graph by build files
    and options, so `build.zig` must not decide from a file's existence
    (the scaffold's placeholder ROM survived the real one for an hour;
    rule now in CLAUDE.md). Tests inside an imported module do not run in
    Zig 0.17 (Gear's `gg.zig` keyframe test probably never ran). Reset
    arrays with `@memset`, never `v.* = .{}` (64 KB default image in
    `.text`). SPEC section 9's FM formula fixed (YM2612 clock is master/7).
    `Md.z80.reset()` still uses Gear's Game Gear post-BIOS state: Track D
    sets the Genesis one. SRAM is not in `Md` yet: Track C adds it.
  - Open for Adrian: the repository has no root LICENSE; the test ROM was
    given MIT under Adrian's name. Gate: flash `snouty-genesis-xip.uf2`
    and confirm an XIP cart launches (test pattern + overlay).
- 2026-09-29 (M1 started, Adrian: proceed). No badge is available until
  the day of the show, so the calibrated badge-bench is the reference for
  every milestone and the hardware checks (XIP launch, drive streaming
  stall rates) are open items, not gates. Integration branch `genesis/m1`
  in `/home/exedev/snouty-badge-genesis`; tracks A-D in worktrees
  `/home/exedev/snouty-badge-genesis-{m68k,vdp,machine,sound}` on
  `genesis/m1-{m68k,vdp,machine,sound}`.
- 2026-09-30 (M1 perf pass, branch `genesis/m1-perf` from `9b933d7`,
  worktree `/home/exedev/snouty-badge-genesis-perf`). Integration step 4:
  targets met with the defaults (full speed, no fallback). Behaviour
  bit-identical throughout: the test ROM's golden lines and the new
  `golden-mini` run (Miniplanets, 600 frames into level 1, frame + tone +
  state hashes) unchanged after every commit. badge-bench calibrated, ms
  per update (mean / worst), Miniplanets from `out/romfs_mini.img` with the
  toml's 120-update script and with `tools/scripts/m1_mini300.json` (300
  updates, Start at 100/130/160, level 1 from ~170):

  | Change | Mini 120 | Mini 300 | Test ROM | `.text` |
  |---|---|---|---|---|
  | integration `9b933d7` | 34.65 / 37.67 | 35.33 / 39.29 | 22.75 / 26.30 | 200,732 |
  | hot `Md` fields within 4 KB | 32.04 / 34.93 | | 21.49 / 25.54 | 185,100 |
  | Z80 step inlined | 29.45 / 32.08 | 29.96 / 32.87 | 21.17 / 25.07 | 196,252 |
  | IRQ level cached in the VDP | 28.03 / 30.57 | 28.61 / 31.13 | 20.64 / 23.60 | 197,452 |
  | wait loops skipped exactly | 19.68 / 30.74 | 20.69 / 31.63 | 8.80 / 24.04 | 198,236 |
  | DMA copied from ROM/RAM | 19.52 / 30.74 | 20.29 / 30.74 | 8.80 / 24.04 | 199,500 |
  | (An), (An)+ operands inline | 18.61 / 28.11 | 19.47 / 28.11 | 8.77 / 24.21 | 204,572 |

  Worst updates are Miniplanets' boot (update 12, Z80 driver upload and
  tile loads) and its level load (update 143, ~26.7 ms now); they do not
  wait for V-int, so the wait-loop skip does nothing for them. Measured
  and rejected: the `z80` module at ReleaseSmall (-21 KB flash, +3.5 ms
  on Miniplanets); inline bus accessor fast paths (+19 KB, no gain);
  d16(An) inline too (+22 KB, slower); a per-instruction wait-loop check
  in `run_m68k` (+4-5 cycles per 68000 instruction from spills). Z80
  share in play: `run_z80` 30% (5.8 ms per update; its core is Gear's,
  its main loop polls the YM2612 timer flag all frame).
