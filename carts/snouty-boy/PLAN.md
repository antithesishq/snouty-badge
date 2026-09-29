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

## Hardware checklist (Adrian)

- M1 gate: overlay avg/max microseconds and FPS with 2048-gb.
- Menu: game shows through around the panel; resume is clean.
- Scrub: step feels instant; Right back to live takes well under a second;
  restored frame visible under the bar; neopixels dim in menu, off after.
- Chime audible on the splash.
- M5: a `.gb` copied to the drive runs; the About screen says "drive"; FPS
  with the ROM in flash; several files show the picker.

## Later milestones

See SPEC.md section 17. M2 needs the ROM Adrian supplies (or a homebrew
pulled at Claude's judgement if it blocks work).
