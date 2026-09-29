//! The sunset-lake scene, numerically as in PLAN.md "The M1 scene, exactly"
//! and "The M2 scene, exactly". Constants, the M2 knobs, the sky function and
//! the shore texture lookup; tools/reference.py mirrors it.
const std = @import("std");
const math = @import("math.zig");
const shore_data = @import("shore_data.zig");
const variant = @import("variant.zig");
const Vec3 = math.Vec3;
const vec3 = math.vec3;
const splat = math.splat;

/// Unit direction toward the sun.
pub const sun_dir: Vec3 = blk: {
    const l = vec3(0.40, 0.30, -0.85);
    const len: f32 = @floatCast(@sqrt(@as(f64, 0.40 * 0.40 + 0.30 * 0.30 + 0.85 * 0.85)));
    break :blk l / splat(len);
};
pub const sun_col = vec3(1.00, 0.85, 0.60);

pub const sky_horizon = vec3(1.00, 0.55, 0.25);
pub const sky_mid = vec3(0.85, 0.35, 0.40);
pub const sky_zenith = vec3(0.15, 0.20, 0.45);

pub const sphere_centre = vec3(0.0, 1.0, 0.0);
/// Radius 1.0: the normal is simply p - centre and the quadratic's c term is
/// |oc|^2 - 1.
pub const sphere_tint = vec3(0.95, 0.93, 0.90);

/// Glass sphere: centre, radius, IOR 1.5, transmission tint, Fresnel f0.
pub const glass_centre = vec3(-1.9, 0.75, 1.3);
pub const glass_radius: f32 = 0.7;
pub const glass_ior: f32 = 1.5;
pub const glass_tint = vec3(0.90, 0.96, 1.00);
pub const glass_f0: f32 = 0.04;
/// Colour of a depth-2 glass hit (constant, only ever a few pixels).
pub const glass_far = vec3(0.45, 0.33, 0.35);

pub const water_deep = vec3(0.02, 0.08, 0.14);
/// Sunlight scattered in the water, scaled by the shadow: 0.08 * sun_col.
pub const water_scatter = sun_col * splat(0.08);
/// Specular highlight colour on the water: 0.5 * sun_col.
pub const water_spec_col = sun_col * splat(0.5);
/// Colour of a depth-2 sphere hit per unit of lambert: tint * sun_col.
pub const sphere_lit_col = sphere_tint * sun_col;
pub const water_f0: f32 = 0.02;

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

/// A sphere's shadow on the water: the sun-side cylinder of radius
/// sqrt(1.21) * rs around the sphere, cut by y = 0, is an ellipse; x0..z1 is
/// a padded box around the whole ellipse (the shadow is exactly 1 outside
/// it), folded at comptime.
pub const Caster = struct {
    c: Vec3,
    /// smoothstep edges 0.72 rs^2 and 1.21 rs^2 on q2.
    q2_lo: f32,
    q2_hi: f32,
    opacity: f32,
    x0: f32,
    x1: f32,
    z0: f32,
    z1: f32,
};

fn caster(c: Vec3, rs: f32, opacity: f32) Caster {
    const l = sun_dir;
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
        .opacity = opacity,
        .x0 = ax - hx,
        .x1 = ax + hx,
        .z0 = az - hz,
        .z1 = az + hz,
    };
}

/// Chrome (opacity 1.0) and glass (0.55, only when glass_enabled).
pub const casters = if (glass_enabled) [2]Caster{
    caster(sphere_centre, 1.0, 1.0),
    caster(glass_centre, glass_radius, 0.55),
} else [1]Caster{
    caster(sphere_centre, 1.0, 1.0),
};

/// Shore plane z = shore_z facing -z, x in (-16, 16], y in [0, 4), 8 texels
/// per unit (PLAN.md "Shore hit").
pub const shore_z: f32 = 14.0;
pub const shore_half_width: f32 = 16.0;
pub const shore_height: f32 = 4.0;
pub const shore_texels_per_unit: f32 = 8.0;

comptime {
    if (shore_data.width != 256 or shore_data.height != 32) @compileError("shore texture must be 256 x 32");
}

/// shore_data.palette as vectors (linear RGB, already lit).
const shore_palette: [16]Vec3 = blk: {
    var t: [16]Vec3 = undefined;
    for (shore_data.palette, 0..) |c, i| t[i] = vec3(c[0], c[1], c[2]);
    break :blk t;
};

/// Colour of shore texel (u, v), u in 0..255, v in 0..31, or null if
/// transparent (index 0). Two 4-bit indices per byte, low nibble even u.
pub inline fn shore_texel(u: u32, v: u32) ?Vec3 {
    const byte = shore_data.texels[v * 128 + (u >> 1)];
    const i = (byte >> @intCast((u & 1) * 4)) & 15;
    if (i == 0) return null;
    return shore_palette[i];
}

/// The gradient as an affine function of h per segment, grad = a + b * h,
/// with a and b folded at comptime: lerp(horizon, mid, h / 0.3) for h < 0.3,
/// lerp(mid, zenith, (h - 0.3) / 0.7) above.
const grad_lo_b = (sky_mid - sky_horizon) * splat(1.0 / 0.3);
const grad_lo_a = sky_horizon;
const grad_hi_b = (sky_zenith - sky_mid) * splat(1.0 / 0.7);
const grad_hi_a = sky_mid - grad_hi_b * splat(0.3);

/// sun_col scaled by the sun disc and glow weights.
const sun_disc_col = sun_col;
const sun_glow_col = sun_col * splat(0.4);

/// Sky colour for unit direction `d`: two-segment vertical gradient plus the
/// sun disc and glow. The spec clamps h = d.y to [0, 1]; the tracer only
/// calls sky for d.y >= 0 (downward rays always hit the water, whose
/// reflections are forced to r.y > 0) and |d| = 1, so the clamp is a no-op
/// and is left out.
pub inline fn sky(d: Vec3) Vec3 {
    return sky_h(d, d[1]);
}

/// sky for any unit direction, with the spec's clamp of h to [0, 1] (only
/// glass_secondary = .env looks up downward directions).
pub inline fn sky_clamped(d: Vec3) Vec3 {
    return sky_h(d, @max(0.0, d[1]));
}

inline fn sky_h(d: Vec3, h: f32) Vec3 {
    const grad = if (h < 0.3)
        grad_lo_a + grad_lo_b * splat(h)
    else
        grad_hi_a + grad_hi_b * splat(h);
    const s = math.dot(d, sun_dir);
    if (s <= 0.90) return grad; // both smoothsteps are zero below 0.90
    const disc = smoothstep_k(0.9950, 0.9995, s);
    var glow = smoothstep_k(0.90, 1.00, s);
    glow = glow * glow;
    return grad + sun_disc_col * splat(disc) + sun_glow_col * splat(glow);
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
