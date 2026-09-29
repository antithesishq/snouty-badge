# Plan: Snouty running badge

Owner: Adrian Hatch (Antithesis). Target: SYCL Badge V2, 160x128 RGB565.

## Status

- 2026-09-25: v1 built, reviewed by Adrian (speed and size approved), tagged
  `v1.0.0`. v2 (panel waterfall) built then superseded. v3 (real GHZ backdrop,
  clean panel) built, reviewed by Adrian, tagged `v2.0.0` (`v2.0.1` fixes the
  grass strip). v4 jump + v5 Iris spin + Jump Study 05 reviewed and tagged
  `v3.0.0`. Nothing flashed to hardware yet.
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
- 2026-09-25: Run Study 05 replaces Study 04. Identical except the chest emblem,
  which is now an Iris-style mark. Direct swap; 42 px differ per frame.

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
- Neopixels stay off (never written; see the root `docs/NEOPIXELS.md`).

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
../../tools/preview.mjs      headless Node runner: cart.wasm -> PNG frames (shared)
../../tools/serve-cart.mjs   serves cart.wasm on :2468 with CORS + ws reload (shared)
docs/RUNNING.md              how to build, preview, flash
```

Build approach: try the Zig package route first (`add_os_cart` in upstream is
`pub` and takes a dependency). Known wrinkle: it resolves
`src/os/system/tracy_protocol.zig` via the consumer's `b.path`, so we may need a
tiny shim at that path in our repo, or fall back to building in-tree via a
symlink under `sycl-badge/showcase/carts/`.

## Verification

- `../../tools/preview.mjs` (shared) instantiates the WASM with the same `env` imports as
  `simulator/src/runtime.ts`, calls `start()`, then `update()` N times, and
  dumps the framebuffer to PNGs. A Pillow script stitches them into a GIF.
  This is how we review frames on the VM without a browser.
- The user runs the real simulator locally: `node ../../tools/serve-cart.mjs` plus
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

## v2: Iris logo behind a translucent waterfall (built 2026-09-25, superseded by v3)

Adrian approved v1 speed and size and tagged it `v1.0.0`. v2 adds the Iris and
the deferred waterfall, both confined to the name panel so Snouty and the
ground are untouched.

Layout of the panel (y 108..127), back to front:

1. Panel background, Anti-Black, as before.
2. Two 16x16 Iris marks in Anti-White at (8, 110) and (136, 110). The text is
   centered in the 112 px between them, so "Adrian Hatch" (96 px) still fits.
   Source: `assets/gen/iris_16.png`, hand-pixelled from the 288 px logo mark
   (3 px brackets, rounded outer corner, 7 px diamond). Magenta key.
3. Text, unchanged.
4. Waterfall: `assets/gen/waterfall.png` (16x16, 4 blues) tiled across the
   panel and scrolled downward `water_px_per_tick` (start at 1) so it reads
   as water falling off the ground ledge. Drawn through a checkerboard mask
   `((x + y + tick) & 1) == 0` whose phase flips every tick. At 60 Hz the eye
   blends it to 50% translucency, the same trick Genesis games used. In the
   GIF preview (every 4th frame) the checkerboard is visible; that is expected.
   A 2 px foam row in the lightest blue at y 108..109 marks the ledge.

Assets: `tools/prepare_assets.py` now also writes `iris_16.png` and
`waterfall.png`; `build.zig` converts both (4-bit; iris with transparency).

Verification: headless preview GIF plus a single-frame check that the text is
still legible through the mask.

Outcome: at 50% everywhere, "Antithesis" in coral was hard to read in the
60 Hz blend. Fix kept: water covers 1 in 2 pixels over the bare panel but
only 1 in 4 (cycling over four ticks) over content pixels, i.e. anything not
panel-colored (text and Iris marks). `docs/preview_v2.gif` is rendered with
`make_gif.py --blend 4` from an every-tick dump to approximate the eye.

## v3: real Green Hill Zone waterfall backdrop, clean name panel (built 2026-09-25)

Adrian's direction after seeing v2: keep the name panel clean (no overlay) and
make the sky behind Snouty a direct copy of the famous Sonic 1 Green Hill Zone
waterfall backdrop (rasterscroll.com's Sonic-1-Waterfall.gif). Adrian's asset
hunt supplied the Spriters Resource rips, which is what we build from; the
screenshot GIF is used for the grass strip and to derive exact water colors.

Sources, saved under `assets/ref/`: GHZ background strips rip, GHZ chunks rip
(has the 192x192 waterfall chunk), the 2x 4-frame screenshot GIF, and the
disassembly's `GHZ Waterfall.bin` (kept for reference, not decoded; the chunk
rip already contains the same tiles).

How the original effect works and how we reproduce it (`tools/prepare_background.py`):

- Background strips (small clouds, mountains, cliffs with bushes, lake) are
  stacked into a 160x96 window: 16 + 28 + 40 + 12 rows, all from x offset 56 of
  each strip.
- The waterfall is a FOREGROUND chunk with about half its columns transparent.
  That column dither is the Genesis "translucency". We overlay the chunk over
  the whole window exactly as the game does, no alpha.
- Water shimmer is palette cycling: four palette entries (purple placeholders
  in the rips) rotate through four blues every 100 ms. We emit four PNGs, one
  per cycle step, with the mapping derived by aligning the chunk pattern to the
  screenshot: at step k, level i shows BLUES[(i - k) % 4]. Two extra purples the
  rip uses for lake shimmer are aliased onto levels 0 and 2.
- The strips span several Genesis palette lines, so a frame has about 20
  colors and is converted at 8 bits (15,360 B per frame). Because the cycle
  only permutes colors, all four frames produce identical index arrays and
  differ only in their 20-entry palettes; the linker merges the arrays, so the
  four frames cost about 15 KB in total, not 61 KB.
- Grass strip: 96x12 from the screenshot's ground rows 191..203 (period 96),
  rescaled from the 0..238 ramp to the rips' 0..252 ramp so it matches.

Cart: `draw_background(comptime sprite)` draws the full 160x96 frame chosen by
`(tick_total / 6) % 4`, then ground, panel (Irises + text, no water), Snouty.
Double buffering is `.no_copy_full_frame` since every pixel is redrawn.

Result: `docs/preview_v3.gif` (sampled every 3 ticks at 50 ms so the 100 ms
palette cycle is visible). Firmware about 94 KB of the 256 KB cart limit.

Option kept in the script: set `CURTAIN = False` to skip the foreground chunk
overlay and show only the calmer background strips (cliff-gap waterfall and
lake still shimmer). Faithful curtain is the default per Adrian's request.

## v4: jump on A (built 2026-09-25, awaiting review)

Adrian: "make Snouty jump when I press an input (the Z key in the simulator)".
Z and K map to the A button (bit 2) in the simulator; on hardware it is the A
button.

Input plumbing: upstream's wasm platform never reads the simulator's button
word, so on wasm the cart reads the u16 at address 0x04 itself (same bit
layout as `Controls`); on hardware it reads `cart.controls`. `../../tools/preview.mjs
--press T1-T2` holds A during those updates for headless testing.

Asset: the jump study's `snouty_jump_indexed.png` has a broken palette and the
RGBA frames are smooth-shaded, so `prepare_assets.py` snaps each RGBA frame to
the run palette with a hard alpha cut. Result `assets/gen/snouty_jump.png`,
12 cells of 96x96. Jump Study 05 (2026-09-25) replaced the crosshair chest
emblem with the Iris mark; poses and feet rows are unchanged, so it was a
direct swap of the source directory.

Timing design. The study's poses: 0 stand, 1 dip, 2 crouch, 3 coiled, 4 takeoff,
5 fast rise, 6 apex hang, 7 late apex, 8 descent, 9 pre-landing reach,
10 landing compression, 11 recovery. Running jump uses 4..11. Frames must
hold while Snouty moves through the air, so the pose is chosen from the arc
phase, not from a fixed per-frame duration:

- Horizontal speed is unchanged during the jump (1.5 px/tick, so feet never
  need to match the ground).
- Arc: `h = 40` px, airborne `T = 40` ticks (0.67 s):
  `arc(t) = 4*h*t*(T-t) / (T*T)`, integer math.
- Pose by phase t/T: [0, .10) takeoff 4, [.10, .35) rise 5, [.35, .55) apex 6,
  [.55, .70) late apex 7, [.70, .88) descent 8, [.88, 1) reach 9. Then on the
  ground: landing 10 for 6 ticks, recovery 11 for 6 ticks, then back into the
  run cycle at frame 0.
- Vertical placement aligns each frame's feet row (lowest opaque row,
  printed by prepare_assets.py: run [88 ...], jump [93,93,93,93,93,87,72,77,85,88,88,88])
  to `ground_y - arc(t)`, so the feet trace the parabola exactly regardless of
  how much lift the artist baked into a pose. Cell y can go negative at the
  apex, so the sprite draw clips vertically as well as horizontally.
- A press is edge-triggered and only accepted while running on the ground. If
  Snouty leaves the right edge mid-jump, the normal off-screen pause takes over.

Tunables in one place: `jump_height_px`, `jump_air_ticks`, `land_ticks`,
`recover_ticks`, and the phase table.

Outcome: feet trace the parabola exactly (verified per tick), run cycle is
pixel-identical when A is not pressed, a press while airborne is ignored, and
a second press after landing jumps again. At `jump_height_px = 40` the net rim
clips 4-12 px at the top edge around the apex and the ear tip 2-3 px for two
ticks; the face never clips. About 28 px would keep everything on screen.
Preview: `docs/preview_v4.gif` (press at update 60). Firmware about 147 KB.

## v5: Iris coin spin (built 2026-09-25)

Adrian: the two Iris marks should spin like a coin in pseudo-3D, spin then
pause, at the same pacing as the other animations.

- `tools/prepare_assets.py` renders `assets/gen/iris_spin.png`: 24 cells of
  16x16, one full turn. Frame k is angle k*15 degrees; visible width is
  16*|cos| (minimum 1), sampled nearest-neighbor from the hand-pixelled Iris.
  From 90 to 270 degrees the back face shows: mirrored and drawn in brand
  Grey 2 (`#D3CDD4`) so the two faces read apart. Front face stays Anti-White.
- Cart: 4 ticks per frame (same as the run cycle), so a turn takes 96 ticks
  (1.6 s), then 120 ticks (2 s) resting on the front face. Both marks spin in
  step. Frame = `(tick_total % 216) / 4` during the spin, else 0.
- `draw_cell` now takes its cell size from the strip height, so it serves the
  96 px Snouty strips and the 16 px Iris strip. The static `iris_16.png` is
  no longer built (still generated as the design source).

Preview: `docs/preview_v5.gif` (includes a jump at update 60). Firmware about
150 KB.

## Deferred (v6+)

- Parallax clouds and background hills in the sky.
