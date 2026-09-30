# Snouty on the Water

Fourth badge cart for the Software You Can Love (SYCL) conference, built for
Antithesis: a real-time ray tracer demo (rippling water, chrome and glass
spheres, dithered sunset). `SPEC.md` is the design and milestone list,
`PLAN.md` the current milestone's contract between parallel tracks. The
sibling cart `../snouty-bugs` is where this toolchain was copied from; its
CLAUDE.md and `../snouty-run/CLAUDE.md` have the long explanations of the
simulator quirks.

## Layout

- `cart/src/` — the Zig cart, one module per concern (SPEC.md section 9).
  `main.zig` exports `start()` and `update()` and holds the wasm shims.
- `tools/` — `reference.py` (numpy reference renderer), `check_render.mjs`.
  The headless runner (`preview.mjs`), `serve-cart.mjs` (serves the wasm on
  :2468 for the simulator), `make_gif.py` and `check_float.mjs` are shared, in
  `../../tools/`.
- `docs/` — `RUNNING.md`, milestone GIFs.
- `../../sycl-badge/` — upstream badge repo, read-only SDK, a git submodule
  at the repository root. Path dependency of the root `build.zig.zon`.

## Target hardware (SYCL Badge V2)

- RP2354B, Core 1 runs the cart. Cortex-M33 at 150 MHz, hard-float ABI
  with single-precision FPU: `f32` add/mul 1 cycle, `/` and `@sqrt` ~14.
  `f64` is soft-float and must not appear in any hot path.
- Screen 160x128 RGB565. Framebuffer is column-major:
  `cart.framebuffer[x][y]`, write `Pixel.from_color(c)` or `set_color`.
- Inputs `cart.controls.*`: start, select, a, b, click, up, down, left, right.
  The OS owns Start+Select (exit to menu) and joystick click (FPS overlay);
  never bind click.
- Audio `cart.tone2`, one voice: unused, no audio in this cart (SPEC.md section 8). 5 neopixels (`cart.neopixels`): off; this
  cart never writes non-zero values (root `docs/NEOPIXELS.md`; a coworker's
  badge shows the LEDs are unusably bright even at 1%, 2026-09-29).
- Budget: ELF `.text`+`.data` at most 120 KB, `.bss` at most 120 KB.

## Building

Zig `0.17.0-dev.1936+5a625d5f3` at `~/.local/bin/zig`
(`export PATH="$HOME/.local/bin:$PATH"`). Commands here run from this cart's
directory (`carts/snouty-reflections/`) unless noted; only `zig build` runs
from the repository root (`../..`). `zig build` there writes
`zig-out/firmware/snouty-reflections.uf2`, `.elf` and
`zig-out/bin/snouty-reflections.wasm` in the root `zig-out/` (from here:
`../../zig-out/...`); `zig build -Dcart=snouty-reflections` builds only this
cart, which keeps it to about 2 min clean (all carts take several minutes).
`-Ddebug_overlay=true` draws render timing on screen; `zig build check-float`
runs the float check. This cart's `build.zig` is a module (`pub fn add`)
called by the root `build.zig`; the root has the one `build.zig.zon` and the
one `src/os/system/tracy_protocol.zig` symlink into the `sycl-badge/`
submodule. Zig fetches packages into the root `zig-pkg/` (gitignored).

## Simulator and preview

Same shims as snouty-bugs: `present_wasm()` copies the frame to 0x20 with
red/blue swapped for the web simulator; `read_controls()` reads the
simulator's button word at 0x04. Headless:

```
node ../../tools/preview.mjs ../../zig-out/bin/snouty-reflections.wasm --frames 600 --every 6 --out out/
python3 ../../tools/make_gif.py out/ preview.gif --scale 3 --ms 50
```

Debug exports (wasm): `debug_frame`, `debug_render_us`,
`debug_pixel_checksum`, `debug_dither_mode`, and since M3
`debug_set_view(preset, t, orbit, height_mm)` (freezes on that view),
`debug_set_dither_mode(mode)` (1 = none, for reference comparisons),
`debug_preset`, `debug_state`, `debug_t`, `debug_orbit`,
`debug_height_mm`. B cycles bayer -> blue noise -> palette16 -> none, so
input scripts need three B presses to reach none
(`tools/scripts/m3_nodither.json`). App state is `cart/src/app.zig`.

## Conventions

- Zig style follows upstream: snake_case functions, 4-space indent, `zig fmt`.
- No allocation, no libm at runtime (`math.sin_turns`), no `f64` in the cart.
- The scene is defined numerically in `PLAN.md`; the Zig tracer and
  `tools/reference.py` must agree to within `check_render.mjs` tolerance.
  Changing the scene means changing both and the plan.
- Commit messages: short imperative subject, body explains why.
- Milestone hand-off: tag, preview GIF in `docs/`, and a "pull and run this"
  section in the final message (Adrian reviews locally and flashes).
