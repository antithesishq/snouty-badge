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
The meter is compiled out since 2026-09-29 (neopixels off, SPEC.md section
12); `-Dneopixels=true` re-enables it for development.
Frozen frame on scrub: restore k, step one frame through the sink, restore k
again (documented in `cart/src/frontend/rewind.zig`).

## M5 ROM loader: ROMs from the badge drive (started 2026-09-29)

Branch `boy/rom-loader` in worktree `/home/exedev/snouty-badge-boyrom`
(off main `d4af03c`). Design: `docs/ROM_DRIVE.md` at the repository root
(shared with Snouty Gear, whose M0 builds the FAT12 reader `lib/romfs.zig`
in parallel on branch `gear/m0`; this branch carries the same stub with the
frozen interface until that lands, byte-identical so the merge is clean).
SPEC.md section 11 and 13 were updated with it.

What changes for the user: copy any `.gb` (or DMG-compatible `.gbc`) file
onto the badge drive next to `snouty-boy.uf2`, eject, run the cart. One file:
it starts. Several: a picker after the splash. None, or no readable volume:
the embedded fallback ROM (`-Drom`, default `roms/2048.gb`) as today. The
web simulator always runs the embedded ROM.

### Skeleton (done by the integrator before the tracks)

- Root: `lib/romfs.zig` stub + `lib/tests.zig` hung off `zig build test`,
  `-Drom-source=drive|embed` (`common.RomSource`, default `drive`; `pack`
  exists for Snouty Gear and is rejected here).
- `core/rom.zig`: `Rom` = 16 KB bank pointer table (`banks: [64]?[*]const u8`,
  1 MB cap) with a per-512-byte-sector slow path for banks a fragmented
  drive file cannot map directly. `Rom.from_slice(bytes)`,
  `Rom.from_sectors(len, sectors: []const [*]const u8)`, `read(off)`,
  `bank_ptr(bank)`, `fragmented_banks()`, `crc32()`.
- `Gb.rom: Rom`; `Gb.init(bytes)` (contiguous, unchanged for tests) and
  `Gb.init_rom(rom: Rom)`. The MMU caches the two mapped banks' pointers in
  `Gb.rom0` / `Gb.romn` (`mmu.remap_rom`, called after MBC writes, on
  reset and on restore); a null pointer falls back to `Rom.read`. The hot
  path is one load, as before.
- `mmu.cart_ram_len(rom: *const Rom)` (run time) and `mmu.ram_len_for(code)`
  (comptime-callable, header byte 0x149).
- Keyframes at run time: `Gb.Fixed = KeyframeWith(0)` plus
  `snapshot_pool(out: *Fixed, ram: []u8)` / `restore_pool(k, ram)`; a pool
  slot is a `Fixed` followed by `cart_ram_len` bytes. `Keyframe` and
  `KeyframeWith` stay for the tests.
- `core.ring.Ring(max_n, interval)`: `n` slots in use chosen at run time
  (`Ring.init(n)`, `max_slots`, log sized to `max_n`).

### Frozen for M5: the frontend's view of a ROM

```zig
// core/rom.zig (integrator; Track A may extend, not change signatures)
pub const Rom = struct { len: u32, banks: [64]?[*]const u8, sectors: []const [*]const u8, tail: ?[*]const u8,
    pub fn from_slice([]const u8) Rom; pub fn from_sectors(u32, []const [*]const u8) Rom;
    pub fn read(*const Rom, u32) u8; pub fn bank_ptr(*const Rom, u32) ?[*]const u8;
    pub fn fragmented_banks(*const Rom) u32; pub fn crc32(*const Rom) u32 };
// lib/romfs.zig: frozen in carts/snouty-gear/PLAN.md ("Frozen for M0"): Volume.open(base) /
// find(exts, out) / map(entry, clusters) -> Mapped { size, chunk(off, len) ?[*]const u8, read(off) u8, crc32() }.
// The stub's open() returns error.NoVolume, so until gear/m0 lands the badge build always falls back.
```

### Track A: core hardening and measurements (files `core/*.zig`, `tests/**`, `tools/romcheck.py`)

