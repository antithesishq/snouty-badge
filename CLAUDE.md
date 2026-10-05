# Snouty carts (repository notes)

One repository for Antithesis's SYCL Badge V2 carts and the tools around them.
This file holds what every cart shares: the hardware, the cart API, how the
build is wired, and the working conventions. Each `carts/<cart>/CLAUDE.md`
adds that cart's specifics (its modules, asset tables, gates). Read `PLAN.md`
at the root for the repository plan and each cart's `PLAN.md` / `SPEC.md` for
its design and milestone status.

## Layout

- `carts/<cart>/` — one directory per cart: `cart/src/main.zig` exports
  `start()` and `update()`; `cart/build/convert_gfx.zig` and
  `cart/src/packed_int_array.zig` are per-cart copies of upstream's asset
  converter (do not import across carts); `assets/gen/` are committed build
  inputs; `tools/` has `prepare_assets.py`, input `scripts/` and the cart's
  own checks (the generic tools are in the root `tools/`); `docs/RUNNING.md`, `PLAN.md`,
  `SPEC.md`, `ASSETS.md`. `build.zig` is a module with `pub fn add(...)`
  called by the root build.zig. Carts: `snouty-run` (binary `snouty`),
  `snouty-bugs`, `snoutenstein`, `snouty-reflections`, `snouty-boy`,
  `snouty-maze`, `snouty-gear`, `snouty-genesis`, `snouty-lynx`,
  `snouty-flyover`, `demosnout`, `snouty-zero` (XIP only), `snouty-pipes`, `siwoo` (a name
  badge: demosnout's head plus a chrome name), `snouty-link` (the link-cable
  test; `lib/link.zig` is the badge-to-badge link, docs/LINK.md), `snouty-gc` (a
  combat racer forked from snouty-zero's engine), `snouty-cycles` (Tron light
  cycles against AI programs),
  `paperclips` (a port of Universal Paperclips, with the authors'
  permission), `raspberry-trail` (The Raspberry Trail: a faithful port of
  the 1978 MECC BASIC listing of the wagon-trail game), `snouty-sense` (the
  time-of-flight probe: a TMF8820 on the Qwiic port; `lib/tof.zig` is the
  driver, docs/TOF.md), `snouty-theremin` (a theremin played by hand over
  the sensor, or the stick; docs/TOF.md M1), `snouty-morph` (a demoscene
  mesh that follows and deforms with your hand over the same sensor;
  `lib/tof_pose.zig` is the hand pose from its 3x3 zones, docs/TOF.md M3).
- `build.zig`, `build.zig.zon`, `build/common.zig` — the one Zig package.
  Shared options (`-Dcart`, `-Dcart-mode`, `-Ddebug_overlay`, `-Dsound`, `-Drom`, ...)
  and the shared `test` and `check-float` steps are declared here and passed
  to each cart. `build/os_cart.zig` builds a cart in RAM mode (upstream's
  `add_os_cart`) or XIP mode (`build/xip/entry.zig` as root, `cart_xip.ld`,
  artifact `<binary>-xip`); `-Dcart-mode=ram|xip|both`.
- `tools/` — the shared cart tools: `preview.mjs` (headless wasm runner: PNG
  frames, `frames.json`, input scripts, export checks), `serve-cart.mjs` (wasm
  server for the simulator, picks the cart from the cwd), `make_gif.py`,
  `check_float.mjs`, `uf2_info.py`. Cart docs call them as `../../tools/x`.
- `sycl-badge/` — upstream SDK as a git submodule, pinned. Read-only; do not
  patch it. `src/os/system/tracy_protocol.zig` at the root is a symlink into
  it that `add_os_cart` needs.
- `badge-bench/` — emulated cycle benchmark (`bench.sh <elf>`); its own
  `carts/<binary>.toml` files hold per-cart defaults (a different `carts/`).
  `badge-bench/calibrate/` is a cart too (`-Dcart=badge-calibrate`): the
  hardware calibration kernels and `fit.py`; see its SPEC.md and PLAN.md.
