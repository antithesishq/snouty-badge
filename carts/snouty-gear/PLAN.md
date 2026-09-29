# Snouty Gear: plan

SPEC.md is the design. This file is the working contract for the current
milestone: who owns which files, the frozen interfaces, what "done" means.
SPEC.md section 18 was decided 2026-09-29; the ROM is Waternet.

## M0 Scaffold (two Opus tracks in worktrees, then integration)

**Done 2026-09-29**, tag `snouty-gear/m0`; results in Status below.

Started 2026-09-29 on branch `gear/m0`. The skeleton commit already holds:
the `carts` table line in the root `build.zig`, `-Dgg-rom` and
`-Dgg-rom-source=drive|embed|pack` in `build/common.zig`
(`common.RomSource`), a stub `carts/snouty-gear/build.zig`, the shipped ROM
`roms/waternet.gg` (MIT, `roms/LICENSE-waternet`, Waternet v1.0 by Willems
Davy, md5 `44d92c492caa17f298d216b9e272dd3d`, gitignore exception at the
root), a stub `lib/romfs.zig` with the frozen interface below, and
`lib/tests.zig` hung off `zig build test`.

### Frozen for M0: `lib/romfs.zig` (docs/ROM_DRIVE.md section 4)

```zig
pub const base_addr: usize = 0x10080000; // OS linker.ld romfs origin (pinned sycl-badge)
pub const size: usize = 1280 * 1024;
pub const sector_size: usize = 512;
pub const max_clusters: usize = size / sector_size; // sizes the caller's cluster table
pub const Error = error{ NoVolume, BadGeometry, BadChain, TooManyClusters };
pub const Entry = struct { name: [64]u8, name_len: u8, size: u32, first_cluster: u16,
                           pub fn slice(*const Entry) []const u8 };
pub const Volume = struct {
    base: [*]const u8,
    pub fn open(base: [*]const u8) Error!Volume;   // boot sector: 0xAA55, 512 B sectors,
                                                   // "FAT12   ", 1 sector/cluster, 32 root entries
    // Root-directory scan for files whose extension (case-insensitive, no dot)
    // is in `exts`; skips deleted, directory and volume-label entries; the
    // long name when the host wrote one, else the 8.3 name. Returns the count.
    pub fn find(*const Volume, exts: []const []const u8, out: []Entry) usize;
    // Walks the FAT chain into `clusters` (ceil(size / 512) entries needed).
    pub fn map(*const Volume, e: Entry, clusters: []u16) Error!Mapped;
};
pub const Mapped = struct {
    size: u32, clusters: []const u16, data_base: [*]const u8,
    pub fn contiguous(*const Mapped) ?[*]const u8;          // whole file in one run
    pub fn chunk(*const Mapped, offset: u32, len: u32) ?[*]const u8; // one run, inside the file
    pub fn read(*const Mapped, offset: u32) u8;              // per-cluster path
    pub fn crc32(*const Mapped) u32;                         // IEEE, over the whole file
};
```

The reader is `const`-only over a `[*]const u8` base so host tests point it
at an image in memory and the badge points it at `base_addr`. It never
reads beyond the sectors it needs, so truncated test images work. No
allocator, no floats.

### Track A: cart scaffold (files `carts/snouty-gear/**` except `PLAN.md`/`SPEC.md`, `badge-bench/carts/snouty-gear.toml`, root `README.md` row)

- `build.zig` per Snouty Boy's: RAM cart (XIP only when `pack`, which just
  fails with "not built yet" for now), `core` and `rom` modules, the
  embedded ROM from `-Dgg-rom` (default `roms/waternet.gg`, cart-relative
  paths accepted), `-Dcart-optimize`, host tests on `tests/all.zig` with
  `-Dtest-filter`/`-Dtest-optimize`. The wasm build always embeds.
