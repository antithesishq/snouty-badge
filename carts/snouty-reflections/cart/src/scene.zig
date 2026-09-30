//! The sunset-lake scene, numerically as in PLAN.md "The M1 scene, exactly"
//! and "The M2 scene, exactly". Constants, the M2 knobs, the sky function and
//! the shore texture lookup; tools/reference.py mirrors it.
const std = @import("std");
const math = @import("math.zig");
const shore_data = @import("shore_data.zig");
const variant = @import("variant.zig");
const build_options = @import("build_options");
const Vec3 = math.Vec3;
const vec3 = math.vec3;
const splat = math.splat;

/// Scene presets (PLAN.md M3 "Presets"), selected at runtime; every variant
/// has all four.
pub const Preset = enum(u32) { sunset = 0, midnight = 1, noon = 2, storm = 3 };
pub const preset_count = 4;

/// What occupies the second sphere slot, centre (-1.9, 0.75, 1.3), r 0.7:
/// the glass sphere (sunset, in the variants that have glass), the matte
/// sphere (midnight, noon) or nothing.
pub const Slot2 = enum(u8) { none, glass, matte };

/// Water shadows of a preset: the variant's water_shadows (sunset), exact
/// per primary water hit (noon), or none.
pub const PresetShadows = enum { variant, primary_exact, off };

/// A preset's inputs, as in the PLAN table.
const PresetDef = struct {
    l: [3]comptime_float,
    sun_col: Vec3,
    /// Sun (or moon) disc and glow in the sky.
    disc: bool = true,
    /// Sun specular on the water.
    water_spec: bool = true,
    horizon: Vec3,
    mid: Vec3,
    zenith: Vec3,
    /// Scales the amplitude of all three waves.
    ripple: f32 = 1.0,
    /// Multiplies the shore palette, clamped to 1.
    shore_tint: Vec3 = vec3(1.0, 1.0, 1.0),
    slot2: Slot2 = .none,
    third: bool = false,
    shadows: PresetShadows = .off,
};

const preset_defs = [preset_count]PresetDef{
    .{ // sunset
        .l = .{ 0.40, 0.30, -0.85 },
        .sun_col = vec3(1.00, 0.85, 0.60),
        .horizon = vec3(1.00, 0.55, 0.25),
        .mid = vec3(0.85, 0.35, 0.40),
        .zenith = vec3(0.15, 0.20, 0.45),
        .slot2 = if (variant.glass_enabled) .glass else .none,
        .shadows = .variant,
    },
    .{ // midnight
        .l = .{ -0.40, 0.35, -0.85 },
        .sun_col = vec3(0.55, 0.62, 0.80),
        .horizon = vec3(0.06, 0.08, 0.18),
        .mid = vec3(0.03, 0.04, 0.12),
        .zenith = vec3(0.01, 0.01, 0.05),
        .ripple = 0.5,
        .shore_tint = vec3(0.45, 0.50, 0.70),
        .slot2 = .matte,
    },
    .{ // noon
        .l = .{ 0.30, 0.85, -0.43 },
        .sun_col = vec3(1.00, 0.97, 0.92),
        .horizon = vec3(0.70, 0.82, 0.95),
        .mid = vec3(0.45, 0.65, 0.92),
        .zenith = vec3(0.20, 0.40, 0.85),
        .ripple = 0.8,
        .shore_tint = vec3(1.05, 1.02, 1.00),
        .slot2 = .matte,
        .third = noon_third_sphere,
        .shadows = if (noon_shadows) .primary_exact else .off,
    },
    .{ // storm
        .l = .{ 0.40, 0.30, -0.85 },
        .sun_col = vec3(0.40, 0.40, 0.45),
        .disc = false,
        .water_spec = false,
        .horizon = vec3(0.35, 0.36, 0.40),
        .mid = vec3(0.25, 0.26, 0.30),
        .zenith = vec3(0.12, 0.13, 0.16),
        .ripple = 2.5,
        .shore_tint = vec3(0.50, 0.50, 0.55),
    },
};

/// The sunset preset's values under their M2 names (the M2.2 scene).
pub const sun_dir: Vec3 = unit(preset_defs[0].l);
pub const sun_col = preset_defs[0].sun_col;
pub const sky_mid = preset_defs[0].mid;

