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
