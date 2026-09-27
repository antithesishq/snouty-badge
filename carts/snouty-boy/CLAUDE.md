# Snouty Boy

Fifth badge cart for the Software You Can Love (SYCL) conference, built for
Antithesis: a Game Boy (DMG) emulator in Zig with one embedded ROM and a
time scrubber. `SPEC.md` is the design; `PLAN.md` is the current
milestone's file ownership and interface contract. Sibling carts
`../snouty-bugs` and `../snouty-run` hold the toolchain history; their
CLAUDE.md files have the long explanations, this one summarises.

## Layout

- `core/` — the emulator, badge-agnostic. `gb.zig` is the shared state and
  frame loop; one file per subsystem. No `cart-api` import, no floats, no
  allocator, no clock, no randomness (SPEC.md 10.3). Host-testable.
- `cart/src/` — the badge frontend. `main.zig` exports `start()`/`update()`
  and holds the wasm simulator shims; `frontend/` maps video, input, debug
  overlay, later menu/audio/rewind.
- `tests/` — host tests (`zig build test`). `tests/roms/` is gitignored;
  run `tools/fetch_test_roms.sh` first. `tests/acid2_reference.bin` is the
  dmg-acid2 reference as 160x144 shade bytes.
- `roms/` — the shipped game ROM (`*.gb` gitignored except the committed
  `2048.gb`, the build's fallback ROM; its LICENSE sits next to it).
- `tools/` — `fetch_test_roms.sh`, `romcheck.py`. The headless wasm runner
  (`preview.mjs`), `serve-cart.mjs` (serves the wasm on :2468) and
  `make_gif.py` are shared, in `../../tools/`.
- `../../sycl-badge/` — upstream badge repo, read-only SDK, a git submodule
  at the repository root. Path dependency of the root `build.zig.zon`; the
  one `src/os/system/tracy_protocol.zig` symlink is at the root too.

## Target hardware (SYCL Badge V2)

- RP2354B Cortex-M33 at 150 MHz, Core 1 runs the cart from RAM. Cart RAM
  307 KB total incl. 32 KB stack; code + ROM + state all live there.
- Screen 160x128 RGB565, framebuffer column-major `cart.framebuffer[x][y]`,
  `Pixel.from_color(DisplayColor.rgb(0xRRGGBB))`.
- Inputs `cart.controls.*`: start, select, a, b, click, up, down, left,
  right. The OS owns Start+Select (exit) and click; never bind click.
- Audio `cart.tone2(...)`, one voice, each call cancels the previous.
- `read_flash`/`write_flash_page` are stubs on hardware: the ROM is
  embedded at build time (`-Drom=path`, default `tests/roms/dmg-acid2.gb`,
  `roms/2048.gb` when that is not fetched).

## Building

Zig `0.17.0-dev.1936+5a625d5f3` at `~/.local/bin/zig`
(`export PATH="$HOME/.local/bin:$PATH"`). Zig 0.17 spells optimize modes
`.debug/.safe/.fast/.small`. Commands here run from this cart's directory
(`carts/snouty-boy/`) unless noted; only `zig build` runs from the repository
root (`../..`), whose `build.zig` calls this cart's `build.zig` module
(`pub fn add`) and owns the one `build.zig.zon`.

- `zig build -Dcart=snouty-boy` (root) → `zig-out/firmware/snouty-boy.uf2`,
  `.elf`, `zig-out/bin/snouty-boy.wasm` in the root `zig-out/` (from here
  `../../zig-out/...`). Clean build about 2 min; plain `zig build` builds
  every cart (several minutes). `-Dcart-optimize=small|fast` (default fast),
  `-Drom=carts/snouty-boy/roms/x.gb` (or `-Drom=roms/x.gb`, relative to
  this cart). Without `tests/roms/dmg-acid2.gb` the build prints a note and
  embeds `roms/2048.gb`.
- `zig build test` (root) → every cart's host tests, this cart's native core
  tests among them (about 15 s of it). `-Dtest-filter=acid`.
- `size ../../zig-out/firmware/snouty-boy.elf` for the memory budget (SPEC.md 13).
- Headless: `node ../../tools/preview.mjs ../../zig-out/bin/snouty-boy.wasm --frames 60 --every 10 --out out/`
  then look at `out/frame_XXXX.png`. Buttons via `--press A:30-40`.
- `zig fmt core cart tests build.zig` before committing.

## Simulator quirks (upstream `main`)

The wasm platform never presents and the web simulator reads a legacy
framebuffer at 0x20 with red/blue swapped; buttons arrive at 0x04.
`main.zig` has `present_wasm()` and `read_controls()` shims for wasm only.
`micros_since_boot` advances a fixed 1000 per call in wasm, so the overlay
always reads 1000 us / 500 fps in the simulator; only hardware numbers count.

## Conventions

- Zig style follows upstream: snake_case functions, 4-space indent, `zig fmt`.
- Core: fixed arrays, integer math, deterministic. Hot paths avoid function
  pointers except the one `LineSink` call per line.
- Commit messages: short imperative subject, body explains why.
- Milestone hand-off: tag, preview GIF in `docs/`, and a "pull and run this"
  section in the final message (Adrian reviews locally in the simulator and
  flashes the uf2).
