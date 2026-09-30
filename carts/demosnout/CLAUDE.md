# Demosnout

Demoscene cart for the SYCL Badge V2, built for Antithesis: ten classic
real-time effects on a 120 BPM frame clock, looping, with a part picker.
`SPEC.md` is the design, `PLAN.md` the current milestone's contract
between parallel tracks. Toolchain and simulator shims are copied from
the sibling carts (`../snouty-maze`, `../snouty-reflections`); their
CLAUDE.md files hold the long explanations.

## Layout

- `cart/src/main.zig`: `start()`, `update()`, debug exports, wasm shims.
- `cart/src/timeline.zig`: the ordered part table and the fades.
- `cart/src/parts/*.zig`: one effect per file, the interface of SPEC
  section 4 (`name`, `init`, `enter`, `render(t, fb)`).
- `cart/src/gen/`: committed generated data (`scroller_font.zig`,
  `textures.zig`) from `tools/gen_font.py` and `tools/gen_textures.py`;
  rerun the tool and commit when `assets/` changes. Never comptime-heavy
  (Adrian's Mac Zig fails with OutOfMemory on big comptime loops).
- `tools/bench_parts.sh`: badge-bench per part. Shared tools
  (`preview.mjs`, `serve-cart.mjs`, `make_gif.py`, `check_float.mjs`) are
  in `../../tools/`; badge-bench in `../../badge-bench/`.
- `docs/`: `RUNNING.md`, `PERF.md`, milestone GIFs.

## Hardware facts

RP2354B Core 1, Cortex-M33 at 150 MHz, single-precision FPU; `f64` is
soft-float and forbidden (`zig build check-float`). Screen 160x128
RGB565, column-major `cart.framebuffer[x][y]` of `cart.Pixel`; build
pixels with `Pixel.from_color` (byte-swapped on wasm). Cart RAM 307 KB
including code; budgets in SPEC section 2. Inputs `cart.controls`; the OS
owns Start+Select and the stick click. No audio, no neopixels.

## Building

Zig `0.17.0-dev.1936+5a625d5f3` at `~/.local/bin/zig`
(`export PATH="$HOME/.local/bin:$PATH"`). From the repository root:
`zig build -Dcart=demosnout` (outputs `zig-out/firmware/demosnout.{uf2,elf}`,
`zig-out/bin/demosnout.wasm`), `zig build test`, `zig build check-float`.
`-Ddebug_overlay=true` compiles in the B-toggled timing overlay. Never
branch `build.zig` on file existence or environment (this Zig caches the
configure graph).

Headless, from the root:

```
node tools/preview.mjs zig-out/bin/demosnout.wasm --frames 1800 --every 6 --raw-colors --out carts/demosnout/out/loop
python3 tools/make_gif.py carts/demosnout/out/loop carts/demosnout/docs/preview.gif --scale 3 --ms 100
node tools/preview.mjs zig-out/bin/demosnout.wasm --frames 300 --call debug_goto:4 --every 5 --raw-colors --out carts/demosnout/out/tunnel
badge-bench/bench.sh zig-out/firmware/demosnout.elf --frames 900 --every 60 --symbols
carts/demosnout/tools/bench_parts.sh          # one badge-bench run per part, worst-frame table
```

## Conventions

- Upstream Zig style: snake_case functions, 4-space indent, `zig fmt`.
- No allocation, no `std.fmt`, no libm, no `f64`. Fixed-point in per-pixel
  loops (must match bit-for-bit on wasm and thumb), `f32` for per-frame
  set-up. Array repetition `**` does not parse in this Zig; use `@splat`.
- No `@Vector` fields in structs stored in comptime tables (thumb layout
  mismatch, see snouty-maze's CLAUDE.md).
- Every part writes every pixel, every frame; state resets in `enter()`;
  randomness only from `rng.zig` with a constant seed.
- Perf rule: worst frame of every part under 12 ms in calibrated
  badge-bench; half resolution plus `fx.upscale2x` is the escape hatch.
- Commit messages: short imperative subject, body says why. Milestone
  hand-off: tag, GIF in `docs/`, "pull and run this" section for Adrian.
