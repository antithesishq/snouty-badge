//! Shared math, trimmed from snouty-morph's copy (which came from demosnout
//! and snouty-maze): the f32 sine table in turns, smoothstep, lerp, and the
//! integer sine `isin`/`icos` (Q15, 1024 steps per turn) for the
//! fixed-point per-pixel loops, which must match bit for bit on wasm and
//! thumb. f32 or integer only: the M33 FPU handles f32; f64 is soft-float
//! and never appears in the cart (`zig build check-float`).
//!
//! `init_tables()` must run before the first `isin` (main.start() calls it
//! first). The f32 table is built at comptime as in snouty-maze (1024
//! iterations, which Adrian's Mac Zig handles); the integer table is filled
//! from it at run time.
const std = @import("std");

pub inline fn clamp01(x: f32) f32 {
    return @min(1.0, @max(0.0, x));
}

pub inline fn clampf(x: f32, lo: f32, hi: f32) f32 {
    return @min(hi, @max(lo, x));
}

/// smoothstep on [0, 1].
pub inline fn smoothstep01(t: f32) f32 {
    const x = clamp01(t);
    return x * x * (3.0 - 2.0 * x);
}

pub inline fn lerp1(a: f32, b: f32, t: f32) f32 {
    return a + (b - a) * t;
}

/// Fractional part, x - floor(x), in [0, 1).
pub inline fn fract(x: f32) f32 {
    return x - @floor(x);
}

/// Round to the nearest integer (halves away from zero).
pub inline fn iround(x: f32) i32 {
    return @intFromFloat(if (x >= 0) x + 0.5 else x - 0.5);
}

// ---------------------------------------------------------------------------
// Sine table. Angles are in "turns" (1.0 = 360 degrees).

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

// ---------------------------------------------------------------------------
// Integer sine: 1024 steps per turn, results in -32767..32767 (Q15).

pub const isin_len = 1024;
var isin_table: [isin_len]i16 = @splat(0);

/// Fills the integer sine table. Call once, before any isin/icos.
pub fn init_tables() void {
    for (&isin_table, 0..) |*v, i| {
        const s = sin_table[i] * 32767.0;
        const r: i32 = @intFromFloat(if (s >= 0) s + 0.5 else s - 0.5);
        v.* = @intCast(std.math.clamp(r, -32767, 32767));
    }
}

/// sin(a / 1024 turns) in Q15; `a` wraps (only the low 10 bits count).
pub inline fn isin(a: u32) i32 {
    return isin_table[a & (isin_len - 1)];
}

/// cos(a / 1024 turns) in Q15.
pub inline fn icos(a: u32) i32 {
    return isin_table[(a +% 256) & (isin_len - 1)];
}

/// isin for a signed phase.
pub inline fn isin_i(a: i32) i32 {
    return isin(@bitCast(a));
}

test "math: sine tables" {
    init_tables();
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), sin_turns(0.25), 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, -1.0), cos_turns(0.5), 1e-4);
    try std.testing.expectEqual(@as(i32, 32767), isin(256));
    try std.testing.expectEqual(@as(i32, -32767), icos(512));
    try std.testing.expectEqual(isin(1000), isin_i(-24));
    try std.testing.expectEqual(@as(i32, 3), iround(2.5));
    try std.testing.expectEqual(@as(i32, -3), iround(-2.5));
}
