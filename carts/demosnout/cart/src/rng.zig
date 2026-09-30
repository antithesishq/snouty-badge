//! Seedable xorshift32 (copied from snouty-maze). Parts never call
//! cart.rand(): each seeds its own generator with a constant in enter(), so
//! every run shows the same frames (SPEC.md section 4).
const std = @import("std");

pub const Xorshift = struct {
    state: u32,

    pub fn init(seed: u32) Xorshift {
        return .{ .state = if (seed == 0) 0x9e3779b9 else seed };
    }

    pub fn next(self: *Xorshift) u32 {
        var x = self.state;
        x ^= x << 13;
        x ^= x >> 17;
        x ^= x << 5;
        self.state = x;
        return x;
    }

    /// Uniform in [0, n). n > 0.
    pub fn below(self: *Xorshift, n: u32) u32 {
        return @intCast((@as(u64, self.next()) * n) >> 32);
    }

    /// Uniform in [0, 1).
    pub fn unit(self: *Xorshift) f32 {
        return @as(f32, @floatFromInt(self.next() >> 8)) * (1.0 / 16777216.0);
    }
};

test "xorshift is deterministic and covers its range" {
    var a = Xorshift.init(1);
    var b = Xorshift.init(1);
    for (0..100) |_| try std.testing.expectEqual(a.next(), b.next());
    var hit: [4]bool = @splat(false);
    for (0..200) |_| hit[a.below(4)] = true;
    for (hit) |h| try std.testing.expect(h);
}
