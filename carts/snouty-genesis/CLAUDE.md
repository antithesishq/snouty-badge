# Snouty Genesis

Eighth badge cart for the Software You Can Love (SYCL) conference, built
for Antithesis: a Sega Genesis emulator in Zig, and the third emulator
after `../snouty-boy` and `../snouty-gear`, which it copies wherever it
can (their CLAUDE.md and docs have the longer explanations). The badge
build reads its ROM from a `.gen`/`.md`/`.bin` file on the badge's USB
drive in place (docs/ROM_DRIVE.md at the repository root, `docs/ROM_STREAMING.md`
here) and embeds no ROM (none on the drive: the no-ROM screen,
`frontend/help.zig`); the simulator always embeds.
`SPEC.md` is the design; `PLAN.md` is the current milestone's file
ownership and interface contract.

## Layout

- `core/` — the emulator, badge-agnostic. `md.zig` is the whole console
  (`Md`), `step_frame(pad, render)`, `tone()`, `Keyframe` +
  `snapshot`/`restore`, the `line_sink`; one file per subsystem
  (`m68k.zig` generic over the bus, `bus.zig` the 68000 map, `z80bus.zig`
  the Z80 map, `vdp.zig`, `ym2612.zig`, `psg.zig`, `rom.zig` with
  `RomSource`, `tunables.zig` the performance knobs). No `cart-api` import,
  no floats, no allocator, no clock, no randomness, no romfs: the core sees
  the ROM only as `rom.RomSource`, a base pointer or a cluster table.
  Host-testable. `step_frame` runs the 262-line frame loop of PLAN.md's
  M1 contract (68000 share, Z80 slice, YM timers, `end_line`).
- The Z80 is Snouty Gear's `carts/snouty-gear/core/z80.zig`, imported as
  the module **`z80`** (`@import("z80")` in `core/z80bus.zig`), rooted at
  that file by this cart's `build.zig` for both the cart and the host
  tests. Never copy it: a fix goes into Gear's file with Gear's tests still
  green. It imports only its sibling `tables.zig`, which a module rooted
  there can see.
