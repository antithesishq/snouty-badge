# Plan: M0 scaffold, M1 "Tracer on hardware", M2 "Materials and shore", M2.2 "Names, skyline and Iris", M3 "Presets and motion"

Companion to `SPEC.md`. This file is the contract between the parallel
tracks; when it and the spec disagree, this file wins for the current
milestone and the spec is updated afterwards.

## M0 Scaffold (done 2026-09-26)

Copied from `snouty-bugs`: toolchain (`build.zig`, `build.zig.zon`, tracy
symlink), `tools/preview.mjs`, `tools/serve-cart.mjs`, `tools/make_gif.py`,
`cart/src/input.zig`, the wasm simulator shims in `main.zig`. New:
`math.zig` (Vec3 as `@Vector(3, f32)`, sin table in turns, Schlick,
reflect), `dither.zig` stub (truncation; API fixed below), `overlay.zig`
stub, `-Ddebug_overlay` build option exposed as `@import("build_options")`.
Verified: `zig build` produces uf2/elf/wasm; ELF attributes say
`Tag_ABI_VFP_args: VFP registers`, `Tag_FP_arch: FPv5/FP-D16`; the preview
tool shows the stub gradient; B toggles `debug_dither_mode`.

## M1 goal

One scene, sunset lake: rippling water, one chrome sphere, gradient sky
with a sun, camera orbiting, temporal Bayer dither, timing readout. Flash
it, read fps and `render_us`, pick the resolution path (SPEC section 10).

## Tracks

Each track owns the files listed and touches nothing else. Any needed
change to another track's file goes into the final report as a request.

| Track | Owner | Files |
|-------|-------|-------|
| A tracer | Opus agent | `cart/src/main.zig` (render loop only), `camera.zig`, `scene.zig`, `trace.zig`, `water.zig`, `math.zig` (additions only) |
| B dither, overlay, float check | Opus agent | `cart/src/dither.zig`, `cart/src/overlay.zig`, `build.zig` (new step only), `tools/check_float.mjs` |
| C reference and harness | Opus agent | `tools/reference.py`, `tools/check_render.mjs`, `tools/scripts/*.json`, `docs/RUNNING.md` |

Integration (me): build, run `check_render.mjs`, GIF, tag `m1`, hand-off note.

## Fixed interfaces

```zig
// dither.zig (Track B implements; Track A calls)
pub const Mode = enum(u32) { bayer_temporal = 0, none = 1 };
pub var mode: Mode;
pub fn next_mode() void;
pub fn begin_frame(frame: u32) void;               // once per frame, before quantise
pub inline fn quantise(x: u32, y: u32, rgb: math.Vec3) cart.Pixel; // rgb saturated to [0,1]

// overlay.zig (Track B)
pub fn draw(render_us: u32, frame: u32) void;      // draws over the finished frame

// trace.zig (Track A)
pub fn render_frame(frame: u32) void;              // fills cart.framebuffer via dither.quantise
```

`main.zig` calls, in this order per update: `input.update`, B-press ->
`dither.next_mode()`, `dither.begin_frame(frame)`, `trace.render_frame(frame)`,
timing, `overlay.draw` (only when `build_options.debug_overlay`),
`frame += 1`, `present_wasm` on wasm. Track A owns `main.zig` and replaces
the stub `render()` with the `trace.render_frame` call; nothing else in it
changes.

Debug exports (already wired): `debug_frame`, `debug_render_us`,
`debug_pixel_checksum`, `debug_dither_mode`.

## The M1 scene, exactly

Both `trace.zig` (Track A) and `tools/reference.py` (Track C) implement
this. Right-handed, +y up. `t = frame / 20.0` seconds (the cart is locked
to 20 fps with `set_vsync_enabled(1000.0 / 20.0)`).

**Screen to ray.** Horizontal FOV 60 degrees: `tan_h = tan(30 deg) =
0.57735`. For pixel `(x, y)` (0-based, y down):

```
u = (x + 0.5 - 80) / 80 * tan_h
v = -(y + 0.5 - 64) / 80 * tan_h
dir = normalize(fwd + right * u + up * v)
```

**Camera.** Orbit angle in turns `theta = frame / 600.0` (one revolution
every 30 s, 12 deg/s). Radius 4.5, height 1.6.

```
eye    = (4.5 * sin_turns(theta), 1.6, 4.5 * cos_turns(theta))
target = (0, 0.9, 0)
fwd    = normalize(target - eye)
right  = normalize(cross(fwd, (0, 1, 0)))
up     = cross(right, fwd)
```

**Sun.** Direction toward the sun `L = normalize(0.40, 0.30, -0.85)`.
Colour `sun_col = (1.00, 0.85, 0.60)`.

**Sky(d)** for a unit direction `d`. Gradient on `h = clamp01(d.y)`:

```
horizon = (1.00, 0.55, 0.25)
mid     = (0.85, 0.35, 0.40)
zenith  = (0.15, 0.20, 0.45)
grad    = h < 0.3 ? lerp(horizon, mid, h / 0.3) : lerp(mid, zenith, (h - 0.3) / 0.7)
s       = dot(d, L)
disc    = smoothstep(0.9950, 0.9995, s)
glow    = smoothstep(0.90, 1.00, s); glow = glow * glow
sky     = grad + sun_col * (disc + 0.4 * glow)
```

**Chrome sphere.** Centre `C = (0, 1.0, 0)`, radius 1.0, tint
`(0.95, 0.93, 0.90)`. Intersection: standard quadratic, nearest `t > 1e-3`.

**Water plane** `y = 0`. Hit when `d.y < 0`: `t = -o.y / d.y`, `p = o + d t`.
Ripple height field (`sin_turns` takes turns; `k.p` uses `p.x, p.z`):

| i | A     | k (x, z)      | w    |
|---|-------|---------------|------|
| 1 | 0.020 | (0.90, 0.35)  | 0.55 |
| 2 | 0.012 | (-0.45, 0.80) | 0.80 |
| 3 | 0.006 | (1.70, -1.20) | 1.30 |

```
fade   = 1 / (1 + 0.06 * dist)         where dist = |p - eye| (distance from the
                                        camera; for depth>0 rays use the ray origin)
phase_i = k_i.x * p.x + k_i.z * p.z + w_i * t          (in turns)
dh/dx  = fade * sum_i A_i * k_i.x * 2pi * cos_turns(phase_i)
dh/dz  = fade * sum_i A_i * k_i.z * 2pi * cos_turns(phase_i)
n      = normalize(-dh/dx, 1, -dh/dz)   (Zig may use math.renormalize)
```

The height itself is never used, only the normal (the plane stays flat).

**Shading.** `trace(o, d, depth)` returns linear RGB, `depth` 0..2.

```
hit sphere (nearest):
    n = (p - C) / 1.0
    if depth < 2:  return tint * trace(p, reflect(d, n), depth + 1)
    else:          return tint * sun_col * (0.25 + 0.75 * max(0, dot(n, L)))

hit water (d.y < 0, and no sphere hit closer):
    n     = ripple normal at p
    r     = reflect(d, n);  if r.y < 0.02: r.y = 0.02; r = normalize(r)
    refl  = depth < 2 ? trace(p, r, depth + 1) : sky(r)
    f     = schlick(max(0, dot(-d, n)), 0.02)
    deep  = (0.02, 0.08, 0.14)
    spec  = max(0, dot(r, L)) ^ 64        (six squarings)
    return lerp(deep, refl, f) + sun_col * (0.5 * spec)

miss:
    return sky(d)
```

Depth-2 water (reached only via two bounces) uses `sky(r)` directly, so
recursion is bounded at three levels and there is no unbounded loop. The
final colour is `saturate(color)` then `dither.quantise(x, y, color)`.

**Quantisation, mode `none`** (used for the reference comparison):

```
r5 = floor(r * 31 + 1e-4), g6 = floor(g * 63 + 1e-4), b5 = floor(b * 31 + 1e-4)
```

**Mode `bayer_temporal`** (default). 4x4 Bayer matrix `B[y & 3][(x + 2 * (frame & 1)) & 3]`
with values 0..15, threshold `th = (B + 0.5) / 16`:

```
r5 = floor(r * 31 + th), same for g (63) and b (31), each clamped to range
```

Track B may add a gamma table if it stays within the interface; the
reference compares only in mode `none`, linear.

## Performance rules for Track A

- Column-major loop: `for x: for y:`; compute `fwd + right * u` once per
  column; `up * v` from a comptime 128-entry table of `v` values.
- `f32` everywhere. `@sqrt` and `/` are hardware; no `std.math.pow`, no
  `@sin` at runtime (use `math.sin_turns`), no `f64`.
- Hot path is one function; use `inline` for the small helpers. Verify no
  `__aeabi_d*` or `__aeabi_f*`/`__addsf3`-style symbols in the ELF via
  `tools/check_float.mjs` (Track B), or `nm` if available.
- Report the wasm `debug_render_us` is 0 (no timer in wasm); the number
  Adrian reads comes from hardware. Measure on the VM with a rough proxy:
  host-side `zig build` of a `ReleaseFast` test binary running
  `render_frame` 100 times is fine for relative comparisons only.
- Target after M1 on hardware: `render_us` at most 50,000 (20 fps).

## Track C harness details

- `tools/reference.py`: numpy, renders frame `F` at 160x128 following the
  section above exactly (exact `sin`/`cos`, exact normalize), quantises in
  mode `none` to 8-bit RGB (`r5 * 255 / 31` etc.) and writes
  `out/ref_FFFF.png`. CLI: `--frame F --out DIR`.
