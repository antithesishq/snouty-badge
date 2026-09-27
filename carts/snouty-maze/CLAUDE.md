# Snouty Maze

Sixth badge cart for the Software You Can Love (SYCL) conference, built for
Antithesis: a from-scratch clone of the Windows 3D Maze screensaver drawn by
a small software rasterizer with a z buffer. `SPEC.md` is the design and
milestone list, `PLAN.md` the current milestone's contract between parallel
tracks. Toolchain copied from `../snouty-reflections` and `../snouty-bugs`;
their CLAUDE.md files have the long explanations of the simulator quirks.

## Layout

- `cart/src/` — the Zig cart, one module per concern (SPEC.md section 11).
  `main.zig` exports `start()` and `update()` and holds the wasm shims and
  debug exports. `render/` is the rasterizer. `host_tests.zig` is the root
  for `zig build test`.
- `assets/gen/` — build-input PNGs (committed), produced by
  `tools/prepare_assets.py --from-w95 assets/src/w95 --art
  ../snouty-art/out/maze` from the original screensaver textures in
  `assets/src/w95/` plus the snouty-art maze pack (Snouty, Zig mark, Iris
  mark, Start button); `--placeholders` draws procedural stand-ins instead.
- `tools/` — `preview.mjs` (headless wasm runner to PNGs), `serve-cart.mjs`
  (serves the wasm on :2468 for the simulator), `make_gif.py`,
  `check_float.mjs`, `check_golden.mjs`, `prepare_assets.py`.
- `tests/golden/` — golden PNGs and `poses.json` for `check_golden.mjs`.
- `docs/` — `RUNNING.md`, milestone GIFs.
- `../sycl-badge/` — upstream badge repo, read-only SDK. Path dependency.

## Target hardware (SYCL Badge V2)

- RP2354B, Core 1 runs the cart. Cortex-M33 at 150 MHz, hard-float ABI
  with single-precision FPU: `f32` add/mul 1 cycle, `/` and `@sqrt` ~14.
  `f64` is soft-float and must not appear in any hot path
  (`zig build check-float` fails the build if it does).
- Screen 160x128 RGB565. Framebuffer is column-major:
  `cart.framebuffer[x][y]`, write `Pixel.from_color(c)`. Both framebuffers
  are OS-owned; the cart's z buffer is its own 40 KB.
- Inputs `cart.controls.*`: start, select, a, b, click, up, down, left, right.
  The OS owns Start+Select (exit to menu) and joystick click (FPS overlay);
  never bind click.
- Audio `cart.tone2`, one voice. 5 neopixels (`cart.neopixels`, GRB), every
  channel at or below 10/255.
- Budget: ELF `.text`+`.data` at most 120 KB, `.bss` at most 100 KB.

## Building

Zig `0.17.0-dev.1936+5a625d5f3` at `~/.local/bin/zig`
(`export PATH="$HOME/.local/bin:$PATH"`). `zig build` writes
`zig-out/firmware/snouty-maze.uf2`, `.elf` and `zig-out/bin/snouty-maze.wasm`.
Clean build about 4 min, incremental seconds. `-Ddebug_overlay=true` turns
the timing overlay on at start (Select toggles it anyway).
`src/os/system/tracy_protocol.zig` is a committed symlink into
`../sycl-badge`; the repos must be siblings. Zig fetches packages into
`zig-pkg/` (gitignored). Assets: `build.zig` has an `images` table, one row
per PNG in `assets/gen/`; the converter emits a `gfx` module
(`gfx.<name>.width/.height/.colors/.indices`).

## Simulator and preview

Same shims as snouty-bugs: `present_wasm()` copies the frame to 0x20 with
red/blue swapped for the web simulator; `read_controls()` reads the
simulator's button word at 0x04. Headless:

```
node tools/preview.mjs zig-out/bin/snouty-maze.wasm --frames 600 --every 6 --out out/
python3 tools/make_gif.py out/ preview.gif --scale 3 --ms 100
node tools/check_golden.mjs            # golden-image regression
```

## Conventions

- Zig style follows upstream: snake_case functions, 4-space indent, `zig fmt`.
- No allocation, no libm at runtime (`math.sin_angle`), no `f64` in the cart.
  Array repetition `**` does not parse in this Zig build; use `@splat`.
- No `@Vector` fields in structs that live in comptime tables (arrays of
  structs in `.rodata`): on thumb, Zig sizes such a struct differently
  from the layout LLVM emits for the constant (40 vs 48 bytes for the
  sphere `Face`), so every entry after the first is read misaligned. The
  wasm build agrees with itself, so the simulator hides it. Use `[3]f32`
  fields and convert at the use site (`render/mesh.zig`).
- Randomness only through `rng.zig`, seeded once from `cart.rand()` in
  `start()`, so `preview.mjs --seed` reproduces runs exactly.
- Never commit the generated `gfx.zig`; do commit `assets/gen/*.png`.
- Commit messages: short imperative subject, body explains why.
- Milestone hand-off: tag, preview GIF in `docs/`, and a "pull and run this"
  section in the final message (Adrian reviews locally and flashes).
