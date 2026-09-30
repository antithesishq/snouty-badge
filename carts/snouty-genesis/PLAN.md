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

## M2 Streaming and frontend: contract

Branch `genesis/m2` (from main `f53d696`, worktree
`/home/exedev/snouty-badge-genesis`). Two Opus tracks in worktrees with
disjoint files, then integration. What M2 delivers (SPEC.md sections 5,
6, 11, 12, 17): the boot splash, the emulator menu (buttons, scale,
sound, overlay, reset, pick ROM, about), the button remap, the crop
scale mode, the drive picker for several ROMs, the no-ROM help screen,
and a host-tested drive scan against a FAT12 fixture image. Not in M2:
the H40 column-pair averaging option of SPEC.md section 6 (1.5x render
time; revisit with the M4 numbers), the two-note splash chime (dropped:
every cart boots silent, root docs/SOUND.md, and audio gets no further
investment), any scrub (M3).

### Frontend states (main.zig, both tracks touch it; integration merges)

`State = enum(u32) { splash = 0, running = 1, menu = 2, pick = 3, help = 4 }`,
one update = two Genesis frames = 1/30 s, as M1.

- `start()`: `text.init`, `video.init`, `romsrc.scan()`. Then the ROM
  decision:
  - not a drive build (`!romsrc.use_drive`: wasm, `-Dmd-rom-source=embed`),
    or the volume failed to open: `begin(romsrc.embedded(why))`, run after
    the splash;
  - exactly one playable candidate: `begin(romsrc.select(i))`, run after
    the splash;
  - two or more: `pick` after the splash;
  - a volume but no playable candidate: `help` after the splash.
- `begin(src)`: `md.init_in_place(src)`, `md.line_sink = video.sink()`,
  apply the scale setting (below), `have_md = true`. Never touch `md`
  before `have_md` (the wasm exports return 0 until then).
- `splash`: `splash.update(any_pressed)` returns true when done or
  skipped; then `suppress_held` and enter `running` (calling
  `run_update` in the same update), `pick` or `help`.
- `pick` (drive builds only, guarded by `if (romsrc.use_drive)` so none
  of it compiles into wasm): `picker.update(edge)` returns `??usize`:
  outer null stay; inner null the embedded ROM (`romsrc.embedded("skipped")`),
  else `romsrc.select(i)`. Then `begin`, `suppress_held`, `running`.
- `help` (drive builds only): `help.update(edge)` returns true on A (or
  B): `begin(romsrc.embedded("no ROM on the drive"))`, `running`.
- `running`: as M1's `run_update`; `in.open_menu` enters `menu`
  (`menu.open()`, then `menu.update` once in the same update).
- `menu`: `audio.silence()`; `menu.update(&md, edge)` returns `.stay`,
  `.resume_game` (close, `suppress_held`, apply scale, `running`,
  `run_update` in the same update) or `.pick_rom` (close, `suppress_held`,
  `picker.reset()`, `pick`; drive builds with candidates only).
- `romsrc.draw_report()` only while `debug.enabled` (as Gear); the About
  screen and the title band carry the ROM facts otherwise.

### Track A: menu, splash, remap, scale (branch `genesis/m2-menu`, worktree `/home/exedev/snouty-badge-genesis-menu`)

Files: `cart/src/frontend/menu.zig` (new), `cart/src/frontend/splash.zig`
(new), `cart/src/frontend/input.zig`, `cart/src/frontend/video.zig`,
`cart/src/main.zig` (splash and menu wiring only, the `pick`/`help` arms
left as `if (romsrc.use_drive) {}` stubs coded to the Track B interface
below; keep the diff small), `build.zig` (the `iris` import only:
`cart.addImport("iris", b.createModule(.{ .root_source_file = b.path("lib/iris_mark.zig") }))`).

- Splash: Snouty Gear's `splash.zig` at 30 Hz: `frames = 36`,
  `land_frame = 24`, title "SNOUTY GENESIS" with "GENESIS" in the
  accent colour, the Iris mark (`lib/iris_mark.zig`, 24x24 at 2x) sliding
  down onto a dark navy background (`video.blank` takes a 9-bit CRAM word
  here, not Gear's 12-bit one). No chime, no `request_chime`. Any button
  skips.
- Menu: Gear's `menu.zig` adapted. Opened by the 500 ms Select hold
  (`input.zig` already raises `open_menu`), frozen frame through the
  `copy_forward` trick (Gear's comment explains it; the cart runs
  `.no_copy_full_frame` too). Keys as Gear: Up/Down move (wrap), A
  choose, B or a Select tap that began inside the menu resumes,
  Left/Right cycle a setting row; Left/Right on Resume/Reset/About do
  nothing (M3 scrubs there and draws "Scrub: ..." on the panel's bottom
  line, keep it free). Rows in order: `Resume`, `Buttons`, `Scale`,
  `Sound`, `Debug overlay`, `Reset`, `Pick ROM`, `About`. `Pick ROM`
  exists only when `romsrc.use_drive and romsrc.candidate_count > 0`
  (comptime-false in wasm: the row is skipped, not greyed); A on it
  returns `.pick_rom`. Eight rows do not fit Gear's layout (7 rows, 10 px,
  86 px panel): use 9 px rows, or a 28 px title band; keep the bottom
  line free. `pub const version = "0.2.0-m2"`.
  - Title band: "SNOUTY GENESIS", then the ROM's name
    (`romsrc.title_name()`: the header's domestic name trimmed, else the
    overseas name, else the file name; cut to 20 columns with `~`), then
    "verified by" / "deterministic replay".
  - `Sound: On/Off` flips `audio.enabled` directly (it is seeded from
    `build_options.sound`; the M1 placeholder's A toggle goes away).
    `Debug overlay: On/Off` flips `debug.enabled`.
  - `Reset`: `md.reset()`, then the scale is re-applied by main (Vdp.reset
    puts `line_mode` back to squeeze), and `.resume_game`.
  - About: version; file name (`romsrc.file_name()`), header name, size
    in KB, `Source: embedded|drive`, region letters and "SRAM" when
    declared (`core.rom.parse_header`), then `CRC xxxxxxxx` and
    "fragmented" for a drive ROM, or "Drive not used:" + `romsrc.fallback`
    for an embedded one. "B: back" on the bottom line.
  - Colours: Gear's fixed scheme (navy band, white/yellow text, black
    panel with a blue frame, yellow cursor bar).