- `tools/check_render.mjs`: loads a preview PNG and a reference PNG, compares
  per channel in 5/6/5 units (recover by `round(v8 * 31 / 255)`). PASS if at
  most 1% of pixels differ by more than 1 unit in any channel and no pixel
  differs by more than 6 units; prints the differing-pixel count and the max
  difference. Exit 3 on FAIL. No npm dependencies (decode PNG with
  `node:zlib`, as `preview.mjs` does).
- `tools/scripts/m1_nodither.json`: presses B on tick 0 so frames render in
  mode `none`. Frames to check: 0 and 300 (`--frames 301 --every 300`).
- `docs/RUNNING.md`: adapted from snouty-bugs, plus a "reference check"
  section and the flashing note (copy uf2 to the badge's USB drive).

## Done criteria for M1

1. `zig build` clean; ELF `.text` under 120 KB; `check_float.mjs` passes.
2. `check_render.mjs` PASS on frames 0 and 300.
3. `docs/preview_m1.gif` from 600 frames every 6 (one full orbit, dithered).
4. Tag `m1`, hand-off note with pull-and-run steps; Adrian flashes and
   reports fps and `render_us` (`-Ddebug_overlay=true` build, or the OS FPS
   overlay via joystick click).

## M1.1 Performance pass (2026-09-27)

Adrian approved applying every lossless optimisation found by the emulated
cycle model (docs/M1.md "Emulated cost" once written) and keeping the
80x64 upscale path for a later A/B. "Lossless" means `check_render.mjs`
still passes against the unchanged `tools/reference.py`; the scene
definition above does not change.

Tracks:

| Track | Files |
|-------|-------|
| D optimise | `cart/src/trace.zig`, `water.zig`, `scene.zig`, `camera.zig`, `math.zig`, `main.zig` (noinline only) |
| E emulator tool | `tools/emu/**`, `docs/RUNNING.md` (new section only), `docs/M1.md` (append only) |

Changes for D, in the measured order of payoff (baseline 356 modelled
cycles per pixel at frame 0):

1. Analytic primary-ray length: |dir|^2 = 1 + u^2 + v^2 for an orthonormal
   basis; one rsqrt Newton step per row from a per-column seed. -16 cyc/px.
2. Paired sine table (value, delta) so `sin_turns`/`cos_turns` is one
   load pair and one multiply-add; fold the cosine quarter turn into the
   per-frame phases. -15 cyc/px, +8 KB `.text` (budget allows).
3. One reciprocal for the water hit distance and the fade. -6 cyc/px.
4. `@min(1, c)` instead of full saturate: colour is never negative. -4 cyc/px.
5. Fold constant products at comptime (`0.5*sun_col`, `tint*sun_col`), sky
   lerps in affine form to cut literal-pool loads. Estimated a few cyc/px.
6. Turn the `ts != inf` compare into a bool hit flag. 1-2 cyc/px.
7. Branchless, register-resident sky gradient endpoints. 2-4 cyc/px.
8. `noinline` on `render_frame` so `update` stops shuffling FP registers. ~1%.
9. Per-frame screen bounding box of the sphere (column range, per-column
   row range); primary rays outside it skip the sphere test. ~10 cyc/px.

Each step: build, `check_render` frames 0 and 300, emulator run; keep the
step only if the modelled cycles drop and the check passes. Target: at or
under 40 ms modelled per frame, worst frame of the orbit.

Track E moves the scratch benchmark into `tools/emu/` with a venv
bootstrap (`unicorn`, `capstone`, `pyelftools`), paths relative to the
repo, a single `tools/emu/run.sh` that builds the bench ELF, runs frames 0
and 300 plus an orbit sweep, checks against the reference, and prints the
per-class table and modelled ms. Documented in `docs/RUNNING.md`.

## M2 Materials and shore (2026-09-29)

Adrian's decisions (2026-09-29): lock 20 fps at full resolution (SPEC
section 17 question 2), and let the benchmark decide real against fake
refraction, behind one switch (question 5). The M1 hardware gate is
replaced by the calibrated badge-bench model (worst orbit frame 42.19 ms
at m1.1, frame 557; mean 38.1 ms).

**Budget.** The worst frame of 600, default Bayer dither, calibrated busy
ms from `badge-bench/bench.sh zig-out/firmware/snouty-reflections.elf
--frames 600` (run from the repository root), must be **at most 47.0 ms**.
That leaves 3 ms under the 50 ms frame for model drift. If the full
feature set does not fit, the knobs below are turned in the listed order
until it does, and the result is recorded in the status at the end of this
section.

### Tracks

| Track | Owner | Files |
|-------|-------|-------|
| A tracer | Opus agent | `cart/src/trace.zig`, `scene.zig`, `water.zig`, `camera.zig`, `math.zig`, `main.zig` (render loop only) |
| B shore art | Opus agent | `tools/gen_shore.py`, `cart/src/shore_data.zig`, `cart/src/shore_texels.bin`, `tools/shore_palette.json`, `docs/shore_texture.png` |
| C reference and harness | Opus agent | `tools/reference.py`, `tools/check_render.mjs`, `tools/scripts/*.json`, `docs/RUNNING.md` |

Integration (me): merge, `check_render` on the check frames, badge-bench
before/after, knob decisions, SPEC update, GIF, tag `snouty-reflections/m2`.
The plan commit ships a stub `shore_data.zig` + `shore_texels.bin` in the
final format so A and C can work before B lands.

### The M2 scene, exactly

Everything in "The M1 scene, exactly" holds unless changed here. The
chrome sphere, camera, sun, sky and ripple waves are unchanged.

**Materials.**

| Object | Definition |
|--------|------------|
| Chrome sphere | centre `(0, 1.0, 0)`, radius 1.0, tint `(0.95, 0.93, 0.90)`, shadow opacity 1.0 |
| Glass sphere | centre `G = (-1.9, 0.75, 1.3)`, radius `rg = 0.7`, IOR 1.5, tint `glass_tint = (0.90, 0.96, 1.00)`, `f0 = 0.04`, shadow opacity 0.55 |
| Shore | plane `z = 14`, facing `-z`, covering `x` in `(-16, 16]`, `y` in `[0, 4)`, textured, alpha by index 0 |
| Water | as M1, plus shadows and a scatter term (below), and the new fade |

Spheres never contain the camera (orbit radius 4.5, glass extends to 3.0
from the axis) and are always nearer than the shore along any ray (all
ray origins and both spheres have `z < 5`), so the visibility order is:
nearest sphere, then shore, then water, then sky.

**Shore hit.** Only for `d.z > 0`:

```
ts = (14 - o.z) / d.z;  xs = o.x + d.x * ts;  ys = o.y + d.y * ts
if 0 <= ys < 4 and -16 < xs <= 16:
    u = min(255, floor((16 - xs) * 8))      # mirrored: reads left to right from the lake
    v = min(31,  floor((4 - ys) * 8))       # row 0 is the top
    i = texel(u, v)                         # 4-bit index, see "Shore texture format"
    if i != 0: hit, colour = palette[i]     # linear RGB, already lit; no further shading
```

A downward ray that satisfies `ys >= 0` reaches the shore before the water
(`ys >= 0` means the water hit lies beyond `z = 14`), so the shore test
comes before the water test. Transparent texels and misses fall through to
water (`d.y < 0`) or sky.

**Glass shading.** At a glass hit `p` (ray from outside), `n = (p - G) / rg`,
`c = -dot(d, n)` (> 0):

```
refract(I, N, eta, c):  k = max(0, 1 - eta^2 (1 - c^2));  return eta I + (eta c - sqrt(k)) N

F   = schlick(c, 0.04)
r   = reflect(d, n)
d1  = refract(d, n, 1/1.5, c)                           # entering
t1  = -2 dot(p - G, d1);  q = p + d1 t1                 # exit point, second chord end
n2  = (q - G) / rg;  c2 = dot(d1, n2)
d2  = refract(d1, -n2, 1.5, c2)                         # leaving; a sphere has no TIR on exit
glass(depth < 2)  = F * trace(p, r, depth+1) + (1 - F) * glass_tint * trace(q, d2, depth+1)
glass(depth == 2) = glass_far = (0.45, 0.33, 0.35)      # constant, only ever a few pixels
```

Internal reflection at the exit is dropped (the transmitted part keeps
`1 - F`). `d2` is renormalised if the implementation drifts; the reference
uses exact normalise. The reflected ray cannot hit the glass again and the
exit ray cannot either (convex), so neither tests it.

**Fake glass** (`glass_mode = .fake`, knob 1): no exit intersection;
`d2 = normalize(d1)` traced from `p`, the rest identical. The reference
implements both (`--glass real|fake`), default matching the cart.

**Water shading** (replaces the M1 water rule; only `base` and the shadow
are new):

```
sh    = product over spheres S (centre c, radius rs, opacity a):
            oc = c - p;  b = dot(oc, L)
            if b <= 0: 1
            else:      q2 = dot(oc, oc) - b*b
                       1 - a * (1 - smoothstep(0.72 rs^2, 1.21 rs^2, q2))
base  = water_deep + water_scatter * sh          water_scatter = 0.08 * sun_col = (0.08, 0.068, 0.048)
spec  = max(0, dot(r, L))^64 * sh
return lerp(base, refl, f) + sun_col * (0.5 * spec)
```

Shadows apply to every water hit at every depth (knob 2 narrows this).
`refl` at depth 2 is now `env(r)`: shore if the shore test hits, else
`sky(r)`. The same `env` rule applies to every sky lookup, so a depth-2
water reflection shows the shore.