/// normalize(l) in f64, rounded once.
fn unit(comptime l: [3]comptime_float) Vec3 {
    const len: f32 = @floatCast(@sqrt(@as(f64, l[0] * l[0] + l[1] * l[1] + l[2] * l[2])));
    return vec3(@floatCast(l[0]), @floatCast(l[1]), @floatCast(l[2])) / splat(len);
}

/// Sphere geometry. Spheres move only vertically (the bob), so x, z and the
/// radius stay comptime and the centre height is a per-frame value; y0 is
/// the rest height (M2.2, motion off).
pub const SphereGeom = struct { x: f32, y0: f32, z: f32, r: f32, phase: f32 };
/// The chrome sphere. Radius 1.0: the normal is simply p - centre.
pub const chrome = SphereGeom{ .x = 0.0, .y0 = 1.0, .z = 0.0, .r = 1.0, .phase = 0.0 };
/// The second slot: glass or matte (Slot2).
pub const slot2 = SphereGeom{ .x = -1.9, .y0 = 0.75, .z = 1.3, .r = 0.7, .phase = 0.5 };
/// The small chrome sphere (noon, knob noon_third_sphere).
pub const small = SphereGeom{ .x = 1.8, .y0 = 0.5, .z = 1.6, .r = 0.5, .phase = 0.25 };

pub const sphere_centre = vec3(chrome.x, chrome.y0, chrome.z);
pub const sphere_tint = vec3(0.95, 0.93, 0.90);

/// Glass sphere: centre, radius, IOR 1.5, transmission tint, Fresnel f0.
pub const glass_centre = vec3(slot2.x, slot2.y0, slot2.z);
pub const glass_radius: f32 = slot2.r;
pub const glass_ior: f32 = 1.5;
pub const glass_tint = vec3(0.90, 0.96, 1.00);
pub const glass_f0: f32 = 0.04;
/// Colour of a depth-2 glass hit (constant, only ever a few pixels).
pub const glass_far = vec3(0.45, 0.33, 0.35);

/// Matte sphere albedo (midnight, noon, in the glass slot).
pub const matte_albedo = vec3(0.60, 0.55, 0.50);

pub const water_deep = vec3(0.02, 0.08, 0.14);
/// Sunlight scattered in the water, scaled by the shadow: 0.08 * the M2
/// sun_col, the same in every preset.
pub const water_scatter = sun_col * splat(0.08);
pub const water_f0: f32 = 0.02;

/// A preset's comptime-derived values (the M2.2 folds, per preset).
const Consts = struct {
    sun_dir: Vec3,
    sun_col: Vec3,
    /// The gradient as an affine function of h per segment, grad = a + b * h:
    /// lerp(horizon, mid, h / 0.3) for h < 0.3, lerp(mid, zenith, (h - 0.3)
    /// / 0.7) above.
    grad_lo_a: Vec3,
    grad_lo_b: Vec3,
    grad_hi_a: Vec3,
    grad_hi_b: Vec3,
    /// sun_col scaled by the disc and glow weights.
    sun_disc_col: Vec3,
    sun_glow_col: Vec3,
    /// dot(d, L) at or below which the sky has neither disc nor glow: 0.90,
    /// or 2 (never exceeded) for a preset without them.
    sky_cut: f32,
    /// The M2 constant in every preset.
    water_scatter: Vec3,
    /// Specular highlight colour on the water: 0.5 * sun_col (zero without).
    water_spec_col: Vec3,
    /// water_deep + water_scatter: the unshadowed base.
    water_base: Vec3,
    /// Colour of a depth-2 chrome hit per unit of lambert: tint * sun_col.
    sphere_lit_col: Vec3,
    /// Matte colour = matte_amb + matte_sun * max(0, dot(n, L)).
    matte_amb: Vec3,
    matte_sun: Vec3,
    shore_palette: [16]Vec3,
    slot2: Slot2,
    third: bool,
    shadows: PresetShadows,
};