- Tests in `tests/rom_unit.zig`: `Rom.from_sectors` with every bank
  fragmented, a fragmented bank read through `Gb.read8` after an MBC1 bank
  switch equals the same ROM embedded (run Blargg `cpu_instrs.gb` both ways
  for a few frames and compare keyframes), `remap_rom` after `restore` of a
  keyframe taken in another bank, a 1 MB image caps and folds banks like
  before, out-of-range banks read 0xFF exactly as the slice code did (a
  48 KB image, bank 3).
- `tests/determinism.zig`: the pool form (`snapshot_pool`/`restore_pool`
  with 0, 2 KB and 8 KB of cart RAM) round-trips and replays like
  `Keyframe`. `tests/ring_unit.zig`: `Ring.init(n)` for n = 2, 3, max;
  `history_fraction` with n < max.
- Blargg, dmg-acid2, ppu/apu unit tests untouched and green (57 tests
  before this milestone; report the count).
- badge-bench: run `snouty-boy.elf` (embedded 2048-gb, `bench.sh`) on the
  skeleton and on `main` and report the per-frame cycles; the pointer cache
  must not be slower than the slice bounds check. If it is, fix `read8`.
- `tools/romcheck.py`: print what the drive loader will do with a file
  (size class, mapper, cart RAM, CGB-only flag, header checksum).
- Do not edit `cart/src/**` or docs (Track B). Report anything the frontend
  must know.

### Track B: frontend, build and docs (files `build.zig`, `cart/src/**`, `docs/RUNNING.md`, `README.md`, `CLAUDE.md`, `badge-bench/carts/snouty-boy.toml`, root `README.md` row for snouty-boy)

- `build.zig`: `romfs` module (`lib/romfs.zig`) and a `rom_source`
  build option (`@import("rom").source`, `.drive` or `.embed`; the wasm
  build always behaves as `.embed`, the badge build follows
  `-Drom-source`). `-Drom-source=pack` fails with a clear message.
- `cart/src/frontend/romsrc.zig`: badge + drive only. `scan()`: open the
  volume at `romfs.base_addr`, `find(&.{ "gb", "gbc" }, ...)` into a fixed
  candidate table (8 entries), validate each (length 0x150..1 MB, header
  checksum 0x14D over 0x134..0x14C; a mismatch or a size out of range is
  listed as unplayable), note CGB-only (0x143 == 0xC0) and mapper/RAM caps
  as hints only. `select(i)`: `map` into a static `[romfs.max_clusters]u16`
  table, build a `[core.rom_mod.max_sectors][*]const u8` sector table from
  `Mapped.chunk(s * 512, 512)`, `Rom.from_sectors`, CRC32, remember
  name/size/CRC/source/fragmented banks. On any error: the embedded ROM,
  with the reason kept for the About screen. Zero candidates: embedded.
- `main.zig`: `Rom` chosen before `Gb.init_rom`; new state `.pick` between
  splash and running when more than one candidate is playable (Up/Down,
  A selects, B takes the embedded ROM; the list shows name, size and the
  hints). Exactly one: straight in. `debug_*` exports must not touch `gb`
  before it exists (return 0 in `.pick`).
- `rewind.zig`: keyframe pool sized at run time. On the badge the pool is
  the RAM between `__bss_end__` (aligned to 8) and `__stack_limit__`
  (`cart_ram.ld` exports both; leave 1 KB below the stack limit), taken at
  `start()`, so the ring no longer ships as zero-filled `.bss` in the UF2
  (docs/ROM_DRIVE.md section 3; today's UF2 is 484 KB, of which 330 KB is
  zeros). On wasm a static 160 KB pool. Slot stride =
  `@sizeOf(Gb.Fixed) + cart_ram_len` rounded up to `@alignOf(Gb.Fixed)`;
  `slots = min(pool / stride, Ring.max_slots)` with `max_slots = 12`,
  `Ring.init(slots)`; refuse to start (message) below 2. Show the slot count
  in the debug overlay. `spare`/self-check keep compiling.
- `menu.zig`: About lists ROM title, source ("drive: name" or "embedded"),
  size, CRC32, "fragmented: N banks" when non-zero, and the fallback reason
  when the drive was tried and lost.
- `debug.zig`: one extra overlay line with the keyframe slot count and the
  ROM source letter.