**Chrome** at depth 2 is unchanged (lambert, no shadow). A chrome
reflection at depth < 2 now can hit the glass, the shore, the water or the
sky.

**Ripple fade** (the horizon moiré fix): `g = 1 / (1 + fade_k * dist)`,
`fade = g * g`, `fade_k = 0.05`. `dist` is as in M1. The integrator may
retune `fade_k` alone, in both implementations together.

### Shore texture format

`cart/src/shore_texels.bin`: 256 x 32 texels, 4-bit palette indices, two
per byte, row-major from the top row: texel `(u, v)` is in byte
`v * 128 + u / 2`, low nibble for even `u`, high nibble for odd `u`
(4096 bytes). Index 0 is transparent.

`cart/src/shore_data.zig` (generated, do not edit):

```zig
pub const width = 256;
pub const height = 32;
pub const palette: [16][3]f32 = .{ ... };     // linear RGB in [0, 1]; entry 0 unused
pub const texels: *const [4096]u8 = @embedFile("shore_texels.bin");
```

`tools/shore_palette.json`: the same palette as `[[r, g, b], ...]`, for
`reference.py`. `tools/gen_shore.py` writes all three plus
`docs/shore_texture.png` (4x preview, transparent shown as magenta);
`python3 tools/gen_shore.py` from the cart directory regenerates them
deterministically. Generated art only, per the art policy: no external
downloads, Snouty derived from the existing run-cycle standing frame in
`../snouty-run/assets/` and recoloured to the palette.

Content, left to right as seen from the lake: a jetty with Snouty standing
on it (about 24 to 28 texels tall), "ANTITHESIS" in a chunky 8x12 font,
a treeline silhouette along the top edge of the whole band with varying
height (its sky gaps are index 0). The shore is on the +z side and faces
the sun (which lies toward -z), so it is front-lit whenever it is in view,
with the sun behind the camera: the palette is warm and sunset-lit, and
the glitter half of the orbit and the shore half alternate. The bottom rows meet the water
(a shoreline strip of 2 to 3 texels) so the reflection joins up.

### Knobs

All in `scene.zig` under one `// M2 knobs` block, each with a comment
stating its modelled cost as measured:

1. `glass_mode: enum { real, fake }` (default real).
2. `water_shadows: enum { all, primary_only, off }` (default all):
   `primary_only` shadows only depth-0 water hits.
3. `glass_secondary: enum { full, env }` (default full): `env` makes the
   glass at depth 1 return `F * env(r) + (1 - F) * glass_tint * env(d2)`
   instead of tracing the two rays.

The reference takes the same knobs as flags; the integrator runs it with
the cart's final settings.

### Rules for Track A

- Keep M1's structure: comptime-instantiated `trace` per (depth, from),
  per-frame screen spans so primary rays skip impossible tests. Extend the
  sphere span to the glass sphere (two spans per column; rows in either run
  the full test), and add whatever per-frame bounds pay for themselves
  (for example a world-space box around each shadow on the water: spheres
  and sun are static in M2, so this box can be comptime).
- New `From` values as needed (reflection off glass, glass exit ray).
  Every ray type tests only what it can hit.
- Keep `hit_sphere`'s `stable` and `on_water` forms for the chrome sphere;
  write the glass test the same way (`on_water` generalises to
  `oc = (o.x - Gx, -Gy, o.z - Gz)`).
- Add `const bench_split = false;` in `trace.zig`: when true, the shading
  functions for glass, shore and water shadow are `noinline` so
  `bench.sh --symbols` attributes their cycles. Report the split with it on,
  ship it off.
- `.text + .data` must stay under 120 KB (m1.1: 97 KB). If glass
  instantiation per depth pushes it over, mirror the `inv_len` table in y
  (saves ~20 KB, PLAN M1.1 notes).
- Measure after each feature (shore, then shadows, then glass): worst and
  mean over 600 frames. Report the numbers per step.
- No `f64`, no runtime `std.math`; `zig build check-float` passes.

### Check frames

`check_render.mjs` against `reference.py` in dither mode `none` on frames
0, 150, 300, 450 and the bench's worst frame. The M1 rule gains an
outlier allowance for nearest-texel shore edges, the shadow edge and
grazing glass silhouettes, where f32 and f64 legitimately pick different
sides: PASS if at most 1% of pixels differ by more than 1 unit and at most
0.25% (51 pixels) by more than 6 units. The report prints both counts and
writes a diff PNG with the >6 outliers marked, so they can be eyeballed.

### Done criteria for M2

1. `zig build -Dcart=snouty-reflections` clean; `.text + .data` < 120 KB;
   `zig build check-float` passes.
2. `check_render` PASS on the check frames with the shipped knobs.
3. Worst frame at most 47.0 ms calibrated busy (600 frames, default
   dither); before/after table and per-feature split recorded below.
4. `docs/preview_m2.gif` (600 frames every 6), `docs/shore_texture.png`.
5. SPEC status and section 17 answers updated; tag `snouty-reflections/m2`;
   pull-and-run note.

### M2 status

- 2026-09-29: plan written; tracks A, B, C started.
- 2026-09-29: first integration (cc19649): scene complete and check_render
  PASS, but calibrated worst 74.85 ms (frame 531), mean 59.9; without glass
  48.3 worst. Knobs 1-3 save at most 3 ms. Three ways forward offered.

## M2.1 Perf variants (2026-09-29)

Adrian asked for all three options built, to compare them himself on the
emulator. One tree, one build option, three firmware images. The picture
logic stays shared; a variant only sets knobs, frame rate and render scale.

### The variants

`-Dreflections_variant=<name>` (root `zig build -Dcart=snouty-reflections`);
default `full20` is cc19649 unchanged (over budget, kept as the baseline).

| name     | res         | fps | scene                                         | budget (94%) |
|----------|-------------|-----|-----------------------------------------------|--------------|
| `full20` | 160x128     | 20  | everything, knobs 1-4 at defaults             | 47.0 ms      |
| `cut20`  | 160x128     | 20  | no glass sphere; water_shadows = primary_only | 47.0 ms      |
| `full15` | 160x128     | 15  | everything; glass_primary = env (knob 4)      | 62.7 ms      |
| `half30` | 80x64 x2    | 30  | everything, knobs at defaults                 | 31.3 ms      |

Budgets are 94% of the frame period, the same margin as M2's 47 of 50.
If a variant misses its budget, the integrator turns further knobs
(2, then 3) within that variant and records it; it does not change the
scene of another variant.

### Shared rules

- `cart/src/variant.zig` is the one place that maps the build option to
  constants: `fps: u32`, `render_scale: u32` (1 or 2), `glass_enabled: bool`,
  and overrides for knobs 2 and 4. `scene.zig`'s knobs read from it.
- Animation runs on seconds, not frames: one orbit is 30 s at every fps
  (`camera.orbit_frames = 30 * fps`, the sin/cos table sized to match, still
  comptime), water `t = frame / fps`. So all variants show the same scene at
  the same wall time, and a bench sweep is one orbit = `orbit_frames` frames.
- `main.start` sets `set_vsync_enabled(1000.0 / fps)`.
- `glass_enabled = false` removes the glass everywhere: no hit tests, no
  screen span, no shadow caster. Not a transparent sphere.
- `render_scale = 2`: rays only at even (x, y), using the existing
  full-resolution camera tables at that pixel (no new tables); each ray's
  colour is written to its 2x2 block, and each of the four pixels is
  quantised with its own full-resolution dither threshold, so the Bayer
  pattern stays at full resolution. Spans and shore rows keep their
  full-resolution meaning; a block's row kind is the kind of its even row.
  Loops step by 2; no per-pixel branch on the scale.
- Size: `.text + .data` < 120 KB for every variant.
- No f64, no runtime std.math; `zig build check-float` passes per variant.

### Reference and check