- `snouty-art/` — code-driven sprite pipeline; `tools/install_badge.py` and
  `tools/build_maze.py` write into the carts' `assets/`.
- Zig `0.17.0-dev.1936+5a625d5f3` at `~/.local/bin/zig`
  (`export PATH="$HOME/.local/bin:$PATH"`). Node 22 and Python 3 are installed.

## Target hardware (SYCL Badge V2)

- MCU: RP2354B. Core 0 runs the OS kernel, Core 1 runs the cart.
- Screen: 160x128, RGB565 (`DisplayColor` is packed r:u5 g:u6 b:u5; use
  `DisplayColor.rgb(0xRRGGBB)`).
- Framebuffer is column-major: `cart.framebuffer[x][y]`, type `Pixel`, write with
  `Pixel.from_color(color)` (handles wasm vs hardware byte order).
- Inputs: `cart.controls.*` (start, select, a, b, click, up, down, left, right).
  The OS owns Start+Select (exit to menu) and joystick click (FPS overlay);
  never bind click. Newer upstream OS firmware opens a settings box on
  Start+Select and keeps the cart running behind it, so a cart should react
  to neither button while both are held (demosnout's `update` does this).
- 5 neopixels (`cart.neopixels`, GRB): off for every cart. No cart writes a
  non-zero value to `cart.neopixels` (a coworker's badge shows the LEDs are
  unusably bright even at 1%, 2026-09-29; `docs/NEOPIXELS.md`), and
  badge-bench warns (`neopixels written: ...`) if a run does.
  `-Dneopixels=true` exists only for the dormant LED code in snoutenstein,
  snouty-maze and snouty-boy; other carts have no LED code and do not take it.
  Also one user LED, light sensor, battery level, speaker (`tone2`, one
  voice, each call cancels the previous).
- Speaker: every cart boots silent and has a runtime sound toggle (a menu
  row or a button). A cart's sound flag is initialised from
  `build_options.sound` (`-Dsound=true` builds a sound-on set) and only
  that toggle changes it; the OS keeps no volume setting across cart
  starts (`docs/SOUND.md`). The show badges' newer firmware ignores `tone2`
  and its IPC words are now the streaming-audio ring: badge builds never
  call `cart.tone2`; use `lib/tone_stream.zig` (effects) or
  `lib/audio_feed.zig` (emulators), docs/SOUND.md sections 7 and 8
  (snouty-lynx has its own feed in `frontend/audio.zig`).
- Flash: 8000 pages of 256 bytes available via the cart API (`Zone`).
- Cart RAM window 307 KB (`0x20035100..0x20080000`, 32 KB of it stack). A RAM
  cart holds code, read-only data and state there; keep `size -A` of `.text`
  + `.data` + `.bss` well under it. An XIP cart (`-Dcart-mode=xip`) runs code
  and read-only data from the 256 KB cart flash window instead and keeps the
  whole RAM window for `.data`/`.bss`; the route for carts whose ROM plus
  state exceeds ~250 KB.

## Cart API (from `sycl-badge/src/os/cart/api.zig`)

Import as `@import("cart-api")`. Every cart must contain
`comptime { cart.export_start_code(); }`. Key calls:

- Frame pacing: `set_vsync_enabled(1000.0 / 60.0)`, `set_vsync_disabled()`,
  `set_vsync_dynamic()`. `present()` is called automatically after `update()`.
- Double buffering: `set_double_buffer_mode(.copy_forward | .no_copy_dirty_rect |
  .no_copy_full_frame | .{ .clear_full_frame = color })`. Full-screen carts use
  `.no_copy_full_frame` and redraw everything each frame.
- Drawing: `blit(BlitOptions)` (no transparency: skip a key color manually or
  write pixels directly), `rect`, `oval`, `line`, `hline`, `vline`, `text`
  (8x8 font). `mark_dirty_rect` if you write the framebuffer directly and use
  dirty-rect modes.
- `rand()`, `micros_since_boot()`, `trace()` for debug output.

Reference carts: `sycl-badge/showcase/carts/dvd` (simplest asset pipeline),
`zeroman` (atlases with palettes + transparency), `plasma`/`lcd-text` (minimal).

## Building

```
zig build                      # every cart, from the repository root
zig build -Dcart=snouty-maze   # one cart
zig build test                 # every cart's host tests and lib/'s
zig build check-float          # soft-float check (reflections, maze, flyover, demosnout, zero, gc, morph)
```

Outputs `zig-out/firmware/<binary>.uf2`, `.elf` and `zig-out/bin/<binary>.wasm`
at the root. `add_os_cart` (upstream `build.zig`) builds the thumb firmware and
the wasm from the same module; a cart's `custom_builder` adds its `gfx` or
other modules. `build.zig.zon` mirrors upstream's `microzig` and `zigimg`
entries because the converters call `b.dependency("zigimg")` on this builder.
Packages land in `zig-pkg/` (gitignored). Never commit generated `gfx.zig`;
do commit `assets/gen/*.png`.

Adrian builds on an Apple-silicon Mac with the same Zig, where heavy comptime
(big comptime loops over arrays, comptime reinterpretation of const bytes)
fails inside the compiler with `error: OutOfMemory`. Put data through
build-time host programs (like `convert_gfx`) or committed generated files
and keep comptime light.

## Simulator and headless preview

Upstream's wasm platform never presents a frame; the web simulator reads a
legacy framebuffer at 0x20 with red and blue swapped and writes buttons to
0x04, which the API no longer reads. Every cart's `main.zig` has wasm-only
`present_wasm()` and `read_controls()` shims for this. From a cart
directory: `node ../../tools/serve-cart.mjs` (serves that cart's wasm on
:2468) plus `npm run dev` in `sycl-badge/simulator`; headless `node
../../tools/preview.mjs ../../zig-out/bin/<binary>.wasm ...` and
`../../tools/make_gif.py`. Details and
per-cart options in `docs/RUNNING.md` at the root and in each cart.

## Performance

Tune against `badge-bench/bench.sh zig-out/firmware/<binary>.elf --symbols`
before and after a milestone and record the numbers in the cart's PLAN.md
status. Since 2026-09-29 the model is calibrated against a badge by default
(`badge-bench/calibrate/calibration.toml`: fitted class costs, an FP
result-latency stall, LCD-DMA contention; use the `busy ms` column);
`--no-calibrate` gives the old raw floor. Unmeasured still: VFMA, LDRD/STRD,
framebuffer halfword access. Expose knobs as adjustable constants in one
place and leave headroom. Budget is 16.7 ms per `update()` for 60 fps carts.

## Conventions

- Zig style follows upstream: snake_case functions, 4-space indent, `zig fmt`.
- Per-frame work stays cheap: no allocation, no float-heavy loops over the
  whole screen unless the cart is built for it. Precompute at `start()` or in
  a host generator. Tick-based timing, 1 tick = 1/60 s; deterministic given a seed.
- Code-drawn placeholder art (`tools/prepare_assets.py` style) counts as final
  unless Adrian swaps a sheet; make new assets the same way or through
  `snouty-art/`.
- Plan first: update the cart's `PLAN.md` before building a milestone. Hand
  off with an annotated tag `<cart>/<milestone>`, a preview GIF in the cart's
  `docs/`, and a short "how to pull and run this" section (Adrian reviews
  locally in the simulator and on the badge).
- Commit messages: short imperative subject, body explains why.
- Push every merge to `main` to `origin` straight away (`git push origin
  main`). Several sessions work in parallel and each starts from
  `origin/main`, so an unpushed merge is invisible to the others. Merge
  only with the cart's gate green (its `tools/check.sh`, `zig build test`
  where it has host tests), and push tags with their merge.
- Work on a branch in a worktree (`git worktree add -b <branch>
  ../snouty-badge-<name> origin/main`), then remove the worktree and
  delete the branch once it is merged and pushed. Before removing any
  worktree, check that it is yours and has no uncommitted work: other
  sessions create worktrees at any time.
