//! The M1 sunset-lake scene, numerically as in PLAN.md "The M1 scene,
//! exactly". Constants plus the sky function; tools/reference.py mirrors it.
const std = @import("std");
const math = @import("math.zig");
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

pub const water_deep = vec3(0.02, 0.08, 0.14);
pub const water_f0: f32 = 0.02;

/// Minimum reflected-ray elevation off the water, so reflections never dip
/// below the plane.
pub const min_reflect_y: f32 = 0.02;

/// Sky colour for unit direction `d`: two-segment vertical gradient plus the
/// sun disc and glow. Divisions by constants are written as multiplications
/// by comptime reciprocals.
pub inline fn sky(d: Vec3) Vec3 {
    const h = math.clamp01(d[1]);
    const grad = if (h < 0.3)
        math.lerp(sky_horizon, sky_mid, h * (1.0 / 0.3))
    else
        math.lerp(sky_mid, sky_zenith, (h - 0.3) * (1.0 / 0.7));
    const s = math.dot(d, sun_dir);
    if (s <= 0.90) return grad; // both smoothsteps are zero below 0.90
    const disc = smoothstep_k(0.9950, 0.9995, s);
    var glow = smoothstep_k(0.90, 1.00, s);
    glow = glow * glow;
    return grad + sun_col * splat(disc + 0.4 * glow);
}

/// smoothstep with comptime edges, so the divide becomes a multiply.
inline fn smoothstep_k(comptime e0: f32, comptime e1: f32, x: f32) f32 {
    const inv: f32 = comptime 1.0 / (e1 - e0);
    const t = math.clamp01((x - e0) * inv);
    return t * t * (3.0 - 2.0 * t);
}

test "sun_dir is unit" {
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), math.length(sun_dir), 1e-6);
}
