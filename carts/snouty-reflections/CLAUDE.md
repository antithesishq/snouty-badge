# Snouty on the Water

Fourth badge cart for the Software You Can Love (SYCL) conference, built for
Antithesis: a real-time ray tracer demo (rippling water, chrome and glass
spheres, dithered sunset). `SPEC.md` is the design and milestone list,
`PLAN.md` the current milestone's contract between parallel tracks. The
sibling repo `../snouty-bugs` is where this toolchain was copied from; its
CLAUDE.md and `../snouty-badge/CLAUDE.md` have the long explanations of the
simulator quirks.

## Layout

- `cart/src/` — the Zig cart, one module per concern (SPEC.md section 9).
  `main.zig` exports `start()` and `update()` and holds the wasm shims.
- `tools/` — `preview.mjs` (headless wasm runner to PNGs), `serve-cart.mjs`
  (serves the wasm on :2468 for the simulator), `make_gif.py`,
  `reference.py` (numpy reference renderer), `check_render.mjs`,
  `check_float.mjs`.
- `docs/` — `RUNNING.md`, milestone GIFs.
- `../sycl-badge/` — upstream badge repo, read-only SDK. Path dependency.

## Target hardware (SYCL Badge V2)

- RP2354B, Core 1 runs the cart. Cortex-M33 at 150 MHz, hard-float ABI
  with single-precision FPU: `f32` add/mul 1 cycle, `/` and `@sqrt` ~14.
  `f64` is soft-float and must not appear in any hot path.
- Screen 160x128 RGB565. Framebuffer is column-major:
  `cart.framebuffer[x][y]`, write `Pixel.from_color(c)` or `set_color`.
- Inputs `cart.controls.*`: start, select, a, b, click, up, down, left, right.
  The OS owns Start+Select (exit to menu) and joystick click (FPS overlay);
  never bind click.
- Audio `cart.tone2`, one voice. 5 neopixels (`cart.neopixels`, GRB), every
  channel at or below 10/255.
- Budget: ELF `.text`+`.data` at most 120 KB, `.bss` at most 120 KB.

## Building

Zig `0.17.0-dev.1936+5a625d5f3` at `~/.local/bin/zig`
(`export PATH="$HOME/.local/bin:$PATH"`). `zig build` writes
`zig-out/firmware/snouty-reflections.uf2`, `.elf` and
`zig-out/bin/snouty-reflections.wasm`. Clean build about 2 min.
`-Ddebug_overlay=true` draws render timing on screen. `src/os/system/
tracy_protocol.zig` is a committed symlink into `../sycl-badge`; the repos
must be siblings. Zig fetches packages into `zig-pkg/` (gitignored).

## Simulator and preview

Same shims as snouty-bugs: `present_wasm()` copies the frame to 0x20 with
red/blue swapped for the web simulator; `read_controls()` reads the
simulator's button word at 0x04. Headless:

```
node tools/preview.mjs zig-out/bin/snouty-reflections.wasm --frames 600 --every 6 --out out/
python3 tools/make_gif.py out/ preview.gif --scale 3 --ms 50
```

Debug exports (wasm): `debug_frame`, `debug_render_us`,
`debug_pixel_checksum`, `debug_dither_mode`. `--press B:0-0` switches to
the no-dither mode for reference comparisons.

## Conventions

- Zig style follows upstream: snake_case functions, 4-space indent, `zig fmt`.
- No allocation, no libm at runtime (`math.sin_turns`), no `f64` in the cart.
- The scene is defined numerically in `PLAN.md`; the Zig tracer and
  `tools/reference.py` must agree to within `check_render.mjs` tolerance.
  Changing the scene means changing both and the plan.
- Commit messages: short imperative subject, body explains why.
- Milestone hand-off: tag, preview GIF in `docs/`, and a "pull and run this"
  section in the final message (Adrian reviews locally and flashes).
