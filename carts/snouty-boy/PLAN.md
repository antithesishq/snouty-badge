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

## M6 Color core and M7 Color cart: contract (started 2026-09-29)

Design: SPEC.md section 19. Work happens on branch `snouty-boy-color`
(worktree `/home/exedev/snouty-badge-color`, off main a4341e9, so other
sessions' uncommitted work in the main checkout is untouched). Track
worktrees branch off `snouty-boy-color`; each symlinks `sycl-badge` to
`/home/exedev/snouty-badge/sycl-badge` and copies `tests/roms/` (never
commit the symlink's typechange). Merged by hand, as M1.

### M6.0 Interface (Claude, before the tracks): `core/gb.zig`, frozen for M6

- `Model = enum { dmg, cgb }`; `default_model(rom)` is `.cgb` when header
  0x143 has bit 7. `Gb.init(rom, model, cart_ram)`: `cart_ram` is a buffer
  the owner provides, at least `mmu.cart_ram_len(rom)` bytes (tests use
  `&.{}` or a local array). `reset()` keeps `rom`, `model`, `cart_ram` (zeroed)
  and `line_sink`.
- New state: `vram: [0x4000]u8`, `wram: [0x8000]u8`, `banks: mmu.Banks`
  (cached `vram_off`, `wram_off`), `hdma: mmu.Hdma`, `dot_shift: u2`
  (2 normal, 1 double speed), `stall_m: u16` (CPU M-cycles the CPU is
  stalled by GDMA/HDMA, ticked away by the frame loop), `ppu.bg_pal`/
  `ppu.obj_pal` (64 bytes each), and outside the state `pal_dirty: bool`.
- Units: `gb.tick(m)` takes CPU M-cycles. `timer.tick`, `serial.tick`,
  `mmu.tick_dma` take CPU M-cycles; `ppu.tick(gb, dots)` and
  `apu.tick(gb, dots)` take dots (`m << dot_shift`; 4 per M-cycle at normal
  speed). The frame loop counts `frame_dots` (70,224 per frame).
- Keyframes: `Gb.Small` holds every snapshotted field except VRAM, WRAM and
  cart RAM; `save_small`/`load_small`; `state_regions(small)` returns the
  byte regions `[small, vram, wram, cart_ram]` for the page store.
  `KeyframeWith(n)` stays (tests, self check) as `{ small, vram, wram,
  cart_ram[n] }`; `cart_ram_len` goes up to 32 KB.
- DMG mode must be observably unchanged: every M1..M4 test stays green
  with `.dmg` passed explicitly.

### Track A: CPU, memory map, DMA (files: `core/cpu.zig`, `core/mmu.zig`, `core/timer.zig`, `core/serial.zig`, `core/joypad.zig`, `tests/blargg.zig`, new `tests/cgb_unit.zig`, `tools/fetch_test_roms.sh`, `tools/romcheck.py`)

- CGB post-boot CPU registers (A = 0x11, F = 0x80, B = 0, C = 0, D = 0xFF,
  E = 0x56, H = 0, L = 0x0D) and CGB I/O reset values.
- VBK (0xFF4F, reads 0xFE | bank), SVBK (0xFF70, 0 -> 1, reads 0xF8 |
  bank), both CGB only (DMG: 0xFF, offsets fixed). Update `banks`.
- KEY1 (0xFF4D, reads 0x7E | speed << 7 | armed) and STOP: armed ->
  toggle `dot_shift`, clear armed, pause 2050 M-cycles (via `stall_m`), no
  halt. Unarmed STOP stays HALT-like.
- HDMA1..5 (0xFF51..55): GDMA (bit 7 = 0) copies at once and adds
  `stall_m` (8 M-cycles per 16 bytes at normal speed, 16 at double);
  HBlank DMA (bit 7 = 1) copies 16 bytes per `mmu.hdma_hblank(gb)` call
  (the PPU calls it on entering mode 0 on lines 0..143 with the LCD on;
  if the LCD is off when started, copy one block immediately as hardware
  does), writing bit 7 = 0 to HDMA5 while active cancels; HDMA5 reads
  remaining length - 1 with bit 7 set when inactive. Source masks: 0xFFF0,
  not from VRAM; destination 0x8000 | (x & 0x1FF0) in the current VRAM bank.
- MBC5 RAM banking (4 x 8 KB), MBC1/3 RAM banks where the header asks;
  `cart_ram_len` 0/2/8/32 KB (header 3 = 32 KB, 4/5 capped to 32 KB with
  a romcheck warning). `romcheck.py` accepts CGB ROMs and prints model,
  double-speed hint (writes to 0xFF4D in the code) and HDMA use.
- 0xFF6C OPRI, 0xFF72..75, 0xFF76/77 (read 0), RP 0xFF56: stored per
  SPEC 19.1. BCPS..OCPD 0xFF68..6B and OPRI delegate to `ppu.write_reg` /
  `ppu.read_reg` (B implements; stub stores to `io`).
- `fetch_test_roms.sh`: cgb-acid2 (+ reference PNG), chosen Mooneye CGB
  tests. Tests: Blargg cpu_instrs and instr_timing in both models (CGB at
  normal speed); `tests/cgb_unit.zig` for banking, KEY1/STOP, GDMA/HDMA,
  cart RAM banks; Mooneye CGB tests that pass headless (Mooneye signals
  pass with the Fibonacci registers B=3 C=5 D=8 E=13 H=21 L=34 at `LD B,B`).

### Track B: PPU (files: `core/ppu.zig`, `tests/ppu_unit.zig`, `tests/acid2.zig`, new `tests/cgb_acid2.zig`, new `tools/make_cgb_ref.py`, new `tests/cgb_acid2_reference.bin`)

- `tick(gb, dots)`; CGB renderer per SPEC 19.1/19.2: BG/window attributes
  from VRAM bank 1, tile bank, flips, BG priority bit, LCDC.0 master
  priority, OBJ palette + bank bits, OAM-order priority when OPRI bit 0 is
  0 (CGB default), 10-per-line limit as DMG. Output byte = colour index
  (BG 0..31, OBJ 32..63). DMG path byte-identical.
- BCPS/BCPD/OCPS/OCPD with auto-increment (reads of BCPS/OCPS 0x40 | v),
  set `gb.pal_dirty` on data writes. Palette RAM reset: CGB boot leaves BG
  palettes white (0x7FFF); OBJ palettes are undefined, use white too.
- Call `mmu.hdma_hblank(gb)` when entering mode 0 on visible lines.
- `tools/make_cgb_ref.py` converts cgb-acid2's reference PNG to 160x144
  RGB555 little-endian u16 (the PNG uses c << 3 | c >> 2 per channel, so
  divide exactly); `tests/cgb_acid2.zig` runs cgb-acid2 in CGB mode,
  converts each index through palette RAM at emit time, compares exactly.
- Unit tests for each CGB feature; DMG acid2 unchanged.

### Track C: page store and frontend (files: new `core/kstore.zig`, `core/ring.zig`, new `tests/kstore_unit.zig`, `tests/ring_unit.zig`, `tests/determinism.zig`, `cart/src/**`, `tests/all.zig`, `docs/RUNNING.md`, `README.md`)

- `core/kstore.zig`: `Store(page_size, pool_pages, max_keyframes)` per SPEC
  19.3 over `state_regions`; refcounted pool, shared zero page, compare
  against the previous keyframe's page, evict oldest until it fits;
  `put`, `get(k, regions)`, `drop_oldest`, stats (pages used, bytes per
  keyframe). Host tests: sharing, zero page, eviction order, exact restore.
- `core/ring.zig`: runtime count with eviction from the old end (the store
  decides when); keep the truncation semantics.
- Frontend: `main.zig` inits with `default_model(rom)` and a cart RAM
  buffer sized `mmu.cart_ram_len(rom)`; `rewind.zig` on the page store,
  pool sized from the budget (RAM vs XIP: find how `os_cart` builds XIP and
  pass the mode in); `video.zig` rebuilds `lut[0..64]` from palette RAM when
  `pal_dirty` (raw and GBC-LCD colour correction; menu item "Color" in CGB
  mode replaces "Palette"); frozen-frame remap only in DMG mode; splash and
  menu say "COLOR" in CGB mode; debug overlay adds pool use.
- Determinism test on 2048-gb and (if present) the Color ROM, through the
  page store (restore from store == keyframe field by field).
- Needs A and B only for the Color ROM to do anything; build and test on
  2048-gb until merge.

### M6 integration

1. `zig build test` green: all DMG tests, cgb-acid2 exact, Blargg in both
   models, unit tests. 2. Build the cart with cgb-acid2 and the Color ROM;
   preview frames. 3. Sizes for fast/small, RAM and XIP. Tag
   `snouty-boy/m6`.

### M7 Color cart

Ship ROM chosen (license checked, section 11 rules extended to CGB),
committed with its LICENSE like 2048-gb and made the default `-Drom`;
`badge-bench/carts/snouty-boy-color.toml` press script; bench before and
after tuning, knobs per SPEC 19.5, numbers recorded here; GIF in `docs/`;
tag `snouty-boy/m7`. Hardware gate (Adrian): overlay ms and FPS, colours
look right, scrub depth.

ROM research (2026-09-29, licenses read from the repos; open decision for
Adrian, M6 does not depend on it):

| ROM | License | Size | MBC / RAM | CGB | Sound | Double speed / HDMA |
|---|---|---|---|---|---|---|
| Rebound (DevEd, art Twoflower) | MIT, whole repo incl. DevSound music | 128 KB | MBC5 / 0 | C0 | music + SFX | yes / yes |
| Rex Runner (The Void) | MIT, whole repo | 32 KB | MBC5 / 8 KB | 80 | SFX | likely / no |
| Libbet (Damian Yerrick) | zlib | 32 KB | none / 0 | 80 | SFX | no / no |
| CrossConnect | MIT (font licence unchecked) | 32 KB | MBC5 / 8 KB | 80 | SFX | no / no |

Recommendation: Rebound, because it is the only one with music and the
only one exercising double speed and HDMA, but 128 KB leaves the RAM cart
about 20 KB of page pool, so it wants the XIP cart. Rex Runner is the RAM
cart fallback. Build and bench both in M7; Adrian picks the default.
Rejected: Tobu Tobu Girl DX (256 KB), uCity/Geometrix (GPL-3), Shock Lobster
(DMG only), Petris (NC), Tuff (assets reserved).

### M7 performance pass (2026-09-29)

Branch `snouty-boy-color`, badge-bench calibrated `busy ms` (the model is
a floor). Press scripts: Rebound `badge-bench/carts/snouty-boy-color.toml`
(pass it with `--config`; XIP cart, 1800 frames), Rex Runner `--frames 900
--press START:200-202 --press A:400-402 ... A:700-702` (RAM cart), 2048-gb
`badge-bench/carts/snouty-boy.toml` (RAM cart, 600 frames).

| ROM | Mode | Before mean / p95 / max | After mean / p95 / max |
|---|---|---:|---:|
| Rebound | CGB, double speed, HDMA, XIP | 13.39 / 20.43 / 42.54 | 5.28 / 10.30 / 22.20 |
| Rex Runner | CGB, RAM | 8.38 / 13.70 / 20.65 | 3.50 / 6.77 / 10.26 |
| 2048-gb | DMG, RAM | 7.67 / 11.02 / 17.81 | 3.92 / 6.02 / 9.48 |

"Before" is 91141d4 (after the CGB mid-instruction LY sync). Per step
(mean / p95 / max, Rebound then Rex):

| Step | Rebound | Rex |
|---|---|---|
| inline tick fast paths | 11.11 / 17.26 / 35.29 | 7.33 / 11.04 / 18.01 |
| VRAM/WRAM last in `Gb`, CGB renderer (nibble decode, masked word pass, sprite spans), `lines_wanted` (16 dropped lines skip pixel work) | 9.77 / 16.19 / 32.83 | 5.93 / 10.70 / 16.17 |
| halted fast-forward to the next event (`Gb.halt_m`) | 7.25 / 14.84 / 32.58 | 4.54 / 10.59 / 16.02 |
| inline ROM fetch (`mmu.fetch8`) | 6.82 / 13.77 / 30.27 | 4.38 / 9.56 / 14.77 |
| event-driven catch-up (`Gb.tick_lazy`) + direct overlay blitter | 6.02 / 12.04 / 34.31 | 3.73 / 9.16 / 13.05 |
| opcode switch inlined into `cpu.step` (size only) | 6.04 / 12.01 / 34.11 | 3.78 / 9.09 / 12.97 |
| lazy LY/STAT/APU reads, `cpu.step` inlined into the frame loop | 5.28 / 10.30 / 22.20 | 3.50 / 6.77 / 10.26 |

Every core step is exact: a host harness hashing console state and every
emitted line per frame (2048-gb, rex, rebound, both acid2) matched 91141d4
byte for byte after each step, and `zig build test` stays green.

Frames still over 13.4 ms, Rebound only: frame 85 (20.1, the game's boot
with the LCD off in double speed), 976-989 (13.6 to 22.2, the level load:
LCD off, the CPU running flat out in double speed, and at 978 the LCD
switched on mid-frame, so `step_frame` runs until the next VBlank, about
1.8 frames of emulation). No pixel work happens there, so frame skip would
not help; lever 6 (auto frame skip) was not built. Rex's worst (608, 10.3)
is a CPU-bound game frame.

Sizes (fast, text / bss bytes), before -> after: rex-runner RAM 100,988 /
171,840 -> 101,688 / 169,696; 2048-gb RAM 98,308 / 171,376 -> 98,292 /
169,496; Rebound XIP 199,808 / 270,000 -> 199,888 / 270,128. The RAM
page pool is about 2 KB smaller (`tuning.code_estimate` 64 -> 66 KB).

Knobs: `cart/src/frontend/tuning.zig` (keyframe interval 30, page size
512, typical pages per keyframe 8, code estimate 66 KB, overlay on).
Open: XIP flash-fetch stalls are not modelled (`--flash-cycles 0`), so the
Rebound XIP numbers are the most optimistic; hardware overlay numbers
decide.

## Hardware checklist (Adrian)

- M1 gate: overlay avg/max microseconds and FPS with 2048-gb.
- Menu: game shows through around the panel; resume is clean.
- Scrub: step feels instant; Right back to live takes well under a second;
  restored frame visible under the bar; neopixels dim in menu, off after.
- Chime audible on the splash.

## Later milestones

See SPEC.md section 17. M2 needs the ROM Adrian supplies (or a homebrew
pulled at Claude's judgement if it blocks work).
