# Snouty Genesis

Eighth badge cart for the Software You Can Love (SYCL) conference, built
for Antithesis: a Sega Genesis emulator in Zig, and the third emulator
after `../snouty-boy` and `../snouty-gear`, which it copies wherever it
can (their CLAUDE.md and docs have the longer explanations). The badge
build reads its ROM from a `.gen`/`.md`/`.bin` file on the badge's USB
drive in place (docs/ROM_DRIVE.md at the repository root, `docs/ROM_STREAMING.md`
here) and falls back to the embedded ROM; the simulator always embeds.
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
  Host-testable. M0: every subsystem is a compiling stub with the PLAN.md
  M1 signatures; `step_frame` draws a test pattern.
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
  Select hold = menu), audio (`Md.tone()` -> `tone2` on change), debug
  (overlay), text (fast font), romsrc (drive or embedded ROM, the report
  line).
- `tests/` — host tests, entry `tests/all.zig`. `tests/roms/` is
  gitignored; Track R's `tools/fetch_test_roms.sh` fills it.
- `roms/` — Track R's shipped test ROM `snouty-test.bin` and its licence.
  `*.gen`/`*.smd` are gitignored at the root, `.bin`/`.md` by path here.
- `tools/` — Track R: `fetch_test_roms.sh`, `romcheck.py`, `testrom/`.
  Shared tools (`preview.mjs`, `serve-cart.mjs`, `make_gif.py`,
  `make_romfs.py`) are in `../../tools/`.
- `../../lib/romfs.zig` — the FAT12 drive reader, imported as `romfs`.

## Target hardware (SYCL Badge V2)

- RP2354B Cortex-M33 at 150 MHz, Core 1 runs the cart. **XIP cart only**:
  code and read-only data (the embedded ROM too) in the 256 KB cart flash
  window, `.data`/`.bss` in the 307 KB RAM window (32 KB stack). The drive
  ROM is read by pointer from the XIP flash window (romfs at `0x10080000`,
  1280 KB).
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

- `zig build -Dcart=snouty-genesis -Dcart-mode=xip` →
  `zig-out/firmware/snouty-genesis-xip.uf2`, `.elf`,
  `zig-out/bin/snouty-genesis.wasm`. Without `-Dcart-mode=xip` a build
  that names only this cart stops at configure time with a message
  (SPEC.md section 13); `both` builds the XIP cart only; an all-carts
  `zig build` or a `-Dcart` list with other carts builds it as XIP
  regardless of `-Dcart-mode`.
- `-Dmd-rom=path` picks the embedded ROM (repo-relative, cart-relative
  `roms/x.bin`, absolute or `~/x.bin`); default `roms/snouty-test.bin`
  (16 KB, built from `tools/testrom/`). `-Dmd-rom-source=drive|embed`
  (default `drive`); `-Dcart-optimize=fast|small|safe|debug`.
- The generated `rom` module (cart and host tests) has `data` (the
  embedded ROM), `name` (its file name) and `source` (`.drive` or
  `.embed`).
- **Configure cache rule**: this Zig caches the configure phase's build
  graph keyed by the build files and the options. A graph decision taken
  from anything else (a file's existence, an environment variable) is
  frozen at the first configure and silently reused; M0 lost an hour to a
  placeholder ROM chosen that way. Decide from options only.
- `zig build test-genesis -Dcart=snouty-genesis -Dcart-mode=xip` → this
  cart's host tests only; `zig build test` → every built cart's (plus
  lib/). `-Dtest-filter=smoke` (names carry an area prefix: `smoke:`,
  `md:`, `rom:`), `-Dtest-optimize=`.
- `size -A zig-out/firmware/snouty-genesis-xip.elf` against SPEC.md section 13.
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