fn consts(comptime def: PresetDef) Consts {
    const grad_lo_b = (def.mid - def.horizon) * splat(1.0 / 0.3);
    const grad_hi_b = (def.zenith - def.mid) * splat(1.0 / 0.7);
    var pal: [16]Vec3 = undefined;
    for (shore_data.palette, 0..) |c, i| {
        const v = vec3(c[0], c[1], c[2]);
        pal[i] = @min(splat(1.0), v * def.shore_tint);
    }
    return .{
        .sun_dir = unit(def.l),
        .sun_col = def.sun_col,
        .grad_lo_a = def.horizon,
        .grad_lo_b = grad_lo_b,
        .grad_hi_a = def.mid - grad_hi_b * splat(0.3),
        .grad_hi_b = grad_hi_b,
        .sun_disc_col = if (def.disc) def.sun_col else splat(0.0),
        .sun_glow_col = if (def.disc) def.sun_col * splat(0.4) else splat(0.0),
        .sky_cut = if (def.disc) 0.90 else 2.0,
        .water_scatter = water_scatter,
        .water_spec_col = if (def.water_spec) def.sun_col * splat(0.5) else splat(0.0),
        .water_base = water_deep + water_scatter,
        .sphere_lit_col = sphere_tint * def.sun_col,
        .matte_amb = matte_albedo * (def.mid * splat(0.15)),
        .matte_sun = matte_albedo * def.sun_col,
        .shore_palette = pal,
        .slot2 = def.slot2,
        .third = def.third,
        .shadows = def.shadows,
    };
}

pub const preset_consts: [preset_count]Consts = blk: {
    var t: [preset_count]Consts = undefined;
    for (preset_defs, 0..) |def, i| t[i] = consts(def);
    break :blk t;
};
const consts_sunset = preset_consts[0];
const consts_midnight = preset_consts[1];
const consts_noon = preset_consts[2];
const consts_storm = preset_consts[3];

/// A preset's values at runtime. A switch over four separate constants, not
/// preset_consts[i]: the thumb build indexed that array of vector structs
/// with a stride that did not match its layout (presets 1 to 3 read the
/// wrong bytes on the badge build only; the wasm was right).
pub fn consts_of(preset: Preset) *const Consts {
    return switch (preset) {
        .sunset => &consts_sunset,
        .midnight => &consts_midnight,
        .noon => &consts_noon,
        .storm => &consts_storm,
    };
}

/// Ripple amplitude scale per preset (water.zig folds it into the waves).
pub const ripple_scale: [preset_count]f32 = blk: {
    var t: [preset_count]f32 = undefined;
    for (preset_defs, 0..) |def, i| t[i] = def.ripple;
    break :blk t;
};

/// The per-frame scene: a preset's values with the attract fade folded into
/// every colour the tracer emits (so a faded frame costs nothing extra: the
/// fade scales the traced colour before saturation, which is where the spec
/// puts it), plus the moving parts (sun direction, sphere heights).
pub const Frame = struct {
    sun_dir: Vec3,
    /// Faded sun colour (the logo's highlight).
    sun_col: Vec3,
    grad_lo_a: Vec3,
    grad_lo_b: Vec3,
    grad_hi_a: Vec3,
    grad_hi_b: Vec3,
    sun_disc_col: Vec3,
    sun_glow_col: Vec3,
    water_deep: Vec3,
    water_scatter: Vec3,
    water_spec_col: Vec3,
    water_base: Vec3,
    sphere_lit_col: Vec3,
    glass_far: Vec3,
    matte_amb: Vec3,
    matte_sun: Vec3,
    shore_palette: [16]Vec3,
    sky_cut: f32,
    /// The three spheres' centre heights.
    chrome: Ball,
    slot2: Ball,
    small: Ball,
    slot2_kind: Slot2,
    third: bool,
    preset: Preset,
};

/// A sphere's per-frame centre height y and k = y^2 - r^2 (the water-origin
/// quadratic's constant term).
pub const Ball = struct {
    y: f32,
    k: f32,

    pub fn at(comptime g: SphereGeom, y: f32) Ball {
        return .{ .y = y, .k = y * y - g.r * g.r };
    }
};

