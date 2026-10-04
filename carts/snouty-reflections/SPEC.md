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
- Audio: background music through the newer firmware's streaming ring (section 8); never `tone2`. Neopixels: off; the cart never writes
  non-zero values (root `docs/NEOPIXELS.md`; a coworker's badge shows the
  LEDs are unusably bright even at 1%, 2026-09-29).
- Rendering mode `.no_copy_full_frame`, full redraw every frame, vsync via
  `set_vsync_enabled(1000.0 / target_fps)` so the frame rate is steady
  rather than jittering with scene cost.

## 3. Controls

Revised 2026-09-30: A freezes the scene for progressive path tracing
(section 5b); presets moved from A to Select, which was the sound toggle
before audio was dropped (section 8).

| Input          | Attract (default)                 | Free camera                          | Frozen (section 5b)                          |
|----------------|-----------------------------------|--------------------------------------|----------------------------------------------|
| Left / Right   | Enter free camera; orbit          | Orbit around the spheres             | Orbit the frozen view; restarts accumulation |
| Up / Down      | Enter free camera; raise / lower  | Camera height 1.0 to 1.8 m           | Height; restarts accumulation                |
| A              | Freeze                            | Freeze                               | Unfreeze: time resumes where it stopped      |
| B              | Cycle dither mode (section 5.5)   | Cycle dither mode                    | Cycle dither mode (accumulation kept)        |
| Select         | Next scene preset (section 6)     | Next scene preset                    | Next preset; restarts accumulation           |
| Start          | Music on/off (section 8)          | Return to attract orbit              | Unfreeze and return to attract orbit         |

Free camera returns to attract by itself after 20 s without input; frozen
mode returns to attract 60 s after its image has converged with no input
(section 17 question 8). Holding the stick while frozen shows the
real-time tracer's moving view; accumulation restarts on release. The camera can never go
below the water plane or inside a sphere; the orbit radius is fixed so the
composition always holds.

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

## 5a. Spinning Iris logo (M2.2)

A thick Iris mark (the coral bracket-and-diamond logo) stands on the water
in front of the shore, next to the names, and spins about its vertical
axis. It is a ray-traced object like the spheres, so it shows in the water
and in the chrome sphere as well as directly. It replaces section 17's
"Iris emblem etched into the chrome sphere" idea.

Why it is affordable: it stands 8.5 to 18.5 units from the camera, so it is
at most about 50 pixels tall on screen (and a few pixels in the sphere).
Only rays inside its per-frame screen bounds, or in the bounds of its water
reflection, test it; a hit costs one plane pair and a handful of 2D shape
tests, no secondary rays. The estimate is 1 to 2 ms of the 20 fps frame,
against 1.6 ms of headroom in `cut20`, so PLAN.md M2.2 gives it knobs.

## 5b. Freeze frame: progressive path tracing (M4)

Pressing A stops time (camera, water, logo spin, sphere bob, sun drift all
hold at the frame A was pressed) and the cart switches from the real-time
tracer to a Monte Carlo one that adds one sample per pixel per pass into
an accumulation buffer. The picture starts as the ordinary real-time frame,
turns briefly noisy, and then converges over seconds to what the real-time
path cannot afford: the whole scene, glass sphere included, with soft
light and glossy reflections. Pressing A again resumes time exactly where
it stopped. The claim of section 16 gets stronger, not weaker: every pixel
is still traced, now hundreds of times.

**What the frozen tracer adds over cut20** (all of it paid for by time,
not by the 50 ms frame):

- Anti-aliasing: each sample jitters its ray inside the pixel (box
  filter), so edges of the spheres, logo and skyline come out smooth.
- Soft shadows: the sun is a disc (angular radius a knob, about 1.5 deg)
  and each shadow ray aims at a random point on it. Spheres and the Iris
  logo shadow the water with real penumbras (cut20 has no water shadows at
  all; M2 had analytic ones for spheres only).
- The glass sphere is back, with real refraction. At each glass hit the
  path reflects with probability equal to the Fresnel term and refracts
  otherwise: one ray per hit, so cheaper per sample than the real-time
  glass that traced both.
- Glossy water: the ripple normal is perturbed by a sampled microfacet
  (roughness a knob), so the sun's glitter path and the reflections blur
  the way real water does instead of breaking into single-pixel sparkle.