- `core/gg.zig` with the whole `Gg` struct (Z80 registers, 8 KB RAM, VDP
  state incl. 16 KB VRAM and 64 B CRAM, PSG, mapper, counters, cart RAM),
  `init(rom: Rom)`, `reset()` to the post-BIOS state, `step_frame(pad)`, the
  `Keyframe` copy, and the `line_sink` callback (`[160]u5` indices + the
  `*const [32]u16` CRAM). Subsystem files (`z80.zig`, `bus.zig`, `vdp.zig`,
  `psg.zig`, `rom.zig`) compile as stubs with their public shape. The M0
  `step_frame` fills VRAM/CRAM with a moving test pattern through the sink
  so the video path is exercised. `core/rom.zig`: 16 KB bank pointer table
  (`[32]?[*]const u8`, null = go through the romfs per-cluster path),
  built from an embedded slice or a `romfs.Mapped`.
- `cart/src/main.zig` + `frontend/{video,input,debug,romsrc}.zig` copied
  from Snouty Boy and trimmed: video squeezes 144 -> 128 with the CRAM ->
  `Pixel` cache, input maps SPEC.md section 5, debug overlay as is,
  `romsrc.zig` chooses the ROM per `-Dgg-rom-source` (badge only: open the
  volume at `romfs.base_addr`, `find(.{"gg","sms"})`, `map`, CRC; on any
  error or no file, the embedded ROM) and reports name/size/CRC/source.
  The M0 screen shows the test pattern plus one text line with that report.
- `tools/fetch_test_roms.sh` (zexall-sms v0.21 `zexdoc.sms`/`zexall.sms`;
  SingleStepTests Z80 `v1/` by sparse checkout, optional flag since it is
  1.2 GB), `tools/romcheck.py` (GG/SMS header at `7FF0`, region, size,
  mapper heuristics, `FFFC` writes, port `BF` register writes summary),
  `tools/scripts/m0_pattern.json` for `../../tools/preview.mjs`.
- `CLAUDE.md`, `README.md`, `docs/RUNNING.md`, `badge-bench/carts/snouty-gear.toml`
  (600 frames, `budget_ms = 16.7`, a `romfs` line commented until Track B lands).
- Done when `zig build -Dcart=snouty-gear` and `zig build test` pass, the
  headless preview shows the pattern and "ROM: embedded waternet.gg 64 KB",
  `size -A` of the ELF and the uf2 size are recorded in the report.

### Track B: romfs reader and tooling (files `lib/romfs.zig`, `lib/tests.zig`, `lib/tests/**`, `tools/make_romfs.py`, `badge-bench/badge_bench/**`, `badge-bench/README.md`, `docs/ROM_DRIVE.md` status lines)

- `lib/romfs.zig` per the frozen interface, matching
  `sycl-badge/src/os/loader/storage.zig` (the geometry, the LFN layout the
  OS reads, deleted entries `E5`, end of directory `00`, FAT12 12-bit
  packing, chain end `>= 0xFF8`).
- `tools/make_romfs.py OUT.img FILE... [--size 1280K] [--truncate] [--fragment N] [--delete NAME]`:
  writes a FAT12 super-floppy with the OS geometry, long names plus 8.3
  aliases as macOS/Windows write them, optional cluster interleaving to
  fragment files and deleted entries. `--truncate` stops the image at the
  last used sector for committed fixtures.
- Tests in `lib/tests/romfs_unit.zig` (imported from `lib/tests.zig`): a
  fresh image with one file (contiguous, `chunk` on every 16 KB bank),
  fragmented (chunk null where it should be, `read` matches the file),
  long and 8.3 names, deleted entry skipped, several matches, no volume,
  bad geometry, `crc32` against `std.hash.Crc32`. Fixtures are generated
  by `make_romfs.py --truncate` from small pseudo-random files and
  committed under `lib/tests/fixtures/` (under 100 KB total), with the
  command line in a comment; the test also checks `read` byte-for-byte
  against the source bytes (stored in the fixture directory).
