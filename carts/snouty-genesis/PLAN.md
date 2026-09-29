# Snouty Genesis: plan

SPEC.md is the design. This file is the working contract for the current
milestone: who owns which files, the frozen interfaces, what "done" means.
Nothing below is started until Adrian has answered SPEC.md section 18.

## M0 Scaffold (one agent, then me)

- `carts/snouty-genesis/` per SPEC.md section 15; one line in the root
  `build.zig` `carts` table; the cart builds in XIP mode only and a RAM
  build fails with a pointer to SPEC.md section 13; `-Dmd-rom=` in
  `common.Options` (default the shipped ROM in `roms/`). Host test target
  on `tests/all.zig`.
- `core/md.zig` defines the whole console state and `step_frame`; the
  subsystem files compile as stubs; the frontend draws a test pattern.
- `tools/fetch_test_roms.sh` (68000 ProcessorTests, sparse checkout;
  confirm repository and license), `tools/romcheck.py`,
  `tools/make_fat_image.py` (stub), `roms/<game>` + `roms/LICENSE-<game>`,
  `badge-bench/carts/snouty-genesis.toml`, `CLAUDE.md`, `docs/RUNNING.md`,
  root README row, `.gitignore` entries per SPEC.md section 11.
- Done when: `zig build -Dcart=snouty-genesis -Dcart-mode=xip` and
  `zig build test` pass, the test pattern shows in a headless preview,
  every other cart's uf2 is byte-identical to before.
- Gate: Adrian confirms an XIP cart launches on the badge (shared with
  Snouty Gear M4 if that runs first).

## M1 Core: contract

Three Opus agents in their own git worktrees and branches, disjoint files.
Nobody edits another track's files; a needed change goes in the final
report and is stubbed locally.

### Frozen for M1: `core/md.zig` and `core/rom.zig`'s interface

- `Md.step_frame(pad: u16, render: bool)`: runs `m68k.step(&bus)` (returns
  68000 cycles) and `vdp.tick(cycles)` until the VDP reports the end of
  line 261; lines are rendered only when `render` is set and only those in
  the line table.
- `Bus` (in `core/bus.zig`, a concrete struct holding `*Md`) provides
  `read8(addr: u24) u8`, `read16(addr: u24) u16`, `write8`, `write16`.
  `M68k(comptime BusT)` calls only those, plus `BusT.irq_level() u3`
  sampled between instructions and `BusT.ack_irq(level)`.
- `RomSource`: `size: u32`, `base: ?[*]const u8` (contiguous fast path),
  `clusters: []const u32` (flash address per 512 B cluster otherwise).
  `rom.read16(src, addr)` is the only accessor the bus uses.
- `md.line_sink` receives each rendered badge row as `[160]u8` (6-bit
  palette index plus the shadow/highlight tag in bits 6-7) and the current
  `*const [64]u16` 9-bit CRAM, so the frontend owns color conversion.
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

### Track B: VDP (files `core/vdp.zig`, `tests/vdp_unit.zig`)

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

### Track C: machine and frontend (files `core/bus.zig`, `core/psg.zig`, `core/rom.zig`, `tests/bus_unit.zig`, `tests/golden.zig`, `cart/src/**`, `tools/scripts/*.json`, `docs/RUNNING.md`)

- Bus: memory map, mirrors, I/O and 3-button pad protocol (TH select),
  Z80 arbiter stub and Z80 RAM (SPEC.md section 9), SRAM, PSG writes.
- `rom.zig`: embedded source, header parse, SMD detection, `read16`.
- Frontend: `video.zig` (index to `Pixel` cache, shadow/highlight),
  `input.zig` (Select tap versus hold), `debug.zig` overlay, `main.zig`
  with the wasm shims and the 60/30 loop, copied from Snouty Gear and
  adapted.
- `tests/golden.zig`: scripted run of the shipped ROM, frame hashes at
  fixed frames; hashes filled in at integration after an eyeball review.

### Integration (me, after the three merge)

1. `zig build test` green; ProcessorTests numbers recorded.
2. The shipped ROM playable in the simulator start to finish; preview GIF.
3. Decode-table choice made from Track A's numbers.
4. badge-bench on the XIP ELF with `tools/scripts/m1_play.json`: update
   mean under 28 ms, worst under 31 ms, calibrated. Record the table here.
5. Sizes (`size -A`) recorded against SPEC.md section 13, and the ROM
   ceiling recomputed from the real flash image.
6. Tag `snouty-genesis/m1`; pull-and-run notes. Gate: Adrian flashes and
   reports the overlay numbers.

## Status

- 2026-09-29: SPEC.md, this plan and `docs/ROM_STREAMING.md` drafted;
  waiting on section 18.