- Remap (SPEC.md sections 5 and 18 item 5): `input.zig` gains
  `pub const Layout = enum(u8)` of the six assignments of Genesis A, B, C
  to badge B, badge A and the Select tap, `pub var layout: Layout`
  defaulting to the M1 mapping (badge B = B, badge A = C, tap = A), the
  next ones `B=C A=B S=A`, `B=B A=A S=C`, `B=A A=B S=C`, `B=A A=C S=B`,
  `B=C A=A S=B`. `pad_from_controls` and the tap use it; the tap's pad
  bit is the layout's third button. Menu label `Btns B=B A=C S=A`
  (16 columns). Cycled by Left/Right/A. `Edge` gains `released` and
  `any_pressed` (Gear has them).
- Scale (SPEC.md section 6): `video.zig` gains
  `pub var scale: core.vdp.LineMode = .squeeze` and
  `pub fn apply(md: *core.Md) void` (`md.vdp.line_mode = scale`); main
  calls `apply` in `begin`, after `Reset` and when the menu closes. The
  menu row reads `Scale: Squeeze` / `Scale: Crop`. (M3 note: `Keyframe`
  carries the whole `Vdp`, so `restore` must re-apply too.)
- Wasm exports: `debug_state` documents 0..4; `debug_menu_opens`
  (rename of `debug_menu_requests`), `debug_settings` (bit 0 sound, bit
  1 crop, bits 2-4 layout index, bit 5 overlay), `debug_sound_on` kept.
- Verify: `zig build -Dcart=snouty-genesis -Dcart-mode=xip` from the
  worktree root; `node tools/preview.mjs zig-out/bin/snouty-genesis.wasm
  --frames 220 --every 4 --script tools/scripts/m2_menu.json` (write that
  script: nothing to 40 so the splash plays, then Select held 45-62,
  Down/Right/A taps through the rows, B) and look at the PNGs; the host
  tests stay green (`zig build test-genesis ...`; `tests/roms` is a
  symlink into the genesis worktree). Sizes: `.text` must stay under
  the 256 KB window with room for Track B (about 8 KB); report `.text`
  and `.bss` before and after. `zig fmt`. Commits `snouty-genesis: `
  prefixed; do not merge, do not touch main.

### Track B: drive scan, picker, help (branch `genesis/m2-drive`, worktree `/home/exedev/snouty-badge-genesis-drive`)

Files: `cart/src/frontend/drive.zig` (new module, no `cart-api`
import), `cart/src/frontend/romsrc.zig` (rework), `cart/src/frontend/picker.zig`
(new), `cart/src/frontend/help.zig` (new), `tests/drive_unit.zig` (new),
`tests/fixtures/` (new: the image, its sources and a README with the
exact `make_romfs.py` command), `tests/all.zig` (one line), `build.zig`
(the `drive` module for the cart and the tests, and `romfs` for the
tests), `main.zig` (the `pick`/`help` arms and `begin`; the splash/menu
arms coded as stubs to the Track A interface above; keep the diff small),
`tools/` only if a tiny helper is needed to interleave an SMD fixture.

- `drive.zig`: everything that decides what is on the drive, host
  testable. Imports `core`, `rom` (the generated module) and `romfs` only.
  `pub const max_candidates = 8`; `pub const Candidate = struct { entry:
  romfs.Entry, verdict: core.rom.Refusal, name: [48]u8 + len (the header's
  domestic name trimmed, else overseas; empty when refused), size: u32 }`
  with `playable()`; `pub const Scan = struct { candidates, count,
  playable_count, err: ?romfs.Error }`; `pub fn scan(base: [*]const u8,
  clusters: []u16) Scan` (the volume's `.gen`/`.md`/`.bin` root files,
  each mapped once through `clusters`, `core.rom.check` on a `RomSource`
  built as M1's `source_of`; files with no header at all are listed with
  `.no_header` so the picker can show them dimmed, not skipped); `pub fn
  open(base, cand, clusters) !romfs.Mapped` and `pub fn source_of(m:
  *const romfs.Mapped) core.RomSource`. `Volume` may be kept in a module
  static after `scan` so `open` needs no re-open.