- badge-bench: `--romfs IMAGE` maps the image at `0x10080000` (read-only,
  any size up to 1280 KB, zero-padded to a 4 KB multiple),
  `--flash-read-cycles N` (default 0) adds N cycles per data load from that
  range, a `romfs = "path"` key in `carts/<cart>.toml` (relative to the
  repository root), `describe_addr` names the region, README section.
  Keep it that simple (Adrian: further model refinement is academic).
- Done when `zig build test` is green with the real reader, an image with
  `waternet.gg` built by the tool round-trips through the reader in a test,
  and `badge-bench` runs `snouty-boy.elf` unchanged with `--romfs` given
  (proves the mapping does not disturb a cart that ignores it).

### Integration (me)

1. Merge both tracks into `gear/m0`; `zig build` (all carts), every other
   cart's uf2/wasm byte-identical to the baseline hashes taken before M0.
2. `zig build test` green; `make_romfs.py` image with `waternet.gg`,
   badge-bench on `snouty-gear.elf` with `--romfs`: the overlay/report line
   must read the drive ROM (name, CRC) rather than the embedded one.
3. Preview PNG of the pattern in `docs/`; PLAN.md status; tag `snouty-gear/m0`;
   pull-and-run notes for Adrian.

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
- `gg.line_sink` receives each rendered visible line as `[160]u5` palette
  indices (0..31; sprites use 16..31, so a u4 cannot hold them) plus the
  current `*const [32]u16` 12-bit CRAM, so the
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
3. badge-bench on the RAM ELF with a romfs image holding the ROM and
   `tools/scripts/m1_play.json`:
   mean under 8 ms, worst under 12 ms, calibrated. Record the table here.
4. Sizes (`size -A`, fast and small) recorded against SPEC.md section 13.
5. Tag `snouty-gear/m1`; pull-and-run notes. Gate: Adrian flashes and
   reports the overlay numbers.

## Status

- 2026-09-29: SPEC.md and this plan drafted; section 18 decided. Next: M0.
- 2026-09-29: M0 started on branch `gear/m0` (skeleton commit, then tracks
  A and B in worktrees).
- 2026-09-29: M0 done. Track A (cart scaffold, `cdb842e`) and Track B
  (romfs reader, `make_romfs.py`, badge-bench `--romfs`, `073412b`) merged.
  - `zig build` of every cart: the other seven carts' uf2 and wasm are
    byte-identical to the pre-M0 build (097b1ab, same worktree, same SDK pin).
  - `zig build test`: green (65 test steps incl. 8 romfs and 9 gear tests;
    Snouty Boy's tests need `carts/snouty-boy/tools/fetch_test_roms.sh` in
    a fresh checkout, as before).
  - Sizes (RAM cart, fast, drive source, incl. the 64 KB embedded ROM):
    `.text` 105,312, `.data` 220, `.bss` 39,584 (5 KB of it the cluster
    table); uf2 291,840 B, wasm 261,030 B. Code alone is ~40 KB, against
    SPEC.md's ~95 KB estimate for the finished cart.
  - badge-bench, 120 frames, `romfs = carts/snouty-gear/out/romfs.img`
    (Waternet, built by `tools/make_romfs.py`): the cart found and mapped
    `waternet.gg` from the drive image and showed `crc 6BB36DFC` (matches
    zlib); pattern frame 3.30 ms busy, start-up 2.68 ms. `docs/m0_drive_bench.png`.
  - Deviations from the M0 text, all accepted: sink pixels are `[160]u5`
    (indices reach 31); `-Dgg-rom-source=pack` prints a note and builds the
    drive cart instead of failing; `Gg.init_in_place` because the 33 KB
    console must not cross the 32 KB badge stack by value; the report line
    word-wraps over up to four rows.
  - romcheck: Waternet writes `FFFC` (cart RAM unknown, computed value) and
    no line interrupt seen; Sonic GG writes register 10 (line IRQ likely),
    no cart RAM. M1 tracks B and C take note.
  - Open from docs/ROM_DRIVE.md section 3: keep the M3 keyframe ring out of
    `.bss` (the uf2 carries `.bss` zeros) if the uf2 gets too big for the drive.
  Next: M1 (three tracks per the contract above); gate on Adrian's hardware
  run of this M0 uf2 with a `.gg` file on the drive.