- `cart/src/` — the badge frontend. `main.zig` exports `start()`/`update()`
  (60/30: `tunables.render_every` frames per update, the last rendered)
  and holds the wasm simulator shims; `frontend/` has video (tagged index
  -> `Pixel` cache with shadow/highlight), input (pad word, Select tap = A,
  Select hold = menu), audio (the RAM cart: `core/sound.zig`'s samples
  through `audio_feed` into the new firmware's ring, never `tone2`; the
  XIP cart: `Md.tone()` -> `tone2` on change; the wasm build drives the
  simulator's `tone` import itself, see the file), debug
  (overlay), text (fast font), romsrc (drive or embedded ROM, the report
  line), picker, help (the no-ROM screen).
- `tests/` — host tests, entry `tests/all.zig`. `tests/roms/` is
  gitignored; Track R's `tools/fetch_test_roms.sh` fills it.
- `roms/` — Track R's shipped test ROM `snouty-test.bin` and its licence.
  `*.gen`/`*.smd` are gitignored at the root, `.bin`/`.md` by path here.
- `tools/` — Track R: `fetch_test_roms.sh`, `romcheck.py`, `testrom/`.
  Shared tools (`preview.mjs`, `serve-cart.mjs`, `make_gif.py`,
  `make_romfs.py`) are in `../../tools/`.
- `../../lib/romfs.zig` — the FAT12 drive reader, imported as `romfs`.

## Target hardware (SYCL Badge V2)

- RP2354B Cortex-M33 at 150 MHz, Core 1 runs the cart. Two carts (M5): the
  **RAM cart** `snouty-genesis` (no Z80, no scrubber; code, data and state
  in the 307 KB RAM window, 32 KB of it stack) and the **XIP cart**
  `snouty-genesis-xip`, everything: code and read-only data (the
  embedded ROM too in an embed build) in the 256 KB cart flash window,
  `.data`/`.bss` in the RAM window. Both read the drive ROM by pointer from the XIP flash window
  (romfs at `0x10080000`, 1280 KB).
- Screen 160x128 RGB565, column-major `cart.framebuffer[x][y]`. The core
  emits badge rows directly: 160 tagged pixels per row, 128 rows (the line
  and column tables of SPEC.md section 6 live in the VDP).
- Inputs `cart.controls.*`; the OS owns Start+Select (exit) and click.
  Mapping (SPEC.md section 5): d-pad, badge B = B, badge A = C, Start;
  Select tap = A (4 Genesis frames on release); Select hold 500 ms =
  emulator menu (M2). Neopixels are never written (root docs/NEOPIXELS.md).

## Building

Zig `0.17.0-dev.1936+5a625d5f3` at `~/.local/bin/zig`
(`export PATH="$HOME/.local/bin:$PATH"`); optimize modes are spelled
`.debug/.safe/.fast/.small`. `zig build` runs from the repository root
only (it calls this cart's `build.zig` `pub fn add`).

- `zig build -Dcart=snouty-genesis` (`-Dcart-mode=ram`, the default, or
  `both`) → `zig-out/firmware/snouty-genesis.uf2`/`.elf` (RAM cart) and
  `snouty-genesis-xip.uf2`/`.elf` (XIP cart), `zig-out/bin/snouty-genesis.wasm`
  (built from the XIP cart's modules: Z80 and scrubber). `-Dcart-mode=xip`
  builds the XIP cart and the wasm only. The variants differ only through
  `build_options` (`z80`, `scrub`, `synth`, `sound`; the core imports it too:
  `tunables.z80_enabled`, `undo.enabled`, `sound.enabled` = the RAM
  cart's FM + PSG synthesis, `tunables.fm_rate_div` its FM rate) and module optimize modes (RAM
  cart: `app`, `drive`, `romfs`, `rom`, `iris`, `hint` and cart-api
  ReleaseSmall; `core` and `video` ReleaseFast), plus the RAM cart's
  trimmed test ROM in embed builds (`tools/trim_rom.zig`). Keep the RAM
  ELF's `__bss_end__` under `__stack_limit__` (`arm-none-eabi-nm`): 4 KB to
  spare until the sound took most of it (PLAN.md "Sound on the new
  firmware"; the update's sample buffer lives on the stack in
  `run_update`).
- Module layout: `cart/src/main.zig` (root: exports, wasm shims) imports
  `app` (`cart/src/frontend/app.zig`: the state machine, rooted in
  `frontend/`, so every frontend file but `video.zig` and `drive.zig`
  belongs to it) and `video` (the line sink, its own module so it stays
  ReleaseFast). Frontend files import the line sink as `@import("video")`,
  never by path.
- `-Dmd-rom=path` picks the embedded ROM (repo-relative, cart-relative
  `roms/x.bin`, absolute or `~/x.bin`); default `roms/snouty-test.bin`
  (16 KB, built from `tools/testrom/`). `-Dmd-rom-source=drive|embed`
  (default `drive`); `-Dcart-optimize=fast|small|safe|debug`. A drive
  build (both badge carts) links no embedded ROM: `romsrc.embedded` is a
  compile error there and nothing else it analyzes reads `rom.data`, so
  `@embedFile` emits nothing (the wasm, built from the same modules but
  never `use_drive`, keeps it). Keep it that way: every KB of cart image
  costs 2 KB of drive space.
- The generated `rom` module (cart and host tests) has `data` (the
  embedded ROM), `name` (its file name) and `source` (`.drive` or
  `.embed`). The RAM cart's (embed builds) has the default test ROM
  without its zero padding (3 KB, `tools/trim_rom.zig`).
- **Configure cache rule**: this Zig caches the configure phase's build
  graph keyed by the build files and the options. A graph decision taken
  from anything else (a file's existence, an environment variable) is
  frozen at the first configure and silently reused; M0 lost an hour to a
  placeholder ROM chosen that way. Decide from options only.
- `zig build test-genesis -Dcart=snouty-genesis` → this
  cart's host tests only (`snouty-genesis-tests` for the full core,
  `snouty-genesis-ram-tests` for the RAM cart's, `tests/ram_variant.zig`); `zig build test` → every built cart's (plus
  lib/). `-Dtest-filter=smoke` (names carry an area prefix: `smoke:`,
  `md:`, `rom:`), `-Dtest-optimize=`.
- `size -A zig-out/firmware/snouty-genesis.elf` and `-xip.elf` against
  SPEC.md section 13.
- Headless: `node tools/preview.mjs zig-out/bin/snouty-genesis.wasm --frames 60 --every 30 --out carts/snouty-genesis/out/`
  (from the root), then look at the PNGs.
- `zig fmt carts/snouty-genesis` before committing.

## Rules

- Adrian builds on a Mac where heavy comptime makes Zig run out of memory:
  no big comptime loops over arrays, no comptime reinterpretation of
  embedded bytes. Tables come from host generators (`tools/gen_m68k.py` in
  M1) or literal data; small maps are built at runtime.
- The console is ~137 KB: keep it a static and use `Md.init_in_place`;
  never return one by value (32 KB stack on the badge, 14.7 KB in wasm).
  Reset big arrays with `@memset`, never `x.* = .{}` on a struct holding
  them: that puts the whole default image in flash and copies it (M0 found
  a 64 KB `Vdp` default in `.text` that way).
- Core: fixed arrays, integer math, deterministic. Hot paths avoid function
  pointers except the one `LineSink` call per rendered row.
- Simulator quirks (upstream `main`): the wasm platform never presents and
  the simulator reads a legacy framebuffer at 0x20 with red/blue swapped;
  buttons arrive at 0x04. `main.zig` has `present_wasm()`/`read_controls()`
  for wasm only. `micros_since_boot` adds 1000 per call in wasm, so the
  overlay always reads 1000 us there.
- Commit messages: `snouty-genesis: ` prefix, short imperative subject,
  body explains why.
- Milestone hand-off: tag, preview in `docs/`, a "pull and run this"
  section in the final message (Adrian reviews in the simulator and flashes).