- Docs: `docs/RUNNING.md` section "ROMs from the badge drive" (copy, eject,
  run; which files show in the picker; `-Drom-source`, `-Drom`; the wasm
  always embeds), `README.md`, `CLAUDE.md` (the "read_flash is a stub so the
  ROM is embedded" paragraph becomes the drive loader), root `README.md`
  row, `badge-bench/carts/snouty-boy.toml` with a commented `romfs =` line
  until the bench option exists.
- Done when `zig build -Dcart=snouty-boy` builds RAM and wasm, the wasm
  preview still plays 2048-gb, the badge UF2 is far smaller than 484 KB,
  and `size -A` is recorded in the report (`.text`, `.data`, `.bss`).

### Integration (me)

1. Merge A and B into `boy/rom-loader`; `zig build -Dcart=snouty-boy`,
   `zig build test` green; preview 2048-gb; record sizes.
2. If `gear/m0` has landed on main by then: rebase onto main, drop the
   stub, build a drive image with `tools/make_romfs.py` holding
   `roms/2048.gb`, run badge-bench with `--romfs` and confirm the About
   screen would read the drive ROM (CRC), and compare cycles with the
   embedded run. Otherwise these are listed as pending.
3. PLAN/SPEC status, tag `snouty-boy/m5`, pull-and-run notes for Adrian.

Hardware gate (Adrian, first flash): a `.gb` on the drive starts; the
About screen shows "drive"; FPS with the ROM in flash (XIP cache misses on
ROM fetches are the open question, docs/ROM_DRIVE.md section 6); the drive
still mounts with the ROM on it.

### M5 status (2026-09-29, tag `snouty-boy/m5`)

Both tracks merged. Host tests 77 (was 56; the 2048-based determinism and
APU tests had been skipping because they read `roms/2048.gb` relative to
the cwd, fixed). badge-bench with the embedded 2048-gb: 879 k cycles per
frame against 891 k on `main` (the pointer cache is 1.3% faster than the
slice bounds check). Fast build with 2048-gb embedded, stub reader:
`.text` 92.8 KB, `.bss` 28.4 KB, UF2 245 KB (was 497 KB; the keyframe pool
left `.bss`). With the real reader (scratch merge with `gear/m0`): `.text`
98 KB, `.bss` 41.8 KB (13 KB of romfs tables), pool 124.6 KB: 6 slots with
2048-gb (2 KB cart RAM), 7 without cart RAM, 5 with 8 KB; wasm 8. Drive
path verified in badge-bench with `--romfs` (docs/RUNNING.md 9.1): one
file starts, two files show the picker, a fragmented file plays through the
per-sector path and About shows the right CRC. Not done: hardware (the gate
above); merging `gear/m0` (the gear session's), after which the stub in
`lib/romfs.zig` disappears in the merge. Follow-up idea: put the 13 KB of
romfs tables into the pool arena to win the seventh slot back.
M8 (below) replaced the pool slots with the page store in the same arena.

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
Decided 2026-09-29: ship both (`roms/rebound.gbc`, `roms/rex-runner.gb`,
LICENSE files with source commit and sha256), `-Drom` picks.
Rejected: Tobu Tobu Girl DX (256 KB), uCity/Geometrix (GPL-3), Shock Lobster
(DMG only), Petris (NC), Tuff (assets reserved).

### M6/M7 status (2026-09-29)

- Tracks A, B, C merged (715e20f); integration found one CGB bug: Rebound
  polls LY with the VBlank interrupt enabled, and LY only advanced after
  whole instructions, so it never left its pre-level wait. Fixed in
  91141d4 (CGB LY/STAT reads catch the PPU up to the operand M-cycle).
- `zig build test`: 101 pass, 7 skipped (ROM-path tests). Blargg both
  models, dmg-acid2 and cgb-acid2 exact, determinism through the page store.
- Rebound (XIP) and Rex Runner (RAM) play in colour in the simulator;
  `docs/m6_color_rebound.gif`.
- Not tagged yet: Adrian decided the M5 ROM loader (branch
  `boy/rom-loader`) lands on main first. Done in M8 (below): `main` merged
  into this branch with M5's bank-pointer ROM table kept and its keyframe
  pool replaced by the page store; the `snouty-boy/m6` tag waits for
  Adrian's review of M8.
- Hardware (Adrian): overlay ms/FPS for both ROMs, XIP launch of the
  Rebound UF2, colours (LCD vs Raw), scrub depth.

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

## M8 Integration: Color on the drive loader (2026-09-29)

Main now holds M5 (`snouty-boy/m5`: ROMs read in place from the badge
drive through `core.Rom` bank pointers, a picker, the keyframe pool in the
RAM above `.bss`) merged with Snouty Gear's real `lib/romfs.zig`. This
milestone lands M6/M7 on top of it so one `snouty-boy.uf2` plays `.gb` and
`.gbc` files from the drive, and tags `snouty-boy/m6`.

Mechanics: `git merge main` into `snouty-boy-color` (one conflict pass over
the 15 files both branches touched, instead of replaying 27 commits), then
fast-forward main. Adrian's decision (M6/M7 status above): keep M5's ROM
table, replace M5's keyframe pool with the page store.

### Design of the merged cart

1. ROM: `core.Rom` (64 x 16 KB bank pointers, per-sector slow path for
   fragmented drive files) is the only ROM representation. `Gb.init` takes
   `(rom: Rom, model: Model, cart_ram: []u8)`; a slice convenience
   (`Rom.from_slice`) keeps the host tests short. `default_model` and
   `mmu.cart_ram_len` read the header through the table. The CGB MMU keeps
   M5's cached bank pointers (`Gb.rom0/romn`, `mmu.remap_rom`) with MBC5's
   9-bit bank number and the inline `fetch8` fast path.
2. Keyframes: the page store (`core.kstore`, 512 B pages shared between
   keyframes) is the keyframe form; `Gb.Fixed` pool slots go. The store's
   page pool and keyframe tables live in M5's run-time arena (the RAM
   between `__bss_end__` and `__stack_limit__`, 1 KB stack guard), laid out
   in `begin()` once the ROM and its cart RAM size are known, together with
   the live console's cart RAM (up to 32 KB). Comptime keeps only the maxima
   (`max_pages` for Small + 16 KB VRAM + 32 KB WRAM + 32 KB cart RAM, a
   keyframe cap in `tuning.zig`); the page count is a run-time number, so
   `tuning.code_estimate`, the comptime budget arithmetic and
   `cart_options.xip` in `rewind.zig` disappear. The arena shrinks by itself
   when a ROM is embedded (it sits in `.rodata`) and is the whole RAM window
   for an XIP build. Fewer than two keyframes' worth of arena -> the M5
   `halted` state. In wasm the arena stays a static array.
3. Sources: `-Drom-source=drive` (default): the picker lists `.gb` and
   `.gbc` files, one file starts at once, none falls back to the embedded
   ROM. `-Drom-source=embed`: the embedded ROM only, and `-Dcart-mode=xip`
   for ROMs that do not fit RAM beside the code (Rebound, 128 KB). All three
   must build: default, `embed` + `roms/rex-runner.gb`, `embed` +
   `roms/rebound.gbc` + `xip`.
4. Overlay and menu: Color's own glyph blitter stays; the third overlay line
   shows the keyframe count and M5's `D`/`E` source letter; the About screen
   shows the model next to the source and CRC.
5. Everything else is additive: DMG path byte-exact (dmg-acid2, Blargg),
   cgb-acid2, both determinism forms (page store, and M5's fragmented-file
   replay through the store), `rom_unit`, `kstore_unit`, `ring_unit`.

### Steps

1. Merge, resolve, `zig fmt`, `zig build test` green (expected about 115
   tests: the 101 Color ones plus M5's `rom_unit`, ring and drive
   determinism cases).
2. The three builds above link; sizes recorded (`.text`, `.bss`, arena
   left for the store with 2048-gb, Rex Runner and Rebound from the drive).
3. badge-bench, calibrated `busy ms`, with a drive image from
   `tools/make_romfs.py` holding `rebound.gbc`, `rex-runner.gb` and
   `2048.gb`: Rebound and Rex with the M7 press scripts through the picker,
   2048 with `carts/snouty-boy.toml`. `snouty-boy-color.toml` switches to
   the RAM ELF plus `romfs`. Numbers next to the M7 table.
4. Docs: README (how ROMs get onto the badge, the embedded alternative),
   `docs/RUNNING.md` sections 4, 8, 9, SPEC 11.1 and 19.4, CLAUDE.md, the
   root README row, the M5 and M6/M7 status blocks, this section's status.
5. Tag `snouty-boy/m6`, fast-forward main, push.

### M8 status (2026-09-29, not tagged)

Merged `main` (18f07bd) into `snouty-boy-color` as planned (merge commit
40fb541 plus follow-ups). Host tests: 132 for this cart, all pass (M5 77,
Color 101; the rest are M5's rom/ring tests, the fragmented-image store
replays and a layout test). The Color determinism tests on Rex Runner and
Rebound had been skipping under `zig build test` (paths relative to the cart
directory, the test runs from the root); they now run, from `roms/`.

Sizes (fast, `size -A`; arena = `__stack_limit__ - 1 KB - __bss_end__`,
holding the live `Gb` of 50,392 bytes, its cart RAM and the page store):

| Build | .text | .data | .bss | Arena | UF2 |
|---|---:|---:|---:|---:|---:|
| default (`drive`, dmg-acid2 fallback embedded, RAM) | 114,872 | 116 | 18,584 | 138,792 | 269,824 |
| `embed` rex-runner (RAM) | 106,548 | 120 | 4,484 | 161,372 | 224,768 |
| `embed` rebound, XIP (text in flash) | 205,164 | 120 | 4,484 | 268,548 | 412,160 (206 KB of the 256 KB window) |

Store after the console and cart RAM (computed with `layout`'s rules; the
bench overlay agrees, e.g. Rebound 20 keyframes): default build from the
drive: 2048-gb 19 keyframes / 80 KB pool, Rex Runner 18 / 74 KB, Rebound
20 / 82 KB, a 32 KB cart RAM game 12 / 48 KB; `embed` Rex 23 / 95 KB; XIP
Rebound 50 / 202 KB. A 128 KB ROM embedded in a RAM build links (61.6 KB
arena) and shows the halted screen, checked in badge-bench.

badge-bench, calibrated busy ms (mean / p95 / max), default build ELF with
`--romfs out/boy-m8.img` (rebound.gbc, rex-runner.gb, 2048.gb, all
contiguous), each game picked in the picker so it starts at the same update
as in M7; PNGs checked (right game, overlay `kf N D`):

| ROM | M7 (embedded) | M8 (drive, picker) |
|---|---:|---:|
| Rebound (CGB, double speed, HDMA) | 5.28 / 10.30 / 22.20 (XIP) | 5.13 / 9.90 / 21.44 (RAM) |
| Rex Runner (CGB) | 3.50 / 6.77 / 10.26; M7 build with the M8 script 3.60 / 7.58 / 10.67 | 3.55 / 7.26 / 10.39 |
| 2048-gb (DMG) | 3.92 / 6.02 / 9.48 | 3.93 / 5.92 / 10.12 |

Presses: Rebound `badge-bench/carts/snouty-boy-color.toml` (now the RAM
ELF plus `romfs`; `A:72-73` picks the first file as the splash ends).
Rex Runner `--frames 900 --press DOWN:66-67,A:72-73,START:200-202,A:400-402,
A:450-452,A:500-502,A:550-552,A:600-602,A:650-652,A:700-702` (the M7 list
was only recorded as "START:200-202, A:400-402 ... A:700-702", so the M7
build was re-benched with this list for a like-for-like number). 2048-gb
`carts/snouty-boy.toml` with the picker presses `START:18-19, DOWN:22-23,
DOWN:26-27, A:30-31` in place of `START:30-31`. The Rex and 2048 maxima are
the frame the file is picked (map, CRC32 of the ROM, layout, reset, first
keyframe); Rebound's are the M7 ones (boot and level load in double
speed). No regression; the drive ROM path is as fast as the embedded one.

