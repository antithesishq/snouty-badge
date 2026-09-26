# Snouty on the Water: demo spec

Owner: Adrian Hatch (Antithesis). Target: SYCL Badge V2, 160x128 RGB565, 60 Hz.
Fourth cart for the badge, alongside `snouty-badge` (running Snouty),
`snouty-bugs` (bullet hell) and `snoutenstein` (raycaster FPS). Working
title only; repo name `snouty-reflections` is also provisional (section 17).
Status and milestones are at the bottom.

## 1. One paragraph

A demoscene piece, not a game: a real-time ray tracer on a 150 MHz
microcontroller. A chrome sphere and a glass sphere hover over an infinite
rippling lake at sunset while the camera slowly orbits. Snouty and the
badge text ("Adrian Hatch" / "Antithesis") stand on the far shore and are
seen mostly as their wobbling reflection in the water. Every pixel of
every frame is a traced ray: primary hit, shadow ray, one reflection
bounce, Fresnel-blended water. The float image is quantised to RGB565
through an animated ordered dither so the sky gradient has no bands and
the whole thing has a 16-bit-console grain. It runs unattended as a badge
(attract loop), and the joystick lets a passer-by steer the camera. The
SDK ships a "Ray Tracing in One Weekend" showcase cart that draws one
pixel per frame; this cart is the same idea at 20 frames per second.

## 2. Hardware facts the design leans on

- RP2354B, Cortex-M33 at 150 MHz. The cart target is built `eabihf` with
  `fp_armv8d16sp`, so `f32` add/mul are single-cycle, `f32` divide and
  `@sqrt` are hardware (about 14 cycles), and `f64` must never appear in a
  hot loop (soft-float). Core 1 runs only the cart; `present()` waits for
  the previous LCD flush, so the cart gets essentially the whole frame
  interval for itself.
- Frame budget at 20 fps: 7.5 M cycles / 20,480 pixels = ~366 cycles per
  pixel at full resolution, or ~1,460 per traced pixel at 80x64 (section 5
  has both paths; M1 decides). 30 fps full res would be ~244 cycles per
  pixel and is the stretch target.
- Screen 160x128, framebuffer column-major (`framebuffer[x][y]`). Rays are
  traced column by column so output stores are stride-1 `u16`, and the
  per-column ray basis is computed once per column.
- Hardware `Pixel` is a bitcast of `DisplayColor`; wasm swaps bytes. All
  quantisation goes through the `Pixel` conversion once, in the dither
  stage.
- Cart RAM 307 KB (`0x20035100..0x20080000`), binary at most 256 KB.
  Budget for this cart: ELF `.text`+`.data` at most 120 KB, `.bss` at most
  120 KB (section 13).
- Inputs: joystick 4-way, A, B, Start, Select. Start+Select (250 ms) and
  joystick click are OS-owned; never bound.
- Audio: `tone2`, one buzzer voice. Neopixels: 5, every channel at or below
  10/255.
- Rendering mode `.no_copy_full_frame`, full redraw every frame, vsync via
  `set_vsync_enabled(1000.0 / target_fps)` so the frame rate is steady
  rather than jittering with scene cost.

## 3. Controls

| Input          | Attract (default)                 | Free camera                            |
|----------------|-----------------------------------|----------------------------------------|
| Left / Right   | Enter free camera; orbit          | Orbit around the spheres               |
| Up / Down      | Enter free camera; raise / lower  | Camera height (clamped above water)    |
| A              | Next scene preset (section 6)     | Next scene preset                      |
| B              | Cycle dither mode (section 5.5)   | Cycle dither mode                      |
| Select         | Toggle sound + LEDs               | Toggle sound + LEDs                    |
| Start          | (nothing)                         | Return to attract orbit                |

Free camera returns to attract by itself after 20 s without input. The
camera can never go below the water plane or inside a sphere; the orbit
radius is fixed so the composition always holds.

## 4. Screen layout

