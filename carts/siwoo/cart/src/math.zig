//! The f32 sine table in turns (1.0 = 360 degrees, so wrapping is a fract,
//! not a modulo by pi), copied from demosnout's math.zig with only what the
//! head and the name use. Everything is f32: the M33 FPU handles f32
//! add/mul in one cycle; f64 is soft-float and never appears in the cart
//! (`zig build check-float`).
const std = @import("std");

pub const sin_table_len = 1024;
pub const sin_table: [sin_table_len]f32 = blk: {
    @setEvalBranchQuota(20000);
    var t: [sin_table_len]f32 = undefined;
    for (0..sin_table_len) |i| {
        const a: f64 = @as(f64, @floatFromInt(i)) * (2.0 * std.math.pi / @as(f64, sin_table_len));
        t[i] = @floatCast(@sin(a));
    }
    break :blk t;
};

/// sin(turns * 2*pi) with linear interpolation. Valid for any finite input.
pub inline fn sin_turns(turns: f32) f32 {
    const f = (turns - @floor(turns)) * @as(f32, sin_table_len);
    const i: u32 = @intFromFloat(f);
    const frac = f - @as(f32, @floatFromInt(i));
    const a = sin_table[i & (sin_table_len - 1)];
    const b = sin_table[(i + 1) & (sin_table_len - 1)];
    return a + (b - a) * frac;
}

pub inline fn cos_turns(turns: f32) f32 {
    return sin_turns(turns + 0.25);
}

/// Fractional part, x - floor(x), in [0, 1).
pub inline fn fract(x: f32) f32 {
    return x - @floor(x);
}

test "sin table" {
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), sin_turns(0.0), 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), sin_turns(0.25), 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, -1.0), sin_turns(0.75), 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), cos_turns(3.0), 1e-4);
}