Deviations and choices:

- The live `Gb` moved into the arena too, not only the store and cart RAM:
  it was 50 KB of zero-filled `.bss` shipped in the UF2 (373 KB with it in
  `.bss`, 270 KB now; M5's 245 KB had a 17 KB `Gb`).
- `kstore.Store(page_size)` takes its memory and sizes at run time
  (`init(mem, pool_pages, max_keyframes, max_pages)`, `bytes_for`,
  `pages_fitting`); `check()` is quadratic now (test only). The keyframe
  count is split from the arena with the M7 rule (table + 8 typical pages
  per keyframe), capped at `tuning.max_keyframes` = 64 (32 s; the XIP arena
  reaches about 50, and the cap sizes the 1,920-byte input log).
- Halted threshold: two keyframe tables and half a full keyframe of pool,
  not a whole one (a full keyframe is every page non-zero, 81 KB with 32 KB
  of cart RAM, which would have refused such games from the drive). If a
  keyframe does not fit even alone, the history is emptied
  (`ring.lose_history`) until the next one fits, instead of trapping.
- Overlay: line 2 `fps N pool NK`, line 3 `kf N D|E`. About: `CRC xxxxxxxx
  CGB|DMG`. Picker hints: "Color" for CGB-flagged files, "RAM>32K".
- M5's pool determinism tests became store replays from a fully fragmented
  image with 0, 2, 8 and 32 KB of cart RAM; M5's `rom_unit` pool check goes
  through the store.
- `badge-bench/carts/snouty-boy.toml`: comment corrected (a drive build
  needs `--romfs`; picker presses for the three-file image).

Open: tag `snouty-boy/m6`, fast-forward main and push (Adrian); the
hardware checklist below. `main` has moved on since 18f07bd (Snoutenstein
M5 only, nothing under `carts/snouty-boy`, `lib`, `build` or
`badge-bench`), so landing this needs a merge rather than a fast-forward.

### Hardware checklist after M8 (Adrian)

- Copy `snouty-boy.uf2` and the three ROM files onto the badge drive, eject,
  start the cart: picker lists three files; each starts; About says Source
  drive and the right model.
- Overlay ms/FPS for Rebound (double speed) and Rex Runner; colours (LCD vs
  Raw); scrub depth in seconds from the overlay's keyframe count.
- 2048-gb: the M1 gate numbers.

## Simulator sound fix (2026-09-30)

Snouty Gear found (2026-09-29, Sonic inaudible) that upstream's wasm
`tone2` shim sends `duration = -1` as `0xFFFFFFFF`, which the simulator's
WASM-4 style worklet reads as a 255-frame attack/decay/sustain/release:
every note restarts a 4 s fade-in and music stays under 2% volume. This
cart had the same defect. Fix as in Gear, `frontend/audio.zig`: the wasm
build calls the simulator's `tone` import itself (no attack, 6-frame
sustain re-issued every frame, pulse at 50% duty for the square voice, the
worklet's triangle channel for the wave channel, the old channel silenced
on a shape change); the badge keeps the infinite `tone2`, which the OS
driver supports. Thumb `.text` byte-identical to before. New export
`debug_tone_hz`. Headless check: `tools/preview.mjs` with its `tone` stub
logging shows the chime as sustain 4 / attack 0 and Rex Runner's jump
tone re-issued per frame with attack 0.