Full 160x128 is the rendered image; there is no HUD. The badge text lives
in the scene (section 6) rather than as an overlay, because a flat overlay
would break the "everything is ray traced" claim. A debug overlay (frame
microseconds, fps, dither mode) draws in the top-left when built with
`-Ddebug_overlay=true`, using the OS font. The OS FPS overlay is used for
the M1 gate as well.

## 5. Rendering

### 5.1 Pipeline per frame

1. Update camera (orbit angle, height), water time, sun position.
2. Build the camera basis once: forward, right, up vectors. Per column
   `x`, compute `right * u(x)` once; per pixel add `up * v(y)` from a
   comptime table of `v` values. Direction is normalised with one
   `1/@sqrt` per pixel (needed for reflections to be correct).
3. Trace the pixel (5.2), producing a linear `f32` RGB triple.
4. Dither and quantise (5.5), store `Pixel` into `framebuffer[x][y]`.
5. `present()`.

Colour math stays in `f32` throughout; gamma is a 3-entry-per-channel
lookup on the quantised value, i.e. baked into the dither tables, so it is
free.

### 5.2 Ray tracing model

Scene primitives, all analytic:

- **Water plane** `y = 0`, infinite. Rows whose primary ray points down
  hit it (`t = -o.y / d.y`). Normal perturbed by ripples (5.3).
- **Spheres**: up to 3 (chrome, glass, matte). Standard quadratic; the
  discriminant test rejects misses in ~12 flops.
- **Shore plane**: a vertical plane far behind the spheres carrying the
  shore texture (Snouty, text, treeline silhouette) with alpha. Rays that
  miss it or hit transparent texels continue to the sky.
- **Sky**: a comptime 64-entry vertical gradient (sunset) indexed by
  `d.y`, plus a sun disc (dot product with sun direction, thresholded and
  smooth-stepped) that gives the glitter its highlight.

Shading per hit:

- Sun is a single directional light. Diffuse `max(0, n.l)`, Blinn-Phong
  specular with a per-material power realised as three successive squares
  (power 8) so no `pow` call.
- **One shadow ray** from every non-water hit toward the sun, tested
  against the spheres only (planes cannot shadow anything here).
- **Chrome**: reflect once, shade the secondary hit fully (no further
  bounce), tint by material colour.
- **Glass**: reflect once and refract once (Snell with fixed IOR 1.5, the
  square root is hardware); blend by Schlick Fresnel (one `1-c` raised to
  the fifth via square, square, multiply). Refracted ray exits the sphere
  through a second intersection and continues to whatever is behind.
  Secondary rays are terminated at depth 1: they may hit water or the
  shore and shade it without another bounce.
- **Water**: reflect the view ray about the perturbed normal, trace the
  reflection at depth 1 (spheres, shore, sky). Blend reflection with a
  deep-water colour by Schlick Fresnel so the water looks glassy at
  grazing angles and dark blue underfoot. Add the sun specular on the
  perturbed normal; this is the glitter.

Worst-case flop count for a water pixel that reflects a glass sphere: plane
hit (6) + ripple normal (~30) + reflect (10) + 3 sphere tests (36) + glass
shading incl. shadow ray to 2 spheres (~70) + Fresnel/blend (~20) + dither
(~10) is roughly 180 flops plus two `1/@sqrt`, so ~250 cycles. Most pixels
are cheaper (sky-only water, or sky). Full-res 20 fps is therefore
plausible and 30 fps is the stretch; the M1 measurement decides.

### 5.3 Ripples

Normal perturbation is procedural: three directional sine waves of
different wavelength, speed and amplitude, evaluated as `sin` from a
comptime 1,024-entry table with linear interpolation. The gradient of the
height field gives `n = normalize(-dh/dx, 1, -dh/dz)`; the normalise is
approximated as `n * (1.5 - 0.5 * n.n)` (one Newton step, no sqrt) since
the perturbation is small. Amplitude fades with distance so the far water
is calm and the horizon is a clean line; near water shows the shore
reflection breaking up, which is the money shot.

### 5.4 Shore texture

