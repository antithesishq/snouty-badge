//! Seedable xorshift32 streams. Gameplay never calls cart.rand() directly:
//! main.zig takes one seed from it in start(), and every stream (the game's
//! round seeds, each AI's own stream, M2's gap seeds) derives from that, so
//! headless runs (preview.mjs --seed) and rewind replays reproduce exactly.
//! Integer only.
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

    /// True with probability permille / 1000.
    pub fn chance(self: *Xorshift, permille: u32) bool {
        return self.below(1000) < permille;
    }
};

/// Mixes a seed with a stream number (murmur3 finaliser), so sibling
/// streams from one seed look unrelated.
pub fn mix(seed: u32, stream: u32) u32 {
    var h = seed ^ (stream *% 0x9e3779b9);
    h ^= h >> 16;
    h *%= 0x85ebca6b;
    h ^= h >> 13;
    h *%= 0xc2b2ae35;
    h ^= h >> 16;
    return h;
}

test "xorshift is deterministic and covers its range" {
    var a = Xorshift.init(1);
    var b = Xorshift.init(1);
    for (0..100) |_| try std.testing.expectEqual(a.next(), b.next());
    var hit: [4]bool = @splat(false);
    for (0..200) |_| hit[a.below(4)] = true;
    for (hit) |h| try std.testing.expect(h);
    try std.testing.expect(mix(1, 0) != mix(1, 1));
}