- The logo in every reflection (water and chrome), and specular chains up
  to 4 bounces (chrome to glass to water and back).
- Diffuse surfaces get true path tracing: a cosine-weighted bounce plus a
  shadow ray to the sun, lit by the sky dome, with colour bleeding from the
  lake and the other spheres. The default sunset scene is nearly all
  mirrors; the matte spheres of the M3 presets (section 6) are where this
  shows.
- Depth of field (knob, section 17 question 9): a thin lens focused on the
  chrome sphere, so the skyline and the shore melt into bokeh.

**Sampling.** Pixel jitter, lens and sun-disc samples come from a
low-discrepancy sequence per pass, offset per pixel by a blue-noise tile,
so the noise is fine-grained and converges faster than white noise. The
random numbers are an integer hash of (pixel, pass, dimension), so a
frozen image is deterministic and `tools/reference.py` can compute the
same estimator. Each sample is clamped (knob, default 4.0 in linear units)
before accumulating so the sun's reflection does not leave fireflies.

**Accumulation.** One `u32` per pixel holding the running mean as RGB
11:11:10 fixed point over [0, 2), updated `mean += (x - mean) / n` with
stochastic rounding from the pixel hash so the mean stays unbiased: 80 KB
of `.bss`. All pixels share the pass count `n`. The display pass runs the
mean through the same dither stage as the real-time frame.

**Scheduling.** A pass costs more than a frame (estimate 80 to 150 ms; M4
measures it), so it is sliced by columns: each `update()` traces columns
until about 40 ms have gone by (`micros_since_boot`), then dithers the
whole accumulator to the screen. The display keeps refreshing at 20 fps,
input stays live, and a pass front sweeps across the image. Tracing stops
at `max_passes` (knob, default 256, about 30 s); the image stays up until
A. Until the first pass completes, the columns not yet traced show the
real-time frame that was on screen when A was pressed.

**Structure.** A separate module `pt.zig` with runtime scene parameters
(no comptime specialisation: speed matters less here than breadth). The
real-time tracer and its per-variant specialisations are untouched; its
check_render and badge-bench numbers must not move.

## 6. Scene presets

Cycled with A, each a small struct (camera orbit parameters, sun
direction, sky gradient index, sphere list, ripple parameters):

Cycled with Select since 2026-09-30 (section 3). In frozen mode (section
5b) every preset gets its full content, glass and shadows included.

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
traced colour toward black before dithering); the cycle pauses while
frozen.

## 7. Animation

- Camera orbits at 12 degrees per second, height bobbing gently.
- Sun drifts slowly along the horizon so the glitter path moves.
- Spheres bob in anti-phase (`sin` table) by about half a radius. (M3
  also spun a faint procedural stripe pattern on the chrome sphere; it
  was dropped on 2026-09-30 at Adrian's request: on the badge the hard
  0.12-deep bands read as rendering artifacts, not as chrome, and they
  cost ~1.1 ms in sunset.)
- Ripples move with time; a low-amplitude circular ripple radiates from
  under each sphere as it bobs (one extra sine term keyed to distance
  from the sphere's shadow point on the water).

## 8. Audio

Background music since 2026-10-04 (Adrian: "peaceful and serene chiptune
music ... sound should be toggleable"). This replaces the 2026-09-30 "no
audio" decision (the badge speaker sounds bad) for this cart only.

- The piece: Erik Satie, *Gymnopedie No. 1* (1888), from the Mutopia
  Project's public-domain typesetting (`tools/music/gymnopedie_1.ly` and
  `.mid`, Mutopia-2014/12/14-37). `tools/gen_music.py` turns the MIDI into
  `cart/src/music_data.zig` (348 notes, 1.4 KB): body, ending 1, body,
  ending 2, two bars' rest, loop; about 3.6 minutes at 64 bpm.
- The arrangement (`cart/src/music.zig`): eight voices. The melody is a
  soft 25% pulse with delayed vibrato; an echo voice repeats it 3/8 of a
  beat later and quieter (the NES trick for reverb); the chords are
  triangles, rolled upwards one sixteenth of a beat per note; the bass is
  a triangle, an octave up below C3 so the small speaker carries it.
- The badge: the newer firmware's streaming ring (root `docs/SOUND.md`
  section 7, `lib/stream_audio.zig`). Synthesis at 22.05 kHz, upsampled
  2x, integers only; `update` keeps ~113 ms queued (one 50 ms frame plus a
  slow one) in an 8 KB ring. Measured cost in section 13's status line.