- `romsrc.zig`: `pub const use_drive = !cart.is_wasm and rom.source ==
  .drive`; `pub var scan_result: drive.Scan`; `pub fn scan() void` (drive
  builds; a no-op otherwise); `pub var candidate_count`, `playable_count`;
  `pub fn select(i: usize) core.RomSource` (map the candidate again,
  CRC32, `origin`, the report line as M1); `pub fn embedded(why:
  ?[]const u8) core.RomSource` (M1's, now `pub`); `pub var fallback:
  ?[]const u8` (why the drive was not used); `pub fn file_name()`
  and `pub fn title_name()` ([]const u8, see Track A); `origin`, `crc`,
  `report()`, `draw_report()` as M1. The `clusters` table (5 KB) and
  `mapped` stay statics owned here.
- `picker.zig`: Snouty Boy's picker at 30 Hz with the menu's colours
  (navy title band "Pick a ROM", white rows, yellow cursor bar, dimmed
  unplayable rows). One row per candidate: file name (14 columns) and
  size (`512K`). Under the list the selected file's header name, or its
  refusal text (`Refusal.text()`) when unplayable; then `A: play` and
  `B: test ROM`. `pub fn update(e: input.Edge) ??usize`, `pub fn reset()`
  (cursor to the first playable; called before re-entering from the
  menu). Full redraw every update.
- `help.zig`: the SPEC.md section 12 screen for a drive with no Genesis
  ROM: "No Genesis ROM found", "Copy a .gen, .md or .bin file to the
  SYCLBADGE drive, eject, restart." (word-wrapped to 20 columns), then up
  to four skipped files as `NAME: reason` (dimmed), then `A: run test ROM`.
  `pub fn update(e: input.Edge) bool`. The embedded ROM is always the
  shipped test ROM in a badge build, so the wording can say so.
- Fixture (`tests/fixtures/m2_drive.img`, `--truncate`): from
  `roms/snouty-test.bin`: `TEST.GEN` contiguous, `FRAG.MD` fragmented
  (`--fragment`), `NOHDR.BIN` (16 KB of a byte pattern with no header),
  `BAD.BIN` an SMD-interleaved copy of the test ROM (build it with a few
  lines of Python noted in the README: 512-byte copier header with bytes
  8-9 AA BB, then 16 KB blocks odd bytes first), `README.TXT` (ignored
  by extension), a deleted `.gen` entry (`--delete`), a `.fseventsd`
  directory. Keep the image small (the test ROM is 16 KB).
- `tests/drive_unit.zig` (`drive:` prefix): `scan` finds the four
  `.gen/.md/.bin` files with verdicts ok/ok/no_header/smd_interleaved,
  `playable_count == 2`, names `SNOUTY TEST`-style from the header (read
  the actual header text of the test ROM and assert it), sizes; `open`
  of `TEST.GEN` is contiguous and of `FRAG.MD` is not, both read back
  byte-identical to `roms/snouty-test.bin` through `source_of` +
  `core.rom.read8/read16`, CRC32 equal; a scan of an image with no ROM
  gives `playable_count == 0` and no error; a bad boot sector gives
  `err = NoVolume`. The tests' `drive` module is rooted at
  `cart/src/frontend/drive.zig` with imports `core`, `rom`, `romfs`
  (`lib/romfs.zig`); the fixture is `@embedFile`d from `tests/fixtures/`.
- Screens: no wasm path reaches them, so capture with badge-bench:
  `python3 tools/make_romfs.py carts/snouty-genesis/out/pick.img
  carts/snouty-genesis/roms/snouty-test.bin=TEST.GEN
  carts/snouty-genesis/roms/miniplanets.bin=MINI.GEN` then
  `badge-bench/bench.sh zig-out/firmware/snouty-genesis-xip.elf --config
  badge-bench/carts/snouty-genesis.toml --romfs carts/snouty-genesis/out/pick.img
  --frames 60 --png 10 --press B:1-2 --press DOWN:44-45 --out
  carts/snouty-genesis/out/pick/` (B skips the splash stub) and an empty
  image for the help screen; put one PNG of each in `docs/` as
  `m2_picker.png`, `m2_help.png`.
- Verify: build, `zig build test-genesis ...` green with the new tests,
  every M1 test unchanged, badge-bench with the M1 toml (empty image)
  still runs the embedded ROM; report `.text`/`.bss`. `zig fmt`. Commits
  `snouty-genesis: ` prefixed; do not merge, do not touch main.

### Integration (me, after the two merge)

1. Merge A then B into `genesis/m2`; resolve `main.zig` and `build.zig`.
2. `zig fmt`, build, all host tests, golden hashes unchanged (the core
   is untouched).
3. Scripts: `tools/scripts/m2_play.json` = `m1_play.json` shifted by the
   36 splash updates (or a B tap at update 1 to skip it: pick the shift so
   the bench measures the game); `m2_menu.json` from Track A. Toml:
   `frames` and `script` updated; bench numbers for the game (mean/worst)
   and for a menu-open run.
4. Sizes against SPEC.md section 13; preview GIF `docs/m2_splash_menu.gif`
   (splash, game, menu, About), the picker and help PNGs from Track B.
5. `docs/RUNNING.md` (states, keys, menu rows, picker, help, exports,
   bench), `SPEC.md` section 12 status (chime dropped) and Status,
   `README.md`, this file's Status; tag `snouty-genesis/m2`; ff-merge
   main; push. Hardware check (open, not a gate): XIP launch, drive
   streaming stall rates contiguous and fragmented (Adrian, show day).

## M3 Scrub: contract

The time scrubber (SPEC.md section 10): an undo record per 30 Genesis
frames, Left/Right in the menu step half a second back and forward through
them, resuming from a parked position plays on from there and drops the
future. Two Opus tracks in worktrees against the prep commit on
`genesis/m3`, then integration. Snouty Gear's M3 (`gear/m3`, worktree
`/home/exedev/snouty-badge-gear`) is the prior art for the frontend
(`frontend/rewind.zig`, the menu's scrub line and scrub view, the debug
exports, `m3_scrub.json`) and for the shape of the tests; its page store
is not.

### Step 0 (done in the prep commit)

The third Start of the Miniplanets scripts paused the game (SPEC 10.1).
`tests/golden_mini.zig` `pad_at`, `tools/scripts/m1_mini300.json` and
`m2_mini300.json` lost it; the `golden-mini:` lines and the unpaused
badge-bench numbers are in the Status entry for 2026-09-30 (M3 started)
and are the M3 baseline: every track compares against them.

### Decisions defaulted here (Adrian may overrule; nothing is blocked)

- Mechanism: the copy-on-first-write undo records SPEC.md 10 describes,
  not Gear's page store. The page store keeps every non-zero page of the
  newest keyframe in its pool: for a Genesis with its 64 KB VRAM in use
  that is about 136 KB, more than the ~105 KB the RAM window has left. An
  undo record only holds what changed, and the live console is the newest
  keyframe.
- A record is applied by swapping: each 64-byte block in the record is
  exchanged with the console's block, and the record then holds the
  newer contents. Applying it again goes forward. So Left and Right are
  the same operation, bit-exact, with no input log and no replay
  (deviation from SPEC.md 10 as first written: the per-frame pad log is
  dropped; Gear needed it to replay back to live).
- Storage: one uniform ring of 68-byte slots (`u16` id, `u16` pad, 64
  bytes) in a run-time arena, the RAM the linker leaves between
  `__bss_end__` and `__stack_limit__` minus a 1 KB guard, as Gear does.
  A record is a run of slots: first the console's small state (every
  console field outside the four byte regions, packed as `Md.Small`,
  about 1.7 KB, ids `0xF000 + chunk`), then one slot per block first
  written in the interval (id = region << 12 | block). Regions: work RAM
  (1024 blocks), VRAM (1024), Z80 RAM (128), cartridge SRAM (256 at most,
  only the declared range is ever written). The dirty state is one byte
  per block (2432 bytes in `.bss`), read on the write paths and cleared
  when a record closes. When the ring is full the oldest closed record is
  evicted; when the open record alone fills it, history is lost until the
  next boundary (the dirty bytes are set to 1 so the write paths stop
  copying) and rebuilds from there.
- Interval 30 frames (0.5 s, the scrub step), records capped at 64
  (32 s). Block size 64 B (SPEC 10.1 measured 16 B as not worth it for
  Gear; the same holds here).
- The picture while parked: the console is restored exactly to the
  keyframe and stays there; `Md.render_still` draws all 128 rows from
  that state through the line sink without stepping (sprite table cache
  rebuilt, the sticky status bits saved around it), so the parked state
  is never disturbed. It shows the frame the game was about to draw,
  which is what a player expects from "0.5 s ago".
- The menu UI is Gear's: "Scrub: live / 3.5s" or "Scrub: -1.5 / 3.5s" on
  the panel's bottom line (`menu.scrub_line_y`, already reserved),
  Left/Right on a non-setting row scrub with 4 steps per second on hold,
  after a step the panel gives way to a bottom bar over the restored
  picture, B or a Select tap resume, Up/Down/A bring the panel back.
  "Scrub: no memory" when the arena holds fewer than two records' worth
  of slots. Reset and Pick ROM forget the history.
- Performance gate: the write-path check costs one byte load and a
  branch per 68000/Z80/VDP write. Track A measures with badge-bench
  before and after; the budget is +1.0 ms mean on the unpaused Miniplanets
  script and the section 8 totals (31 mean / 33 worst) still hold. If the
  check costs more, the fallback is a per-frame block compare against a
  shadow copy of work RAM only (VRAM keeps the DMA-run marks), decided at
  integration, not by the track.

### Frozen for M3

```zig
// core/undo.zig (Track A). One tracker for one console (file-level state:
// the dirty bytes must be reachable from the write paths without an Md
// offset). No cart-api, no allocator; the arena comes from the frontend.
pub const block_size = 64;
pub const Slot = extern struct { id: u16, pad: u16 = 0, data: [block_size]u8 };  // 68 B
pub const frames_per_record = 30;
pub const max_records = 64;
pub const Region = enum(u4) { work_ram = 0, vram = 1, z80_ram = 2, sram = 3, small = 15 };
pub fn init(arena: []align(4) u8) void;      // slots = arena.len / 68; tracking off
pub fn capacity_slots() usize;               // 0 before init
pub fn reset(md: *Md) void;                  // forget history, open record 0 from md; tracking on
pub fn disable() void;                       // tracking off (dirty all 1), the console runs untracked
pub fn record_frame(md: *Md) void;           // after every stepped frame; truncates if parked; boundary close/open
pub fn can_step(dir: i2) bool;
pub fn step(md: *Md, dir: i2) bool;          // swap one record (see above); false at the ends
pub fn parked() bool;                        // cursor != 0
pub fn resume_here(md: *Md) void;            // frontend, before the first step_frame after a scrub: drops the future, opens a record here
pub fn depth_frames() u32;                   // frames behind live (0 live)
pub fn history_frames() u32;                 // frames reachable back from live
pub fn record_count() usize;                 // closed records held
pub fn slots_in_use() usize;
// Hot hooks, inline, called BEFORE the write with the region address:
pub inline fn touch_wr(addr: u16) void;      // work RAM byte address (a word never straddles a block)
pub inline fn touch_vr(addr: u16) void;      // VRAM
pub fn touch_vr_range(addr: u16, bytes: u32) void;  // DMA runs, wraps at 64 KB
pub inline fn touch_zr(addr: u13) void;      // Z80 RAM
pub inline fn touch_sr(addr: u14) void;      // cartridge SRAM (index into md.sram)

// core/md.zig (Track A)
pub const Small = struct { ... };            // cpu, vdp: vdp.Vdp.Small (all but vram and line_mode), io, pad,
                                             // sram_active, dma_stall, z80, z80_bank, arbiter, z80_int, ym, psg,
                                             // frame_count, m68k_carry, z80_carry
pub fn save_small(md: *const Md, out: *Small) void;
pub fn load_small(md: *Md, k: *const Small) void;  // recomputes tone_cache; keeps rom, line_sink, line_mode, not_wait_loop
pub fn render_still(md: *Md) void;           // 128 rows through line_sink from the current state, state unchanged
// Keyframe / snapshot / restore stay (tests).

// cart/src/frontend/rewind.zig (Track B), over core.undo
pub fn init() bool;                          // arena from the linker (wasm: static), undo.init; false = no memory
pub fn reset(md: *core.Md) void;             // after begin() and the menu's Reset
pub fn record_frame(md: *core.Md) void;
pub fn step(md: *core.Md, dir: i2) bool;     // undo.step then show()
pub fn show(md: *core.Md) void;              // render_still + video.finish_frame
pub fn depth_frames() u32; history_frames() u32; record_count() usize; capacity_slots() usize; slots_in_use() usize; arena_bytes() usize;
// cart/src/frontend/tuning.zig (Track B): stack_guard = 1024, wasm_arena_bytes (badge-like, set at integration)
```

`main.zig` (Track B): `rewind.init()` in `start` (before the console
exists; the arena does not depend on the ROM), `rewind.reset(&md)` at the
end of `begin`, `rewind.record_frame(&md)` after every `md.step_frame` in
`run_update`, `rewind.reset` after the menu's Reset row (`md.reset()`
writes the memories directly, past the hooks). Exports `debug_scrub_depth`,
`debug_scrub_history`, `debug_scrub_records`, `debug_scrub_slots`,
`debug_scrub_capacity`, `debug_scrub_arena` for `--dump-exports`.

### Track A: core (files `core/undo.zig`, `core/md.zig` (Small, render_still, hooks), `core/bus.zig`, `core/vdp.zig`, `core/z80bus.zig` (hooks only), `tests/undo_unit.zig`, `tests/determinism.zig`, `tests/scrub_sizing.zig`, `tests/all.zig`)

- `core/undo.zig` as frozen above. Ring bookkeeping: records as
  (start slot, length) in a `[max_records]` table plus the open record;
  append at the head, evict at the tail, modular slot indices; `cursor`
  = records applied (0 live). Left from live with an empty open record
  (live on the boundary) goes straight to the newest closed record, as
  Gear's ring does. Resuming while parked drops the applied records
  (they hold the future) and opens a fresh record from the parked state.
  `reset` and the boundary close/open: `save_small` into the record's
  small slots, dirty bytes cleared. The hot hooks test one dirty byte and
  call a non-inline `save(region, block)` on the first write.
- Hooks: `bus.zig` `write8`/`write16` work RAM path (`touch_wr` before
  the store), `write8_io` SRAM store (`touch_sr`); `vdp.zig` `bus_write`
  VRAM case (`touch_vr`), `dma_68k` fast path (`touch_vr_range` per run),
  `dma_fill` and `dma_copy` VRAM stores (`touch_vr` per byte, or a range
  when register 15 is 1 or 2); `z80bus.zig` `write` Z80 RAM store
  (`touch_zr`); the 68000's A00000 writes reach the same function. CRAM
  and VSRAM are in `Small`. Nothing else in the core writes the regions
  except `reset` (`@memset`), which the frontend follows with
  `rewind.reset`.
- `Md.Small`/`save_small`/`load_small` copy field by field with an
  `inline for` over the field names (Gear `gg.zig` `save_small`);
  `vdp.Vdp.Small`/`save_small`/`load_small` the same, skipping `vram`
  and `line_mode`; `spr_cache`, `spr_band`, `spr_count`, `spr_dirty` are
  copied (they are consistent with the VRAM of the same instant).
  `load_small` ends with `tone_cache = pick_tone()`.
- `Md.render_still`: for every line with a row (`vdp.row_for_line`),
  `vdp.render_line(row, sink)` through `md.line_sink`; save and restore
  `vdp.status` and `vdp.line` around it; `vdp.line` is walked 0..261 for
  `row_for_line`. Confirm with a test that a `Keyframe` before equals the
  one after (`std.meta.eql` field by field, as `tests/determinism.zig` in
  Gear does).
- Tests (all host, `tests/all.zig` updated):
  - `undo_unit.zig`: a small arena (say 400 slots) over a console running
    the test ROM: record/step/step symmetry (Left then Right restores the
    exact `Keyframe`), depth/history arithmetic, truncation on resume,
    eviction order, lose-history and rebuild, the empty-open-record
    boundary case, `disable`.
  - `determinism.zig`: the test ROM (always present) and Miniplanets (skip
    if absent) for 600 frames with a scripted pad stream, a full
    `Keyframe` every 30 frames alongside a tracked run in a large arena;
    then walk Left through every record comparing each parked state with
    the keyframe of that frame, walk Right back to live and compare with
    the live keyframe; also a tracked console and an untracked one stepped
    identically end equal (tracking changes no behaviour). Then resume
    from a parked position and check the next boundary's record chains
    correctly (step back twice, forward twice).
  - `scrub_sizing.zig` (print only, like `golden-mini`): Miniplanets
    through `golden_mini.pad_at`, slots per record and a per-scene
    summary (boot, title, level load, play), the SPEC 10.1 table redone
    through the real store.
- badge-bench before (prep commit) and after (tracking on from `start`;
  Track A wires a minimal `undo.init`/`undo.reset`/`record_frame` into
  `main.zig` behind nothing else so the numbers are of the shipped path;
  Track B's `rewind.zig` replaces it at integration): unpaused
  `m2_mini300.json` from `out/romfs_mini.img`, 336 updates, `busy ms`
  mean / worst, and the test ROM script. Report the delta.
- `zig fmt`, `zig build test-genesis` green, `golden`/`golden-mini` lines
  unchanged from the Status baseline, both targets build, `.text` and
  `.bss` reported (`size -A`).

### Track B: frontend (files `cart/src/frontend/rewind.zig`, `cart/src/frontend/tuning.zig`, `cart/src/frontend/menu.zig`, `cart/src/main.zig`, `tools/scripts/m3_scrub.json`, `badge-bench/carts/snouty-genesis.toml`, `docs/RUNNING.md`)

- Until Track A lands, build against a stub `core/undo.zig` with the
  frozen signatures (no-ops returning "no memory"), kept out of the
  track's commits or replaced at merge; `Md.render_still` may be stubbed
  as one `step_frame` for the preview run. Do not touch other core files.
- `rewind.zig` as frozen: the arena from `__bss_end__`/`__stack_limit__`
  minus `tuning.stack_guard` on the badge (Gear's `find_arena`), a
  `tuning.wasm_arena_bytes` static in wasm (start at 100 KB; integration
  sets it to the badge's `size -A` figure); `init` returns false when
  fewer than `2 * small_slots + 64` slots fit; stats for the menu and the
  exports.
- `menu.zig`: Gear's scrub line, `scrub_view` bar, auto-repeat (4 steps
  per second while Left/Right held), `scrub_label` with its comptime
  checks, dim line while there is no history, "Scrub: no memory"; the
  Genesis row set stays (Resume, Btns, Scale, Sound, Debug overlay, Reset,
  Pick ROM, About). Reset and Pick ROM call `rewind.reset` after the
  console is (re)made (`begin` does it for Pick ROM). After a scrub step
  `video.apply(&md)` is harmless and kept for the M2 note.
- `main.zig` wiring and exports as above; `debug_state` unchanged.
- `tools/scripts/m3_scrub.json`: Miniplanets from the splash into play
  (M2's `m2_mini300.json` presses), then a 35-update Select hold to open
  the menu, Left x4 with releases (each step 0.5 s back), Right x2, B to
  resume, 40 updates of play, the menu again, Left x2, B; about 420
  updates. Verify in the headless preview with
  `--dump-exports debug_state,debug_scrub_depth,debug_scrub_history,debug_scrub_records`
  that the depth reads 60/120/180/240 then 120/60 frames, that resuming
  truncates (records drop) and that play continues; PNGs of the scrub
  bar. The toml gets a comment with the Miniplanets scrub command
  (`--script ... m3_scrub.json --frames 420`); the default run stays the
  test ROM.
- `docs/RUNNING.md`: the scrubber's controls and limits (about 5 s in
  play, more on menus, under 1 s right after a level load).
- No host tests (cart-api); `zig fmt`, both targets build, no comptime
  loops.

### Integration (me, after the two merge)

1. Merge both tracks into `genesis/m3`; `zig build test-genesis` green
   (determinism included), golden lines unchanged, every cart builds.
2. `wasm_arena_bytes` from `size -A` of the merged XIP ELF (RAM window
   0x4AF00 minus the 32 KB stack, `.data` + `.bss`, the guard); preview
   run of `m3_scrub.json`; GIF `docs/m3_scrub.gif`; RUNNING.md folded.
3. badge-bench: unpaused Miniplanets and the test ROM with the scrubber
   on, against the Step 0 baseline; the scrub script's menu updates
   (`render_still` cost). Sizes.
4. SPEC 10 status paragraph, tag `snouty-genesis/m3`, merge to main and
   push (Adrian tests from main), pull-and-run notes.

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
- 2026-09-29 (M1 tracks merged, perf pass running): all four tracks
  landed on `genesis/m1` (A 5 commits, B 7, C 5, D 3) plus integration.
  - Track A: 68000 complete; SingleStepTests full set 1,000,060 cases:
    821,970 pass on state AND cycles, 178,087 address-error cases skipped
    (SPEC 4), 3 disputed data cases, 0 failures. Two-level decode (9.25 KB)
    chosen over the 64 K table (+55 KB flash for 2%). `code_window` on
    the bus for direct opcode fetch. 98.8 host cycles/instruction on a
    stub bus.
  - Track B: VDP with 70 unit tests incl. a random-state pixel-exact
    reference comparison; H40 stress at the 4 ms render budget, H32 and
    shadow/highlight stress over it (5.7 / 5.0 ms; open).
  - Track C: bus, rom refusals, frame loop, frontend, golden test
    (hashes filled after review), `m1_play.json`.
  - Track D: Z80 map with cached window, YM2612 register model with
    timers (period = (1024-TA)*144 YM clocks: the datasheet's 72 is for
    the OPN prescaler), PSG, `pick_tone`. Found the test ROM driver bug
    (EI inside the V-int handler: 3 acceptances per line-long INT); ROM
    fixed and rebuilt (checksum 00B2).
  - Integration: `Z80.step` called, not inlined (85 KB function
    otherwise); bus accessors out of line (inline they overflowed the
    256 KB flash window by 2.3 KB). 124/124 host tests. `.text` 200,732 B,
    `.bss` 164,828 B.
  - Runs: the test ROM end to end (tone sequence as tools/testrom/README);
    Miniplanets boots, title, gameplay (docs/m1_miniplanets.gif).
  - badge-bench (calibrated, 120 updates): test ROM 22.75 ms mean / 26.30
    worst; Miniplanets from the drive image 34.65 / 37.67, OVER the 31/33
    targets (Z80 23.5%, 68000 handlers 47%, EA reads 13.6%, bus accessors
    5.4%, VDP 5%). Perf pass on `genesis/m1-perf` (Opus) with those
    targets (result below).
  - Open after M1: H32/shadow-highlight render cost; hot loops not yet in
    RAM-text (XIP cache); Z80 writes to the VDP through 7F00 dropped;
    menu is a placeholder (M2); a `-Dmd-rom` larger than the flash window
    fails the firmware link although the wasm builds (wasm-only step
    wanted); no root LICENSE (test ROM is MIT under Adrian's name).
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
- 2026-09-30 (M1 DONE): tag `snouty-genesis/m1`. Perf branch merged;
  on the merged tree: 136/136 host tests (SingleStepTests subset 0
  failures), golden hashes unchanged, every other cart's uf2
  byte-identical. badge-bench calibrated: test ROM 8.77 ms mean / 24.21
  worst; Miniplanets from the drive 18.61 / 28.11 (120 updates) and
  19.47 / 28.11 (300-update gameplay script): under the 31 / 33 targets
  at full speed, no fallback set. Sizes: `.text` 204,572 B (256 KB
  window), `.bss` 164,852 B (`Md` ~157 KB; ~110 KB of the RAM window
  left for the M3 ring), uf2 411,648 B (so about 830 KB of `romfs` remain
  for ROMs on an otherwise empty drive). Next: M2 streaming picker,
  menu, splash, remap, scale/crop. Hardware check (open): XIP launch,
  drive streaming stall rates.
- 2026-09-30 (simulator sound): as found in Snouty Gear 2026-09-29,
  upstream's wasm `tone2` shim sends `duration = -1` as `0xFFFFFFFF`,
  which the simulator's WASM-4 style worklet reads as a 255-frame
  attack/decay/sustain/release, so every note restarts a 4 s fade-in and
  music stays under 2% volume. `frontend/audio.zig` now calls the
  simulator's `tone` import itself in the wasm build (no attack, 6-frame
  sustain re-issued every update, 50% duty); the badge keeps the infinite
  `tone2`. Thumb `.text` byte-identical. `debug_tone_calls` counts voice
  changes on both targets (11 in the M1 play script), not the per-update
  re-issues. Headless check: `tools/preview.mjs` with its `tone` stub
  logging shows 0xFFFFFFFF durations before and sustain 6 / attack 0 after.
- 2026-09-30 (M2 started): branch `genesis/m2` from main `f53d696`; tracks
  A (menu, splash, remap, scale) and B (drive scan, picker, help) as above.
- 2026-09-30 (M2 DONE): tag `snouty-genesis/m2`. Track A (5 commits:
  input layouts and edges, scale + `video.apply`, romsrc names, splash,
  menu + state machine) and Track B (3 commits: `drive.zig` module +
  tests + fixtures, romsrc rework + picker + help + main wiring, screen
  captures) merged; main.zig, romsrc.zig and build.zig resolved by hand
  (integration commit a8e3409), the menu's Pick ROM row switched on.
  - Host tests 143/143 (136 of M1 unchanged, 7 `drive:`); golden hashes
    unchanged (the core is untouched). Every cart builds (`zig build`).
  - Sizes: `.text` 220,600 B (+16.0 KB over M1; 41.5 KB of the 256 KB
    window left), `.data` 156, `.bss` 165,412 B (+560; the picker's
    scan table). Embed build `.text` 196,620 B (no drive code).
  - badge-bench (calibrated, `busy ms`, game updates only, i.e. after the
    36 splash updates at 0.37 ms each): test ROM from the drive
    (`romfs_test.img`, `m2_play.json`, 156 updates) 8.75 mean / 24.21
    worst (M1 embedded 8.77 / 24.21); Miniplanets from the drive
    (`romfs_mini.img`, `m2_mini300.json`, 336 updates) 19.47 / 28.11 (M1
    19.47 / 28.11): the frontend costs nothing in play. Menu updates
    0.90 ms, picker 0.30 ms, help 0.33 ms. Choosing a 512 KB ROM in the
    picker costs one 43.6 ms update (the CRC32 over the file): a single
    slipped present at load, noted below.
  - Screens: `docs/m2_splash_menu.gif` (preview, `m2_menu.json`: splash,
    game, menu rows cycling, About, crop, second open), `docs/m2_picker.png`
    and `docs/m2_help.png` (badge-bench over drive images). The picker ->
    Miniplanets -> menu -> Pick ROM -> picker -> Miniplanets again path verified in
    badge-bench (`out/pickflow2/`).
  - Deviations from the contract: FRAG.MD in the fixture is fragmented by
    a post-processing step in `make_fixtures.py` (`--fragment` deals
    clusters round-robin, so two equal files never differ); `Candidate`
    gained `map_err` and `note()`; `live_edge()` masks buttons held over
    from the previous state so the press that skips the splash cannot pick
    a row; the report's `(i of N)` counts listed files, as the picker does.
  - Open after M2: the CRC32 at selection (drop it or spread it over the
    splash) and the fragmented path's cost (test ROM 35.0 ms early updates
    through the cluster table vs 24.2 embedded in Track B's run: measure
    properly in M4, a RAM cache for hot ranges is the M4 answer); H40
    column-pair averaging (SPEC 6) not offered; M3's `Keyframe` restore
    must call `video.apply` (the `Vdp` carries `line_mode`); `romsrc`
    `title_name` inlines `parse_header` (about 1 KB); the debug overlay is
    on by default until the hardware numbers are in; the two track
    worktrees' `sycl-badge` submodules were empty (`git submodule
    update --init --reference` from the main checkout's module store fixed
    them). Hardware check (open, not a gate): XIP launch, drive streaming
    stall rates contiguous and fragmented, the picker on a real drive.
- 2026-09-30 (M3 feasibility, no code): record sizes for the delta
  keyframes measured with temporary write probes (SPEC 10.1): 8-10 KB
  per 30-frame record in Miniplanets play, 89 KB at a level load, about
  110 KB of RAM for the ring, so about 6 s of history in play. Found
  that the third Start in the Miniplanets scripts pauses the game: the
  M1/M2 Miniplanets perf numbers are for a paused game; M3's first step
  is to fix `golden_mini.pad_at`, `m1_mini300.json`, `m2_mini300.json`,
  re-record `golden-mini` and re-bench. Adrian: M3 starts after Snouty
  Gear M3 (same design, prior art).
- 2026-09-30 (M3 started, after Snouty Gear M3): branch `genesis/m3` from
  origin/main `2680e2a`; contract above. Step 0: the pausing third Start
  dropped from `golden_mini.pad_at`, `m1_mini300.json`, `m2_mini300.json`.
  Unpaused baseline, `golden-mini:` lines: `frames 0x246F566FF41A43A4, 62
  tone changes 0xE68656F23938261E, state 0x3B9FFCB07C1C9047`; `68000 pc
  00061E sr 2004, z80 pc 0D45`. Tracks A (core, `genesis/m3-core`,
  worktree `/home/exedev/snouty-badge-genesis-core`) and B (frontend,
  `genesis/m3-front`, `/home/exedev/snouty-badge-genesis-front`).
  Unpaused badge-bench baseline (calibrated, `busy ms`, Miniplanets from
  `out/romfs_mini.img`, `m2_mini300.json`, 336 updates incl. 36 splash):
  17.87 mean / 28.10 worst (update 48, boot), 0 over budget; level-1
  play updates about 21.2 ms (paused they were 19.5); game updates
  about 20.0 mean. Hot: `step_frame` 41.6 %, `run_z80` 28.8 %, plane
  render 9.6 %, `write16` 1.7 % (1734 calls per update).
- 2026-09-30 (M3 DONE): tag `snouty-genesis/m3`. Track A (3 commits:
  `core/undo.zig`, `Md.Small`/`render_still`, hooks; `undo_unit`;
  `determinism` + `scrub_sizing`) merged, Track B's five frontend commits
  cherry-picked over its stub commit (rewind/tuning, menu scrub UI,
  main.zig wiring + exports, `m3_scrub.json`, RUNNING.md). Integration:
  `tuning.wasm_arena_bytes` 101 KB (the badge arena: 307,968 - 32 KB
  stack - 168 `.data` - 170,068 `.bss` - 1 KB guard = 103,940 B, 1528
  slots), `docs/m3_scrub.gif`, RUNNING.md's sequence marked verified.
  - Host tests 157/157 (143 + 11 `undo_unit`, 2 `determinism` (test ROM
    and Miniplanets: every Left matches its full keyframe, Right returns
    to live, tracked == untracked, resume chains), 1 `scrub_sizing`);
    `golden-mini:` lines unchanged from the baseline; `golden` unchanged.
  - Preview (Miniplanets wasm, `m3_scrub.json`, 540 updates): menu at
    frame 556; Lefts park at depth 16 / 46 / 76 / 106, Rights 76 / 46,
    B resumes from 510 (records 8 -> 7, `frame_count` 516 at update 404),
    second visit depth 22 / 52, live again at the end with 11 records,
    350 frames of history, 1517 of 1520 slots (pool-limited).
  - badge-bench (calibrated, `busy ms`, scrubber on from `start`):
    Miniplanets unpaused `m2_mini300` 336 updates 17.99 mean / 28.84 worst
    (baseline 17.87 / 28.10; +0.12 ms mean is the write-path byte test,
    `write16` 46.1K -> 55.0K cycles per update, plus one-off block copies;
    the worst is the boot update 47 copying the Z80 upload), game updates
    20.10 mean, play 21.3; scrub script 540 updates 14.34 / 28.84, 0 over,
    a scrub step update 4.9 ms (`render_still` 128 rows + the swap), menu
    0.9 ms; test ROM `m2_play` 156 updates 6.90 / 25.82 (Track A's baseline on the same
    path 6.82 / 24.21; the worst is update 36, the first game update,
    copying the boot writes). Sizes: `.text` 231,952 B
    (+11.4 KB over M2; 30.2 KB of the flash window left), `.data` 168,
    `.bss` 170,068 (+4.7 KB: 2432 need bytes, `Md.Small` staging 1664 B,
    record table).
  - Sizing (`scrub_sizing`, Miniplanets, slots per 30-frame record, 26 of
    them the 1664 B small state): boot 506-527, title 74-131, menu load
    677, menu 74, level load 1362 (92.6 KB: RAM 411 / VRAM 906 / Z80 19
    blocks), play 123-142 (8.6 KB). A 1528-slot ring holds about 11 play
    records: 5.5 s of history in play (plus up to 0.5 s in the open
    record), 9.5 s on menus, 0.5-1 s right after boot or a level load.
  - Deviations from the contract (defaulted, Adrian may overrule): the
    frontend calls `undo.resume_here` before the first frame after a
    scrub (the truncation cannot live in `record_frame`, which runs after
    the frame); the dirty byte is a "need" byte (nonzero = not yet saved,
    so all-zero `.bss` means tracking off and no `.data` image); the Z80
    bank window's work RAM writes are hooked too (the contract's list
    missed them); `render_still` also restores the sprite cache fields;
    the first Left from live goes to the start of the open record (depth
    = frames since the last boundary, not a fixed 60); auto-repeat is one
    step per 8 updates (3.75/s); the menu suppresses buttons held over
    from the game on open; `m3_scrub.json` is 540 updates; the Reset row
    forgets the history.
  - Open after M3: `not_wait_loop` is a hint outside `Small` (harmless,
    determinism test agrees); the hooks cannot tell two consoles apart
    (only the determinism test steps two); a level load leaves under 1 s
    of history until it rebuilds; H40 column averaging and the CRC32 at
    selection still open (M4 perf). Hardware check (open, not a gate):
    the scrub step's 4.9 ms and the arena size on a real badge.
