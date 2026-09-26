# Snouty Boy: plan

SPEC.md is the design. This file is the working contract for the current
milestone: who owns which files, what the interfaces are, what "done" means.

## M0 Scaffold (done 2026-09-26)

- Repo layout per SPEC.md section 15. `build.zig` builds the cart
  (`-Drom=`, `-Dcart-optimize=`) and `zig build test` runs host tests
  (`-Dtest-filter=`).
- `core/gb.zig` defines the whole console state (`Gb`, `Keyframe`,
  `LineSink`, `Pad`, `Reg`, `Irq`) and the frame loop. Subsystems are stubs
  that compile and emit a test pattern.
- `cart/src/main.zig` runs one core frame per badge frame with the wasm
  shims; `frontend/video.zig` maps lines to the framebuffer.
- `tools/fetch_test_roms.sh` (Blargg, dmg-acid2), `tools/romcheck.py`,
  `tests/acid2_reference.bin` (160x144 shades, 0 = lightest, row-major).

## M1 Core on hardware: contract (merged 2026-09-26, tag `m1`; gate pending)

Three tracks in parallel, each in its own git worktree and branch, disjoint
files. Nobody edits another track's files; if you need a change there,
write it down in your final report and stub around it locally.

### Shared, frozen for M1 (edit only by agreement): `core/gb.zig`

- `Gb.step_frame(pad)`: runs `cpu.step` + `gb.tick(m)` until the PPU sets
  `gb.vblank_hit`, or for 17,556 M-cycles with the LCD off.
- `gb.tick(m)` fans out to `timer.tick`, `ppu.tick`, `mmu.tick_dma`,
  `apu.tick`, `serial.tick`, all `(gb: *Gb, m: u8)` in M-cycles.
- Registers live in `gb.io[0x00..0x80]` (offsets in `Reg`). Subsystem
  structs hold only what is not a register (`Cpu`, `Ppu`, `Timer`, `Mbc`).
  Adding fields to your own struct is fine; the `Keyframe` copies the
  struct whole.
- `gb.request_irq(Irq.x)` sets IF. `gb.line_sink` receives each rendered
  visible line as `[160]u8` final shades (0 lightest .. 3 darkest).
- Pad byte: `Pad.right..Pad.start` (bit set = pressed), fed by the frontend.

### Track A: CPU, memory, timer (files: `core/cpu.zig`, `core/mmu.zig`, `core/timer.zig`, `core/serial.zig`, `core/joypad.zig`, `tests/blargg.zig`)

- SM83: every opcode incl. CB prefix, flags, DAA, HALT (+ HALT bug), STOP
  as HALT, EI delay, interrupt dispatch (5 M-cycles), correct M-cycle counts
  (branch taken vs not). `step` returns 1..6 (interrupt dispatch 5).
- MMU: full map, echo RAM, OAM, HRAM, IE, I/O dispatch. Reads of
  unmapped/write-only bits return 1s where documented. `0xFF40..0xFF4B`
  delegate to `ppu.write_reg` / `ppu.read_reg` (track B implements them;
  the stubs store/load `gb.io` so A can proceed). SC write with bit 7 calls
  `serial.start_transfer`. Joypad `P1` select bits via `joypad.update`.
- MBC none / MBC1 (with mode bit and 0x20/0x40/0x60 quirk) / MBC3 (no RTC)
  / MBC5, keeping `rom_bank_offset` / `ram_bank_offset` cached; RAM enable.
  Cart RAM capped at 8 KB.
- Timer: DIV 16-bit, TIMA at the 4 TAC rates, overflow reloads TMA and
  raises `Irq.timer` (the one-cycle delay is optional). DIV write resets.
- OAM DMA: write to 0xFF46 copies 160 bytes (instant is fine).
- `reset_io`: documented post-boot DMG values for all registers.
- Tests (`tests/blargg.zig`): each `cpu_instrs_01..11.gb`, `cpu_instrs.gb`
  and `instr_timing.gb` @embedFile'd from `tests/roms/`, run frames until
  `gb.serial.text()` contains "Passed" (or "Failed" -> test fails), with a
  budget of 4000 frames. All green under `zig build test`.

### Track B: PPU (files: `core/ppu.zig`, `tests/ppu_unit.zig`, `tests/acid2.zig`)