/// The frame's scene values. `sun` is the (drifted) direction to the sun,
/// `ys` the sphere centre heights.
pub fn frame_at(preset: Preset, fade: f32, sun: Vec3, ys: [3]f32) Frame {
    const c = consts_of(preset);
    const f = splat(fade);
    var fr: Frame = .{
        .sun_dir = sun,
        .sun_col = c.sun_col * f,
        .grad_lo_a = c.grad_lo_a * f,
        .grad_lo_b = c.grad_lo_b * f,
        .grad_hi_a = c.grad_hi_a * f,
        .grad_hi_b = c.grad_hi_b * f,
        .sun_disc_col = c.sun_disc_col * f,
        .sun_glow_col = c.sun_glow_col * f,
        .water_deep = water_deep * f,
        .water_scatter = c.water_scatter * f,
        .water_spec_col = c.water_spec_col * f,
        .water_base = c.water_base * f,
        .sphere_lit_col = c.sphere_lit_col * f,
        .glass_far = glass_far * f,
        .matte_amb = c.matte_amb * f,
        .matte_sun = c.matte_sun * f,
        .shore_palette = undefined,
        .sky_cut = c.sky_cut,
        .chrome = .at(chrome, ys[0]),
        .slot2 = .at(slot2, ys[1]),
        .small = .at(small, ys[2]),
        .slot2_kind = c.slot2,
        .third = c.third,
        .preset = preset,
    };
    for (&fr.shore_palette, &c.shore_palette) |*d, s| d.* = s * f;
    return fr;
}

/// Minimum reflected-ray elevation off the water, so reflections never dip
/// below the plane.
pub const min_reflect_y: f32 = 0.02;

// M2 knobs. Turned in this order if the full feature set is over budget
// (PLAN.md "Knobs"). Knobs 2 and 4 and the glass sphere itself are set per
// perf variant in variant.zig (PLAN.md "M2.1 Perf variants"). Costs are calibrated badge-bench busy ms on the two
// heaviest orbit frames, 500 (glass nearest the camera, ~5600 glass pixels)
// and 558 (worst without glass), each knob applied on top of the ones
// above it. Full feature set: 72.7 / 69.3 ms; without glass 46.2 / 48.3.

pub const GlassMode = enum { real, fake };
/// real: the transmitted ray leaves from the exit point of the chord, bent
/// twice. fake: no exit intersection, the once-bent ray leaves from the
/// entry point. fake saves nothing: -0.3 / +1.8 ms (its rays aim steeper
/// into the water, which costs more than the exit point saves).
pub const glass_mode: GlassMode = .real;

pub const WaterShadows = enum { all, primary_only, off };
/// Shadows of both spheres on the water: every water hit, depth-0 hits only,
/// or none. primary_only -2.1 / -1.7 ms, off another -1.4 / -1.3 ms.
pub const water_shadows: WaterShadows = variant.water_shadows;

pub const GlassSecondary = enum { full, env };
/// full: glass seen at depth 1 traces its reflected and transmitted rays.
/// env: it looks both up in env() (shore or sky) instead. +0.7 / +0.1 ms
/// (only ~450 such pixels; within the model's layout noise).
pub const glass_secondary: GlassSecondary = .full;

pub const GlassPrimary = enum { full, env };
/// Knob 4 (PLAN.md M2.1, full15): env makes the glass seen by primary rays
/// look both rays up in env_flat (env() upward, flat unrippled water
/// downward) instead of tracing them. With knobs 1-3 at their defaults:
/// 50.5 / 56.6 ms.
pub const glass_primary: GlassPrimary = variant.glass_primary;

/// false (cut20): no glass sphere anywhere, not even as a shadow caster.
pub const glass_enabled: bool = variant.glass_enabled;

// M2.2 knobs 5-7: which rays see the Iris logo (iris.zig; PLAN.md M2.2
// "Knobs"). Primary rays always do; rays leaving the glass never. Turned
// 7 to 3, then 5 off, then 6 off if cut20 is over budget; variant.zig sets
// them per variant. Costs are calibrated badge-bench busy ms, cut20, one
// orbit, worst / mean: taller shore alone 46.65 / 43.37; the logo seen by
// primary rays 46.46 / 43.70 (K = 4); + water reflections 52.95 / 46.80;
// + chrome reflections 54.01 / 47.90. Then K = 3: 53.77 / 47.90, chrome
// off: 52.84 / 46.84, water off: 46.33 / 43.69 (shipped). So knob 5 costs
// ~1.1 ms, knob 6 ~6.5 ms at its worst frame (3.1 mean), K = 4 vs 3 ~0.2.

/// Knob 5: rays reflected off the chrome sphere show the logo.
pub const iris_in_chrome: bool = variant.iris_in_chrome;
/// Knob 6: rays reflected off the water, at any depth, show the logo.
pub const iris_in_water: bool = variant.iris_in_water;
/// Knob 7: K, the mask samples along the ray's path through the slab
/// (minimum 2: the slab entry and exit).
pub const iris_samples: u32 = variant.iris_samples;

