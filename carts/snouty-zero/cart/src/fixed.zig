//! Q16.16 fixed point, turn angles and a small rng. Everything in this cart
//! is integer so wasm, badge-bench and the badge produce identical frames
//! and the simulation rewinds exactly (SPEC 5, 10).
const std = @import("std");
const sin_table = @import("gen/sin.zig").table;

/// Fraction bits of the Q16.16 format used for world coordinates.
pub const Q = 16;
pub const one: i32 = 1 << Q;

/// (a * b) >> 16 through i64, no overflow for |a|,|b| < 2^31.
pub inline fn mul(a: i32, b: i32) i32 {
    return @intCast((@as(i64, a) * @as(i64, b)) >> Q);
}

/// (a << 16) / b through i64; b != 0.
pub inline fn div(a: i32, b: i32) i32 {
    return @intCast(@divTrunc(@as(i64, a) << Q, @as(i64, b)));
}

/// Angles are u16 turns: 65536 per revolution, 0 = +x, 16384 = +y.
pub const Turn = u16;

/// sin of a turn angle in Q16.16, from the 256-entry table (tools/gen_sin.py).
pub inline fn sin(a: Turn) i32 {
    return sin_table[a >> 8];
}
pub inline fn cos(a: Turn) i32 {
    return sin_table[(a +% 16384) >> 8];
}

/// Signed shortest difference from `from` to `to` in turn units (-32768..32767).
pub inline fn turn_diff(from: Turn, to: Turn) i32 {
    return @as(i16, @bitCast(to -% from));
}

/// Integer part of a Q16.16 value (floor).
pub inline fn int(v: i32) i32 {
    return v >> Q;
}

/// Integer square root (floor) of a u32.
pub fn isqrt(v: u32) u32 {
    if (v < 2) return v;
    var x: u32 = @as(u32, 1) << @intCast((32 - @clz(v) + 1) / 2);
    while (true) {
        const y = (x + v / x) / 2;
        if (y >= x) return x;
        x = y;
    }
}

/// Approximate atan2 as a turn (u16): octant decomposition plus a linear
/// ratio, error under 1/128 turn. Enough for AI steering and rank.
pub fn atan2(y: i32, x: i32) Turn {
    if (x == 0 and y == 0) return 0;
    const ax: i64 = @abs(x);
    const ay: i64 = @abs(y);
    // ratio in 0..8192 (1/8 turn is 8192 units)
    const r: i64 = if (ax >= ay) @divTrunc(ay * 8192, ax) else @divTrunc(ax * 8192, ay);
    // bend the linear ratio toward atan: t = r*(1 + (8192-r)*0.27/8192)/... keep it simple:
    const t: i64 = r + @divTrunc((8192 - r) * r * 11, 8192 * 40);
    var a: i64 = if (ax >= ay) t else 16384 - t;
    if (x < 0) a = 32768 - a;
    if (y < 0) a = -a;
    return @bitCast(@as(i16, @truncate(a)));
}

/// xorshift32; never seed with 0.
pub const Rng = struct {
    s: u32,
    pub fn next(self: *Rng) u32 {
        var x = self.s;
        x ^= x << 13;
        x ^= x >> 17;
        x ^= x << 5;
        self.s = x;
        return x;
    }
    /// 0..n-1
    pub fn below(self: *Rng, n: u32) u32 {
        return self.next() % n;
    }
};

test "sin table quadrants" {
    try std.testing.expectEqual(@as(i32, 0), sin(0));
    try std.testing.expectEqual(one, sin(16384));
    try std.testing.expectEqual(one, cos(0));
    try std.testing.expectEqual(-one, cos(32768));
    try std.testing.expect(@abs(sin(8192) - 46341) < 4);
}

test "turn_diff wraps" {
    try std.testing.expectEqual(@as(i32, 200), turn_diff(65500, 164));
    try std.testing.expectEqual(@as(i32, -200), turn_diff(164, 65500));
}

test "isqrt" {
    try std.testing.expectEqual(@as(u32, 10), isqrt(100));
    try std.testing.expectEqual(@as(u32, 10), isqrt(119));
    try std.testing.expectEqual(@as(u32, 65535), isqrt(0xFFFF_FFFF));
}

test "atan2 octants" {
    try std.testing.expectEqual(@as(Turn, 0), atan2(0, 100));
    try std.testing.expect(@abs(turn_diff(atan2(100, 0), 16384)) < 300);
    try std.testing.expect(@abs(turn_diff(atan2(100, 100), 8192)) < 300);
    try std.testing.expect(@abs(turn_diff(atan2(-100, -100), 40960)) < 300);
    try std.testing.expect(@abs(turn_diff(atan2(0, -100), 32768)) < 300);
}