One 128x64 RGB-indexed texture (16 colours + transparent) stretched across
the shore plane: Snouty standing on a jetty at left, "Adrian Hatch" and
"Antithesis" in a chunky 8x12 pixel font at right, treeline silhouette
across the top. The direct view sees only the top rows of it above the
horizon (the camera is low); most of it is seen inverted in the water.
Lookup is a `u8` fetch and a palette table; the palette carries a
sunset-lit variant and a "reflection" variant (slightly darker, bluer) so
reflections read as reflections even before Fresnel.

### 5.5 Dithering and quantisation

The traced colour is `f32` linear RGB in `[0, 1]`. Quantisation to 5/6/5
bits would band the sky visibly. Modes, cycled with B:

1. **Ordered 4x4 Bayer, temporal** (default): threshold from a 4x4 Bayer
   matrix indexed by `(x & 3, y & 3)`, with the matrix offset by frame
   parity so the pattern alternates every frame. At 20 fps on an LCD this
   averages to smooth gradients in the eye while still looking like
   dither in a photo. Cost: one table load and one add per channel.
2. **Blue noise 64x64** (comptime-generated void-and-cluster table, 4 KB):
   quieter texture than Bayer, same cost. Toggle to compare.
3. **16-colour palette, ordered**: quantise to a fixed 16-colour sunset
   palette with an 8x8 Bayer matrix (nearest-colour via a 16x16x16 comptime
   lookup cube, 4 KB). The pure Amiga look. Slower by one table indirection.
4. **None**: straight truncation, to show people why dithering exists.

Gamma: the traced values are linear; conversion to display gamma is folded
into the quantisation by comparing against a gamma-spaced threshold table
rather than calling `pow`.

### 5.6 Resolution fallback

If M1 measures under 20 fps at full res, switch to `render_scale = 2`:
trace 80x64, then upscale in the dither stage by evaluating each traced
pixel's colour against four different Bayer thresholds (one per output
pixel). The upscale is free because the quantisation runs per output pixel
anyway, and the dither pattern hides the blockiness. Interlaced
(alternate columns per frame, previous frame reused) is the second
fallback and is cheaper still but shimmers on motion; keep it as a mode
only if scale 2 is not enough.

## 6. Scene presets

Cycled with A, each a small struct (camera orbit parameters, sun
direction, sky gradient index, sphere list, ripple parameters):

1. **Sunset lake** (default): chrome + glass sphere, low orange sun,
   strong glitter.
2. **Midnight**: dark blue sky, moon disc, chrome + matte sphere, calm water,
   shore text lit cool.
3. **Noon**: bright sky, hard shadows on the water (spheres shadow the
   water: this is the one preset where the shadow ray tests from water
   hits too, budget permitting), three spheres.
4. **Storm** (stretch): grey sky, high ripple amplitude, no sun disc, the
   reflection tears apart.

Attract mode advances presets every 30 s with a 1 s fade (scale the
traced colour toward black before dithering).

## 7. Animation

- Camera orbits at 12 degrees per second, height bobbing gently.
- Sun drifts slowly along the horizon so the glitter path moves.
- Spheres bob in anti-phase (`sin` table) by about half a radius; the
  chrome sphere slowly spins a faint procedural stripe pattern so its
  reflection has visible motion even when the camera pauses.
- Ripples move with time; a low-amplitude circular ripple radiates from
  under each sphere as it bobs (one extra sine term keyed to distance
  from the sphere's shadow point on the water).

## 8. Audio and neopixels

- Buzzer: a slow, sparse chiptune arpeggio (single voice, `tone2`), 8-bar
  loop, tempo synced to the camera orbit so one loop is one revolution.
  Off by default? No: on, because the badge is a demo. Select toggles.
- Neopixels: bias lighting. Every frame the dither stage accumulates the
  sum of the 5 vertical screen strips' colours (one add per pixel into
  five accumulators); the five LEDs show those strip averages, scaled to
  the 10/255 cap. When the sun glitter crosses a strip, that LED brightens.

## 9. Architecture