- The simulator: lead, echo and bass on the WASM-4 APU's pulse and
  triangle channels through `tone`; no chords there.
- Default off (root `docs/SOUND.md`: every cart boots silent;
  `-Dsound=true` starts it on). Start in the attract orbit toggles it and
  shows "MUSIC ON" / "MUSIC OFF" for 1.5 s; off fades out within ~0.2 s
  and pauses the song, on resumes it. Start and Select do nothing while
  both are held (the newer firmware's settings chord).
- Variants: on in cut20, full20 and full15; compiled out of half30, whose
  `.text` has no room for it (`variant.music`).

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
                  upscale
  math.zig        Vec3 (@Vector(3, f32)), sin table, fast inverse sqrt
  pt.zig          frozen-mode progressive path tracer (section 5b)
tools/
  gen_shore.py    shore texture from assets/ (Snouty + text + trees)
  gen_bluenoise.py void-and-cluster table -> Zig source
  (preview.mjs, make_gif.py, serve-cart.mjs: shared, in ../../tools/)
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
| Frozen-mode tracer `pt.zig` (est.)            | .text | ~15 KB  |
| Per-column / per-row direction tables         | .bss  | 2 KB    |
| Half-res colour buffer (scale 2 path only)    | .bss  | 60 KB   |
| Scene + camera state                          | .bss  | 1 KB    |
| Frozen-mode accumulation, 160x128 `u32`       | .bss  | 80 KB   |
| Total                                         |       | ~123 KB |

The framebuffers belong to the OS and are not counted. Well inside 307 KB.
Measured M2.2 (cut20): `.text` + `.data` 90 KB, `.bss` 45 KB (40 KB of it
the 1/|ray| table). The M4 accumulator takes `.bss` to about 125 KB, over
the 120 KB this cart has kept to, so M4 raises the `.bss` limit to 136 KB:
90 + 125 + 32 KB stack = 247 KB of the 307 KB window.

## 12. Asset manifest

All generated in code (`tools/gen_shore.py`), no downloads:

- Shore texture, 256x48 texels, 4-bit palette (M2.2; M2 had 256x32):
  the Vancouver skyline seen from the water along the top (towers,
  Harbour Centre's saucer, Canada Place's sails at the waterline, the North
  Shore mountains faint behind), "ANTITHESIS" and "ADRIAN HATCH" in the
  8x12 font, and Snouty on a jetty (downscaled from the run study).
- Iris mark: not a texture. The spinning 3D logo (section 5a) is an
  analytic 2D shape measured from `snouty-art/ref/iris_mark.png`, extruded,
  so it costs no flash and stays sharp at any distance.

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
- **M3 Presets and motion**: the four presets on Select, attract cycling
  with fade, free camera, sphere bobbing and radiating ripples, sun drift,
  chrome stripes (dropped in M3.1, 2026-09-30: they looked like
  artifacting), dither modes 2 to 4, all at 20 fps in cut20. A is
  reserved for M4. No audio (section 8).
- **M4 Freeze frame**: A freezes time and runs the progressive path
  tracer (section 5b) until A again; reference estimator and a
  convergence check in `tools/`, per-pass cost from badge-bench.
- **M5 Polish**: debug overlay option, hardware tuning pass, final GIFs,
  README.

## 14. Future options (not in this cart's scope)

Kept here so they are not lost. Either could become a second "scene" in
this cart behind the A button if the budget allows, or a fifth cart.

- **Voxel heightfield flyover** (Comanche-style): moved to its own idea
  note, `carts/snouty-flyover/SPEC.md` (2026-09-30), as a possible
  separate cart.
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
   separate future cart? **Answered 2026-09-30: separate cart idea,
   `carts/snouty-flyover/`.**
8. Frozen mode (section 5b) never times out, so a badge left frozen at a
   booth stays on its converged image. Resume attract by itself some time
   after the image converges with no input? Recommendation: yes, 60 s.
   **Answered 2026-09-30: yes, 60 s after convergence (PLAN.md M4).**
9. Depth of field in frozen mode: on by default (subtle, focused on the
   chrome sphere), off, or a toggle? Recommendation: on, subtle.
   **Answered 2026-09-30: on, subtle (`lens_radius` 0.05, a knob).**

Question 4 (music) is answered by section 8: no audio.

## Status

- 2026-09-26: spec drafted. Adrian confirmed none of section 17 blocks a
  first version; plan approved.
- 2026-09-26: M0 scaffold (tag `m0`) and M1 tracer (tag `m1`) built. The
  sunset scene renders in the simulator and matches `tools/reference.py`
  on frames 0 and 300; ELF `.text` 13.7 KB, no soft-float symbols. Hardware
  fps and `render_us` not yet measured: that is the M1 gate (section 10).
  Known tuning item: ripple moiré near the horizon; the distance fade in
  PLAN.md is too weak and should be strengthened in M2 (plan, tracer and
  reference together).
- 2026-09-27: M1.1 performance pass (tag `m1.1`). Emulated Cortex-M33
  cycle model (`tools/emu/`) puts the worst orbit frame at ~35 ms
  modelled, down from ~50; every change is lossless against the
  reference. 80x64 upscale kept for a later A/B. Still awaiting the
  hardware number.
- 2026-09-29: calibrated badge-bench (fitted on a real badge) puts m1.1's
  worst orbit frame at 42.19 ms: the "20 to 29 fps" row of section 10, so
  lock 20 at full resolution. Adrian's answers: question 2 full res at
  20 fps; question 5 let the benchmark decide, one switch. M2 planned in
  PLAN.md with a 47 ms worst-frame budget.
- 2026-09-29: M2 built with glass, shore and water shadows, but the full
  scene's worst frame is 74.85 ms calibrated. M2.1 built three perf variants
  (`-Dreflections_variant`, `docs/variants.md`). Adrian picked `cut20`: full
  res at 20 fps, no glass sphere, no water shadows, 45.37 ms worst. It is the
  default build on main; the other variants stay buildable. Question 5 is
  moot while the glass is out.
- 2026-09-29: Adrian added to scope: "ADRIAN HATCH" next to "ANTITHESIS",
  a Vancouver skyline in place of the treeline, and a spinning 3D Iris logo
  near the names so it reflects (section 5a, section 12). Planned as M2.2
  in PLAN.md, before M3.
- 2026-09-29: M2.2 on main (tag `snouty-reflections/m2.2`): Vancouver
  skyline, both names, spinning Iris logo seen directly in cut20 (46.33 ms
  worst); the logo also reflects in water and chrome in half30. Whether
  cut20 gets the reflections waits on a per-frame hardware capture (branch
  `reflections/hw-trace`).
- 2026-09-30: logo moved right of the skyline (`x = -13.5`, in front of
  Canada Place), on main. Adrian: no audio (section 8, the badge speaker
  sounds bad); A becomes freeze-frame progressive path tracing (section
  5b, M4), presets move to Select; M3 next, then M4, then M5 polish. The
  voxel flyover became its own idea note, `carts/snouty-flyover/SPEC.md`.
- 2026-09-30: M3 on main (tag `snouty-reflections/m3`): four presets on
  Select with attract cycling and fades, free camera (orbit, height 1.0 to
  1.8 m), A freezes time, bobbing spheres, sun drift, chrome stripes, four
  dither modes. cut20 worst frames: sunset 46.36, storm 45.45 ms; midnight
  50.30 and noon 50.62 (accepted). Rings, noon's shadows and third sphere
  are off in the real-time view and return in M4's freeze frame. Next: M4.
- 2026-09-30: M3.1 (branch `reflections/m3.1`): chrome stripes dropped at
  Adrian's request (they read as artifacting; section 7), and the Iris
  logo moved to `x = -15.5`, clear of Harbour Centre. cut20 worst frames:
  sunset 45.67, storm 45.15, midnight 49.36, noon 49.73 ms (PLAN.md M3.1).
- 2026-09-30: M3.1 on main (tag `snouty-reflections/m3.1`): chrome
  stripes dropped (Adrian: they read as artifacting), Iris logo moved to
  `x = -15.5`, clear of the skyline.
- 2026-09-30: M4 on main (tag `snouty-reflections/m4`): A freezes and the
  progressive path tracer converges over about 60 s (256 passes, ~190 ms
  each on the calibrated bench) with the glass sphere, soft shadows,
  glossy water, depth of field and every preset's full content, while the
  display stays at 20 fps (frozen updates at most 42.9 ms). Auto-resume
  60 s after convergence. Next: M5 polish.