`tools/reference.py` gains `--fps`, `--no-glass`, `--glass-primary env`
(knob 4: the glass seen by primary rays looks its reflected ray up in
`env()` and its transmitted ray in `env_flat`, trace.zig's definition) and
`--scale 2` (render at 80x64 on the even pixel grid, upscaled 2x2).
`check_render.mjs --variant <name>` passes the matching flags; for `half30`
it compares every pixel of the upscaled image (dither `none` makes each
block uniform). Frames: 0, 1/4, 1/2, 3/4 of the orbit and each variant's
bench worst. The M2 pass rule applies unchanged.

### Tools

`tools/build_variants.sh` (run from the cart directory) builds all four
and copies them to `dist/variants/<name>.{uf2,elf,wasm}`, then prints
sizes. `tools/bench_variants.sh` runs badge-bench (calibrated, default
dither) over one orbit per variant and prints a table: worst frame and
index, mean, budget, verdict.

### Tracks

- **A (cart)**: variant.zig, build option, seconds-based animation,
  glass_enabled, render_scale 2, knob wiring, build_variants.sh. Owns
  `cart/`, `build.zig`, `tools/build_variants.sh`.
- **C (reference)**: the reference flags, check_render --variant,
  bench_variants.sh, badge-bench frames for the variants. Owns
  `tools/reference.py`, `tools/check_render.mjs`, `tools/bench_variants.sh`.

The integrator builds, benches, checks, updates this status and
`docs/RUNNING.md` (section on variants), writes `docs/variants.md` with the
table and a GIF per variant, and tags `snouty-reflections/m2.1-variants`.

### M2.1 status

- 2026-09-29: plan written.
- 2026-09-29: tracks A and C merged. full20 renders bit-identically to
  cc19649 (checksums on frames 0/150/300/450, both dither modes). cut20 as
  planned was 47.97 ms (0.97 over); knob 3 does nothing without glass, so
  water_shadows went from primary_only to off: 45.37 ms. Final, calibrated
  busy, one orbit, bayer dither: full20 75.00 (over), cut20 45.37, full15
  57.19, half30 20.81, all against the budgets above. `.text + .data`: full20
  114148, cut20 103156, full15 112164, half30 117460 bytes; check-float passes
  on all. check_render PASS for every variant on its four orbit frames and its
  worst frame; negative controls (one variant's wasm checked as another) fail.
  Table, montage and GIFs in docs/variants.md; RUNNING.md section 9. Tagged
  `snouty-reflections/m2.1-variants`. Waiting on Adrian's pick.
- 2026-09-29: Adrian picked `cut20` for main ("can't really see the
  difference without water shadows"), keeping the variants buildable. The
  default `-Dreflections_variant` is now cut20. Water shadows are strongest
  when the camera faces the sun (~3,400 pixels changed at frames 525 and 0,
  up to 41/255 per channel) and nearly gone with the sun behind it (~300 at
  frames 225 to 300): a darker wedge on the water beyond the sphere, also in
  its reflection, with less glitter (`docs/water_shadows_on_off.png`,
  reference frame 525). tools/emu was broken since M2 (it did not copy
  shore_texels.bin) and M2.1 (no build_options): fixed, it now builds a
  variant (EMU_VARIANT, default cut20) and passes reference.py --variant.
  `docs/preview_m2.gif` is cut20. Tagged `snouty-reflections/m2`.

## M2.2 Names, skyline and Iris (2026-09-29)

Adrian added three things to scope (SPEC section 5a, 12): "ADRIAN HATCH"
beside "ANTITHESIS", a Vancouver skyline instead of the treeline, and a
spinning 3D Iris logo near the names so it reflects. The shipped variant
is `cut20`; all four variants must keep building and are benched.

### The scene changes, exactly

Everything in the M2 scene holds unless changed here.

**Shore.** Plane `z = 14` facing `-z`, `x` in `(-16, 16]`, `y` in `[0, 6)`
(was `[0, 4)`), 256 x 48 texels (was 32 rows), still 8 texels per unit:

```
u = min(255, floor((16 - xs) * 8));   v = min(47, floor((6 - ys) * 8))
```

`shore_texels.bin` grows to 6144 bytes, same packing. Code takes the height
from `shore_data.height` (Zig) and the texel file size (Python), not a
literal.

**Iris logo.** A slab-extruded Iris mark standing on the water.

| Item | Value |
|------|-------|
| Centre | `C = (-13.5, 1.8, 12.0)` (was `x = 4.5`; moved right of the skyline, the counterpart of Snouty on the left, clear of the title) |
| Half-size | `S = 1.5` (the mark's unit square spans `U, V` in `[-1, 1]`) |
| Half-thickness | `h = 0.12` (world units) |
| Bounding sphere | centre `C`, radius `1.57` (mark radius `1.042 S`, plus `h`) |
| Spin | `phi = 2 pi * ((6 * frame) mod orbit_frames) / orbit_frames`: six turns per 30 s orbit, 5 s per turn, the same at every fps; reuse the orbit sin/cos table at index `(6 * frame) mod orbit_frames` |
| Axes | `n = (-sin phi, 0, -cos phi)` (faces the lake at `phi = 0`), `e_u = (-cos phi, 0, sin phi)` (reads left to right from the lake), `e_v = (0, 1, 0)` |
| Local coords | `q = p - C`: `U = dot(q, e_u) / S`, `V = q.y / S`, `W = dot(q, n)` |

It spans `y` in `[0.3, 3.3]` and `z` in `[10.43, 13.57]`: above the water
and in front of the shore, so along any ray the order is sphere, logo,
shore, water, sky, except that a sphere and the logo compare `t` (a ray
from the water beyond the logo can meet both).

**Mask** `M(U, V)` (measured from `snouty-art/ref/iris_mark.png`, 288 px,
centre 144, unit 140 px; the small inner fillets are dropped, they are
under a pixel at this size):

```
diamond(U, V) = |U| + |V| <= 0.414
TL(U, V)      = U <= 0.293 and V >= -0.293 and U >= -1 and V <= 1
                and not (U > -0.65 and V < 0.65)
                and (U >= 0 or V <= 0 or U*U + V*V <= 1)
BR(U, V)      = TL(-U, -V)
M(U, V)       = diamond or TL or BR
```

**Hit.** For a ray `o + t d` with `t` in `(t_min, t_max)` (the bounding
sphere chord, clipped to `t > 1e-3` and to `t` less than any nearer hit):

```
Wo = dot(o - C, n);  Wd = dot(d, n)
if |Wd| > 1e-6:  ta, tb = sorted((-h - Wo) / Wd, (h - Wo) / Wd)   # slab entry, exit
else:            if |Wo| > h: miss;  ta, tb = -inf, +inf
t0 = max(ta, t_min);  t1 = min(tb, t_max);  if t0 >= t1: miss
for i in 0 .. K-1:        # K = iris_samples, default 4
    t = t0 + (t1 - t0) * i / (K - 1)
    if M(U(o + t d), V(o + t d)): hit at t; face = (i == 0 and t0 == ta); stop
```

`face` hits are on a front or back face; any other sample hit is the side.

**Shading** (no secondary rays, no shadow received or cast):

```
iris = (1.0, 0.3467, 0.2831)                  # linear of sRGB (255, 159, 145)
face: N = n if dot(n, d) < 0 else -n
      col = iris * (0.30 + 0.70 * max(0, dot(N, L)))
            + sun_col * 0.6 * max(0, dot(reflect(d, N), L))^32
side: col = iris * 0.18
```

**Which rays test it.** Primary rays; rays reflected off the water at any
depth (knob 6); rays reflected off the chrome sphere (knob 5). Rays
leaving the glass sphere (full20, full15) do not. A per-frame conservative
bound decides which rays actually run the test (for example the
projected bounding sphere for primary rays, the mirrored one widened for
the ripple slope for water rays, a bounding-sphere reject for chrome
rays); a bound may never change the picture.

### Knobs (added to the M2 block in scene.zig)

5. `iris_in_chrome: bool` (default true): chrome reflections show the logo.
6. `iris_in_water: bool` (default true): water reflections show it.
7. `iris_samples: u32` (default 4, minimum 2): K above.

Reference flags: `--iris-in-chrome`, `--iris-in-water` (0/1),
`--iris-samples K`, `--no-iris`. Variant presets set them if a variant
changes them.

### Budget and order of work

Budgets are unchanged: cut20 47.0, full20 (baseline) 47.0, full15 62.7,
half30 31.3 ms, calibrated busy, one orbit, bayer dither. cut20 starts at
45.37. Measure after each step: taller shore with the new art, then the
logo primary only, then in water, then in chrome. If cut20 is over, turn
knob 7 to 3, then knob 5 off, then knob 6 off, and stop and report if still
over. The other variants' knobs follow cut20's unless their own budget
allows more. `.text + .data` < 120 KB for every variant; if one goes over,
mirror the `inv_len` table in y (M1.1 notes, ~20 KB).

### Shore art (Track B)

`tools/gen_shore.py` redraws the 256 x 48 texture; same rules as M2 (code
drawn, no downloads, point-sampled at about a texel per pixel, mostly
seen upside down in rippling water, everything two texels thick, 15
colours plus transparent; trees may go to free palette slots).

- Top: a Vancouver skyline as seen from the water at sunset, sky gaps
  index 0. Recognisable at this size: Harbour Centre's saucer and mast,
  the tall slim Living Shangri-La, a cluster of glass towers catching the
  sun, Canada Place's white sails at the waterline, and the North Shore
  mountains (the Lions' twin peaks) as a faint hazy band behind.
- "ADRIAN HATCH" over "ANTITHESIS" in the 8x12 font, cream outlined in
  ink, in `u` 108 to 236.
- Snouty on the jetty, as M2, in `u` 12 to 76.
- `u` 80 to 104, `v` 22 to 47 is where the logo stands in front: keep it
  plain (skyline and shoreline only), no text.
- The bottom rows meet the water as before.

### Check frames

check_render per variant on the four orbit quarters, the bench worst, and
three logo frames the integrator picks from the bench data: logo largest on
screen, logo edge-on, logo in the chrome sphere. The M2 pass rule holds.

### Tracks

- **A (tracer)**: taller shore, logo, bounds, knobs, variants, size, the
  per-step numbers. Owns `cart/`.
- **B (art)**: `tools/gen_shore.py` and what it writes
  (`cart/src/shore_texels.bin`, `shore_data.zig`, `tools/shore_palette.json`,
  `docs/shore_texture.png`). Writes a first 256 x 48 version early (the M2
  art moved down 16 rows is fine) so A and C can test against the new size.
- **C (reference)**: `tools/reference.py` (shore size, logo, flags),
  `tools/check_render.mjs` if needed.

The integrator benches, checks, writes `docs/preview_m2.2.gif` and a
close-up of the logo, updates SPEC status and RUNNING.md, and tags
`snouty-reflections/m2.2`.

### M2.2 status

- 2026-09-29: plan written; tracks A, B, C started.
- 2026-09-29: tracks A, B, C merged (untagged, pending Adrian). Art: Vancouver
  skyline, "ADRIAN HATCH" over "ANTITHESIS", palette reshuffled (B's report in
  gen_shore.py). Tracer: iris.zig, per-column pre-planned spans (lossless,
  paid for the logo's overhead), inv_len mirrored in y (comptime 80x64,
  unfolded into .bss at init). Per step, cut20 calibrated worst / mean:
  taller shore 46.65 / 43.37; + logo primary K=4 46.46 / 43.70; + water
  reflections 52.95 / 46.80; + chrome 54.01 / 47.90; K=3 53.77; chrome off
  52.84; water off 46.33 / 43.69 (shipped). Final: full20 73.88 (over,
  baseline), cut20 46.33, full15 58.05 (67.30 with the logo everywhere),
  half30 22.57 with the logo everywhere. full20/cut20/full15 ship iris_cut
  (no logo in water or chrome, K=3); half30 all on. `.text + .data`: 101608 /
  89976 / 99672 / 119576; check-float passes; check_render PASS on all
  variants incl. logo frames 279 (edge-on), 393 (largest), 597 (chrome).
  Open for Adrian: the logo only reflects in half30; a badge capture
  (branch reflections/hw-trace) will say whether cut20 can afford the water
  reflection.
- 2026-09-29: Adrian approved shipping as is (logo seen directly in cut20,
  reflections decided after the hardware capture). Merged with main (41
  commits; main added lib/iris_mark.zig, not used here yet), re-verified:
  cut20 46.33 / 43.69 ms, check_render PASS, all carts build. Tagged
  `snouty-reflections/m2.2` and pushed to main.
- 2026-09-30: Adrian asked for the logo to the right of the skyline, the
  counterpart of Snouty on the left. Centre moved from `x = 4.5` to
  `x = -13.5` (in front of Canada Place; the exact mirror of Snouty,
  `x = -11.75`, crowded the end of "HATCH"). Shore texture unchanged.
  cut20 45.94 / 43.61 ms, half30 22.47 / 18.91; check_render PASS (cut20
  frames 190, 250, 270; half30 285, 375, 405).

## M3 Presets and motion (2026-09-30)

SPEC.md sections 3, 6 and 7 as revised 2026-09-30: four presets on
Select, attract cycling with a fade, a free camera on the stick, spheres
that bob with rings on the water, a drifting sun, stripes on the chrome,
dither modes 2 to 4. A freezes time (the real-time tracer keeps drawing
the frozen scene; M4 swaps the path tracer in behind the same button).
No audio (SPEC.md section 8).

### The problem M3 has to solve first

M2.2 bakes the scene into comptime constants and tables: sphere centres,
the sun, the sky colours, the ripple amplitudes, the camera height (and
from it `camera.first_water_row`, `water.primary_t`, the 27.5 KB
`water.primary_fade`), the chrome-to-logo cone. Presets and motion make
all of these per-frame values. cut20 has 1.06 ms left (45.94 of 47.0 ms
worst), so the first step is to make the scene a runtime input without
motion or new content and measure what that costs, before anything is
added (Track A step 1).

### Fixed interfaces

```zig
// scene.zig (Track A)
pub const Preset = enum(u32) { sunset = 0, midnight = 1, noon = 2, storm = 3 };

// camera.zig (Track A)
pub const default_height: f32 = 1.6;
pub const min_height: f32 = 1.0;
pub const max_height: f32 = 1.8; // Adrian 2026-09-30: was 3.0, over budget above 1.8

// trace.zig (Track A)
pub const View = struct {
    preset: scene.Preset,
    /// Scene time in frames at variant.fps: water, logo spin, bobbing, sun
    /// drift, stripes. Stops while frozen.
    t: u32,
    /// Camera angle as an index into camera.orbit_sincos, [0, orbit_frames).
    orbit: u32,
    /// Eye height, [min_height, max_height].
    height: f32,
    /// Colour scale for the attract fade: 1 full, 0 black.
    fade: f32,
};
pub fn render_frame(view: View) void;

// dither.zig (Track B), extended
pub const Mode = enum(u32) { bayer_temporal = 0, none = 1, blue_noise = 2, palette16 = 3 };
// next_mode() order: bayer_temporal -> blue_noise -> palette16 -> none -> bayer_temporal
```

Legacy identity: with the knob `motion = false`,
`render_frame(.{ .preset = .sunset, .t = f, .orbit = f % orbit_frames,
.height = default_height, .fade = 1 })` gives exactly M2.2's frame `f`,
bit for bit (checked with `debug_pixel_checksum` against the `m2.2`
wasm). This is the regression check for the refactor.

Debug exports added (wasm): `debug_set_view(preset, t, orbit,
height_mm)` (freezes and sets the view, for check_render; the harness no
longer steers by input scripts), `debug_set_dither_mode(mode)`,
`debug_preset`, `debug_state` (0 attract, 1 free, 2 frozen).

### App state (Track B, `main.zig` + new `app.zig`)

- State: `attract`, `free`, plus a `frozen: bool` on top of either.
  `t` advances by 1 per update unless frozen. `orbit` advances by 1 per
  unfrozen attract frame; in free camera Left/Right add -3/+3 per frame
  (36 deg/s at 20 fps), wrapping. Up/Down change `height` by 0.05 per
  frame, clamped. Leaving free camera keeps angle and height, and height
  eases back to `default_height` at 0.05 per frame in attract.
- Stick in attract enters free camera. 20 s (`20 * fps` frames) without
  input returns to attract. Start returns to attract at once (and
  unfreezes).
- A toggles `frozen`. While frozen the stick still moves the camera (M4:
  restarts accumulation), Select still changes preset, B dither.
- Select: next preset, immediately (no fade). Attract: next preset every
  `orbit_frames` frames of unfrozen attract time, with `fade` going 1 to 0
  over the last 0.5 s before the switch and 0 to 1 over the first 0.5 s
  after it. The cycle counter pauses while frozen or in free camera.
- Dither modes 2 to 4 (SPEC.md section 5.5): the blue-noise 64x64 table
  and the 16-colour palette plus its 16^3 lookup cube come from host
  generators (`tools/gen_bluenoise.py`, `tools/gen_palette16.py`) as
  committed binary files, `@embedFile`d; no comptime generation (root
  CLAUDE.md, the Mac OOM). Same cost per pixel as Bayer for blue noise
  (one load); palette16 may cost up to 1 ms more, and only counts against
  the budget as a separate bench row (it is a show-off mode, not default).

### The M3 scene, exactly

Everything below is per frame, from `View`. `s = t / fps` seconds.
Presets are selected at runtime; all four exist in every variant.

**Motion** (knob `motion`, master switch; off = M2.2 identity):

- Bob: sphere `i` centre `y = y0_i + 0.2 + 0.2 * sin_turns(s / 10 + phase_i)`,
  `phase` 0 for the chrome, 0.5 for the second sphere, 0.25 for the third.
  So the chrome sphere (y0 1.0, r 1.0) floats 0 to 0.4 above the water.
- Sun drift: `L` rotated about +y by `8 deg * sin_turns(s / 60)`.
- Rings (knob `rings`): for each sphere, the water height gains
  `A_r * sin_turns(k_r * d - w_r * s) * (1 - d / R_r)^2` for `d < R_r`,
  `d` = horizontal distance of `p` from the sphere's centre;
  `A_r = 0.006`, `k_r = 1 / 0.6`, `w_r = 1.3`, `R_r = 3.0`; the normal
  adds its analytic gradient, times the same distance fade as the waves.
  Rays test the ring only inside the sphere's `2 R_r` square.
- Stripes (knob `stripes`): chrome colour times
  `1 - 0.12 * [fract(3 * (n.x cos a + n.z sin a)) < 0.5]`,
  `a = s / 20` turns, `n` the unit normal at the hit.

**Presets** (sky gradient as the M1 formula with these colours; "sun"
is the light and the disc, moon included):

| | sunset (1) | midnight (2) | noon (3) | storm (4) |
|---|---|---|---|---|
| `L` before drift | normalize(0.40, 0.30, -0.85) | normalize(-0.40, 0.35, -0.85) | normalize(0.30, 0.85, -0.43) | normalize(0.40, 0.30, -0.85) |
| sun_col | (1.00, 0.85, 0.60) | (0.55, 0.62, 0.80) | (1.00, 0.97, 0.92) | (0.40, 0.40, 0.45) |
| disc and glow | yes | yes (moon) | yes | no |
| water specular | yes | yes | yes | no |
| horizon | (1.00, 0.55, 0.25) | (0.06, 0.08, 0.18) | (0.70, 0.82, 0.95) | (0.35, 0.36, 0.40) |
| mid | (0.85, 0.35, 0.40) | (0.03, 0.04, 0.12) | (0.45, 0.65, 0.92) | (0.25, 0.26, 0.30) |
| zenith | (0.15, 0.20, 0.45) | (0.01, 0.01, 0.05) | (0.20, 0.40, 0.85) | (0.12, 0.13, 0.16) |
| ripple amplitude scale | 1.0 | 0.5 | 0.8 | 2.5 |
| shore palette tint | (1, 1, 1) | (0.45, 0.50, 0.70) | (1.05, 1.02, 1.00), clamped to 1 | (0.50, 0.50, 0.55) |
| spheres | chrome; glass where the variant has it | chrome; matte | chrome; matte; small chrome | chrome |
| water shadows | the variant's | off | primary rays, exact (knob `noon_shadows`) | off |

The matte sphere takes the glass slot's place, centre `(-1.9, 0.75,
1.3)`, `r 0.7`, albedo `(0.60, 0.55, 0.50)`, colour `albedo * (0.15 *
sky_mid + sun_col * max(0, dot(n, L)))`, no reflection, no shadow ray.
The small chrome sphere: centre `(1.8, 0.5, 1.6)`, `r 0.5`, tint as the
chrome (knob `noon_third_sphere`). Water shadows in noon: the M2 soft
shadow formula, evaluated exactly per primary water hit inside each
sphere's shadow box (the boxes move with bob and drift; no shadow map).
The ripple amplitude scale multiplies all three waves; the bounds that
depend on it (`water.max_slope`, `water_refl_len2_min`) are recomputed per
preset at comptime (four values). Logo, shore geometry, water body
colours unchanged in every preset.

**Camera height**: `eye.y = height`; the basis from the M1 formulas with
that height. At `default_height` the M2.2 comptime-folded values are used
unchanged (identity). At any other height, `first_water_row`,
`primary_t` and `primary_fade` are recomputed at runtime, in f32, only on
frames where `height` changed; the camera must not go inside a sphere at
any height and angle (min eye-to-centre distance stays above r + 0.3).

### Knobs (scene.zig, cut order)

If a cut20 bench row is over 47.0 ms, turn these in order within that
preset, record each step's cost, and report instead of cutting further:
`rings` (per preset), `stripes`, `noon_shadows`, `noon_third_sphere`,
`sun_drift`. Never cut the free camera, presets or bob without asking
Adrian.

### Budget and bench

cut20, calibrated busy ms, worst frame <= 47.0 in every row:

1. Step 1 (runtime scene, motion off, sunset): record the cost against
   45.94. If it is over 1.0 ms, Track A stops and reports before building
   further (the approach needs rethinking, e.g. per-preset comptime
   specialisation within the 120 KB).
2. Attract, 4 orbits (2,400 frames): every preset, motion on, fades.
3. Height sweep: a bench-only build option `-Dreflections_bench=height`
   makes attract move the height 1.0 to 3.0 and back continuously (a
   table rebuild every frame), 1 orbit per preset.
4. palette16 dither, sunset, 1 orbit: reported, not gated.

Other variants (full20, full15, half30) get the same presets and motion,
must build, pass `check-float` and check_render, and are not gated on
time. `.text + .data` <= 120 KB applies to cut20; the others may go to
140 KB (the RAM window allows it; they are not shipped).

### Reference and check (Track C)

`tools/reference.py` gains `--preset`, `--t`, `--orbit`, `--height`,
`--motion 0|1`, `--rings/--stripes/...` knob flags and the matte and
third spheres, rings, stripes, drift, per-preset sky/sun/tint. It uses
the per-frame f32-rounded values only where the cart does (the height
basis), otherwise f64. `check_render.mjs` sets the cart's view through
`debug_set_view` and dither `none` through `debug_set_dither_mode`, and
gains `--preset` and `--height`. Check set: each preset at `t` = 0, 150,
300, 450 (orbit = t); sunset and storm at heights 1.0 and 3.0; motion off
sunset frames 0 and 300 against M2.2 (identity). The M2 pass rule holds.
`tools/bench_variants.sh` gains the bench rows above.

### Tracks

Each track works in its own git worktree on its own branch off this plan
commit and commits there; the integrator merges. File ownership as usual:
a change needed in another track's file goes in the final report.

- **A (tracer)**: `cart/src/scene.zig`, `trace.zig`, `water.zig`,
  `camera.zig`, `iris.zig`, `variant.zig`, `math.zig`, `build.zig`
  (bench option only). Step 1 first and its number reported in the
  commit message; then presets, then motion, then height, with a bench
  number per step recorded in this file's M3 status. Until B lands,
  a minimal `main.zig` call with a default View is allowed in A's branch
  only.
- **B (app, dither)**: `cart/src/main.zig`, new `cart/src/app.zig`,
  `input.zig`, `dither.zig`, `overlay.zig`, `tools/gen_bluenoise.py`,
  `tools/gen_palette16.py`, their committed outputs. Builds against a
  stub `trace.View`/`render_frame(view)` in its branch until A lands.
- **C (reference, harness)**: `tools/reference.py`,
  `tools/check_render.mjs`, `tools/bench_variants.sh`, `tools/scripts/`,
  `docs/RUNNING.md`. Verifies the legacy identity path against the m2.2
  wasm first.

Integration (me): merge A, B, C; build all variants; check_render and
bench rows; preset montage and a free-camera GIF in `docs/`; SPEC.md
status; tag `snouty-reflections/m3`.

### Done criteria for M3

- All four presets, attract cycling with fades, free camera with its
  timeout, A freeze, Select presets, B through four dither modes, on the
  simulator.
- Legacy identity passes; check_render passes on the check set for cut20
  and half30.
- cut20 bench rows 1 to 3 at or under 47.0 ms, or a report of which knob
  would be needed and what it costs.
- `zig build check-float` passes for every variant; sizes as above.

### M3 status

- 2026-09-30: plan written.
- 2026-09-30 (Track A step 1): runtime scene, motion off, sunset only.
  `trace.View` / `render_frame(view)`; preset values (sun, sky, colours,
  shore palette, wave gains) are comptime per preset and copied into a
  per-frame `scene.Frame` with the fade folded into every emitted colour
  (no per-pixel cost); sphere heights and `k = y^2 - r^2` per frame; the
  primary water tables are runtime copies (`water.build_tables`) of the
  comptime ones at default height. Legacy identity: checksums of frames
  0..600 step 50 equal the m2.2 baseline for cut20 and half30, both dither
  modes. cut20 45.48 / 43.09 ms (worst / mean; baseline 45.94 / 43.61):
  -0.46 ms. `.text + .data` cut20 94800, full20 106152, full15 104376,
  half30 123368 (under 140 KB); `.bss` cut20 86632, full20/full15 120488,
  half30 120592 (the 40 KB primary_fade_rt).
- 2026-09-30 (Track A steps 2-4, presets, motion, height). Calibrated busy
  ms, worst / mean over one orbit, cut20 unless noted.
  - Presets and matte/small spheres, motion off (`-Dreflections_bench=
    motion_off`): row 1, sunset 45.49 / 43.11 (baseline 45.94 / 43.61);
    legacy identity holds (checksums 0..600 step 50, cut20 and half30,
    dither none; bayer differs on odd frames only because the stand-in
    main's dither parity follows its own frame counter, not the view).
  - A first general form (runtime flags for the other spheres in every
    ray) cost 1.4 ms in sunset and put midnight at 55.1, noon at 66.8.
    Now: the render is instantiated twice in cut20 (`trace.Class`:
    chrome-only for sunset and storm, the M2.2 code; general for presets
    with a second sphere), and in the general one the water rows whose
    reflection may meet another sphere or whose hit may lie in a noon
    shadow (`x` rows, per column: the M2.2 water-logo bands, a small span
    round the mirror image for t >= tau, a span round each shadow box)
    run x kinds; the rest run the chrome-only kinds. debug_span paints a
    plain row that needed an x kind: zero over 200 frames each of
    midnight and noon; a negative control paints 359.
  - Knobs in cut order, measured at each preset's worst frame: rings 12.5
    ms in sunset (8.9 active, 3.6 for the ring code's mere presence in
    the water normal) - off in cut20, full20, full15, half30 (half30 33.1
    with rings, budget 31.3); stripes 1.1 in sunset, ~0 in midnight and
    noon - kept; noon_shadows 6.9 and noon_third_sphere 6.6 in noon - off
    in cut20, full20, full15 (kept in half30); sun_drift 0 - kept.
  - Row 2 per preset, motion on, knobs as above: sunset 46.62 / 44.08,
    midnight 49.81 / 46.01 (OVER), noon 50.24 / 45.34 (OVER), storm
    45.78 / 42.81. Midnight and noon are over after every knob: of their
    ~3.5 ms over sunset, the matte seen in the water costs 1.4-1.8
    (without it 48.41 / 48.45), the rest is the general render (1.3) and
    the x-row planning (0.5). Not cut further: needs Adrian (options:
    no matte in water reflections, a matte-only render instance for +17
    KB, or a lower bar for those two presets).
  - Row 3, height sweep (`-Dreflections_bench=height`: 1.0 -> 3.0 -> 1.0
    over each orbit, a table rebuild every frame): sunset 51.40 / 47.17,
    midnight 54.89 / 48.98, noon 55.32 / 48.32, storm 51.53 / 45.99, all
    OVER. Worst per height band (sunset): 1.0-1.8 at or under 46.5, 2.0
    48.2, 2.4 50.6, 2.6-3.0 51.4: above ~1.8 m more rows see water (every
    row at 3.0), and water pixels cost ~270 cycles against ~60 for sky.
    The rebuild is 0.8 ms at 1.0 m, ~2 ms at 3.0 m (a divide per entry).
    Needs Adrian: e.g. max_height 1.8, or a cheaper water shade above it.
  - Other variants (not gated): half30 sunset 27.11 / 21.21, noon 20.45
    / 18.07 (budget 31.3); full15 sunset 64.83 / 60.63 (budget 62.7);
    full20 sunset 90.48 / 68.47 (baseline). full20 and full15 got
    heavier than M2.2 because moving spheres make the static shadow map
    invalid: their water shadows are exact per hit at every depth.
  - check_render (Track C's reference, the variant's knob flags): 24/24
    PASS for cut20, half30, full20, full15 (worst: storm t=300, 75 pixels
    > 1 unit, 21 > 6: the one-step normal renormalisation at 2.5x
    amplitude). check-float passes for every variant and the height and
    motion_off builds.
  - Sizes, `.text + .data` / `.bss`: cut20 98684 / 47080, full20 84028 /
    46968, full15 82636 / 46968, half30 111916 / 47080. The inverse ray
    length is read from the 20 KB quarter table with a mirrored stride
    (no 40 KB unfolded copy); the shipped build computes the primary
    water fade at runtime (40 KB `.bss`, every height) and leaves out the
    27.5 KB comptime table, which the motion_off build keeps.
  - Toolchain bug found: indexing a comptime array of structs holding
    vectors (`[4]Consts`) at runtime read wrong bytes for presets 1-3 in
    the thumb build only (wasm right); `scene.consts_of` switches over
    four separate constants instead.
- 2026-09-30 (integration, branch reflections/m3-int): A, B, C merged,
  m3_shim removed. Legacy identity (motion_off vs the pre-M3 main build)
  13/13 frames identical for cut20 and half30, dither none and bayer;
  check_render 24/24 PASS for all four variants with their knob flags.
  Sizes `.text + .data` / `.bss`: cut20 109936 / 67096, full20 95456 /
  66984, full15 93936 / 66984, half30 123344 / 67096 (under 140 KB). The
  blue-noise table is f32 (16 KB `.bss`); M4's 80 KB accumulator still
  fits the 307 KB window (110 + 147 + 32) but a u8 table would give 12 KB
  back. Bench (`bench_variants.sh --m3`, cut20): row 1 45.49 / 43.11
  PASS; row 2 attract 4 orbits: sunset 46.36, midnight 50.30 (OVER),
  noon 50.62 (OVER), storm 45.45; row 3 height sweep with Track B's app
  (1.0 to 3.0 m at 50 mm per frame, a rebuild every frame): 54.2 to 58.9,
  all OVER; row 4 palette16 47.24 / 44.69 (report). Waiting on Adrian for
  midnight/noon, max height, and the knobs turned off (rings, noon
  shadows, noon third sphere).
- 2026-09-30: Adrian's answers: midnight and noon ship as they are
  (occasional stutter accepted on their heaviest frames); free camera
  capped at 1.8 m (`camera.max_height`, reference, check_render, docs);
  rings, noon shadows and noon's third sphere stay off in the real-time
  view (M4's frozen tracer brings them back). Row 3 again with the cap:
  sunset 48.01 / 44.17, midnight 52.36, noon 52.72, storm 47.76 / 42.82.
  Sunset and storm are over 47.0 only while the height is moving (the
  table rebuild, ~1.6 ms, runs on every frame of a height change), still
  inside the 50 ms frame. check_render 24/24 PASS cut20 and half30 at the
  new heights. Preview GIFs `docs/preview_m3_presets.gif` (4 orbits of
  attract) and `docs/preview_m3_free_camera.gif`. Tagged
  `snouty-reflections/m3`.

## M4 Freeze frame (2026-09-30)

SPEC.md section 5b: A freezes time and a progressive path tracer, `pt.zig`,
replaces the real-time tracer until A again. Adrian's answers
(2026-09-30): section 17 question 8, a converged frozen image resumes
attract by itself after 60 s without input; question 9, depth of field on
by default, subtle, focused on the chrome sphere.

The real-time tracer and its per-variant specialisations are not changed
beyond the memory sharing below. Its check_render (24/24) and M3 bench
rows 1 and 2 must stay within 0.1 ms of the M3 numbers.

### Memory

The accumulator is 160 x 128 `u32` = 80 KB. The real-time tracer's
`water.primary_fade_rt` (`[80][128]f32`, 40 KB) is only needed while the
real-time tracer runs, so both live in one 80 KB arena:

```zig
// arena.zig (Track A)
pub var words: [camera.width * camera.height]u32 align(8) = undefined;
pub const Owner = enum { realtime, pt };
pub var owner: Owner = .realtime;
```

`water.primary_fade_rt` becomes a comptime-known pointer into
`arena.words` (same code in the hot path: a constant address). Handing
the arena to `pt` sets `owner = .pt`; handing it back calls
`water.invalidate_tables()` (sets `tables_height` to NaN), so the next
real-time frame rebuilds the tables (about 1.6 ms, once). The motion_off
bench build keeps its comptime table and does not use the arena for it.

Limits for every shipped variant: `.text + .data` at most 136 KB, `.bss`
at most 136 KB, and their sum at most 250 KB (the RAM window is 307,456 B
with a 32 KB stack). Expected cut20: `.bss` 67 + 40 = 107 KB.

### Fixed interfaces

```zig
// pt.zig (Track A)
pub const max_passes: u32 = 256;          // knob
pub const slice_us: u32 = 36_000;         // knob: tracing time per update
pub const wasm_columns_per_update: u32 = 40; // knob: wasm has no clock; the integrator sets it from the bench rate
/// Seed the accumulator from the framebuffer the real-time tracer has just
/// drawn for `view` (decode RGB565 to linear, n = 0 in every column), take
/// the arena, and set up the frozen scene. Call after trace.render_frame
/// in the same update.
pub fn begin(view: trace.View) void;
/// Trace whole columns (one sample per pixel each) until
/// micros_since_boot() >= deadline_us, at least one column; on wasm,
/// exactly wasm_columns_per_update columns. Nothing once done().
pub fn step(deadline_us: u64) void;
/// Dither the accumulator mean to the framebuffer (dither.quantise in the
/// current mode, then the caller's dither.end_frame()).
pub fn display() void;
/// Give the arena back to the real-time tracer (no-op when not active).
pub fn release() void;
pub fn active() bool;
/// Completed passes (the minimum over columns).
pub fn passes() u32;
pub fn done() bool;                       // passes() == max_passes
```

Debug exports added (wasm, Track B in `main.zig`): `debug_set_pt(on)`
(0 keeps the M3 behaviour: a frozen view shows the real-time frame; 1,
the default, runs the path tracer), `debug_pt_run(n)` (runs n whole passes
synchronously, wasm only), `debug_pt_passes()`, `debug_pt_accum()` (byte
address of `arena.words` in wasm memory, for the harness to read the
means), `debug_pt_restart()`. `check_render.mjs` calls `debug_set_pt(0)`
first.

### App (Track B, `app.zig`, `main.zig`, `overlay.zig`)

- A (unfrozen): this update renders the real-time frame as today, with
  time stopped; then `pt.begin(view)`. Later frozen updates:
  `pt.step(t0 + slice_us)` (`t0` is `micros_since_boot()` at the start of
  update), `pt.display()`, `dither.end_frame()`.
- Stick held while frozen: `pt.release()` and the real-time tracer draws
  the moving view (so the camera stays responsive); on the first update
  with no stick held, the real-time frame for the new view and then
  `pt.begin` (a restart). Select while frozen: next preset, the same
  restart. B while frozen: next dither mode, accumulation kept.
- A (frozen): `pt.release()`, time resumes. Start: `pt.release()`,
  unfreeze, attract.
- Auto-resume (question 8, knob `frozen_resume_s = 60`): once `pt.done()`,
  `frozen_resume_s * fps` updates without input act as Start.
- `debug_set_view` keeps its M3 meaning and, with `debug_set_pt(1)`, the
  next update starts accumulation.
- `-Ddebug_overlay=true`: while frozen, also show `passes()`.

### The M4 estimator, exactly

Both `pt.zig` and `tools/reference.py --pt` implement this. f32 in the
cart (no f64), f64 in the reference except for the integer RNG, which
must match bit for bit.

**Scene.** The frozen `View`'s scene, as the real-time M3 scene defines
it at that `t` (bob heights, drifted sun `L`, logo spin, wave phases,
per-preset sky, sun colour, shore tint, ripple scale), with every preset's
full content regardless of variant: sunset chrome + glass, midnight
chrome + matte, noon chrome + matte + small chrome, storm chrome; rings
on in every preset; stripes as M3; the logo everywhere. `fade = 1`.

**Random numbers.** Pixel `(x, y)`, pass `n` (0-based, per column),
dimension `d`:

```
lowbias32(v): v ^= v >> 16; v *= 0x7feb352d; v ^= v >> 15; v *= 0x846ca68b; v ^= v >> 16   (u32 wrapping)
key = (n * 64 + d) * 20480 + y * 160 + x                                (u32 wrapping)
hash(x, y, n, d) = lowbias32(key)
to_unit(h) = (h >> 8) * 2^-24                                           (exact in f32)
bn(x, y) = bluenoise64.bin[(y & 63) * 64 + (x & 63)]                    (the dither's file, u8)
```

Dimensions 0 to 3 are a blue-noise-rotated R2 sequence, the rest hashed:

```
A0 = 3242174889 (0xc13fa9a9), A1 = 2447445414 (0x91e10da6)      # 2^32 / g, 2^32 / g^2, g the plastic number
d = 0, 1 (pixel jitter): u = to_unit((bn(x,      y     ) << 24) + n * A_d)
d = 2, 3 (lens):         u = to_unit((bn(x + 32, y + 32) << 24) + n * A_(d-2))
d >= 4:                  u = to_unit(hash(x, y, n, d))
```

Vertex `b` (0 = the primary hit) uses dimensions `4 + 4b` and `5 + 4b`
for the sun direction and `6 + 4b`, `7 + 4b` for its surface sample.
Dimension 63 is the accumulator's stochastic rounding.

**Camera ray.** `px = x + u0`, `py = y + u1`, then the M1 screen-to-ray
formulas with `px, py` in place of `x + 0.5, y + 0.5`, the camera basis
of the view's orbit and height. Depth of field (knob `dof`, default on):

```
f  = dot(chrome_centre - eye, fwd)                 # chrome centre at t
P  = eye + dir * (f / dot(dir, fwd))
rl = lens_radius * sqrt(u2);  a = 2 pi u3           # lens_radius = 0.05 (knob)
o  = eye + right * (rl cos a) + up * (rl sin a);  dir = normalize(P - o)
```

**Sun sample** at vertex `b`: `Ls = normalize(L + tan(sun_radius) *
sqrt(ua) * (cos(2 pi ub) e1 + sin(2 pi ub) e2))`, `sun_radius = 1.5 deg`
(knob), `(e1, e2) = onb(L)`, with

```
onb(n): s = n.z >= 0 ? 1 : -1;  a = -1 / (s + n.z);  b = n.x n.y a
        e1 = (1 + s n.x^2 a, s b, -s n.x);  e2 = (b, s + n.y^2 a, -n.y)
```

**Visibility** `vis(p, Ls)`: a shadow ray from `p` along `Ls` (t > 1e-3):
0 if it meets the chrome, matte or small sphere or the logo; 0.45 if it
meets only the glass (M2 opacity 0.55); 1 otherwise (the shore does not
cast).

**Path.** `Lsum = 0`, `thr = (1,1,1)`, `diffuse = false`, then for vertex
`b = 0 .. max_bounces` (`max_bounces = 4`, knob; `b == max_bounces` is the
terminal vertex): find the nearest hit of spheres, logo (M2.2 slab test,
K = 4), opaque shore texel and water plane (`d.y < 0`), as in the
real-time scene, and shade:

- **Sky** (miss): `Lsum += thr * sky(d)`; after a diffuse bounce use
  `sky` without the disc term (`grad + sun_col * 0.4 * glow`: the disc is
  the light the direct term already counts). Stop.
- **Shore**: `Lsum += thr * palette[i]` (preset tint). Stop.
- **Logo**: `Lsum += thr * logo_colour` (M2.2 face/side shading with `L`).
  Stop.
- **Chrome** (and the small chrome): `n` the unit normal. Terminal:
  `Lsum += thr * tint * stripe * sun_col * (0.25 + 0.75 max(0, n.L))`,
  stop. Else `thr *= tint * stripe`, `d = reflect(d, n)`.
- **Glass**: `n` outward. Entering when `dot(d, n) < 0`: `c = -dot(d, n)`,
  `eta = 1/1.5`, normal `n`; else `c = dot(d, n)`, `eta = 1.5`, normal
  `-n`. `k = 1 - eta^2 (1 - c^2)`; `F = 1` if `k < 0`, else
  `schlick(entering ? c : sqrt(k), 0.04)`. Terminal: `Lsum += thr *
  glass_far`, stop. Else with `u = u(6 + 4b)`: `u < F` reflects, otherwise
  refracts (`refract` as M2 with that normal), and `thr *= glass_tint` on
  entering refraction only. The next hit of a ray inside the glass is its
  far side.
- **Water** at `p`: ripple normal as M3 (three waves times the preset
  scale, plus rings, `fade` from `dist = |p - o|`, `o` this ray's origin),
  then gloss (knob `water_roughness = 0.08`):

  ```
  rr = water_roughness * sqrt(u(6+4b));  a = 2 pi u(7+4b)
  n' = normalize(n + (rr cos a, 0, rr sin a))
  r  = reflect(d, n');  if r.y < 0.02: r.y = 0.02, r = normalize(r)
  F  = schlick(max(0, -dot(d, n')), 0.02)
  v  = vis(p, Ls)
  base = water_deep + water_scatter * v
  spec = (preset has water specular) ? max(0, dot(r, Ls))^64 * v : 0
  Lsum += thr * ((1 - F) * base + sun_col * 0.5 * spec)
  ```

  Terminal: `Lsum += thr * F * env(r)` (shore, else `sky(r)`), stop. Else
  `thr *= F`, `d = r`.
- **Matte**: `n`, `Lsum += thr * albedo * sun_col * max(0, dot(n, Ls)) *
  vis(p, Ls)` when `dot(n, Ls) > 0`. Terminal: stop. Else a
  cosine-weighted bounce, `ra = sqrt(u(6+4b))`, `a = 2 pi u(7+4b)`,
  `d = e1 ra cos a + n sqrt(1 - ra^2) + e2 ra sin a` with `(e1, e2) =
  onb(n)`, `thr *= albedo * sky_fill` (`sky_fill = 0.3`, knob: the
  real-time look had a 0.15 ambient; the full dome without it washes the
  matte out), `diffuse = true`.

After a bounce the new origin is `p` (hits need `t > 1e-3`). The path
stops early when `max(thr) < 1/1024` (the reference does the same). The
sample is `min(Lsum, 4.0)` per channel (knob `sample_clamp`).

**Accumulator.** Per pixel one `u32`, r bits 0-10, g 11-21, b 22-31,
fixed point over `[0, 4)`: `r = q_r / 512`, `g = q_g / 512`,
`b = q_b / 256`. Per column `n_col[x]`, the samples each of its pixels
holds. Adding sample `s` to a pixel: `m = decode + (s - decode) /
(n_col + 1)`, then per channel `q = min(max_q, floor(m * scale + u_c))`,
`u_c` from `hash(x, y, n, 63)`: r `(h >> 21) / 2048`, g `((h >> 10) &
2047) / 2048`, b `(h & 1023) / 1024`. After the column, `n_col += 1`.
`begin` stores the decoded real-time frame (`r5 / 31` etc.) with every
`n_col = 0`, so a column's first sample replaces it: until the front
reaches a column it shows the real-time frame.

**Order.** Each pass traces columns 0 to 159 left to right, rows 0 to 127,
so the pass front sweeps across the image. `display()` saturates each mean
to `[0, 1]` and runs `dither.quantise`.

### Reference and check (Track C)

- `tools/reference.py --pt --passes N [--from M]` computes the estimator
  above for passes `M .. N-1` (same RNG, so the same samples), vectorised
  over pixels, and saves the float mean (`.npy`) plus a PNG. Cache
  converged images under `out/pt_ref/`.
- `tools/check_pt.mjs`: sets a view (`debug_set_view`, `debug_set_pt(1)`),
  runs `debug_pt_run`, reads the means from `debug_pt_accum()` and
  compares, in 8-bit units of `[0, 1]` (means saturated to `[0, 1]`):
  1. Same samples: cart after 16 passes against the reference's first 16
     passes: at least 98% of channel values within 3 units, mean absolute
     difference at most 0.5 (float differences flip a few Fresnel and
     gloss choices, nothing else).
  2. Convergence: against the reference with 1024 passes, RMSE at 16, 64
     and 256 passes decreases, `RMSE(64) / RMSE(256) >= 1.6`, and
     `RMSE(256) <= 4.0` units.
  3. Seed: after `pt.begin` and before any column, `display()` with dither
     `none` reproduces the real-time frame exactly.
  Check set: each preset at `t = 0`, `orbit = 0`; sunset at `t = 300`;
  noon at height 1.0.
- `tools/bench_variants.sh --m4`: cut20, badge-bench,
  row 5 sunset, midnight, noon: preset by Select, A at update 100, 1,200
  updates frozen. Gate: every frozen update's calibrated busy time at most
  47.0 ms. Report: passes after 1,200 updates, the update at which
  `done()` (time to 256 passes in seconds at 20 fps), ms per pass.
  Row 6: stick held while frozen (the real-time preview with a table
  rebuild): reported, not gated. Plus M3 rows 1 and 2 again (within
  0.1 ms of M3).

### Tracks

Worktrees off this plan commit, one branch each; each track commits,
the integrator merges. A change needed in another track's file goes in
the final report.

- **A (path tracer)**: new `cart/src/pt.zig`, new `cart/src/arena.zig`,
  `water.zig` (the arena pointer and `invalidate_tables` only). May read
  but not change `scene.zig`, `iris.zig`, `camera.zig`, `math.zig`,
  `shore_data.zig`; small `pub` additions there are allowed if the
  real-time code does not change. Until B lands, a stand-in in its
  branch's `main.zig` is allowed.
- **B (app)**: `cart/src/app.zig`, `main.zig`, `overlay.zig`,
  `tools/scripts/` (m4 scripts). Builds against a stub `pt.zig` in its
  branch until A lands.
- **C (reference, harness)**: `tools/reference.py`, new
  `tools/check_pt.mjs`, `tools/check_render.mjs` (`debug_set_pt(0)`),
  `tools/bench_variants.sh`, `docs/RUNNING.md`.

Integration (me): merge A, B, C; set `wasm_columns_per_update` and
`slice_us` from the bench; check_pt, check_render, check-float, sizes,
bench rows; a freeze GIF and before/after stills in `docs/`; SPEC.md
status; tag `snouty-reflections/m4`; merge to main.

### Done criteria for M4

- A freezes and the image converges on the simulator in every preset;
  stick, Select, B, A, Start behave as above; auto-resume after 60 s.
- check_pt passes on the check set; check_render 24/24 still passes for
  cut20 and half30; `zig build check-float` for every variant.
- Row 5 frozen updates at most 47.0 ms in every preset; rows 1 and 2
  within 0.1 ms of M3; sizes within the limits.

### M4 status

- 2026-09-30: plan written. Question 8: 60 s auto-resume; question 9: DOF
  on, `lens_radius` 0.05.
