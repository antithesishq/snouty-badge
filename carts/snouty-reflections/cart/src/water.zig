//! Ripple normal for the water plane y = 0 (PLAN.md table of three waves).
//! Only the gradient of the height field is used; the plane stays flat.
const std = @import("std");
const math = @import("math.zig");
const camera = @import("camera.zig");
const Vec3 = math.Vec3;

const Wave = struct { a: f32, kx: f32, kz: f32, w: f32 };

pub const waves = [3]Wave{
    .{ .a = 0.020, .kx = 0.90, .kz = 0.35, .w = 0.55 },
    .{ .a = 0.012, .kx = -0.45, .kz = 0.80, .w = 0.80 },
    .{ .a = 0.006, .kx = 1.70, .kz = -1.20, .w = 1.30 },
};

/// A_i * k_i * 2pi, folded at comptime.
const gx: [3]f32 = blk: {
    var g: [3]f32 = undefined;
    for (waves, 0..) |wv, i| g[i] = wv.a * wv.kx * (2.0 * std.math.pi);
    break :blk g;
};
const gz: [3]f32 = blk: {
    var g: [3]f32 = undefined;
    for (waves, 0..) |wv, i| g[i] = wv.a * wv.kz * (2.0 * std.math.pi);
    break :blk g;
};

/// Distance fade of the ripples: g * g with g = 1 / (1 + fade_k * dist)
/// (M2; the square cuts the horizon moire).
pub const fade_k = 0.05;

/// Primary rays that go down (rows >= camera.first_water_row) hit the water
/// at a distance that does not depend on the frame: the eye height is fixed
/// and the ray's y component depends only on the row. So the hit is
/// p = eye + w * primary_t[row] for the unnormalised ray w = fwd + right*u +
/// up*v, and the fade is a per-pixel constant; both folded at comptime in
/// f64. primary_fade is indexed [camera.half_column(x)][y - first_water_row]
/// (80 x 86 f32, 27.5 KB).
pub const primary_t: [camera.water_rows]f32 = blk: {
    var t: [camera.water_rows]f32 = undefined;
    for (0..camera.water_rows) |i| {
        const v: f64 = camera.v_table[camera.first_water_row + i];
        t[i] = @floatCast(-@as(f64, camera.orbit_height) / (camera.basis_y64 + camera.basis_h64 * v));
    }
    break :blk t;
};
pub const primary_fade: [camera.width / 2][camera.water_rows]f32 = blk: {
    @setEvalBranchQuota(200000);
    var t: [camera.width / 2][camera.water_rows]f32 = undefined;
    for (0..camera.width / 2) |x| {
        const u: f64 = camera.u_table[x];
        for (0..camera.water_rows) |i| {
            const v: f64 = camera.v_table[camera.first_water_row + i];
            const dist = -@as(f64, camera.orbit_height) / (camera.basis_y64 + camera.basis_h64 * v) *
                @sqrt(1.0 + u * u + v * v);
            if (dist > 1e5) @compileError("primary water hit beyond sin_turns range");
            const g = 1.0 / (1.0 + fade_k * dist);
            t[x][i] = @floatCast(g * g);
        }
    }
    break :blk t;
};

/// Per-frame phase offsets (fract(w_i * t) + 1/4) * 1024, in sine-table
/// steps: the quarter turn turns the table sine into the cosine the gradient
/// needs, and the power-of-two scale (folded into k too) saves the per-wave
/// multiply in the lookup without changing a bit of the result.
pub const Phases = [3]f32;
const steps: f32 = math.sin_table_len;

pub fn phases_at_frame(frame: u32) Phases {
    // t = frame / 20 s. The f32 product is exact enough for any frame below
    // 2^24; fract keeps the runtime phase argument small.
    const t = @as(f32, @floatFromInt(frame)) * (1.0 / 20.0);
    var ph: Phases = undefined;
    inline for (waves, 0..) |wv, i| ph[i] = (math.fract(wv.w * t) + 0.25) * steps;
    return ph;
}

/// Perturbed unit normal at water point `p`. `fade` is g * g, g = 1 / (1 +
/// fade_k * dist) for the distance from the ray origin; the tracer derives g
/// from the same reciprocal as the hit distance.
/// `p` must satisfy |p.x|, |p.z| < 2e5 (sin_turns range); the tracer clamps
/// the hit distance to guarantee it.
pub inline fn normal(p: Vec3, fade: f32, ph: Phases) Vec3 {
    var dx: f32 = 0.0;
    var dz: f32 = 0.0;
    inline for (waves, 0..) |wv, i| {
        // cos(k.p + w t): ph carries the quarter turn; all in table steps.
        const c = math.sin_steps((wv.kx * steps) * p[0] + (wv.kz * steps) * p[2] + ph[i]);
        dx += gx[i] * c;
        dz += gz[i] * c;
    }
    // math.renormalize of (nx, 1, nz), with its 1.5 - 0.5 * (nx^2 + 1 + nz^2)
    // written as 1 - 0.5 * (nx^2 + nz^2).
    const nx = -fade * dx;
    const nz = -fade * dz;
    const sc = 1.0 - 0.5 * (nx * nx + nz * nz);
    return math.vec3(nx * sc, sc, nz * sc);
}
