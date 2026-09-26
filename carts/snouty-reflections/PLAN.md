# Plan: M0 scaffold and M1 "Tracer on hardware"

Companion to `SPEC.md`. This file is the contract between the parallel
tracks; when it and the spec disagree, this file wins for M1 and the spec
is updated afterwards.

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