```
cart/src/
  main.zig        start/update, mode state machine, debug exports
  camera.zig      orbit, basis, per-column/per-row direction tables
  scene.zig       presets, sphere lists, sun, sky gradients (comptime)
  trace.zig       intersections, shading, reflection/refraction
  water.zig       ripple height/normal, Fresnel, glitter
  shore.zig       shore texture lookup, palettes
  dither.zig      Bayer/blue-noise/palette tables (comptime), quantise,
                  upscale, neopixel accumulation
  math.zig        Vec3 (@Vector(3, f32)), sin table, fast inverse sqrt
  music.zig       tone2 sequencer
tools/
  gen_shore.py    shore texture from assets/ (Snouty + text + trees)
  gen_bluenoise.py void-and-cluster table -> Zig source
  preview.mjs, make_gif.py, serve-cart.mjs   copied from snouty-bugs
```

`Vec3` is `@Vector(3, f32)` so Zig emits scalar VFP code without struct
overhead; check the M1 disassembly for `vsqrt.f32` and `vdiv.f32` and for
the absence of `__aeabi_f` soft-float calls (`arm-none-eabi-nm` on the
ELF; the build fails if any `__aeabi_d*` symbol is present).

## 10. Debug and verification

Debug exports, as in `snouty-bugs`: `debug_render_us`, `debug_fps_x10`,
`debug_mode`, `debug_preset`, `debug_pixel_checksum` (sum of the
framebuffer, for regression tests).

- `zig build` gives `zig-out/firmware/snouty-reflections.uf2` and
  `zig-out/bin/snouty-reflections.wasm`; `size -A` against section 13;
  soft-float symbol check.
- Headless: `preview.mjs --script tools/scripts/*.json` for each preset
  and dither mode, dumping PNGs; every milestone ships a GIF in `docs/`.
- Reference renderer: `tools/reference.py`, a straightforward Python port
  of the same scene at the same resolution. `check_render.mjs` compares
  the wasm frame against the reference frame per pixel (before dither)
  with a tolerance, so shading bugs are caught without eyeballing.
- Hardware, M1 gate: FPS overlay reading and `debug_render_us` on the
  sunset preset, worst frame of one orbit. Decision table:

| Measured (full res) | Decision                                         |
|---------------------|--------------------------------------------------|
| >= 30 fps           | lock 30, spend the surplus on preset 3 shadows   |
| 20 to 29 fps        | lock 20, as spec'd                               |
| 12 to 19 fps        | `render_scale = 2`, lock 30                      |
| < 12 fps            | scale 2 plus interlace, or drop glass to chrome  |

## 11. Memory budget

| Item                                          | Where | Size    |
|-----------------------------------------------|-------|---------|
| Code (est. 2.5k lines of Zig)                 | .text | ~35 KB  |
| Shore texture 128x64 indexed                  | .text | 8 KB    |
| Sky gradients 4 x 64 x 3 f32                  | .text | 3 KB    |
| Sin table 1,024 f32, Bayer, blue noise 64x64  | .text | 9 KB    |
| Palette cube 16^3 u8 (mode 3)                 | .text | 4 KB    |
| Music                                         | .text | 1 KB    |
| Per-column / per-row direction tables         | .bss  | 2 KB    |
| Half-res colour buffer (scale 2 path only)    | .bss  | 60 KB   |
| Scene + camera state, accumulators            | .bss  | 1 KB    |
| Total                                         |       | ~123 KB |

The framebuffers belong to the OS and are not counted. Well inside 307 KB.

## 12. Asset manifest

- `assets/snouty_shore.png`: 40x48 Snouty standing, side view, sunset-lit,
  16-colour palette shared with the text. Derived from the run cycle's
  standing frame in `snouty-badge`.
- `assets/shore_text.png`: generated by `gen_shore.py` from a bundled 8x12
  font; "Adrian Hatch" over "Antithesis".
- `assets/treeline.png`: 128x16 silhouette, 1-bit.
- `assets/logo/`: Iris marks (copied from `snouty-badge`) for a faint
  emblem etched into the chrome sphere's stripe pattern (stretch).

## 13. Milestones

Each milestone: a tag, a GIF in `docs/`, a "pull and run" note. Parallel
tracks go to Opus subagents with disjoint files, as before.