## Hardware checklist (Adrian)

- M1 gate: overlay avg/max microseconds and FPS with 2048-gb.
- Menu: game shows through around the panel; resume is clean.
- Scrub: step feels instant; Right back to live takes well under a second;
  restored frame visible under the bar; neopixels stay dark (default build).
- Chime audible on the splash.
- M5: a `.gb` copied to the drive runs; the About screen says "drive"; FPS
  with the ROM in flash; several files show the picker.

## Later milestones

See SPEC.md section 17. M2 needs the ROM Adrian supplies (or a homebrew
pulled at Claude's judgement if it blocks work).

## Sound on the new firmware (2026-10-04)

Contract: root `docs/EMU_SOUND.md` (Track A). Adrian heard nothing from
Tetris DX with Sound on: the show badges' firmware ignores `CART_TONE` and
plays only a cart-owned 44.1 kHz u8 ring. Done on branch `emu-sound-boy`:

- Core (`core/apu.zig` "Sample generation"): all four channels rendered
  lazily (before APU writes, sequencer steps, end of frame), box filter
  over 95/96-dot bins, NR50/NR51 to mono, ~27 Hz high-pass, `apu.gain` 80
  (Tetris / Tetris DX 99.9th percentile swing +-77 / +-95 of 127; 5 and 99
  of ~2.6 M samples clip, longest run 16). 738/739 samples per frame
  (`Gb.audio_len`, `apu.samples`). `Gb.audio_render` gates it; render
  state (`apu.Snd`, 3.7 KB) is caller-owned, outside keyframes, reset on
  restore. Channel 4 lives in render state only (NR52 bit 3 still reads 0).
  Left out: DAC offset pops, wave start delay, duty reset on power off,
  Vin, PCM12/34. `Gb.init_in` initialises in place (by value it put a
  50 KB temporary on the 32 KB stack once `reset` grew: a start-up crash
  in badge-bench).
- Frontend: `audio_feed` `Feed(738, 739, 4096)`; no `tone2`/`tone` on the
  badge; chime = 60 ms square bursts through the feed; `idle` ramps out in
  every non-stepping update; the menu turns rendering off (scrub replays
  cost nothing). Overlay line 4 `q N u N`. Wasm path unchanged.
- Tests: 12 `sound:` tests (`tests/sound_unit.zig`); cart total 148 test
  blocks + the entry block, all pass; full `zig build test` 552 pass, 4
  skipped (Lynx, as before). This cart has no `check-float`.
- Every other cart's UF2 byte-identical to the plan-commit baseline
  (`/home/exedev/emu-sound/baseline/SHA256SUMS`).
- Size (fast, default build): .text 115,876 -> 122,744; .data 116 -> 120;
  .bss 18,588 -> 27,324 (ring 4 KB + feed scratch, `Snd` 3.7 KB);
  `__bss_end__` 0x2005619c -> 0x20059efc: the arena (console + cart RAM +
  page store) is 15,712 bytes smaller, a few keyframes fewer.

badge-bench, calibrated busy ms mean / p95 / max (drive images built with
`tools/make_romfs.py`; Tetris presses `START:30-31,START:200-203,
START:350-353,START:500-503,START:650-653,START:800-803,LEFT:1000-1003,
RIGHT:1100-1103,A:1200-1202,LEFT:1300-1303,DOWN:1400-1440`, 1800 frames;
Tetris reaches play, Tetris DX its name-entry screen with music):

| Run | plan commit | sound off | `-Dsound=true` |
|---|---:|---:|---:|
| 2048 (`snouty-boy.toml`, one-file image) | 3.98 / 5.92 / 9.19 | 4.02 / 5.98 / 9.29 | 4.37 / 6.35 / 9.72 |
| Rebound (`snouty-boy-color.toml`, boy-m8 image) | 1.85 / 9.54 / 19.49 | 1.86 / 9.65 / 19.70 | 1.94 / 10.01 / 20.15 |
| Tetris DX (CGB) | | 4.26 / 5.10 / 11.41 | 5.18 / 6.63 / 12.30 |
| Tetris (DMG) | | 8.51 / 8.92 / 13.38 | 9.50 / 10.15 / 15.01 |

Sound off is within 0.05 ms mean of the plan commit. Sound on: 0 updates
over budget on 2048, Tetris and Tetris DX; underruns 0 (queue min 1514,
mean ~2100); the audio share is about 0.9-1.0 ms mean, 0.9-1.6 ms worst
(on minus off; in the TDX symbol table `render_keep` 6.4%, noise 3.4%,
wave 2.6%, the feed 0.6% of cycles). The Rebound script no longer reaches
the game before update ~1450 (it sits in the picker, in the plan-commit
build too; its one over-budget frame 1413 is the same in all three), so
its bench counts the picker's silence as underruns. WAVs were dropped
(Adrian, 2026-10-04: he flashes builds himself at the show).

Open: Adrian's ear on the badge (gain, noise drums); the Rebound bench
script's picker timing.

## Fast forward (2026-10-04)

Contract: root `docs/FAST_FORWARD.md` (trigger changed by Adrian the same
day from Select+Right to the double tap). Branch `emu-ff-boy`.

- Input (`frontend/input.zig`): a short Select press holds its tap back
  for `ff_tap_window` (12 frames, 200 ms) after the release; a second press
  inside the window is fast forward from that press while Select is held
  (no tap, no menu timer, nothing on release); no second press: the tap
  as before, 200 ms later. Start in the window or during fast forward
  drops everything. Only Select is masked; the d-pad and A/B/Start reach
  the game. `GameInput.fast`, `Ctx.step(pad, fresh, fast)`.
- Stepping (`main.zig` `step_fast`): skipped frames with
  `lines_wanted` cleared (`video.set_drawing`) and no sound rendering, each
  through `rewind.record_frame`, while time since the update began plus
  estimates of one more skipped frame and the drawn frame fit
  `tuning.ff_budget_us` (13 ms, up to `ff_max_frames` 4), then the drawn
  frame. Deviation from the plan: a game whose skipped plus drawn frame do
  not fit 13 ms (DMG Tetris busy-waits for VBlank: ~5.8 ms skipped, ~8.6 ms
  drawn, so it stayed at 1x) gets two refreshes on purpose
  (`ff_slow_budget_us` 28 ms, up to 8 frames, picture at 30 Hz): 2x.
  Wasm (clock stub): always 4 frames.
- Sound: `audio.fast_forward` turns rendering off and ramps the stream
  out; the first 1x frame resumes it primed, so the cart's underrun count
  stays 0.
- Indicator `>>4.0x` (frames per 60 Hz refresh, averaged) bottom right;
  the next frame's full redraw removes it (checked with badge-bench
  `--lcd`). Hints: "2x Sel+hold: fast" under "Hold Select: menu" in the
  play strip, and at the foot of About.