comptime {
    if (iris_samples < 2) @compileError("iris_samples must be at least 2");
}

// M3 knobs (PLAN.md M3 "Knobs"), in cut order: if a cut20 bench row is over
// 47.0 ms, rings (per preset), then stripes, noon_shadows,
// noon_third_sphere, sun_drift. Never cut the free camera, presets or bob
// without asking Adrian. Calibrated busy ms, cut20 (PLAN.md "M3 status"):
// rings 12.5 in sunset (8.9 when active, 3.6 for the code's presence even
// with no ring: cut20 compiles them out); stripes 1.1 in sunset, nothing
// measurable in midnight or noon (kept); noon_shadows 6.9 and
// noon_third_sphere 6.6 in noon (both off in cut20); sun_drift 0 (kept).

/// Master switch for bob, sun drift, rings and stripes. false renders the
/// M2.2 scene bit for bit (sunset, default height, fade 1): the legacy
/// identity check. Off in the -Dreflections_bench=motion_off build.
pub const motion: bool = build_options.reflections_bench != .motion_off;
/// Circular ripples around each sphere, per preset (sunset, midnight, noon,
/// storm); variant.zig turns them off where the budget does not allow them.
pub const rings: [preset_count]bool = @splat(variant.rings);
/// Whether any preset has rings: without, the ring code is not compiled at
/// all (its mere presence in the water normal costs ~3.5 ms in cut20).
pub const any_rings = motion and blk: {
    var any = false;
    for (rings) |r| any = any or r;
    break :blk any;
};
/// Faint rotating stripes on the chrome sphere, per preset.
pub const stripes: [preset_count]bool = .{ true, true, true, true };
pub const any_stripes = motion and blk: {
    var any = false;
    for (stripes) |x| any = any or x;
    break :blk any;
};
/// Noon's exact water shadows on primary water hits (variant.zig: off in
/// cut20).
pub const noon_shadows: bool = variant.noon_shadows;
/// Noon's small chrome sphere (variant.zig: off in cut20).
pub const noon_third_sphere: bool = variant.noon_third_sphere;
/// The sun's slow swing about +y.
pub const sun_drift: bool = true;

/// Bob: centre y = y0 + bob_lift + bob_amp * sin_turns(s / bob_period + phase).
pub const bob_lift: f32 = 0.2;
pub const bob_amp: f32 = 0.2;
pub const bob_period: f32 = 10.0;
/// Sun drift: L rotated about +y by drift_deg * sin_turns(s / drift_period).
pub const drift_deg: f32 = 8.0;
pub const drift_period: f32 = 60.0;
/// Stripes: chrome colour times 1 - stripe_depth where fract(3 (n.x cos a +
/// n.z sin a)) < 0.5, a = s / stripe_period turns.
pub const stripe_depth: f32 = 0.12;
pub const stripe_freq: f32 = 3.0;
pub const stripe_period: f32 = 20.0;

/// A sphere's shadow on the water: the sun-side cylinder of radius
/// sqrt(1.21) * rs around the sphere, cut by y = 0, is an ellipse; x0..z1 is
/// a padded box around the whole ellipse (the shadow is exactly 1 outside
/// it), folded at comptime.
pub const Caster = struct {
    c: Vec3,
    /// smoothstep edges 0.72 rs^2 and 1.21 rs^2 on q2.
    q2_lo: f32,
    q2_hi: f32,
    /// 1 / (q2_hi - q2_lo).
    q2_inv: f32,
    opacity: f32,
    x0: f32,
    x1: f32,
    z0: f32,
    z1: f32,
};

pub fn caster(c: Vec3, rs: f32, opacity: f32, l: Vec3) Caster {
    // Axis hit on y = 0, then the ellipse's semi-axes: R across the sun's
    // horizontal direction e and R / L.y along it.
    const s0 = c[1] / l[1];
    const ax = c[0] - l[0] * s0;
    const az = c[2] - l[2] * s0;
    const rr = 1.1 * rs;
    const lh = @sqrt(l[0] * l[0] + l[2] * l[2]);
    const ex = l[0] / lh;
    const ez = l[2] / lh;
    const iy2 = 1.0 / (l[1] * l[1]);
    const pad = 0.05;
    const hx = rr * @sqrt(ez * ez + ex * ex * iy2) + pad;
    const hz = rr * @sqrt(ex * ex + ez * ez * iy2) + pad;
    return .{
        .c = c,
        .q2_lo = 0.72 * rs * rs,
        .q2_hi = 1.21 * rs * rs,
        .q2_inv = 1.0 / (1.21 * rs * rs - 0.72 * rs * rs),
        .opacity = opacity,
        .x0 = ax - hx,
        .x1 = ax + hx,
        .z0 = az - hz,
        .z1 = az + hz,
    };
}

