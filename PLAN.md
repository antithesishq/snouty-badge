# Plan: Snouty running badge

Owner: Adrian Hatch (Antithesis). Target: SYCL Badge V2, 160x128 RGB565.

## Status

- 2026-09-25: v1 built and verified headless (`docs/preview_v1.gif`). Not yet
  flashed to a badge. Awaiting Adrian's review of size, speed and colors.
- Found while building: upstream's wasm platform never presents frames and the
  simulator reads a legacy framebuffer at 0x20 with red/blue in the legacy
  order, so `present_wasm()` in the cart copies and color-swaps each frame for
  the simulator only. Hardware path is untouched.

## Goal for v1

Snouty runs slowly from the left edge to the right edge of the badge, over and
over, on a Green Hill Zone style ground, with "Adrian Hatch" and "Antithesis"
readable underneath. Deliverable is a UF2 for the badge and a WASM the user can
run in the web simulator on their own machine.

## Asset facts (from the delivered Snouty studies)

- Run cycle: 16 frames, 96x96 cells, strip is 1536x96, play 0..15 forward, never
  ping-pong. Origin (48, 88); ground baseline y=88 in the cell.
- Visible art is about 72x84 pixels; the tallest frame reaches cell y=3.
- 15 opaque colors plus transparency. `snouty_run_indexed.png` is 4-bit with
  palette index 0 transparent.
- Planted toe travels 6 px per animation frame, so Snouty must move exactly
  6 px right per frame or the feet slide. Speed is set by frame duration only.
- Jump study exists (12 frames). Not used in v1.

## Screen layout (v1)

```
y   0..95   sky (GHZ blue), Snouty runs here; cell top = 96-88 = 8
y  96..107  ground strip, 12 px: 3 px grass, 9 px brown checker (GHZ style)
y 108..127  name panel, 20 px: "Adrian Hatch" at y=110, "Antithesis" at y=119
```

Text uses the built-in 8x8 font, centered ("Adrian Hatch" is 96 px wide,
"Antithesis" 80 px). Panel background is Antithesis Anti-Black `#16031B`;
name in Anti-White `#FCFBF9`, company in Coral `#F18271` (brand guide colors).

Snouty at native 96x96 fills 3/4 of the screen height on purpose; a 2x downscale
would destroy the pixel art. If it reads as too big on hardware, the fallback is
a hand-redrawn 48x48 sprite, not a resample.

## Motion

- Badge renders at 60 Hz. Advance the animation frame every `ticks_per_frame`
  ticks (start at 4, so 15 fps, about 90 px/s, one crossing in 2.8 s).
- Snouty x goes from -96 to 160 in 6 px steps, then waits `pause_ticks` off
  screen (start at 60) and restarts. Camera is fixed, ground does not scroll.
- Frame index = (frame counter) mod 16 so the loop is seamless.
- Neopixels stay off in v1 (bright and battery hungry).

## Rendering approach

- `set_double_buffer_mode(.{ .clear_full_frame = sky })`, redraw everything
  each frame: ground rows, panel, text, then Snouty.
- Snouty is drawn with our own loop over the 4-bit palette indices, skipping
  index 0. Upstream `blit` has no transparency. 96x96 = 9216 index reads per
  frame, trivial for the RP2354.
- Memory: 4-bit strip is 73,728 bytes plus palette; cart binary limit is 256 KB
  and runs from RAM. Comfortable. Ground tile and text are tiny.

## Asset pipeline

`tools/prepare_assets.py` (Python, Pillow) writes into `assets/gen/`:

1. `snouty_run.png`: the 16-frame strip with transparent pixels flattened to
   magenta `#FF00FF`. The upstream `convert_gfx.zig` reserves palette index 0 as
   `(31,0,31)` when `transparency=true`, so magenta becomes the skip index and
   the 15 real colors fill indices 1..15, exactly 4 bits.
2. `ghz_ground.png`: an original 32x12 tile drawn in the style of Green Hill
   Zone (grass stripe over a brown/tan checkerboard). We do not copy Sega's
   tiles; we draw our own in that style.

At build time the Zig build runs a copy of upstream's `convert_gfx.zig` on
those PNGs to produce a `gfx` module. `assets/gen/` is committed so the user's
build needs Zig only, not Python.

## Repo layout after v1

```
build.zig, build.zig.zon     Zig package depending on ../sycl-badge (path dep)
cart/src/main.zig            the cart
cart/src/packed_int_array.zig  copied from upstream dvd cart
cart/build/convert_gfx.zig   copied from upstream dvd cart
assets/                      delivered art (zips + unpacked studies)
assets/gen/                  build inputs produced by prepare_assets.py
tools/prepare_assets.py      asset prep
tools/preview.mjs            headless Node runner: cart.wasm -> PNG frames
tools/serve-cart.mjs         serves cart.wasm on :2468 with CORS + ws reload
docs/RUNNING.md              how to build, preview, flash
```

Build approach: try the Zig package route first (`add_os_cart` in upstream is
`pub` and takes a dependency). Known wrinkle: it resolves
`src/os/system/tracy_protocol.zig` via the consumer's `b.path`, so we may need a
tiny shim at that path in our repo, or fall back to building in-tree via a
symlink under `sycl-badge/showcase/carts/`.

## Verification

- `tools/preview.mjs` instantiates the WASM with the same `env` imports as
  `simulator/src/runtime.ts`, calls `start()`, then `update()` N times, and
  dumps the framebuffer to PNGs. A Pillow script stitches them into a GIF.
  This is how we review frames on the VM without a browser.
- The user runs the real simulator locally: `node tools/serve-cart.mjs` plus
  `npm run dev` in `sycl-badge/simulator`, or the hosted simulator at
  badgesim.microzig.tech, which also fetches from localhost:2468.
- Hardware: copy `zig-out/firmware/snouty.uf2` over `CURRENT.UF2`.

## Work breakdown

1. Asset prep script and generated PNGs. (me)
2. Zig build + cart. (subagent, Opus)
3. Headless preview harness + cart server + RUNNING.md. (subagent, Opus,
   in parallel with 2, developed against upstream `dvd.wasm`)
4. Integrate, review frames, tune speed and layout, commit, hand off.

## Open items for Adrian

- Iris logo: no source file on the box. Brand guide confirms the Iris mark and
  colors, but the SVG lives in Drive. scp an SVG or large PNG into `assets/`
  and I will hand-pixel a 16x16 or 20x20 version for the panel. v1 uses text.
- Speed and size taste calls after the first preview GIF.

## Deferred (v2+)

- Sega Genesis style translucent waterfall over the name panel. Plan: a
  2-frame or 4-frame 16-wide tile column of light blues, drawn with 50%
  ordered dithering (checkerboard skip) so the text shows through, the way
  Genesis games faked alpha. Animate by scrolling the tile downward 1-2 px
  per tick. Cheap, no blending math.
- Parallax clouds and background hills in the sky.
- Iris logo in the panel, jump on button press (jump study is ready).
- Coral neopixel pulse on foot contact frames (0 and 8), dimmed hard.
