# Snouty Gear: plan

SPEC.md is the design. This file is the working contract for the current
milestone: who owns which files, the frozen interfaces, what "done" means.
SPEC.md section 18 was decided 2026-09-29; the ROM is Waternet.

## M0 Scaffold (one agent, then me)

- `carts/snouty-gear/` per SPEC.md section 15; one line in the root
  `build.zig` `carts` table; `-Dgg-rom=` in `common.Options` (default the
  shipped ROM in `roms/`); `-Dcart-optimize` shared with Snouty Boy (it is
  already global). Host test target on `tests/all.zig`.
- `core/gg.zig` defines the whole console state and `step_frame`; the
  subsystem files compile as stubs; the frontend draws a test pattern.
- `tools/fetch_test_roms.sh` (zexall-sms v0.21, SingleStepTests Z80 by
  sparse checkout of `v1/`), `tools/romcheck.py`, `roms/<game>.gg` +
  `roms/LICENSE-<game>`, `badge-bench/carts/snouty-gear.toml`,
  `CLAUDE.md`, `docs/RUNNING.md`, root README row.
- Done when: `zig build -Dcart=snouty-gear` (RAM and `-Dcart-mode=xip`)
  and `zig build test` pass, the test pattern shows in a headless
  preview, every other cart's uf2 is byte-identical to before.

## M1 Core: contract

Three Opus agents in their own git worktrees and branches, disjoint files.
Nobody edits another track's files; a needed change goes in the final
report and is stubbed locally.

### Frozen for M1: `core/gg.zig`

- `Gg.step_frame(pad: u8)`: runs `z80.step(&bus)` (returns T-states) and
  `vdp.tick(t)` until the VDP reports the end of line 261.
- `Bus` (in `core/bus.zig`, a concrete struct holding `*Gg`) provides
  `read(addr: u16) u8`, `write(addr: u16, v: u8)`, `in(port: u8) u8`,
  `out(port: u8, v: u8)`. `Z80(comptime BusT)` calls only those, plus
  `BusT.irq_line() bool` sampled between instructions.
- `gg.line_sink` receives each rendered visible line as `[160]u4` palette
  indices (0..31) plus the current `*const [32]u16` 12-bit CRAM, so the
  frontend owns color conversion.
- Pad byte: bit set = pressed, `up down left right b1 b2 start`.
- `Keyframe` copies `Gg` minus the ROM pointer and the sink.

### Track A: Z80 (files `core/z80.zig`, `core/tables.zig` (generated), `tools/gen_tables.py`, `tests/z80_single_step.zig`, `tests/z80_zex.zig`)

- Every documented and undocumented opcode in all prefix groups, flags
  incl. X/Y and WZ, R register low 7 bits, IFF1/IFF2, IM 0/1/2 (1 is what
  the Game Gear uses), HALT, EI delay, interrupt acceptance cost, correct
  T-states incl. taken/not-taken and block-instruction repeats.
- `tests/z80_single_step.zig`: reads `tests/roms/z80/v1/*.json` with
  `std.json` on the host, flat 64 KB memory bus, port reads from the test's
  `ports` list; checks final registers, memory, port writes and cycle count.
  Skips cleanly if the files are absent.
- `tests/z80_zex.zig`: runs `zexdoc.sms` / `zexall.sms` on a minimal bus
  (mapper, RAM, SDSC console capture on ports `FC/FD`, everything else
  ignored) until the "Tests complete" text; every test line must read OK.
- Record host run times; if ZEXALL takes over 60 s in Debug, run it under
  `ReleaseSafe` via the test optimize option.

### Track B: VDP (files `core/vdp.zig`, `tests/vdp_unit.zig`)

- Control-port latch (first byte, second byte with code), VRAM
  read-ahead buffer, CRAM writes as byte pairs (Game Gear), register
  writes, status read clearing flags and the latch.
- Counters: line 0..261, V counter jumps as documented for 192-line NTSC,
  H counter from T-state position. Frame IRQ at line 192 (if enabled), line
  counter reloaded from register 10 outside the active area, IRQ on
  underflow. `irq_line()` for the bus.
- `render_line(y)` for Game Gear lines 24..167 only, columns 48..207 only,
  called at the start of the line; skipped lines (squeeze) still run
  sprite evaluation for the overflow and collision flags.
- Tests: scroll and both locks, left-column blank, BG priority over
  sprites, flips, 8 sprites per line + overflow, 8x16, zoom, shift-left,
  collision flag, line-counter reload and IRQ timing, status side effects.

### Track C: machine and frontend (files `core/bus.zig`, `core/psg.zig`, `core/rom.zig`, `tests/bus_unit.zig`, `tests/psg_unit.zig`, `tests/golden.zig`, `cart/src/**`, `tools/scripts/*.json`, `docs/RUNNING.md`)

- Bus: memory map, Sega mapper with the first 1 KB fixed, cart RAM (8 KB
  cap unless `romcheck.py` says otherwise), RAM mirror, port decode per
  SPEC.md section 3, SDSC console capture (tests only, compiled in always,
  it costs a compare).
- PSG register model per SPEC.md section 9.
- Frontend: `video.zig` (squeeze/crop map, CRAM -> `Pixel` cache),
  `input.zig`, `debug.zig` overlay, `main.zig` with the wasm shims, copied
  from Snouty Boy and adapted.
- `tests/golden.zig`: scripted run of the shipped ROM, frame hashes at
  fixed frames; hashes filled in at integration after an eyeball review.

### Integration (me, after the three merge)

1. `zig build test` green; ZEX and SingleStepTests numbers recorded.
2. The shipped ROM playable in the simulator start to finish; preview GIF.
3. badge-bench on the RAM and XIP ELFs with `tools/scripts/m1_play.json`:
   mean under 8 ms, worst under 12 ms, calibrated. Record the table here.
4. Sizes (`size -A`, fast and small) recorded against SPEC.md section 13.
5. Tag `snouty-gear/m1`; pull-and-run notes. Gate: Adrian flashes and
   reports the overlay numbers.

## Status

- 2026-09-29: SPEC.md and this plan drafted; section 18 decided. Next: M0.
