# Plan: M0 scaffold, M1 "Tracer on hardware", M2 "Materials and shore"

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