- Tests: comptime tests in `input.zig` (delayed tap, double tap and hold,
  other buttons pass, late second press opens the menu, Start in the window
  and during fast forward), a flow test, and `tests/determinism.zig` fast
  forward batches (1 to 4 frames, pixel work and sound off but the last)
  equal to 1x frame by frame in state and drawn lines on 2048-gb,
  rex-runner and rebound. Cart 153 tests pass; `zig build test` and
  `check-float` green; every other cart's UF2 byte-identical to emu-ff.
- Size (fast, default build): .text 89,188 -> 90,976, .bss 27,324 ->
  27,348, UF2 236,544 -> 240,128; the arena is ~1.8 KB smaller.

badge-bench, calibrated busy ms mean / p95 / max. Fast forward scripts: the
PLAN.md sound-section presses to reach play, then `SELECT:1000-1002,
SELECT:1006-1599` (Tetris also LEFT and A inside); 2048 `START:30-31,
START:120-121, SELECT:200-202, SELECT:206-700` with DOWN, LEFT and RIGHT
inside; Rex Runner `START:30-31, START:200-202, SELECT:300-302,
SELECT:306-800, A:400-402`. Speed from `step_frame` calls (`--json` hot
list) over the fast window:

| ROM | Fast window | Over 16.7 ms | Frames per update | Speed |
|---|---:|---:|---:|---:|
| Tetris (DMG) | 26.19 / 26.53 / 26.79 | 594 of 594, by design (two refreshes, under 33.3) | 4.0 | 2.0x |
| Tetris DX (CGB) | 10.98 / 11.61 / 12.26 | 0 | 4.0 | 4.0x |
| 2048 (DMG) | 6.94 / 7.10 / 15.16 | 0 | 3.97 | 4.0x |
| Rex Runner (CGB) | 7.41 / 8.41 / 25.90 | 4 (464-467, see below) | 4.0 | 4.0x |
| Tetris DX, `-Dsound=true` | 10.99 / 11.62 / 12.27 | 0 | 4.0 | 4.0x |