- **M0 Scaffold**: repo, toolchain copied from `snouty-bugs`, `docs/RUNNING.md`,
  this spec, empty modules, debug exports wired.
- **M1 Tracer on hardware** (the risk milestone): camera orbit, water
  plane with ripples, one chrome sphere, sky gradient, Bayer dither,
  `debug_render_us`. Tracks: A `trace.zig`/`water.zig`/`camera.zig`,
  B `dither.zig`/`math.zig` plus soft-float check in `build.zig`,
  C `tools/reference.py`, `check_render.mjs`, `docs/RUNNING.md`. Gate:
  Adrian flashes it and reports fps and the microsecond readout; the
  section 10 table picks the resolution path.
- **M2 Materials and shore**: glass sphere with refraction, shadow rays,
  shore texture with Snouty and text, reflection palette, Fresnel tuning.
- **M3 Presets and motion**: the four presets, attract cycling with fade,
  free camera, sphere bobbing and radiating ripples, dither modes 2 to 4.
- **M4 Polish**: neopixel bias lighting, chiptune, debug overlay option,
  hardware tuning pass, final GIFs, README.

## 14. Future options (not in this cart's scope)

Kept here so they are not lost. Either could become a second "scene" in
this cart behind the A button if the budget allows, or a fifth cart.

- **Voxel heightfield flyover** (Comanche-style). Cast one ray per column
  through a 256x256 `u8` heightmap with a colour map, drawing vertical
  runs from the bottom up with an occlusion height per column. Cheaper
  per pixel than ray tracing; 30 fps full res is realistic. Lakes in the
  heightmap can reuse this cart's water shader (reflect the ray, march
  again) and distance fog reuses the dither stage. Needs ~128 KB of map
  data, which fits.
- **Bump-mapped rotozoom tunnel**. Per-pixel `(angle, depth)` lookup into
  a comptime 160x128 table, textured with a tiled 64x64 pattern, with a
  cheap bump term from a second offset lookup to fake a moving light.
  Guaranteed 60 fps, hypnotic, and a good "intermission" between heavier
  scenes; but it is a table effect rather than a hardware push.

## 15. Risks

- **FPU not actually in play**: if the toolchain silently soft-floats, the
  whole budget is off by 10x. Mitigation: M1 symbol check and disassembly
  before anything else is built.
- **LCD SPI bandwidth**: a full 40 KB frame per present. The existing carts
  run full-frame at 60 Hz, so 20 to 30 Hz is safe.
- **Banding despite dither** on the real panel: LCD gamma differs from the
  simulator. Mitigation: the gamma threshold table is one constant to
  retune on hardware in M1.
- **Composition at 160x128**: the shore text must be legible when
  reflected and rippled. Mitigation: text is 12 px tall and the ripple
  amplitude fades near the horizon where the reflection is smallest.

## 16. Verification of the claim

The badge text in preset 1 reads "every pixel ray traced, 150 MHz". This
must stay true: no sprite blits, no precomputed sky image, no reprojection
that reuses last frame's colours (interlace fallback excepted, and if it
ships the text changes).

## 17. Open questions for Adrian

1. Name: "Snouty on the Water" (title) and `snouty-reflections` (repo) are
   placeholders. Alternatives: "Reflections", "Snouty Lake", "Juggler
   Hatch".
2. Frame rate philosophy: lock 20 fps full res (spec) or prefer 30 fps at
   80x64 upscaled if hardware lands between? Recommendation: full res at
   20; the dither reads better with real pixels.
3. Should the free camera exist at all, or is this a pure attract-mode
   piece? Recommendation: keep it; people will grab the stick.
4. Music on by default (spec) or off?
5. Glass sphere: real refraction (spec) or fake bent-ray glass if the
   budget is tight? The M1 measurement may answer this.
6. Iris emblem etched into the chrome sphere: worth the art time?
7. Should the flyover (section 14) be planned as a preset in this cart
   from the start, sharing the water and dither code, or kept as a
   separate future cart?

## Status

- 2026-09-26: spec drafted, nothing built yet. Next: answers to section
  17, then M0 scaffold copied from `snouty-bugs`.