- 2026-09-29: M1 started on branch `gear/m1` (prep commit drops the M0
  stub-shape test; tracks A/B/C in worktrees `-z80`, `-vdp`, `-machine`).
- 2026-09-29: M1 core done on `gear/m1`. Tracks A (`566e510`.. Z80),
  B (`41fa714` VDP) and C (`fd9c1f1` machine, frontend, tests) merged with
  a one-line integration fix (`@setEvalBranchQuota` in the Z80 switch: the
  real inline bus pushed analysis past Zig's default quota).
  - Z80: SingleStepTests 1604/1604 files, 1,604,000 cases, 0 failures
    (streamed by `fetch_test_roms.sh --single-step-all`, 4 min 41 s wall);
    ZEXDOC and ZEXALL 79/79 OK each (8.3 s and 9.5 s under `safe`); 11
    interrupt/HALT/EI unit tests. `zig build test` keeps a 36-file subset
    (0.5 s) and both ZEX ROMs (ZEXALL skipped in Debug builds).
  - VDP: 25 unit tests through the ports (latch, buffer, CRAM pairs,
    status, frame and line IRQ timing, counters, scroll and locks, flips,
    priority, sprite limit/overflow/collision, 8x16, zoom, shift-left).
  - Machine: 14 bus, 6 PSG, 2 smoke, 1 golden test; golden pins Waternet
    frames 120/180/360/570 from the reviewed run (`docs/m1_waternet.gif`).
  - `zig build test`: 9/9 steps, 67/67 tests, 40 s wall (safe).
  - Waternet plays start to finish in the simulator (title, menus, grid,
    quit prompt). Sonic the Hedgehog GG (256 KB, local) runs through the
    SEGA logo, title, map and Green Hill Zone (`docs/m1_sonic_ghz.png`);
    its line-IRQ counter stays 0 in the frame-IRQ heuristic, unverified.
  - Sizes, RAM cart, drive source, incl. the 64 KB embedded ROM: fast
    `.text` 172,388 / `.data` 220 / `.bss` 39,608 (uf2 427,008 B);
    small `.text` 130,532 (uf2 342,528 B). Code alone ~108 KB fast /
    ~66 KB small against SPEC.md 13's ~95 KB; the 256-way Z80 switch with
    the inline bus is the growth. RAM in use fast: 212 KB + 32 KB stack
    of 307 KB, leaving ~63 KB for the M3 keyframe ring: watch it.
  - badge-bench (calibrated, RAM ELF, ROM from a romfs image), before the
    perf pass:

    | Run | frames | mean busy | p95 | worst | over 16.7 |
    |---|---|---|---|---|---|
    | Waternet, `m1_play` | 600 | 9.57 ms | 11.52 | 12.09 (frame 92) | 0 |
    | Sonic GG from the drive | 1200 | 9.87 ms | 12.54 | 12.55 (frame 237) | 0 |

    Start-up 2.68 ms (Waternet) / 10.15 ms (Sonic: CRC of 256 KB). Hot:
    `_start` (inlined step_frame/tick/bus) 63%, `api.text` 12.8% (1.2 ms:
    overlay + report line), `video.on_line` 7.3%, Z80 decoders ~12%.
    Against the M1 targets (mean < 8, worst < 12) both runs are just over;
    a perf pass follows on `gear/m1-perf` (numbers appended below).
  - Deviations accepted: `render_line(line, x0, out)` takes the VDP line
    and first column; `Mapper.bank` caches wrapped slots; IRQ counters
    live in `Gg` (IFF1 edge + PC 0038 heuristic); `frame_t` is the last
    frame's T-states, diagnostic only; port C0-FF fully decoded (only
    C0/DC pad, C1/DD FF); golden reads the ROM and script at run time.