Rex Runner 464-467: the game-over frames cost ~3x a running frame; one
update overshot to 17.99 ms (the estimate trails by a frame), the next
three took the two-refresh path (25-26 ms). 2048's maxima are the frames
a tile move lands in. Sound on: overlay `u 0` throughout; the bench's OS
pads silence only inside the fast window (1008-1599) and the queue is
back above 1,000 samples on the first 1x update.

1x, the sound-section scripts (bf44cc3 plan commit -> this branch):
Tetris 8.51 / 8.92 / 13.38 -> 8.57 / 9.30 / 13.40, Tetris DX 4.26 / 5.10 /
11.41 -> 4.32 / 5.15 / 11.79, 2048 (`snouty-boy.toml`) 4.02 / 5.98 / 9.29
-> 4.09 / 6.00 / 9.31, all 0 over. The ~0.06 ms: the overlay's glyph
blitter is no longer inlined (it takes a position now) and the play hint
strip has two lines in the first 3 s.

Preview: `tools/scripts/ff_rex.json` on a Rex Runner wasm,
`docs/fast_forward.gif` and `docs/fast_forward_sheet.png` (1x, `>>4.0x`,
1x).

Open: Adrian on the badge (feel of the 200 ms tap delay, Tetris at 2x with
a 30 Hz picture).