pub const glass_opacity: f32 = 0.55;

/// The sunset scene's casters at rest: chrome (opacity 1.0) and glass (0.55,
/// only when glass_enabled); the static shadow map (motion off) samples
/// them.
pub const casters = if (glass_enabled) [2]Caster{
    caster(sphere_centre, 1.0, 1.0, sun_dir),
    caster(glass_centre, glass_radius, glass_opacity, sun_dir),
} else [1]Caster{
    caster(sphere_centre, 1.0, 1.0, sun_dir),
};

/// Shore plane z = shore_z facing -z, x in (-16, 16], y in [0, shore_height),
/// 8 texels per unit (PLAN.md "Shore hit"; M2.2: 48 rows, y in [0, 6)). The
/// height follows the generated texture.
pub const shore_z: f32 = 14.0;
pub const shore_half_width: f32 = 16.0;
pub const shore_texels_per_unit: f32 = 8.0;
pub const shore_rows: u32 = shore_data.height;
pub const shore_height: f32 = @as(f32, @floatFromInt(shore_rows)) / shore_texels_per_unit;
/// Bytes per texel row: two 4-bit indices per byte.
const shore_stride = shore_data.width / 2;

comptime {
    if (shore_data.width != 256) @compileError("shore texture must be 256 texels wide");
    if (shore_data.texels.len != shore_stride * shore_rows) @compileError("shore texel file does not match width x height");
}

/// Colour of shore texel (u, v), u in 0..255, v in 0..shore_rows - 1, or null if
/// transparent (index 0). Two 4-bit indices per byte, low nibble even u.
pub inline fn shore_texel(fr: *const Frame, u: u32, v: u32) ?Vec3 {
    const byte = shore_data.texels[v * shore_stride + (u >> 1)];
    const i = (byte >> @intCast((u & 1) * 4)) & 15;
    if (i == 0) return null;
    return fr.shore_palette[i];
}

/// Sky colour for unit direction `d`: two-segment vertical gradient plus the
/// sun disc and glow. The spec clamps h = d.y to [0, 1]; the tracer only
/// calls sky for d.y >= 0 (downward rays always hit the water, whose
/// reflections are forced to r.y > 0) and |d| = 1, so the clamp is a no-op
/// and is left out.
pub inline fn sky(fr: *const Frame, d: Vec3) Vec3 {
    return sky_h(fr, d, d[1]);
}

/// sky for any unit direction, with the spec's clamp of h to [0, 1] (only
/// glass_secondary = .env looks up downward directions).
pub inline fn sky_clamped(fr: *const Frame, d: Vec3) Vec3 {
    return sky_h(fr, d, @max(0.0, d[1]));
}

inline fn sky_h(fr: *const Frame, d: Vec3, h: f32) Vec3 {
    const grad = if (h < 0.3)
        fr.grad_lo_a + fr.grad_lo_b * splat(h)
    else
        fr.grad_hi_a + fr.grad_hi_b * splat(h);
    const s = math.dot(d, fr.sun_dir);
    if (s <= fr.sky_cut) return grad; // both smoothsteps are zero below 0.90
    const disc = smoothstep_k(0.9950, 0.9995, s);
    var glow = smoothstep_k(0.90, 1.00, s);
    glow = glow * glow;
    return grad + fr.sun_disc_col * splat(disc) + fr.sun_glow_col * splat(glow);
}

/// smoothstep with comptime edges, so the divide becomes a multiply.
pub inline fn smoothstep_k(comptime e0: f32, comptime e1: f32, x: f32) f32 {
    const inv: f32 = comptime 1.0 / (e1 - e0);
    const t = math.clamp01((x - e0) * inv);
    return t * t * (3.0 - 2.0 * t);
}

test "sun_dir is unit" {
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), math.length(sun_dir), 1e-6);
}
