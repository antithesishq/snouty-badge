//! Ripple normal for the water plane y = 0 (PLAN.md table of three waves).
//! Only the gradient of the height field is used; the plane stays flat.
const std = @import("std");
const math = @import("math.zig");
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

/// Per-frame phase offsets fract(w_i * t), in turns. Set by begin_frame.
pub const Phases = [3]f32;

pub fn phases_at_frame(frame: u32) Phases {
    // t = frame / 20 s. The f32 product is exact enough for any frame below
    // 2^24; fract keeps the runtime phase argument small.
    const t = @as(f32, @floatFromInt(frame)) * (1.0 / 20.0);
    var ph: Phases = undefined;
    inline for (waves, 0..) |wv, i| ph[i] = math.fract(wv.w * t);
    return ph;
}

/// Perturbed unit normal at water point `p`, `dist` from the ray origin.
pub inline fn normal(p: Vec3, dist: f32, ph: Phases) Vec3 {
    const fade = 1.0 / (1.0 + 0.06 * dist);
    var dx: f32 = 0.0;
    var dz: f32 = 0.0;
    inline for (waves, 0..) |wv, i| {
        const c = math.cos_turns(wv.kx * p[0] + wv.kz * p[2] + ph[i]);
        dx += gx[i] * c;
        dz += gz[i] * c;
    }
    return math.renormalize(math.vec3(-fade * dx, 1.0, -fade * dz));
}
