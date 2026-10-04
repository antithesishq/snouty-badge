# Snouty Boy

Fifth badge cart for the Software You Can Love (SYCL) conference, built for
Antithesis: a Game Boy (DMG) and Game Boy Color (CGB, SPEC.md 19) emulator
in Zig that runs a `.gb`/`.gbc` file from the badge drive (embedded ROM as
fallback) with a time scrubber. `SPEC.md` is the design; `PLAN.md` is the
current milestone's file ownership and interface contract. Sibling carts
`../snouty-bugs` and `../snouty-run` hold the toolchain history; their
CLAUDE.md files have the long explanations, this one summarises.

## Layout

- `core/` — the emulator, badge-agnostic. `gb.zig` is the shared state and
  frame loop; one file per subsystem. No `cart-api` import, no floats, no
  allocator, no clock, no randomness (SPEC.md 10.3). Host-testable.
- `core/kstore.zig` — the keyframe page store (SPEC.md 19.3): state regions
  (`Gb.state_regions`) cut into pages, shared with the previous keyframe
  when equal, a shared zero page, refcounted pool, oldest-first eviction.
  `core/ring.zig` is the scrubber's frame/age bookkeeping on top of it.
- `cart/src/` — the badge frontend. `main.zig` exports `start()`/`update()`
  and holds the wasm simulator shims; `frontend/` has video (DMG shade LUT,
  CGB palette-RAM LUT rebuilt on `gb.pal_dirty`), input, debug overlay,
  menu, splash, audio, rewind (the run-time arena: console, cart RAM, page
  store), the ROM source (`romsrc.zig`) and the ROM picker (`picker.zig`).
  `flow.zig` (screen flow: splash, pick, running, menu, halted) and
  `input.zig` have no cart-api import and run in the host tests
  (`tests/flow_unit.zig`): every transition suppresses held buttons and
  every screen but the game reads `input.State.live_edge()`.
- `tests/` — host tests (`zig build test`). `tests/roms/` is gitignored;
  run `tools/fetch_test_roms.sh` first. Only `tests/*.zig` run: a `test`
  block inside `core/*.zig` is never built (the test root is `tests/all.zig`
  and `_ = core` does not pull them in), so put core tests in `tests/`. `tests/acid2_reference.bin` is the
  dmg-acid2 reference as 160x144 shade bytes.
- `roms/` — the committed ROMs, each with its LICENSE next to it: `2048.gb`
  (the build's fallback ROM), `rex-runner.gb` and `rebound.gbc` (the Color
  ROMs, M7); other `*.gb` are gitignored.
- `tools/` — `fetch_test_roms.sh`, `romcheck.py`. The headless wasm runner
  (`preview.mjs`), `serve-cart.mjs` (serves the wasm on :2468) and
  `make_gif.py` are shared, in `../../tools/`.
- `../../sycl-badge/` — upstream badge repo, read-only SDK, a git submodule
  at the repository root. Path dependency of the root `build.zig.zon`; the
  one `src/os/system/tracy_protocol.zig` symlink is at the root too.

## Target hardware (SYCL Badge V2)

- RP2354B Cortex-M33 at 150 MHz, Core 1 runs the cart from RAM. Cart RAM
  window 0x4AF00 bytes (300 KiB) incl. a 32 KB stack; in the RAM cart code,
  the embedded ROM and state live there (a drive ROM stays in flash), in the
  XIP cart (`-Dcart-mode=xip`) code and the embedded ROM run from the 256 KB
  flash window and all of the RAM is state.
- Screen 160x128 RGB565, framebuffer column-major `cart.framebuffer[x][y]`,
  `Pixel.from_color(DisplayColor.rgb(0xRRGGBB))`.
- Inputs `cart.controls.*`: start, select, a, b, click, up, down, left,
  right. The OS owns Start+Select (exit) and click; never bind click.
- Audio: the core renders four channels at 44.1 kHz (`core/apu.zig`
  "Sample generation", gated by `Gb.audio_render`) and the badge build
  streams them through `../../lib/audio_feed.zig` to the newer firmware's
  ring (SPEC.md 9). The badge build never calls `cart.tone2` or the `tone`
  import (on the new firmware those clobber the ring words). The wasm
  build keeps one voice through the simulator's `tone` import
  (upstream's shim breaks infinite tones; `frontend/audio.zig` explains).
- `read_flash`/`write_flash_page` are stubs on hardware, so the ROM is read
  by pointer: `cart/src/frontend/romsrc.zig` finds `.gb`/`.gbc` files on the
  badge drive (the OS `romfs` FAT12 region at 0x10080000) through the shared
  reader `../../lib/romfs.zig` and builds `core.Rom` from one flash pointer
  per 512-byte sector (SPEC.md 11.1, `docs/ROM_DRIVE.md` at the root). No
  file, no volume, or a mapping error: the embedded fallback ROM
  (`-Drom=path`, default `tests/roms/dmg-acid2.gb`, `roms/2048.gb` when that
  is not fetched). `-Drom-source=embed` and the wasm build use only the
  embedded ROM. The header picks the model (`core.default_model`).
- Arena (`frontend/rewind.zig` `layout`): not `.bss`; once the ROM is
  chosen, the RAM from `__bss_end__` to `__stack_limit__` minus 1 KB (wasm:
  a static 256 KB array) holds the live `Gb` (50 KB), its cart RAM (0 to
  32 KB) and the page store (pool, tables, free list, refcounts), keyframes
  at most `tuning.max_keyframes` (64). Everything there is written before
  it is read, so the OS not zeroing it is fine; keep anything that must
  start zeroed in `.bss`. Too small an arena: the `halted` screen.

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
- `size -A ../../zig-out/firmware/snouty-boy.elf` for the memory budget
  (SPEC.md 13, 19.4); the arena is `__stack_limit__ - __bss_end__ - 1 KB`
  (`nm`). `-Drom-source=drive|embed` (default drive) picks the badge's ROM
  source; `-Dcart-mode=xip|both` adds `snouty-boy-xip.elf`/`.uf2`, needed
  for an embedded ROM above about 64 KB (rebound.gbc, 128 KB: a RAM build
  links but the arena is too small and the cart shows the halted screen).
  Sizes (fast, PLAN.md M8 status): default drive build text 115 KB / bss
  18 KB / arena 136 KB; Rebound XIP arena 262 KB. Knobs:
  `cart/src/frontend/tuning.zig`.
- Headless: `node ../../tools/preview.mjs ../../zig-out/bin/snouty-boy.wasm --frames 60 --every 10 --out out/`
  then look at `out/frame_XXXX.png`. Buttons via `--press A:30-40`.
- Keyframe sizes per ROM: `tests/determinism.zig` prints a `kstore ...`
  line per ROM; `zig build test` hides it, so run the newest
  `../../.zig-cache/o/*/test` binary from this directory.
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
