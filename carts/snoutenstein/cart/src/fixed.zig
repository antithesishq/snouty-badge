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

/// atan(i / 256) in angle units for i in 0..256 (0 .. 45 degrees),
/// built at comptime; `atan2` below is pure integer at run time.
const atan_len = 256;
const atan_table: [atan_len + 1]Angle = blk: {
    @setEvalBranchQuota(20000);
    var t: [atan_len + 1]Angle = undefined;
    for (&t, 0..) |*v, i| {
        const r = @as(f64, @floatFromInt(i)) / @as(f64, atan_len);
        v.* = @intFromFloat(@round(std.math.atan(r) * 65536.0 / (2.0 * std.math.pi)));
    }
    break :blk t;
};

/// Angle of the vector (x, y) in the same convention as `sin`/`cos`
/// (0 = +x, quarter = +y). Integer only; error under 0.12 degrees.
/// atan2(0, 0) is 0.
pub fn atan2(y: Fixed, x: Fixed) Angle {
    if (x == 0 and y == 0) return 0;
    const ax: i64 = if (x < 0) -@as(i64, x) else x;
    const ay: i64 = if (y < 0) -@as(i64, y) else y;
    var a: Angle = undefined;
    if (ay <= ax) {
        const r: usize = @intCast(@divTrunc(ay * atan_len + @divTrunc(ax, 2), ax));
        a = atan_table[r];
    } else {
        const r: usize = @intCast(@divTrunc(ax * atan_len + @divTrunc(ay, 2), ay));
        a = angle_quarter - atan_table[r];
    }
    if (x < 0) a = 32768 - a;
    if (y < 0) a = 0 -% a;
    return a;
}

/// Signed difference `a - b` wrapped to -180 .. +180 degrees.
pub fn angle_diff(a: Angle, b: Angle) i16 {
    return @bitCast(a -% b);
}

test "sin/cos basics" {
    try std.testing.expectEqual(@as(Fixed, 0), sin(0));
    try std.testing.expectEqual(one, sin(angle_quarter));
    try std.testing.expectEqual(one, cos(0));
    try std.testing.expectEqual(from_int(6), mul(from_int(2), from_int(3)));
    try std.testing.expectEqual(half, div(one, from_int(2)));
}

test "atan2 octants and wrap" {
    try std.testing.expectEqual(@as(Angle, 0), atan2(0, one));
    try std.testing.expectEqual(angle_quarter, atan2(one, 0));
    try std.testing.expectEqual(@as(Angle, 32768), atan2(0, -one));
    try std.testing.expectEqual(@as(Angle, 49152), atan2(-one, 0));
    try std.testing.expectEqual(@as(Angle, 8192), atan2(one, one));
    try std.testing.expectEqual(@as(Angle, 32768 + 8192), atan2(-one, -one));
    // Round trip through the sin table over the whole circle.
    var a: u32 = 0;
    while (a < 65536) : (a += 97) {
        const back = atan2(sin(@intCast(a)) * 16, cos(@intCast(a)) * 16);
        const d = angle_diff(back, @intCast(a));
        try std.testing.expect(d >= -80 and d <= 80); // table step 64 + atan error
    }
    try std.testing.expectEqual(@as(i16, -10), angle_diff(5, 15));
    try std.testing.expectEqual(@as(i16, 20), angle_diff(10, 65526));
}