- Mode machine per line: OAM scan 80 T, drawing 172 T, HBlank rest; lines
  144..153 VBlank; `Irq.vblank` on entering line 144 (+ set
  `gb.vblank_hit`); STAT interrupts on mode 0/1/2 and LY=LYC with the
  single shared STAT line (rising edge only); STAT register read composes
  mode bits and coincidence flag; LCDC bit 7 off: LY=0, mode 0, no lines
  emitted; turning on restarts from line 0.
- Line render at entry to mode 3, with current registers: BG (LCDC.0,
  tile map/data select, signed addressing, SCX/SCY), window (LCDC.5, WX/WY,
  internal window line counter), sprites (LCDC.1/.2, 8x8/8x16, at most 10
  per line by OAM order, X-priority then OAM order, flips, OBP0/1, BG-over-
  OBJ priority against BG color 0), BGP applied. Output final shades into
  `gb.ppu.line` and `sink.emit(ly, &line)`.
- `write_reg`/`read_reg` side effects (LCDC, STAT writable bits, LY read-
  only, LYC compare, DMA belongs to A: on 0xFF46 call nothing, just store;
  A's `write8` handles the copy before delegating).
- Tests: `tests/ppu_unit.zig` synthetic VRAM/OAM cases (BG scroll, window
  cut-in, sprite priority and flips, 10-sprite limit). `tests/acid2.zig`
  runs `dmg-acid2.gb` for 20 frames, captures the last full 160x144 frame
  through a `LineSink`, compares byte for byte with
  `tests/acid2_reference.bin`. This needs A's CPU; until A merges, guard it
  with a check that the CPU is not the stub (e.g. skip if PC never leaves
  0x0100) and rely on the unit tests.

### Track C: frontend and tools (files: `cart/src/main.zig`, `cart/src/frontend/*.zig`, `tools/preview.mjs`, `docs/RUNNING.md`, `README.md`)

- `video.zig`: squeeze/crop line maps (done in M0, verify), palettes as
  `Pixel` tables, fast column stores. Blank the framebuffer when the LCD
  is off (shade 0).
- `input.zig`: straight mapping (M0). Add edge detection helpers for M3.
- `debug.zig`: overlay with avg/max `step_frame` microseconds and FPS
  computed from `micros_since_boot`, toggled off with `-Ddebug=false`
  build option? No: keep it a runtime `pub var enabled`, on for M1.
- `main.zig`: keep `read_controls` / `present_wasm` shims; add
  `debug_*` zero-arg exports that `preview.mjs --dump-exports` can read
  (e.g. `debug_frame_count`, `debug_step_us`).
- `tools/preview.mjs`: verify it works with this cart; add nothing
  unless needed. `docs/RUNNING.md`: adapt from snouty-bugs (build,
  `-Drom`, tests, simulator, flash). `README.md`.
- Measure: `size zig-out/firmware/snouty-boy.elf` for `.text`/`.bss`
  with `-Dcart-optimize=fast` and `small`; record both in the report.

### Integration (after the three merge)

1. `zig build test` all green (Blargg, acid2, unit).
2. `zig build -Drom=tests/roms/dmg-acid2.gb`; preview 20 frames; the
   acid2 face shows in the PNGs.
3. `zig build` with the fast and small optimize modes; record sizes.
4. Tag `m1`, GIF in `docs/`, pull-and-run note. Gate: Adrian flashes the
   uf2 and reports FPS and the overlay's microseconds.

## M3 and M4 (merged 2026-09-26, tags `m3`, `m4`)

M3: Select-hold menu, splash + chime, APU ch1-3 model to one `tone2` voice.
M4: keyframe ring (N = 7 for 2048-gb, 3.5 s), input log, Left/Right scrub
with a bottom-bar view, neopixel history meter, `tests/determinism.zig`.
Frozen frame on scrub: restore k, step one frame through the sink, restore k
again (documented in `cart/src/frontend/rewind.zig`).

## Hardware checklist (Adrian)

- M1 gate: overlay avg/max microseconds and FPS with 2048-gb.
- Menu: game shows through around the panel; resume is clean.
- Scrub: step feels instant; Right back to live takes well under a second;
  restored frame visible under the bar; neopixels dim in menu, off after.
- Chime audible on the splash.

## Later milestones

See SPEC.md section 17. M2 needs the ROM Adrian supplies (or a homebrew
pulled at Claude's judgement if it blocks work).
