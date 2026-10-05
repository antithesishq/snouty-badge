# Snouty vs. the Bugs

Second badge cart for the Software You Can Love (SYCL) conference, built for
Antithesis: a horizontal bullet-hell shooter starring Snouty, with an attract
mode that plays itself until someone presses a button. `SPEC.md` is the game
design and milestone plan; `ASSETS.md` is the brief for the pixel-art agent.
The sibling cart `../snouty-run` (the running/jumping Snouty cart) is where
the toolchain wrinkles were first solved; its CLAUDE.md has the long
explanations and this file only summarises them.

## Layout

- `SPEC.md`, `ASSETS.md` — design and art brief. Update SPEC.md status per milestone.
- `assets/` — delivered art studies (dropped in via scp), `assets/gen/` build
  inputs (committed), `assets/ref/` references.
- `cart/src/` — the Zig cart, one module per concern (see SPEC.md section 13).
  `main.zig` exports `start()` and `update()`.
- `cart/build/convert_gfx.zig`, `cart/src/packed_int_array.zig` — copied from
  upstream's dvd cart; do not import across repos.
- `tools/` — `check.sh`, `prepare_assets.py`, input scripts in `tools/scripts/`.
  The headless runner (`preview.mjs`), `serve-cart.mjs` (serves the wasm on
  :2468 for the simulator) and `make_gif.py` are shared, in `../../tools/`.
- `../../sycl-badge/` — upstream badge repo, read-only SDK: a git submodule at the
  repository root and the root package's path dependency.

## Target hardware (SYCL Badge V2)

- RP2354B, Core 1 runs the cart. Screen 160x128 RGB565, `DisplayColor.rgb(0xRRGGBB)`.
- Framebuffer is column-major: `cart.framebuffer[x][y]`, write `Pixel.from_color(c)`.
- Inputs `cart.controls.*`: start, select, a, b, click, up, down, left, right.
  The OS owns Start+Select (exit to menu) and joystick click (FPS overlay);
  never bind click.
- Audio `cart.tone2(.{ .frequency, .duration, .volume, .flags = .{ .shape } })`,
  one voice, each call cancels the previous. `cart.set_global_volume`.
- 5 neopixels (`cart.neopixels`): off. This cart never writes non-zero values
  (root `docs/NEOPIXELS.md`; a coworker's badge shows the LEDs are unusably
  bright even at 1%, 2026-09-29).
- Cart budget: keep the ELF `.text` + `.data` under 160 KB (see SPEC.md section 2).

## Cart API essentials

`@import("cart-api")`; every cart has `comptime { cart.export_start_code(); }`.
`set_vsync_enabled(1000.0 / 60.0)`, `set_double_buffer_mode(.no_copy_full_frame)`
and redraw everything each frame. `blit` has no transparency; sprites are
drawn with our own index loop that skips palette index 0 (`draw_cell` in
`main.zig`, to be generalised in `draw.zig`). Built-in 8x8 font via `cart.text`.
`cart.rand()`, `cart.micros_since_boot()`, `cart.trace()` for debugging.

## Asset pipeline

`build.zig` has an `images` table: one row per PNG in `assets/gen/` with
palette bits (4 = 15 colors + transparent) and a transparency flag. At build
time upstream's converter turns them into a `gfx` module: `gfx.<name>.width`,
`.height`, `.colors`, `.indices` (PackedIntSlice). With transparency on,
palette index 0 is reserved for magenta `#FF00FF`; `tools/prepare_assets.py`
(to be written, modelled on snouty-badge's) flattens alpha 0 to that key.
Every animation is one horizontal strip of equal cells, frame 0 left. Sheet
sizes and frame counts are in SPEC.md section 12 / ASSETS.md section 7.

## Building

Zig `0.17.0` at `~/.local/bin/zig`
(`export PATH="$HOME/.local/bin:$PATH"`). Commands in this file run from this
cart's directory (`carts/snouty-bugs/`) unless noted; `zig build` runs from the
repository root, two levels up. There `zig build -Dcart=snouty-bugs` (or plain
`zig build` for every cart) writes `zig-out/firmware/snouty-bugs.uf2`, `.elf`
and `zig-out/bin/snouty-bugs.wasm` (`../../zig-out/` from here). A clean build
of every cart takes several minutes; `-Dcart=` keeps it short. This cart's
`build.zig` is a module with `pub fn add(...)` that the root `build.zig` calls;
there is no per-cart `build.zig.zon`, and the `src/os/system/tracy_protocol.zig`
symlink that `add_os_cart` needs lives once at the repository root. Zig fetches
packages into `zig-pkg/` at the repository root (gitignored).

## Simulator and preview

Upstream's wasm platform never presents and the web simulator reads a legacy
framebuffer at 0x20 with red/blue swapped, and buttons arrive at 0x04 which
the API no longer reads. `main.zig` has `present_wasm()` and `read_controls()`
shims for wasm builds only. Headless:

```
node ../../tools/preview.mjs ../../zig-out/bin/snouty-bugs.wasm --frames 600 --every 6 --out out/
python3 ../../tools/make_gif.py out/ preview.gif --scale 3 --ms 100
```

`--press A-B` holds the A button over tick ranges; the game milestones extend
this to all buttons and an input script (SPEC.md section 14). Browser:
`node ../../tools/serve-cart.mjs` plus `npm run dev` in `../../sycl-badge/simulator`.

## Conventions

- Zig style follows upstream: snake_case functions, 4-space indent, `zig fmt`.
- Fixed pools, no allocation, no libm at runtime (comptime sin table).
  Tick-based timing only; 1 tick = 1/60 s.
- Deterministic given a seed: DEMO uses a fixed seed so headless soak runs
  are reproducible. Never call `cart.rand()` from gameplay; use `rng.zig`.
- Never commit the generated `gfx.zig`; do commit `assets/gen/*.png`.
- Commit messages: short imperative subject, body explains why.
- Milestone hand-off: tag, preview GIF in `docs/`, and a "pull and run this"
  section in the final message (Adrian reviews locally in the simulator).
