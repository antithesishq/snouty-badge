//! 16.16 fixed point for the simulation (SPEC.md 9.3: no f32 in `step`).
//! Angles are u16 turns: 65,536 = 360 degrees, 0 = +x, 16,384 = +y (screen
//! down / map south), increasing clockwise on the map as drawn.
const std = @import("std");

pub const Fixed = i32;
pub const one: Fixed = 1 << 16;
pub const half: Fixed = 1 << 15;

pub fn from_int(i: i32) Fixed {
    return i << 16;
}
/// Floor toward negative infinity.
pub fn to_int(f: Fixed) i32 {
    return f >> 16;
}
pub fn from_float(comptime f: comptime_float) Fixed {
    return @intFromFloat(f * 65536.0);
}
pub fn to_f32(f: Fixed) f32 {
    return @as(f32, @floatFromInt(f)) / 65536.0;
}
pub fn mul(a: Fixed, b: Fixed) Fixed {
    return @intCast((@as(i64, a) * @as(i64, b)) >> 16);
}
pub fn div(a: Fixed, b: Fixed) Fixed {
    return @intCast(@divTrunc(@as(i64, a) << 16, @as(i64, b)));
}
pub fn abs(a: Fixed) Fixed {
    return if (a < 0) -a else a;
}
pub fn frac(a: Fixed) Fixed {
    return a & 0xFFFF;
}

pub const Angle = u16;
pub const angle_quarter: Angle = 16384;
/// Degrees to angle units, for comptime constants.
pub fn deg(comptime d: comptime_float) Angle {
    return @intFromFloat(d * 65536.0 / 360.0);
}

const table_bits = 10;
const table_len = 1 << table_bits;
const sin_table: [table_len]Fixed = blk: {
    @setEvalBranchQuota(20000);
    var t: [table_len]Fixed = undefined;
    for (&t, 0..) |*v, i| {
        const a = @as(comptime_float, @floatFromInt(i)) * 2.0 * std.math.pi / @as(comptime_float, table_len);
        v.* = @intFromFloat(@round(@sin(a) * 65536.0));
    }
    break :blk t;
};

pub fn sin(a: Angle) Fixed {
    return sin_table[a >> (16 - table_bits)];
}
pub fn cos(a: Angle) Fixed {
    return sin_table[(a +% angle_quarter) >> (16 - table_bits)];
}

test "sin/cos basics" {
    try std.testing.expectEqual(@as(Fixed, 0), sin(0));
    try std.testing.expectEqual(one, sin(angle_quarter));
    try std.testing.expectEqual(one, cos(0));
    try std.testing.expectEqual(from_int(6), mul(from_int(2), from_int(3)));
    try std.testing.expectEqual(half, div(one, from_int(2)));
}
